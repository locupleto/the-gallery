import QtQuick
import QtQuick.Window

// Shim for Quickshell.PanelWindow: a layer-shell surface anchored to screen
// edges on real Wayland compositors. macOS has no layer-shell, so this is
// just a Window; `anchors`/`margins`/`exclusionMode` are accepted (some
// vendored qs.Ui files set them) but have no positioning effect here --
// host.py centers/sizes windows itself.
Window {
    id: root

    property QtObject anchors: QtObject {
        property bool top: false
        property bool bottom: false
        property bool left: false
        property bool right: false
    }
    property QtObject margins: QtObject {
        property int top: 0
        property int bottom: 0
        property int left: 0
        property int right: 0
    }
    property var exclusionMode: null

    property real implicitWidth: -1
    property real implicitHeight: -1
    onImplicitWidthChanged: if (implicitWidth > 0) width = implicitWidth
    onImplicitHeightChanged: if (implicitHeight > 0) height = implicitHeight

    readonly property bool backingWindowVisible: root.visible
}
