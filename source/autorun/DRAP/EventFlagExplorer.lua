-- DRAP/EventFlagExplorer.lua
-- Tool for discovering, monitoring, and manipulating game event flags
-- Enhanced version with flag name extraction

local Shared = require("DRAP/Shared")

local M = Shared.create_module("EventFlagExplorer")
M:set_throttle(0.25)

------------------------------------------------------------
-- Configuration
------------------------------------------------------------

local FLAG_RANGES = {
    { name = "Low range",      start = 1,      stop = 500 },
    { name = "Mid range",      start = 500,    stop = 2000 },
    { name = "High range",     start = 2000,   stop = 5000 },
    { name = "Very high",      start = 5000,   stop = 10000 },
}

local KNOWN_FLAGS = {}
local DISCOVERED_FLAGS_FILE = "AP_DRDR_discovered_flags.json"
local FLAG_NAMES_FILE = "AP_DRDR_flag_names.json"

------------------------------------------------------------
-- Singleton Managers
------------------------------------------------------------

local efm_mgr = M:add_singleton("efm", "app.solid.gamemastering.EventFlagsManager")

------------------------------------------------------------
-- Internal State
------------------------------------------------------------

local flag_snapshot = {}
local recent_changes = {}
local MAX_RECENT_CHANGES = 100
local discovered_flags = {}
local flag_names_cache = {}  -- { [flag_id] = "name" }

local monitoring_enabled = false
local monitor_range_start = 1
local monitor_range_end = 5000

local gui_visible = false
local current_tab = 0
local scan_results = {}
local manual_flag_input = "1"

local efm_methods = {}
local methods_discovered = false

------------------------------------------------------------
-- EventFlag Type Exploration
------------------------------------------------------------

local event_flag_td = nil
local event_flag_fields = {}
local event_flag_enum_values = {}

local function explore_event_flag_type()
    -- Try to find the EventFlag type definition
    local type_names = {
        "solid.MT2RE.EventFlag",
        "app.solid.MT2RE.EventFlag",
        "MT2RE.EventFlag",
        "EventFlag",
    }

    for _, type_name in ipairs(type_names) do
        local td = sdk.find_type_definition(type_name)
        if td then
            event_flag_td = td
            M.log(string.format("Found EventFlag type: %s", type_name))

            -- Get all fields
            local fields = td:get_fields()
            if fields then
                M.log("=== EventFlag Fields ===")
                for i, field in ipairs(fields) do
                    if field then
                        local ok, name = pcall(field.get_name, field)
                        if ok and name then
                            local is_static = false
                            pcall(function() is_static = field:is_static() end)

                            local field_type = nil
                            pcall(function() field_type = field:get_type():get_full_name() end)

                            -- Try to get the value if it's a static field (likely enum-like constants)
                            local value = nil
                            if is_static then
                                pcall(function() value = field:get_data(nil) end)
                            end

                            event_flag_fields[name] = {
                                field = field,
                                is_static = is_static,
                                field_type = field_type,
                                value = value,
                            }

                            if value ~= nil then
                                M.log(string.format("  %s = %s (%s, static=%s)",
                                    name, tostring(value), tostring(field_type), tostring(is_static)))

                                -- If this is a number, it's likely a flag ID
                                local num_val = tonumber(value)
                                if num_val then
                                    event_flag_enum_values[num_val] = name
                                    flag_names_cache[num_val] = name
                                end
                            else
                                M.log(string.format("  %s (%s, static=%s)",
                                    name, tostring(field_type), tostring(is_static)))
                            end
                        end
                    end
                end
                M.log("=== End Fields ===")
            end

            -- Also check for nested types or enums
            local nested = nil
            pcall(function() nested = td:get_nested_types() end)
            if nested then
                M.log("=== Nested Types ===")
                for i, nt in ipairs(nested) do
                    if nt then
                        local ok, name = pcall(nt.get_full_name, nt)
                        if ok then M.log("  " .. tostring(name)) end
                    end
                end
                M.log("=== End Nested ===")
            end

            return true
        end
    end

    M.log("Could not find EventFlag type definition")
    return false
end

------------------------------------------------------------
-- Flag Name Extraction via getEventNameDefine
------------------------------------------------------------

