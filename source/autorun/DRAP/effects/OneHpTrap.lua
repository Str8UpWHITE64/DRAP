-- DRAP/effects/OneHpTrap.lua
-- 1 HP Trap: Frank is left on one hit point. It never kills.
--
-- The damage is hp-1 through PlayerCondition.requestInfinityModeDamage, which
-- was measured exact in a story run (no flinch, no mode check). The amount is
-- always below current HP, so it cannot reach 0 -- addDamage taking HP to 0
-- is what leaves the player undead. An unreadable HP declines (stays banked)
-- rather than guessing; HP already at 1 counts as fired.
--
-- Run through DamageLink.apply_unshared so the drop is never read back as a
-- hit and broadcast (a 7000-HP drop would be a full block to everyone).
-- The Infinity drain's next tick would kill Frank at 1 HP, so it is held off
-- for a grace period afterwards.

local Shared = require("DRAP/Shared")
local ItemEffects = require("DRAP/ItemEffects")
local TrapBank = require("DRAP/TrapBank")
local PlayerReady = require("DRAP/PlayerReady")

local M = Shared.create_module("OneHpTrap")

local NAME = "1 HP Trap"
local DRAIN_GRACE_SECONDS = 10

local PSM_TYPE = "app.solid.PlayerStatusManager"
local PM_TYPE  = "app.solid.PlayerManager"

local function read_hp()
    local psm = sdk.get_managed_singleton(PSM_TYPE)
    if not psm then return nil end
    return tonumber(Shared.safe(function() return psm:call("getVitalNew") end))
end

--- @return boolean true if the trap is spent (applied, or Frank was already on 1)
function M.fire()
    if not Shared.is_in_game() then return false end
    if not PlayerReady.ready() then return false end

    local hp = read_hp()
    if not hp then
        M.log("HP unreadable -- declining")
        return false
    end
    hp = math.floor(hp)
    if hp < 1 then return false end         -- dead or dying: not ours to touch
    if hp == 1 then
        M.log("already on 1 HP -- nothing to do")
        return true
    end

    local pm = sdk.get_managed_singleton(PM_TYPE)
    local cond = pm and Shared.safe(function() return pm:call("get_CurrentPlayerCondition") end)
    if not cond then return false end

    local amount = hp - 1
    local fn = function() cond:call("requestInfinityModeDamage", amount) end
    local DL = package.loaded["DRAP/trackers/DamageLink"]
    local ok
    if DL and DL.apply_unshared then
        ok = DL.apply_unshared(fn, amount)
    else
        ok = pcall(fn)
    end
    if not ok then
        M.log("requestInfinityModeDamage failed -- declining")
        return false
    end

    local Drain = package.loaded["DRAP/effects/InfinityDrain"]
    if Drain and Drain.grace then Drain.grace(DRAIN_GRACE_SECONDS) end
    M.log(string.format("HP %d -> 1", hp))
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

--- Testing: fire it now, no server. Needs drap_activate_debug() only for the
--- usual frame work; this call itself goes straight to the effect.
_G.drap_trap_onehp = function()
    M.log("console -> " .. tostring(M.fire()))
end

return M
