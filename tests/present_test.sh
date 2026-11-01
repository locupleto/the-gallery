#!/usr/bin/env bash
#
# present_test.sh -- offline test of the presenter (`gallery present`, bin/gallery's
# "the presenter" section).
#
# Entirely offline: stand-in `yabai` and `osascript` scripts go first on PATH.
# The fake yabai answers queries from a fixture window list ($WINDOWS, a JSON
# file) and logs every command that would move a window; the fake osascript
# recognises the presenter's few AppleScripts by their text, answers the URL
# query from $URL, and logs the rest. HOME is a temp directory, so the real
# state/presenter.json is never read or written.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GALLERY_BIN="${REPO_ROOT}/bin/gallery"

say()  { echo "[present_test] $*"; }
fail() { echo "[present_test] FAIL: $*" >&2; exit 1; }

[ -x "${GALLERY_BIN}" ] || fail "${GALLERY_BIN} not found or not executable"
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gallery-present-test.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT
FAKE_BIN="${WORK_DIR}/bin"
FAKE_HOME="${WORK_DIR}/home"
mkdir -p "${FAKE_BIN}" "${FAKE_HOME}/.config/gallery/state"
STATE="${FAKE_HOME}/.config/gallery/state/presenter.json"
export LOG="${WORK_DIR}/log"

# yabai: queries from $WINDOWS; --spaces --space is Desktop $SPACE.
cat > "${FAKE_BIN}/yabai" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
pick() {
  python3 - "$WINDOWS" "$1" <<'PY'
import json, sys
ws = json.load(open(sys.argv[1])); key = sys.argv[2]
if key == "focus":
    w = next((w for w in ws if w.get("has-focus")), None)
else:
    w = next((w for w in ws if str(w["id"]) == key), None)
if w is None:
    sys.exit(1)
print(json.dumps(w))
PY
}
case "$*" in
  "-m query --windows")                 cat "$WINDOWS" ;;
  "-m query --windows --window")        pick focus ;;
  "-m query --windows --window recent") pick "${RECENT:-none}" ;;
  "-m query --windows --window "*)      pick "$5" ;;
  "-m query --spaces --space")          printf '{"index": %s}\n' "$SPACE" ;;
  "-m window "*)                        echo "yabai $*" >> "$LOG" ;;
  *) echo "fake yabai: unhandled: $*" >&2; exit 1 ;;
esac
FAKE

# osascript: tell the scripts apart by their text; argv follows the -e pairs.
# A presenter's tabs (the URL listing) come from $TABS, one per line.
cat > "${FAKE_BIN}/osascript" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
script=""; args=()
while [ $# -gt 0 ]; do
  if [ "$1" = "-e" ]; then script="${script}$2"$'\n'; shift 2; else args+=("$1"); shift; fi
done
case "${script}" in
  *"set out to out"*)    printf '%b' "${TABS:-}" ;;
  *"tab ((item 2"*)      echo "osascript select ${args[*]}" >> "$LOG" ;;
  *"make new document"*) echo "osascript new ${args[*]}" >> "$LOG"; echo "${NEW_ID}" ;;
  *"make new tab"*)      echo "osascript show ${args[*]}" >> "$LOG" ;;
  *"close window"*)      echo "osascript close ${args[*]}" >> "$LOG" ;;
  *"unique id of s"*)    [ "${args[0]}" = "${AGENT_SESSION:-}" ] && echo "${AGENT_WIN:-}" || echo "" ;;
  *"URL of current tab"*)
    [ "${URL_GONE:-0}" = 1 ] && exit 1
    echo "${URL:-}" ;;
  *) echo "fake osascript: unhandled script" >&2; exit 1 ;;
esac
FAKE
chmod +x "${FAKE_BIN}/yabai" "${FAKE_BIN}/osascript"

ART="https://claude.ai/artifact/AbC123"

