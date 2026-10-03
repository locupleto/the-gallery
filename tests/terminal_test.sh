#!/usr/bin/env bash
#
# terminal_test.sh -- the multi-terminal support: bin/gallery-term (which
# terminal, and the exact commands it would run), the renderer's per-terminal
# theme files, and `gallery terminal` / `gallery console` against throwaway
# config files.
#
# Opens no window and touches no real config: HOME is a temp directory, the
# "installed apps" are empty directories under it (GALLERY_TERM_APP_DIRS),
# gallery-term only ever runs with --dry-run, and the renderer's live reload of
# a running terminal is switched off (GALLERY_NO_TERMINAL_RELOAD).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# `defaults` writes the real preferences whatever $HOME is: a stand-in.
export GALLERY_DEFAULTS_BIN="${SCRIPT_DIR}/fake-defaults"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GALLERY="${REPO_ROOT}/bin/gallery"
TERM_BIN="${REPO_ROOT}/bin/gallery-term"
RENDER="${REPO_ROOT}/tools/render-theme.py"

say()  { echo "[terminal_test] $*"; }
fail() { echo "[terminal_test] FAIL: $*" >&2; exit 1; }

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gallery-terminal-test.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

export HOME="${WORK_DIR}/home"
unset GALLERY_CONFIG_DIR GALLERY_TERMINAL GALLERY_TERM_RUNNING || true
export GALLERY_NO_TERMINAL_RELOAD=1
export GALLERY_TERM_BIN="${TERM_BIN}"
APPS="${WORK_DIR}/apps"
export GALLERY_TERM_APP_DIRS="${APPS}"
CFG="${HOME}/.config/gallery"
mkdir -p "${HOME}" "${APPS}" "${CFG}/themes"

# A current theme for the renderer: a copy of a shipped one, `current` -> it.
cp -R "${REPO_ROOT}/themes/tokyo-night" "${CFG}/themes/tokyo-night"
ln -s tokyo-night "${CFG}/themes/current"

