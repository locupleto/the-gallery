#!/usr/bin/env python3
"""gallery-qml host.

Loads a single Omarchy-style QML plugin entry point (unmodified) into a
PySide6 QQmlApplicationEngine, using the Quickshell shim in qml/shim/ and
the vendored qs.Commons / qs.Ui in qml/vendor/qs/.

Usage:
    python host.py <plugin-dir> [entry.qml] --title "<Name>" [--width W] [--height H]

If entry.qml is omitted, the plugin's manifest.json entryPoints.panel is
used, falling back to the sole *.qml file in the plugin directory if there
is exactly one.
"""

import argparse
import json
import os
import re
import signal
import sys
from pathlib import Path

QML_DIR = Path(__file__).resolve().parent

# shim/ must be importable *and* registered with the QML type system
# before a QQmlApplicationEngine exists -- see qml/shim/__init__.py.
sys.path.insert(0, str(QML_DIR))
import shim  # noqa: E402,F401
from shim import quickshell_io as _shim_io  # noqa: E402

from PySide6.QtCore import (  # noqa: E402
    QMetaObject,
    QObject,
    Q_ARG,
    Qt,
    QTimer,
    QUrl,
    Slot,
    qInstallMessageHandler,
)
import signal as _signal  # noqa: E402
from PySide6.QtGui import QFont, QFontDatabase, QColor, QCursor, QGuiApplication  # noqa: E402
from PySide6.QtQml import QQmlApplicationEngine, QQmlComponent  # noqa: E402
from PySide6.QtQuick import QQuickWindow  # noqa: E402


class _ProcessPollBridge(QObject):
    """Bridges a QML Timer (which keeps firing under the macOS event loop,
    unlike a Python QTimer) to the shim's process-exit reaper."""

    @Slot()
    def poll(self):
        _shim_io.poll_processes()


class _CloseShortcutFilter(QObject):
    """App-wide Cmd+W handler. A QtQuick plugin has no menu bar, so the
    standard macOS close shortcut never reaches it; with the Command
    modifier the combo is delivered as a ShortcutOverride/KeyPress that the
    focused QML item ignores, so catch it at the application level and quit."""

    def __init__(self, app):
        super().__init__(app)
        self._app = app

    def eventFilter(self, obj, event):
        from PySide6.QtCore import QEvent
        if event.type() in (QEvent.ShortcutOverride, QEvent.KeyPress):
            if event.key() == Qt.Key_W and (event.modifiers() & Qt.ControlModifier):
                self._app.quit()
                return True
        return super().eventFilter(obj, event)

DEFAULT_WIDTH = 900
DEFAULT_HEIGHT = 640
FALLBACK_BACKGROUND = "#101315"  # qs.Commons Color.qml's own default


def slugify(title: str) -> str:
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", title.strip()).strip("-").lower()
    return slug or "plugin"


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plugin_dir")
    parser.add_argument("entry_qml", nargs="?", default=None)
    parser.add_argument("--title", required=True)
    parser.add_argument("--width", type=int, default=None)
    parser.add_argument("--height", type=int, default=None)
    return parser.parse_args(argv)


def resolve_entry(plugin_dir: Path, entry_qml):
    if entry_qml:
        return (plugin_dir / entry_qml).resolve()

    manifest_path = plugin_dir / "manifest.json"
    if manifest_path.exists():
        try:
            manifest = json.loads(manifest_path.read_text())
            panel_entry = manifest.get("entryPoints", {}).get("panel")
            if panel_entry:
                return (plugin_dir / panel_entry).resolve()
        except (OSError, ValueError, AttributeError):
            pass

    qml_files = sorted(plugin_dir.glob("*.qml"))
    if len(qml_files) == 1:
        return qml_files[0].resolve()
    raise SystemExit(
        f"gallery-qml: cannot determine entry QML in {plugin_dir}; "
        "pass it explicitly as the second argument"
    )


def ensure_runtime_env():
    # qs.Ui's Button/TextField/etc. customize QtQuick.Controls'
    # `background:` delegate; macOS's native Controls style refuses that
    # (see the "current style does not support customization" QML warning)
    # so force the cross-platform Basic style, which every plugin gets
    # regardless of what style the user's Qt install would otherwise pick.
    os.environ.setdefault("QT_QUICK_CONTROLS_STYLE", "Basic")
    if not os.environ.get("XDG_RUNTIME_DIR"):
        runtime_dir = os.path.join(os.environ.get("TMPDIR", "/tmp"), "gallery-runtime")
        os.makedirs(runtime_dir, exist_ok=True)
        try:
            os.chmod(runtime_dir, 0o700)
        except OSError:
            pass
        os.environ["XDG_RUNTIME_DIR"] = runtime_dir
    if not os.environ.get("OMARCHY_PATH"):
        os.environ["OMARCHY_PATH"] = os.path.expanduser("~/.config/gallery")


