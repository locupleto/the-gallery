--- lib/outline.lua -- the focus outline on Macs without JankyBorders.
---
--- JankyBorders (bin/gallery-borders) draws the outline on macOS 14 and
--- later. It cannot run on older systems, so there this module draws the
--- same frame itself: one hs.canvas, a rounded ring just outside the focused
--- window, in the colour and width tools/render-theme.py wrote to
--- state/theme.json (border_active, border_width). A JankyBorders gradient
--- expression is drawn as a gradient along the same diagonal.
---
--- It runs only when no borders binary is installed and the Gallery is not
--- switched off (state/paused). bin/gallery-borders calls M.apply through
--- obj:outline("apply") wherever it would have reconfigured JankyBorders,
--- and `gallery off` calls obj:outline("stop").
---
--- The canvas follows window-filter events, plus a short burst of polling
--- after each one so a yabai re-layout or a mouse drag is tracked to the
--- end. It trails a moving window by a frame or two, which JankyBorders,
--- drawing inside the window server, does not.
---
--- Returns a table with:
---   .start(ctx)   start following focus if the conditions above hold
---   .stop()       remove the outline and stop following
---   .apply(ctx)   re-read the style and start, restyle or stop as needed
---   .status()     one line: running or not, and why

local M = {}

-- Testing aid: true draws the outline even where JankyBorders is installed.
M.force = false

local HOME = os.getenv("HOME")
local BORDERS_BINS = { "/opt/homebrew/bin/borders", "/usr/local/bin/borders" }
local PAUSED_FILE = HOME .. "/.config/gallery/state/paused"
local DEFAULT_COLOR = "#7aa2f7"
local DEFAULT_WIDTH = 5
-- macOS window corner radius (Monterey to Sonoma draw about 10 px).
local WINDOW_RADIUS = 10
-- Polling after an event: interval and how long it lasts.
local FOLLOW_INTERVAL = 1 / 30
local FOLLOW_FOR = 0.8

local canvas = nil
local filter = nil
local spacesWatcher = nil
local followTimer = nil
local followUntil = 0
local sanityTimer = nil
local lastKey = nil
local style = { colors = { DEFAULT_COLOR }, angle = 0, width = DEFAULT_WIDTH }
local reason = "not started"

local function exists(path)
  return hs.fs.attributes(path) ~= nil
end

--- True if JankyBorders is installed (it then owns the outline).
function M.bordersInstalled()
  for _, path in ipairs(BORDERS_BINS) do
    if exists(path) then
      return true
    end
  end
  return false
end

--- "0xAARRGGBB" or "#rrggbb" -> hs.drawing colour table, or nil.
local function parseColor(s)
  if type(s) ~= "string" then
    return nil
  end
  local a, r, g, b = s:match("^0[xX](%x%x)(%x%x)(%x%x)(%x%x)$")
  if not a then
    r, g, b = s:match("^#(%x%x)(%x%x)(%x%x)$")
    a = "ff"
  end
  if not r then
    return nil
  end
  return {
    alpha = tonumber(a, 16) / 255,
    red = tonumber(r, 16) / 255,
    green = tonumber(g, 16) / 255,
    blue = tonumber(b, 16) / 255,
  }
end

--- Style from the theme tokens: border_active is a JankyBorders colour
--- (0xAARRGGBB) or gradient(top_left=A,bottom_right=B) /
--- gradient(top_right=A,bottom_left=B); falls back to accent.
local function styleFrom(theme)
  theme = theme or {}
  local s = { colors = {}, angle = 0, width = DEFAULT_WIDTH }
  local active = theme.border_active
  if type(active) == "string" and active:match("^gradient%(") then
    for c in active:gmatch("0[xX]%x%x%x%x%x%x%x%x") do
      table.insert(s.colors, parseColor(c))
    end
    -- hs.canvas measures gradient angles from left-to-right with y
    -- pointing down: 45 runs top left to bottom right, 135 top right to
    -- bottom left.
    s.angle = active:match("^gradient%(top_right") and 135 or 45
  else
    table.insert(s.colors, parseColor(active))
  end
  if #s.colors == 0 then
    s.colors = { parseColor(theme.accent) or parseColor(DEFAULT_COLOR) }
  end
  local w = tonumber(theme.border_width)
  if w and w >= 1 and w <= 12 then
    s.width = w
  end
  return s
end

--- The window to outline, or nil: a visible standard window that is not
--- in native full screen.
local function target()
  local win = hs.window.focusedWindow()
  if not win then
    return nil
  end
  local ok, good = pcall(function()
    return win:isStandard() and win:isVisible() and not win:isFullScreen()
  end)
  if ok and good then
    return win
  end
  return nil
end

local function hide()
  if canvas then
    canvas:hide()
  end
  lastKey = nil
end

local function build()
  if canvas then
    canvas:delete()
  end
  canvas = hs.canvas.new({ x = 0, y = 0, w = 10, h = 10 })
  canvas:level(hs.canvas.windowLevels.floating)
  canvas:behavior({ "canJoinAllSpaces", "stationary", "ignoresCycle" })
  canvas:clickActivating(false)
  lastKey = nil
