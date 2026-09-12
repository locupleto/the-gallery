#!/usr/bin/env bash
# Install (or refresh) the optional tiling layer: yabai + skhd, configured from this
# repo. Run from a shell with access to this checkout (Terminal/Claude), on each
# machine that should tile. Idempotent: re-run after editing tiler/yabairc or
# tiler/skhdrc to push the new files and reload both services.
#
# The rc files are COPIED, not symlinked: launchd starts yabai/skhd, and under launchd
# macOS TCC denies reading the external volume this repo lives on (same reason the
# assistant itself runs from ~/.ai_voice_assistant, see deploy/sync-to-home.sh).
#
# No scripting addition is installed (no sudoers entry, no `yabai --load-sa`). SIP
# stays enabled; Space switching remains the Mission Control Ctrl+N shortcuts.
#
#   tiler/install.sh            install/refresh; restart a service only if its
#                               effective config changed (see "services")
#   tiler/install.sh --restart  restart both services even if unchanged
#   tiler/install.sh --dry-run  print what would happen
#   tiler/install.sh --uninstall  stop both services and remove the rc files
#                                 (keeps the Homebrew formulas)
set -euo pipefail
cd "$(dirname "$0")"

DRY=0; UNINSTALL=0; RESTART=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        --uninstall) UNINSTALL=1 ;;
        --restart) RESTART=1 ;;
        *) echo "usage: $0 [--dry-run] [--restart] [--uninstall]" >&2; exit 2 ;;
    esac
done

run() { if [ "$DRY" = 1 ]; then echo "[dry] $*"; else echo "[tiler] $*"; "$@"; fi; }

YABAI_RC="$HOME/.config/yabai/yabairc"
SKHD_RC="$HOME/.config/skhd/skhdrc"

if [ "$UNINSTALL" = 1 ]; then
    command -v yabai >/dev/null && run yabai --stop-service || true
    command -v skhd  >/dev/null && run skhd  --stop-service || true
    run rm -f "$YABAI_RC" "$SKHD_RC" "$(dirname "$SKHD_RC")/learn"
    run rm -rf "$HOME/Applications/Learn.app"
    echo "[tiler] services stopped, rc files removed. The voice assistant falls back"
    echo "        to System Events placement on its own (no restart needed)."
    exit 0
fi

# --- prerequisites --------------------------------------------------------------
if ! command -v brew >/dev/null; then
    echo "Homebrew is required (https://brew.sh)" >&2; exit 1
fi
# yabai needs each display to have its own Spaces and a stable Space order.
spans="$(defaults read com.apple.spaces spans-displays 2>/dev/null || echo 0)"
mru="$(defaults read com.apple.dock mru-spaces 2>/dev/null || echo 0)"
if [ "$spans" != 0 ]; then
    echo "[tiler] WARNING: 'Displays have separate Spaces' is OFF (System Settings >"
    echo "        Desktop & Dock > Mission Control). yabai needs it ON; log out/in after."
fi
if [ "$mru" != 0 ]; then
    echo "[tiler] WARNING: 'Automatically rearrange Spaces based on most recent use'"
    echo "        is ON. Turn it OFF or Space numbers will drift under you."
fi
if pgrep -xq Magnet || pgrep -xq Rectangle; then
    echo "[tiler] WARNING: another window manager (Magnet/Rectangle) is running; quit it."
fi

# --- install ----------------------------------------------------------------------
for f in yabai skhd; do
    if brew list --formula "$f" >/dev/null 2>&1; then
        echo "[tiler] $f already installed ($(brew list --versions "$f"))"
    else
        run brew install "asmvik/formulae/$f"
    fi
done
# JankyBorders (borders): draws the accent outline around the focused window
# (launched from yabairc). Needs no scripting addition, so SIP stays enabled.
if brew list --formula borders >/dev/null 2>&1; then
    echo "[tiler] borders already installed ($(brew list --versions borders))"
else
    run brew install "FelixKratz/formulae/borders"
