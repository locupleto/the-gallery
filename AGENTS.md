# Working on The Gallery

This file is for changing The Gallery's source. To customize an installed
Gallery (keys, tiling, themes, terminals), use the end-user skill in
[`agents/skills/gallery/`](agents/skills/gallery/SKILL.md) instead; the
installer links it into the agents' skill folders.

## Layout

- `install.sh`: the installer and uninstaller. It copies the repo into place
  (`~/bin`, `~/.config/gallery`, `~/.config/skhd`, `~/.hammerspoon`),
  records every file in `state/install-manifest.tsv`, backs up what it
  replaces (`.gallery-bak`) and runs `tiler/install.sh` first.
  `tools/install-lib.sh` holds the shared backup and manifest helpers.
- `tiler/`: yabai, skhd and JankyBorders: `yabairc`, `tiler.skhd`, `learn`
  (the Learn sheets and key sheet), `tree-guard`, `yabai-layout`, and the
  templates for the user's `local.skhd`, `yabairc.local` and `rules.local`.
- `bin/gallery`: the CLI; one bash file with a section per verb. The other
  `bin/gallery-*` helpers open terminal windows (`gallery-term`, `-tui`,
  `-menu`), start the coding agent (`gallery-agent`), run the QML host
  (`gallery-qml`) and talk to Hammerspoon (`gallery-hs`).
- `Gallery.spoon/`: the Hammerspoon side (plugin host, IPC, watchers).
- `plugins/gallery.*`: the bundled plugins; `skhd/gallery.skhd` their keys.
- `themes/`: the themes vendored from Omarchy (`colors.toml` only);
  `tools/render-theme.py` renders a theme into every target.
- `qml/`, `patches/`: the Quickshell shim for unmodified Omarchy QML plugins
  and the macOS overrides for imported ones.
- `agents/skills/gallery/`: the end-user agent skill.
- `docs/`: the user documentation. `tools/screenshots/take.sh` regenerates
  the README images.

## Tests

`tests/run.sh` runs everything: syntax checks, the Hammerspoon Lua tests and
every `tests/*_test.sh`. It needs the Gallery installed, Hammerspoon running
and the screen unlocked (`tui_test` and `qml_test` drive real windows; a
locked screen makes new windows invisible to yabai). The other shell suites
run offline on their own, e.g. `bash tests/install_test.sh`.

Add or update a test with every behaviour change, and run the affected suites
before committing; a piped `| tail` hides a failing exit code.

## Rules

- **Never touch the real desktop from a test.** Tests use a temporary
  `$HOME` and stubs. `defaults` writes the real preferences whatever `$HOME`
  says, so tests go through `GALLERY_DEFAULTS_BIN` (`tests/fake-defaults`).
- **Never restart yabai** as a side effect: `tiler/install.sh` restarts it
  only when its effective config changed. A restart loses every Desktop's
  layout.
- **`pgrep -u "$(id -u)" -a`** for every process lookup: without `-u` another
  logged-in user's process counts; without `-a` macOS hides the caller's own
  parents (an install run from iTerm2 cannot see iTerm2). `offon_test`
  enforces both.
- **The user's files are sacred.** `local.skhd`, `yabairc.local`,
  `rules.local`, `state/*.json`, the user's themes, hooks and plugins are
  never overwritten; the installer backs up anything it replaces and the
  uninstaller puts it back. Anything new the installer writes outside
  `~/.config/gallery` must be recorded and removed again on uninstall.
- **Docs change with the code**, in the same commit: README, `docs/`, and the
  agent skill when a user-facing command or file changes.
- Shell: bash with `set -euo pipefail`, two-space indent, `local` variables,
  comments that say why. Match the surrounding code.
