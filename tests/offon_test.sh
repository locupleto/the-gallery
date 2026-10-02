#!/bin/bash
# offon_test.sh -- `gallery off` / `gallery on` in a throwaway HOME, with
# yabai, skhd, pgrep and pkill stubbed so nothing on the real desktop is
# touched (pgrep reports nothing running, so the CLI takes its direct path).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/gallery-offon-test.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
fail() { echo "[offon_test] FAIL: $*" >&2; exit 1; }
say() { echo "[offon_test] $*"; }
export HOME="${WORK}/home"; mkdir -p "${HOME}" "${WORK}/stub"
LOG="${WORK}/stub.log"; export LOG
for c in yabai skhd pkill; do
  printf '#!/bin/sh\necho "%s $*" >> "$LOG"\n' "$c" > "${WORK}/stub/$c"
done
printf '#!/bin/sh\nexit 1\n' > "${WORK}/stub/pgrep"
chmod +x "${WORK}/stub/"*
export PATH="${WORK}/stub:${PATH}"
G="${REPO_ROOT}/bin/gallery"
PAUSED="${HOME}/.config/gallery/state/paused"

out="$("${G}" off)"
[ -f "${PAUSED}" ] || fail "off did not record the paused state"
grep -q "yabai --stop-service" "${LOG}" || fail "off did not stop yabai"
grep -q "pkill -x borders" "${LOG}" || fail "off did not stop the borders"
case "${out}" in *"Gallery off"*) ;; *) fail "off printed: ${out}" ;; esac
: > "${LOG}"
out="$("${G}" off)"
case "${out}" in *"already off"*) ;; *) fail "a second off printed: ${out}" ;; esac
[ ! -s "${LOG}" ] || fail "a second off touched the services: $(cat "${LOG}")"
doc="$("${G}" doctor 2>/dev/null || true)"
case "${doc}" in "NOTE    the Gallery is off"*) ;; *) fail "doctor does not mention the off state" ;; esac
say "off: yabai and borders stopped once, state recorded, doctor says so"

: > "${LOG}"
out="$("${G}" on)"
[ ! -f "${PAUSED}" ] || fail "on left the paused state"
grep -q "yabai --start-service" "${LOG}" || fail "on did not start yabai"
case "${out}" in *"Gallery on"*) ;; *) fail "on printed: ${out}" ;; esac
say "on: yabai started, state cleared"
say "PASS offon_test.sh"
