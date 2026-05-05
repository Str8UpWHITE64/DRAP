-- DRAP/MsgEvents.lua
-- Two-backend message-event watcher. See docs/reframework/features/msg_events.md.
--
--   Status list (PP-bonus floats) -> PSM.setScoreBuff(score, msg_no, etc)
--   All other lists               -> MessageManager.queue/set/voice/cutscene
--
-- Used by AP_LocationTriggers to convert in-game events into AP location
-- checks. State persisted in _G so it survives REFramework script reloads.

local M = {}

local PSM_TYPE = "app.solid.PlayerStatusManager"
local MM_TYPE  = "app.solid.gamemastering.MessageManager"

local Shared = require("DRAP/Shared")
local log = Shared.create_logger("MsgEvents")

-- The 18 message-list names. Resolved on first lookup via
-- MessageManager.get_MessageList<Name>() to a byte value.
local MSG_LISTS = {
    "Scoop", "Item", "Radio", "Status", "Notebook", "ToDo", "Shop", "System",
    "Broadcast", "ClosedCaption", "Voice", "Event",
    "EVB", "EVCH_A", "EVCH_B", "EVM", "EVS", "Sys360",
}
local _list_byte_cache = {}
local _list_name_by_byte = {}

local function _resolve_list_byte(name)
    if type(name) == "number" then return name end
    if _list_byte_cache[name] ~= nil then return _list_byte_cache[name] end
    local td = sdk.find_type_definition(MM_TYPE)
    if not td then return nil end
    local m = td:get_method("get_MessageList" .. name)
    if not m then return nil end
    local ok, v = pcall(function() return m:call(nil) end)
    if not ok or v == nil then return nil end
    local b = tonumber(v)
    _list_byte_cache[name] = b
    _list_name_by_byte[b] = name
    return b
end

------------------------------------------------------------
-- Internal state (persisted across script reloads via _G)
------------------------------------------------------------
-- Keys are STRINGS to avoid a Lua VM "invalid key to 'next'" issue with
-- integer-keyed tables in _G. See docs/.../msg_events.md.

local function _key(msg_no) return "msg_" .. tostring(msg_no) end

_G._DRAP_MSGEVENTS_STATE = _G._DRAP_MSGEVENTS_STATE or {
    watchers = {},        -- watchers["msg_<N>"] = { cb, once, gate_score, msg_no }
    mm_watchers = {},     -- mm_watchers["L<byte>"]["msg_<N>"] = { cb, once, msg_no, list_byte, list_name }
    watch_hook_installed = false,
    mm_hook_installed = false,
}
local STATE = _G._DRAP_MSGEVENTS_STATE
-- Defensive: older revisions may have stored partial state.
STATE.watchers              = STATE.watchers or {}
STATE.mm_watchers           = STATE.mm_watchers or {}
if STATE.watch_hook_installed == nil then STATE.watch_hook_installed = false end
if STATE.mm_hook_installed    == nil then STATE.mm_hook_installed    = false end

local watchers = STATE.watchers
local mm_watchers = STATE.mm_watchers

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function argint(a)
    local ok, v = pcall(sdk.to_int64, a)
    if ok then return tonumber(v) or -1 end
    return -1
end

------------------------------------------------------------
-- PP-event watcher hook (Status list via setScoreBuff)
------------------------------------------------------------

