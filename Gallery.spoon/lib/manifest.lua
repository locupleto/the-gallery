--- lib/manifest.lua -- plugin discovery and manifest validation.
---
--- Returns a table with:
---   .KNOWN_KINDS       -- array of kind names considered "known" (only used
---                         to decide whether to warn on an unknown kind)
---   .validate(manifest, dir) -> errors, warnings
---       errors and warnings are each an array of strings. `dir` is the
---       plugin's directory, used to resolve and check entry point paths.
---   .scan(pluginDir) -> list of {id, dir, manifest, errors, warnings}
---       One entry per subdirectory of pluginDir containing a manifest.json.
---       A plugin whose manifest fails to decode or fails validation is
---       still included in the list (with its errors filled in) -- this
---       function never raises.
---
--- This module only depends on hs.fs and hs.json (both preloaded by
--- init.lua before scan() is ever called) plus the Lua 5.4 standard
--- library, so it can also be dofile'd standalone (e.g. from
--- tests/manifest_test.lua run headless through `hs -q`).

local M = {}

M.KNOWN_KINDS = {
  ["bar-widget"] = true,
  ["panel"] = true,
  ["overlay"] = true,
  ["menu"] = true,
  ["service"] = true,
  ["bar"] = true,
  ["tui"] = true,
}

-- The live plugin directory: any manifest scanned from here could in
-- principle have been dropped in by a third party, so an id claiming the
-- "gallery." first-party prefix is always warned about at this location,
-- whether or not it actually shipped with the repo -- scan()/validate()
-- have no way to tell the difference once a plugin is installed here.
local FIRST_PARTY_DIR = os.getenv("HOME") .. "/.config/gallery/plugins"

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

-- hasEntryForKind/entryKeyMatchesKinds -- the kinds<->entryPoints cross-
-- consistency checks below match kind names to entryPoints keys directly
-- (both "panel" and "panel") EXCEPT for "bar-widget", where an unmodified
-- Omarchy manifest uses the camelCase key "barWidget" (see the Radio Atlas
-- manifest this was modelled on) while our own bar-widget-kind plugins
-- (if any ever declare an entry point at all) would use the hyphenated
-- key matching the kind name -- both spellings are accepted so neither
-- convention ever produces a spurious warning.
local function hasEntryForKind(entryPoints, kind)
  if entryPoints[kind] ~= nil then
    return true
  end
  if kind == "bar-widget" and entryPoints["barWidget"] ~= nil then
    return true
  end
  return false
end

local function entryKeyMatchesKinds(key, kinds)
  if tableContains(kinds, key) then
    return true
  end
  if key == "barWidget" and tableContains(kinds, "bar-widget") then
    return true
  end
  return false
end

local function isStringArray(t)
  if type(t) ~= "table" then
    return false
  end
  local n = 0
  for k, v in pairs(t) do
    if type(k) ~= "number" then
      return false
    end
    if type(v) ~= "string" then
      return false
    end
    n = n + 1
  end
  return n == #t
end

