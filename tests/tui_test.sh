#!/usr/bin/env bash
#
# tui_test.sh -- end-to-end test of the `tui` plugin kind (bin/gallery-tui
# plus bin/gallery's route_open_close_toggle) against the real
# gallery.sysmon demo plugin (kinds: ["tui"], gallery.tui.command:
# /opt/homebrew/bin/btop).
#
# Unlike the *_test.lua files (which run inside a headless or live
# Hammerspoon Lua environment via `hs`), a tui-kind plugin is deliberately
# NOT routed through Hammerspoon at all -- gallery open/close/toggle
# resolve it locally to gallery-tui, which spawns a real window of the configured terminal (iTerm2, Ghostty, kitty or WezTerm),
# titled "Gallery: <manifest.name>", that yabai floats and centres (rule
# label gallery-tui, grid 6:6:1:1:4:4). This script therefore drives the
# INSTALLED CLI (~/bin/gallery, ~/bin/gallery-tui) exactly as a user would,
# and asserts on real yabai window state -- it opens and closes a real
# window on screen; that is expected.
#
# Never wraps `gallery`/`gallery-tui` in coreutils `timeout` when a
# Hammerspoon IPC round-trip might be in flight (see bin/gallery and
# tests/run.sh) -- but the tui/menu path in this script never reaches
# Hammerspoon, so a plain `timeout` guard is fine here as a last-resort
# safety net against a truly wedged osascript/yabai call.
#
set -euo pipefail

PLUGIN_ID="gallery.sysmon"
PLUGIN_NAME="System Monitor"
TITLE="Gallery: ${PLUGIN_NAME}"
GALLERY_BIN="${HOME}/bin/gallery"
GALLERY_TUI_BIN="${HOME}/bin/gallery-tui"
# The app name yabai reports for the configured terminal (iTerm2, Ghostty,
# kitty, WezTerm -- see `gallery terminal`); the window checks below filter on it.
TUI_APP="$("${HOME}/bin/gallery-term" app 2>/dev/null || echo iTerm2)"
export TUI_APP
PY="/usr/bin/python3"
CMD_TIMEOUT=20

say() {
  echo "[tui_test] $*"
}

fail() {
  # dump_windows runs once, from the cleanup EXIT trap below, on any
  # non-zero exit -- not here too, to avoid printing the window list twice.
  echo "[tui_test] FAIL: $*" >&2
  exit 1
}

# dump_windows -- prints the current yabai window list on failure, so a CI
# log has something to diagnose from without re-running interactively.
dump_windows() {
  echo "[tui_test] yabai -m query --windows (${TUI_APP} only):" >&2
  yabai -m query --windows 2>/dev/null \
    | "${PY}" -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception as e:
    print("  <could not parse yabai output: %s>" % e)
    sys.exit(0)
for w in data:
    if w.get("app") == __import__("os").environ["TUI_APP"]:
        print("  id=%s title=%r floating=%s visible=%s frame=%s" % (
            w.get("id"), w.get("title"), w.get("is-floating"),
            w.get("is-visible"), w.get("frame")))
' 2>&1 | sed 's/^/[tui_test]   /' >&2 || true
}

# window_count -- number of terminal windows with our exact title.
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
print(sum(1 for w in data if w.get("app") == __import__("os").environ["TUI_APP"] and w.get("title") == title))
' "${TITLE}"
}

# window_fields -- tab-separated is-floating, is-visible, x, y, w, h for the
# (first) matching window, or nothing (empty output) if none is open.
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
matches = [w for w in data if w.get("app") == __import__("os").environ["TUI_APP"] and w.get("title") == title]
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
# reports it floating and visible. Float/grid application (either the
# gallery-tui rule or its own belt-and-suspenders float_me) lands a beat
# after the window itself appears, so this is polled rather than checked
# once right after is_open.
is_floating_visible() {
  local fields
  fields="$(window_fields)"
  [ -n "${fields}" ] || return 1
  case "${fields}" in
    "True"$'\t'"True"$'\t'*) return 0 ;;
    *) return 1 ;;
  esac
}

btop_gone() {
  ! pgrep -x btop >/dev/null 2>&1
}

