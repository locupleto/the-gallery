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
#   themes.sh --offload-key NAME
#                              what ctrl-x does on NAME: offloads it, then
#                              prints the fzf actions that show the outcome
#   themes.sh --header-only    the header's key lines (and the last outcome)
#                              without the palette grid
#   themes.sh --warm-previews  make the downscaled preview copy of every
#                              theme's active wallpaper and exit (the picker
#                              runs this in the background when it opens)
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
#   ctrl-x                     offload the highlighted theme from this Mac
#                              (`gallery theme offload`) at once, no
#                              confirmation; the outcome replaces the
#                              header's first line. The current theme and a
#                              theme with no copy elsewhere are refused, with
#                              the reason there; `gallery theme restore`
#                              undoes an offload
#   ctrl-u                     toggle whether the Übersicht crystal widgets
#                              follow the theme or keep their own shipped
#                              colours -- see `gallery widgets`. The key and
#                              its "Widgets: ..." header line exist only
#                              while Übersicht is running with those widgets
#                              on this Mac (widgets_available below); on any
#                              other Mac the picker never mentions them
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

GALLERY_BIN="${HOME}/bin/gallery"
THEME_DIR="${HOME}/.config/gallery/themes"
CONSOLE_STATE_FILE="${HOME}/.config/gallery/state/console.json"
WIDGETS_STATE_FILE="${HOME}/.config/gallery/state/widgets.json"
BORDERS_STATE_FILE="${HOME}/.config/gallery/state/borders.json"
# Downscaled copies of the wallpapers for the preview pane (see preview_image).
PREVIEW_CACHE="${GALLERY_CACHE_DIR:-${XDG_CONFIG_HOME:-${HOME}/.config}/gallery/cache}/theme-previews"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# --- width awareness ---------------------------------------------------------
# The header (instructions + swatch grid) lives in fzf's LIST pane, which is
# half the window (preview-window=right:50%). On a 16" laptop screen the Gallery
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

# --- swatches (list-side header) -------------------------------------------

# CELL_WIDTH -- the visible (non-ANSI) column width of one swatch_cell line:
# 3 (block) + 2 (spacing) + 16 (label field) + 1 (space) + 1 (#) + 6 (hex).
# Used to pad out a missing/malformed colour's cell to the same width, so
# the right-hand column still lines up across rows even when a theme is
# missing one of the left-hand keys.
CELL_WIDTH=29
[[ "$COMPACT" -eq 1 ]] && CELL_WIDTH=22   # 3 + 2 + 17, no hex (see swatch_cell)

# Two-column layout: 16 colours in 8 rows. Index i pairs LEFT_KEYS[i] with
# RIGHT_KEYS[i]. The last right-hand slot is a spare -- most colors.toml
# files don't define bright_foreground, in which case that cell is just
# left blank (swatch_cell's missing-key tolerance handles it).
LEFT_KEYS=(accent background foreground red yellow green cyan blue)
RIGHT_KEYS=(magenta bright_red bright_yellow bright_green bright_cyan bright_blue bright_magenta bright_foreground)

# load_colors FILE -- read FILE's flat `key = "value"` lines once into
# COLOR_KEYS/COLOR_VALS (first line wins for a repeated key), so the grid
# below looks its 16 colours up without a sed per cell. Anchored at the
# start of the line, so "foreground" never matches "bright_foreground".
# colors.toml files may lack keys; callers tolerate that. Plain indexed
# arrays: the picker may run on bash 3.2.
COLOR_KEYS=()
COLOR_VALS=()
load_colors() {
  local line re='^([A-Za-z0-9_]+)[[:space:]]*=[[:space:]]*"(.*)"[[:space:]]*$'
  COLOR_KEYS=()
  COLOR_VALS=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $re ]]; then
      COLOR_KEYS+=("${BASH_REMATCH[1]}")
      COLOR_VALS+=("${BASH_REMATCH[2]}")
    fi
  done < "$1"
}

# color_of KEY -- sets COLOR to KEY's value from load_colors, or "".
COLOR=""
color_of() {
  local i
  COLOR=""
  for i in "${!COLOR_KEYS[@]}"; do
    if [[ "${COLOR_KEYS[$i]}" == "$1" ]]; then
      COLOR="${COLOR_VALS[$i]}"
      return 0
    fi
  done
}

