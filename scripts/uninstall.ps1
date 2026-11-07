# uninstall.ps1 - remove dsh-multi-window from a DSH profile.
#
# Usage:
#   .\scripts\uninstall.ps1                        # remove the plugin from the desktop profile
#   .\scripts\uninstall.ps1 -Profile desktop -DshHome <dsh home>
#   .\scripts\uninstall.ps1 -DryRun                # print the plan, change nothing
#   .\scripts\uninstall.ps1 -RemoveRuntime         # also delete the shared window runtime
#   .\scripts\uninstall.ps1 -RemoveProfiles        # also delete the per-conversation profiles
#
# The plugin is removed with the DSH CLI (dsh plugin --profile <name> remove <package>).
# When the CLI is unavailable or fails, the script falls back to editing the profile
# package.json and deleting the junction in node_modules. Only a junction or a
# symbolic link is ever deleted there; a real directory is reported and left alone.
#
# The window runtime and the temporary browser profiles are KEPT by default: the
# runtime is reused by every profile and the profiles hold each window's local state.
#
# This script never kills processes, never restarts the GUI, never touches app.asar
# and never uses the network.
#
# NOTE: this file is intentionally pure ASCII. Windows PowerShell 5.1 mis-parses
# non-ASCII literals in a script that is not saved as UTF-8 with BOM, so a pure ASCII
# script stays valid no matter how it was copied.

[CmdletBinding()]
param(
    [string]$Profile = 'desktop',
    [string]$DshHome = '',
    [switch]$DryRun,
    [switch]$RemoveRuntime,
    [switch]$RemoveProfiles
)

$ErrorActionPreference = 'Stop'

$PluginName = 'dsh-multi-window'
$PluginDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($PluginDir)) {
    $PluginDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$PluginDir = Split-Path -Parent $PluginDir

# Both directories are created by the Node half under the system temporary
# directory; nothing here depends on where the plugin is installed.
$TempRoot     = [System.IO.Path]::GetTempPath()
$RuntimeDir   = Join-Path $TempRoot 'dsh-multi-window-runtime'
$RuntimeExe   = Join-Path $RuntimeDir 'dsh-window.exe'
$ProfilesRoot = Join-Path $TempRoot 'dsh-multi-window'

# ---------------------------------------------------------------- helpers

function Fail {
    param([string]$Message)
    Write-Error -Message $Message -ErrorAction Continue
    exit 1
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} bytes' -f $Bytes)
}

function Get-DirectorySize {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return 0 }
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { return 0 }
        return [double]$sum
    } catch {
        return 0
    }
}

# A reparse point is never the directory we mean to delete: recursing through it
# would destroy whatever it points at.
function Test-IsReparsePoint {
    param([string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force
        return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    } catch {
        return $false
    }
}

# Locate the DSH command line tool without assuming an installation path:
# an explicit DSH_CLI wins, then PATH.
function Resolve-DshCli {
    $configured = $env:DSH_CLI
    if (-not [string]::IsNullOrEmpty($configured)) {
        if (Test-Path -LiteralPath $configured -PathType Leaf) { return $configured }
        Write-Warning ('DSH_CLI points at a missing file, ignoring it: ' + $configured)
    }
    foreach ($name in @('dsh.cmd', 'dsh')) {
        $found = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $found) { return $found.Source }
    }
    return $null
}

# The DSH home holds every profile. DSH_HOME wins, then the conventional
# per-user location; the caller can always override with -DshHome.
function Resolve-DshHome {
    param([string]$Explicit)
    if (-not [string]::IsNullOrEmpty($Explicit)) { return $Explicit }
    if (-not [string]::IsNullOrEmpty($env:DSH_HOME)) { return $env:DSH_HOME }
    return (Join-Path $env:USERPROFILE '.dsh')
}

