-- DRAP/effects/SizeTraps.lua
-- Tiny Trap and Giant Trap: Frank's size changes for a while.
--
-- Measured in game (2026-10-13): writing via.Transform LocalScale on
-- the player GameObject shrinks or grows him cleanly, and he still interacts
-- with things at either size. 0.5 and 1.5 are the agreed sizes. Cutscenes
-- RESET the scale, so the trap is a desired state that is re-asserted, not a
-- one-shot write.
--
-- One trap at a time: a Tiny while Giant runs (or the reverse) replaces it and
-- its 30 s start fresh; the same trap again just refreshes the 30 s.
--
-- While Frank is not ready (cutscene, door load, vehicle -- PlayerReady) the
-- scale is left alone and the clock is paused, so a cutscene does not eat the
-- trap. When he is ready again the scale is written back if the game changed
-- it. The original scale is captured the first time and restored on expiry.
--
-- The state is cleared when play ends: a new player object starts at its own
-- scale. A startup guard also puts back a scale that is exactly one of ours
-- with no trap active (a script reload mid-trap would otherwise leave Frank
-- stuck).

local Shared = require("DRAP/Shared")
local TrapBank = require("DRAP/TrapBank")
local ItemEffects = require("DRAP/ItemEffects")
local PlayerReady = require("DRAP/PlayerReady")

local M = Shared.create_module("SizeTraps")

local PM_TYPE = "app.solid.PlayerManager"

local TINY, GIANT = "Tiny Trap", "Giant Trap"
local SCALE = { [TINY] = 0.5, [GIANT] = 1.5 }
local DURATION = 30.0
local TICK = 0.1
local EPS = 0.001

local active = nil      -- { name, scale, remaining }
local base = nil        -- { x, y, z } before any trap
local last_tick = nil
local was_in_game = false

------------------------------------------------------------
-- Transform access
------------------------------------------------------------

local function player_transform()
    local pm = sdk.get_managed_singleton(PM_TYPE)
    local go = pm and Shared.safe(function() return pm:call("get_CurrentPlayer") end)
    return go and Shared.safe(function() return go:call("get_Transform") end)
end

local function read_scale(tr)
    local s = tr and Shared.safe(function() return tr:call("get_LocalScale") end)
    if not s then return nil end
    return { x = s.x, y = s.y, z = s.z }
end

local function write_scale(tr, x, y, z)
    return Shared.safe(function()
        tr:call("set_LocalScale", Vector3f.new(x, y, z))
        return true
    end) == true
end

local function is_ours(s)
    if not s then return false end
    for _, v in pairs(SCALE) do
        if math.abs(s.x - v) < EPS and math.abs(s.y - v) < EPS and math.abs(s.z - v) < EPS then
            return true
        end
    end
    return false
end

local function is_value(s, v)
    return s and math.abs(s.x - v) < EPS and math.abs(s.y - v) < EPS and math.abs(s.z - v) < EPS
end

------------------------------------------------------------
-- Effect
------------------------------------------------------------

local function restore(why)
    local tr = player_transform()
    local b = base or { x = 1, y = 1, z = 1 }
    if tr then
        local cur = read_scale(tr)
        if not cur or not is_value(cur, b.x) then
            write_scale(tr, b.x, b.y, b.z)
        end
    end
    M.log(string.format("restored scale (%s)", why))
    active, base = nil, nil
end

local function fire(name)
    if not Shared.is_in_game() then return false end
    if not PlayerReady.ready() then return false end
    local tr = player_transform()
    local cur = read_scale(tr)
    if not cur then return false end
    local s = SCALE[name]
    if not base then
        -- Never record one of our own sizes as the original.
        base = is_ours(cur) and { x = 1, y = 1, z = 1 } or cur
    end
    if not write_scale(tr, s, s, s) then return false end
    local replaced = active and active.name ~= name
    active = { name = name, scale = s, remaining = DURATION }
    M.log(string.format("%s: scale %.2f for %.0f s%s", name, s, DURATION,
        replaced and " (replaced the other size)" or ""))
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
    local tr = player_transform()
    local cur = read_scale(tr)
    if tr and cur and not is_value(cur, active.scale) then
        write_scale(tr, active.scale, active.scale, active.scale)
        M.log(string.format("scale had been reset (%.2f) -- re-applied %s",
            cur.x, active.name))
    end
end

local last_run = 0
re.on_frame(function()
    local ig = Shared.is_in_game()
    if not ig then
        if was_in_game and active then
            M.log("left play with " .. active.name .. " running -- dropped")
        end
        active, base = nil, nil
        was_in_game = false
        return
    end
    if not was_in_game then
        was_in_game = true
        -- Startup guard.
        if not active then
            local tr = player_transform()
            if tr and is_ours(read_scale(tr)) then
                write_scale(tr, 1, 1, 1)
                M.log("guard: stray trap scale reset to 1")
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
    for _, name in ipairs({ TINY, GIANT }) do
        TrapBank.register(name, { fire = function() return fire(name) end })
        ItemEffects.register(name, {
            on_replay = "skip",
            apply = function()
                M.log(string.format("%s banked (%d owed)", name, TrapBank.banked(name)))
            end,
        })
    end
end

function M.is_active() return active ~= nil end

-- Testing, needs drap_activate_debug(): fire straight away, bypassing the bank.
_G.drap_tiny_trap = function() M.log("tiny -> " .. tostring(fire(TINY))) end
_G.drap_giant_trap = function() M.log("giant -> " .. tostring(fire(GIANT))) end
_G.drap_size_status = function()
    M.log(string.format("active=%s remaining=%s base=%s ready=%s",
        active and active.name or "none",
        active and string.format("%.1f", active.remaining) or "-",
        base and string.format("%.2f", base.x) or "-",
        tostring(PlayerReady.ready())))
end

return M
