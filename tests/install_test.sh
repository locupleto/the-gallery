#!/usr/bin/env bash
#
# install_test.sh -- install.sh / tiler/install.sh and their --uninstall, end to
# end, in a throwaway HOME.
#
# Safe to run on a real Mac: HOME is a temp directory, and every command that
# would touch the system (yabai, skhd, brew, launchctl, defaults, osascript,
# open, pkill, killall, pgrep, hs, ...) is a stub earlier on PATH that only logs
# its arguments. Hammerspoon.app is a temp directory (GALLERY_HAMMERSPOON_APP),
# the LaunchServices call in tiler/learn is redirected (GALLERY_LSREGISTER).
#
# Scenario A seeds files of the user's own where the installers write or edit,
# installs, simulates console wiring, a wallpaper apply and a theme render,
# reinstalls (nothing new may be backed up), edits an installed file and
# reinstalls (the edit must be kept), then uninstalls and checks every seeded
# file is byte-identical to what it was. Scenario B installs into a HOME with
# nothing pre-existing and checks the uninstall leaves no trace.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL="${REPO_ROOT}/install.sh"

say()  { echo "[install_test] $*"; }
fail() { echo "[install_test] FAIL: $*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
command -v rsync >/dev/null 2>&1 || fail "rsync not found on PATH"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gallery-install-test.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

# --- stubs ----------------------------------------------------------------------
STUBS="${WORK_DIR}/stubs"
export GALLERY_NO_WALLPAPERS=1   # no downloads from Omarchy during the test
STUB_LOG="${WORK_DIR}/stub.log"
mkdir -p "${STUBS}"
: > "${STUB_LOG}"
for name in yabai skhd osascript open pkill killall launchctl hs plutil codesign mdimport glow fzf; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 0\n' "${name}" "${STUB_LOG}" > "${STUBS}/${name}"
done
# pgrep: succeeds for the names in $STUB_RUNNING.
cat > "${STUBS}/pgrep" <<EOF
#!/bin/sh
for a in "\$@"; do n="\$a"; done
case " \${STUB_RUNNING:-} " in *" \$n "*) exit 0 ;; esac
exit 1
EOF
# brew: every formula is installed; \`brew services list\` prints \$STUB_BREW_SERVICES.
cat > "${STUBS}/brew" <<EOF
#!/bin/sh
echo "brew \$*" >> "${STUB_LOG}"
case "\$1 \$2" in
  "list --formula") exit 0 ;;
  "list --versions") echo "\$3 1.0"; exit 0 ;;
  "services list") printf 'Name Status User File\n%s\n' "\${STUB_BREW_SERVICES:-borders none}"; exit 0 ;;
esac
exit 0
EOF
# defaults: only the iTerm2 default-profile read answers.
cat > "${STUBS}/defaults" <<EOF
#!/bin/sh
echo "defaults \$*" >> "${STUB_LOG}"
case "\$*" in
  *"Default Bookmark Guid"*) [ -n "\${STUB_ITERM_GUID:-}" ] && { echo "\${STUB_ITERM_GUID}"; exit 0; }; exit 1 ;;
