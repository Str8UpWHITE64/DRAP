-- DRAP/effects/CostumeTraps.lua
-- Traps that change what Frank is wearing.
--
--   Bald Trap                  the hair goes
--   Goddamnit, Donut! Trap   heart boxers and bare feet
--   Boxers Trap                stripped, via the engine's own change2Naked
--
-- CostumeRandomizer owns the changer; this only picks parts and ids.
-- CostumePart, from app.solid.CostumePart in the dump:
--     0=Body 1=Foot 2=Hat 3=Glasses 4=Watch 5=Camera 7=Outfit
--
-- The Costume enum is NOT descriptive -- 72 entries named Costume_0..Costume_70
-- -- so every id below was found by eye with drap_costume_cycle_* and is
-- recorded here because there is no way to derive it. Verified in game:
--     Hat 0   bald
--     Foot 0  barefoot
--     Body 35 heart boxers
--
-- These are deliberately NOT reverted on a timer. Frank changes clothes at the
-- changing rooms in vanilla, so the player already has a way out -- and being
-- stuck in boxers until you find one is the joke.
--
-- APPLIED ON AREA LOAD, NEVER IMMEDIATELY. Dressing Frank the moment a trap
-- fired crashed the game at random for every tester, on all three traps. The
-- costume randomizer only ever changes costume from the AreaManager load hook
-- and has never crashed, so traps hand themselves to that same path via
-- CostumeRandomizer.queue_trap. With Costume Chaos on, the queued trap
-- REPLACES that load's random outfit instead of racing it.

local Shared = require("DRAP/Shared")
local ItemEffects = require("DRAP/ItemEffects")
local TrapBank = require("DRAP/TrapBank")
local CostumeRandomizer = require("DRAP/effects/CostumeRandomizer")

local M = Shared.create_module("CostumeTraps")

local BALD    = "Bald Trap"
local DONUT   = "Goddamnit, Donut! Trap"
local BOXERS  = "Boxers Trap"

local PART_BODY, PART_FOOT, PART_HAT = 0, 1, 2

local BALD_HAT       = 0
local BAREFOOT       = 0
local HEART_BOXERS   = 35

local function notify(text)
    local Notify = package.loaded["DRAP/Notify"]
    if Notify and Notify.send then
        pcall(Notify.send, text, { duration = 5.0 })
    end
end

local function dress_bald()
    if not CostumeRandomizer.set_part(PART_HAT, BALD_HAT) then return false end
    M.log("bald trap applied")
    notify("Your hair is gone.")
    return true
end

local function dress_donut()
    -- Body first: a body swap can reset the other slots, so feet go after.
    if not CostumeRandomizer.set_part(PART_BODY, HEART_BOXERS) then return false end
    CostumeRandomizer.set_part(PART_FOOT, BAREFOOT)
    M.log("donut trap applied -- heart boxers, barefoot")
    notify("Goddamnit, Donut!")
    return true
end

-- change2Naked strips every slot in one call, so this needs no ids at all --
-- unlike the Donut trap, which is a hand-picked body and foot.
local function dress_boxers()
    if not CostumeRandomizer.set_naked() then return false end
    M.log("boxers trap applied")
    notify("You have been stripped to your boxers.")
    return true
end

--- Hand the trap to the costume randomizer's area-load hook. Queuing always
--- succeeds, so a trap that lands on a menu or between areas is not wasted and
--- does not need re-banking -- it simply dresses Frank on the next load.
local function queued(name, dress)
    return function()
        return CostumeRandomizer.queue_trap(name, dress)
    end
end

function M.register()
    TrapBank.register(BALD,   { fire = queued(BALD,   dress_bald) })
    TrapBank.register(DONUT,  { fire = queued(DONUT,  dress_donut) })
    TrapBank.register(BOXERS, { fire = queued(BOXERS, dress_boxers) })

    for _, name in ipairs({ BALD, DONUT, BOXERS }) do
        ItemEffects.register(name, {
            on_replay = "skip",
            apply = function()
                M.log(string.format("%s banked (%d owed)", name,
                    TrapBank.banked(name)))
            end,
        })
    end
end

-- Console helpers queue the same way the real traps do, so what is tested is
-- what ships. Walk through a door to see the result.
_G.drap_trap_bald   = function() CostumeRandomizer.queue_trap(BALD,   dress_bald) end
_G.drap_trap_donut  = function() CostumeRandomizer.queue_trap(DONUT,  dress_donut) end
_G.drap_trap_boxers = function() CostumeRandomizer.queue_trap(BOXERS, dress_boxers) end

--- Dress Frank immediately, bypassing the queue. For diagnosing the original
--- crash only -- this is the path that crashed testers.
_G.drap_trap_costume_now = function(which)
    local map = { bald = dress_bald, donut = dress_donut, boxers = dress_boxers }
    local fn = map[tostring(which or "bald"):lower()]
    if not fn then M.log("usage: drap_trap_costume_now('bald'|'donut'|'boxers')"); return end
    M.log("applying immediately -- this is the path that crashed")
    fn()
end

return M
