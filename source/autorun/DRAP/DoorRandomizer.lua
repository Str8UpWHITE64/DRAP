-- DRAP/DoorRandomizer.lua
-- Door Randomizer for Archipelago
-- Intercepts areaJump() calls to redirect door transitions based on AP slot data

local Shared = require("DRAP/Shared")
local Activation = require("DRAP/Activation")
local BossFight = require("DRAP/BossFight")

local M = Shared.create_module("DoorRandomizer")

------------------------------------------------------------
-- Configuration
------------------------------------------------------------

local AHLM_TYPE_NAME = "app.solid.gamemastering.AreaHitLayoutManager"
local HIT_DATA_TYPE_NAME = "app.solid.gamemastering.HIT_DATA"

------------------------------------------------------------
-- Scene Information (shared with DoorSceneLock via DRAP/Shared)
------------------------------------------------------------

local SCENE_INFO = Shared.SCENE_INFO
local INDEX_TO_SCENE = Shared.INDEX_TO_SCENE

------------------------------------------------------------
-- Module State (exposed for NPC carry-over)
------------------------------------------------------------

M.last_final_destination = nil  -- { area_jump_name, area_no, pos, angle, was_redirected, door_id }
M.last_transition = nil

function M.get_last_transition()
    return M.last_transition
end

function M.get_last_final_destination()
    return M.last_final_destination
end

------------------------------------------------------------
-- Module-level state. Declared up front so every function in the file
-- can reference them, regardless of source position. (Lua module-level
-- locals are only visible to code that follows their declaration; an
-- earlier version of this file had `clear_redirects` reset two locals
-- before they were declared, which silently set globals instead of
-- clearing the locals. Same hazard pattern as Bridge.lua's pre-fix
-- scoping bug.)
------------------------------------------------------------

local hook_installed = false
local hook_install_attempted = false
local area_jump_method = nil
local ahlm_td = nil
local hit_data_td = nil

-- DOOR_REDIRECTS: slot-data redirects (gated by randomization_enabled).
-- STATIC_REDIRECTS: always-on, gameplay-driven redirects (e.g. SceneFixups'
--   EP->s138 -> s136 redirect when AP is active). Survive set_redirects().
local DOOR_REDIRECTS = {}
local STATIC_REDIRECTS = {}

local randomization_enabled = false
local suppressed = false  -- temporary; e.g. during escort missions

local hit_data_fields = {}
local hit_data_fields_discovered = false

local redirect_count = 0

-- True only for the length of an areaJump call made by warp_to with
-- opts.no_redirect. The warp's door id is "<scene>|s136|door0", which is a
-- real shuffled door from the Rooftop (and from Entrance Plaza under
-- ScoopSanity), so without this a Teleport Trap fired there went wherever
-- that door had been randomized to.
local bypass_redirects = false

-- Vehicle arrival data. A door's HIT_DATA carries _VehicleJumpDatas: per
-- vehicle type, where that vehicle is put in the area the door leads to.
-- The engine takes the vehicle through any door and uses that entry when it
-- has one, else the door's own arrival point. A redirect rewrites the arrival
-- point but not these entries, so a motorcycle through a redirected Leisure
-- Park -> Paradise door was put at the Paradise position inside North Plaza
-- and fell out of the world. The entries are moved to the redirect's arrival
-- point for the jump and put back when the door is used unredirected.
local vehicle_jump_saved = {}      -- HIT_DATA address -> { { entry, pos }, ... }

-- Height above the arrival point for a vehicle, by the door whose arrival is
-- used. Only the ramp down into the Tunnel needs one: its walking arrival is
-- on the slope, and the game's own entries lift cars 0.69 and the Humvee 2.75.
local VEHICLE_LIFT = {
    ["SCN_s700|s600|door0"] = { default = 0.69, [4] = 2.75 },
}

-- Heading after a door while riding. The game works out the arrival rotation
-- from the door's angle and records it, but only turns the vehicle's
-- transform, which its physics overwrites on the next step, so the vehicle
-- keeps the heading it had and can arrive facing a wall. Set by the areaJump
-- hook, applied on the first frame in the new area.
-- Only a door the vehicle was not built for gets the turn: a redirected door,
-- or a mall door taken by driving into it. The ramp between Leisure Park and
-- the Tunnel is the game's own vehicle door, and a vehicle driven through it
-- keeps the heading it came in with; the walking arrival angle there would
-- leave it sideways at the top of the ramp.
local vehicle_face_pending = nil   -- { from, area_no, yaw, at }
local vehicle_door_jump = false    -- true while the door prompt fires areaJump

-- Mall doors while riding. The game offers no door prompt to a car at a mall
-- door and a mall door is a solid wall to one, so only the Tunnel ramp takes a
-- vehicle across. For a ridden vehicle close to a mall door between these open
-- areas, the game's own door prompt and sign are let through; the door button
-- then takes the vehicle across. Driving into a door does nothing. Small rooms,
-- the Security Room side and the Tunnel are left alone. A door the game already
-- offers the vehicle (the motorcycle and bicycle) keeps the game's own action.
local VEHICLE_DOOR_SCENES = {
    s100 = true, s200 = true, s300 = true, s400 = true,
    s700 = true, s900 = true, sa00 = true,
}
local VEHICLE_DOOR_REACH = 3.0     -- metres beyond the door's own prompt radius
-- a hit this wide is no door leaf: Wonderland has a 15 m one behind its Food
-- Court door
local VEHICLE_DOOR_MAX_RADIUS = 5.0
-- extra reach for a long vehicle, whose centre stays further from the glass
-- when its nose is against it (RIDE_CAR_TYPE: 1 sedan, 3 box truck, 4 Humvee)
local VEHICLE_REACH_EXTRA = { [1] = 0.5, [3] = 2.5, [4] = 1.5 }
local VEHICLE_DOOR_FACING = 0.5    -- cos of the widest angle to the door that counts
local VEHICLE_DOOR_BUTTON = 16384  -- InputDefine.Kind.ACTION_INTERACT, the button a door uses on foot
-- true: the game's own door prompt and action serve the vehicle; false: DRAP's
-- toast and its own jump
local VEHICLE_GAME_PROMPT = true
local VEHICLE_PROMPT_EVERY = 3.5   -- seconds between refreshes of the on-screen prompt
local vehicle_door = { next_check = 0, shown = false, shown_at = 0, was_down = false,
    block = false, block_until = 0, refused = 0, force = false, offered = nil,
    targets = {}, inter_hit = nil, signed = 0, arrived = {} }

-- How far past the walking arrival point, in the direction Frank walks out,
-- a vehicle is put after the prompt, so it stands clear of the door and the
-- wall around it. Keyed "<from>|<to>" with a default.
local VEHICLE_ARRIVAL_AHEAD = {
    default = 4.0,
    -- a planter stands a few metres ahead of these arrivals; closer in, the
    -- vehicle has room to drive off or turn
    ["s100|s200"] = 1.5,
    ["sa00|s900"] = 1.0,
    ["s900|s100"] = 2.0,
    ["s100|s900"] = 7.0,
}
-- Metres to the right of that line (negative: left), where a planter stands on
-- the line itself. Al Fresca has two in a row in front of the Entrance Plaza
-- door, too close together for a vehicle to stand between them.
local VEHICLE_ARRIVAL_SIDE = {
    ["s100|s900"] = -4.0,
}

-- Rooms a vehicle is never taken into. Any door can be redirected to one of
-- them under Door Randomizer, and the game carries the ridden vehicle through
-- any door, so a car could otherwise end up inside the Security Room or the
-- Hideout. A door into one of these, taken while riding, is held: the player
-- is put out of the vehicle, then the same door is taken on foot. s138 is the
-- Security Room's entrance from Entrance Plaza.
local NO_VEHICLE_AREAS = {
    s135 = "the Heliport",
    s136 = "the Security Room",
    s138 = "the Security Room",
    s401 = "Carlito's Hideout",
}
-- Rooms only the motorcycle and the bicycle are taken into. Cars, the box
-- truck and the Humvees are held at the door the same way.
local NO_CAR_AREAS = {
    s230 = "the Warehouse",
}
local CAR_TYPES = { [1] = true, [2] = true, [3] = true, [4] = true }  -- 4door, 2door, truck, Humvee
local VEHICLE_GETOUT_WAIT = 8.0    -- seconds for the get-out before the door is given up
local vehicle_room = nil           -- { hd, dest, area, at, asked, out_at }
local vehicle_getout_request = nil -- true while a get-out waits for the update thread
local vehicle_getout_next = 0      -- next time a vehicle found inside one of those rooms is emptied

-- How high each car's origin sits above the floor when it stands on its
-- wheels. A door with no arrival entry for the vehicle puts it at the walking
-- arrival point, on the floor, and the tall ones (sedan, box truck) stay
-- sunk to the axles. Motorcycle and bicycle arrive fine at floor height.
local VEHICLE_REST_HEIGHT = { [1] = 1.0, [2] = 0.45, [3] = 1.0 }
local vehicle_lift_pending = nil   -- { from, area_no, base, rest, at, tries, wait }

------------------------------------------------------------
-- Singleton Managers
------------------------------------------------------------

local ahlm_mgr = M:add_singleton("ahlm", "app.solid.gamemastering.AreaHitLayoutManager")
local am_mgr   = M:add_singleton("am", "app.solid.gamemastering.AreaManager")

------------------------------------------------------------
-- Helper Functions
------------------------------------------------------------

local function get_scene_name(scene_code)
    if not scene_code then return "Unknown" end
    local code = scene_code:gsub("^SCN_", "")
    local info = SCENE_INFO[code]
    return info and info.name or scene_code
end

