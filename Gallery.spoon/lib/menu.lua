--- lib/menu.lua -- kind "menu" via hs.chooser.
---
--- ctx is expected to expose:
---   ctx.plugins        -- map: id -> {manifest, dir, errors, warnings}
---   ctx.log(level, msg) -- logging function
---   ctx:ipc(verb, id)   -- for a chosen item's action.type == "ipc"
---
--- Deliberately keeps its own module-level state (M.choosers: map id ->
--- hs.chooser) rather than storing choosers on ctx -- tests (see
--- tests/kinds_test.lua) inspect that state directly through
--- spoon.Gallery.Menu rather than needing to poke at hs.chooser globals.
---
--- Items come from manifest.gallery.menu.source, one of:
---   {"type":"static","items":[{...}, ...]}
---   {"type":"command","command":"/path/bin","args":[...]}
--- For "command", the process is run synchronously (hs.task:start() then
--- :waitUntilExit()) and its stdout is read as one JSON object per line;
--- each decoded line becomes a choice. A line that fails to decode is
--- skipped and logged, never raised.
---
--- Each item is expected to look like:
---   {"text":"...", "subText":"...",
---    "action":{"type":"exec","command":"...","args":[...]}
---             |{"type":"open","url":"..."}
---             |{"type":"ipc","verb":"...","id":"..."}}
--- The whole item table is handed to hs.chooser as a choice, "action" and
--- all -- hs.chooser does not care about extra keys, and hands the chosen
--- table straight back to the completion callback, so no separate
--- id-to-item bookkeeping is needed.
---
--- Returns a table with .open(ctx, id), .close(ctx, id), .toggle(ctx, id),
--- .isOpen(id), and the .choosers state table itself.

-- Expand a leading "~" in a command path or argument so manifests need not
-- hardcode the home directory.
local function expandHome(v)
  if type(v) == "string" and v:sub(1, 2) == "~/" then
    return os.getenv("HOME") .. v:sub(2)
  end
  return v
end
local function expandArgs(list)
  local out = {}
  for i, a in ipairs(list or {}) do out[i] = expandHome(a) end
  return out
end

local M = {}

M.choosers = {}

local DEFAULT_WIDTH = 40
local DEFAULT_ROWS = 10

local function tableContains(t, value)
  if type(t) ~= "table" then
    return false
  end
  for _, v in ipairs(t) do
    if v == value then
      return true
    end
  end
  return false
end

local function loadStaticItems(sourceCfg)
  if type(sourceCfg.items) == "table" then
    return sourceCfg.items
  end
  return {}
end

--- Run sourceCfg.command (with sourceCfg.args) synchronously via hs.task
--- and parse its stdout as one JSON object per line. Never raises;
--- unparsable lines are skipped and logged.
local function loadCommandItems(ctx, id, sourceCfg)
  local items = {}

  local command = sourceCfg.command
  if type(command) ~= "string" or command == "" then
    ctx.log("WARN", "menu source for " .. id .. " has no command")
    return items
  end

  local args = sourceCfg.args
  if type(args) ~= "table" then
    args = {}
  end

  local stdout = ""
  local newOk, task = pcall(hs.task.new, expandHome(command), function(exitCode, out, err)
    stdout = out or ""
    if exitCode ~= 0 then
      ctx.log("WARN", "menu source command for " .. id .. " exited " .. tostring(exitCode) .. ": " .. tostring(err))
    end
  end, expandArgs(args))
  if not newOk or not task then
    ctx.log("WARN", "failed to create menu source task for " .. id)
    return items
  end

  local startOk = false
  pcall(function() startOk = task:start() end)
  if not startOk then
    ctx.log("WARN", "failed to start menu source task for " .. id)
    return items
  end
  pcall(function() task:waitUntilExit() end)

  for line in stdout:gmatch("[^\r\n]+") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" then
      local decodeOk, decoded = pcall(hs.json.decode, trimmed)
      if decodeOk and type(decoded) == "table" then
        table.insert(items, decoded)
      else
        ctx.log("WARN", "menu source line for " .. id .. " is not valid JSON: " .. trimmed)
      end
    end
  end

  return items
end

