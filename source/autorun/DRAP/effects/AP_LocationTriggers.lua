-- DRAP/effects/AP_LocationTriggers.lua
-- Wires MsgEvents watchers to AP location-check sends.
-- See docs/reframework/features/ap_location_triggers.md.
--
-- Two trigger shapes: "single" (one location, one fire) and "counted"
-- (count_names[1..N] + optional all_location_name on the all-X message,
-- with starting counter bootstrapped from COMPLETED_CHECKS history).

local M = {}
local MsgEvents = require("DRAP/MsgEvents")

local Shared = require("DRAP/Shared")
local log = Shared.create_logger("AP_LocTriggers")

-- Module state -- stored in _G so it survives REFramework script reloads.
-- Without this, a script reset orphans the trigger_data list (which only
-- comes through on slot-connect) and the watchers in MsgEvents end up
-- looking at an empty table, producing "setScoreBuff unwatched" log spam.
_G._DRAP_LOC_TRIGGERS_STATE = _G._DRAP_LOC_TRIGGERS_STATE or {
    counters    = {},   -- counters[entry.id] = current count
    entries     = {},   -- entries_by_id (also used to re-register on reload)
    bridge_ref  = nil,  -- last known bridge module reference
    raw_data    = nil,  -- last trigger_data list passed to setup()
}
local TS = _G._DRAP_LOC_TRIGGERS_STATE
local _bridge   -- bound by setup() and on auto-reregister
local _counters = TS.counters
local _entries  = TS.entries
local _registered = false

-- Ask the bridge whether this loc has already been checked. Defensive --
-- the bridge may not have an is_completed method on older versions.
local function _is_check_completed(loc_name)
    if not _bridge or not loc_name then return false end
    if type(_bridge.is_completed) == "function" then
        local ok, result = pcall(_bridge.is_completed, loc_name)
        if ok then return result and true or false end
    end
    return false
end

-- Ship a location check to AP. Bridge dedups internally so multiple sends
-- of the same location are safe (server-side dedup is also robust).
local function _send_check(loc_name)
    if not _bridge then
        log("send_check skipped: bridge not bound (loc=" .. tostring(loc_name) .. ")")
        return
    end
    if not loc_name then
        log("send_check skipped: loc_name nil")
        return
    end
    log("send_check: " .. tostring(loc_name))
    local ok, err = pcall(_bridge.check, loc_name)
    if not ok then
        log("send_check failed: " .. tostring(err))
    end
end

-- For a "counted" entry, walk count_names from end to start to find the
-- highest-index name already in COMPLETED_CHECKS. That's our starting
-- counter.
local function _bootstrap_counter(entry)
    if entry.type ~= "counted" then return end
    local names = entry.count_names or {}
    for i = #names, 1, -1 do
        if _is_check_completed(names[i]) then
            _counters[entry.id] = i
            return
        end
    end
    _counters[entry.id] = 0
end

