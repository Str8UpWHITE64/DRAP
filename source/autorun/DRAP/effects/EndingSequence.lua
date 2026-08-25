-- DRAP/effects/EndingSequence.lua
-- Take a finished run to a real ending instead of letting it stop.
--
-- Savior, Psycho and Genocide used to end the moment the goal condition was
-- met: the check went out, the multiworld said won, and the game carried on
-- as if nothing had happened. This walks the game into one of its own endings
-- first, so the run finishes the way the game finishes.
--
-- HOW AN ENDING IS REACHED, measured in game:
--
--   Ending A   flags 356, 309 and 311 on, then the clock to day 4 12:01
--   Ending B   flag 356 on, then the same jump
--
-- 12:01 and not 12:00 -- noon exactly does not trigger it, the same way night
-- mode restores to 12:01 rather than parking on a due-time.
--
-- The flags are what makes a single jump enough. Without them the clock stops
-- at each cutscene along the way and has to be nudged again; 356 (EV_EVS05) is
-- the day 1 evening cutscene, and setting it means the jump runs straight to
-- the helicopter instead.
--
-- Ending B does NOT need Frank on the helipad. Measured: it plays from inside
-- the Security Room.
--
-- THE CLOCK IS WRITTEN, NOT TURBOED. TimeGate.set_game_time writes mClock,
-- which is the real clock; turbo would run the whole remaining story at speed
-- and fire every scheduled event and time-based check on the way past. See
-- BACKLOG for why set_mdate is not an option -- mDate is derived and the write
-- evaporates.
--
-- VICTORY GOES OUT AFTER THE ENDING, not when the goal is met. Flag 147
-- (EV_EVS25B) is Ending B and is confirmed not to be set by Ending A, so it
-- is a safe signal that this ending in particular has played.

local Shared = require("DRAP/Shared")

local M = Shared.create_module("EndingSequence")
M:set_throttle(0.5)

local EFM_TYPE = "app.solid.gamemastering.EventFlagsManager"
local AM_TYPE = "app.solid.gamemastering.AreaManager"

local efm_mgr = M:add_singleton("efm", EFM_TYPE)
local am_mgr = M:add_singleton("am", AM_TYPE)

-- Whether a cutscene is on screen. The Psycho sequence waits on this rather
-- than on a stopwatch, so a player who watches the invasion is not cut off
-- mid-scene and one who skips it does not sit waiting.
local ETM_TYPE = "app.solid.gamemastering.EventTimelineManager"
local etm_mgr = M:add_singleton("etm", ETM_TYPE)

local function event_playing()
    local etm = etm_mgr:get()
    if not etm then return nil end
    return Shared.safe(function() return etm:call("isEventPlaying") end)
end

-- The Security Room (s136), read from the game with drap_ending_status while
-- standing in it.
--
-- NOT derived from the scene code. It was 310 here on the theory that s136
-- means 0x136, and the goal endings never fired from a real run because of
-- it -- the area check simply never matched. s701 really is 1793 (0x701),
-- which is what made the theory look sound. Read the index, do not compute
-- it.
local SECURITY_ROOM_AREA = 288

-- Day 4 12:01.
local ENDING_DAY, ENDING_HOUR, ENDING_MINUTE = 4, 12, 1

-- EV_EVS05: the day 1 evening cutscene. Setting it is what lets one jump run
-- all the way instead of stopping at every scene.
local FLAG_SKIP_CUTSCENES = 356

-- The Special Forces pair, needed for Ending A only.
local FLAG_SF = 309
local FLAG_SF_EXCLUDE = 311

-- EV_EVS25B. Set when Ending B plays, and confirmed NOT set by Ending A.
local FLAG_ENDING_B = 147

-- EV_EVS13, set when the Special Forces capture begins -- watched during the
-- capture trace. It is what confirms the Psycho ending; 147 never arrives for
-- it.
local FLAG_PSYCHO_CAPTURE = 363

-- Meet Jessie. Nothing ending-shaped works before this: the story flags the
-- endings set are ignored outright -- 1311 was written and simply did not
-- take, which skips the Special Forces invasion and leaves the Psycho
-- sequence waiting for a cutscene that can never play.
local FLAG_MET_JESSIE = 769

