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

-- Night mode borrows the clock.
--
-- mClock is a plain tick count from Day 0 00:00 at 30 ticks per second, and
-- everything else is derived from it -- mDay/mHour/mMinute/mSecond by division,
-- and SCQManager's mDate from those. So writing 0 puts the world at midnight
-- and the engine lights it as night itself. That is the real thing, not the
-- WorldDayNight controller, which could never be seeked and only ever gave
-- back frame 0 whatever we asked for.
--
-- Borrowed rather than given, because the prologue's scheduled events sit at
-- 35h and 36h. Letting time run again from 0 would walk back through the
-- opening cutscenes, so releasing puts the clock no earlier than the run start.
local NIGHT_CLOCK = 0
-- Day 1 12:01, not 12:00. The run starts at 3888000 (the engine's
-- SURVIVAL_START_TIME) and five scheduled events sit on exactly that tick, so
-- restoring to it would park the clock on a due-time -- the likeliest way to
-- make an opening cutscene fire a second time. One minute past clears all of
-- them and is still well before the next event at 43h.
local RUN_START_CLOCK = 3888000 + 1800
local night_clock_armed = false
local night_clock_held = nil      -- the mClock we replaced, nil when not holding

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

--- Hold the clock at midnight. Re-applied rather than written once: a save
--- load brings the save's own mClock back, and the hold has to survive that.
local function apply_night_clock(gm)
    if not (night_clock_armed and gm) then return end
    local cur = tonumber(gm.mClock)
    if cur == nil or cur == NIGHT_CLOCK then return end
    -- Only the first value is the one we owe back; later re-applies are the
    -- save's copy of midnight coming round again.
    if night_clock_held == nil then night_clock_held = cur end
    gm.mClock = NIGHT_CLOCK
    M.log(string.format("Night mode: mClock %d -> %d (midnight)", cur, NIGHT_CLOCK))
end

--- Give the clock back before time is allowed to run, never behind the run
--- start -- see the note by NIGHT_CLOCK.
local function release_night_clock(gm)
    if night_clock_held == nil then return end
    local restore = math.max(night_clock_held, RUN_START_CLOCK)
    night_clock_held = nil
    if not gm then return end
    gm.mClock = restore
    M.log(string.format("Night mode: clock released to %d (%.2fh)",
        restore, restore / 108000))
end

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

        -- Only while frozen. With time running the game cycles day to night on
        -- its own and pinning midnight would fight a working mechanic.
        apply_night_clock(gm)
    else
        release_night_clock(gm)

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

    -- Before anything runs the clock forward. Turbo from midnight would cross
    -- the prologue's scheduled events at 35h and 36h on its way to the target.
    release_night_clock(gm_mgr:get())

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
    -- Do NOT call switchTimeSpeedMode every frame -- that resets the game's
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

--- Arm or disarm night mode's hold on the clock. Armed only, not applied here:
--- the hold goes on when time freezes and comes off when it runs, which
--- apply_gate_state already sequences.
--- @param on boolean
function M.set_night_clock(on)
    on = (on == true)
    if night_clock_armed == on then return night_clock_armed end
    night_clock_armed = on
    if on then
        M.log("Night mode: clock hold armed (midnight while time is frozen)")
        apply_gate_state()
    else
        release_night_clock(gm_mgr:get())
        M.log("Night mode: clock hold disarmed")
    end
    return night_clock_armed
end

--- Whether the clock is currently being held at midnight.
function M.is_night_clock_held()
    return night_clock_armed and night_clock_held ~= nil
end

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

-- mClock ticks at 30 a second, so an hour is 108000 of them.
local TICKS_PER_HOUR = 108000

M.TICKS_PER_HOUR = TICKS_PER_HOUR

--- Day/time -> mClock ticks. mClock counts from Day 0 00:00 and the run starts
--- at 3888000, which is 36h -- Day 1 12:00 -- so the day number needs no
--- offset of its own.
local function clock_ticks(day, hour, minute)
    return math.floor((day * 24 + hour + (minute / 60)) * TICKS_PER_HOUR)
end

--- Jump the clock straight to a day and time.
---
--- THIS is how time is set. set_mdate below writes SCQManager's mDate, which
--- is DERIVED from mClock: the engine recomputes it within a frame and the
--- write evaporates. Measured, three jumps to day 4 in a row each read back as
--- day 1. Only mClock is the real clock, which is why night mode writes it.
---
--- Nothing is turboed, so no scheduled event between here and there runs. That
--- is the point -- a turbo from day 1 fires every story event and every
--- time-based check on the way past.
---
--- @return boolean held whether the clock reads back at the target
function M.set_game_time(day, hour, minute)
    day = tonumber(day) or 1
    hour = tonumber(hour) or 12
    minute = tonumber(minute) or 0

    local gm = gm_mgr:get()
    if not gm then
        M.log("set_game_time: no GameManager")
        return false
    end

    local target = clock_ticks(day, hour, minute)
    local before = tonumber(gm.mClock)

    -- A cap or a freeze would drag it straight back.
    M.unlock_all_time()

    local ok = pcall(function() gm.mClock = target end)
    local after = tonumber(gm.mClock)
    local held = (ok and after ~= nil and math.abs(after - target) < TICKS_PER_HOUR)

    M.log(string.format(
        "set_game_time: day %d %02d:%02d -- mClock %s -> %d, reads back %s%s",
        day, hour, minute, tostring(before), target, tostring(after),
        held and "" or "  DID NOT HOLD"))
    return held
end

--- The clock as day/hour/minute, read off mClock rather than the derived mDate.
--- @return integer|nil day, integer hour, integer minute, integer ticks
function M.get_game_time()
    local gm = gm_mgr:get()
    if not gm then return nil end
    local ticks = tonumber(gm.mClock)
    if not ticks then return nil end
    local total_minutes = math.floor(ticks / (TICKS_PER_HOUR / 60))
    local day = math.floor(total_minutes / (24 * 60))
    local rest = total_minutes % (24 * 60)
    return day, math.floor(rest / 60), rest % 60, ticks
end

--- Turbo-advance time to a target mDate. Unfreezes time, sets turbo
--- speed, then re-freezes on arrival.
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

------------------------------------------------------------
-- Console
------------------------------------------------------------

--- Jump the clock. drap_time_set(4, 11, 55) for five to noon on the last day.
_G.drap_time_set = function(day, hour, minute)
    local held = M.set_game_time(day, hour, minute)
    if not held then
        M.log("the clock did not take the write -- something is driving it back")
    end
    _G.drap_time_show()
end

--- What the clock reads, from mClock and from the derived mDate, so the two
--- can be compared when one of them is lying.
_G.drap_time_show = function()
    local day, hour, minute, ticks = M.get_game_time()
    if not day then
        M.log("no GameManager -- cannot read the clock")
        return
    end
    M.log(string.format("mClock %d = day %d %02d:%02d   (mDate reads %s)",
        ticks, day, hour, minute, tostring(M.get_current_mdate())))
end

return M