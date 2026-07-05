-- DRAP/effects/PlayerStats.lua
-- Skill grants + stat deltas as AP items. See docs/reframework/features/player_stats.md.
--
-- State model: granted-skills set + per-stat delta amounts. apply() recomputes
-- canonical state = baseline + deltas and writes it via PSM/HitPointController.
-- Re-applies on save load (notfiyDataRead), level-up (calcPlayerLevelUp), and
-- a 1Hz drift watchdog. Persistence: per-slot/seed JSON.

local M = {}

local Shared = require("DRAP/Shared")
local Ledger = require("DRAP/LocationLedger")
local log = Shared.create_logger("PlayerStats")

------------------------------------------------------------
-- Baseline values (Frank at L1, captured from PlayerLvUpUserData)
------------------------------------------------------------

local BASELINE = {
    hp_max       = 4000,
    attack_pct   = 100,
    throw_power  = 100,
    run_level    = 1,
    item_buff    = 4,
    speed_mul    = 1.0,
}

-- Vanilla LevelSpeedMax baseline at speed_mul=1.0
local SPEED_TABLE_BASE = { 1.2, 1.3, 1.4 }

------------------------------------------------------------
-- Skill bit ↔ name mapping (in-game display names)
------------------------------------------------------------

local SKILL_BY_NAME = {
    ["Jump Kick"]        = 0,
    ["Zombie Ride"]      = 1,
    ["Kick Back"]        = 2,
    ["Power Push"]       = 3,
    ["Judo Throw"]       = 4,
    ["Knee Drop"]        = 5,
    ["Lift Up"]          = 6,
    ["Wall Kick"]        = 7,
    ["Face Crusher"]     = 8,
    ["Football Tackle"]  = 9,
    ["Giant Swing"]      = 10,
    ["Hammer Throw"]     = 11,
    ["Neck Twist"]       = 12,
    ["Roundhouse Kick"]  = 13,
    ["Disembowel"]       = 14,
    ["Somersault Kick"]  = 15,
    ["Flying Dodge"]     = 16,
    ["Double Lariat"]    = 17,
    ["Karate Chop"]      = 18,
    ["Zombie Walk"]      = 19,
    ["Suplex"]           = 20,
}

-- Stat-item name -> (delta-key, magnitude)
local STAT_DELTA_BY_NAME = {
    ["Progressive Health Upgrade"]    = { key = "hp_max",      mag = 1000 },
    ["Progressive Attack Upgrade"]    = { key = "attack_pct",  mag = 25 },
    ["Progressive Throw Upgrade"]     = { key = "throw_power", mag = 25 },
    ["Progressive Item Slot Upgrade"] = { key = "item_buff",   mag = 1 },
    ["Progressive Run Level Upgrade"] = { key = "run_level",   mag = 1 },
    ["Progressive Speed Upgrade"]     = { key = "speed_mul",   mag = 0.05 },
}

------------------------------------------------------------
-- Module state
------------------------------------------------------------

-- Keyed by skill name to dodge a Lua VM "invalid key to 'next'" issue with
-- integer-key 0 in _G-stored tables. See docs/.../player_stats.md.
local granted_skills = {}  -- { [skill_name] = true }
local stat_deltas = {
    hp_max = 0, attack_pct = 0, throw_power = 0,
    run_level = 0, item_buff = 0, speed_mul = 0,
}

local progression_mode = "replace"   -- "vanilla_only" | "replace" | "extra_buffs_only"
local save_filename = nil
local hooks_installed = false

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function _psm() return sdk.get_managed_singleton("app.solid.PlayerStatusManager") end

local function _hpc()
    local psm = _psm()
    if not psm then return nil end
    local hpc
    pcall(function() hpc = psm:call("get_PlayerVitalController") end)
    return hpc
end

local function _player_condition()
    local pm = sdk.get_managed_singleton("app.solid.PlayerManager")
    if not pm then return nil end
    local cond
    pcall(function() cond = pm:call("get_CurrentPlayerCondition") end)
    return cond
end