def pidfile_path(title_slug: str) -> Path:
    state_dir = Path(os.path.expanduser("~/.config/gallery/state/qml"))
    state_dir.mkdir(parents=True, exist_ok=True)
    return state_dir / f"{title_slug}.pid"


def qml_message_handler(_msg_type, _context, message):
    # Route QML console.log/warn/error and engine warnings to stderr, one
    # line each, regardless of the message's severity -- callers grep this
    # for "no QML load errors" rather than caring about Qt's own log levels.
    print(message, file=sys.stderr)


def read_theme_background():
    """Best-effort read of the active Gallery/Omarchy theme's background
    color, mirroring qs.Commons Color.qml's own fallback chain (background,
    else color0) without needing a QML context to ask the real singleton."""
    theme_file = Path(os.path.expanduser("~/.local/state/omarchy/current/theme/colors.toml"))
    if not theme_file.exists():
        return None
    try:
        raw = theme_file.read_text()
    except OSError:
        return None
    background = None
    darker_background = None
    color0 = None
    for line in raw.splitlines():
        match = re.match(r'\s*([A-Za-z0-9_-]+)\s*=\s*"?(#[0-9A-Fa-f]{6})', line)
        if not match:
            continue
        if match.group(1) == "background":
            background = match.group(2)
        elif match.group(1) == "darker_background":
            darker_background = match.group(2)
        elif match.group(1) == "color0":
            color0 = match.group(2)
    # Prefer the theme's deepest tone so the host window fill matches the
    # near-black QML plugin surfaces (see qs.Commons Color.qml).
    return darker_background or background or color0


def resolve_background_color(root):
    value = root.property("background")
    if isinstance(value, QColor) and value.isValid():
        return value
    theme_bg = read_theme_background()
    return QColor(theme_bg or FALLBACK_BACKGROUND)


NERD_FONT_CANDIDATES = (
    "JetBrainsMono Nerd Font",
    "Hack Nerd Font",
    "MesloLGM Nerd Font",
    "MesloLGL Nerd Font",
    "CaskaydiaCove Nerd Font",
    "FiraCode Nerd Font",
)

# Same state dir bin/gallery's FONT_STATE_FILE and pidfile_path above both
# point at -- `gallery font set|native` writes {"family": ..., "size": ...,
# "weight": ...} here; missing/garbage means no preference (see
# read_font_pref_family below, the same tolerance as
# tools/render-theme.py's read_font_prefs).
FONT_STATE_PATH = Path(os.path.expanduser("~/.config/gallery/state/font.json"))


