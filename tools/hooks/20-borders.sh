#!/usr/bin/env bash
#
# 20-borders.sh -- theme-set hook that re-syncs JankyBorders' focus outline
# to the new accent color.
#
# Installed by install.sh into ~/.config/gallery/hooks/theme-set.d/ and run
# by `gallery theme set <name>` and `gallery theme next` (not by `theme
# render`) with the new theme name as $1, in name order with the other
# hooks there.
#
# It just calls the installed gallery-borders helper (see bin/gallery-borders
# for the actual borders invocation and its hot-reconfigure-vs-relaunch
# logic). If that helper is not installed -- e.g. the tiler is not set up on
# this machine -- the hook exits quietly rather than failing the theme change.
#
set -euo pipefail

THEME="${1:?usage: 20-borders.sh <theme-name>}"
GALLERY_BORDERS="${HOME}/bin/gallery-borders"

[ -x "${GALLERY_BORDERS}" ] || exit 0

"${GALLERY_BORDERS}" apply
