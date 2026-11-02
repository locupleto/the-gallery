#!/usr/bin/env bash
# Gallery TUI plugin: pick a wallpaper from the current theme's backgrounds
# in fzf, with a live image preview (iTerm inline images via chafa), and
# apply it via the gallery CLI.
#
#   backgrounds.sh                 run the interactive fzf picker (needs a tty)
#   backgrounds.sh --from-themes   same picker, but Esc becomes the theme
#                                  picker (gallery.themes/themes.sh) instead
#                                  of closing -- this is how themes.sh hands
#                                  off to this script on Enter, and how Esc
#                                  hands back, all via fzf's become() (in
#                                  place, no new window/process tree)
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

# pair_partner FILE -- for "<stem>.left.<ext>", print the matching
# "<stem>.right.<ext>" path when that file exists (a left/right pair, one
# wallpaper across two displays); print nothing otherwise. The list only
# ever shows the left file of a pair (`gallery bg list`), so the left name
# is the only one that needs resolving.
pair_partner() {
  local file="$1" base dir right
  base="$(basename "$file")"
  dir="$(dirname "$file")"
  case "$base" in
    *.left.*) right="${dir}/${base%.left.*}.right.${base##*.left.}" ;;
    *) return 0 ;;
  esac
  [[ -r "$right" ]] && printf '%s\n' "$right"
  return 0
}

# PAIR_GAP_PERMILLE -- the black strip between the halves of a stitched
# preview, standing in for the two displays' bezels (per mille of one half's
# width).
PAIR_GAP_PERMILLE=12

# stitch_pair LEFT RIGHT -- print the path of one image with LEFT and RIGHT
# side by side, as the two displays show them, so the preview shows the
# whole panorama instead of its left half. Drawn once by AppKit (JXA, on
# every Mac, no extra install) at 1600 px per half and cached under
# ~/.config/gallery/cache/pair-previews (inside the Gallery's own folder,
# so an uninstall takes it along), keyed by both paths and their
# modification times, so a replaced half draws a new preview. Prints
# nothing when drawing fails; the caller then shows the left half alone.
stitch_pair() {
  local left="$1" right="$2" cache key out
  cache="${GALLERY_CACHE_DIR:-${CONFIG_HOME}/gallery/cache}/pair-previews"
  key="$(printf '%s|%s|%s|%s' "$left" "$right" \
    "$(stat -f %m "$left" 2>/dev/null)" "$(stat -f %m "$right" 2>/dev/null)" | md5 -q 2>/dev/null)"
  [[ -n "$key" ]] || return 0
  out="${cache}/${key}.jpg"
  if [[ ! -s "$out" ]]; then
    mkdir -p "$cache" 2>/dev/null || return 0
    osascript -l JavaScript - "$left" "$right" "${out}.tmp" 1600 "$PAIR_GAP_PERMILLE" >/dev/null 2>&1 <<'JXA' || return 0
ObjC.import('AppKit');
function run(argv) {
  const [l, r, out, hw, gapPm] = argv;
  const L = $.NSImage.alloc.initWithContentsOfFile(l);
  const R = $.NSImage.alloc.initWithContentsOfFile(r);
  if (L.isNil() || R.isNil()) throw new Error('unreadable image');
  const w = parseInt(hw, 10);
  const h = Math.round(w * L.size.height / L.size.width);
  const gap = Math.max(2, Math.round(w * parseInt(gapPm, 10) / 1000));
  const W = 2 * w + gap;
  const rep = $.NSBitmapImageRep.alloc.initWithBitmapDataPlanesPixelsWidePixelsHighBitsPerSampleSamplesPerPixelHasAlphaIsPlanarColorSpaceNameBytesPerRowBitsPerPixel(
    null, W, h, 8, 4, true, false, 'NSDeviceRGBColorSpace', 0, 0);
  $.NSGraphicsContext.saveGraphicsState;
  $.NSGraphicsContext.setCurrentContext($.NSGraphicsContext.graphicsContextWithBitmapImageRep(rep));
  $.NSColor.blackColor.setFill;
  $.NSRectFill($.NSMakeRect(0, 0, W, h));
  // 1 = NSCompositingOperationCopy
  L.drawInRectFromRectOperationFraction($.NSMakeRect(0, 0, w, h), $.NSZeroRect, 1, 1.0);
  R.drawInRectFromRectOperationFraction($.NSMakeRect(w + gap, 0, w, h), $.NSZeroRect, 1, 1.0);
  $.NSGraphicsContext.restoreGraphicsState;
  // 3 = NSBitmapImageFileTypeJPEG
  const data = rep.representationUsingTypeProperties(3, $({ NSImageCompressionFactor: 0.85 }));
  if (!data.writeToFileAtomically(out, true)) throw new Error('write failed');
}
JXA
    mv -f "${out}.tmp" "$out" 2>/dev/null || return 0
  fi
  printf '%s\n' "$out"
}

