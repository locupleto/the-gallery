-- tests/outline_test.lua -- headless tests for Gallery.spoon/lib/outline.lua,
-- the focus outline Hammerspoon draws where JankyBorders cannot run: how it
-- reads the colour and width out of the theme tokens. Drawing itself needs
-- a screen and is checked by hand.
--
-- Invoke with:
--   hs -t 30 -q /absolute/path/to/tests/outline_test.lua
--
-- (see tests/manifest_test.lua for why the path comes from _cli.args)

local function selfDir()
  local selfPath = _cli and _cli.args and _cli.args[1]
  if type(selfPath) == "string" then
    local dir = selfPath:match("(.*/)")
    if dir then
      return dir
    end
  end
  return "./"
end

local Outline = dofile(selfDir() .. "../Gallery.spoon/lib/outline.lua")

local passCount = 0
local failures = {}

local function check(name, condition, detail)
  if condition then
    passCount = passCount + 1
  else
    table.insert(failures, name .. (detail and (" -- " .. tostring(detail)) or ""))
  end
end

local function near(a, b)
  return type(a) == "number" and math.abs(a - b) < 0.002
end

-- A solid JankyBorders colour: 0xAARRGGBB.
local s = Outline.styleFrom({ border_active = "0xff93b68d", border_width = 8 })
check("solid: one colour", #s.colors == 1, #s.colors)
check("solid: red", near(s.colors[1].red, 0x93 / 255), s.colors[1].red)
check("solid: green", near(s.colors[1].green, 0xb6 / 255), s.colors[1].green)
check("solid: blue", near(s.colors[1].blue, 0x8d / 255), s.colors[1].blue)
check("solid: alpha", near(s.colors[1].alpha, 1), s.colors[1].alpha)
check("solid: width", s.width == 8, s.width)

-- A gradient keeps both stops, and the diagonal sets the angle.
s = Outline.styleFrom({ border_active = "gradient(top_left=0xee26a269,bottom_right=0xee2ec27e)" })
check("gradient: two colours", #s.colors == 2, #s.colors)
check("gradient: first stop", near(s.colors[1].red, 0x26 / 255), s.colors[1] and s.colors[1].red)
check("gradient: alpha kept", near(s.colors[1].alpha, 0xee / 255), s.colors[1] and s.colors[1].alpha)
check("gradient: top_left angle", s.angle == 45, s.angle)
s = Outline.styleFrom({ border_active = "gradient(top_right=0xff000000,bottom_left=0xffffffff)" })
check("gradient: top_right angle", s.angle == 135, s.angle)

-- No border tokens (an older theme.json): the accent, at the default width.
s = Outline.styleFrom({ accent = "#509475" })
check("fallback: accent", #s.colors == 1 and near(s.colors[1].green, 0x94 / 255), s.colors[1] and s.colors[1].green)
check("fallback: default width", s.width == 5, s.width)

-- Out-of-range widths are ignored.
s = Outline.styleFrom({ border_active = "0xff000000", border_width = 40 })
check("width over 12 ignored", s.width == 5, s.width)

-- Nothing usable at all still gives a colour.
s = Outline.styleFrom(nil)
check("nil theme: a colour", #s.colors == 1 and type(s.colors[1].red) == "number")

-- Not started: no canvas, and a status line saying why.
check("not started: no canvas", Outline.canvasState() == nil)
check("not started: status", Outline.status():find("^not running") ~= nil, Outline.status())

if #failures == 0 then
  return "PASS " .. passCount
end
return "FAIL\n" .. table.concat(failures, "\n")
