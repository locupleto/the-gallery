#!/bin/bash
# take.sh -- regenerate the README screenshots (assets/screenshots/*.jpg).
#
#   tools/screenshots/take.sh                 every scene, then build the images
#   tools/screenshots/take.sh tiles agents    only these scenes, then build
#   tools/screenshots/take.sh build           only rebuild the images from the
#                                             captures already taken
#
# Scenes: tiles (tiling.jpg, themes.jpg, theme-picker.jpg, learn.jpg,
# plugins.jpg), walls (wallpapers.jpg, wallpapers-more.jpg), terminals
# (terminals.jpg), agents (agents.jpg). Captures are kept in
# ~/.cache/gallery-screenshots, so retaking one scene reuses the others.
#
# What it needs:
#   - an EMPTY Space on the main display that nothing else uses during the
#     run: DEMO_SPACE is its yabai index, DEMO_DESKTOP the Mission Control
#     number that ctrl+<n> switches to (they differ when a native full-screen
#     Space sits before it). Defaults 10 and 9.
#   - the screen unlocked, and nobody at the keyboard: every window opens on
#     whichever Space is in view, so the script checks that the demo Space is
#     in view before each one and stops if it cannot get it back.
#   - iTerm2, Ghostty, kitty, WezTerm, btop, superfile (spf), fastfetch, nvim,
#     the Radio Atlas plugin, claude and gemini (signed in), and Pillow
#     (through uv, or importable by python3).
#
# What it changes while it runs, and puts back on exit (also on Ctrl-C or an
# abort): the theme and every theme's selected wallpaper, ~/.config/skhd/
# local.skhd (the example file is swapped in so the Learn sheet shows no
# personal keys), the demo Space's gaps, and the Space in view. Every window
# it opens is closed; terminal apps that were not running before are quit.
#
# What is in each picture is set below: wallpapers per scene, the commit whose
# tools/render-theme.py fills the editor tile, the agent prompts. To follow an
# Omarchy wallpaper change, edit the WALL_* lines and run the affected scenes.
# Look at every image before committing (see docs in the vault note
# Screenshot-Regeneration): the agents' replies differ from run to run.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
ASSETS="${REPO}/assets/screenshots"
SHOTS="${HOME}/.cache/gallery-screenshots"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/gallery-shots.XXXXXX")"
GALLERY="${HOME}/bin/gallery"
GHS="${HOME}/bin/gallery-hs"
HOOK="${HOME}/.config/gallery/hooks/theme-set.d/30-wallpaper.sh"
THEMES="${HOME}/.config/gallery/themes"
STATE="${HOME}/.config/gallery/state"
SK="${HOME}/.config/skhd"

DEMO_SPACE="${DEMO_SPACE:-10}"
DEMO_DESKTOP="${DEMO_DESKTOP:-9}"

# --- what is in the pictures ---------------------------------------------------
# The editor tile shows tools/render-theme.py as of this commit, line 752.
CODE_REV="${CODE_REV:-e7fc796}"
# theme:wallpaper (a file in that theme's backgrounds/ folder)
WALL_MAIN="osaka-jade:1-glowing-city.webp"            # tiling, picker, learn, plugins, terminals
WALL_THEMES="tokyo-night:0-winding-road.webp catppuccin-latte:1-color-fade.webp gruvbox:1-the-backwater.jpg"
WALL_HERO="tokyo-night:1-quattro.webp"
WALL_MORE="kanagawa:1-kanagawa.jpg retro-82:1-in-the-groove.webp catppuccin:1-totoro.webp lupine:01-cherry-blossom-bokeh.webp"
WALL_AGENTS="tokyo-night:0-winding-road.webp"
AGENT_DIR="/tmp/gallery-demo"   # shown in the agents' status lines
PROMPT_WEBSITE="Create index.html: a one-page site for a small coffee shop, dark theme, menu section and opening hours"
PROMPT_API="Write app.py: a minimal Flask JSON API with /health and /items endpoints, plus a test file"
PROMPT_API_TESTS="Install the dependencies and run the tests with pytest"
PROMPT_NOTES="Summarise README.md and add three sections these meeting notes should have"
# Claude Code started without the user's own settings and memory, in a plain voice.
DEMO_CLAUDE="claude --setting-sources project,local --append-system-prompt 'This session is a public product demo. Use a plain, neutral, friendly tone and no persona, and print no status markers.'"

