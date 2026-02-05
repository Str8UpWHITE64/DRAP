-- DRAP/GameEventTracker.lua
-- Production tracker for game events using EventFlagsManager
-- Maps known flag IDs to AP location checks
--
-- Usage: Once EventFlagExplorer discovers a flag, add it to EVENT_DEFINITIONS below
-- Then when that flag becomes set, it will send the AP location check

local Shared = require("DRAP/Shared")

local M = Shared.create_module("GameEventTracker")
M:set_throttle(0.5)

------------------------------------------------------------
-- Configuration
------------------------------------------------------------

-- Event definitions file (can be extended via JSON)
local EVENTS_JSON_FILE = "AP_DRDR_game_events.json"
local PROGRESS_JSON_DIR = "AP_DRDR_Progress"
local PROGRESS_JSON_FILE = nil  -- Set via set_save_filename()

------------------------------------------------------------
-- Event Definitions
--
-- Add flag mappings here as you discover them with EventFlagExplorer
-- Format: { flag_id = number, location_name = string, category = string }
------------------------------------------------------------

local EVENT_DEFINITIONS = {
    -- =====================================================
    -- MAIN STORY SCOOPS
    -- =====================================================
    -- TODO: Discover these with EventFlagExplorer
    -- Example format:
    -- { flag_id = 1234, location_name = "Meet Jessie in the Service Hallway", category = "story" },
    -- { flag_id = 1235, location_name = "Complete Backup for Brad", category = "story" },

    -- =====================================================
    -- PSYCHOPATH EVENTS
    -- =====================================================
    -- { flag_id = 2001, location_name = "Meet Adam", category = "psycho" },
    -- { flag_id = 2002, location_name = "Kill Adam", category = "psycho" },
    -- { flag_id = 2003, location_name = "Meet Cletus", category = "psycho" },
    -- { flag_id = 2004, location_name = "Kill Cletus", category = "psycho" },

    -- =====================================================
    -- OVERTIME EVENTS
    -- =====================================================
    -- { flag_id = 3001, location_name = "Get bit!", category = "overtime" },
    -- { flag_id = 3002, location_name = "See the crashed helicopter", category = "overtime" },

    -- =====================================================
    -- MISC EVENTS
    -- =====================================================
    -- { flag_id = 4001, location_name = "Watch the convicts kill that poor guy", category = "misc" },
}

------------------------------------------------------------
-- Singleton Managers
------------------------------------------------------------

local efm_mgr = M:add_singleton("efm", "app.solid.gamemastering.EventFlagsManager")

------------------------------------------------------------
-- Internal State
------------------------------------------------------------

-- Indexed lookup tables (built from EVENT_DEFINITIONS)
local EVENTS_BY_FLAG = {}      -- { [flag_id] = event_def }
local EVENTS_BY_NAME = {}      -- { [location_name] = event_def }

-- Tracked state
local COMPLETED_EVENTS = {}    -- { [flag_id] = true }
local SENT_CHECKS = {}         -- { [location_name] = true }  -- What we've sent to AP

-- State flags
local definitions_loaded = false
local save_loaded = false
local initialized = false
local save_dirty = false

------------------------------------------------------------
-- Public Callbacks
------------------------------------------------------------

--- Called when a game event is detected as complete
--- @param location_name string The AP location name
--- @param flag_id number The event flag ID
--- @param category string The event category
M.on_event_complete = nil

------------------------------------------------------------
-- Save File Management
------------------------------------------------------------

function M.set_save_filename(slot_name, seed)
    local function safe_fn(s)
        if not s then return "unknown" end
        return tostring(s):gsub("[^%w%-_]", "_"):sub(1, 32)
    end

    local slot = safe_fn(slot_name)
    local sd = safe_fn(seed)
    PROGRESS_JSON_FILE = string.format("./%s/AP_DRDR_events_%s_%s.json",
        PROGRESS_JSON_DIR, slot, sd)
    M.log(string.format("Event progress file: %s", PROGRESS_JSON_FILE))
end

local function get_save_path()
    return PROGRESS_JSON_FILE or (PROGRESS_JSON_DIR .. "/AP_DRDR_events_default.json")
end

local function save_progress()
    if not save_dirty then return end

    local data = {
        version = 1,
        last_updated = os.time(),
        completed = {},
        sent_checks = {},
    }

    for flag_id, _ in pairs(COMPLETED_EVENTS) do
        data.completed[tostring(flag_id)] = true
    end

    for loc_name, _ in pairs(SENT_CHECKS) do
        data.sent_checks[loc_name] = true
    end

    local ok = Shared.save_json(get_save_path(), data, 2, M.log)
    if ok then
        save_dirty = false
    end
end

