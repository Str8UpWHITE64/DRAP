-- DRAP/NpcInvestigation.lua
-- NPC Carry-Over Handler for Door Randomizer
-- Rewrites NPC destinations when player goes through randomized doors

local Shared = require("DRAP/Shared")

local M = Shared.create_module("NpcCarryOver")

------------------------------------------------------------
-- Configuration
------------------------------------------------------------

local NPC_MANAGER_TYPE = "app.solid.gamemastering.NpcManager"
local NPC_PROXIMITY_THRESHOLD = 5.0  -- Max distance per axis for NPC to follow

------------------------------------------------------------
-- State
------------------------------------------------------------

local npc_mgr = M:add_singleton("npc", NPC_MANAGER_TYPE)

local hooks_installed = false
local hook_install_attempted = false

local npc_replace_list_field = nil
local check_carry_over_method = nil
local replace_npc_method = nil
local npc_manager_td = nil

local vec3_td = sdk.find_type_definition("via.vec3")

-- Spread NPCs out slightly when teleporting
local carry_over_counter = 0
local CARRY_OVER_OFFSET_STEP = 0.40

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function safe_tostring(val)
    if val == nil then return "nil" end
    local ok, str = pcall(tostring, val)
    return ok and str or "?"
end

local function extract_vec3(vec3_obj)
    if not vec3_obj then return nil end
    local result = {}
    pcall(function() result.x = vec3_obj.x end)
    pcall(function() result.y = vec3_obj.y end)
    pcall(function() result.z = vec3_obj.z end)
    return result
end

local function make_vec3(x, y, z)
    if Vector3f and Vector3f.new then
        local ok, vec = pcall(Vector3f.new, x, y, z)
        if ok and vec then return vec end
    end
    if vec3_td then
        local ok, inst = pcall(sdk.create_instance, vec3_td)
        if ok and inst then
            pcall(function() inst.x = x end)
            pcall(function() inst.y = y end)
            pcall(function() inst.z = z end)
            return inst
        end
    end
    return nil
end

local function get_player_position()
    local player_mgr = sdk.get_managed_singleton("app.solid.PlayerManager")
    if player_mgr then
        local condition = nil
        pcall(function() condition = player_mgr:get_field("_CurrentPlayerCondition") end)
        if condition then
            local pos = nil
            pcall(function() pos = condition:get_field("LastPlayerPos") end)
            if pos then
                return extract_vec3(pos)
            end
        end
    end
    return nil
end

local function is_npc_near_player(npc_pos, player_pos)
    if not npc_pos or not player_pos then return true end
    local dx = math.abs((npc_pos.x or 0) - (player_pos.x or 0))
    local dy = math.abs((npc_pos.y or 0) - (player_pos.y or 0))
    local dz = math.abs((npc_pos.z or 0) - (player_pos.z or 0))
    return dx <= NPC_PROXIMITY_THRESHOLD and dy <= NPC_PROXIMITY_THRESHOLD and dz <= NPC_PROXIMITY_THRESHOLD
end

------------------------------------------------------------
-- NPC List Field Discovery
------------------------------------------------------------

local function discover_npc_replace_list_field()
    if npc_replace_list_field then return true end

    local mgr = npc_mgr:get()
    if not mgr then return false end

    local td = npc_mgr:get_type_def()
    if not td then return false end

    local candidates = { "mpReplaceList", "mReplaceList", "replaceList", "mpNpcReplaceList" }
    for _, name in ipairs(candidates) do
        local f = td:get_field(name)
        if f then
            local ok, val = pcall(f.get_data, f, mgr)
            if ok and val then
                local count = Shared.get_collection_count(val)
                if count >= 0 then
                    npc_replace_list_field = f
                    return true
                end
            end
        end
    end

    -- Fallback: search all fields for a List containing NpcBaseInfo
    local fields = Shared.get_fields_array(td)
    for _, field in ipairs(fields) do
        if field then
            local ok_name, fname = pcall(field.get_name, field)
            if ok_name and fname then
                local ftype = field:get_type()
                local tname = ftype and ftype:get_full_name() or ""
                if tname:find("List") and tname:find("NpcBaseInfo") then
                    npc_replace_list_field = field
                    return true
                end
            end
        end
    end

    return false
end

------------------------------------------------------------
-- NPC Rewriting
------------------------------------------------------------

local function rewrite_single_npc(npc_obj, dest, index)
    if not npc_obj or not dest then return false end

    -- Increment counter for position offset
    carry_over_counter = carry_over_counter + 1
    local offset = CARRY_OVER_OFFSET_STEP * (carry_over_counter % 6)

    local new_area = dest.area_no
    local new_x = (dest.pos and dest.pos.x or 0) + offset
    local new_y = dest.pos and dest.pos.y or 0
    local new_z = dest.pos and dest.pos.z or 0

    -- Set mAreaNo
    pcall(function() npc_obj:set_field("mAreaNo", new_area) end)

    -- Set mPos
    local new_pos = make_vec3(new_x, new_y, new_z)
    if new_pos then
        pcall(function() npc_obj:set_field("mPos", new_pos) end)
    end

    -- Ensure mCarryOverFlag is true
    pcall(function() npc_obj:set_field("mCarryOverFlag", true) end)

    return true
