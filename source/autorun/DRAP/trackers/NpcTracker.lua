-- DRAP/trackers/NpcTracker.lua
-- Tracks app.solid.gamemastering.NpcManager.NpcInfoList live state changes
-- and logs when survivors are rescued (enter the Security Room).

local Shared = require("DRAP/Shared")
local SharedData = require("DRAP/SharedData")

local M = Shared.create_module("NpcTracker")
M:set_throttle(0.5)  -- CHECK_INTERVAL

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
local survivor_name_to_id = {}
local survivor_json_loaded = false

local baseinfo_name_field = nil
local baseinfo_state_field = nil
local baseinfo_vital_field = nil

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

    local rows = SharedData.survivors()
    if type(rows) ~= "table" or #rows == 0 then
        M.log("SharedData.survivors() returned empty or invalid data")
        return
    end

    survivor_defs = {}
    survivor_id_to_name = {}
    survivor_id_to_gameid = {}
    survivor_name_to_id = {}

    for _, row in ipairs(rows) do
        local name = row.name
        local game_id = row.game_id
        local item_number = tonumber(row.item_number)

        if name and game_id and item_number then
            table.insert(survivor_defs, {
                name = name,
                game_id = game_id,
                item_number = item_number,
            })

            survivor_id_to_name[item_number] = name
            survivor_id_to_gameid[item_number] = game_id
            -- First wins: a few names repeat across scene variants (Isabela,
            -- Brad), and no scoop survivor is among them.
            if survivor_name_to_id[name] == nil then
                survivor_name_to_id[name] = item_number
            end
        end
    end

    M.log(string.format("Loaded %d survivors from SharedData", #survivor_defs))
    survivor_json_loaded = true
end

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function friendly_name_to_survivor_id(name)
    if name == nil then return nil end
    if not survivor_json_loaded then load_survivor_json() end
    return survivor_name_to_id[name]
end

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
    -- Optional: a missing hp field must not stop rescue tracking, so this
    -- one is deliberately not part of the check below.
    baseinfo_vital_field = td:get_field("mVitalNew")

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
-- Death Detection
------------------------------------------------------------
-- mLiveState is NOT a liveness signal: a corpse keeps whatever state it died
-- with. Measured on a real kill -- hp went 3500 to 0 and isDead went true,
-- while mLiveState stayed on JOIN for the rest of the run. Liveness is hp and
-- isDead, nothing else.
--
-- A death is only believed for someone seen alive first. Half-initialised
-- records read hp=0/isDead=true before they properly spawn, and calling a
-- living survivor dead is the expensive mistake: it strips their mission box
-- with no way to get it back.

local seen_alive = {}   -- npc_id -> true once observed alive
local dead_now = {}     -- npc_id -> true, was alive and is now dead

local function record_is_alive(npc_info)
    local dead = nil
    pcall(function() dead = npc_info:call("isDead") end)
    if dead == true then return false end
    if baseinfo_vital_field then
        local ok, hp = pcall(baseinfo_vital_field.get_data, baseinfo_vital_field,
                             npc_info)
        if ok and hp ~= nil then return (tonumber(hp) or 0) > 0 end
    end
    -- Nothing readable said otherwise, so treat as alive: erring toward alive
    -- keeps an odd record from failing someone's scoop.
    return true
end

-- Folded once per tick, after every record for the id has been seen: a stype
-- can hold more than one record, and one live record means they are alive
-- whatever the others say.
local function fold_liveness(npc_id, any_alive)
    if any_alive then
        seen_alive[npc_id] = true
        if dead_now[npc_id] then
            dead_now[npc_id] = nil
            M.log(string.format("%s is alive again -- death retracted",
                survivor_id_to_friendly_name(npc_id)))
        end
    elseif seen_alive[npc_id] and not dead_now[npc_id] then
        dead_now[npc_id] = true
        M.log(string.format("%s died", survivor_id_to_friendly_name(npc_id)))
        if M.on_survivor_died then
            pcall(M.on_survivor_died, npc_id,
                  survivor_id_to_friendly_name(npc_id))
        end
    end
end

--- Accepts a friendly name or a numeric survivor type.
function M.is_survivor_dead(name_or_id)
    local id = tonumber(name_or_id) or friendly_name_to_survivor_id(name_or_id)
    if not id then return false end
    return dead_now[id] == true
end

function M.get_dead_survivors()
    local out = {}
    for id in pairs(dead_now) do
        table.insert(out, survivor_id_to_friendly_name(id))
    end
    table.sort(out)
    return out
end

------------------------------------------------------------
-- Per-frame Update
------------------------------------------------------------

-- Reset state when singleton changes
npc_mgr.on_instance_changed = function(old, new)
    baseinfo_name_field = nil
    baseinfo_state_field = nil
    baseinfo_vital_field = nil
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
    local alive_this_tick = {}
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

                -- NPC is in the Security Room -> count as rescued
                if state_index == LIVE_STATE.ENTER_SAFTY_AREA or state_index == LIVE_STATE.SAFTY_AREA then
                    on_survivor_rescued_internal(npc_id, state_index)
                end

                alive_this_tick[npc_id] = (alive_this_tick[npc_id] or false)
                    or record_is_alive(npc_info)
            end
        end
    end

    for npc_id, any_alive in pairs(alive_this_tick) do
        fold_liveness(npc_id, any_alive)
    end
end

return M