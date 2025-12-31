-- reframework/autorun/AP_DRDR_main.lua
local game_name = reframework:get_game_name()
if game_name ~= "dd2" then
    re.msg("[DRAP] This script is only for Dead Rising Deluxe Remaster")
    return
end

local redirect_save_path = true

local AP_BRIDGE = require("ap_drdr_bridge")

AP = AP or {}
AP.AP_BRIDGE       = AP_BRIDGE
AP.ItemSpawner     = require("DRAP/ItemSpawner")
AP.DoorSceneLock   = require("DRAP/DoorSceneLock")
AP.ChallengeTracker= require("DRAP/ChallengeTracker")
AP.LevelTracker    = require("DRAP/LevelTracker")
AP.EventTracker    = require("DRAP/EventTracker")
AP.NpcTracker      = require("DRAP/NpcTracker")
AP.PPStickerTracker= require("DRAP/PPStickerTracker")
AP.SaveSlot        = require("DRAP/SaveSlot")
AP.TimeGate        = require("DRAP/TimeGate")
AP.Scene           = require("DRAP/Scene")
AP.DeathLink       = require("DRAP/DeathLink")

------------------------------------------------------------
-- AP item handlers
------------------------------------------------------------

-- Auto-register item handlers from JSON
local function register_spawn_handlers_from_json()
    local item_list_path = "drdr_items.json" -- autorun/data/drdr_items.json

    local items = json.load_file(item_list_path)
    if not items then
        print("[DRAP-AP] Failed to load item list JSON: " .. item_list_path)
        return
    end

    local x = 0
    for _, def in ipairs(items) do

        -- We only care about entries that have a visible name
        if def.name and def.name ~= "" and def.item_number then
            -- Capture in locals so closures don’t all share the last values
            local ap_item_name = def.name          -- must match AP item name
            local item_no      = def.item_number   -- in-game item_number
            local game_id      = def.game_id       -- optional

            AP_BRIDGE.register_item_handler_by_name(ap_item_name, function(net_item, item_name, sender_name)
                print(string.format(
                    "[DRAP-AP] Applying item '%s' (%s) from %s -> spawn item_number=%d",
                    item_name or ap_item_name,
                    tostring(game_id),
                    tostring(sender_name or "?"),
                    item_no
                ))

                AP.ItemSpawner.spawn(item_no)
            end)
            x = x + 1
        end
    end
    print(string.format(("[DRAP-AP] Auto-registered %s spawn handlers for JSON items."), tostring(x)))
end

register_spawn_handlers_from_json()

-- Register remaining items
-- Area unlocks:
AP_BRIDGE.register_item_handler_by_name("Helipad key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s.",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s135")
end)

AP_BRIDGE.register_item_handler_by_name("Safe Room key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s.",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s136")
end)

AP_BRIDGE.register_item_handler_by_name("Rooftop key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s.",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s231")
end)

AP_BRIDGE.register_item_handler_by_name("Service Hallway key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s.",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s230")
end)

AP_BRIDGE.register_item_handler_by_name("Paradise Plaza key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s.",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s200")
end)

AP_BRIDGE.register_item_handler_by_name("Colby's Movie Theater key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s.",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s503")
end)

AP_BRIDGE.register_item_handler_by_name("Leisure Park key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s.",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s700")
end)

AP_BRIDGE.register_item_handler_by_name("North Plaza key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s.",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s400")
end)

AP_BRIDGE.register_item_handler_by_name("Crislip's Hardware Store key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s.",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s501")
end)

AP_BRIDGE.register_item_handler_by_name("Food Court key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s.",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("sa00")
end)

AP_BRIDGE.register_item_handler_by_name("Wonderland Plaza key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s.",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s300")
end)

AP_BRIDGE.register_item_handler_by_name("Al Fresca Plaza key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s.",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s900")
end)

AP_BRIDGE.register_item_handler_by_name("Entrance Plaza key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s.",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s100")
end)

AP_BRIDGE.register_item_handler_by_name("Grocery Store key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s.",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s500")
end)

AP_BRIDGE.register_item_handler_by_name("Maintenance Tunnel key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s.",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s600")
end)

AP_BRIDGE.register_item_handler_by_name("Hideout key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s.",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s401")
end)

------------------------------------------------------------
-- Async helpers
------------------------------------------------------------

-- Time Locks
local TIME_CAPS = {
    DAY2_06_AM = 20500, -- Day 2 06:00 - 1 hour
    DAY2_11_AM = 21000, -- Day 2 11:00 - 1 hour
    DAY3_00_AM = 21100, -- Day 3 00:00 - 1 hour
    DAY3_11_AM = 31000, -- Day 3 11:00 - 1 hour
    DAY4_12_PM = 41100, -- Day 4 12:00 - 1 hour
}

