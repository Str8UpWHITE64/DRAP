-- DRAP/effects/PpBonusMatch.lua
-- Which microwave, stove, dish, rack, treadmill or sandbag was that?
--
-- The Extra PP bonuses are COUNTED triggers: the game fires one Status message
-- per use and the Nth one awards "Use N Microwaves". That leaves the names
-- placeless, and forces the logic to approximate regions with region_counts.
--
-- Each object has a recorded position in shared data now, so a fired award can
-- be matched to the one it came from and send a name that says where it is.
-- Two ways to match, per trigger:
--
--   nearest         -- the player is standing at the thing they used, so the
--                      closest recorded instance in this scene wins
--   object_broken   -- the thing was destroyed, and the player can be nowhere
--                      near a specific one of them (the 18 dishes are stacked
--                      on one shelf). Find the object that is BREAKING instead.
--
-- Breaking is visible immediately, so neither path waits for the despawn:
--   uOm13b (dish)    CurrentDestroyTime rises above 0 the moment it breaks
--   uOm127 (sandbag) HitPointController.CurrentHitPoint drops to 0
-- Watching for the object to LEAVE OmList also works, but takes a second or
-- two, which reads as a laggy check.

local M = {}

local Shared = require("DRAP/Shared")
local log = Shared.create_logger("PpBonusMatch")
M.log = log

local safe = Shared.safe

local AM_TYPE = "app.solid.gamemastering.AreaManager"
local PM_TYPE = "app.solid.PlayerManager"

-- How far the player may be from a recorded position and still be counted as
-- standing at it. The closest two same-kind objects are the Food Court
-- microwaves at about 20 apart, and the treadmills at 1.5 -- but the player
-- stands ON a treadmill, so their capture distance is near zero. 6 is wide
-- enough for a stove the player backed away from and far short of 20.
local NEAREST_LIMIT = 6.0

-- An object counts as "the one that broke" within this of a recorded position.
local OBJECT_LIMIT = 3.0

------------------------------------------------------------
-- State
------------------------------------------------------------

-- Forward declarations. Both are called from resolve()/setup(), which sit
-- above the strategy implementations. Lua resolves an undeclared name as a
-- global, so without these the call fails at runtime rather than at load --
-- and lua_use_before_decl.py does not look inside function bodies.
local install_award_hook
local most_active
local match_report
local match_award

local instances_by_trigger = {}   -- id -> { match, om_type, items = {...} }
local bridge = nil                -- set by setup(); object-driven sends go here
local last_scene = nil            -- so the index is dropped on an area change
local dry_run = false

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function player_pos()
    local pm = safe(function() return sdk.get_managed_singleton(PM_TYPE) end)
    if not pm then return nil end
    local go = safe(function() return pm:call("get_CurrentPlayer") end)
    local tr = go and safe(function() return go:call("get_Transform") end)
    return tr and safe(function() return tr:call("get_Position") end)
end

local function current_scene()
    local am = safe(function() return sdk.get_managed_singleton(AM_TYPE) end)
    if not am then return nil end
    local idx = tonumber(safe(function() return am:get_field("mAreaIndex") end))
    if not idx then return nil end
    for code, info in pairs(Shared.SCENE_INFO or {}) do
        if info and info.index == idx then return code end
    end
    return nil
end

local function dist2(a, bx, by, bz)
    local dx, dy, dz = (a.x or 0) - bx, (a.y or 0) - by, (a.z or 0) - bz
    return dx * dx + dy * dy + dz * dz
end

--- Closest instance to a point, within a limit. Returns instance, distance.
local function closest(items, scene, x, y, z, limit)
    local best, best_d2 = nil, limit * limit
    for _, inst in ipairs(items or {}) do
        if not scene or inst.scene == scene then
            local d2 = dist2({ x = x, y = y, z = z }, inst.x, inst.y, inst.z)
            if d2 <= best_d2 then best, best_d2 = inst, d2 end
        end
    end
    return best, best and math.sqrt(best_d2) or nil
end

------------------------------------------------------------
-- Finding the object that just broke
------------------------------------------------------------

--- Is this object mid-destruction?
---
--- Two different signals because the two types report it differently, and
--- neither has to wait for the object to leave the list.
local function is_breaking(om)
    local t = tonumber(safe(function() return om:get_field("CurrentDestroyTime") end))
    if t and t > 0 then return true end
    local hpc = safe(function() return om:get_field("<HitPointController>k__BackingField") end)
    if hpc then
        local hp = tonumber(safe(function()
            return hpc:get_field("<CurrentHitPoint>k__BackingField")
        end))
        if hp and hp <= 0 then return true end
    end
    local rate = tonumber(safe(function() return om:get_field("mBreakRate") end))
    if rate and rate > 0 then return true end
    return false
end

local function om_position(om)
    local go = safe(function() return om:call("get_GameObject") end)
    local tr = go and safe(function() return go:call("get_Transform") end)
    return tr and safe(function() return tr:call("get_Position") end)
end

--- Every object of a type in the area, as { address -> object }.
local function objects_of_type(om_type)
    local out = {}
    local am = safe(function() return sdk.get_managed_singleton(AM_TYPE) end)
    if not am then return out end
    local list = safe(function() return am:get_field("OmList") end)
    if not list then return out end
    local count = tonumber(safe(function() return list:call("get_Count") end)) or 0
    local want = "solid.MT2RE." .. tostring(om_type)
    for i = 0, count - 1 do
        local om = safe(function() return list:call("get_Item", i) end)
        if om then
            local td = safe(function() return om:get_type_definition() end)
            local name = td and safe(function() return td:get_full_name() end)
            if name == want then
                local addr = safe(function() return om:get_address() end)
                if addr then out[addr] = om end
            end
        end
    end
    return out
