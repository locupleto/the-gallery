#!/usr/bin/env python3
"""render-theme.py -- render the active Gallery theme into every consumer
this repo knows about: a CSS custom-property sheet, a JSON token dump, an
iTerm2 dynamic profile (plus a theme file each for Ghostty, kitty and
WezTerm), and a shell fragment (also consumed by the crystal
widgets and by bin/gallery-borders for the JankyBorders focus outline).

Reads ~/.config/gallery/themes/current/colors.toml (the `current` symlink
Gallery.spoon and `gallery theme set` manage) and
~/.config/gallery/state/borders.json (the width/bright prefs `gallery
borders` writes -- missing/garbage means the defaults, see
read_borders_prefs), and writes:

  ~/.config/gallery/state/theme.css
  ~/.config/gallery/state/theme.json
  ~/.config/gallery/state/theme.sh
  ~/.config/gallery/state/crystal.css
  ~/Library/Application Support/iTerm2/DynamicProfiles/gallery-theme.json
  ~/Library/Application Support/iTerm2/DynamicProfiles/gallery-console.json
  ~/.config/gallery/state/terminals/{ghostty.conf,kitty.conf,wezterm.lua,
    gallery-osc.sh,glass.env} (see "Ghostty, kitty, WezTerm" below)
  ~/.config/btop/themes/gallery.theme
  ~/.config/btop/btop.conf (color_theme key only, rewritten in place)
  ~/Library/Application Support/superfile/theme/gallery.toml
  ~/Library/Application Support/superfile/config.toml (theme and
    transparent_background keys only, rewritten in place)

theme.json and theme.sh (NOT theme.css) also carry the derived JankyBorders
tokens border_active/border_active_hex/border_inactive/border_width/
border_bright -- see build_border_tokens below. border_active/border_inactive
honour Omarchy's own hyprland_active_border / hyprland_inactive_border
override keys (Hyprland colour syntax: rgba(hex8)/rgb(hex6)/bare #rrggbb,
one or more space-separated colours, optional trailing "Ndeg"), translated
to JankyBorders' own `0xAARRGGBB` / `gradient(...)` syntax by
parse_hypr_gradient + janky_color.

stdlib only -- no third-party TOML parser, since the upstream files this
repo vendors (see tools/vendor-omarchy-themes.sh) are a flat `key = "value"`
TOML with no tables, arrays, or multi-line strings, which is trivial to
parse by hand and keeps this script dependency-free on any Python 3.

Two colors.toml shapes are understood, because upstream Omarchy's actual
schema (checked against basecamp/omarchy, all 22 themes, 2026-09) differs
from a flat 16-slot ANSI palette:

  - Omarchy's real schema: mode, accent, selection, muted, background,
    dark_background, darker_background, lighter_background, foreground,
    dark_foreground, light_foreground, bright_foreground, red, yellow,
    orange, green, cyan, blue, magenta, brown, bright_red, bright_yellow,
    bright_green, bright_cyan, bright_blue, bright_magenta. No cursor key,
    no color0..color15, no light.mode file -- light/dark is the `mode` key.
  - A hand-authored theme following the flat contract this repo also
    accepts: accent, cursor, foreground, background, selection_foreground,
    selection_background, color0..color15, plus an optional empty
    light.mode file next to colors.toml instead of a `mode` key.

Every derived token below prefers a literal key if the file has it, and
otherwise computes it from Omarchy's real keys -- so both shapes render
identically.

This script is the SINGLE derivation of every Gallery theme token, including
the Gallery-only `surface`/`border` pair (see mix_hex below). state/theme.json
is not just a dump for external consumers: Gallery.spoon/lib/theme.lua reads
it back (when its `name` matches the resolved current theme) instead of
re-deriving tokens itself, so this script's output is authoritative -- see
the header comment atop lib/theme.lua for the fallback relationship.
"""
from __future__ import annotations

import json
import math
import os
import re
import subprocess
import sys
from pathlib import Path

CONFIG_DIR = Path(os.environ.get("GALLERY_CONFIG_DIR", str(Path.home() / ".config" / "gallery")))
THEMES_DIR = CONFIG_DIR / "themes"
CURRENT_LINK = THEMES_DIR / "current"
STATE_DIR = CONFIG_DIR / "state"
ITERM_DYNAMIC_PROFILES_DIR = (
    Path.home() / "Library" / "Application Support" / "iTerm2" / "DynamicProfiles"
)
ITERM_PROFILE_PATH = ITERM_DYNAMIC_PROFILES_DIR / "gallery-theme.json"
CONSOLE_STATE_PATH = STATE_DIR / "console.json"
WIDGETS_STATE_PATH = STATE_DIR / "widgets.json"
FONT_STATE_PATH = STATE_DIR / "font.json"
CRYSTAL_CSS_PATH = STATE_DIR / "crystal.css"
BORDERS_STATE_PATH = STATE_DIR / "borders.json"
ITERM_CONSOLE_PROFILE_PATH = ITERM_DYNAMIC_PROFILES_DIR / "gallery-console.json"
BTOP_CONFIG_DIR = Path.home() / ".config" / "btop"
BTOP_THEME_PATH = BTOP_CONFIG_DIR / "themes" / "gallery.theme"
BTOP_CONF_PATH = BTOP_CONFIG_DIR / "btop.conf"
SUPERFILE_CONFIG_DIR = Path.home() / "Library" / "Application Support" / "superfile"
SUPERFILE_THEME_PATH = SUPERFILE_CONFIG_DIR / "theme" / "gallery.toml"
SUPERFILE_CONF_PATH = SUPERFILE_CONFIG_DIR / "config.toml"

ANSI_NAMES = [
    "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
    "bright_black", "bright_red", "bright_green", "bright_yellow",
    "bright_blue", "bright_magenta", "bright_cyan", "bright_white",
]


def parse_flat_toml(text: str) -> dict:
    """Parse the flat `key = "value"` TOML colors.toml uses. No tables, no
    arrays, no multi-line strings -- just comments, blank lines, and
    `key = "value"` (or bare/numeric) assignments."""
    result: dict[str, str] = {}
    for lineno, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        # Strip an inline comment that starts after the value (only safe
        # once we know the value isn't itself a quoted string containing '#').
        if value.startswith('"') and value.endswith('"') and len(value) >= 2:
            value = value[1:-1]
        elif value.startswith("'") and value.endswith("'") and len(value) >= 2:
            value = value[1:-1]
        else:
            if "#" in value:
                value = value.split("#", 1)[0].strip()
        result[key] = value
    return result


def hex_to_rgb_int(value: str) -> tuple[int, int, int]:
    v = value.strip().lstrip("#")
    if len(v) == 3:
        v = "".join(c * 2 for c in v)
    if len(v) != 6:
        raise ValueError(f"not a #rrggbb color: {value!r}")
    return int(v[0:2], 16), int(v[2:4], 16), int(v[4:6], 16)


def hex_to_rgb_float(value: str) -> tuple[float, float, float]:
    r, g, b = hex_to_rgb_int(value)
    return r / 255.0, g / 255.0, b / 255.0


