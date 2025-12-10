-- Dead Rising Deluxe Remaster - Survivor Tracker (module)
-- Tracks app.solid.gamemastering.NpcManager.NpcInfoList live state changes
-- and logs when survivors are rescued (enter the safe room).

local M = {}
M.on_survivor_rescued = nil

------------------------------------------------
-- Logging
------------------------------------------------

local function log(msg)
    print("[SurvivorTracker] " .. tostring(msg))
end2

------------------------------------------------
-- Config
------------------------------------------------

local NpcManager_TYPE_NAME           = "app.solid.gamemastering.NpcManager"
local NPC_INFO_LIST_FIELD_NAME       = "NpcInfoList"

local BASEINFO_NAME_FIELD_NAME       = "<Name>k__BackingField"
local BASEINFO_STATE_FIELD_NAME      = "mLiveState"

local SURVIVOR_JSON_PATH             = "survivors.json" -- autorun/data/survivors.json

local last_check_time = 0
local CHECK_INTERVAL  = 1  -- seconds


------------------------------------------------
-- Live state enum helpers
------------------------------------------------

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

-- States we consider "rescued" for logging / AP purposes
local RESCUED_STATES = {
    [LIVE_STATE.ENTER_SAFTY_AREA] = true,
    [LIVE_STATE.SAFTY_AREA]       = true,
}

-- expose enums
M.LIVE_STATE       = LIVE_STATE
M.LIVE_STATE_NAMES = LIVE_STATE_NAMES

------------------------------------------------
-- Survivor data (from survivors.json)
------------------------------------------------

local survivor_defs          = {}
local survivor_id_to_name    = {}  -- integer SurvivorType ID -> friendly name
local survivor_id_to_gameid  = {}  -- integer SurvivorType ID -> game_id
local survivor_json_loaded   = false

