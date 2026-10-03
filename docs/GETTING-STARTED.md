# Getting started

The first half hour after [installing](INSTALL.md). By the end you will know
the two help keys, have tiled a few windows, moved between them and between
Spaces, changed the theme, and set up a coding agent. Nothing here changes
anything you cannot undo.

## What "super" is

Every key in the Gallery starts with **super**, which is the **left Option**
key. Right Option still types characters as usual (`@`, `{`, `|` and so on on
many layouts), so use it whenever you need one. If your layout does not
behave, see [Keyboard layouts](CUSTOMIZING.md#keyboard-layouts).

"super + h" means: hold left Option and press h.

## The two help keys

Learn these first. Everything else can be looked up with them.

- **super + space** opens the **Learn menu**: a floating terminal window
  listing cheat sheets. Type to filter the list, use the arrow keys to move,
  Enter shows the highlighted sheet (a preview appears on the right), and Esc
  closes the menu. A sheet is paged: arrows, PgUp, PgDn, the mouse wheel,
  `j`/`k`, space and `b` scroll, and `q`, Esc or Enter close it. There is no
  search inside a sheet. A new install has one sheet, the key sheet below;
  add your own markdown files to `~/.config/gallery/sheets`, or ask your
  coding agent to write them (see [Learn sheets](CUSTOMIZING.md#learn-sheets)).
- **super + shift + space** opens the **key sheet** directly: every binding
  from your `local.skhd`, `tiler.skhd` and `gallery.skhd`, generated from the
  files, so it is always current and includes keys you add yourself.

The Learn menu is also in Spotlight: search for "Learn". If the menu or sheet
does not appear, `gallery doctor` says what is missing (fzf and glow are
needed).

Two commands in a terminal:

```sh
gallery help       # every command
gallery doctor     # one line per check: OK, WARN, MISSING or FAIL
```

If keys do nothing, run `gallery doctor` first: it checks that yabai and skhd
are running.

## Switching it off for a while

New to tiling? You do not have to live in it all day. **shift + ctrl +
super + escape** switches the Gallery off, and the same key switches it back
on. From a terminal:

```sh
gallery off
gallery on
```

**Off** gives you plain macOS:

- Windows go back to the size and place they had before the tiling took
  them: the ones that were open when you last switched the Gallery on (or
  installed it). A window you opened since has no earlier place, so it stays
  where the tiling put it, as an ordinary window. Windows that macOS reopens
  after a restart count as new ones, so if you restart while the Gallery is
  on, they too stay where the tiling put them.
- yabai, skhd and the focus outline stop. Every key goes back to macOS, and
  left Option types characters again.
- Your terminals go back to their own colours (and iTerm2 to your own
  default profile).
- It stays off until you switch it on, also after you log out or restart the
  Mac.

**On** tiles again:

- Every ordinary window on screen is tiled at once, Finder windows included.
  Dialogs, System Settings and other windows the Gallery floats on purpose
  stay floating, and minimised windows stay minimised.
- The tiles start from even splits: split ratios you adjusted by hand before
  switching off are not kept.
- Your terminals follow the theme again.

The theme and wallpaper stay as they are either way.
`gallery doctor` says when the Gallery is off.

While it is off, the switch-on key is held by Hammerspoon, since skhd is not
running. If Hammerspoon is not running, use `gallery on`. Running
`./install.sh` also switches the Gallery on.

## A guided walk

Do these in order. Windows tile by themselves: each new window splits the
space the focused one had.

1. **Open a terminal: super + return.** Press it twice more. Each window
   takes a share of the screen, with gaps between them. The focused one has a
   coloured outline.
2. **Move focus: super + h / j / k / l** (left / down / up / right, as in
   vim). super + tab jumps back to the previous window.
3. **Move a window: super + shift + h / j / k / l** swaps it with its
   neighbour in that direction. super + the arrow keys resize it.
4. **Switch Spaces: super + 1 ... 9.** Spaces are macOS desktops. This works
   by pressing Mission Control's "Switch to Desktop N" shortcuts for you, so
   they must be on: System Settings, Keyboard, Keyboard Shortcuts, Mission
   Control, tick "Switch to Desktop N" for each desktop you use. A Space must
   exist to be reached; add desktops in Mission Control.
5. **Send a window to a Space: super + shift + 1 ... 9.** The window moves
   and you follow it.
6. **Float, zoom, close.** super + t floats a window (centred, not tiled;
   again to tile it back). super + f zooms it to fill the display (again to
   undo). super + w closes it. super + m minimizes it.
7. **Open a browser window: super + b.** It opens in your default browser.
   The first press asks for permission to control System Events: allow it.
8. **Change the look.** super + shift + ctrl + space opens the theme picker:
   Enter applies a theme to the terminals, the outline, the wallpaper, btop
   and superfile at once. super + shift + ctrl + b opens the background
   picker, and super + ctrl + space switches to the next wallpaper of the
   current theme. Wallpapers are not in the repository, see
   [Wallpapers](CUSTOMIZING.md#wallpapers).
9. **Gallery plugins.** super + shift + 0 opens the System Monitor (btop),
   super + ctrl + 0 a picker of your Spaces and windows, and super + ctrl + w
   the weather panel (it needs an API key, see
   [INSTALL.md](INSTALL.md#optional-extras)). Each key again closes its
   window.

The first press of a key that opens something may raise a macOS prompt such as
"skhd wants to control iTerm2". Allow it once.

### The most common keys

| Keys | What it does |
|---|---|
| super + space | Learn menu |
| super + shift + space | the key sheet |
| super + return | new terminal window |
| super + b | new browser window |
| super + h / j / k / l | focus left / down / up / right |
| super + tab | focus the previous window |
| super + shift + h / j / k / l | swap the window left / down / up / right |
| super + arrows | resize by 60 px |
| super + 1 ... 9 | switch to Space N |
| super + shift + 1 ... 9 | send the window to Space N and follow |
| super + shift + s | send the window to the other display |
| super + f | zoom: fill the display |
| super + t | float / tile |
| super + r | rotate the layout 90 degrees |
| super + shift + b | balance all tiles |
| super + s | stacked / tiled for this Space |
| super + m | minimize |
| super + w | close the window |
| super + o | open your home folder in Finder |
| super + shift + ctrl + space | theme picker |
| super + shift + ctrl + b | background picker |
| super + shift + 0 | System Monitor |
| super + shift + ctrl + a | open your coding agent |

The full table is in [tiler/README.md](../tiler/README.md#keys-left-option--super).
Mouse: Option-drag moves a window, Option-right-drag resizes it, and
dropping a window onto a tile swaps them.

Avoid super + shift + r unless you must: it restarts yabai, which rebuilds the
layout of every window ([FAQ](FAQ.md#the-layout-got-messed-up)).

## The commands you will use most

```sh
gallery theme list                 # installed themes
gallery theme set tokyo-night      # switch theme (also: gallery theme next)
gallery bg next                    # next wallpaper of the current theme
gallery terminal set ghostty       # which terminal the Gallery opens (iterm2, ghostty, kitty, wezterm)
gallery console native             # your terminals back to their own colours (theme: follow it again)
gallery font set "MesloLGS NFM" 14 # one monospace font for everything (gallery font list shows candidates)
gallery glass set 0.2 12           # terminal transparency 0-0.9 and blur 0-64
gallery borders width 8            # focus outline width, 1 to 12
gallery home save                  # remember which Space each app lives on
```

Arrange your apps across Spaces first, then `gallery home save`: it writes
rules so the apps return to those Spaces after a login. Nothing saves it
automatically. Details for each are in [CUSTOMIZING.md](CUSTOMIZING.md).

## Set up your coding agent

`super + shift + ctrl + a` opens a coding agent in a new tiled terminal window.
Choose the agent and where it starts, once.

1. **Pick the agent.** See what is installed, then choose:

   ```sh
   gallery agent list                  # built-ins and whether each is on your PATH
   gallery agent set claude            # or gemini, opencode, codex, copilot, crush
   gallery agent set aider --command "aider --yes"   # any other CLI, run as typed
   ```

2. **Set the start directory** to the folder that holds your repositories:

   ```sh
   gallery agent dir ~/Code
   ```

   One folder for all repositories means the agent asks you to trust the
   folder once, instead of once per project. Tell the agent which repository to
   work in, or start it from a shell and `cd` first. If the directory cannot be reached (an external
   volume that is not mounted, say), the agent starts in `$HOME` and prints a
   warning. `gallery agent dir --clear` goes back to `$HOME`.

3. **Check it:**

   ```sh
   gallery agent status                # agent, start directory, command
   ```

4. **Press super + shift + ctrl + a.** Each press opens another window;
   quit the agent to close it.

5. **More than one agent?** The default is the one the key starts. Start any
   other by name, once, without changing the default:

   ```sh
   gallery agent open gemini                         # a built-in
   gallery agent add aider --command "aider --yes"   # register a custom one
   gallery agent open aider
   ```

   `gallery agent set <name>` changes the default, and a second agent can have
   a key of its own. See [More than one agent](CUSTOMIZING.md#more-than-one-agent).

**Security.** The built-in commands start each agent in its "do not ask"
mode, so it runs unattended with the full file and shell access of your
account, in the start directory. Choose that directory with this in mind and
do not point it at `$HOME` if you can avoid it. More in
[AI agents](CUSTOMIZING.md#ai-agents).

## Next steps

- [CUSTOMIZING.md](CUSTOMIZING.md): your own keys, tiling settings, themes,
  wallpapers, fonts, plugins; what an update overwrites and what it keeps.
- [FAQ.md](FAQ.md): keys that do nothing, Spaces that will not switch,
  characters you cannot type, windows that will not tile.
- [tiler/README.md](../tiler/README.md): the full key table.
