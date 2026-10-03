#!/bin/bash
# offon_test.sh -- `gallery off` / `gallery on` in a throwaway HOME, with
# yabai, skhd, launchctl, osascript, pgrep and pkill stubbed so nothing on the
# real desktop is touched. $RUNNING lists the processes pgrep reports.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# `defaults` writes the real preferences whatever $HOME is: a stand-in.
export GALLERY_DEFAULTS_BIN="${REPO_ROOT}/tests/fake-defaults"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/gallery-offon-test.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
fail() { echo "[offon_test] FAIL: $*" >&2; exit 1; }
say() { echo "[offon_test] $*"; }
export HOME="${WORK}/home"; mkdir -p "${HOME}/Library/LaunchAgents" "${WORK}/stub"
touch "${HOME}/Library/LaunchAgents/com.asmvik.yabai.plist" "${HOME}/Library/LaunchAgents/com.koekeishiya.skhd.plist"
LOG="${WORK}/stub.log"; RUNNING="${WORK}/running"; export LOG RUNNING
STATE="${HOME}/.config/gallery/state"
PAUSED="${STATE}/paused"; UNTILED="${STATE}/untiled.json"

# yabai: logs every call; `query --windows` prints the window list below.
cat > "${WORK}/stub/yabai" <<'EOF'
#!/bin/sh
echo "yabai $*" >> "$LOG"
case "$*" in
  "-m query --windows") cat <<'JSON'
[{"id": 11, "is-floating": false, "is-minimized": false, "can-move": true, "can-resize": true},
 {"id": 12, "is-floating": true,  "is-minimized": false, "can-move": true, "can-resize": true},
 {"id": 13, "is-floating": false, "is-minimized": false, "can-move": true, "can-resize": true,
  "frame": {"x": 868.0, "y": 42.0, "w": 852.0, "h": 529.0}},
 {"id": 14, "is-floating": false, "is-minimized": true,  "can-move": true, "can-resize": true}]
JSON
  ;;
esac
EOF
# osascript: the window-server snapshot `gallery on` takes.
cat > "${WORK}/stub/osascript" <<'EOF'
#!/bin/sh
echo "osascript" >> "$LOG"
echo '[{"id": 11, "app": "Finder", "x": 100, "y": 200, "w": 800, "h": 600}]'
EOF
for c in skhd launchctl pkill; do
  printf '#!/bin/sh\necho "%s $*" >> "$LOG"\n' "$c" > "${WORK}/stub/$c"
done
cat > "${WORK}/stub/pgrep" <<'EOF'
#!/bin/sh
for a; do name="$a"; done
grep -qx "$name" "$RUNNING" 2>/dev/null
EOF
chmod +x "${WORK}/stub/"*
export PATH="${WORK}/stub:${PATH}"
G="${REPO_ROOT}/bin/gallery"
UID_="$(id -u)"

# --- off, from on -------------------------------------------------------------
printf 'yabai\nskhd\n' > "${RUNNING}"
mkdir -p "${STATE}"
cat > "${UNTILED}" <<'EOF'
[{"id": 11, "app": "Finder", "x": 100, "y": 200, "w": 800, "h": 600},
 {"id": 12, "app": "Notes",  "x": 50,  "y": 60,  "w": 400, "h": 300},
 {"id": 14, "app": "Mail",   "x": 0,   "y": 0,   "w": 500, "h": 500}]
EOF
out="$("${G}" off)"
[ -f "${PAUSED}" ] || fail "off did not record the paused state"
case "${out}" in *"Gallery off: 2 window(s) back"*) ;; *) fail "off printed: ${out}" ;; esac
grep -qx "yabai -m window 11 --toggle float" "${LOG}" || fail "a tiled window was not floated before the move"
grep -q "yabai -m window 12 --toggle float" "${LOG}" && fail "an already floating window was toggled (that would tile it)"
grep -qx "yabai -m window 11 --move abs:100:200" "${LOG}" || fail "window 11 not moved back"
grep -qx "yabai -m window 11 --resize abs:800:600" "${LOG}" || fail "window 11 not resized back"
grep -qx "yabai -m window 12 --move abs:50:60" "${LOG}" || fail "window 12 not moved back"
grep -qx "yabai -m window 13 --toggle float" "${LOG}" || fail "a window opened after on was not frozen"
grep -qx "yabai -m window 13 --move abs:868:42" "${LOG}" || fail "a window opened after on did not keep its tile's place"
grep -qx "yabai -m window 13 --resize abs:852:529" "${LOG}" || fail "a window opened after on did not keep its tile's size"
last_toggle="$(grep -n -- "--toggle float" "${LOG}" | tail -1 | cut -d: -f1)"
first_move="$(grep -n -- "--move" "${LOG}" | head -1 | cut -d: -f1)"
[ "${last_toggle}" -lt "${first_move}" ] || fail "a window was moved before every window was floated (its neighbours re-tile)"
grep -q "yabai -m window 14 " "${LOG}" && fail "a minimised window was moved"
grep -qx "launchctl disable gui/${UID_}/com.asmvik.yabai" "${LOG}" || fail "off did not disable yabai in launchd"
grep -qx "launchctl disable gui/${UID_}/com.koekeishiya.skhd" "${LOG}" || fail "off did not disable skhd in launchd"
grep -qx "yabai --stop-service" "${LOG}" || fail "off did not stop yabai"
grep -qx "skhd --stop-service" "${LOG}" || fail "off did not stop skhd"
grep -q "pkill -x borders" "${LOG}" || fail "off did not stop the borders"
last_move="$(grep -n -- "--move\|--resize" "${LOG}" | tail -1 | cut -d: -f1)"
stop_yabai="$(grep -n -- "yabai --stop-service" "${LOG}" | cut -d: -f1)"
[ "${last_move}" -lt "${stop_yabai}" ] || fail "windows were moved after yabai was stopped"
[ "$(tail -1 "${LOG}")" = "skhd --stop-service" ] || fail "skhd was not stopped last (the key's own process runs under it)"
say "off: every window floated first, then the last on's windows put back and newer ones kept at their tile, minimised ones left, both services disabled and stopped, skhd last"

