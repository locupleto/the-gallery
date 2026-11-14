#!/usr/bin/env bash
#
# ghosts_test.sh -- offline test of the gallery.ghosts relaunch circuit
# breaker (plugins/gallery.ghosts/ghosts).
#
# Regression guard for the loop found on 2026-09-22: ghosts state is keyed by
# WINDOW id, and relaunching an app hands it a brand new window with a brand
# new id, so a re-ghosting app looked like a first offence on every pass.
# Claude and ChatGPT were quit and relaunched roughly every 90 s for hours,
# each time ghosting the very window ghosts' own `open -a` had just produced.
#
# Entirely offline: the breaker's real source text is lifted out of the
# shipped script and exercised against a temp state file, so no window is
# scanned, no app is quit and nothing is relaunched. Asserts the three
# transitions that matter, plus that state_prune keeps owner records (losing
# them is exactly what re-arms the loop).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GHOSTS="${REPO_ROOT}/plugins/gallery.ghosts/ghosts"
COOLDOWN=21600   # must match RELAUNCH_COOLDOWN in the script

say()  { echo "[ghosts_test] $*"; }
fail() { echo "[ghosts_test] FAIL: $*" >&2; exit 1; }

[ -f "${GHOSTS}" ] || fail "${GHOSTS} not found"
command -v jq >/dev/null 2>&1 || fail "jq not found on PATH"

grep -q '^RELAUNCH_COOLDOWN=' "${GHOSTS}" || fail "RELAUNCH_COOLDOWN is gone from the script"
grep -q "^RELAUNCH_COOLDOWN=${COOLDOWN}" "${GHOSTS}" \
  || fail "RELAUNCH_COOLDOWN changed; update COOLDOWN in this test to match"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

