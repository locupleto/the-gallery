import QtQuick

// Shim for Quickshell.ShellRoot: a non-visual container for a shell's
// top-level objects (PanelWindows, Scopes, Loaders...). Plain Item already
// accepts non-visual QObject children through its default `data` property,
// which is all a plugin root ever needs from ShellRoot here.
Item {}