: > "${LOG}"; : > "${RUNNING}"
out="$("${G}" off)"
case "${out}" in *"already off"*) ;; *) fail "a second off printed: ${out}" ;; esac
[ ! -s "${LOG}" ] || fail "a second off touched the services: $(cat "${LOG}")"
doc="$("${G}" doctor 2>/dev/null || true)"
case "${doc}" in "NOTE    the Gallery is off"*) ;; *) fail "doctor does not mention the off state" ;; esac
printf '%s\n' "${doc}" | grep -qx "OFF     yabai stopped (gallery off)" || fail "doctor reports a stopped yabai as missing while off"
printf '%s\n' "${doc}" | grep -qx "OFF     skhd stopped (gallery off)" || fail "doctor reports a stopped skhd as missing while off"
say "off twice is a no-op; doctor says off, not missing"

# --- the ghost watchdog stands down while off ---------------------------------
cat > "${WORK}/fake-yabai" <<'EOF'
#!/bin/sh
echo "ghosts-yabai $*" >> "$LOG"
echo '[]'
EOF
chmod +x "${WORK}/fake-yabai"
: > "${LOG}"
GHOSTS_YABAI="${WORK}/fake-yabai" sh "${REPO_ROOT}/plugins/gallery.ghosts/ghosts" check
grep -q "ghosts-yabai" "${LOG}" && fail "ghosts check compared windows while the Gallery was off"
say "ghosts check does nothing while off"

# --- on, from off -------------------------------------------------------------
: > "${LOG}"; : > "${RUNNING}"; rm -f "${UNTILED}"
out="$("${G}" on)"
[ ! -f "${PAUSED}" ] || fail "on left the paused state"
grep -q '"id": 11' "${UNTILED}" || fail "on did not note where the windows were"
grep -qx "launchctl enable gui/${UID_}/com.asmvik.yabai" "${LOG}" || fail "on did not enable yabai in launchd"
grep -qx "launchctl enable gui/${UID_}/com.koekeishiya.skhd" "${LOG}" || fail "on did not enable skhd in launchd"
grep -qx "yabai --start-service" "${LOG}" || fail "on did not start yabai"
grep -qx "skhd --start-service" "${LOG}" || fail "on did not start skhd"
snap="$(grep -n "osascript" "${LOG}" | cut -d: -f1)"
start="$(grep -n "yabai --start-service" "${LOG}" | cut -d: -f1)"
[ "${snap}" -lt "${start}" ] || fail "the snapshot was taken after yabai started tiling"
case "${out}" in *"Gallery on"*) ;; *) fail "on printed: ${out}" ;; esac
say "on: window places noted before yabai starts, both services enabled and started"

: > "${LOG}"; printf 'yabai\nskhd\n' > "${RUNNING}"
out="$("${G}" on)"
case "${out}" in *"already on"*) ;; *) fail "a second on printed: ${out}" ;; esac
[ ! -s "${LOG}" ] || fail "a second on touched the services: $(cat "${LOG}")"
say "on twice is a no-op"

# --- the key ------------------------------------------------------------------
grep -qx 'shift + ctrl + lalt - escape : "$HOME/bin/gallery" off' "${REPO_ROOT}/tiler/tiler.skhd" \
  || fail "tiler.skhd does not bind the off key to gallery off"
grep -q '^::' "${REPO_ROOT}/tiler/tiler.skhd" && fail "tiler.skhd still declares skhd modes"
grep -q 'hs.hotkey.bind({ "shift", "ctrl", "alt" }, "escape"' "${REPO_ROOT}/Gallery.spoon/init.lua" \
  || fail "the Spoon does not hold the on key while off"
say "the key: skhd switches off, Hammerspoon switches on"
# A second definition of a function silently replaces the first for every
# caller (bash keeps the last one), as a quiet hs_call nearly did here.
dups="$(sed -n 's/^\([a-z_][a-z0-9_]*\)() {.*/\1/p' "${G}" | sort | uniq -d)"
[ -z "${dups}" ] || fail "bin/gallery defines these functions twice: ${dups}"
say "no function in bin/gallery is defined twice"
# Run from Hammerspoon's key (or skhd's), plain `pgrep -x` cannot see its own
# parent: the on/off code must ask with -a.
sed -n '/^# --- off \/ on/,/^cmd_reload/p' "${G}" | grep -q 'pgrep -xq' \
  && fail "the off/on code uses pgrep without -a (blind to its own parent process)"
grep -q 'off and "on" or "off"' "${REPO_ROOT}/Gallery.spoon/init.lua" \
  || fail "the Hammerspoon key does not decide on or off from the state file"
say "pgrep -a in the off/on code; the Hammerspoon key follows the state file"
# pgrep sees every user's processes: on a Mac where someone else is logged
# in, their yabai would pass for ours. Every lookup is scoped to this user.
unscoped="$(cd "${REPO_ROOT}" && grep -n 'pgrep -' bin/gallery bin/gallery-borders bin/gallery-term install.sh tiler/install.sh tiler/tiler.skhd \
  | grep -v -E '^[^:]+:[0-9]+: *#' | grep -v 'pgrep -u "\$(id -u)"' || true)"
[ -z "${unscoped}" ] || fail "pgrep not scoped to the current user: ${unscoped}"
say "every pgrep is scoped to the current user"
say "PASS offon_test.sh"
