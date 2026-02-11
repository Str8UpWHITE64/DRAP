-- reframework/autorun/AP_DRDR_main.lua
-- Dead Rising Deluxe Remaster - Archipelago Main Entry Point

local game_name = reframework:get_game_name()
if game_name ~= "dd2" then
    re.msg("[DRAP] This script is only for Dead Rising Deluxe Remaster")
    return
end

------------------------------------------------------------
-- Load Modules
------------------------------------------------------------

local AP_BRIDGE = require("ap_drdr_bridge")

AP = AP or {}
AP.AP_BRIDGE        = AP_BRIDGE
AP.ItemSpawner      = require("DRAP/ItemSpawner")
AP.ItemRestriction  = require("DRAP/ItemRestriction")
AP.DoorSceneLock    = require("DRAP/DoorSceneLock")
AP.DoorRandomizer   = require("DRAP/DoorRandomizer")
AP.NpcCarryover     = require("DRAP/NpcCarryover")
AP.ChallengeTracker = require("DRAP/ChallengeTracker")
AP.LevelTracker     = require("DRAP/LevelTracker")
AP.EventTracker     = require("DRAP/EventTracker")
AP.NpcTracker       = require("DRAP/NpcTracker")
AP.PPStickerTracker = require("DRAP/PPStickerTracker")
AP.SaveSlot         = require("DRAP/SaveSlot")
AP.TimeGate         = require("DRAP/TimeGate")
AP.Scene            = require("DRAP/Scene")
AP.DeathLink        = require("DRAP/DeathLink")

AP.EventFlagExplorer = require("DRAP/EventFlagExplorer")
AP.GameEventTracker  = require("DRAP/GameEventTracker")
AP.EventFlagDumper   = require("DRAP/EventFlagDumper")
AP.ScoopExplorer     = require("DRAP/ScoopExplorer")
AP.NpcInvestigator   = require("DRAP/NpcInvestigator")
AP.NpcSpawner        = require("DRAP/NpcSpawner")
AP.ScoopUnlocker     = require("DRAP/ScoopUnlocker")

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
AP.ScoopUnlocker.register_with_ap_bridge(AP_BRIDGE)

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
-- Victory Handler
------------------------------------------------------------

AP_BRIDGE.register_item_handler_by_name("Victory", function(net_item, item_name, sender_name)
    log("Victory received! Sending goal completion to server...")
    AP_BRIDGE.send_goal_complete()
end)

------------------------------------------------------------
-- Apply Permanent Effects
------------------------------------------------------------

local function apply_permanent_effects_from_ap()
    for _, key in ipairs(AREA_KEYS) do
        if AP_BRIDGE.has_item_name(key.name) then
            AP.DoorSceneLock.unlock_scene(key.scene)
        end
    end
    AP.ScoopUnlocker.reapply_unlocked_scoops()
end

------------------------------------------------------------
-- Hook Wiring: Level Tracker
------------------------------------------------------------

AP.LevelTracker.on_level_changed = function(old_level, new_level)
    log(string.format("Level changed %d -> %d", old_level, new_level))
    if new_level > old_level then
        AP_BRIDGE.check(string.format("Reach Level %d", new_level))
    end
end

------------------------------------------------------------
-- Hook Wiring: Event Tracker
------------------------------------------------------------

AP.EventTracker.on_tracked_location = function(desc, source, raw_id, extra)
    -- Don't send checks if ScoopUnlocker is currently enabling flags
    -- (This prevents false completions when we unlock a mission)
    if AP.ScoopUnlocker and AP.ScoopUnlocker.is_currently_unlocking() then
        log(string.format("Ignoring tracked location '%s' (ScoopUnlocker is unlocking)", tostring(desc)))
        return
    end

    log(string.format("Tracked location: %s", tostring(desc)))
    AP.AP_BRIDGE.check(desc)

    -- Forward events to ScoopUnlocker for milestone/chain tracking
    if AP.ScoopUnlocker and AP.ScoopUnlocker.on_event_tracked then
        pcall(AP.ScoopUnlocker.on_event_tracked, desc)
    end
