-- DRAP/SaveDiagnostics.lua
-- Passive "Failed to Save" capture.
--
-- Hooks the SaveDataManager save flow, keeps a ring buffer of recent save
-- events, and dumps state + history to drap_save_failures.log whenever an
-- error-path method fires. One captured failure identifies the cause
-- (usually the Steam ~200 MB save quota -- see the README).
--
-- Console:
--   drap_save_snapshot()         -- log current SaveDataManager state
--   drap_save_capture_status()   -- capture state + counts
--   drap_save_capture_dump()     -- flush ring buffer + state on demand
--   drap_save_capture_clear()    -- delete the failures log

local Shared = require("DRAP/Shared")

local M = Shared.create_module("SaveDiag")

------------------------------------------------------------
-- Configuration
------------------------------------------------------------

local SDM_TYPE         = "app.solid.gamemastering.SaveDataManager"
local SAVE_MODE_TYPE   = "app.solid.gamemastering.SaveDataManager.SaveMode"
local SAVE_LOAD_STEP   = "app.solid.gamemastering.SaveDataManager.SaveLoadStep"
local SAVE_RESULT_TYPE = "via.storage.saveService.SaveResult"
local SAVE_SERVICE     = "via.storage.saveService.SaveService"

local FAILURES_FILE = "drap_save_failures.log"
local RING_SIZE = 120
local MAX_INSTALL_TRIES = 600

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local safe = Shared.safe

local function tdef(name) return sdk.find_type_definition(name) end
local function get_sdm() return sdk.get_managed_singleton(SDM_TYPE) end

local function argint(a)
    if a == nil then return -1 end
    local ok, v = pcall(sdk.to_int64, a)
    if ok and v ~= nil then return tonumber(v) or -1 end
    return -1
end

-- Enum field name <-> value maps, filled lazily once the types load.
local function enum_map(type_name)
    local td = tdef(type_name)
    if not td then return {} end
    local out = {}
    for _, f in ipairs(td:get_fields()) do
        local ok_s, is_static = pcall(function() return f:is_static() end)
        local ok_l, is_literal = pcall(function() return f:is_literal() end)
        if ok_s and ok_l and is_static and is_literal then
            local v = safe(function() return f:get_data(nil) end)
            table.insert(out, { name = f:get_name(), value = tonumber(v) or v })
        end
    end
    table.sort(out, function(a, b)
        return (tonumber(a.value) or 0) < (tonumber(b.value) or 0)
    end)
    return out
end

local CACHE = { mode = nil, step = nil, result = nil }
local function ensure_enums()
    if not CACHE.mode   or #CACHE.mode   == 0 then CACHE.mode   = enum_map(SAVE_MODE_TYPE)   end
    if not CACHE.step   or #CACHE.step   == 0 then CACHE.step   = enum_map(SAVE_LOAD_STEP)   end
    if not CACHE.result or #CACHE.result == 0 then CACHE.result = enum_map(SAVE_RESULT_TYPE) end
end

local function enum_name(map, value)
    if not map or value == nil then return tostring(value) end
    local v = tonumber(value) or value
    for _, e in ipairs(map) do
        if (tonumber(e.value) or e.value) == v then return e.name end
    end
    return tostring(value)
end

------------------------------------------------------------
-- Capture State (in _G so it survives script reloads)
------------------------------------------------------------

_G.DRAP_SAVE_CAPTURE = _G.DRAP_SAVE_CAPTURE or {
    enabled = true,
    installed = false,
    install_tries = 0,
    ring = { head = 1, count = 0, items = {} },
    failures = 0,
    events = 0,
    last_failure = nil,   -- { reason, when } for the GUI
    start_time = os.clock(),
}
local C = _G.DRAP_SAVE_CAPTURE

local function ring_push(line)
    if not C.enabled then return end
    C.events = C.events + 1
    local stamp = string.format("[%8.3f] %s", os.clock() - C.start_time, line)
    C.ring.items[C.ring.head] = stamp
    C.ring.head = (C.ring.head % RING_SIZE) + 1
    if C.ring.count < RING_SIZE then C.ring.count = C.ring.count + 1 end
end

local function ring_emit(file)
    local start = C.ring.head - C.ring.count
    if start < 1 then start = start + RING_SIZE end
    for i = 0, C.ring.count - 1 do
        local idx = ((start - 1 + i) % RING_SIZE) + 1
        if C.ring.items[idx] then file:write(C.ring.items[idx] .. "\n") end
    end
end

------------------------------------------------------------
-- State Snapshot
------------------------------------------------------------

