#!/usr/bin/env bash
#
# agent_test.sh -- offline test of bin/gallery-agent.
#
# Entirely offline: GALLERY_CONFIG_DIR points at a temp tree so the real
# ~/.config/gallery/state/agent.json is never touched, GALLERY_AGENT_DIR at a
# temp directory, and a stub PATH provides fake agent binaries. No agent is
# ever launched and no window is ever opened -- the pure verbs
# (status/list/set) are asserted through what `status` reports, and `open`
# through GALLERY_AGENT_PRINT_COMMAND, which prints the window command
# instead of handing it to iTerm.
#
set -euo pipefail
export GALLERY_NO_NOTIFY=1   # no real notifications from the missing-agent path

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
AGENT="${REPO_ROOT}/bin/gallery-agent"

say()  { echo "[agent_test] $*"; }
fail() { echo "[agent_test] FAIL: $*" >&2; exit 1; }

[ -x "${AGENT}" ] || fail "${AGENT} not found or not executable"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gallery-agent-test.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT
mkdir -p "${WORK_DIR}/config" "${WORK_DIR}/start" "${WORK_DIR}/bin"
for a in claude gemini; do printf '#!/bin/sh\nexit 0\n' > "${WORK_DIR}/bin/$a"; chmod +x "${WORK_DIR}/bin/$a"; done

run() { GALLERY_CONFIG_DIR="${WORK_DIR}/config" GALLERY_AGENT_DIR="${WORK_DIR}/start" \
        PATH="${WORK_DIR}/bin:/usr/bin:/bin" "${AGENT}" "$@"; }

# --- 1. the default is claude, with the bypass flag Omarchy uses ---------------
out="$(run status)"
grep -q '^agent:   claude' <<<"${out}" || fail "default should be claude: ${out}"
grep -q -- '--permission-mode bypassPermissions' <<<"${out}" \
  || fail "claude must launch with bypassPermissions: ${out}"
say "default is claude, launched unattended"

# --- 2. every supported agent has an unattended flag ---------------------------
# A new agent added without one would silently sit waiting for an approval it
# cannot show, which is the whole failure this launcher exists to avoid.
for a in claude gemini opencode codex copilot crush; do
  run set "$a" >/dev/null 2>&1 || fail "set $a was rejected"
  line="$(run status | sed -n 's/^command: //p')"
  [ "$(wc -w <<<"${line}")" -ge 2 ] || fail "$a has no unattended flag: '${line}'"
done
say "all six supported agents carry an unattended flag"

# --- 3. an unsupported agent is refused ----------------------------------------
if run set definitely-not-an-agent >/dev/null 2>&1; then
  fail "an unsupported agent was accepted"
fi
say "unsupported agent refused"

# --- 4. the start directory, and its fallback ----------------------------------
run set claude >/dev/null
grep -q "^starts:  ${WORK_DIR}/start$" <<<"$(run status)" || fail "start dir not honoured"
# The start directory may live on an external volume: if it is not mounted the
# agent must still launch, from $HOME, rather than failing outright.
missing="$(GALLERY_CONFIG_DIR="${WORK_DIR}/config" GALLERY_AGENT_DIR="${WORK_DIR}/gone" \
           PATH="${WORK_DIR}/bin:/usr/bin:/bin" "${AGENT}" status 2>/dev/null)"
grep -q "^starts:  ${HOME}$" <<<"${missing}" || fail "missing start dir should fall back to HOME: ${missing}"
say "start directory honoured, and falls back to HOME when unreachable"

# --- 5. the choice survives, and list marks it ---------------------------------
run set gemini >/dev/null
grep -q '^agent:   gemini' <<<"$(run status)" || fail "the default did not persist"
grep -q '^gemini .*(default)' <<<"$(run list)" || fail "list does not mark the default"
grep -q '^claude .*installed' <<<"$(run list)" || fail "list does not report installed agents"
say "default persists in state and list marks it"

