-- DRAP/ItemSpawner.lua
-- UI-based item spawning system for Archipelago
-- Players can view received items and choose when to spawn them into their inventory

local Shared = require("DRAP/Shared")

local M = Shared.create_module("ItemSpawner")
M:set_throttle(0.25)  -- CHECK_INTERVAL

------------------------------------------------------------
-- Configuration / Tunables
------------------------------------------------------------

local SUCCESS_COOLDOWN     = 0.35     -- delay after a successful spawn

-- Spawn path selector.
-- "world"     -- ItemManager.instantiateItem (5-arg) auto-preloads the prefab
--               then drops the item at the player's feet. Bypasses the
--               buggy Inventory.setEventItem path that the README flags as
--               a frequent crash source.
-- "inventory" -- Legacy path: Inventory.setEventItem(id, false). Direct
--               inventory injection. Kept for fast revert if the world path
--               regresses.
local SPAWN_PATH = "world"

-- World-spawn tunables.
local WORLD_SPAWN_OFFSET_Y = 1.0      -- spawn slightly above the floor so it
                                       -- doesn't sink through level geometry
local WORLD_PRELOAD_TIMEOUT_S = 5.0   -- max wait for prefab preload

------------------------------------------------------------
-- Restricted item mode: Spawning Control
------------------------------------------------------------

-- When true, spawning is disabled (Restricted item mode)
local spawning_disabled = false

------------------------------------------------------------
-- Singleton Manager
------------------------------------------------------------

local ps_mgr = M:add_singleton("ps", "app.solid.PlayerStatusManager")

------------------------------------------------------------
-- Internal State: Inventory Access
------------------------------------------------------------

local inv_instance = nil
local inv_td = nil
local set_event_method = nil
local current_items_field = nil
local max_slot_field = nil
local global_not_before = 0.0

------------------------------------------------------------
-- Internal State: UI
------------------------------------------------------------

-- Currently selected item name in the UI (for deduplicated list)
local selected_item_name = nil

-- Filter options
local filter_text = ""

-- Reference to bridge module
local AP_BRIDGE = nil

-- Reference to ScoopUnlocker (for event item filtering)
local ScoopUnlocker = nil

------------------------------------------------------------
-- Time Helper
------------------------------------------------------------

local function now_time()
    return os.clock()
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

local function get_received_items_from_bridge()
    local bridge = get_bridge()
    if bridge and bridge.get_all_received_items then
        return bridge.get_all_received_items() or {}
    end
    return {}
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

    -- Re-read every call: PlayerInventory swaps on scene load / save load.
    local current_inv = Shared.safe_get_field(ps, inv_field)
    if current_inv ~= inv_instance then
        local from = inv_instance and "live" or "nil"
        local to   = current_inv  and "live" or "nil"
        M.log(string.format("PlayerInventory %s -> %s (scene/save transition)", from, to))
        reset_inv_cache()
        inv_instance = current_inv
        -- Short cooldown after inventory swap so a queued spawn doesn't fire
        -- against the half-initialized new inventory.
        global_not_before = math.max(global_not_before, now_time() + 1.5)
    end

    if not inv_instance then return false end

    if not inv_td then
        local ok, td = pcall(inv_instance.get_type_definition, inv_instance)
        if not ok or not td then
            M.log("Failed to get Inventory type definition from instance.")
            return false
        end
        inv_td = td
    end

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

-- For the world path, inventory-full doesn't matter: items drop on the floor
-- for later pickup. Only the legacy inventory path is gated by capacity.
local function inventory_full_blocks_spawn()
    if SPAWN_PATH ~= "inventory" then return false end
    return not can_accept_more_items()
end

------------------------------------------------------------
-- World-spawn helpers (ItemManager.instantiateItem 5-arg path)
------------------------------------------------------------

local IM_TYPE_NAME = "app.solid.gamemastering.ItemManager"
local PM_TYPE_NAME = "app.solid.PlayerManager"

local function get_item_manager()
    return sdk.get_managed_singleton(IM_TYPE_NAME)
end

