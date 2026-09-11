#!/usr/bin/env bash
#
# qml_test.sh -- end-to-end test of the `qml` plugin kind (bin/gallery's
# route_open_close_toggle/route_qml plus bin/gallery-qml) against the
# gallery.qml-demo fixture plugin.
#
# Like tui_test.sh, a qml-kind plugin is deliberately NOT routed through
# Hammerspoon at all -- gallery open/close/toggle resolve it locally
# (bin/gallery's PY_RESOLVE_KIND detects the plugin's panel entry point
# ends in .qml) and shell out to gallery-qml, which launches the
# Quickshell-for-macOS host in a real window titled "Gallery: <name>" that
# yabai floats and centres (rule label gallery-qml, no grid; the plugin sizes its own window and the host centres it, no
# app filter -- see bin/gallery's ensure_gallery_qml_yabai_rule). Unlike
# the tui path, "is this plugin open" is tracked by a pidfile
# (~/.config/gallery/state/qml/<slug>.pid) that gallery-qml itself writes
# and bin/gallery reads/kills -- there is no iTerm2/gallery-tui process
# name to poll for exit, so this script polls the pidfile's pid instead.
#
# This script drives the INSTALLED CLI (~/bin/gallery, ~/bin/gallery-qml)
# exactly as a user would, and asserts on real yabai window state -- it
# opens and closes a real window on screen; that is expected.
#
# SKIPs (exit 0) rather than failing when the qml host is not present at
# all on this machine: the gallery.qml-demo fixture plugin, gallery-qml
# itself, and the qml-venv are all built/installed by a separate slice of
# work and may not exist yet when this test is run.
#
# Never wraps `gallery`/`gallery-qml` in coreutils `timeout` when a
# Hammerspoon IPC round-trip might be in flight (see bin/gallery and
# tests/run.sh) -- but, like tui_test.sh, the qml path in this script
# never reaches Hammerspoon, so a plain `timeout` guard is fine here as a
# last-resort safety net against a truly wedged osascript/yabai call.
#
set -euo pipefail

PLUGIN_ID="gallery.qml-demo"
PLUGIN_NAME="QML Demo"
TITLE="Gallery: ${PLUGIN_NAME}"
GALLERY_BIN="${HOME}/bin/gallery"
GALLERY_QML_BIN="${HOME}/bin/gallery-qml"
QML_PLUGIN_DIR="${HOME}/.config/gallery/plugins/gallery.qml-demo"
QML_VENV_DIR="${HOME}/.config/gallery/qml-venv"
PIDFILE="${HOME}/.config/gallery/state/qml/qml-demo.pid"
PY="/usr/bin/python3"
CMD_TIMEOUT=20

say() {
  echo "[qml_test] $*"
}

fail() {
  echo "[qml_test] FAIL: $*" >&2
  exit 1
}

# dump_windows -- prints the current yabai window list on failure, so a CI
# log has something to diagnose from without re-running interactively.
dump_windows() {
  echo "[qml_test] yabai -m query --windows:" >&2
  yabai -m query --windows 2>/dev/null \
    | "${PY}" -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception as e:
    print("  <could not parse yabai output: %s>" % e)
    sys.exit(0)
for w in data:
    print("  id=%s app=%r title=%r floating=%s visible=%s frame=%s" % (
        w.get("id"), w.get("app"), w.get("title"), w.get("is-floating"),
        w.get("is-visible"), w.get("frame")))
' 2>&1 | sed 's/^/[qml_test]   /' >&2 || true
}

# window_count -- number of windows (any app) with our exact title.
window_count() {
  local json
  json="$(yabai -m query --windows 2>/dev/null || true)"
  [ -n "${json}" ] || { echo 0; return; }
  printf '%s' "${json}" | "${PY}" -c '
import json, sys
title = sys.argv[1]
try:
    data = json.loads(sys.stdin.read())
except Exception:
    print(0)
    sys.exit(0)
print(sum(1 for w in data if w.get("title") == title))
' "${TITLE}"
}

# window_fields -- tab-separated is-floating, is-visible, x, y, w, h for
# the (first) matching window, or nothing (empty output) if none is open.
window_fields() {
  local json
  json="$(yabai -m query --windows 2>/dev/null || true)"
  [ -n "${json}" ] || return 0
  printf '%s' "${json}" | "${PY}" -c '
import json, sys
title = sys.argv[1]
try:
    data = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
matches = [w for w in data if w.get("title") == title]
if not matches:
    sys.exit(0)
w = matches[0]
f = w.get("frame") or {}
print("\t".join(str(v) for v in [
    w.get("is-floating"), w.get("is-visible"),
    f.get("x"), f.get("y"), f.get("w"), f.get("h"),
]))
' "${TITLE}"
}

# display_frame -- tab-separated x, y, w, h of the focused display.
display_frame() {
  yabai -m query --displays --display 2>/dev/null | "${PY}" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
f = d.get("frame") or {}
print("\t".join(str(v) for v in [f.get("x"), f.get("y"), f.get("w"), f.get("h")]))
'
}

