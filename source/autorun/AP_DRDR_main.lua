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

local AP_BRIDGE = require("DRAP/Bridge")

AP = AP or {}
AP.AP_BRIDGE        = AP_BRIDGE
AP.ItemSpawner      = require("DRAP/ItemSpawner")
AP.ItemRestriction  = require("DRAP/ItemRestriction")
AP.DoorSceneLock    = require("DRAP/DoorSceneLock")
AP.DoorRandomizer   = require("DRAP/DoorRandomizer")
AP.DoorVisualizer   = require("DRAP/DoorVisualizer")
AP.NpcCarryover     = require("DRAP/NpcCarryover")
AP.ChallengeTracker = require("DRAP/trackers/ChallengeTracker")
AP.LevelTracker     = require("DRAP/trackers/LevelTracker")
AP.EventTracker     = require("DRAP/trackers/EventTracker")
AP.NpcTracker       = require("DRAP/trackers/NpcTracker")
AP.PPStickerTracker = require("DRAP/trackers/PPStickerTracker")
AP.SaveSlot         = require("DRAP/SaveSlot")
AP.TimeGate         = require("DRAP/TimeGate")
AP.Scene            = require("DRAP/Scene")
AP.DeathLink        = require("DRAP/trackers/DeathLink")
AP.ScoopUnlocker     = require("DRAP/ScoopUnlocker")
AP.SceneFixups       = require("DRAP/SceneFixups")
AP.GUI               = require("DRAP/GUI")
AP.Notify            = require("DRAP/Notify")
AP.MsgEvents         = require("DRAP/MsgEvents")

-- Debug modules. Noisy output (per-flag prints) and JSON persistence inside
-- EventFlagExplorer gate themselves on GUI's "Debug Mode" checkbox.
AP.EventFlagExplorer = require("DRAP/debug/EventFlagExplorer")

local Shared = require("DRAP/Shared")
local SharedData = require("DRAP/SharedData")
local log = Shared.create_logger("DRAP")

------------------------------------------------------------
-- Item Handlers: Auto-register from JSON
------------------------------------------------------------

local function register_spawn_handlers_from_json()
    local items = SharedData.items()
    if not items or #items == 0 then
        log("Failed to load item list from SharedData")
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

do
    local ItemEffects = require("DRAP/ItemEffects")
    local counts = ItemEffects.get_silent_overwrite_counts()
    if counts.names > 0 or counts.ids > 0 then
        log(string.format(
            "Item handler registrations: %d duplicate display names overwrote earlier entries (pre-existing data; last wins)",
            counts.names))
    end
end

------------------------------------------------------------
-- Item Effect Modules
------------------------------------------------------------
-- Each effect module registers its own handlers via ItemEffects.register(...)
-- and exposes an optional reapply() for the save-load path. Add new effect
-- files under DRAP/effects/ and wire them here.

AP.effects = AP.effects or {}
AP.effects.AreaKeyEffects             = require("DRAP/effects/AreaKeyEffects")
AP.effects.TimeLockEffects            = require("DRAP/effects/TimeLockEffects")
AP.effects.VictoryEffects             = require("DRAP/effects/VictoryEffects")
AP.effects.SurvivorScoopCompletion    = require("DRAP/effects/SurvivorScoopCompletion")
AP.effects.SaviorGoalEffects          = require("DRAP/effects/SaviorGoalEffects")
AP.effects.BookSkills                 = require("DRAP/effects/BookSkills")
AP.effects.BookGuards                 = require("DRAP/effects/BookGuards")
AP.effects.PlayerStats                = require("DRAP/effects/PlayerStats")
AP.effects.PlayerBuffs                = require("DRAP/effects/PlayerBuffs")
AP.effects.HostileSurvivorTrap        = require("DRAP/effects/HostileSurvivorTrap")
AP.effects.ZombieEffects              = require("DRAP/effects/ZombieEffects")
AP.effects.CostumeRandomizer          = require("DRAP/effects/CostumeRandomizer")
AP.effects.AP_LocationTriggers        = require("DRAP/effects/AP_LocationTriggers")
AP.effects.DoorPromptOverlay          = require("DRAP/effects/DoorPromptOverlay")

AP.effects.AreaKeyEffects.register_all()
AP.effects.TimeLockEffects.register_all()
AP.effects.VictoryEffects.register_all()
AP.effects.SurvivorScoopCompletion.register_all()
AP.effects.SaviorGoalEffects.register_all()
AP.effects.BookSkills.register_all()
AP.effects.BookGuards.register_all()
AP.effects.PlayerStats.register()
AP.effects.PlayerBuffs.register()
AP.effects.HostileSurvivorTrap.register()
AP.effects.ZombieEffects.register()
AP.effects.CostumeRandomizer.register()
AP.effects.AP_LocationTriggers.register()
AP.effects.DoorPromptOverlay.register()

