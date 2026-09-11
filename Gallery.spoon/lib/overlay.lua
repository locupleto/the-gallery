--- lib/overlay.lua -- kind "overlay": a borderless hs.webview covering the
--- whole frame of one display, sitting above panels, dismissed by a
--- keypress rather than by its own close button.
---
--- ctx is expected to expose the same surface lib/panel.lua relies on
--- (ctx.plugins, ctx.log, ctx.close, ctx.version, ctx.theme) since this
--- module hands ctx straight to lib/bridge.lua's Bridge.new, exactly as
--- lib/panel.lua does -- see the contract comment atop lib/bridge.lua.
---
--- Keeps its own module-level state (M.overlays: map id -> {webview,
--- eventtap, bridge}) rather than storing it on ctx, mirroring
--- lib/menu.lua, so tests (tests/kinds_test.lua) can inspect it directly
--- through spoon.Gallery.Overlay.
---
--- Returns a table with .open(ctx, id), .close(ctx, id), .toggle(ctx, id),
--- .isOpen(id).

local M = {}

M.overlays = {}

--- This file's own directory, so lib/bridge.lua can be dofile'd as a
--- sibling regardless of how overlay.lua itself was loaded -- the same
--- technique lib/panel.lua and tests/manifest_test.lua use (dofile sets
--- the chunk name to "@<path>", so debug.getinfo(1,"S").source is a
--- reliable absolute path here). Deliberately NOT shared code with
--- panel.lua (this worker does not own panel.lua); a few duplicated lines
--- is the established pattern in this repo for self-contained modules.
local function selfDir()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    return source:sub(2):match("(.*/)") or "./"
  end
  return "./"
end

local SELF_DIR = selfDir()
local WindowUtil = dofile(SELF_DIR .. "window_util.lua")

-- lib/bridge.lua is reused exactly as lib/panel.lua reuses it (same
-- Bridge.new(ctx, id, dir) contract -- see the comment atop that file),
-- giving overlay pages the full window.gallery (close/log/exec/theme/
-- data), per Plugin-Contract.md's "Injected... into every panel and
-- overlay webview". Loaded defensively: if this ever fails (bridge.lua
-- missing or broken), M.open falls back to WindowUtil.newMinimalBridge's
-- close/log-only bridge instead of failing the whole overlay.
local BridgeOk, Bridge = pcall(dofile, SELF_DIR .. "bridge.lua")
if not BridgeOk then
  Bridge = nil
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

local DEFAULT_DISMISS = "any-key"
local ESCAPE_KEYCODE = 53 -- kVK_Escape

--- True if id's overlay window is currently open. Never raises.
function M.isOpen(id)
  return M.overlays[id] ~= nil
end

