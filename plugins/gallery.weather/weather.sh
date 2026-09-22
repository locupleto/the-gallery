#!/usr/bin/env bash
#
# gallery.weather / weather.sh -- Gallery TUI plugin: a compact "glance"
# weather panel (current conditions only, no forecast), opened/closed by a
# toggle keybinding in a floating, centred iTerm window (see bin/gallery-tui
# and this plugin's manifest.json -- grid "6:6:2:2:2:2", a centred third of
# the screen, smaller than a picker's "6:6:1:1:4:4" since this is a glance
# panel, not something you interact with).
#
# Ported from crystal-widgets-v2/widgets/crystal-weather.widget/widget_runner.sh
# (an Übersicht desktop widget in a sibling, unrelated repo) -- same
# OpenWeatherMap call, same condition-code -> icon classification table,
# same day/night detection, same caching discipline. NOT sourced or
# imported from that repo at runtime; this is a standalone port. Kept
# deliberately close to the original so the two stay easy to diff by eye.
#
# Differences from the widget_runner.sh original:
#   - Cache/stamp/lock live under ~/.cache/gallery/weather/ (created on
#     first run), not /tmp -- this plugin is not an Übersicht widget and
#     has no HTOP_TEMP_DIR convention to inherit.
#   - This is an interactive glance panel a person opens for a few
#     seconds, not a widget re-run by a scheduler every 60s. The rate
#     limit (FETCH_INTERVAL, below) is unchanged from the original (10
#     minutes) but the panel ALWAYS renders immediately from whatever is
#     in the cache when a fetch is skipped (rate-limited) or fails --
#     never blocks on the network, never shows a spinner.
#   - Location/units/icon set come from this repo's own small flat JSON
#     state file (~/.config/gallery/state/weather.json), in the house
#     style of state/font.json and state/console.json, not from
#     WEATHER_LOCATION/WEATHER_UNITS/WEATHER_ICON_SET environment
#     variables. Defaults (location "Stockholm,SE", units "metric",
#     iconSet "meteocons-line") apply field-by-field, including when the
#     file is missing entirely.
#   - The icon is rendered inline in the terminal (rsvg-convert to a
#     true-alpha PNG sent to iTerm2 as an inline image, falling back to
#     chafa and then to a Nerd Font glyph -- see render_icon_inline)
#     rather than embedded as raw SVG markup in a JSON payload for
#     index.coffee; there is no coffeescript renderer here.
#   - Any keypress closes the panel (in addition to the outside toggle
#     keybinding), not just Esc.
#
# ---- Cache discipline (identical contract to the widget original) --------
# Three files under CACHE_DIR:
#   weather.json     the last GOOD response, published by an atomic `mv`
#                     over any previous good response -- a fetch that
#                     fails (network error, non-200, or a 200 whose body
#                     isn't valid `{"cod": 200, ...}` JSON) never touches
#                     it, so the panel always has the last known-good
#                     conditions to fall back on.
#   weather.stamp     mtime = last fetch ATTEMPT (pass or fail), the rate
#                     limiter: a fetch is only even tried once stamp_age
#                     >= FETCH_INTERVAL seconds.
#   weather.lock.d    an mkdir-based mutex (mkdir is atomic: exactly one
#                     concurrent invocation of this script wins the race
#                     and does the fetch). A lock directory older than two
#                     minutes is treated as orphaned (left behind by a
#                     killed runner -- a fetch takes at most ~10s) and
#                     reaped before the mkdir attempt.
# The published cache's age (now - mtime) drives the "stale, N minutes
# old" hint once it exceeds STALE_AFTER.
#
# ---- API key resolution (never enters the repo, never printed) -----------
# The iTerm window this runs in is spawned via an iTerm2 profile `command`
# (see bin/gallery-tui's spawn_window), which runs this script directly --
# NOT a login/interactive shell, so ~/.zshrc is never sourced and any
# export set only there will be invisible here. Resolved in this order,
# first hit wins:
#   1. $OPENWEATHERMAP_API_KEY, if already set in this process's
#      environment (e.g. exported by a launchd plist or a parent that did
#      source a shell rc before getting here).
#   2. ~/.config/gallery/weather.key -- a single-line file, mode 600.
#      This is the real path in practice, per the above. Written by the
#      `gallery weather key --set <key>` subcommand (owned by another
#      engineer, built in parallel -- not part of this plugin).
# If neither yields a key, the panel renders a friendly "not configured"
# message naming that subcommand, waits for a keypress, and exits 0 --
# never an error, per this repo's general fail-safe philosophy: an
# unconfigured or unreachable weather source degrades gracefully and never
# spews errors into the floating window.
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
GALLERY_DIR="${CONFIG_HOME}/gallery"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ICONS_DIR="${SELF_DIR}/icons"
KEY_FILE="${GALLERY_DIR}/weather.key"
STATE_FILE="${GALLERY_DIR}/state/weather.json"
THEME_STATE="${GALLERY_DIR}/state/theme.sh"

