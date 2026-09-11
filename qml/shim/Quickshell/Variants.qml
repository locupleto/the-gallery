import QtQml

// Shim for Quickshell.Variants: instantiate one delegate per model entry,
// where the delegate is often a non-Item object (a PanelWindow, say) that a
// plain Repeater could not parent. QtQml's Instantiator already does
// exactly this and already exposes `model`/`delegate`/`active`/`count`/
// `object` plus `objectAdded`/`objectRemoved`, so there is nothing to add.
Instantiator {}
