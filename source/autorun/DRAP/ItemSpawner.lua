-- Dead Rising Deluxe Remaster - Item Spawner (module)
-- Gives items via Inventory.setEventItem with a queued, slot-aware system.

local M = {}

------------------------------------------------
-- Logging
------------------------------------------------

local function log(msg)
    print("[ItemSpawner] " .. tostring(msg))
end


------------------------------------------------
-- Type names / constants
------------------------------------------------

local StatusManager_TYPE_NAME = "app.solid.PlayerStatusManager"
local Inventory_TYPE_NAME     = "app.solid.character.player.Inventory"

------------------------------------------------
-- Cached state
------------------------------------------------

local ps_instance            = nil  -- current PlayerStatusManager singleton
local ps_td                  = nil  -- PlayerStatusManager type definition
local inv_field              = nil  -- PlayerInventory field on PlayerStatusManager
local missing_inv_warned     = false

local inv_instance           = nil  -- app.solid.character.player.Inventory instance
local inv_td                 = nil  -- Inventory type definition

local set_event_method       = nil  -- Inventory.setEventItem(app.MTData.ITEM_NO, bool)
local missing_method_warned  = false

local current_items_field    = nil  -- <CurrentItemNumbers>k__BackingField
local max_slot_field         = nil  -- <CurrentMaxSlot>k__BackingField
local capacity_warned        = false

-- Simple FIFO queue of pending ItemNos
local pending_items          = {}   -- { item_no1, item_no2, ... }

------------------------------------------------
-- Helpers
------------------------------------------------

local function reset_ps_cache()
    ps_td                  = nil
    inv_field              = nil
    missing_inv_warned     = false

    inv_instance           = nil
    inv_td                 = nil

    set_event_method       = nil
    missing_method_warned  = false

    current_items_field    = nil
    max_slot_field         = nil
    capacity_warned        = false

    --pending_items          = {}
end

