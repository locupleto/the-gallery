# Changelog

What changed in each release of The Gallery. Versions follow
[Semantic Versioning](https://semver.org); while the version starts with 0,
a minor release (0.2, 0.3) may change how things work, and its notes say how
to carry your setup across. `gallery version` prints the version you have.

## 0.6.2 (2026-10-30)

- The tree guard no longer gives up on a Desktop because a rebuild ran
  while the screen locked (nothing can be resized then); it tries again at
  the next change.

## 0.6.1 (2026-10-30)

- Fixed: removing a Desktop in Mission Control could leave the Desktop you
  were on with a broken tiling: a window shrunk into a corner and others
  overlapping it. The tree guard, which rebuilds such a Desktop, saw the
  gap but took the windows still moving for a recovery and left it. It now
  measures again until the Desktop has settled, then rebuilds it.

## 0.6.0 (2026-10-30)

- Desktops are now remembered by monitor. Each save notes every Desktop's
  monitor by its permanent id and its place on that monitor, and after a
  login windows, terminals and tile shapes go back there whatever the
  Desktop's number is now. Before, adding or removing a Desktop on the main
  display, or making another display the main one, sent windows to the
  wrong Desktops. The home rules in `rules.local` load only while the
  numbers are unchanged; run `gallery home save` once (or let the automatic
  save do it) so the saved files carry the monitors.

## 0.5.2 (2026-10-30)

- Fixed: a web app added to the Dock from Safari was often saved as "Web
  App", the name yabai gives the generic process it runs in, so it could not
  be put back or started again. The Gallery now uses the name macOS gives
  the app (Outlook), when saving, reopening and placing windows.

## 0.5.1 (2026-10-30)

- Fixed: a web app added to the Dock from Safari (Outlook, say) came back
  after login without a window. The save recorded Safari's generic Web
  App.app for it; it now records the app's own bundle in ~/Applications.
- The look at iTerm2's windows during a save gives up after 10 seconds, so
  macOS's one-time question whether Hammerspoon may control iTerm2 cannot
  hold up a save before sleep.

## 0.5.0 (2026-10-30)

- Terminals come back with what ran in them. `home save` notes for each
  iTerm2 window whether a Claude Code agent runs in it (and which session)
  or a shell (and its folder), in `~/.config/yabai/home-terminals.json`.
  With `gallery home reopen on`, the login opens one window per saved
  terminal on its saved Desktop instead of iTerm2's empty restored windows:
  agents resumed with `claude --resume` (idle, the conversation intact),
  shells in their folder. `gallery home reopen` lists them. The automatic
  save now also saves when an agent starts or ends.

## 0.4.1 (2026-10-30)

- Fixed: `gallery home reopen` could not start an app whose name differs
  from its file (iTerm2 is iTerm.app) before a save had recorded where it
  is. It now asks Launch Services for the app.

## 0.4.0 (2026-10-30)

- The Gallery can reopen your apps after a login instead of macOS:
  `gallery home reopen on` (per Mac, off by default). macOS starts every app
  at once while yabai is still starting, which is how windows ended up on
  Desktop 1; the Gallery waits for yabai and an unlocked screen, then starts
  the apps of the last save one at a time and puts each window on its
  Desktop. It needs "Close windows when quitting an application" off in
  System Settings > Desktop & Dock so the apps restore their windows;
  `gallery home reopen` shows both macOS settings and the apps it would
  start. `home save` now also writes `~/.config/yabai/home-apps.json`.

## 0.3.2 (2026-10-30)

- Homes now exist only while the Mac logs in. Once the after-login pass has
  put your windows back, the home rules and signals are taken out of yabai
  and `rules.local` loads nothing until the next login, so no window is ever
  moved to another Desktop during the day: not a dialog or floating window
  of a pinned app, and not a Safari window whose title changed to one with
  a home (both still could in 0.3.1). Run `gallery home save` once to
  rewrite `rules.local` in the new form (the automatic save does it too).
- `gallery home apply` moves every window back to its saved Desktop as a
  one-off, then unloads the homes again.

## 0.3.1 (2026-10-30)

- Fixed: starting an app (Outlook from the Dock, say) threw you to its home
  Desktop. Homes now only place windows while the Mac logs in; once the
  after-login pass has put your windows back, every new window opens on the
  Desktop you are on, an app's first window too.

## 0.3.0 (2026-10-30)

- Your desktop is saved automatically, on every Mac: every half hour and
  just before the Mac sleeps, shuts down, restarts or logs out, so the next
  login finds the windows where you left them. Before, a Desktop layout was
  only as fresh as your last `gallery home save`. Guards keep a scattered,
  half-closed or unchanged desktop from being saved; each day's last save
  is kept for 14 days in `~/.config/yabai/home-history/`. If you set up a
  scheduled `gallery home save` of your own, remove it.
- After a login every window goes back to the Desktop it was on, terminals
  and Finder included (they have no home rule, so they all opened on the
  first Desktop). Windows of one app are matched by title, else in opening
  order.
- Finder roams like the terminals and gets no home rule: a folder opened on
  one Desktop no longer throws you to Finder's home Desktop.
- `gallery home save` now says when it could not save the tile shapes,
  instead of failing silently.

## 0.2.0 (2026-10-28)

- Two new themes from Omarchy: starship and jade-horse, with their
  wallpapers. Every existing theme stays, osaka-jade too (upstream replaced
  it with jade-horse). Run `./install.sh` to get them; it fetches the new
  wallpapers.
- Fixed: an update stopped halfway when a folder the Gallery keeps in step
  with its own copy (the agent skill, a plugin, the Spoon) held a link to a
  folder: making the backup copy followed the link and failed. Such a link
  is now backed up as a link, like any other stray file, and the update
  runs to the end. A plain `ln -s` of the skill onto its existing link
  leaves exactly such a link inside the skill folder.
- super + shift + f opens Finder at the home folder: Omarchy's file-manager
  key. The super + o keys (home, Downloads, Desktop) stay.
- Fixed: an app key pressed on an empty Desktop did nothing when the app was
  already open on another one. The app keys now go through
  `~/.config/skhd/app-focus`, which takes you to the app's window (on any
  Desktop or display, minimized or hidden), or starts the app and follows
  its first window. To carry it across, change your own `open -a X` keys in
  `local.skhd` to `"$HOME/.config/skhd/app-focus" X`.
