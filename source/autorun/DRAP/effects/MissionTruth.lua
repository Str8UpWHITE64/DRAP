-- DRAP/effects/MissionTruth.lua
-- The ScoopSanity mission box and its directions, set up in the data the game
-- reads, so the game draws the right thing itself.
--
-- What the game reads:
--
--   SCQManager.mQueList[10]       the queued boxes. Main cases always use slot 0.
--   GUIHelper.getMissionList      filters it; the HUD list, the map list and the
--                                 info panel all come from it.
--   slot -> TblNo -> rSCQTable EventQueTable (mDispTblNo, mPosTblNo)
--   mDispTblNo -> DisplayListData row: title / info / hint message ids. The HUD
--                 list draws title + hint, the info panel and the map the info
--                 message (title, GOAL line and text in one).
--   MessageManager.getMessageGuid(id, list) finds the message's unit and walks
--                 its DataList. Case units carry conditions on the game's
--                 progress and resolve to nothing when out of step with it.
--   via.gui.message.get(Guid)     the text.
--   mPosTblNo -> rSCQParam.mScqPosInfoSets[n]: rows with start/end conditions;
--                 type 3 = room (mScqRoomTbl, routes the compass across areas),
--                 type 1 = position (mScqPosTbl, the marker). getGuidePosList
--                 feeds both the compass and the map icons from these.
--
-- So under ScoopSanity this module:
--   * points every main box row at one set of plain messages, and answers those
--     messages' GUIDs in message.get with the current text: the game's own for a
--     running mission, with its clock times taken out, and DRAP's for The Facts
--     and the status boxes, which have none that fits;
--   * answers the six borrowed survivor rows and the four scoops with no row of
--     their own (spare rows, for the 72 hours only) with DRAP's text;
--   * takes the clock times out of any other side box whose text has them;
--   * points every main queue table at one pos-info set holding an unconditional
--     room and position for the objective, so the compass routes to the right
--     area and the map marker sits on the objective;
--   * keeps exactly one main box queued whenever there is one to show;
--   * when doors are shuffled or locked, puts the compass on the door that
--     really leads onward, for the main box and for every queued side box.
-- No message is edited, so a box can only show the text set for its own row.

local M = {}

local Shared = require("DRAP/Shared")
local log = Shared.create_logger("MissionTruth")
M.log = log

local State = require("DRAP/scoops/ScoopState")
local SharedData = require("DRAP/SharedData")

local SCQ_T = "app.solid.gamemastering.SCQManager"
local MM_T = "app.solid.gamemastering.MessageManager"

local function pc(fn, ...) local ok, a = pcall(fn, ...); if ok then return a end return nil end
local function num(v) if v == nil then return nil end if type(v) == "number" then return v end return tonumber(tostring(v)) end

