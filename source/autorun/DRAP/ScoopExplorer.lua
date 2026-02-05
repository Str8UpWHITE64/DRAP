-- DRAP/ScoopExplorer.lua
-- Focused exploration of Scoop/Mission data structures
-- Goal: Find how "rescued" survivors are tracked

local Shared = require("DRAP/Shared")

local M = Shared.create_module("ScoopExplorer")

------------------------------------------------------------
-- Known/Suspected Types
------------------------------------------------------------

local SCOOP_TYPES = {
    "solid.MT2RE.rScoopList",
    "solid.MT2RE.ScoopData",
    "solid.MT2RE.ScoopInfo",
    "solid.MT2RE.Scoop",
    "app.solid.MT2RE.rScoopList",
    "app.solid.ScoopData",
}

local MISSION_TYPES = {
    "solid.MT2RE.rMissionList",
    "solid.MT2RE.MissionData",
    "solid.MT2RE.Mission",
    "app.solid.gamemastering.MissionManager",
}

------------------------------------------------------------
-- Singleton Exploration
------------------------------------------------------------

function M.find_scoop_singleton()
    M.log("=== SEARCHING FOR SCOOP SINGLETON ===")

    -- Common singleton patterns
    local patterns = {
        "app.solid.gamemastering.%s",
        "app.solid.%s",
        "solid.gamemastering.%s",
        "solid.%s",
    }

    local names = {
        "ScoopManager", "ScoopList", "MissionManager", "MissionList",
        "SurvivorManager", "EscortManager", "QuestManager", "TaskManager",
    }

    for _, pattern in ipairs(patterns) do
        for _, name in ipairs(names) do
            local full_name = string.format(pattern, name)
            local mgr = sdk.get_managed_singleton(full_name)
            if mgr then
                M.log(string.format("FOUND SINGLETON: %s", full_name))
                M.dump_singleton(mgr, full_name)
            end
        end
    end
end

function M.dump_singleton(mgr, name)
    if not mgr then return end

    local td = mgr:get_type_definition()
    if not td then return end

    M.log(string.format("--- %s Fields ---", name))

    local fields = td:get_fields()
    if fields then
        for _, field in ipairs(fields) do
            if field then
                local fname, ftype = nil, nil
                pcall(function() fname = field:get_name() end)
                pcall(function() ftype = field:get_type():get_full_name() end)

                if fname then
                    -- Get value
                    local val = nil
                    pcall(function() val = field:get_data(mgr) end)

                    local val_str = "nil"
                    if val ~= nil then
                        local count = Shared.get_collection_count(val)
                        if count >= 0 then
                            val_str = string.format("[%d items]", count)
                        else
                            val_str = tostring(val)
                        end
                    end

                    M.log(string.format("  %s: %s = %s", fname, ftype or "?", val_str))
                end
            end
        end
    end

    M.log(string.format("--- %s Methods ---", name))
    local methods = td:get_methods()
    if methods then
        for _, method in ipairs(methods) do
            if method then
                local mname = nil
                pcall(function() mname = method:get_name() end)
                if mname then
                    local lower = mname:lower()
                    -- Only log interesting methods
                    if lower:find("scoop") or lower:find("mission") or
                       lower:find("survivor") or lower:find("rescue") or
                       lower:find("complete") or lower:find("clear") or
                       lower:find("get") or lower:find("check") then
                        local params = 0
                        pcall(function() params = method:get_num_params() end)
                        M.log(string.format("  %s (params: %d)", mname, params))
                    end
                end
            end
        end
    end
end

------------------------------------------------------------
-- GameMaster Exploration (often has mission/scoop refs)
------------------------------------------------------------

function M.explore_game_master()
    M.log("=== EXPLORING GAMEMASTER ===")

    local gm = sdk.get_managed_singleton("app.solid.gamemastering.GameMaster")
    if not gm then
        M.log("GameMaster not found")
        return
    end

    M.dump_singleton(gm, "GameMaster")

    -- Try to access any scoop/mission related fields
    local td = gm:get_type_definition()
    if not td then return end

    local fields = td:get_fields()
    if fields then
        for _, field in ipairs(fields) do
            if field then
                local fname = nil
                pcall(function() fname = field:get_name() end)
                if fname then
                    local lower = fname:lower()
                    if lower:find("scoop") or lower:find("mission") or
                       lower:find("task") or lower:find("quest") then
                        M.log(string.format("Interesting field: %s", fname))

                        local val = nil
                        pcall(function() val = field:get_data(gm) end)
                        if val then
                            M.dump_object(val, fname, 2)
                        end
                    end
                end
            end
        end
    end
