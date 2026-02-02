-- DRAP/EventTracker.lua
-- Tracks:
--   - app.solid.gamemastering.GameManager.mEventNo
--   - app.solid.SolidLogManager.SuccessSCQList

local Shared = require("DRAP/Shared")

local M = Shared.create_module("EventTracker")
M:set_throttle(0.5)  -- CHECK_INTERVAL

------------------------------------------------------------
-- Singleton Managers
------------------------------------------------------------

local gm_mgr  = M:add_singleton("gm", "app.solid.gamemastering.GameManager")
local slm_mgr = M:add_singleton("slm", "app.solid.SolidLogManager")

------------------------------------------------------------
-- Configuration
------------------------------------------------------------

local EVENT_ENUM_TYPE_NAME = "app.solid.gamemastering.EVENT_NO"
local EVENT_NONE_ID = 65535

------------------------------------------------------------
-- Internal State
------------------------------------------------------------

local EVENT_ID_TO_NAME = {}
local event_enum_built = false
local last_event_no = nil
local last_scq_list_count = nil
local SENT_DESCRIPTIONS = {}

------------------------------------------------------------
-- Tracked Events / SCQs
------------------------------------------------------------

local TRACKED_EVENT_IDS = {
    [2]   = 'Entrance Plaza Cutscene 1',
    [7]   = 'Stomp the queen',
    [10]  = 'Complete Backup for Brad',
    [12]  = 'Escort Brad to see Dr Barnaby',
    [81]  = 'Survive until 7pm on day 1',
    [15]  = 'Meet back at the Safe Room at 6am day 2',
    [16]  = 'Complete Image in the Monitor',
    [17]  = 'Complete Rescue the Professor',
    [21]  = 'Meet Steven',
    [22]  = 'Clean up... Register 6!',
    [26]  = 'Complete Girl Hunting',
    [30]  = 'Complete Promise to Isabela',
    [31]  = 'Save Isabela from the zombie',
    [33]  = 'Complete Transporting Isabela',
    [37]  = 'Meet at Safe Room at 11am day 3',
    [38]  = 'Beat Drivin Carlito',
    [41]  = 'Meet at Safe Room at 5pm day 3',
    [80]  = 'Escort Isabela to the Hideout and have a chat',
    [43]  = "Complete Jessie's Discovery",
    [44]  = 'Meet Larry',
    [49]  = 'Head back to the safe room at the end of day 3',
    [53]  = 'Get bit!',
    [131] = 'Gather the suppressants and generator and talk to Isabela',
    [126] = 'Give Isabela 5 queens',
    [136] = 'Get to the Humvee',
    [144] = 'Fight a tank and win',
    [134] = 'Ending S: Beat up Brock with your bare fists!',
    [115] = 'Meet Kent on day 1',
    [116] = 'Meet Kent on day 2',
    [117] = "Complete Kent's day 2 photoshoot",
    [113] = 'Meet Kent on day 3',
    [70]  = 'Kill Kent on day 3',
    [63]  = 'Watch the convicts kill that poor guy',
    [66]  = 'Meet Cletus',
    [72]  = 'Kill Cletus',
    [57]  = 'Meet Cliff',
    [71]  = 'Kill Cliff',
    [67]  = 'Witness Sean in Paradise Plaza',
    [58]  = 'Meet Sean',
    [73]  = 'Kill Sean',
    [59]  = 'Meet Adam',
    [74]  = 'Kill Adam',
    [60]  = 'Meet Jo',
    [75]  = 'Kill Jo',
    [61]  = 'Meet Paul',
    [76]  = 'Defeat Paul',
    [64]  = 'Meet the Hall Family',
    [79]  = 'Get grabbed by the raincoats',
}

local TRACKED_SCQ_IDS = {
    ["0x7A"] = "Help barricade the door!",
    ["0x7B"] = "Get to the stairs!",
    ["0x7C"] = "Meet Jessie in the Service Hallway",
    ["0x01"] = "Complete Temporary Agreement",
    ["0x02"] = "Complete Medicine Run",
    ["0x03"] = "Complete Professor's Past",
    ["0x04"] = "Beat up Isabela",
    ["0x05"] = "Carry Isabela back to the Safe Room",
    ["0x06"] = "Complete Santa Cabeza",
    ["0x07"] = "Complete Bomb Collector",
    ["0x08"] = "Complete The Butcher",
    ["0x09"] = "Complete Memories",
    ["0x7F"] = "Witness Special Forces 10pm Day 3",
    ["0x7E"] = "Ending A: Solve all of the cases and be on the helipad at 12pm",
    ["0x20"] = "Complete Kent's day 1 photoshoot",
    ["0x4A"] = 'Kill Roger and Jack (and Thomas if you want) and chat with Wayne',
    ["0xCA"] = "Find Greg's secret passage",
}

