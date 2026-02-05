-- DRAP/Shared.lua
-- Shared utilities for Dead Rising Archipelago mod
-- Consolidates common patterns used across all modules

local Shared = {}

------------------------------------------------------------
-- Logging Factory
------------------------------------------------------------

--- Sanitizes a string for safe logging (removes binary garbage)
--- @param s any The value to sanitize for logging
--- @return string The sanitized string
function Shared.safe_log_string(s)
    if s == nil then return "nil" end
    local str = tostring(s)
    -- Remove null characters and everything after them
    local null_pos = str:find("%z")
    if null_pos then
        str = str:sub(1, null_pos - 1)
    end
    -- Remove non-printable characters (keep newlines and tabs)
    str = str:gsub("[%c%z]", function(c)
        if c == "\n" or c == "\t" then return c end
        return ""
    end)
    -- Remove high-byte characters (non-ASCII garbage)
    str = str:gsub("[\128-\255]", "")
    return str
end

--- Builds a completely fresh, clean string character by character
--- @param str string The input string
--- @return string A fresh string with only printable ASCII
local function build_clean_string(str)
    local clean = {}
    for i = 1, #str do
        local b = string.byte(str, i)
        -- Only include printable ASCII (32-126), newline, tab
        if (b >= 32 and b <= 126) or b == 10 or b == 9 then
            clean[#clean + 1] = string.char(b)
        end
    end
    return table.concat(clean)
end

--- Creates a logger function with a prefix tag
--- @param tag string The module name to prefix log messages with
--- @return function A log function that prefixes messages with [tag]
function Shared.create_logger(tag)
    local prefix = "[" .. tag .. "] "
    return function(msg)
        local clean_msg = Shared.safe_log_string(msg)
        -- Skip empty messages
        if clean_msg == "" or clean_msg == "nil" then return end
        local str = prefix .. clean_msg
        print(build_clean_string(str))
    end
end

--- Safe string.format that cleans all string arguments first
--- @param fmt string The format string
--- @param ... any The arguments
--- @return string The formatted string
function Shared.safe_format(fmt, ...)
    local args = {...}
    for i, arg in ipairs(args) do
        if type(arg) == "string" then
            args[i] = Shared.clean_string(arg)
        end
    end
    return string.format(fmt, table.unpack(args))
end

------------------------------------------------------------
-- Safe Value Conversion
------------------------------------------------------------

--- Safely converts a managed value to integer
--- @param val any The value to convert (number, managed int64, etc.)
--- @return number|nil The integer value or nil if conversion fails
function Shared.to_int(val)
    if val == nil then return nil end
    if type(val) == "number" then return math.floor(val) end

    local ok_i64, i64 = pcall(sdk.to_int64, val)
    if not ok_i64 or i64 == nil then return nil end

    if type(i64) == "number" then return math.floor(i64) end

    local ok_g, raw = pcall(i64.get_int64, i64)
    if not ok_g or raw == nil then return nil end

    return math.floor(raw)
end

--- Cleans a string by removing null characters, control characters, and binary garbage
--- @param input any The value to clean
--- @return string The cleaned string
function Shared.clean_string(input)
    if input == nil then return "" end

    local str
    if type(input) == "string" then
        str = input
    else
        -- Try to convert managed string properly
        local mo = sdk.to_managed_object(input)
        if mo ~= nil then
            local ok, s = pcall(sdk.to_string, mo)
            if ok and type(s) == "string" then
                str = s
            end
        end
        if not str then
            str = tostring(input)
        end
    end

    -- Truncate at first null character
    local null_pos = str:find("%z")
    if null_pos then
        str = str:sub(1, null_pos - 1)
    end

    -- Remove any remaining control characters and high-byte garbage
    str = str:gsub("[%z%c]", "")
    str = str:gsub("[\128-\255]", "")

    return str
end

--- Sanitizes a string for use as a filename/token
--- @param s any The value to sanitize
--- @return string The sanitized string
function Shared.sanitize_token(s)
    s = Shared.clean_string(s)
    s = s:gsub("[%c\128-\255]", "")
    s = s:gsub("[^%w%-%_%.]", "_")
    s = s:gsub("_+", "_"):gsub("^_+", ""):gsub("_+$", "")
    return s
end

------------------------------------------------------------
-- Managed Collection Helpers
------------------------------------------------------------

--- Gets the count/length of a managed collection
--- @param container any The managed collection
--- @return number The count, or 0 if unavailable
function Shared.get_collection_count(container)
    if container == nil then return 0 end

    -- Try get_Count (List<T>)
    local ok, count = pcall(sdk.call_object_func, container, "get_Count")
    if ok and count ~= nil then
        return Shared.to_int(count) or 0
    end

    -- Try get_Length (arrays)
    ok, count = pcall(sdk.call_object_func, container, "get_Length")
    if ok and count ~= nil then
        return Shared.to_int(count) or 0
    end

    -- Try get_size
    ok, count = pcall(sdk.call_object_func, container, "get_size")
    if ok and count ~= nil then
        return Shared.to_int(count) or 0
    end

    return 0
end

--- Gets an item from a managed collection by index
--- @param container any The managed collection
--- @param index number The zero-based index
--- @return any The item, or nil if unavailable
function Shared.get_collection_item(container, index)
    if container == nil or index == nil then return nil end

    -- Try get_Item (List<T>)
    local ok, item = pcall(sdk.call_object_func, container, "get_Item", index)
    if ok then return item end

    -- Try get_element (native arrays)
    ok, item = pcall(function() return container:get_element(index) end)
    if ok then return item end

    return nil
end

--- Iterates over a managed collection
--- @param container any The managed collection
--- @return function Iterator that yields (index, item) pairs
function Shared.iter_collection(container)
    local count = Shared.get_collection_count(container)
    local i = -1
    return function()
        i = i + 1
        if i < count then
            return i, Shared.get_collection_item(container, i)
        end
    end
end

------------------------------------------------------------
-- Field Access Helpers
------------------------------------------------------------

--- Gets a field value from an object, trying multiple field name variants
--- @param obj any The managed object
--- @param variants table Array of field names to try
--- @return any|nil The field value, or nil if not found
--- @return any|nil The field object, or nil if not found
function Shared.get_field_value(obj, variants)
    if obj == nil then return nil, nil end

    local td = obj:get_type_definition()
    if not td then return nil, nil end

    for _, name in ipairs(variants) do
        local f = td:get_field(name)
        if f ~= nil then
            local ok, v = pcall(f.get_data, f, obj)
            if ok then
                return v, f
            end
        end
    end

    return nil, nil
end

--- Safely reads a field from an object
--- @param obj any The managed object
--- @param field any The field object
--- @return any|nil The field value, or nil on error
function Shared.safe_get_field(obj, field)
    if not obj or not field then return nil end
    local ok, val = pcall(field.get_data, field, obj)
    if ok then return val end
    return nil
end

--- Safely sets a field on an object
--- @param obj any The managed object
--- @param field_name string The field name
--- @param value any The value to set
--- @return boolean True if successful
function Shared.safe_set_field(obj, field_name, value)
    if not obj then return false end
    local ok, err = pcall(obj.set_field, obj, field_name, value)
    return ok
end

--- Gets all fields from a type definition as a plain Lua array
--- @param td any The type definition
--- @return table Array of field objects
function Shared.get_fields_array(td)
    if not td then return {} end

    local raw = td:get_fields()
    if not raw then return {} end

    local fields = {}

    -- Try List-style access
    local get_count = raw.get_Count or raw.get_size
    if get_count and raw.get_Item then
        local count = get_count(raw)
        for i = 0, count - 1 do
            fields[#fields + 1] = raw:get_Item(i)
        end
        return fields
    end

    -- Try array-style access
    local i = 1
    while raw[i] ~= nil do
        fields[#fields + 1] = raw[i]
        i = i + 1
    end

    return fields
end

------------------------------------------------------------
-- Singleton Manager
------------------------------------------------------------

--- Creates a singleton manager with automatic change detection and caching
--- @param type_name string The full type name of the singleton
--- @param logger function|nil Optional logger function
--- @return table Singleton manager object
function Shared.create_singleton_manager(type_name, logger)
    local log = logger or function() end
    local short_name = type_name:match("%.([^%.]+)$") or type_name

    local mgr = {
        type_name = type_name,
        instance = nil,
        type_def = nil,
        fields = {},
        methods = {},
        missing_warned = {},
        on_instance_changed = nil,  -- callback(old_instance, new_instance)
    }

    --- Updates the singleton reference, detecting changes
    --- @return any|nil The current singleton instance
    function mgr:update()
        local current = sdk.get_managed_singleton(self.type_name)

        if current ~= self.instance then
            local old = self.instance

            if old ~= nil and current == nil then
                log(short_name .. " destroyed (likely title screen).")
            elseif old == nil and current ~= nil then
                log(short_name .. " created (likely entering game).")
            elseif old ~= nil and current ~= nil then
                log(short_name .. " instance changed.")
            end

            self.instance = current
            self.type_def = nil
            self.fields = {}
            self.methods = {}
            self.missing_warned = {}

            if self.on_instance_changed then
                pcall(self.on_instance_changed, old, current)
            end
        end

        return self.instance
    end

    --- Gets the singleton instance (calls update internally)
    --- @return any|nil The current singleton instance
    function mgr:get()
        return self:update()
    end

    --- Gets the type definition, caching it
    --- @return any|nil The type definition
    function mgr:get_type_def()
        if self.type_def then return self.type_def end
        if not self.instance then return nil end

        local ok, td = pcall(self.instance.get_type_definition, self.instance)
        if ok and td then
            self.type_def = td
        end
        return self.type_def
    end

    --- Gets a field, caching it
    --- @param field_name string The field name
    --- @param warn_once boolean|nil Whether to warn once if missing (default true)
    --- @return any|nil The field object
    function mgr:get_field(field_name, warn_once)
        if self.fields[field_name] then
            return self.fields[field_name]
        end

        local td = self:get_type_def()
        if not td then return nil end

        local f = td:get_field(field_name)
        if f then
            self.fields[field_name] = f
            return f
        end

        if warn_once ~= false and not self.missing_warned[field_name] then
            log("Field '" .. field_name .. "' not found on " .. short_name)
            self.missing_warned[field_name] = true
        end

        return nil
    end

    --- Gets a method, caching it
    --- @param method_name string The method name
    --- @param warn_once boolean|nil Whether to warn once if missing (default true)
    --- @return any|nil The method object
    function mgr:get_method(method_name, warn_once)
        if self.methods[method_name] then
            return self.methods[method_name]
        end

        local td = self:get_type_def()
        if not td then return nil end

        local m = td:get_method(method_name)
        if m then
            self.methods[method_name] = m
            return m
        end

        if warn_once ~= false and not self.missing_warned[method_name] then
            log("Method '" .. method_name .. "' not found on " .. short_name)
            self.missing_warned[method_name] = true
        end

        return nil
    end

    --- Reads a field value from the singleton
    --- @param field_name string The field name
    --- @return any|nil The field value
    function mgr:read_field(field_name)
        if not self.instance then return nil end
        local f = self:get_field(field_name)
        if not f then return nil end

        local ok, val = pcall(f.get_data, f, self.instance)
        if ok then return val end
        return nil
    end

    --- Calls a method on the singleton
    --- @param method_name string The method name
    --- @param ... any Arguments to pass
    --- @return boolean Success
    --- @return any Return value or error
    function mgr:call_method(method_name, ...)
        if not self.instance then return false, "No instance" end
        local m = self:get_method(method_name)
        if not m then return false, "Method not found" end

        return pcall(m.call, m, self.instance, ...)
    end

    return mgr
end

------------------------------------------------------------
-- Frame Throttling
------------------------------------------------------------

--- Creates a frame throttle that limits how often a function runs
--- @param interval number Minimum seconds between executions
--- @return function A function that returns true if enough time has passed
function Shared.create_throttle(interval)
    local last_time = 0
    return function()
        local now = os.clock()
        if now - last_time >= interval then
            last_time = now
            return true
        end
        return false
    end
end

--- Creates a frame-count based throttle
--- @param frame_interval number Number of frames between executions
--- @return function A function that returns true every N frames
function Shared.create_frame_throttle(frame_interval)
    local counter = 0
    return function()
        counter = counter + 1
        if counter >= frame_interval then
            counter = 0
            return true
        end
        return false
    end
end

------------------------------------------------------------
-- State Tracking
------------------------------------------------------------

--- Creates a state tracker that detects value changes
--- @param on_change function|nil Callback(old_value, new_value) when value changes
--- @return table State tracker object
function Shared.create_state_tracker(on_change)
    local tracker = {
        value = nil,
        initialized = false,
        on_change = on_change,
    }

    --- Updates the tracked value
    --- @param new_value any The new value
    --- @return boolean True if the value changed
    function tracker:update(new_value)
        if not self.initialized then
            self.value = new_value
            self.initialized = true
            return false
        end

        if new_value ~= self.value then
            local old = self.value
            self.value = new_value

            if self.on_change then
                pcall(self.on_change, old, new_value)
            end

            return true
        end

        return false
    end

    --- Resets the tracker to uninitialized state
    function tracker:reset()
        self.value = nil
        self.initialized = false
    end

    return tracker
end

--- Creates a threshold tracker for numeric values
--- @param thresholds table Array of threshold values
--- @param on_threshold function|nil Callback(index, threshold, prev, current) when crossed
--- @return table Threshold tracker object
function Shared.create_threshold_tracker(thresholds, on_threshold)
    local tracker = {
        thresholds = thresholds,
        reached = {},
        last_value = nil,
        on_threshold = on_threshold,
    }

    -- Initialize reached flags
    for i = 1, #thresholds do
        tracker.reached[i] = false
    end

    --- Updates with a new value, firing callbacks for any newly crossed thresholds
    --- @param current number The current value
    function tracker:update(current)
        if type(current) ~= "number" then return end

        -- First read: check all thresholds already met
        if self.last_value == nil then
            self.last_value = current
            for i, threshold in ipairs(self.thresholds) do
                if current >= threshold and not self.reached[i] then
                    self.reached[i] = true
                    if self.on_threshold then
                        pcall(self.on_threshold, i, threshold, current, current)
                    end
                end
            end
            return
        end

        local prev = self.last_value
        if current == prev then return end

        -- Only care about increases
        if current > prev then
            for i, threshold in ipairs(self.thresholds) do
                if not self.reached[i] and current >= threshold and prev < threshold then
                    self.reached[i] = true
                    if self.on_threshold then
                        pcall(self.on_threshold, i, threshold, prev, current)
                    end
                end
            end
        end

        self.last_value = current
    end

    --- Resets all tracking state
    function tracker:reset()
        self.last_value = nil
        for i = 1, #self.thresholds do
            self.reached[i] = false
        end
    end

    return tracker
end

------------------------------------------------------------
-- JSON Helpers
------------------------------------------------------------

--- Safely loads a JSON file
--- @param path string The file path
--- @param logger function|nil Optional logger for errors
--- @return table|nil The parsed data, or nil on error
function Shared.load_json(path, logger)
    local data = json.load_file(path)
    if not data and logger then
        logger("Failed to load JSON: " .. path)
    end
    return data
end

--- Safely saves a JSON file
--- @param path string The file path
--- @param data table The data to save
--- @param indent number|nil Indentation level (default 4)
--- @param logger function|nil Optional logger for errors
--- @return boolean True if successful
function Shared.save_json(path, data, indent, logger)
    local ok = json.dump_file(path, data, indent or 4)
    if not ok and logger then
        logger("Failed to save JSON: " .. path)
    end
    return ok
end

------------------------------------------------------------
-- Module Pattern Helper
------------------------------------------------------------

--- Creates a standard module structure with common patterns
--- @param name string The module name (for logging)
--- @return table Module with standard structure
function Shared.create_module(name)
    local log = Shared.create_logger(name)

    local mod = {
        name = name,
        log = log,
        singletons = {},
        throttle = nil,
        initialized = false,
    }

    --- Adds a singleton manager to this module
    --- @param key string A short key to reference the singleton
    --- @param type_name string The full type name
    --- @return table The singleton manager
    function mod:add_singleton(key, type_name)
        local mgr = Shared.create_singleton_manager(type_name, self.log)
        self.singletons[key] = mgr
        return mgr
    end

    --- Gets a singleton manager by key
    --- @param key string The key
    --- @return table|nil The singleton manager
    function mod:get_singleton(key)
        return self.singletons[key]
    end

    --- Sets up frame throttling for this module
    --- @param interval number Seconds between updates
    function mod:set_throttle(interval)
        self.throttle = Shared.create_throttle(interval)
    end

    --- Checks if the module should run this frame (respects throttle)
    --- @return boolean True if should run
    function mod:should_run()
        if self.throttle then
            return self.throttle()
        end
        return true
    end

    log("Module created.")
    return mod
end

------------------------------------------------------------
-- Scene/Game State Helpers
------------------------------------------------------------

--- Checks if we're currently in gameplay (not title screen/loading)
--- Uses PlayerStatusManager.PlayerLevel as indicator
--- @return boolean True if in game
function Shared.is_in_game()
    local ps = sdk.get_managed_singleton("app.solid.PlayerStatusManager")
    if not ps then return false end

    local td = ps:get_type_definition()
    if not td then return false end

    local f = td:get_field("PlayerLevel")
    if not f then return false end

    local ok, lvl = pcall(f.get_data, f, ps)
    if not ok or lvl == nil then return false end

    return true
end

return Shared