-- DRAP/effects/ZombieEffects.lua
-- Difficulty modifiers: Night Mode (params + glowing eyes), Hardcore
-- Zombies, and the zombie spawn multiplier.
-- See docs/reframework/features/zombie_effects.md.
--
-- Two activation paths:
--   * Permanent (YAML options) -- slot_data flags flip at connect, stay on for session.
--   * Timed -- apply for N seconds then revert (testing / future trap items).

local M = {}

local Shared = require("DRAP/Shared")
local log = Shared.create_logger("ZombieEffects")
M.log = log

------------------------------------------------------------
-- Constants
------------------------------------------------------------

local ZM_TYPE = "app.solid.gamemastering.ZombieManager"

-- Day fields whose values get overwritten with night equivalents so engine
-- code paths that read the day branch directly still see night values.
local NIGHT_PAIRS = {
    { day = "HoldMissRateDay",      night = "HoldMissRateNight" },
    { day = "HoldBlockRateDay",     night = "HoldBlockRateNight" },
    { day = "HoldBlockFallRateDay", night = "HoldBlockFallRateNight" },
}

-- Hour-threshold fields. Setting day=25, night=0 makes the engine's
-- "is current_hour in night window" check evaluate true regardless.
local NIGHT_HOUR_FIELDS = { "ZOMBIE_HOUR_DAY_TIME", "ZOMBIE_HOUR_NIGHT_TIME" }

-- Hardcore Zombies amplifies these on top of force-night.
local HARDCORE_VALUES = {
    HoldVitalDec            = -3000,    -- 3x bite damage (was -1000)
    HoldVitalDecDown        = -9000,    -- 3x downed-bite damage (was -3000)
    AttackScratchDamageRate = 7.0,      -- 2x scratch damage (was 3.5)
    TARGET_PL_FIND_RADIUS   = 25.0,     -- aggro from far (was 9)
    TARGET_FIND_RADIUS_MAX  = 35.0,     -- (was 13)
    TARGET_NPC_FIND_RADIUS  = 25.0,     -- (was 10)
    HoldLeverGachaNum       = 30,       -- 2x mash count to escape (was 15)
    HoldButtonGachaReduce   = 0.05,     -- mash decay 2.5x faster (was 0.02)
}

local DEFAULT_NIGHT_DURATION = 90.0
local DEFAULT_HARDCORE_DURATION = 60.0

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local safe = Shared.safe

local function _zm() return sdk.get_managed_singleton(ZM_TYPE) end

local function _def()
    local zm = _zm()
    if not zm then return nil end
    return safe(function() return zm:get_field("mDefinitionUserData") end)
end

local function _read(def, name)
    return safe(function() return def:get_field(name) end)
end

local function _write(def, name, value)
    return pcall(function() def:set_field(name, value) end)
end

local _notify_trap = Shared.lazy_notify_trap()

------------------------------------------------------------
-- isHourNight() hook -- engine-side override
------------------------------------------------------------
-- Hooked once; post-hook returns non-null when _night_active is true.

local _night_active = false
local _night_hook_installed = false

local function _install_night_hook()
    if _night_hook_installed then return end
    local td = sdk.find_type_definition(ZM_TYPE)
    if not td then return end
    local fn = td:get_method("isHourNight")
    if not fn then
        log("WARN: ZombieManager.isHourNight() not found")
        return
    end
    sdk.hook(fn, function(args) end, function(retval)
        if _night_active then return sdk.to_ptr(1) end
        return retval
    end)
    _night_hook_installed = true
    log("isHourNight() hook installed (gated by _night_active)")
end

------------------------------------------------------------
-- Glowing night eyes
------------------------------------------------------------
-- Per-zombie state on ZombieThinkBehavior, reached via uZombie.mZombieThink.
-- setNightEye() builds the eye effect; writing mNightEye alone does not.
-- Zombies stream in constantly, so this sweeps on a tick rather than once.

local NIGHT_EYE_INTERVAL = 30    -- frames between sweeps

local _night_eyes = false
local _eye_tick = 0

local function _each_zombie_think(fn)
    local zm = _zm()
    if not zm then return 0 end
    local list = safe(function() return zm:get_field("mpZombie") end)
    if not list then return 0 end
    local n = tonumber(safe(function() return list:call("get_Count") end)) or 0
    local hit = 0
    for i = 0, n - 1 do
        local z = safe(function() return list:call("get_Item", i) end)
        local th = z and safe(function() return z:get_field("mZombieThink") end)
        if th and fn(th) then hit = hit + 1 end
    end
    return hit
