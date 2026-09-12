#!/usr/bin/env bash
# Gallery TUI plugin: pick a Gallery theme in fzf (Omarchy's theme-menu, in
# a floating terminal) and apply it via the gallery CLI.
#
# Layout note: fzf's preview pane cannot mix plain text with ANY image
# protocol (iTerm OSC 1337, chafa's native passthrough, sixel) -- the image
# gets dropped (or the text gets swallowed) the instant they share one
# preview invocation, on this fzf build (0.74.4), empirically. So the
# palette swatches live in the LIST-SIDE HEADER (rebuilt per highlighted
# theme via `transform-header`) instead of the preview pane, and the
# preview pane shows the theme's active background wallpaper alone, at
# full chafa resolution -- same recipe gallery.backgrounds/backgrounds.sh
# uses for its own image-only preview. Theme name + background filename go
# in the preview pane's border label instead (`transform-preview-label`),
# never mixed into the image bytes.
#
#   themes.sh                  run the interactive fzf picker (needs a tty)
#   themes.sh --list           print the fzf input lines and exit (for testing, no tty needed)
#   themes.sh --preview NAME   render NAME's background image alone and exit
#                              (no tty needed; this is what fzf itself shells
#                              back out to on every highlight change)
#   themes.sh --swatches NAME  print the header block (static instructions
#                              line + NAME's two-column palette grid) and
#                              exit -- this is what fzf's `transform-header`
#                              shells out to on load/every highlight change
#   themes.sh --dims NAME      print "NAME  BG_FILE  WxH" (or "NAME  no
#                              backgrounds") and exit -- this is what fzf's
#                              `transform-preview-label` shells out to, to
#                              caption the preview pane's border
#
# Keys (inside the picker):
#   Enter                      apply the highlighted theme, drop into its
#                              backgrounds picker
#   Esc                        close
#   ctrl-t                     toggle whether the iTerm "Console" profile
#                              (the user's everyday terminal) follows the
#                              active theme or stays on its own Default
#                              colours -- see `gallery console`; the header's
#                              second line reflects the result
#   ctrl-w                     cycle the JankyBorders focus-outline width
#                              through the presets 3 -> 5 -> 8 -> 12 -> 3 --
#                              see `gallery borders width`; the header's
#                              third line reflects the result
#   ctrl-b                     toggle whether the focus outline's colour is
#                              mixed toward the theme's bright_foreground --
#                              see `gallery borders bright`; same header line
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

GALLERY_BIN="${HOME}/bin/gallery"
THEME_DIR="${HOME}/.config/gallery/themes"
CONSOLE_STATE_FILE="${HOME}/.config/gallery/state/console.json"
BORDERS_STATE_FILE="${HOME}/.config/gallery/state/borders.json"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# get_val FILE KEY -- print the (unquoted) value of a flat `key = "value"`
# line in a colors.toml, anchored to the start of the line so e.g. "foreground"
# never matches "dark_foreground" / "bright_foreground". Prints nothing (and
# still exits 0) when the key is absent -- colors.toml files are allowed to
# be missing keys and callers must tolerate that.
get_val() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  sed -n "s/^${key}[[:space:]]*=[[:space:]]*\"\\(.*\\)\"[[:space:]]*\$/\\1/p" "$file" | head -1
}

# --- width awareness ---------------------------------------------------------
# The header (instructions + swatch grid) lives in fzf's LIST pane, which is
# half the window (preview-window=right:50%). On a 16" MacBook the Gallery
# window's 6:6 grid gives ~105 columns in total, so the list pane has ~48 --
# the full header lines (up to 85 columns) and the two-column swatch grid
# (60) are cut off there, key hints included. Below COMPACT_BELOW list
# columns the header switches to a compact form: shorter wording, the border
# prefs on two lines, and swatches without their hex values.
#
# fzf exports FZF_COLUMNS to transform/execute commands (the --swatches
# subprocess); the initial --header is built before fzf starts, where
# `tput cols` reads the window. A fallback of 160 (wide) keeps the full form
# when neither is known.
COMPACT_BELOW=86   # the full border line is 85 columns
list_cols() {
  local total
  total="${FZF_COLUMNS:-${COLUMNS:-$(tput cols 2>/dev/null || echo 160)}}"
  [[ "$total" =~ ^[0-9]+$ ]] || total=160
  printf '%d' $(( total / 2 - 4 ))
}
COMPACT=0
[[ "$(list_cols)" -lt "$COMPACT_BELOW" ]] && COMPACT=1

