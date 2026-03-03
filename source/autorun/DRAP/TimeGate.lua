-- DRAP/TimeGate.lua
-- Freezes / restores in-game time for Archipelago progression gating
-- Uses SCQManager.<mDate>k__BackingField for time caps

local Shared = require("DRAP/Shared")

local M = Shared.create_module("TimeGate")

------------------------------------------------------------
-- Singleton Managers
------------------------------------------------------------

local gm_mgr  = M:add_singleton("gm", "app.solid.gamemastering.GameManager")
local scq_mgr = M:add_singleton("scq", "app.solid.gamemastering.SCQManager")
local gts_mgr = M:add_singleton("gts", "app.solid.gamemastering.GameTimeSpeedManager")

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

local testing_mode = false
local manual_freeze_enabled = false
local cap_freeze_enabled = false
local saved_time_add = nil
local time_cap_mdate = nil
local speed_up_unlock_hooked = false

-- Turbo advance state
local turbo_active = false
local turbo_target_mdate = nil
local turbo_complete_callback = nil
local TURBO_SPEED_VALUE = 2000
local NORMAL_SPEED_VALUE = 50

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
    -- Don't interfere while turbo advance is running
    if turbo_active then return end

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

local function write_scq_mdate(new_mdate)
    local scq = scq_mgr:get()
    if not scq then
        M.log("ERROR: SCQManager not available for mDate write")
        return false
    end

    local ok, err = pcall(function()
        scq:call("set_mDate(System.UInt32)", new_mdate)
    end)

    if ok then
        M.log(string.format("Set mDate to %s", mdate_to_string(new_mdate)))
        return true
    else
        M.log(string.format("ERROR writing mDate: %s", tostring(err)))
        return false
    end
end

------------------------------------------------------------
-- Turbo Advance
--
-- Sets SpeedMode to turbo (2) with a very high speed value,
-- then monitors mDate until we hit the target. On arrival,
-- restores SpeedMode to normal (0) and freezes time.
------------------------------------------------------------

local function start_turbo()
    local gts = gts_mgr:get()
    if not gts then
        M.log("ERROR: GameTimeSpeedManager not available for turbo")
        return false
    end

    gts.SpeedUpTurboValue = TURBO_SPEED_VALUE
    gts:call("switchTimeSpeedMode(app.solid.gamemastering.GameTimeSpeedManager.Mode)", 2)
    turbo_active = true
    M.log(string.format("Turbo started: switchTimeSpeedMode(2), SpeedUpTurboValue=%d, target=%s",
        TURBO_SPEED_VALUE, mdate_to_string(turbo_target_mdate)))
    return true
end

local function stop_turbo()
    local gts = gts_mgr:get()
    if gts then
        gts:call("switchTimeSpeedMode(app.solid.gamemastering.GameTimeSpeedManager.Mode)", 0)
        gts.SpeedUpTurboValue = NORMAL_SPEED_VALUE
    end
    turbo_active = false
    turbo_target_mdate = nil
    turbo_complete_callback = nil
    M.log("Turbo stopped: switchTimeSpeedMode(0), SpeedUpTurboValue=" .. tostring(NORMAL_SPEED_VALUE))
end

