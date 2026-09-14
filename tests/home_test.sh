#!/usr/bin/env bash
#
# home_test.sh -- offline test of `gallery home save --dry-run` (bin/gallery,
# the "home (yabai window -> Space snapshot)" section).
#
# Entirely offline: a fixture `yabai -m query --windows` JSON array is fed in
# via GALLERY_HOME_WINDOWS_JSON (bin/gallery's home_windows_json honours it
# instead of shelling out to a real yabai), and HOME is pointed at a temp
# directory so a real ~/.config/yabai/rules.local is never touched. Asserts
# on the exact generated rule lines with `grep -F` and on the absence of
# rules for windows that must be filtered out (iTerm2, Learn:, floating,
# AXDialog).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GALLERY_BIN="${REPO_ROOT}/bin/gallery"

say() {
  echo "[home_test] $*"
}

fail() {
  echo "[home_test] FAIL: $*" >&2
  exit 1
}

[ -x "${GALLERY_BIN}" ] || fail "${GALLERY_BIN} not found or not executable"
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gallery-home-test.XXXXXX")"
cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

FIXTURE="${WORK_DIR}/windows.json"
FAKE_HOME="${WORK_DIR}/home"
mkdir -p "${FAKE_HOME}"

# Fixture covers every case the algorithm must handle:
#   - Mail: one app, one Space -> a single app rule.
#   - Safari: one app on two Spaces, one window with an empty title (skipped,
#     noted in a comment) and one with a title containing `.` `(` and `'`,
#     which must come through regex- and shell-escaped.
#   - iTerm2: in the default roam list -- no rule at all.
#   - Notes: title "Learn: cheatsheet" -- a Gallery/Learn surface -- ignored
#     regardless of app.
#   - Preview: is-floating true -- ignored.
#   - System Settings: subrole AXDialog, not AXStandardWindow -- ignored.
cat > "${FIXTURE}" << 'EOF'
[
  {"id": 100, "app": "Mail", "title": "Inbox", "space": 5,
   "subrole": "AXStandardWindow", "is-floating": false},
  {"id": 101, "app": "Safari", "title": "", "space": 2,
   "subrole": "AXStandardWindow", "is-floating": false},
  {"id": 102, "app": "Safari", "title": "Report v1.2 (final) — Urban's copy", "space": 6,
   "subrole": "AXStandardWindow", "is-floating": false},
  {"id": 103, "app": "iTerm2", "title": "zsh", "space": 1,
   "subrole": "AXStandardWindow", "is-floating": false},
  {"id": 104, "app": "Notes", "title": "Learn: cheatsheet", "space": 1,
   "subrole": "AXStandardWindow", "is-floating": false},
  {"id": 105, "app": "Preview", "title": "diagram.pdf", "space": 1,
   "subrole": "AXStandardWindow", "is-floating": true},
  {"id": 106, "app": "System Settings", "title": "", "space": 1,
   "subrole": "AXDialog", "is-floating": false}
]
EOF

say "running gallery home save --dry-run against the fixture"
OUT="$(GALLERY_HOME_WINDOWS_JSON="${FIXTURE}" HOME="${FAKE_HOME}" "${GALLERY_BIN}" home save --dry-run)"
say "--- generated content ---"
printf '%s\n' "${OUT}"
say "--- end generated content ---"

assert_contains() {
  local needle="$1"
  printf '%s\n' "${OUT}" | grep -F -q -- "${needle}" \
    || fail "expected line not found: ${needle}"
}

assert_not_contains() {
  local needle="$1"
  if printf '%s\n' "${OUT}" | grep -F -q -- "${needle}"; then
    fail "unexpected line found: ${needle}"
  fi
}

# --- single-Space app: one plain rule ---------------------------------------
assert_contains "yabai -m rule --add label=home-mail app='^Mail\$' space=5"

# --- multi-Space app: per-window title rules, in Space order, plus the ------
# --- comment, plus the skipped-empty-title note -----------------------------
assert_contains "# Safari is on several Spaces: pinned per window by title (brittle -- titles change)"
assert_contains "1 window(s) with no title skipped"
assert_contains "yabai -m rule --add label=home-safari-1 app='^Safari\$' title='^Report v1\\.2 \\(final\\) — Urban'\\''s copy\$' space=6"

# --- exclusions: roam (iTerm2), Learn:, floating, AXDialog ------------------
assert_not_contains "home-iterm2"
assert_not_contains "home-notes"
assert_not_contains "home-preview"
assert_not_contains "home-system-settings"
say "exclusions OK (iTerm2/Learn:/floating/AXDialog produced no rules)"

# --- title-changed signal: removed first, re-added scoped to Safari, ---------
# --- re-applying exactly the title rules -------------------------------------
assert_contains "yabai -m signal --remove home-title-changed >/dev/null 2>&1"
assert_contains "yabai -m signal --add label=home-title-changed event=window_title_changed app='^(Safari)\$' action='yabai -m rule --apply home-safari-1'"
say "title-changed signal OK"

# --- no title rules at all: the signal is only removed, never added ---------
OUT_ONE="$(GALLERY_HOME_WINDOWS_JSON="${FIXTURE}" HOME="${FAKE_HOME}" "${GALLERY_BIN}" home save --dry-run --roam Safari)"
printf '%s\n' "${OUT_ONE}" | grep -F -q -- "yabai -m signal --remove home-title-changed" \
  || fail "signal remove line missing when no title rules"
if printf '%s\n' "${OUT_ONE}" | grep -F -q -- "yabai -m signal --add"; then
  fail "signal added although no title rules exist"
fi
say "signal absent without title rules OK"

# --- header sanity -----------------------------------------------------------
assert_contains "# Roaming (no rule): iTerm2"
assert_contains "#!/usr/bin/env sh"
say "header OK"

say "running bash -n on bin/gallery"
bash -n "${GALLERY_BIN}" || fail "bin/gallery failed bash -n"
say "bash -n OK"

say "PASS home_test.sh"