esac
echo 0
EOF
# bin/gallery and the installer reach `defaults` through GALLERY_DEFAULTS_BIN
# (the real one writes the real preferences whatever $HOME is): this stub too.
export GALLERY_DEFAULTS_BIN="${STUBS}/defaults"
chmod +x "${STUBS}"/*
export PATH="${STUBS}:${PATH}"
export GALLERY_NO_TERMINAL_RELOAD=1
export GALLERY_LSREGISTER=/usr/bin/true
unset GALLERY_CONFIG_DIR GALLERY_TERMINAL XDG_CONFIG_HOME STUB_RUNNING STUB_ITERM_GUID || true

contains() { grep -qF -- "$2" <<<"$1"; }
assert_contains() { contains "$1" "$2" || fail "$3: expected to find: $2
--- got:
$1"; }
assert_lacks() { contains "$1" "$2" && fail "$3: did not expect: $2
--- got:
$1"; return 0; }
assert_file() { [ -e "$1" ] || fail "$2: missing $1"; }
assert_gone() { [ ! -e "$1" ] && [ ! -L "$1" ] || fail "$2: still present: $1"; }
assert_same() { cmp -s "$1" "$2" || fail "$3: $1 differs from $2"; }
count_in() { grep -cF -- "$2" "$1" || true; }

# new_home <name> -- a fresh HOME with the skeleton any real Mac has.
new_home() {
  HOME_DIR="${WORK_DIR}/$1"
  rm -rf "${HOME_DIR}"
  mkdir -p "${HOME_DIR}/.config" "${HOME_DIR}/.local/state" "${HOME_DIR}/Library/Application Support" "${HOME_DIR}/Library/Logs"
  export HOME="${HOME_DIR}"
  mkdir -p "${WORK_DIR}/apps/Hammerspoon.app" "${WORK_DIR}/apps/kitty.app" "${WORK_DIR}/apps/Ghostty.app" "${WORK_DIR}/apps/WezTerm.app"
  export GALLERY_HAMMERSPOON_APP="${WORK_DIR}/apps/Hammerspoon.app"
  export GALLERY_TERM_APP_DIRS="${WORK_DIR}/apps"
}

# listing <root> <exclude-prefix>... -- sorted find output, minus excluded subtrees.
listing() {
  local root="$1" ex
  shift
  (cd "${root}" && find . | sort) > "${WORK_DIR}/listing.tmp"
  for ex in "$@"; do
    grep -v -e "^${ex}\$" -e "^${ex}/" "${WORK_DIR}/listing.tmp" > "${WORK_DIR}/listing.tmp2" || true
    mv "${WORK_DIR}/listing.tmp2" "${WORK_DIR}/listing.tmp"
  done
  cat "${WORK_DIR}/listing.tmp"
}

# --- scenario A: an existing setup ----------------------------------------------
say "scenario A: seeded user files"
new_home homeA
H="${HOME_DIR}"
ORIG="${WORK_DIR}/orig"
mkdir -p "${ORIG}"

seed() { # seed <path-under-HOME> <content>   (keeps a pristine copy in ORIG)
  mkdir -p "$(dirname "${H}/$1")" "$(dirname "${ORIG}/$1")"
  printf '%s' "$2" > "${H}/$1"
  cp -p "${H}/$1" "${ORIG}/$1"
}
seed .config/yabai/yabairc $'#!/usr/bin/env sh\n# my own yabairc\nyabai -m config layout float\n'
seed .config/skhd/skhdrc $'# my own skhdrc\nalt - a : echo hi\n'
seed .yabairc $'# an old dotfile that the new rc will shadow\n'
seed .hammerspoon/init.lua $'-- my hammerspoon\nhs.alert.show("mine")'
seed .config/kitty/kitty.conf $'font_size 13\n'
seed .config/ghostty/config $'theme = dark\n'
seed .config/btop/btop.conf $'color_theme = "Default"\nupdate_ms = 2000\n'
seed "Library/Application Support/superfile/config.toml" $'theme = "catppuccin"\nauto_check_update = true\n\n[open_with]\nmd = "glow"\n'
seed "Library/Application Support/com.apple.wallpaper/Store/Index.plist" $'not really a plist, only bytes to compare\n'
seed bin/mytool $'#!/bin/sh\necho mine\n'
chmod 755 "${H}/bin/mytool"
listing "${H}" > "${WORK_DIR}/A.before"

# Dry run first: it must change nothing and must say what it would do.
out="$("${INSTALL}" --dry-run --minimal 2>&1)" || { echo "${out}" >&2; fail "A: dry-run install failed"; }
assert_contains "${out}" "exists, user file: would back it up to ${H}/.config/yabai/yabairc.gallery-bak" "A dry-run names the backup"
assert_contains "${out}" "would back up ${H}/.hammerspoon/init.lua to ${H}/.hammerspoon/init.lua.gallery-bak" "A dry-run names the init.lua backup"
listing "${H}" > "${WORK_DIR}/A.dry"
diff -q "${WORK_DIR}/A.before" "${WORK_DIR}/A.dry" >/dev/null || fail "A: dry-run install changed the file tree"
for f in .config/yabai/yabairc .config/skhd/skhdrc .hammerspoon/init.lua; do assert_same "${H}/${f}" "${ORIG}/${f}" "A dry-run left ${f} alone"; done
say "A: dry-run install changes nothing and names each backup"

out="$("${INSTALL}" --minimal 2>&1)" || { echo "${out}" >&2; fail "A: install failed"; }
assert_contains "${out}" "WARNING: ${H}/.yabairc exists" "A warns about the shadowed ~/.yabairc"
assert_same "${H}/.config/yabai/yabairc.gallery-bak" "${ORIG}/.config/yabai/yabairc" "A yabairc backup"
assert_same "${H}/.config/skhd/skhdrc.gallery-bak" "${ORIG}/.config/skhd/skhdrc" "A skhdrc backup"
assert_same "${H}/.config/yabai/yabairc" "${REPO_ROOT}/tiler/yabairc" "A installed yabairc"
assert_same "${H}/.config/skhd/skhdrc" "${REPO_ROOT}/tiler/skhdrc" "A installed skhdrc"
assert_same "${H}/.config/skhd/gallery.skhd" "${REPO_ROOT}/skhd/gallery.skhd" "A installed gallery.skhd"
assert_same "${H}/bin/gallery" "${REPO_ROOT}/bin/gallery" "A installed gallery CLI"
assert_same "${H}/.hammerspoon/init.lua.gallery-bak" "${ORIG}/.hammerspoon/init.lua" "A init.lua backup"
[ "$(count_in "${H}/.hammerspoon/init.lua" "-- gallery:begin")" = 1 ] || fail "A: init.lua should hold one Gallery block"
grep -q 'hs.alert.show("mine")' "${H}/.hammerspoon/init.lua" || fail "A: init.lua lost the user's line"
assert_same "${H}/.yabairc" "${ORIG}/.yabairc" "A ~/.yabairc untouched"
assert_same "${H}/bin/mytool" "${ORIG}/bin/mytool" "A ~/bin/mytool untouched"
MAN="${H}/.config/gallery/state/install-manifest.tsv"
assert_file "${MAN}" "A manifest"
grep -q "^${H}/.config/yabai/yabairc	" "${MAN}" || fail "A: manifest lacks yabairc"
grep -q "^${H}/.config/yabai/yabairc	[0-9a-f]\{64\}	${H}/.config/yabai/yabairc.gallery-bak\$" "${MAN}" || fail "A: manifest should name the yabairc backup"
# The renderer changed the seeded companion settings, and recorded the originals.
grep -q 'color_theme = "gallery"' "${H}/.config/btop/btop.conf" || fail "A: btop.conf was not pointed at the gallery theme"
grep -q 'update_ms = 2000' "${H}/.config/btop/btop.conf" || fail "A: btop.conf lost another key"
assert_file "${H}/.config/gallery/state/conf-originals.json" "A conf record"
grep -q 'color_theme = \\"Default\\"' "${H}/.config/gallery/state/conf-originals.json" || fail "A: original btop line not recorded"
say "A: install backs up every file of the user's and records its own"

# Console wiring (what `gallery console theme` adds) for every terminal, the
# wallpaper hook's first apply, and a theme re-render.
GAL="${H}/bin/gallery"
for t in kitty ghostty wezterm; do
  "${GAL}" terminal set "${t}" >/dev/null 2>&1 || fail "A: gallery terminal set ${t}"
  "${GAL}" console theme >/dev/null 2>&1 || fail "A: gallery console theme (${t})"
done
grep -qF "include ${H}/.config/gallery/state/terminals/kitty.conf" "${H}/.config/kitty/kitty.conf" || fail "A: kitty include missing"
grep -qF "config-file = ?${H}/.config/gallery/state/terminals/ghostty.conf" "${H}/.config/ghostty/config" || fail "A: ghostty include missing"
assert_file "${H}/.wezterm.lua" "A wezterm.lua created by console theme"
mkdir -p "${H}/.config/gallery/themes/tokyo-night/backgrounds"
printf 'png' > "${H}/.config/gallery/themes/tokyo-night/backgrounds/default.png"
"${H}/.config/gallery/hooks/theme-set.d/30-wallpaper.sh" tokyo-night >/dev/null 2>&1 || fail "A: wallpaper hook failed"
SNAP="${H}/.config/gallery/state/wallpaper-original.plist"
assert_same "${SNAP}" "${ORIG}/Library/Application Support/com.apple.wallpaper/Store/Index.plist" "A wallpaper snapshot"
printf 'changed by the gallery\n' > "${H}/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
"${H}/.config/gallery/hooks/theme-set.d/30-wallpaper.sh" tokyo-night >/dev/null 2>&1 || fail "A: second wallpaper hook run failed"
assert_same "${SNAP}" "${ORIG}/Library/Application Support/com.apple.wallpaper/Store/Index.plist" "A snapshot is never overwritten"
"${GAL}" theme render >/dev/null 2>&1 || fail "A: theme render"
say "A: console wiring, wallpaper snapshot and theme render recorded"

# Reinstall: idempotent.
find "${H}" -name '*.gallery-*' | sort > "${WORK_DIR}/A.baks1"
cp "${MAN}" "${WORK_DIR}/A.manifest1"
printf 'user plugin file\n' > "${H}/.config/gallery/plugins/gallery.hello/mine.txt"
out="$("${INSTALL}" --minimal 2>&1)" || { echo "${out}" >&2; fail "A: reinstall failed"; }
find "${H}" -name '*.gallery-*' | sort > "${WORK_DIR}/A.baks2"
diff "${WORK_DIR}/A.baks1" "${WORK_DIR}/A.baks2" >/dev/null || fail "A: reinstall created new backup files:
$(diff "${WORK_DIR}/A.baks1" "${WORK_DIR}/A.baks2")"
diff "${WORK_DIR}/A.manifest1" "${MAN}" >/dev/null || fail "A: manifest changed on reinstall"
[ "$(count_in "${H}/.hammerspoon/init.lua" "-- gallery:begin")" = 1 ] || fail "A: reinstall duplicated the init.lua block"
[ "$(count_in "${H}/.config/kitty/kitty.conf" "state/terminals/kitty.conf")" = 1 ] || fail "A: kitty include duplicated"
[ "$(count_in "${H}/.config/ghostty/config" "state/terminals/ghostty.conf")" = 1 ] || fail "A: ghostty include duplicated"
assert_same "${SNAP}" "${ORIG}/Library/Application Support/com.apple.wallpaper/Store/Index.plist" "A snapshot after reinstall"
assert_gone "${H}/.config/gallery/plugins/gallery.hello/mine.txt" "A user file in a Gallery directory is moved aside"
assert_same "$(find "${H}/.config/gallery/backup" -name mine.txt | head -n 1)" <(printf 'user plugin file\n') "A moved-aside plugin file is kept"
say "A: reinstall is idempotent and moves a stray file out of a Gallery directory into backup/"

# A stale init.lua block is refreshed in place.
python3 - "${H}/.hammerspoon/init.lua" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace('hs.loadSpoon("Gallery")', 'hs.loadSpoon("Gallery") -- stale')
open(p, "w").write(s)
PY
"${INSTALL}" --minimal >/dev/null 2>&1 || fail "A: reinstall (stale block) failed"
grep -q -- '-- stale' "${H}/.hammerspoon/init.lua" && fail "A: stale init.lua block was not refreshed"
[ "$(count_in "${H}/.hammerspoon/init.lua" "-- gallery:begin")" = 1 ] || fail "A: refresh duplicated the block"
say "A: a stale init.lua block is refreshed"

# An edited Gallery file is kept as .gallery-edited on reinstall.
printf '# my own binding\n' >> "${H}/.config/skhd/gallery.skhd"
out="$("${INSTALL}" --minimal 2>&1)" || fail "A: reinstall after edit failed"
assert_contains "${out}" "was edited since it was installed" "A warns about the edited file"
assert_contains "${out}" "local.skhd" "A points at the local override"
edited="$(find "${H}/.config/skhd" -name 'gallery.skhd.gallery-edited.*' | head -n 1)"
[ -n "${edited}" ] || fail "A: no .gallery-edited copy"
grep -q 'my own binding' "${edited}" || fail "A: .gallery-edited copy lacks the edit"
assert_same "${H}/.config/skhd/gallery.skhd" "${REPO_ROOT}/skhd/gallery.skhd" "A gallery.skhd reinstalled"
say "A: an edited Gallery file is saved as .gallery-edited before it is overwritten"
rm -f "${edited}"

# Uninstall: dry run first.
listing "${H}" > "${WORK_DIR}/A.pre-uninstall"
out="$("${INSTALL}" --uninstall --dry-run 2>&1)" || fail "A: dry-run uninstall failed"
assert_contains "${out}" "would restore ${H}/.config/yabai/yabairc.gallery-bak to ${H}/.config/yabai/yabairc" "A dry-run uninstall names the restore"
listing "${H}" > "${WORK_DIR}/A.post-dry"
diff -q "${WORK_DIR}/A.pre-uninstall" "${WORK_DIR}/A.post-dry" >/dev/null || fail "A: dry-run uninstall changed the tree"

: > "${STUB_LOG}"
STUB_RUNNING="borders Hammerspoon" "${INSTALL}" --uninstall > "${WORK_DIR}/A.uninstall.out" 2>&1 || { cat "${WORK_DIR}/A.uninstall.out" >&2; fail "A: uninstall failed"; }
# Hammerspoon still had the Gallery loaded: it is quit, and reopened only
# for a config of the user's own (scenario A seeds one).
assert_contains "$(cat "${STUB_LOG}")" 'osascript -e tell application id "org.hammerspoon.Hammerspoon" to quit' "A quits Hammerspoon"
assert_contains "$(cat "${STUB_LOG}")" "open -a Hammerspoon" "A reopens Hammerspoon for the user's own init.lua"
[ -z "${INSTALL_TEST_VERBOSE:-}" ] || cat "${WORK_DIR}/A.uninstall.out"
for f in .config/yabai/yabairc .config/skhd/skhdrc .yabairc .hammerspoon/init.lua .config/kitty/kitty.conf \
         .config/ghostty/config .config/btop/btop.conf "Library/Application Support/superfile/config.toml" \
         "Library/Application Support/com.apple.wallpaper/Store/Index.plist" bin/mytool; do
  assert_same "${H}/${f}" "${ORIG}/${f}" "A uninstall restores ${f}"
done
assert_gone "${H}/.wezterm.lua" "A wezterm.lua"
assert_gone "${H}/.hammerspoon/Spoons/Gallery.spoon" "A Spoon"
assert_gone "${MAN}" "A manifest"
assert_gone "${H}/.config/gallery/state/conf-originals.json" "A conf record"
log="$(cat "${STUB_LOG}")"
assert_contains "${log}" "yabai --stop-service" "A stops yabai"
assert_contains "${log}" "yabai --uninstall-service" "A unregisters yabai"
assert_contains "${log}" "skhd --uninstall-service" "A unregisters skhd"
assert_contains "${log}" "killall borders" "A stops borders (not a brew service)"
assert_contains "${log}" "killall WallpaperAgent" "A restarts WallpaperAgent for the wallpaper restore"
find "${H}" \( -name '*.gallery-bak*' -o -name '*.gallery-edited*' \) | grep -v "/.config/gallery/" && fail "A: backup files left behind" || true
# Nothing but the user's files and ~/.config/gallery remains.
listing "${H}" ./.config/gallery > "${WORK_DIR}/A.after"
# (The wallpaper hook's own log is left in ~/Library/Logs; --purge removes it.)
listing_before_ex="$(grep -v -e '^\./\.config/gallery' -e '^\./Library/Logs\(/\|$\)' "${WORK_DIR}/A.before" || true)"
after_ex="$(grep -v -e '^\./Library/Logs\(/\|$\)' "${WORK_DIR}/A.after" || true)"
[ "${listing_before_ex}" = "${after_ex}" ] || fail "A: files differ from before the install:
$(diff <(echo "${listing_before_ex}") <(echo "${after_ex}"))"
assert_file "${H}/.config/gallery" "A ~/.config/gallery kept without --purge"
say "A: uninstall restores every seeded file byte for byte and stops/unregisters the services"

if "${INSTALL}" --uninstall --purge </dev/null >/dev/null 2>&1; then fail "A: --purge ran without a confirmation"; fi
assert_file "${H}/.config/gallery" "A an unconfirmed --purge changes nothing"
"${INSTALL}" --uninstall --purge --yes >/dev/null 2>&1 || fail "A: uninstall --purge failed"
assert_gone "${H}/.config/gallery" "A --purge"
say "A: --purge removes ~/.config/gallery"

# --- scenario B: nothing pre-existing ------------------------------------------------
say "scenario B: clean HOME"
new_home homeB
H="${HOME_DIR}"
listing "${H}" > "${WORK_DIR}/B.before"
"${INSTALL}" --minimal >/dev/null 2>&1 || fail "B: install failed"
assert_file "${H}/.config/yabai/yabairc" "B yabairc"
assert_file "${H}/.hammerspoon/init.lua" "B init.lua"
assert_file "${H}/Library/Application Support/iTerm2/DynamicProfiles/gallery-theme.json" "B iTerm profile"
[ ! -e "${H}/.config/yabai/yabairc.gallery-bak" ] || fail "B: backed up a file that did not exist"
# A stale block in an init.lua the Gallery created is refreshed without a
# backup: there is nothing of the user's in it to keep.
sed -i '' 's/^require("hs.ipc")$/require("hs.ipc") -- stale/' "${H}/.hammerspoon/init.lua"
"${INSTALL}" --minimal >/dev/null 2>&1 || fail "B: reinstall failed"
[ ! -e "${H}/.hammerspoon/init.lua.gallery-bak" ] || fail "B: backed up an init.lua the Gallery created"
grep -q -- '-- stale' "${H}/.hammerspoon/init.lua" && fail "B: the stale block was not refreshed"
assert_same "${H}/.config/skhd/local.skhd" "${REPO_ROOT}/tiler/local.skhd.example" "B seeds local.skhd"
assert_file "${H}/.config/skhd/tiler.skhd" "B tiler.skhd"
# The user's own iTerm2 default, as `gallery console theme` notes it when it
# makes Console the default: the uninstall must give it back.
python3 - "${H}/.config/gallery/state/console.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["iterm_default_before"] = "MY-OWN-GUID"
json.dump(d, open(p, "w"))
PY
# brew services shows borders registered: it must be left running.
: > "${STUB_LOG}"
STUB_RUNNING="borders" STUB_BREW_SERVICES="borders started" STUB_ITERM_GUID="gallery-console" \
  "${INSTALL}" --uninstall > "${WORK_DIR}/B.uninstall.out" 2>&1 || { cat "${WORK_DIR}/B.uninstall.out" >&2; fail "B: uninstall failed"; }
assert_lacks "$(cat "${STUB_LOG}")" "killall borders" "B leaves a brew-managed borders alone"
[ -f "${H}/Library/Application Support/iTerm2/DynamicProfiles/gallery-console.json" ] || fail "B: Console profile removed while it is iTerm2's default"
assert_contains "$(cat "${STUB_LOG}")" "defaults write com.googlecode.iterm2 Default Bookmark Guid -string MY-OWN-GUID" "B gives iTerm2's own default back"
assert_contains "$(cat "${WORK_DIR}/B.uninstall.out")" "set your own profile as the default" "B tells how to release the Console profile"
assert_gone "${H}/Library/Application Support/iTerm2/DynamicProfiles/gallery-theme.json" "B gallery-theme.json"
assert_gone "${H}/.config/skhd/local.skhd" "B removes the unedited local.skhd seed"
assert_gone "${H}/.config/skhd/tiler.skhd" "B tiler.skhd"
rm -rf "${H}/Library/Application Support/iTerm2"
# An edited local.skhd is the user's and survives uninstall.
"${INSTALL}" --minimal >/dev/null 2>&1 || fail "B: second install failed"
echo 'lalt - p : echo mine' >> "${H}/.config/skhd/local.skhd"
"${INSTALL}" --minimal >/dev/null 2>&1 || fail "B: third install failed"
assert_contains "$(cat "${H}/.config/skhd/local.skhd")" "echo mine" "B reinstall keeps an edited local.skhd"
"${INSTALL}" --uninstall >/dev/null 2>&1 || fail "B: second uninstall failed"
assert_contains "$(cat "${H}/.config/skhd/local.skhd")" "echo mine" "B uninstall keeps an edited local.skhd"
rm -f "${H}/.config/skhd/local.skhd"; rmdir "${H}/.config/skhd" 2>/dev/null || true
rm -rf "${H}/Library/Application Support/iTerm2"
"${INSTALL}" --uninstall --purge --yes >/dev/null 2>&1 || fail "B: uninstall --purge failed"
listing "${H}" > "${WORK_DIR}/B.after"
diff "${WORK_DIR}/B.before" "${WORK_DIR}/B.after" >/dev/null || fail "B: uninstall left a trace:
$(diff "${WORK_DIR}/B.before" "${WORK_DIR}/B.after")"
say "B: install then uninstall --purge leaves nothing behind; brew-managed borders and an in-use Console profile are kept"

# --- scenario C: an install from before the manifest existed ---------------------------
say "scenario C: upgrade from an install without a manifest"
new_home homeC
H="${HOME_DIR}"
mkdir -p "${H}/.config/yabai" "${H}/.config/skhd"
cp "${REPO_ROOT}/tiler/yabairc" "${H}/.config/yabai/yabairc"
{ cat "${REPO_ROOT}/tiler/skhdrc"; echo "# older version"; } > "${H}/.config/skhd/skhdrc"
"${INSTALL}" --minimal >/dev/null 2>&1 || fail "C: install failed"
[ ! -e "${H}/.config/yabai/yabairc.gallery-bak" ] || fail "C: an identical Gallery file was backed up as the user's"
[ ! -e "${H}/.config/skhd/skhdrc.gallery-bak" ] || fail "C: an older Gallery file was backed up as the user's"
ls "${H}/.config/skhd"/skhdrc.gallery-edited.* >/dev/null 2>&1 || fail "C: no safety copy of the older Gallery file"
say "C: files recognised as an earlier Gallery install are overwritten, with a safety copy"

# --- scenario D: the renderer's companion-app handling ---------------------------------
say "scenario D: btop / superfile settings"
new_home homeD
H="${HOME_DIR}"
RENDER="${REPO_ROOT}/tools/render-theme.py"
mkdir -p "${H}/.config/gallery/themes"
cp -R "${REPO_ROOT}/themes/tokyo-night" "${H}/.config/gallery/themes/tokyo-night"
ln -s tokyo-night "${H}/.config/gallery/themes/current"
# A PATH without Homebrew, so neither btop nor spf can be found.
NOAPPS_PATH="/usr/bin:/bin"
PATH="${NOAPPS_PATH}" python3 "${RENDER}" > "${WORK_DIR}/D.render1" 2>&1 || { cat "${WORK_DIR}/D.render1" >&2; fail "D: render failed"; }
assert_contains "$(cat "${WORK_DIR}/D.render1")" "btop: not installed, skipped" "D render reports btop absent"
assert_gone "${H}/.config/btop" "D btop config dir is not created for an app that is not installed"
assert_gone "${H}/Library/Application Support/superfile" "D superfile config dir is not created either"
mkdir -p "${H}/.config/btop"
printf 'update_ms = 2000\n' > "${H}/.config/btop/btop.conf"
PATH="${NOAPPS_PATH}" python3 "${RENDER}" >/dev/null 2>&1 || fail "D: render with a btop config failed"
grep -q 'color_theme = "gallery"' "${H}/.config/btop/btop.conf" || fail "D: btop.conf not updated once its config dir exists"
RECORD="${H}/.config/gallery/state/conf-originals.json"
PYCHECK='import json,sys; d=json.load(open(sys.argv[1])); v=list(d.values())[0]; assert v["color_theme"] is None, v'
python3 -c "${PYCHECK}" "${RECORD}" || fail "D: an absent key should be recorded as null"
PATH="${NOAPPS_PATH}" python3 "${RENDER}" >/dev/null 2>&1 || fail "D: second render failed"
python3 -c "${PYCHECK}" "${RECORD}" || fail "D: the record was overwritten by a later render"
# A value the user changed after the Gallery set it is not clobbered on restore.
printf 'update_ms = 2000\ncolor_theme = "Mine"\n' > "${H}/.config/btop/btop.conf"
PATH="${NOAPPS_PATH}" python3 "${RENDER}" --restore-confs > "${WORK_DIR}/D.restore" 2>&1 || fail "D: restore-confs failed"
assert_contains "$(cat "${WORK_DIR}/D.restore")" "changed since the Gallery set it" "D restore leaves a value the user changed"
grep -q 'color_theme = "Mine"' "${H}/.config/btop/btop.conf" || fail "D: the user's later choice was overwritten"
assert_gone "${RECORD}" "D record is deleted after the restore"
say "D: companion apps are only touched when installed; originals are recorded once and restored"

say "all install tests passed"
