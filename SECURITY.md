# Security

## Reporting a vulnerability

Please report security problems privately, not in a public issue: on GitHub,
open the repository's **Security** tab and choose **Report a vulnerability**.
Only the maintainer sees the report. You can expect a first answer within a
week.

Include what you found, the steps to reproduce it, and the macOS version and
Gallery commit you saw it on.

## What counts

The Gallery runs with more access than most desktop tools, so these are the
places a problem matters most:

- **Accessibility and Automation grants.** yabai, skhd and Hammerspoon hold
  Accessibility; the Gallery's scripts drive your terminal over AppleScript. A
  way to make them run something you did not ask for is a vulnerability.
- **Plugins.** `gallery add <git-url>` installs code from another repository
  and runs it. A way for a plugin to escape what its manifest declares, or to
  run before you enable it, is in scope; a plugin that does harm once you have
  installed and enabled it is the plugin's problem, not the Gallery's.
- **Your files.** The installer edits a few of your config files and backs
  them up first; uninstalling puts them back. Anything that loses or exposes
  a file of yours is in scope.
- **Secrets.** The weather key lives in `~/.config/gallery/weather.key`. A way
  for it to leak (into logs, the process list, a public file) is in scope.

The coding agents start in their "do not ask" mode by design (see the
security note in [Getting started](docs/GETTING-STARTED.md#set-up-your-coding-agent));
that choice is documented, not a vulnerability.

## Supported versions

Only the current `main` branch. Fixes are made there; there are no release
branches.
