-- DRAP/DoorRandomizer.lua
-- Door Randomizer for Archipelago
-- Intercepts areaJump() calls to redirect door transitions based on AP slot data

local Shared = require("DRAP/Shared")

local M = Shared.create_module("DoorRandomizer")

------------------------------------------------------------
-- Configuration
------------------------------------------------------------

local AHLM_TYPE_NAME = "app.solid.gamemastering.AreaHitLayoutManager"
local HIT_DATA_TYPE_NAME = "app.solid.gamemastering.HIT_DATA"

------------------------------------------------------------
-- Scene Information
------------------------------------------------------------

local SCENE_INFO = {
    s140 = { name = "Title Screen",             index = 292  },
    s135 = { name = "Helipad",                  index = 287  },
    s136 = { name = "Safe Room",                index = 288  },
    s231 = { name = "Rooftop",                  index = 535  },
    s230 = { name = "Service Hallway",          index = 534  },
    s200 = { name = "Paradise Plaza",           index = 512  },
    s503 = { name = "Colby's Movie Theater",    index = 1283 },
    s700 = { name = "Leisure Park",             index = 1792 },
    s400 = { name = "North Plaza",              index = 1024 },
    s501 = { name = "Crislip's Hardware Store", index = 1281 },
    sa00 = { name = "Food Court",               index = 2560 },
    s300 = { name = "Wonderland Plaza",         index = 768  },
    s900 = { name = "Al Fresca Plaza",          index = 2304 },
    s100 = { name = "Entrance Plaza",           index = 256  },
    s500 = { name = "Grocery Store",            index = 1280 },
    s600 = { name = "Maintenance Tunnel",       index = 1536 },
    s401 = { name = "Hideout",                  index = 1025 },
    s601 = { name = "Butcher",                  index = 1537 },
}

-- Reverse lookup: index -> scene code
local INDEX_TO_SCENE = {}
for code, info in pairs(SCENE_INFO) do
    INDEX_TO_SCENE[info.index] = code
end

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
-- Internal State
------------------------------------------------------------

local hook_installed = false
local hook_install_attempted = false
local area_jump_method = nil
local ahlm_td = nil
local hit_data_td = nil

-- Mapping for door randomization (loaded from AP)
local DOOR_REDIRECTS = {}

-- Enable/disable randomization
local randomization_enabled = false
local suppressed = false  -- temporarily suppress redirects (e.g. during escort missions)

-- Cache for HIT_DATA fields
local hit_data_fields = {}
local hit_data_fields_discovered = false

-- Stats
local redirect_count = 0

------------------------------------------------------------
-- Singleton Managers
------------------------------------------------------------

local ahlm_mgr = M:add_singleton("ahlm", "app.solid.gamemastering.AreaHitLayoutManager")
local am_mgr   = M:add_singleton("am", "app.solid.gamemastering.AreaManager")
local pm_mgr   = M:add_singleton("pm", "app.solid.PlayerManager")

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

local function vec3_any_to_table(v)
    if not v then return nil end
    if type(v) == "table" then
        return {
            x = v.x or v[1] or 0,
            y = v.y or v[2] or 0,
            z = v.z or v[3] or 0,
        }
    end
    return nil
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

local function extract_vec3(vec3_obj)
    if not vec3_obj then return nil end

    local result = { _raw = vec3_obj }

    local ok_x, x = pcall(function() return vec3_obj.x end)
    local ok_y, y = pcall(function() return vec3_obj.y end)
    local ok_z, z = pcall(function() return vec3_obj.z end)

    if ok_x then result.x = x end
    if ok_y then result.y = y end
    if ok_z then result.z = z end

    return result
end

local function format_vec3(vec3_data)
    if not vec3_data then return "nil" end
    return string.format("(%.2f, %.2f, %.2f)",
        vec3_data.x or 0, vec3_data.y or 0, vec3_data.z or 0)
end

local function to_vector3f(val)
    if val == nil then return nil end

    if type(val) == "userdata" then return val end

    if type(val) == "table" then
        local x = val.x or val[1] or 0
        local y = val.y or val[2] or 0
        local z = val.z or val[3] or 0

        if Vector3f and Vector3f.new then
            local ok, vec = pcall(Vector3f.new, x, y, z)
            if ok and vec then return vec end
        end

        local vec3_td = sdk.find_type_definition("via.vec3")
        if vec3_td then
            local ok, vec = pcall(function()
                local v = sdk.create_instance(vec3_td)
                if v then
                    v.x = x
                    v.y = y
                    v.z = z
                end
                return v
            end)
            if ok and vec then return vec end
        end

        return val
    end

    return nil
end

