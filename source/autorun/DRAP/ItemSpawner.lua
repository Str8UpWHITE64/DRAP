-- Dead Rising Deluxe Remaster - Item Spawner (module)
-- Gives items via Inventory.setEventItem with a queued, slot-aware system + safe backoff.

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
-- Tunables (safety)
------------------------------------------------
local CHECK_INTERVAL         = 0.25     -- polling rate
local SUCCESS_COOLDOWN       = 0.35     -- delay after a successful spawn
local BASE_FAIL_COOLDOWN     = 0.75     -- initial delay after a failed spawn
local FAIL_BACKOFF_MULT      = 1.8      -- exponential backoff multiplier
local MAX_FAIL_COOLDOWN      = 10.0     -- cap backoff
local MAX_RETRIES_PER_ITEM   = 8        -- after this, we drop it (or you can keep forever)
local PROCESS_ONE_PER_TICK   = true     -- keep predictable and safer

------------------------------------------------
-- Cached state
------------------------------------------------
local ps_instance            = nil
local ps_td                  = nil
local inv_field              = nil
local missing_inv_warned     = false

local inv_instance           = nil
local inv_td                 = nil

local set_event_method       = nil
local missing_method_warned  = false

local current_items_field    = nil
local max_slot_field         = nil
local capacity_warned        = false

-- Queue entries: { item_no = number, retries = number, not_before = time }
local pending_items          = {}

-- Processing guards / timers
local is_processing          = false
local global_not_before      = 0.0   -- next time we are allowed to call setEventItem at all

------------------------------------------------
-- Helpers
------------------------------------------------
local function now_time()
    return os.clock()
end

local function reset_ps_cache()
    ps_td                 = nil
    inv_field             = nil
    missing_inv_warned    = false

    inv_instance          = nil
    inv_td                = nil

    set_event_method      = nil
    missing_method_warned = false

    current_items_field   = nil
    max_slot_field        = nil
    capacity_warned       = false

    -- NOTE: Do NOT clear pending_items here. We want to survive scene swaps.
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

------------------------------------------------
-- Ensure PlayerStatusManager + PlayerInventory
------------------------------------------------
local function ensure_player_status_manager()
    local current = sdk.get_managed_singleton(StatusManager_TYPE_NAME)

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

    if not ps_td then
        ps_td = ps_instance:get_type_definition()
        if not ps_td then
            log("Failed to get PlayerStatusManager type definition from instance.")
            return false
        end
    end

    if not inv_field then
        inv_field = ps_td:get_field("PlayerInventory")
        if not inv_field then
            if not missing_inv_warned then
                log("PlayerInventory field not found on PlayerStatusManager.")
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

    -- IMPORTANT: Always re-read the inventory instance and detect changes.
    -- Inventory can be replaced during loads without changing the PSM instance.
    local current_inv = nil
    local ok_read, val = pcall(inv_field.get_data, inv_field, ps_instance)
    if ok_read then current_inv = val end

    if current_inv ~= inv_instance then
        if inv_instance ~= nil and current_inv == nil then
            log("PlayerInventory became nil (leaving gameplay?).")
        elseif inv_instance == nil and current_inv ~= nil then
            log("PlayerInventory became available.")
        elseif inv_instance ~= nil and current_inv ~= nil then
            log("PlayerInventory instance changed (scene load / save load).")
        end

        inv_instance = current_inv
        inv_td = nil
        set_event_method = nil
        current_items_field = nil
        max_slot_field = nil
        capacity_warned = false
        missing_method_warned = false

        -- Give a short global cooldown after inventory swap
        global_not_before = math.max(global_not_before, now_time() + 1.5)
    end

    if not inv_instance then
        return false
    end

    if not inv_td then
        inv_td = inv_instance:get_type_definition()
        if not inv_td then
            log("Failed to get Inventory type definition from instance.")
            return false
        end
    end

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
    if not inv_td then return false end

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
    local ok_max, maxv     = pcall(max_slot_field.get_data, max_slot_field, inv_instance)

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

------------------------------------------------
-- Process queue (safe single-flight + backoff)
------------------------------------------------
local function process_pending_items()
    if is_processing then
        return
    end
    if pending_count() == 0 then
        return
    end

    local t = now_time()
    if t < global_not_before then
        return
    end

    if not ensure_inventory() then
        return
    end

    -- Optional “don’t spawn before time loads” gate
    if AP and AP.TimeGate and AP.TimeGate.get_current_mdate then
        local ok_tg, mdate = pcall(AP.TimeGate.get_current_mdate)
        if ok_tg and mdate and mdate <= 11200 then
            return
        end
    end

    if not can_accept_more_items() then
        return
    end

    local entry = peek_item()
    if not entry then
        return
    end

    if t < (entry.not_before or 0.0) then
        return
    end

    -- Only pop when we are about to attempt
    entry = pop_item()
    if not entry then return end

    is_processing = true

    log(string.format(
        "Processing queued item: ItemNo=%d (queue=%d retries=%d)",
        entry.item_no, pending_count(), entry.retries
    ))

    local ok, err = pcall(function()
        set_event_method:call(inv_instance, entry.item_no, false)
    end)

    if ok then
        log("setEventItem succeeded for ItemNo=" .. tostring(entry.item_no))
        global_not_before = now_time() + SUCCESS_COOLDOWN
    else
        local err_s = tostring(err)
        log("setEventItem FAILED for ItemNo=" .. tostring(entry.item_no) .. " error: " .. err_s)

        -- Backoff & retry
        entry.retries = (entry.retries or 0) + 1
        if entry.retries > MAX_RETRIES_PER_ITEM then
            log("Dropping ItemNo=" .. tostring(entry.item_no) .. " after " .. tostring(entry.retries) .. " retries.")
            -- If you prefer “never drop”, comment that line and requeue forever.
        else
            local cool = BASE_FAIL_COOLDOWN * (FAIL_BACKOFF_MULT ^ (entry.retries - 1))
            if cool > MAX_FAIL_COOLDOWN then cool = MAX_FAIL_COOLDOWN end

            entry.not_before = now_time() + cool
            -- Put it back at the FRONT to preserve ordering, but only when it’s ready again.
            push_front(entry)

            -- Also apply a global cooldown so we don't hammer other items during a failure window
            global_not_before = math.max(global_not_before, now_time() + math.min(cool, 2.0))
        end
    end

    is_processing = false
end

------------------------------------------------
-- Public API
------------------------------------------------
function M.spawn(item_no)
    if type(item_no) ~= "number" then
        local as_num = tonumber(item_no)
        if not as_num then
            log("spawn: item_no must be a number or numeric string, got: " .. tostring(item_no))
            return
        end
        item_no = as_num
    end

    enqueue_item(item_no)
    log(string.format("spawn: queued ItemNo=%d (queue size now %d)", item_no, pending_count()))
end

function M.pending_count()
    return pending_count()
end

------------------------------------------------
-- on_frame (called from main)
------------------------------------------------
local last_check_time = 0

function M.on_frame()
    local t = now_time()
    if t - last_check_time < CHECK_INTERVAL then
        return
    end
    last_check_time = t

    ensure_inventory()
    process_pending_items()
end

log("Module loaded.")
return M
