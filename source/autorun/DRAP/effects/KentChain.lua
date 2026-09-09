-- DRAP/effects/KentChain.lua
-- Kent's three days, playable in any order and replayable.
--
-- The engine's model (measured, docs/Kent_Handoff.md): a day RUNS while its
-- START flag is on and its FINISH is off; STARTs are cumulative; the queue,
-- the display boxes and the appear/timeout flags are all DERIVED from that
-- state every tick (moveListQue / scoopSetCheck). Continuously asserting
-- Kent flags therefore fights the engine -- re-asserting 1225 respawned
-- day-2 Kent, holding a box's END off made day 1 "Scoop Chance Lost", and
-- clearing another day's FINISH re-ran its completion. So this module never
-- holds a claim: it applies the measured arming recipe ONCE per transition
-- and lets the engine drive.
--
-- The recipe, isolated 2026-08-21 (each step's necessity measured):
--   1. wipe the Kent flag family -- including 343 (EV_EVB07, "the day-3
--      battle happened") which blocks the photoshoot event after day 3;
--   2. clear Kent's enemy death records, EmSaveParam[1]/[2] -- psycho Kent
--      is an EM45 ENEMY; the slots are identity-indexed (enumEmSaveParam:
--      EM45_1/EM45_2) so they are stable on every save. Without this the
--      photoshoot event spawns him dead;
--   3. zero the scoop fields of his NpcBaseInfo if one exists (records are
--      created per placement and usually absent between days);
--   4. set the day's measured standalone start set (the scoop row's
--      `flags`). Works in-session; no reload needed.
--
-- psychoKillBit is deliberately NOT touched: verified unnecessary, and it
-- is a shared bitmask holding other psychos' kill records.
--
-- Which day to arm comes from the existing machinery: the Kent scoops are a
-- conflict group, so at most one is received-and-uncompleted at a time, and
-- the group's ADVANCE unlocks the next when one completes. This module just
-- mirrors "the received, uncompleted Kent day" into engine state.
--
-- Transitions apply WHEREVER the player stands, a short debounce after the
-- desired day changes (so the completing day's ceremony writes land first).
-- Vanilla 2->3 happens with no area change at all -- psycho Kent appears in
-- place -- so an area-gated arm breaks real flows. The ceremony-refire
-- hazard that once motivated an area guard is handled structurally instead:
-- completed days' records are never touched (see KEEP_WHEN_COMPLETED).
--
-- When NO day should run (nothing received yet, everything completed, or
-- the sanity layer idle) the three START flags are held off at the module
-- throttle, replacing the pre-activation suppression these flags used to
-- get from the reconciler -- the engine sets 779 by itself on the vanilla
-- schedule, so a one-shot clear would not stay cleared.

local Shared = require("DRAP/Shared")
local SharedData = require("DRAP/SharedData")

local M = Shared.create_module("KentChain")
M:set_throttle(1.0)

local efm_mgr = M:add_singleton("efm", "app.solid.gamemastering.EventFlagsManager")
local am_mgr  = M:add_singleton("am",  "app.solid.gamemastering.AreaManager")
local npc_mgr = M:add_singleton("npc", "app.solid.gamemastering.NpcManager")
local ss_mgr  = M:add_singleton("ss",  "app.solid.SolidStorage")
local em_mgr  = M:add_singleton("em",  "app.solid.EnemyManager")
local pm_mgr  = M:add_singleton("pm",  "app.solid.PlayerManager")

-- Day order IS the arming preference: the conflict group unlocks at most one
-- at a time, but if state ever disagrees the earliest listed day wins.
local DAYS = {
    "Cut from the Same Cloth",   -- day 1
    "Photo Challenge",           -- day 2
    "Photographer's Pride",      -- day 3
}

-- Only days 2 and 3 have a handoff token: their box entry flags (2508,
-- 2509) are written by the PREVIOUS day's completion cluster. Day 1 has
-- no predecessor, so 2507 being on never means a handoff. It was on in a
-- tester's save from an earlier arm of day 1 (2026-08-29): on the reload
-- the quiet-state sweep knocked 779 down before the ledger replayed the
-- unlock, the replay then found 2507 on and gentle-armed onto a queue
-- entry the load had never activated, and Kent stayed away -- with days
-- 2 and 3 chained behind him.
local function has_handoff_token(name)
    return name ~= DAYS[1]
end

local KENT_STYPE = 32
-- Debounce between the desired day changing and the arm, so the completing
-- day's ceremony writes land first.
local SETTLE_SECONDS = 3.0

-- Arming during a completing day's cutscene is what produces "Scoop Chance
-- Lost": the conflict group advances the instant a day completes, so day 3's
-- unlock lands inside day 2's ceremony, and clearing the scheduler's records
-- mid-ceremony makes it re-run scoop 32's appear->lost cycle (measured: DRAP
-- cleared 1224, the engine answered 1224 @ scoopSetCheck then 1277 @
-- lateUpdate, and 1277 IS the banner). Day 2 alone never showed it; waiting
-- a few seconds before starting day 3 never showed it.
--
-- GameManager.mEventNo was tried as the gate and REJECTED: it holds the LAST
-- event number rather than clearing, so it never reads "no event" again
-- (trace 112517 sat at evno=117 for hundreds of seconds after that event
-- ended) and day 3 simply never armed.
--
-- The player cannot move during a cutscene, so sustained player movement is
-- the honest "the ceremony is over and control is back" signal.
-- Movement alone is not enough: a cutscene ANIMATES the player actor, so
-- "is moving right now" reads true mid-ceremony, and an arm fired as soon as
-- day 2's cutscene ended. So the clock starts at the FIRST movement seen
-- after the transition and is STICKY -- standing still does not reset it --
-- and the arm waits ARM_DELAY beyond that. Movement says control came back;
-- the delay covers the ceremony writes that trail it.
local MOVE_EPSILON = 0.05         -- metres per sample that counts as moving
local ARM_DELAY = 6.0             -- wait this long after movement is first seen
                                  -- (runtime-tunable: drap_kent_gate)
local MOVE_WAIT_CAP = 60.0        -- arm anyway if the player never moves

-- Everything any Kent day can leave behind, flag-wise. The union of the
-- three days' start sets, the engine's completion/appear/timeout records,
-- the EM45 encounter family, and the battle records. 343 (EV_EVB07) and
-- 1155/1171/1292 are the ones history missed; see docs/Kent_Handoff.md.
local FAMILY = {
    779, 780, 781,          -- STARTs
    843, 844, 845,          -- FINISHes
    2443, 2444, 2445,       -- SUCCESSes
    2507, 2508, 2509,       -- display entries
    2541, 2542,             -- display ends (day 3's is 1155 below)
    2710,                   -- STARTC9, day 3's second start flag
    1224, 1225, 1277, 1278, -- NPC21 appear / timeout records
    385, 386, 387, 388, 389,-- EM45 SET records
    344, 345, 3601,         -- EM45SET / request records
    342, 352, 343,          -- EVB battle records (343 = EVB07, day-3 fight)
    1155, 1171, 1292,       -- third-appear / day-3 lost / enemy-set trigger
    346, 1290, 1291,        -- enemy-set members (sets 0/1)
}

-- EmSaveParam slots, identity-indexed by app.solid.enumEmSaveParam:
-- 1 = EM45_1_SAVE_PARAM, 2 = EM45_2_SAVE_PARAM -- both exclusively Kent.
local EMSAVE_SLOTS = { 1, 2 }

-- A COMPLETED day keeps its ENTIRE vanilla post-completion footprint --
-- the exact flags the engine wrote at its completion, measured in
-- docs/Kent_flag_tests.md. Clearing any of a completed day's records
-- in-session makes some subsystem re-run its completion ceremony (the
-- phantom "day-2 window": first seen on FINISH/SUCCESS, still fired when
-- only its EM45 records/box flags were wiped). Mirror vanilla, do not
-- synthesize a cleaner state.
--
-- Day 3 is the deliberate exception: its residue (343, 845/2445, 1155,
-- 1171, 1292, EmSaveParam) PROVABLY blocks the other days, the proven
-- replay recipe clears all of it, and its ceremony has never re-fired
-- (it is the psycho death event -- it needs the actor). Empty keep set.
local KEEP_WHEN_COMPLETED = {
    ["Cut from the Same Cloth"] = {          -- day-1 completion footprint
        779, 843, 2443, 2507, 2541,          -- start/finish/success, box
        385, 344,                            -- EM45 set-1 records
        1224, 1277,                          -- appear + timeout records
        342,                                 -- EVB02: in the MEASURED
        -- completion trace (lands right after 843/1277) but not the
        -- flag-tests summary table. Wiping it made the engine RE-RUN
        -- day-1's shoot on re-entry with day 2 armed. 3601 (EM45_REQ) is
        -- deliberately NOT here: it belongs to the day-3 ARMING context
        -- (fires with 1224 after day 3's start set), and forcing it ON
        -- during day 2 jammed the set spawn -- Kent did not place.
    },
    ["Photo Challenge"] = {                  -- day-2 completion footprint
        780, 844, 2444, 2508, 2542,          -- start/finish/success, box
        386, 387, 389, 345,                  -- EM45 set-2 records
        -- 1225 deliberately NOT kept: it is day 2's appear INPUT, not a
        -- record. Keeping it dressed the freshly placed Kent as day-2
        -- (his behavior asserted EM45_SET2, untalkable) -- measured
        -- 2026-08-21. The day-1 standalone set has it explicitly off.
    },
    ["Photographer's Pride"] = {},           -- day 3: cleared (see above)
}

-- Retired = START on + FINISH on; re-asserted for kept completed days in
-- case anything cleared them (the day-3 start set does this by hand too).
-- The scheduler's own records for each day, from
-- rSCQTable.mScoopSetSchedulers (drap_scq_sched):
--     [0] area=512 queNo=32 set=1224(APPEAR1) timeout=1277(TIMEOUT1)
--     [1] area=512 queNo=34 set=0             timeout=1171
-- queNo 33 (day 2) has NO scheduler row.
--
-- These belong to SCQ.scoopSetCheck / SCQ.lateUpdate, not to us. Clearing a
-- RETIRED day's records makes the scheduler re-run that day's appear->lost
-- cycle: measured 2026-08-22 on a 2->3 arm, we cleared 1224 and the engine
-- answered with 1224 (scoopSetCheck) then 1277 (lateUpdate) -- and 1277
-- firing IS the "Scoop Chance Lost" banner.
local DAY_SCHEDULER_RECORDS = {
    ["Cut from the Same Cloth"] = { 1224, 1277 },
    ["Photo Challenge"]         = {},
    ["Photographer's Pride"]    = { 1171 },
}

-- A day is retired by an arm when the arm SETS its FINISH flag.
local DAY_FINISH = {
    ["Cut from the Same Cloth"] = 843,
    ["Photo Challenge"]         = 844,
    ["Photographer's Pride"]    = 845,
}

local DAY_RETIRE = {
    ["Cut from the Same Cloth"] = { 779, 843 },
    ["Photo Challenge"]         = { 780, 844 },
    ["Photographer's Pride"]    = {},
}

-- Held OFF every tick while the day is ARMED and not completed --
-- 1.2.0 HEAD's proven day-2 configuration, verbatim (the old
-- disable_flags list the rework deleted). Day-2-after-day-1 same-day is
-- NOT the vanilla overnight path: it works by pinning day-1's residue off
-- so scoop 32's scheduler re-fires the appear (1224 off, 843 off = still
-- scheduled) and the flags dress the appeared Kent as day 2. This must be
-- CONTINUOUS: a one-shot clear lets the engine re-assert the records and
-- re-run day-1's shoot instead (the 5h regression). Verified working for
-- months in the shipped build; only day 2 needs it (day 1 and day 3's
-- out-of-order arms are proven with their own recipes).
local CLEAR_WHILE_ARMED = {
    ["Photo Challenge"] = { 342, 344, 385, 843, 1224, 1277 },
}

-- Quiet-state suppression targets (see on_frame): the STARTs of days that
-- are not completed.
local DAY_STARTS = {
    ["Cut from the Same Cloth"] = { 779 },
    ["Photo Challenge"]         = { 780 },
    ["Photographer's Pride"]    = { 781, 2710 },
}

-- Armed-state verification flags: ONLY the EV_SCQ_START queue flags, which
-- are cumulative and never engine-cleared mid-day (measured). NOT 2710
-- (STARTC9) -- the meet-day-3 sequence quick-loads and consumes it, and
-- verifying it made the post-quickload check read "unwound by a load",
-- re-arm mid-day, and replay the cutscene (field report 2026-08-21).
local VERIFY_STARTS = {
    ["Cut from the Same Cloth"] = { 779 },
    ["Photo Challenge"]         = { 779, 780 },
    ["Photographer's Pride"]    = { 779, 780, 781 },
}

local armed_day = nil         -- name of the day the recipe last armed
local armed_at = nil          -- os.clock() of the last successful arm
local box_topped_up = false   -- one box top-up per arm (see tick)
local want_seen = nil         -- last desired-day value observed
local want_since = nil        -- os.clock() when it changed
local verify_pending = false  -- re-check armed flags after a load edge
local death_edge_at = nil     -- os.clock() when day-3 completion registered
local death_clear_wanted = false -- another day is coming, so clear the records
-- The engine's completion handoff cluster takes ~4s (843 at t+0, the 2508
-- token at t+4, healthy trace). An arm inside that window must WAIT for
-- the token (then gentle-arm) or for the window to lapse (then full-wipe,
-- the out-of-order case where no handoff is coming).
local handoff_deadline = nil
local HANDOFF_WAIT = 10.0
local completed_snapshot = {} -- day -> completed, as of last tick
local last_pos = nil          -- previous sampled player position
local moved_at = nil          -- os.clock() of the FIRST movement since the
                              -- last arm; sticky until the next transition
