import QtQuick

// Shim for Quickshell.Widgets.WrapperItem: sizes itself to its content plus
// a margin. Best-effort -- not exercised by RadioAtlas or the demo plugin.
Item {
    id: root

    default property alias data: content.data
    property int margin: 0

    implicitWidth: content.childrenRect.width + margin * 2
    implicitHeight: content.childrenRect.height + margin * 2

    Item {
        id: content
        anchors.centerIn: parent
    }
}
