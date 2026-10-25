-- DRAP/effects/TeleportTrap.lua
-- Teleport Trap: Frank is sent to the Security Room and his followers are not.
--
-- The warp is DoorRandomizer.warp_to, the same simulated door entry as
-- drap_warp_home, with two differences:
--   leave_party  -- no carry. A warp leaves the party in the old area anyway
--                   (measured, NpcCarryover.lua); the engine's carry verdict is
--                   answered no for the moment of the jump so the Rooftop and
--                   Entrance Plaza, which have a real door to s136, agree.
--   no_redirect  -- door redirects are ignored for this one jump, or a trap
--                   fired on the Rooftop went wherever the vent was shuffled to.
-- No NPC record is written. A left-behind follower stays JOIN in its own area,
-- which is the vanilla state for a survivor who fell behind at a door.
--
-- It holds (declines, stays banked) while:
--   * Frank is on the way to Ending S: Isabela's departure scene has played
--     (flag 151, EV_EVENT56) or he is in the Clock Tower Tunnel (sb00-sb04).
--     The tunnel has no door back in, so a jump out of it strands the run
--     short of Ending S. Read straight from the game rather than from the
--     Overtime state, so it holds even if that state is late or wrong;
--   * PlayerReady says no (loading, door, cutscene, vehicle, settling);
--   * Jessie has not been met, or the flag cannot be read -- before her the
--     Security Room is reached by cutscene only;
--   * Overtime, or an ending sequence is pending -- a Security Room warp may
--     start Jessie's Discovery;
--   * a scripted escort is here: a loaded NPC in ESCORT (Brad), Isabela in
--     the party, or Frank piggy-backing someone.
-- Already in the Security Room: spent, no jump.
--
-- The Security Room is the start region and is never locked, so a warp there
-- reaches nothing logic does not already allow.

local Shared = require("DRAP/Shared")
local ItemEffects = require("DRAP/ItemEffects")
local TrapBank = require("DRAP/TrapBank")
local PlayerReady = require("DRAP/PlayerReady")

local M = Shared.create_module("TeleportTrap")

local NAME = "Teleport Trap"

-- The landing drap_warp_home uses (the s231 -> s136 door0 arrival).
local HOME_SCENE = "s136"
local HOME_POS = { x = 153.19, y = 9.32, z = 216.92 }
local HOME_ANGLE = { x = 0.0, y = 0.93, z = 0.0 }

local LIVE_STATE_ESCORT = 8

-- EV_EVENT56: the Overtime scene in which Frank leaves Isabela's hideout with
-- her for the tunnel. The event table puts him in sb00 straight after it.
local FLAG_TUNNEL_DEPARTURE = 151

local EFM_TYPE = "app.solid.gamemastering.EventFlagsManager"

local NPC_MGR_TYPE = "app.solid.gamemastering.NpcManager"
local AM_TYPE = "app.solid.gamemastering.AreaManager"
local PM_TYPE = "app.solid.PlayerManager"

local _notify_trap = Shared.lazy_notify_trap()

local last_hold = nil   -- the last reason logged, so a hold logs once

------------------------------------------------------------
-- World checks
------------------------------------------------------------

local function scoop_unlocker()
    return (_G.AP and _G.AP.ScoopUnlocker) or package.loaded["DRAP/ScoopUnlocker"]
end

local function met_jessie()
    local SU = scoop_unlocker()
    if not (SU and SU.has_met_jessie) then return false end
    local ok, v = pcall(SU.has_met_jessie)
    return ok and v == true
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

local function current_scene()
    local am = sdk.get_managed_singleton(AM_TYPE)
    local p = am and Shared.safe(function() return am:get_field("CurrentLevelPath") end)
    return p and tostring(p) or nil
end

local function flag_on(id)
    local efm = sdk.get_managed_singleton(EFM_TYPE)
    if not efm then return false end
    return Shared.safe(function() return efm:call("evFlagCheck", id) end) == true
end

--- On the Ending S route: the departure scene has played, or Frank is
--- standing in one of the Clock Tower Tunnel scenes.
local function ending_s_route()
    local scene = current_scene()
    if scene and scene:find("sb0%d") then return true end
    return flag_on(FLAG_TUNNEL_DEPARTURE)
end