local function snapshot_lines()
    local lines = {}
    local function w(s) table.insert(lines, s) end
    local save = get_sdm()
    if not save then
        w("  (SaveDataManager singleton not live)")
        return lines
    end
    local function fld(n) return safe(function() return save:get_field(n) end) end
    local function meth(n) return safe(function() return save:call(n) end) end
    ensure_enums()

    w(string.format("  SlotId=%s  SaveIdx=%s  LoadIdx=%s  ReqState=%s  Step=%s (%s)",
        tostring(fld("SlotId")), tostring(fld("SaveGameDataIndex")),
        tostring(fld("LoadGameDataIndex")), tostring(fld("RequestState")),
        tostring(fld("_SaveLoadStepState")),
        enum_name(CACHE.step, fld("_SaveLoadStepState"))))
    w(string.format("  IsBusy=%s SaveBusy=%s LoadBusy=%s RemoveBusy=%s ErrorBusy=%s ErrDlgBusy=%s",
        tostring(meth("get_IsBusy")), tostring(meth("get_IsSaveBusy")),
        tostring(meth("get_IsLoadBusy")), tostring(meth("get_IsRemoveBusy")),
        tostring(meth("get_IsErrorBusy")), tostring(meth("get_IsErrorDialogBusy"))))
    w(string.format("  isNoErrorSave=%s isNoErrorLoad=%s isSaveStateIdle=%s RequestIdle=%s",
        tostring(meth("isNoErrorSave")), tostring(meth("isNoErrorLoad")),
        tostring(meth("isSaveStateIdle")), tostring(meth("get_RequestIdle"))))
    w(string.format("  LastErrType=%s  WarnState=%s",
        tostring(fld("LastErrorTypeValue")), tostring(fld("WarningStateValue"))))
    w(string.format("  GetSlotNeedSize=%s bytes", tostring(meth("getSlotNeedSize"))))

    -- The mount path is what DRAP redirects; mount-related failures show
    -- up here, and so does the storage layer's own view: its size figures,
    -- and the last result it recorded. A capture without these could only
    -- say that the write waited and failed. Steam's file count follows:
    -- its 30-file cap is the failure seen so far (result 51), and it still
    -- applies to vanilla saves.
    for _, ln in ipairs(M.space_lines()) do w(ln) end
    local store = AP and AP.SteamStore
    if store and store.store_lines then
        local ok, slines = pcall(store.store_lines)
        if ok then for _, ln in ipairs(slines) do w(ln) end end
    end
    return lines
end

-- via.storage.saveService.SaveResult, the values a PC build can report.
-- A static table: resolving the enum through the SDK at connect froze the
-- game (2026-09-10).
local SAVE_RESULT_NAMES = {
    [0] = "Null", [1] = "Doing", [2] = "Success", [3] = "Cancel",
    [15] = "Failed_MountError", [19] = "Failed_FileOpenError",
    [20] = "Failed_FileWriteError", [25] = "Failed_SlotLimitOver",
    [27] = "Failed_SaveDataSizeMaxOver", [29] = "Failed_OutOfDiskFreeSpace",
    [51] = "Failed_Steam_SaveError", [52] = "Failed_Steam_LoadError",
    [53] = "Failed_Steam_RemoveError", [54] = "Failed_Steam_NotFireCallback",
    [55] = "Failed_Steam_OutOfDiskFreeSpace", [56] = "Failed_NoSteam",
}

local function save_result_text(v)
    local n = tonumber(v)
    local name = n and SAVE_RESULT_NAMES[n]
    return name and string.format("%s (%s)", tostring(v), name) or tostring(v)
end

