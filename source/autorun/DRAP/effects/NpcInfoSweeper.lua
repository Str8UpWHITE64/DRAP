-- DRAP/effects/NpcInfoSweeper.lua
-- Automated recovery for "survivor won't spawn / spawns dead" (the Burt bug).
--
-- The engine keeps one persistent NpcBaseInfo per survivor stype, and a
-- record stuck at isDead=true + mLiveState=UNKNOWN (never encountered)
-- blocks every later spawn of that survivor. On first game entry and every
-- area transition, this scans NpcInfoList, logs anomalies, and removes
-- corrupt records for survivors whose scoop is received-and-not-completed;
-- the engine recreates a clean record on next area entry.
--
-- Safety filters:
--   * ScoopSanity only: flag-driven spawning is what breaks, so the sweep does
--     not run in vanilla. The spawn blocker below is exempt -- it serves
--     HostileSurvivorTrap and must keep arming from its JSON.
--   * SurvivorCensus verdict == CORRUPT only. A record stuck at isDead +
--     mLiveState=UNKNOWN is ambiguous on its own: a survivor killed before the
--     player ever met them looks identical, and removing that record made
--     SurvivorRecovery resurrect them. The census settles it with history.
--     "all_dead" mode (drap_npc_sweep_mode) still sweeps every dead record.
--   * Owning scoop must be received and not completed, so vanilla scoop
--     expiry deaths in time-flowing modes are never touched.
--   * Trap-pool stypes (>= 59) skipped -- HostileSurvivorTrap self-cleans.
--
-- Layout note: the spawn-blocker section must stay above M.on_frame --
-- module locals are invisible to functions defined earlier.

local Shared = require("DRAP/Shared")
local SharedData = require("DRAP/SharedData")
local ScoopUnlocker = require("DRAP/ScoopUnlocker")
local Census = require("DRAP/npc/SurvivorCensus")

local M = Shared.create_module("NpcInfoSweeper")
M:set_throttle(1.0)

------------------------------------------------------------
-- Configuration
------------------------------------------------------------

-- stypes >= this belong to the HostileSurvivorTrap pool, which manages its
-- own dead-record cleanup. Never sweep them.
local TRAP_POOL_MIN_STYPE = 59

------------------------------------------------------------
-- Singleton Managers
------------------------------------------------------------

local am_mgr  = M:add_singleton("am",  "app.solid.gamemastering.AreaManager")
local npc_mgr = M:add_singleton("npc", "app.solid.gamemastering.NpcManager")

------------------------------------------------------------
-- State
------------------------------------------------------------

local enabled = true
local mode = "corrupt"          -- "corrupt" | "all_dead"

-- Newborn grace: a freshly created NpcBaseInfo is indistinguishable from a
-- corpse (all fields zeroed, isDead=true) until the engine's spawn init
-- completes, which spans several area-load frames. Removing one too early
-- amputates the engine's own repair, so a corrupt-looking record must persist
-- across this window before removal is allowed.
local NEWBORN_GRACE_SECONDS = 30.0
local corrupt_first_seen = {}   -- stype -> os.clock() when first seen corrupt
local last_area_index = nil
local removed_this_session = 0
local last_sweep_report = "never swept"

-- survivor display name -> stype, from survivors.json (sweepable range only)
local name_to_stype = nil
local stype_to_name = {}

-- cached NpcBaseInfo field defs (same for every entry)
local bf = nil

------------------------------------------------------------
-- Survivor Data
------------------------------------------------------------

local function ensure_survivor_map()
    if name_to_stype then return name_to_stype end
    name_to_stype = {}
    local rows = SharedData.survivors()
    if type(rows) ~= "table" then return name_to_stype end
    for _, row in ipairs(rows) do
        local stype = tonumber(row.item_number)
        if row.name and stype and stype < TRAP_POOL_MIN_STYPE then
            name_to_stype[row.name] = stype
            stype_to_name[stype] = row.name
        end
    end
    return name_to_stype
end

-- stype -> owning scoop name, for survivors whose scoop is currently
-- received and not completed. Rebuilt per sweep (cheap; sweeps are rare).
-- Scoop npc entries that aren't rescue survivors ("Kent Day 1", "Convicts",
-- psychopath names) have no survivors.json match and drop out naturally.
local function build_eligible_stypes()
    local eligible = {}
    local names = ensure_survivor_map()
    local ok, status = pcall(ScoopUnlocker.get_all_status)
    if not ok or type(status) ~= "table" then return eligible end
    for _, s in ipairs(status) do
        if s.received and not s.completed and type(s.npcs) == "table" then
            for _, npc_name in ipairs(s.npcs) do
                local stype = names[npc_name]
                if stype then eligible[stype] = s.name end
            end
        end
    end
    return eligible
