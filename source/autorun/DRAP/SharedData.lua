-- DRAP/SharedData.lua
-- Single source of truth for static data shared between Python (AP generation)
-- and Lua (in-game enforcement): areas, time keys, items, survivors, stickers.
--
-- Data lives in drdr_shared.json (shipped under reframework/data/).
-- The file is loaded lazily on first access and cached.
--
-- IMPORTANT: source/data/drdr_shared.json and apworld/drdr/drdr_shared.json
-- MUST stay identical. Only edit the source/data/ copy, then sync.
-- See source/data/README.md for the full sync rule.

local M = {}

local SHARED_JSON_PATH = "drdr_shared.json"
local data = nil
local load_attempted = false

local Shared = require("DRAP/Shared")
local log = Shared.create_logger("SharedData")

local function ensure_loaded()
    if data then return true end
    if load_attempted and not data then return false end
    load_attempted = true

    local loaded = json.load_file(SHARED_JSON_PATH)
    if not loaded then
        log("Failed to load " .. SHARED_JSON_PATH)
        return false
    end
    if type(loaded) ~= "table" then
        log(SHARED_JSON_PATH .. " did not parse to a table")
        return false
    end
    data = loaded
    log(string.format(
        "Loaded schema_version=%s (areas=%d, time_keys=%d, items=%d, survivors=%d, stickers=%d)",
        tostring(data.schema_version),
        data.areas and #data.areas or 0,
        data.time_keys and #data.time_keys or 0,
        data.items and #data.items or 0,
        data.survivors and #data.survivors or 0,
        data.stickers and #data.stickers or 0
    ))
    return true
end

-- Allow callers to force a reload (e.g., after editing the JSON at runtime).
function M.reload()
    data = nil
    load_attempted = false
    return ensure_loaded()
end

-- Section accessors. Return an empty table if the file isn't available so
-- callers can iterate safely without nil checks.
function M.areas()
    ensure_loaded()
    return (data and data.areas) or {}
end

function M.time_keys()
    ensure_loaded()
    return (data and data.time_keys) or {}
end

function M.items()
    ensure_loaded()
    return (data and data.items) or {}
end

function M.survivors()
    ensure_loaded()
    return (data and data.survivors) or {}
end

function M.stickers()
    ensure_loaded()
    return (data and data.stickers) or {}
end

-- Scoop -> list of survivor display names that escape to the Security Room as part
-- of that scoop. Only includes scoops whose npcs field contains at least one
-- name matching a "Rescue X" location in Python's Locations.py.
function M.scoop_survivors()
    ensure_loaded()
    return (data and data.scoop_survivors) or {}
end

function M.schema_version()
    ensure_loaded()
    return data and data.schema_version or nil
end

-- Derived lookups, built once on first access.
local _scene_by_key_item = nil
local _area_by_name = nil

function M.scene_for_key_item(key_item_name)
    if not _scene_by_key_item then
        _scene_by_key_item = {}
        for _, a in ipairs(M.areas()) do
            if a.key_item and a.scene_code then
                _scene_by_key_item[a.key_item] = a.scene_code
            end
        end
    end
    return _scene_by_key_item[key_item_name]
end

function M.area_by_name(name)
    if not _area_by_name then
        _area_by_name = {}
        for _, a in ipairs(M.areas()) do
            if a.name then _area_by_name[a.name] = a end
        end
    end
    return _area_by_name[name]
end

return M
