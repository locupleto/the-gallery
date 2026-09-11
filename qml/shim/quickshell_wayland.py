"""Shim for `Quickshell.Wayland` (URI "Quickshell.Wayland", major version 1).

There is no wlroots layer-shell on macOS. `WlrLayershell` is an
attached-property stub so plugins that set `WlrLayershell.namespace`,
`.layer` or `.keyboardFocus` on a window (usually a PanelWindow) keep
loading; none of it has any effect on how the window actually behaves here.
The `WlrLayer` / `WlrKeyboardFocus` enums plugins sometimes reference
(`WlrLayer.Overlay`, `WlrKeyboardFocus.Exclusive`, ...) are NOT provided --
no plugin this host targets needs them, and none of the vendored qs.Ui
files that reference them (KeyboardPanel.qml, SpeedTestOverlay.qml) are
imported by RadioAtlas.qml, the demo plugin, or any Button/PanelSlider/
BorderSurface/TextField/Toggle/WidgetButton/BarWidget dependency chain, so
they are never compiled. See qml/README.md.
"""

from PySide6.QtCore import Property, QObject, Signal
from PySide6.QtQml import QmlAttached, QmlElement

QML_IMPORT_NAME = "Quickshell.Wayland"
QML_IMPORT_MAJOR_VERSION = 1


class WlrLayershellAttached(QObject):
    namespaceChanged = Signal()
    layerChanged = Signal()
    keyboardFocusChanged = Signal()
    exclusiveZoneChanged = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._namespace = ""
        self._layer = None
        self._keyboard_focus = None
        self._exclusive_zone = 0

    def _get_namespace(self):
        return self._namespace

    def _set_namespace(self, value):
        if value != self._namespace:
            self._namespace = value
            self.namespaceChanged.emit()

    namespace = Property(str, _get_namespace, _set_namespace, notify=namespaceChanged)

    def _get_layer(self):
        return self._layer

    def _set_layer(self, value):
        if value != self._layer:
            self._layer = value
            self.layerChanged.emit()

    layer = Property("QVariant", _get_layer, _set_layer, notify=layerChanged)

    def _get_keyboard_focus(self):
        return self._keyboard_focus

    def _set_keyboard_focus(self, value):
        if value != self._keyboard_focus:
            self._keyboard_focus = value
            self.keyboardFocusChanged.emit()

    keyboardFocus = Property(
        "QVariant", _get_keyboard_focus, _set_keyboard_focus, notify=keyboardFocusChanged
    )

    def _get_exclusive_zone(self):
        return self._exclusive_zone

    def _set_exclusive_zone(self, value):
        value = int(value)
        if value != self._exclusive_zone:
            self._exclusive_zone = value
            self.exclusiveZoneChanged.emit()

    exclusiveZone = Property(
        int, _get_exclusive_zone, _set_exclusive_zone, notify=exclusiveZoneChanged
    )


@QmlElement
@QmlAttached(WlrLayershellAttached)
class WlrLayershell(QObject):
    @classmethod
    def qmlAttachedProperties(cls, *args):
        return WlrLayershellAttached(args[-1])