# run <args...> -- the gallery with the fakes, a fresh log each time.
run() {
  : > "${LOG}"
  PATH="${FAKE_BIN}:${PATH}" HOME="${FAKE_HOME}" ITERM_SESSION_ID="${SESSION:-}" \
    GALLERY_PRESENTER_TRIES=2 GALLERY_PRESENTER_SLEEP=0 \
    GALLERY_PRESENTER_HINT_TRIES="${HINT_TRIES:-1}" \
    "${GALLERY_BIN}" "$@"
}
logged()     { grep -F -q -- "$1" "${LOG}" || { cat "${LOG}" >&2; fail "$2: expected log line: $1"; }; }
not_logged() { if grep -F -q -- "$1" "${LOG}"; then cat "${LOG}" >&2; fail "$2: unexpected log line: $1"; fi; }
registered() { python3 -c 'import json,sys; sys.exit(0 if int(sys.argv[2]) in json.load(open(sys.argv[1])).get("windows", []) else 1)' "${STATE}" "$1"; }
windows()    { WINDOWS="${WORK_DIR}/w-$1.json"; export WINDOWS; cat > "${WINDOWS}"; }

export SPACE=3 NEW_ID=0 URL=""

# --- 1. an artifact window on a Desktop with no presenter --------------------
# The page goes to a NEW window the presenter makes (never Safari's own, which
# may be a private one), floated, centred and focused; Safari's is closed.
windows one <<'EOF2'
[
  {"id": 50,  "app": "iTerm2", "space": 3, "is-floating": false, "has-focus": false},
  {"id": 899, "app": "Safari", "space": 3, "is-floating": false, "has-focus": true},
  {"id": 900, "app": "Safari", "space": 3, "is-floating": false, "has-focus": false}
]
EOF2
URL="${ART}" NEW_ID=900 run present _adopt 899
logged "osascript new ${ART}" "adopt"
logged "yabai -m window 900 --toggle float" "adopt"
logged "yabai -m window 900 --grid 8:8:1:1:6:6" "adopt"
logged "yabai -m window --focus 900" "adopt"
logged "osascript close 899" "adopt"
not_logged "--sub-layer" "adopt"
registered 900 || fail "adopt: 900 not recorded as a presenter"
registered 899 && fail "adopt: Safari's own window must not become the presenter"
say "ok: the first artifact gets a new floating presenter; Safari's window closes"

# --- 2. a second artifact window hands its page to the presenter and closes --
windows two <<'EOF2'
[
  {"id": 50,  "app": "iTerm2", "space": 3, "is-floating": false, "has-focus": false},
  {"id": 900, "app": "Safari", "space": 3, "is-floating": true,  "has-focus": false},
  {"id": 901, "app": "Safari", "space": 3, "is-floating": false, "has-focus": true}
]
EOF2
URL="${ART}2" run present _adopt 901
logged "osascript show 900 ${ART}2" "second"
logged "osascript close 901" "second"
logged "yabai -m window --focus 900" "second"
not_logged "osascript new" "second"
registered 901 && fail "second: 901 must not become a presenter"
say "ok: a second artifact becomes a tab in the presenter"

# --- 3. another Desktop gets its own presenter -------------------------------
windows three <<'EOF2'
[
  {"id": 50,  "app": "iTerm2", "space": 3, "is-floating": false, "has-focus": false},
  {"id": 900, "app": "Safari", "space": 3, "is-floating": true,  "has-focus": false},
  {"id": 902, "app": "Safari", "space": 5, "is-floating": false, "has-focus": true},
  {"id": 905, "app": "Safari", "space": 5, "is-floating": false, "has-focus": false}
]
EOF2
URL="${ART}3" NEW_ID=905 run present _adopt 902
logged "osascript new ${ART}3" "other Desktop"
logged "yabai -m window 905 --toggle float" "other Desktop"
not_logged "osascript show 900" "other Desktop"
registered 905 || fail "other Desktop: 905 not recorded"
say "ok: each Desktop has its own presenter"