-- The mall, already cleared. Measured: 146 + 151 spawns the mall's zombies
-- already dead, bodies on the ground, and NO Special Forces -- unlike the
-- 309/311 pair, which brings the soldiers and their music with it.
--
-- Leisure Park and the Maintenance Tunnels keep live zombies under this; they
-- are outside whatever the pair covers. Accepted: the beat is the mall itself
-- looking finished on the way back to the Security Room.
-- Zombie Jessie down. ScoopUnlocker already treats this as "the story has
-- nothing left to run" and jumps to Ending A on it.
local FLAG_ZOMBIE_JESSIE = 1311

-- The Psycho ending, measured in game.
--
-- Dying once the Special Forces have invaded puts Frank on their helicopter.
-- Firing the event by hand does NOT: startEvent(363) returns true, spawns the
-- helicopter and the guards, and never takes the player -- even standing on
-- its own scene (s701) at the exact position the real capture recorded. The
-- death is the first step of the sequence, not the last.
--
-- These flags skip the day 1-3 story so a single clock write can land on day
-- 4, leaving only the invasion cutscene to play. Narrowed by hand from a full
-- turbo trace; the EV_SCQ_* and EV_RADIO_MES_* traffic in that trace is the
-- game's own bookkeeping and does not need setting.
local PSYCHO_FLAGS = {
    1311,  -- EV_ZOMBIE_JESSIE_DIE: the story has nothing left to run
     356,  -- EV_EVS05: lets one clock write go all the way
     305,  -- EV_EVENT43
     306,  -- EV_EVENT44
     412,  -- EVM11_1700
     348,  -- EV_EVENT63
     349,  -- EV_EVENT64
}

-- Midnight is when they invade. The pre-death hop is so the LAST write to
-- 12:01 does not drag the sun from midnight to noon in one go.
--
-- 09:45 for the pre-death hop. A cutscene plays at 10:00 on day 4 and
-- interrupts the death, so the capture never starts -- 11:30, 11:15 and 10:30
-- all landed inside it. Stopping short of 10:00 is what leaves the death a
-- clear run.
local PSYCHO_INVASION = { 4, 0, 0 }
local PSYCHO_PRE_DEATH = { 4, 9, 45 }
local PSYCHO_FINISH = { 4, 12, 1 }

-- These are LIMITS, not waits. Each stage that follows a cutscene watches
-- isEventPlaying and moves on the moment the scene ends; the number is only
-- how long to wait for a scene that never starts (a player who skips, or a
-- cutscene that does not fire at all). Tunable with drap_psycho_delays.
local psycho_delays = {
    invasion = 45.0,   -- midnight -> the invasion cutscene is over
    settle   = 3.0,    -- how long the screen must stay clear before the death
    capture  = 45.0,   -- the death -> the capture is over
}

local FLAG_MALL_CLEARED_A = 146
local FLAG_MALL_CLEARED_B = 151

-- How long to let an area load settle before writing the clock. Jumping while
-- the load is still in flight is the sort of thing that half-applies.
local SETTLE_SECONDS = 5.0

------------------------------------------------------------
-- State
------------------------------------------------------------

-- What to send once the ending has played, or nil when nothing is pending.
local pending_goal_location = nil
-- Which ending the pending goal wants, and the flag that says it has played.
local pending_ending = "b"
local pending_done_flag = FLAG_ENDING_B
-- Set once the jump has been made, so it is not made twice.
local jumped = false
-- When the player was first seen in the Security Room, for the settle wait.
local in_room_since = nil
-- Psycho runs as a small sequence: which stage, its deadline, and whether a
-- cutscene has been seen during this stage.
local psycho_stage = nil
local psycho_at = nil
local psycho_saw_event = false
-- os.clock() since which nothing has been on screen, or nil while a scene is.
local psycho_quiet_since = nil
-- Flags this sequence turned on that were off before, so a run that does NOT
-- end can be put back. Forcing the day 1-3 story flags and then leaving them
-- set sends the rest of the run sideways -- Overtime autosaved with them on
-- and played the Carlito's Hideout cutscene, which cannot happen there.
local psycho_flags_raised = {}
-- So the "waiting for Meet Jessie" note is said once, not every frame.
local jessie_wait_logged = false

------------------------------------------------------------
-- Flags and the clock
------------------------------------------------------------

local function flag_off(id)
    local efm = efm_mgr:get()
    if not efm then return false end
    return pcall(function() efm:call("evFlagOff", id) end)
end

local function flag_on(id)
    local efm = efm_mgr:get()
    if not efm then return false end
    return pcall(function() efm:call("evFlagOn", id) end)
end

local function flag_is_on(id)
    local efm = efm_mgr:get()
    if not efm then return nil end
    return Shared.safe(function() return efm:call("evFlagCheck", id) end)
