#!/usr/bin/env bash
#
# themes_picker_test.sh -- offline test of the theme picker plugin
# (plugins/gallery.themes/themes.sh) and the `gallery theme list` it is
# built on: the light/current markers, the swatch header, the startup facts
# handed to fzf's subprocesses, and the downscaled preview cache.
#
# Never touches the real desktop: HOME is a temp directory, the CLI is the
# repo's own copy, and nothing here sets a theme or a wallpaper.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PICKER="${REPO_ROOT}/plugins/gallery.themes/themes.sh"

say() { echo "[themes_picker_test] $*"; }
fail() { echo "[themes_picker_test] FAIL: $*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"

WORK="$(mktemp -d "$(dirname "${TMPDIR:-/tmp}/x")/gallery-themepicker-test.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
H="${WORK}/home"
CFG="${H}/.config/gallery"
T="${CFG}/themes"
CACHE="${CFG}/cache/theme-previews"
mkdir -p "${H}/bin" "${T}"
cp "${REPO_ROOT}/bin/gallery" "${H}/bin/gallery"

# png W H R G B FILE -- a solid-colour PNG, stdlib only.
png() {
  python3 - "$@" <<'PY'
import struct, sys, zlib
w, h, r, g, b = map(int, sys.argv[1:6]); out = sys.argv[6]
raw = b"".join(b"\x00" + bytes([r, g, b]) * w for _ in range(h))
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
open(out, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                      + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
PY
}

# Four themes: dark, light by colors.toml mode, light by light.mode file,
# and one whose colors.toml lacks keys (and has a decoy bright_ key).
mkdir -p "${T}/alpha/backgrounds" "${T}/beta" "${T}/gamma" "${T}/delta"
printf 'mode = "dark"\naccent = "#112233"\nbackground = "#000000"\nforeground = "#ffffff"\nred = "#ff0000"\n' \
  > "${T}/alpha/colors.toml"
printf 'mode = "light"\naccent = "#abcdef"\n' > "${T}/beta/colors.toml"
printf 'accent = "#123456"\n' > "${T}/gamma/colors.toml"; : > "${T}/gamma/light.mode"
printf 'bright_foreground = "#eeeeee"\nforeground = "#cccccc"\nforeground = "#999999"\nblue = "nothex"\n' \
  > "${T}/delta/colors.toml"
ln -sfn alpha "${T}/current"
png 3200 1800 10 20 30 "${T}/alpha/backgrounds/wall.png"

g() { HOME="${H}" XDG_CONFIG_HOME="${H}/.config" "${H}/bin/gallery" "$@"; }
picker() { HOME="${H}" XDG_CONFIG_HOME="${H}/.config" COLUMNS=200 "${PICKER}" "$@"; }

# --- gallery theme list -------------------------------------------------------
want=$'alpha (current)\nbeta (light)\ndelta\ngamma (light)'
[ "$(g theme list)" = "${want}" ] || fail "theme list: got $(g theme list | tr '\n' '|')"
[ "$(g theme current)" = "alpha" ] || fail "theme current"
say "theme list: current and both light rules marked, 'current' link skipped"

# --- picker list ------------------------------------------------------------------
[ "$(picker --list)" = $'alpha\talpha (current)\nbeta\tbeta (light)\ndelta\tdelta\ngamma\tgamma (light)' ] \
  || fail "picker --list: got $(picker --list | tr '\n\t' '|>')"
say "picker list: bare name, then the annotated line"

# --- swatch header ------------------------------------------------------------------
sw="$(picker --swatches alpha)"
printf '%s\n' "${sw}" | grep -q '^Current: alpha -- ' || fail "swatches: header names the current theme"
printf '%s\n' "${sw}" | grep -q $'\033\[48;2;17;34;51m   \033\[0m  accent           #112233' \
  || fail "swatches: accent cell"
# delta: the first foreground line wins, bright_foreground is not foreground,
# a malformed value leaves a blank cell of the same width.
sd="$(picker --swatches delta | sed 's/\x1b\[[0-9;]*m//g')"
printf '%s\n' "${sd}" | grep -q '^   *  foreground       #cccccc' || fail "swatches: first foreground line wins"
printf '%s\n' "${sd}" | grep -q 'bright_foreground #eeeeee' || fail "swatches: bright_foreground cell"
row="$(printf '%s\n' "${sd}" | grep 'bright_foreground')"
[ "${row%%bright_foreground*}" = "$(printf '%*s' 36 '')" ] \
  || fail "swatches: a malformed colour must still pad its cell (got '${row%%bright_foreground*}')"
# Compact form (narrow window): no hex values.
# (Output captured first: grep -q quitting early would SIGPIPE the picker,
# and pipefail would count that as a failure.)
out="$(COLUMNS=100 HOME="${H}" XDG_CONFIG_HOME="${H}/.config" "${PICKER}" --swatches alpha)"
case "${out}" in *'#112233'*) fail "swatches: compact form must drop the hex values" ;; esac
# The startup facts passed through the environment are honoured.
out="$(GALLERY_THEMES_CURRENT=beta GALLERY_THEMES_WIDGETS=1 picker --swatches alpha)"
printf '%s\n' "${out}" | grep -q '^Current: beta -- ' \
  || fail "swatches: GALLERY_THEMES_CURRENT from the picker's startup"
printf '%s\n' "${out}" | grep -q '^Widgets: own colours' \
  || fail "swatches: GALLERY_THEMES_WIDGETS=1 shows the widgets line"
out="$(GALLERY_THEMES_WIDGETS=0 picker --swatches alpha)"
printf '%s\n' "${out}" | grep -q '^Widgets:' \
  && fail "swatches: GALLERY_THEMES_WIDGETS=0 hides the widgets line"
say "swatches: palette grid, missing/malformed keys, compact form, startup env"

# --- prefs ------------------------------------------------------------------------------
mkdir -p "${CFG}/state"
printf '{"mode": "theme"}' > "${CFG}/state/console.json"
printf '{"width": 99, "bright": true}' > "${CFG}/state/borders.json"
printf 'not json' > "${CFG}/state/widgets.json"
s="$(GALLERY_THEMES_WIDGETS=1 picker --swatches alpha)"
printf '%s\n' "${s}" | grep -q '^Console: follows theme' || fail "prefs: console mode"
printf '%s\n' "${s}" | grep -q 'width ( )3 ( )5 ( )8 (•)12 ' || fail "prefs: width clamped to 12"
printf '%s\n' "${s}" | grep -q 'bright ( )off (•)on' || fail "prefs: bright"
printf '%s\n' "${s}" | grep -q '^Widgets: own colours' || fail "prefs: garbage widgets.json reads as native"
[ "$(picker --next-width)" = "3" ] || fail "prefs: next width after 12 is 3"
say "prefs: three state files read in one go, defaults and clamping kept"

# --- preview cache --------------------------------------------------------------------
FZF_PREVIEW_COLUMNS=40 FZF_PREVIEW_LINES=20 picker --preview alpha >/dev/null 2>&1
n="$(find "${CACHE}" -name '*.jpg' 2>/dev/null | wc -l | tr -d ' ')"
[ "${n}" = "1" ] || fail "preview: expected one downscaled copy in the cache, found ${n}"
copy="$(find "${CACHE}" -name '*.jpg')"
w="$(sips -g pixelWidth "${copy}" | awk '/pixelWidth/{print $2}')"
h="$(sips -g pixelHeight "${copy}" | awk '/pixelHeight/{print $2}')"
[ "${w}" = "1600" ] && [ "${h}" = "900" ] || fail "preview: copy should be 1600x900, got ${w}x${h}"
FZF_PREVIEW_COLUMNS=40 FZF_PREVIEW_LINES=20 picker --preview alpha >/dev/null 2>&1
[ "$(find "${CACHE}" -name '*.jpg' | wc -l | tr -d ' ')" = "1" ] || fail "preview: a second look must reuse the copy"
sleep 1; png 3200 1800 200 20 30 "${T}/alpha/backgrounds/wall.png"
FZF_PREVIEW_COLUMNS=40 FZF_PREVIEW_LINES=20 picker --preview alpha >/dev/null 2>&1
[ "$(find "${CACHE}" -name '*.jpg' | wc -l | tr -d ' ')" = "2" ] || fail "preview: a replaced wallpaper needs a new copy"
[ "$(picker --dims alpha)" = "alpha  wall.png  3200x1800" ] || fail "dims: label keeps the original size, got $(picker --dims alpha)"
[ "$(picker --preview beta)" = "no backgrounds" ] || fail "preview: a theme without wallpapers"
rm -rf "${CACHE}"
picker --warm-previews
[ "$(find "${CACHE}" -name '*.jpg' | wc -l | tr -d ' ')" = "1" ] || fail "warm: one copy per theme with a wallpaper"
find "${CACHE}" -name '*.tmp' | grep -q . && fail "warm: no temp files left behind"
say "preview: downscaled copy made once, reused, redrawn on change, warmed ahead"

# --- offload: CLI -------------------------------------------------------------------
export GALLERY_THEME_OFFLOAD_HOOKS_DIR="${WORK}/offload.d"
mkdir -p "${GALLERY_THEME_OFFLOAD_HOOKS_DIR}" "${WORK}/kept"
# A keeper hook for themes linked into ${WORK}/store: its "elsewhere" is ${WORK}/kept.
cat > "${GALLERY_THEME_OFFLOAD_HOOKS_DIR}/50-test" <<EOF
#!/usr/bin/env bash
set -euo pipefail
verb="\$1" name="\$2" path="\$3" store="${WORK}/store" kept="${WORK}/kept"
case "\${verb}" in
  check)   [ -L "\${path}" ] || exit 3; echo "kept in test"; exit 0 ;;
  offload) cp -R "\${store}/\${name}" "\${kept}/"; rm -rf "\${store}/\${name}" ;;
  restore) cp -R "\${kept}/\${name}" "\${store}/"; ln -s "\${store}/\${name}" "\${path}" ;;
