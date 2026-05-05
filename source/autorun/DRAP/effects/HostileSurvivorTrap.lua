-- DRAP/effects/HostileSurvivorTrap.lua
-- Spawns hostile NPCs at the player's location as an AP trap item.
-- Two trap types: Hostile NPC Trap (cutscene NPCs) and Special Forces Trap
-- (the soldier tier). See docs/reframework/features/hostile_survivor_trap.md
-- for the full mechanism, validation rules, HP-scaling, and console commands.

local M = {}

local Shared = require("DRAP/Shared")
local log = Shared.create_logger("HostileSurvivorTrap")
M.log = log

------------------------------------------------------------
-- Constants
------------------------------------------------------------

local NPC_TYPE = "app.solid.gamemastering.NpcManager"
local PM_TYPE  = "app.solid.PlayerManager"
local AM_TYPE  = "app.solid.gamemastering.AreaManager"

local LIVE_STATE_RAGE   = 12
local LIVE_STATE_ZOMBIE = 10   -- alternate hostile state; behaves differently per-NPC
local SPAWN_OFFSET_X = 1.5

-- Filter for _G.drap_trap_zombie's target picker. See docs § "LIVE_STATE
-- testing". Special Force silently no-ops (or hangs) under LIVE_STATE_ZOMBIE.
local NO_ZOMBIE_STYPES = {
    [59] = "Special Force",
}

local _notify_trap = Shared.lazy_notify_trap()

local SANCTUARY_SCENES = {
    SCN_s136 = true,   -- Security Room (proper)
    SCN_s138 = true,   -- Security Room (zombie hallway variant)
    SCN_s401 = true,   -- Carlito's Hideout
}

-- Standard "Hostile NPC Trap" pool: cutscene-only NPCs. See docs §
-- "Trap target pool". Empirical exclusions: stypes 82 (James Ramsey) and
-- 83 (Sid) refuse to spawn; stype 59 (Special Force) is split into its
-- own trap below.
local TRAP_POOL = {
    [73] = "Ryan LaRosa",
    [74] = "Chris Hines",
    [75] = "Todd Mendel",
    [76] = "Brian Reynolds",
    [77] = "Dana Simms",
    [78] = "Verlene Willis",
    [79] = "Mark Quemada",
    [80] = "Kathy Peterson",
    [81] = "Alan Peterson",
    [84] = "Freddie May",
}

-- Special Forces Trap pool. Single-stype (NpcBaseInfo is keyed per-stype),
-- so each fire spawns at most one. See docs § "Special Forces Trap".
local SPECIAL_FORCES_TRAP_POOL = {
    [59] = "Special Force",
}

-- Defense in depth: stypes that must NEVER be spawned by the trap. See
-- docs § "Defense-in-depth: FORBIDDEN_STYPES validation".
local FORBIDDEN_STYPES = {
    [0]  = "Burt Thompson (npc00) -- regular survivor, Barricade Pair scoop",
}

-- Validate pools at module load: forbid overlap with FORBIDDEN_STYPES and
-- enforce the safe stype range (>= 59). Logs an ERROR + drops the entry.
do
    local function validate(pool, label)
        for stype, name in pairs(pool) do
            if FORBIDDEN_STYPES[stype] then
                log(string.format("ERROR: %s[%d] (%s) overlaps FORBIDDEN_STYPES (%s) -- removing",
                    label, stype, name, FORBIDDEN_STYPES[stype]))
                pool[stype] = nil
            elseif stype < 59 then
                log(string.format("ERROR: %s[%d] (%s) is in the regular-survivor range (<59) -- removing",
                    label, stype, name))
                pool[stype] = nil
            end
        end
    end
    validate(TRAP_POOL, "TRAP_POOL")
    validate(SPECIAL_FORCES_TRAP_POOL, "SPECIAL_FORCES_TRAP_POOL")
end

-- Defer/retry interval for queued traps.
local DEFER_INTERVAL_S = 5.0

-- Drop queued traps that have been waiting longer than this.
local DEFER_TIMEOUT_S = 600.0   -- 10 minutes