contains() { grep -qF -- "$2" <<<"$1"; }
assert_contains() { contains "$1" "$2" || fail "$3: expected to find: $2
--- got:
$1"; }
assert_lacks() { contains "$1" "$2" && fail "$3: did not expect: $2
--- got:
$1"; return 0; }

# --- 1. which terminal --------------------------------------------------------
[ "$("${TERM_BIN}" name)" = "iterm2" ] || fail "nothing installed: expected iterm2 as the last resort"
mkdir -p "${APPS}/kitty.app" "${APPS}/WezTerm.app"
[ "$("${TERM_BIN}" name)" = "kitty" ] || fail "first installed of ghostty/kitty/wezterm should win"
mkdir -p "${APPS}/iTerm.app"
[ "$("${TERM_BIN}" name)" = "iterm2" ] || fail "iterm2 should win whenever it is installed"
say "default terminal: iterm2 if installed, else the first of ghostty, kitty, wezterm"

# yabai's owner names
for pair in iterm2:iTerm2 ghostty:Ghostty kitty:kitty wezterm:WezTerm; do
  id="${pair%%:*}" app="${pair#*:}"
  [ "$(GALLERY_TERMINAL="${id}" "${TERM_BIN}" app)" = "${app}" ] || fail "app name for ${id} is not ${app}"
done
say "app names match what yabai reports"

# --- 2. list / set -------------------------------------------------------------
out="$("${TERM_BIN}" list)"
assert_contains "${out}" "iterm2    installed (current)" "list marks the current terminal"
assert_contains "${out}" "ghostty   -" "list shows an absent terminal"
assert_contains "${out}" "kitty     installed" "list shows an installed terminal"
if "${TERM_BIN}" set ghostty 2>/dev/null; then fail "set accepted a terminal that is not installed"; fi
if "${TERM_BIN}" set alacritty 2>/dev/null; then fail "set accepted an unsupported terminal"; fi
mkdir -p "${APPS}/Ghostty.app"
out="$("${GALLERY}" terminal set ghostty)"
assert_contains "${out}" "terminal: ghostty" "gallery terminal set"
grep -q '"terminal": "ghostty"' "${CFG}/state/terminal.json" || fail "terminal.json not written"
[ -f "${CFG}/state/terminals/ghostty.conf" ] || fail "set did not re-render the theme"
assert_contains "$("${GALLERY}" terminal)" "terminal: ghostty (Ghostty)" "terminal status"
assert_contains "$("${GALLERY}" terminal list)" "ghostty   installed (current)" "terminal list"
[ "$(GALLERY_TERMINAL=wezterm "${TERM_BIN}" name)" = "wezterm" ] || fail "GALLERY_TERMINAL override"
echo '{"terminal": "bogus"}' > "${CFG}/state/terminal.json"
[ "$("${TERM_BIN}" name)" = "iterm2" ] || fail "an unusable state file should fall back to the default"
say "terminal list / set / status"

# --- 3. gallery-term open --dry-run, every terminal x role x cold|running -------
open_dry() { # terminal role running args...
  local t="$1" r="$2" run="$3"
  shift 3
  GALLERY_TERMINAL="${t}" GALLERY_TERM_RUNNING="${run}" "${TERM_BIN}" open --dry-run --role "${r}" "$@"
}
TERMDIR="${CFG}/state/terminals"

# iTerm2: unchanged shapes. float = the Gallery profile (or default when the
# profile file is absent), cold folds activate into one script; tile on a cold
# iTerm is `open -a iTerm` (no command) or open + create (command).
rm -f "${HOME}/Library/Application Support/iTerm2/DynamicProfiles/gallery-theme.json"
out="$(open_dry iterm2 float 1 --title "Gallery: Foo Bar" -- /x/gallery-tui run "Foo Bar")"
assert_contains "${out}" "tell application id \"com.googlecode.iterm2\" to create window with default profile command" "iterm float running"
assert_contains "${out}" "'\\''Foo Bar'\\''" "iterm float command is single-quoted"
# iTerm's own command parser does not undo backslash escapes: a word with
# quotes and $ in it (the agent's login-shell wrapper) must reach it single-quoted.
out="$(open_dry iterm2 tile 1 -- /bin/zsh -l -c 'exec "$0" launch' /x/gallery-agent)"
assert_contains "${out}" "'\\''exec \\\"\$0\\\" launch'\\''" "iterm keeps \$0 inside single quotes"
out="$(open_dry iterm2 float 0 --title "Gallery: Foo" -- /x/gallery-tui run Foo)"
assert_contains "${out}" "activate" "iterm float cold activates"
mkdir -p "${HOME}/Library/Application Support/iTerm2/DynamicProfiles"
python3 "${RENDER}" >/dev/null
out="$(open_dry iterm2 float 1 --title "Gallery: Foo" -- /x/gallery-tui run Foo)"
assert_contains "${out}" 'create window with profile "Gallery" command' "iterm float uses the Gallery profile once rendered"
out="$(open_dry iterm2 float 1 --profile default --title "Learn: menu" -- /x/learn menu)"
# "default" means the user's own profile as the Console profile carries it
# (their Default plus the theme's colours while the console follows it).
assert_contains "${out}" 'create window with profile "Console" command' "--profile default uses Console once rendered"
assert_lacks "${out}" 'profile "Gallery"' "--profile default"
out="$(open_dry iterm2 tile 0)"
[ "${out}" = "open -a iTerm" ] || fail "cold iTerm tile with no command should only launch iTerm: ${out}"
out="$(open_dry iterm2 tile 1)"
assert_contains "${out}" 'set w to (create window with profile "Console")' "iterm tile running uses the Console profile"
assert_contains "${out}" "select w" "iterm tile selects the new window"
out="$(open_dry iterm2 tile 0 -- /bin/zsh -l -c 'exec "$0" launch' /a/agent)"
assert_contains "${out}" "open -a iTerm" "iterm tile+command cold launches first"
assert_contains "${out}" "return id of w" "iterm tile+command returns the window id"
say "gallery-term iterm2: float / tile, cold / running"

# Ghostty
out="$(open_dry ghostty float 1 --title "Gallery: Foo" --cwd /w -- /x/gallery-tui run Foo)"
assert_contains "${out}" 'tell application id "com.mitchellh.ghostty"' "ghostty drives the app by bundle id"
assert_contains "${out}" "new window with configuration {command:" "ghostty new window with configuration"
assert_contains "${out}" "gallery-term wrap '\\''Gallery: Foo'\\''" "ghostty wraps the command to set the title"
assert_contains "${out}" "${TERMDIR}/gallery-osc.sh" "ghostty float loads the palette escapes"
assert_contains "${out}" 'initial working directory:"/w"' "ghostty cwd"
assert_lacks "${out}" "open -a" "ghostty running does not relaunch"
out="$(open_dry ghostty float 0 --title "Gallery: Foo" -- /x/gallery-tui run Foo)"
assert_contains "${out}" "open -a Ghostty" "ghostty cold launches first"
out="$(open_dry ghostty tile 1 --title T -- /x/cmd)"
assert_lacks "${out}" "gallery-osc.sh" "ghostty tile gets no palette escapes"
assert_contains "${out}" "gallery-term wrap T " "ghostty tile still sets the title"
out="$(open_dry ghostty tile 1)"
assert_contains "${out}" "new window" "ghostty tile, no command"
assert_contains "${out}" "initial working directory:\"${HOME}\"" "ghostty tile, no command, starts in the home folder"
assert_lacks "${out}" "command:" "ghostty tile, no command"
[ "$(open_dry ghostty tile 0)" = "open -a Ghostty" ] || fail "cold ghostty tile with no command should only launch it"
say "gallery-term ghostty: float / tile, cold / running"

# kitty
out="$(open_dry kitty float 1 --title "Gallery: Foo" -- /x/gallery-tui run Foo)"
assert_contains "${out}" "kitty --single-instance --instance-group gallery-float -o confirm_os_window_close=0 --title 'Gallery: Foo'" "kitty title option"
assert_contains "${out}" "--config ${TERMDIR}/kitty.conf" "kitty float themes the window"
assert_contains "${out}" "/x/gallery-tui run Foo &" "kitty runs detached"
assert_lacks "${out}" "gallery-term wrap" "kitty needs no wrapper"
mkdir -p "${HOME}/.config/kitty"
: > "${HOME}/.config/kitty/kitty.conf"
out="$(open_dry kitty float 0 --title X -- /x/cmd)"
assert_contains "${out}" "--config ${HOME}/.config/kitty/kitty.conf --config ${TERMDIR}/kitty.conf" "kitty float keeps the user config, theme after it"
[ "$(open_dry kitty float 0 --title X -- /x/cmd)" = "$(open_dry kitty float 1 --title X -- /x/cmd)" ] \
  || fail "kitty cold and running should be the same command line"
out="$(open_dry kitty tile 1)"
assert_lacks "${out}" "--config" "kitty tile uses the user's config"
assert_contains "${out}" "--single-instance" "kitty tile"
out="$(open_dry kitty tile 1 --cwd /w --title T -- /x/cmd)"
assert_contains "${out}" "--directory /w" "kitty cwd"
say "gallery-term kitty: float / tile, cold = running"

# WezTerm
out="$(open_dry wezterm float 1 --title "Gallery: Foo" -- /x/gallery-tui run Foo)"
assert_contains "${out}" "wezterm --config window_background_opacity=0.88 --config macos_window_background_blur=9 --config hide_tab_bar_if_only_one_tab=true start --always-new-process" "wezterm float glass in its own process"
assert_contains "${out}" "gallery-term wrap 'Gallery: Foo' ${TERMDIR}/gallery-osc.sh /x/gallery-tui run Foo &" "wezterm wrapper"
out="$(open_dry wezterm tile 0)"
assert_contains "${out}" "wezterm start --cwd ${HOME} &" "wezterm tile, no command, starts in the home folder"
assert_lacks "${out}" "--config" "wezterm tile uses the user's config"
out="$(open_dry wezterm tile 1 --cwd /w)"
assert_contains "${out}" "start --cwd /w" "wezterm cwd"
say "gallery-term wezterm: float / tile"

# Argument checking
if "${TERM_BIN}" open --dry-run --role float 2>/dev/null; then fail "a float window without a command should be refused"; fi
if "${TERM_BIN}" open --dry-run --role sideways -- /x 2>/dev/null; then fail "a bad role should be refused"; fi
say "gallery-term argument checks"

# The wrapper itself: sets the title, loads the palette, becomes the command.
printf 'printf PALETTE\n' > "${WORK_DIR}/osc.sh"
out="$("${TERM_BIN}" wrap "Gallery: T" "${WORK_DIR}/osc.sh" /bin/echo ran)"
[ "${out}" = "$(printf '\033]0;Gallery: T\007PALETTEran')" ] || fail "wrap output was: $(printf '%s' "${out}" | od -c | head -3)"
say "gallery-term wrap"

# --- 4. rendered theme files -----------------------------------------------------
rm -rf "${CFG}/state/terminals"
printf '{"family": "Test Nerd Font", "size": 15, "weight": "Regular"}\n' > "${CFG}/state/font.json"
printf '{"mode": "theme"}\n' > "${CFG}/state/console.json"
python3 "${RENDER}" >/dev/null 2>&1
for f in ghostty.conf kitty.conf wezterm.lua gallery-osc.sh glass.env; do
  [ -s "${TERMDIR}/${f}" ] || fail "renderer did not write terminals/${f}"
done
g="$(cat "${TERMDIR}/ghostty.conf")"
assert_contains "${g}" "palette = 0=#" "ghostty palette 0"
assert_contains "${g}" "palette = 15=#" "ghostty palette 15"
assert_contains "${g}" "background = #1a1b26" "ghostty background"
assert_contains "${g}" "foreground = #" "ghostty foreground"
assert_contains "${g}" "cursor-color = #" "ghostty cursor"
assert_contains "${g}" "selection-background = #" "ghostty selection"
assert_contains "${g}" "background-opacity = 0.88" "ghostty opacity = 1 - CONSOLE_TRANSPARENCY"
assert_contains "${g}" "background-blur = 9" "ghostty blur"
assert_contains "${g}" 'font-family = "Test Nerd Font"' "ghostty font"
assert_contains "${g}" "font-size = 15" "ghostty font size"
k="$(cat "${TERMDIR}/kitty.conf")"
assert_contains "${k}" "color0 #" "kitty color0"
assert_contains "${k}" "color15 #" "kitty color15"
assert_contains "${k}" "background #1a1b26" "kitty background"
assert_contains "${k}" "selection_background #" "kitty selection"
assert_contains "${k}" "background_opacity 0.88" "kitty opacity"
assert_contains "${k}" "background_blur 9" "kitty blur"
assert_contains "${k}" "font_family Test Nerd Font" "kitty font"
assert_contains "${k}" "font_size 15" "kitty font size"
w="$(cat "${TERMDIR}/wezterm.lua")"
assert_contains "${w}" 'background = "#1a1b26"' "wezterm background"
assert_contains "${w}" "ansi = { " "wezterm ansi"
assert_contains "${w}" "brights = { " "wezterm brights"
assert_contains "${w}" "selection_bg" "wezterm selection"
assert_contains "${w}" "window_background_opacity = 0.88" "wezterm opacity"
assert_contains "${w}" "macos_window_background_blur = 9" "wezterm blur"
assert_contains "${w}" 'font = wezterm.font("Test Nerd Font")' "wezterm font"
assert_contains "${w}" "add_to_config_reload_watch_list" "wezterm module watches itself"
[ "$(grep -c '^printf' "${TERMDIR}/gallery-osc.sh")" -eq 19 ] || fail "gallery-osc.sh should set 16 colours + fg, bg, cursor"
[ "$(cat "${TERMDIR}/glass.env")" = "$(printf 'opacity=0.88\nblur=9')" ] || fail "glass.env"
python3 "${RENDER}" --print >/dev/null
# no font preference: no font keys at all
rm "${CFG}/state/font.json"
python3 "${RENDER}" >/dev/null 2>&1
for f in ghostty.conf kitty.conf wezterm.lua; do
  if grep -qi 'font' "${TERMDIR}/${f}"; then fail "${f} carries font keys with no font preference"; fi
done
# wezterm native mode: an empty table, so merging it changes nothing
printf '{"mode": "native"}\n' > "${CFG}/state/console.json"
python3 "${RENDER}" >/dev/null 2>&1
grep -q '^return {}$' "${TERMDIR}/wezterm.lua" || fail "wezterm.lua should return an empty table in native console mode"
grep -q 'palette = 0=' "${TERMDIR}/ghostty.conf" || fail "ghostty.conf is written whatever the console mode"
# iTerm outputs still written
[ -f "${HOME}/Library/Application Support/iTerm2/DynamicProfiles/gallery-theme.json" ] || fail "iTerm Gallery profile missing"
[ -f "${HOME}/Library/Application Support/iTerm2/DynamicProfiles/gallery-console.json" ] || fail "iTerm Console profile missing"
say "rendered theme files for ghostty, kitty, wezterm (and the iTerm profiles still)"

# --- 4a. console close: ask (default) adds nothing, never adds each no-prompt key
ITERM_CONSOLE_JSON="${HOME}/Library/Application Support/iTerm2/DynamicProfiles/gallery-console.json"
printf '{"mode": "theme"}\n' > "${CFG}/state/console.json"
python3 "${RENDER}" >/dev/null 2>&1
for f in ghostty.conf kitty.conf wezterm.lua; do
  if grep -qi 'confirm' "${TERMDIR}/${f}"; then fail "${f} carries a close setting with close=ask"; fi
done
python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))["Profiles"][0]; assert "Prompt Before Closing 2" not in p' "${ITERM_CONSOLE_JSON}" \
  || fail "iTerm Console profile carries a close setting with close=ask"