esac
EOF
chmod +x "${GALLERY_THEME_OFFLOAD_HOOKS_DIR}/50-test"
mkdir -p "${WORK}/store/epsilon/backgrounds"
printf 'accent = "#0000ff"\n' > "${WORK}/store/epsilon/colors.toml"
png 64 36 1 2 3 "${WORK}/store/epsilon/backgrounds/e.png"
ln -s "${WORK}/store/epsilon" "${T}/epsilon"

out="$(g theme offload alpha 2>&1)" && fail "offload: the current theme must be refused"
[[ "${out}" == *"current theme"* ]] || fail "offload: current theme reason, got: ${out}"
out="$(g theme offload delta 2>&1)" && fail "offload: a theme with no keeper must be refused"
[[ "${out}" == *"no copy elsewhere"* ]] || fail "offload: no-keeper reason, got: ${out}"
[ -d "${T}/delta" ] || fail "offload: a refused theme must stay"
[ "$(g theme offload --check epsilon | cut -f2)" = "kept in test" ] || fail "offload --check: where"
out="$(g theme offload epsilon)"
[[ "${out}" == "epsilon offloaded, "*" freed (kept in test)" ]] || fail "offload: message, got: ${out}"
[ ! -e "${T}/epsilon" ] && [ ! -e "${WORK}/store/epsilon" ] && [ -f "${WORK}/kept/epsilon/colors.toml" ] \
  || fail "offload: the link and the hook's copy here go, the kept copy stays"