local function loadItems(ctx, id, menuCfg)
  local source = menuCfg.source
  if type(source) ~= "table" then
    ctx.log("WARN", "menu " .. id .. " has no gallery.menu.source")
    return {}
  end

  if source.type == "static" then
    return loadStaticItems(source)
  elseif source.type == "command" then
    return loadCommandItems(ctx, id, source)
  end

  ctx.log("WARN", "unknown menu source type for " .. id .. ": " .. tostring(source.type))
  return {}
end

local function runAction(ctx, id, action)
  if type(action) ~= "table" or type(action.type) ~= "string" then
    return
  end

  if action.type == "exec" then
    local command = action.command
    if type(command) == "string" and command ~= "" then
      local args = action.args
      if type(args) ~= "table" then
        args = {}
      end
      local newOk, task = pcall(hs.task.new, expandHome(command), function() end, expandArgs(args))
      if newOk and task then
        local startOk = false
        pcall(function() startOk = task:start() end)
        if not startOk then
          ctx.log("WARN", "menu action exec failed to start for " .. id)
        end
      else
        ctx.log("WARN", "menu action exec failed to create task for " .. id)
      end
    end
  elseif action.type == "open" then
    if type(action.url) == "string" and action.url ~= "" then
      pcall(hs.urlevent.openURL, action.url)
    end
  elseif action.type == "ipc" then
    if type(action.verb) == "string" then
      pcall(function() ctx:ipc(action.verb, action.id) end)
    end
  else
    ctx.log("WARN", "unknown menu action type for " .. id .. ": " .. tostring(action.type))
  end
end

--- True if id's chooser exists and reports itself visible. Never raises.
function M.isOpen(id)
  local chooser = M.choosers[id]
  if not chooser then
    return false
  end
  local ok, visible = pcall(function() return chooser:isVisible() end)
  return ok and visible == true
end

--- Show a menu-kind plugin's hs.chooser, built fresh from its
--- manifest.gallery.menu.source every time (so a "command" source picks up
--- changes without needing a rescan).
function M.open(ctx, id)
  if not id or id == "" then
    return "usage: open <id>"
  end

  local entry = ctx.plugins[id]
  if not entry then
    return "unknown plugin: " .. id
  end

  local manifest = entry.manifest
  if not tableContains(manifest.kinds, "menu") then
    return "plugin does not support menu: " .. id
  end

  if M.isOpen(id) then
    return "already open: " .. id
  end

  local menuCfg = (manifest.gallery and manifest.gallery.menu) or {}
  local items = loadItems(ctx, id, menuCfg)

  local chooser
  local newOk, newErr = pcall(function()
    chooser = hs.chooser.new(function(choice)
      M.choosers[id] = nil
      if choice then
        runAction(ctx, id, choice.action)
      end
    end)
  end)
  if not newOk or not chooser then
    ctx.log("ERROR", "failed to create chooser for " .. id .. ": " .. tostring(newErr))
    return "error: could not create menu for " .. id
  end

  pcall(function() chooser:choices(items) end)
  pcall(function() chooser:placeholderText(menuCfg.placeholder or "") end)
  pcall(function() chooser:width(menuCfg.width or DEFAULT_WIDTH) end)
  pcall(function() chooser:rows(menuCfg.rows or DEFAULT_ROWS) end)
  pcall(function() chooser:bgDark(true) end)

  M.choosers[id] = chooser
  pcall(function() chooser:show() end)

  ctx.log("INFO", "opened menu " .. id .. " with " .. tostring(#items) .. " item(s)")
  return "opened " .. id
end

--- Hide id's chooser, if shown. Deliberately permissive (no enabled/kind
--- checks) so a menu that was disabled after being opened can still be
--- closed, mirroring lib/panel.lua's M.close.
function M.close(ctx, id)
  if not id or id == "" then
    return "usage: close <id>"
  end

  local chooser = M.choosers[id]
  if not chooser then
    return "not open: " .. id
  end

  pcall(function() chooser:hide() end)
  M.choosers[id] = nil

  ctx.log("INFO", "closed menu " .. id)
  return "closed " .. id
end

function M.toggle(ctx, id)
  if not id or id == "" then
    return "usage: toggle <id>"
  end
  if M.isOpen(id) then
    return M.close(ctx, id)
  end
  return M.open(ctx, id)
end

return M
