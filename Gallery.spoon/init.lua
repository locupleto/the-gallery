--- === Gallery ===
---
--- Hosts manifest-driven desktop plugins (panels, overlays, menus, services)
--- on macOS, modelled on Omarchy 4's plugin system. Each plugin is a
--- directory under obj.pluginDir containing a manifest.json; Gallery scans
--- that directory at start, validates each manifest, and exposes an IPC
--- surface (see obj:ipc) that the `gallery` CLI drives.
---
--- This is a first draft written before Hammerspoon was available locally
--- for testing, so every call into the hs.* API is defensive (pcall-wrapped
--- where an API name or behavior could not be confirmed against a running
--- Hammerspoon).

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "Gallery"
obj.version = "0.0.1"
obj.author = "Urban Ottosson"
obj.license = "MIT"
obj.homepage = "https://github.com/locupleto/the-gallery"

obj.pluginDir = os.getenv("HOME") .. "/.config/gallery/plugins"
obj.logPath = os.getenv("HOME") .. "/Library/Logs/gallery.log"
-- Written at the end of start(); the installer waits for it instead of probing
-- the IPC port, because a probe killed mid-request can wedge or crash Hammerspoon.
obj.readyPath = os.getenv("HOME") .. "/.config/gallery/state/ready"
obj.plugins = {}
obj.windows = {}
-- Keyed by plugin id: the hs.window that was frontmost immediately before
-- that plugin's panel was shown, captured so focus can be restored to it
-- on close (see manifest.gallery.panel.restoreFocus).
obj.previousFocusWindow = {}

--- Append a timestamped line to obj.logPath and print to the Hammerspoon
--- console. Never raises: a failure to open the log file is silently
--- ignored so logging can never take Gallery down.
local function log(level, msg)
  local line = string.format("%s %s %s", os.date("!%Y-%m-%dT%H:%M:%SZ"), level, msg)

  local ok = pcall(function()
    local f = io.open(obj.logPath, "a")
    if f then
      f:write(line, "\n")
      f:close()
    end
  end)
  if not ok then
    -- Nothing more we can do if the log file itself is unwritable.
  end

  if hs and hs.printf then
    pcall(hs.printf, "[Gallery] %s: %s", level, msg)
  end
end

--- True if value is present in the array-like table t.
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

--- Validate the minimal manifest fields Gallery relies on. Returns
--- true, or false plus a reason string.
local function validateManifest(m)
  if type(m) ~= "table" then
    return false, "manifest is not a table"
  end
  if m.schemaVersion ~= 1 then
    return false, "schemaVersion is not 1"
  end
  if type(m.id) ~= "string" or m.id == "" then
    return false, "missing or invalid id"
  end
  if type(m.name) ~= "string" or m.name == "" then
    return false, "missing or invalid name"
  end
  if type(m.version) ~= "string" or m.version == "" then
    return false, "missing or invalid version"
  end
  if type(m.kinds) ~= "table" then
    return false, "kinds is not a table"
  end
  if type(m.entryPoints) ~= "table" then
    return false, "entryPoints is not a table"
  end
  return true
end

--- Pick a floating window level from whichever Hammerspoon module currently
--- exposes windowLevels. This has moved between hs.drawing and hs.canvas
--- across Hammerspoon versions; try both and fall back to nil (the
--- system default level) rather than raising.
local function pickWindowLevel()
  local ok, level = pcall(function()
    if hs.drawing and hs.drawing.windowLevels and hs.drawing.windowLevels.floating then
      return hs.drawing.windowLevels.floating
    end
    if hs.canvas and hs.canvas.windowLevels and hs.canvas.windowLevels.floating then
      return hs.canvas.windowLevels.floating
    end
    return nil
  end)
  if ok then
    return level
  end
  return nil
end

--- Default window style mask names (see manifest.gallery.panel.style) and
--- default focus mode (see manifest.gallery.panel.focus). Kept as named
--- constants so the gate test harness's `variant` subcommand and this file
--- agree on what "default" means.
local DEFAULT_PANEL_STYLE = { "borderless", "utility" }
local DEFAULT_PANEL_FOCUS = "activate"

--- Scan obj.pluginDir for plugin subdirectories containing manifest.json,
--- decode and validate each, and populate obj.plugins keyed by id. A
--- missing plugin directory, an unreadable manifest, or a manifest that
--- fails validation is logged and skipped -- this never raises.
-- Extensions are loaded eagerly here so the first panel open does not pay
-- their load cost (measured at about 2.5 s cold) and so their console
-- banners do not leak into CLI output.
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
  }) do
    pcall(require, name)
  end
end