end

--- Order matters: setNightZombieCtrl() recomputes mNight from the in-game
--- hour, so the flags go last or they read back false immediately.
local function _set_night_eye(th, on)
    local ok = pcall(function() th:call("setNightEye", on) end)
    pcall(function() th:call("setNightZombieCtrl") end)
    pcall(function() th:set_field("mNight", on) end)
    pcall(function() th:set_field("mNightEye", on) end)
    return ok
end

local function _sweep_night_eyes()
    _each_zombie_think(function(th)
        if safe(function() return th:get_field("mNightEye") end) ~= _night_eyes then
            return _set_night_eye(th, _night_eyes)
        end
        return false
    end)
end

------------------------------------------------------------
-- Zombie spawn multiplier
------------------------------------------------------------
-- mAllSetCnt on the selected layout is how many zombies the area asks for, and
-- mSpeedyNum its share of fast ones. MaxNormalZombieNum, spawn range, the
-- additional count and the per-type maxima are ceilings, not requests --
-- raising them changes nothing.
--
-- The layout resource is rebuilt per area load, so scaling has to happen in a
-- pre-hook on instantinateZombies rather than as a one-shot write.

local ELM_TYPE = "app.solid.gamemastering.EnemyLayoutManager"
local SPAWN_MULT_MAX = 5

local _spawn_mult = 1
local _spawn_bases = {}          -- layout resource id -> vanilla {cnt, spd}
local _spawn_hook_installed = false
-- Log what each scale write did. Off by default: this runs on every area load.
local _spawn_verbose = false

local function _selected_layout()
    local e = sdk.get_managed_singleton(ELM_TYPE)
    if not e then return nil, nil end
    local sel = safe(function() return e:get_field("SelectedZombieSet") end)
    local res = sel and safe(function() return sel:get_field("CurrentLayoutResource") end)
    local lay = res and safe(function() return res:get_field("mLayout") end)
    return lay, res
end

--- Baselines are keyed per layout resource: mAllSetCnt differs per area, and a
--- single shared baseline would scale an already-scaled number after a move.
local function _apply_spawn_scale()
    -- 1 is vanilla and wants no write at all. 0 is a real setting -- it asks
    -- the area for no zombies -- so only 1 returns early.
    if _spawn_mult == 1 then return end
    local lay, res = _selected_layout()
    if not lay then
        -- Silent before, which made "the hook never fired" and "the layout was
        -- not ready yet" look the same as "the write was ignored".
        if _spawn_verbose then log("scale skipped: no selected layout yet") end
        return
    end
    local rid = tostring(res and safe(function() return res:get_field("mId") end) or "?")
    if not _spawn_bases[rid] then
        _spawn_bases[rid] = {
            cnt = tonumber(safe(function() return lay:get_field("mAllSetCnt") end)) or 0,
            spd = tonumber(safe(function() return lay:get_field("mSpeedyNum") end)) or 0,
        }
    end
    local b = _spawn_bases[rid]
    local want_cnt = math.floor(b.cnt * _spawn_mult)
    local want_spd = math.floor(b.spd * _spawn_mult)
    pcall(function() lay:set_field("mAllSetCnt", want_cnt) end)
    pcall(function() lay:set_field("mSpeedyNum", want_spd) end)
    if _spawn_verbose then
        local got_cnt = tonumber(safe(function() return lay:get_field("mAllSetCnt") end))
        local got_spd = tonumber(safe(function() return lay:get_field("mSpeedyNum") end))
        log(string.format(
            "layout %s: base %d/%d, wrote %d/%d, reads back %s/%s",
            rid, b.cnt, b.spd, want_cnt, want_spd,
            tostring(got_cnt), tostring(got_spd)))
    end
end

-- Scale the layout at INIT time, which is the only moment early enough.
--
-- The watcher below fixes "the area never gets scaled", but it necessarily
-- runs after the layout appears -- and by then the engine has already spawned
-- from the vanilla count. Harmless at 3x (the extra zombies still arrive);
-- very visible at 0x, where a handful spawn before the write lands.
--
-- initZombieModelSpaceSet takes the layout as an argument, so it does not
-- depend on SelectedZombieSet being populated -- which is exactly what the
-- instantinateZombies pre-hook was missing. Address checked unique before
-- hooking (fn 140c926f0), per the fold hazard.
local _init_hook_installed = false
local _init_scaled = {}          -- layout address -> the count we wrote

