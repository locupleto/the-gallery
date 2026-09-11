import QtQuick

// Shim for Quickshell.Scope: a non-visual grouping container, used to scope
// ownership of Processes/FileViews/Windows without giving them a visual
// parent. See ShellRoot.qml for why plain Item is enough here.
Item {}
