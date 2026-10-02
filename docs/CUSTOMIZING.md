# Making it yours

The one page for changing the Gallery to suit you: keys, tiling, themes,
wallpapers, fonts, terminals, plugins, the coding agent and the Learn sheets.
It says where your changes go so that an update or an uninstall does not lose
them, and gives short recipes. It links to the reference pages instead of
repeating them: the [README](../README.md) for what each part is,
[INSTALL.md](INSTALL.md) for the installer, [THEMES.md](THEMES.md),
[PLUGINS.md](PLUGINS.md) and [tiler/README.md](../tiler/README.md).

Contents: [What is yours](#what-is-yours-and-what-an-update-overwrites) -
[Keys](#keys) - [Tiling](#tiling) - [Themes](#themes) -
[Wallpapers](#wallpapers) - [Fonts and glass](#fonts-and-glass) -
[Terminals](#terminals) - [Plugins](#plugins) -
[AI agents](#ai-agents) - [Learn sheets](#learn-sheets) -
[Where to look next](#where-to-look-next)

## What is yours, and what an update overwrites

`./install.sh` copies files into place; running it again (an update) copies
them again. The rule is simple: files named after the Gallery are the
Gallery's and are overwritten, and every place meant for you is never
touched. Put lasting changes in the places marked "you".

| Path | Owner | Survives an update | Survives `--uninstall` |
|---|---|---|---|
| `~/.config/skhd/local.skhd` | you | yes, never overwritten | yes if you edited it; removed only while it is still the untouched seed copy |
| `~/.config/skhd/skhdrc`, `tiler.skhd`, `gallery.skhd` | Gallery | no, overwritten (an edited copy is saved first, see below) | removed; your original `skhdrc` comes back from `.gallery-bak` |
| `~/.config/skhd/learn`, `focus-dir`, `browser-window`, `learn.style.json`; `~/.config/yabai/yabai-layout`, `tree-guard` | Gallery | no, overwritten | removed |
| `~/.config/yabai/yabairc` | Gallery | no, overwritten | removed; your original comes back from `.gallery-bak` |
| `~/.config/yabai/yabairc.local` | you | yes, the installer never creates or touches it | yes |
| `~/.config/yabai/rules.local` | you (written by `gallery home save`) | yes | yes |
| `~/.config/gallery/state/*.json` (font, glass, borders, console, terminal, agent, backgrounds, weather, widgets) | you, written by the `gallery` verbs | yes | yes; deleted by `--purge` |
| `~/.config/gallery/state/theme.*`, `terminals/`, `crystal.css` | Gallery, generated | rewritten on every render | kept; deleted by `--purge` |
| `~/.config/gallery/themes/<theme>` for a theme the Gallery ships | Gallery | `colors.toml` is overwritten; files you added (such as `backgrounds/`) stay | kept; deleted by `--purge` |
| `~/.config/gallery/themes/<your-theme>`, `themes/current` | you | yes | kept; deleted by `--purge` |
| `~/.config/gallery/plugins/gallery.*` (the bundled ones) | Gallery | no: each is synced to match the checkout; a file you added inside is moved to `backup/<timestamp>/` and an edit is overwritten | kept; deleted by `--purge` |
| `~/.config/gallery/plugins/<other>` (from `gallery add`, `gallery clone` or made by hand) | you | yes | kept; deleted by `--purge` |
| `~/.config/gallery/gallery.json` (enabled and disabled plugins) | you | yes | kept; deleted by `--purge` |
| `~/.config/gallery/hooks/theme-set.d/10-`, `20-`, `30-` (shipped hooks) | Gallery | no, overwritten | removed |
| `~/.config/gallery/hooks/theme-set.d/<your hooks>` | you | yes | kept; deleted by `--purge` |
| `~/.config/gallery/sheets/` | you, except `Tiler-Keys.md`, which is generated | yes | kept; deleted by `--purge` |
| `~/.config/gallery/patches/`, `qml/`, `bin/render-theme.py` | Gallery | no, synced from the checkout (extra files go to `backup/<timestamp>/`) | kept; deleted by `--purge` |
| `~/bin/gallery`, `gallery-hs`, `gallery-tui`, `gallery-term`, `gallery-menu`, `gallery-borders`, `gallery-agent`, `gallery-qml` | Gallery | no, overwritten | removed; a file of yours they replaced comes back |
| `~/.hammerspoon/init.lua` | you; the Gallery owns only the block between `-- gallery:begin` and `-- gallery:end` | yes; only that block is rewritten, and only if it is out of date | the block is removed, and the file is restored if nothing else changed |

### Backups

- **`<name>.gallery-bak`**: your original of a file the installer replaced
  (`yabairc`, `skhdrc`, a `~/bin/gallery`...). Also made once, before the
  first edit, of files the Gallery edits in place (`init.lua`, btop and
  superfile settings, Ghostty and kitty configs). `--uninstall` puts it back.
  A second backup of the same name gets a timestamp suffix.
- **`<name>.gallery-edited.<timestamp>`**: you edited a file the Gallery
  owns, and an update (or an uninstall) is about to replace or remove it.
  Your version is kept beside it. If you find one, move the change into
  `local.skhd`, `yabairc.local` or a hook so it stops needing a copy.
- **`~/.config/gallery/backup/<timestamp>/`**: files an update would have
  deleted from a directory the Gallery owns (a file you dropped into a
  bundled plugin, a patch you put straight into `~/.config/gallery/patches/`).
  They keep their path below the timestamp, for example
  `backup/<timestamp>/.config/gallery/patches/<id>/...`. Nothing prunes this;
  delete old ones yourself.
- **`~/.config/gallery/state/install-manifest.tsv`**: every file the
  installer wrote, with its checksum and where its backup is. It is how an
  uninstall tells "unchanged, remove it" from "you edited it, keep it". Do not
  delete it.

### Uninstalling

```sh
./install.sh --uninstall --dry-run    # list what would be removed or restored
./install.sh --uninstall              # keeps ~/.config/gallery
./install.sh --uninstall --purge      # also deletes ~/.config/gallery
./install.sh --uninstall --keep-wallpaper
```

`--purge` deletes the whole of `~/.config/gallery/`, after everything else has
been restored. That includes what you added there: your themes and their
backgrounds, plugins from `gallery add` and `gallery clone`, hooks, sheets,
saved preferences, backups and the manifest. It does not ask. Copy out what
you want to keep first. `--keep-wallpaper` skips putting the saved wallpaper
settings back. The full list of what is undone is under
[Uninstalling](INSTALL.md#uninstalling) in INSTALL.md.

## Keys

### Your own keys: `local.skhd`

`~/.config/skhd/skhdrc` binds nothing; it loads three files in this order:

1. `~/.config/skhd/local.skhd`: yours.
2. `~/.config/skhd/tiler.skhd`: the tiler's keys.
3. `~/.config/skhd/gallery.skhd`: the Gallery's keys.

skhd does not warn about a hotkey defined twice: the first definition wins and
the later one is dropped silently. Because `local.skhd` is loaded first, a key
you bind there replaces the same key in the other two, and a new key is simply
added. skhd has no "unbind", so to switch a shipped key off bind it to a
no-op:

```sh
lalt + ctrl - 0 : true
```

The installer creates `local.skhd` once, from `tiler/local.skhd.example` with
everything commented out, and never overwrites it. skhd reloads a key file
when it changes, but only a file that existed when skhd started; if you
create the file by hand run `skhd --reload` once. Key syntax is skhd's own:
see [its documentation](https://github.com/asmvik/skhd). In it, `lalt` is left
Option, which is "super". Right Option is deliberately unbound, so it still
types `@ | [ ] { }` on a Swedish layout.

A line starting with `## ` above a binding describes it, and the description
puts it on the generated key sheet (`super + shift + space`) under "Your
keys". A binding without one is not listed. Add a header such as
`# --- apps ---` to file the keys under another section; the example file
uses it to put the app slots under "Apps". Regenerate the sheet with:

```sh
~/.config/skhd/learn install
```

#### Omarchy's app slots

Omarchy puts an app on each letter. Left unbound here because they are
personal. `local.skhd.example` has them ready to uncomment; this is the shape:

```sh
## AI assistant
lalt - a : open -a "/Applications/Claude.app"
## Email web app
lalt - e : open -a "$HOME/Applications/Gmail.app"
## messaging
lalt - g : open -a Telegram
```

Before choosing a key, see what is taken (`lalt` plus a letter is mostly in
use for the tiler: `b c f h j k l m o r s t w`, `return`, `tab`, `space`, the
arrows and `1` to `9`):

```sh
grep -hE '^[a-z].* : ' ~/.config/skhd/tiler.skhd ~/.config/skhd/gallery.skhd
```

Calendar (`super + c`) and the Finder keys (`super + o`) are in
`tiler.skhd` too, and you can override them the same way. Web apps saved from
Safari live in `~/Applications`; `open -a` raises the window they already
have.

### The Gallery's keys

From `skhd/gallery.skhd` (installed as `~/.config/skhd/gallery.skhd`). "super"
is left Option.

| Keys | Action |
|---|---|
| super + shift + 0 | System Monitor (`gallery.sysmon`, btop) |
| super + ctrl + 0 | spaces and windows picker (`gallery.spaces`) |
| super + cmd + 0 | Radio Atlas (`akshar.radio-atlas`); not bundled; the key does nothing until you `gallery add` that plugin |
| super + shift + ctrl + space | theme picker (`gallery.themes`) |
| super + shift + ctrl + b | background picker (`gallery.backgrounds`) |
| super + ctrl + space | next background of the current theme (`gallery bg next`) |
| super + ctrl + w | weather panel (`gallery.weather`) |
| super + shift + ctrl + a | open the coding agent in a new window (`gallery agent`) |

The tiler's keys (focus, swap, Spaces, zoom, float, close, terminal, Learn) are
in the [key table in tiler/README.md](../tiler/README.md#keys-left-option--super);
`super + space` opens Learn and `super + shift + space` the key sheet.

### Binding a plugin to a key

`gallery open`, `close` and `toggle` take a plugin id (and, for a plugin with
more than one interactive kind, an optional kind). Bind them in `local.skhd`
with the full path, as the shipped keys do, since skhd's `PATH` is minimal:

```sh
## my disk-usage plugin
lalt - n : "$HOME/bin/gallery" toggle me.diskfree
```

Pick a free key. `lalt - k` is "focus north" in `tiler.skhd`; binding it in
`local.skhd` would replace it. `gallery list` shows plugin ids.

### Changing "super"

There is no single setting for the modifier. `local.skhd` can rebind
individual keys, but "super" is the literal `lalt` written on every line of
`tiler.skhd` and `gallery.skhd`, so changing it wholesale means editing those
two files. Do it in your own fork of the repository, so an update does not
overwrite it (an edit made only to the installed copies is saved as
`.gallery-edited.<timestamp>` and then replaced), then run `./install.sh`:

```sh
sed -i '' 's/lalt/cmd/g' tiler/tiler.skhd skhd/gallery.skhd
```

Read the caveats before you do:

- Left Option was chosen because almost nothing in macOS uses it. `cmd`
  collides with the shortcuts of every app: `cmd - c` (Calendar here) would
  stop copying, `cmd - w` closes a tab, `cmd - m` and `cmd - tab` and
  `cmd - space` belong to macOS. Expect to rebind many keys by hand.
- Switching Spaces works by sending the Mission Control shortcut `ctrl - N`
  (`lalt - 1` runs `skhd -k "ctrl - 1"`). Make `ctrl` your super and the
  binding becomes the key it sends, which defeats Mission Control itself, and
  the Gallery's `ctrl + lalt` and `shift + ctrl + lalt` chords turn into
  duplicates. Do not use `ctrl`.
- Use a left-hand modifier name (`lalt`, `lcmd`, ...) rather than `alt` if you
  stay on Option, or the right Option stops typing `@ | [ ] { }`.
- The mouse modifier is separate: Option-drag moves and Option-right-drag
  resizes because of `mouse_modifier alt` in the yabai config. Set the same
  modifier in `yabairc.local` (see below).
- `tiler.skhd` stands skhd down while UTM is focused (`.blacklist`), because an
  Omarchy guest uses left Option too. Keep that in mind if you pick a
  different modifier for a VM host.
- The Learn key sheet prints `lalt` as "super"; with another modifier it shows
  the modifier you chose, so the sheet stays truthful but reads oddly.

## Tiling

### Settings: `yabairc.local`

`~/.config/yabai/yabairc.local` is plain `sh`, sourced by `yabairc` after its
own `yabai -m config` lines and rules (and before the shipped signals and the
focus border), so a value set there replaces the shipped one, since yabai keeps
the last value set. It can also add rules. The installer never creates it:
copy the template and uncomment what you want.

```sh
cp tiler/yabairc.local.example ~/.config/yabai/yabairc.local
```

The template lists every setting the shipped `yabairc` sets, with its value:
`layout` (`bsp`, `stack`, `float`), `window_placement`, `split_ratio`,
`auto_balance`, the gaps (`window_gap` and the four `*_padding` values, all
8), the mouse (`mouse_modifier alt`, `mouse_action1 move`, `mouse_action2
resize`, `mouse_drop_action swap`, `focus_follows_mouse autofocus`) and
`manage=off` rules for apps you never want tiled:

```sh
yabai -m config window_gap 12
yabai -m rule --add label=never-tile-spotify app="^Spotify$" manage=off
```

Give every rule a `label`: yabai replaces a rule added again under the same
label, so the file can be run more than once without piling up duplicates.
Everything else yabai offers is in `man yabai`.

**Apply a change without restarting yabai.** Restarting rebuilds every window
tree from scratch and loses your hand-tuned split ratios on every display.
`super + shift + r` restarts it, so avoid it for this. Instead run the same
lines by hand, then keep them in `yabairc.local` so they survive the next
start:

```sh
yabai -m config window_gap 12     # takes effect at once
sh ~/.config/yabai/yabairc.local  # or re-run the whole file (labelled rules only)
yabai -m rule --apply             # move already-open windows by the new rules
```

### Where apps live: `rules.local` and `gallery home`

yabai does not remember which Space a window was on across a login. A rule
with `space=N` puts an app back every time, and that is what
`~/.config/yabai/rules.local` holds, one labelled rule per app. `yabairc`
sources it when present. Arrange your apps across your Spaces, then:

```sh
gallery home show      # the window -> Space map, and the live home-* rules
gallery home save      # write rules.local from the current layout and apply it
gallery home apply     # re-source rules.local and apply it live
```

`home save` leaves terminals and the browser out (they roam; add apps with
`--roam A,B`), previews with `--dry-run`, and keeps the previous file as
`rules.local.prev`. Nothing saves it automatically. Because `save` rewrites
the file, keep your own non-home rules in `yabairc.local`, not in
`rules.local`. Space numbers are one global sequence across displays and shift
if you add or remove a Space in Mission Control. The template is
`tiler/rules.local.example`.

### The focus outline

JankyBorders draws the outline on the focused window. The colour comes from the
theme: its `hyprland_active_border` key if it has one, else `accent`
([THEMES.md](THEMES.md#authoring-a-theme)). You set the shape:

```sh
gallery borders status
gallery borders width 8          # 1 to 12, default 5
gallery borders bright on        # on | off | toggle: mix toward the bright foreground
```

Both are kept in `state/borders.json` and re-applied on every theme change.
In the theme picker, `ctrl-w` cycles the width (3, 5, 8, 12) and `ctrl-b`
toggles bright. To change the outline for one theme only, give that theme a
`hyprland_active_border` (a gradient is allowed) in its `colors.toml`.

## Themes

### Switching

```sh
gallery theme list      # installed themes; marks the current and light ones
gallery theme set <name>
gallery theme next      # alphabetically next, wrapping around
gallery theme render    # re-run the renderer only (no hooks)
```

`super + shift + ctrl + space` opens the picker, with the palette and the
theme's wallpapers previewed; Enter applies. A theme change recolours the
terminals, the focus outline, the wallpaper, btop and superfile together; the
table in [THEMES.md](THEMES.md#what-re-themes-when) says what each command
touches.

### Adding a theme from Omarchy or elsewhere

A theme is a directory with a `colors.toml`. Every directory under
`~/.config/gallery/themes/` is a theme; there is no registry:

```sh
git clone <theme-repo-url> ~/.config/gallery/themes/<name>
gallery theme list
gallery theme set <name>
```

Or copy the directory in by hand. Only `colors.toml` is read; a theme's other
files (editor, terminal and icon configs for Linux apps) are ignored, and a
`backgrounds/` directory next to it supplies wallpapers (below). A theme that
has no `colors.toml` cannot be set (`gallery theme set` says so). The name may
contain letters, digits, `.`, `_` and `-`. Light themes declare
`mode = "light"` or carry a `light.mode` file.

Do not edit a theme the Gallery ships in place. An update copies the shipped
`colors.toml` over it. Copy it to a new name and change that:

```sh
cp -R ~/.config/gallery/themes/tokyo-night ~/.config/gallery/themes/my-night
$EDITOR ~/.config/gallery/themes/my-night/colors.toml
gallery theme set my-night
```

### Writing your own

`colors.toml` is flat TOML. `background`, `foreground` and `accent` are the
three worth always setting; the rest fall back to derived values. The key
table, the derived tokens, and everything the renderer writes are in
[THEMES.md](THEMES.md#authoring-a-theme). `tools/render-theme.py --print`
(from a checkout, or `~/.config/gallery/bin/render-theme.py --print`) prints
the resolved tokens without writing anything.

### Theming another app: a theme-set hook

After `gallery theme set` and `gallery theme next`, the Gallery runs every
executable file in `~/.config/gallery/hooks/theme-set.d/`, in name order, each
as `hook <theme-name>`. `theme render` does not run hooks. The renderer has
already finished by then, so a hook can read the current colours from
`~/.config/gallery/state/theme.sh`, a shell file of exports:

| Variable | Value |
|---|---|
| `GALLERY_THEME_NAME` | the theme name |
| `GALLERY_BG`, `GALLERY_FG`, `GALLERY_ACCENT`, `GALLERY_MUTED` | background (the deepest tone), foreground, accent, muted |
| `GALLERY_COLOR0` to `GALLERY_COLOR15` | the 16 ANSI colours |
| `GALLERY_BORDER_ACTIVE`, `GALLERY_BORDER_ACTIVE_HEX`, `GALLERY_BORDER_INACTIVE`, `GALLERY_BORDER_WIDTH`, `GALLERY_BORDER_BRIGHT` | the focus outline |

All values are `#rrggbb` strings (the border colours have their own format,
see [THEMES.md](THEMES.md#statethemesh)). A hook that fails prints a message
and the rest still run. Keep hooks quick: they run one after another before
the command returns.

A worked example: colour tmux's status line and active pane border to follow
the theme. Save as `~/.config/gallery/hooks/theme-set.d/40-tmux.sh` and make
it executable:

```bash
#!/usr/bin/env bash
# 40-tmux.sh -- write ~/.config/tmux/gallery.conf from the current theme.
set -euo pipefail

. "${HOME}/.config/gallery/state/theme.sh"

out="${HOME}/.config/tmux/gallery.conf"
mkdir -p "$(dirname "${out}")"
cat > "${out}" <<EOF
# generated by 40-tmux.sh for theme ${GALLERY_THEME_NAME}
set -g status-style "bg=${GALLERY_BG},fg=${GALLERY_FG}"
set -g pane-border-style "fg=${GALLERY_MUTED}"
set -g pane-active-border-style "fg=${GALLERY_ACCENT}"
EOF

# Apply to a running tmux server; harmless if there is none.
tmux source-file "${out}" 2>/dev/null || true
```

```sh
chmod +x ~/.config/gallery/hooks/theme-set.d/40-tmux.sh
echo 'source-file -q ~/.config/tmux/gallery.conf' >> ~/.tmux.conf
gallery theme set <name>     # runs the hook; look for "running hook: 40-tmux.sh"
```

Use a number of your own. The shipped hooks are `10-log-theme.sh`,
`20-borders.sh` (recolours the focus outline) and `30-wallpaper.sh`; editing
one of those means an update overwrites it, so add a file instead. Files you add
are never removed by an update.

## Wallpapers

Wallpapers are per theme: images in
`~/.config/gallery/themes/<theme>/backgrounds/` (`jpg`, `jpeg`, `png`, `heic`,
`webp`). They are not in the repository. Fetch the Omarchy ones for a vendored
theme from a checkout, and add your own by copying files in:

```sh
tools/fetch-omarchy-backgrounds.sh tokyo-night      # or --all
cp ~/Pictures/dusk.jpg ~/.config/gallery/themes/tokyo-night/backgrounds/
```

```sh
gallery bg list [theme]        # the theme's images, the active one marked
gallery bg set <file> [theme]  # choose one and apply it (the filename inside backgrounds/)
gallery bg next [theme]        # cycle forward; prev cycles back
gallery bg apply [theme]       # re-apply the recorded choice
gallery bg current [theme]     # print the active filename
gallery bg restore             # put back the wallpaper settings from before the first Gallery background
```

The choice is remembered per theme in `state/backgrounds.json` and used again
whenever you switch to that theme. With nothing chosen the hook uses
`default.<ext>` if there is one, else the first image by name. A theme with no
`backgrounds/` leaves the desktop picture alone.

`super + ctrl + space` is `gallery bg next`; `super + shift + ctrl + b` opens
the background picker. `bg restore` brings back the wallpaper store that was
saved the first time a background was applied, and the uninstaller does the
same unless you pass `--keep-wallpaper`. How the picture reaches every Space,
and the `GALLERY_WALLPAPER_ALL_SPACES` switch, are in
[THEMES.md](THEMES.md#wallpapers).

## Fonts and glass

```sh
gallery font list                       # installed Nerd Fonts
gallery font set "MesloLGS NFM" 14      # family [size] [weight]
gallery font set "JetBrainsMono Nerd Font" 13 Bold
gallery font native                     # no preference: every app keeps its own font
gallery font                            # status
```

The default size is 13 and the weight `Regular`. The family is checked
against `fc-list`, so it needs fontconfig (`brew install fontconfig`) and must
be installed. A font set this way goes into the Gallery's terminal profiles
and files (iTerm2's "Gallery" profile, and "Console" while the console follows
the theme; the Ghostty, kitty and WezTerm theme files, where the weight is not
mapped), into the QML plugin host's `monospace` font, and into
`--gallery-font-family` for web panels. Use a Nerd Font if you want the
prompt and TUI icons to draw.

```sh
gallery glass                           # status
gallery glass set 0.2 12                # transparency 0 to 0.9, optional blur 0 to 64
gallery glass set 0                     # solid, keep the current blur
gallery glass default                   # shipped glass: 0.12, blur 9
```

Glass is the terminal windows' transparency and background blur. It is one
setting shared by the floating Gallery windows and the console, so tiled and
floating terminals look alike; iTerm2 gets it as a profile setting, the other
terminals as opacity and blur in their theme files. Both commands re-render the
theme, and the values live in `state/glass.json` and `state/font.json`. See
[THEMES.md](THEMES.md#iterm2-profiles) for exactly which profiles and files.

## Terminals

The Gallery opens its floating windows, Learn and the agent in one terminal:
iTerm2, Ghostty, kitty or WezTerm.

```sh
gallery terminal            # which one is in use
gallery terminal list       # the supported ones, and which are installed
gallery terminal set ghostty
```

With nothing chosen it is iTerm2 if installed, otherwise the first installed of
the others. Floating windows always take the theme. Whether your everyday
terminal follows it too is a separate choice:

```sh
gallery console status
gallery console theme       # your terminal follows the theme
gallery console native      # back to its own colours (the default)
gallery console toggle
```

`console theme` needs a one-time step per terminal (iTerm2: make the "Console"
profile your default; WezTerm: two lines in your Lua; Ghostty and kitty: one
include line the Gallery adds for you). They are described in
[INSTALL.md](INSTALL.md#choosing-the-terminal) and the README's
[Terminals](../README.md#terminals) section. In the theme picker, `ctrl-t`
toggles the console.

## Plugins

A plugin is a directory with a `manifest.json`; the full format is in
[PLUGINS.md](PLUGINS.md#manifest). Directories under `~/.config/gallery/plugins/`
are yours, as long as their id is not one the Gallery ships. Use your own prefix
for the id: the `gallery.` prefix is for bundled plugins and warns on
validation.

### A minimal `tui` plugin

A `tui` plugin is a command run in a floating, centred terminal window. The
manifest needs `schemaVersion` 1, a lowercase `id` (`^[a-z0-9][a-z0-9.-]*$`),
`name` (also the window title), `version`, `kinds`, and for a `tui`
`gallery.tui.command`. `entryPoints` stays `{}` for this kind; `gallery
validate` mentions that as a warning, which is fine.

`~/.config/gallery/plugins/me.diskfree/manifest.json`:

```json
{
  "schemaVersion": 1,
  "id": "me.diskfree",
  "name": "Disk Usage",
  "version": "0.1.0",
  "kinds": ["tui"],
  "entryPoints": {},
  "gallery": {
    "tui": {
      "command": "~/.config/gallery/plugins/me.diskfree/diskfree.sh",
      "args": [],
      "grid": "6:6:2:2:2:2"
    }
  }
}
```

`grid` is a yabai `--grid` spec, `rows:cols:x:y:w:h` (default `6:6:1:1:4:4`,
the middle of a 6 by 6 grid).

`~/.config/gallery/plugins/me.diskfree/diskfree.sh`:

```bash
#!/usr/bin/env bash
# Show free disk space in the theme's accent colour; any key closes.
THEME_SH="${HOME}/.config/gallery/state/theme.sh"
[ -f "${THEME_SH}" ] && . "${THEME_SH}"

# "#rrggbb" -> "r;g;b" for a truecolor escape.
rgb() { local h="${1#\#}"; printf '%d;%d;%d' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"; }

printf '\033[1;38;2;%sm Disk usage\033[0m\n\n' "$(rgb "${GALLERY_ACCENT:-#7aa2f7}")"
df -h /
printf '\n press any key to close'
read -rsn1
```

```sh
chmod +x ~/.config/gallery/plugins/me.diskfree/diskfree.sh
gallery validate ~/.config/gallery/plugins/me.diskfree   # needs Hammerspoon running
gallery enable me.diskfree      # a plugin whose id has no "gallery." prefix starts disabled
gallery toggle me.diskfree      # opens the window; again to close it
```

`tui` plugins are opened by `gallery` itself, without Hammerspoon, from the
manifest on disk; a plugin is refused only if it is listed under `disabled` in
`gallery.json`. `gallery list`, `enable`, `disable` and `validate` go through
the Spoon, so it must be running for those. The command runs without your
shell startup files, so it has a short `PATH` and none of your `zshrc`
exports; give it absolute paths and read secrets from a file (the weather
plugin reads `~/.config/gallery/weather.key`). Add a key with the recipe under
[Binding a plugin to a key](#binding-a-plugin-to-a-key).

### Adding, cloning, removing

```sh
gallery add <git-url> --enable   # clone into ~/.config/gallery/plugins, apply patches, enable
gallery update [id]              # pull git-managed plugins, re-apply patches
gallery clone <id> <new-id>      # copy an installed plugin under a new id
gallery disable <id>             # stays installed, stops running
gallery remove <id>              # a git clone is deleted; anything else goes to ~/.config/gallery/removed/
```

`gallery add` prints a warning and asks first (`--yes` skips it): a plugin runs
as you, unsandboxed. Read it before enabling it ([Security](PLUGINS.md#security)).

To change a bundled plugin, clone it and edit the clone: an update overwrites
the bundled copy but never touches yours.

```sh
gallery clone gallery.sysmon me.sysmon
$EDITOR ~/.config/gallery/plugins/me.sysmon/manifest.json   # a different grid, say
```

`clone` copies the directory and rewrites only the `id`. A manifest whose
`command` points into the original's directory (the weather plugin's does)
still runs the original's script, so change that path as well.

### Porting an Omarchy plugin

Most Omarchy plugins run as they are: `gallery add <git-url> --enable`, then
`gallery open <id>`. The QML ones run through the Gallery's host (see
[qml](PLUGINS.md#qml) for what is supported). When one fails because a helper
script calls a Linux-only tool (`hyprctl`, `pactl`, `systemctl`, ...), replace
that file with a macOS version through the patch overlay:

1. Put the replacement in this repository, at
   `patches/<plugin-id>/<path relative to the plugin root>`, and `chmod +x`
   it if the original was executable. Note at the top of the file what it
   replaces and why. The worked example is `patches/akshar.radio-atlas/`;
   [patches/README.md](../patches/README.md) explains the layout.
2. Run `./install.sh`. It copies `patches/` to `~/.config/gallery/patches/`.
3. Run `gallery patch <plugin-id>` to lay the files over the installed plugin.
   From then on `gallery add` and `gallery update` re-apply them on their own.

It has to be in the repository, not in `~/.config/gallery/patches/`: the
installer syncs that directory from the checkout and deletes whatever is not in
it, so a patch you create there is moved to
`~/.config/gallery/backup/<timestamp>/` the next time you run `./install.sh`
(and silently stops applying). To try a change quickly, edit the file under
`~/.config/gallery/plugins/<id>/` directly; just know that `gallery update`
may overwrite it.

If the QML view itself cannot run (it needs a Quickshell module the shim lacks),
`tools/import-omarchy-plugin <git-url-or-dir>` scaffolds a web `panel` plugin
and a port report; see [Importing Omarchy
plugins](PLUGINS.md#importing-omarchy-plugins). There is no `gallery import`
command, the tool is run from a checkout.

## AI agents

`gallery agent` opens a coding agent in a new terminal window, in the manner
of Omarchy's `omarchy-agent`. `super + shift + ctrl + a` (in `gallery.skhd`)
runs it. The window is an ordinary tiled terminal, not a floating one, and
every press opens another.

```sh
gallery agent                       # open the default agent in a new window
gallery agent inline                # run it in this terminal instead
gallery agent status                # default agent, start directory, command
gallery agent list                  # the built-ins and whether each is on PATH
gallery agent set codex             # choose a built-in
gallery agent set aider --command "aider --yes"   # any other CLI
gallery agent dir ~/Work            # where the agent starts (default: $HOME)
gallery agent dir --clear           # back to $HOME
```

The built-in agents, and the command line each is started with (its own way of
saying "do not stop to ask"):

| Name | Command |
|---|---|
| `claude` (the default) | `claude --permission-mode bypassPermissions` |
| `gemini` | `gemini --yolo` |
| `opencode` | `opencode --auto` |
| `codex` | `codex --dangerously-bypass-approvals-and-sandbox` |
| `copilot` | `copilot --allow-all` |
| `crush` | `crush --yolo` |

`set <name> --command "<line>"` records any other agent. The line runs from
the start directory exactly as typed, so put the program first and its own
"do not ask" flag after it. It must not contain double quotes, backslashes or
newlines (use single quotes inside it), and the name may use only letters,
digits, `.`, `_` and `-`. `set <built-in>` without `--command` goes back to
the built-in's own command. Settings are in `state/agent.json`.

The start directory is `GALLERY_AGENT_DIR` if set (in the environment skhd
runs under), else the one recorded with `gallery agent dir`, else `$HOME`; an
unreachable directory falls back to `$HOME` with a warning. Pointing it at one
folder that holds your repositories means an agent asks for trust once rather
than per project.

**Security.** An agent started this way runs unattended, with the full file
and shell access of your account, in the start directory: it will not stop to
ask before it edits or deletes files or runs commands. That is on purpose,
because a window opened by a keypress could not show a prompt anyway. Choose
the start directory with that in mind, do not point it at `$HOME` if you can
avoid it, and do not set a custom command whose "do not ask" flag you do not
want.

## Learn sheets

Learn (`super + space`) lists markdown files as a menu and renders the one you
pick; `q` or Esc closes it. The folder is `~/.config/gallery/sheets`: drop in
any `.md` file and it appears under its filename. Front matter is stripped.

```sh
mkdir -p ~/.config/gallery/sheets
$EDITOR ~/.config/gallery/sheets/Git-Tricks.md
~/.config/skhd/learn list           # the sheet names
```

`Tiler-Keys.md` is the one generated sheet, rebuilt from the `## ` description
lines in `local.skhd`, `tiler.skhd` and `gallery.skhd` (`~/.config/skhd/learn
install`, which the installers also run). Do not edit it; edit the descriptions.
To read sheets from somewhere else, either replace the folder with a symlink
(`ln -s <folder> ~/.config/gallery/sheets`) or set `LEARN_SHEETS` in the
environment skhd runs under. Learn needs `fzf` and `glow`. More in
[tiler/README.md](../tiler/README.md#learn-cheat-sheets-on-a-key).

## Where to look next

- [README.md](../README.md): what the three parts are, how a theme change fans
  out, the command reference under "Usage".
- [INSTALL.md](INSTALL.md): installer flags, permissions, updating,
  uninstalling in full, troubleshooting.
- [THEMES.md](THEMES.md): the `colors.toml` keys, derived tokens, every file
  the renderer writes, hooks and wallpapers.
- [PLUGINS.md](PLUGINS.md): manifests and every plugin kind, the `window.gallery`
  bridge, QML plugins, importing Omarchy plugins.
- [tiler/README.md](../tiler/README.md): the full key table, tree repair,
  Learn, the yabai and skhd configuration.
- [patches/README.md](../patches/README.md): macOS overrides for imported
  plugins.
- `gallery doctor` checks the install; `gallery log` follows
  `~/Library/Logs/gallery.log`.
