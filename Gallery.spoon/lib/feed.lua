--- lib/feed.lua -- kind "bar-widget": background commands run on an
--- interval, writing their output to ~/.config/gallery/feed/<id>.json for
--- Übersicht widgets (or anything else) to read.
---
--- ctx is expected to expose:
---   ctx.plugins        -- map: id -> {manifest, dir, errors, warnings}
---   ctx.log(level, msg) -- logging function
---   ctx:isEnabled(id)   -- used by M.rescan to decide what to (re)schedule
---
--- Keeps its own module-level state (M.widgets: map id -> record), same
--- shape and lifecycle discipline as lib/service.lua (start/stop/stopAll/
--- rescan/runNow), so tests (tests/kinds_test.lua) can introspect it
--- directly through spoon.Gallery.Feed. No restart-on-failure logic here
--- unlike lib/service.lua -- a widget command simply runs again on its
--- next tick regardless of the previous exit code.
---
--- Each enabled bar-widget-kind plugin gets manifest.gallery.widget.command
--- (with .args) run every manifest.gallery.widget.interval seconds
--- (default 10) via hs.timer.doEvery, synchronously from this module's
--- point of view (hs.task:start() then :waitUntilExit()) so M.runNow(id)
--- can be used by tests without racing the task's completion callback.
---
--- The command's stdout is parsed as JSON; if it doesn't decode to a
--- table it is wrapped as {"text": <trimmed stdout>} instead (per the
--- contract: "must be JSON; if not, wrap as {text: ...}"). Either way an
--- "updatedAt" epoch field is added before the file is written atomically
--- to ~/.config/gallery/feed/<id>.json.

local M = {}

M.widgets = {}

local DEFAULT_INTERVAL = 10
local MIN_INTERVAL = 1

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

local function feedDir()
  return os.getenv("HOME") .. "/.config/gallery/feed"
end

local function feedPath(id)
  return feedDir() .. "/" .. id .. ".json"
end

local function writeFeed(ctx, id, stdout)
  pcall(function()
    hs.fs.mkdir(os.getenv("HOME") .. "/.config/gallery")
    hs.fs.mkdir(feedDir())

    local trimmed = (stdout or ""):match("^%s*(.-)%s*$")
    local decodeOk, decoded = pcall(hs.json.decode, trimmed)
    local payload
    if decodeOk and type(decoded) == "table" then
      payload = decoded
    else
      payload = { text = trimmed }
    end
    payload.updatedAt = os.time()

    local encodeOk, encoded = pcall(hs.json.encode, payload)
    if not encodeOk then
      ctx.log("WARN", "widget " .. id .. " failed to encode feed payload")
      return
    end

    local path = feedPath(id)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if f then
      f:write(encoded)
      f:close()
      os.rename(tmp, path)
    end
  end)
end

local function runCommand(ctx, id, record, cfg)
  local command = cfg.command
  local args = cfg.args
  if type(args) ~= "table" then
    args = {}
  end
  if type(command) ~= "string" or command == "" then
    ctx.log("WARN", "widget " .. id .. " has no command configured")
    return
  end

  local exitCode, stdout
  local newOk, task = pcall(hs.task.new, command, function(code, out, err)
    exitCode = code
    stdout = out
    if code ~= 0 then
      ctx.log("WARN", "widget " .. id .. " exited " .. tostring(code) .. ": " .. tostring(err))
    end
  end, args)

  if not newOk or not task then
    ctx.log("WARN", "failed to create task for widget " .. id)
    return
  end

  local startOk = false
  pcall(function() startOk = task:start() end)
  if not startOk then
    ctx.log("WARN", "failed to start task for widget " .. id)
    return
  end
  pcall(function() task:waitUntilExit() end)

  -- hs.task:waitUntilExit() only guarantees the OS process has exited, not
  -- that the completion callback above has already run (observed by hand:
  -- under heavy system load the two can be seconds apart) -- so the exit
  -- code comes from task:terminationStatus(), available the moment the
  -- process exits, rather than the callback's `code` upvalue, which may
  -- still be nil here. stdout has no such synchronous accessor and stays
  -- best-effort: if the callback truly hasn't run yet, writeFeed below
  -- falls back to {"text": ""} for this tick rather than raising, and the
  -- next tick (or the next runNow) picks up cleanly.
  local statusOk, terminationStatus = pcall(function() return task:terminationStatus() end)
  if statusOk and terminationStatus ~= nil then
    exitCode = terminationStatus
  end

  record.lastRun = os.time()
  record.code = exitCode
  writeFeed(ctx, id, stdout)
end

--- Schedule (or reschedule) id's widget timer. No-op if id is unknown,
--- errored, or not a bar-widget-kind plugin. Stops any existing timer for
--- id first, so this is safe to call repeatedly (enable, rescan).
function M.start(ctx, id)
  local entry = ctx.plugins[id]
  if not entry then
    return
  end
  local manifest = entry.manifest
  if entry.errors and #entry.errors > 0 then
    return
  end
  if not manifest or not tableContains(manifest.kinds, "bar-widget") then
    return
  end

  if M.widgets[id] then
    M.stop(id)
  end

  local cfg = (manifest.gallery and manifest.gallery.widget) or {}
  local interval = tonumber(cfg.interval) or DEFAULT_INTERVAL
  if interval < MIN_INTERVAL then
    interval = MIN_INTERVAL
  end

  local record = {
    ctx = ctx,
    cfg = cfg,
    interval = interval,
    lastRun = nil,
    code = nil,
  }
  M.widgets[id] = record

  local timerOk, timer = pcall(hs.timer.doEvery, interval, function()
    pcall(runCommand, ctx, id, record, cfg)
  end)
  if timerOk and timer then
    record.timer = timer
  else
    ctx.log("WARN", "failed to schedule widget " .. id)
  end

  -- Run once immediately so a fresh start/enable/rescan doesn't wait a
  -- full interval before the first feed file exists.
  pcall(runCommand, ctx, id, record, cfg)
end

--- Stop id's timer and forget it. Safe to call on an id with no running
--- widget (no-op).
function M.stop(id)
  local record = M.widgets[id]
  if not record then
    return
  end
  if record.timer then
    pcall(function() record.timer:stop() end)
  end
  M.widgets[id] = nil
end

--- Stop every running widget. Called from init.lua's obj:stop().
function M.stopAll()
  for id in pairs(M.widgets) do
    M.stop(id)
  end
end

--- Rebuild timers for every currently-enabled, error-free bar-widget-kind
--- plugin, mirroring lib/service.lua's M.rescan.
function M.rescan(ctx)
  M.stopAll()
  for id, entry in pairs(ctx.plugins) do
    local manifest = entry.manifest
    local errored = entry.errors and #entry.errors > 0
    if not errored and manifest and tableContains(manifest.kinds, "bar-widget") and ctx:isEnabled(id) then
      M.start(ctx, id)
    end
  end
end

--- Force an immediate run of id's command, bypassing its timer. Exposed
--- for tests (see tests/kinds_test.lua). Requires id to already have a
--- running widget (i.e. M.start has scheduled it).
function M.runNow(id)
  local record = M.widgets[id]
  if not record then
    return "not running: " .. id
  end
  runCommand(record.ctx, id, record, record.cfg)
  return "ran " .. id
end

return M
