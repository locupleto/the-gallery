"""Python side of the Quickshell shim.

Importing this package registers every Python-backed QML type (the
`Quickshell`, `Quickshell.Io`, `Quickshell.Hyprland` and `Quickshell.Wayland`
modules) with the QML engine's type system. It must be imported *before* a
`QQmlApplicationEngine` is created -- see qml/host.py.

`Quickshell.Widgets`, and the window/loader types in `Quickshell` itself
(FloatingWindow, PanelWindow, PopupWindow, ShellRoot, Scope, LazyLoader,
Variants), are plain QML files instead -- see qml/shim/Quickshell/ -- since
they are thin wrappers around existing QtQuick/QtQml types and a QML file is
simpler than a Python class for them. Those are picked up automatically once
`qml/shim` is on the QML import path; nothing to import here for those.
"""

from . import quickshell_core  # noqa: F401
from . import quickshell_io  # noqa: F401
from . import quickshell_hyprland  # noqa: F401
from . import quickshell_wayland  # noqa: F401
