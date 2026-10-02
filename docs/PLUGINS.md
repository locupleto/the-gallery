# Writing plugins

A plugin is a directory containing a `manifest.json`. The Spoon
(`Gallery.spoon/`) scans `~/.config/gallery/plugins/<id>/` at start and on
`gallery` rescans, validates every manifest, and hosts the plugin according to
the kinds the manifest declares. The bundled plugins under `plugins/` are
working examples of every kind; each is a few lines of manifest.

```sh
gallery validate <dir>               # check a manifest without installing it
gallery add <git-url> [--enable]     # clone a plugin into ~/.config/gallery/plugins
gallery list [--json]                # id, version, kinds, enabled|disabled|errored
```

During development, put the directory under `~/.config/gallery/plugins/`, run
`gallery validate` on it, then `gallery enable <id>` and `gallery open <id>`.
Changes to a manifest need a rescan; see [Spoon IPC](#spoon-ipc).

Plugins are not sandboxed; see [Security](#security).

## Manifest

```json
{
  "schemaVersion": 1,
  "id": "example.hello",
  "name": "Hello",
  "version": "0.0.1",
  "kinds": ["panel"],
  "entryPoints": { "panel": "index.html" },
  "gallery": { "panel": { "width": 560, "height": 320 } }
}
```

Top-level fields, checked by `Gallery.spoon/lib/manifest.lua`:

| Field | Rule |
|---|---|
| `schemaVersion` | must be `1` (error otherwise) |
| `id` | non-empty string matching `^[a-z0-9][a-z0-9.-]*$` (error otherwise). The `gallery.` prefix is for first-party plugins; an id with it, installed under `~/.config/gallery/plugins`, validates with a warning. The `omarchy.` prefix is reserved upstream and warns. |
| `name` | non-empty string. Also the window title: tui, menu and qml windows are titled `Gallery: <name>`. |
| `version` | non-empty string |
| `kinds` | non-empty array of strings: `tui`, `panel`, `overlay`, `menu`, `service`, `bar-widget`, `bar`. An unknown kind (including `qml`) is a warning. |
| `entryPoints` | object, kind to file path. Each path is relative, contains no `..`, and must exist as a file (errors otherwise). A kind with no entry point, or an entry point for an undeclared kind, is a warning only. `tui`, `menu`, `service` and `bar-widget` do not use one, so leave `entryPoints` as `{}` and accept the warning (`barWidget` is accepted as an alias key for `bar-widget`). |
| `gallery` | object of Gallery-specific settings, below. Unknown keys are ignored. |

A `tui` kind additionally requires `gallery.tui.command` (error). Any other
top-level field (Omarchy's `description`, an `imported` block, ...) is
ignored. A plugin whose manifest has errors is listed as `errored` and the
Spoon refuses to open it.

`gallery.<kind>` settings:

| Key | Fields |
|---|---|
| `gallery.primaryKind` | which interactive kind `open` means when several are declared: `tui`, `panel`, `overlay` or `menu` |
| `gallery.tui` | `command` (required; path, or a name looked up on `PATH`), `args` (array), `grid` (yabai `--grid` spec `R:C:X:Y:W:H`, default `6:6:1:1:4:4`) |
| `gallery.panel` | `width` (640), `height` (400), `transparent` (false), `style` (array of `hs.webview.windowMasks` names, default `["borderless","utility"]`), `focus` (`activate` default, `window`, `none`), `restoreFocus` (true; only `false` disables), `cascade` (32; pixel offset per already-open panel, `0` disables) |
| `gallery.overlay` | `display` (`cursor` default, or `main`), `dismiss` (`any-key` default, or `escape`), `focus` (default none; `activate` takes focus) |
| `gallery.menu` | `source`, `placeholder`, `width` (40), `rows` (10); see [menu](#menu) |
| `gallery.service` | `command`, `args`, `interval` (seconds, default 60, minimum 5), `restartOnFailure` |
| `gallery.widget` | `command`, `args`, `interval` (seconds, default 10, minimum 1) |

## Which kind `open` runs

`gallery open|close|toggle <id> [kind]` picks the kind in this order:

1. the explicit `kind` argument;
2. `gallery.primaryKind`, if it names a declared interactive kind;
3. the first declared of `tui`, `panel`, `overlay`, `menu`.

Whenever that yields `panel` or `overlay` and the matching `entryPoints` value
ends in `.qml`, the plugin runs as the derived kind `qml` instead. `qml` is
never declared in `kinds`; `gallery list` shows a `.qml`-backed panel or
overlay as `qml`. `service`, `bar-widget` and `bar` are not interactive: they
run once the plugin is enabled and cannot be opened.

Two code paths implement this, and they differ slightly:

- `bin/gallery` handles `tui`, `menu` and `qml` itself, with no Hammerspoon
  involved (`route_open_close_toggle` in `bin/gallery`). It refuses only a
  plugin listed in `disabled` in `gallery.json`.
- `panel` and `overlay` go to the Spoon over IPC. The Spoon also refuses an
  errored plugin and any plugin that is not enabled, and checks that an
  explicit `kind` is one the manifest declares.

`open` on an already open tui or qml window focuses it; `toggle` closes it if
open; `close` on a closed plugin prints `not open: <id>`.

## tui

A floating, centred terminal. Implemented by `bin/gallery-tui` with the
configured terminal (iTerm2, Ghostty, kitty or WezTerm; `bin/gallery-term`
opens the window) and yabai; the Spoon is not involved, so a `tui` plugin works with Hammerspoon
stopped.

- On iTerm2 the window uses the dynamic profile named in
  `~/Library/Application Support/iTerm2/DynamicProfiles/gallery-theme.json`
  ("Gallery"); on the other terminals it gets the Gallery theme as described
  in [THEMES.md](THEMES.md#ghostty-kitty-and-wezterm). It is titled
  `Gallery: <name>`. A yabai rule (`label=gallery-tui`)
  matches that title prefix on windows of the configured terminal, makes them unmanaged (floating)
  and places them on the `grid`. The window opens on the display that had
  focus.
- `command` and every `args` entry have a leading `~` and any literal `$HOME`
  expanded. `PATH` has `/opt/homebrew/bin` and `/usr/local/bin` prepended. A
  command containing `/` must be executable; otherwise it is looked up on
  `PATH`. Failing both prints `gallery-tui: command not found or not
  executable: ...` and holds the window for 3 seconds.
- The command runs in the foreground with the window's tty, replaces the
  launching shell, and should exit on its own key. The session closes when
  the command exits (`Close Sessions On End`), without a prompt.
- The window is started by the terminal directly, not by an interactive shell, so
  `~/.zshrc` is not read. A plugin that needs a secret reads it from a file,
  for example under `~/.config/gallery/` (the weather plugin reads
  `~/.config/gallery/weather.key`).
- To colour the window's contents like the theme, source
  `~/.config/gallery/state/theme.sh` (see [THEMES.md](THEMES.md#statethemesh)).

## menu

A list of items, each with an action. `gallery open` runs the menu as an fzf
list in a `tui`-style window (`bin/gallery-menu`, which needs `fzf`);
`Enter` runs the item, `Esc` closes. `source` is one of:

```json
{ "type": "static", "items": [ ... ] }
{ "type": "command", "command": "~/path/to/script", "args": [] }
```

A `command` source prints one JSON object per line (lines that are not JSON
are skipped). In the fzf runner the command is stopped after 30 seconds.

An item has `text`, an optional `subText`, and an `action`:

| `action.type` | Fields | Effect |
|---|---|---|
| `exec` | `command`, `args` | start the program, detached, no shell |
| `open` | `url` | open the URL with the default handler |
| `ipc` | `verb`, `id` | in the fzf runner, run `gallery <verb> [id]`; in the Spoon's chooser, call the Spoon IPC verb (below) |

`~/` in `command`, `args` and a source `command` is expanded. `placeholder`,
`width` and `rows` apply only to the Spoon's `hs.chooser` implementation
(`Gallery.spoon/lib/menu.lua`), which is used when the Spoon's `open` verb is
called for a menu directly. `plugins/gallery.menu-demo` shows all three
actions.

## panel

A web page in a Hammerspoon `hs.webview`, loaded from `file://` (so relative
paths to scripts, styles and images inside the plugin directory work).

- Centred on the screen under the pointer, `width` by `height` points, at
  the floating window level, with text entry enabled. Each panel already open
  shifts a new one down and right by `cascade` points. `transparent: true`
  makes the webview background transparent.
- Focus: `activate` activates Hammerspoon and focuses the window, `window`
  focuses the window only, `none` leaves focus alone. On close, focus returns
  to the window that was frontmost at open unless `restoreFocus` is `false`.
- Colours: use the CSS variables and the JS object below so the page follows
  the theme.

## overlay

Like a panel, but covering the whole frame of one display (`display`:
`cursor` for the display under the pointer, or `main`), above panels, with a
transparent, borderless webview. It is dismissed by a key: any key by
default, or only Escape with `dismiss: "escape"`. It does not take focus
unless `focus` is `"activate"`; the dismiss key is caught by an event tap, not
by the page. The same `window.gallery` bridge is injected. See
`plugins/gallery.overlay-demo`.

## service

A background command run by the Spoon on a timer, with no window. Runs when
the plugin is enabled and error-free; started at Spoon start, and
rescheduled by `enable`, `disable` and `rescan`.

- `command` (a leading `~/` is expanded) and `args` run every `interval`
  seconds (default 60, values below 5 become 5), and once immediately.
- The run is synchronous inside Hammerspoon: keep it short.
- After each run `~/.config/gallery/state/services/<id>.json` is rewritten
  with `{"lastRun": <epoch>, "code": <exit code>, "restarts": <count>}`.
- With `restartOnFailure: true`, a non-zero exit is retried after 5 seconds, up
  to 3 times, and then logged as failed; the retry count resets after a run
  that exits 0.
- The `services` IPC verb lists running services with interval, last run (UTC),
  last exit code and restarts. `plugins/gallery.service-demo` and
  `plugins/gallery.ghosts` are examples.

## bar-widget

A feed for something else to read, such as a status bar or a widget host.
`gallery.widget.command` (no `~` expansion; use an absolute path) runs every
`interval` seconds (default 10, minimum 1) and once at start. Its stdout is
parsed as JSON; a JSON object is written as is, anything else is wrapped as
`{"text": "<trimmed stdout>"}`. Either way an `updatedAt` epoch field is
added and the result is written atomically to
`~/.config/gallery/feed/<id>.json`. The `feed` IPC verb prints the last
feed. A `bar-widget` with no `gallery.widget.command` (an Omarchy bar widget
written in QML, for instance) logs one warning and produces no feed. The
`bar` kind is accepted by validation and has no runtime.

## qml

Unmodified Omarchy plugins. A `panel` or `overlay` whose entry point is a
`.qml` file runs in `qml/host.py`, a PySide6 host with a shim for the
Quickshell modules and Omarchy's `qs.Commons` and `qs.Ui` vendored under
`qml/vendor/`. `qml/README.md` documents the shim in detail.

```sh
gallery add <git-url> --enable
gallery open <id>
```

No manifest changes are needed. Facts that matter when a plugin does not
behave:

- Supported: `Process`, `FileView`, `StdioCollector`, `SplitParser`,
  `FloatingWindow`/`PanelWindow`/`PopupWindow`, `ShellRoot`, `Scope`,
  `LazyLoader`, `Variants`, and the vendored `qs.Commons` and `qs.Ui`.
  `DataStream`, `SocketServer` and `Socket` are not implemented, and neither
  are `IpcHandler`, `QsWindow` or the `WlrLayer`/`WlrKeyboardFocus`/
  `ExclusionMode` enums; a plugin that reaches them fails to load.
- Accepted and ignored: Hyprland IPC (`dispatch` is a no-op, monitors and
  workspaces are empty), layer-shell attached properties, `iconPath` (always
  empty).
- Only the `panel`/`overlay` entry point is run. `bar` and `bar-widget` QML
  entry points are not.
- The host sets `QT_QUICK_CONTROLS_STYLE=Basic` unless it is already set, and
  `OMARCHY_PATH` to `~/.config/gallery` unless it is already set. `monospace`,
  `Monospace` and `mono` are mapped to `$GALLERY_FONT` if that names an
  installed family, else to the `gallery font set` family, else to the first
  installed Nerd Font from a built-in list.
- Colours come from the theme's `colors.toml` through the
  `~/.config/omarchy/current/theme` and `~/.local/state/omarchy/current/theme`
  links the installer creates, not from `state/theme.*`.
- A window is titled `Gallery: <name>`; a yabai rule (`label=gallery-qml`)
  floats it. Escape (when the plugin does not use it) and Cmd+W close it. The
  host also exits when its last window is hidden. Its pid is in
  `~/.config/gallery/state/qml/<title-slug>.pid`; stderr goes to
  `~/Library/Logs/gallery-qml.log`.
- `gallery.panel.width` and `height` are not applied; the plugin sizes its own
  window.
- The first run builds the venv; see `gallery-qml --setup` in
  [INSTALL.md](INSTALL.md#optional-extras).

### macOS patches

An Omarchy plugin sometimes ships a helper script that only works on Linux
(`hyprctl`, `pactl`, `systemctl`, ...). Put a replacement at
`patches/<plugin-id>/<path relative to the plugin root>` in this repository.
`install.sh` copies `patches/` to `~/.config/gallery/patches/`; `gallery add`
and `gallery update` lay each file over the installed plugin (permissions
preserved), and `gallery patch <id>` re-applies them by hand. It is a plain
file overlay, not a diff format. See `patches/README.md` and the worked example
`patches/akshar.radio-atlas/`.

## window.gallery

Injected at document start into every panel and overlay page (an overlay
falls back to just `close` and `log` if the full bridge cannot be built).

```js
window.gallery = {
  version,                          // Gallery.spoon version string
  theme,                            // object of theme tokens, see below
  close(),                          // close this plugin's window
  log(message),                     // append to ~/Library/Logs/gallery.log
  exec(cmd, args),                  // Promise<{code, stdout, stderr}>
  data: { subscribe(topic, cb), unsubscribe(topic) },
}
```

- `exec` starts `cmd` as an `hs.task`: no shell, `args` is an array, `cmd`
  should be an absolute path (for example `/usr/bin/uname`). The promise
  resolves with the exit code and the collected output, and rejects if the
  command is empty, cannot be started, or if 8 commands are already running
  for the page.
- `data.subscribe("spaces", cb)` calls `cb` every 2 seconds with
  `{spaces, windows}` from `yabai -m query --spaces` and `--windows`, or
  `{error: "yabai not available"}` once if yabai cannot be queried.
  `data.subscribe("metrics", cb)` reads `~/tmp/metrics.json` every second,
  written by a sampler that is not part of this repository; without it the
  callback receives `{error: "metrics unavailable"}` once. Other topics are
  ignored with a log warning. Closing the window stops the timers.
- Theme: the tokens in `state/theme.json` (see [THEMES.md](THEMES.md)) are
  available as `window.gallery.theme` and as CSS custom properties on `:root`,
  `--gallery-<token>`. Use the single-word tokens (`background`, `foreground`,
  `accent`, `muted`, `surface`, `border`, `danger`, `success`, `warning`,
  `info`, `cursor`, `color0` to `color15`) in plugin CSS. Multi-word tokens
  such as `surface_background` are named with underscores in the variables
  injected when the page loads and with hyphens (`--gallery-surface-background`)
  after a live theme reload, so they are not reliable names.
- When the theme changes while the page is open, the Spoon replaces the
  injected variables, updates `window.gallery.theme`, and dispatches
  `window.dispatchEvent(new CustomEvent("gallery:theme", {detail: theme}))`.
- With the bridge unavailable (for example the page opened in a browser),
  `window.gallery` is undefined: guard calls, and give the CSS fallbacks
  (`var(--gallery-accent, #d8a656)`). `plugins/gallery.hello/index.html`
  exercises every part of the bridge.

## Enabled state

`~/.config/gallery/gallery.json`:

```json
{"schemaVersion": 1, "enabled": ["gallery.hello"], "disabled": [], "settings": {}}
```

`gallery enable <id>` and `gallery disable <id>` rewrite it atomically (and
close the plugin's window on disable). A plugin is enabled if its id is in
`enabled`; otherwise, a `gallery.`-prefixed id is enabled unless it is in
`disabled`; any other id is disabled until enabled. A fresh file lists
`gallery.hello`. The Spoon writes `~/.config/gallery/state/ready` (epoch and
version) at the end of each start, which the installer waits for.

## Spoon IPC

The CLI talks to the Spoon with `hs.ipc`. To call it directly, use the watchdog
wrapper rather than bare `hs`:

```sh
gallery-hs -t 10 "return spoon.Gallery:ipc('list')"
gallery-hs -t 10 "return spoon.Gallery:ipc('open', 'gallery.hello')"
```

`spoon.Gallery:ipc(verb, id, kind)` always returns a string. Verbs:

| Verb | Argument | Result |
|---|---|---|
| `status` | | one-line summary |
| `list`, `list-json` | | plugins as tab-separated lines, or JSON |
| `open`, `close`, `toggle` | `id`, optional `kind` | `opened <id>`, `closed <id>`, `not open: <id>`, ... |
| `enable`, `disable` | `id` | persists to `gallery.json` |
| `validate` | directory | `ok`, or `warnings:`/`errors:` and the messages |
| `rescan` | | re-scan the plugin directory and reschedule services and feeds |
| `services` | | running services |
| `feed` | `id` | last feed JSON, or `no feed` |
| `theme`, `theme-json`, `theme-reload` | | current theme name, its tokens, or re-read it and re-inject into open webviews |

An unknown verb returns `unknown verb: <verb>`. Do not reload Hammerspoon over
IPC: the client that asked for the reload can hang. `gallery reload` touches
`~/.hammerspoon/init.lua` and lets the installed path watcher reload it.

## Importing Omarchy plugins

Most Omarchy plugins need no import: `gallery add <git-url> --enable` and the
[qml](#qml) kind run them as they are, with [patches](#macos-patches) for
Linux-only helpers.

`tools/import-omarchy-plugin` is for the cases where the QML view cannot run
(it needs a Quickshell module the shim lacks, or a Linux-only interface) and
the plugin is to be rebuilt as a web `panel`:

```sh
tools/import-omarchy-plugin <git-url-or-dir> [--out DIR] [--id NEW_ID]
```

It clones (shallow) or reads the plugin, then:

- scans `.qml` and `.js` files for `Process { command: [...] }` arrays, imports,
  and known Linux-only modules, paths and binaries (`Quickshell.Hyprland`,
  `Quickshell.Wayland`, `Quickshell.Services.*`, `/sys/`, `/proc/`, `hyprctl`,
  `pactl`, `wpctl`, `pw-*`, `bluetoothctl`, `notify-send`, `dbus*`), and
  classifies each command's binary as available, missing or non-portable;
- writes, under `--out` (default `./imported/<id>`): a converted
  `manifest.json` (entry points `index.html`, or `service.js` for `service`; a
  480 by 360 `gallery.panel` for visual kinds; an `imported` provenance block),
  the plugin's `.js` files copied verbatim, an `index.html` skeleton with a
  `Process.run` shim over `gallery.exec` and a TODO list of the QML views to
  rewrite, a `service.js` stub when the manifest declares `service`, and
  `PORT-REPORT.md`;
- runs `gallery validate` on the result if `gallery` is installed.

Exit code 0 means a verdict of portable or partial, 2 not portable, 1 an
error. The generated manifest has no `gallery.service` or `gallery.widget`
command, so add one for those kinds. The `Process` shim passes `cmd[0]` to
`gallery.exec` unchanged, which needs an absolute path.

## Security

Plugins are not sandboxed. A plugin runs arbitrary code with everything your
user account can reach: `gallery.exec` and `service`/`bar-widget` commands run
as you inside the Hammerspoon session, a `tui` command runs in your terminal,
and a `qml` plugin runs in a host process that can start any program through
`Process`. `gallery add` prints a warning and asks for confirmation (`--yes`
skips the prompt). Read a plugin before enabling it.