local function get_player_pos_xyz()
    local pmgr = sdk.get_managed_singleton(PM_TYPE_NAME)
    if not pmgr then return nil end
    local cond = nil
    pcall(function() cond = pmgr:get_field("_CurrentPlayerCondition") end)
    if not cond then return nil end
    local pos = nil
    pcall(function() pos = cond:get_field("LastPlayerPos") end)
    if not pos then return nil end
    local x, y, z
    pcall(function() x = pos.x; y = pos.y; z = pos.z end)
    if not (x and y and z) then return nil end
    return x, y, z
end

local function build_vec3(x, y, z)
    if Vector3f and Vector3f.new then
        local ok, v = pcall(Vector3f.new, x, y, z)
        if ok then return v end
    end
    return nil
end

-- Identity rotation. Quaternion.new takes (w, x, y, z) -- confirmed via
-- drap_npc_probe / drap_item_probe investigation.
local function build_identity_rot()
    if Quaternion and Quaternion.new then
        local ok, q = pcall(Quaternion.new, 1, 0, 0, 0)
        if ok then return q end
    end
    return nil
end

-- Track which prefabs we've preloaded so we don't double-register.
local world_preloaded = {}

local function preload_prefab(im, item_no)
    if world_preloaded[item_no] then return true end
    local ok = pcall(function() im:call("setPreloadedItemPrefab", item_no) end)
    if ok then world_preloaded[item_no] = true; return true end
    return false
end

local function is_prefab_ready(im, item_no)
    local standby = nil
    pcall(function() standby = im:get_field("ItemStandbyPrefab") end)
    if not standby then return false end
    local has = nil
    pcall(function() has = standby:call("ContainsKey", item_no) end)
    return has == true
end

-- Async spawn: preload, wait for prefab, then instantiate. Returns immediately;
-- the actual item appears in the world after the prefab finishes streaming.
-- on_done(success, err_string) fires once when the operation completes (success
-- or timeout).
local function world_spawn_async(item_no, on_done)
    local im = get_item_manager()
    if not im then
        if on_done then on_done(false, "ItemManager singleton not available") end
        return
    end

    local px, py, pz = get_player_pos_xyz()
    if not px then
        if on_done then on_done(false, "Player position not available") end
        return
    end
    local pos = build_vec3(px, py + WORLD_SPAWN_OFFSET_Y, pz)
    local rot = build_identity_rot()
    if not pos or not rot then
        if on_done then on_done(false, "Failed to construct vec3/Quaternion") end
        return
    end

    preload_prefab(im, item_no)

    -- Poll for prefab readiness, then call the 5-arg instantiateItem.
    local started = os.clock()
    local fired = false
    re.on_frame(function()
        if fired then return end
        if is_prefab_ready(im, item_no) then
            fired = true
            local ok, err = pcall(function()
                im:call(
                    "instantiateItem(app.MTData.ITEM_NO, via.vec3, via.Quaternion, System.Action`1<via.GameObject>, via.Folder)",
                    item_no, pos, rot, nil, nil)
            end)
            if on_done then on_done(ok, ok and nil or tostring(err)) end
            return
        end
        if os.clock() - started > WORLD_PRELOAD_TIMEOUT_S then
            fired = true
            if on_done then on_done(false, "Prefab preload timeout") end
        end
    end)
end

------------------------------------------------------------
-- Item Spawning Logic
------------------------------------------------------------

-- Shared pre-checks: cooldown, restricted-mode, time gate, inventory full,
-- and item-no resolution. Returns (game_item_no, item_name) on success, or
-- (nil, err_string) on failure.
local function precheck_spawn(item_entry)
    if not item_entry then return nil, "No item provided" end
    if spawning_disabled then
        return nil, "Spawning disabled (restricted item mode active)"
    end
    if now_time() < global_not_before then
        return nil, "Cooldown active"
    end
    if not ensure_inventory() then
        return nil, "Inventory not available"
    end

    -- Optional "don't spawn before time loads" gate
    if AP and AP.TimeGate and AP.TimeGate.get_current_mdate then
        local ok_tg, mdate = pcall(AP.TimeGate.get_current_mdate)
        if ok_tg and mdate and mdate < 11200 then
            return nil, "Game time not ready"
        end
    end

    if inventory_full_blocks_spawn() then
        return nil, "Inventory full"
    end

    local game_item_no = item_entry.game_item_no
    local item_name    = item_entry.item_name or "Unknown Item"

    if not game_item_no then
        local bridge = get_bridge()
        if bridge and bridge.get_game_item_number then
            game_item_no = bridge.get_game_item_number(item_name)
        end
    end

    if not game_item_no then
        M.log(string.format("No game item number for: %s", item_name))
        return nil, "No game item number mapped"
    end

    return game_item_no, item_name