--- Scale a layout we were handed directly. No resource id here, so idempotence
--- is by remembering what we wrote: if it still reads that, this is a repeat
--- call and the value must not be scaled a second time.
local function _scale_layout_now(lay)
    local addr = safe(function() return lay:get_address() end)
    local cnt = tonumber(safe(function() return lay:get_field("mAllSetCnt") end))
    if not cnt then return end
    if addr and _init_scaled[addr] == cnt then return end

    local spd = tonumber(safe(function() return lay:get_field("mSpeedyNum") end)) or 0
    local want_cnt = math.floor(cnt * _spawn_mult)
    local want_spd = math.floor(spd * _spawn_mult)
    pcall(function() lay:set_field("mAllSetCnt", want_cnt) end)
    pcall(function() lay:set_field("mSpeedyNum", want_spd) end)
    if addr then _init_scaled[addr] = want_cnt end
    if _spawn_verbose then
        log(string.format("init-hook: %d/%d -> %d/%d (reads back %s/%s)",
            cnt, spd, want_cnt, want_spd,
            tostring(safe(function() return lay:get_field("mAllSetCnt") end)),
            tostring(safe(function() return lay:get_field("mSpeedyNum") end))))
    end
end

local function _install_layout_init_hook()
    if _init_hook_installed then return end
    local td = sdk.find_type_definition(ELM_TYPE)
    local fn = td and td:get_method("initZombieModelSpaceSet")
    if not fn then
        log("WARN: initZombieModelSpaceSet() not found -- the multiplier will"
            .. " apply a beat late (visible at 0x)")
        return
    end
    sdk.hook(fn, function(args)
        if _spawn_mult == 1 then return end
        -- Which slot holds the layout is not worth asserting: find the one
        -- that IS an rEnemyLayout rather than assuming an argument index.
        for i = 2, 4 do
            local obj = safe(function() return sdk.to_managed_object(args[i]) end)
            local tn = obj and safe(function()
                return obj:get_type_definition():get_full_name()
            end)
            if tn and tn:find("rEnemyLayout") then
                pcall(_scale_layout_now, obj)
                break
            end
        end
    end, nil)
    _init_hook_installed = true
    log("initZombieModelSpaceSet() pre-hook installed (scales at layout init)")
end

local function _install_spawn_hook()
    if _spawn_hook_installed then return end
    local td = sdk.find_type_definition(ELM_TYPE)
    local fn = td and td:get_method("instantinateZombies")
    if not fn then
        log("WARN: EnemyLayoutManager.instantinateZombies() not found -- "
            .. "spawn multiplier unavailable")
        return
    end
    sdk.hook(fn, function(args)
        if _spawn_verbose then log("instantinateZombies fired") end
        pcall(_apply_spawn_scale)
    end, nil)
    _spawn_hook_installed = true
    log("instantinateZombies() pre-hook installed (gated by multiplier)")
    _install_layout_init_hook()
end

-- Re-apply the scale once the new area's layout actually exists.
--
-- The pre-hook alone is not enough. On an area change instantinateZombies
-- fires BEFORE SelectedZombieSet is populated, so _apply_spawn_scale bails
-- with "no selected layout yet" and the new area keeps its vanilla counts --
-- measured, every transition, every fired hook. Writing while standing in an
-- area does stick, so the write itself was never the problem; its timing was.
--
-- Rather than guess when the layout becomes ready, watch for it. A freshly
-- built layout reads its vanilla count, so "current equals the baseline while
-- the baseline is not the target" picks out exactly the un-scaled case: it
-- re-arms on every area load, and once written the condition is false, so it
-- does not fight the engine for the rest of the area.
local WATCH_INTERVAL = 0.25
local _spawn_watch_next = 0

function M.on_frame()
    if _spawn_mult == 1 then return end
    local now = os.clock()
    if now < _spawn_watch_next then return end
    _spawn_watch_next = now + WATCH_INTERVAL

    local lay, res = _selected_layout()
    if not lay then return end

    local rid = tostring(res and safe(function() return res:get_field("mId") end) or "?")
    local cur = tonumber(safe(function() return lay:get_field("mAllSetCnt") end))
    if not cur then return end

    local b = _spawn_bases[rid]
    if b == nil then
        -- First sight of this layout: what it reads now IS vanilla.
        if _spawn_verbose then log("watcher: new layout " .. rid .. " -- scaling") end
        _apply_spawn_scale()
        return
    end

    local want = math.floor(b.cnt * _spawn_mult)
    if cur ~= want and cur == b.cnt then
        if _spawn_verbose then
            log(string.format("watcher: layout %s rebuilt at vanilla %d -- rescaling",
                rid, cur))
        end
        _apply_spawn_scale()
    end
