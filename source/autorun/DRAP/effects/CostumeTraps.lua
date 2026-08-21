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

local function fire_bald()
    if not CostumeRandomizer.set_part(PART_HAT, BALD_HAT) then return false end
    M.log("bald trap applied")
    notify("Your hair is gone.")
    return true
end

local function fire_donut()
    -- Body first: a body swap can reset the other slots, so feet go after.
    if not CostumeRandomizer.set_part(PART_BODY, HEART_BOXERS) then return false end
    CostumeRandomizer.set_part(PART_FOOT, BAREFOOT)
    M.log("donut trap applied -- heart boxers, barefoot")
    notify("Goddamnit, Donut!")
    return true
end

-- change2Naked strips every slot in one call, so this needs no ids at all --
-- unlike the Donut trap, which is a hand-picked body and foot.
local function fire_boxers()
    if not CostumeRandomizer.set_naked() then return false end
    M.log("boxers trap applied")
    notify("You have been stripped to your boxers.")
    return true
end

--- Declines while Frank is not spawned, so a trap landing on the title screen
--- is re-banked by TrapBank instead of being wasted.
local function guarded(fn)
    return function()
        if not Shared.is_in_game() then return false end
        if not CostumeRandomizer.player_ready() then return false end
        return fn() ~= false
    end
end

function M.register()
    TrapBank.register(BALD,    { fire = guarded(fire_bald) })
    TrapBank.register(DONUT,   { fire = guarded(fire_donut) })
    TrapBank.register(BOXERS,  { fire = guarded(fire_boxers) })

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

_G.drap_trap_bald = function()
    if not fire_bald() then M.log("player not ready") end
end

_G.drap_trap_donut = function()
    if not fire_donut() then M.log("player not ready") end
end

_G.drap_trap_boxers = function()
    if not fire_boxers() then M.log("player not ready") end
end

return M
