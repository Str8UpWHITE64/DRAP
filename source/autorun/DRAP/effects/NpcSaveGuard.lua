-- DRAP/effects/NpcSaveGuard.lua
-- Guards the NPC block of the game save against silent truncation.
--
-- The save stores NPC records as a COUNT plus a FIXED array allocated once:
--   SolidSave.npcnum  : uint32                     (0x158)
--   SolidSave.npcWork : NPC_STORAGE_BASE_INFO[]    (0xc8, capacity set at ctor)
-- NpcManager.notfiyDataWrite serializes NpcInfoList into that array; count
-- and entries are independent, so ANY disagreement between them round-trips
-- as: the uncounted-for records' data is gone, and the reader -- told by
-- npcnum to expect entries that were never written -- materializes the gap
-- as allocated-but-never-filled NpcBaseInfo (stype 0, all fields zeroed:
-- the "blank records" / historical "Burt Thompson x3").
--
-- Two ways to get the disagreement:
--   * capacity overflow (list > 64). REFUTED as the field mechanism: the
--     corrupting save's npcnum was < 50 (its post-reload challenge burst
--     re-fired "Encounter 10 survivors" but not "Encounter 50", and both
--     read SolidSave.npcnum). Kept as a hard limit for long lists.
--   * count/filter mismatch: npcnum counts records the writer then skips.
--     The engine has an explicit save-eligibility notion
--     (getInformationNum(bool checkNotSave), NpcBaseInfo.IsOpeningNotSave),
--     and the corrupting save was the autosave fired ON an area transition
--     with 5 followers mid-carry-over (mCarryOverFlag/mJustLoad) -- a
--     per-record transient state at the write instant would also explain why
--     the lost set was not a clean list tail, and why it reproduces on one
--     machine's frame timing and not another's. This is the live suspect.
--
-- Field evidence (drap_20260806_232004.log, RazgrizEast): an autosave written
-- at 00:05:40 with 5 party members reloaded at 00:05:58 with Alyssa Laurent
-- (28) and Isabela Keyes (34) missing and exactly 3 blank records that had
-- never existed before that boundary. Lost count == blank count, in one
-- round-trip. A Hostile NPC Trap had created records 79/81 at 23:49; trap
-- corpses are only cleaned when the same stype re-fires, so they squat in
-- save slots regardless of which variant is live.
--
-- This module:
--   * measures the real npcWork capacity from the live SolidSave (no guess);
--   * purges unambiguous debris -- blank records and long-dead trap-pool
--     records -- from the MAIN thread on a 5s cadence (never from the save
--     thread's hooks: removeInformation there would mutate NpcInfoList
--     while the main thread iterates it);
--   * logs a census on both sides of every save boundary and NAMES any
--     record that existed at the last write but is missing after a read,
--     so a field log alone can convict or acquit the save round-trip;
--   * exposes is_save_write_in_flight() so main-thread code that mutates
--     serialized record state (PartyHudGuard) can stand down mid-write.
--
-- Purge safety:
--   * a blank is stype==0 AND state==0 AND area==0 AND hp==0 AND isDead --
--     only an allocated-and-abandoned record decodes that way; a real Burt
--     (met, killed, or spawned) always carries a nonzero area or state;
--   * a freshly created record looks blank until the engine's spawn init
--     runs, so blanks are only purged after BLANK_GRACE_SECONDS;
--   * trap-pool records (stype >= 59) are only purged when dead, and only
--     after TRAP_DEAD_GRACE_SECONDS -- a trap fired moments ago holds a
--     dead record the RAGE-promotion poll is still waiting on;
--   * healthy records are never touched: if the list is over capacity after
--     the purge, that is logged loudly (with the at-risk tail) and left alone.
--
-- Console:
--   drap_npc_capacity()          -- one-shot report: capacity, npcnum, counts
--   drap_autosave_probe()        -- is the autosave-inhibit lever usable?
--   drap_autosave_inhibit(on)    -- hold/release the autosave by hand
--   drap_npc_save_guard(on)      -- enable/disable the pre-write purge
--   drap_npc_save_guard_status() -- guard state + last boundary stats

local Shared = require("DRAP/Shared")
local SharedData = require("DRAP/SharedData")
local Logger = require("DRAP/Logger")

local M = Shared.create_module("NpcSaveGuard")

local npc_mgr = M:add_singleton("npc", "app.solid.gamemastering.NpcManager")
local ss_mgr  = M:add_singleton("ss",  "app.solid.SolidStorage")

------------------------------------------------------------
-- Configuration
------------------------------------------------------------

-- The exact stypes HostileSurvivorTrap spawns (TRAP_POOL +
-- SPECIAL_FORCES_TRAP_POOL in that module). Deliberately NOT "every stype
-- >= 59": that range also holds engine NPCs whose dead records may matter,
-- and this module deletes where the sweeper merely skips.
local TRAP_POOL_STYPES = {
    [59] = true,
    [73] = true, [74] = true, [75] = true, [76] = true, [77] = true,
    [78] = true, [79] = true, [80] = true, [81] = true, [84] = true,
}

