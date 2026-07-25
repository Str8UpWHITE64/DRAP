-- DRAP/Logger.lua
-- Per-session log file sink. See docs/reframework/features/logging.md.
--
-- Every module logs through Shared.create_logger(), which funnels here. This
-- module mirrors each line to the script console (as before) and appends it to
-- a timestamped file under reframework/data/DRAP_Logs/, one file per launch so
-- yesterday's evidence survives today's session.
--
-- Load order note: nothing in DRAP may be required from this file. Shared.lua
-- requires Logger, and Shared is the first require in every other module, so a
-- back-reference here would be circular. Logger depends only on the REFramework
-- globals (io/os/json/fs) and stands up on its own at require time.

local Logger = {}

------------------------------------------------------------
-- Version
------------------------------------------------------------

--- Client-side mod version, stamped into every log header so a pasted log
--- identifies its own build. tools/build_release.py fails the build when this
--- drifts from world_version in apworld/drdr/archipelago.json -- bump both.
Logger.VERSION = "1.1.0"

------------------------------------------------------------
-- Levels
------------------------------------------------------------

Logger.LEVELS = { DEBUG = 10, INFO = 20, WARN = 30, ERROR = 40 }

-- Padded for column alignment in the file; trimmed by level_short for prose.
local LEVEL_LABEL = {
    [10] = "DEBUG",
    [20] = "INFO ",
    [30] = "WARN ",
    [40] = "ERROR",
}

--- @param level number
--- @return string Level label without padding, e.g. "WARN"
local function level_short(level)
    local name = (LEVEL_LABEL[level] or "?"):gsub(" ", "")
    return name
end

------------------------------------------------------------
-- Tunables
------------------------------------------------------------

local LOG_DIR = "DRAP_Logs"

-- A module that throws inside on_frame produces the same line 60x/second.
-- Consecutive identical lines collapse into a "repeated N times" rollup, which
-- is flushed when a different line arrives or after this many seconds.
local DUP_ROLLUP_SECONDS = 5.0

-- Backstop for spam that alternates between two messages (which defeats the
-- consecutive-duplicate collapse). Lines past the budget in a one-second window
-- are dropped and counted, never silently discarded.
local MAX_LINES_PER_SECOND = 300

-- Hard ceiling so a runaway loop can't fill a player's disk. Console output
-- continues after the cap; only the file stops growing.
local MAX_FILE_BYTES = 32 * 1024 * 1024

-- Session files kept in DRAP_Logs before older ones are pruned (best effort --
-- see prune_old_logs).
local KEEP_SESSIONS = 20

-- Lines held in memory for the GUI's Log tab.
local RECENT_LINES = 200

------------------------------------------------------------
-- State
------------------------------------------------------------

local S = {
    stamp = nil,           -- "20260725_143012"
    path = nil,            -- relative path actually opened, or nil
    handle = nil,
    start_clock = os.clock(),
    start_date = os.date("%Y-%m-%d %H:%M:%S"),

    file_min = Logger.LEVELS.DEBUG,     -- everything reaches the file
    console_min = Logger.LEVELS.INFO,   -- console stays as noisy as it was

    bytes = 0,
    capped = false,

    -- counters
    counts = { total = 0, debug = 0, info = 0, warn = 0, error = 0,
               dropped = 0, collapsed = 0, bad_level = 0 },

    -- consecutive-duplicate collapse
    dup_key = nil,
    dup_count = 0,
    dup_first_clock = 0,

    -- Concurrency instrumentation. Lua is single-threaded per state, so a
    -- write that starts while another is still in progress means something
    -- re-entered us -- either a native callback calling back into Lua, or a
    -- second OS thread running the same state. Both corrupt records.
    depth = 0,
    main_thread = nil,
    reentrant = 0,
    offthread = 0,
    threads_seen = {},
    deferred = {},

    -- per-second rate limit window
    window_start = 0,
    window_lines = 0,
    window_dropped = 0,

    -- flush pacing
    last_flush = 0,

    -- GUI ring buffer
    recent = {},
    recent_head = 0,
}

------------------------------------------------------------
-- Text Sanitizing
------------------------------------------------------------

