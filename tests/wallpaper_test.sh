#!/usr/bin/env bash
#
# wallpaper_test.sh -- offline test of the wallpaper hook
# (tools/hooks/30-wallpaper.sh) and `gallery bg ...`, including LEFT/RIGHT
# pairs.
#
# Never touches the real desktop: HOME is a temp directory (so the wallpaper
# store, the config dir and the log are all fake), and osascript and killall
# are stubs on PATH that only log their calls.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GALLERY_BIN="${REPO_ROOT}/bin/gallery"
HOOK_SRC="${REPO_ROOT}/tools/hooks/30-wallpaper.sh"

say() { echo "[wallpaper_test] $*"; }
fail() { echo "[wallpaper_test] FAIL: $*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"

WORK="$(mktemp -d "$(dirname "${TMPDIR:-/tmp}/x")/gallery-wallpaper-test.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
H="${WORK}/home"
CFG="${H}/.config/gallery"
BG="${CFG}/themes/jade/backgrounds"
STORE="${H}/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
CALLS="${WORK}/calls.log"
STUBS="${WORK}/stubs"
mkdir -p "${BG}" "${CFG}/hooks/theme-set.d" "$(dirname "${STORE}")" "${STUBS}"
ln -sfn jade "${CFG}/themes/current"
cp "${HOOK_SRC}" "${CFG}/hooks/theme-set.d/30-wallpaper.sh"
chmod +x "${CFG}/hooks/theme-set.d/30-wallpaper.sh"

# osascript stub: logs its arguments (and stdin for the System Events path);
# the JavaScript form answers with the fake display count.
cat > "${STUBS}/osascript" <<STUB
#!/bin/sh
if [ "\$1" = "-l" ]; then
  shift 2; shift 2  # -l JavaScript -e <script>
  echo "jxa \$*" >> "${CALLS}"
  echo "\${FAKE_SCREENS:-2}"
else
  echo "applescript: \$(cat)" >> "${CALLS}"
fi
STUB
printf '#!/bin/sh\necho "killall $*" >> "%s"\n' "${CALLS}" > "${STUBS}/killall"
chmod +x "${STUBS}/osascript" "${STUBS}/killall"

gallery() { PATH="${STUBS}:${PATH}" HOME="${H}" "${GALLERY_BIN}" "$@"; }
hook() { PATH="${STUBS}:${PATH}" HOME="${H}" "${CFG}/hooks/theme-set.d/30-wallpaper.sh" "$@"; }

touch "${BG}/a.png" "${BG}/b.left.png" "${BG}/b.right.jpg" "${BG}/c.left.png" "${BG}/d.png"

# --- list / current / next / prev / set ------------------------------------
LIST="$(gallery bg list jade)"
[ "${LIST}" = "a.png
b.left.png (+ right)
c.left.png
d.png" ] || fail "list: unexpected output: ${LIST}"
say "list: a pair is one entry; a lone .left is an ordinary image"

[ "$(gallery bg current jade)" = "a.png" ] || fail "current: expected the first image"
gallery bg next jade >/dev/null
[ "$(gallery bg current jade)" = "b.left.png" ] || fail "next from a single onto the pair"
gallery bg prev jade >/dev/null
gallery bg set b.right.jpg jade >/dev/null
grep -q '"jade": "b.left.png"' "${CFG}/state/backgrounds.json" || fail "set: the LEFT filename must be recorded"
[ "$(gallery bg current jade)" = "b.left.png" ] || fail "current after set of a right half"
gallery bg next jade >/dev/null
[ "$(gallery bg current jade)" = "c.left.png" ] || fail "next must step over the pair as a unit"
gallery bg prev jade >/dev/null
[ "$(gallery bg current jade)" = "b.left.png" ] || fail "prev back onto the pair"
gallery bg prev jade >/dev/null
[ "$(gallery bg current jade)" = "a.png" ] || fail "prev from the pair"
gallery bg set b jade >/dev/null
[ "$(gallery bg current jade)" = "b.left.png" ] || fail "set with the bare stem"
gallery bg set c.left.png jade >/dev/null
[ "$(gallery bg current jade)" = "c.left.png" ] || fail "set a lone half"
if gallery bg set c jade >/dev/null 2>&1; then fail "a bare stem must not match a lone half"; fi
say "set/next/prev: either half or the bare stem selects the pair, LEFT is recorded, steps are per pair"

gallery bg set c.left.png jade >/dev/null
: > "${CALLS}"
# --- hook: dry run ----------------------------------------------------------
OUT="$(GALLERY_WALLPAPER_DRY_RUN=1 hook jade b.right.jpg)"
echo "${OUT}" | grep -q "pair: LEFT ${BG}/b.left.png" || fail "dry run: LEFT missing: ${OUT}"
echo "${OUT}" | grep -q "pair: RIGHT ${BG}/b.right.jpg" || fail "dry run: RIGHT missing"
echo "${OUT}" | grep -q "setDesktopImageURLForScreenOptionsError" || fail "dry run: the JXA is not printed"
OUT="$(GALLERY_WALLPAPER_DRY_RUN=1 hook jade c.left.png)"
echo "${OUT}" | grep -q "would apply ${BG}/c.left.png" || fail "dry run: a lone half is a single image"
echo "${OUT}" | grep -q 'set picture of every desktop' || fail "dry run: single keeps System Events"
OUT="$(GALLERY_WALLPAPER_DRY_RUN=1 hook jade)"   # recorded choice: c.left.png (lone)
echo "${OUT}" | grep -q "would apply ${BG}/c.left.png" || fail "dry run: recorded choice"
gallery bg set b.left.png jade >/dev/null
: > "${CALLS}"
OUT="$(GALLERY_WALLPAPER_DRY_RUN=1 hook jade)"
echo "${OUT}" | grep -q "pair: LEFT ${BG}/b.left.png" || fail "dry run: the recorded pair is applied"
[ ! -s "${CALLS}" ] || fail "dry run called a stub: $(cat "${CALLS}")"
say "hook dry run: pair assignment and JXA printed; lone halves and singles keep the old path"

# --- hook: pair apply and Space sync against a synthetic store --------------
store() {  # store <left-url> <right-url> <old-url>
  python3 - "${STORE}" "$1" "$2" "$3" <<'PY'
import plistlib, sys
def conf(url):
    return plistlib.dumps({"url": {"relative": url}})
def desk(url):
    return {"Desktop": {"Content": {"Choices": [{"Configuration": conf(url)}]}}, "Type": "idle"}
left, right, old = sys.argv[2:5]
data = {
  "Displays": {"D1": desk(left), "D2": desk(right), "STALE": desk(old)},
  "Spaces": {
    "": {"Default": desk(left), "Displays": {"D1": desk(left)}},
    "S2": {"Default": desk(old), "Displays": {"D1": desk(old), "D2": desk(old)}},
    "S3": {"Default": desk(old), "Displays": {"D2": desk(old)}},
    "S4": {"Default": desk(left), "Displays": {"D1": desk(left), "D2": desk(right)}},
  },
}
with open(sys.argv[1], "wb") as fh:
    plistlib.dump(data, fh, fmt=plistlib.FMT_BINARY)
PY
}
show() {  # show <space> <display|Default>
  python3 - "${STORE}" "$1" "$2" <<'PY'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))["Spaces"][sys.argv[2]]
e = d["Default"] if sys.argv[3] == "Default" else d["Displays"][sys.argv[3]]
print(plistlib.loads(e["Desktop"]["Content"]["Choices"][0]["Configuration"])["url"]["relative"])
PY
}
LURL="file://${BG}/b.left.png"
RURL="file://${BG}/b.right.jpg"
store "${LURL}" "${RURL}" "file:///old.png"
: > "${CALLS}"
hook jade >/dev/null || fail "pair apply failed"
grep -q "^jxa ${BG}/b.left.png ${BG}/b.right.jpg\$" "${CALLS}" || fail "JXA not called with LEFT then RIGHT: $(cat "${CALLS}")"
grep -q "applescript" "${CALLS}" && fail "a pair must not use System Events"
grep -q "killall WallpaperAgent" "${CALLS}" || fail "WallpaperAgent was not restarted after a sync: $(tail -3 "${H}/Library/Logs/gallery.log")"
[ "$(show S2 D1)" = "${LURL}" ] || fail "S2 D1"
[ "$(show S2 D2)" = "${RURL}" ] || fail "S2 D2"
[ "$(show S2 Default)" = "${LURL}" ] || fail "S2 Default is LEFT"
[ "$(show S3 D2)" = "${RURL}" ] || fail "S3 D2"
[ "$(show S4 D2)" = "${RURL}" ] || fail "S4 untouched"
grep -q "applied pair" "${H}/Library/Logs/gallery.log" || fail "pair apply not logged"
say "pair apply: JXA gets LEFT then RIGHT; every Space's displays follow by UUID, Default gets LEFT"