end

-- Legacy path: Inventory.setEventItem direct injection.
-- Kept for fast revert via SPAWN_PATH = "inventory".
local function try_spawn_item_inventory(item_entry)
    local game_item_no, item_name = precheck_spawn(item_entry)
    if not game_item_no then return false, item_name end

    M.log(string.format("Spawning item (inventory): %s (GameItemNo=%s)",
        tostring(item_name), tostring(game_item_no)))

    local ok, err = pcall(function()
        set_event_method:call(inv_instance, game_item_no, false)
    end)

    if ok then
        M.log("setEventItem succeeded for: " .. tostring(item_name))
        global_not_before = now_time() + SUCCESS_COOLDOWN
        return true, nil
    else
        local err_s = tostring(err)
        M.log("setEventItem FAILED for: " .. tostring(item_name) .. " error: " .. err_s)
        return false, err_s
    end
end

-- New path: ItemManager.instantiateItem 5-arg with auto-preload.
-- Drops the item at the player's feet (offset slightly above floor so it
-- doesn't sink). Async -- the call returns immediately; the actual item
-- appears once the prefab finishes streaming.
local function try_spawn_item_world(item_entry)
    local game_item_no, item_name = precheck_spawn(item_entry)
    if not game_item_no then return false, item_name end

    M.log(string.format("Spawning item (world): %s (GameItemNo=%s)",
        tostring(item_name), tostring(game_item_no)))

    -- Apply the cooldown immediately on dispatch so rapid clicks don't queue
    -- many concurrent spawns. The actual instantiation happens async.
    global_not_before = now_time() + SUCCESS_COOLDOWN

    world_spawn_async(game_item_no, function(ok, err)
        if ok then
            M.log("instantiateItem succeeded for: " .. tostring(item_name))
        else
            M.log(string.format("instantiateItem FAILED for: %s -- %s",
                tostring(item_name), tostring(err)))
        end
    end)

    -- Return optimistically -- async result is logged separately.
    return true, nil
end

-- Dispatcher: routes to the configured spawn path.
local function try_spawn_item(item_entry)
    if SPAWN_PATH == "inventory" then
        return try_spawn_item_inventory(item_entry)
    end
    return try_spawn_item_world(item_entry)
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

--- Restricted-item-mode toggle. When disabled, the Spawn Selected button
--- is greyed out and try_spawn_item returns "spawning disabled".
function M.set_spawning_disabled(disabled)
    spawning_disabled = (disabled == true)
    M.log("Spawning disabled: " .. tostring(spawning_disabled))
end

--- Console-accessible spawn-path toggle. "world" routes through
--- ItemManager.instantiateItem (5-arg) which auto-preloads the prefab and
--- drops the item at the player's feet. "inventory" routes through the
--- legacy Inventory.setEventItem path -- kept as a fast-revert option in
--- case the world path regresses in production.
function M.set_spawn_path(path)
    if path == "world" or path == "inventory" then
        SPAWN_PATH = path
        M.log("SPAWN_PATH set to: " .. path)
    else
        M.log("Invalid spawn path: " .. tostring(path) ..
            " (expected 'world' or 'inventory')")
    end
end

function M.get_spawn_path()
    return SPAWN_PATH
end

------------------------------------------------------------
-- UI: Filter Helper
------------------------------------------------------------

local function get_scoop_unlocker()
    if ScoopUnlocker then return ScoopUnlocker end
    local ok, mod = pcall(require, "DRAP/ScoopUnlocker")
    if ok and mod then
        ScoopUnlocker = mod
        return ScoopUnlocker
    end
    return nil