end

local function rewrite_npc_list(npc_list, dest, player_area, player_pos)
    if not npc_list or not dest or not dest.area_no then return 0 end

    local count = Shared.get_collection_count(npc_list)
    if count == 0 then return 0 end

    local rewritten = 0
    for i = 0, count - 1 do
        local item = Shared.get_collection_item(npc_list, i)
        if item then
            -- Read NPC state
            local live_state, npc_area, npc_pos = nil, nil, nil
            pcall(function() live_state = Shared.to_int(item:get_field("mLiveState")) end)
            pcall(function() npc_area = Shared.to_int(item:get_field("mAreaNo")) end)
            pcall(function() npc_pos = extract_vec3(item:get_field("mPos")) end)

            -- Filter 1: Must be party member (mLiveState == 2)
            if live_state ~= 2 then
                -- Skip: not a party member
            -- Filter 2: Must be in same area as player
            elseif player_area and npc_area and npc_area ~= player_area then
                -- Skip: not in player's area
            -- Filter 3: Must be near player
            elseif player_pos and npc_pos and not is_npc_near_player(npc_pos, player_pos) then
                -- Skip: too far from player
            else
                if rewrite_single_npc(item, dest, i) then
                    rewritten = rewritten + 1
                end
            end
        end
    end

    return rewritten
end

------------------------------------------------------------
-- Method Discovery
------------------------------------------------------------

local function discover_methods()
    npc_manager_td = sdk.find_type_definition(NPC_MANAGER_TYPE)
    if not npc_manager_td then return false end

    local methods = npc_manager_td:get_methods()
    if not methods then return false end

    for _, method in ipairs(methods) do
        if method then
            local ok, name = pcall(method.get_name, method)
            if ok and name then
                if name == "checkCarryOverNpc" then
                    check_carry_over_method = method
                elseif name == "replaceNpc" then
                    replace_npc_method = method
                end
            end
        end
    end

    return check_carry_over_method ~= nil
end

------------------------------------------------------------
-- Hook Installation
------------------------------------------------------------

local function install_hooks()
    if hooks_installed or hook_install_attempted then return end
    hook_install_attempted = true

    if not discover_methods() then
        M.log("ERROR: Could not find required methods")
        return
    end

    if not discover_npc_replace_list_field() then
        M.log("WARNING: Could not find NPC replace list field")
    end

    -- Hook checkCarryOverNpc - this is where we rewrite NPC destinations
    local hook1_ok = pcall(function()
        sdk.hook(
            check_carry_over_method,
            -- PRE: Spoof args to vanilla so game's validation passes
            function(args)
                local tr = nil
                if AP and AP.DoorRandomizer and AP.DoorRandomizer.get_last_transition then
                    tr = AP.DoorRandomizer.get_last_transition()
                end

                if tr and tr.randomized and tr.randomized.was_redirected and tr.vanilla then
                    local v_new = tr.vanilla.area_no
                    local v_old = tr.vanilla.area_no_old
                    if v_new then pcall(function() args[3] = sdk.to_ptr(v_new) end) end
                    if v_old then pcall(function() args[4] = sdk.to_ptr(v_old) end) end
                end
                return args
            end,
            -- POST: Rewrite NPC list to randomized destination
            function(retval)
                local tr = nil
                if AP and AP.DoorRandomizer and AP.DoorRandomizer.get_last_transition then
                    tr = AP.DoorRandomizer.get_last_transition()
                end

                if tr and tr.randomized and tr.randomized.was_redirected then
                    local npc_list = nil
                    local ok_mo, retval_mo = pcall(sdk.to_managed_object, retval)
                    if ok_mo and retval_mo then
                        npc_list = retval_mo
                    end

                    if npc_list and Shared.get_collection_count(npc_list) > 0 then
                        local dest = {
                            area_no = tr.randomized.area_no,
                            pos = tr.randomized.pos,
                        }
                        local player_area = tr.vanilla and tr.vanilla.area_no_old or nil
                        local player_pos = get_player_position()

                        local rewritten = rewrite_npc_list(npc_list, dest, player_area, player_pos)
                        if rewritten > 0 then
                            M.log(string.format("Rewrote %d NPCs to area %d", rewritten, dest.area_no))
                        end
                    end
                end
                return retval
            end
        )
    end)

    if not hook1_ok then
        M.log("ERROR: Failed to hook checkCarryOverNpc")
        return
    end

    -- Hook replaceNpc
    if replace_npc_method then
        pcall(function()
            sdk.hook(replace_npc_method,
                function(args) return args end,
                function(retval) return retval end
            )
        end)
    end

    hooks_installed = true
    M.log("Hooks installed successfully")
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

function M.get_hook_status()
    return hooks_installed
end

function M.on_frame()
    if hooks_installed or hook_install_attempted then return end
    if not Shared.is_in_game() then return end
    install_hooks()
end

------------------------------------------------------------
-- Initialize
------------------------------------------------------------

M.log("NpcCarryOver module loaded")

return M