local function load_progress()
    if save_loaded then return end

    local data = Shared.load_json(get_save_path())
    if data then
        if data.completed then
            for flag_id_str, _ in pairs(data.completed) do
                local flag_id = tonumber(flag_id_str)
                if flag_id then
                    COMPLETED_EVENTS[flag_id] = true
                end
            end
        end

        if data.sent_checks then
            for loc_name, _ in pairs(data.sent_checks) do
                SENT_CHECKS[loc_name] = true
            end
        end

        local comp_count = 0
        for _ in pairs(COMPLETED_EVENTS) do comp_count = comp_count + 1 end
        M.log(string.format("Loaded progress: %d completed events", comp_count))
    end

    save_loaded = true
end

-- Auto-save
re.on_script_reset(function() save_progress() end)
re.on_config_save(function() save_progress() end)

------------------------------------------------------------
-- Definition Loading
------------------------------------------------------------

local function build_lookup_tables()
    EVENTS_BY_FLAG = {}
    EVENTS_BY_NAME = {}

    for _, event in ipairs(EVENT_DEFINITIONS) do
        if event.flag_id and event.location_name then
            EVENTS_BY_FLAG[event.flag_id] = event
            EVENTS_BY_NAME[event.location_name] = event
        end
    end

    local count = 0
    for _ in pairs(EVENTS_BY_FLAG) do count = count + 1 end
    M.log(string.format("Built lookup tables: %d events defined", count))
end

local function load_definitions_from_json()
    local data = Shared.load_json(EVENTS_JSON_FILE)
    if not data then return false end

    if data.events and type(data.events) == "table" then
        local added = 0
        for _, event in ipairs(data.events) do
            if event.flag_id and event.location_name then
                table.insert(EVENT_DEFINITIONS, {
                    flag_id = event.flag_id,
                    location_name = event.location_name,
                    category = event.category or "unknown",
                    notes = event.notes,
                })
                added = added + 1
            end
        end
        M.log(string.format("Loaded %d event definitions from JSON", added))
        return added > 0
    end

    return false
end

local function load_definitions()
    if definitions_loaded then return end

    -- Try to load additional definitions from JSON
    load_definitions_from_json()

    -- Build lookup tables
    build_lookup_tables()

    definitions_loaded = true
end

------------------------------------------------------------
-- Flag Checking
------------------------------------------------------------

local function check_flag(flag_id)
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

------------------------------------------------------------
-- Event Scanning
------------------------------------------------------------

local function scan_events()
    local newly_completed = {}

    for flag_id, event in pairs(EVENTS_BY_FLAG) do
        -- Skip if already known completed
        if COMPLETED_EVENTS[flag_id] then
            goto continue
        end

        -- Check the flag
        local is_set = check_flag(flag_id)

        if is_set == true then
            COMPLETED_EVENTS[flag_id] = true
            save_dirty = true
            table.insert(newly_completed, event)
        end

        ::continue::
    end

    -- Process newly completed events
    for _, event in ipairs(newly_completed) do
        M.log(string.format("EVENT COMPLETE: %s (flag=%d, category=%s)",
            event.location_name, event.flag_id, event.category or "?"))

        -- Fire callback
        if M.on_event_complete then
            pcall(M.on_event_complete, event.location_name, event.flag_id, event.category)
        end

        -- Track that we need to send this check
        if not SENT_CHECKS[event.location_name] then
            SENT_CHECKS[event.location_name] = true
            save_dirty = true

            -- Try to send to AP if bridge is available
            if AP and AP.AP_BRIDGE and AP.AP_BRIDGE.check then
                local ok = pcall(AP.AP_BRIDGE.check, event.location_name)
                if ok then
                    M.log(string.format("  -> Sent AP check: %s", event.location_name))
                end
            end
        end
    end

    if #newly_completed > 0 then
        save_progress()
    end
end

------------------------------------------------------------
-- Initial Sync
------------------------------------------------------------

local function initial_sync()
    M.log("Performing initial event sync...")

    local synced = 0
    local already_known = 0

    for flag_id, event in pairs(EVENTS_BY_FLAG) do
        local is_set = check_flag(flag_id)

        if is_set == true then
            if COMPLETED_EVENTS[flag_id] then
                already_known = already_known + 1
            else
                COMPLETED_EVENTS[flag_id] = true
                save_dirty = true
                synced = synced + 1

                -- Fire callback for synced events
                if M.on_event_complete then
                    pcall(M.on_event_complete, event.location_name, event.flag_id, event.category)
                end

                -- Send AP check if not already sent
                if not SENT_CHECKS[event.location_name] then
                    SENT_CHECKS[event.location_name] = true

                    if AP and AP.AP_BRIDGE and AP.AP_BRIDGE.check then
                        pcall(AP.AP_BRIDGE.check, event.location_name)
                    end
                end
            end
        end
    end

    M.log(string.format("Initial sync: %d new, %d already known", synced, already_known))

    if synced > 0 then
        save_progress()
    end

    initialized = true
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