printf '{"mode": "theme", "close": "never"}\n' > "${CFG}/state/console.json"
python3 "${RENDER}" >/dev/null 2>&1
assert_contains "$(cat "${TERMDIR}/ghostty.conf")" "confirm-close-surface = false" "close never (ghostty)"
assert_contains "$(cat "${TERMDIR}/kitty.conf")" "confirm_os_window_close 0" "close never (kitty)"
assert_contains "$(cat "${TERMDIR}/wezterm.lua")" 'window_close_confirmation = "NeverPrompt"' "close never (wezterm)"
python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))["Profiles"][0]; assert p["Prompt Before Closing 2"] == 0' "${ITERM_CONSOLE_JSON}" \
  || fail "iTerm Console profile should not prompt with close=never"
# the CLI keeps mode and close side by side
assert_contains "$("${GALLERY}" console close)" "close: never" "console close shows the setting"
"${GALLERY}" console close ask >/dev/null
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d == {"mode": "theme", "close": "ask"}, d' "${CFG}/state/console.json" \
  || fail "console close ask should keep the mode"
"${GALLERY}" console close never >/dev/null
"${GALLERY}" console native >/dev/null 2>&1 || true
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d == {"mode": "native", "close": "never"}, d' "${CFG}/state/console.json" \
  || fail "console native should keep the close setting"
