import QtQuick

// Shim for Quickshell.Widgets.IconImage: Quickshell.iconPath() never
// resolves anything meaningful on macOS (see quickshell_core.py), so this
// is a plain Image that a plugin can still point `source` at directly.
Image {
    property string iconName: ""
    fillMode: Image.PreserveAspectFit
}