# --- cleanup trap: close the window and kill any stray btop on any exit ---
cleanup() {
  local rc=$?
  if [ "${rc}" -ne 0 ]; then
    say "cleanup after failure: closing ${PLUGIN_ID} and killing stray btop"
    dump_windows
  fi
  timeout "${CMD_TIMEOUT}" "${GALLERY_BIN}" close "${PLUGIN_ID}" >/dev/null 2>&1 || true
  pkill -x btop >/dev/null 2>&1 || true
  exit "${rc}"
}
trap cleanup EXIT

# --- preconditions / SKIP gate -------------------------------------------

if ! command -v btop >/dev/null 2>&1; then
  say "SKIP: btop not found on PATH"
  trap - EXIT
  exit 0
fi
if ! command -v yabai >/dev/null 2>&1; then
  say "SKIP: yabai not found on PATH"
  trap - EXIT
  exit 0
fi
if ! osascript -e "exists application \"${TUI_APP}\"" >/dev/null 2>&1; then
  say "SKIP: ${TUI_APP} not installed"
  trap - EXIT
  exit 0
fi
YABAI_PROBE="$(yabai -m query --windows 2>/dev/null || true)"
if [ "${#YABAI_PROBE}" -lt 2 ]; then
  say "SKIP: yabai -m query --windows returned no usable data (yabai not fully running?)"
  trap - EXIT
  exit 0
fi
[ -x "${GALLERY_BIN}" ] || fail "${GALLERY_BIN} not found or not executable"
[ -x "${GALLERY_TUI_BIN}" ] || fail "${GALLERY_TUI_BIN} not found or not executable"
command -v "${PY}" >/dev/null 2>&1 || fail "${PY} not found"

# --- 1. precondition: no window titled \"${TITLE}\" is already open -------

if [ "$(window_count)" -ge 1 ]; then
  say "a window titled '${TITLE}' is already open -- closing it first"
  timeout "${CMD_TIMEOUT}" "${GALLERY_BIN}" close "${PLUGIN_ID}" >/dev/null 2>&1 || true
  wait_until "precondition close" 8 is_closed \
    || fail "a pre-existing '${TITLE}' window did not close within 8s"
fi
say "precondition OK: no '${TITLE}' window open"

# --- 2. open --------------------------------------------------------------

say "opening ${PLUGIN_ID}"
open_out="$(timeout "${CMD_TIMEOUT}" "${GALLERY_BIN}" open "${PLUGIN_ID}")"
say "gallery open output: ${open_out}"
[ "${open_out}" = "opened ${PLUGIN_ID}" ] || fail "expected 'opened ${PLUGIN_ID}', got: ${open_out}"

wait_until "window appears" 8 is_open \
  || fail "no window titled '${TITLE}' appeared within 8s"
say "window appeared"

# Float/grid application lands a beat after the window itself appears
# (gallery-tui's own float_me has up to ~4s of internal polling before it
# even starts) -- give the SAME 8s budget for is-floating/is-visible to
# settle, rather than sampling once immediately.
wait_until "window becomes floating and visible" 8 is_floating_visible \
  || fail "window titled '${TITLE}' did not become floating+visible within 8s (last fields: $(window_fields))"

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

say "opening ${PLUGIN_ID} again (should just focus the existing window)"
open_out2="$(timeout "${CMD_TIMEOUT}" "${GALLERY_BIN}" open "${PLUGIN_ID}")"
say "gallery open output: ${open_out2}"
[ "${open_out2}" = "opened ${PLUGIN_ID}" ] || fail "expected 'opened ${PLUGIN_ID}' on re-open, got: ${open_out2}"
sleep 1
count="$(window_count)"
[ "${count}" -eq 1 ] || fail "expected exactly 1 window titled '${TITLE}' after re-open, found ${count}"
say "still exactly one window"

# --- 4. gallery-tui status -------------------------------------------------

