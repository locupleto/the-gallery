# Terminals, plugins, the agent and the rest

## Terminals

```sh
gallery console status           # whether terminals follow the theme
gallery console theme | native   # follow the theme, or their own colours
gallery console close ask|never  # whether terminal windows ask before closing
gallery terminal list | set <name>   # iterm2, ghostty, kitty, wezterm
gallery font list | set <family> [size] [weight] | native
gallery glass set 0.2 12         # transparency 0-0.9, blur 0-64
gallery glass default
```

The Gallery never rewrites a terminal's own settings beyond one include line
(Ghostty, kitty) and, for iTerm2, its "Console" profile, default profile and
window style, all given back by `console native`, `gallery off` and
uninstalling. iTerm2 changes wait until iTerm2 quits (a running iTerm2 undoes
outside changes). Do not edit the generated files under
`~/.config/gallery/state/terminals/`.

## Plugins

```sh
gallery list                     # installed plugins and their state
gallery enable <id> | disable <id>
gallery open | close | toggle <id>
gallery add <git-url>            # install another plugin
gallery remove <id>
gallery clone <id> <new-id>      # to change a bundled plugin, clone it first
```

Bundled plugins (`gallery.*`) are synced on every update; change a clone
instead. Writing a plugin: `docs/PLUGINS.md`.

## The coding agent

```sh
gallery agent status             # agent, start folder, command
gallery agent set <name>         # claude, gemini, opencode, codex, copilot, crush
gallery agent set <name> --command "<command line>"
gallery agent dir <folder>       # where it starts; --clear goes back to ~/Work
```

The built-in agents start in their "do not ask" mode, in the start folder.

## Learn sheets

super + space opens Learn. Markdown files in `~/.config/gallery/sheets/` are
the user's sheets (`Tiler-Keys.md` is generated from the key files; do not
edit it).

## Off and on

`gallery off` puts windows back where they were before tiling and stops
tiling, outline and keys until `gallery on` (shift + ctrl + super + escape
toggles). Only on the user's request.

## Diagnosis

- `gallery doctor`: every check, with a hint for anything missing.
- `gallery status`, `gallery log`.
- A key does nothing: `skhd --observe`; Secure Keyboard Entry in the
  terminal; the Mission Control "Switch to Desktop N" shortcuts for super + N.
- Windows not tiling or invisible to yabai: `gallery ghosts`; a locked screen
  makes new windows invisible until relaunched.
- More in `docs/FAQ.md` and `docs/INSTALL.md` (Troubleshooting).