function obj:start()
  preloadExtensions()
  self.plugins = {}
  self.windows = self.windows or {}
  self.previousFocusWindow = self.previousFocusWindow or {}

  local dirOk, dirAttr = pcall(hs.fs.attributes, self.pluginDir)
  if not dirOk or not dirAttr or dirAttr.mode ~= "directory" then
    log("WARN", "plugin directory not found: " .. tostring(self.pluginDir))
    return self
  end

  local scanOk, scanErr = pcall(function()
    for entry in hs.fs.dir(self.pluginDir) do
      if entry ~= "." and entry ~= ".." then
        local pluginPath = self.pluginDir .. "/" .. entry
        local attr = hs.fs.attributes(pluginPath)
        if attr and attr.mode == "directory" then
          local manifestPath = pluginPath .. "/manifest.json"
          if hs.fs.attributes(manifestPath) then
            local readOk, manifest = pcall(hs.json.read, manifestPath)
            if readOk and manifest then
              local valid, reason = validateManifest(manifest)
              if valid then
                self.plugins[manifest.id] = { manifest = manifest, dir = pluginPath }
                log("INFO", "loaded plugin " .. manifest.id .. " from " .. pluginPath)
              else
                log("WARN", "invalid manifest at " .. manifestPath .. ": " .. tostring(reason))
              end
            else
              log("WARN", "failed to read/decode manifest at " .. manifestPath)
            end
          end
        end
      end
    end
  end)

  if not scanOk then
    log("ERROR", "error scanning plugin directory: " .. tostring(scanErr))
  end

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
    elseif verb == "open" then
      return self:open(id)
    elseif verb == "close" then
      return self:close(id)
    elseif verb == "toggle" then
      return self:toggle(id)
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
  for _ in pairs(self.plugins) do
    pluginCount = pluginCount + 1
  end

  local windowCount = 0
  for _ in pairs(self.windows) do
    windowCount = windowCount + 1
  end

  return string.format(
    "Gallery %s; plugins=%d; pluginDir=%s; windows=%d",
    obj.version,
    pluginCount,
    self.pluginDir,
    windowCount
  )
end

--- One line per loaded plugin: "<id>\t<version>\t<kinds joined by comma>".
function obj:list()
  local lines = {}
  for id, entry in pairs(self.plugins) do
    local kinds = table.concat(entry.manifest.kinds or {}, ",")
    table.insert(lines, string.format("%s\t%s\t%s", id, entry.manifest.version, kinds))
  end
  table.sort(lines)
  return table.concat(lines, "\n")
end