local arm_blocked_since = nil -- os.clock() when the gate first held the arm
local record_stale = false    -- day-3 aftermath left a bad record: remove it
                              -- on the NEXT arm (only then -- removing a
                              -- LIVE actor's record orphans him)
local DEATH_CLEAR_WINDOW = 20.0  -- keep clearing this long after the edge:
                                 -- the death event may write the record
                                 -- again mid-cutscene after our first clear

-- The three rows' `flags` lists ARE the measured standalone start sets,
-- and their guide entries carry Kent's authored spawn position.
local start_sets = nil        -- name -> flags list, from shared data
local spawn_pos = nil         -- name -> {x,y,z} authored photo-spot position
local disp_flags = nil        -- name -> box entry flag (the handoff token)
local disp_end_flags = nil    -- name -> box END flag

local function ensure_start_sets()
    if start_sets then return end
    start_sets, spawn_pos, disp_flags, disp_end_flags = {}, {}, {}, {}
    for _, e in ipairs(SharedData.scoops()) do
        if e.chain_managed and e.name then
            start_sets[e.name] = e.flags
            disp_flags[e.name] = e.disp_flag
            disp_end_flags[e.name] = e.disp_end_flag
            local g = e.guide
            if g and g.x and g.y and g.z then
                spawn_pos[e.name] = { x = g.x, y = g.y, z = g.z }
            end
        end
    end
end

------------------------------------------------------------
-- Engine access
------------------------------------------------------------

local function flag_check(fid)
    local efm = efm_mgr:get()
    if not efm then return nil end
    local ok, v = pcall(function() return efm:call("evFlagCheck", fid) end)
    if ok then return v == true end
    return nil
end

local function flag_set(fid, on)
    local efm = efm_mgr:get()
    if not efm then return false end
    return pcall(function() efm:call(on and "evFlagOn" or "evFlagOff", fid) end)
end

local function current_area()
    local am = am_mgr:get()
    if not am then return nil end
    local f = am_mgr:get_field("mAreaIndex", false)
    if not f then return nil end
    return Shared.to_int(Shared.safe_get_field(am, f))
end

local function unlocker()
    return _G.AP and _G.AP.ScoopUnlocker
end

local function scoop_sanity_on()
    local su = unlocker()
    if not su or not su.is_scoop_sanity_enabled then return false end
    local ok, on = pcall(su.is_scoop_sanity_enabled)
    return ok and on == true
end

------------------------------------------------------------
-- The recipe
------------------------------------------------------------

local function zero_em_save_param(e, label)
    if not e then return end
    pcall(function()
        local be = e:get_field("mBeflag") == true
        local p = e:get_field("Pos")
        local has_pos = p and (p.x ~= 0 or p.y ~= 0 or p.z ~= 0)
        if be or has_pos then
            e:set_field("mBeflag", false)
            e:set_field("GameTime", 0)
            e:set_field("VitalNew", 0)
            -- Pos too: the photoshoot Kent is the EM45 ENEMY, and a stale
            -- Pos from a previous day's shoot re-places him there (the
            -- downstairs spawn). Clean baseline slots are all-zero.
            pcall(function() e:set_field("Pos", Vector3f.new(0, 0, 0)) end)
            M.log("cleared enemy record " .. label
                .. (has_pos and " (incl stale position)" or ""))
        end
    end)
