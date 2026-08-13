-- DRAP/effects/UnlockItemSpawns.lua
-- Make the Security Room's post-clear weapons spawn when their item arrives.
--
-- The Laser Sword and Real Mega Buster normally only appear in the Security
-- Room once the game has been cleared, which most runs never do. Under
-- Restricted Item Mode that made them unreachable: the item can be sent, but
-- there is nothing in the world to pick up.
--
-- Each has its own single-entry layout file with an EVENT_APPEAR of 0 and
-- CHECK=128, loaded by an ItemLayoutRegistor in GameFlowByFlags mode. The
-- condition is one event flag, read out of GameFlowFlagsDatas[0].mEventFlag
-- and confirmed in game by toggling each:
--
--   2861  Real Mega Buster  ITL_itemlayout136_bm_UD
--   2865  Laser Sword       ITL_itemlayout136_bs_UD
--
-- The two books in the same Security Room group (Infinite Durability 2863,
-- Blender 2825) are deliberately NOT here. BookSkills grants a book's effect
-- through a checkItemSkill hook, so receiving one works without ever holding
-- a copy -- spawning them would add nothing.
--
-- Setting the flag makes the item spawn on the next load of the Security Room,
-- so receiving one mid-run works without a reload -- the player just has to
-- walk back in.
--
-- This does not replace granting the item. Non-restricted runs still get it
-- handed over as before; the spawn is what makes it obtainable in Restricted.

local M = {}

local Shared = require("DRAP/Shared")
local ItemEffects = require("DRAP/ItemEffects")
local log = Shared.create_logger("UnlockItemSpawns")
M.log = log

local safe = Shared.safe

local EFM_TYPE = "app.solid.gamemastering.EventFlagsManager"

-- AP item name -> the flag that makes its Security Room placement load.
local UNLOCK_FLAG = {
    ["Real Mega Buster"] = 2861,
    ["Laser Sword"] = 2865,
}

local function set_flag(flag_id)
    local efm = sdk.get_managed_singleton(EFM_TYPE)
    if not efm then return false end
    -- Already on is the common case on replay; skip the write so the flag
    -- trace stays readable.
    local cur = safe(function() return efm:call("evFlagCheck", flag_id) end)
    if cur == true then return true end
    return pcall(function() efm:call("evFlagOn", flag_id) end)
end

--- Turn on the spawn flag for one item. Safe to call repeatedly.
function M.unlock(item_name)
    local flag = UNLOCK_FLAG[item_name]
    if not flag then return false end
    if set_flag(flag) then
        log(string.format("%s: flag %d on -- it will be in the Security Room "
            .. "next time you load it", item_name, flag))
        return true
    end
    log.warn(string.format("%s: could not set flag %d", item_name, flag))
    return false
end

--- Re-apply everything already received. The bridge replays items on
--- reconnect, but a fresh save starts with the flags clear, so the flags have
--- to be re-set rather than assumed.
function M.reapply()
    local bridge = _G.AP and _G.AP.AP_BRIDGE
    if not (bridge and bridge.has_item_name) then return 0 end
    local n = 0
    for name in pairs(UNLOCK_FLAG) do
        local ok, held = pcall(bridge.has_item_name, name)
        if ok and held == true and M.unlock(name) then n = n + 1 end
    end
    if n > 0 then
        log(string.format("re-applied %d unlock flag(s)", n))
    end
    return n
end

function M.register()
    local count = 0
    for name in pairs(UNLOCK_FLAG) do
        ItemEffects.register(name, {
            -- Replay must apply: a new save clears the flags, and the item is
            -- still in the player's list, so skipping would leave it
            -- permanently unspawnable.
            on_replay = "apply",
            apply = function(ctx) M.unlock(name) end,
        })
        count = count + 1
    end
    log(string.format("Registered %d Security Room unlock handler(s)", count))
end

_G.drap_unlocks = function()
    for name, flag in pairs(UNLOCK_FLAG) do
        local efm = sdk.get_managed_singleton(EFM_TYPE)
        local on = efm and safe(function()
            return efm:call("evFlagCheck", flag)
        end)
        log(string.format("  %-28s flag %d = %s", name, flag, tostring(on)))
    end
end

return M
