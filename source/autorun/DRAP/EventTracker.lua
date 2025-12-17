-- Dead Rising Deluxe Remaster - Event Tracker (module)
-- Tracks:
--   - app.solid.gamemastering.GameManager.mEventNo
--   - app.solid.SolidLogManager.SuccessSCQList
-- and fires a single callback for any tracked "story check".

local M = {}

M.on_tracked_check = nil
M.on_event_changed = nil

------------------------------------------------
-- Logging
------------------------------------------------

local function log(msg)
    print("[EventTracker] " .. tostring(msg))
end


------------------------------------------------
-- Config: GameManager / EventNo
------------------------------------------------

local GameManager_TYPE_NAME   = "app.solid.gamemastering.GameManager"
local EVENT_ENUM_TYPE_NAME    = "app.solid.gamemastering.EVENT_NO"
local EVENT_NONE_ID           = 65535

local gm_instance             = nil
local gm_td                   = nil
local event_no_field           = nil
local missing_event_no_warned = false

local event_enum_td           = nil
local EVENT_ID_TO_NAME        = {}
local event_enum_built        = false

local last_event_no           = nil

local last_check_time         = 0
local CHECK_INTERVAL          = 0.5 -- seconds

------------------------------------------------
-- Config: SolidLogManager / SCQ completions
------------------------------------------------

local SolidLogManager_TYPE_NAME   = "app.solid.SolidLogManager"
local SUCCESS_LIST_FIELD_NAME     = "SuccessSCQList"

local slm_instance                = nil
local slm_td                      = nil
local success_list_field           = nil
local missing_success_warned      = false

local last_scq_list_count         = nil

local SENT_DESCRIPTIONS = {}

------------------------------------------------
-- Mapped tracked checks
------------------------------------------------