local TIME_LOCK_CHAIN = {
    { key="DAY2_06_AM", cap=TIME_CAPS.DAY2_06_AM, unlock=function() AP.TimeGate.unlock_day2_6am() end },
    { key="DAY2_11_AM", cap=TIME_CAPS.DAY2_11_AM, unlock=function() AP.TimeGate.unlock_day2_11am() end },
    { key="DAY3_00_AM", cap=TIME_CAPS.DAY3_00_AM, unlock=function() AP.TimeGate.unlock_day3_12am() end },
    { key="DAY3_11_AM", cap=TIME_CAPS.DAY3_11_AM, unlock=function() AP.TimeGate.unlock_day3_11am() end },
    { key="DAY4_12_PM", cap=TIME_CAPS.DAY4_12_PM, unlock=function() AP.TimeGate.unlock_all_time() end },
}

local function apply_time_locks_from_ap()
    if not (AP.TimeGate and AP.TimeGate.set_time_cap) then return end
    if not (AP_BRIDGE and AP_BRIDGE.has_item_name) then return end

    local last_unlocked_index = 0

    for i, step in ipairs(TIME_LOCK_CHAIN) do
        if AP_BRIDGE.has_item_name(step.key) then
            if i == last_unlocked_index + 1 then
                step.unlock()
                last_unlocked_index = i
                print(string.format("[DRAP-AP] Time chain unlocked: %s (step %d/%d)", step.key, i, #TIME_LOCK_CHAIN))
            else
                print(string.format("[DRAP-AP] Time chain blocked: have %s but missing earlier step.", step.key))
                break
            end
        else
            break
        end
    end

    if last_unlocked_index >= #TIME_LOCK_CHAIN then
        print("[DRAP-AP] Time chain fully unlocked.")
        return
    end

    local next_step = TIME_LOCK_CHAIN[last_unlocked_index + 1]
    if next_step and next_step.cap then
        AP.TimeGate.set_time_cap(next_step.cap)
        print(string.format("[DRAP-AP] Time cap set to next required step: %s (cap=%s)", next_step.key, tostring(next_step.cap)))
    end
end


local function on_time_item_received(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Received progression item '%s' from %s; re-evaluating time locks.",
        tostring(item_name), tostring(sender_name or "?")
    ))
    apply_time_locks_from_ap()
end

AP_BRIDGE.register_item_handler_by_name("DAY2_06_AM", on_time_item_received)
AP_BRIDGE.register_item_handler_by_name("DAY2_11_AM", on_time_item_received)
AP_BRIDGE.register_item_handler_by_name("DAY3_00_AM", on_time_item_received)
AP_BRIDGE.register_item_handler_by_name("DAY3_11_AM", on_time_item_received)
AP_BRIDGE.register_item_handler_by_name("DAY4_12_PM", on_time_item_received)


local function apply_permanent_effects_from_ap()
    -- Example: door keys
    if AP_BRIDGE.has_item_name("Helipad key") then
        AP.DoorSceneLock.unlock_scene("s135")
    end

    if AP_BRIDGE.has_item_name("Safe Room key") then
        AP.DoorSceneLock.unlock_scene("s136")
    end

    if AP_BRIDGE.has_item_name("Rooftop key") then
        AP.DoorSceneLock.unlock_scene("s231")
    end

    if AP_BRIDGE.has_item_name("Service Hallway key") then
        AP.DoorSceneLock.unlock_scene("s230")
    end

    if AP_BRIDGE.has_item_name("Paradise Plaza key") then
        AP.DoorSceneLock.unlock_scene("s200")
    end

    if AP_BRIDGE.has_item_name("Colby's Movie Theater key") then
        AP.DoorSceneLock.unlock_scene("s503")
    end

    if AP_BRIDGE.has_item_name("Leisure Park key") then
        AP.DoorSceneLock.unlock_scene("s700")
    end

    if AP_BRIDGE.has_item_name("North Plaza key") then
        AP.DoorSceneLock.unlock_scene("s400")
    end

    if AP_BRIDGE.has_item_name("Crislip's Hardware Store key") then
        AP.DoorSceneLock.unlock_scene("s501")
    end

    if AP_BRIDGE.has_item_name("Food Court key") then
        AP.DoorSceneLock.unlock_scene("sa00")
    end

    if AP_BRIDGE.has_item_name("Wonderland Plaza key") then
        AP.DoorSceneLock.unlock_scene("s300")
    end

    if AP_BRIDGE.has_item_name("Al Fresca Plaza key") then
        AP.DoorSceneLock.unlock_scene("s900")
    end

    if AP_BRIDGE.has_item_name("Entrance Plaza key") then
        AP.DoorSceneLock.unlock_scene("s100")
    end

    if AP_BRIDGE.has_item_name("Grocery Store key") then
        AP.DoorSceneLock.unlock_scene("s500")
    end

    if AP_BRIDGE.has_item_name("Maintenance Tunnel key") then
        AP.DoorSceneLock.unlock_scene("s600")
    end

    if AP_BRIDGE.has_item_name("Hideout key") then
        AP.DoorSceneLock.unlock_scene("s401")
    end
end

------------------------------------------------------------
-- Re-apply items and effects on new game
------------------------------------------------------------

if AP.TimeGate.is_new_game() then
    AP.AP_BRIDGE.reapply_all_items()
    apply_permanent_effects_from_ap()
end

------------------------------------------------------------
-- AP hook wiring
------------------------------------------------------------
-- Level tracking
AP.LevelTracker.on_level_changed = function(old_level, new_level)
    print(string.format("[DRAP-AP] Level changed %d -> %d", old_level, new_level))

    if new_level > old_level then
        local loc_name = string.format("Reach Level %d", new_level)
        AP.AP_BRIDGE.check(loc_name)
    end
end

-- Story / game events
AP.EventTracker.on_tracked_location =
    function(desc, source, raw_id, extra)
        print(string.format(
            "Tracked location reached: %s ",
            tostring(desc)
        ))
        AP.AP_BRIDGE.check(desc)
    end


-- Challenges
AP.ChallengeTracker.on_challenge_threshold =
    function(field_name, def, idx, target, prev, current, threshold_id)
        local label = def.label or field_name

        -- Prefer the per-threshold id as the AP location name
        local loc_name = threshold_id or string.format("%s_%d", field_name, target or -1)

        print(string.format(
            "[DRAP-AP] Challenge reached [%s] '%s' target #%d: %d (from %d to %d)",
            tostring(loc_name),
            tostring(label),
            idx or -1,
            target or -1,
            prev or -1,
            current or -1
        ))

        -- Send a separate location check per threshold
        AP.AP_BRIDGE.check(loc_name)
    end


-- Survivors rescued
AP.NpcTracker.on_survivor_rescued =
    function(npc_id, state_index, friendly_name, game_id)
        print(string.format("[DRAP-AP] Survivor rescued: name=%s",tostring(friendly_name)))
        local name = string.format("Rescue %s", friendly_name)
        AP.AP_BRIDGE.check(name)
    end

-- PP Stickers
AP.PPStickerTracker.on_sticker_event_taked =
    function(location_name, item_number, photo_id, item_unique_no, having_event)
        print(string.format(
            "[DRAP-AP] PP sticker EVENT TAKED: Location=%s ItemNumber=%s PhotoId=%s ItemUniqueNo=%s HavingEvent=%s",
            tostring(location_name), tostring(item_number), tostring(photo_id),
            tostring(item_unique_no), tostring(having_event)
        ))
        AP.AP_BRIDGE.check(location_name)
    end

------------------------------------------------------------
-- DeathLink wiring
------------------------------------------------------------

AP.DeathLink.on_death_detected = function()
    if not (AP and AP.DeathLinkEnabled) then
        return
    end

    local player_name = tostring(AP_REF and AP_REF.APSlot or "DRDR Player")

    if AP.AP_BRIDGE and AP.AP_BRIDGE.send_deathlink then
        AP.AP_BRIDGE.send_deathlink({
            cause = player_name .. " died."
        })
    end
end

------------------------------------------------------------
-- Console Helpers
------------------------------------------------------------

_G.ap_spawn_item = function(item_no)
    AP.ItemSpawner.spawn(item_no)
end

_G.lock_scene   = function(code) AP.DoorSceneLock.lock_scene(code) end
_G.unlock_scene = function(code) AP.DoorSceneLock.unlock_scene(code) end

_G.list_rescued = function()
    local rescued = AP.NpcTracker.get_rescued_survivors()
    for id, _ in pairs(rescued) do
        print("Rescued survivor ID:", id, "game_id:", AP.NpcTracker.get_survivor_game_id(id))
    end
end

_G.death_link = function(code) AP.DeathLink.kill_player("manual") end

_G.freeze = function() AP.TimeGate.enable() end

_G.cap = function(code) AP.TimeGate.set_time_cap_mdate(code) end

------------------------------------------------------------
-- Main script
------------------------------------------------------------


local AP_REF = AP.AP_BRIDGE.AP_REF

local function extract_seed(slot_data)
    return slot_data and (slot_data.seed_name or slot_data.seed or slot_data.seed_id) or "unknown"
end

local prev = AP_REF.on_slot_connected
AP_REF.on_slot_connected = function(slot_data)
    if prev then pcall(prev, slot_data) end

    print(string.format("[DRAP-AP] Slot connected: slot=%s seed=%s",
        tostring(AP_REF.APSlot),
        tostring(slot_data.seed_name or slot_data.seed or slot_data.seed_id or "unknown")
    ))

    -- DeathLink option
    local deathlink_enabled = (type(slot_data) == "table" and slot_data.death_link == true) or false
    AP.DeathLinkEnabled = deathlink_enabled

    if AP.AP_BRIDGE and AP.AP_BRIDGE.set_deathlink_enabled then
        AP.AP_BRIDGE.set_deathlink_enabled(deathlink_enabled)
    end

    print("[DRAP-AP] DeathLink enabled=" .. tostring(deathlink_enabled))

    -- Load saveslot
    if AP.SaveSlot and AP.SaveSlot.apply_for_slot and redirect_save_path then
        print("[DRAP-AP] Applying AP save redirect for slot.")
        AP.SaveSlot.apply_for_slot(AP_REF.APSlot, slot_data.seed_name or slot_data.seed or slot_data.seed_id)
    else
        print("[DRAP-AP] AP.SaveSlot.apply_ap_save_dir not available.")
    end

    local slot = AP_REF.APSlot or (AP_REF.APClient and AP_REF.APClient:get_player_alias(AP_REF.APClient:get_player_number())) or "unknown"
    local seed = extract_seed(slot_data)

    AP.AP_BRIDGE.set_received_items_filename(slot, seed)
    AP.AP_BRIDGE.load_received_items()

    local rescued_survivors = AP.NpcTracker.get_rescued_survivors()
    for id, _ in pairs(rescued_survivors) do
        local name = string.format("Rescue %s", AP.NpcTracker.get_survivor_friendly_name(id) or tostring(id))
        AP.AP_BRIDGE.check(name)
    end
end


local was_in_game = false
local pending_reapply_check = false
local reapply_done = false

local function on_enter_game()
    print("[DRAP] Entered gameplay.")
    pending_reapply_check = true
    reapply_done = false
end

local function try_reapply_items_if_ready()
    if not pending_reapply_check or reapply_done then
        return
    end

    -- Wait until inventory system is actually alive
    if not AP.ItemSpawner.inventory_system_running() then
        return
    end

    -- Now inventory exists; safe to check time
    if AP.TimeGate and AP.TimeGate.is_new_game and AP.TimeGate.is_new_game() then
        print("[DRAP] New game confirmed; reapplying AP items.")
        AP.AP_BRIDGE.reapply_all_items()
    end

    apply_permanent_effects_from_ap()
    apply_time_locks_from_ap()

    reapply_done = true
    pending_reapply_check = false
end


re.on_frame(function()
    -- Resolve isInGame safely
    local ok_ig, now_in_game = pcall(AP.Scene.isInGame)
    if not ok_ig or not now_in_game then
        was_in_game = false
        return
    end

    -- Helper: safely call module.on_frame()
    local function safe_on_frame(mod, name)
        if mod and type(mod.on_frame) == "function" then
            local ok = pcall(mod.on_frame)
            if not ok then print("[DRAP] " .. name .. ".on_frame error suppressed") end
        end
    end

    safe_on_frame(AP.ItemSpawner,     "ItemSpawner")
    safe_on_frame(AP.DoorSceneLock,   "DoorSceneLock")
    safe_on_frame(AP.ChallengeTracker,"ChallengeTracker")
    safe_on_frame(AP.LevelTracker,    "LevelTracker")
    safe_on_frame(AP.EventTracker,    "EventTracker")
    safe_on_frame(AP.NpcTracker,      "NpcTracker")
    safe_on_frame(AP.TimeGate,        "TimeGate")
    safe_on_frame(AP.DeathLink,       "DeathLink")
    safe_on_frame(AP.AP_BRIDGE,       "AP_BRIDGE")
    safe_on_frame(AP.PPStickerTracker,"PPStickerTracker")

    -- Enter-game edge
    if now_in_game and not was_in_game then
        pcall(on_enter_game)
    end
    was_in_game = now_in_game
    try_reapply_items_if_ready()
end)

print("[DRAP] Main script loaded.")
