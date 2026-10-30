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
if printf '%s\n' "${OUT_ONE}" | grep -F -q -- "yabai -m signal --add label=home-title-changed"; then
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

# --- home-keep-here: the signal (a home rule acts on every LATER window too) -
# Every pinned app is in the filter, the old signal is removed first, and the
# action hands the new window to `gallery home _keep-here`.
assert_contains "yabai -m signal --remove home-keep-here >/dev/null 2>&1 || true"
assert_contains "yabai -m signal --add label=home-keep-here event=window_created app='^(Mail|Safari)\$' action='PATH=\"/opt/homebrew/bin:/usr/local/bin:\$PATH\" \"\$HOME/bin/gallery\" home _keep-here \"\$YABAI_WINDOW_ID\" >/dev/null 2>&1'"
printf '[{"id": 1, "app": "iTerm2", "title": "zsh", "space": 1, "subrole": "AXStandardWindow", "is-floating": false}]' > "${WORK_DIR}/roam-only.json"
OUT_NONE="$(GALLERY_HOME_WINDOWS_JSON="${WORK_DIR}/roam-only.json" HOME="${FAKE_HOME}" "${GALLERY_BIN}" home save --dry-run)"
printf '%s\n' "${OUT_NONE}" | grep -F -q "yabai -m signal --remove home-keep-here" || fail "keep-here: no remove line without pinned apps"
if printf '%s\n' "${OUT_NONE}" | grep -F -q "label=home-keep-here event"; then
  fail "keep-here: signal added although no app is pinned"
fi
printf '%s\n' "${OUT}" > "${WORK_DIR}/rules-full.sh"
PATH="${WORK_DIR}/failstub:${PATH}" sh "${WORK_DIR}/rules-full.sh" || fail "a rules file fails when its signals are absent"
say "keep-here signal: every pinned app, removed first, absent without pins"

# --- T1: _keep-here moves a LATER window back to the Desktop in view ---------
# A stub yabai serves the windows and the focused Space, and logs the moves.
KH_STUB="${WORK_DIR}/kh-stub"; KH_LOG="${WORK_DIR}/kh.log"
mkdir -p "${KH_STUB}"
cat > "${KH_STUB}/yabai" <<EOF
#!/bin/sh
case "\$*" in
  "-m query --windows") cat "${WORK_DIR}/kh-windows.json" ;;
  "-m query --spaces --space") cat "${WORK_DIR}/kh-space.json" ;;
  *) echo "yabai \$*" >> "${KH_LOG}" ;;
esac
exit 0
EOF
chmod +x "${KH_STUB}/yabai"
# The desktop: Desktops 1-9 on display 1, 10-13 on display 2. Safari (pid 700)
# is pinned to Desktop 10; the user is on the empty Desktop 5.
kh_windows() { printf '%s\n' "$1" > "${WORK_DIR}/kh-windows.json"; }
kh_space() { printf '{"index": %s, "display": %s}\n' "$1" "$2" > "${WORK_DIR}/kh-space.json"; }
kh() {  # kh <window id> [app age] [session age]: a fresh login unless given
  : > "${KH_LOG}"
  HOME="${FAKE_HOME}" PATH="${KH_STUB}:${PATH}" GALLERY_APP_AGE="${2:-}" GALLERY_SESSION_ID=55 \
    GALLERY_SESSION_AGE="${3:-30}" "${GALLERY_BIN}" home _keep-here "$1" \
    || fail "_keep-here exited non-zero"
}
moved() { grep -qx -- "yabai -m window $1 --space $2" "${KH_LOG}" && grep -qx -- "yabai -m window --focus $1" "${KH_LOG}"; }
still() { [ ! -s "${KH_LOG}" ] || fail "$1 -- but it moved: $(tr '\n' '|' < "${KH_LOG}")"; }
OLD='{"id": 701, "pid": 700, "app": "Safari", "space": 10, "subrole": "AXStandardWindow", "is-floating": false}'
NEW='{"id": 702, "pid": 700, "app": "Safari", "space": 10, "subrole": "AXStandardWindow", "is-floating": false}'
kh_space 5 1