local BLANK_GRACE_SECONDS = 60.0
local TRAP_DEAD_GRACE_SECONDS = 60.0

------------------------------------------------------------
-- State
------------------------------------------------------------

local purge_enabled = true
local hooks_installed = false

-- Grace tracking. Blanks carry no identity (every field is zero), so their
-- grace is a single timestamp: the first scan that saw any blank. Trap
-- corpses are keyed by stype -- one record exists per stype.
local blank_first_seen = nil     -- os.clock() when blanks were first seen
local trap_dead_since = {}       -- stype -> os.clock() when first seen dead

-- Stats from the most recent write, for the read-side comparison. stypes is
-- a map stype -> record count so a cross-boundary diff can name the losses.
local last_write = nil           -- { at, total, blanks, capacity, stypes }
local last_report = "no save boundary seen yet"

-- Monotonic boundary counter, embedded in every census line. Two identical
-- consecutive boundaries would otherwise be collapsed by the Logger's
-- duplicate rollup ("repeated N times") and the field log would under-count
-- save events -- the exact thing this module exists to make countable.
local boundary_seq = 0

-- Load-window tracer state, and the deferred damage prompt. These MUST be
-- declared here, not down beside the tracer that reads them: on_save_read is
-- defined earlier in this file and assigns to all three of the mutable ones.
-- A local declared after that point is a different variable -- the assignment
-- would silently create a global, the tracer would read a local that never
-- changes, and the window would appear stuck open forever (every later spawn
-- logged as a collision). See the tracer section below for what they mean.
local read_in_progress = false
local read_window_start = nil
local last_read_end = nil

local stype_to_name = nil

local function ensure_names()
    if stype_to_name then return end
    stype_to_name = {}
    for _, row in ipairs(SharedData.survivors() or {}) do
        local stype = tonumber(row.item_number)
        if row.name and stype then stype_to_name[stype] = row.name end
    end
end

local function name_of(stype)
    ensure_names()
    return stype_to_name[stype] or ("stype " .. tostring(stype))
end

------------------------------------------------------------
-- Scanning
------------------------------------------------------------

local function read_entry(info)
    local e = { info = info }
    pcall(function()
        local v = info:get_field("<Name>k__BackingField")
        e.stype = tonumber(v) or tonumber(tostring(v))
    end)
    pcall(function() e.state = tonumber(info:get_field("mLiveState")) end)
    pcall(function() e.area = tonumber(info:get_field("mAreaNo")) end)
    pcall(function() e.hp = tonumber(info:get_field("mVitalNew")) end)
    local ok_d, dead = pcall(function() return info:call("isDead") end)
    e.is_dead = ok_d and dead == true
    -- Transient / save-eligibility state. A record mid-transition (carry-over,
    -- just-load) or flagged IsOpeningNotSave is the prime suspect for being
    -- counted by npcnum yet skipped by the writer -- the mismatch that eats
    -- records and mints blanks without the list ever nearing capacity.
    pcall(function() e.carry = info:get_field("mCarryOverFlag") == true end)
    pcall(function() e.justload = info:get_field("mJustLoad") == true end)
    pcall(function() e.notsave = info:get_field("IsOpeningNotSave") == true end)
    return e
end

local function is_blank(e)
    return (e.stype or -1) == 0 and (e.state or -1) == 0
        and (e.area or -1) == 0 and (e.hp or -1) == 0 and e.is_dead
end

--- Walks NpcInfoList once. Returns nil when the manager or list is not live.
--- @return table|nil { entries, total, blanks, dead, trap_dead, stypes }
local function scan()
    local mgr = npc_mgr:get()
    if not mgr then return nil end
    local list_field = npc_mgr:get_field("NpcInfoList")
    local list = list_field and Shared.safe_get_field(mgr, list_field)
    if not list then return nil end

    local out = { entries = {}, total = 0, blanks = 0, dead = 0,
                  trap_dead = 0, carry = 0, justload = 0, notsave = 0,
                  stypes = {}, flags = {} }
    for _, info in Shared.iter_collection(list) do
        if info then
            local e = read_entry(info)
            if e.stype then
                out.total = out.total + 1
                out.stypes[e.stype] = (out.stypes[e.stype] or 0) + 1
                if e.is_dead then out.dead = out.dead + 1 end
                if is_blank(e) then out.blanks = out.blanks + 1 end
                if e.is_dead and TRAP_POOL_STYPES[e.stype] then
                    out.trap_dead = out.trap_dead + 1
                end
                if e.carry then out.carry = out.carry + 1 end
                if e.justload then out.justload = out.justload + 1 end
                if e.notsave then out.notsave = out.notsave + 1 end
                -- Worst-case OR per stype, so the read-side damage report can
                -- say what state a lost record was in when it was written.
                local f = out.flags[e.stype] or {}
                f.carry = f.carry or e.carry
                f.justload = f.justload or e.justload
                f.notsave = f.notsave or e.notsave
                out.flags[e.stype] = f
                table.insert(out.entries, e)
            end
        end
    end
    return out
end