CACHE_DIR="${CACHE_HOME}/gallery/weather"
CACHE="${CACHE_DIR}/weather.json"       # last GOOD response (atomic mv)
STAMP="${CACHE_DIR}/weather.stamp"      # last fetch ATTEMPT (rate limiter)
LOCK="${CACHE_DIR}/weather.lock.d"      # mkdir-based fetch mutex
ICON_CACHE_DIR="${CACHE_DIR}/icons"     # rasterised icons (see render_icon_inline)

FETCH_INTERVAL=600   # min seconds between API attempts (unchanged from widget)
STALE_AFTER=1800     # cache age that triggers the "stale, N minutes old" hint

# --- theme -------------------------------------------------------------
# Same source as gallery.themes/themes.sh: the flat GALLERY_* exports
# tools/render-theme.py regenerates on every theme change. Missing/absent
# file (never rendered yet) falls back to a dark, legible palette so the
# panel is never unreadable -- these fallbacks are never combined with a
# partially-sourced theme.sh, since a valid theme.sh always sets all of
# them together.
if [[ -f "$THEME_STATE" ]]; then
  # shellcheck source=/dev/null
  source "$THEME_STATE"
fi
: "${GALLERY_BG:=#1f1811}"
: "${GALLERY_FG:=#e8e6df}"
: "${GALLERY_ACCENT:=#d8a656}"
: "${GALLERY_MUTED:=#9a886c}"
: "${GALLERY_COLOR1:=#e5726f}"   # red -- used for the "not configured" hint

RESET=$'\033[0m'
BOLD=$'\033[1m'

