-- DRAP/PPStickerTracker.lua
-- Tracks PP sticker captures using:
--   1. EventFlagsManager.evFlagCheck() for stickers with valid FlagIDs
--   2. AreaManager.OmList.mChecked for stickers without flags (FlagID = 0)
-- Authoritative flag-based tracking - no false positives

local Shared = require("DRAP/Shared")

local M = Shared.create_module("PPStickerTracker")
M:set_throttle(0.5)

------------------------------------------------------------
-- Configuration
------------------------------------------------------------

local PP_JSON_PATH = "PPstickers.json"
local CAPTURED_JSON_DIR = "AP_DRDR_Stickers"
local CAPTURED_JSON_FILE = nil  -- Set via set_save_filename()

------------------------------------------------------------
-- Singleton Managers
------------------------------------------------------------

local efm_mgr = M:add_singleton("efm", "app.solid.gamemastering.EventFlagsManager")
local am_mgr = M:add_singleton("am", "app.solid.gamemastering.AreaManager")

------------------------------------------------------------
-- Internal State
------------------------------------------------------------

-- Sticker data from JSON: { [photo_id] = { flag_id, name, item_number } }
local STICKER_DATA = {}

-- Photo IDs that need OmList checking (FlagID = 0 or duplicate)
local OMLIST_PHOTO_IDS = {}

-- Captured stickers: { [photo_id] = true }
local CAPTURED = {}

-- Initialization state
local data_loaded = false
local initialized = false
local save_dirty = false

------------------------------------------------------------
-- Public Callback (compatible with AP_DRDR_main.lua)
------------------------------------------------------------

M.on_sticker_event_taked = nil

------------------------------------------------------------
-- Save File Management
------------------------------------------------------------

--- Set the save filename based on slot and seed
--- @param slot_name string The AP slot name
--- @param seed string The seed
function M.set_save_filename(slot_name, seed)
    local function safe_fn(s)
        if not s then return "unknown" end
        return tostring(s):gsub("[^%w%-_]", "_"):sub(1, 32)
    end

    local slot = safe_fn(slot_name)
    local sd = safe_fn(seed)
    CAPTURED_JSON_FILE = "./" .. CAPTURED_JSON_DIR .. "/AP_DRDR_stickers_" .. slot .. "_" .. sd .. ".json"
    M.log("Sticker save file: " .. CAPTURED_JSON_FILE)
end

local function get_save_path()
    return CAPTURED_JSON_FILE or (CAPTURED_JSON_DIR .. "/AP_DRDR_stickers_default.json")
end

local function save_captured()
    if not save_dirty then return end

    local data = {
        version = 1,
        last_updated = os.time(),
        captured = {},
    }

    for photo_id, _ in pairs(CAPTURED) do
        data.captured[tostring(photo_id)] = true
    end

    local ok = Shared.save_json(get_save_path(), data, 2, M.log)
    if ok then
        save_dirty = false
    end
end

local function load_captured()
    local data = Shared.load_json(get_save_path())
    if data and data.captured then
        for photo_id_str, _ in pairs(data.captured) do
            local photo_id = tonumber(photo_id_str)
            if photo_id then
                CAPTURED[photo_id] = true
            end
        end

        local count = 0
        for _ in pairs(CAPTURED) do count = count + 1 end
        M.log(string.format("Loaded %d captured stickers from save", count))
    end
end

-- Auto-save
re.on_script_reset(function() save_captured() end)
re.on_config_save(function() save_captured() end)

------------------------------------------------------------
-- Flag Check via EventFlagsManager
------------------------------------------------------------

local function check_flag(flag_id)
    if not flag_id or flag_id == 0 then return nil end

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
-- OmList Check via AreaManager
------------------------------------------------------------

local om_list_field = nil
local om_item_fields = {}  -- { mChecked, mMyScoopId }

local function ensure_omlist_fields()
    if om_list_field then return true end

    local am_td = sdk.find_type_definition("app.solid.gamemastering.AreaManager")
    if not am_td then return false end

    om_list_field = am_td:get_field("OmList")
    if not om_list_field then
        M.log("OmList field not found on AreaManager")
        return false
    end

    -- Get fields from the Om item type
    local om_td = sdk.find_type_definition("solid.MT2RE.uOm13f")
    if om_td then
        om_item_fields.mChecked = om_td:get_field("mChecked")
        om_item_fields.mMyScoopId = om_td:get_field("mMyScoopId")
    end

    return om_item_fields.mChecked ~= nil and om_item_fields.mMyScoopId ~= nil
end

