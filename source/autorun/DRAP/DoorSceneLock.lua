-- DRAP/DoorSceneLock.lua
-- Disables doors by toggling HIT_DATA.mHitData.Disabled for locked scenes

local Shared = require("DRAP/Shared")
local SharedData = require("DRAP/SharedData")
local Activation = require("DRAP/Activation")

local M = Shared.create_module("DoorSceneLock")
local testing_mode = false

------------------------------------------------------------
-- Singleton Managers
------------------------------------------------------------

local am_mgr   = M:add_singleton("am", "app.solid.gamemastering.AreaManager")
local ahlm_mgr = M:add_singleton("ahlm", "app.solid.gamemastering.AreaHitLayoutManager")

------------------------------------------------------------
-- Scene Metadata (shared with DoorRandomizer via DRAP/Shared)
------------------------------------------------------------

local SCENE_INFO = Shared.SCENE_INFO

------------------------------------------------------------
-- Lock State
------------------------------------------------------------

local LOCKED_SCENES = {
    ["s140"] = false,
    ["s135"] = false,
    ["s136"] = false,
    ["s231"] = true,
    ["s230"] = true,
    ["s200"] = true,
    ["s503"] = true,
    ["s700"] = true,
    ["s400"] = true,
    ["s501"] = true,
    ["sa00"] = true,
    ["s300"] = true,
    ["s900"] = true,
    ["s500"] = true,
    ["s100"] = true,
    ["s600"] = true,
    ["s401"] = true,
    ["s601"] = true,
}

------------------------------------------------------------
-- Split Keys Lock State
------------------------------------------------------------

-- Split Keys locks a single door rather than a whole scene, so the state is
-- keyed origin -> destination. Built from drdr_shared.json when the option is
-- on; empty otherwise.
local LOCKED_SPLIT = {}
local split_keys_enabled = false

------------------------------------------------------------
-- Door Locks State
------------------------------------------------------------

-- Door Locks keeps the area keys in play with the doors shuffled, so a door
-- has to be judged by where it now leads rather than by its vanilla target.
-- The graph the AP world sends matches its own logic; without the option the
-- vanilla graph from shared data still applies.
local door_locks_enabled = false
local shuffled_area_graph = nil

------------------------------------------------------------
-- Public State
------------------------------------------------------------

M.CurrentLevelPath = nil
M.CurrentAreaIndex = nil

------------------------------------------------------------
-- Internal State
------------------------------------------------------------

local HITDATA_PATCHES = {}
local last_area_index = nil
local last_level_path = nil
local pending_rescan = false
local _warned_no_graph = false

-- Connecting mid-session has to re-judge the doors it left alone while
-- dormant. Declared after pending_rescan so the closure captures the local.
Activation.on_activate(function() pending_rescan = true end)

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function scene_is_locked(scene_code)
    if testing_mode then return false end
    return LOCKED_SCENES[scene_code] == true
end

-- The Entrance Plaza door names the dummy Security Room (s138) as its target;
-- SceneFixups catches that trigger and sends the player to the real s136
-- instead. Both lock tables are keyed on the real scene, so without this the
-- door reads as ungated and Split Keys never locks it.
local SCENE_ALIASES = {
    ["s138"] = "s136",
}

-- Split Keys replaces the area keys entirely, so no area key ever arrives to
-- unlock a scene. The per-door state governs instead of the scene state.
local function door_is_locked(origin_code, destination_code)
    if testing_mode then return false end
    -- Every scene below starts locked and only an arriving key item opens
    -- one, so with no slot connected these would never open at all.
    if not Activation.is_active() then return false end
    destination_code = SCENE_ALIASES[destination_code] or destination_code
    if split_keys_enabled then
        local from = LOCKED_SPLIT[origin_code]
        return from ~= nil and from[destination_code] == true
    end
    return LOCKED_SCENES[destination_code] == true
end

