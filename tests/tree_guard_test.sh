#!/usr/bin/env bash
#
# tree_guard_test.sh -- offline test of tiler/tree-guard's hole detection.
#
# Entirely offline: TREE_GUARD_YABAI points the guard at a stand-in `yabai`
# that serves fixture JSON, and TREE_GUARD_STATE at a temp file, so no real
# yabai is queried and no Space is ever rebuilt. Only `check` mode is
# exercised, which measures and reports but never repairs.
#
# The BROKEN fixture is the real geometry recorded on 2026-09-21, when half of
# a 2560x1440 display sat empty after a window was closed and reopened: three
# tiles crowded into the right-hand 1208 px while the tree still reserved the
# left half. It is the regression this guard exists for, and note that those
# three tiles are a PERFECT partition of their own bounding box -- a detector
# that compared tiles against their own extent instead of the display's usable
# rect would call this healthy.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GUARD="${REPO_ROOT}/tiler/tree-guard"

say()  { echo "[tree_guard_test] $*"; }
fail() { echo "[tree_guard_test] FAIL: $*" >&2; exit 1; }

[ -x "${GUARD}" ] || fail "${GUARD} not found or not executable"
command -v jq >/dev/null 2>&1 || fail "jq not found on PATH"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tree-guard-test.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

# A stand-in yabai: every query the guard makes, answered from $FIXTURE.
cat > "${WORK_DIR}/yabai" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
last="${@: -1}"   # the space index, for the --space queries
case "$*" in
  "-m config window_gap")            echo 8 ;;
  "-m query --displays")             jq -c '.displays'              "$FIXTURE" ;;
  "-m query --spaces")               jq -c '.spaces'                "$FIXTURE" ;;
  "-m query --windows")              jq -c '.windows'               "$FIXTURE" ;;
  "-m query --spaces --space "*)     jq -c --argjson i "$last" '.spaces[] | select(.index == $i)' "$FIXTURE" ;;
  "-m query --windows --space "*)    jq -c --argjson i "$last" '[.windows[] | select(.space == $i)]' "$FIXTURE" ;;
  "-m space "*"--layout "*)          echo "$*" >> "$REPAIRS" ;;
  *) echo "fake yabai: unhandled query: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "${WORK_DIR}/yabai"

# tile <id> <space> <display> <x> <y> <w> <h>
tile() {
  jq -nc --argjson id "$1" --argjson sp "$2" --argjson d "$3" \
         --argjson x "$4" --argjson y "$5" --argjson w "$6" --argjson h "$7" \
    '{id:$id, space:$sp, display:$d, frame:{x:$x,y:$y,w:$w,h:$h},
      "is-floating":false, "is-minimized":false, "is-visible":true,
      "has-fullscreen-zoom":false, "has-parent-zoom":false, "is-native-fullscreen":false}'
}

fixture() {   # fixture <output-path> <tile-json>...
  local out="$1"; shift
  jq -nc --argjson w "$(printf '%s\n' "$@" | jq -sc .)" \
    '{displays: [{index:1, frame:{x:0,y:0,w:2560,h:1440}}],
      spaces:   [{index:1, display:1, type:"bsp", "is-visible":true}],
      windows:  $w}' > "$out"
}

run_guard() {  # run_guard <fixture> <state> ; echoes output, returns the guard's exit code
  FIXTURE="$1" TREE_GUARD_YABAI="${WORK_DIR}/yabai" REPAIRS="${WORK_DIR}/repairs" \
  TREE_GUARD_STATE="$2" PATH="${WORK_DIR}:${PATH}" \
    "${GUARD}" check 2>&1
}

# The real thing: default mode, which measures, confirms and then repairs.
run_guard_auto() {  # run_guard_auto <fixture> <state> <repairs-file>
  : > "$3"
  FIXTURE="$1" TREE_GUARD_YABAI="${WORK_DIR}/yabai" REPAIRS="$3" \
  TREE_GUARD_STATE="$2" TREE_GUARD_LOG="${WORK_DIR}/guard.log" \
  TREE_GUARD_LOCK="${WORK_DIR}/lock.$$.$RANDOM" \
  TREE_GUARD_SETTLE=0 TREE_GUARD_CONFIRM=0 PATH="${WORK_DIR}:${PATH}" \
    "${GUARD}" 2>&1
}

