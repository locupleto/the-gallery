# Installing The Gallery

Step-by-step setup for a new Mac. The top-level `README.md` explains what the
pieces are; this page is the order to do things in.

Contents: [Prerequisites](#prerequisites) -
[Run the installer](#run-the-installer) -
[First-run permissions](#first-run-permissions) -
[Verify](#verify) -
[Optional extras](#optional-extras) -
[Updating](#updating) -
[Uninstalling](#uninstalling) -
[Troubleshooting](#troubleshooting)

## Prerequisites

The same table as the README's "Prerequisites" section, in brief:

| Prerequisite | How | Why |
|---|---|---|
| Homebrew | [brew.sh](https://brew.sh) | the installer brews everything else; it stops up front if `brew` is missing |
| A terminal: iTerm2, Ghostty, kitty or WezTerm | `brew install --cask iterm2` (or `ghostty`, `kitty`, `wezterm`) | every floating TUI window, Learn, `super+return` and the agent window; one is enough, see [Choosing the terminal](#choosing-the-terminal) |
| Hammerspoon | `brew install --cask hammerspoon` | the plugin host (the installer refuses to run without `/Applications/Hammerspoon.app`) |
| Optional: chafa, uv | `brew install chafa uv` | picker previews; the venv for the `qml` kind |
| Optional: librsvg | `brew install librsvg` | transparent weather icon (`rsvg-convert`); without it the weather panel falls back to chafa or a glyph |
| Optional: a folder of markdown sheets | none | the Learn menu reads them; Obsidian is not required |

Notes:

- The stock `/bin/bash` 3.2 and the system `python3` are enough. `git`, `rsync`
  and `python3` are expected on `PATH`.
- Homebrew is expected at `/opt/homebrew` (Apple silicon). A few paths are
  fixed to it: `bin/gallery-tui` and `bin/gallery-qml` prepend it to `PATH`,
  the `spaces` feed in `Gallery.spoon/lib/bridge.lua` runs
  `/opt/homebrew/bin/yabai`, and the System Monitor plugin runs
  `/opt/homebrew/bin/btop`.
- Put `~/bin` on your shell `PATH`; the installer copies the `gallery*`
  commands there. The skhd key bindings call `$HOME/bin/gallery` by full path,
  so they work either way, but typing `gallery` in a terminal needs it.
- yabai needs *Displays have separate Spaces* on and *Automatically rearrange
  Spaces based on most recent use* off (System Settings, Desktop & Dock,
  Mission Control). `tiler/install.sh` prints a warning for each that is
  wrong, and for a running Magnet or Rectangle, which should be quit.
- The tiler deliberately does not install the yabai scripting addition, so
  System Integrity Protection stays enabled.

## Run the installer

```sh
git clone <this repository> the-gallery
cd the-gallery
./install.sh --dry-run     # optional: print what would happen, change nothing
./install.sh
```

Flags:

| Flag | Effect |
|---|---|
| `--dry-run` | print every step, change nothing (also passed to `tiler/install.sh`) |
| `--uninstall` | remove the Gallery; see [Uninstalling](#uninstalling) |
| `--skip-tiler` | do not run `tiler/install.sh` (yabai, skhd, JankyBorders, Learn); plugin host and theming only |
| `--restart-tiler` | passed to `tiler/install.sh` as `--restart`: restart yabai and skhd even if their config did not change |
| `--minimal` | do not `brew install` the companion apps (btop, superfile) |
| `-h`, `--help` | print usage |

An unknown flag prints the usage and exits 1.

In order, the installer:

1. Checks that `/Applications/Hammerspoon.app` exists and that `brew` is on
   `PATH` (Homebrew is not required with `--skip-tiler --minimal`).
2. Installs btop and superfile with Homebrew unless `--minimal`. A failed
   install only warns. Prints an advisory for fzf, chafa, btop and spf if any
   is missing.
3. Copies, rather than symlinks, the Spoon to
   `~/.hammerspoon/Spoons/Gallery.spoon`, the bundled plugins to
   `~/.config/gallery/plugins/`, the vendored themes to
   `~/.config/gallery/themes/` (existing themes are not deleted), the renderer
   to `~/.config/gallery/bin/render-theme.py`, the theme-set hooks to
   `~/.config/gallery/hooks/theme-set.d/`, and `qml/` and `patches/` to
   `~/.config/gallery/`. The comment at the top of `install.sh` explains why a
   copy is needed: launchd-started tools cannot read an external volume.
4. Points `~/.config/gallery/themes/current` at `tokyo-night` if no current
   theme is set.
5. Installs the commands `gallery`, `gallery-hs`, `gallery-tui`,
   `gallery-menu`, `gallery-borders`, `gallery-agent` and `gallery-qml` into
   `~/bin/`.
6. Writes a block delimited by `-- gallery:begin` and `-- gallery:end` into
   `~/.hammerspoon/init.lua` (creating the file, or appending to it), unless
   the file already mentions "Gallery". The block loads `hs.ipc`, loads and
   starts the Spoon, and reloads Hammerspoon when a `.lua` file under
   `~/.hammerspoon/` changes.
7. Copies `skhd/gallery.skhd` to `~/.config/skhd/`, runs `tiler/install.sh`
   (brew installs yabai, skhd, JankyBorders, fzf and glow; copies the rc files;
   starts the services, restarting one only when its effective config
   changed), then reloads skhd and regenerates the Learn key sheet.
8. Links `~/.config/omarchy/current/theme` and
   `~/.local/state/omarchy/current/theme` to `~/.config/gallery/themes/current`
   so Omarchy QML plugins find their colours. A real directory at either path
   is left alone.
9. Runs `gallery theme render`, re-syncs the focus outline if `borders` is
   running, and waits up to 12 seconds for the Spoon's ready stamp
   (`~/.config/gallery/state/ready`). If none appears it touches
   `~/.hammerspoon/init.lua` to trigger a reload and waits again; after a
   second miss it quits and relaunches Hammerspoon. If Hammerspoon was not
   running it is started in the background.

The installer is idempotent. Re-running it never touches what is yours: the
`state/` preferences, `gallery.json`, the `themes/current` link, themes you
added by hand, and plugins added with `gallery add`.

## First-run permissions

macOS does not allow these to be granted from a script. Do them in this order;
the later steps assume the earlier ones.

1. **Hammerspoon: Accessibility.** System Settings, Privacy & Security,
   Accessibility, enable Hammerspoon, then quit and reopen Hammerspoon. Also
   enable *Launch Hammerspoon at login* in its preferences; `gallery doctor`
   warns when it is not a login item. Until Hammerspoon runs with the grant,
   `gallery status` and the other commands that go through it fail (see
   [Troubleshooting](#troubleshooting)).
2. **yabai and skhd: Accessibility.** Both prompt on first start. Enable both
   under the same Accessibility list, then restart each so the grant takes
   effect:

   ```sh
   yabai --restart-service; skhd --restart-service
   ```

3. **Mission Control shortcuts.** System Settings, Keyboard, Keyboard
   Shortcuts, Mission Control: enable *Switch to Desktop N* for every Desktop
   you use. `super+N` and `super+shift+N` are built on these Ctrl+N shortcuts,
   because yabai cannot switch Spaces without the scripting addition.
4. **Secure Keyboard Entry off** in your terminal (iTerm2, Ghostty and kitty
   have it in their menus). While it is on, skhd does not see keys while that
   terminal is frontmost.
5. **Automation prompts**, raised the first time each binding is used. Allow
   each once:
   - "skhd wants to control iTerm2" (`super+return`, and every floating TUI
     such as the theme picker or System Monitor, which `bin/gallery-term`
     opens through AppleScript). The same prompt names Ghostty if that is your
     terminal; kitty and WezTerm are started as plain processes and raise none;
   - "skhd wants to control System Events" (`super+b`);
   - "Learn wants to control iTerm2" (launching Learn from Spotlight; again
     Ghostty on a Ghostty setup).
6. **iTerm2: default profile (only for `gallery console`).** The renderer
   writes two iTerm2 dynamic profiles. "Gallery" is used by the floating
   windows and needs no setup. "Console" is a child of your own "Default"
   profile and is what makes your everyday terminal follow the theme. In iTerm2:
   Settings (Cmd-,), Profiles, select "Console", Other Actions, Set as Default.
   Do not make "Gallery" the default: it closes its session when the command
   ends and never prompts, which suits a floating TUI and not a shell.
   `gallery console theme` then switches Console to the theme's colours
   (`native`, the default, leaves it identical to Default), and
   `gallery console status` prints `default profile: Console (ok)` once the
   setting has taken.

### Choosing the terminal

`gallery terminal` shows which terminal the Gallery opens windows in. With
nothing recorded it is iTerm2 if installed, otherwise the first installed of
Ghostty, kitty and WezTerm. `gallery terminal list` shows the supported ones
and which are installed; `gallery terminal set <name>` records the choice in
`~/.config/gallery/state/terminal.json` and re-renders the theme.

Per terminal, beyond the install:

- **iTerm2.** Steps 4 to 6 above.
- **Ghostty.** Nothing for floating windows. For `gallery console theme`, the
  Gallery adds `config-file = ?~/.config/gallery/state/terminals/ghostty.conf`
  to `~/.config/ghostty/config`; a running Ghostty is told to reload on every
  render. Set `initial-window = false` if a cold start opened by a keybinding
  should not leave Ghostty's own startup window behind.
- **kitty.** Nothing for floating windows. `gallery console theme` adds an
  `include` line for `state/terminals/kitty.conf` to
  `~/.config/kitty/kitty.conf`. For colours to change in running windows, enable
  remote control there: `allow_remote_control socket-only` and
  `listen_on unix:/tmp/kitty`.
- **WezTerm.** Nothing for floating windows. For `gallery console theme`,
  the Gallery prints two lines for your `wezterm.lua`
  (and writes `~/.wezterm.lua` with them if you have no config):

  ```lua
  local ok, gallery = pcall(dofile, wezterm.home_dir .. '/.config/gallery/state/terminals/wezterm.lua')
  if ok then for k, v in pairs(gallery) do config[k] = v end end
  ```

  The module puts itself on wezterm's reload watch list, so a theme change
  reloads running windows.

Alacritty is not supported yet.

## Verify

```sh
gallery doctor
gallery status
gallery theme next
```

`gallery doctor` prints one line per check, prefixed `OK`, `WARN`, `MISSING`
or `FAIL`, and exits 0 only when nothing is `MISSING` or `FAIL`. `WARN` lines
(fzf, glow, btop, the qml venv, a missing `borders.json`) are optional or
informational. On a fresh install before the grants above, expect `MISSING`
for Hammerspoon running, `hs CLI on PATH`, Accessibility granted, and the
yabai and skhd running checks.

`gallery status` prints one line from the Spoon, for example
`Gallery 0.1.0; plugins=13; errored=0; pluginDir=...; windows=0`. `errored`
should be 0.

`gallery theme next` switches to the alphabetically next theme and runs the
whole fan-out: the renderer, the hooks, and a reload of open panels. The
terminal windows, focus outline and (if fetched) wallpaper change together.
See [THEMES.md](THEMES.md).

Then try a binding: `super+space` (left Option plus space) opens Learn, and
`gallery open gallery.sysmon` opens the System Monitor in a floating window.

## Optional extras

- **QML plugins.** `gallery-qml --setup` creates the venv at
  `~/.config/gallery/qml-venv` (a uv-managed Python 3.12 plus PySide6, so it
  needs `uv` and network access) and the `Gallery.app` wrapper at
  `~/.config/gallery/Gallery.app`, and launches nothing. The installer does
  not do this itself so it stays fast and offline; the venv is also built on
  the first run of any `qml` plugin. See [PLUGINS.md](PLUGINS.md).
- **Wallpapers.** They are never in the repository. From the checkout:

  ```sh
  tools/fetch-omarchy-backgrounds.sh --all        # or one theme name; --force re-downloads
  ```

  Images land in `~/.config/gallery/themes/<name>/backgrounds/`. Without them
  a theme applies everywhere except the desktop picture. See
  [THEMES.md](THEMES.md#wallpapers).
- **Home Spaces.** Arrange your apps across Spaces, then run
  `gallery home save`. It writes `~/.config/yabai/rules.local` and applies it,
  so the apps return to their Spaces after a login. `gallery home show` prints
  the current map and `gallery home apply` re-applies the file. Nothing saves
  it automatically.
- **Weather.** `gallery weather key --set <key>` stores an OpenWeatherMap API
  key in `~/.config/gallery/weather.key` (mode 600; no `gallery weather`
  subcommand prints it back). `gallery weather location --set City,CC` sets the
  location (default `Stockholm,SE`) and `gallery weather units --set
  metric|imperial` the units. The panel opens with `ctrl+lalt-w`.
- **Learn sheets.** The menu reads markdown files from
  `~/.config/gallery/sheets` (override with `LEARN_SHEETS`). Without any it
  lists only the generated key sheet. See `tiler/README.md`.
- **Übersicht widgets.** `gallery widgets ...` and the picker's `ctrl-u` target
  a widget set that is not published. Without it `gallery widgets available`
  exits 1 and the rest is a no-op.

## Updating

```sh
cd the-gallery
git pull
./install.sh
```

Everything the installer manages is re-copied; the files listed under
[Run the installer](#run-the-installer) as yours are not touched. yabai and
skhd are restarted only if their effective config (rc files without comments
and blank lines) changed, because a yabai restart rebuilds every window tree;
the tiler saves and restores the layout around it. Pass `--restart-tiler` to
force it, or `--skip-tiler` to leave the tiler alone.

Plugins added with `gallery add` update separately: `gallery update [id]`
fast-forwards git-managed plugins and re-applies any macOS patches from
`patches/`.

## Uninstalling

```sh
./install.sh --uninstall           # add --dry-run first to preview
./install.sh --uninstall --skip-tiler
```

This stops yabai and skhd and removes their rc files, `Learn.app` and the
tiler helpers (unless `--skip-tiler`), removes the installed Spoon, and removes
the `gallery*` commands from `~/bin/`. It leaves in place:

- `~/.config/gallery/` (plugins, themes, state, preferences);
- `~/.config/skhd/gallery.skhd`;
- the Homebrew formulae, including btop and superfile;
- the iTerm2 dynamic profile files, the `state/terminals/` files, the include
  line `gallery console theme` added to a Ghostty or kitty config, and the btop
  and superfile theme files the renderer wrote;
- `~/.hammerspoon/init.lua`. Remove the block between `-- gallery:begin` and
  `-- gallery:end` by hand.

Delete `~/.config/gallery/` yourself for a clean slate.

## Troubleshooting

**Logs.** `gallery log` follows `~/Library/Logs/gallery.log` (the Spoon, theme
hooks and wallpaper hook). Other logs: `~/Library/Logs/gallery-qml.log` (QML
hosts), `~/Library/Logs/gallery-ghosts.log`, `~/Library/Logs/yabai-tree-guard.log`.

**`gallery status` hangs, then fails with exit code 124.** Commands that talk
to the Spoon go through `gallery-hs`, which gives each `hs` call 10 seconds
(`GALLERY_HS_TIMEOUT`), kills it if it is still waiting, retries once, and then
prints `error sending to remote: client watchdog timeout` or `error: can't
access Hammerspoon message port` and exits 124, after roughly 25 seconds. Causes:
Hammerspoon is not running, `hs.ipc` is not loaded (the `~/.hammerspoon/init.lua`
block is missing), or the request landed during a reload. Start Hammerspoon,
check the block, run `gallery reload`, and retry. Never wrap `hs` in
`timeout`: killing the client mid-request can wedge Hammerspoon's IPC port.

**`hs CLI not installed`.** The installer does not install the `hs` tool. In
the Hammerspoon console run `hs.ipc.cliInstall("/opt/homebrew")`.

**Key bindings do nothing.** Check that skhd is running with the Accessibility
grant (`gallery doctor`), that your terminal's Secure Keyboard Entry is off, and
watch the keys with `skhd --observe`. Test a binding from a cold state too, with
the terminal not running: `gallery-term` addresses iTerm2 by bundle id and
activates it when it is cold, launches and waits for Ghostty, and starts kitty
and WezTerm as processes.

**A floating TUI does not appear.** Run `gallery open <id>` from a terminal to
see the error. The usual cause is a missing Automation grant for skhd (or for
the terminal you ran it from) to control iTerm2 or Ghostty. `gallery-term open
--dry-run --role float -- true` prints what would be run. A `tui` command that is missing
or not executable prints an error in its own window and holds it for 3 seconds.

**yabai does not tile new windows.** `gallery doctor` reports
`FAIL yabai is blind` when no window has an accessibility reference. Dismiss any
pending Accessibility prompt and restart the service, for example
`launchctl kickstart -k gui/$(id -u)/com.asmvik.yabai`, as the doctor message
says. Windows created while the screen is locked never get a
reference; `gallery ghosts` lists them.

**The theme changes but the desktop picture does not.** No backgrounds are
installed for that theme; `~/Library/Logs/gallery.log` says
`wallpaper: no wallpaper for <theme>`. Fetch them (see above). If only the
current Space changes, see "bg" in the README for the per-Space override and
`GALLERY_WALLPAPER_ALL_SPACES`.

**The console does not follow the theme.** `gallery console status` must show
mode `theme` and `default profile: Console (ok)`.

**`gallery doctor` reports the qml venv missing.** Run `gallery-qml --setup`.

**Editing the scripts.** `install.sh` and the tiler scripts run under the stock
bash 3.2: an empty array expanded under `set -u` is an unbound variable. Use
`${arr[@]+"${arr[@]}"}`, as `install.sh` does.
