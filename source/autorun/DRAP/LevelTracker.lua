-- Dead Rising Deluxe Remaster - Level Tracker (module)
-- Tracks app.solid.PlayerStatusManager.PlayerLevel changes (level ups)

local M = {}
M.on_level_changed = nil

local ARMED_AFTER_GAME_TIME = 11200   -- known-safe time
local armed = false

local next_try_at = 0.0              -- os.clock() timestamp for next attempt
local backoff = 0.5                  -- seconds; grows on failure up to cap
local BACKOFF_MAX = 5.0             -- cap retry delay

------------------------------------------------
-- Logging
------------------------------------------------

local function log(msg)
    print("[LevelTracker] " .. tostring(msg))
end

------------------------------------------------
-- Config
------------------------------------------------

local StatusManager_TYPE_NAME = "app.solid.PlayerStatusManager"

local ps_instance          = nil   -- current PlayerStatusManager singleton
local ps_td                = nil   -- PlayerStatusManager type definition
local level_field           = nil   -- PlayerLevel field
local missing_level_warned = false

local last_level           = nil   -- last seen PlayerLevel

local last_check_time = 0
local CHECK_INTERVAL  = 1  -- seconds

------------------------------------------------
-- PlayerStatusManager access
------------------------------------------------

local function reset_ps_cache()
    ps_td                = nil
    level_field          = nil
    missing_level_warned = false
    last_level           = nil
end

local function ensure_player_status_manager()
    -- Always fetch the current singleton each frame
    local current = sdk.get_managed_singleton(StatusManager_TYPE_NAME)

    -- Detect instance changes (destroyed / recreated)
    if current ~= ps_instance then
        if ps_instance ~= nil and current == nil then
            log("PlayerStatusManager destroyed (likely title screen).")
        elseif ps_instance == nil and current ~= nil then
            log("PlayerStatusManager created (likely entering game).")
        elseif ps_instance ~= nil and current ~= nil then
            log("PlayerStatusManager instance changed (scene load?).")
        end

        ps_instance = current
        reset_ps_cache()
    end

    if not ps_instance then
        return false
    end

    if not ps_td then
        local ok, td = pcall(function()
            return ps_instance:get_type_definition()
        end)
        if not ok or not td then
            log("Failed to get PlayerStatusManager type definition from instance.")
            return false
        end
        ps_td = td
    end

    -- Get PlayerLevel field
    if not level_field then
        local ok, f = pcall(function()
            return ps_td:get_field("PlayerLevel")
        end)
        if not ok then
            return false
        end
        level_field = f

        if not level_field then
            if not missing_level_warned then
                log("PlayerLevel field not found on PlayerStatusManager (likely title screen or wrong context).")
                missing_level_warned = true
            end
            return false
        end
    end


    return true
end

------------------------------------------------
-- Main update entrypoint
------------------------------------------------

local first_load_in = false
local first_check_time = nil

function M.on_frame()
    -- Throttle checks
    local now = os.clock()
    if now - last_check_time < CHECK_INTERVAL then
        return
    end
    last_check_time = now

    -- Don’t touch managed singletons until we’re truly “in game”
    if AP and AP.Scene and AP.Scene.isInGame then
        local ok, in_game = pcall(AP.Scene.isInGame)
        if not ok or not in_game then
            armed = false
            next_try_at = 0.0
            backoff = 0.5
            return
        end
    end

    -- Arm using GAME time (much more reliable than waiting 3 seconds real time)
    if not armed then
        if AP and AP.TimeGate and AP.TimeGate.get_current_mdate then
            local ok, t = pcall(AP.TimeGate.get_current_mdate)
            if not ok or not t or t <= ARMED_AFTER_GAME_TIME then
                return
            end
            armed = true
            reset_ps_cache()
            ps_instance = nil
            log("Armed after game-time gate; caches reset.")
        else
            -- If TimeGate isn’t available, don’t run (avoid churn window)
            return
        end
    end

    -- Backoff: after a native throw, wait before touching managed again
    if now < next_try_at then
        return
    end

    -- Wrap singleton fetch too (it can throw native exceptions)
    local ok_single, current = pcall(function()
        return sdk.get_managed_singleton(StatusManager_TYPE_NAME)
    end)
    if not ok_single then
        next_try_at = now + backoff
        backoff = math.min(backoff * 2.0, BACKOFF_MAX)
        return
    end

    -- Detect instance changes
    if current ~= ps_instance then
        ps_instance = current
        reset_ps_cache()
    end

    if not ps_instance then
        return
    end

    -- Type definition
    if not ps_td then
        local ok, td = pcall(function()
            return ps_instance:get_type_definition()
        end)
        if not ok or not td then
            next_try_at = now + backoff
            backoff = math.min(backoff * 2.0, BACKOFF_MAX)
            reset_ps_cache()
            ps_instance = nil
            return
        end
        ps_td = td
    end

    -- Field lookup
    if not level_field then
        local ok, f = pcall(function()
            return ps_td:get_field("PlayerLevel")
        end)
        if not ok then
            next_try_at = now + backoff
            backoff = math.min(backoff * 2.0, BACKOFF_MAX)
            reset_ps_cache()
            return
        end
        level_field = f
        if not level_field then
            if not missing_level_warned then
                log("PlayerLevel field not found on PlayerStatusManager (wrong context?).")
                missing_level_warned = true
            end
            return
        end
    end

    -- Read value (this is where you’re currently throwing)
    local ok_lvl, current_level = pcall(function()
        return level_field:get_data(ps_instance)
    end)

    if not ok_lvl or type(current_level) ~= "number" then
        -- IMPORTANT: after a throw, STOP trying for a while.
        next_try_at = now + backoff
        backoff = math.min(backoff * 2.0, BACKOFF_MAX)

        -- Drop caches so next attempt is fresh
        reset_ps_cache()
        ps_instance = nil
        return
    end

    -- Success: reset backoff
    backoff = 0.5
    next_try_at = 0.0

    -- First read: initialize + resend levels up to current
    if last_level == nil then
        last_level = current_level
        log(string.format("Initial PlayerLevel: %d", current_level))

        if M.on_level_changed then
            for lvl = 2, current_level do
                log(string.format("  [AP] Processing initial level-up step: %d -> %d", lvl - 1, lvl))
                pcall(M.on_level_changed, lvl - 1, lvl)
            end
        end
        return
    end

    -- Detect changes
    if current_level ~= last_level then
        if current_level > last_level then
            if M.on_level_changed then
                for lvl = last_level + 1, current_level do
                    log(string.format("  [AP] Processing level-up step: %d -> %d", lvl - 1, lvl))
                    pcall(M.on_level_changed, lvl - 1, lvl)
                end
            end
        elseif current_level < last_level then
            log(string.format("Player level decreased: %d -> %d", last_level, current_level))
        end
        last_level = current_level
    end
end


log("Module loaded. Tracking PlayerStatusManager.PlayerLevel.")

return M