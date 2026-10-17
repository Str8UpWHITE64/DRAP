-- DRAP/ItemRestriction.lua
-- Restricted Item Mode: Restricts item pickup to only items received from AP server
-- Players cannot pick up items unless they've been sent by Archipelago

local Shared = require("DRAP/Shared")
local SharedData = require("DRAP/SharedData")

local M = Shared.create_module("ItemRestriction")
M:set_throttle(0.25)  -- CHECK_INTERVAL

------------------------------------------------------------
-- Singleton Managers
------------------------------------------------------------

local im_mgr   = M:add_singleton("im", "app.solid.gamemastering.ItemManager")
local ahlm_mgr = M:add_singleton("ahlm", "app.solid.gamemastering.AreaHitLayoutManager")
local am_mgr   = M:add_singleton("am", "app.solid.gamemastering.AreaManager")

------------------------------------------------------------
-- Configuration
------------------------------------------------------------

M.enabled = false  -- Restricted Item Mode is OFF by default
-- Turning the mode on from the console is a deliberate act, so it stands in
-- for the slot connect. Without it the mode is untestable without standing up
-- a server, and the main loop skips this module entirely while dormant.
local console_override = false
-- Item numbers granted by hand for offline testing, on top of anything the
-- slot has actually sent.
local GRANTED = {}

------------------------------------------------------------
-- Internal State
------------------------------------------------------------

-- Known items from JSON (items we track for restriction)
local KNOWN_ITEM_NUMBERS = {}  -- item_number -> true (only items with non-empty names)
local known_items_loaded = false

-- Track allowed item numbers (game item numbers the player can pick up)
local ALLOWED_ITEM_COUNTS = {}  -- item_no -> count of how many can be picked up

-- Track patches we've made so we can restore them
local GROUND_ITEM_PATCHES = {}    -- item_obj -> { original_takeable = bool }
local DISPENSER_PATCHES = {}      -- layout_info -> { original_item_no = number }

-- Area tracking for rescanning
local last_area_index = nil
local last_level_path = nil

-- Reference to bridge module (set lazily)
local AP_BRIDGE = nil

------------------------------------------------------------
-- Known Items Loading
------------------------------------------------------------

