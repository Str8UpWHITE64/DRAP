-- DRAP/effects/PsychoGoalEffects.lua
-- The Psycho goal: the player wins by killing a configurable number of
-- survivors. Savior turned inside out, and built beside it on purpose --
-- the counting, milestone and goal-send shape are the same, only the event
-- and the location names differ.
--
-- Only active when AP.Goal == 4. Otherwise the module is inert.
--
-- Only kills the PLAYER landed count. A survivor the zombies reach is a
-- target lost for the run, not a check earned, so the count comes from the
-- "Kill X" checks the tracker sends rather than from deaths.
--
-- Counting is based on AP_BRIDGE.has_completed_check, which persists across
-- disconnects, so the running total survives reconnects and crashes without
-- needing its own save file.

local SharedData = require("DRAP/SharedData")
local Shared = require("DRAP/Shared")

local M = {}

local GOAL_PSYCHO = 4
local GOAL_LOCATION_NAME = "Psycho: Kill enough survivors to escape"

local goal_sent = false

local log = Shared.create_logger("PsychoGoalEffects")

-- Every survivor in the mall: the 45 from scoop_survivors plus the 3 who
-- arrive without a scoop of their own. All 48 are targets.
local FREE_SURVIVORS = { "Bill Brenton", "Jeff Meyer", "Natalie Meyer" }

local _survivor_universe = nil

local function survivor_universe()
    if _survivor_universe then return _survivor_universe end
    _survivor_universe = {}
    local seen = {}
    for _, survivors in pairs(SharedData.scoop_survivors()) do
        for _, name in ipairs(survivors) do
            if not seen[name] then
                seen[name] = true
                table.insert(_survivor_universe, name)
            end
        end
    end
    for _, name in ipairs(FREE_SURVIVORS) do
        if not seen[name] then
            seen[name] = true
            table.insert(_survivor_universe, name)
        end
    end
    return _survivor_universe
end

-- Iterates known survivors so the count is bounded and cannot pick up the
-- other "Kill ..." locations -- the psychopath kills and the zombie tiers
-- share that prefix and must never count toward this goal.
local function count_killed()
    if not AP or not AP.AP_BRIDGE or not AP.AP_BRIDGE.has_completed_check then
        return 0
    end
    local n = 0
    for _, name in ipairs(survivor_universe()) do
        if AP.AP_BRIDGE.has_completed_check("Kill " .. name) then
            n = n + 1
        end
    end
    return n
end

local KILL_MILESTONES = { 5, 10, 15, 20, 25, 30, 35, 40, 45, 48 }

local function send_kill_milestones()
    if not (AP and AP.AP_BRIDGE and AP.AP_BRIDGE.check) then return end
    local n = count_killed()
    for _, threshold in ipairs(KILL_MILESTONES) do
        if n >= threshold then
            -- The bridge dedupes, so re-sending a met milestone is free, which
            -- is what makes this safe on reapply as well as on each kill.
            pcall(AP.AP_BRIDGE.check,
                string.format("Kill %d survivors", threshold))
        end
    end
end

local function is_psycho_goal()
    return AP and AP.Goal == GOAL_PSYCHO
end

local function target()
    return (AP and tonumber(AP.NumberOfKills)) or 25
end

local function try_send_goal()
    if goal_sent then return end
    if not is_psycho_goal() then return end
    local n = count_killed()
    local t = target()
    if n >= t then
        log(string.format("Psycho threshold reached (%d/%d). Sending goal check.",
            n, t))
        if AP.AP_BRIDGE and AP.AP_BRIDGE.check then
            AP.AP_BRIDGE.check(GOAL_LOCATION_NAME)
            goal_sent = true
        end
    end
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

--- Called from the NpcTracker kill-attribution callback, after the
--- "Kill <name>" check itself has been sent.
function M.on_survivor_killed(friendly_name)
    send_kill_milestones()
    if not is_psycho_goal() then return end
    try_send_goal()
end

--- Re-evaluate after save-load or reconnect, in case the threshold was met
--- but the goal check never went out. Idempotent; a second send is harmless.
--- Also covers a run that killed people before connecting, which has no kill
--- event left to fire.
function M.reapply()
    send_kill_milestones()
    if not is_psycho_goal() then return end
    try_send_goal()
end

--- Progress for the GUI: how many of the target have been killed.
function M.progress()
    return count_killed(), target()
end

--- The 48 targets, as names. The one definition of the roster -- anything
--- else that needs it (hostility, for one) reads it from here rather than
--- rebuilding it, because the free three are easy to forget and were.
function M.all_targets()
    return survivor_universe()
end

--- Is this NPC one of the 48 targets?
---
--- The kill tracker reports every player kill, which is the honest thing for
--- it to do, but plenty of what it sees is not a target: the Hostile NPC Trap
--- spawns cutscene NPCs (stypes 59+) and rages them, and the story NPCs --
--- Otis, Brad, Isabela, Barnaby -- sit in the same range as the survivors.
--- None of them may send a check or move the count.
function M.is_target(friendly_name)
    if not friendly_name then return false end
    for _, name in ipairs(survivor_universe()) do
        if name == friendly_name then return true end
    end
    return false
end

function M.is_active()
    return is_psycho_goal()
end

function M.register_all()
    if is_psycho_goal() then
        log(string.format("Psycho goal active: target = %d kills", target()))
    end
end

_G.drap_psycho_status = function()
    local n, t = M.progress()
    log(string.format("psycho: %d/%d killed, goal=%s, sent=%s",
        n, t, tostring(AP and AP.Goal), tostring(goal_sent)))
    local missing = {}
    for _, name in ipairs(survivor_universe()) do
        if not (AP and AP.AP_BRIDGE and AP.AP_BRIDGE.has_completed_check
                and AP.AP_BRIDGE.has_completed_check("Kill " .. name)) then
            table.insert(missing, name)
        end
    end
    table.sort(missing)
    log(string.format("still alive or lost (%d): %s", #missing,
        table.concat(missing, ", ")))
end

return M