local function enqueue_item(item_no)
    pending_items[#pending_items + 1] = item_no
end

local function dequeue_item()
    if #pending_items == 0 then
        return nil
    end
    local item_no = pending_items[1]
    table.remove(pending_items, 1)
    return item_no
end

local function pending_count()
    return #pending_items
end

------------------------------------------------
-- Ensure PlayerStatusManager + PlayerInventory
------------------------------------------------

local function ensure_player_status_manager()
    -- Always fetch the current singleton each frame / call
    local current = sdk.get_managed_singleton(StatusManager_TYPE_NAME)

    -- Detect instance changes (destroyed / recreated)
    if current ~= ps_instance then
        if ps_instance ~= nil and current == nil then
            log("PlayerStatusManager destroyed (likely title screen).")
        elseif ps_instance == nil and current ~= nil then
            log("PlayerStatusManager created (likely entering game).")
        elseif ps_instance ~= nil and current ~= nil then
            log("PlayerStatusManager instance changed (scene load?).")
        end

        ps_instance = current
        reset_ps_cache()
    end

    if not ps_instance then
        return false
    end

    -- Get type definition from the instance
    if not ps_td then
        ps_td = ps_instance:get_type_definition()
        if not ps_td then
            log("Failed to get PlayerStatusManager type definition from instance.")
            return false
        end
    end

    -- Get PlayerInventory field
    if not inv_field then
        inv_field = ps_td:get_field("PlayerInventory")

        if not inv_field then
            if not missing_inv_warned then
                log("PlayerInventory field not found on PlayerStatusManager (likely title screen or wrong context).")
                missing_inv_warned = true
            end
            return false
        end
    end

    return true
end

local function ensure_inventory()
    if not ensure_player_status_manager() then
        return false
    end

    -- Get Inventory instance from PlayerStatusManager
    if not inv_instance then
        inv_instance = inv_field:get_data(ps_instance)
        if not inv_instance then
            if not missing_inv_warned then
                log("PlayerInventory instance is nil (not in gameplay yet?).")
                missing_inv_warned = true
            end
            return false
        end
    end

    -- Get Inventory type definition
    if not inv_td then
        inv_td = inv_instance:get_type_definition()
        if not inv_td then
            log("Failed to get Inventory type definition from instance.")
            return false
        end
    end

    -- Get setEventItem(app.MTData.ITEM_NO, System.Boolean)
    if not set_event_method then
        set_event_method = inv_td:get_method("setEventItem")
        if not set_event_method then
            if not missing_method_warned then
                log("Inventory.setEventItem method not found.")
                missing_method_warned = true
            end
            return false
        end
    end

    return true
end

function M.inventory_system_running()
    return ensure_inventory()
end
------------------------------------------------
-- Inventory capacity helpers
------------------------------------------------

local function ensure_capacity_fields()
    if not inv_td then
        return false
    end

    if not current_items_field then
        current_items_field = inv_td:get_field("<CurrentItemNumbers>k__BackingField")
    end
    if not max_slot_field then
        max_slot_field = inv_td:get_field("<CurrentMaxSlot>k__BackingField")
    end

    if (not current_items_field) or (not max_slot_field) then
        if not capacity_warned then
            log("Could not find CurrentItemNumbers/CurrentMaxSlot fields on Inventory.")
            capacity_warned = true
        end
        return false
    end

    return true
end

local function get_inventory_counts()
    if not ensure_capacity_fields() then
        return nil, nil
    end

    local ok_curr, current = pcall(current_items_field.get_data, current_items_field, inv_instance)
    local ok_max, max     = pcall(max_slot_field.get_data, max_slot_field, inv_instance)

    if not ok_curr or not ok_max then
        return nil, nil
    end

    return current, max
end

local function can_accept_more_items()
    local current, max = get_inventory_counts()
    if not current or not max then
        return false
    end
    return current < max
end

------------------------------------------------
-- Process queue
------------------------------------------------
local current_time = nil
local function process_pending_items()
    if pending_count() == 0 then
        return
    end

    if not ensure_inventory() then
        return
    end

    current_time = AP.TimeGate.get_current_time()

    if current_time <= 43200 then
        return
    end

    if not can_accept_more_items() then
        -- Inventory full; wait until a slot opens.
        return
    end

    -- For safety, only spawn one item per check; keeps behavior predictable.
    local next_item = dequeue_item()
    if not next_item then
        return
    end

    log(string.format(
        "Processing queued item: ItemNo=%d (remaining in queue: %d)",
        next_item, pending_count()
    ))

    local ok, err = pcall(function()
        -- Signature: setEventItem(app.MTData.ITEM_NO, System.Boolean)
        set_event_method:call(inv_instance, next_item, false)
    end)

    if ok then
        log("setEventItem succeeded for ItemNo=" .. tostring(next_item))
    else
        log("setEventItem failed for ItemNo=" .. tostring(next_item) ..
              " error: " .. tostring(err))
    end
end

------------------------------------------------
-- Public API
------------------------------------------------

function M.spawn(item_no)
    -- Coerce numeric strings to numbers
    if type(item_no) ~= "number" then
        local as_num = tonumber(item_no)
        if not as_num then
            log("spawn: item_no must be a number or numeric string, got: " .. tostring(item_no))
            return
        end
        item_no = as_num
    end

    enqueue_item(item_no)
    log(string.format(
        "spawn: queued ItemNo=%d (queue size now %d)",
        item_no, pending_count()
    ))

    -- Try to process immediately if possible
    if ensure_inventory() and can_accept_more_items() then
        process_pending_items()
    end
end

function M.pending_count()
    return pending_count()
end

-- Called from central re.on_frame in main.lua
local last_check_time = 0
local CHECK_INTERVAL  = 0.25  -- 4x per second is plenty for queue processing

function M.on_frame()
    local now = os.clock()
    if now - last_check_time < CHECK_INTERVAL then
        return
    end
    last_check_time = now

    ensure_inventory()
    process_pending_items()
end

log("Module loaded.")

return M