end

------------------------------------------------------------
-- Night lighting
------------------------------------------------------------
-- Set the clock to midnight and let the engine light it.
--
-- mClock is a plain tick count from Day 0 00:00, 30 ticks per second, and the
-- day/hour/minute readout and SCQManager's mDate are all derived from it. Zero
-- is midnight, so the game renders its own night -- the real thing, including
-- the interiors that a global controller override never reached.
--
-- This replaces driving WorldDayNight_Controller.updateFrame. That controller
-- could not be seeked: it reset its timeline to 0 whatever frame we asked for,
-- measured by asking for 45 and 120 and reading 0.0 back both times, so the
-- result was approximate at best.
--
-- TimeGate owns the write, because it owns the clock and has to give it back
-- before anything runs time forward. Here we only decide whether to ask.
--
-- ScoopSanity only. Without it the clock runs and the game cycles day to night
-- by itself; holding midnight would fight a working mechanic. Also gated on
-- Meet Jessie so the prologue plays in its intended daylight.
--
-- The glowing eyes stay separate: the engine only sets those at Day 1 19:00,
-- so midnight alone does not produce them.

local _light_night = false        -- option wants night lighting
local _light_gate_open = false    -- ScoopSanity + Jessie both satisfied

local function _time_gate()
    local ok, TG = pcall(require, "DRAP/TimeGate")
    if ok then return TG end
    return nil
end

local function _scoop_state()
    local ok, S = pcall(require, "DRAP/scoops/ScoopState")
    if ok then return S end
    return nil
end

--- Overtime runs on this same clock and has its own scheduled events -- one at
--- Day 6 11:00 in s700 -- so holding it at Day 0 midnight would be 72-hour
--- state applied where it does not belong.
---
--- Checked every poll rather than only when the gate opens: a run reaches the
--- endgame and enters Overtime in the SAME session the gate opened in, and
--- Overtime freezes time with Jessie eventually reading true, which is exactly
--- the shape that would otherwise keep the hold on.
local function _in_overtime()
    local S = _scoop_state()
    if not (S and S.is_endgame_reached) then return false end
    local ok, v = pcall(S.is_endgame_reached)
    return ok and v == true
end

------------------------------------------------------------
-- Timed-effect scheduler (capture / apply / restore)
------------------------------------------------------------

local _timed = {}    -- name -> { saved, expires_at, restore_fn }
local _frame_cb_installed = false

-- Timer-expiry loop registered at module load. Registering re.on_frame
-- from within another on_frame disrupts REFramework's iteration.
re.on_frame(function()
    local now = os.clock()
    for name, entry in pairs(_timed) do
        if entry.expires_at and now >= entry.expires_at then
            pcall(entry.restore_fn)
            _timed[name] = nil
            log(string.format("'%s' restored after expiration", name))
        end
    end

    -- Night eyes share this callback rather than registering a second one.
    _eye_tick = _eye_tick + 1
    if _night_eyes and _eye_tick % NIGHT_EYE_INTERVAL == 0 then
        pcall(_sweep_night_eyes)
    end
end)

local function _start_timed(name, sec, capture_fn, apply_fn, restore_fn)
    sec = tonumber(sec) or 30
    -- Cancel any prior instance -- a re-fire restarts the timer with a
    -- fresh capture so we don't lose the original baseline.
    if _timed[name] then
        pcall(_timed[name].restore_fn)
        _timed[name] = nil
    end

    local saved = capture_fn()
    if saved == nil then
        log(string.format("'%s': capture failed, aborting", name))
        return false
    end

    local entry = {
        saved = saved,
        expires_at = os.clock() + sec,
        restore_fn = function() restore_fn(saved) end,
    }

    pcall(apply_fn)
    _timed[name] = entry
    log(string.format("'%s' active for %.0fs", name, sec))
    return true
end

------------------------------------------------------------
-- Capture / apply primitives (shared by timed + permanent paths)
------------------------------------------------------------