local function try_get_event_name_define(flag_id)
    local efm = efm_mgr:get()
    if not efm then return nil end

    -- Try calling getEventNameDefine
    local ok, result = pcall(function()
        return efm:call("getEventNameDefine", flag_id)
    end)

    if ok and result then
        -- Result might be a string directly or an object
        if type(result) == "string" then
            return result
        elseif type(result) == "userdata" then
            -- Try to convert to string
            local str_ok, str = pcall(tostring, result)
            if str_ok and str and str ~= "" and not str:find("userdata") then
                return str
            end

            -- Try get_field for common string field names
            for _, field_name in ipairs({"value", "Value", "name", "Name", "m_value", "mValue"}) do
                local field_ok, field_val = pcall(function()
                    return result:get_field(field_name)
                end)
                if field_ok and field_val then
                    return tostring(field_val)
                end
            end
        end
    end

    return nil
end

local function try_get_event_no(name)
    local efm = efm_mgr:get()
    if not efm then return nil end

    local ok, result = pcall(function()
        return efm:call("getEventNo", name)
    end)

    if ok and result then
        return tonumber(result)
    end

    return nil
end

------------------------------------------------------------
-- Bulk Name Extraction
------------------------------------------------------------

--- Extract names for a range of flag IDs
--- @param start_id number Starting flag ID
--- @param end_id number Ending flag ID
--- @return table Map of flag_id -> name
function M.extract_names(start_id, end_id)
    M.log(string.format("Extracting names for flags %d to %d...", start_id, end_id))

    local names = {}
    local found = 0

    for flag_id = start_id, end_id do
        -- First check cache
        if flag_names_cache[flag_id] then
            names[flag_id] = flag_names_cache[flag_id]
            found = found + 1
        else
            -- Try getEventNameDefine
            local name = try_get_event_name_define(flag_id)
            if name and name ~= "" and name ~= "nil" then
                names[flag_id] = name
                flag_names_cache[flag_id] = name
                found = found + 1
            end
        end
    end

    M.log(string.format("Found %d names in range %d-%d", found, start_id, end_id))
    return names
end

--- Extract all names from EventFlag static fields (enum-like)
function M.extract_enum_names()
    if not event_flag_td then
        explore_event_flag_type()
    end

    local count = 0
    for flag_id, name in pairs(event_flag_enum_values) do
        if not flag_names_cache[flag_id] then
            flag_names_cache[flag_id] = name
            count = count + 1
        end
    end

    M.log(string.format("Extracted %d names from EventFlag enum", count))
    return event_flag_enum_values
end

------------------------------------------------------------
-- Dump All Known Names
------------------------------------------------------------

