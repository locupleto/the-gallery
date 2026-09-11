--- lib/panel.lua -- webview open/close mechanics for panel-kind plugins,
--- including the usercontent JS bridge. Ported unchanged in behavior from
--- the original init.lua; only the enclosing `self` became an explicit
--- `ctx` parameter (the Spoon object) so this module carries no globals.
---
--- ctx is expected to expose:
---   ctx.plugins             -- map: id -> {manifest, dir, errors, warnings}
---   ctx.windows              -- map: id -> hs.webview, mutated in place
---   ctx.previousFocusWindow  -- map: id -> hs.window, mutated in place
---   ctx.log(level, msg)      -- logging function
---
--- Returns a table with .open(ctx, id), .close(ctx, id), .toggle(ctx, id).
--- Callers (init.lua) are expected to have already checked that id is
--- known, enabled, and error-free before calling .open(); .close() and
--- .toggle()'s close path stay permissive so a plugin that was disabled
--- or errored out after being opened can still be closed cleanly.

local M = {}

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

-- Default window style mask names (see manifest.gallery.panel.style) and
-- default focus mode (see manifest.gallery.panel.focus). Kept as named
-- constants so the gate test harness's `variant` subcommand and this file
-- agree on what "default" means.
local DEFAULT_PANEL_STYLE = { "borderless", "utility" }
local DEFAULT_PANEL_FOCUS = "activate"

--- Open a panel-kind plugin's window. Sizes and positions the webview from
--- the manifest's gallery.panel config, centred on the screen under the
--- mouse, and remembers it in ctx.windows keyed by id.
function M.open(ctx, id)
  if not id or id == "" then
    return "usage: open <id>"
  end

  local entry = ctx.plugins[id]
  if not entry then
    return "unknown plugin: " .. id
  end

  if ctx.windows[id] then
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
            M.close(ctx, id)
          elseif body.action == "log" then
            ctx.log("INFO", "[" .. id .. "] " .. tostring(body.message))
          end
        end)
      end)
      if not callbackOk then
        ctx.log("WARN", "failed to set usercontent callback for " .. id .. ": " .. tostring(callbackErr))
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
        ctx.log("WARN", "failed to inject gallery bridge script for " .. id .. ": " .. tostring(injectErr))
      end
    else
      ctx.log("WARN", "failed to create usercontent controller for " .. id .. "; JS bridge disabled")
    end
  end

  local webviewOk, webview
  if ucc then
    webviewOk, webview = pcall(hs.webview.new, rect, {}, ucc)
  else
    webviewOk, webview = pcall(hs.webview.new, rect)
  end
  if not webviewOk or not webview then
    ctx.log("ERROR", "failed to create webview for " .. id)
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
    ctx.log("WARN", "failed to apply window style for " .. id .. ": " .. tostring(styleErr))
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
        ctx.windows[id] = nil
      end
    end)
  end)

  pcall(function() webview:url("file://" .. path) end)

  -- Capture whatever was frontmost right before this panel is shown, so
  -- M.close can restore focus to it afterwards (manifest.gallery.panel.restoreFocus).
  local prevFrontOk, prevFront = pcall(function() return hs.window.frontmostWindow() end)
  ctx.previousFocusWindow[id] = (prevFrontOk and prevFront) or nil

  pcall(function() webview:show() end)

  ctx.windows[id] = webview

  -- Focus handling: manifest.gallery.panel.focus (default "activate").
  --   "activate" -- activate the Hammerspoon app, then focus this window.
  --   "window"   -- focus this window only, do not activate the app.
  --   "none"     -- do nothing; whatever has focus keeps it.
  local focusMode = panelCfg.focus
  if focusMode ~= "activate" and focusMode ~= "window" and focusMode ~= "none" then
    if focusMode ~= nil then
      ctx.log("WARN", "unknown focus mode '" .. tostring(focusMode) .. "' for " .. id .. "; defaulting to " .. DEFAULT_PANEL_FOCUS)
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

  ctx.log("INFO", string.format("opened %s style=%s focus=%s", id, styleDesc, focusMode))
  return "opened " .. id
end

--- Close and forget a plugin's open window. If
--- manifest.gallery.panel.restoreFocus is not false, also attempts to
--- refocus whatever window was frontmost before this plugin's panel was
--- shown (captured in M.open). Deliberately permissive: does not check
--- enabled/errored state, so a plugin that was disabled while its panel
--- was open can still be closed cleanly (see obj:disable in init.lua).
function M.close(ctx, id)
  if not id or id == "" then
    return "usage: close <id>"
  end

  local win = ctx.windows[id]
  if not win then
    return "not open: " .. id
  end

  pcall(function() win:delete() end)
  ctx.windows[id] = nil

  local prevWindow = ctx.previousFocusWindow[id]
  ctx.previousFocusWindow[id] = nil

  local entry = ctx.plugins[id]
  local panelCfg = (entry and entry.manifest and entry.manifest.gallery and entry.manifest.gallery.panel) or {}
  if panelCfg.restoreFocus ~= false then
    if prevWindow then
      local restoreOk, restoreErr = pcall(function() prevWindow:focus() end)
      if restoreOk then
        ctx.log("INFO", "restored previous focus after closing " .. id)
      else
        ctx.log("WARN", "failed to restore previous focus after closing " .. id .. ": " .. tostring(restoreErr))
      end
    else
      ctx.log("INFO", "no previous window captured to restore focus to after closing " .. id)
    end
  end

  ctx.log("INFO", "closed " .. id)
  return "closed " .. id
end

--- Open if not currently open, otherwise close. Enabled/errored refusal
--- happens inside M.open when there is no window yet; closing an open
--- window is always permitted (see M.close).
function M.toggle(ctx, id)
  if not id or id == "" then
    return "usage: toggle <id>"
  end

  if ctx.windows[id] then
    return M.close(ctx, id)
  end
  return M.open(ctx, id)
end

return M