- Fixed: a new browser window (super + b, Cmd-N) on an empty Desktop was
  thrown onto the browser's home Desktop. A home rule now settles only an
  app's first window; a later one stays where you opened it. Run
  `gallery home save` once to install the signal that does this.
- `gallery home save --keep-absent` keeps the home of an app that has no
  window open right now; only plain rules are kept, never title rules.
- The docs said the browser roams by default; only terminals do.
- The agent skill now covers questions as well as changes: it tells the
  agent to answer "which key does what" from the live key list
  (`~/.config/skhd/Tiler-Keys.md`), and the README says so.
- Fixed: the windows on a second display could be re-tiled in a new order
  when windows opened or closed elsewhere. The tiler's gap repair had
  remembered that display as larger than it is, after a window once hung
  over its edge; the remembered area is now kept within the display.

## 0.1.0 (2026-10-04)

The first public release.

- **Tiling.** New windows tile themselves (yabai), with left Option as super
  and Omarchy's key bindings (skhd). The focused window wears an outline in
  the theme's accent colour (JankyBorders, or Hammerspoon before macOS 14).
  super + space opens Learn, a set of cheat sheets that includes one built
  from the live key bindings.
- **Themes.** 22 of Omarchy's themes, applied at once to the terminal
  (iTerm2, Ghostty, kitty or WezTerm), the focus outline, the wallpaper,
  btop, superfile and the font. Each terminal's own settings are backed up
  and come back on `gallery console native`, `gallery off` or uninstall.
- **Coding agents.** shift + ctrl + super + a opens your agent (Claude Code,
  Codex, Gemini CLI, Copilot CLI, opencode, crush or any other CLI) in a new
  tile, started in `~/Work` or a folder you choose with `gallery agent dir`.
  An agent skill, linked into `~/.agents/skills` and `~/.claude/skills`,
  tells the agent how to change the Gallery safely.
- **Desktop homes.** `gallery home save` records which Desktop each app
  lives on and each Desktop's tile shape. After a login the Gallery puts
  both back at the first quiet moment and re-syncs the wallpaper on every
  Desktop.
- **Plugins.** A plugin host modelled on Omarchy 4's runs floating terminal
  tools, background services and unmodified Omarchy QML plugins (such as
  Radio Atlas). `gallery add` installs a plugin from git.
- **Try it and leave.** `gallery off` puts the windows back where they were
  and stops the tiling until `gallery on`. `./install.sh --uninstall`
  restores every file the installer replaced or edited.
