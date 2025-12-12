-- ap_drdr_bridge.lua
local AP_REF = require("AP_REF/core")

local M = {}

------------------------------------------------------------
-- Logging helper
------------------------------------------------------------
local function log(msg)
    print("[AP-DRDR] " .. tostring(msg))
end

------------------------------------------------------------
-- Data Package (unchanged from before)
------------------------------------------------------------

local AP_ITEMS_BY_NAME     = {}
local AP_LOCATIONS_BY_NAME = {}

AP_REF.on_data_package_changed = function(data_package)
    local game_pkg = data_package.games[AP_REF.APGameName]
    if not game_pkg then
        log(string.format("No data package for game '%s'", AP_REF.APGameName))
        return
    end

    AP_ITEMS_BY_NAME     = game_pkg.item_name_to_id or {}
    AP_LOCATIONS_BY_NAME = game_pkg.location_name_to_id or {}

    log(string.format(
        "Data package loaded: items=%d locations=%d",
        (AP_ITEMS_BY_NAME and #AP_ITEMS_BY_NAME) or 0,
        (AP_LOCATIONS_BY_NAME and #AP_LOCATIONS_BY_NAME) or 0
    ))
end

function M.get_item_id(name)     return AP_ITEMS_BY_NAME[name]     end
function M.get_location_id(name) return AP_LOCATIONS_BY_NAME[name] end

------------------------------------------------------------
-- Connection helper
------------------------------------------------------------
local function is_connected()
    return AP_REF.APClient
       and AP_REF.APClient:get_state() ~= AP.State.DISCONNECTED
end

------------------------------------------------------------
-- Location checks
------------------------------------------------------------
function M.check(loc)
    if not is_connected() then
        log("Not connected -> cannot send AP check")
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
-- Item tracking + persistence
------------------------------------------------------------

-- File to persist received items between sessions
local RECEIVED_ITEMS_FILE = "AP_DRDR_items.json"

-- list of { index, item_id, item_name, sender, flags }
local RECEIVED_ITEMS        = {}
-- name -> count
local RECEIVED_ITEMS_BY_NAME = {}
-- highest AP index we've processed
local last_item_index = -1

local function rebuild_name_counts()
    RECEIVED_ITEMS_BY_NAME = {}
    for _, it in ipairs(RECEIVED_ITEMS) do
        if it.item_name and it.item_name ~= "" then
            RECEIVED_ITEMS_BY_NAME[it.item_name] =
                (RECEIVED_ITEMS_BY_NAME[it.item_name] or 0) + 1
        end
    end
end

local function load_received_items()
    local data = json.load_file(RECEIVED_ITEMS_FILE)
    if not data then
        log("No existing received-items file; starting fresh.")
        return
    end

    RECEIVED_ITEMS   = data.items or {}
    last_item_index  = data.last_item_index or -1
    rebuild_name_counts()

    log(string.format(
        "Loaded received-items file: %d items, last_index=%d",
        #RECEIVED_ITEMS, last_item_index
    ))
end

local function save_received_items()
    local data = {
        last_item_index = last_item_index,
        items           = RECEIVED_ITEMS
    }
    if not json.dump_file(RECEIVED_ITEMS_FILE, data, 4) then
        log("Failed to save received-items file.")
    else
        log("Saved received-items file.")
    end
end

-- Call at script load
load_received_items()

-- Save when config is saved / script resets
re.on_config_save(function()
    save_received_items()
end)

re.on_script_reset(function()
    save_received_items()
end)

------------------------------------------------------------
-- Public helpers for “have we ever gotten X?”
------------------------------------------------------------

function M.has_item_name(name)
    return (RECEIVED_ITEMS_BY_NAME[name] or 0) > 0
end

-- Optional: expose all items if you need them
function M.get_all_received_items()
    return RECEIVED_ITEMS
end

------------------------------------------------------------
-- Item handlers registry
------------------------------------------------------------

local ITEM_HANDLERS_BY_NAME = {}
local ITEM_HANDLERS_BY_ID   = {}

function M.register_item_handler_by_name(name, fn)
    ITEM_HANDLERS_BY_NAME[name] = fn
end

function M.register_item_handler_by_id(id, fn)
    ITEM_HANDLERS_BY_ID[id] = fn
end

function M.default_item_handler(net_item, item_name, sender_name)
    log(string.format(
        "Received unhandled item id=%s name=%s from %s",
        tostring(net_item.item),
        tostring(item_name),
        tostring(sender_name)
    ))
end

------------------------------------------------------------
-- Core: apply a single item
-- is_replay = true when reapplying for a new save (so we don't re-store)
------------------------------------------------------------
local function handle_net_item(net_item, is_replay)
    local item_id = net_item.item
    local sender  = net_item.player

    local sender_game = AP_REF.APClient:get_player_game(sender)
    local item_name   = AP_REF.APClient:get_item_name(item_id, sender_game)
    local sender_name = AP_REF.APClient:get_player_alias(sender)
    local index       = net_item.index or -1

    log(string.format(
        "Applying AP item index=%d id=%d (%s) from %s (replay=%s)",
        index, item_id, tostring(item_name), tostring(sender_name), tostring(is_replay)
    ))

    -- Store only for *new* items
    if not is_replay then
        local entry = {
            index     = index,
            item_id   = item_id,
            item_name = item_name,
            sender    = sender,
        }
        table.insert(RECEIVED_ITEMS, entry)

        if item_name and item_name ~= "" then
            RECEIVED_ITEMS_BY_NAME[item_name] =
                (RECEIVED_ITEMS_BY_NAME[item_name] or 0) + 1
        end
    end

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

------------------------------------------------------------
-- AP callback: new items from server
------------------------------------------------------------
AP_REF.on_items_received = function(items)
    if not items then return end

    for _, net_item in ipairs(items) do
        if net_item.index and net_item.index > last_item_index then
            last_item_index = net_item.index
            handle_net_item(net_item, false)
        end
    end
end

------------------------------------------------------------
-- Reapply all items we’ve ever gotten
-- (for starting a new save while keeping AP progression)
------------------------------------------------------------
function M.reapply_all_items()
    log(string.format(
        "Reapplying %d previously received AP items...",
        #RECEIVED_ITEMS
    ))

    for _, entry in ipairs(RECEIVED_ITEMS) do
        local fake_net_item = {
            index  = entry.index,
            item   = entry.item_id,
            player = entry.sender
        }
        -- true = replay, don’t re-store in RECEIVED_ITEMS
        handle_net_item(fake_net_item, true)
    end
end

M.AP_REF = AP_REF
return M
