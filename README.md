# tiler/ — automatic tiling with yabai + skhd (optional)

The voice assistant places windows through System Events on its own. With
[yabai](https://github.com/asmvik/yabai) running, windows **tile themselves**
(binary space partitioning, gaps, the 7:5 house split) and the assistant's
desktop verbs talk to yabai instead — `desktop.py` detects it at runtime
(`DESKTOP_TILER=auto`). Stop yabai and everything falls back to System
Events; nothing else changes.

[skhd](https://github.com/asmvik/skhd) adds keyboard control with **left
Option as "super"**, the same muscle memory as Hyprland.

## Install

```bash
tiler/install.sh              # brew install yabai + skhd, copy the rc files, start services
tiler/install.sh --dry-run    # show what it would do
tiler/install.sh --uninstall  # stop both, remove the rc files (formulas stay)
```

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

Mouse: Option-drag moves a window, Option-right-drag resizes, dropping onto a
tile swaps.

### Swedish keyboard note

On the Swedish layout the Option key types `@` (⌥2), `|` (⌥7), `[` `]` (⌥8/9)
and `{` `}` (⌥⇧8/9). Only the **left** Option is bound here, so type those
symbols with the **right** Option — exactly like AltGr on Linux. Because of
that, the voice assistant's push-to-talk on the Studio is the **right
Command** key (`PTT_KEY=cmd_r` in its LaunchAgent), no longer right Option.

## Configuration

- `yabairc` → `~/.config/yabai/yabairc`: bsp layout, 8 px gaps, even splits
  (`split_ratio 0.5`; the 7:5 house grid is applied only when asked for a
  "column" by voice), new windows on the
  display under the pointer, and `manage=off` rules for System Settings,
  utilities, Finder dialogs and any non-standard window.
- `skhdrc` → `~/.config/skhd/skhdrc`: the table above.

Edit here, re-run `tiler/install.sh` (copies + reloads). The files are copied,
not symlinked: launchd-started yabai cannot read the external volume this repo
lives on.

## Voice

With the tiler active, "put Safari on the right column" swaps tiles, "Safari
on the left third" floats it at that size, "fill the screen" zooms, and new
verbs appear: "balance the windows", "rotate the layout", "float that",
"stack the windows", "back to tiling", "send Safari to space three". See
`desktop.py` and the README's desktop-control section.

## Upgrade / disable

```bash
yabai --stop-service; skhd --stop-service
brew upgrade yabai skhd
yabai --start-service; skhd --start-service   # re-tick Accessibility only if macOS asks
```

yabai ships a signed release binary, so its Accessibility grant survives
upgrades. skhd is compiled by Homebrew with an ad-hoc signature, so after
`brew upgrade skhd` expect to remove and re-add it in the Accessibility list.

Disable at any time with `yabai --stop-service` — the assistant notices within
seconds and returns to System Events placement. `DESKTOP_TILER=off` in the
assistant's environment forces that even while yabai runs.