# --- 6. the window command: a login shell, and nothing tui about it ------------
# The agent window is an ORDINARY tiled terminal, like Omarchy's (whose
# omarchy-launch-tui is only `xdg-terminal-exec -e <command>`), never a
# gallery-tui floating surface. Two ways that could regress, both pinned here:
# dropping the login shell, which loses the PATH that has `claude` on it
# because iTerm inherits launchd's; and reviving the "Gallery: " window title,
# which a yabai rule floats and un-manages.
run set claude >/dev/null
cmd="$(GALLERY_CONFIG_DIR="${WORK_DIR}/config" GALLERY_AGENT_DIR="${WORK_DIR}/start" \
       PATH="${WORK_DIR}/bin:/usr/bin:/bin" GALLERY_AGENT_PRINT_COMMAND=1 "${AGENT}" open)"
grep -q -- '/bin/zsh -l -c' <<<"${cmd}" || fail "window command is not a login shell: ${cmd}"
grep -qF -- "${AGENT}" <<<"${cmd}" || fail "window command does not re-run this script: ${cmd}"
if grep -q 'Gallery: ' <<<"${cmd}"; then
  fail "window carries a Gallery: title, which yabai floats: ${cmd}"
fi
say "window command is a login shell re-running launch, with no tui title"

# --- 7. a window macOS misplaced is moved to the Space in view ----------------
# Pressing the key inside the Space-switch animation can leave the new window
# on the Space being left. keep_on_current_space is driven here against a stub
# yabai -- the real function, lifted out of the script, so production code
# carries no extra test seam. The stub answers window and space queries from
# fixed values and records every move.
mkdir -p "${WORK_DIR}/yabai"
cat > "${WORK_DIR}/yabai/yabai" <<'STUB'
#!/bin/sh
# $STUB_WIN_SPACE empty = yabai never sees the window (AX-less).
case "$*" in
  "-m query --windows --window "*)
    [ -n "${STUB_WIN_SPACE}" ] || exit 1
    printf '{\n\t"id":%s,\n\t"space":%s,\n}\n' "$5" "${STUB_WIN_SPACE}" ;;
  "-m query --spaces --space") printf '{\n\t"id":9,\n\t"index":%s,\n}\n' "${STUB_VIEW_SPACE}" ;;
  *) echo "$*" >> "${STUB_LOG}" ;;
esac
STUB
chmod +x "${WORK_DIR}/yabai/yabai"
fn="$(sed -n '/^keep_on_current_space() {$/,/^}$/p' "${AGENT}")"
[ -n "${fn}" ] || fail "keep_on_current_space not found in ${AGENT}"
keep() {  # keep <window space or ""> <space in view>; prints the recorded moves
  : > "${WORK_DIR}/moves"
  STUB_WIN_SPACE="$1" STUB_VIEW_SPACE="$2" STUB_LOG="${WORK_DIR}/moves" \
    PATH="${WORK_DIR}/yabai:/usr/bin:/bin" bash -c "${fn}"'; keep_on_current_space 4242'
  cat "${WORK_DIR}/moves"
}
moves="$(keep 6 2)"
grep -qx -- '-m window 4242 --space 2' <<<"${moves}" || fail "misplaced window not moved to Space 2: ${moves}"
grep -qx -- '-m window 4242 --focus' <<<"${moves}" || fail "moved window not focused: ${moves}"
[ -z "$(keep 2 2)" ] || fail "a window already on the Space in view was moved"
[ -z "$(keep '' 2)" ] || fail "a window yabai never saw was acted on"
say "misplaced window moved to the Space in view; correct or unseen ones left alone"

# --- 8. a custom agent: any CLI, by command line --------------------------------
# `set <name> --command "<line>"` records the line next to the name; status and
# list show it, `inline` runs it (after the cd, through a shell, so single
# quotes in it work), and `set <built-in>` goes back to the built-in.
printf '#!/bin/sh\necho "custom-ran in $(pwd) with: $*"\n' > "${WORK_DIR}/bin/my-agent"
chmod +x "${WORK_DIR}/bin/my-agent"
run set claude >/dev/null
run set myagent --command "my-agent --auto-yes --name 'two words'" >/dev/null 2>&1 \
  || fail "set <name> --command was rejected"
