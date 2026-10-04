#!/usr/bin/env bash
#
# layout_test.sh -- offline test of tiler/yabai-layout's after-login matching
# (remap_snapshot, in_shape): saved windows are matched to the windows open
# now by app and title, then app; a Space is kept only when every saved tiled
# window finds a match and nothing extra is tiled there. Pure Python, no yabai.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

say()  { echo "[layout_test] $*"; }
fail() { echo "[layout_test] FAIL: $*" >&2; exit 1; }

PYTHONDONTWRITEBYTECODE=1 python3 - "${REPO_ROOT}/tiler/yabai-layout" <<'PY' || fail "see above"
import importlib.machinery, importlib.util, sys

loader = importlib.machinery.SourceFileLoader("yabai_layout", sys.argv[1])
spec = importlib.util.spec_from_loader("yabai_layout", loader)
yl = importlib.util.module_from_spec(spec)
loader.exec_module(yl)

def saved(wid, app, title, x, y, w, h, floating=False):
    return {"id": wid, "app": app, "title": title, "frame": {"x": x, "y": y, "w": w, "h": h},
            "is_floating": floating, "is_minimized": False, "stack_index": 0,
            "split_type": "vertical", "space_index": 1}

def live(wid, app, title, space=1, floating=False):
    return {"id": wid, "app": app, "title": title, "space": space, "is-floating": floating,
            "is-minimized": False, "has-ax-reference": True, "stack-index": 0,
            "frame": {"x": 0, "y": 0, "w": 1, "h": 1}}

def snap(spaces):
    return {"version": 1, "config": {"window_gap": 8}, "focused_window": 5,
            "spaces": {str(i): {"space_index": i, "windows": ws} for i, ws in spaces.items()}}

failures = []
def check(cond, msg):
    if not cond:
        failures.append(msg)

# Three iTerm2 windows: full height left, two stacked right; ids all new.
s = snap({1: [saved(1, "iTerm2", "zsh", 8, 40, 850, 970),
              saved(2, "iTerm2", "claude", 866, 40, 850, 480),
              saved(3, "iTerm2", "agents", 866, 528, 850, 480)]})
out, notes = yl.remap_snapshot(s, [live(30, "iTerm2", "-zsh"), live(10, "iTerm2", "-zsh"), live(20, "iTerm2", "-zsh")])
ws = out["spaces"].get("1", {}).get("windows", [])
check(len(ws) == 3, "three same-app windows should all be matched")
check(sorted(w["id"] for w in ws) == [10, 20, 30], "saved ids should be replaced by the live ones")
check([w["frame"]["x"] for w in ws] == [8, 866, 866], "the saved frames (the shape) must be kept")
check(out["focused_window"] is None, "a saved focus id means nothing after a login")

# A unique app + title is matched exactly, the rest by app.
s = snap({1: [saved(1, "Notes", "Notes", 8, 40, 850, 970), saved(2, "Safari", "Docs", 866, 40, 850, 970)]})
out, _ = yl.remap_snapshot(s, [live(7, "Safari", "Docs"), live(8, "Notes", "Notes")])
ids = {w["app"]: w["id"] for w in out["spaces"]["1"]["windows"]}
check(ids == {"Notes": 8, "Safari": 7}, f"apps should map to their own windows, got {ids}")

# Counts differ, or another app is open: the Space is left alone.
s = snap({1: [saved(1, "Notes", "N", 8, 40, 850, 970), saved(2, "Maps", "M", 866, 40, 850, 970)]})
out, notes = yl.remap_snapshot(s, [live(9, "Notes", "N")])
check("1" not in out["spaces"], "a Space with a window missing must be left alone")
out, notes = yl.remap_snapshot(s, [live(9, "Notes", "N"), live(10, "Music", "X")])
check("1" not in out["spaces"], "a Space with another app open must be left alone")
check(any("not the saved apps" in n for n in notes), "the reason should be noted")

# Floating windows are neither matched nor counted; other Spaces are separate.
s = snap({1: [saved(1, "Notes", "N", 8, 40, 1700, 970), saved(2, "Calc", "C", 100, 100, 200, 300, floating=True)],
          2: [saved(3, "Maps", "M", 8, 40, 1700, 970)]})
out, _ = yl.remap_snapshot(s, [live(11, "Notes", "N"), live(12, "Calc", "C", floating=True), live(13, "Maps", "M", space=2)])
check([w["id"] for w in out["spaces"]["1"]["windows"]] == [11], "floats are not part of the shape")
check([w["id"] for w in out["spaces"]["2"]["windows"]] == [13], "each Space is matched on its own")

# in_shape: already on the saved frames (within eps), or not.
sp = {"windows": [saved(11, "Notes", "N", 8, 40, 850, 970)]}
on = {11: dict(live(11, "Notes", "N"), frame={"x": 9, "y": 41, "w": 849, "h": 969})}
off = {11: dict(live(11, "Notes", "N"), frame={"x": 866, "y": 40, "w": 850, "h": 970})}
check(yl.in_shape(sp, on, 10), "a Space within eps is already in shape")
check(not yl.in_shape(sp, off, 10), "a mirrored Space is not in shape")

if failures:
    for f in failures:
        print("[layout_test]   " + f)
    sys.exit(1)
PY
say "remap: same-app windows matched in order, app+title exact, mismatched Spaces left alone, floats skipped; in_shape"
say "PASS layout_test.sh"
