"""Shim for `Quickshell.Io` (URI "Quickshell.Io", major version 1).

Implements `Process` (backed by QProcess), `StdioCollector`, `SplitParser`
and `FileView` (backed by plain file I/O + QFileSystemWatcher) with the
subset of Quickshell's semantics exercised by Omarchy plugins: setting
`running` starts/stops a Process, `exec()` replaces the command and
restarts it, StdioCollector accumulates a stream until the process exits,
and FileView auto-(re)loads on path change unless `preload` is false.

Not implemented: `DataStream`, `SocketServer`, `Socket` -- no Omarchy
plugin surveyed for this host used them, and they would need a real IPC
transport to mean anything on macOS.
"""

import os
import subprocess
import sys
import tempfile
import weakref

from PySide6.QtCore import (
    Property,
    QByteArray,
    QFileSystemWatcher,
    QObject,
    QProcess,
    QProcessEnvironment,
    QTimer,
    Signal,
    Slot,
)
from PySide6.QtQml import QmlElement

from ._jsvalue import to_python, to_str_list

QML_IMPORT_NAME = "Quickshell.Io"
QML_IMPORT_MAJOR_VERSION = 1


# macOS/PySide6 event-delivery gotcha: a QObject the QML engine instantiates
# (like a plugin's `Process { }`) does not get its QProcess exit notifier --
# or any child QTimer -- serviced while the app is idle, so finished() can
# never fire and `running` would stay true forever after a command exits.
# (A QML `Timer` element, handled entirely in C++, does keep firing.) The
# host therefore injects a QML Timer that calls poll_processes() on the tick,
# which reaps exits for every live Process as a backstop. See host.py.
_live_processes = weakref.WeakSet()


def poll_processes():
    for proc in list(_live_processes):
        try:
            proc._poll_exit()
        except RuntimeError:
            # The underlying C++ object was already destroyed; drop it.
            pass


def _pid_alive(pid):
    """True only if pid is a live, non-zombie process. A child the Qt reaper
    has not yet collected shows as a zombie ('Z'); treat that as gone."""
    if not pid:
        return False
    try:
        out = subprocess.run(
            ["ps", "-o", "state=", "-p", str(pid)],
            capture_output=True, text=True,
        ).stdout.strip()
    except Exception:
        return True
    if not out:
        return False
    return not out.startswith("Z")


@QmlElement
class StdioCollector(QObject):
    """Accumulates one stdio stream of a Process until it exits."""

    streamFinished = Signal()
    textChanged = Signal()
    dataChanged = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._buffer = bytearray()
        self._wait_for_end = True

    # -- called by Process, not exposed to QML --
    def _reset(self):
        self._buffer = bytearray()

    def _feed(self, chunk: bytes):
        self._buffer.extend(chunk)

    def _finish(self):
        self.textChanged.emit()
        self.dataChanged.emit()
        self.streamFinished.emit()

    def _get_wait_for_end(self):
        return self._wait_for_end

    def _set_wait_for_end(self, value):
        self._wait_for_end = bool(value)

    waitForEnd = Property(bool, _get_wait_for_end, _set_wait_for_end)

    def _get_text(self):
        return bytes(self._buffer).decode("utf-8", "replace")

    text = Property(str, _get_text, notify=textChanged)

    def _get_data(self):
        return QByteArray(bytes(self._buffer))

    data = Property("QByteArray", _get_data, notify=dataChanged)


@QmlElement
class SplitParser(QObject):
    """Splits an incoming stdio stream on `splitMarker`, emitting `read`
    once per chunk as data arrives (plus whatever partial chunk remains
    when the process exits)."""

    read = Signal(str, arguments=["data"])

    def __init__(self, parent=None):
        super().__init__(parent)
        self._marker = "\n"
        self._buffer = ""

    def _reset(self):
        self._buffer = ""

    def _get_marker(self):
        return self._marker

    def _set_marker(self, value):
        self._marker = value if value else "\n"

    splitMarker = Property(str, _get_marker, _set_marker)

    def _feed(self, chunk: bytes):
        self._buffer += chunk.decode("utf-8", "replace")
        while self._marker in self._buffer:
            line, self._buffer = self._buffer.split(self._marker, 1)
            self.read.emit(line)

    def _finish(self):
        if self._buffer:
            self.read.emit(self._buffer)
            self._buffer = ""


