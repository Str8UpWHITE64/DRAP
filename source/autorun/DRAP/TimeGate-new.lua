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

local GameManager_TYPE_NAME = "app.solid.gamemastering.GameManager"

local gm_instance            = nil   -- current GameManager singleton
local gm_missing_warned      = false

-- freeze sources
local manual_freeze_enabled  = false -- controlled by M.enable/disable/set_frozen
local cap_freeze_enabled     = false -- controlled by time cap logic

local saved_time_add         = nil   -- original mTimeAdd before freezing

-- current time cap; when mClock >= this, time is frozen
local time_cap_seconds       = nil

-- Named checkpoints (fill these with real integer values later)
local TIME_CAPS = {
    -- TODO: fill with actual mClock values (seconds or internal unit the game uses)
    DAY2_06_AM = 0,  -- 6:00am Day 2
    DAY2_11_AM = 0,  -- 11:00am Day 2
    DAY3_00_AM = 0,  -- 12:00am Day 3
    DAY3_11_AM = 0,  -- 11:00am Day 3
    DAY4_12_PM = 0,  -- 12:00pm Day 4
}

------------------------------------------------
-- GameManager access
------------------------------------------------

local function ensure_game_manager()
    local current = sdk.get_managed_singleton(GameManager_TYPE_NAME)

    if current == nil then
        if not gm_missing_warned then
            log("GameManager singleton not found; timer control unavailable.")
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
            -- Only log the first transition into frozen from non-frozen
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
-- Time cap logic
------------------------------------------------

local function evaluate_time_cap(gm)
    if not time_cap_seconds then
        -- No cap active
        if cap_freeze_enabled then
            cap_freeze_enabled = false
            log("Time cap cleared; cap-based freeze disabled.")
        end
        return
    end

    local clock = gm.mClock or 0

    if clock >= time_cap_seconds then
        -- Clamp if we overshot in one tick
        if clock > time_cap_seconds then
            gm.mClock = time_cap_seconds
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

--------------------------------
-- Public API: status
--------------------------------

function M.is_enabled()
    -- Returns the *effective* frozen state (manual OR cap)
    return manual_freeze_enabled or cap_freeze_enabled
end

function M.is_manual_freeze()
    return manual_freeze_enabled
end

function M.is_cap_freeze()
    return cap_freeze_enabled
end

--------------------------------
-- Public API: manual freeze control
--------------------------------

function M.enable()
    if manual_freeze_enabled then return end
    manual_freeze_enabled = true
    log("Manual gate enabled; will freeze in-game time.")
    apply_gate_state()
end

function M.disable()
    if not manual_freeze_enabled then return end
    manual_freeze_enabled = false
    log("Manual gate disabled; restoring in-game time (if no cap freeze).")
    apply_gate_state()
end

-- Convenience wrapper for boolean control
function M.set_frozen(frozen)
    if frozen then
        M.enable()
    else
        M.disable()
    end
end

--------------------------------
-- Public API: time cap control
--------------------------------

-- Set a raw time cap in "seconds" (or whatever unit mClock uses).
-- When mClock >= cap, time is frozen until the cap is raised or cleared.
function M.set_time_cap(seconds)
    time_cap_seconds = seconds
    cap_freeze_enabled = false  -- will be re-evaluated next frame
    log(string.format("Time cap set to %s.", tostring(seconds)))
end

-- Clear the current time cap (removes cap-based freeze).
function M.clear_time_cap()
    time_cap_seconds = nil
    if cap_freeze_enabled then
        cap_freeze_enabled = false
        log("Time cap cleared; cap-based freeze disabled.")
        apply_gate_state()
    else
        log("Time cap cleared.")
    end
end

-- Completely unlock time (no caps, no manual freeze)
function M.unlock_all_time()
    time_cap_seconds = nil
    cap_freeze_enabled = false
    manual_freeze_enabled = false
    log("All time restrictions cleared (no caps, no manual freeze).")
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
    local gm = ensure_game_manager()
    if not gm then return end

    -- First, evaluate the cap (may toggle cap_freeze_enabled)
    evaluate_time_cap(gm)

    -- Then, enforce effective freeze state (manual OR cap)
    apply_gate_state(gm)
end

log("Module loaded. Managing time using GameManager.mTimeAdd")

return M