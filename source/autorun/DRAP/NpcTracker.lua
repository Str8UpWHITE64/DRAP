-- DRAP/NpcTracker.lua
-- Tracks app.solid.gamemastering.NpcManager.NpcInfoList live state changes
-- and logs when survivors are rescued (enter the safe room).

local Shared = require("DRAP/Shared")

local M = Shared.create_module("SurvivorTracker")
M:set_throttle(0.5)  -- CHECK_INTERVAL

------------------------------------------------------------
-- Configuration
------------------------------------------------------------

local SURVIVOR_JSON_PATH = "survivors.json"

------------------------------------------------------------
-- Live State Enum
------------------------------------------------------------

local LIVE_STATE = {
    UNKNOWN          = 0,
    FOUND            = 1,
    JOIN             = 2,
    ENTER_SAFTY_AREA = 3,
    SAFTY_AREA       = 4,
    RESTRAINT        = 5,
    CONFINE          = 6,
    DEFECT           = 7,
    ESCORT           = 8,
    SLEEP            = 9,
    LOST             = 10,
    RAGE             = 11,
}

local LIVE_STATE_NAMES = {
    [0]  = "UNKNOWN",
    [1]  = "FOUND",
    [2]  = "JOIN",
    [3]  = "ENTER_SAFTY_AREA",
    [4]  = "SAFTY_AREA",
    [5]  = "RESTRAINT",
    [6]  = "CONFINE",
    [7]  = "DEFECT",
    [8]  = "ESCORT",
    [9]  = "SLEEP",
    [10] = "LOST",
    [11] = "RAGE",
}

-- Expose enums
M.LIVE_STATE       = LIVE_STATE
M.LIVE_STATE_NAMES = LIVE_STATE_NAMES

------------------------------------------------------------
-- Singleton Manager
------------------------------------------------------------

local npc_mgr = M:add_singleton("npc", "app.solid.gamemastering.NpcManager")

------------------------------------------------------------
-- Internal State
------------------------------------------------------------

local survivor_defs = {}
local survivor_id_to_name = {}
local survivor_id_to_gameid = {}
local survivor_json_loaded = false

local baseinfo_name_field = nil
local baseinfo_state_field = nil

local survivor_states = {}    -- key: tostring(npc_info) -> last state
local rescued_survivors = {}  -- key: npc_id -> true once rescued

------------------------------------------------------------
-- Public Callback
------------------------------------------------------------

M.on_survivor_rescued = nil

------------------------------------------------------------
-- JSON Loading
------------------------------------------------------------

