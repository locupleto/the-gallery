--- === Gallery ===
---
--- Hosts manifest-driven desktop plugins (panels, overlays, menus, services)
--- on macOS, modelled on Omarchy 4's plugin system. Each plugin is a
--- directory under obj.pluginDir containing a manifest.json; Gallery scans
--- that directory at start, validates each manifest, and exposes an IPC
--- surface (see obj:ipc) that the `gallery` CLI drives.
---
--- Phase 2: this file is the Spoon object only (metadata, start/stop, IPC
--- dispatch, logging shim). The actual work lives in lib/, loaded below:
---   lib/log.lua      -- append-only log
---   lib/manifest.lua -- plugin discovery + manifest validation
---   lib/state.lua    -- ~/.config/gallery/gallery.json (enable/disable)
---   lib/panel.lua    -- webview open/close mechanics for panel-kind plugins

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "Gallery"
obj.version = "0.1.0"
obj.author = "Urban Ottosson"
obj.license = "MIT"
obj.homepage = "https://github.com/locupleto/the-gallery"

obj.pluginDir = os.getenv("HOME") .. "/.config/gallery/plugins"
-- Written at the end of start(); the installer waits for it instead of probing
-- the IPC port, because a probe killed mid-request can wedge or crash Hammerspoon.
obj.readyPath = os.getenv("HOME") .. "/.config/gallery/state/ready"
obj.plugins = {}
obj.pluginList = {}
obj.windows = {}
-- Keyed by plugin id: the hs.window that was frontmost immediately before
-- that plugin's panel was shown, captured so focus can be restored to it
-- on close (see manifest.gallery.panel.restoreFocus). Read/written by
-- lib/panel.lua.
obj.previousFocusWindow = {}

--- Resolve a path within this Spoon's own directory. Prefers
--- hs.spoons.resourcePath (see https://www.hammerspoon.org/docs/hs.spoons.html,
--- confirmed present in this Hammerspoon build), which derives the Spoon's
--- directory from the call stack of whoever calls it; wrapping the call in
--- an anonymous function here keeps that stack lookup pointed at this file.
--- Falls back to deriving the directory from this file's own
--- debug.getinfo source if resourcePath is ever unavailable.
local function resourcePath(partial)
  local ok, result = pcall(function() return hs.spoons.resourcePath(partial) end)
  if ok and result then
    return result
  end
  local source = debug.getinfo(1, "S").source:sub(2)
  local dir = source:match("(.*/)") or "./"
  return dir .. partial
end

local Log = dofile(resourcePath("lib/log.lua"))
local Manifest = dofile(resourcePath("lib/manifest.lua"))
local State = dofile(resourcePath("lib/state.lua"))
local Panel = dofile(resourcePath("lib/panel.lua"))

Log.path = os.getenv("HOME") .. "/Library/Logs/gallery.log"
obj.statePath = State.defaultPath()

--- Append a timestamped line to Log.path and print to the Hammerspoon
--- console. Never raises. Also exposed on obj (as obj.log) so lib/panel.lua
--- can call ctx.log(level, msg) without a global.
local function log(level, msg)
  Log.log(level, msg)
end
obj.log = log

--- True if id claims the first-party "gallery." namespace.
local function isFirstParty(id)
  return type(id) == "string" and id:match("^gallery%.") ~= nil
end

--- Preload the hs.* extensions Gallery depends on. Extensions are loaded
--- eagerly here so the first panel open does not pay their load cost
--- (measured at about 2.5 s cold) and so their console banners do not leak
--- into CLI output.
local function preloadExtensions()
  for _, name in ipairs({
    "hs.webview",
    "hs.webview.usercontent",
    "hs.mouse",
    "hs.screen",
    "hs.drawing",
    "hs.canvas",
    "hs.json",
    "hs.fs",
    "hs.application",
    "hs.window",
    "hs.pathwatcher",
  }) do
    pcall(require, name)
  end
end

