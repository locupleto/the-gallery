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
tiler/install.sh --uninstall  # stop and unregister both, put back what it replaced (formulas stay)
```

An existing `yabairc`, `skhdrc` or helper of yours is moved to
`<name>.gallery-bak` before the Gallery's copy goes in, and `--uninstall` moves
it back; a Gallery file you edited is copied to
`<name>.gallery-edited.<timestamp>` before it is overwritten. Everything
installed is listed in `~/.config/gallery/state/install-manifest.tsv`.
`~/.yabairc` and `~/.skhdrc` are never modified, but yabai and skhd read the
`~/.config` copies first, so the installer warns when one exists.
`--uninstall` also unregisters the launchd services (so they do not start at
the next login) and stops JankyBorders unless it is a `brew services` entry.

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
3. **Secure Keyboard Entry off** in your terminal (iTerm2, Ghostty and kitty have
   it in their menus), otherwise skhd is blind while that terminal is frontmost.

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
| super + return | new terminal window in the configured terminal (`gallery terminal`; iTerm2 unless set otherwise), launched if it is not running (on iTerm2 and Ghostty, first press: allow "skhd wants to control iTerm2") |
| super + shift + r | restart yabai, reload skhd |
| super + c | Calendar |
| super + a / shift + a, e, y, x, g / shift + g | Omarchy's other app slots: not bound out of the box (they are personal); examples in `local.skhd.example` |
| super + space | Learn menu: pick a cheat sheet (first press: allow "skhd wants to control iTerm2") |
| super + shift + space | the key sheet, generated from `local.skhd`, `tiler.skhd` and `gallery.skhd` |

Mouse: Option-drag moves a window, Option-right-drag resizes, dropping onto a
tile swaps.

### Swedish keyboard note

On the Swedish layout the Option key types `@` (⌥2), `|` (⌥7), `[` `]` (⌥8/9)
and `{` `}` (⌥⇧8/9). Only the **left** Option is bound here, so type those
symbols with the **right** Option — exactly like AltGr on Linux. Anything
else that wants a hold-to-talk or similar modifier key should use right
Command, not right Option.


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

Not every gap is a tree hole, though. A window that refuses to fill the tile
yabai gives it leaves exactly the same shortfall, and no rebuild will ever
close it — QEMU with `zoom-to-fit=on` is the case that found this: it tiles,
but keeps the guest's aspect ratio and letterboxes inside its tile, reading as
a 5% hole for as long as the VM runs. So a rebuild that does not improve
coverage is recorded against that Space's window set in
`~/.config/yabai/tree-guard.skip` and not attempted again until the set
changes — opening or closing a window re-arms it, which is also when a real
hole can next appear. `tree-guard check` says so when it meets one.

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
floating terminal window (in the configured terminal; see `gallery terminal`),
centred on the display that had focus when the key
was pressed (the script finds its own window by its `Learn: …` title and
moves, floats and centres it by id; a `yabairc` rule is the backup), with
an fzf list of your markdown cheat sheets;
Enter renders the chosen one with glow, `q` or Esc closes. Three doors:

- **super + space** — the menu; **super + shift + space** — the tiler keys directly.
- **Spotlight → "Learn"** — `~/Applications/Learn.app`, a shell-script bundle
  built by `tiler/learn install` (first launch: allow "Learn wants to control iTerm2"
  or Ghostty, if that is your terminal).

The `yabairc` rule that floats Learn windows matches the app names iTerm2,
Ghostty, kitty and WezTerm. Changing it on a running desk takes a restart of
yabai, which rebuilds the layout, so apply it live instead:
`yabai -m rule --add app="^(iTerm2|Ghostty|kitty|WezTerm)$" title="^Learn: " manage=off grid=6:6:1:1:4:4`
and copy `yabairc` into `~/.config/yabai/` by hand.

One source per sheet: the notes are plain markdown files read in place from
one folder, never copied, and a note iCloud has evicted is fetched first.
The folder is `~/.config/gallery/sheets`, which `learn install` creates;
`LEARN_SHEETS` (any folder of `.md` files) or `OBSIDIAN_VAULT` (its
`Cheat-Sheets` folder) override it, set in the environment skhd runs under.
To keep the sheets in an Obsidian vault without setting either, make the
default folder a symlink to the vault's folder:
`ln -s "<vault>/Cheat-Sheets" ~/.config/gallery/sheets`. With no sheets of
your own the menu lists just the generated `Tiler-Keys`. The only generated sheet is
`Tiler-Keys.md`, written from the `## description` lines above each binding
in `local.skhd`, `tiler.skhd` and `gallery.skhd` — so keep those lines current; `tiler/install.sh` regenerates the
note and the app every run. Dependencies: `fzf`, `glow` (Homebrew, installed
by the script).

## Configuration

- `yabairc` → `~/.config/yabai/yabairc`: bsp layout, 8 px gaps, even splits
  (`split_ratio 0.5`; a 7:5 grid is applied only on request), new windows on
  the
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
- `skhdrc` → `~/.config/skhd/skhdrc`: binds nothing; it loads `local.skhd`,
  `tiler.skhd` and `gallery.skhd`, in that order.
- `tiler.skhd` → `~/.config/skhd/tiler.skhd`: the table above.
- `~/.config/skhd/local.skhd` (your own keys; never overwritten): loaded
  first. The installers create it once, from `local.skhd.example` (all
  commented out: the app slots above, a custom key, and how to switch a
  shipped key off). Its `## ` description lines appear in the Learn key sheet,
  under "Your keys". skhd keeps the FIRST definition of a duplicate hotkey and
  drops the later one without a warning, so a key in `local.skhd` replaces the
  same key in `tiler.skhd` or `gallery.skhd`. skhd has no "unbind"; rebind a
  key to `: true` to silence it. A missing `.load` file is only a warning in
  skhd's error log.
- `~/.config/yabai/yabairc.local` (optional, not created by the installer):
  plain `sh` sourced by `yabairc` after its own `yabai -m config` lines and
  rules and before `rule --apply`, so any setting there (gaps, layout, mouse
  modifier, extra rules) replaces the shipped one. Template:
  `yabairc.local.example`.

Edit here, re-run `tiler/install.sh` (copies + reloads). The files are copied,
not symlinked: launchd-started yabai cannot read an external volume, and
this repo may live on one.

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

Nothing outside this repo is required. Other tools can read the generated
`~/.config/skhd/Tiler-Keys.md` key sheet to stay in sync with the bindings,
and anything that places windows should check whether yabai is running and
fall back to System Events when it is not.
