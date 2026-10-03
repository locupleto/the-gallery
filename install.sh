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
# Nothing of yours is lost. A file the installer replaces is first moved to
# <name>.gallery-bak (or, if you edited a Gallery file, copied to
# <name>.gallery-edited.<timestamp>); files it edits in place (init.lua, the
# terminal configs, btop and superfile settings) are backed up once; every file
# it writes is listed in ~/.config/gallery/state/install-manifest.tsv. --uninstall
# reverses all of it. The helpers live in tools/install-lib.sh.
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
TERM_BIN_SRC="${SCRIPT_DIR}/bin/gallery-term"
TERM_BIN_DEST="${HOME_DIR}/bin/gallery-term"
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
OMARCHY_LINKS_RECORD="${CONFIG_DIR}/state/omarchy-links.tsv"
HS_INIT="${HOME_DIR}/.hammerspoon/init.lua"
HAMMERSPOON_APP="${GALLERY_HAMMERSPOON_APP:-/Applications/Hammerspoon.app}"

DRY_RUN=0
UNINSTALL=0
SKIP_TILER=0
RESTART_TILER=0
MINIMAL=0
PURGE=0
KEEP_WALLPAPER=0
ASSUME_YES=0
NO_WALLPAPERS=0

usage() {
  cat <<'USAGE' >&2
usage: install.sh [--dry-run] [--uninstall [--purge [--yes]] [--keep-wallpaper]] [--skip-tiler] [--restart-tiler] [--minimal] [--no-wallpapers]
  --dry-run        print what would happen (including each file it would back
                   up or restore), change nothing
  --uninstall      remove the Gallery (and, unless --skip-tiler, the tiler) and
                   put back every file of yours it replaced or edited; keeps
                   ~/.config/gallery (your state) and the Homebrew formulae
  --purge          with --uninstall: also delete ~/.config/gallery, including
                   plugins and themes you added and a real sheets/ folder;
                   asks first (or pass --yes)
  --yes            with --purge: do not ask
  --keep-wallpaper with --uninstall: do not restore the saved wallpaper settings
  --skip-tiler     do not run tiler/install.sh (yabai/skhd/borders/Learn)
  --restart-tiler  pass --restart through to tiler/install.sh, forcing a
                   yabai/skhd restart even if their config did not change
  --minimal        do not brew install the companion apps (btop, superfile)
  --no-wallpapers  do not download Omarchy's wallpapers for the themes
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
    --minimal)
      MINIMAL=1
      ;;
    --purge)
      PURGE=1
      ;;
    --keep-wallpaper)
      KEEP_WALLPAPER=1
      ;;
    --yes)
      ASSUME_YES=1
      ;;
    --no-wallpapers)
      NO_WALLPAPERS=1
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

if [ "${UNINSTALL}" -eq 0 ] && [ "$((PURGE + KEEP_WALLPAPER))" -gt 0 ]; then
  echo "[gallery] --purge and --keep-wallpaper only apply to --uninstall" >&2
  usage
  exit 1
fi

