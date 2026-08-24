-- DRAP/trackers/KnockbackLink.lua
-- KnockbackLink: share being knocked about with the rest of the multiworld.
--
-- Protocol tag is KnockbackLink, and the payload's "value" is a CHANGE IN
-- VELOCITY -- x, y, z as floats, +x east, +y up, +z south.
--
-- SENDING needs three things together, because no single call answers it.
-- Measured, in the order they were tried and why each fell short:
--
--   startButtobi        carries a real velocity but ONLY fires for being
--                       THROWN. Jeff knocking Frank flat fires nothing.
--   requestDamage       never fires for ordinary hits, only for a few cases
--                       like riding a skateboard into a wall.
--   DamageInfo.Wince    always 0, despite being the engine's word for a
--                       flinch.
--   get_DamageR1Type    live and correct, but HOLDS the last reaction rather
--                       than resetting. Two knockdowns in a row produce one
--                       change, so it cannot be watched for transitions.
--
-- So: OnDamageHit says a hit landed and hands over its direction, and the
-- reaction state read when that hit is drained says what the hit DID. The
-- game's own classification, rather than a damage number standing in for it.
--
-- The threshold covers the one gap left. A zombie grab fires OnDamageHit at
-- 350 without staggering him, and reading the reaction after it would return
-- whatever he was last put through -- so a hit too light to stagger is
-- dropped before the reaction is consulted. Measured: grabs 350, and every
-- hit that put him down 1000 or more (Jeff, Sean, a raincoat slash, Cletus).
--
-- DamageDir is always unit length and points AT whatever hit him, so what
-- goes out is its negation flattened to the ground -- which is exactly what
-- startButtobi did on the one hit where both were visible.
--
-- No player filter is needed here: OnDamageHit is defined on PlayerCondition,
-- so unlike addDamage -- which fires for every zombie Frank swings at -- it
-- can only ever mean Frank.
--
-- RECEIVING goes through PlayerCondition.requestDamage(damage, reaction, dir),
-- which is the game's own damage-reaction entry point. Damage is 0: this link
-- shares being staggered, not being hurt, and DamageLink already covers the
-- hurting. The direction is negated back into a DamageDir, and the reaction is
-- picked at random from five that were confirmed by hand to look like a real
-- hit and to let Frank get up again afterwards.
--
-- Reactions NOT used, on purpose: DEAD, DEAD_WAIT and LANDING_DEAD end the
-- run, and IS_ZOMBIE is whatever happens when Frank turns. None of those is
-- something another player's stumble should be able to do.
--
-- THE LOOP TO AVOID: a received knockback runs the reaction FSM, which calls
-- startButtobi, which the hook would send straight back out. Two guards, the
-- same shape as DamageLink -- Bridge drops bounces carrying this client's own
-- uuid, and applying one sets a flag the hook honours.

local Shared = require("DRAP/Shared")

local M = Shared.create_module("KnockbackLink")
M:set_throttle(0.1)

local PM_TYPE = "app.solid.PlayerManager"
local COND_TYPE = "app.solid.survivor.player.PlayerCondition"
local R1_TYPE = "app.solid.MT.PlayerDamageR1Type"

-- Confirmed by hand: each of these reads as a real hit and Frank gets back up.
local REACTIONS = {
    "PL_DMG_R1_L",          -- a solid flinch
    "PL_DMG_R1_DOWN",       -- knocked down
    "PL_DMG_R1_BUTTOBI",    -- sent flying
    "PL_DMG_R1_KIRIMOMI",   -- spun round
    "PL_DMG_R1_AOMUKE",     -- onto his back
}

-- Under this it is not a hit at all. Being held by a zombie drains health in
-- a stream of ZERO-damage events -- 29 of them in five seconds, measured --
-- and none of those is a knockback. Real hits start at 350.
local MIN_HIT_DAMAGE = 100

-- Repeated hits are real and should each send, but a psychopath's combo can
-- land several in a few frames and there is no reason to flood the room.
local SEND_COOLDOWN = 0.25

-- Reactions that count as being knocked about. Wider than the five the
-- receive half plays, on purpose: S and M are the small and medium flinches,
-- and a zombie shoving Frank measured PL_DMG_R1_S at 350 damage -- it moved
-- him, so it counts. What arrives at the other end is still one of the five,
-- so a nudge here becomes a proper stagger there.
local KNOCKBACK_REACTIONS = {
    PL_DMG_R1_S = true,
    PL_DMG_R1_M = true,
    PL_DMG_R1_L = true,
    PL_DMG_R1_DOWN = true,
    PL_DMG_R1_BUTTOBI = true,
    PL_DMG_R1_KIRIMOMI = true,
    PL_DMG_R1_AOMUKE = true,
}

-- Anchored to the only velocity ever measured: Cletus's 1002-damage shot came
-- through startButtobi as speedXZ = 2.0.
local SPEED_PER_DAMAGE = 1.0 / 500.0

