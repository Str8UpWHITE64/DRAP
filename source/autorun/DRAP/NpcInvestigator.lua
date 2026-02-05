-- DRAP/SurvivorDeepDive.lua
-- Deep dive into NpcInfoList and cScoopList structures
-- Goal: Find the "rescued" state tracking

local Shared = require("DRAP/Shared")

local M = Shared.create_module("SurvivorDeepDive")

------------------------------------------------------------
-- Singleton Managers
------------------------------------------------------------

local npc_mgr = M:add_singleton("npc", "app.solid.gamemastering.NpcManager")

------------------------------------------------------------
-- Type Exploration
------------------------------------------------------------

local function explore_type(type_name)
    local td = sdk.find_type_definition(type_name)
    if not td then
        M.log(string.format("Type not found: %s", type_name))
        return nil
    end

    M.log(string.format("=== TYPE: %s ===", type_name))

    -- Fields
    local fields = td:get_fields()
    if fields then
        M.log("Fields:")
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

    -- Methods (filtered for interesting ones)
    local methods = td:get_methods()
    if methods then
        M.log("Methods (filtered):")
        for _, method in ipairs(methods) do
            if method then
                local mname = nil
                pcall(function() mname = method:get_name() end)
                if mname then
                    local lower = mname:lower()
                    if lower:find("get") or lower:find("set") or lower:find("is") or
                       lower:find("check") or lower:find("state") or lower:find("rescue") or
                       lower:find("save") or lower:find("complete") or lower:find("escort") then
                        local params = 0
                        pcall(function() params = method:get_num_params() end)
                        M.log(string.format("  %s (params: %d)", mname, params))
                    end
                end
            end
        end
    end

    return td
end

------------------------------------------------------------
-- Object Field Dumper (recursive)
------------------------------------------------------------

local function dump_all_fields(obj, name, indent)
    indent = indent or ""
    if not obj then
        M.log(string.format("%s%s: nil", indent, name))
        return
    end

    local td = nil
    pcall(function() td = obj:get_type_definition() end)
    if not td then
        M.log(string.format("%s%s: (no type def) %s", indent, name, tostring(obj)))
        return
    end

    local type_name = nil
    pcall(function() type_name = td:get_full_name() end)

    M.log(string.format("%s%s [%s]:", indent, name, type_name or "?"))

    local fields = td:get_fields()
    if not fields then return end

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

                if val == nil then
                    M.log(string.format("%s  %s: nil", indent, fname))
                elseif type(val) == "userdata" then
                    -- Check if collection
                    local count = Shared.get_collection_count(val)
                    if count >= 0 then
                        M.log(string.format("%s  %s: [%d items] (%s)", indent, fname, count, ftype or "?"))
                    else
                        -- Simple value or object
                        local str = tostring(val)
                        if #str > 60 then str = str:sub(1, 60) .. "..." end
                        M.log(string.format("%s  %s: %s (%s)", indent, fname, str, ftype or "?"))
                    end
                else
                    M.log(string.format("%s  %s: %s (%s)", indent, fname, tostring(val), type(val)))
                end
            end
        end
    end
end

------------------------------------------------------------
-- NpcInfoList Exploration
------------------------------------------------------------

function M.dump_npc_info_list()
    local mgr = npc_mgr:get()
    if not mgr then
        M.log("NpcManager not available")
        return
    end

    M.log("=== DUMPING NpcInfoList ===")

    local td = mgr:get_type_definition()
    if not td then return end

    local field = td:get_field("NpcInfoList")
    if not field then
        M.log("NpcInfoList field not found")
        return
    end

    local list = nil
    pcall(function() list = field:get_data(mgr) end)
    if not list then
        M.log("Could not get NpcInfoList")
        return
    end

    local count = Shared.get_collection_count(list)
    M.log(string.format("NpcInfoList has %d items", count))

    for i = 0, count - 1 do
        local item = Shared.get_collection_item(list, i)
        if item then
            M.log(string.format("\n--- NPC INFO [%d] ---", i))
            dump_all_fields(item, "NpcBaseInfo")
        end
    end
end

------------------------------------------------------------
-- NpcBaseInfo Type Exploration
------------------------------------------------------------

function M.explore_npc_base_info()
    M.log("=== EXPLORING NpcBaseInfo TYPE ===")

    local types = {
        "app.solid.npc.NpcBaseInfo",
        "solid.npc.NpcBaseInfo",
        "solid.MT2RE.NpcBaseInfo",
    }

    for _, t in ipairs(types) do
        local td = explore_type(t)
        if td then break end
    end
end

------------------------------------------------------------
-- cScoopList Exploration
------------------------------------------------------------