-- Where this door leads right now. Only Door Locks needs the answer: with the
-- option off every area key is precollected, so the vanilla target and the
-- real one are both unlocked and asking would change nothing.
local function effective_destination(level_path, jump_name, hit_data)
    if not door_locks_enabled then return jump_name end
    local DR = AP and AP.DoorRandomizer
    if not (DR and DR.resolve_destination) then return jump_name end
    return DR.resolve_destination(level_path, jump_name, hit_data) or jump_name
end

local function current_area_graph()
    if shuffled_area_graph and next(shuffled_area_graph) then
        return shuffled_area_graph
    end
    return SharedData.area_graph()
end

-- The prologue route. Before Meet Jessie the player MUST walk the Security
-- Room <-> Entrance Plaza doorway for the opening cutscene, and no key for it
-- can exist yet; after Jessie the key governs it like any other door. The game
-- barricades the doorway itself in between, so nothing is lost by leaving it
-- open until then.
--
-- This replaced an event-name test that also treated EVENT_NONE -- i.e. no
-- event running, the normal state -- as a reason to unlock, which left the
-- door open from the Security Room side for most of a run. Reported twice as
-- "the Security Room to Entrance Plaza door works without its split key", and
-- only in that direction, because the old test also required being in s136.
local function is_prologue_doorway(origin_code, destination_code)
    origin_code = SCENE_ALIASES[origin_code] or origin_code
    destination_code = SCENE_ALIASES[destination_code] or destination_code
    return (origin_code == "s136" and destination_code == "s100")
        or (origin_code == "s100" and destination_code == "s136")
end

-- Cached because the flag is unreadable inside the load window, and guessing
-- either way there is bad: guess "met" and the prologue door locks with no key
-- in existence; guess "not met" and the key is bypassable. Starts true (a run
-- begins before Jessie) and only ever moves on a successful read.
local before_jessie = true

local function refresh_jessie_state()
    local SU = AP and AP.ScoopUnlocker
    if not (SU and SU.has_met_jessie) then return end
    local met = SU.has_met_jessie()
    if met ~= nil then before_jessie = (met == false) end
end

-- Whether one door should be shut, given the layout's vanilla target and its
-- HIT_DATA. Kept apart from the scan so it can be tested without standing up
-- the whole reflection walk.
--
-- The prologue exception keys on the vanilla target, not on where the door now
-- leads: it identifies the Security Room's mall door, which the player has to
-- walk through for the opening cutscene. The game barricades that doorway
-- itself until Jessie, so the mod has no business locking it -- and the door
-- is still that doorway however the shuffle rerouted it.
function M.should_disable_door(level_path, origin_code, jump_name, hit_data, pre_jessie)
    if jump_name == nil or jump_name == "" then return false end
    -- Keyed on the doorway's own identity, not where it now leads: under Door
    -- Locks the shuffle moves the destination, and the prologue still has to
    -- be walkable.
    if pre_jessie and is_prologue_doorway(origin_code, jump_name) then
        return false
    end
    return door_is_locked(origin_code,
                          effective_destination(level_path, jump_name, hit_data))
end


local function get_area_info()
    local am = am_mgr:get()
    if not am then return nil, nil end

    local area_index = nil
    local level_path = nil

    local area_index_f = am_mgr:get_field("mAreaIndex", false)
    if area_index_f then
        local v = Shared.safe_get_field(am, area_index_f)
        if v then area_index = Shared.to_int(v) end
    end

    local level_path_f = am_mgr:get_field("CurrentLevelPath", false) or
                         am_mgr:get_field("<CurrentLevelPath>k__BackingField", false)
    if level_path_f then
        local v = Shared.safe_get_field(am, level_path_f)
        if v then level_path = tostring(v) end
    else
        local ok, v = pcall(sdk.call_object_func, am, "get_CurrentLevelPath")
        if ok and v then level_path = tostring(v) end
    end

    return area_index, level_path
end

------------------------------------------------------------
-- HitData Patching
------------------------------------------------------------

