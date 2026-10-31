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

# plan_placement: every open window back on its saved Desktop, terminals too.
def psaved(wid, app, title, space, display=1, minimized=False):
    return {"id": wid, "app": app, "title": title, "space_index": space, "display": display,
            "is_minimized": minimized}
def pspaces(n, displays=1):
    return [{"index": i, "display": 1 if i <= n // displays else 2} for i in range(1, n + 1)]
s = {"spaces": {"x": {"windows": [
    psaved(5, "iTerm2", "claude", 3), psaved(6, "iTerm2", "claude", 4), psaved(7, "iTerm2", "claude", 4),
    psaved(8, "Safari", "Docs", 2), psaved(9, "Safari", "Mail", 5), psaved(10, "Notes", "N", 1),
    psaved(11, "Maps", "M", 12, display=2)]}}}
now = [live(40, "iTerm2", "-zsh"), live(41, "iTerm2", "-zsh"), live(42, "iTerm2", "-zsh"),
       live(50, "Safari", "Mail"), live(51, "Safari", "Docs"), live(60, "Notes", "N"),
       live(70, "Maps", "M"), live(80, "Music", "X")]
moves, notes = yl.plan_placement(s, now, pspaces(6))
got = {wid: target for wid, _, target in moves}
check(got == {40: 3, 41: 4, 42: 4, 50: 5, 51: 2}, f"placement: got {got}")
check(60 not in got, "a window already on its Desktop is not moved")
check(80 not in got, "an app absent from the save is left alone")
check(any("Maps#70" in n for n in notes), "a Desktop that is not here now should be noted, not used")
# Fewer windows open than saved: the earliest saved ones are used.
moves, _ = yl.plan_placement(s, [live(40, "iTerm2", "-zsh")], pspaces(6))
check(moves == [(40, "iTerm2", 3)], f"one terminal goes to the first saved one's Desktop, got {moves}")
# Minimized windows are never moved, nor saved minimized ones used.
moves, _ = yl.plan_placement({"spaces": {"x": {"windows": [psaved(1, "Notes", "N", 4, minimized=True)]}}},
                             [live(2, "Notes", "N")], pspaces(6))
check(moves == [], "a saved minimized window is not a placement")
moves, _ = yl.plan_placement({"spaces": {"x": {"windows": [psaved(1, "Notes", "N", 4)]}}},
                             [dict(live(2, "Notes", "N"), **{"is-minimized": True})], pspaces(6))
check(moves == [], "a minimized open window is not moved")

# Desktops by monitor: a snapshot's Desktops are renumbered for the
# displays connected now (uuid + place on that display).
def tsaved(index, uuid, pos, display, apps):
    return {"space_index": index, "display": display, "display_uuid": uuid, "display_space": pos,
            "windows": [{"id": 100 + index * 10 + i, "app": a, "title": a, "space_index": index,
                         "display": display, "display_uuid": uuid, "display_space": pos}
                        for i, a in enumerate(apps)]}
snap = {"spaces": {"2": tsaved(2, "AAA", 2, 1, ["Mail"]), "3": tsaved(3, "AAA", 3, 1, ["Notes"]),
                   "5": tsaved(5, "BBB", 2, 2, ["Safari"]), "1": tsaved(1, "AAA", 1, 1, [])}}
same = [{"uuid": "AAA", "index": 1, "spaces": [1, 2, 3]}, {"uuid": "BBB", "index": 2, "spaces": [4, 5]}]
moved, notes = yl.translate_snapshot(snap, same)
check(sorted(moved["spaces"]) == ["1", "2", "3", "5"] and notes == [], "translate: unchanged displays: %r" % notes)
check(yl.desktops_unchanged(snap, same), "translate: unchanged displays not reported as unchanged")
# A Desktop removed on the main display: the second display's Desktops shift down.
fewer = [{"uuid": "AAA", "index": 1, "spaces": [1, 2]}, {"uuid": "BBB", "index": 2, "spaces": [3, 4]}]
moved, notes = yl.translate_snapshot(snap, fewer)
check(moved["spaces"]["4"]["windows"][0]["app"] == "Safari" and moved["spaces"]["4"]["windows"][0]["space_index"] == 4,
      "translate: Safari should be on Desktop 4 now: %r" % moved["spaces"].keys())
check("3" not in moved["spaces"] or moved["spaces"]["3"]["windows"] == [], "translate: a vanished Desktop kept its windows")
check(any("has no Desktop 3" in n for n in notes), "translate: the vanished Desktop was not noted: %r" % notes)
check(not yl.desktops_unchanged(snap, fewer), "translate: a renumbering was reported as unchanged")
# The displays swapped order: each Desktop follows its monitor.
swapped = [{"uuid": "BBB", "index": 1, "spaces": [1, 2]}, {"uuid": "AAA", "index": 2, "spaces": [3, 4, 5]}]
moved, _ = yl.translate_snapshot(snap, swapped)
check(moved["spaces"]["2"]["windows"][0]["app"] == "Safari" and moved["spaces"]["2"]["display"] == 1,
      "translate: Safari did not follow its monitor")
check(moved["spaces"]["4"]["windows"][0]["app"] == "Mail" and moved["spaces"]["5"]["windows"][0]["app"] == "Notes",
      "translate: the main monitor's Desktops did not follow it")
# A monitor not connected: its Desktops are dropped, noted.
alone = [{"uuid": "AAA", "index": 1, "spaces": [1, 2, 3]}]
moved, notes = yl.translate_snapshot(snap, alone)
check("5" not in moved["spaces"] and any("not connected" in n for n in notes), "translate: absent monitor: %r" % notes)
# Placement follows the translation.
moves, _ = yl.plan_placement(yl.translate_snapshot(snap, swapped)[0],
                             [live(7, "Safari", "Safari"), live(8, "Mail", "Mail")],
                             [{"index": i, "display": 1 if i < 3 else 2} for i in range(1, 6)])
check(sorted((a, t) for _, a, t in moves) == [("Mail", 4), ("Safari", 2)], "translate: placement %r" % moves)
# A snapshot from before (no uuids) is used as saved.
old = {"spaces": {"5": {"space_index": 5, "display": 2, "windows": [{"id": 1, "app": "X"}]}}}
check(yl.translate_snapshot(old, fewer) == (old, []), "translate: an old snapshot was changed")
check(yl.desktop_positions(same) == {1: ("AAA", 1), 2: ("AAA", 2), 3: ("AAA", 3), 4: ("BBB", 1), 5: ("BBB", 2)},
      "desktop_positions")

# A Safari web app yabai names "Web App" gets the name macOS gives it (a
# stand-in lsappinfo on PATH: pid 31 is Outlook, pid 32 unknown).
import os, tempfile
stub = tempfile.mkdtemp()
with open(os.path.join(stub, "lsappinfo"), "w") as fh:
    fh.write('#!/bin/sh\ncase "$*" in\n  "find pid=31") echo ASN:0x1 ;;\n'
             '  "info -only name ASN:0x1") echo \'"Outlook" ASN:0x1:\' ;;\nesac\n')
os.chmod(os.path.join(stub, "lsappinfo"), 0o755)
os.environ["PATH"] = stub + ":" + os.environ["PATH"]
named = yl.web_app_names([{"id": 1, "pid": 31, "app": "Web App"}, {"id": 2, "pid": 32, "app": "Web App"},
                          {"id": 3, "pid": 31, "app": "Mail"}])
check([w["app"] for w in named] == ["Outlook", "Web App", "Mail"], "web app names: %r" % named)

# restore_space on a Desktop not in view, against a stand-in yabai that does
# what the real one did after a restart: un-floating a window there tiles it
# into the Desktop in view (7), a moment later rather than at once. Saved: Observatory left, Telegram over Signal
# right, on Desktop 10.
class FakeYabai:
    def __init__(self, grow_after):
        self.visible = 7
        self.grow_after = grow_after   # anchor queries before it fills the Desktop
        self.anchor_queries = 0
        self.wins = {1: {"space": 10, "floating": False}, 2: {"space": 10, "floating": False},
                     3: {"space": 10, "floating": False}}
    def yabai(self, *args, check=True):
        if args[0] == "window" and args[2:4] == ("--toggle", "float"):
            w = self.wins[int(args[1])]
            w["floating"] = not w["floating"]
            if not w["floating"] and w["space"] != self.visible:
                w["wander_in"] = 2     # moves to the Desktop in view a moment later
        elif args[0] == "window" and args[2] == "--space":
            self.wins[int(args[1])]["space"] = int(args[3])
        return ""
    def query(self, wid):
        w = self.wins[wid]
        if "wander_in" in w:
            w["wander_in"] -= 1
            if w["wander_in"] <= 0:
                del w["wander_in"]
                w["space"] = self.visible
        frame = {"x": 2568, "y": 39, "w": 1268, "h": 1393}
        if wid == 1:
            self.anchor_queries += 1
            if self.anchor_queries > self.grow_after:
                frame = {"x": 2568, "y": 39, "w": 2544, "h": 1393}
        return {"id": wid, "space": w["space"], "is-floating": w["floating"], "frame": frame}

def restore_with(fake):
    yl.yabai = fake.yabai
    yl.query_window_by_id = fake.query
    built = []
    yl._build = lambda *a: built.append(a)
    yl._clear_insert = lambda *a: None
    yl.ANCHOR_SETTLE_S = 0.5
    yl.RELEASE_SETTLE_S = 1.0
    sp = {"space_index": 10, "windows": [
        dict(saved(1, "Safari", "The Observatory", 2568, 39, 1268, 1393), space_index=10),
        dict(saved(2, "Telegram", "Telegram", 3844, 39, 1268, 836), space_index=10),
        dict(saved(3, "Signal", "Signal", 3844, 884, 1268, 548), space_index=10)]}
    live_by_id = {i: dict(live(i, "x", "x", space=10), id=i) for i in (1, 2, 3)}
    summary = []
    yl.restore_space(sp, live_by_id, 8, 10, summary)
    for _ in range(3):                 # let any pending move land
        for i in (2, 3):
            fake.query(i)
    return built, summary

# The anchor never fills the Desktop (a window wedged in the tree): the Space
# is given up, and every window it floated stays on Desktop 10.
fake = FakeYabai(grow_after=10**9)
built, summary = restore_with(fake)
check(not built, "restore: a blocked Desktop must not be rebuilt")
check(any("immovable" in s for s in summary), "restore: the blocked Desktop should be noted: %r" % summary)
check({w["space"] for w in fake.wins.values()} == {10},
      "restore: given up, windows must stay on their Desktop: %r" % fake.wins)
check(not any(w["floating"] for w in fake.wins.values()), "restore: given up, nothing may be left floating")

# The anchor fills the Desktop late (a Desktop not in view): not taken for a
# wedged window, the Desktop is rebuilt.
fake = FakeYabai(grow_after=2)
built, summary = restore_with(fake)
check(len(built) == 1, "restore: an anchor that fills the Desktop late must still be rebuilt: %r" % summary)

# return_strays: a window yabai moved during the restore goes back.
fake = FakeYabai(grow_after=0)
fake.wins[2]["space"] = 7
yl.yabai = fake.yabai
n = yl.return_strays({1: 10, 2: 10, 3: 10}, [{"id": i, "space": w["space"]} for i, w in fake.wins.items()])
check(n == 1 and fake.wins[2]["space"] == 10, "return_strays: Telegram should be back on 10: %r" % fake.wins)

# cmd_restore rebuilds only the Desktops in view (11 here); 10 is left alone.
import json as _json, types
snapf = os.path.join(tempfile.mkdtemp(), "layout.json")
with open(snapf, "w") as fh:
    _json.dump({"version": 1, "config": {"window_gap": 8}, "focused_window": None, "spaces": {
        str(i): {"space_index": i, "windows": [saved(i, "App%d" % i, "T", 8, 40, 850, 970)]}
        for i in (10, 11)}}, fh)
touched = []
yl.restore_space = lambda sp, *a: touched.append(sp["space_index"])
yl.wait_for_yabai = lambda *a: True
yl.query_windows = lambda: []
yl.query_spaces = lambda: [{"index": 10, "is-visible": False}, {"index": 11, "is-visible": True}]
yl.RELEASE_SETTLE_S = 0
yl.yabai = lambda *a, **k: ""
yl.cmd_restore(types.SimpleNamespace(file=snapf, remap=False, wait=1))
check(touched == [11], "restore: only the Desktop in view may be rebuilt, got %r" % touched)

if failures:
    for f in failures:
        print("[layout_test]   " + f)
    sys.exit(1)
PY
say "Desktops by monitor: renumbered with the displays, follow a swapped monitor, absent ones left"
say "place: windows matched by app+title then creation order; absent Desktops, minimized and unknown apps left"
say "restore: only Desktops in view; a Desktop given up keeps its windows; a late anchor is waited for"
say "remap: same-app windows matched in order, app+title exact, mismatched Spaces left alone, floats skipped; in_shape"
say "PASS layout_test.sh"