local function flag_note(f)
    if not f then return "" end
    local tags = {}
    if f.carry then table.insert(tags, "carry-over") end
    if f.justload then table.insert(tags, "just-load") end
    if f.notsave then table.insert(tags, "not-save") end
    if #tags == 0 then return "" end
    return " [was " .. table.concat(tags, "+") .. " at the write]"
end

------------------------------------------------------------
-- Save-block capacity
------------------------------------------------------------

--- Reads the fixed NPC array's real capacity and last-written count from the
--- live SolidSave. Returns -1 for anything unavailable (early frames, title
--- screen) rather than guessing.
--- @return number capacity  npcWork array length, or -1
--- @return number npcnum    count the save block last carried, or -1
local function read_save_block()
    local ss = ss_mgr:get()
    if not ss then return -1, -1 end
    local capacity, npcnum = -1, -1
    pcall(function()
        local arr = ss:call("getnpcWork")
        if arr then
            capacity = Shared.get_collection_count(arr)
            if capacity == 0 then capacity = -1 end
        end
    end)
    pcall(function()
        local n = ss:call("getnpcnum")
        if n ~= nil then npcnum = Shared.to_int(n) or -1 end
    end)
    return capacity, npcnum
end

------------------------------------------------------------
-- Debris purge (pre-write)
------------------------------------------------------------

--- Removes unambiguous debris records so real ones fit inside the save
--- block. Runs from the notfiyDataWrite pre-hook, so removals land before
--- the engine serializes the list.
--- @param s table a scan() result
--- @return number removed
local function purge_debris(s)
    local mgr = npc_mgr:get()
    if not mgr then return 0 end
    local now = os.clock()

    -- Grace bookkeeping first, so this write can arm the next one even when
    -- purging is disabled.
    if s.blanks > 0 then
        blank_first_seen = blank_first_seen or now
    else
        blank_first_seen = nil
    end
    local seen_dead_traps = {}
    for _, e in ipairs(s.entries) do
        if TRAP_POOL_STYPES[e.stype] and e.is_dead then
            seen_dead_traps[e.stype] = true
            trap_dead_since[e.stype] = trap_dead_since[e.stype] or now
        end
    end
    for stype in pairs(trap_dead_since) do
        if not seen_dead_traps[stype] then trap_dead_since[stype] = nil end
    end

    if not purge_enabled then return 0 end

    local to_remove = {}
    for _, e in ipairs(s.entries) do
        if is_blank(e) then
            if blank_first_seen and now - blank_first_seen >= BLANK_GRACE_SECONDS then
                e.why = "blank record (allocated, never filled in)"
                table.insert(to_remove, e)
            end
        elseif TRAP_POOL_STYPES[e.stype] and e.is_dead then
            local since = trap_dead_since[e.stype]
            if since and now - since >= TRAP_DEAD_GRACE_SECONDS then
                e.why = "dead trap-pool record"
                table.insert(to_remove, e)
            end
        end
    end

    local removed, removed_blanks = 0, 0
    for _, e in ipairs(to_remove) do
        local ok = pcall(function()
            mgr:call("removeInformation(app.solid.npc.NpcBaseInfo)", e.info)
        end)
        if ok then
            removed = removed + 1
            M.log(string.format(
                "pre-save purge: removed %s -- %s, freeing a save slot",
                e.stype == 0 and "a blank record"
                    or string.format("%s (stype=%d)", name_of(e.stype), e.stype),
                e.why))
            if is_blank(e) then removed_blanks = removed_blanks + 1 end
            if TRAP_POOL_STYPES[e.stype] then
                trap_dead_since[e.stype] = nil
            end
        end
    end
    -- Only a fresh blank should get fresh grace; a purge that touched no
    -- blanks must not reset a timer that is still counting toward one.
    if removed_blanks > 0 then blank_first_seen = nil end
    return removed
end

------------------------------------------------------------
-- Boundary handlers
------------------------------------------------------------

-- Scan stashed by the write PRE-hook for the write POST-hook. npcnum is
-- written *by* notfiyDataWrite, so only the post side can compare what the
-- engine recorded against what the list held going in.
local pending_write = nil

