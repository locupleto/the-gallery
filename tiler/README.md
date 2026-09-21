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
| ctrl + super + r | repair the tree by hand — normally automatic, see *Tree repair* below (resets that Space's split ratios) |
| super + s | toggle stacked ⇄ tiled for the current Space |
| super + ← → ↑ ↓ | resize by 60 px |
| super + m | minimize |
| super + w | close window |
| super + return | new iTerm window, launched if iTerm is not running (first press: allow "skhd wants to control iTerm2") |
| super + shift + r | restart yabai, reload skhd |
| super + a / shift + a | Claude desktop app / ChatGPT app (both in /Applications) |
| super + c | Calendar |
| super + e | Gmail web app |
| super + y | YouTube web app |
| super + x | X web app |
| super + g / shift + g | Telegram (Omarchy's messaging slot) / Grok web app |
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


## Tree repair (automatic)

yabai's tree can end up holding a node for a window that is no longer tiled: a
destroy notification it never received, a window whose accessibility reference
never arrived, or a window added to the tree twice. The node keeps its share of
the display, nothing draws in it, and the surviving tiles will not grow into it
— a stripe of empty desktop, often half the screen.

`yabai -m space --balance` does not fix this. Balance only evens the ratios
*within* the existing structure, so it redistributes the hole instead of
closing it. The cure is to drop the Space to `float` and back to `bsp`, which
rebuilds the tree from the windows that are actually there.

`tree-guard` does that automatically. `yabairc` subscribes it to
`window_destroyed`, `application_terminated`, `window_minimized`,
`space_changed` and `display_changed`; after each it measures every visible bsp
Space and rebuilds only the ones that are genuinely short:

    coverage = SUM (w + gap)(h + gap) / (usable_w + gap)(usable_h + gap)

which is 1.0 for a whole Space and falls by the fraction the hole occupies.
The comparison is against the display's **usable rect**, not the tiles' own
bounding box: the survivors of this fault are a perfect partition of a smaller
box, so a bounding-box test would call a half-empty display healthy.
`tests/tree_guard_test.sh` asserts that on the geometry recorded when it
happened.

A rebuild costs that Space's hand-tuned split ratios, so it is deliberately
hard to trigger by accident — coverage must fall below `0.97` **and** still be
low when re-measured 0.6 s later, which keeps a Space caught mid-transition
from being flattened. Nothing is touched while the screen is locked.

The usable rect is calibrated from yabai's own tiles rather than from AppKit,
whose `visibleFrame` omits the menu-bar inset on a secondary display under
"Displays have separate Spaces" (it claims 1440 px usable where yabai tiles
1393). Every bsp Space on a display contributes its extent, the widest span
wins, and the result is cached per display frame in
`~/.config/yabai/tree-guard.rects`; changing resolution discards the entry
rather than measuring against a rectangle that no longer exists.

Only repairs are logged, to `~/Library/Logs/yabai-tree-guard.log`, so an empty
log means it has never had to act. By hand:

```bash
tree-guard check     # measure every visible Space, report, change nothing
tree-guard repair    # rebuild the current Space unconditionally (= ctrl+super+r)
```

If it ever proves too eager or too shy: `TREE_GUARD_THRESHOLD`,
`TREE_GUARD_CONFIRM`, `TREE_GUARD_SETTLE`.

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
- `~/.config/yabai/rules.local` (optional, per machine, not in the repo):
  app → home-Space rules, sourced by `yabairc` when present. yabai does not
  remember window placement across a reboot and macOS's own Space restoration
  is reset by OS upgrades; a labelled `app="^Telegram$" space=10` rule puts the
  app back on its Space at every login. Template: `rules.local.example`. Apply
  live without restarting yabai: `. ~/.config/yabai/rules.local && yabai -m
  rule --apply`. `gallery home save` generates this file from the current
  layout (snapshot the windows you have arranged instead of hand-writing the
  map) and `gallery home apply` re-sources it live the same way.
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

The one consumer outside this repo is the voice assistant (`ai_voice_assistant`),
and super+b is the one key that depends on it: the binding runs its
`desktop.py` from `~/.ai_voice_assistant` when that holds a venv python (the
Studio's synced runtime), else from the repo checkout under
`~/Developer/projects/git` (the laptop, which also has a bare
`~/.ai_voice_assistant` state folder, hence the test for the python and not
the directory). `gallery doctor` reports which runtime it resolves.
Its `desktop.py` detects yabai at runtime (`DESKTOP_TILER=auto`) and routes
window-placement verbs through yabai while it is running, falling back to
System Events the moment yabai stops (`DESKTOP_TILER=off` forces that
fallback even while yabai runs). Its fast brain reads the generated
`~/.config/skhd/Tiler-Keys.md` key sheet, so voice verbs never drift out of
sync with the Learn menu. That is the only link between the two projects.