assert_contains "$("${GALLERY}" console status)" "takes effect only while the console follows the theme" "close never in native mode is flagged"
"${GALLERY}" console close sometimes >/dev/null 2>&1 && fail "console close sometimes should be rejected"
"${GALLERY}" console close ask >/dev/null
printf '{"mode": "native"}\n' > "${CFG}/state/console.json"
say "console close ask|never: rendered per terminal, kept alongside the mode"

# --- 4b. glass: state/glass.json overrides the defaults, bad input never fails ---
ITERM_CONSOLE="${HOME}/Library/Application Support/iTerm2/DynamicProfiles/gallery-console.json"
printf '{"mode": "theme"}\n' > "${CFG}/state/console.json"
printf '{"transparency": 0.3, "blur": 20}\n' > "${CFG}/state/glass.json"
err="$(python3 "${RENDER}" 2>&1 >/dev/null)"
[ -z "${err}" ] || fail "a valid glass.json should render silently, got: ${err}"
assert_contains "$(cat "${TERMDIR}/ghostty.conf")" "background-opacity = 0.7" "glass.json opacity (ghostty)"
assert_contains "$(cat "${TERMDIR}/ghostty.conf")" "background-blur = 20" "glass.json blur (ghostty)"
assert_contains "$(cat "${TERMDIR}/kitty.conf")" "background_opacity 0.7" "glass.json opacity (kitty)"
assert_contains "$(cat "${TERMDIR}/wezterm.lua")" "macos_window_background_blur = 20" "glass.json blur (wezterm)"
[ "$(cat "${TERMDIR}/glass.env")" = "$(printf 'opacity=0.7\nblur=20')" ] || fail "glass.env should follow glass.json"
python3 - "${ITERM_CONSOLE}" "${HOME}/Library/Application Support/iTerm2/DynamicProfiles/gallery-theme.json" <<'PY' || fail "iTerm profiles should follow glass.json"
import json, sys
for path in sys.argv[1:]:
    prof = json.load(open(path))["Profiles"][0]
    assert prof["Transparency"] == 0.3 and prof["Blur Radius"] == 20.0 and prof["Blur"] is True, (path, prof)
