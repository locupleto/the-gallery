# Themes

A theme is a directory holding a `colors.toml`. `tools/render-theme.py` reads
the active one and writes everything that is coloured: the CSS, JSON and shell
files other tools read, two iTerm2 profiles, theme files for Ghostty, kitty and
WezTerm, a btop theme, a superfile theme,
and (through hooks) the focus outline and the wallpaper. This page covers
writing a theme, what the renderer derives and emits, and what changes when.

## Using themes

```sh
gallery theme list          # installed themes; marks the current one and light ones
gallery theme set <name>    # switch and re-render everything
gallery theme next          # next theme alphabetically, wrapping around
gallery theme render        # re-run the renderer only
```

Themes live in `~/.config/gallery/themes/<name>/`. `install.sh` copies the
vendored Omarchy themes from `themes/` there without deleting anything, so a
directory you add by hand stays. `~/.config/gallery/themes/current` is a
symlink to the active theme; `theme set` replaces it atomically. A theme name
may contain letters, digits, `.`, `_` and `-`.

## Authoring a theme

Create `~/.config/gallery/themes/<name>/colors.toml`:

```toml
mode = "dark"

accent = "#7aa2f7"
selection = "#292e42"
muted = "#3c3f46"

background = "#1a1b26"
dark_background = "#13141c"
darker_background = "#0e0e14"
lighter_background = "#24283b"

foreground = "#c5c7cb"
# ... see the key table below
```

The file is flat TOML, one `key = "value"` per line, with `#` comments and no
tables, arrays or multi-line strings. Values are `#rrggbb` (`#rgb` is
accepted). A missing key falls back as described under
[Derived tokens](#derived-tokens), so a theme can be small, but `background`,
`foreground` and `accent` are the ones worth always giving (they default to
`#000000`, `#ffffff`, and the foreground).

Keys of Omarchy's `colors.toml` schema (`themes/tokyo-night/colors.toml` is a
complete example):

| Key | Used for |
|---|---|
| `mode` | `"dark"` or `"light"`. Without it, a file named `light.mode` next to `colors.toml` marks a light theme. |
| `accent`, `selection`, `muted` | highlight colour, selection background, neutral grey |
| `background`, `dark_background`, `darker_background`, `lighter_background` | the background and its tones |
| `foreground`, `dark_foreground`, `light_foreground`, `bright_foreground` | the foreground and its tones |
| `red`, `yellow`, `orange`, `green`, `cyan`, `blue`, `magenta`, `brown` | colours |
| `bright_red`, `bright_yellow`, `bright_green`, `bright_cyan`, `bright_blue`, `bright_magenta` | bright variants |
| `hyprland_active_border`, `hyprland_inactive_border` | optional; the focus outline, see below |

The renderer also accepts a flat, hand-written shape: `cursor`,
`selection_foreground`, `selection_background` and `color0` to `color15`
given literally, which then win over anything derived. Any other key is
carried through to the outputs untouched.

`hyprland_active_border` and `hyprland_inactive_border` use Hyprland's colour
syntax: one or more space-separated `rgba(RRGGBBAA)`, `rgb(RRGGBB)` or
`#rrggbb` colours with an optional trailing `NNNdeg`. The renderer converts
them to JankyBorders' `0xAARRGGBB` or `gradient(...)` (first and last colour;
the angle picks the diagonal). Without `hyprland_active_border` the outline
uses `accent`; without `hyprland_inactive_border` there is no inactive
outline. `gallery borders bright on` mixes the active colours 40% toward
`bright_foreground` (else `light_foreground`, else `foreground`).

To vendor Omarchy's own themes, `tools/vendor-omarchy-themes.sh` fetches
`colors.toml` (and `light.mode` where present); see `themes/UPSTREAM.md`.

## Derived tokens

`build_tokens` in `tools/render-theme.py` is the single derivation; the Spoon
reads its `state/theme.json` back instead of recomputing. Every key in
`colors.toml` except `mode` is a token, plus:

| Token | Value |
|---|---|
| `cursor` | `cursor`, else `accent` |
| `selection_background` | `selection_background`, else `selection`, else `background` |
| `selection_foreground` | `selection_foreground`, else `foreground` |
| `color0` to `color15` | the literal `colorN` if given, else the first present of the keys below, else `foreground` |
| `muted` | `color8` |
| `danger`, `success`, `warning`, `info` | `color1`, `color2`, `color3`, `color4` |
| `surface` | `lighter_background`, else `background` mixed 12% toward `foreground` |
| `surface_background` | `darker_background`, else `background` |
| `border` | `background` mixed 25% toward `foreground` |

`color0` to `color15` fallbacks:

| Token | Falls back to |
|---|---|
| `color0` | `dark_background`, `background` |
| `color1` to `color7` | `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`, `foreground` |
| `color8` | `muted`, `dark_foreground` |
| `color9` to `color14` | `bright_red`, `bright_green`, `bright_yellow`, `bright_blue`, `bright_magenta`, `bright_cyan`, each falling back to the plain colour |
| `color15` | `bright_foreground`, `foreground` |

So `danger` is `color1`, which is `red` unless `colors.toml` sets `color1`;
`muted` is `color8`, which is the `muted` key unless `color8` is set. A "mix"
moves each channel of the first colour the given fraction of the way to the
second.

Note the three that are easy to confuse:

- `background` is the theme's ordinary background. Terminal windows, btop and
  superfile are painted from it.
- `surface` is a raised tone, `lighter_background`, for a panel or control on
  top of the background.
- `surface_background` is the deepest tone, `darker_background`, intended for
  non-terminal chrome. In the files written here it appears in `theme.json`,
  `theme.css`, and as `GALLERY_BG` in `theme.sh`.
- `border` is a hairline tone between `background` and `foreground`.

`gallery theme render` runs the renderer; `tools/render-theme.py --print`
prints the resolved tokens without writing anything. The `GALLERY_CONFIG_DIR`
environment variable moves the config directory the renderer reads and writes.

## What the renderer writes

Each run writes all of these:

| Output | Content |
|---|---|
| `~/.config/gallery/state/theme.css` | `:root { --gallery-<token>: <value>; ... }` |
| `~/.config/gallery/state/theme.json` | every token plus `name`, `light`, and the border tokens |
| `~/.config/gallery/state/theme.sh` | `export` lines for shell scripts |
| `~/.config/gallery/state/crystal.css` | CSS for the Übersicht widgets; empty unless widgets mode is `theme` |
| `~/Library/Application Support/iTerm2/DynamicProfiles/gallery-theme.json` | iTerm2 profile "Gallery" |
| `~/Library/Application Support/iTerm2/DynamicProfiles/gallery-console.json` | iTerm2 profile "Console" |
| `~/.config/gallery/state/terminals/ghostty.conf` | Ghostty theme: palette, colours, glass, font |
| `~/.config/gallery/state/terminals/kitty.conf` | kitty theme |
| `~/.config/gallery/state/terminals/wezterm.lua` | WezTerm config module for your `wezterm.lua` to merge |
| `~/.config/gallery/state/terminals/gallery-osc.sh` | the palette as escape sequences, loaded in floating windows on terminals with no per-window config |
| `~/.config/gallery/state/terminals/glass.env` | the glass values (`opacity`, `blur`) `bin/gallery-term` passes to WezTerm |
| `~/.config/btop/themes/gallery.theme` | btop theme; `color_theme = "gallery"` is set in `~/.config/btop/btop.conf` |
| `~/Library/Application Support/superfile/theme/gallery.toml` | superfile theme; `theme` and `transparent_background = true` are set in superfile's `config.toml` |

For btop and superfile only the named keys of the existing config file are
rewritten, and a missing file is created with just those keys.

### state/theme.css

