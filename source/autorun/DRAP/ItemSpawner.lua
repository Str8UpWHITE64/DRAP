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

-- Currently selected item index in the UI
local selected_item_index = nil

-- UI State
local mainWindowVisible = false
local showMainWindow = true

-- Filter options
local filter_text = ""

-- Reference to bridge module
local AP_BRIDGE = nil

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

    -- Try to get from AP global
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
-- Item Spawning Logic
------------------------------------------------------------

local function try_spawn_item(item_entry)
    if not item_entry then return false, "No item provided" end

    -- Check if spawning is disabled (restricted item mode)
    if spawning_disabled then
        return false, "Spawning disabled (restricted item mode active)"
    end

    local t = now_time()
    if t < global_not_before then
        return false, "Cooldown active"
    end

    if not ensure_inventory() then
        return false, "Inventory not available"
    end

    -- Optional "don't spawn before time loads" gate
    if AP and AP.TimeGate and AP.TimeGate.get_current_mdate then
        local ok_tg, mdate = pcall(AP.TimeGate.get_current_mdate)
        if ok_tg and mdate and mdate <= 11200 then
            return false, "Game time not ready"
        end
    end

    if not can_accept_more_items() then
        return false, "Inventory full"
    end

    -- Get the game item number - try stored value first, then lookup by name
    local game_item_no = item_entry.game_item_no
    local item_name = item_entry.item_name or "Unknown Item"

    -- If no game_item_no stored, try to look it up from the bridge
    if not game_item_no then
        local bridge = get_bridge()
        if bridge and bridge.get_game_item_number then
            game_item_no = bridge.get_game_item_number(item_name)
        end
    end

    if not game_item_no then
        M.log(string.format("No game item number for: %s", item_name))
        return false, "No game item number mapped"
    end

    M.log(string.format("Spawning item: %s (GameItemNo=%s)",
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

------------------------------------------------------------
-- Public API
------------------------------------------------------------

--- Gets the count of items from the bridge
--- @return number The count
function M.item_count()
    local items = get_received_items_from_bridge()
    return #items
end

--- Gets all received items from the bridge
--- @return table The items list
function M.get_received_items()
    return get_received_items_from_bridge()
end

--- Clears selection
function M.clear_selection()
    selected_item_index = nil
    M.log("Cleared selection")
end

--- Gets the current item count
--- @return number The count
function M.pending_count()
    return M.item_count()
end

------------------------------------------------------------
-- Restricted item mode: Spawning Control Public API
------------------------------------------------------------

--- Sets whether spawning is disabled (for restricted item mode)
--- @param disabled boolean Whether to disable spawning
function M.set_spawning_disabled(disabled)
    spawning_disabled = (disabled == true)
    M.log("Spawning disabled: " .. tostring(spawning_disabled))
end

--- Gets whether spawning is disabled
--- @return boolean True if spawning is disabled
function M.is_spawning_disabled()
    return spawning_disabled
end

------------------------------------------------------------
-- UI: Filter Helper
------------------------------------------------------------

local function is_effect_item(item_name)
    if not item_name then return false end

    -- Special case for "Hockey Stick"
    if item_name == "Hockey Stick" then
        return false
    end

    -- Filter out key items
    if string.find(item_name, "key", 1, true) then
        return true
    end

    -- Filter out day/time items (DAY2_06_AM, DAY3_00_AM, etc.)
    if string.find(item_name, "^DAY%d") then
        return true
    end

    return false
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

local function draw_item_window()
    if not mainWindowVisible then return end

    imgui.set_next_window_size(Vector2f.new(400, 350), 4)  -- 4 = ImGuiCond_FirstUseEver

    if showMainWindow then
        showMainWindow = imgui.begin_window("Archipelago Items", showMainWindow, 0)
    else
        imgui.begin_window("Archipelago Items", nil, 0)
    end

    local size = imgui.get_window_size()

    -- Get items from bridge
    local received_items = get_received_items_from_bridge()

    -- Build filtered and sorted list
    local filtered_items = {}
    for i, entry in ipairs(received_items) do
        if matches_filter(entry) then
            table.insert(filtered_items, { index = i, entry = entry })
        end
    end

    -- Sort alphabetically by item name
    table.sort(filtered_items, function(a, b)
        local name_a = (a.entry.item_name or ""):lower()
        local name_b = (b.entry.item_name or ""):lower()
        return name_a < name_b
    end)

    local total = #received_items
    local filtered_count = #filtered_items

    -- Header: Stats
    imgui.text(string.format("Items: %d (showing %d)", total, filtered_count))

    -- Inventory status
    local current, maxv = get_inventory_counts()
    if current and maxv then
        imgui.same_line()
        imgui.text(string.format(" | Inventory: %d / %d", current, maxv))
    else
        imgui.same_line()
        imgui.text_colored(" | Inventory: N/A", 0xFF8888FF)
    end

    -- restricted item mode status
    if spawning_disabled then
        imgui.same_line()
        imgui.text_colored(" | RESTRICTED ITEM MODE", 0xFFFF4444)  -- Red
    end

    imgui.separator()

    -- Filter controls
    imgui.text("Filter:")
    imgui.same_line()
    imgui.push_item_width(200)
    local changed, new_filter = imgui.input_text("##filter", filter_text)
    if changed then
        filter_text = new_filter
    end
    imgui.pop_item_width()

    imgui.separator()

    -- Item list
    local list_height = size.y - 120  -- Leave room for button at bottom
    imgui.begin_child_window("ItemList", Vector2f.new(size.x - 16, list_height), true, 0)

    for _, item_data in ipairs(filtered_items) do
        local i = item_data.index
        local entry = item_data.entry
        local is_selected = (selected_item_index == i)

        -- Build display text (just item name)
        local display_text = entry.item_name or ("Item #" .. tostring(entry.item_id))

        -- Use a small button for selection, then text
        local button_label = is_selected and "> " or "  "
        if imgui.button(button_label .. "##sel" .. tostring(i)) then
            if is_selected then
                selected_item_index = nil  -- Deselect on second click
            else
                selected_item_index = i
            end
        end
        imgui.same_line()

        -- Show item text with color based on selection
        if is_selected then
            imgui.text_colored(display_text, 0xFF00FFFF)  -- Cyan for selected
        else
            imgui.text(display_text)
        end
    end

    if filtered_count == 0 then
        if total == 0 then
            imgui.text_colored("No items received yet.", 0xFF888888)
        else
            imgui.text_colored("No spawnable items match the filter.", 0xFF888888)
        end
    end

    imgui.end_child_window()

    imgui.separator()

    -- Action button
    local selected_entry = selected_item_index and received_items[selected_item_index] or nil

    -- Spawn Selected button
    -- In restricted item mode, spawning is disabled - items must be picked up from the world
    local can_spawn = selected_entry and
                      can_accept_more_items() and
                      ensure_inventory() and
                      not spawning_disabled

    if can_spawn then
        if imgui.button("Spawn Selected") then
            local success, err = try_spawn_item(selected_entry)
            if success then
                M.log("Successfully spawned: " .. tostring(selected_entry.item_name))
                -- Deselect after successful spawn
                selected_item_index = nil
            else
                M.log(string.format("Spawn failed: %s - %s",
                    tostring(selected_entry.item_name), tostring(err)))
            end
        end
    else
        imgui.push_style_color(21, 0xFF555555)  -- ImGuiCol_Button (grayed out)
        imgui.button("Spawn Selected")
        imgui.pop_style_color(1)
    end

    -- Status messages
    if selected_entry then
        imgui.same_line()
        if spawning_disabled then
            imgui.text_colored("Restricted item mode: pick up items in world!", 0xFFFF4444)
        elseif not can_accept_more_items() then
            imgui.text_colored("Inventory full!", 0xFFFF8800)
        elseif not ensure_inventory() then
            imgui.text_colored("Not in-game", 0xFFFF8800)
        end
    end

    imgui.end_window()
end

------------------------------------------------------------
-- UI Toggle (Public API)
------------------------------------------------------------

function M.show_window()
    showMainWindow = true
end

function M.hide_window()
    showMainWindow = false
end

function M.toggle_window()
    showMainWindow = not showMainWindow
end

function M.is_window_visible()
    return showMainWindow
end

------------------------------------------------------------
-- Per-frame Update (called from main script)
------------------------------------------------------------

function M.on_frame()
    if not M:should_run() then return end
    ensure_inventory()
end

------------------------------------------------------------
-- REFramework Hooks
------------------------------------------------------------

re.on_frame(function()
    if mainWindowVisible then
        draw_item_window()
    end
end)

re.on_draw_ui(function()
    local changed
    changed, showMainWindow = imgui.checkbox("Show AP Items Window", showMainWindow)
    if changed then
        -- Checkbox was toggled
    end
end)

re.on_pre_application_entry("UpdateBehavior", function()
    if reframework:is_drawing_ui() and showMainWindow then
        mainWindowVisible = true
    else
        mainWindowVisible = false
    end
end)

return M