local function _capture_night()
    local def = _def()
    if not def then return nil end
    local saved = { day_values = {}, hour_thresholds = {} }
    for _, p in ipairs(NIGHT_PAIRS) do
        local v = _read(def, p.day)
        if v ~= nil then saved.day_values[p.day] = v end
    end
    for _, fname in ipairs(NIGHT_HOUR_FIELDS) do
        local v = _read(def, fname)
        if v ~= nil then saved.hour_thresholds[fname] = v end
    end
    return saved
end

local function _apply_night()
    _install_night_hook()
    _night_active = true
    -- Glowing eyes, on the zombies standing here now and on later spawns.
    _night_eyes = true
    pcall(_sweep_night_eyes)
    local def = _def()
    if not def then return end
    for _, p in ipairs(NIGHT_PAIRS) do
        local n = _read(def, p.night)
        if n ~= nil then _write(def, p.day, n) end
    end
    -- Collapse hour window so non-hooked code paths also see night.
    _write(def, "ZOMBIE_HOUR_DAY_TIME", 25)
    _write(def, "ZOMBIE_HOUR_NIGHT_TIME", 0)
end

local function _restore_night(saved)
    _night_active = false
    -- Clear the eyes off anything still standing, then stop sweeping.
    _night_eyes = false
    pcall(_sweep_night_eyes)
    local def = _def()
    if not def or not saved then return end
    for fname, v in pairs(saved.day_values or {}) do _write(def, fname, v) end
    for fname, v in pairs(saved.hour_thresholds or {}) do _write(def, fname, v) end
end

local function _capture_hardcore()
    local def = _def()
    if not def then return nil end
    local saved = {}
    for fname, _ in pairs(HARDCORE_VALUES) do
        local v = _read(def, fname)
        if v ~= nil then saved[fname] = v end
    end
    return saved
end

local function _apply_hardcore()
    local def = _def()
    if not def then return end
    for fname, target in pairs(HARDCORE_VALUES) do
        _write(def, fname, target)
    end
end

local function _restore_hardcore(saved)
    local def = _def()
    if not def or not saved then return end
    for fname, v in pairs(saved or {}) do _write(def, fname, v) end
end

------------------------------------------------------------
-- Permanent activation (slot-data driven)
------------------------------------------------------------
-- Skips the timer wrapper; baseline tracked so set_permanent_*(false) can revert.

local _permanent = {
    night = { active = false, saved = nil },
    hardcore = { active = false, saved = nil },
}

function M.set_permanent_night(enable)
    enable = (enable ~= false)
    if enable then
        if _permanent.night.active then return true end
        _permanent.night.saved = _capture_night()
        if _permanent.night.saved == nil then
            log("set_permanent_night: capture failed (ZombieDefinitionUserData missing)")
            return false
        end
        _apply_night()
        _permanent.night.active = true
        log("Permanent Night Mode ENABLED")
        return true
    else
        if not _permanent.night.active then return false end
        _restore_night(_permanent.night.saved)
        _permanent.night.saved = nil
        _permanent.night.active = false
        log("Permanent Night Mode DISABLED")
        return true
    end
end

function M.set_permanent_hardcore(enable)
    enable = (enable ~= false)
    if enable then
        -- Hardcore implies Night -- apply night first so it's part of the
        -- baseline restore chain too.
        if not _permanent.night.active then M.set_permanent_night(true) end
        if _permanent.hardcore.active then return true end
        _permanent.hardcore.saved = _capture_hardcore()
        if _permanent.hardcore.saved == nil then
            log("set_permanent_hardcore: capture failed")
            return false
        end
        _apply_hardcore()
        _permanent.hardcore.active = true
        log("Permanent Hardcore Zombies ENABLED")
        return true
    else
        if not _permanent.hardcore.active then return false end
        _restore_hardcore(_permanent.hardcore.saved)
        _permanent.hardcore.saved = nil
        _permanent.hardcore.active = false
        log("Permanent Hardcore Zombies DISABLED")
        -- Note: leaves Permanent Night Mode active. Caller decides whether
        -- to also call set_permanent_night(false).
        return true
    end
end

function M.is_permanent_night_active()    return _permanent.night.active end
function M.is_permanent_hardcore_active() return _permanent.hardcore.active end

------------------------------------------------------------
-- Spawn multiplier (slot-data driven)
------------------------------------------------------------

