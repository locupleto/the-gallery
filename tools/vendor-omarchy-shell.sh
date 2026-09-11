#!/usr/bin/env bash
#
# vendor-omarchy-shell.sh -- pull qs.Commons and qs.Ui (Omarchy 4 "Quattro"
# shell/Commons and shell/Ui) from basecamp/omarchy into qml/vendor/qs/, so
# gallery-qml can load unmodified Omarchy plugins that `import qs.Commons`
# / `import qs.Ui`.
#
# Re-runnable: re-fetches every file in both directories from the pinned
# ref (or $OMARCHY_REF if set) and overwrites qml/vendor/qs/{Commons,Ui} in
# place, then rewrites qml/vendor/UPSTREAM.md with the commit this vendor
# came from. Requires `gh` authenticated against github.com.
#
# Usage:
#   tools/vendor-omarchy-shell.sh                # vendor from quattro (default)
#   OMARCHY_REF=some-branch tools/vendor-omarchy-shell.sh
#
set -euo pipefail

REPO="basecamp/omarchy"
REF="${OMARCHY_REF:-quattro}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GALLERY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENDOR_DIR="${GALLERY_ROOT}/qml/vendor/qs"

command -v gh >/dev/null 2>&1 || { echo "vendor-omarchy-shell: 'gh' CLI is required" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "vendor-omarchy-shell: 'gh' is not authenticated (gh auth login)" >&2; exit 1; }

echo "Resolving ${REPO}@${REF}..." >&2
COMMIT_JSON="$(gh api "repos/${REPO}/commits/${REF}")"
COMMIT_SHA="$(printf '%s' "${COMMIT_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])')"
COMMIT_DATE="$(printf '%s' "${COMMIT_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["commit"]["committer"]["date"])')"
echo "  -> ${COMMIT_SHA} (${COMMIT_DATE})" >&2

echo "Listing shell/Commons and shell/Ui at ${COMMIT_SHA}..." >&2
PATHS="$(gh api "repos/${REPO}/git/trees/${COMMIT_SHA}?recursive=1" \
  --jq '.tree[] | select(.type == "blob") | select(.path | test("^shell/(Commons|Ui)/")) | .path')"

if [ -z "${PATHS}" ]; then
  echo "vendor-omarchy-shell: no shell/Commons or shell/Ui files found at ${COMMIT_SHA}" >&2
  exit 1
fi

rm -rf "${VENDOR_DIR}/Commons" "${VENDOR_DIR}/Ui"
mkdir -p "${VENDOR_DIR}/Commons" "${VENDOR_DIR}/Ui"

COUNT=0
while IFS= read -r path; do
  [ -z "${path}" ] && continue
  # path looks like "shell/Commons/Color.qml" or "shell/Ui/qmldir";
  # destination drops the "shell/" prefix: qml/vendor/qs/Commons/Color.qml
  dest="${VENDOR_DIR}/${path#shell/}"
  mkdir -p "$(dirname "${dest}")"
  gh api "repos/${REPO}/contents/${path}?ref=${COMMIT_SHA}" --jq .content | base64 -d > "${dest}"
  echo "  fetched ${path}" >&2
  COUNT=$((COUNT + 1))
done <<< "${PATHS}"

echo "Vendored ${COUNT} files." >&2

cat > "${GALLERY_ROOT}/qml/vendor/UPSTREAM.md" <<EOF
# Vendored: basecamp/omarchy shell/Commons + shell/Ui

- Source: https://github.com/${REPO}
- Ref requested: \`${REF}\`
- Commit: \`${COMMIT_SHA}\`
- Commit date: ${COMMIT_DATE}
- Vendored: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- Files: ${COUNT}
- Re-vendor with: \`tools/vendor-omarchy-shell.sh\` (or \`OMARCHY_REF=<ref> tools/vendor-omarchy-shell.sh\`)

## Layout

\`shell/Commons/*\` -> \`qml/vendor/qs/Commons/*\`
\`shell/Ui/*\` -> \`qml/vendor/qs/Ui/*\`

(the \`shell/\` prefix is dropped; \`qmldir\` in each directory declares the
module as \`qs.Commons\` / \`qs.Ui\`, matching what Omarchy plugins \`import\`.)

## Patches applied on top of upstream

None. Every vendored file loads under the gallery-qml shim (qml/shim/) as
shipped upstream -- see qml/README.md for what the shim provides and what a
handful of qs.Ui files reference but never get compiled by the plugins this
host targets (KeyboardPanel.qml, SpeedTestOverlay.qml, PopupCard.qml,
Panel.qml and a few others reach further into layer-shell-only Quickshell
APIs -- WlrLayer, WlrKeyboardFocus, ExclusionMode, IpcHandler, QsWindow --
that are not shimmed; those files simply are never imported by RadioAtlas.qml
or gallery.qml-demo, and QML only compiles a module file when something
actually references its type, so this is inert rather than papered over).

## Runtime path note

Commons/Color.qml and Commons/Style.qml read the active theme from
\`Quickshell.env("HOME") + "/.local/state/omarchy/current/theme"\`
(colors.toml, shell.toml) as of this vendor's commit -- this is what the
Gallery installer needs to point \`~/.local/state/omarchy/current/theme\` at
(a symlink to the active Gallery theme), not \`~/.config/omarchy\`. Confirm
against Commons/Color.qml's \`currentThemePath\` property after any re-vendor,
since Omarchy has moved this path before.
EOF

echo "Wrote qml/vendor/UPSTREAM.md" >&2
