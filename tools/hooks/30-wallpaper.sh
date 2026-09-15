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
# macOS LIMITATION, AND HOW THIS HOOK WORKS AROUND IT: "set picture of
# every desktop" (System Events) only writes the display-level default and
# the primary Space's entry in the wallpaper store
# (~/Library/Application Support/com.apple.wallpaper/Store/Index.plist).
# Any Space that was ever given its own picture (System Settings, or an
# earlier spanning setup) carries a per-Space override there that shadows
# the default -- and System Events can neither read nor write those, so it
# happily reports the new picture while the Space keeps its old one.
# Walking the Spaces and re-applying does not help either, for the same
# reason. So after the System Events apply, this hook copies the primary
# Space's freshly written Desktop configuration into every other Space
# entry in the store and restarts WallpaperAgent, which re-reads it. This
# is best-effort: if the store is missing, unreadable, or does not yet show
# the chosen picture on the primary entry, the step is logged and skipped
# (the visible Space is still correct). Set GALLERY_WALLPAPER_ALL_SPACES=0
# to keep the plain System Events behaviour.
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
STORE_FILE="${HOME}/Library/Application Support/com.apple.wallpaper/Store/Index.plist"

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

ALL_SPACES="${GALLERY_WALLPAPER_ALL_SPACES:-1}"
SYNC_ERR="${TMPDIR:-/tmp}/gallery-wallpaper-sync.$$.err"

# apply_visible -- sets the picture on the visible Space of every display.
apply_visible() {
  echo "${APPLESCRIPT_SRC}" | osascript >/dev/null
}

# sync_store -- copies the primary Space's Desktop configuration into every
# other Space entry of the wallpaper store (its Default and per-display
# sub-entries) whose picture differs, and prints how many were rewritten.
# Waits briefly for WallpaperAgent to have persisted the System Events
# apply into the primary entry first. Returns 1 (reason on stderr) if the
# store cannot be used, so the caller can log and move on. Uses only the
# python3 stdlib, like recorded_choice.
sync_store() {
  [ -f "${STORE_FILE}" ] || { echo "store not found: ${STORE_FILE}" >&2; return 1; }
  command -v python3 >/dev/null 2>&1 || { echo "python3 not available" >&2; return 1; }
  python3 - "${STORE_FILE}" "${CHOSEN}" <<'PY'
import copy, os, plistlib, sys, time, urllib.parse

store, chosen = sys.argv[1], sys.argv[2]
want = "file://" + urllib.parse.quote(os.path.abspath(chosen))

def picture(entry):
    try:
        cfg = plistlib.loads(entry["Default"]["Desktop"]["Content"]["Choices"][0]["Configuration"])
        return cfg["url"]["relative"]
    except Exception:
        return None

# WallpaperAgent writes the store shortly after the System Events apply;
# give it a moment before concluding the primary entry was not updated.
deadline = time.time() + 5
while True:
    with open(store, "rb") as fh:
        data = plistlib.load(fh)
    spaces = data.get("Spaces")
    primary = spaces.get("") if isinstance(spaces, dict) else None
    if primary and picture(primary) == want:
        break
    if time.time() > deadline:
        sys.stderr.write("primary Space entry does not show the chosen picture\n")
        sys.exit(1)
    time.sleep(0.5)

src = primary["Default"]["Desktop"]
stale = [u for u, e in spaces.items() if u and isinstance(e, dict) and picture(e) != want]
for uuid in stale:
    entry = spaces[uuid]
    entry.setdefault("Default", {})["Desktop"] = copy.deepcopy(src)
    for disp in entry.get("Displays", {}).values():
        if isinstance(disp, dict):
            disp["Desktop"] = copy.deepcopy(src)
if stale:
    with open(store, "wb") as fh:
        plistlib.dump(data, fh, fmt=plistlib.FMT_BINARY)
print(len(stale))
PY
}

if [ "${GALLERY_WALLPAPER_DRY_RUN:-0}" = "1" ]; then
  echo "wallpaper (dry run): would apply ${CHOSEN}"
  echo "wallpaper (dry run): would run:"
  echo "${APPLESCRIPT_SRC}"
  if [ "${ALL_SPACES}" = "1" ]; then
    if [ -f "${STORE_FILE}" ]; then
      echo "wallpaper (dry run): would then sync every Space entry in ${STORE_FILE} and restart WallpaperAgent"
    else
      echo "wallpaper (dry run): would skip the Space sync (wallpaper store not found)"
    fi
  fi
  exit 0
fi

if apply_visible; then
  log "applied ${CHOSEN} for ${THEME}"
else
  log "FAILED to apply ${CHOSEN} for ${THEME}"
  echo "gallery: 30-wallpaper.sh: osascript failed to apply ${CHOSEN}" >&2
  exit 1
fi

if [ "${ALL_SPACES}" = "1" ]; then
  if N="$(sync_store 2>"${SYNC_ERR}")"; then
    if [ "${N}" -gt 0 ]; then
      # WallpaperAgent only re-reads the store on launch; launchd brings it
      # straight back.
      killall WallpaperAgent 2>/dev/null || true
      log "synced ${N} other Space entries to ${CHOSEN}; WallpaperAgent restarted"
    else
      log "all Space entries already on ${CHOSEN}"
    fi
  else
    log "Space sync skipped: $(tr '\n' ' ' <"${SYNC_ERR}")"
  fi
  rm -f "${SYNC_ERR}"
fi
exit 0