def clamp_byte(n: float) -> int:
    """Port of Gallery.spoon/lib/theme.lua's clampByte: clamp to 0..255 and
    round half-up (Lua's math.floor(n + 0.5)), NOT Python's banker's-rounding
    round() -- the two disagree on exact .5 boundaries, which matters for
    byte-identical hex output with the Lua side."""
    if n < 0:
        return 0
    if n > 255:
        return 255
    return int(math.floor(n + 0.5))


def mix_hex(from_hex: str, toward_hex: str, pct: float) -> str:
    """Port of Gallery.spoon/lib/theme.lua's mixHex: mix `from_hex` toward
    `toward_hex` by `pct` (0..1) and return "#rrggbb". Falls back to
    `from_hex` unchanged if either color fails to parse, exactly like the
    Lua original (which returns fromHex when hexToRgb yields nil)."""
    try:
        fr, fg, fb = hex_to_rgb_int(from_hex)
        tr, tg, tb = hex_to_rgb_int(toward_hex)
    except ValueError:
        return from_hex
    r = clamp_byte(fr + (tr - fr) * pct)
    g = clamp_byte(fg + (tg - fg) * pct)
    b = clamp_byte(fb + (tb - fb) * pct)
    return f"#{r:02x}{g:02x}{b:02x}"


# --- Hyprland colour syntax -> JankyBorders colour syntax -------------------
#
# Omarchy's Hyprland template feeds `hyprland_active_border` /
# `hyprland_inactive_border` straight into Hyprland's `general:col.*_border`
# config keys, whose colour syntax is one or more space-separated colour
# tokens -- `rgba(RRGGBBAA)`, `rgb(RRGGBB)`, or a bare `#rrggbb` -- plus an
# optional trailing `NNNdeg` angle when there is more than one colour
# (Hyprland's own gradient). JankyBorders (see `man borders`) instead wants
# a single `0xAARRGGBB`, or `gradient(top_left=0xAARRGGBB,
# bottom_right=0xAARRGGBB)` / `gradient(top_right=...,bottom_left=...)` for
# a two-stop gradient, picking the axis from the angle. These two helpers
# convert one to the other; janky_color does the final assembly.

_HYPR_COLOR_RE = re.compile(r"rgba?\([0-9a-fA-F]+\)|#[0-9a-fA-F]{3,8}")
_HYPR_ANGLE_RE = re.compile(r"(\d+)\s*deg\b")


def parse_hypr_color(token: str) -> tuple[str, str]:
    """Parse one Hyprland colour token -- rgba(RRGGBBAA), rgb(RRGGBB), or a
    bare #rrggbb/#rgb -- into (hex6, alpha2), both lowercase, no leading
    "#". Unrecognized input falls back to opaque black rather than raising,
    since a hand-edited colors.toml should degrade, not crash the renderer."""
    t = token.strip()

    m = re.fullmatch(r"rgba\(([0-9a-fA-F]{8})\)", t)
    if m:
        h = m.group(1).lower()
        return h[0:6], h[6:8]

    m = re.fullmatch(r"rgb\(([0-9a-fA-F]{6})\)", t)
    if m:
        return m.group(1).lower(), "ff"

    m = re.fullmatch(r"#?([0-9a-fA-F]{6})", t)
    if m:
        return m.group(1).lower(), "ff"

    m = re.fullmatch(r"#?([0-9a-fA-F]{3})", t)
    if m:
        h = m.group(1).lower()
        return "".join(c * 2 for c in h), "ff"

    return "000000", "ff"


def parse_hypr_gradient(value: str) -> tuple[list[tuple[str, str]], int | None]:
    """Parse a full Hyprland colour value -- one or more colour tokens plus
    an optional trailing angle, e.g. "rgba(26a269ee) rgba(2ec27eee) 45deg"
    -- into (colours, angle). colours is a list of (hex6, alpha2) pairs in
    the order they appear; angle is None if no "NNNdeg" token is present.
    A value with no recognizable colour token at all falls back to a single
    opaque-black colour, same as parse_hypr_color's own fallback."""
    colours = [parse_hypr_color(m.group(0)) for m in _HYPR_COLOR_RE.finditer(value)]
    if not colours:
        colours = [("000000", "ff")]
    angle_match = _HYPR_ANGLE_RE.search(value)
    angle = int(angle_match.group(1)) if angle_match else None
    return colours, angle


def janky_color(colours: list[tuple[str, str]], angle: int | None) -> str:
    """Render (colours, angle) -- parse_hypr_gradient's own return shape --
    into a JankyBorders colour expression. One colour: a bare 0xAARRGGBB.
    Two or more: a gradient using the first and last colour (Omarchy's own
    Hyprland gradients are two-stop in practice), on the top_left/
    bottom_right diagonal when the angle is absent or in [0,90] / >=270,
    and on the top_right/bottom_left diagonal for an angle in (90,270)."""

    def argb(pair: tuple[str, str]) -> str:
        hex6, alpha2 = pair
        return f"0x{alpha2}{hex6}"

    if len(colours) <= 1:
        return argb(colours[0])

    first = argb(colours[0])
    last = argb(colours[-1])
    if angle is not None and 90 < angle < 270:
        return f"gradient(top_right={first},bottom_left={last})"
    return f"gradient(top_left={first},bottom_right={last})"


def build_border_tokens(tokens: dict, raw: dict, prefs: dict) -> dict:
    """Derive the JankyBorders-facing tokens (not part of the CSS/`border`
    token theme.lua consumes): border_active, border_active_hex,
    border_inactive, border_width, border_bright.

    border_active honours Omarchy's own `hyprland_active_border` override
    key when the current theme's colors.toml defines it, else falls back to
    `accent`; border_inactive honours `hyprland_inactive_border` when
    present, else stays fully transparent (JankyBorders' own
    "no inactive outline" value). When prefs["bright"] is set, every
    active-border colour is mixed toward bright_foreground (falling back to
    light_foreground, then foreground) at a fixed 0.40 ratio via mix_hex,
    alpha preserved -- border_active_hex reports the (possibly mixed)
    first colour as "#rrggbb", for status lines/swatches."""
    active_raw = raw.get("hyprland_active_border") or tokens["accent"]
    inactive_raw = raw.get("hyprland_inactive_border")

    active_colours, active_angle = parse_hypr_gradient(active_raw)

    bright = bool(prefs.get("bright", False))
    if bright:
        bright_target = (
            tokens.get("bright_foreground")
            or tokens.get("light_foreground")
            or tokens["foreground"]
        )
        active_colours = [
            (mix_hex(f"#{hex6}", bright_target, 0.40).lstrip("#"), alpha2)
            for hex6, alpha2 in active_colours
        ]

    border_active = janky_color(active_colours, active_angle)
    border_active_hex = f"#{active_colours[0][0]}"

    if inactive_raw:
        inactive_colours, inactive_angle = parse_hypr_gradient(inactive_raw)
        border_inactive = janky_color(inactive_colours, inactive_angle)
    else:
        border_inactive = "0x00000000"

    return {
        "border_active": border_active,
        "border_active_hex": border_active_hex,
        "border_inactive": border_inactive,
        "border_width": int(prefs.get("width", 5)),
        "border_bright": bright,
    }