end

-- Lazy-loaded PlayerStats (covers Progressive *Upgrade* and the 21 SKILL items)
local PlayerStats_mod = nil
local function get_player_stats()
    if PlayerStats_mod then return PlayerStats_mod end
    local ok, mod = pcall(require, "DRAP/effects/PlayerStats")
    if ok and mod then PlayerStats_mod = mod end
    return PlayerStats_mod
end

local function is_effect_item(item_name)
    if not item_name then return false end

    -- Filter out scoop/milestone event items handled by ScoopUnlocker
    local su = get_scoop_unlocker()
    if su and su.is_event_item and su.is_event_item(item_name) then
        return true
    end

    -- Special case for "Hockey Stick"
    if item_name == "Hockey Stick" then
        return false
    end

    if item_name == "Maintenance Tunnel Access Key" then
        return true
    end

    -- Filter out key items
    if string.find(item_name, "key", 1, true) then
        return true
    end

    -- Filter out day/time items (DAY2_06_AM, DAY3_00_AM, etc.)
    if string.find(item_name, "^DAY%d") then
        return true
    end

    -- Filter out PlayerStats-handled items: the 21 skill items + the
    -- Progressive *Upgrade* stat items. These apply via PlayerStats.apply()
    -- on slot-connect/grant; spawning them into the world does nothing.
    local ps = get_player_stats()
    if ps and ps.is_handled_item and ps.is_handled_item(item_name) then
        return true
    end

    -- Filter out Book items ("Book [Title]" pattern). Books grant passive
    -- combat/score modifiers via the Brain item path -- they have no
    -- standalone world prefab worth spawning.
    if string.find(item_name, "^Book %[") then
        return true
    end

    return false
end

local function is_key_item(item_name)
    if not item_name then return false end
    if item_name == "Hockey Stick" then return false end
    return string.find(item_name, "key", 1, true) ~= nil
end

local function matches_filter(entry)
    -- Exclude effect-style items (keys, day items)
    if is_effect_item(entry.item_name) then
        return false
    end

    -- Check text filter
    if filter_text and filter_text ~= "" then
        local lower_filter = string.lower(filter_text)
        local lower_name = string.lower(entry.item_name or "")

        if not string.find(lower_name, lower_filter, 1, true) then
            return false
        end
    end

    return true
end

------------------------------------------------------------
-- UI: Item Window Drawing
------------------------------------------------------------