function Format-JsonString {
    param([string]$Value)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Value.ToCharArray()) {
        $code = [int]$ch
        if ($ch -eq '"') { [void]$sb.Append('\"') }
        elseif ($ch -eq '\') { [void]$sb.Append('\\') }
        elseif ($code -eq 8) { [void]$sb.Append('\b') }
        elseif ($code -eq 9) { [void]$sb.Append('\t') }
        elseif ($code -eq 10) { [void]$sb.Append('\n') }
        elseif ($code -eq 12) { [void]$sb.Append('\f') }
        elseif ($code -eq 13) { [void]$sb.Append('\r') }
        elseif ($code -lt 32) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# Write 2-space indented JSON without escaping non-ASCII text.
# Windows PowerShell 5.1 ConvertTo-Json produces unstable indentation, so the
# profile package.json is serialized here instead of with the built-in cmdlet.
function ConvertTo-JsonText {
    param($Node, [int]$Level = 0)

    $indent = '  ' * $Level
    $childIndent = '  ' * ($Level + 1)

    if ($null -eq $Node) { return 'null' }
    if ($Node -is [bool]) {
        if ($Node) { return 'true' } else { return 'false' }
    }
    if ($Node -is [string]) { return (Format-JsonString $Node) }

    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        $props = @($Node.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' -or $_.MemberType -eq 'Property' })
        if ($props.Count -eq 0) { return '{}' }
        $lines = @()
        foreach ($p in $props) {
            $lines += ($childIndent + (Format-JsonString $p.Name) + ': ' + (ConvertTo-JsonText $p.Value ($Level + 1)))
        }
        return ("{`n" + ($lines -join ",`n") + "`n" + $indent + '}')
    }

    if ($Node -is [System.Collections.IDictionary]) {
        if ($Node.Count -eq 0) { return '{}' }
        $lines = @()
        foreach ($key in @($Node.Keys)) {
            $lines += ($childIndent + (Format-JsonString ([string]$key)) + ': ' + (ConvertTo-JsonText $Node[$key] ($Level + 1)))
        }
        return ("{`n" + ($lines -join ",`n") + "`n" + $indent + '}')
    }

    if ($Node -is [System.Collections.IEnumerable]) {
        $items = @($Node)
        if ($items.Count -eq 0) { return '[]' }
        $lines = @()
        foreach ($item in $items) {
            $lines += ($childIndent + (ConvertTo-JsonText $item ($Level + 1)))
        }
        return ("[`n" + ($lines -join ",`n") + "`n" + $indent + ']')
    }

    if ($Node -is [double] -or $Node -is [single] -or $Node -is [decimal]) {
        return $Node.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    return ([string]$Node)
}

function Read-ProfileJson {
    param([string]$Path)
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { throw ('the profile package.json is empty: ' + $Path) }
    return ($raw | ConvertFrom-Json)
}

function Write-JsonFile {
    param([string]$Path, $Node)
    $text = (ConvertTo-JsonText $Node 0) + "`n"
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $text, $utf8)
}

function Get-BundleList {
    param($Json)
    $bundles = @()
    if ($null -ne $Json.PSObject.Properties['dsh']) {
        $dshNode = $Json.dsh
        if ($null -ne $dshNode.PSObject.Properties['profile']) {
            $profNode = $dshNode.profile
            if ($null -ne $profNode.PSObject.Properties['bundles']) {
                $bundles = @($profNode.bundles | Where-Object { $null -ne $_ })
            }
        }
    }
    return ,$bundles
}

function Get-InstalledState {
    param([string]$PackageJsonPath)
    $json = Read-ProfileJson $PackageJsonPath
    $hasDep = $false
    if ($null -ne $json.PSObject.Properties['dependencies']) {
        $hasDep = ($null -ne $json.dependencies.PSObject.Properties[$PluginName])
    }
    $bundles = Get-BundleList $json
    $hasBundle = ($bundles -contains $PluginName)
    return [pscustomobject]@{ HasDependency = $hasDep; HasBundle = $hasBundle }
}

function Backup-PackageJson {
    param([string]$Path)
    $dir = Split-Path -Parent $Path
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    $existing = @(Get-ChildItem -LiteralPath $dir -Filter 'package.json.bak.*' -File -ErrorAction SilentlyContinue)
    foreach ($bak in $existing) {
        if ((Get-FileHash -LiteralPath $bak.FullName -Algorithm SHA256).Hash -eq $hash) {
            Write-Host ('package.json already backed up with identical content: ' + $bak.FullName)
            return $bak.FullName
        }
    }
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    $target = Join-Path $dir ('package.json.bak.' + $stamp)
    $index = 1
    while (Test-Path -LiteralPath $target) {
        $target = Join-Path $dir ('package.json.bak.' + $stamp + '.' + $index)
        $index = $index + 1
    }
    Copy-Item -LiteralPath $Path -Destination $target -Force
    Write-Host ('backed up package.json -> ' + $target)
    return $target
}

# A non-ASCII path argument is mangled on Windows PowerShell 5.1 with a legacy
# console code page, so the console is switched to UTF-8 around the CLI call.
function Invoke-DshCli {
    param([string]$Cli, [string[]]$Arguments)

    $oldOut = $null
    $oldIn = $null
    $changed = $false
    try {
        $oldOut = [Console]::OutputEncoding
        $oldIn = [Console]::InputEncoding
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [Console]::OutputEncoding = $utf8
        [Console]::InputEncoding = $utf8
        $changed = $true
    } catch {
        Write-Warning ('cannot switch the console encoding to UTF-8: ' + $_.Exception.Message)
    }

    try {
        $output = & $Cli @Arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
    } catch {
        $output = $_.Exception.Message
        $code = 1
    } finally {
        if ($changed) {
            try {
                [Console]::OutputEncoding = $oldOut
                [Console]::InputEncoding = $oldIn
            } catch {
                Write-Warning 'cannot restore the console encoding (display only).'
            }
        }
    }

    return [pscustomobject]@{ ExitCode = $code; Output = $output }
}

# Test-Path throws on an invalid path, which with ErrorActionPreference=Stop would
# abort the script before the fallback path ever runs.
function Test-DshCli {
    param([string]$Cli)
    if ([string]::IsNullOrEmpty($Cli)) { return $false }
    try {
        return (Test-Path -LiteralPath $Cli -PathType Leaf)
    } catch {
        return $false
    }
}

# A junction Target may be reported with a Global\ or \\?\ prefix, so normalize
# before comparing it with the plugin directory.
function Normalize-LinkTarget {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return '' }
    $t = $Path.Trim().Replace('/', '\')
    foreach ($prefix in @('\??\', '\\?\', 'Global\')) {
        if ($t.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $t = $t.Substring($prefix.Length)
        }
    }
    return $t.TrimEnd('\')
}

# Unlink the junction or symbolic link itself, never its target. Directory.Delete
# with recursive=$false drops the reparse point and leaves the target alone.
#
# Do not "simplify" this into Remove-Item -Recurse. Measured on Windows PowerShell
# 5.1 that happens to unlink a junction rather than descend into it, but the
# behaviour is undocumented and other deleters - MSYS rm -rf, Node fs.rmSync - do
# follow the link and wipe the target.
function Remove-LinkOnly {
    param([string]$Path)
    if ([System.IO.Directory]::Exists($Path)) {
        [System.IO.Directory]::Delete($Path, $false)
    } else {
        [System.IO.File]::Delete($Path)
    }
}

# Delete a directory tree without walking through a junction or symbolic link.
function Remove-TreeSafely {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (Test-IsReparsePoint $Path) {
        Remove-LinkOnly $Path
        return
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Remove-Item -LiteralPath $Path -Force
        return
    }

    $children = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
    foreach ($child in $children) {
        if (Test-IsReparsePoint $child.FullName) {
            Remove-LinkOnly $child.FullName
        } elseif ($child.PSIsContainer) {
            Remove-TreeSafely $child.FullName
        } else {
            Remove-Item -LiteralPath $child.FullName -Force
        }
    }
    Remove-Item -LiteralPath $Path -Force
}

# Delete node_modules\<package> only when it is a link onto the plugin directory.
# A real directory (an unpacked copy, or another package with the same name) is
# reported and kept.
function Remove-PluginJunction {
    param([string]$ProfileDir, [string]$TargetDir)

    $linkPath = Join-Path (Join-Path $ProfileDir 'node_modules') $PluginName
    if (-not (Test-Path -LiteralPath $linkPath)) {
        Write-Host ('no node_modules\' + $PluginName + ' entry, nothing to delete there.')
        return $true
    }

    $item = Get-Item -LiteralPath $linkPath -Force
    $linkType = ''
    try { $linkType = [string]$item.LinkType } catch { $linkType = '' }
    $isReparse = (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)

    if (-not $isReparse -and $linkType -ne 'Junction' -and $linkType -ne 'SymbolicLink') {
        Write-Warning ('node_modules\' + $PluginName + ' is a real directory, not a junction; left untouched. Delete it by hand if it is an old unpacked copy.')
        return $false
    }

    $resolved = $null
    try { $resolved = $item.Target } catch { $resolved = $null }
    if ($resolved -is [array]) { $resolved = $resolved[0] }
    $normalized = Normalize-LinkTarget ([string]$resolved)
    if ($normalized -ne '' -and ($normalized -ine $TargetDir.TrimEnd('\'))) {
        Write-Warning ('node_modules\' + $PluginName + ' points at ' + $resolved + ', not at the plugin directory; left untouched.')
        return $false
    }

    Remove-LinkOnly $linkPath
    Write-Host ('removed link: ' + $linkPath)
    return $true
}

# Delete the derived window runtime. It only holds hard links onto the Host's own
# Electron payload plus one generated main process, so nothing but time is lost.
function Remove-WindowRuntime {
    param([string]$RuntimeDir, [string]$RuntimeExe)

    if (-not (Test-Path -LiteralPath $RuntimeDir)) {
        Write-Host ('no runtime directory: ' + $RuntimeDir)
        return $true
    }
    if (Test-IsReparsePoint $RuntimeDir) {
        Write-Warning ('the runtime directory is a reparse point; refusing to delete it: ' + $RuntimeDir)
        return $false
    }

    $looksLikeRuntime = $false
    try { $looksLikeRuntime = Test-Path -LiteralPath $RuntimeExe -PathType Leaf } catch { $looksLikeRuntime = $false }
    if (-not $looksLikeRuntime) {
        try { $looksLikeRuntime = Test-Path -LiteralPath (Join-Path $RuntimeDir 'resources') -PathType Container } catch { $looksLikeRuntime = $false }
    }
    if (-not $looksLikeRuntime) {
        Write-Warning ('the directory does not look like the window runtime (no dsh-window.exe and no resources\); refusing to delete: ' + $RuntimeDir)
        return $false
    }

    $size = Get-DirectorySize $RuntimeDir
    Write-Host ('deleting runtime (' + (Format-Size $size) + ' of hard links): ' + $RuntimeDir)
    try {
        Remove-TreeSafely $RuntimeDir
    } catch {
        Write-Warning ('cannot delete the runtime directory: ' + $_.Exception.Message)
        Write-Warning 'close any open DSH window and run this script again.'
        return $false
    }
    Write-Host 'runtime deleted.'
    return $true
}

# Delete the per-conversation Chromium profiles below the temporary directory.
function Remove-WindowProfiles {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root)) {
        Write-Host ('no temporary profiles: ' + $Root)
        return $true
    }
    if (Test-IsReparsePoint $Root) {
        Write-Warning ('the temporary profile directory is a reparse point; refusing to delete it: ' + $Root)
        return $false
    }

    $size = Get-DirectorySize $Root
    $count = 0
    try {
        $count = @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue).Count
    } catch {
        $count = 0
    }
    Write-Host ('deleting temporary profiles (' + $count + ' folders, ' + (Format-Size $size) + '): ' + $Root)
    try {
        Remove-TreeSafely $Root
    } catch {
        Write-Warning ('cannot delete the temporary profiles: ' + $_.Exception.Message)
        Write-Warning 'close any open DSH window and run this script again.'
        return $false
    }
    Write-Host 'temporary profiles deleted.'
    return $true
}

# ---------------------------------------------------------------- main

$DshHome = Resolve-DshHome $DshHome
$DshCli = Resolve-DshCli

Write-Host '==> dsh-multi-window uninstall'
Write-Host ('    profile : ' + $Profile)

$profileDir = Join-Path $DshHome ('profiles\' + $Profile)
if (-not (Test-Path -LiteralPath $profileDir -PathType Container)) {
    Fail ('profile directory not found: ' + $profileDir + '. Check -DshHome / -Profile.')
}
$packageJson = Join-Path $profileDir 'package.json'
if (-not (Test-Path -LiteralPath $packageJson -PathType Leaf)) {
    Fail ('no package.json in the profile directory: ' + $packageJson)
}

Write-Host ('    plugin dir : ' + $PluginDir)
Write-Host ('    profile dir: ' + $profileDir)

try {
    $state = Get-InstalledState $packageJson
} catch {
    Fail ('cannot read package.json: ' + $_.Exception.Message)
}

$installed = ($state.HasDependency -or $state.HasBundle)
$cliAvailable = Test-DshCli $DshCli

if (-not $installed) {
    Write-Host 'the package is not referenced by this profile; no plugin step needed.'
}

if ($DryRun) {
    Write-Host ''
    Write-Host '[DryRun] no file is written and the CLI is not invoked. Plan:'
    if ($installed) {
        Write-Host ('  1) back up: ' + $packageJson + ' -> package.json.bak.<yyyyMMddHHmmss>')
        if ($cliAvailable) {
            Write-Host ('  2) primary: ' + $DshCli + ' plugin --profile ' + $Profile + ' remove ' + $PluginName)
        } else {
            Write-Host '  2) primary: skipped (CLI not found)'
        }
        Write-Host '  3) fallback (only when the primary path fails) edits these JSON fields:'
        Write-Host ('       remove dependencies["' + $PluginName + '"]')
        Write-Host ('       remove "' + $PluginName + '" from dsh.profile.bundles')
        Write-Host ('       remove node_modules\' + $PluginName + ' if it is a junction onto the plugin directory')
    } else {
        Write-Host '  1) 2) 3) plugin steps skipped: not installed'
    }
    if ($RemoveRuntime) {
        if (Test-Path -LiteralPath $RuntimeDir) {
            Write-Host ('  4) window runtime: would delete ' + $RuntimeDir + ' (' + (Format-Size (Get-DirectorySize $RuntimeDir)) + ' of hard links)')
        } else {
            Write-Host ('  4) window runtime: nothing to delete (' + $RuntimeDir + ' is absent)')
        }
    } else {
        Write-Host ('  4) window runtime: kept (pass -RemoveRuntime to delete ' + $RuntimeDir + ')')
    }
    if ($RemoveProfiles) {
        if (Test-Path -LiteralPath $ProfilesRoot) {
            Write-Host ('  5) temporary profiles: would delete ' + $ProfilesRoot + ' (' + (Format-Size (Get-DirectorySize $ProfilesRoot)) + ')')
        } else {
            Write-Host ('  5) temporary profiles: nothing to delete (' + $ProfilesRoot + ' is absent)')
        }
    } else {
        Write-Host ('  5) temporary profiles: kept (pass -RemoveProfiles to delete ' + $ProfilesRoot + ')')
    }
    Write-Host ('  current state: dependencies has the package = ' + $state.HasDependency + '; bundles has the package = ' + $state.HasBundle)
    Write-Host ''
    Write-Host 'DryRun finished, nothing was changed.'
    exit 0
}

$backupPath = $null
$removed = $true

if ($installed) {
    $backupPath = Backup-PackageJson $packageJson

    $done = $false

    if ($cliAvailable) {
        Write-Host 'calling the DSH CLI ...'
        $result = Invoke-DshCli -Cli $DshCli -Arguments @('plugin', '--profile', $Profile, 'remove', $PluginName)
        if ($result.ExitCode -eq 0) {
            try {
                $state = Get-InstalledState $packageJson
            } catch {
                $state = [pscustomobject]@{ HasDependency = $false; HasBundle = $false }
            }
            if (-not $state.HasDependency -and -not $state.HasBundle) {
                Write-Host 'CLI uninstall succeeded.'
                $done = $true
            } else {
                Write-Warning 'the CLI reported success but package.json still references the package; the fallback path finishes the job.'
            }
        } else {
            Write-Warning ('the DSH CLI failed (exit code ' + $result.ExitCode + '), using the fallback path.')
            if ($result.Output -and $result.Output.Trim().Length -gt 0) {
                Write-Host '--- CLI output ---'
                Write-Host $result.Output.Trim()
                Write-Host '------------------'
            }
        }
    } else {
        Write-Warning 'DSH CLI not found, using the fallback path.'
    }

    if (-not $done) {
        Write-Host 'fallback: editing package.json ...'
        try {
            $json = Read-ProfileJson $packageJson

            if ($null -ne $json.PSObject.Properties['dependencies']) {
                $depNode = $json.dependencies
                if ($null -ne $depNode.PSObject.Properties[$PluginName]) {
                    $depNode.PSObject.Properties.Remove($PluginName)
                    Write-Host ('removed dependencies[' + $PluginName + ']')
                }
            }

            $bundles = Get-BundleList $json
            if ($bundles -contains $PluginName) {
                $kept = @($bundles | Where-Object { $_ -ne $PluginName })
                if ($null -eq $json.PSObject.Properties['dsh']) {
                    Add-Member -InputObject $json -MemberType NoteProperty -Name 'dsh' -Value ([pscustomobject]@{}) -Force
                }
                if ($null -eq $json.dsh.PSObject.Properties['profile']) {
                    Add-Member -InputObject $json.dsh -MemberType NoteProperty -Name 'profile' -Value ([pscustomobject]@{}) -Force
                }
                Add-Member -InputObject $json.dsh.profile -MemberType NoteProperty -Name 'bundles' -Value $kept -Force
                Write-Host ('removed ' + $PluginName + ' from dsh.profile.bundles (' + $bundles.Count + ' -> ' + $kept.Count + ' entries)')
            }

            Write-JsonFile -Path $packageJson -Node $json
            Write-Host ('written: ' + $packageJson)
        } catch {
            Fail ('cannot rewrite package.json: ' + $_.Exception.Message + ' (backup at ' + $backupPath + ', restore it by hand)')
        }
    }

    if (-not (Remove-PluginJunction -ProfileDir $profileDir -TargetDir $PluginDir)) {
        $removed = $false
    }

    try {
        $state = Get-InstalledState $packageJson
    } catch {
        Fail ('cannot re-read package.json for verification: ' + $_.Exception.Message)
    }
    if ($state.HasDependency -or $state.HasBundle) {
        Fail ('verification failed: dependencies has the package = ' + $state.HasDependency + ', bundles has the package = ' + $state.HasBundle + '. Backup at ' + $backupPath)
    }
} else {
    if (-not (Remove-PluginJunction -ProfileDir $profileDir -TargetDir $PluginDir)) {
        $removed = $false
    }
}

if ($RemoveRuntime) {
    $configured = $env:DSH_MULTI_WINDOW_EXE
    if (-not [string]::IsNullOrEmpty($configured)) {
        $normConfigured = Normalize-LinkTarget $configured
        $normRuntime = Normalize-LinkTarget $RuntimeDir
        if (-not $normConfigured.StartsWith($normRuntime, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Warning ('DSH_MULTI_WINDOW_EXE points outside the runtime directory, so it is not deleted: ' + $configured)
        }
    }
    if (-not (Remove-WindowRuntime -RuntimeDir $RuntimeDir -RuntimeExe $RuntimeExe)) {
        $removed = $false
    }
} else {
    Write-Host ''
    Write-Host ('window runtime kept: ' + $RuntimeDir)
    Write-Host '  (pass -RemoveRuntime to delete it; it is rebuilt from the Host on the next window)'
}

if ($RemoveProfiles) {
    if (-not (Remove-WindowProfiles -Root $ProfilesRoot)) {
        $removed = $false
    }
} else {
    Write-Host ('temporary window profiles kept: ' + $ProfilesRoot)
    Write-Host '  (pass -RemoveProfiles to delete them)'
}

Write-Host ''
if ($removed) {
    Write-Host 'Uninstall finished. Restart the DSH desktop app for the change to take effect.'
    exit 0
} else {
    Write-Warning 'uninstall finished with warnings (see above); restart the DSH desktop app for the plugin change to take effect.'
    exit 1
}
