# The Gallery

An Omarchy-style desktop for macOS. Three parts, in the order they matter
day to day:

1. **Tiling.** yabai + skhd with left Option as "super", Omarchy's key
   bindings, a JankyBorders outline on the focused window, and a Learn menu
   of cheat sheets (`tiler/`).
2. **Themes.** Omarchy's colour themes rendered onto everything at once:
   iTerm2, the focus outline, the wallpaper, Übersicht widgets, the font.
3. **Plugins.** A Hammerspoon Spoon that hosts manifest-driven plugins
   (floating TUIs, services, unmodified Omarchy QML plugins), modelled on
   Omarchy 4's plugin system: each plugin is a directory with a
   `manifest.json`, so plugins come and go without touching Gallery itself.

## What it is

- `tiler/` — yabai + skhd tiling and hotkeys (left Option as "super"),
  JankyBorders, and the Learn cheat-sheet menu. See `tiler/README.md`.
- `themes/` — vendored Omarchy colour themes (see `themes/UPSTREAM.md`) plus
  `tools/render-theme.py`, which renders the active theme into CSS, JSON, an
  iTerm2 profile, and a shell fragment.
- `Gallery.spoon` — the Hammerspoon Spoon that loads plugin manifests and
  manages plugin windows.
- `plugins/` — bundled plugins, each a self-contained directory.
- `bin/gallery` — a CLI for controlling Gallery from the shell.

## Install

```sh
./install.sh
```

This copies the Spoon and bundled plugins onto the boot volume (see the
rationale comment in `install.sh` for why they are copied rather than
symlinked) and wires `~/.hammerspoon/init.lua` to load Gallery.

On a new Mac, before running it: Homebrew, a GitHub SSH key, iTerm2 and
Hammerspoon (`brew install --cask iterm2 hammerspoon`; the installer refuses
to run without Hammerspoon.app), and the Obsidian vault synced (the Learn
menu reads its sheets from it). Optional but wanted for the full experience:
`brew install chafa btop uv` (picker previews, sysmon, the `qml` kind). The
script itself installs yabai, skhd, JankyBorders, fzf and glow, copies
everything it needs onto the boot volume, renders the current theme, and
starts Hammerspoon; the stock `/bin/bash` 3.2 is enough. macOS then asks for
Accessibility (Hammerspoon, yabai, skhd) and a few Automation grants by
hand; `gallery doctor` lists what is still missing. The step-by-step
walkthrough, validated on a second Mac, is the vault note
`Projects/The-Gallery/Installing-On-A-New-Mac.md`. Updating later is `git
pull` followed by the same `./install.sh`.

## Tiling and hotkeys

`install.sh` installs the tiler first (yabai, skhd, JankyBorders, Learn) via
`tiler/install.sh`, then copies the Gallery's own key bindings into place.
skhd is the only hotkey grabber on the system: Gallery bindings live in
`skhd/gallery.skhd`, included by `tiler/skhdrc` with `.load "gallery.skhd"`,
so the Gallery never registers its own hotkeys. Pass `--skip-tiler` to
`install.sh` to skip the tiler step (e.g. on a machine that should run only
the plugin host and theming). See `tiler/README.md` for the full key table,
Learn, and the once-per-machine manual steps (Accessibility, Mission Control
shortcuts, Secure Keyboard Entry).

## Usage

```sh
gallery status | list [--json] | open <id> | close <id> | toggle <id> |
gallery enable <id> | disable <id> | validate <dir> |
gallery add <git-url> [--enable] [--yes] | update [id] | remove <id> [--yes] |
gallery clone <id> <new-id> |
gallery theme list | current | set <name> | render | next |
gallery bg list | current | set <file> | next | prev | apply |
gallery console status | theme | native | toggle |
gallery font status | set <family> [size] [weight] | native | list |
gallery widgets status | available | theme | native | toggle |
gallery borders status | width <n> | bright on|off|toggle |
gallery home show | save [--roam A,B] [--dry-run] | apply |
gallery reload | log | doctor | install
```

`add`, `update`, `remove`, and `clone` mirror Omarchy's `plugin` verbs:
`add` clones a plugin from git into `~/.config/gallery/plugins`, `update`
fast-forwards git-managed plugins, `remove` disables and deletes (or
archives) one, and `clone` duplicates an installed plugin under a new id.