local function list_items(lst)
    local out = {}
    if not lst then return out end
    local n = num(pc(function() return lst:call("get_Count") end)) or 0
    for i = 0, n - 1 do out[#out + 1] = pc(function() return lst:call("get_Item", i) end) or false end
    return out
end

------------------------------------------------------------
-- State
------------------------------------------------------------

local enabled = false
local scoop_unlocker = nil       -- set in init (avoid require cycle)
local target = nil               -- the main box: { title, hint, combined, area, x, y, z }

------------------------------------------------------------
-- The main box: what it should say (DRAP state only)
------------------------------------------------------------

local WAITING_TITLE = "Waiting for Mission"
local WAITING_INFO = "Next mission will unlock once it is sent to you."
local START_TITLE = "Start a Mission"
local START_WHERE = "Archipelago window, Scoops tab"

local function make_target(title, info, loc, guide)
    loc = loc or "Anywhere"
    return {
        title = title,
        hint = info,
        combined = title .. "\r\nGOAL: " .. loc .. "\r\n" .. info,
        area = guide and guide.area or nil,
        x = guide and guide.x, y = guide and guide.y, z = guide and guide.z,
    }
end

-- The game's own text for a running mission: which message, and which of its
-- plain entries. A case's units hold one entry per story step, behind conditions
-- on the game's progress, so the entry is read directly and the conditions never
-- come into it. The Facts is not here: its text sends the player to the Hideout.
local GAME_TEXT = {
    ["Backup for Brad"]      = { title = { 1050, 1 }, info = { 1060, 1 }, hint = { 1415, 1 } },
    ["A Temporary Agreement"] = { title = { 1050, 3 }, info = { 1060, 3 }, hint = { 1415, 4 } },
    ["Image in the Monitor"] = { title = { 1051, 1 }, info = { 1061, 1 }, hint = { 1416, 1 } },
    ["Rescue the Professor"] = { title = { 1051, 2 }, info = { 1061, 2 }, hint = { 1416, 2 } },
    ["Medicine Run"]         = { title = { 1051, 3 }, info = { 1061, 3 }, hint = { 1416, 4 } },
    ["Professor's Past"]     = { title = { 1052, 1 }, info = { 1062, 1 }, hint = { 1417, 1 } },
    ["Girl Hunting"]         = { title = { 1053, 2 }, info = { 1063, 2 }, hint = { 1418, 2 } },
    ["A Promise to Isabela"] = { title = { 1054, 1 }, info = { 1064, 1 }, hint = { 1419, 1 } },
    ["Santa Cabeza"]         = { title = { 1055, 1 }, info = { 1065, 1 }, hint = { 1420, 1 } },
    ["The Last Resort"]      = { title = { 1056, 2 }, info = { 1066, 2 }, hint = { 1421, 2 } },
    ["Hideout"]              = { title = { 1057, 2 }, info = { 1067, 2 }, hint = { 1422, 2 } },
    ["Jessie's Discovery"]   = { title = { 1057, 3 }, info = { 1067, 3 }, hint = { 1422, 3 } },
    ["The Butcher"]          = { title = { 1057, 4 }, info = { 1067, 4 }, hint = { 1422, 4 } },
}
local game_text = {}              -- mission -> { title, info, hint }, read on the frame thread

--- The game's text without its clock: missions do not run to the game's schedule
--- here. The START line goes whole, a time inside a sentence goes from the
--- sentence, and the bomb count goes from the one hint that does not follow it.
local function strip_times(s)
    s = s:gsub("<COLOR %w+>START:[^\r\n]*</COLOR>\r?\n", "")
    s = s:gsub(" at %d+ [ap]%.m%. on %d+/%d+", "")
    s = s:gsub(" by %d+ [ap]%.m%. on %d+/%d+", "")
    s = s:gsub(" at noon on the %d+%a+", "")
    s = s:gsub(" at midnight", "")
    s = s:gsub(" %(%d+ to go!%)", "")
    return s
end

local function objective_text(name)
    local d = State.data(name)
    local desc = d and d.description
    if not desc then return "" end
    return desc.description or desc.trigger or ""
end

local function target_for_main(name)
    local d = State.data(name)
    local g = game_text[name]
    if g then
        return { title = g.title, hint = g.hint, combined = g.info,
                 area = d and d.guide and d.guide.area,
                 x = d and d.guide and d.guide.x, y = d and d.guide and d.guide.y, z = d and d.guide and d.guide.z }
    end
    local loc = d and d.description and d.description.location or nil
    return make_target(name, objective_text(name), loc, d and d.guide)
end

local function find_active_main()
    for _, s in ipairs(SharedData.scoops()) do
        if s.category == "Main" and scoop_unlocker.has_received_scoop(s.name)
            and not State.completed[s.name] then
            return s.name
        end
    end
    return nil
end

local GOAL_SAVIOR, GOAL_GENOCIDE, GOAL_PSYCHO = 2, 3, 4
local GOAL_DONE_TITLE = "Goal Complete"
local GOAL_DONE_INFO = "Return to the Security Room to finish the run."
local SECURITY_ROOM = { area = 288, x = 149.65, y = 9.25, z = 228.65 }

local function genocide_areas_left()
    local kt = AP and AP.KillTracker
    if not (kt and kt.progress) then return nil, nil end
    local ok, rows = pcall(kt.progress)
    if not ok or type(rows) ~= "table" or #rows == 0 then return nil, nil end
    local left, total = 0, 0
    for _, row in ipairs(rows) do
        total = total + 1
        if not row.done then left = left + 1 end
    end
    return left, total
end

--- The box for a count-based goal, or nil if this seed has none. Reads the
--- same progress() the goals themselves use.
local function goal_target()
    local goal = AP and tonumber(AP.Goal)
    if not goal then return nil end
    local ok_e, Ending = pcall(require, "DRAP/effects/EndingSequence")
    if ok_e and Ending and Ending.is_pending and Ending.is_pending() then
        return make_target(GOAL_DONE_TITLE, GOAL_DONE_INFO, "Security Room", SECURITY_ROOM)
    end
    if goal == GOAL_SAVIOR then
        local sg = AP and AP.effects and AP.effects.SaviorGoalEffects
        if not (sg and sg.progress) then return nil end
        local ok, n, t = pcall(sg.progress)
        if not ok or not n or not t then return nil end
        return make_target("Savior",
            string.format("Rescue %d survivors and escape. Rescued %d of %d.", t, n, t),
            "Security Room", nil)
    end
    if goal == GOAL_PSYCHO then
        local pg = AP and AP.effects and AP.effects.PsychoGoalEffects
        if not (pg and pg.progress) then return nil end
        local ok, n, t = pcall(pg.progress)
        if not ok or not n or not t then return nil end
        return make_target("Psycho",
            string.format("Kill %d survivors and escape. Killed %d of %d.", t, n, t),
            "Security Room", nil)
    end
    if goal == GOAL_GENOCIDE then
        local left, total = genocide_areas_left()
        if not left then return nil end
        if left == 0 then
            return make_target("Zombie Genocider",
                "Every area is cleared. Return to the Security Room", "Security Room", SECURITY_ROOM)
        end
        return make_target("Zombie Genocider", string.format(
            "Kill 53,594 zombies across the mall. %d of %d area%s still to clear.",
            left, total, left == 1 and "" or "s"), "Anywhere in the mall", nil)
    end
    return nil
end

-- The Facts: a route, not a spot. Its way to Jessie is Paradise Plaza ->
-- Warehouse -> Rooftop -> Security Room, so the box names the next leg and
-- the directions point at the area the leg ends in.
local FACTS = "The Facts"
local FACTS_LEGS = {
    s200 = { to = "s230", info = "Go to the Warehouse." },
    s230 = { to = "s231", info = "Go up to the Rooftop." },
    s231 = { to = "s136", info = "Go through the vent to the Security Room." },
}
local FACTS_ROUTE_START = "s200"

local function facts_running()
    return State.has_received(FACTS) and not State.completed[FACTS]
end

local function player_scene()
    local lock = AP and AP.DoorSceneLock
    local path = lock and lock.CurrentLevelPath
    return path and (tostring(path):gsub("^SCN_", "")) or nil
end

local function next_hop(from, goal)
    local graph = SharedData.area_graph()
    local prev, queue, head = { [from] = from }, { from }, 1
    while queue[head] do
        local cur = queue[head]; head = head + 1
        if cur == goal then break end
        for _, nb in ipairs(graph[cur] or {}) do
            if not prev[nb] then prev[nb] = cur; queue[#queue + 1] = nb end
        end
    end
    if not prev[goal] then return nil end
    local step = goal
    while prev[step] ~= from do step = prev[step] end
    return step
end

local function player_pos()
    local p = nil
    pcall(function()
        local pm = sdk.get_managed_singleton("app.solid.PlayerManager")
        local pl = pm and pm:call("get_CurrentPlayer")
        p = pl and pl:call("get_Transform"):call("get_Position")
    end)
    return p
end

local function door_to(scene, to)
    local lock = AP and AP.DoorSceneLock
    if not (lock and lock.door_triggers) then return nil end
    local p = player_pos()
    local best, best_d2 = nil, math.huge
    for _, t in ipairs(lock.door_triggers(scene)) do
        if (t.real or t.to) == to then
            local d2 = p and ((p.x - t.x) ^ 2 + (p.z - t.z) ^ 2) or 0
            if d2 < best_d2 then best, best_d2 = t, d2 end
        end
    end
    return best
end

local function scene_index(code)
    local si = Shared.SCENE_INFO and Shared.SCENE_INFO[code]
    return si and si.index or nil
end

local function facts_target()
    local scene = player_scene()
    if scene == "s136" then
        return make_target(FACTS,
            "Kill Zombie Jessie.",
            "Security Room", SECURITY_ROOM)
    end
    local info, to
    if FACTS_LEGS[scene] then
        info, to = FACTS_LEGS[scene].info, FACTS_LEGS[scene].to
    else
        to = scene and next_hop(scene, FACTS_ROUTE_START) or nil
        info = "Head to Paradise Plaza, then the Warehouse and the Rooftop, to reach the Security Room."
    end
    local area = to and Shared.SCENE_INFO and Shared.SCENE_INFO[to]
    local where = area and area.name or "Paradise Plaza"
    -- In the area: the marker on the door out; the room row then never
    -- applies (the player is in it). Elsewhere the compass routes to `to`.
    local door = to and scene and door_to(scene, to)
    local guide
    if door then
        guide = { area = scene_index(scene), x = door.x, y = door.y or 0, z = door.z }
    elseif to then
        guide = { area = scene_index(to) }
    end
    return make_target(FACTS, info, where, guide)
end

local function scene_of_index(index)
    for code, info in pairs(Shared.SCENE_INFO or {}) do
        if info.index == index then return code end
    end
    return nil
end

--- Directions for `guide` from where the player stands. The game's own route
--- across areas walks its vanilla portal table, so when doors are shuffled or
--- locked the compass goes to the door that really leads onward instead, and
--- the next area picks the next door. With no open way there, no direction.
local function directed(guide)
    if not (guide and guide.area) then return guide end
    local lock = AP and AP.DoorSceneLock
    if not (lock and lock.route_is_unreliable and lock.route_is_unreliable()) then return guide end
    local scene = player_scene()
    local goal = scene_of_index(guide.area)
    if not (scene and goal) or scene == goal then return guide end
    local p = player_pos()
    local door = lock.next_door(scene, goal, p and p.x, p and p.z)
    if door == nil then return guide end
    if not door then return {} end
    return { area = scene_index(scene), x = door.x, y = door.y or 0, z = door.z }
end

-- Under ScoopSanity the main box never shows the vanilla story objective:
-- the running mission, else the goal or a placeholder. The endgame leaves the
-- box to the engine (the finale plays normally).
local function main_target()
    if not scoop_unlocker then return nil end
    if State.is_endgame_reached() then return nil end
    if facts_running() then return facts_target() end
    if State.is_any_order() then
        local ao = State.any_order_status()
        if ao.running then return target_for_main(ao.running) end
        if #ao.startable == 1 then
            return make_target(START_TITLE, string.format(
                "%s is ready to start. Press Start next to it in the"
                .. " Scoops tab of the Archipelago window.", ao.startable[1]),
                START_WHERE, nil)
        elseif #ao.startable > 1 then
            return make_target(START_TITLE, string.format(
                "%d main missions are ready to start. Pick one in the"
                .. " Scoops tab of the Archipelago window.", #ao.startable),
                START_WHERE, nil)
        end
        return goal_target() or make_target(WAITING_TITLE, WAITING_INFO, nil, nil)
    end
    -- Received only: a story flag the game switches on (or DRAP holds on, as
    -- 272 is held to clear Brad out) does not make a mission the player's.
    local current = scoop_unlocker.get_current_chain_scoop()
    if current and scoop_unlocker.has_received_scoop(current)
        and not State.completed[current] then
        return target_for_main(current)
    end
    local active_main = find_active_main()
    if active_main then return target_for_main(active_main) end
    return goal_target() or make_target(WAITING_TITLE, WAITING_INFO, nil, nil)
end

local function compute_target()
    local t = main_target()
    if not t then return nil end
    local g = directed(t)
    if g ~= t then t.area, t.x, t.y, t.z = g.area, g.x, g.y, g.z end
    return t
end

------------------------------------------------------------
-- Owned rows
------------------------------------------------------------
-- A row is one DisplayListData entry. The game files its main boxes under
-- three entry types: 2 (the eight cases and The Facts), 3 (the case-slot
-- placeholder) and 4 (the story beats: the prologue, 72-Hour Nightmare, the
-- Overtime steps). Any of them can be queued under ScoopSanity -- a save made
-- in the prologue still carries "Start investigating!" -- and every one of
-- them shows the main box. They are all pointed at ONE set of messages (the
-- prologue row 51's three units, the only main messages with no conditions)
-- and every queue table that shows
-- one of them at ONE pos-info set (set 23, case 1's own), so whichever main
-- row the game has queued draws the same, current main box.
--
-- The six survivor scoops with no box of their own borrow a spare row each
-- (repurpose); those rows keep their own units and their own sets.
--
-- message.get answers exactly those messages' own GUIDs, read from their units
-- on the frame thread: under ScoopSanity nothing else shows them. The GUIDs must
-- be real ones: processMessage passes a unit's GUID to via.gui.message.getData
-- and dereferences the result unchecked, so an unknown GUID crashes the game.
--
-- Shared data is left alone: set 50 serves forty tables, and MesSys_0000 is
-- every empty hint in the game.

local LIST_OF_TYPE = { [0] = 0, [1] = 0x10, [2] = 0x12 }
local ROLES = {
    { role = 1, id = "mTitleMesId", type = "mTitleMesType" },
    { role = 2, id = "mInfoMesId", type = "mInfoMesType" },
    { role = 3, id = "mHintMesId", type = "mHintMesType" },
}
local MAIN_ROW = 51              -- "Start investigating!": three plain, unconditional messages
local MAIN_SET = 23              -- case 1's pos-info set: used by its table alone
local MAIN_POS = 23              -- mScqPosTbl entry only the main sets read

local repurposed = {}             -- disp_flag -> { name, title, combined, hint, area, x, y, z, pin }
local main_rows = {}              -- row index -> true
local survivor_rows = {}          -- row index -> repurposed entry
local side_rows = {}              -- row index -> side scoop name (its own box rows)
local side_by_flag = {}           -- entry flag -> side scoop name
local side_dirs = {}              -- row index -> { set, pos, area } for rows whose set is their own
local survivor_sets = {}          -- row index -> its own pos-info set
local main_tables = {}            -- queue table index -> true
local rows_known = false

-- The four scoops the game gives no box. Each takes a spare row, shown through a
-- table nothing runs, with text on two messages the game has retired (real GUIDs,
-- no row uses them) and a case set that goes unread while the main tables share
-- theirs. Rows 49 and 48 are Overtime's Cold Spray and Perfume Bottle; their own
-- tables and the row's own fields go back at the endgame, and only then, because
-- a row cannot change under a queued entry. All of it is memory; the entry flags
-- are spare ones Overtime never reads.
local OWN_BOXES = {
    { scoop = "The Convicts",   row = 19, table = 57, own_table = 25, entry = 2516, set = 24, pos = 26, title = 296, info = 297 },
    { scoop = "The Cult",       row = 26, table = 65, entry = 2523, set = 25, pos = 31, title = 298, info = 302 },
    { scoop = "Cletus",         row = 49, table = 67, own_table = 75, entry = 2515, set = 26, pos = 32, title = 303, info = 307 },
    { scoop = "Special Forces", row = 48, table = 76, own_table = 74, entry = 2536, set = 27, pos = 34, title = 308, info = 309 },
}
local OWN_TIME_TBL = 48           -- table 65's time entry: the whole 72 hours
local own_saved = nil             -- what the boxes changed, until it goes back
local own_data = {}               -- scoop name -> its entry in the shared data
local own_handback_since = nil

local side_times = {}             -- row index -> its info text without the clock, false if it has none

local function addr(o) return o and pc(function() return o:get_address() end) or nil end

------------------------------------------------------------
-- Text: message.get answers DRAP GUIDs, and only those
------------------------------------------------------------

-- texts[row][role] = the Lua text. The post-hook makes a fresh managed string
-- for each answer: a cached one kept with add_ref gets freed under the HUD, and
-- the game then crashes reading it in GUIHelper.getMissionMessage.
local texts = {}

local function set_text(row, role, s)
    texts[row] = texts[row] or {}
    texts[row][role] = s or ""
end

local hook_hits, hook_misses = 0, 0
local msg_hooked = false

-- mData1 -> { d2, d3, row, role }: the GUIDs DRAP answers, read from the
-- rows' own units. mData1 alone narrows to one candidate; data2/data3 confirm.
local owned_guids = {}

local function read_guid_parts(ptr)
    if not ptr then return nil end
    local vt = pc(function() return sdk.to_valuetype(ptr, "System.Guid") end)
    if not vt then return nil end
    local d1 = num(pc(function() return vt:get_field("mData1") end))
    local e = d1 and owned_guids[d1]
    if not e then return nil end
    if num(pc(function() return vt:get_field("mData2") end)) ~= e.d2
        or num(pc(function() return vt:get_field("mData3") end)) ~= e.d3 then return nil end
    return e.row, e.role
end

local function ensure_msg_hook()
    if msg_hooked then return true end
    -- Static, so args[2] points at the GUID. Called about 150 times a second
    -- with the HUD up, so the pre-hook only reads the argument's fields.
    local td = sdk.find_type_definition("via.gui.message")
    local m = td and td:get_method("get(System.Guid)")
    if not m then log("via.gui.message.get n/a"); return false end
    local ok = pcall(sdk.hook, m, function(args)
        if not enabled then return end
        local row, role = read_guid_parts(args[2])
        if not row then return end
        local st = thread.get_hook_storage()
        if st then st.mt_row, st.mt_role = row, role end
    end, function(retval)
        local st = thread.get_hook_storage()
        if not (st and st.mt_row) then return retval end
        local row, role = st.mt_row, st.mt_role
        st.mt_row, st.mt_role = nil, nil
        local s = texts[row] and texts[row][role]
        if s then
            local out
            pcall(function() out = sdk.to_ptr(sdk.create_managed_string(s)) end)
            if out then
                hook_hits = hook_hits + 1
                return out
            end
        end
        hook_misses = hook_misses + 1
        return retval
    end)
    msg_hooked = ok
    return ok
end

------------------------------------------------------------
-- Unit patching: one unconditional message per owned row and role
------------------------------------------------------------

local registered = {}             -- "row:role" -> mData1 registered for it

local function message_unit(mm, id, mtype)
    local list = LIST_OF_TYPE[mtype]
    if not list or not id or id == 0 then return nil end
    local name = pc(function() return mm:call("getMessageName", id, list) end)
    if not name then return nil end
    local li = num(pc(function() return mm:call("getSolidMessageListFromListType", list) end))
    if not li or li < 0 then return nil end
    local uds = pc(function() return mm:get_field("mSolidMessageUserDataList") end)
    local ud = uds and pc(function() return uds:call("get_Item", li) end)
    return ud and pc(function() return ud:call("getMessageData", tostring(name)) end) or nil
end

local function type_name(o) return pc(function() return o:get_type_definition():get_name() end) end

--- Answer `unit`'s GUID with DRAP's text for (row, role). Only a unit whose
--- DataList is one plain Raw entry is used: its GUID is then the one the game
--- asks for whatever its progress. Nothing in the unit is written.
local function register_unit(row, role, unit)
    local key = row .. ":" .. role
    local items = list_items(pc(function() return unit:get_field("DataList") end))
    if #items ~= 1 or not items[1] or type_name(items[1]) ~= "MessageDataRaw" then
        if registered[key] ~= false then
            log(string.format("row %d role %d: message has %d entries, not one plain one; not used",
                row, role, #items))
            registered[key] = false
        end
        return false
    end
    local g = pc(function() return items[1]:get_field("MessageId") end)
    local d1 = g and num(pc(function() return g:get_field("mData1") end))
    if not d1 or d1 == 0 then return false end
    if registered[key] ~= d1 then
        if registered[key] then owned_guids[registered[key]] = nil end
        owned_guids[d1] = { row = row, role = role,
                            d2 = num(pc(function() return g:get_field("mData2") end)),
                            d3 = num(pc(function() return g:get_field("mData3") end)) }
        registered[key] = d1
    end
    return true
end

local function restore_units()
    owned_guids, registered = {}, {}
end

local msg_get = nil

--- The text behind a message GUID, as the game's table has it.
local function guid_text(g)
    msg_get = msg_get or pc(function() return sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)") end)
    if not (g and msg_get) then return nil end
    local s = pc(function() return msg_get:call(nil, g) end)
    return s ~= nil and tostring(s) or nil
end

--- The n-th plain entry of a unit, whatever conditions sit around it.
local function nth_raw(unit, n)
    local seen = 0
    for _, e in ipairs(list_items(pc(function() return unit:get_field("DataList") end))) do
        if e and type_name(e) == "MessageDataRaw" then
            seen = seen + 1
            if seen == n then return pc(function() return e:get_field("MessageId") end) end
        end
    end
    return nil
end

local game_text_done = false

--- Read the missions' text once, on the frame thread. A message that cannot be
--- read leaves that mission on the mod's description, never on a blank.
local function load_game_text(mm)
    if game_text_done then return end
    local missing = 0
    for name, e in pairs(GAME_TEXT) do
        if not game_text[name] then
            local out = {}
            for role, ref in pairs(e) do
                local unit = message_unit(mm, ref[1], 0)
                local s = unit and guid_text(nth_raw(unit, ref[2]))
                if s and s ~= "" then out[role] = strip_times(s) end
            end
            if out.title and out.info and out.hint then game_text[name] = out else missing = missing + 1 end
        end
    end
    if missing == 0 then
        game_text_done = true
        log("game text read for every mission that has it")
    end
end

------------------------------------------------------------
-- Row and table repointing
------------------------------------------------------------

local row_orig = {}               -- row index -> { field -> value }
local table_orig = {}             -- table index -> original mPosTblNo

local function def_table(scq)
    return pc(function() return scq:get_field("mDefinitionTable"):get_field("mTable") end)
end

local function point_rows_at_main(rows)
    local src = rows[MAIN_ROW + 1]
    if not src then return end
    local vals = {}
    for _, R in ipairs(ROLES) do
        vals[R.id] = num(pc(function() return src:get_field(R.id) end))
        vals[R.type] = num(pc(function() return src:get_field(R.type) end))
    end
    for ri in pairs(main_rows) do
        local row = rows[ri + 1]
        if row and ri ~= MAIN_ROW then
            if not row_orig[ri] then
                local o = {}
                for k in pairs(vals) do o[k] = num(pc(function() return row:get_field(k) end)) end
                row_orig[ri] = o
            end
            for k, v in pairs(vals) do
                if num(pc(function() return row:get_field(k) end)) ~= v then
                    pcall(function() row:set_field(k, v) end)
                end
            end
        end
    end
end

local function point_tables_at_main_set(tables)
    for ti in pairs(main_tables) do
        local qt = tables[ti + 1]
        if qt then
            local cur = num(pc(function() return qt:get_field("mPosTblNo") end))
            if table_orig[ti] == nil then table_orig[ti] = cur end
            if cur ~= MAIN_SET then pcall(function() qt:set_field("mPosTblNo", MAIN_SET) end) end
        end
    end
end

local function restore_rows_tables()
    local scq = sdk.get_managed_singleton(SCQ_T)
    local dt = scq and def_table(scq)
    if not dt then return end
    local rows = list_items(pc(function() return dt:get_field("mDisplayDatas") end))
    for ri, o in pairs(row_orig) do
        local row = rows[ri + 1]
        if row then for k, v in pairs(o) do pcall(function() row:set_field(k, v) end) end end
        row_orig[ri] = nil
    end
    local tables = list_items(pc(function() return dt:get_field("mEventQueDatas") end))
    for ti, v in pairs(table_orig) do
        local qt = tables[ti + 1]
        if qt and v then pcall(function() qt:set_field("mPosTblNo", v) end) end
        table_orig[ti] = nil
    end
end

------------------------------------------------------------
-- Directions: an unconditional room + position
------------------------------------------------------------

-- getGuidePosList reads a set's rows in order: type 3 = room (an index into
-- mScqRoomTbl; while the player is elsewhere the compass routes there),
-- type 1 = position (an index into mScqPosTbl), type 0 = an NPC, type >= 5 ends
-- the list. Start/end type 0 = no condition.
local POS_FIELDS = { "mStType", "mStParam", "mEndType", "mEndParam", "mPosType", "mPosParam" }
local POS_ROOM, POS_SPOT, POS_OFF = 3, 1, 9

local function room_no(area_index)
    -- mScqRoomTbl holds an area's scene number as hex (s136 -> 0x136, sa00 ->
    -- 0xa00), what getGuidePosList compares with AreaManager.getAreaNoSub.
    for code, info in pairs(Shared.SCENE_INFO or {}) do
        if info.index == area_index then return tonumber(code:sub(2), 16) end
    end
    return nil
end

local set_orig = {}               -- set index -> { {field values} per row }

local function param_table(scq)
    return pc(function() return scq:get_field("mParamTable"):get_field("mTable") end)
end

local function room_index(pt, rn)
    local rooms = pc(function() return pt:get_field("mScqRoomTbl") end)
    local items = list_items(rooms)
    for i, v in ipairs(items) do if num(v) == rn then return i - 1 end end
    -- Not in the table (the Rooftop and the Warehouse are not): add it. Only
    -- DRAP's rows point past the vanilla entries.
    if not pcall(function() rooms:call("Add", rn) end) then return nil end
    return #items
end

--- Point pos-info set `si` at `guide` (area index and optional x/y/z) using
--- position entry `pos_idx`; with no guide the set gives no direction at all.
local function patch_set(scq, si, guide, pos_idx)
    local pt = param_table(scq)
    if not pt then return false end
    local sets = list_items(pc(function() return pt:get_field("mScqPosInfoSets") end))
    local set = sets[si + 1]
    if not set then return false end
    local rows = list_items(pc(function() return set:get_field("mSCQPosInfos") end))
    if #rows == 0 then return false end
    if not set_orig[si] then
        local orig = {}
        for i, r in ipairs(rows) do
            local o = {}
            for _, k in ipairs(POS_FIELDS) do o[k] = num(pc(function() return r:get_field(k) end)) end
            orig[i] = o
        end
        set_orig[si] = orig
    end
    local want = {}
    if guide and guide.area then
        local rn = room_no(guide.area)
        local ri = rn and pt and room_index(pt, rn)
        if ri then want[#want + 1] = { 0, 0, 0, 0, POS_ROOM, ri } end
    end
    if guide and guide.x and pos_idx then
        local pd = pc(function() return scq:call("getSCQPosData", pos_idx) end)
        if pd then
            pcall(function() pd:set_field("mPos", Vector3f.new(guide.x, guide.y or 0, guide.z)) end)
            want[#want + 1] = { 0, 0, 0, 0, POS_SPOT, pos_idx }
        end
    end
    for i, r in ipairs(rows) do
        local w = want[i] or { 0, 0, 0, 0, POS_OFF, 0 }
        for j, k in ipairs(POS_FIELDS) do
            if num(pc(function() return r:get_field(k) end)) ~= w[j] then
                pcall(function() r:set_field(k, w[j]) end)
            end
        end
    end
    return true
end

local function restore_sets()
    local scq = sdk.get_managed_singleton(SCQ_T)
    local pt = scq and param_table(scq)
    if not pt then return end
    local sets = list_items(pc(function() return pt:get_field("mScqPosInfoSets") end))
    for si, orig in pairs(set_orig) do
        local set = sets[si + 1]
        for i, r in ipairs(list_items(set and pc(function() return set:get_field("mSCQPosInfos") end))) do
            local o = orig[i]
            if o then for _, k in ipairs(POS_FIELDS) do pcall(function() r:set_field(k, o[k]) end) end end
        end
        set_orig[si] = nil
    end
end

------------------------------------------------------------
-- Discovering the rows from the game's own tables
------------------------------------------------------------

local function discover(scq)
    local dt = def_table(scq)
    if not dt then return false end
    local rows = list_items(pc(function() return dt:get_field("mDisplayDatas") end))
    if #rows == 0 then return false end
    main_rows, survivor_rows, survivor_sets, main_tables, side_rows = {}, {}, {}, {}, {}
    side_dirs = {}
    for i, row in ipairs(rows) do
        if row then
            local et = num(pc(function() return row:get_field("mDispEntryType") end))
            local ef = num(pc(function() return row:get_field("mDispEntryFlag") end))
            if et == 2 or et == 3 or et == 4 then
                main_rows[i - 1] = true
            elseif ef and repurposed[ef] then
                survivor_rows[i - 1] = repurposed[ef]
            end
            if not main_rows[i - 1] and ef and side_by_flag[ef] then side_rows[i - 1] = side_by_flag[ef] end
        end
    end
    local set_users = {}
    local tables = list_items(pc(function() return dt:get_field("mEventQueDatas") end))
    for ti, qt in ipairs(tables) do
        if qt then
            local d = num(pc(function() return qt:get_field("mDispTblNo") end))
            local p = num(pc(function() return qt:get_field("mPosTblNo") end))
            if d and main_rows[d] then main_tables[ti - 1] = true end
            -- Main tables are all pointed at the main set, so they do not count.
            if p and not (d and main_rows[d]) then set_users[p] = (set_users[p] or 0) + 1 end
            if d and side_rows[d] and not survivor_rows[d] and p and p ~= 60 and not side_dirs[d] then
                side_dirs[d] = { set = p }
            end
            if d and survivor_rows[d] and p and p ~= 60 then survivor_sets[d] = p end
        end
    end
    -- A borrowed set must be the survivor row's alone; else leave it be.
    for d, p in pairs(survivor_sets) do
        if (set_users[p] or 0) ~= 1 then survivor_sets[d] = nil end
    end
    -- A side row's directions, from its own set: the area from its room row,
    -- and the position entry it marks with. Without both, or with a set other
    -- rows use, it stays the game's.
    local pt = param_table(scq)
    local sets = list_items(pt and pc(function() return pt:get_field("mScqPosInfoSets") end))
    local rooms = list_items(pt and pc(function() return pt:get_field("mScqRoomTbl") end))
    for d, e in pairs(side_dirs) do
        local room, pos
        local set = sets[e.set + 1]
        for _, r in ipairs(list_items(set and pc(function() return set:get_field("mSCQPosInfos") end))) do
            local ty = r and num(pc(function() return r:get_field("mPosType") end))
            local pa = r and num(pc(function() return r:get_field("mPosParam") end))
            if ty == POS_ROOM and not room then room = num(rooms[pa + 1]) end
            if ty == POS_SPOT and not pos then pos = pa end
        end
        local info = room and Shared.SCENE_INFO and Shared.SCENE_INFO[string.format("s%03x", room)]
        if info and info.index and pos and set_users[e.set] == 1 then
            e.area, e.pos = info.index, pos
        else
            side_dirs[d] = nil
        end
    end
    for _, b in ipairs(OWN_BOXES) do
        main_tables[b.table] = nil
        side_rows[b.row] = nil
        side_dirs[b.row] = nil
    end
    local nm, ns, nt = 0, 0, 0
    for _ in pairs(main_rows) do nm = nm + 1 end
    for _ in pairs(survivor_rows) do ns = ns + 1 end
    for _ in pairs(main_tables) do nt = nt + 1 end
    log(string.format("main box rows %d (tables %d), borrowed survivor rows %d", nm, nt, ns))
    rows_known = true
    return true
end

------------------------------------------------------------
-- One main box: the queue holds exactly one main row
------------------------------------------------------------
-- After the prologue the queue can hold a case row in slot 0 next to the story
-- beats "Start investigating!" and "72-Hour Nightmare". With every main row
-- showing the same box that would be three copies of it. The queue ends an
-- entry by itself once its row's END flag is on (moveDispListQue) and never
-- re-queues a row whose END flag is on (checkQueDispTable), so every main row
-- but the one kept gets an END flag that is on now. The kept one keeps its own.
-- Nothing in the queue is written by hand.
--
-- With no main row queued at all, the box is asked for the game's way: the
-- entry flag of a case row whose END flags are off (a main row always goes
-- to slot 0, and only into an empty one).

local EFM_T = "app.solid.gamemastering.EventFlagsManager"
local end_orig = {}               -- row index -> its own mDispEndFlag
local ALWAYS_ON = { 769, 264, 263 } -- met Jessie / the prologue's end, checked live
local last_queue_note = nil

local function flag_on(efm, id)
    if not id or id == 0 then return false end
    return pc(function() return efm:call("evFlagCheck", id) end) == true
end

local function keep_row(row, ri)
    local o = end_orig[ri]
    if o == nil then return end
    if num(pc(function() return row:get_field("mDispEndFlag") end)) ~= o then
        pcall(function() row:set_field("mDispEndFlag", o) end)
    end
end

local function retire_row(efm, row, ri)
    local cur = num(pc(function() return row:get_field("mDispEndFlag") end))
    if end_orig[ri] == nil then end_orig[ri] = cur end
    if flag_on(efm, cur) then return true end
    local cand = { num(pc(function() return row:get_field("mDispEntryFlag") end)) }
    for _, f in ipairs(ALWAYS_ON) do cand[#cand + 1] = f end
    for _, f in ipairs(cand) do
        if flag_on(efm, f) then
            pcall(function() row:set_field("mDispEndFlag", f) end)
            return true
        end
    end
    return false
end

local side_note = {}
local empty_passes = 0

local function manage_queue(scq, rows, tables)
    local efm = sdk.get_managed_singleton(EFM_T)
    if not efm then return end
    local q = pc(function() return scq:get_field("mQueList") end)
    local n = num(pc(function() return q:get_size() end)) or 0
    local queued = {}
    for i = 0, n - 1 do
        local e = pc(function() return q:get_element(i) end)
        local st = e and num(pc(function() return e:get_field("State") end))
        if st == 1 or st == 2 then
            local r = pc(function() return e:get_field("CurrentDisplayData") end)
            local ri = r and num(pc(function() return r:get_field("mTableNo") end))
            if ri and main_rows[ri] then queued[#queued + 1] = { slot = i, row = ri } end
            -- A side scoop DRAP counts as done ends its box now, whichever way it
            -- was finished (the game's own end can lag, or never come when the
            -- check was sent another way).
            local sname = ri and side_rows[ri]
            if sname and State.completed[sname] then
                local row = rows[ri + 1]
                if row and retire_row(efm, row, ri) and not side_note[ri] then
                    side_note[ri] = true
                    log(string.format("side box of finished '%s' (row %d) retired", sname, ri))
                end
            end
        end
    end
    local keep = queued[1] and queued[1].row or nil   -- slot order: slot 0 first
    if keep then empty_passes = 0 end
    for ri in pairs(main_rows) do
        local row = rows[ri + 1]
        if row then
            if ri == keep then keep_row(row, ri)
            elseif end_orig[ri] ~= nil or (function()
                for _, x in ipairs(queued) do if x.row == ri then return true end end
                return false end)() then
                retire_row(efm, row, ri)
            end
        end
    end
    local note
    if keep then
        note = string.format("main box in slot %d (row %d), %d other main row(s) retired",
            queued[1].slot, keep, #queued - 1)
    elseif empty_passes < 2 then
        -- Wait three passes (about 6 s): right after a load the queue is
        -- still being restored, and a box asked for then lands next to the
        -- saved one.
        empty_passes = empty_passes + 1
        note = last_queue_note
    else
        -- Ask for one: a case row (entry type 2) whose END flags are both off.
        local asked
        for ri = 0, 8 do
            local row = rows[ri + 1]
            local et = row and num(pc(function() return row:get_field("mDispEntryType") end))
            if et == 2 then
                local entry = num(pc(function() return row:get_field("mDispEntryFlag") end))
                local rend = end_orig[ri] or num(pc(function() return row:get_field("mDispEndFlag") end))
                local tend
                for _, qt in ipairs(tables) do
                    if qt and num(pc(function() return qt:get_field("mDispTblNo") end)) == ri then
                        tend = num(pc(function() return qt:get_field("mQueEndFlag") end)); break
                    end
                end
                if entry and not flag_on(efm, rend) and not flag_on(efm, tend) then
                    keep_row(row, ri)
                    -- The queue reacts to the entry flag turning ON. One left on
                    -- from an entry that has since ended asks for nothing, so it
                    -- goes off for one pass and back on at the next.
                    if flag_on(efm, entry) then
                        pcall(function() efm:call("evFlagOff", entry) end)
                        asked = string.format("row %d (entry %d off, on next pass)", ri, entry)
                    else
                        pcall(function() efm:call("evFlagOn", entry) end)
                        asked = string.format("row %d (entry %d on)", ri, entry)
                    end
                    break
                end
            end
        end
        note = asked and ("no main box queued: asked for " .. asked)
            or "no main box queued and no case row free to ask for"
    end
    if note ~= last_queue_note then
        last_queue_note = note
        log(note)
    end
end

------------------------------------------------------------
-- Apply: text, units, rows, tables and directions
------------------------------------------------------------

--- Under the Psycho goal survivors are targets, so a box says so.
local function goal_words(s)
    if not State.is_psycho_mode() then return s end
    return (s:gsub("Rescue ", "Kill "):gsub("rescue ", "kill "))
end

local function patch_row_units(mm, rows, ri)
    local row = rows[ri + 1]
    if not row then return end
    for _, R in ipairs(ROLES) do
        local id = num(pc(function() return row:get_field(R.id) end))
        local ty = num(pc(function() return row:get_field(R.type) end))
        -- id 0 is MesSys_0000, the empty hint every side box shares: never ours.
        if id and id ~= 0 and not registered[ri .. ":" .. R.role] then
            local unit = message_unit(mm, id, ty)
            if unit then register_unit(ri, R.role, unit) end
        end
    end
end

local last_apply = 0

--- A side box whose game text carries a clock time answers with the text without
--- it. Read once; a row with no time is left to the game.
local function update_side_times(mm, rows)
    for ri in pairs(side_rows) do
        if side_times[ri] == nil and not survivor_rows[ri] then
            local row = rows[ri + 1]
            local id = row and num(pc(function() return row:get_field("mInfoMesId") end))
            local ty = row and num(pc(function() return row:get_field("mInfoMesType") end))
            local unit = id and id ~= 0 and message_unit(mm, id, ty)
            local s = unit and guid_text(nth_raw(unit, 1))
            if s then
                local cut = strip_times(s)
                side_times[ri] = cut ~= s and cut or false
            end
        end
        if side_times[ri] then
            set_text(ri, 2, side_times[ri])
            local row = rows[ri + 1]
            local unit = row and message_unit(mm, num(row:get_field("mInfoMesId")), num(row:get_field("mInfoMesType")))
            if unit and not registered[ri .. ":2"] then register_unit(ri, 2, unit) end
        end
    end
end

local ROW_FIELDS = { "mTitleMesId", "mTitleMesType", "mInfoMesId", "mInfoMesType",
                     "mDispEntryFlag", "mDispEntryParam", "mDispEndFlag" }
local TABLE_FIELDS = { "mDispFlag", "mDispTblNo", "mPosTblNo", "mTimeTblNo" }

local function set_if(o, k, v)
    if pc(function() return o:get_field(k) end) ~= v then pcall(function() o:set_field(k, v) end) end
end

--- Save the fields a box will change, once.
local function save_own(scq, rows, tables)
    if own_saved then return end
    local saved = {}
    for _, b in ipairs(OWN_BOXES) do
        local row, qt, own = rows[b.row + 1], tables[b.table + 1], b.own_table and tables[b.own_table + 1]
        local pd = pc(function() return scq:call("getSCQPosData", b.pos) end)
        local e = { row = {}, tbl = {}, pos = pd and pc(function() return pd:get_field("mPos") end) }
        for _, k in ipairs(ROW_FIELDS) do e.row[k] = pc(function() return row:get_field(k) end) end
        for _, k in ipairs(TABLE_FIELDS) do e.tbl[k] = pc(function() return qt:get_field(k) end) end
        e.own = own and pc(function() return own:get_field("mDispFlag") end)
        saved[b.row] = e
    end
    own_saved = saved
end

local function on_flag(efm)
    for _, f in ipairs(ALWAYS_ON) do if flag_on(efm, f) then return f end end
    return nil
end

--- Whether a scoop's box should be up: the same test the side boxes' own has.
local function own_box_wanted(name)
    return State.is_active(name) and not State.is_conflict_blocked(name)
        and not State.is_blocked_by_active_main(name) and State.has_prerequisites_met(name)
end

local function update_own_boxes(scq, mm, rows, tables)
    local efm = sdk.get_managed_singleton(EFM_T)
    if not efm then return end
    save_own(scq, rows, tables)
    own_handback_since = nil
    for _, b in ipairs(OWN_BOXES) do
        local row, qt, own = rows[b.row + 1], tables[b.table + 1], b.own_table and tables[b.own_table + 1]
        local s = own_data[b.scoop]
        if row and qt and s then
            if own then set_if(own, "mDispFlag", false) end
            set_if(row, "mTitleMesId", b.title); set_if(row, "mTitleMesType", 1)
            set_if(row, "mInfoMesId", b.info); set_if(row, "mInfoMesType", 1)
            set_if(row, "mDispEntryFlag", b.entry); set_if(row, "mDispEntryParam", b.entry)
            set_if(qt, "mDispTblNo", b.row); set_if(qt, "mPosTblNo", b.set)
            set_if(qt, "mTimeTblNo", OWN_TIME_TBL); set_if(qt, "mDispFlag", true)
            local box = s.box or {}
            local d = s.description or {}
            local goal, text = box.goal or d.location or "Anywhere", box.text or d.description or ""
            set_text(b.row, 1, b.scoop)
            set_text(b.row, 2, b.scoop .. "\r\nGOAL: " .. goal .. "\r\n" .. text)
            patch_row_units(mm, rows, b.row)
            patch_set(scq, b.set, box.area and directed(box) or nil, b.pos)
            if own_box_wanted(b.scoop) then
                set_if(row, "mDispEndFlag", 0)
                if not flag_on(efm, b.entry) then pcall(function() efm:call("evFlagOn", b.entry) end) end
            else
                local f = on_flag(efm)
                if f then set_if(row, "mDispEndFlag", f) end
                if flag_on(efm, b.entry) then pcall(function() efm:call("evFlagOff", b.entry) end) end
            end
        end
    end
end

local function own_entries_queued(scq)
    local q = pc(function() return scq:get_field("mQueList") end)
    local n = num(pc(function() return q:get_size() end)) or 0
    for i = 0, n - 1 do
        local e = pc(function() return q:get_element(i) end)
        local st = e and num(pc(function() return e:get_field("State") end))
        local tb = e and num(pc(function() return e:get_field("TblNo") end))
        if st and st ~= 0 then
            for _, b in ipairs(OWN_BOXES) do if b.table == tb then return true end end
        end
    end
    return false
end

--- Hand the spare rows back. The queue reads a row through its table, so the
--- entries end first (END on, entry off) and the fields go back once none is left.
local function finish_own_handback(force)
    if not own_saved then return end
    local scq = sdk.get_managed_singleton(SCQ_T)
    local dt = scq and def_table(scq)
    if not dt then return end
    if own_entries_queued(scq) and not force then return end
    local rows = list_items(pc(function() return dt:get_field("mDisplayDatas") end))
    local tables = list_items(pc(function() return dt:get_field("mEventQueDatas") end))
    for _, b in ipairs(OWN_BOXES) do
        local e = own_saved[b.row]
        local row, qt, own = rows[b.row + 1], tables[b.table + 1], b.own_table and tables[b.own_table + 1]
        if e and row and qt then
            for k, v in pairs(e.row) do pcall(function() row:set_field(k, v) end) end
            for k, v in pairs(e.tbl) do pcall(function() qt:set_field(k, v) end) end
            if own and e.own ~= nil then pcall(function() own:set_field("mDispFlag", e.own) end) end
            local pd = pc(function() return scq:call("getSCQPosData", b.pos) end)
            if pd and e.pos then pcall(function() pd:set_field("mPos", e.pos) end) end
        end
    end
    own_saved, own_handback_since = nil, nil
    log("spare rows handed back")
end

local function start_own_handback()
    if not own_saved or own_handback_since then return end
    local scq = sdk.get_managed_singleton(SCQ_T)
    local efm = sdk.get_managed_singleton(EFM_T)
    local dt = scq and def_table(scq)
    if not (dt and efm) then return end
    local rows = list_items(pc(function() return dt:get_field("mDisplayDatas") end))
    local f = on_flag(efm)
    for _, b in ipairs(OWN_BOXES) do
        local row = rows[b.row + 1]
        if row and f then set_if(row, "mDispEndFlag", f) end
        if flag_on(efm, b.entry) then pcall(function() efm:call("evFlagOff", b.entry) end) end
    end
    own_handback_since = os.clock()
end
--- Rows with a queued, live entry right now.
local function queued_rows(scq)
    local out = {}
    local q = pc(function() return scq:get_field("mQueList") end)
    local n = num(pc(function() return q:get_size() end)) or 0
    for i = 0, n - 1 do
        local e = pc(function() return q:get_element(i) end)
        local st = e and num(pc(function() return e:get_field("State") end))
        if st == 1 or st == 2 then
            local r = pc(function() return e:get_field("CurrentDisplayData") end)
            local ri = r and num(pc(function() return r:get_field("mTableNo") end))
            if ri then out[ri] = true end
        end
    end
    return out
end

--- Put a side row's set and position entry back to the game's.
local function restore_side_row(scq, e)
    local pt = param_table(scq)
    local sets = list_items(pt and pc(function() return pt:get_field("mScqPosInfoSets") end))
    local set = sets[e.set + 1]
    local orig = set_orig[e.set]
    for i, r in ipairs(list_items(set and pc(function() return set:get_field("mSCQPosInfos") end))) do
        local o = orig and orig[i]
        if o then for _, k in ipairs(POS_FIELDS) do pcall(function() r:set_field(k, o[k]) end) end end
    end
    set_orig[e.set] = nil
    if e.pos_orig then
        local pd = pc(function() return scq:call("getSCQPosData", e.pos) end)
        if pd then pcall(function() pd:set_field("mPos", e.pos_orig) end) end
    end
    e.stepped, e.pos_orig = nil, nil
end

--- A queued side box's compass: the same door step as the main box. Any other
--- time its set is the game's own, which also tracks the survivor by name.
local function update_side_directions(scq)
    local queued = queued_rows(scq)
    for ri, e in pairs(side_dirs) do
        local g = { area = e.area }
        if queued[ri] then g = directed({ area = e.area }) end
        if queued[ri] and not (g.area == e.area and not g.x) then
            if not e.stepped then
                local pd = pc(function() return scq:call("getSCQPosData", e.pos) end)
                e.pos_orig = pd and pc(function() return pd:get_field("mPos") end)
                e.stepped = true
            end
            patch_set(scq, e.set, g.area and g or nil, e.pos)
        elseif e.stepped then
            restore_side_row(scq, e)
        end
    end
end

local function restore_side_rows()
    local scq = sdk.get_managed_singleton(SCQ_T)
    if not scq then return end
    for _, e in pairs(side_dirs) do
        if e.stepped then restore_side_row(scq, e) end
    end
end

local function apply()
    if not enabled or not target then return end
    local scq = sdk.get_managed_singleton(SCQ_T)
    local mm = sdk.get_managed_singleton(MM_T)
    if not (scq and mm) then return end
    if not rows_known and not discover(scq) then return end
    local dt = def_table(scq)
    local rows = list_items(dt and pc(function() return dt:get_field("mDisplayDatas") end))
    local tables = list_items(dt and pc(function() return dt:get_field("mEventQueDatas") end))
    -- the main box
    set_text(MAIN_ROW, 1, target.title)
    set_text(MAIN_ROW, 2, target.combined)
    set_text(MAIN_ROW, 3, target.hint)
    patch_row_units(mm, rows, MAIN_ROW)
    point_rows_at_main(rows)
    point_tables_at_main_set(tables)
    pcall(manage_queue, scq, rows, tables)
    patch_set(scq, MAIN_SET, target.area and target or nil, MAIN_POS)
    -- the borrowed survivor boxes
    for ri, rp in pairs(survivor_rows) do
        set_text(ri, 1, rp.title)
        set_text(ri, 2, goal_words(rp.combined))
        set_text(ri, 3, goal_words(rp.hint))
        patch_row_units(mm, rows, ri)
        if survivor_sets[ri] then patch_set(scq, survivor_sets[ri], directed(rp), rp.pin) end
    end
    pcall(update_side_directions, scq)
    pcall(update_side_times, mm, rows)
    pcall(update_own_boxes, scq, mm, rows, tables)
end

local function restore_ends()
    local scq = sdk.get_managed_singleton(SCQ_T)
    local dt = scq and def_table(scq)
    local rows = list_items(dt and pc(function() return dt:get_field("mDisplayDatas") end))
    for ri, o in pairs(end_orig) do
        local row = rows[ri + 1]
        if row and o then pcall(function() row:set_field("mDispEndFlag", o) end) end
        end_orig[ri] = nil
    end
end

local function restore_all()
    pcall(start_own_handback)
    pcall(restore_side_rows)
    pcall(restore_ends)
    pcall(restore_units)
    pcall(restore_rows_tables)
    pcall(restore_sets)
end

------------------------------------------------------------
-- Refresh: recompute the main box when DRAP's state changes
------------------------------------------------------------

local function target_key(t)
    if not t then return "" end
    return t.title .. "\1" .. t.hint .. "\1" .. tostring(t.area)
        .. "\1" .. string.format("%.0f,%.0f", t.x or 0, t.z or 0)
end

function M.refresh()
    if not enabled then return end
    local t = compute_target()
    if target_key(t) == target_key(target) then return end
    target = t
    if t then
        log(string.format("box -> %q / %q (area %s)", t.title, t.hint, tostring(t.area)))
    else
        -- The endgame: the finale's boxes are the game's own again.
        log("no main box -- left to the engine")
        restore_all()
        return
    end
    pcall(apply)
end

------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------

local frame_installed = false
local last_tick = 0

function M.init(deps)
    scoop_unlocker = deps and deps.scoop_unlocker
    repurposed = {}
    for _, s in ipairs(SharedData.scoops()) do
        local rp = s.repurpose
        if rp and rp.title and s.disp_flag then
            repurposed[s.disp_flag] = {
                name = s.name,
                title = rp.title,
                hint = rp.desc or "",
                combined = rp.title .. "\r\nGOAL: " .. (rp.goal or "?") .. "\r\n" .. (rp.desc or ""),
                area = rp.area, x = rp.x, y = rp.y, z = rp.z, pin = rp.pin_slot,
            }
        end
    end
    side_by_flag = {}
    for _, s in ipairs(SharedData.scoops()) do
        own_data[s.name] = s
        if s.category ~= "Main" then
            if s.disp_flag then side_by_flag[s.disp_flag] = s.name end
            for _, f in ipairs(s.extra_disp_flags or {}) do side_by_flag[f] = s.name end
        end
    end
    rows_known = false
    side_times = {}
    if not frame_installed then
        frame_installed = true
        re.on_frame(function()
            local now = os.clock()
            if now - last_tick < 0.5 then return end
            last_tick = now
            -- Runs with the module off too: handing back can outlast the switch.
            if own_handback_since then
                pcall(finish_own_handback, now - own_handback_since > 30)
            end
            if not enabled then return end
            local mm = sdk.get_managed_singleton(MM_T)
            if mm then pcall(load_game_text, mm) end
            pcall(M.refresh)
            -- Re-assert every 2 s, in case a load rebuilds a table. The cost is
            -- a few field reads.
            if target and now - last_apply > 2.0 then
                last_apply = now
                pcall(apply)
            end
        end)
    end
    log("initialized")
end

function M.set_enabled(on)
    on = not not on
    if on == enabled then return end
    enabled = on
    if on then
        ensure_msg_hook()
        M.refresh()
        pcall(apply)
        log("enabled")
    else
        target = nil
        restore_all()
        log("disabled")
    end
end

function M.is_enabled() return enabled end
function M.current() return target end
function M.game_text() return game_text end
function M.side_times() return side_times end

--- What the box layer is doing: rows, patched units, sets, message.get answers.
_G.drap_mt_state = function()
    local function count(tb) local n = 0; for _ in pairs(tb) do n = n + 1 end; return n end
    local out = {
        main_rows = count(main_rows), main_tables = count(main_tables), survivor_rows = count(survivor_rows),
        units = count(owned_guids), rows_repointed = count(row_orig), tables_repointed = count(table_orig),
        sets = count(set_orig), hits = hook_hits, misses = hook_misses,
        game_text = count(game_text), own_saved = own_saved ~= nil,
        title = target and target.title, hint = target and target.hint, area = target and target.area,
    }
    log(string.format("rows %d main (%d repointed), %d survivor; units %d; sets %d; message.get answered %d (no text %d)",
        out.main_rows, out.rows_repointed, out.survivor_rows, out.units, out.sets, out.hits, out.misses))
    log(string.format("main box: %s", target and string.format("%q / %q (area %s)",
        target.title, target.hint, tostring(target.area)) or "none"))
    return out
end

return M