--- Open a panel-kind plugin's window. Sizes and positions the webview from
--- the manifest's gallery.panel config, centred on the screen under the
--- mouse, and remembers it in obj.windows keyed by id.
function obj:open(id)
  if not id or id == "" then
    return "usage: open <id>"
  end

  local entry = self.plugins[id]
  if not entry then
    return "unknown plugin: " .. id
  end

  if self.windows[id] then
    return "already open: " .. id
  end

  local manifest = entry.manifest
  if not tableContains(manifest.kinds, "panel") then
    return "plugin does not support panel: " .. id
  end

  local entryPoint = manifest.entryPoints and manifest.entryPoints.panel
  if not entryPoint then
    return "no panel entry point declared: " .. id
  end

  local panelCfg = (manifest.gallery and manifest.gallery.panel) or {}
  local width = panelCfg.width or 640
  local height = panelCfg.height or 400

  local screenFrame = nil
  local screenOk, screen = pcall(function() return hs.mouse.getCurrentScreen() end)
  if screenOk and screen then
    local frameOk, frame = pcall(function() return screen:frame() end)
    if frameOk then
      screenFrame = frame
    end
  end
  if not screenFrame then
    local mainOk, mainScreen = pcall(function() return hs.screen.mainScreen() end)
    if mainOk and mainScreen then
      local frameOk, frame = pcall(function() return mainScreen:frame() end)
      if frameOk then
        screenFrame = frame
      end
    end
  end

  local rect
  if screenFrame then
    rect = {
      x = screenFrame.x + (screenFrame.w - width) / 2,
      y = screenFrame.y + (screenFrame.h - height) / 2,
      w = width,
      h = height,
    }
  else
    rect = { x = 0, y = 0, w = width, h = height }
  end

  local path = entry.dir .. "/" .. entryPoint

  -- JavaScript-to-Lua bridge: a usercontent controller named "gallery" is
  -- wired into the webview so page JS can call window.gallery.close() and
  -- window.gallery.log(msg). Built defensively -- if the controller cannot
  -- be created (or its callback/script cannot be attached) the webview is
  -- still created without it rather than failing the whole open.
  local ucc = nil
  do
    local uccOk, controller = pcall(function() return hs.webview.usercontent.new("gallery") end)
    if uccOk and controller then
      ucc = controller

      local callbackOk, callbackErr = pcall(function()
        ucc:setCallback(function(message)
          local body = message and message.body
          if type(body) ~= "table" then
            return
          end
          if body.action == "close" then
            self:close(id)
          elseif body.action == "log" then
            log("INFO", "[" .. id .. "] " .. tostring(body.message))
          end
        end)
      end)
      if not callbackOk then
        log("WARN", "failed to set usercontent callback for " .. id .. ": " .. tostring(callbackErr))
      end

      local injectOk, injectErr = pcall(function()
        ucc:injectScript({
          source = [[
window.gallery = {
  close: function () { webkit.messageHandlers.gallery.postMessage({action: "close"}); },
  log: function (m) { webkit.messageHandlers.gallery.postMessage({action: "log", message: String(m)}); }
};
]],
          injectionTime = "documentStart",
        })
      end)
      if not injectOk then
        log("WARN", "failed to inject gallery bridge script for " .. id .. ": " .. tostring(injectErr))
      end
    else
      log("WARN", "failed to create usercontent controller for " .. id .. "; JS bridge disabled")
    end
  end

  local webviewOk, webview
  if ucc then
    webviewOk, webview = pcall(hs.webview.new, rect, {}, ucc)
  else
    webviewOk, webview = pcall(hs.webview.new, rect)
  end
  if not webviewOk or not webview then
    log("ERROR", "failed to create webview for " .. id)
    return "error: could not create window for " .. id
  end

  -- Window style: manifest.gallery.panel.style is an array of
  -- hs.webview.windowMasks key names (default {"borderless","utility"}).
  -- hs.webview:windowStyle accepts that array directly and combines the
  -- named masks with bitwise-or internally.
  local styleList = panelCfg.style
  if type(styleList) ~= "table" or #styleList == 0 then
    styleList = DEFAULT_PANEL_STYLE
  end
  local styleOk, styleErr = pcall(function() webview:windowStyle(styleList) end)
  if not styleOk then
    log("WARN", "failed to apply window style for " .. id .. ": " .. tostring(styleErr))
  end
  local styleDesc = table.concat(styleList, "+")

  local level = pickWindowLevel()
  if level then
    pcall(function() webview:level(level) end)
  end

  pcall(function() webview:allowTextEntry(true) end)

  if panelCfg.transparent then
    pcall(function() webview:transparent(true) end)
  end

  pcall(function() webview:deleteOnClose(true) end)
  pcall(function() webview:bringToFront(true) end)

  pcall(function()
    webview:windowCallback(function(action)
      if action == "closing" then
        self.windows[id] = nil
      end
    end)
  end)

  pcall(function() webview:url("file://" .. path) end)

  -- Capture whatever was frontmost right before this panel is shown, so
  -- obj:close can restore focus to it afterwards (manifest.gallery.panel.restoreFocus).
  local prevFrontOk, prevFront = pcall(function() return hs.window.frontmostWindow() end)
  self.previousFocusWindow[id] = (prevFrontOk and prevFront) or nil

  pcall(function() webview:show() end)

  self.windows[id] = webview

  -- Focus handling: manifest.gallery.panel.focus (default "activate").
  --   "activate" -- activate the Hammerspoon app, then focus this window.
  --   "window"   -- focus this window only, do not activate the app.
  --   "none"     -- do nothing; whatever has focus keeps it.
  local focusMode = panelCfg.focus
  if focusMode ~= "activate" and focusMode ~= "window" and focusMode ~= "none" then
    if focusMode ~= nil then
      log("WARN", "unknown focus mode '" .. tostring(focusMode) .. "' for " .. id .. "; defaulting to " .. DEFAULT_PANEL_FOCUS)
    end
    focusMode = DEFAULT_PANEL_FOCUS
  end

  if focusMode == "activate" then
    pcall(function()
      local app = hs.application.get("Hammerspoon")
      if app then
        app:activate(true)
      end
    end)
    pcall(function()
      local hsWindow = webview:hswindow()
      if hsWindow then
        hsWindow:focus()
      end
    end)
  elseif focusMode == "window" then
    pcall(function()
      local hsWindow = webview:hswindow()
      if hsWindow then
        hsWindow:focus()
      end
    end)
  end
  -- focusMode == "none": nothing to do.

  log("INFO", string.format("opened %s style=%s focus=%s", id, styleDesc, focusMode))
  return "opened " .. id
end

--- Close and forget a plugin's open window. If
--- manifest.gallery.panel.restoreFocus is not false, also attempts to
--- refocus whatever window was frontmost before this plugin's panel was
--- shown (captured in obj:open).
function obj:close(id)
  if not id or id == "" then
    return "usage: close <id>"
  end

  local win = self.windows[id]
  if not win then
    return "not open: " .. id
  end

  pcall(function() win:delete() end)
  self.windows[id] = nil

  local prevWindow = self.previousFocusWindow[id]
  self.previousFocusWindow[id] = nil

  local entry = self.plugins[id]
  local panelCfg = (entry and entry.manifest and entry.manifest.gallery and entry.manifest.gallery.panel) or {}
  if panelCfg.restoreFocus ~= false then
    if prevWindow then
      local restoreOk, restoreErr = pcall(function() prevWindow:focus() end)
      if restoreOk then
        log("INFO", "restored previous focus after closing " .. id)
      else
        log("WARN", "failed to restore previous focus after closing " .. id .. ": " .. tostring(restoreErr))
      end
    else
      log("INFO", "no previous window captured to restore focus to after closing " .. id)
    end
  end

  log("INFO", "closed " .. id)
  return "closed " .. id
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

return obj
