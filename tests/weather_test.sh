#!/usr/bin/env bash
#
# weather_test.sh -- offline test of `gallery weather ...` (bin/gallery, the
# "Gallery weather (gallery.weather; a floating glance panel over
# OpenWeatherMap's current-conditions endpoint)" section).
#
# Entirely offline, same isolation as home_test.sh: HOME is pointed at a
# temp directory (bin/gallery's CONFIG_DIR is "${HOME}/.config/gallery"),
# so a real ~/.config/gallery/state/weather.json or
# ~/.config/gallery/weather.key is never touched, read, or overwritten.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GALLERY_BIN="${REPO_ROOT}/bin/gallery"

say() {
  echo "[weather_test] $*"
}

fail() {
  echo "[weather_test] FAIL: $*" >&2
  exit 1
}

[ -x "${GALLERY_BIN}" ] || fail "${GALLERY_BIN} not found or not executable"
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gallery-weather-test.XXXXXX")"
cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

FAKE_HOME="${WORK_DIR}/home"
mkdir -p "${FAKE_HOME}"
STATE_FILE="${FAKE_HOME}/.config/gallery/state/weather.json"
KEY_FILE="${FAKE_HOME}/.config/gallery/weather.key"

gallery() {
  HOME="${FAKE_HOME}" "${GALLERY_BIN}" "$@"
}

# json_field <file> <key> -- prints one top-level field's JSON-decoded
# value (empty output if the file/field is missing).
json_field() {
  local file="$1" key="$2"
  [ -f "${file}" ] || return 0
  python3 -c '
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
if isinstance(data, dict) and key in data:
    v = data[key]
    print(v if isinstance(v, str) else json.dumps(v))
' "${file}" "${key}"
}

# --- 1. bare `gallery weather` before any state: defaults, key not configured

say "bare 'gallery weather' with no state at all"
status_out="$(gallery weather)"
say "--- output ---"
printf '%s\n' "${status_out}"
say "--- end output ---"
printf '%s\n' "${status_out}" | grep -qF "location Stockholm,SE" \
  || fail "expected default location Stockholm,SE in status output"
printf '%s\n' "${status_out}" | grep -qF "units metric" \
  || fail "expected default units metric in status output"
printf '%s\n' "${status_out}" | grep -qF "icons meteocons-line" \
  || fail "expected default icons meteocons-line in status output"
printf '%s\n' "${status_out}" | grep -qF "key not configured" \
  || fail "expected 'key not configured' with no key file present"
[ ! -f "${STATE_FILE}" ] || fail "bare status must not create ${STATE_FILE}"
say "defaults + not-configured OK"

# --- 2. location --set / --clear round-trip, unrelated fields intact -------

say "setting units and icons first, to have unrelated fields in the state file"
gallery weather units --set imperial >/dev/null
gallery weather icons --set meteocons-fill >/dev/null
[ -f "${STATE_FILE}" ] || fail "state file was not created by units/icons --set"

say "setting location"
gallery weather location --set "Oslo,NO" >/dev/null
[ "$(json_field "${STATE_FILE}" location)" = "Oslo,NO" ] \
  || fail "state file location not updated to Oslo,NO: $(cat "${STATE_FILE}")"
[ "$(json_field "${STATE_FILE}" units)" = "imperial" ] \
  || fail "location --set clobbered unrelated field units: $(cat "${STATE_FILE}")"
[ "$(json_field "${STATE_FILE}" iconSet)" = "meteocons-fill" ] \
  || fail "location --set clobbered unrelated field iconSet: $(cat "${STATE_FILE}")"
say "location --set round-trip OK, unrelated fields intact"

say "clearing location"
gallery weather location --clear >/dev/null
[ "$(json_field "${STATE_FILE}" location)" = "Stockholm,SE" ] \
  || fail "location --clear did not revert to the default Stockholm,SE: $(cat "${STATE_FILE}")"
[ "$(json_field "${STATE_FILE}" units)" = "imperial" ] \
  || fail "location --clear clobbered unrelated field units: $(cat "${STATE_FILE}")"
[ "$(json_field "${STATE_FILE}" iconSet)" = "meteocons-fill" ] \
  || fail "location --clear clobbered unrelated field iconSet: $(cat "${STATE_FILE}")"
say "location --clear round-trip OK, unrelated fields intact"

