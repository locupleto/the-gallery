--- lib/service.lua -- kind "service": background commands run on an
--- interval, independent of any panel/overlay/menu window state.
---
--- ctx is expected to expose:
---   ctx.plugins        -- map: id -> {manifest, dir, errors, warnings}
---   ctx.log(level, msg) -- logging function
---   ctx:isEnabled(id)   -- used by M.rescan to decide what to (re)schedule
---
--- Keeps its own module-level state (M.services: map id -> record) so
--- tests (tests/kinds_test.lua) and the `services` IPC verb (see
--- init.lua) can introspect it directly through spoon.Gallery.Service.
---
--- Each enabled service-kind plugin gets manifest.gallery.service.command
--- (with .args) run every manifest.gallery.service.interval seconds
--- (default 60, floored at 5) via hs.timer.doEvery. Each run is
--- synchronous from this module's point of view (hs.task:start() then
--- :waitUntilExit()) so a run's result -- and the heartbeat file write
--- that follows it -- is never split across two event-loop turns; this
--- also lets M.runNow(id) be used by tests without a race against the
--- task's completion callback. On a non-zero exit with
--- manifest.gallery.service.restartOnFailure true, retries after 5s up to
--- 3 times before giving up and logging.
---
--- Writes ~/.config/gallery/state/services/<id>.json:
---   {"lastRun": <epoch>, "code": <exit code>, "restarts": <count>}
---
--- Returns a table with .start(ctx, id), .stop(id), .stopAll(),
--- .rescan(ctx), .runNow(id), .statusLines().

local M = {}

M.services = {}

local DEFAULT_INTERVAL = 60
local MIN_INTERVAL = 5
local MAX_RETRIES = 3
local RETRY_DELAY = 5
local STDOUT_TAIL_BYTES = 2048

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

local function stateDir()
  return os.getenv("HOME") .. "/.config/gallery/state/services"
end

local function heartbeatPath(id)
  return stateDir() .. "/" .. id .. ".json"
end

local function writeHeartbeat(id, record)
  pcall(function()
    hs.fs.mkdir(os.getenv("HOME") .. "/.config/gallery")
    hs.fs.mkdir(os.getenv("HOME") .. "/.config/gallery/state")
    hs.fs.mkdir(stateDir())

    local encodeOk, encoded = pcall(hs.json.encode, {
      lastRun = record.lastRun,
      code = record.code,
      restarts = record.restarts,
    })
    if not encodeOk then
      return
    end

    local path = heartbeatPath(id)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if f then
      f:write(encoded)
      f:close()
      os.rename(tmp, path)
    end
  end)
end

