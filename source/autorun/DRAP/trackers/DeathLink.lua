-- DRAP/trackers/DeathLink.lua
-- Tracks player death via PlayerVitalController
-- and provides a DeathLink-compatible "kill player" trigger

local Shared = require("DRAP/Shared")
local PlayerReady = require("DRAP/PlayerReady")

local M = Shared.create_module("DeathLink")
M:set_throttle(0.25)  -- CHECK_INTERVAL_FRAMES = 15 at 60fps ≈ 0.25s

------------------------------------------------------------
-- Singleton Managers
------------------------------------------------------------

local psm_mgr = M:add_singleton("psm", "app.solid.PlayerStatusManager")
local pm_mgr  = M:add_singleton("pm", "app.solid.PlayerManager")
local gm_mgr  = M:add_singleton("gm", "app.solid.gamemastering.GameManager")

------------------------------------------------------------
-- Internal State
------------------------------------------------------------

-- Last InGameFlowManagerBase seen, kept only to notice when it changes.
--
-- It is NOT a cache any more. get_MainInstance can hand back a different
-- object without GameManager itself being replaced -- a log of two Psycho
-- runs 40s apart showed no GameManager transition at all -- and a call on a
-- stale one neither throws nor does anything: pcall returns true, the log
-- says "playerDead() invoked", and nobody dies. Re-reading it costs one
-- managed call, which is nothing next to a death that silently does not
-- happen.
local igfm_cached = nil
local last_is_dead = nil
local has_announced_death_this_life = false

-- A DeathLink from another world waits until Frank is on foot, out of
-- cutscenes and past any load screen. One is enough: dying once answers any
-- number of them.
local held_death = nil

-- Why the next death is not to be sent out, or nil. A received DeathLink
-- must not echo back, and the Psycho ending's scripted death (the trigger for
-- the Special Forces capture) must not kill the rest of the multiworld at
-- the moment the run is won. Nothing stopped either before: every death sent.
local quiet_death = nil

-- A kill made through Infinity damage, waiting to be seen to land.
local pending_kill = nil
-- Enough to kill from any health. 99999 was the measured lethal call.
local INFINITY_DEATH_DAMAGE = 99999
-- How long a kill gets to land before the fallback, and how long HP may sit
-- at 0 with the death animation still playing before he counts as stuck.
local KILL_VERIFY_AFTER = 2.0
local KILL_DYING_GRACE = 8.0

------------------------------------------------------------
-- Public Callbacks
------------------------------------------------------------

M.on_death_detected = nil
M.on_revive_detected = nil

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function get_vital_controller()
    local psm = psm_mgr:get()
    if not psm then return nil end

    -- Try backing field first
    local vc = Shared.get_field_value(psm, {"<PlayerVitalController>k__BackingField"})
    if vc then return vc end

    -- Try accessor method
    if psm.get_PlayerVitalController then
        local ok, v = pcall(psm.get_PlayerVitalController, psm)
        if ok then return v end
    end

    return nil
end

local function vital_is_dead(vc)
    if not vc then return nil end
    if vc.get_IsDead then
        local ok, v = pcall(vc.get_IsDead, vc)
        if ok then return v end
    end
    return nil
end

local function get_ingame_flow_manager()
    local gm = gm_mgr:get()
    if not gm then
        M.log("get_ingame_flow_manager: GameManager singleton is nil")
        return nil
    end

    local ok, v = pcall(function()
        return gm:call("get_MainInstance")
    end)

    if ok and v then
        if igfm_cached ~= nil and igfm_cached ~= v then
            M.log("InGameFlowManagerBase replaced -- the old one would have"
                .. " swallowed playerDead() silently")
        end
        igfm_cached = v
        return v
    end

    igfm_cached = nil
    M.log("get_ingame_flow_manager: gm:call(get_MainInstance) failed")
    return nil
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

--- The game's own death, with no animation: InGameFlowManagerBase.playerDead().
--- @return boolean true if the call went through
local function kill_via_player_dead(reason)
    local igfm = get_ingame_flow_manager()
    if not igfm then
        M.log("kill_player: InGameFlowManagerBase not available yet. reason=" .. tostring(reason))
        return false
    end

    if not igfm.playerDead then
        igfm_cached = nil
        M.log("kill_player: playerDead() not bound; cache cleared.")
        return false
    end

    local ok = pcall(igfm.playerDead, igfm)
    if ok then
        M.log("kill_player: playerDead() invoked. reason=" .. tostring(reason))
        return true
    end

    igfm_cached = nil
    M.log("kill_player: playerDead() call failed; cache cleared.")
    return false
end

local function read_hp()
    local psm = psm_mgr:get()
    if not psm then return nil end
    return tonumber(Shared.safe(function() return psm:call("getVitalNew") end))
end

--- Infinity Mode's damage, enough to kill. Measured in a story run: it has
--- no mode check, and a lethal amount plays the full death animation, where
--- playerDead() cuts straight to the end. The HP it takes is not a hit, so
--- DamageLink is told not to send it.
--- @return boolean true if the call went through -- NOT that he died
local function kill_via_infinity_damage(reason)
    local pm = pm_mgr:get()
    local cond = pm and Shared.safe(function() return pm:call("get_CurrentPlayerCondition") end)
    if not cond then return false end
    local hp = read_hp()
    local amount = math.max(INFINITY_DEATH_DAMAGE, (hp or 0) + 1000)
    local fn = function() cond:call("requestInfinityModeDamage", amount) end
    local DamageLink = package.loaded["DRAP/trackers/DamageLink"]
    local ok
    if DamageLink and DamageLink.apply_unshared then
        ok = DamageLink.apply_unshared(fn, hp or amount)
    else
        ok = pcall(fn)
    end
    if ok then
        M.log(string.format("kill_player: Infinity death (%d) at HP %s. reason=%s",
            amount, tostring(hp), tostring(reason)))
    end
    return ok == true