def resolve_current_theme_dir() -> Path:
    if not CURRENT_LINK.exists():
        sys.exit(
            f"render-theme: no current theme: {CURRENT_LINK} does not exist "
            "(run 'gallery theme set <name>' first)"
        )
    resolved = CURRENT_LINK.resolve()
    if not resolved.is_dir():
        sys.exit(f"render-theme: current theme target is not a directory: {resolved}")
    return resolved


def read_console_mode() -> str:
    """Read the iTerm console mode ("theme" or "native") that `gallery
    console theme|native|toggle` records in CONSOLE_STATE_PATH. Defaults to
    "native" (untouched Default colours) if the file is missing, unreadable,
    or carries anything other than {"mode": "theme"|"native"} -- same
    missing-file-means-default tolerance as bg_read_choice in bin/gallery."""
    try:
        data = json.loads(CONSOLE_STATE_PATH.read_text())
    except (OSError, ValueError):
        return "native"
    if isinstance(data, dict):
        mode = data.get("mode")
        if mode in ("theme", "native"):
            return mode
    return "native"


def read_widgets_mode() -> str:
    """Read the Übersicht crystal-widgets mode ("theme" or "native") that
    `gallery widgets theme|native|toggle` records in WIDGETS_STATE_PATH.
    Same contract and defaults as read_console_mode: missing, unreadable,
    or anything other than {"mode": "theme"|"native"} means "native", i.e.
    the widgets keep their own shipped colours."""
    try:
        data = json.loads(WIDGETS_STATE_PATH.read_text())
    except (OSError, ValueError):
        return "native"
    if isinstance(data, dict):
        mode = data.get("mode")
        if mode in ("theme", "native"):
            return mode
    return "native"


