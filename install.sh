#!/usr/bin/env bash
#
# install.sh -- install The Gallery Spoon, plugins, and CLI.
#
# Rationale: the Spoon and plugins are COPIED onto the boot volume (not
# symlinked) because macOS TCC denies launchd-started apps (Hammerspoon
# included) access to the external volume this repo lives on. A symlink
# would resolve back through that volume and fail the same way, so a real
# copy is required. Re-run this script after editing the Spoon or plugins
# to push changes across.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_EPOCH="$(date +%s)"
HOME_DIR="${HOME}"
SPOON_SRC="${SCRIPT_DIR}/Gallery.spoon"
SPOON_DEST="${HOME_DIR}/.hammerspoon/Spoons/Gallery.spoon"
PLUGINS_SRC="${SCRIPT_DIR}/plugins"
PLUGINS_DEST="${HOME_DIR}/.config/gallery/plugins"
CONFIG_DIR="${HOME_DIR}/.config/gallery"
BIN_SRC="${SCRIPT_DIR}/bin/gallery"
BIN_DEST="${HOME_DIR}/bin/gallery"
HS_INIT="${HOME_DIR}/.hammerspoon/init.lua"

DRY_RUN=0
UNINSTALL=0

for arg in "$@"; do
  case "${arg}" in
    --dry-run)
      DRY_RUN=1
      ;;
    --uninstall)
      UNINSTALL=1
      ;;
    *)
      echo "[gallery] unknown option: ${arg}" >&2
      exit 1
      ;;
  esac
done

run() {
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "[gallery] (dry-run) $*"
  else
    echo "[gallery] $*"
    "$@"
  fi
}

require_hammerspoon() {
  if [ ! -d "/Applications/Hammerspoon.app" ]; then
    echo "[gallery] Hammerspoon.app not found in /Applications" >&2
    echo "[gallery] install it with: brew install --cask hammerspoon" >&2
    exit 1
  fi
}

do_uninstall() {
  echo "[gallery] uninstalling"
  if [ -d "${SPOON_DEST}" ]; then
    run rm -rf "${SPOON_DEST}"
  else
    echo "[gallery] no Spoon installed at ${SPOON_DEST}"
  fi

  if [ -e "${BIN_DEST}" ]; then
    run rm -f "${BIN_DEST}"
  else
    echo "[gallery] no CLI installed at ${BIN_DEST}"
  fi

  echo "[gallery] leaving ${CONFIG_DIR} in place"
  echo "[gallery] leaving ${HS_INIT} in place -- Gallery load block was not removed automatically."
  echo "[gallery] to finish by hand, remove the block delimited by:"
  echo "[gallery]   -- gallery:begin"
  echo "[gallery]   -- gallery:end"
  echo "[gallery] from ${HS_INIT}"
  exit 0
}

if [ "${UNINSTALL}" -eq 1 ]; then
  do_uninstall
fi

require_hammerspoon

echo "[gallery] installing Spoon to ${SPOON_DEST}"
run mkdir -p "$(dirname "${SPOON_DEST}")"
run rsync -a --delete "${SPOON_SRC}/" "${SPOON_DEST}/"

echo "[gallery] installing plugins to ${PLUGINS_DEST}"
run mkdir -p "${PLUGINS_DEST}"
run rsync -a "${PLUGINS_SRC}/" "${PLUGINS_DEST}/"

echo "[gallery] ensuring config directories exist"
run mkdir -p "${CONFIG_DIR}/feed" "${CONFIG_DIR}/themes" "${CONFIG_DIR}/hooks"

echo "[gallery] installing CLI to ${BIN_DEST}"
run mkdir -p "${HOME_DIR}/bin"
run cp "${BIN_SRC}" "${BIN_DEST}"
run chmod +x "${BIN_DEST}"

GALLERY_BLOCK='-- gallery:begin
-- hs.ipc must be loaded or the hs command-line tool blocks forever.
require("hs.ipc")
hs.loadSpoon("Gallery")
spoon.Gallery:start()

