-- tests/kinds_test.lua -- headless tests for the Phase 3 plugin kinds
-- (menu, overlay, service, bar-widget) added in Gallery.spoon/lib/{menu,
-- overlay,service,feed}.lua, plus the open/close/toggle kind routing in
-- Gallery.spoon/init.lua.
--
-- Unlike tests/manifest_test.lua (which dofiles library modules in
-- isolation, no live Spoon involved), this test needs a REAL, already
-- running Gallery Spoon: opening a menu/overlay creates actual
-- hs.chooser/hs.webview objects, and a service/widget's runNow spawns a
-- real hs.task. It therefore assumes Hammerspoon is already up with
-- Gallery installed, started, and its plugins (including the four demo
-- plugins this test exercises) scanned -- see tests/run.sh, which runs
-- this file after its "gallery status" smoke test -- and references the
-- live `spoon.Gallery` global directly rather than dofile'ing anything.
--
-- Invoke with:
--   hs -t 30 -q /absolute/path/to/tests/kinds_test.lua
--
-- (hs runs a file directly when given a path starting with "/", sending
-- its CONTENT to the already-running Hammerspoon to be loaded -- see the
-- longer note in tests/manifest_test.lua for why self-location below uses
-- `_cli.args[1]` rather than debug.getinfo.) `-q` suppresses ordinary
-- print() output, so this file builds up its report and returns it as the
-- chunk's final value rather than printing along the way; the final line
-- is "PASS <n>" if every check passed, or "FAIL" plus a list of failing
-- checks below it -- tests/run.sh greps for "^PASS ".

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

if not (spoon and spoon.Gallery) then
  check("spoon.Gallery is loaded", false, "run this against a live, installed Hammerspoon+Gallery (see tests/run.sh)")
  return report()
end

local Gallery = spoon.Gallery

-- Make sure the demo plugins this test exercises are scanned and their
-- service/widget timers scheduled before anything below relies on them
-- (install.sh's file watcher already triggers a reload on plugin changes,
-- but rescan is cheap and idempotent, so do it explicitly rather than
-- assuming that raced to completion first).
Gallery:ipc("rescan")

local function hammerspoonWindowCount()
  local n = 0
  local ok, windows = pcall(hs.window.allWindows)
  if not ok or type(windows) ~= "table" then
    return n
  end
  for _, w in ipairs(windows) do
    local appOk, name = pcall(function() return w:application():name() end)
    if appOk and name == "Hammerspoon" then
      n = n + 1
    end
  end
  return n
end

--------------------------------------------------------------------------
-- 1. menu kind: gallery.menu-demo opens/closes an hs.chooser.
--------------------------------------------------------------------------
do
  local Menu = Gallery.Menu
  check("Menu module is wired onto the Spoon", Menu ~= nil)

  if Menu then
    check("menu-demo not open before test", not Menu.isOpen("gallery.menu-demo"))

    local openResult = Gallery:ipc("open", "gallery.menu-demo")
    check("menu-demo open reports opened", tostring(openResult):find("^opened") ~= nil, tostring(openResult))
    check("menu-demo chooser reports visible", Menu.isOpen("gallery.menu-demo"), tostring(openResult))

    local closeResult = Gallery:ipc("close", "gallery.menu-demo")
    check("menu-demo close reports closed", tostring(closeResult):find("^closed") ~= nil, tostring(closeResult))
    check("menu-demo chooser reports hidden after close", not Menu.isOpen("gallery.menu-demo"), tostring(closeResult))
  end
end