end

local function clear_enemy_records()
    -- Both copies must be cleaned. The save blob (SolidSave.EmSaveParam) is
    -- what the photoshoot event reads -- but it is RE-SERIALIZED from
    -- EnemyManager's LIVE records on every autosave, and walking back into
    -- Paradise Plaza is an area transition = an autosave. Cleaning only the
    -- blob let the death come straight back (measured: 2->3->1, day-1 Kent
    -- spawned dead).

    -- 1. The live records: EnemyManager.EnemySaveParamList, identified by
    --    the EnumEmParam field, not list position.
    local em = em_mgr:get()
    if em then
        pcall(function()
            local list = em:get_field("EnemySaveParamList")
            local n = list and list:call("get_Count") or 0
            for i = 0, n - 1 do
                local entry = list:call("get_Item", i)
                if entry then
                    local which = Shared.to_int(entry:get_field("EnumEmParam"))
                    for _, slot in ipairs(EMSAVE_SLOTS) do
                        if which == slot then
                            zero_em_save_param(entry:get_field("SaveData"),
                                string.format("live EmSaveData enum %d", which))
                        end
                    end
                end
            end
        end)
    end

    -- 2. The save-work copy, for reads that happen before the next save.
    local ss = ss_mgr:get()
    if not ss then return end
    local save
    pcall(function() save = ss:get_field("mSaveWork") end)
    if not save then return end
    local arr
    pcall(function() arr = save:get_field("EmSaveParam") end)
    if not arr then return end
    for _, i in ipairs(EMSAVE_SLOTS) do
        pcall(function()
            local e = arr:call("get_Item", i) or arr:get_element(i)
            zero_em_save_param(e, string.format("EmSaveParam[%d]", i))
        end)
    end
