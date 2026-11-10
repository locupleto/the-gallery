#!/usr/bin/env bash
#
# space_focus_test.sh -- offline test of tiler/space-focus, which hands focus
# to a Desktop the Space keys just brought into view.
#
# The fault behind it (2026-11-10): switching the second display to another
# Desktop left focus on the first display, so the agent key (and super+return)
# opened the new window there instead of on the Desktop in view.
#
# Entirely offline: yabai is a stub serving a fixture desktop and logging every
# call, so nothing is focused for real.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SF="${REPO_ROOT}/tiler/space-focus"

say() { echo "[space_focus_test] $*"; }
fail() { echo "[space_focus_test] FAIL: $*" >&2; exit 1; }

[ -x "${SF}" ] || fail "${SF} not found or not executable"
command -v jq >/dev/null || fail "jq is needed"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gallery-space-focus-test.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
STUB="${WORK}/stub"; ST="${WORK}/state"; LOG="${WORK}/calls.log"
mkdir -p "${STUB}" "${ST}"

# Fixture: Space 3 on display 1; Space 13 (empty) and 15 on display 2.
# ST/visible names the Spaces in view; ST/focused the focused window's Space.
cat > "${STUB}/yabai" <<STUBEOF
#!/bin/sh
echo "yabai \$*" >> "${LOG}"
case "\$*" in
  "-m query --spaces --space "*)
    s=\${5}; d=1; [ "\$s" -ge 10 ] && d=2
    v=false; grep -qx "\$s" "${ST}/visible" && v=true
    printf '{"index":%s,"display":%s,"is-visible":%s}' "\$s" "\$d" "\$v" ;;
  "-m query --windows --window")
    [ -s "${ST}/focused" ] || exit 1
    printf '{"id":1,"space":%s}' "\$(cat "${ST}/focused")" ;;
  "-m query --windows --space 15")
    printf '[{"id":71,"is-visible":false,"is-minimized":true,"is-hidden":false},{"id":72,"is-visible":true,"is-minimized":false,"is-hidden":false},{"id":73,"is-visible":true,"is-minimized":false,"is-hidden":false}]' ;;
  "-m query --windows --space "*) printf '[]' ;;
esac
exit 0
STUBEOF
chmod +x "${STUB}/yabai"
export PATH="${STUB}:${PATH}"

run() { : > "${LOG}"; SPACE_FOCUS_TRIES=3 "${SF}" "$@"; }

# 1. A Desktop with windows: its front window in view is focused.
echo 3 > "${ST}/visible"; echo 15 >> "${ST}/visible"; echo 3 > "${ST}/focused"
run 15
grep -qx "yabai -m window --focus 72" "${LOG}" || fail "did not focus the front visible window of Space 15"
grep -q "display --focus" "${LOG}" && fail "focused the display although Space 15 has a window"
say "a Desktop with windows: its front window takes focus"

# 2. An empty Desktop: its display is focused.
echo 3 > "${ST}/visible"; echo 13 >> "${ST}/visible"
run 13
grep -qx "yabai -m display --focus 2" "${LOG}" || fail "did not focus display 2 for the empty Space 13"
say "an empty Desktop: its display takes focus"

# 3. Focus already on the Desktop: nothing is touched.
echo 15 > "${ST}/focused"; echo 15 > "${ST}/visible"
run 15
grep -q -- "--focus" "${LOG}" && fail "moved focus that was already on the Desktop"
say "focus already there: left alone"

# 4. The Desktop never comes into view: gives up quietly, focuses nothing.
echo 3 > "${ST}/visible"
run 15 || fail "a Desktop that never came into view made it fail"
grep -q -- "--focus" "${LOG}" && fail "focused something although the Desktop never came into view"
say "a Desktop that never appears: no focus change"

# 5. Bad arguments.
if SPACE_FOCUS_TRIES=1 "${SF}" 2>/dev/null; then fail "accepted no argument"; fi
if SPACE_FOCUS_TRIES=1 "${SF}" x 2>/dev/null; then fail "accepted a non-number"; fi
say "rejects a missing or non-numeric index"

# 6. The keys and the installer.
for n in 1 2 3 4 5 6 7 8 9; do
  grep -qxF "lalt - ${n} : skhd -k \"ctrl - ${n}\"; \"\$HOME/.config/skhd/space-focus\" ${n}" "${REPO_ROOT}/tiler/tiler.skhd" \
    || fail "super+${n} does not call space-focus"
done
grep -q 'gl_install_file space-focus "\$SKHD_DIR/space-focus" 755' "${REPO_ROOT}/tiler/install.sh" \
  || fail "tiler/install.sh does not install space-focus"
grep -q '"\$SKHD_DIR/space-focus"' <(sed -n '/for f in "\$YABAI_RC"/p' "${REPO_ROOT}/tiler/install.sh") \
  || fail "tiler/install.sh --uninstall does not remove space-focus"
say "super+1..9 call it; installed and uninstalled"
say "PASS"