local function tailString(s, maxBytes)
  s = s or ""
  if #s <= maxBytes then
    return s
  end
  return s:sub(#s - maxBytes + 1)
end

-- Forward-declared: a failed run with restartOnFailure schedules a retry
-- that calls this function again.
local runCommand

runCommand = function(ctx, id, record, cfg)
  local command = cfg.command
  local args = cfg.args
  if type(args) ~= "table" then
    args = {}
  end
  if type(command) ~= "string" or command == "" then
    ctx.log("WARN", "service " .. id .. " has no command configured")
    return
  end

  local exitCode, stdout
  local newOk, task = pcall(hs.task.new, command, function(code, out, err)
    exitCode = code
    stdout = out
    if code ~= 0 then
      ctx.log("WARN", "service " .. id .. " exited " .. tostring(code) .. ": " .. tostring(err))
    end
  end, args)

  if not newOk or not task then
    ctx.log("WARN", "failed to create task for service " .. id)
    return
  end

  local startOk = false
  pcall(function() startOk = task:start() end)
  if not startOk then
    ctx.log("WARN", "failed to start task for service " .. id)
    return
  end
  pcall(function() task:waitUntilExit() end)

  -- hs.task:waitUntilExit() only guarantees the OS process has exited, not
  -- that the completion callback above has already run (observed by hand:
  -- under heavy system load the two can be seconds apart) -- so the exit
  -- code comes from task:terminationStatus(), which is available the
  -- moment the process exits, rather than from the callback's `code`
  -- upvalue, which may still be nil here. stdout has no such synchronous
  -- accessor and stays best-effort (nil if the callback truly hasn't run
  -- yet); see the same note in lib/feed.lua.
  local statusOk, terminationStatus = pcall(function() return task:terminationStatus() end)
  if statusOk and terminationStatus ~= nil then
    exitCode = terminationStatus
  end

  record.lastRun = os.time()
  record.code = exitCode
  record.stdoutTail = tailString(stdout, STDOUT_TAIL_BYTES)
  writeHeartbeat(id, record)

  if exitCode ~= nil and exitCode ~= 0 then
    if cfg.restartOnFailure and record.retries < MAX_RETRIES then
      record.retries = record.retries + 1
      record.restarts = record.restarts + 1
      ctx.log("INFO", "service " .. id .. " restart " .. record.retries .. "/" .. MAX_RETRIES .. " in " .. RETRY_DELAY .. "s")
      record.retryTimer = hs.timer.doAfter(RETRY_DELAY, function()
        if M.services[id] == record then
          runCommand(ctx, id, record, cfg)
        end
      end)
    elseif cfg.restartOnFailure then
      record.failed = true
      ctx.log("ERROR", "service " .. id .. " failed after " .. MAX_RETRIES .. " restarts; giving up")
    end
  else
    record.retries = 0
    record.failed = false
  end
end

--- Schedule (or reschedule) id's service timer. No-op if id is unknown,
--- errored, or not a service-kind plugin. Stops any existing timer for id
--- first, so this is safe to call repeatedly (enable, rescan).
function M.start(ctx, id)
  local entry = ctx.plugins[id]
  if not entry then
    return
  end
  local manifest = entry.manifest
  if entry.errors and #entry.errors > 0 then
    return
  end
  if not manifest or not tableContains(manifest.kinds, "service") then
    return
  end

  if M.services[id] then
    M.stop(id)
  end

  local cfg = (manifest.gallery and manifest.gallery.service) or {}
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
    stdoutTail = "",
    restarts = 0,
    retries = 0,
    failed = false,
  }
  M.services[id] = record

  local timerOk, timer = pcall(hs.timer.doEvery, interval, function()
    pcall(runCommand, ctx, id, record, cfg)
  end)
  if timerOk and timer then
    record.timer = timer
  else
    ctx.log("WARN", "failed to schedule service " .. id)
  end

  -- Run once immediately so a fresh start/enable/rescan doesn't wait a
  -- full interval before the first heartbeat exists.
  pcall(runCommand, ctx, id, record, cfg)
end

--- Stop id's timer(s) and forget it. Safe to call on an id with no
--- running service (no-op).
function M.stop(id)
  local record = M.services[id]
  if not record then
    return
  end
  if record.timer then
    pcall(function() record.timer:stop() end)
  end
  if record.retryTimer then
    pcall(function() record.retryTimer:stop() end)
  end
  M.services[id] = nil
end

--- Stop every running service. Called from init.lua's obj:stop().
function M.stopAll()
  for id in pairs(M.services) do
    M.stop(id)
  end
end

--- Rebuild timers for every currently-enabled, error-free service-kind
--- plugin. Stops every existing timer first (so a plugin that lost its
--- service kind, or was disabled, is not left running), then starts one
--- for each match. Called at Spoon start, and again on enable/disable/
--- rescan.
function M.rescan(ctx)
  M.stopAll()
  for id, entry in pairs(ctx.plugins) do
    local manifest = entry.manifest
    local errored = entry.errors and #entry.errors > 0
    if not errored and manifest and tableContains(manifest.kinds, "service") and ctx:isEnabled(id) then
      M.start(ctx, id)
    end
  end
end

--- Force an immediate run of id's command, bypassing its timer. Exposed
--- for tests (see tests/kinds_test.lua) so a heartbeat can be asserted
--- without waiting up to a full interval. Requires id to already have a
--- running service (i.e. M.start has scheduled it).
function M.runNow(id)
  local record = M.services[id]
  if not record then
    return "not running: " .. id
  end
  runCommand(record.ctx, id, record, record.cfg)
  return "ran " .. id
end

--- One line per running service: "<id>\t<interval>\t<lastRun>\t<code>\t<restarts>".
--- lastRun is an ISO-8601 UTC timestamp, or "never" if it hasn't run yet.
function M.statusLines()
  local lines = {}
  for id, record in pairs(M.services) do
    table.insert(lines, string.format(
      "%s\t%ss\t%s\t%s\t%s",
      id,
      tostring(record.interval),
      record.lastRun and os.date("!%Y-%m-%dT%H:%M:%SZ", record.lastRun) or "never",
      tostring(record.code),
      tostring(record.restarts)
    ))
  end
  table.sort(lines)
  return lines
end

return M
