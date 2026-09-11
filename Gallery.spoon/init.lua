--- === Gallery ===
---
--- Hosts manifest-driven desktop plugins (panels, overlays, menus, services)
--- on macOS, modelled on Omarchy 4's plugin system. Each plugin is a
--- directory under obj.pluginDir containing a manifest.json; Gallery scans
--- that directory at start, validates each manifest, and exposes an IPC
--- surface (see obj:ipc) that the `gallery` CLI drives.
---
--- Phase 2/3: this file is the Spoon object only (metadata, start/stop,
--- IPC dispatch, logging shim, and -- the only Phase 3 addition here --
--- routing open/close/toggle to the right kind module). The actual work
--- lives in lib/, loaded below:
---   lib/log.lua      -- append-only log
---   lib/manifest.lua -- plugin discovery + manifest validation
---   lib/state.lua    -- ~/.config/gallery/gallery.json (enable/disable)
---   lib/panel.lua    -- webview open/close mechanics for panel-kind plugins
---   lib/menu.lua     -- hs.chooser mechanics for menu-kind plugins
---   lib/overlay.lua  -- webview mechanics for overlay-kind plugins
---   lib/service.lua  -- background timers for service-kind plugins
---   lib/feed.lua     -- background timers for bar-widget-kind plugins
---
--- A plugin's primary interactive kind -- the one open/close/toggle act
--- on -- is chosen in priority order panel > overlay > menu (see
--- primaryInteractiveKind below). service and bar-widget are not
--- interactive: they run continuously once enabled (see lib/service.lua,
--- lib/feed.lua) and are inspected via the `services`/`feed` IPC verbs
--- rather than opened/closed.

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "Gallery"
obj.version = "0.1.0"
obj.author = "Urban Ottosson"
obj.license = "MIT"
obj.homepage = "https://github.com/locupleto/the-gallery"

obj.pluginDir = os.getenv("HOME") .. "/.config/gallery/plugins"
obj.themesDir = os.getenv("HOME") .. "/.config/gallery/themes"
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
local Theme = dofile(resourcePath("lib/theme.lua"))
local Panel = dofile(resourcePath("lib/panel.lua"))
local Menu = dofile(resourcePath("lib/menu.lua"))
local Overlay = dofile(resourcePath("lib/overlay.lua"))
local Service = dofile(resourcePath("lib/service.lua"))
local Feed = dofile(resourcePath("lib/feed.lua"))

-- Exposed on the Spoon object itself (not just as local upvalues) so
-- tests (tests/kinds_test.lua) can introspect each module's own state --
-- e.g. spoon.Gallery.Menu.isOpen(id) -- through the live, already-running
-- instance rather than dofile'ing a disconnected copy.
obj.Menu = Menu
obj.Panel = Panel -- exposed for tests and tooling; open/close/toggle route by kind
obj.Overlay = Overlay
obj.Service = Service
obj.Feed = Feed

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

