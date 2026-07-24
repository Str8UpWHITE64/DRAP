-- DRAP/debug/FlagTraceRecorder.lua
-- Phase 0 Flag Atlas: read-only event-flag transition recorder. Writes every
-- transition to a JSONL session file stamped with gameplay context (area,
-- event no, case, game date, DRAP-caused?); the offline analyzer
-- (investigation/atlas/build_atlas.py) turns these into a "what triggers what"
-- graph, including cutscene-embedded writes that exist in no static table.
--
-- Capture paths: evFlagOn/Off hooks; bulk-write hooks ScoopUnlocker never sees
-- (orEventFlag/setEventFlag/clearAllEventFlag/eventFlagClear/clearEventFlagOffset
-- -- cutscenes use orEventFlag); a per-tick poll-diff fallback for native writes
-- that bypass managed methods; and SCQManager lifecycle observation.
--
-- Recording follows GUI Debug Mode by default; console overrides:
--   drap_trace_start()/drap_trace_stop() force on/off, drap_trace_auto()
--   follows debug mode, drap_trace_marker("text") annotates, drap_trace_status().
--
-- Output: reframework/data/AP_DRDR_flag_trace_<ts>.jsonl
-- (flat filename: io.open cannot create directories)

local Shared = require("DRAP/Shared")

local M = Shared.create_module("FlagTraceRecorder")
M:set_throttle(0.25)

local efm_mgr = M:add_singleton("efm", "app.solid.gamemastering.EventFlagsManager")
local scq_mgr = M:add_singleton("scq", "app.solid.gamemastering.SCQManager")
local am_mgr  = M:add_singleton("am",  "app.solid.gamemastering.AreaManager")
local gm_mgr  = M:add_singleton("gm",  "app.solid.gamemastering.GameManager")

local EFM_TYPE = "app.solid.gamemastering.EventFlagsManager"
local SCQ_TYPE = "app.solid.gamemastering.SCQManager"

local FLAG_SLOTS = 131  -- 4192 bits / 32

------------------------------------------------------------
-- Recording state
------------------------------------------------------------

-- forced = nil follows GUI Debug Mode; true/false = console override.
-- Defaults ON for the research phase; drap_trace_auto() returns to debug-gated.
local forced = true
local hooks_installed = false
local hook_attempted = false
local session_path = nil
local session_announced = false

local buffer = {}
local BUFFER_FLUSH_LINES = 100
local last_flush = 0
local FLUSH_INTERVAL = 2.0

