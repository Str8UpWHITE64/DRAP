-- DRAP/DoorRandomizer.lua
-- Door Randomizer for Archipelago
-- Intercepts areaJump() calls to redirect door transitions based on AP slot data

local Shared = require("DRAP/Shared")
local Activation = require("DRAP/Activation")

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

-- Debug area tracing. Off unless drap_trace_areas turns it on.
local trace_areas = false
local last_traced_area = nil

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
function M.warp_to(area_name, pos, angle, label)
    if not ensure_area_jump_method() then return false end

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

    local ok, err = pcall(area_jump_method.call, area_jump_method, ahlm, hit_data)
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

    warp_targets = {}
    for _, d in ipairs(loaded.doors) do
        local label = display_name(d.from) .. " - " .. display_name(d.to) .. " Door"
        if (pair_count[tostring(d.from) .. "|" .. tostring(d.to)] or 0) > 1 then
            label = label .. " " .. tostring((d.door_no or 0) + 1)
        end
        local list = warp_targets[d.from]
        if not list then list = {}; warp_targets[d.from] = list end
        list[#list + 1] = {
            label = label, to = d.to, door_no = d.door_no or 0,
            pos = d.position, angle = d.angle,
        }
    end

    -- The tunnel has no doors, so its spots ride along as their own area.
    for name, entry in pairs(TUNNEL_SPOTS) do
        local code = entry[1]
        local list = warp_targets[code]
        if not list then list = {}; warp_targets[code] = list end
        list[#list + 1] = {
            label = display_name(code) .. " - " .. name, to = code,
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

    update_vehicle_door_blocking()

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