end

-- remove_mode: true only for the day-3 aftermath record -- it has no live
-- actor behind it (Kent is dead) and carries a bad POSITION the placement
-- path would reuse (he spawned downstairs off it). For every other
-- transition the record belongs to a LIVE actor (post-photoshoot Kent
-- wandering the plaza) and removal ORPHANS him -- day-2 Kent then never
-- spawned (measured 2026-08-21). In-place zeroing is the proven default.
local function reset_npc_record(remove_mode, pos)
    local mgr = npc_mgr:get()
    if not mgr then return end
    local list
    pcall(function() list = mgr:get_field("NpcInfoList") end)
    if not list then return end
    local n
    pcall(function() n = list:call("get_Count") end)
    -- Census diagnostic: a chained same-area transition was observed with
    -- NO stype-32 record at arm time even though a Kent actor stood in the
    -- plaza -- knowing which records exist decides whether the position
    -- problem is record-borne or actor-borne.
    local stypes = {}
    for i = 0, (n or 0) - 1 do
        pcall(function()
            local e = list:call("get_Item", i)
            if e then
                table.insert(stypes,
                    tostring(Shared.to_int(e:get_field("<Name>k__BackingField"))))
            end
        end)
    end
    for i = 0, (n or 0) - 1 do
        local info
        pcall(function()
            local e = list:call("get_Item", i)
            if e and Shared.to_int(e:get_field("<Name>k__BackingField")) == KENT_STYPE then
                info = e
            end
        end)
        if info then
            if remove_mode then
                local removed = pcall(function()
                    mgr:call("removeInformation(app.solid.npc.NpcBaseInfo)", info)
                end)
                if not removed then
                    removed = pcall(function() mgr:call("removeInformation", info) end)
                end
                if removed then
                    M.log("removed Kent's day-3 aftermath record (fresh placement next entry)")
                    return
                end
            end
            pcall(function()
                info:set_field("mScoopCheckState", 0)
                info:set_field("mScoopTimeOutFlag", 0)
                info:set_field("mFreeFlag", 0)
                info:set_field("mSituationNo", 0)
            end)
            -- Restore the AUTHORED spawn position: placement reuses the
            -- record's position, and the previous day's Kent wanders after
            -- his shoot -- the next day then spawned wherever he ended up
            -- (downstairs, measured on 2->1 after 3->2). setPos, with the
            -- field as the fallback.
            if pos then
                pcall(function()
                    local v = Vector3f.new(pos.x, pos.y, pos.z)
                    local ok = pcall(function() info:call("setPos", v) end)
                    if not ok then info:set_field("mPos", v) end
                end)
            end
            M.log("zeroed Kent's record scoop fields"
                .. (pos and " + restored authored spawn position" or ""))
            return
        end
    end
    M.log(string.format("no stype-32 record among %d (stypes: %s)",
        n or 0, table.concat(stypes, ",")))
end