-- Per-scene fixups (e.g. disable s136 safe-room barricade once Jessie is met
-- under ScoopSanity). Hooks AreaManager.onLoadMapEvent.
AP.SceneFixups.register()

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
    if AP.effects.SurvivorScoopCompletion then
        AP.effects.SurvivorScoopCompletion.on_survivor_rescued(friendly_name)
    end
    if AP.effects.SaviorGoalEffects then
        AP.effects.SaviorGoalEffects.on_survivor_rescued(friendly_name)
    end
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
-- Only used in ScoopSanity mode -- time is frozen indefinitely until scoops progress
AP.ScoopUnlocker.set_time_freeze_callback(function()
    log("ScoopUnlocker: Time freeze triggered (ScoopSanity)")
    AP.TimeGate.enable()
end)

AP.ScoopUnlocker.set_time_unfreeze_callback(function()
    log("ScoopUnlocker: Time unfreeze triggered (ScoopSanity)")
    AP.TimeGate.disable()
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
    AP.ScoopUnlocker.set_door_randomizer_enabled(door_randomizer_enabled)
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

    -- Goal option
    local goal = (type(slot_data) == "table" and slot_data.goal) or 0
    AP.Goal = goal
    local goal_names = { [0] = "Ending S", [1] = "Ending A", [2] = "Savior" }
    log("Goal: " .. (goal_names[goal] or tostring(goal)))

    -- Number of survivors (only meaningful when goal == 2, Savior)
    AP.NumberOfSurvivors = (type(slot_data) == "table" and tonumber(slot_data.number_of_survivors)) or 35
    if goal == 2 then
        log("Savior target: " .. tostring(AP.NumberOfSurvivors) .. " survivors")
    end

    -- ScoopSanity option
    local scoop_sanity_enabled = (type(slot_data) == "table" and slot_data.scoop_sanity == true)
    AP.ScoopSanityEnabled = scoop_sanity_enabled
    AP.ScoopUnlocker.set_scoop_sanity_enabled(scoop_sanity_enabled)
    log("ScoopSanity enabled=" .. tostring(scoop_sanity_enabled))

    -- Goal mode for ScoopUnlocker -- used to fire flag 270 (Backup for Brad
    -- cutscene that opens EP shutters) on Meet-Jessie when goal is Savior.
    AP.ScoopUnlocker.set_goal_mode(goal)

    -- Set up ScoopUnlocker persistence and ordering
    AP.ScoopUnlocker.set_save_filename(slot, seed)
    AP.ScoopUnlocker.load_save()

    -- PlayerStats persistence (skills + stat deltas survive script reload)
    AP.effects.PlayerStats.set_save_filename(slot, seed)
    AP.effects.PlayerStats.load_save()
    -- Read slot-data progression mode if provided (default: replace)
    local prog_mode = (type(slot_data) == "table" and slot_data.vanilla_progression) or "replace"
    AP.effects.PlayerStats.set_progression_mode(prog_mode)

    -- Hostile-Survivor trap spawn-count range from slot data (default 1-3)
    local hs_min = (type(slot_data) == "table" and tonumber(slot_data.hostile_survivor_count_min)) or 1
    local hs_max = (type(slot_data) == "table" and tonumber(slot_data.hostile_survivor_count_max)) or 3
    AP.effects.HostileSurvivorTrap.set_spawn_count_range(hs_min, hs_max)

    -- Zombie difficulty options (Night Mode / Hardcore Zombies). The slot_data
    -- arrives with hardcore->night already auto-promoted (see fill_slot_data),
    -- so we just honor the two flags directly.
    local night_enabled = (type(slot_data) == "table" and slot_data.night_mode_enabled == true)
    local hardcore_enabled = (type(slot_data) == "table" and slot_data.hardcore_zombies_enabled == true)
    if AP.effects.ZombieEffects then
        if night_enabled then
            AP.effects.ZombieEffects.set_permanent_night(true)
        else
            AP.effects.ZombieEffects.set_permanent_night(false)
        end
        if hardcore_enabled then
            AP.effects.ZombieEffects.set_permanent_hardcore(true)
        else
            AP.effects.ZombieEffects.set_permanent_hardcore(false)
        end
        log(string.format("Zombie difficulty: night=%s hardcore=%s",
            tostring(night_enabled), tostring(hardcore_enabled)))
    end

    -- Costume randomizer toggles (3 independent options):
    --   * random_starting_costume : one randomized outfit at session start
    --   * costume_chaos_mode      : re-randomize on every area transition
    --   * dlc_outfits_enabled     : expand Body pool to include DLC anchors (43..62)
    if AP.effects.CostumeRandomizer then
        local starting = (type(slot_data) == "table"
                          and slot_data.random_starting_costume == true)
        local chaos    = (type(slot_data) == "table"
                          and slot_data.costume_chaos_mode == true)
        local dlc      = (type(slot_data) == "table"
                          and slot_data.dlc_outfits_enabled == true)
        AP.effects.CostumeRandomizer.setup({
            starting_costume = starting,
            chaos_mode       = chaos,
            dlc_enabled      = dlc,
        })
        log(string.format("Costume randomizer: starting=%s chaos=%s dlc=%s",
            tostring(starting), tostring(chaos), tostring(dlc)))
    end

    -- PP-bonus AP location triggers. Slot data carries the per-entry mapping
    -- (msg_no -> location_name(s)) so this Lua module just walks the list,
    -- registers MsgEvents watchers, and fires AP_BRIDGE.check on each event.
    -- Disabled cleanly if pp_bonus_locations is off (trigger_data is empty).
    if AP.effects.AP_LocationTriggers then
        local trigger_data = (type(slot_data) == "table"
                              and slot_data.pp_bonus_trigger_data) or {}
        AP.effects.AP_LocationTriggers.setup(trigger_data, AP_BRIDGE)
        log(string.format("PP-bonus location triggers: %d entries",
            type(trigger_data) == "table" and #trigger_data or 0))
    end

    -- Door-randomizer in-game overlay. Slot data carries a per-scene table
    -- of redirected destinations keyed by the vanilla destination name.
    -- The overlay shows whenever the player approaches a door whose
    -- destination has been redirected for this seed. Empty table when
    -- door_randomizer is off, in which case setup() disables cleanly.
    if AP.effects.DoorPromptOverlay then
        local overlay = (type(slot_data) == "table"
                         and slot_data.door_overlay_data) or {}
        AP.effects.DoorPromptOverlay.setup(overlay)
    end

    -- Re-apply time freeze if needed (ScoopSanity only -- handles mid-game reconnect
    -- where the Meet Jessie flag is already set but TimeGate lost its freeze state)
    if scoop_sanity_enabled and AP.ScoopUnlocker.is_time_frozen() then
        AP.TimeGate.enable()
        log("Restored time freeze after connect (ScoopSanity)")
    end

    if scoop_sanity_enabled then
        -- Apply randomized main scoop order from server
        local scoop_order = slot_data.scoop_order
        if scoop_order and type(scoop_order) == "table" and #scoop_order > 0 then
            AP.ScoopUnlocker.set_scoop_order(scoop_order)
            log("Scoop order set with " .. tostring(#scoop_order) .. " entries")
        elseif goal == 2 then
            -- Savior + ScoopSanity: main scoops are intentionally excluded.
            log("Savior+ScoopSanity: main scoops disabled, no scoop order expected")
        else
            log("WARNING: ScoopSanity enabled but no scoop_order in slot data")
        end
    end

    -- Save slot redirect (controlled via AP_REF.APSaveRedirect in connection window)
    if AP.SaveSlot and AP.SaveSlot.apply_for_slot and AP_BRIDGE.AP_REF.APSaveRedirect then
        log("Applying AP save redirect for slot")
        AP.SaveSlot.apply_for_slot(slot, seed)
    end

    -- Restore the persisted received-items list. The on_items_received
    -- filter (`index > last_item_index`) then splits the server's full item
    -- history into already-applied (skipped) vs received-while-offline
    -- (applied as fresh). This is what stops traps from re-firing on every
    -- reconnect -- on_replay="skip" is only consulted by the manual reapply
    -- path, not the on-connect dispatch.
    AP_BRIDGE.set_received_items_filename(slot, seed)
    AP_BRIDGE.load_received_items()

    -- Load completed checks list and resend all to the server.
    -- This catches any checks that were completed while disconnected.
    AP_BRIDGE.set_completed_checks_filename(slot, seed)
    AP_BRIDGE.load_completed_checks()
    AP_BRIDGE.resend_all_checks()

    -- Set up sticker save file
    if AP.PPStickerTracker.set_save_filename then
        AP.PPStickerTracker.set_save_filename(slot, seed)
    end
end

------------------------------------------------------------
-- Game Enter Detection
------------------------------------------------------------

local was_in_game = false
local pending_reapply = false
local new_game_checked = false

local function on_enter_game()
    log("Entered gameplay")
    pending_reapply = true
    new_game_checked = false
end

local function try_reapply_if_ready()
    if not pending_reapply then return end
    if not AP.ItemSpawner.inventory_system_running() then return end

    -- Check for new game before reapplying (only once per game entry)
    if not new_game_checked then
        new_game_checked = true
        if AP.ScoopUnlocker.is_new_game() then
            log("New game detected -- resetting side scoop progress")
            AP.ScoopUnlocker.reset_for_new_game()
        end
    end

    log("Reapplying AP items")
    AP_BRIDGE.reapply_all_items()
    AP.ScoopUnlocker.reapply_unlocked_scoops()
    AP.effects.AreaKeyEffects.reapply()
    AP.effects.TimeLockEffects.reapply()
    AP.effects.SurvivorScoopCompletion.reapply()
    AP.effects.SaviorGoalEffects.reapply()
    AP.effects.BookSkills.reapply()
    AP.effects.PlayerStats.reapply()

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
        local ok, err = pcall(mod.on_frame)
        if not ok then log(name .. ".on_frame ERROR: " .. tostring(err)) end
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
    safe_on_frame(AP.effects.BookGuards, "BookGuards")

    -- Debug modules
    safe_on_frame(AP.EventFlagExplorer, "EventFlagExplorer")

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
_G.show_items = function() AP.GUI.show_window() end
_G.hide_items = function() AP.GUI.hide_window() end

log("Main script loaded.")