local function load_survivor_json()
    local file = io.open(SURVIVOR_JSON_PATH, "r")
    if not file then
        log("Could not open " .. SURVIVOR_JSON_PATH)
        return
    end

    local text = file:read("*a")
    file:close()

    survivor_defs         = {}
    survivor_id_to_name   = {}
    survivor_id_to_gameid = {}

    -- Parse to JSON
    for obj in text:gmatch("{(.-)}") do
        local name         = obj:match('"name"%s*:%s*"(.-)"')
        local game_id      = obj:match('"game_id"%s*:%s*"(.-)"')
        local item_num_str = obj:match('"item_number"%s*:%s*(%d+)')
        local item_number  = item_num_str and tonumber(item_num_str) or nil

        if name and game_id and item_number then
            table.insert(survivor_defs, {
                name        = name,
                game_id     = game_id,
                item_number = item_number,
            })

            survivor_id_to_name[item_number]   = name
            survivor_id_to_gameid[item_number] = game_id
        end
    end

    log(string.format("Loaded %d survivors from %s", #survivor_defs, SURVIVOR_JSON_PATH))
    survivor_json_loaded = true
end

------------------------------------------------
-- Helpers
------------------------------------------------

local function idx(container, i)
    if container == nil then return nil end

    if container.get_Item ~= nil then
        local ok, v = pcall(function() return container:get_Item(i) end)
        if ok then return v end
    end

    if container.get_element ~= nil then
        local ok, v = pcall(function() return container:get_element(i) end)
        if ok then return v end
    end

    return nil
end

local function get_len(container)
    if container == nil then return 0 end

    if container.get_Length ~= nil then
        local ok, v = pcall(function() return container:get_Length() end)
        if ok then return v end
    end

    if container.get_Count ~= nil then
        local ok, v = pcall(function() return container:get_Count() end)
        if ok then return v end
    end

    if container.get_size ~= nil then
        local ok, v = pcall(function() return container:get_size() end)
        if ok then return v end
    end

    return 0
end

------------------------------------------------
-- Name helper (ID -> friendly name)
------------------------------------------------

local function survivor_id_to_friendly_name(id)
    if id == nil then
        return "<nil>"
    end
    return survivor_id_to_name[id] or tostring(id)
end

-- expose mapping if needed elsewhere
function M.get_survivor_game_id(id)
    return survivor_id_to_gameid[id]
end

------------------------------------------------
-- NpcManager access & cache
------------------------------------------------

local npc_mgr_instance                = nil
local npc_mgr_td                      = nil
local npc_info_list_field             = nil
local baseinfo_name_field             = nil
local baseinfo_state_field            = nil

local survivor_states                 = {}  -- key: tostring(npc_info) -> last state
local rescued_survivors               = {}  -- key: npc_id -> true once rescued
local npc_info_list_missing_warned    = false
local baseinfo_fields_missing_warned  = false

local function reset_npc_cache()
    npc_mgr_td             = nil
    npc_info_list_field    = nil
    baseinfo_name_field    = nil
    baseinfo_state_field   = nil
    survivor_states        = {}
    npc_info_list_missing_warned   = false
    baseinfo_fields_missing_warned = false
end

local function ensure_npc_manager()
    -- Always fetch current singleton each frame
    local current = sdk.get_managed_singleton(NpcManager_TYPE_NAME)

    -- Detect instance changes
    if current ~= npc_mgr_instance then
        if npc_mgr_instance ~= nil and current == nil then
            log("NpcManager destroyed (likely title screen).")
        elseif npc_mgr_instance == nil and current ~= nil then
            log("NpcManager created (likely entering game).")
        elseif npc_mgr_instance ~= nil and current ~= nil then
            log("NpcManager instance changed (scene load?).")
        end

        npc_mgr_instance = current
        reset_npc_cache()
    end

    -- If there is no current NpcManager, nothing to do this frame
    if not npc_mgr_instance then
        return false
    end

    -- Get type definition from the instance
    if not npc_mgr_td then
        npc_mgr_td = npc_mgr_instance:get_type_definition()
        if not npc_mgr_td then
            log("Failed to get NpcManager type definition from instance.")
            return false
        end
    end

    -- Get NpcInfoList field
    if not npc_info_list_field then
        npc_info_list_field = npc_mgr_td:get_field(NPC_INFO_LIST_FIELD_NAME)

        if not npc_info_list_field then
            if not npc_info_list_missing_warned then
                log("NpcInfoList field not found on NpcManager.")
                npc_info_list_missing_warned = true
            end
            return false
        else
            log("Found NpcInfoList field.")
        end
    end

    -- Load survivor JSON once, after we know the game is actually running
    if not survivor_json_loaded then
        load_survivor_json()
    end

    return true
end


------------------------------------------------
-- NpcBaseInfo field helpers
------------------------------------------------

local function ensure_baseinfo_fields(npc_info)
    if baseinfo_name_field and baseinfo_state_field then
        return true
    end

    local td = npc_info:get_type_definition()
    if not td then
        return false
    end

    baseinfo_name_field  = td:get_field(BASEINFO_NAME_FIELD_NAME)
    baseinfo_state_field = td:get_field(BASEINFO_STATE_FIELD_NAME)

    if not baseinfo_name_field or not baseinfo_state_field then
        if not baseinfo_fields_missing_warned then
            log("Failed to find NpcBaseInfo fields: "
                .. BASEINFO_NAME_FIELD_NAME .. " and/or " .. BASEINFO_STATE_FIELD_NAME)
            baseinfo_fields_missing_warned = true
        end
        return false
    end

    return true
end

------------------------------------------------
-- State change / rescue logging
------------------------------------------------

-- Currently unused
local function on_state_change(name, old_state, new_state, npc_id)
    local old_s = LIVE_STATE_NAMES[old_state] or tostring(old_state)
    local new_s = LIVE_STATE_NAMES[new_state] or tostring(new_state)
    log(string.format("%s went from %s to %s.", name, old_s, new_s))
end

local function on_survivor_rescued(npc_id, state_index)
    -- Already rescued before? Don't double-log or double-send
    if rescued_survivors[npc_id] then
        return
    end

    rescued_survivors[npc_id] = true

    local friendly = survivor_id_to_friendly_name(npc_id)
    log(string.format("%s was rescued!", friendly))

    -- AP hook
    if M.on_survivor_rescued then
        local game_id = survivor_id_to_gameid[npc_id]
        pcall(M.on_survivor_rescued, npc_id, state_index, friendly, game_id)
    end
end

-- Optional getter so AP side can inspect who’s been rescued
function M.get_rescued_survivors()
    return rescued_survivors
end


------------------------------------------------
-- Main update entrypoint
------------------------------------------------

function M.on_frame()
    -- Throttle checks to reduce performance impact
    local now = os.clock()
    if now - last_check_time < CHECK_INTERVAL then
        return
    end
    last_check_time = now

    -- Make sure NpcManager + NpcInfoList are available
    if not ensure_npc_manager() then
        return
    end

    local info_list = npc_info_list_field:get_data(npc_mgr_instance)
    if info_list == nil then
        return
    end

    local count = get_len(info_list)
    if count == 0 then
        return
    end

    for i = 0, count - 1 do
        local npc_info = idx(info_list, i)
        if npc_info and ensure_baseinfo_fields(npc_info) then
            -- Survivor ID from BaseInfo name enum / value
            local ok_name, name_enum = pcall(function()
                return baseinfo_name_field:get_data(npc_info)
            end)

            local npc_id = nil
            if ok_name and name_enum ~= nil then
                if type(name_enum) == "number" then
                    npc_id = name_enum
                else
                    npc_id = tonumber(tostring(name_enum))
                end
            end

            if npc_id == nil then
                goto continue
            end

            local survivor_name = survivor_id_to_friendly_name(npc_id)

            -- Live state
            local ok_state, state_raw = pcall(function()
                return baseinfo_state_field:get_data(npc_info)
            end)

            local state_index = 0
            if ok_state and state_raw ~= nil then
                state_index = tonumber(state_raw) or 0
            end

            -- Track and detect state changes
            local key        = tostring(npc_info)
            local prev_state = survivor_states[key]

            if prev_state == nil then
                survivor_states[key] = state_index

            elseif prev_state ~= state_index then
                survivor_states[key] = state_index

                -- FOUND / JOIN -> ENTER_SAFTY_AREA / SAFTY_AREA counts as rescue
                local is_join_to_safe =
                    ((prev_state == LIVE_STATE.JOIN or prev_state == LIVE_STATE.FOUND) and
                     (state_index == LIVE_STATE.ENTER_SAFTY_AREA or
                      state_index == LIVE_STATE.SAFTY_AREA))

                if is_join_to_safe then
                    on_survivor_rescued(npc_id, state_index)
                else
                    -- on_state_change(survivor_name, prev_state, state_index, npc_id)
                end
            end
        end
        ::continue::
    end
end

log("Module loaded. Tracking NpcManager.NpcInfoList live states.")

return M