end

------------------------------------------------------------
-- NpcBaseInfo Access
------------------------------------------------------------

local function ensure_fields(info)
    if bf then return true end
    local td = info:get_type_definition()
    if not td then return false end
    bf = {
        name  = td:get_field("<Name>k__BackingField"),
        state = td:get_field("mLiveState"),
        vital = td:get_field("mVitalNew"),
        area  = td:get_field("mAreaNo"),
    }
    if not bf.name or not bf.state then
        M.log("WARNING: NpcBaseInfo fields not found; sweep disabled this session")
        bf = nil
        return false
    end
    return true
end

local function read_int_field(field, info)
    if not field then return nil end
    local ok, v = pcall(field.get_data, field, info)
    if not ok or v == nil then return nil end
    return tonumber(v) or tonumber(tostring(v))
end

local function read_entry(info)
    if not ensure_fields(info) then return nil end
    local entry = {
        info  = info,
        stype = read_int_field(bf.name, info),
        state = read_int_field(bf.state, info),
        vital = read_int_field(bf.vital, info),
        area  = read_int_field(bf.area, info),
    }
    local ok_d, dead = pcall(function() return info:call("isDead") end)
    entry.is_dead = (ok_d and dead == true)
    return entry
end

local function describe(entry, owning_scoop)
    return string.format(
        "stype=%s (%s) state=%s hp=%s area=%s isDead=%s%s",
        tostring(entry.stype),
        stype_to_name[entry.stype] or "?",
        tostring(entry.state),
        tostring(entry.vital),
        tostring(entry.area),
        tostring(entry.is_dead),
        owning_scoop and (" scoop=" .. owning_scoop) or "")
end

------------------------------------------------------------
-- Sweep
------------------------------------------------------------

--- Scan NpcInfoList, log anomalies, remove broken survivor records.
--- @param reason string Why the sweep is running (for the log)
--- @return number removed
function M.sweep(reason)
    local mgr = npc_mgr:get()
    if not mgr then return 0 end

    local list_field = npc_mgr:get_field("NpcInfoList")
    if not list_field then return 0 end
    local list = Shared.safe_get_field(mgr, list_field)
    if not list then return 0 end

    local eligible = build_eligible_stypes()

    -- Pass 1: read everything, tally per-stype counts, group for the census.
    -- Never remove while iterating the live list.
    local stype_counts = {}
    local by_stype = {}
    local entries = {}
    local to_remove = {}
    local anomalies = 0
    local seen_stypes = {}

    for _, info in Shared.iter_collection(list) do
        if info then
            local e = read_entry(info)
            if e and e.stype then
                stype_counts[e.stype] = (stype_counts[e.stype] or 0) + 1
                seen_stypes[e.stype] = true
                by_stype[e.stype] = by_stype[e.stype] or {}
                table.insert(by_stype[e.stype], e)
                table.insert(entries, e)
            end
        end
    end

    Census.observe(by_stype)

    -- Pass 2: judge each record. The verdict, not the record's current shape,
    -- decides -- a survivor the player killed looks exactly like a record the
    -- flag-spawn never filled in, and used to be removed and then resurrected.
    for _, e in ipairs(entries) do
        local verdict = Census.verdict_for(e.stype, by_stype[e.stype])
        local corrupt = verdict == Census.VERDICT.CORRUPT
        local owning = eligible[e.stype]

        -- Dead records are routine now that the census tells them apart, so
        -- they go to the session log only and stay off the console.
        if e.is_dead and e.stype < TRAP_POOL_MIN_STYPE then
            M.log.debug(string.format("dead record: %s [%s]",
                describe(e, owning), verdict))
            if corrupt then anomalies = anomalies + 1 end
        end

        local should_remove = owning ~= nil
            and ((mode == "corrupt" and corrupt)
                 or (mode == "all_dead" and e.is_dead))
        if should_remove then
            local first = corrupt_first_seen[e.stype]
            if not first then
                corrupt_first_seen[e.stype] = os.clock()
                should_remove = false
                M.log(string.format(
                    "newborn grace: %s -- removal deferred %ds",
                    describe(e, owning), NEWBORN_GRACE_SECONDS))
            elseif os.clock() - first < NEWBORN_GRACE_SECONDS then
                should_remove = false
            end
        end
        if not corrupt then corrupt_first_seen[e.stype] = nil end
        if should_remove then
            e.owning = owning
            table.insert(to_remove, e)
        end
    end

    -- Log duplicate stypes (same survivor appearing multiple times). We only
    -- remove the ones matching the removal policy; a duplicate pair of
    -- healthy records is logged as an anomaly for field reports.
    for stype, n in pairs(stype_counts) do
        if n > 1 and stype < TRAP_POOL_MIN_STYPE then
            anomalies = anomalies + 1
            M.log(string.format("duplicate records: stype=%d (%s) x%d",
                stype, stype_to_name[stype] or "?", n))
        end
    end

    -- No-record-yet visibility: informational ONLY. Record creation is LAZY --
    -- the engine creates a survivor's NpcBaseInfo at flag-flip or, failing
    -- that, on first entry to their home area. A missing record is a normal
    -- resting state, NOT damage, so it's not counted as an anomaly. Genuine
    -- damage is: record still absent/zeroed AFTER entering the home area with
    -- the scoop active.
    for stype, scoop_name in pairs(eligible) do
        if not seen_stypes[stype] then
            M.log(string.format(
                "no record yet: stype=%d (%s) scoop='%s' -- normal until "
                .. "their area is visited; investigate only if it persists "
                .. "after visiting",
                stype, stype_to_name[stype] or "?", scoop_name))
        end
    end

    -- Pass 2: remove captured targets by reference. The (NpcBaseInfo)
    -- overload removes the exact entry; the (SurvivorType) overload would
    -- only drop the canonical one and leave shadows (see BookGuards).
    local removed = 0
    for _, e in ipairs(to_remove) do
        local ok = pcall(function()
            mgr:call("removeInformation(app.solid.npc.NpcBaseInfo)", e.info)
        end)
        if ok then
            removed = removed + 1
            M.log(string.format("REMOVED broken record (%s): %s -- engine will respawn on next area entry",
                reason or "?", describe(e, e.owning)))
        else
            M.log.warn("removeInformation FAILED for " .. describe(e, e.owning))
        end
    end

    removed_this_session = removed_this_session + removed
    last_sweep_report = string.format("%s: %d anomalies, %d removed (mode=%s)",
        reason or "?", anomalies, removed, mode)
    if removed > 0 or anomalies > 0 then
        M.log("sweep " .. last_sweep_report)
    end
    return removed
