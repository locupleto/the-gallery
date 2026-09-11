import QtQuick

// Shim for Quickshell.Widgets.MarginWrapperManager: a plain data holder for
// the four edge margins some wrapper delegates read. Best-effort -- not
// exercised by RadioAtlas or the demo plugin.
QtObject {
    property int marginTop: 0
    property int marginBottom: 0
    property int marginLeft: 0
    property int marginRight: 0
}
