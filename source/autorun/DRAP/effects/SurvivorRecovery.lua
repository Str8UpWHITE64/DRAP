-- DRAP/effects/SurvivorRecovery.lua
-- Self-healing for broken survivor spawns (the Twin Sisters bug class).
--
-- Problem: certain histories (e.g. an in-session reload crossing a scoop
-- receipt under pre-1.2.0 code) leave a scoop engine-active while its
-- survivor's NpcBaseInfo is missing or a zeroed corpse (state=0 hp=0 area=0
-- isDead). The engine never retries, so the survivor can never spawn.
-- Fix: clear the broken record and spawnNPC at the survivor's known position
-- via the same engine path HostileSurvivorTrap uses.
--
-- Parts:
--   HARVESTER (passive) -- records each survivor's first healthy sighting into
--   a positions DB, overlaying the set bundled in drdr_shared.json.
--   REPAIR (area entry) -- respawns a survivor at their spawn point when the
--   census judges the record broken.
--   PARTY RESTORE (per tick) -- puts a survivor lost mid-escort back at the
--   player's side, following.
--   DEATH RESPAWN (area entry) -- returns a killed survivor to their spawn
--   point when the Survivor Respawn option is on, so their check stays winnable.
--   CROSS-SESSION -- snapshots the escort party on save and restores it on
--   load, but only behind PartySnapshot's fingerprint gate.
--
-- Guards:
--   * ScoopSanity only, and nothing spawns before AP activation;
--   * the census verdict, not the current frame -- a survivor the player killed
--     reads identically to a broken one in one frame, and used to be
--     resurrected on that basis;
--   * a final liveness re-check immediately before every spawn, because
--     spawning CLEARS existing records first;
--   * cutscene-staged NPCs wait for their group to prove it spawned;
--   * session-scoped facts (in-party, seen-alive) reset on save load, so a
--     loaded save is never judged against the one before it.

local Shared = require("DRAP/Shared")
local SharedData = require("DRAP/SharedData")
local Census = require("DRAP/npc/SurvivorCensus")
local Snapshot = require("DRAP/npc/PartySnapshot")
local Ledger = require("DRAP/LocationLedger")

local M = Shared.create_module("SurvivorRecovery")
M:set_throttle(1.0)

local npc_mgr = M:add_singleton("npc", "app.solid.gamemastering.NpcManager")
local am_mgr  = M:add_singleton("am",  "app.solid.gamemastering.AreaManager")

-- Forward declarations: these are used by functions defined ABOVE their natural
-- home. Module locals are invisible to functions defined earlier, so assigning
-- without declaring here would silently create a global instead -- do not add
-- `local` at the later definition sites.
local get_area
local lost_first_seen = {}   -- stype -> os.clock() when first seen lost

local DB_FILE = "./AP_DRDR_Items/AP_DRDR_survivor_positions.json"
local TRAP_POOL_MIN_STYPE = 59
local REPAIR_SETTLE_SECONDS = 5.0

-- A party member who vanishes is restored where the player is standing, so
-- there is no area-entry edge to wait behind -- just long enough that we are
-- not racing the engine's own lazy re-creation.
local RESTORE_SETTLE_SECONDS = 5.0
local LIVE_STATE_JOIN = 2
local SPAWN_OFFSET_X = 1.5
local PM_TYPE = "app.solid.PlayerManager"

------------------------------------------------------------
-- Survivor identity maps (from shared data)
------------------------------------------------------------

local stype_to_name = nil
local name_to_stype = nil

local function ensure_maps()
    if stype_to_name then return end
    stype_to_name, name_to_stype = {}, {}
    for _, row in ipairs(SharedData.survivors()) do
        local stype = tonumber(row.item_number)
        if row.name and stype and stype < TRAP_POOL_MIN_STYPE then
            stype_to_name[stype] = row.name
            name_to_stype[row.name] = stype
        end
    end
end

------------------------------------------------------------
-- Positions DB (persistent; first healthy sighting wins)
------------------------------------------------------------

local db = nil
local db_dirty = false

local function load_db()
    if db then return end
    -- Local harvests overlay the positions bundled in drdr_shared.json,
    -- so fresh installs ship with full coverage and local sightings can
    -- still refine or extend it.
    db = {}
    for stype_s, e in pairs(SharedData.survivor_positions()) do
        db[stype_s] = e
    end
    for stype_s, e in pairs(Shared.load_json_if_exists(DB_FILE) or {}) do
        db[stype_s] = e
    end
end

local function save_db()
    if not db_dirty then return end
    if Shared.save_json(DB_FILE, db, 2, M.log) then
        db_dirty = false
    end
end

local function db_get(stype)
    load_db()
    return db[tostring(stype)]
end

local function db_put(stype, entry)
    load_db()
    db[tostring(stype)] = entry
    db_dirty = true
end

------------------------------------------------------------
-- NpcBaseInfo access
------------------------------------------------------------

local function read_record(info)
    local e = { info = info }
    pcall(function()
        local v = info:get_field("<Name>k__BackingField")
        e.stype = tonumber(v) or tonumber(tostring(v))
    end)
    pcall(function() e.state = tonumber(info:get_field("mLiveState")) end)
    pcall(function() e.area = tonumber(info:get_field("mAreaNo")) end)
    pcall(function() e.hp = tonumber(info:get_field("mVitalNew")) end)
    pcall(function()
        local p = info:get_field("mPos")
        if p then e.x, e.y, e.z = p.x, p.y, p.z end
    end)
    local ok_d, dead = pcall(function() return info:call("isDead") end)
    e.is_dead = ok_d and dead == true
    return e
end