say "building a harness around the breaker's real source text"
{
  echo '#!/bin/sh'
  echo 'set -eu'
  echo "STATE_FILE=${TMP}/state.json"
  cat <<'HARNESS'
state_get() { [ -f "$STATE_FILE" ] && jq -r --arg id "$1" '.[$id].action // empty' "$STATE_FILE" 2>/dev/null || true; }
state_at()  { [ -f "$STATE_FILE" ] && jq -r --arg id "$1" '.[$id].at // empty' "$STATE_FILE" 2>/dev/null || true; }
state_set() {
  [ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"
  tmp=$(mktemp); jq --arg id "$1" --arg owner "$2" --arg action "$3" --argjson at "$(date +%s)" \
    '.[$id] = {owner: $owner, action: $action, at: $at}' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}
HARNESS
  # the breaker itself, verbatim from the shipped script
  awk '/^OWNER_PREFIX=/,/^}$/' "${GHOSTS}"
  awk '/^breaker_allows\(\) \{/,/^}$/' "${GHOSTS}"
  cat <<'BODY'
echo '{}' > "$STATE_FILE"
breaker_allows Claude || { echo "UNEXPECTED: blocked before any relaunch"; exit 1; }
echo "ok: never relaunched -> allowed"
owner_mark Claude relaunched
if breaker_allows Claude; then echo "UNEXPECTED: allowed immediately after a relaunch"; exit 1; fi
echo "ok: just relaunched -> blocked"
tmp=$(mktemp); jq --argjson old "$(( $(date +%s) - COOLDOWN_AGE ))" '.["owner:Claude"].at = $old' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
breaker_allows Claude || { echo "UNEXPECTED: still blocked after the cooldown"; exit 1; }
echo "ok: cooldown served -> allowed again"
BODY
} | sed "s/COOLDOWN_AGE/$((COOLDOWN + 1))/" > "${TMP}/harness.sh"

out="$(sh "${TMP}/harness.sh" 2>&1)" || { echo "${out}"; fail "breaker harness failed"; }
printf '%s\n' "${out}" | sed 's/^/[ghosts_test]   /'
printf '%s\n' "${out}" | grep -q "never relaunched -> allowed"  || fail "missing first-offence case"
printf '%s\n' "${out}" | grep -q "just relaunched -> blocked"   || fail "breaker did not block the loop"
printf '%s\n' "${out}" | grep -q "cooldown served -> allowed"   || fail "cooldown never re-arms"

say "state_prune must keep owner records while dropping dead window ids"
printf '%s\n' '{"8113":{"owner":"Claude","action":"seen","at":1},"owner:Claude":{"owner":"Claude","action":"relaunched","at":1}}' > "${TMP}/s.json"
pruned="$(jq -c --argjson live '["9999"]' \
  'with_entries(select((.key | startswith("owner:")) or (.key as $k | $live | index($k))))' "${TMP}/s.json")"
printf '%s' "${pruned}" | grep -q '"owner:Claude"' || fail "prune dropped the owner record -- the loop is re-armed"
printf '%s' "${pruned}" | grep -q '"8113"'          && fail "prune kept a window id that is no longer live"
say "prune keeps owner:Claude, drops 8113 -- correct"

say "the shipped prune filter carries the same startswith guard"
grep -q 'startswith("owner:")' "${GHOSTS}" || fail "state_prune in the script lost its owner-record guard"

say "an automatic relaunch is gated by the breaker"
grep -q 'if ! breaker_allows "$owner"; then' "${GHOSTS}" || fail "cmd_check no longer consults the breaker"
say "an explicit \`ghosts fix\` still records the attempt"
grep -q 'owner_mark "$owner" relaunched; state_set "$id" "$owner" relaunched' "${GHOSTS}" \
  || fail "cmd_fix no longer records the relaunch"

# --- the harm discriminator, driven through the real scan() ------------------
# The script exposes GHOSTS_YABAI so a fake yabai can stand in. Class B must
# act only on an AX-less window that actually costs something: visible (ghost
# text under the tiles) or holding a BSP slot (an empty gap). A stub that is
# neither -- which is what Claude and ChatGPT leave behind, and what drove the
# 2026-09-22 relaunch loop -- must be ignored.
say "exercising scan()'s class-B discriminator against a fake yabai"

cat > "${TMP}/windows.json" <<'JSON'
[
 {"id":900001,"pid":9001,"app":"StubApp","title":"","role":"","subrole":"",
  "frame":{"x":10,"y":20,"w":630,"h":1393},"space":1,
  "has-ax-reference":false,"is-visible":false,"is-minimized":false,"is-hidden":false,
  "is-floating":false,"split-type":"none","can-move":false,"can-resize":false},
 {"id":900002,"pid":9002,"app":"SlotApp","title":"","role":"","subrole":"",
  "frame":{"x":10,"y":20,"w":600,"h":600},"space":1,
  "has-ax-reference":false,"is-visible":false,"is-minimized":false,"is-hidden":false,
  "is-floating":false,"split-type":"vertical","can-move":false,"can-resize":false},
 {"id":900003,"pid":9003,"app":"VisibleApp","title":"","role":"","subrole":"",
  "frame":{"x":10,"y":20,"w":600,"h":600},"space":1,
  "has-ax-reference":false,"is-visible":true,"is-minimized":false,"is-hidden":false,
  "is-floating":false,"split-type":"none","can-move":false,"can-resize":false},
 {"id":900004,"pid":9004,"app":"FloatApp","title":"","role":"","subrole":"",
  "frame":{"x":0,"y":0,"w":600,"h":600},"space":1,
  "has-ax-reference":false,"is-visible":true,"is-minimized":false,"is-hidden":false,
  "is-floating":true,"split-type":"none","can-move":false,"can-resize":false}
]
JSON

cat > "${TMP}/fake-yabai" <<FAKE
#!/bin/sh
case "\$*" in
  *--windows*) cat "${TMP}/windows.json" ;;
  *--spaces*)  echo '[]' ;;
  *)           echo '[]' ;;
esac
FAKE
chmod +x "${TMP}/fake-yabai"

# scan() also walks the REAL window-server list (its first source), so the
# output legitimately contains this machine's own windows. Only the fixture
# ids are asserted on.
scan_out="$(GHOSTS_YABAI="${TMP}/fake-yabai" sh "${GHOSTS}" scan 2>/dev/null || true)"
fixture_hits="$(printf '%s\n' "${scan_out}" | grep -E '^90000[0-9]' || true)"
say "fixture windows reported by scan:"
if [ -n "${fixture_hits}" ]; then printf '%s\n' "${fixture_hits}" | sed 's/^/[ghosts_test]   /'; else say "  (none)"; fi

