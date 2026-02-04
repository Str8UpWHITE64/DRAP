-- DRAP/TimeGate.lua
-- Freezes / restores in-game time for Archipelago progression gating
-- Uses SCQManager.<mDate>k__BackingField for time caps

local Shared = require("DRAP/Shared")

local M = Shared.create_module("TimeGate")

local testing_mode = false  -- Set to true to disable time gating for testing

------------------------------------------------------------
-- Singleton Managers
------------------------------------------------------------

local gm_mgr  = M:add_singleton("gm", "app.solid.gamemastering.GameManager")
local scq_mgr = M:add_singleton("scq", "app.solid.gamemastering.SCQManager")

------------------------------------------------------------
-- Configuration
------------------------------------------------------------

-- Named checkpoints (mDate values)
-- Format: day*10000 + hour*100 + minute
local TIME_CAPS = {
    DAY2_06_AM = 20500, -- Day 2 06:00 - 1 hour
    DAY2_11_AM = 21000, -- Day 2 11:00 - 1 hour
    DAY3_00_AM = 22300, -- Day 3 00:00 - 1 hour
    DAY3_11_AM = 31000, -- Day 3 11:00 - 1 hour
    DAY4_12_PM = 41100, -- Day 4 12:00 - 1 hour
}

M.TIME_CAPS = TIME_CAPS

------------------------------------------------------------
-- Internal State
------------------------------------------------------------

local manual_freeze_enabled = false
local cap_freeze_enabled = false
local saved_time_add = nil
local time_cap_mdate = nil
local speed_up_unlock_hooked = false

------------------------------------------------------------
-- Helpers: mDate parse/format
------------------------------------------------------------

local function parse_mdate(md)
    if md == nil then return nil end
    md = tonumber(md)
    if not md then return nil end

    local day    = math.floor(md / 10000)
    local hour   = math.floor((md % 10000) / 100)
    local minute = math.floor(md % 100)
    return day, hour, minute
end

local function mdate_to_string(md)
    local day, hour, minute = parse_mdate(md)
    if not day then return tostring(md) end
    return string.format("%s (Day %d %02d:%02d)", tostring(md), day, hour, minute)
end

------------------------------------------------------------
-- Core Time Control
------------------------------------------------------------

local function apply_gate_state()
    local gm = gm_mgr:get()
    if not gm then return end

    local effective_freeze = manual_freeze_enabled or cap_freeze_enabled

    if effective_freeze then
        -- Save the current time speed before freezing (only once)
        if saved_time_add == nil then
            local current = gm.mTimeAdd
            -- Don't save 0 as the restore value
            saved_time_add = (current ~= 0) and current or 30
            M.log(string.format("Captured current time speed: %s", tostring(saved_time_add)))
        end

        if gm.mTimeAdd ~= 0 then
            gm.mTimeAdd = 0
            M.log("Time frozen (mTimeAdd set to 0).")
        end
    else
        -- Only restore once when transitioning from frozen to unfrozen
        if saved_time_add ~= nil then
            -- Only restore if time is currently frozen (mTimeAdd == 0)
            if gm.mTimeAdd == 0 then
                gm.mTimeAdd = saved_time_add
                M.log(string.format("Time restored (mTimeAdd = %s).", tostring(saved_time_add)))
            end
            -- Clear saved value so we stop interfering with player speed controls
            saved_time_add = nil
        end
    end
end

------------------------------------------------------------
-- SCQ mDate Access
------------------------------------------------------------

local function read_scq_mdate()
    local scq = scq_mgr:get()
    if not scq then return nil end

    local ok, v = pcall(function()
        local f = scq:get_type_definition():get_field("<mDate>k__BackingField")
        if f then
            return f:get_data(scq)
        end
        return scq["<mDate>k__BackingField"]
    end)

    if ok then return v end
    return nil
end

------------------------------------------------------------
-- Time Cap Logic
------------------------------------------------------------

local function evaluate_time_cap_mdate()
    if not time_cap_mdate then
        if cap_freeze_enabled then
            cap_freeze_enabled = false
            M.log("Time cap cleared; cap-based freeze disabled.")
        end
        return
    end

    local md = read_scq_mdate()
    if md == nil then return end
    md = tonumber(md) or 0

    if md >= time_cap_mdate then
        if not cap_freeze_enabled then
            cap_freeze_enabled = true
            M.log(string.format("Time cap reached; freezing time. current=%s cap=%s",
                mdate_to_string(md), mdate_to_string(time_cap_mdate)
            ))
        end
    else
        if cap_freeze_enabled then
            cap_freeze_enabled = false
            M.log(string.format("Below cap; cap-based freeze disabled. current=%s cap=%s",
                mdate_to_string(md), mdate_to_string(time_cap_mdate)
            ))
        end
    end