function M.explore_scoop_types()
    M.log("=== EXPLORING SCOOP TYPES ===")

    local types = {
        "solid.MT2RE.cScoopList",
        "solid.MT2RE.rScoopList",
        "solid.MT2RE.ScoopData",
        "solid.MT2RE.Scoop",
        "app.solid.ScoopData",
    }

    for _, t in ipairs(types) do
        explore_type(t)
    end
end

------------------------------------------------------------
-- Find and Dump Scoop List Instance
------------------------------------------------------------

function M.find_scoop_list()
    M.log("=== SEARCHING FOR SCOOP LIST INSTANCE ===")

    -- Search common singletons for scoop list references
    local singletons = {
        {"app.solid.gamemastering.NpcManager", "npc"},
        {"app.solid.gamemastering.GameMaster", "gm"},
        {"app.solid.gamemastering.AreaManager", "area"},
        {"app.solid.gamemastering.MissionManager", "mission"},
    }

    for _, info in ipairs(singletons) do
        local singleton_name = info[1]
        local short_name = info[2]

        local mgr = sdk.get_managed_singleton(singleton_name)
        if mgr then
            local td = mgr:get_type_definition()
            if td then
                local fields = td:get_fields()
                if fields then
                    for _, field in ipairs(fields) do
                        if field then
                            local fname, ftype = nil, nil
                            pcall(function() fname = field:get_name() end)
                            pcall(function() ftype = field:get_type():get_full_name() end)

                            if ftype and (ftype:find("Scoop") or ftype:find("scoop")) then
                                M.log(string.format("FOUND in %s: %s (%s)", short_name, fname, ftype))

                                local val = nil
                                pcall(function() val = field:get_data(mgr) end)
                                if val then
                                    dump_all_fields(val, fname, "  ")

                                    -- If it has mpScoopList, dump that too
                                    local val_td = nil
                                    pcall(function() val_td = val:get_type_definition() end)
                                    if val_td then
                                        local scoop_list_field = val_td:get_field("mpScoopList")
                                        if scoop_list_field then
                                            local scoop_list = nil
                                            pcall(function() scoop_list = scoop_list_field:get_data(val) end)
                                            if scoop_list then
                                                local scount = Shared.get_collection_count(scoop_list)
                                                M.log(string.format("    mpScoopList has %d items", scount))

                                                -- Dump first few scoop items
                                                for j = 0, math.min(scount - 1, 5) do
                                                    local scoop_item = Shared.get_collection_item(scoop_list, j)
                                                    if scoop_item then
                                                        M.log(string.format("\n    --- SCOOP [%d] ---", j))
                                                        dump_all_fields(scoop_item, "cScoopList", "      ")
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
            end
        end
    end
end

------------------------------------------------------------
-- SurvivorDefine Exploration
------------------------------------------------------------