local function extract_hit_data(hit_data_obj)
    if not hit_data_obj then return nil end
    if not discover_hit_data_fields() then return nil end

    local data = {}

    for name, field in pairs(hit_data_fields) do
        local ok, value = pcall(field.get_data, field, hit_data_obj)
        if ok and value ~= nil then
            local val_type = type(value)
            if val_type == "userdata" then
                if name == "mAreaJumpPos" or name == "mAreaJumpAngle" then
                    local vec_data = extract_vec3(value)
                    data[name] = format_vec3(vec_data)
                    data[name .. "_raw"] = value
                    data[name .. "_vec"] = vec_data
                else
                    local ok_str, str = pcall(tostring, value)
                    data[name] = ok_str and str or "<userdata>"
                    data[name .. "_raw"] = value
                end
            elseif val_type == "boolean" or val_type == "number" or val_type == "string" then
                data[name] = value
            else
                data[name] = tostring(value)
            end
        end
    end

    return data
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
-- Vehicle Dismount Helper
------------------------------------------------------------

local function dismount_vehicle()
    local pm = pm_mgr:get()
    if not pm then return end

    local vtype_field = pm_mgr:get_field("<VehicleType>k__BackingField", false)
    if not vtype_field then return end

    local cur = Shared.safe_get_field(pm, vtype_field)
    if cur and cur ~= 0 then
        pcall(function() vtype_field:set_data(pm, 0) end)
        M.log("Dismounted player from vehicle for door transition")
    end
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

                    -- Check for redirect
                    local was_redirected = false
                    local redirect_target = nil

                    if randomization_enabled and not suppressed and DOOR_REDIRECTS[door_id] then
                        local redirect = DOOR_REDIRECTS[door_id]
                        redirect_target = redirect.target_area

                        local mod_ok = modify_hit_data_destination(
                            hit_data_mo,
                            redirect.target_area,
                            redirect.target_pos,
                            redirect.target_angle
                        )

                        if mod_ok then
                            was_redirected = true
                            redirect_count = redirect_count + 1
                            dismount_vehicle()
                            M.log(string.format("Redirected %s -> %s (was: %s)",
                                door_id, get_scene_name(redirect_target), get_scene_name(original_dest)))
                        end
                    end

                    -- Store final destination for NPC carry-over
                    local final_area_jump_name = original_dest
                    local final_pos = door_data.mAreaJumpPos_vec and vec3_any_to_table(door_data.mAreaJumpPos_vec) or nil
                    local final_angle = door_data.mAreaJumpAngle_vec and vec3_any_to_table(door_data.mAreaJumpAngle_vec) or nil
                    local final_was_redirected = false

                    if was_redirected and redirect_target then
                        final_area_jump_name = redirect_target
                        final_was_redirected = true

                        if DOOR_REDIRECTS[door_id] then
                            local r = DOOR_REDIRECTS[door_id]
                            if r.target_pos then final_pos = vec3_any_to_table(r.target_pos) end
                            if r.target_angle then final_angle = vec3_any_to_table(r.target_angle) end
                        end
                    end

                    M.last_final_destination = {
                        door_id = door_id,
                        area_jump_name = final_area_jump_name,
                        area_no = area_jump_name_to_area_no(final_area_jump_name),
                        pos = final_pos,
                        angle = final_angle,
                        was_redirected = final_was_redirected,
                    }

                    local vanilla_area_no_old = area_index
                    local vanilla_area_no = area_jump_name_to_area_no(original_dest)

                    M.last_transition = {
                        door_id = door_id,
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

                return args
            end,
            -- Post-hook
            function(retval)
                return retval
            end
        )
    end)

    if not hook_ok then
        M.log("ERROR: Failed to install areaJump hook")
        return false
    end

    hook_installed = true
    M.log("Door randomizer hook installed")
    return true
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

--- Clears all redirects and disables randomization
function M.clear_redirects()
    DOOR_REDIRECTS = {}
    randomization_enabled = false
    redirect_count = 0
    vehicle_blocked_doors = {}
    player_was_in_vehicle = false
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

--- Returns whether the hook is installed
function M.is_hook_installed()
    return hook_installed
end

------------------------------------------------------------
-- Vehicle Door Blocking
--
-- When door randomization is active and the player is riding
-- a vehicle, we disable all area-jump hit data so they cannot
-- transition through a door while in the vehicle.  When they
-- exit the vehicle, we re-enable the doors (respecting any
-- DoorSceneLock locks that may still apply).
------------------------------------------------------------

local DoorSceneLock = nil
local function get_door_scene_lock()
    if not DoorSceneLock then
        local ok, mod = pcall(require, "DRAP/DoorSceneLock")
        if ok and mod then DoorSceneLock = mod end
    end
    return DoorSceneLock
end

local vehicle_blocked_doors = {}   -- layout_info -> jump_name
local player_was_in_vehicle = false

