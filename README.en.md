# dsh-multi-window

Open any DSH conversation in its own native window, so several conversations
can be watched at the same time.

> 中文: [README.md](./README.md)

## What it does

The DSH desktop shell manages a single main window. This plugin adds
**Open in new window** to a Session's context menu. Choosing it makes the Host
spawn a separate Electron window that loads the *same* Web UI, anchored to the
Session you picked through `#dsh-window=<session id>`.

The window has its own process and its own user-data directory: closing it does
not affect the main window, and vice versa.

## Features

- The window is the **complete, interactive DSH UI** - sidebar, plugins, skills,
  scheduled tasks, context insights, every button. Nothing is trimmed, because
  it loads the same frontend.
- **The window title is the Session title.** The client reads `displayTitle` from
  `sessions.list` and passes it through the URL hash; later page-title updates are
  suppressed so the title stays put.
- **Windows stagger automatically**: FNV-1a over the session id picks one of 36
  slots, 40px apart, clamped to the screen.
- **One `--user-data-dir` per window**, so localStorage, sign-in state and scroll
  position never collide.
- Choosing the same Session twice focuses the existing window instead of opening
  a second one.
- Links inside the window open in the system browser.

### Anchoring is not a one-shot switch

A new window has no stored selection of its own, so its boot navigation can
overwrite the Session this plugin selected. The client therefore corrects for a
bounded period: it re-checks every 300ms for up to 8s and stops once the target
has held for 3s. The first click or keypress in the window ends the correction
immediately, so a deliberate switch is never taken back. See
`CORRECT_DEADLINE_MS` / `CORRECT_INTERVAL_MS` / `CORRECT_HOLD_MS` in `lib/client.js`.

## Install

Requires the **Windows desktop client** (Windows 10 / 11), **DSH desktop client
0.2.1-rc.5 or newer**, and Node.js 20+ (bundled with DSH, nothing to install
separately).

### Option A: plugin marketplace (recommended)

Search for `dsh-multi-window` in the DSH plugin marketplace and install it in one click.

### Option B: command line

```powershell
dsh plugin add dsh-multi-window
```

If the `dsh` command is unavailable, `scripts/install.ps1` falls back to editing
the profile's `package.json` and creating a junction:

```powershell
.\scripts\install.ps1                 # install into the desktop profile
.\scripts\install.ps1 -DryRun         # print the plan, change nothing
```

The scripts hard-code no paths: the CLI comes from `DSH_CLI` then `PATH`, the DSH
home from `DSH_HOME` then `%USERPROFILE%\.dsh`, both overridable with
`-Profile` / `-DshHome`.

**Restart the DSH desktop app** after installing so the plugin is loaded.

> The plugin locates the Electron payload through `process.execPath` pointing at
> the DSH installation, so the command-line **`dsh web` mode is not supported** —
> there the process is not the desktop client and there is no payload to link.

### The window runtime builds itself

This package ships **no binaries** and needs no build step. The DSH Host already
runs as `ELECTRON_RUN_AS_NODE=1 <app exe>`, so `dirname(process.execPath)` is
already the complete Electron payload. On the first window it is hard-linked into
the system temporary directory:

```
%TEMP%\dsh-multi-window-runtime\
  dsh-window.exe          <- hard link to the DSH executable
  *.pak *.dll *.dat ...   <- hard links to the same payload
  locales\                <- junction
  resources\app\main.js   <- written from this package's lib/window-main.js
```

That is why the package is a few dozen KB, works on any machine, and costs no
extra disk (a hard link copies no data). Where the filesystem or a security
policy refuses hard links, the files are copied instead and windows still work.

## Uninstall

```powershell
dsh plugin remove dsh-multi-window
```

The runtime and the per-Session temporary profiles are kept by default; the
repository's `scripts/uninstall.ps1` can remove them (`-RemoveRuntime`,
`-RemoveProfiles`).

## Verify

1. Restart DSH; `dsh-multi-window` appears under Settings -> Plugins.
2. Right-click a Session; the menu offers **Open in new window**.
3. The new window's title bar shows that Session's title and its content is that
   Session.
4. Open a second Session; the two windows stagger and title themselves apart.
5. Close the window; the main window is unaffected.

Backend check (copy the token from the main window's address bar):

```powershell
curl.exe "http://127.0.0.1:<port>/api/multi-window.open?session=<sessionId>&title=<title>&token=<token>"
# first call: {"url":"...","session":"...","pid":1234,"focused":false}
# same Session again: {"...","focused":true} (focuses the existing window)
```

## How it works

1. **Node half** (`lib/index.js`) serves `GET /api/multi-window.open`: it
   validates the query, builds the Host's own authenticated URL with
   `connection.authenticatedUrl()`, writes `dsh-window` + `title` into the hash,
   makes sure the runtime exists, spawns the sidecar and answers with
   `{url, session, pid, focused}`. The spawn passes
   `--no-sandbox --user-data-dir=<profile>` and removes the inherited
   `ELECTRON_RUN_AS_NODE`.
2. **Sidecar** (`lib/window-main.js`, materialised as `resources\app\main.js`) is
   a minimal Electron main process: parse the URL, title from the hash, position
   from the hash, menu, follow the page theme, load.
3. **Client half** (`lib/client.js`) adds the context-menu row, calls the route,
   and in a window raised that way anchors itself to the Session.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| The window flashes and exits | The sidecar needs `--no-sandbox`, and the inherited `ELECTRON_RUN_AS_NODE` must be removed - the Host runs under it and a child would start as Node instead of Electron. `spawnWindow` does both; a hand-started exe must too. This is a host constraint, not a preference |
| 503 `the window runtime is unavailable` | The runtime could not be built. Check the `hint` in the response: usually the temp directory is not writable, or `DSH_MULTI_WINDOW_EXE` points nowhere |
| Blank window | The sidecar cannot reach the Host. Check that the reported `pid` is alive and the main window can reach the same address |
| Title is `DSH Window` | The hash carried no `title` (the Session has none yet); the page title takes over. Reopen the window |
| Windows pile up in the middle | Positions come from 36 hash slots; collisions overlap. Drag one aside |
| Appearance lags after a DSH upgrade | The runtime is hard-linked, so it follows the Host. If the Host moved to another directory, delete `%TEMP%\dsh-multi-window-runtime` and reopen a window |
| Want a different runtime | Set `DSH_MULTI_WINDOW_EXE` to any Electron executable; it wins |

## Known limits

- A **blank Session** opens on the "explore" welcome page. That is how DSH renders
  an empty Session, not a failed anchor.
- Windows default to **1280x820 (min 520x600)** and open on the **primary** display.
- Tokens are regenerated when DSH restarts, so **already-open windows must be
  reopened**.
- Side-by-side conversations inside one window are not implemented.

## Publishing

Source repository: [github.com/JohnshyCY/dsh-multi-window](https://github.com/JohnshyCY/dsh-multi-window).

```powershell
npm publish
```

## License

[MIT](./LICENSE)