end

------------------------------------------------------------
-- Hook Wiring: Challenge Tracker
------------------------------------------------------------

AP.ChallengeTracker.on_challenge_threshold = function(field_name, def, idx, target, prev, current, threshold_id)
    local loc_name = threshold_id or string.format("%s_%d", field_name, target or -1)
    log(string.format("Challenge reached [%s] target #%d: %d", tostring(loc_name), idx or -1, target or -1))
    AP_BRIDGE.check(loc_name)
end

------------------------------------------------------------
-- Hook Wiring: Survivor Tracker
------------------------------------------------------------

AP.NpcTracker.on_survivor_rescued = function(npc_id, state_index, friendly_name, game_id)
    log(string.format("Survivor rescued: %s", tostring(friendly_name)))
    AP_BRIDGE.check(string.format("Rescue %s", friendly_name))
end

------------------------------------------------------------
-- Hook Wiring: PP Sticker Tracker
------------------------------------------------------------

AP.PPStickerTracker.on_sticker_event_taked = function(location_name, item_number, photo_id, item_unique_no, having_event)
    log(string.format("PP sticker captured: %s", tostring(location_name)))
    AP_BRIDGE.check(location_name)
end

------------------------------------------------------------
-- Hook Wiring: ScoopUnlocker
------------------------------------------------------------

-- When ScoopUnlocker detects a scoop completion via its flag hook,
-- send the corresponding AP location check
AP.ScoopUnlocker.set_completion_callback(function(event_desc, flag_id, scoop_name)
    log(string.format("Scoop completion detected: '%s' (flag %d, scoop '%s')",
        tostring(event_desc), flag_id or 0, tostring(scoop_name)))
    AP_BRIDGE.check(event_desc)
end)

-- When AP enforcement activates (Meet Jessie milestone), log it
AP.ScoopUnlocker.set_ap_activated_callback(function()
    log("ScoopUnlocker: AP enforcement activated")
end)

-- When time freeze triggers (Get to the Stairs! milestone), apply it
-- Only used in ScoopSanity mode — time is frozen indefinitely until scoops progress
AP.ScoopUnlocker.set_time_freeze_callback(function()
    if not AP.ScoopSanityEnabled then
        log("ScoopUnlocker: Time freeze milestone hit but ScoopSanity disabled, ignoring")
        return
    end
    log("ScoopUnlocker: Time freeze triggered (ScoopSanity)")
    AP.TimeGate.enable()
end)

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

local function extract_seed(slot_data)
    local raw = slot_data and (slot_data.seed_name or slot_data.seed or slot_data.seed_id) or "unknown"
    return Shared.clean_string(raw)
end