-- Expose for external use
M.EVENT_ID_TO_NAME = EVENT_ID_TO_NAME
M.TRACKED_EVENT_IDS = TRACKED_EVENT_IDS
M.TRACKED_SCQ_IDS = TRACKED_SCQ_IDS

------------------------------------------------------------
-- Public State
------------------------------------------------------------

M.CURRENT_EVENT_NAME = nil

------------------------------------------------------------
-- Public Callbacks
------------------------------------------------------------

M.on_tracked_location = nil
M.on_event_changed = nil

------------------------------------------------------------
-- Event Enum Helpers
------------------------------------------------------------

local function build_event_enum_map()
    if event_enum_built then return end

    local event_enum_td = sdk.find_type_definition(EVENT_ENUM_TYPE_NAME)
    if not event_enum_td then
        M.log("Could not find EVENT_NO enum type.")
        event_enum_built = true
        return
    end

    local fields = Shared.get_fields_array(event_enum_td)
    for _, field in ipairs(fields) do
        if field:is_static() then
            local ok, value = pcall(field.get_data, field, nil)
            if ok and type(value) == "number" then
                EVENT_ID_TO_NAME[value] = field:get_name()
            end
        end
    end

    event_enum_built = true
end

--- Converts an event number to its name
--- @param event_no number The event number
--- @return string The event name
function M.event_no_to_name(event_no)
    if not event_no then return "nil" end
    local name = EVENT_ID_TO_NAME[event_no]
    if name then return name end
    if event_no == EVENT_NONE_ID then return "EVENT_NONE" end
    return string.format("UNKNOWN_EVENT_%d", event_no)
end

------------------------------------------------------------
-- Location Firing
------------------------------------------------------------

local function maybe_fire_location(desc, source, raw_id, extra)
    if not desc then return end
    if SENT_DESCRIPTIONS[desc] then return end

    SENT_DESCRIPTIONS[desc] = true
    if M.on_tracked_location then
        pcall(M.on_tracked_location, desc, source, raw_id, extra)
    end
end

------------------------------------------------------------
-- SCQ Tracking
------------------------------------------------------------

local function handle_scq_updates()
    local slm = slm_mgr:get()
    if not slm then return end

    local success_list_field = slm_mgr:get_field("SuccessSCQList")
    if not success_list_field then return end

    local list = Shared.safe_get_field(slm, success_list_field)
    if not list then return end

    local count = Shared.get_collection_count(list)

    -- Initial read
    if last_scq_list_count == nil then
        last_scq_list_count = count
        M.log(string.format("Initial SuccessSCQList count = %d", count))

        for i = 0, count - 1 do
            local item = Shared.get_collection_item(list, i)
            local raw = item and tostring(item) or "(read error)"
            M.log(string.format("  [SCQ existing %d] %s", i, raw))
        end
        return
    end

    -- Reset detection
    if count < last_scq_list_count then
        M.log(string.format("SuccessSCQList count reset: %d -> %d", last_scq_list_count, count))
        last_scq_list_count = count
        return
    end

    -- New entries
    if count > last_scq_list_count then
        for i = last_scq_list_count, count - 1 do
            local item = Shared.get_collection_item(list, i)
            local raw = item and tostring(item) or "(read error)"
            local desc = TRACKED_SCQ_IDS[raw]
            if desc then
                maybe_fire_location(desc, "SCQ", raw, nil)
            end
        end
        last_scq_list_count = count
    end
end

------------------------------------------------------------
-- Per-frame Update
------------------------------------------------------------

-- Reset state when singleton changes
gm_mgr.on_instance_changed = function(old, new)
    last_event_no = nil
end

slm_mgr.on_instance_changed = function(old, new)
    last_scq_list_count = nil
end

function M.on_frame()
    if not M:should_run() then return end

    -- Build event enum map once
    if not event_enum_built then
        build_event_enum_map()
    end

    -- Track GameManager.mEventNo
    local gm = gm_mgr:get()
    if gm then
        local event_no_field = gm_mgr:get_field("mEventNo")
        if event_no_field then
            local ok_no, event_no = pcall(event_no_field.get_data, event_no_field, gm)
            if ok_no then
                if last_event_no == nil then
                    last_event_no = event_no
                    local name = M.event_no_to_name(event_no)
                    M.log(string.format("Initial mEventNo: %s (%d)", name, event_no))
                    M.CURRENT_EVENT_NAME = name
                elseif event_no ~= last_event_no then
                    local old_name = M.event_no_to_name(last_event_no)
                    local new_name = M.event_no_to_name(event_no)

                    M.CURRENT_EVENT_NAME = new_name

                    if M.on_event_changed then
                        pcall(M.on_event_changed, last_event_no, event_no, old_name, new_name)
                    end

                    local desc = TRACKED_EVENT_IDS[event_no]
                    if desc then
                        maybe_fire_location(desc, "EventNo", event_no, new_name)
                    end

                    last_event_no = event_no
                end
            end
        end
    end

    -- Track SCQ Success list
    handle_scq_updates()
end

return M