--------------------------------
-- Dead Rising Deluxe Remaster - Time Gate (module)
-- Freezes / restores in-game time for Archipelago progression gating
-- Uses SCQManager.<mDate>k__BackingField for time caps
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
local SCQManager_TYPE_NAME  = "app.solid.gamemastering.SCQManager"

local gm_instance       = nil
local gm_missing_warned = false

local scq_instance       = nil
local scq_missing_warned = false

-- freeze sources
local manual_freeze_enabled  = false
local cap_freeze_enabled     = false

local saved_time_add         = nil

-- Current cap in mDate integer form (e.g. 20600 = Day 2 06:00)
local time_cap_mdate         = nil

-- Named checkpoints (mDate values)
-- Format: day*10000 + hour*100 + minute
local TIME_CAPS = {
    DAY2_06_AM = 20500, -- Day 2 06:00 - 1 hour
    DAY2_11_AM = 21000, -- Day 2 11:00 - 1 hour
    DAY3_00_AM = 21100, -- Day 3 00:00 - 1 hour
    DAY3_11_AM = 31000, -- Day 3 11:00 - 1 hour
    DAY4_12_PM = 41100, -- Day 4 12:00 - 1 hour
}

------------------------------------------------
-- Helpers: mDate parse/format
------------------------------------------------
local function parse_mdate(md)
    -- md example: 20230 = Day 2 02:30
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

local function ensure_scq_manager()
    local current = sdk.get_managed_singleton(SCQManager_TYPE_NAME)

    if current == nil then
        if not scq_missing_warned then
            log("SCQManager singleton not found; mDate caps unavailable.")
            scq_missing_warned = true
        end
        scq_instance = nil
        return nil
    end

    if current ~= scq_instance then
        scq_instance = current
        scq_missing_warned = false
        log("SCQManager singleton updated.")
    end

    return scq_instance
end

local function read_scq_mdate(scq)
    -- Prefer field accessor via get_field if available; fallback to direct if REFramework exposes it
    local ok, v = pcall(function()
        -- field name given: "<mDate>k__BackingField"
        local f = scq:get_type_definition():get_field("<mDate>k__BackingField")
        if f then
            return f:get_data(scq)
        end
        -- fallback
        return scq["<mDate>k__BackingField"]
    end)
    if ok then return v end
    return nil
end

------------------------------------------------
-- Core time control
------------------------------------------------
local function apply_gate_state(gm)
    gm = gm or ensure_game_manager()
    if not gm then return end

    local effective_freeze = manual_freeze_enabled or cap_freeze_enabled

    if effective_freeze then
        if saved_time_add == nil then
            saved_time_add = 30
            log(string.format("Captured current time speed: %s", tostring(saved_time_add)))
        end

        if gm.mTimeAdd ~= 0 then
            gm.mTimeAdd = 0
            log("Time frozen (mTimeAdd set to 0).")
        end
    else
        if saved_time_add ~= nil and gm.mTimeAdd ~= saved_time_add then
            gm.mTimeAdd = 30
            log(string.format("Time restored (mTimeAdd = %s).", tostring(saved_time_add)))
        end
    end
end

------------------------------------------------
-- Time cap logic
------------------------------------------------
local function evaluate_time_cap_mdate()
    if not time_cap_mdate then
        if cap_freeze_enabled then
            cap_freeze_enabled = false
            log("Time cap cleared; cap-based freeze disabled.")
        end
        return
    end

    local scq = ensure_scq_manager()
    if not scq then return end

    local md = read_scq_mdate(scq)
    if md == nil then return end
    md = tonumber(md) or 0

    if md >= time_cap_mdate then
        if not cap_freeze_enabled then
            cap_freeze_enabled = true
            log(string.format("Time cap reached; freezing time. current=%s cap=%s",
                mdate_to_string(md), mdate_to_string(time_cap_mdate)
            ))
        end
    else
        if cap_freeze_enabled then
            cap_freeze_enabled = false
            log(string.format("Below cap; cap-based freeze disabled. current=%s cap=%s",
                mdate_to_string(md), mdate_to_string(time_cap_mdate)
            ))
        end
    end
end

------------------------------------------------------------
-- New game detection
------------------------------------------------------------
function M.is_new_game()
    local scq = ensure_scq_manager()
    if not scq then return false end

    local md = read_scq_mdate(scq)
    if md == nil then return false end

    local day, hour, minute = parse_mdate(md)
    if not day then return false end

    local current_event = AP and AP.EventTracker and AP.EventTracker.CURRENT_EVENT_NAME or nil

    log(string.format("Current mDate=%s (Day %d %02d:%02d) event=%s",
        tostring(md), day, hour, minute, tostring(current_event)))

    -- Keep your heuristic (tweak as desired)
    if day == 1 and hour == 12 and minute <= 05 and current_event == "EVENT01" then
        return true
    end

    return false
end

function M.get_current_mdate()
    local scq = ensure_scq_manager()
    if not scq then return nil end
    return read_scq_mdate(scq)
end

--------------------------------
-- Public API: manual freeze control
--------------------------------
function M.enable()
    if manual_freeze_enabled then return end
    manual_freeze_enabled = true
    log("Manual freeze enabled.")
    apply_gate_state()
end

function M.disable()
    if not manual_freeze_enabled then return end
    manual_freeze_enabled = false
    log("Manual freeze disabled.")
    apply_gate_state()
end

function M.set_frozen(frozen)
    if frozen then M.enable() else M.disable() end
end

--------------------------------
-- Public API: time cap control (mDate)
--------------------------------
function M.set_time_cap_mdate(md_cap)
    time_cap_mdate = tonumber(md_cap)
    cap_freeze_enabled = false
    log(string.format("Time cap set to mDate=%s.", mdate_to_string(time_cap_mdate)))
end

-- Backward-compatible name, but now *expects mDate* (not seconds)
function M.set_time_cap(value)
    M.set_time_cap_mdate(value)
end

function M.clear_time_cap()
    time_cap_mdate = nil
    if cap_freeze_enabled then
        cap_freeze_enabled = false
        log("Time cap cleared; cap-based freeze disabled.")
    else
        log("Time cap cleared.")
    end
    apply_gate_state()
end

function M.unlock_all_time()
    time_cap_mdate = nil
    cap_freeze_enabled = false
    manual_freeze_enabled = false
    log("All time restrictions cleared.")
    apply_gate_state()
end

-- Named controls
function M.unlock_day2_6am()  M.set_time_cap_mdate(TIME_CAPS.DAY2_06_AM) end
function M.unlock_day2_11am() M.set_time_cap_mdate(TIME_CAPS.DAY2_11_AM) end
function M.unlock_day3_12am() M.set_time_cap_mdate(TIME_CAPS.DAY3_00_AM) end
function M.unlock_day3_11am() M.set_time_cap_mdate(TIME_CAPS.DAY3_11_AM) end
function M.unlock_day4_12pm() M.set_time_cap_mdate(TIME_CAPS.DAY4_12_PM) end

--------------------------------
-- Main update entrypoint
--------------------------------
function M.on_frame()
    evaluate_time_cap_mdate()

    local gm = ensure_game_manager()
    if gm then
        apply_gate_state(gm)
    end
end

log("Module loaded. Managing time using SCQManager.<mDate>k__BackingField and GameManager.mTimeAdd")

return M
