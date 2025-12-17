-- Dead Rising Deluxe Remaster - PP Sticker / Unique Photo Tracker (module)
-- Tracks per-sticker completion using SolidModelAttribute on sticker model(s).
-- Hooks updateUniqueItemHint() on a specific model type and logs:
--   - When a new PhotoId is first seen
--   - When isUniqueItemHasBeenFound() transitions false -> true for that PhotoId (once)
--   - When isUniqueEventTaked() transitions false -> true for that PhotoId (once)


local M = {}
M.on_sticker_found       = nil
M.on_sticker_event_taked = nil

local PP_BY_PHOTO_ID = nil

------------------------------------------------
-- Logging
------------------------------------------------

local function log(msg)
    print("[PPStickerTracker] " .. tostring(msg))
end

------------------------------------------------
-- Config
------------------------------------------------

local MODEL_TYPE_NAME        = "solid.MT2RE.uOm13f"
local MODEL_ATTR_TYPE_NAME   = "app.solid.character.SolidModelAttribute"

-- SolidModelAttribute fields of interest
local PHOTO_ID_FIELD_NAME    = "mPhotoId"                       -- System.UInt32
local ITEM_UNIQUE_NO_FIELD   = "<mItemUniqueNo>k__BackingField" -- System.UInt32
local HAVING_EVENT_FIELD     = "HavingUniqueEvent"              -- solid.MT2RE.EventFlag (int-ish)

local last_check_time = 0
local CHECK_INTERVAL  = 1  -- seconds


------------------------------------------------
-- State
------------------------------------------------

local model_td               = nil   -- sticker model type definition
local model_attr_td          = nil   -- SolidModelAttribute type definition
local model_attr_field       = nil   -- field on model holding SolidModelAttribute
local update_hint_method     = nil   -- updateUniqueItemHint method on model

local photo_id_field         = nil   -- SolidModelAttribute.mPhotoId
local item_unique_no_field   = nil   -- SolidModelAttribute.<mItemUniqueNo>k__BackingField
local having_event_field     = nil   -- SolidModelAttribute.HavingUniqueEvent

local hook_installed         = false
local missing_warned         = false

local last_hook_attempt_time = 0.0

local attr_state             = {}
local get_attr_from_model = nil  -- function(this) -> attr or nil


-- Global de-duplication by PhotoId:
local seen_photo_ids         = {}    -- [photo_id] = true (ever seen)
local found_photo_ids        = {}    -- [photo_id] = true (ever found)
local event_taked_photo_ids  = {}    -- [photo_id] = true (ever event-taked)

-- Expose maps
M.seen_photo_ids        = seen_photo_ids
M.found_photo_ids       = found_photo_ids
M.event_taked_photo_ids = event_taked_photo_ids

------------------------------------------------
-- Helpers
------------------------------------------------