[ "$(g theme offloaded)" = "epsilon  (kept in test)" ] || fail "offloaded: list, got: $(g theme offloaded)"
g theme restore epsilon >/dev/null
[ -L "${T}/epsilon" ] && [ -f "${T}/epsilon/backgrounds/e.png" ] || fail "restore: the hook puts it back"
[ -z "$(g theme offloaded)" ] || fail "restore: no longer listed as offloaded"
# A hook that fails its check stops the offload.
printf '#!/bin/sh\necho "mirror unreachable"; exit 1\n' > "${GALLERY_THEME_OFFLOAD_HOOKS_DIR}/10-broken"
chmod +x "${GALLERY_THEME_OFFLOAD_HOOKS_DIR}/10-broken"
out="$(g theme offload epsilon 2>&1)" && fail "offload: a failing check must stop it"
[[ "${out}" == *"mirror unreachable"* ]] && [ -L "${T}/epsilon" ] || fail "offload: failing check reason, theme kept"
rm -f "${GALLERY_THEME_OFFLOAD_HOOKS_DIR}/10-broken"
# Vendored: the small files are kept, the wallpapers freed; restore puts them back.
printf 'alpha\nbeta\n' > "${CFG}/state/vendored-themes"
mkdir -p "${T}/beta/backgrounds"; png 64 36 9 9 9 "${T}/beta/backgrounds/b.png"
[ "$(g theme offload --check beta | cut -f2)" = "an Omarchy theme: restore brings it back, install.sh its wallpapers" ] \
  || fail "offload --check vendored: where, got: $(g theme offload --check beta)"