out="$(run status)"
grep -q '^agent:   myagent$' <<<"${out}" || fail "custom agent should be the default and installed: ${out}"
grep -qF "command: my-agent --auto-yes --name 'two words' (custom)" <<<"${out}" || fail "status does not show the custom command: ${out}"
grep -qF '"command": "my-agent --auto-yes --name '"'two words'"'"' "${WORK_DIR}/config/state/agent.json" || fail "command not in agent.json"
grep -qF "myagent" <<<"$(run list)" && grep -q '^myagent .*installed (default, custom: my-agent' <<<"$(run list)" \
  || fail "list does not show the custom agent: $(run list)"
out="$(run inline)"
[ "${out}" = "custom-ran in $(cd "${WORK_DIR}/start" && pwd) with: --auto-yes --name two words" ] || fail "inline did not run the custom command in the start dir: ${out}"
cmd="$(GALLERY_CONFIG_DIR="${WORK_DIR}/config" GALLERY_AGENT_DIR="${WORK_DIR}/start" \
       PATH="${WORK_DIR}/bin:/usr/bin:/bin" GALLERY_AGENT_PRINT_COMMAND=1 "${AGENT}" open)"
grep -q -- '/bin/zsh -l -c' <<<"${cmd}" || fail "custom agent window is not a login shell: ${cmd}"
# the start directory keeps the command, and the other way round
run dir "${WORK_DIR}/start" >/dev/null
grep -q '"command"' "${WORK_DIR}/config/state/agent.json" || fail "dir dropped the custom command"
run set myagent --command "my-agent --second" >/dev/null 2>&1
grep -q "^starts:  ${WORK_DIR}/start$" <<<"$(run status)" || fail "set --command dropped the start dir"
run dir --clear >/dev/null
grep -q '"command"' "${WORK_DIR}/config/state/agent.json" || fail "dir --clear dropped the custom command"
# a program that is not on PATH is flagged, but still recorded
run set ghostagent --command "no-such-cli --go" >/dev/null 2>&1 || fail "a custom agent not on PATH should still be recorded"
grep -q 'NOT INSTALLED' <<<"$(run status)" || fail "status should flag a custom program that is not on PATH"
if run inline >/dev/null 2>&1; then fail "inline ran an agent that is not installed"; fi
# refused: no command for an unknown name, quotes, backslashes, newlines, junk
if run set ghostagent2 >/dev/null 2>&1; then fail "an unknown name without --command was accepted"; fi
for bad in 'my-agent "x"' 'my-agent \x' "$(printf 'my-agent\nrm')" "   " ""; do
  if run set bad --command "${bad}" >/dev/null 2>&1; then fail "a bad command was accepted: ${bad}"; fi
done
if run set "bad name" --command "my-agent" >/dev/null 2>&1; then fail "a name with a space was accepted"; fi
if run set myagent --command >/dev/null 2>&1; then fail "--command with no value was accepted"; fi
grep -q 'ghostagent' "${WORK_DIR}/config/state/agent.json" || fail "a refused set must leave the state file alone"
# a built-in without --command clears the custom command
run set gemini >/dev/null
if grep -q '"command"' "${WORK_DIR}/config/state/agent.json"; then fail "set <built-in> kept the custom command"; fi
grep -q -- '--yolo' <<<"$(run status)" || fail "gemini should be back on its own command"
# a built-in can carry its own command line too
run set claude --command "claude --model opus" >/dev/null 2>&1
grep -qF 'command: claude --model opus (custom)' <<<"$(run status)" || fail "a built-in with --command should use it"
run set claude >/dev/null
say "custom agents: set --command, status/list, inline, dir keeps it, bad input refused, built-in clears it"

say "PASS"