local function install_watch_hook()
    if STATE.watch_hook_installed then return true end
    local td = sdk.find_type_definition(PSM_TYPE)
    if not td then log("PSM type missing"); return false end
    local m = td:get_method("setScoreBuff")
    if not m then log("setScoreBuff method missing"); return false end

    local pending = nil

    sdk.hook(m,
        function(args)
            -- args[3]=score, args[4]=msg_no, args[5]=etc (all uint32)
            pending = {
                score  = argint(args[3]),
                msg_no = argint(args[4]),
                etc    = argint(args[5]),
            }
        end,
        function(retval)
            local p = pending; pending = nil
            if not p then return retval end
            -- Look up via _G so old closures still find the live state
            -- after a script reload.
            local current = _G._DRAP_MSGEVENTS_STATE
                            and _G._DRAP_MSGEVENTS_STATE.watchers or watchers
            local w = current[_key(p.msg_no)]
            if w then
                -- The engine fires twice per event: score=0 (slot reserve)
                -- then score=N (actual award). gate_score=true (default)
                -- suppresses the prelude.
                local gate = w.gate_score
                if gate == nil then gate = true end
                if gate and p.score == 0 then return retval end

                local ok, err = pcall(w.cb, p.score, p.msg_no, p.etc)
                if not ok then
                    log(string.format("watcher cb error for msg_no=%d: %s",
                        p.msg_no, tostring(err)))
                end
                if w.once then current[_key(p.msg_no)] = nil end
            else
                -- Diagnostic: log unwatched fires (score>0 only, skipping
                -- the noisy slot-reserve calls). Helps debug "I did event X
                -- and nothing happened" -- a wrong msg_no surfaces here.
                if p.score and p.score > 0 then
                    log(string.format(
                        "setScoreBuff unwatched: msg_no=%d score=%d etc=%d",
                        p.msg_no, p.score, p.etc))
                end
            end
            return retval
        end)

    STATE.watch_hook_installed = true
    log("setScoreBuff watcher hook installed")
    return true
end

------------------------------------------------------------
-- MessageManager hook (queue / set / voice / cutscene)
------------------------------------------------------------

local function install_mm_hook()
    if STATE.mm_hook_installed then return true end
    local td = sdk.find_type_definition(MM_TYPE)
    if not td then log("MessageManager type missing"); return false end

    local function hook_one(sig, label)
        local m = td:get_method(sig)
        if not m then return end
        sdk.hook(m,
            function(args)
                local id   = argint(args[3])
                local list = argint(args[4])
                -- Lookup via _G + string keys (same rationale as the
                -- Status hook above).
                local mm = _G._DRAP_MSGEVENTS_STATE
                           and _G._DRAP_MSGEVENTS_STATE.mm_watchers or mm_watchers
                local list_table = mm["L" .. tostring(list)]
                if not list_table then return end
                local k = "msg_" .. tostring(id)
                local w = list_table[k]
                if not w then return end
                local ok, err = pcall(w.cb, id, list, label)
                if not ok then
                    log(string.format("mm-watcher cb error for %s/%d: %s",
                        _list_name_by_byte[list] or tostring(list), id, tostring(err)))
                end
                if w.once then list_table[k] = nil end
            end,
            function(retval) return retval end)
    end

    hook_one("queue(System.UInt32, System.Byte, app.solid.gamemastering.MessageManager.MESS_QUEUE_FLAG)", "queue")
    hook_one("set(System.UInt32, System.Byte, app.solid.gamemastering.MessageManager.MESS_QUEUE_FLAG)",   "set")
    hook_one("setVoiceMessage(System.UInt32, app.solid.gamemastering.MessageManager.MESS_QUEUE_FLAG)",    "voice")
    hook_one("drawCutsceneMessage(System.UInt32, System.Byte)",                                            "cutscene")

    STATE.mm_hook_installed = true
    log("MessageManager queue/set/voice/cutscene watcher hook installed")
    return true
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

-- Watch a Status-list msg_no fire via setScoreBuff.
-- callback signature: function(score, msg_no, etc)
-- opts:
--   once       -- auto-unregister after first fire (default false)
--   gate_score -- if true (default), suppress score=0 slot-reserve prelude
function M.watch(msg_no, callback, opts)
    msg_no = tonumber(msg_no)
    if not msg_no then log("watch: msg_no required"); return false end
    if type(callback) ~= "function" then log("watch: callback required"); return false end
    install_watch_hook()
    opts = opts or {}
    local k = _key(msg_no)
    watchers[k] = {
        cb         = callback,
        once       = opts.once and true or false,
        gate_score = (opts.gate_score == nil) and true or (opts.gate_score and true or false),
        msg_no     = msg_no,
    }
    log(string.format("watching msg_no=%d (once=%s, gate_score=%s)",
        msg_no, tostring(watchers[k].once),
        tostring(watchers[k].gate_score)))
    return true
end

