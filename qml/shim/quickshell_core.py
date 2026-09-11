"""Shim for the `Quickshell` QML module (URI "Quickshell", major version 1).

Provides the `Quickshell` singleton only. `ShellRoot`, `Scope`,
`FloatingWindow`, `PanelWindow`, `PopupWindow`, `LazyLoader` and `Variants`
are plain QML files living next to this module's qmldir
(qml/shim/Quickshell/) -- they are thin wrappers around existing QtQuick /
QtQml types (Window, Loader, Instantiator, Item), so a QML file is simpler
than a Python class.
"""

import os
import subprocess
import tempfile

from PySide6.QtCore import Property, QObject, Slot
from PySide6.QtGui import QGuiApplication
from PySide6.QtQml import QmlElement, QmlSingleton

from ._jsvalue import to_str_list

QML_IMPORT_NAME = "Quickshell"
QML_IMPORT_MAJOR_VERSION = 1


def gallery_config_dir() -> str:
    return os.environ.get("OMARCHY_PATH") or os.path.expanduser("~/.config/gallery")


@QmlElement
@QmlSingleton
class Quickshell(QObject):
    """Stand-in for Quickshell's own `Quickshell` singleton.

    Real values are supplied where a macOS equivalent exists (env,
    processId, the various directories); Wayland/Hyprland-only concepts
    (screens as a live compositor model, iconPath resolution against a
    freedesktop icon theme) are best-effort stubs.
    """

    @Slot(str, result=str)
    def env(self, name):
        return os.environ.get(name, "")

    @Slot("QVariant")
    def execDetached(self, command):
        cmd = to_str_list(command)
        if not cmd:
            return
        try:
            subprocess.Popen(
                cmd,
                start_new_session=True,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except OSError:
            pass

    @Slot(str, result=str)
    def iconPath(self, name):
        # No freedesktop icon theme on macOS; nothing sane to resolve to.
        return ""

    @Property(int, constant=True)
    def processId(self):
        return os.getpid()

    @Property(str, constant=True)
    def shellDir(self):
        return gallery_config_dir()

    @Property(str, constant=True)
    def shellPath(self):
        return gallery_config_dir()

    @Property(str, constant=True)
    def dataDir(self):
        return os.path.join(gallery_config_dir(), "data")

    @Property(str, constant=True)
    def stateDir(self):
        return os.path.join(gallery_config_dir(), "state")

    @Property(str, constant=True)
    def cacheDir(self):
        return os.path.join(tempfile.gettempdir(), "gallery-cache")

    @Property("QVariant", constant=True)
    def screens(self):
        app = QGuiApplication.instance()
        return list(app.screens()) if app else []
