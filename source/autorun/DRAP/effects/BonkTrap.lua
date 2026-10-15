-- DRAP/effects/BonkTrap.lua
-- Bonk Trap: Frank is knocked about, as if a zombie had hit him.
--
-- The knockback itself is KnockbackLink's (requestDamage with damage 0 and a
-- random one of the five confirmed reactions). This is only the trap around
-- it. It works with KnockbackLink off, and is not rebroadcast over it.
--
-- TrapBank owns how many are owed. A bonk during a cutscene, a door load or
-- in a vehicle does the wrong thing, so it declines until PlayerReady says
-- Frank is free, and stays banked.

local Shared = require("DRAP/Shared")
local ItemEffects = require("DRAP/ItemEffects")
local TrapBank = require("DRAP/TrapBank")
local PlayerReady = require("DRAP/PlayerReady")

local M = Shared.create_module("BonkTrap")

local BONK = "Bonk Trap"

local function fire()
    if not Shared.is_in_game() then return false end
    if not PlayerReady.ready() then return false end
    local Knock = package.loaded["DRAP/trackers/KnockbackLink"]
        or require("DRAP/trackers/KnockbackLink")
    return Knock.bonk("Bonk Trap") ~= false
end

function M.register()
    TrapBank.register(BONK, { fire = fire })
    ItemEffects.register(BONK, {
        on_replay = "skip",
        apply = function()
            M.log(string.format("%s banked (%d owed)", BONK, TrapBank.banked(BONK)))
        end,
    })
end

return M
