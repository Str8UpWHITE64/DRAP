-- Dead Rising Deluxe Remaster - Survivor LiveState tracker

local NPC_MANAGER_TNAME   = "app.solid.gamemastering.NpcManager"
local NPC_INFO_LIST_FIELD = "NpcInfoList"

local BASEINFO_NAME_FIELD  = "<Name>k__BackingField"
local BASEINFO_STATE_FIELD = "mLiveState"

local survivor_defs = {}
local survivor_id_to_gameid = {}  -- integer ID -> game_id
local survivor_id_to_name   = {}  -- integer ID -> friendly name

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

local RESCUED_STATES = {
    [LIVE_STATE.ENTER_SAFTY_AREA] = true,
    [LIVE_STATE.SAFTY_AREA]       = true,
}

local function log(msg)
    print("[SurvivorTracker] " .. msg)
end

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
    return 0
end

local function enum_to_name(enum_val)
    if type(enum_val) == "number" then
        return survivor_id_to_name[enum_val] or tostring(enum_val)
    end

    local as_num = tonumber(tostring(enum_val))
    return survivor_id_to_name[as_num] or tostring(as_num)
end

--------------------------------------------------
-- Survivor JSON loading
--------------------------------------------------

local SURVIVOR_DATA_PATH = "survivors.json"

local function load_survivor_json()
    local file = io.open(SURVIVOR_DATA_PATH, "r")
    if not file then
        log("Could not open " .. SURVIVOR_DATA_PATH)
        return
    end

    local text = file:read("*a")
    file:close()

    survivor_defs = {}
    survivor_id_to_gameid = {}
    survivor_id_to_name   = {}

    -- Very simple parser: find each {...} object in the array
    for obj in text:gmatch("{(.-)}") do
        local name          = obj:match('"name"%s*:%s*"(.-)"')
        local game_id       = obj:match('"game_id"%s*:%s*"(.-)"')
        local item_num_str  = obj:match('"item_number"%s*:%s*(%d+)')
        local item_number   = item_num_str and tonumber(item_num_str) or nil

        if name and game_id and item_number then
            table.insert(survivor_defs, {
                name        = name,
                game_id     = game_id,
                item_number = item_number,
            })

            survivor_id_to_gameid[item_number] = game_id
            survivor_id_to_name[item_number]   = name
        end
    end

    log("Loaded " .. tostring(#survivor_defs) .. " survivors from " .. SURVIVOR_DATA_PATH)
end
--------------------------------------------------
-- Cached type info
--------------------------------------------------

local npc_manager
local info_list_field
local baseinfo_name_field
local baseinfo_state_field
local survivor_states = {}

local npc_init_success = false
local npc_init_logged_nil = false

local function ensure_fields()

    if npc_init_success then
        return true
    end

    -- Try to grab the singleton every frame until it exists
    npc_manager = sdk.get_managed_singleton(NPC_MANAGER_TNAME)
    if npc_manager == nil then
        if not npc_init_logged_nil then
            log("NpcManager singleton is nil, waiting for it to be created...")
            npc_init_logged_nil = true
        end
        return false
    end

    local mgr_td = npc_manager:get_type_definition()
    if mgr_td == nil then
        -- This is unlikely to be transient; log once and keep trying
        log("Failed to get NpcManager type definition")
        return false
    end

    info_list_field = mgr_td:get_field(NPC_INFO_LIST_FIELD)
    if info_list_field == nil then
        log("Failed to find NpcInfoList field on NpcManager (" .. NPC_INFO_LIST_FIELD .. ")")
        return false
    end

    -- BaseInfo fields are resolved lazily from the first NpcBaseInfo we see
    baseinfo_name_field  = nil
    baseinfo_state_field = nil

    npc_init_success = true
    log("NpcManager + NpcInfoList initialized")

    -- Load survivor JSON when the manager is ready
    if not _G.__survivor_json_loaded then
        load_survivor_json()
        _G.__survivor_json_loaded = true
    end

    return true
end


local function ensure_baseinfo_fields(npc_info)
    if baseinfo_name_field ~= nil and baseinfo_state_field ~= nil then
        return true
    end

    local td = npc_info:get_type_definition()
    if td == nil then
        return false
    end

    baseinfo_name_field  = td:get_field(BASEINFO_NAME_FIELD)
    baseinfo_state_field = td:get_field(BASEINFO_STATE_FIELD)

    if baseinfo_name_field == nil then
        log("BaseInfo name field not found: " .. BASEINFO_NAME_FIELD)
        return false
    end
    if baseinfo_state_field == nil then
        log("BaseInfo state field not found: " .. BASEINFO_STATE_FIELD)
        return false
    end

    return true
end

--------------------------------------------------
-- Event handlers
--------------------------------------------------

local function on_survivor_rescued(npc_id, state_index)
    local friendly = survivor_id_to_name[npc_id] or ("ID " .. tostring(npc_id))
    log(string.format("%s was rescued!", friendly))

    -- Archipelago hook:
    -- ap_send_location(survivor_id_to_gameid[npc_id])
end

local function on_state_change(name, old_state, new_state)
    local old_s = LIVE_STATE_NAMES[old_state] or tostring(old_state)
    local new_s = LIVE_STATE_NAMES[new_state] or tostring(new_state)

    log(string.format("%s went from %s to %s.", name, old_s, new_s))
end


--------------------------------------------------
-- Main update loop
--------------------------------------------------

re.on_frame(function()
    if not ensure_fields() then
        return
    end

    local info_list = info_list_field:get_data(npc_manager)
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

            -- Read survivor type / ID
            local ok_name, name_enum = pcall(function()
                return baseinfo_name_field:get_data(npc_info)
            end)

            local npc_id = nil
            if ok_name and name_enum ~= nil then
                npc_id = tonumber(name_enum) or tonumber(tostring(name_enum))
            end

            if npc_id == nil then
                goto continue
            end

            -- Friendly name from JSON
            local name_str = enum_to_name(npc_id)

            -- Read NPC state
            local ok_state, state_raw = pcall(function()
                return baseinfo_state_field:get_data(npc_info)
            end)

            local state_index = ok_state and tonumber(state_raw) or 0

            -- State tracking
            local key = tostring(npc_info)
            local prev_state = survivor_states[key]

            if prev_state == nil then
                survivor_states[key] = state_index

            elseif prev_state ~= state_index then
                survivor_states[key] = state_index

                on_state_change(name_str, prev_state, state_index)

                local was_rescued = RESCUED_STATES[prev_state]
                local now_rescued = RESCUED_STATES[state_index]

                if (not was_rescued) and now_rescued then
                    on_survivor_rescued(npc_id, state_index)
                end
            end
        end
        ::continue::
    end
end)
