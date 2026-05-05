-- DRAP/effects/ZombieEffects.lua
-- Difficulty modifiers (Night Mode, Hardcore Zombies) via ZombieDefinitionUserData.
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

return M