--- Rebuilds a string from printable ASCII only. Engine strings arrive as UTF-16
--- remnants and null-padded buffers; writing those raw produces log files that
--- text editors refuse to open.
--- @param s any
--- @return string
local function scrub(s)
    if s == nil then return "nil" end
    local str = type(s) == "string" and s or tostring(s)
    local null_pos = str:find("%z")
    if null_pos then str = str:sub(1, null_pos - 1) end

    local out = {}
    for i = 1, #str do
        local b = string.byte(str, i)
        if (b >= 32 and b <= 126) or b == 9 then
            out[#out + 1] = string.char(b)
        elseif b == 10 then
            -- Keep multi-line payloads on one record so grep-per-line works.
            out[#out + 1] = " | "
        end
    end
    return table.concat(out)
end

Logger.scrub = scrub

------------------------------------------------------------
-- File Setup
------------------------------------------------------------

--- Writes DRAP_Logs/latest.json, a one-glance pointer at the newest session
--- for bug reports. It also brings the directory into existence: json.dump_file
--- creates missing parent directories (this is how AP_DRDR_Items/ appears on a
--- fresh install) whereas plain io.open does not.
--- @param log_name string|nil Bare filename of this session's log
--- @return boolean True if the write succeeded
local function write_dir_pointer(log_name)
    -- `json` is a REFramework global and is always present in practice, but a
    -- nil here would be evaluated before pcall could catch it, and nothing in
    -- this file is allowed to take the mod down with it.
    if type(json) ~= "table" and type(json) ~= "userdata" then return false end

    local ok, wrote = pcall(json.dump_file, LOG_DIR .. "/latest.json", {
        session      = log_name or "(opening)",
        path         = log_name and (LOG_DIR .. "/" .. log_name) or nil,
        started      = S.start_date,
        drap_version = Logger.VERSION,
    }, 4)
    return ok and wrote ~= false
end

--- Opens path for writing only if nothing is there yet, so a second instance
--- (or a same-second script reset) never shares a handle with the first.
--- @param path string
--- @return file|nil
local function open_if_free(path)
    local existing = io.open(path, "r")
    if existing then
        existing:close()
        return nil
    end
    return io.open(path, "w")
end

--- Opens the session file, appending a numeric suffix when the name is taken.
--- Prefers DRAP_Logs/; falls back to the data root if the directory can't be
--- created (older REFramework build, read-only data dir), which is where every
--- other DRAP file already lands.
--- @return file|nil handle
--- @return string|nil path
local function open_session_file()
    local base = "drap_" .. S.stamp
    local dir_ready = write_dir_pointer(nil)

    for _, prefix in ipairs(dir_ready and { LOG_DIR .. "/", "" } or { "" }) do
        for attempt = 0, 9 do
            local name = (attempt == 0) and (base .. ".log")
                                        or string.format("%s_%d.log", base, attempt)
            local f = open_if_free(prefix .. name)
            if f then
                if dir_ready then write_dir_pointer(name) end
                return f, prefix .. name
            end
        end
    end

    return nil, nil
end

--- Best-effort retention. os.remove is not part of REFramework's io sandbox, so
--- on some builds it resolves against the game's working directory and simply
--- fails -- harmless, because the guarded pattern below can only ever name a
--- DRAP session log. The outcome is verified against fs.glob and reported in
--- the header, so a no-op shows up as "prune unsupported" rather than silence.
--- @return table Array of session-log paths, newest last
local function list_session_logs()
    if type(fs) ~= "table" and type(fs) ~= "userdata" then return {} end

    -- fs.glob takes a std::regex, not a Lua pattern, and REFramework reports
    -- paths with the platform separator. Try the backslash form first (matching
    -- the probes in investigation/) and fall back to the forward-slash form.
    local files
    for _, rx in ipairs({ [[DRAP_Logs\\drap_.*\.log]], [[DRAP_Logs/drap_.*\.log]] }) do
        local ok, res = pcall(fs.glob, rx)
        if ok and type(res) == "table" and #res > 0 then
            files = res
            break
        end
    end
    if not files then return {} end

    local names = {}
    for _, f in ipairs(files) do
        -- Filenames embed a sortable %Y%m%d_%H%M%S stamp, so lexical order is
        -- chronological order.
        if type(f) == "string" and f:match("drap_%d+_%d+.*%.log$") then
            names[#names + 1] = f
        end
    end
    table.sort(names)
    return names
end

Logger.list_session_logs = list_session_logs

--- @param keep number How many of the newest sessions to retain
--- @return number removed
--- @return number remaining
local function prune_old_logs(keep)
    local names = list_session_logs()
    local current = S.path and S.path:match("([^/\\]+)$")

    local removed = 0
    for i = 1, #names - keep do
        -- Separator style can differ between fs.glob and our own path, so
        -- protect the open file by basename rather than by full path.
        local base = names[i]:match("([^/\\]+)$")
        if base ~= current and pcall(os.remove, names[i]) then
            removed = removed + 1
        end
    end

    return removed, #list_session_logs()
end

------------------------------------------------------------
-- Raw Emit
------------------------------------------------------------

--- Appends a preformatted record to the session file, honouring the size cap
--- and flushing on a short interval so a hard crash loses at most ~1s of tail.
--- @param text string
--- @param urgent boolean|nil Flush immediately (warnings and errors)
local function emit_file(text, urgent)
    if not S.handle or S.capped then return end

    local line = text .. "\n"
    S.bytes = S.bytes + #line

    if S.bytes > MAX_FILE_BYTES then
        S.capped = true
        pcall(function()
            S.handle:write(string.format(
                "\n[logger] size cap reached (%d MB) -- file closed, console logging continues\n",
                math.floor(MAX_FILE_BYTES / (1024 * 1024))))
            S.handle:flush()
            S.handle:close()
        end)
        S.handle = nil
        return
    end

    -- A disk error here would otherwise propagate out of whatever module
    -- happened to be logging. Losing the log is acceptable; taking a feature
    -- down with it is not, so the sink retires itself instead.
    local ok = pcall(function()
        S.handle:write(line)
        local now = os.clock()
        if urgent or (now - S.last_flush) >= 1.0 then
            S.handle:flush()
            S.last_flush = now
        end
    end)

    if not ok then
        S.capped = true
        pcall(function() S.handle:close() end)
        S.handle = nil
        print("[logger] write failed -- session file closed, console logging continues")
    end
end

--- Identifies the calling OS thread. REFramework dispatches a script callback
--- on whatever thread the game happened to call it from, and the RE Engine VM
--- keeps a per-thread context, so the context pointer doubles as a cheap thread
--- id. Returns a short hex tail, or "?" when the sdk isn't usable yet.
--- @return string
local function thread_tag()
    if type(sdk) ~= "table" and type(sdk) ~= "userdata" then return "?" end
    local ok, ctx = pcall(sdk.get_thread_context)
    if not ok or ctx == nil then return "?" end
    return (tostring(ctx):match("(%x%x%x%x%x)%s*$")) or "?"
end

--- Mirrors a record into REFramework's own log (re2_framework_log.txt), which
--- is a different sink from print(). Two reasons to bother: DRAP lines end up
--- interleaved with REFramework's own hook and script errors, which is useful
--- context when diagnosing a crash, and it leaves a second copy if the session
--- file never opened. That file is truncated on every launch -- which is the
--- whole reason the session log exists -- so this supplements it, never
--- replaces it.
--- @param level number
--- @param text string
local function emit_framework_log(level, text)
    if type(log) ~= "table" and type(log) ~= "userdata" then return end
    local fn = (level >= Logger.LEVELS.ERROR and log.error)
            or (level >= Logger.LEVELS.WARN and log.warn)
            or log.info
    if fn then pcall(fn, text) end
end

--- Stores a record in the GUI ring buffer.
--- @param text string
local function push_recent(text)
    S.recent_head = (S.recent_head % RECENT_LINES) + 1
    S.recent[S.recent_head] = text
end

--- Formats one record: wall clock, elapsed seconds, level, tag, message.
--- @param level number
--- @param tag string
--- @param msg string
--- @return string
local function format_line(level, tag, msg)
    local label = LEVEL_LABEL[level]
    if label == nil then
        -- A constant integer key missing from a constant table means the Lua
        -- state is damaged. Count it rather than quietly printing "?????".
        S.counts.bad_level = S.counts.bad_level + 1
        label = "?????"
    end

    -- Mark records written from a thread other than the one that loaded us.
    -- Normal records stay in the documented format; anything off-thread is
    -- meant to be impossible to miss.
    local t = thread_tag()
    local marker = ""
    if S.main_thread and t ~= "?" and t ~= S.main_thread then
        S.offthread = S.offthread + 1
        S.threads_seen[t] = (S.threads_seen[t] or 0) + 1
        marker = " !THREAD:" .. t
    end

    return string.format("%s  +%09.3f  %s  [%s]%s %s",
        os.date("%H:%M:%S"),
        os.clock() - S.start_clock,
        label,
        tag,
        marker,
        msg)
end

--- Writes a record to file + GUI buffer, and to the console when the level
--- clears the console threshold.
--- @param level number
--- @param tag string
--- @param msg string
local function deliver(level, tag, msg)
    local line = format_line(level, tag, msg)

    if level >= S.file_min then
        emit_file(line, level >= Logger.LEVELS.WARN)
        push_recent(line)
    end

    if level >= S.console_min then
        -- INFO keeps the historical "[Tag] message" console format; anything
        -- else is worth calling out by name.
        if level == Logger.LEVELS.INFO then
            print("[" .. tag .. "] " .. msg)
        else
            print("[" .. tag .. "] " .. level_short(level) .. ": " .. msg)
        end
        emit_framework_log(level, "[" .. tag .. "] " .. msg)
    end
end

--- Emits the pending "repeated N times" rollup, if any.
local function flush_duplicates()
    if S.dup_count > 0 then
        deliver(Logger.LEVELS.INFO, "logger",
            string.format("last message repeated %d more time(s) over %.1fs",
                S.dup_count, os.clock() - S.dup_first_clock))
        S.counts.collapsed = S.counts.collapsed + S.dup_count
    end
    S.dup_key = nil
    S.dup_count = 0
end

------------------------------------------------------------
-- Public Write Path
------------------------------------------------------------

-- Forward declaration so Logger.write can call it before it is defined, and so
-- `function write_impl(...)` below assigns the local rather than a global.
local write_impl

--- Core sink. Every DRAP log line arrives here.
---
--- Wraps write_impl with a re-entrancy guard. Lua is single-threaded per state,
--- so if a second call arrives while the first is still inside the file write,
--- something re-entered us: a native callback calling back into Lua, or a second
--- OS thread running this state. Either one interleaves the FILE* buffer and
--- produces truncated records. When that happens the record is queued instead of
--- written, so the instrumentation cannot itself scramble the evidence.
--- @param tag string Module name
--- @param level number A Logger.LEVELS value
--- @param msg any Message (sanitized here)
function Logger.write(tag, level, msg)
    if S.main_thread == nil then S.main_thread = thread_tag() end

    if S.depth > 0 then
        S.reentrant = S.reentrant + 1
        S.deferred[#S.deferred + 1] = { tag = tag, level = level, msg = msg,
                                        thread = thread_tag() }
        -- Bound it: if re-entry is constant, we must not grow without limit.
        if #S.deferred > 4096 then table.remove(S.deferred, 1) end
        return
    end

    S.depth = 1
    local ok, err = pcall(write_impl, tag, level, msg)
    S.depth = 0

    -- Drain anything that arrived while we were inside the write.
    if #S.deferred > 0 then
        local pending = S.deferred
        S.deferred = {}
        S.depth = 1
        for _, d in ipairs(pending) do
            pcall(write_impl, d.tag, d.level,
                  "[deferred from thread " .. tostring(d.thread) .. "] " .. tostring(d.msg))
        end
        S.depth = 0
    end

    if not ok then
        S.depth = 0
        print("[logger] write failed: " .. tostring(err))
    end
end

--- The real write path.
--- @param tag string
--- @param level number
--- @param msg any
function write_impl(tag, level, msg)
    level = level or Logger.LEVELS.INFO
    tag = scrub(tag or "DRAP")
    msg = scrub(msg)
    if msg == "" or msg == "nil" then return end

    -- Counters track what was logged, including lines later collapsed or
    -- dropped, so the GUI's totals don't lie about how much happened.
    S.counts.total = S.counts.total + 1
    if level >= Logger.LEVELS.ERROR then
        S.counts.error = S.counts.error + 1
    elseif level >= Logger.LEVELS.WARN then
        S.counts.warn = S.counts.warn + 1
    elseif level >= Logger.LEVELS.INFO then
        S.counts.info = S.counts.info + 1
    else
        S.counts.debug = S.counts.debug + 1
    end

    local now = os.clock()

    -- Collapse consecutive identical records.
    local key = level .. "\1" .. tag .. "\1" .. msg
    if key == S.dup_key then
        S.dup_count = S.dup_count + 1
        if (now - S.dup_first_clock) >= DUP_ROLLUP_SECONDS then
            local held, since = S.dup_count, S.dup_first_clock
            S.dup_key, S.dup_count = nil, 0
            deliver(Logger.LEVELS.INFO, "logger",
                string.format("last message repeated %d more time(s) over %.1fs",
                    held, now - since))
            S.counts.collapsed = S.counts.collapsed + held
            -- Keep collapsing the same message in the next window.
            S.dup_key = key
            S.dup_first_clock = now
        end
        return
    end
    flush_duplicates()
    S.dup_key = key
    S.dup_first_clock = now

    -- Per-second budget for spam the collapse above can't catch. Warnings and
    -- errors are exempt: a flood of routine chatter must never be able to hide
    -- the failure that follows it, which is the whole reason the file exists.
    if level < Logger.LEVELS.WARN then
        if (now - S.window_start) >= 1.0 then
            if S.window_dropped > 0 then
                deliver(Logger.LEVELS.WARN, "logger", string.format(
                    "rate limit: dropped %d line(s) in the last second", S.window_dropped))
            end
            S.window_start = now
            S.window_lines = 0
            S.window_dropped = 0
        end

        S.window_lines = S.window_lines + 1
        if S.window_lines > MAX_LINES_PER_SECOND then
            -- Counted as it happens, so the GUI never reads 0 dropped while
            -- lines are actively going over the side.
            S.window_dropped = S.window_dropped + 1
            S.counts.dropped = S.counts.dropped + 1
            return
        end
    end

    deliver(level, tag, msg)
end

--- Convenience wrappers used by Logger's own callers.
function Logger.debug(tag, msg) Logger.write(tag, Logger.LEVELS.DEBUG, msg) end
function Logger.info(tag, msg)  Logger.write(tag, Logger.LEVELS.INFO,  msg) end
function Logger.warn(tag, msg)  Logger.write(tag, Logger.LEVELS.WARN,  msg) end
function Logger.error(tag, msg) Logger.write(tag, Logger.LEVELS.ERROR, msg) end

------------------------------------------------------------
-- Control / Introspection
------------------------------------------------------------

--- Forces buffered records to disk. Called before risky operations and on
--- script reset; safe to call when no file is open.
function Logger.flush()
    flush_duplicates()
    if S.handle then
        pcall(S.handle.flush, S.handle)
        S.last_flush = os.clock()
    end
end

--- @return string|nil Relative path of this session's log, nil if console-only
function Logger.get_path() return S.path end

--- @return string Session stamp, e.g. "20260725_143012"
function Logger.get_stamp() return S.stamp end

--- @return boolean True when records are reaching a file
function Logger.is_file_active() return S.handle ~= nil end

--- @return table Snapshot of the line counters plus file size
function Logger.stats()
    return {
        total     = S.counts.total,
        debug     = S.counts.debug,
        info      = S.counts.info,
        warn      = S.counts.warn,
        error     = S.counts.error,
        dropped   = S.counts.dropped,
        collapsed = S.counts.collapsed,
        bytes     = S.bytes,
        capped    = S.capped,
        -- Corruption instrumentation. Any of these being non-zero means the
        -- Lua state is being used in a way it cannot survive.
        bad_level = S.counts.bad_level,
        reentrant = S.reentrant,
        offthread = S.offthread,
        threads    = S.threads_seen,
        main_thread = S.main_thread,
    }
end

--- One-line summary of the corruption counters, for the GUI and the session
--- footer. Empty string when everything is healthy.
--- @return string
function Logger.anomaly_summary()
    local bits = {}
    if S.counts.bad_level > 0 then
        bits[#bits + 1] = string.format("%d bad level lookups", S.counts.bad_level)
    end
    if S.reentrant > 0 then
        bits[#bits + 1] = string.format("%d re-entrant writes", S.reentrant)
    end
    if S.offthread > 0 then
        local names = {}
        for t, n in pairs(S.threads_seen) do names[#names + 1] = t .. "x" .. n end
        table.sort(names)
        bits[#bits + 1] = string.format("%d off-thread records (%s; main=%s)",
            S.offthread, table.concat(names, ","), tostring(S.main_thread))
    end
    return table.concat(bits, "; ")
end

--- Most recent records, oldest first, for the GUI's Log tab.
--- @param limit number|nil How many to return (default: all buffered)
--- @return table Array of formatted strings
function Logger.recent(limit)
    local out = {}
    local n = 0
    for i = 1, RECENT_LINES do
        local idx = ((S.recent_head + i - 1) % RECENT_LINES) + 1
        if S.recent[idx] then
            n = n + 1
            out[n] = S.recent[idx]
        end
    end
    if limit and n > limit then
        local trimmed = {}
        for i = n - limit + 1, n do trimmed[#trimmed + 1] = out[i] end
        return trimmed
    end
    return out
end

--- Resolves a level name to its numeric value.
--- @param name string|number "DEBUG".."ERROR" or a LEVELS value
--- @return number|nil
function Logger.level_value(name)
    if type(name) == "number" then return name end
    return Logger.LEVELS[tostring(name):upper()]
end

--- Sets the minimum level written to the session file. Defaults to DEBUG;
--- raising it means losing detail from the artifact players send us, so this
--- exists for troubleshooting the logger itself rather than routine use.
--- @param name string|number
function Logger.set_file_level(name)
    local v = Logger.level_value(name)
    if v then
        S.file_min = v
        Logger.info("logger", "file level set to " .. (LEVEL_LABEL[v] or "?"))
    end
end

--- Sets the minimum level printed to the script console.
--- @param name string|number
function Logger.set_console_level(name)
    local v = Logger.level_value(name)
    if v then
        S.console_min = v
        Logger.info("logger", "console level set to " .. (LEVEL_LABEL[v] or "?"))
    end
end

--- @return number file minimum level
--- @return number console minimum level
function Logger.get_levels() return S.file_min, S.console_min end

--- @param level number
--- @return string Trimmed level label, e.g. "WARN"
function Logger.level_name(level) return level_short(level) end

------------------------------------------------------------
-- Session Start
------------------------------------------------------------

--- Reads an engine/framework detail without letting a missing API abort the
--- header. Older REFramework builds don't expose every getter, and sol2 hands
--- some bound members back as callable userdata rather than plain functions --
--- so callability is established by pcall rather than by type().
--- @param fn any
--- @param ... any
--- @return string
local function probe(fn, ...)
    if fn == nil then return "n/a" end
    local ok, v = pcall(fn, ...)
    if ok and v ~= nil then return scrub(v) end
    return "n/a"
end

--- Opens the file and writes the header block. Runs once, at require time.
local function start_session()
    S.stamp = os.date("%Y%m%d_%H%M%S")
    S.window_start = os.clock()
    S.last_flush = os.clock()

    local handle, path = open_session_file()
    S.handle = handle
    S.path = path

    if not handle then
        print("[logger] could not open a session log file -- console output only")
        return
    end

    local removed, remaining = prune_old_logs(KEEP_SESSIONS)

    local head = {
        "============================================================",
        " Dead Rising Archipelago (DRAP) session log",
        "============================================================",
        " started        : " .. S.start_date,
        " session file   : " .. path,
        " DRAP version   : " .. Logger.VERSION,
        " game           : " .. probe(reframework and reframework.get_game_name, reframework),
        " REFramework    : " .. probe(reframework and reframework.get_commit_hash, reframework)
                             .. " / " .. probe(reframework and reframework.get_tag, reframework),
        " RF build       : " .. probe(reframework and reframework.get_build_date, reframework)
                             .. " " .. probe(reframework and reframework.get_build_time, reframework),
        " TDB version    : " .. probe(sdk and sdk.get_tdb_version),
        " retention      : " .. (removed > 0
                                    and string.format("pruned %d, %d session(s) kept", removed, remaining)
                                 or string.format("prune unsupported on this build, %d session(s) kept", remaining)),
        "------------------------------------------------------------",
        " Columns: wall-clock  +elapsed-seconds  LEVEL  [Module] message",
        " Attach this whole file to bug reports.",
        "============================================================",
        "",
    }
    handle:write(table.concat(head, "\n") .. "\n")
    handle:flush()
    S.bytes = 0  -- the header is overhead, not part of the growth budget
end

-- Every DRAP module requires Shared, and Shared requires this file, so a throw
-- at this point would take the whole mod offline over a logging problem.
-- Degrade to console-only instead.
do
    local ok, err = pcall(start_session)
    if not ok then
        if S.handle then pcall(function() S.handle:close() end) end
        S.handle = nil
        S.path = nil
        print("[logger] session log setup failed (" .. tostring(err) ..
              ") -- console output only")
    end
end

-- REFramework tears the Lua state down on "Reset Scripts" and on exit paths
-- that get that far. Close the file cleanly so the tail isn't lost.
if re and re.on_script_reset then
    re.on_script_reset(function()
        Logger.info("logger", "session ending (script reset)")
        Logger.flush()
        if S.handle then
            pcall(S.handle.close, S.handle)
            S.handle = nil
        end
    end)
end

------------------------------------------------------------
-- Console Helpers
------------------------------------------------------------

_G.drap_log_path = function()
    print("[logger] " .. tostring(S.path or "console only"))
    return S.path
end

_G.drap_log_flush = function() Logger.flush() end

return Logger
