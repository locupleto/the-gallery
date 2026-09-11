import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Trimmed-down stand-in for the real basecamp/omarchy-basecamp-plugin
// Panel.qml -- just enough to exercise tools/import-omarchy-plugin's
// import-statement scan (qs.Commons/qs.Ui are Omarchy's private QML
// component library, which has no macOS renderer).
Item {
  id: root
  width: 240
  height: 32

  Text {
    anchors.centerIn: parent
    text: "Basecamp"
    color: Color.foreground
  }
}