kh_windows "[${OLD}, ${NEW}]"; kh 702 3600
moved 702 5 || fail "T1: a second window of a running app was not brought back to Desktop 5: $(cat "${KH_LOG}")"
say "T1 a second Safari window (super+b, Cmd-N) comes back to the Desktop in view and is focused"

kh_windows "[${OLD}, ${NEW}]"; kh 702 5
still "a young app's windows (restored at launch or login) must go home"
kh_windows "[${NEW}]"; kh 702 3600
still "an app's first window (a launch, a Dock reopen) must go home"
kh_windows "[${OLD}, $(printf '%s' "${NEW}" | sed 's/"space": 10/"space": 5/')]"; kh 702 3600
still "a window already on the Desktop in view needs no move"
kh_windows "[${OLD}, $(printf '%s' "${NEW}" | sed 's/"is-floating": false/"is-floating": true/')]"; kh 702 3600
still "a floating window (a dialog, a panel) is left alone"
kh_windows "[${OLD}, $(printf '%s' "${NEW}" | sed 's/AXStandardWindow/AXDialog/')]"; kh 702 3600
still "a non-standard window is left alone"
kh_windows "[${OLD}, ${NEW}]"; kh "abc" 3600
still "a malformed window id is ignored"
kh_windows "[${OLD}]"; kh 702 3600
still "a window yabai no longer lists is ignored"
say "T1 left home: a young app, a first window, already here, floating, a dialog, a bad id"

# Once the login pass has put the windows back, every new window stays where
# it is opened, an app's first one and a young app's too (Outlook started
# from the Dock, 2026-10-30); so it does once the pass can no longer run.
mkdir -p "${FAKE_HOME}/.config/gallery/state"
echo 55 > "${FAKE_HOME}/.config/gallery/state/home-login-done"
kh_windows "[${NEW}]"; kh 702 2
moved 702 5 || fail "settled: an app's first window was thrown to its home Desktop: $(cat "${KH_LOG}")"
kh_windows "[${OLD}, $(printf '%s' "${NEW}" | sed 's/"is-floating": false/"is-floating": true/')]"; kh 702 2
still "settled: a floating window is still left alone"
echo 54 > "${FAKE_HOME}/.config/gallery/state/home-login-done"
kh_windows "[${NEW}]"; kh 702 2
still "another login's done marker must not settle this one"
kh_windows "[${NEW}]"; kh 702 2 99999
moved 702 5 || fail "settled: a session past the login pass still sent a first window home"
rm -f "${FAKE_HOME}/.config/gallery/state/home-login-done"
say "T1 after the login pass every new window stays on the Desktop in view, a first one too"

# Several Desktops on two displays: the user on Desktop 12 (display 2), a
# window thrown onto Desktop 3 (display 1) comes to 12 -- the global index.
kh_space 12 2
kh_windows "[$(printf '%s' "${OLD}" | sed 's/"space": 10/"space": 3/'), $(printf '%s' "${NEW}" | sed 's/"space": 10/"space": 3/')]"; kh 702 3600
moved 702 12 || fail "T9: the window did not come to Desktop 12 on the second display: $(cat "${KH_LOG}")"
# The app's age from ps when no seam is set: launchd (pid 1) is old.
kh_space 5 1
kh_windows "[$(printf '%s' "${OLD}" | sed 's/"pid": 700/"pid": 1/'), $(printf '%s' "${NEW}" | sed 's/"pid": 700/"pid": 1/')]"; kh 702
moved 702 5 || fail "_keep-here: the app's age from ps was not read: $(cat "${KH_LOG}")"
say "T9 the second display's Desktops (10-13) and the app age from ps"

# T9 for the save: a window on the second display's Desktop 12 gets space=12,
# yabai's one global index across displays.
printf '[{"id": 1, "app": "Obsidian", "title": "Vault", "space": 12, "display": 2, "subrole": "AXStandardWindow", "is-floating": false}]' > "${WORK_DIR}/display2.json"
GALLERY_HOME_WINDOWS_JSON="${WORK_DIR}/display2.json" HOME="${FAKE_HOME}" "${GALLERY_BIN}" home save --dry-run \
  | grep -F -q "yabai -m rule --add label=home-obsidian app='^Obsidian\$' space=12" || fail "T9: a second-display Desktop lost its global index"