# wait_until <predicate-description> <max-seconds> <command...> -- polls
# `"$@"` (expected to exit 0 once the condition holds) once per 0.5s.
wait_until() {
  local desc="$1" max_s="$2"
  shift 2
  local waited_ms=0 max_ms=$((max_s * 1000))
  while [ "${waited_ms}" -lt "${max_ms}" ]; do
    if "$@"; then
      return 0
    fi
    sleep 0.5
    waited_ms=$((waited_ms + 500))
  done
  return 1
}

is_open() {
  [ "$(window_count)" -ge 1 ]
}

is_closed() {
  [ "$(window_count)" -eq 0 ]
}

# is_floating_visible -- true once a matching window exists AND yabai
# reports it floating and visible. Float/grid application (the
# gallery-qml yabai rule) lands a beat after the window itself appears, so
# this is polled rather than checked once right after is_open.
is_floating_visible() {
  local fields
  fields="$(window_fields)"
  [ -n "${fields}" ] || return 1
  case "${fields}" in
    "True"$'\t'"True"$'\t'*) return 0 ;;
    *) return 1 ;;
  esac
}

pidfile_pid() {
  [ -f "${PIDFILE}" ] && cat "${PIDFILE}" 2>/dev/null
}

pidfile_pid_alive() {
  local pid
  pid="$(pidfile_pid)"
  [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null
}

pidfile_gone() {
  [ ! -f "${PIDFILE}" ]
}

# --- cleanup trap: close the window on any exit ----------------------------
cleanup() {
  local rc=$?
  if [ "${rc}" -ne 0 ]; then
    say "cleanup after failure: closing ${PLUGIN_ID}"
    dump_windows
  fi
  timeout "${CMD_TIMEOUT}" "${GALLERY_BIN}" close "${PLUGIN_ID}" >/dev/null 2>&1 || true
  exit "${rc}"
}

# --- preconditions / SKIP gate ---------------------------------------------

if [ ! -d "${QML_PLUGIN_DIR}" ]; then
  say "SKIP: ${QML_PLUGIN_DIR} not installed (qml host/demo plugin not built yet)"
  exit 0
fi
if [ ! -x "${GALLERY_QML_BIN}" ]; then
  say "SKIP: ${GALLERY_QML_BIN} not found"
  exit 0
fi
if [ ! -d "${QML_VENV_DIR}" ]; then
  say "SKIP: ${QML_VENV_DIR} not present (first run of a qml plugin creates it)"
  exit 0
fi
if ! command -v yabai >/dev/null 2>&1; then
  say "SKIP: yabai not found on PATH"
  exit 0
fi
YABAI_PROBE="$(yabai -m query --windows 2>/dev/null || true)"
if [ "${#YABAI_PROBE}" -lt 2 ]; then
  say "SKIP: yabai -m query --windows returned no usable data (yabai not fully running?)"
  exit 0
fi
[ -x "${GALLERY_BIN}" ] || fail "${GALLERY_BIN} not found or not executable"
command -v "${PY}" >/dev/null 2>&1 || fail "${PY} not found"

# Everything present -- from here on a real failure is a real failure, so
# install the closing trap only now (a SKIP above must not try to close a
# plugin that was never opened).
trap cleanup EXIT

# --- 1. precondition: no window titled "${TITLE}" is already open, and no
#        stale pidfile from a previous run --------------------------------

if [ "$(window_count)" -ge 1 ]; then
  say "a window titled '${TITLE}' is already open -- closing it first"
  timeout "${CMD_TIMEOUT}" "${GALLERY_BIN}" close "${PLUGIN_ID}" >/dev/null 2>&1 || true
  wait_until "precondition close" 8 is_closed \
    || fail "a pre-existing '${TITLE}' window did not close within 8s"
fi
rm -f "${PIDFILE}" 2>/dev/null || true
say "precondition OK: no '${TITLE}' window open, no pidfile"

# --- 2. open ----------------------------------------------------------------

say "opening ${PLUGIN_ID}"
open_out="$(timeout "${CMD_TIMEOUT}" "${GALLERY_BIN}" open "${PLUGIN_ID}")"
say "gallery open output: ${open_out}"
[ "${open_out}" = "opened ${PLUGIN_ID}" ] || fail "expected 'opened ${PLUGIN_ID}', got: ${open_out}"

wait_until "window appears" 20 is_open \
  || fail "no window titled '${TITLE}' appeared within 20s"
say "window appeared"

wait_until "pidfile appears" 20 test -f "${PIDFILE}" \
  || fail "pidfile ${PIDFILE} was not written within 20s"
say "pidfile exists: $(pidfile_pid)"

wait_until "window becomes floating and visible" 20 is_floating_visible \
  || fail "window titled '${TITLE}' did not become floating+visible within 20s (last fields: $(window_fields))"

fields="$(window_fields)"
[ -n "${fields}" ] || fail "window disappeared before its fields could be read"
IFS=$'\t' read -r is_floating is_visible wx wy ww wh <<<"${fields}"
say "window state: is-floating=${is_floating} is-visible=${is_visible} frame=(${wx},${wy},${ww},${wh})"

dfields="$(display_frame)"
[ -n "${dfields}" ] || fail "could not read the focused display's frame"
IFS=$'\t' read -r dx dy dw dh <<<"${dfields}"
say "display frame: (${dx},${dy},${dw},${dh})"

"${PY}" -c '
import sys
wx, wy, ww, wh, dx, dy, dw, dh = (float(a) for a in sys.argv[1:9])
ok = (wx > dx) and (wy > dy) and (wx + ww < dx + dw) and (wy + wh < dy + dh)
sys.exit(0 if ok else 1)
' "${wx}" "${wy}" "${ww}" "${wh}" "${dx}" "${dy}" "${dw}" "${dh}" \
  || fail "window frame (${wx},${wy},${ww},${wh}) is not roughly centred within display (${dx},${dy},${dw},${dh})"
say "window is floating, visible, and roughly centred"

# --- 3. opening again must not duplicate the window ------------------------

pid_before="$(pidfile_pid)"
say "opening ${PLUGIN_ID} again (should just focus the existing window)"
open_out2="$(timeout "${CMD_TIMEOUT}" "${GALLERY_BIN}" open "${PLUGIN_ID}")"
say "gallery open output: ${open_out2}"
[ "${open_out2}" = "opened ${PLUGIN_ID}" ] || fail "expected 'opened ${PLUGIN_ID}' on re-open, got: ${open_out2}"
sleep 1
count="$(window_count)"
[ "${count}" -eq 1 ] || fail "expected exactly 1 window titled '${TITLE}' after re-open, found ${count}"
pid_after="$(pidfile_pid)"
[ "${pid_before}" = "${pid_after}" ] || fail "re-open spawned a new process (pid ${pid_before} -> ${pid_after})"
say "still exactly one window, same pid (${pid_after})"

# --- 4. close ---------------------------------------------------------------

say "closing ${PLUGIN_ID}"
close_out="$(timeout "${CMD_TIMEOUT}" "${GALLERY_BIN}" close "${PLUGIN_ID}")"
say "gallery close output: ${close_out}"
[ "${close_out}" = "closed ${PLUGIN_ID}" ] || fail "expected 'closed ${PLUGIN_ID}', got: ${close_out}"

wait_until "window disappears" 8 is_closed \
  || fail "window titled '${TITLE}' did not disappear within 8s of close"
say "window closed"

wait_until "pidfile removed" 8 pidfile_gone \
  || fail "pidfile ${PIDFILE} was not removed within 8s of close"
say "pidfile removed"

wait_until "process exits" 5 sh -c "! kill -0 '${pid_after}' 2>/dev/null" \
  || fail "process ${pid_after} is still alive 5s after close"
say "process exited"

# --- 5. close when not open --------------------------------------------------

say "closing ${PLUGIN_ID} again (already closed)"
close_out2="$(timeout "${CMD_TIMEOUT}" "${GALLERY_BIN}" close "${PLUGIN_ID}")"
say "gallery close output: ${close_out2}"
[ "${close_out2}" = "not open: ${PLUGIN_ID}" ] || fail "expected 'not open: ${PLUGIN_ID}', got: ${close_out2}"

# --- 6. toggle open, toggle close --------------------------------------------

say "toggling ${PLUGIN_ID} (expect open)"
toggle_out1="$(timeout "${CMD_TIMEOUT}" "${GALLERY_BIN}" toggle "${PLUGIN_ID}")"
say "gallery toggle output: ${toggle_out1}"
[ "${toggle_out1}" = "opened ${PLUGIN_ID}" ] || fail "expected 'opened ${PLUGIN_ID}' from toggle, got: ${toggle_out1}"
wait_until "toggle-open window appears" 10 is_open \
  || fail "no window titled '${TITLE}' appeared within 20s of toggle-open"
wait_until "toggle-open pidfile appears" 10 test -f "${PIDFILE}" \
  || fail "pidfile ${PIDFILE} was not written within 20s of toggle-open"
wait_until "toggle-open window becomes floating and visible" 10 is_floating_visible \
  || fail "toggle-open: window did not become floating+visible within 20s (last fields: $(window_fields))"
say "toggle-open OK"

say "toggling ${PLUGIN_ID} (expect close)"
toggle_out2="$(timeout "${CMD_TIMEOUT}" "${GALLERY_BIN}" toggle "${PLUGIN_ID}")"
say "gallery toggle output: ${toggle_out2}"
[ "${toggle_out2}" = "closed ${PLUGIN_ID}" ] || fail "expected 'closed ${PLUGIN_ID}' from toggle, got: ${toggle_out2}"
wait_until "toggle-close window disappears" 8 is_closed \
  || fail "window titled '${TITLE}' did not disappear within 8s of toggle-close"
wait_until "toggle-close pidfile removed" 8 pidfile_gone \
  || fail "pidfile ${PIDFILE} was not removed within 8s of toggle-close"
say "toggle-close OK"

say "PASS qml_test.sh"
