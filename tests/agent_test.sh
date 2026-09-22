#!/usr/bin/env bash
#
# agent_test.sh -- offline test of plugins/gallery.agent/agent.
#
# Entirely offline: GALLERY_CONFIG_DIR points at a temp tree so the real
# ~/.config/gallery/state/agent.json is never touched, GALLERY_AGENT_DIR at a
# temp directory, and a stub PATH provides fake agent binaries. `launch` is
# never run -- only the pure verbs (status/list/set) and the start-directory
# fallback, both asserted by inspecting what `status` reports.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
AGENT="${REPO_ROOT}/plugins/gallery.agent/agent"

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
# cannot show, which is the whole failure this plugin exists to avoid.
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
# The estate's git root lives on an external volume: if it is not mounted the
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

say "PASS"