end

------------------------------------------------------------
-- SpeedUp Unlock Hook
------------------------------------------------------------

local function speed_up_unlock_hook()
    if speed_up_unlock_hooked then return end

    local t = sdk.find_type_definition("app.solid.gamemastering.GameManager")
    if not t then return end

    local m = t:get_method("isSpeedUpTimeUnlock()") or t:get_method("isSpeedUpTimeUnlock")
    if not m then return end

    M.log("Hooking GameManager.isSpeedUpTimeUnlock (skip original, return true)")

    sdk.hook(
        m,
        function(args)
            return sdk.PreHookResult.SKIP_ORIGINAL, true
        end
    )

    speed_up_unlock_hooked = true
    M.log("isSpeedUpTimeUnlock Hook installed.")
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

--- Gets the current mDate value
--- @return number|nil The current mDate
function M.get_current_mdate()
    return read_scq_mdate()
end

--- Checks if this appears to be a new game
--- @return boolean True if new game detected
function M.is_new_game()
    local md = read_scq_mdate()
    if md == nil then return false end

    local day, hour, minute = parse_mdate(md)
    if not day then return false end

    local current_event = AP and AP.EventTracker and AP.EventTracker.CURRENT_EVENT_NAME or nil

    M.log(string.format("Current mDate=%s (Day %d %02d:%02d) event=%s",
        tostring(md), day, hour, minute, tostring(current_event)))

    if day == 1 and hour <= 12 and minute <= 05 and current_event == "EVENT01" then
        M.log("New game detected based on mDate and event.")
        return true
    end

    return false
end

--- Enables manual time freeze
function M.enable()
    if manual_freeze_enabled then return end
    manual_freeze_enabled = true
    M.log("Manual freeze enabled.")
    apply_gate_state()
end

--- Disables manual time freeze
function M.disable()
    if not manual_freeze_enabled then return end
    manual_freeze_enabled = false
    M.log("Manual freeze disabled.")
    apply_gate_state()
end

--- Sets the freeze state
--- @param frozen boolean Whether to freeze
function M.set_frozen(frozen)
    if frozen then M.enable() else M.disable() end
end

--- Sets the time cap using mDate format
--- @param md_cap number The mDate cap value
function M.set_time_cap_mdate(md_cap)
    time_cap_mdate = tonumber(md_cap)
    cap_freeze_enabled = false
    M.log(string.format("Time cap set to mDate=%s.", mdate_to_string(time_cap_mdate)))
end

-- Backward-compatible alias
M.set_time_cap = M.set_time_cap_mdate

--- Clears the time cap
function M.clear_time_cap()
    time_cap_mdate = nil
    if cap_freeze_enabled then
        cap_freeze_enabled = false
        M.log("Time cap cleared; cap-based freeze disabled.")
    else
        M.log("Time cap cleared.")
    end
    apply_gate_state()
end

--- Removes all time restrictions
function M.unlock_all_time()
    time_cap_mdate = nil
    cap_freeze_enabled = false
    manual_freeze_enabled = false
    M.log("All time restrictions cleared.")
    apply_gate_state()
end

-- Named unlock functions
function M.unlock_day2_6am()  M.set_time_cap_mdate(TIME_CAPS.DAY2_06_AM) end
function M.unlock_day2_11am() M.set_time_cap_mdate(TIME_CAPS.DAY2_11_AM) end
function M.unlock_day3_12am() M.set_time_cap_mdate(TIME_CAPS.DAY3_00_AM) end
function M.unlock_day3_11am() M.set_time_cap_mdate(TIME_CAPS.DAY3_11_AM) end
function M.unlock_day4_12pm() M.set_time_cap_mdate(TIME_CAPS.DAY4_12_PM) end

------------------------------------------------------------
-- Per-frame Update
------------------------------------------------------------

function M.on_frame()
    if testing_mode then
        return
    end
    evaluate_time_cap_mdate()
    apply_gate_state()

    if not speed_up_unlock_hooked then
        pcall(speed_up_unlock_hook)
    end
end

return M