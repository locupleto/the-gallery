#!/usr/bin/env bash
# Gallery TUI plugin: pick a wallpaper from the current theme's backgrounds
# in fzf, with a live image preview (iTerm inline images via chafa), and
# apply it via the gallery CLI.
#
#   backgrounds.sh                 run the interactive fzf picker (needs a tty)
#   backgrounds.sh --list          print the fzf input lines and exit (for testing, no tty needed)
#   backgrounds.sh --preview FILE  render FILE's image and exit (no tty needed;
#                                  this is what fzf itself shells back out to on
#                                  every highlight change). FILE may be a bare
#                                  basename (resolved against the current
#                                  theme's backgrounds dir) or a full path.
#   backgrounds.sh --dims FILE     print "FILE  WxH" and exit -- this is what
#                                  fzf's `transform-preview-label` shells out
#                                  to (see fzf_args below) to caption the
#                                  preview window's border with the filename
#                                  and pixel dimensions, entirely separate
#                                  from the image bytes on the preview
#                                  command's stdout (see render_preview's
#                                  comment for why that separation matters).
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

GALLERY_BIN="${HOME}/bin/gallery"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
THEME_CURRENT_DIR="${CONFIG_HOME}/gallery/themes/current"
BG_DIR="${THEME_CURRENT_DIR}/backgrounds"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# theme_name -- basename of the resolved `current` symlink target, for the
# header line. Falls back to the literal dir name if it isn't a symlink (or
# doesn't exist), so a missing/odd theme dir never aborts the script.
theme_name() {
  local resolved
  if resolved="$(cd "$THEME_CURRENT_DIR" 2>/dev/null && pwd -P)"; then
    basename "$resolved"
  else
    basename "$THEME_CURRENT_DIR" 2>/dev/null || true
  fi
}

# resolve_bg NAME_OR_PATH -- print the absolute path for a bare basename
# (looked up under the current theme's backgrounds dir), or pass an existing
# path straight through unchanged.
resolve_bg() {
  local arg="$1"
  if [[ "$arg" == */* && -e "$arg" ]]; then
    printf '%s\n' "$arg"
  else
    printf '%s\n' "${BG_DIR}/${arg}"
  fi
}

# image_dims FILE -- prints "WIDTH HEIGHT" (space-separated, via sips), or
# nothing if the file isn't a readable image. Shared by render_preview
# (sizing) and print_dims (the --dims mode below).
image_dims() {
  local file="$1" dims width height
  dims="$(sips -g pixelWidth -g pixelHeight "$file" 2>/dev/null)" || return 0
  width="$(printf '%s\n' "$dims" | sed -n 's/^[[:space:]]*pixelWidth:[[:space:]]*//p')"
  height="$(printf '%s\n' "$dims" | sed -n 's/^[[:space:]]*pixelHeight:[[:space:]]*//p')"
  [[ -n "$width" && -n "$height" ]] && printf '%s %s\n' "$width" "$height"
}

# print_dims NAME_OR_PATH -- "NAME  WxH" (or "NAME  ?x?" if dims lookup
# fails), for fzf's `transform-preview-label` bind (see fzf_args below).
# Deliberately kept separate from render_preview: this is the ONLY thing
# that ends up as fzf's preview-window border label, never mixed into the
# preview command's own stdout (see render_preview's comment for why).
print_dims() {
  local arg="$1" file dims
  file="$(resolve_bg "$arg")"
  dims="$(image_dims "$file")"
  printf '%s  %sx%s\n' "$(basename "$file")" "${dims%% *}" "${dims##* }"
}

# render_preview NAME_OR_PATH -- the image card fzf's --preview shells out
# to: just the image, sized from $FZF_PREVIEW_COLUMNS / $FZF_PREVIEW_LINES.
# Never fails loudly -- a missing/unreadable file just prints a short
# message in the preview pane.
#
# This prints the image ALONE, with no accompanying text (filename/dims go
# through fzf's `transform-preview-label` instead -- see print_dims above
# and fzf_args below), and that separation is load-bearing: measured
# empirically against this fzf build (0.74.4) inside this picker's actual
# preview pane, ANY plain stdout text sharing a preview invocation with the
# image -- before OR after it -- causes fzf's preview-window compositor to
# either drop the image (text first) or silently swallow the text (image
# first). Only an invocation that emits the image and nothing else renders
# correctly.
#
# Rendering path, in order of preference:
#   1. chafa (Unicode/ANSI truecolor art, or iTerm2's native protocol when
#      chafa detects iTerm) -- this is the only path confirmed to work
#      *inside* this picker's preview pane -- install it
#      (`brew install chafa`) for a working live preview.
#   2. iTerm2's native inline-image protocol (OSC 1337), written directly
#      to /dev/tty -- this is what fzf-preview.sh falls back to (imgcat)
#      when chafa isn't installed. NOTE: this path does NOT render reliably
#      inside fzf's preview pane on this build -- a direct /dev/tty write
#      races fzf's own screen redraws and corrupts the transfer (iTerm
#      shows its broken-image glyph). It works fine outside of fzf (a
#      plain script printing it does render), so it's kept as a
#      best-effort fallback for that case.
#   3. `file`'s one-line description, if neither is available.
render_preview() {
  local arg="$1" file dims width height cols rows img_rows b64
  file="$(resolve_bg "$arg")"

  if [[ ! -r "$file" ]]; then
    printf '(not readable: %s)\n' "$file"
    return 0
  fi

  dims="$(image_dims "$file")"
  width="${dims%% *}"
  height="${dims##* }"

  cols="${FZF_PREVIEW_COLUMNS:-80}"
  rows="${FZF_PREVIEW_LINES:-40}"
  # Ask for a height that matches the image's own aspect ratio (scaled to
  # $cols, correcting for terminal cells being roughly twice as tall as
  # wide) rather than nearly the whole pane -- iTerm reserves screen rows
  # for exactly the height we declare regardless of how much of that box
  # the (aspect-preserved) image actually fills, so asking for the full
  # pane height leaves a lot of dead space below a widescreen wallpaper.
  if [[ -n "$width" && -n "$height" && "$width" -gt 0 ]]; then
    img_rows=$(( (cols * height) / (2 * width) ))
    [[ "$img_rows" -lt 1 ]] && img_rows=1
    [[ "$img_rows" -gt "$rows" ]] && img_rows="$rows"
  else
    img_rows="$rows"
  fi

  if command -v chafa >/dev/null 2>&1; then
    chafa -s "${cols}x${img_rows}" "$file" 2>/dev/null
  elif command -v imgcat >/dev/null 2>&1; then
    imgcat -W "$cols" -H "$img_rows" "$file" >/dev/tty 2>/dev/null
  else
    b64="$(base64 < "$file" 2>/dev/null | tr -d '\n')"
    if [[ -n "$b64" ]]; then
      printf '\033]1337;File=inline=1;width=%d;height=%d;preserveAspectRatio=1:%s\a\n' \
        "$cols" "$img_rows" "$b64" >/dev/tty 2>/dev/null
    else
      file "$file" 2>/dev/null || echo "(unable to preview image)"
    fi
  fi
}

# list_lines -- the fzf input: one tab-delimited line per background.
#   field 1: bare basename (drives --preview and `gallery bg set`)
#   field 2: display text shown/searched in fzf ("(current)" annotation
#            added here since `bg list` itself only promises bare names)
# Returns non-zero (nothing printed) if `gallery bg list` isn't supported
# yet by the installed CLI -- caller decides how to report that.
list_lines() {
  local out current name
  out="$("${GALLERY_BIN}" bg list 2>/dev/null)" || return 1
  current="$("${GALLERY_BIN}" bg current 2>/dev/null)" || current=""
  printf '%s\n' "$out" | while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ -n "$current" && "$name" == "$current" ]]; then
      printf '%s\t%s (current)\n' "$name" "$name"
    else
      printf '%s\t%s\n' "$name" "$name"
    fi
  done
}

