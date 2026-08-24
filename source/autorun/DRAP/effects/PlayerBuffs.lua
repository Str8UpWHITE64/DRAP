-- DRAP/effects/PlayerBuffs.lua
-- Temporary buffs and traps that fill the AP item pool.
-- See docs/reframework/features/player_buffs.md.
--
-- Three effect categories:
--   * Juice-driven (5 buffs + 2 traps) -- engine-native, self-managing timers.
--   * Custom-timed (Berserker Mode, Skipped Leg Day Trap) -- save baseline, apply, restore.
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
-- Reaching 0 via addDamage triggers a stuck-undead state (HP<=0 but no
-- death/respawn transition), forcing a game restart. 1000 keeps a danger-zone
-- feel without tripping the bug.
local DAMAGE_HP_FLOOR = 1000
-- Berserker Mode attack% target (and paired Buttobi computed from it)
local BERSERKER_ATTACK_PCT = 1000
-- Skipped Leg Day Trap multiplier on LevelSpeedMax
local SLOW_TRAP_MULT = 0.5

-- Skipped Arm Day: attack percent while the trap runs. 1 is the floor rather
-- than 0 -- zero attack risks a divide in the damage maths, and 1% already
-- means nothing dies.
local ARM_DAY_ATTACK_PCT = 1
local ARM_DAY_DURATION   = 30.0

-- Oops More Zombies: multiplies whatever the run is ALREADY using, so it
-- stacks on a slot-data multiplier instead of overwriting it.
local ZOMBIE_TRAP_FACTOR   = 2
local ZOMBIE_TRAP_DURATION = 60.0

-- Potty Mouth: Frank's frustration bark. The id is a Wwise EVENT backed by a
-- random container, so repeats give different lines rather than one on a loop.
-- seCallTankVoice is the safe overload -- its siblings take a Nullable vec3
-- and passing nil for that crashed the game.
local FRANK_BARK_SE_ID   = 226669665
local POTTY_DURATION     = 30.0
-- Spacing is deliberate. Breaking an inventory quickly took the game down
-- inside Wwise, and a bark every frame is the same mistake with a nicer name.
local POTTY_INTERVAL     = 1.0
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
-- Custom-timed effect state (Berserker Mode + Skipped Leg Day Trap)
-- Each entry: { expires_at, saved_state, restore_fn }
------------------------------------------------------------

local _timed_effects = {}     -- { [name] = entry }
local _frame_cb_installed = false

-- Timer-expiry loop registered at module load. Registering re.on_frame
-- from within another on_frame disrupts REFramework's iteration.
------------------------------------------------------------
-- God mode (debug): invincible + un-grabbable + super speed, re-asserted
-- every tick (area loads / level-ups reset the underlying values).
-- Toggled from the Scoops tab debug GUI.
------------------------------------------------------------

local god_mode = false
local god_saved_speed = nil
local god_last_tick = 0

-- Books that make a test run quick: unarmed damage, both camera upgrades, and
-- weapons that never break. Looked up by name so the numbers stay in one place.
local GOD_BOOKS = {
    "Book [Martial Arts]",
    "Book [Camera 1]",
    "Book [Camera 2]",
    "Book [Infinite Durability]",
}
-- Only the ones God Mode granted are revoked on the way out -- a book the slot
-- legitimately sent has to survive.
local god_granted_books = {}

