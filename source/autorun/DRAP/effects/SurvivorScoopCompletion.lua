-- DRAP/effects/SurvivorScoopCompletion.lua
-- Auto-marks a scoop complete once all its rescuable survivors are rescued.
-- Scoop->survivor mapping comes from drdr_shared.json's `scoop_survivors`
-- (filtered against Locations.py's "Rescue X" so boss entries don't count).
--
-- Also exposes progress(scoop_name) for the tracker UI to tint partial scoops.
-- Complete_scoop() is idempotent so coexisting with the flag-based path
-- is safe -- whichever fires first wins.

local SharedData = require("DRAP/SharedData")

local M = {}

local Shared = require("DRAP/Shared")
local log = Shared.create_logger("SurvivorScoopCompletion")

-- Which survivor display names have been rescued this slot/seed.
-- Authoritative source is AP_BRIDGE's COMPLETED_CHECKS (persisted). We mirror
-- into this table so progress() and check_scoops() don't hit the bridge on
-- every call; sync on rescue events and on reapply().
local rescued = {}

-- Cached: survivor name -> list of scoops they belong to. Built from
-- SharedData.scoop_survivors() on first use.
local survivor_to_scoops = nil

local function build_reverse_index()
    if survivor_to_scoops then return end
    survivor_to_scoops = {}
    for scoop_name, survivors in pairs(SharedData.scoop_survivors()) do
        for _, sname in ipairs(survivors) do
            if not survivor_to_scoops[sname] then
                survivor_to_scoops[sname] = {}
            end
            table.insert(survivor_to_scoops[sname], scoop_name)
        end
    end
end

-- Is a specific scoop's full survivor set rescued? Doesn't touch ScoopUnlocker.
local function all_survivors_rescued(scoop_name)
    local survivors = SharedData.scoop_survivors()[scoop_name]
    if not survivors or #survivors == 0 then return false end
    for _, sname in ipairs(survivors) do
        if not rescued[sname] then return false end
    end
    return true
end

-- Fire complete_scoop for any scoop that's now fully rescued and not already
-- marked complete. Scoped to scoops that touch the provided survivor name,
-- or all scoops if name is nil (used by reapply()).
local function check_scoops(triggered_by_survivor)
    if not AP or not AP.ScoopUnlocker or not AP.ScoopUnlocker.complete_scoop then
        return
    end

    build_reverse_index()

    local candidates
    if triggered_by_survivor then
        candidates = survivor_to_scoops[triggered_by_survivor] or {}
    else
        candidates = {}
        for scoop_name in pairs(SharedData.scoop_survivors()) do
            table.insert(candidates, scoop_name)
        end
    end

    for _, scoop_name in ipairs(candidates) do
        if AP.ScoopUnlocker.is_scoop_completed
                and AP.ScoopUnlocker.is_scoop_completed(scoop_name) then
            -- already complete; skip
        elseif all_survivors_rescued(scoop_name) then
            log(string.format("All survivors rescued for '%s' -- marking complete", scoop_name))
            AP.ScoopUnlocker.complete_scoop(scoop_name)
        end
    end
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

-- Called from the existing NpcTracker callback in AP_DRDR_main.lua.
function M.on_survivor_rescued(friendly_name)
    if not friendly_name or friendly_name == "" then return end
    rescued[friendly_name] = true
    check_scoops(friendly_name)
end

-- Re-evaluate every scoop against what has been seen rescued. Safe to call
-- multiple times.
--
-- This used to rebuild `rescued` from the ledger's "Rescue <name>" checks.
-- That cannot tell one world from the next: a second game on the same seed
-- found Simone's check already sent, marked her rescued, completed "A Woman
-- in Despair" on the spot, and she could never be recruited again. The world
-- is the authority instead -- NpcTracker's poll re-reports anyone actually
-- standing in the Security Room after a reload, so a mid-run reload still
-- completes correctly, and a fresh world reports nobody.
function M.reapply()
    check_scoops(nil)
end

--- A new world on the same seed: nobody has been rescued in it yet.
--- Called from the reload path, not from reapply -- reapply also runs on
--- ordinary activation, after the poll may already have reported survivors,
--- and wiping there would lose them.
function M.reset_world()
    local n = 0
    for _ in pairs(rescued) do n = n + 1 end
    rescued = {}
    if n > 0 then
        log(string.format("new world -- forgot %d rescued survivor(s)", n))
    end
end

-- Returns (rescued_count, total_count) for a scoop. total_count = 0 means the
-- scoop has no rescuable survivors (e.g. pure psycho scoops like Cletus).
function M.progress(scoop_name)
    local survivors = SharedData.scoop_survivors()[scoop_name]
    if not survivors or #survivors == 0 then return 0, 0 end
    local n = 0
    for _, sname in ipairs(survivors) do
        if rescued[sname] then n = n + 1 end
    end
    return n, #survivors
end

-- No ItemEffects registration -- this module reacts to NpcTracker callbacks.
-- Kept for symmetry; state rebuilt via reapply() on save-load.
function M.register_all()
    local count = 0
    for _ in pairs(SharedData.scoop_survivors()) do count = count + 1 end
    log(string.format("Registered survivor-scoop auto-completion (%d scoops tracked)", count))
end

return M