end

--- Kills the player (received DeathLink, lethal DamageLink, the drain).
---
--- A damage call going through is not a death -- a dodge or a grab can eat
--- it -- so the death is checked on the frame and playerDead() follows if it
--- did not take. That matters for quiet_death: left set after a death that
--- never happened, it would swallow the next real one.
--- @param reason string|nil The reason for death
--- @return boolean True if a death is on its way
function M.kill_player(reason)
    -- Avoid spamming if already dead
    local vc = get_vital_controller()
    if vc then
        local is_dead = vital_is_dead(vc)
        if is_dead == true then
            M.log("kill_player: already dead; ignoring. reason=" .. tostring(reason))
            return false
        end
    end

    if pending_kill then
        M.log("kill_player: a death is already on its way. reason=" .. tostring(reason))
        return true
    end

    if kill_via_infinity_damage(reason) then
        pending_kill = { reason = reason, at = os.clock(), stage = "infinity" }
        return true
    end
    M.log("kill_player: Infinity death unavailable, using playerDead()")
    return kill_via_player_dead(reason)
end

--- Follows an Infinity death up. Dead: done. HP at 0 but not dead yet: the
--- animation is still playing, wait. Still standing: playerDead(), and if
--- that does not take either, give up and clear quiet_death.
local function verify_pending_kill()
    local p = pending_kill
    if not p then return end
    if vital_is_dead(get_vital_controller()) == true then
        pending_kill = nil
        return
    end
    local elapsed = os.clock() - p.at
    if elapsed < KILL_VERIFY_AFTER then return end

    if p.stage == "infinity" then
        local hp = read_hp()
        if hp and hp <= 0 and elapsed < KILL_DYING_GRACE then return end
        M.log(string.format("kill_player: Infinity death did not take (HP %s after %.1fs); playerDead() instead",
            tostring(hp), elapsed))
        p.stage = "player_dead"
        p.at = os.clock()
        if kill_via_player_dead(p.reason) then return end
    end

    pending_kill = nil
    M.log("kill_player: no death after both routes. reason=" .. tostring(p.reason))
    if quiet_death then
        M.log("kill_player: clearing quiet_death (" .. tostring(quiet_death) .. ") so it cannot swallow a later death")
        quiet_death = nil
    end
end

local function kill_quietly(reason, why, killer)
    quiet_death = why
    local ok = (killer or M.kill_player)(reason)
    if not ok then quiet_death = nil end
    return ok
end

--- A death that is not sent as a DeathLink: the Psycho ending's. Stays on
--- playerDead(): the capture-vs-game-over branch (EV_CASE_FAIL 2326) was
--- measured on that route, and a damage death may not take the same one.
function M.kill_without_sending(reason)
    local vc = get_vital_controller()
    if vc and vital_is_dead(vc) == true then
        M.log("kill_without_sending: already dead; ignoring. reason=" .. tostring(reason))
        return false
    end
    return kill_quietly(reason, tostring(reason), kill_via_player_dead)
end

--- A DeathLink from another player. Kills now if Frank is ready, else holds
--- it for the frame loop. Lethal DamageLink uses kill_player and is not held.
local function kill_from_link(reason)
    return kill_quietly(reason, "a received DeathLink")
end

function M.receive(reason)
    if not held_death and PlayerReady.ready() then
        return kill_from_link(reason)
    end
    if not held_death then
        M.log(string.format("DeathLink held (%s): %s", PlayerReady.blocked_by(), tostring(reason)))
    end
    held_death = reason
    return false
end

------------------------------------------------------------
-- Death Polling
------------------------------------------------------------

local function poll_death_state()
    local vc = get_vital_controller()
    if not vc then return end

    local is_dead = vital_is_dead(vc)

    -- First read: initialize state
    if last_is_dead == nil and is_dead ~= nil then
        last_is_dead = is_dead
        has_announced_death_this_life = (is_dead == true)
        return
    end

    -- Revive detection
    if last_is_dead == true and is_dead == false then
        has_announced_death_this_life = false
        quiet_death = nil
        if M.on_revive_detected then
            pcall(M.on_revive_detected)
        end
    end

    -- Death detection
    if (last_is_dead == false or last_is_dead == nil) and is_dead == true then
        if not has_announced_death_this_life then
            has_announced_death_this_life = true
            if quiet_death then
                M.log("Detected player death -- " .. quiet_death .. ", not sent.")
                quiet_death = nil
            else
                M.log("Detected player death.")
                if M.on_death_detected then
                    pcall(M.on_death_detected)
                end
            end
        end
    end

    last_is_dead = is_dead
end

------------------------------------------------------------
-- Per-frame Update
------------------------------------------------------------

function M.on_frame()
    if not M:should_run() then return end
    poll_death_state()
    verify_pending_kill()
    if held_death and PlayerReady.ready() then
        local reason = held_death
        held_death = nil
        M.log("releasing a held DeathLink")
        kill_from_link(reason)
    end
end

--- Receive a DeathLink through the real path, holding and all, to test the
--- deferral offline.
_G.drap_deathlink_receive = function()
    M.receive("DeathLink: console test")
end

return M