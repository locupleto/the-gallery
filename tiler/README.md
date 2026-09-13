# tiler/ — the Gallery's tiling layer: yabai + skhd (optional)

This is The Gallery's tiling and hotkey layer -- "Omarchy on macOS" for window
management. [yabai](https://github.com/asmvik/yabai) tiles windows
automatically (binary space partitioning, gaps, the 7:5 house split) and
[skhd](https://github.com/asmvik/skhd) adds keyboard control with **left
Option as "super"**, the same muscle memory as Hyprland. JankyBorders draws a
crisp accent outline around the focused window, following the active Gallery
theme when the Gallery is installed. The Learn sheet (`super + space`) is
Omarchy's cheat-sheet menu, rebuilt on this desk -- see "Learn" below.

## Install

```bash
tiler/install.sh              # brew install yabai + skhd, copy the rc files, start services
tiler/install.sh --dry-run    # show what it would do
tiler/install.sh --uninstall  # stop both, remove the rc files (formulas stay)
```

`./install.sh` at the Gallery root runs this as its first step (unless given
`--skip-tiler`), so on a fresh machine one command installs tiling, hotkeys,
theming and the plugin host together; `tiler/install.sh` still works
standalone, with the same flags, for a tiling-only setup or a quick refresh
after editing `yabairc`/`skhdrc`.

Then, once per machine:

1. **Accessibility** for `yabai` and `skhd` (System Settings → Privacy &
   Security → Accessibility; both prompt on first start). Restart each service
   after ticking: `yabai --restart-service; skhd --restart-service`.
2. **Mission Control shortcuts**: System Settings → Keyboard → Keyboard
   Shortcuts… → Mission Control → enable *Switch to Desktop N* for every
   Desktop you use. super+N and super+shift+N are built on these Ctrl+N
   shortcuts because yabai cannot switch Spaces without the scripting addition.
3. **iTerm → Secure Keyboard Entry off**, otherwise skhd is blind while iTerm
   is frontmost.

Prerequisites checked by the script: *Displays have separate Spaces* on,
*Automatically rearrange Spaces* off, no Magnet/Rectangle running.

**Not installed on purpose:** the scripting addition (`yabai --load-sa`,
sudoers entry, partially disabled SIP). It only adds Space switching/creation,
animations and opacity, which this setup does not need. SIP stays enabled.

## Keys (left Option = super)

| keys | action |
|---|---|
| super + h / j / k / l | focus west / south / north / east (continues onto the next display) |
| super + shift + h / j / k / l | swap the window in that direction (moves to the next display at the edge) |
| super + 1 … 9 | switch to Space N (via Ctrl+N) |
| super + shift + 1 … 9 | send the window to Space N and follow |
| super + shift + s | send the window to the other display and follow |
| super + tab | focus the previous window |
| super + f | toggle zoom (window fills its display) |
| super + t | toggle float (a floated window lands centred) |
| super + shift + e | toggle split direction |
| super + r | rotate the tree 90° |
| super + b | new window in the default browser (first press: allow "skhd wants to control System Events") |
| super + shift + b | balance all tiles |
| super + s | toggle stacked ⇄ tiled for the current Space |
| super + ← → ↑ ↓ | resize by 60 px |
| super + m | minimize |
| super + w | close window |
| super + return | new iTerm window (first press: allow "skhd wants to control iTerm2") |
| super + shift + r | restart yabai, reload skhd |
| super + a / shift + a | ChatGPT / Grok web apps |
| super + c | Calendar |
| super + e | Gmail web app |
| super + y | YouTube web app |
| super + x | X web app |
| super + g | Telegram (Omarchy's messaging slot) |
| super + space | Learn menu: pick a cheat sheet (first press: allow "skhd wants to control iTerm2") |
| super + shift + space | the tiler key sheet, generated from `skhdrc` |

Mouse: Option-drag moves a window, Option-right-drag resizes, dropping onto a
tile swaps.

### Swedish keyboard note

On the Swedish layout the Option key types `@` (⌥2), `|` (⌥7), `[` `]` (⌥8/9)
and `{` `}` (⌥⇧8/9). Only the **left** Option is bound here, so type those
symbols with the **right** Option — exactly like AltGr on Linux. Because of
that, the voice assistant's push-to-talk on the Studio is the **right
Command** key (`PTT_KEY=cmd_r` in its LaunchAgent), no longer right Option.

## Learn (cheat sheets on a key)

Omarchy's "Learn" menu, rebuilt on this desk. `tiler/learn` opens a
floating iTerm window, centred on the display that had focus when the key
was pressed (the script finds its own window by its `Learn: …` title and
moves, floats and centres it by id; a `yabairc` rule is the backup), with
an fzf list of the vault's `Cheat-Sheets` notes;
Enter renders the chosen one with glow, `q` or Esc closes. Three doors:

- **super + space** — the menu; **super + shift + space** — the tiler keys directly.
- **Spotlight → "Learn"** — `~/Applications/Learn.app`, a shell-script bundle
  built by `tiler/learn install` (first launch: allow "Learn wants to control iTerm2").

One source per sheet: the notes are read in place from the Obsidian vault
(`~/Library/Mobile Documents/iCloud~md~obsidian/Documents/ObsidianVault/Cheat-Sheets`,
override with `OBSIDIAN_VAULT` or `LEARN_SHEETS`), never copied, and an
evicted iCloud note is fetched first. The only generated sheet is
`Tiler-Keys.md`, written from the `## description` lines above each binding
in `skhdrc` — so keep those lines current; `tiler/install.sh` regenerates the
note and the app every run. Dependencies: `fzf`, `glow` (Homebrew, installed
by the script).

## Configuration

- `yabairc` → `~/.config/yabai/yabairc`: bsp layout, 8 px gaps, even splits
  (`split_ratio 0.5`; the 7:5 house grid is applied only when asked for a
  "column" by voice), new windows on the
  display under the pointer, and `manage=off` rules for System Settings,
  utilities, Finder dialogs and any non-standard window. Two signals
  (`window_destroyed`, `application_terminated`) refocus the window under the
  pointer, else the most recent one, whenever a close leaves no focused
  window — macOS otherwise parks focus on a windowless app after Cmd+W.
- `skhdrc` → `~/.config/skhd/skhdrc`: the table above.

Edit here, re-run `tiler/install.sh` (copies + reloads). The files are copied,
not symlinked: launchd-started yabai cannot read the external volume this repo
lives on.

## Upgrade / disable

```bash
yabai --stop-service; skhd --stop-service
brew upgrade yabai skhd
yabai --start-service; skhd --start-service   # re-tick Accessibility only if macOS asks
```

yabai ships a signed release binary, so its Accessibility grant survives
upgrades. skhd is compiled by Homebrew with an ad-hoc signature, so after
`brew upgrade skhd` expect to remove and re-add it in the Accessibility list.

Disable at any time with `yabai --stop-service`; see "Consumers" below for
what notices.

## Consumers

The one consumer outside this repo is the voice assistant (`ai_voice_assistant`).
Its `desktop.py` detects yabai at runtime (`DESKTOP_TILER=auto`) and routes
window-placement verbs through yabai while it is running, falling back to
System Events the moment yabai stops (`DESKTOP_TILER=off` forces that
fallback even while yabai runs). Its fast brain reads the generated
`~/.config/skhd/Tiler-Keys.md` key sheet, so voice verbs never drift out of
sync with the Learn menu. That is the only link between the two projects.
