import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Acceptance test for the gallery-qml Quickshell shim: exercises qs.Ui
// controls backed by qs.Commons (Style/Color), a Quickshell.Io.Process,
// and a Quickshell.Io.FileView round-trip, all under an unmodified
// Omarchy-style plugin entry point.
Item {
    id: root

    readonly property int preferredWidth: 520
    readonly property int preferredHeight: 420

    focus: true
    Keys.onEscapePressed: Qt.quit()

    property int clickCount: 0
    property string dateOutput: "(not run yet)"
    property string fileRoundTrip: "(not written yet)"

    Rectangle {
        anchors.fill: parent
        color: Color.menu.background
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.space(24)
        spacing: Style.spacing.lg

        Text {
            text: "Gallery QML Demo"
            color: Color.menu.text
            font.family: Style.font.family
            font.pixelSize: Style.font.heading
            font.bold: true
        }

        Text {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: "qs.Ui Button + PanelSlider + TextField + Toggle, a live "
                + "Quickshell.Io.Process, and a Quickshell.Io.FileView round-trip."
            color: Color.menu.text
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
        }

        RowLayout {
            spacing: Style.spacing.md

            Button {
                text: "Click me"
                bordered: true
                onClicked: root.clickCount += 1
            }

            Button {
                text: "Run /bin/date"
                bordered: true
                onClicked: dateProcess.running = true
            }

            Toggle {
                id: toggle
                checked: false
            }
        }

        Text {
            text: "Clicked " + root.clickCount + " time(s); toggle is "
                + (toggle.checked ? "on" : "off")
            color: Color.menu.text
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
        }

        PanelSlider {
            id: slider
            Layout.fillWidth: true
            minimum: 0
            maximum: 100
            value: 40
        }

        Text {
            text: "Slider value: " + Math.round(slider.value)
            color: Color.menu.text
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
        }

        TextField {
            id: textField
            Layout.fillWidth: true
            placeholderText: "type here, then click \"Save to file\""
        }

        Text {
            text: "Process (\"/bin/date\") stdout: " + root.dateOutput
            color: Color.menu.text
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        RowLayout {
            spacing: Style.spacing.md

            Button {
                text: "Save to file"
                bordered: true
                onClicked: fileView.setText(textField.text)
            }

            Button {
                text: "Reload from file"
                bordered: true
                onClicked: fileView.reload()
            }
        }

        Text {
            text: "FileView round-trip: " + root.fileRoundTrip
            color: Color.menu.text
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        Item { Layout.fillHeight: true }
    }

    Process {
        id: dateProcess
        command: ["/bin/date"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.dateOutput = text.trim()
        }
        onExited: function(exitCode, exitStatus) {
            if (exitCode !== 0) root.dateOutput = "process failed (exit " + exitCode + ")"
        }
    }

    FileView {
        id: fileView
        readonly property string tmpDir: Quickshell.env("TMPDIR") || "/tmp/"
        path: (tmpDir.endsWith("/") ? tmpDir : tmpDir + "/") + "gallery-qml-demo.txt"
        preload: false
        watchChanges: false
        printErrors: true
        onLoaded: root.fileRoundTrip = text()
        onLoadFailed: function(error) { root.fileRoundTrip = "load failed: " + error }
        onSaved: {
            root.fileRoundTrip = "saved — reloading..."
            fileView.reload()
        }
        onSaveFailed: function(error) { root.fileRoundTrip = "save failed: " + error }
    }

    Component.onCompleted: root.forceActiveFocus()
}
