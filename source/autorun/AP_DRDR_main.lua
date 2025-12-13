-- reframework/autorun/AP_DRDR_main.lua
local game_name = reframework:get_game_name()
if game_name ~= "dd2" then
    re.msg("[DRAP] This script is only for Dead Rising Deluxe Remaster")
    return
end

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
            local item_no      = def.item_number   -- your in-game item_number
            local game_id      = def.game_id       -- optional, if you ever need it

            AP_BRIDGE.register_item_handler_by_name(ap_item_name, function(net_item, item_name, sender_name)
                print(string.format(
                    "[DRAP-AP] Applying item '%s' (%s) from %s -> spawn item_number=%d",
                    item_name or ap_item_name,
                    tostring(game_id),
                    tostring(sender_name or "?"),
                    item_no
                ))

                -- Your existing item spawn logic:
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
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s: unlock security room",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s135")
end)

AP_BRIDGE.register_item_handler_by_name("Safe Room key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s: unlock security room",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s136")
end)

AP_BRIDGE.register_item_handler_by_name("Rooftop key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s: unlock security room",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s231")
end)

AP_BRIDGE.register_item_handler_by_name("Service Hallway key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s: unlock security room",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s230")
end)

AP_BRIDGE.register_item_handler_by_name("Paradise Plaza key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s: unlock security room",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s200")
end)

AP_BRIDGE.register_item_handler_by_name("Colby's Movie Theater key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s: unlock security room",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s503")
end)

AP_BRIDGE.register_item_handler_by_name("Leisure Park key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s: unlock security room",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s700")
end)

AP_BRIDGE.register_item_handler_by_name("North Plaza key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s: unlock security room",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s400")
end)

AP_BRIDGE.register_item_handler_by_name("Crislip's Hardware Store key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s: unlock security room",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s501")
end)

AP_BRIDGE.register_item_handler_by_name("Food Court key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s: unlock security room",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("sa00")
end)

AP_BRIDGE.register_item_handler_by_name("Wonderland Plaza key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s: unlock security room",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s300")
end)

AP_BRIDGE.register_item_handler_by_name("Al Fresca Plaza key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s: unlock security room",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s900")
end)

AP_BRIDGE.register_item_handler_by_name("Entrance Plaza key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s: unlock security room",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s100")
end)

AP_BRIDGE.register_item_handler_by_name("Grocery Store key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s: unlock security room",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s500")
end)

AP_BRIDGE.register_item_handler_by_name("Maintenance Tunnel key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s: unlock security room",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s600")
end)

AP_BRIDGE.register_item_handler_by_name("Hideout key", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s: unlock security room",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.DoorSceneLock.unlock_scene("s401")
end)

-- Time Locks
AP_BRIDGE.register_item_handler_by_name("DAY2_06_AM", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s: unlock security room",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.TimeGate.unlock_day2_6am()
end)

AP_BRIDGE.register_item_handler_by_name("DAY2_11_AM", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s: unlock security room",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.TimeGate.unlock_day2_11am()
end)

AP_BRIDGE.register_item_handler_by_name("DAY3_00_AM", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s: unlock security room",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.TimeGate.unlock_day3_12am()
end)

AP_BRIDGE.register_item_handler_by_name("DAY3_11_AM", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s: unlock security room",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.TimeGate.unlock_day3_11am()
end)

AP_BRIDGE.register_item_handler_by_name("DAY4_12_PM", function(net_item, item_name, sender_name)
    print(string.format("[DRAP-AP] Applying progression item '%s' from %s: unlock security room",
        tostring(item_name), tostring(sender_name or "?")
    ))

    AP.TimeGate.unlock_day4_12pm()
end)