local function _set_speed_table(values)
    local cond = _player_condition()
    if not cond then return false end
    local pvs
    pcall(function() pvs = cond:get_field("<PlayerSetting>k__BackingField") end)
    if not pvs then return false end
    local ms
    pcall(function() ms = pvs:get_field("MoveSetting") end)
    if not ms then return false end
    local list
    pcall(function() list = ms:get_field("LevelSpeedMax") end)
    if not list then return false end
    for i, v in ipairs(values) do
        pcall(function() list:call("set_Item", i - 1, v) end)
    end
    return true
end

------------------------------------------------------------
-- Canonical-state application
------------------------------------------------------------

-- Compute target value for each stat (baseline + delta).
local function _target_values()
    return {
        hp_max      = BASELINE.hp_max      + stat_deltas.hp_max,
        attack_pct  = BASELINE.attack_pct  + stat_deltas.attack_pct,
        throw_power = BASELINE.throw_power + stat_deltas.throw_power,
        run_level   = BASELINE.run_level   + stat_deltas.run_level,
        item_buff   = BASELINE.item_buff   + stat_deltas.item_buff,
        speed_mul   = BASELINE.speed_mul   + stat_deltas.speed_mul,
    }
end

-- Build the bitfield. Iterates SKILL_BY_NAME (string keys) rather than
-- granted_skills directly to dodge pairs() issues with integer-key 0.
local function _skill_bitfield()
    local bits = 0
    for name, idx in pairs(SKILL_BY_NAME) do
        if granted_skills[name] then bits = bits | (1 << idx) end
    end
    return bits
end

-- Write canonical DRAP state into the engine. Idempotent -- call any time.
function M.apply()
    if progression_mode == "vanilla_only" then return end

    local psm = _psm()
    local hpc = _hpc()
    if not psm then return end

    local t = _target_values()

    -- HP -- both PSM (save state) AND live HitPointController (UI/combat)
    if hpc then
        pcall(function() hpc:call("set_DefaultHitPoint", t.hp_max) end)
        pcall(function() hpc:call("set_CurrentHitPoint", t.hp_max) end)
    end
    pcall(function() psm:call("setPlayerVitalMax", t.hp_max) end)
    pcall(function() psm:set_field("_PlayerVitalNew", t.hp_max) end)

    -- Attack% + paired Buttobi (KB = 100 + 0.8 * (atk-100))
    local kb = math.floor(100 + 0.8 * (t.attack_pct - 100) + 0.5)
    pcall(function() psm:call("setPlayerAttackPercent", t.attack_pct) end)
    pcall(function() psm:call("setPlayerButtobiPercent", kb) end)

    -- Throw, run, item buff
    pcall(function() psm:call("setPlayerThrowPower", t.throw_power) end)
    pcall(function() psm:call("setPlayerRunLevel", t.run_level) end)
    pcall(function() psm:call("setPlayerItemBuffMax", t.item_buff) end)

    -- Speed multiplier scales the LevelSpeedMax table
    local scaled = {}
    for i, v in ipairs(SPEED_TABLE_BASE) do scaled[i] = v * t.speed_mul end
    _set_speed_table(scaled)

    -- Skill bitfield -- write to all three engine storage paths (field,
    -- setter method, property setter). Clear-then-write defends against
    -- any setter that's accidentally OR-style. See player_stats.md.
    local target_bits = _skill_bitfield()
    pcall(function() psm:call("setPlayerSkill", 0) end)
    pcall(function() psm:call("setPlayerSkill", target_bits) end)
    pcall(function() psm:call("set_PlayerSkillBits", 0) end)
    pcall(function() psm:call("set_PlayerSkillBits", target_bits) end)
    pcall(function() psm:set_field("PlayerSkill", target_bits) end)

    -- Refresh UI
    pcall(function() psm:set_field("<LevelUpdated>k__BackingField", true) end)
    pcall(function() psm:call("applyPlayerValue") end)
end

-- Reset to vanilla L1 baseline (clears all deltas + skills)
function M.reset_to_baseline()
    granted_skills = {}
    for k, _ in pairs(stat_deltas) do stat_deltas[k] = 0 end
    M.apply()
    log("Reset to L1 baseline")
end

------------------------------------------------------------
-- Public grant API
------------------------------------------------------------

-- Grant a skill by display name (e.g. "Jump Kick"). Idempotent.
function M.grant_skill(name)
    if SKILL_BY_NAME[name] == nil then
        log("Unknown skill: '" .. tostring(name) .. "'")
        return false
    end
    if granted_skills[name] then return false end
    granted_skills[name] = true
    M.apply()
    M.save_state()
    log("Granted skill: " .. name)
    return true