function M.dump_all_names()
    M.log("=== ALL KNOWN FLAG NAMES ===")

    -- Collect and sort
    local sorted = {}
    for flag_id, name in pairs(flag_names_cache) do
        table.insert(sorted, { id = flag_id, name = name })
    end
    table.sort(sorted, function(a, b) return a.id < b.id end)

    for _, item in ipairs(sorted) do
        M.log(string.format("  %d: %s", item.id, item.name))
    end

    M.log(string.format("Total: %d names", #sorted))
    return sorted
end

function M.save_names()
    local data = {
        version = 1,
        last_updated = os.time(),
        names = flag_names_cache,
    }

    Shared.save_json(FLAG_NAMES_FILE, data, 2, M.log)
    M.log(string.format("Saved %d flag names", 0))
end

function M.load_names()
    local data = Shared.load_json(FLAG_NAMES_FILE)
    if data and data.names then
        local count = 0
        for flag_id_str, name in pairs(data.names) do
            local flag_id = tonumber(flag_id_str)
            if flag_id and not flag_names_cache[flag_id] then
                flag_names_cache[flag_id] = name
                count = count + 1
            end
        end
        M.log(string.format("Loaded %d flag names from file", count))
    end
end

------------------------------------------------------------
-- EventFlagsManager Method Discovery
------------------------------------------------------------

local function discover_efm_methods()
    if methods_discovered then return end

    local efm = efm_mgr:get()
    if not efm then return end

    local td = efm:get_type_definition()
    if not td then return end

    local methods = td:get_methods()
    if not methods then return end

    M.log("=== EventFlagsManager Methods ===")
    for i, method in ipairs(methods) do
        if method then
            local ok, name = pcall(method.get_name, method)
            if ok and name then
                efm_methods[name] = method

                if name:lower():find("flag") or name:lower():find("ev") or name:lower():find("event") then
                    local param_count = 0
                    pcall(function() param_count = method:get_num_params() end)
                    M.log(string.format("  %s (params: %d)", name, param_count))
                end
            end
        end
    end
    M.log("=== End Methods ===")

    methods_discovered = true
end

------------------------------------------------------------
-- Flag Operations
------------------------------------------------------------

function M.check_flag(flag_id)
    local efm = efm_mgr:get()
    if not efm then return nil end

    local ok, result = pcall(function()
        return efm:call("evFlagCheck", flag_id)
    end)

    if ok then
        return result == true
    end
    return nil
end

function M.set_flag_on(flag_id)
    local efm = efm_mgr:get()
    if not efm then
        M.log("ERROR: EventFlagsManager not available")
        return false
    end

    local ok, err = pcall(function()
        efm:call("evFlagOn", flag_id)
    end)

    if ok then
        M.log(string.format("Flag %d set ON via evFlagOn", flag_id))
        return true
    end

    -- Try alternate
    ok, err = pcall(function()
        efm:call("flagOn", flag_id)
    end)

    if ok then
        M.log(string.format("Flag %d set ON via flagOn", flag_id))
        return true
    end

    M.log(string.format("Could not set flag %d ON: %s", flag_id, tostring(err)))
    return false
end

function M.set_flag_off(flag_id)
    local efm = efm_mgr:get()
    if not efm then
        M.log("ERROR: EventFlagsManager not available")
        return false
    end

    local ok, err = pcall(function()
        efm:call("evFlagOff", flag_id)
    end)

    if ok then
        M.log(string.format("Flag %d set OFF via evFlagOff", flag_id))
        return true
    end

    M.log(string.format("Could not set flag %d OFF: %s", flag_id, tostring(err)))
    return false
end

------------------------------------------------------------
-- Get Flag Name Helper
------------------------------------------------------------

function M.get_flag_name(flag_id)
    -- Check cache first
    if flag_names_cache[flag_id] then
        return flag_names_cache[flag_id]
    end

    -- Try getEventNameDefine
    local name = try_get_event_name_define(flag_id)
    if name and name ~= "" then
        flag_names_cache[flag_id] = name
        return name
    end

    -- Check known flags
    if KNOWN_FLAGS[flag_id] then
        return KNOWN_FLAGS[flag_id].name
    end

    return nil
end

------------------------------------------------------------
-- Scanning
------------------------------------------------------------

function M.scan_range(start_id, end_id)
    local set_flags = {}

    for flag_id = start_id, end_id do
        local is_set = M.check_flag(flag_id)
        if is_set == true then
            table.insert(set_flags, flag_id)
        end
    end

    return set_flags
end

function M.scan_and_log(start_id, end_id)
    M.log(string.format("Scanning flags %d to %d...", start_id, end_id))

    local set_flags = M.scan_range(start_id, end_id)

    M.log(string.format("Found %d set flags:", #set_flags))
    for _, flag_id in ipairs(set_flags) do
        local name = M.get_flag_name(flag_id) or "?"
        M.log(string.format("  Flag %d: %s", flag_id, name))
    end

    return set_flags
end

--- Scan and extract names for all set flags
function M.scan_with_names(start_id, end_id)
    M.log(string.format("Scanning flags %d to %d with name extraction...", start_id, end_id))

    local results = {}

    for flag_id = start_id, end_id do
        local is_set = M.check_flag(flag_id)
        if is_set == true then
            local name = M.get_flag_name(flag_id)
            table.insert(results, {
                flag_id = flag_id,
                name = name or "Unknown",
                is_set = true,
            })
        end
    end

    M.log(string.format("Found %d set flags:", #results))
    for _, item in ipairs(results) do
        M.log(string.format("  %d: %s", item.flag_id, item.name))
    end

    return results
end

------------------------------------------------------------
-- Monitoring
------------------------------------------------------------

function M.take_snapshot(start_id, end_id)
    start_id = start_id or monitor_range_start
    end_id = end_id or monitor_range_end

    local count = 0
    for flag_id = start_id, end_id do
        local is_set = M.check_flag(flag_id)
        if is_set ~= nil then
            flag_snapshot[flag_id] = is_set
            count = count + 1
        end
    end

    M.log(string.format("Snapshot taken: %d flags in range %d-%d", count, start_id, end_id))
end

function M.detect_changes()
    local changes = {}

    for flag_id, old_val in pairs(flag_snapshot) do
        local new_val = M.check_flag(flag_id)
        if new_val ~= nil and new_val ~= old_val then
            table.insert(changes, {
                flag_id = flag_id,
                old_val = old_val,
                new_val = new_val,
                timestamp = os.clock(),
                name = M.get_flag_name(flag_id),
            })
            flag_snapshot[flag_id] = new_val
        end
    end

    return changes
end

local function process_changes()
    local changes = M.detect_changes()

    for _, change in ipairs(changes) do
        local action = change.new_val and "SET" or "CLEARED"
        local name = change.name or "Unknown"

        M.log(string.format("FLAG %s: %d (%s)", action, change.flag_id, name))

        table.insert(recent_changes, 1, change)
        while #recent_changes > MAX_RECENT_CHANGES do
            table.remove(recent_changes)
        end

        if not discovered_flags[change.flag_id] then
            discovered_flags[change.flag_id] = {
                first_seen = os.time(),
                action = action,
                name = name,
            }
        end
    end

    return changes
end

------------------------------------------------------------
-- Persistence
------------------------------------------------------------

function M.save_discovered()
    local data = {
        version = 1,
        last_updated = os.time(),
        flags = discovered_flags,
        known = KNOWN_FLAGS,
    }

    Shared.save_json(DISCOVERED_FLAGS_FILE, data, 2, M.log)
    M.save_names()
    M.log("Saved discovered flags and names")
end

function M.load_discovered()
    local data = Shared.load_json(DISCOVERED_FLAGS_FILE)
    if data then
        if data.flags then
            discovered_flags = data.flags
        end
        if data.known then
            for k, v in pairs(data.known) do
                KNOWN_FLAGS[tonumber(k) or k] = v
            end
        end
    end
    M.load_names()
end

re.on_script_reset(function() M.save_discovered() end)
re.on_config_save(function() M.save_discovered() end)

------------------------------------------------------------
-- GUI
------------------------------------------------------------

local function draw_monitor_tab()
    imgui.text("Flag Monitoring")
    imgui.separator()

    local mon_changed, mon_enabled = imgui.checkbox("Enable Monitoring", monitoring_enabled)
    if mon_changed then
        monitoring_enabled = mon_enabled
        if mon_enabled then
            M.take_snapshot()
        end
    end

    imgui.same_line()
    if imgui.button("Take Snapshot") then
        M.take_snapshot()
    end

    imgui.text("Monitor Range:")
    imgui.push_item_width(100)
    local changed_s, new_s = imgui.input_text("Start##range", tostring(monitor_range_start))
    if changed_s then monitor_range_start = tonumber(new_s) or 1 end
    imgui.same_line()
    local changed_e, new_e = imgui.input_text("End##range", tostring(monitor_range_end))
    if changed_e then monitor_range_end = tonumber(new_e) or 5000 end
    imgui.pop_item_width()

    imgui.separator()
    imgui.text("Recent Flag Changes:")

    imgui.begin_child_window("ChangesList", Vector2f.new(0, 200), true, 0)

    if #recent_changes == 0 then
        imgui.text_colored("No changes detected yet.", 0xFF888888)
        imgui.text("Enable monitoring and play the game.")
    else
        for i, change in ipairs(recent_changes) do
            local action = change.new_val and "SET" or "CLEARED"
            local color = change.new_val and 0xFF00FF00 or 0xFFFF8800
            local name = change.name or ""

            local text = string.format("[%d] Flag %d %s", i, change.flag_id, action)
            if name ~= "" then
                text = text .. " - " .. name
            end

            imgui.text_colored(text, color)
        end
    end

    imgui.end_child_window()
end

local function draw_scan_tab()
    imgui.text("Flag Scanner")
    imgui.separator()

    imgui.text("Quick Scan Ranges:")
    for _, range in ipairs(FLAG_RANGES) do
        if imgui.button(range.name .. "##scan") then
            scan_results = M.scan_with_names(range.start, range.stop)
        end
        imgui.same_line()
    end
    imgui.new_line()

    imgui.separator()

    imgui.text(string.format("Scan Results: %d flags set", #scan_results))

    imgui.begin_child_window("ScanResults", Vector2f.new(0, 250), true, 0)

    for _, item in ipairs(scan_results) do
        local text = string.format("Flag %d: %s", item.flag_id, item.name)
        imgui.text(text)
    end

    imgui.end_child_window()
end

local function draw_manual_tab()
    imgui.text("Manual Flag Control")
    imgui.separator()

    imgui.text("Flag ID:")
    imgui.same_line()
    imgui.push_item_width(100)
    local changed, new_val = imgui.input_text("##flagid", manual_flag_input)
    if changed then manual_flag_input = new_val end
    imgui.pop_item_width()

    local flag_id = tonumber(manual_flag_input)

    if flag_id then
        local is_set = M.check_flag(flag_id)
        local state_str = is_set == true and "SET" or (is_set == false and "NOT SET" or "UNKNOWN")
        local state_color = is_set == true and 0xFF00FF00 or 0xFFFF8800

        imgui.same_line()
        imgui.text_colored("Current: " .. state_str, state_color)

        -- Show name if known
        local name = M.get_flag_name(flag_id)
        if name then
            imgui.text("Name: " .. name)
        end

        if imgui.button("Set ON") then
            M.set_flag_on(flag_id)
        end
        imgui.same_line()
        if imgui.button("Set OFF") then
            M.set_flag_off(flag_id)
        end
        imgui.same_line()
        if imgui.button("Toggle") then
            if is_set then
                M.set_flag_off(flag_id)
            else
                M.set_flag_on(flag_id)
            end
        end
    else
        imgui.text_colored("Enter a valid flag ID", 0xFFFF0000)
    end

    imgui.separator()
    imgui.text("Bulk Operations:")

    if imgui.button("Discover Methods") then
        discover_efm_methods()
    end

    imgui.same_line()
    if imgui.button("Explore EventFlag Type") then
        explore_event_flag_type()
    end

    imgui.same_line()
    if imgui.button("Extract Enum Names") then
        M.extract_enum_names()
    end

    if imgui.button("Save All") then
        M.save_discovered()
    end

    imgui.same_line()
    if imgui.button("Load All") then
        M.load_discovered()
    end

    imgui.same_line()
    if imgui.button("Dump Names") then
        M.dump_all_names()
    end
end

local function draw_names_tab()
    imgui.text("Flag Names Database")
    imgui.separator()

    local count = 0
    for _ in pairs(flag_names_cache) do count = count + 1 end

    imgui.text(string.format("Total known names: %d", count))

    if imgui.button("Extract from Enum") then
        M.extract_enum_names()
    end
    imgui.same_line()
    if imgui.button("Extract Range 1-1000") then
        M.extract_names(1, 1000)
    end
    imgui.same_line()
    if imgui.button("Save Names") then
        M.save_names()
    end

    imgui.separator()

    imgui.begin_child_window("NamesList", Vector2f.new(0, 0), true, 0)

    local sorted = {}
    for flag_id, name in pairs(flag_names_cache) do
        table.insert(sorted, { id = flag_id, name = name })
    end
    table.sort(sorted, function(a, b) return a.id < b.id end)

    for _, item in ipairs(sorted) do
        local is_set = M.check_flag(item.id)
        local color = is_set and 0xFF00FF00 or 0xFFFFFFFF
        imgui.text_colored(string.format("%d: %s", item.id, item.name), color)
    end

    imgui.end_child_window()
end

local function draw_main_window()
    if not gui_visible then return end

    imgui.set_next_window_size(Vector2f.new(550, 450), 4)

    local still_open = imgui.begin_window("Event Flag Explorer v2", true, 0)
    if not still_open then
        gui_visible = false
        imgui.end_window()
        return
    end

    local efm = efm_mgr:get()
    local status_color = efm and 0xFF00FF00 or 0xFFFF0000
    local status_text = efm and "EventFlagsManager: OK" or "EventFlagsManager: NOT AVAILABLE"
    imgui.text_colored(status_text, status_color)

    if monitoring_enabled then
        imgui.same_line()
        imgui.text_colored(" [MONITORING]", 0xFF00FFFF)
    end

    local name_count = 0
    for _ in pairs(flag_names_cache) do name_count = name_count + 1 end
    imgui.same_line()
    imgui.text(string.format(" | Names: %d", name_count))

    imgui.separator()

    if imgui.button("Monitor") then current_tab = 0 end
    imgui.same_line()
    if imgui.button("Scan") then current_tab = 1 end
    imgui.same_line()
    if imgui.button("Manual") then current_tab = 2 end
    imgui.same_line()
    if imgui.button("Names") then current_tab = 3 end

    imgui.separator()

    if current_tab == 0 then
        draw_monitor_tab()
    elseif current_tab == 1 then
        draw_scan_tab()
    elseif current_tab == 2 then
        draw_manual_tab()
    elseif current_tab == 3 then
        draw_names_tab()
    end

    imgui.end_window()
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

function M.show_window()
    gui_visible = true
end

function M.hide_window()
    gui_visible = false
end

function M.toggle_window()
    gui_visible = not gui_visible
end

function M.is_monitoring()
    return monitoring_enabled
end

function M.start_monitoring(start_id, end_id)
    monitor_range_start = start_id or monitor_range_start
    monitor_range_end = end_id or monitor_range_end
    M.take_snapshot()
    monitoring_enabled = true
    M.log(string.format("Started monitoring flags %d-%d", monitor_range_start, monitor_range_end))
end

function M.stop_monitoring()
    monitoring_enabled = false
    M.log("Stopped monitoring")
end

function M.get_recent_changes()
    return recent_changes
end

function M.get_discovered_flags()
    return discovered_flags
end

function M.get_all_names()
    return flag_names_cache
end

function M.register_known_flag(flag_id, name, category)
    KNOWN_FLAGS[flag_id] = {
        name = name,
        category = category,
    }
    flag_names_cache[flag_id] = name
end

------------------------------------------------------------
-- REFramework Hooks
------------------------------------------------------------

re.on_frame(function()
    if gui_visible then
        draw_main_window()
    end
end)

re.on_draw_ui(function()
    local changed, new_val = imgui.checkbox("Show Event Flag Explorer", gui_visible)
    if changed then
        gui_visible = new_val
    end
end)

------------------------------------------------------------
-- Per-frame Update
------------------------------------------------------------

function M.on_frame()
    if not M:should_run() then return end

    if not methods_discovered then
        discover_efm_methods()
    end

    if monitoring_enabled then
        process_changes()
    end
end

------------------------------------------------------------
-- Console Helpers
------------------------------------------------------------

_G.eflag_check = function(id)
    local result = M.check_flag(id)
    local name = M.get_flag_name(id)
    print(string.format("Flag %d (%s): %s", id, name or "?", tostring(result)))
    return result
end

_G.eflag_on = function(id) return M.set_flag_on(id) end
_G.eflag_off = function(id) return M.set_flag_off(id) end

_G.eflag_scan = function(s, e)
    local results = M.scan_with_names(s or 1, e or 1000)
    return results
end

_G.eflag_monitor = function(s, e)
    M.start_monitoring(s, e)
end

_G.eflag_stop = function()
    M.stop_monitoring()
end

_G.eflag_gui = function()
    M.show_window()
end

_G.eflag_name = function(id)
    local name = M.get_flag_name(id)
    print(string.format("Flag %d: %s", id, name or "NOT FOUND"))
    return name
end

_G.eflag_explore = function()
    explore_event_flag_type()
end

_G.eflag_extract = function(s, e)
    return M.extract_names(s or 1, e or 1000)
end

_G.eflag_dump = function()
    return M.dump_all_names()
end

------------------------------------------------------------
-- Module Load
------------------------------------------------------------

M.load_discovered()
M.log("EventFlagExplorer v2 loaded")
M.log("Commands: eflag_check(id), eflag_on(id), eflag_off(id), eflag_scan(s,e)")
M.log("          eflag_name(id), eflag_explore(), eflag_extract(s,e), eflag_dump()")
M.log("          eflag_gui()")

-- Auto-explore on load
explore_event_flag_type()

return M