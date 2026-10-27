-- DRAP/effects/CarlitoStay.lua
-- Drivin' Carlito stays in the Maintenance Tunnel after The Last Resort until
-- he is beaten, so "Beat Drivin Carlito" cannot be missed by finishing the
-- case first.
--
-- How the game places him: a model layout in the Maintenance Tunnel (s600,
-- class uEm55, his bomb truck with him) that loads when the game flow is
-- exactly 320 and 1284 EV_CARLITO3_DIE is off. Flow 320 is written by the
-- 11am meeting that opens the case; his death scene moves it to 330 and the
-- ramp at the end of the case to 340, so in the vanilla game he is gone once
-- the case is over. His save backup keeps the health he had, so a Carlito
-- left alive comes back at full health.
--
-- ScoopSanity only. Without it Drivin' Carlito is left exactly as the game
-- has him (gone once the case is over) and "Beat Drivin Carlito" is an
-- excluded location, so nothing here runs.
--
-- What this module does: on a door or warp into the tunnel, when
--   * ScoopSanity is on,
--   * he has been in reach in this slot: The Last Resort has finished in this
--     world (839 EV_SCQ_FINISH07 on), or DRAP remembers the 11am meeting or
--     the case being done from any world,
--   * he is not dead (1284 off) and the check has not been sent,
--   * the ending has not been reached (no Overtime, 312 off, flow under 1000),
-- the game flow is set to 320 before the tunnel loads, and the flow it had is
-- written back on the way out (on the door or warp out, or on the first frame
-- in another area if the tunnel was left some other way). DoorRandomizer's
-- areaJump hook only hands over the destination; every game call (flag reads,
-- the flow write) runs from the frame callback that drains it, never inside
-- the hook. The flow it
-- replaced is kept in the location ledger, so a reload inside the tunnel
-- still gives it back on leaving.
--
-- Why not 839 alone: Save and Start Over, or loading a save from before the
-- case, gives a world where 839 is off and his layout is gone again, while
-- the check is still unsent. A completed main is not handed out again after
-- a Start Over, so the case never replays; ScoopFinish's repair of the case
-- row does raise 839 again (measured 2026-10-26), but only once it runs.
-- The ledger (Complete Bomb Collector) and ScoopState's completed mains are
-- per slot and outlive both, so he is brought back whenever the case was
-- done once.
--
-- The check itself comes from 1284 (EventTracker's flag table): after the case
-- his death scene does not play, because it also waits on 296, which the case
-- clears when it ends.

local Shared = require("DRAP/Shared")

local M = Shared.create_module("CarlitoStay")

local TUNNEL = "s600"
local CARLITO_FLOW = 320
local DEATH_SCENE_FLOW = 330          -- his death scene's own write
local CASE_FINISH_FLAG = 839          -- EV_SCQ_FINISH07, The Last Resort
local CARLITO_DEAD_FLAG = 1284        -- EV_CARLITO3_DIE
local ENDING_FLAG = 312
local OVERTIME_FLOW = 1000            -- Overtime and later flows run from here up
local CHECK_NAME = "Beat Drivin Carlito"
local MEETING_CHECK = "Meet back at the Security Room at 11am day 3"
local CASE_CHECK = "Complete Bomb Collector"
local CASE_SCOOP = "The Last Resort"
local SECTION = "carlito_stay"
local LEAVE_GRACE_S = 60              -- an entry that never lands is undone after this

------------------------------------------------------------
-- Pure rules (tested without the game)
------------------------------------------------------------

--- Whether he has been in reach in this slot: the case finished in this
--- world, or the ledger / ScoopState remember the meeting or the case from
--- any world (a Start Over or an older save keeps those).
function M.was_reached(s)
    return s.case_done == true or s.meeting_seen == true or s.case_seen == true
end

--- Whether entering the tunnel now should bring him back.
--- s: { active, scoop_sanity, case_done, meeting_seen, case_seen, dead,
---      check_sent, endgame, ending_flag, flow }
--- Returns ok, reason.
function M.should_hold(s)
    if not s.active then return false, "no slot connected" end
    if s.scoop_sanity ~= true then return false, "ScoopSanity off" end
    if s.endgame or s.ending_flag then return false, "ending reached" end
    if not M.was_reached(s) then return false, "11am meeting and The Last Resort not reached" end
    if s.dead then return false, "already beaten" end
    if s.check_sent then return false, "check already sent" end
    if type(s.flow) ~= "number" then return false, "game flow unreadable" end
    if s.flow >= OVERTIME_FLOW then return false, "game flow in the Overtime range" end
    return true, nil
end

--- What to write back when leaving: the saved flow, or nil when the game has
--- moved the flow on its own since (anything but 320 or his death scene's
--- 330) and should be left alone.
function M.restore_value(saved, current_flow)
    if type(saved) ~= "table" or type(saved.old) ~= "number" then return nil end
    if current_flow ~= CARLITO_FLOW and current_flow ~= DEATH_SCENE_FLOW then return nil end
    if saved.old == current_flow then return nil end
    return saved.old
end

------------------------------------------------------------
-- Game access
------------------------------------------------------------

local function flow_manager()
    local td = Shared.safe(function()
        return sdk.find_type_definition("app.solid.gamemastering.InGameFlowManagerBase")
    end)
    local m = td and td:get_method("get_BaseInstance")
    return m and Shared.safe(function() return m:call(nil) end)
end

local function get_flow()
    local mgr = flow_manager()
    return mgr and tonumber(Shared.safe(function() return mgr:call("getGameFlow") end))
end

local function set_flow(v)
    local mgr = flow_manager()
    if not mgr then return false end
    return pcall(function() mgr:call("setGameFlow", v) end)
end

local function flag(id)
    local efm = sdk.get_managed_singleton("app.solid.gamemastering.EventFlagsManager")
    return efm and Shared.safe(function() return efm:call("evFlagCheck", id) end) == true
end

local function current_scene()
    local am = sdk.get_managed_singleton("app.solid.gamemastering.AreaManager")
    local p = am and Shared.safe(function() return am:get_field("CurrentLevelPath") end)
    return p and tostring(p):gsub("^SCN_", "") or nil
end

local function ledger() return package.loaded["DRAP/LocationLedger"] end
local function state() return package.loaded["DRAP/scoops/ScoopState"] end
local function activation() return package.loaded["DRAP/Activation"] end
local function unlocker() return package.loaded["DRAP/ScoopUnlocker"] end

local function scoop_sanity_on()
    local U = unlocker()
    if not (U and U.is_scoop_sanity_enabled) then return false end
    local ok, on = pcall(U.is_scoop_sanity_enabled)
    return ok and on == true
end

local record = nil          -- { old = flow } while the tunnel is held at 320
local entering_at = nil     -- os.clock() of the jump that set it
local pending = {}          -- destinations queued by the areaJump hook
local frame_no = 0

local function load_record()
    local L = ledger()
    if not (L and L.is_init and L.is_init()) then return record end
    local doc = L.get_section(SECTION)
    if type(doc) == "table" and type(doc.old) == "number" then return doc end
    return nil
end

local function save_record(r)
    record = r
    local L = ledger()
    if L and L.is_init and L.is_init() then L.set_section(SECTION, r or {}) end
end

local function snapshot()
    local A, S, L = activation(), state(), ledger()
    local ledger_ok = L ~= nil and L.is_init ~= nil and L.is_init()
    local function sent(name) return ledger_ok and L.is_checked(name) == true end
    return {
        active = A ~= nil and A.is_active ~= nil and A.is_active() == true,
        scoop_sanity = scoop_sanity_on(),
        case_done = flag(CASE_FINISH_FLAG),
        meeting_seen = sent(MEETING_CHECK),
        case_seen = sent(CASE_CHECK)
            or (S ~= nil and S.is_completed ~= nil and S.is_completed(CASE_SCOOP) == true),
        dead = flag(CARLITO_DEAD_FLAG),
        check_sent = sent(CHECK_NAME),
        endgame = S ~= nil and S.is_endgame_reached ~= nil and S.is_endgame_reached() == true,
        ending_flag = flag(ENDING_FLAG),
        flow = get_flow(),
    }
end

local function restore(why, note)
    note = note or ""
    local r = record or load_record()
    if not r then return end
    local cur = get_flow()
    local v = M.restore_value(r, cur)
    if v and set_flow(v) then
        M.log(string.format("Left the tunnel (%s): game flow %s -> %d%s", why, tostring(cur), v, note))
    else
        M.log(string.format("Left the tunnel (%s): game flow %s left as is%s", why, tostring(cur), note))
    end
    save_record(nil)
    entering_at = nil
end

------------------------------------------------------------
-- Door / warp: queued by the areaJump hook, handled on the next frame
------------------------------------------------------------

--- Called inside DoorRandomizer's areaJump pre-hook. Plain Lua only: it
--- records the destination and the frame, nothing else.
function M.queue_jump(dest)
    pending[#pending + 1] = { dest = dest, frame = frame_no }
end

local function scene_note()
    return string.format("scene %s", tostring(current_scene()))
end

--- dest: the scene code being entered ("s600"). Runs from the frame callback.
function M.on_jump(dest, frames)
    local note = frames and string.format(" (%d frame(s) after the door, %s)", frames, scene_note()) or ""
    if dest == TUNNEL then
        local s = snapshot()
        local ok, why = M.should_hold(s)
        if not ok then
            M.log("Entering the tunnel, no hold: " .. tostring(why) .. note)
            return
        end
        local r = record or load_record()
        if not r then
            if s.flow == CARLITO_FLOW then return end
            save_record({ old = s.flow })
        else
            record = r
        end
        entering_at = os.clock()
        if s.flow ~= CARLITO_FLOW and set_flow(CARLITO_FLOW) then
            M.log(string.format("Entering the tunnel: game flow %d -> %d for Drivin' Carlito%s",
                s.flow, CARLITO_FLOW, note))
        end
    elseif record or load_record() then
        restore("door to " .. tostring(dest), note)
    end
end

------------------------------------------------------------
-- Frame: the tunnel left without a door (reload elsewhere, title, ending)
------------------------------------------------------------

local next_check = 0

function M.on_frame()
    if not M:should_run() then return end
    local now = os.clock()
    if now < next_check then return end
    next_check = now + 0.5
    if not (record or load_record()) then return end
    if not Shared.is_in_game() then return end
    local scene = current_scene()
    if not scene or scene == "" then return end
    if scene == TUNNEL then
        entering_at = nil
        return
    end
    if entering_at and now - entering_at < LEAVE_GRACE_S then return end
    restore("now in " .. scene)
end

--- Drains the jump queue every frame, outside the main loop's in-game gate,
--- so a jump is handled on the first frame after the door.
function M.drain()
    frame_no = frame_no + 1
    if #pending == 0 then return end
    local batch = pending
    pending = {}
    local A = activation()
    if not (A and A.is_active and A.is_active()) then return end
    for _, j in ipairs(batch) do
        local ok, err = pcall(M.on_jump, j.dest, frame_no - j.frame)
        if not ok then M.log("jump handling failed: " .. tostring(err)) end
    end
end

function M.register()
    if re and re.on_frame then re.on_frame(M.drain) end
    local DR = package.loaded["DRAP/DoorRandomizer"]
    if DR and DR.add_jump_listener then
        DR.add_jump_listener(M.queue_jump)
    else
        M.log("DoorRandomizer has no jump listener -- the tunnel hold is off")
    end
end

return M