function M.explore_survivor_define()
    M.log("=== EXPLORING SurvivorDefine ===")

    local types = {
        "app.solid.SurvivorDefine",
        "app.solid.SurvivorDefine.SurvivorType",
        "solid.SurvivorDefine",
    }

    for _, t in ipairs(types) do
        local td = sdk.find_type_definition(t)
        if td then
            M.log(string.format("Found: %s", t))

            -- Get static fields (enum values)
            local fields = td:get_fields()
            if fields then
                local values = {}
                for _, field in ipairs(fields) do
                    if field then
                        local fname = nil
                        local is_static = false
                        pcall(function() fname = field:get_name() end)
                        pcall(function() is_static = field:is_static() end)

                        if fname and is_static and fname ~= "value__" then
                            local val = nil
                            pcall(function() val = field:get_data(nil) end)
                            if val ~= nil then
                                table.insert(values, {name = fname, value = tonumber(val) or val})
                            end
                        end
                    end
                end

                -- Sort by value
                table.sort(values, function(a, b)
                    if type(a.value) == "number" and type(b.value) == "number" then
                        return a.value < b.value
                    end
                    return tostring(a.value) < tostring(b.value)
                end)

                M.log(string.format("  Survivor Types (%d):", #values))
                for _, v in ipairs(values) do
                    M.log(string.format("    %s = %s", v.name, tostring(v.value)))
                end
            end
        end
    end
end

------------------------------------------------------------
-- Watch NPC State Changes
------------------------------------------------------------

local npc_states = {}  -- { [index] = { field_name = value, ... } }
local watching = false
local watch_fields = {
    "mLiveState", "mAreaNo", "mScoopState", "mEscortState",
    "mCarryOverFlag", "mSavedFlag", "mRescuedFlag", "mJoinFlag",
    "mDeadFlag", "mState", "mStatus", "mPhase",
}

function M.start_watching()
    watching = true
    npc_states = {}
    M.log("Started watching NPC states")
    M.log(string.format("Watching fields: %s", table.concat(watch_fields, ", ")))
end

function M.stop_watching()
    watching = false
    M.log("Stopped watching")
end

local function check_state_changes()
    if not watching then return end

    local mgr = npc_mgr:get()
    if not mgr then return end

    local td = mgr:get_type_definition()
    if not td then return end

    local field = td:get_field("NpcInfoList")
    if not field then return end

    local list = nil
    pcall(function() list = field:get_data(mgr) end)
    if not list then return end

    local count = Shared.get_collection_count(list)

    for i = 0, count - 1 do
        local item = Shared.get_collection_item(list, i)
        if item then
            local item_td = nil
            pcall(function() item_td = item:get_type_definition() end)
            if item_td then
                local current = {}
                local npc_id = nil

                -- Get NPC ID for identification
                pcall(function() npc_id = Shared.to_int(item:get_field("mNpcId")) end)
                if not npc_id then
                    pcall(function() npc_id = Shared.to_int(item:get_field("mSurvivorType")) end)
                end

                -- Check all watched fields
                for _, fname in ipairs(watch_fields) do
                    local f = item_td:get_field(fname)
                    if f then
                        local val = nil
                        pcall(function() val = f:get_data(item) end)
                        if val ~= nil then
                            current[fname] = val
                        end
                    end
                end

                -- Compare with previous state
                local prev = npc_states[i]
                if prev then
                    for fname, new_val in pairs(current) do
                        local old_val = prev[fname]
                        if old_val ~= nil and tostring(old_val) ~= tostring(new_val) then
                            M.log(string.format("NPC[%d] (ID=%s) %s: %s -> %s",
                                i, tostring(npc_id), fname, tostring(old_val), tostring(new_val)))
                        end
                    end
                end

                npc_states[i] = current
            end
        end
    end
end

------------------------------------------------------------
-- Escort/Rescue Field Search
------------------------------------------------------------

function M.search_rescue_fields()
    M.log("=== SEARCHING FOR RESCUE-RELATED FIELDS ===")

    -- Search NpcBaseInfo type
    local types_to_search = {
        "app.solid.npc.NpcBaseInfo",
        "solid.npc.NpcBaseInfo",
        "solid.MT2RE.NpcBaseInfo",
        "app.solid.npc.NpcReplaceInfo",
        "app.solid.gamemastering.NpcManager.NpcReplaceInfo",
    }

    local keywords = {"rescue", "save", "escort", "complete", "finish", "end", "safe", "success", "state", "flag", "phase"}

    for _, type_name in ipairs(types_to_search) do
        local td = sdk.find_type_definition(type_name)
        if td then
            M.log(string.format("Searching in %s:", type_name))

            local fields = td:get_fields()
            if fields then
                for _, field in ipairs(fields) do
                    if field then
                        local fname = nil
                        local ftype = nil
                        pcall(function() fname = field:get_name() end)
                        pcall(function() ftype = field:get_type():get_full_name() end)

                        if fname then
                            local lower = fname:lower()
                            for _, kw in ipairs(keywords) do
                                if lower:find(kw) then
                                    M.log(string.format("  FOUND: %s (%s)", fname, ftype or "?"))
                                    break
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
-- Full Analysis
------------------------------------------------------------

function M.full_analysis()
    M.explore_npc_base_info()
    M.log("")
    M.explore_scoop_types()
    M.log("")
    M.find_scoop_list()
    M.log("")
    M.dump_npc_info_list()
    M.log("")
    M.search_rescue_fields()
end

------------------------------------------------------------
-- Per-frame Hook
------------------------------------------------------------

re.on_frame(function()
    if watching then
        check_state_changes()
    end
end)

------------------------------------------------------------
-- Console Commands
------------------------------------------------------------

_G.surv_info = function() M.dump_npc_info_list() end
_G.surv_type = function() M.explore_npc_base_info() end
_G.surv_scoop = function() M.explore_scoop_types() end
_G.surv_find = function() M.find_scoop_list() end
_G.surv_define = function() M.explore_survivor_define() end
_G.surv_rescue = function() M.search_rescue_fields() end
_G.surv_watch = function() M.start_watching() end
_G.surv_unwatch = function() M.stop_watching() end
_G.surv_full = function() M.full_analysis() end

------------------------------------------------------------
-- Module Load
------------------------------------------------------------

M.log("SurvivorDeepDive loaded")
M.log("Commands:")
M.log("  surv_info()   - Dump current NpcInfoList contents")
M.log("  surv_type()   - Explore NpcBaseInfo type")
M.log("  surv_scoop()  - Explore scoop types")
M.log("  surv_find()   - Find scoop list instances")
M.log("  surv_define() - Explore SurvivorDefine enum")
M.log("  surv_rescue() - Search for rescue-related fields")
M.log("  surv_watch()  - Watch for state changes")
M.log("  surv_full()   - Run full analysis")

return M