end

-- Object address -> instance, per scene. Built while everything is still at
-- rest, because a broken object MOVES: a destroyed sandbag drops to the floor,
-- and its live position then sits ~2.9 from where it hung -- further than the
-- 2.5 between neighbouring bags, so matching the fallen position picked the
-- wrong bag. Identity is taken once, up front, and the break only has to look
-- it up.
local om_index = {}      -- scene -> om_type -> { address -> instance }

-- Everything M.reset_index clears has to be declared HERE, above it. These
-- used to sit further down beside the code that reads them, which put them
-- out of scope at the point reset_index assigns them -- so it silently wrote
-- six globals and cleared none of the real state. Reloading an area did not
-- let a missed check be earned again, which was the whole point of it.

-- Objects already reported broken. A broken object STAYS in OmList in its
-- broken state for a while, so without this the same one answers every later
-- break -- measured: bags 2, 3 and 4 all came back as bag 2. It also settles
-- the iteration order question, since pairs() has none to rely on.
local broken_seen = {}   -- address -> true

local last_state = {}    -- address -> last seen state value

-- One report per instance until the area reloads. Without this the
-- accumulator refills the moment it is cleared and fires again -- and while
-- the game is PAUSED the speed stays frozen at a non-zero value, so it repeats
-- every tick. Cleared with the index, so a reload still allows a retry.
local reported = {}

local rot_accum = {}      -- address -> degrees since the last send
local dwell = {}          -- instance name -> seconds stood there
local stat_progress = {}   -- instance name -> units accumulated nearby

local function ensure_index(scene, om_type, items)
    om_index[scene] = om_index[scene] or {}
    if om_index[scene][om_type] then return om_index[scene][om_type] end

    local objs = objects_of_type(om_type)
    local map, n = {}, 0
    for addr, om in pairs(objs) do
        -- Skip anything already breaking: it has moved, so its position no
        -- longer identifies it and a guess here would be wrong for good.
        if not is_breaking(om) then
            local p = om_position(om)
            if p then
                local inst = closest(items, scene, p.x, p.y, p.z, OBJECT_LIMIT)
                if inst then map[addr] = inst; n = n + 1 end
            end
        end
    end
    if n == 0 then
        -- OmList is not populated the moment an area loads. Caching an empty
        -- map here would leave the area permanently unindexed, so leave it
        -- unset and try again on the next tick.
        return map
    end
    om_index[scene][om_type] = map
    log(string.format("indexed %d %s object(s) in %s", n, om_type, tostring(scene)))
    return map
end

--- Forget the index, so it is rebuilt from the objects now in the area.
function M.reset_index()
    om_index = {}
    broken_seen = {}
    reported = {}
    last_state = {}
    rot_accum = {}
    dwell = {}
    stat_progress = {}
end

-- Objects already reported. A broken object STAYS in OmList in its broken
-- state for a while, so without this the same one answers every later break --
-- measured: bags 2, 3 and 4 all came back as bag 2. It also settles the
-- iteration order question, since pairs() has none to rely on.

--- The instance whose object has just started breaking, or nil.
local function find_breaking(scene, om_type, items)
    local map = ensure_index(scene, om_type, items)
    for addr, om in pairs(objects_of_type(om_type)) do
        if not broken_seen[addr] and is_breaking(om) then
            broken_seen[addr] = true
            local inst = map[addr]
            if inst then return inst end
            log(string.format("%s at %s is breaking but was not indexed",
                om_type, tostring(addr)))
        end
    end
    return nil
end

------------------------------------------------------------
-- Public
------------------------------------------------------------

--- Feed the instance tables in, from shared data's ap_trigger_locations.
function M.setup(trigger_entries, ap_bridge)
    instances_by_trigger = {}
    bridge = ap_bridge or bridge

    -- Fall back to the shipped shared data when nothing came from a slot.
    -- Debug mode has no slot data at all, and the positions are the same
    -- either way -- they describe the mall, not the seed.
    local from_slot = type(trigger_entries) == "table" and #trigger_entries > 0
    if not from_slot then
        local ok, SharedData = pcall(require, "DRAP/SharedData")
        if ok and SharedData and SharedData.ap_trigger_locations then
            trigger_entries = SharedData.ap_trigger_locations()
            log("no slot trigger data -- using the shipped positions")
        end
    end

    local n = 0
    for _, e in ipairs(trigger_entries or {}) do
        if type(e.instances) == "table" and #e.instances > 0 then
            instances_by_trigger[e.id] = {
                match = e.match or "nearest",
                om_type = e.om_type,
                msg_no = tonumber(e.msg_no),
                items = e.instances,
                all_name = e.all_location_name,
                method = e.method,
                -- Tuning values. Every one of these was being dropped here,
                -- so the polls silently used their defaults and "defer" never
                -- applied -- which read as the feature being broken.
                threshold = tonumber(e.threshold),
                radius = tonumber(e.radius),
                seconds = tonumber(e.seconds),
                move_min = tonumber(e.move_min),
                stat_field = e.stat_field,
                amount = tonumber(e.amount),
                defer = tonumber(e.defer),
                state_field = e.state_field,
                state_enum = e.state_enum,
                state_from = e.state_from,
            }
            n = n + #e.instances
        end
    end
    install_award_hook()
    log(string.format("%d trigger(s), %d instance(s)",
        (function() local c = 0; for _ in pairs(instances_by_trigger) do c = c + 1 end; return c end)(), n))
end