--- 1 is vanilla; values above it scale how many zombies each area asks for.
--- Clamped to SPAWN_MULT_MAX because the cost is frame rate, not correctness.
---
--- 0 asks the area for no zombies at all. Whether the engine accepts that is
--- not yet known -- it has never been asked before.
function M.set_spawn_multiplier(n)
    n = tonumber(n) or 1
    if n < 0 then n = 0 end
    if n > SPAWN_MULT_MAX then n = SPAWN_MULT_MAX end
    _spawn_mult = n
    if n ~= 1 then
        _install_spawn_hook()
        -- Apply to the area already loaded; every later area is covered by the
        -- hook, which runs before the game places enemies.
        pcall(_apply_spawn_scale)
        log(string.format("Zombie spawn multiplier: %dx%s", n,
            n == 0 and " -- the mall should empty on the next area load" or ""))
    else
        log("Zombie spawn multiplier: 1x (vanilla)")
    end
    return true
end

function M.get_spawn_multiplier() return _spawn_mult end

------------------------------------------------------------
-- Night lighting (slot-data driven, ScoopSanity + Jessie gated)
------------------------------------------------------------

--- Enable night lighting. ScoopSanity only -- see the note above. Does nothing
--- until Meet Jessie is complete.
function M.set_night_lighting(enable, scoop_sanity)
    enable = (enable == true) and (scoop_sanity == true)
    _light_night = enable
    if enable then
        log("Night lighting armed (waiting on Meet Jessie)")
    else
        _light_gate_open = false
        local TG = _time_gate()
        if TG and TG.set_night_clock then TG.set_night_clock(false) end
        log("Night lighting off")
    end
    return true
end

--- Polled from the frame loop. Opens once Meet Jessie is complete, and closes
--- again on reaching the endgame -- Overtime is the one thing that takes it
--- back. has_met_jessie is tri-state, so a nil read is "ask again later"
--- rather than "not yet".
local function _refresh_light_gate()
    if not _light_night then return end

    if _in_overtime() then
        if _light_gate_open then
            _light_gate_open = false
            local TG = _time_gate()
            if TG and TG.set_night_clock then TG.set_night_clock(false) end
            log("Night lighting off (Overtime runs on its own clock)")
        end
        return
    end

    if _light_gate_open then return end
    local SU = _G.AP and _G.AP.ScoopUnlocker
    if not (SU and SU.has_met_jessie) then return end
    local met = SU.has_met_jessie()
    if met == true then
        _light_gate_open = true
        local TG = _time_gate()
        if TG and TG.set_night_clock then TG.set_night_clock(true) end
        log("Night lighting active (Meet Jessie complete)")
    end
end

function M.is_night_lighting_active()
    if not (_light_night and _light_gate_open) then return false end
    local TG = _time_gate()
    if TG and TG.is_night_clock_held then return TG.is_night_clock_held() end
    return true
end

-- Gate polling gets its own callback: _refresh_light_gate is defined below the
-- timer loop near the top of this file, so that loop cannot reach it. Once a
-- second is plenty for a one-way latch.
local _gate_tick = 0
re.on_frame(function()
    _gate_tick = _gate_tick + 1
    if _gate_tick % 60 ~= 0 then return end
    pcall(_refresh_light_gate)
end)

------------------------------------------------------------
-- Timed activation (manual / testing / future trap items)
------------------------------------------------------------

function M.night_mode(sec)
    sec = tonumber(sec) or DEFAULT_NIGHT_DURATION
    return _start_timed("Night Mode", sec,
        _capture_night,
        function()
            _apply_night()
            _notify_trap("Night Mode",
                string.format("Zombies grab harder for %.0fs", sec))
        end,
        _restore_night)
end

function M.hardcore_zombies(sec)
    sec = tonumber(sec) or DEFAULT_HARDCORE_DURATION
    -- Stack night mode underneath
    M.night_mode(sec)
    return _start_timed("Hardcore Zombies", sec,
        _capture_hardcore,
        function()
            _apply_hardcore()
            _notify_trap("Hardcore Zombies",
                string.format("3x bite damage for %.0fs", sec))
        end,
        _restore_hardcore)
end

------------------------------------------------------------
-- Diagnostics / cleanup
------------------------------------------------------------

function M.get_active_effects()
    local out = {}
    for name, entry in pairs(_timed) do
        out[name] = entry.expires_at - os.clock()
    end
    return out
end

function M.cancel_all()
    for _, entry in pairs(_timed) do
        pcall(entry.restore_fn)
    end
    _timed = {}
    log("Cancelled all timed zombie effects")
