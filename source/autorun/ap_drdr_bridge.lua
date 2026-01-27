-- ap_drdr_bridge.lua
-- Bridge between Archipelago client and Dead Rising mod

local Shared = require("DRAP/Shared")
local AP_REF = require("AP_REF/core")

local M = Shared.create_module("AP-DRDR-Bridge")

------------------------------------------------------------
-- Data Package
------------------------------------------------------------

local AP_ITEMS_BY_NAME = {}
local AP_LOCATIONS_BY_NAME = {}

AP_REF.on_data_package_changed = function(data_package)
    local ap_game = AP_REF.APClient and AP_REF.APClient:get_game() or AP_REF.APGameName
    local game_pkg = data_package.games[ap_game]

    if not game_pkg then
        M.log("No data package for game: " .. tostring(ap_game))
        return
    end

    AP_ITEMS_BY_NAME = game_pkg.item_name_to_id or {}
    AP_LOCATIONS_BY_NAME = game_pkg.location_name_to_id or {}

    local item_count, loc_count = 0, 0
    for _ in pairs(AP_ITEMS_BY_NAME) do item_count = item_count + 1 end
    for _ in pairs(AP_LOCATIONS_BY_NAME) do loc_count = loc_count + 1 end

    M.log(string.format("Data package loaded: items=%d locations=%d", item_count, loc_count))
end

function M.get_item_id(name) return AP_ITEMS_BY_NAME[name] end
function M.get_location_id(name) return AP_LOCATIONS_BY_NAME[name] end

------------------------------------------------------------
-- Connection Helper
------------------------------------------------------------

local function is_connected()
    if not AP_REF.APClient then return false end
    local st = AP_REF.APClient:get_state()
    return st ~= AP.State.DISCONNECTED
end

function M.is_connected()
    return is_connected()
end

------------------------------------------------------------
-- DeathLink
------------------------------------------------------------

M.deathlink_enabled = false

function M.set_deathlink_enabled(v)
    M.deathlink_enabled = (v == true)
    M.log("DeathLink enabled: " .. tostring(M.deathlink_enabled))
end

local function has_tag(tags, needle)
    if not tags or type(tags) ~= "table" then return false end
    for _, v in pairs(tags) do
        if v == needle then return true end
    end
    return false
end

local function handle_bounced(json_rows)
    if not M.deathlink_enabled then return end
    if not json_rows or type(json_rows) ~= "table" then return end

    if not has_tag(json_rows["tags"], "DeathLink") then return end

    local data = json_rows["data"] or {}
    local source = data["source"] or data["player"] or "Unknown"
    local cause = data["cause"] or ("DeathLink from " .. tostring(source))

    M.log("DeathLink received: " .. tostring(cause))

    if _G.AP and _G.AP.DeathLink and _G.AP.DeathLink.kill_player then
        pcall(_G.AP.DeathLink.kill_player, "DeathLink: " .. tostring(cause))
    else
        M.log("DeathLink received, but AP.DeathLink.kill_player unavailable")
    end
end

function M.send_deathlink(data)
    if not M.deathlink_enabled then return false end
    if not AP_REF.APClient then return false end
    if not is_connected() then return false end

    local time_of_death = math.floor(os.time())
    if AP_REF.APClient.get_server_time then
        local ok, t = pcall(AP_REF.APClient.get_server_time, AP_REF.APClient)
        if ok and t then time_of_death = math.floor(tonumber(t) or os.time()) end
    end

    local my_alias = "DRDR Player"
    if AP_REF.APClient.get_player_alias and AP_REF.APClient.get_slot then
        local ok_slot, slot = pcall(AP_REF.APClient.get_slot, AP_REF.APClient)
        if ok_slot and slot then
            local ok_alias, alias = pcall(AP_REF.APClient.get_player_alias, AP_REF.APClient, slot)
            if ok_alias and alias then my_alias = alias end
        end
    end
    my_alias = tostring((data and data.source) or my_alias)

    local deathLinkData = {
        time = (data and data.time) or time_of_death,
        cause = (data and data.cause) or (my_alias .. " died."),
        source = my_alias
    }

    if type(AP_REF.APClient.Bounce) == "function" then
        local ok, err = pcall(AP_REF.APClient.Bounce, AP_REF.APClient, deathLinkData, nil, nil, { "DeathLink" })
        if ok then
            M.log("Sent DeathLink: " .. tostring(deathLinkData.cause))
            return true
        end
        M.log("DeathLink send failed: " .. tostring(err))
    end

    return false