--- Check if a photo_id is marked as checked in OmList
--- @param target_photo_id number The PhotoID to check
--- @return boolean|nil True if checked, false if found but not checked, nil if not found
local function check_omlist(target_photo_id)
    local am = am_mgr:get()
    if not am then return nil end

    if not ensure_omlist_fields() then return nil end

    local ok, om_list = pcall(om_list_field.get_data, om_list_field, am)
    if not ok or not om_list then return nil end

    -- Get the _items array from the list
    local items = nil
    pcall(function()
        local items_field = om_list:get_type_definition():get_field("_items")
        if items_field then
            items = items_field:get_data(om_list)
        end
    end)

    if not items then
        -- Try direct iteration
        items = om_list
    end

    -- Iterate through items
    local count = Shared.get_collection_count(items)
    for i = 0, count - 1 do
        local item = Shared.get_collection_item(items, i)
        if item then
            -- Check if it's the right type
            local item_type = nil
            pcall(function() item_type = item:get_type_definition():get_full_name() end)

            if item_type and item_type:find("uOm13f") then
                local scoop_id = nil
                local is_checked = nil

                if om_item_fields.mMyScoopId then
                    local ok_id, v = pcall(om_item_fields.mMyScoopId.get_data, om_item_fields.mMyScoopId, item)
                    if ok_id then scoop_id = Shared.to_int(v) end
                end

                if scoop_id == target_photo_id then
                    if om_item_fields.mChecked then
                        local ok_chk, v = pcall(om_item_fields.mChecked.get_data, om_item_fields.mChecked, item)
                        if ok_chk then is_checked = (v == true) end
                    end
                    return is_checked
                end
            end
        end
    end

    return nil  -- Not found in current area
end

------------------------------------------------------------
-- Data Loading
------------------------------------------------------------

local function load_sticker_data()
    if data_loaded then return true end

    local rows = Shared.load_json(PP_JSON_PATH, M.log)
    if not rows then
        M.log("Failed to load " .. PP_JSON_PATH)
        return false
    end

    -- Track flag usage to detect duplicates
    local flag_usage = {}  -- { [flag_id] = count }

    local count = 0
    for _, row in ipairs(rows) do
        local photo_id = row.PhotoID
        local flag_id = row.FlagID or 0
        local name = row.LocationName
        local item_number = row.ItemNumber

        if photo_id then
            STICKER_DATA[photo_id] = {
                flag_id = flag_id,
                name = name,
                item_number = item_number,
            }

            -- Track flag usage
            if flag_id and flag_id > 0 then
                flag_usage[flag_id] = (flag_usage[flag_id] or 0) + 1
            end

            count = count + 1
        end
    end

    -- Identify photo_ids that need OmList checking
    -- (FlagID = 0 or duplicate flags)
    local omlist_count = 0
    for photo_id, sticker in pairs(STICKER_DATA) do
        local flag_id = sticker.flag_id

        local needs_omlist = false
        if not flag_id or flag_id == 0 then
            needs_omlist = true
        elseif flag_usage[flag_id] and flag_usage[flag_id] > 1 then
            needs_omlist = true
            M.log(string.format("  Duplicate FlagID %d for PhotoID %d - will use OmList", flag_id, photo_id))
        end

        if needs_omlist then
            OMLIST_PHOTO_IDS[photo_id] = true
            omlist_count = omlist_count + 1
        end
    end

    M.log(string.format("Loaded %d stickers (%d need OmList checking)", count, omlist_count))
    data_loaded = true
    return count > 0
end

------------------------------------------------------------
-- Sticker Checking
------------------------------------------------------------

--- Check if a sticker is captured using the appropriate method
--- @param photo_id number The PhotoID
--- @return boolean|nil True if captured, false if not, nil if unknown
local function is_sticker_captured(photo_id)
    local sticker = STICKER_DATA[photo_id]
    if not sticker then return nil end

    -- If this sticker needs OmList checking
    if OMLIST_PHOTO_IDS[photo_id] then
        local omlist_result = check_omlist(photo_id)
        if omlist_result ~= nil then
            return omlist_result
        end
        -- Fall through to flag check if OmList didn't find it
    end

    -- Use flag check for stickers with valid flags
    local flag_id = sticker.flag_id
    if flag_id and flag_id > 0 then
        return check_flag(flag_id)
    end

    return nil
end

------------------------------------------------------------
-- Scanning
------------------------------------------------------------

local function scan_stickers()
    if not data_loaded then return end

    local newly_captured = {}

    for photo_id, sticker in pairs(STICKER_DATA) do
        -- Skip if already known captured
        if CAPTURED[photo_id] then
            goto continue
        end

        local is_captured = is_sticker_captured(photo_id)

        if is_captured == true then
            CAPTURED[photo_id] = true
            save_dirty = true
            table.insert(newly_captured, {
                photo_id = photo_id,
                flag_id = sticker.flag_id,
                name = sticker.name,
                item_number = sticker.item_number,
            })
        end

        ::continue::
    end

    -- Process newly captured
    for _, sticker in ipairs(newly_captured) do
        local location_name = sticker.name
        if not location_name and sticker.item_number then
            location_name = "Photograph PP Sticker " .. tostring(sticker.item_number)
        elseif not location_name then
            location_name = "Photograph PP Sticker (PhotoId " .. tostring(sticker.photo_id) .. ")"
        end

        M.log(string.format("CAPTURED: %s (PhotoId=%d, Flag=%s)",
            location_name, sticker.photo_id, tostring(sticker.flag_id)))

        if M.on_sticker_event_taked then
            pcall(M.on_sticker_event_taked,
                location_name,
                sticker.item_number,
                sticker.photo_id,
                nil,
                sticker.flag_id)
        end
    end

    if #newly_captured > 0 then
        save_captured()
    end