`theme set <name>` atomically points `~/.config/gallery/themes/current` at
the named theme, re-renders it (CSS/JSON/iTerm profile/shell fragment via
`tools/render-theme.py`), runs every executable in
`~/.config/gallery/hooks/theme-set.d/` with the theme name as its argument,
and asks the running Spoon to reload over IPC. `theme next` does the same
for the alphabetically next installed theme, wrapping around. `theme
render` just re-runs the renderers for the current theme, without touching
hooks or the Spoon. Themes come from `themes/` (vendored via
`tools/vendor-omarchy-themes.sh`) plus anything a user drops into
`~/.config/gallery/themes/` by hand.

`bg ...` records a per-theme wallpaper choice in
`~/.config/gallery/state/backgrounds.json` and applies it through the
`30-wallpaper.sh` hook; `bg next`/`prev` cycle the current theme's
`backgrounds/` directory. Because macOS only lets a script set the picture
of the *visible* Space, the hook then walks every Space with yabai (skipping
native-fullscreen ones) and applies it on each before returning you to where
you were; `GALLERY_WALLPAPER_WALK=0` keeps it to the visible Space.

`console ...` decides whether your everyday iTerm2 terminal follows the
theme. The renderer writes a second dynamic profile,
`~/Library/Application Support/iTerm2/DynamicProfiles/gallery-console.json`
("Console"), declared as a child of your own "Default" profile, so it
inherits font, keys and every other setting. In `native` mode the file
carries no colour keys and Console is identical to Default; in `theme` mode
it carries the active theme's colours, and iTerm pushes the change into
already-open windows. The mode is stored in
`~/.config/gallery/state/console.json` and re-applied on every `theme
set`/`next`/`render`. Inside the theme picker, `ctrl-t` toggles it.

One-time iTerm2 setup, by hand: Settings (Cmd-,) > Profiles > select
"Console" in the profile list > "Other Actions..." > "Set as Default". The
default profile shows a star in the list; `gallery console status` prints
`default profile: Console (ok)` once it has taken. Writing the
`Default Bookmark Guid` preference from the shell is not honoured while
iTerm runs, so the CLI never tries.

`font ...` records a single Gallery-wide monospace font preference in
`~/.config/gallery/state/font.json` (`{"family", "size", "weight"}`;
missing means "native" -- no font opinion, everything inherits its host's
own default font exactly as before this feature existed). `font set
<family> [size] [weight]` validates the family against `fc-list` (size
defaults 13, weight Regular), records it, and re-renders; `font native`
clears it. The renderer resolves the family/weight to the PostScript name
iTerm2's "Normal Font" profile key wants (via `fc-list`) and adds it to
both the floating Gallery profile and the Console profile (theme mode
only), alongside `"Use Non-ASCII Font": false` so Nerd Font glyphs come
from the same face; if resolution fails it warns to stderr and renders
without a font opinion rather than crashing. `font list` shows installed
Nerd Fonts. The QML plugin host (`qml/host.py`) reads the same file and,
when a family is set and installed, puts it first in the "monospace" alias
fallback list it already resolves Omarchy's icon font from.

`widgets ...` does the same for the Übersicht crystal widgets
(locupleto/crystal-widgets-v2), and is just as optional: `native` (the
default) leaves them on their own shipped colours, `theme` swaps their
static white for the theme's lightest foreground and their CPU/mem/swap bar
fill for the accent. The renderer writes `~/.config/gallery/state/crystal.css`
(CSS custom properties, empty in native mode) which the widgets'
`crystal-theme.widget` injects into the widget document every couple of
seconds, and adds `CRYSTAL_BAR_COLOR` to `theme.sh` in theme mode only. The
mode lives in `~/.config/gallery/state/widgets.json`. The theme picker shows
a "Widgets: ..." line and binds `ctrl-u` to toggle it, but only while
Übersicht is running with those widgets on this Mac (`gallery widgets
available`); elsewhere the picker never mentions them.

`borders ...` controls the focused-window frame JankyBorders draws
(`bin/gallery-borders`). The active colour follows Omarchy's own rule: a
theme's `hyprland_active_border` in `colors.toml` if it defines one, else
`accent`, with gradients (and their angle) honoured via JankyBorders' own
`gradient(top_left=...,bottom_right=...)` syntax. Width is 1-12 (default
5); "bright" mixes every active-border colour toward the theme's
`bright_foreground` (falling back to `light_foreground`, then
`foreground`) at a fixed ratio. Both prefs live in
`~/.config/gallery/state/borders.json` and are re-applied on every theme
render. Inside the theme picker, `ctrl-w` cycles width through the presets
3/5/8/12 and `ctrl-b` toggles bright.

Run `gallery` with no arguments, or see `bin/gallery`, for the full verb
list.

## Documentation

Full design notes and decisions live in the Obsidian vault, under
`Projects/The-Gallery/`. This README stays short on purpose.
