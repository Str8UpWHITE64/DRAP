-- DRAP/effects/GasTrap.lua
-- Knockout Gas Trap: Frank is hit with the powder the raincoat cultists throw.
-- He is blinded and bent over until he wiggles free or the timer runs out.
--
-- Measured in game (2026-10-17). Hitting him with the blind or
-- stun damage type is only a one second flinch. What works is the game's own
-- route: setUnsteadyTimer(PL_UNSTEADY_CULT_BLIND, n) and then
-- setUnSteadyMotion(), after which the game puts him into SpControlStatus 24
-- (UnSteadyCultBlind) by itself, with the "regain footing" prompt, and counts
-- the timer down once a second. Entering status 24 directly also sticks, but
-- skips the game's setup, so it is not used. ActionLeaveSpStatus(24) frees him
-- at once.
--
-- The game does not end the status when its timer reaches zero: Frank has to
-- press the wiggle button (the "Regain footing" prompt). So the trap releases
-- him itself at zero, and the deadline is only a backup.
--
-- Length: 12 s. Wiggling free takes a few seconds, so this is felt without
-- being a stall; it is shorter than the 30 s of the other timed traps because
-- he can do almost nothing meanwhile. The watchdog forces him out 3 s after
-- the timer should have run out, so he cannot stay stuck.
--
-- It holds (declines, stays banked) while:
--   * PlayerReady says no (loading, door, cutscene, vehicle, settling);
--   * Jessie has not been met, Overtime, or an ending sequence is pending;
--   * Frank is in any special-control status already (carrying or shouldering
--     someone, skateboard, mower, a grapple, an earlier gas): status 0 only;
--   * he is piggy-backing a survivor.
--
-- The timer is left at its last value when he leaves the status (measured),
-- so once he is out it is put back to the idle state the game shows at rest.

local Shared = require("DRAP/Shared")
local ItemEffects = require("DRAP/ItemEffects")
local TrapBank = require("DRAP/TrapBank")
local PlayerReady = require("DRAP/PlayerReady")

local M = Shared.create_module("GasTrap")

local NAME = "Knockout Gas Trap"
local DURATION = 12         -- seconds, the game's unsteady timer (Int32)
local MARGIN = 3.0          -- watchdog: force him out this long after the timer
local ENTER_WAIT = 2.0      -- the status must show within this, or it did nothing
local TICK = 0.1

local PM_TYPE = "app.solid.PlayerManager"
local UNSTEADY_CULT_BLIND = 4       -- PL_UNSTEADY_TYPE
local UNSTEADY_INVALID = -1         -- what the type reads at rest
local SP_NONE = 0
local SP_CULT_BLIND = 24            -- SpControlStatusType.UnSteadyCultBlind

local _notify_trap = Shared.lazy_notify_trap()

local active = nil          -- { started, deadline, entered }
local last_tick = 0
local last_hold = nil
local was_in_game = false
local queued = false        -- console request, run on the next frame

------------------------------------------------------------
-- Player and world
------------------------------------------------------------

local function player_cond()
    local pm = sdk.get_managed_singleton(PM_TYPE)
    return pm and Shared.safe(function() return pm:call("get_CurrentPlayerCondition") end)
end

local function sp_status(cond)
    return tonumber(Shared.safe(function() return cond:call("get_SpControlStatus") end))
end

local function unsteady_type(cond)
    return tonumber(Shared.safe(function() return cond:call("get_UnSteadyType") end))
end

local function in_overtime()
    local S = package.loaded["DRAP/scoops/ScoopState"]
    if not (S and S.is_endgame_reached) then return false end
    local ok, v = pcall(S.is_endgame_reached)
    return ok and v == true
end

local function ending_busy()
    local ES = package.loaded["DRAP/effects/EndingSequence"]
    if not ES then return false end
    return (ES.is_pending and ES.is_pending()) or (ES.is_jumping and ES.is_jumping()) or false
end

--- Why it cannot fire right now, or nil when it can.
function M.blocked_by()
    if not Shared.is_in_game() then return "not in game" end
    if active then return "already gassed" end
    if not PlayerReady.ready() then
        return "player not ready (" .. tostring(PlayerReady.blocked_by()) .. ")"
    end
    if not Shared.past_prologue() then return "Jessie not met yet" end
    if in_overtime() then return "Overtime" end
    if ending_busy() then return "ending sequence" end
    local cond = player_cond()
    if not cond then return "no player condition" end
    local sp = sp_status(cond)
    if sp == nil then return "status unreadable" end
    if sp ~= SP_NONE then return "special status " .. tostring(sp) end
    if Shared.safe(function() return cond:call("isPiggyBack") end) == true then
        return "carrying a survivor"
    end
    return nil