# swatch_cell LABEL HEX -- sets CELL to one truecolor block + label + hex
# value (compact mode drops the hex), at a fixed visible width of CELL_WIDTH,
# or to CELL_WIDTH blank spaces if HEX was missing/malformed -- keeps a
# two-up row's right column aligned regardless of which keys a given
# colors.toml happens to define. Sets a variable rather than printing, so
# the grid needs no subshell per cell.
CELL=""
swatch_cell() {
  local label="$1" hex="$2" r g b
  hex="${hex#\#}"
  if [[ "${#hex}" -ne 6 || "$hex" == *[!0-9a-fA-F]* ]]; then
    printf -v CELL '%*s' "$CELL_WIDTH" ''
    return 0
  fi
  r=$((16#${hex:0:2}))
  g=$((16#${hex:2:2}))
  b=$((16#${hex:4:2}))
  if [[ "$COMPACT" -eq 1 ]]; then
    printf -v CELL '\033[48;2;%d;%d;%dm   \033[0m  %-17.17s' "$r" "$g" "$b" "$label"
  else
    printf -v CELL '\033[48;2;%d;%d;%dm   \033[0m  %-16s #%s' "$r" "$g" "$b" "$label" "$hex"
  fi
}

# render_swatches NAME -- the 8-row, two-column palette grid for NAME's
# colors.toml (16 cells: see LEFT_KEYS/RIGHT_KEYS above). No name/heading
# line here -- that's static_header's job -- just the grid itself.
render_swatches() {
  local name="$1"
  local file="${THEME_DIR}/${name}/colors.toml"
  local i left_cell

  if [[ ! -f "$file" ]]; then
    printf '(no colors.toml found)\n'
    return 0
  fi

  load_colors "$file"
  for i in "${!LEFT_KEYS[@]}"; do
    color_of "${LEFT_KEYS[$i]}"
    swatch_cell "${LEFT_KEYS[$i]}" "$COLOR"
    left_cell="$CELL"
    color_of "${RIGHT_KEYS[$i]}"
    swatch_cell "${RIGHT_KEYS[$i]}" "$COLOR"
    printf '%s  %s\n' "$left_cell" "$CELL"
  done
}

# read_prefs -- prints "CONSOLE WIDGETS WIDTH BRIGHT" (e.g. "native theme 5
# off") straight from the three state files, each with its own default when
# missing/unreadable/garbage: console and widgets "theme"/"native" (default
# "native", bin/gallery's console_read_mode contract), width 1..12 (default
# 5) and bright "on"/"off" (default "off", bin/gallery's borders_read_prefs).
# One python3 for all three files: this runs on every highlight change, and
# a python start is the expensive part, not the reading.
read_prefs() {
  python3 -c '
import json, sys

def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}

def mode(path):
    val = load(path).get("mode")
    return val if val in ("theme", "native") else "native"

borders = load(sys.argv[3])
width = 5
w = borders.get("width")
if isinstance(w, int) and not isinstance(w, bool):
    width = max(1, min(12, w))
bright = borders.get("bright") is True
sys.stdout.write("%s %s %d %s" % (mode(sys.argv[1]), mode(sys.argv[2]), width, "on" if bright else "off"))
' "$CONSOLE_STATE_FILE" "$WIDGETS_STATE_FILE" "$BORDERS_STATE_FILE" 2>/dev/null \
    || printf 'native native 5 off'
}

# borders_prefs -- "WIDTH BRIGHT" from read_prefs.
borders_prefs() {
  local prefs
  prefs="$(read_prefs)"
  printf '%s' "${prefs#* * }"
}

# widgets_available -- 0 when Übersicht is running on this Mac with the
# crystal widgets, else 1: mirrors bin/gallery's widgets_available (one ps,
# one glob) rather than shelling out to `gallery widgets available`, since
# this runs on every focus event. Decides whether the picker shows the
# "Widgets: ..." line and honours ctrl-u at all.
widgets_available() {
  # Decided once when the picker starts (see GALLERY_THEMES_WIDGETS below)
  # and inherited by every fzf subprocess: Übersicht does not come and go
  # while the picker is open, and the ps costs more than the rest of a
  # header refresh.
  case "${GALLERY_THEMES_WIDGETS:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  local args dir w
  args="$(ps -axo args= 2>/dev/null | grep '[R]esources/server.js' | head -n 1)"
  [[ -n "$args" ]] || return 1
  dir="$(printf '%s\n' "$args" | sed -n 's/.* -d \(.*\) -p [0-9][0-9]* .*/\1/p')"
  [[ -n "$dir" ]] || dir="${HOME}/Library/Application Support/Übersicht/widgets"
  [[ -d "$dir" ]] || return 1
  for w in "$dir"/crystal-*.widget; do
    [[ -d "$w" ]] && return 0
  done
  return 1
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

# native_label -- what "console native" means on the configured terminal:
# iTerm2's Default profile, or on any other terminal simply its own config.
native_label() {
  local t
  t="${GALLERY_THEMES_TERM:-$("${HOME}/bin/gallery-term" name 2>/dev/null || echo iterm2)}"
  if [[ "$t" == iterm2 ]]; then printf 'iTerm Default'; else printf 'own config'; fi
}

# --- offloading (ctrl-x) ------------------------------------------------------
# One picker's state lives in GALLERY_THEMES_STATE, a temp dir made at
# startup and inherited by every fzf subprocess: `message` holds the last
# offload's outcome, shown in place of the "Current:" line until the next.
state_file() { printf '%s/%s' "${GALLERY_THEMES_STATE:-/nonexistent}" "$1"; }

# set_message COLOUR TEXT -- the outcome line (31 red, 32 green), first line only.
set_message() {
  [[ -n "${GALLERY_THEMES_STATE:-}" ]] || return 0
  printf '\033[%sm%s\033[0m' "$1" "${2%%$'\n'*}" > "$(state_file message)"
}

# offload_key NAME -- ctrl-x: offload NAME now (Urban's call: no
# confirmation; the refusals in `gallery theme offload` are the safety net,
# and `gallery theme restore` undoes it). Prints the fzf actions to run next.
offload_key() {
  local name="$1" out rc=0 self_q
  self_q="$(printf '%q' "$SELF")"
  out="$("${GALLERY_BIN}" theme offload "$name" 2>&1)" || rc=$?
  out="${out#gallery: }"
  if [[ "$rc" -eq 0 ]]; then
    set_message 32 "$out"
    # The outcome goes up without {1}: fzf skips an action whose placeholder
    # is empty, and after an offload the list may well be empty (the query
    # matched only the theme just removed). The next focus redraws the grid.
    printf 'reload-sync(%s --list)+transform-header(%s --header-only)+refresh-preview\n' "$self_q" "$self_q"
  else
    set_message 31 "$out"
    printf 'transform-header(%s --header-only)\n' "$self_q"
  fi
}

# static_header -- the header's fixed first three lines: which theme is
# presently active plus the key hints, the terminal console's current mode,
# and the JankyBorders width/bright prefs. Queries `gallery theme current`,
# and read_prefs itself (rather than taking them as
# arguments) so both the top-level --header (built once, interactively) and
# every --swatches subprocess (fzf shells this whole script back out to,
# fresh, on load/each highlight) print identical lines without needing to
# thread state between processes.
static_header() {
  local current mode wmode console_line prefs width bright border_line widgets_line message=""
  [[ -f "$(state_file message)" ]] && message="$(cat "$(state_file message)")"
  # The current theme cannot change while the picker is open (Enter hands
  # over to the backgrounds picker), so the startup value is passed down.
  current="${GALLERY_THEMES_CURRENT-$("${GALLERY_BIN}" theme current 2>/dev/null || true)}"
  prefs="$(read_prefs)"
  read -r mode wmode width bright <<< "$prefs"
  if [[ "$mode" == "theme" ]]; then
    console_line="Console: follows theme  (ctrl-t toggles)"
  else
    console_line="Console: $(native_label)  (ctrl-t toggles)"
  fi
  # The Übersicht line is appended only on a Mac where it means something
  # (see widgets_available); elsewhere the header is exactly as before.
  widgets_line=""
  if widgets_available; then
    case "$wmode" in
      theme) widgets_line="Widgets: follow theme  (ctrl-u toggles)" ;;
      *)     widgets_line="Widgets: own colours  (ctrl-u toggles)" ;;
    esac
  fi
  if [[ "$COMPACT" -eq 1 ]]; then
    # Narrow list pane (see list_cols): same facts, four short lines (five
    # with the widgets line), so every key hint stays visible.
    case "$mode" in
      theme) console_line="Console: follows theme  ctrl-t" ;;
      *)     console_line="Console: $(native_label)  ctrl-t" ;;
    esac
    [[ -n "$widgets_line" ]] && widgets_line="${widgets_line/  (ctrl-u toggles)/  ctrl-u}"
    if [[ -n "$message" ]]; then printf '%s\n' "$message"; else printf 'Current: %s  Enter applies, Esc closes\n' "${current:-(none)}"; fi
    printf '%s\nBorder width %s  ctrl-w\nBorder bright %s  ctrl-b\n' \
      "$console_line" "$(width_radio "$width")" "$(bright_radio "$bright")"
    [[ -n "$widgets_line" ]] && printf '%s\n' "$widgets_line"
    printf 'Offload from this Mac  ctrl-x\n'
    return 0
  fi
  border_line="$(printf 'Border: width %s  ctrl-w cycles   bright %s  ctrl-b toggles' \
    "$(width_radio "$width")" "$(bright_radio "$bright")")"
  if [[ -n "$message" ]]; then
    printf '%s\n' "$message"
  else
    printf 'Current: %s -- Enter applies theme and shows its backgrounds, Esc closes\n' "${current:-(none)}"
  fi
  printf '%s\n%s\n' "$console_line" "$border_line"
  [[ -n "$widgets_line" ]] && printf '%s\n' "$widgets_line"
  printf 'Offload: ctrl-x removes the highlighted theme from this Mac\n'
  return 0
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

# preview_image FILE -- prints the path of a copy of FILE at most 1600 px
# wide (JPEG, in PREVIEW_CACHE), making it on first use; prints FILE itself
# when it cannot. chafa decodes the whole image on every highlight, and a 5K
# PNG wallpaper takes it ~400 ms where the copy takes ~50 ms. The key covers
# path, size and mtime, so a replaced wallpaper gets a fresh copy.
preview_image() {
  local file="$1" key out tmp
  key="$(printf '%s|%s' "$file" "$(stat -f '%z %m' "$file" 2>/dev/null)" | md5 -q 2>/dev/null)" \
    || { printf '%s\n' "$file"; return 0; }
  out="${PREVIEW_CACHE}/${key}.jpg"
  if [[ ! -s "$out" ]]; then
    tmp="${out}.$$.tmp"
    if ! { mkdir -p "$PREVIEW_CACHE" \
           && sips -s format jpeg -s formatOptions 85 -Z 1600 "$file" --out "$tmp" >/dev/null 2>&1 \
           && [[ -s "$tmp" ]] && mv -f "$tmp" "$out"; } 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null
      printf '%s\n' "$file"
      return 0
    fi
  fi
  printf '%s\n' "$out"
}

# warm_previews -- make the preview copy of every theme's active wallpaper,
# so the first pass down the list is as quick as the next one. Run in the
# background when the picker opens; a copy that already exists costs a stat.
warm_previews() {
  local dir name bg
  for dir in "${THEME_DIR}"/*/; do
    name="${dir%/}"
    name="${name##*/}"
    [[ "$name" == current ]] && continue
    bg="$("${GALLERY_BIN}" bg current "$name" 2>/dev/null)" || continue
    [[ -r "${dir}backgrounds/${bg}" ]] && preview_image "${dir}backgrounds/${bg}" >/dev/null
  done
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

  # Dimensions from the copy (same aspect ratio, and sips reads it faster).
  bg_path="$(preview_image "$bg_path")"
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

  # kitty and Ghostty keep images (kitty's graphics protocol, which chafa uses
  # there) on a layer of their own that fzf's preview refresh does not touch,
  # so each new image landed on top of the last one: delete them first.
  # iTerm2's inline images live in the text cells and go with them.
  [[ -n "${KITTY_WINDOW_ID:-}" || "${TERM:-}" == xterm-kitty || "${TERM:-}" == xterm-ghostty \
     || "${TERM_PROGRAM:-}" == ghostty ]] && printf '\033_Ga=d,d=A\033\\'
  chafa -s "${cols}x${img_rows}" "$bg_path" 2>/dev/null
}

# Build the fzf input: one tab-delimited line per row.
#   field 1: bare theme name (drives --preview and `gallery theme set`)
#   field 2: display text shown/searched in fzf (gallery's own annotation,
#            e.g. "tokyo-night (current)")
list_lines() {
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf '%s\t%s\n' "${line%% (*}" "$line"
  done < <("${GALLERY_BIN}" theme list)
}

# current_pos LINES -- 1-based line number of the "(current" row in
# list_lines' output LINES, so fzf can start with the cursor already on the
# active theme. Empty/failure if there is none (no current theme set yet) --
# caller tolerates that.
current_pos() {
  local n=0 name display
  while IFS=$'\t' read -r name display; do
    n=$((n + 1))
    if [[ "$display" == *"(current"* ]]; then
      printf '%s\t%s\n' "$n" "$name"
      return 0
    fi
  done <<< "$1"
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
  --header-only)
    # The key lines alone (with any outcome message), no palette grid.
    static_header
    exit 0
    ;;
  --offload-key)
    offload_key "${2:?usage: themes.sh --offload-key <name>}"
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
  --warm-previews)
    warm_previews
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