--------------------------------------------------------------------------
-- 2. overlay kind: gallery.overlay-demo opens/closes a full-display webview.
--------------------------------------------------------------------------
do
  local Overlay = Gallery.Overlay
  check("Overlay module is wired onto the Spoon", Overlay ~= nil)

  if Overlay then
    check("overlay-demo not open before test", not Overlay.isOpen("gallery.overlay-demo"))

    local before = hammerspoonWindowCount()
    local openResult = Gallery:ipc("open", "gallery.overlay-demo")
    check("overlay-demo open reports opened", tostring(openResult):find("^opened") ~= nil, tostring(openResult))
    check("overlay-demo webview reports open", Overlay.isOpen("gallery.overlay-demo"), tostring(openResult))
    local during = hammerspoonWindowCount()
    check("overlay-demo adds a Hammerspoon window", during > before, "before=" .. before .. " during=" .. during)

    local closeResult = Gallery:ipc("close", "gallery.overlay-demo")
    check("overlay-demo close reports closed", tostring(closeResult):find("^closed") ~= nil, tostring(closeResult))
    check("overlay-demo webview reports closed", not Overlay.isOpen("gallery.overlay-demo"), tostring(closeResult))
    -- NOT asserted here: that hammerspoonWindowCount() returns to `before`
    -- immediately after close. Confirmed by hand (see the worklog) that it
    -- does, but only once the window server has actually torn down the
    -- webview's NSWindow -- which needs a run-loop turn this single
    -- synchronous `hs -q` chunk never yields back for. Across separate `hs
    -- -c` calls (e.g. via ~/bin/gallery, with the shell between them) the
    -- count reliably returns to baseline; Overlay.isOpen() above is the
    -- reliable same-chunk signal that close actually ran.
  end
end

--------------------------------------------------------------------------
-- 3. service kind: gallery.service-demo writes a heartbeat on demand.
--------------------------------------------------------------------------
do
  local Service = Gallery.Service
  check("Service module is wired onto the Spoon", Service ~= nil)

  if Service then
    local runResult = Service.runNow("gallery.service-demo")
    check("service-demo runNow reports ran", tostring(runResult):find("^ran") ~= nil, tostring(runResult))

    local heartbeatPath = os.getenv("HOME") .. "/.config/gallery/state/services/gallery.service-demo.json"
    local readOk, heartbeat = pcall(hs.json.read, heartbeatPath)
    check("service-demo heartbeat file parses", readOk and type(heartbeat) == "table", tostring(heartbeat))
    if readOk and type(heartbeat) == "table" then
      check("service-demo heartbeat has numeric lastRun", type(heartbeat.lastRun) == "number")
      check("service-demo heartbeat exit code is 0", heartbeat.code == 0, tostring(heartbeat.code))
    end

    local lines = Service.statusLines()
    local found = false
    for _, line in ipairs(lines) do
      if line:find("gallery.service-demo", 1, true) then
        found = true
      end
    end
    check("services status includes gallery.service-demo", found, table.concat(lines, " | "))
  end
end

--------------------------------------------------------------------------
-- 4. bar-widget kind: gallery.widget-demo writes a feed file on demand.
--------------------------------------------------------------------------
do
  local Feed = Gallery.Feed
  check("Feed module is wired onto the Spoon", Feed ~= nil)

  if Feed then
    local runResult = Feed.runNow("gallery.widget-demo")
    check("widget-demo runNow reports ran", tostring(runResult):find("^ran") ~= nil, tostring(runResult))

    local feedPath = os.getenv("HOME") .. "/.config/gallery/feed/gallery.widget-demo.json"
    local readOk, feed = pcall(hs.json.read, feedPath)
    check("widget-demo feed file parses", readOk and type(feed) == "table", tostring(feed))
    if readOk and type(feed) == "table" then
      check("widget-demo feed has numeric updatedAt", type(feed.updatedAt) == "number")
    end

    local feedIpc = Gallery:ipc("feed", "gallery.widget-demo")
    local decodeOk, decoded = pcall(hs.json.decode, feedIpc)
    check("feed ipc verb returns parseable JSON", decodeOk and type(decoded) == "table", tostring(feedIpc))
  end
end

--------------------------------------------------------------------------
-- 5. Routing: a plugin with only a non-interactive kind refuses open.
--------------------------------------------------------------------------
do
  local result = Gallery:ipc("open", "gallery.service-demo")
  check("service-only plugin refuses open", result == "no interactive kind: gallery.service-demo", tostring(result))
end

return report()
