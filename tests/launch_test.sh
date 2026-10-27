#!/usr/bin/env bash
#
# launch_test.sh -- offline test of the app keys (tiler/app-focus) and super+b
# (tiler/browser-window) on a desktop of many Desktops over two displays.
#
# The faults behind it (2026-10-27): an app key pressed on an empty Desktop
# did nothing while the app was open on another Desktop (`open -a` only
# activates it, and macOS was set not to follow an activated app), and a new
# browser window went to the browser's home Desktop instead of the one in view
# (that half is the home-keep-here signal, tested in home_test.sh).
#
# Entirely offline: yabai, open, osascript and lsappinfo are stubs earlier on
# PATH that serve a fixture desktop and log every call, so no app is started
# and no window is focused. A stub `open` can run a hook, standing in for the
# app starting or making its window.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_FOCUS="${REPO_ROOT}/tiler/app-focus"
BROWSER="${REPO_ROOT}/tiler/browser-window"

say() { echo "[launch_test] $*"; }
fail() { echo "[launch_test] FAIL: $*" >&2; exit 1; }

[ -x "${APP_FOCUS}" ] || fail "${APP_FOCUS} not found or not executable"
[ -x "${BROWSER}" ] || fail "${BROWSER} not found or not executable"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gallery-launch-test.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
STUB="${WORK}/stub"
ST="${WORK}/state"     # running: "<bundle id> <pid>" lines; windows.json; names
LOG="${WORK}/calls.log"
mkdir -p "${STUB}" "${ST}" "${WORK}/home"

# --- stubs -------------------------------------------------------------------
cat > "${STUB}/yabai" <<EOF
#!/bin/sh
echo "yabai \$*" >> "${LOG}"
case "\$*" in
  "-m query --windows") cat "${ST}/windows.json" ;;
esac
exit 0
EOF
cat > "${STUB}/lsappinfo" <<EOF
#!/bin/sh
case "\$1" in
  find) bid="\${2#bundleid=}"
        awk -v b="\${bid}" '\$1 == b { print "ASN:" \$2 ":" }' "${ST}/running" ;;
  info) pid="\${4#ASN:}"; pid="\${pid%:}"; echo "    pid = \${pid} !cgsConnection" ;;
esac
exit 0
EOF
# open logs, then runs the hook once (the app starting, or making a window).
cat > "${STUB}/open" <<EOF
#!/bin/sh
echo "open \$*" >> "${LOG}"
if [ -x "${ST}/on-open" ]; then "${ST}/on-open"; rm -f "${ST}/on-open"; fi
exit 0
EOF
cat > "${STUB}/osascript" <<EOF
#!/bin/sh
echo "osascript \$*" >> "${LOG}"
case "\$*" in
  *"id of application"*)
    name=\$(printf '%s' "\$*" | sed -E 's/.*application "([^"]+)".*/\1/')
    awk -F '\t' -v n="\${name}" '\$1 == n { print \$2 }' "${ST}/names" ;;
  *" is running"*)
    bid=\$(printf '%s' "\$*" | sed -E 's/.*application id "([^"]+)".*/\1/')
    if awk -v b="\${bid}" '\$1 == b { f = 1 } END { exit !f }' "${ST}/running"; then echo true; else echo false; fi ;;