local function load_survivor_json()
    if survivor_json_loaded then return end

    local file = io.open(SURVIVOR_JSON_PATH, "r")
    if not file then
        M.log("Could not open " .. SURVIVOR_JSON_PATH)
        return
    end

    local text = file:read("*a")
    file:close()

    survivor_defs = {}
    survivor_id_to_name = {}
    survivor_id_to_gameid = {}

    -- Simple JSON parsing
    for obj in text:gmatch("{(.-)}") do
        local name = obj:match('"name"%s*:%s*"(.-)"')
        local game_id = obj:match('"game_id"%s*:%s*"(.-)"')
        local item_num_str = obj:match('"item_number"%s*:%s*(%d+)')
        local item_number = item_num_str and tonumber(item_num_str) or nil

        if name and game_id and item_number then
            table.insert(survivor_defs, {
                name = name,
                game_id = game_id,
                item_number = item_number,
            })

            survivor_id_to_name[item_number] = name
            survivor_id_to_gameid[item_number] = game_id
        end
    end

    M.log(string.format("Loaded %d survivors from %s", #survivor_defs, SURVIVOR_JSON_PATH))
    survivor_json_loaded = true
end

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function survivor_id_to_friendly_name(id)
    if id == nil then return "<nil>" end
    return survivor_id_to_name[id] or tostring(id)
end

--- Gets the game_id for a survivor
--- @param id number The survivor ID
--- @return string|nil The game_id
function M.get_survivor_game_id(id)
    return survivor_id_to_gameid[id]
end

--- Gets the friendly name for a survivor
--- @param id number The survivor ID
--- @return string The friendly name
function M.get_survivor_friendly_name(id)
    return survivor_id_to_friendly_name(id)
end

--- Gets the map of rescued survivors
--- @return table Map of npc_id -> true
function M.get_rescued_survivors()
    return rescued_survivors
end

------------------------------------------------------------
-- BaseInfo Field Access
------------------------------------------------------------

local function ensure_baseinfo_fields(npc_info)
    if baseinfo_name_field and baseinfo_state_field then
        return true
    end

    local td = npc_info:get_type_definition()
    if not td then return false end

    baseinfo_name_field = td:get_field("<Name>k__BackingField")
    baseinfo_state_field = td:get_field("mLiveState")

    if not baseinfo_name_field or not baseinfo_state_field then
        M.log("Failed to find NpcBaseInfo fields")
        return false
    end

    return true
end

------------------------------------------------------------
-- Rescue Detection
------------------------------------------------------------

local function on_survivor_rescued_internal(npc_id, state_index)
    if rescued_survivors[npc_id] then
        return
    end

    rescued_survivors[npc_id] = true

    local friendly = survivor_id_to_friendly_name(npc_id)
    M.log(string.format("%s was rescued!", friendly))

    if M.on_survivor_rescued then
        local game_id = survivor_id_to_gameid[npc_id]
        pcall(M.on_survivor_rescued, npc_id, state_index, friendly, game_id)
    end
end

------------------------------------------------------------
-- Per-frame Update
------------------------------------------------------------

-- Reset state when singleton changes
npc_mgr.on_instance_changed = function(old, new)
    baseinfo_name_field = nil
    baseinfo_state_field = nil
    survivor_states = {}
end

function M.on_frame()
    if not M:should_run() then return end

    local mgr = npc_mgr:get()
    if not mgr then return end

    -- Load survivor JSON once
    if not survivor_json_loaded then
        load_survivor_json()
    end

    -- Get NpcInfoList
    local info_list_field = npc_mgr:get_field("NpcInfoList")
    if not info_list_field then return end

    local info_list = Shared.safe_get_field(mgr, info_list_field)
    if not info_list then return end

    -- Iterate over NPCs
    for i, npc_info in Shared.iter_collection(info_list) do
        if npc_info and ensure_baseinfo_fields(npc_info) then
            -- Get NPC ID
            local ok_name, name_enum = pcall(baseinfo_name_field.get_data, baseinfo_name_field, npc_info)

            local npc_id = nil
            if ok_name and name_enum ~= nil then
                if type(name_enum) == "number" then
                    npc_id = name_enum
                else
                    npc_id = tonumber(tostring(name_enum))
                end
            end

            if npc_id then
                -- Get live state
                local ok_state, state_raw = pcall(baseinfo_state_field.get_data, baseinfo_state_field, npc_info)
                local state_index = (ok_state and state_raw) and (tonumber(state_raw) or 0) or 0

                -- Track state changes
                local key = tostring(npc_info)
                local prev_state = survivor_states[key]

                if prev_state == nil then
                    survivor_states[key] = state_index
                elseif prev_state ~= state_index then
                    survivor_states[key] = state_index

                    -- FOUND / JOIN -> ENTER_SAFTY_AREA / SAFTY_AREA = rescue
                    local is_join_to_safe =
                        (prev_state == LIVE_STATE.JOIN or prev_state == LIVE_STATE.FOUND) and
                        (state_index == LIVE_STATE.ENTER_SAFTY_AREA or state_index == LIVE_STATE.SAFTY_AREA)

                    if is_join_to_safe then
                        on_survivor_rescued_internal(npc_id, state_index)
                    end
                end
            end
        end
    end
end

return M