@QmlElement
class Process(QObject):
    """QProcess-backed shim for Quickshell.Io.Process."""

    started = Signal()
    exited = Signal(int, int, arguments=["exitCode", "exitStatus"])
    runningChanged = Signal()
    commandChanged = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._command = []
        self._environment = []
        self._clear_environment = False
        self._working_directory = ""
        self._stdin_enabled = False
        self._stdout = None
        self._stderr = None
        self._running = False
        self._finalized = True

        self._proc = QProcess(self)
        self._proc.readyReadStandardOutput.connect(self._on_ready_stdout)
        self._proc.readyReadStandardError.connect(self._on_ready_stderr)
        self._proc.started.connect(self.started)
        self._proc.finished.connect(self._on_finished)

        _live_processes.add(self)

    # -- command --
    def _get_command(self):
        return list(self._command)

    def _set_command(self, value):
        self._command = to_str_list(value)
        self.commandChanged.emit()

    command = Property("QVariant", _get_command, _set_command, notify=commandChanged)

    # -- running --
    def _get_running(self):
        return self._running

    def _set_running(self, value):
        value = bool(value)
        if value == self._running:
            return
        if value:
            self._start()
        else:
            self._stop()

    running = Property(bool, _get_running, _set_running, notify=runningChanged)

    def _set_running_state(self, value):
        if self._running != value:
            self._running = value
            self.runningChanged.emit()

    def _start(self):
        if not self._command:
            return
        if self._stdout is not None and hasattr(self._stdout, "_reset"):
            self._stdout._reset()
        if self._stderr is not None and hasattr(self._stderr, "_reset"):
            self._stderr._reset()

        if self._clear_environment:
            env = QProcessEnvironment()
        else:
            env = QProcessEnvironment.systemEnvironment()
        for kv in self._environment:
            if "=" in kv:
                key, value = kv.split("=", 1)
                env.insert(key, value)
        self._proc.setProcessEnvironment(env)
        self._proc.setWorkingDirectory(self._working_directory or os.getcwd())

        program, *args = self._command
        self._finalized = False
        self._proc.start(program, args)
        self._set_running_state(True)

    def _stop(self):
        if self._proc.state() != QProcess.NotRunning:
            self._proc.terminate()
            if not self._proc.waitForFinished(200):
                self._proc.kill()
                self._proc.waitForFinished(200)
        self._finalized = True
        self._set_running_state(False)

    def _on_ready_stdout(self):
        chunk = bytes(self._proc.readAllStandardOutput())
        if chunk and self._stdout is not None and hasattr(self._stdout, "_feed"):
            self._stdout._feed(chunk)

    def _on_ready_stderr(self):
        chunk = bytes(self._proc.readAllStandardError())
        if chunk and self._stderr is not None and hasattr(self._stderr, "_feed"):
            self._stderr._feed(chunk)

    def _on_finished(self, exit_code, exit_status):
        self._finalize(exit_code, exit_status)

    def _poll_exit(self):
        """Called from the host's QML-driven timer. Detect a command that has
        exited even though QProcess never delivered finished() here."""
        if self._finalized:
            return
        # waitForFinished(0) makes Qt block-check the child directly rather
        # than via the un-serviced notifier; it emits finished -> _finalize
        # if the process has exited.
        if self._proc.waitForFinished(0):
            return
        # Still not seen (a detached grandchild holds the output pipe open):
        # ask the OS whether our direct child is gone or a zombie, and if so
        # finalize off the current exit code.
        if not _pid_alive(self._proc.processId()):
            self._finalize(self._proc.exitCode(), self._proc.exitStatus())

    def _finalize(self, exit_code, exit_status):
        if self._finalized:
            return
        self._finalized = True
        self._on_ready_stdout()
        self._on_ready_stderr()
        if self._stdout is not None and hasattr(self._stdout, "_finish"):
            self._stdout._finish()
        if self._stderr is not None and hasattr(self._stderr, "_finish"):
            self._stderr._finish()
        self._set_running_state(False)
        # PySide6 hands back real enum members (QProcess.ExitStatus), not
        # plain ints; unwrap before emitting our plain-int signal.
        status_value = getattr(exit_status, "value", exit_status)
        self.exited.emit(int(exit_code), int(status_value))

    # -- misc properties --
    def _get_stdout(self):
        return self._stdout

    def _set_stdout(self, value):
        self._stdout = value
        if value is not None and value.parent() is None:
            value.setParent(self)

    stdout = Property(QObject, _get_stdout, _set_stdout)

    def _get_stderr(self):
        return self._stderr

    def _set_stderr(self, value):
        self._stderr = value
        if value is not None and value.parent() is None:
            value.setParent(self)

    stderr = Property(QObject, _get_stderr, _set_stderr)

    def _get_environment(self):
        return list(self._environment)

    def _set_environment(self, value):
        self._environment = to_str_list(value)

    environment = Property("QVariant", _get_environment, _set_environment)

    def _get_clear_environment(self):
        return self._clear_environment

    def _set_clear_environment(self, value):
        self._clear_environment = bool(value)

    clearEnvironment = Property(bool, _get_clear_environment, _set_clear_environment)

    def _get_working_directory(self):
        return self._working_directory

    def _set_working_directory(self, value):
        self._working_directory = value or ""

    workingDirectory = Property(str, _get_working_directory, _set_working_directory)

    def _get_stdin_enabled(self):
        return self._stdin_enabled

    def _set_stdin_enabled(self, value):
        self._stdin_enabled = bool(value)

    stdinEnabled = Property(bool, _get_stdin_enabled, _set_stdin_enabled)

    @Property(int)
    def processId(self):
        return int(self._proc.processId())

    @Slot(int)
    def signal(self, sig):
        pid = self._proc.processId()
        if pid:
            try:
                os.kill(int(pid), sig)
            except OSError:
                pass

    @Slot(str)
    def write(self, text):
        if self._proc.state() == QProcess.Running:
            self._proc.write(text.encode("utf-8"))

    @Slot("QVariant")
    def exec(self, command):
        self._set_command(command)
        if self._running:
            self._stop()
        self._start()

    @Slot()
    def startDetached(self):
        if not self._command:
            return
        program, *args = self._command
        QProcess.startDetached(program, args, self._working_directory or os.getcwd())


