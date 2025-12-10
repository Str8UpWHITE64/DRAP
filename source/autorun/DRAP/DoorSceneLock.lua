-- Dead Rising Deluxe Remaster - Door HitData Scene Locker (module)
-- Disables doors by toggling HIT_DATA.mHitData.Disabled via set_field("Disabled", ...)
-- for LayoutInfos whose AREA_JUMP_NAME points to locked scenes.

local M = {}

------------------------------------------------
-- Logging
------------------------------------------------

local function log(msg)
    print("[DoorSceneLock] " .. tostring(msg))
end

------------------------------------------------
-- Config
------------------------------------------------

local AreaManager_TYPE_NAME = "app.solid.gamemastering.AreaManager"

local am_instance  = nil
local am_td        = nil
local area_index_f = nil
local level_path_f = nil
local am_warned    = false

------------------------------------------------------------
-- Scene metadata (for logs only)
------------------------------------------------------------

local SCENE_INFO = {
    s135 = { name = "Helipad",                 index = 287  },
    s136 = { name = "Safe Room",               index = 288  },
    s231 = { name = "Rooftop",                 index = 535  },
    s230 = { name = "Service Hallway",         index = 534  },
    s200 = { name = "Paradise Plaza",          index = 512  },
    s503 = { name = "Colby's Movie Theater",   index = 1283 },
    s700 = { name = "Leisure Park",            index = 1792 },
    s400 = { name = "North Plaza",             index = 1024 },
    s501 = { name = "Crisip's Hardware Store", index = 1281 },
    sa00 = { name = "Food Court",              index = 2560 },
    s300 = { name = "Wonderland Plaza",        index = 768  },
    s900 = { name = "Al Fresca Plaza",         index = 2304 },
    s100 = { name = "Entrance Plaza",          index = 256  },
    s500 = { name = "Grocery Store",           index = 1280 },
    s600 = { name = "Maintenance Tunnel",      index = 1536 },
    s401 = { name = "Hideout",                 index = 1025 },
}

------------------------------------------------------------
-- Lock state
------------------------------------------------------------

local LOCKED_SCENES = {
    -- ["s135"] = true,
    -- ["s200"] = true,
}

local function scene_is_locked(scene_code)
    return LOCKED_SCENES[scene_code] == true
end

------------------------------------------------------------
-- Generic helpers
------------------------------------------------------------

local function any_to_int(val)
    if val == nil then return nil end
    if type(val) == "number" then return math.floor(val) end

    local ok_i64, i64 = pcall(sdk.to_int64, val)
    if not ok_i64 or i64 == nil then return nil end

    if type(i64) == "number" then return math.floor(i64) end

    local ok_g, raw = pcall(i64.get_int64, i64)
    if not ok_g or raw == nil then return nil end

    return math.floor(raw)
end

local function get_list_count(list)
    if list == nil then return 0 end
    local ok, count = pcall(sdk.call_object_func, list, "get_Count")
    if not ok or count == nil then return 0 end
    return any_to_int(count) or 0
end

local function get_list_item(list, index)
    if list == nil or index == nil then return nil end
    local ok, item = pcall(sdk.call_object_func, list, "get_Item", index)
    if not ok then return nil end
    return item
end

local function get_field_value(obj, variants)
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

------------------------------------------------------------
-- AreaManager (current area info)
------------------------------------------------------------

local function reset_area_manager_cache()
    am_td        = nil
    area_index_f = nil
    level_path_f = nil
    am_warned    = false
end

local function ensure_area_manager()
    local current = sdk.get_managed_singleton(AreaManager_TYPE_NAME)

    if current ~= am_instance then
        am_instance = current
        reset_area_manager_cache()

        if current ~= nil then
            am_td = sdk.find_type_definition(AreaManager_TYPE_NAME)
            if am_td ~= nil then
                area_index_f = am_td:get_field("mAreaIndex")
                level_path_f =
                    am_td:get_field("CurrentLevelPath")
                    or am_td:get_field("<CurrentLevelPath>k__BackingField")
            end
        end
    end

    return am_instance
end

local function get_area_info()
    local am = ensure_area_manager()
    if am == nil then
        if not am_warned then
            log("WARN: AreaManager singleton not available.")
            am_warned = true
        end
        return nil, nil
    end

    local area_index = nil
    local level_path = nil

    if area_index_f ~= nil then
        local ok_ai, v = pcall(area_index_f.get_data, area_index_f, am)
        if ok_ai and v ~= nil then
            area_index = any_to_int(v)
        end
    end

    if level_path_f ~= nil then
        local ok_lp, v = pcall(level_path_f.get_data, level_path_f, am)
        if ok_lp and v ~= nil then
            level_path = tostring(v)
        end
    else
        local ok_prop, v = pcall(sdk.call_object_func, am, "get_CurrentLevelPath")
        if ok_prop and v ~= nil then
            level_path = tostring(v)
        end
    end

    return area_index, level_path
