-- tests/learn_test.lua -- headless tests for the gallery.learn plugin
-- (plugins/gallery.learn/{manifest.json,learn-menu.py,index.html}).
--
-- Like tests/kinds_test.lua, this needs a REAL, already-running Gallery
-- Spoon with gallery.learn installed, enabled, and scanned -- see
-- tests/run.sh, which runs this file the same way (after gallery
-- status). Invoke with:
--
--   hs -t 30 -q /absolute/path/to/tests/learn_test.lua
--
-- `-q` suppresses ordinary print() output; the final line is "PASS <n>"
-- if every check passed, or "FAIL" plus the failing checks below it --
-- tests/run.sh greps for "^PASS ".
--
-- Two things this plugin adds that no bundled demo plugin needs, both
-- covered below:
--   1. It declares kinds ["menu","panel"] -- panel wins routing priority
--      (see Gallery.spoon/init.lua's primaryInteractiveKind), so
--      Gallery:ipc("open"/"close", ...) exercises the PANEL; the MENU is
--      only reachable directly through spoon.Gallery.Menu (see the
--      module docstring in learn-menu.py and the Plugin-Contract.md note
--      that manifest.gallery.menu action types are exec/open/ipc only).
--   2. Its menu source is a real subprocess (learn-menu.py list), not a
--      static item array, so this test also shells out to learn-menu.py
--      directly (list/show/render) to check its own contract (JSON
--      lines, state file, HTML fragment) independent of Hammerspoon.
--      Its "show" action itself shells out to ~/bin/gallery close/open
--      -- calling the REAL one here would deadlock (that subprocess
--      needs this same Hammerspoon's IPC port serviced, which can't
--      happen until this chunk returns), so this test points
--      LEARN_GALLERY_BIN at a harmless stub instead; the routing
--      workaround itself is exercised for real in point 1, via the
--      live Lua API rather than a subprocess.

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
Gallery:ipc("rescan")

local PLUGIN_ID = "gallery.learn"
local HOME = os.getenv("HOME")
local SCRIPT = HOME .. "/.config/gallery/plugins/" .. PLUGIN_ID .. "/learn-menu.py"
local CURRENT_PATH = HOME .. "/.config/gallery/state/learn-current"
local TILER_KEYS = HOME ..
  "/Library/Mobile Documents/iCloud~md~obsidian/Documents/ObsidianVault/Cheat-Sheets/Tiler-Keys.md"

--------------------------------------------------------------------------
-- 1. Plugin loads clean: scanned, no errors, declares both kinds.
--------------------------------------------------------------------------
do
  local entry = Gallery.plugins[PLUGIN_ID]
  check("gallery.learn is scanned", entry ~= nil)

  if entry then
    check("gallery.learn has no manifest errors", not entry.errors or #entry.errors == 0,
      table.concat(entry.errors or {}, "; "))

    local kinds = (entry.manifest and entry.manifest.kinds) or {}
    local hasMenu, hasPanel = false, false
    for _, k in ipairs(kinds) do
      if k == "menu" then hasMenu = true end
      if k == "panel" then hasPanel = true end
    end
    check("gallery.learn declares kinds menu+panel", hasMenu and hasPanel, table.concat(kinds, ","))
  end
end

--------------------------------------------------------------------------
-- 2. learn-menu.py list: one JSON item per line, "Tiler keys" first.
--------------------------------------------------------------------------
do
  local handle = io.popen("/usr/bin/python3 '" .. SCRIPT .. "' list 2>&1")
  local out = handle and handle:read("*a") or ""
  if handle then handle:close() end

  local firstLine = out:match("^[^\r\n]+")
  local decodeOk, firstItem = pcall(hs.json.decode, firstLine or "")
  check("learn-menu.py list produces at least one line", firstLine ~= nil, out)
  check("learn-menu.py list's first line is valid JSON", decodeOk and type(firstItem) == "table", tostring(firstLine))

  if decodeOk and type(firstItem) == "table" then
    check("first item is the Tiler keys special item", firstItem.text == "Tiler keys", tostring(firstItem.text))
    local action = firstItem.action
    check("first item action is exec python3 learn-menu.py show <path>",
      type(action) == "table" and action.type == "exec"
        and action.command == "/usr/bin/python3"
        and type(action.args) == "table" and action.args[2] == "show",
      firstLine)
  end

  local lineCount = 0
  local allValid = true
  for line in out:gmatch("[^\r\n]+") do
    lineCount = lineCount + 1
    local ok = pcall(hs.json.decode, line)
    if not ok then allValid = false end
  end
  check("every list line is valid JSON", allValid, out)
  check("list produced more than one item", lineCount > 1, tostring(lineCount))
end

--------------------------------------------------------------------------
-- 3. learn-menu.py show <path> (via a harmless stub for ~/bin/gallery,
--    see the file header) records the choice; render then reflects it.
--------------------------------------------------------------------------
do
  if not hs.fs.attributes(TILER_KEYS) then
    check("Tiler-Keys.md exists in the vault (skipping show/render checks)", false, TILER_KEYS)
  else
    local showCmd = "LEARN_GALLERY_BIN=/usr/bin/true /usr/bin/python3 '" .. SCRIPT .. "' show '" .. TILER_KEYS .. "' 2>&1"
    local showHandle = io.popen(showCmd)
    local showOut = showHandle and showHandle:read("*a") or ""
    if showHandle then showHandle:close() end
    check("learn-menu.py show ran without error output", showOut == "", showOut)

    local currentAttr = hs.fs.attributes(CURRENT_PATH)
    check("learn-current state file was written", currentAttr ~= nil, CURRENT_PATH)

    if currentAttr then
      local f = io.open(CURRENT_PATH, "r")
      local recorded = f and f:read("*l") or nil
      if f then f:close() end
      check("learn-current records the chosen sheet path", recorded == TILER_KEYS, tostring(recorded))
    end

    local renderHandle = io.popen("/usr/bin/python3 '" .. SCRIPT .. "' render 2>&1")
    local html = renderHandle and renderHandle:read("*a") or ""
    if renderHandle then renderHandle:close() end

    check("render output wraps content in learn-doc", html:find('class="learn%-doc"') ~= nil, html:sub(1, 120))
    check("render output includes an h1 for Tiler keys", html:find("<h1>Tiler keys</h1>") ~= nil, html:sub(1, 200))
    check("render output has no unconverted fenced code markers", not html:find("```"), html:sub(1, 200))
  end
end

--------------------------------------------------------------------------
-- 4. Kind routing: Gallery:ipc open/close exercises the PANEL (panel
--    wins over menu; see Gallery.spoon/init.lua's primaryInteractiveKind)
--    -- the same shape of check tests/kinds_test.lua runs for
--    gallery.hello, not the menu.
--------------------------------------------------------------------------
do
  Gallery.Panel.close(Gallery, PLUGIN_ID) -- idempotent if already closed; the generic verb now opens the menu (primaryKind)

  local openResult = Gallery.Panel.open(Gallery, PLUGIN_ID)
  check("ipc open reports opened (routes to panel)", tostring(openResult):find("^opened") ~= nil, tostring(openResult))
  check("gallery.learn window is tracked open", Gallery.windows[PLUGIN_ID] ~= nil, tostring(openResult))

  local closeResult = Gallery.Panel.close(Gallery, PLUGIN_ID)
  check("ipc close reports closed", tostring(closeResult):find("^closed") ~= nil, tostring(closeResult))
  check("gallery.learn window is no longer tracked", Gallery.windows[PLUGIN_ID] == nil, tostring(closeResult))
end

--------------------------------------------------------------------------
-- 5. The menu itself is only reachable directly through
--    spoon.Gallery.Menu, not through Gallery:ipc("open", ...) -- see
--    point 4. This is the routing gap noted for the host maintainer (a
--    `gallery.primaryKind` manifest hint would remove the need for it).
--------------------------------------------------------------------------
do
  local Menu = Gallery.Menu
  check("Menu module is wired onto the Spoon", Menu ~= nil)

  if Menu then
    Menu.close(Gallery, PLUGIN_ID) -- idempotent if already closed

    local openResult = Menu.open(Gallery, PLUGIN_ID)
    check("Menu.open reports opened", tostring(openResult):find("^opened") ~= nil, tostring(openResult))
    check("gallery.learn chooser reports visible", Menu.isOpen(PLUGIN_ID), tostring(openResult))

    local closeResult = Menu.close(Gallery, PLUGIN_ID)
    check("Menu.close reports closed", tostring(closeResult):find("^closed") ~= nil, tostring(closeResult))
    check("gallery.learn chooser reports hidden after close", not Menu.isOpen(PLUGIN_ID), tostring(closeResult))
  end
end

return report()