# --- 4. pages that do not match, the presenter's own windows, off ------------
URL="https://example.com/" run present _adopt 901
[ ! -s "${LOG}" ] || { cat "${LOG}" >&2; fail "non-matching page touched windows"; }
URL="" run present _adopt 901
[ ! -s "${LOG}" ] || fail "blank window touched windows"
URL_GONE=1 run present _adopt 901
[ ! -s "${LOG}" ] || fail "vanished window touched windows"
URL="${ART}" run present _adopt 900
[ ! -s "${LOG}" ] || fail "a presenter re-adopted itself"
# The presenter could not be made (Safari refused): Safari's window is kept.
URL="${ART}4" NEW_ID="" SPACE=3 WINDOWS="${WORK_DIR}/w-one.json" run present _adopt 899
not_logged "osascript close" "no presenter made"
run present off >/dev/null
URL="${ART}" run present _adopt 901
[ ! -s "${LOG}" ] || fail "presenter off still acted"
run present on >/dev/null
say "ok: non-matching, blank, gone, own and switched-off windows are left alone"

# --- 5. a presenter the user tiled is theirs: the next page starts a new one --
windows five <<'EOF2'
[
  {"id": 50,  "app": "iTerm2", "space": 3, "is-floating": false, "has-focus": false},
  {"id": 900, "app": "Safari", "space": 3, "is-floating": false, "has-focus": false},
  {"id": 903, "app": "Safari", "space": 3, "is-floating": false, "has-focus": true},
  {"id": 906, "app": "Safari", "space": 3, "is-floating": false, "has-focus": false}
]
EOF2
URL="${ART}5" NEW_ID=906 run present _adopt 903
logged "osascript new ${ART}5" "tiled"
not_logged "osascript show 900" "tiled"
registered 900 && fail "tiled: 900 still recorded"
registered 906 || fail "tiled: 906 not recorded"
say "ok: a tiled presenter is released and a new one is made"

# --- 6. gallery present <url>: a new window when the Desktop has none --------
windows six <<'EOF'
[
  {"id": 50,  "app": "iTerm2", "space": 4, "is-floating": false, "has-focus": true},
  {"id": 910, "app": "Safari", "space": 4, "is-floating": false, "has-focus": false}
]
EOF
OUT="$(SPACE=4 NEW_ID=910 run present "${ART}6")"
logged "osascript new ${ART}6" "present"
logged "yabai -m window 910 --grid 8:8:1:1:6:6" "present"
logged "yabai -m window --focus 910" "present"
registered 910 || fail "present: 910 not recorded"
printf '%s' "${OUT}" | grep -q "window 910" || fail "present: output names no window: ${OUT}"
say "ok: gallery present opens a new presenter"

# --- 7. gallery present <url>: a tab when there is one; a file is a file URL --
windows seven <<'EOF'
[
  {"id": 50,  "app": "iTerm2", "space": 4, "is-floating": false, "has-focus": true},
  {"id": 910, "app": "Safari", "space": 4, "is-floating": true,  "has-focus": false}
]
EOF
echo '<p>x</p>' > "${WORK_DIR}/page one.html"
SPACE=4 run present "${WORK_DIR}/page one.html" >/dev/null
logged "osascript show 910 file://" "present file"
logged "page%20one.html" "present file"
not_logged "osascript new" "present file"
say "ok: gallery present adds a tab; files become file URLs"

# --- 8. status and custom patterns ------------------------------------------
python3 - "${STATE}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["match"] = [r"^https://example\.org/"]
json.dump(d, open(sys.argv[1], "w"))
PY
windows nine <<'EOF'
[
  {"id": 50,  "app": "iTerm2", "space": 2, "is-floating": false, "has-focus": false},
  {"id": 930, "app": "Safari", "space": 2, "is-floating": false, "has-focus": true},
  {"id": 931, "app": "Safari", "space": 2, "is-floating": false, "has-focus": false}
]
EOF
URL="${ART}" SPACE=2 run present _adopt 930
[ ! -s "${LOG}" ] || fail "custom patterns: the default one still matched"
URL="https://example.org/x" SPACE=2 NEW_ID=931 run present _adopt 930
logged "yabai -m window 931 --toggle float" "custom patterns"
OUT="$(run present status)"
printf '%s' "${OUT}" | grep -q "presenter: on" || fail "status: ${OUT}"
printf '%s' "${OUT}" | grep -q "example" || fail "status lacks patterns: ${OUT}"
say "ok: patterns come from state/presenter.json; status reports"

