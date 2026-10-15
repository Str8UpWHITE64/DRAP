-- DRAP/effects/InfinityDrain.lua
-- Infinity Mode's health drain, in a story run.
--
-- Vanilla Infinity takes 1 HP per 36 clock ticks, measured: 10 HP a second at
-- normal speed, so one 1000-HP bar every 100 s. It lives in
-- InfiniteGameManager, which only exists in Infinity, so it cannot be switched
-- on here. This module runs its own timer and hurts Frank through
-- PlayerCondition.requestInfinityModeDamage, which works outside Infinity
-- (no mode check, no flinch at 500, and a lethal amount plays the proper
-- death).
--
-- REAL TIME, NOT THE CLOCK. Vanilla drains on clock ticks, and DRAP jumps the
-- clock: TimeGate's turbo, EndingSequence's set_game_time, the game's own
-- speed-up. Draining by clock would empty Frank during a skip. So the amount
-- comes from os.clock() only, and the clock is read for one thing: a jump
-- larger than normal running means a skip, and that second is not drained.
--
-- A tick only lands when the second before it was live too, so a guard that
-- clears mid-second never lets a partial skip through.
--
-- Live means: option on, connected (offline is vanilla -- only the console's
-- drap_infinity_drain() debug override skips both), in game, past the
-- prologue, alive, game time moving (false in the pause menu and the map),
-- no turbo, no speed-up, no ending jump, no cutscene, no door load.
-- Vehicles drain, as they do in Infinity.
--
-- Damage is applied through DamageLink.apply_unshared, so the ticks are never
-- read back as hits. Instead one DamageLink block (80 points = 1000 HP) goes
-- out per full bar drained. The last tick goes through DeathLink.kill_player,
-- which verifies the death and falls back to playerDead(); that death is an
-- ordinary one and sends a DeathLink.
--
-- PlayerStats.apply() no longer refills HP: it only raises current HP by the
-- amount max HP rose, so doors, grants and save loads cannot undo the drain.

local Shared = require("DRAP/Shared")
local PlayerReady = require("DRAP/PlayerReady")

local M = Shared.create_module("InfinityDrain")

local BAR_HP = 1000
local DAMAGELINK_POINTS_PER_BAR = 80
local DEFAULT_RATE = 100        -- seconds per bar, vanilla
local MIN_RATE, MAX_RATE = 30, 600
local TICK_S = 1.0
-- Longest real gap one tick may cover. A hitch longer than this is not
-- drained in one lump.
local MAX_DT = 1.5
-- Clock ticks per real second at normal speed (measured 360). A sample that
-- moved more than twice that, plus slack, is a skip.
local NORMAL_TICKS_PER_S = 360
local JUMP_SLACK = 120

local enabled = false
local forced = false            -- console testing, ignores the connection
local rate = DEFAULT_RATE

local last_sample = nil         -- os.clock() of the previous sample
local last_clock = nil
local was_live = false
local carry = 0                 -- fractional HP owed
local drained_for_link = 0      -- HP drained toward the next DamageLink block
local last_why = nil
local grace_until = 0       -- os.clock() before which the drain holds off

------------------------------------------------------------
-- World access. One table so the unit test can replace it.
------------------------------------------------------------

local PSM_T  = "app.solid.PlayerStatusManager"
local PM_T   = "app.solid.PlayerManager"
local GM_T   = "app.solid.gamemastering.GameManager"
local GTS_T  = "app.solid.gamemastering.GameTimeSpeedManager"

local function call(obj, name, ...)
    if not obj then return nil end
    local args = { ... }
    return Shared.safe(function() return obj:call(name, table.unpack(args)) end)
end

local function flow_manager()
    local gm = sdk.get_managed_singleton(GM_T)
    return gm and call(gm, "get_MainInstance") or nil
end

local world = {}

function world.now() return os.clock() end