say "T9 a Desktop on the second display keeps its global index (space=12)"

# --- T8: --keep-absent carries plain rules, never title rules ----------------
# The previous file holds what the nightly save had piled up by 2026-10-27:
# plain rules, title rules (carried by mistake, a greedy pattern), a plain
# rule for an app this save pins by title, a now-roaming app, a dotted name.
KA_HOME="${WORK_DIR}/ka-home"; mkdir -p "${KA_HOME}/.config/yabai"
cat > "${KA_HOME}/.config/yabai/rules.local" <<'EOF'
#!/usr/bin/env sh
yabai -m rule --add label=home-claude app='^Claude$' space=2
yabai -m rule --add label=home-safari app='^Safari$' space=10
yabai -m rule --add label=home-safari-2 app='^Safari$' title='^The Observatory$' space=10
yabai -m rule --add label=home-preview-1 app='^Preview$' title='^JARVIS-mech\.png$' space=9
yabai -m rule --add label=home-iterm2 app='^iTerm2$' space=1
yabai -m rule --add label=home-finder app='^Finder$' space=1
yabai -m rule --add label=home-mail app='^Mail$' space=3
yabai -m rule --add label=home-microsoft-word app='^Microsoft\ Word\.x$' space=4
yabai -m rule --add label=home-claude app='^Claude$' space=2
EOF
OUT_KA="$(GALLERY_HOME_WINDOWS_JSON="${FIXTURE}" HOME="${KA_HOME}" "${GALLERY_BIN}" home save --dry-run --keep-absent)"
ka_has() { printf '%s\n' "${OUT_KA}" | grep -F -q -- "$1" || fail "keep-absent: expected '$1' in: ${OUT_KA}"; }
ka_not() { if printf '%s\n' "${OUT_KA}" | grep -F -q -- "$1"; then fail "keep-absent: unexpected '$1'"; fi; }
ka_has "# Carried forward from the previous save (app absent now)"
ka_has "yabai -m rule --add label=home-claude app='^Claude\$' space=2"
ka_has "yabai -m rule --add label=home-microsoft-word app='^Microsoft\\ Word\\.x\$' space=4"
[ "$(printf '%s\n' "${OUT_KA}" | grep -c 'label=home-claude ')" = 1 ] || fail "keep-absent: a duplicate rule was carried twice"
ka_not "The Observatory"
ka_not "home-preview-1"
ka_not "label=home-safari app="
ka_not "home-iterm2"
ka_not "home-finder"
ka_has "yabai -m rule --add label=home-mail app='^Mail\$' space=5"
[ "$(printf '%s\n' "${OUT_KA}" | grep -c 'label=home-mail ')" = 1 ] || fail "keep-absent: Mail's old Desktop was carried beside its new one"
ka_has "app='^(Claude|Mail|Microsoft Word\\.x|Safari)\$'"
OUT_NOKA="$(GALLERY_HOME_WINDOWS_JSON="${FIXTURE}" HOME="${KA_HOME}" "${GALLERY_BIN}" home save --dry-run)"
if printf '%s\n' "${OUT_NOKA}" | grep -F -q "home-claude"; then fail "a save without --keep-absent carried a rule"; fi
say "T8 --keep-absent: absent apps keep plain rules once; title, superseded and roaming rules dropped"

# Finder roams by default: it never quits, so every folder window it opens is
# a "first window" home-keep-here cannot rescue, and a Finder rule threw the
# user to Finder's home Desktop (2026-10-30, a Desktop folder opened from 8).
printf '[{"id": 1, "app": "Finder", "title": "Downloads", "space": 3, "subrole": "AXStandardWindow", "is-floating": false}]' > "${WORK_DIR}/finder.json"
OUT_FINDER="$(GALLERY_HOME_WINDOWS_JSON="${WORK_DIR}/finder.json" HOME="${FAKE_HOME}" "${GALLERY_BIN}" home save --dry-run)"
if printf '%s\n' "${OUT_FINDER}" | grep -F -q "home-finder"; then fail "Finder got a home rule"; fi
printf '%s\n' "${OUT_FINDER}" | grep -F -q "# Roaming (no rule): iTerm2, Ghostty, kitty, WezTerm, Finder" || fail "Finder missing from the roaming list"
say "Finder roams by default"