PY
# out-of-range values are clamped, not rejected
printf '{"transparency": 5, "blur": 500}\n' > "${CFG}/state/glass.json"
python3 "${RENDER}" >/dev/null 2>&1
[ "$(cat "${TERMDIR}/glass.env")" = "$(printf 'opacity=0.1\nblur=64')" ] || fail "glass.json should clamp to transparency 0.9, blur 64"
printf '{"transparency": -1, "blur": -3}\n' > "${CFG}/state/glass.json"
python3 "${RENDER}" >/dev/null 2>&1
[ "$(cat "${TERMDIR}/glass.env")" = "$(printf 'opacity=1\nblur=0')" ] || fail "glass.json should clamp negatives to solid, no blur"
# a bad value or a bad file warns on stderr and falls back to the defaults
printf '{"transparency": "lots", "blur": 20}\n' > "${CFG}/state/glass.json"
err="$(python3 "${RENDER}" 2>&1 >/dev/null)" || fail "a bad glass value must not fail the render"
assert_contains "${err}" "transparency must be a number" "bad glass value warns"
[ "$(cat "${TERMDIR}/glass.env")" = "$(printf 'opacity=0.88\nblur=20')" ] || fail "only the bad glass field should fall back"
printf 'not json {' > "${CFG}/state/glass.json"
err="$(python3 "${RENDER}" 2>&1 >/dev/null)" || fail "a corrupt glass.json must not fail the render"
assert_contains "${err}" "ignoring" "corrupt glass.json warns"
[ "$(cat "${TERMDIR}/glass.env")" = "$(printf 'opacity=0.88\nblur=9')" ] || fail "a corrupt glass.json should mean the defaults"
printf '[1, 2]\n' > "${CFG}/state/glass.json"
python3 "${RENDER}" >/dev/null 2>&1 || fail "a non-object glass.json must not fail the render"
rm -f "${CFG}/state/glass.json"
python3 "${RENDER}" >/dev/null 2>&1
[ "$(cat "${TERMDIR}/glass.env")" = "$(printf 'opacity=0.88\nblur=9')" ] || fail "no glass.json should mean the defaults"
python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))["Profiles"][0]; assert p["Transparency"]==0.12 and p["Blur Radius"]==9.0' "${ITERM_CONSOLE}" || fail "default iTerm glass changed"

