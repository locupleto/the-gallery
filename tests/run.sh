#!/usr/bin/env bash
#
# run.sh -- Phase 2 test runner for The Gallery.
#
# Runs, in order:
#   1. `luac -p` (syntax check only) on every .lua file in the repo
#   2. `bash -n` (syntax check only) on every shell script in the repo
#   3. tests/manifest_test.lua, headless, through `hs -t 30 -q`
#   4. `~/bin/gallery status`, as a smoke test that the installed Spoon
#      is actually up and answering IPC
#
# Never wraps `hs` in coreutils `timeout` -- see bin/gallery and
# tests/gate.sh for why.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GALLERY_HS="${REPO_ROOT}/bin/gallery-hs"

say() {
  echo "[run] $*"
}

fail() {
  echo "[run] FAIL: $*" >&2
  exit 1
}

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "$1 not found on PATH"
  fi
}

require luac
require bash
require hs
[ -x "${GALLERY_HS}" ] || fail "${GALLERY_HS} not found or not executable"

# run_hs_file <timeout-seconds> <lua-file> [more hs args...] -- runs a test
# FILE through `hs -t N -q FILE`, not through gallery-hs: these are
# long-running by design (internal sleeps, multi-phase state machines) so
# gallery-hs's own retry-after-1.5s logic does not fit them. They still need
# a watchdog of their own though, so a reply lost to a Hammerspoon reload
# does not hang the whole test run: run hs in the background, wait up to
# timeout+5s, kill -9 and report FAIL if it did not return in that window.
run_hs_file() {
  local timeout_s="$1"
  shift
  local out_file
  out_file="$(mktemp -t gallery-test-file)"
  hs -t "${timeout_s}" -q "$@" > "${out_file}" 2>&1 &
  local pid=$!
  local max_wait=$((timeout_s + 5))
  local waited=0
  while kill -0 "${pid}" 2>/dev/null && [ "${waited}" -lt "${max_wait}" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "${pid}" 2>/dev/null; then
    kill -9 "${pid}" 2>/dev/null
    wait "${pid}" 2>/dev/null
    cat "${out_file}" >&2
    rm -f "${out_file}"
    fail "hs -t ${timeout_s} -q $* did not return within ${max_wait}s (watchdog killed it)"
  fi
  wait "${pid}" 2>/dev/null || true
  cat "${out_file}"
  rm -f "${out_file}"
}

say "luac -p on every .lua file"
lua_status=0
while IFS= read -r -d '' f; do
  if ! luac -p "${f}"; then
    echo "[run]   syntax error: ${f}" >&2
    lua_status=1
  fi
done < <(find "${REPO_ROOT}" -name '*.lua' -not -path '*/.git/*' -print0)
[ "${lua_status}" -eq 0 ] || fail "one or more .lua files failed luac -p"
say "all .lua files OK"

say "bash -n on every shell script"
sh_status=0
while IFS= read -r -d '' f; do
  if ! bash -n "${f}"; then
    echo "[run]   syntax error: ${f}" >&2
    sh_status=1
  fi
done < <(find "${REPO_ROOT}" -name '*.sh' -not -path '*/.git/*' -print0)
# bin/gallery has no .sh extension but is a bash script; check it too.
if [ -f "${REPO_ROOT}/bin/gallery" ]; then
  bash -n "${REPO_ROOT}/bin/gallery" || sh_status=1
fi
[ "${sh_status}" -eq 0 ] || fail "one or more shell scripts failed bash -n"
say "all shell scripts OK"

say "running tests/manifest_test.lua through hs"
manifest_out="$(run_hs_file 30 "${SCRIPT_DIR}/manifest_test.lua")"
printf '%s\n' "${manifest_out}"
if ! printf '%s\n' "${manifest_out}" | grep -q "^PASS "; then
  fail "manifest_test.lua did not report PASS"
fi
say "manifest_test.lua OK"

say "running tests/theme_test.lua through hs"
theme_out="$(run_hs_file 30 "${SCRIPT_DIR}/theme_test.lua")"
printf '%s\n' "${theme_out}"
if ! printf '%s\n' "${theme_out}" | grep -q "^PASS "; then
  fail "theme_test.lua did not report PASS"
fi
say "theme_test.lua OK"

say "~/bin/gallery status"
if ! "${HOME}/bin/gallery" status; then
  fail "gallery status failed"
fi

say "running tests/kinds_test.lua through hs"
kinds_out="$(run_hs_file 30 "${SCRIPT_DIR}/kinds_test.lua")"; printf '%s\n' "${kinds_out}"; printf '%s\n' "${kinds_out}" | grep -q "^PASS " || fail "kinds_test.lua did not report PASS"


# tests/bridge_test.lua is a 3-phase state machine driven by three separate
# `hs` invocations with real sleeps between them -- see the big comment at
# the top of that file for why a single call (with an internal busy-wait)
# cannot work: Hammerspoon does not deliver an evaluateJavaScript reply (or
# any other async callback) while the invocation that issued it is still
# running, only once that invocation's chunk has returned and a later,
# separate invocation lets the run loop turn again.
say "running tests/bridge_test.lua through hs (phase 1: open)"
"${GALLERY_HS}" -t 10 "return spoon.Gallery:ipc('close', 'gallery.hello')" > /dev/null 2>&1 || true
bridge_phase1="$(run_hs_file 60 "${SCRIPT_DIR}/bridge_test.lua")"
printf '%s\n' "${bridge_phase1}"
sleep 1
say "running tests/bridge_test.lua through hs (phase 2: issue in-page assertions)"
bridge_phase2="$(run_hs_file 60 "${SCRIPT_DIR}/bridge_test.lua")"
printf '%s\n' "${bridge_phase2}"
sleep 2
say "running tests/bridge_test.lua through hs (phase 3: collect + assert + close)"
bridge_out="$(run_hs_file 60 "${SCRIPT_DIR}/bridge_test.lua")"
printf '%s\n' "${bridge_out}"
if ! printf '%s\n' "${bridge_out}" | grep -q "^PASS "; then
  fail "bridge_test.lua did not report PASS"
fi
say "bridge_test.lua OK"

say "running tests/tui_test.sh"; "${SCRIPT_DIR}/tui_test.sh" || fail "tui_test.sh failed"

say "running tests/import_test.sh"; "${SCRIPT_DIR}/import_test.sh" || fail "import_test.sh failed"

say "all checks passed"
