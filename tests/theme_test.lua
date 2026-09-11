-- tests/theme_test.lua -- headless tests for Gallery.spoon/lib/theme.lua.
--
-- Runs inside a real Hammerspoon Lua environment (hs.fs/hs.json/hs.fs.link
-- available) but with no Spoon loaded, no windows, no IPC -- purely a test
-- of the library module in isolation, exactly like tests/manifest_test.lua
-- (which this file's conventions -- selfDir, check/report, writeFile/
-- mkdirp/TMP_ROOT -- are copied from). Invoke with:
--
--   hs -t 30 -q /absolute/path/to/tests/theme_test.lua
--
-- (hs runs a file directly when given a path starting with "/".) `-q`
-- suppresses ordinary print() output -- only the executed chunk's final
-- return value is shown -- so this file builds up its report and returns
-- it as the last statement. "PASS <n>" if every check passed, or "FAIL"
-- plus a list of failing checks below it; tests/run.sh greps for "^PASS ".
--
-- Self-location: see tests/manifest_test.lua's own long comment on this --
-- `_cli.args[1]` is the reliable path here, not debug.getinfo.
local function selfDir()
  local selfPath = _cli and _cli.args and _cli.args[1]
  if type(selfPath) == "string" then
    local dir = selfPath:match("(.*/)")
    if dir then
      return dir
    end
  end
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    return source:sub(2):match("(.*/)") or "./"
  end
  return "./"
end

local TESTS_DIR = selfDir()
local LIB_DIR = TESTS_DIR .. "../Gallery.spoon/lib/"

local Theme = dofile(LIB_DIR .. "theme.lua")

local passCount = 0
local failures = {}

local function check(name, condition, detail)
  if condition then
    passCount = passCount + 1
  else
    table.insert(failures, name .. (detail and detail ~= "" and (" -- " .. detail) or ""))
  end
end

local function writeFile(path, content)
  local f = assert(io.open(path, "w"))
  f:write(content or "")
  f:close()
end

local function mkdirp(path)
  os.execute("mkdir -p '" .. path .. "'")
end

--- Symlink themesDir/current -> themesDir/targetName. Prefers
--- hs.fs.link(old, new, true) (confirmed present on this machine, its
--- third argument creates a symlink rather than a hard link -- same
--- luafilesystem-derived API hs.fs.attributes/hs.fs.symlinkAttributes
--- come from); falls back to `ln -sfn` via os.execute if hs.fs.link is
--- ever unavailable. Deliberately passes the ABSOLUTE theme dir as `old`
--- -- confirmed by hand that hs.fs.link resolves a relative `old` against
--- Hammerspoon's own process cwd (~/.hammerspoon), not against `new`'s
--- directory the way a raw symlink() syscall / `ln -s` would, which would
--- otherwise point this test's fixtures at the wrong place entirely.
--- lib/theme.lua's resolveCurrentDir handles an absolute symlink target
--- exactly like a relative one, so this is equally valid coverage of the
--- real "current -> <name>" contract.
local function symlinkCurrent(themesDir, targetName)
  local absoluteTarget = themesDir .. "/" .. targetName
  local ok = pcall(function()
    return hs.fs.link(absoluteTarget, themesDir .. "/current", true)
  end)
  if not ok then
    os.execute("ln -sfn '" .. absoluteTarget .. "' '" .. themesDir .. "/current'")
  end
end

-- Scratch directory for fixture files this test creates on the fly --
-- deliberately NOT under ~/.config/gallery/themes (the real contract
-- location, which the task's manual verify step requires left empty
-- afterwards; a worker owns install.sh/themes/ there, not this test).
local TMP_ROOT = os.tmpname()
os.remove(TMP_ROOT)
mkdirp(TMP_ROOT)

--------------------------------------------------------------------------
-- 1. parse(): comments, blank lines, spaces, quoted and unquoted values.
--------------------------------------------------------------------------
do
  local dir = TMP_ROOT .. "/parse-fixture"
  mkdirp(dir)
  writeFile(dir .. "/colors.toml", table.concat({
    "# a full-line comment",
    "",
    "   ",
    "accent = \"#7aa2f7\"",
    "background='#1a1b26'",
    "foreground =  \"#a9b1d6\"   ",
    "color0 = #32344a",
    "# another comment before EOF",
  }, "\n"))

  local parsed, err = Theme.parse(dir .. "/colors.toml")
  check("parse: returns a table", type(parsed) == "table", tostring(err))
  if type(parsed) == "table" then
    check("parse: double-quoted value stripped", parsed.accent == "#7aa2f7", tostring(parsed.accent))
    check("parse: single-quoted value stripped", parsed.background == "#1a1b26", tostring(parsed.background))
    check("parse: tolerates extra spaces around = and trailing space", parsed.foreground == "#a9b1d6", tostring(parsed.foreground))
    check("parse: unquoted bare value", parsed.color0 == "#32344a", tostring(parsed.color0))
  end

  local missing, missingErr = Theme.parse(dir .. "/does-not-exist.toml")
  check("parse: nonexistent file returns nil", missing == nil)
  check("parse: nonexistent file returns an error string", type(missingErr) == "string" and missingErr ~= "")