# swatch LABEL HEX -- one truecolor block + label + hex value, or nothing if
# HEX is empty/malformed (missing-key tolerance lives here). Fixed visible
# width when HEX is present -- see CELL_WIDTH below, which depends on this
# exact format string. Compact mode drops the hex value (block + label only).
swatch() {
  local label="$1" hex="$2" r g b
  [[ -n "$hex" ]] || return 0
  hex="${hex#\#}"
  [[ "${#hex}" -eq 6 ]] || return 0
  case "$hex" in
    *[!0-9a-fA-F]*) return 0 ;;
  esac
  r=$((16#${hex:0:2}))
  g=$((16#${hex:2:2}))
  b=$((16#${hex:4:2}))
  if [[ "$COMPACT" -eq 1 ]]; then
    printf '\033[48;2;%d;%d;%dm   \033[0m  %-17.17s\n' "$r" "$g" "$b" "$label"
  else
    printf '\033[48;2;%d;%d;%dm   \033[0m  %-16s #%s\n' "$r" "$g" "$b" "$label" "$hex"
  fi
}

# --- swatches (list-side header) -------------------------------------------

# CELL_WIDTH -- the visible (non-ANSI) column width of one swatch() line:
# 3 (block) + 2 (spacing) + 16 (label field) + 1 (space) + 1 (#) + 6 (hex).
# Used to pad out a missing/malformed colour's cell to the same width, so
# the right-hand column still lines up across rows even when a theme is
# missing one of the left-hand keys.
CELL_WIDTH=29
[[ "$COMPACT" -eq 1 ]] && CELL_WIDTH=22   # 3 + 2 + 17, no hex (see swatch)

# Two-column layout: 16 colours in 8 rows. Index i pairs LEFT_KEYS[i] with
# RIGHT_KEYS[i]. The last right-hand slot is a spare -- most colors.toml
# files don't define bright_foreground, in which case that cell is just
# left blank (swatch()'s own missing-key tolerance handles it).
LEFT_KEYS=(accent background foreground red yellow green cyan blue)
RIGHT_KEYS=(magenta bright_red bright_yellow bright_green bright_cyan bright_blue bright_magenta bright_foreground)

# swatch_cell LABEL HEX -- swatch()'s output, or CELL_WIDTH blank spaces if
# HEX was missing/malformed (swatch() itself prints nothing in that case) --
# keeps a two-up row's right column aligned regardless of which keys a given
# colors.toml happens to define.
swatch_cell() {
  local label="$1" hex="$2" out
  out="$(swatch "$label" "$hex")"
  if [[ -z "$out" ]]; then
    printf '%*s' "$CELL_WIDTH" ''
  else
    printf '%s' "$out"
  fi
}

# render_swatches NAME -- the 8-row, two-column palette grid for NAME's
# colors.toml (16 cells: see LEFT_KEYS/RIGHT_KEYS above). No name/heading
# line here -- that's static_header's job -- just the grid itself.
render_swatches() {
  local name="$1"
  local file="${THEME_DIR}/${name}/colors.toml"
  local i left_key right_key left_cell right_cell

  if [[ ! -f "$file" ]]; then
    printf '(no colors.toml found)\n'
    return 0
  fi

  for i in "${!LEFT_KEYS[@]}"; do
    left_key="${LEFT_KEYS[$i]}"
    right_key="${RIGHT_KEYS[$i]}"
    left_cell="$(swatch_cell "$left_key" "$(get_val "$file" "$left_key")")"
    right_cell="$(swatch_cell "$right_key" "$(get_val "$file" "$right_key")")"
    printf '%s  %s\n' "$left_cell" "$right_cell"
  done
}

# console_mode -- prints "theme" or "native" straight from
# CONSOLE_STATE_FILE (default "native" if missing/unreadable/garbage), same
# contract as bin/gallery's console_read_mode. Reads the state file directly
# instead of shelling out to `gallery console status` -- this runs on every
# `focus` event (i.e. every arrow key in the picker), and status's extra
# `defaults read` call is needless work per keystroke.
console_mode() {
  if [[ ! -f "$CONSOLE_STATE_FILE" ]]; then
    printf 'native'
    return 0
  fi
  python3 -c '
import json, sys

mode = "native"
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
    if isinstance(data, dict):
        val = data.get("mode")
        if val in ("theme", "native"):
            mode = val
except Exception:
    pass
sys.stdout.write(mode)
' "$CONSOLE_STATE_FILE" 2>/dev/null || printf 'native'
}

# borders_prefs -- prints "WIDTH BRIGHT" (bright as "on"/"off") straight
# from BORDERS_STATE_FILE, default "5 off" if missing/unreadable/garbage --
# same contract (and same per-keystroke direct-file-read reasoning) as
# console_mode above, mirroring bin/gallery's own borders_read_prefs.
borders_prefs() {
  if [[ ! -f "$BORDERS_STATE_FILE" ]]; then
    printf '5 off'
    return 0
  fi
  python3 -c '
import json, sys

width = 5
bright = False
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
    if isinstance(data, dict):
        w = data.get("width")
        if isinstance(w, int) and not isinstance(w, bool):
            width = max(1, min(12, w))
        b = data.get("bright")
        if isinstance(b, bool):
            bright = b
except Exception:
    pass
sys.stdout.write(str(width) + " " + ("on" if bright else "off"))
' "$BORDERS_STATE_FILE" 2>/dev/null || printf '5 off'
}

# next_width -- prints the next width preset after the currently stored
# width, cycling 3 -> 5 -> 8 -> 12 -> 3; a stored width that is not one of
# the four presets (hand-edited borders.json) goes to 5. This is what
# `themes.sh --next-width` prints, and what the picker's ctrl-w bind shells
# out to (nested inside its own execute-silent, so it re-reads the prefs
# fresh on every keypress rather than once at picker startup).
next_width() {
  local width
  width="$(borders_prefs)"
  width="${width%% *}"
  case "$width" in
    3) printf '5' ;;
    5) printf '8' ;;
    8) printf '12' ;;
    12) printf '3' ;;
    *) printf '5' ;;
  esac
}