-- The write hooks run on the SAVE thread (field-proven: varying !THREAD ids).
-- This timestamp lets main-thread code (PartyHudGuard's mLiveState flips)
-- avoid mutating serialized record state while the writer is copying it.
-- Self-expires so a post-hook that never fires cannot wedge consumers.
local save_write_at = nil
local SAVE_WRITE_WINDOW_SECONDS = 2.0

function M.is_save_write_in_flight()
    return save_write_at ~= nil
        and (os.clock() - save_write_at) < SAVE_WRITE_WINDOW_SECONDS
end

-- Debris purged on the main thread since the last write boundary, so the
-- boundary line can still report it.
local purged_since_last_write = 0

local function on_save_write_pre()
    save_write_at = os.clock()
    local s = scan()
    if not s then return end
    -- Scan only -- NO list mutation here. This hook runs on the save thread,
    -- and removeInformation from here would mutate NpcInfoList while the
    -- main thread iterates it (engine walks, HUD guard, sweeps). The purge
    -- runs from on_frame instead.
    pending_write = { s = s, removed = purged_since_last_write }
end

local function on_save_write_post()
    save_write_at = nil
    purged_since_last_write = 0
    local pw = pending_write
    pending_write = nil
    if not pw then return end
    local s = pw.s

    local capacity, npcnum = read_save_block()
    local mgr = npc_mgr:get()
    local info_num_save = -1
    if mgr then
        pcall(function()
            info_num_save = Shared.to_int(mgr:call("getInformationNum", true)) or -1
        end)
    end

    boundary_seq = boundary_seq + 1
    last_write = { at = os.clock(), total = s.total, blanks = s.blanks,
                   capacity = capacity, stypes = s.stypes, flags = s.flags }
    last_report = string.format(
        "write #%d: %d records (%d blank, %d dead, %d carry-over, %d just-load,"
            .. " %d not-save), npcnum=%s, saveEligible=%s, capacity=%s, purged=%d",
        boundary_seq, s.total, s.blanks, s.dead, s.carry, s.justload, s.notsave,
        npcnum >= 0 and tostring(npcnum) or "?",
        info_num_save >= 0 and tostring(info_num_save) or "?",
        capacity > 0 and tostring(capacity) or "?", pw.removed)
    -- File-only by default (console_min is INFO); the file threshold is
    -- hard-wired to DEBUG for every install, so this always lands in the
    -- session log with zero tester configuration.
    M.log.debug(last_report)

    -- Field-verified 2026-08-07: not-save records (IsOpeningNotSave, which
    -- the ENGINE sets on DRAP-spawned NPCs) are excluded from npcnum AND the
    -- entries COHERENTLY -- npcnum == saveEligible == entries written, and
    -- the round-trip is clean (no blanks). So npcnum != list-total is the
    -- design, not the bug. The bug is npcnum disagreeing with what the
    -- writer actually serialized -- npcnum vs getInformationNum(true) at the
    -- same boundary. Blanks are minted exactly when THAT breaks.
    if npcnum >= 0 and info_num_save >= 0 and npcnum ~= info_num_save then
        M.log.error(string.format(
            "ENGINE WRITE INCOHERENCE: npcnum=%d written but the engine"
                .. " counts %d save-eligible record(s) at the same boundary"
                .. " (total=%d, carry-over=%d, not-save=%d) -- %d record(s)"
                .. " will blank or vanish on the next load",
            npcnum, info_num_save, s.total, s.carry, s.notsave,
            math.abs(npcnum - info_num_save)))
    end

    -- A regular survivor's record reading not-save is the despawn in the
    -- making: that record is excluded from the save BY DESIGN and cannot
    -- survive a reload. Trap-pool records are expected to carry the flag
    -- (they are DRAP-spawned and their dropping on reload is desirable).
    local marked = {}
    for _, e in ipairs(s.entries) do
        if e.notsave and not TRAP_POOL_STYPES[e.stype] and e.stype ~= 0 then
            table.insert(marked, string.format("%s(stype=%d%s%s)",
                name_of(e.stype), e.stype,
                (e.state or 0) == 2 and ",JOIN" or "",
                e.is_dead and ",dead" or ""))
        end
    end
    if #marked > 0 then
        M.log.error(string.format(
            "SURVIVOR RECORD MARKED NOT-SAVE at write #%d: %s -- these"
                .. " records are excluded from the save and will not survive"
                .. " a reload",
            boundary_seq, table.concat(marked, ", ")))
    end

    -- Capacity overflow: refuted as the field mechanism (RazgrizEast's
    -- npcnum was < 50 against capacity 64) but kept as a hard limit --
    -- a long completionist list can still fall off this cliff.
    if capacity > 0 and s.total > capacity then
        local over = s.total - capacity
        local tail = {}
        for i = math.max(1, #s.entries - over + 1), #s.entries do
            local e = s.entries[i]
            table.insert(tail, string.format("%s(stype=%d%s)",
                name_of(e.stype), e.stype, e.is_dead and ",dead" or ""))
        end
        M.log.error(string.format(
            "NPC SAVE BLOCK OVERFLOW: %d records but the save array holds %d"
                .. " -- %d record(s) will not survive a save/load. List tail"
                .. " (most at risk): %s",
            s.total, capacity, over, table.concat(tail, ", ")))
    end

    -- The boundary block must be on disk NOW: a crash at the save boundary
    -- is exactly the event being diagnosed, and DEBUG/INFO lines otherwise
    -- sit in the file buffer for up to a second.
    pcall(Logger.flush)
end

local function on_save_read()
    -- Close the reconstruction window first: everything below runs after
    -- the engine's read finished, and the tracer's "inside vs after"
    -- distinction depends on this ordering.
    read_in_progress = false
    last_read_end = os.clock()
    local s = scan()
    if not s then return end
    local capacity, npcnum = read_save_block()

    -- Arm the blank grace here too, so a save made a minute after a
    -- corrupting load already purges instead of waiting for a second write.
    if s.blanks > 0 then
        blank_first_seen = blank_first_seen or os.clock()
    end

    boundary_seq = boundary_seq + 1
    last_report = string.format(
        "read #%d: %d records (%d blank, %d dead), npcnum=%s, capacity=%s",
        boundary_seq, s.total, s.blanks, s.dead,
        npcnum >= 0 and tostring(npcnum) or "?",
        capacity > 0 and tostring(capacity) or "?")
    M.log(last_report)

    -- npcnum past capacity on a READ convicts the loaded file itself: it was
    -- written from an over-capacity list, whoever wrote it.
    if capacity > 0 and npcnum > capacity then
        M.log.error(string.format(
            "LOADED SAVE IS OVER CAPACITY: npcnum=%d but the array holds %d"
                .. " -- this save lost %d record(s) when it was written",
            npcnum, capacity, npcnum - capacity))
    end

    -- In-session round-trip: name what the boundary ate. Only meaningful
    -- when a write was observed this session (a session-start load has
    -- nothing to diff against). A record that was not-save at the write is
    -- EXPECTED to be absent now -- that is the engine's designed exclusion
    -- (field-verified: trap corpses drop cleanly, no blanks) -- so it goes
    -- to an INFO note, not the damage line.
    if last_write then
        local lost, expected = {}, {}
        for stype, n in pairs(last_write.stypes) do
            local now_n = s.stypes[stype] or 0
            if now_n < n and stype ~= 0 then
                local f = last_write.flags and last_write.flags[stype]
                local desc = string.format("%s(stype=%d)%s%s",
                    name_of(stype), stype,
                    n - now_n > 1 and (" x" .. (n - now_n)) or "",
                    flag_note(f))
                if f and f.notsave then
                    table.insert(expected, desc)
                else
                    table.insert(lost, desc)
                end
            end
        end
        table.sort(lost)
        table.sort(expected)
        if #expected > 0 then
            M.log(string.format(
                "expected drops (were not-save at the write): %s",
                table.concat(expected, ", ")))
        end
        local blanks_grew = s.blanks > last_write.blanks
        if #lost > 0 or blanks_grew then
            M.log.error(string.format(
                "SAVE ROUND-TRIP DAMAGE: blanks %d -> %d; save-eligible"
                    .. " records at the last write now missing: %s",
                last_write.blanks, s.blanks,
                #lost > 0 and table.concat(lost, ", ") or "(none)"))
            -- Log only. A message box used to ask the player to reload the
            -- same save as an experiment; it belonged to the survivor
            -- repair era (removed in 3666dfe) and also fired on a new game,
            -- where the old world's records are rightly gone.
        end
    end

    pcall(Logger.flush)
end

------------------------------------------------------------
-- Load-window reentry tracer
--
-- The bug's invariants (always ScoopSanity, always a reload; party size,
-- run length and machine strength irrelevant to WHETHER it happens; zero
-- vanilla reports ever) point at the LOAD, not the write. A blank is an
-- allocated-but-never-filled NpcBaseInfo -- which is what the reader's fill
-- loop leaves behind if something inserts into NpcInfoList while it runs.
-- The engine stages every ACTIVE scoop at a load (clean-machine trace:
-- spawnNPC bursts at area=-1, evno=65535, after EVERY save_read), and
-- ScoopSanity is what turns that burst from vanilla's 0-2 NPCs into a
-- dozen. Staging overlapping reconstruction would misalign fills: k
-- records left blank, k fills lost -- the exact k-for-k field signature.
--
-- This measures it instead of arguing it: the NpcManager read window is
-- stamped by the save hooks, and every record-lifecycle call is logged
-- relative to it. A call INSIDE the window is the collision (ERROR, with
-- offset); calls within 10s after are the staging burst (DEBUG), so every
-- machine's safety margin -- staging start minus reconstruction end -- is
-- measurable from any session log.
------------------------------------------------------------

-- State for this tracer is declared with the rest of the module state, above:
-- on_save_read assigns to it and is defined earlier in the file.
local STAGING_WATCH_SECONDS = 10.0

local function note_lifecycle(what, stype)
    local now = os.clock()
    local who = stype and string.format("%s (stype=%d)", name_of(stype), stype)
        or "?"
    if read_in_progress and read_window_start then
        M.log.error(string.format(
            "LOAD-WINDOW REENTRY: %s for %s fired +%.3fs INSIDE NpcManager"
                .. " save reconstruction -- record fills can misalign here",
            what, who, now - read_window_start))
        pcall(Logger.flush)
    elseif last_read_end and (now - last_read_end) <= STAGING_WATCH_SECONDS then
        M.log.debug(string.format(
            "post-load staging: %s for %s +%.3fs after reconstruction ended",
            what, who, now - last_read_end))
    end
end

local function install_lifecycle_tracer_hooks(td)
    local targets = {
        { sig = "spawnNPC(app.solid.SurvivorDefine.SurvivorType, via.vec3,"
            .. " via.Quaternion, solid.MT2RE.cUnitPropertyContainer,"
            .. " System.Action`1<via.GameObject>)",
          what = "spawnNPC", stype_arg = 3 },
        { sig = "spawnNPC(app.solid.SurvivorDefine.SurvivorType,"
            .. " solid.MT2RE.cUnitPropertyContainer,"
            .. " System.Action`1<via.GameObject>)",
          what = "spawnNPC", stype_arg = 3 },
        { sig = "createInformation(app.solid.SurvivorDefine.SurvivorType,"
            .. " System.UInt32)",
          what = "createInformation", stype_arg = 3 },
        { sig = "entryNpcBaseInfo(via.GameObject, app.solid.npc.NpcBaseInfo)",
          what = "entryNpcBaseInfo" },
        { sig = "registerController(app.solid.survivor.NpcController)",
          what = "registerController" },
    }
    local armed = 0
    for _, t in ipairs(targets) do
        local m = td:get_method(t.sig)
        if not m then
            local bare = t.sig:match("^([^(]+)")
            if bare then m = td:get_method(bare) end
        end
        if m then
            local ok = pcall(sdk.hook, m,
                function(args)
                    local stype
                    if t.stype_arg then
                        pcall(function()
                            stype = tonumber(sdk.to_int64(args[t.stype_arg]))
                        end)
                    end
                    pcall(note_lifecycle, t.what, stype)
                end,
                function(retval) return retval end)
            if ok then armed = armed + 1 end
        end
    end
    M.log(string.format("load-window lifecycle tracer armed (%d hooks)", armed))
end

------------------------------------------------------------
-- Hook installation
------------------------------------------------------------

-- How long after a door crossing carry-over is still considered in flight.
-- Matches NpcCarryover's own staleness window.
local CARRYOVER_WINDOW_SECONDS = 10.0

local function carryover_age()
    local DR = AP and AP.DoorRandomizer
    if not (DR and DR.get_last_transition) then return nil end
    local ok, tr = pcall(DR.get_last_transition)
    if not ok or type(tr) ~= "table" or not tr.at then return nil end
    return os.clock() - tr.at
end

-- Log-only, for now. The probe showed setCheckAutoSaveInhibit does not move
-- isAutoSaveInhibit(), so the inhibit flag cannot be trusted as a lever --
-- deferring the write means intercepting the REQUEST instead. Before building
-- that, this records which of the three entry points the transition autosave
-- actually uses, how long after the door crossing it fires, and what state the
-- NPC records are in at that instant. The suspected corrupting write is an
-- autosave landing while party records are mid-carry-over; this is what shows
-- it happening rather than inferring it.
local function log_autosave_request(which)
    local age = carryover_age()
    local s = scan()
    M.log(string.format(
        "AUTOSAVE REQUEST via %s -- carry-over %s | records %s",
        which,
        age and string.format("%.1fs ago%s", age,
            age <= CARRYOVER_WINDOW_SECONDS and " (IN FLIGHT)" or "")
            or "no transition recorded",
        s and string.format("total=%d blank=%d carry=%d justload=%d notsave=%d",
            s.total, s.blanks, s.carry or -1, s.justload or -1, s.notsave or -1)
            or "unreadable"))
end

local function install_autosave_probe_hooks()
    local td = sdk.find_type_definition("app.solid.SolidStorage")
    if not td then return false end
    local targets = {
        { "requestAutoSave", "requestAutoSave()" },
        { "requestAutoSaveByNearestSpawnData", "requestAutoSaveByNearestSpawnData(via.vec3)" },
        { "prepareAutoSave", "prepareAutoSave(System.String, via.vec3, via.Quaternion)" },
    }
    local armed = {}
    for _, t in ipairs(targets) do
        local m = td:get_method(t[2]) or td:get_method(t[1])
        if m then
            local ok = pcall(function()
                sdk.hook(m,
                    function() pcall(log_autosave_request, t[1]) end,
                    function(retval) return retval end)
            end)
            if ok then armed[#armed + 1] = t[1] end
        end
    end
    if #armed > 0 then
        M.log("autosave request hooks installed: " .. table.concat(armed, ", "))
        return true
    end
    M.log.warn("autosave request hooks FAILED -- no entry point could be hooked")
    return false
end

local function install_hooks()
    if hooks_installed then return end
    local td = sdk.find_type_definition("app.solid.gamemastering.NpcManager")
    if not td then return end
    local m_write = td:get_method("notfiyDataWrite(app.solid.SolidStorage)")
        or td:get_method("notfiyDataWrite")
    local m_read = td:get_method("notfiyDataRead(app.solid.SolidStorage)")
        or td:get_method("notfiyDataRead")
    if not m_write or not m_read then return end

    local ok = pcall(function()
        sdk.hook(m_write,
            function() pcall(on_save_write_pre) end,
            function(retval) pcall(on_save_write_post) return retval end)
        sdk.hook(m_read,
            function()
                pcall(function()
                    read_in_progress = true
                    read_window_start = os.clock()
                end)
            end,
            function(retval) pcall(on_save_read) return retval end)
    end)
    hooks_installed = ok
    -- INFO on purpose: a field log must positively prove the instrument was
    -- armed, or a quiet log is indistinguishable from a disarmed one.
    M.log("NPC save-boundary hooks " .. (ok and "installed" or "FAILED"))
    if ok then
        pcall(install_autosave_probe_hooks)
        pcall(install_lifecycle_tracer_hooks, td)
    end
end

local PURGE_INTERVAL_SECONDS = 5.0
local last_purge_at = 0

function M.on_frame()
    if not hooks_installed then
        if not Shared.is_in_game() then return end
        install_hooks()
    end

    -- Debris purge on the MAIN thread, decoupled from the save hooks:
    -- removeInformation mutates NpcInfoList, and doing that from the save
    -- thread's write pre-hook raced every main-thread iteration of the list.
    -- A 5s cadence still clears debris well before it matters.
    if not Shared.is_in_game() then return end
    if os.clock() - last_purge_at < PURGE_INTERVAL_SECONDS then return end
    last_purge_at = os.clock()
    if M.is_save_write_in_flight() then return end
    local s = scan()
    if s then
        purged_since_last_write = purged_since_last_write + purge_debris(s)
    end
end

------------------------------------------------------------
-- Console
------------------------------------------------------------

_G.drap_npc_capacity = function()
    local capacity, npcnum = read_save_block()
    local s = scan()
    local mgr = npc_mgr:get()
    local info_num_all, info_num_save = -1, -1
    if mgr then
        pcall(function()
            info_num_all = Shared.to_int(mgr:call("getInformationNum", false)) or -1
        end)
        pcall(function()
            info_num_save = Shared.to_int(mgr:call("getInformationNum", true)) or -1
        end)
    end
    M.log(string.format(
        "npcWork capacity=%s  npcnum(last save block)=%s"
            .. "  getInformationNum(false)=%s  getInformationNum(true)=%s",
        capacity > 0 and tostring(capacity) or "unavailable",
        npcnum >= 0 and tostring(npcnum) or "unavailable",
        tostring(info_num_all), tostring(info_num_save)))
    if not s then
        M.log("NpcInfoList not available")
        return
    end
    -- Transient counts included so the decay after a door crossing can be
    -- checked by hand. mCarryOverFlag is consumed by the carry-over spawn, so
    -- a healthy standing NPC reads false: a count that stays high long after
    -- a crossing means the flags are stuck, which is the abnormal per-record
    -- state the save writer would be serializing at every boundary.
    M.log(string.format(
        "NpcInfoList: %d records (%d blank, %d dead, %d dead trap-pool,"
            .. " %d carry-over, %d just-load, %d not-save)",
        s.total, s.blanks, s.dead, s.trap_dead, s.carry, s.justload, s.notsave))
    if capacity > 0 then
        if s.total > capacity then
            M.log.error(string.format(
                "OVER CAPACITY by %d -- the next save will drop records",
                s.total - capacity))
        else
            M.log(string.format("headroom: %d free save slot(s)",
                capacity - s.total))
        end
    end
    local parts = {}
    for _, e in ipairs(s.entries) do
        table.insert(parts, string.format("%d%s%s%s%s%s", e.stype,
            is_blank(e) and "B" or (e.is_dead and "d" or ""),
            (e.state or 0) == 2 and "J" or "",
            e.carry and "c" or "",
            e.justload and "l" or "",
            e.notsave and "o" or ""))
    end
    M.log("list order (stype, B=blank d=dead J=join c=carry-over"
        .. " l=just-load o=not-save): " .. table.concat(parts, " "))
end

-- Field-level diff of two NpcBaseInfo records. Built to answer "what does a
-- naturally-joined survivor's record have that a DRAP-respawned one lacks":
-- respawned members follow and count in the escort but the engine does not
-- transport their bodies at area transitions, so some join/area state our
-- promotion never writes must differ. Every non-static field is read
-- generically off the type definition so nothing is missed.
--   drap_npc_compare(10, 21)  -- e.g. natural Susan Walsh vs respawned Sally
_G.drap_npc_compare = function(stype_a, stype_b)
    local mgr = npc_mgr:get()
    if not mgr then M.log("NpcManager not live") return end
    local a, b
    pcall(function() a = mgr:call("searchInformation", tonumber(stype_a)) end)
    pcall(function() b = mgr:call("searchInformation", tonumber(stype_b)) end)
    if not a or not b then
        M.log(string.format("record missing: %s=%s %s=%s",
            tostring(stype_a), a and "ok" or "nil",
            tostring(stype_b), b and "ok" or "nil"))
        return
    end
    local td = a:get_type_definition()
    if not td then M.log("no type definition") return end

    local function fmt(info, field)
        local ok, v = pcall(field.get_data, field, info)
        if not ok then return "<err>" end
        if v == nil then return "nil" end
        local t = type(v)
        if t == "number" or t == "boolean" or t == "string" then
            return tostring(v)
        end
        -- vec3 and friends: try x/y/z, else the type name beats a pointer.
        local ok2, s = pcall(function()
            if v.x ~= nil then
                return string.format("(%.2f, %.2f, %.2f)", v.x, v.y, v.z)
            end
        end)
        if ok2 and s then return s end
        local vtd = nil
        pcall(function() vtd = v:get_type_definition() end)
        return "<" .. ((vtd and vtd:get_name()) or "obj") .. ">"
    end

    M.log(string.format("comparing %s (stype=%s) vs %s (stype=%s):"
            .. " [only differing fields shown]",
        name_of(tonumber(stype_a)), tostring(stype_a),
        name_of(tonumber(stype_b)), tostring(stype_b)))
    local same = 0
    for _, f in ipairs(td:get_fields()) do
        local is_static = false
        pcall(function() is_static = f:is_static() end)
        if not is_static then
            local va, vb = fmt(a, f), fmt(b, f)
            if va ~= vb then
                M.log(string.format("  DIFF %-28s A=%s  B=%s",
                    f:get_name(), va, vb))
            else
                same = same + 1
            end
        end
    end
    for _, m in ipairs({ "isDead", "haveJoined", "isOffJoinNum",
                         "isLeadEnable", "isCarryOver", "getLiveState" }) do
        local ra, rb
        pcall(function() ra = a:call(m) end)
        pcall(function() rb = b:call(m) end)
        if tostring(ra) ~= tostring(rb) then
            M.log(string.format("  DIFF %-28s A=%s  B=%s",
                m .. "()", tostring(ra), tostring(rb)))
        else
            same = same + 1
        end
    end
    M.log(string.format("  (%d fields/methods identical)", same))
    pcall(Logger.flush)
end

-- Probe for the autosave-inhibit lever. The engine exposes, on SolidStorage:
--   setCheckAutoSaveInhibit(System.Boolean InInhibit) -> System.Void
--   isAutoSaveInhibit() -> System.Boolean
--   requestAutoSave() -> System.Void
-- If setting it true makes isAutoSaveInhibit() read true, we can hold the
-- transition autosave off until NPC carry-over settles and then request it --
-- deferring the write instead of racing it. That is the only defense aimed at
-- the engine's own writer rather than at our contributions to it.
--
-- Read-only in effect: whatever the flag was on entry is restored before this
-- returns, and if the entry read failed it restores to false (autosaves
-- allowed), never to inhibited. Nothing is saved and nothing is skipped --
-- the toggles happen and are undone inside this one call.
_G.drap_autosave_probe = function()
    local ss = ss_mgr:get()
    if not ss then
        M.log("autosave probe: SolidStorage unavailable (load a save first)")
        return
    end

    local function read()
        local v
        local ok = pcall(function() v = ss:call("isAutoSaveInhibit") end)
        if not ok then return nil end
        return v
    end
    local function write(v)
        return pcall(function() ss:call("setCheckAutoSaveInhibit", v) end)
    end

    local before = read()
    M.log(string.format("autosave probe: isAutoSaveInhibit() on entry = %s",
        tostring(before)))

    local set_true_ok = write(true)
    local after_true = read()
    local set_false_ok = write(false)
    local after_false = read()

    -- Restore. Unknown entry state falls back to false, the permissive one.
    write(before == true)
    local restored = read()

    M.log(string.format(
        "autosave probe: set(true)=%s -> reads %s | set(false)=%s -> reads %s",
        set_true_ok and "ok" or "FAILED", tostring(after_true),
        set_false_ok and "ok" or "FAILED", tostring(after_false)))

    if after_true == true and after_false == false then
        M.log("autosave probe: the flag is settable and readable, polarity is"
            .. " true = inhibited -- deferring the transition autosave is viable")
    elseif after_true == after_false then
        M.log.warn("autosave probe: the read does not follow the setter --"
            .. " isAutoSaveInhibit() likely reflects the engine's own"
            .. " InhibitCondition list, not this flag. Hook requestAutoSave"
            .. " instead of trusting the flag.")
    else
        M.log.warn("autosave probe: unexpected polarity -- do not build on this"
            .. " until it is understood")
    end

    if restored ~= before and not (before == nil and restored == false) then
        M.log.error(string.format(
            "autosave probe: FAILED TO RESTORE (was %s, now %s) -- run"
                .. " drap_autosave_inhibit(false) before saving",
            tostring(before), tostring(restored)))
    else
        M.log(string.format("autosave probe: restored to %s", tostring(restored)))
    end
    pcall(Logger.flush)
end

-- Escape hatch for the probe above, and the manual lever for testing by hand.
_G.drap_autosave_inhibit = function(on)
    local ss = ss_mgr:get()
    if not ss then M.log("SolidStorage unavailable"); return end
    pcall(function() ss:call("setCheckAutoSaveInhibit", on == true) end)
    local now
    pcall(function() now = ss:call("isAutoSaveInhibit") end)
    M.log(string.format("autosave inhibit set to %s, isAutoSaveInhibit()=%s",
        tostring(on == true), tostring(now)))
end

_G.drap_npc_save_guard = function(on)
    if on == nil then on = not purge_enabled end
    purge_enabled = on == true
    M.log("pre-save debris purge " .. (purge_enabled and "ENABLED" or "DISABLED")
        .. " (boundary logging always on)")
end

_G.drap_npc_save_guard_status = function()
    M.log(string.format(
        "purge=%s hooks=%s blank_first_seen=%s last=[%s]",
        tostring(purge_enabled), tostring(hooks_installed),
        blank_first_seen and string.format("%.0fs ago", os.clock() - blank_first_seen)
            or "never", last_report))
end

return M
