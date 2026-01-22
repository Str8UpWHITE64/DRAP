-- DRAP/PPStickerTracker.lua
-- Tracks per-sticker completion using SolidModelAttribute on sticker model(s)

local Shared = require("DRAP/Shared")

local M = Shared.create_module("PPStickerTracker")
M:set_throttle(1.0)

------------------------------------------------------------
-- Configuration
------------------------------------------------------------

local MODEL_TYPE_NAME = "solid.MT2RE.uOm13f"
local MODEL_ATTR_TYPE_NAME = "app.solid.character.SolidModelAttribute"
local PP_JSON_PATH = "PPstickers.json"

------------------------------------------------------------
-- Internal State
------------------------------------------------------------

local model_td = nil
local model_attr_td = nil
local update_hint_method = nil
local photo_id_field = nil
local item_unique_no_field = nil
local having_event_field = nil

local hook_installed = false
local missing_warned = false

local attr_state = {}
local get_attr_from_model = nil

local PP_BY_PHOTO_ID = nil

-- Global de-duplication by PhotoId
local seen_photo_ids = {}
local found_photo_ids = {}
local event_taked_photo_ids = {}

-- Expose maps
M.seen_photo_ids = seen_photo_ids
M.found_photo_ids = found_photo_ids
M.event_taked_photo_ids = event_taked_photo_ids

------------------------------------------------------------
-- Public Callbacks
------------------------------------------------------------

M.on_sticker_found = nil
M.on_sticker_event_taked = nil

------------------------------------------------------------
-- JSON Loading
------------------------------------------------------------

local function ensure_pp_map()
    if PP_BY_PHOTO_ID then return true end

    PP_BY_PHOTO_ID = {}
    local rows = Shared.load_json(PP_JSON_PATH, M.log)
    if not rows then return false end

    local count = 0
    for _, row in ipairs(rows) do
        local pid = row.PhotoID
        local item = row.ItemNumber
        local name = row.LocationName

        if pid then
            local pid_num = tonumber(pid)
            local pid_str = tostring(pid)

            PP_BY_PHOTO_ID[pid_str] = { item = item, name = name }
            if pid_num then
                PP_BY_PHOTO_ID[pid_num] = { item = item, name = name }
            end
            count = count + 1
        end
    end

    M.log("Loaded PPstickers.json entries: " .. tostring(count))
    return count > 0
end

local function map_photo_id(photo_id)
    ensure_pp_map()
    if not PP_BY_PHOTO_ID then return nil end
    return PP_BY_PHOTO_ID[photo_id]
end

------------------------------------------------------------
-- Type Setup
------------------------------------------------------------

local function ensure_model_types()
    if model_td and model_attr_td then return true end

    model_td = sdk.find_type_definition(MODEL_TYPE_NAME)
    if not model_td then
        if not missing_warned then
            M.log("ERROR: could not find model type: " .. MODEL_TYPE_NAME)
            missing_warned = true
        end
        return false
    end

    model_attr_td = sdk.find_type_definition(MODEL_ATTR_TYPE_NAME)
    if not model_attr_td then
        if not missing_warned then
            M.log("ERROR: could not find SolidModelAttribute type")
            missing_warned = true
        end
        return false
    end

    return true
end

local function ensure_model_attr_field()
    if get_attr_from_model then return true end
    if not model_td then return false end

    local fields = Shared.get_fields_array(model_td)
    for _, f in ipairs(fields) do
        if f and not f:is_static() then
            local ftype = f:get_type()
            if ftype and ftype:get_full_name() == MODEL_ATTR_TYPE_NAME then
                local ok_has = pcall(function() return type(f.get_data) == "function" end)
                if ok_has then
                    get_attr_from_model = function(model_obj)
                        return f:get_data(model_obj)
                    end
                    M.log("Found SolidModelAttribute field: " .. f:get_name())
                    return true
                end
            end
        end
    end

    if not missing_warned then
        M.log("No usable SolidModelAttribute field found")
        missing_warned = true
    end
    return false