# --- homes are for the login only ---------------------------------------------
# rules.local asks `gallery home _settled` before loading anything: once this
# login's pass is done no rule or signal is loaded, so nothing moves a window
# to another Desktop mid-session (a Dock launch, a dialog, a Safari title).
assert_contains "# Homes act only while the Mac logs in (see \`gallery home _settled\`)."
assert_contains 'if [ -n "${GALLERY_HOME_FORCE:-}" ] || ! { [ -x "$HOME/bin/gallery" ] && "$HOME/bin/gallery" home _settled; }; then'
[ "$(printf '%s\n' "${OUT}" | tail -1)" = "fi" ] || fail "settled: the guard does not close the file"
ST_HOME="${WORK_DIR}/st-home"; ST_LOG="${WORK_DIR}/st-yabai.log"; ST_STUB="${WORK_DIR}/st-stub"
mkdir -p "${ST_HOME}/bin" "${ST_HOME}/.config/gallery/state" "${ST_STUB}"
ln -sf "${GALLERY_BIN}" "${ST_HOME}/bin/gallery"
printf '#!/bin/sh\necho "yabai $*" >> "%s"\n' "${ST_LOG}" > "${ST_STUB}/yabai"; chmod +x "${ST_STUB}/yabai"
printf '%s\n' "${OUT}" > "${WORK_DIR}/st-rules.local"
st() {  # st <session age> [force]: source the generated file as yabairc does
  : > "${ST_LOG}"
  HOME="${ST_HOME}" PATH="${ST_STUB}:${PATH}" GALLERY_SESSION_ID=88 GALLERY_SESSION_AGE="$1" \
    GALLERY_HOME_FORCE="${2:-}" sh -c ". '${WORK_DIR}/st-rules.local'"
}
st 30
grep -q "rule --add label=home-mail" "${ST_LOG}" || fail "settled: a fresh login did not load the homes"
echo 88 > "${ST_HOME}/.config/gallery/state/home-login-done"
st 30
[ -s "${ST_LOG}" ] && fail "settled: homes loaded after the login pass: $(tr '\n' '|' < "${ST_LOG}")"
st 30 1
grep -q "rule --add label=home-mail" "${ST_LOG}" || fail "settled: GALLERY_HOME_FORCE did not load the homes"
rm -f "${ST_HOME}/.config/gallery/state/home-login-done"
st 99999
[ -s "${ST_LOG}" ] && fail "settled: homes loaded in a session past the login pass"
HOME="${ST_HOME}" GALLERY_SESSION_ID=88 GALLERY_SESSION_AGE=30 "${GALLERY_BIN}" home _settled \
  && fail "settled: _settled said yes in a fresh login"
HOME="${ST_HOME}" GALLERY_SESSION_ID=88 GALLERY_SESSION_AGE=99999 "${GALLERY_BIN}" home _settled \
  || fail "settled: _settled said no in an old session"
say "homes load only while logging in (or forced by home apply); _settled answers"

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
grep -q "layout place --file ${LP_HOME}/.config/yabai/home-layout.json" "${LP_CALLS}" || fail "login pass: the windows were not placed on their saved Desktops"
[ "$(sed -n 1p "${LP_CALLS}" | cut -d' ' -f2)" = "place" ] || fail "login pass: placement must come before the shapes"
[ "$(cat "${LP_HOME}/.config/gallery/state/home-login-done")" = 4242 ] || fail "login pass: the session was not marked done"
grep -q "signal --remove home-keep-here" "${LP_LOG}" || fail "login pass: the homes were not unloaded once done"
grep -q "gallery bg apply" "${LP_CALLS}" || fail "login pass: a Desktop with an old wallpaper was not re-synced"
store "file:///a.jpg"; lp2
grep -q "gallery bg apply" "${LP_CALLS}" && fail "login pass: re-applied the wallpaper although every Desktop matched"
rm -f "${LP_HOME}/.config/yabai/home-layout.json"; lp2
grep -q "layout restore" "${LP_CALLS}" && fail "login pass: restored shapes without a saved layout"
say "login pass: windows placed, then tile shapes restored; wallpaper re-applied only when a Desktop differs"