end

function M.revoke_skill(name)
    if SKILL_BY_NAME[name] == nil then return false end
    if not granted_skills[name] then return false end
    granted_skills[name] = nil
    M.apply()
    M.save_state()
    log("Revoked skill: " .. name)
    return true
end

-- Grant a stat upgrade by item name (e.g. "Progressive Health Upgrade").
-- Adds the magnitude to the appropriate delta and re-applies.
function M.grant_stat(name)
    local entry = STAT_DELTA_BY_NAME[name]
    if not entry then
        log("Unknown stat item: '" .. tostring(name) .. "'")
        return false
    end
    stat_deltas[entry.key] = (stat_deltas[entry.key] or 0) + entry.mag
    M.apply()
    M.save_state()
    log(string.format("Granted '%s' (+%s to %s, total delta=%s)",
        name, tostring(entry.mag), entry.key, tostring(stat_deltas[entry.key])))
    return true
end

-- Generic dispatcher -- accepts any AP item name we handle.
function M.grant_item(name)
    if SKILL_BY_NAME[name] ~= nil then return M.grant_skill(name) end
    if STAT_DELTA_BY_NAME[name] ~= nil then return M.grant_stat(name) end
    return false
end

function M.is_handled_item(name)
    return SKILL_BY_NAME[name] ~= nil or STAT_DELTA_BY_NAME[name] ~= nil
end

------------------------------------------------------------
-- Configuration
------------------------------------------------------------

function M.set_progression_mode(mode)
    if mode ~= "vanilla_only" and mode ~= "replace" and mode ~= "extra_buffs_only" then
        log("Invalid progression mode: " .. tostring(mode))
        return
    end
    progression_mode = mode
    log("Progression mode: " .. mode)
end

function M.get_progression_mode() return progression_mode end

------------------------------------------------------------
-- Persistence (per-slot/seed JSON, same pattern as ScoopUnlocker)
------------------------------------------------------------

function M.set_save_filename(slot, seed)
    -- Sanitized like the Bridge stores: unsanitized slot/seed with reserved
    -- characters made json.dump_file fail silently every save.
    save_filename = string.format(
        "./AP_DRDR_Scoops/DRAP_player_stats_%s_%s.json",
        Shared.sanitize_token(slot or "0"), Shared.sanitize_token(seed or "0"))
    log("Save filename: " .. save_filename)
end

function M.save_state()
    if not save_filename then return false end
    local skill_names = {}
    for name in pairs(granted_skills) do
        table.insert(skill_names, name)
    end
    table.sort(skill_names)   -- deterministic order on disk
    local data = {
        granted_skills = skill_names,
        stat_deltas    = stat_deltas,
        progression    = progression_mode,
    }
    -- Run ledger is the primary store; legacy standalone file is only a
    -- pre-connect fallback.
    if Ledger.is_init() then
        return Ledger.set_section("player_stats", data)
    end
    local ok = pcall(json.dump_file, save_filename, data)
    return ok
end

function M.load_save()
    -- Prefer the run ledger; fall back to (and migrate from) the legacy
    -- standalone file for seeds saved by older versions.
    local data = Ledger.is_init() and Ledger.get_section("player_stats") or nil
    local from_legacy = false
    if not data and save_filename then
        data = Shared.load_json_if_exists(save_filename)
        from_legacy = data ~= nil
    end
    if not data then
        log("No existing PlayerStats state (ledger or legacy file)")
        return false
    end
    if from_legacy and Ledger.is_init() then
        Ledger.set_section("player_stats", data)
        log("Migrated PlayerStats state into the run ledger")
    end

    -- Skills load idempotently (set semantics, replays are no-ops).
    local new_granted = {}
    local skill_count = 0
    if type(data.granted_skills) == "table" then
        for _, name in ipairs(data.granted_skills) do
            if SKILL_BY_NAME[name] ~= nil and not new_granted[name] then
                new_granted[name] = true
                skill_count = skill_count + 1
            end
        end
    end
    granted_skills = new_granted

    -- stat_deltas are NOT loaded -- the bridge replay rebuilds them fresh
    -- from AP-received items. Loading + replaying would double-count
    -- because the bridge resets RECEIVED_ITEMS on every connect.
    -- See docs/.../player_stats.md.
    for k, _ in pairs(stat_deltas) do stat_deltas[k] = 0 end

    if type(data.progression) == "string" then
        progression_mode = data.progression
    end

    log(string.format("Loaded state: %d skills granted (deltas reset for rebuild), mode=%s",
        skill_count, tostring(progression_mode)))
    M.apply()
    return true
