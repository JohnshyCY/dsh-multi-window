# install.ps1 - install dsh-multi-window into a DSH profile.
#
# Usage:
#   .\scripts\install.ps1                          # install into the desktop profile
#   .\scripts\install.ps1 -Profile desktop -DshHome <dsh home>
#   .\scripts\install.ps1 -DryRun                  # print the plan, change nothing
#
# The plugin is installed with the DSH CLI (dsh plugin --profile <name> add link:<dir>).
# When the CLI is unavailable or fails, the script falls back to editing the profile
# package.json and creating a junction in node_modules.
#
# The sidecar window runtime is NOT generated here. It is derived from the Host's own
# Electron payload the first time a window is opened, so installing needs no large
# copy and no extra step.
#
# This script never kills processes, never restarts the GUI, never touches app.asar
# and never uses the network.
#
# NOTE: this file is intentionally pure ASCII. Windows PowerShell 5.1 mis-parses
# non-ASCII literals in a script that is not saved as UTF-8 with BOM, so any copy of
# this file stays valid regardless of how it was transferred.

[CmdletBinding()]
param(
    [string]$Profile = 'desktop',
    [string]$DshHome = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$PluginName = 'dsh-multi-window'
# The plugin directory is the parent of this script, so a path containing
# non-ASCII characters never has to appear in the source of this file.
$PluginDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($PluginDir)) {
    $PluginDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$PluginDir = Split-Path -Parent $PluginDir
$LinkValue = 'link:' + $PluginDir

# ---------------------------------------------------------------- helpers

function Fail {
    param([string]$Message)
    Write-Error -Message $Message -ErrorAction Continue
    exit 1
}

# Locate the DSH command line tool without assuming an installation path:
# an explicit DSH_CLI wins, then PATH, then the well-known npm bin shims.
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

# Emit 2-space indented JSON without escaping non-ASCII text.
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

function Set-JsonProperty {
    param($Node, [string]$Name, $Value)
    Add-Member -InputObject $Node -MemberType NoteProperty -Name $Name -Value $Value -Force
}

# Read dsh.profile.bundles; always an array, empty when the field is absent.
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

# Run the DSH CLI. A non-ASCII path argument is mangled on Windows PowerShell 5.1
# with a legacy console code page, so the console is switched to UTF-8 around the
# call and restored afterwards.
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
        Write-Warning ('cannot switch the console encoding to UTF-8; a non-ASCII path may be garbled: ' + $_.Exception.Message)
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
# follow the link and wipe the target. Unlinking explicitly is the only portable
# form and the only one that cannot destroy data outside the tree.
function Remove-LinkOnly {
    param([string]$Path)
    if ([System.IO.Directory]::Exists($Path)) {
        [System.IO.Directory]::Delete($Path, $false)
    } else {
        [System.IO.File]::Delete($Path)
    }
}

# Make node_modules\<package> a junction onto the plugin directory.
function Ensure-PluginJunction {
    param([string]$ProfileDir, [string]$TargetDir)

    $nodeModules = Join-Path $ProfileDir 'node_modules'
    if (-not (Test-Path -LiteralPath $nodeModules -PathType Container)) {
        New-Item -ItemType Directory -Path $nodeModules -Force | Out-Null
        Write-Host ('created directory: ' + $nodeModules)
    }
    $linkPath = Join-Path $nodeModules $PluginName

    if (Test-Path -LiteralPath $linkPath) {
        $item = Get-Item -LiteralPath $linkPath -Force
        $isLink = (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
        if (-not $isLink) {
            Write-Warning ('node_modules\' + $PluginName + ' exists and is not a link (a real directory or an unpacked older copy); left untouched. Remove it by hand if the plugin misbehaves.')
            return
        }
        $resolved = $null
        try { $resolved = $item.Target } catch { $resolved = $null }
        if ($resolved -is [array]) { $resolved = $resolved[0] }
        if ((Normalize-LinkTarget ([string]$resolved)) -ieq $TargetDir.TrimEnd('\')) {
            Write-Host ('link already in place: ' + $linkPath)
            return
        }
        Remove-LinkOnly $linkPath
        Write-Host ('removed the previous link: ' + $linkPath + ' (it pointed at ' + $resolved + ')')
    }

    New-Item -ItemType Junction -Path $linkPath -Target $TargetDir | Out-Null
    Write-Host ('created junction: ' + $linkPath + ' -> ' + $TargetDir)
}

# ---------------------------------------------------------------- main

$DshHome = Resolve-DshHome $DshHome
$DshCli = Resolve-DshCli

Write-Host '==> dsh-multi-window install'
Write-Host ('    profile : ' + $Profile)

$profileDir = Join-Path $DshHome ('profiles\' + $Profile)
if (-not (Test-Path -LiteralPath $profileDir -PathType Container)) {
    Fail ('profile directory not found: ' + $profileDir + '. Check -DshHome / -Profile, or start the DSH desktop app once to create the profile.')
}
$packageJson = Join-Path $profileDir 'package.json'
if (-not (Test-Path -LiteralPath $packageJson -PathType Leaf)) {
    Fail ('no package.json in the profile directory: ' + $packageJson + '. Start the DSH desktop app once to initialize this profile.')
}
if (-not (Test-Path -LiteralPath $PluginDir -PathType Container)) {
    Fail ('plugin directory not found: ' + $PluginDir)
}
if (-not (Test-Path -LiteralPath (Join-Path $PluginDir 'package.json') -PathType Leaf)) {
    Fail ('no package.json in the plugin directory: ' + (Join-Path $PluginDir 'package.json'))
}

Write-Host ('    plugin dir : ' + $PluginDir)
Write-Host ('    profile dir: ' + $profileDir)
if (Test-DshCli $DshCli) {
    Write-Host ('    dsh cli    : ' + $DshCli)
} else {
    Write-Host '    dsh cli    : not found (set DSH_CLI or add dsh to PATH); using the JSON fallback'
}

try {
    $state = Get-InstalledState $packageJson
} catch {
    Fail ('cannot read package.json: ' + $_.Exception.Message)
}

$needsInstall = -not ($state.HasDependency -and $state.HasBundle)
if ($needsInstall -and ($state.HasDependency -or $state.HasBundle)) {
    Write-Host 'incomplete installation detected (only one of dependencies / dsh.profile.bundles is present); this run completes it.'
}

$cliAvailable = Test-DshCli $DshCli

if ($DryRun) {
    Write-Host ''
    Write-Host '[DryRun] no file is written and the CLI is not invoked. Plan:'
    if ($needsInstall) {
        Write-Host ('  1) back up: ' + $packageJson + ' -> package.json.bak.<yyyyMMddHHmmss>')
        if ($cliAvailable) {
            Write-Host ('  2) primary: ' + $DshCli + ' plugin --profile ' + $Profile + ' add "' + $LinkValue + '"')
        } else {
            Write-Host '  2) primary: skipped (CLI not found)'
        }
        Write-Host '  3) fallback (only when the primary path fails) edits these JSON fields:'
        Write-Host ('       dependencies["' + $PluginName + '"] = "' + $LinkValue.Replace('\', '\\') + '"')
        Write-Host ('       dsh.profile.bundles += "' + $PluginName + '"')
        Write-Host ('       node_modules\' + $PluginName + ' -> ' + $PluginDir + ' (junction)')
    } else {
        Write-Host '  1) 2) 3) plugin steps skipped: already installed'
    }
    Write-Host '  4) window runtime: not built here; the Host derives it from its own Electron payload on the first window'
    Write-Host ('  current state: dependencies has the package = ' + $state.HasDependency + '; bundles has the package = ' + $state.HasBundle)
    Write-Host ''
    Write-Host 'DryRun finished, nothing was changed.'
    exit 0
}

$backupPath = $null
if ($needsInstall) {
    $backupPath = Backup-PackageJson $packageJson

    $installed = $false

    if ($cliAvailable) {
        Write-Host 'calling the DSH CLI (link: local directory) ...'
        $result = Invoke-DshCli -Cli $DshCli -Arguments @('plugin', '--profile', $Profile, 'add', $LinkValue)
        if ($result.ExitCode -eq 0) {
            try {
                $state = Get-InstalledState $packageJson
            } catch {
                $state = [pscustomobject]@{ HasDependency = $false; HasBundle = $false }
            }
            if ($state.HasDependency -and $state.HasBundle) {
                Write-Host 'CLI install succeeded.'
                $installed = $true
            } else {
                Write-Warning 'the CLI reported success but dependencies / bundles are incomplete; the fallback path completes the install.'
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

    if (-not $installed) {
        Write-Host 'fallback: editing package.json and creating the junction ...'
        try {
            $json = Read-ProfileJson $packageJson

            if ($null -eq $json.PSObject.Properties['dependencies']) {
                Set-JsonProperty -Node $json -Name 'dependencies' -Value ([pscustomobject]@{})
            }
            Set-JsonProperty -Node $json.dependencies -Name $PluginName -Value $LinkValue

            if ($null -eq $json.PSObject.Properties['dsh']) {
                Set-JsonProperty -Node $json -Name 'dsh' -Value ([pscustomobject]@{})
            }
            if ($null -eq $json.dsh.PSObject.Properties['profile']) {
                Set-JsonProperty -Node $json.dsh -Name 'profile' -Value ([pscustomobject]@{})
            }
            if ($null -eq $json.dsh.profile.PSObject.Properties['bundles']) {
                Set-JsonProperty -Node $json.dsh.profile -Name 'bundles' -Value @()
            }
            $bundles = Get-BundleList $json
            if ($bundles -notcontains $PluginName) {
                $bundles = @($bundles) + $PluginName
            }
            Set-JsonProperty -Node $json.dsh.profile -Name 'bundles' -Value $bundles

            Write-JsonFile -Path $packageJson -Node $json
            Write-Host ('written: ' + $packageJson)
        } catch {
            Fail ('cannot rewrite package.json: ' + $_.Exception.Message + ' (backup at ' + $backupPath + ', restore it by hand)')
        }

        try {
            Ensure-PluginJunction -ProfileDir $profileDir -TargetDir $PluginDir
        } catch {
            Fail ('cannot create the junction: ' + $_.Exception.Message)
        }
    } else {
        Ensure-PluginJunction -ProfileDir $profileDir -TargetDir $PluginDir
    }

    try {
        $state = Get-InstalledState $packageJson
    } catch {
        Fail ('cannot re-read package.json for verification: ' + $_.Exception.Message)
    }
    if (-not ($state.HasDependency -and $state.HasBundle)) {
        Fail ('verification failed: dependencies has the package = ' + $state.HasDependency + ', bundles has the package = ' + $state.HasBundle + '. Backup at ' + $backupPath)
    }
} else {
    Write-Host 'plugin already installed, the profile is left untouched.'
    Try { Ensure-PluginJunction -ProfileDir $profileDir -TargetDir $PluginDir } catch { Write-Warning ('cannot refresh the junction: ' + $_.Exception.Message) }
}

Write-Host ''
Write-Host 'Install finished. The window runtime needs no setup: the Host builds it from'
Write-Host 'its own Electron payload the first time a window is opened.'
Write-Host 'Next: restart the DSH desktop app, then right-click any conversation and choose "Open in new window".'
exit 0