--- The location name for the award that just fired, or nil to fall back to
--- the counted name.
---
--- nil is deliberate rather than a guess: sending the wrong one of eighteen
--- dishes is worse than sending the old counted name.
function M.resolve(trigger_id)
    if next(instances_by_trigger) == nil then M.setup(nil) end
    local t = instances_by_trigger[trigger_id]
    if not t then return nil end
    local scene = current_scene()

    -- Objects are rebuilt on an area load, so the addresses in the index are
    -- dead once the player leaves. Keeping them would silently match nothing.
    if scene ~= last_scene then
        M.reset_index()
        last_scene = scene
    end

    local inst, d
    if t.match == "object_active" and t.om_type and t.state_field then
        local hit, mag = most_active(scene, t)
        if hit then
            log(string.format("%s -> %s (spinning, %s=%.1f)", trigger_id,
                hit.name, t.state_field, mag))
            return dry_run and nil or hit.name
        end
        log(string.format("%s: no %s is moving", trigger_id, tostring(t.om_type)))
        return nil
    end

    -- The strategy name must agree with shared data. It did not once, and the
    -- mismatch was invisible: an unknown value falls through to the position
    -- path, which answers plausibly and wrongly rather than failing.
    local KNOWN = { nearest = true, object_broken = true, object_state = true,
                    object_active = true, object_rotation = true,
                    player_dwell = true, player_stat = true }
    if M.owns(trigger_id) and t.match ~= "object_broken" then
        return nil   -- the frame poll answers for these
    end
    if not KNOWN[t.match] then
        log(string.format("%s: unknown match %q -- treating as nearest",
            trigger_id, tostring(t.match)))
    end
    if t.match == "object_broken" and t.om_type then
        inst = find_breaking(scene, t.om_type, t.items)
        if not inst then
            log(string.format("%s: nothing of type %s is breaking",
                trigger_id, tostring(t.om_type)))
            return nil
        end
    else
        local p = player_pos()
        if not p then return nil end
        inst, d = closest(t.items, scene, p.x, p.y, p.z, NEAREST_LIMIT)
    end

    if not inst then
        log(string.format("%s: no instance within range in %s",
            trigger_id, tostring(scene)))
        return nil
    end
    log(string.format("%s -> %s%s", trigger_id, inst.name,
        d and string.format(" (%.2f away)", d) or " (by object)"))
    if dry_run then
        log("   dry run: not sending")
        return nil
    end
    return inst.name
end

------------------------------------------------------------
-- Dry run
------------------------------------------------------------
-- Testing this normally needs a generated seed: the instances arrive in slot
-- data and the awards are noticed by AP_LocationTriggers, which only registers
-- on slot connect. Neither happens in debug mode.
--
-- So the dry run watches setScoreBuff itself. Not through MsgEvents.watch --
-- that keeps ONE watcher per message number, and registering there would
-- replace AP_LocationTriggers' watcher and stop real checks firing.

local dry_hooked = false
local dry_pending = {}

local function trigger_for_msg(msg_no)
    for id, t in pairs(instances_by_trigger) do
        if t.msg_no == msg_no then return id end
    end
    return nil
end