# the CLI: gallery glass [status] | set <transparency> [<blur>] | default
assert_contains "$("${GALLERY}" glass)" "transparency 0.12, blur 9 (default)" "glass status, defaults"
out="$("${GALLERY}" glass set 0.4 30)"
assert_contains "${out}" "transparency 0.4, blur 30 (custom)" "glass set"
[ "$(cat "${TERMDIR}/glass.env")" = "$(printf 'opacity=0.6\nblur=30')" ] || fail "glass set should re-render the terminal files"
"${GALLERY}" glass set 0 >/dev/null
assert_contains "$("${GALLERY}" glass status)" "transparency 0, blur 30 (custom)" "glass set <t> keeps the blur"
for bad in "0.95" "1" "-0.1" "abc" "0.1.2"; do
  "${GALLERY}" glass set "${bad}" >/dev/null 2>&1 && fail "glass set ${bad} should be rejected"
done
"${GALLERY}" glass set 0.2 65 >/dev/null 2>&1 && fail "glass set with blur 65 should be rejected"
"${GALLERY}" glass set 0.2 1.5 >/dev/null 2>&1 && fail "glass set with a fractional blur should be rejected"
"${GALLERY}" glass bogus >/dev/null 2>&1 && fail "unknown glass subcommand should fail"
assert_contains "$("${GALLERY}" glass default)" "transparency 0.12, blur 9 (default)" "glass default"
[ ! -e "${CFG}/state/glass.json" ] || fail "glass default should remove glass.json"
[ "$(cat "${TERMDIR}/glass.env")" = "$(printf 'opacity=0.88\nblur=9')" ] || fail "glass default should re-render the defaults"
say "glass: glass.json honoured by every renderer, clamped, bad input warns; gallery glass set|default"

# --- 5. console mode against throwaway configs ---------------------------------
GH_CONF="${HOME}/.config/ghostty/config"
KT_CONF="${HOME}/.config/kitty/kitty.conf"
GH_LINE="config-file = ?${TERMDIR}/ghostty.conf"
KT_LINE="include ${TERMDIR}/kitty.conf"

count_line() { grep -Fxc -- "$2" "$1" || true; }

