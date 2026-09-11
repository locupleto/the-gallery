import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Trimmed-down stand-in for the real basecamp/omarchy-basecamp-plugin
// Service.qml, kept just realistic enough to exercise
// tools/import-omarchy-plugin's Process-block scanner:
//   - a fully literal command array (basecamp CLI, not installed here)
//   - a command array with one dynamic (non-literal) element (flock,
//     which *is* installed here via Homebrew)
Item {
  id: root

  property string lockPath: "/tmp/gallery-basecamp-fixture.lock"
  property var notifications: []

  function refresh() {
    if (notificationsProcess.running) return
    notificationsProcess.running = true
  }

  Process {
    id: notificationsProcess
    running: false
    command: ["basecamp", "notifications", "list", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.notifications = Model.parseNotifications(text)
    }
  }

  // setupLockPath is a QML property reference, not a string literal, so
  // this element must be reported as <dynamic> even though the command
  // itself (flock) is fully classifiable.
  Process {
    id: setupLockProcess
    running: false
    command: ["flock", "-n", lockPath, "true"]
    onExited: function (exitCode) {
      root.notifications = []
    }
  }
}