-- Each trap fires random[min,max] NPCs (capped by available stypes).
-- Driven by YAML via M.set_spawn_count_range.
local spawn_count_min = 1
local spawn_count_max = 3

------------------------------------------------------------
-- Module state
------------------------------------------------------------

-- Per-trap-type pending queues. See docs § "Per-trap-type pending queue".
local pending = {
    hostile        = { count = 0, first_at = nil },
    special_forces = { count = 0, first_at = nil },
}
local last_check_time = 0

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local safe = Shared.safe

local function get_npc_mgr()  return sdk.get_managed_singleton(NPC_TYPE) end
local function get_player_mgr() return sdk.get_managed_singleton(PM_TYPE) end
local function get_area_mgr()   return sdk.get_managed_singleton(AM_TYPE) end

-- True if the player is in a scene where attacking is disabled (sanctuary).
local function in_sanctuary()
    local am = get_area_mgr()
    if not am then return false end
    local scene
    pcall(function() scene = am:get_field("CurrentLevelPath") end)
    scene = tostring(scene or "")
    return SANCTUARY_SCENES[scene] == true
end

local function get_player_pos()
    local pm = get_player_mgr()
    if not pm then return nil end
    local cond
    pcall(function() cond = pm:call("get_CurrentPlayerCondition") end)
    if not cond then return nil end
    local pos
    pcall(function() pos = cond:get_field("LastPlayerPos") end)
    if not pos then return nil end
    local x, y, z
    pcall(function() x = pos.x; y = pos.y; z = pos.z end)
    if not (x and y and z) then return nil end
    return x, y, z
end

local function stype_is_active(stype)
    local mgr = get_npc_mgr()
    if not mgr then return false end
    local info = safe(function() return mgr:call("searchInformation", stype) end)
    if not info then return false end
    local is_dead = safe(function() return info:call("isDead") end)
    return not is_dead
end

