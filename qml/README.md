# gallery-qml

A PySide6 (Qt for Python 6.11) host that loads unmodified Omarchy 4
"Quattro" Quickshell plugins written in QML, on macOS. Launch with
`bin/gallery-qml <plugin-dir> [entry.qml] --title "<Name>"` (see that
script's header comment for the venv it manages).

## Layout

- `qml/host.py` -- the host: builds a `QGuiApplication` + `QQmlApplicationEngine`,
  wires up import paths, loads the plugin's entry QML, and either shows its
  root directly (if it's already a Window) or wraps a plain `Item` root in
  one.
- `qml/shim/` -- fills in the `Quickshell`, `Quickshell.Io`,
  `Quickshell.Hyprland`, `Quickshell.Wayland` and `Quickshell.Widgets` QML
  modules real Quickshell provides but PySide6 does not.
- `qml/vendor/qs/` -- vendored copy of Omarchy's own pure-QML `qs.Commons`
  (Border/Color/Style/Util singletons) and `qs.Ui` (Button, PanelSlider,
  BorderSurface, TextField, Toggle, ...) modules, fetched by
  `tools/vendor-omarchy-shell.sh`. See `qml/vendor/UPSTREAM.md` for the
  pinned commit.

## How the shim works

Two different techniques are used, per type, picked for whichever is less
code:

1. **Python classes** (`qml/shim/quickshell_*.py`), registered with the QML
   type system via PySide6's `@QmlElement` / `@QmlSingleton` / `@QmlAttached`
   decorators plus a `QML_IMPORT_NAME` / `QML_IMPORT_MAJOR_VERSION` pair per
   module. Registration happens as a side effect of importing the module
   (see `qml/shim/__init__.py`), and must happen *before* a
   `QQmlApplicationEngine` is constructed -- `host.py` does `import shim`
   right after inserting `qml/` onto `sys.path`. This is used for anything
   that needs real logic backed by a Qt C++ class: `Process` (QProcess),
   `FileView` (plain file I/O + QFileSystemWatcher), `StdioCollector`,
   `SplitParser`, the `Quickshell` singleton itself, the `Hyprland`
   singleton, and the `HyprlandWindow` / `WlrLayershell` attached-property
   objects.
2. **Plain QML files** under `qml/shim/Quickshell/` (with a `qmldir`,
   exactly like a hand-written QML module), for types that are thin
   wrappers around existing QtQuick/QtQml types: `FloatingWindow` /
   `PanelWindow` / `PopupWindow` (all `QtQuick.Window`), `ShellRoot` /
   `Scope` (plain `Item`), `LazyLoader` (`Loader`), `Variants`
   (`QtQml.Instantiator`), and everything in `Quickshell.Widgets`
   (`ClippingRectangle`, `WrapperItem`, `WrapperRectangle`,
   `MarginWrapperManager`, `IconImage`).

   A QML module can be provided by *both* mechanisms at once for the same
   URI (Python-registered types plus a qmldir's file-based ones) -- this is
   how `Quickshell` itself works here: the `Quickshell` singleton comes from
   Python, `FloatingWindow` and friends come from
   `qml/shim/Quickshell/*.qml`. `host.py` adds `qml/shim` to the QML import
   path so the qmldir-based half resolves; the Python half needs no import
   path at all, since `qmlRegisterType`-style registration lives in a
   process-global type registry independent of the filesystem.

### `Quickshell` (URI `Quickshell`, v1)

- `Quickshell` singleton: `env(name)`, `execDetached(list)`,
  `iconPath(name)` (always `""` -- no freedesktop icon theme on macOS),
  `processId`, `shellDir`/`shellPath`/`dataDir`/`stateDir`/`cacheDir`
  (under `~/.config/gallery` unless `$OMARCHY_PATH` is set), `screens`
  (`QGuiApplication.screens()`).
- `FloatingWindow`, `PanelWindow`, `PopupWindow`: plain `Window`s with
  `implicitWidth`/`implicitHeight` (Window has no such properties natively;
  these apply once, on change, to `width`/`height`), `minimumSize`
  (FloatingWindow), `backingWindowVisible` (aliased straight to `visible`
  -- there is no compositor-confirmation gap on macOS the way there can be
  on Wayland), and no-op/best-effort `anchors`/`margins`/`exclusionMode`
  (PanelWindow) or `anchorItem` (PopupWindow).
- `ShellRoot`, `Scope`: plain `Item` (its default `data` property already
  accepts non-visual `QObject` children, which is all either type needs).
- `LazyLoader`: `Loader` plus `component` (maps to `sourceComponent`) and
  `loading`.
- `Variants`: `QtQml.Instantiator` un-renamed -- it already has
  `model`/`delegate`/`active`/`count`/`object`/`objectAdded`/`objectRemoved`,
  which is exactly what Quickshell's own `Variants` offers, including
  support for non-`Item` delegates (e.g. a `PanelWindow` per screen) that a
  plain `Repeater` could not parent.

### `Quickshell.Io` (v1)

- `Process`: backed by `QProcess`. `command` (list), `running` (bool --
  setting it starts/stops the process), `environment`, `clearEnvironment`,
  `workingDirectory`, `stdinEnabled`, `stdout`/`stderr` (a `StdioCollector`
  or `SplitParser` instance), `processId`; `started()`/`exited(exitCode,
  exitStatus)` signals; `write(str)`, `signal(int)`, `exec(list)` (replace
  `command` and restart), `startDetached()`.
- `StdioCollector`: `text`/`data` properties, `waitForEnd`, `streamFinished()`
  signal, fired once when the owning `Process` exits (this host does not
  attempt a mid-run partial-`waitForEnd:false` streaming mode -- every
  plugin surveyed for this host uses `waitForEnd: true`).
- `SplitParser`: `splitMarker` (default `"\n"`), `read(data)` signal per
  chunk as bytes arrive, plus whatever partial chunk remains when the
  process exits.
- `FileView`: `path`, `watchChanges` (via `QFileSystemWatcher`),
  `atomicWrites` (write-to-temp-then-`os.replace`), `preload` (default
  `true`), `printErrors`, `blockWrites`/`blockLoading` (accepted, but this
  host's I/O is synchronous either way), `adapter` (opaque passthrough,
  unused); `text()`/`data()`/`setText(str)`/`setData(bytes)`/`reload()`
  methods; `loaded()`/`loadFailed(error)`/`saved()`/`saveFailed(error)`/
  `fileChanged()` signals. The initial auto-load (when `preload` is true)
  is deferred one event-loop tick past construction via
  `QTimer.singleShot(0, ...)` rather than reacting to the `path` setter
  immediately -- see the docstring on `FileView` in
  `qml/shim/quickshell_io.py` for why (some plugins, Radio Atlas included,
  set `preload: false` *after* `path` in object-literal order).
- **Not implemented**: `DataStream`, `SocketServer`, `Socket`. No plugin
  surveyed for this host uses them, and they would need a real IPC
  transport to mean anything standalone on macOS.

### `Quickshell.Hyprland` (v1)

There is no Hyprland (or any Wayland compositor) on macOS. `Hyprland`
singleton: `dispatch()` is a no-op, `focusedMonitor`/`monitors`/
`workspaces` are always empty/null, `rawEvent(event)` is declared but never
emitted (so `Connections { target: Hyprland; function onRawEvent(e) {} }`
binds cleanly, it just never fires). `HyprlandWindow` attached property:
settable no-op `opacity` (float).

### `Quickshell.Wayland` (v1)

`WlrLayershell` attached property: `namespace`, `layer`, `keyboardFocus`,
`exclusiveZone` -- all settable, all no-ops. The `WlrLayer` /
`WlrKeyboardFocus` / `ExclusionMode` enums some qs.Ui files reference
(`WlrLayer.Overlay`, `ExclusionMode.Ignore`, ...) are **not** provided:
none of RadioAtlas.qml, gallery.qml-demo, or the Button/PanelSlider/
BorderSurface/TextField/Toggle/WidgetButton/BarWidget dependency chain
those two plugins exercise ever imports the qs.Ui files that reference them
(`KeyboardPanel.qml`, `SpeedTestOverlay.qml`, `Panel.qml`, `PopupCard.qml`,
`Dropdown.qml`, `SearchableDropdown.qml`, `ConfirmDialog.qml`,
`MultiSelect.qml`). QML only compiles a module file the first time
something actually instantiates one of its types, so these files sit in
`qml/vendor/qs/Ui/` unused and inert rather than needing a patch. A plugin
that *does* reach one of them will fail to load; extending the shim to
cover `IpcHandler`, `QsWindow`, and those three enums would be the next
slice.

### `Quickshell.Widgets` (v1)

`ClippingRectangle` (`Rectangle { clip: true }`), `WrapperItem` /
`WrapperRectangle` (size-to-content-plus-margin, best-effort), `IconImage`
(plain `Image`; pointless without a real icon theme, but a plugin can still
set `source` on it directly), `MarginWrapperManager` (plain data holder).
None of these are exercised by RadioAtlas.qml or gallery.qml-demo.

## macOS-specific gotchas the host works around

- **QtQuick Controls native style can't be customized.** qs.Ui's
  `Button`/`TextField`/etc. override `Control.background`, which macOS's
  native Controls style refuses ("the current style does not support
  customization of this control"). `host.py` sets
  `QT_QUICK_CONTROLS_STYLE=Basic` before constructing `QGuiApplication`
  unless the environment already overrides it.
- **Panel-kind plugins commonly gate their real UI behind `open()`.**
  qs.Ui's `Panel.qml` base class (and Radio Atlas, independently) expose a
  root-level `open()`/`show()` function that a real Omarchy shell calls on
  "summon"; without a shell, nothing would ever call it, and (in Radio
  Atlas's case) its actual content lives inside a nested `FloatingWindow`
  that `open()` makes visible -- the wrapped root `Item` itself paints
  nothing on its own. `host.py` calls `open()` (or `show()`) once via
  `QMetaObject.invokeMethod`, best-effort, after wrapping an `Item` root; a
  plugin with no such method (like the demo plugin, which renders directly)
  is unaffected. One side effect: for a plugin like Radio Atlas, this means
  **two** top-level windows end up on screen -- the host's own empty
  `Gallery: <Name>` wrapper (per the generic Item-wrapping contract) and
  the plugin's own separately-titled window with the actual content. Not
  pretty, but harmless, and fixing it would require guessing whether a
  plugin's root `Item` ever paints anything of its own before deciding
  whether to create the wrapper at all.
- **SIGTERM needs to reach `app.quit()`, not the OS default.** `gallery
  close`/`pkill` send SIGTERM to the pid in the pidfile; Python's default
  SIGTERM handling just kills the process without running `aboutToQuit`
  (so the pidfile would never get cleaned up, and helper processes started
  via `Process`/`execDetached` could survive it). `host.py` installs a
  `signal.signal(SIGTERM, ...)` handler that calls `app.quit()`, plus an
  idle 200ms `QTimer` -- a blocked Qt event loop never hands control back
  to the Python interpreter to notice a pending signal otherwise.
- **QJSValue, not a Python list.** A QML array literal bound to a Python
  `Property`/`Slot` typed `"QVariant"` arrives as a `QJSValue`, not an
  already-unwrapped Python list -- `list(some_qjsvalue)` raises `TypeError`
  and (if not caught very deliberately) silently produces an empty
  command/environment. See `qml/shim/_jsvalue.py`.
- **`QProcess.finished`'s `exitStatus` is a real enum**, not a plain int,
  in this PySide6 version; `int(exit_status)` raises `TypeError` --
  unwrap via `.value` first (see `Process._on_finished`).

## Vendoring qs.Commons / qs.Ui

```
tools/vendor-omarchy-shell.sh                 # from omacom/omarchy@quattro
OMARCHY_REF=some-other-ref tools/vendor-omarchy-shell.sh
```

Re-runnable: it always re-fetches every file under `shell/Commons/` and
`shell/Ui/` from the resolved commit and overwrites
`qml/vendor/qs/{Commons,Ui}` in place, then rewrites
`qml/vendor/UPSTREAM.md` with the commit this vendor came from. Requires an
authenticated `gh` (`gh auth status`).

## Running a plugin by hand

```
bin/gallery-qml <plugin-dir> [entry.qml] --title "<Name>" [--width W --height H]
```

`entry.qml` is optional if the plugin has a `manifest.json` with
`entryPoints.panel`, or exactly one `*.qml` file. `bin/gallery-qml` creates
(once) a venv at `~/.config/gallery/qml-venv` via `uv` -- a uv-*managed*
Python, never Homebrew's, per this repo's standing rule for Gallery venvs
-- and installs PySide6 into it before exec'ing `qml/host.py`.

A window's pidfile lives at
`~/.config/gallery/state/qml/<title-slug>.pid`; `kill -TERM $(cat
that-file)` closes it cleanly (pidfile removed, process group killed, no
leftover child processes).