-- Returns records grouped by stype: { [stype] = { entries... } }
local function scan_records()
    local mgr = npc_mgr:get()
    if not mgr then return nil end
    local list_field = npc_mgr:get_field("NpcInfoList")
    local list = list_field and Shared.safe_get_field(mgr, list_field)
    if not list then return nil end
    local by_stype = {}
    local count = Shared.get_collection_count(list) or 0
    for i = 0, count - 1 do
        local info = Shared.get_collection_item(list, i)
        if info then
            local e = read_record(info)
            if e.stype then
                by_stype[e.stype] = by_stype[e.stype] or {}
                table.insert(by_stype[e.stype], e)
            end
        end
    end
    return by_stype
end

------------------------------------------------------------
-- Passive harvester
------------------------------------------------------------

-- First healthy sighting per stype: pre-recruit states only. States 0/1 are
-- free-standing survivors; state 5 is captive/hostage idle (Jennifer Gorman,
-- Jo's captives -- an earlier state<=1 filter wrongly rejected them). States 4
-- (joined/escorting) and 8 are post-recruit and never harvested, nor is anyone
-- in the safety rooms (a rescued NPC's position isn't their spawn point).
local HARVEST_STATES = { [0] = true, [1] = true, [5] = true }
local SAFETY_AREAS = { [288] = true, [292] = true }

local function harvest(by_stype)
    ensure_maps()
    local added = 0
    for stype, entries in pairs(by_stype) do
        if stype < TRAP_POOL_MIN_STYPE and stype_to_name[stype]
            and not db_get(stype) then
            for _, e in ipairs(entries) do
                if not e.is_dead and HARVEST_STATES[e.state or -1]
                    and (e.hp or 0) > 0
                    and not SAFETY_AREAS[e.area or -1]
                    and e.x and (e.x ~= 0 or e.z ~= 0) then
                    db_put(stype, {
                        name = stype_to_name[stype],
                        x = e.x, y = e.y, z = e.z,
                        area = e.area, state = e.state, hp = e.hp,
                    })
                    added = added + 1
                    M.log(string.format(
                        "harvested %s (stype=%d): area=%d pos=(%.2f, %.2f, %.2f) state=%d",
                        stype_to_name[stype], stype, e.area or -1,
                        e.x, e.y, e.z, e.state or -1))
                    break
                end
            end
        end
    end
    if added > 0 then save_db() end
end

------------------------------------------------------------
-- Repair
------------------------------------------------------------

-- NPCs of every ACTIVE scoop (received, not completed), whatever the category.
--
-- This once filtered to Survivor-category on the reasoning that boss-gated NPCs
-- must never spawn early. "Active" guards that better and is narrower in
-- practice -- the scoop must be received, the player must be standing in the
-- NPC's own spawn area on an entry edge, and the settle must elapse. Kay Nelson
-- is why: her scoop was active and her fellow hostages had spawned, but the
-- category filter refused to repair her and her Rescue check was unwinnable.
--- @return table stype -> { scoop, category }
--- @return table scoop name -> array of member stypes
local function eligible_survivors()
    ensure_maps()
    local out, groups = {}, {}
    local su = _G.AP and _G.AP.ScoopUnlocker
    if not su or not su.get_all_status then return out, groups end
    local ok, status = pcall(su.get_all_status)
    if not ok or type(status) ~= "table" then return out, groups end
    for _, s in ipairs(status) do
        if s.received and not s.completed and type(s.npcs) == "table" then
            for _, npc_name in ipairs(s.npcs) do
                local stype = name_to_stype[npc_name]
                if stype then
                    out[stype] = { scoop = s.name, category = s.category }
                    groups[s.name] = groups[s.name] or {}
                    table.insert(groups[s.name], stype)
                end
            end
        end
    end
    return out, groups
end

-- Scoops whose hostages are staged by a named cutscene, and the tracked
-- location that fires when it plays. For these, the cutscene is the only
-- trustworthy answer to "have they spawned yet".
--
-- A sibling being alive is NOT good enough. Cheryl Jones stands in Colby's
-- Movieland before Meet Sean runs, so the sibling check read the group as
-- already spawned and repaired the other four at their captive spots; the
-- cutscene then staged its own copies and the player got duplicates.
-- Out of Control is deliberately absent. Greg Simpson does not appear when
-- Adam is met -- he spawns after Adam dies and a second cutscene runs -- so
-- gating on Meet Adam would let the repair fire while he is still legitimately
-- absent. He has one sibling-less entry, so he keeps declining instead.
local STAGING_EVENTS = {
    ["A Strange Group"]  = "Meet Sean",
    ["Above the Law"]    = "Meet Jo",
    ["Long Haired Punk"] = "Meet Paul",
}

local STAGED_EVENT_NAMES = {}
for _, event in pairs(STAGING_EVENTS) do STAGED_EVENT_NAMES[event] = true end

-- Staging cutscenes seen SINCE THE CURRENT SAVE WAS LOADED. Cleared alongside
-- the census session state -- a check sent in an earlier save says nothing
-- about whether the scene has played in this one.
local staged_this_session = {}

--- Record a tracked location as it fires. Called from the event hook.
function M.note_tracked_location(desc)
    if desc and STAGED_EVENT_NAMES[desc] then
        if not staged_this_session[desc] then
            M.log(string.format("staging cutscene seen: %s", desc))
        end
        staged_this_session[desc] = true
    end
end

-- Has this scoop's spawn event run yet? -> "yes" / "no" / "unknown".
--
-- Psychopath-scoop hostages are staged with the psycho and only exist once its
-- cutscene plays, so "missing" is normally "not yet".
--
-- For a scoop in STAGING_EVENTS the cutscene decides. Everything else falls
-- back to a sibling seen alive this save, which proves the event fired and
-- makes a still-absent member a real failure.
--
-- alive_session, NOT ever_alive: the question is about THIS save. Persisted
-- history made groups look already-spawned and their members were placed at
-- their captive spots early, which the scene then duplicated.
--
-- UNKNOWN means no sibling can ever answer -- five scoops (Out of Control,
-- Photographer's Pride, Mark of the Sniper, The Convicts, The Cult) have a
-- single rescuable member, the rest of their npcs being psychos with no
-- SurvivorType. Jennifer Gorman is the same shape: she spawns alone, so no
-- sibling will ever vouch for her. Callers decline on UNKNOWN, which is the
-- safe answer while none of them have been reported missing;
-- drap_recover_force is the override.
local function group_spawn_state(stypes, self_stype, scoop_name)
    local event = STAGING_EVENTS[scoop_name]
    if event then
        return staged_this_session[event] and "yes" or "no"
    end

    local others = 0
    for _, st in ipairs(stypes or {}) do
        if st ~= self_stype then
            others = others + 1
            local h = Census.get(st)
            if h and h.alive_session then return "yes" end
        end
    end
    if others == 0 then return "unknown" end
    return "no"
end

-- Every rescuable survivor, as stype -> scoop name. Source data is already
-- filtered against Locations.py's "Rescue X" list, so boss entries never appear.
--
-- Deliberately not gated on scoop state, unlike eligible_survivors(): Jennifer
-- Gorman's scoop is Psychopath-category AND completes on witnessing Sean, which
-- would strand her while she is still standing there unrescued.
--
-- Deliberately not gated on the AP check either. Checks outlive the save that
-- earned them, and on a new game the player may be rescuing that survivor again
-- for the PP or a goal, so a sent check must never stop them existing. What
-- does stop recovery is the census RESCUED verdict -- rescued in THIS save.
local function rescuable_survivors()
    ensure_maps()
    local out = {}
    for scoop_name, names in pairs(SharedData.scoop_survivors() or {}) do
        for _, npc_name in ipairs(names) do
            local stype = name_to_stype[npc_name]
            if stype then out[stype] = scoop_name end
        end
    end
    return out
end

local function clear_records_for(stype)
    local mgr = npc_mgr:get()
    if not mgr then return 0 end
    local by_stype = scan_records()
    local removed = 0
    for _, e in ipairs((by_stype or {})[stype] or {}) do
        local ok = pcall(function()
            mgr:call("removeInformation(app.solid.npc.NpcBaseInfo)", e.info)
        end)
        if ok then removed = removed + 1 end
    end
    return removed
end

------------------------------------------------------------
-- Party restore helpers
------------------------------------------------------------

local function get_player_pos()
    local pm = sdk.get_managed_singleton(PM_TYPE)
    if not pm then return nil end
    local cond
    pcall(function() cond = pm:call("get_CurrentPlayerCondition") end)
    if not cond then return nil end
    local pos
    pcall(function() pos = cond:get_field("LastPlayerPos") end)
    if not pos then return nil end
    local x, y, z
    pcall(function() x, y, z = pos.x, pos.y, pos.z end)
    if not (x and y and z) then return nil end
    return x, y, z
end

-- Escort party size. Only used to prove setEscortEnable actually did
-- something -- the count is never used to refuse a restore, because DRAP
-- routinely escorts past the vanilla 8 and PartyHudGuard absorbs the
-- HUD-widget overflow.
local function get_escort_count()
    local mgr = npc_mgr:get()
    if not mgr then return -1 end
    local n = -1
    pcall(function() n = tonumber(mgr:call("getEscortNpcNum", 0)) or -1 end)
    return n
end

-- HitPointController on the owning GameObject is the real damage tracker;
-- setVitalFull alone leaves a survivor who falls over on first contact.
local function reset_health(info)
    pcall(function() info:call("setVitalFull") end)
    local vmax
    pcall(function() vmax = info:get_field("mVitalMax") end)
    if vmax then pcall(function() info:set_field("mVitalNew", vmax) end) end
    local owner, go, comps
    pcall(function() owner = info:get_field("Owner") end)
    if not owner then return end
    pcall(function() go = owner:call("get_GameObject") end)
    if not go then return end
    pcall(function() comps = go:call("get_Components") end)
    if not comps then return end
    local n = 0
    pcall(function() n = tonumber(comps:call("get_Count")) or 0 end)
    for i = 0, n - 1 do
        local c
        pcall(function() c = comps:call("get_Item", i) end)
        if c then
            local td = c:get_type_definition()
            if td and (td:get_full_name() or ""):find("HitPointController") then
                pcall(function() c:call("fullRecover") end)
                return
            end
        end
    end
end

-- Put a healthy record into the player's party. setLiveState(JOIN) alone is
-- NOT enough: SceneFixups gates the safe-room rescue cutscene on
-- getEscortNpcNum() > 0, so a survivor who is JOIN but not escort-registered
-- can follow the player in and never complete. The before/after counts are
-- logged because setEscortEnable's effect has never been confirmed in the
-- field -- if the count never moves, that is the thing to report.
local function promote_to_join(info, label)
    local mgr = npc_mgr:get()
    if not mgr or not info then return false end
    reset_health(info)
    local before = get_escort_count()
    pcall(function() info:call("setLiveState", LIVE_STATE_JOIN) end)
    local ok = pcall(function() mgr:call("setEscortEnable", info) end)
    local after = get_escort_count()
    local lead
    pcall(function() lead = info:call("isLeadEnable") end)
    M.log(string.format(
        "%s: JOIN set, setEscortEnable=%s, escort %d -> %d, isLeadEnable=%s",
        label, ok and "ok" or "FAILED", before, after, tostring(lead)))
    return ok
end

-- Move a record to the player's feet. No spawnNPC: NpcBaseInfo is keyed one
-- per stype, so spawning a stype that is already live corrupts the natural
-- NPC. Mirrors NpcCarryover.rewrite_single_npc.
local function move_to_player(info)
    local px, py, pz = get_player_pos()
    if not px then return false end
    local area = get_area()
    if area then pcall(function() info:set_field("mAreaNo", area) end) end
    local v
    pcall(function() v = Vector3f.new(px + SPAWN_OFFSET_X, py, pz) end)
    if v then
        local ok = pcall(function() info:call("setPos", v) end)
        if not ok then pcall(function() info:set_field("mPos", v) end) end
    end
    pcall(function() info:set_field("mCarryOverFlag", true) end)
    return true
end

local spawn_pending = {}   -- stype -> { started, entry, scoop, join, at_player }

--- @param join boolean respawn them already in the player's party
--- @param at_player boolean spawn at the player instead of the DB spawn point
local function spawn_at(stype, entry, scoop_name, forced, verdict, join, at_player)
    local mgr = npc_mgr:get()
    if not mgr then return false end

    local sx, sy, sz = entry.x, entry.y, entry.z
    if at_player then
        local px, py, pz = get_player_pos()
        if not px then return false end
        sx, sy, sz = px + SPAWN_OFFSET_X, py, pz
    end

    local pos, rot
    pcall(function() pos = Vector3f.new(sx, sy, sz) end)
    -- Quaternion.new is (w, x, y, z); the other order spawns them in the floor.
    pcall(function() rot = Quaternion.new(1, 0, 0, 0) end)
    if not pos or not rot then return false end

    -- Final liveness check against the engine, not the scan this decision was
    -- made from. The engine creates records lazily on area entry, so by the
    -- time we act it may already have spawned them itself -- and because the
    -- next line DELETES existing records, acting on a stale read would destroy
    -- a healthy survivor and replace them with a duplicate. One NpcBaseInfo
    -- exists per stype, so there is no safe way to have both.
    local live
    pcall(function() live = mgr:call("searchInformation", stype) end)
    if live then
        local dead
        pcall(function() dead = live:call("isDead") end)
        if dead == false then
            if not forced then
                M.log(string.format(
                    "skip respawn of %s (stype=%d): already alive on arrival",
                    entry.name or "?", stype))
                return false
            end
            M.log.warn(string.format(
                "forced respawn of %s (stype=%d) is overwriting a LIVE record",
                entry.name or "?", stype))
        end
    end

    -- Must precede the spawn: isDead persists across respawns of a stype, and
    -- neither setVitalFull nor fullRecover clears it.
    local removed = clear_records_for(stype)
    local ok = pcall(function()
        mgr:call("spawnNPC(app.solid.SurvivorDefine.SurvivorType, "
            .. "via.vec3, via.Quaternion, "
            .. "solid.MT2RE.cUnitPropertyContainer, "
            .. "System.Action`1<via.GameObject>)",
            stype, pos, rot, nil, nil)
    end)
    M.log(string.format(
        "REPAIR%s: respawning %s (stype=%d, scoop='%s', %s) at %s (%.2f, %.2f, %.2f)"
            .. " -- cleared %d broken record(s), spawnNPC=%s%s",
        forced and " (forced)" or "", entry.name or "?", stype,
        scoop_name or "?", verdict or "manual",
        at_player and "player" or "spawn point", sx, sy, sz,
        removed, ok and "ok" or "FAILED", join and ", joining" or ""))
    if ok then
        spawn_pending[stype] = {
            started = os.clock(), entry = entry, scoop = scoop_name,
            join = join, at_player = at_player,
        }
    end
    return ok
end

-- Put one survivor back at the player's side, following. Shared by the
-- lost-mid-escort path and the cross-session restore: a live record is MOVED
-- (one NpcBaseInfo exists per stype, so spawning over a live one corrupts the
-- natural NPC), and only an absent or dead one is spawned.
local function restore_member(stype, scoop_name, verdict)
    local entry = db_get(stype) or { name = stype_to_name[stype] }
    local label = entry.name or tostring(stype)
    local info
    pcall(function()
        local mgr = npc_mgr:get()
        info = mgr and mgr:call("searchInformation", stype)
    end)
    local alive = false
    if info then
        local dead
        pcall(function() dead = info:call("isDead") end)
        alive = dead == false
    end
    if alive then
        M.log(string.format(
            "RESTORE: %s (stype=%d, scoop='%s', %s) -- moving live record"
                .. " to the player", label, stype, scoop_name or "?", verdict))
        if move_to_player(info) then
            promote_to_join(info, "restore " .. label)
            return true
        end
        return false
    end
    return spawn_at(stype, entry, scoop_name, false, verdict, true, true)
end

local function finish_pending_spawns()
    if not next(spawn_pending) then return end
    local mgr = npc_mgr:get()
    if not mgr then return end
    for stype, st in pairs(spawn_pending) do
        local elapsed = os.clock() - st.started
        if elapsed > 30.0 then
            M.log(string.format("repair %s: BaseInfo never appeared (30s)",
                st.entry.name or stype))
            spawn_pending[stype] = nil
        elseif elapsed >= 1.0 then
            local info
            pcall(function() info = mgr:call("searchInformation", stype) end)
            if info then
                local dead
                pcall(function() dead = info:call("isDead") end)
                if dead == false then
                    local label = st.entry.name or tostring(stype)
                    if st.join then
                        -- Respawned into the party: place them, then wire the
                        -- escort. Spawning a grouped survivor alone can break
                        -- their normal path, which JOIN sidesteps.
                        if st.at_player then
                            move_to_player(info)
                        else
                            pcall(function()
                                info:set_field("mAreaNo", st.entry.area)
                            end)
                        end
                        promote_to_join(info, "repair " .. label)
                        M.log(string.format("repair %s: alive and joined (%.1fs)",
                            label, elapsed))
                    else
                        pcall(function()
                            info:set_field("mAreaNo", st.entry.area)
                        end)
                        pcall(function()
                            info:call("setLiveState", st.entry.state or 1)
                        end)
                        M.log(string.format("repair %s: alive (%.1fs, state=%d)",
                            label, elapsed, st.entry.state or 1))
                    end
                    spawn_pending[stype] = nil
                end
            end
        end
    end
end

------------------------------------------------------------
-- Census persistence
--
-- The census has to outlive the session: a survivor killed yesterday leaves
-- only a zeroed corpse record, which without history reads as a broken spawn
-- and gets them resurrected on the next launch. Stored per slot/seed in the
-- run ledger, same as PlayerStats.
------------------------------------------------------------

local CENSUS_SECTION = "survivor_census"

-- Configured at load, not on connect: NpcInfoSweeper also feeds the census, so
-- the trap-pool filter has to be in place before any observation happens.
Census.init({
    log = M.log,
    should_track = function(stype) return stype < TRAP_POOL_MIN_STYPE end,
})

function M.load_census()
    if not Ledger.is_init() then
        M.log.debug("census load skipped: ledger not initialized yet")
        return false
    end
    local doc = Ledger.get_section(CENSUS_SECTION)
    if not doc then
        Census.reset()
        return false
    end
    return Census.restore(doc) == true
end

local function flush_census()
    if not Census.is_dirty() or not Ledger.is_init() then return end
    if Ledger.set_section(CENSUS_SECTION, Census.serialize()) then
        Census.clear_dirty()
    end
end

------------------------------------------------------------
-- Cross-session escort party
--
-- The census deliberately does NOT persist party membership -- see
-- joined_session in SurvivorCensus -- because restored history claiming a
-- party is what teleported survivors to the player on a new game. This
-- reintroduces it under a hard gate: snapshot who is following at save time,
-- and restore at load time ONLY when a monotonic fingerprint proves the loaded
-- save is at or past that point.
--
-- Not gated on game time: ScoopSanity freezes the clock, so mDate is flat in
-- exactly the mode this exists for.
------------------------------------------------------------

local PARTY_SECTION = "escort_party"
local PSM_TYPE = "app.solid.PlayerStatusManager"
local SCQ_TYPE = "app.solid.gamemastering.SCQManager"
local SCORE_TOTAL = 0

-- Signals that only ever go up within a playthrough. Any of them reading lower
-- than the snapshot proves this is an earlier save.
local function read_signals()
    local sig = {}
    local npc = npc_mgr:get()
    if npc then
        pcall(function() sig.join_count = tonumber(npc:get_field("mJoinCount")) end)
        pcall(function() sig.rescue_num = tonumber(npc:call("getRescueNum")) end)
    end
    local psm = sdk.get_managed_singleton(PSM_TYPE)
    if psm then
        pcall(function()
            sig.pp_total = tonumber(psm:call("getTotalScore", SCORE_TOTAL))
        end)
        pcall(function() sig.level = tonumber(psm:get_field("PlayerLevel")) end)
    end
    local scq = sdk.get_managed_singleton(SCQ_TYPE)
    if scq then
        pcall(function() sig.case = tonumber(scq:get_field("mCase")) end)
    end
    return sig
end

-- Tri-state on purpose: nil means the flags were unreadable, which is normal
-- inside the load window. PartySnapshot treats nil as "retry", never "no".
local function read_new_game()
    local su = _G.AP and _G.AP.ScoopUnlocker
    if not su or not su.is_new_game then return nil end
    local ok, v = pcall(su.is_new_game)
    if not ok then return nil end
    return v
end

local function current_party(by_stype)
    by_stype = by_stype or scan_records()
    if not by_stype then return nil end
    local out = {}
    for stype, recs in pairs(by_stype) do
        if stype < TRAP_POOL_MIN_STYPE then
            for _, e in ipairs(recs) do
                if (tonumber(e.state) or -1) == LIVE_STATE_JOIN and not e.is_dead then
                    table.insert(out, { stype = stype, area = e.area })
                    break
                end
            end
        end
    end
    return out
end

-- Written from the save hook so the party recorded is the party being
-- serialized. An empty party is still written, so a stale snapshot cannot
-- outlive the escort it described.
function M.snapshot_party()
    if not Ledger.is_init() then return false end
    local party = current_party()
    if not party then return false end
    local doc = Snapshot.capture(party, read_signals())
    if not Ledger.set_section(PARTY_SECTION, doc) then return false end
    M.log(string.format("party snapshot saved: %d following", #party))
    return true
end

local restore_state = nil   -- { at, tries } while a load is being evaluated
local RESTORE_RETRY_SECONDS = 1.0
local RESTORE_MAX_TRIES = 20

--- Called from the load hook. The decision itself is deferred: manager and
--- flag reads are unreliable inside the load window.
---
--- Clearing the census session state FIRST is not optional. Loading an earlier
--- save without restarting the game leaves joined_session set from the state
--- that was just being played, and the in-session lost-from-party path then
--- restores that whole party into a save where they were never recruited --
--- straight past the cross-session gate, which had correctly declined.
function M.schedule_party_restore()
    Census.begin_save_session()
    staged_this_session = {}
    lost_first_seen = {}
    restore_state = { at = os.clock() + RESTORE_SETTLE_SECONDS, tries = 0 }
end

local function apply_party_restore(doc)
    local by_stype = scan_records() or {}
    local scoops = rescuable_survivors()

    local function is_present(stype)
        for _, e in ipairs(by_stype[stype] or {}) do
            if (tonumber(e.state) or -1) == LIVE_STATE_JOIN and not e.is_dead then
                return true
            end
        end
        return false
    end
    -- Rescued IN THIS SAVE, per the census. Deliberately not "their AP check
    -- was sent" -- checks outlive the save they came from, and a player on a
    -- new game may be rescuing that survivor again for the PP or a goal.
    local function is_rescued(stype)
        return Census.verdict_for(stype, by_stype[stype]) == Census.VERDICT.RESCUED
    end

    local todo, skipped = Snapshot.to_restore(doc, is_present, is_rescued)
    for stype, why in pairs(skipped) do
        M.log.debug(string.format("party restore skips %s (stype=%d): %s",
            stype_to_name[stype] or "?", stype, why))
    end
    if #todo == 0 then
        M.log("party restore: everyone is accounted for")
        return
    end
    for _, m in ipairs(todo) do
        restore_member(m.stype, scoops[m.stype] or "?", "cross-session")
    end
end

local function tick_party_restore()
    if not restore_state or os.clock() < restore_state.at then return end
    local doc = Ledger.is_init() and Ledger.get_section(PARTY_SECTION) or nil
    local cur = read_signals()
    cur.new_game = read_new_game()
    local status, reason = Snapshot.evaluate(doc, cur)

    if status == Snapshot.STATUS.RETRY
        and restore_state.tries < RESTORE_MAX_TRIES then
        restore_state.tries = restore_state.tries + 1
        restore_state.at = os.clock() + RESTORE_RETRY_SECONDS
        return
    end

    restore_state = nil
    if status == Snapshot.STATUS.ACCEPT then
        M.log("party restore: " .. reason)
        apply_party_restore(doc)
    elseif status ~= Snapshot.STATUS.NONE then
        -- Refusals are logged loudly: this is the branch that protects an
        -- unrecoverable mistake, so it must be visible when it fires.
        M.log("party restore DECLINED -- " .. reason)
    end
end

-- notfiyDataWrite / notfiyDataRead (the engine's own typo) fire deterministically
-- around save and load -- confirmed in BACKLOG, and PlayerStats already relies
-- on the read hook. Snapshotting from NpcManager's own write means the party we
-- record is exactly the party being serialized.
local save_hooks_installed = false

local function install_save_hooks()
    if save_hooks_installed then return end
    local td = sdk.find_type_definition("app.solid.gamemastering.NpcManager")
    if not td then return end
    local m_write = td:get_method("notfiyDataWrite(app.solid.SolidStorage)")
        or td:get_method("notfiyDataWrite")
    local m_read = td:get_method("notfiyDataRead(app.solid.SolidStorage)")
        or td:get_method("notfiyDataRead")
    if not m_write or not m_read then return end

    local ok = pcall(function()
        sdk.hook(m_write,
            function() pcall(M.snapshot_party) end,
            function(retval) return retval end)
        sdk.hook(m_read,
            function() end,
            function(retval) pcall(M.schedule_party_restore) return retval end)
    end)
    save_hooks_installed = ok
    M.log.debug("party save/load hooks " .. (ok and "installed" or "FAILED"))
end

------------------------------------------------------------
-- Area-entry detection + settle timer
------------------------------------------------------------

local last_area = nil
local entry_check = nil   -- { area, at } pending settle check

function get_area()
    local am = am_mgr:get()
    if not am then return nil end
    local f = am_mgr:get_field("mAreaIndex", false)
    if not f then return nil end
    return Shared.to_int(Shared.safe_get_field(am, f))
end

-- Verdicts that mean "the engine owes us this survivor at their spawn point".
-- KILLED is absent: a dead survivor is the player's doing, and is handled
-- separately by the Survivor Respawn option. RESCUED and LOST_FROM_PARTY are
-- absent because neither belongs at a spawn point.
local REPAIRABLE = {
    [Census.VERDICT.CORRUPT] = true,
    [Census.VERDICT.NEVER_SPAWNED] = true,
    [Census.VERDICT.VANISHED] = true,
}

-- Survivor Respawn (AP option): when a survivor dies their "Rescue X" location
-- can never fire again, because the check only comes from reaching the
-- Security Room. Respawning them keeps the seed matching what generation
-- already assumed -- that every location stays reachable.
local survivor_respawn_enabled = true

function M.set_survivor_respawn_enabled(enabled)
    survivor_respawn_enabled = enabled == true
end

function M.is_survivor_respawn_enabled()
    return survivor_respawn_enabled
end

-- Master switch for the SPAWNING half only; the census keeps observing either
-- way. Exists so a broken spawn can be reproduced deliberately: without it,
-- removing a record to see whether the engine recreates it just triggers our
-- own repair and hides the answer.
local repair_enabled = true

function M.set_repair_enabled(enabled)
    repair_enabled = enabled ~= false
end

function M.is_repair_enabled()
    return repair_enabled
end

local function run_repair_check(area, by_stype)
    if not by_stype then return end

    -- Broken-spawn repair stays scoop-gated: it exists to fix a flag-spawn
    -- that never fired for a scoop you are actively working on.
    local eligible, groups = eligible_survivors()
    for stype, info in pairs(eligible) do
        local entry = db_get(stype)
        if entry and entry.area == area and not spawn_pending[stype] then
            local verdict = Census.verdict_for(stype, by_stype[stype])
            local repairable = REPAIRABLE[verdict]

            -- NEVER_SPAWNED on a cutscene-staged NPC means "the scene has not
            -- played yet", not "broken". Only treat it as broken once a
            -- sibling proves the group event ran. VANISHED/CORRUPT are exempt:
            -- both carry evidence the NPC already existed.
            if repairable and verdict == Census.VERDICT.NEVER_SPAWNED
                and info.category ~= "Survivor" then
                local state = group_spawn_state(groups[info.scoop], stype,
                                                info.scoop)
                if state ~= "yes" then
                    repairable = false
                    M.log.debug(string.format(
                        "holding off on %s (stype=%d): '%s' group spawn=%s"
                            .. " -- use drap_recover_force(%d) to override",
                        stype_to_name[stype] or "?", stype, info.scoop,
                        state, stype))
                end
            end

            if repairable then
                spawn_at(stype, entry, info.scoop, false, verdict)
            end
        end
    end

    -- Death respawn is gated on the CHECK instead, for the reasons on
    -- rescuable_survivors. Area ENTRY only: they come back where they
    -- started, so the player walks back for them, and they get a live
    -- controller straight away instead of idling in an empty area. JOIN
    -- because a survivor who normally spawns in a group can break alone.
    if not survivor_respawn_enabled then return end
    for stype, scoop_name in pairs(rescuable_survivors()) do
        local entry = db_get(stype)
        if entry and entry.area == area and not spawn_pending[stype] then
            if Census.verdict_for(stype, by_stype[stype]) == Census.VERDICT.KILLED then
                spawn_at(stype, entry, scoop_name, false,
                    Census.VERDICT.KILLED, true, false)
            end
        end
    end
end

------------------------------------------------------------
-- Party restore (a survivor lost while following the player)
------------------------------------------------------------

-- Not area-gated and not tied to an area-entry edge: the player is standing
-- there mid-escort, so the fix belongs at their feet as soon as we trust it.
local function run_party_restore(by_stype)
    if not by_stype then return end
    -- Same gate as death respawn: someone who was physically following the
    -- player is worth restoring whatever category their scoop is, and whether
    -- or not the scoop itself has completed. The census RESCUED verdict, not
    -- the AP check, is what stops us touching someone already delivered.
    local rescuable = rescuable_survivors()
    if not next(rescuable) then return end

    for stype, scoop_name in pairs(rescuable) do
        local verdict = Census.verdict_for(stype, by_stype[stype])
        if verdict ~= Census.VERDICT.LOST_FROM_PARTY then
            lost_first_seen[stype] = nil
        elseif not spawn_pending[stype] then
            local first = lost_first_seen[stype]
            if not first then
                lost_first_seen[stype] = os.clock()
            elseif os.clock() - first >= RESTORE_SETTLE_SECONDS then
                lost_first_seen[stype] = nil
                restore_member(stype, scoop_name, Census.VERDICT.LOST_FROM_PARTY)
            end
        end
    end
end

------------------------------------------------------------
-- Frame driver
------------------------------------------------------------

-- ScoopSanity drives survivor spawning through flags, and that is the only
-- mode where the spawns break. Vanilla is left completely alone -- including
-- the harvester, since drdr_shared.json already ships every survivor position.
local function scoop_sanity_on()
    local su = _G.AP and _G.AP.ScoopUnlocker
    if not su or not su.is_scoop_sanity_enabled then return false end
    local ok, on = pcall(su.is_scoop_sanity_enabled)
    return ok and on == true
end

-- Nothing spawns before AP activation (meeting Jessie), the same gate the rest
-- of the mod uses. A new game on an existing run starts pre-activation with a
-- census full of history, and without this the intro would spawn survivors the
-- player has not reached yet.
local function ap_activated()
    local su = _G.AP and _G.AP.ScoopUnlocker
    if not su or not su.is_ap_activated then return false end
    local ok, on = pcall(su.is_ap_activated)
    return ok and on == true
end

function M.on_frame()
    if not M:should_run() then return end
    if not scoop_sanity_on() then return end
    install_save_hooks()
    if not Shared.is_in_game() then
        last_area = nil
        entry_check = nil
        lost_first_seen = {}
        return
    end

    finish_pending_spawns()

    -- One scan per tick feeds the census, both repair paths and the harvester.
    -- The census must see every tick, not just area entries: its whole job is
    -- to have witnessed a survivor alive before they turn up as a corpse.
    local by_stype = scan_records()
    if by_stype then
        Census.observe(by_stype)
        flush_census()
    end

    -- Observation above is always safe and worth keeping; anything that SPAWNS
    -- waits for activation, and can be switched off for controlled testing.
    local may_spawn = ap_activated() and repair_enabled

    if by_stype and may_spawn then
        -- Party restore runs every tick, unlike spawn-point repair -- a
        -- survivor lost mid-escort should not wait for the next door.
        run_party_restore(by_stype)
    end
    if may_spawn then tick_party_restore() end

    local area = get_area()
    if area and area ~= last_area then
        -- Area-ENTRY edge: schedule the repair check after the engine's
        -- own lazy creation has had time to act.
        if last_area ~= nil then
            entry_check = { area = area, at = os.clock() + REPAIR_SETTLE_SECONDS }
        end
        last_area = area
    end

    if entry_check and os.clock() >= entry_check.at then
        local check = entry_check
        entry_check = nil
        if get_area() == check.area and may_spawn then
            run_repair_check(check.area, by_stype)
        end
    end

    if by_stype then harvest(by_stype) end
end

------------------------------------------------------------
-- Console
------------------------------------------------------------

_G.drap_recover_status = function()
    load_db()
    ensure_maps()
    local n = 0
    for _ in pairs(db) do n = n + 1 end
    M.log(string.format("positions DB: %d survivors harvested -> %s", n, DB_FILE))
    local names = {}
    for stype_s, e in pairs(db) do
        table.insert(names, string.format("%s(%s@%s)",
            e.name or "?", stype_s, tostring(e.area)))
    end
    table.sort(names)
    M.log("  " .. table.concat(names, ", "))
end

-- Every NPC of every DRAP-active scoop, whatever the category. Auto-repair
-- only covers Survivor-category scoops, but a psycho-scoop NPC who fails to
-- appear is exactly what gets reported, so the diagnostic has to show them.
local function active_scoop_npcs()
    ensure_maps()
    local su = _G.AP and _G.AP.ScoopUnlocker
    if not su or not su.get_all_status then return {} end
    local out = {}
    local ok, status = pcall(su.get_all_status)
    if not ok or type(status) ~= "table" then return out end
    for _, s in ipairs(status) do
        if s.received and not s.completed and type(s.npcs) == "table" then
            for _, npc_name in ipairs(s.npcs) do
                local stype = name_to_stype[npc_name]
                if stype then
                    out[stype] = { scoop = s.name, category = s.category }
                end
            end
        end
    end
    return out
end

-- Why each active scoop NPC is (or is not) being repaired. The verdict is the
-- whole decision, so this is the first thing to read on a "they never spawned"
-- or "they came back from the dead" report.
_G.drap_census_status = function()
    local s = Census.stats()
    M.log(string.format(
        "census: %d observed, %d seen alive, %d died, %d joined, %d rescued"
            .. " | survivor respawn=%s, escort party=%d",
        s.total, s.ever_alive, s.deaths, s.ever_joined, s.rescued,
        tostring(survivor_respawn_enabled), get_escort_count()))

    local by_stype = scan_records() or {}
    local rescuable = rescuable_survivors()
    local _, status_groups = eligible_survivors()
    local shown = {}
    local lines = {}

    local function add(stype, scoop, category)
        if shown[stype] then return end
        shown[stype] = true
        local h = Census.get(stype) or {}
        -- Two different gates, so name which ones this survivor passes:
        -- spawn-point repair needs a Survivor-category active scoop, while
        -- death respawn and party restore cover any rescuable survivor.
        local gates = {}
        if category == "Survivor" then table.insert(gates, "repair") end
        if rescuable[stype] then table.insert(gates, "rescuable") end
        if #gates == 0 then table.insert(gates, "manual only") end
        -- Cutscene-staged NPCs are deliberately held back until their scoop's
        -- group is known to have spawned; say so rather than looking idle.
        if category and category ~= "Survivor" then
            local st = group_spawn_state(status_groups[scoop], stype, scoop)
            if st ~= "yes" then table.insert(gates, "held:group=" .. st) end
        end
        table.insert(lines, string.format(
            "  %s (stype=%d, scoop='%s' [%s], %s): %s [records=%d "
                .. "ever_alive=%s death_seen=%s joined=%s safe=%s max_state=%s]",
            stype_to_name[stype] or "?", stype, scoop or "?",
            tostring(category or "?"), table.concat(gates, "+"),
            Census.verdict_for(stype, by_stype[stype]),
            #(by_stype[stype] or {}), tostring(h.ever_alive or false),
            tostring(h.death_seen or false), tostring(h.ever_joined or false),
            tostring(h.ever_safe or false), tostring(h.max_state or 0)))
    end

    for stype, info in pairs(active_scoop_npcs()) do
        add(stype, info.scoop, info.category)
    end
    -- Rescuable survivors whose scoop is already complete or inactive are
    -- invisible to the loop above, and they are precisely the ones that used
    -- to fall through the cracks.
    for stype, scoop in pairs(rescuable) do add(stype, scoop, nil) end

    table.sort(lines)
    if #lines == 0 then
        M.log("  (nothing active and no outstanding rescue checks)")
    else
        for _, l in ipairs(lines) do M.log(l) end
    end
end

-- What the cross-session gate would decide right now, and why. Read this
-- before concluding a restore "did nothing" -- a refusal is a deliberate
-- outcome, and this names the signal responsible.
_G.drap_party_snapshot = function()
    local doc = Ledger.is_init() and Ledger.get_section(PARTY_SECTION) or nil
    local cur = read_signals()
    cur.new_game = read_new_game()

    local sig = doc and doc.signals or {}
    M.log("stored snapshot: " .. (doc and (Snapshot.party_size(doc)
        .. " member(s)") or "none"))
    for _, k in ipairs(Snapshot.SIGNALS) do
        M.log(string.format("   %-11s snapshot=%-10s now=%s", k,
            tostring(sig[k]), tostring(cur[k])))
    end
    M.log("   new_game    now=" .. tostring(cur.new_game))
    for _, m in ipairs((doc or {}).party or {}) do
        M.log(string.format("   member: %s (stype=%d, area=%s)",
            stype_to_name[m.stype] or "?", m.stype, tostring(m.area)))
    end
    local status, reason = Snapshot.evaluate(doc, cur)
    M.log(string.format("verdict: %s -- %s", status, reason))
    return status
end

-- Force a snapshot without saving the game. Lets the whole snapshot -> loss ->
-- restore path be exercised in one sitting, instead of waiting for the rare
-- bug that motivated it.
_G.drap_party_snapshot_save = function()
    if not Ledger.is_init() then
        M.log("cannot snapshot: ledger not initialized (connect first)")
        return false
    end
    return M.snapshot_party()
end

-- Force the load-time evaluation now. Runs the same gate a real load would,
-- so a refusal here is a real refusal.
_G.drap_party_restore_now = function()
    M.schedule_party_restore()
    M.log("party restore scheduled -- evaluating in "
        .. tostring(RESTORE_SETTLE_SECONDS) .. "s")
end

-- Turn auto-repair off to reproduce a broken spawn on purpose: with it on,
-- removing a record just triggers our own repair and hides what the engine
-- would have done. drap_census_status keeps working either way.
_G.drap_recover_enabled = function(on)
    if on == nil then on = not M.is_repair_enabled() end
    M.set_repair_enabled(on)
    M.log("auto-repair " .. (M.is_repair_enabled() and "ENABLED" or "DISABLED")
        .. " (census still observing)")
end

-- Manual repair for anything auto-repair deliberately skips (psycho-scoop
-- NPCs, boss-gated hostages). Requires a DB entry.
_G.drap_recover_force = function(stype)
    stype = tonumber(stype)
    ensure_maps()
    local entry = db_get(stype)
    if not entry then
        M.log(string.format("no DB position for stype %s -- visit them on a "
            .. "healthy save first (harvester) ", tostring(stype)))
        return
    end
    spawn_at(stype, entry, "manual", true)
end

return M
