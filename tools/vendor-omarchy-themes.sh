#!/usr/bin/env bash
#
# vendor-omarchy-themes.sh -- vendor colors.toml (and light.mode, where
# present) for every theme in basecamp/omarchy into themes/<name>/ in this
# repo, plus themes/UPSTREAM.md recording provenance and Omarchy's MIT
# licence.
#
# Primary path: the GitHub contents/tree API (no local git needed, works
# even if the upstream repo has been renamed -- the API redirects contents
# and commit lookups for a renamed repo, so "basecamp/omarchy" keeps working
# as the canonical reference even after such a move).
#
# Fallback: a shallow sparse git clone into the scratchpad dir, used only if
# the API path fails (e.g. rate-limited or offline mirror unavailable).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
THEMES_DIR="${REPO_ROOT}/themes"
UPSTREAM_OWNER_REPO="basecamp/omarchy"
API_ROOT="https://api.github.com/repos/${UPSTREAM_OWNER_REPO}"
SCRATCH="${TMPDIR:-/tmp}/vendor-omarchy-themes.$$"

command -v curl >/dev/null 2>&1 || { echo "vendor-omarchy-themes: curl not found" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "vendor-omarchy-themes: python3 not found" >&2; exit 1; }

mkdir -p "${THEMES_DIR}"
mkdir -p "${SCRATCH}"
trap 'rm -rf "${SCRATCH}"' EXIT

echo "[vendor] resolving ${UPSTREAM_OWNER_REPO} repo metadata"
REPO_JSON="${SCRATCH}/repo.json"
if ! curl -sf -m 20 -L "${API_ROOT}" -o "${REPO_JSON}"; then
  echo "[vendor] could not reach GitHub API for repo metadata" >&2
  REPO_JSON=""
fi

DEFAULT_BRANCH=""
RESOLVED_FULL_NAME=""
if [ -n "${REPO_JSON}" ]; then
  DEFAULT_BRANCH="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(d.get("default_branch", ""))
except Exception:
    print("")
' "${REPO_JSON}")"
  RESOLVED_FULL_NAME="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(d.get("full_name", ""))
except Exception:
    print("")
' "${REPO_JSON}")"
fi

vendor_via_api() {
  [ -n "${DEFAULT_BRANCH}" ] || return 1

  echo "[vendor] resolving latest commit on ${DEFAULT_BRANCH}"
  local commit_json commit_sha commit_date
  commit_json="${SCRATCH}/commit.json"
  curl -sf -m 20 -L "${API_ROOT}/commits/${DEFAULT_BRANCH}" -o "${commit_json}" || return 1
  commit_sha="$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print(d.get("sha", ""))
' "${commit_json}")"
  commit_date="$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print(d.get("commit", {}).get("author", {}).get("date", ""))
' "${commit_json}")"
  [ -n "${commit_sha}" ] || return 1

  echo "[vendor] listing themes/ tree at ${commit_sha}"
  local tree_json
  tree_json="${SCRATCH}/tree.json"
  curl -sf -m 30 -L "${API_ROOT}/git/trees/${commit_sha}?recursive=1" -o "${tree_json}" || return 1

  local names_file
  names_file="${SCRATCH}/theme-names.txt"
  python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
names = sorted({
    p.split("/", 2)[1]
    for p in (t["path"] for t in d.get("tree", []))
    if p.startswith("themes/") and p.count("/") >= 1
})
for n in names:
    print(n)
' "${tree_json}" > "${names_file}"

  [ -s "${names_file}" ] || return 1

  local light_names_file
  light_names_file="${SCRATCH}/light-names.txt"
  python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
for t in d.get("tree", []):
    p = t["path"]
    if p.startswith("themes/") and p.endswith("/light.mode"):
        print(p.split("/")[1])
' "${tree_json}" > "${light_names_file}" || true

  echo "[vendor] fetching LICENSE"
  local license_txt
  license_txt="${SCRATCH}/LICENSE"
  curl -sf -m 20 -L "https://raw.githubusercontent.com/${RESOLVED_FULL_NAME:-${UPSTREAM_OWNER_REPO}}/${commit_sha}/LICENSE" \
    -o "${license_txt}" || return 1

  local name got=0 failed=0
  while IFS= read -r name; do
    [ -n "${name}" ] || continue
    local dest="${THEMES_DIR}/${name}"
    mkdir -p "${dest}"
    if curl -sf -m 20 -L \
        "https://raw.githubusercontent.com/${RESOLVED_FULL_NAME:-${UPSTREAM_OWNER_REPO}}/${commit_sha}/themes/${name}/colors.toml" \
        -o "${dest}/colors.toml"; then
      got=$((got + 1))
    else
      echo "[vendor] failed to fetch colors.toml for ${name}" >&2
      failed=1
      continue
    fi
    if grep -qx "${name}" "${light_names_file}" 2>/dev/null; then
      : > "${dest}/light.mode"
    fi
  done < "${names_file}"

  [ "${got}" -gt 0 ] || return 1
  [ "${failed}" -eq 0 ] || echo "[vendor] some themes failed to fetch via API (see above)" >&2

  cp "${license_txt}" "${SCRATCH}/LICENSE.final"
  VENDORED_COMMIT="${commit_sha}"
  VENDORED_DATE="${commit_date}"
  VENDORED_BRANCH="${DEFAULT_BRANCH}"
  VENDORED_FULL_NAME="${RESOLVED_FULL_NAME:-${UPSTREAM_OWNER_REPO}}"
  VENDORED_COUNT="${got}"
  return 0
}