# Everything below is worked out once, here, and handed to the fzf
# subprocesses (--swatches/--dims run on every highlight) through the
# environment: the list, the current theme, whether the Übersicht widgets
# are there, and which terminal this is. Opening used to cost three
# `gallery theme list` calls and several ps/python runs before fzf drew.
lines="$(list_lines)"
pos="" current=""
if found="$(current_pos "$lines")"; then
  pos="${found%%$'\t'*}"
  current="${found#*$'\t'}"
fi
export GALLERY_THEMES_CURRENT="$current"
GALLERY_THEMES_WIDGETS=0
widgets_available && GALLERY_THEMES_WIDGETS=1
export GALLERY_THEMES_WIDGETS
GALLERY_THEMES_TERM="$("${HOME}/bin/gallery-term" name 2>/dev/null || echo iterm2)"
export GALLERY_THEMES_TERM
GALLERY_THEMES_STATE="$(mktemp -d "${TMPDIR:-/tmp}/gallery-themes.XXXXXX")"
export GALLERY_THEMES_STATE
header_line="$(static_header)"

# Fill the preview cache for the themes not looked at yet, at low priority,
# without holding the picker up (its output and lifetime are its own).
# No tty file descriptors, so closing the window never waits on it.
( nice -n 10 "$SELF" --warm-previews </dev/null >/dev/null 2>&1 & ) 2>/dev/null

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
  # ctrl-t: flip the terminal console between following the theme and staying
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
  # ctrl-x: offload the highlighted theme at once (offload_key).
  --bind "ctrl-x:transform(${self_q} --offload-key {1})"
)
# ctrl-u: toggle whether the Übersicht crystal widgets follow the theme.
# Bound only when Übersicht is running with those widgets on this Mac, so
# on any other Mac the key does nothing and the header never mentions it.
if widgets_available; then
  fzf_args+=(--bind "ctrl-u:execute-silent(${gallery_q} widgets toggle)+transform-header(${self_q} --swatches {1})+transform-preview-label(${self_q} --dims {1})")
fi
# `load`, not `start`: the list is streamed in, so pos() on `start` runs
# against an empty list and does nothing. The initial header/preview-label
# also have to be set here (chained onto the same bind), since `focus`
# doesn't fire for the row fzf highlights by default before any navigation.
if [[ -n "$pos" ]]; then
  fzf_args+=(--bind "load:pos(${pos})+transform-header(${self_q} --swatches {1})+transform-preview-label(${self_q} --dims {1})")
else
  fzf_args+=(--bind "load:transform-header(${self_q} --swatches {1})+transform-preview-label(${self_q} --dims {1})")
fi

printf '%s' "${lines:+${lines}$'\n'}" | fzf "${fzf_args[@]}" || true
rm -rf "$GALLERY_THEMES_STATE"

# Reached only once the become() chain (however many theme<->backgrounds
# hops the user made) has really wound down -- i.e. Esc all the way out.
# Enter no longer falls through to a plain "print selection and exit"; the
# bind above both applies the theme and transitions to stage two itself.
exit 0
