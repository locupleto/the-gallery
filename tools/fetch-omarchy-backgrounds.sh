#!/usr/bin/env bash
#
# fetch-omarchy-backgrounds.sh -- download upstream Omarchy's wallpapers
# (themes/<name>/backgrounds/*) for one or more themes already vendored in
# this repo's themes/ directory, into the LIVE per-user config dir:
#
#   ~/.config/gallery/themes/<name>/backgrounds/
#
# These images are NEVER written into the repo (themes/<name>/ here) -- they
# are large binary files, machine-local, and not something this repo wants
# to track or ship; only colors.toml is vendored (see
# tools/vendor-omarchy-themes.sh). This script is the opt-in, per-theme way
# to pull the matching wallpapers onto a given machine.
#
# Usage:
#   fetch-omarchy-backgrounds.sh <theme-name>|--all [--force]
#
#   <theme-name>  one theme already present under themes/<name>/ in this repo
#   --all         fetch backgrounds for every vendored theme
#   --force       re-download files that already exist locally (default:
#                 skip files already present)
#
# Same upstream repo/resolution convention as vendor-omarchy-themes.sh: the
# GitHub contents/tree API against basecamp/omarchy's default branch (no
# ref is pinned there, so none is pinned here either -- both scripts always
# fetch from whatever is current upstream). curl only, no git clone of the
# whole upstream repo.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
THEMES_DIR="${REPO_ROOT}/themes"
CONFIG_THEMES_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/gallery/themes"
UPSTREAM_OWNER_REPO="basecamp/omarchy"
API_ROOT="https://api.github.com/repos/${UPSTREAM_OWNER_REPO}"

command -v curl >/dev/null 2>&1 || { echo "fetch-omarchy-backgrounds: curl not found" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "fetch-omarchy-backgrounds: python3 not found" >&2; exit 1; }

usage() {
  echo "usage: fetch-omarchy-backgrounds.sh <theme-name>|--all [--force]" >&2
  exit 1
}

[ "$#" -ge 1 ] || usage

FORCE=0
TARGET=""
for arg in "$@"; do
  case "${arg}" in
    --force)
      FORCE=1
      ;;
    --all)
      TARGET="--all"
      ;;
    -*)
      usage
      ;;
    *)
      if [ -n "${TARGET}" ] && [ "${TARGET}" != "--all" ]; then
        usage
      fi
      [ "${TARGET}" = "--all" ] || TARGET="${arg}"
      ;;
  esac
done
[ -n "${TARGET}" ] || usage

SCRATCH="${TMPDIR:-/tmp}/fetch-omarchy-backgrounds.$$"
mkdir -p "${SCRATCH}"
trap 'rm -rf "${SCRATCH}"' EXIT

echo "[fetch-bg] resolving ${UPSTREAM_OWNER_REPO} repo metadata"
REPO_JSON="${SCRATCH}/repo.json"
curl -sf -m 20 -L "${API_ROOT}" -o "${REPO_JSON}" \
  || { echo "[fetch-bg] could not reach GitHub API for repo metadata" >&2; exit 1; }

DEFAULT_BRANCH="$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print(d.get("default_branch", ""))
' "${REPO_JSON}")"
RESOLVED_FULL_NAME="$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print(d.get("full_name", ""))
' "${REPO_JSON}")"
[ -n "${DEFAULT_BRANCH}" ] || { echo "[fetch-bg] could not resolve default branch" >&2; exit 1; }
RESOLVED_FULL_NAME="${RESOLVED_FULL_NAME:-${UPSTREAM_OWNER_REPO}}"

echo "[fetch-bg] resolving latest commit on ${DEFAULT_BRANCH}"
COMMIT_JSON="${SCRATCH}/commit.json"
curl -sf -m 20 -L "${API_ROOT}/commits/${DEFAULT_BRANCH}" -o "${COMMIT_JSON}" \
  || { echo "[fetch-bg] could not resolve latest commit" >&2; exit 1; }
COMMIT_SHA="$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print(d.get("sha", ""))
' "${COMMIT_JSON}")"
[ -n "${COMMIT_SHA}" ] || { echo "[fetch-bg] could not resolve commit sha" >&2; exit 1; }

echo "[fetch-bg] listing full tree at ${COMMIT_SHA}"
TREE_JSON="${SCRATCH}/tree.json"
curl -sf -m 30 -L "${API_ROOT}/git/trees/${COMMIT_SHA}?recursive=1" -o "${TREE_JSON}" \
  || { echo "[fetch-bg] could not list repo tree" >&2; exit 1; }

# list_backgrounds <theme-name> -- prints "path\tsize" lines (one per file)
# for everything under themes/<name>/backgrounds/ in the tree, or nothing
# if that theme has no backgrounds dir upstream.
list_backgrounds() {
  python3 -c '
import json, sys
name = sys.argv[2]
prefix = "themes/%s/backgrounds/" % name
with open(sys.argv[1]) as f:
    d = json.load(f)
for t in d.get("tree", []):
    p = t.get("path", "")
    if t.get("type") == "blob" and p.startswith(prefix) and p != prefix:
        print("%s\t%s" % (p, t.get("size", 0)))
' "${TREE_JSON}" "$1"
}

fetch_theme_backgrounds() {
  local name="$1"
  if [ ! -d "${THEMES_DIR}/${name}" ]; then
    echo "[fetch-bg] ${name}: not a vendored theme (no ${THEMES_DIR}/${name}) -- skipping" >&2
    return 1
  fi

  local listing
  listing="$(list_backgrounds "${name}")"
  if [ -z "${listing}" ]; then
    echo "[fetch-bg] ${name}: no backgrounds/ upstream -- nothing to fetch"
    return 0
  fi

  local dest="${CONFIG_THEMES_DIR}/${name}/backgrounds"
  mkdir -p "${dest}"

  local path size base got=0 skipped=0 failed=0
  while IFS=$'\t' read -r path size; do
    [ -n "${path}" ] || continue
    base="$(basename "${path}")"
    if [ -f "${dest}/${base}" ] && [ "${FORCE}" -ne 1 ]; then
      echo "[fetch-bg] ${name}/${base}: already present, skipping (--force to re-download)"
      skipped=$((skipped + 1))
      continue
    fi
    echo "[fetch-bg] ${name}/${base}: fetching (${size} bytes)"
    if curl -sf -m 60 -L \
        "https://raw.githubusercontent.com/${RESOLVED_FULL_NAME}/${COMMIT_SHA}/${path}" \
        -o "${dest}/${base}"; then
      got=$((got + 1))
    else
      echo "[fetch-bg] ${name}/${base}: download failed" >&2
      rm -f "${dest}/${base}"
      failed=$((failed + 1))
    fi
  done <<< "${listing}"

  echo "[fetch-bg] ${name}: fetched ${got}, skipped ${skipped}, failed ${failed} (in ${dest})"
  [ "${failed}" -eq 0 ]
}

overall_failed=0
if [ "${TARGET}" = "--all" ]; then
  for dir in "${THEMES_DIR}"/*/; do
    [ -d "${dir}" ] || continue
    theme_name="$(basename "${dir}")"
    fetch_theme_backgrounds "${theme_name}" || overall_failed=1
  done
else
  fetch_theme_backgrounds "${TARGET}" || overall_failed=1
fi

exit "${overall_failed}"