-- Pick up to `count` distinct trap targets from `pool` (each different
-- stype). May return fewer than `count` if the pool is depleted.
local function pick_trap_targets_from(pool, count)
    local candidates = {}
    for stype, _ in pairs(pool) do
        if not stype_is_active(stype) then
            table.insert(candidates, stype)
        end
    end
    -- Shuffle in place (Fisher-Yates)
    for i = #candidates, 2, -1 do
        local j = math.random(i)
        candidates[i], candidates[j] = candidates[j], candidates[i]
    end
    local out = {}
    for i = 1, math.min(count, #candidates) do
        out[i] = candidates[i]
    end
    return out
end

-- Backward-compat wrapper: defaults to the standard hostile-survivor pool.
local function pick_trap_targets(count)
    return pick_trap_targets_from(TRAP_POOL, count)
end

-- Returns true, nil if conditions allow the trap to fire right now.
-- Returns false, "reason" otherwise (logged once per attempt).
local function can_fire_now()
    local pm = get_player_mgr()
    if not pm then return false, "PlayerManager not live" end
    local player
    pcall(function() player = pm:call("get_CurrentPlayer") end)
    if not player then return false, "player not in-game" end

    if in_sanctuary() then return false, "in sanctuary scene" end

    -- AP gate (only ScoopSanity enforces; standard mode just needs AP connection
    -- which is implicit when an item is being received)
    local su = _G.AP and _G.AP.ScoopUnlocker
    if su and su.is_scoop_sanity_enabled and su.is_scoop_sanity_enabled() then
        if not (su.is_ap_activated and su.is_ap_activated()) then
            return false, "ScoopSanity awaiting Jessie"
        end
    end

    return true
end

------------------------------------------------------------
-- Spawn machinery (lifted from drap_npc_probe.lua)
------------------------------------------------------------

local function clear_dead_baseinfo(stype)
    local mgr = get_npc_mgr()
    if not mgr then return end
    local info = safe(function() return mgr:call("searchInformation", stype) end)
    if not info then return end
    local is_dead = safe(function() return info:call("isDead") end)
    if is_dead then
        pcall(function() mgr:call("removeInformation", stype) end)
    end
end

local function reset_baseinfo_health(info)
    pcall(function() info:call("setVitalFull") end)
    local vmax = safe(function() return info:get_field("mVitalMax") end)
    if vmax then pcall(function() info:set_field("mVitalNew", vmax) end) end
    -- HitPointController on the GameObject is the actual damage tracker.
    local owner = safe(function() return info:get_field("Owner") end)
    if not owner then return end
    local go = safe(function() return owner:call("get_GameObject") end)
    if not go then return end
    local comps = safe(function() return go:call("get_Components") end)
    if not comps then return end
    local n = tonumber(safe(function() return comps:call("get_Count") end)) or 0
    for i = 0, n - 1 do
        local c = safe(function() return comps:call("get_Item", i) end)
        if c then
            local td = c:get_type_definition()
            local cname = td and td:get_full_name() or ""
            if cname:find("HitPointController") then
                pcall(function() c:call("fullRecover") end)
                return
            end
        end
    end
end

-- live_state defaults to LIVE_STATE_RAGE; hp_mult defaults to 1.0 (vanilla).
-- The HP-multiplier write happens AFTER reset_baseinfo_health so it
-- overrides the vanilla restore. See docs § "HP scaling".
local function setup_spawned(stype, live_state, hp_mult)
    live_state = live_state or LIVE_STATE_RAGE
    hp_mult = tonumber(hp_mult) or 1.0

    local mgr = get_npc_mgr()
    if not mgr then return end
    local info = safe(function() return mgr:call("searchInformation", stype) end)
    if not info then return end

    -- Set area to player's current area
    local am = get_area_mgr()
    if am then
        local area_no = safe(function() return am:call("getAreaIndex") end)
        if area_no then pcall(function() info:set_field("mAreaNo", area_no) end) end
    end
    pcall(function() info:set_field("mCarryOverFlag", true) end)

    -- Position at player + offset
    local px, py, pz = get_player_pos()
    if px and Vector3f and Vector3f.new then
        local ok, v = pcall(Vector3f.new, px + SPAWN_OFFSET_X, py, pz)
        if ok then
            local set_ok = pcall(function() info:call("setPos", v) end)
            if not set_ok then pcall(function() info:set_field("mPos", v) end) end
        end
    end

    reset_baseinfo_health(info)

    -- Apply HP multiplier (after reset_baseinfo_health so we override its
    -- vanilla-restoring writes). 1.0 = no change.
    if hp_mult ~= 1.0 then
        local vmax = safe(function() return info:get_field("mVitalMax") end)
        if vmax then
            local new_max = math.floor(tonumber(vmax) * hp_mult + 0.5)
            pcall(function() info:set_field("mVitalMax", new_max) end)
            pcall(function() info:set_field("mVitalNew", new_max) end)
        end
    end

    pcall(function() info:call("setLiveState", live_state) end)
end

local function fire_spawn(stype, live_state, hp_mult)
    live_state = live_state or LIVE_STATE_RAGE
    hp_mult = tonumber(hp_mult) or 1.0

    local mgr = get_npc_mgr()
    if not mgr then return false end

    clear_dead_baseinfo(stype)

    -- Build pos + identity rotation. Quaternion order is (w, x, y, z).
    local px, py, pz = get_player_pos()
    if not px then return false end
    local pos, rot
    if Vector3f and Vector3f.new then
        local ok, v = pcall(Vector3f.new, px + SPAWN_OFFSET_X, py, pz)
        if ok then pos = v end
    end
    if Quaternion and Quaternion.new then
        local ok, q = pcall(Quaternion.new, 1, 0, 0, 0)
        if ok then rot = q end
    end
    if not pos or not rot then return false end

    pcall(function()
        mgr:call("spawnNPC(app.solid.SurvivorDefine.SurvivorType, " ..
                 "via.vec3, via.Quaternion, " ..
                 "solid.MT2RE.cUnitPropertyContainer, " ..
                 "System.Action`1<via.GameObject>)",
                 stype, pos, rot, nil, nil)
    end)

    -- Poll for the BaseInfo to become non-dead, then promote to RAGE.
    local started_at = os.clock()
    local fired = false
    re.on_frame(function()
        if fired then return end
        local elapsed = os.clock() - started_at
        if elapsed < 1.0 then return end          -- wait at least 1s for engine pipeline
        if elapsed > 30.0 then                     -- give up after 30s
            fired = true
            log("Gave up waiting for BaseInfo for stype=" .. stype)
            return
        end
        local info = safe(function() return mgr:call("searchInformation", stype) end)
        if not info then return end
        local still_dead = safe(function() return info:call("isDead") end)
        if still_dead then return end
        fired = true
        setup_spawned(stype, live_state, hp_mult)
        local pool_name = TRAP_POOL[stype] or SPECIAL_FORCES_TRAP_POOL[stype] or "?"
        log(string.format("Spawned hostile %s (stype=%d, live_state=%d, hp_mult=%.2f) at player",
            pool_name, stype, live_state, hp_mult))
    end)

    return true
end

------------------------------------------------------------
-- Per-frame deferred-firing loop
------------------------------------------------------------

-- Per-pool deferred-firing helper. Drains one queued trap, or drops the
-- whole queue once it's been waiting longer than DEFER_TIMEOUT_S.
local function process_pending(pool, label, state)
    if state.count <= 0 then return end
    local now = os.clock()

    if state.first_at and (now - state.first_at) > DEFER_TIMEOUT_S then
        log(string.format("Dropping %d queued %s -- exceeded %ds timeout",
            state.count, label, DEFER_TIMEOUT_S))
        state.count = 0
        state.first_at = nil
        return
    end

    local ok = can_fire_now()
    if not ok then return end   -- still gated, keep waiting

    local count = math.random(spawn_count_min, spawn_count_max)
    local targets = pick_trap_targets_from(pool, count)
    if #targets == 0 then return end   -- no safe targets, keep waiting

    log(string.format("Deferred %s firing %d hostile(s)", label, #targets))
    _notify_trap(label,
        string.format("%d hostile attacker%s spawned!",
            #targets, #targets == 1 and "" or "s"))
    for _, stype in ipairs(targets) do fire_spawn(stype) end
    state.count = state.count - 1
    if state.count <= 0 then state.first_at = nil end
end

-- Deferred-firing loop registered at module load. Registering re.on_frame
-- from within another on_frame disrupts REFramework's iteration.
re.on_frame(function()
    if pending.hostile.count <= 0 and pending.special_forces.count <= 0 then return end
    local now = os.clock()
    if now - last_check_time < DEFER_INTERVAL_S then return end
    last_check_time = now

    process_pending(TRAP_POOL,                "Hostile NPC Trap",    pending.hostile)
    process_pending(SPECIAL_FORCES_TRAP_POOL, "Special Forces Trap", pending.special_forces)
end)

------------------------------------------------------------
-- Public API
------------------------------------------------------------

-- Generic trap-fire path: fires immediately, or queues on `state` if
-- conditions block.
local function fire_trap_impl(pool, label, state)
    local ok, reason = can_fire_now()
    if not ok then
        state.count = state.count + 1
        state.first_at = state.first_at or os.clock()
        log(string.format("%s deferred (%s) -- queued (count=%d)",
            label, tostring(reason), state.count))
        return
    end

    local count = math.random(spawn_count_min, spawn_count_max)
    local targets = pick_trap_targets_from(pool, count)
    if #targets == 0 then
        -- All pool stypes already alive -- defer until at least one frees up
        state.count = state.count + 1
        state.first_at = state.first_at or os.clock()
        log(string.format("%s: pool stypes all alive -- queued for retry", label))
        return
    end

    log(string.format("%s firing %d hostile(s)", label, #targets))
    _notify_trap(label,
        string.format("%d hostile attacker%s spawned!",
            #targets, #targets == 1 and "" or "s"))
    for _, stype in ipairs(targets) do
        fire_spawn(stype)
    end
end

-- Fire a Hostile NPC Trap (random[min,max] cutscene NPCs in RAGE).
function M.fire_trap()
    fire_trap_impl(TRAP_POOL, "Hostile NPC Trap", pending.hostile)
end

-- Fire a Special Forces Trap (single Special Force NPC in RAGE; the pool
-- is single-stype so count effectively caps at 1).
function M.fire_special_forces_trap()
    fire_trap_impl(SPECIAL_FORCES_TRAP_POOL, "Special Forces Trap", pending.special_forces)
end

-- Configure the spawn-count range (driven from YAML via AP slot data).
function M.set_spawn_count_range(min, max)
    min = tonumber(min) or 1
    max = tonumber(max) or min
    if max < min then max = min end
    spawn_count_min = math.max(1, min)
    spawn_count_max = math.max(spawn_count_min, max)
    log(string.format("Hostile NPC Trap spawn range: %d-%d",
        spawn_count_min, spawn_count_max))
end

function M.get_spawn_count_range()
    return spawn_count_min, spawn_count_max
end

-- Diagnostics / config
function M.get_pending_count()
    return pending.hostile.count + pending.special_forces.count
end

function M.clear_pending()
    pending.hostile.count           = 0
    pending.hostile.first_at         = nil
    pending.special_forces.count    = 0
    pending.special_forces.first_at  = nil
    log("Cleared pending trap queue")
end

function M.register()
    -- on_replay = "skip" -- don't re-spawn on save reload.
    local ItemEffects = require("DRAP/ItemEffects")
    ItemEffects.register("Hostile NPC Trap", {
        on_replay = "skip",
        apply = function(ctx) M.fire_trap() end,
    })
    ItemEffects.register("Special Forces Trap", {
        on_replay = "skip",
        apply = function(ctx) M.fire_special_forces_trap() end,
    })

    local hostile_n, sf_n = 0, 0
    for _ in pairs(TRAP_POOL)                do hostile_n = hostile_n + 1 end
    for _ in pairs(SPECIAL_FORCES_TRAP_POOL) do sf_n      = sf_n + 1 end
    log(string.format("HostileNpcTrap registered (2 items: hostile pool=%d, special_forces pool=%d)",
        hostile_n, sf_n))
end

-- Like pick_trap_targets but skips stypes that don't support
-- LIVE_STATE_ZOMBIE (NO_ZOMBIE_STYPES).
local function pick_zombie_targets(count)
    local candidates = {}
    for stype, _ in pairs(TRAP_POOL) do
        if not NO_ZOMBIE_STYPES[stype] and not stype_is_active(stype) then
            table.insert(candidates, stype)
        end
    end
    for i = #candidates, 2, -1 do
        local j = math.random(i)
        candidates[i], candidates[j] = candidates[j], candidates[i]
    end
    local out = {}
    for i = 1, math.min(count, #candidates) do
        out[i] = candidates[i]
    end
    return out
end

-- Console shortcuts for testing.
_G.drap_fire_hostile_trap = function() return M.fire_trap() end
_G.drap_fire_special_forces_trap = function() return M.fire_special_forces_trap() end

-- Manual zombie-trap fire (LIVE_STATE_ZOMBIE probe). See docs §
-- "LIVE_STATE testing".
-- Usage:
--   drap_trap_zombie()      -- fire with default random count
--   drap_trap_zombie(3)     -- fire with exactly 3 zombified NPCs
_G.drap_trap_zombie = function(count)
    local ok, reason = can_fire_now()
    if not ok then
        log("drap_trap_zombie: cannot fire now (" .. tostring(reason) .. ")")
        return
    end

    count = tonumber(count) or math.random(spawn_count_min, spawn_count_max)
    local targets = pick_zombie_targets(count)
    if #targets == 0 then
        log("drap_trap_zombie: no eligible targets " ..
            "(zombie-capable pool exhausted or all already alive)")
        return
    end

    log(string.format("Manual zombie trap firing %d zombified NPC(s)", #targets))
    _notify_trap("Hostile NPC Trap (Zombie)",
        string.format("%d zombified NPC%s spawned!",
            #targets, #targets == 1 and "" or "s"))
    for _, stype in ipairs(targets) do
        fire_spawn(stype, LIVE_STATE_ZOMBIE)
    end
end

-- Manual buffed-trap fire (HP-scaling probe). See docs § "HP scaling".
-- Usage:
--   drap_trap_buffed(2.0)        -- 2x HP, default random count
--   drap_trap_buffed(0.5, 3)     -- half HP, 3 attackers
--   drap_trap_buffed(5.0, 1)     -- 5x HP single tank for damage testing
_G.drap_trap_buffed = function(hp_mult, count)
    local ok, reason = can_fire_now()
    if not ok then
        log("drap_trap_buffed: cannot fire now (" .. tostring(reason) .. ")")
        return
    end

    hp_mult = tonumber(hp_mult) or 1.0
    count = tonumber(count) or math.random(spawn_count_min, spawn_count_max)
    local targets = pick_trap_targets_from(TRAP_POOL, count)
    if #targets == 0 then
        log("drap_trap_buffed: no eligible targets (pool exhausted)")
        return
    end

    log(string.format("Manual buffed trap firing %d NPC(s) at %.2fx HP",
        #targets, hp_mult))
    _notify_trap("Hostile NPC Trap (Buffed)",
        string.format("%d attacker%s @ %.1fx HP",
            #targets, #targets == 1 and "" or "s", hp_mult))
    for _, stype in ipairs(targets) do
        fire_spawn(stype, LIVE_STATE_RAGE, hp_mult)
    end
end

-- Attack-power probe: dumps the spawned NPC's components, filtered to
-- field names matching Attack/Power/Damage/Vital/Hit/Strength. NpcBaseInfo
-- only carries HP, so combat values live elsewhere (NpcAction, HitController,
-- NpcThink, etc.). Run after firing a trap.
-- Usage:
--   drap_npc_dump_components(73)  -- dump Ryan LaRosa's component fields
_G.drap_npc_dump_components = function(stype)
    stype = tonumber(stype)
    if not stype then
        log("drap_npc_dump_components: usage: drap_npc_dump_components(<stype>)")
        return
    end

    local mgr = get_npc_mgr()
    if not mgr then log("NpcManager unavailable"); return end
    local info = safe(function() return mgr:call("searchInformation", stype) end)
    if not info then log("No NpcBaseInfo for stype " .. stype); return end

    local owner = safe(function() return info:get_field("Owner") end)
    local go = owner and safe(function() return owner:call("get_GameObject") end)
    if not go then log("No GameObject for stype " .. stype); return end

    local comps = safe(function() return go:call("get_Components") end)
    local n = comps and tonumber(safe(function() return comps:call("get_Count") end)) or 0
    log(string.format("=== Components for stype=%d (count=%d) ===", stype, n))

    -- Components likely to carry combat/strength data. Print these in detail.
    local interesting = {
        ["app.solid.HitPointController"]            = true,
        ["app.solid.npc.NpcAction"]                 = true,
        ["app.solid.npc.NpcThink"]                  = true,
        ["app.solid.npc.NpcBasebehaviorMachine"]    = true,
        ["app.Collision.HitController"]             = true,
        ["app.solid.character.SolidModelAttribute"] = true,
    }

    for i = 0, n - 1 do
        local c = safe(function() return comps:call("get_Item", i) end)
        if c then
            local td = c:get_type_definition()
            local tname = td and td:get_full_name() or "?"
            if interesting[tname] then
                log(string.format("  [%d] %s -- fields:", i, tname))
                local fields = td and td:get_fields() or {}
                for _, f in ipairs(fields) do
                    local fname = safe(function() return f:get_name() end) or "?"
                    if fname:match("[Aa]ttack") or fname:match("[Pp]ower")
                       or fname:match("[Dd]amage") or fname:match("[Vv]ital")
                       or fname:match("[Hh]it") or fname:match("[Ss]trength") then
                        local val = safe(function() return f:get_data(c) end)
                        log(string.format("       %-40s = %s", fname, tostring(val)))
                    end
                end
            end
        end
    end
end

return M