# width_radio WIDTH -- "(*)3 ( )5 ( )8 ( )12" with WIDTH's own preset
# marked selected (bullet), or, if WIDTH isn't one of the four presets, all
# four unselected plus a trailing "[WIDTH]" showing the actual value.
width_radio() {
  local width="$1" p mark parts=()
  for p in 3 5 8 12; do
    if [[ "$p" == "$width" ]]; then
      mark="(•)"
    else
      mark="( )"
    fi
    parts+=("${mark}${p}")
  done
  printf '%s' "${parts[*]}"
  case "$width" in
    3|5|8|12) ;;
    *) printf ' [%s]' "$width" ;;
  esac
}

# bright_radio BRIGHT -- "(*)off ( )on" or "( )off (*)on" depending on
# BRIGHT ("on"/"off"; anything else reads as "off").
bright_radio() {
  local bright="$1" off_mark on_mark
  if [[ "$bright" == "on" ]]; then
    off_mark="( )"
    on_mark="(•)"
  else
    off_mark="(•)"
    on_mark="( )"
  fi
  printf '%soff %son' "$off_mark" "$on_mark"
}

# static_header -- the header's fixed first three lines: which theme is
# presently active plus the key hints, the iTerm console's current mode,
# and the JankyBorders width/bright prefs. Queries `gallery theme current`,
# console_mode, and borders_prefs itself (rather than taking them as
# arguments) so both the top-level --header (built once, interactively) and
# every --swatches subprocess (fzf shells this whole script back out to,
# fresh, on load/each highlight) print identical lines without needing to
# thread state between processes.
static_header() {
  local current mode console_line prefs width bright border_line
  current="$("${GALLERY_BIN}" theme current 2>/dev/null || true)"
  mode="$(console_mode)"
  if [[ "$mode" == "theme" ]]; then
    console_line="Console: follows theme  (ctrl-t toggles)"
  else
    console_line="Console: iTerm Default  (ctrl-t toggles)"
  fi
  prefs="$(borders_prefs)"
  width="${prefs%% *}"
  bright="${prefs##* }"
  if [[ "$COMPACT" -eq 1 ]]; then
    # Narrow list pane (see list_cols): same facts, four short lines, so
    # every key hint stays visible.
    case "$mode" in
      theme) console_line="Console: follows theme  ctrl-t" ;;
      *)     console_line="Console: iTerm Default  ctrl-t" ;;
    esac
    printf 'Current: %s  Enter applies, Esc closes\n%s\nBorder width %s  ctrl-w\nBorder bright %s  ctrl-b\n' \
      "${current:-(none)}" "$console_line" "$(width_radio "$width")" "$(bright_radio "$bright")"
    return 0
  fi
  border_line="$(printf 'Border: width %s  ctrl-w cycles   bright %s  ctrl-b toggles' \
    "$(width_radio "$width")" "$(bright_radio "$bright")")"
  printf 'Current: %s -- Enter applies theme and shows its backgrounds, Esc closes\n%s\n%s\n' \
    "${current:-(none)}" "$console_line" "$border_line"
}

