#!/usr/bin/env bash
#
# gate.sh -- Phase 1 "focus gate" test harness for The Gallery.
#
# Usage:
#   tests/gate.sh cycles [N]                   -- N open/close cycles (default 50)
#   tests/gate.sh two                           -- open gallery.hello + gallery.hello2 together
#   tests/gate.sh variant <style-list> <focus>  -- rewrite gallery.hello's panel style/focus and reinstall
#   tests/gate.sh matrix                        -- print the manual test matrix checklist
#
# Every hs IPC call uses the hs tool's graceful -t timeout (never coreutils timeout,
# wedges this script. Every step prints what it is doing.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GALLERY_BIN="${HOME}/bin/gallery"
HS_TIMEOUT=10

say() {
  echo "[gate] $*"
}

hs_eval() {
  # Runs a Lua expression through `hs -c`, capped at HS_TIMEOUT seconds.
  # On a freshly (re)launched Hammerspoon, the first use of any given
  # extension in that runtime prints a "-- Loading extension: X" banner to
  # stdout ahead of the actual return value, so only the LAST line is kept.
  hs -t "${HS_TIMEOUT}" -q -c "$1" | grep -v "^-- " | tail -n 1
}

wait_for_hs_ready() {
  # install.sh can fall back to a full quit+relaunch of Hammerspoon.app,
  # which takes a few seconds to come back up and load Gallery. Poll
  # instead of racing it with the next IPC call.
  say "waiting for Hammerspoon to answer IPC calls"
  local waited=0
  local max_wait=30
  while [ "${waited}" -lt "${max_wait}" ]; do
    if hs -t 3 -q -c "return spoon.Gallery and 'ready' or 'no-gallery'" 2>/dev/null | grep -q ready; then
      say "Hammerspoon ready after ${waited}s"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  echo "[gate] Hammerspoon did not become ready within ${max_wait}s" >&2
  return 1
}

require_hs() {
  if ! command -v hs >/dev/null 2>&1; then
    echo "[gate] hs CLI not found on PATH" >&2
    exit 1
  fi
  if ! command -v "${GALLERY_BIN}" >/dev/null 2>&1 && [ ! -x "${GALLERY_BIN}" ]; then
    echo "[gate] installed CLI not found at ${GALLERY_BIN}; run ./install.sh first" >&2
    exit 1
  fi
}

count_hammerspoon_windows() {
  # Counts Hammerspoon's own on-screen windows (all webview panels plus any
  # console window), via hs.window.allWindows() filtered to the app named
  # "Hammerspoon".
  hs_eval 'local n=0; for _,w in ipairs(hs.window.allWindows()) do local ok,name = pcall(function() return w:application():name() end); if ok and name=="Hammerspoon" then n=n+1 end end; return n'
}

gallery_windows_count() {
  # Counts entries in spoon.Gallery.windows directly, independent of the
  # Hammerspoon-window count above.
  hs_eval 'local n=0; for _ in pairs(spoon.Gallery.windows) do n=n+1 end; return n'
}