local function load_known_items()
    -- If already loaded successfully, don't reload
    if known_items_loaded then return true end

    local items = SharedData.items()
    if type(items) ~= "table" or #items == 0 then
        -- Don't set known_items_loaded = true, so we retry next time
        M.log("WARNING: SharedData.items() returned empty or invalid data")
        return false
    end

    KNOWN_ITEM_NUMBERS = {}
    local count = 0

    -- Only track items with a non-empty name -- those are the AP-tracked
    -- items. Items with empty names are vanilla world items that we never
    -- restrict (they'd be unobtainable otherwise).
    for _, def in ipairs(items) do
        if def.name and def.name ~= "" and def.item_number then
            local item_num = tonumber(def.item_number)
            if item_num then
                KNOWN_ITEM_NUMBERS[item_num] = true
                count = count + 1
            end
        end
    end

    if count == 0 then
        M.log("WARNING: No valid items found in SharedData")
        return false
    end

    M.log(string.format("SUCCESS: Loaded %d known item numbers from SharedData", count))
    known_items_loaded = true
    return true
end

--- Forces a reload of the known items list
function M.reload_known_items()
    known_items_loaded = false
    KNOWN_ITEM_NUMBERS = {}
    local success = load_known_items()
    M.log("reload_known_items() result: " .. tostring(success))
    return success
end

local function is_known_item(item_no)
    if not item_no then return false end
    return KNOWN_ITEM_NUMBERS[item_no] == true
end

------------------------------------------------------------
-- Bridge Access
------------------------------------------------------------

local function get_bridge()
    if AP_BRIDGE then return AP_BRIDGE end

    if AP and AP.AP_BRIDGE then
        AP_BRIDGE = AP.AP_BRIDGE
        return AP_BRIDGE
    end

    return nil
end

------------------------------------------------------------
-- Allowed Items Management
------------------------------------------------------------

-- Items that turn into another item when they break. The new item appears in
-- Frank's hands mid-swing, where the sweep cannot take it back safely,
-- so receiving the whole item allows its broken form too. Game item numbers:
-- Push Broom 8 -> Push Broom Handle 9, Mailbox 252 -> Mailbox Post 254.
local BREAKS_INTO = {
    [8]   = 9,
    [252] = 254,
}

local function allow_broken_forms()
    for whole, broken in pairs(BREAKS_INTO) do
        if (ALLOWED_ITEM_COUNTS[whole] or 0) > 0 then
            ALLOWED_ITEM_COUNTS[broken] = math.max(ALLOWED_ITEM_COUNTS[broken] or 0, 1)
        end
    end
end

--- Rebuilds the allowed item counts from AP bridge received items
local function rebuild_allowed_items()
    ALLOWED_ITEM_COUNTS = {}

    local bridge = get_bridge()
    if not bridge or not bridge.get_all_received_items then
        return
    end

    local received = bridge.get_all_received_items()
    if not received then return end

    for _, entry in ipairs(received) do
        local game_item_no = entry.game_item_no
        if game_item_no then
            ALLOWED_ITEM_COUNTS[game_item_no] = (ALLOWED_ITEM_COUNTS[game_item_no] or 0) + 1
        end
    end
    allow_broken_forms()
end

--- Rebuilds and folds in anything granted by hand. Called wherever the
--- allowance is rebuilt, so a console grant survives a rescan.
local function rebuild_allowed_with_grants()
    rebuild_allowed_items()
    for item_no in pairs(GRANTED) do
        ALLOWED_ITEM_COUNTS[item_no] = (ALLOWED_ITEM_COUNTS[item_no] or 0) + 1
    end
    allow_broken_forms()
end

-- An item is allowed iff: restricted mode is off, OR the item is not a
-- known AP item (we never restrict vanilla-only items), OR the player has
-- received at least one copy of it from AP this run.
local function is_item_allowed(item_no)
    if not M.enabled then return true end
    if not item_no then return true end
    if not is_known_item(item_no) then return true end
    return (ALLOWED_ITEM_COUNTS[item_no] or 0) > 0
end

------------------------------------------------------------
-- Pickup hook
------------------------------------------------------------
-- The scan below marks world items untakeable so no prompt appears, which is
-- the experience we want. It cannot be the only defence though: it runs on a
-- timer, so anything spawning between ticks is takeable until the next one; it
-- only walks two lists, so zombie drops and container contents are never seen;
-- and setTakeable is advisory -- the engine drifts mTakeable back on its own,
-- which is why the scan already re-checks it.
--
-- Every item that reaches the player passes through Inventory.PickItem
-- whatever spawned it, so refusing there closes all three at once. The scan
-- stays for the prompt; this decides what actually happens.
local INVENTORY_TYPE = "app.solid.character.player.Inventory"
local pick_hooked = false
local pick_blocked = 0
-- Set by the pre-hook only for the call it is refusing. The post-hook runs for
-- every call, so without this it would report failure for allowed pickups too.
local pick_refused = false
local pick_seen = {}        -- item_no -> logged once, so a miss is diagnosable

--- @return integer|nil the item's game item number
local function item_number_of(item)
    if not item then return nil end
    local no = Shared.get_field_value(item, {"mItemNo", "<mItemNo>k__BackingField"})
    if no == nil then return nil end
    return Shared.to_int(no)
end

--- Hooks one of the inventory's entry points. PickItem returns bool and the
--- others return an Item, so a refused call answers false or nil -- either
--- way the caller reads "nothing was taken".
local function install_one_pick_hook(method, label)
    sdk.hook(method,
        function(args)
            pick_refused = false
            if not M.enabled then return end
            local item_no
            pcall(function()
                item_no = item_number_of(sdk.to_managed_object(args[3]))
            end)
            if not item_no then return end
            if is_item_allowed(item_no) then return end

            pick_blocked = pick_blocked + 1
            pick_refused = true
            if not pick_seen[item_no] then
                pick_seen[item_no] = true
                M.log(string.format("blocked %s of item %d -- not received",
                    label, item_no))
            end
            return sdk.PreHookResult.SKIP_ORIGINAL
        end,
        function(retval)
            if pick_refused then
                pick_refused = false
                return sdk.to_ptr(0)
            end
            return retval
        end)
end

-- Both entry points that carry an item. PickItemFromReserve is deliberately
-- absent: it takes no item, so there is nothing to judge.
--
-- In practice these rarely fire. The scan marks world items untakeable, so the
-- game never asks -- these catch whatever the scan missed, which is the case
-- the old implementation had no answer for.
local PICK_METHODS = { "PickItem", "SetItem" }

local function install_pick_hook()
    if pick_hooked then return end
    local td = sdk.find_type_definition(INVENTORY_TYPE)
    if not td then return end

    local armed = {}
    for _, name in ipairs(PICK_METHODS) do
        local m = td:get_method(name)
        if m then
            local ok = pcall(install_one_pick_hook, m, name)
            if ok then armed[#armed + 1] = name end
        end
    end
    pick_hooked = true
    if #armed == 0 then
        M.log("no pickup method could be hooked -- falling back to the scan alone")
    else
        M.log("pickup hooks armed on " .. table.concat(armed, ", "))
    end
end


------------------------------------------------------------
-- Inventory sweep
------------------------------------------------------------
-- The last line of defence, and the only one that does not care how an item
-- arrived. Hooks cover the pickup calls we know about; a handgun caught
-- mid-fall still got through in testing, and items handed over by survivors or
-- granted by a cutscene may never touch those calls at all.
--
-- So rather than guess at every route in, check what the player is actually
-- holding and take back anything they should not have.
local sweep_removed = 0
local sweep_failed = {}     -- item_no -> already reported, so it says so once
                            -- (reset by drap_restrict_removal)
local sweep_said = {}       -- reason -> reported, so a dead sweep says why once

local function say_sweep_once(reason)
    if sweep_said[reason] then return end
    sweep_said[reason] = true
    M.log("sweep: " .. reason)
end

local function player_inventory()
    local pm = sdk.get_managed_singleton("app.solid.PlayerManager")
    if not pm then return nil end
    local inv
    pcall(function() inv = pm:call("get_Inventory") end)
    return inv
end

--- An inventory slot does not carry the item number where a world item does.
--- Read in game: ItemSlot has two fields, Item and SAVE_WORK, and it is
--- SAVE_WORK that holds mItemNo. The Item object beside it does not.
--- @return integer|nil item number, or nil if the slot is empty
local function slot_item_number(slot)
    if not slot then return nil end
    local save_work = Shared.get_field_value(slot, {"SAVE_WORK"})
    local no = save_work and item_number_of(save_work) or nil
    if no then return no end
    -- Not seen in practice, but harmless if a patch moves it back.
    local item = Shared.get_field_value(slot, {"Item"})
    return item and item_number_of(item) or nil
end

--- @return integer number of items taken back
-- clearItem takes the slot ByRef, and calling it from Lua reports success
-- while changing nothing -- the item stays and the sweep retries forever. So
-- every removal is verified by re-reading the slot, and several routes are
-- tried until one actually takes. Whichever wins is logged once, so we learn
-- which of these the engine really honours.
-- Confirmed in game. Kept as a list because every removal is verified against
-- the held count anyway, so adding a fallback later costs nothing.
local REMOVAL_STRATEGIES = {
    -- Takes the item number by value. The slot-based calls take it ByRef and
    -- cannot be driven from Lua: clearItem reports success and changes
    -- nothing, dropItem half-clears and corrupts the slot.
    { name = "removeItem(itemNo)",
      run = function(inv, _, item_no) inv:call("removeItem", item_no) end },
}

local removal_strategy = nil    -- the one that worked, reused thereafter
-- On: the mode's whole promise is that you only have what you were sent, so an
-- item that got in some other way has to go. removeItem takes the number by
-- value and leaves the inventory consistent, which is what makes this safe --
-- the slot-based calls do not. clearItem silently does nothing, and dropItem
-- half-clears: the weapon lands on the floor, the slot keeps it, and firing it
-- shoots from where it fell.
local removal_enabled = true

--- Removes one slot's item and proves it. Returns true only when the slot no
--- longer holds what it held.
local function remove_from_slot(inv, slot, index, item_no)
    local function held_count()
        local n
        pcall(function() n = inv:call("get_CurrentItemNumbers") end)
        return n and Shared.to_int(n) or nil
    end

    local function attempt(strategy)
        local before = held_count()
        local ok = pcall(strategy.run, inv, slot, item_no)
        if not ok then return false end
        local after = held_count()
        -- The slot losing its number is not enough: a half-cleared slot reads
        -- empty while the player still has the item. The count is the truth.
        return before ~= nil and after ~= nil and after < before
    end

    if removal_strategy and attempt(removal_strategy) then return true end

    for _, strategy in ipairs(REMOVAL_STRATEGIES) do
        if strategy ~= removal_strategy and attempt(strategy) then
            removal_strategy = strategy
            return true
        end
    end
    return false
end

--- @param verbose boolean|nil report every slot and why it was left alone
local function sweep_inventory(verbose)
    if not M.enabled then return 0 end
    local inv = player_inventory()
    if not inv then return 0 end

    local count
    pcall(function() count = inv:call("get_CurrentItemNumbers") end)
    count = count and Shared.to_int(count) or nil
    if not count or count <= 0 then
        say_sweep_once("no slot count -- get_CurrentItemNumbers gave "
            .. tostring(count))
        return 0
    end

    local removed = 0
    for i = 0, count - 1 do
        local slot
        pcall(function() slot = inv:call("getItemSlot", i) end)
        if slot then
            local item_no = slot_item_number(slot)
            if not item_no then
                say_sweep_once("slots hold no readable item number -- run "
                    .. "drap_restrict_dump_inventory() to see their fields")
            elseif verbose then
                -- Two separate reasons an item survives, and they want
                -- different fixes: not ours to police, or already granted.
                M.log(string.format("  slot %d: item %d  known=%s allowed=%s",
                    i, item_no, tostring(is_known_item(item_no)),
                    tostring(is_item_allowed(item_no))))
            end
            if item_no and not is_item_allowed(item_no) then
                if not removal_enabled then
                    if not sweep_failed[item_no] then
                        sweep_failed[item_no] = true
                        M.log(string.format(
                            "item %d is held but should not be -- removal is "
                            .. "off (drap_restrict_removal(true) to try it)",
                            item_no))
                    end
                elseif remove_from_slot(inv, slot, i, item_no) then
                    removed = removed + 1
                    sweep_removed = sweep_removed + 1
                    sweep_failed[item_no] = nil
                    M.log(string.format("took back item %d -- not received", item_no))
                elseif not sweep_failed[item_no] then
                    -- Once per item, not once per tick: it is held, we cannot
                    -- take it, and repeating that every frame helps nobody.
                    sweep_failed[item_no] = true
                    M.log.warn(string.format(
                        "item %d is held and cannot be removed -- every route "
                        .. "reported success but the slot still has it", item_no))
                end
            end
        end
    end
    return removed
end

------------------------------------------------------------
-- Area Info Helper
------------------------------------------------------------

local function get_area_info()
    local am = am_mgr:get()
    if not am then return nil, nil end

    local area_index = nil
    local level_path = nil

    local area_index_f = am_mgr:get_field("mAreaIndex", false)
    if area_index_f then
        local v = Shared.safe_get_field(am, area_index_f)
        if v then area_index = Shared.to_int(v) end
    end

    local level_path_f = am_mgr:get_field("CurrentLevelPath", false) or
                         am_mgr:get_field("<CurrentLevelPath>k__BackingField", false)
    if level_path_f then
        local v = Shared.safe_get_field(am, level_path_f)
        if v then level_path = tostring(v) end
    else
        local ok, v = pcall(sdk.call_object_func, am, "get_CurrentLevelPath")
        if ok and v then level_path = tostring(v) end
    end

    return area_index, level_path
end

------------------------------------------------------------
-- Ground Item Restriction (ItemManager)
-- Scans both mItemLayoutSpawnedItem and mShelfCheckItemsInScene
------------------------------------------------------------

local function scan_item_list(items_list, source_name)
    if not items_list then return 0, 0 end

    local patched_count = 0
    local restored_count = 0

    for i, item in Shared.iter_collection(items_list) do
        if item then
            -- Get the item number
            local item_no = Shared.get_field_value(item, {"mItemNo", "<mItemNo>k__BackingField"})
            if item_no then
                item_no = Shared.to_int(item_no)
            end

            if item_no then
                local allowed = is_item_allowed(item_no)
                local item_key = tostring(item)

                local item_td = item:get_type_definition()
                if item_td then
                    local set_takeable = item_td:get_method("setTakeable")

                    if set_takeable then
                        if allowed then
                            if GROUND_ITEM_PATCHES[item_key] then
                                local ok = pcall(set_takeable.call, set_takeable, item, true)
                                if ok then
                                    GROUND_ITEM_PATCHES[item_key] = nil
                                    restored_count = restored_count + 1
                                end
                            end
                        else
                            -- Known item we haven't received -- make it untakeable.
                            if not GROUND_ITEM_PATCHES[item_key] then
                                local ok = pcall(set_takeable.call, set_takeable, item, false)
                                if ok then
                                    GROUND_ITEM_PATCHES[item_key] = { item_no = item_no, source = source_name }
                                    patched_count = patched_count + 1
                                end
                            else
                                -- Defensive re-check: if mTakeable drifted back to
                                -- true (engine may flip it during respawn), force
                                -- it back off.
                                local mTakeable = Shared.get_field_value(item, {"mTakeable", "<mTakeable>k__BackingField"})
                                if mTakeable == true then
                                    pcall(set_takeable.call, set_takeable, item, false)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return patched_count, restored_count
end

local function scan_ground_items()
    if not M.enabled then return end

    local im = im_mgr:get()
    if not im then return end

    local total_patched = 0
    local total_restored = 0

    -- Scan mItemLayoutSpawnedItem (world-spawned items)
    local spawned_field = im_mgr:get_field("mItemLayoutSpawnedItem", false)
    if spawned_field then
        local spawned_container = Shared.safe_get_field(im, spawned_field)
        if spawned_container then
            local items_td = spawned_container:get_type_definition()
            if items_td then
                local items_field = items_td:get_field("_items")
                if items_field then
                    local items_list = Shared.safe_get_field(spawned_container, items_field)
                    local p, r = scan_item_list(items_list, "spawned")
                    total_patched = total_patched + p
                    total_restored = total_restored + r
                end
            end
        end
    end

    -- Scan mShelfCheckItemsInScene (dropped items from player/NPCs)
    local shelf_field = im_mgr:get_field("mShelfCheckItemsInScene", false)
    if shelf_field then
        local shelf_container = Shared.safe_get_field(im, shelf_field)
        if shelf_container then
            local shelf_td = shelf_container:get_type_definition()
            if shelf_td then
                local shelf_items_field = shelf_td:get_field("_items")
                if shelf_items_field then
                    local shelf_items_list = Shared.safe_get_field(shelf_container, shelf_items_field)
                    local p, r = scan_item_list(shelf_items_list, "shelf")
                    total_patched = total_patched + p
                    total_restored = total_restored + r
                end
            end
        end
    end
end

------------------------------------------------------------
-- Dispenser Item Restriction (AreaHitLayoutManager)
-- Only affects items with SHAPE == 4 (dispenser items)
------------------------------------------------------------

local DISPENSER_SHAPE = 4  -- Shape value that indicates a dispenser item

local function scan_dispenser_items()
    if not M.enabled then return end

    local ahlm = ahlm_mgr:get()
    if not ahlm then return end

    local res_field = ahlm_mgr:get_field("mAreaHitResource", false) or
                      ahlm_mgr:get_field("<mAreaHitResource>k__BackingField", false)
    if not res_field then return end

    local res_list = Shared.safe_get_field(ahlm, res_field)
    if not res_list then return end

    local patched_count = 0
    local restored_count = 0

    for r_i, res in Shared.iter_collection(res_list) do
        if res then
            local pResource_val = Shared.get_field_value(res, {"pResource", "<pResource>k__BackingField"})
            if pResource_val then
                local pRes = pResource_val
                local pRes_td = pRes:get_type_definition()

                -- Look for rItemLayout instead of rAreaHitLayout
                if pRes_td and pRes_td:get_full_name() == "app.solid.gamemastering.rItemLayout" then
                    local layout_list_val = Shared.get_field_value(pRes, {"mpLayoutInfoList", "<mpLayoutInfoList>k__BackingField"})

                    if layout_list_val then
                        for li_i, li in Shared.iter_collection(layout_list_val) do
                            if li then
                                -- Check SHAPE first - only process dispenser items (SHAPE == 4)
                                local shape = Shared.get_field_value(li, {"SHAPE", "<SHAPE>k__BackingField"})
                                if shape then
                                    shape = Shared.to_int(shape)
                                end

                                -- Skip if not a dispenser item
                                if shape ~= DISPENSER_SHAPE then
                                    goto continue_dispenser
                                end

                                -- Get the item number from ITEM_NO (this is the "true" item number)
                                local item_no = Shared.get_field_value(li, {"ITEM_NO", "<ITEM_NO>k__BackingField"})
                                if item_no then
                                    item_no = Shared.to_int(item_no)
                                end

                                if item_no and item_no > 0 then
                                    local allowed = is_item_allowed(item_no)
                                    local layout_key = tostring(li)

                                    -- Get mHitData
                                    local mHitData_val = Shared.get_field_value(li, {"mHitData", "<mHitData>k__BackingField"})

                                    if mHitData_val then
                                        if allowed then
                                            -- Item should be available - set mItemNo to match ITEM_NO
                                            if DISPENSER_PATCHES[layout_key] then
                                                local ok = pcall(mHitData_val.set_field, mHitData_val, "mItemNo", item_no)
                                                if ok then
                                                    DISPENSER_PATCHES[layout_key] = nil
                                                    restored_count = restored_count + 1
                                                end
                                            end
                                        else
                                            -- Item should NOT be available - set mItemNo to 0
                                            if not DISPENSER_PATCHES[layout_key] then
                                                local ok_set = pcall(mHitData_val.set_field, mHitData_val, "mItemNo", 0)
                                                if ok_set then
                                                    DISPENSER_PATCHES[layout_key] = { item_no = item_no }
                                                    patched_count = patched_count + 1
                                                end
                                            end
                                        end
                                    end
                                end

                                ::continue_dispenser::
                            end
                        end
                    end
                end
            end
        end
    end
end

------------------------------------------------------------
-- Full Rescan
------------------------------------------------------------

local function rescan_all_items()
    if not M.enabled then return end

    -- Make sure known items are loaded - if not, skip this rescan
    if not load_known_items() then
        M.log("rescan_all_items: Skipping - known items not yet loaded")
        return
    end

    rebuild_allowed_with_grants()
    scan_ground_items()
    scan_dispenser_items()
end

------------------------------------------------------------
-- Restore All (when disabling restricted item mode)
------------------------------------------------------------

local function restore_item_list(items_list)
    if not items_list then return end

    for i, item in Shared.iter_collection(items_list) do
        if item then
            local item_key = tostring(item)
            if GROUND_ITEM_PATCHES[item_key] then
                local item_td = item:get_type_definition()
                if item_td then
                    local set_takeable = item_td:get_method("setTakeable")
                    if set_takeable then
                        pcall(set_takeable.call, set_takeable, item, true)
                    end
                end
            end
        end
    end
end

local function restore_all_items()
    -- Restore ground items from both sources
    local im = im_mgr:get()
    if im then
        -- Restore mItemLayoutSpawnedItem
        local spawned_field = im_mgr:get_field("mItemLayoutSpawnedItem", false)
        if spawned_field then
            local spawned_container = Shared.safe_get_field(im, spawned_field)
            if spawned_container then
                local items_td = spawned_container:get_type_definition()
                if items_td then
                    local items_field = items_td:get_field("_items")
                    if items_field then
                        local items_list = Shared.safe_get_field(spawned_container, items_field)
                        restore_item_list(items_list)
                    end
                end
            end
        end

        -- Restore mShelfCheckItemsInScene
        local shelf_field = im_mgr:get_field("mShelfCheckItemsInScene", false)
        if shelf_field then
            local shelf_container = Shared.safe_get_field(im, shelf_field)
            if shelf_container then
                local shelf_td = shelf_container:get_type_definition()
                if shelf_td then
                    local shelf_items_field = shelf_td:get_field("_items")
                    if shelf_items_field then
                        local shelf_items_list = Shared.safe_get_field(shelf_container, shelf_items_field)
                        restore_item_list(shelf_items_list)
                    end
                end
            end
        end
    end
    GROUND_ITEM_PATCHES = {}

    -- Restore dispenser items - use ITEM_NO directly to restore mItemNo
    local ahlm = ahlm_mgr:get()
    if ahlm then
        local res_field = ahlm_mgr:get_field("mAreaHitResource", false) or
                          ahlm_mgr:get_field("<mAreaHitResource>k__BackingField", false)
        if res_field then
            local res_list = Shared.safe_get_field(ahlm, res_field)
            if res_list then
                for r_i, res in Shared.iter_collection(res_list) do
                    if res then
                        local pResource_val = Shared.get_field_value(res, {"pResource", "<pResource>k__BackingField"})
                        if pResource_val then
                            local pRes = pResource_val
                            local pRes_td = pRes:get_type_definition()
                            if pRes_td and pRes_td:get_full_name() == "app.solid.gamemastering.rItemLayout" then
                                local layout_list_val = Shared.get_field_value(pRes, {"mpLayoutInfoList", "<mpLayoutInfoList>k__BackingField"})
                                if layout_list_val then
                                    for li_i, li in Shared.iter_collection(layout_list_val) do
                                        if li then
                                            local layout_key = tostring(li)
                                            if DISPENSER_PATCHES[layout_key] then
                                                -- Get ITEM_NO to restore to mItemNo
                                                local item_no = Shared.get_field_value(li, {"ITEM_NO", "<ITEM_NO>k__BackingField"})
                                                if item_no then
                                                    item_no = Shared.to_int(item_no)
                                                end

                                                if item_no and item_no > 0 then
                                                    local mHitData_val = Shared.get_field_value(li, {"mHitData", "<mHitData>k__BackingField"})
                                                    if mHitData_val then
                                                        pcall(mHitData_val.set_field, mHitData_val, "mItemNo", item_no)
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    DISPENSER_PATCHES = {}

    M.log("All item restrictions restored")
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

--- Enables restricted item mode
function M.enable()
    if M.enabled then return end
    M.enabled = true
    M.log("Restricted Item Mode ENABLED - items restricted to AP received items")
    install_pick_hook()
    rescan_all_items()
end

--- Disables restricted item mode
function M.disable()
    if not M.enabled then return end
    M.enabled = false
    M.log("Restricted Item Mode DISABLED - all items available")
    restore_all_items()
end

--- Sets the enabled state
--- @param enabled boolean Whether restricted item mode should be enabled
function M.set_enabled(enabled)
    if enabled then
        M.enable()
    else
        M.disable()
    end
end

--- Checks if restricted item mode is enabled
--- @return boolean True if enabled
function M.is_enabled()
    return M.enabled
end

--- Called when new items are received from AP. Triggers a rescan so the
--- newly-received items become takeable on the player's next pickup attempt.
function M.on_items_received()
    if not M.enabled then return end
    rescan_all_items()
end

--- Forces a full rescan of all items (console helper).
function M.force_rescan()
    rescan_all_items()
end

--- Dumps all known item numbers to the log (console helper).
function M.dump_known_items()
    load_known_items()
    M.log("=== FULL KNOWN ITEMS DUMP ===")
    local sorted_items = {}
    for item_no, _ in pairs(KNOWN_ITEM_NUMBERS) do
        table.insert(sorted_items, item_no)
    end
    table.sort(sorted_items)
    for _, item_no in ipairs(sorted_items) do
        M.log(string.format("  Known item #%d", item_no))
    end
    M.log(string.format("=== Total: %d known items ===", #sorted_items))
end

--- Checks if a specific item number is in the known list
--- @param item_no number The item number to check
function M.is_item_known(item_no)
    load_known_items()
    local result = KNOWN_ITEM_NUMBERS[item_no] == true
    M.log(string.format("is_item_known(%d) = %s", item_no, tostring(result)))
    return result
end

------------------------------------------------------------
-- Per-frame Update
------------------------------------------------------------

-- Reset state when singletons change
im_mgr.on_instance_changed = function(old, new)
    GROUND_ITEM_PATCHES = {}
    if M.enabled then
        M.log("ItemManager changed - will rescan ground items")
    end
end

ahlm_mgr.on_instance_changed = function(old, new)
    DISPENSER_PATCHES = {}
    if M.enabled then
        M.log("AreaHitLayoutManager changed - will rescan dispensers")
    end
end

function M.on_frame()
    if not M:should_run() then return end
    if not M.enabled then return end

    -- The scene has to exist before the type resolves, so enable() alone is
    -- not enough when the mode is switched on before a save is loaded.
    if not pick_hooked then install_pick_hook() end

    -- Check for area changes
    local area_index, level_path = get_area_info()
    if area_index and level_path then
        if area_index ~= last_area_index or level_path ~= last_level_path then
            last_area_index = area_index
            last_level_path = level_path
            M.log(string.format("Area changed to %s (index %d)", tostring(level_path), area_index))

            -- Force reload known items on area change to ensure they're loaded
            M.reload_known_items()
            M.log("Rescanning items for new area...")
            rescan_all_items()
        end
    end

    if not known_items_loaded then
        load_known_items()
        return
    end

    -- Periodic rescan to catch dynamically spawned items
    scan_ground_items()
    scan_dispenser_items()
    sweep_inventory()
end

------------------------------------------------------------
-- Console
------------------------------------------------------------

-- Own loop rather than the main one. The main loop skips every module while no
-- slot is connected, which is exactly where this mode needs testing -- and a
-- console override is no use if nothing ticks.
re.on_frame(function()
    if not console_override then return end
    pcall(M.on_frame)
end)

--- drap_restrict_grant(52)         -- pretend the slot sent item 52
--- drap_restrict_grant(52, false)  -- take it back
_G.drap_restrict_grant = function(item_no, on)
    if not M.enabled then
        M.log.warn("restricted mode is off -- the grant is recorded but "
            .. "nothing is being restricted yet")
    end
    item_no = tonumber(item_no)
    if not item_no then
        M.log("usage: drap_restrict_grant(<item number> [, false])")
        return
    end
    if on == false then
        GRANTED[item_no] = nil
        M.log("revoked item " .. item_no)
    else
        GRANTED[item_no] = true
        M.log("granted item " .. item_no)
    end
    rebuild_allowed_with_grants()
    rescan_all_items()
end

--- Which half is doing the work. A rising blocked count with the scan also
--- running means something reached PickItem that the scan never marked --
--- which is the leak this hook exists to catch.
--- Everything the sweep looks at, printed. A sweep that takes back nothing
--- looks identical whether it found no contraband or never saw the inventory
--- at all -- this says which, and names the fields so a wrong guess is
--- obvious rather than silent.
_G.drap_restrict_dump_inventory = function()
    local inv = player_inventory()
    if not inv then
        M.log("no Inventory -- PlayerManager.get_Inventory returned nothing")
        return
    end
    local inv_type = "?"
    pcall(function() inv_type = inv:get_type_definition():get_full_name() end)
    M.log("Inventory is " .. inv_type)

    local raw
    local ok = pcall(function() raw = inv:call("get_CurrentItemNumbers") end)
    M.log(string.format("  get_CurrentItemNumbers: ok=%s raw=%s as_int=%s",
        tostring(ok), tostring(raw),
        tostring(raw and Shared.to_int(raw) or nil)))

    local count = raw and Shared.to_int(raw) or 0
    for i = 0, math.max(count, 8) - 1 do
        local slot
        local got = pcall(function() slot = inv:call("getItemSlot", i) end)
        if not got or not slot then
            M.log(string.format("  slot %d: none", i))
        else
            local st = "?"
            pcall(function() st = slot:get_type_definition():get_full_name() end)
            M.log(string.format("  slot %d: %s", i, st))
            local td
            pcall(function() td = slot:get_type_definition() end)
            local fields = td and Shared.get_fields_array(td) or {}
            for _, f in ipairs(fields) do
                local name
                pcall(function() name = f:get_name() end)
                if name then
                    local v = Shared.safe_get_field(slot, f)
                    local desc = tostring(v)
                    -- If it looks like an Item, say what item it is.
                    local no = v and item_number_of(v) or nil
                    if no then desc = desc .. "  itemNo=" .. tostring(no) end
                    M.log(string.format("      %-28s %s", name, desc))
                end
            end
        end
    end
end

--- Runs the sweep on demand, for checking it against a known-bad inventory.
_G.drap_restrict_sweep = function()
    if not M.enabled then
        M.log.warn("restricted mode is off -- the sweep does nothing. "
            .. "Run drap_restrict(true) first.")
        return 0
    end
    local n = sweep_inventory(true)
    M.log(string.format("sweep took back %d item(s)", n))
    return n
end

--- Removal is destructive and none of the routes tried so far leave the
--- inventory intact, so it stays off until asked for explicitly.
_G.drap_restrict_removal = function(on)
    if not M.enabled then
        M.log.warn("restricted mode is off -- nothing will be removed until "
            .. "drap_restrict(true)")
    end
    removal_enabled = (on ~= false)
    sweep_failed = {}
    M.log("inventory removal " .. (removal_enabled and "ON" or "off"))
    return removal_enabled
end

_G.drap_restrict_status = function()
    M.log(string.format("Restricted Item Mode: %s", M.enabled and "ON" or "off"))
    if not M.enabled then
        M.log("  everything below is zero because the mode is off -- "
            .. "drap_restrict(true) arms it")
    end
    M.log(string.format("  PickItem hooked: %s", tostring(pick_hooked)))
    M.log(string.format("  pickups refused this session: %d", pick_blocked))
    M.log(string.format("  items taken back by the sweep: %d", sweep_removed))
    M.log(string.format("  inventory removal: %s",
        removal_enabled and "ON" or "off (reporting only)"))
    local n = 0
    for _ in pairs(ALLOWED_ITEM_COUNTS) do n = n + 1 end
    M.log(string.format("  distinct item types allowed: %d", n))
end

--- Turns the mode on without a slot, for testing offline.
_G.drap_restrict = function(on)
    if on == nil then on = not M.enabled end
    console_override = on == true
    M.set_enabled(console_override)
    M.log(console_override
        and "restricted mode ON (console override -- runs without a slot)"
        or "restricted mode off")
    return M.enabled
end

return M