# print_dims NAME_OR_PATH -- "NAME  WxH" (or "NAME  ?x?" if dims lookup
# fails), for fzf's `transform-preview-label` bind (see fzf_args below).
# A left/right pair reads "STEM  pair, 2 x WxH": one wallpaper, two
# displays. Deliberately kept separate from render_preview: this is the
# ONLY thing that ends up as fzf's preview-window border label, never mixed
# into the preview command's own stdout (see render_preview's comment for
# why).
print_dims() {
  local arg="$1" file dims base
  file="$(resolve_bg "$arg")"
  dims="$(image_dims "$file")"
  base="$(basename "$file")"
  if [[ -n "$(pair_partner "$file")" ]]; then
    printf '%s  pair, 2 x %sx%s\n' "${base%.left.*}" "${dims%% *}" "${dims##* }"
  else
    printf '%s  %sx%s\n' "$base" "${dims%% *}" "${dims##* }"
  fi
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

  # A left/right pair previews as the whole panorama (both halves, a bezel
  # strip between), not just the left file the list names.
  local right stitched
  right="$(pair_partner "$file")"
  if [[ -n "$right" ]]; then
    stitched="$(stitch_pair "$file" "$right")"
    [[ -n "$stitched" ]] && file="$stitched"
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

  # kitty and Ghostty keep images (kitty's graphics protocol, which chafa uses
  # there) on a layer of their own that fzf's preview refresh does not touch,
  # so each new image landed on top of the last one: delete them first.
  # iTerm2's inline images live in the text cells and go with them.
  [[ -n "${KITTY_WINDOW_ID:-}" || "${TERM:-}" == xterm-kitty || "${TERM:-}" == xterm-ghostty \
     || "${TERM_PROGRAM:-}" == ghostty ]] && printf '\033_Ga=d,d=A\033\\'
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
  local out err current name
  # `gallery bg list` exits 1 both when the verb is unknown and when the
  # theme simply has no wallpapers fetched yet. Only the former is a real
  # failure; the latter is an empty list (the caller shows a hint).
  if ! out="$("${GALLERY_BIN}" bg list 2>/dev/null)"; then
    err="$("${GALLERY_BIN}" bg list 2>&1 >/dev/null || true)"
    case "$err" in
      *"no backgrounds for theme"*) return 0 ;;
      *) return 1 ;;
    esac
  fi
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

from_themes=0
if [[ "${1:-}" == "--from-themes" ]]; then
  from_themes=1
  shift
fi

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

# The two plugins are installed side by side under .../gallery/plugins/, so
# resolve the sibling by path rather than assuming it's on PATH. Only
# needed in --from-themes mode (Esc becomes it); resolved unconditionally
# here since it's cheap and keeps the fzf_args block below simple.
THEMES_SH="$(cd "$(dirname "$SELF")/../gallery.themes" && pwd)/themes.sh"