local prev_on_slot_connected = AP_BRIDGE.AP_REF.on_slot_connected
AP_BRIDGE.AP_REF.on_slot_connected = function(slot_data)
    if prev_on_slot_connected then pcall(prev_on_slot_connected, slot_data) end

    local slot = Shared.clean_string(AP_BRIDGE.AP_REF.APSlot or "unknown")
    local seed = extract_seed(slot_data)

    log("Slot connected: slot=" .. slot .. " seed=" .. seed)

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

    -- Door Randomizer option
    local door_randomizer_enabled = (type(slot_data) == "table" and slot_data.door_randomizer == true)
    AP.DoorRandomizerEnabled = door_randomizer_enabled
    log("Door Randomizer enabled=" .. tostring(door_randomizer_enabled))

    -- Apply door redirects if enabled
    if door_randomizer_enabled and AP.DoorRandomizer then
        local door_redirects = slot_data.door_redirects
        if door_redirects then
            AP.DoorRandomizer.set_redirects(door_redirects)
            log("Door randomization activated with " .. tostring(AP.DoorRandomizer.get_redirect_config_count()) .. " redirects")
        else
            AP.DoorRandomizer.clear_redirects()
            log("Door randomizer enabled but no redirects provided")
        end
    elseif AP.DoorRandomizer then
        AP.DoorRandomizer.clear_redirects()
    end

    -- ScoopSanity option
    local scoop_sanity_enabled = (type(slot_data) == "table" and slot_data.scoop_sanity == true)
    AP.ScoopSanityEnabled = scoop_sanity_enabled
    log("ScoopSanity enabled=" .. tostring(scoop_sanity_enabled))

    -- Set up ScoopUnlocker persistence and ordering
    AP.ScoopUnlocker.set_save_filename(slot, seed)
    AP.ScoopUnlocker.load_save()

    if scoop_sanity_enabled then
        -- Apply randomized main scoop order from server
        local scoop_order = slot_data.scoop_order
        if scoop_order and type(scoop_order) == "table" and #scoop_order > 0 then
            AP.ScoopUnlocker.set_scoop_order(scoop_order)
            log("Scoop order set with " .. tostring(#scoop_order) .. " entries")
        else
            log("WARNING: ScoopSanity enabled but no scoop_order in slot data")
        end
    end

    -- Save slot redirect (controlled via AP_REF.APSaveRedirect in connection window)
    if AP.SaveSlot and AP.SaveSlot.apply_for_slot and AP_BRIDGE.AP_REF.APSaveRedirect then
        log("Applying AP save redirect for slot")
        AP.SaveSlot.apply_for_slot(slot, seed)
    end

    -- Reset received items file for a fresh sync from the server.
    -- This ensures any previously corrupted item data is discarded and
    -- rebuilt from the authoritative server replay.
    AP_BRIDGE.set_received_items_filename(slot, seed)
    AP_BRIDGE.reset_received_items()

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
local pending_reapply = false

local function on_enter_game()
    log("Entered gameplay")
    pending_reapply = true
end

local function try_reapply_if_ready()
    if not pending_reapply then return end
    if not AP.ItemSpawner.inventory_system_running() then return end

    log("Reapplying AP items")
    AP_BRIDGE.reapply_all_items()
    AP.ScoopUnlocker.reapply_unlocked_scoops()
    apply_permanent_effects_from_ap()
    apply_time_locks_from_ap()

    -- ScoopSanity: restore indefinite time freeze if milestone was reached
    if AP.ScoopSanityEnabled and AP.ScoopUnlocker.is_time_frozen() then
        AP.TimeGate.enable()
        log("Restored time freeze from saved milestone (ScoopSanity)")
    end

    pending_reapply = false
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
    safe_on_frame(AP.NpcCarryover,     "NpcCarryover")
    safe_on_frame(AP.ChallengeTracker, "ChallengeTracker")
    safe_on_frame(AP.LevelTracker,     "LevelTracker")
    safe_on_frame(AP.EventTracker,     "EventTracker")
    safe_on_frame(AP.NpcTracker,       "NpcTracker")
    safe_on_frame(AP.TimeGate,         "TimeGate")
    safe_on_frame(AP.DeathLink,        "DeathLink")
    safe_on_frame(AP.AP_BRIDGE,        "AP_BRIDGE")
    safe_on_frame(AP.PPStickerTracker, "PPStickerTracker")
    safe_on_frame(AP.SaveSlot,         "SaveSlot")

    safe_on_frame(AP.GameEventTracker,  "GameEventTracker")
    safe_on_frame(AP.EventFlagExplorer, "EventFlagExplorer")
    safe_on_frame(AP.NpcInvestigator,  "NpcInvestigator")
    safe_on_frame(AP.NpcSpawner,       "NpcSpawner")

    -- Enter-game edge detection
    if now_in_game and not was_in_game then
        pcall(on_enter_game)
    end
    was_in_game = now_in_game

    try_reapply_if_ready()
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
_G.cap        = function(code) AP.TimeGate.set_time_cap(code) end
_G.show_items = function() AP.ItemSpawner.show_window() end
_G.hide_items = function() AP.ItemSpawner.hide_window() end


log("Main script loaded.")