# --- reopening the apps (gallery home reopen) -------------------------------
# A stub yabai answers from a live window file; a stub `open` logs the launch
# and adds that app's window to it; a stub `ps` names each pid's executable.
RO_HOME="${WORK_DIR}/ro-home"; RO_STUB="${WORK_DIR}/ro-stub"; RO_LIVE="${WORK_DIR}/ro-live.json"
RO_OPENS="${WORK_DIR}/ro-opens.log"; RO_LOG="${RO_HOME}/.config/gallery/gallery-home.log"
mkdir -p "${RO_HOME}/.config/gallery/state" "${RO_HOME}/.config/yabai" "${RO_STUB}"
cat > "${RO_STUB}/yabai" <<EOF
#!/bin/sh
case "\$*" in
  "-m query --windows") cat "${RO_LIVE}" ;;
esac
exit 0
EOF
cat > "${RO_STUB}/open" <<EOF
#!/bin/sh
echo "open \$*" >> "${RO_OPENS}"
eval "app=\\\${\$#}"; app="\$(basename "\${app}" .app)"
[ "\${app}" = iTerm ] && app=iTerm2
[ "\${app}" = Silent ] && exit 0
python3 -c 'import json, sys
ws = json.load(open(sys.argv[1]))
ws.append({"id": 900 + len(ws), "app": sys.argv[2], "space": 1, "has-ax-reference": True})
json.dump(ws, open(sys.argv[1], "w"))' "${RO_LIVE}" "\${app}"
EOF
RO_APPS="${WORK_DIR}/Apps"; mkdir -p "${RO_APPS}/Mail.app" "${RO_APPS}/iTerm.app"
cat > "${RO_STUB}/ps" <<EOF
#!/bin/sh
case "\$4" in
  11) echo "${RO_APPS}/Mail.app/Contents/MacOS/Mail" ;;
  12) echo "${RO_APPS}/iTerm.app/Contents/MacOS/iTerm2" ;;
  13) echo "/usr/libexec/helper" ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' > "${RO_STUB}/layout-tool"
chmod +x "${RO_STUB}/yabai" "${RO_STUB}/open" "${RO_STUB}/ps" "${RO_STUB}/layout-tool"
ro() {  # ro <args...>: the gallery CLI in the reopen sandbox
  GALLERY_RUNNING_BUNDLES="${RO_RUNNING:-}" HOME="${RO_HOME}" PATH="${RO_STUB}:${PATH}" \
    GALLERY_OPEN_BIN="${GALLERY_OPEN_BIN:-${RO_STUB}/open}" GALLERY_LSREGISTER="${GALLERY_LSREGISTER:-/nonexistent}" \
    GALLERY_LAYOUT_TOOL="${RO_STUB}/layout-tool" GALLERY_DEFAULTS_BIN="${REPO_ROOT}/tests/fake-defaults" \
    GALLERY_HOME_POLL=1 GALLERY_HOME_REOPEN_WAIT=3 GALLERY_SESSION_ID=66 GALLERY_SESSION_AGE=999999 \
    "${GALLERY_BIN}" "$@"
}
rwin() {  # rwin <id> <app> <pid> <space>
  printf '{"id": %s, "app": "%s", "title": "t%s", "pid": %s, "space": %s, "subrole": "AXStandardWindow", "is-floating": false, "has-ax-reference": true}' "$1" "$2" "$1" "$3" "$4"
}
printf '[%s, %s, %s]' "$(rwin 1 Mail 11 2)" "$(rwin 2 iTerm2 12 3)" "$(rwin 3 Helper 13 3)" > "${RO_LIVE}"
ro home save >/dev/null
python3 - "${RO_HOME}/.config/yabai/home-apps.json" "${RO_APPS}" <<'PY' || fail "reopen: home save did not record the app bundles"
import json, sys
d = json.load(open(sys.argv[1]))
assert d == {"Mail": sys.argv[2] + "/Mail.app", "iTerm2": sys.argv[2] + "/iTerm.app"}, d
PY
printf '[%s]' "$(rwin 1 Mail 99 2)" > "${RO_LIVE}"
ro home save >/dev/null
grep -q iTerm.app "${RO_HOME}/.config/yabai/home-apps.json" || fail "reopen: a save forgot the bundle of an app that is closed now"
say "reopen: home save records each app's bundle and keeps those of closed apps"

