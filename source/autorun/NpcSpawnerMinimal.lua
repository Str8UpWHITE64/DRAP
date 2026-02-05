-- DRAP/NpcSpawnerMinimal.lua
-- Minimal NPC Spawner - NO HOOKS, just simple spawn tests
-- This is a diagnostic version to find what causes crashes

local M = {}
M.log = function(msg) log.info("[NpcSpawnerMin] " .. tostring(msg)) end

------------------------------------------------------------
-- State
------------------------------------------------------------

local npc_manager = nil
local spawn_methods = {}
local show_window = false
local last_error = ""
local survivor_types = {}

------------------------------------------------------------
-- Discovery (run once when needed)
------------------------------------------------------------

local function discover_npc_manager()
    if npc_manager then return true end

    local ok, mgr = pcall(function()
        return sdk.get_managed_singleton("app.solid.gamemastering.NpcManager")
    end)

    if ok and mgr then
        npc_manager = mgr
        M.log("Found NpcManager: " .. tostring(mgr))
        return true
    end

    last_error = "NpcManager not found"
    return false
end

local function discover_spawn_methods()
    if #spawn_methods > 0 then return true end

    local ok, td = pcall(function()
        return sdk.find_type_definition("app.solid.gamemastering.NpcManager")
    end)

    if not ok or not td then
        last_error = "NpcManager type not found"
        return false
    end

    local methods = td:get_methods()
    if not methods then
        last_error = "Could not get methods"
        return false
    end

    for _, method in ipairs(methods) do
        local name_ok, name = pcall(method.get_name, method)
        if name_ok and name == "spawnNPC" then
            table.insert(spawn_methods, {
                method = method,
            })
            M.log("Found spawnNPC method")
        end
    end

    if #spawn_methods == 0 then
        last_error = "No spawnNPC methods found"
        return false
    end

    return true
end

local function discover_survivor_types()
    if next(survivor_types) then return true end

    local ok, td = pcall(function()
        return sdk.find_type_definition("app.solid.gamemastering.SurvivorType")
    end)

    if not ok or not td then return false end

    local fields = td:get_fields()
    if not fields then return false end

    for _, field in ipairs(fields) do
        local f_ok, is_static = pcall(field.is_static, field)
        if f_ok and is_static then
            local n_ok, fname = pcall(field.get_name, field)
            local v_ok, fval = pcall(field.get_data, field, nil)
            if n_ok and v_ok and fname and fval then
                survivor_types[fname] = fval
            end
        end
    end

    return true
end

------------------------------------------------------------
-- Spawn Functions
------------------------------------------------------------

