--- lib/theme.lua -- Omarchy colors.toml theme loading and token
--- derivation.
---
--- Theme contract: a theme lives at
--- ~/.config/gallery/themes/<name>/colors.toml, a flat TOML file (no
--- tables, arrays, or multi-line strings). The active theme is the
--- symlink ~/.config/gallery/themes/current -> <name> (directory).
--- TWO shapes are understood here, because upstream Omarchy's actual
--- schema (checked against all 22 vendored themes, see
--- tools/vendor-omarchy-themes.sh) differs from a flat 16-slot ANSI
--- palette -- tools/render-theme.py (the CLI's own renderer, owned by
--- another worker) documents and implements the exact same two shapes,
--- and the derivation below MUST keep agreeing with it key-for-key:
---
---   - Omarchy's real schema: mode ("dark"|"light"), accent, selection,
---     muted, background, dark_background, darker_background,
---     lighter_background, foreground, dark_foreground, light_foreground,
---     bright_foreground, red, yellow, orange, green, cyan, blue, magenta,
---     brown, bright_red, bright_yellow, bright_green, bright_cyan,
---     bright_blue, bright_magenta. No cursor key, no color0..color15, no
---     light.mode file -- light/dark is the `mode` key.
---   - A hand-authored theme following the flat contract this module also
---     accepts: accent, cursor, foreground, background,
---     selection_foreground, selection_background, color0..color15, plus
---     an optional empty light.mode file next to colors.toml instead of a
---     `mode` key.
---
--- Every derived token below prefers a literal key the file already has,
--- and otherwise computes it from Omarchy's real keys, so both shapes
--- render an identical color0..15/cursor/selection_*/muted/danger/
--- success/warning/info set (see deriveFromRealSchema).
---
--- This module only depends on hs.fs, hs.json, and the Lua 5.4 standard
--- library (io.open/io.popen), so it can be dofile'd standalone (e.g. from
--- tests/theme_test.lua run headless through `hs -q`), the same way
--- lib/manifest.lua documents for itself.
---
--- Returns a table with:
---   .parse(path) -> table | nil, error
---       Parses the flat colors.toml subset at `path`: ignores comments
---       (lines whose first non-space character is "#") and blank lines,
---       tolerates spaces around "=", and strips single/double quotes from
---       values. Never raises.
---   .defaultTokens() -> table
---       The built-in fallback token table (name="default", light=false,
---       plus the same background/foreground/accent/muted/surface/danger/
---       success values hardcoded as DEFAULT_THEME in lib/bridge.lua),
---       used whenever there is no resolvable current theme.
---   .load(themesDir) -> table
---       Resolves themesDir .. "/current", parses its colors.toml, and
---       returns a token table: every raw key from colors.toml (minus
---       `mode`), plus `name` (the resolved theme directory's basename),
---       `light` (boolean: mode == "light" if a mode key is present,
---       else true iff light.mode exists in that directory), and the
---       derived tokens cursor, selection_foreground, selection_background,
---       color0..color15, muted, danger, success, warning, info, surface,
---       border (see deriveFromRealSchema). Falls back to defaultTokens()
---       on any failure (no current symlink, unreadable/unparseable
---       colors.toml). Never raises.
---   .cssVariables(tokens) -> string
---       ":root{--gallery-<key>: <value>;...}" (underscores in key names
---       become dashes); skips "name" and "light" (not valid CSS values).
---   .json(tokens) -> string
---       hs.json.encode(tokens), defensively (returns "{}" on failure).

local M = {}

-- Mirrors lib/bridge.lua's own DEFAULT_THEME exactly (background,
-- foreground, accent, muted, surface, danger, success), plus `light` --
-- returned whenever there is no current theme to load. Kept as a literal
-- copy rather than requiring bridge.lua back (this module has to stay
-- standalone-dofile'able, same constraint manifest.lua documents for
-- itself) -- see the note atop lib/bridge.lua's own DEFAULT_THEME if the
-- two ever need to be kept in sync by hand.
local DEFAULT_THEME = {
  name = "default",
  light = false,
  background = "#1f1811",
  foreground = "#e8e6df",
  accent = "#d8a656",
  muted = "#9a886c",
  surface = "#2a2214",
  danger = "#e5726f",
  success = "#5cc98f",
}