end

------------------------------------------------------------
-- Object Dumping
------------------------------------------------------------

function M.dump_object(obj, name, max_depth)
    max_depth = max_depth or 1
    if max_depth <= 0 then return end
    if not obj then
        M.log(string.format("%s: nil", name))
        return
    end

    local td = nil
    pcall(function() td = obj:get_type_definition() end)
    if not td then return end

    local type_name = nil
    pcall(function() type_name = td:get_full_name() end)

    M.log(string.format("-- %s (%s) --", name, type_name or "?"))

    -- Check if it's a collection
    local count = Shared.get_collection_count(obj)
    if count >= 0 then
        M.log(string.format("  Collection with %d items", count))

        -- Dump first few items
        for i = 0, math.min(count - 1, 3) do
            local item = Shared.get_collection_item(obj, i)
            if item then
                M.dump_object(item, string.format("%s[%d]", name, i), max_depth - 1)
            end
        end
        return
    end

    -- Dump fields
    local fields = td:get_fields()
    if fields then
        for _, field in ipairs(fields) do
            if field then
                local fname, ftype = nil, nil
                local is_static = false
                pcall(function() fname = field:get_name() end)
                pcall(function() ftype = field:get_type():get_full_name() end)
                pcall(function() is_static = field:is_static() end)

                if fname and not is_static then
                    local val = nil
                    pcall(function() val = field:get_data(obj) end)

                    local val_str = "nil"
                    if val ~= nil then
                        if type(val) == "userdata" then
                            local sub_count = Shared.get_collection_count(val)
                            if sub_count >= 0 then
                                val_str = string.format("[%d items]", sub_count)
                            else
                                val_str = tostring(val):sub(1, 50)
                            end
                        else
                            val_str = tostring(val)
                        end
                    end

                    M.log(string.format("  %s: %s = %s", fname, ftype or "?", val_str))
                end
            end
        end
    end
end

------------------------------------------------------------
-- Search All Singletons for Scoop Data
------------------------------------------------------------

function M.search_all_singletons()
    M.log("=== SEARCHING ALL SINGLETONS ===")

    local singletons = {
        "app.solid.gamemastering.GameMaster",
        "app.solid.gamemastering.NpcManager",
        "app.solid.gamemastering.AreaManager",
        "app.solid.gamemastering.EventFlagsManager",
        "app.solid.gamemastering.MissionManager",
        "app.solid.gamemastering.TimeManager",
        "app.solid.PlayerManager",
    }

    for _, singleton_name in ipairs(singletons) do
        local mgr = sdk.get_managed_singleton(singleton_name)
        if mgr then
            local td = mgr:get_type_definition()
            if td then
                local fields = td:get_fields()
                if fields then
                    for _, field in ipairs(fields) do
                        if field then
                            local fname = nil
                            local ftype = nil
                            pcall(function() fname = field:get_name() end)
                            pcall(function() ftype = field:get_type():get_full_name() end)

                            if fname and ftype then
                                local lower_name = fname:lower()
                                local lower_type = ftype:lower()

                                -- Look for scoop/mission/survivor related
                                if lower_name:find("scoop") or lower_type:find("scoop") or
                                   lower_name:find("mission") or lower_type:find("mission") or
                                   lower_name:find("survivor") or lower_type:find("survivor") or
                                   lower_name:find("rescue") or lower_type:find("rescue") then

                                    M.log(string.format("FOUND in %s: %s (%s)",
                                        singleton_name, fname, ftype))

                                    -- Get and dump the value
                                    local val = nil
                                    pcall(function() val = field:get_data(mgr) end)
                                    if val then
                                        M.dump_object(val, fname, 2)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

------------------------------------------------------------
-- Specific Type Exploration
------------------------------------------------------------

