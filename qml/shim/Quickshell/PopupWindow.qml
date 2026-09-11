import QtQuick
import QtQuick.Window

// Shim for Quickshell.PopupWindow: a small positioned popup surface
// anchored to another Item (Quickshell uses this for menus/tooltips). Not
// exercised by RadioAtlas or the demo plugin; kept minimal.
Window {
    id: root

    property Item anchorItem: null
    property var exclusionMode: null

    property real implicitWidth: -1
    property real implicitHeight: -1
    onImplicitWidthChanged: if (implicitWidth > 0) width = implicitWidth
    onImplicitHeightChanged: if (implicitHeight > 0) height = implicitHeight

    readonly property bool backingWindowVisible: root.visible
}