# --- preview pane (image only) ----------------------------------------------

# image_dims FILE -- prints "WIDTH HEIGHT" (space-separated, via sips), or
# nothing if the file isn't a readable image. Same recipe as
# gallery.backgrounds/backgrounds.sh's image_dims.
image_dims() {
  local file="$1" dims width height
  dims="$(sips -g pixelWidth -g pixelHeight "$file" 2>/dev/null)" || return 0
  width="$(printf '%s\n' "$dims" | sed -n 's/^[[:space:]]*pixelWidth:[[:space:]]*//p')"
  height="$(printf '%s\n' "$dims" | sed -n 's/^[[:space:]]*pixelHeight:[[:space:]]*//p')"
  [[ -n "$width" && -n "$height" ]] && printf '%s %s\n' "$width" "$height"
}

# print_dims NAME -- "NAME  BG_FILENAME  WxH" (or "NAME  no backgrounds" if
# the theme has none), for fzf's `transform-preview-label` bind. Deliberately
# kept separate from render_preview: this is the ONLY thing that ends up as
# the preview pane's border label, never mixed into the preview command's
# own stdout (see render_preview's comment for why that separation matters).
print_dims() {
  local name="$1" bg_name bg_path dims
  bg_name="$("${GALLERY_BIN}" bg current "$name" 2>/dev/null || true)"
  if [[ -z "$bg_name" ]]; then
    printf '%s  no backgrounds\n' "$name"
    return 0
  fi
  bg_path="${THEME_DIR}/${name}/backgrounds/${bg_name}"
  dims="$(image_dims "$bg_path")"
  if [[ -n "$dims" ]]; then
    printf '%s  %s  %sx%s\n' "$name" "$bg_name" "${dims%% *}" "${dims##* }"
  else
    printf '%s  %s\n' "$name" "$bg_name"
  fi
}