# --purge deletes things only the user has (added plugins and themes, a real
# sheets/ folder, every preference), so it is confirmed before anything is
# touched -- not halfway through the uninstall.
if [ "${PURGE}" -eq 1 ] && [ "${DRY_RUN}" -eq 0 ] && [ "${ASSUME_YES}" -eq 0 ]; then
  purge_dir="${HOME}/.config/gallery"
  if [ ! -t 0 ]; then
    echo "[gallery] --purge deletes ${purge_dir}; not a terminal, so pass --yes to confirm" >&2
    exit 1
  fi
  echo "[gallery] --purge will delete ${purge_dir}, including:"
  for d in "${purge_dir}"/plugins/* "${purge_dir}"/themes/*; do
    [ -d "${d}" ] && [ ! -L "${d}" ] || continue
    case "$(basename "${d}")" in gallery.*|current) continue ;; esac
    [ -d "${SCRIPT_DIR:-.}/themes/$(basename "${d}")" ] && continue
    echo "[gallery]   ${d}"
  done
  if [ -d "${purge_dir}/sheets" ] && [ ! -L "${purge_dir}/sheets" ]; then
    echo "[gallery]   ${purge_dir}/sheets (a folder, not a link: your sheets go with it)"
  fi
  echo "[gallery]   and every preference in ${purge_dir}/state"
  printf '[gallery] type "yes" to delete it: '
  read -r answer || answer=""
  if [ "${answer}" != "yes" ]; then
    echo "[gallery] not purging; nothing was changed"
    exit 1
  fi
fi

GL_DRY="${DRY_RUN}"
GL_TAG="[gallery]"
# shellcheck source=tools/install-lib.sh
. "${SCRIPT_DIR}/tools/install-lib.sh"

run() {
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "[gallery] (dry-run) $*"
  else
    echo "[gallery] $*"
    "$@"
  fi
}

require_hammerspoon() {
  if [ ! -d "${HAMMERSPOON_APP}" ]; then
    echo "[gallery] Hammerspoon.app not found at ${HAMMERSPOON_APP}" >&2
    echo "[gallery] install it with: brew install --cask hammerspoon" >&2
    exit 1
  fi
}

# Homebrew may be installed without being on this shell's PATH (its installer
# asks you to add `brew shellenv` to your shell, and a fresh account or an
# SSH session may not have it): look in both of its usual places.
if ! command -v brew >/dev/null 2>&1; then
  for _brew_dir in /opt/homebrew/bin /usr/local/bin; do
    if [ -x "${_brew_dir}/brew" ]; then
      export PATH="${_brew_dir}:${PATH}"
      echo "[gallery] note: Homebrew found at ${_brew_dir} but not on your PATH; add it with" >&2
      echo "[gallery]         echo 'eval \"\$(${_brew_dir}/brew shellenv)\"' >> ~/.zprofile" >&2
      break
    fi
  done
fi

# Homebrew is a prerequisite, never installed from here (its installer wants
# sudo and an interactive terminal). Checked up front so a Mac without it
# fails before anything is copied, rather than half-way through in
# tiler/install.sh. Not needed when neither the tiler nor the companion apps
# are being installed.
require_homebrew() {
  [ "${SKIP_TILER}" -eq 1 ] && [ "${MINIMAL}" -eq 1 ] && return 0
  if ! command -v brew >/dev/null 2>&1; then
    echo "[gallery] Homebrew not found -- install it first: https://brew.sh" >&2
    echo "[gallery] (or run with --skip-tiler --minimal to install without it)" >&2
    exit 1
  fi
}

# Companion apps the theme renderer colours to match: btop (the System
# Monitor plugin) and superfile (the `spf` file manager). Installed by
# default so a new Mac comes out complete; --minimal skips them. A failed
# brew install only warns -- nothing else in the Gallery depends on them.
# --uninstall leaves them in place, like any other Homebrew formula.
install_companion_apps() {
  local formula
  if [ "${MINIMAL}" -eq 1 ]; then
    echo "[gallery] --minimal: not installing btop or superfile"
    return 0
  fi
  for formula in btop superfile; do
    if brew list --formula "${formula}" >/dev/null 2>&1; then
      echo "[gallery] ${formula} already installed ($(brew list --versions "${formula}"))"
    else
      run brew install "${formula}" \
        || echo "[gallery] brew install ${formula} failed -- carrying on without it" >&2
    fi
  done
}

# jq: the Ghost Windows service reads yabai's JSON with it. macOS 15 and later
# ship /usr/bin/jq; older systems need it from Homebrew. Needed even with
# --minimal, and quick to build where Homebrew has no prebuilt package.
install_jq() {
  if command -v jq >/dev/null 2>&1; then
    echo "[gallery] jq found ($(command -v jq))"
    return 0
  fi
  if ! command -v brew >/dev/null 2>&1; then
    echo "[gallery] jq not found and no Homebrew -- the Ghost Windows check needs it: brew install jq" >&2
    return 0
  fi
  run brew install jq \
    || echo "[gallery] brew install jq failed -- the Ghost Windows check will not work without it" >&2
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

# --- uninstall ---------------------------------------------------------------------

# unwire_include <file> <line> -- drop the one line the Gallery added to a
# terminal config, then put the backup back (or delete the file if the Gallery
# created it and nothing else is in it).
unwire_include() {
  local file="$1" line="$2"
  [ -f "${file}" ] && grep -Fxq -- "${line}" "${file}" || return 0
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "[gallery] (dry-run) would remove the Gallery include line from ${file}"
    return 0
  fi
  gl_line_remove "${file}" "${line}"
  gl_finish_edit "${file}" 1
}

# The ~/.wezterm.lua `gallery console theme` writes when the user has no
# wezterm config at all (bin/gallery, console_config_apply). Reproduced here
# byte for byte so only an untouched one is deleted.
gl_wezterm_generated() {
  local rel="${CONFIG_DIR}/state/terminals/wezterm.lua" expr
  case "${rel}" in
    "${HOME_DIR}"/*) expr="wezterm.home_dir .. '/${rel#"${HOME_DIR}"/}'" ;;
    *)               expr="'${rel}'" ;;
  esac
  printf '%s\n' \
    "local wezterm = require 'wezterm'" \
    "local config = wezterm.config_builder()" \
    "local ok, gallery = pcall(dofile, ${expr})" \
    "if ok then for k, v in pairs(gallery) do config[k] = v end end" \
    "return config"
}

uninstall_terminal_wiring() {
  local gh_line="config-file = ?${CONFIG_DIR}/state/terminals/ghostty.conf"
  local kitty_line="include ${CONFIG_DIR}/state/terminals/kitty.conf"
  local wz="${HOME_DIR}/.wezterm.lua" generated
  unwire_include "${HOME_DIR}/.config/ghostty/config" "${gh_line}"
  unwire_include "${HOME_DIR}/.config/ghostty/config.ghostty" "${gh_line}"
  unwire_include "${HOME_DIR}/.config/kitty/kitty.conf" "${kitty_line}"
  gl_rmdir_empty "${HOME_DIR}/.config/ghostty" "${HOME_DIR}/.config/kitty"

  if [ -f "${wz}" ]; then
    generated="$(mktemp "${TMPDIR:-/tmp}/gallery-wezterm.XXXXXX")"
    gl_wezterm_generated > "${generated}"
    if cmp -s "${wz}" "${generated}"; then
      run rm -f "${wz}"
      gl_note removed "${wz} (created by the Gallery)"
    elif grep -Fq -- "state/terminals/wezterm.lua" "${wz}"; then
      echo "[gallery] ${wz} loads the Gallery's wezterm module; the two lines are harmless without it (pcall) -- remove them when convenient"
      gl_note kept "${wz} (two Gallery lines remain; harmless)"
    fi
    rm -f "${generated}"
  fi
}

uninstall_iterm_profiles() {
  local dir="${HOME_DIR}/Library/Application Support/iTerm2/DynamicProfiles"
  local default_guid
  if [ -e "${dir}/gallery-theme.json" ]; then
    run rm -f "${dir}/gallery-theme.json"
    gl_note removed "${dir}/gallery-theme.json"
  fi
  # The user's own default profile, noted when the Gallery made Console the
  # default (bin/gallery, iterm_default_take), goes back first.
  local before
  before="$(python3 -c '
import json, sys
try:
    v = json.load(open(sys.argv[1])).get("iterm_default_before")
except Exception:
    v = None
if v is not None:
    print(v)
' "${CONFIG_DIR}/state/console.json" 2>/dev/null || true)"
  local prefs="${GALLERY_DEFAULTS_BIN:-defaults}" undo
  if [ -n "${before}" ] && [ "$("${prefs}" read com.googlecode.iterm2 "Default Bookmark Guid" 2>/dev/null || true)" = "gallery-console" ] \
     && pgrep -u "$(id -u)" -xq iTerm2; then
    # A running iTerm2 would put its default straight back: say how instead.
    if [ "${before}" = "-" ]; then
      undo="defaults delete com.googlecode.iterm2 'Default Bookmark Guid'"
    else
      undo="defaults write com.googlecode.iterm2 'Default Bookmark Guid' -string '${before}'"
    fi
    echo "[gallery] iTerm2 is running, so its default profile cannot be given back now. Quit iTerm2, then run:"
    echo "[gallery]   ${undo}"
    gl_note kept "iTerm2's default profile is still Console until you run: ${undo}"
  elif [ -n "${before}" ] && [ "$("${prefs}" read com.googlecode.iterm2 "Default Bookmark Guid" 2>/dev/null || true)" = "gallery-console" ]; then
    if [ "${before}" = "-" ]; then
      run "${prefs}" delete com.googlecode.iterm2 "Default Bookmark Guid"
    else
      run "${prefs}" write com.googlecode.iterm2 "Default Bookmark Guid" -string "${before}"
    fi
    gl_note restored "iTerm2's default profile (your own, from before the Gallery)"
  fi
  if [ -e "${dir}/gallery-console.json" ]; then
    default_guid="$("${prefs}" read com.googlecode.iterm2 "Default Bookmark Guid" 2>/dev/null || true)"
    if [ "${default_guid}" = "gallery-console" ]; then
      echo "[gallery] iTerm2's default profile is still Console; keeping ${dir}/gallery-console.json"
      echo "[gallery] set your own profile as the default (iTerm2: Settings > Profiles > pick one > Other Actions > Set as Default), then delete that file"
      gl_note kept "${dir}/gallery-console.json (iTerm2 default profile is Console)"
    else
      run rm -f "${dir}/gallery-console.json"
      gl_note removed "${dir}/gallery-console.json"
    fi
  fi
  gl_rmdir_empty "${dir}" "$(dirname "${dir}")"
}

# The Omarchy compatibility links: removed only if they point into the
# Gallery's config; a link of the user's own that the installer replaced is put
# back from state/omarchy-links.tsv.
uninstall_omarchy_links() {
  local link target
  for link in "${OMARCHY_THEME_LINK}" "${OMARCHY_STATE_THEME_LINK}"; do
    if [ -L "${link}" ]; then
      target="$(readlink "${link}")"
      case "${target}" in
        "${CONFIG_DIR}"/*)
          run rm -f "${link}"
          gl_note removed "${link}"
          target="$(awk -F'\t' -v l="${link}" '$1 == l { print $2; exit }' "${OMARCHY_LINKS_RECORD}" 2>/dev/null || true)"
          if [ -n "${target}" ]; then
            run ln -s "${target}" "${link}"
            gl_note restored "${link} -> ${target}"
          fi
          ;;
        *)
          gl_note kept "${link} (points to ${target}, not ours)"
          ;;
      esac
    fi
  done
  rm -f "${OMARCHY_LINKS_RECORD}" 2>/dev/null || true
  gl_rmdir_empty "$(dirname "${OMARCHY_THEME_LINK}")" "$(dirname "$(dirname "${OMARCHY_THEME_LINK}")")" \
    "$(dirname "${OMARCHY_STATE_THEME_LINK}")" "$(dirname "$(dirname "${OMARCHY_STATE_THEME_LINK}")")"
}

do_uninstall() {
  local path init_created=0 had_confs=0
  echo "[gallery] uninstalling"

  if [ "${SKIP_TILER}" -eq 1 ]; then
    echo "[gallery] --skip-tiler: not running tiler/install.sh --uninstall"
  else
    tiler_args=(--uninstall)
    [ "${DRY_RUN}" -eq 1 ] && tiler_args+=(--dry-run)
    echo "[gallery] running tiler/install.sh ${tiler_args[*]}"
    "${SCRIPT_DIR}/tiler/install.sh" "${tiler_args[@]}"
  fi

  # init.lua first: with the Spoon gone below, a surviving load block would
  # make Hammerspoon report an error at every reload.
  [ -e "${CONFIG_DIR}/state/init-lua-created" ] && init_created=1
  if gl_block_has "${HS_INIT}"; then
    if [ "${DRY_RUN}" -eq 1 ]; then
      echo "[gallery] (dry-run) would remove the Gallery block from ${HS_INIT}"
    else
      gl_block_strip "${HS_INIT}"
      gl_finish_edit "${HS_INIT}" "${init_created}"
      rm -f "${CONFIG_DIR}/state/init-lua-created"
    fi
  fi

  if [ -d "${SPOON_DEST}" ]; then
    run rm -rf "${SPOON_DEST}"
    gl_note removed "${SPOON_DEST}"
  else
    echo "[gallery] no Spoon installed at ${SPOON_DEST}"
  fi
  gl_rmdir_empty "${HOME_DIR}/.hammerspoon/Spoons" "${HOME_DIR}/.hammerspoon"

  # Every file install_file wrote: removed if still ours, restored from its
  # backup if it replaced one of yours. With --skip-tiler the tiler's own files
  # (yabai and skhd directories) stay, except gallery.skhd, which is ours.
  while IFS= read -r path; do
    [ -n "${path}" ] || continue
    if [ "${SKIP_TILER}" -eq 1 ]; then
      case "${path}" in
        "${HOME_DIR}/.config/skhd/gallery.skhd") ;;
        "${HOME_DIR}/.config/yabai/"*|"${HOME_DIR}/.config/skhd/"*) continue ;;
      esac
    fi
    gl_uninstall_file "${path}"
  done <<EOF
$(gl_manifest_paths)
EOF
  gl_rmdir_empty "${HOME_DIR}/bin" "${HOME_DIR}/.config/skhd" "${HOME_DIR}/.config/yabai"

  uninstall_terminal_wiring
  uninstall_iterm_profiles

  # btop / superfile settings back to what they were (and their rendered
  # themes removed), from the checkout's renderer so it works without an
  # installed copy.
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "[gallery] (dry-run) would restore btop/superfile settings from ${CONFIG_DIR}/state/conf-originals.json"
  elif command -v python3 >/dev/null 2>&1; then
    [ -e "${CONFIG_DIR}/state/conf-originals.json" ] && had_confs=1
    python3 "${RENDER_TOOL_SRC}" --restore-confs | sed 's/^/[gallery] /'
    [ "${had_confs}" -eq 1 ] && gl_note restored "btop / superfile settings the Gallery had changed"
  fi

  uninstall_omarchy_links

  if [ -f "${CONFIG_DIR}/state/wallpaper-original.plist" ]; then
    if [ "${KEEP_WALLPAPER}" -eq 1 ]; then
      echo "[gallery] --keep-wallpaper: leaving the wallpaper as it is (saved original: ${CONFIG_DIR}/state/wallpaper-original.plist)"
      gl_note kept "the current wallpaper settings"
    elif [ "${DRY_RUN}" -eq 1 ]; then
      echo "[gallery] (dry-run) would restore the saved wallpaper store and restart WallpaperAgent (gallery bg restore)"
    else
      if "${BIN_SRC}" bg restore; then
        gl_note restored "the wallpaper settings"
      else
        gl_note kept "the wallpaper settings (restore failed; run: gallery bg restore)"
      fi
    fi
  fi

  if [ "${PURGE}" -eq 1 ]; then
    run rm -rf "${CONFIG_DIR}"
    run rm -f "${HOME_DIR}/Library/Logs/gallery.log"
    gl_note removed "${CONFIG_DIR} (--purge)"
  else
    gl_note kept "${CONFIG_DIR} (your state; --purge deletes it)"
  fi
  gl_note kept "the Homebrew formulae installed for the Gallery (yabai, skhd, borders, fzf, glow, btop, superfile): brew uninstall them if you want"

  echo "[gallery] uninstall complete"
  gl_summary
  exit 0
}

if [ "${UNINSTALL}" -eq 1 ]; then
  do_uninstall
fi

require_hammerspoon
require_homebrew
install_jq
install_companion_apps
advise_optional_tools

echo "[gallery] installing Spoon to ${SPOON_DEST}"
run mkdir -p "$(dirname "${SPOON_DEST}")"
gl_rsync_delete "${SPOON_SRC}/" "${SPOON_DEST}/"

echo "[gallery] installing plugins to ${PLUGINS_DEST}"
run mkdir -p "${PLUGINS_DEST}"
# Per-plugin --delete so files a plugin no longer ships (an old index.html,
# say) do not linger; third-party plugins living beside ours are untouched.
for plugin_dir in "${PLUGINS_SRC}"/*/; do
  [ -d "${plugin_dir}" ] || continue
  gl_rsync_delete "${plugin_dir}" "${PLUGINS_DEST}/$(basename "${plugin_dir}")/"
