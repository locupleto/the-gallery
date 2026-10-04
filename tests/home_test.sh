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
  {"id": 102, "app": "Safari", "title": "Report v1.2 (final) — Kim's copy", "space": 6,
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
assert_contains "yabai -m rule --add label=home-safari-1 app='^Safari\$' title='^Report v1\\.2 \\(final\\) — Kim'\\''s copy\$' space=6"

# --- exclusions: roam (iTerm2), Learn:, floating, AXDialog ------------------
assert_not_contains "home-iterm2"
assert_not_contains "home-notes"
assert_not_contains "home-preview"
assert_not_contains "home-system-settings"
say "exclusions OK (iTerm2/Learn:/floating/AXDialog produced no rules)"

# --- title-changed signal: removed first, re-added scoped to Safari, ---------
# --- re-applying exactly the title rules -------------------------------------
assert_contains "yabai -m signal --remove home-title-changed >/dev/null 2>&1 || true"
assert_contains "yabai -m signal --add label=home-title-changed event=window_title_changed app='^(Safari)\$' action='yabai -m rule --apply home-safari-1'"
say "title-changed signal OK"

# --- no title rules at all: the signal is only removed, never added ---------
OUT_ONE="$(GALLERY_HOME_WINDOWS_JSON="${FIXTURE}" HOME="${FAKE_HOME}" "${GALLERY_BIN}" home save --dry-run --roam Safari)"
printf '%s\n' "${OUT_ONE}" | grep -F -q -- "yabai -m signal --remove home-title-changed" \
  || fail "signal remove line missing when no title rules"
if printf '%s\n' "${OUT_ONE}" | grep -F -q -- "yabai -m signal --add"; then
  fail "signal added although no title rules exist"
fi
# ... and such a file must run cleanly when that signal does not exist (a
# failing last line made `home save` exit silently).
printf '%s\n' "${OUT_ONE}" > "${WORK_DIR}/rules-one.sh"
mkdir -p "${WORK_DIR}/failstub"
printf '#!/bin/sh\ncase "$*" in *"signal --remove"*) exit 1 ;; esac\nexit 0\n' > "${WORK_DIR}/failstub/yabai"
chmod +x "${WORK_DIR}/failstub/yabai"
PATH="${WORK_DIR}/failstub:${PATH}" sh "${WORK_DIR}/rules-one.sh" || fail "a rules file without title rules fails when the signal is absent"
say "signal absent without title rules OK"

# --- header sanity -----------------------------------------------------------
assert_contains "# Roaming (no rule): iTerm2"
assert_contains "#!/usr/bin/env sh"
say "header OK"

say "running bash -n on bin/gallery"
bash -n "${GALLERY_BIN}" || fail "bin/gallery failed bash -n"
say "bash -n OK"

# --- the login pass (gallery home _login-pass) -----------------------------
# A stub yabai logs every call and reports a fixed window list, so the desktop
# is "quiet"; the session and idle time come in through the test seams.
LP_HOME="${WORK_DIR}/lp-home"
LP_STUB="${WORK_DIR}/lp-stub"
LP_LOG="${WORK_DIR}/lp-yabai.log"
mkdir -p "${LP_HOME}/.config/gallery/state" "${LP_STUB}"
cat > "${LP_STUB}/yabai" <<EOF
#!/bin/sh
echo "yabai \$*" >> "${LP_LOG}"
case "\$*" in
  "-m query --windows") echo '[{"id": 1, "space": 2}, {"id": 2, "space": 3}]' ;;
esac
exit 0
EOF
chmod +x "${LP_STUB}/yabai"
lp() {  # lp <session-age> <idle-seconds>
  HOME="${LP_HOME}" PATH="${LP_STUB}:${PATH}" GALLERY_SESSION_ID=4242 \
    GALLERY_SESSION_AGE="$1" GALLERY_IDLE_SECONDS="$2" GALLERY_HOME_POLL=1 \
    GALLERY_HOME_QUIET_FOR=2 GALLERY_HOME_QUIET_TIMEOUT=5 "${GALLERY_BIN}" home _login-pass
}
applied() { grep -q -- "-m rule --apply" "${LP_LOG}" 2>/dev/null; }

