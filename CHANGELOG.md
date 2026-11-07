# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.1.0 — 2026-11-07

### Added

- **Open in new window** entry in the Session context menu: one native Electron window
  per Session, loading the same DSH frontend with nothing trimmed.
- `GET /api/multi-window.open` raises a window and answers `{url, session, pid, focused}`.
  Choosing a Session whose window is still alive focuses that window instead of
  opening a second one.
- The window title follows the Session's `displayTitle` and is locked against
  later page-title changes.
- Windows stagger their positions automatically, derived from a hash of the
  session id, and are clamped to the screen.
- Window chrome — title bar, menu bar and background — follows DSH's own light/dark
  theme rather than the operating system's.
- One browser profile directory per window, so sign-in state, local storage and
  scroll position stay independent.
- The client anchors a new window to its Session with a bounded correction loop
  (300ms interval, 8s budget; stops after 3s of stability or on the first user
  gesture).
- Runtime bootstrap on first use: the Host's own Electron payload is hard-linked
  into the system temporary directory, falling back to copying where links are
  refused. No network access, no build step, and the package ships no binaries.
- Links opened inside a window are handed to the default system browser.
- `scripts/install.ps1` and `scripts/uninstall.ps1` with profile backup, a
  CLI-first install path and a `package.json` fallback.
- Documentation in Chinese and English.