end

local function ensure_attr_fields()
    if photo_id_field then return true end
    if not model_attr_td then return false end

    photo_id_field = model_attr_td:get_field("mPhotoId")
    item_unique_no_field = model_attr_td:get_field("<mItemUniqueNo>k__BackingField")
    having_event_field = model_attr_td:get_field("HavingUniqueEvent")

    return true
end

local function ensure_update_hint_method()
    if update_hint_method then return true end
    if not model_td then return false end

    update_hint_method = model_td:get_method("updateUniqueItemHint")
    if not update_hint_method then
        if not missing_warned then
            M.log("Could not find updateUniqueItemHint()")
            missing_warned = true
        end
        return false
    end
    return true
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

function M.send_pp_sticker_100()
    local loc = "Photograph PP Sticker 100"
    if AP and AP.AP_BRIDGE and AP.AP_BRIDGE.check then
        AP.AP_BRIDGE.check(loc)
    end
end

------------------------------------------------------------
-- Hook Installation
------------------------------------------------------------

local function install_hook()
    if hook_installed then return true end

    if not ensure_model_types() then return false end
    if not ensure_model_attr_field() then return false end
    ensure_attr_fields()
    if not ensure_update_hint_method() then return false end

    sdk.hook(
        update_hint_method,
        function(args)
            local ok = pcall(function()
                local this = args[2]
                if not this or not get_attr_from_model then return end

                local attr = get_attr_from_model(this)
                if not attr then return end

                local attr_key = tostring(attr)
                local st = attr_state[attr_key]

                if not st then
                    st = {}
                    attr_state[attr_key] = st

                    if photo_id_field then
                        local okv, v = pcall(photo_id_field.get_data, photo_id_field, attr)
                        if okv then st.photo_id = v end
                    end

                    if item_unique_no_field then
                        local okv, v = pcall(item_unique_no_field.get_data, item_unique_no_field, attr)
                        if okv then st.item_unique = v end
                    end

                    if having_event_field then
                        local okv, v = pcall(having_event_field.get_data, having_event_field, attr)
                        if okv then st.having_event = v end
                    end

                    local pid = st.photo_id
                    if pid and not seen_photo_ids[pid] then
                        seen_photo_ids[pid] = true
                        M.log(string.format("New photo target: PhotoId=%s", tostring(st.photo_id)))
                    end
                end

                local ok_item, item_found = pcall(function() return attr:call("isUniqueItemHasBeenFound") end)
                local ok_event, event_taked = pcall(function() return attr:call("isUniqueEventTaked") end)

                local pid = st.photo_id

                if ok_item and item_found == true and pid then
                    if not found_photo_ids[pid] and not st.last_item then
                        found_photo_ids[pid] = true
                        M.log(string.format("Sticker FOUND: PhotoId=%s", tostring(st.photo_id)))
                    end
                end

                if ok_event and event_taked == true and pid then
                    if not event_taked_photo_ids[pid] and not st.last_event then
                        event_taked_photo_ids[pid] = true
                        M.log(string.format("Sticker CAPTURED: PhotoId=%s", tostring(st.photo_id)))

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
                            M.log("WARN: PhotoId not in JSON: " .. tostring(st.photo_id))
                            if M.on_sticker_event_taked then
                                pcall(M.on_sticker_event_taked, "Photograph PP Sticker " .. tostring(st.photo_id), nil, st.photo_id, st.item_unique, st.having_event)
                            end
                        end
                    end
                end

                if ok_item then st.last_item = item_found end
                if ok_event then st.last_event = event_taked end
            end)
            return args
        end,
        function(retval) return retval end
    )

    hook_installed = true
    M.log("Hook installed on updateUniqueItemHint()")
    return true
end

------------------------------------------------------------
-- Per-frame Update
------------------------------------------------------------

function M.on_frame()
    if hook_installed then return end
    if not M:should_run() then return end
    install_hook()
end

return M