------------------------------------------------------------------------
-- Small hex color mixing helper (used to derive `surface` and `border`
-- from background/foreground).
------------------------------------------------------------------------

--- "#rgb" or "#rrggbb" -> r, g, b (0-255 each), or nil if unparseable.
local function hexToRgb(hex)
  if type(hex) ~= "string" then
    return nil
  end
  local h = hex:gsub("^#", "")
  if #h == 3 then
    h = h:sub(1, 1):rep(2) .. h:sub(2, 2):rep(2) .. h:sub(3, 3):rep(2)
  end
  if #h ~= 6 then
    return nil
  end
  local r = tonumber(h:sub(1, 2), 16)
  local g = tonumber(h:sub(3, 4), 16)
  local b = tonumber(h:sub(5, 6), 16)
  if not (r and g and b) then
    return nil
  end
  return r, g, b
end

local function clampByte(n)
  if n < 0 then return 0 end
  if n > 255 then return 255 end
  return math.floor(n + 0.5)
end

--- Mix `fromHex` toward `towardHex` by `pct` (0..1) and return "#rrggbb".
--- Falls back to `fromHex` unchanged if either color fails to parse.
local function mixHex(fromHex, towardHex, pct)
  local fr, fg, fb = hexToRgb(fromHex)
  local tr, tg, tb = hexToRgb(towardHex)
  if not (fr and tr) then
    return fromHex
  end
  local r = clampByte(fr + (tr - fr) * pct)
  local g = clampByte(fg + (tg - fg) * pct)
  local b = clampByte(fb + (tb - fb) * pct)
  return string.format("#%02x%02x%02x", r, g, b)
end

------------------------------------------------------------------------
-- parse
------------------------------------------------------------------------

--- Strip a value of surrounding whitespace and, if present, a single
--- matching pair of double or single quotes -- tolerating an inline
--- trailing comment only in the quoted case (the flat subset this parses
--- never needs one in the unquoted case: values here are always bare hex
--- colors with no internal whitespace).
local function stripValue(raw)
  local trimmed = raw:match("^%s*(.-)%s*$")
  local dq = trimmed:match('^"(.-)"')
  if dq then
    return dq
  end
  local sq = trimmed:match("^'(.-)'")
  if sq then
    return sq
  end
  -- Unquoted: take the first run of non-space characters.
  return trimmed:match("^(%S*)") or trimmed
end

--- Parse the flat TOML subset described atop this file. Returns a table
--- of string key -> string value, or nil, error on failure to open the
--- file. Malformed individual lines (no recognisable "key = value") are
--- silently skipped rather than failing the whole parse, matching the
--- "tolerate" language in the contract.
function M.parse(path)
  local f, openErr = io.open(path, "r")
  if not f then
    return nil, "failed to open " .. tostring(path) .. ": " .. tostring(openErr)
  end
  local content = f:read("a") or ""
  f:close()

  local result = {}
  -- Append a trailing newline so the last line (even with no terminator)
  -- is captured by the same gmatch pattern as every other line.
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
      local key, rawValue = trimmed:match("^([%w_%-]+)%s*=%s*(.-)$")
      if key then
        result[key] = stripValue(rawValue)
      end
    end
  end

  return result
end

------------------------------------------------------------------------
-- defaultTokens
------------------------------------------------------------------------

--- The built-in fallback shape has none of Omarchy's real-schema keys
--- (no red/green/yellow/blue) to derive danger/success/warning/info from
--- -- running it through deriveFromRealSchema's pick-with-a-foreground-
--- default logic would collapse all four to plain `foreground`, which
--- would be a visible regression against the literal colors DEFAULT_THEME
--- already hardcodes. So this stays its own small, literal-preserving
--- enrichment (cursor/selection_foreground default from accent/foreground
--- only if not already set -- both already unset here, so this always
--- fills them in -- plus the same background/foreground `border` mix
--- every other theme gets), deliberately NOT deriveFromRealSchema.
function M.defaultTokens()
  local tokens = {}
  for k, v in pairs(DEFAULT_THEME) do
    tokens[k] = v
  end
  tokens.cursor = tokens.cursor or tokens.accent
  tokens.selection_foreground = tokens.selection_foreground or tokens.foreground
  if tokens.background and tokens.foreground then
    tokens.border = mixHex(tokens.background, tokens.foreground, 0.25)
  end
  return tokens