function M.simple_spawn(type_id)
    M.log("=== SIMPLE SPAWN TEST ===")
    M.log("Type ID: " .. tostring(type_id))

    if not discover_npc_manager() then
        M.log("FAILED: " .. last_error)
        return false
    end

    if not discover_spawn_methods() then
        M.log("FAILED: " .. last_error)
        return false
    end

    M.log("Found " .. #spawn_methods .. " spawnNPC methods")

    -- Try each method with just the type argument
    for i, info in ipairs(spawn_methods) do
        M.log("Trying method #" .. i)

        -- Try with minimal args first (type, nil, nil)
        local ok, result = pcall(function()
            return info.method:call(npc_manager, type_id, nil, nil)
        end)

        M.log("  (type, nil, nil): ok=" .. tostring(ok) .. " result=" .. tostring(result))

        if ok and result then
            M.log("SUCCESS!")
            return true
        end

        -- Try with more nils if that didn't work
        local ok2, result2 = pcall(function()
            return info.method:call(npc_manager, type_id, nil, nil, nil, nil)
        end)

        M.log("  (type, nil x5): ok=" .. tostring(ok2) .. " result=" .. tostring(result2))

        if ok2 and result2 then
            M.log("SUCCESS!")
            return true
        end
    end

    M.log("All methods failed")
    return false
end

------------------------------------------------------------
-- NPC Finding and Teleporting
------------------------------------------------------------

local function get_player_position()
    local result = nil
    pcall(function()
        local player_mgr = sdk.get_managed_singleton("app.solid.PlayerManager")
        if player_mgr then
            local condition = player_mgr:get_field("_CurrentPlayerCondition")
            if condition then
                local pos = condition:get_field("LastPlayerPos")
                if pos then
                    result = { x = pos.x, y = pos.y, z = pos.z }
                end
            end
        end
    end)
    return result
end

local function find_npc_by_type(survivor_type)
    -- Try to find NPCs in the NpcManager's lists
    if not npc_manager then
        discover_npc_manager()
    end
    if not npc_manager then return nil end

    -- Try various field names that might contain NPC lists
    local list_field_names = {
        "mpNpcList",
        "mNpcList",
        "mpReplaceList",
        "mReplaceList",
        "_NpcList",
        "NpcList",
    }

    for _, field_name in ipairs(list_field_names) do
        local ok, list = pcall(function()
            return npc_manager:get_field(field_name)
        end)

        if ok and list then
            -- Try to iterate the list
            local count_ok, count = pcall(function()
                return list:call("get_Count") or list:call("get_size") or 0
            end)

            if count_ok and count and count > 0 then
                M.log("Found list '" .. field_name .. "' with " .. count .. " items")

                for i = 0, count - 1 do
                    local item_ok, item = pcall(function()
                        return list:call("get_Item", i) or list:call("Get", i)
                    end)

                    if item_ok and item then
                        -- Check if this NPC matches our type
                        local type_ok, npc_type = pcall(function()
                            return item:get_field("mSurvivorType") or
                                   item:get_field("SurvivorType") or
                                   item:get_field("mType")
                        end)

                        if type_ok and npc_type == survivor_type then
                            M.log("Found NPC of type " .. survivor_type .. " at index " .. i)
                            return item
                        end
                    end
                end
            end
        end
    end

    return nil
end

local function teleport_npc(npc, pos)
    if not npc or not pos then return false end

    M.log(string.format("Teleporting NPC to (%.1f, %.1f, %.1f)", pos.x, pos.y, pos.z))

    -- Try to set mPos field
    local ok = pcall(function()
        -- Create a vec3
        local vec3_td = sdk.find_type_definition("via.vec3")
        if vec3_td then
            local new_pos = ValueType.new(vec3_td)
            new_pos.x = pos.x
            new_pos.y = pos.y
            new_pos.z = pos.z
            npc:set_field("mPos", new_pos)
        end
    end)

    if ok then
        M.log("Set mPos successfully")
        return true
    end

    -- Try alternate field names
    local field_names = {"mPos", "mPosition", "Position", "_Position"}
    for _, fname in ipairs(field_names) do
        local ok2 = pcall(function()
            local vec3_td = sdk.find_type_definition("via.vec3")
            local new_pos = ValueType.new(vec3_td)
            new_pos.x = pos.x
            new_pos.y = pos.y
            new_pos.z = pos.z
            npc:set_field(fname, new_pos)
        end)
        if ok2 then
            M.log("Set " .. fname .. " successfully")
            return true
        end
    end

    M.log("Could not teleport NPC")
    return false
end

------------------------------------------------------------
-- Spawn and Teleport
------------------------------------------------------------

function M.spawn_and_teleport(type_id)
    M.log("=== SPAWN AND TELEPORT ===")
    M.log("Type ID: " .. tostring(type_id))

    -- Get player position first
    local player_pos = get_player_position()
    if not player_pos then
        M.log("ERROR: Could not get player position")
        return false
    end
    M.log(string.format("Player at: (%.1f, %.1f, %.1f)", player_pos.x, player_pos.y, player_pos.z))

    -- Spawn the NPC
    local spawn_ok = M.simple_spawn(type_id)
    M.log("Spawn result: " .. tostring(spawn_ok))

    -- Wait a moment then try to find and teleport
    -- (In practice this might need to be deferred to next frame)
    local npc = find_npc_by_type(type_id)
    if npc then
        local target_pos = {
            x = player_pos.x + 2,
            y = player_pos.y,
            z = player_pos.z + 2
        }
        teleport_npc(npc, target_pos)
    else
        M.log("Could not find spawned NPC in lists")
    end

    return spawn_ok
end

------------------------------------------------------------
-- List all NPCs (debug)
------------------------------------------------------------

function M.list_npcs()
    M.log("=== LISTING ALL NPCS ===")

    if not npc_manager then
        discover_npc_manager()
    end
    if not npc_manager then
        M.log("ERROR: No NpcManager")
        return
    end

    -- Get type definition to find all fields
    local td = npc_manager:get_type_definition()
    if not td then
        M.log("ERROR: Could not get type definition")
        return
    end

    local fields = td:get_fields()
    if not fields then
        M.log("ERROR: Could not get fields")
        return
    end

    for _, field in ipairs(fields) do
        local fname_ok, fname = pcall(field.get_name, field)
        if fname_ok and fname then
            -- Check if it looks like a list
            if fname:lower():find("list") or fname:lower():find("npc") then
                local fval_ok, fval = pcall(field.get_data, field, npc_manager)
                if fval_ok and fval then
                    -- Try to get count
                    local count = nil
                    pcall(function()
                        count = fval:call("get_Count")
                    end)
                    if not count then
                        pcall(function()
                            count = fval:call("get_size")
                        end)
                    end

                    local type_str = ""
                    pcall(function()
                        local ftd = field:get_type()
                        type_str = ftd and ftd:get_full_name() or ""
                    end)

                    M.log(string.format("  %s: %s (count=%s)", fname, type_str, tostring(count or "?")))
                end
            end
        end
    end
end

local function draw_window()
    if not show_window then return end

    local ok, err = pcall(function()
        imgui.set_next_window_size(Vector2f.new(400, 400), 4)
        show_window = imgui.begin_window("NPC Spawner (Minimal)", show_window, 0)

        imgui.text("Minimal NPC Spawner")
        imgui.separator()

        -- Status
        local mgr_status = npc_manager and "FOUND" or "NOT FOUND"
        imgui.text("NpcManager: " .. mgr_status)
        imgui.text("Spawn Methods: " .. #spawn_methods)

        if last_error ~= "" then
            imgui.text_colored("Error: " .. last_error, 0xFFFF8888)
        end

        imgui.separator()

        -- Simple spawn buttons
        imgui.text("Simple Spawn (default location):")
        if imgui.button("Burt (0)") then M.simple_spawn(0) end
        imgui.same_line()
        if imgui.button("Ronald (11)") then M.simple_spawn(11) end
        imgui.same_line()
        if imgui.button("Jessie (61)") then M.simple_spawn(61) end

        imgui.separator()

        -- Spawn + teleport buttons
        imgui.text("Spawn + Teleport to Player:")
        if imgui.button("Burt##tp") then M.spawn_and_teleport(0) end
        imgui.same_line()
        if imgui.button("Ronald##tp") then M.spawn_and_teleport(11) end
        imgui.same_line()
        if imgui.button("Jessie##tp") then M.spawn_and_teleport(61) end

        imgui.separator()

        -- Debug buttons
        imgui.text("Debug:")
        if imgui.button("List NPCs") then M.list_npcs() end
        imgui.same_line()
        if imgui.button("Discover All") then
            discover_npc_manager()
            discover_spawn_methods()
            discover_survivor_types()
            M.log("Discovery complete")
        end

        -- Player position
        local ppos = get_player_position()
        if ppos then
            imgui.text(string.format("Player: (%.1f, %.1f, %.1f)", ppos.x, ppos.y, ppos.z))
        else
            imgui.text("Player: unknown")
        end

        imgui.end_window()
    end)

    if not ok then
        M.log("GUI ERROR: " .. tostring(err))
    end
end

------------------------------------------------------------
-- REFramework hooks
------------------------------------------------------------

re.on_frame(function()
    local ok = pcall(draw_window)
end)

re.on_draw_ui(function()
    local changed
    changed, show_window = imgui.checkbox("NPC Spawner (Minimal)", show_window)
end)

------------------------------------------------------------
-- Console commands
------------------------------------------------------------

_G.npc_min = function(type_id)
    return M.simple_spawn(type_id or 0)
end

_G.npc_tp = function(type_id)
    return M.spawn_and_teleport(type_id or 0)
end

_G.npc_list = function()
    return M.list_npcs()
end

_G.npc_discover = function()
    discover_npc_manager()
    discover_spawn_methods()
    discover_survivor_types()
    M.log("Discovery complete")
end

------------------------------------------------------------

M.log("NpcSpawnerMinimal loaded")
M.log("Commands: npc_min(id), npc_tp(id), npc_list(), npc_discover()")

return M