end

------------------------------------------------------------
-- AreaHitLayoutManager (hit resources)
------------------------------------------------------------

local AreaHitLayoutManager_TYPE_NAME = "app.solid.gamemastering.AreaHitLayoutManager"

local ahlm_instance          = nil
local ahlm_td                = nil
local mAreaHitResource_field = nil
local ahlm_warned            = false

local function reset_ahlm_cache()
    ahlm_td                = nil
    mAreaHitResource_field = nil
    ahlm_warned            = false
end

local function ensure_area_hit_layout_manager()
    local current = sdk.get_managed_singleton(AreaHitLayoutManager_TYPE_NAME)

    if current ~= ahlm_instance then
        ahlm_instance = current
        reset_ahlm_cache()

        if current ~= nil then
            ahlm_td = sdk.find_type_definition(AreaHitLayoutManager_TYPE_NAME)
            if ahlm_td ~= nil then
                mAreaHitResource_field =
                    ahlm_td:get_field("mAreaHitResource")
                    or ahlm_td:get_field("<mAreaHitResource>k__BackingField")
            end
        end
    end

    return ahlm_instance
end

local function get_areahit_resource_list()
    local mgr = ensure_area_hit_layout_manager()
    if mgr == nil then
        if not ahlm_warned then
            log("WARN: AreaHitLayoutManager singleton not available.")
            ahlm_warned = true
        end
        return nil
    end

    if mAreaHitResource_field == nil then
        if not ahlm_warned then
            log("WARN: AreaHitLayoutManager has no mAreaHitResource field.")
            ahlm_warned = true
        end
        return nil
    end

    local ok, list = pcall(mAreaHitResource_field.get_data, mAreaHitResource_field, mgr)
    if not ok then
        return nil
    end

    return list
end

------------------------------------------------------------
-- HitData patch tracking (per LayoutInfo)
------------------------------------------------------------

local HITDATA_PATCHES = {}

local function disable_hitdata(layout_info, hitdata)
    if not layout_info or not hitdata then return false end

    local ok_get, cur = pcall(hitdata.get_field, hitdata, "Disabled")
    if not ok_get then
        log("      [HitData] Failed to get 'Disabled': " .. tostring(cur))
        return false
    end

    local patch = HITDATA_PATCHES[layout_info]
    if not patch then
        patch = {}
        HITDATA_PATCHES[layout_info] = patch
    end

    if cur == true then
        return false
    end

    local ok_set, err = pcall(hitdata.set_field, hitdata, "Disabled", true)
    if not ok_set then
        log("      [HitData] Failed to set 'Disabled' true: " .. tostring(err))
        return false
    end

    log("      [HitData] Disabled -> true")
    patch.disabled = true
    return true
end

local function enable_hitdata(layout_info, hitdata)
    if not layout_info or not hitdata then return false end

    local ok_get, cur = pcall(hitdata.get_field, hitdata, "Disabled")
    if not ok_get then
        log("      [HitData] Failed to get 'Disabled' for unlock: " .. tostring(cur))
        return false
    end

    if cur == false then
        return false
    end

    local ok_set, err = pcall(hitdata.set_field, hitdata, "Disabled", false)
    if not ok_set then
        log("      [HitData] Failed to set 'Disabled' false: " .. tostring(err))
        return false
    end

    log("      [HitData] Disabled -> false")
    HITDATA_PATCHES[layout_info] = nil
    return true
end

------------------------------------------------------------
-- Core: scan current area, toggle mHitData.Disabled for locked scenes
------------------------------------------------------------