end

------------------------------------------------------------
-- Hooks: re-apply DRAP state after engine writes
------------------------------------------------------------

local function _capture_engine_values()
    local psm = _psm()
    if not psm then return nil end
    local function fld(n)
        local v
        pcall(function() v = psm:get_field(n) end)
        return tonumber(v) or 0
    end
    return {
        hp_max     = fld("PlayerVitalMax"),
        attack_pct = fld("PlayerAttackPercent"),
        throw      = fld("PlayerThrowPower"),
        run_level  = fld("PlayerRunLevel"),
        item_buff  = fld("PlayerItemBuffMax"),
        skill_bits = fld("PlayerSkill"),
        level      = fld("PlayerLevel"),
    }
end

-- Diff and log any field whose value is different post-vanilla-write than the
-- DRAP canonical target. Each diff line: "Engine tried X, DRAP held Y".
local function _log_vanilla_overrides(pre, post)
    if not pre or not post then return end
    local t = _target_values()
    local target_skill_bits = _skill_bitfield()
    local lines = {}

    if post.level ~= pre.level then
        table.insert(lines, string.format("Level: %d -> %d (engine)", pre.level, post.level))
    end
    if post.hp_max ~= pre.hp_max and post.hp_max ~= t.hp_max then
        table.insert(lines, string.format(
            "  Engine set HP=%d, DRAP overriding to %d", post.hp_max, t.hp_max))
    end
    if post.attack_pct ~= pre.attack_pct and post.attack_pct ~= t.attack_pct then
        table.insert(lines, string.format(
            "  Engine set Attack=%d%%, DRAP overriding to %d%%",
            post.attack_pct, t.attack_pct))
    end
    if post.throw ~= pre.throw and post.throw ~= t.throw_power then
        table.insert(lines, string.format(
            "  Engine set Throw=%d, DRAP overriding to %d", post.throw, t.throw_power))
    end
    if post.run_level ~= pre.run_level and post.run_level ~= t.run_level then
        table.insert(lines, string.format(
            "  Engine set RunLevel=%d, DRAP overriding to %d",
            post.run_level, t.run_level))
    end
    if post.item_buff ~= pre.item_buff and post.item_buff ~= t.item_buff then
        table.insert(lines, string.format(
            "  Engine set ItemBuff=%d, DRAP overriding to %d",
            post.item_buff, t.item_buff))
    end
    if post.skill_bits ~= pre.skill_bits and post.skill_bits ~= target_skill_bits then
        table.insert(lines, string.format(
            "  Engine set Skills=0x%08X, DRAP overriding to 0x%08X",
            post.skill_bits, target_skill_bits))
    end
    if #lines > 0 then
        log("--- LEVEL-UP DETECTED (replace mode) ---")
        for _, ln in ipairs(lines) do log(ln) end
    end
end

local function _install_hooks()
    if hooks_installed then return end
    local td = sdk.find_type_definition("app.solid.PlayerStatusManager")
    if not td then return end

    -- Save load -> re-apply DRAP state
    local m_read = td:get_method("notfiyDataRead")
    if m_read then
        sdk.hook(m_read,
            function() end,
            function(retval)
                log("Save load detected -- reapplying DRAP state")
                M.apply()
                return retval
            end)
    end

    -- Level-up complete -> diff engine writes vs DRAP target, log overrides,
    -- re-apply. Pre-snapshot lets us show what the engine tried to write.
    local m_lvup = td:get_method("calcPlayerLevelUp")
    if m_lvup then
        local pre_snapshot = nil
        sdk.hook(m_lvup,
            function(args)
                if progression_mode == "replace" then
                    pre_snapshot = _capture_engine_values()
                end
            end,
            function(retval)
                if progression_mode == "replace" then
                    local post = _capture_engine_values()
                    _log_vanilla_overrides(pre_snapshot, post)
                    M.apply()
                end
                return retval
            end)
    end

    hooks_installed = true