# render_preview NAME -- the image card fzf's --preview shells out to: NAME's
# active background image ALONE, sized from $FZF_PREVIEW_COLUMNS /
# $FZF_PREVIEW_LINES and the image's own aspect ratio (via sips) -- the exact
# recipe gallery.backgrounds/backgrounds.sh's render_preview uses for its own
# image-only preview (see that function's comment for the empirical detail
# this depends on: on this fzf build, ANY plain stdout text sharing a preview
# invocation with an image -- before OR after it -- causes fzf's
# preview-window compositor to either drop the image or swallow the text.
# Only an invocation that emits the image and nothing else renders
# correctly). Theme name / background filename / pixel dimensions are never
# mixed in here -- they go through print_dims / transform-preview-label
# instead.
render_preview() {
  local name="$1" bg_name bg_path dims width height cols rows img_rows

  if ! command -v chafa >/dev/null 2>&1; then
    printf '(install chafa for a preview)\n'
    return 0
  fi

  bg_name="$("${GALLERY_BIN}" bg current "$name" 2>/dev/null || true)"
  if [[ -z "$bg_name" ]]; then
    printf 'no backgrounds\n'
    return 0
  fi

  bg_path="${THEME_DIR}/${name}/backgrounds/${bg_name}"
  if [[ ! -r "$bg_path" ]]; then
    printf '(background image not readable)\n'
    return 0
  fi

  dims="$(image_dims "$bg_path")"
  width="${dims%% *}"
  height="${dims##* }"

  cols="${FZF_PREVIEW_COLUMNS:-80}"
  rows="${FZF_PREVIEW_LINES:-40}"
  # Ask for a height that matches the image's own aspect ratio (scaled to
  # $cols, correcting for terminal cells being roughly twice as tall as
  # wide) rather than nearly the whole pane -- see backgrounds.sh's
  # render_preview comment for why.
  if [[ -n "$width" && -n "$height" && "$width" -gt 0 ]]; then
    img_rows=$(( (cols * height) / (2 * width) ))
    [[ "$img_rows" -lt 1 ]] && img_rows=1
    [[ "$img_rows" -gt "$rows" ]] && img_rows="$rows"
  else
    img_rows="$rows"
  fi

  chafa -s "${cols}x${img_rows}" "$bg_path" 2>/dev/null
}

# Build the fzf input: one tab-delimited line per row.
#   field 1: bare theme name (drives --preview and `gallery theme set`)
#   field 2: display text shown/searched in fzf (gallery's own annotation,
#            e.g. "tokyo-night (current)")
list_lines() {
  "${GALLERY_BIN}" theme list | while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf '%s\t%s\n' "${line%% (*}" "$line"
  done
}

# current_pos NAME -- 1-based line number of NAME in list_lines' output, so
# fzf can start with the cursor already on the active theme. Empty/failure
# if not found (e.g. no current theme set yet) -- caller tolerates that.
current_pos() {
  local current="$1" n=0 name
  while IFS=$'\t' read -r name _; do
    n=$((n + 1))
    if [[ "$name" == "$current" ]]; then
      printf '%s\n' "$n"
      return 0
    fi
  done < <(list_lines)
  return 1
}

case "${1:-}" in
  --preview)
    render_preview "${2:?usage: themes.sh --preview <name>}"
    exit 0
    ;;
  --swatches)
    name="${2:?usage: themes.sh --swatches <name>}"
    static_header
    printf '\n'
    render_swatches "$name"
    exit 0
    ;;
  --dims)
    print_dims "${2:?usage: themes.sh --dims <name>}"
    exit 0
    ;;
  --next-width)
    next_width
    exit 0
    ;;
  --list)
    if [[ ! -x "$GALLERY_BIN" ]]; then
      echo "gallery CLI not found at ${GALLERY_BIN}" >&2
      exit 1
    fi
    list_lines
    exit 0
    ;;
esac

if [[ ! -x "$GALLERY_BIN" ]]; then
  echo "gallery CLI not found at ${GALLERY_BIN} -- cannot list themes."
  sleep 3
  exit 1
fi

if ! command -v fzf >/dev/null 2>&1; then
  echo "fzf is not installed -- cannot show the theme picker."
  sleep 3
  exit 1
fi