fi
# The Learn menu (tiler/learn): fzf picks a sheet, glow renders it.
for f in fzf glow; do
    if brew list --formula "$f" >/dev/null 2>&1; then
        echo "[tiler] $f already installed ($(brew list --versions "$f"))"
    else
        run brew install "$f"
    fi
done

# --- configuration -------------------------------------------------------------------
# The rc files minus comments and blank lines: what a service actually acts on.
# Captured before the copy so the services step can tell a real change from a
# comment-only edit.
effective() { grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null || true; }
yabai_before="$(effective "$YABAI_RC")"
skhd_before="$(effective "$SKHD_RC")"

run install -d "$(dirname "$YABAI_RC")" "$(dirname "$SKHD_RC")"
run install -m 755 yabairc "$YABAI_RC"
run install -m 644 skhdrc  "$SKHD_RC"
# skhdrc includes gallery.skhd (The Gallery key bindings, repo git/the-gallery).
# Ensure the file exists so the include resolves even before the Gallery is installed.
[ -e "$(dirname "$SKHD_RC")/gallery.skhd" ] || run install -m 644 /dev/null "$(dirname "$SKHD_RC")/gallery.skhd"
# The Learn script lives next to skhdrc (skhd and Learn.app run under launchd, which
# cannot read this volume); it also writes the generated key sheet into the vault
# and builds ~/Applications/Learn.app for Spotlight.
run install -m 755 learn "$(dirname "$SKHD_RC")/learn"
run install -m 644 learn.style.json "$(dirname "$SKHD_RC")/learn.style.json"
if [ "$DRY" = 1 ]; then echo "[dry] learn install skhdrc"; else "$(dirname "$SKHD_RC")/learn" install "$PWD/skhdrc"; fi

# --- services --------------------------------------------------------------------------
# A running service is restarted so a changed rc file takes effect
# (--start-service on a running service returns 0 without reloading anything).
# Restarting yabai is NOT free: it rebuilds every window tree from scratch, so
# manual split ratios, swaps and zoom state on every display are lost. A
# service is therefore restarted only when its effective config (comments and
# blank lines stripped) differs from what was live before the copy, or with
# --restart. Comment-only edits are copied without touching the services.
for f in yabai skhd; do
    case "$f" in
        yabai) before="$yabai_before"; after="$(effective yabairc)" ;;
        skhd)  before="$skhd_before";  after="$(effective skhdrc)" ;;
    esac
    if [ "$DRY" = 1 ]; then echo "[dry] $f --restart-service if config changed (or --start-service)"; continue; fi
    if ! pgrep -xq "$f"; then
        "$f" --start-service && echo "[tiler] $f service started"
    elif [ "$RESTART" = 1 ] || [ "$before" != "$after" ]; then
        "$f" --restart-service && echo "[tiler] $f service restarted"
    else
        echo "[tiler] $f config unchanged, not restarting (--restart to force)"
    fi
done

cat <<'MSG'

[tiler] Manual steps (once per machine):
  1. System Settings > Privacy & Security > Accessibility: tick "yabai" and "skhd"
     (both request it on first start). Then run `yabai --restart-service` and
     `skhd --restart-service` — each must restart after the grant.
  2. System Settings > Keyboard > Keyboard Shortcuts... > Mission Control: enable
     "Switch to Desktop N" for every Desktop you use (super+N and super+shift+N
     ride on these Ctrl+N shortcuts).
  3. iTerm > Secure Keyboard Entry must be OFF, or skhd stops seeing keys while
     iTerm is frontmost.
  4. Try: left Option+h/j/k/l (focus), left Option+2 (Space 2), right Option+2 (@),
     left Option+space (Learn menu; first press: allow "skhd wants to control iTerm2"),
     Cmd+space "Learn" (first launch: allow "Learn wants to control iTerm2").
  Verify: `yabai -m query --displays` lists your displays; `skhd --observe` shows keys.
MSG
