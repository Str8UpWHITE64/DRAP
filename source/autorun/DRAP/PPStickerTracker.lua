-- Dead Rising Deluxe Remaster - PP Sticker / Unique Photo Tracker (module)
-- Tracks per-sticker completion using SolidModelAttribute on sticker model(s).
-- Hooks updateUniqueItemHint() on a specific model type and logs:
--   - When a new PhotoId is first seen (ever)
--   - When isUniqueItemHasBeenFound() transitions false -> true for that PhotoId (once)
--   - When isUniqueEventTaked() transitions false -> true for that PhotoId (once)


local M = {}
M.on_sticker_found       = nil
M.on_sticker_event_taked = nil

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
    if model_attr_field then
        return true
    end
    if not model_td or not model_attr_td then
        return false
    end

    local fields = get_fields_list(model_td)
    for _, f in ipairs(fields) do
        if f and not f:is_static() then
            local ftype = f:get_type()
            if ftype and ftype:get_full_name() == MODEL_ATTR_TYPE_NAME then
                model_attr_field = f
                log("[PPStickerTracker] Found SolidModelAttribute field on " .. MODEL_TYPE_NAME .. ": " .. f:get_name())
                break
            end
        end
    end

    if not model_attr_field and not missing_warned then
        log("[PPStickerTracker] No SolidModelAttribute field found on " .. MODEL_TYPE_NAME)
        missing_warned = true
        return false
    end

    return model_attr_field ~= nil
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

    log("[PPStickerTracker] Found updateUniqueItemHint() on " .. MODEL_TYPE_NAME)
    return true
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
            -- Pre-hook: inspect this call once per engine call
            local this = sdk.to_managed_object(args[2])
            if this and model_attr_field then
                local ok_attr, attr = pcall(model_attr_field.get_data, model_attr_field, this)
                if ok_attr and attr ~= nil then
                    local attr_key = tostring(attr)
                    local st = attr_state[attr_key]

                    -- Initialize per-attribute state
                    if not st then
                        st = {}
                        attr_state[attr_key] = st

                        if photo_id_field then
                            local ok, v = pcall(photo_id_field.get_data, photo_id_field, attr)
                            if ok then st.photo_id = v end
                        end
                        if item_unique_no_field then
                            local ok, v = pcall(item_unique_no_field.get_data, item_unique_no_field, attr)
                            if ok then st.item_unique = v end
                        end
                        if having_event_field then
                            local ok, v = pcall(having_event_field.get_data, having_event_field, attr)
                            if ok then st.having_event = v end
                        end

                        -- Only log once per PhotoId (ever)
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

                    -- Query flags via methods
                    local ok_item, item_found   = pcall(attr.call, attr, "isUniqueItemHasBeenFound")
                    local ok_event, event_taked = pcall(attr.call, attr, "isUniqueEventTaked")

                    local pid = st.photo_id

                    -- First time FOUND for this PhotoId
                    if ok_item and item_found == true and pid ~= nil then
                        if not found_photo_ids[pid] and (st.last_item == false or st.last_item == nil) then
                            found_photo_ids[pid] = true
                            log(string.format(
                                "Sticker FOUND: PhotoId=%s, ItemUniqueNo=%s, HavingEvent=%s",
                                tostring(st.photo_id),
                                tostring(st.item_unique),
                                tostring(st.having_event)
                            ))

                            -- AP hook
                            if M.on_sticker_found then
                                pcall(M.on_sticker_found,
                                    st.photo_id, st.item_unique, st.having_event)
                            end
                        end
                    end

                    -- First time EVENT TAKED for this PhotoId
                    if ok_event and event_taked == true and pid ~= nil then
                        if not event_taked_photo_ids[pid] and (st.last_event == false or st.last_event == nil) then
                            event_taked_photo_ids[pid] = true
                            log(string.format(
                                "Sticker CAPTURED: PhotoId=%s, ItemUniqueNo=%s, HavingEvent=%s",
                                tostring(st.photo_id),
                                tostring(st.item_unique),
                                tostring(st.having_event)
                            ))

                            -- AP hook
                            if M.on_sticker_event_taked then
                                pcall(M.on_sticker_event_taked,
                                    st.photo_id, st.item_unique, st.having_event)
                            end
                        end
                    end

                    -- Remember last-known states for this attribute instance
                    if ok_item  then st.last_item  = item_found  end
                    if ok_event then st.last_event = event_taked end
                end
            end

            return args
        end,
        function(retval)
            -- Post-hook: no modification
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