end

------------------------------------------------------------
-- Effect
------------------------------------------------------------

--- Put the unsteady timer back to the idle state, if it is still ours.
local function reset_timer(cond)
    if unsteady_type(cond) ~= UNSTEADY_CULT_BLIND then return end
    Shared.safe(function() cond:call("setUnsteadyTimer", UNSTEADY_INVALID, 0) end)
    M.log(string.format("unsteady timer reset (type now %s)", tostring(unsteady_type(cond))))
end

local function finish(why, force_leave, watchdog)
    local cond = player_cond()
    if cond then
        if force_leave and sp_status(cond) == SP_CULT_BLIND then
            Shared.safe(function() cond:call("ActionLeaveSpStatus", SP_CULT_BLIND, true, true) end)
            if watchdog then M.log("watchdog: forced Frank out of the powder status") end
        end
        reset_timer(cond)
    end
    if active and active.entered_at then
        M.log(string.format("Frank was in the powder status for %.1f s", os.clock() - active.entered_at))
    end
    M.log("gas over (" .. why .. ")")
    active = nil
end

local function hold(why)
    if why ~= last_hold then
        M.log("holding: " .. why)
        last_hold = why
    end
    return false
end

--- @return boolean true when spent
function M.fire()
    local why = M.blocked_by()
    if why then return hold(why) end
    last_hold = nil

    local cond = player_cond()
    local ok = Shared.safe(function()
        cond:call("setUnsteadyTimer", UNSTEADY_CULT_BLIND, DURATION)
        cond:call("setUnSteadyMotion")
        return true
    end)
    if ok ~= true then
        M.log("could not set the unsteady state -- staying banked")
        return false
    end
    local now = os.clock()
    active = { started = now, deadline = now + DURATION + MARGIN, entered = false }
    M.log(string.format("gassed for %d s (watchdog at %.0f s)", DURATION, DURATION + MARGIN))
    _notify_trap(NAME, "The cultists' powder -- wiggle free")
    return true
end

local function tick()
    if not active then return end
    local now = os.clock()
    local cond = player_cond()
    if not cond then return end
    local sp = sp_status(cond)

    if sp == SP_CULT_BLIND then
        if not active.entered then active.entered_at = now end
        active.entered = true
        -- Measured: the game counts the timer to zero but leaves the
        -- status on until Frank presses the wiggle button, so release him
        -- when it hits zero, with the deadline as the backup.
        local left = tonumber(Shared.safe(function() return cond:get_field("CurrentUnSteadyTimer") end))
        if left and left <= 0.05 and now - active.started >= 1.0 then
            return finish("timer reached zero", true)
        end
        if now >= active.deadline then return finish("watchdog deadline", true, true) end
        return
    end
    if active.entered then
        return finish("Frank is free")                  -- wiggled out, or the timer ended
    end
    if now - active.started >= ENTER_WAIT then
        return finish("the status never showed")
    end
end

re.on_frame(function()
    local ig = Shared.is_in_game()
    if not ig then
        if was_in_game and active then
            M.log("left play while gassed -- dropped")
            active = nil
        end
        was_in_game = false
        return
    end
    was_in_game = true
    if queued then
        queued = false
        M.log("console -> " .. tostring(M.fire()))
    end
    local now = os.clock()
    if now - last_tick < TICK then return end
    last_tick = now
    local ok, err = pcall(tick)
    if not ok then M.log.warn("tick failed: " .. tostring(err)) end
end)

------------------------------------------------------------
-- Registration
------------------------------------------------------------

function M.register()
    TrapBank.register(NAME, { fire = M.fire })
    ItemEffects.register(NAME, {
        on_replay = "skip",
        apply = function()
            M.log(string.format("%s banked (%d owed)", NAME, TrapBank.banked(NAME)))
        end,
    })
end

function M.is_active() return active ~= nil end

-- Testing, needs drap_activate_debug(): fire on the next frame, every hold
-- still applied.
_G.drap_gas_trap = function()
    local why = M.blocked_by()
    if why then M.log("console: would hold -- " .. why) end
    queued = true
end
_G.drap_gas_status = function()
    local cond = player_cond()
    M.log(string.format("active=%s sp=%s utype=%s ready=%s",
        tostring(active ~= nil),
        tostring(cond and sp_status(cond)),
        tostring(cond and unsteady_type(cond)),
        tostring(PlayerReady.ready())))
end

return M