--- Re-scan obj.pluginDir and rebuild obj.plugins / obj.pluginList. Never
--- raises (Manifest.scan doesn't either). Returns total, errored counts.
local function loadPlugins(self)
  local results = Manifest.scan(self.pluginDir)
  table.sort(results, function(a, b)
    return tostring(a.id or a.dir) < tostring(b.id or b.dir)
  end)

  self.plugins = {}
  self.pluginList = results

  local errored = 0
  for _, entry in ipairs(results) do
    local key = (entry.id and entry.id ~= "") and entry.id or entry.dir
    self.plugins[key] = entry
    if entry.errors and #entry.errors > 0 then
      errored = errored + 1
      log("WARN", "errored plugin " .. tostring(entry.id or entry.dir) .. " (" .. entry.dir .. "): " .. table.concat(entry.errors, "; "))
    else
      log("INFO", "loaded plugin " .. tostring(entry.id) .. " from " .. entry.dir)
      if entry.warnings and #entry.warnings > 0 then
        log("WARN", "plugin " .. tostring(entry.id) .. " has warnings: " .. table.concat(entry.warnings, "; "))
      end
    end
  end

  return #results, errored
end

function obj:start()
  preloadExtensions()
  self.windows = self.windows or {}
  self.previousFocusWindow = self.previousFocusWindow or {}

  loadPlugins(self)
  self.state = State.load(self.statePath)

  pcall(function()
    hs.fs.mkdir(os.getenv("HOME") .. "/.config/gallery/state")
    local f = io.open(self.readyPath, "w")
    if f then f:write(string.format("%d %s\n", os.time(), obj.version)); f:close() end
  end)
  return self
end

--- Close every open plugin window.
function obj:stop()
  for id, win in pairs(self.windows) do
    pcall(function() win:delete() end)
    self.windows[id] = nil
  end
  self.previousFocusWindow = {}
  return self
end

--- Dispatch an IPC verb from the `gallery` CLI. Always returns a string,
--- even on error, and never raises out of this function.
function obj:ipc(verb, id)
  local ok, result = pcall(function()
    if verb == "status" then
      return self:status()
    elseif verb == "list" then
      return self:list()
    elseif verb == "list-json" then
      return self:listJson()
    elseif verb == "open" then
      return self:open(id)
    elseif verb == "close" then
      return self:close(id)
    elseif verb == "toggle" then
      return self:toggle(id)
    elseif verb == "enable" then
      return self:enable(id)
    elseif verb == "disable" then
      return self:disable(id)
    elseif verb == "validate" then
      return self:validateDir(id)
    elseif verb == "rescan" then
      return self:rescan()
    else
      return "unknown verb: " .. tostring(verb)
    end
  end)

  if ok then
    return result
  end

  log("ERROR", "ipc error for verb " .. tostring(verb) .. ": " .. tostring(result))
  return "error: " .. tostring(result)
end

--- One-line summary of Gallery's current state.
function obj:status()
  local pluginCount = 0
  local erroredCount = 0
  for _, entry in pairs(self.plugins) do
    if entry.errors and #entry.errors > 0 then
      erroredCount = erroredCount + 1
    else
      pluginCount = pluginCount + 1
    end
  end

  local windowCount = 0
  for _ in pairs(self.windows) do
    windowCount = windowCount + 1
  end

  return string.format(
    "Gallery %s; plugins=%d; errored=%d; pluginDir=%s; windows=%d",
    obj.version,
    pluginCount,
    erroredCount,
    self.pluginDir,
    windowCount
  )
end

--- One line per scanned plugin: "<id>\t<version>\t<kinds joined by comma>\t<state>",
--- state being enabled|disabled|errored.
function obj:list()
  local lines = {}
  for _, entry in ipairs(self.pluginList) do
    local manifest = entry.manifest or {}
    local state
    if entry.errors and #entry.errors > 0 then
      state = "errored"
    elseif State.isEnabled(self.state, entry.id, isFirstParty(entry.id)) then
      state = "enabled"
    else
      state = "disabled"
    end
    local kinds = table.concat(manifest.kinds or {}, ",")
    table.insert(lines, string.format("%s\t%s\t%s\t%s", tostring(entry.id), tostring(manifest.version or ""), kinds, state))
  end
  table.sort(lines)
  return table.concat(lines, "\n")
end

--- JSON array of {id,name,version,kinds,enabled,errored,errors,warnings,dir}
--- for every scanned plugin.
function obj:listJson()
  local out = {}
  for _, entry in ipairs(self.pluginList) do
    local manifest = entry.manifest or {}
    local errored = (entry.errors and #entry.errors > 0) or false
    table.insert(out, {
      id = entry.id,
      name = manifest.name,
      version = manifest.version,
      kinds = manifest.kinds or {},
      enabled = (not errored) and State.isEnabled(self.state, entry.id, isFirstParty(entry.id)) or false,
      errored = errored,
      errors = entry.errors or {},
      warnings = entry.warnings or {},
      dir = entry.dir,
    })
  end

  local encodeOk, encoded = pcall(hs.json.encode, out)
  if not encodeOk then
    error("failed to encode plugin list: " .. tostring(encoded))
  end
  return encoded
end

--- Open a panel-kind plugin's window (see lib/panel.lua). Refuses unknown,
--- errored, and disabled plugins.
function obj:open(id)
  if not id or id == "" then
    return "usage: open <id>"
  end

  local entry = self.plugins[id]
  if not entry then
    return "unknown plugin: " .. id
  end

  if entry.errors and #entry.errors > 0 then
    return "errored: " .. id .. " (" .. table.concat(entry.errors, "; ") .. ")"
  end

  if not State.isEnabled(self.state, id, isFirstParty(id)) then
    return "not enabled: " .. id
  end

  return Panel.open(self, id)
end

--- Close a plugin's open window (see lib/panel.lua). Deliberately
--- permissive -- not gated on enabled/errored state -- so an already-open
--- window can always be closed (obj:disable relies on this).
function obj:close(id)
  if not id or id == "" then
    return "usage: close <id>"
  end
  return Panel.close(self, id)
end

--- Open if not currently open, otherwise close.
function obj:toggle(id)
  if not id or id == "" then
    return "usage: toggle <id>"
  end
  if self.windows[id] then
    return self:close(id)
  end
  return self:open(id)
end

--- Mark a plugin enabled and persist it to gallery.json.
function obj:enable(id)
  if not id or id == "" then
    return "usage: enable <id>"
  end
  local entry = self.plugins[id]
  if not entry then
    return "unknown plugin: " .. id
  end

  State.enable(self.state, id, self.statePath)
  log("INFO", "enabled " .. id)
  return "enabled: " .. id
end

--- Mark a plugin disabled and persist it to gallery.json, closing its
--- window first if open.
function obj:disable(id)
  if not id or id == "" then
    return "usage: disable <id>"
  end
  local entry = self.plugins[id]
  if not entry then
    return "unknown plugin: " .. id
  end

  if self.windows[id] then
    self:close(id)
  end

  State.disable(self.state, id, self.statePath)
  log("INFO", "disabled " .. id)
  return "disabled: " .. id
end

--- Validate the manifest.json in an arbitrary directory (not necessarily
--- one Gallery has scanned) and report errors/warnings as text.
function obj:validateDir(dir)
  if not dir or dir == "" then
    return "usage: validate <dir>"
  end

  local manifestPath = dir .. "/manifest.json"
  local readOk, manifest = pcall(hs.json.read, manifestPath)
  if not readOk or not manifest then
    return "errors:\nfailed to read/decode manifest at " .. manifestPath
  end

  local errors, warnings = Manifest.validate(manifest, dir)
  local lines = {}
  if #errors > 0 then
    -- bin/gallery's cmd_validate/cmd_add match on the "errors:" prefix.
    table.insert(lines, "errors:")
    for _, e in ipairs(errors) do table.insert(lines, e) end
    if #warnings > 0 then
      table.insert(lines, "warnings:")
      for _, w in ipairs(warnings) do table.insert(lines, w) end
    end
  elseif #warnings > 0 then
    -- bin/gallery's cmd_add matches on a bare "warnings:" prefix (not
    -- "ok\nwarnings:...") for the warnings-only case.
    table.insert(lines, "warnings:")
    for _, w in ipairs(warnings) do table.insert(lines, w) end
  else
    -- bin/gallery's cmd_validate/cmd_add match on the exact string "ok".
    table.insert(lines, "ok")
  end
  return table.concat(lines, "\n")
end

--- Re-run the manifest scan without a full Hammerspoon reload.
function obj:rescan()
  local total, errored = loadPlugins(self)
  return string.format("rescanned: plugins=%d errored=%d", total - errored, errored)
end

return obj