vendor_via_git_clone() {
  echo "[vendor] falling back to shallow sparse git clone"
  command -v git >/dev/null 2>&1 || { echo "[vendor] git not found" >&2; return 1; }

  local clone_dir
  clone_dir="${SCRATCH}/omarchy-clone"
  rm -rf "${clone_dir}"

  if ! git clone --depth 1 --filter=blob:none --sparse \
      "https://github.com/${UPSTREAM_OWNER_REPO}.git" "${clone_dir}" >&2; then
    echo "[vendor] git clone failed" >&2
    return 1
  fi
  ( cd "${clone_dir}" && git sparse-checkout set themes ) >&2 || return 1

  [ -d "${clone_dir}/themes" ] || return 1

  local commit_sha commit_date branch
  commit_sha="$(cd "${clone_dir}" && git rev-parse HEAD)"
  commit_date="$(cd "${clone_dir}" && git log -1 --format=%aI)"
  branch="$(cd "${clone_dir}" && git rev-parse --abbrev-ref HEAD)"

  local got=0 name
  for name_dir in "${clone_dir}"/themes/*/; do
    [ -d "${name_dir}" ] || continue
    name="$(basename "${name_dir}")"
    [ -f "${name_dir}colors.toml" ] || continue
    mkdir -p "${THEMES_DIR}/${name}"
    cp "${name_dir}colors.toml" "${THEMES_DIR}/${name}/colors.toml"
    if [ -f "${name_dir}light.mode" ]; then
      cp "${name_dir}light.mode" "${THEMES_DIR}/${name}/light.mode"
    fi
    got=$((got + 1))
  done

  [ "${got}" -gt 0 ] || return 1

  if [ -f "${clone_dir}/LICENSE" ]; then
    cp "${clone_dir}/LICENSE" "${SCRATCH}/LICENSE.final"
  else
    echo "[vendor] no LICENSE file found in clone" >&2
    return 1
  fi

  VENDORED_COMMIT="${commit_sha}"
  VENDORED_DATE="${commit_date}"
  VENDORED_BRANCH="${branch}"
  VENDORED_FULL_NAME="${UPSTREAM_OWNER_REPO}"
  VENDORED_COUNT="${got}"
  return 0
}

VENDORED_COMMIT=""
VENDORED_DATE=""
VENDORED_BRANCH=""
VENDORED_FULL_NAME=""
VENDORED_COUNT=""

if ! vendor_via_api; then
  echo "[vendor] API path failed, trying git clone fallback" >&2
  if ! vendor_via_git_clone; then
    echo "[vendor] both API and git clone fallback failed" >&2
    exit 1
  fi
fi

echo "[vendor] writing themes/UPSTREAM.md"
{
  echo "# Upstream: Omarchy themes"
  echo
  echo "Vendored from [\`${UPSTREAM_OWNER_REPO}\`](https://github.com/${UPSTREAM_OWNER_REPO})"
  echo "(resolved as \`${VENDORED_FULL_NAME}\` at fetch time)."
  echo
  echo "- Source commit: \`${VENDORED_COMMIT}\`"
  echo "- Source branch: \`${VENDORED_BRANCH}\`"
  echo "- Commit date: ${VENDORED_DATE}"
  echo "- Fetched: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- Themes vendored: ${VENDORED_COUNT}"
  echo "- Vendored by: tools/vendor-omarchy-themes.sh"
  echo
  echo "Only \`colors.toml\` (and \`light.mode\`, where the upstream theme"
  echo "directory has one) is vendored per theme; Omarchy also ships"
  echo "wallpapers, editor/terminal themes, and icon sets that this repo"
  echo "does not need and does not copy."
  echo
  echo "## Licence"
  echo
  echo "Omarchy is MIT licensed. Full licence text as fetched from the"
  echo "source commit above:"
  echo
  echo '```'
  cat "${SCRATCH}/LICENSE.final"
  echo '```'
} > "${THEMES_DIR}/UPSTREAM.md"

echo "[vendor] done: ${VENDORED_COUNT} themes vendored from ${VENDORED_FULL_NAME}@${VENDORED_COMMIT}"

light_count=0
for d in "${THEMES_DIR}"/*/; do
  [ -f "${d}light.mode" ] && light_count=$((light_count + 1))
done
echo "[vendor] themes with light.mode: ${light_count}"