# --- 1. healthy: a 2x2-ish partition filling the usable rect 8,39 - 2552,1432 --
HEALTHY="${WORK_DIR}/healthy.json"
fixture "${HEALTHY}" \
  "$(tile 1 1 1 8    39  1268 692)" \
  "$(tile 2 1 1 8    740 1268 692)" \
  "$(tile 3 1 1 1284 39  1268 1393)"

out="$(run_guard "${HEALTHY}" "${WORK_DIR}/state-healthy")" || fail "healthy fixture reported a hole: ${out}"
grep -q "space 1: whole" <<<"${out}" || fail "expected 'whole', got: ${out}"
say "healthy layout reads as whole -- ${out}"

# --- 2. broken: the recorded half-empty display ---------------------------------
# Calibration comes from the cache (an earlier healthy reading for this same
# display frame), which is how a display whose only Space is broken is still
# measured against how far its tiles once reached.
BROKEN="${WORK_DIR}/broken.json"
fixture "${BROKEN}" \
  "$(tile 1 1 1 1344 39  1208 692)" \
  "$(tile 2 1 1 1344 740 600  692)" \
  "$(tile 3 1 1 1952 740 600  692)"

cp "${WORK_DIR}/state-healthy" "${WORK_DIR}/state-broken"
if out="$(run_guard "${BROKEN}" "${WORK_DIR}/state-broken")"; then
  fail "broken fixture was NOT detected (exit 0): ${out}"
fi
grep -q "space 1: HOLE" <<<"${out}" || fail "expected 'HOLE', got: ${out}"
say "half-empty display detected -- ${out}"

# --- 3. the bounding-box trap ---------------------------------------------------
# Those three broken tiles partition their own bounding box perfectly. Prove it,
# so the reason this detector uses the display's usable rect stays on the record.
bbox_ratio="$(jq -r '[.windows[] | (.frame.w + 8) * (.frame.h + 8)] as $c
  | ([.windows[] | .frame.x] | min) as $l | ([.windows[] | .frame.y] | min) as $t
  | ([.windows[] | .frame.x + .frame.w] | max) as $r | ([.windows[] | .frame.y + .frame.h] | max) as $b
  | (($c | add) / (($r - $l + 8) * ($b - $t + 8)))' "${BROKEN}")"
awk -v r="${bbox_ratio}" 'BEGIN { exit !(r > 0.99) }' \
  || fail "expected the broken tiles to fill their own bbox (got ${bbox_ratio})"
say "broken tiles fill their own bounding box (${bbox_ratio}) -- bbox test would miss this"

# --- 4. a floating or minimized window must not count as coverage ---------------
SPARSE="${WORK_DIR}/sparse.json"
fixture "${SPARSE}" \
  "$(tile 1 1 1 8 39 1268 1393)" \
  "$(tile 2 1 1 1284 39 1268 1393 | jq -c '.["is-minimized"] = true')"
cp "${WORK_DIR}/state-healthy" "${WORK_DIR}/state-sparse"
if out="$(run_guard "${SPARSE}" "${WORK_DIR}/state-sparse")"; then
  fail "a half-covered Space with a minimized window was not detected: ${out}"
fi
say "minimized windows do not count as coverage -- ${out}"

# --- 5. the repair itself: float then bsp, on the broken Space only -------------
cp "${WORK_DIR}/state-healthy" "${WORK_DIR}/state-auto"
run_guard_auto "${BROKEN}" "${WORK_DIR}/state-auto" "${WORK_DIR}/repairs" >/dev/null
[ -s "${WORK_DIR}/repairs" ] || fail "a persistent hole was measured but never repaired"
grep -qx -- "-m space 1 --layout float" "${WORK_DIR}/repairs" || fail "no float step: $(cat "${WORK_DIR}/repairs")"
grep -qx -- "-m space 1 --layout bsp"   "${WORK_DIR}/repairs" || fail "no bsp step: $(cat "${WORK_DIR}/repairs")"
grep -q "rebuilding" "${WORK_DIR}/guard.log" || fail "the repair was not logged"
say "persistent hole rebuilt -- $(tr '\n' ';' < "${WORK_DIR}/repairs")"

# --- 6. a healthy Space is never rebuilt ---------------------------------------
cp "${WORK_DIR}/state-healthy" "${WORK_DIR}/state-noop"
run_guard_auto "${HEALTHY}" "${WORK_DIR}/state-noop" "${WORK_DIR}/repairs-noop" >/dev/null
[ -s "${WORK_DIR}/repairs-noop" ] && fail "a whole Space was rebuilt: $(cat "${WORK_DIR}/repairs-noop")"
say "whole Space left untouched -- split ratios safe"

say "PASS"