local TRACKED_EVENT_IDS = {
    [2]   = 'Entrance Plaza Cutscene 1',                                   -- EVENT04
    [7]   = 'Stomp the queen',                                             -- EVENT10
    [10]  = 'Complete Backup for Brad',                                    -- EVENT13
    [12]  = 'Escort Brad to see Dr Barnaby',                               -- EVENT16
    [81]  = 'Survive until 9pm on day 1',                                  -- EVENT_EVS05
    [15]  = 'Meet back at the Safe Room at 6am day 2',                     -- EVENT19
    [16]  = 'Complete Image in the Monitor',                               -- EVENT20
    [17]  = 'Complete Rescue the Professor',                               -- EVENT21_A0
    [21]  = 'Meet Steven',                                                 -- EVENT22
    [22]  = 'Clean up... Register 6!',                                     -- EVENT23
    [26]  = 'Complete Girl Hunting',                                       -- EVENT27
    [30]  = 'Complete Promise to Isabela',                                 -- EVENT30
    [31]  = 'Save Isabela from the zombie',                                -- EVENT31_A
    [33]  = 'Complete Transporting Isabela',                               -- EVENT32_A
    [37]  = 'Meet at Safe Room at 11am day 3',                             -- EVENT35
    [38]  = 'Beat Drivin Carlito',                                         -- EVENT36
    [41]  = 'Meet at Safe Room at 5pm day 3',                              -- EVENT38
    [80]  = 'Escort Isabela to the Hideout and have a chat',               -- EVENT_EVS02
    [43]  = "Complete Jessie's Discovery",                                 -- EVENT40
    [44]  = 'Meet Larry',                                                  -- EVENT41
    [49]  = 'Head back to the safe room at the end of day 3',              -- EVENT46_A
    [53]  = 'Get bit!',                                                    -- EVENT50_A
    [131] = 'Gather the suppressants and generator and talk to Isabela',   -- EVENT53
    [126] = 'Give Isabela 5 queens',                                       -- EVENT55
    [136] = 'Get to the Humvee',                                           -- EVENT59
    [144] = 'Fight a tank and win',                                        -- EVENT60
    [134] = 'Ending S: Beat up Brock with your bare fists!',               -- EVENT61
    [115] = 'Meet Kent on day 1',                                          -- EVENT_EM45SET
    [116] = 'Meet Kent on day 2',                                          -- EVENT_EM5SET_2
    [117] = "Complete Kent's day 2 photoshoot",                            -- EVENT_EVB05
    [113] = 'Meet Kent on day 3',                                          -- EVENT_EVB07
    [70] = 'Kill Kent on day 3',                                           -- EVENT_EM45_DIE
    [63] = 'Watch the convicts kill that poor guy',
    [66] = 'Meet Cletus',
    [72] = 'Kill Cletus',
    [57] = 'Meet Cliff',                                                   -- EVENT_EM46
    [71] = 'Kill Cliff',                                                   -- EVENT_EEM46_DIE
    [58] = 'Meet Sean',                                                    -- EVENT_EM44
    [73] = 'Kill Sean',                                                    -- EVENT_EM44_DIE
    [59] = 'Meet Adam',                                                    -- EVENT_EM48
    [74] = 'Kill Adam',                                                    -- EVENT_EM48_DIE
    [69] = 'Meet Jo',                                                      -- EVENT_EM4B
    [75] = 'Kill Jo',                                                      -- EVENT_EM4B_DIE
    [61] = 'Meet Paul',                                                    -- EVENT_EM47_1
    [76] = 'Defeat Paul',                                                  -- EVENT_EM47_DIE
    [64] = 'Meet the Hall Family',                                         -- EVENT_EM4E_1
    [79] = 'Get grabbed by the raincoats',                                 -- EVENT_EVS01

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

------------------------------------------------
-- Event enum helpers
------------------------------------------------

local function build_event_enum_map()
    if event_enum_built then return end

    event_enum_td = sdk.find_type_definition(EVENT_ENUM_TYPE_NAME)
    if not event_enum_td then
        log("Could not find EVENT_NO enum type.")
        event_enum_built = true -- avoid spamming
        return
    end

    local fields = event_enum_td:get_fields() or {}
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

local function event_no_to_name(event_no)
    if not event_no then return "nil" end
    local name = EVENT_ID_TO_NAME[event_no]
    if name then
        return name
    end
    if event_no == EVENT_NONE_ID then
        return "EVENT_NONE"
    end
    return string.format("UNKNOWN_EVENT_%d", event_no)
end

M.EVENT_ID_TO_NAME = EVENT_ID_TO_NAME
M.event_no_to_name = event_no_to_name
M.TRACKED_EVENT_IDS = TRACKED_EVENT_IDS
M.TRACKED_SCQ_IDS   = TRACKED_SCQ_IDS

------------------------------------------------
-- GameManager access
------------------------------------------------

local function reset_gm_cache()
    gm_td                    = nil
    event_no_field           = nil
    missing_event_no_warned  = false
    last_event_no            = nil
end

local function ensure_game_manager()
    local current = sdk.get_managed_singleton(GameManager_TYPE_NAME)

    if current ~= gm_instance then
        if gm_instance ~= nil and current == nil then
            log("GameManager destroyed (likely title screen).")
        elseif gm_instance == nil and current ~= nil then
            log("GameManager created (likely entering game).")
        elseif gm_instance ~= nil and current ~= nil then
            log("GameManager instance changed (scene load?).")
        end

        gm_instance = current
        reset_gm_cache()
    end

    if not gm_instance then
        return false
    end

    if not gm_td then
        gm_td = gm_instance:get_type_definition()
        if not gm_td then
            log("Failed to get GameManager type definition from instance.")
            return false
        end
    end

    if not event_no_field then
        event_no_field = gm_td:get_field("mEventNo")

        if not event_no_field then
            if not missing_event_no_warned then
                log("mEventNo field not found on GameManager (likely title screen).")
                missing_event_no_warned = true
            end
            return false
        end
    end
    return true
end

------------------------------------------------
-- SolidLogManager / SCQ access
------------------------------------------------

local function reset_slm_cache()
    slm_td                 = nil
    success_list_field     = nil
    missing_success_warned = false
    last_scq_list_count    = nil
end

local function ensure_solid_log_manager()
    local current = sdk.get_managed_single_singleton and sdk.get_managed_single_singleton(SolidLogManager_TYPE_NAME)
        or sdk.get_managed_singleton(SolidLogManager_TYPE_NAME) -- safety for typos

    if current ~= slm_instance then
        if slm_instance ~= nil and current == nil then
            log("SolidLogManager destroyed (likely left game / title screen).")
        elseif slm_instance == nil and current ~= nil then
            log("SolidLogManager created (likely entered game).")
        elseif slm_instance ~= nil and current ~= nil then
            log("SolidLogManager instance changed.")
        end

        slm_instance = current
        reset_slm_cache()
    end

    if not slm_instance then
        return false
    end

    if not slm_td then
        slm_td = slm_instance:get_type_definition()
        if not slm_td then
            log("Failed to get SolidLogManager type definition.")
            return false
        end
    end

    if not success_list_field then
        success_list_field = slm_td:get_field(SUCCESS_LIST_FIELD_NAME)
        if not success_list_field then
            if not missing_success_warned then
                log("Could not find field '" .. SUCCESS_LIST_FIELD_NAME .. "' on SolidLogManager.")
                missing_success_warned = true
            end
            return false
        end
    end

    return true
end

local function get_success_list_and_count()
    if not ensure_solid_log_manager() then
        return nil, 0
    end

    local list = success_list_field:get_data(slm_instance)
    if not list then
        return nil, 0
    end

    local ok_count, count = pcall(list.get_Count, list)
    if not ok_count or not count then
        return nil, 0
    end

    return list, count
end

local function get_scq_item_string(list, index)
    local ok_item, val = pcall(list.get_Item, list, index)
    if not ok_item or val == nil then
        return nil
    end
    return tostring(val)
end

local function maybe_fire_location(desc, source, raw_id, extra)
    if not desc then return end
    if SENT_DESCRIPTIONS[desc] then
        return
    end

    SENT_DESCRIPTIONS[desc] = true
    if M.on_tracked_location then
        pcall(M.on_tracked_location, desc, source, raw_id, extra)
    end
end

------------------------------------------------
-- SCQ tracking logic
------------------------------------------------

local function handle_scq_updates()
    local list, count = get_success_list_and_count()
    if not list then
        return
    end

    if last_scq_list_count == nil then
        last_scq_list_count = count
        log(string.format("Initial SuccessSCQList count = %d", count))

        for i = 0, count - 1 do
            local raw = get_scq_item_string(list, i) or "(read error)"
            log(string.format("  [SCQ existing %d] %s", i, raw))
        end
        return
    end

    if count < last_scq_list_count then
        log(string.format("SuccessSCQList count reset: %d -> %d", last_scq_list_count, count))
        last_scq_list_count = count
        return
    end

    if count > last_scq_list_count then
        for i = last_scq_list_count, count - 1 do
            local raw = get_scq_item_string(list, i) or "(read error)"
            local desc = TRACKED_SCQ_IDS[raw]
            if desc then
                maybe_fire_location(desc, "SCQ", raw, nil)
            end
        end
        last_scq_list_count = count
    end
end


------------------------------------------------
-- Main update entrypoint
------------------------------------------------
M.CURRENT_EVENT_NAME = nil

function M.on_frame()
    -- Throttle to reduce impact
    local now = os.clock()
    if now - last_check_time < CHECK_INTERVAL then
        return
    end
    last_check_time = now

    ------------------------------------------------
    -- 1) GameManager.mEventNo tracking
    ------------------------------------------------
    if ensure_game_manager() then
        if not event_enum_built then
            build_event_enum_map()
        end

        local ok_no, event_no = pcall(event_no_field.get_data, event_no_field, gm_instance)
        if ok_no then

            if last_event_no == nil then
                last_event_no = event_no
                local name = event_no_to_name(event_no)
                log(string.format("Initial mEventNo: %s (%d)", name, event_no))
                M.CURRENT_EVENT_NAME = name
            elseif event_no ~= last_event_no then
                local old_name = event_no_to_name(last_event_no)
                local new_name = event_no_to_name(event_no)

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

    ------------------------------------------------
    -- 2) SCQ Success list tracking
    ------------------------------------------------
    handle_scq_updates()
end

log("Module loaded. Tracking GameManager.mEventNo. and SolidLogManager.SuccessSCQList")

return M