function world.connected()
    local Bridge = _G.AP and _G.AP.AP_BRIDGE
    return Bridge ~= nil and Bridge.is_connected ~= nil and Bridge.is_connected() == true
end

function world.in_game() return Shared.is_in_game() and Shared.past_prologue() end

function world.hp()
    return tonumber(call(sdk.get_managed_singleton(PSM_T), "getVitalNew"))
end

function world.dead()
    local psm = sdk.get_managed_singleton(PSM_T)
    local vc = call(psm, "get_PlayerVitalController")
    return call(vc, "get_IsDead") == true
end

function world.time_moving()
    return call(flow_manager(), "get_IsGameTimeMove") == true
end

function world.clock()
    local gm = sdk.get_managed_singleton(GM_T)
    if not gm then return nil end
    return tonumber(Shared.safe(function() return gm:get_field("mClock") end))
end

function world.speed_normal()
    local gts = sdk.get_managed_singleton(GTS_T)
    if not gts then return true end
    local mode = Shared.to_int(Shared.safe(function() return gts:get_field("SpeedMode") end))
    return mode == nil or mode == 0
end

function world.turbo()
    local TG = package.loaded["DRAP/TimeGate"]
    return TG ~= nil and TG.is_turbo_active ~= nil and TG.is_turbo_active() == true
end

function world.ending_busy()
    local ES = package.loaded["DRAP/effects/EndingSequence"]
    if not ES then return false end
    return (ES.is_pending and ES.is_pending()) or (ES.is_jumping and ES.is_jumping()) or false
end

--- No cutscene, no load, no door. A vehicle does not stop the drain.
function world.on_scene()
    return PlayerReady.ready(0) or PlayerReady.blocked_by() == "in a vehicle"
end

--- Apply n HP of Infinity damage. Returns true if the call went through.
function world.hurt(n)
    local pm = sdk.get_managed_singleton(PM_T)
    local cond = call(pm, "get_CurrentPlayerCondition")
    if not cond then return false end
    local fn = function() cond:call("requestInfinityModeDamage", n) end
    local DL = package.loaded["DRAP/trackers/DamageLink"]
    if DL and DL.apply_unshared then return DL.apply_unshared(fn, n) end
    return pcall(fn)
end

function world.kill(reason)
    local DeathLink = package.loaded["DRAP/trackers/DeathLink"]
    return DeathLink ~= nil and DeathLink.kill_player(reason) == true
end

function world.send_bar()
    local DL = package.loaded["DRAP/trackers/DamageLink"]
    if DL and DL.send_points then DL.send_points(DAMAGELINK_POINTS_PER_BAR) end
end

------------------------------------------------------------
-- Gating
------------------------------------------------------------

--- Why the drain is not running this second, or nil when it is.
--- @param dt number real seconds since the previous sample
--- @param clock number|nil mClock now
local function blocked(dt, clock)
    if not enabled and not forced then return "off" end
    if not forced and not world.connected() then return "not connected" end
    if not world.in_game() then return "not in game" end
    if world.now() < grace_until then return "grace" end
    if world.dead() then return "dead" end
    local hp = world.hp()
    if not hp or hp <= 0 then return "no hp" end
    if world.turbo() then return "turbo" end
    if not world.speed_normal() then return "time speed-up" end
    if world.ending_busy() then return "ending" end
    if not world.time_moving() then return "time stopped" end
    if clock and last_clock then
        local moved = clock - last_clock
        if moved < 0 or moved > dt * NORMAL_TICKS_PER_S * 2 + JUMP_SLACK then
            return "clock jumped"
        end
    end
    if not world.on_scene() then return "cutscene or load" end
    return nil
end

local function note(why)
    if why ~= last_why then
        last_why = why
        M.log("drain " .. (why and ("paused: " .. why) or "running"))
    end
end

local function hp_per_second()
    return BAR_HP / rate
end

