-- reframework/autorun/AP_DRDR_main.lua
-- Dead Rising Deluxe Remaster - Archipelago Main Entry Point

local game_name = reframework:get_game_name()
if game_name ~= "dd2" then
    re.msg("[DRAP] This script is only for Dead Rising Deluxe Remaster")
    return
end

------------------------------------------------------------
-- Configuration
------------------------------------------------------------

local REDIRECT_SAVE_PATH = true

------------------------------------------------------------
-- Load Modules
------------------------------------------------------------

local AP_BRIDGE = require("ap_drdr_bridge")

AP = AP or {}
AP.AP_BRIDGE        = AP_BRIDGE
AP.ItemSpawner      = require("DRAP/ItemSpawner")
AP.ItemRestriction  = require("DRAP/ItemRestriction")
AP.DoorSceneLock    = require("DRAP/DoorSceneLock")
AP.DoorRandomizer   = require("DRAP/DoorRandomizer")  -- NEW: Door Randomizer
AP.ChallengeTracker = require("DRAP/ChallengeTracker")
AP.LevelTracker     = require("DRAP/LevelTracker")
AP.EventTracker     = require("DRAP/EventTracker")
AP.NpcTracker       = require("DRAP/NpcTracker")
AP.PPStickerTracker = require("DRAP/PPStickerTracker")
AP.SaveSlot         = require("DRAP/SaveSlot")
AP.TimeGate         = require("DRAP/TimeGate")
AP.Scene            = require("DRAP/Scene")
AP.DeathLink        = require("DRAP/DeathLink")

local Shared = require("DRAP/Shared")
local log = Shared.create_logger("DRAP")

------------------------------------------------------------
-- Item Handlers: Auto-register from JSON
------------------------------------------------------------

local function register_spawn_handlers_from_json()
    local items = json.load_file("drdr_items.json")
    if not items then
        log("Failed to load item list JSON")
        return
    end

    local count = 0
    for _, def in ipairs(items) do
        if def.name and def.name ~= "" and def.item_number then
            local ap_item_name = def.name
            local item_no = def.item_number

            -- Register the game item number mapping for the ItemSpawner UI
            AP_BRIDGE.register_game_item_number(ap_item_name, item_no)

            -- Register the handler (for non-spawnable items like keys, this does the actual work)
            AP_BRIDGE.register_item_handler_by_name(ap_item_name, function(net_item, item_name, sender_name)
                log(string.format("Received item '%s' from %s -> item_number=%d",
                    item_name or ap_item_name, tostring(sender_name or "?"), item_no))
                -- Items are tracked by the bridge's RECEIVED_ITEMS list
                -- The ItemSpawner UI reads from bridge.get_all_received_items()

                -- Notify ItemRestriction that new items have been received
                -- This triggers a rescan so the player can pick up newly allowed items
                if AP.ItemRestriction and AP.ItemRestriction.on_items_received then
                    pcall(AP.ItemRestriction.on_items_received)
                end
            end)
            count = count + 1
        end
    end
    log(string.format("Auto-registered %d item handlers and game item mappings from JSON", count))
end

register_spawn_handlers_from_json()

------------------------------------------------------------
-- Item Handlers: Area Keys
------------------------------------------------------------

local AREA_KEYS = {
    { name = "Helipad key",                 scene = "s135" },
    { name = "Safe Room key",               scene = "s136" },
    { name = "Rooftop key",                 scene = "s231" },
    { name = "Service Hallway key",         scene = "s230" },
    { name = "Paradise Plaza key",          scene = "s200" },
    { name = "Colby's Movie Theater key",   scene = "s503" },
    { name = "Leisure Park key",            scene = "s700" },
    { name = "North Plaza key",             scene = "s400" },
    { name = "Crislip's Hardware Store key", scene = "s501" },
    { name = "Food Court key",              scene = "sa00" },
    { name = "Wonderland Plaza key",        scene = "s300" },
    { name = "Al Fresca Plaza key",         scene = "s900" },
    { name = "Entrance Plaza key",          scene = "s100" },
    { name = "Grocery Store key",           scene = "s500" },
    { name = "Maintenance Tunnel key",      scene = "s600" },
    { name = "Hideout key",                 scene = "s401" },
}