def read_font_pref_family():
    """Best-effort read of the Gallery-wide font family preference, or None
    if the file is missing, unreadable, or carries no usable family."""
    try:
        data = json.loads(FONT_STATE_PATH.read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    family = data.get("family")
    if isinstance(family, str) and family.strip():
        return family.strip()
    return None


def install_font_substitutions():
    """Omarchy's Style.fontFamily is the fontconfig alias "monospace", which
    on Omarchy resolves to a Nerd Font; its plugins draw icons from the
    private-use glyphs of that font. On macOS Qt maps "monospace" to Menlo,
    which has no such glyphs, so icons render as boxes. Route the alias to
    an installed Nerd Font instead: $GALLERY_FONT wins outright (an explicit
    per-invocation override); otherwise the `gallery font set` preference
    (if any) goes first in the fallback list, ahead of the hardcoded
    NERD_FONT_CANDIDATES."""
    families = set(QFontDatabase.families())
    candidates = list(NERD_FONT_CANDIDATES)
    font_pref = read_font_pref_family()
    if font_pref:
        candidates.insert(0, font_pref)
    wanted = [os.environ.get("GALLERY_FONT", "")] + candidates
    for family in wanted:
        if family and family in families:
            for alias in ("monospace", "Monospace", "mono"):
                QFont.insertSubstitution(alias, family)
            return family
    return None


def invoke_open_if_present(root):
    """Best-effort: many Omarchy "panel"-kind plugins (Radio Atlas among
    them) gate their real UI behind an open()/show() call the shell issues
    on summon -- qs.Ui's Panel.qml base class follows the same convention.
    Standalone hosting has no shell to make that call, so make it here once
    the window exists; this is what makes such a plugin's actual content
    (e.g. Radio Atlas's nested FloatingWindow and its globe) appear at all.
    A plugin with no `open` method (like the demo plugin, which renders
    directly) is unaffected.
    """
    meta = root.metaObject()
    for name, arg in (("open", "{}"), ("show", "{}"), ("open", None), ("show", None)):
        if arg is None:
            idx = meta.indexOfMethod(f"{name}()")
        else:
            idx = meta.indexOfMethod(f"{name}(QVariant)")
        if idx < 0:
            continue

        def _invoke(name=name, arg=arg):
            if arg is None:
                QMetaObject.invokeMethod(root, name, Qt.DirectConnection)
            else:
                QMetaObject.invokeMethod(root, name, Qt.DirectConnection, Q_ARG("QVariant", arg))

        QTimer.singleShot(0, _invoke)
        return


def center_on_cursor_screen(window):
    cursor_pos = QCursor.pos()
    screen = QGuiApplication.screenAt(cursor_pos) or QGuiApplication.primaryScreen()
    if screen is None:
        return
    geometry = screen.availableGeometry()
    x = geometry.x() + (geometry.width() - window.width()) // 2
    y = geometry.y() + (geometry.height() - window.height()) // 2
    window.setPosition(x, y)


def install_escape_to_close(window, app):
    original_key_release = window.keyReleaseEvent

    def key_release(event):
        original_key_release(event)
        # Cmd+W is the standard macOS "close window" shortcut; close on it
        # unconditionally (Qt maps the Command key to ControlModifier on
        # macOS). Escape only closes if the plugin did not consume it for
        # its own use (Radio Atlas uses Escape to clear search / hide help).
        if event.key() == Qt.Key_W and (event.modifiers() & Qt.ControlModifier):
            app.quit()
        elif not event.isAccepted() and event.key() == Qt.Key_Escape:
            app.quit()

    window.keyReleaseEvent = key_release


def visible_plugin_windows():
    return [
        w for w in QGuiApplication.allWindows()
        if w.isVisible() and w.parent() is None and isinstance(w, QQuickWindow)
    ]


def install_quit_on_hide(window, app):
    """A plugin that hides its own window (Radio Atlas's Escape does
    `panel.visible = false` and then calls a shell.hide() that does not
    exist here) would otherwise leave this process alive with no window:
    the pidfile still says "open", so the next `gallery toggle` spends
    itself killing an invisible host instead of showing one. Treat "last
    window hidden" exactly like "last window closed": quit, so the pidfile
    goes away and the next toggle launches afresh. Debounced slightly so a
    plugin that hides and re-shows within a frame is not caught out."""

    def check_quit():
        if not visible_plugin_windows():
            app.quit()

    def on_visible_changed(visible):
        if not visible:
            QTimer.singleShot(150, check_quit)

    window.visibleChanged.connect(on_visible_changed)


def bring_to_front(window):
    """The host is launched from skhd/nohup, i.e. by a process that is not
    the active application, so macOS does not hand it key focus on its
    own. Without focus the plugin's key handlers (Escape included) never
    see a keypress. Ask for it explicitly; the yabai float rule keeps the
    window on top regardless."""
    window.raise_()
    window.requestActivate()


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    plugin_dir = Path(args.plugin_dir).resolve()
    if not plugin_dir.is_dir():
        raise SystemExit(f"gallery-qml: no such plugin directory: {plugin_dir}")
    entry_path = resolve_entry(plugin_dir, args.entry_qml)
    if not entry_path.exists():
        raise SystemExit(f"gallery-qml: entry QML not found: {entry_path}")

    ensure_runtime_env()
    qInstallMessageHandler(qml_message_handler)

    # Claim the pidfile before Qt/QML start up (a second or more): until it
    # exists bin/gallery believes the plugin is not running, so two quick
    # toggles would launch two hosts. bin/gallery also writes it at launch
    # time; this is the same pid, since gallery-qml execs into us.
    title_slug = slugify(args.title)
    pidfile = pidfile_path(title_slug)
    pidfile.write_text(str(os.getpid()))

    # Its own process group, so quitting can take any helper processes the
    # plugin spawned (Process/execDetached) down with it instead of leaving
    # zombies behind.
    try:
        os.setpgrp()
    except OSError:
        pass

    app = QGuiApplication(sys.argv[:1])
    # Dock/menu identity. The real name + icon come from the Gallery.app
    # bundle the host is launched through (see bin/gallery-qml); this keeps
    # the name consistent when run unbundled (e.g. a dev checkout).
    app.setApplicationName("Gallery")

    _close_filter = _CloseShortcutFilter(app)
    app.installEventFilter(_close_filter)

    chosen_font = install_font_substitutions()

    if chosen_font:

        print(f"gallery-qml: monospace -> {chosen_font}", file=sys.stderr)

    # `gallery close`/pkill send SIGTERM to the pid in our pidfile. Python's
    # default SIGTERM handling would just kill the process without running
    # aboutToQuit (so cleanup() -- unlinking the pidfile, killing our
    # process group -- would never run); route it through app.quit()
    # instead. A Qt event loop blocked in C++ never gives the interpreter a
    # chance to notice a pending signal, so a short idle QTimer is needed
    # to keep handing control back to Python periodically.
    _signal.signal(_signal.SIGTERM, lambda *_a: app.quit())
    _signal.signal(_signal.SIGINT, lambda *_a: app.quit())
    _signal_poke_timer = QTimer()
    _signal_poke_timer.timeout.connect(lambda: None)
    _signal_poke_timer.start(200)

    engine = QQmlApplicationEngine()
    engine.addImportPath(str(QML_DIR / "shim"))
    engine.addImportPath(str(QML_DIR / "vendor"))
    engine.addImportPath(str(plugin_dir))

    engine.load(QUrl.fromLocalFile(str(entry_path)))
    if not engine.rootObjects():
        print(f"gallery-qml: failed to load {entry_path}", file=sys.stderr)
        try:
            pidfile.unlink()
        except FileNotFoundError:
            pass
        sys.exit(1)

    root = engine.rootObjects()[0]

    # Drive the shim's process-exit reaper from a QML Timer: a Process the
    # QML engine instantiated never gets its own QProcess/QTimer callbacks
    # serviced on macOS while idle, but a QML Timer element does keep firing.
    poll_bridge = _ProcessPollBridge()
    engine.rootContext().setContextProperty("__galleryProcessPoll", poll_bridge)
    poll_component = QQmlComponent(
        engine,
        QUrl.fromLocalFile(str(QML_DIR / "ProcessPoll.qml")),
        QQmlComponent.CompilationMode.PreferSynchronous,
    )
    poll_timer_obj = poll_component.create(engine.rootContext())
    if poll_timer_obj is None:
        print(
            "gallery-qml: process-poll timer failed: "
            + poll_component.errorString().strip(),
            file=sys.stderr,
        )
    else:
        # Parent it into the loaded plugin's own object tree so it is driven
        # by the same event source as the plugin's working QML timers.
        poll_timer_obj.setParent(root)

    def cleanup():
        try:
            pidfile.unlink()
        except FileNotFoundError:
            pass
        # Take the whole process group down so a plugin's helper scripts
        # (started via Process or Quickshell.execDetached) never survive us.
        try:
            os.killpg(os.getpgrp(), signal.SIGTERM)
        except OSError:
            pass

    if isinstance(root, QQuickWindow):
        window = root
        if not window.title():
            window.setTitle(args.title)
    else:
        width = args.width or int(root.property("preferredWidth") or 0) or DEFAULT_WIDTH
        height = args.height or int(root.property("preferredHeight") or 0) or DEFAULT_HEIGHT

        window = QQuickWindow()
        window.setTitle(f"Gallery: {args.title}")
        window.resize(width, height)
        window.setColor(resolve_background_color(root))

        root.setParentItem(window.contentItem())
        root.setWidth(width)
        root.setHeight(height)

        invoke_open_if_present(root)

    def plugin_windows():
        """Visible top-level windows the plugin created itself (Radio Atlas
        opens its own FloatingWindow from open()); never our wrapper."""
        return [w for w in visible_plugin_windows() if w is not window]

    def adopt(plugin_window):
        # The plugin's own window becomes THE Gallery window: same title
        # convention (the CLI and yabai key off "Gallery: <Name>"), centred,
        # Escape-to-close; the empty wrapper stays hidden.
        plugin_window.setTitle(f"Gallery: {args.title}")
        center_on_cursor_screen(plugin_window)
        install_escape_to_close(plugin_window, app)
        if window.isVisible():
            window.hide()
        install_quit_on_hide(plugin_window, app)
        bring_to_front(plugin_window)

    adopted = {"done": False}

    def poll_plugin_windows():
        if adopted["done"]:
            return
        found = plugin_windows()
        if found:
            adopted["done"] = True
            adopt(found[0])

    is_wrapper = not isinstance(root, QQuickWindow)
    if is_wrapper:
        # Give a plugin that opens its own window a moment to do so before
        # the wrapper is shown at all (avoids a doubled window), then keep
        # watching for a while in case it opens late (after a fetch, say).
        poll_plugin_windows()
        if not adopted["done"]:
            center_on_cursor_screen(window)
            window.show()
            install_escape_to_close(window, app)
            bring_to_front(window)
        watch = QTimer(); watch.setInterval(100)
        ticks = {"n": 0}
        def _tick():
            ticks["n"] += 1
            poll_plugin_windows()
            if adopted["done"] or ticks["n"] > 50:
                watch.stop()
        watch.timeout.connect(_tick)
        watch.start()
    else:
        center_on_cursor_screen(window)
        window.show()
        install_escape_to_close(window, app)
        install_quit_on_hide(window, app)
        bring_to_front(window)
    # QGuiApplication quits on its own when the last window closes; wiring
    # QQuickWindow.closing to a Python slot instead raises a TypeError in
    # PySide6 (QQuickCloseEvent* is not convertible) on every close.
    app.setQuitOnLastWindowClosed(True)

    exit_code = app.exec()
    cleanup()
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