do
  -- Debounced: an install copies several files at once, and reloading on each
  -- event leaves the IPC port down for many seconds (or crashes Hammerspoon).
  -- Both must be globals: a watcher held only by a local is garbage collected
  -- and silently stops firing after a few minutes.
  galleryReloadTimer = nil
  gallerySpoonWatcher = hs.pathwatcher.new(os.getenv("HOME") .. "/.hammerspoon/", function(files)
    for _, file in ipairs(files) do
      if file:sub(-4) == ".lua" then
        if galleryReloadTimer then galleryReloadTimer:stop() end
        galleryReloadTimer = hs.timer.doAfter(1.0, hs.reload)
        break
      end
    end
  end)
  gallerySpoonWatcher:start()
end
-- gallery:end'

if [ ! -e "${HS_INIT}" ]; then
  echo "[gallery] writing new ${HS_INIT}"
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "[gallery] (dry-run) create ${HS_INIT} with Gallery load block"
  else
    run mkdir -p "$(dirname "${HS_INIT}")"
    printf '%s\n' "${GALLERY_BLOCK}" > "${HS_INIT}"
  fi
elif ! grep -q "Gallery" "${HS_INIT}"; then
  echo "[gallery] appending Gallery block to existing ${HS_INIT}"
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "[gallery] (dry-run) append Gallery block to ${HS_INIT}"
  else
    {
      printf '\n'
      printf '%s\n' "${GALLERY_BLOCK}"
    } >> "${HS_INIT}"
  fi
else
  echo "[gallery] ${HS_INIT} already references Gallery, leaving it untouched"
fi

# --- skhd bindings ----------------------------------------------------------------
# Copied next to skhdrc, which includes it with `.load "gallery.skhd"` (added by
# the tiler installer in ai_voice_assistant). skhd is reloaded if it is running.
SKHD_DIR="${HOME_DIR}/.config/skhd"
if [ -d "${SKHD_DIR}" ]; then
  run install -m 644 "${SCRIPT_DIR}/skhd/gallery.skhd" "${SKHD_DIR}/gallery.skhd"
  if pgrep -xq skhd; then
    if [ "${DRY_RUN}" -eq 1 ]; then echo "[dry] skhd --reload"; else skhd --reload && echo "[gallery] skhd reloaded"; fi
  fi
else
  echo "[gallery] no ~/.config/skhd; skipping key bindings (install the tiler first)"
fi

# --- Hammerspoon reload -------------------------------------------------------------
# The init.lua pathwatcher reloads Hammerspoon (debounced) when the Spoon copy above
# changes, and the Spoon writes ~/.config/gallery/state/ready when it has started.
# We wait for that stamp rather than probing the IPC port: an hs client killed by
# a timeout mid-request has been seen to wedge or crash Hammerspoon.
READY="${CONFIG_DIR}/state/ready"
stamp_fresh() { [ -f "${READY}" ] && [ "$(cut -d' ' -f1 "${READY}")" -ge "${INSTALL_EPOCH}" ]; }
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "[dry] wait for the Gallery ready stamp, else reload or relaunch Hammerspoon"
elif ! pgrep -x "Hammerspoon" >/dev/null 2>&1; then
  run open -g -a Hammerspoon
  echo "[gallery] Hammerspoon started"
else
  waited=0
  while ! stamp_fresh && [ "${waited}" -lt 12 ]; do sleep 1; waited=$((waited + 1)); done
  if stamp_fresh; then
    echo "[gallery] Gallery reloaded and ready (${waited}s)"
  else
    # Reload through the file watcher, never over IPC: an hs client whose
    # conversation is cut by the reload hangs forever and can wedge the port.
    echo "[gallery] no reload observed; touching init.lua to trigger one"
    touch "${HS_INIT}"
    waited=0
    while ! stamp_fresh && [ "${waited}" -lt 12 ]; do sleep 1; waited=$((waited + 1)); done
    if stamp_fresh; then
      echo "[gallery] Gallery reloaded and ready (${waited}s after reload request)"
    else
      echo "[gallery] still not ready; relaunching Hammerspoon"
      osascript -e 'tell application "Hammerspoon" to quit' >/dev/null 2>&1 || true
      sleep 2; pkill -x Hammerspoon 2>/dev/null || true; sleep 1
      open -g -a Hammerspoon
    fi
  fi
fi

echo "[gallery] install complete"