-- A psychopath's best hit should not fling a partner into orbit.
local MAX_SEND_SPEED = 6.0

local psm_mgr = M:add_singleton("psm", PM_TYPE)

local enabled = false
local hook_installed = false

local applying_received = false
local pending = {}             -- written by the hook, drained on the frame

-- Log what every hit was judged to be, without sending anything.
local watching = false

local r1_values = nil          -- reaction name -> engine value

------------------------------------------------------------
-- Chain
------------------------------------------------------------

local function player_condition()
    local pm = psm_mgr:get()
    if not pm then return nil end
    return Shared.safe(function() return pm:call("get_CurrentPlayerCondition") end)
end

--- Reaction name -> value, read from the enum rather than hardcoded. The dump
--- lists the names but not the numbers, and a wrong enum value does nothing at
--- all rather than failing loudly.
local function load_reactions()
    if r1_values then return r1_values end
    r1_values = {}
    local td = Shared.safe(function() return sdk.find_type_definition(R1_TYPE) end)
    for _, f in ipairs(td and td:get_fields() or {}) do
        local static = Shared.safe(function() return f:is_static() end)
        local literal = Shared.safe(function() return f:is_literal() end)
        if static and literal then
            local v = Shared.safe(function() return f:get_data(nil) end)
            if v ~= nil then r1_values[f:get_name()] = tonumber(v) end
        end
    end
    return r1_values
end

--- The reaction Frank is in, by name. Holds the LAST one rather than
--- resetting, so it is only meaningful right after a hit.
local function current_reaction()
    local cond = player_condition()
    if not cond then return nil end
    local v = Shared.safe(function() return cond:call("get_DamageR1Type") end)
    v = tonumber(v)
    if v == nil then return nil end
    for name, value in pairs(load_reactions()) do
        if value == v then return name end
    end
    return tostring(v)
end

------------------------------------------------------------
-- Sending
------------------------------------------------------------

local function install_hook()
    if hook_installed then return end
    local td = Shared.safe(function() return sdk.find_type_definition(COND_TYPE) end)
    local m = td and td:get_method(
        "OnDamageHit(app.Collision.HitController.DamageInfo)")
    if not m then
        M.log("OnDamageHit not found -- knockbacks cannot be detected")
        return
    end
    local ok = pcall(function()
        sdk.hook(m, function(args)
            if applying_received then return end
            if not enabled and not watching then return end
            -- A managed object: a raw pointer answers nil to get_field, and
            -- does it silently.
            local di = sdk.to_managed_object(args[3])
            if not di then return end
            local damage = di:get_field("<Damage>k__BackingField")
            local dir = di:get_field("<DamageDir>k__BackingField")
            if not damage or not dir then return end
            pending[#pending + 1] = {
                damage = tonumber(damage) or 0,
                x = dir.x, y = dir.y, z = dir.z,
            }
        end, function(retval) return retval end)
    end)
    hook_installed = ok
    M.log(ok and "watching OnDamageHit" or "failed to hook OnDamageHit")
end

-- What the reaction read as on the previous hit. Only used to mark a line as
-- new in the watch log now, not to decide anything.
local last_reaction_seen = nil

-- Earliest the next knockback may go out.
local send_ready_at = 0

--- One entry: decide whether it was a knockback and send it on.
--- @return string what happened, for the watch log
local function handle_hit(k)
    -- Read AFTER the hit: this is what that hit did to him. Always read, and
    -- always reported -- checking damage first meant a light hit was dropped
    -- before anyone could see what the game had classed it as.
    local reaction = current_reaction() or "?"
    local changed = (reaction ~= last_reaction_seen)
    last_reaction_seen = reaction



    local tail = changed and " (new)" or ""

    -- Health draining while a zombie holds him arrives as a stream of
    -- zero-damage events. Those are not hits.
    if k.damage < MIN_HIT_DAMAGE then
        return string.format("%d damage -- not a hit", k.damage)
    end

    if not KNOCKBACK_REACTIONS[reaction] then
        return string.format("%d damage, %s%s -- not a knockback",
            k.damage, reaction, tail)
    end

    -- Deliberately NOT requiring the reaction to have changed. It holds its
    -- last value and nothing in the engine counts requests -- measured,
    -- IsDamageRequestedCount stays 0 -- so repeated identical hits are
    -- indistinguishable from a held reading. Repeats are the common case
    -- (a zombie shoving him over and over), so they are believed, and the
    -- cost of being wrong is a partner getting one stagger too many.
    if os.clock() < send_ready_at then
        return string.format("%d damage, %s -- too soon after the last",
            k.damage, reaction)
    end

    -- Away from whatever hit him, along the ground. DamageDir's own y is
    -- where the blow came from vertically, not the way he travels; the one
    -- hit where both were visible had startButtobi flat at y = 0.
    local dx, dz = -(tonumber(k.x) or 0), -(tonumber(k.z) or 0)
    local flat = math.sqrt(dx * dx + dz * dz)
    if flat <= 0 then
        return string.format("%d damage, %s, but no direction", k.damage, reaction)
    end

    local speed = k.damage * SPEED_PER_DAMAGE
    if speed > MAX_SEND_SPEED then speed = MAX_SEND_SPEED end
    send_ready_at = os.clock() + SEND_COOLDOWN
    local vx, vz = dx / flat * speed, dz / flat * speed

    if not enabled then
        return string.format("%d damage, %s%s -> would send (%.2f, 0, %.2f)",
            k.damage, reaction, tail, vx, vz)
    end

    local Bridge = _G.AP and _G.AP.AP_BRIDGE
    if Bridge and Bridge.send_knockback then
        Bridge.send_knockback(vx, 0.0, vz)
    end
    return string.format("%d damage, %s -> sent (%.2f, 0, %.2f)",
        k.damage, reaction, vx, vz)