# --- 3. invalid units / icons values are rejected --------------------------

say "rejecting an invalid units value"
set +e
bad_units_out="$(gallery weather units --set bogus 2>&1)"
bad_units_rc=$?
set -e
say "gallery weather units --set bogus -> exit ${bad_units_rc}: ${bad_units_out}"
[ "${bad_units_rc}" -ne 0 ] || fail "invalid units value must exit non-zero"
[ "$(json_field "${STATE_FILE}" units)" = "imperial" ] \
  || fail "invalid units --set must not modify the state file"
say "invalid units rejected OK"

say "rejecting an invalid icons value"
set +e
bad_icons_out="$(gallery weather icons --set bogus 2>&1)"
bad_icons_rc=$?
set -e
say "gallery weather icons --set bogus -> exit ${bad_icons_rc}: ${bad_icons_out}"
[ "${bad_icons_rc}" -ne 0 ] || fail "invalid icons value must exit non-zero"
[ "$(json_field "${STATE_FILE}" iconSet)" = "meteocons-fill" ] \
  || fail "invalid icons --set must not modify the state file"
say "invalid icons rejected OK"

# --- 4. key --set: mode 600, never echoed -----------------------------------

SECRET="sk-test-super-secret-owm-key-1234567890"

say "setting the API key"
[ ! -f "${KEY_FILE}" ] || fail "precondition: key file must not exist yet"
key_set_out="$(gallery weather key --set "${SECRET}" 2>&1)"
say "gallery weather key --set <redacted> -> ${key_set_out}"
[ -f "${KEY_FILE}" ] || fail "key --set did not create ${KEY_FILE}"

perm="$(stat -f '%Lp' "${KEY_FILE}")"
[ "${perm}" = "600" ] || fail "expected mode 600 on ${KEY_FILE}, got ${perm}"
say "key file created with mode 600"

if printf '%s' "${key_set_out}" | grep -qF "${SECRET}"; then
  fail "key --set echoed the key value in its output"
fi
say "key --set did not echo the key"

status_out2="$(gallery weather 2>&1)"
say "gallery weather (with key configured) -> ${status_out2}"
printf '%s\n' "${status_out2}" | grep -qF "key configured" \
  || fail "expected 'key configured' once a key file is present"
if printf '%s' "${status_out2}" | grep -qF "${SECRET}"; then
  fail "'gallery weather' echoed the key value in its output"
fi
say "plain 'gallery weather' did not echo the key"

if grep -qF "${SECRET}" "${STATE_FILE}"; then
  fail "the key leaked into ${STATE_FILE}"
fi
say "key never appears in the JSON state file"

say "clearing the API key"
key_clear_out="$(gallery weather key --clear 2>&1)"
say "gallery weather key --clear -> ${key_clear_out}"
[ ! -f "${KEY_FILE}" ] || fail "key --clear did not remove ${KEY_FILE}"
if printf '%s' "${key_clear_out}" | grep -qF "${SECRET}"; then
  fail "key --clear echoed the key value in its output"
fi
status_out3="$(gallery weather)"
printf '%s\n' "${status_out3}" | grep -qF "key not configured" \
  || fail "expected 'key not configured' after key --clear"
say "key --clear OK"

# --- 5. manifest.json, if it exists yet (plugins/gallery.weather is being ---
# --- authored in parallel by another engineer; skip gracefully if absent) --

MANIFEST="${REPO_ROOT}/plugins/gallery.weather/manifest.json"
if [ -f "${MANIFEST}" ]; then
  say "checking ${MANIFEST}"
  python3 -c '
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
assert isinstance(data, dict), "manifest.json is not a JSON object"
kinds = data.get("kinds")
assert isinstance(kinds, list) and "tui" in kinds, "manifest.json does not declare kind tui: %r" % (kinds,)
' "${MANIFEST}" || fail "plugins/gallery.weather/manifest.json is not valid or does not declare kind tui"
  say "manifest.json OK (valid JSON, declares kind tui)"
else
  say "SKIP: ${MANIFEST} does not exist yet (plugins/gallery.weather authored in parallel)"
fi

say "running bash -n on bin/gallery"
bash -n "${GALLERY_BIN}" || fail "bin/gallery failed bash -n"
say "bash -n OK"

say "PASS weather_test.sh"
