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
AP.EventTracker    = require("DRAP/EventTracker-new")
AP.NpcTracker      = require("DRAP/NpcTracker")
AP.PPStickerTracker= require("DRAP/PPStickerTracker")
AP.SaveSlot        = require("DRAP/SaveSlot")
AP.TimeGate        = require("DRAP/TimeGate-new")

------------------------------------------------------------
-- AP item handlers
------------------------------------------------------------

-- Auto-register item handlers from JSON
local function register_spawn_handlers_from_json()
    -- adjust path if needed
    local item_list_path = "data/drdr_items.json"

    local items = json.load_file(item_list_path)
    if not items then
        print("[DRAP-AP] Failed to load item list JSON: " .. item_list_path)
        return
    end

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
        end
    end

    print("[DRAP-AP] Auto-registered spawn handlers for JSON items.")
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

AP_BRIDGE.register_item_handler_by_name("Crisip's Hardware Store key", function(net_item, item_name, sender_name)
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



local function ap_is_connected()
    if not AP_REF.APClient then
        return false
    end

    local state = AP_REF.APClient:get_state()
    return state ~= AP.State.DISCONNECTED
end

local function send_level_checks_to_ap(old_level, new_level)
    if not ap_is_connected() then
        print(string.format(
            "[DRAP-AP] Not connected to AP; skipping level checks (%d -> %d).",
            old_level or -1, new_level or -1
        ))
        return
    end

    -- Collect all location IDs for levels gained
    local locs = {}

    -- Safeguard (old_level should always be < new_level here, but just in case)
    local start_level = (old_level or (new_level - 1))

    for lvl = start_level + 1, new_level do
        local loc_id = LEVEL_TO_AP_LOCATION_ID[lvl]
        if loc_id then
            table.insert(locs, loc_id)
            print(string.format(
                "[DRAP-AP] Queuing AP location check for level %d (loc_id=%d)",
                lvl, loc_id
            ))
        else
            print(string.format(
                "[DRAP-AP] No AP location mapped for level %d; skipping.",
                lvl
            ))
        end
    end

    if #locs > 0 then
        AP_REF.APClient:LocationChecks(locs)
        print(string.format(
            "[DRAP-AP] Sent %d level-based location check(s) to AP.",
            #locs
        ))
    end
end

------------------------------------------------------------
-- AP hook wiring
------------------------------------------------------------

local AP_BRIDGE = require("ap_drdr_bridge")

-- Level tracking
AP.LevelTracker.on_level_changed = function(old_level, new_level)
    print(string.format("[DRAP-AP] Level changed %d -> %d", old_level, new_level))

    if new_level > old_level then
        local loc_name = string.format("Reach Level %02d", new_level)
        AP_BRIDGE.check(loc_name)
    end
end

-- Story / game events
AP.EventTracker.on_event_changed =
    function(old_id, new_id, old_name, new_name)
        print(string.format(
            "[DRAP-AP] Event changed %s (%d) -> %s (%d)",
            tostring(old_name), old_id or -1, tostring(new_name), new_id or -1
        ))
        event_name = new_name
        AP_BRIDGE.check(event_name)
    end

-- Challenges (SolidSave thresholds)
AP.ChallengeTracker.on_challenge_threshold =
    function(field_name, def, idx, target, prev, current)
        local label = def.label or field_name
        local challenge = (string.format(
            "[DRAP-AP] Challenge '%s' target #%d reached: %d (from %d to %d)",
            label, idx, target or -1, prev or -1, current or -1
        ))
        AP_BRIDGE.check(challenge)
    end

-- Survivors rescued
AP.NpcTracker.on_survivor_rescued =
    function(npc_id, state_index, friendly_name, game_id)
        print(string.format(
            "[DRAP-AP] Survivor rescued: id=%s name=%s game_id=%s state=%s",
            tostring(npc_id), tostring(friendly_name), tostring(game_id), tostring(state_index)
        ))
        local name = string.format("Rescue %s", friendly_name)
        AP_BRIDGE.check(name)
    end

-- PP Stickers
AP.PPStickerTracker.on_sticker_event_taked =
    function(photo_id, item_unique_no, having_event)
        print(string.format(
            "[DRAP-AP] PP sticker EVENT TAKED: PhotoId=%s ItemUniqueNo=%s HavingEvent=%s",
            tostring(photo_id), tostring(item_unique_no), tostring(having_event)
        ))
        AP_BRIDGE.check("Photograph PP Sticker " .. photo_id)
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

re.on_frame(function()
    AP.ItemSpawner.on_frame()
    AP.DoorSceneLock.on_frame()
    AP.ChallengeTracker.on_frame()
    AP.LevelTracker.on_frame()
    AP.EventTracker.on_frame()
    AP.NpcTracker.on_frame()
    AP.PPStickerTracker.on_frame()
end)

print("[DRAP] Main script loaded.")