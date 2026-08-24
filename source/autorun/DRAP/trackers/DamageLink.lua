-- DRAP/trackers/DamageLink.lua
-- DamageLink: share "took a hit" with the rest of the multiworld.
--
-- Protocol tag is SharedDamage, and the unit is damage_points. One point is
-- ONE HEALTH BLOCK here -- Frank has 4000 HP at level 1 and each Progressive
-- Health Upgrade adds 1000, so a block is 1000 HP. That keeps a point worth
-- roughly what a heart is worth in the games this links with, and it scales:
-- a late-game Frank with ten blocks shrugs off what would floor him on day 1.
--
-- SENDING is accumulated, not per hit. A zombie grab is a few hundred HP, and
-- broadcasting each one would flood the room with fractional points. Damage is
-- added up and one point leaves for every HP_PER_POINT taken, with the
-- remainder carried -- so four small hits still cost the room a point, and
-- nothing is lost to rounding.
--
-- DETECTION hooks HitPointController.addDamage. Its address is unique (checked
-- with investigation/sdk/check_fold.py -- a folded stub here would take the
-- game down), but it fires for EVERY damageable thing in the mall, so the hook
-- compares the receiving object against the player's own controller and does
-- nothing else. No managed calls inside the hook: it stores an integer and the
-- frame loop does the work.
--
-- RECEIVING can kill, deliberately. It goes through PlayerBuffs, which knows
-- the thing that makes this dangerous: addDamage taking HP to 0 leaves the
-- player undead -- HP<=0 with no death and no respawn, needing a restart. So
-- a lethal amount damages down to the floor and then calls the game's own
-- playerDead(). The Damage Player Trap stays non-lethal; only this can kill.
--
-- THE LOOP that has to be avoided: a bounce is echoed back to its sender, and
-- damage applied on receipt goes through addDamage like any other. Two guards
-- -- Bridge ignores bounces carrying this client's uuid, and applying received
-- damage sets a flag the hook honours, so it is never rebroadcast.

local Shared = require("DRAP/Shared")

local M = Shared.create_module("DamageLink")
M:set_throttle(0.25)

local PlayerBuffs = require("DRAP/effects/PlayerBuffs")

local HPC_TYPE = "app.solid.HitPointController"
local PSM_TYPE = "app.solid.PlayerStatusManager"

-- One damage point is one health block.
local HP_PER_POINT = 1000

local psm_mgr = M:add_singleton("psm", PSM_TYPE)

local enabled = false
local hook_installed = false

-- The player's own HitPointController, by address. Refreshed on the frame,
-- never read inside the hook.
local player_hpc_addr = nil

-- HP taken since the last point was sent. Carried rather than reset, so a
-- string of small hits still adds up to a point.
local damage_carry = 0

-- Damage this module is applying itself. The hook skips it, or received
-- damage would be broadcast straight back out.
local applying_received = false

-- Set by the hook when the PLAYER took a hit. The hook says WHEN and WHO;
-- how much comes from the health bar on the next frame.
--
-- addDamage's ARGUMENT IS SIGNED BUT ITS SIGN MEANS NOTHING. Measured in
-- game: addDamage(-3000) took 3000 HP, addDamage(350) took 350, and the
-- Damage Player Trap has always passed a positive 2000 and damages. The
-- magnitude is the damage whichever way it arrives.
--
-- Reading the HP delta instead of the argument was what surfaced that, and it
-- stays because it is still the better source: it is right under either sign,
-- and it reports what the player actually watched disappear rather than what
-- was requested before any clamping.
local hit_fired = false
local last_hp = nil

-- Raw argument values, for the watch log only.
local watch_hits = {}

-- Log every hit as it lands. Off by default -- this is how HP_PER_POINT gets
-- set from real numbers instead of a guess, since what a zombie grab actually
-- costs is not written down anywhere.
local watching = false

------------------------------------------------------------
-- Detection
------------------------------------------------------------

local function refresh_player_hpc()
    local psm = psm_mgr:get()
    if not psm then player_hpc_addr = nil; return end
    local hpc = Shared.safe(function()
        return psm:call("get_PlayerVitalController")
    end)
    if not hpc then player_hpc_addr = nil; return end
    player_hpc_addr = Shared.safe(function() return hpc:get_address() end)
end