local function rescan_current_area_doors()
    local area_index, level_path = get_area_info()
    log(string.format(
        "Rescanning doors for area_index=%s level_path=%s",
        tostring(area_index), tostring(level_path)
    ))

    local res_list = get_areahit_resource_list()
    if res_list == nil then
        log("No AreaHitResource list; abort scan.")
        return
    end

    local res_count = get_list_count(res_list)
    if res_count <= 0 then
        log("mAreaHitResource is empty; nothing to scan.")
        return
    end

    log(string.format("Found %d AreaHitResource entries.", res_count))

    for r_i = 0, res_count - 1 do
        local res = get_list_item(res_list, r_i)
        if res ~= nil then
            local file_val, _ = get_field_value(res, {
                "file", "<file>k__BackingField",
                "mName", "<mName>k__BackingField",
                "Name", "<Name>k__BackingField",
            })
            local list_name = file_val and tostring(file_val) or "<unknown>"

            local pResource_val, _ = get_field_value(res, {
                "pResource", "<pResource>k__BackingField",
            })
            if pResource_val ~= nil then
                local pRes    = pResource_val
                local pRes_td = pRes:get_type_definition()
                if pRes_td ~= nil and pRes_td:get_full_name() == "app.solid.gamemastering.rAreaHitLayout" then
                    local layout_list_val, _ = get_field_value(pRes, {
                        "mpLayoutInfoList", "<mpLayoutInfoList>k__BackingField",
                    })
                    if layout_list_val ~= nil then
                        local layout_count = get_list_count(layout_list_val)
                        if layout_count > 0 then
                            log(string.format(
                                "  Scanning '%s' (%d LayoutInfos)",
                                list_name, layout_count
                            ))

                            for li_i = 0, layout_count - 1 do
                                local ok_item, li = pcall(sdk.call_object_func, layout_list_val, "get_Item", li_i)
                                if ok_item and li ~= nil then
                                    local jump_name, _ = get_field_value(li, {
                                        "AREA_JUMP_NAME", "<AREA_JUMP_NAME>k__BackingField",
                                    })
                                    jump_name = jump_name and tostring(jump_name) or ""

                                    local mHitData_val, _ = get_field_value(li, {
                                        "mHitData", "<mHitData>k__BackingField",
                                    })

                                    if mHitData_val ~= nil then
                                        local hitdata = mHitData_val

                                        if jump_name ~= "" then
                                            local locked = scene_is_locked(jump_name)

                                            if locked then
                                                local info = SCENE_INFO[jump_name]
                                                local desc = info
                                                    and (info.name .. " (idx=" .. info.index .. ")")
                                                    or "<unknown>"
                                                log(string.format(
                                                    "    LayoutInfo[%d] in '%s' jumps to '%s' (%s) -> LOCKED; setting HitData.Disabled = true.",
                                                    li_i, list_name, jump_name, desc
                                                ))
                                                disable_hitdata(li, hitdata)
                                            else
                                                -- FORCE unlock: set Disabled = false
                                                -- Disabled logging when doors are unlocked
                                                --log(string.format(
                                                --    "    LayoutInfo[%d] in '%s' jumps to '%s' -> UNLOCKED; setting HitData.Disabled = false.",
                                                --    li_i, list_name, jump_name
                                                --))
                                                enable_hitdata(li, hitdata)
                                            end
                                        else
                                            if HITDATA_PATCHES[li] ~= nil then
                                                log(string.format(
                                                    "    LayoutInfo[%d] in '%s' has no jump_name; forcing HitData.Disabled = false.",
                                                    li_i, list_name
                                                ))
                                                enable_hitdata(li, hitdata)
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
-- Public API
------------------------------------------------------------

function M.lock_scene(scene_code)
    scene_code = tostring(scene_code)
    LOCKED_SCENES[scene_code] = true

    local info = SCENE_INFO[scene_code]
    if info then
        log(string.format("Scene '%s' (%s, index=%d) marked LOCKED.",
            scene_code, info.name, info.index))
    else
        log(string.format("Scene '%s' marked LOCKED.", scene_code))
    end

    rescan_current_area_doors()
end

function M.unlock_scene(scene_code)
    scene_code = tostring(scene_code)
    LOCKED_SCENES[scene_code] = nil

    local info = SCENE_INFO[scene_code]
    if info then
        log(string.format("Scene '%s' (%s, index=%d) marked UNLOCKED.",
            scene_code, info.name, info.index))
    else
        log(string.format("Scene '%s' marked UNLOCKED.", scene_code))
    end

    rescan_current_area_doors()
end

function M.is_scene_locked(scene_code)
    return scene_is_locked(tostring(scene_code))
end

-- Optional helper if you ever want to bulk-set from AP data
function M.set_locked_scenes(map)
    LOCKED_SCENES = map or {}
    rescan_current_area_doors()
end

------------------------------------------------------------
-- Area change detection (central on_frame will call this)
------------------------------------------------------------

local last_area_index = nil
local last_level_path = nil

function M.on_frame()
    local area_index, level_path = get_area_info()
    if area_index ~= nil and level_path ~= nil then
        if area_index ~= last_area_index or level_path ~= last_level_path then
            log(string.format(
                "Area change: %s (%s) -> %s (%s)",
                tostring(last_area_index), tostring(last_level_path),
                tostring(area_index), tostring(level_path)
            ))
            last_area_index = area_index
            last_level_path = level_path

            rescan_current_area_doors()
        end
    end
end

log("Module loaded. Tracking doors with AreaManager.mAreaIndex and locking/unlocking with mAreaHitResource.HitData.disable.")

return M