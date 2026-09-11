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

from PySide6.QtCore import (  # noqa: E402
    QMetaObject,
    Q_ARG,
    Qt,
    QTimer,
    QUrl,
    qInstallMessageHandler,
)
import signal as _signal  # noqa: E402
from PySide6.QtGui import QColor, QCursor, QGuiApplication  # noqa: E402
from PySide6.QtQml import QQmlApplicationEngine  # noqa: E402
from PySide6.QtQuick import QQuickWindow  # noqa: E402

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
    color0 = None
    for line in raw.splitlines():
        match = re.match(r'\s*([A-Za-z0-9_-]+)\s*=\s*"?(#[0-9A-Fa-f]{6})', line)
        if not match:
            continue
        if match.group(1) == "background":
            background = match.group(2)
        elif match.group(1) == "color0":
            color0 = match.group(2)
    return background or color0


def resolve_background_color(root):
    value = root.property("background")
    if isinstance(value, QColor) and value.isValid():
        return value
    theme_bg = read_theme_background()
    return QColor(theme_bg or FALLBACK_BACKGROUND)


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
        if not event.isAccepted() and event.key() == Qt.Key_Escape:
            app.quit()

    window.keyReleaseEvent = key_release


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

    # Its own process group, so quitting can take any helper processes the
    # plugin spawned (Process/execDetached) down with it instead of leaving
    # zombies behind.
    try:
        os.setpgrp()
    except OSError:
        pass

    app = QGuiApplication(sys.argv[:1])

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
        sys.exit(1)

    root = engine.rootObjects()[0]

    title_slug = slugify(args.title)
    pidfile = pidfile_path(title_slug)
    pidfile.write_text(str(os.getpid()))

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

    center_on_cursor_screen(window)
    window.show()
    install_escape_to_close(window, app)
    # QGuiApplication quits on its own when the last window closes; wiring
    # QQuickWindow.closing to a Python slot instead raises a TypeError in
    # PySide6 (QQuickCloseEvent* is not convertible) on every close.
    app.setQuitOnLastWindowClosed(True)

    exit_code = app.exec()
    cleanup()
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
