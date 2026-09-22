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

say "PASS ghosts_test.sh"