end

--------------------------------------------------------------------------
-- 2. load(): full tokyo-night-style fixture, symlinked as current --
--    derived tokens, cssVariables(), json().
--------------------------------------------------------------------------
do
  local themesDir = TMP_ROOT .. "/themes-a"
  local themeDir = themesDir .. "/tokyo-night"
  mkdirp(themeDir)
  writeFile(themeDir .. "/colors.toml", table.concat({
    "accent = \"#7aa2f7\"",
    "cursor = \"#c0caf5\"",
    "foreground = \"#a9b1d6\"",
    "background = \"#1a1b26\"",
    "selection_foreground = \"#c0caf5\"",
    "selection_background = \"#7aa2f7\"",
    "color0 = \"#32344a\"",
    "color1 = \"#f7768e\"",
    "color2 = \"#9ece6a\"",
    "color3 = \"#e0af68\"",
    "color4 = \"#7aa2f7\"",
    "color5 = \"#ad8ee6\"",
    "color6 = \"#449dab\"",
    "color7 = \"#787c99\"",
    "color8 = \"#444b6a\"",
    "color9 = \"#ff7a93\"",
    "color10 = \"#b9f27c\"",
    "color11 = \"#ff9e64\"",
    "color12 = \"#7da6ff\"",
    "color13 = \"#bb9af7\"",
    "color14 = \"#0db9d7\"",
    "color15 = \"#acb0d0\"",
  }, "\n"))
  symlinkCurrent(themesDir, "tokyo-night")

  local tokens = Theme.load(themesDir)
  check("load: name is the resolved theme dir's basename", tokens.name == "tokyo-night", tostring(tokens.name))
  check("load: light is false (no light.mode file)", tokens.light == false, tostring(tokens.light))
  check("load: raw key accent passed through", tokens.accent == "#7aa2f7", tostring(tokens.accent))
  check("load: raw key selection_background passed through", tokens.selection_background == "#7aa2f7", tostring(tokens.selection_background))

  check("load: derived muted == color8", tokens.muted == "#444b6a", tostring(tokens.muted))
  check("load: derived danger == color1", tokens.danger == "#f7768e", tostring(tokens.danger))
  check("load: derived success == color2", tokens.success == "#9ece6a", tostring(tokens.success))
  check("load: derived warning == color3", tokens.warning == "#e0af68", tostring(tokens.warning))
  check("load: derived info == color4", tokens.info == "#7aa2f7", tostring(tokens.info))

  -- background #1a1b26 (26,27,38) mixed 12% toward foreground #a9b1d6
  -- (169,177,214) -> r=26+(169-26)*.12=43.16 -> 0x2b, g=27+(177-27)*.12=45
  -- -> 0x2d, b=38+(214-38)*.12=59.12 -> 0x3b.
  check("load: derived surface is background mixed 12% toward foreground", tokens.surface == "#2b2d3b", tostring(tokens.surface))
  -- same mix at 25%: r=26+143*.25=61.75->0x3e, g=27+150*.25=64.5->0x41,
  -- b=38+176*.25=82->0x52.
  check("load: derived border is background mixed 25% toward foreground", tokens.border == "#3e4152", tostring(tokens.border))

  local css = Theme.cssVariables(tokens)
  check("cssVariables: wraps in :root{...}", css:match("^:root{.*}$") ~= nil, css)
  check("cssVariables: includes --gallery-accent", css:find("--gallery-accent: #7aa2f7;", 1, true) ~= nil, css)
  check("cssVariables: underscore key becomes dashed custom property", css:find("--gallery-selection-background: #7aa2f7;", 1, true) ~= nil, css)
  check("cssVariables: does not emit --gallery-name", css:find("--gallery-name", 1, true) == nil, css)
  check("cssVariables: does not emit --gallery-light", css:find("--gallery-light", 1, true) == nil, css)

  local json = Theme.json(tokens)
  local decodeOk, decoded = pcall(hs.json.decode, json)
  check("json: decodes back to a table", decodeOk and type(decoded) == "table")
  if decodeOk and type(decoded) == "table" then
    check("json: round-trips accent", decoded.accent == "#7aa2f7", tostring(decoded.accent))
    check("json: round-trips name", decoded.name == "tokyo-night", tostring(decoded.name))
  end
