# FAQ

Short answers, with links to the full ones. "super" is the left Option key.

## Keys

### Can I switch it off for a while?

Yes: shift + ctrl + super + escape, or `gallery off`, gives you plain macOS
(no tiling, no outline, left Option types again), and the same key or
`gallery on` brings it back. Off puts the windows that were open when you
switched it on back where they were; windows opened since stay where they
are. Off lasts through a restart until you switch it on, and on tiles every
window again, starting from even splits. See
[Switching it off for a while](GETTING-STARTED.md#switching-it-off-for-a-while).

### Nothing happens when I press a key

Work down this list:

1. Run `gallery doctor` and look at the skhd lines. skhd must be running.
2. skhd and yabai need the Accessibility grant: System Settings, Privacy &
   Security, Accessibility. After ticking them restart both:
   `yabai --restart-service; skhd --restart-service`
   ([INSTALL.md](INSTALL.md#first-run-permissions)).
3. Turn Secure Keyboard Entry off in your terminal (it is in the iTerm2,
   Ghostty and kitty menus). While it is on, skhd cannot see keys typed in
   that terminal.
4. Run `skhd --observe` and press the key. If nothing prints, skhd does not
   get the key. If a keycode prints, your layout may be the cause: see
   [Keyboard layouts](CUSTOMIZING.md#keyboard-layouts).
5. A key that opens a window raises a macOS Automation prompt the first time
   ("skhd wants to control iTerm2"). If you dismissed it, enable it under
   Privacy & Security, Automation.

Also see [Troubleshooting](INSTALL.md#troubleshooting).

### super + 1 does not switch Spaces

Space switching sends Mission Control's Ctrl+N shortcut, so "Switch to
Desktop N" must be enabled for each desktop (System Settings, Keyboard,
Keyboard Shortcuts, Mission Control), and the desktop must exist. If it still
fails and your layout is French or Belgian AZERTY, the digit row types
symbols and the bindings cannot resolve; use the hex keycode fix in
[Keyboard layouts](CUSTOMIZING.md#keyboard-layouts).

### I cannot type @ { } [ ] |

Many layouts type those with Option. The Gallery uses the left Option, so
use the **right** Option for characters; it is never bound. See
[Typing characters on Option](CUSTOMIZING.md#typing-characters-on-option).

### How do I see all the keys?

super + space opens the Learn menu and super + shift + space the generated
key sheet. The full table is in
[tiler/README.md](../tiler/README.md#keys-left-option--super). See
[Getting started](GETTING-STARTED.md#the-two-help-keys).

### How do I change, add or disable a key?

Edit `~/.config/skhd/local.skhd`. It loads before the shipped files and the
first definition of a key wins, so a line there replaces the shipped one.
There is no unbind: to disable a key, bind it to `true`
(`lalt + ctrl - 0 : true`). Do not edit `tiler.skhd` or `gallery.skhd`; an
update overwrites them. See
[Your own keys](CUSTOMIZING.md#your-own-keys-localskhd).

## Windows and layout

### A window does not tile, or floats

Some windows are floated on purpose: System Settings, Calculator, Activity
Monitor and other utilities, Finder's copy and info dialogs, and anything that
is not a standard window (dialogs, sheets, popovers). Float or tile a window
yourself with super + t. To keep an app out of tiling for good, add a rule to
`~/.config/yabai/yabairc.local`:

```sh
yabai -m rule --add label=never-tile-spotify app="^Spotify$" manage=off
yabai -m rule --apply
```

See [Tiling](CUSTOMIZING.md#settings-yabairclocal). A few apps refuse to
resize to their tile: a window with a minimum size larger than its tile
overlaps its neighbour (Finder windows do not get narrower than about 480
points, which shows with five windows on a laptop screen), and one that
cannot grow leaves a gap. That is the app, not the tiler; fewer windows on
the Space, or super + t to float one, gives it room.

If no window tiles at all, `gallery doctor` may print "yabai is blind". It
means yabai has no Accessibility access: dismiss any pending prompt and
restart the service as the message says. Windows created while the screen is
locked are invisible to yabai; `gallery ghosts` lists them and
`gallery ghosts fix` relaunches their app
([Troubleshooting](INSTALL.md#troubleshooting)).

### The layout got messed up

First try the gentle repairs. super + shift + b balances all tiles. A stripe
of empty desktop that tiles will not grow into is a stale node in the tree;
ctrl + super + r rebuilds the current Space (it resets that Space's split
ratios), and the Gallery also does it automatically when it detects one
([Tree repair](../tiler/README.md#tree-repair-automatic)).

super + shift + r restarts yabai and reloads skhd. Use it as a last resort:
a yabai restart rebuilds every window tree and loses your hand-tuned split
ratios on every display. To apply a setting change without a restart, see
[Apply a change without restarting yabai](CUSTOMIZING.md#settings-yabairclocal).

### After a restart my apps are on the wrong Desktops

The Gallery puts an app back on its Desktop only if you saved one for it.
Arrange your apps the way you want them, then:

```sh
gallery home save      # remember which Desktop each app lives on
gallery home show      # check: the map, and the saved rules
```

Save again whenever you rearrange; nothing is saved automatically. Terminals
and the browser roam by default (`gallery home save --roam A,B` sets your
own list). A rule saved for one window by its title, as for a browser window
on a Desktop of its own, stops matching when the title changes; save again.

After a login macOS reopens your apps while the tiler is still starting, so
some windows can miss their rule. The Gallery applies the rules once more by
itself at the first quiet moment after you log in (nothing opening or moving,
and you not typing or using the mouse), and `gallery home apply` does it by
hand any time. `~/.config/gallery/gallery-home.log` shows when it ran.

### How do I use more than one display?

super + h / j / k / l continues onto the neighbouring display when there is
nothing further in that direction, and super + shift + h / j / k / l moves the
window across at the edge. super + shift + s sends the window to the other
display and follows it. New windows open on the display under the mouse
pointer, and hovering a window focuses it. Spaces are numbered in one sequence
across all displays. yabai needs "Displays have separate Spaces" on in System
Settings, Desktop & Dock ([INSTALL.md](INSTALL.md#prerequisites)).

### Does it need SIP disabled?

No. The Gallery does not install yabai's scripting addition, so System
Integrity Protection stays on. That is why Spaces are switched with Mission
Control's shortcuts ([tiler/README.md](../tiler/README.md#install)).

## Look

### Can I use Ghostty, kitty or WezTerm instead of iTerm2?

Yes: `gallery terminal list`, then `gallery terminal set ghostty` (or
`kitty`, `wezterm`). Floating windows, Learn, super + return and the agent
use it, and all four take the theme. Your everyday terminals follow it too,
every installed one; `gallery console native` gives them back their own
colours ([Terminals](CUSTOMIZING.md#terminals)).

### super + w asks before closing a terminal window

That is the terminal's own prompt for a window running something other than
the shell. Omarchy switches it off; the Gallery keeps it for your everyday
windows unless you choose otherwise: `gallery console close never` (it needs
`gallery console theme`). The Gallery's own floating windows never ask
([Closing windows without asking](CUSTOMIZING.md#closing-windows-without-asking)).

### The terminal is too transparent, or not transparent enough

`gallery glass` shows the setting. `gallery glass set 0` makes it solid,
`gallery glass set 0.3 12` sets transparency (0 to 0.9) and blur (0 to 64),
and `gallery glass default` restores 0.12 / 9
([Fonts and glass](CUSTOMIZING.md#fonts-and-glass)).

### How do I add my own theme or wallpaper?

A theme is a folder with a `colors.toml` in `~/.config/gallery/themes/`, and
wallpapers are images in that theme's `backgrounds/` folder. Copy a shipped
theme to a new name rather than editing it in place, since updates overwrite
shipped themes ([Themes](CUSTOMIZING.md#themes),
[Wallpapers](CUSTOMIZING.md#wallpapers)).

## Coding agent

### Which folder does my coding agent start in, and how do I change it?

`~/Work`, as on Omarchy. The first time the agent starts, the Gallery creates
`~/Work` if it is not there. If you already have a `~/Work`, it is used as it
is: nothing in it is changed, and uninstalling never removes it. (Uninstalling
removes `~/Work` only when the Gallery created it and it is still empty.)

To start it somewhere else, say the folder that holds your git repositories,
record that folder once per Mac:

```sh
gallery agent dir ~/Developer/git     # any folder; it must exist
gallery agent status                  # "starts:" shows the folder in use
gallery agent dir --clear             # back to ~/Work
```

The next agent you open starts there; agents already open stay where they
are. A folder on an external disk is fine: if it is not mounted when the agent
starts, the agent starts in `~/Work` and prints a warning instead of failing.
`GALLERY_AGENT_DIR`, if set in the environment skhd runs under, overrides the
recorded folder.

**Why not the home folder?** Agents such as Claude Code ask whether you trust
the folder they start in, and they never remember the answer for your home
folder, so they would ask on every start. One folder means one answer that
sticks, and it covers every repository inside it. It also limits where an
agent works: the Gallery starts agents in their "do not ask" mode (see
[Getting started](GETTING-STARTED.md#set-up-your-coding-agent)), so they act
without stopping in whatever folder they start in.

### My agent asks for permissions, or I want a different one

The start directory is `gallery agent dir <path>` (see above). Pick the agent with
`gallery agent set <name>`, or `gallery agent set <name> --command "..."` for
any other CLI. To keep one default and use others now and then, start them
by name with `gallery agent open <name>` (custom ones are registered first
with `gallery agent add`; see
[More than one agent](CUSTOMIZING.md#more-than-one-agent)). The built-in
commands already start the agent in its
"do not ask" mode, so it will not stop to ask; read the security note in
[Getting started](GETTING-STARTED.md#set-up-your-coding-agent) and
[AI agents](CUSTOMIZING.md#ai-agents). `gallery agent status` shows what is set.

## Installing

### Do I need Hammerspoon, Obsidian or Übersicht?

Hammerspoon: the installer requires it, because it hosts the plugins, and
`gallery status`, `list`, `enable` and `validate` talk to it. The tiling keys
run on yabai and skhd alone (`tiler/install.sh` gives a tiling-only setup).
Obsidian: no. Learn reads plain markdown files from
`~/.config/gallery/sheets`. Übersicht: no; only the optional
`gallery widgets` commands use it, and they do nothing without the widget set
([INSTALL.md](INSTALL.md#optional-extras)).

### Does it run on an Intel Mac, or an older macOS?

Yes. On an Intel Mac with a current macOS nothing is different. macOS 12
Monterey and 13 Ventura work too, with older Hammerspoon and iTerm2 builds,
kitty as the best terminal, a focus outline drawn by Hammerspoon instead of
JankyBorders before macOS 14, and
`./install.sh --minimal` to avoid hours of compiling. The details are under
"Older Macs" in [INSTALL.md](INSTALL.md#prerequisites).

### How do I update?

```sh
cd the-gallery
git pull
./install.sh
```

yabai and skhd are restarted only if their configuration actually changed
([Updating](INSTALL.md#updating)).

### Will an update overwrite my changes?

Not the places meant for you: `local.skhd`, `yabairc.local`, `rules.local`,
your themes, plugins, hooks and sheets, and your saved settings. Files named
after the Gallery are overwritten; an edited copy is saved as
`<name>.gallery-edited.<timestamp>` first. The table is in
[What is yours](CUSTOMIZING.md#what-is-yours-and-what-an-update-overwrites).

### How do I uninstall completely?

```sh
./install.sh --uninstall --dry-run   # preview
./install.sh --uninstall             # keeps ~/.config/gallery
./install.sh --uninstall --purge     # also deletes ~/.config/gallery
```

It stops yabai and skhd, removes what it installed, puts back the files and
wallpaper settings it replaced, and leaves the Homebrew formulae.
[INSTALL.md](INSTALL.md#uninstalling) lists everything.
