#!/usr/bin/env bash
#
# import_test.sh -- exercises tools/import-omarchy-plugin.
#
# Phase 1 (offline): runs the tool against tests/fixtures/omarchy-basecamp
# and asserts the report exists, `basecamp` classifies missing (it is not
# installed on this Mac), `flock` classifies available, the dynamic
# (lockPath) element renders as `<dynamic>`, the verdict is partial, and
# the generated manifest validates cleanly through the live Gallery Spoon.
#
# Phase 2 (network): runs the tool against the real
# basecamp/omarchy-basecamp-plugin from GitHub and prints its verdict.
#
# Never wraps `hs` in coreutils `timeout` -- gallery validate goes through
# bin/gallery-hs, which carries its own graceful timeout and watchdog; see
# tests/run.sh and bin/gallery-hs for why.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOL="${REPO_ROOT}/tools/import-omarchy-plugin"
GALLERY_HS="${REPO_ROOT}/bin/gallery-hs"

say() {
  echo "[import_test] $*"
}

fail() {
  echo "[import_test] FAIL: $*" >&2
  exit 1
}

command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
[ -x "${TOOL}" ] || fail "${TOOL} is missing or not executable"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gallery-import-test.XXXXXX")"
cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Phase 1: local fixture, offline.
# ---------------------------------------------------------------------------
FIXTURE_OUT="${WORK_DIR}/out-fixture"

say "running the tool on tests/fixtures/omarchy-basecamp"
set +e
fixture_output="$(python3 "${TOOL}" "${REPO_ROOT}/tests/fixtures/omarchy-basecamp" --out "${FIXTURE_OUT}" 2>&1)"
fixture_status=$?
set -e
printf '%s\n' "${fixture_output}"
[ "${fixture_status}" -eq 0 ] || fail "tool exited ${fixture_status} on the local fixture (expected 0 -- portable/partial)"

REPORT="${FIXTURE_OUT}/PORT-REPORT.md"
[ -f "${REPORT}" ] || fail "PORT-REPORT.md was not written to ${FIXTURE_OUT}"
say "report exists: ${REPORT}"

grep -Eq '^\| [^|]+ \| missing \| `basecamp ' "${REPORT}" \
  || fail "basecamp was not classified missing in ${REPORT}"
say "basecamp classified missing"

grep -Eq '^\| [^|]+ \| available \| `flock ' "${REPORT}" \
  || fail "flock was not classified available in ${REPORT}"
say "flock classified available"

grep -q '<dynamic>' "${REPORT}" || fail "no <dynamic> element found in ${REPORT}"
say "dynamic element shown as <dynamic>"

grep -q '^\*\*partial\*\*' "${REPORT}" || fail "verdict was not partial in ${REPORT}"
say "verdict partial"

[ -f "${FIXTURE_OUT}/manifest.json" ] || fail "manifest.json was not written to ${FIXTURE_OUT}"
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${FIXTURE_OUT}/manifest.json" \
  || fail "generated manifest.json is not valid JSON"

if command -v hs >/dev/null 2>&1 && [ -x "${GALLERY_HS}" ]; then
  say "validating the generated manifest through the live Gallery Spoon"
  validate_out="$("${GALLERY_HS}" -t 10 "return spoon.Gallery:ipc('validate', '${FIXTURE_OUT}')" 2>&1 || true)"
  printf '%s\n' "${validate_out}"
  case "${validate_out}" in
    errors:*)
      fail "generated manifest failed gallery validate: ${validate_out}"
      ;;
    *)
      say "manifest validates (gallery validate: ${validate_out})"
      ;;
  esac
else
  say "hs not on PATH -- skipping the live gallery validate cross-check"
fi

# ---------------------------------------------------------------------------
# Phase 2: the real Basecamp plugin from GitHub (network).
# ---------------------------------------------------------------------------
say "running the tool on the real basecamp/omarchy-basecamp-plugin (network)"
REAL_OUT="${WORK_DIR}/out-basecamp-real"
set +e
real_output="$(python3 "${TOOL}" https://github.com/basecamp/omarchy-basecamp-plugin --out "${REAL_OUT}" 2>&1)"
real_status=$?
set -e
printf '%s\n' "${real_output}"
if [ "${real_status}" -eq 1 ]; then
  fail "tool errored (exit 1) on the real Basecamp plugin -- see output above"
fi
verdict_line="$(printf '%s\n' "${real_output}" | grep '^verdict:' || true)"
say "real Basecamp plugin verdict: ${verdict_line:-<none printed>}"

say "PASS import_test.sh"
