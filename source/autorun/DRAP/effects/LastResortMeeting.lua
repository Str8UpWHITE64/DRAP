-- DRAP/effects/LastResortMeeting.lua
-- The Last Resort's meeting plays anywhere in the Security Room, not only from
-- the game's own box in the middle of it.
--
-- The truck bombs wait on 296 EV_EVENT35, and that comes with the meeting
-- (event 37, scene evm35), which the game starts from a walk-in box next to
-- door 517. Under ScoopSanity the case starts from the Scoops tab, wherever the
-- player is, and someone who comes in by the Rooftop door and leaves the same
-- way never touches the box.
--
-- The box itself can't simply be made bigger: it fires on a physics contact, so
-- someone already standing inside it when the case starts would get nothing. So
-- while the case runs, this checks the box's own conditions from the frame and,
-- once Frank is in the room and free, starts the same event the way the game's
-- waiting rows do (GameManager.doEventSet). The event row writes 296, 6, 2319
-- and the flow, and the check follows the event as it always does. Once 296 is
-- on the box's conditions fail, so it can't fire again, after a reload or
-- anywhere else.
--
-- ScoopSanity only. Without it the case runs on the game's own schedule.
--
-- Also logs what the tunnel holds on every entry, whatever the case is doing:
-- 296, the five "bomb placed" flags and the game flow.

local Shared = require("DRAP/Shared")
local PlayerReady = require("DRAP/PlayerReady")

local M = Shared.create_module("LastResortMeeting")

local CASE_SCOOP = "The Last Resort"
local SCENE = "evm35"
local MEETING_EVENT = 37
local ROOM_SCENE = "s136"
local TUNNEL_AREA = 1536
local CASE_START_FLAG = 294           -- EV_EVENT33_0
local CASE_QUEUE_FLAG = 775           -- EV_SCQ_START07
local MEETING_FLAG = 296              -- EV_EVENT35
local BOMB_PLACED_FLAGS = { 3329, 3330, 3331, 3332, 3333 }

-- The monitor room. Door 517 is at z 230.65 and everything behind it (the hall,
-- the stairs, the way to the Entrance Plaza and the Heliport) is further along z.
local ROOM = { x_min = 125.0, x_max = 170.0, y_min = 8.5, y_max = 11.0, z_min = 205.0, z_max = 230.3 }

local CHECK_EVERY = 0.25
local SETTLE_S = 1.0                  -- free and in the area this long first
local RETRY_S = 4.0
local MAX_TRIES = 3

------------------------------------------------------------
-- Pure rules (tested without the game)
------------------------------------------------------------

function M.in_room(p)
    return p ~= nil and p.x ~= nil and p.y ~= nil and p.z ~= nil
        and p.x >= ROOM.x_min and p.x <= ROOM.x_max
        and p.y >= ROOM.y_min and p.y <= ROOM.y_max
        and p.z >= ROOM.z_min and p.z <= ROOM.z_max
end

--- Whether the case wants its meeting now, before looking at where Frank is.
--- s: { scoop_sanity, case_active, case_started, case_queued, meeting_flag }
function M.wants_meeting(s)
    return s.scoop_sanity == true and s.case_active == true
        and s.case_started == true and s.case_queued == true
        and s.meeting_flag == false
end

------------------------------------------------------------
-- Game access
------------------------------------------------------------

local function flag(id)
    local efm = sdk.get_managed_singleton("app.solid.gamemastering.EventFlagsManager")
    if not efm then return nil end
    return Shared.safe(function() return efm:call("evFlagCheck", id) end)
end

local function level()
    local am = sdk.get_managed_singleton("app.solid.gamemastering.AreaManager")
    local p = am and Shared.safe(function() return am:get_field("CurrentLevelPath") end)
    return p and tostring(p):gsub("^SCN_", "") or nil
end

local function area_index()
    local am = sdk.get_managed_singleton("app.solid.gamemastering.AreaManager")
    return am and Shared.to_int(Shared.safe(function() return am:get_field("mAreaIndex") end)) or nil
end

local function player_pos()
    local pm = sdk.get_managed_singleton("app.solid.PlayerManager")
    local go = pm and Shared.safe(function() return pm:call("get_CurrentPlayer") end)
    local tr = go and Shared.safe(function() return go:call("get_Transform") end)
    local v = tr and Shared.safe(function() return tr:call("get_Position") end)
    if not v then return nil end
    return { x = v.x, y = v.y, z = v.z }
end

local function game_flow()
    local td = sdk.find_type_definition("app.solid.gamemastering.InGameFlowManagerBase")
    local m = td and td:get_method("get_BaseInstance")
    local mgr = m and Shared.safe(function() return m:call(nil) end)
    return mgr and tonumber(Shared.safe(function() return mgr:call("getGameFlow") end))
end

--- A Case File or help page holds the game on its back menu, and an area jump
--- does nothing then.
local function back_menu_clear()
    local gm = sdk.get_managed_singleton("app.solid.gamemastering.GameManager")
    local v = gm and Shared.safe(function() return gm:get_field("mBackMenuCurrentState") end)
    return tonumber(v) == 0
end