end

------------------------------------------------------------------------
-- load
------------------------------------------------------------------------

local function shQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

--- Resolve themesDir .. "/current" to the theme directory it points at,
--- plus that directory's basename as the theme's `name`. Returns nil if
--- there is no current symlink (or nothing at that path at all).
---
--- Prefers hs.fs.symlinkAttributes (confirmed by hand on this machine to
--- expose a `target` field already resolved to an absolute path, even for
--- a relative-looking link like "current -> test-theme"); falls back to
--- `readlink` via io.popen (explicitly acceptable per the contract) for
--- any Hammerspoon build where symlinkAttributes doesn't expose `target`.
local function resolveCurrentDir(themesDir)
  local currentPath = themesDir .. "/current"

  if not hs.fs.attributes(currentPath) then
    return nil, nil
  end

  local target = nil
  local symOk, symAttr = pcall(hs.fs.symlinkAttributes, currentPath)
  if symOk and type(symAttr) == "table" and type(symAttr.target) == "string" and symAttr.target ~= "" then
    target = symAttr.target
  end

  if not target then
    local popenOk, handle = pcall(io.popen, "readlink " .. shQuote(currentPath) .. " 2>/dev/null")
    if popenOk and handle then
      local out = handle:read("*l")
      handle:close()
      if type(out) == "string" and out ~= "" then
        target = out
      end
    end
  end

  if not target then
    -- currentPath exists (checked above) but we could not resolve it as a
    -- symlink -- treat it as the theme dir itself rather than failing.
    return currentPath, "current"
  end

  local dir
  if target:sub(1, 1) == "/" then
    dir = target
  else
    dir = themesDir .. "/" .. target
  end
  -- Strip any trailing slash before taking the basename.
  local clean = dir:gsub("/+$", "")
  local name = clean:match("([^/]+)$") or clean
  return clean, name
end

--- First present, non-empty value of tokens[k] for k in keys, else default.
--- Mirrors tools/render-theme.py's own pick() (including its truthiness
--- check: an empty string counts as absent, same as Python's `if raw[k]`).
local function pickFirst(tokens, keys, default)
  for _, k in ipairs(keys) do
    local v = tokens[k]
    if v ~= nil and v ~= "" then
      return v
    end
  end
  return default
end

-- color0..color15 fallback source keys, in order of preference, tried
-- only when the raw file doesn't already have that colorN key itself.
-- MUST match tools/render-theme.py's own color_fallbacks table exactly
-- (see the big comment atop this file) -- note color0 falls back to
-- dark_background (not darker_background).
local COLOR_FALLBACKS = {
  { "color0", { "dark_background", "background" } },
  { "color1", { "red" } },
  { "color2", { "green" } },
  { "color3", { "yellow" } },
  { "color4", { "blue" } },
  { "color5", { "magenta" } },
  { "color6", { "cyan" } },
  { "color7", { "foreground" } },
  { "color8", { "muted", "dark_foreground" } },
  { "color9", { "bright_red", "red" } },
  { "color10", { "bright_green", "green" } },
  { "color11", { "bright_yellow", "yellow" } },
  { "color12", { "bright_blue", "blue" } },
  { "color13", { "bright_magenta", "magenta" } },
  { "color14", { "bright_cyan", "cyan" } },
  { "color15", { "bright_foreground", "foreground" } },
}