# ghostty: file missing -> created with exactly the one line
rm -f "${GH_CONF}"
"${GALLERY}" terminal set ghostty >/dev/null
"${GALLERY}" console theme >/dev/null
[ "$(count_line "${GH_CONF}" "${GH_LINE}")" = 1 ] || fail "console theme should create the ghostty config with the include"
[ "$(wc -l < "${GH_CONF}" | tr -d ' ')" = 1 ] || fail "created ghostty config should hold only the include"
"${GALLERY}" console theme >/dev/null
[ "$(count_line "${GH_CONF}" "${GH_LINE}")" = 1 ] || fail "console theme twice should still leave one include"
assert_contains "$("${GALLERY}" console status)" "includes the Gallery theme" "console status (ghostty)"
"${GALLERY}" console native >/dev/null
[ "$(count_line "${GH_CONF}" "${GH_LINE}")" = 0 ] || fail "console native should remove the include"
"${GALLERY}" console native >/dev/null
# an existing config without a trailing newline: backed up, only the line added
printf 'font-size = 12\ntheme = foo' > "${GH_CONF}"
cp "${GH_CONF}" "${WORK_DIR}/gh.orig"
"${GALLERY}" console theme >/dev/null
[ -f "${GH_CONF}.gallery-bak" ] || fail "no backup before the first edit"
cmp -s "${GH_CONF}.gallery-bak" "${WORK_DIR}/gh.orig" || fail "backup differs from the original"
[ "$(sed -n 1,2p "${GH_CONF}")" = "$(printf 'font-size = 12\ntheme = foo')" ] || fail "existing ghostty lines were altered"
[ "$(count_line "${GH_CONF}" "${GH_LINE}")" = 1 ] || fail "include not added to an existing config"
"${GALLERY}" console native >/dev/null
cmp -s "${GH_CONF}" "${WORK_DIR}/gh.orig" || [ "$(cat "${GH_CONF}")" = "$(printf 'font-size = 12\ntheme = foo')" ] \
  || fail "native should leave the rest of the ghostty config as it was"
say "console theme|native on ghostty: add, idempotent, backup, remove"

# kitty
mkdir -p "${APPS}/kitty.app"
rm -f "${KT_CONF}"
"${GALLERY}" terminal set kitty >/dev/null
"${GALLERY}" console theme >/dev/null
[ "$(count_line "${KT_CONF}" "${KT_LINE}")" = 1 ] || fail "console theme should add the kitty include"
"${GALLERY}" console theme >/dev/null
[ "$(count_line "${KT_CONF}" "${KT_LINE}")" = 1 ] || fail "kitty include duplicated"
"${GALLERY}" console native >/dev/null
[ "$(count_line "${KT_CONF}" "${KT_LINE}")" = 0 ] || fail "kitty include not removed"
say "console theme|native on kitty"

# wezterm: never edits an existing Lua; creates ~/.wezterm.lua only when absent
"${GALLERY}" terminal set wezterm >/dev/null
rm -f "${HOME}/.wezterm.lua"
out="$("${GALLERY}" console theme)"
assert_contains "${out}" "created ${HOME}/.wezterm.lua" "wezterm config created when absent"
grep -q 'state/terminals/wezterm.lua' "${HOME}/.wezterm.lua" || fail "created wezterm.lua does not load the theme"
grep -q 'for k, v in pairs(gallery)' "${HOME}/.wezterm.lua" || fail "created wezterm.lua misses the merge line"
grep -q '^return {$' "${TERMDIR}/wezterm.lua" || fail "wezterm.lua should carry the palette in theme mode"
out="$("${GALLERY}" console theme)"
assert_contains "${out}" "already loads" "wezterm wiring is idempotent"
printf -- '-- mine\nreturn {}\n' > "${HOME}/.wezterm.lua"
cp "${HOME}/.wezterm.lua" "${WORK_DIR}/wez.orig"
out="$("${GALLERY}" console theme)"
assert_contains "${out}" "add these two lines" "wezterm: lines printed for an existing config"
assert_contains "${out}" "pcall(dofile" "wezterm: snippet shown"
cmp -s "${HOME}/.wezterm.lua" "${WORK_DIR}/wez.orig" || fail "an existing wezterm.lua must never be edited"
"${GALLERY}" console native >/dev/null
grep -q '^return {}$' "${TERMDIR}/wezterm.lua" || fail "wezterm native should empty the module"
say "console theme|native on wezterm: prints, creates only when absent, never edits"

