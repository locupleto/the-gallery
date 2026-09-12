#!/usr/bin/env bash
#
# 30-wallpaper.sh -- theme-set hook for The Gallery: applies a per-theme
# desktop wallpaper, if one has been fetched.
#
# Installed by install.sh into ~/.config/gallery/hooks/theme-set.d/ and run
# by `gallery theme set <name>` (and, indirectly, `gallery theme next`) with
# the new theme name as $1, alongside every other executable file in that
# directory (name order).
#
# Wallpapers are NOT vendored into this repo (see
# tools/fetch-omarchy-backgrounds.sh) -- this hook only looks in the live
# config dir, under themes/<name>/backgrounds/. If that directory does not
# exist or has no images, this is a silent no-op (logged, not an error):
# most themes will simply have no wallpaper until fetched.
#
# Selection order:
#   1. An explicit override given as $2 (a filename inside the theme's
#      backgrounds dir, or an absolute path) -- used by `gallery bg set`/
#      `next`/`prev` for instant-apply, overriding everything below.
#   2. The filename recorded for this theme in state/backgrounds.json
#      (see `gallery bg`), if that file still exists in the theme's
#      backgrounds dir.
#   3. A file named "default.<ext>" if present.
#   4. Otherwise the lexically first image (by filename).
# Recognised extensions (case-insensitive): jpg jpeg png heic webp.
#
# KNOWN macOS LIMITATION: "set picture of every desktop" (System Events)
# only changes the picture for the CURRENT Space on each display. Other,
# not-currently-visible Spaces keep whatever wallpaper they already had --
# there is no public API/AppleScript verb that reaches every Space on every
# display in one call. Switching to each Space and re-running would work but
# is not done here.
#
# Set GALLERY_WALLPAPER_DRY_RUN=1 to print the chosen path and the
# osascript this hook would run, without applying anything or touching the
# log file.
#
set -euo pipefail

THEME="${1:?usage: 30-wallpaper.sh <theme-name> [filename-or-path]}"
OVERRIDE="${2:-}"
LOG_FILE="${HOME}/Library/Logs/gallery.log"
CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/gallery"
BG_DIR="${CONFIG_DIR}/themes/${THEME}/backgrounds"
STATE_FILE="${CONFIG_DIR}/state/backgrounds.json"

mkdir -p "$(dirname "${LOG_FILE}")"

log() {
  printf '%s wallpaper: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "${LOG_FILE}"
}

# is_image_ext <filename> -- true if the extension is one of the
# recognised image types, case-insensitively. Written for bash 3.2
# (macOS /bin/bash): no ${var,,}, no mapfile.
is_image_ext() {
  local ext
  ext="$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')"
  case "${ext}" in
    jpg|jpeg|png|heic|webp) return 0 ;;
    *) return 1 ;;
  esac
}

# first_image <glob...> -- prints the first image among the (already
# lexically sorted) glob matches, or nothing.
first_image() {
  local f
  for f in "$@"; do
    [ -f "${f}" ] || continue
    if is_image_ext "${f}"; then
      printf '%s' "${f}"
      return 0
    fi
  done
  return 0
}

# recorded_choice -- prints the filename recorded for THEME in
# state/backgrounds.json (written by `gallery bg set`/`next`/`prev`), or
# nothing if the state file is missing, unreadable, or has no entry for
# this theme. Uses only the python3 stdlib json module -- no jq dependency,
# matching the CLI's own reader/writer.
recorded_choice() {
  [ -f "${STATE_FILE}" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -c '
import json, sys

path, theme = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
if isinstance(data, dict):
    val = data.get(theme)
    if isinstance(val, str) and val:
        sys.stdout.write(val)
' "${STATE_FILE}" "${THEME}"
}

if [ -n "${OVERRIDE}" ]; then
  # Explicit override from `gallery bg` -- a bare filename resolves inside
  # this theme's backgrounds dir; an absolute path is used as-is. This is
  # the one case that does not need BG_DIR to exist.
  case "${OVERRIDE}" in
    /*) CHOSEN="${OVERRIDE}" ;;
    *) CHOSEN="${BG_DIR}/${OVERRIDE}" ;;
  esac
  if [ ! -f "${CHOSEN}" ]; then
    log "FAILED: override not found: ${CHOSEN}"
    echo "gallery: 30-wallpaper.sh: override file not found: ${CHOSEN}" >&2
    exit 1
  fi
else
  if [ ! -d "${BG_DIR}" ]; then
    log "no wallpaper for ${THEME}"
    exit 0
  fi

  # Prefer the recorded per-theme choice (if the file still exists and is
  # still a recognised image type); otherwise fall back to a file named
  # default.<ext>; otherwise the lexically first image. Pathname expansion
  # already sorts its matches, so the first accepted match is the
  # deterministic choice. Glob on real wildcards ("default.*", "*") and
  # filter by extension in code: brace-expanding literal extensions would
  # defeat nullglob, since "default.jpg" with no such file is plain text,
  # not a pattern, and nullglob only elides patterns containing wildcards.
  CHOSEN=""
  RECORDED="$(recorded_choice)"
  if [ -n "${RECORDED}" ] && [ -f "${BG_DIR}/${RECORDED}" ] && is_image_ext "${RECORDED}"; then
    CHOSEN="${BG_DIR}/${RECORDED}"
  fi

  if [ -z "${CHOSEN}" ]; then
    shopt -s nullglob
    CHOSEN="$(first_image "${BG_DIR}"/default.*)"
    [ -n "${CHOSEN}" ] || CHOSEN="$(first_image "${BG_DIR}"/*)"
    shopt -u nullglob
  fi

  if [ -z "${CHOSEN}" ]; then
    log "no wallpaper for ${THEME}"
    exit 0
  fi
fi

APPLESCRIPT_SRC="$(cat <<EOF
tell application "System Events"
    set picture of every desktop to POSIX file "${CHOSEN}"
end tell
EOF
)"

if [ "${GALLERY_WALLPAPER_DRY_RUN:-0}" = "1" ]; then
  echo "wallpaper (dry run): would apply ${CHOSEN}"
  echo "wallpaper (dry run): would run:"
  echo "${APPLESCRIPT_SRC}"
  exit 0
fi

if echo "${APPLESCRIPT_SRC}" | osascript >/dev/null; then
  log "applied ${CHOSEN} for ${THEME}"
else
  log "FAILED to apply ${CHOSEN} for ${THEME}"
  echo "gallery: 30-wallpaper.sh: osascript failed to apply ${CHOSEN}" >&2
  exit 1
fi