--- hs.json.encode(v) raises for a bare scalar (confirmed by hand, same
--- gotcha lib/bridge.lua's own encodeJson documents) -- wrap it in a
--- 1-element array and strip the brackets, so a plain Lua string still
--- goes through hs.json's own escaping rather than reimplementing it.
--- Used only to embed the re-inject script's CSS text as a JS string
--- literal (see obj:themeReload).
local function encodeJsonScalar(value)
  local ok, wrapped = pcall(hs.json.encode, { value })
  if not ok then
    return false, wrapped
  end
  return true, wrapped:sub(2, -2)
end

--- A plugin's primary interactive kind, in priority order panel > overlay
--- > menu -- the one open/close/toggle act on. Returns nil for a plugin
--- with only non-interactive kinds (service, bar-widget, bar).
local function primaryInteractiveKind(manifest)
  local kinds = manifest and manifest.kinds
  -- A plugin with several interactive kinds may say which one `open` means
  -- (manifest.gallery.primaryKind); otherwise panel > overlay > menu.
  local hint = manifest and manifest.gallery and manifest.gallery.primaryKind
  if hint and tableContains(kinds, hint) and (hint == "panel" or hint == "overlay" or hint == "menu") then
    return hint
  end
  if tableContains(kinds, "panel") then
    return "panel"
  elseif tableContains(kinds, "overlay") then
    return "overlay"
  elseif tableContains(kinds, "menu") then
    return "menu"
  end
  return nil
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
    "hs.chooser",
    "hs.task",
    "hs.urlevent",
    "hs.eventtap",
    "hs.timer",
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

  local themeOk, themeResult = pcall(Theme.load, self.themesDir)
  if themeOk and type(themeResult) == "table" then
    self.theme = themeResult
  else
    log("WARN", "failed to load theme, falling back to default: " .. tostring(themeResult))
    self.theme = Theme.defaultTokens()
  end
  log("INFO", "loaded theme " .. tostring(self.theme.name))

  -- Background kinds are scheduled last, once both self.plugins and
  -- self.state exist (Service/Feed.rescan consult self:isEnabled, which
  -- reads self.state).
  Service.rescan(self)
  Feed.rescan(self)

  pcall(function()
    hs.fs.mkdir(os.getenv("HOME") .. "/.config/gallery/state")
    local f = io.open(self.readyPath, "w")
    if f then f:write(string.format("%d %s\n", os.time(), obj.version)); f:close() end
  end)
  return self
end

--- Close every open plugin window (panel, menu, overlay) and stop every
--- running service/widget timer.
function obj:stop()
  for id, win in pairs(self.windows) do
    pcall(function() win:delete() end)
    self.windows[id] = nil
  end
  self.previousFocusWindow = {}

  for id in pairs(Menu.choosers) do
    pcall(Menu.close, self, id)
  end
  for id in pairs(Overlay.overlays) do
    pcall(Overlay.close, self, id)
  end

  Service.stopAll()
  Feed.stopAll()

  return self
end

--- True if id should be considered enabled (see lib/state.lua).
function obj:isEnabled(id)
  return State.isEnabled(self.state, id, isFirstParty(id))
end

--- "<name> light=<bool>" for the currently-loaded theme. A plain local
--- function rather than an obj:theme() method: self.theme is also the
--- DATA field lib/bridge.lua reads as ctx.theme (the token table itself,
--- set in start() and replaced by obj:themeReload()) -- a method stored
--- under that same key would collide with, and be silently clobbered by,
--- that data as soon as start() ran (confirmed by hand: self:theme()
--- raised "attempt to call a table value" once self.theme held real
--- tokens). Called directly (themeSummary(self)) from obj:ipc below
--- instead, which sidesteps the collision entirely since it is never
--- stored on obj/self at all.
local function themeSummary(self)
  local t = self.theme
  if type(t) ~= "table" then
    t = Theme.defaultTokens()
  end
  return string.format("%s light=%s", tostring(t.name), tostring(t.light and true or false))
end

--- Dispatch an IPC verb from the `gallery` CLI. Always returns a string,
--- even on error, and never raises out of this function.
function obj:ipc(verb, id)
  -- DEBUG timing so a hung client can be correlated against the log: did
  -- the handler itself ever finish, or is the reply what got lost? Uses
  -- hs.timer.secondsSinceEpoch when available (real Hammerspoon runtime),
  -- falling back to os.clock (e.g. a headless test harness) so this never
  -- raises on its own.
  local startTime = (hs and hs.timer and hs.timer.secondsSinceEpoch and hs.timer.secondsSinceEpoch()) or os.clock()
  log("DEBUG", "ipc " .. tostring(verb) .. " " .. tostring(id) .. " start")

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
    elseif verb == "services" then
      return self:servicesStatus()
    elseif verb == "feed" then
      return self:feed(id)
    elseif verb == "theme" then
      return themeSummary(self)
    elseif verb == "theme-json" then
      return self:themeJson()
    elseif verb == "theme-reload" then
      return self:themeReload()
    else
      return "unknown verb: " .. tostring(verb)
    end
  end)

  local endTime = (hs and hs.timer and hs.timer.secondsSinceEpoch and hs.timer.secondsSinceEpoch()) or os.clock()
  local elapsedMs = math.floor((endTime - startTime) * 1000 + 0.5)
  log("DEBUG", "ipc " .. tostring(verb) .. " " .. tostring(id) .. " done in " .. tostring(elapsedMs) .. " ms")

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
    elseif self:isEnabled(entry.id) then
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
      enabled = (not errored) and self:isEnabled(entry.id) or false,
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

--- Open a plugin's primary interactive kind (panel > overlay > menu; see
--- primaryInteractiveKind). Refuses unknown, errored, and disabled
--- plugins; a plugin with only non-interactive kinds (service,
--- bar-widget) reports "no interactive kind".
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

  if not self:isEnabled(id) then
    return "not enabled: " .. id
  end

  local kind = primaryInteractiveKind(entry.manifest)
  if kind == "panel" then
    return Panel.open(self, id)
  elseif kind == "overlay" then
    return Overlay.open(self, id)
  elseif kind == "menu" then
    return Menu.open(self, id)
  end
  return "no interactive kind: " .. id
end

--- Close a plugin's open window (whichever kind module owns it -- see
--- primaryInteractiveKind). Deliberately permissive for a known plugin --
--- not gated on enabled/errored state -- so an already-open window can
--- always be closed (obj:disable relies on this). An unknown id falls
--- through to Panel.close, which preserves the pre-Phase-3 behaviour of
--- returning "not open: <id>" rather than erroring.
function obj:close(id)
  if not id or id == "" then
    return "usage: close <id>"
  end

  local entry = self.plugins[id]
  local kind = entry and primaryInteractiveKind(entry.manifest) or nil

  if kind == "panel" then
    return Panel.close(self, id)
  elseif kind == "overlay" then
    return Overlay.close(self, id)
  elseif kind == "menu" then
    return Menu.close(self, id)
  end

  if not entry then
    return Panel.close(self, id)
  end
  return "no interactive kind: " .. id
end

