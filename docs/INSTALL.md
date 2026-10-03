# Installing The Gallery

Step-by-step setup for a new Mac. The top-level `README.md` explains what the
pieces are; this page is the order to do things in.

Contents: [Prerequisites](#prerequisites) -
[Run the installer](#run-the-installer) -
[First-run permissions](#first-run-permissions) -
[Verify](#verify) -
[Set up your coding agent](#set-up-your-coding-agent) -
[Optional extras](#optional-extras) -
[Updating](#updating) -
[Uninstalling](#uninstalling) -
[Troubleshooting](#troubleshooting)

## Prerequisites

The same table as the README's "Prerequisites" section, in brief:

| Prerequisite | How | Why |
|---|---|---|
| Homebrew | [brew.sh](https://brew.sh) | the installer brews everything else; it stops up front if `brew` is missing |
| A terminal: iTerm2, Ghostty, kitty or WezTerm | `brew install --cask iterm2` (or `ghostty`, `kitty`, `wezterm`) | every floating TUI window, Learn, `super+return` and the agent window; one is enough. iTerm2 is the most tested and the default whenever installed. Apple's Terminal is not supported; with none of the four installed, the installer brews iTerm2 (and stops only if that fails). See [Choosing the terminal](#choosing-the-terminal) |
| Hammerspoon | `brew install --cask hammerspoon` | the plugin host (the installer refuses to run without `/Applications/Hammerspoon.app`) |
| Optional: a coding agent | `brew install --cask claude-code` (or Codex, Gemini, opencode, ...) | the agent key, shift + ctrl + super + a; see `gallery agent list` |
| Optional: chafa, uv | `brew install chafa uv` | picker previews; the venv for the `qml` kind |
| Optional: librsvg | `brew install librsvg` | transparent weather icon (`rsvg-convert`); without it the weather panel falls back to chafa or a glyph |
| Optional: a folder of markdown sheets | none | the Learn menu reads them; Obsidian is not required |

Notes:

- The stock `/bin/bash` 3.2 and the system `python3` are enough. `git`, `rsync`
  and `python3` are expected on `PATH`.
- Homebrew can be at `/opt/homebrew` (Apple silicon) or `/usr/local`
  (Intel); the scripts look in both.
- **Intel Macs** on a current macOS need nothing special: Homebrew lives in
  `/usr/local` there and every script looks for it in both places. The
  differences below come from an older macOS, not from Intel as such.
- **Older Macs.** The Gallery runs on macOS 12 Monterey and later, with these
  differences:
  - Hammerspoon 1.1 and later need macOS 13. On macOS 12, install
    [Hammerspoon 1.0.0](https://github.com/Hammerspoon/hammerspoon/releases/tag/1.0.0)
    by hand.
  - Homebrew's iTerm2 cask needs macOS 13, but iTerm2 3.6.x runs on 12.4 and
    later: download it from [iterm2.com](https://iterm2.com/downloads.html).
    Ghostty needs macOS 13. kitty still supports macOS 12 (0.49 does) and is
    the best of the supported terminals there: `gallery terminal set kitty`,
    then `gallery console theme` for its colours.
  - JankyBorders needs macOS 14, so the installer skips it before Sonoma and
    Hammerspoon draws the focus outline instead. It takes the same colour and
    width, and `gallery borders` sets it the same way. It is not quite as
    smooth: while you drag or resize a window the outline follows a moment
    behind, and it sits above other windows rather than just under them.
  - Homebrew no longer has prebuilt packages for macOS 12 and builds from
    source. That is quick for yabai and skhd and takes a few minutes for fzf
    and glow (Go), but btop pulls in LLVM, which takes hours on an old Mac:
    run `./install.sh --minimal` to leave btop and superfile out.
  - The macOS Python 3 (3.9 on Monterey) is enough for the theme renderer;
    nothing else needs installing for it.
  - macOS 15 and later include `jq`; on older systems the installer brews it
    (the Ghost Windows check needs it), even with `--minimal`.
  - On a Homebrew that has never installed an app (a cask), the first one asks
    for your password, because Homebrew must create `/usr/local/Caskroom`;
    run it in a terminal on that Mac, for example
    `brew install --cask claude-code`.
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
git clone https://github.com/locupleto/the-gallery
cd the-gallery
./install.sh --dry-run     # optional: print what would happen, change nothing
./install.sh
```

The `gallery` command is installed in `~/bin`. If that folder is not on your
PATH, the installer ends with a note and the line to add (once):

```sh
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zprofile
```

Flags:

| Flag | Effect |
|---|---|
| `--dry-run` | print every step, change nothing (also passed to `tiler/install.sh`) |
| `--uninstall` | remove the Gallery and restore what it replaced; see [Uninstalling](#uninstalling) |
| `--purge` | with `--uninstall`: also delete `~/.config/gallery/`; asks first |
| `--yes` | with `--purge`: do not ask (required when not run from a terminal) |
| `--keep-wallpaper` | with `--uninstall`: do not restore the saved wallpaper settings |
| `--skip-tiler` | do not run `tiler/install.sh` (yabai, skhd, JankyBorders, Learn); plugin host and theming only |
| `--restart-tiler` | passed to `tiler/install.sh` as `--restart`: restart yabai and skhd even if their config did not change |
| `--minimal` | do not `brew install` the companion apps (btop, superfile) |
| `--no-wallpapers` | do not download Omarchy's wallpapers (about 50 MB from github.com/basecamp/omarchy) |
| `-h`, `--help` | print usage |

An unknown flag prints the usage and exits 1.

In order, the installer:

1. Checks that `/Applications/Hammerspoon.app` exists (override the path with
   `GALLERY_HAMMERSPOON_APP`) and that `brew` is on `PATH` (Homebrew is not
   required with `--skip-tiler --minimal`).
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
   `~/.hammerspoon/init.lua`: the file is created if missing; an existing one
   is copied to `init.lua.gallery-bak` once and the block appended; a block
   already there is replaced in place if it is out of date. The block loads
   `hs.ipc`, loads and starts the Spoon, and reloads Hammerspoon when a `.lua`
   file under `~/.hammerspoon/` changes.
7. Copies `skhd/gallery.skhd` to `~/.config/skhd/`, runs `tiler/install.sh`
   (brew installs yabai, skhd, JankyBorders, fzf and glow; copies the rc files;
   starts the services, restarting one only when its effective config
   changed), then reloads skhd and regenerates the Learn key sheet.
8. Links `~/.config/omarchy/current/theme` and
   `~/.local/state/omarchy/current/theme` to `~/.config/gallery/themes/current`
   so Omarchy QML plugins find their colours. A real directory at either path
   is left alone; a symlink of yours is replaced, and its target recorded so
   uninstalling points it back.
9. Runs `gallery theme render`, re-syncs the focus outline if `borders` is
   running, and waits up to 12 seconds for the Spoon's ready stamp
   (`~/.config/gallery/state/ready`). If none appears it touches
   `~/.hammerspoon/init.lua` to trigger a reload and waits again; after a
   second miss it quits and relaunches Hammerspoon. If Hammerspoon was not
   running it is started in the background.

### What is backed up, and what is recorded

The installer is idempotent, and it does not overwrite a file of yours without
keeping it.

- **Files it installs** (the rc files, `gallery.skhd`, the helper scripts, the
  hooks, `~/bin/gallery*`): each is recorded with its checksum in
  `~/.config/gallery/state/install-manifest.tsv`. If the destination already
  exists and is not in the manifest, it is moved to `<name>.gallery-bak` first
  (to `<name>.gallery-bak.<timestamp>` if that name is taken) and the message
  says so. If it is in the manifest but you changed it since, your version is
  copied to `<name>.gallery-edited.<timestamp>` before the new one goes in;
  keep lasting changes in a local override file instead of editing installed
  files. A copy that is unchanged is overwritten silently. A file left by an
  older install, from before the manifest existed, is recognised by its
  header: it is overwritten with a `.gallery-edited` safety copy, not treated
  as yours.
- **Files it edits in place** (`init.lua`, the Ghostty and kitty configs while
  the console follows the theme, btop's `btop.conf`, superfile's
  `config.toml`): copied to `<name>.gallery-bak` before the first edit, and
  never again. For btop and superfile the renderer also records the original
  value of each key it sets in `state/conf-originals.json`, and only touches
  them if the app is installed or its config directory already exists.
- **Wallpaper**: before the first background is applied, the system's wallpaper
  store is copied to `~/.config/gallery/state/wallpaper-original.plist`.
  `gallery bg restore` puts it back and restarts the wallpaper agent.
- **Directories the installer owns** (the Spoon, the bundled plugins, `qml/`,
  `patches/`) are synced so they match the checkout. A file you added inside
  one is copied to `~/.config/gallery/backup/<timestamp>/` before the sync
  removes it. Edits to a shipped file in them are overwritten.

Re-running it never touches the `state/` preferences, `gallery.json`, the
`themes/current` link, themes you added by hand, or plugins added with
`gallery add`. `--dry-run` says which files it would back up and which it would
overwrite.

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
6. **iTerm2: nothing to do.** The renderer writes two iTerm2 dynamic
   profiles. "Gallery" is used by the floating windows. "Console" is a child
   of your own "Default" profile carrying the theme's colours; the windows
   the Gallery opens use it, and the installer makes it iTerm2's default
   profile so iTerm2's own Cmd-N windows follow the theme too. It also sets
   iTerm2's window style to *Minimal*, which paints the title bar and tabs in
   the terminal's background colour, so the whole window follows the theme
   instead of the system's light or dark look. Your own default and window
   style are noted first and given back by `gallery console native`,
   `gallery off` and uninstalling. If iTerm2 is running while you install,
   that waits until you next quit it: a running iTerm2 puts its own settings
   back over any outside change. `gallery console status` prints
   `default profile: Console (ok)` once it has happened. To do it by hand:
   Settings (Cmd-,), Profiles, select "Console", Other Actions, Set as
   Default. Do not make "Gallery"
   the default: it closes its session when the command ends and never
   prompts, which suits a floating TUI and not a shell.
7. **iTerm2's own questions**, asked once in each account, the first time
   the Gallery opens a window in it:
   - "iTerm2 would like to find devices on your local network": iTerm2 asks
     this itself on its first start. The Gallery does not need it; either
     answer works.
   - "Allow terminal-initiated display?" (or similar), when the theme or
     wallpaper picker first shows a preview: the previews are pictures drawn
     through iTerm2's inline-image feature. Allow it, and tick *remember*, or
     the previews stay empty.

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
  `~/.config/kitty/kitty.conf`. Running windows re-read the changed include
  on a theme change; enabling remote control there (`allow_remote_control
  socket-only` and `listen_on unix:/tmp/kitty`) also lets the renderer push the
  colours at once.
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

## Set up your coding agent

shift + ctrl + super + a opens a coding agent (Claude Code by default) in a
new tile. Tell it two things once per Mac:

```sh
gallery agent set claude       # or codex, gemini, opencode, copilot, crush,
                               # or: set <name> --command "<any CLI>"
gallery agent dir ~/Code       # the folder that holds your repositories
gallery agent status           # check both
```

The agent starts in that folder, so it asks to trust it once and that covers
every repository inside it. Without a folder set it starts in your home
folder. It runs without stopping to ask before each command or edit, so pick
the folder with that in mind. More in
[Getting started](GETTING-STARTED.md#set-up-your-coding-agent).

## Optional extras

- **QML plugins.** `gallery-qml --setup` creates the venv at
  `~/.config/gallery/qml-venv` (a uv-managed Python 3.12 plus PySide6, so it
  needs `uv` and network access) and the `Gallery.app` wrapper at
  `~/.config/gallery/Gallery.app`, and launches nothing. The installer does
  not do this itself so it stays fast and offline; the venv is also built on
  the first run of any `qml` plugin. See [PLUGINS.md](PLUGINS.md).
- **Wallpapers.** They are never in the repository; the installer downloads
  Omarchy's own for every theme that has none yet, unless run with
  `--no-wallpapers`. To fetch them later, or again:

  ```sh
  tools/fetch-omarchy-backgrounds.sh --all        # or theme names; --force re-downloads
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

Updating from a release older than 2026-10-02 (before the install manifest):

- The first run cannot yet tell its own files from yours, so it keeps a copy
  of each earlier Gallery file it replaces as `<name>.gallery-edited.<time>`.
  If you never edited those files, delete the copies; if you did, move the
  change into `local.skhd`, `yabairc.local` or a hook (see
  [CUSTOMIZING.md](CUSTOMIZING.md)).
- The app keys on super + a, e, y, x and g are no longer bound by the shipped
  key file. Copy the ones you used from `tiler/local.skhd.example` into
  `~/.config/skhd/local.skhd` before you update, and they carry on working.

Plugins added with `gallery add` update separately: `gallery update [id]`
fast-forwards git-managed plugins and re-applies any macOS patches from
`patches/`.

## Uninstalling

```sh
./install.sh --uninstall           # add --dry-run first to preview
./install.sh --uninstall --skip-tiler
```

The aim is that the Mac ends up as it was. The uninstaller works from the
install manifest and the backups described under
[What is backed up](#what-is-backed-up-and-what-is-recorded):

- stops yabai and skhd and unregisters their launchd services
  (`--uninstall-service`), so they do not start again at the next login
  (skipped with `--skip-tiler`). It also stops JankyBorders, unless
  `brew services list` shows it registered, in which case it is left running;
- removes each file it installed if it is still unchanged, and moves one you
  edited to `<name>.gallery-edited.<timestamp>`; where an installed file
  replaced one of yours, the `.gallery-bak` is moved back. This covers the rc
  files, the tiler helpers, `Learn.app`, `gallery.skhd`, the hooks and the
  `gallery*` commands in `~/bin/`;
- removes the Gallery block from `~/.hammerspoon/init.lua` (restoring the
  backup if the file is otherwise as it was, deleting the file if the
  installer created it and nothing else is in it) and then the Spoon;
- removes the `include` line from your kitty config, the `config-file` line
  from your Ghostty config, and `~/.wezterm.lua` if it is still exactly what
  the Gallery wrote (a wezterm config of yours is only reported);
- gives back iTerm2's default profile and window style as they were before
  the Gallery; if iTerm2 is running, that happens by itself the moment you
  quit it (the summary prints the commands, should you log out first);
- removes the iTerm2 profile `gallery-theme.json`, and `gallery-console.json`
  unless iTerm2's default profile is still Console (then once iTerm2 quits);
- restores the btop and superfile settings it changed, and removes the themes
  it rendered for them;
- removes the two Omarchy theme links if they point into `~/.config/gallery`;
- restores the saved wallpaper settings (`--keep-wallpaper` skips this);
- ends with a summary of what was restored, removed and kept.

It leaves in place `~/.config/gallery/` (plugins, themes, state, the
manifest's backups) and the Homebrew formulae, including btop and superfile.
`--purge` also deletes `~/.config/gallery/` and the Gallery's log, after
everything above has been restored. Empty directories the installer created
are removed.

```sh
./install.sh --uninstall --dry-run   # lists each file it would remove or restore
./install.sh --uninstall --purge
```

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

**`hs CLI not installed`.** The Gallery's block in `~/.hammerspoon/init.lua`
links the `hs` tool into Homebrew's `bin` each time Hammerspoon loads it. If
it is still missing, run `hs.ipc.cliInstall("/opt/homebrew")` in the
Hammerspoon console (`"/usr/local"` on an Intel Mac).

**Installing over SSH.** The installer itself runs fine over SSH, but the
permission prompts appear on that Mac's own screen. Anything that talks to
System Events, `gallery doctor` among them, waits until someone answers the
prompt there, so it seems to hang. Give the Accessibility grants and answer
the first prompts at the Mac.

**The first window after a permission prompt opens blank and tiled.** A
terminal that is still starting when its first window is created can reach
yabai without its title, so the rule that floats Learn and the pickers does not
match. Close it and press the key again; once the terminal is running it does
not recur.

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