g theme offload beta >/dev/null
[ ! -e "${T}/beta" ] && [ -f "${CFG}/state/offloaded/beta/colors.toml" ] \
  && [ ! -e "${CFG}/state/offloaded/beta/backgrounds" ] || fail "offload vendored: record keeps colors only"
[[ "$(g theme restore beta)" == *"install.sh"* ]] || fail "restore vendored: says install.sh brings the wallpapers"
[ -f "${T}/beta/colors.toml" ] && [ ! -e "${CFG}/state/offloaded/beta" ] || fail "restore vendored: files back, record gone"
out="$(g theme restore beta 2>&1)" && fail "restore: a theme not offloaded must be refused"
say "offload: refusals, hook keeper, vendored keeper, restore, failing check"

# --- offload: picker (ctrl-x twice, Esc cancels, moving cancels) -----------------------------
export GALLERY_THEMES_STATE="${WORK}/pickerstate"; mkdir -p "${GALLERY_THEMES_STATE}"
[ "$(picker --esc epsilon)" = "abort" ] || fail "esc: closes when nothing is pending"
[[ "$(picker --offload-key epsilon)" == "transform-header("*"--swatches {1})" ]] || fail "ctrl-x 1: asks"
h="$(picker --swatches epsilon | sed 's/\x1b\[[0-9;]*m//g')"
[[ "${h}" == "Offload epsilon from this Mac?"* ]] || fail "ctrl-x 1: confirmation header, got: ${h%%$'\n'*}"
[[ "${h}" == *"Kept: kept in test"* && "${h}" == *"ctrl-x again offloads"* ]] || fail "ctrl-x 1: size, where, keys"
[[ "$(picker --esc epsilon)" == "transform-header("* ]] || fail "esc: cancels a pending offload"
[ -L "${T}/epsilon" ] || fail "esc: nothing offloaded"
picker --offload-key epsilon >/dev/null
picker --swatches gamma >/dev/null   # the cursor moved: cancels
[ ! -f "${GALLERY_THEMES_STATE}/pending" ] || fail "moving away must cancel"
picker --offload-key epsilon >/dev/null
out="$(picker --offload-key epsilon)"
[[ "${out}" == "reload-sync("*"--list)"* ]] || fail "ctrl-x 2: reloads the list"
# No {1} in the outcome: fzf drops an action whose placeholder is empty, and
# the list may be empty after the offload (the query matched only that theme).
[[ "${out}" != *"{1}"* ]] || fail "ctrl-x 2: the outcome must show even with an empty list"
picker --header-only | sed 's/\x1b\[[0-9;]*m//g' | head -1 | grep -q '^epsilon offloaded, ' \
  || fail "ctrl-x 2: --header-only shows the outcome"
[ ! -e "${T}/epsilon" ] || fail "ctrl-x 2: offloaded"
picker --swatches gamma | sed 's/\x1b\[[0-9;]*m//g' | head -1 | grep -q '^epsilon offloaded, ' \
  || fail "ctrl-x 2: outcome replaces the Current line"
[[ "$(picker --offload-key alpha)" != *"{1}"* ]] || fail "ctrl-x refused: the reason must show even with an empty list"
picker --swatches alpha | sed 's/\x1b\[[0-9;]*m//g' | head -1 | grep -q 'current theme' \
  || fail "ctrl-x on the current theme: reason shown"
[ ! -f "${GALLERY_THEMES_STATE}/pending" ] || fail "ctrl-x on the current theme: nothing pending"
picker --list | grep -q '^epsilon' && fail "list: an offloaded theme is gone from the list"
unset GALLERY_THEMES_STATE
say "picker: ctrl-x asks then offloads, Esc and moving cancel, refusals shown"

bash -n "${PICKER}" || fail "syntax"
/bin/bash -n "${PICKER}" || fail "syntax under /bin/bash (3.2)"
say "all checks passed"