if [[ -z "$lines" ]]; then
  # Wallpapers are never in the repo; they are fetched per machine (see
  # tools/fetch-omarchy-backgrounds.sh). Say so, with the command.
  echo
  echo "  No wallpapers fetched for theme '$(theme_name)' on this Mac."
  echo "  The theme is applied; only the desktop picture is unchanged."
  echo
  echo "  Fetch them with (from the the-gallery checkout):"
  echo "    tools/fetch-omarchy-backgrounds.sh $(theme_name)     # or --all"
  echo
  if [[ "$from_themes" -eq 1 ]]; then
    # Handed off from the theme picker: bounce back to it instead of
    # dumping the user out. Direct launch (key B): just close.
    echo "  Returning to the theme picker..."
    sleep 4
    exec "$THEMES_SH"
  fi
  sleep 4
  exit 0
fi

current="$("${GALLERY_BIN}" bg current 2>/dev/null || true)"
pos="$(current_pos "$current" "$lines" || true)"
theme="$(theme_name)"

self_q="$(printf '%q' "$SELF")"
themes_q="$(printf '%q' "$THEMES_SH")"

# The list pane is 40% of the window (preview-window=right:60%); on a 16"
# laptop screen that is ~38 columns, so keep the header short there (same idea as
# themes.sh's compact mode).
total_cols="${FZF_COLUMNS:-${COLUMNS:-$(tput cols 2>/dev/null || echo 160)}}"
[[ "$total_cols" =~ ^[0-9]+$ ]] || total_cols=160
if [[ $(( total_cols * 4 / 10 - 4 )) -lt 56 ]]; then
  if [[ "$from_themes" -eq 1 ]]; then
    header="${theme:-(unknown)}  Enter applies, Esc back"
  else
    header="${theme:-(unknown)}  Enter applies, Esc closes"
  fi
elif [[ "$from_themes" -eq 1 ]]; then
  header="Theme: ${theme:-(unknown)} -- Enter applies, Esc back to themes"
else
  header="Theme: ${theme:-(unknown)} -- Enter applies, Esc closes"
fi

gallery_q="$(printf '%q' "$GALLERY_BIN")"
header_q="$(printf '%q' "$header")"

fzf_args=(
  --delimiter=$'\t'
  --with-nth=2
  --height=100%
  --layout=reverse
  --border=rounded
  --no-multi
  --prompt='Background > '
  --header="$header"
  --preview="${self_q} --preview {1}"
  --preview-window=right:60%,border-rounded
  --preview-label=' Background '
  --bind "focus:transform-preview-label(${self_q} --dims {1})"
  # Enter applies the highlighted wallpaper and keeps the picker open, so
  # several can be tried in a row: set it (execute-silent waits for the
  # wallpaper hook), say which one is applied under the header, and reload
  # the list to move "(current)". Esc leaves (or goes back to the themes).
  # The cursor keeps its row across the reload (same order, same length).
  # Do not add --id-nth + --track to "follow" it: on fzf 0.74 that pair
  # drops every action after the reload and then ignores keys.
  --bind "enter:execute-silent(${gallery_q} bg set {1})+transform-header(printf '%s\\nApplied: %s' ${header_q} {1})+reload(${self_q} --list)"
)
# `load`, not `start`: the list is streamed in, so pos() on `start` runs
# against an empty list and does nothing. The initial preview-label also
# has to be set here (chained onto the same bind) since `focus` doesn't
# fire for the row fzf highlights by default before any navigation.
# unbind(load) because Enter's reload fires `load` again, and pos() would
# then pull the cursor back to the wallpaper that was current at start.
if [[ -n "$pos" ]]; then
  fzf_args+=(--bind "load:pos(${pos})+transform-preview-label(${self_q} --dims {1})+unbind(load)")
else
  fzf_args+=(--bind "load:transform-preview-label(${self_q} --dims {1})+unbind(load)")
fi
if [[ "$from_themes" -eq 1 ]]; then
  # Only when we were handed off from the theme picker: Esc becomes it
  # again (in place, via execve -- see themes.sh's own enter bind) instead
  # of the default abort-and-exit.
  fzf_args+=(--bind "esc:become(${themes_q})")
fi

# Enter no longer ends fzf (see its bind above), so this returns only on
# Esc when launched directly: close quietly.
printf '%s\n' "$lines" | fzf "${fzf_args[@]}" >/dev/null || true

exit 0
