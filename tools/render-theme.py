#!/usr/bin/env python3
"""render-theme.py -- render the active Gallery theme into every consumer
this repo knows about: a CSS custom-property sheet, a JSON token dump, an
iTerm2 dynamic profile, and a shell fragment (also consumed by the crystal
widgets).

Reads ~/.config/gallery/themes/current/colors.toml (the `current` symlink
Gallery.spoon and `gallery theme set` manage) and writes:

  ~/.config/gallery/state/theme.css
  ~/.config/gallery/state/theme.json
  ~/.config/gallery/state/theme.sh
  ~/Library/Application Support/iTerm2/DynamicProfiles/gallery-theme.json
  ~/Library/Application Support/iTerm2/DynamicProfiles/gallery-console.json
  ~/.config/btop/themes/gallery.theme
  ~/.config/btop/btop.conf (color_theme key only, rewritten in place)

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
ITERM_CONSOLE_PROFILE_PATH = ITERM_DYNAMIC_PROFILES_DIR / "gallery-console.json"
BTOP_CONFIG_DIR = Path.home() / ".config" / "btop"
BTOP_THEME_PATH = BTOP_CONFIG_DIR / "themes" / "gallery.theme"
BTOP_CONF_PATH = BTOP_CONFIG_DIR / "btop.conf"

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
    # The Gallery UI surface -- QML plugin panels, the iTerm floating-window
    # canvas, and btop's background -- is painted with the theme's deepest
    # tone so every surface reads as one near-black UI. Falls back to the
    # ordinary background for any theme that omits darker_background.
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


def render_css(tokens: dict) -> str:
    lines = [":root {"]
    for key, value in tokens.items():
        lines.append(f"  {css_var_name(key)}:{value};")
    lines.append(f"  {css_var_name('muted')}:{tokens['color8']};")
    lines.append(f"  {css_var_name('danger')}:{tokens['color1']};")
    lines.append(f"  {css_var_name('success')}:{tokens['color2']};")
    lines.append(f"  {css_var_name('warning')}:{tokens['color3']};")
    lines.append(f"  {css_var_name('info')}:{tokens['color4']};")
    lines.append("}")
    return "\n".join(lines) + "\n"


def render_json(tokens: dict, name: str, light: bool) -> str:
    payload = dict(tokens)
    payload["name"] = name
    payload["light"] = light
    payload["muted"] = tokens["color8"]
    payload["danger"] = tokens["color1"]
    payload["success"] = tokens["color2"]
    payload["warning"] = tokens["color3"]
    payload["info"] = tokens["color4"]
    return json.dumps(payload, indent=2, sort_keys=True) + "\n"


def render_shell(tokens: dict, name: str) -> str:
    def q(value: str) -> str:
        return "'" + value.replace("'", "'\\''") + "'"

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

    r, g, b = hex_to_rgb_int(tokens["accent"])
    lines.append(f"export CRYSTAL_BAR_COLOR='rgba({r},{g},{b},1.0)'")
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


def render_iterm_profile(tokens: dict, name: str) -> str:
    profile = {
        "Name": "Gallery",
        "Guid": "gallery-theme",
        "Background Color": iterm_color_dict(tokens["surface_background"]),
        "Foreground Color": iterm_color_dict(tokens["foreground"]),
        "Cursor Color": iterm_color_dict(tokens["cursor"]),
        "Cursor Text Color": iterm_color_dict(tokens["surface_background"]),
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
        "Transparency": 0.0,
    }
    for i in range(16):
        profile[f"Ansi {i} Color"] = iterm_color_dict(tokens[f"color{i}"])

    doc = {"Profiles": [profile]}
    return json.dumps(doc, indent=2, sort_keys=True) + "\n"


def render_iterm_console_profile(tokens: dict, name: str, mode: str) -> str:
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
    EXCEPT the background is tokens["background"] (the theme's own ordinary
    background), not tokens["surface_background"] (that is the Gallery UI
    panel's deliberately-darker tint, not what an everyday terminal should
    show). No window-behaviour keys here either (Close Sessions On End,
    Window Type, etc.) -- those make sense only for the floating, ephemeral
    Gallery TUI host, never for an always-open everyday terminal.
    """
    profile = {
        "Name": "Console",
        "Guid": "gallery-console",
        "Dynamic Profile Parent Name": "Default",
    }
    if mode == "theme":
        profile["Use Separate Colors for Light and Dark Mode"] = False
        profile["Background Color"] = iterm_color_dict(tokens["background"])
        profile["Foreground Color"] = iterm_color_dict(tokens["foreground"])
        profile["Bold Color"] = iterm_color_dict(tokens["foreground"])
        profile["Cursor Color"] = iterm_color_dict(tokens["cursor"])
        profile["Cursor Text Color"] = iterm_color_dict(tokens["background"])
        profile["Selection Color"] = iterm_color_dict(tokens["selection_background"])
        profile["Selected Text Color"] = iterm_color_dict(tokens["selection_foreground"])
        for i in range(16):
            profile[f"Ansi {i} Color"] = iterm_color_dict(tokens[f"color{i}"])

    doc = {"Profiles": [profile]}
    return json.dumps(doc, indent=2, sort_keys=True) + "\n"


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
        ("main_bg", tokens["surface_background"]),
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


def update_btop_conf(theme_name: str) -> None:
    """Idempotently set `color_theme = "<theme_name>"` in btop.conf, leaving
    every other key untouched. btop rewrites this file on exit, so only the
    one key this function owns is ever touched -- never a full overwrite."""
    new_line = f'color_theme = "{theme_name}"\n'

    if BTOP_CONF_PATH.is_file():
        lines = BTOP_CONF_PATH.read_text().splitlines(keepends=True)
        replaced = False
        for i, line in enumerate(lines):
            if line.strip().startswith("color_theme"):
                lines[i] = new_line
                replaced = True
                break
        if not replaced:
            if lines and not lines[-1].endswith("\n"):
                lines[-1] += "\n"
            lines.append(new_line)
        BTOP_CONF_PATH.write_text("".join(lines))
    else:
        BTOP_CONF_PATH.parent.mkdir(parents=True, exist_ok=True)
        BTOP_CONF_PATH.write_text(new_line)


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

    if print_only:
        payload = dict(tokens)
        payload["name"] = name
        payload["light"] = light
        for k, v in sorted(payload.items()):
            print(f"{k} = {v}")
        return 0

    console_mode = read_console_mode()

    write_file(STATE_DIR / "theme.css", render_css(tokens))
    write_file(STATE_DIR / "theme.json", render_json(tokens, name, light))
    write_file(STATE_DIR / "theme.sh", render_shell(tokens, name))
    write_file(ITERM_PROFILE_PATH, render_iterm_profile(tokens, name))
    write_file(ITERM_CONSOLE_PROFILE_PATH, render_iterm_console_profile(tokens, name, console_mode))
    write_file(BTOP_THEME_PATH, render_btop_theme(tokens, name))
    update_btop_conf("gallery")

    print(f"rendered theme '{name}' ({'light' if light else 'dark'})")
    print(f"  {STATE_DIR / 'theme.css'}")
    print(f"  {STATE_DIR / 'theme.json'}")
    print(f"  {STATE_DIR / 'theme.sh'}")
    print(f"  {ITERM_PROFILE_PATH}")
    print(f"  {ITERM_CONSOLE_PROFILE_PATH} (console: {console_mode})")
    print(f"  {BTOP_THEME_PATH}")
    print(f"  {BTOP_CONF_PATH} (color_theme = gallery)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
