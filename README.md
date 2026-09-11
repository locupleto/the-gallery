# The Gallery

A Hammerspoon Spoon that hosts manifest-driven desktop plugins (panels,
overlays, menus, services) on macOS. Modelled on Omarchy 4's plugin system:
each plugin is a directory with a `manifest.json` declaring its id, kinds,
and entry points, so plugins can be added and removed without touching
Gallery itself.

## What it is

- `Gallery.spoon` — the Hammerspoon Spoon that loads plugin manifests and
  manages plugin windows.
- `plugins/` — bundled plugins, each a self-contained directory.
- `bin/gallery` — a CLI for controlling Gallery from the shell.
- `themes/` — vendored Omarchy colour themes (see `themes/UPSTREAM.md`) plus
  `tools/render-theme.py`, which renders the active theme into CSS, JSON, an
  iTerm2 profile, and a shell fragment.

## Install

```sh
./install.sh
```

This copies the Spoon and bundled plugins onto the boot volume (see the
rationale comment in `install.sh` for why they are copied rather than
symlinked) and wires `~/.hammerspoon/init.lua` to load Gallery.

## Usage

```sh
gallery status | list [--json] | open <id> | close <id> | toggle <id> |
gallery enable <id> | disable <id> | validate <dir> |
gallery add <git-url> [--enable] [--yes] | update [id] | remove <id> [--yes] |
gallery clone <id> <new-id> |
gallery theme list | current | set <name> | render | next |
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

Run `gallery` with no arguments, or see `bin/gallery`, for the full verb
list.

## Documentation

Full design notes and decisions live in the Obsidian vault, under
`Projects/The-Gallery/`. This README stays short on purpose.