end

------------------------------------------------------------
-- Skill-bitfield watchdog
------------------------------------------------------------
-- 1Hz drift watcher: re-asserts the bitfield if the engine writes
-- PlayerSkill outside our hooks (area transitions, internal migrations).
-- Disabled in vanilla_only mode.

local _watchdog_installed = false
local _last_logged_drift = nil

local function _install_skill_watchdog()
    if _watchdog_installed then return end
    _watchdog_installed = true
    local last_check = 0
    re.on_frame(function()
        if progression_mode == "vanilla_only" then return end
        local now = os.clock()
        if now - last_check < 1.0 then return end
        last_check = now

        local psm = _psm()
        if not psm then return end
        local cur
        pcall(function() cur = psm:get_field("PlayerSkill") end)
        cur = tonumber(cur)
        if cur == nil then return end
        local target = _skill_bitfield()
        if cur == target then return end

        local key = string.format("%d:%d", cur, target)
        if key ~= _last_logged_drift then
            _last_logged_drift = key
            log(string.format(
                "Watchdog: PlayerSkill drift -- engine=0x%08X, DRAP target=0x%08X. Re-applying.",
                cur, target))
        end
        M.apply()
    end)
end

------------------------------------------------------------
-- Diagnostics
------------------------------------------------------------

function M.get_state_summary()
    local skill_count = 0
    for _ in pairs(granted_skills) do skill_count = skill_count + 1 end
    return {
        skills_granted = skill_count,
        stat_deltas    = stat_deltas,
        progression    = progression_mode,
    }
end

function M.print_state()
    local s = M.get_state_summary()
    log(string.format("Skills granted: %d/21", s.skills_granted))
    log(string.format("HP delta: +%d (max: %d)",
        s.stat_deltas.hp_max, BASELINE.hp_max + s.stat_deltas.hp_max))
    log(string.format("Attack delta: +%d%% (total: %d%%)",
        s.stat_deltas.attack_pct, BASELINE.attack_pct + s.stat_deltas.attack_pct))
    log(string.format("Throw delta: +%d (total: %d)",
        s.stat_deltas.throw_power, BASELINE.throw_power + s.stat_deltas.throw_power))
    log(string.format("Run level: %d (max %d)",
        BASELINE.run_level + s.stat_deltas.run_level, 3))
    log(string.format("Item buff: %d (max 15)",
        BASELINE.item_buff + s.stat_deltas.item_buff))
    log(string.format("Speed multiplier: %.2fx",
        BASELINE.speed_mul + s.stat_deltas.speed_mul))
    log("Progression mode: " .. s.progression)
end

-- Rebuild stat deltas from the bridge's received items, then apply.
-- Called from main's try_reapply_if_ready after game entry. Skills load
-- from JSON via load_save() and aren't touched here -- on_replay="skip"
-- prevents grant_stat from running during the bridge's replay, and the
-- bridge resets RECEIVED_ITEMS on every connect, so stats need rebuild.
function M.reapply()
    if not _G.AP or not _G.AP.AP_BRIDGE
            or type(_G.AP.AP_BRIDGE.get_all_received_items) ~= "function" then
        return false
    end

    -- Reset deltas so we don't double-count items already in the table.
    for k, _ in pairs(stat_deltas) do stat_deltas[k] = 0 end

    local items = _G.AP.AP_BRIDGE.get_all_received_items() or {}
    local stat_grants = 0
    for _, entry in ipairs(items) do
        local name = entry and entry.item_name
        if name then
            local stat_entry = STAT_DELTA_BY_NAME[name]
            if stat_entry then
                stat_deltas[stat_entry.key] = stat_deltas[stat_entry.key] + stat_entry.mag
                stat_grants = stat_grants + 1
            end
        end
    end
    M.apply()
    if stat_grants > 0 then
        log(string.format("Reapplied %d stat upgrades from received items", stat_grants))
    end
    return true
end