end

------------------------------------------------------------
-- Emergency spawn blocker: skips engine spawn requests for specific
-- survivor stypes (recovery tool for deterministic spawn crashes).
-- Blocks persist across restarts (AP_DRDR_Items/AP_DRDR_spawn_blocks.json)
-- and every hook decision is flushed to drap_spawn_block.log.
-- WARNING: blocking a spawn the scene loader waits on stalls the load.
------------------------------------------------------------

local BLOCK_FILE = "./AP_DRDR_Items/AP_DRDR_spawn_blocks.json"
local BLOCK_LOG = "drap_spawn_block.log"

local BLOCKED_SPAWNS = {}
local spawn_hooks_installed = false

local function block_log(msg)
    M.log(msg)
    local f = io.open(BLOCK_LOG, "a")
    if f then
        f:write(string.format("[%s] %s\n", os.date("%H:%M:%S"), msg))
        f:close()
    end
end

local function save_blocks()
    local list = {}
    for stype in pairs(BLOCKED_SPAWNS) do table.insert(list, stype) end
    table.sort(list)
    Shared.save_json(BLOCK_FILE, { blocked = list }, 2, M.log)
end

local function load_blocks()
    BLOCKED_SPAWNS = {}
    local probe = io.open(BLOCK_FILE, "r")
    if not probe then return end
    probe:close()
    local data = Shared.load_json(BLOCK_FILE)
    if data and type(data.blocked) == "table" then
        for _, stype in ipairs(data.blocked) do
            local n = tonumber(stype)
            if n then BLOCKED_SPAWNS[n] = true end
        end
    end
end

local function install_spawn_hooks()
    if spawn_hooks_installed then return true end
    local td = sdk.find_type_definition("app.solid.gamemastering.NpcManager")
    if not td then return false end

    local sigs = {
        "spawnNPC(app.solid.SurvivorDefine.SurvivorType, via.vec3, via.Quaternion, solid.MT2RE.cUnitPropertyContainer, System.Action`1<via.GameObject>)",
        "spawnNPC(app.solid.SurvivorDefine.SurvivorType, solid.MT2RE.cUnitPropertyContainer, System.Action`1<via.GameObject>)",
    }
    local hooked = 0
    for _, sig in ipairs(sigs) do
        local m = td:get_method(sig)
        if m then
            local ok = pcall(sdk.hook, m,
                function(args)
                    local stype = nil
                    pcall(function() stype = tonumber(sdk.to_int64(args[3])) end)
                    if stype and BLOCKED_SPAWNS[stype] then
                        block_log(string.format("BLOCKED spawnNPC for stype %d (%s)",
                            stype, stype_to_name[stype] or "?"))
                        return sdk.PreHookResult.SKIP_ORIGINAL
                    end
                end,
                function(retval) return retval end)
            if ok then hooked = hooked + 1 end
        end
    end
    spawn_hooks_installed = hooked > 0
    if spawn_hooks_installed then
        local n = 0
        for _ in pairs(BLOCKED_SPAWNS) do n = n + 1 end
        block_log(string.format("spawn-block hooks installed (%d overloads, %d active blocks)",
            hooked, n))
    end
    return spawn_hooks_installed