# ---------------------------------------------------------------------------
# cycles [N]
# ---------------------------------------------------------------------------
cmd_cycles() {
  local n="${1:-50}"
  say "running ${n} open/close cycles of gallery.hello through ${GALLERY_BIN}"

  local before_windows
  before_windows="$(count_hammerspoon_windows)"
  say "Hammerspoon windows before: ${before_windows}"

  local times_file
  times_file="$(mktemp)"

  local i
  for i in $(seq 1 "${n}"); do
    local t0 t1 delta
    t0="$(python3 -c 'import time; print(f"{time.time():.6f}")')"
    "${GALLERY_BIN}" open gallery.hello >/dev/null
    t1="$(python3 -c 'import time; print(f"{time.time():.6f}")')"
    delta="$(python3 -c "print(f'{${t1} - ${t0}:.4f}')")"
    echo "${delta}" >> "${times_file}"
    "${GALLERY_BIN}" close gallery.hello >/dev/null
    if [ $((i % 10)) -eq 0 ] || [ "${i}" -eq "${n}" ]; then
      say "cycle ${i}/${n} done (last open: ${delta}s)"
    fi
  done

  local after_windows
  after_windows="$(count_hammerspoon_windows)"
  say "Hammerspoon windows after: ${after_windows}"

  local gallery_windows
  gallery_windows="$(gallery_windows_count)"
  say "spoon.Gallery.windows entries remaining: ${gallery_windows}"

  local min max median
  min="$(sort -n "${times_file}" | head -1)"
  max="$(sort -n "${times_file}" | tail -1)"
  median="$(sort -n "${times_file}" | awk '{a[NR]=$1} END {if (NR%2==1) print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2}')"

  say "open timings over ${n} cycles: min=${min}s median=${median}s max=${max}s"

  local pass=1
  if [ "${gallery_windows}" != "0" ]; then
    say "FAIL: spoon.Gallery.windows is not empty (${gallery_windows} entries)"
    pass=0
  fi
  if [ "${before_windows}" != "${after_windows}" ]; then
    say "FAIL: stray Hammerspoon windows remain (before=${before_windows} after=${after_windows})"
    pass=0
  fi

  rm -f "${times_file}"

  if [ "${pass}" -eq 1 ]; then
    echo "PASS"
  else
    echo "FAIL"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# two
# ---------------------------------------------------------------------------
ensure_gallery_hello2() {
  local dest="${REPO_ROOT}/plugins/gallery.hello2"
  if [ -d "${dest}" ]; then
    say "plugins/gallery.hello2 already exists, leaving it as-is"
    return 0
  fi

  say "creating plugins/gallery.hello2 as a copy of gallery.hello"
  mkdir -p "${dest}"
  cp "${REPO_ROOT}/plugins/gallery.hello/index.html" "${dest}/index.html"
  cp "${REPO_ROOT}/plugins/gallery.hello/manifest.json" "${dest}/manifest.json"

  say "rewriting gallery.hello2/manifest.json (id, name, offset window size)"
  python3 - "${dest}/manifest.json" << 'PYEOF'
import json
import sys

path = sys.argv[1]
with open(path) as f:
    manifest = json.load(f)

manifest["id"] = "gallery.hello2"
manifest["name"] = "Hello Two"
manifest.setdefault("gallery", {}).setdefault("panel", {})
manifest["gallery"]["panel"]["width"] = 480
manifest["gallery"]["panel"]["height"] = 280

with open(path, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PYEOF

  say "recolouring gallery.hello2/index.html accent colour (amber -> blue)"
  # gallery.hello's accent is #d8a656 (amber); give the second panel a
  # visually distinct accent (#56a6d8, blue) so the two are easy to tell
  # apart at a glance.
  sed -i '' \
    -e 's/#d8a656/#56a6d8/g' \
    -e 's/#e8b968/#68b9e8/g' \
    -e 's/rgba(216, 166, 86,/rgba(86, 166, 216,/g' \
    "${dest}/index.html"
}

cmd_two() {
  ensure_gallery_hello2

  say "running ./install.sh to deploy gallery.hello2"
  (cd "${REPO_ROOT}" && ./install.sh)
  wait_for_hs_ready

  say "opening gallery.hello"
  "${GALLERY_BIN}" open gallery.hello
  say "opening gallery.hello2"
  "${GALLERY_BIN}" open gallery.hello2

  sleep 1

  local hs_windows gallery_windows
  hs_windows="$(count_hammerspoon_windows)"
  gallery_windows="$(gallery_windows_count)"
  say "Hammerspoon windows with both open: ${hs_windows}"
  say "spoon.Gallery.windows entries with both open: ${gallery_windows}"

  say "closing gallery.hello"
  "${GALLERY_BIN}" close gallery.hello
  say "closing gallery.hello2"
  "${GALLERY_BIN}" close gallery.hello2

  local hs_windows_after gallery_windows_after
  hs_windows_after="$(count_hammerspoon_windows)"
  gallery_windows_after="$(gallery_windows_count)"
  say "Hammerspoon windows after closing both: ${hs_windows_after}"
  say "spoon.Gallery.windows entries after closing both: ${gallery_windows_after}"
}

# ---------------------------------------------------------------------------
# variant <style-list> <focus-mode>
# ---------------------------------------------------------------------------
cmd_variant() {
  local style_list="${1:?usage: gate.sh variant <style-list> <focus-mode>}"
  local focus_mode="${2:?usage: gate.sh variant <style-list> <focus-mode>}"
  local manifest_path="${REPO_ROOT}/plugins/gallery.hello/manifest.json"

  say "rewriting ${manifest_path}: style=[${style_list}] focus=${focus_mode}"
  python3 - "${manifest_path}" "${style_list}" "${focus_mode}" << 'PYEOF'
import json
import sys

path, style_csv, focus_mode = sys.argv[1], sys.argv[2], sys.argv[3]
styles = [s for s in style_csv.split(",") if s]

with open(path) as f:
    manifest = json.load(f)

manifest.setdefault("gallery", {}).setdefault("panel", {})
manifest["gallery"]["panel"]["style"] = styles
manifest["gallery"]["panel"]["focus"] = focus_mode

with open(path, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PYEOF

  say "running ./install.sh to deploy the variant"
  (cd "${REPO_ROOT}" && ./install.sh)
  wait_for_hs_ready

  say "applied variant: style=[${style_list}] focus=${focus_mode}"
  say "now press left Option+0 (or: ${GALLERY_BIN} open gallery.hello) and judge:"
  say "  - does it grab keyboard focus immediately?"
  say "  - does typing land in the input field?"
  say "  - does Escape close it and return focus to what you were using?"
}

# ---------------------------------------------------------------------------
# matrix
# ---------------------------------------------------------------------------
cmd_matrix() {
  cat << 'EOF'
Gallery Phase 1 focus-gate manual test matrix
==============================================
Fill in PASS/FAIL and notes for each row after exercising the current
style/focus variant (see `gate.sh variant`).

[ ] Focus on first keypress
    - Open the panel, immediately type without clicking it first.
    - PASS if the first keystroke lands in the input field.
    notes:

[ ] Typed characters reach input, Escape closes with focus returning
    - Type a few characters, confirm they appear in the field.
    - Press Escape; panel should close and focus should return to
      whatever application had focus before the panel opened.
    notes:

[ ] Works on both displays, follows cursor
    - Move the mouse to the second display, open the panel there.
    - PASS if it appears centred on the display under the cursor.
    notes:

[ ] Survives a Space (virtual desktop) switch
    - Open the panel, switch to another Space and back.
    - PASS if the panel is still present and still focusable.
    notes:

[ ] yabai neither tiles nor resizes the panel
    - With yabai running, open the panel.
    - PASS if yabai leaves its size/position alone (no tiling, no resize).
    notes:

[ ] A second panel does not steal focus from the first
    - Open gallery.hello, then open gallery.hello2 (see `gate.sh two`).
    - PASS if opening the second panel does not yank focus away from
      the first while the first is still meant to be active, and if
      each panel's own focus behavior is otherwise as expected.
    notes:
EOF
}

# ---------------------------------------------------------------------------
main() {
  require_hs

  local subcommand="${1:-}"
  case "${subcommand}" in
    cycles)
      shift || true
      cmd_cycles "${1:-50}"
      ;;
    two)
      cmd_two
      ;;
    variant)
      shift || true
      cmd_variant "${1:-}" "${2:-}"
      ;;
    matrix)
      cmd_matrix
      ;;
    *)
      echo "usage: gate.sh cycles [N] | two | variant <style-list> <focus-mode> | matrix" >&2
      exit 1
      ;;
  esac
}

main "$@"