local function evaluate_turbo()
    if not turbo_active or not turbo_target_mdate then return end

    -- Keep turbo value set (just a property, doesn't reset the speed mode).
    -- Do NOT call switchTimeSpeedMode every frame — that resets the game's
    -- internal speed accumulator and prevents time from advancing properly.
    -- start_turbo() already set speed mode to 2; the game maintains it.
    local gts = gts_mgr:get()
    if gts then
        gts.SpeedUpTurboValue = TURBO_SPEED_VALUE
    end
    -- Ensure mTimeAdd isn't zeroed (cutscenes can freeze time)
    local gm = gm_mgr:get()
    if gm and gm.mTimeAdd == 0 then
        gm.mTimeAdd = saved_time_add or 30
    end

    -- Check mDate for completion
    local md = read_scq_mdate()
    if not md then return end
    md = tonumber(md) or 0

    if md >= turbo_target_mdate then
        M.log(string.format("Turbo target reached: current=%s target=%s",
            mdate_to_string(md), mdate_to_string(turbo_target_mdate)))
        local cb = turbo_complete_callback
        stop_turbo()
        -- Re-freeze time after turbo advance
        manual_freeze_enabled = true
        apply_gate_state()
        -- Notify caller
        if cb then pcall(cb) end
        return  -- Do NOT re-engage after stopping
    end
end

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
            return sdk.PreHookResult.SKIP_ORIGINAL
        end,
        function(retval)
            return sdk.to_ptr(1)
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

--- Sets the mDate directly (advance time)
--- @param new_mdate number The target mDate value
--- @return boolean Whether the write succeeded
function M.set_mdate(new_mdate)
    new_mdate = tonumber(new_mdate)
    if not new_mdate then return false end
    local current = read_scq_mdate()
    M.log(string.format("Advancing time: %s -> %s",
        current and mdate_to_string(current) or "?", mdate_to_string(new_mdate)))
    return write_scq_mdate(new_mdate)
end

--- Turbo-advance time to a target mDate
--- Unfreezes time, sets turbo speed, then re-freezes on arrival
--- @param target_mdate number The target mDate value
--- @return boolean Whether turbo started successfully
--- Turbo-advance time to a target mDate
--- Unfreezes time, sets turbo speed, then re-freezes on arrival
--- @param target_mdate number The target mDate value
--- @param on_complete function|nil Optional callback when target is reached
--- @return boolean Whether turbo started successfully
function M.turbo_advance_to(target_mdate, on_complete)
    target_mdate = tonumber(target_mdate)
    if not target_mdate then return false end

    local current = read_scq_mdate()
    if current and tonumber(current) >= target_mdate then
        M.log(string.format("Already past target: current=%s target=%s",
            mdate_to_string(current), mdate_to_string(target_mdate)))
        if on_complete then pcall(on_complete) end
        return true
    end

    -- Disable manual freeze so apply_gate_state doesn't fight us
    manual_freeze_enabled = false
    apply_gate_state()

    turbo_target_mdate = target_mdate
    turbo_complete_callback = on_complete
    return start_turbo()
end

--- Whether turbo advance is currently running
--- @return boolean
function M.is_turbo_active()
    return turbo_active
end

--- Cancel an in-progress turbo advance
function M.cancel_turbo()
    if turbo_active then
        stop_turbo()
        M.log("Turbo advance cancelled")
    end
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
function M.set_time_cap(md_cap)
    time_cap_mdate = tonumber(md_cap)
    cap_freeze_enabled = false
    M.log(string.format("Time cap set to mDate=%s.", mdate_to_string(time_cap_mdate)))
end

--- Clears the time cap
function M.clear_time_cap()
    time_cap_mdate = nil
    cap_freeze_enabled = false
    M.log("Time cap cleared.")
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
function M.unlock_day2_6am()  M.set_time_cap(TIME_CAPS.DAY2_06_AM) end
function M.unlock_day2_11am() M.set_time_cap(TIME_CAPS.DAY2_11_AM) end
function M.unlock_day3_12am() M.set_time_cap(TIME_CAPS.DAY3_00_AM) end
function M.unlock_day3_11am() M.set_time_cap(TIME_CAPS.DAY3_11_AM) end

--- Sets testing mode (disables time gating)
--- @param enabled boolean Whether testing mode is enabled
function M.set_testing_mode(enabled)
    testing_mode = enabled
    M.log("Testing mode " .. (enabled and "enabled" or "disabled"))
end

--- Gets testing mode state
--- @return boolean Whether testing mode is enabled
function M.get_testing_mode()
    return testing_mode
end

------------------------------------------------------------
-- Per-frame Update
------------------------------------------------------------

function M.on_frame()
    -- Always try to hook speed up unlock
    if not speed_up_unlock_hooked then
        pcall(speed_up_unlock_hook)
    end

    if testing_mode then return end

    evaluate_turbo()
    evaluate_time_cap_mdate()
    apply_gate_state()
end

------------------------------------------------------------
-- REFramework UI
------------------------------------------------------------

re.on_draw_ui(function()
    if imgui.tree_node("DRAP: TimeGate") then
        local changed, new_val = imgui.checkbox("Testing Mode (Disable Time Gating)", testing_mode)
        if changed then
            M.set_testing_mode(new_val)
        end

        -- Display current time info
        local md = read_scq_mdate()
        if md then
            imgui.text("Current mDate: " .. mdate_to_string(md))
        end
        if time_cap_mdate then
            imgui.text("Time Cap: " .. mdate_to_string(time_cap_mdate))
        end
        imgui.text("Frozen: " .. tostring(manual_freeze_enabled or cap_freeze_enabled))

        -- Turbo status
        if turbo_active then
            imgui.text_colored("TURBO ACTIVE -> " .. mdate_to_string(turbo_target_mdate), 0xFF00FFFF)
            if imgui.button("Cancel Turbo") then M.cancel_turbo() end
        end

        imgui.separator()
        imgui.text("Turbo Advance To:")
        if md then
            if imgui.button("Day2 6AM") then M.turbo_advance_to(20600) end
            imgui.same_line()
            if imgui.button("Day2 11AM") then M.turbo_advance_to(21100) end
            imgui.same_line()
            if imgui.button("Day3 12AM") then M.turbo_advance_to(30000) end
            if imgui.button("Day3 11AM") then M.turbo_advance_to(31100) end
            imgui.same_line()
            if imgui.button("Day4 12PM") then M.turbo_advance_to(41200) end
        end

        imgui.tree_pop()
    end
end)

return M