--- Validate a decoded manifest table against the plugin directory `dir`
--- (used to resolve/check entry point paths). Returns two arrays of
--- strings: errors and warnings. Never raises.
function M.validate(manifest, dir)
  local errors = {}
  local warnings = {}

  if type(manifest) ~= "table" then
    table.insert(errors, "manifest is not a table")
    return errors, warnings
  end

  if manifest.schemaVersion ~= 1 then
    table.insert(errors, "schemaVersion is not 1")
  end

  if type(manifest.id) ~= "string" or manifest.id == "" then
    table.insert(errors, "missing or invalid id")
  end
  if type(manifest.name) ~= "string" or manifest.name == "" then
    table.insert(errors, "missing or invalid name")
  end
  if type(manifest.version) ~= "string" or manifest.version == "" then
    table.insert(errors, "missing or invalid version")
  end

  local id = manifest.id
  if type(id) == "string" and id ~= "" then
    if not id:match("^[a-z0-9][a-z0-9%.%-]*$") then
      table.insert(errors, "id does not match ^[a-z0-9][a-z0-9.-]*$: " .. id)
    end
    if id:match("^omarchy%.") then
      table.insert(warnings, "reserved upstream namespace: " .. id)
    end
    if id:match("^gallery%.") and type(dir) == "string" and dir:sub(1, #FIRST_PARTY_DIR) == FIRST_PARTY_DIR then
      table.insert(warnings, "first-party namespace: " .. id)
    end
  end

  local kinds = manifest.kinds
  local kindsOk = isStringArray(kinds) and #kinds > 0
  if not kindsOk then
    table.insert(errors, "kinds is not a non-empty array of strings")
  else
    for _, kind in ipairs(kinds) do
      if not M.KNOWN_KINDS[kind] then
        table.insert(warnings, "unknown kind: " .. tostring(kind))
      end
    end
  end

  local entryPoints = manifest.entryPoints
  local entryPointsOk = type(entryPoints) == "table"
  if not entryPointsOk then
    table.insert(errors, "entryPoints is not a table")
  else
    for kind, entryPoint in pairs(entryPoints) do
      if type(entryPoint) ~= "string" or entryPoint == "" then
        table.insert(errors, "entry point for kind '" .. tostring(kind) .. "' is not a string")
      else
        if entryPoint:sub(1, 1) == "/" then
          table.insert(errors, "entry point for kind '" .. tostring(kind) .. "' is an absolute path: " .. entryPoint)
        elseif entryPoint:find("..", 1, true) then
          table.insert(errors, "entry point for kind '" .. tostring(kind) .. "' contains '..': " .. entryPoint)
        elseif type(dir) == "string" then
          local full = dir .. "/" .. entryPoint
          local attr = hs.fs.attributes(full)
          if not attr or attr.mode ~= "file" then
            table.insert(errors, "entry point for kind '" .. tostring(kind) .. "' does not exist: " .. entryPoint)
          end
        end

        -- A .qml entry point (an unmodified Omarchy plugin) is a normal,
        -- fully supported case -- it runs under the Quickshell-for-macOS
        -- host (bin/gallery-qml), not a native Gallery panel/overlay. No
        -- warning here; see Gallery.spoon/init.lua's resolveKind, which is
        -- where such a panel/overlay is routed to "qml" instead.
      end
    end
  end

  -- A tui-kind plugin has no entry point file (it runs a shell command in
  -- a terminal window instead -- see bin/gallery-tui); what it must declare
  -- is manifest.gallery.tui.command.
  if kindsOk and tableContains(kinds, "tui") then
    local tuiCfg = manifest.gallery and manifest.gallery.tui
    if type(tuiCfg) ~= "table" or type(tuiCfg.command) ~= "string" or tuiCfg.command == "" then
      table.insert(errors, "tui kind requires gallery.tui.command (non-empty string)")
    end
  end

  -- kinds/entryPoints cross-consistency -- warnings only, both directions.
  -- (See hasEntryForKind/entryKeyMatchesKinds above for the bar-widget/
  -- barWidget alias this needs to allow.)
  if kindsOk then
    for _, kind in ipairs(kinds) do
      if not (entryPointsOk and hasEntryForKind(entryPoints, kind)) then
        table.insert(warnings, "kind '" .. kind .. "' has no entry point")
      end
    end
  end
  if entryPointsOk then
    for key, _ in pairs(entryPoints) do
      if not (kindsOk and entryKeyMatchesKinds(key, kinds)) then
        table.insert(warnings, "entry point declared for kind '" .. tostring(key) .. "' not listed in kinds")
      end
    end
  end

  return errors, warnings
end

--- True if manifest.entryPoints[kind] is a non-empty path ending in
--- ".qml" -- i.e. this kind is actually an unmodified Omarchy plugin
--- rendered by the Quickshell-for-macOS host (bin/gallery-qml), not a
--- native Gallery kind module. Meaningful only for kind == "panel" or
--- "overlay" (the two kinds an Omarchy manifest ever puts a .qml file
--- behind); called from Gallery.spoon/init.lua's resolveKind, which is
--- the single place a resolved panel/overlay is turned into "qml", and
--- mirrored exactly by bin/gallery's own PY_RESOLVE_KIND (the CLI's
--- Python helper for its own non-Hammerspoon routing).
function M.isQmlEntryPoint(manifest, kind)
  local entryPoints = manifest and manifest.entryPoints
  if type(entryPoints) ~= "table" then
    return false
  end
  local entryPoint = entryPoints[kind]
  return type(entryPoint) == "string" and entryPoint:sub(-4) == ".qml"
end

--- Scan pluginDir for subdirectories containing manifest.json. Returns a
--- list of {id, dir, manifest, errors, warnings}. Never raises: a missing
--- plugin directory yields an empty list, and an unreadable/undecodable
--- manifest is recorded as an errored entry rather than skipped or raised.
function M.scan(pluginDir)
  local results = {}

  local dirOk, dirAttr = pcall(hs.fs.attributes, pluginDir)
  if not dirOk or not dirAttr or dirAttr.mode ~= "directory" then
    return results
  end

  local scanOk, scanErr = pcall(function()
    for entry in hs.fs.dir(pluginDir) do
      if entry ~= "." and entry ~= ".." then
        local pluginPath = pluginDir .. "/" .. entry
        local attr = hs.fs.attributes(pluginPath)
        if attr and attr.mode == "directory" then
          local manifestPath = pluginPath .. "/manifest.json"
          if hs.fs.attributes(manifestPath) then
            local readOk, manifest = pcall(hs.json.read, manifestPath)
            if readOk and manifest then
              local errors, warnings = M.validate(manifest, pluginPath)
              table.insert(results, {
                id = manifest.id,
                dir = pluginPath,
                manifest = manifest,
                errors = errors,
                warnings = warnings,
              })
            else
              table.insert(results, {
                id = nil,
                dir = pluginPath,
                manifest = nil,
                errors = { "failed to read/decode manifest at " .. manifestPath },
                warnings = {},
              })
            end
          end
        end
      end
    end
  end)

  if not scanOk then
    table.insert(results, {
      id = nil,
      dir = pluginDir,
      manifest = nil,
      errors = { "error scanning plugin directory: " .. tostring(scanErr) },
      warnings = {},
    })
  end

  return results
end

return M
