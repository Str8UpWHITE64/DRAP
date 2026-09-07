-- DRAP/effects/ConvictRespawnTrap.lua
-- Each copy of the trap puts the convicts back once.
--
-- Vanilla gives three encounters because it gives three days, and
-- SET_PRISONER_1DAY marks a day's encounter as spent. ScoopSanity freezes the
-- clock, so the day never advances and only that marker is ever consulted --
-- they come once and never again. Clearing it brings them back on the next
-- entry to Leisure Park; the area transition is what re-runs the spawn.
--
-- TrapBank owns how many are owed. This file is one attempt, which declines
-- until the player has the scoop and the encounter is actually spent.
--
-- Flags are the only handle on them: they are not NpcBaseInfo records (a dump
-- with them alive shows only Sophie Richard) and not Em4eManager, whose list
-- stayed empty and whose EV_EM4E_* flags never moved. Checked 2026-08-09 --
-- don't go back down either road.

local Shared = require("DRAP/Shared")
local ItemEffects = require("DRAP/ItemEffects")
local TrapBank = require("DRAP/TrapBank")

local M = Shared.create_module("ConvictRespawnTrap")

local efm_mgr = M:add_singleton("efm", "app.solid.gamemastering.EventFlagsManager")

local TRAP_ITEM = "Convicts Respawn Trap"
local SCOOP_NAME = "The Convicts"

local FLAG_DAY1 = 445      -- SET_PRISONER_1DAY -- "this encounter is spent"
local FLAG_PRISONER_DIE = 1299
-- Each prisoner also keeps his own death record (EV_700_PRISONER01/02_DIE,
-- the 700 being Leisure Park). Left set, the respawn placed two of them as
-- corpses (tester report).
local FLAG_PRISONER01_DIE = 3332
local FLAG_PRISONER02_DIE = 3333

------------------------------------------------------------
-- Flags
------------------------------------------------------------

local function flag_get(id)
    local efm = efm_mgr:get()
    if not efm then return nil end
    local ok, v = pcall(function() return efm:call("evFlagCheck", id) end)
    if not ok then return nil end
    return v == true
end

local function flag_off(id)
    local efm = efm_mgr:get()
    if not efm then return false end
    return pcall(function() efm:call("evFlagOff", id) end)
end

local function scoop_received()
    local SU = AP and AP.ScoopUnlocker
    if not (SU and SU.has_received_scoop) then return false end
    local ok, v = pcall(SU.has_received_scoop, SCOOP_NAME)
    return ok and v == true
end

------------------------------------------------------------
-- The respawn
------------------------------------------------------------

--- Declines by returning false, which costs nothing and leaves it banked.
local function try_respawn()
    if not scoop_received() then return false end

    -- 445 off means they are already out there.
    if flag_get(FLAG_DAY1) ~= true then return false end

    -- Both flags below are how the Kill the convicts check is spotted, so
    -- give the tracker its turn before either is wiped.
    if AP and AP.EventTracker and AP.EventTracker.poll_event_flags then
        pcall(AP.EventTracker.poll_event_flags)
    end

    if not flag_off(FLAG_DAY1) then
        M.log.warn("could not clear SET_PRISONER_1DAY -- staying banked")
        return false
    end
    -- Gates nothing, but leaving it set while they are alive reads as a lie.
    flag_off(FLAG_PRISONER_DIE)
    -- These two do gate: a prisoner whose own record says dead comes back dead.
    flag_off(FLAG_PRISONER01_DIE)
    flag_off(FLAG_PRISONER02_DIE)

    M.log("convicts respawn armed -- they return on the next entry to Leisure Park")
    local Notify = package.loaded["DRAP/Notify"] or require("DRAP/Notify")
    if Notify and Notify.send then
        pcall(Notify.send, "The convicts are back in Leisure Park.",
              { duration = 5.0 })
    end
    return true
end

function M.register()
    TrapBank.register(TRAP_ITEM, { fire = try_respawn })
    -- Logs the arrival where every other item's is; TrapBank does the work.
    ItemEffects.register(TRAP_ITEM, {
        on_replay = "skip",
        apply = function(ctx)
            M.log(string.format("banked (%d owed)", TrapBank.banked(TRAP_ITEM)))
        end,
    })
end

------------------------------------------------------------
-- Console
------------------------------------------------------------

_G.drap_convict_trap_status = function()
    M.log(string.format("banked=%d | scoop received=%s | 445=%s 1299=%s",
        TrapBank.banked(TRAP_ITEM), tostring(scoop_received()),
        tostring(flag_get(FLAG_DAY1)), tostring(flag_get(FLAG_PRISONER_DIE))))
end

--- Arm one by hand for testing. Does not touch the bank.
_G.drap_convict_trap_fire = function()
    if try_respawn() then
        M.log("armed by hand -- nothing was deducted from the bank")
    else
        M.log("declined: need the scoop received and 445 on")
    end
end

return M
