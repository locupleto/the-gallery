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
THEMES_SRC="${SCRIPT_DIR}/themes"
THEMES_DEST="${CONFIG_DIR}/themes"
THEME_HOOKS_SRC="${SCRIPT_DIR}/tools/hooks"
THEME_HOOKS_DEST="${CONFIG_DIR}/hooks/theme-set.d"
RENDER_TOOL_SRC="${SCRIPT_DIR}/tools/render-theme.py"
RENDER_TOOL_DEST="${CONFIG_DIR}/bin/render-theme.py"
DEFAULT_THEME="tokyo-night"
BIN_SRC="${SCRIPT_DIR}/bin/gallery"
BIN_DEST="${HOME_DIR}/bin/gallery"
HS_BIN_SRC="${SCRIPT_DIR}/bin/gallery-hs"
HS_BIN_DEST="${HOME_DIR}/bin/gallery-hs"
TUI_BIN_SRC="${SCRIPT_DIR}/bin/gallery-tui"
TUI_BIN_DEST="${HOME_DIR}/bin/gallery-tui"
MENU_BIN_SRC="${SCRIPT_DIR}/bin/gallery-menu"
MENU_BIN_DEST="${HOME_DIR}/bin/gallery-menu"
BORDERS_BIN_SRC="${SCRIPT_DIR}/bin/gallery-borders"
BORDERS_BIN_DEST="${HOME_DIR}/bin/gallery-borders"
QML_BIN_SRC="${SCRIPT_DIR}/bin/gallery-qml"
QML_BIN_DEST="${HOME_DIR}/bin/gallery-qml"
AGENT_BIN_SRC="${SCRIPT_DIR}/bin/gallery-agent"
AGENT_BIN_DEST="${HOME_DIR}/bin/gallery-agent"
QML_SRC="${SCRIPT_DIR}/qml"
QML_DEST="${CONFIG_DIR}/qml"
PATCHES_SRC="${SCRIPT_DIR}/patches"
PATCHES_DEST="${CONFIG_DIR}/patches"
OMARCHY_THEME_LINK="${HOME_DIR}/.config/omarchy/current/theme"
OMARCHY_STATE_THEME_LINK="${HOME_DIR}/.local/state/omarchy/current/theme"
OMARCHY_THEME_TARGET="${CONFIG_DIR}/themes/current"
HS_INIT="${HOME_DIR}/.hammerspoon/init.lua"

DRY_RUN=0
UNINSTALL=0
SKIP_TILER=0
RESTART_TILER=0

usage() {
  cat <<'USAGE' >&2
usage: install.sh [--dry-run] [--uninstall] [--skip-tiler] [--restart-tiler]
  --dry-run        print what would happen, change nothing
  --uninstall      remove the Gallery (and, unless --skip-tiler, the tiler)
  --skip-tiler     do not run tiler/install.sh (yabai/skhd/borders/Learn)
  --restart-tiler  pass --restart through to tiler/install.sh, forcing a
                   yabai/skhd restart even if their config did not change
USAGE
}

for arg in "$@"; do
  case "${arg}" in
    --dry-run)
      DRY_RUN=1
      ;;
    --uninstall)
      UNINSTALL=1
      ;;
    --skip-tiler)
      SKIP_TILER=1
      ;;
    --restart-tiler)
      RESTART_TILER=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "[gallery] unknown option: ${arg}" >&2
      usage
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

# Optional tools used by individual tui plugins. Missing ones only degrade
# the plugin that needs them, so this is advisory, never fatal.
advise_optional_tools() {
  local pair tool formula
  # command:formula -- superfile's command is spf.
  for pair in fzf:fzf chafa:chafa btop:btop spf:superfile; do
    tool="${pair%%:*}"
    formula="${pair#*:}"
    if ! command -v "${tool}" >/dev/null 2>&1; then
      echo "[gallery] optional: ${tool} not found -- install with: brew install ${formula}" >&2
    fi
  done
}

