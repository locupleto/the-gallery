#!/usr/bin/env bash
# Gallery TUI plugin: browse yabai spaces/windows in fzf and jump to one.
#
#   spaces.sh          run the interactive fzf picker (needs a tty)
#   spaces.sh --list   print the listing lines and exit (for testing, no tty needed)
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Build the fzf input: one tab-delimited line per row.
#   field 1: kind  ("win" or "space")
#   field 2: id    (window id for "win", space index for "space")
#   field 3: display text shown/searched in fzf
list_lines() {
  local spaces_json windows_json
  spaces_json=$(yabai -m query --spaces)
  windows_json=$(yabai -m query --windows)

  SPACES_JSON="$spaces_json" WINDOWS_JSON="$windows_json" /usr/bin/python3 <<'PYEOF'
import json
import os

spaces = json.loads(os.environ["SPACES_JSON"])
windows = json.loads(os.environ["WINDOWS_JSON"])

space_by_index = {s["index"]: s for s in spaces}
windows_by_space = {}
for w in windows:
    windows_by_space.setdefault(w["space"], []).append(w)

def truncate(title, limit=60):
    title = (title or "").replace("\t", " ").replace("\n", " ")
    if len(title) > limit:
        return title[: limit - 3] + "..."
    return title

rows = []  # (space_index, sort_key, line)
for index in sorted(space_by_index):
    space = space_by_index[index]
    space_flag = "*" if space.get("has-focus") else " "
    wins = sorted(windows_by_space.get(index, []), key=lambda w: (w.get("app") or "").lower())
    if not wins:
        display = f"{space_flag}{index:>2}  (empty)"
        rows.append((index, "", f"space\t{index}\t{display}"))
        continue
    for w in wins:
        win_flag = "●" if w.get("has-focus") else " "
        app = w.get("app") or ""
        title = truncate(w.get("title"))
        display = f"{space_flag}{index:>2}  {win_flag} {app} — {title}"
        rows.append((index, app.lower(), f"win\t{w['id']}\t{display}"))

rows.sort(key=lambda r: (r[0], r[1]))
for _, _, line in rows:
    print(line)
PYEOF
}

if [[ "${1:-}" == "--list" ]]; then
  if ! command -v yabai >/dev/null 2>&1; then
    echo "yabai not found on PATH" >&2
    exit 1
  fi
  list_lines
  exit 0
fi

if ! command -v yabai >/dev/null 2>&1 || ! yabai -m query --spaces >/dev/null 2>&1; then
  echo "yabai is not installed or not running — cannot list spaces."
  sleep 3
  exit 1
fi

selected=""
status=0
selected=$(list_lines | fzf \
  --delimiter=$'\t' \
  --with-nth=3 \
  --height=100% \
  --layout=reverse \
  --border=rounded \
  --prompt='Spaces > ' \
  --header='Enter focuses the window, Esc closes') || status=$?

if [[ -z "$selected" ]]; then
  # Esc / no selection: close quietly.
  exit 0
fi

kind=$(cut -f1 <<<"$selected")
id=$(cut -f2 <<<"$selected")

case "$kind" in
  win)
    yabai -m window --focus "$id"
    ;;
  space)
    yabai -m space --focus "$id"
    ;;
esac

exit 0