--- The save service's mount and space figures, one line each.
function M.space_lines()
    local out = {}
    local svc_td = tdef(SAVE_SERVICE)
    if not svc_td then return out end
    local svc = sdk.get_managed_singleton(SAVE_SERVICE)
        or sdk.get_native_singleton(SAVE_SERVICE)
    if not svc then return out end
    local function get(name)
        local m = svc_td:get_method(name)
        if not m then return "n/a" end
        local v = safe(function() return m:call(svc) end)
        return v == nil and "nil" or tostring(v)
    end
    table.insert(out, string.format("  SaveMountPath=%s", get("get_SaveMountPath")))
    -- ForceWindows selects the plain-file backend SaveSlot uses under a
    -- redirect; false means Steam remote storage.
    table.insert(out, string.format("  ForceWindows=%s  SaveDirectoryPath=%s  FakeOwner=%s  OverrideAccountId=%s",
        get("get_ForceWindows"), get("get_SaveDirectoryPath"),
        get("get_FakeOwner"), get("get_OverrideSaveAccountId")))
    table.insert(out, string.format("  SaveDataSize=%s  Max=%s  Min=%s  FreeSpace=%s",
        get("get_SaveDataSize"), get("get_SaveDataMaxSize"),
        get("get_SaveDataMinSize"), get("get_SaveDataFreeSpaceSize")))
    table.insert(out, string.format("  LastErrorCode=%s  LastShortErrorCode=%s  LastCheckExisting=%s  LastSaveResult=%s",
        get("get_LastErrorCode"), get("get_LastShortErrorCode"),
        get("get_LastCheckExistingResult"), save_result_text(get("get_LastSaveResult"))))
    -- The detail table is the service's view of the slots on the current
    -- mount. The redirect asks for it to be rebuilt and never checks the
    -- answer; a slot size of 16 bytes at failure says it never was.
    table.insert(out, string.format("  Segment=%s  DetailTblEnabled=%s  DetailUpdateRequest=%s  LastDetailUpdate=%s  DetailTblCount=%s",
        get("get_SaveServiceSegment"), get("get_SaveFileDetailTblEnabled"),
        get("get_SaveFileDetailUpdateRequest"), get("get_LastUpdateSaveFileDetailResult"),
        get("getSaveFileDetailTblCount")))
    return out
end

_G.drap_save_space = function()
    for _, ln in ipairs(M.space_lines()) do M.log(ln) end
    local store = AP and AP.SteamStore
    if store and store.store_lines then
        for _, ln in ipairs(store.store_lines()) do M.log(ln) end
    end
end

------------------------------------------------------------
-- Failure Dump
------------------------------------------------------------

local function dump_failure(reason)
    if not C.enabled then return end
    C.failures = C.failures + 1
    C.last_failure = { reason = reason, when = os.date() }
    local f, err = io.open(FAILURES_FILE, "a")
    if not f then
        M.log.error("failure log open failed: " .. tostring(err))
        return
    end
    f:write(string.format(
        "\n========== [%s] %s  (failure #%d, t=%.3f) ==========\n",
        os.date(), reason, C.failures, os.clock() - C.start_time))
    f:write("--- SaveDataManager state at failure ---\n")
    for _, ln in ipairs(snapshot_lines()) do f:write(ln .. "\n") end
    f:write(string.format("--- recent save events (last %d) ---\n", C.ring.count))
    ring_emit(f)
    f:write("==========================================\n")
    f:flush()
    f:close()
    M.log.error(string.format("SAVE FAILURE captured (#%d, %s) -> %s",
        C.failures, reason, FAILURES_FILE))
end

------------------------------------------------------------
-- Hooks
------------------------------------------------------------

