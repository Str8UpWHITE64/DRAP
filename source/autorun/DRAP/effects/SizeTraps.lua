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
--
-- Held weapons: a weapon in Frank's hand is a child of the player object
-- (joint R_Weapon). The game sets its LocalScale when it goes into the hand
-- so that its world size is its own size at Frank's scale of that moment:
-- a weapon taken out while Frank is at 0.5 gets LocalScale 2.0, at 1.5 it
-- gets 0.667. The game never rewrites it while the weapon stays in the hand,
-- so once Frank is back to 1.0 that weapon is twice (or two thirds) its size.
-- Putting it away or dropping it resets it. So the weapon in the hand is
-- tracked with Frank's scale at the moment it went in, and on expiry its
-- scale is corrected for Frank's restored size. With no trap running, a
-- weapon in the hand whose LocalScale is exactly one of those leftovers is
-- put back to 1 (covers a trap that ended without its restore: a reload or
-- leaving play mid-trap).

local Shared = require("DRAP/Shared")
local TrapBank = require("DRAP/TrapBank")
local ItemEffects = require("DRAP/ItemEffects")
local PlayerReady = require("DRAP/PlayerReady")

local M = Shared.create_module("SizeTraps")

local PM_TYPE = "app.solid.PlayerManager"
local PSM_TYPE = "app.solid.PlayerStatusManager"

local TINY, GIANT = "Tiny Trap", "Giant Trap"
local _notify_trap = Shared.lazy_notify_trap()
local SIZE_LINE = { [TINY] = "Frank is small for %.0fs", [GIANT] = "Frank is big for %.0fs" }
local SCALE = { [TINY] = 0.5, [GIANT] = 1.5 }
local DURATION = 30.0
local TICK = 0.1
local EPS = 0.001

local active = nil      -- { name, scale, remaining }
local base = nil        -- { x, y, z } before any trap
local held = nil        -- { addr, ls = {x,y,z}, at } the weapon in hand and Frank's scale when it went in
local GUARD_EVERY = 1.0
local last_guard = 0
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

local function same_scale(a, b)
    return a and b and math.abs(a.x - b.x) < EPS and math.abs(a.y - b.y) < EPS and math.abs(a.z - b.z) < EPS
end

-- The LocalScale a weapon should have in the hand at Frank's scale `now`,
-- given the LocalScale `ls` the game gave it when it went into the hand at
-- Frank's scale `at`. The game keeps the weapon's world size at attach, so
-- its own size is ls * at; under a parent at `now` that is ls * at / now.
-- nil when nothing needs writing.
function M.held_fix(ls, at, now)
    if not (ls and at and now) or now == 0 or math.abs(at - now) < EPS then return nil end
    local k = at / now
    return { x = ls.x * k, y = ls.y * k, z = ls.z * k }
end

-- True for a LocalScale that can only be left over from a size trap: what
-- the game gives a weapon of size 1 when it goes into the hand at one of
-- the trap scales, seen with Frank at `now`.
function M.is_leftover(ls, now)
    if not (ls and now) then return false end
    for _, v in pairs(SCALE) do
        if math.abs(v - now) >= EPS and is_value(ls, now / v) then return true end
    end
    return false
end

-- The weapon in Frank's hand: its Transform, the object's address and its
-- LocalScale. nil with nothing in the hand (a put-away weapon has no parent).
local function held_weapon(player_tr)
    if not player_tr then return nil end
    local psm = sdk.get_managed_singleton(PSM_TYPE)
    local inv = psm and Shared.safe(function() return psm:get_field("PlayerInventory") end)
    local item = inv and Shared.safe(function() return inv:call("getFirstItem") end)
    local go = item and Shared.safe(function() return item:call("get_GameObject") end)
    local tr = go and Shared.safe(function() return go:call("get_Transform") end)
    local parent = tr and Shared.safe(function() return tr:call("get_Parent") end)
    if not parent then return nil end
    local pa = Shared.safe(function() return parent:get_address() end)
    if not pa or pa ~= Shared.safe(function() return player_tr:get_address() end) then return nil end
    local ls = read_scale(tr)
    if not ls then return nil end
    return { tr = tr, addr = Shared.safe(function() return go:get_address() end), ls = ls }
end

-- Notes a weapon that has just gone into the hand, with Frank's scale now.
local function track_held(player_tr)
    local h = held_weapon(player_tr)
    if not h then held = nil; return end
    if held and held.addr == h.addr and same_scale(held.ls, h.ls) then return end
    local cur = read_scale(player_tr)
    if not cur then return end
    held = { addr = h.addr, ls = h.ls, at = cur.x }
end

-- After Frank's scale went back to `now`: give the weapon in hand its own size.
local function fix_held(player_tr, now)
    local h = held_weapon(player_tr)
    local rec = held
    held = nil
    if not (h and rec and rec.addr == h.addr and same_scale(rec.ls, h.ls)) then return end
    local want = M.held_fix(h.ls, rec.at, now)
    if want and write_scale(h.tr, want.x, want.y, want.z) then
        M.log(string.format("held weapon scale %.3f -> %.3f", h.ls.x, want.x))
    end
end

-- No trap running: put back a weapon left at a trap's compensating scale.
local function guard_held()
    local tr = player_transform()
    local cur = read_scale(tr)
    if not cur or is_ours(cur) then return end
    local h = held_weapon(tr)
    if h and M.is_leftover(h.ls, cur.x) then
        if write_scale(h.tr, 1, 1, 1) then
            M.log(string.format("guard: held weapon scale %.3f reset to 1", h.ls.x))
        end
    end
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
        fix_held(tr, b.x)
    end
    M.log(string.format("restored scale (%s)", why))
    active, base, held = nil, nil, nil
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
    track_held(tr)   -- before the write: a weapon already in hand went in at this scale
    if not write_scale(tr, s, s, s) then return false end
    local replaced = active and active.name ~= name
    active = { name = name, scale = s, remaining = DURATION }
    M.log(string.format("%s: scale %.2f for %.0f s%s", name, s, DURATION,
        replaced and " (replaced the other size)" or ""))
    _notify_trap(name, string.format(SIZE_LINE[name], DURATION))
    return true
end

local function tick()
    local now = os.clock()
    local dt = last_tick and (now - last_tick) or 0
    last_tick = now

    if not active then
        if now - last_guard >= GUARD_EVERY then
            last_guard = now
            guard_held()
        end
        return
    end
    -- Followed even while not ready: a cutscene can reset Frank's scale, and
    -- a weapon that goes into the hand then goes in at that scale.
    track_held(player_transform())
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
        active, base, held = nil, nil, nil
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