say() { echo "[shots] $*"; }
die() { echo "[shots] ABORT: $*" >&2; exit 1; }

# --- spaces and windows ----------------------------------------------------------
visible_space() {
  yabai -m query --spaces --display 1 | python3 -c "import json,sys;print([s['index'] for s in json.load(sys.stdin) if s['is-visible']][0])"
}
desktop_key() { "${GHS}" -t 5 "hs.eventtap.keyStroke({'ctrl'}, '$1', 20000); return 1" >/dev/null; }
demo() { # make sure the demo Space is in view, or stop
  local i
  for i in 1 2 3; do
    [ "$(visible_space)" = "${DEMO_SPACE}" ] && return 0
    desktop_key "${DEMO_DESKTOP}"; sleep 1.5
  done
  die "the demo Space ${DEMO_SPACE} is not in view"
}
demo_windows() { yabai -m query --windows --space "${DEMO_SPACE}" | python3 -c 'import json,sys;print(" ".join(str(w["id"]) for w in json.load(sys.stdin)))'; }
close_demo_windows() {
  # Stop what runs in them first: a terminal asked to close a window with a
  # program still running asks for confirmation (iTerm2) or leaves a dead
  # window behind (Ghostty). iTerm2 windows are closed over AppleScript,
  # which never asks; the rest through yabai once their program is gone.
  pkill -f "exec sleep 9031" 2>/dev/null; pkill -f "public product demo" 2>/dev/null
  sleep 1
  yabai -m query --windows --space "${DEMO_SPACE}" 2>/dev/null | python3 -c 'import json,sys;[print(w["id"],w["app"]) for w in json.load(sys.stdin)]' |
  while read -r id app; do
    if [ "${app}" = iTerm2 ]; then
      osascript -e "tell application \"iTerm2\" to close (window id ${id})" >/dev/null 2>&1
    else
      yabai -m window "${id}" --close 2>/dev/null
    fi
  done
  sleep 1.5
}
empty_demo() { [ -z "$(demo_windows)" ] || die "windows left on the demo Space before this scene: $(demo_windows)"; }
pad() { # pad top bottom left right gap -- the demo Space only
  yabai -m config --space "${DEMO_SPACE}" top_padding "$1"
  yabai -m config --space "${DEMO_SPACE}" bottom_padding "$2"
  yabai -m config --space "${DEMO_SPACE}" left_padding "$3"
  yabai -m config --space "${DEMO_SPACE}" right_padding "$4"
  yabai -m config --space "${DEMO_SPACE}" window_gap "$5"
}
look() { # look theme:wallpaper -- theme, plus a wallpaper shown without being selected
  local theme="${1%%:*}" wall="${1#*:}"
  [ -f "${THEMES}/${theme}/backgrounds/${wall}" ] || die "no wallpaper ${theme}/${wall}"
  "${GALLERY}" theme set "${theme}" >/dev/null 2>&1
  demo; "${HOOK}" "${theme}" "${THEMES}/${theme}/backgrounds/${wall}" >/dev/null 2>&1; sleep 3
}
shot() { sleep "${2:-2}"; demo; screencapture -x -D1 "${SHOTS}/$1.png" && say "captured $1"; }
iterm_tile() { # iterm_tile <command> -- an iTerm window on the demo Space
  demo
  osascript -e "tell application \"iTerm2\"
    set w to (create window with default profile command \"/bin/zsh -lc '$1'\")
    set bounds of w to {200, 200, 1200, 900}
    return id of w
  end tell" >> "${WORK}/ids"
  sleep 1.5
}
close_tiles() {
  local id
  while read -r id; do
    [ -n "${id}" ] && osascript -e "tell application \"iTerm2\" to close (window id ${id})" >/dev/null 2>&1
  done < "${WORK}/ids"
  : > "${WORK}/ids"; sleep 1
}
focus_title() {
  local wid
  wid="$(yabai -m query --windows --space "${DEMO_SPACE}" | python3 -c "import json,sys,re;w=[x for x in json.load(sys.stdin) if re.search(sys.argv[1],x['title'])];print(w[0]['id'] if w else '')" "$1")"
  [ -n "${wid}" ] && yabai -m window "${wid}" --focus
}
four_tiles() { # editor, file manager, btop, fastfetch
  iterm_tile "exec ${WORK}/code-tile.sh"
  iterm_tile "cd ${REPO} && exec spf ${REPO}"
  iterm_tile "exec btop -c ${HERE}/btop-demo.conf"
  iterm_tile "clear; fastfetch -l small -s OS:Kernel:Packages:Shell:WM:Terminal:TerminalFont:CPU:GPU:Memory:Break:Colors; sleep 99999"
  sleep 1; focus_title superfile
}

# --- iTerm session text, for the agents ------------------------------------------
send() { # send <window id> <AppleScript text expression>
  osascript -e "tell application id \"com.googlecode.iterm2\" to tell current session of (first window whose id is $1) to write text ($2) newline NO" >/dev/null
}
type_line() { send "$1" "\"$2\""; sleep 0.4; send "$1" '(character id 13)'; }
screen_text() { # the last lines of a window's session
  osascript -e "tell application id \"com.googlecode.iterm2\" to tell current session of (first window whose id is $1) to get contents" 2>/dev/null | tail -60
}
wait_text() { # wait_text <id> <regex> <seconds>
  local i
  for ((i = 0; i < $3; i += 2)); do
    screen_text "$1" | grep -Eq "$2" && return 0
    sleep 2
  done
  return 1
}

# --- restore, always ---------------------------------------------------------------
ORIG_THEME=""; ORIG_SPACE=""; RESTORED=0
restore() {
  [ "${RESTORED}" = 1 ] && return; RESTORED=1
  say "restoring the desktop"
  close_tiles 2>/dev/null
  close_demo_windows
  for app in ghostty kitty; do
    grep -qx "${app}" "${WORK}/running" 2>/dev/null || pkill -x "${app}" 2>/dev/null
  done
  grep -qx wezterm-gui "${WORK}/running" 2>/dev/null || pkill -f "WezTerm.app/Contents/MacOS/wezterm-gui" 2>/dev/null
  [ -f "${SK}/local.skhd.shots-keep" ] && mv -f "${SK}/local.skhd.shots-keep" "${SK}/local.skhd" && "${SK}/learn" install "${SK}/skhdrc" >/dev/null 2>&1
  pad 8 8 8 8 8 2>/dev/null
  [ -f "${WORK}/backgrounds.json" ] && cp -f "${WORK}/backgrounds.json" "${STATE}/backgrounds.json"
  [ -n "${ORIG_THEME}" ] && "${GALLERY}" theme set "${ORIG_THEME}" >/dev/null 2>&1
  "${GALLERY}" bg apply >/dev/null 2>&1
  [ -n "${ORIG_SPACE}" ] && [ "${ORIG_SPACE}" != "${DEMO_SPACE}" ] && desktop_key "$(desktop_of "${ORIG_SPACE}")"
  rm -rf "${WORK}" "${AGENT_DIR}"
  say "restored: theme ${ORIG_THEME}, Space ${ORIG_SPACE}, $(demo_windows 2>/dev/null | wc -w | tr -d ' ') window(s) left on the demo Space"
}
desktop_of() { # Mission Control number of a yabai Space index (native full-screen Spaces have none)
  yabai -m query --spaces | python3 -c "
import json,sys
n=0
for s in json.load(sys.stdin):
    if not s['is-native-fullscreen']: n+=1
    if s['index']==int(sys.argv[1]): print(n)" "$1"
}

# --- scenes ------------------------------------------------------------------------------
scene_tiles() {
  local tw n=2
  pad 8 8 8 8 8
  "${GALLERY}" bg set "${WALL_MAIN#*:}" "${WALL_MAIN%%:*}" >/dev/null 2>&1   # what the picker previews
  look "${WALL_MAIN}"; four_tiles; shot tiling-main
  "${GALLERY}" open gallery.themes >/dev/null; shot theme-picker 4; "${GALLERY}" close gallery.themes >/dev/null; sleep 1.5
  "${SK}/learn" open menu >/dev/null 2>&1; shot learn-menu 4
  osascript -e 'tell application id "com.googlecode.iterm2" to close (every window whose name starts with "Learn")' >/dev/null 2>&1; sleep 1.5
  "${GALLERY}" open akshar.radio-atlas qml >/dev/null; shot radio-atlas 6; "${GALLERY}" close akshar.radio-atlas qml >/dev/null 2>&1; sleep 2
  "${GALLERY}" open gallery.weather >/dev/null; shot weather 6; "${GALLERY}" close gallery.weather >/dev/null 2>&1; sleep 1.5
  for tw in ${WALL_THEMES}; do
    close_tiles; look "${tw}"; four_tiles; shot "tiling-${n}" 2.5; n=$((n + 1))
  done
  close_tiles
}

scene_walls() {
  local tw n=1
  pad 120 120 1640 80 8     # two tiles kept to the right third, the wallpaper beside them
  look "${WALL_HERO}"
  iterm_tile "exec btop -c ${HERE}/btop-demo.conf"
  iterm_tile "clear; fastfetch -l small -s OS:Kernel:Shell:WM:Terminal:TerminalFont:CPU:Memory:Break:Colors; sleep 99999"
  shot hero 3; close_tiles
  pad 1000 90 1720 90 8     # one small window in the corner
  for tw in ${WALL_MORE}; do
    look "${tw}"
    iterm_tile "clear; fastfetch -l small -s OS:WM:Terminal:Shell:Break:Colors; sleep 99999"
    shot "wall-${n}" 2.5; close_tiles; n=$((n + 1))
  done
  pad 8 8 8 8 8
}

scene_terminals() {
  local t
  pad 8 8 8 8 8
  look "${WALL_MAIN}"
  for t in iterm2 ghostty kitty wezterm; do
    demo
    GALLERY_TERMINAL="${t}" "${HOME}/bin/gallery-term" open --role tile --title "${t}" -- \
      /bin/zsh -lc "clear; fastfetch -l small -s OS:Terminal:TerminalFont:Shell:Colors; exec sleep 9031" >/dev/null
    sleep 5
  done
  shot terminals 3
  close_demo_windows
}

new_window() { # new_window <before> -- the demo-Space window not in <before>
  local id
  for id in $(demo_windows); do case " $1 " in *" ${id} "*) ;; *) echo "${id}"; return ;; esac; done
}