--- Port of tools/render-theme.py's build_tokens()/pick(): derives
--- cursor, selection_foreground, selection_background, color0..color15,
--- and (aliasing color1/2/3/4/8) danger/success/warning/info/muted onto
--- `tokens` in place, plus this module's own surface/border (not part of
--- render-theme.py's output at all -- a Gallery-only pair of extra UI
--- tokens layered on top). `tokens` must already have `background` and
--- `foreground` copied in from the raw parse (missing/empty ones get
--- render-theme.py's own literal fallback defaults "#000000"/"#ffffff").
--- Never raises.
local function deriveFromRealSchema(tokens)
  local background = pickFirst(tokens, { "background" }, "#000000")
  local foreground = pickFirst(tokens, { "foreground" }, "#ffffff")
  local accent = pickFirst(tokens, { "accent" }, foreground)

  if tokens.accent == nil or tokens.accent == "" then tokens.accent = accent end
  if tokens.background == nil or tokens.background == "" then tokens.background = background end
  if tokens.foreground == nil or tokens.foreground == "" then tokens.foreground = foreground end

  tokens.cursor = pickFirst(tokens, { "cursor", "accent" }, accent)
  tokens.selection_background = pickFirst(tokens, { "selection_background", "selection", "background" }, background)
  tokens.selection_foreground = pickFirst(tokens, { "selection_foreground", "foreground" }, foreground)

  for _, spec in ipairs(COLOR_FALLBACKS) do
    local key, fallbackKeys = spec[1], spec[2]
    local existing = tokens[key]
    if existing == nil or existing == "" then
      tokens[key] = pickFirst(tokens, fallbackKeys, foreground)
    end
  end

  -- render-theme.py's render_css/render_json always publish these four
  -- (plus muted) as plain aliases of color1/2/3/4/8 -- not an independent
  -- fallback chain -- so this does the same rather than re-deriving them
  -- from tokens.red/green/yellow/blue/muted a second, possibly divergent
  -- way.
  tokens.muted = tokens.color8
  tokens.danger = tokens.color1
  tokens.success = tokens.color2
  tokens.warning = tokens.color3
  tokens.info = tokens.color4

  -- surface/border: Gallery-only, not in render-theme.py. surface prefers
  -- Omarchy's own lighter_background verbatim; border is always the mix
  -- (no upstream key to prefer instead).
  if tokens.lighter_background and tokens.lighter_background ~= "" then
    tokens.surface = tokens.lighter_background
  else
    tokens.surface = mixHex(tokens.background, tokens.foreground, 0.12)
  end
  tokens.border = mixHex(tokens.background, tokens.foreground, 0.25)
end

--- Load the active theme from themesDir (see contract atop this file).
--- Never raises; falls back to defaultTokens() on any failure.
function M.load(themesDir)
  local ok, result = pcall(function()
    local dir, name = resolveCurrentDir(themesDir)
    if not dir then
      return nil
    end

    local raw = M.parse(dir .. "/colors.toml")
    if type(raw) ~= "table" then
      return nil
    end

    local tokens = {}
    for k, v in pairs(raw) do
      if k ~= "mode" then
        tokens[k] = v
      end
    end
    tokens.name = name or "current"

    -- light/dark: Omarchy's real schema uses a `mode` key ("dark" or
    -- "light"); the hand-authored flat contract has no `mode` key and
    -- instead uses an empty light.mode file next to colors.toml. Prefer
    -- `mode` when present (matches tools/render-theme.py's own
    -- build_tokens exactly), falling back to the light.mode file only
    -- when there is no `mode` key at all.
    local mode = raw.mode
    if type(mode) == "string" and mode ~= "" then
      tokens.light = mode:match("^%s*(.-)%s*$"):lower() == "light"
    else
      local lightAttr = hs.fs.attributes(dir .. "/light.mode")
      tokens.light = lightAttr ~= nil
    end

    deriveFromRealSchema(tokens)
    return tokens
  end)

  if ok and type(result) == "table" then
    return result
  end
  return M.defaultTokens()
end

------------------------------------------------------------------------
-- cssVariables / json
------------------------------------------------------------------------

--- ":root{--gallery-<key>: <value>;...}" -- keys sorted for deterministic
--- output (helps tests and log diffing alike); "name" and "light" are
--- skipped (not valid CSS custom property values).
function M.cssVariables(tokens)
  local keys = {}
  for k in pairs(tokens or {}) do
    table.insert(keys, k)
  end
  table.sort(keys)

  local parts = { ":root{" }
  for _, key in ipairs(keys) do
    if key ~= "name" and key ~= "light" then
      local value = tokens[key]
      if type(value) == "string" or type(value) == "number" then
        local cssKey = tostring(key):gsub("_", "-")
        table.insert(parts, "--gallery-" .. cssKey .. ": " .. tostring(value) .. ";")
      end
    end
  end
  table.insert(parts, "}")
  return table.concat(parts)
end

--- hs.json.encode(tokens), defensively -- "{}" if tokens is nil/unencodable.
function M.json(tokens)
  local ok, encoded = pcall(hs.json.encode, tokens or {})
  if not ok then
    return "{}"
  end
  return encoded
end

return M
