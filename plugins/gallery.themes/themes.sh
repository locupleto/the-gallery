#!/usr/bin/env bash
# Gallery TUI plugin: pick a Gallery theme in fzf (Omarchy's theme-menu, in
# a floating terminal) and apply it via the gallery CLI.
#
#   themes.sh                  run the interactive fzf picker (needs a tty)
#   themes.sh --list           print the fzf input lines and exit (for testing, no tty needed)
#   themes.sh --preview NAME   render NAME's palette card and exit (no tty needed;
#                              this is what fzf itself shells back out to on
#                              every highlight change)
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

GALLERY_BIN="${HOME}/bin/gallery"
THEME_DIR="${HOME}/.config/gallery/themes"
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

# swatch LABEL HEX -- one truecolor block + label + hex value, or nothing if
# HEX is empty/malformed (missing-key tolerance lives here).
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
  printf '\033[48;2;%d;%d;%dm   \033[0m  %-16s #%s\n' "$r" "$g" "$b" "$label" "$hex"
}

# render_preview NAME -- the palette card fzf's --preview shells out to.
render_preview() {
  local name="$1"
  local file="${THEME_DIR}/${name}/colors.toml"
  printf '%s\n\n' "$name"
  if [[ ! -f "$file" ]]; then
    echo "(no colors.toml found)"
    return 0
  fi
  local key
  for key in accent background foreground \
             red yellow green cyan blue magenta \
             bright_red bright_yellow bright_green bright_cyan bright_blue bright_magenta; do
    swatch "$key" "$(get_val "$file" "$key")"
  done
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

current="$("${GALLERY_BIN}" theme current 2>/dev/null || true)"
pos="$(current_pos "$current" || true)"

fzf_args=(
  --delimiter=$'\t'
  --with-nth=2
  --height=100%
  --layout=reverse
  --border=rounded
  --no-multi
  --prompt='Theme > '
  --header="Current: ${current:-(none)} -- Enter applies, Esc closes"
  --preview="$(printf '%q' "$SELF") --preview {1}"
  --preview-window=right:50%
)
# `load`, not `start`: the list is streamed in, so pos() on `start` runs
# against an empty list and does nothing.
if [[ -n "$pos" ]]; then
  fzf_args+=(--bind "load:pos(${pos})")
fi

selected=""
status=0
selected=$(list_lines | fzf "${fzf_args[@]}") || status=$?

if [[ -z "$selected" ]]; then
  # Esc / no selection: close quietly.
  exit 0
fi

name=$(cut -f1 <<<"$selected")

"${GALLERY_BIN}" theme set "$name"

exit 0
