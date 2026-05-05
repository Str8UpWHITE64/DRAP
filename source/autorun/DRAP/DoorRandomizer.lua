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
-- earlier version of this file had `clear_redirects` reset
-- `vehicle_blocked_doors` and `player_was_in_vehicle` before they were
-- declared, which silently set globals instead of clearing the locals.
-- Same hazard pattern as Bridge.lua's pre-fix scoping bug.)
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

-- Vehicle door-blocking state. While in a vehicle with door randomization
-- active, every area-jump HIT_DATA is set Disabled=true. Restored on dismount.
local vehicle_blocked_doors = {}   -- layout_info -> jump_name
local player_was_in_vehicle = false

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

                    -- Check for redirect -- static redirects (always-on,
                    -- gameplay-driven) take precedence over slot-data ones.
                    local was_redirected = false
                    local redirect_target = nil
                    local active_redirect = STATIC_REDIRECTS[door_id]
                    if (not active_redirect) and randomization_enabled and not suppressed then
                        active_redirect = DOOR_REDIRECTS[door_id]
                    end

                    -- Static redirects may be either a table or a function
                    -- that returns a table -- function form lets the redirect
                    -- branch on live runtime state (e.g. NPC escort count).
                    if type(active_redirect) == "function" then
                        local ok, resolved = pcall(active_redirect, door_id, door_data)
                        active_redirect = (ok and type(resolved) == "table") and resolved or nil
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
                            dismount_vehicle()
                            M.log(string.format("Redirected %s -> %s (was: %s)",
                                door_id, get_scene_name(redirect_target), get_scene_name(original_dest)))
                        end
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
-- While in a vehicle, all area-jump doors are Disabled=true so the player
-- can't transition through one. Restored on dismount, respecting any
-- DoorSceneLock locks still in effect.
------------------------------------------------------------

local DoorSceneLock = nil
local function get_door_scene_lock()
    if not DoorSceneLock then
        local ok, mod = pcall(require, "DRAP/DoorSceneLock")
        if ok and mod then DoorSceneLock = mod end
    end
    return DoorSceneLock
end

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
    M.log(string.format("Player %s vehicle -- %s %d door(s)",
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

--- Simulates the s231->s136 door transition to warp the player to the Security Room
function M.warp_to_security_room()
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
        M.log("Warped to Security Room via simulated door entry")
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

        if imgui.button("Warp to Security Room") then
            M.warp_to_security_room()
        end

        imgui.tree_pop()
    end
end)

return M