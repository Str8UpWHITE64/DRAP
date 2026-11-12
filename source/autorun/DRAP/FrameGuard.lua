-- DRAP/FrameGuard.lua
-- Every callback DRAP hands to re.on_frame (and the other re.on_* registers)
-- runs inside its own protected call.
--
-- REFramework runs a script state's frame callbacks in one loop, and an error
-- escaping one of them ends that loop for the frame: every callback registered
-- after it is skipped. A module that throws every frame therefore stops the
-- rest of DRAP -- item delivery, checks, Restricted Items, door locks, the
-- logger's own periodic lines -- while the game carries on, and the error goes
-- only to REFramework's log. Here a failing callback is caught, logged to the
-- session log, and the others keep running.
--
-- Only callbacks defined in DRAP's own files are wrapped; another script's
-- callbacks reach REFramework unchanged. Required first by AP_DRDR_main, so it
-- covers every module, including callbacks registered later at runtime.

local Logger = require("DRAP/Logger")

local M = {}

local TAG = "frameguard"
local REPORT_EVERY = 30.0      -- seconds between repeat reports per callback

local REGISTERS = {
    "on_frame", "on_draw_ui", "on_pre_application_entry",
    "on_application_entry", "on_config_save", "on_script_reset",
}

local failures = {}            -- label -> { count, since_report, last_report, last_err }
local installed = false
local wrapped = 0              -- callbacks wrapped so far

local function source_of(fn)
    if type(debug) ~= "table" or type(debug.getinfo) ~= "function" then return nil end
    local ok, info = pcall(debug.getinfo, fn, "S")
    if not ok or type(info) ~= "table" then return nil end
    return info
end

--- True for a function defined in one of DRAP's files.
local function is_ours(info)
    local src = info and info.source
    if type(src) ~= "string" then return false end
    return src:find("[/\\]DRAP[/\\]") ~= nil or src:find("^@?DRAP[/\\]") ~= nil
        or src:find("[/\\]AP_REF[/\\]") ~= nil or src:find("^@?AP_REF[/\\]") ~= nil
        or src:find("AP_DRDR_main", 1, true) ~= nil
end

local function label_for(kind, info)
    local src = tostring(info.short_src or info.source or "?")
    src = src:gsub("^.*[/\\]autorun[/\\]", "")
    return string.format("%s %s:%s", kind, src, tostring(info.linedefined or "?"))
end

local function traceback(e)
    if type(debug) == "table" and type(debug.traceback) == "function" then
        return debug.traceback(tostring(e), 2)
    end
    return tostring(e)
end

local function report(label, err)
    local f = failures[label]
    local now = os.clock()
    if not f then
        f = { count = 0, since_report = 0, last_report = now }
        failures[label] = f
        f.count, f.last_err = 1, err
        Logger.error(TAG, string.format("%s failed (the other callbacks keep running): %s",
            label, tostring(err)))
        return
    end
    f.count = f.count + 1
    f.since_report = f.since_report + 1
    f.last_err = err
    if now - f.last_report >= REPORT_EVERY then
        local first_line = tostring(err):match("^[^\n]*") or tostring(err)
        Logger.error(TAG, string.format("%s still failing: %d time(s) in the last %.0f s, %d in all: %s",
            label, f.since_report, now - f.last_report, f.count, first_line))
        f.since_report = 0
        f.last_report = now
    end
end

local function finish(label, ok, ...)
    if ok then return ... end
    pcall(report, label, (...))
end

local function wrap(kind, fn)
    local info = source_of(fn)
    if not is_ours(info) then return fn end
    local label = label_for(kind, info)
    wrapped = wrapped + 1
    return function(...)
        return finish(label, xpcall(fn, traceback, ...))
    end
end

--- Replace each re.on_* register with one that wraps DRAP's callbacks.
function M.install()
    if installed then return true end
    if type(re) ~= "table" and type(re) ~= "userdata" then return false end
    local done = 0
    for _, name in ipairs(REGISTERS) do
        local ok_get, orig = pcall(function() return re[name] end)
        if ok_get and orig ~= nil then
            local replacement = function(...)
                local n = select("#", ...)
                local args = { ... }
                -- The callback is the last argument (on_pre_application_entry
                -- takes the entry name first).
                if n > 0 and type(args[n]) == "function" then
                    args[n] = wrap(name, args[n])
                end
                return orig(table.unpack(args, 1, n))
            end
            local ok_set = pcall(function() re[name] = replacement end)
            local ok_read, now = pcall(function() return re[name] end)
            if ok_set and ok_read and now == replacement then done = done + 1 end
        end
    end
    installed = done > 0
    Logger.info(TAG, string.format("%d callback register(s) guarded", done))
    return installed
end

--- How many of DRAP's callbacks are guarded.
function M.wrapped_count() return wrapped end

--- Failing callbacks so far: { [label] = { count, last_err } }.
function M.failures()
    local out = {}
    for label, f in pairs(failures) do out[label] = { count = f.count, last_err = f.last_err } end
    return out
end

_G.drap_frame_errors = function()
    local any = false
    for label, f in pairs(failures) do
        any = true
        Logger.info(TAG, string.format("%s: %d failure(s), last: %s", label, f.count,
            tostring(f.last_err):match("^[^\n]*")))
    end
    if not any then Logger.info(TAG, "no callback has failed") end
    return any
end

return M