local function apply_day(name)
    ensure_start_sets()
    local start_set = start_sets[name]
    if not start_set or #start_set == 0 then
        M.log("no start set for '" .. tostring(name) .. "' -- cannot arm")
        return false
    end

    -- GENTLE ARM: when the engine has ALREADY handed off to this day (its
    -- box entry flag -- the measured handoff token, set by the previous
    -- day's completion -- is on), its queue entry is freshly ACTIVATED
    -- (StateSub SCENARIO_START). The full wipe below destroys that entry;
    -- the queue re-derives it as StateSub NONE and the activation edge is
    -- spent -- queued forever, never ready, no spawn (vanilla-order 1->2,
    -- measured via drap_kent_scq 2026-08-22). Preserve the engine's own
    -- handoff: only top up the day's input flags (e.g. 1225) and leave
    -- everything else exactly as the engine built it.
    local disp = disp_flags[name]
    if disp and has_handoff_token(name) and flag_check(disp) == true then
        local ids = {}
        for _, fid in ipairs(start_set) do
            flag_set(fid, true)
            table.insert(ids, tostring(fid))
        end
        M.log(string.format(
            "gentle arm '%s' (engine handoff detected; inputs %s topped up)",
            name, table.concat(ids, " ")))
        return true
    end

    -- Completed OTHER days keep their entire vanilla completion footprint
    -- and stay retired -- see KEEP_WHEN_COMPLETED.
    local su = unlocker()
    local keep = {}
    local retire = {}
    local kept_days = 0
    for day_name, keep_list in pairs(KEEP_WHEN_COMPLETED) do
        if day_name ~= name and su then
            local ok, done = pcall(su.is_scoop_completed, day_name)
            if ok and done == true then
                for _, fid in ipairs(keep_list) do keep[fid] = true end
                for _, fid in ipairs(DAY_RETIRE[day_name] or {}) do
                    table.insert(retire, fid)
                end
                if #keep_list > 0 then kept_days = kept_days + 1 end
            end
        end
    end

    -- A day this arm RETIRES (its FINISH flag is in the start set -- day 3
    -- carries 843 and 844) keeps its scheduler records too, exactly as a
    -- completed day does. Otherwise the wipe hands the scheduler a cleared
    -- appear flag for a day that is over, it re-appears the set and then
    -- loses it, and the player gets "Scoop Chance Lost". KEEP_WHEN_COMPLETED
    -- does not cover this: out of order, the retired day was never played.
    local in_start_set = {}
    for _, fid in ipairs(start_set) do in_start_set[fid] = true end
    for day_name, finish in pairs(DAY_FINISH) do
        if day_name ~= name and in_start_set[finish] then
            for _, fid in ipairs(DAY_SCHEDULER_RECORDS[day_name] or {}) do
                keep[fid] = true
            end
        end
    end

    for _, fid in ipairs(FAMILY) do
        if not keep[fid] then flag_set(fid, false) end
    end
    for _, fid in ipairs(retire) do flag_set(fid, true) end
    clear_enemy_records()
    reset_npc_record(record_stale, spawn_pos[name])
    record_stale = false
    local ids = {}
    for _, fid in ipairs(start_set) do
        flag_set(fid, true)
        table.insert(ids, tostring(fid))
    end
    M.log(string.format(
        "armed '%s' (flags %s)%s; scheduler evaluates on area entry",
        name, table.concat(ids, " "),
        kept_days > 0
            and (" -- kept " .. kept_days .. " completed day(s)' footprint")
            or ""))
    return true
end

-- While a day is armed and its photoshoot has not started, Kent's record
-- must never carry a finished-day footprint. The arm's one-shot cleanup is
-- not enough: save/NPC reconstruction can RE-CREATE the previous day's
-- record (DONE + 0x200 + old timeout) at any moment afterwards, and the
-- talk-sequence load then DISCARDS the poisoned record and re-places Kent
-- at the fallback point downstairs (measured 2026-08-21: record present
-- with day-2 footprint before the talk, gone after, Kent downstairs; in
-- the healthy baseline the record survives that load).
--
-- The guard stops the moment the engine starts the shoot -- it writes
-- DONE + the EM45 set record (385/386) legitimately then. Day 3 has no
-- photoshoot; its record needs no guarding.
local SHOOT_STARTED_FLAG = {
    ["Cut from the Same Cloth"] = 385,
    ["Photo Challenge"]         = 386,
}

local function maintain_record(name)
    local shoot_flag = SHOOT_STARTED_FLAG[name]
    if not shoot_flag then return end
    if flag_check(shoot_flag) == true then return end  -- shoot running: hands off
    -- The enemy save records need the same standing treatment as the NPC
    -- record: the PREVIOUS day's EM45 shoot actor retires around the arm
    -- and can serialize its end position into the live records AFTER the
    -- arm's one-shot clear -- the talk-load then places Kent off it
    -- (downstairs, 3->2->1 regression 2026-08-22). Idempotent: only
    -- touches records with the death bit or a non-zero position.
    clear_enemy_records()
    local mgr = npc_mgr:get()
    if not mgr then return end
    local list
    pcall(function() list = mgr:get_field("NpcInfoList") end)
    if not list then return end
    local n
    pcall(function() n = list:call("get_Count") end)
    for i = 0, (n or 0) - 1 do
        local dirty = false
        pcall(function()
            local info = list:call("get_Item", i)
            if info and Shared.to_int(info:get_field("<Name>k__BackingField")) == KENT_STYPE then
                local scs  = Shared.to_int(info:get_field("mScoopCheckState")) or 0
                local free = Shared.to_int(info:get_field("mFreeFlag")) or 0
                -- Poison = DONE, or the 0x200 post-shoot marker. Bit 0 is
                -- FF_2ND, Kent's LEGITIMATE day-2 mode -- stripping it made
                -- an armed day 2 play with day-1 dialogue and state
                -- (regression, 2026-08-22). Never touch it here.
                if scs == 2 or (free & ~1) ~= 0 then
                    info:set_field("mScoopCheckState", 0)
                    info:set_field("mScoopTimeOutFlag", 0)
                    info:set_field("mFreeFlag", free & 1)
                    info:set_field("mSituationNo", 0)
                    -- Restore the record position ONLY as part of a poison
                    -- scrub. The whole point of the guard is that a CLEAN
                    -- record SURVIVES the talk-load, and the load then
                    -- re-places Kent at the record's position -- i.e.
                    -- right where he was standing (near the player), the
                    -- behaviour verified as "worked perfectly". Actor
                    -- teleports and distance-based snapping were tried and
                    -- REVERTED: they yanked Kent around pre-emptively at
                    -- day start (2026-08-22).
                    ensure_start_sets()
                    local pos = spawn_pos[name]
                    if pos then
                        local v = Vector3f.new(pos.x, pos.y, pos.z)
                        local ok = pcall(function() info:call("setPos", v) end)
                        if not ok then info:set_field("mPos", v) end
                    end
                    dirty = true
                end
            end
        end)
        if dirty then
            M.log("record guard: scrubbed a finished-day footprint off Kent's record")
            return
        end
    end
end

-- HEAD's disable-active behavior for the armed day, verbatim: pin the
-- listed flags off each tick until the day completes. See
-- CLEAR_WHILE_ARMED for why this exists and why it must be continuous.
local clears_logged = {}
local pinned_day = nil
local function maintain_clears(name)
    local list = CLEAR_WHILE_ARMED[name]
    if not list then return end
    pinned_day = name
    for _, fid in ipairs(list) do
        if flag_check(fid) == true then
            flag_set(fid, false)
            if not clears_logged[fid] then
                clears_logged[fid] = true
                M.log(string.format(
                    "pinning day-1 residue flag %d off while '%s' runs",
                    fid, name))
            end
        end
    end
end

-- When the pinned day stops being the armed day (completed, or switched
-- away), the pinned flags must be RESTORED, not just released: the pins
-- hold 843/1224 off, which is precisely the state where scoop 32 is still
-- schedulable -- letting go without re-retiring re-fires the appear and
-- Kent respawns after the completion (HEAD's known day-2 bug, same root).
local function release_pins(name)
    pinned_day = nil
    clears_logged = {}
    if name ~= "Photo Challenge" then return end
    -- Re-retire day 1: FINISH + appear latch stop the scheduler.
    flag_set(843, true)
    flag_set(1224, true)
    -- If day 1 was genuinely completed, restore the rest of its footprint.
    local su = unlocker()
    if su then
        local ok, done = pcall(su.is_scoop_completed, DAYS[1])
        if ok and done == true then
            for _, fid in ipairs({ 385, 344, 342, 1277, 2541 }) do
                flag_set(fid, true)
            end
        end
    end
    M.log("released day-2 pins -- day 1 re-retired (843/1224 on)")
end

------------------------------------------------------------
-- Desired state
------------------------------------------------------------

--- Is the target day's handoff token (its box entry flag, set by the
--- previous day's completion cluster ~4s after the completion flag) on?
--- Day 1 has no predecessor and therefore no token (see has_handoff_token).
local function handoff_token_on(name)
    ensure_start_sets()
    if not has_handoff_token(name) then return false end
    local disp = disp_flags[name]
    return disp ~= nil and flag_check(disp) == true
end

--- Did a chain day complete since the last tick? arm_for_unlock runs
--- synchronously inside the completion callstack, so comparing against
--- last tick's snapshot detects "the handoff cluster is in flight RIGHT
--- NOW" -- the movement gate cannot (moved_at is stale by completion
--- after minutes of normal play).
local function fresh_completion()
    local su = unlocker()
    if not su then return false end
    for _, day in ipairs(DAYS) do
        local ok, done = pcall(su.is_scoop_completed, day)
        if ok and done == true and completed_snapshot[day] ~= true then
            return true
        end
    end
    return false
end

-- The received, uncompleted Kent day -- at most one exists (conflict group),
-- earliest day wins if state ever disagrees.
local function desired_day()
    local su = unlocker()
    if not su then return nil end
    for _, name in ipairs(DAYS) do
        local ok_r, received = pcall(su.has_received_scoop, name)
        local ok_c, completed = pcall(su.is_scoop_completed, name)
        if ok_r and ok_c and received == true and completed ~= true then
            return name
        end
    end
    return nil
end

-- Whether the armed day's start set is still fully on. Consulted ONLY
-- after a load edge (see on_frame): the engine legitimately CONSUMES parts
-- of the start set during play -- the meet-day-3 sequence retires one of
-- day 3's armed flags -- and re-arming on that mid-day made the wipe replay
-- the cutscene (measured). A save load, by contrast, passes through the
-- load screen (is_in_game false), so that edge is the only honest signal
-- that the flag array may have been restored out from under the arm.
-- Verified on VERIFY_STARTS only, never the full start set: aux flags
-- (box entries, appear inputs, STARTC9) are legitimately consumed by the
-- engine as the day progresses, and door transitions AND the day-3 meet
-- sequence's internal quick-load all pass through the load screen --
-- checking a consumed flag there falsely re-arms mid-day.
--- The player's world position, or nil if unreadable.
local function player_pos()
    local pm = pm_mgr:get()
    if not pm then return nil end
    local go = Shared.safe(function() return pm:call("get_CurrentPlayer") end)
    if not go then return nil end
    local tr = Shared.safe(function() return go:call("get_Transform") end)
    if not tr then return nil end
    return Shared.safe(function() return tr:call("get_Position") end)
end

--- True once the player has been moving under their own control for
--- MOVE_SETTLE seconds -- i.e. the completing day's cutscene is over.
--- Unreadable positions count as settled: never stall the arm on a bad read.
local function ceremony_settled()
    local now = os.clock()
    local p = player_pos()
    if not p then
        arm_blocked_since = nil
        return true
    end

    local moved = false
    if last_pos then
        local dx, dy, dz = p.x - last_pos.x, p.y - last_pos.y, p.z - last_pos.z
        moved = (dx * dx + dy * dy + dz * dz) > (MOVE_EPSILON * MOVE_EPSILON)
    end
    last_pos = { x = p.x, y = p.y, z = p.z }

    if moved and not moved_at then
        moved_at = now
        M.log("player moving -- arming in " .. tostring(ARM_DELAY) .. "s")
    end

    if moved_at and (now - moved_at) >= ARM_DELAY then
        arm_blocked_since = nil
        return true
    end

    -- A player who parks after the cutscene must not wedge the chain.
    arm_blocked_since = arm_blocked_since or now
    if now - arm_blocked_since >= MOVE_WAIT_CAP then
        M.log(string.format(
            "no sustained movement after %.0fs -- arming anyway", MOVE_WAIT_CAP))
        arm_blocked_since = nil
        return true
    end
    return false
end

local function still_armed(name)
    local starts = VERIFY_STARTS[name]
    if not starts then return true end
    for _, fid in ipairs(starts) do
        local v = flag_check(fid)
        if v == false then return false end
        -- nil (unreadable) counts as armed: do not churn on a bad read
    end
    return true
end

------------------------------------------------------------
-- Tick
------------------------------------------------------------

function M.on_frame()
    if not M:should_run() then return end
    if not Shared.is_in_game() then
        want_since = nil
        verify_pending = true
        return
    end
    if not scoop_sanity_on() then return end

    -- Refresh the completion snapshot FIRST: arm_for_unlock runs between
    -- ticks inside the completion callstack, and comparing against this
    -- (then one-tick-stale) snapshot is how it detects an in-flight
    -- handoff cluster.
    do
        local su = unlocker()
        if su then
            for _, day in ipairs(DAYS) do
                local ok, done = pcall(su.is_scoop_completed, day)
                if ok then completed_snapshot[day] = done == true end
            end
        end
    end

    -- Day 3's death records are cleared the moment its completion
    -- registers, NOT deferred to the next arm: the arm waits on the next
    -- day's unlock (conflict-deferral can hold that until an area event),
    -- and the records must be gone before the player re-enters Paradise.
    -- Re-asserted for a short window -- the death event can write the
    -- record again mid-cutscene after the first clear. The clear itself is
    -- idempotent (only touches records with mBeflag set).
    --
    -- ONLY when another Kent day is still to come. Day 3's set stays
    -- satisfied after the kill (1292 on, 1155 cleared by the box top-up),
    -- so the death record is the one thing keeping the engine from placing
    -- day-3 Kent again on the next Paradise entry. With no later day
    -- received, clearing it brought him back alive (field report
    -- 2026-09-09). A day that arrives later gets the clear from its own
    -- full arm.
    if not death_edge_at then
        local su = unlocker()
        if su then
            local ok, done = pcall(su.is_scoop_completed, DAYS[3])
            if ok and done == true then
                death_edge_at = os.clock()
                -- Stale-record removal only when we WATCHED day 3 complete
                -- as the armed day. After a script/save reload with day 3
                -- long completed, this check re-fires -- but flagging then
                -- would make a later 1<->2 arm remove a LIVE actor's
                -- record (the orphan bug).
                if armed_day == DAYS[3] then record_stale = true end
                death_clear_wanted = false
                for _, day in ipairs(DAYS) do
                    if day ~= DAYS[3] then
                        local ok_d, done_d = pcall(su.is_scoop_completed, day)
                        local ok_r, got = pcall(su.has_ap_received, day)
                        if not (ok_d and done_d == true) and ok_r and got == true then
                            death_clear_wanted = true
                        end
                    end
                end
                M.log(death_clear_wanted
                    and "day-3 completion detected -- clearing death records (another day is coming)"
                    or "day-3 completion detected -- death records kept (no other Kent day received)")
            end
        end
    end
    if death_edge_at and death_clear_wanted
        and os.clock() - death_edge_at < DEATH_CLEAR_WINDOW then
        clear_enemy_records()
    end

    local want = desired_day()

    -- Pin release: the moment the pinned day is no longer the desired day
    -- (it completed, or the chain moved on), restore the retired state.
    if pinned_day and want ~= pinned_day then
        release_pins(pinned_day)
    end

    -- Quiet state: no Kent day should run, so keep the engine's own
    -- schedule from starting one. Enforced (not one-shot): the engine sets
    -- 779 by itself at Kent's vanilla appearance time. Completed days are
    -- left alone -- START+FINISH both on is the retired state, and touching
    -- a completed day's records re-fires its completion ceremony.
    if not want then
        armed_day = nil
        want_seen = nil
        -- Retire a lingering Pride box: the engine's positional handoff
        -- sets 2509 at the previous day's completion, and with no next
        -- day desired nothing ever wipes it. 1155 is measured SAFE here
        -- (no Kent spawn is pending in the quiet state, and a later
        -- day-3 arm wipes 1155 and re-raises 2509 itself -- activation
        -- and completion verified unaffected).
        ensure_start_sets()
        do
            local su2 = unlocker()
            local pride_received = false
            if su2 then
                local ok, r = pcall(su2.has_received_scoop, DAYS[3])
                pride_received = ok and r == true
            end
            if not pride_received and flag_check(2509) == true
                and flag_check(1155) ~= true then
                flag_set(1155, true)
                M.log("quiet state: retired lingering Pride box via 1155")
            end
        end
        local su = unlocker()
        for day_name, starts in pairs(DAY_STARTS) do
            local done = false
            if su then
                local ok, v = pcall(su.is_scoop_completed, day_name)
                done = ok and v == true
            end
            if not done then
                for _, fid in ipairs(starts) do
                    if flag_check(fid) == true then
                        flag_set(fid, false)
                        M.log(string.format(
                            "suppressed vanilla Kent start flag %d", fid))
                    end
                end
            end
        end
        return
    end

    if want == armed_day then
        -- Mid-play, the armed state is TRUSTED -- the engine consumes armed
        -- flags as the day progresses and that must not look like an unwind.
        -- Only a load edge warrants one re-check.
        if not verify_pending then
            maintain_record(want)
            maintain_clears(want)
            -- Box top-up: a FULL arm wipes the day's box entry flag and
            -- only day 1/3 re-set their own (day 2's start set carries no
            -- entry flag), so an out-of-order day 2 ran boxless. Setting
            -- the entry AFTER the arm is settled is measured safe (box
            -- shows, spawn unaffected); the rising edge enqueues the
            -- display entry. Gentle-armed days already have the engine's
            -- token on, so this no-ops there. END (2542) is never touched.
            if not box_topped_up and armed_at
                and os.clock() - armed_at > 5.0 then
                box_topped_up = true
                ensure_start_sets()
                local disp = disp_flags[want]
                if disp and flag_check(disp) == false then
                    flag_set(disp, true)
                    M.log(string.format(
                        "box top-up: raised entry flag %d for '%s'", disp, want))
                end
                -- And clear a lingering box END once (vanilla 1->2: the
                -- day-2 box was created by the handoff edge and then ended
                -- by a stale 2542; a ONE-SHOT clear brought it back with
                -- spawn and completion unaffected -- measured. One-shot,
                -- so the engine's own later end is never fought (the
                -- Scoop Chance Lost trap was the CONTINUOUS hold).
                local dend = disp_end_flags[want]
                if dend and flag_check(dend) == true then
                    flag_set(dend, false)
                    M.log(string.format(
                        "box top-up: cleared lingering END flag %d for '%s'",
                        dend, want))
                end
            end
            want_seen = want
            return
        end
        if still_armed(want) then
            verify_pending = false
            maintain_record(want)
            maintain_clears(want)
            want_seen = want
            return
        end
        M.log("armed state unwound by a load -- re-arming")
    end

    -- Arm wherever the player stands, a short debounce after the desired
    -- day CHANGED -- so the completing day's ceremony writes finish first.
    -- The old outside-Paradise guard existed to dodge the ceremony re-fire,
    -- but the footprint model already prevents that (completed days'
    -- records are never touched), and the guard itself broke real flows:
    -- vanilla 2->3 needs NO area change (psycho Kent appears in place), and
    -- a quick dip out of 512 and back beat the settle timer, so the player
    -- re-entered on un-armed state (measured: broken spawn).
    --
    -- A re-arm with an UNCHANGED desired day (save load unwound the flags)
    -- skips the debounce -- the ceremony is long over.
    if want ~= want_seen then
        want_seen = want
        want_since = os.clock()
        return
    end
    if want_since and os.clock() - want_since < SETTLE_SECONDS then return end

    -- Handoff wait: while the completing day's cluster is in flight, arm
    -- the moment the engine's token appears (gentle path inside apply_day);
    -- if the window lapses with no token, this is an out-of-order
    -- transition and the full wipe proceeds below.
    local token = handoff_token_on(want)
    if handoff_deadline then
        if os.clock() < handoff_deadline and not token then return end
        handoff_deadline = nil
    end
    if not token and not ceremony_settled() then return end

    if apply_day(want) then
        armed_day = want
        armed_at = os.clock()
        box_topped_up = false
        verify_pending = false
        -- Fresh wait bookkeeping for the next transition.
        arm_blocked_since = nil
        moved_at = nil
        last_pos = nil
    end
end

------------------------------------------------------------
-- Unlock-time arming (called by ScoopUnlocker)
------------------------------------------------------------

-- ScoopUnlocker delegates chain-managed unlocks here instead of writing
-- the scoop's flags itself: two writers armed the day twice -- the unlock
-- write started it instantly, then the debounced tick arm wiped the
-- running sequence and replayed the meet cutscene. This applies the full
-- recipe synchronously at unlock, and the tick loop then sees the day as
-- already armed. Returns true on success (ScoopUnlocker logs the mode).
--- Arm at unlock, but ONLY if the engine is between events. The conflict
--- group advances the moment a day completes, so the next day's unlock lands
--- inside the completing day's cutscene -- and this path bypassed on_frame's
--- gate entirely, which is why day 3 armed the instant day 2's cutscene
--- started and the scheduler answered with 1277 ("Scoop Chance Lost").
--- Returning false is not a failure: ScoopUnlocker logs "KentChain will arm
--- on tick" and on_frame arms it once the ceremony has settled.
function M.arm_for_unlock(name)
    -- A sibling completing THIS instant means the engine's handoff cluster
    -- is in flight (the 2508/2509 token lands ~4s after the completion
    -- flag). The movement gate cannot see this -- moved_at is stale after
    -- minutes of play -- so it is detected against last tick's completion
    -- snapshot, and the arm waits for the token (gentle) or the window.
    if fresh_completion() and not handoff_token_on(name) then
        handoff_deadline = os.clock() + HANDOFF_WAIT
        want_seen = name
        want_since = os.clock()
        M.log(string.format(
            "deferring arm of '%s' -- completion handoff in flight", name))
        return false
    end
    if not ceremony_settled() then
        M.log(string.format(
            "unlock of '%s' arrived mid-event -- deferring the arm to the tick",
            tostring(name)))
        return false
    end
    if not apply_day(name) then return false end
    armed_day = name
    armed_at = os.clock()
    box_topped_up = false
    want_seen = name
    want_since = os.clock()
    verify_pending = false
    return true
end

------------------------------------------------------------
-- Console
------------------------------------------------------------

--- Tune or disable the arm gate at runtime, so "is the gate causing this?"
--- is one command instead of a redeploy.
---   drap_kent_gate(0)   arm immediately -- the pre-gate behaviour
---   drap_kent_gate(6)   restore the default
---   drap_kent_gate()    report the current value
_G.drap_kent_gate = function(seconds)
    if seconds ~= nil then
        ARM_DELAY = tonumber(seconds) or ARM_DELAY
        moved_at = nil
        arm_blocked_since = nil
        last_pos = nil
    end
    M.log(string.format("arm gate: %.1fs after first movement%s",
        ARM_DELAY, ARM_DELAY <= 0 and "  (DISABLED -- arms immediately)" or ""))
end

_G.drap_kent_chain = function()
    local su = unlocker()
    print("[KentChain] scoop_sanity=" .. tostring(scoop_sanity_on())
        .. " armed=" .. tostring(armed_day)
        .. " desired=" .. tostring(desired_day())
        .. " area=" .. tostring(current_area()))
    if su then
        for i, name in ipairs(DAYS) do
            local r = pcall(su.has_received_scoop, name) and su.has_received_scoop(name)
            local c = pcall(su.is_scoop_completed, name) and su.is_scoop_completed(name)
            local a = su.is_scoop_active and select(2, pcall(su.is_scoop_active, name))
            print(string.format("[KentChain]   day %d %-28s received=%s completed=%s flags_on=%s",
                i, name, tostring(r), tostring(c), tostring(a)))
        end
    end
end

return M