local function area_jump_name_to_area_no(area_jump_name)
    if not area_jump_name then return nil end
    local code = tostring(area_jump_name):gsub("^SCN_", "")
    local info = SCENE_INFO[code]
    return info and info.index or nil
end

------------------------------------------------------------
-- HIT_DATA Field Discovery and Extraction
------------------------------------------------------------

local function discover_hit_data_fields()
    if hit_data_fields_discovered then return true end

    hit_data_td = sdk.find_type_definition(HIT_DATA_TYPE_NAME)
    if not hit_data_td then return false end

    local fields = Shared.get_fields_array(hit_data_td)
    for _, field in ipairs(fields) do
        if field then
            local ok, name = pcall(field.get_name, field)
            if ok and name then
                hit_data_fields[name] = field
            end
        end
    end

    hit_data_fields_discovered = true
    return true
end

local extract_vec3 = Shared.vec3_extract
local to_vector3f  = Shared.vec3_create

-- Named field reader: returns the raw field value, or nil on miss/error.
local function read_hit_data_field(hit_data_obj, name)
    local f = hit_data_fields[name]
    if not f then return nil end
    local ok, v = pcall(f.get_data, f, hit_data_obj)
    if ok then return v end
    return nil
end

-- Extracts the four fields the redirect pipeline actually consumes:
-- mAreaJumpName (string), mDoorNo (number), and the position/angle vectors
-- (returned as {x, y, z} tables). Anything else on HIT_DATA is ignored.
local function extract_hit_data(hit_data_obj)
    if not hit_data_obj then return nil end
    if not discover_hit_data_fields() then return nil end

    local jump_name  = read_hit_data_field(hit_data_obj, "mAreaJumpName")
    local jump_pos   = read_hit_data_field(hit_data_obj, "mAreaJumpPos")
    local jump_angle = read_hit_data_field(hit_data_obj, "mAreaJumpAngle")
    local door_no    = read_hit_data_field(hit_data_obj, "mDoorNo")

    return {
        mAreaJumpName       = jump_name and tostring(jump_name) or nil,
        mAreaJumpPos_vec    = jump_pos and extract_vec3(jump_pos) or nil,
        mAreaJumpAngle_vec  = jump_angle and extract_vec3(jump_angle) or nil,
        mDoorNo             = door_no,
    }
end

local function generate_door_id(data, from_area_code)
    if not data then return "unknown" end

    local id_parts = {}
    local current_area = from_area_code or "unknown"

    if current_area == "unknown" then
        if AP and AP.DoorSceneLock and AP.DoorSceneLock.CurrentLevelPath then
            current_area = tostring(AP.DoorSceneLock.CurrentLevelPath)
        end
    end
    table.insert(id_parts, current_area)

    if data.mAreaJumpName and data.mAreaJumpName ~= "" then
        table.insert(id_parts, tostring(data.mAreaJumpName))
    end

    if data.mDoorNo then
        table.insert(id_parts, "door" .. tostring(data.mDoorNo))
    end

    return table.concat(id_parts, "|")
end

------------------------------------------------------------
-- HIT_DATA Modification (for redirects)
------------------------------------------------------------

local function modify_hit_data_destination(hit_data_obj, new_area_name, new_pos, new_angle)
    if not hit_data_obj then return false end
    if not discover_hit_data_fields() then return false end

    -- Modify mAreaJumpName
    if new_area_name then
        local ok1 = pcall(function()
            hit_data_obj:set_field("mAreaJumpName", new_area_name)
        end)
        if not ok1 then
            pcall(function() hit_data_obj.mAreaJumpName = new_area_name end)
        end
    end

    -- Modify mAreaJumpPos
    if new_pos then
        local vec3_pos = to_vector3f(new_pos)
        if vec3_pos then
            pcall(function() hit_data_obj:set_field("mAreaJumpPos", vec3_pos) end)
        end
    end

    -- Modify mAreaJumpAngle
    if new_angle then
        local vec3_angle = to_vector3f(new_angle)
        if vec3_angle then
            pcall(function() hit_data_obj:set_field("mAreaJumpAngle", vec3_angle) end)
        end
    end

    return true
end

------------------------------------------------------------
-- Current Area Helper
------------------------------------------------------------

local function get_current_area_info()
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
    end

    return area_index, level_path
end

------------------------------------------------------------
-- Vehicle Arrival Data
------------------------------------------------------------

