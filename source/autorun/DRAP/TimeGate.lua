--------------------------------
-- Dead Rising Deluxe Remaster - Time Gate (module)
-- Freezes / restores in-game time for Archipelago progression gating
--------------------------------

local M = {}

------------------------------------------------
-- Logging
------------------------------------------------
local function log(msg)
    print("[TimeGate] " .. tostring(msg))
end

------------------------------------------------
-- Config
------------------------------------------------

local GameManager_TYPE_NAME      = "app.solid.gamemastering.GameManager"
local TimeInterp_TYPE_NAME       = "app.solid.gamemastering.TimeInterpolateManager"

local gm_instance                = nil   -- current GameManager singleton
local gm_missing_warned          = false

local ti_instance                = nil   -- current TimeInterpolateManager singleton
local ti_missing_warned          = false

-- freeze sources
local manual_freeze_enabled      = false -- controlled by M.enable/disable/set_frozen
local cap_freeze_enabled         = false -- controlled by time cap logic

local saved_time_add             = nil   -- original mTimeAdd before freezing
local time_cap_seconds           = nil

-- Named checkpoints (CurrentSecond values)
local TIME_CAPS = {
    DAY2_06_AM = 104400,   -- 6:00am Day 2 - 1 hour
    DAY2_11_AM = 122400,   -- 11:00am Day 2 - 1 hour
    DAY3_00_AM = 169200,  -- 12:00am Day 3 - 1 hour
    DAY3_11_AM = 208800,  -- 11:00am Day 3 - 1 hour
    DAY4_12_PM = 298800,  -- 12:00pm Day 4 - 1 hour
}

------------------------------------------------
-- Manager access
------------------------------------------------

local function ensure_game_manager()
    local current = sdk.get_managed_singleton(GameManager_TYPE_NAME)

    if current == nil then
        if not gm_missing_warned then
            log("GameManager singleton not found; timer speed control unavailable.")
            gm_missing_warned = true
        end
        gm_instance = nil
        return nil
    end

    if current ~= gm_instance then
        gm_instance = current
        gm_missing_warned = false
        log("GameManager singleton updated.")
    end

    return gm_instance
end

local function ensure_time_interpolator()
    local current = sdk.get_managed_singleton(TimeInterp_TYPE_NAME)

    if current == nil then
        if not ti_missing_warned then
            log("TimeInterpolateManager singleton not found; time caps unavailable.")
            ti_missing_warned = true
        end
        ti_instance = nil
        return nil
    end

    if current ~= ti_instance then
        ti_instance = current
        ti_missing_warned = false
        log("TimeInterpolateManager singleton updated.")
    end

    return ti_instance
end

------------------------------------------------
-- Core time control
------------------------------------------------

local function apply_gate_state(gm)
    gm = gm or ensure_game_manager()
    if not gm then return end

    local effective_freeze = manual_freeze_enabled or cap_freeze_enabled

    if effective_freeze then
        -- First time enabling: capture current speed
        if saved_time_add == nil then
            saved_time_add = gm.mTimeAdd or 30
            log(string.format("Captured current time speed: %s", tostring(saved_time_add)))
        end

        -- Force freeze
        if gm.mTimeAdd ~= 0 then
            gm.mTimeAdd = 0
            log("Time frozen (mTimeAdd set to 0).")
        end
    else
        -- Restoring original speed if we have one
        if saved_time_add ~= nil and gm.mTimeAdd ~= saved_time_add then
            gm.mTimeAdd = saved_time_add
            log(string.format("Time restored (mTimeAdd = %s).", tostring(saved_time_add)))
        end
    end
end

------------------------------------------------
-- Time cap logic (position via TimeInterpolateManager.CurrentSecond)
------------------------------------------------

local function evaluate_time_cap()
    if not time_cap_seconds then
        -- No cap active
        if cap_freeze_enabled then
            cap_freeze_enabled = false
            log("Time cap cleared; cap-based freeze disabled.")
        end
        return
    end

    local ti = ensure_time_interpolator()
    if not ti then return end

    local clock = ti.CurrentSecond or 0

    if clock >= time_cap_seconds then
        -- Clamp if we overshot in one tick
        if clock > time_cap_seconds then
            ti.CurrentSecond = time_cap_seconds
        end

        if not cap_freeze_enabled then
            cap_freeze_enabled = true
            log(string.format("Time cap reached (%s); freezing time.", tostring(time_cap_seconds)))
        end
    else
        -- Below cap: no cap freeze needed
        if cap_freeze_enabled then
            cap_freeze_enabled = false
            log("Time is below cap; cap-based freeze disabled.")
        end
    end
end

------------------------------------------------------------
-- Detect if the player is at the very start of a new game
------------------------------------------------------------
function M.is_new_game()

    local ti = ensure_time_interpolator()
    if not ti then return end
    local clock = ti.CurrentSecond
    local new_game = false
    log("Current time: " .. tostring(clock))
    local current_event = AP.EventTracker.CURRENT_EVENT_NAME
    if clock <= 43200  and current_event == "EVENT01" then -- or clock == 0 then
        log("Detected new game start time.")
        new_game = true
    end

    -- NEW GAME START TIME = 43200 (12:00 PM Day 1)
    return new_game
end

function M.get_current_time()
    local ti = ensure_time_interpolator()
    if not ti then return nil end
    return ti.CurrentSecond or nil
end

--------------------------------
-- Public API: time cap control
--------------------------------

-- Set a raw time cap in CurrentSecond units.
-- When CurrentSecond >= cap, time is frozen until the cap is raised or cleared.
function M.set_time_cap(seconds)
    time_cap_seconds = seconds
    cap_freeze_enabled = false  -- will be re-evaluated next frame
    log(string.format("Time cap set to %s.", tostring(seconds)))
end

-- Completely unlock time
function M.unlock_all_time()
    time_cap_seconds = nil
    cap_freeze_enabled = false
    manual_freeze_enabled = false
    log("All time restrictions cleared.")
    apply_gate_state()
end

-- Named controls
function M.unlock_day2_6am()
    M.set_time_cap(TIME_CAPS.DAY2_06_AM)
end

function M.unlock_day2_11am()
    M.set_time_cap(TIME_CAPS.DAY2_11_AM)
end

function M.unlock_day3_12am()
    M.set_time_cap(TIME_CAPS.DAY3_00_AM)
end

function M.unlock_day3_11am()
    M.set_time_cap(TIME_CAPS.DAY3_11_AM)
end

function M.unlock_day4_12pm()
    M.set_time_cap(TIME_CAPS.DAY4_12_PM)
end

--------------------------------
-- Main update entrypoint
--------------------------------

function M.on_frame()
    -- Evaluate cap based on TimeInterpolateManager.CurrentSecond
    evaluate_time_cap()

    -- Enforce freeze/unfreeze via GameManager.mTimeAdd
    local gm = ensure_game_manager()
    if gm then
        apply_gate_state(gm)
    end
end

log("Module loaded. Managing time using TimeInterpolateManager.CurrentSecond and GameManager.mTimeAdd")

return M