end

function M.block_spawn(stype)
    stype = tonumber(stype)
    if not stype then
        M.log("block_spawn: numeric stype required")
        return false
    end
    ensure_survivor_map()
    BLOCKED_SPAWNS[stype] = true
    save_blocks()
    local ok = install_spawn_hooks()
    local name = stype_to_name[stype] or "?"
    block_log(string.format("spawn BLOCK armed for stype %d (%s), hooks=%s, persisted",
        stype, name, tostring(ok)))
    -- Unmissable confirmation the command actually executed.
    pcall(re.msg, string.format(
        "DRAP: spawn block ACTIVE for %s (stype %d).\n"
        .. "Persists across restarts until drap_npc_unblock_spawn(%d).",
        name, stype, stype))
    return true
end

function M.unblock_spawn(stype)
    stype = tonumber(stype)
    if stype then
        BLOCKED_SPAWNS[stype] = nil
        save_blocks()
        block_log(string.format("spawn unblocked for stype %d", stype))
    end
end

_G.drap_npc_block_spawn = function(stype) M.block_spawn(stype) end
_G.drap_npc_unblock_spawn = function(stype) M.unblock_spawn(stype) end
_G.drap_npc_blocked_spawns = function()
    local any = false
    for stype in pairs(BLOCKED_SPAWNS) do
        any = true
        M.log(string.format("  blocked: stype %d (%s)", stype, stype_to_name[stype] or "?"))
    end
    if not any then M.log("  no spawn blocks active") end
end

-- Restore persisted blocks at load; hooks install from on_frame once the
-- NpcManager type is available.
load_blocks()

------------------------------------------------------------
-- Per-frame Update
------------------------------------------------------------

npc_mgr.on_instance_changed = function(old, new)
    bf = nil
end

function M.on_frame()
    -- Keep trying to install the spawn-block hooks whenever any block is
    -- active (persisted blocks arm before the NpcManager type is loaded).
    if not spawn_hooks_installed and next(BLOCKED_SPAWNS) ~= nil then
        install_spawn_hooks()
    end

    -- Everything below is ScoopSanity-only: the flag-driven spawning that
    -- corrupts records does not happen in vanilla. drap_npc_sweep() still
    -- forces a sweep by hand for debugging.
    local ss_ok, ss_on = pcall(ScoopUnlocker.is_scoop_sanity_enabled)
    if not ss_ok or ss_on ~= true then return end

    if not enabled then return end
    if not M:should_run() then return end
    if not Shared.is_in_game() then
        last_area_index = nil
        return
    end

    local am = am_mgr:get()
    if not am then return end
    local area_field = am_mgr:get_field("mAreaIndex")
    if not area_field then return end
    local ok, area = pcall(area_field.get_data, area_field, am)
    if not ok or area == nil then return end
    area = tonumber(area)
    if area == nil then return end

    if last_area_index == nil then
        -- First frame in gameplay (fresh load): sweep once so an
        -- already-corrupted save self-repairs without needing a transition.
        last_area_index = area
        M.sweep("initial load")
    elseif area ~= last_area_index then
        last_area_index = area
        M.sweep("area transition")
    end
end

------------------------------------------------------------
-- Public API / Console Commands
------------------------------------------------------------

function M.set_enabled(v)
    enabled = (v == true)
    M.log("sweep enabled: " .. tostring(enabled))
end

function M.set_mode(m)
    if m ~= "corrupt" and m ~= "all_dead" then
        M.log("invalid mode '" .. tostring(m) .. "' (use 'corrupt' or 'all_dead')")
        return
    end
    mode = m
    M.log("sweep mode: " .. mode)
end

function M.get_status()
    return {
        enabled = enabled,
        mode = mode,
        removed_this_session = removed_this_session,
        last_sweep = last_sweep_report,
    }
end

_G.drap_npc_sweep = function()
    local n = M.sweep("manual")
    M.log(string.format("manual sweep removed %d record(s)", n))
end

_G.drap_npc_sweep_mode = function(m) M.set_mode(m) end
_G.drap_npc_sweep_enabled = function(v) M.set_enabled(v) end

_G.drap_npc_sweep_status = function()
    local s = M.get_status()
    M.log(string.format("enabled=%s mode=%s removed_this_session=%d last=[%s]",
        tostring(s.enabled), s.mode, s.removed_this_session, s.last_sweep))
end

return M