local function vehicle_jump_entries(hit_data_obj)
    local out = {}
    local list = Shared.safe(function() return hit_data_obj:get_field("_VehicleJumpDatas") end)
    if not list then return out end
    for _, e in Shared.iter_collection(list) do
        if e then out[#out + 1] = e end
    end
    return out
end

local function hit_data_key(hit_data_obj)
    return Shared.safe(function() return hit_data_obj:get_address() end)
end

-- Moves every vehicle entry on the door to the redirect's arrival point.
local function retarget_vehicle_jumps(hit_data_obj, redirect)
    if not (redirect and redirect.target_pos) then return 0 end
    local entries = vehicle_jump_entries(hit_data_obj)
    if #entries == 0 then return 0 end
    local key = hit_data_key(hit_data_obj)
    if key and not vehicle_jump_saved[key] then
        local saved = {}
        for _, e in ipairs(entries) do
            local p = Shared.safe(function() return e:get_field("VehiclePos") end)
            saved[#saved + 1] = { entry = e, pos = p and extract_vec3(p) or nil }
        end
        vehicle_jump_saved[key] = saved
    end
    local target = extract_vec3(redirect.target_pos) or redirect.target_pos
    local lift = VEHICLE_LIFT[redirect.template_door_id or ""]
    local n = 0
    for _, e in ipairs(entries) do
        local vtype = Shared.safe(function() return e:get_field("VehicleType") end)
        local dy = lift and (lift[Shared.to_int(vtype) or -1] or lift.default) or 0
        local v = to_vector3f({ x = target.x, y = target.y + dy, z = target.z })
        if v and pcall(function() e:set_field("VehiclePos", v) end) then n = n + 1 end
    end
    return n
end

-- Puts a door's vehicle entries back after a redirect moved them.
local function restore_vehicle_jumps(hit_data_obj)
    local key = hit_data_key(hit_data_obj)
    local saved = key and vehicle_jump_saved[key]
    if not saved then return end
    for _, s in ipairs(saved) do
        local v = s.pos and to_vector3f(s.pos)
        if v then pcall(function() s.entry:set_field("VehiclePos", v) end) end
    end
    vehicle_jump_saved[key] = nil
end

-- RIDE_CAR_TYPE of the vehicle the player is in, 0 on foot.
local function ridden_type()
    local pm = sdk.get_managed_singleton("app.solid.PlayerManager")
    local v = pm and Shared.safe(function() return pm:get_field("<VehicleType>k__BackingField") end)
    return (v ~= nil and Shared.to_int(v)) or 0
end

local function player_in_vehicle()
    return ridden_type() ~= 0
end

-- The room's name and who is kept out, when the ridden vehicle may not go
-- into the area `code`; nil on foot or when it may.
local function barred_area(code)
    local vtype = ridden_type()
    if vtype == 0 or not code then return nil end
    if NO_VEHICLE_AREAS[code] then return NO_VEHICLE_AREAS[code], "Vehicles" end
    if CAR_TYPES[vtype] and NO_CAR_AREAS[code] then return NO_CAR_AREAS[code], "Cars" end
    return nil
end

local function door_has_vehicle_entry(hit_data_obj, vtype)
    for _, e in ipairs(vehicle_jump_entries(hit_data_obj)) do
        local t = Shared.safe(function() return e:get_field("VehicleType") end)
        if Shared.to_int(t) == vtype then return true end
    end
    return false
end

local function read_yaw(q)
    local x, y, z, w = q.x, q.y, q.z, q.w
    return math.atan(2 * (w * y + x * z), 1 - 2 * (x * x + y * y))
end

-- The open doors of this area a vehicle may take: { hd, to, x, z, radius }.
-- A wide doorway has one entry per leaf, and some leaves carry no arrival
-- point (one of three in Paradise and in the Food Court to Leisure Park);
-- such a leaf is taken with a sibling entry's data so every leaf works.
local function vehicle_doors_here(here)
    local out, blank, by_to = {}, {}, {}
    local ahlm = ahlm_mgr:get()
    local res_list = ahlm and Shared.get_field_value(ahlm, { "mAreaHitResource", "<mAreaHitResource>k__BackingField" })
    if not res_list then return out end
    for _, res in Shared.iter_collection(res_list) do
        local pres = res and Shared.get_field_value(res, { "pResource", "<pResource>k__BackingField" })
        local td = pres and Shared.safe(function() return pres:get_type_definition():get_full_name() end)
        if td == "app.solid.gamemastering.rAreaHitLayout" then
            local infos = Shared.get_field_value(pres, { "mpLayoutInfoList", "<mpLayoutInfoList>k__BackingField" })
            for _, li in Shared.iter_collection(infos) do
                local hd = li and Shared.get_field_value(li, { "mHitData", "<mHitData>k__BackingField" })
                local to = hd and tostring(Shared.safe(function() return hd:get_field("mAreaJumpName") end) or ""):gsub("^SCN_", "")
                local ev = hd and tostring(Shared.safe(function() return hd:get_field("mEventName") end) or "")
                if to and to ~= here and VEHICLE_DOOR_SCENES[to] and ev == ""
                    and Shared.safe(function() return hd:get_field("Disabled") end) ~= true then
                    local c = Shared.safe(function() return hd:get_field("mCursorWorldPos") end)
                    local cx, cz
                    pcall(function() cx = c.x; cz = c.z end)
                    local jp = Shared.safe(function() return hd:get_field("mAreaJumpPos") end)
                    local jx, jz
                    pcall(function() jx = jp.x; jz = jp.z end)
                    if cx and not (cx == 0 and cz == 0) then
                        local d = { hd = hd, to = to, x = cx, z = cz,
                            radius = tonumber(Shared.safe(function() return hd:get_field("mRadius") end)) or 0 }
                        if jx and not (jx == 0 and jz == 0) then
                            d.leaf = hd
                            out[#out + 1] = d
                            by_to[to] = by_to[to] or hd
                        else
                            -- taking this one as it is dropped the bike at the
                            -- area's origin
                            blank[#blank + 1] = d
                        end
                    end
                end
            end
        end
    end
    for _, d in ipairs(blank) do
        if by_to[d.to] then
            d.leaf = d.hd
            d.hd = by_to[d.to]
            out[#out + 1] = d
        end
    end
    return out
end

-- Does the game itself offer this door to a ridden vehicle of this type? Mall
-- doors list the motorcycle and bicycle as allowed. The game takes them through
-- itself, with Frank aboard or on foot depending on the door, and DRAP leaves
-- that alone.
local function door_game_offers(hd, vtype)
    local list = Shared.safe(function() return hd:get_field("_EventInteractableVehicleType") end)
    if not list then return false end
    for _, v in Shared.iter_collection(list) do
        if Shared.to_int(v) == vtype then return true end
    end
    return false
end

-- Where a door leads right now, redirects included: { area, pos, angle, id }.
local function door_destination(hd, level_path)
    local data = extract_hit_data(hd)
    if not data then return nil end
    local id = generate_door_id(data, level_path)
    local redirect = STATIC_REDIRECTS[id]
    if (not redirect) and randomization_enabled and not suppressed then redirect = DOOR_REDIRECTS[id] end
    if type(redirect) == "function" then
        local ok, r = pcall(redirect, id, data)
        redirect = (ok and type(r) == "table") and r or nil
    end
    local area = tostring((redirect and redirect.target_area) or data.mAreaJumpName or ""):gsub("^SCN_", "")
    local pos = (redirect and redirect.target_pos and extract_vec3(redirect.target_pos)) or data.mAreaJumpPos_vec
    local angle = (redirect and redirect.target_angle and extract_vec3(redirect.target_angle)) or data.mAreaJumpAngle_vec
    -- the arrival spots are per arrival door, so a redirect uses the door it lands at
    local tf, tt = tostring((redirect and redirect.template_door_id) or ""):match("^SCN_(%w+)|(%w+)|")
    return { area = area, pos = pos, angle = angle, id = id, arrival_key = tf and (tf .. "|" .. tt) or nil }
end

-- Puts the vehicle arrival entry of the ridden type on the door at a spot
-- ahead of the walking arrival point, facing the way Frank walks out. The jump
-- then lands the vehicle there instead of on top of the far door.
local function set_vehicle_arrival(hd, vtype, dest, from)
    if not (dest.pos and dest.pos.y and dest.angle) then return false end
    local list = Shared.safe(function() return hd:get_field("_VehicleJumpDatas") end)
    if not list then return false end
    local yaw = dest.angle.y or 0
    local key = dest.arrival_key or (from .. "|" .. dest.area)
    local ahead = VEHICLE_ARRIVAL_AHEAD[key] or VEHICLE_ARRIVAL_AHEAD.default
    local rest = VEHICLE_REST_HEIGHT[vtype] or 1.0
    local side = VEHICLE_ARRIVAL_SIDE[key] or 0
    local pos = to_vector3f({ x = dest.pos.x + math.sin(yaw) * ahead + math.cos(yaw) * side, y = dest.pos.y + rest,
        z = dest.pos.z + math.cos(yaw) * ahead - math.sin(yaw) * side })
    local rot = Quaternion.new(math.cos(yaw / 2), 0.0, math.sin(yaw / 2), 0.0)
    if not pos then return false end
    local entry
    for _, e in ipairs(vehicle_jump_entries(hd)) do
        local t = Shared.safe(function() return e:get_field("VehicleType") end)
        if Shared.to_int(t) == vtype then entry = e; break end
    end
    if entry then
        local key = hit_data_key(hd)
        if key and not vehicle_jump_saved[key] then
            local saved = {}
            for _, e in ipairs(vehicle_jump_entries(hd)) do
                local p = Shared.safe(function() return e:get_field("VehiclePos") end)
                saved[#saved + 1] = { entry = e, pos = p and extract_vec3(p) or nil }
            end
            vehicle_jump_saved[key] = saved
        end
    else
        entry = Shared.safe(function() return sdk.create_instance("app.solid.gamemastering.VehicleJumpData") end)
        if not entry then return false end
        entry = Shared.safe(function() return entry:add_ref() end) or entry
        if not pcall(function() entry:set_field("VehicleType", vtype) end) then return false end
    end
    local ok = pcall(function()
        entry:set_field("VehiclePos", pos)
        entry:set_field("VehicleRot", rot)
        if not door_has_vehicle_entry(hd, vtype) then list:call("Add", entry) end
    end)
    return ok and door_has_vehicle_entry(hd, vtype)
end

-- The door button is also the button that gets Frank out of the vehicle, so
-- a press at the prompt would take the door and put him on the road. While the
-- prompt is up, and for a second after it was taken, the player's get-off is
-- refused. The hook only reads plain Lua state.
local getoff_hooked = false
local function install_getoff_block()
    if getoff_hooked then return end
    getoff_hooked = true
    -- The button runs VehicleDriverPlayer.startForceOut, which starts the
    -- get-off and later calls requestGetOffCar; blocking only the latter let
    -- the started get-off finish after the new area had loaded.
    for _, h in ipairs({
        { "app.solid.Vehicle.VehicleDriverPlayer", "startForceOut(app.solid.survivor.player.PlayerCondition, System.Boolean)" },
        { "app.solid.Vehicle.VehicleController", "requestGetOffCar(via.GameObject, System.Boolean)" },
        { "app.solid.Vehicle.VehicleController", "requestGetOffCar(app.solid.Vehicle.VehicleController.VehicleSeat, via.GameObject, System.Boolean, System.Boolean)" },
    }) do
        local td = sdk.find_type_definition(h[1])
        local fn = td and td:get_method(h[2])
        if fn then
            pcall(function()
                sdk.hook(fn,
                    function(args)
                        if vehicle_door.block or os.clock() < vehicle_door.block_until then
                            vehicle_door.refused = vehicle_door.refused + 1
                            return sdk.PreHookResult.SKIP_ORIGINAL
                        end
                    end,
                    function(retval) return retval end)
            end)
        end
    end
end

-- The game checks a ridden vehicle's contact with a door in checkAreaHit, and
-- that check also sets the door's sign (its name and the button). When the
-- door's collision is not marked interactable, a sight line from Frank to the
-- door decides; seated in a car at the glass the line is blocked, so the game
-- deletes the sign and refuses the door, and only "Get Out" is left. For the
-- offered door only, its collision reads as interactable, so the sight line is
-- skipped and the game passes the door, draws its own sign and button, and
-- takes the vehicle through on the button, as at the Tunnel ramp. Everything
-- else the check asks (the door's own flags, a shutter still down) still
-- decides, so a door that is shut on foot stays shut to a vehicle. The hook
-- compares one pointer with the doors in vehicle_door.targets and calls
-- nothing managed.
local hit_hooked = false
local function install_hit_override()
    if hit_hooked then return end
    hit_hooked = true
    local cd = sdk.find_type_definition(AHLM_TYPE_NAME .. ".AreaHitCollisionData")
    local inter = cd and cd:get_method("get_Interactable")
    if inter then
        pcall(function()
            sdk.hook(inter,
                function(args)
                    vehicle_door.inter_hit = nil
                    if not vehicle_door.force then return end
                    local obj = sdk.to_managed_object(args[2])
                    vehicle_door.inter_hit = obj and obj:read_qword(0x10) or nil
                end,
                function(retval)
                    local hit = vehicle_door.inter_hit
                    vehicle_door.inter_hit = nil
                    if hit and vehicle_door.targets[hit] then
                        vehicle_door.signed = vehicle_door.signed + 1
                        return sdk.to_ptr(1)
                    end
                    return retval
                end)
        end)
    end
end

local function interact_down()
    local is = sdk.get_managed_singleton("app.solid.InputSystem")
    if not is then return false end
    local d = Shared.safe(function() return is:call("isDown(app.solid.InputDefine.Kind)", VEHICLE_DOOR_BUTTON) end)
    local o = Shared.safe(function() return is:call("isOn(app.solid.InputDefine.Kind)", VEHICLE_DOOR_BUTTON) end)
    return d == true or o == true
end

local function hide_vehicle_prompt()
    vehicle_door.block = false
    vehicle_door.force = false
    vehicle_door.offered = nil
    if next(vehicle_door.arrived) then vehicle_door.arrived = {} end
    if vehicle_door.signed > 0 then
        M.log(string.format("Vehicle door: door read as interactable x%d", vehicle_door.signed))
        vehicle_door.signed = 0
    end
    if not vehicle_door.shown then return end
    vehicle_door.shown = false
    local Notify = package.loaded["DRAP/Notify"]
    if Notify and Notify.hide then pcall(Notify.hide) end
end

local function show_vehicle_prompt(dest_area, blocks_getoff)
    local now = os.clock()
    vehicle_door.block = blocks_getoff
    if vehicle_door.shown and now - vehicle_door.shown_at < VEHICLE_PROMPT_EVERY then return end
    if not vehicle_door.shown then M.log("Vehicle door prompt shown: " .. dest_area) end
    vehicle_door.shown, vehicle_door.shown_at = true, now
    local Notify = package.loaded["DRAP/Notify"]
    if Notify and Notify.send then
        pcall(Notify.send, "<BOLD>Go through</BOLD> to " .. get_scene_name("SCN_" .. dest_area)
            .. "  (door button)", { duration = VEHICLE_PROMPT_EVERY + 1.0 })
    end
end

-- Facing a door: toward its prompt point, or along the way the door leads
-- (its walking arrival heading). A vehicle stopped against the glass beside a
-- leaf has that leaf's point off to one side, so the first test alone drops
-- the prompt the moment the vehicle comes to rest.
local function facing_door(d, fx, fz, dx, dz, dist)
    if (fx * dx + fz * dz) / dist >= VEHICLE_DOOR_FACING then return true end
    local a = Shared.safe(function() return d.hd:get_field("mAreaJumpAngle") end)
    local ay
    pcall(function() ay = a.y end)
    if not ay or ay == 0 then return false end
    return fx * math.sin(ay) + fz * math.cos(ay) >= VEHICLE_DOOR_FACING
end

-- Every leaf of a door within reach. A leaf can be two hit datas at nearly the
-- same spot, each with its own story flags, so only one of them is live; the
-- nearer one is often the dead twin (Wonderland to the Food Court, 9 cm apart).
-- The door the game touches has to be among them, so none is singled out.
local function door_leaves_near(doors, to, px, pz, reach)
    local targets, hds = {}, {}
    for _, d in ipairs(doors) do
        local dx, dz = d.x - px, d.z - pz
        if d.to == to and d.radius <= VEHICLE_DOOR_MAX_RADIUS
            and math.sqrt(dx * dx + dz * dz) <= d.radius + reach then
            for _, h in ipairs({ d.hd, d.leaf }) do
                local a = hit_data_key(h)
                if a and not targets[a] then
                    targets[a] = true
                    hds[#hds + 1] = h
                end
            end
        end
    end
    return targets, hds
end

-- The prompt for a ridden vehicle at a mall door. Close to an open door
-- between the areas in VEHICLE_DOOR_SCENES, facing it, the door button takes
-- the door. The jump goes through areaJump on the door's own data, so
-- redirects, locks (a locked door is Disabled and skipped), the rooms a
-- vehicle is held out of and the arrival heading all apply as for a door
-- used on foot.
local function vehicle_door_check()
    if not area_jump_method then return end
    install_getoff_block()
    if vehicle_door.refused > 0 then
        M.log(string.format("Vehicle door: get-off refused x%d", vehicle_door.refused))
        vehicle_door.refused = 0
    end
    local now = os.clock()
    local down = interact_down()
    local pressed = down and not vehicle_door.was_down
    vehicle_door.was_down = down
    if now < vehicle_door.next_check and not pressed then return end
    vehicle_door.next_check = now + 0.1
    if vehicle_face_pending or vehicle_room or (M.last_jump_at and now - M.last_jump_at < 4) then
        hide_vehicle_prompt()
        return
    end
    local vtype = ridden_type()
    if vtype == 0 then hide_vehicle_prompt(); return end
    local _, level_path = get_current_area_info()
    local here = level_path and tostring(level_path):gsub("^SCN_", "")
    if not (here and VEHICLE_DOOR_SCENES[here]) then hide_vehicle_prompt(); return end

    local pm = sdk.get_managed_singleton("app.solid.PlayerManager")
    local vc = pm and Shared.safe(function() return pm:call("get_VehicleControl") end)
    local tr = vc and Shared.safe(function() return vc:call("get_GameObject"):call("get_Transform") end)
    local pos = tr and Shared.safe(function() return tr:call("get_Position") end)
    local rot = tr and Shared.safe(function() return tr:call("get_Rotation") end)
    if not (pos and rot) then hide_vehicle_prompt(); return end
    local px, pz, yaw = pos.x, pos.z, read_yaw(rot)
    local fx, fz = math.sin(yaw), math.cos(yaw)

    local best, best_dist, best_dest
    local doors = vehicle_doors_here(here)
    local reach = VEHICLE_DOOR_REACH + (VEHICLE_REACH_EXTRA[vtype] or 0)
    for _, d in ipairs(doors) do
        local dx, dz = d.x - px, d.z - pz
        local dist = math.sqrt(dx * dx + dz * dz)
        if d.radius <= VEHICLE_DOOR_MAX_RADIUS and dist <= d.radius + reach and dist > 0.01
            and facing_door(d, fx, fz, dx, dz, dist)
            and (not best_dist or dist < best_dist) then
            local dest = door_destination(d.hd, level_path)
            if dest and (VEHICLE_DOOR_SCENES[dest.area] or NO_VEHICLE_AREAS[dest.area]) then
                best, best_dist, best_dest = d, dist, dest
            end
        end
    end
    if not best then hide_vehicle_prompt(); return end
    local door_key = here .. "|" .. best.to
    local leaves
    vehicle_door.targets, leaves = door_leaves_near(doors, best.to, px, pz, reach)

    -- A door the game lists for this vehicle (the motorcycle and the bicycle
    -- at every mall door) keeps the game's own action, which may put Frank
    -- through on foot; only the sight line is opened, so the game's sign shows
    -- for a rider stopped at the glass. The get-off is not refused there.
    if door_game_offers(best.hd, vtype) then
        install_hit_override()
        if vehicle_door.offered ~= door_key then
            vehicle_door.offered = door_key
            M.log(string.format("Vehicle door left to the game's own action: %s -> %s (%.1f m)",
                here, best_dest.area, best_dist))
        end
        vehicle_door.force = true
        vehicle_door.block = false
        return
    end

    local held = NO_VEHICLE_AREAS[best_dest.area] ~= nil
    if VEHICLE_GAME_PROMPT and not held then
        -- the game's own prompt and door action: its arrival spot is set first
        install_hit_override()
        -- whichever leaf the button takes, the vehicle lands at its own spot
        local set = true
        for _, h2 in ipairs(leaves) do
            local a = hit_data_key(h2)
            if not vehicle_door.arrived[a] then
                vehicle_door.arrived[a] = true
                local dest = door_destination(h2, level_path)
                if not (dest and dest.pos and not (dest.pos.x == 0 and dest.pos.z == 0)) then dest = best_dest end
                set = set_vehicle_arrival(h2, vtype, dest, here) and set
            end
        end
        if vehicle_door.offered ~= door_key then
            vehicle_door.offered = door_key
            M.log(string.format("Vehicle door offered to the game's prompt: %s -> %s (%.1f m), arrival spot %s",
                here, best_dest.area, best_dist, set and "set" or "not set"))
            if set and best_dest.pos then
                M.log(string.format("Vehicle arrival spot: walking point (%.1f, %.1f) angle %.2f, vehicle %.1f m ahead",
                    best_dest.pos.x, best_dest.pos.z, (best_dest.angle and best_dest.angle.y) or 0,
                    VEHICLE_ARRIVAL_AHEAD[best_dest.arrival_key or (here .. "|" .. best_dest.area)] or VEHICLE_ARRIVAL_AHEAD.default))
            end
        end
        vehicle_door.force = true
        vehicle_door.block = true
        if pressed then
            M.log(string.format("Vehicle door button at the door %s -> %s (%.1f m, radius %.1f)",
                here, best_dest.area, best_dist, best.radius))
            vehicle_door.block_until = now + 1.0
        end
        return
    end
    vehicle_door.force = false
    show_vehicle_prompt(best_dest.area, not held)
    if not pressed then return end

    M.log(string.format("Vehicle door button at the door %s -> %s (%.1f m, radius %.1f)",
        here, best_dest.area, best_dist, best.radius))
    hide_vehicle_prompt()
    if not held then vehicle_door.block_until = now + 1.0 end
    vehicle_door.next_check = now + 5
    -- a door into a room no vehicle enters is held by the jump hook: no spot needed
    local arrival = NO_VEHICLE_AREAS[best_dest.area] or set_vehicle_arrival(best.hd, vtype, best_dest, here)
    if not arrival then M.log("Vehicle door: no arrival spot set, the walking spot is used")
    elseif not NO_VEHICLE_AREAS[best_dest.area] and best_dest.pos then
        M.log(string.format("Vehicle arrival spot: walking point (%.1f, %.1f) angle %.2f, vehicle %.1f m ahead",
            best_dest.pos.x, best_dest.pos.z, (best_dest.angle and best_dest.angle.y) or 0,
            VEHICLE_ARRIVAL_AHEAD[best_dest.arrival_key or (here .. "|" .. best_dest.area)] or VEHICLE_ARRIVAL_AHEAD.default))
    end
    vehicle_door_jump = true
    local ok, err = pcall(area_jump_method.call, area_jump_method, ahlm_mgr:get(), best.hd)
    vehicle_door_jump = false
    if not ok then M.log("Vehicle door jump failed: " .. tostring(err)) end
end

-- Turns the ridden vehicle to the arrival angle once the new area is in.
-- setRotation(Quaternion) goes to the physics body, the route the game itself
-- uses to warp a vehicle; turning the transform alone does nothing. The
-- heading it gives is the one asked for plus a reference heading the body
-- keeps, measured per vehicle: none on the cars; on the box
-- truck the heading it was parked at, and on the truck and the motorcycle
-- after a door the heading they jumped with. That reference cannot be read,
-- so the first turn asks for the target, the heading is read back once the
-- turn has had time to land, and a turn that moved the vehicle but missed
-- gives the reference (read less asked) for the next one.
-- The read is only trusted once it holds: the turn can land later than the
-- first read, and a truck that drove up the ramp already faced the target, so
-- an early read matched and the late turn then left it sideways.
local FACE_RECHECK_FRAMES = 30
local FACE_CONFIRM_FRAMES = 30
local FACE_MAX_TRIES = 6

local function vehicle_yaw(vc)
    local rot = Shared.safe(function() return vc:call("get_GameObject"):call("get_Transform"):call("get_Rotation") end)
    return rot and read_yaw(rot) or nil
end

local function wrap_angle(a)
    return ((a + math.pi) % (2 * math.pi)) - math.pi
end

local function face_vehicle_on_arrival()
    local p = vehicle_face_pending
    if not p then return end
    if os.clock() - p.at > 120 then vehicle_face_pending = nil; return end
    if not p.tries then
        local idx = get_current_area_info()
        if idx == nil or (idx == p.from and idx ~= p.area_no) then return end
        if not (p.yaw and player_in_vehicle()) then vehicle_face_pending = nil; return end
        p.tries, p.wait, p.cmd = 0, 0, p.yaw
    end
    if p.wait > 0 then p.wait = p.wait - 1; return end

    local pm = sdk.get_managed_singleton("app.solid.PlayerManager")
    local vc = pm and Shared.safe(function() return pm:call("get_VehicleControl") end)
    if not vc then vehicle_face_pending = nil; return end
    local yaw = vehicle_yaw(vc)
    p.seen = p.seen or {}
    if p.tries > 0 then p.seen[#p.seen + 1] = string.format("%.2f", yaw or 0) end
    local off = yaw and math.abs(wrap_angle(yaw - p.yaw)) or nil
    if p.tries > 0 and off and off < 0.1 then
        if p.confirmed then
            vehicle_face_pending = nil
            M.log(string.format("Vehicle turned to the arrival heading (%.2f, %d tr%s: %s)", p.yaw, p.tries,
                p.tries == 1 and "y" or "ies", table.concat(p.seen, " ")))
            return
        end
        -- on target: read once more before calling it done
        p.confirmed = true
        p.wait = FACE_CONFIRM_FRAMES
        return
    end
    p.confirmed = nil
    if p.tries >= FACE_MAX_TRIES then
        vehicle_face_pending = nil
        M.log(string.format("Vehicle could not be turned to the arrival heading (%.2f; read %s)", p.yaw, table.concat(p.seen, " ")))
        return
    end
    -- A turn that moved the vehicle but missed shows the reference it adds;
    -- one that did not move it yet is simply asked for again.
    if p.tries > 0 and yaw and p.before and math.abs(wrap_angle(yaw - p.before)) > 0.02 then
        p.cmd = wrap_angle(p.yaw - wrap_angle(yaw - p.cmd))
    end
    p.before = yaw
    p.tries = p.tries + 1
    p.wait = FACE_RECHECK_FRAMES
    local c = p.cmd
    pcall(function()
        vc:call("setRotation(via.Quaternion)", Quaternion.new(math.cos(c / 2), 0.0, math.sin(c / 2), 0.0))
    end)
end

-- Raises a car that came through a door lower than it stands on its wheels.
-- The arrival point is on the floor; the car is put back at its resting
-- height there and settles. Read back a few frames later and repeated, as the
-- first frames in a new area can still be overwritten by the game's own
-- placement.
local LIFT_RECHECK_FRAMES = 5
local LIFT_MAX_TRIES = 4

local function lift_vehicle_on_arrival()
    local p = vehicle_lift_pending
    if not p then return end
    local now = os.clock()
    if now - p.at > 60 then vehicle_lift_pending = nil; return end
    local idx = get_current_area_info()
    if idx == nil or (idx == p.from and idx ~= p.area_no) then return end
    p.arrived = p.arrived or now
    if p.wait > 0 then p.wait = p.wait - 1; return end

    local pm = sdk.get_managed_singleton("app.solid.PlayerManager")
    local vc = pm and Shared.safe(function() return pm:call("get_VehicleControl") end)
    if not vc then vehicle_lift_pending = nil; return end
    local pos = Shared.safe(function() return vc:call("get_GameObject"):call("get_Transform"):call("get_Position") end)
    if not pos then return end
    local dx, dz = pos.x - p.base.x, pos.z - p.base.z
    if dx * dx + dz * dz > 16 then
        -- not placed at the arrival yet
        if now - p.arrived > 10 then vehicle_lift_pending = nil end
        return
    end
    local want = p.base.y + p.rest
    if pos.y >= want - 0.2 then
        if p.tries > 0 then
            M.log(string.format("Vehicle lifted onto its wheels (%.2f above the arrival point, %d tr%s)",
                pos.y - p.base.y, p.tries, p.tries == 1 and "y" or "ies"))
        end
        vehicle_lift_pending = nil
        return
    end
    if p.tries >= LIFT_MAX_TRIES then
        M.log(string.format("Vehicle could not be lifted (%.2f above the arrival point)", pos.y - p.base.y))
        vehicle_lift_pending = nil
        return
    end
    p.tries = p.tries + 1
    p.wait = LIFT_RECHECK_FRAMES
    local x, y, z = pos.x, want + 0.05, pos.z
    pcall(function() vc:call("setPosition", Vector3f.new(x, y, z)) end)
end

local function notify(text)
    local Notify = package.loaded["DRAP/Notify"]
    if Notify and Notify.send then pcall(Notify.send, text, { duration = 5.0 }) end
end

-- The driver's own get-off, the route the Exit button takes:
-- VehicleDriverPlayer.startForceOut(PlayerCondition, false). Run from the
-- update thread; the get-off motion then plays out over a second or two.
local function run_vehicle_getout()
    if not vehicle_getout_request then return end
    vehicle_getout_request = nil
    local pm = sdk.get_managed_singleton("app.solid.PlayerManager")
    local vc = pm and Shared.safe(function() return pm:call("get_VehicleControl") end)
    local drv = vc and Shared.safe(function() return vc:get_field("<Driver>k__BackingField") end)
    local cond = pm and Shared.safe(function() return pm:get_field("_CurrentPlayerCondition") end)
    if not (drv and cond) then
        M.log("Vehicle get-out: no driver or player condition")
        return
    end
    local ok, err = pcall(function() drv:call("startForceOut", cond, false) end)
    if not ok then M.log("Vehicle get-out failed: " .. tostring(err)) end
end

if re and re.on_pre_application_entry then
    re.on_pre_application_entry("UpdateBehavior", function()
        local ok, err = pcall(run_vehicle_getout)
        if not ok then M.log("Vehicle get-out failed: " .. tostring(err)) end
    end)
end

-- A door into a room in NO_VEHICLE_AREAS (or NO_CAR_AREAS, in a car), taken while riding, was held by the
-- areaJump hook. Gets the player out, then takes the same door on foot. If the
-- player is still aboard after VEHICLE_GETOUT_WAIT the door is given up and
-- the player told to get out first. Also empties a vehicle found inside one of
-- those rooms however it got there, so the player is never stuck in one.
local function vehicle_room_step()
    local now = os.clock()
    local r = vehicle_room
    if not r then
        if now < vehicle_getout_next or not player_in_vehicle() then return end
        local _, level_path = get_current_area_info()
        local here = level_path and tostring(level_path):gsub("^SCN_", "")
        local name = barred_area(here)
        if name then
            vehicle_getout_next = now + 3
            M.log("In a vehicle inside " .. name .. ": getting out")
            vehicle_getout_request = true
        end
        return
    end
    local idx = get_current_area_info()
    if idx and idx ~= r.area then
        vehicle_room = nil
        return
    end
    if player_in_vehicle() then
        if not r.asked then
            r.asked = now
            M.log("Vehicle door into " .. r.name .. " held: getting out first")
            notify(r.who .. " can't go into " .. r.name .. ". Getting out first.")
            vehicle_getout_request = true
        elseif now - r.asked > VEHICLE_GETOUT_WAIT then
            M.log("Vehicle door into " .. r.name .. " given up: still in the vehicle")
            notify("Get out of the vehicle to go into " .. r.name .. ".")
            vehicle_room = nil
        end
        return
    end
    r.out_at = r.out_at or now
    if now - r.out_at < 0.5 then return end
    vehicle_room = nil
    if not area_jump_method then return end
    M.log("On foot: taking the door into " .. r.name)
    local ok, err = pcall(area_jump_method.call, area_jump_method, ahlm_mgr:get(), r.hd)
    if not ok then M.log("Door after get-out failed: " .. tostring(err)) end
end

------------------------------------------------------------
-- Hook Installation
------------------------------------------------------------

local function discover_ahlm_methods()
    if not ahlm_td then
        ahlm_td = sdk.find_type_definition(AHLM_TYPE_NAME)
        if not ahlm_td then
            return nil, "Could not find AreaHitLayoutManager type"
        end
    end

    local methods = ahlm_td:get_methods()
    if not methods then
        return nil, "Could not get methods from type definition"
    end

    for i, method in ipairs(methods) do
        if method then
            local ok, name = pcall(method.get_name, method)
            if ok and name == "areaJump" then
                return method, nil
            end
        end
    end

    return nil, "areaJump method not found"
end


--- Resolves areaJump without installing anything.
---
--- The frame loop is silent while no slot is connected, so in a vanilla run
--- the hook never installs and the method is never found -- which is what the
--- warp used to trip over. Debug mode is enough to resolve it, because
--- resolving changes nothing on its own.
local function ensure_area_jump_method()
    if area_jump_method then return true end

    local GUI = package.loaded["DRAP/GUI"]
    local debug_on = GUI and GUI.is_debug and GUI.is_debug() or false
    if not (Activation.is_active() or debug_on) then
        M.log("Cannot warp: turn on Debug Mode first (no slot connected)")
        return false
    end

    local method, err = discover_ahlm_methods()
    if not method then
        M.log("Cannot warp: " .. (err or "areaJump not found"))
        return false
    end
    area_jump_method = method
    discover_hit_data_fields()
    return true
end

-- Called from the areaJump pre-hook with (destination scene code, area index
-- being left), after redirects are applied and before the new area loads.
-- Inside the hook: a listener may only record; game calls belong on a frame.
local jump_listeners = {}

function M.add_jump_listener(fn)
    for _, f in ipairs(jump_listeners) do
        if f == fn then return end
    end
    jump_listeners[#jump_listeners + 1] = fn
end

local function install_hook()
    if hook_installed then return true end
    if hook_install_attempted then return false end

    hook_install_attempted = true

    local method, err = discover_ahlm_methods()
    if not method then
        M.log("ERROR: " .. (err or "Unknown error"))
        return false
    end

    area_jump_method = method
    discover_hit_data_fields()

    local hook_ok = pcall(function()
        sdk.hook(
            area_jump_method,
            -- Pre-hook: intercept and potentially redirect
            function(args)
                -- When a door was last used, so anything that must not land
                -- mid-load (PlayerReady) can tell a load screen is coming.
                M.last_jump_at = os.clock()
                local hold_for_vehicle = false
                pcall(function()
                    local hit_data_arg = args[3]
                    if not hit_data_arg then return end

                    local hit_data_mo = sdk.to_managed_object(hit_data_arg)
                    if not hit_data_mo then return end

                    local door_data = extract_hit_data(hit_data_mo)
                    if not door_data then return end

                    local area_index, level_path = get_current_area_info()
                    local door_id = generate_door_id(door_data, level_path)
                    local original_dest = door_data.mAreaJumpName or "?"

                    -- Check for redirect -- static redirects (always-on,
                    -- gameplay-driven) take precedence over slot-data ones.
                    local was_redirected = false
                    local redirect_target = nil
                    local active_redirect = nil
                    if not bypass_redirects then
                        active_redirect = STATIC_REDIRECTS[door_id]
                    end
                    if (not active_redirect) and not bypass_redirects
                        and randomization_enabled and not suppressed then
                        active_redirect = DOOR_REDIRECTS[door_id]
                    end

                    -- Static redirects may be either a table or a function
                    -- that returns a table -- function form lets the redirect
                    -- branch on live runtime state (e.g. NPC escort count).
                    if type(active_redirect) == "function" then
                        local ok, resolved = pcall(active_redirect, door_id, door_data)
                        active_redirect = (ok and type(resolved) == "table") and resolved or nil
                    end

                    -- No vehicle into the rooms in NO_VEHICLE_AREAS, and no car
                    -- into those in NO_CAR_AREAS: hold the door untouched;
                    -- vehicle_room_step gets the player out and takes it
                    -- again on foot.
                    local dest_code = (tostring(active_redirect and active_redirect.target_area or original_dest):gsub("^SCN_", ""))
                    local barred, barred_who = barred_area(dest_code)
                    if barred then
                        hold_for_vehicle = true
                        if not vehicle_room then
                            vehicle_room = { hd = hit_data_mo, dest = dest_code, name = barred, who = barred_who,
                                area = area_index, at = os.clock() }
                        end
                        return
                    end

                    if active_redirect then
                        redirect_target = active_redirect.target_area

                        local mod_ok = modify_hit_data_destination(
                            hit_data_mo,
                            active_redirect.target_area,
                            active_redirect.target_pos,
                            active_redirect.target_angle
                        )

                        if mod_ok then
                            was_redirected = true
                            redirect_count = redirect_count + 1
                            -- a prompt jump has put its own arrival spot on the door
                            local moved = (vehicle_door_jump or vehicle_door.force) and 0 or retarget_vehicle_jumps(hit_data_mo, active_redirect)
                            M.log(string.format("Redirected %s -> %s (was: %s)%s",
                                door_id, get_scene_name(redirect_target), get_scene_name(original_dest),
                                moved > 0 and string.format(", %d vehicle arrival(s) moved", moved) or ""))
                        end
                    end
                    if not was_redirected and not (vehicle_door_jump or vehicle_door.force) then
                        restore_vehicle_jumps(hit_data_mo)
                    end

                    -- Store final destination for NPC carry-over
                    local final_area_jump_name = original_dest
                    local final_pos = door_data.mAreaJumpPos_vec and extract_vec3(door_data.mAreaJumpPos_vec) or nil
                    local final_angle = door_data.mAreaJumpAngle_vec and extract_vec3(door_data.mAreaJumpAngle_vec) or nil
                    local final_was_redirected = false

                    if was_redirected and redirect_target then
                        final_area_jump_name = redirect_target
                        final_was_redirected = true

                        if type(active_redirect) == "table" then
                            if active_redirect.target_pos then final_pos = extract_vec3(active_redirect.target_pos) end
                            if active_redirect.target_angle then final_angle = extract_vec3(active_redirect.target_angle) end
                        end
                    end

                    if was_redirected or (vehicle_door_jump or vehicle_door.force) then
                        vehicle_face_pending = {
                            from = area_index,
                            area_no = area_jump_name_to_area_no(final_area_jump_name),
                            yaw = final_angle and final_angle.y or nil,
                            at = os.clock(),
                        }
                    else
                        vehicle_face_pending = nil
                    end

                    -- A car that will arrive at the walking arrival point (no
                    -- entry of its own on the door, or one just moved there
                    -- by a redirect) is raised onto its wheels after the jump.
                    local vtype = ridden_type()
                    local rest = VEHICLE_REST_HEIGHT[vtype]
                    if rest and final_pos and final_pos.y and not (vehicle_door_jump or vehicle_door.force)
                        and (was_redirected or not door_has_vehicle_entry(hit_data_mo, vtype)) then
                        vehicle_lift_pending = {
                            from = area_index,
                            area_no = area_jump_name_to_area_no(final_area_jump_name),
                            base = final_pos, rest = rest, at = os.clock(), tries = 0, wait = 0,
                        }
                    else
                        vehicle_lift_pending = nil
                    end

                    M.last_final_destination = {
                        door_id = door_id,
                        area_jump_name = final_area_jump_name,
                        area_no = area_jump_name_to_area_no(final_area_jump_name),
                        pos = final_pos,
                        angle = final_angle,
                        was_redirected = final_was_redirected,
                    }

                    -- Listeners that need to know where a door leads before the
                    -- area loads. They run inside this hook, so they must stay
                    -- plain Lua: record what they need and act on a frame.
                    local dest_code = tostring(final_area_jump_name):gsub("^SCN_", "")
                    for _, fn in ipairs(jump_listeners) do
                        local ok, err = pcall(fn, dest_code, area_index)
                        if not ok then M.log("jump listener failed: " .. tostring(err)) end
                    end

                    local vanilla_area_no_old = area_index
                    local vanilla_area_no = area_jump_name_to_area_no(original_dest)

                    M.last_transition = {
                        door_id = door_id,
                        -- Stamped so consumers can tell a live door crossing
                        -- from a stale record: this table persists until the
                        -- NEXT jump, but the transition it describes is over
                        -- within seconds.
                        at = os.clock(),
                        vanilla = {
                            area_no = vanilla_area_no,
                            area_no_old = vanilla_area_no_old,
                            door_no = door_data.mDoorNo,
                            area_jump_name = original_dest,
                        },
                        randomized = {
                            area_no = M.last_final_destination.area_no,
                            pos = M.last_final_destination.pos,
                            angle = M.last_final_destination.angle,
                            was_redirected = final_was_redirected,
                            area_jump_name = final_area_jump_name,
                            door_id = door_id,
                        }
                    }
                end)

                if hold_for_vehicle then return sdk.PreHookResult.SKIP_ORIGINAL end
                return args
            end,
            -- Post-hook
            function(retval)
                return retval
            end
        )
    end)

    if not hook_ok then
        M.log.error("Failed to install areaJump hook")
        return false
    end

    hook_installed = true
    M.log("Door randomizer hook installed")
    return true
end

--- Installs the areaJump hook outside the frame loop, which is silent while
--- no slot is connected. Static redirects need the hook to exist, so without
--- this they cannot be tested in a vanilla run at all. Debug Mode is the gate,
--- same as the warp.
function M.ensure_hook()
    if hook_installed then return true end
    local GUI = package.loaded["DRAP/GUI"]
    local debug_on = GUI and GUI.is_debug and GUI.is_debug() or false
    if not (Activation.is_active() or debug_on) then
        M.log("cannot install the areaJump hook: turn on Debug Mode "
            .. "(no slot connected)")
        return false
    end
    hook_install_attempted = false      -- allow a retry from the console
    return install_hook()
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

--- Sets door redirects from AP slot data
--- @param redirects table Dictionary of door_id -> redirect info
function M.set_redirects(redirects)
    if not redirects then
        DOOR_REDIRECTS = {}
        randomization_enabled = false
        M.log("Door redirects cleared")
        return
    end

    DOOR_REDIRECTS = {}
    local count = 0

    for door_id, redirect_data in pairs(redirects) do
        DOOR_REDIRECTS[door_id] = {
            target_area = redirect_data.target_area,
            target_pos = redirect_data.target_pos or redirect_data.position,
            target_angle = redirect_data.target_angle or redirect_data.angle,
            template_door_id = redirect_data.template_door_id,
        }
        count = count + 1
    end

    if count > 0 then
        randomization_enabled = true
        M.log(string.format("Loaded %d door redirects from AP", count))
    else
        randomization_enabled = false
        M.log("No door redirects to load")
    end
end

--- Add a single always-on redirect (independent of slot-data and not affected
--- by suppression). Used by gameplay-driven fixes like SceneFixups. The
--- `data` parameter may be either:
---   * a table { target_area, target_pos, target_angle [, template_door_id] }
---   * a function() that returns such a table (resolved at door-crossing
---     time -- useful for branching on live runtime state e.g. NPC escort)
function M.add_static_redirect(door_id, data)
    if type(door_id) ~= "string" then
        M.log("add_static_redirect: door_id must be string")
        return false
    end
    if type(data) == "function" then
        STATIC_REDIRECTS[door_id] = data
        M.log(string.format("Added static callback redirect: %s", door_id))
        return true
    elseif type(data) == "table" then
        STATIC_REDIRECTS[door_id] = {
            target_area = data.target_area,
            target_pos = data.target_pos,
            target_angle = data.target_angle,
            template_door_id = data.template_door_id,
        }
        M.log(string.format("Added static redirect: %s -> %s",
            door_id, tostring(data.target_area)))
        return true
    end
    M.log("add_static_redirect: data must be table or function")
    return false
end

--- Remove a static redirect. Returns true if one was actually removed.
function M.remove_static_redirect(door_id)
    if STATIC_REDIRECTS[door_id] then
        STATIC_REDIRECTS[door_id] = nil
        M.log("Removed static redirect: " .. door_id)
        return true
    end
    return false
end

--- Returns the current static-redirect table (read-only inspection).
function M.get_static_redirects()
    return STATIC_REDIRECTS
end

--- Clears all redirects and disables randomization
function M.clear_redirects()
    DOOR_REDIRECTS = {}
    randomization_enabled = false
    redirect_count = 0
    M.log("Door redirects cleared")
end

--- Returns whether door randomization is actively redirecting
function M.is_enabled()
    return randomization_enabled and not suppressed
end

--- Temporarily suppress or unsuppress door redirects (e.g. during escort missions)
function M.set_suppressed(value)
    if suppressed ~= value then
        suppressed = value
        M.log("Door redirects " .. (value and "SUPPRESSED" or "UNSUPPRESSED"))
    end
end

--- Returns whether door randomization is currently suppressed
function M.is_suppressed()
    return suppressed
end

--- Returns the current redirect count (how many times redirects have been applied)
function M.get_redirect_count()
    return redirect_count
end

--- Returns the number of configured redirects
function M.get_redirect_config_count()
    local count = 0
    for _ in pairs(DOOR_REDIRECTS) do count = count + 1 end
    return count
end

--- Returns the current door redirects table
--- @return table Dictionary of door_id -> redirect info
function M.get_redirects()
    return DOOR_REDIRECTS
end

--- Where a door really leads, for callers holding a layout's HIT_DATA.
--- Reads mDoorNo off the hit data rather than guessing from the player's
--- position, so the two North Plaza <-> Wonderland doorways resolve apart.
--- Returns the vanilla name when the door has no redirect, so the result can
--- be used unconditionally. Second return is the door id, for logging.
function M.resolve_destination(level_path, vanilla_jump_name, hit_data_obj)
    if not (level_path and vanilla_jump_name) then return vanilla_jump_name, nil end

    local door_no = 0
    if hit_data_obj and discover_hit_data_fields() then
        local v = read_hit_data_field(hit_data_obj, "mDoorNo")
        if v then door_no = v end
    end

    local door_id = tostring(level_path) .. "|" .. tostring(vanilla_jump_name)
                    .. "|door" .. tostring(door_no)
    local redirect = DOOR_REDIRECTS[door_id]
    if redirect and redirect.target_area then
        return tostring(redirect.target_area), door_id
    end
    return vanilla_jump_name, door_id
end

--- Returns whether the hook is installed
function M.is_hook_installed()
    return hook_installed
end

-- Debug area tracing. Off unless drap_trace_areas turns it on.
local trace_areas = false
local last_traced_area = nil

------------------------------------------------------------
-- Existing HIT_DATA Borrowing (for warp)
------------------------------------------------------------

-- The last HIT_DATA we managed to borrow, kept across areas. The tunnel has
-- none of its own, so without this the warp works in one direction only:
-- you can get in and then cannot get out.
local last_hit_data = nil

--- Finds an existing HIT_DATA from the current area's door layout
local function find_existing_hit_data()
    local ahlm = ahlm_mgr:get()
    if not ahlm then return nil end

    local res_field = ahlm_mgr:get_field("mAreaHitResource", false)
                   or ahlm_mgr:get_field("<mAreaHitResource>k__BackingField", false)
    if not res_field then return nil end

    local res_list = Shared.safe_get_field(ahlm, res_field)
    if not res_list then return nil end

    for _, res in Shared.iter_collection(res_list) do
        if res then
            local pResource_val = Shared.get_field_value(res, {"pResource", "<pResource>k__BackingField"})
            if pResource_val then
                local pRes_td = pResource_val:get_type_definition()
                if pRes_td and pRes_td:get_full_name() == "app.solid.gamemastering.rAreaHitLayout" then
                    local layout_list = Shared.get_field_value(pResource_val,
                        {"mpLayoutInfoList", "<mpLayoutInfoList>k__BackingField"})

                    if layout_list then
                        for _, li in Shared.iter_collection(layout_list) do
                            if li then
                                local mHitData = Shared.get_field_value(li,
                                    {"mHitData", "<mHitData>k__BackingField"})
                                if mHitData then
                                    last_hit_data = mHitData
                                    return mHitData
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return nil
end

--- Borrows a HIT_DATA from the current area, points it wherever we like and
--- calls areaJump on it -- the same path a real door takes, so everything that
--- normally runs on a transition still runs.
---
--- The destination position is used as given. There is no snap-to-ground, so a
--- wrong one puts the player outside the world; this is a debug tool and a
--- reload is the recovery.
--- @param area_name string scene code, e.g. "s136"
--- @param pos table|nil {x,y,z}; the area's origin when omitted
--- @param angle table|nil {x,y,z}
--- @param label string|nil name for the log line
--- @param opts table|nil { leave_party = true } leaves followers where they
---   stand (Teleport Trap); { no_redirect = true } ignores door redirects;
---   { boss_ok = true } warps during a psychopath fight (test tooling).
function M.warp_to(area_name, pos, angle, label, opts)
    if not ensure_area_jump_method() then return false end
    opts = opts or {}

    -- The HIT_DATA made below has no vehicle list, and areaJump looks the
    -- ride up in it: a warp while driving took the game down. A list could
    -- not be made from Lua, so the warp waits until the player gets out.
    if player_in_vehicle() then
        M.log("Cannot warp while in a vehicle -- get out first")
        return false
    end

    -- A warp out of a psychopath fight can leave the boss despawned and the
    -- fight unwinnable. boss_ok is for test tooling only.
    local boss = BossFight.blocked_by()
    if boss and not opts.boss_ok then
        M.log("Cannot warp during a " .. boss .. " -- finish the fight first")
        -- The warp buttons give no other sign they did nothing.
        local Notify = package.loaded["DRAP/Notify"]
        if Notify and Notify.warn then pcall(Notify.warn, "No warping during a boss fight") end
        return false
    end

    -- Bring the party. A warp skips the engine's door path, so
    -- checkCarryOverNpc never runs and NpcCarryover never sees the crossing --
    -- escorts were left behind in the old area. Done BEFORE the player moves,
    -- because members are matched against the area they are standing in.
    local carryover = _G.AP and _G.AP.NpcCarryover
    if opts.leave_party then
        -- Nothing is rewritten: followers keep their JOIN records in the area
        -- they are in, the vanilla "left behind at a door" state. The engine
        -- can still accept the pair from the Rooftop or Entrance Plaza (both
        -- have a real door to s136), so its verdict is answered no instead.
        if carryover and type(carryover.begin_warp_strand) == "function" then
            pcall(carryover.begin_warp_strand)
        else
            M.log("leave_party: begin_warp_strand missing -- engine may still carry")
        end
    elseif not carryover then
        M.log("carry-over: AP.NpcCarryover missing -- party not brought")
    elseif type(carryover.carry_party_to) ~= "function" then
        M.log("carry-over: carry_party_to missing -- party not brought")
    else
        -- Errors reported, not swallowed: a bare pcall here hid the failure
        -- completely and looked identical to the call never happening.
        -- Open the verdict window FIRST: the engine runs its own carry-over
        -- pass during the jump and normally refuses a warp's area pair, and
        -- rewriting the records alone does not move anyone.
        if type(carryover.begin_warp_carry) == "function" then
            pcall(carryover.begin_warp_carry)
        end
        local ok, err = pcall(carryover.carry_party_to, area_name, pos)
        if not ok then
            M.log("carry-over failed: " .. tostring(err))
        end
    end

    local ahlm = ahlm_mgr:get()
    if not ahlm then
        M.log("Cannot warp: AreaHitLayoutManager not available")
        return false
    end

    -- Built rather than borrowed. Borrowing rewrites a real door's
    -- destination, which persists until that layout reloads -- and the tunnel
    -- has no doors to borrow in the first place. HIT_DATA is a managed class
    -- with a vtable, so one can be made; the caller sets every field the jump
    -- reads and the other 32 default harmlessly.
    local hit_data, source = nil, nil
    pcall(function() hit_data = sdk.create_instance(HIT_DATA_TYPE_NAME, true) end)
    if not hit_data then
        pcall(function() hit_data = sdk.create_instance(HIT_DATA_TYPE_NAME) end)
    end
    if hit_data then
        pcall(function() hit_data:add_ref() end)
        source = "a constructed HIT_DATA"
    else
        -- Only if that ever stops working. Both of these edit a live door.
        hit_data, source = find_existing_hit_data(), "a door in this area"
        if not hit_data and last_hit_data then
            hit_data, source = last_hit_data, "a door in a previous area"
        end
    end
    if not hit_data then
        M.log("Cannot warp: no HIT_DATA could be made or borrowed")
        return false
    end

    pos = pos or { x = 0.0, y = 0.0, z = 0.0 }
    angle = angle or { x = 0.0, y = 0.0, z = 0.0 }

    if not modify_hit_data_destination(hit_data, area_name, pos, angle) then
        M.log("Cannot warp: failed to configure HIT_DATA")
        return false
    end
    pcall(function() hit_data:set_field("mDoorNo", 0) end)

    bypass_redirects = opts.no_redirect == true
    local ok, err = pcall(area_jump_method.call, area_jump_method, ahlm, hit_data)
    bypass_redirects = false
    if ok then
        M.log(string.format(
            "Warped to %s (%.2f, %.2f, %.2f) via simulated door entry, using %s",
            label or area_name, pos.x, pos.y, pos.z, source))
        return true
    end
    M.log("Warp failed: " .. tostring(err))
    return false
end

-- Spots inside the Clock Tower Tunnel, read with drap_player_pos() while
-- standing in each. Not door anchors -- it has no doors we can capture, and
-- sb01/sb02 are joined by a load zone -- so these are player positions, which
-- is what makes them safe to land on.
--
-- Reaching it normally costs five queens, so without these the only way
-- to test anything past Isabela is to play the whole chain again.
local TUNNEL_SPOTS = {
    entrance     = { "sb00", { x =  -3.600, y = -16.576, z =  -61.500 } },
    middle       = { "sb01", { x =  -0.361, y = -47.451, z = -336.366 } },
    exit         = { "sb02", { x =  -0.457, y = -50.073, z = -346.448 } },
    humvee       = { "sb02", { x =  -0.799, y = -51.948, z = -419.491 } },
    battleground = { "sb03", { x = 118.017, y = -50.136, z = -491.883 } },
    brock        = { "sb03", { x = 150.200, y = -50.383, z = -482.700 } },
}

------------------------------------------------------------
-- Warp targets
------------------------------------------------------------

-- Built by tools/build_door_table.py from the apworld's EMBEDDED_DOOR_DATA.
-- The runtime only ever sees anchors through slot_data, which is empty with no
-- slot connected -- and the picker is meant to work exactly there.
local DOORS_JSON_PATH = "drdr_doors.json"
local warp_targets = nil        -- scene code -> list of targets
local warp_areas = nil          -- scene codes, in display order

local function display_name(code)
    local info = Shared.SCENE_INFO[code]
    return info and info.name or code
end

--- Groups every door by the area it is in, labelled the way the GUI shows it.
--- A door number only appears when an area has more than one door to the same
--- place, which is the only time it disambiguates anything.
local function build_warp_targets()
    if warp_targets then return true end

    local loaded = json.load_file(DOORS_JSON_PATH)
    if type(loaded) ~= "table" or type(loaded.doors) ~= "table" then
        M.log.warn("could not load " .. DOORS_JSON_PATH .. " -- no door list")
        warp_targets, warp_areas = {}, {}
        return false
    end

    local pair_count = {}
    for _, d in ipairs(loaded.doors) do
        local key = tostring(d.from) .. "|" .. tostring(d.to)
        pair_count[key] = (pair_count[key] or 0) + 1
    end

    -- A door record's `position` is where the player ARRIVES in `to`, so
    -- warping with it walks them through the door. The picker groups doors
    -- under `from` and labels them "<from> - <to>", which reads as "the door
    -- in <from>" -- so it should land them in `from`, at that door.
    --
    -- Every door has a reverse record (all 54 checked), and the reverse of
    -- A->B arrives in A beside the same doorway. That is the position to use.
    local reverse = {}
    for _, d in ipairs(loaded.doors) do
        reverse[tostring(d.to) .. "|" .. tostring(d.from) .. "|"
            .. tostring(d.door_no or 0)] = d
    end

    warp_targets = {}
    for _, d in ipairs(loaded.doors) do
        local label = display_name(d.from) .. " - " .. display_name(d.to) .. " Door"
        if (pair_count[tostring(d.from) .. "|" .. tostring(d.to)] or 0) > 1 then
            label = label .. " " .. tostring((d.door_no or 0) + 1)
        end
        local back = reverse[tostring(d.from) .. "|" .. tostring(d.to) .. "|"
            .. tostring(d.door_no or 0)]
        local list = warp_targets[d.from]
        if not list then list = {}; warp_targets[d.from] = list end
        list[#list + 1] = {
            label = label,
            -- Where the warp actually goes: the selected area, near the door.
            area = back and d.from or d.to,
            pos = back and back.position or d.position,
            angle = back and back.angle or d.angle,
            -- Kept for callers that want the far side.
            to = d.to,
            door_no = d.door_no or 0,
            -- False when no reverse record exists, so the UI can say the warp
            -- falls through to the far side rather than silently doing it.
            near_side = back ~= nil,
        }
    end

    -- The tunnel has no doors, so its spots ride along as their own area.
    for name, entry in pairs(TUNNEL_SPOTS) do
        local code = entry[1]
        local list = warp_targets[code]
        if not list then list = {}; warp_targets[code] = list end
        list[#list + 1] = {
            label = display_name(code) .. " - " .. name, to = code,
            -- A spot, not a doorway: it already lands inside its own area.
            area = code, near_side = true,
            door_no = 0, pos = entry[2], angle = nil,
        }
    end

    warp_areas = {}
    for code in pairs(warp_targets) do warp_areas[#warp_areas + 1] = code end
    table.sort(warp_areas, function(a, b) return display_name(a) < display_name(b) end)
    for _, list in pairs(warp_targets) do
        table.sort(list, function(x, y) return x.label < y.label end)
    end
    return true
end

--- @return table scene codes in display order, table code -> targets
function M.get_warp_targets()
    build_warp_targets()
    return warp_areas, warp_targets
end

function M.area_display_name(code) return display_name(code) end

--- @param spot string one of TUNNEL_SPOTS; lists them when omitted or unknown
function M.warp_to_tunnel(spot)
    local entry = TUNNEL_SPOTS[tostring(spot or "")]
    if not entry then
        local names = {}
        for k in pairs(TUNNEL_SPOTS) do names[#names + 1] = k end
        table.sort(names)
        M.log("usage: drap_warp_tunnel(\"" .. table.concat(names, "\" | \"") .. "\")")
        return false
    end
    local info = Shared.SCENE_INFO[entry[1]]
    return M.warp_to(entry[1], entry[2], nil,
        (info and info.name or entry[1]) .. " / " .. spot)
end

--- The s231->s136 door0 transition, kept as a named shortcut.
function M.warp_to_security_room()
    return M.warp_to("s136",
        { x = 153.19, y = 9.32, z = 216.92 },
        { x = 0.0,    y = 0.93, z = 0.0 },
        "Security Room")
end




------------------------------------------------------------
-- Console
------------------------------------------------------------

--- Use drap_player_pos() to read a destination before warping to it -- that
--- is the capture that mapped the Maintenance Tunnel doorways, and it is
--- proven where this warp is not.
---
--- drap_warp("sb00")                 area origin
--- drap_warp("s136", 153.19, 9.32, 216.92)
_G.drap_warp = function(area, x, y, z, ay)
    if type(area) ~= "string" then
        M.log("usage: drap_warp(\"s136\" [, x, y, z [, angleY]])")
        return false
    end
    local pos = (x and y and z) and { x = x, y = y, z = z } or nil
    local angle = ay and { x = 0.0, y = ay, z = 0.0 } or nil
    return M.warp_to(area, pos, angle)
end


--- The way out. Warping to an area origin can drop the player through the
--- floor, and this leaves without reloading -- provided the area we are
--- standing in has a HIT_DATA to borrow. If it does not, nothing can warp out
--- of it and a reload is the only recovery.
_G.drap_warp_home = function() return M.warp_to_security_room() end

--- drap_warp_tunnel("humvee") -- straight to the tank fight trigger
_G.drap_warp_tunnel = function(spot) return M.warp_to_tunnel(spot) end

--- Logs the area and position on every area change. Left on, walking or
--- warping through the tunnel records all five scenes without anyone having to
--- remember to type anything -- which is how the codes got lost last time.
_G.drap_trace_areas = function(on)
    trace_areas = (on ~= false)
    M.log("area tracing " .. (trace_areas and "ON" or "OFF"))
    if trace_areas then last_traced_area = nil end
    return trace_areas
end

------------------------------------------------------------
-- Per-frame Update
------------------------------------------------------------

function M.on_frame()
    if not Shared.is_in_game() then
        return
    end

    if not hook_installed and not hook_install_attempted then
        install_hook()
    end

    vehicle_room_step()
    face_vehicle_on_arrival()
    lift_vehicle_on_arrival()
    vehicle_door_check()

    if trace_areas then
        local idx = get_current_area_info()
        if idx and idx ~= last_traced_area then
            last_traced_area = idx
            -- The capture that mapped the Maintenance Tunnel doorways, rather
            -- than a second one that could disagree with it. Door anchors come
            -- from drap_door_capture.lua, which records them as they are
            -- walked -- the only way to get one out of the engine.
            local overlay = package.loaded["DRAP/effects/DoorPromptOverlay"]
            if overlay and overlay.capture_position then
                pcall(overlay.capture_position)
            end
        end
    end
end

------------------------------------------------------------
-- REFramework UI
------------------------------------------------------------

re.on_draw_ui(function()
    if imgui.tree_node("DRAP: DoorRandomizer") then
        imgui.text("Hook Installed: " .. tostring(hook_installed))
        imgui.text("Randomization: " .. (randomization_enabled and "ENABLED" or "DISABLED")
            .. (suppressed and " (SUPPRESSED)" or ""))
        imgui.text("Redirects Configured: " .. tostring(M.get_redirect_config_count()))
        imgui.text("Redirects Applied: " .. tostring(redirect_count))

        if imgui.button("Warp to Security Room") then
            M.warp_to_security_room()
        end

        imgui.tree_pop()
    end
end)

return M