-- Register watchers for a single trigger entry. Status list events go
-- through the setScoreBuff watcher; other lists go through the
-- MessageManager.queue/set watcher.
local function _register_entry(entry)
    local list = entry.list
    local msg_no = tonumber(entry.msg_no)
    if not list or not msg_no then return false end

    if entry.type == "single" then
        local loc = entry.location_name
        if not loc then return false end
        local cb_status = function(score, mn, etc)
            log(string.format("FIRED single %s/%d -> %s (score=%d)",
                tostring(list), mn or 0, tostring(loc), score or 0))
            _send_check(loc)
        end
        local cb_msg    = function(mn, list_b, lbl)
            log(string.format("FIRED single %s/%d -> %s (label=%s)",
                tostring(list), mn or 0, tostring(loc), tostring(lbl)))
            _send_check(loc)
        end
        if list == "Status" then
            MsgEvents.watch(msg_no, cb_status)
        else
            MsgEvents.watch_message(list, msg_no, cb_msg)
        end
        return true
    end

    if entry.type == "counted" then
        local count_names = entry.count_names or {}
        local max_count   = #count_names
        if max_count == 0 then return false end

        -- Per-instance handler: bump counter, send Nth name if in range.
        local per_instance = function()
            local cur = (_counters[entry.id] or 0) + 1
            _counters[entry.id] = cur
            log(string.format("FIRED counted %s/%d (entry=%s) cur=%d/%d",
                tostring(list), msg_no, tostring(entry.id), cur, max_count))
            if cur <= max_count then
                _send_check(count_names[cur])
            end
            -- If cur == max_count, the engine will also fire all_msg_no
            -- which sends all_location_name through the separate watcher
            -- below -- no need to send it here.
        end
        if list == "Status" then
            MsgEvents.watch(msg_no, function(score, mn, etc) per_instance() end)
        else
            MsgEvents.watch_message(list, msg_no, function(mn, list_b, lbl) per_instance() end)
        end

        -- ALL-X watcher: separate location, fires once when the engine
        -- has registered all-N completion.
        local all_msg_no = tonumber(entry.all_msg_no)
        local all_loc   = entry.all_location_name
        if all_msg_no and all_loc then
            local all_cb_status = function(score, mn, etc)
                log(string.format("FIRED all %s/%d -> %s",
                    tostring(list), mn or 0, tostring(all_loc)))
                _send_check(all_loc)
            end
            local all_cb_msg    = function(mn, list_b, lbl)
                log(string.format("FIRED all %s/%d -> %s",
                    tostring(list), mn or 0, tostring(all_loc)))
                _send_check(all_loc)
            end
            if list == "Status" then
                MsgEvents.watch(all_msg_no, all_cb_status)
            else
                MsgEvents.watch_message(list, all_msg_no, all_cb_msg)
            end
        end
        return true
    end

    return false
end

-- Public API. Called from main slot-connect with (trigger_data, bridge).
function M.setup(trigger_data, bridge)
    if _registered then
        log("setup called again -- replacing watchers")
    end
    _bridge = bridge
    TS.bridge_ref = bridge

    -- Clear in place; reassigning would orphan the TS.counters/TS.entries refs.
    for k in pairs(_counters) do _counters[k] = nil end
    for k in pairs(_entries)  do _entries[k]  = nil end

    if type(trigger_data) ~= "table" or #trigger_data == 0 then
        TS.raw_data = nil
        log("no trigger_data; PP-bonus locations disabled this seed")
        return 0
    end
    TS.raw_data = trigger_data

    local count = 0
    for _, entry in ipairs(trigger_data) do
        _entries[entry.id or "?"] = entry
        _bootstrap_counter(entry)
        if _register_entry(entry) then count = count + 1 end
    end
    _registered = true
    log(string.format("registered %d PP-bonus trigger entries", count))
    return count
end

-- Auto-re-register from cached TS state if a script reset left us without
-- watchers (slot-connect won't refire on reload).
local function _maybe_auto_reregister()
    if _registered then return end       -- already done this load
    if not TS.raw_data then return end   -- no cached data to replay
    if not TS.bridge_ref then return end -- no bridge reference cached
    log("auto-re-registering from cached trigger_data after script reload")
    M.setup(TS.raw_data, TS.bridge_ref)
end

-- Console helper: force a re-register (e.g. if you changed slot data and
-- want to refresh without disconnecting).
_G.drap_loc_triggers_reregister = function()
    if not TS.raw_data then
        log("no cached trigger_data -- connect to AP first")
        return
    end
    _registered = false
    M.setup(TS.raw_data, TS.bridge_ref)
end

-- Diagnostics
function M.dump_counters()
    log("Current counters:")
    for id, n in pairs(_counters) do
        local e = _entries[id] or {}
        local maxc = (e.count_names and #e.count_names) or 0
        log(string.format("  %-22s %d / %d", id, n, maxc))
    end
end

function M.register()
    -- Bring back watchers from cached state if only Lua reloaded.
    _maybe_auto_reregister()
end

_G.drap_loc_triggers_dump = function() M.dump_counters() end

return M
