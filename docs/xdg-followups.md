# XDG follow-ups

From the 2026-10-07 Projects-directory change (xdg-user-dirs 0.20 enables
`XDG_PROJECTS_DIR` by default; this repo now declares `xdg.userDirs` on all
four hosts and runs `xdg-user-dirs-update` as a user unit on dynhetz).
Audit of specifications.freedesktop.org against this repo:

Covered: basedir (`xdg.enable`, `xdg.configFile`, `xdg.stateHome` in
aid-web, `xdg-utils`), user-dirs.

## Worth doing

- `xdg-ninja` (nixpkgs, audit tool): scans `$HOME` for basedir violations,
  suggests fixes. Read-only. Run once per host, fix what it finds.
- `~/.local/bin` on PATH: basedir spec says distros should ensure it;
  `home.sessionPath` is unset everywhere here.
- Default terminal execution (`xdg.terminal-exec`, HM module + package in
  nixpkgs): declare foot in `xdg-terminals.list` on Linux hosts. Little
  reads it headless; pays off under any GUI.

## Situational

- `xdg.mimeApps` default apps: only matters where `xdg-open` runs with no
  DE (headless `xdg-open https://...`). Ignored on macOS.
- Trash spec + `trash-cli`: undo for `rm` in interactive shells. Needs an
  alias decision; not taken.
- Secret Service: agenix files already cover this better headless (no
  keyring-unlock problem). No action.

## Correctly N/A headless

Portals, autostart (the dynhetz user unit is its headless equivalent),
notifications, MPRIS, idle-inhibit, status-notifier, thumbnail,
recent-files, menu/icon/sound themes.

## Watch, don't adopt

Drafts `terminal-intent`, `intent-apps`, `global-shortcuts`. The first is
the eventual successor to `Terminal=true` handling; nothing implements
any of them yet.

## Known inconsistency

`xdg.userDirs.setSessionVariables` defaults by state version: true on
dynhetz/hetztop/cros (25.11), false on macbook (26.11). Set it explicitly
if uniformity matters; apps should use `xdg-user-dir` regardless.