printf '%s\n' "${fixture_hits}" | grep -q '^900001' \
  && fail "harmless stub (invisible, split-type none) was flagged -- this is the relaunch loop"
say "900001 invisible + no tile slot -> ignored (correct)"

printf '%s\n' "${fixture_hits}" | grep -q '^900002' \
  || fail "a window holding a BSP slot was NOT flagged -- the Calendar case regressed"
say "900002 invisible but holds a tile slot -> flagged (correct)"

printf '%s\n' "${fixture_hits}" | grep -q '^900003' \
  || fail "a visible AX-less window was NOT flagged"
say "900003 visible -> flagged (correct)"

printf '%s\n' "${fixture_hits}" | grep -q '^900004' \
  && fail "a floating window was flagged; floating windows are not tiled"
say "900004 floating -> ignored (correct)"

# --- the undrawn class: yabai shows a tile the window server does not draw ----
# Reminders, restored at login on 2026-11-13, kept a tile that showed only
# wallpaper. Both sides are faked here, so nothing on this machine is read.
say "exercising scan()'s undrawn class against a fake yabai and window server"

tile() {  # id app visible floating hidden split
  printf '{"id":%s,"pid":%s,"app":"%s","title":"t","role":"AXWindow","subrole":"AXStandardWindow","frame":{"x":0,"y":0,"w":800,"h":600},"space":1,"has-ax-reference":true,"is-visible":%s,"is-minimized":false,"is-hidden":%s,"is-floating":%s,"split-type":"%s","can-move":true,"can-resize":true}' \
    "$1" "$1" "$2" "$3" "$5" "$4" "$6"
}
{
  printf '['
  tile 900010 DrawnApp    true  false false vertical; printf ','
  tile 900011 UndrawnApp  true  false false vertical; printf ','
  tile 900012 FloatingApp true  true  false none;     printf ','
  tile 900013 HiddenApp   false false true  vertical; printf ','
  tile 900014 AwayApp     false false false vertical
  printf ']'
} > "${TMP}/windows.json"

cat > "${TMP}/fake-ws" <<FAKE
#!/bin/sh
cat "${TMP}/ws.txt"
FAKE
chmod +x "${TMP}/fake-ws"

printf '900010\0370\037900010\037DrawnApp\037t\0370\0370\037800\037600\n' > "${TMP}/ws.txt"
undrawn_out="$(GHOSTS_YABAI="${TMP}/fake-yabai" GHOSTS_WINDOW_SERVER="${TMP}/fake-ws" sh "${GHOSTS}" scan 2>/dev/null || true)"
printf '%s\n' "${undrawn_out}" | sed 's/^/[ghosts_test]   /'
printf '%s\n' "${undrawn_out}" | grep -q "^900011	undrawn	" \
  || fail "a visible tile the window server does not draw was NOT flagged -- the Reminders case"
[ "$(printf '%s\n' "${undrawn_out}" | grep -c '^9000')" = 1 ] \
  || fail "only 900011 may be flagged: drawn, floating, hidden and out-of-view windows are not undrawn"
say "900011 visible tile, not drawn -> flagged; the other four -> ignored (correct)"

: > "${TMP}/ws.txt"
blind_out="$(GHOSTS_YABAI="${TMP}/fake-yabai" GHOSTS_WINDOW_SERVER="${TMP}/fake-ws" sh "${GHOSTS}" scan 2>/dev/null || true)"
printf '%s\n' "${blind_out}" | grep -q 'undrawn' \
  && fail "with no tile on the on-screen list every app would be relaunched; nothing may be flagged"
say "no tile confirmed on screen -> nothing flagged (correct)"

# --- diagnostic logging ------------------------------------------------------
say "flag-time logging must record the fields that decide harm"
grep -q '^window_diag() {' "${GHOSTS}" || fail "window_diag helper is gone"
for field in 'is-visible' 'split-type' 'can-move'; do
  grep -q "${field}" "${GHOSTS}" || fail "window_diag no longer reports ${field}"
done
grep -q 'log "candidate: .*\$(window_diag "\$id")' "${GHOSTS}" || fail "candidate log line lost window_diag"
grep -q 'log "ghost: .*\$(window_diag "\$id")'     "${GHOSTS}" || fail "ghost log line lost window_diag"
say "candidate and ghost log lines both carry window_diag"

say "PASS ghosts_test.sh"
