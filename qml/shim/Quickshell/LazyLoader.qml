import QtQuick

// Shim for Quickshell.LazyLoader: Loader already provides `active` and
// `item`; only `component` (Quickshell's name for sourceComponent) and
// `loading` need adding.
Loader {
    id: root

    property Component component
    readonly property bool loading: status === Loader.Loading

    sourceComponent: active ? component : null
}