--- Check if an event is complete by location name
--- @param location_name string The AP location name
--- @return boolean True if complete
function M.is_event_complete(location_name)
    local event = EVENTS_BY_NAME[location_name]
    if not event then return false end
    return COMPLETED_EVENTS[event.flag_id] == true
end

--- Check if an event is complete by flag ID
--- @param flag_id number The flag ID
--- @return boolean True if complete
function M.is_flag_complete(flag_id)
    return COMPLETED_EVENTS[flag_id] == true
end

--- Get all completed events
--- @return table List of completed event definitions
function M.get_completed_events()
    local results = {}
    for flag_id, _ in pairs(COMPLETED_EVENTS) do
        local event = EVENTS_BY_FLAG[flag_id]
        if event then
            table.insert(results, event)
        end
    end
    return results
end

--- Get progress for a category
--- @param category string The category to check
--- @return number completed, number total
function M.get_category_progress(category)
    local total = 0
    local completed = 0

    for flag_id, event in pairs(EVENTS_BY_FLAG) do
        if event.category == category then
            total = total + 1
            if COMPLETED_EVENTS[flag_id] then
                completed = completed + 1
            end
        end
    end

    return completed, total
end

--- Get overall progress
--- @return number completed, number total
function M.get_progress()
    local total = 0
    local completed = 0

    for _ in pairs(EVENTS_BY_FLAG) do
        total = total + 1
    end
    for _ in pairs(COMPLETED_EVENTS) do
        completed = completed + 1
    end

    return completed, total
end

--- Manually register an event definition (for runtime additions)
--- @param flag_id number The flag ID
--- @param location_name string The AP location name
--- @param category string|nil The category
function M.register_event(flag_id, location_name, category)
    local event = {
        flag_id = flag_id,
        location_name = location_name,
        category = category or "dynamic",
    }

    table.insert(EVENT_DEFINITIONS, event)
    EVENTS_BY_FLAG[flag_id] = event
    EVENTS_BY_NAME[location_name] = event

    M.log(string.format("Registered event: %s (flag=%d)", location_name, flag_id))
end

--- Force a rescan of all events
function M.rescan()
    initialized = false
    initial_sync()
    scan_events()
end

--- Reset all progress (for debugging)
function M.reset_progress()
    COMPLETED_EVENTS = {}
    SENT_CHECKS = {}
    save_dirty = true
    save_progress()
    M.log("Progress reset")
end

--- Print status to log
function M.print_status()
    local completed, total = M.get_progress()
    M.log("=== GAME EVENT TRACKER STATUS ===")
    M.log(string.format("  Progress: %d / %d events", completed, total))

    -- By category
    local categories = {}
    for _, event in pairs(EVENTS_BY_FLAG) do
        local cat = event.category or "unknown"
        categories[cat] = (categories[cat] or 0) + 1
    end

    for cat, count in pairs(categories) do
        local cat_done, cat_total = M.get_category_progress(cat)
        M.log(string.format("  %s: %d / %d", cat, cat_done, cat_total))
    end

    M.log(string.format("  Save file: %s", get_save_path()))
    M.log(string.format("  Initialized: %s", tostring(initialized)))
    M.log("=== END STATUS ===")
end

--- Print completed events
function M.print_completed()
    M.log("=== COMPLETED EVENTS ===")

    local events = M.get_completed_events()
    table.sort(events, function(a, b)
        if a.category ~= b.category then
            return (a.category or "") < (b.category or "")
        end
        return a.flag_id < b.flag_id
    end)

    local current_cat = nil
    for _, event in ipairs(events) do
        if event.category ~= current_cat then
            current_cat = event.category
            M.log(string.format("  [%s]", current_cat or "unknown"))
        end
        M.log(string.format("    Flag %d: %s", event.flag_id, event.location_name))
    end

    M.log(string.format("Total: %d", #events))
end

------------------------------------------------------------
-- Per-frame Update
------------------------------------------------------------

function M.on_frame()
    if not M:should_run() then return end

    -- Load definitions if not done
    if not definitions_loaded then
        load_definitions()
    end

    -- Load saved progress if not done
    if not save_loaded then
        load_progress()
    end

    -- Need EventFlagsManager
    local efm = efm_mgr:get()
    if not efm then return end

    -- Initial sync
    if not initialized then
        initial_sync()
    end

    -- Regular scanning
    scan_events()
end

------------------------------------------------------------
-- Console Helpers
------------------------------------------------------------

_G.event_status = function() M.print_status() end
_G.event_completed = function() M.print_completed() end
_G.event_rescan = function() M.rescan() end
_G.event_reset = function() M.reset_progress() end

------------------------------------------------------------
-- Module Load
------------------------------------------------------------

M.log("GameEventTracker loaded")
M.log("Console commands: event_status(), event_completed(), event_rescan(), event_reset()")
M.log("NOTE: Add event definitions to EVENT_DEFINITIONS table or AP_DRDR_game_events.json")

return M