import QtQuick
import QtQuick.Window

// Shim for Quickshell.FloatingWindow: an ordinary top-level window. Real
// Quickshell floats it above the compositor's tiling; on macOS it is just a
// normal Window that host.py can show, center and title like any other.
Window {
    id: root

    property size minimumSize: Qt.size(0, 0)
    onMinimumSizeChanged: {
        minimumWidth = minimumSize.width
        minimumHeight = minimumSize.height
    }

    // Window has no implicitWidth/Height of its own (that is an Item
    // concept); plugins size their FloatingWindow the same way they would
    // size an Item, so provide it and apply it to the real width/height
    // once, on change -- not a permanent binding, so a later user resize
    // (or the plugin's own width/height writes) is not fought.
    property real implicitWidth: -1
    property real implicitHeight: -1
    onImplicitWidthChanged: if (implicitWidth > 0) width = implicitWidth
    onImplicitHeightChanged: if (implicitHeight > 0) height = implicitHeight

    // Quickshell distinguishes the "requested" visible state from the
    // compositor's confirmation that the backing surface actually mapped
    // (there can be a frame or two of lag). There is no such gap for a
    // plain QWindow, so mirror it directly.
    readonly property bool backingWindowVisible: root.visible

    // Layer-shell-ish property some plugins set defensively even on a
    // FloatingWindow; accepted and ignored.
    property var exclusionMode: null
}
