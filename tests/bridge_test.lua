-- tests/bridge_test.lua -- headless test for Gallery.spoon/lib/bridge.lua's
-- window.gallery JavaScript bridge, exercised end to end through a real
-- gallery.hello panel.
--
-- Invoke with:
--
--   hs -t 60 -q /absolute/path/to/tests/bridge_test.lua
--
-- exactly like tests/manifest_test.lua (hs runs a file directly when given
-- a path starting with "/"; `-q` suppresses ordinary print() output so
-- only the executed chunk's final return value is shown).
--
-- WHY THIS IS THREE CALLS, NOT ONE (read before "fixing" this):
--
-- The natural design -- open the panel, busy-wait with hs.timer.usleep
-- until the page has loaded, then call webview:evaluateJavaScript(script,
-- callback) and busy-wait again for the callback -- does NOT work, and
-- this was confirmed by hand, not assumed:
--
--   * A callback registered by THIS invocation (evaluateJavaScript's own
--     completion handler, hs.timer.doAfter, hs.task's exit callback --
--     tried all three) never fires while this same top-level chunk is
--     still running, no matter how long or how it waits (hs.timer.usleep
--     loop, one long usleep, doesn't matter). Hammerspoon's Lua execution
--     owns the run loop for the duration of one `hs -c`/`hs <file>`
--     invocation; queued async replies only get delivered once that
--     invocation's chunk RETURNS and a later, separate invocation lets
--     the run loop turn again. tests/gate.sh already relies on exactly
--     this (wait_for_hs_ready polls via repeated SEPARATE `hs -c` calls
--     with a real `sleep` in bash between them, never a single blocking
--     wait inside one call) -- this file follows the same idiom instead
--     of fighting it.
--   * Consequently: evaluateJavaScript issued in the SAME invocation as
--     the ipc('open', ...) call can race the page's own document-start
--     script and see window.gallery still undefined, even though the
--     page finishes loading in well under a second once Hammerspoon's
--     run loop actually gets to run it.
--
-- So this file is a tiny 3-phase state machine, phase implied by what it
-- observes (no explicit argument needed), meant to be invoked 2-3 times
-- with a couple of real seconds between calls (see tests/run.sh, which
-- does exactly this):
--
--   phase 1 (gallery.hello not open): open it via spoon.Gallery:ipc, and
--     bookmark the current end of gallery.log so phase 3 only looks at
--     lines appended after this point.
--   phase 2 (open, JS assertions not yet issued): evaluate a script in
--     the page that runs the actual assertions -- gallery.exec resolves
--     0 for /usr/bin/true, gallery.theme.accent is a string, the
--     --gallery-accent CSS custom property is non-empty -- and reports
--     the result via the existing gallery.log() bridge call (fire and
--     forget from the page's point of view; no Lua-side callback needed
--     for this at all, which is what makes phase 2 possible in one shot).
--   phase 2b (issued, result not observed yet): tells the caller to
--     retry shortly.
--   phase 3 (result observed in the log): parses it, runs the real
--     PASS/FAIL checks, closes the panel via spoon.Gallery:ipc, asserts
--     spoon.Gallery.windows is empty, and returns the final "PASS n" /
--     "FAIL" report (this is the line tests/run.sh greps for).
--
-- Self-location follows tests/manifest_test.lua's convention exactly.
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

local PLUGIN_ID = "gallery.hello"
local LOG_PATH = os.getenv("HOME") .. "/Library/Logs/gallery.log"
-- Transient scratch state for this test's own phase tracking -- not part
-- of Gallery's own state, just how this file remembers, across separate
-- `hs` invocations, how far along it got. Safe to delete any time.
local STATE_PATH = "/tmp/gallery-bridge-test-state.json"

local passCount = 0
local failures = {}

local function check(name, condition, detail)
  if condition then
    passCount = passCount + 1
  else
    table.insert(failures, name .. (detail and detail ~= "" and (" -- " .. detail) or ""))
  end
end

local function report()
  if #failures == 0 then
    return "PASS " .. passCount
  end
  local lines = { "FAIL" }
  for _, f in ipairs(failures) do
    table.insert(lines, "  " .. f)
  end
  return table.concat(lines, "\n")
end

local function readState()
  local ok, decoded = pcall(hs.json.read, STATE_PATH)
  if ok and type(decoded) == "table" then
    return decoded
  end
  return nil
end

local function writeState(state)
  pcall(function()
    local encoded = hs.json.encode(state)
    local f = assert(io.open(STATE_PATH, "w"))
    f:write(encoded)
    f:close()
  end)
end

local function clearState()
  pcall(os.remove, STATE_PATH)
end

local function logEndOffset()
  local f = io.open(LOG_PATH, "r")
  if not f then
    return 0
  end
  local size = f:seek("end") or 0
  f:close()
  return size
end

--- Returns the JSON payload of the LAST "BRIDGE_TEST_RESULT {...}" line
--- appearing in LOG_PATH at or after byte offset `bookmark`, or nil if
--- none is there yet. %b{} is Lua's balanced-match pattern, so this is
--- safe even though the payload itself contains nested braces (theme is
--- an object).
local function findResultSince(bookmark)
  local f = io.open(LOG_PATH, "r")
  if not f then
    return nil
  end
  f:seek("set", bookmark or 0)
  local tail = f:read("a") or ""
  f:close()

  local found = nil
  for line in tail:gmatch("[^\n]+") do
    local json = line:match("BRIDGE_TEST_RESULT (%b{})")
    if json then
      found = json
    end
  end
  return found
end

-- Runs inside the page once evaluated. Fire-and-forget on purpose: it
-- reports its own result via the existing gallery.log() bridge call
-- (already a one-way, no-reply message) instead of relying on Lua
-- observing an evaluateJavaScript completion handler, which -- per the
-- big comment above -- cannot fire within the same invocation that
-- issues it anyway.
local SELF_ASSERT_JS = [[
(async function () {
  var out = { execCode: null, execError: null, accentType: null, cssVarAccent: null };
  try {
    out.accentType = typeof (window.gallery && window.gallery.theme && window.gallery.theme.accent);
  } catch (e) {
    out.accentTypeError = String(e && e.message || e);
  }
  try {
    out.cssVarAccent = getComputedStyle(document.documentElement).getPropertyValue("--gallery-accent").trim();
  } catch (e) {
    out.cssVarError = String(e && e.message || e);
  }
  try {
    var r = await window.gallery.exec("/usr/bin/true", []);
    out.execCode = r.code;
  } catch (e) {
    out.execError = String(e && e.message || e);
  }
  if (window.gallery && typeof window.gallery.log === "function") {
    window.gallery.log("BRIDGE_TEST_RESULT " + JSON.stringify(out));
  }
})();
]]

------------------------------------------------------------------------
-- Phase dispatch.
------------------------------------------------------------------------
local win = spoon.Gallery.windows[PLUGIN_ID]

if not win then
  clearState()
  local openMsg = spoon.Gallery:ipc("open", PLUGIN_ID)
  writeState({ bookmark = logEndOffset(), issued = false })
  return "PHASE1 open: " .. tostring(openMsg)
    .. " -- rerun this file (after ~1s) to run the in-page assertions"
end

local state = readState()
if not state then
  -- Open (by us or something else) but no bookmark of our own -- treat
  -- this run as phase 1 without reopening (already open).
  state = { bookmark = logEndOffset(), issued = false }
  writeState(state)
end

if not state.issued then
  local evalOk, evalErr = pcall(function() win:evaluateJavaScript(SELF_ASSERT_JS) end)
  if not evalOk then
    return "PHASE2 FAILED to evaluate self-assert script: " .. tostring(evalErr)
  end
  state.issued = true
  writeState(state)
  return "PHASE2 assertions issued -- rerun this file (after ~2s) to collect the result"
end

local resultJson = findResultSince(state.bookmark)
if not resultJson then
  return "PHASE2b waiting for the in-page assertions to resolve -- rerun this file shortly"
end

------------------------------------------------------------------------
-- Phase 3: parse, assert, close, assert windows=0.
------------------------------------------------------------------------
local decodeOk, result = pcall(hs.json.decode, resultJson)
if not decodeOk or type(result) ~= "table" then
  result = {}
  check("BRIDGE_TEST_RESULT payload decodes as JSON", false, "raw=" .. tostring(resultJson))
else
  check("BRIDGE_TEST_RESULT payload decodes as JSON", true)
end

check(
  "gallery.exec(\"/usr/bin/true\", []) resolves with code 0",
  result.execCode == 0,
  "execCode=" .. tostring(result.execCode) .. " execError=" .. tostring(result.execError)
)
check(
  "typeof gallery.theme.accent === \"string\"",
  result.accentType == "string",
  "accentType=" .. tostring(result.accentType) .. " accentTypeError=" .. tostring(result.accentTypeError)
)
check(
  "--gallery-accent CSS custom property is non-empty",
  type(result.cssVarAccent) == "string" and result.cssVarAccent ~= "",
  "cssVarAccent=" .. tostring(result.cssVarAccent) .. " cssVarError=" .. tostring(result.cssVarError)
)

local closeMsg = spoon.Gallery:ipc("close", PLUGIN_ID)
check("close reported success", tostring(closeMsg):match("^closed") ~= nil, tostring(closeMsg))

local windowCount = 0
for _ in pairs(spoon.Gallery.windows) do
  windowCount = windowCount + 1
end
check("spoon.Gallery.windows is empty after close", windowCount == 0, "windows=" .. tostring(windowCount))

clearState()

-- TESTS_DIR is unused beyond documenting self-location parity with
-- tests/manifest_test.lua; keep the reference so it isn't flagged dead.
local _ = TESTS_DIR

return report()
