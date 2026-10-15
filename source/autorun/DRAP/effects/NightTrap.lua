-- DRAP/effects/NightTrap.lua
-- Night Trap: it is midnight for 30 seconds, as if Night Mode were on.
--
-- Two halves, the same two the YAML Night Mode has:
--   * the zombies go to night (ZombieEffects.night_acquire: grab and block
--     rates, the hour window, glowing eyes), refcounted so it never fights
--     Hardcore Zombies or the permanent mode;
--   * the sky goes dark (TimeGate.begin_trap_night: mClock written to 0,
--     time frozen), because the engine derives its lighting from the clock.
--
-- The clock is borrowed. TimeGate hands it back no earlier than the run start
-- when the trap ends. A save written mid-trap stores midnight, and this
-- module's state is in memory only, so the clock it replaced is also kept in
-- the ledger (section "night_trap") and a reload that finds the clock sitting
-- at exactly 0 gets it back (repair). Only the trap writes 0 outside the
-- YAML hold, which is armed (and so excluded) when the YAML mode lights.
--
-- It never fires in Overtime -- that runs on its own clock and scheduled
-- events -- and stays banked there (TrapBank only counts a trap paid when
-- fire returns true). It cancels if Overtime starts, an ending sequence
-- begins, the connection drops, or a cutscene starts. With the YAML Night
-- Mode on it has nothing to add: the apworld keeps it out of the pool, and a
-- stray copy is consumed as a no-op.

local Shared = require("DRAP/Shared")
local ItemEffects = require("DRAP/ItemEffects")
local TrapBank = require("DRAP/TrapBank")
local PlayerReady = require("DRAP/PlayerReady")
local Ledger = require("DRAP/LocationLedger")

local M = Shared.create_module("NightTrap")

local NAME = "Night Trap"
local DURATION = 30.0
local SECTION = "night_trap"
local CHECK_EVERY = 0.25
local REPAIR_EVERY = 2.0

local GM_T = "app.solid.gamemastering.GameManager"

local _notify_trap = Shared.lazy_notify_trap()

local active = false
local expires_at = 0
local forced = false          -- console: ignore the connection
local next_check = 0
local next_repair = 0

------------------------------------------------------------
-- World access
------------------------------------------------------------

local function zombie_effects()
    return package.loaded["DRAP/effects/ZombieEffects"]
        or require("DRAP/effects/ZombieEffects")
end

local function time_gate()
    return package.loaded["DRAP/TimeGate"] or require("DRAP/TimeGate")
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

local function connected()
    local Bridge = _G.AP and _G.AP.AP_BRIDGE
    return Bridge ~= nil and Bridge.is_connected ~= nil and Bridge.is_connected() == true
end

local function read_clock()
    local gm = sdk.get_managed_singleton(GM_T)
    if not gm then return nil end
    return tonumber(Shared.safe(function() return gm:get_field("mClock") end))
end

local function write_clock(v)
    local gm = sdk.get_managed_singleton(GM_T)
    if not gm then return false end
    return pcall(function() gm:set_field("mClock", v) end)
end

------------------------------------------------------------
-- Ledger (save recovery)
------------------------------------------------------------

local function persist(clock)
    if not Ledger.is_init() then return end
    Ledger.set_section(SECTION, { clock = clock })
end

local function stored_clock()
    if not Ledger.is_init() then return nil end
    local doc = Ledger.get_section(SECTION)
    return type(doc) == "table" and tonumber(doc.clock) or nil
end

--- A save taken mid-trap leaves mClock at exactly 0 and nothing running to
--- give it back. The ledger kept the clock the trap replaced; put it back.
--- The record is kept after a normal end on purpose: a save written mid-trap
--- can be loaded after the trap is long over.
local function repair()
    if active or time_gate().is_trap_night_held() then return end
    if not Shared.is_in_game() then return end
    if read_clock() ~= 0 then return end
    -- Midnight held on purpose by the YAML mode is not a stranded save.
    local ZE = package.loaded["DRAP/effects/ZombieEffects"]
    if ZE and ZE.is_permanent_night_active and ZE.is_permanent_night_active() then return end
    local saved = stored_clock()
    if not saved or saved <= 0 then return end
    if write_clock(saved) then
        M.log(string.format("repaired a mid-trap save: clock 0 -> %d", saved))
    end
end

------------------------------------------------------------
-- The effect
------------------------------------------------------------

local function stop(why)
    if not active then return end
    active = false
    pcall(function() zombie_effects().night_release() end)
    local restored = time_gate().end_trap_night()
    M.log(string.format("Night Trap over (%s), clock back to %s", why, tostring(restored)))
end

local function start(sec)
    local ok, replaced = time_gate().begin_trap_night()
    if not ok then
        M.log("clock hold refused -- declining")
        return false
    end
    zombie_effects().night_acquire()
    persist(replaced)
    active = true
    expires_at = os.clock() + sec
    _notify_trap(NAME, string.format("Midnight for %.0fs", sec))
    M.log(string.format("Night Trap on for %.0fs", sec))
    return true
end

--- Whether it can pay out right now. Overtime and not-ready decline, which
--- leaves the trap banked.
local function can_fire()
    if not Shared.is_in_game() then return false end
    -- Not before Meet Jessie: the prologue plays in its own daylight and its
    -- events sit on this clock. Same signal as InfinityDrain and ItemSpawner;
    -- it is tri-state, so an unreadable flag also holds the trap back.
    if not Shared.past_prologue() then return false end
    if in_overtime() or ending_busy() then return false end
    return PlayerReady.ready()
end

--- @return boolean true when spent
local function fire(sec)
    if not can_fire() then return false end
    local ZE = zombie_effects()
    if ZE.is_permanent_night_active and ZE.is_permanent_night_active() then
        M.log("YAML Night Mode is on -- nothing to add, consumed")
        return true
    end
    sec = tonumber(sec) or DURATION
    if active then
        expires_at = os.clock() + sec          -- a second one extends it
        return true
    end
    return start(sec)
end

function M.is_active() return active end

function M.on_frame()
    local now = os.clock()
    if now < next_check then return end
    next_check = now + CHECK_EVERY

    if active then
        if now >= expires_at then return stop("expired") end
        if in_overtime() then return stop("Overtime") end
        if ending_busy() then return stop("ending") end
        if not forced and not connected() then return stop("disconnected") end
        if PlayerReady.blocked_by() == "cutscene" then return stop("cutscene") end
    elseif now >= next_repair then
        next_repair = now + REPAIR_EVERY
        pcall(repair)
    end
end

--- Testing / disconnect: end it now.
function M.cancel() stop("cancelled") end

function M.register()
    TrapBank.register(NAME, { fire = function() return fire() end, can_fire = can_fire })
    ItemEffects.register(NAME, {
        on_replay = "skip",
        apply = function()
            M.log(string.format("%s banked (%d owed)", NAME, TrapBank.banked(NAME)))
        end,
    })
end

--- Offline test: drap_night_trap(sec) -- skips the connection check, still
--- obeys Overtime and readiness. drap_night_trap(0) ends it.
_G.drap_night_trap = function(sec)
    forced = true
    if tonumber(sec) == 0 then M.cancel(); return end
    M.log("console -> " .. tostring(fire(sec)))
end

return M