local function disable_hitdata(layout_info, hitdata)
    if not layout_info or not hitdata then return false end

    local ok_get, cur = pcall(hitdata.get_field, hitdata, "Disabled")
    if not ok_get then return false end
    if cur == true then return false end

    local ok_set = pcall(hitdata.set_field, hitdata, "Disabled", true)
    if not ok_set then return false end

    HITDATA_PATCHES[layout_info] = { disabled = true }
    return true
end

local function enable_hitdata(layout_info, hitdata)
    if not layout_info or not hitdata then return false end

    local ok_get, cur = pcall(hitdata.get_field, hitdata, "Disabled")
    if not ok_get then return false end
    if cur == false then return false end

    local ok_set = pcall(hitdata.set_field, hitdata, "Disabled", false)
    if not ok_set then return false end

    HITDATA_PATCHES[layout_info] = nil
    return true
end

------------------------------------------------------------
-- Door Scanning
------------------------------------------------------------

-- Each door's own trigger, as the engine has it: HIT_DATA carries the
-- interaction point (mCursorWorldPos) and its cylinder (mRadius, mHeight).
-- Recorded on every scan so DoorPromptOverlay can speak from the same
-- volume the engine prompts from, instead of a landing-spot anchor.
-- scene_code -> list of { to = jump_name, x, y, z, radius, height }
local door_triggers = {}

function M.door_triggers(scene_code)
    return door_triggers[scene_code] or {}
end

local function record_trigger(origin_code, jump_name, hitdata, li)
    if not origin_code then return end
    local pos = Shared.safe(function() return hitdata:get_field("mCursorWorldPos") end)
    local x, y, z
    pcall(function() x = pos.x; y = pos.y; z = pos.z end)
    if not x or (x == 0 and y == 0 and z == 0) then
        pos = Shared.safe(function() return li:get_field("CHECK_MESSAGE_POS_") end)
        pcall(function() x = pos.x; y = pos.y; z = pos.z end)
    end
    if not x then return end
    local list = door_triggers[origin_code]
    if not list then list = {}; door_triggers[origin_code] = list end
    table.insert(list, {
        to = jump_name, x = x, y = y, z = z,
        radius = tonumber(Shared.safe(function() return hitdata:get_field("mRadius") end)) or 0,
        height = tonumber(Shared.safe(function() return hitdata:get_field("mHeight") end)) or 0,
    })
end

