-- DRAP/ItemSpawner.lua
-- Gives items via Inventory.setEventItem with a queued, slot-aware system + safe backoff.

local Shared = require("DRAP/Shared")

local M = Shared.create_module("ItemSpawner")
M:set_throttle(0.25)  -- CHECK_INTERVAL

------------------------------------------------------------
-- Configuration / Tunables
------------------------------------------------------------

local SUCCESS_COOLDOWN     = 0.35     -- delay after a successful spawn
local BASE_FAIL_COOLDOWN   = 0.75     -- initial delay after a failed spawn
local FAIL_BACKOFF_MULT    = 1.8      -- exponential backoff multiplier
local MAX_FAIL_COOLDOWN    = 10.0     -- cap backoff
local MAX_RETRIES_PER_ITEM = 8        -- after this, drop the item

------------------------------------------------------------
-- Singleton Manager
------------------------------------------------------------

local ps_mgr = M:add_singleton("ps", "app.solid.PlayerStatusManager")

------------------------------------------------------------
-- Internal State
------------------------------------------------------------

local inv_instance = nil
local inv_td = nil
local set_event_method = nil
local current_items_field = nil
local max_slot_field = nil

local pending_items = {}       -- Queue: { item_no, retries, not_before }
local is_processing = false
local global_not_before = 0.0

------------------------------------------------------------
-- Queue Management
------------------------------------------------------------

local function now_time()
    return os.clock()
end

local function enqueue_item(item_no)
    pending_items[#pending_items + 1] = { item_no = item_no, retries = 0, not_before = 0.0 }
end

local function pending_count()
    return #pending_items
end

local function peek_item()
    return pending_items[1]
end

local function pop_item()
    if #pending_items == 0 then return nil end
    local e = pending_items[1]
    table.remove(pending_items, 1)
    return e
end

local function push_front(e)
    table.insert(pending_items, 1, e)
end

------------------------------------------------------------
-- Inventory Access
------------------------------------------------------------

local function reset_inv_cache()
    inv_instance = nil
    inv_td = nil
    set_event_method = nil
    current_items_field = nil
    max_slot_field = nil
end

local function ensure_inventory()
    local ps = ps_mgr:get()
    if not ps then
        reset_inv_cache()
        return false
    end

    local inv_field = ps_mgr:get_field("PlayerInventory")
    if not inv_field then
        return false
    end

    -- Always re-read inventory instance (can change during loads)
    local current_inv = Shared.safe_get_field(ps, inv_field)

    if current_inv ~= inv_instance then
        if inv_instance ~= nil and current_inv == nil then
            M.log("PlayerInventory became nil (leaving gameplay?).")
        elseif inv_instance == nil and current_inv ~= nil then
            M.log("PlayerInventory became available.")
        elseif inv_instance ~= nil and current_inv ~= nil then
            M.log("PlayerInventory instance changed (scene load / save load).")
        end

        reset_inv_cache()
        inv_instance = current_inv

        -- Give a short global cooldown after inventory swap
        global_not_before = math.max(global_not_before, now_time() + 1.5)
    end

    if not inv_instance then
        return false
    end

    -- Get type definition
    if not inv_td then
        local ok, td = pcall(inv_instance.get_type_definition, inv_instance)
        if not ok or not td then
            M.log("Failed to get Inventory type definition from instance.")
            return false
        end
        inv_td = td
    end

    -- Get setEventItem method
    if not set_event_method then
        set_event_method = inv_td:get_method("setEventItem")
        if not set_event_method then
            M.log("Inventory.setEventItem method not found.")
            return false
        end
    end

    return true
end

--- Checks if the inventory system is running
--- @return boolean True if inventory is available
function M.inventory_system_running()
    return ensure_inventory()
end

------------------------------------------------------------
-- Capacity Helpers
------------------------------------------------------------

local function ensure_capacity_fields()
    if not inv_td then return false end

    if not current_items_field then
        current_items_field = inv_td:get_field("<CurrentItemNumbers>k__BackingField")
    end
    if not max_slot_field then
        max_slot_field = inv_td:get_field("<CurrentMaxSlot>k__BackingField")
    end

    return current_items_field ~= nil and max_slot_field ~= nil
end

local function get_inventory_counts()
    if not ensure_capacity_fields() then
        return nil, nil
    end

    local ok_curr, current = pcall(current_items_field.get_data, current_items_field, inv_instance)
    local ok_max, maxv = pcall(max_slot_field.get_data, max_slot_field, inv_instance)

    if not ok_curr or not ok_max then
        return nil, nil
    end

    return current, maxv
end

local function can_accept_more_items()
    local current, maxv = get_inventory_counts()
    if current == nil or maxv == nil then
        return false
    end
    return current < maxv
end

------------------------------------------------------------
-- Process Queue
------------------------------------------------------------

local function process_pending_items()
    if is_processing then return end
    if pending_count() == 0 then return end

    local t = now_time()
    if t < global_not_before then return end

    if not ensure_inventory() then return end

    -- Optional "don't spawn before time loads" gate
    if AP and AP.TimeGate and AP.TimeGate.get_current_mdate then
        local ok_tg, mdate = pcall(AP.TimeGate.get_current_mdate)
        if ok_tg and mdate and mdate <= 11200 then
            return
        end
    end

    if not can_accept_more_items() then return end

    local entry = peek_item()
    if not entry then return end

    if t < (entry.not_before or 0.0) then return end

    -- Only pop when we are about to attempt
    entry = pop_item()
    if not entry then return end

    is_processing = true

    M.log(string.format(
        "Processing queued item: ItemNo=%d (queue=%d retries=%d)",
        entry.item_no, pending_count(), entry.retries
    ))

    local ok, err = pcall(function()
        set_event_method:call(inv_instance, entry.item_no, false)
    end)

    if ok then
        M.log("setEventItem succeeded for ItemNo=" .. tostring(entry.item_no))
        global_not_before = now_time() + SUCCESS_COOLDOWN
    else
        local err_s = tostring(err)
        M.log("setEventItem FAILED for ItemNo=" .. tostring(entry.item_no) .. " error: " .. err_s)

        -- Backoff & retry
        entry.retries = (entry.retries or 0) + 1
        if entry.retries > MAX_RETRIES_PER_ITEM then
            M.log("Dropping ItemNo=" .. tostring(entry.item_no) .. " after " .. tostring(entry.retries) .. " retries.")
        else
            local cool = BASE_FAIL_COOLDOWN * (FAIL_BACKOFF_MULT ^ (entry.retries - 1))
            if cool > MAX_FAIL_COOLDOWN then cool = MAX_FAIL_COOLDOWN end

            entry.not_before = now_time() + cool
            push_front(entry)

            global_not_before = math.max(global_not_before, now_time() + math.min(cool, 2.0))
        end
    end

    is_processing = false
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

--- Queues an item to be spawned
--- @param item_no number|string The item number
function M.spawn(item_no)
    if type(item_no) ~= "number" then
        local as_num = tonumber(item_no)
        if not as_num then
            M.log("spawn: item_no must be a number or numeric string, got: " .. tostring(item_no))
            return
        end
        item_no = as_num
    end

    enqueue_item(item_no)
    M.log(string.format("spawn: queued ItemNo=%d (queue size now %d)", item_no, pending_count()))
end

--- Gets the current pending item count
--- @return number The count
function M.pending_count()
    return pending_count()
end

------------------------------------------------------------
-- Per-frame Update
------------------------------------------------------------

function M.on_frame()
    if not M:should_run() then return end

    ensure_inventory()
    process_pending_items()
end

return M