end

local function ringElements(w, h)
  local width = style.width
  local outer = {
    type = "rectangle",
    action = "fill",
    frame = { x = 0, y = 0, w = w, h = h },
    roundedRectRadii = { xRadius = WINDOW_RADIUS + width, yRadius = WINDOW_RADIUS + width },
  }
  if #style.colors > 1 then
    outer.fillGradient = "linear"
    outer.fillGradientColors = style.colors
    outer.fillGradientAngle = style.angle
  else
    outer.fillColor = style.colors[1]
  end
  -- Punch the window's own shape out of the filled rectangle, so only the
  -- ring around it is left.
  local hole = {
    type = "rectangle",
    action = "fill",
    fillColor = { white = 0, alpha = 1 },
    compositeRule = "destinationOut",
    frame = { x = width, y = width, w = w - 2 * width, h = h - 2 * width },
    roundedRectRadii = { xRadius = WINDOW_RADIUS, yRadius = WINDOW_RADIUS },
  }
  return { outer, hole }
end

--- Put the ring around the focused window, or hide it.
local function refresh()
  if not canvas then
    return
  end
  local win = target()
  if not win then
    hide()
    return
  end
  local f = win:frame()
  local width = style.width
  local key = string.format("%d:%d:%d:%d:%d", win:id() or 0, f.x, f.y, f.w, f.h)
  if key == lastKey then
    return
  end
  local frame = { x = f.x - width, y = f.y - width, w = f.w + 2 * width, h = f.h + 2 * width }
  local sizeChanged = not lastKey or canvas:frame().w ~= frame.w or canvas:frame().h ~= frame.h
  canvas:frame(frame)
  if sizeChanged then
    canvas:replaceElements(ringElements(frame.w, frame.h))
  end
  canvas:show()
  lastKey = key
end

--- Refresh now, then keep refreshing for a moment: yabai moves windows in
--- several steps and a drag sends a stream of events.
local function follow()
  refresh()
  followUntil = hs.timer.secondsSinceEpoch() + FOLLOW_FOR
  if followTimer and followTimer:running() then
    return
  end
  followTimer = hs.timer.doEvery(FOLLOW_INTERVAL, function()
    refresh()
    if hs.timer.secondsSinceEpoch() > followUntil then
      followTimer:stop()
    end
  end)
end

local function wanted()
  if M.bordersInstalled() and not M.force then
    return false, "JankyBorders is installed and draws the outline"
  end
  if exists(PAUSED_FILE) then
    return false, "the Gallery is off"
  end
  return true, nil
end

function M.stop()
  if filter then
    filter:unsubscribeAll()
    filter = nil
  end
  if spacesWatcher then
    spacesWatcher:stop()
    spacesWatcher = nil
  end
  if followTimer then
    followTimer:stop()
    followTimer = nil
  end
  if sanityTimer then
    sanityTimer:stop()
    sanityTimer = nil
  end
  if canvas then
    canvas:delete()
    canvas = nil
  end
  lastKey = nil
  reason = "stopped"
end

function M.start(ctx)
  local ok, why = wanted()
  if not ok then
    M.stop()
    reason = why
    return false
  end
  style = styleFrom(ctx and ctx.theme)
  if canvas then
    -- Already running: restyle in place.
    lastKey = nil
    refresh()
    reason = "running"
    return true
  end

  build()
  filter = hs.window.filter.new()
  filter:subscribe({
    hs.window.filter.windowFocused,
    hs.window.filter.windowUnfocused,
    hs.window.filter.windowMoved,
    hs.window.filter.windowVisible,
    hs.window.filter.windowNotVisible,
    hs.window.filter.windowMinimized,
    hs.window.filter.windowHidden,
    hs.window.filter.windowDestroyed,
    hs.window.filter.windowFullscreened,
    hs.window.filter.windowUnfullscreened,
  }, function() follow() end)
  spacesWatcher = hs.spaces.watcher.new(function() follow() end)
  spacesWatcher:start()
  -- A slow check for whatever the events miss (yabai can move a window
  -- without the app sending a moved notification).
  sanityTimer = hs.timer.doEvery(1, refresh)
  follow()
  reason = "running"
  return true
end

--- Re-read the style and start, restyle or stop to match the conditions.
function M.apply(ctx)
  return M.start(ctx)
end

--- Exposed for tests (tests/outline_test.lua).
M.styleFrom = styleFrom

--- The canvas frame and whether it is showing, for tests.
function M.canvasState()
  if not canvas then
    return nil
  end
  return { frame = canvas:frame(), showing = canvas:isShowing() }
end

function M.status()
  if canvas then
    return string.format("running, width %d, %s", style.width,
      #style.colors > 1 and "gradient" or "solid")
  end
  local _, why = wanted()
  return "not running: " .. tostring(why or reason)
end

return M