# --- 9. the agent's note: `gallery present hint`, from a hook's JSON ---------
HINTS="${FAKE_HOME}/.config/gallery/state/presenter-hints"
python3 - "${STATE}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d.pop("match", None)
json.dump(d, open(sys.argv[1], "w"))
PY
windows hint <<'EOF2'
[
  {"id": 50,  "app": "iTerm2", "space": 8,  "is-floating": false, "has-focus": false},
  {"id": 77,  "app": "Safari", "space": 16, "is-floating": false, "has-focus": false},
  {"id": 940, "app": "Safari", "space": 16, "is-floating": false, "has-focus": true},
  {"id": 941, "app": "Safari", "space": 16, "is-floating": false, "has-focus": false}
]
EOF2
HOOK_JSON='{"tool_name": "mcp__claude-artifacts__publish_files", "tool_response": [{"type": "text", "text": "{\"slug\": \"x\", \"url\": \"https://claude.ai/artifact/Hint9\", \"version\": \"1\"}"}]}'
printf '%s' "${HOOK_JSON}" | SESSION="w2t0p0:SESS-A" AGENT_SESSION="SESS-A" AGENT_WIN=50 run present hint
notes() { find "${HINTS}" -maxdepth 1 -name '*.json' | wc -l | tr -d ' '; }
[ "$(notes)" = 1 ] || fail "hint: expected one note in ${HINTS}"
grep -q '"window": 50' "${HINTS}"/*.json && grep -q '"space": 8' "${HINTS}"/*.json \
  || fail "hint: note lacks the agent window/Desktop: $(cat "${HINTS}"/*.json)"
printf '%s' '{"tool_response": "no url here"}' | SESSION="w2t0p0:SESS-A" AGENT_SESSION="SESS-A" AGENT_WIN=50 run present hint
printf '%s' "${HOOK_JSON}" | SESSION="" run present hint
[ "$(notes)" = 1 ] || fail "hint: a note without url or agent was filed"
say "ok: the hook's note records the agent's window and Desktop"

# --- 10. the page goes to the agent's Desktop; the user keeps their focus ----
# Agent on 8, user browsing on 16 (window 77; Safari's new window 940 took
# focus). Safari adds ?via=auto_preview: the note still matches.
URL="https://claude.ai/artifact/Hint9?via=auto_preview" SPACE=16 RECENT=77 NEW_ID=941 \
  HINT_TRIES=3 run present _adopt 940
logged "osascript new https://claude.ai/artifact/Hint9?via=auto_preview" "agent Desktop"
logged "yabai -m window 941 --space 8" "agent Desktop"
logged "yabai -m window --focus 77" "agent Desktop"
not_logged "yabai -m window --focus 941" "agent Desktop"
logged "osascript close 940" "agent Desktop"
[ "$(notes)" = 0 ] || fail "agent Desktop: the note was not used up"
say "ok: the presenter opens on the agent's Desktop; focus stays with the user"

# --- 11. a second page for that agent: a tab there, focus still the user's --
windows hint2 <<'EOF2'
[
  {"id": 50,  "app": "iTerm2", "space": 8,  "is-floating": false, "has-focus": false},
  {"id": 77,  "app": "Safari", "space": 16, "is-floating": false, "has-focus": false},
  {"id": 941, "app": "Safari", "space": 8,  "is-floating": true,  "has-focus": false},
  {"id": 942, "app": "Safari", "space": 16, "is-floating": false, "has-focus": true}
]
EOF2
printf '%s' '{"tool_response": {"url": "https://claude.ai/artifact/Hint11"}}' \
  | SESSION="w2t0p0:SESS-A" AGENT_SESSION="SESS-A" AGENT_WIN=50 run present hint
URL="https://claude.ai/artifact/Hint11" SPACE=16 RECENT=77 HINT_TRIES=3 run present _adopt 942
logged "osascript show 941 https://claude.ai/artifact/Hint11" "agent tab"
logged "yabai -m window --focus 77" "agent tab"
not_logged "--space" "agent tab"
logged "osascript close 942" "agent tab"
say "ok: further pages become tabs on the agent's Desktop"

# --- 12. gallery present from the agent's own shell: its Desktop -------------
windows hint3 <<'EOF2'
[
  {"id": 50,  "app": "iTerm2", "space": 8,  "is-floating": false, "has-focus": true},
  {"id": 941, "app": "Safari", "space": 8,  "is-floating": true,  "has-focus": false}
]
EOF2
OUT="$(SPACE=8 SESSION="w2t0p0:SESS-A" AGENT_SESSION="SESS-A" AGENT_WIN=50 run present "https://example.net/")"
logged "osascript show 941 https://example.net/" "present from agent"
logged "yabai -m window --focus 941" "present from agent"
printf '%s' "${OUT}" | grep -q "Desktop 8" || fail "present from agent: ${OUT}"
say "ok: gallery present uses the agent's Desktop and focuses when the user is there"

# --- 13. the pre-publish note: used at once when the window beats the url note
# Claude Code fired the post-publish hook 5 s after opening the page (live,
# 2026-11-01): the pending note from the pre-publish hook must carry it.
windows pre <<'EOF2'
[
  {"id": 50,  "app": "iTerm2", "space": 8,  "is-floating": false, "has-focus": false},
  {"id": 60,  "app": "iTerm2", "space": 5,  "is-floating": false, "has-focus": false},
  {"id": 77,  "app": "Safari", "space": 16, "is-floating": false, "has-focus": false},
  {"id": 950, "app": "Safari", "space": 16, "is-floating": false, "has-focus": true},
  {"id": 951, "app": "Safari", "space": 16, "is-floating": false, "has-focus": false}
]
EOF2
pre()  { printf '{"tool_use_id": "%s", "tool_input": {}}' "$1" | SESSION="w2t0p0:$2" AGENT_SESSION="$2" AGENT_WIN="$3" run present hint --before; }
post() { printf '{"tool_use_id": "%s", "tool_response": {"url": "%s"}}' "$1" "$4" | SESSION="w2t0p0:$2" AGENT_SESSION="$2" AGENT_WIN="$3" run present hint; }
pre toolu_A SESS-A 50
[ "$(ls "${HINTS}/pending" | wc -l | tr -d ' ')" = 1 ] || fail "pre: no pending note"
START=$(date +%s)
URL="https://claude.ai/artifact/Pre13?via=auto_preview" SPACE=16 RECENT=77 NEW_ID=951 HINT_TRIES=40 \
  GALLERY_PRESENTER_SLEEP=0.25 run present _adopt 950
[ $(( $(date +%s) - START )) -lt 5 ] || fail "pre: a single pending note must be used without waiting"
logged "yabai -m window 951 --space 8" "pre"
logged "yabai -m window --focus 77" "pre"
[ -z "$(ls "${HINTS}/pending")" ] || fail "pre: pending note not used up"
post toolu_A SESS-A 50 "https://claude.ai/artifact/Pre13"
say "ok: the pre-publish note places a page that arrives before the url note"

# --- 14. a republish opens no window: its pending note is withdrawn ----------
pre toolu_B SESS-A 50
post toolu_B SESS-A 50 "https://claude.ai/artifact/Pre13"
[ -z "$(ls "${HINTS}/pending")" ] || fail "republish: pending note left behind"
rm -f "${HINTS}"/*.json
windows click <<'EOF2'
[
  {"id": 77,  "app": "Safari", "space": 16, "is-floating": false, "has-focus": false},
  {"id": 960, "app": "Safari", "space": 16, "is-floating": false, "has-focus": true},
  {"id": 961, "app": "Safari", "space": 16, "is-floating": false, "has-focus": false}
]
EOF2
START=$(date +%s)
URL="https://claude.ai/artifact/Clicked" SPACE=16 NEW_ID=961 HINT_TRIES=40 GALLERY_PRESENTER_SLEEP=0.25 \
  run present _adopt 960
[ $(( $(date +%s) - START )) -lt 5 ] || fail "click: no notes must mean no wait"
not_logged "--space" "click"
logged "yabai -m window --focus 961" "click"
say "ok: a link the user clicked goes to the Desktop in view, without waiting"

# --- 15. two agents publishing at once: the url note tells them apart --------
windows two-agents <<'EOF2'
[
  {"id": 50,  "app": "iTerm2", "space": 8,  "is-floating": false, "has-focus": false},
  {"id": 60,  "app": "iTerm2", "space": 5,  "is-floating": false, "has-focus": false},
  {"id": 77,  "app": "Safari", "space": 16, "is-floating": false, "has-focus": false},
  {"id": 970, "app": "Safari", "space": 16, "is-floating": false, "has-focus": true},
  {"id": 971, "app": "Safari", "space": 16, "is-floating": false, "has-focus": false}
]
EOF2
pre toolu_C SESS-A 50
pre toolu_D SESS-B 60
post toolu_D SESS-B 60 "https://claude.ai/artifact/FromB"
URL="https://claude.ai/artifact/FromB" SPACE=16 RECENT=77 NEW_ID=971 run present _adopt 970
logged "yabai -m window 971 --space 5" "two agents"
[ "$(ls "${HINTS}/pending")" = "toolu_C.json" ] || fail "two agents: A's pending note must stay: $(ls "${HINTS}/pending")"
# No url note in time: the newest pending note is taken.
pre toolu_E SESS-B 60
URL="https://claude.ai/artifact/Unsure" SPACE=16 RECENT=77 NEW_ID=971 run present _adopt 970
logged "yabai -m window 971 --space 5" "two agents, no url note"
[ "$(ls "${HINTS}/pending")" = "toolu_C.json" ] || fail "two agents: the newest note was not the one used"
say "ok: with two agents publishing, url notes decide; else the newest pending note"

# --- 16. the post-publish note is filed from the pending one, before it goes -
# Live 2026-11-01: the post hook withdrew the pending note, then spent 2 s
# finding the agent's Desktop; the window arriving in between found neither.
rm -f "${HINTS}"/*.json "${HINTS}"/pending/*.json
pre toolu_F SESS-A 50
printf '{"tool_use_id": "toolu_F", "tool_response": {"url": "https://claude.ai/artifact/Race16"}}' \
  | SESSION="" run present hint
[ "$(notes)" = 1 ] || fail "race: no url note filed"
grep -q '"space": 8' "${HINTS}"/*.json || fail "race: url note lacks the pending note's Desktop"
[ -z "$(ls "${HINTS}/pending")" ] || fail "race: pending note not withdrawn"
say "ok: the url note takes the pending note's Desktop, then the pending note goes"

# --- 17. the page already open: matched without its #fragment, reloaded ----
# A uhf deck keeps its slide in the fragment, and the server prints its
# address without the trailing slash.
windows reload <<'EOF2'
[
  {"id": 50,  "app": "iTerm2", "space": 4, "is-floating": false, "has-focus": true},
  {"id": 910, "app": "Safari", "space": 4, "is-floating": true,  "has-focus": false}
]
EOF2
python3 - "${STATE}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["windows"] = [910]
json.dump(d, open(sys.argv[1], "w"))
PY
TABS='https://claude.ai/artifact/X\nhttp://localhost:3004/#slide-5\n'
TABS="${TABS}" SPACE=4 run present --reload "http://localhost:3004" >/dev/null
logged "osascript select 910 2 1" "reload"
not_logged "osascript show" "reload"
TABS="${TABS}" SPACE=4 run present "http://localhost:3004/" >/dev/null
logged "osascript select 910 2 0" "bring forward"
TABS="${TABS}" SPACE=4 run present "http://localhost:3004/?film=1" >/dev/null
logged "osascript show 910 http://localhost:3004/?film=1" "other query"
not_logged "osascript select" "other query"
run present --reload >/dev/null 2>&1 && fail "present --reload without a url must fail"
say "ok: an open page is found despite #slide-N and reloaded in place with --reload"

say "all presenter tests passed"