end

------------------------------------------------------------
-- Bounced Handler
------------------------------------------------------------

local user_on_bounced = nil

function M.set_on_bounced(fn)
    user_on_bounced = fn
end

AP_REF.on_bounced = function(json_rows)
    pcall(handle_bounced, json_rows)
    if user_on_bounced then pcall(user_on_bounced, json_rows) end
end

------------------------------------------------------------
-- Client Binding
------------------------------------------------------------

function M.bind_client()
    if not AP_REF.APClient then return false end

    AP_REF.APClient:set_items_received_handler(function(items)
        if AP_REF.on_items_received then AP_REF.on_items_received(items) end
    end)

    AP_REF.APClient:set_data_package_changed_handler(function(dp)
        if AP_REF.on_data_package_changed then AP_REF.on_data_package_changed(dp) end
    end)

    AP_REF.APClient:set_slot_connected_handler(function(slot_data)
        if AP_REF.on_slot_connected then AP_REF.on_slot_connected(slot_data) end
    end)

    AP_REF.APClient:set_room_info_handler(function()
        if AP_REF.on_room_info then AP_REF.on_room_info() end
    end)

    M.log("Rebound APClient handlers.")
    return true
end

------------------------------------------------------------
-- Location Checks
------------------------------------------------------------

local function resolve_location_id(name)
    if not AP_REF.APClient or not AP_REF.APClient.get_location_id then return nil end
    local ok, id = pcall(AP_REF.APClient.get_location_id, AP_REF.APClient, name, nil)
    if ok then return id end
    return nil
end

function M.check(loc_name)
    M.log("Sending location check: " .. tostring(loc_name))

    if not AP_REF.APClient then
        M.log("APClient is nil")
        return false
    end

    local st = AP_REF.APClient:get_state()
    if AP.State and st == AP.State.DISCONNECTED then
        M.log("Disconnected; cannot send")
        return false
    end

    local loc_id = resolve_location_id(loc_name)
    if not loc_id then
        M.log("Could not resolve location: " .. tostring(loc_name))
        return false
    end

    loc_id = tonumber(loc_id) or loc_id
    local ok, ret = pcall(AP_REF.APClient.LocationChecks, AP_REF.APClient, { loc_id })
    M.log("LocationChecks ok=" .. tostring(ok))
    return ok
end

------------------------------------------------------------
-- Game Item Number Mapping
------------------------------------------------------------

-- Maps item names to their game item numbers (for spawning)
local ITEM_NAME_TO_GAME_NO = {}

--- Registers a mapping from item name to game item number
--- @param item_name string The AP item name
--- @param game_item_no number The game's internal item number
function M.register_game_item_number(item_name, game_item_no)
    ITEM_NAME_TO_GAME_NO[item_name] = game_item_no
end

--- Gets the game item number for an item name
--- @param item_name string The AP item name
--- @return number|nil The game item number or nil
function M.get_game_item_number(item_name)
    return ITEM_NAME_TO_GAME_NO[item_name]
end

------------------------------------------------------------
-- Item Tracking & Persistence
------------------------------------------------------------

local RECEIVED_ITEMS = {}
local RECEIVED_ITEMS_BY_NAME = {}
local last_item_index = -1
local RECEIVED_ITEMS_FILE = nil

local function safe_filename(s)
    s = tostring(s or "unknown")
    s = s:gsub("[^%w%-%._]", "_")
    return s
end

function M.set_received_items_filename(slot_name, seed)
    local slot = safe_filename(slot_name)
    local sd = safe_filename(seed)
    RECEIVED_ITEMS_FILE = string.format("./AP_DRDR_Items/AP_DRDR_items_%s_%s.json", slot, sd)
end

local function rebuild_name_counts()
    RECEIVED_ITEMS_BY_NAME = {}
    for _, it in ipairs(RECEIVED_ITEMS) do
        if it.item_name and it.item_name ~= "" then
            RECEIVED_ITEMS_BY_NAME[it.item_name] = (RECEIVED_ITEMS_BY_NAME[it.item_name] or 0) + 1
        end
    end
