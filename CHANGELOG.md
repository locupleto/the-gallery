# Changelog

What changed in each release of The Gallery. Versions follow
[Semantic Versioning](https://semver.org); while the version starts with 0,
a minor release (0.2, 0.3) may change how things work, and its notes say how
to carry your setup across. `gallery version` prints the version you have.

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