local function install_hooks()
    if C.installed then return true end
    local sdm_td = tdef(SDM_TYPE)
    if not sdm_td then
        C.install_tries = C.install_tries + 1
        return false
    end
    ensure_enums()

    local function hook_pre_named(method_name, on_pre)
        local m = sdm_td:get_method(method_name)
        if not m then
            M.log("MISS hook: " .. method_name)
            return false
        end
        local ok, err = pcall(sdk.hook, m, function(args)
            if not C.enabled then return end
            local ok2, e = pcall(on_pre, args)
            if not ok2 then M.log("hook err " .. method_name .. ": " .. tostring(e)) end
        end, nil)
        if not ok then
            M.log("hook install failed " .. method_name .. ": " .. tostring(err))
            return false
        end
        return true
    end

    -- Activity events (ring buffer only)
    hook_pre_named("requestSaveGameData", function(args)
        ring_push(string.format("requestSaveGameData(mode=%s, slot=%d)",
            enum_name(CACHE.mode, argint(args[3])), argint(args[4])))
    end)
    hook_pre_named("requestSaveGameDataAuto", function()
        ring_push("requestSaveGameDataAuto()")
    end)
    hook_pre_named("requestSaveSystemData", function()
        ring_push("requestSaveSystemData()")
    end)
    hook_pre_named("requestSaveSystemDataNoSaveIcon", function()
        ring_push("requestSaveSystemDataNoSaveIcon()")
    end)
    hook_pre_named("requestRemoveGameData", function(args)
        ring_push(string.format("requestRemoveGameData(mode=%s, slot=%d)",
            enum_name(CACHE.mode, argint(args[3])), argint(args[4])))
    end)
    hook_pre_named("doCheckSpaceStart", function() ring_push("> doCheckSpaceStart") end)
    hook_pre_named("doCheckSpace",      function() ring_push("  doCheckSpace") end)
    hook_pre_named("doCheckSpaceEnd",   function() ring_push("< doCheckSpaceEnd") end)
    hook_pre_named("doSave",            function() ring_push("> doSave") end)
    hook_pre_named("doSaveWait",        function() ring_push("  doSaveWait") end)
    hook_pre_named("flushSaveData",     function() ring_push("  flushSaveData") end)

    -- isSpaceFreePC's argument is the via.storage SaveResult code.
    hook_pre_named("isSpaceFreePC", function(args)
        local code = argint(args[3])
        ring_push(string.format("isSpaceFreePC(SaveResult=%s [%d])",
            enum_name(CACHE.result, code), code))
    end)

    -- Failure/error path -- trigger points that flush the capture.
    hook_pre_named("doErrorAutoSaveFailure", function()
        ring_push("!!! doErrorAutoSaveFailure")
        dump_failure("doErrorAutoSaveFailure")
    end)
    hook_pre_named("doErrorSaveStart", function(args)
        local step = argint(args[3])
        ring_push(string.format("!!! doErrorSaveStart(step=%s)",
            enum_name(CACHE.step, step)))
        dump_failure("doErrorSaveStart step=" .. enum_name(CACHE.step, step))
    end)
    hook_pre_named("doErrorSaveAgain", function(args)
        ring_push(string.format("!!! doErrorSaveAgain(next=%s, end=%s)",
            enum_name(CACHE.step, argint(args[3])),
            enum_name(CACHE.step, argint(args[4]))))
        dump_failure("doErrorSaveAgain")
    end)
    hook_pre_named("openSaveErrorDialog_PC", function()
        ring_push("!!! openSaveErrorDialog_PC")
        dump_failure("openSaveErrorDialog_PC")
    end)
    hook_pre_named("doErrorAutoSaveSuccess", function()
        ring_push("    doErrorAutoSaveSuccess (recovery ok)")
    end)

    -- The storage service's side: the request the manager makes and the
    -- answer it gets. A failing save whose ring shows flushSaveData then
    -- doSaveWait with no saveSingle between never asked the service at all.
    -- Both saveSingle overloads fold-checked unique (2026-09-10).
    local svc_td = tdef(SAVE_SERVICE)
    if svc_td then
        local pending_slot = nil
        local function hook_svc(sig, label, with_slot)
            local m = svc_td:get_method(sig)
            if not m then M.log("MISS hook: SaveService." .. sig); return end
            local ok, err = pcall(sdk.hook, m,
                function(args)
                    if not C.enabled then return end
                    pending_slot = with_slot and argint(args[3]) or nil
                end,
                function(retval)
                    if not C.enabled then return retval end
                    local accepted = false
                    pcall(function() accepted = (sdk.to_int64(retval) & 0xFF) ~= 0 end)
                    ring_push(string.format("  SaveService.%s(%s) -> %s", label,
                        pending_slot == nil and "" or tostring(pending_slot),
                        accepted and "accepted" or "REFUSED"))
                    return retval
                end)
            if not ok then M.log("hook install failed SaveService." .. sig .. ": " .. tostring(err)) end
        end
        hook_svc("saveSingle()", "saveSingle", false)
        hook_svc("saveSingle(System.Int32)", "saveSingle", true)
        -- setSaveFileDetail is folded with set_SystemSaveFileDetail (2
        -- aliases); not hookable.
    end

    C.installed = true
    M.log("Save-failure hooks installed (passive capture active).")
    return true
end

------------------------------------------------------------
-- Per-frame Update
------------------------------------------------------------

function M.on_frame()
    if C.installed then return end
    if C.install_tries > MAX_INSTALL_TRIES then return end
    install_hooks()
end

------------------------------------------------------------
-- Console Commands
------------------------------------------------------------

function _G.drap_save_snapshot()
    for _, ln in ipairs(snapshot_lines()) do M.log(ln) end
end

function _G.drap_save_capture_status()
    M.log(string.format(
        "enabled=%s installed=%s events=%d failures=%d ring=%d/%d log=%s",
        tostring(C.enabled), tostring(C.installed),
        C.events, C.failures, C.ring.count, RING_SIZE, FAILURES_FILE))
end

function _G.drap_save_capture_dump()
    dump_failure("manual_dump")
end

function _G.drap_save_capture_clear()
    local f = io.open(FAILURES_FILE, "w")
    if f then f:close(); M.log("cleared " .. FAILURES_FILE) end
    C.ring.head = 1
    C.ring.count = 0
    C.ring.items = {}
end

return M
