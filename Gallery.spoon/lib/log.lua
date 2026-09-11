--- lib/log.lua -- Gallery's append-only log.
---
--- Returns a table with:
---   .path       -- the log file path (settable by the caller before first use)
---   .log(level, msg) -- append a timestamped line to .path and echo to the
---                        Hammerspoon console. Never raises: a failure to
---                        open the log file is silently swallowed so logging
---                        can never take Gallery down.

local M = {}

M.path = os.getenv("HOME") .. "/Library/Logs/gallery.log"

function M.log(level, msg)
  local line = string.format("%s %s %s", os.date("!%Y-%m-%dT%H:%M:%SZ"), level, msg)

  pcall(function()
    local f = io.open(M.path, "a")
    if f then
      f:write(line, "\n")
      f:close()
    end
  end)

  if hs and hs.printf then
    pcall(hs.printf, "[Gallery] %s: %s", level, msg)
  end
end

return M