# The two plugins are installed side by side under .../gallery/plugins/, so
# resolve the sibling by path rather than assuming it's on PATH.
BACKGROUNDS_SH="$(cd "$(dirname "$SELF")/../gallery.backgrounds" && pwd)/backgrounds.sh"

current="$("${GALLERY_BIN}" theme current 2>/dev/null || true)"
pos="$(current_pos "$current" || true)"
header_line="$(static_header)"

gallery_q="$(printf '%q' "$GALLERY_BIN")"
bg_q="$(printf '%q' "$BACKGROUNDS_SH")"
self_q="$(printf '%q' "$SELF")"

fzf_args=(
  --delimiter=$'\t'
  --with-nth=2
  --height=100%
  --layout=reverse
  --border=rounded
  --no-multi
  --ansi
  --prompt='Theme > '
  --header="$header_line"
  --preview="${self_q} --preview {1}"
  --preview-window=right:50%,border-rounded
  --preview-label=' Background '
  # Rebuilds the ENTIRE header (static line + two-column swatch grid) and
  # the preview pane's border label every time the highlighted row changes,
  # by shelling this same script back out to itself in --swatches / --dims
  # mode -- see those functions' comments. Chained with `+` so one focus
  # event fires both transforms together.
  --bind "focus:transform-header(${self_q} --swatches {1})+transform-preview-label(${self_q} --dims {1})"
  # Enter applies the theme (execute-silent -- ~1-2s: renderers + hooks
  # incl. wallpaper) and then hands the SAME fzf process off to the
  # background picker for that theme via become(), which execve()s over
  # this process in place -- no new window, no new process tree. The
  # change-header first is a best-effort "please wait" cue: fzf renders it
  # before the blocking execute-silent runs.
  --bind "enter:change-header(Applying theme, please wait...)+execute-silent(${gallery_q} theme set {1})+become(${bg_q} --from-themes)"
  # ctrl-t: flip the iTerm console between following the theme and staying
  # on its own Default colours, then refresh the header/preview-label so the
  # "Console: ..." line reflects the new mode immediately.
  --bind "ctrl-t:execute-silent(${gallery_q} console toggle)+transform-header(${self_q} --swatches {1})+transform-preview-label(${self_q} --dims {1})"
  # ctrl-w: cycle the JankyBorders focus-outline width through the presets
  # 3 -> 5 -> 8 -> 12 -> 3. The `\$(...)` is escaped so it is NOT expanded
  # by this script -- fzf's own execute-silent shell evaluates it fresh on
  # every keypress, via `themes.sh --next-width` (next_width above), so the
  # cycle always starts from whatever width is currently on disk.
  --bind "ctrl-w:execute-silent(${gallery_q} borders width \$(${self_q} --next-width))+transform-header(${self_q} --swatches {1})+transform-preview-label(${self_q} --dims {1})"
  # ctrl-b: toggle whether the focus outline's colour is mixed toward the
  # theme's bright_foreground.
  --bind "ctrl-b:execute-silent(${gallery_q} borders bright toggle)+transform-header(${self_q} --swatches {1})+transform-preview-label(${self_q} --dims {1})"
)
# `load`, not `start`: the list is streamed in, so pos() on `start` runs
# against an empty list and does nothing. The initial header/preview-label
# also have to be set here (chained onto the same bind), since `focus`
# doesn't fire for the row fzf highlights by default before any navigation.
if [[ -n "$pos" ]]; then
  fzf_args+=(--bind "load:pos(${pos})+transform-header(${self_q} --swatches {1})+transform-preview-label(${self_q} --dims {1})")
else
  fzf_args+=(--bind "load:transform-header(${self_q} --swatches {1})+transform-preview-label(${self_q} --dims {1})")
fi

list_lines | fzf "${fzf_args[@]}" || true

# Reached only once the become() chain (however many theme<->backgrounds
# hops the user made) has really wound down -- i.e. Esc all the way out.
# Enter no longer falls through to a plain "print selection and exit"; the
# bind above both applies the theme and transitions to stage two itself.
exit 0