--- A loaded NPC whose record is ESCORT. searchNpc answers a live controller
--- only for an NPC that is placed in the loaded area, so Brad's record left at
--- ESCORT elsewhere after Backup for Brad does not hold the trap forever.
local function escort_here()
    local mgr = sdk.get_managed_singleton(NPC_MGR_TYPE)
    if not mgr then return false end
    local list = Shared.safe(function() return mgr:get_field("NpcInfoList") end)
    if not list then return false end
    local count = tonumber(Shared.safe(function() return list:call("get_Count") end)) or 0
    for i = 0, count - 1 do
        local info = Shared.safe(function() return list:call("get_Item", i) end)
        if info then
            local state = tonumber(Shared.safe(function() return info:get_field("mLiveState") end))
            if state == LIVE_STATE_ESCORT then
                local dead = Shared.safe(function() return info:call("isDead") end)
                local stype = tonumber(Shared.safe(function()
                    return info:get_field("<Name>k__BackingField") end))
                if dead ~= true and stype then
                    local npc = Shared.safe(function() return mgr:call("searchNpc", stype) end)
                    if npc ~= nil then return true, stype end
                end
            end
        end
    end
    return false
end

local function isabela_in_party()
    local SF = (_G.AP and _G.AP.SceneFixups) or package.loaded["DRAP/SceneFixups"]
    if not (SF and SF.isabela_in_party) then return false end
    local ok, v = pcall(SF.isabela_in_party)
    return ok and v == true
end

--- PlayerCondition.isPiggyBack is in the dump; not yet read in game. A
--- failed read counts as not carrying -- the Isabela check backs it up.
local function piggy_back()
    local pm = sdk.get_managed_singleton(PM_TYPE)
    local cond = pm and Shared.safe(function() return pm:call("get_CurrentPlayerCondition") end)
    if not cond then return false end
    return Shared.safe(function() return cond:call("isPiggyBack") end) == true
end

--- Why it cannot fire right now, or nil when it can.
function M.blocked_by()
    if not Shared.is_in_game() then return "not in game" end
    if ending_s_route() then return "on the way to Ending S (Clock Tower Tunnel)" end
    if not PlayerReady.ready() then return "player not ready (" .. tostring(PlayerReady.blocked_by()) .. ")" end
    if not met_jessie() then return "Jessie not met yet" end
    if in_overtime() then return "Overtime" end
    if ending_busy() then return "ending sequence" end
    if isabela_in_party() then return "Isabela in the party" end
    if piggy_back() then return "carrying a survivor" end
    local esc, stype = escort_here()
    if esc then return "escort here (stype " .. tostring(stype) .. ")" end
    return nil
end

------------------------------------------------------------
-- Fire
------------------------------------------------------------

local function hold(why)
    if why ~= last_hold then
        M.log("holding: " .. why)
        last_hold = why
    end
    return false
end

--- @return boolean true when spent (warped, or already home)
function M.fire()
    local why = M.blocked_by()
    if why then return hold(why) end
    last_hold = nil

    local scene = current_scene()
    if scene and scene:find(HOME_SCENE, 1, true) then
        M.log("already in the Security Room -- nothing to do")
        _notify_trap(NAME, "Already in the Security Room")
        return true
    end

    local DR = (_G.AP and _G.AP.DoorRandomizer) or package.loaded["DRAP/DoorRandomizer"]
    if not (DR and DR.warp_to) then return hold("DoorRandomizer missing") end

    local ok, warped = pcall(DR.warp_to, HOME_SCENE, HOME_POS, HOME_ANGLE,
        "Security Room (Teleport Trap)", { leave_party = true, no_redirect = true })
    if not (ok and warped) then
        M.log("warp failed -- staying banked: " .. tostring(ok and "warp_to returned false" or warped))
        return false
    end
    M.log("warped to the Security Room from " .. tostring(scene) .. ", party left behind")
    _notify_trap(NAME, "Back to the Security Room -- your followers stayed put")
    return true
end

function M.register()
    TrapBank.register(NAME, { fire = M.fire })
    ItemEffects.register(NAME, {
        on_replay = "skip",
        apply = function()
            M.log(string.format("%s banked (%d owed)", NAME, TrapBank.banked(NAME)))
        end,
    })
end

--- Testing: fire it now, with every hold still applied. Needs
--- drap_activate_debug() (the warp refuses without a slot or Debug Mode).
_G.drap_trap_teleport = function()
    local why = M.blocked_by()
    if why then M.log("console: would hold -- " .. why) end
    M.log("console -> " .. tostring(M.fire()))
end

return M