do_uninstall() {
  echo "[gallery] uninstalling"

  if [ "${SKIP_TILER}" -eq 1 ]; then
    echo "[gallery] --skip-tiler: not running tiler/install.sh --uninstall"
  else
    tiler_args=(--uninstall)
    [ "${DRY_RUN}" -eq 1 ] && tiler_args+=(--dry-run)
    echo "[gallery] running tiler/install.sh ${tiler_args[*]}"
    "${SCRIPT_DIR}/tiler/install.sh" "${tiler_args[@]}"
  fi

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

  if [ -e "${HS_BIN_DEST}" ]; then
    run rm -f "${HS_BIN_DEST}"
  else
    echo "[gallery] no CLI installed at ${HS_BIN_DEST}"
  fi
  run rm -f "${TUI_BIN_DEST}" "${MENU_BIN_DEST}" "${QML_BIN_DEST}" "${BORDERS_BIN_DEST}" "${AGENT_BIN_DEST}"

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
advise_optional_tools

echo "[gallery] installing Spoon to ${SPOON_DEST}"
run mkdir -p "$(dirname "${SPOON_DEST}")"
run rsync -a --delete "${SPOON_SRC}/" "${SPOON_DEST}/"

echo "[gallery] installing plugins to ${PLUGINS_DEST}"
run mkdir -p "${PLUGINS_DEST}"
# Per-plugin --delete so files a plugin no longer ships (an old index.html,
# say) do not linger; third-party plugins living beside ours are untouched.
for plugin_dir in "${PLUGINS_SRC}"/*/; do
  [ -d "${plugin_dir}" ] || continue
  run rsync -a --delete "${plugin_dir}" "${PLUGINS_DEST}/$(basename "${plugin_dir}")/"
done

echo "[gallery] ensuring config directories exist"
run mkdir -p "${CONFIG_DIR}/feed" "${CONFIG_DIR}/themes" "${CONFIG_DIR}/hooks"

echo "[gallery] installing themes to ${THEMES_DEST}"
run mkdir -p "${THEMES_DEST}"
# No --delete: user-authored themes may already live under THEMES_DEST, and
# the `current` symlink (also under THEMES_DEST) must never be touched here.
run rsync -a --exclude 'current' "${THEMES_SRC}/" "${THEMES_DEST}/"

echo "[gallery] installing theme renderer to ${RENDER_TOOL_DEST}"
run mkdir -p "$(dirname "${RENDER_TOOL_DEST}")"
run cp "${RENDER_TOOL_SRC}" "${RENDER_TOOL_DEST}"
run chmod +x "${RENDER_TOOL_DEST}"

echo "[gallery] installing theme-set hook examples to ${THEME_HOOKS_DEST}"
run mkdir -p "${THEME_HOOKS_DEST}"
if [ -d "${THEME_HOOKS_SRC}" ]; then
  for hook in "${THEME_HOOKS_SRC}"/*; do
    [ -f "${hook}" ] || continue
    run install -m 755 "${hook}" "${THEME_HOOKS_DEST}/$(basename "${hook}")"
  done
fi

echo "[gallery] installing qml shim tree to ${QML_DEST}"
run mkdir -p "${QML_DEST}"
if [ -d "${QML_SRC}" ]; then
  run rsync -a --delete "${QML_SRC}/" "${QML_DEST}/"
else
  echo "[gallery] no qml/ directory in this checkout yet -- skipping (a qml-kind plugin will not run until it is added)"
fi

echo "[gallery] installing patches to ${PATCHES_DEST}"
run mkdir -p "${PATCHES_DEST}"
if [ -d "${PATCHES_SRC}" ]; then
  run rsync -a --delete "${PATCHES_SRC}/" "${PATCHES_DEST}/"
fi

if [ ! -e "${THEMES_DEST}/current" ]; then
  if [ -d "${THEMES_DEST}/${DEFAULT_THEME}" ]; then
    echo "[gallery] no current theme set, pointing 'current' at ${DEFAULT_THEME}"
    run ln -s "${DEFAULT_THEME}" "${THEMES_DEST}/current"
  else
    echo "[gallery] no current theme set, and default theme '${DEFAULT_THEME}' is not installed; leaving 'current' unset" >&2
  fi
fi

echo "[gallery] installing CLI to ${BIN_DEST}"
run mkdir -p "${HOME_DIR}/bin"
run cp "${BIN_SRC}" "${BIN_DEST}"
run chmod +x "${BIN_DEST}"

echo "[gallery] installing hs watchdog CLI to ${HS_BIN_DEST}"
run cp "${HS_BIN_SRC}" "${HS_BIN_DEST}"
run chmod +x "${HS_BIN_DEST}"

echo "[gallery] installing terminal-window helpers to ${TUI_BIN_DEST}, ${MENU_BIN_DEST}"
run cp "${TUI_BIN_SRC}" "${TUI_BIN_DEST}"
run cp "${MENU_BIN_SRC}" "${MENU_BIN_DEST}"
run chmod +x "${TUI_BIN_DEST}" "${MENU_BIN_DEST}"

echo "[gallery] installing theme-aware borders helper to ${BORDERS_BIN_DEST}"
run cp "${BORDERS_BIN_SRC}" "${BORDERS_BIN_DEST}"
run chmod +x "${BORDERS_BIN_DEST}"

echo "[gallery] installing coding-agent launcher to ${AGENT_BIN_DEST}"
run cp "${AGENT_BIN_SRC}" "${AGENT_BIN_DEST}"
run chmod +x "${AGENT_BIN_DEST}"
# The agent shipped briefly (2026-09-22) as a tui-kind plugin, which opened it
# in a floating window; it is a plain bin script now, so an installation that
# saw that version still has the plugin -- and `gallery open gallery.agent`
# would still float one. Removed here rather than left to rot.
if [ -d "${PLUGINS_DEST}/gallery.agent" ]; then
  echo "[gallery] removing the superseded gallery.agent plugin (the agent is ${AGENT_BIN_DEST} now)"
  run rm -rf "${PLUGINS_DEST}/gallery.agent"
fi

if [ -f "${QML_BIN_SRC}" ]; then
  echo "[gallery] installing qml host launcher to ${QML_BIN_DEST}"
  run cp "${QML_BIN_SRC}" "${QML_BIN_DEST}"
  run chmod +x "${QML_BIN_DEST}"
  # The qml-venv (PySide6 etc.) is deliberately NOT created here -- it is
  # built on first run (gallery-qml itself, or `gallery-qml --setup`) so
  # install.sh stays fast and does not need network access every time.
  echo "[gallery] qml-venv is not created by install.sh -- it is built on first run of any qml plugin (or: gallery-qml --setup)"
  # Ship the Dock icon for the Gallery.app wrapper that gallery-qml builds
  # around the qml host (so the Dock shows "Gallery" + icon, not
  # "python3.12" + a blank document). The bundle itself is assembled lazily
  # by gallery-qml once the venv exists.
  if [ -f "${SCRIPT_DIR}/assets/Gallery.icns" ]; then
    run cp "${SCRIPT_DIR}/assets/Gallery.icns" "${CONFIG_DIR}/Gallery.icns"
  fi
else
  echo "[gallery] no bin/gallery-qml in this checkout yet -- skipping (a qml-kind plugin will not run until it is added)"
fi

GALLERY_BLOCK='-- gallery:begin
-- hs.ipc must be loaded or the hs command-line tool blocks forever.
require("hs.ipc")
hs.loadSpoon("Gallery")
spoon.Gallery:start()
-- Close every Gallery window, chooser and timer before a reload or quit;
-- otherwise their native windows outlive the Lua state as untracked orphans.
hs.shutdownCallback = function()
  pcall(function() spoon.Gallery:stop() end)
end

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

# --- skhd bindings, first copy ------------------------------------------------------
# skhdrc includes gallery.skhd; put the real file in place BEFORE the tiler step so
# that when tiler/install.sh starts or restarts skhd (a fresh machine, or a changed
# skhdrc) the new instance already carries the Gallery keys. The reload further
# down covers the case where only this file changed.
SKHD_DIR="${HOME_DIR}/.config/skhd"
run mkdir -p "${SKHD_DIR}"
run install -m 644 "${SCRIPT_DIR}/skhd/gallery.skhd" "${SKHD_DIR}/gallery.skhd"

# --- tiler (yabai, skhd, JankyBorders, Learn) --------------------------------------
# The Gallery's tiling layer lives in tiler/ in this same repo. Its installer places
# ~/.config/yabai/yabairc and ~/.config/skhd/skhdrc (which includes gallery.skhd,
# copied into place by the next step) and starts/restarts the services itself,
# restarting yabai only when its effective config actually changed -- see
# tiler/install.sh for that logic, which is unchanged here.
if [ "${SKIP_TILER}" -eq 1 ]; then
  echo "[gallery] --skip-tiler: not running tiler/install.sh"
else
  # Expanded with the ${arr[@]+"${arr[@]}"} idiom: under `set -u`, the stock
  # macOS bash 3.2 (/bin/bash, what a Mac without Homebrew's bash runs this
  # with) treats an EMPTY array expansion as an unbound variable.
  tiler_args=()
  [ "${DRY_RUN}" -eq 1 ] && tiler_args+=(--dry-run)
  [ "${RESTART_TILER}" -eq 1 ] && tiler_args+=(--restart)
  echo "[gallery] running tiler/install.sh ${tiler_args[@]+"${tiler_args[*]}"}"
  "${SCRIPT_DIR}/tiler/install.sh" ${tiler_args[@]+"${tiler_args[@]}"}
fi

# --- skhd bindings, reload ----------------------------------------------------------
# gallery.skhd (copied above) is included by skhdrc with `.load "gallery.skhd"`.
# skhd is asked to reload if it is running, so a change to this file alone takes
# effect without a restart.
if [ -d "${SKHD_DIR}" ]; then
  if pgrep -xq skhd; then
    if [ "${DRY_RUN}" -eq 1 ]; then
      echo "[dry] skhd --reload"
    else
      # `skhd --restart-service` (tiler step) returns before the new instance
      # has written its pid-file; for a few seconds `skhd --reload` then fails
      # with "could not locate existing instance". Retry briefly.
      reload_tries=0
      until skhd --reload 2>/dev/null; do
        reload_tries=$((reload_tries + 1))
        if [ "${reload_tries}" -ge 10 ]; then
          echo "[gallery] skhd --reload did not succeed after ${reload_tries} tries; run it by hand" >&2
          break
        fi
        sleep 1
      done
      [ "${reload_tries}" -lt 10 ] && echo "[gallery] skhd reloaded"
    fi
  fi
  # The tiler's key sheet (vault Cheat-Sheets/Tiler-Keys.md, plus the copy the
  # voice assistant reads) is generated from the "## " lines of skhdrc and its
  # includes -- this file among them -- so regenerate it here too, or a changed
  # Gallery binding stays unknown to Learn and to Jarvis until the tiler is
  # next installed.
  if [ -x "${SKHD_DIR}/learn" ]; then
    if [ "${DRY_RUN}" -eq 1 ]; then echo "[dry] learn install (key sheet)"; else "${SKHD_DIR}/learn" install && echo "[gallery] key sheet regenerated"; fi
  fi
else
  # Only reachable with --skip-tiler: tiler/install.sh (just above) always
  # creates ~/.config/skhd on a real run.
  echo "[gallery] no ~/.config/skhd (--skip-tiler was given); skipping key bindings"
fi

# --- Omarchy theme compatibility symlinks ------------------------------------------
# Unmodified Omarchy QML plugins read their colours through Omarchy's own
# theme-current convention. Omarchy 4's qs.Commons Color/Style singletons
# (vendored under qml/vendor) read ~/.local/state/omarchy/current/theme;
# older plugins and scripts use ~/.config/omarchy/current/theme. Point both
# at Gallery's own `current` theme symlink so such a plugin sees the right
# colours without any plugin-side patch. A link is only replaced when it is
# itself a symlink (or absent) -- a real directory there is left alone (a
# genuine Omarchy install sharing this Mac) and reported, never clobbered.
link_omarchy_theme() {
  local link="$1"
  echo "[gallery] linking Omarchy theme compatibility symlink ${link} -> ${OMARCHY_THEME_TARGET}"
  run mkdir -p "$(dirname "${link}")"
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "[dry] would link ${link} -> ${OMARCHY_THEME_TARGET} unless a real directory is already there"
  elif [ -L "${link}" ] || [ ! -e "${link}" ]; then
    local tmp_link
    tmp_link="$(mktemp -u "$(dirname "${link}")/.theme.XXXXXXXX")"
    ln -s "${OMARCHY_THEME_TARGET}" "${tmp_link}"
    mv -fh "${tmp_link}" "${link}"
    echo "[gallery] linked ${link} -> ${OMARCHY_THEME_TARGET}"
  else
    echo "[gallery] ${link} is a real directory, not a symlink -- leaving it in place"
  fi
}
link_omarchy_theme "${OMARCHY_THEME_LINK}"
link_omarchy_theme "${OMARCHY_STATE_THEME_LINK}"

# --- theme render ---------------------------------------------------------------------
# A fresh machine has no ~/.config/gallery/state/theme.{css,json,sh} until a theme
# is set or rendered, yet the Spoon, the theme picker, gallery-borders and the
# iTerm2 dynamic profiles all read those files. Render the current theme now
# (renderers only -- hooks and the Spoon are not touched; cheap and idempotent),
# then re-sync the borders daemon, which yabairc may have launched before the
# render existed and which reconfigures in place.
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "[dry] gallery theme render; gallery-borders apply"
else
  if "${BIN_DEST}" theme render >/dev/null 2>&1; then
    echo "[gallery] theme rendered ($(readlink "${THEMES_DEST}/current" 2>/dev/null || echo current))"
  else
    echo "[gallery] theme render failed; run 'gallery theme render' by hand" >&2
  fi
  if pgrep -xq borders && [ -x "${BORDERS_BIN_DEST}" ]; then
    "${BORDERS_BIN_DEST}" apply >/dev/null 2>&1 && echo "[gallery] borders re-synced to the rendered theme" || true
  fi
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