scene_agents() {
  local d before web api notes i text
  rm -rf "${AGENT_DIR}"
  for d in website api notes; do mkdir -p "${AGENT_DIR}/${d}"; git -C "${AGENT_DIR}/${d}" init -q; done
  printf '# website\n\nA small static site.\n' > "${AGENT_DIR}/website/README.md"
  printf '# api\n\nA tiny JSON API.\n' > "${AGENT_DIR}/api/README.md"
  printf '# notes\n\nMeeting notes.\n' > "${AGENT_DIR}/notes/README.md"
  pad 8 8 8 8 8
  look "${WALL_AGENTS}"
  # Opened in this order, yabai gives the first the left half and splits the
  # right half between the other two.
  before="$(demo_windows)"; demo
  "${HOME}/bin/gallery-term" open --role tile --title claude -- /bin/zsh -lc "cd ${AGENT_DIR}/website && exec ${DEMO_CLAUDE}" >/dev/null; sleep 5
  web="$(new_window "${before}")"; before="$(demo_windows)"; demo
  "${HOME}/bin/gallery-term" open --role tile --title gemini -- /bin/zsh -lc "cd ${AGENT_DIR}/api && exec gemini" >/dev/null; sleep 6
  api="$(new_window "${before}")"; before="$(demo_windows)"; demo
  "${HOME}/bin/gallery-term" open --role tile --title claude -- /bin/zsh -lc "cd ${AGENT_DIR}/notes && exec ${DEMO_CLAUDE}" >/dev/null; sleep 6
  notes="$(new_window "${before}")"
  [ -n "${web}" ] && [ -n "${api}" ] && [ -n "${notes}" ] || die "an agent window did not open (${web}/${api}/${notes})"
  # First-run questions: Claude asks to trust a new folder, Gemini to pick a theme.
  for i in "${web}" "${notes}"; do screen_text "${i}" | grep -qi "trust" && send "${i}" '(character id 13)'; done
  screen_text "${api}" | grep -q "Select Theme" && { send "${api}" '(character id 27)'; sleep 1.5; }
  type_line "${web}" "${PROMPT_WEBSITE}"
  type_line "${api}" "${PROMPT_API}"
  type_line "${notes}" "${PROMPT_NOTES}"
  # Gemini asks before every file it writes and every command it runs. Approve
  # until it asks to run pytest, and leave it waiting there.
  local asked_tests=0
  for ((i = 0; i < 90; i++)); do
    text="$(screen_text "${api}")"
    if printf '%s' "${text}" | grep -q "Waiting for user confirmation"; then
      # The command itself, not its description (pip's mentions pytest too).
      if printf '%s' "${text}" | grep -E '\? +(Shell|WriteFile|Edit)' | tail -1 | grep -Eq 'Shell +(python[0-9.]* -m )?pytest'; then break; fi
      say "approving Gemini: $(printf '%s' "${text}" | grep -E '\? +(Shell|WriteFile|Edit)' | tail -1 | sed 's/^[^?]*//' | cut -c1-90)"
      send "${api}" '(character id 13)'; sleep 4; continue
    fi
    if [ "${asked_tests}" = 0 ] && printf '%s' "${text}" | grep -q "Type your message" && printf '%s' "${text}" | grep -q "requirements.txt"; then
      type_line "${api}" "${PROMPT_API_TESTS}"; asked_tests=1
    fi
    sleep 4
  done
  [ "${i}" -lt 90 ] || say "warning: Gemini never reached its pytest question"
  wait_text "${web}" ' · done ' 240 || say "warning: the website agent did not finish in time"
  wait_text "${notes}" ' · done ' 240 || say "warning: the notes agent did not finish in time"
  yabai -m window "${notes}" --focus 2>/dev/null
  shot agents 3
  send "${api}" '(character id 27)'; sleep 0.5
  close_demo_windows
}

