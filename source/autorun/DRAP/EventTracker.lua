-- Dead Rising Deluxe Remaster - Event Tracker (module)
-- Tracks app.solid.gamemastering.GameManager.mEventNo changes

local M = {}
M.on_event_changed = nil

------------------------------------------------
-- Logging
------------------------------------------------

local function log(msg)
    print("[EventTracker] " .. tostring(msg))
end

------------------------------------------------
-- Config
------------------------------------------------

local GameManager_TYPE_NAME   = "app.solid.gamemastering.GameManager"
local EVENT_ENUM_TYPE_NAME    = "app.solid.gamemastering.EVENT_NO"
local EVENT_NONE_ID           = 65535

local gm_instance             = nil   -- current GameManager singleton
local gm_td                   = nil   -- GameManager type definition
local event_no_field           = nil   -- mEventNo field
local missing_event_no_warned = false

local event_enum_td           = nil
local EVENT_ID_TO_NAME        = {}
local event_enum_built        = false

local last_event_no           = nil   -- last seen mEventNo

local last_check_time         = 0
local CHECK_INTERVAL          = 1     -- seconds

------------------------------------------------
-- Helpers
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
    log(string.format("Built EVENT_NO enum map with ~%d entries.", #fields))
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

-- expose map & helper
M.EVENT_ID_TO_NAME = EVENT_ID_TO_NAME
M.event_no_to_name = event_no_to_name

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
    -- Always fetch the current singleton each frame
    local current = sdk.get_managed_singleton(GameManager_TYPE_NAME)

    -- Detect instance changes (destroyed / recreated)
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

    -- If there is no current GameManager, we can't read anything this frame
    if not gm_instance then
        return false
    end

    -- Get type definition from the instance
    if not gm_td then
        gm_td = gm_instance:get_type_definition()
        if not gm_td then
            log("Failed to get GameManager type definition from instance.")
            return false
        end
    end

    -- Get mEventNo field
    if not event_no_field then
        event_no_field = gm_td:get_field("mEventNo")

        if not event_no_field then
            if not missing_event_no_warned then
                log("mEventNo field not found on GameManager (likely title screen).")
                missing_event_no_warned = true
            end
            return false
        else
            log("Found mEventNo field.")
        end
    end
    return true
end

------------------------------------------------
-- Main update entrypoint
------------------------------------------------

function M.on_frame()
    -- Throttle checks to reduce performance impact
    local now = os.clock()
    if now - last_check_time < CHECK_INTERVAL then
        return
    end
    last_check_time = now

    -- Make sure we can access GameManager and mEventNo
    if not ensure_game_manager() then
        return
    end

    -- Build enum map once (if available)
    if not event_enum_built then
        build_event_enum_map()
    end

    -- Safely read current mEventNo
    local ok_no, event_no = pcall(event_no_field.get_data, event_no_field, gm_instance)
    if not ok_no then
        return
    end

    -- First successful read for this GameManager instance:
    if last_event_no == nil then
        last_event_no = event_no
        local name = event_no_to_name(event_no)
        log(string.format("Initial mEventNo: %s (%d)", name, event_no))
        return
    end

    -- Detect changes
    if event_no ~= last_event_no then
        local old_name = event_no_to_name(last_event_no)
        local new_name = event_no_to_name(event_no)

        log(string.format(
            "mEventNo changed: %s (%d) -> %s (%d)",
            old_name, last_event_no, new_name, event_no
        ))

        -- AP hook
        if M.on_event_changed then
            pcall(M.on_event_changed, last_event_no, event_no, old_name, new_name)
        end

        last_event_no = event_no
    end
end

log("Module loaded. Tracking GameManager.mEventNo.")

return M