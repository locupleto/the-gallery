// Injected by host.py: a QML Timer (kept ticking by the QtQuick event
// source even when Python QTimers are starved on macOS) that drives the
// shim's process-exit reaper. See qml/shim/quickshell_io.py poll_processes.
import QtQuick

Timer {
    interval: 150
    running: true
    repeat: true
    onTriggered: if (typeof __galleryProcessPoll !== "undefined") __galleryProcessPoll.poll()
}