end

local function current_area()
    local am = am_mgr:get()
    if not am then return nil end
    return Shared.to_int(Shared.safe(function()
        return am:get_field("mAreaIndex")
    end))
end

--- Set the flags an ending needs and put the clock on its trigger.
--- @param flags integer[] event flags to raise first
--- @param reason string for the log
--- @return boolean whether the clock took the write
local function jump_to_ending(flags, reason)
    for _, id in ipairs(flags) do
        local ok = flag_on(id)
        M.log(string.format("%s: flag %d %s", reason, id, ok and "on" or "FAILED"))
    end

    local TimeGate = require("DRAP/TimeGate")
    local held = TimeGate.set_game_time(ENDING_DAY, ENDING_HOUR, ENDING_MINUTE)
    M.log(string.format("%s: clock -> day %d %02d:%02d %s", reason,
        ENDING_DAY, ENDING_HOUR, ENDING_MINUTE,
        held and "-- ending should play" or "-- CLOCK DID NOT HOLD"))
    return held
end

------------------------------------------------------------
-- Public
------------------------------------------------------------

--- Ending A, for the Ending S and Ending A goals. Called once Zombie Jessie is
--- down, which is the point the story has nothing left to run.
function M.jump_to_ending_a()
    return jump_to_ending({ FLAG_SKIP_CUTSCENES, FLAG_SF, FLAG_SF_EXCLUDE },
                          "Ending A")
end

--- Ending B, for the goals that have no ending of their own.
function M.jump_to_ending_b()
    return jump_to_ending({ FLAG_SKIP_CUTSCENES }, "Ending B")
end

--- Has the cutscene for this stage finished?
---
--- True once a scene has been seen and has ended, or once the limit passes
--- with no scene at all. Watching for the END rather than counting seconds is
--- what lets a player sit through the invasion without the death landing on
--- top of it.
local function stage_ready()
    local playing = event_playing()
    if playing == true then
        psycho_saw_event = true
        return false
    end
    if psycho_saw_event then return true end
    return os.clock() >= psycho_at
end

local function enter_stage(n, limit)
    psycho_stage = n
    psycho_at = os.clock() + limit
    psycho_saw_event = false
    psycho_quiet_since = nil
end

--- The Psycho ending: carried onto the Special Forces helicopter.
---
--- Runs as a sequence because each step needs the one before it to have
--- played:
---
---   1. flags + jump to day 4 00:00   the invasion cutscene plays
---   2. jump to day 4 11:30           so the last hop is not midnight -> noon
---   3. death                         the game turns this into the capture
---   4. jump to day 4 12:01           finishes the run
function M.jump_to_ending_psycho()
    psycho_flags_raised = {}
    for _, id in ipairs(PSYCHO_FLAGS) do
        -- Only ours to undo if it was not already set by the player's run.
        if flag_is_on(id) ~= true then
            table.insert(psycho_flags_raised, id)
        end
        local ok = flag_on(id)
        M.log(string.format("Psycho: flag %d %s", id, ok and "on" or "FAILED"))
    end
    local TimeGate = require("DRAP/TimeGate")
    local held = TimeGate.set_game_time(table.unpack(PSYCHO_INVASION))
    M.log(string.format("Psycho: clock -> day %d %02d:%02d %s -- invasion",
        PSYCHO_INVASION[1], PSYCHO_INVASION[2], PSYCHO_INVASION[3],
        held and "" or "(CLOCK DID NOT HOLD)"))
    enter_stage(1, psycho_delays.invasion)
    M.log("Psycho: stage 1 -- waiting for the invasion cutscene to finish")
    return held
end

