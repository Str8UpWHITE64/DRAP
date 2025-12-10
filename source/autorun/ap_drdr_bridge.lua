-- ap_drdr_bridge.lua
-- Archipelago <-> Dead Rising Deluxe Remaster integration layer.

local AP_REF = require("AP_REF/core")

local M = {}

------------------------------------------------------------
-- Logging helper
------------------------------------------------------------
local function log(msg)
    print("[AP-DRDR] " .. tostring(msg))
end

------------------------------------------------------------
-- Data Package (dynamic item/location tables)
------------------------------------------------------------

local AP_ITEMS_BY_NAME     = {}
local AP_LOCATIONS_BY_NAME = {}

AP_REF.on_data_package_changed = function(data_package)
    local game_pkg = data_package.games[AP_REF.APGameName]
    if not game_pkg then
        log(string.format("[AP-DRDR] No data package for game '%s'", AP_REF.APGameName))
        return
    end

    AP_ITEMS_BY_NAME     = game_pkg.item_name_to_id or {}
    AP_LOCATIONS_BY_NAME = game_pkg.location_name_to_id or {}

    log(string.format(
        "[AP-DRDR] Data package loaded: %d items, %d locations",
        (AP_ITEMS_BY_NAME and #AP_ITEMS_BY_NAME) or 0,
        (AP_LOCATIONS_BY_NAME and #AP_LOCATIONS_BY_NAME) or 0
    ))
end

function M.get_item_id(name)
    return AP_ITEMS_BY_NAME[name]
end

function M.get_location_id(name)
    return AP_LOCATIONS_BY_NAME[name]
end

------------------------------------------------------------
-- Connection helper
------------------------------------------------------------
local function is_connected()
    return AP_REF.APClient
       and AP_REF.APClient:get_state() ~= AP.State.DISCONNECTED
end

------------------------------------------------------------
-- Location checks (by id or by name)
------------------------------------------------------------
function M.check(loc)
    if not is_connected() then
        log("Not connected — cannot send AP check")
        return false
    end

    local loc_id = loc
    if type(loc) == "string" then
        loc_id = AP_LOCATIONS_BY_NAME[loc]
        if not loc_id then
            log("Unknown AP location: " .. loc)
            return false
        end
    end

    AP_REF.APClient:LocationChecks({ loc_id })
    log("Sent AP location check: " .. tostring(loc_id))
    return true
end

------------------------------------------------------------
-- Item handling
------------------------------------------------------------

-- We track the highest item index we've applied so we don't double-apply on reconnect.
local last_item_index = -1

-- Handlers can be registered by *name* or *id*.
-- Name is usually nicer because it comes from your APWorld.
local ITEM_HANDLERS_BY_NAME = {}
local ITEM_HANDLERS_BY_ID   = {}

-- Register handler by AP item name
function M.register_item_handler_by_name(name, fn)
    ITEM_HANDLERS_BY_NAME[name] = fn
end

-- Register handler by AP item numeric id
function M.register_item_handler_by_id(id, fn)
    ITEM_HANDLERS_BY_ID[id] = fn
end

-- Optional: default handler for unhandled items
function M.default_item_handler(net_item, item_name, sender_name)
    log(string.format(
        "Received unhandled item id=%s name=%s from %s",
        tostring(net_item.item),
        tostring(item_name),
        tostring(sender_name)
    ))
end

local function handle_net_item(net_item)
    local item_id = net_item.item
    local sender  = net_item.player

    -- Resolve names for logging / matching
    local sender_game = AP_REF.APClient:get_player_game(sender)
    local item_name   = AP_REF.APClient:get_item_name(item_id, sender_game)
    local sender_name = AP_REF.APClient:get_player_alias(sender)

    log(string.format(
        "Received AP item index=%d id=%d (%s) from %s",
        net_item.index or -1,
        item_id,
        tostring(item_name),
        tostring(sender_name)
    ))

    -- Prefer ID-specific handler, then name-based handler
    local handler = ITEM_HANDLERS_BY_ID[item_id]
                 or (item_name and ITEM_HANDLERS_BY_NAME[item_name])
                 or M.default_item_handler

    local ok, err = pcall(handler, net_item, item_name, sender_name)
    if not ok then
        log(string.format(
            "Error in item handler for id=%d name=%s: %s",
            item_id, tostring(item_name), tostring(err)
        ))
    end
end

AP_REF.on_items_received = function(items)
    if not items then return end

    for _, net_item in ipairs(items) do
        -- Only apply items we haven't processed yet
        if net_item.index and net_item.index > last_item_index then
            last_item_index = net_item.index
            handle_net_item(net_item)
        end
    end
end

------------------------------------------------------------
-- Export
------------------------------------------------------------
M.AP_REF = AP_REF
return M