------------------------------------------------------------
-- Async helpers
------------------------------------------------------------
local TIME_CAPS = {
    DAY2_06_AM = 61200,   -- 6:00am Day 2 - 1 hour
    DAY2_11_AM = 79200,   -- 11:00am Day 2 - 1 hour
    DAY3_00_AM = 126000,  -- 12:00am Day 3 - 1 hour
    DAY3_11_AM = 165600,  -- 11:00am Day 3 - 1 hour
    DAY4_12_PM = 255600,  -- 12:00pm Day 4 - 1 hour
}
local function apply_permanent_effects_from_ap()
    -- Example: door keys
    if AP_BRIDGE.has_item_name("Helipad Key") then
        AP.DoorSceneLock.unlock_scene("s135")
    end

    if AP_BRIDGE.has_item_name("Safe Room Key") then
        AP.DoorSceneLock.unlock_scene("s136")
    end

    if AP_BRIDGE.has_item_name("Rooftop Key") then
        AP.DoorSceneLock.unlock_scene("s231")
    end

    if AP_BRIDGE.has_item_name("Service Hallway Key") then
        AP.DoorSceneLock.unlock_scene("s230")
    end

    if AP_BRIDGE.has_item_name("Paradise Plaza Key") then
        AP.DoorSceneLock.unlock_scene("s200")
    end

    if AP_BRIDGE.has_item_name("Colby's Movie Theater Key") then
        AP.DoorSceneLock.unlock_scene("s503")
    end

    if AP_BRIDGE.has_item_name("Leisure Park Key") then
        AP.DoorSceneLock.unlock_scene("s700")
    end

    if AP_BRIDGE.has_item_name("North Plaza Key") then
        AP.DoorSceneLock.unlock_scene("s400")
    end

    if AP_BRIDGE.has_item_name("Crislip's Hardware Store Key") then
        AP.DoorSceneLock.unlock_scene("s501")
    end

    if AP_BRIDGE.has_item_name("Food Court Key") then
        AP.DoorSceneLock.unlock_scene("sa00")
    end

    if AP_BRIDGE.has_item_name("Wonderland Plaza Key") then
        AP.DoorSceneLock.unlock_scene("s300")
    end

    if AP_BRIDGE.has_item_name("Al Fresca Plaza Key") then
        AP.DoorSceneLock.unlock_scene("s900")
    end

    if AP_BRIDGE.has_item_name("Entrance Plaza Key") then
        AP.DoorSceneLock.unlock_scene("s100")
    end

    if AP_BRIDGE.has_item_name("Grocery Store Key") then
        AP.DoorSceneLock.unlock_scene("s500")
    end

    if AP_BRIDGE.has_item_name("Maintenance Tunnel Key") then
        AP.DoorSceneLock.unlock_scene("s600")
    end

    if AP_BRIDGE.has_item_name("Hideout Key") then
        AP.DoorSceneLock.unlock_scene("s401")
    end

    -- Time freezes
    if AP_BRIDGE.has_item_name("DAY2_06_AM") then
        AP.TimeGate.unlock_day2_6am()

        if AP_BRIDGE.has_item_name("DAY2_11_AM") then
            AP.TimeGate.unlock_day2_11am()

            if AP_BRIDGE.has_item_name("DAY3_00_AM") then
                AP.TimeGate.unlock_day3_12am()

                if AP_BRIDGE.has_item_name("DAY3_11_AM") then
                    AP.TimeGate.unlock_day3_11am()

                    if AP_BRIDGE.has_item_name("DAY4_12_PM") then
                        AP.TimeGate.unlock_all_time()
                    else
                        AP.TimeGate.set_time_cap(TIME_CAPS.DAY4_12_PM)
                    end
                else
                    AP.TimeGate.set_time_cap(TIME_CAPS.DAY3_11_AM)
                end
            else
                AP.TimeGate.set_time_cap(TIME_CAPS.DAY3_00_AM)
            end
        else
            AP.TimeGate.set_time_cap(TIME_CAPS.DAY2_11_AM)
        end
    else
        AP.TimeGate.set_time_cap(TIME_CAPS.DAY2_06_AM)
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


-- Challenges (SolidSave thresholds)
AP.ChallengeTracker.on_challenge_threshold =
    function(field_name, def, idx, target, prev, current)
        local label = def.label or field_name
        local challenge = (string.format(
            "[DRAP-AP] Challenge '%s' target #%d reached: %d (from %d to %d)",
            label, idx, target or -1, prev or -1, current or -1
        ))
        AP.AP_BRIDGE.check(challenge)
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

    -- your existing logic
    print(string.format("[DRAP-AP] Slot connected: slot=%s seed=%s",
        tostring(AP_REF.APSlot),
        tostring(slot_data.seed_name or slot_data.seed or slot_data.seed_id or "unknown")
    ))

    -- Load saveslot
    if AP.SaveSlot and AP.SaveSlot.apply_for_slot then
        print("[DRAP-AP] Applying AP save redirect for slot.")
        AP.SaveSlot.apply_for_slot(AP_REF.APSlot, slot_data.seed_name or slot_data.seed or slot_data.seed_id)
    else
        print("[DRAP-AP] AP.SaveSlot.apply_ap_save_dir not available.")
    end

    local slot = AP_REF.APSlot or (AP_REF.APClient and AP_REF.APClient:get_player_alias(AP_REF.APClient:get_player_number())) or "unknown"
    local seed = extract_seed(slot_data)

    AP.AP_BRIDGE.set_received_items_filename(slot, seed)
    AP.AP_BRIDGE.load_received_items()
end

local was_in_game = false

local function on_enter_game()
    print("[DRAP] Entered gameplay.")
    print("[DRAP] Is new game:", tostring(AP.TimeGate.is_new_game and AP.TimeGate.is_new_game()))

    -- If you want: detect new game via your time-gate check
    if AP.TimeGate and AP.TimeGate.is_new_game and AP.TimeGate.is_new_game() then
        print("[DRAP] New game detected; reapplying AP items.")
        AP.AP_BRIDGE.reapply_all_items()
    end
    apply_permanent_effects_from_ap()
end

re.on_frame(function()
    local now_in_game = AP.Scene.isInGame()
    if not now_in_game then
        return
    end
    AP.ItemSpawner.on_frame()
    AP.DoorSceneLock.on_frame()
    AP.ChallengeTracker.on_frame()
    AP.LevelTracker.on_frame()
    AP.EventTracker.on_frame()
    AP.NpcTracker.on_frame()
    AP.AP_BRIDGE.on_frame()
    AP.PPStickerTracker.on_frame()

    if now_in_game and not was_in_game then
        print("[DRAP] Detected transition into game.")
        on_enter_game()
    end
    was_in_game = now_in_game
end)
print("[DRAP] Main script loaded.")