function M.explore_type(type_name)
    M.log(string.format("=== EXPLORING TYPE: %s ===", type_name))

    local td = sdk.find_type_definition(type_name)
    if not td then
        M.log("Type not found")
        return
    end

    M.log("Fields:")
    local fields = td:get_fields()
    if fields then
        for _, field in ipairs(fields) do
            if field then
                local fname, ftype, is_static = nil, nil, false
                pcall(function() fname = field:get_name() end)
                pcall(function() ftype = field:get_type():get_full_name() end)
                pcall(function() is_static = field:is_static() end)

                if fname then
                    local static_str = is_static and " [STATIC]" or ""
                    M.log(string.format("  %s: %s%s", fname, ftype or "?", static_str))
                end
            end
        end
    end

    M.log("Methods:")
    local methods = td:get_methods()
    if methods then
        for _, method in ipairs(methods) do
            if method then
                local mname = nil
                local params = 0
                pcall(function() mname = method:get_name() end)
                pcall(function() params = method:get_num_params() end)

                if mname then
                    M.log(string.format("  %s (params: %d)", mname, params))
                end
            end
        end
    end
end

------------------------------------------------------------
-- Try Direct rScoopList Access
------------------------------------------------------------

function M.try_rscooplist()
    M.log("=== TRYING rScoopList ===")

    -- rScoopList might be accessed through the resource system
    local resource_mgr = sdk.get_managed_singleton("via.ResourceManager")
    if resource_mgr then
        M.log("ResourceManager found - rScoopList might be a resource file")
    end

    -- Try to find it as a field in NpcManager
    local npc_mgr = sdk.get_managed_singleton("app.solid.gamemastering.NpcManager")
    if npc_mgr then
        local td = npc_mgr:get_type_definition()
        if td then
            -- Look for any field with "Scoop" in name or type
            local fields = td:get_fields()
            if fields then
                for _, field in ipairs(fields) do
                    if field then
                        local fname = nil
                        local ftype = nil
                        pcall(function() fname = field:get_name() end)
                        pcall(function() ftype = field:get_type():get_full_name() end)

                        if (fname and fname:find("Scoop")) or (ftype and ftype:find("Scoop")) then
                            M.log(string.format("Found: %s (%s)", fname or "?", ftype or "?"))

                            local val = nil
                            pcall(function() val = field:get_data(npc_mgr) end)
                            if val then
                                M.dump_object(val, fname, 3)
                            end
                        end
                    end
                end
            end
        end
    end

    -- Also check AreaManager
    local area_mgr = sdk.get_managed_singleton("app.solid.gamemastering.AreaManager")
    if area_mgr then
        local td = area_mgr:get_type_definition()
        if td then
            local fields = td:get_fields()
            if fields then
                for _, field in ipairs(fields) do
                    if field then
                        local fname = nil
                        local ftype = nil
                        pcall(function() fname = field:get_name() end)
                        pcall(function() ftype = field:get_type():get_full_name() end)

                        if (fname and fname:find("Scoop")) or (ftype and ftype:find("Scoop")) then
                            M.log(string.format("Found in AreaManager: %s (%s)", fname or "?", ftype or "?"))

                            local val = nil
                            pcall(function() val = field:get_data(area_mgr) end)
                            if val then
                                M.dump_object(val, fname, 3)
                            end
                        end
                    end
                end
            end
        end
    end
end

------------------------------------------------------------
-- Console Commands
------------------------------------------------------------

_G.scoop_find = function() M.find_scoop_singleton() end
_G.scoop_gm = function() M.explore_game_master() end
_G.scoop_all = function() M.search_all_singletons() end
_G.scoop_type = function(t) M.explore_type(t) end
_G.scoop_try = function() M.try_rscooplist() end

------------------------------------------------------------
-- Run all searches
------------------------------------------------------------

function M.full_search()
    M.find_scoop_singleton()
    M.explore_game_master()
    M.search_all_singletons()
    M.try_rscooplist()
end

_G.scoop_full = function() M.full_search() end

------------------------------------------------------------
-- Module Load
------------------------------------------------------------

M.log("ScoopExplorer loaded")
M.log("Commands: scoop_find(), scoop_gm(), scoop_all(), scoop_type(name), scoop_try()")
M.log("          scoop_full() - run all searches")

return M