: > "${LP_LOG}"; lp 30 60
applied && fail "login pass: applied without a saved layout"
mkdir -p "${LP_HOME}/.config/yabai"
printf '#!/bin/sh\nyabai -m rule --add label=home-mail app=^Mail$ space=5\n' > "${LP_HOME}/.config/yabai/rules.local"
: > "${LP_LOG}"; lp 9999 60
applied && fail "login pass: acted in a session that is not fresh"
[ -e "${LP_HOME}/.config/gallery/state/home-login-pass" ] && fail "login pass: marked an old session as done"
touch "${LP_HOME}/.config/gallery/state/paused"
: > "${LP_LOG}"; lp 30 60
applied && fail "login pass: acted while the Gallery is off"
rm -f "${LP_HOME}/.config/gallery/state/paused"
: > "${LP_LOG}"; lp 30 0
applied && fail "login pass: moved windows while the user was busy"
grep -q "no quiet moment" "${LP_HOME}/.config/gallery/gallery-home.log" || fail "login pass: giving up was not logged"
rm -f "${LP_HOME}/.config/gallery/state/home-login-pass"
: > "${LP_LOG}"; lp 30 60
applied || fail "login pass: did not apply the home rules in a quiet fresh session"
grep -q "home-mail" "${LP_LOG}" || fail "login pass: rules.local was not loaded first"
grep -q "home rules applied" "${LP_HOME}/.config/gallery/gallery-home.log" || fail "login pass: not logged"
: > "${LP_LOG}"; lp 30 60
applied && fail "login pass: ran twice in one login session"
say "login pass: once per fresh login, after a quiet moment; never while busy, off, or without a layout"

# The pass then rebuilds the saved tile shapes and, if a Desktop shows another
# wallpaper than the main one, re-applies the current wallpaper. Stubs: the
# layout tool and `gallery bg apply` log their calls; a fake wallpaper store.
LP_CALLS="${WORK_DIR}/lp-calls.log"
printf '#!/bin/sh\necho "layout $*" >> "%s"\n' "${LP_CALLS}" > "${LP_STUB}/layout-tool"
printf '#!/bin/sh\necho "gallery $*" >> "%s"\n' "${LP_CALLS}" > "${LP_STUB}/gallery-self"
chmod +x "${LP_STUB}/layout-tool" "${LP_STUB}/gallery-self"
echo '{}' > "${LP_HOME}/.config/yabai/home-layout.json"
mkdir -p "${LP_HOME}/.config/gallery/themes/jade"; ln -sfn jade "${LP_HOME}/.config/gallery/themes/current"
store() {  # store <picture for Desktop 2>: the main Desktop shows a.jpg
  python3 - "${WORK_DIR}/Index.plist" "$1" <<'PY'
import plistlib, sys
def desk(url):
    return {"Desktop": {"Content": {"Choices": [{"Configuration": plistlib.dumps({"url": {"relative": url}})}]}}}
data = {"Spaces": {"": {"Default": desk("file:///a.jpg")},
                   "UUID-2": {"Default": desk(sys.argv[2]), "Displays": {"D1": desk(sys.argv[2])}}}}
with open(sys.argv[1], "wb") as fh:
    plistlib.dump(data, fh, fmt=plistlib.FMT_BINARY)
PY
}
lp2() {
  rm -f "${LP_HOME}/.config/gallery/state/home-login-pass"; : > "${LP_CALLS}"
  GALLERY_LAYOUT_TOOL="${LP_STUB}/layout-tool" GALLERY_SELF="${LP_STUB}/gallery-self" \
    GALLERY_WALLPAPER_STORE="${WORK_DIR}/Index.plist" GALLERY_HOME_SETTLE=0 lp 30 60
}
store "file:///old-tokyo.jpg"; lp2
grep -q "layout restore --remap --file ${LP_HOME}/.config/yabai/home-layout.json" "${LP_CALLS}" || fail "login pass: the tile shapes were not restored: $(cat "${LP_CALLS}")"
grep -q "gallery bg apply" "${LP_CALLS}" || fail "login pass: a Desktop with an old wallpaper was not re-synced"
store "file:///a.jpg"; lp2
grep -q "gallery bg apply" "${LP_CALLS}" && fail "login pass: re-applied the wallpaper although every Desktop matched"
rm -f "${LP_HOME}/.config/yabai/home-layout.json"; lp2
grep -q "layout restore" "${LP_CALLS}" && fail "login pass: restored shapes without a saved layout"
say "login pass: tile shapes restored when saved; wallpaper re-applied only when a Desktop differs"

say "PASS home_test.sh"