function M.draw_tab_content(debug)
    local size = imgui.get_window_size()

    -- Get items from bridge
    local received_items = get_received_items_from_bridge()

    -- Build deduplicated list: group by item_name, count occurrences
    local item_counts = {}  -- item_name -> { count = N, first_index = i, entry = entry }
    local unique_names = {}  -- ordered list of unique item names

    for i, entry in ipairs(received_items) do
        local name = entry.item_name or ""
        if matches_filter(entry) then
            if not item_counts[name] then
                item_counts[name] = { count = 0, first_index = i, entry = entry }
                table.insert(unique_names, name)
            end
            item_counts[name].count = item_counts[name].count + 1
        end
    end

    -- Sort alphabetically by item name
    table.sort(unique_names, function(a, b)
        return a:lower() < b:lower()
    end)

    local total = #received_items
    local unique_count = #unique_names

    -- === TOP SECTION: Action buttons and status (fixed at top) ===

    -- Spawn Selected button at the TOP
    local selected_entry = selected_item_name and item_counts[selected_item_name] and item_counts[selected_item_name].entry or nil

    local can_spawn = selected_entry and
                      not inventory_full_blocks_spawn() and
                      ensure_inventory() and
                      not spawning_disabled

    if can_spawn then
        if imgui.button("Spawn Selected") then
            local success, err = try_spawn_item(selected_entry)
            if success then
                M.log("Successfully spawned: " .. tostring(selected_entry.item_name))
            else
                M.log("Spawn failed: " .. tostring(selected_entry.item_name) .. " - " .. tostring(err))
            end
        end
    else
        imgui.push_style_color(21, 0xFF555555)  -- ImGuiCol_Button (grayed out)
        imgui.button("Spawn Selected")
        imgui.pop_style_color(1)
    end

    -- Status messages on same line
    imgui.same_line()
    if selected_entry then
        if spawning_disabled then
            imgui.text_colored("Restricted mode!", 0xFFFF4444)
        elseif inventory_full_blocks_spawn() then
            imgui.text_colored("Inventory full!", 0xFFFF8800)
        elseif not ensure_inventory() then
            imgui.text_colored("Not in-game", 0xFFFF8800)
        else
            imgui.text_colored("Ready", 0xFF44FF44)
        end
    else
        imgui.text_colored("Select an item", 0xFF888888)
    end

    imgui.separator()

    if debug then
        -- Header: Stats
        imgui.text("Items: " .. tostring(total) .. " total, " .. tostring(unique_count) .. " unique")

        -- Inventory status
        local current, maxv = get_inventory_counts()
        if current and maxv then
            imgui.same_line()
            imgui.text(" | Inv: " .. tostring(current) .. "/" .. tostring(maxv))
        end

        -- restricted item mode status
        if spawning_disabled then
            imgui.same_line()
            imgui.text_colored(" | RESTRICTED", 0xFFFF4444)
        end

        -- Filter controls
        imgui.text("Filter:")
        imgui.same_line()
        imgui.push_item_width(size.x - 80)
        local changed, new_filter = imgui.input_text("##filter", filter_text)
        if changed then
            filter_text = new_filter
        end
        imgui.pop_item_width()

        imgui.separator()
    end

    -- === ITEM LIST (scrollable) ===
    local list_height = size.y - (debug and 145 or 80)
    imgui.begin_child_window("ItemList", Vector2f.new(size.x - 16, list_height), true, 0)

    for _, item_name in ipairs(unique_names) do
        local data = item_counts[item_name]
        local is_selected = (selected_item_name == item_name)

        -- Build display text with count if > 1
        local display_text = item_name
        if data.count > 1 then
            display_text = item_name .. " (x" .. tostring(data.count) .. ")"
        end

        -- Selectable row
        if imgui.menu_item(display_text, "", is_selected) then
            if is_selected then
                selected_item_name = nil  -- Deselect on second click
            else
                selected_item_name = item_name
            end
        end
    end

    if unique_count == 0 then
        if total == 0 then
            imgui.text_colored("No items received yet.", 0xFF888888)
        else
            imgui.text_colored("No spawnable items match the filter.", 0xFF888888)
        end
    end

    imgui.end_child_window()
end

------------------------------------------------------------
-- UI: Keys Tab Drawing
------------------------------------------------------------

function M.draw_keys_tab_content(debug)
    local received_items = get_received_items_from_bridge()

    -- Collect key items, deduplicated
    local key_counts = {}   -- name -> { count = N, entry = entry }
    local key_names = {}    -- ordered unique names

    for _, entry in ipairs(received_items) do
        local name = entry.item_name or ""
        if is_key_item(name) then
            if not key_counts[name] then
                key_counts[name] = { count = 0, entry = entry }
                table.insert(key_names, name)
            end
            key_counts[name].count = key_counts[name].count + 1
        end
    end

    table.sort(key_names, function(a, b) return a:lower() < b:lower() end)

    if debug then
        local total_keys = 0
        for _, data in pairs(key_counts) do total_keys = total_keys + data.count end

        imgui.text(string.format("Keys received: %d (%d unique)", total_keys, #key_names))
        imgui.separator()
    end

    -- Key list
    imgui.begin_child_window("KeyList", Vector2f.new(0, 0), true, 0)

    for _, name in ipairs(key_names) do
        local data = key_counts[name]
        local display = name
        if data.count > 1 then
            display = name .. " (x" .. tostring(data.count) .. ")"
        end
        imgui.text_colored(display, 0xFF44DDFF)
    end

    if #key_names == 0 then
        imgui.text_colored("No keys received yet.", 0xFF888888)
    end

    imgui.end_child_window()
end

------------------------------------------------------------
-- Per-frame Update (called from main script)
------------------------------------------------------------

function M.on_frame()
    if not M:should_run() then return end
    ensure_inventory()
end

return M