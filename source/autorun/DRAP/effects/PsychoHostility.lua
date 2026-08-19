-- DRAP/effects/PsychoHostility.lua
-- Psycho Mode: survivors turn on the player once their scoop starts.
--
-- setLiveState(RAGE) is the same call the Hostile NPC Trap uses. Confirmed on
-- LIVE survivors rather than freshly spawned ones: the write holds, via the
-- NpcBaseInfo surface alone, for as long as it was watched.
--
-- Applied on a poll rather than once at unlock, because a scoop usually
-- unlocks before its survivors exist -- the engine creates their records
-- lazily on area entry. Re-checking also covers a survivor the engine calms
-- down again.
--
-- Covers all 48 targets, not just the ones in scoops: Bill Brenton and the
-- two Meyers have no scoop of their own. Those three are targets from the
-- moment they exist; the rest wait for their scoop to unlock. A survivor who
-- is dead, or whose scoop is done, is left alone.

local Shared = require("DRAP/Shared")
local SharedData = require("DRAP/SharedData")

local M = Shared.create_module("PsychoHostility")
M:set_throttle(1.0)

local NPC_MANAGER_TYPE = "app.solid.gamemastering.NpcManager"
local npc_mgr = M:add_singleton("npc", NPC_MANAGER_TYPE)

-- 12, not the 11 in NpcTracker's LIVE_STATE table. 12 is what the trap uses
-- and what was measured making an NPC hostile; the enum in NpcTracker
-- disagrees and has never been exercised for this value.
local LIVE_STATE_RAGE = 12

local raged = {}   -- stype -> true, so the log stays quiet after the first

local _name_to_stype = nil

local function name_to_stype(name)
    if not _name_to_stype then
        _name_to_stype = {}
        local rows = SharedData.survivors()
        if type(rows) == "table" then
            for _, row in ipairs(rows) do
                local n = tonumber(row.item_number)
                if row.name and n and _name_to_stype[row.name] == nil then
                    _name_to_stype[row.name] = n
                end
            end
        end
    end
    return _name_to_stype[name]
end

local function psycho_on()
    local su = AP and AP.ScoopUnlocker
    if not (su and su.is_psycho_mode) then return false end
    local ok, on = pcall(su.is_psycho_mode)
    return ok and on == true
end

--- Every target that should currently be hostile.
---
--- Keyed off the shared 48-name roster, not off scoop_survivors: Bill Brenton
--- and the two Meyers arrive without a scoop of their own, so walking the
--- scoops alone left three targets permanently friendly.
---
--- A target with a scoop turns hostile once that scoop is unlocked and stays
--- that way until it resolves. A target without one has nothing to wait for.
local function scoop_of_survivor()
    local map = {}
    for scoop_name, roster in pairs(SharedData.scoop_survivors()) do
        for _, name in ipairs(roster) do map[name] = scoop_name end
    end
    return map
end

local function current_targets()
    local out = {}
    local su = AP and AP.ScoopUnlocker
    local pg = AP and AP.effects and AP.effects.PsychoGoalEffects
    if not (su and pg and pg.all_targets) then return out end

    local owner = scoop_of_survivor()
    for _, name in ipairs(pg.all_targets()) do
        local scoop_name = owner[name]
        local active
        if not scoop_name then
            -- No scoop to unlock, so they are a target from the moment they
            -- exist.
            active = true
        else
            local ok = pcall(function()
                active = su.has_received_scoop(scoop_name)
                    and not su.is_scoop_completed(scoop_name)
            end)
            if not ok then active = false end
        end
        if active then
            local stype = name_to_stype(name)
            if stype then out[stype] = name end
        end
    end
    return out
end

local function make_hostile(mgr, stype, name)
    local info = Shared.safe(function()
        return mgr:call("searchInformation", stype)
    end)
    if not info then return end

    -- Leave the dead alone: a corpse keeps the state it died with, so writing
    -- RAGE onto one achieves nothing and muddies the log.
    local dead = Shared.safe(function() return info:call("isDead") end)
    if dead == true then return end

    local state = tonumber(Shared.safe(function()
        return info:get_field("mLiveState")
    end))
    if state == LIVE_STATE_RAGE then return end

    local ok = pcall(function() info:call("setLiveState", LIVE_STATE_RAGE) end)
    if ok and not raged[stype] then
        raged[stype] = true
        M.log(string.format("%s turned hostile", tostring(name)))
    end
end

function M.on_frame()
    if not M:should_run() then return end
    if not psycho_on() then return end
    if not Shared.is_in_game() then return end

    local mgr = npc_mgr:get()
    if not mgr then return end

    for stype, name in pairs(current_targets()) do
        make_hostile(mgr, stype, name)
    end
end

--- Clear the "already logged" set so a new run reports afresh.
function M.reset()
    raged = {}
end

_G.drap_psycho_hostility = function()
    if not psycho_on() then
        M.log("psycho mode is off -- nobody is being made hostile")
        return
    end
    local targets = current_targets()
    local n = 0
    for _ in pairs(targets) do n = n + 1 end
    M.log(string.format("%d live target(s) right now", n))
    local mgr = npc_mgr:get()
    for stype, name in pairs(targets) do
        local info = mgr and Shared.safe(function()
            return mgr:call("searchInformation", stype)
        end)
        local state = info and tonumber(Shared.safe(function()
            return info:get_field("mLiveState")
        end))
        M.log(string.format("  %-24s stype=%-3d state=%s%s",
            tostring(name), stype, tostring(state),
            state == LIVE_STATE_RAGE and "  (hostile)" or ""))
    end
end

return M