# fg HEX -- truecolor foreground escape for HEX ("#rrggbb"), or nothing if
# HEX is empty/malformed -- same tolerance discipline as themes.sh's own
# swatch(). Never fails the script; a bad theme value just prints in the
# terminal's default color instead of aborting.
fg() {
  local hex="${1#\#}" r g b
  [[ "${#hex}" -eq 6 ]] || return 0
  case "$hex" in
    *[!0-9a-fA-F]*) return 0 ;;
  esac
  r=$((16#${hex:0:2}))
  g=$((16#${hex:2:2}))
  b=$((16#${hex:4:2}))
  printf '\033[38;2;%d;%d;%dm' "$r" "$g" "$b"
}

# --- small utilities -----------------------------------------------------

# term_cols -- best-effort terminal width, falling back to the manifest's
# grid share of a typical display when tput has nothing (no tty yet).
term_cols() {
  tput cols 2>/dev/null || echo 60
}

# center LINE -- print LINE (may contain ANSI colour codes) padded on the
# left so its *visible* width is centred in the terminal. Strips ANSI SGR
# sequences only for the width calculation, never from the printed text.
center() {
  local line="$1" cols visible pad
  cols="$(term_cols)"
  visible="$(printf '%s' "$line" | sed -E 's/\x1b\[[0-9;]*m//g')"
  pad=$(( (cols - ${#visible}) / 2 ))
  [[ "$pad" -lt 0 ]] && pad=0
  printf '%*s%s\n' "$pad" '' "$line"
}

blank_lines() {
  local n="$1" i
  for ((i = 0; i < n; i++)); do printf '\n'; done
}

# wait_for_key -- block for exactly one keypress, then return. Any key
# closes the panel (q and Escape both work, trivially -- any byte read()
# picks up is "a key"); this is the panel's own dismissal in addition to
# the outside toggle keybinding that opened it (see bin/gallery-tui).
wait_for_key() {
  IFS= read -rsn 1 _ || true
}

# --- Nerd Font glyph fallback (no chafa installed) ------------------------
#
# The Gallery pins "MesloLGS Nerd Font Mono" (see state/font.json), so
# these codepoints are always available. Covers every ICON_MAP category
# below with a real weather glyph from the Nerd Font "weather" block;
# categories with no distinct day/night or no dedicated glyph reuse the
# closest visual match (noted inline) rather than inventing an unverified
# codepoint.
#   U+E30D  clear-day            U+E32B  clear-night
#   U+E302  rain                 U+E30A  partly-cloudy-day
#   U+E312  snow                 U+E31D  thunderstorms
#   U+E313  fog / mist           U+E34B  overcast / cloudy
glyph_for() {
  local category="$1" is_day="$2"
  case "$category" in
    thunder)          printf '' ;;
    drizzle|rain)      printf '' ;;
    sleet|snow)        printf '' ;;
    mist|smoke|haze|dust|fog)
                       printf '' ;;
    clear)
      if [[ "$is_day" == "1" ]]; then printf ''; else printf ''; fi
      ;;
    partly)            printf '' ;;   # no dedicated partly-night glyph; reused
    wind|tornado|broken|overcast|*)
                       printf '' ;;   # no dedicated glyph for these; reused
  esac
}

# --- API key resolution ---------------------------------------------------

resolve_api_key() {
  local key="${OPENWEATHERMAP_API_KEY:-}"
  if [[ -z "$key" && -f "$KEY_FILE" ]]; then
    key="$(head -n 1 "$KEY_FILE" 2>/dev/null | tr -d '[:space:]')"
  fi
  printf '%s' "$key"
}

# --- state (location/units/iconSet) ---------------------------------------

# read_state -- "LOCATION<US>UNITS<US>ICONSET" (<US> = ASCII 0x1F, the unit
# separator), defaults applied field-by-field (missing file, unreadable
# file, missing/invalid field all fall back independently) -- same
# tolerance discipline as themes.sh's console_mode/widgets_mode/
# borders_prefs. Deliberately NOT tab-delimited: bash's `read` treats tab
# (like space and newline) as "IFS whitespace" and collapses runs of it /
# strips it at the ends, so a genuinely empty field is silently swallowed
# and every field after it shifts left. 0x1F is not whitespace, so `read`
# splits on it literally, empty fields included -- see parse_cache below,
# where icon_path legitimately can be empty.
read_state() {
  python3 -c '
import json, sys

location = "Stockholm,SE"
units = "metric"
icon_set = "meteocons-line"
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
    if isinstance(data, dict):
        loc = data.get("location")
        if isinstance(loc, str) and loc.strip():
            location = loc.strip()
        u = data.get("units")
        if u in ("metric", "imperial"):
            units = u
        iset = data.get("iconSet")
        if isinstance(iset, str) and iset.strip():
            icon_set = iset.strip()
except Exception:
    pass
sys.stdout.write(location + "\x1f" + units + "\x1f" + icon_set)
' "$STATE_FILE" 2>/dev/null || printf 'Stockholm,SE\x1fmetric\x1fmeteocons-line'
}

# --- rendering -------------------------------------------------------------

render_not_configured() {
  blank_lines 3
  center "$(fg "$GALLERY_ACCENT")${BOLD}Weather${RESET}"
  printf '\n'
  center "$(fg "$GALLERY_COLOR1")Weather is not configured.${RESET}"
  printf '\n'
  center "$(fg "$GALLERY_FG")Set an OpenWeatherMap API key with:${RESET}"
  center "$(fg "$GALLERY_ACCENT")gallery weather key --set <key>${RESET}"
  printf '\n'
  center "$(fg "$GALLERY_MUTED")press any key to close${RESET}"
}

render_unavailable() {
  local location="$1"
  blank_lines 3
  center "$(fg "$GALLERY_ACCENT")${BOLD}Weather${RESET}"
  printf '\n'
  center "$(fg "$GALLERY_COLOR1")No weather data yet for ${location}.${RESET}"
  center "$(fg "$GALLERY_FG")Check the connection, or the location in${RESET}"
  center "$(fg "$GALLERY_FG")~/.config/gallery/state/weather.json${RESET}"
  printf '\n'
  center "$(fg "$GALLERY_MUTED")press any key to close${RESET}"
}

# --- icon rendering -------------------------------------------------------
#
# Three tiers, best first:
#   1. rsvg-convert -> PNG with a real alpha channel, emitted straight to
#      iTerm2 as an inline image. This is the ONLY path that gives a
#      genuinely transparent icon. chafa's iTerm output never emits a fully
#      transparent pixel -- its "background" comes out at alpha 1/255, which
#      iTerm paints as an opaque swatch, i.e. a visible box behind the icon.
#      The rasterised PNG is cached under ICON_CACHE_DIR, so the conversion
#      runs once per icon rather than on every open, and is re-run only when
#      the source SVG is newer than the cached PNG.
#   2. chafa -- works in any terminal, but paints that opaque box; still
#      better than no icon at all.
#   3. nothing (return 1), so the caller falls back to a Nerd Font glyph.
render_icon_inline() {
  local icon_path="$1" cols_w="$2" rows_h="$3" pad="$4"
  [[ -n "$icon_path" && -f "$icon_path" ]] || return 1

  # Tier 1: true-alpha PNG, inline in iTerm2.
  if [[ "${TERM_PROGRAM:-}" == "iTerm.app" || -n "${ITERM_SESSION_ID:-}" ]] \
     && command -v rsvg-convert >/dev/null 2>&1; then
    local png b64
    png="${ICON_CACHE_DIR}/$(basename "${icon_path%.svg}")-240.png"
    if [[ ! -s "$png" || "$icon_path" -nt "$png" ]]; then
      mkdir -p "$ICON_CACHE_DIR" 2>/dev/null
      rsvg-convert -w 240 -h 240 -f png -o "$png" "$icon_path" 2>/dev/null || png=""
    fi
    if [[ -n "$png" && -s "$png" ]]; then
      b64="$(base64 < "$png" | tr -d '\n')"
      printf '%*s' "$pad" ''
      printf '\033]1337;File=inline=1;width=%d;height=%d;preserveAspectRatio=1:%s\a\n' \
        "$cols_w" "$rows_h" "$b64"
      return 0
    fi
  fi

  # Tier 2: chafa.
  if command -v chafa >/dev/null 2>&1; then
    chafa -s "${cols_w}x${rows_h}" "$icon_path" 2>/dev/null | while IFS= read -r imgline; do
      printf '%*s%s\n' "$pad" '' "$imgline"
    done
    return 0
  fi

  return 1
}

# render_panel -- the happy-path panel: icon, temp, condition, city, feels
# like, humidity/wind line, and an optional stale hint.
render_panel() {
  local city="$1" temp="$2" condition="$3" feels="$4" humidity="$5" \
        wind="$6" icon_path="$7" category="$8" is_day="$9" stale="${10}" age_min="${11}"

  blank_lines 2

  # Sized for a glance panel: a handful of terminal rows/columns, not the
  # full pane -- one small element above a short list of lines, not a
  # full-bleed image (contrast gallery.backgrounds/backgrounds.sh).
  local cols icon_cols=18 icon_rows=9 pad
  cols="$(term_cols)"
  pad=$(( (cols - icon_cols) / 2 ))
  [[ "$pad" -lt 0 ]] && pad=0

  if ! render_icon_inline "$icon_path" "$icon_cols" "$icon_rows" "$pad"; then
    center "$(fg "$GALLERY_ACCENT")$(glyph_for "$category" "$is_day")${RESET}"
  fi

  printf '\n'
  center "$(fg "$GALLERY_FG")${BOLD}${temp}${RESET}  $(fg "$GALLERY_MUTED")${condition}${RESET}"
  center "$(fg "$GALLERY_MUTED")${city}${RESET}"
  printf '\n'
  center "$(fg "$GALLERY_FG")Feels like ${feels}${RESET}"
  center "$(fg "$GALLERY_FG")${humidity} · ${wind}${RESET}"

  if [[ "$stale" == "1" ]]; then
    printf '\n'
    center "$(fg "$GALLERY_MUTED")stale, ${age_min} min old${RESET}"
  fi

  printf '\n'
  center "$(fg "$GALLERY_MUTED")press any key to close${RESET}"
}

# --- fetch -------------------------------------------------------------
#
# Ported near-verbatim from widget_runner.sh's rate-limited, mutex-guarded
# fetch block. Only the paths (CACHE_DIR under ~/.cache/gallery/weather
# instead of $HTOP_TEMP_DIR) and the source of q/appid/units (resolved
# local vars instead of WEATHER_* env vars) differ.
fetch_if_due() {
  local location="$1" api_key="$2" units="$3"
  local now stamp_age

  now=$(date +%s)
  stamp_age=$FETCH_INTERVAL
  [[ -f "$STAMP" ]] && stamp_age=$(( now - $(stat -f %m "$STAMP" 2>/dev/null || echo 0) ))

  [[ "$stamp_age" -ge "$FETCH_INTERVAL" ]] || return 0

  # Reap a lock orphaned by a killed runner (a fetch takes at most ~10s).
  [[ -d "$LOCK" ]] && find "$LOCK" -maxdepth 0 -mmin +2 -exec rmdir {} \; 2>/dev/null

  mkdir "$LOCK" 2>/dev/null || return 0   # someone else is already fetching
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT
  touch "$STAMP"   # count the attempt, pass or fail

  local tmp http_code
  tmp="${CACHE}.tmp.$$"
  http_code=$(curl -sS -G \
    --connect-timeout 5 --max-time 10 \
    --data-urlencode "q=${location}" \
    --data-urlencode "appid=${api_key}" \
    --data-urlencode "units=${units}" \
    -o "$tmp" -w '%{http_code}' \
    "https://api.openweathermap.org/data/2.5/weather" 2>/dev/null)

  # Validate before publishing so a garbage body never replaces good data.
  if [[ "$http_code" == "200" ]] && python3 -c \
    'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if int(d.get("cod",0))==200 else 1)' \
    "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$CACHE"   # atomic publish, same volume
  else
    rm -f "$tmp"
  fi

  rmdir "$LOCK" 2>/dev/null || true
  trap - EXIT
}

# parse_cache -- reads CACHE and prints a 0x1F-delimited record (see
# read_state's comment on why not tab: icon_path is legitimately often
# empty, and bash `read` would otherwise swallow it) for the happy-path
# panel, or nothing (exit 1) if CACHE is missing/corrupt. The ICON_MAP
# table and classify() are copied EXACTLY from widget_runner.sh (all
# branches) -- this is the one piece of this script that must stay a
# byte-for-byte match to the reference's condition-code mapping.
parse_cache() {
  python3 - "$CACHE" "$ICONS_DIR" "$1" "$2" "$STALE_AFTER" <<'PYEOF'
import json, os, sys, time

cache, icons_dir, icon_set, units, stale_after = sys.argv[1:6]

try:
    with open(cache, encoding="utf-8") as f:
        w = json.load(f)
except Exception:
    sys.exit(1)

# OWM condition class -> (meteocons day, meteocons night, EF day, EF night).
# meteocons-line and meteocons-fill share filenames, so one table serves
# both (and weather-icons, if ever installed alongside them).
ICON_MAP = {
    "thunder":  ("thunderstorms-day", "thunderstorms-night", "wi-thunderstorm", "wi-thunderstorm"),
    "drizzle":  ("drizzle",           "drizzle",             "wi-sprinkle",     "wi-sprinkle"),
    "rain":     ("rain",              "rain",                "wi-rain",         "wi-rain"),
    "sleet":    ("sleet",             "sleet",               "wi-sleet",        "wi-sleet"),
    "snow":     ("snow",              "snow",                "wi-snow",         "wi-snow"),
    "mist":     ("mist",              "mist",                "wi-day-fog",      "wi-night-fog"),
    "smoke":    ("smoke",             "smoke",               "wi-smoke",        "wi-smoke"),
    "haze":     ("haze-day",          "haze-night",          "wi-day-haze",     "wi-night-fog"),
    "dust":     ("dust-day",          "dust-night",          "wi-dust",         "wi-dust"),
    "fog":      ("fog-day",           "fog-night",           "wi-day-fog",      "wi-night-fog"),
    "wind":     ("wind",              "wind",                "wi-strong-wind",  "wi-strong-wind"),
    "tornado":  ("tornado",           "tornado",             "wi-tornado",      "wi-tornado"),
    "clear":    ("clear-day",         "clear-night",         "wi-day-sunny",    "wi-night-clear"),
    "partly":   ("partly-cloudy-day", "partly-cloudy-night", "wi-day-cloudy",   "wi-night-alt-cloudy"),
    "broken":   ("overcast-day",      "overcast-night",      "wi-cloudy",       "wi-cloudy"),
    "overcast": ("overcast",          "overcast",            "wi-cloudy",       "wi-cloudy"),
}

def classify(cid):
    if 200 <= cid <= 232:            return "thunder"   # 2xx thunderstorm
    if 300 <= cid <= 321:            return "drizzle"   # 3xx drizzle
    if cid == 511:                   return "sleet"     # freezing rain
    if 500 <= cid <= 531:            return "rain"      # 5xx rain / showers
    if 611 <= cid <= 616:            return "sleet"     # sleet / rain+snow mix
    if 600 <= cid <= 622:            return "snow"      # snow / snow showers
    if cid == 701:                   return "mist"
    if cid == 711:                   return "smoke"
    if cid == 721:                   return "haze"
    if cid in (731, 751, 761, 762): return "dust"      # dust whirls/sand/dust/ash
    if cid == 741:                   return "fog"
    if cid == 771:                   return "wind"      # squall
    if cid == 781:                   return "tornado"
    if cid == 800:                   return "clear"
    if cid in (801, 802):           return "partly"    # few / scattered clouds
    if cid == 803:                   return "broken"    # broken clouds
    return "overcast"                                   # 804 + forward-compatible fallback

try:
    cid = int(w["weather"][0]["id"])
    is_day = not w["weather"][0].get("icon", "01d").endswith("n")
except Exception:
    sys.exit(1)

category = classify(cid)
m_day, m_night, wi_day, wi_night = ICON_MAP[category]
if icon_set == "weather-icons":
    name, fallback = (wi_day if is_day else wi_night), "wi-cloudy"
else:
    name, fallback = (m_day if is_day else m_night), "cloudy"

icon_path = ""
for cand in (name, fallback):
    p = os.path.join(icons_dir, icon_set, cand + ".svg")
    if os.path.isfile(p):
        icon_path = p
        break

speed_unit = "m/s" if units == "metric" else "mph"
wind_src = w.get("wind", {})
compass = ""
if wind_src.get("deg") is not None:
    pts = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    compass = " " + pts[int((wind_src["deg"] + 22.5) // 45) % 8]

age = int(time.time() - os.path.getmtime(cache))
stale = "1" if age > int(stale_after) else "0"

try:
    fields = [
        w.get("name", "") or "",
        "%d°" % round(w["main"]["temp"]),
        (w["weather"][0].get("description", "") or "").capitalize(),
        "%d°" % round(w["main"]["feels_like"]),
        "%d%%" % w["main"]["humidity"],
        "%.1f %s%s" % (wind_src.get("speed", 0), speed_unit, compass),
        icon_path,
        category,
        "1" if is_day else "0",
        stale,
        str(age // 60),
    ]
except Exception:
    sys.exit(1)

sys.stdout.write("\x1f".join(fields))
PYEOF
}

# --- main -------------------------------------------------------------

# Hide the cursor for the lifetime of the panel and always put it back, on
# any exit path including a signal. chafa used to hide it as a side effect
# of its own output; the inline-image path does not, so it is done here
# explicitly rather than depending on a renderer's incidental behaviour.
if [[ -t 1 ]]; then
  printf '\033[?25l'
  trap 'printf "\033[?25h"' EXIT INT TERM
fi

mkdir -p "$CACHE_DIR" 2>/dev/null || true

api_key="$(resolve_api_key)"
if [[ -z "$api_key" ]]; then
  render_not_configured
  wait_for_key
  exit 0
fi

IFS=$'\x1f' read -r location units icon_set <<<"$(read_state)"

fetch_if_due "$location" "$api_key" "$units"

if [[ ! -f "$CACHE" ]]; then
  render_unavailable "$location"
  wait_for_key
  exit 0
fi

record="$(parse_cache "$icon_set" "$units")"
if [[ -z "$record" ]]; then
  render_unavailable "$location"
  wait_for_key
  exit 0
fi

IFS=$'\x1f' read -r city temp condition feels humidity wind icon_path category is_day stale age_min <<<"$record"

render_panel "$city" "$temp" "$condition" "$feels" "$humidity" "$wind" \
  "$icon_path" "$category" "$is_day" "$stale" "$age_min"
wait_for_key
exit 0