local function rescan_current_area_doors()
    local area_index, level_path = get_area_info()
    M.CurrentLevelPath = level_path
    M.CurrentAreaIndex = area_index
    refresh_jessie_state()

    -- Which side of the door the player is standing on ("SCN_s200" -> "s200")
    local origin_code = level_path and (tostring(level_path):gsub("^SCN_", "")) or nil
    if origin_code then door_triggers[origin_code] = {} end

    local ahlm = ahlm_mgr:get()
    if not ahlm then return end

    local res_field = ahlm_mgr:get_field("mAreaHitResource", false) or
                      ahlm_mgr:get_field("<mAreaHitResource>k__BackingField", false)
    if not res_field then return end

    local res_list = Shared.safe_get_field(ahlm, res_field)
    if not res_list then return end

    for r_i, res in Shared.iter_collection(res_list) do
        if res then
            local pResource_val = Shared.get_field_value(res, {"pResource", "<pResource>k__BackingField"})
            if pResource_val then
                local pRes = pResource_val
                local pRes_td = pRes:get_type_definition()

                if pRes_td and pRes_td:get_full_name() == "app.solid.gamemastering.rAreaHitLayout" then
                    local layout_list_val = Shared.get_field_value(pRes, {"mpLayoutInfoList", "<mpLayoutInfoList>k__BackingField"})

                    if layout_list_val then
                        for li_i, li in Shared.iter_collection(layout_list_val) do
                            if li then
                                local jump_name = Shared.get_field_value(li, {"AREA_JUMP_NAME", "<AREA_JUMP_NAME>k__BackingField"})
                                jump_name = jump_name and tostring(jump_name) or ""

                                local event_name = Shared.get_field_value(li, {"EVENT_NAME", "<EVENT_NAME>k__BackingField"})
                                event_name = event_name and tostring(event_name) or ""

                                local mHitData_val = Shared.get_field_value(li, {"mHitData", "<mHitData>k__BackingField"})

                                -- Special case for Food Court
                                if jump_name == "" and event_name == "evm12" then
                                    jump_name = "sa00"
                                end

                                if mHitData_val and jump_name ~= "" then
                                    record_trigger(origin_code, jump_name, mHitData_val, li)
                                    if M.should_disable_door(level_path, origin_code,
                                                             jump_name, mHitData_val, before_jessie) then
                                        disable_hitdata(li, mHitData_val)
                                    else
                                        enable_hitdata(li, mHitData_val)
                                    end
                                elseif mHitData_val and HITDATA_PATCHES[li] then
                                    enable_hitdata(li, mHitData_val)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if origin_code then
        M.log(string.format("%s: %d door trigger(s) recorded for the key hint",
            origin_code, #(door_triggers[origin_code] or {})))
    end
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

function M.lock_scene(scene_code)
    scene_code = tostring(scene_code)
    LOCKED_SCENES[scene_code] = true
    -- Try to rescan now, but also flag for retry if managers aren't ready
    pending_rescan = true
    rescan_current_area_doors()
end

function M.unlock_scene(scene_code)
    scene_code = tostring(scene_code)
    LOCKED_SCENES[scene_code] = nil
    -- Try to rescan now, but also flag for retry if managers aren't ready
    pending_rescan = true
    rescan_current_area_doors()
end

function M.is_scene_locked(scene_code)
    return scene_is_locked(tostring(scene_code))
end

------------------------------------------------------------
-- Split Keys
------------------------------------------------------------

-- Turning the option on locks every transition in the shared data; the keys
-- open them one at a time as they arrive.
function M.set_split_keys_enabled(enabled)
    split_keys_enabled = enabled == true
    LOCKED_SPLIT = {}

    if split_keys_enabled then
        local count = 0
        for _, entry in ipairs(SharedData.split_areas()) do
            for _, t in ipairs(entry.transitions or {}) do
                if t.origin and t.destination then
                    LOCKED_SPLIT[t.origin] = LOCKED_SPLIT[t.origin] or {}
                    LOCKED_SPLIT[t.origin][t.destination] = true
                    count = count + 1
                end
            end
        end
        M.log(string.format("Split Keys enabled, %d transitions locked", count))
    else
        M.log("Split Keys disabled")
    end

    pending_rescan = true
    rescan_current_area_doors()
end

function M.unlock_transition(origin_code, destination_code)
    local from = LOCKED_SPLIT[tostring(origin_code)]
    if from then from[tostring(destination_code)] = nil end
    -- Deliberately no immediate rescan. Reconnecting replays every split key
    -- at once, which is 48 unlocks, and each rescan walks the area's layout
    -- list through reflection. on_frame drains pending_rescan next tick.
    pending_rescan = true
end

function M.is_transition_locked(origin_code, destination_code)
    return door_is_locked(tostring(origin_code), tostring(destination_code))
end

function M.get_split_keys_enabled()
    return split_keys_enabled
end

------------------------------------------------------------
-- Door Locks
------------------------------------------------------------

-- graph is the AP world's {scene_code = {scene_code, ...}} of where the doors
-- actually lead. Passing nil falls back to the vanilla graph in shared data.
function M.set_door_locks_enabled(enabled, graph)
    door_locks_enabled = enabled == true
    shuffled_area_graph = (door_locks_enabled and type(graph) == "table") and graph or nil

    if door_locks_enabled then
        local edges = 0
        for _, targets in pairs(shuffled_area_graph or {}) do edges = edges + #targets end
        if edges > 0 then
            M.log(string.format("Door Locks enabled, %d edges in the shuffled graph", edges))
        else
            -- Without the graph the search would answer for the vanilla mall
            -- while the player walks a shuffled one, which reads as scoops
            -- refusing to start for no visible reason.
            M.log("Door Locks enabled but no area graph was sent -- reachability"
                .. " will follow the vanilla layout and may be wrong")
        end
    end

    pending_rescan = true
    rescan_current_area_doors()
end

function M.get_door_locks_enabled()
    return door_locks_enabled
end

------------------------------------------------------------
-- Reachability
------------------------------------------------------------

-- Which areas the player could walk to from the safe room right now, given
-- whatever doors are open. Recomputed per call -- the answer changes every
-- time a key arrives, and the graph is 17 nodes.
--
-- This is the only question that survives every mode. Area keys lock by
-- destination scene, Split Keys by transition, and plain door randomization
-- locks nothing at all (every key is precollected), so a search over the live
-- lock state answers all of them without a key list per mode.
--
-- The edges are the vanilla ones except under Door Locks, which sends the
-- shuffled graph. Plain door randomization can keep walking the vanilla graph:
-- nothing is locked, so the search reports everything reachable either way.
function M.reachable_areas(start_code)
    start_code = tostring(start_code or "s136")
    local graph = current_area_graph()
    local seen = { [start_code] = true }
    local queue, head = { start_code }, 1
    while head <= #queue do
        local at = queue[head]
        head = head + 1
        for _, to in ipairs(graph[at] or {}) do
            if not seen[to] and not door_is_locked(at, to) then
                seen[to] = true
                queue[#queue + 1] = to
            end
        end
    end
    return seen
end

function M.can_reach_area(area_code, start_code)
    if not area_code then return false end
    -- An old reframework/data/drdr_shared.json has no area_graph, and without
    -- it every area reads as unreachable -- which would defer every scoop
    -- forever and look exactly like a hang. Answer yes when we cannot answer
    -- at all; the rules still gate the checks either way.
    if not next(current_area_graph()) then
        if not _warned_no_graph then
            _warned_no_graph = true
            M.log("area_graph missing from shared data -- scoop reachability"
                .. " gating is off (update reframework/data/drdr_shared.json)")
        end
        return true
    end
    return M.reachable_areas(start_code)[tostring(area_code)] == true
end

function M.is_on_title_screen()
    return M.CurrentLevelPath == "SCN_s140"
end

function M.set_testing_mode(enabled)
    testing_mode = enabled == true
    M.log("Testing mode " .. (testing_mode and "enabled" or "disabled"))
    rescan_current_area_doors()
end

function M.get_testing_mode()
    return testing_mode
end

------------------------------------------------------------
-- Per-frame Update
------------------------------------------------------------

function M.on_frame()
    local area_index, level_path = get_area_info()
    if area_index and level_path then
        local area_changed = (area_index ~= last_area_index or level_path ~= last_level_path)

        if area_changed or pending_rescan then
            last_area_index = area_index
            last_level_path = level_path
            rescan_current_area_doors()
            -- Only clear pending if we successfully have managers
            if ahlm_mgr:get() then
                pending_rescan = false
            end
        end
    end
end

------------------------------------------------------------
-- REFramework UI
------------------------------------------------------------

re.on_draw_ui(function()
    if imgui.tree_node("DRAP: DoorSceneLock") then
        local changed, new_val = imgui.checkbox("Testing Mode (Unlock All Doors)", testing_mode)
        if changed then
            M.set_testing_mode(new_val)
        end

        -- Display current area info
        if M.CurrentLevelPath then
            imgui.text("Current Level: " .. tostring(M.CurrentLevelPath))
        end
        if M.CurrentAreaIndex then
            imgui.text("Area Index: " .. tostring(M.CurrentAreaIndex))
        end

        -- Display locked scenes
        if imgui.tree_node("Locked Scenes") then
            for code, info in pairs(SCENE_INFO) do
                local locked = LOCKED_SCENES[code] == true
                local status = locked and "[LOCKED]" or "[UNLOCKED]"
                imgui.text(string.format("%s %s (%s)", status, info.name, code))
            end
            imgui.tree_pop()
        end

        imgui.tree_pop()
    end
end)

return M
