"""Shim for `Quickshell.Hyprland` (URI "Quickshell.Hyprland", major version 1).

There is no Hyprland (or any Wayland compositor) on macOS. This exists so
plugins that defensively import and reference `Hyprland`/`HyprlandWindow`
keep loading: `dispatch()` is a no-op, `focusedMonitor`/`monitors`/
`workspaces` are always empty, and `rawEvent` is declared but never emitted
(so a `Connections { target: Hyprland; function onRawEvent(e) {} }` binds
without a "no matching signal" warning, it just never fires).
"""

from PySide6.QtCore import Property, QObject, Signal, Slot
from PySide6.QtQml import QmlAttached, QmlElement, QmlSingleton

QML_IMPORT_NAME = "Quickshell.Hyprland"
QML_IMPORT_MAJOR_VERSION = 1


@QmlElement
@QmlSingleton
class Hyprland(QObject):
    rawEvent = Signal("QVariant", arguments=["event"])

    @Slot(str)
    def dispatch(self, _request):
        pass

    @Property("QVariant", constant=True)
    def focusedMonitor(self):
        return None

    @Property("QVariant", constant=True)
    def monitors(self):
        return []

    @Property("QVariant", constant=True)
    def workspaces(self):
        return []


class HyprlandWindowAttached(QObject):
    """Attached-property object for `HyprlandWindow.<prop>: ...`."""

    opacityChanged = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._opacity = 1.0

    def _get_opacity(self):
        return self._opacity

    def _set_opacity(self, value):
        value = float(value)
        if value != self._opacity:
            self._opacity = value
            self.opacityChanged.emit()

    opacity = Property(float, _get_opacity, _set_opacity, notify=opacityChanged)


@QmlElement
@QmlAttached(HyprlandWindowAttached)
class HyprlandWindow(QObject):
    # PySide6's attached-property dispatch calls this with extra leading
    # positional args beyond the attachee (observed empirically); only the
    # last argument is the object the property is attached to.
    @classmethod
    def qmlAttachedProperties(cls, *args):
        return HyprlandWindowAttached(args[-1])
