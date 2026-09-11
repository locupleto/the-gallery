--- lib/state.lua -- persisted enable/disable state at
--- ~/.config/gallery/gallery.json:
---   {"schemaVersion":1,"enabled":["gallery.hello"],"disabled":[],"settings":{}}
---
--- Every function takes the state path explicitly (defaulting to
--- M.defaultPath()) rather than storing it as module state, so tests can
--- point at a temp file instead of the real one.
---
--- Returns a table with:
---   .defaultPath() -> string
---   .load(path) -> state table (created on disk with the default shape if
---                  the file is missing or unreadable)
---   .save(state, path) -- atomic write (temp file + os.rename)
---   .isEnabled(state, id, isFirstParty) -> bool
---   .enable(state, id, path) -- adds id to enabled[], removes from
---                  disabled[], saves; returns state
---   .disable(state, id, path) -- adds id to disabled[], removes from
---                  enabled[], saves; returns state

local M = {}

function M.defaultPath()
  return os.getenv("HOME") .. "/.config/gallery/gallery.json"
end

local function defaultState()
  return {
    schemaVersion = 1,
    enabled = { "gallery.hello" },
    disabled = {},
    settings = {},
  }
end

local function removeValue(list, value)
  local out = {}
  for _, v in ipairs(list or {}) do
    if v ~= value then
      table.insert(out, v)
    end
  end
  return out
end

local function tableContains(t, value)
  for _, v in ipairs(t or {}) do
    if v == value then
      return true
    end
  end
  return false
end

--- Write state to path atomically: write to path..".tmp" then os.rename
--- over the destination, so a reader never observes a half-written file.
function M.save(state, path)
  path = path or M.defaultPath()
  local tmpPath = path .. ".tmp"

  local dir = path:match("(.*)/[^/]+$")
  if dir then
    pcall(hs.fs.mkdir, dir)
  end

  local ok, err = pcall(function()
    local encoded = hs.json.encode(state, true)
    local f = assert(io.open(tmpPath, "w"))
    f:write(encoded)
    f:close()
    local renameOk, renameErr = os.rename(tmpPath, path)
    if not renameOk then
      error(renameErr or ("failed to rename " .. tmpPath .. " to " .. path))
    end
  end)

  if not ok then
    pcall(os.remove, tmpPath)
    error(err)
  end

  return state
end

--- Load state from path, creating it with the default shape if missing or
--- unreadable. Never raises.
function M.load(path)
  path = path or M.defaultPath()

  local readOk, decoded = pcall(hs.json.read, path)
  if readOk and type(decoded) == "table" then
    decoded.schemaVersion = decoded.schemaVersion or 1
    decoded.enabled = decoded.enabled or {}
    decoded.disabled = decoded.disabled or {}
    decoded.settings = decoded.settings or {}
    return decoded
  end

  local state = defaultState()
  pcall(M.save, state, path)
  return state
end

--- True if id should be considered enabled: explicitly in enabled[], or
--- (when isFirstParty) not explicitly disabled.
function M.isEnabled(state, id, isFirstParty)
  if tableContains(state.enabled, id) then
    return true
  end
  if tableContains(state.disabled, id) then
    return false
  end
  return isFirstParty == true
end

function M.enable(state, id, path)
  state.disabled = removeValue(state.disabled, id)
  if not tableContains(state.enabled, id) then
    table.insert(state.enabled, id)
  end
  M.save(state, path)
  return state
end

function M.disable(state, id, path)
  state.enabled = removeValue(state.enabled, id)
  if not tableContains(state.disabled, id) then
    table.insert(state.disabled, id)
  end
  M.save(state, path)
  return state
end

return M
