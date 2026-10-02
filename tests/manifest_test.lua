-- tests/manifest_test.lua -- headless tests for Gallery.spoon/lib/manifest.lua
-- and Gallery.spoon/lib/state.lua.
--
-- Runs inside a real Hammerspoon Lua environment (hs.fs/hs.json available)
-- but with no Spoon loaded, no windows, no IPC -- purely a test of the two
-- library modules in isolation. Invoke with:
--
--   hs -t 30 -q /absolute/path/to/tests/manifest_test.lua
--
-- (hs runs a file directly when given a path starting with "/".) `-q`
-- (quiet mode) suppresses ordinary print() output -- only errors and the
-- executed chunk's final return value are shown -- so this file builds up
-- its report and returns it as the last statement rather than printing
-- along the way. The final line of that returned report is "PASS <n>" if
-- every check passed, or "FAIL" plus a list of failing checks below it;
-- tests/run.sh greps for "^PASS " since there is no exit code path back
-- from `hs -c`/`hs <file>`.
--
-- Self-location: `hs <file>` sends the file's CONTENT to Hammerspoon to be
-- loaded, without an "@path" chunkname, so debug.getinfo(1,"S").source is
-- the raw source text here, not a usable path. The reliable way to learn
-- this file's own path is `_cli.args[1]`, which the hs CLI populates with
-- the file path argument it was invoked with (see `hs -h`).
local function selfDir()
  local selfPath = _cli and _cli.args and _cli.args[1]
  if type(selfPath) == "string" then
    local dir = selfPath:match("(.*/)")
    if dir then
      return dir
    end
  end
  -- Fallback for other invocation styles (e.g. dofile'd from another
  -- script rather than run directly via `hs <file>`).
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    return source:sub(2):match("(.*/)") or "./"
  end
  return "./"
end

local TESTS_DIR = selfDir()
local LIB_DIR = TESTS_DIR .. "../Gallery.spoon/lib/"

local Manifest = dofile(LIB_DIR .. "manifest.lua")
local State = dofile(LIB_DIR .. "state.lua")

local passCount = 0
local failures = {}

local function check(name, condition, detail)
  if condition then
    passCount = passCount + 1
  else
    table.insert(failures, name .. (detail and detail ~= "" and (" -- " .. detail) or ""))
  end
end

local function listContains(list, needlePattern)
  for _, v in ipairs(list or {}) do
    if tostring(v):find(needlePattern, 1, true) then
      return true
    end
  end
  return false
end

local function joined(list)
  return table.concat(list or {}, "; ")
end

local function writeFile(path, content)
  local f = assert(io.open(path, "w"))
  f:write(content or "")
  f:close()
end

local function mkdirp(path)
  os.execute("mkdir -p '" .. path .. "'")
end

-- Scratch directory for fixture files this test creates on the fly.
local TMP_ROOT = os.tmpname()
os.remove(TMP_ROOT)
mkdirp(TMP_ROOT)