local function god_book_numbers()
    local SharedData = require("DRAP/SharedData")
    local wanted, out = {}, {}
    for _, n in ipairs(GOD_BOOKS) do wanted[n] = true end
    for _, def in ipairs(SharedData.items()) do
        if def.name and def.item_number and wanted[def.name] then
            out[#out + 1] = { name = def.name, item_no = def.item_number }
        end
    end
    return out
end

local function god_apply_books(on)
    local books = AP and AP.effects and AP.effects.BookSkills
    if not books then return end
    if on then
        for _, b in ipairs(god_book_numbers()) do
            -- Leave anything already owned alone, so it is not revoked later.
            if not books.is_granted(b.item_no) then
                books.grant(b.item_no)
                god_granted_books[b.item_no] = true
            end
        end
    else
        for item_no in pairs(god_granted_books) do
            books.revoke(item_no)
        end
        god_granted_books = {}
    end
end
local GOD_TICK_SECONDS = 2.0
local GOD_SPEED = { 5.0, 5.0, 5.0 }
local GOD_RUN_LEVEL = 10   -- acceleration: reach top speed instantly

local function _set_god_run(level_or_nil)
    local ps = _G.AP and _G.AP.effects and _G.AP.effects.PlayerStats
    if ps and ps.set_god_run_level then pcall(ps.set_god_run_level, level_or_nil) end
end

local function _read_speed_table()
    local ms = _move_setting()
    if not ms then return nil end
    local list
    pcall(function() list = ms:get_field("LevelSpeedMax") end)
    if not list then return nil end
    local out = {}
    for i = 0, 2 do
        local ok, v = pcall(function() return list:call("get_Item", i) end)
        out[i + 1] = ok and tonumber(v) or nil
    end
    if out[1] and out[2] and out[3] then return out end
    return nil
end

-- True no-damage: PlayerVitalController IS an app.solid.HitPointController,
-- which exposes the engine's own set_Invincible / set_NoDamage switches.
-- Re-asserted each tick in case area loads reset them.
local function _set_invincible(on)
    local hpc = _hpc()
    if not hpc then return false end
    pcall(function() hpc:call("set_Invincible", on == true) end)
    pcall(function() hpc:call("set_NoDamage", on == true) end)
    return true
end

function M.set_god_mode(enabled)
    enabled = enabled == true
    if enabled == god_mode then return end
    god_mode = enabled
    if enabled then
        god_saved_speed = _read_speed_table()
        _set_speed_table(GOD_SPEED)
        _refresh_psm_ui()
        _set_invincible(true)
        _set_god_run(GOD_RUN_LEVEL)
        god_last_tick = 0   -- fire the buff tick immediately
        god_apply_books(true)
        if AP and AP.ItemSpawner and AP.ItemSpawner.set_show_all_items then
            AP.ItemSpawner.set_show_all_items(true)
        end
        local n = 0
        for _ in pairs(god_granted_books) do n = n + 1 end
        log(string.format(
            "GOD MODE ON (Invincible + NoDamage[grab immunity] + speed %s"
                .. " + %d book(s) + every item spawnable)",
            tostring(GOD_SPEED[1]), n))
    else
        _set_invincible(false)
        _set_god_run(nil)
        god_apply_books(false)
        if AP and AP.ItemSpawner and AP.ItemSpawner.set_show_all_items then
            AP.ItemSpawner.set_show_all_items(false)
        end
        _set_speed_table(god_saved_speed or VANILLA_SPEED_TABLE)
        _refresh_psm_ui()
        -- Let the juice timers lapse on their own (short refresh window).
        log("GOD MODE OFF (invincibility, grab immunity, speed, books and the"
            .. " item list restored)")
    end
end

function M.is_god_mode() return god_mode end

-- Potty Mouth state. Kept out of _timed_effects because it has nothing to
-- restore -- it just stops.
local _potty = { until_at = 0, next_at = 0 }

--- One frustration bark from Frank, on the frame thread.
--- Sound MUST be played from a frame: the same call from the console reports
--- success and is silent, which cost a long stretch of the audio work.
local function _fire_bark()
    local sm = sdk.get_managed_singleton("app.solid.SoundManager")
    if not sm then return false end
    local pm = sdk.get_managed_singleton(PM_TYPE)
    local go = pm and select(2, pcall(function() return pm:call("get_CurrentPlayer") end))
    if not go then return false end
    return pcall(function()
        sm:call("seCallTankVoice(System.UInt32, via.GameObject)",
            FRANK_BARK_SE_ID, go)
    end)
end

re.on_frame(function()
    if god_mode then
        local now = os.clock()
        if now - god_last_tick >= GOD_TICK_SECONDS then
            god_last_tick = now
            -- NoDamage covers grab immunity (Alex) -- no juice needed.
            _set_invincible(true)                        -- area loads may reset
            _set_speed_table(GOD_SPEED)                  -- level-ups rewrite it
            _set_god_run(GOD_RUN_LEVEL)                  -- ditto run level
        end
    end
    -- Potty Mouth: one bark every POTTY_INTERVAL until the window closes.
    if _potty.until_at > 0 then
        local now = os.clock()
        if now >= _potty.until_at then
            _potty.until_at = 0
            log("'Potty Mouth Trap' expired")
        elseif now >= _potty.next_at then
            _potty.next_at = now + POTTY_INTERVAL
            _fire_bark()
        end
    end

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

--- Damage that is allowed to finish the job.
---
--- The Damage Player Trap clamps at DAMAGE_HP_FLOOR because addDamage taking
--- HP to 0 leaves the player undead -- HP<=0 with no death or respawn, which
--- needs a restart. DamageLink is meant to be able to kill, so the last hit
--- goes through the game's own death instead of through HP: damage down to
--- the floor, then playerDead().
---
--- @param amount integer HP to remove
--- @param reason string for the death log if it lands
--- @return string "damaged", "killed", or "unavailable"
function M.player_damage_or_kill(amount, reason)
    amount = tonumber(amount) or DAMAGE_AMOUNT
    local psm = _psm()
    local hpc = _hpc()
    if not psm or not hpc then return "unavailable" end

    local cur
    pcall(function() cur = psm:call("getVitalNew") end)
    cur = tonumber(cur)

    -- A failed HP read must not read as "lethal" -- that would kill on a bad
    -- read rather than on real damage. Unknown HP takes the ordinary path.
    if not cur then
        pcall(function() hpc:call("addDamage", amount) end)
        log(string.format("%s: -%d HP (current HP unknown)",
            tostring(reason or "damage"), amount))
        return "damaged"
    end

    -- Not lethal: ordinary damage, same as the trap.
    if cur and (cur - amount) >= DAMAGE_HP_FLOOR then
        pcall(function() hpc:call("addDamage", amount) end)
        log(string.format("%s: -%d HP (%d -> %d)",
            tostring(reason or "damage"), amount, cur, cur - amount))
        return "damaged"
    end

    -- Lethal. Take what can safely be taken so the health bar shows the hit,
    -- then let the game kill him.
    if cur and cur > DAMAGE_HP_FLOOR then
        pcall(function() hpc:call("addDamage", cur - DAMAGE_HP_FLOOR) end)
    end

    local DeathLink = require("DRAP/trackers/DeathLink")
    if DeathLink and DeathLink.kill_player then
        DeathLink.kill_player(reason or "damage")
        log(string.format("%s: lethal -- killed rather than written to 0",
            tostring(reason or "damage")))
        return "killed"
    end

    log(string.format("%s: lethal but no death path available", tostring(reason or "damage")))
    return "unavailable"
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
--- Skipped Arm Day: Frank hits like a wet paper bag for 30 seconds.
---
--- The override lives in PlayerStats rather than being written straight to the
--- engine, because PlayerStats.apply() is idempotent and hook-driven -- a save,
--- load or level-up during the window would otherwise restore full attack and
--- silently cancel the trap. Routing it through PlayerStats also means the
--- restore is "clear the override and re-apply", which recomputes the correct
--- value from baseline plus upgrades instead of a remembered number that may
--- be stale by then.
function M.arm_day_trap(sec)
    sec = tonumber(sec) or ARM_DAY_DURATION
    local PlayerStats = package.loaded["DRAP/effects/PlayerStats"]
        or require("DRAP/effects/PlayerStats")
    if not (PlayerStats and PlayerStats.set_attack_override) then
        log("Skipped Arm Day Trap: PlayerStats override unavailable")
        return
    end
    _start_timed("Skipped Arm Day Trap", sec,
        function() return true end,
        function()
            PlayerStats.set_attack_override(ARM_DAY_ATTACK_PCT)
            _notify_trap("You skipped arm day.")
            log(string.format("Skipped Arm Day Trap: attack %d%% for %.0fs",
                ARM_DAY_ATTACK_PCT, sec))
        end,
        function()
            PlayerStats.clear_attack_override()
        end)
end

--- Oops More Zombies: double the spawn multiplier for a minute.
---
--- Doubles whatever the run is ALREADY using, so it stacks on a slot-data
--- multiplier rather than replacing it. The target is computed from the SAVED
--- value every time apply runs, so a second copy landing mid-window extends
--- the timer without doubling again -- _start_timed keeps the original capture
--- and re-runs apply.
function M.zombie_swarm_trap(sec)
    sec = tonumber(sec) or ZOMBIE_TRAP_DURATION
    local Zombies = package.loaded["DRAP/effects/ZombieEffects"]
        or require("DRAP/effects/ZombieEffects")
    if not (Zombies and Zombies.set_spawn_multiplier) then
        log("Oops More Zombies Trap: ZombieEffects unavailable")
        return
    end
    local NAME = "Oops More Zombies Trap"
    _start_timed(NAME, sec,
        function()
            local cur = Zombies.get_spawn_multiplier and Zombies.get_spawn_multiplier()
            return tonumber(cur) or 1
        end,
        function()
            local entry = _timed_effects[NAME]
            local base = (entry and tonumber(entry.saved)) or 1
            Zombies.set_spawn_multiplier(base * ZOMBIE_TRAP_FACTOR)
            _notify_trap("Oops, more zombies.")
            log(string.format("%s: %dx -> %dx for %.0fs", NAME, base,
                base * ZOMBIE_TRAP_FACTOR, sec))
        end,
        function(saved)
            -- Back to what the run was using, not to vanilla.
            Zombies.set_spawn_multiplier(tonumber(saved) or 1)
        end)
end

--- Potty Mouth: Frank swears every couple of seconds for half a minute.
---
--- Not a _timed_effect: there is nothing to capture or restore, the barks
--- simply stop. The id is a Wwise event backed by a random container, so the
--- lines vary on their own.
function M.potty_mouth_trap(sec)
    sec = tonumber(sec) or POTTY_DURATION
    local now = os.clock()
    _potty.until_at = now + sec
    _potty.next_at = now          -- first one immediately
    _notify_trap("Frank has some choice words.")
    log(string.format("Potty Mouth Trap: barking for %.0fs", sec))
end

function M.slow_trap(sec, multiplier)
    sec = tonumber(sec) or DEFAULT_TIMED_DURATION
    multiplier = tonumber(multiplier) or SLOW_TRAP_MULT

    _start_timed("Skipped Leg Day Trap", sec,
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
            local saved = _timed_effects["Skipped Leg Day Trap"]
                          and _timed_effects["Skipped Leg Day Trap"].saved
            local base = saved or VANILLA_SPEED_TABLE
            local scaled = {}
            for i, v in ipairs(base) do scaled[i] = v * multiplier end
            _set_speed_table(scaled)
            local psm = _psm()
            if psm then pcall(function() psm:call("applyPlayerValue") end) end
            log(string.format("Skipped Leg Day Trap: %gx speed for %.1fs", multiplier, sec))
            _notify_trap("Skipped Leg Day Trap", string.format("%gx speed for %.0fs", multiplier, sec))
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
        { name = "Skipped Leg Day Trap",          fn = M.slow_trap },
        { name = "Damage Player Trap", fn = M.player_damage },
        { name = "Skipped Arm Day Trap", fn = M.arm_day_trap },
        { name = "Oops More Zombies Trap", fn = M.zombie_swarm_trap },
        { name = "Potty Mouth Trap",   fn = M.potty_mouth_trap },
    }
    -- Traps go through TrapBank instead of firing on arrival: one that lands
    -- at the title screen or mid-load used to be lost outright. Banked ones
    -- are paid out one at a time once the player is actually in the game.
    -- Buffs keep firing immediately -- they are a gift, and holding one back
    -- to drip-feed it later would just be annoying.
    local TrapBank = require("DRAP/TrapBank")
    local TRAPS = {
        ["Stomach Ache Trap"]  = true,
        ["Zombait Trap"]       = true,
        ["Skipped Leg Day Trap"]          = true,
        ["Damage Player Trap"] = true,
        ["Skipped Arm Day Trap"] = true,
        ["Oops More Zombies Trap"] = true,
        ["Potty Mouth Trap"]   = true,
    }
    local trap_n = 0
    for _, item in ipairs(items) do
        if TRAPS[item.name] then
            trap_n = trap_n + 1
            TrapBank.register(item.name, { fire = function() item.fn() end })
            -- Registered with ItemEffects too, purely so the arrival is
            -- logged where every other item's is. It does no work.
            ItemEffects.register(item.name, {
                on_replay = "skip",
                apply = function(ctx)
                    log(string.format("%s banked (%d owed)", item.name,
                        TrapBank.banked(item.name)))
                end,
            })
        else
            ItemEffects.register(item.name, {
                on_replay = "skip",
                apply = function(ctx) item.fn() end,
            })
        end
    end
    log(string.format("PlayerBuffs registered (%d items, %d via TrapBank)",
        #items, trap_n))
end

_G.drap_god = function(on)
    if on == nil then on = not M.is_god_mode() end
    M.set_god_mode(on ~= false)
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

_G.drap_trap_armday  = function(sec) M.arm_day_trap(sec) end
_G.drap_trap_zombies = function(sec) M.zombie_swarm_trap(sec) end
_G.drap_trap_potty   = function(sec) M.potty_mouth_trap(sec) end

return M
