# Vendored: basecamp/omarchy shell/Commons + shell/Ui

- Source: https://github.com/basecamp/omarchy
- Ref requested: `quattro`
- Commit: `b5589faaf80c6f87c07d4560fca37c4a81722f28`
- Commit date: 2026-09-11T02:57:36Z
- Vendored: 2026-09-11T19:17:11Z
- Files: 42
- Re-vendor with: `tools/vendor-omarchy-shell.sh` (or `OMARCHY_REF=<ref> tools/vendor-omarchy-shell.sh`)

## Layout

`shell/Commons/*` -> `qml/vendor/qs/Commons/*`
`shell/Ui/*` -> `qml/vendor/qs/Ui/*`

(the `shell/` prefix is dropped; `qmldir` in each directory declares the
module as `qs.Commons` / `qs.Ui`, matching what Omarchy plugins `import`.)

## Patches applied on top of upstream

None. Every vendored file loads under the gallery-qml shim (qml/shim/) as
shipped upstream -- see qml/README.md for what the shim provides and what a
handful of qs.Ui files reference but never get compiled by the plugins this
host targets (KeyboardPanel.qml, SpeedTestOverlay.qml, PopupCard.qml,
Panel.qml and a few others reach further into layer-shell-only Quickshell
APIs -- WlrLayer, WlrKeyboardFocus, ExclusionMode, IpcHandler, QsWindow --
that are not shimmed; those files simply are never imported by RadioAtlas.qml
or gallery.qml-demo, and QML only compiles a module file when something
actually references its type, so this is inert rather than papered over).

## Runtime path note

Commons/Color.qml and Commons/Style.qml read the active theme from
`Quickshell.env("HOME") + "/.local/state/omarchy/current/theme"`
(colors.toml, shell.toml) as of this vendor's commit -- this is what the
Gallery installer needs to point `~/.local/state/omarchy/current/theme` at
(a symlink to the active Gallery theme), not `~/.config/omarchy`. Confirm
against Commons/Color.qml's `currentThemePath` property after any re-vendor,
since Omarchy has moved this path before.