# current_pos CURRENT LINES -- 1-based line number of CURRENT within LINES
# (list_lines' output), so fzf can start with the cursor already on the
# active background. Empty/failure if not found -- caller tolerates that.
current_pos() {
  local current="$1" lines="$2" n=0 name
  while IFS=$'\t' read -r name _; do
    n=$((n + 1))
    if [[ "$name" == "$current" ]]; then
      printf '%s\n' "$n"
      return 0
    fi
  done <<<"$lines"
  return 1
}

case "${1:-}" in
  --preview)
    render_preview "${2:?usage: backgrounds.sh --preview <file>}"
    exit 0
    ;;
  --dims)
    print_dims "${2:?usage: backgrounds.sh --dims <file>}"
    exit 0
    ;;
  --list)
    if [[ ! -x "$GALLERY_BIN" ]]; then
      echo "gallery CLI not found at ${GALLERY_BIN}" >&2
      exit 1
    fi
    if ! list_lines; then
      echo "gallery CLI does not support 'bg' yet (needs 'gallery bg list') -- cannot list backgrounds." >&2
      exit 1
    fi
    exit 0
    ;;
esac

if [[ ! -x "$GALLERY_BIN" ]]; then
  echo "gallery CLI not found at ${GALLERY_BIN} -- cannot list backgrounds."
  sleep 3
  exit 1
fi

if ! command -v fzf >/dev/null 2>&1; then
  echo "fzf is not installed -- cannot show the background picker."
  sleep 3
  exit 1
fi

lines="$(list_lines)"
if [[ $? -ne 0 ]]; then
  echo "gallery CLI does not support 'bg' yet (needs 'gallery bg list/current/set') -- cannot show the background picker."
  sleep 3
  exit 1
fi

if [[ -z "$lines" ]]; then
  echo "No backgrounds found for the current theme."
  sleep 3
  exit 0
fi

current="$("${GALLERY_BIN}" bg current 2>/dev/null || true)"
pos="$(current_pos "$current" "$lines" || true)"
theme="$(theme_name)"

self_q="$(printf '%q' "$SELF")"

fzf_args=(
  --delimiter=$'\t'
  --with-nth=2
  --height=100%
  --layout=reverse
  --border=rounded
  --no-multi
  --prompt='Background > '
  --header="Theme: ${theme:-(unknown)} -- Enter applies, Esc closes"
  --preview="${self_q} --preview {1}"
  --preview-window=right:60%,border-rounded
  --preview-label=' Background '
  --bind "focus:transform-preview-label(${self_q} --dims {1})"
)
# `load`, not `start`: the list is streamed in, so pos() on `start` runs
# against an empty list and does nothing. The initial preview-label also
# has to be set here (chained onto the same bind) since `focus` doesn't
# fire for the row fzf highlights by default before any navigation.
if [[ -n "$pos" ]]; then
  fzf_args+=(--bind "load:pos(${pos})+transform-preview-label(${self_q} --dims {1})")
else
  fzf_args+=(--bind "load:transform-preview-label(${self_q} --dims {1})")
fi

selected=""
status=0
selected=$(printf '%s\n' "$lines" | fzf "${fzf_args[@]}") || status=$?

if [[ -z "$selected" ]]; then
  # Esc / no selection: close quietly.
  exit 0
fi

name=$(cut -f1 <<<"$selected")

"${GALLERY_BIN}" bg set "$name"

exit 0
