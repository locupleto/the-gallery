#!/usr/bin/env bash
#
# backgrounds_picker_test.sh -- offline test of the wallpaper picker plugin
# (plugins/gallery.backgrounds/backgrounds.sh) with LEFT/RIGHT pairs: the
# preview label, the stitched panorama preview and its cache, and the fzf
# bindings that keep the picker open on Enter.
#
# Never touches the real desktop: HOME is a temp directory, and nothing here
# applies a wallpaper. The stitching runs the real osascript (AppKit draws
# into a file; no window, no desktop change).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PICKER="${REPO_ROOT}/plugins/gallery.backgrounds/backgrounds.sh"

say() { echo "[backgrounds_picker_test] $*"; }
fail() { echo "[backgrounds_picker_test] FAIL: $*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"

WORK="$(mktemp -d "$(dirname "${TMPDIR:-/tmp}/x")/gallery-bgpicker-test.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
H="${WORK}/home"
CFG="${H}/.config/gallery"
BG="${CFG}/themes/jade/backgrounds"
CACHE="${CFG}/cache/pair-previews"
mkdir -p "${BG}"
ln -sfn jade "${CFG}/themes/current"

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
png 64 36 200 0 0 "${BG}/a.png"
png 64 36 255 0 0 "${BG}/b.left.png"
png 64 36 0 0 255 "${BG}/b.right.png"
png 64 36 0 255 0 "${BG}/c.left.png"   # a lone .left: an ordinary image

picker() { HOME="${H}" XDG_CONFIG_HOME="${H}/.config" "${PICKER}" "$@"; }

# --- preview label ----------------------------------------------------------
[ "$(picker --dims b.left.png)" = "b  pair, 2 x 64x36" ] \
  || fail "dims: a pair is labelled by its stem as one wallpaper on two displays, got: $(picker --dims b.left.png)"
[ "$(picker --dims a.png)" = "a.png  64x36" ] || fail "dims: a single image keeps its plain label"
[ "$(picker --dims c.left.png)" = "c.left.png  64x36" ] || fail "dims: a lone .left is not a pair"
say "label: a pair reads as one wallpaper across two displays"

# --- stitched preview ---------------------------------------------------------
# PATH without chafa/imgcat would still reach the stitching; the image
# output itself is not checked, only the stitched file it was drawn from.
FZF_PREVIEW_COLUMNS=40 FZF_PREVIEW_LINES=20 picker --preview b.left.png >/dev/null 2>&1
n="$(find "${CACHE}" -name '*.jpg' 2>/dev/null | wc -l | tr -d ' ')"
[ "${n}" = "1" ] || fail "preview: expected one stitched panorama in the cache, found ${n}"
stitched="$(find "${CACHE}" -name '*.jpg')"
w="$(sips -g pixelWidth "${stitched}" | awk '/pixelWidth/{print $2}')"
h="$(sips -g pixelHeight "${stitched}" | awk '/pixelHeight/{print $2}')"
[ "${w}" = "3219" ] && [ "${h}" = "900" ] \
  || fail "preview: the panorama should be two 1600 px halves plus the bezel strip (3219x900), got ${w}x${h}"
say "preview: both halves stitched side by side with a bezel strip"

# The halves really are left then right: sample the middle of each half.
python3 - "${stitched}" <<'PY' || fail "preview: halves are not left=red, right=blue"
import subprocess, sys
f = sys.argv[1]
# sips converts to BMP so the pixels can be read without extra modules.
bmp = f + ".bmp"
subprocess.run(["sips", "-s", "format", "bmp", f, "--out", bmp], check=True, capture_output=True)
d = open(bmp, "rb").read()
off = int.from_bytes(d[10:14], "little"); w = int.from_bytes(d[18:22], "little", signed=True)
bpp = int.from_bytes(d[28:30], "little") // 8; row = (w * bpp + 3) // 4 * 4
def px(x, y): i = off + y * row + x * bpp; return d[i + 2], d[i + 1], d[i]
l, r, gap = px(800, 450), px(2400, 450), px(1609, 450)
assert l[0] > 200 and l[2] < 60, l
assert r[2] > 200 and r[0] < 60, r
assert max(gap) < 40, gap
PY
say "preview: left half on the left, right half on the right, black between"

FZF_PREVIEW_COLUMNS=40 FZF_PREVIEW_LINES=20 picker --preview b.left.png >/dev/null 2>&1
[ "$(find "${CACHE}" -name '*.jpg' | wc -l | tr -d ' ')" = "1" ] || fail "preview: a second look must reuse the cache"
sleep 1; png 64 36 0 0 200 "${BG}/b.right.png"
FZF_PREVIEW_COLUMNS=40 FZF_PREVIEW_LINES=20 picker --preview b.left.png >/dev/null 2>&1
[ "$(find "${CACHE}" -name '*.jpg' | wc -l | tr -d ' ')" = "2" ] || fail "preview: a replaced half must draw a new panorama"
FZF_PREVIEW_COLUMNS=40 FZF_PREVIEW_LINES=20 picker --preview a.png >/dev/null 2>&1
FZF_PREVIEW_COLUMNS=40 FZF_PREVIEW_LINES=20 picker --preview c.left.png >/dev/null 2>&1
[ "$(find "${CACHE}" -name '*.jpg' | wc -l | tr -d ' ')" = "2" ] || fail "preview: single images are shown as they are, never stitched"
say "cache: reused, redrawn when a half changes, never used for single images"

# --- Enter keeps the picker open ----------------------------------------------
grep -q 'enter:execute-silent(${gallery_q} bg set {1})+transform-header(.*)+reload(${self_q} --list)"' "${PICKER}" \
  || fail "enter: must apply with bg set, update the header, then reload the list instead of closing fzf"
# fzf 0.74 with --id-nth plus --track drops every action after a reload and
# then ignores keys: the picker froze after the first Enter. Without them
# the cursor keeps its row across the reload (same order, same length).
if grep -qE -- '^[[:space:]]*--(id-nth|track)' "${PICKER}"; then
  fail "enter: --id-nth/--track freeze fzf after the reload"
fi
grep -q 'unbind(load)' "${PICKER}" || fail "enter: the start-up pos() must not fire again on reload"
bash -n "${PICKER}" || fail "syntax"
say "enter: applies, stays open, cursor kept"

say "all checks passed"