done

echo "[gallery] ensuring config directories exist"
run mkdir -p "${CONFIG_DIR}/feed" "${CONFIG_DIR}/themes" "${CONFIG_DIR}/hooks"

echo "[gallery] installing themes to ${THEMES_DEST}"
run mkdir -p "${THEMES_DEST}"
# No --delete: user-authored themes may already live under THEMES_DEST, and
# the `current` symlink (also under THEMES_DEST) must never be touched here.
run rsync -a --exclude 'current' "${THEMES_SRC}/" "${THEMES_DEST}/"

# Omarchy's wallpapers are not in this repository: they are their artists'
# work, which Omarchy ships with no licence of its own, so they are downloaded
# from Omarchy itself, for every theme that has none yet (an update fetches
# only what a new theme lacks). --no-wallpapers skips this; a failed download
# only warns, and tools/fetch-omarchy-backgrounds.sh can be re-run by hand.
WALLPAPERS_FETCHED=" "
if [ "${NO_WALLPAPERS}" -eq 1 ] || [ -n "${GALLERY_NO_WALLPAPERS:-}" ]; then
  echo "[gallery] not fetching Omarchy's wallpapers (--no-wallpapers)"
else
  missing=()
  for theme_dir in "${THEMES_SRC}"/*/; do
    name="$(basename "${theme_dir}")"
    ls "${THEMES_DEST}/${name}/backgrounds/"* >/dev/null 2>&1 || missing+=("${name}")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "[gallery] fetching Omarchy's wallpapers for ${#missing[@]} theme(s) from github.com/basecamp/omarchy"
    if [ "${DRY_RUN}" -eq 1 ]; then
      echo "[dry] tools/fetch-omarchy-backgrounds.sh ${missing[*]}"
    else
      # One run for all of them: upstream is resolved once (GitHub's API
      # allows 60 requests an hour), and each theme reports its own result.
      fetch_log="$(mktemp "${TMPDIR:-/tmp}/gallery-fetch.XXXXXX")"
      "${SCRIPT_DIR}/tools/fetch-omarchy-backgrounds.sh" "${missing[@]}" > "${fetch_log}" 2>&1 || true
      failed_names=()
      for name in "${missing[@]}"; do
        if grep -Eq "^\[fetch-bg\] ${name}: (fetched [0-9]+, skipped [0-9]+, failed 0|no backgrounds/ upstream)" "${fetch_log}"; then
          WALLPAPERS_FETCHED="${WALLPAPERS_FETCHED}${name} "
        else
          failed_names+=("${name}")
        fi
      done
      if [ "${#failed_names[@]}" -gt 0 ]; then
        # The script's own reason (e.g. the rate limit and when it resets), once.
        grep -E "^\[fetch-bg\] (could not|GitHub)|limit" "${fetch_log}" | head -1 >&2 || true
        echo "[gallery] could not fetch the wallpapers for: ${failed_names[*]}" >&2
        echo "[gallery] later: tools/fetch-omarchy-backgrounds.sh ${failed_names[*]}" >&2
      fi
      rm -f "${fetch_log}"
    fi
  fi
fi

echo "[gallery] installing theme renderer to ${RENDER_TOOL_DEST}"
run mkdir -p "$(dirname "${RENDER_TOOL_DEST}")"
gl_install_file "${RENDER_TOOL_SRC}" "${RENDER_TOOL_DEST}" 755

echo "[gallery] installing theme-set hook examples to ${THEME_HOOKS_DEST}"
run mkdir -p "${THEME_HOOKS_DEST}"
if [ -d "${THEME_HOOKS_SRC}" ]; then
  for hook in "${THEME_HOOKS_SRC}"/*; do
    [ -f "${hook}" ] || continue
    gl_install_file "${hook}" "${THEME_HOOKS_DEST}/$(basename "${hook}")" 755
  done
fi

echo "[gallery] installing qml shim tree to ${QML_DEST}"
run mkdir -p "${QML_DEST}"
if [ -d "${QML_SRC}" ]; then
  gl_rsync_delete "${QML_SRC}/" "${QML_DEST}/"
else
  echo "[gallery] no qml/ directory in this checkout yet -- skipping (a qml-kind plugin will not run until it is added)"
fi

echo "[gallery] installing patches to ${PATCHES_DEST}"
run mkdir -p "${PATCHES_DEST}"
if [ -d "${PATCHES_SRC}" ]; then
  gl_rsync_delete "${PATCHES_SRC}/" "${PATCHES_DEST}/"
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
gl_install_file "${BIN_SRC}" "${BIN_DEST}" 755

echo "[gallery] installing hs watchdog CLI to ${HS_BIN_DEST}"
gl_install_file "${HS_BIN_SRC}" "${HS_BIN_DEST}" 755

echo "[gallery] installing terminal-window helpers to ${TUI_BIN_DEST}, ${TERM_BIN_DEST}, ${MENU_BIN_DEST}"
gl_install_file "${TUI_BIN_SRC}" "${TUI_BIN_DEST}" 755
gl_install_file "${TERM_BIN_SRC}" "${TERM_BIN_DEST}" 755
gl_install_file "${MENU_BIN_SRC}" "${MENU_BIN_DEST}" 755

echo "[gallery] installing theme-aware borders helper to ${BORDERS_BIN_DEST}"
gl_install_file "${BORDERS_BIN_SRC}" "${BORDERS_BIN_DEST}" 755

echo "[gallery] installing coding-agent launcher to ${AGENT_BIN_DEST}"
gl_install_file "${AGENT_BIN_SRC}" "${AGENT_BIN_DEST}" 755
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
  gl_install_file "${QML_BIN_SRC}" "${QML_BIN_DEST}" 755
  # The qml-venv (PySide6 etc.) is deliberately NOT created here -- it is
  # built on first run (gallery-qml itself, or `gallery-qml --setup`) so
  # install.sh stays fast and does not need network access every time.
  echo "[gallery] qml-venv is not created by install.sh -- it is built on first run of any qml plugin (or: gallery-qml --setup)"
  # Ship the Dock icon for the Gallery.app wrapper that gallery-qml builds
  # around the qml host (so the Dock shows "Gallery" + icon, not
  # "python3.12" + a blank document). The bundle itself is assembled lazily
  # by gallery-qml once the venv exists.
  if [ -f "${SCRIPT_DIR}/assets/Gallery.icns" ]; then
    gl_install_file "${SCRIPT_DIR}/assets/Gallery.icns" "${CONFIG_DIR}/Gallery.icns" 644
  fi
else
  echo "[gallery] no bin/gallery-qml in this checkout yet -- skipping (a qml-kind plugin will not run until it is added)"
fi

GALLERY_BLOCK='-- gallery:begin
-- hs.ipc must be loaded or the hs command-line tool blocks forever.
require("hs.ipc")
-- The hs command-line tool the gallery CLI talks through, linked into
-- the Homebrew bin directory (/opt/homebrew on Apple silicon, /usr/local on Intel).
do
  local prefix = hs.fs.attributes("/opt/homebrew/bin") and "/opt/homebrew" or "/usr/local"
  if not hs.ipc.cliStatus(prefix, true) then hs.ipc.cliInstall(prefix, true) end
end
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

# init.lua belongs to the user: the load block is appended once (after a backup
# of the file), refreshed in place when it is out of date, and left alone
# otherwise. Detected by its begin marker, not by the word "Gallery".
if ! gl_exists "${HS_INIT}"; then
  echo "[gallery] writing new ${HS_INIT}"
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "[gallery] (dry-run) create ${HS_INIT} with Gallery load block"
  else
    run mkdir -p "$(dirname "${HS_INIT}")"
    printf '%s\n' "${GALLERY_BLOCK}" > "${HS_INIT}"
    mkdir -p "${CONFIG_DIR}/state"
    : > "${CONFIG_DIR}/state/init-lua-created"
  fi
elif gl_block_has "${HS_INIT}"; then
  current_block="$(awk '/^-- gallery:begin$/ { p = 1 } p { print } /^-- gallery:end$/ { p = 0 }' "${HS_INIT}")"
  if [ "${current_block}" = "${GALLERY_BLOCK}" ]; then
    echo "[gallery] ${HS_INIT} already has the current Gallery block"
  elif [ "${DRY_RUN}" -eq 1 ]; then
    echo "[gallery] (dry-run) would back up ${HS_INIT} and refresh its Gallery block"
  else
    echo "[gallery] refreshing the Gallery block in ${HS_INIT}"
    # A file the Gallery created holds nothing of the user's to back up.
    [ -e "${CONFIG_DIR}/state/init-lua-created" ] || gl_backup_once "${HS_INIT}"
    gl_block_replace "${HS_INIT}" "${GALLERY_BLOCK}"
  fi
elif grep -q -- '-- gallery:begin' "${HS_INIT}"; then
  echo "[gallery] ${HS_INIT} has a Gallery begin marker without its end marker; leaving it alone -- fix it by hand" >&2
else
  echo "[gallery] appending Gallery block to existing ${HS_INIT} (exists, user file)"
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "[gallery] (dry-run) would back up ${HS_INIT} to ${HS_INIT}.gallery-bak, then append the Gallery block"
  else
    gl_backup_once "${HS_INIT}"
    {
      printf '\n'
      printf '%s\n' "${GALLERY_BLOCK}"
    } >> "${HS_INIT}"
  fi
fi

# --- skhd bindings, first copy ------------------------------------------------------
# skhdrc includes gallery.skhd; put the real file in place BEFORE the tiler step so
# that when tiler/install.sh starts or restarts skhd (a fresh machine, or a changed
# skhdrc) the new instance already carries the Gallery keys. The reload further
# down covers the case where only this file changed.
SKHD_DIR="${HOME_DIR}/.config/skhd"
run mkdir -p "${SKHD_DIR}"
gl_install_file "${SCRIPT_DIR}/skhd/gallery.skhd" "${SKHD_DIR}/gallery.skhd" 644
# local.skhd (the user's own bindings, loaded by skhdrc): seeded once, never overwritten.
[ -e "${SKHD_DIR}/local.skhd" ] || run install -m 644 "${SCRIPT_DIR}/tiler/local.skhd.example" "${SKHD_DIR}/local.skhd"

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
  # The tiler step starts yabai and skhd, which ends a `gallery off`.
  if [ -f "${CONFIG_DIR}/state/paused" ]; then
    echo "[gallery] the Gallery was off (gallery off); installing switches it back on"
    run rm -f "${CONFIG_DIR}/state/paused"
  fi
  # Where the windows are before yabai first tiles them, so that a later
  # `gallery off` can put them back (no-op while yabai is already running).
  [ "${DRY_RUN}" -eq 1 ] || "${SCRIPT_DIR}/bin/gallery" _snapshot || true
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
  if pgrep -u "$(id -u)" -xq skhd; then
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
  # The tiler's key sheet (Tiler-Keys.md in the Learn sheets folder, plus the
  # copy in ~/.config/skhd that other tools read) is generated from the "## "
  # lines of skhdrc and its includes -- this file among them -- so regenerate
  # it here too, or a changed Gallery binding stays unknown to Learn until the
  # tiler is next installed.
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
# genuine Omarchy install sharing this Mac) and reported, never clobbered. The
# target of a symlink of the user's own that gets replaced is recorded in
# state/omarchy-links.tsv, and --uninstall points it back there.
link_omarchy_theme() {
  local link="$1"
  echo "[gallery] linking Omarchy theme compatibility symlink ${link} -> ${OMARCHY_THEME_TARGET}"
  run mkdir -p "$(dirname "${link}")"
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "[dry] would link ${link} -> ${OMARCHY_THEME_TARGET} unless a real directory is already there"
  elif [ -L "${link}" ] || [ ! -e "${link}" ]; then
    local tmp_link old_target
    old_target="$(readlink "${link}" 2>/dev/null || true)"
    case "${old_target}" in
      ""|"${CONFIG_DIR}"/*) ;;
      *)
        if ! awk -F'\t' -v l="${link}" '$1 == l { f = 1 } END { exit !f }' "${OMARCHY_LINKS_RECORD}" 2>/dev/null; then
          mkdir -p "${CONFIG_DIR}/state"
          printf '%s\t%s\n' "${link}" "${old_target}" >> "${OMARCHY_LINKS_RECORD}"
          echo "[gallery] ${link} pointed to ${old_target}; recorded so uninstall can point it back"
        fi
        ;;
    esac
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
# terminal themes (iTerm2 profiles, Ghostty/kitty/WezTerm files) all read those files. Render the current theme now
# (renderers only -- hooks and the Spoon are not touched; cheap and idempotent),
# then re-sync the borders daemon, which yabairc may have launched before the
# render existed and which reconfigures in place.
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "[dry] gallery theme render; gallery-borders apply"
else
  if "${BIN_DEST}" theme render >/dev/null 2>&1; then
    echo "[gallery] theme rendered ($(readlink "${THEMES_DEST}/current" 2>/dev/null || echo current))"
    # The current theme's wallpapers arrived just now (a first install): put
    # one on the desktop. On an update the wallpaper is left as it is.
    current_theme="$(readlink "${THEMES_DEST}/current" 2>/dev/null || true)"
    case "${WALLPAPERS_FETCHED}" in
      *" ${current_theme} "*)
        [ -n "${current_theme}" ] && "${BIN_DEST}" bg apply >/dev/null 2>&1 \
          && echo "[gallery] wallpaper set from ${current_theme}'s backgrounds" || true ;;
    esac
  else
    echo "[gallery] theme render failed; run 'gallery theme render' by hand" >&2
  fi
  if pgrep -u "$(id -u)" -xq borders && [ -x "${BORDERS_BIN_DEST}" ]; then
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
elif ! pgrep -u "$(id -u)" -x "Hammerspoon" >/dev/null 2>&1; then
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

# The CLI lives in ~/bin, which a fresh Mac does not have on PATH. Say so
# rather than edit the user's shell startup files.
case ":${PATH}:" in
  *":${HOME_DIR}/bin:"*) ;;
  *)
    echo "[gallery] note: ${HOME_DIR}/bin is not on your PATH, so the gallery command is not found yet."
    echo "[gallery]       Add it once, then open a new terminal:"
    echo "[gallery]         echo 'export PATH=\"\$HOME/bin:\$PATH\"' >> ~/.zprofile"
    echo "[gallery]       (until then: ~/bin/gallery doctor)"
    ;;
esac

# The user's terminals follow the theme from the first install: every
# installed terminal is wired to it (iTerm2 also gets the Console profile as
# its default), each config file is backed up as <file>.gallery-bak before
# its first edit, and the user's own iTerm2 default is noted. `gallery off`
# puts them all back while off, `gallery console native` for good, and
# --uninstall restores them. An existing choice (console.json) is kept.
if [ "${DRY_RUN}" -ne 1 ] && [ -x "${HOME_DIR}/bin/gallery" ]; then
  if [ ! -f "${CONFIG_DIR}/state/console.json" ]; then
    echo "[gallery] your terminals now follow the theme (back to their own colours with: gallery console native)"
    # What it did per terminal (and WezTerm's two lines), not the render log.
    "${HOME_DIR}/bin/gallery" console theme 2>&1 \
      | grep -E '^(iterm2|ghostty|kitty|wezterm):|^  (local|if) ' | sed 's/^/[gallery]   /' || true
  fi
  console_steps="$("${HOME_DIR}/bin/gallery" console _hint 2>/dev/null || true)"
  if [ -n "${console_steps}" ]; then
    echo "[gallery] note: the windows the Gallery opens follow the theme; for iTerm2's own new windows too:"
    printf '%s\n' "${console_steps}" | sed 's/^/[gallery]         /'
  fi
fi