-- Recovery: zero state, walk AP-received items, re-grant each once. Use if
-- stat_deltas got corrupted by an older version's doubling-on-reconnect bug.
function M.rebuild_from_received_items()
    granted_skills = {}
    for k, _ in pairs(stat_deltas) do stat_deltas[k] = 0 end

    if not _G.AP or not _G.AP.AP_BRIDGE
            or type(_G.AP.AP_BRIDGE.get_all_received_items) ~= "function" then
        log("rebuild: AP_BRIDGE.get_all_received_items unavailable")
        return false
    end
    local items = _G.AP.AP_BRIDGE.get_all_received_items() or {}

    local skill_grants, stat_grants = 0, 0
    for _, entry in ipairs(items) do
        local name = entry and entry.item_name
        if name then
            if SKILL_BY_NAME[name] ~= nil then
                if M.grant_skill(name) then skill_grants = skill_grants + 1 end
            elseif STAT_DELTA_BY_NAME[name] ~= nil then
                if M.grant_stat(name) then stat_grants = stat_grants + 1 end
            end
        end
    end

    log(string.format("rebuild: %d skills granted, %d stat upgrades applied (from %d received items)",
        skill_grants, stat_grants, #items))
    return true
end

------------------------------------------------------------
-- Registration
------------------------------------------------------------

function M.register()
    _install_hooks()
    _install_skill_watchdog()

    -- on_replay="skip" for both: rebuild is handled by save_state/load_save +
    -- the bridge's natural server-push on connect. For stats specifically,
    -- replaying through grant_stat would double-count deltas.
    local ItemEffects = require("DRAP/ItemEffects")
    local count = 0
    for name, _ in pairs(SKILL_BY_NAME) do
        ItemEffects.register(name, {
            on_replay = "skip",
            apply = function(ctx) M.grant_skill(name) end,
        })
        count = count + 1
    end
    for name, _ in pairs(STAT_DELTA_BY_NAME) do
        ItemEffects.register(name, {
            on_replay = "skip",
            apply = function(ctx) M.grant_stat(name) end,
        })
        count = count + 1
    end
    log(string.format("PlayerStats registered (%d items)", count))
end

------------------------------------------------------------
-- Console commands
------------------------------------------------------------

_G.drap_player_stats_print   = function() M.print_state() end
_G.drap_player_stats_apply   = function() M.apply() end
_G.drap_player_stats_reset   = function() M.reset_to_baseline() end
_G.drap_player_stats_grant   = function(name) return M.grant_item(name) end
_G.drap_player_stats_rebuild = function() return M.rebuild_from_received_items() end

-- Direct PlayerSkill setter (decimal or hex bitmask). Rebuilds granted_skills
-- so the watchdog target stays in sync.
--   drap_set_skills(266329)   -- 0x41059
--   drap_set_skills(0)        -- no skills
--   drap_set_skills(2097151)  -- all 21 (0x1FFFFF)
_G.drap_set_skills = function(value)
    value = tonumber(value) or 0
    local psm = _psm()
    if not psm then log("PSM nil"); return end

    local new_set = {}
    for name, bit in pairs(SKILL_BY_NAME) do
        if (value & (1 << bit)) ~= 0 then new_set[name] = true end
    end
    granted_skills = new_set

    pcall(function() psm:call("setPlayerSkill", value) end)
    pcall(function() psm:call("set_PlayerSkillBits", value) end)
    pcall(function() psm:set_field("PlayerSkill", value) end)
    local readback
    pcall(function() readback = psm:get_field("PlayerSkill") end)
    log(string.format("set PlayerSkill -> 0x%X (readback 0x%X, watchdog target = 0x%X)",
        value, readback or 0, _skill_bitfield()))
end

-- Read all known PlayerSkill paths side-by-side. Useful when debugging
-- a "skills aren't gating right" report -- if these diverge, one of the
-- engine-side storage paths isn't being written correctly.
_G.drap_player_stats_read_skills = function()
    local psm = _psm()
    if not psm then log("PSM nil"); return end
    local function read(getter)
        local v
        pcall(function() v = getter(psm) end)
        v = tonumber(v)
        return v and string.format("%d (0x%08X)", v, v) or "nil"
    end
    local target = _skill_bitfield()
    log(string.format("DRAP target            = %d (0x%08X)", target, target))
    log("PlayerSkill field      = " .. read(function(p) return p:get_field("PlayerSkill") end))
    log("getPlayerSkill()       = " .. read(function(p) return p:call("getPlayerSkill") end))
    log("get_PlayerSkillBits()  = " .. read(function(p) return p:call("get_PlayerSkillBits") end))
end

return M
