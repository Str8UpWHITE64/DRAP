-- DRAP/effects/PlayerBuffs.lua
-- Temporary buffs and traps that fill the AP item pool.
-- See docs/reframework/features/player_buffs.md.
--
-- Three effect categories:
--   * Juice-driven (5 buffs + 2 traps) -- engine-native, self-managing timers.
--   * Custom-timed (Berserker Mode, Slow Trap) -- save baseline, apply, restore.
--   * Instant (Heal, Player Damage, PP Boost) -- single function call.

local M = {}

local Shared = require("DRAP/Shared")
local log = Shared.create_logger("PlayerBuffs")
M.log = log

------------------------------------------------------------
-- Constants
------------------------------------------------------------

local PSM_TYPE = "app.solid.PlayerStatusManager"
local PM_TYPE  = "app.solid.PlayerManager"

-- Juice slot indices (confirmed by user playtest)
local JUICE = {
    FLEETFOOT     = 0,   -- buff: speed
    STOMACH_ACHE  = 1,   -- trap: hidden debuff (no UI feedback)
    UNTOUCHABLE   = 2,   -- buff: invincibility
    SPITFIRE      = 3,   -- buff: fire breath
    -- 4 = NECTAR -- omitted (VFX plays but doesn't actually spawn queens)
    ENERGIZER     = 5,   -- buff: HP regen
    ZOMBAIT       = 6,   -- trap: attracts zombies
    TOUGHNESS     = 7,   -- buff: damage reduction
}

local DEFAULT_JUICE_DURATION = 30.0
-- Default for slow trap and Berserker Mode
local DEFAULT_TIMED_DURATION = 30.0
-- Heal magnitude (instant HP restore)
local HEAL_AMOUNT = 2000
local DAMAGE_AMOUNT = 2000
-- Damage Player Trap floor: clamp damage so the player never drops below this.
-- Going to 0 via addDamage triggers a stuck-undead state (HP <= 0 but the engine
-- never transitions to the death/respawn path), forcing the player to close
-- the game. Leaving them at 1000 keeps a clear "danger zone" feel without
-- tripping the bug.
local DAMAGE_HP_FLOOR = 1000
-- Berserker Mode attack% target (and paired Buttobi computed from it)
local BERSERKER_ATTACK_PCT = 1000
-- Slow Trap multiplier on LevelSpeedMax
local SLOW_TRAP_MULT = 0.5
-- Vanilla LevelSpeedMax baseline (captured from PlayerLvUpUserData)
local VANILLA_SPEED_TABLE = { 1.2, 1.3, 1.4 }

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local _notify_trap = Shared.lazy_notify_trap()

local function _psm() return sdk.get_managed_singleton(PSM_TYPE) end

local function _player_condition()
    local pm = sdk.get_managed_singleton(PM_TYPE)
    if not pm then return nil end
    local cond
    pcall(function() cond = pm:call("get_CurrentPlayerCondition") end)
    return cond
end

local function _hpc()
    local psm = _psm()
    if not psm then return nil end
    local hpc
    pcall(function() hpc = psm:call("get_PlayerVitalController") end)
    return hpc
end

local function _move_setting()
    local cond = _player_condition()
    if not cond then return nil end
    local pvs
    pcall(function() pvs = cond:get_field("<PlayerSetting>k__BackingField") end)
    if not pvs then return nil end
    local ms
    pcall(function() ms = pvs:get_field("MoveSetting") end)
    return ms
end

local function _set_speed_table(values)
    local ms = _move_setting()
    if not ms then return false end
    local list
    pcall(function() list = ms:get_field("LevelSpeedMax") end)
    if not list then return false end
    for i, v in ipairs(values) do
        pcall(function() list:call("set_Item", i - 1, v) end)
    end
    return true
end

local function _refresh_psm_ui()
    local psm = _psm()
    if not psm then return end
    pcall(function() psm:set_field("<LevelUpdated>k__BackingField", true) end)
    pcall(function() psm:call("applyPlayerValue") end)
end

-- Juice trigger: PlayerCondition.setMixJuiceTimerAll(MixJuiceID, float seconds).
-- The duration MUST be a Lua float (force via *1.0) -- int passes as arg2=0.
local function _trigger_juice(slot_idx, duration)
    local cond = _player_condition()
    if not cond then return false end
    local td = sdk.find_type_definition("app.solid.gamemastering.GameManager.MixJuiceID")
    if not td then return false end
    local enum_names = {
        [0] = "MIX_JUICE_ID_WHITE",   [1] = "MIX_JUICE_ID_BLACK",
        [2] = "MIX_JUICE_ID_RED",     [3] = "MIX_JUICE_ID_BLUE",
        [4] = "MIX_JUICE_ID_YELLOW",  [5] = "MIX_JUICE_ID_GREEN",
        [6] = "MIX_JUICE_ID_PINK",    [7] = "MIX_JUICE_ID_ARMOR",
    }
    local fd = td:get_field(enum_names[slot_idx])
    if not fd then return false end
    local enum_val
    pcall(function() enum_val = fd:get_data(nil) end)
    if not enum_val then return false end
    local sec = (tonumber(duration) or DEFAULT_JUICE_DURATION) * 1.0   -- force float
    pcall(function() cond:call("setMixJuiceTimerAll", enum_val, sec) end)
    return true
end

------------------------------------------------------------
-- Custom-timed effect state (Berserker Mode + Slow Trap)
-- Each entry: { expires_at, saved_state, restore_fn }
------------------------------------------------------------

local _timed_effects = {}     -- { [name] = entry }
local _frame_cb_installed = false

-- Timer-expiry loop registered at module load. Registering re.on_frame
-- from within another on_frame disrupts REFramework's iteration.
re.on_frame(function()
    if next(_timed_effects) == nil then return end
    local now = os.clock()
    for name, entry in pairs(_timed_effects) do
        if now >= entry.expires_at then
            local ok, err = pcall(entry.restore_fn)
            if not ok then
                log(string.format("Restore failed for '%s': %s", name, tostring(err)))
            end
            _timed_effects[name] = nil
            log(string.format("'%s' expired -- restored", name))
        end
    end
end)

local function _start_timed(name, duration, capture_fn, apply_fn, restore_fn)
    -- If already active, capture is preserved (don't double-save baseline);
    -- otherwise capture now.
    local existing = _timed_effects[name]
    if not existing then
        local saved = capture_fn()
        _timed_effects[name] = {
            saved = saved,
            expires_at = os.clock() + duration,
            restore_fn = function() restore_fn(saved) end,
        }
    else
        -- Already running -- extend the timer
        existing.expires_at = os.clock() + duration
    end
    apply_fn()
end

------------------------------------------------------------
-- Juice buff API (each = single AP item)
------------------------------------------------------------

function M.fleetfoot_effect(sec)
    if _trigger_juice(JUICE.FLEETFOOT, sec or DEFAULT_JUICE_DURATION) then
        log("Fleetfoot Effect activated")
    end
end

function M.untouchable_effect(sec)
    if _trigger_juice(JUICE.UNTOUCHABLE, sec or DEFAULT_JUICE_DURATION) then
        log("Untouchable Effect activated")
    end
end

function M.spitfire_effect(sec)
    if _trigger_juice(JUICE.SPITFIRE, sec or DEFAULT_JUICE_DURATION) then
        log("Spitfire Effect activated")
    end
end

function M.energizer_effect(sec)
    if _trigger_juice(JUICE.ENERGIZER, sec or DEFAULT_JUICE_DURATION) then
        log("Energizer Effect activated")
    end
end

function M.toughness_effect(sec)
    if _trigger_juice(JUICE.TOUGHNESS, sec or DEFAULT_JUICE_DURATION) then
        log("Toughness Effect activated")
    end
end

------------------------------------------------------------
-- Juice trap API
------------------------------------------------------------

function M.stomach_ache(sec)
    -- 60s default -- effect is pretty random in timing, so a longer window
    -- gives it more chance to actually hit the player.
    sec = sec or 60
    if _trigger_juice(JUICE.STOMACH_ACHE, sec) then
        log("Stomach Ache Trap fired")
        _notify_trap("Stomach Ache Trap", string.format("Periodic damage for %ds", sec))
    end
end

function M.zombait(sec)
    sec = sec or DEFAULT_JUICE_DURATION
    if _trigger_juice(JUICE.ZOMBAIT, sec) then
        log("Zombait Trap fired")
        _notify_trap("Zombait Trap", string.format("Zombies drawn to you for %ds", sec))
    end
end

------------------------------------------------------------
-- Instant effects
------------------------------------------------------------

function M.heal(amount)
    amount = tonumber(amount) or HEAL_AMOUNT
    local hpc = _hpc()
    if not hpc then return end
    pcall(function() hpc:call("recovery", amount) end)
    log(string.format("Heal: +%d HP", amount))
end

function M.player_damage(amount)
    amount = tonumber(amount) or DAMAGE_AMOUNT
    local psm = _psm()
    local hpc = _hpc()
    if not psm or not hpc then return end

    -- Read current HP; clamp damage to keep the player at >= DAMAGE_HP_FLOOR.
    local cur
    pcall(function() cur = psm:call("getVitalNew") end)
    cur = tonumber(cur)
    if cur and cur <= DAMAGE_HP_FLOOR then
        log(string.format("Damage Player Trap: HP=%d already at/below floor %d -- skipping",
            cur, DAMAGE_HP_FLOOR))
        _notify_trap("Damage Player Trap", "(skipped -- HP too low)")
        return
    end
    if cur and (cur - amount) < DAMAGE_HP_FLOOR then
        amount = cur - DAMAGE_HP_FLOOR
    end

    pcall(function() hpc:call("addDamage", amount) end)
    if cur then
        log(string.format("Damage Player Trap: -%d HP (%d -> %d)", amount, cur, cur - amount))
    else
        log(string.format("Damage Player Trap: -%d HP (current HP unknown)", amount))
    end
    _notify_trap("Damage Player Trap", string.format("-%d HP", amount))
end

function M.pp_boost(amount)
    amount = tonumber(amount) or 5000
    local psm = _psm()
    if not psm then return end

    -- See player_buffs.md for the calcScore param choices.
    pcall(function() psm:call("calcScore", 0, amount, 65535, 0, false) end)

    -- calcPlayerLevelUp must run from the engine's update loop -- defer to next frame.
    local fired = false
    re.on_frame(function()
        if fired then return end
        fired = true
        local p = _psm()
        if p then pcall(function() p:call("calcPlayerLevelUp") end) end
    end)

    log(string.format("PP Boost: +%d PP (level-up check next frame)", amount))
end

------------------------------------------------------------
-- Custom-timed effects
------------------------------------------------------------

-- 30s @ 1000% attack% with paired Buttobi. Auto-restores.
function M.berserker_mode(sec)
    sec = tonumber(sec) or DEFAULT_TIMED_DURATION
    local psm = _psm()
    if not psm then return end

    _start_timed("Berserker Mode", sec,
        function()
            -- capture
            local atk, kb
            pcall(function() atk = psm:get_field("PlayerAttackPercent") end)
            pcall(function() kb  = psm:get_field("PlayerButtobiPercent") end)
            return {
                atk = tonumber(atk) or 100,
                kb  = tonumber(kb)  or 100,
            }
        end,
        function()
            -- apply: attack=1000, buttobi = 100 + 0.8*900 = 820
            pcall(function() psm:call("setPlayerAttackPercent", BERSERKER_ATTACK_PCT) end)
            pcall(function() psm:call("setPlayerButtobiPercent", 820) end)
            _refresh_psm_ui()
            log(string.format("Berserker Mode: Attack=%d for %.1fs",
                BERSERKER_ATTACK_PCT, sec))
        end,
        function(saved)
            -- restore
            pcall(function() psm:call("setPlayerAttackPercent", saved.atk) end)
            pcall(function() psm:call("setPlayerButtobiPercent", saved.kb) end)
            _refresh_psm_ui()
        end)
end

-- 30s @ 0.5x speed (multiplies the LevelSpeedMax table). Auto-restores.
function M.slow_trap(sec, multiplier)
    sec = tonumber(sec) or DEFAULT_TIMED_DURATION
    multiplier = tonumber(multiplier) or SLOW_TRAP_MULT

    _start_timed("Slow Trap", sec,
        function()
            -- capture current LevelSpeedMax values
            local ms = _move_setting()
            if not ms then return nil end
            local list
            pcall(function() list = ms:get_field("LevelSpeedMax") end)
            if not list then return nil end
            local count
            pcall(function() count = list:call("get_Count") end)
            count = tonumber(count) or 0
            local out = {}
            for i = 0, count - 1 do
                local v
                pcall(function() v = list:call("get_Item", i) end)
                out[i + 1] = tonumber(v) or 0
            end
            return out
        end,
        function()
            -- apply: scale baseline by multiplier
            local saved = _timed_effects["Slow Trap"]
                          and _timed_effects["Slow Trap"].saved
            local base = saved or VANILLA_SPEED_TABLE
            local scaled = {}
            for i, v in ipairs(base) do scaled[i] = v * multiplier end
            _set_speed_table(scaled)
            local psm = _psm()
            if psm then pcall(function() psm:call("applyPlayerValue") end) end
            log(string.format("Slow Trap: %gx speed for %.1fs", multiplier, sec))
            _notify_trap("Slow Trap", string.format("%gx speed for %.0fs", multiplier, sec))
        end,
        function(saved)
            -- restore
            _set_speed_table(saved or VANILLA_SPEED_TABLE)
            local psm = _psm()
            if psm then pcall(function() psm:call("applyPlayerValue") end) end
        end)
end

------------------------------------------------------------
-- Diagnostics / registration
------------------------------------------------------------

function M.get_active_timed_effects()
    local out = {}
    for name, entry in pairs(_timed_effects) do
        out[name] = entry.expires_at - os.clock()
    end
    return out
end

function M.cancel_all_timed_effects()
    for _, entry in pairs(_timed_effects) do
        pcall(entry.restore_fn)
    end
    _timed_effects = {}
    log("Cancelled all timed effects")
end

function M.register()
    -- Register filler buffs/traps with ItemEffects.
    -- on_replay = "skip" -- temporary effects shouldn't re-fire on save reload.
    local ItemEffects = require("DRAP/ItemEffects")
    local items = {
        -- Juice buffs
        { name = "Fleetfoot Effect",   fn = M.fleetfoot_effect },
        { name = "Untouchable Effect", fn = M.untouchable_effect },
        { name = "Spitfire Effect",    fn = M.spitfire_effect },
        { name = "Energizer Effect",   fn = M.energizer_effect },
        { name = "Toughness Effect",   fn = M.toughness_effect },
        -- Juice traps (gated by trap_percentage on AP-gen side)
        { name = "Stomach Ache Trap",  fn = M.stomach_ache },
        { name = "Zombait Trap",       fn = M.zombait },
        -- Custom buffs / instant effects
        { name = "Heal",               fn = M.heal },
        { name = "Berserker Mode",     fn = M.berserker_mode },
        { name = "PP Boost",           fn = function(ctx)
                local amt = (ctx and ctx.net_item and ctx.net_item.amount) or 5000
                M.pp_boost(amt)
            end },
        -- Custom traps
        { name = "Slow Trap",          fn = M.slow_trap },
        { name = "Damage Player Trap", fn = M.player_damage },
    }
    for _, item in ipairs(items) do
        ItemEffects.register(item.name, {
            on_replay = "skip",
            apply = function(ctx) item.fn() end,
        })
    end
    log(string.format("PlayerBuffs registered (%d items)", #items))
end

_G.drap_buff_fleetfoot   = function(s) M.fleetfoot_effect(s)   end
_G.drap_buff_untouchable = function(s) M.untouchable_effect(s) end
_G.drap_buff_spitfire    = function(s) M.spitfire_effect(s)    end
_G.drap_buff_energizer   = function(s) M.energizer_effect(s)   end
_G.drap_buff_toughness   = function(s) M.toughness_effect(s)   end
_G.drap_trap_stomach_ache = function(s) M.stomach_ache(s) end
_G.drap_trap_zombait      = function(s) M.zombait(s) end
_G.drap_buff_heal         = function(a) M.heal(a) end
_G.drap_buff_berserker    = function(s) M.berserker_mode(s) end
_G.drap_buff_pp_boost     = function(a) M.pp_boost(a) end
_G.drap_trap_slow         = function(s, m) M.slow_trap(s, m) end
_G.drap_trap_damage       = function(a) M.player_damage(a) end

return M