-- Shadow of the event-flag slots, updated by hooks AND polls; the poll
-- only emits records for bits that differ from the shadow (i.e. writes
-- that came through a path the hooks don't cover).
local shadow = nil

-- Context cache, refreshed each throttled tick (cheap singleton reads).
local ctx = { area = nil, event_no = nil, case = nil, mdate = nil, in_game = false }

local function is_recording()
    if forced ~= nil then return forced end
    local ok, gui = pcall(require, "DRAP/GUI")
    return ok and gui and gui.is_debug and gui.is_debug() or false
end

------------------------------------------------------------
-- JSONL encoding (hand-rolled so a pretty-printer can't break one-line format)
------------------------------------------------------------

local function esc(s)
    s = tostring(s)
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r")
    return s
end

local function enc_val(v)
    local t = type(v)
    if t == "number" then
        if v % 1 == 0 then return string.format("%d", v) end
        return string.format("%.3f", v)
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif t == "table" then
        local parts = {}
        for k, sub in pairs(v) do
            table.insert(parts, string.format('"%s":%s', esc(k), enc_val(sub)))
        end
        table.sort(parts)
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return '"' .. esc(v) .. '"'
end

local function encode_record(rec)
    local parts = {}
    for k, v in pairs(rec) do
        table.insert(parts, string.format('"%s":%s', esc(k), enc_val(v)))
    end
    table.sort(parts)
    return "{" .. table.concat(parts, ",") .. "}"
end

------------------------------------------------------------
-- File output
------------------------------------------------------------

local function ensure_session()
    if session_path then return end
    session_path = string.format("AP_DRDR_flag_trace_%s.jsonl", os.date("%Y%m%d_%H%M%S"))
end

local function flush()
    if #buffer == 0 then return end
    ensure_session()
    local ok, err = pcall(function()
        local f = io.open(session_path, "a")
        if not f then error("open failed") end
        f:write(table.concat(buffer, "\n") .. "\n")
        f:close()
    end)
    if ok then
        buffer = {}
        if not session_announced then
            session_announced = true
            M.log("Trace session -> reframework/data/" .. session_path)
        end
    else
        -- Keep the buffer; retry next flush. Cap so a persistent I/O
        -- failure can't grow memory without bound.
        if #buffer > 5000 then buffer = {} end
    end
    last_flush = os.clock()
end

local function emit(rec)
    if not is_recording() then return end
    rec.t = math.floor(os.clock() * 1000) / 1000
    rec.area = ctx.area
    rec.evno = ctx.event_no
    rec.case_no = ctx.case
    rec.mdate = ctx.mdate
    table.insert(buffer, encode_record(rec))
    if #buffer >= BUFFER_FLUSH_LINES then flush() end
end

------------------------------------------------------------
-- Context refresh
------------------------------------------------------------

local function refresh_context()
    ctx.in_game = Shared.is_in_game()

    local am = am_mgr:get()
    if am then
        local f = am_mgr:get_field("mAreaIndex", false)
        if f then ctx.area = Shared.to_int(Shared.safe_get_field(am, f)) end
    end

    local gm = gm_mgr:get()
    if gm then
        local ok, v = pcall(function() return gm:get_field("mEventNo") end)
        if ok and v ~= nil then ctx.event_no = tonumber(v) end
    end

    local scq = scq_mgr:get()
    if scq then
        local ok1, c = pcall(function() return scq:get_field("mCase") end)
        if ok1 and c ~= nil then ctx.case = tonumber(c) end
        -- mDate is a property; the raw field read returns nil, use the getter.
        local ok2, d = pcall(function() return scq:call("get_mDate") end)
        if ok2 and d ~= nil then ctx.mdate = tonumber(d) end
    end
end

------------------------------------------------------------
-- Was this write caused by DRAP itself?
------------------------------------------------------------

local function drap_write_active()
    local su = _G.AP and _G.AP.ScoopUnlocker
    if su and su.is_currently_unlocking then
        local ok, v = pcall(su.is_currently_unlocking)
        return ok and v == true
    end
    return false
end

------------------------------------------------------------
-- Shadow helpers
------------------------------------------------------------

local function read_all_slots()
    local efm = efm_mgr:get()
    if not efm then return nil end
    local slots = {}
    for i = 0, FLAG_SLOTS - 1 do
        local ok, v = pcall(function() return efm:call("getEventFlag", i) end)
        if not ok or v == nil then return nil end
        slots[i] = tonumber(v) or 0
    end
    return slots
end

-- Returns true/false for a shadowed flag state, or nil when the shadow
-- isn't baselined yet (record everything until the first poll lands).
local function shadow_get_bit(flag_id)
    if not shadow then return nil end
    local slot = math.floor(flag_id / 32)
    local cur = shadow[slot]
    if cur == nil then return nil end
    return (cur & (1 << (flag_id % 32))) ~= 0
end

local function shadow_set_bit(flag_id, on)
    if not shadow then return end
    local slot = math.floor(flag_id / 32)
    local bit = flag_id % 32
    local cur = shadow[slot]
    if cur == nil then return end
    if on then
        shadow[slot] = cur | (1 << bit)
    else
        shadow[slot] = cur & ~(1 << bit)
    end
end

------------------------------------------------------------
-- Hooks
------------------------------------------------------------

local function argint(a)
    if a == nil then return -1 end
    local ok, v = pcall(sdk.to_int64, a)
    if ok and v ~= nil then return (tonumber(v) or -1) & 0xFFFFFFFF end
    return -1
end

local function hook_method(td, sig, pre_fn)
    local m = td:get_method(sig)
    if not m then
        -- Exact signature may not match this build; retry with the bare
        -- name (REFramework resolves the first overload).
        local bare = sig:match("^([^(]+)")
        if bare and bare ~= sig then m = td:get_method(bare) end
    end
    if not m then
        M.log("hook MISS: " .. sig)
        return false
    end
    local ok = pcall(sdk.hook, m, function(args)
        pcall(pre_fn, args)
        return args
    end, function(retval) return retval end)
    if not ok then M.log("hook FAIL: " .. sig) end
    return ok
end

local function install_hooks()
    if hooks_installed or hook_attempted then return end
    local efm_td = sdk.find_type_definition(EFM_TYPE)
    if not efm_td then return end
    hook_attempted = true

    -- Single-bit writes (both overloads; uint is common). State-aware: the
    -- engine calls evFlagOff on already-off housekeeping flags every frame
    -- (tens of thousands of no-op records), so only emit on real state changes.
    for _, sig in ipairs({ "evFlagOn(System.UInt32)", "evFlagOn(solid.MT2RE.EventFlag)" }) do
        hook_method(efm_td, sig, function(args)
            local fid = argint(args[3])
            if shadow_get_bit(fid) ~= true then
                emit({ ev = "set", flag = fid, src = "hook", drap = drap_write_active() })
                shadow_set_bit(fid, true)
            end
        end)
    end
    for _, sig in ipairs({ "evFlagOff(System.UInt32)", "evFlagOff(solid.MT2RE.EventFlag)" }) do
        hook_method(efm_td, sig, function(args)
            local fid = argint(args[3])
            if shadow_get_bit(fid) ~= false then
                emit({ ev = "clear", flag = fid, src = "hook", drap = drap_write_active() })
                shadow_set_bit(fid, false)
            end
        end)
    end

    -- Bulk writes ScoopUnlocker's evFlagOn hook never sees. Poll-diff catches
    -- the per-flag deltas; these records preserve WHICH path fired.
    hook_method(efm_td, "orEventFlag(System.UInt32, System.UInt32)", function(args)
        emit({ ev = "bulk_or", slot = argint(args[3]), mask = argint(args[4]),
               drap = drap_write_active() })
    end)
    hook_method(efm_td, "setEventFlag(System.UInt32, System.UInt32)", function(args)
        emit({ ev = "bulk_set", slot = argint(args[3]), value = argint(args[4]),
               drap = drap_write_active() })
    end)
    hook_method(efm_td, "clearAllEventFlag", function(args)
        emit({ ev = "clear_all" })
    end)
    hook_method(efm_td, "eventFlagClear(app.solid.gamemastering.EventFlagsManager.EVENT_CLEAR_TYPE)", function(args)
        emit({ ev = "flag_clear_type", clear_type = argint(args[3]) })
    end)
    hook_method(efm_td, "clearEventFlagOffset(app.solid.gamemastering.EventOffsets)", function(args)
        emit({ ev = "clear_offset", offset = argint(args[3]) })
    end)

    -- NpcManager record lifecycle: every NpcBaseInfo add/remove with its stype
    -- and state. Instruments the zeroed-record theory -- a failed spawn may
    -- leave a default record (stype 0) that collides with Burt and blocks his
    -- future spawns; an add with stype=0/state=0 mid-scoop is the smoking gun.
    local npc_td = sdk.find_type_definition("app.solid.gamemastering.NpcManager")
    if npc_td then
        local function npc_info_summary(args)
            local out = { stype = -1, state = -1 }
            pcall(function()
                local info = sdk.to_managed_object(args[3])
                if not info then return end
                local td = info:get_type_definition()
                local nf = td and td:get_field("<Name>k__BackingField")
                local sf = td and td:get_field("mLiveState")
                if nf then
                    local v = nf:get_data(info)
                    out.stype = tonumber(v) or tonumber(tostring(v)) or -1
                end
                if sf then
                    local v = sf:get_data(info)
                    out.state = tonumber(v) or tonumber(tostring(v)) or -1
                end
            end)
            return out
        end
        -- Real creation methods per docs (addInformation/registInformation/
        -- setInformation all MISS on this build):
        --   createInformation(SurvivorType, uint attr) -- makes the record
        --   entryNpcBaseInfo(GameObject, NpcBaseInfo)  -- binds spawned NPC
        hook_method(npc_td, "createInformation", function(args)
            emit({ ev = "npc_record_create",
                   stype = argint(args[3]), attr = argint(args[4]) })
        end)
        hook_method(npc_td, "entryNpcBaseInfo", function(args)
            emit({ ev = "npc_record_entry" })
        end)
        hook_method(npc_td, "spawnNPC", function(args)
            emit({ ev = "npc_spawn_call", stype = argint(args[3]) })
        end)
        hook_method(npc_td, "removeInformation(app.solid.npc.NpcBaseInfo)", function(args)
            local s = npc_info_summary(args)
            emit({ ev = "npc_record_remove", stype = s.stype, state = s.state })
        end)
    end

    -- SCQManager lifecycle -- Phase 0 verification targets for the rework.
    local scq_td = sdk.find_type_definition(SCQ_TYPE)
    if scq_td then
        hook_method(scq_td, "finishSCQ(System.Byte, System.Boolean)", function(args)
            emit({ ev = "scq_finish", scq_no = argint(args[3]),
                   success = argint(args[4]) ~= 0 })
        end)
        hook_method(scq_td, "notfiyDataRead(app.solid.SolidStorage)", function(args)
            emit({ ev = "save_read" })
        end)
        hook_method(scq_td, "notfiyDataWrite(app.solid.SolidStorage)", function(args)
            emit({ ev = "save_write" })
        end)
        hook_method(scq_td, "callRadio", function(args)
            emit({ ev = "radio_call" })
        end)
        hook_method(scq_td, "NpcScoopGet(System.String, app.solid.gamemastering.SCQManager.SCQ_DISP_TYPE, System.Byte)", function(args)
            local name = nil
            pcall(function()
                local s = sdk.to_managed_object(args[3])
                if s then name = s:call("ToString") end
            end)
            emit({ ev = "npc_scoop_get", npc = name or "?" })
        end)
    else
        M.log("SCQManager type not found -- lifecycle hooks skipped")
    end

    hooks_installed = true
    M.log("Trace hooks installed (flag writes + bulk paths + SCQ lifecycle)")
end

------------------------------------------------------------
-- Poll-diff: catch native writes the managed hooks miss
------------------------------------------------------------

local function poll_diff()
    local current = read_all_slots()
    if not current then return end

    if not shadow then
        shadow = current
        emit({ ev = "baseline", nonzero_slots = (function()
            local n = 0
            for _, v in pairs(current) do if v ~= 0 then n = n + 1 end end
            return n
        end)() })
        return
    end

    for slot = 0, FLAG_SLOTS - 1 do
        local before = shadow[slot] or 0
        local after = current[slot] or 0
        if before ~= after then
            local went_on = after & ~before
            local went_off = before & ~after
            for bit = 0, 31 do
                local fid = slot * 32 + bit
                if went_on & (1 << bit) ~= 0 then
                    emit({ ev = "set", flag = fid, src = "poll" })
                end
                if went_off & (1 << bit) ~= 0 then
                    emit({ ev = "clear", flag = fid, src = "poll" })
                end
            end
        end
    end
    shadow = current
end

------------------------------------------------------------
-- Frame driver (self-registered: must keep running during cutscenes, where
-- AP_DRDR_main's isInGame-gated loop stops calling modules)
------------------------------------------------------------

function M.on_frame()
    install_hooks()
    if not M:should_run() then return end
    if not is_recording() then
        -- Drop the shadow when paused so resuming re-baselines instead of
        -- reporting the whole gap as one giant burst of transitions.
        shadow = nil
        return
    end
    refresh_context()
    poll_diff()
    if #buffer > 0 and os.clock() - last_flush >= FLUSH_INTERVAL then
        flush()
    end
end

re.on_frame(function()
    pcall(M.on_frame)
end)

------------------------------------------------------------
-- Console
------------------------------------------------------------

_G.drap_trace_start = function()
    forced = true
    M.log("Trace recording FORCED ON")
end

_G.drap_trace_stop = function()
    flush()
    forced = false
    M.log("Trace recording FORCED OFF")
end

_G.drap_trace_auto = function()
    forced = nil
    M.log("Trace recording follows GUI Debug Mode")
end

-- Programmatic annotation from other DRAP modules, captured with full flag
-- context for the offline analyzer. No-op while not recording.
function M.note(text)
    emit({ ev = "note", note = tostring(text or "") })
    flush()
end

_G.drap_trace_marker = function(text)
    if not is_recording() then
        M.log("Not recording -- marker dropped (drap_trace_start() first)")
        return
    end
    emit({ ev = "marker", note = tostring(text or "") })
    flush()
    M.log("Marker recorded: " .. tostring(text))
end

_G.drap_trace_status = function()
    M.log(string.format(
        "recording=%s (forced=%s) hooks=%s session=%s buffered=%d",
        tostring(is_recording()), tostring(forced), tostring(hooks_installed),
        tostring(session_path or "not started"), #buffer))
end

return M