One custom property per token, named `--gallery-` plus the token with `_`
replaced by `-`: `--gallery-background`, `--gallery-accent`,
`--gallery-surface-background`, `--gallery-color4`, `--gallery-selection-background`,
and one per raw `colors.toml` key (`--gallery-dark-background`,
`--gallery-hyprland-active-border`, ...). `--gallery-muted`, `--gallery-danger`,
`--gallery-success`, `--gallery-warning` and `--gallery-info` are the aliases
above. With `gallery font set`, `--gallery-font-family` and
`--gallery-font-weight` are added. `name`, `light` and the border tokens are
not in the CSS. The Spoon does not read this file; panel and overlay pages get
their variables injected by the Spoon (see
[PLUGINS.md](PLUGINS.md#windowgallery)), which are built from `theme.json`.

### state/theme.json

Every token (sorted keys), plus `name`, `light` (boolean), the aliases
`muted`, `danger`, `success`, `warning`, `info`, and the focus-outline tokens
`border_active` (a JankyBorders colour), `border_active_hex`, `border_inactive`,
`border_width` and `border_bright`. `Gallery.spoon/lib/theme.lua` uses this
file when its `name` matches the current theme and it carries every required
token; otherwise it parses `colors.toml` itself.

### state/theme.sh

Source it from a shell script to colour the output. Variables:

| Variable | Value |
|---|---|
| `GALLERY_THEME_NAME` | theme name |
| `GALLERY_BG` | `surface_background` |
| `GALLERY_FG`, `GALLERY_ACCENT` | `foreground`, `accent` |
| `GALLERY_MUTED` | `color8` |
| `GALLERY_COLOR0` to `GALLERY_COLOR15` | `color0` to `color15` |
| `GALLERY_BORDER_ACTIVE`, `GALLERY_BORDER_ACTIVE_HEX`, `GALLERY_BORDER_INACTIVE` | focus-outline colours |
| `GALLERY_BORDER_WIDTH`, `GALLERY_BORDER_BRIGHT` | width (1 to 12, default 5), `1` or `0` |
| `CRYSTAL_BAR_COLOR` | only in widgets `theme` mode: `rgba(r,g,b,1.0)` of the accent |

`bin/gallery-borders` and the weather plugin read it.

### Ghostty, kitty and WezTerm

Written on every render, whatever terminal is configured (`gallery terminal`).
All three map the same tokens: the 16 ANSI colours (`color0` to `color15`),
`background`, `foreground`, `cursor`, the selection pair, the shared glass
(by default opacity 0.88, blur 9, the inverse of the iTerm2 profiles'
transparency 0.12; see `gallery glass`),
and, only while `gallery font set` holds a preference, the font family and size
(the weight is not mapped).

- `ghostty.conf` uses `palette = N=#rrggbb`, `background`, `foreground`,
  `cursor-color`, `cursor-text`, `selection-background`, `selection-foreground`,
  `background-opacity`, `background-blur`, `font-family`, `font-size`.
- `kitty.conf` uses `colorN`, `background`, `foreground`, `cursor`,
  `cursor_text_color`, `selection_background`, `selection_foreground`,
  `background_opacity`, `background_blur`, `font_family`, `font_size`.
- `wezterm.lua` is a module returning a table: `colors` (`foreground`,
  `background`, `cursor_bg`, `cursor_fg`, `cursor_border`, `selection_bg`,
  `selection_fg`, `ansi`, `brights`), `window_background_opacity`,
  `macos_window_background_blur`, and `font`/`font_size`. It adds itself to
  wezterm's config-reload watch list. In console `native` mode it returns an
  empty table, because the Gallery never edits your Lua to switch it off.
- `gallery-osc.sh` is a POSIX `sh` fragment: OSC 4 for the 16 colours and
  OSC 10, 11, 12 for foreground, background and cursor. `bin/gallery-term`
  sources it inside a floating Gallery window, which is how Ghostty (no
  per-window config) and WezTerm get the theme on one window only.

Floating Gallery windows always use the theme: iTerm2 through the "Gallery"
profile, kitty through `--config` with `kitty.conf`, WezTerm through
`--config` glass and the escape sequences, Ghostty through the escape
sequences (its opacity and blur stay yours). Your everyday terminal follows the
theme only after `gallery console theme`: iTerm2's "Console" profile, one
include line in the Ghostty or kitty config, two Lua lines for WezTerm.

After writing, the renderer asks every supported terminal that is already
running, configured or not, to pick the change up: Ghostty over AppleScript
(`reload_config`), and kitty with `kitty @ set-colors` when a remote-control
socket is reachable (`allow_remote_control` and `listen_on` in `kitty.conf`).
kitty also re-reads the changed include by itself, WezTerm reloads its module
by itself, and iTerm2 reloads its dynamic profiles. Nothing is ever launched for
this. `GALLERY_NO_TERMINAL_RELOAD=1` skips it.

### iTerm2 profiles

Both are dynamic profiles; iTerm2 reloads them when the file changes.

- **Gallery** (`Guid` `gallery-theme`) is what floating windows opened by
  `bin/gallery-tui` use. It sets the background, foreground, cursor, cursor
  text, selection, selected text and ANSI 0 to 15 colours from the tokens, and
  behaviour for a throwaway window: sessions close when the command ends,
  no prompt before closing, no bell, 1000 lines of scrollback.
- **Console** (`Guid` `gallery-console`) is a child of your own "Default"
  profile (`Dynamic Profile Parent Name`), so it inherits everything it does
  not set. In `native` mode (the default) it sets nothing, so it equals
  Default. In `theme` mode (`gallery console theme`) it sets the same colours plus a bold colour.
  Making it the default profile is a one-time manual step; see
  [INSTALL.md](INSTALL.md#first-run-permissions).

Both profiles use the theme's ordinary `background` (not `surface_background`)
with the same glass: by default `Transparency` 0.12 and a blur of radius 9 (the
defaults `CONSOLE_TRANSPARENCY` and `CONSOLE_BLUR_RADIUS` in
`tools/render-theme.py`). `gallery glass set <transparency 0-0.9> [<blur 0-64>]`
records your own in `~/.config/gallery/state/glass.json`
(`{"transparency": 0.2, "blur": 12}`) and re-renders; `gallery glass default`
removes it. The renderer clamps out-of-range values, and a malformed file only
warns on stderr and falls back to the defaults. The other terminals get the same
values as opacity (1 minus the transparency) and blur.
Floating and tiled terminals therefore look alike. With `gallery font set`,
both also get `Normal Font` and `Use Non-ASCII Font` false (Console only in
`theme` mode); the font family is resolved to a PostScript name with
`fc-list`, and if it cannot be resolved the renderer warns and skips the font
keys.

### btop and superfile

btop: `main_bg` is empty, which is the terminal's own background, so btop
takes on its window's glass. `main_fg`, `selected_fg` and `graph_text` are
`foreground`; `title`, `hi_fg`, `selected_bg` and `proc_misc` are `accent`;
the neutral chrome (`inactive_fg`, `meter_bg`, `cpu_box`, `mem_box`,
`div_line`) is `lighter_background`, else `muted`, else `color8`; `net_box`
is `color4` and `proc_box` is `color5`; the graph gradients use `color1` to
`color6`, `color10` and `orange` (else `color3`).

superfile: panels, footer, sidebar and modals use `background`, with
`transparent_background = true` so the terminal's glass shows through;
`accent` marks the active elements, `muted` (else `color8`) the neutral
borders, and `color1`, `color2`, `color4`, `color5`, `color6` the rest. The
code-preview syntax style is the same-named style for the themes in
`SUPERFILE_SYNTAX_STYLES` (catppuccin, catppuccin-latte, gruvbox, nord,
rose-pine, tokyo-night), else `github` (light) or `github-dark`.

Neither the renderer nor the hooks signal a running btop or superfile; a new
instance picks the theme up.

### state/crystal.css

For an Übersicht widget set that is not published. In widgets `theme` mode it
declares `--crystal-static` (`bright_foreground`, else `light_foreground`,
else `foreground`), `--crystal-static-20`, `-45`, `-65`, `-70`, `-75`, `-85`,
`-90` and `-92` (the same colour at that percent alpha) and
`--crystal-dynamic` (`accent`). In `native` mode, the default, the file holds
only a comment, so the widgets keep their own colours. Without the widget
set this is a no-op; `gallery widgets available` exits 1.

## Hooks

After a theme change, `gallery theme set` and `gallery theme next` run every
executable regular file in `~/.config/gallery/hooks/theme-set.d/`, in
name order (shell glob order), each as `hook <theme-name>`. A hook that fails
prints `gallery: hook failed: <name>` and the rest still run. `theme render`
does not run hooks.

`install.sh` copies the examples from `tools/hooks/` into that directory with
mode 755. Files you add beside them are not removed (a file of the same name
is overwritten):

| Hook | Does |
|---|---|
| `10-log-theme.sh` | appends a line to `~/Library/Logs/gallery.log` |
| `20-borders.sh` | runs `~/bin/gallery-borders apply` to recolour the focus outline; exits quietly if the helper is absent |
| `30-wallpaper.sh` | sets the desktop picture; see below |

Write your own as an executable script that takes the theme name as `$1`,
for example `~/.config/gallery/hooks/theme-set.d/40-editor.sh`. Hooks run
synchronously, so keep them quick. `GALLERY_THEME_HOOKS_DIR` points the CLI
at a different hooks directory (the tests use it).

## Wallpapers

Wallpapers are not in this repository. `./install.sh` downloads Omarchy's
own for every theme that has none yet (`--no-wallpapers` skips that), and
the same script it uses can be run by hand:

```sh
tools/fetch-omarchy-backgrounds.sh <theme-name>...   # one or more vendored themes
tools/fetch-omarchy-backgrounds.sh --all [--force]   # every vendored theme
```

Images are placed in `~/.config/gallery/themes/<name>/backgrounds/` (existing
files are skipped unless `--force`). You can also put your own images there;
recognised extensions are `jpg`, `jpeg`, `png`, `heic` and `webp`. A theme with
no `backgrounds/` directory applies everywhere except the desktop picture; the
hook logs `wallpaper: no wallpaper for <theme>` and exits 0.

`30-wallpaper.sh` picks the image in this order:

1. an explicit argument (`$2`: a filename in the theme's `backgrounds/`, or an
   absolute path), which only `gallery bg` passes;
2. the filename recorded for the theme in `state/backgrounds.json`, if it still
   exists;
3. a file named `default.<ext>`;
4. the first image by filename.

`gallery bg list|current|set <file>|next|prev|apply [theme]` manages the
recorded choice. `set`, `next` and `prev` record it and apply it at once if the
theme is the current one (otherwise they record only); `apply` re-applies the
current choice. They call the wallpaper hook directly and do not render or run
the other hooks.

The hook sets the picture through System Events, which only reaches the
display default and the primary Space. A Space that was ever given its own
picture keeps an override in
`~/Library/Application Support/com.apple.wallpaper/Store/Index.plist` that
shadows it, so by default the hook then copies the primary entry into every
Space entry there and restarts `WallpaperAgent`. `GALLERY_WALLPAPER_ALL_SPACES=0`
keeps the plain System Events behaviour, and `GALLERY_WALLPAPER_DRY_RUN=1`
prints what would be applied without applying it.

## What re-themes when

| Action | Renderer outputs | Hooks | Open panels and overlays |
|---|---|---|---|
| `gallery theme set <name>`, `theme next`, picking a theme in the Themes plugin | yes | all (log, borders, wallpaper) | re-injected |
| `gallery theme render` | yes | none | not touched |
| `gallery console theme\|native\|toggle` | yes (changes the Console profile, the WezTerm module) and, for Ghostty and kitty, adds or removes the include line in your config | none | not touched |
| `gallery terminal set <name>` | yes | none | not touched |
| `gallery glass set\|default` | yes (profiles' transparency and blur, the terminal files, `glass.env`) | none | not touched |
| `gallery font set\|native` | yes (profiles' font, `--gallery-font-*`) | none | not touched |
| `gallery widgets theme\|native\|toggle` | yes (`crystal.css`, `CRYSTAL_BAR_COLOR`) | none | not touched |
| `gallery borders width\|bright` | yes | none, but runs `gallery-borders apply` | not touched |
| `gallery bg set\|next\|prev\|apply` | no | the wallpaper hook only | not touched |
| `./install.sh` | yes (`theme render`) | none; re-syncs `borders` | no |
| Spoon start or reload | no | none | the Spoon reads `state/theme.json` |

Notes:

- "Renderer outputs" is every file in the table above. Running iTerm2 windows
  pick up a changed profile because iTerm2 reloads dynamic profiles itself;
  Ghostty and kitty are nudged by the renderer and WezTerm reloads on its own
  (see Ghostty, kitty and WezTerm above).
- The focus outline is recoloured only by the `20-borders.sh` hook, by
  `gallery borders`, or by `./install.sh`, not by `theme render`.
- Omarchy QML plugins read the theme's `colors.toml` directly through the
  `~/.config/omarchy/current/theme` and `~/.local/state/omarchy/current/theme`
  links, which point at `~/.config/gallery/themes/current`, so they follow
  `theme set` by themselves when they next read it.
- `tui` plugins that source `state/theme.sh` get the new colours the next
  time they are started.
