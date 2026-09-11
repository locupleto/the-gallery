--- lib/window_util.lua -- shared window helpers for kinds that manage
--- their own hs.webview windows outside of lib/panel.lua (currently
--- lib/overlay.lua). Deliberately a separate file rather than anything
--- shared with (or copy-pasted from) panel.lua, which this worker does
--- not own: the logic below is the more general form (an explicit display
--- selector, a named-level list to try in order) rather than a literal
--- copy of panel.lua's cursor-with-fallback-to-main / floating-only
--- behaviour, so it can be added without touching panel.lua at all.
---
--- Returns a table with:
---   .screenFrame(display) -> hs.geometry rect or nil
---   .pickWindowLevel(names) -> number or nil
---   .newMinimalBridge(logFn, onClose) -> hs.webview.usercontent or nil
---       Fallback-only JS bridge (window.gallery = {close, log}) for a
---       kind that wants panel.lua's basic bridge behaviour but cannot
---       reach lib/bridge.lua (missing, or failed to load). Kinds that
---       CAN reach lib/bridge.lua should dofile it directly instead (see
---       lib/overlay.lua), since it offers gallery.exec/theme/data too.

local M = {}

--- Resolve a screen frame ({x,y,w,h}) for the given display selector:
---   "cursor" (default, and the fallback for any unrecognised value) --
---     the screen under the mouse pointer, falling back to the main
---     screen if that cannot be determined.
---   "main" -- hs.screen.mainScreen() directly.
--- Never raises; returns nil only if no screen frame could be determined
--- by either path.
function M.screenFrame(display)
  if display ~= "main" then
    local screenOk, screen = pcall(function() return hs.mouse.getCurrentScreen() end)
    if screenOk and screen then
      local frameOk, frame = pcall(function() return screen:frame() end)
      if frameOk then
        return frame
      end
    end
  end

  local mainOk, mainScreen = pcall(function() return hs.screen.mainScreen() end)
  if mainOk and mainScreen then
    local frameOk, frame = pcall(function() return mainScreen:frame() end)
    if frameOk then
      return frame
    end
  end

  return nil
end

--- Try each name in `names` (e.g. {"overlay", "floating"}) in order against
--- whichever of hs.canvas.windowLevels / hs.drawing.windowLevels currently
--- exposes it, returning the first numeric level found. Never raises;
--- returns nil (system default level) if none of the names resolve.
function M.pickWindowLevel(names)
  for _, name in ipairs(names or {}) do
    local ok, level = pcall(function()
      if hs.canvas and hs.canvas.windowLevels and hs.canvas.windowLevels[name] then
        return hs.canvas.windowLevels[name]
      end
      if hs.drawing and hs.drawing.windowLevels and hs.drawing.windowLevels[name] then
        return hs.drawing.windowLevels[name]
      end
      return nil
    end)
    if ok and level then
      return level
    end
  end
  return nil
end

--- Build a minimal usercontent controller providing window.gallery =
--- {close, log} to a webview -- the fallback bridge for a kind that wants
--- panel.lua's basic close/log behaviour but cannot reach lib/bridge.lua.
--- onClose is invoked with no arguments when the page calls
--- window.gallery.close(); logFn(level, msg) is invoked for
--- window.gallery.log(msg). Never raises; returns nil on any failure.
function M.newMinimalBridge(logFn, onClose)
  local uccOk, controller = pcall(function() return hs.webview.usercontent.new("gallery") end)
  if not uccOk or not controller then
    return nil
  end

  pcall(function()
    controller:setCallback(function(message)
      local body = message and message.body
      if type(body) ~= "table" then
        return
      end
      if body.action == "close" then
        pcall(onClose)
      elseif body.action == "log" and logFn then
        pcall(logFn, "INFO", tostring(body.message))
      end
    end)
  end)

  pcall(function()
    controller:injectScript({
      source = [[
window.gallery = {
  close: function () { webkit.messageHandlers.gallery.postMessage({action: "close"}); },
  log: function (m) { webkit.messageHandlers.gallery.postMessage({action: "log", message: String(m)}); }
};
]],
      injectionTime = "documentStart",
    })
  end)

  return controller
end

return M