def read_font_prefs() -> dict | None:
    """Read the Gallery-wide monospace font preference that `gallery font
    set|native` records in FONT_STATE_PATH: {"family": str, "size": int,
    "weight": str}. Same missing-file-means-nothing-recorded tolerance as
    read_console_mode/read_widgets_mode, except there is no sentinel value
    for "native" here (unlike mode = "theme"|"native") -- native is simply
    the absence of a usable file, so this returns None instead of a string,
    and every caller below skips adding font keys entirely when it does."""
    try:
        data = json.loads(FONT_STATE_PATH.read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    family = data.get("family")
    size = data.get("size")
    weight = data.get("weight")
    if (
        isinstance(family, str)
        and family.strip()
        and isinstance(size, int)
        and not isinstance(size, bool)
        and isinstance(weight, str)
        and weight.strip()
    ):
        return {"family": family.strip(), "size": size, "weight": weight.strip()}
    return None


def resolve_iterm_font(family: str, weight: str) -> str | None:
    """Resolve a (family, weight) pair to the PostScript name fc-list knows
    it by, e.g. ("SauceCodePro Nerd Font Mono", "SemiBold") ->
    "SauceCodeProNFM-SemiBold". iTerm2's "Normal Font" profile key wants
    "<PostScriptName> <size>", not the human family/style pair -- there is
    no other reliable way to get from one to the other than asking
    fontconfig, which is why this shells out to fc-list rather than trying
    to derive it. Returns None (never raises) if fc-list is missing, the
    face is not installed, or its output cannot be parsed -- callers must
    treat that as "skip the font keys, warn, keep rendering"."""
    pattern = f":family={family}:style={weight}"
    try:
        result = subprocess.run(
            ["fc-list", pattern, "-f", "%{postscriptname}\n"],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as exc:
        print(f"render-theme: fc-list not available, skipping font: {exc}", file=sys.stderr)
        return None
    if result.returncode != 0:
        print(
            f"render-theme: fc-list failed for {family!r} {weight!r}: "
            f"{result.stderr.strip()}",
            file=sys.stderr,
        )
        return None
    for line in result.stdout.splitlines():
        line = line.strip()
        if line:
            return line
    print(
        f"render-theme: no installed font matches family={family!r} style={weight!r}, "
        "skipping font keys (see: gallery font list)",
        file=sys.stderr,
    )
    return None


def read_borders_prefs() -> dict:
    """Read the JankyBorders picker prefs (`gallery borders width|bright`)
    out of BORDERS_STATE_PATH: {"width": int, "bright": bool}. Same
    missing-file/garbage-means-defaults tolerance as read_console_mode --
    defaults are {"width": 5, "bright": False}. width is clamped to 1..12
    regardless of what is on disk, in case it was hand-edited."""
    defaults = {"width": 5, "bright": False}
    try:
        data = json.loads(BORDERS_STATE_PATH.read_text())
    except (OSError, ValueError):
        return dict(defaults)
    if not isinstance(data, dict):
        return dict(defaults)

    width = data.get("width")
    if isinstance(width, bool) or not isinstance(width, int):
        width = defaults["width"]
    width = max(1, min(12, width))

    bright = data.get("bright")
    if not isinstance(bright, bool):
        bright = defaults["bright"]

    return {"width": width, "bright": bright}


def theme_name_from_dir(theme_dir: Path) -> str:
    # Prefer the symlink's immediate target name (not the fully resolved
    # real path) so the reported name matches what `gallery theme set` used,
    # even if the themes dir itself is reached through another symlink.
    try:
        target = os.readlink(CURRENT_LINK)
        return Path(target).name
    except OSError:
        return theme_dir.name


def build_tokens(raw: dict, theme_dir: Path) -> tuple[dict, bool]:
    """Return (tokens, light) where tokens is the flat dict of every raw
    key (minus `mode`) plus the normalized contract keys (cursor,
    selection_foreground, selection_background, color0..color15)."""

    def pick(*keys, default=None):
        for k in keys:
            if k in raw and raw[k]:
                return raw[k]
        return default

    background = pick("background", default="#000000")
    foreground = pick("foreground", default="#ffffff")
    accent = pick("accent", default=foreground)

    mode = raw.get("mode")
    if mode is not None:
        light = mode.strip().lower() == "light"
    else:
        light = (theme_dir / "light.mode").exists()

    tokens = {k: v for k, v in raw.items() if k != "mode"}

    tokens.setdefault("accent", accent)
    tokens.setdefault("background", background)
    # The Gallery UI surface -- QML plugin panels and other non-terminal
    # chrome -- is painted with the theme's deepest tone. Terminal windows
    # (floating or tiled) use the ordinary background under one shared glass
    # instead, as Omarchy gives every window the same opacity. Falls back to
    # the ordinary background for any theme that omits darker_background.
    tokens["surface_background"] = pick(
        "darker_background", "background", default=background
    )
    tokens.setdefault("foreground", foreground)
    tokens["cursor"] = pick("cursor", "accent", default=accent)
    tokens["selection_background"] = pick(
        "selection_background", "selection", "background", default=background
    )
    tokens["selection_foreground"] = pick(
        "selection_foreground", "foreground", default=foreground
    )

    color_fallbacks = {
        "color0": ("dark_background", "background"),
        "color1": ("red",),
        "color2": ("green",),
        "color3": ("yellow",),
        "color4": ("blue",),
        "color5": ("magenta",),
        "color6": ("cyan",),
        "color7": ("foreground",),
        "color8": ("muted", "dark_foreground"),
        "color9": ("bright_red", "red"),
        "color10": ("bright_green", "green"),
        "color11": ("bright_yellow", "yellow"),
        "color12": ("bright_blue", "blue"),
        "color13": ("bright_magenta", "magenta"),
        "color14": ("bright_cyan", "cyan"),
        "color15": ("bright_foreground", "foreground"),
    }
    for color_key, fallback_keys in color_fallbacks.items():
        if color_key in raw and raw[color_key]:
            continue
        tokens[color_key] = pick(*fallback_keys, default=foreground)

    # surface/border: Gallery.spoon/lib/theme.lua's own extra UI tokens
    # (not part of any upstream Omarchy shape) -- derived here, byte-
    # identically to theme.lua's mixHex-based derivation, so theme.lua can
    # consume this script's theme.json instead of re-deriving them itself.
    # surface prefers Omarchy's own lighter_background verbatim; border is
    # always the mix (no upstream key to prefer instead).
    surface_pref = tokens.get("lighter_background")
    tokens["surface"] = surface_pref if surface_pref else mix_hex(
        tokens["background"], tokens["foreground"], 0.12
    )
    tokens["border"] = mix_hex(tokens["background"], tokens["foreground"], 0.25)

    return tokens, light


def css_var_name(key: str) -> str:
    return "--gallery-" + key.replace("_", "-")


def render_css(tokens: dict, font_prefs: dict | None) -> str:
    lines = [":root {"]
    for key, value in tokens.items():
        lines.append(f"  {css_var_name(key)}:{value};")
    lines.append(f"  {css_var_name('muted')}:{tokens['color8']};")
    lines.append(f"  {css_var_name('danger')}:{tokens['color1']};")
    lines.append(f"  {css_var_name('success')}:{tokens['color2']};")
    lines.append(f"  {css_var_name('warning')}:{tokens['color3']};")
    lines.append(f"  {css_var_name('info')}:{tokens['color4']};")
    # `gallery font set` -- absent entirely in native mode (see
    # read_font_prefs), same "no keys at all means inherit" contract as the
    # iTerm profiles above.
    if font_prefs:
        family = font_prefs["family"].replace('"', '\\"')
        lines.append(f'  {css_var_name("font-family")}:"{family}";')
        lines.append(f'  {css_var_name("font-weight")}:{font_prefs["weight"]};')
    lines.append("}")
    return "\n".join(lines) + "\n"


def render_json(tokens: dict, name: str, light: bool, border_tokens: dict) -> str:
    payload = dict(tokens)
    payload["name"] = name
    payload["light"] = light
    payload["muted"] = tokens["color8"]
    payload["danger"] = tokens["color1"]
    payload["success"] = tokens["color2"]
    payload["warning"] = tokens["color3"]
    payload["info"] = tokens["color4"]
    payload.update(border_tokens)
    return json.dumps(payload, indent=2, sort_keys=True) + "\n"


def render_shell(tokens: dict, name: str, border_tokens: dict, widgets_mode: str) -> str:
    def q(value: str) -> str:
        return "'" + str(value).replace("'", "'\\''") + "'"

    lines = [
        "# Generated by tools/render-theme.py -- do not edit by hand.",
        f"export GALLERY_THEME_NAME={q(name)}",
        f"export GALLERY_BG={q(tokens['surface_background'])}",
        f"export GALLERY_FG={q(tokens['foreground'])}",
        f"export GALLERY_ACCENT={q(tokens['accent'])}",
        f"export GALLERY_MUTED={q(tokens['color8'])}",
    ]
    for i in range(16):
        lines.append(f"export GALLERY_COLOR{i}={q(tokens[f'color{i}'])}")

    # Crystal widgets (Übersicht): the CPU/mem/swap bar fill, read by the
    # widgets' crystal_common.sh on every refresh. Only exported while
    # `gallery widgets theme` is in force -- in native mode the line is
    # absent and crystal_common.sh keeps the widgets' own shipped colour.
    if widgets_mode == "theme":
        r, g, b = hex_to_rgb_int(tokens["accent"])
        lines.append(f"export CRYSTAL_BAR_COLOR='rgba({r},{g},{b},1.0)'")

    # JankyBorders focus-outline tokens -- see build_border_tokens. Consumed
    # by bin/gallery-borders, which falls back to deriving these itself from
    # GALLERY_ACCENT alone when they are absent (an older, un-rerendered
    # theme.sh).
    lines.append(f"export GALLERY_BORDER_ACTIVE={q(border_tokens['border_active'])}")
    lines.append(f"export GALLERY_BORDER_ACTIVE_HEX={q(border_tokens['border_active_hex'])}")
    lines.append(f"export GALLERY_BORDER_INACTIVE={q(border_tokens['border_inactive'])}")
    lines.append(f"export GALLERY_BORDER_WIDTH={q(border_tokens['border_width'])}")
    lines.append(f"export GALLERY_BORDER_BRIGHT={q('1' if border_tokens['border_bright'] else '0')}")
    return "\n".join(lines) + "\n"


CRYSTAL_STATIC_ALPHAS = (20, 45, 65, 70, 75, 85, 90, 92)


def render_crystal_css(tokens: dict, name: str, widgets_mode: str) -> str:
    """Render the CSS custom properties the Übersicht crystal widgets read
    through their crystal-theme.widget (which cats this file every couple of
    seconds and injects it into the shared widget document).

    Two colours only, by design: --crystal-static (the theme's lightest
    foreground, replacing the widgets' shipped white for text, clock hands
    and markers) with a few fixed-alpha variants --crystal-static-NN, and
    --crystal-dynamic (accent, the CPU/mem/swap bar fill). In native mode
    the file carries no declarations at all, so every var(--crystal-*,
    fallback) in the widgets falls back to its shipped colour."""
    header = f"/* Generated by tools/render-theme.py -- do not edit by hand. theme: {name}, widgets: {widgets_mode} */"
    if widgets_mode != "theme":
        return header + "\n"
    static = (
        tokens.get("bright_foreground")
        or tokens.get("light_foreground")
        or tokens["foreground"]
    )
    sr, sg, sb = hex_to_rgb_int(static)
    ar, ag, ab = hex_to_rgb_int(tokens["accent"])
    lines = [header, ":root {", f"  --crystal-static:{static};"]
    for alpha in CRYSTAL_STATIC_ALPHAS:
        lines.append(f"  --crystal-static-{alpha}:rgba({sr},{sg},{sb},{alpha / 100:.2f});")
    lines.append(f"  --crystal-dynamic:rgba({ar},{ag},{ab},1.0);")
    lines.append("}")
    return "\n".join(lines) + "\n"


def iterm_color_dict(hex_value: str) -> dict:
    r, g, b = hex_to_rgb_float(hex_value)
    return {
        "Red Component": r,
        "Green Component": g,
        "Blue Component": b,
        "Alpha Component": 1.0,
        "Color Space": "sRGB",
    }


def render_iterm_profile(tokens: dict, name: str, font_normal: str | None) -> str:
    profile = {
        "Name": "Gallery",
        "Guid": "gallery-theme",
        "Background Color": iterm_color_dict(tokens["background"]),
        "Foreground Color": iterm_color_dict(tokens["foreground"]),
        "Cursor Color": iterm_color_dict(tokens["cursor"]),
        "Cursor Text Color": iterm_color_dict(tokens["background"]),
        "Selection Color": iterm_color_dict(tokens["selection_background"]),
        "Selected Text Color": iterm_color_dict(tokens["selection_foreground"]),
        "Use Separate Colors for Light and Dark Mode": False,
        # A Gallery window is a floating TUI host (see bin/gallery-tui), not
        # an everyday terminal: it should behave like a modal utility panel
        # that vanishes silently the moment its command (btop, fzf, ...)
        # exits, never prompting and never leaving a dead session on screen.
        "Window Type": 0,
        "Blinking Cursor": False,
        "Scrollback Lines": 1000,
        "Unlimited Scrollback": False,
        "Silence Bell": True,
        "Flashing Bell": False,
        "Visual Bell": False,
        "Close Sessions On End": True,
        "Prompt Before Closing 2": 0,
        # The same glass as the themed console, so a floating TUI reads like
        # the tiles behind it -- Omarchy applies one opacity rule to every
        # window, floating or tiled.
        "Transparency": CONSOLE_TRANSPARENCY,
        "Blur": True,
        "Blur Radius": CONSOLE_BLUR_RADIUS,
    }
    for i in range(16):
        profile[f"Ansi {i} Color"] = iterm_color_dict(tokens[f"color{i}"])
    if font_normal:
        # "Use Non-ASCII Font": False keeps Nerd Font private-use glyphs
        # (icons, powerline separators) coming from this same font instead
        # of iTerm's separate non-ASCII font slot -- see `gallery font`.
        profile["Normal Font"] = font_normal
        profile["Use Non-ASCII Font"] = False

    doc = {"Profiles": [profile]}
    return json.dumps(doc, indent=2, sort_keys=True) + "\n"


# iTerm2 "Transparency" is 0.0 (solid) .. 1.0 (invisible); "Blur Radius" is
# the frosted-glass radius iTerm applies behind a transparent window.
CONSOLE_TRANSPARENCY = 0.12
CONSOLE_BLUR_RADIUS = 9.0


def render_iterm_console_profile(
    tokens: dict, name: str, mode: str, font_normal: str | None
) -> str:
    """Render the "Console" dynamic profile: the user's everyday iTerm2
    terminal, NOT the floating Gallery TUI host. The mechanism (proven
    manually before this was automated) is iTerm2's own dynamic-profile
    parent/child inheritance: this profile carries
    "Dynamic Profile Parent Name": "Default", so iTerm resolves any key it
    does NOT itself define by falling through to the user's own "Default"
    profile (their Homebrew-shell colours, unrelated to Gallery). The user
    makes "Console" their default profile once, by hand, in iTerm2's
    Settings -- this script never touches which profile IS the default.

    native mode: the profile carries nothing but Name/Guid/parent, so it is
    byte-for-byte the inherited Default -- no color keys at all, meaning
    "iTerm console follows its own Default colours, Gallery has no opinion".

    theme mode: adds the active Gallery theme's colours as overrides, same
    token set render_iterm_profile uses for the floating Gallery profile,
    with the same background and glass (the floating profile matches this
    one, as Omarchy gives every window one opacity). No window-behaviour
    keys here (Close Sessions On End, Window Type, etc.) -- those make sense
    only for the floating, ephemeral Gallery TUI host, never for an
    always-open everyday terminal.

    font_normal (the resolved "<PostScriptName> <size>" from `gallery
    font set`, or None for "native") is only ever applied in theme mode --
    in native mode this profile carries no keys beyond Name/Guid/parent,
    so it stays byte-for-byte the inherited Default, font included.
    """
    profile = {
        "Name": "Console",
        "Guid": "gallery-console",
        "Dynamic Profile Parent Name": "Default",
    }
    if mode == "theme":
        profile["Use Separate Colors for Light and Dark Mode"] = False
        # Window glass, stated here rather than inherited: the user's Default
        # profile carries ~20% transparency + blur, which read too light over
        # a bright wallpaper. Keep the blur, darken the tint (less see-through).
        profile["Transparency"] = CONSOLE_TRANSPARENCY
        profile["Blur"] = True
        profile["Blur Radius"] = CONSOLE_BLUR_RADIUS
        profile["Background Color"] = iterm_color_dict(tokens["background"])
        profile["Foreground Color"] = iterm_color_dict(tokens["foreground"])
        profile["Bold Color"] = iterm_color_dict(tokens["foreground"])
        profile["Cursor Color"] = iterm_color_dict(tokens["cursor"])
        profile["Cursor Text Color"] = iterm_color_dict(tokens["background"])
        profile["Selection Color"] = iterm_color_dict(tokens["selection_background"])
        profile["Selected Text Color"] = iterm_color_dict(tokens["selection_foreground"])
        for i in range(16):
            profile[f"Ansi {i} Color"] = iterm_color_dict(tokens[f"color{i}"])
        if font_normal:
            profile["Normal Font"] = font_normal
            profile["Use Non-ASCII Font"] = False

    doc = {"Profiles": [profile]}
    return json.dumps(doc, indent=2, sort_keys=True) + "\n"


# --- Ghostty, kitty, WezTerm ----------------------------------------------------
#
# One file per terminal under state/terminals/, written on every render
# whatever terminal is configured (they are cheap, and `gallery terminal set`
# can then switch without a render of its own order). Each maps the same
# Gallery tokens: the 16 ANSI colours, background/foreground, cursor, the
# selection pair, the shared glass (CONSOLE_TRANSPARENCY inverted into an
# opacity, CONSOLE_BLUR_RADIUS) and -- only while `gallery font set` holds a
# preference -- the font family and size. bin/gallery-term reads two more
# outputs: gallery-osc.sh (the palette as OSC escapes, for a float window on a
# terminal with no per-window config) and glass.env (the glass values, for
# wezterm's --config).

TERMINALS_DIR = STATE_DIR / "terminals"


def glass_opacity() -> float:
    """The window opacity every terminal gets: iTerm2's Transparency is
    0.0 (solid) .. 1.0 (invisible), the other terminals take the opposite."""
    return round(1.0 - CONSOLE_TRANSPARENCY, 2)


def render_ghostty_conf(tokens: dict, name: str, font_prefs: dict | None) -> str:
    lines = [
        f"# Gallery theme: {name}",
        "# Generated by tools/render-theme.py -- do not edit by hand.",
        "# Pulled into ~/.config/ghostty/config by `gallery console theme`.",
        "",
    ]
    for i in range(16):
        lines.append(f"palette = {i}={tokens[f'color{i}']}")
    lines += [
        f"background = {tokens['background']}",
        f"foreground = {tokens['foreground']}",
        f"cursor-color = {tokens['cursor']}",
        f"cursor-text = {tokens['background']}",
        f"selection-background = {tokens['selection_background']}",
        f"selection-foreground = {tokens['selection_foreground']}",
        f"background-opacity = {glass_opacity():g}",
        f"background-blur = {int(CONSOLE_BLUR_RADIUS)}",
    ]
    if font_prefs:
        lines.append(f'font-family = "{font_prefs["family"]}"')
        lines.append(f"font-size = {font_prefs['size']}")
    return "\n".join(lines) + "\n"


def render_kitty_conf(tokens: dict, name: str, font_prefs: dict | None) -> str:
    lines = [
        f"# Gallery theme: {name}",
        "# Generated by tools/render-theme.py -- do not edit by hand.",
        "# Included from ~/.config/kitty/kitty.conf by `gallery console theme`,",
        "# and passed with --config to every floating Gallery window.",
        "",
        f"foreground {tokens['foreground']}",
        f"background {tokens['background']}",
        f"selection_foreground {tokens['selection_foreground']}",
        f"selection_background {tokens['selection_background']}",
        f"cursor {tokens['cursor']}",
        f"cursor_text_color {tokens['background']}",
    ]
    for i in range(16):
        lines.append(f"color{i} {tokens[f'color{i}']}")
    lines += [
        f"background_opacity {glass_opacity():g}",
        f"background_blur {int(CONSOLE_BLUR_RADIUS)}",
    ]
    if font_prefs:
        lines.append(f"font_family {font_prefs['family']}")
        lines.append(f"font_size {font_prefs['size']}")
    return "\n".join(lines) + "\n"


def lua_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def render_wezterm_lua(
    tokens: dict, name: str, font_prefs: dict | None, own_path: Path, console_mode: str
) -> str:
    """A Lua module returning a table of config keys, for the user's own
    wezterm.lua to merge (see `gallery console theme`). It puts itself on
    wezterm's config-reload watch list, so a theme change reloads running
    windows without any other step. The user's Lua is never edited, so the
    console mode is applied here instead: in native mode the table is empty
    and a wezterm that merges it keeps its own look."""

    def lua_list(keys: list[str]) -> str:
        return "{ " + ", ".join(lua_string(tokens[k]) for k in keys) + " }"

    ansi = lua_list([f"color{i}" for i in range(8)])
    brights = lua_list([f"color{i}" for i in range(8, 16)])
    header = [
        f"-- Gallery theme: {name} (console: {console_mode})",
        "-- Generated by tools/render-theme.py -- do not edit by hand.",
        "local wezterm = require 'wezterm'",
        f"wezterm.add_to_config_reload_watch_list({lua_string(str(own_path))})",
    ]
    if console_mode != "theme":
        return "\n".join(header + ["return {}"]) + "\n"
    lines = header + [
        "return {",
        "  colors = {",
        f"    foreground = {lua_string(tokens['foreground'])},",
        f"    background = {lua_string(tokens['background'])},",
        f"    cursor_bg = {lua_string(tokens['cursor'])},",
        f"    cursor_border = {lua_string(tokens['cursor'])},",
        f"    cursor_fg = {lua_string(tokens['background'])},",
        f"    selection_bg = {lua_string(tokens['selection_background'])},",
        f"    selection_fg = {lua_string(tokens['selection_foreground'])},",
        f"    ansi = {ansi},",
        f"    brights = {brights},",
        "  },",
        f"  window_background_opacity = {glass_opacity():g},",
        f"  macos_window_background_blur = {int(CONSOLE_BLUR_RADIUS)},",
        # One tab, no tab bar: a Gallery window reads like the other terminals'.
        "  hide_tab_bar_if_only_one_tab = true,",
    ]
    if font_prefs:
        lines.append(f"  font = wezterm.font({lua_string(font_prefs['family'])}),")
        lines.append(f"  font_size = {font_prefs['size']},")
    lines.append("}")
    return "\n".join(lines) + "\n"


def osc_rgb(hex_value: str) -> str:
    r, g, b = hex_to_rgb_int(hex_value)
    return f"rgb:{r:02x}/{g:02x}/{b:02x}"


def render_osc_script(tokens: dict, name: str) -> str:
    """A POSIX sh fragment that sets the palette of the terminal it prints
    to: OSC 4 for the 16 ANSI colours, OSC 10/11/12 for foreground,
    background and cursor. `gallery-term wrap` sources it inside a floating
    Gallery window on a terminal that cannot be given a per-window config
    (Ghostty, and the palette on wezterm). Only this window is affected."""
    lines = [
        f"# Gallery theme: {name}",
        "# Generated by tools/render-theme.py -- do not edit by hand.",
    ]
    for i in range(16):
        lines.append(f"printf '\\033]4;{i};{osc_rgb(tokens[f'color{i}'])}\\007'")
    lines += [
        f"printf '\\033]10;{osc_rgb(tokens['foreground'])}\\007'",
        f"printf '\\033]11;{osc_rgb(tokens['background'])}\\007'",
        f"printf '\\033]12;{osc_rgb(tokens['cursor'])}\\007'",
    ]
    return "\n".join(lines) + "\n"


def render_glass_env() -> str:
    return f"opacity={glass_opacity():g}\nblur={int(CONSOLE_BLUR_RADIUS)}\n"


def find_gallery_term() -> str | None:
    """bin/gallery-term: GALLERY_TERM_BIN, else the installed copy, else the
    checkout's. It owns the question of which terminal is configured."""
    candidates = [
        os.environ.get("GALLERY_TERM_BIN", ""),
        str(Path.home() / "bin" / "gallery-term"),
        str(Path(__file__).resolve().parent.parent / "bin" / "gallery-term"),
    ]
    for c in candidates:
        if c and os.access(c, os.X_OK):
            return c
    return None


def configured_terminal() -> str | None:
    tool = find_gallery_term()
    if not tool:
        return None
    try:
        out = subprocess.run(
            [tool, "name"], capture_output=True, text=True, check=False, timeout=10
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    return out.stdout.strip() or None


GHOSTTY_RELOAD_SCRIPT = """
if application id "com.mitchellh.ghostty" is running then
  tell application id "com.mitchellh.ghostty"
    if (count of windows) > 0 then
      perform action "reload_config" on (focused terminal of selected tab of front window)
    end if
  end tell
end if
"""


def kitty_sockets() -> list[str]:
    """Remote-control sockets of running kitties: $KITTY_LISTEN_ON, else
    anything socket-shaped at /tmp/kitty* (the `listen_on unix:/tmp/kitty`
    the docs recommend becomes /tmp/kitty-<pid>)."""
    found = []
    env = os.environ.get("KITTY_LISTEN_ON")
    if env:
        found.append(env)
    import glob
    import stat

    for p in sorted(glob.glob("/tmp/kitty*")):
        try:
            if stat.S_ISSOCK(os.stat(p).st_mode):
                found.append(f"unix:{p}")
        except OSError:
            pass
    return found


def find_kitty_binary() -> str | None:
    for c in (
        "/Applications/kitty.app/Contents/MacOS/kitty",
        str(Path.home() / "Applications" / "kitty.app" / "Contents" / "MacOS" / "kitty"),
    ):
        if os.access(c, os.X_OK):
            return c
    import shutil

    return shutil.which("kitty")


def reload_running_terminal(terminal: str | None) -> str | None:
    """Best-effort live reload of the CONFIGURED terminal, and only if it is
    already running -- never launches anything and never raises. Returns a
    one-line report, or None when there was nothing to try. iTerm2 picks its
    dynamic profiles up by itself, and wezterm reloads when the rendered Lua
    module (on its watch list) changes, so neither needs a push."""
    if os.environ.get("GALLERY_NO_TERMINAL_RELOAD"):
        return None
    try:
        if terminal == "ghostty":
            res = subprocess.run(
                ["osascript", "-e", GHOSTTY_RELOAD_SCRIPT],
                capture_output=True, text=True, check=False, timeout=10,
            )
            return "ghostty: reload_config sent" if res.returncode == 0 else None
        if terminal == "kitty":
            kitty = find_kitty_binary()
            conf = TERMINALS_DIR / "kitty.conf"
            running = subprocess.run(["pgrep", "-x", "kitty"], capture_output=True, check=False)
            if not kitty or running.returncode != 0:
                return None
            done = 0
            for sock in kitty_sockets():
                res = subprocess.run(
                    [kitty, "@", "--to", sock, "set-colors", "--all", "--configured", str(conf)],
                    capture_output=True, text=True, check=False, timeout=10,
                )
                done += res.returncode == 0
            if done:
                return f"kitty: colours pushed to {done} instance(s)"
            return (
                "kitty: no remote-control socket (allow_remote_control + listen_on "
                "in kitty.conf for live updates; new windows pick the theme up)"
            )
    except (OSError, subprocess.SubprocessError):
        return None
    return None


# --- btop -------------------------------------------------------------------

def render_btop_theme(tokens: dict, name: str) -> str:
    """Render a complete btop theme (every key the shipped themes under
    /opt/homebrew/share/btop/themes define -- checked against dracula.theme,
    which carries the full 42-key set including graph_text/meter_bg/
    process_*) mapped from Gallery tokens.

    Mapping spirit (mirrors tokyo-night.theme/dracula.theme's own choices):
    accent drives title/hi_fg/selected_bg/proc_misc (the "this is Gallery"
    highlight color); muted (or lighter_background, whichever the theme's
    colors.toml carries) drives the neutral chrome -- inactive text, the
    divider line, the meter background, and the cpu/mem box outlines; the
    net box and the download/upload graphs pick up blue/cyan since network
    graphs read best cool; the process box and its gradient pick up magenta
    so it reads distinctly from cpu (green->yellow->red heat gradient) and
    mem (blue/cyan/yellow/green per sub-meter) at a glance.
    """

    def or_(value: str | None, fallback: str) -> str:
        return value if value else fallback

    neutral = or_(tokens.get("lighter_background"), or_(tokens.get("muted"), tokens["color8"]))
    orange = or_(tokens.get("orange"), tokens["color3"])

    pairs = [
        # Empty = the terminal's own background, so btop takes on its host
        # window's glass instead of painting a solid slab over it.
        ("main_bg", ""),
        ("main_fg", tokens["foreground"]),
        ("title", tokens["accent"]),
        ("hi_fg", tokens["accent"]),
        ("selected_bg", tokens["accent"]),
        ("selected_fg", tokens["foreground"]),
        ("inactive_fg", neutral),
        ("graph_text", tokens["foreground"]),
        ("meter_bg", neutral),
        ("proc_misc", tokens["accent"]),
        ("cpu_box", neutral),
        ("mem_box", neutral),
        ("net_box", tokens["color4"]),
        ("proc_box", tokens["color5"]),
        ("div_line", neutral),
        ("temp_start", tokens["color2"]),
        ("temp_mid", tokens["color3"]),
        ("temp_end", tokens["color1"]),
        ("cpu_start", tokens["color2"]),
        ("cpu_mid", tokens["color3"]),
        ("cpu_end", tokens["color1"]),
        ("free_start", tokens["color4"]),
        ("free_mid", tokens["color6"]),
        ("free_end", tokens["color2"]),
        ("cached_start", tokens["color6"]),
        ("cached_mid", tokens["color4"]),
        ("cached_end", tokens["color5"]),
        ("available_start", tokens["color3"]),
        ("available_mid", orange),
        ("available_end", tokens["color1"]),
        ("used_start", tokens["color2"]),
        ("used_mid", tokens["color10"]),
        ("used_end", tokens["color2"]),
        ("download_start", tokens["color4"]),
        ("download_mid", tokens["color6"]),
        ("download_end", tokens["color2"]),
        ("upload_start", tokens["color5"]),
        ("upload_mid", tokens["color4"]),
        ("upload_end", tokens["color6"]),
        ("process_start", tokens["color5"]),
        ("process_mid", tokens["accent"]),
        ("process_end", neutral),
    ]

    lines = [
        f"# Gallery theme: {name}",
        "# Generated by tools/render-theme.py -- do not edit by hand.",
        "",
    ]
    lines.extend(f'theme[{key}]="{value}"' for key, value in pairs)
    return "\n".join(lines) + "\n"


def set_conf_keys(path: Path, values: dict[str, str]) -> None:
    """Idempotently set each `key = value` line in a flat config file,
    leaving every other line untouched (the owning app may rewrite the file
    itself, so only the keys passed here are ever touched -- never a full
    overwrite). Only top-level keys count: superfile's config.toml ends in
    an `[open_with]` table, so matching stops at the first table header and
    missing keys are inserted just above it (or appended when there is
    none). A missing file is created with just these keys, which both btop
    and superfile fill out with their own defaults on the next start."""
    pending = dict(values)
    lines = path.read_text().splitlines(keepends=True) if path.is_file() else []
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    end = next((i for i, l in enumerate(lines) if l.lstrip().startswith("[")), len(lines))
    for i in range(end):
        key = lines[i].split("=", 1)[0].strip()
        if "=" in lines[i] and key in pending:
            lines[i] = f"{key} = {pending.pop(key)}\n"
    lines[end:end] = [f"{key} = {value}\n" for key, value in pending.items()]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(lines))


def update_btop_conf(theme_name: str) -> None:
    """Point btop.conf's `color_theme` at the rendered theme."""
    set_conf_keys(BTOP_CONF_PATH, {"color_theme": f'"{theme_name}"'})


# --- superfile ----------------------------------------------------------------

# Gallery themes whose upstream palette has a same-named chroma style, so
# superfile's code preview matches too; everything else falls back by mode.
SUPERFILE_SYNTAX_STYLES = {
    "catppuccin": "catppuccin-mocha",
    "catppuccin-latte": "catppuccin-latte",
    "gruvbox": "gruvbox",
    "nord": "nord",
    "rose-pine": "rose-pine",
    "tokyo-night": "tokyonight-night",
}


def render_superfile_theme(tokens: dict, name: str, light: bool) -> str:
    """Render a complete superfile theme (every key its bundled themes
    define -- checked against catppuccin-mocha.toml from superfile 1.6.0)
    mapped from Gallery tokens.

    Backgrounds use the theme's ordinary background, like the terminal
    windows; with transparent_background on (update_superfile_conf)
    superfile leaves most of them unpainted anyway, so the terminal's own
    glass shows through. Accent drives everything "active";
    muted drives the neutral chrome, mirroring render_btop_theme.
    """
    surface = tokens["background"]
    neutral = tokens.get("muted") or tokens["color8"]
    syntax = SUPERFILE_SYNTAX_STYLES.get(name, "github" if light else "github-dark")

    pairs = [
        ("code_syntax_highlight", syntax),
        ("full_screen_fg", tokens["foreground"]),
        ("full_screen_bg", surface),
        ("file_panel_fg", tokens["foreground"]),
        ("file_panel_bg", surface),
        ("file_panel_border", neutral),
        ("file_panel_border_active", tokens["accent"]),
        ("file_panel_top_directory_icon", tokens["color2"]),
        ("file_panel_top_path", tokens["color4"]),
        ("file_panel_item_selected_fg", tokens["accent"]),
        ("file_panel_item_selected_bg", surface),
        ("footer_fg", tokens["foreground"]),
        ("footer_bg", surface),
        ("footer_border", neutral),
        ("footer_border_active", tokens["accent"]),
        ("sidebar_fg", tokens["foreground"]),
        ("sidebar_bg", surface),
        ("sidebar_title", tokens["color6"]),
        ("sidebar_border", surface),
        ("sidebar_border_active", tokens["accent"]),
        ("sidebar_item_selected_fg", tokens["accent"]),
        ("sidebar_item_selected_bg", surface),
        ("sidebar_divider", neutral),
        ("modal_fg", tokens["foreground"]),
        ("modal_bg", surface),
        ("modal_border_active", neutral),
        ("modal_cancel_fg", surface),
        ("modal_cancel_bg", tokens["color1"]),
        ("modal_confirm_fg", surface),
        ("modal_confirm_bg", tokens["color2"]),
        ("help_menu_hotkey", tokens["color6"]),
        ("help_menu_title", tokens["accent"]),
        ("cursor", tokens["cursor"]),
        ("correct", tokens["color2"]),
        ("error", tokens["color1"]),
        ("hint", tokens["color6"]),
        ("cancel", tokens["color1"]),
    ]

    lines = [
        f"# Gallery theme: {name}",
        "# Generated by tools/render-theme.py -- do not edit by hand.",
        "",
    ]
    lines.extend(f'{key} = "{value}"' for key, value in pairs)
    lines.append(f'gradient_color = ["{tokens["accent"]}", "{tokens["color5"]}"]')
    return "\n".join(lines) + "\n"


def update_superfile_conf(theme_name: str) -> None:
    """Point superfile at the rendered theme, with a transparent background
    so the Gallery-themed terminal shows through."""
    set_conf_keys(
        SUPERFILE_CONF_PATH,
        {"theme": f'"{theme_name}"', "transparent_background": "true"},
    )


def write_file(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)


def main(argv: list[str]) -> int:
    print_only = "--print" in argv

    theme_dir = resolve_current_theme_dir()
    colors_path = theme_dir / "colors.toml"
    if not colors_path.is_file():
        sys.exit(f"render-theme: no colors.toml in current theme dir: {theme_dir}")

    raw = parse_flat_toml(colors_path.read_text())
    name = theme_name_from_dir(theme_dir)
    tokens, light = build_tokens(raw, theme_dir)
    borders_prefs = read_borders_prefs()
    border_tokens = build_border_tokens(tokens, raw, borders_prefs)

    if print_only:
        payload = dict(tokens)
        payload["name"] = name
        payload["light"] = light
        payload.update(border_tokens)
        for k, v in sorted(payload.items()):
            print(f"{k} = {v}")
        return 0

    console_mode = read_console_mode()
    widgets_mode = read_widgets_mode()

    # `gallery font set|native` -- font_prefs is None in native mode (or if
    # the state file is missing/garbage); font_normal is additionally None
    # whenever fc-list can't resolve the requested family/weight to a
    # PostScript name (warns to stderr, never crashes the render -- see
    # resolve_iterm_font).
    font_prefs = read_font_prefs()
    font_normal = None
    if font_prefs:
        ps_name = resolve_iterm_font(font_prefs["family"], font_prefs["weight"])
        if ps_name:
            font_normal = f"{ps_name} {font_prefs['size']}"

    write_file(STATE_DIR / "theme.css", render_css(tokens, font_prefs))
    write_file(STATE_DIR / "theme.json", render_json(tokens, name, light, border_tokens))
    write_file(STATE_DIR / "theme.sh", render_shell(tokens, name, border_tokens, widgets_mode))
    write_file(CRYSTAL_CSS_PATH, render_crystal_css(tokens, name, widgets_mode))
    write_file(ITERM_PROFILE_PATH, render_iterm_profile(tokens, name, font_normal))
    write_file(
        ITERM_CONSOLE_PROFILE_PATH,
        render_iterm_console_profile(tokens, name, console_mode, font_normal),
    )
    write_file(TERMINALS_DIR / "ghostty.conf", render_ghostty_conf(tokens, name, font_prefs))
    write_file(TERMINALS_DIR / "kitty.conf", render_kitty_conf(tokens, name, font_prefs))
    write_file(
        TERMINALS_DIR / "wezterm.lua",
        render_wezterm_lua(
            tokens, name, font_prefs, TERMINALS_DIR / "wezterm.lua", console_mode
        ),
    )
    write_file(TERMINALS_DIR / "gallery-osc.sh", render_osc_script(tokens, name))
    write_file(TERMINALS_DIR / "glass.env", render_glass_env())
    write_file(BTOP_THEME_PATH, render_btop_theme(tokens, name))
    update_btop_conf("gallery")
    write_file(SUPERFILE_THEME_PATH, render_superfile_theme(tokens, name, light))
    update_superfile_conf("gallery")

    border_summary = (
        f"borders: width {border_tokens['border_width']}, "
        f"bright {'on' if border_tokens['border_bright'] else 'off'}"
    )
    print(f"rendered theme '{name}' ({'light' if light else 'dark'})")
    print(f"  {STATE_DIR / 'theme.css'}")
    print(f"  {STATE_DIR / 'theme.json'}")
    print(f"  {STATE_DIR / 'theme.sh'} ({border_summary})")
    print(f"  {CRYSTAL_CSS_PATH} (widgets: {widgets_mode})")
    print(f"  {ITERM_PROFILE_PATH}")
    print(f"  {ITERM_CONSOLE_PROFILE_PATH} (console: {console_mode})")
    for terminal_file in ("ghostty.conf", "kitty.conf", "wezterm.lua", "gallery-osc.sh", "glass.env"):
        print(f"  {TERMINALS_DIR / terminal_file}")
    print(f"  {BTOP_THEME_PATH}")
    print(f"  {BTOP_CONF_PATH} (color_theme = gallery)")
    print(f"  {SUPERFILE_THEME_PATH}")
    print(f"  {SUPERFILE_CONF_PATH} (theme = gallery, transparent_background = true)")
    if font_normal:
        font_summary = f"font: {font_prefs['family']} {font_prefs['size']} {font_prefs['weight']}"
    elif font_prefs:
        font_summary = "font: native (requested font could not be resolved -- see warning above)"
    else:
        font_summary = "font: native"
    print(f"  {font_summary}")
    # Last, so a slow or absent terminal can never hold up the files above.
    reload_report = reload_running_terminal(configured_terminal())
    if reload_report:
        print(f"  live reload -- {reload_report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