--- Open an overlay-kind plugin's full-display window.
function M.open(ctx, id)
  if not id or id == "" then
    return "usage: open <id>"
  end

  local entry = ctx.plugins[id]
  if not entry then
    return "unknown plugin: " .. id
  end

  local manifest = entry.manifest
  if not tableContains(manifest.kinds, "overlay") then
    return "plugin does not support overlay: " .. id
  end

  if M.overlays[id] then
    return "already open: " .. id
  end

  local entryPoint = manifest.entryPoints and manifest.entryPoints.overlay
  if not entryPoint then
    return "no overlay entry point declared: " .. id
  end

  local overlayCfg = (manifest.gallery and manifest.gallery.overlay) or {}
  local frame = WindowUtil.screenFrame(overlayCfg.display)
  local rect = frame or { x = 0, y = 0, w = 800, h = 600 }

  local path = entry.dir .. "/" .. entryPoint

  local closed = false
  local function doClose()
    if not closed then
      closed = true
      M.close(ctx, id)
    end
  end

  local bridgeInstance = nil
  local ucc = nil
  if Bridge then
    local bridgeOk, result = pcall(Bridge.new, ctx, id, entry.dir)
    if bridgeOk and result then
      bridgeInstance = result
      ucc = result.ucc
    else
      ctx.log("WARN", "failed to build bridge for overlay " .. id .. ": " .. tostring(result))
    end
  end
  if not ucc then
    ucc = WindowUtil.newMinimalBridge(ctx.log, doClose)
    if ucc then
      ctx.log("INFO", "overlay " .. id .. " using minimal fallback bridge (close/log only)")
    end
  end

  local webviewOk, webview
  if ucc then
    webviewOk, webview = pcall(hs.webview.new, rect, {}, ucc)
  else
    webviewOk, webview = pcall(hs.webview.new, rect)
  end
  if not webviewOk or not webview then
    ctx.log("ERROR", "failed to create overlay webview for " .. id)
    if bridgeInstance then
      pcall(bridgeInstance.dispose)
    end
    return "error: could not create overlay for " .. id
  end

  if bridgeInstance then
    pcall(bridgeInstance.attach, webview)
  end

  pcall(function() webview:windowStyle({ "borderless" }) end)

  -- Above panels: try the "overlay" named level first, falling back to
  -- "floating" (the same level panel.lua uses) if this Hammerspoon build
  -- doesn't expose "overlay" on either hs.canvas or hs.drawing.
  local level = WindowUtil.pickWindowLevel({ "overlay", "floating" })
  if level then
    pcall(function() webview:level(level) end)
  end

  pcall(function() webview:transparent(true) end)
  pcall(function() webview:allowTextEntry(true) end)
  pcall(function() webview:deleteOnClose(true) end)
  pcall(function() webview:bringToFront(true) end)

  pcall(function()
    webview:windowCallback(function(action)
      if action == "closing" then
        if bridgeInstance then
          pcall(bridgeInstance.dispose)
        end
        M.overlays[id] = nil
      end
    end)
  end)

  pcall(function() webview:url("file://" .. path) end)
  pcall(function() webview:show() end)

  -- Dismiss-on-keypress: manifest.gallery.overlay.dismiss (default
  -- "any-key"). "escape" restricts the eventtap to just the Escape key;
  -- anything else (including "any-key" or an unrecognised value) fires on
  -- any keyDown. The eventtap is stopped in M.close so it never outlives
  -- this overlay.
  local dismissMode = overlayCfg.dismiss
  if dismissMode ~= "escape" then
    dismissMode = DEFAULT_DISMISS
  end

  local tap
  local tapOk, tapErr = pcall(function()
    tap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
      if dismissMode == "escape" then
        if event:getKeyCode() == ESCAPE_KEYCODE then
          doClose()
          return true
        end
        return false
      end
      doClose()
      return true
    end)
    tap:start()
  end)
  if not tapOk then
    ctx.log("WARN", "failed to install dismiss eventtap for overlay " .. id .. ": " .. tostring(tapErr))
    tap = nil
  end

  M.overlays[id] = { webview = webview, eventtap = tap, bridge = bridgeInstance }

  -- Focus: manifest.gallery.overlay.focus. Unlike panels, an overlay
  -- defaults to NOT taking focus (it exists to be looked at / dismissed
  -- by a keypress caught at the eventtap level, not typed into); only
  -- "activate" opts in to focusing it like a panel would.
  local focusMode = overlayCfg.focus
  if focusMode == "activate" then
    pcall(function()
      local app = hs.application.get("Hammerspoon")
      if app then app:activate(true) end
    end)
    pcall(function()
      local hsWindow = webview:hswindow()
      if hsWindow then hsWindow:focus() end
    end)
  end

  ctx.log("INFO", string.format("opened overlay %s dismiss=%s focus=%s", id, dismissMode, tostring(focusMode)))
  return "opened " .. id
end

--- Close and forget id's overlay window, stopping its dismiss eventtap and
--- disposing its bridge (if any) first. Deliberately permissive (no
--- enabled/kind checks), mirroring lib/panel.lua's M.close.
function M.close(ctx, id)
  if not id or id == "" then
    return "usage: close <id>"
  end

  local entry = M.overlays[id]
  if not entry then
    return "not open: " .. id
  end

  if entry.eventtap then
    pcall(function() entry.eventtap:stop() end)
  end
  if entry.bridge then
    pcall(entry.bridge.dispose)
  end
  if entry.webview then
    pcall(function() entry.webview:delete() end)
  end
  M.overlays[id] = nil

  ctx.log("INFO", "closed overlay " .. id)
  return "closed " .. id
end

function M.toggle(ctx, id)
  if not id or id == "" then
    return "usage: toggle <id>"
  end
  if M.overlays[id] then
    return M.close(ctx, id)
  end
  return M.open(ctx, id)
end

return M
