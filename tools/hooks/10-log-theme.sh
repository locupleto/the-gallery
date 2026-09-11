#!/usr/bin/env bash
#
# 10-log-theme.sh -- example theme-set hook for The Gallery.
#
# Installed by install.sh into ~/.config/gallery/hooks/theme-set.d/ and run
# by `gallery theme set <name>` (and, indirectly, `gallery theme render`
# does not run hooks -- only `set` does) with the new theme name as $1.
#
# Every executable file in that directory is run in name order with the
# theme name as its only argument; this one just appends a log line so you
# can see theme changes land.
#
set -euo pipefail

THEME="${1:?usage: 10-log-theme.sh <theme-name>}"
LOG_FILE="${HOME}/Library/Logs/gallery.log"

mkdir -p "$(dirname "${LOG_FILE}")"
printf '%s theme set: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${THEME}" >> "${LOG_FILE}"