build() {
  local py=(python3)
  if command -v uv >/dev/null 2>&1; then py=(uv run --quiet --with pillow python3); fi
  "${py[@]}" "${HERE}/build.py" "${SHOTS}" "${ASSETS}"
}

# --- main ---------------------------------------------------------------------------------
main() {
  local scenes=("$@") s
  [ "${#scenes[@]}" -gt 0 ] || scenes=(tiles walls terminals agents)
  if [ "${scenes[*]}" = build ]; then build; return; fi
  for s in "${scenes[@]}"; do
    case "${s}" in tiles|walls|terminals|agents) ;; *) die "unknown scene: ${s}" ;; esac
  done
  ioreg -n Root -d1 -a | plutil -p - | grep -q '"CGSSessionScreenIsLocked" => true' && die "the screen is locked"
  [ -z "$(demo_windows)" ] || die "the demo Space ${DEMO_SPACE} is not empty"
  mkdir -p "${SHOTS}"; : > "${WORK}/ids"
  pgrep -lx 'ghostty|kitty|wezterm-gui' | awk '{print $2}' > "${WORK}/running" || true
  ORIG_SPACE="$(visible_space)"
  ORIG_THEME="$(sed -n "s/^export GALLERY_THEME_NAME='\(.*\)'/\1/p" "${STATE}/theme.sh")"
  cp -f "${STATE}/backgrounds.json" "${WORK}/backgrounds.json" 2>/dev/null
  trap restore EXIT
  trap 'exit 130' INT TERM
  caffeinate -d -i -u -w $$ &
  mv "${SK}/local.skhd" "${SK}/local.skhd.shots-keep"
  cp "${REPO}/tiler/local.skhd.example" "${SK}/local.skhd"
  "${SK}/learn" install "${SK}/skhdrc" >/dev/null 2>&1
  mkdir -p "${WORK}/code/tools"
  git -C "${REPO}" show "${CODE_REV}:tools/render-theme.py" > "${WORK}/code/tools/render-theme.py" || die "no render-theme.py at ${CODE_REV}"
  cat > "${WORK}/code-tile.sh" <<EOF
#!/bin/zsh
cd "${WORK}/code"
exec nvim --clean -R -c 'set notermguicolors number' -c 'colorscheme vim' -c 'syntax on' +752 tools/render-theme.py
EOF
  chmod +x "${WORK}/code-tile.sh"
  demo
  for s in "${scenes[@]}"; do say "scene: ${s}"; empty_demo; "scene_${s}"; done
  restore
  build
}
main "$@"