--- Open if not currently open, otherwise close, for whichever kind module
--- is this plugin's primary interactive kind.
function obj:toggle(id)
  if not id or id == "" then
    return "usage: toggle <id>"
  end

  local entry = self.plugins[id]
  local kind = entry and primaryInteractiveKind(entry.manifest) or nil

  local isOpen
  if kind == "overlay" then
    isOpen = Overlay.isOpen(id)
  elseif kind == "menu" then
    isOpen = Menu.isOpen(id)
  else
    -- "panel", and the unknown-id fallback (matches pre-Phase-3 behaviour).
    isOpen = self.windows[id] ~= nil
  end

  if isOpen then
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
  Service.rescan(self)
  Feed.rescan(self)
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
  Service.rescan(self)
  Feed.rescan(self)
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

--- Re-run the manifest scan without a full Hammerspoon reload, and
--- reschedule background (service/bar-widget) timers to match.
function obj:rescan()
  local total, errored = loadPlugins(self)
  Service.rescan(self)
  Feed.rescan(self)
  return string.format("rescanned: plugins=%d errored=%d", total - errored, errored)
end

--- One line per running service: "<id>\t<interval>\t<lastRun>\t<code>\t<restarts>".
function obj:servicesStatus()
  local lines = Service.statusLines()
  if #lines == 0 then
    return "no services running"
  end
  return table.concat(lines, "\n")
end

--- The last feed JSON written for a bar-widget-kind plugin (see
--- lib/feed.lua), re-encoded as a single-line JSON string, or "no feed" if
--- id has never produced one (or id looks unsafe as a path component).
function obj:feed(id)
  if not id or id == "" then
    return "usage: feed <id>"
  end
  if id:find("/", 1, true) or id:find("..", 1, true) then
    return "invalid id: " .. id
  end

  local path = os.getenv("HOME") .. "/.config/gallery/feed/" .. id .. ".json"
  local readOk, decoded = pcall(hs.json.read, path)
  if not readOk or decoded == nil then
    return "no feed"
  end

  local encodeOk, encoded = pcall(hs.json.encode, decoded)
  if not encodeOk then
    return "no feed"
  end
  return encoded
end

--- The currently-loaded theme's tokens, as JSON.
function obj:themeJson()
  local t = self.theme
  if type(t) ~= "table" then
    t = Theme.defaultTokens()
  end
  return Theme.json(t)
end

--- Re-read the current theme from self.themesDir, replace self.theme (the
--- same table lib/bridge.lua reads as ctx.theme for every NEW panel/
--- overlay it builds), and live-reinject it into every currently OPEN
--- panel and overlay webview: the injected #gallery-theme <style> element's
--- text is replaced, window.gallery.theme is updated, and a "gallery:theme"
--- CustomEvent is dispatched on window so a page can react (see
--- plugins/gallery.hello/index.html's listener). Iterates ctx.windows
--- (panel webviews, keyed by id) and Overlay.overlays (each entry's
--- .webview) directly rather than lib/bridge.lua's own M.open registry --
--- lib/panel.lua and lib/overlay.lua each dofile lib/bridge.lua
--- independently (see that file's own selfDir() comments), so they end up
--- with two SEPARATE Bridge module instances and therefore two separate
--- M.open tables; self.windows and Overlay.overlays are each already a
--- single shared instance for their whole kind (init.lua dofiles
--- lib/panel.lua and lib/overlay.lua exactly once each), so reaching
--- through them here is simpler and more robust than plumbing either
--- module's private Bridge instance back out. Returns the new theme's
--- name (the count is logged, not returned, per the verify step's
--- expectation that this verb answers with just the name).
function obj:themeReload()
  local loadOk, newTheme = pcall(Theme.load, self.themesDir)
  if not loadOk or type(newTheme) ~= "table" then
    log("ERROR", "theme-reload: failed to load theme: " .. tostring(newTheme))
    return "error: failed to load theme"
  end

  self.theme = newTheme

  local cssOk, css = pcall(Theme.cssVariables, newTheme)
  if not cssOk or type(css) ~= "string" then
    css = ":root{}"
  end
  local themeJson = Theme.json(newTheme)
  local cssJsonOk, cssJsonEncoded = encodeJsonScalar(css)
  if not cssJsonOk then
    cssJsonEncoded = "\"\""
  end

  local script = table.concat({
    "(function(){try{",
    "var el=document.getElementById('gallery-theme');",
    "var css=", cssJsonEncoded, ";",
    "if(el){el.textContent=css;}",
    "var theme=", themeJson, ";",
    "if(window.gallery){window.gallery.theme=theme;}",
    "window.dispatchEvent(new CustomEvent('gallery:theme',{detail:theme}));",
    "}catch(e){}})();",
  })

  local count = 0
  for _, webview in pairs(self.windows) do
    local evalOk = pcall(function() webview:evaluateJavaScript(script) end)
    if evalOk then
      count = count + 1
    end
  end
  for _, entry in pairs(Overlay.overlays) do
    if entry and entry.webview then
      local evalOk = pcall(function() entry.webview:evaluateJavaScript(script) end)
      if evalOk then
        count = count + 1
      end
    end
  end

  log("INFO", "theme-reload: " .. tostring(newTheme.name) .. " reinjected into " .. count .. " webview(s)")
  return tostring(newTheme.name)
end

return obj