@QmlElement
class FileView(QObject):
    """Plain-file-backed shim for Quickshell.Io.FileView.

    Initial auto-load (when `preload` is true, the default) is deferred one
    event-loop tick past construction via QTimer.singleShot(0, ...) rather
    than triggered from the `path` property setter directly. Plugins set
    `preload: false` *after* `path` in object-literal order (Radio Atlas's
    playSelectionFile/favoriteSelectionFile do exactly this); reacting to
    `path` synchronously would run a doomed reload before `preload: false`
    had been applied. Deferring by one tick means every property from the
    object literal is already set by the time the initial-load decision is
    made, regardless of the order they were written in -- QQmlParserStatus's
    componentComplete() would be the "proper" fix but is not reliably
    reachable from a plain Python QmlElement in PySide6.
    """

    loaded = Signal()
    loadFailed = Signal(str, arguments=["error"])
    saved = Signal()
    saveFailed = Signal(str, arguments=["error"])
    fileChanged = Signal()
    pathChanged = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._path = ""
        self._watch_changes = False
        self._atomic_writes = False
        self._preload = True
        self._print_errors = True
        self._block_writes = False
        self._block_loading = False
        self._adapter = None
        self._text = ""
        self._data = b""
        self._did_initial_load = False

        self._watcher = QFileSystemWatcher(self)
        self._watcher.fileChanged.connect(self._on_fs_changed)

        QTimer.singleShot(0, self._initial_load)

    def _initial_load(self):
        self._did_initial_load = True
        if self._preload and self._path:
            self.reload()

    # -- path --
    def _get_path(self):
        return self._path

    def _set_path(self, value):
        value = value or ""
        if value == self._path:
            return
        if self._watcher.files():
            self._watcher.removePaths(self._watcher.files())
        self._path = value
        if self._watch_changes and self._path:
            self._watcher.addPath(self._path)
        self.pathChanged.emit()
        if self._did_initial_load and self._preload and self._path:
            self.reload()

    path = Property(str, _get_path, _set_path, notify=pathChanged)

    def _get_watch_changes(self):
        return self._watch_changes

    def _set_watch_changes(self, value):
        self._watch_changes = bool(value)
        if self._watcher.files():
            self._watcher.removePaths(self._watcher.files())
        if self._watch_changes and self._path:
            self._watcher.addPath(self._path)

    watchChanges = Property(bool, _get_watch_changes, _set_watch_changes)

    def _get_atomic_writes(self):
        return self._atomic_writes

    def _set_atomic_writes(self, value):
        self._atomic_writes = bool(value)

    atomicWrites = Property(bool, _get_atomic_writes, _set_atomic_writes)

    def _get_preload(self):
        return self._preload

    def _set_preload(self, value):
        self._preload = bool(value)

    preload = Property(bool, _get_preload, _set_preload)

    def _get_print_errors(self):
        return self._print_errors

    def _set_print_errors(self, value):
        self._print_errors = bool(value)

    printErrors = Property(bool, _get_print_errors, _set_print_errors)

    def _get_block_writes(self):
        return self._block_writes

    def _set_block_writes(self, value):
        self._block_writes = bool(value)

    blockWrites = Property(bool, _get_block_writes, _set_block_writes)

    def _get_block_loading(self):
        return self._block_loading

    def _set_block_loading(self, value):
        self._block_loading = bool(value)

    blockLoading = Property(bool, _get_block_loading, _set_block_loading)

    def _get_adapter(self):
        return self._adapter

    def _set_adapter(self, value):
        self._adapter = to_python(value)

    adapter = Property("QVariant", _get_adapter, _set_adapter)

    # -- content access (called by plugin QML) --
    @Slot(result=str)
    def text(self):
        return self._text

    @Slot(result="QByteArray")
    def data(self):
        return QByteArray(self._data)

    @Slot(str)
    def setText(self, value):
        self._text = value if value is not None else ""
        self._data = self._text.encode("utf-8")
        self._write_to_disk(self._data)

    @Slot("QByteArray")
    def setData(self, value):
        self._data = bytes(value)
        self._text = self._data.decode("utf-8", "replace")
        self._write_to_disk(self._data)

    @Slot()
    def reload(self):
        if not self._path:
            return
        try:
            with open(self._path, "rb") as handle:
                raw = handle.read()
        except OSError as exc:
            if self._print_errors:
                print(f"FileView: failed to load {self._path}: {exc}", file=sys.stderr)
            self.loadFailed.emit(str(exc))
            return
        self._data = raw
        self._text = raw.decode("utf-8", "replace")
        self.loaded.emit()

    def _write_to_disk(self, raw: bytes):
        if not self._path:
            self.saveFailed.emit("no path set")
            return
        try:
            directory = os.path.dirname(self._path) or "."
            os.makedirs(directory, exist_ok=True)
            if self._atomic_writes:
                fd, tmp_path = tempfile.mkstemp(dir=directory)
                try:
                    with os.fdopen(fd, "wb") as handle:
                        handle.write(raw)
                    os.replace(tmp_path, self._path)
                except Exception:
                    if os.path.exists(tmp_path):
                        os.unlink(tmp_path)
                    raise
            else:
                with open(self._path, "wb") as handle:
                    handle.write(raw)
        except OSError as exc:
            if self._print_errors:
                print(f"FileView: failed to save {self._path}: {exc}", file=sys.stderr)
            self.saveFailed.emit(str(exc))
            return
        if self._watch_changes and self._path not in self._watcher.files():
            self._watcher.addPath(self._path)
        self.saved.emit()

    def _on_fs_changed(self, changed_path):
        self.fileChanged.emit()
        # Some writers (atomic renames included) drop the path from the
        # watcher; re-arm it so subsequent external edits keep firing.
        if self._path and self._path not in self._watcher.files() and os.path.exists(self._path):
            self._watcher.addPath(self._path)
