-- DRAP/ItemRestriction.lua
-- Restricted Item Mode: Restricts item pickup to only items received from AP server
-- Players cannot pick up items unless they've been sent by Archipelago

local Shared = require("DRAP/Shared")

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
local ITEMS_JSON_PATH = "drdr_items.json"

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

    -- Use REFramework's json.load_file for proper parsing
    local items = json.load_file(ITEMS_JSON_PATH)
    if not items then
        -- Don't set known_items_loaded = true, so we retry next time
        return false
    end

    if type(items) ~= "table" or #items == 0 then
        M.log("WARNING: " .. ITEMS_JSON_PATH .. " loaded but appears empty or invalid")
        return false
    end

    KNOWN_ITEM_NUMBERS = {}
    local count = 0
    local name_to_number = {}  -- For debugging duplicate detection

    for _, def in ipairs(items) do
        -- Only track items with non-empty names (these are the AP-tracked items)
        if def.name and def.name ~= "" and def.item_number then
            local item_num = tonumber(def.item_number)
            if item_num then
                KNOWN_ITEM_NUMBERS[item_num] = true
                count = count + 1

                -- Track for duplicate detection logging
                if name_to_number[def.name] then
                    -- M.log(string.format("  Note: '%s' has multiple item_numbers: %d and %d",
                    --     def.name, name_to_number[def.name], item_num))
                else
                    name_to_number[def.name] = item_num
                end
            end
        end
    end

    if count == 0 then
        M.log("WARNING: No valid items found in " .. ITEMS_JSON_PATH)
        return false
    end

    M.log(string.format("SUCCESS: Loaded %d known item numbers from %s", count, ITEMS_JSON_PATH))

    -- Log some sample entries to verify parsing worked
    -- M.log("Sample known items (first 10):")
    -- local sample_count = 0
    -- for item_no, _ in pairs(KNOWN_ITEM_NUMBERS) do
    --     if sample_count < 10 then
    --         M.log(string.format("  Item #%d", item_no))
    --         sample_count = sample_count + 1
    --     else
    --         break
    --     end
    -- end

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

--- Checks if an item number is a known AP item
--- @param item_no number The game item number
--- @return boolean True if this is a known AP item
local function is_known_item(item_no)
    if not item_no then return false end
    local result = KNOWN_ITEM_NUMBERS[item_no] == true
    return result
end

--- Debug function to check if an item number is known
--- @param item_no number The game item number
function M.debug_check_item(item_no)
    load_known_items()
    local is_known = KNOWN_ITEM_NUMBERS[item_no] == true
    local is_allowed = is_item_allowed(item_no)
    M.log(string.format("DEBUG: Item #%d - known=%s, allowed=%s, allowed_count=%d",
        item_no, tostring(is_known), tostring(is_allowed), ALLOWED_ITEM_COUNTS[item_no] or 0))
    return is_known, is_allowed
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
end

--- Checks if an item number is allowed to be picked up
--- @param item_no number The game item number
--- @return boolean True if the item can be picked up
local function is_item_allowed(item_no)
    if not M.enabled then return true end  -- If restricted item mode is off, all items allowed
    if not item_no then return true end  -- Unknown items are allowed (safety)

    -- If the item is NOT a known AP item, allow it (don't restrict unknown items)
    if not is_known_item(item_no) then
        return true
    end

    -- For known items, check if player has received it from AP
    return (ALLOWED_ITEM_COUNTS[item_no] or 0) > 0
end

--- Decrements the allowed count for an item (called when picked up)
--- @param item_no number The game item number
function M.consume_allowed_item(item_no)
    if not item_no then return end
    local current = ALLOWED_ITEM_COUNTS[item_no] or 0
    if current > 0 then
        ALLOWED_ITEM_COUNTS[item_no] = current - 1
        M.log(string.format("Consumed allowed item %d, remaining: %d", item_no, current - 1))
    end
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
                local is_known = is_known_item(item_no)
                local allowed = is_item_allowed(item_no)
                local item_key = tostring(item)

                -- Check if item has setTakeable method
                local item_td = item:get_type_definition()
                if item_td then
                    local set_takeable = item_td:get_method("setTakeable")

                    if set_takeable then
                        if allowed then
                            -- Item should be takeable
                            if GROUND_ITEM_PATCHES[item_key] then
                                -- Restore it
                                local ok = pcall(set_takeable.call, set_takeable, item, true)
                                if ok then
                                    -- M.log(string.format("[%s] RESTORED item #%d (known=%s)", source_name, item_no, tostring(is_known)))
                                    GROUND_ITEM_PATCHES[item_key] = nil
                                    restored_count = restored_count + 1
                                end
                            end
                        else
                            -- Item should NOT be takeable (it's a known item we haven't received)
                            if not GROUND_ITEM_PATCHES[item_key] then
                                local ok = pcall(set_takeable.call, set_takeable, item, false)
                                if ok then
                                    -- M.log(string.format("[%s] DISABLED item #%d (known=%s)", source_name, item_no, tostring(is_known)))
                                    GROUND_ITEM_PATCHES[item_key] = { item_no = item_no, source = source_name }
                                    patched_count = patched_count + 1
                                end
                            else
                                -- Already patched - verify it's still disabled
                                local mTakeable = Shared.get_field_value(item, {"mTakeable", "<mTakeable>k__BackingField"})
                                if mTakeable == true then
                                    -- M.log(string.format("[%s] WARNING: item #%d mTakeable=true but should be false! Re-disabling...", source_name, item_no))
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

    -- if total_patched > 0 or total_restored > 0 then
    --     M.log(string.format("Ground items scan complete: disabled %d, restored %d", total_patched, total_restored))
    -- end
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

    rebuild_allowed_items()
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

--- Called when new items are received from AP
--- Triggers a rescan to allow newly received items
function M.on_items_received()
    if not M.enabled then return end
    -- M.log("=== NEW ITEMS RECEIVED FROM AP ===")

    -- -- Log what we're about to allow
    -- local bridge = get_bridge()
    -- if bridge and bridge.get_all_received_items then
    --     local received = bridge.get_all_received_items()
    --     if received then
    --         local last_few = {}
    --         local start_idx = math.max(1, #received - 4)  -- Show last 5 items
    --         for i = start_idx, #received do
    --             local entry = received[i]
    --             if entry then
    --                 table.insert(last_few, string.format("  [%d] %s (game_item_no=%s)",
    --                     i, tostring(entry.item_name), tostring(entry.game_item_no)))
    --             end
    --         end
    --         M.log("Recent items received:")
    --         for _, line in ipairs(last_few) do
    --             M.log(line)
    --         end
    --     end
    -- end

    -- M.log("Rescanning all items...")
    rescan_all_items()
end

--- Forces a full rescan of all items
function M.force_rescan()
    rescan_all_items()
end

--- Gets the count of allowed items for debugging
--- @return table Map of item_no -> count
function M.get_allowed_items()
    return ALLOWED_ITEM_COUNTS
end

--- Gets the known item numbers for debugging
--- @return table Map of item_no -> true
function M.get_known_items()
    load_known_items()
    return KNOWN_ITEM_NUMBERS
end

--- Dumps all known item numbers to the log
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
end

return M