end

------------------------------------------------------------
-- Registration
------------------------------------------------------------

function M.register()
    -- Slot-data driven (no ItemEffects.register); see AP_DRDR_main.lua slot-connect.
    log("ZombieEffects loaded (slot-data driven, no item handlers)")
end

_G.drap_zomb_night    = function(s) M.night_mode(s)    end
_G.drap_zomb_hardcore = function(s) M.hardcore_zombies(s) end
_G.drap_zomb_active   = function() return M.get_active_effects() end
_G.drap_zomb_spawn    = function(n) return M.set_spawn_multiplier(n) end

--- Log every spawn-scale write with what the layout read back afterwards.
--- Answers the only question worth asking when a multiplier does nothing:
--- did the write land, or did the engine ignore the value?
_G.drap_zomb_verbose  = function(on)
    _spawn_verbose = (on ~= false)
    log("spawn scale logging " .. (_spawn_verbose and "ON" or "off"))
end

--- What the CURRENTLY loaded area's layout says right now.
_G.drap_zomb_layout   = function()
    local lay, res = _selected_layout()
    if not lay then
        log("no selected zombie layout -- is an area loaded?")
        return
    end
    local rid = tostring(res and safe(function() return res:get_field("mId") end) or "?")
    local cnt = tostring(safe(function() return lay:get_field("mAllSetCnt") end))
    local spd = tostring(safe(function() return lay:get_field("mSpeedyNum") end))
    log(string.format("layout %s: mAllSetCnt=%s mSpeedyNum=%s (multiplier %sx)",
        rid, cnt, spd, tostring(_spawn_mult)))
    -- Without the baseline the reading is ambiguous: 150 at 5x is either a
    -- correct 5 x 30, or a base that was captured from an already-scaled
    -- value and is now stuck. Say which.
    -- Which SET is selected, not just which layout resource. The area can
    -- swap zombie sets on story progression, and a set that asks for fewer
    -- zombies reads as "the multiplier stopped working" when it did not.
    local e = sdk.get_managed_singleton(ELM_TYPE)
    local sel = e and safe(function() return e:get_field("SelectedZombieSet") end)
    if sel then
        local set_id = safe(function() return sel:get_field("mId") end)
        local set_ty = safe(function() return sel:get_type_definition():get_full_name() end)
        log(string.format("  selected set: id=%s type=%s",
            tostring(set_id), tostring(set_ty)))
    end
    log(string.format("  layouts seen this session: %d", (function()
        local n = 0
        for _ in pairs(_spawn_bases) do n = n + 1 end
        return n
    end)()))

    local b = _spawn_bases[rid]
    if b then
        log(string.format("  baseline for this layout: %d/%d -> expects %d/%d",
            b.cnt, b.spd,
            math.floor(b.cnt * _spawn_mult), math.floor(b.spd * _spawn_mult)))
    else
        log("  NO baseline recorded for this layout -- the scale hook has not"
            .. " run for it, so these are vanilla numbers")
    end
end
-- Read-only, so the Oops More Zombies trap can be checked without changing it.
--- Live zombie counts, so the multiplier is checked by number not by eye.
---
--- These belong to ZombieManager, not the layout manager: the layout decides
--- how many an area ASKS for, this is what is actually standing there.
--- Measured at 1x/5x in Entrance Plaza: 93 live -> 495 live.
---
--- MaxNormalZombieNum is NOT a global cap -- it read 100 while 495 were alive.
--- It bounds the "normal" category only, so do not read it as a ceiling.
_G.drap_zomb_live = function()
    local z = sdk.get_managed_singleton("app.solid.gamemastering.ZombieManager")
    if not z then log("no ZombieManager -- is an area loaded?"); return end
    for _, m in ipairs({ "getZombieLiveNum", "get_NormalZombieNum",
                         "get_NormalZombieRemainNum" }) do
        log(string.format("  %-28s %s", m,
            tostring(safe(function() return z:call(m) end))))
    end
    log(string.format("  %-28s %sx", "spawn multiplier", tostring(_spawn_mult)))
end

_G.drap_zomb_mult     = function()
    log(string.format("spawn multiplier: %sx", tostring(M.get_spawn_multiplier())))
    return M.get_spawn_multiplier()
end
-- drap_zomb_frame is gone with the WorldDayNight controller it tuned. The
-- night point is not a setting any more -- it is midnight on the game clock.

return M