local function install_hook()
    if hook_installed then return end
    local td = Shared.safe(function() return sdk.find_type_definition(HPC_TYPE) end)
    local m = td and td:get_method("addDamage(System.Int32)")
    if not m then
        M.log("addDamage not found -- damage cannot be detected")
        return
    end
    local ok = pcall(function()
        sdk.hook(m, function(args)
            if applying_received then return end
            if not enabled and not watching then return end
            if not player_hpc_addr then return end
            -- args[2] is the controller the call landed on, args[3] the
            -- amount. Both read as plain integers -- no managed calls here.
            local this = sdk.to_int64(args[2])
            if this ~= player_hpc_addr then return end
            -- Signed 32-bit. Masking alone reported -1000 as 4294966296.
            local raw = sdk.to_int64(args[3]) & 0xFFFFFFFF
            if raw >= 0x80000000 then raw = raw - 0x100000000 end
            hit_fired = true
            if watching then watch_hits[#watch_hits + 1] = raw end
        end, function(retval) return retval end)
    end)
    hook_installed = ok
    M.log(ok and "watching addDamage on the player"
             or "failed to hook addDamage")
end

------------------------------------------------------------
-- Receiving
------------------------------------------------------------

--- Take damage, whatever asked for it.
---
--- Separate from apply_received so the console can force a hit while the link
--- is off. Testing the lethal path should not need a server, and a test
--- command that quietly does nothing is worse than no command.
local function take_damage(points, source)
    points = tonumber(points)
    if not points or points <= 0 then return end

    local hp = math.floor(points * HP_PER_POINT)
    local reason = string.format("DamageLink from %s", tostring(source or "someone"))

    applying_received = true
    local outcome = "unavailable"
    pcall(function()
        outcome = PlayerBuffs.player_damage_or_kill(hp, reason)
    end)
    applying_received = false

    M.log(string.format("%s: %s point(s) = %d HP -- %s",
        reason, tostring(points), hp, tostring(outcome)))
end

--- Apply damage that arrived from the multiworld.
--- @param points number damage points, one block each
--- @param source string who sent it, for the log
function M.apply_received(points, source)
    if not enabled then
        M.log("damage arrived but DamageLink is off -- ignored")
        return
    end
    take_damage(points, source)
end

------------------------------------------------------------
-- Sending
------------------------------------------------------------

--- Current HP, as the health bar has it.
local function read_hp()
    local psm = psm_mgr:get()
    if not psm then return nil end
    local v
    pcall(function() v = psm:call("getVitalNew") end)
    return tonumber(v)
end

--- Damage taken since the last frame, measured rather than taken on trust.
--- Returns 0 when HP went up or did not move.
local function drain_damage(prev_hp, cur_hp)
    local fired = hit_fired
    hit_fired = false

    local hits = watch_hits
    watch_hits = {}

    local taken = 0
    if fired and prev_hp and cur_hp and cur_hp < prev_hp then
        taken = prev_hp - cur_hp
    end

    if watching then
        for _, raw in ipairs(hits) do
            M.log(string.format("addDamage(%d)", raw))
        end
        if fired then
            M.log(string.format("  -> HP %s -> %s, took %d (%.2f of a point)",
                tostring(prev_hp), tostring(cur_hp), taken, taken / HP_PER_POINT))
        end
    end

    if not enabled or taken <= 0 then return end

    damage_carry = damage_carry + taken
    local points = math.floor(damage_carry / HP_PER_POINT)
    if points <= 0 then return end
    damage_carry = damage_carry - (points * HP_PER_POINT)

    local Bridge = _G.AP and _G.AP.AP_BRIDGE
    if Bridge and Bridge.send_shared_damage then
        Bridge.send_shared_damage(points)
    end
end

------------------------------------------------------------
-- Public
------------------------------------------------------------

function M.set_enabled(on)
    enabled = (on == true)
    if enabled then
        install_hook()
    else
        -- REFramework has no unhook, so the hook stays and the flag gates it.
        hit_fired = false
        damage_carry = 0
    end
    M.log("DamageLink " .. (enabled and "on" or "off"))
end

function M.is_enabled() return enabled end

function M.on_frame()
    if not enabled and not watching then return end
    if not M:should_run() then return end
    if not Shared.is_in_game() then return end

    refresh_player_hpc()
    install_hook()

    local cur_hp = read_hp()
    drain_damage(last_hp, cur_hp)
    last_hp = cur_hp
end

--- Testing: arm without a server, and see what is being counted.
_G.drap_damagelink = function(on)
    M.set_enabled(on ~= false)
end

--- Testing: print every hit as it lands, to size a damage point properly.
_G.drap_damagelink_watch = function(on)
    watching = (on ~= false)
    if watching then install_hook() end
    M.log("hit watch " .. (watching and "ON -- go take some damage" or "off"))
end

_G.drap_damagelink_status = function()
    local Bridge = _G.AP and _G.AP.AP_BRIDGE
    if Bridge and Bridge.get_damage_tag then
        M.log("bounce tag: " .. tostring(Bridge.get_damage_tag()))
    end
    M.log(string.format(
        "enabled=%s hooked=%s watching=%s player hpc=%s  HP=%s  carry=%d/%d to a point",
        tostring(enabled), tostring(hook_installed), tostring(watching),
        tostring(player_hpc_addr), tostring(last_hp), damage_carry, HP_PER_POINT))
end

--- Testing: take a hit as if one had arrived, with no server and without
--- having to arm the link first.
_G.drap_damagelink_take = function(points)
    take_damage(tonumber(points) or 1, "console")
end

return M