-- Normalize td:get_fields() into a plain Lua array
local function get_fields_list(td)
    local raw = td:get_fields()
    if not raw then
        return {}
    end

    local fields = {}

    local get_count = raw.get_Count or raw.get_size
    if get_count and raw.get_Item then
        local count = get_count(raw)
        for i = 0, count - 1 do
            fields[#fields + 1] = raw:get_Item(i)
        end
        return fields
    end

    local i = 1
    while raw[i] ~= nil do
        fields[#fields + 1] = raw[i]
        i = i + 1
    end

    return fields
end

local function ensure_pp_map()
    local PP_JSON_PATH = "PPstickers.json"

    if PP_BY_PHOTO_ID ~= nil then
        log("PP sticker map already loaded.")
        log("PP sticker map entries: " .. tostring(#PP_BY_PHOTO_ID))
        return true
    end

    PP_BY_PHOTO_ID = {}

    local rows = json.load_file(PP_JSON_PATH)
    if not rows then
        log("ERROR: Failed to load PP stickers JSON: " .. PP_JSON_PATH)
        return false
    end

    local count = 0
    for _, row in ipairs(rows) do
        local pid  = row.PhotoID
        local item = row.ItemNumber
        local name = row.LocationName

        if pid ~= nil then
            -- store under both numeric and string keys to avoid type mismatches
            local pid_num = tonumber(pid)
            local pid_str = tostring(pid)

            PP_BY_PHOTO_ID[pid_str] = { item = item, name = name }
            if pid_num ~= nil then
                PP_BY_PHOTO_ID[pid_num] = { item = item, name = name }
            end
            count = count + 1
        end
    end
    log("Loaded PPstickers.json entries: " .. tostring(count))
    return count > 0
end

local function map_photo_id(photo_id)
    ensure_pp_map()
    if not PP_BY_PHOTO_ID then return nil end
    return PP_BY_PHOTO_ID[photo_id]
end


------------------------------------------------
-- Model / Attribute access
------------------------------------------------

local function ensure_model_types()
    if model_td and model_attr_td then
        return true
    end

    model_td = sdk.find_type_definition(MODEL_TYPE_NAME)
    if not model_td then
        if not missing_warned then
            log("ERROR: could not find model type: " .. MODEL_TYPE_NAME)
            missing_warned = true
        end
        return false
    end

    model_attr_td = sdk.find_type_definition(MODEL_ATTR_TYPE_NAME)
    if not model_attr_td then
        if not missing_warned then
            log("ERROR: could not find SolidModelAttribute type: " .. MODEL_ATTR_TYPE_NAME)
            missing_warned = true
        end
        return false
    end

    return true
end

local function ensure_model_attr_field()
    if get_attr_from_model then
        return true
    end
    if not model_td then
        return false
    end

    local fields = get_fields_list(model_td)
    for _, f in ipairs(fields) do
        if f and not f:is_static() then
            local ftype = f:get_type()
            if ftype and ftype:get_full_name() == MODEL_ATTR_TYPE_NAME then
                -- Validate this really is a Field-like object with callable get_data
                local ok_has, has = pcall(function()
                    return type(f.get_data) == "function"
                end)

                if ok_has and has then
                    model_attr_field = f

                    get_attr_from_model = function(model_obj)

                        return f:get_data(model_obj)
                    end

                    log("[PPStickerTracker] Found SolidModelAttribute field on " .. MODEL_TYPE_NAME .. ": " .. f:get_name())
                    return true
                else
                    log("[PPStickerTracker] Skipping candidate attr field (no callable get_data): " .. tostring(f:get_name()))
                end
            end
        end
    end

    if not missing_warned then
        log("[PPStickerTracker] No usable SolidModelAttribute field found on " .. MODEL_TYPE_NAME)
        missing_warned = true
    end
    return false
end

local function ensure_attr_fields()
    if photo_id_field or item_unique_no_field or having_event_field then
        return true
    end
    if not model_attr_td then
        return false
    end

    photo_id_field       = model_attr_td:get_field(PHOTO_ID_FIELD_NAME)
    item_unique_no_field = model_attr_td:get_field(ITEM_UNIQUE_NO_FIELD)
    having_event_field   = model_attr_td:get_field(HAVING_EVENT_FIELD)

    return true
end

local function ensure_update_hint_method()
    if update_hint_method then
        return true
    end
    if not model_td then
        return false
    end

    update_hint_method = model_td:get_method("updateUniqueItemHint")
    if not update_hint_method then
        if not missing_warned then
            log("[PPStickerTracker] Could not find updateUniqueItemHint() on " .. MODEL_TYPE_NAME)
            missing_warned = true
        end
        return false
    end
    return true
end

------------------------------------------------
-- Custom logic
------------------------------------------------

function M.on_pp_sticker_area_progress()
    local loc = ("Photograph PP Sticker 100")
    if AP and AP.AP_BRIDGE and AP.AP_BRIDGE.check then
        AP.AP_BRIDGE.check(loc)
    end
end

------------------------------------------------
-- Hook install
------------------------------------------------

local function install_hook()
    if hook_installed then
        return true
    end

    if not ensure_model_types() then
        return false
    end
    if not ensure_model_attr_field() then
        return false
    end
    ensure_attr_fields()
    if not ensure_update_hint_method() then
        return false
    end

    sdk.hook(
        update_hint_method,
        function(args)
        local ok = pcall(function()
            local this = args[2]
            if not this then return end
            if not get_attr_from_model then return end

            local attr = get_attr_from_model(this)
            if not attr then return end

            local attr_key = tostring(attr)
            local st = attr_state[attr_key]

            if not st then
                st = {}
                attr_state[attr_key] = st

                if photo_id_field then
                    local okv, v = pcall(function()
                        return photo_id_field:get_data(attr)
                    end)
                    if okv then st.photo_id = v end
                end

                if item_unique_no_field then
                    local okv, v = pcall(function()
                        return item_unique_no_field:get_data(attr)
                    end)
                    if okv then st.item_unique = v end
                end

                if having_event_field then
                    local okv, v = pcall(function()
                        return having_event_field:get_data(attr)
                    end)
                    if okv then st.having_event = v end
                end

                local pid = st.photo_id
                if pid ~= nil and not seen_photo_ids[pid] then
                    seen_photo_ids[pid] = true
                    log(string.format(
                        "New unique photo target: PhotoId=%s, ItemUniqueNo=%s, HavingEvent=%s",
                        tostring(st.photo_id),
                        tostring(st.item_unique),
                        tostring(st.having_event)
                    ))
                end
            end

            -- Query flags via methods (lookup+call inside pcall)
            local ok_item, item_found = pcall(function()
                return attr:call("isUniqueItemHasBeenFound")
            end)

            local ok_event, event_taked = pcall(function()
                return attr:call("isUniqueEventTaked")
            end)

            local pid = st.photo_id

            if ok_item and item_found == true and pid ~= nil then
                if not found_photo_ids[pid] and (st.last_item == false or st.last_item == nil) then
                    found_photo_ids[pid] = true
                    log(string.format(
                        "Sticker FOUND: PhotoId=%s, ItemUniqueNo=%s, HavingEvent=%s",
                        tostring(st.photo_id),
                        tostring(st.item_unique),
                        tostring(st.having_event)
                    ))
                end
            end

            if ok_event and event_taked == true and pid ~= nil then
                if not event_taked_photo_ids[pid] and (st.last_event == false or st.last_event == nil) then
                    event_taked_photo_ids[pid] = true
                    log(string.format(
                        "Sticker CAPTURED: PhotoId=%s, ItemUniqueNo=%s, HavingEvent=%s",
                        tostring(st.photo_id),
                        tostring(st.item_unique),
                        tostring(st.having_event)
                    ))

                    -- AP hook / mapping
                    local row = map_photo_id(st.photo_id)
                    if row and row.name then
                        if M.on_sticker_event_taked then
                            pcall(M.on_sticker_event_taked, row.name, row.item, st.photo_id, st.item_unique, st.having_event)
                        end
                    elseif row and row.item then
                        local loc = "Photograph PP Sticker " .. tostring(row.item)
                        if M.on_sticker_event_taked then
                            pcall(M.on_sticker_event_taked, loc, row.item, st.photo_id, st.item_unique, st.having_event)
                        end
                    else
                        log("WARN: PhotoId not in PPstickers.json: " .. tostring(st.photo_id))
                        if M.on_sticker_event_taked then
                            pcall(M.on_sticker_event_taked, "Photograph PP Sticker " .. tostring(st.photo_id), nil, st.photo_id, st.item_unique, st.having_event)
                        end
                    end
                end
            end

            if ok_item  then st.last_item  = item_found  end
            if ok_event then st.last_event = event_taked end
        end)
        return args
    end,
        function(retval)
            return retval
        end
    )

    hook_installed = true
    log("[PPStickerTracker] Hook installed on " .. MODEL_TYPE_NAME .. ".updateUniqueItemHint()")
    return true
end

------------------------------------------------
-- Main update entrypoint
------------------------------------------------

function M.on_frame()
    -- Once the hook is in, we do nothing per frame.
    if hook_installed then
        return
    end

    -- Throttle checks to reduce performance impact
    local now = os.clock()
    if now - last_check_time < CHECK_INTERVAL then
        return
    end
    last_check_time = now

    install_hook()
end

log("Module loaded. Tracking unique photo targets on " .. MODEL_TYPE_NAME .. ".")

return M