end

--------------------------------------------------------------------------
-- 3. light.mode detection.
--------------------------------------------------------------------------
do
  local themesDir = TMP_ROOT .. "/themes-b"
  local themeDir = themesDir .. "/day-theme"
  mkdirp(themeDir)
  writeFile(themeDir .. "/colors.toml", table.concat({
    "accent = \"#3366cc\"",
    "background = \"#ffffff\"",
    "foreground = \"#111111\"",
    "color1 = \"#cc3333\"",
    "color2 = \"#33cc33\"",
    "color3 = \"#cccc33\"",
    "color4 = \"#3366cc\"",
    "color8 = \"#999999\"",
  }, "\n"))
  writeFile(themeDir .. "/light.mode", "")
  symlinkCurrent(themesDir, "day-theme")

  local tokens = Theme.load(themesDir)
  check("load: light.mode present -> light is true", tokens.light == true, tostring(tokens.light))
  check("load: name matches the light theme's dir", tokens.name == "day-theme", tostring(tokens.name))
end

--------------------------------------------------------------------------
-- 4. default fallback: no current symlink at all.
--------------------------------------------------------------------------
do
  local themesDir = TMP_ROOT .. "/themes-empty"
  mkdirp(themesDir)

  local tokens = Theme.load(themesDir)
  check("load: no current symlink -> name is 'default'", tokens.name == "default", tostring(tokens.name))
  check("load: no current symlink -> light is false", tokens.light == false, tostring(tokens.light))

  local defaults = Theme.defaultTokens()
  check("load fallback matches defaultTokens() background", tokens.background == defaults.background, tostring(tokens.background))
  check("load fallback matches defaultTokens() accent", tokens.accent == defaults.accent, tostring(tokens.accent))
  check("defaultTokens(): includes a derived border", type(defaults.border) == "string" and defaults.border ~= "", tostring(defaults.border))
end

--------------------------------------------------------------------------
-- 5. default fallback: current symlink present but colors.toml missing/
--    unparseable also falls back cleanly (never raises).
--------------------------------------------------------------------------
do
  local themesDir = TMP_ROOT .. "/themes-broken"
  local themeDir = themesDir .. "/broken-theme"
  mkdirp(themeDir)
  -- No colors.toml written at all.
  symlinkCurrent(themesDir, "broken-theme")

  local okCall, tokens = pcall(Theme.load, themesDir)
  check("load: missing colors.toml does not raise", okCall, tostring(tokens))
  check("load: missing colors.toml falls back to default", okCall and tokens.name == "default", okCall and tostring(tokens.name) or tostring(tokens))
end

--------------------------------------------------------------------------
-- 6. Real Omarchy schema, dark: an exact copy of the vendored
--    tokyo-night/colors.toml (see ~/.config/gallery/themes/tokyo-night,
--    installed by the other worker's install.sh from this repo's
--    themes/tokyo-night) -- mode key, no cursor/color0..15/light.mode.
--    Must derive identically to tools/render-theme.py (see the big
--    comment atop lib/theme.lua and the coordinator correction that
--    produced this test): danger==red, color0 from dark_background (NOT
--    darker_background), cursor/selection_* falling back correctly.
--------------------------------------------------------------------------
do
  local themesDir = TMP_ROOT .. "/themes-real-dark"
  local themeDir = themesDir .. "/tokyo-night"
  mkdirp(themeDir)
  writeFile(themeDir .. "/colors.toml", table.concat({
    "mode = \"dark\"",
    "",
    "accent = \"#7aa2f7\"",
    "selection = \"#292e42\"",
    "muted = \"#414868\"",
    "",
    "background = \"#1a1b26\"",
    "dark_background = \"#13141c\"",
    "darker_background = \"#0e0e14\"",
    "lighter_background = \"#24283b\"",
    "",
    "foreground = \"#a9b1d6\"",
    "dark_foreground = \"#565f89\"",
    "light_foreground = \"#b4bee6\"",
    "bright_foreground = \"#c0caf5\"",
    "",
    "red = \"#f7768e\"",
    "yellow = \"#e0af68\"",
    "orange = \"#eb927b\"",
    "green = \"#9ece6a\"",
    "cyan = \"#449dab\"",
    "blue = \"#7aa2f7\"",
    "magenta = \"#ad8ee6\"",
    "brown = \"#75493d\"",
    "",
    "bright_red = \"#ff7a93\"",
    "bright_yellow = \"#ff9e64\"",
    "bright_green = \"#b9f27c\"",
    "bright_cyan = \"#0db9d7\"",
    "bright_blue = \"#7da6ff\"",
    "bright_magenta = \"#bb9af7\"",
  }, "\n"))
  symlinkCurrent(themesDir, "tokyo-night")

  local tokens = Theme.load(themesDir)
  check("real schema (tokyo-night): name matches theme dir", tokens.name == "tokyo-night", tostring(tokens.name))
  check("real schema (tokyo-night): light is false (mode=dark)", tokens.light == false, tostring(tokens.light))
  check("real schema (tokyo-night): raw mode key not passed through", tokens.mode == nil, tostring(tokens.mode))
  check("real schema (tokyo-night): danger == red", tokens.danger == tokens.red and tokens.danger == "#f7768e", tostring(tokens.danger))
  check("real schema (tokyo-night): success == green", tokens.success == "#9ece6a", tostring(tokens.success))
  check("real schema (tokyo-night): warning == yellow", tokens.warning == "#e0af68", tostring(tokens.warning))
  check("real schema (tokyo-night): info == blue", tokens.info == "#7aa2f7", tostring(tokens.info))
  check("real schema (tokyo-night): muted preserved via color8", tokens.muted == "#414868", tostring(tokens.muted))
  check("real schema (tokyo-night): cursor falls back to accent (no cursor key)", tokens.cursor == "#7aa2f7", tostring(tokens.cursor))
  check("real schema (tokyo-night): selection_background falls back to selection", tokens.selection_background == "#292e42", tostring(tokens.selection_background))
  check("real schema (tokyo-night): selection_foreground falls back to foreground", tokens.selection_foreground == "#a9b1d6", tostring(tokens.selection_foreground))
  check("real schema (tokyo-night): surface == lighter_background verbatim", tokens.surface == "#24283b", tostring(tokens.surface))
  check("real schema (tokyo-night): color0 falls back to dark_background (not darker_background)", tokens.color0 == "#13141c", tostring(tokens.color0))
  check("real schema (tokyo-night): color9 falls back to bright_red", tokens.color9 == "#ff7a93", tostring(tokens.color9))
  check("real schema (tokyo-night): color15 falls back to bright_foreground", tokens.color15 == "#c0caf5", tostring(tokens.color15))
