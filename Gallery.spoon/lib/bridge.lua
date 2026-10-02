--- lib/bridge.lua -- the window.gallery JavaScript bridge for panel (and,
--- in future, overlay) webviews.
---
--- Owns everything to do with the WebKit usercontent controller named
--- "gallery": its creation, the document-start injected script that
--- defines window.gallery in the page, message handling for calls that
--- script posts back, and the two host-side data feeds (yabai spaces,
--- crystal_sampler metrics) it can subscribe to. lib/panel.lua only calls
--- Bridge.new() and wires the returned usercontent controller into
--- hs.webview.new(); the webview open/close/focus mechanics stay there.
---
--- Message protocol from JS -- always {action, requestId, ...}, requestId
--- present only on calls that expect a reply:
---   close                          -- fire-and-forget
---   log        {message}           -- fire-and-forget
---   exec       {requestId,cmd,args} -- spawns hs.task, replies once
---   subscribe  {topic}              -- starts a topic timer (idempotent)
---   unsubscribe{topic}              -- stops a topic timer
---
--- Lua replies to a requestId-bearing call by evaluating
---   window.__galleryReply({requestId=...,ok=...,result=...|error=...})
--- and pushes topic updates by evaluating
---   window.__galleryPush("<topic>", <data>)
--- Both receivers are defined by the injected script alongside
--- window.gallery itself (see buildInjectedScript below).
---
--- new(ctx, id, dir) -> {ucc, attach(webview), dispose()}
---   ctx  -- the Gallery Spoon object (self/obj from init.lua). Used for
---           ctx.log(level,msg), ctx.version, ctx.theme (optional table of
---           theme tokens), and ctx.close(ctx,id) (the same method the
---           `close` IPC verb uses) to service the JS "close" action
---           without lib/panel.lua having to be required back into this
---           module (which owns panel.lua's own M.close already).
---   id   -- plugin id; used only in log lines and to scope task/timer
---           bookkeeping to this one bridge instance.
---   dir  -- plugin directory; not read today, accepted for parity with
---           the contract and for any future per-plugin policy (e.g. an
---           exec allowlist) that might key off it.
---
--- attach(webview) must be called once the caller has the hs.webview
--- object in hand (replies/pushes are evaluateJavaScript calls against
--- it, so nothing can be delivered before this). dispose() stops every
--- timer this bridge instance owns; the caller is responsible for calling
--- it exactly once when the panel closes (lib/panel.lua's M.close does
--- this, and its "closing" windowCallback does too, defensively, in case
--- the window ever closes by some path other than M.close).

local M = {}

--- Registry of currently-attached bridges, keyed by plugin id:
---   M.open[id] = { webview = <hs.webview>, bridge = <bridge instance> }
--- Maintained by bridge.attach()/bridge.dispose() below (added on attach,
--- removed on dispose). Exists so a caller that only has a reference to
--- this loaded copy of lib/bridge.lua -- not to lib/panel.lua's or
--- lib/overlay.lua's own module-private bookkeeping -- can still discover
--- which webviews currently have a live bridge attached (e.g. for a
--- theme-reload re-inject). Note that lib/panel.lua and lib/overlay.lua
--- each dofile this file independently (see the selfDir() comment in
--- both), so each gets its own M table and therefore its own M.open --
--- init.lua's theme-reload iterates ctx.windows/Overlay.overlays directly
--- instead for exactly this reason; M.open remains most useful to a
--- caller that already holds the same Bridge module instance panel.lua
--- or overlay.lua loaded (or one that dofiles this file itself for
--- introspection, e.g. a future test).
M.open = {}

-- JS-facing concurrency cap on gallery.exec(); does not apply to the
-- bridge's own internal polling tasks (yabai queries), which are capped
-- structurally instead (see spacesInFlight in M.new).
local MAX_CONCURRENT_TASKS = 8

local DEFAULT_THEME = {
  name = "default",
  background = "#1f1811",
  foreground = "#e8e6df",
  accent = "#d8a656",
  muted = "#9a886c",
  surface = "#2a2214",
  danger = "#e5726f",
  success = "#5cc98f",
}

-- Resolved per the contract: `yabai` from Homebrew's fixed Apple Silicon
-- prefix, and crystal_sampler's metrics.json from HTOP_TEMP_DIR as
-- configured by the author's optional, not-public crystal widgets and their
-- sampler LaunchAgent (HTOP_TEMP_DIR=$HOME/tmp); without them the file is
-- absent and the metrics subscription simply gets no data.
-- Homebrew's prefix: /opt/homebrew on Apple silicon, /usr/local on Intel.
local YABAI_PATH = hs.fs.attributes("/opt/homebrew/bin/yabai") and "/opt/homebrew/bin/yabai"
  or "/usr/local/bin/yabai"
local METRICS_PATH = os.getenv("HOME") .. "/tmp/metrics.json"

local SPACES_INTERVAL = 2
local METRICS_INTERVAL = 1

--- hs.json.encode(v) raises "incorrect type '<type>' for argument 1
--- (expected table)" for a bare string/number/boolean -- confirmed by
--- hand, e.g. hs.json.encode("x") and hs.json.encode(42) both error. Every
--- other JSON encoder call in this file therefore goes through this
--- wrapper instead of hs.json.encode directly: a scalar is wrapped in a
--- 1-element array and the brackets stripped, so it still goes through
--- hs.json's own (correct) string/number escaping rather than
--- reimplementing it.
local function encodeJson(value)
  if type(value) == "table" then
    return pcall(hs.json.encode, value)
  end
  local ok, wrapped = pcall(hs.json.encode, { value })
  if not ok then
    return false, wrapped
  end
  return true, wrapped:sub(2, -2)
end

--- Shallow-merge ctx.theme (if a table) onto DEFAULT_THEME so a partial
--- theme still yields every token; falls back to DEFAULT_THEME whole.
local function resolveTheme(ctx)
  local override = ctx and ctx.theme
  if type(override) ~= "table" then
    return DEFAULT_THEME
  end
  local merged = {}
  for k, v in pairs(DEFAULT_THEME) do merged[k] = v end
  for k, v in pairs(override) do merged[k] = v end
  return merged
end

--- Build the document-start script text that defines window.gallery,
--- window.__galleryReply, and window.__galleryPush in the page. THEME and
--- VERSION are embedded as JSON literals (hs.json.encode output is valid
--- as a JS expression for the plain data used here). Built with plain
--- concatenation rather than string.format so a stray "%" anywhere in the
--- JS body below can never be misread as a format specifier.
local function buildInjectedScript(version, theme)
  local themeOk, themeJson = encodeJson(theme)
  if not themeOk then themeJson = "{}" end
  local versionOk, versionJson = encodeJson(tostring(version or ""))
  if not versionOk then versionJson = "\"\"" end

  return table.concat({
[[
(function () {
  var THEME = ]], themeJson, [[;
  var VERSION = ]], versionJson, [[;

  // Expose theme tokens as CSS custom properties on :root before anything
  // else in the page renders (this script runs at document start).
  try {
    var styleEl = document.createElement("style");
    styleEl.id = "gallery-theme";
    var css = ":root{";
    for (var key in THEME) {
      if (key === "name") continue;
      css += "--gallery-" + key + ": " + THEME[key] + ";";
    }
    css += "}";
    styleEl.textContent = css;
    (document.documentElement || document).appendChild(styleEl);
  } catch (e) { /* best effort -- a missing documentElement is not fatal */ }

  var pending = {};
  var nextRequestId = 1;
  var subs = {};

  function post(msg) {
    try {
      webkit.messageHandlers.gallery.postMessage(msg);
    } catch (e) { /* no bridge available -- calls below will just hang/no-op */ }
  }

  window.__galleryReply = function (msg) {
    var entry = pending[msg.requestId];
    if (!entry) return;
    delete pending[msg.requestId];
    if (msg.ok) {
      entry.resolve(msg.result);
    } else {
      entry.reject(new Error(msg.error || "gallery: unknown error"));
    }
  };

  window.__galleryPush = function (topic, data) {
    var list = subs[topic];
    if (!list) return;
    for (var i = 0; i < list.length; i++) {
      try { list[i](data); } catch (e) { /* one bad subscriber must not break others */ }
    }
  };

  window.gallery = {
    version: VERSION,
    theme: THEME,
    close: function () { post({ action: "close" }); },
    log: function (m) { post({ action: "log", message: String(m) }); },
    exec: function (cmd, args) {
      return new Promise(function (resolve, reject) {
        var id = nextRequestId++;
        pending[id] = { resolve: resolve, reject: reject };
        post({ action: "exec", requestId: id, cmd: String(cmd), args: args || [] });
      });
    },
    data: {
      subscribe: function (topic, cb) {
        if (typeof cb !== "function") return;
        if (!subs[topic]) {
          subs[topic] = [];
          post({ action: "subscribe", topic: topic });
        }
        subs[topic].push(cb);
      },
      unsubscribe: function (topic) {
        if (subs[topic]) {
          delete subs[topic];
          post({ action: "unsubscribe", topic: topic });
        }
      }
    }
  };
})();
]],
  })
end

--- Create a bridge instance: the usercontent controller, its message
--- callback, and the injected script. Never raises -- every fallible step
--- is pcall-wrapped and logged; a failure leaves .ucc nil, which
--- lib/panel.lua already treats as "create the webview without a bridge"
--- (same resilience the original inline code had).
function M.new(ctx, id, dir)
  local bridge = { ucc = nil }

  local webviewRef = nil
  local disposed = false
  local activeTasks = 0
  local timers = {} -- topic -> hs.timer
  local spacesInFlight = false
  local yabaiWarned = false
  local metricsWarned = false

  local function log(level, msg)
    if ctx and type(ctx.log) == "function" then
      pcall(ctx.log, level, "[" .. tostring(id) .. "] bridge: " .. msg)
    end
  end

  local function reply(requestId, ok, result, err)
    if disposed or not webviewRef or requestId == nil then
      return
    end
    local payload = { requestId = requestId, ok = ok and true or false }
    if ok then
      payload.result = result
    else
      payload.error = tostring(err or "unknown error")
    end
    local encodeOk, encoded = encodeJson(payload)
    if not encodeOk then
      log("WARN", "failed to encode reply: " .. tostring(encoded))
      return
    end
    pcall(function()
      webviewRef:evaluateJavaScript("window.__galleryReply(" .. encoded .. ")")
    end)
  end

  local function push(topic, data)
    if disposed or not webviewRef then
      return
    end
    local topicOk, topicJson = encodeJson(topic)
    local dataOk, dataJson = encodeJson(data)
    if not topicOk or not dataOk then
      log("WARN", "failed to encode push for topic " .. tostring(topic))
      return
    end
    pcall(function()
      webviewRef:evaluateJavaScript("window.__galleryPush(" .. topicJson .. ", " .. dataJson .. ")")
    end)
  end

  ------------------------------------------------------------------------
  -- exec: hs.task.new(cmd, callback, streamCallback, args) -- args array only, no shell.
  -- Rejects immediately (no task spawned) once MAX_CONCURRENT_TASKS is
  -- already running; rejects after the fact if the binary cannot be
  -- found or task:start() otherwise fails (confirmed by hand: hs.task.new
  -- on a nonexistent binary still returns a task object, but :start()
  -- returns false and the termination callback is never invoked -- so
  -- start()'s return value, not the callback, is what start-failure has
  -- to be detected from).
  ------------------------------------------------------------------------
  local function handleExec(body)
    local requestId = body.requestId
    local cmd = body.cmd
    local args = body.args
    if type(args) ~= "table" then
      args = {}
    end
    if type(cmd) ~= "string" or cmd == "" then
      reply(requestId, false, nil, "cmd must be a non-empty string")
      return
    end
    if activeTasks >= MAX_CONCURRENT_TASKS then
      reply(requestId, false, nil, "too many concurrent tasks (max " .. MAX_CONCURRENT_TASKS .. ")")
      return
    end

    -- Streaming form of hs.task.new: without a stream callback Hammerspoon
    -- only drains the pipes after the process exits, so any command whose
    -- output exceeds the 64 KiB pipe buffer blocks on write and never
    -- terminates (seen with `ps -Aro ...`, ~77 KB). With the stream callback
    -- the pipes are read as data arrives; the termination callback's own
    -- stdOut/stdErr are then empty, so the buffers below are the only copy.
    local outChunks, errChunks = {}, {}
    local task
    local createOk, createErr = pcall(function()
      task = hs.task.new(cmd, function(exitCode, stdOut, stdErr)
        activeTasks = activeTasks - 1
        if stdOut and stdOut ~= "" then outChunks[#outChunks + 1] = stdOut end
        if stdErr and stdErr ~= "" then errChunks[#errChunks + 1] = stdErr end
        reply(requestId, true, {
          code = exitCode,
          stdout = table.concat(outChunks),
          stderr = table.concat(errChunks),
        })
      end, function(_task, stdOut, stdErr)
        if stdOut and stdOut ~= "" then outChunks[#outChunks + 1] = stdOut end
        if stdErr and stdErr ~= "" then errChunks[#errChunks + 1] = stdErr end
        return true
      end, args)
    end)
    if not createOk or not task then
      reply(requestId, false, nil, "failed to create task: " .. tostring(createErr))
      return
    end

    activeTasks = activeTasks + 1
    local startOk, startErr = pcall(function() return task:start() end)
    if not startOk or not startErr then
      activeTasks = activeTasks - 1
      reply(requestId, false, nil, "failed to start task (binary not found or not executable): " .. tostring(cmd))
    end
  end

  ------------------------------------------------------------------------
  -- data.subscribe("spaces", cb): yabai spaces + windows, every 2s.
  ------------------------------------------------------------------------
  local function pushYabaiError()
    if not yabaiWarned then
      push("spaces", { error = "yabai not available" })
      yabaiWarned = true
    end
  end

  local function pollSpaces()
    if spacesInFlight then
      return
    end
    if not hs.fs.attributes(YABAI_PATH) then
      pushYabaiError()
      return
    end

    spacesInFlight = true
    local function finish()
      spacesInFlight = false
    end

    local function runWindowsQuery(spacesJson)
      local windowsTask
      local ok = pcall(function()
        windowsTask = hs.task.new(YABAI_PATH, function(code, out, _err)
          finish()
          if code ~= 0 then
            pushYabaiError()
            return
          end
          local decodeOk, windowsJson = pcall(hs.json.decode, out)
          if not decodeOk then
            pushYabaiError()
            return
          end
          yabaiWarned = false
          push("spaces", { spaces = spacesJson, windows = windowsJson })
        end, { "-m", "query", "--windows" })
      end)
      if not ok or not windowsTask or not windowsTask:start() then
        finish()
        pushYabaiError()
      end
    end

    local spacesTask
    local ok = pcall(function()
      spacesTask = hs.task.new(YABAI_PATH, function(code, out, _err)
        if code ~= 0 then
          finish()
          pushYabaiError()
          return
        end
        local decodeOk, spacesJson = pcall(hs.json.decode, out)
        if not decodeOk then
          finish()
          pushYabaiError()
          return
        end
        runWindowsQuery(spacesJson)
      end, { "-m", "query", "--spaces" })
    end)
    if not ok or not spacesTask or not spacesTask:start() then
      finish()
      pushYabaiError()
    end
  end

  ------------------------------------------------------------------------
  -- data.subscribe("metrics", cb): crystal_sampler's metrics.json, every 1s.
  -- Read directly (hs.json.read, same pcall convention as lib/state.lua
  -- and lib/manifest.lua) -- no subprocess needed, the sampler already
  -- writes the file atomically.
  ------------------------------------------------------------------------
  local function pollMetrics()
    local readOk, decoded = pcall(hs.json.read, METRICS_PATH)
    if readOk and type(decoded) == "table" then
      metricsWarned = false
      push("metrics", decoded)
    elseif not metricsWarned then
      push("metrics", { error = "metrics unavailable" })
      metricsWarned = true
    end
  end

  local function stopTimer(topic)
    if timers[topic] then
      pcall(function() timers[topic]:stop() end)
      timers[topic] = nil
    end
  end

  local function handleSubscribe(body)
    local topic = body.topic
    if topic == "spaces" then
      if not timers.spaces then
        yabaiWarned = false
        pollSpaces()
        timers.spaces = hs.timer.doEvery(SPACES_INTERVAL, pollSpaces)
      end
    elseif topic == "metrics" then
      if not timers.metrics then
        metricsWarned = false
        pollMetrics()
        timers.metrics = hs.timer.doEvery(METRICS_INTERVAL, pollMetrics)
      end
    else
      log("WARN", "unknown subscribe topic: " .. tostring(topic))
    end
  end

  local function handleUnsubscribe(body)
    local topic = body.topic
    if topic == "spaces" or topic == "metrics" then
      stopTimer(topic)
    end
  end

  ------------------------------------------------------------------------
  -- Message dispatch. Never raises: the usercontent callback below wraps
  -- this in its own pcall too, but each action here is defensive on its
  -- own so one malformed message can't take the others down with it.
  ------------------------------------------------------------------------
  local function handleMessage(message)
    local body = message and message.body
    if type(body) ~= "table" then
      return
    end
    local action = body.action
    if action == "close" then
      if ctx and type(ctx.close) == "function" then
        pcall(ctx.close, ctx, id)
      end
    elseif action == "log" then
      log("INFO", tostring(body.message))
    elseif action == "exec" then
      handleExec(body)
    elseif action == "subscribe" then
      handleSubscribe(body)
    elseif action == "unsubscribe" then
      handleUnsubscribe(body)
    else
      log("WARN", "unknown action: " .. tostring(action))
    end
  end

  ------------------------------------------------------------------------
  -- Build the controller.
  ------------------------------------------------------------------------
  local uccOk, controller = pcall(function() return hs.webview.usercontent.new("gallery") end)
  if uccOk and controller then
    bridge.ucc = controller

    local callbackOk, callbackErr = pcall(function()
      controller:setCallback(function(message)
        local ok, err = pcall(handleMessage, message)
        if not ok then
          log("WARN", "message handler error: " .. tostring(err))
        end
      end)
    end)
    if not callbackOk then
      log("WARN", "failed to set usercontent callback: " .. tostring(callbackErr))
    end

    local theme = resolveTheme(ctx)
    local injectSource = buildInjectedScript(ctx and ctx.version, theme)
    local injectOk, injectErr = pcall(function()
      controller:injectScript({
        source = injectSource,
        injectionTime = "documentStart",
      })
    end)
    if not injectOk then
      log("WARN", "failed to inject gallery bridge script: " .. tostring(injectErr))
    end
  else
    if ctx and type(ctx.log) == "function" then
      pcall(ctx.log, "WARN", "failed to create usercontent controller for " .. tostring(id) .. "; JS bridge disabled")
    end
  end

  function bridge.attach(webview)
    webviewRef = webview
    M.open[id] = { webview = webview, bridge = bridge }
  end

  --- Stop every timer this bridge instance owns. Idempotent -- safe to
  --- call more than once (lib/panel.lua's M.close calls it, and its
  --- "closing" windowCallback calls it again defensively).
  function bridge.dispose()
    disposed = true
    stopTimer("spaces")
    stopTimer("metrics")
    webviewRef = nil
    if M.open[id] and M.open[id].bridge == bridge then
      M.open[id] = nil
    end
  end

  -- dir is accepted per the contract signature but unused today; kept
  -- for parity and any future per-plugin policy keyed off the plugin's
  -- own directory (e.g. an exec allowlist).
  local _ = dir

  return bridge
end

return M
