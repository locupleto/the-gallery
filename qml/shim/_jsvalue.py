"""Shared helper: QML array/object literals bound to a Python `Property`
setter or `Slot` argument typed "QVariant" arrive as a `QJSValue`, not an
already-unwrapped Python list/dict/str -- unlike a plain `list`/`dict`
typed Slot argument, which PySide6 does convert automatically. Every shim
type that accepts a QML array (Process.command, Process.environment,
Quickshell.execDetached, Process.exec) needs this unwrap first.
"""

from PySide6.QtQml import QJSValue


def to_python(value):
    if isinstance(value, QJSValue):
        return value.toVariant()
    return value


def to_str_list(value):
    value = to_python(value)
    if not value:
        return []
    try:
        return [str(part) for part in value]
    except TypeError:
        return []