for _, key in ipairs(AREA_KEYS) do
    AP_BRIDGE.register_item_handler_by_name(key.name, function(net_item, item_name, sender_name)
        log(string.format("Applying progression item '%s' from %s", tostring(item_name), tostring(sender_name or "?")))
        AP.DoorSceneLock.unlock_scene(key.scene)
    end)
end

------------------------------------------------------------
-- Item Handlers: Time Locks
------------------------------------------------------------

local TIME_CAPS = AP.TimeGate.TIME_CAPS

local TIME_LOCK_CHAIN = {
    { key = "DAY2_06_AM", cap = TIME_CAPS.DAY2_06_AM, unlock = function() AP.TimeGate.unlock_day2_6am() end },
    { key = "DAY2_11_AM", cap = TIME_CAPS.DAY2_11_AM, unlock = function() AP.TimeGate.unlock_day2_11am() end },
    { key = "DAY3_00_AM", cap = TIME_CAPS.DAY3_00_AM, unlock = function() AP.TimeGate.unlock_day3_12am() end },
    { key = "DAY3_11_AM", cap = TIME_CAPS.DAY3_11_AM, unlock = function() AP.TimeGate.unlock_day3_11am() end },
    { key = "DAY4_12_PM", cap = TIME_CAPS.DAY4_12_PM, unlock = function() AP.TimeGate.unlock_all_time() end },
}