status_out="$(timeout "${CMD_TIMEOUT}" "${GALLERY_TUI_BIN}" status "${PLUGIN_NAME}")"
status_rc=$?
say "gallery-tui status output: ${status_out} (exit ${status_rc})"
[ "${status_out}" = "open" ] || fail "expected gallery-tui status to print 'open', got: ${status_out}"
[ "${status_rc}" -eq 0 ] || fail "expected gallery-tui status to exit 0 while open, got ${status_rc}"

# --- 5. close ---------------------------------------------------------------

say "closing ${PLUGIN_ID}"
close_out="$(timeout "${CMD_TIMEOUT}" "${GALLERY_BIN}" close "${PLUGIN_ID}")"
say "gallery close output: ${close_out}"
[ "${close_out}" = "closed ${PLUGIN_ID}" ] || fail "expected 'closed ${PLUGIN_ID}', got: ${close_out}"

wait_until "window disappears" 8 is_closed \
  || fail "window titled '${TITLE}' did not disappear within 8s of close"
say "window closed"

wait_until "btop process exits" 5 btop_gone \
  || fail "btop process is still running 5s after close"
say "btop process exited"

# --- 6. toggle open, toggle close ------------------------------------------

say "toggling ${PLUGIN_ID} (expect open)"
toggle_out1="$(timeout "${CMD_TIMEOUT}" "${GALLERY_BIN}" toggle "${PLUGIN_ID}")"
say "gallery toggle output: ${toggle_out1}"
[ "${toggle_out1}" = "opened ${PLUGIN_ID}" ] || fail "expected 'opened ${PLUGIN_ID}' from toggle, got: ${toggle_out1}"
wait_until "toggle-open window appears" 8 is_open \
  || fail "no window titled '${TITLE}' appeared within 8s of toggle-open"
wait_until "toggle-open window becomes floating and visible" 8 is_floating_visible \
  || fail "toggle-open: window did not become floating+visible within 8s (last fields: $(window_fields))"
say "toggle-open OK"

say "toggling ${PLUGIN_ID} (expect close)"
toggle_out2="$(timeout "${CMD_TIMEOUT}" "${GALLERY_BIN}" toggle "${PLUGIN_ID}")"
say "gallery toggle output: ${toggle_out2}"
[ "${toggle_out2}" = "closed ${PLUGIN_ID}" ] || fail "expected 'closed ${PLUGIN_ID}' from toggle, got: ${toggle_out2}"
wait_until "toggle-close window disappears" 8 is_closed \
  || fail "window titled '${TITLE}' did not disappear within 8s of toggle-close"
wait_until "btop process exits after toggle-close" 5 btop_gone \
  || fail "btop process is still running 5s after toggle-close"
say "toggle-close OK"

# --- 7. kind refusal: an explicit kind the manifest does not declare -------
#
# gallery.sysmon's manifest only declares kinds: ["tui"]. Asking for
# "panel" explicitly resolves (via bin/gallery's PY_RESOLVE_KIND, which
# always honours an explicit kind argument) to something route_open_close_
# toggle does not recognise as tui/menu, so it falls back to the original
# Hammerspoon IPC passthrough (run_ipc) -- which the live Gallery Spoon
# itself refuses, printing "kind 'panel' not declared: <id>" and (per
# observed behaviour) exiting 0, since gallery just echoes the IPC reply
# verbatim without inspecting its content. Assert on either: a non-zero
# exit, or that "not declared" appears in the output.
say "asking for a kind gallery.sysmon does not declare (panel)"
set +e
refusal_out="$(timeout "${CMD_TIMEOUT}" "${GALLERY_BIN}" open "${PLUGIN_ID}" panel 2>&1)"
refusal_rc=$?
set -e
say "gallery open ${PLUGIN_ID} panel -> exit ${refusal_rc}: ${refusal_out}"
if [ "${refusal_rc}" -eq 0 ] && ! printf '%s' "${refusal_out}" | grep -qi "not declared"; then
  fail "expected a non-zero exit or a 'not declared' message, got exit ${refusal_rc} and: ${refusal_out}"
fi
say "kind refusal OK"
# Make sure that refusal did not leave a window open behind it.
[ "$(window_count)" -eq 0 ] || fail "kind-refusal call unexpectedly left a '${TITLE}' window open"

say "PASS tui_test.sh"