local function list_items(list)
    local out = {}
    if not list then return out end
    local n = tonumber(Shared.safe(function() return list:call("get_Count") end)) or 0
    for i = 0, n - 1 do
        out[#out + 1] = Shared.safe(function() return list:call("get_Item", i) end)
    end
    return out
end

local function field(o, a, b)
    local v = Shared.safe(function() return o:get_field(a) end)
    if v == nil and b then v = Shared.safe(function() return o:get_field(b) end) end
    return v
end

local function ahlm()
    return sdk.get_managed_singleton("app.solid.gamemastering.AreaHitLayoutManager")
end

--- The box's HIT_DATA in the loaded area, or nil.
local function find_box()
    local mgr = ahlm()
    if not mgr then return nil end
    for _, res in ipairs(list_items(field(mgr, "mAreaHitResource", "<mAreaHitResource>k__BackingField"))) do
        local pr = field(res, "pResource", "<pResource>k__BackingField")
        local td = pr and Shared.safe(function() return pr:get_type_definition():get_full_name() end)
        if td == "app.solid.gamemastering.rAreaHitLayout" then
            for _, li in ipairs(list_items(field(pr, "mpLayoutInfoList", "<mpLayoutInfoList>k__BackingField"))) do
                if tostring(field(li, "EVENT_NAME")) == SCENE then
                    return field(li, "mHitData", "<mHitData>k__BackingField")
                end
            end
        end
    end
    return nil
end

--- The box's own conditions, as the game checks them.
local function box_open(hd)
    local mgr = ahlm()
    local td = sdk.find_type_definition("app.solid.gamemastering.AreaHitLayoutManager")
    if not (mgr and td and hd) then return false end
    for _, name in ipairs({ "eventCheck", "noteventCheck", "sqoopCheck" }) do
        local m = td:get_method(name .. "(app.solid.gamemastering.HIT_DATA)")
        if not m or Shared.safe(function() return m:call(mgr, hd) end) ~= true then return false end
    end
    return true
end

local function scoop_sanity_on()
    local U = package.loaded["DRAP/ScoopUnlocker"]
    if not (U and U.is_scoop_sanity_enabled) then return false end
    local ok, on = pcall(U.is_scoop_sanity_enabled)
    return ok and on == true
end

local function snapshot()
    local S = package.loaded["DRAP/scoops/ScoopState"]
    return {
        scoop_sanity = scoop_sanity_on(),
        case_active = S ~= nil and S.is_active ~= nil and S.is_active(CASE_SCOOP) == true,
        case_started = flag(CASE_START_FLAG),
        case_queued = flag(CASE_QUEUE_FLAG),
        meeting_flag = flag(MEETING_FLAG),
    }
end

------------------------------------------------------------
-- The meeting
------------------------------------------------------------

local pending = false       -- start the event on the next UpdateBehavior
local tries = 0
local next_try = 0

local function reset_tries()
    tries = 0
    next_try = 0
end

--- The game starts its events from its update, so this does too.
local function drain()
    if not pending then return end
    pending = false
    local gm = sdk.get_managed_singleton("app.solid.gamemastering.GameManager")
    if not gm then return end
    local ok, err = pcall(function()
        gm:call("doEventSet(app.solid.gamemastering.EVENT_NO, System.UInt32, System.Boolean)", MEETING_EVENT, 0, false)
    end)
    if not ok then M.log("Could not start the meeting: " .. tostring(err)) end
end

local function check_meeting(now)
    if level() ~= ROOM_SCENE then reset_tries(); return end
    local s = snapshot()
    if not M.wants_meeting(s) then reset_tries(); return end
    if tries >= MAX_TRIES or now < next_try then return end
    if not PlayerReady.ready(SETTLE_S) or not back_menu_clear() then return end
    local p = player_pos()
    if not M.in_room(p) then return end
    local hd = find_box()
    if not (hd and box_open(hd)) then return end
    tries = tries + 1
    next_try = now + RETRY_S
    pending = true
    M.log(string.format("Frank is in the Security Room at (%.1f, %.1f, %.1f): starting The Last Resort's meeting (try %d)",
        p.x, p.y, p.z, tries))
    if tries >= MAX_TRIES then
        M.log("The meeting has not started after " .. MAX_TRIES .. " tries; waiting for the next area load")
    end
end

------------------------------------------------------------
-- The tunnel's log line
------------------------------------------------------------

local tunnel_logged = false

local function onoff(v) return v == true and "on" or (v == false and "off" or "?") end

local function check_tunnel()
    if area_index() ~= TUNNEL_AREA then tunnel_logged = false; return end
    if tunnel_logged or not PlayerReady.ready(SETTLE_S) then return end
    tunnel_logged = true
    local placed = {}
    for _, id in ipairs(BOMB_PLACED_FLAGS) do placed[#placed + 1] = onoff(flag(id)) end
    M.log(string.format("Tunnel entry: 296 %s, bombs placed (3329-3333) %s, game flow %s",
        onoff(flag(MEETING_FLAG)), table.concat(placed, " "), tostring(game_flow())))
end

------------------------------------------------------------
-- Frame
------------------------------------------------------------

local next_check = 0

function M.on_frame()
    local now = os.clock()
    if now < next_check then return end
    next_check = now + CHECK_EVERY
    if not Shared.is_in_game() then return end
    check_tunnel()
    if M:should_run() then check_meeting(now) end
end

function M.register()
    if re and re.on_pre_application_entry then
        re.on_pre_application_entry("UpdateBehavior", drain)
    end
end

return M
