-- DRAP/EventFlagDumper.lua
-- Diagnostic script to dump all flag names from solid.MT2RE.EventFlag
-- Run this once to extract all known flag mappings

local Shared = require("DRAP/Shared")

local M = Shared.create_module("EventFlagDumper")

local OUTPUT_FILE = "AP_DRDR_all_event_flags.json"

------------------------------------------------------------
-- Type Exploration Functions
------------------------------------------------------------

local function dump_type_fields(type_name)
    local td = sdk.find_type_definition(type_name)
    if not td then
        M.log("Type not found: " .. type_name)
        return nil
    end

    M.log(string.format("=== Dumping type: %s ===", type_name))

    local results = {
        type_name = type_name,
        full_name = nil,
        fields = {},
        static_values = {},
        methods = {},
    }

    pcall(function() results.full_name = td:get_full_name() end)

    -- Get fields
    local fields = td:get_fields()
    if fields then
        for i, field in ipairs(fields) do
            if field then
                local field_info = {}

                pcall(function() field_info.name = field:get_name() end)
                pcall(function() field_info.is_static = field:is_static() end)
                pcall(function() field_info.type = field:get_type():get_full_name() end)

                -- For static fields, try to get the value
                if field_info.is_static then
                    local ok, value = pcall(field.get_data, field, nil)
                    if ok then
                        field_info.value = value
                        field_info.value_str = tostring(value)

                        -- If it's a number, store in static_values map
                        local num = tonumber(value)
                        if num and field_info.name then
                            results.static_values[num] = field_info.name
                        end
                    end
                end

                table.insert(results.fields, field_info)

                if field_info.name and field_info.value then
                    M.log(string.format("  %s = %s", field_info.name, tostring(field_info.value)))
                end
            end
        end
    end

    M.log(string.format("  Found %d fields, %d static values",
        #results.fields, 0)) -- count static_values

    return results
end

local function dump_enum_values(type_name)
    local td = sdk.find_type_definition(type_name)
    if not td then
        M.log("Enum type not found: " .. type_name)
        return nil
    end

    M.log(string.format("=== Dumping enum: %s ===", type_name))

    local results = {}

    -- For enums, get the underlying values
    local fields = td:get_fields()
    if fields then
        for i, field in ipairs(fields) do
            if field then
                local name = nil
                local value = nil

                pcall(function() name = field:get_name() end)

                -- Skip the special "value__" field that enums have
                if name and name ~= "value__" then
                    local ok, v = pcall(field.get_data, field, nil)
                    if ok then
                        value = tonumber(v)
                    end

                    if value then
                        results[value] = name
                        M.log(string.format("  %d = %s", value, name))
                    end
                end
            end
        end
    end

    return results
end

------------------------------------------------------------
-- Main Dump Function
------------------------------------------------------------

function M.dump_all_event_flags()
    M.log("Starting comprehensive event flag dump...")

    local all_results = {
        timestamp = os.time(),
        types_explored = {},
        all_flags = {},
    }

    -- List of types to try
    local types_to_try = {
        "solid.MT2RE.EventFlag",
        "app.solid.MT2RE.EventFlag",
        "MT2RE.EventFlag",
        "EventFlag",
        "solid.EventFlag",
        "app.EventFlag",
        -- Also try the manager itself
        "app.solid.gamemastering.EventFlagsManager",
    }

    for _, type_name in ipairs(types_to_try) do
        local td = sdk.find_type_definition(type_name)
        if td then
            M.log(string.format("Found type: %s", type_name))

            -- Check if it's an enum
            local is_enum = false
            pcall(function() is_enum = td:is_a("System.Enum") end)

            local results
            if is_enum then
                results = dump_enum_values(type_name)
            else
                results = dump_type_fields(type_name)
            end

            if results then
                all_results.types_explored[type_name] = results

                -- Merge static values into all_flags
                if type(results) == "table" then
                    if results.static_values then
                        for num, name in pairs(results.static_values) do
                            all_results.all_flags[num] = name
                        end
                    else
                        -- Direct enum values
                        for num, name in pairs(results) do
                            if type(num) == "number" then
                                all_results.all_flags[num] = name
                            end
                        end
                    end
                end
            end
        end
    end

    -- Also try to iterate through all types looking for EventFlag-related ones
    M.log("Searching for additional EventFlag types...")

    -- Try to find nested types or related enums
    local efm_td = sdk.find_type_definition("app.solid.gamemastering.EventFlagsManager")
    if efm_td then
        local nested = nil
        pcall(function() nested = efm_td:get_nested_types() end)
        if nested then
            for _, nt in ipairs(nested) do
                if nt then
                    local nt_name = nil
                    pcall(function() nt_name = nt:get_full_name() end)
                    if nt_name then
                        M.log(string.format("Found nested type: %s", nt_name))
                        local results = dump_type_fields(nt_name)
                        if results and results.static_values then
                            for num, name in pairs(results.static_values) do
                                all_results.all_flags[num] = name
                            end
                        end
                    end
                end
            end
        end
    end

    -- Count and log summary
    local flag_count = 0
    for _ in pairs(all_results.all_flags) do flag_count = flag_count + 1 end

    M.log(string.format("=== DUMP COMPLETE ==="))
    M.log(string.format("Total flags found: %d", flag_count))

    -- Save to file
    Shared.save_json(OUTPUT_FILE, all_results, 2, M.log)
    M.log(string.format("Saved to %s", OUTPUT_FILE))

    return all_results
end

------------------------------------------------------------
-- Try getEventNameDefine for a range
------------------------------------------------------------

function M.extract_names_via_api(start_id, end_id)
    local efm = sdk.get_managed_singleton("app.solid.gamemastering.EventFlagsManager")
    if not efm then
        M.log("EventFlagsManager not available")
        return {}
    end

    M.log(string.format("Extracting names via getEventNameDefine for %d-%d...", start_id, end_id))

    local results = {}
    local found = 0

    for flag_id = start_id, end_id do
        local name = nil

        -- Try getEventNameDefine
        local ok, result = pcall(function()
            return efm:call("getEventNameDefine", flag_id)
        end)

        if ok and result then
            if type(result) == "string" and result ~= "" then
                name = result
            elseif type(result) == "userdata" then
                -- Try to extract string from userdata
                local str_ok, str = pcall(tostring, result)
                if str_ok and str and str ~= "" and not str:find("userdata") then
                    name = str
                end
            end
        end

        if name then
            results[flag_id] = name
            found = found + 1
            if found <= 50 or found % 100 == 0 then  -- Log first 50 and every 100th
                M.log(string.format("  %d: %s", flag_id, name))
            end
        end
    end

    M.log(string.format("Found %d names in range", found))
    return results
end

------------------------------------------------------------
-- Console Commands
------------------------------------------------------------

_G.dump_event_flags = function()
    return M.dump_all_event_flags()
end

_G.extract_flag_names = function(s, e)
    return M.extract_names_via_api(s or 1, e or 5000)
end

------------------------------------------------------------
-- Auto-run on load
------------------------------------------------------------

M.log("EventFlagDumper loaded")
M.log("Run dump_event_flags() to dump all event flag constants")
M.log("Run extract_flag_names(start, end) to try API-based extraction")

return M