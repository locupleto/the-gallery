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

## Install

```sh
./install.sh
```

This copies the Spoon and bundled plugins onto the boot volume (see the
rationale comment in `install.sh` for why they are copied rather than
symlinked) and wires `~/.hammerspoon/init.lua` to load Gallery.

## Usage

```sh
gallery status
gallery list
gallery open gallery.hello
gallery toggle gallery.hello
gallery doctor
```

Run `gallery` with no arguments, or see `bin/gallery`, for the full verb
list.

## Documentation

Full design notes and decisions live in the Obsidian vault, under
`Projects/The-Gallery/`. This README stays short on purpose.