local function is_player_in_vehicle()
    local pm = pm_mgr:get()
    if not pm then return false end

    local vtype_field = pm_mgr:get_field("<VehicleType>k__BackingField", false)
    if not vtype_field then return false end

    local cur = Shared.safe_get_field(pm, vtype_field)
    return cur ~= nil and cur ~= 0
end

local function scan_and_set_doors_disabled(disabled)
    local ahlm = ahlm_mgr:get()
    if not ahlm then return 0 end

    local res_field = ahlm_mgr:get_field("mAreaHitResource", false)
                   or ahlm_mgr:get_field("<mAreaHitResource>k__BackingField", false)
    if not res_field then return 0 end

    local res_list = Shared.safe_get_field(ahlm, res_field)
    if not res_list then return 0 end

    local count = 0

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
                                local jump_name = Shared.get_field_value(li,
                                    {"AREA_JUMP_NAME", "<AREA_JUMP_NAME>k__BackingField"})
                                jump_name = jump_name and tostring(jump_name) or ""

                                local mHitData = Shared.get_field_value(li,
                                    {"mHitData", "<mHitData>k__BackingField"})

                                if mHitData and jump_name ~= "" then
                                    if disabled then
                                        local ok_set = pcall(mHitData.set_field, mHitData, "Disabled", true)
                                        if ok_set then
                                            vehicle_blocked_doors[li] = jump_name
                                            count = count + 1
                                        end
                                    elseif vehicle_blocked_doors[li] then
                                        -- Only re-enable doors WE blocked, and only
                                        -- if DoorSceneLock doesn't have the scene locked
                                        local dsl = get_door_scene_lock()
                                        local scene_locked = dsl and dsl.is_scene_locked(jump_name)
                                        if not scene_locked then
                                            pcall(mHitData.set_field, mHitData, "Disabled", false)
                                        end
                                        vehicle_blocked_doors[li] = nil
                                        count = count + 1
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return count
end

local function update_vehicle_door_blocking()
    if not randomization_enabled or suppressed then return end

    local in_vehicle = is_player_in_vehicle()
    if in_vehicle == player_was_in_vehicle then return end
    player_was_in_vehicle = in_vehicle

    local action = in_vehicle and "disabled" or "re-enabled"
    local count = scan_and_set_doors_disabled(in_vehicle)
    M.log(string.format("Player %s vehicle — %s %d door(s)",
        in_vehicle and "entered" or "exited", action, count))
end

------------------------------------------------------------
-- Existing HIT_DATA Borrowing (for warp)
------------------------------------------------------------

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
                                if mHitData then return mHitData end
                            end
                        end
                    end
                end
            end
        end
    end

    return nil
end

--- Simulates the s231->s136 door transition to warp the player to the Safe Room
function M.warp_to_safe_room()
    if not hook_installed or not area_jump_method then
        M.log("Cannot warp: areaJump hook not installed")
        return false
    end

    local ahlm = ahlm_mgr:get()
    if not ahlm then
        M.log("Cannot warp: AreaHitLayoutManager not available")
        return false
    end

    local hit_data = find_existing_hit_data()
    if not hit_data then
        M.log("Cannot warp: no existing HIT_DATA found in current area")
        return false
    end

    -- Configure the HIT_DATA to match the s231->s136 door0 transition
    local mod_ok = modify_hit_data_destination(
        hit_data,
        "s136",                                      -- mAreaJumpName
        { x = 153.19, y = 9.32, z = 216.92 },       -- mAreaJumpPos
        { x = 0.0,    y = 0.93, z = 0.0 }            -- mAreaJumpAngle
    )

    if not mod_ok then
        M.log("Cannot warp: failed to configure HIT_DATA")
        return false
    end

    -- Set door number
    pcall(function() hit_data:set_field("mDoorNo", 0) end)

    local ok, err = pcall(area_jump_method.call, area_jump_method, ahlm, hit_data)
    if ok then
        M.log("Warped to Safe Room via simulated door entry")
        return true
    else
        M.log("Warp failed: " .. tostring(err))
        return false
    end
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

    update_vehicle_door_blocking()
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
        imgui.text("Player In Vehicle: " .. tostring(player_was_in_vehicle))
        local vbd_count = 0
        for _ in pairs(vehicle_blocked_doors) do vbd_count = vbd_count + 1 end
        imgui.text("Vehicle-Blocked Doors: " .. tostring(vbd_count))

        if imgui.button("Warp to Safe Room") then
            M.warp_to_safe_room()
        end

        imgui.tree_pop()
    end
end)

------------------------------------------------------------
-- Module Initialization
------------------------------------------------------------

M.log("DoorRandomizer module loaded")

return M