end

local function drain()
    if #pending == 0 then return end
    local batch = pending
    pending = {}
    for _, k in ipairs(batch) do
        local what = handle_hit(k)
        if watching then M.log(what) end
    end
end

------------------------------------------------------------
-- Receiving
------------------------------------------------------------

--- Knock Frank about. Shared by the real receive path and the console.
local function take_knockback(x, y, z, source)
    x, y, z = tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0
    local len = math.sqrt(x * x + y * y + z * z)
    if len <= 0 then
        M.log("knockback with no direction -- ignored")
        return
    end

    local cond = player_condition()
    if not cond then
        M.log("no PlayerCondition -- knockback dropped")
        return
    end

    -- requestDamage wants a DamageDir, which points AT whatever hit him, so
    -- it is the incoming direction of travel reversed.
    local dir = Vector3f.new(-x / len, -y / len, -z / len)

    local reactions = load_reactions()
    local name = REACTIONS[math.random(#REACTIONS)]
    local value = reactions[name]
    if value == nil then
        M.log(string.format("reaction %s did not resolve -- knockback dropped", name))
        return
    end

    applying_received = true
    local ok = pcall(function()
        cond:call("requestDamage", 0, value, dir)
    end)
    applying_received = false

    M.log(string.format("knocked about by %s: (%.2f, %.2f, %.2f) as %s%s",
        tostring(source or "someone"), x, y, z, name, ok and "" or " FAILED"))
end

--- Called by Bridge when a KnockbackLink bounce arrives.
function M.apply_received(value, source)
    if not enabled then
        M.log("knockback arrived but KnockbackLink is off -- ignored")
        return
    end
    if type(value) ~= "table" then return end
    take_knockback(value.x, value.y, value.z, source)
end

------------------------------------------------------------
-- Public
------------------------------------------------------------

function M.set_enabled(on)
    enabled = (on == true)
    if enabled then
        install_hook()
    else
        pending = {}
    end
    M.log("KnockbackLink " .. (enabled and "on" or "off"))
end

function M.is_enabled() return enabled end

function M.on_frame()
    if not enabled and not watching then return end
    if not M:should_run() then return end
    if not Shared.is_in_game() then return end

    install_hook()
    drain()
end

------------------------------------------------------------
-- Offline testing
------------------------------------------------------------

--- Arm without a server.
_G.drap_knockbacklink = function(on)
    M.set_enabled(on ~= false)
end

--- Take a knockback as if one had arrived. Works with the link off, so the
--- reaction can be tried without a server -- a test command that quietly does
--- nothing is worse than no command.
_G.drap_knockback_take = function(x, y, z)
    take_knockback(tonumber(x) or 2.0, tonumber(y) or 0.0, tonumber(z) or 0.0,
                   "console")
end

--- Fire one of each reaction in turn, so all five can be seen back to back.
_G.drap_knockback_sample = function()
    for _, name in ipairs(REACTIONS) do
        M.log("next: " .. name)
    end
    M.log("use drap_knockback_take(x, y, z) -- the reaction is random each time")
end

--- Testing: log what every hit was judged to be, and what would go out.
--- Works with the link off, so the threshold and the reaction filter can be
--- tuned against real hits before anything is broadcast.
_G.drap_knockback_watch = function(on)
    watching = (on ~= false)
    if watching then install_hook() end
    M.log("hit watch " .. (watching and "ON -- go get hit" or "off"))
end

_G.drap_knockback_status = function()
    M.log(string.format(
        "enabled=%s hooked=%s watching=%s queued=%d  reaction now=%s  "
        .. "min hit=%d  cooldown=%.2fs",
        tostring(enabled), tostring(hook_installed), tostring(watching),
        #pending, tostring(current_reaction()), MIN_HIT_DAMAGE, SEND_COOLDOWN))
end

return M