-- Watch a (list, msg_no) pair via MessageManager.queue/set/voice/cutscene.
-- callback signature: function(msg_no, list_byte, label)
-- where label is "queue" / "set" / "voice" / "cutscene".
function M.watch_message(list_name, msg_no, callback, opts)
    local list_byte = _resolve_list_byte(list_name)
    if list_byte == nil then
        log("watch_message: unknown list " .. tostring(list_name)); return false
    end
    msg_no = tonumber(msg_no)
    if not msg_no then log("watch_message: msg_no required"); return false end
    if type(callback) ~= "function" then log("watch_message: callback required"); return false end
    install_mm_hook()
    opts = opts or {}
    local outer = "L" .. tostring(list_byte)
    local inner = "msg_" .. tostring(msg_no)
    mm_watchers[outer] = mm_watchers[outer] or {}
    mm_watchers[outer][inner] = {
        cb         = callback,
        once       = opts.once and true or false,
        msg_no     = msg_no,
        list_byte  = list_byte,
        list_name  = list_name,
    }
    log(string.format("watching %s[%d] (once=%s)",
        list_name, msg_no, tostring(mm_watchers[outer][inner].once)))
    return true
end

-- Clear in-place so STATE.watchers and the local alias stay pointed at the
-- same table. Reassigning to {} would orphan the global reference.
function M.unwatch_all()
    for k in pairs(watchers) do watchers[k] = nil end
    for k in pairs(mm_watchers) do mm_watchers[k] = nil end
end

function M.list_watchers()
    local out = {}
    for _, v in pairs(watchers) do
        if v and v.msg_no then
            table.insert(out, { msg_no = v.msg_no, once = v.once, gate_score = v.gate_score })
        end
    end
    table.sort(out, function(a, b) return a.msg_no < b.msg_no end)
    return out
end

function M.register()
    -- No-op marker. Hooks install lazily on first watch() / watch_message() call.
end

------------------------------------------------------------
-- Console commands
------------------------------------------------------------

-- Quick test: watch a msg_no and log every fire.
_G.drap_msgevents_watch = function(msg_no, label)
    label = label or ("msg_" .. tostring(msg_no))
    M.watch(msg_no, function(score, mn, etc)
        log(string.format("FIRED: %s (msg=%d, score=%d, etc=%d)", label, mn, score, etc))
    end)
end

_G.drap_msgevents_unwatch_all = function()
    M.unwatch_all()
    log("cleared all watchers")
end

-- Hard-reset _G state. Use after upgrading across a script-key format
-- change (e.g. integer -> string keys); reconnect AP afterward to rebuild.
_G.drap_msgevents_reset_state = function()
    _G._DRAP_MSGEVENTS_STATE = nil
    log("STATE wiped. Reconnect AP to re-register watchers.")
end

_G.drap_msgevents_list_watchers = function()
    log(string.format("watch_hook_installed=%s mm_hook_installed=%s",
        tostring(STATE.watch_hook_installed),
        tostring(STATE.mm_hook_installed)))

    -- Status watchers
    local sorted = {}
    for _, w in pairs(watchers) do
        if w and w.msg_no then table.insert(sorted, w) end
    end
    table.sort(sorted, function(a, b) return (a.msg_no or 0) < (b.msg_no or 0) end)
    log("Status watchers count = " .. #sorted)
    for _, w in ipairs(sorted) do
        log(string.format("  msg_no=%d once=%s gate_score=%s",
            w.msg_no, tostring(w.once), tostring(w.gate_score)))
    end

    -- MessageManager watchers
    local mm_sorted = {}
    for _, list_table in pairs(mm_watchers) do
        for _, w in pairs(list_table) do
            if w and w.msg_no then table.insert(mm_sorted, w) end
        end
    end
    table.sort(mm_sorted, function(a, b)
        if (a.list_byte or 0) ~= (b.list_byte or 0) then
            return (a.list_byte or 0) < (b.list_byte or 0)
        end
        return (a.msg_no or 0) < (b.msg_no or 0)
    end)
    log("MessageManager watchers count = " .. #mm_sorted)
    for _, w in ipairs(mm_sorted) do
        log(string.format("  %s[%d] once=%s",
            w.list_name or ("byte=" .. tostring(w.list_byte)),
            w.msg_no, tostring(w.once)))
    end
end

return M