local function drain(dt)
    carry = carry + hp_per_second() * math.min(dt, MAX_DT)
    local n = math.floor(carry)
    if n < 1 then return end
    carry = carry - n

    local hp = world.hp()
    if not hp then return end
    if n >= hp then
        M.log(string.format("drained to empty (%d HP left, tick %d)", hp, n))
        world.kill("Infinity drain")
        carry = 0
        return
    end
    if not world.hurt(n) then return end

    drained_for_link = drained_for_link + n
    while drained_for_link >= BAR_HP do
        drained_for_link = drained_for_link - BAR_HP
        world.send_bar()
    end
end

------------------------------------------------------------
-- Public
------------------------------------------------------------

--- From slot data.
--- @param on boolean
--- @param seconds_per_bar number|nil
function M.setup(on, seconds_per_bar)
    enabled = (on == true)
    local r = tonumber(seconds_per_bar) or DEFAULT_RATE
    rate = math.max(MIN_RATE, math.min(MAX_RATE, r))
    was_live = false
    carry = 0
    M.log(string.format("Infinity drain %s, %d s per bar (%.1f HP/s)",
        enabled and "ON" or "off", rate, hp_per_second()))
end

function M.is_enabled() return enabled or forced end

--- Hold the drain off for `seconds` (the 1 HP Trap: the next tick would kill).
--- Resets the partial HP owed, and the second after the grace is skipped like
--- after any other guard.
function M.grace(seconds)
    grace_until = math.max(grace_until, world.now() + (tonumber(seconds) or 0))
    carry = 0
    was_live = false
end

function M.on_frame()
    if not enabled and not forced then return end
    local now = world.now()
    if last_sample and now - last_sample < TICK_S then return end
    local dt = last_sample and (now - last_sample) or 0
    last_sample = now

    local clock = world.clock()
    local why = blocked(dt, clock)
    last_clock = clock
    note(why)

    if why then
        was_live = false
        carry = 0
        return
    end
    if was_live then drain(dt) end
    was_live = true
end

--- Testing hook: replace world access.
function M._set_world(w)
    for k, v in pairs(w) do world[k] = v end
end

--- Testing hook: back to a fresh start.
function M._reset()
    enabled, forced, rate = false, false, DEFAULT_RATE
    last_sample, last_clock, was_live = nil, nil, false
    carry, drained_for_link, last_why = 0, 0, nil
    grace_until = 0
end

local function status_line()
    return string.format("enabled(slot)=%s debug_override=%s rate=%d s/bar (%.1f HP/s) carry=%.2f toward next DamageLink block=%d/%d state=%s",
        tostring(enabled), tostring(forced), rate, hp_per_second(), carry,
        drained_for_link, BAR_HP, tostring(last_why or (M.is_enabled() and "running" or "off")))
end

--- Console: DEBUG OVERRIDE. Runs the drain with no slot and no connection,
--- for testing without an AP save. Real play is unchanged: without the
--- override, offline is vanilla. Needs DRAP armed (drap_activate_debug()),
--- since a dormant DRAP runs no frame work at all.
---   drap_infinity_drain(true)       on at the slot's rate (100 by default)
---   drap_infinity_drain(true, 30)   on at 30 s per bar
---   drap_infinity_drain(false)      override off, back to the slot setting
_G.drap_infinity_drain = function(on, seconds_per_bar)
    forced = (on ~= false)
    if seconds_per_bar then
        rate = math.max(MIN_RATE, math.min(MAX_RATE, tonumber(seconds_per_bar) or rate))
    end
    was_live = false
    carry = 0
    last_why = nil
    if forced then
        M.log("DEBUG OVERRIDE ACTIVE -- drain runs without a slot or connection")
        local Activation = package.loaded["DRAP/Activation"]
        if Activation and Activation.is_active and not Activation.is_active() then
            M.log("DRAP is dormant: run drap_activate_debug() or nothing will drain")
        end
    else
        M.log("debug override off -- back to the slot setting")
    end
    M.log(status_line())
end

_G.drap_infinity_drain_status = function()
    M.log(status_line())
end

return M