local function apply_time_locks_from_ap()
    if not AP.TimeGate.set_time_cap then return end
    if not AP_BRIDGE.has_item_name then return end

    local last_unlocked_index = 0

    for i, step in ipairs(TIME_LOCK_CHAIN) do
        if AP_BRIDGE.has_item_name(step.key) then
            if i == last_unlocked_index + 1 then
                step.unlock()
                last_unlocked_index = i
                log(string.format("Time chain unlocked: %s (step %d/%d)", step.key, i, #TIME_LOCK_CHAIN))
            else
                log(string.format("Time chain blocked: have %s but missing earlier step", step.key))
                break
            end
        else
            break
        end
    end

    if last_unlocked_index >= #TIME_LOCK_CHAIN then
        log("Time chain fully unlocked.")
        return
    end

    local next_step = TIME_LOCK_CHAIN[last_unlocked_index + 1]
    if next_step and next_step.cap then
        AP.TimeGate.set_time_cap(next_step.cap)
        log(string.format("Time cap set to: %s (cap=%s)", next_step.key, tostring(next_step.cap)))
    end
end

local function on_time_item_received(net_item, item_name, sender_name)
    log(string.format("Received time item '%s' from %s; re-evaluating time locks",
        tostring(item_name), tostring(sender_name or "?")))
    apply_time_locks_from_ap()
end

for _, step in ipairs(TIME_LOCK_CHAIN) do
    AP_BRIDGE.register_item_handler_by_name(step.key, on_time_item_received)
end

------------------------------------------------------------
-- Apply Permanent Effects
------------------------------------------------------------

local function apply_permanent_effects_from_ap()
    for _, key in ipairs(AREA_KEYS) do
        if AP_BRIDGE.has_item_name(key.name) then
            AP.DoorSceneLock.unlock_scene(key.scene)
        end
    end
end

------------------------------------------------------------
-- Hook Wiring: Level Tracker
------------------------------------------------------------

AP.LevelTracker.on_level_changed = function(old_level, new_level)
    log(string.format("Level changed %d -> %d", old_level, new_level))
    if new_level > old_level then
        AP.AP_BRIDGE.check(string.format("Reach Level %d", new_level))
    end
end

------------------------------------------------------------
-- Hook Wiring: Event Tracker
------------------------------------------------------------

AP.EventTracker.on_tracked_location = function(desc, source, raw_id, extra)
    log(string.format("Tracked location: %s", tostring(desc)))
    AP.AP_BRIDGE.check(desc)
end

------------------------------------------------------------
-- Hook Wiring: Challenge Tracker
------------------------------------------------------------

AP.ChallengeTracker.on_challenge_threshold = function(field_name, def, idx, target, prev, current, threshold_id)
    local loc_name = threshold_id or string.format("%s_%d", field_name, target or -1)
    log(string.format("Challenge reached [%s] target #%d: %d", tostring(loc_name), idx or -1, target or -1))
    AP.AP_BRIDGE.check(loc_name)
end

------------------------------------------------------------
-- Hook Wiring: Survivor Tracker
------------------------------------------------------------

AP.NpcTracker.on_survivor_rescued = function(npc_id, state_index, friendly_name, game_id)
    log(string.format("Survivor rescued: %s", tostring(friendly_name)))
    AP.AP_BRIDGE.check(string.format("Rescue %s", friendly_name))
end

------------------------------------------------------------
-- Hook Wiring: PP Sticker Tracker
------------------------------------------------------------

AP.PPStickerTracker.on_sticker_event_taked = function(location_name, item_number, photo_id, item_unique_no, having_event)
    log(string.format("PP sticker captured: %s", tostring(location_name)))
    AP.AP_BRIDGE.check(location_name)
end

------------------------------------------------------------
-- Hook Wiring: DeathLink
------------------------------------------------------------

AP.DeathLink.on_death_detected = function()
    if not AP.DeathLinkEnabled then return end

    local player_name = tostring(AP_BRIDGE.AP_REF and AP_BRIDGE.AP_REF.APSlot or "DRDR Player")
    if AP_BRIDGE.send_deathlink then
        AP_BRIDGE.send_deathlink({ cause = player_name .. " died." })
    end
end

------------------------------------------------------------
-- Slot Connection Handler
------------------------------------------------------------

local AP_REF = AP_BRIDGE.AP_REF

local function extract_seed(slot_data)
    return slot_data and (slot_data.seed_name or slot_data.seed or slot_data.seed_id) or "unknown"
end

local prev_on_slot_connected = AP_REF.on_slot_connected
AP_REF.on_slot_connected = function(slot_data)
    if prev_on_slot_connected then pcall(prev_on_slot_connected, slot_data) end

    log(string.format("Slot connected: slot=%s seed=%s",
        tostring(AP_REF.APSlot), extract_seed(slot_data)))

    -- DeathLink option
    local deathlink_enabled = (type(slot_data) == "table" and slot_data.death_link == true)
    AP.DeathLinkEnabled = deathlink_enabled
    AP_BRIDGE.set_deathlink_enabled(deathlink_enabled)
    log("DeathLink enabled=" .. tostring(deathlink_enabled))

    -- Restricted Item Mode (Hard Mode) option
    local restricted_item_mode_enabled = (type(slot_data) == "table" and slot_data.restricted_item_mode == true)
    AP.RestrictedItemModeEnabled = restricted_item_mode_enabled
    AP.ItemRestriction.set_enabled(restricted_item_mode_enabled)
    log("Restricted Item Mode enabled=" .. tostring(restricted_item_mode_enabled))

    -- If hard mode is enabled, disable the item spawner's spawn functionality
    if restricted_item_mode_enabled and AP.ItemSpawner.set_spawning_disabled then
        AP.ItemSpawner.set_spawning_disabled(true)
        log("Item spawning disabled due to hard mode")
    end

    -- Save slot redirect
    if AP.SaveSlot and AP.SaveSlot.apply_for_slot and REDIRECT_SAVE_PATH then
        log("Applying AP save redirect for slot")
        AP.SaveSlot.apply_for_slot(AP_REF.APSlot, extract_seed(slot_data))
    end

    -- Set up received items file
    local slot = AP_REF.APSlot or "unknown"
    local seed = extract_seed(slot_data)
    AP_BRIDGE.set_received_items_filename(slot, seed)
    AP_BRIDGE.load_received_items()

        -- Set up sticker save file
    if AP.PPStickerTracker.set_save_filename then
        AP.PPStickerTracker.set_save_filename(slot, seed)
    end

    -- Sync rescued survivors
    local rescued_survivors = AP.NpcTracker.get_rescued_survivors()
    for id, _ in pairs(rescued_survivors) do
        local name = string.format("Rescue %s", AP.NpcTracker.get_survivor_friendly_name(id) or tostring(id))
        AP_BRIDGE.check(name)
    end
end

------------------------------------------------------------
-- Game Enter Detection
------------------------------------------------------------

local was_in_game = false
local pending_reapply_check = false
local reapply_done = false

local function on_enter_game()
    log("Entered gameplay")
    pending_reapply_check = true
    reapply_done = false
end

local function try_reapply_items_if_ready()
    if not pending_reapply_check or reapply_done then return end

    if not AP.ItemSpawner.inventory_system_running() then return end

    if AP.TimeGate and AP.TimeGate.is_new_game and AP.TimeGate.is_new_game() then
        log("New game confirmed; reapplying AP items")
        AP_BRIDGE.reapply_all_items()
    end

    apply_permanent_effects_from_ap()
    apply_time_locks_from_ap()

    reapply_done = true
    pending_reapply_check = false
end

------------------------------------------------------------
-- Main Frame Loop
------------------------------------------------------------

local function safe_on_frame(mod, name)
    if mod and type(mod.on_frame) == "function" then
        local ok = pcall(mod.on_frame)
        if not ok then log(name .. ".on_frame error suppressed") end
    end
end

re.on_frame(function()
    local ok_ig, now_in_game = pcall(AP.Scene.isInGame)
    if not ok_ig or not now_in_game then
        was_in_game = false
        return
    end

    -- Update all modules
    safe_on_frame(AP.ItemSpawner,      "ItemSpawner")
    safe_on_frame(AP.ItemRestriction,  "ItemRestriction")
    safe_on_frame(AP.DoorSceneLock,    "DoorSceneLock")
    safe_on_frame(AP.DoorRandomizer,   "DoorRandomizer")
    safe_on_frame(AP.NpcInvestigation, "NpcInvestigation")
    safe_on_frame(AP.ChallengeTracker, "ChallengeTracker")
    safe_on_frame(AP.LevelTracker,     "LevelTracker")
    safe_on_frame(AP.EventTracker,     "EventTracker")
    safe_on_frame(AP.NpcTracker,       "NpcTracker")
    safe_on_frame(AP.TimeGate,         "TimeGate")
    safe_on_frame(AP.DeathLink,        "DeathLink")
    safe_on_frame(AP.AP_BRIDGE,        "AP_BRIDGE")
    safe_on_frame(AP.PPStickerTracker, "PPStickerTracker")

    -- Enter-game edge detection
    if now_in_game and not was_in_game then
        pcall(on_enter_game)
    end
    was_in_game = now_in_game

    try_reapply_items_if_ready()
end)

------------------------------------------------------------
-- Console Helpers
------------------------------------------------------------

_G.ap_spawn_item = function(item_no) AP.ItemSpawner.add_received_item(item_no, "Test Item", "Console") end
_G.lock_scene    = function(code) AP.DoorSceneLock.lock_scene(code) end
_G.unlock_scene  = function(code) AP.DoorSceneLock.unlock_scene(code) end
_G.list_rescued  = function()
    for id, _ in pairs(AP.NpcTracker.get_rescued_survivors()) do
        print("Rescued:", id, "game_id:", AP.NpcTracker.get_survivor_game_id(id))
    end
end
_G.death_link = function() AP.DeathLink.kill_player("manual") end
_G.freeze     = function() AP.TimeGate.enable() end
_G.cap        = function(code) AP.TimeGate.set_time_cap_mdate(code) end
_G.show_items = function() AP.ItemSpawner.show_window() end
_G.hide_items = function() AP.ItemSpawner.hide_window() end

------------------------------------------------------------
-- Door Randomizer Console Helpers (NEW)
------------------------------------------------------------

-- Show captured doors summary
_G.doors = function()
    AP.DoorRandomizer.print_captured_doors_summary()
end

-- Show recent door transitions
_G.transitions = function()
    AP.DoorRandomizer.print_recent_transitions()
end

-- Enable door randomization
_G.enable_door_rando = function()
    AP.DoorRandomizer.enable_randomization()
end

-- Disable door randomization
_G.disable_door_rando = function()
    AP.DoorRandomizer.disable_randomization()
end

-- Clear all redirects
_G.clear_redirects = function()
    AP.DoorRandomizer.clear_all_redirects()
end

-- Get all captured door data (returns table)
_G.get_doors = function()
    return AP.DoorRandomizer.get_captured_doors()
end

-- Show door randomizer status
_G.door_status = function()
    AP.DoorRandomizer.print_status()
end

-- Retry hook installation if it failed
_G.retry_door_hook = function()
    AP.DoorRandomizer.retry_hook_install()
end

-- Print HIT_DATA fields
_G.hit_data_fields = function()
    AP.DoorRandomizer.print_hit_data_fields()
end

-- Print full details of the last door transition
_G.last_door = function()
    AP.DoorRandomizer.print_last_transition_details()
end

-- Print all active redirects
_G.redirects = function()
    AP.DoorRandomizer.print_redirects()
end

-- Quick redirect: redirect("SCN_s136|s135|door0", "s200")
-- This would make the Safe Room -> Helipad door go to Paradise Plaza instead
_G.redirect = function(source_door_id, target_area)
    AP.DoorRandomizer.set_redirect(source_door_id, target_area)
end

-- Copy redirect from another door's destination
_G.redirect_like = function(source_door_id, template_door_id)
    AP.DoorRandomizer.set_redirect_from_door(source_door_id, template_door_id)
end

-- Show/hide door randomizer GUI window
_G.show_doors_gui = function()
    AP.DoorRandomizer.show_window()
end

_G.hide_doors_gui = function()
    AP.DoorRandomizer.hide_window()
end

_G.toggle_doors_gui = function()
    AP.DoorRandomizer.toggle_window()
end

-- Save/load door data manually
_G.save_doors = function()
    AP.DoorRandomizer.save_doors()
end

_G.load_doors = function()
    AP.DoorRandomizer.load_doors()
end

_G.save_redirects = function()
    AP.DoorRandomizer.save_redirects()
end

_G.load_redirects = function()
    AP.DoorRandomizer.load_redirects()
end

-- Set description for a door
-- Usage: describe_door("SCN_s136|s200|door0", "Safe Room to Paradise Plaza main door")
_G.describe_door = function(door_id, description)
    AP.DoorRandomizer.set_door_description(door_id, description)
end

-- Print doors grouped by area (compact view)
_G.doors_by_area = function()
    AP.DoorRandomizer.print_doors_by_area()
end

-- Export doors summary (returns table for inspection)
_G.export_doors = function()
    local summary = AP.DoorRandomizer.export_doors_summary()
    for _, door in ipairs(summary) do
        print(string.format("%s -> %s [%s] (uses: %d)",
            door.from, door.to, door.description, door.uses))
    end
    return summary
end

-- Show NPC Investigation status
_G.npc_status = function()
    AP.NpcInvestigation.print_status()
end

-- Print recent replaceNpc calls
_G.npc_replace_calls = function()
    AP.NpcInvestigation.print_recent_replace_calls()
end

-- Print recent NPC transitions (from List.Add)
_G.npc_transitions = function()
    AP.NpcInvestigation.print_recent_npc_transitions()
end

-- Print all captured NPCs
_G.npcs = function()
    AP.NpcInvestigation.print_captured_npcs()
end

-- Print the last NPC transition details
_G.last_npc = function()
    AP.NpcInvestigation.print_last_transition()
end

-- Print the last replaceNpc call details
_G.last_replace = function()
    AP.NpcInvestigation.print_last_replace_call()
end

-- Print NpcReplaceInfo fields discovered
_G.npc_fields = function()
    AP.NpcInvestigation.print_replace_info_fields()
end

-- Retry hook installation
_G.retry_npc_hook = function()
    AP.NpcInvestigation.retry_hook_install()
end

-- Show/hide NPC Investigation GUI window
_G.show_npc_gui = function()
    AP.NpcInvestigation.show_window()
end

_G.hide_npc_gui = function()
    AP.NpcInvestigation.hide_window()
end

_G.toggle_npc_gui = function()
    AP.NpcInvestigation.toggle_window()
end

-- Save/load NPC data
_G.save_npcs = function()
    AP.NpcInvestigation.save_npcs()
end

_G.load_npcs = function()
    AP.NpcInvestigation.load_npcs()
end

-- Enable/disable debug mode for verbose logging
_G.npc_debug = function(enabled)
    if enabled == nil then enabled = true end
    AP.NpcInvestigation.set_debug_mode(enabled)
end

-- Get raw data tables (for inspection in console)
_G.get_npc_transitions = function()
    return AP.NpcInvestigation.get_recent_npc_transitions()
end

_G.get_replace_calls = function()
    return AP.NpcInvestigation.get_recent_replace_calls()
end

_G.get_captured_npcs = function()
    return AP.NpcInvestigation.get_captured_npcs()
end

-- Explore NpcManager fields and methods
_G.explore_npc_mgr = function()
    AP.NpcInvestigation.explore_npc_manager()
end

log("Main script loaded.")