function install_award_hook()
    if dry_hooked then return end
    local td = safe(function()
        return sdk.find_type_definition("app.solid.PlayerStatusManager")
    end)
    local m = td and td:get_method(
        "setScoreBuff(System.UInt32, System.UInt32, System.UInt32)")
    if not m then
        log("setScoreBuff not found -- dry run cannot watch awards")
        return
    end
    sdk.hook(m, function(args)
        local msg_no = safe(function() return sdk.to_int64(args[4]) & 0xFFFFFFFF end)
        if msg_no then dry_pending[#dry_pending + 1] = msg_no end
    end, function(retval) return retval end)
    dry_hooked = true
end

------------------------------------------------------------
-- The "all of them" check
------------------------------------------------------------
-- Sent by counting what has actually been checked, rather than by waiting for
-- the game's own all-X award. The award only ever comes once, so a player who
-- lost one check to a disconnect could never earn the all-X afterwards.

local function send_all_if_complete(id, t)
    if not t.all_name then return end
    if not (bridge and bridge.has_local_check and bridge.has_completed_check) then return end
    -- Components: what the PLAYER photographed. Another world collecting them
    -- must not earn the all-X on their behalf.
    for _, inst in ipairs(t.items) do
        local ok, done = pcall(bridge.has_local_check, inst.name)
        if not ok or done ~= true then return end
    end
    -- Dedupe, though: if the server already has the all-X, do not resend it.
    local ok, already = pcall(bridge.has_completed_check, t.all_name)
    if ok and already == true then return end
    log(string.format("%s -> %s (all %d done)", id, t.all_name, #t.items))
    if dry_run then
        log("   dry run: not sending")
    elseif bridge.check then
        pcall(bridge.check, t.all_name)
    end
end

------------------------------------------------------------
-- Deferring to the game
------------------------------------------------------------
-- Where the game awards the bonus itself, its notification should come first:
-- our own detection exists so a missed check can be earned again, not to beat
-- the game to it. So a detected event waits a moment, and the award -- if it
-- comes -- releases it early.
--
-- Only triggers with a "defer" wait. The destroy and state kinds fire at the
-- same instant as the game anyway, and delaying those would just add lag.

local pending_sends = {}    -- { id, t, name, how, due }

local function queue_send(id, t, name, how)
    if reported[name] then return true end
    local wait = tonumber(t.defer)
    if not wait or wait <= 0 then return false end
    for _, q in ipairs(pending_sends) do
        if q.name == name then return true end   -- already waiting
    end
    pending_sends[#pending_sends + 1] = {
        id = id, t = t, name = name, how = how, due = os.clock() + wait,
    }
    return true
end

--- Send an instance's check, and the all-X if that completed the set.
-- When each trigger last sent something, so the game-award fallback can tell
-- "we missed it" from "we already got it". object_state triggers detect from
-- the object's own state machine and never go through pending_sends, so the
-- fallback used to fire after every successful send and log a failure for a
-- check that had just gone out.
local last_send_at = {}

-- Game awards we could not match yet, kept so they can be retried.
--
-- The award arrives the moment the game grants the bonus, but our instance
-- index is built per scene and is not ready straight after an area load --
-- which is when a stove or microwave in a freshly entered area gets used, and
-- the entry cutscene is playing. Giving up on the first attempt dropped the
-- check entirely. Hold it and keep trying while the player is still there.
local pending_awards = {}
local AWARD_RETRY_SECONDS = 15.0

local function send_instance(id, t, name, how)
    if reported[name] then return end
    reported[name] = true
    last_send_at[id] = os.clock()
    log(string.format("%s -> %s (%s)", id, name, how))
    if dry_run then
        log("   dry run: not sending")
        return
    end
    if bridge and bridge.check then pcall(bridge.check, name) end
    send_all_if_complete(id, t)
end

------------------------------------------------------------
-- Objects that change state rather than break
------------------------------------------------------------
-- A microwave is not destroyed, and the player can walk to another one while
-- the first is still cooking -- so "nearest when the award lands" can name the
-- wrong one. Watch the object's own state machine instead: uOm10c sits in
-- RNO0_WAIT_COOK while cooking, and leaving that state is the food being done.

local enum_cache = {}

local function enum_value(enum_type, field_name)
    local key = tostring(enum_type) .. "." .. tostring(field_name)
    if enum_cache[key] ~= nil then return enum_cache[key] or nil end
    local td = safe(function() return sdk.find_type_definition(enum_type) end)
    for _, f in ipairs((td and safe(function() return td:get_fields() end)) or {}) do
        if safe(function() return f:get_name() end) == field_name then
            local v = safe(function() return f:get_data(nil) end)
            enum_cache[key] = tonumber(v) or false
            return enum_cache[key] or nil
        end
    end
    enum_cache[key] = false
    return nil
end


--- Anything that has just left the watched state, as a list of instances.
local function poll_state(scene, t)
    -- state_from is either the NAME of an enum member, or a plain value when
    -- no enum is given. Stoves need the second: their signal is a boolean,
    -- mAccessEnableFlag going true -> false as the pan goes on.
    local want
    if t.state_enum then
        want = enum_value(t.state_enum, t.state_from)
    else
        want = t.state_from
    end
    if want == nil then return {} end

    local map = ensure_index(scene, t.om_type, t.items)
    local out = {}
    for addr, om in pairs(objects_of_type(t.om_type)) do
        local raw = safe(function() return om:get_field(t.state_field) end)
        local now = (type(raw) == "boolean") and raw or tonumber(raw)
        local was = last_state[addr]
        last_state[addr] = now
        -- Leaving the watched state. For a microwave that is the food coming
        -- out of RNO0_WAIT_COOK; for a stove it is the pan going on, which is
        -- when the game awards the PP.
        if was ~= nil and was == want and now ~= want then
            local inst = map[addr]
            if inst then out[#out + 1] = inst end
        end
    end
    return out
end

------------------------------------------------------------
-- Objects that report the event themselves
------------------------------------------------------------
-- A display rack has no state worth polling: it is spun, and the award only
-- comes on a full 360. The object announces that itself -- uOm122.onPass --
-- so hook it and read WHICH rack from the call's own subject.
--
-- The hook only notes the address; the lookup happens on the frame, because
-- resolving an instance walks OmList.

local method_hooked = {}
local method_pending = {}

local function install_method_hook(id, t)
    local key = tostring(t.om_type) .. "." .. tostring(t.method)
    if method_hooked[key] then return end
    local td = safe(function()
        return sdk.find_type_definition("solid.MT2RE." .. tostring(t.om_type))
    end)
    local m = td and td:get_method(t.method)
    if not m then
        log(string.format("%s: %s not found", id, key))
        method_hooked[key] = true      -- do not retry every tick
        return
    end
    sdk.hook(m, function(args)
        -- args[2] is the object the method was called on.
        local addr = safe(function() return sdk.to_int64(args[2]) end)
        if addr then method_pending[#method_pending + 1] = { id = id, addr = addr } end
    end, function(retval) return retval end)
    method_hooked[key] = true
    log(string.format("%s: watching %s", id, key))
end

--- The indexed object whose field is furthest from zero.
---
--- For display racks. Nothing on them counts rotations -- mRot is never
--- updated, and mTurnSpd is just spin speed that decays to 0 and jumps when
--- hit again. Integrating it here would be reimplementing the game's own
--- 360-degree accounting, and drifting from it.
---
--- So the AWARD still says when (it already knows about the full rotation),
--- and the object only answers which: the spinning one.
--- Why most_active found nothing.
---
--- "no instance could be matched" covers several different failures that look
--- identical from the log: no objects of the type in this scene, objects
--- present but their state field unreadable, or the most-active object not
--- being one of the instances we index. They want different fixes, so say
--- which.
function match_report(scene, t)
    local map = ensure_index(scene, t.om_type, t.items)
    local mapped = 0
    for _ in pairs(map or {}) do mapped = mapped + 1 end
    local seen, readable, best_mag, best_mapped = 0, 0, 0.0, false
    for addr, om in pairs(objects_of_type(t.om_type)) do
        seen = seen + 1
        local v = tonumber(safe(function() return om:get_field(t.state_field) end))
        if v then
            readable = readable + 1
            if math.abs(v) > best_mag then
                best_mag = math.abs(v)
                best_mapped = map and map[addr] ~= nil
            end
        end
    end
    -- Was a cutscene up? The failures so far were all in areas just entered,
    -- which is when an entry scene plays -- so record it rather than wonder.
    local playing = "?"
    local etm = sdk.get_managed_singleton(
        "app.solid.gamemastering.EventTimelineManager")
    if etm then
        playing = tostring(safe(function() return etm:call("isEventPlaying") end))
    end
    return string.format(
        "scene=%s type=%s items=%d indexed=%d live=%d readable(%s)=%d"
        .. " best_mag=%.3f best_is_indexed=%s cutscene=%s",
        tostring(scene), tostring(t.om_type), #(t.items or {}), mapped, seen,
        tostring(t.state_field), readable, best_mag, tostring(best_mapped),
        playing)
end

function most_active(scene, t)
    local map = ensure_index(scene, t.om_type, t.items)
    local best, best_mag = nil, 0.0
    for addr, om in pairs(objects_of_type(t.om_type)) do
        local v = tonumber(safe(function() return om:get_field(t.state_field) end))
        if v then
            local mag = math.abs(v)
            if mag > best_mag then
                best, best_mag = map[addr], mag
            end
        end
    end
    return best, best_mag
end

------------------------------------------------------------
-- Rotation, accumulated
------------------------------------------------------------
-- Racks award on a full 360, and nothing on the object counts turns: mRot is
-- never updated, and mTurnSpd is only the current speed, which decays to zero
-- and jumps when hit again. So the turning is integrated here.
--
-- The point is not to reproduce the game's own count exactly -- it is to fire
-- WITHOUT the award, so a check missed while disconnected can be earned again
-- by spinning the rack once more. Checks are idempotent, so erring generous
-- costs nothing; erring short just means another spin.

-- One report per instance until the area reloads. Without this the
-- accumulator refills the moment it is cleared and fires again -- and while
-- the game is PAUSED the speed stays frozen at a non-zero value, so it repeats
-- every tick. Cleared with the index, so a reload still allows a retry.

local rot_clock = nil

local function poll_rotation(scene, t)
    local now = os.clock()
    local dt = rot_clock and (now - rot_clock) or 0
    rot_clock = now
    if dt <= 0 or dt > 0.5 then return {} end   -- ignore load-window jumps

    local map = ensure_index(scene, t.om_type, t.items)
    local limit = tonumber(t.threshold) or 360.0
    local out = {}
    local readable = false
    for addr, om in pairs(objects_of_type(t.om_type)) do
        local v = tonumber(safe(function() return om:get_field(t.state_field) end))
        if v then readable = true end
        if v and v ~= 0 then
            local acc = (rot_accum[addr] or 0) + math.abs(v) * dt
            if acc >= limit then
                acc = 0
                local inst = map[addr]
                if inst then out[#out + 1] = inst end
            end
            rot_accum[addr] = acc
        end
    end
    if not readable and not t._warned_field then
        t._warned_field = true
        M.log(string.format(
            "%s reads nil -- check the field name (properties are stored as "
            .. "<name>k__BackingField)", tostring(t.state_field)))
    end
    return out
end

------------------------------------------------------------
-- Standing on it
------------------------------------------------------------
-- Treadmills are not in OmList at all, so there is no object to watch. The
-- player is snapped onto one while using it, though, so dwelling within arm's
-- reach of a recorded position is the same event -- and unlike the award, it
-- can be repeated.

local dwell_clock = nil

local stat_last = nil

local function read_save_stat(field)
    local ss = safe(function()
        return sdk.get_managed_singleton("app.solid.SolidStorage")
    end)
    local work = ss and safe(function() return ss:get_field("mSaveWork") end)
    if not work then return nil end
    return tonumber(safe(function() return work:get_field(field) end))
end

-- Is the player pushing a direction right now?
--
-- On a treadmill you hold forward without going anywhere, so position says
-- nothing and velocity is zero. PlayerCondition.currentMoveLength is the move
-- INPUT magnitude, which is exactly the thing being held.
--
-- This replaced reading fullMarathonDist, which does not tick smoothly:
-- measured, it jumped to 100 and then did not move for seven more seconds of
-- running, so any threshold on it fired at the wrong moment.
local function player_move_input()
    local pm = safe(function()
        return sdk.get_managed_singleton("app.solid.PlayerManager")
    end)
    local cond = pm and safe(function()
        return pm:get_field("_CurrentPlayerCondition")
    end)
    if not cond then return nil end
    return tonumber(safe(function()
        return cond:get_field("currentMoveLength")
    end))
end

local function poll_dwell(scene, t)
    local now = os.clock()
    local dt = dwell_clock and (now - dwell_clock) or 0
    dwell_clock = now
    if dt <= 0 or dt > 0.5 then return {} end

    local p = player_pos()
    if not p then return {} end
    local radius = tonumber(t.radius) or 1.2
    local need = tonumber(t.seconds) or 2.0
    -- Standing on a treadmill is not using it. Time only counts while a
    -- direction is actually being held.
    local running = true
    local move_min = tonumber(t.move_min)
    if move_min then
        local mv = player_move_input()
        running = (mv == nil) or (mv >= move_min)   -- unreadable: do not block
    end
    -- ONE instance can be occupied at a time: the nearest in range.
    --
    -- Every instance within radius used to accumulate at once. Treadmills
    -- stand side by side, so ten seconds on the first also banked ten on its
    -- neighbours, and stepping across fired them instantly -- the whole row
    -- completed from one walk.
    local best, best_d2 = nil, nil
    for _, inst in ipairs(t.items) do
        if inst.scene == scene then
            local d2 = dist2(p, inst.x, inst.y, inst.z)
            if d2 <= radius * radius and (best_d2 == nil or d2 < best_d2) then
                best, best_d2 = inst, d2
            end
        end
    end

    local out = {}
    for _, inst in ipairs(t.items) do
        if inst.scene == scene then
            if inst == best then
                -- Counts total time on this one, and is NOT reset when it
                -- fires -- the reported guard stops repeats instead. Zeroing
                -- here made the calibration line measure from the last fire
                -- rather than from stepping on, reporting 2.1s for a 10s stay.
                local held = (dwell[inst.name] or 0) + (running and dt or 0)
                dwell[inst.name] = held
                if held >= need and not reported[inst.name] then
                    out[#out + 1] = inst
                end
            else
                -- Not the one being used, including neighbours in range.
                dwell[inst.name] = 0
            end
        end
    end
    return out
end

------------------------------------------------------------
-- Running, not standing
------------------------------------------------------------
-- Dwelling near a treadmill counts standing on one, which the game does not.
-- SolidSave.fullMarathonDist is the marathon metric and only advances while
-- the player is actually running on one -- so the treadmill being used is the
-- one nearby WHILE that number is climbing.

local function poll_stat(scene, t)
    local now = read_save_stat(t.stat_field)
    if not now then
        if not t._warned_stat then
            t._warned_stat = true
            M.log(string.format("%s unreadable on SolidSave", tostring(t.stat_field)))
        end
        return {}
    end
    local delta = stat_last and (now - stat_last) or 0
    stat_last = now
    -- A negative step means a different save was loaded; start over.
    if delta <= 0 then return {} end

    local p = player_pos()
    if not p then return {} end
    local radius = tonumber(t.radius) or 1.2
    local need = tonumber(t.amount) or 100
    local out = {}
    for _, inst in ipairs(t.items) do
        if inst.scene == scene then
            if dist2(p, inst.x, inst.y, inst.z) <= radius * radius then
                local acc = (stat_progress[inst.name] or 0) + delta
                stat_progress[inst.name] = acc
                if acc >= need and not reported[inst.name] then
                    out[#out + 1] = inst
                end
            else
                -- Cleared on leaving, so only distance covered ON the
                -- treadmill counts. Running UP to one used to bank most of the
                -- total, which made the threshold fire long before the game's.
                stat_progress[inst.name] = 0
            end
        end
    end
    return out
end

--- True when a trigger is driven by destruction rather than by the award.
--- AP_LocationTriggers leaves these alone: sending on both would double up,
--- and the counted fallback would send a second, different name.
function M.owns(trigger_id)
    local t = instances_by_trigger[trigger_id]
    return t ~= nil and t.match ~= "nearest" and t.match ~= "object_active"
end

--- Send for anything that has started breaking since the last look.
---
--- Driven by the object rather than the PP award on purpose: the award only
--- comes the first time, so a check lost to a disconnect could never be
--- retried. Watching the object means reloading the area and breaking it again
--- sends it once more.
--- Best instance for an award, by the trigger's own match rule.
function match_award(t)
    if t.match == "player_dwell" or t.match == "nearest" then
        local p = player_pos()
        if not p then return nil end
        return closest(t.items, current_scene(), p.x, p.y, p.z,
            tonumber(t.radius) or NEAREST_LIMIT)
    end
    if t.match == "object_rotation" or t.match == "object_active"
            or t.match == "object_state" then
        -- object_state has no magnitude to rank on, but the index lookup is
        -- the same and a single live instance is still a confident answer.
        return (most_active(current_scene(), t))
    end
    return nil
end

--- Retry awards we could not place when they arrived.
local function poll_pending_awards()
    if next(pending_awards) == nil then return end
    local now = os.clock()
    for id, entry in pairs(pending_awards) do
        local inst = match_award(entry.t)
        if inst then
            pending_awards[id] = nil
            send_instance(id, entry.t, inst.name, "game awarded, matched late")
        elseif now >= entry.until_at then
            pending_awards[id] = nil
            local why = "?"
            local ok, r = pcall(match_report, current_scene(), entry.t)
            if ok then why = r end
            log(string.format(
                "%s: game awarded but no instance could be matched -- %s",
                id, why))
        end
    end
end

local function poll_broken()
    local scene = current_scene()
    if not scene then return end
    for id, t in pairs(instances_by_trigger) do
        if t.match == "object_broken" and t.om_type then
            local inst = find_breaking(scene, t.om_type, t.items)
            if inst then send_instance(id, t, inst.name, "destroyed") end
        elseif t.match == "object_state" and t.om_type and t.state_field then
            for _, inst in ipairs(poll_state(scene, t)) do
                send_instance(id, t, inst.name, "used")
            end
        elseif t.match == "object_rotation" and t.om_type and t.state_field then
            for _, inst in ipairs(poll_rotation(scene, t)) do
                if not queue_send(id, t, inst.name, "turned") then
                    send_instance(id, t, inst.name, "turned")
                end
            end
        elseif t.match == "player_dwell" then
            for _, inst in ipairs(poll_dwell(scene, t)) do
                if not queue_send(id, t, inst.name, "stood on") then
                    send_instance(id, t, inst.name, "stood on")
                end
            end
        elseif t.match == "player_stat" and t.stat_field then
            for _, inst in ipairs(poll_stat(scene, t)) do
                if not queue_send(id, t, inst.name, "ran on") then
                    send_instance(id, t, inst.name, "ran on")
                end
            end
        elseif t.match == "object_method" and t.om_type and t.method then
            install_method_hook(id, t)
        end
    end
end

--- Index every destroy-type trigger for the area the player is in.
---
--- Runs on arrival rather than on the first break: indexing skips anything
--- already breaking, so the object that triggered the first resolve would be
--- the one object that never got an identity.
local function index_current_scene()
    local scene = current_scene()
    if not scene then return end
    for _, t in pairs(instances_by_trigger) do
        -- Every object-driven strategy needs the index, not just the broken
        -- one: a rack that is never catalogued cannot be named when it spins.
        if t.om_type and t.match ~= "nearest" then
            ensure_index(scene, t.om_type, t.items)
        end
    end
end

M.index_current_scene = index_current_scene

local index_stride = 0

re.on_frame(function()
    -- Keep the area indexed while everything is still standing. Cheap: the
    -- scan only runs while an area has an unindexed destroy-type trigger.
    index_stride = index_stride + 1
    if index_stride >= 30 then
        index_stride = 0
        if next(instances_by_trigger) ~= nil then
            local scene = current_scene()
            if scene ~= last_scene then
                M.reset_index()
                last_scene = scene
            end
            index_current_scene()
        end
    end
    -- Every tick: rotation is integrated over time, and dwell is measured in
    -- seconds. Sampling these twice a second would lose most of the motion.
    if next(instances_by_trigger) ~= nil then poll_broken() end
    -- Awards held because the index was not ready when they arrived.
    poll_pending_awards()

    if #pending_sends > 0 then
        local now = os.clock()
        local keep = {}
        for _, q in ipairs(pending_sends) do
            if now >= q.due then
                send_instance(q.id, q.t, q.name, q.how)
            else
                keep[#keep + 1] = q
            end
        end
        pending_sends = keep
    end

    if #dry_pending == 0 then return end
    local batch = dry_pending
    dry_pending = {}
    for _, msg_no in ipairs(batch) do
        local id = trigger_for_msg(msg_no)
        if id then
            -- The game just announced it: release anything waiting on this
            -- trigger now, so its notification leads and ours follows.
            local keep = {}
            for _, q in ipairs(pending_sends) do
                if q.id == id then
                    send_instance(q.id, q.t, q.name, q.how .. ", game awarded")
                else
                    keep[#keep + 1] = q
                end
            end
            local flushed = #pending_sends ~= #keep
            pending_sends = keep
            local t = instances_by_trigger[id]

            -- Already sent for this trigger a moment ago: the award we are
            -- reacting to is the one we just reported.
            local just_sent = last_send_at[id]
                and (os.clock() - last_send_at[id]) < 3.0

            if t and not flushed and not just_sent and M.owns(id) then
                -- Nothing was waiting, so our detection missed it. The game
                -- says it happened, so send the best answer we have.
                local inst = match_award(t)
                if inst then
                    send_instance(id, t, inst.name, "game awarded")
                else
                    -- Hold it: the index may just not be built yet.
                    if not pending_awards[id] then
                        pending_awards[id] = {
                            t = t, until_at = os.clock() + AWARD_RETRY_SECONDS,
                        }
                        log(string.format(
                            "%s: game awarded, no instance yet -- retrying for %ds",
                            id, AWARD_RETRY_SECONDS))
                    end
                end
            end
            if t and t.match == "player_stat" then
                local p = player_pos()
                local radius = tonumber(t.radius) or 1.2
                for _, inst in ipairs(t.items) do
                    local acc = stat_progress[inst.name]
                    if acc and acc > 0 and p
                        and dist2(p, inst.x, inst.y, inst.z) <= radius * radius then
                        log(string.format(
                            "   award after %.0f units on %s (amount is set to %s)",
                            acc, inst.name, tostring(t.amount)))
                    end
                end
            end
            if t and t.match == "player_dwell" then
                for name, held in pairs(dwell) do
                    if held > 0 then
                        log(string.format(
                            "   award after %.1fs on %s (seconds=%s, move=%s)",
                            held, name, tostring(t.seconds),
                            tostring(player_move_input())))
                    end
                end
            end
            if dry_run then M.resolve(id) end
        elseif dry_run then
            -- Every PP award, matched or not. Silence otherwise cannot be
            -- told apart from the game never awarding -- which is what
            -- happens on a bonus already earned on this save.
            log(string.format("award msg %d (no trigger watches it)", msg_no))
        end
    end
end)

--- Resolve and log, but never send. Works in debug mode, with no slot and no
--- generated seed -- the positions describe the mall, not the seed.
_G.drap_pp_dryrun = function(on)
    dry_run = (on ~= false)
    if next(instances_by_trigger) == nil then M.setup(nil) end
    install_award_hook()
    index_current_scene()
    log(string.format("dry run %s", dry_run
        and "ON -- use each object; names are logged, nothing is sent" or "off"))
end

--- Watch an object type's state field and log every change.
---
--- For working out which state means "done" without guessing: run it, use the
--- object, and read the transitions.
---   drap_pp_watch("uOm1f", "mRno0", "solid.MT2RE.uOm1f.Rno0")
local watch_type, watch_field, watch_enum = nil, nil, nil
local watch_last = {}
local watch_names = nil

_G.drap_pp_watch = function(om_type, field, enum_type)
    watch_type = om_type and tostring(om_type) or nil
    watch_field = field and tostring(field) or "mRno0"
    watch_enum = enum_type and tostring(enum_type) or nil
    watch_last, watch_names = {}, nil
    if not watch_type then
        log("watch off")
        return
    end
    -- Report the count up front. A silent watch is ambiguous between "nothing
    -- happened" and "that type does not exist here" -- and uOm1f is easy to
    -- mistype as u0m1f, which looks identical in a console font.
    local n = 0
    for _ in pairs(objects_of_type(watch_type)) do n = n + 1 end
    log(string.format("watching %s.%s -- %d object(s) of that type here",
        watch_type, watch_field, n))
    if n == 0 then
        log("   nothing to watch. Check the spelling (capital O, not zero),")
        log("   or run drap_om() to see what types this area has.")
    end
end

local function watch_label(v)
    if not watch_enum then return tostring(v) end
    if watch_names == nil then
        watch_names = {}
        local td = safe(function() return sdk.find_type_definition(watch_enum) end)
        for _, f in ipairs((td and safe(function() return td:get_fields() end)) or {}) do
            local static = safe(function() return f:is_static() end)
            local literal = safe(function() return f:is_literal() end)
            if static and literal then
                local d = safe(function() return f:get_data(nil) end)
                if d ~= nil then watch_names[tonumber(d)] = f:get_name() end
            end
        end
    end
    return string.format("%s(%s)", watch_names[v] or "?", tostring(v))
end

local function poll_watch()
    if not watch_type then return end
    for addr, om in pairs(objects_of_type(watch_type)) do
        local now = tonumber(safe(function() return om:get_field(watch_field) end))
        local was = watch_last[addr]
        if was ~= now then
            watch_last[addr] = now
            if was ~= nil then
                local p = om_position(om)
                log(string.format("%s @%s  %s -> %s%s", watch_type, tostring(addr),
                    watch_label(was), watch_label(now),
                    p and string.format("  at (%.1f, %.1f, %.1f)", p.x, p.y, p.z) or ""))
            end
        end
    end
end

re.on_frame(function()
    if #method_pending == 0 then return end
    local batch = method_pending
    method_pending = {}
    local scene = current_scene()
    if not scene then return end
    for _, hit in ipairs(batch) do
        local t = instances_by_trigger[hit.id]
        if t then
            local map = ensure_index(scene, t.om_type, t.items)
            local inst = map[hit.addr]
            if inst then
                send_instance(hit.id, t, inst.name, "spun")
            else
                log(string.format("%s: %s at %s is not indexed",
                    hit.id, tostring(t.om_type), tostring(hit.addr)))
            end
        end
    end
end)

re.on_frame(poll_watch)

--- Watch EVERY readable field on a type, and report whatever changes.
---
--- For when the obvious field turns out not to move: uOm1f.mRno0 stayed put
--- through a whole cook, so the state lives somewhere else on the object.
---   drap_pp_watch_all("uOm1f")
local wa_type = nil
local wa_fields = nil
local wa_last = {}

_G.drap_pp_watch_all = function(om_type)
    wa_type = om_type and tostring(om_type) or nil
    wa_fields, wa_last = nil, {}
    if not wa_type then log("watch-all off"); return end

    local td = safe(function()
        return sdk.find_type_definition("solid.MT2RE." .. wa_type)
    end)
    if not td then log("no such type: " .. wa_type); return end
    -- Walk the parents too. uOm122 declares nothing of its own -- the turn
    -- state (mRot, mBeFlag) lives on cTurnSObj -- so its own field list is
    -- empty and watching only that reports nothing at all.
    wa_fields = {}
    local seen_field = {}
    local at, depth = td, 0
    while at and depth < 8 do
        for _, f in ipairs(safe(function() return at:get_fields() end) or {}) do
            local static = safe(function() return f:is_static() end)
            local nm = safe(function() return f:get_name() end)
            if not static and nm and not seen_field[nm] then
                seen_field[nm] = true
                wa_fields[#wa_fields + 1] = nm
            end
        end
        at = safe(function() return at:get_parent_type() end)
        depth = depth + 1
    end
    local n = 0
    for _ in pairs(objects_of_type(wa_type)) do n = n + 1 end
    log(string.format("watch-all %s: %d field(s) on %d object(s)",
        wa_type, #wa_fields, n))
end

--- Only scalars: an object reference prints as an address that churns.
local function scalar(v)
    local t = type(v)
    if t == "number" or t == "boolean" then return tostring(v) end
    if t == "userdata" then
        local n = tonumber(v)
        if n then return tostring(n) end
    end
    return nil
end

re.on_frame(function()
    if not (wa_type and wa_fields) then return end
    for addr, om in pairs(objects_of_type(wa_type)) do
        local prev = wa_last[addr]
        if prev == nil then prev = {}; wa_last[addr] = prev end
        for _, nm in ipairs(wa_fields) do
            local v = scalar(safe(function() return om:get_field(nm) end))
            if v ~= nil then
                if prev[nm] ~= nil and prev[nm] ~= v then
                    log(string.format("%s @%s  %s: %s -> %s",
                        wa_type, tostring(addr), nm, prev[nm], v))
                end
                prev[nm] = v
            end
        end
    end
end)

--- What is recorded, for one trigger or all of them.
_G.drap_pp_instances = function(trigger_id)
    if next(instances_by_trigger) == nil then M.setup(nil) end
    for id, t in pairs(instances_by_trigger) do
        if not trigger_id or id == trigger_id then
            log(string.format("%s (%s%s) -- %d instance(s):", id, t.match,
                t.om_type and (", " .. t.om_type) or "", #t.items))
            for i, inst in ipairs(t.items) do
                log(string.format("   %2d. %-52s %s (%.1f, %.1f, %.1f)",
                    i, inst.name, tostring(inst.scene), inst.x, inst.y, inst.z))
            end
        end
    end
end

return M
