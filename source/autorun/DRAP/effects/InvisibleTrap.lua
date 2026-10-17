-- DRAP/effects/InvisibleTrap.lua
-- Invisibility Trap: Frank's model is hidden for 30 s. Render only; zombies
-- still see and attack him.
--
-- Measured in game (2026-10-17): set_DrawSelf(false) on the
-- player GameObject hides the body, hat and hands, since they are children of
-- that object. The game turns the flag back on at an area change, so the trap
-- is a desired state that is re-asserted, not a one-shot write.
--
-- While Frank is not ready (cutscene, door load, vehicle -- PlayerReady) the
-- flag is left alone and the clock is paused, so he is visible for cutscenes
-- and a load does not eat the trap. When he is ready again the flag is written
-- back if the game turned it on.
--
-- Restored on expiry. Dropped, with a best-effort restore, when play ends. A
-- startup guard shows a Frank who is hidden with no trap running (a script
-- reload mid-trap would otherwise leave him stuck).

local Shared = require("DRAP/Shared")
local TrapBank = require("DRAP/TrapBank")
local ItemEffects = require("DRAP/ItemEffects")
local PlayerReady = require("DRAP/PlayerReady")

local M = Shared.create_module("InvisibleTrap")

local PM_TYPE = "app.solid.PlayerManager"

local NAME = "Invisibility Trap"
local DURATION = 30.0
local TICK = 0.1

local active = nil      -- { remaining }
local last_tick = nil
local was_in_game = false

local function player_go()
    local pm = sdk.get_managed_singleton(PM_TYPE)
    return pm and Shared.safe(function() return pm:call("get_CurrentPlayer") end)
end

local function read_draw(go)
    return go and Shared.safe(function() return go:call("get_DrawSelf") end)
end

local function write_draw(go, on)
    return Shared.safe(function()
        go:call("set_DrawSelf", on)
        return true
    end) == true
end

local function restore(why)
    local go = player_go()
    if go and read_draw(go) ~= true then
        write_draw(go, true)
    end
    M.log(string.format("Frank shown again (%s)", why))
    active = nil
end

local function fire()
    if not Shared.is_in_game() then return false end
    if not PlayerReady.ready() then return false end
    local go = player_go()
    if not go or read_draw(go) == nil then return false end
    if not write_draw(go, false) then return false end
    local refresh = active ~= nil
    active = { remaining = DURATION }
    M.log(string.format("hidden for %.0f s%s", DURATION, refresh and " (refreshed)" or ""))
    return true
end

local function tick()
    local now = os.clock()
    local dt = last_tick and (now - last_tick) or 0
    last_tick = now

    if not active then return end
    if not PlayerReady.ready() then return end   -- hold; clock paused

    active.remaining = active.remaining - dt
    if active.remaining <= 0 then
        restore("expired")
        return
    end
    local go = player_go()
    if go and read_draw(go) == true then
        write_draw(go, false)
        M.log("draw flag had been reset -- re-hid Frank")
    end
end

local last_run = 0
re.on_frame(function()
    local ig = Shared.is_in_game()
    if not ig then
        if was_in_game and active then
            M.log("left play while hidden -- dropped")
            restore("left play")
        end
        active = nil
        was_in_game = false
        return
    end
    if not was_in_game then
        was_in_game = true
        -- Startup guard.
        if not active then
            local go = player_go()
            if go and read_draw(go) == false then
                write_draw(go, true)
                M.log("guard: Frank was hidden with no trap running -- shown")
            end
        end
    end
    local now = os.clock()
    if now - last_run < TICK then return end
    last_run = now
    local ok, err = pcall(tick)
    if not ok then M.log.warn("tick failed: " .. tostring(err)) end
end)

------------------------------------------------------------
-- Registration
------------------------------------------------------------

function M.register()
    TrapBank.register(NAME, { fire = fire })
    ItemEffects.register(NAME, {
        on_replay = "skip",
        apply = function()
            M.log(string.format("%s banked (%d owed)", NAME, TrapBank.banked(NAME)))
        end,
    })
end

function M.is_active() return active ~= nil end

-- Testing, needs drap_activate_debug(): fire straight away, bypassing the bank.
_G.drap_invisible_trap = function() M.log("invisible -> " .. tostring(fire())) end
_G.drap_invisible_status = function()
    local go = player_go()
    M.log(string.format("active=%s remaining=%s drawself=%s ready=%s",
        tostring(active ~= nil),
        active and string.format("%.1f", active.remaining) or "-",
        tostring(read_draw(go)),
        tostring(PlayerReady.ready())))
end

return M
