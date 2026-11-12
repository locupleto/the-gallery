#!/usr/bin/env bash
#
# window_here_test.sh -- offline test of tiler/window-here, which brings a
# window that comes back on a Desktop out of view to the Desktop in view.
#
# The fault behind it (2026-11-12): Screen Sharing only hides a closed window,
# still tied to the Desktop it was closed on. Started again from another
# Desktop, the window came back over there and macOS dragged the view along.
#
# Entirely offline: yabai is a stub serving a fixture desktop and logging every
# call, so nothing is moved or focused for real.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WH="${REPO_ROOT}/tiler/window-here"

say() { echo "[window_here_test] $*"; }
fail() { echo "[window_here_test] FAIL: $*" >&2; exit 1; }

[ -x "${WH}" ] || fail "${WH} not found or not executable"
command -v jq >/dev/null || fail "jq is needed"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gallery-window-here-test.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
STUB="${WORK}/stub"; ST="${WORK}/state"; LOG="${WORK}/calls.log"
mkdir -p "${STUB}" "${ST}"

# Fixture: window 50 of one app. ST/cur is the Desktop the user is on, ST/wsp
# the window's Desktop, ST/visible the Desktops in view, ST/subrole the
# window's subrole, ST/rules the live rules. ST/drift, when present, is where
# macOS takes the view right after the move; a focus brings it back.
cat > "${STUB}/yabai" <<STUBEOF
#!/bin/sh
echo "yabai \$*" >> "${LOG}"
case "\$*" in
  "-m query --spaces --space")
    printf '{"index":%s}' "\$(cat "${ST}/cur")" ;;
  "-m query --spaces --space "*)
    v=false; grep -qx "\${5}" "${ST}/visible" && v=true
    printf '{"index":%s,"is-visible":%s}' "\${5}" "\$v" ;;
  "-m query --windows --window 50")
    f=false; [ -e "${ST}/focused" ] && f=true
    printf '{"id":50,"pid":4242,"space":%s,"subrole":"%s","has-focus":%s}' \
      "\$(cat "${ST}/wsp")" "\$(cat "${ST}/subrole")" "\$f" ;;
  "-m query --windows --window "*) exit 1 ;;
  "-m rule --list") cat "${ST}/rules" ;;
  "-m window 50 --space "*)
    echo "\${5}" > "${ST}/wsp"
    if [ -e "${ST}/drift" ]; then cat "${ST}/drift" > "${ST}/cur"; rm -f "${ST}/drift"; fi ;;
  "-m window --focus 50")
    cat "${ST}/wsp" > "${ST}/cur"; : > "${ST}/focused" ;;
esac
exit 0
STUBEOF
chmod +x "${STUB}/yabai"
export PATH="${STUB}:${PATH}"

# reset <current Desktop> <window's Desktop>: display 1 shows the current
# Desktop, display 2 shows Desktop 11; an old app, no home rules.
reset() {
  echo "$1" > "${ST}/cur"; echo "$2" > "${ST}/wsp"
  printf '%s\n11\n' "$1" > "${ST}/visible"
  echo AXStandardWindow > "${ST}/subrole"; echo '[]' > "${ST}/rules"
  rm -f "${ST}/focused" "${ST}/drift"
  : > "${LOG}"
}
run() { WINDOW_HERE_APP_AGE="${AGE:-600}" WINDOW_HERE_TRIES=12 "${WH}" "$@"; }
moved() { grep -q -- "-m window 50 --space" "${LOG}"; }

# 1. The fault: the window returns on Desktop 6 while the user is on 8, and
# macOS switches to 6 right after. The window ends on 8, and so does the view.
reset 8 6; echo 6 > "${ST}/drift"
run 50
grep -qx "yabai -m window 50 --space 8" "${LOG}" || fail "did not move the window to the Desktop in view"
[ "$(cat "${ST}/wsp")" = 8 ] || fail "the window is not on Desktop 8"
[ "$(cat "${ST}/cur")" = 8 ] || fail "the view was left on the old Desktop"
[ -e "${ST}/focused" ] || fail "the window did not get focus"
say "a window back on a Desktop out of view: brought here, view and focus with it"

# 2. A window on the Desktop the user is on.
reset 8 8
run 50
moved && fail "moved a window that is already here"
say "a window already here: left alone"

# 3. A window on the other display's Desktop in view.
reset 8 11
run 50
moved && fail "moved a window off the other display"
say "a window on the other display: left alone"

# 4. Not a standard window.
reset 8 6; echo AXDialog > "${ST}/subrole"
run 50
moved && fail "moved a dialog"
say "a dialog: left alone"

# 5. An app that just started puts its windows back where they were.
reset 8 6
AGE=5 run 50
moved && fail "moved a window of an app that just started"
say "a starting app: left alone"

# 6. The home rules are loaded: they place windows on purpose.
reset 8 6; echo '[{"label":"home-safari","app":"^Safari$"},{"label":""}]' > "${ST}/rules"
run 50
moved && fail "moved a window while the home rules are loaded"
say "home rules loaded: left alone"

# 7. A window yabai does not know, and bad arguments.
reset 8 6
run 51 || fail "an unknown window made it fail"
moved && fail "moved something for an unknown window"
if "${WH}" 2>/dev/null; then fail "accepted no argument"; fi
if "${WH}" x 2>/dev/null; then fail "accepted a non-number"; fi
say "an unknown window is ignored; a missing or non-numeric id is rejected"

# 8. The signal and the installer.
grep -q 'label=tiler-window-here event=window_created' "${REPO_ROOT}/tiler/yabairc" \
  || fail "tiler/yabairc does not add the tiler-window-here signal"
grep -q 'gl_install_file window-here "\$YABAI_DIR/window-here" 755' "${REPO_ROOT}/tiler/install.sh" \
  || fail "tiler/install.sh does not install window-here"
grep -q '"\$YABAI_DIR/window-here"' <(sed -n '/for f in "\$YABAI_RC"/p' "${REPO_ROOT}/tiler/install.sh") \
  || fail "tiler/install.sh --uninstall does not remove window-here"
say "the signal is in yabairc; installed and uninstalled"
say "PASS"