--- One step of the Psycho sequence, from the frame loop.
local function advance_psycho()
    local TimeGate = require("DRAP/TimeGate")
    if psycho_stage == 1 then
        if not stage_ready() then return end
        -- No invasion means no Special Forces, and a death with no Special
        -- Forces is just a death: game over, the save reloads, and the stages
        -- after this write the clock onto a run that never asked for it.
        -- Seen on a save that had already been through an ending -- the jump
        -- back to midnight did not replay the cutscene.
        if not psycho_saw_event then
            M.log("Psycho: the invasion never played -- NOT dealing the death."
                .. " Falling back to Ending B so the run still finishes.")
            -- Put the story back. These only make sense with the ending they
            -- were set for; left on, the run carries them into Overtime.
            for _, id in ipairs(psycho_flags_raised) do
                flag_off(id)
                M.log("Psycho: flag " .. id .. " back off")
            end
            psycho_flags_raised = {}
            psycho_stage = nil
            psycho_at = nil
            pending_ending = "b"
            pending_done_flag = FLAG_ENDING_B
            M.jump_to_ending_b()
            return
        end
        TimeGate.set_game_time(table.unpack(PSYCHO_PRE_DEATH))
        M.log(string.format("Psycho: stage 2 -- clock -> day %d %02d:%02d,"
            .. " waiting for a clear screen",
            PSYCHO_PRE_DEATH[1], PSYCHO_PRE_DEATH[2], PSYCHO_PRE_DEATH[3]))
        enter_stage(2, psycho_delays.settle + 30.0)
    elseif psycho_stage == 2 then
        -- The death needs a clear screen: landing it under a cutscene is what
        -- broke 11:30, 11:15 and 10:30. Wait for a QUIET run rather than a
        -- single sample -- and take the deadline as an escape hatch, because
        -- "return while something is playing" with no limit is a hang, not a
        -- wait.
        local now = os.clock()
        if event_playing() == true then
            psycho_quiet_since = nil
        elseif psycho_quiet_since == nil then
            psycho_quiet_since = now
        end
        local quiet_enough = psycho_quiet_since
            and (now - psycho_quiet_since) >= psycho_delays.settle
        if not quiet_enough and now < psycho_at then return end
        if not quiet_enough then
            M.log("Psycho: never got a clear screen -- dealing the death anyway")
        end
        local ok, DeathLink = pcall(require, "DRAP/trackers/DeathLink")
        if ok and DeathLink and DeathLink.kill_player then
            M.log("Psycho: stage 3 -- dealing the death")
            pcall(DeathLink.kill_player, "psycho ending")
        else
            M.log("Psycho: DeathLink unavailable -- cannot deal the death")
        end
        enter_stage(3, psycho_delays.capture)
    elseif psycho_stage == 3 then
        if not stage_ready() then return end
        TimeGate.set_game_time(table.unpack(PSYCHO_FINISH))
        M.log(string.format("Psycho: clock -> day %d %02d:%02d -- done",
            PSYCHO_FINISH[1], PSYCHO_FINISH[2], PSYCHO_FINISH[3]))
        psycho_stage = nil
        psycho_at = nil
    end
end

--- Empty the mall, as the Genocider's own reward.
---
--- Only for that goal: the player killed 53,594 zombies, so the walk back to
--- the Security Room should be through the aftermath. Any other goal leaves
--- the mall alone. Measured: 146 + 151 spawns the mall's zombies already dead
--- with no Special Forces.
function M.clear_the_mall()
    flag_on(FLAG_MALL_CLEARED_A)
    flag_on(FLAG_MALL_CLEARED_B)
    -- Read back rather than announce. "flags on" only ever meant "evFlagOn
    -- was called", and a write that does not take looks identical -- which is
    -- exactly how 1311 hid a pre-Jessie failure.
    M.log(string.format(
        "mall clear: flag %d reads %s, flag %d reads %s"
        .. " (the enemy set is re-picked on the next area load)",
        FLAG_MALL_CLEARED_A, tostring(flag_is_on(FLAG_MALL_CLEARED_A)),
        FLAG_MALL_CLEARED_B, tostring(flag_is_on(FLAG_MALL_CLEARED_B))))
end

--- The goal is met. Hold its check back, take the player to an ending, and
--- send it once that ending has played.
---
--- The check is what yields the Victory item, so holding it holds the win. A
--- run quit part way through re-arms on the next load, because the goal
--- condition that got here is re-derived rather than remembered.
---
--- @param goal_location string the location to check once the ending is done
--- @param opts table|nil ending = "b" (default) or "psycho";
---                       clear_mall = true for the Genocider's empty mall
function M.request_ending(goal_location, opts)
    if pending_goal_location then return end
    opts = opts or {}
    pending_goal_location = goal_location
    pending_ending = opts.ending or "b"
    pending_done_flag = (pending_ending == "psycho")
        and FLAG_PSYCHO_CAPTURE or FLAG_ENDING_B
    jumped = false
    in_room_since = nil
    if opts.clear_mall then pcall(M.clear_the_mall) end
    M.log(string.format(
        "goal reached -- head to the Security Room and the run will finish"
        .. " (%s, ending %s)", tostring(goal_location), pending_ending))
    local ok, Notify = pcall(require, "DRAP/Notify")
    if ok and Notify and Notify.send then
        pcall(Notify.send, "Goal complete -- return to the Security Room.")
    end