# Every installed terminal follows the theme, not only the one the Gallery
# opens windows in: here iTerm2 is chosen and Ghostty and kitty are installed.
"${GALLERY}" terminal set iterm2 >/dev/null
rm -f "${GH_CONF}" "${KT_CONF}"
PREFS() { "${GALLERY_DEFAULTS_BIN}" "$@"; }
PREFS write com.googlecode.iterm2 "Default Bookmark Guid" -string MY-OWN-GUID
"${GALLERY}" console theme >/dev/null
[ "$(count_line "${GH_CONF}" "${GH_LINE}")" = 1 ] || fail "console theme should wire every installed terminal (ghostty)"
[ "$(count_line "${KT_CONF}" "${KT_LINE}")" = 1 ] || fail "console theme should wire every installed terminal (kitty)"
grep -q '"Background Color"' "${HOME}/Library/Application Support/iTerm2/DynamicProfiles/gallery-console.json" \
  || fail "iTerm2 console profile should carry colours in theme mode"
[ "$(PREFS read com.googlecode.iterm2 "Default Bookmark Guid")" = gallery-console ] \
  || fail "theme should make Console iTerm2's default profile"
grep -q '"iterm_default_before": "MY-OWN-GUID"' "${CFG}/state/console.json" || fail "the user's own iTerm2 default was not noted"
"${GALLERY}" console theme >/dev/null
grep -q '"iterm_default_before": "MY-OWN-GUID"' "${CFG}/state/console.json" || fail "a second theme overwrote the noted default"
say "console theme: every installed terminal wired, iTerm2 default taken and the user's own noted"

# gallery off puts every terminal back (the render reads the paused file);
# gallery on applies the theme again. Services stubbed.
mkdir -p "${WORK_DIR}/stub"
for c in yabai skhd launchctl pkill; do printf '#!/bin/sh\nexit 0\n' > "${WORK_DIR}/stub/$c"; done
printf '#!/bin/sh\nexit 1\n' > "${WORK_DIR}/stub/pgrep"
chmod +x "${WORK_DIR}/stub/"*
PATH="${WORK_DIR}/stub:${PATH}" "${GALLERY}" off >/dev/null
[ "$(count_line "${GH_CONF}" "${GH_LINE}")" = 0 ] || fail "off should take the theme out of ghostty"
[ "$(count_line "${KT_CONF}" "${KT_LINE}")" = 0 ] || fail "off should take the theme out of kitty"
[ "$(PREFS read com.googlecode.iterm2 "Default Bookmark Guid")" = MY-OWN-GUID ] || fail "off should give back the user's iTerm2 default"
if grep -q '"Background Color"' "${HOME}/Library/Application Support/iTerm2/DynamicProfiles/gallery-console.json"; then
  fail "off should render the Console profile bare"
fi
grep -q '"mode": "theme"' "${CFG}/state/console.json" || fail "off must not forget that the console follows the theme"
PATH="${WORK_DIR}/stub:${PATH}" "${GALLERY}" on >/dev/null
[ "$(count_line "${GH_CONF}" "${GH_LINE}")" = 1 ] || fail "on should wire ghostty again"
[ "$(PREFS read com.googlecode.iterm2 "Default Bookmark Guid")" = gallery-console ] || fail "on should make Console the default again"
grep -q '"Background Color"' "${HOME}/Library/Application Support/iTerm2/DynamicProfiles/gallery-console.json" \
  || fail "on should render the theme into the Console profile"
say "gallery off / on: terminals back to their own colours and themed again, preference kept"

"${GALLERY}" console native >/dev/null
[ "$(count_line "${GH_CONF}" "${GH_LINE}")" = 0 ] && [ "$(count_line "${KT_CONF}" "${KT_LINE}")" = 0 ] \
  || fail "native should unwire every installed terminal"
[ "$(PREFS read com.googlecode.iterm2 "Default Bookmark Guid")" = MY-OWN-GUID ] || fail "native should give back the user's iTerm2 default"
grep -q iterm_default_before "${CFG}/state/console.json" && fail "the noted default should be cleared once given back"
if grep -q '"Background Color"' "${HOME}/Library/Application Support/iTerm2/DynamicProfiles/gallery-console.json"; then
  fail "iTerm2 console profile should be bare in native mode"
fi
# a default the user picked themselves while themed is theirs: not overwritten
"${GALLERY}" console theme >/dev/null
PREFS write com.googlecode.iterm2 "Default Bookmark Guid" -string PICKED-LATER
"${GALLERY}" console native >/dev/null
[ "$(PREFS read com.googlecode.iterm2 "Default Bookmark Guid")" = PICKED-LATER ] || fail "native overwrote a default the user picked since"
say "console native: everything given back; a default picked since is left alone"

say "PASS terminal_test.sh"