esac
exit 0
EOF
chmod +x "${STUB}"/*

printf 'Telegram\tru.keepcoder.Telegram\nCalendar\tcom.apple.iCal\nBartender\tcom.surteesstudios.Bartender\n' > "${ST}/names"

# win <id> <pid> <space> <display> [visible minimized hidden subrole]
win() {
  printf '{"id": %s, "pid": %s, "space": %s, "display": %s, "is-visible": %s, "is-minimized": %s, "is-hidden": %s, "subrole": "%s"}' \
    "$1" "$2" "$3" "$4" "${5:-false}" "${6:-false}" "${7:-false}" "${8:-AXStandardWindow}"
}
windows() { local IFS=,; printf '[%s]\n' "$*" > "${ST}/windows.json"; }
running() { printf '%s\n' "$@" > "${ST}/running"; }
reset() { : > "${LOG}"; rm -f "${ST}/on-open"; }
run_af() { PATH="${STUB}:${PATH}" APP_FOCUS_WAIT=1 "${APP_FOCUS}" "$@"; }
logged() { grep -qF -- "$1" "${LOG}"; }
expect() { logged "$1" || fail "$2 -- expected '$1' in: $(tr '\n' '|' < "${LOG}")"; }
reject() { if logged "$1"; then fail "$2 -- unexpected '$1' in: $(tr '\n' '|' < "${LOG}")"; fi; }

# The desktop: Desktops 1-9 on display 1, 10-13 on display 2; the user is
# looking at the empty Desktop 5 (and 10 on the other display). An iTerm2
# window (pid 50) is there to show a window of another app is never picked.
ITERM="$(win 900 50 3 1)"

# --- T4: running, its window on another Desktop of the same display ----------
reset; running "ru.keepcoder.Telegram 580"
windows "${ITERM}" "$(win 581 580 2 1)"
run_af Telegram
expect "yabai -m window --focus 581" "T4: the window on another Desktop is focused"
reject "open " "T4: a running app with a window is not re-opened"
say "T4 app key on an empty Desktop focuses the app's window on another Desktop"

# --- T5: its only window on the second display -------------------------------
reset; windows "${ITERM}" "$(win 582 580 12 2)"
run_af Telegram
expect "yabai -m window --focus 582" "T5: the window on the second display is focused"
say "T5 ... and on the second display"

# --- a window already in view wins over one on a hidden Desktop --------------
reset; windows "$(win 583 580 7 1)" "$(win 584 580 10 2 true)"
run_af Telegram
expect "yabai -m window --focus 584" "the window in view is preferred"
say "a window on a Desktop in view is preferred"

# --- minimized: brought back, then focused -----------------------------------
reset; windows "$(win 585 580 4 1 false true)"
run_af Telegram
expect "yabai -m window 585 --deminimize" "a minimized window is deminimized"
expect "yabai -m window --focus 585" "a minimized window is focused"
say "a minimized window is brought back and focused"

# --- hidden (Cmd-H): unhidden through open first -----------------------------
reset; windows "$(win 586 580 4 1 false false true)"
run_af Telegram
expect "open -a Telegram" "a hidden app is unhidden"
expect "yabai -m window --focus 586" "a hidden app's window is focused"
say "a hidden app is unhidden and its window focused"

# --- T6: running with no window (closed to the Dock) -------------------------
# open's reopen makes the window -- a home rule may put it anywhere -- and the
# view follows it.
reset; windows "${ITERM}" "$(win 587 580 0 1 false false false AXFloatingWindow)"
printf '#!/bin/sh\nprintf %s > "%s"\n' "'[{\"id\": 588, \"pid\": 580, \"space\": 11, \"display\": 2, \"is-visible\": false, \"is-minimized\": false, \"is-hidden\": false, \"subrole\": \"AXStandardWindow\"}]'" "${ST}/windows.json" > "${ST}/on-open"
chmod +x "${ST}/on-open"
run_af Telegram
expect "open -a Telegram" "T6: an app with no window is reopened"
expect "yabai -m window --focus 588" "T6: the new window is followed"
reject "yabai -m window --focus 587" "T6: a non-standard window is never picked"
say "T6 running without a window: reopened, and the view follows the new window"

# --- not running: started, its first window followed to its home Desktop -----
reset; running ""; windows "${ITERM}"
cat > "${ST}/on-open" <<EOF
#!/bin/sh
echo "ru.keepcoder.Telegram 590" > "${ST}/running"
printf '[{"id": 591, "pid": 590, "space": 10, "display": 2, "subrole": "AXStandardWindow"}]' > "${ST}/windows.json"
EOF
chmod +x "${ST}/on-open"
run_af Telegram
expect "open -a Telegram" "a cold app is started"
expect "yabai -m window --focus 591" "a cold app's first window is followed"
say "not running: started, and its first window is followed"

# --- a menu-bar app that never shows a window: gives up quietly --------------
reset; running "com.surteesstudios.Bartender 600"; windows "${ITERM}"
start=$(date +%s)
run_af Bartender || fail "app-focus failed for an app without windows"
[ $(( $(date +%s) - start )) -le 4 ] || fail "app-focus waited past APP_FOCUS_WAIT"
expect "open -a Bartender" "a windowless app is still opened"
reject "--focus" "nothing is focused when no window appears"
say "an app that never shows a window: opened, then the wait ends"

# --- a path, as the web-app keys pass it ------------------------------------
mkdir -p "${WORK}/Apps/Gmail.app/Contents"
cat > "${WORK}/Apps/Gmail.app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.apple.Safari.WebApp.TEST</string></dict></plist>
EOF
reset; running "com.apple.Safari.WebApp.TEST 610"; windows "$(win 611 610 2 1)"
run_af "${WORK}/Apps/Gmail.app"
expect "yabai -m window --focus 611" "a path resolves to its bundle's windows"
say "a .app path resolves through its Info.plist"

# --- an app nobody can name: plain open -a -----------------------------------
reset
run_af "No Such App"
expect "open -a No Such App" "an unknown app falls back to open -a"
reject "yabai" "an unknown app never queries yabai"
say "an unresolvable app falls back to open -a"

# --- the keys: every shipped app key goes through app-focus ------------------
if grep -nE '^[^#].*: *open -a ' "${REPO_ROOT}/tiler/tiler.skhd" | grep -v 'lalt - return'; then
  fail "tiler.skhd still binds an app key to plain open -a"
fi
grep -qE '^lalt - c : "\$HOME/\.config/skhd/app-focus" Calendar$' "${REPO_ROOT}/tiler/tiler.skhd" \
  || fail "super+c is not bound through app-focus"
if grep -nE '^#(shift \+ )?lalt - [a-z] : open -a ' "${REPO_ROOT}/tiler/local.skhd.example" | grep -v 'Visual Studio Code'; then
  fail "local.skhd.example still suggests plain open -a for an app slot"
fi
grep -q 'gl_install_file app-focus "\$SKHD_DIR/app-focus" 755' "${REPO_ROOT}/tiler/install.sh" \
  || fail "tiler/install.sh does not install app-focus"
grep -q '"\$SKHD_DIR/app-focus"' <(sed -n '/for f in "\$YABAI_RC"/p' "${REPO_ROOT}/tiler/install.sh") \
  || fail "tiler/install.sh --uninstall does not remove app-focus"
say "the shipped and example app keys use app-focus; installed and uninstalled"

# --- super+b ---------------------------------------------------------------------
# handlers <bundle id>: the https handler in a fake LaunchServices plist.
handlers() {
  local d="${WORK}/home/Library/Preferences/com.apple.LaunchServices"
  mkdir -p "${d}"
  python3 - "${d}/com.apple.launchservices.secure.plist" "$1" <<'PY'
import plistlib, sys
with open(sys.argv[1], "wb") as fh:
    plistlib.dump({"LSHandlers": [{"LSHandlerURLScheme": "https", "LSHandlerRoleAll": sys.argv[2]}]}, fh)
PY
}
run_b() { HOME="${WORK}/home" PATH="${STUB}:${PATH}" APP_FOCUS_WAIT=1 "${BROWSER}"; }

# T2: running Safari, its windows on its home Desktop: asked for a new window,
# which the browser makes on the Desktop in view; no open, no Desktop switch.
reset; rm -rf "${WORK}/home/Library"
running "com.apple.Safari 700"; windows "$(win 701 700 10 2)"
run_b
expect 'osascript -e tell application id "com.apple.Safari" -e make new document -e activate -e end tell' "T2: Safari is asked for a new document"
reject "open " "T2: a running Safari is not re-opened"
reject "--focus 701" "T2: the old window on another Desktop is not focused"
say "T2 running Safari (default when no handler is set): a new window here"

reset; handlers com.google.Chrome; running "com.google.Chrome 710"; windows "$(win 711 710 10 2)"
run_b
expect 'make new window' "T2: Chrome is asked for a new window"
say "T2 running Chrome: make new window"

reset; handlers org.mozilla.firefox; running "org.mozilla.firefox 720"; windows "$(win 721 720 10 2)"
run_b
expect "open -b org.mozilla.firefox" "T2: another browser is activated"
expect 'keystroke "n" using command down' "T2: another browser gets Cmd-N"
say "T2 running Firefox: activated and sent Cmd-N"

# T3: not running: started, and its first window followed wherever it lands.
reset; handlers com.apple.Safari; running ""; windows "${ITERM}"
cat > "${ST}/on-open" <<EOF
#!/bin/sh
echo "com.apple.Safari 730" > "${ST}/running"
printf '[{"id": 731, "pid": 730, "space": 10, "display": 2, "subrole": "AXStandardWindow"}]' > "${ST}/windows.json"
EOF
chmod +x "${ST}/on-open"
run_b
expect "open -b com.apple.Safari" "T3: a cold browser is started"
expect "yabai -m window --focus 731" "T3: its first window is followed"
reject "make new document" "T3: a cold browser is not asked for a second window"
say "T3 browser not running: started, and the view follows its first window"

say "PASS launch_test.sh"