end

--------------------------------------------------------------------------
-- 7. Real Omarchy schema, light: an exact copy of the vendored
--    catppuccin-latte/colors.toml -- mode = "light".
--------------------------------------------------------------------------
do
  local themesDir = TMP_ROOT .. "/themes-real-light"
  local themeDir = themesDir .. "/catppuccin-latte"
  mkdirp(themeDir)
  writeFile(themeDir .. "/colors.toml", table.concat({
    "mode = \"light\"",
    "",
    "accent = \"#1e66f5\"",
    "selection = \"#ccd0da\"",
    "muted = \"#acb0be\"",
    "",
    "background = \"#eff1f5\"",
    "dark_background = \"#e3e4e8\"",
    "darker_background = \"#d7d8dc\"",
    "lighter_background = \"#dce0e8\"",
    "",
    "foreground = \"#4c4f69\"",
    "dark_foreground = \"#9ca0b0\"",
    "light_foreground = \"#5c5f77\"",
    "bright_foreground = \"#4c4f69\"",
    "",
    "red = \"#d20f39\"",
    "yellow = \"#df8e1d\"",
    "orange = \"#d84e2b\"",
    "green = \"#40a02b\"",
    "cyan = \"#179299\"",
    "blue = \"#1e66f5\"",
    "magenta = \"#ea76cb\"",
    "brown = \"#6c2715\"",
    "",
    "bright_red = \"#d20f39\"",
    "bright_yellow = \"#df8e1d\"",
    "bright_green = \"#40a02b\"",
    "bright_cyan = \"#179299\"",
    "bright_blue = \"#1e66f5\"",
    "bright_magenta = \"#ea76cb\"",
  }, "\n"))
  symlinkCurrent(themesDir, "catppuccin-latte")

  local tokens = Theme.load(themesDir)
  check("real schema (catppuccin-latte): name matches theme dir", tokens.name == "catppuccin-latte", tostring(tokens.name))
  check("real schema (catppuccin-latte): light is true (mode=light)", tokens.light == true, tostring(tokens.light))
  check("real schema (catppuccin-latte): danger == red", tokens.danger == tokens.red and tokens.danger == "#d20f39", tostring(tokens.danger))
end

--------------------------------------------------------------------------
-- Report. Returned (not printed) as the chunk's final value -- see the
-- note on `-q` above.
--------------------------------------------------------------------------
os.execute("rm -rf '" .. TMP_ROOT .. "'")

if #failures == 0 then
  return "PASS " .. passCount
else
  local lines = { "FAIL" }
  for _, f in ipairs(failures) do
    table.insert(lines, "  " .. f)
  end
  return table.concat(lines, "\n")
end