# A single display gets LEFT only, and the sync needs only LEFT.
store "${LURL}" "file:///never.png" "file:///old.png"
: > "${CALLS}"
FAKE_SCREENS=1 hook jade >/dev/null || fail "single-display pair apply failed"
[ "$(show S2 Default)" = "${LURL}" ] || fail "single display: S2 Default"
say "pair on one display: only LEFT is waited for"

# The store never shows the pair: the sync is skipped, the hook still succeeds.
store "file:///other.png" "file:///other2.png" "file:///old.png"
: > "${CALLS}"
hook jade >/dev/null || fail "hook must succeed when the sync is skipped"
grep -q "Space sync skipped" "${H}/Library/Logs/gallery.log" || fail "skipped sync not logged"
grep -q "killall" "${CALLS}" && fail "WallpaperAgent restarted though nothing was written"
[ "$(show S2 D1)" = "file:///old.png" ] || fail "store must be untouched when the pair never shows"
say "pair sync: skipped and logged when the store never shows the pair"

# --- singles keep the old sync ----------------------------------------------
gallery bg set a.png jade >/dev/null 2>&1 || true   # recorded; may try to apply via the stubs
: > "${CALLS}"
python3 - "${STORE}" "file://${BG}/a.png" <<'PY'
import plistlib, sys
def desk(url):
    return {"Desktop": {"Content": {"Choices": [{"Configuration": plistlib.dumps({"url": {"relative": url}})}]}}}
new, old = sys.argv[2], "file:///old.png"
data = {"Spaces": {"": {"Default": desk(new)}, "S2": {"Default": desk(old), "Displays": {"D1": desk(old)}}}}
with open(sys.argv[1], "wb") as fh:
    plistlib.dump(data, fh, fmt=plistlib.FMT_BINARY)
PY
hook jade a.png >/dev/null || fail "single apply failed"
grep -q "applescript: tell application \"System Events\"" "${CALLS}" || fail "single image must use System Events"
grep -q "^jxa" "${CALLS}" && fail "single image must not use JXA"
[ "$(show S2 D1)" = "file://${BG}/a.png" ] || fail "single sync: S2 display"
say "single image: System Events and the primary-copy sync, unchanged"

say "OK"