end

--- Whether an ending is waiting to play.
function M.is_pending()
    return pending_goal_location ~= nil
end

local function send_pending_goal()
    local name = pending_goal_location
    pending_goal_location = nil
    if not name then return end
    M.log(string.format("ending played -- sending %s", name))
    if AP and AP.AP_BRIDGE and AP.AP_BRIDGE.check then
        AP.AP_BRIDGE.check(name)
    end
end

function M.on_frame()
    if not pending_goal_location then return end
    if not M:should_run() then return end
    if not Shared.is_in_game() then return end
    if jumped then return end

    -- Before Meet Jessie the game discards the flags an ending needs, so
    -- jumping here burns the attempt and finishes nothing.
    if flag_is_on(FLAG_MET_JESSIE) ~= true then
        if not jessie_wait_logged then
            jessie_wait_logged = true
            M.log("ending held -- Meet Jessie has not happened yet, and the"
                .. " story flags an ending needs will not stick before it")
        end
        return
    end

    -- Wait for the Security Room, and for its load to settle. Writing the
    -- clock mid-transition is asking for half of it to apply.
    if current_area() ~= SECURITY_ROOM_AREA then
        in_room_since = nil
        return
    end
    if in_room_since == nil then
        in_room_since = os.clock()
        return
    end
    if os.clock() - in_room_since < SETTLE_SECONDS then return end

    jumped = true
    if pending_ending == "psycho" then
        M.jump_to_ending_psycho()
    else
        M.jump_to_ending_b()
    end
end

--- Forget a pending ending. Used when a save is loaded into a different run.
function M.reset()
    pending_goal_location = nil
    jessie_wait_logged = false
    pending_ending = "b"
    pending_done_flag = FLAG_ENDING_B
    jumped = false
    in_room_since = nil
end

------------------------------------------------------------
-- Console
------------------------------------------------------------

_G.drap_ending_a = function() M.jump_to_ending_a() end
_G.drap_ending_b = function() M.jump_to_ending_b() end

_G.drap_ending_status = function()
    M.log(string.format(
        "pending=%s jumped=%s area=%s (security room is %d) flag %d=%s",
        tostring(pending_goal_location), tostring(jumped),
        tostring(current_area()), SECURITY_ROOM_AREA,
        FLAG_ENDING_B, tostring(flag_is_on(FLAG_ENDING_B))))
end

--- Test the Psycho ending without a Psycho seed.
---
--- Sets Zombie Jessie's flag, jumps to day 4 midnight for the Special Forces
--- invasion, and deals the death once it has played.
-- The Psycho sequence drives itself.
--
-- main.lua only calls module on_frame while Activation is active AND the
-- player is in game, and this sequence breaks both: the death and the capture
-- cutscene take the player out of "in game", and testing happens offline. A
-- half-run sequence leaves the clock at midnight with no ending, so it gets
-- its own loop and is gated on nothing but having been asked for.
-- Watching for the ending to play, off main's gated loop.
--
-- main.lua only calls module on_frame while activated AND in game, and an
-- ending is exactly when "in game" stops being true -- the Psycho capture
-- runs to a game-over screen and then the menu. Waiting for the confirming
-- flag there would mean the goal check never goes out and the player never
-- wins, having done everything right.
re.on_frame(function()
    if not pending_goal_location then return end
    if flag_is_on(pending_done_flag) == true then
        send_pending_goal()
    end
end)

re.on_frame(function()
    if not psycho_stage then return end
    local ok, err = pcall(advance_psycho)
    if not ok then
        M.log("Psycho: stage failed -- " .. tostring(err))
        psycho_stage = nil
        psycho_at = nil
    end
end)

_G.drap_psycho_ending = function() return M.jump_to_ending_psycho() end

--- Retune the gaps without a redeploy: invasion, settle, capture (seconds).
--- Limits, not waits: how long to allow for a cutscene that never starts.
_G.drap_psycho_delays = function(invasion, settle, capture)
    psycho_delays.invasion = tonumber(invasion) or psycho_delays.invasion
    psycho_delays.settle   = tonumber(settle)   or psycho_delays.settle
    psycho_delays.capture  = tonumber(capture)  or psycho_delays.capture
    M.log(string.format("Psycho delays: invasion=%.1fs settle=%.1fs capture=%.1fs",
        psycho_delays.invasion, psycho_delays.settle, psycho_delays.capture))
end

return M