end

------------------------------------------------------------
-- Initial Sync
------------------------------------------------------------

local function initial_sync()
    if not data_loaded then return end

    M.log("Performing initial sticker sync...")

    local synced = 0
    local already_known = 0

    for photo_id, sticker in pairs(STICKER_DATA) do
        local is_captured = is_sticker_captured(photo_id)

        if is_captured == true then
            if CAPTURED[photo_id] then
                already_known = already_known + 1
            else
                CAPTURED[photo_id] = true
                save_dirty = true
                synced = synced + 1

                -- Fire callback for synced stickers
                local location_name = sticker.name or ("Photograph PP Sticker " .. tostring(sticker.item_number or "?"))
                if M.on_sticker_event_taked then
                    pcall(M.on_sticker_event_taked,
                        location_name,
                        sticker.item_number,
                        photo_id,
                        nil,
                        sticker.flag_id)
                end
            end
        end
    end

    M.log(string.format("Initial sync: %d new, %d already known", synced, already_known))

    if synced > 0 then
        save_captured()
    end

    initialized = true
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

function M.is_captured(photo_id)
    return CAPTURED[photo_id] == true
end

function M.check_flag(flag_id)
    return check_flag(flag_id)
end

function M.check_omlist(photo_id)
    return check_omlist(photo_id)
end

function M.get_progress()
    local captured = 0
    local total = 0

    for _ in pairs(STICKER_DATA) do
        total = total + 1
    end
    for _ in pairs(CAPTURED) do
        captured = captured + 1
    end

    return captured, total
end

function M.get_sticker_data()
    return STICKER_DATA
end

function M.get_captured()
    return CAPTURED
end

function M.rescan()
    initialized = false
    initial_sync()
    scan_stickers()
end

function M.reset_captured()
    CAPTURED = {}
    save_dirty = true
    save_captured()
    M.log("Captured state reset")
end

function M.print_status()
    local captured, total = M.get_progress()
    M.log("=== PP STICKER STATUS ===")
    M.log(string.format("  Progress: %d / %d captured", captured, total))
    M.log(string.format("  OmList stickers: %d", 0))  -- Count OMLIST_PHOTO_IDS

    local omlist_count = 0
    for _ in pairs(OMLIST_PHOTO_IDS) do omlist_count = omlist_count + 1 end
    M.log(string.format("  Stickers needing OmList: %d", omlist_count))

    M.log(string.format("  Save file: %s", get_save_path()))
    M.log(string.format("  Initialized: %s", tostring(initialized)))

    local efm = efm_mgr:get()
    local am = am_mgr:get()
    M.log(string.format("  EventFlagsManager: %s", efm and "OK" or "NOT available"))
    M.log(string.format("  AreaManager: %s", am and "OK" or "NOT available"))
    M.log("=== END STATUS ===")
end

function M.print_captured()
    M.log("=== CAPTURED STICKERS ===")

    local list = {}
    for photo_id, _ in pairs(CAPTURED) do
        local sticker = STICKER_DATA[photo_id]
        local name = sticker and sticker.name or "?"
        local item_num = sticker and sticker.item_number or 0
        table.insert(list, { photo_id = photo_id, name = name, item_num = item_num })
    end

    table.sort(list, function(a, b) return a.item_num < b.item_num end)

    for _, item in ipairs(list) do
        M.log(string.format("  [%d] %s", item.item_num, item.name))
    end

    M.log(string.format("Total: %d", #list))
end

function M.print_omlist_stickers()
    M.log("=== STICKERS USING OMLIST ===")
    for photo_id, _ in pairs(OMLIST_PHOTO_IDS) do
        local sticker = STICKER_DATA[photo_id]
        local name = sticker and sticker.name or "?"
        local flag_id = sticker and sticker.flag_id or 0
        M.log(string.format("  PhotoID %d: %s (FlagID=%d)", photo_id, name, flag_id))
    end
    M.log("=== END ===")
end

function M.send_pp_sticker_100()
    local loc = "Photograph PP Sticker 100"
    if AP and AP.AP_BRIDGE and AP.AP_BRIDGE.check then
        AP.AP_BRIDGE.check(loc)
    end
end

------------------------------------------------------------
-- Per-frame Update
------------------------------------------------------------

function M.on_frame()
    if not M:should_run() then return end

    if not data_loaded then
        load_sticker_data()
        load_captured()
    end

    -- Need at least EventFlagsManager
    local efm = efm_mgr:get()
    if not efm then return end

    if not initialized then
        initial_sync()
    end

    scan_stickers()
end

------------------------------------------------------------
-- Module Load
------------------------------------------------------------

M.log("PPStickerTracker loaded (hybrid: evFlagCheck + OmList)")

return M