# The saved desktop: Mail (Desktop 2), iTerm2 x2 + Finder + Silent (Desktop 3), Notes (Desktop 10).
cat > "${RO_HOME}/.config/yabai/home-layout.json" <<'EOF'
{"spaces": {"10": {"windows": [{"app": "Notes"}]},
            "2": {"windows": [{"app": "Mail"}]},
            "3": {"windows": [{"app": "iTerm2"}, {"app": "iTerm2"}, {"app": "Finder"}, {"app": "Silent"}]}}}
EOF
echo '[]' > "${RO_LIVE}"
[[ "$(ro home reopen)" == *"reopening off"* ]] || fail "reopen: not off by default"
out="$(ro home reopen status)"
printf '%s\n' "${out}" | grep -q "Mail (1 windows) ${RO_APPS}/Mail.app" || fail "reopen: status does not list Mail: ${out}"
printf '%s\n' "${out}" | grep -q "Finder" && fail "reopen: Finder is on the skip list"
printf '%s\n' "${out}" | grep -q "Close windows when quitting" || fail "reopen: status does not show the macOS setting"
echo "Notes  # not this one" > "${RO_HOME}/.config/gallery/home-reopen-skip"
[[ "$(ro home reopen status)" == *Notes* ]] && fail "reopen: home-reopen-skip was ignored"
say "reopen: off by default; status lists the saved apps not open, minus the skip list"