--------------------------------------------------------------------------
-- 1. A valid manifest validates clean: no errors, no warnings.
--------------------------------------------------------------------------
do
  local dir = TMP_ROOT .. "/valid"
  mkdirp(dir)
  writeFile(dir .. "/index.html", "<html></html>")

  local manifest = {
    schemaVersion = 1,
    id = "gallery.demo",
    name = "Demo",
    version = "0.1.0",
    kinds = { "panel" },
    entryPoints = { panel = "index.html" },
  }
  local errors, warnings = Manifest.validate(manifest, dir)
  check("valid manifest: no errors", #errors == 0, joined(errors))
  check("valid manifest: no warnings", #warnings == 0, joined(warnings))
end

--------------------------------------------------------------------------
-- 2. Each ERROR class.
--------------------------------------------------------------------------
do
  local errors = Manifest.validate({
    schemaVersion = 2, id = "a", name = "A", version = "0.1",
    kinds = { "panel" }, entryPoints = { panel = "x" },
  }, TMP_ROOT)
  check("error: schemaVersion ~= 1", listContains(errors, "schemaVersion"), joined(errors))
end

do
  local errors = Manifest.validate({
    schemaVersion = 1, name = "A", version = "0.1",
    kinds = { "panel" }, entryPoints = { panel = "x" },
  }, TMP_ROOT)
  check("error: missing id", listContains(errors, "id"), joined(errors))
end

do
  local errors = Manifest.validate({
    schemaVersion = 1, id = "a", version = "0.1",
    kinds = { "panel" }, entryPoints = { panel = "x" },
  }, TMP_ROOT)
  check("error: missing name", listContains(errors, "name"), joined(errors))
end

do
  local errors = Manifest.validate({
    schemaVersion = 1, id = "a", name = "A",
    kinds = { "panel" }, entryPoints = { panel = "x" },
  }, TMP_ROOT)
  check("error: missing version", listContains(errors, "version"), joined(errors))
end

do
  local errors = Manifest.validate({
    schemaVersion = 1, id = "Not_Valid!", name = "A", version = "0.1",
    kinds = { "panel" }, entryPoints = { panel = "x" },
  }, TMP_ROOT)
  check("error: id does not match pattern", listContains(errors, "id does not match"), joined(errors))
end

do
  local errors = Manifest.validate({
    schemaVersion = 1, id = "a", name = "A", version = "0.1",
    kinds = {}, entryPoints = { panel = "x" },
  }, TMP_ROOT)
  check("error: kinds is empty array", listContains(errors, "kinds is not a non-empty array"), joined(errors))
end

do
  local errors = Manifest.validate({
    schemaVersion = 1, id = "a", name = "A", version = "0.1",
    kinds = "panel", entryPoints = { panel = "x" },
  }, TMP_ROOT)
  check("error: kinds is not a table", listContains(errors, "kinds is not a non-empty array"), joined(errors))
end

do
  local errors = Manifest.validate({
    schemaVersion = 1, id = "a", name = "A", version = "0.1",
    kinds = { "panel" }, entryPoints = "not-a-table",
  }, TMP_ROOT)
  check("error: entryPoints is not a table", listContains(errors, "entryPoints is not a table"), joined(errors))
end

do
  local errors = Manifest.validate({
    schemaVersion = 1, id = "a", name = "A", version = "0.1",
    kinds = { "panel" }, entryPoints = { panel = "/etc/passwd" },
  }, TMP_ROOT)
  check("error: entry point is absolute", listContains(errors, "absolute path"), joined(errors))
end

do
  local errors = Manifest.validate({
    schemaVersion = 1, id = "a", name = "A", version = "0.1",
    kinds = { "panel" }, entryPoints = { panel = "../escape.html" },
  }, TMP_ROOT)
  check("error: entry point contains ..", listContains(errors, "contains '..'"), joined(errors))
end

do
  local dir = TMP_ROOT .. "/missing-entry"
  mkdirp(dir)
  local errors = Manifest.validate({
    schemaVersion = 1, id = "a", name = "A", version = "0.1",
    kinds = { "panel" }, entryPoints = { panel = "nope.html" },
  }, dir)
  check("error: entry point does not exist", listContains(errors, "does not exist"), joined(errors))
end

do
  local errors = Manifest.validate({
    schemaVersion = 1, id = "a", name = "A", version = "0.1",
    kinds = { "tui" }, entryPoints = {},
  }, TMP_ROOT)
  check("error: tui kind without gallery.tui.command", listContains(errors, "tui kind requires gallery.tui.command"), joined(errors))
end

do
  local errors = Manifest.validate({
    schemaVersion = 1, id = "a", name = "A", version = "0.1",
    kinds = { "tui" }, entryPoints = {},
    gallery = { tui = { command = "btop" } },
  }, TMP_ROOT)
  check("valid: tui kind with gallery.tui.command", #errors == 0, joined(errors))
end

--------------------------------------------------------------------------
-- 3. WARNING classes: kinds/entryPoints inconsistency, unknown kind,
--    .qml entry point, omarchy./gallery. namespaces.
--------------------------------------------------------------------------
do
  local dir = TMP_ROOT .. "/kind-no-entry"
  mkdirp(dir)
  local _, warnings = Manifest.validate({
    schemaVersion = 1, id = "a", name = "A", version = "0.1",
    kinds = { "panel", "overlay" }, entryPoints = {},
  }, dir)
  check("warning: kind with no entry point", listContains(warnings, "has no entry point"), joined(warnings))
end

do
  local dir = TMP_ROOT .. "/entry-no-kind"
  mkdirp(dir)
  writeFile(dir .. "/overlay.html", "")
  local _, warnings = Manifest.validate({
    schemaVersion = 1, id = "a", name = "A", version = "0.1",
    kinds = { "panel" }, entryPoints = { panel = nil, overlay = "overlay.html" },
  }, dir)
  check("warning: entry point for unlisted kind", listContains(warnings, "not listed in kinds"), joined(warnings))
end

do
  local _, warnings = Manifest.validate({
    schemaVersion = 1, id = "a", name = "A", version = "0.1",
    kinds = { "widget-of-mystery" }, entryPoints = {},
  }, TMP_ROOT)
  check("warning: unknown kind", listContains(warnings, "unknown kind"), joined(warnings))
end

do
  -- A .qml entry point is fully supported (runs under bin/gallery-qml,
  -- the Quickshell-for-macOS host) -- no error, and specifically no
  -- longer any "no macOS renderer" warning (that warning predates
  -- gallery-qml's existence).
  local dir = TMP_ROOT .. "/qml"
  mkdirp(dir)
  writeFile(dir .. "/Panel.qml", "")
  local errors, warnings = Manifest.validate({
    schemaVersion = 1, id = "a", name = "A", version = "0.1",
    kinds = { "panel" }, entryPoints = { panel = "Panel.qml" },
  }, dir)
  check("qml entry point: no errors", #errors == 0, joined(errors))
  check("qml entry point: no warnings", #warnings == 0, joined(warnings))
end

do
  -- The camelCase "barWidget" entryPoints key (real Omarchy convention,
  -- see the Radio Atlas fixture below) is accepted for the hyphenated
  -- "bar-widget" kind in both consistency-check directions.
  local dir = TMP_ROOT .. "/bar-widget-camel"
  mkdirp(dir)
  writeFile(dir .. "/BarWidget.qml", "")
  local errors, warnings = Manifest.validate({
    schemaVersion = 1, id = "a", name = "A", version = "0.1",
    kinds = { "bar-widget" }, entryPoints = { barWidget = "BarWidget.qml" },
  }, dir)
  check("bar-widget/barWidget alias: no errors", #errors == 0, joined(errors))
  check("bar-widget/barWidget alias: no 'has no entry point' warning", not listContains(warnings, "has no entry point"), joined(warnings))
  check("bar-widget/barWidget alias: no 'not listed in kinds' warning", not listContains(warnings, "not listed in kinds"), joined(warnings))
end

do
  local _, warnings = Manifest.validate({
    schemaVersion = 1, id = "omarchy.something", name = "A", version = "0.1",
    kinds = {}, entryPoints = {},
  }, TMP_ROOT)
  check("warning: omarchy. reserved namespace", listContains(warnings, "reserved upstream namespace"), joined(warnings))
end

do
  -- Only warned when the plugin's dir is under the live install location.
  local dir = os.getenv("HOME") .. "/.config/gallery/plugins/manifest-test-fixture"
  local _, warnings = Manifest.validate({
    schemaVersion = 1, id = "gallery.something", name = "A", version = "0.1",
    kinds = {}, entryPoints = {},
  }, dir)
  check("warning: gallery. first-party namespace under live plugin dir", listContains(warnings, "first-party namespace"), joined(warnings))

  local _, warningsElsewhere = Manifest.validate({
    schemaVersion = 1, id = "gallery.something", name = "A", version = "0.1",
    kinds = {}, entryPoints = {},
  }, TMP_ROOT)
  check("no warning: gallery. id outside live plugin dir", not listContains(warningsElsewhere, "first-party namespace"), joined(warningsElsewhere))
end

--------------------------------------------------------------------------
-- 4. The Omarchy Basecamp fixture validates cleanly (no errors, no
--    warnings -- a .qml entry point behind a known kind is no longer
--    flagged; see the qml-entry-point tests above).
--------------------------------------------------------------------------
do
  local fixtureDir = TESTS_DIR .. "fixtures/omarchy-basecamp"
  local readOk, manifest = pcall(hs.json.read, fixtureDir .. "/manifest.json")
  check("omarchy fixture: manifest reads", readOk and manifest ~= nil)
  if readOk and manifest then
    local errors, warnings = Manifest.validate(manifest, fixtureDir)
    check("omarchy fixture: no errors", #errors == 0, joined(errors))
    check("omarchy fixture: no warnings", #warnings == 0, joined(warnings))
  end
end

--------------------------------------------------------------------------
-- 4b. The Omarchy Radio Atlas fixture (real upstream manifest shape,
--     camelCase "barWidget" entry point key included, plus keepLoaded/
--     author/license/description/homepage/repository/keywords/barWidget
--     top-level fields a plugin.json validator has no business warning
--     about) validates with zero errors and no entry-point warnings.
--------------------------------------------------------------------------
do
  local fixtureDir = TESTS_DIR .. "fixtures/omarchy-radio-atlas"
  local readOk, manifest = pcall(hs.json.read, fixtureDir .. "/manifest.json")
  check("radio-atlas fixture: manifest reads", readOk and manifest ~= nil)
  if readOk and manifest then
    local errors, warnings = Manifest.validate(manifest, fixtureDir)
    check("radio-atlas fixture: no errors", #errors == 0, joined(errors))
    check("radio-atlas fixture: no warnings", #warnings == 0, joined(warnings))
    check("radio-atlas fixture: effective kind is qml (panel entry point)", Manifest.isQmlEntryPoint(manifest, "panel"))
  end
end

--------------------------------------------------------------------------
-- 5. scan() never raises and records errored plugins without skipping them.
--------------------------------------------------------------------------
do
  local scanDir = TMP_ROOT .. "/scan-root"
  mkdirp(scanDir .. "/good")
  writeFile(scanDir .. "/good/index.html", "")
  writeFile(scanDir .. "/good/manifest.json", hs.json.encode({
    schemaVersion = 1, id = "gallery.good", name = "Good", version = "0.1.0",
    kinds = { "panel" }, entryPoints = { panel = "index.html" },
  }))

  mkdirp(scanDir .. "/bad")
  writeFile(scanDir .. "/bad/manifest.json", hs.json.encode({
    schemaVersion = 1, name = "Bad", version = "0.1.0",
    kinds = {}, entryPoints = {},
  }))

  local results = Manifest.scan(scanDir)
  check("scan: finds both plugins", #results == 2, tostring(#results))

  local goodEntry, badEntry
  for _, entry in ipairs(results) do
    if entry.id == "gallery.good" then goodEntry = entry end
    if entry.id == nil then badEntry = entry end
  end

  check("scan: good plugin has no errors", goodEntry ~= nil and #goodEntry.errors == 0, goodEntry and joined(goodEntry.errors))
  check("scan: bad plugin recorded with errors, not skipped", badEntry ~= nil and #badEntry.errors > 0)
end

--------------------------------------------------------------------------
-- 6. state.lua: load/save/enable/disable round trip via a temp path.
--------------------------------------------------------------------------
do
  local statePath = TMP_ROOT .. "/gallery-state.json"

  local state = State.load(statePath)
  check("state: default schemaVersion", state.schemaVersion == 1)
  check("state: default enabled contains gallery.hello", listContains(state.enabled, "gallery.hello"))
  check("state: file created on load", hs.fs.attributes(statePath) ~= nil)

  check("state: gallery.hello enabled by default", State.isEnabled(state, "gallery.hello", true))
  check("state: unknown first-party id enabled by default", State.isEnabled(state, "gallery.other", true))
  check("state: unknown third-party id disabled by default", not State.isEnabled(state, "some.thirdparty", false))

  State.enable(state, "gallery.hello2", statePath)
  check("state: enable adds to in-memory enabled list", listContains(state.enabled, "gallery.hello2"))

  -- Round trip: reload from disk into a fresh table and confirm it persisted.
  local reloaded = State.load(statePath)
  check("state: enable persisted across reload", listContains(reloaded.enabled, "gallery.hello2"))

  State.disable(reloaded, "gallery.hello2", statePath)
  check("state: disable removes from enabled list", not listContains(reloaded.enabled, "gallery.hello2"))
  check("state: disable adds to disabled list", listContains(reloaded.disabled, "gallery.hello2"))

  local reloadedAgain = State.load(statePath)
  check("state: disable persisted across reload", listContains(reloadedAgain.disabled, "gallery.hello2"))
  check("state: disabled id no longer in enabled list after reload", not listContains(reloadedAgain.enabled, "gallery.hello2"))
  check("state: isEnabled false for a disabled first-party id", not State.isEnabled(reloadedAgain, "gallery.hello2", true))
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
