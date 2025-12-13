-- ap_drdr_bridge.lua
local AP_REF = require("AP_REF/core")

local M = {}

------------------------------------------------------------
-- Logging helper
------------------------------------------------------------
local function sanitize(s)
    s = tostring(s or "")
    s = s:gsub("[%c\128-\255]", ".")
    return s
end

local function log(msg)
    print("[AP-DRDR-Bridge] " .. sanitize(msg))
end


local dumped = false

local function dump_apclient_methods_once()
    if dumped or not AP_REF.APClient then return end
    dumped = true

    log("Dumping APClient methods (metatable __index):")
    local mt = debug.getmetatable(AP_REF.APClient)
    if not mt then
        log("  (no metatable)")
        return
    end

    local idx = mt.__index
    if type(idx) ~= "table" then
        log("  (__index is not a table)")
        return
    end

    local names = {}
    for k, v in pairs(idx) do
        if type(v) == "function" then
            table.insert(names, tostring(k))
        end
    end
    table.sort(names)

    for _, n in ipairs(names) do
        -- keep output readable
        if n:lower():find("data") or n:lower():find("sync") or n:lower():find("package") or n:lower():find("room") then
            log("  " .. n)
        end
    end
end

local function try_call_method(name, ...)
    local fn = AP_REF.APClient and AP_REF.APClient[name]
    if type(fn) ~= "function" then
        print("[AP-DRDR-Bridge] APClient has no method: " .. name)
        return false, nil
    end
    local ok, res = pcall(fn, AP_REF.APClient, ...)
    print(string.format("[AP-DRDR-Bridge] %s() -> ok=%s type=%s",
        name, tostring(ok), tostring(type(res))
    ))
    return ok, res
end

------------------------------------------------------------
-- Data Package
------------------------------------------------------------

local function count_pairs(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end


local AP_ITEMS_BY_NAME     = {}
local AP_LOCATIONS_BY_NAME = {}

AP_REF.on_data_package_changed = function(data_package)
    local ap_game = AP_REF.APClient and AP_REF.APClient:get_game() or AP_REF.APGameName
    local game_pkg = data_package.games[ap_game]
    if not game_pkg then
        log("No data package for game key: " .. tostring(ap_game))
        if data_package and data_package.games then
            for k,_ in pairs(data_package.games) do
                log("  data_package has game: " .. tostring(k))
            end
        end
        return
    end

    log("game_pkg keys:")
    for k, v in pairs(game_pkg) do
        log("?" .. tostring(k) .. " (" .. tostring(type(v)) .. ")")
    end

    -- If there’s a nested "location" table, dump its keys too
    if type(game_pkg.location) == "table" then
        log("game_pkg.location keys:")
        for k, v in pairs(game_pkg.location) do
            log("  location." .. tostring(k) .. " (" .. tostring(type(v)) .. ")")
        end
    end

    if type(game_pkg.locations) == "table" then
        log("game_pkg.locations keys:")
        for k, v in pairs(game_pkg.locations) do
            log("  locations." .. tostring(k) .. " (" .. tostring(type(v)) .. ")")
        end
    end

    AP_ITEMS_BY_NAME     = game_pkg.item_name_to_id or {}
    AP_LOCATIONS_BY_NAME = game_pkg.location_name_to_id or {}

    log(string.format(
        "Data package loaded: items=%d locations=%d",
        count_pairs(AP_ITEMS_BY_NAME),
        count_pairs(AP_LOCATIONS_BY_NAME)
    ))

end

function M.get_item_id(name)     return AP_ITEMS_BY_NAME[name]     end
function M.get_location_id(name) return AP_LOCATIONS_BY_NAME[name] end

------------------------------------------------------------
-- Connection helper
------------------------------------------------------------
local function is_connected()
    if not AP_REF.APClient then return false end
    local st = AP_REF.APClient:get_state()
    return st ~= AP.State.DISCONNECTED
end

-- Rebind APClient handlers to the CURRENT AP_REF.on_* functions
function M.bind_client()
    if not AP_REF.APClient then
        return false
    end

    -- wrap so APClient always calls the *latest* AP_REF handlers
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

    log("Rebound APClient handlers to bridge callbacks.")
    return true
end


------------------------------------------------------------
-- Location checks
------------------------------------------------------------
local function resolve_location_id(name)
    local fn = AP_REF.APClient and AP_REF.APClient.get_location_id
    if type(fn) ~= "function" then return nil end
    local ok, id = pcall(fn, AP_REF.APClient, name, nil)
    if ok then return id end
    return nil
end

function M.check(loc_name)
    log("Attempting to send AP location check for: " .. tostring(loc_name))
    if not AP_REF.APClient then
        log("APClient is nil")
        return false
    end

    local st = AP_REF.APClient:get_state()
    log("APClient state=" .. tostring(st))
    if AP.State and AP.State.DISCONNECTED ~= nil and st == AP.State.DISCONNECTED then
        log("Disconnected; cannot send")
        return false
    end

    local loc_id = resolve_location_id(loc_name)
    if not loc_id then
        log("Could not resolve location id for '" .. tostring(loc_name) .. "'")
        return false
    end

    loc_id = tonumber(loc_id) or loc_id
    log("Resolved loc_id=" .. tostring(loc_id))

    local ok, ret = pcall(AP_REF.APClient.LocationChecks, AP_REF.APClient, { loc_id })
    log("LocationChecks ok=" .. tostring(ok) .. " return=" .. tostring(ret))
    return ok
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

local function safe_filename(s)
    s = tostring(s or "unknown")
    -- keep it filesystem safe
    s = s:gsub("[^%w%-%._]", "_")
    return s
end

 function M.set_received_items_filename(slot_name, seed)
    local slot = safe_filename(slot_name)
    local sd   = safe_filename(seed)
    RECEIVED_ITEMS_FILE = string.format("AP_DRDR_items_%s_%s.json", slot, sd)
    log("Using received-items file: " .. RECEIVED_ITEMS_FILE)
end

local function reset_received_items_state()
    RECEIVED_ITEMS = {}
    RECEIVED_ITEMS_BY_NAME = {}
    last_item_index = -1
end

local function rebuild_name_counts()
    RECEIVED_ITEMS_BY_NAME = {}
    for _, it in ipairs(RECEIVED_ITEMS) do
        if it.item_name and it.item_name ~= "" then
            RECEIVED_ITEMS_BY_NAME[it.item_name] =
                (RECEIVED_ITEMS_BY_NAME[it.item_name] or 0) + 1
        end
    end
end

function M.load_received_items()
    local data = json.load_file(RECEIVED_ITEMS_FILE)
    if not data then
        log("No existing received-items file; starting fresh: " .. tostring(RECEIVED_ITEMS_FILE))
        reset_received_items_state()
        return
    end

    RECEIVED_ITEMS  = data.items or {}
    last_item_index = data.last_item_index or -1
    rebuild_name_counts()

    log(string.format(
        "Loaded received-items file '%s': %d items, last_index=%d",
        tostring(RECEIVED_ITEMS_FILE),
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

    local item_name = AP_REF.APClient:get_item_name(item_id, nil)
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

local bound_once = false

function M.on_frame()
    if not bound_once and AP_REF.APClient then
        bound_once = true
        M.bind_client()
    end
end

M.AP_REF = AP_REF
return M