# The login pass with reopening off starts nothing.
printf '#!/bin/sh\n' > "${RO_HOME}/.config/yabai/rules.local"
lpro() {  # lpro [locked]: the login pass in a fresh session
  rm -f "${RO_HOME}/.config/gallery/state/home-login-pass" "${RO_HOME}/.config/gallery/state/home-login-done"
  : > "${RO_OPENS}"; echo '[]' > "${RO_LIVE}"
  GALLERY_RUNNING_BUNDLES="" HOME="${RO_HOME}" PATH="${RO_STUB}:${PATH}" GALLERY_OPEN_BIN="${RO_STUB}/open" \
    GALLERY_LAYOUT_TOOL="${RO_STUB}/layout-tool" GALLERY_SESSION_ID=67 GALLERY_SESSION_AGE=30 \
    GALLERY_IDLE_SECONDS=60 GALLERY_HOME_POLL=1 GALLERY_HOME_QUIET_FOR=2 GALLERY_HOME_QUIET_TIMEOUT="${2:-8}" \
    GALLERY_HOME_REOPEN_WAIT=3 GALLERY_HOME_SETTLE=0 GALLERY_SCREEN_LOCKED="${1:-0}" \
    GALLERY_WALLPAPER_STORE=/nonexistent "${GALLERY_BIN}" home _login-pass
}
lpro
[ -s "${RO_OPENS}" ] && fail "reopen: the login pass started apps with reopening off"
[[ "$(ro home reopen on)" == *"reopening on"* ]] || fail "reopen: on did not confirm"
[ -f "${RO_HOME}/.config/gallery/state/home-reopen" ] || fail "reopen: on did not write the per-Mac switch"
lpro 1 3
[ -s "${RO_OPENS}" ] && fail "reopen: started apps behind the lock screen"
grep -q "screen stayed locked" "${RO_LOG}" || fail "reopen: giving up behind the lock was not logged"
lpro
[ "$(cat "${RO_OPENS}")" = "open -g ${RO_APPS}/Mail.app
open -g ${RO_APPS}/iTerm.app
open -g -a Silent" ] || fail "reopen: wrong launches or order: $(tr '\n' '|' < "${RO_OPENS}")"
grep -q "reopen: iTerm2: 2 of 2 windows\|reopen: iTerm2: 1 of 2 windows" "${RO_LOG}" || fail "reopen: iTerm2's wait was not logged"
grep -q "reopen: Silent: 0 of 1 windows after 3s" "${RO_LOG}" || fail "reopen: an app without windows did not time out"
grep -q "reopen: started 3 apps" "${RO_LOG}" || fail "reopen: the total was not logged"
[ "$(cat "${RO_HOME}/.config/gallery/state/home-login-done")" = 67 ] || fail "reopen: the pass did not go on to place the windows"
say "reopen: the login pass starts the saved apps one by one, only when on and unlocked, then places them"

# An app already open is left alone; so is one running without a window.
printf '[%s]' "$(rwin 1 Mail 11 2)" > "${RO_LIVE}"; : > "${RO_OPENS}"
ro home reopen now >/dev/null
grep -q Mail.app "${RO_OPENS}" && fail "reopen: started an app that was open already"
grep -q iTerm.app "${RO_OPENS}" || fail "reopen: now did not start a missing app"
: > "${RO_OPENS}"; echo '[]' > "${RO_LIVE}"
RO_RUNNING="${RO_APPS}/iTerm.app" ro home reopen now >/dev/null
grep -q iTerm.app "${RO_OPENS}" && fail "reopen: started an app running without a window"
[[ "$(ro home reopen off)" == *"reopening off"* ]] || fail "reopen: off did not confirm"
[ -f "${RO_HOME}/.config/gallery/state/home-reopen" ] && fail "reopen: off left the switch"
# Started by name where no save recorded the bundle; when `open -a` does not
# know the name (iTerm2 is iTerm.app), Launch Services names the bundle.
mkdir -p "${RO_APPS}/Bundled.app"
cat > "${RO_STUB}/lsregister" <<EOF
#!/bin/sh
printf 'path:  /nowhere/Other.app (0x1)\nname:  Other\npath:  ${RO_APPS}/Bundled.app (0x2)\nname:  ByName\n'
EOF
cat > "${RO_STUB}/open-byname" <<EOF
#!/bin/sh
echo "open \$*" >> "${RO_OPENS}"
[ "\$2" = -a ] && exit 1
exit 0
EOF
chmod +x "${RO_STUB}/lsregister" "${RO_STUB}/open-byname"
echo '{"spaces": {"1": {"windows": [{"app": "ByName"}]}}}' > "${RO_HOME}/.config/yabai/home-layout.json"
: > "${RO_OPENS}"; echo '[]' > "${RO_LIVE}"
GALLERY_LSREGISTER="${RO_STUB}/lsregister" GALLERY_OPEN_BIN="${RO_STUB}/open-byname" ro home reopen now >/dev/null
[ "$(cat "${RO_OPENS}")" = "open -g -a ByName
open -g ${RO_APPS}/Bundled.app" ] || fail "reopen: no Launch Services fallback: $(tr '\n' '|' < "${RO_OPENS}")"
say "reopen: open apps left alone; off removes the switch; unknown names found through Launch Services"

# --- automatic save (gallery home _autosave) --------------------------------
# A stub `gallery` (GALLERY_SELF) stands in for `home save` and writes the
# files a real save writes; the window list comes from GALLERY_HOME_WINDOWS_JSON.
AS_HOME="${WORK_DIR}/as-home"; AS_LOG="${AS_HOME}/.config/gallery/gallery-home.log"
AS_CALLS="${WORK_DIR}/as-calls.log"
mkdir -p "${AS_HOME}/.config/gallery/state" "${AS_HOME}/.config/yabai"
cat > "${LP_STUB}/as-gallery" <<EOF
#!/bin/sh
echo "gallery \$*" >> "${AS_CALLS}"
echo rules > "${AS_HOME}/.config/yabai/rules.local"
printf '{"spaces": {"1": {"windows": [{"id": 1}, {"id": 2}, {"id": 3}, {"id": 4}]}}}' > "${AS_HOME}/.config/yabai/home-layout.json"
echo "home: 3 apps pinned, 0 windows pinned by title, roaming: iTerm2 -> /x"
EOF
chmod +x "${LP_STUB}/as-gallery"
win() {  # win <id> <app> <title> <space>
  printf '{"id": %s, "app": "%s", "title": "%s", "space": %s, "is-minimized": false}' "$1" "$2" "$3" "$4"
}
printf '[%s, %s, %s, %s]' "$(win 1 Mail Inbox 2)" "$(win 2 iTerm2 zsh 3)" "$(win 3 Notes N 4)" "$(win 4 Safari Docs 5)" > "${WORK_DIR}/as4.json"
printf '[%s, %s, %s, %s]' "$(win 1 Mail Inbox 2)" "$(win 2 iTerm2 zsh 6)" "$(win 3 Notes N 4)" "$(win 4 Safari Docs 5)" > "${WORK_DIR}/as4b.json"
printf '[%s, %s]' "$(win 1 Mail Inbox 2)" "$(win 2 iTerm2 zsh 3)" > "${WORK_DIR}/as2.json"
printf '[%s, %s, %s]' "$(win 1 Mail "" 2)" "$(win 2 iTerm2 "" 3)" "$(win 3 Notes N 4)" > "${WORK_DIR}/asblank.json"
as() {  # as <reason> <windows file> <session age>
  : > "${AS_CALLS}"
  HOME="${AS_HOME}" PATH="${LP_STUB}:${PATH}" GALLERY_SELF="${LP_STUB}/as-gallery" GALLERY_SESSION_ID=77 \
    GALLERY_SESSION_AGE="$3" GALLERY_HOME_WINDOWS_JSON="$2" "${GALLERY_BIN}" home _autosave "$1"
}
saved() { grep -q "home save --keep-absent" "${AS_CALLS}"; }

as periodic "${WORK_DIR}/as4.json" 60
saved && fail "autosave: saved before the login pass put the windows back"
grep -q "login pass has not put the windows back" "${AS_LOG}" || fail "autosave: the skip was not logged"
as periodic "${WORK_DIR}/as4.json" 60
[ "$(grep -c "login pass has not" "${AS_LOG}")" = 1 ] || fail "autosave: a repeated skip was logged again"
as periodic "${WORK_DIR}/as4.json" 9000
saved || fail "autosave: did not save in an old session whose pass never finished"
echo 77 > "${AS_HOME}/.config/gallery/state/home-login-done"
rm -f "${AS_HOME}/.config/gallery/state/home-autosave-sig"
as periodic "${WORK_DIR}/as4.json" 60
saved || fail "autosave: did not save once the login pass was done"
[ -f "${AS_HOME}/.config/yabai/home-history/$(date +%Y-%m-%d)/rules.local" ] || fail "autosave: no dated history copy"
grep -q "autosave (periodic): home: 3 apps pinned" "${AS_LOG}" || fail "autosave: the save was not logged"
as periodic "${WORK_DIR}/as4.json" 60
saved && fail "autosave: saved an unchanged desktop again"
sed 's/"zsh"/"claude: thinking"/' "${WORK_DIR}/as4.json" > "${WORK_DIR}/as4t.json"
as periodic "${WORK_DIR}/as4t.json" 60
saved && fail "autosave: a title change alone counted as a change"
as sleep "${WORK_DIR}/as4b.json" 60
saved || fail "autosave: a window moved to another Desktop was not saved"
as periodic "${WORK_DIR}/as2.json" 60
saved && fail "autosave: saved with only 2 windows open"
as periodic "${WORK_DIR}/asblank.json" 60
saved && fail "autosave: saved a desktop of title-less windows"
python3 -c 'import json; print(json.dumps({"spaces": {"1": {"windows": [{"id": i} for i in range(10)]}}}))' \
  > "${AS_HOME}/.config/yabai/home-layout.json"
as poweroff "${WORK_DIR}/as4.json" 60
saved && fail "autosave: a shutdown with apps quitting shrank the saved desktop"
grep -q "apps quitting" "${AS_LOG}" || fail "autosave: the shutdown skip was not logged"
as periodic "${WORK_DIR}/as4.json" 60
saved || fail "autosave: the shrink guard must only apply at shutdown"
touch "${AS_HOME}/.config/gallery/state/paused"
rm -f "${AS_HOME}/.config/gallery/state/home-autosave-sig"
as periodic "${WORK_DIR}/as4.json" 60
saved && fail "autosave: saved while the Gallery is off"
say "autosave: after the login pass, only on change, never scattered, title-less, half-closed or off; history kept"

say "PASS home_test.sh"
