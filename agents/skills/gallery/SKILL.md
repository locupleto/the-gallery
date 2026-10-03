---
name: gallery
description: >
  REQUIRED for customizing The Gallery, the Omarchy-style macOS desktop
  (yabai tiling, skhd keys, Hammerspoon, themes) installed on this Mac. Use
  when editing ~/.config/skhd/, ~/.config/yabai/ or ~/.config/gallery/, or
  when the user asks about keybindings, hotkeys, tiling, gaps, padding,
  window rules, which Desktop/Space an app lives on, the focus outline or
  border, themes, wallpapers, terminal colours, fonts, transparency/glass,
  the Learn key sheet, Gallery plugins, the coding agent's start folder,
  switching the Gallery off or on, or any `gallery` command. Not for
  working on The Gallery's own source code (see AGENTS.md in its repo).
---

# The Gallery

The Gallery turns macOS into an Omarchy-style desktop: yabai tiles the
windows, skhd provides the keys ("super" is the left Option key, `lalt` in
skhd files), JankyBorders draws the focus outline, Hammerspoon hosts the
plugins, and one theme colours the terminals, outline, wallpaper and TUIs.
Everything is driven by the `gallery` command in `~/bin`.

This skill is for changing an installed Gallery to suit its user. It is not
for developing The Gallery itself.

## The rules

1. **Look before you change.** Start with `gallery doctor` (health) and the
   matching status command (`gallery theme current`, `gallery home show`,
   `gallery borders status`, `gallery glass`, `gallery console status`,
   `gallery agent status`, ...). If the user asks for something you cannot
   find a place for, say so rather than inventing one.
2. **Change only the files that are the user's.** An update (`./install.sh`)
   overwrites the Gallery's own files. The user's places are:

   | What | Where |
   |---|---|
   | Keys | `~/.config/skhd/local.skhd` (loaded first, so it wins) |
   | Tiling settings and window rules | `~/.config/yabai/yabairc.local` |
   | Which Desktop an app lives on | `~/.config/yabai/rules.local`, written by `gallery home save` |
   | Preferences (font, glass, borders, terminal, agent, wallpaper...) | the `gallery` verbs, which write `~/.config/gallery/state/*.json` |
   | Own themes | a new directory under `~/.config/gallery/themes/` |
   | Theming other apps | a hook in `~/.config/gallery/hooks/theme-set.d/` |
   | Own plugins | `~/.config/gallery/plugins/<id>` (not `gallery.*`) |
   | Learn sheets | `~/.config/gallery/sheets/` (not `Tiler-Keys.md`) |

   Never edit `skhdrc`, `tiler.skhd`, `gallery.skhd`, `yabairc`, a shipped
   theme's `colors.toml`, a bundled `gallery.*` plugin or anything in `~/bin`:
   the next update replaces them. A `*.gallery-edited.<timestamp>` file means
   someone did; move that change into the matching user file.
3. **Prefer a `gallery` verb** over editing a file when one exists
   (`gallery borders width 8`, not editing state JSON).
4. **Never restart yabai** (`yabai --restart-service`, `super + shift + r`)
   without asking the user first. A restart rebuilds every window tree and
   loses the hand-tuned layout on every display. Apply settings live instead
   (see [tiling.md](tiling.md)). Do not run `./install.sh --uninstall`,
   `--purge` or `gallery off` unless the user asked for exactly that.
5. **Apply, then verify.** Changes to `local.skhd` load by themselves; yabai
   settings are applied with `yabai -m config ...`; themes with
   `gallery theme set`. Afterwards run `gallery doctor` and tell the user what
   changed, where, and how to undo it.

## Topic guides

Read the one that matches the request:

- [keys.md](keys.md): adding, changing or switching off a key; the key sheet
- [tiling.md](tiling.md): gaps, layout, floating apps, window rules, app
  homes on Desktops, the focus outline
- [theming.md](theming.md): themes, wallpapers, writing a theme, theming
  another app with a hook
- [terminals-and-more.md](terminals-and-more.md): terminal colours, font,
  glass, plugins, the coding agent, Learn sheets, switching off, diagnosis

The full user documentation is in the Gallery's repository, `docs/` (start
with `docs/CUSTOMIZING.md`), also online at
https://github.com/locupleto/the-gallery/tree/main/docs.

## Useful facts

- Desktops are macOS Spaces. yabai numbers them in one sequence across all
  displays (`yabai -m query --spaces`), so on a second display "Desktop 1"
  may be Space 10.
- `gallery off` restores the windows' pre-tiling positions and stops tiling,
  outline and keys until `gallery on` (it survives a restart).
- Logs: `gallery log` (Hammerspoon side), `~/.config/gallery/gallery-home.log`
  (the after-login home pass), `~/.config/gallery/gallery-ghosts.log`
  (windows yabai cannot see).