end

function M.load_received_items()
    local data = Shared.load_json(RECEIVED_ITEMS_FILE, M.log)
    if not data then
        M.log("No existing received-items file; starting fresh")
        RECEIVED_ITEMS = {}
        RECEIVED_ITEMS_BY_NAME = {}
        last_item_index = -1
        return
    end

    RECEIVED_ITEMS = data.items or {}
    last_item_index = data.last_item_index or -1
    rebuild_name_counts()
end

local function save_received_items()
    local data = { last_item_index = last_item_index, items = RECEIVED_ITEMS }
    Shared.save_json(RECEIVED_ITEMS_FILE, data, 4, M.log)
end

re.on_config_save(save_received_items)
re.on_script_reset(save_received_items)

------------------------------------------------------------
-- Item Check Helpers
------------------------------------------------------------

function M.has_item_name(name)
    return (RECEIVED_ITEMS_BY_NAME[name] or 0) > 0
end

function M.get_all_received_items()
    return RECEIVED_ITEMS
end

------------------------------------------------------------
-- Item Handlers Registry
------------------------------------------------------------

local ITEM_HANDLERS_BY_NAME = {}
local ITEM_HANDLERS_BY_ID = {}

function M.register_item_handler_by_name(name, fn)
    ITEM_HANDLERS_BY_NAME[name] = fn
end

function M.register_item_handler_by_id(id, fn)
    ITEM_HANDLERS_BY_ID[id] = fn
end

function M.default_item_handler(net_item, item_name, sender_name)
    M.log(string.format("Unhandled item id=%s name=%s from %s",
        tostring(net_item.item), tostring(item_name), tostring(sender_name)))
end

------------------------------------------------------------
-- Item Application
------------------------------------------------------------

local function handle_net_item(net_item, is_replay)
    local item_id = net_item.item
    local sender = net_item.player
    local index = net_item.index or -1

    local item_name = AP_REF.APClient:get_item_name(item_id, nil)
    local sender_name = AP_REF.APClient:get_player_alias(sender)

    M.log(string.format("Applying item index=%d id=%d (%s) from %s (replay=%s)",
        index, item_id, tostring(item_name), tostring(sender_name), tostring(is_replay)))

    -- Look up the game item number from our registered mappings
    local game_item_no = ITEM_NAME_TO_GAME_NO[item_name]

    if not is_replay then
        table.insert(RECEIVED_ITEMS, {
            index = index,
            item_id = item_id,
            item_name = item_name,
            sender = sender,
            game_item_no = game_item_no,  -- Store game item number for spawning
        })

        if item_name and item_name ~= "" then
            RECEIVED_ITEMS_BY_NAME[item_name] = (RECEIVED_ITEMS_BY_NAME[item_name] or 0) + 1
        end
    end

    local handler = ITEM_HANDLERS_BY_ID[item_id]
        or (item_name and ITEM_HANDLERS_BY_NAME[item_name])
        or M.default_item_handler

    local ok, err = pcall(handler, net_item, item_name, sender_name)
    if not ok then
        M.log(string.format("Error in handler for id=%d: %s", item_id, tostring(err)))
    end
end

AP_REF.on_items_received = function(items)
    if not items then return end

    for _, net_item in ipairs(items) do
        if net_item.index and net_item.index > last_item_index then
            last_item_index = net_item.index
            handle_net_item(net_item, false)
        end
    end
end

function M.reapply_all_items()
    M.log(string.format("Reapplying %d previously received items...", #RECEIVED_ITEMS))

    for _, entry in ipairs(RECEIVED_ITEMS) do
        local fake_net_item = {
            index = entry.index,
            item = entry.item_id,
            player = entry.sender
        }
        handle_net_item(fake_net_item, true)
    end
end

------------------------------------------------------------
-- Per-frame Update
------------------------------------------------------------

local bound_once = false

function M.on_frame()
    if not bound_once and AP_REF.APClient then
        bound_once = true
        M.bind_client()
    end
end

M.AP_REF = AP_REF
return M