-- DRAP/DoorSceneLock.lua
-- Disables doors by toggling HIT_DATA.mHitData.Disabled for locked scenes

local Shared = require("DRAP/Shared")

local M = Shared.create_module("DoorSceneLock")
local testing_mode = false

------------------------------------------------------------
-- Singleton Managers
------------------------------------------------------------

local am_mgr   = M:add_singleton("am", "app.solid.gamemastering.AreaManager")
local ahlm_mgr = M:add_singleton("ahlm", "app.solid.gamemastering.AreaHitLayoutManager")

------------------------------------------------------------
-- Scene Metadata
------------------------------------------------------------

local SCENE_INFO = {
    s140 = { name = "Title Screen",             index = 292  },
    s135 = { name = "Helipad",                  index = 287  },
    s136 = { name = "Safe Room",                index = 288  },
    s231 = { name = "Rooftop",                  index = 535  },
    s230 = { name = "Service Hallway",          index = 534  },
    s200 = { name = "Paradise Plaza",           index = 512  },
    s503 = { name = "Colby's Movie Theater",    index = 1283 },
    s700 = { name = "Leisure Park",             index = 1792 },
    s400 = { name = "North Plaza",              index = 1024 },
    s501 = { name = "Crislip's Hardware Store", index = 1281 },
    sa00 = { name = "Food Court",               index = 2560 },
    s300 = { name = "Wonderland Plaza",         index = 768  },
    s900 = { name = "Al Fresca Plaza",          index = 2304 },
    s100 = { name = "Entrance Plaza",           index = 256  },
    s500 = { name = "Grocery Store",            index = 1280 },
    s600 = { name = "Maintenance Tunnel",       index = 1536 },
    s401 = { name = "Hideout",                  index = 1025 },
}

------------------------------------------------------------
-- Lock State
------------------------------------------------------------

local LOCKED_SCENES = {
    ["s140"] = false,
    ["s135"] = false,
    ["s136"] = false,
    ["s231"] = true,
    ["s230"] = true,
    ["s200"] = true,
    ["s503"] = true,
    ["s700"] = true,
    ["s400"] = true,
    ["s501"] = true,
    ["sa00"] = true,
    ["s300"] = true,
    ["s900"] = true,
    ["s500"] = true,
    ["s100"] = true,
    ["s600"] = true,
    ["s401"] = true,
}

------------------------------------------------------------
-- Public State
------------------------------------------------------------

M.CurrentLevelPath = nil
M.CurrentAreaIndex = nil

------------------------------------------------------------
-- Internal State
------------------------------------------------------------

local HITDATA_PATCHES = {}
local last_area_index = nil
local last_level_path = nil
local pending_rescan = false

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function scene_is_locked(scene_code)
    if testing_mode then return false end
    return LOCKED_SCENES[scene_code] == true
end

local function current_event_blocks_s100_lock()
    local ev = ""
    if AP and AP.EventTracker and AP.EventTracker.CURRENT_EVENT_NAME then
        ev = tostring(AP.EventTracker.CURRENT_EVENT_NAME)
    end

    if M.CurrentLevelPath == "SCN_s136" then
        if string.find(ev, "EVENT01", 1, true) then return true, ev end
        if string.find(ev, "EVENT04", 1, true) then return true, ev end
        if string.find(ev, "EVENT06", 1, true) then return true, ev end
        if string.find(ev, "EVENT_NONE", 1, true) then return true, ev end
    end
    return false, ev
end

local function get_area_info()
    local am = am_mgr:get()
    if not am then return nil, nil end

    local area_index = nil
    local level_path = nil

    local area_index_f = am_mgr:get_field("mAreaIndex", false)
    if area_index_f then
        local v = Shared.safe_get_field(am, area_index_f)
        if v then area_index = Shared.to_int(v) end
    end

    local level_path_f = am_mgr:get_field("CurrentLevelPath", false) or
                         am_mgr:get_field("<CurrentLevelPath>k__BackingField", false)
    if level_path_f then
        local v = Shared.safe_get_field(am, level_path_f)
        if v then level_path = tostring(v) end
    else
        local ok, v = pcall(sdk.call_object_func, am, "get_CurrentLevelPath")
        if ok and v then level_path = tostring(v) end
    end

    return area_index, level_path
end

------------------------------------------------------------
-- HitData Patching
------------------------------------------------------------

local function disable_hitdata(layout_info, hitdata)
    if not layout_info or not hitdata then return false end

    local ok_get, cur = pcall(hitdata.get_field, hitdata, "Disabled")
    if not ok_get then return false end
    if cur == true then return false end

    local ok_set = pcall(hitdata.set_field, hitdata, "Disabled", true)
    if not ok_set then return false end

    HITDATA_PATCHES[layout_info] = { disabled = true }
    return true
end

local function enable_hitdata(layout_info, hitdata)
    if not layout_info or not hitdata then return false end

    local ok_get, cur = pcall(hitdata.get_field, hitdata, "Disabled")
    if not ok_get then return false end
    if cur == false then return false end

    local ok_set = pcall(hitdata.set_field, hitdata, "Disabled", false)
    if not ok_set then return false end

    HITDATA_PATCHES[layout_info] = nil
    return true
end

------------------------------------------------------------
-- Door Scanning
------------------------------------------------------------

local function rescan_current_area_doors()
    local area_index, level_path = get_area_info()
    M.CurrentLevelPath = level_path
    M.CurrentAreaIndex = area_index
    local bypass_s100, ev = current_event_blocks_s100_lock()

    local ahlm = ahlm_mgr:get()
    if not ahlm then return end

    local res_field = ahlm_mgr:get_field("mAreaHitResource", false) or
                      ahlm_mgr:get_field("<mAreaHitResource>k__BackingField", false)
    if not res_field then return end

    local res_list = Shared.safe_get_field(ahlm, res_field)
    if not res_list then return end

    for r_i, res in Shared.iter_collection(res_list) do
        if res then
            local pResource_val = Shared.get_field_value(res, {"pResource", "<pResource>k__BackingField"})
            if pResource_val then
                local pRes = pResource_val
                local pRes_td = pRes:get_type_definition()

                if pRes_td and pRes_td:get_full_name() == "app.solid.gamemastering.rAreaHitLayout" then
                    local layout_list_val = Shared.get_field_value(pRes, {"mpLayoutInfoList", "<mpLayoutInfoList>k__BackingField"})

                    if layout_list_val then
                        for li_i, li in Shared.iter_collection(layout_list_val) do
                            if li then
                                local jump_name = Shared.get_field_value(li, {"AREA_JUMP_NAME", "<AREA_JUMP_NAME>k__BackingField"})
                                jump_name = jump_name and tostring(jump_name) or ""

                                local event_name = Shared.get_field_value(li, {"EVENT_NAME", "<EVENT_NAME>k__BackingField"})
                                event_name = event_name and tostring(event_name) or ""

                                local mHitData_val = Shared.get_field_value(li, {"mHitData", "<mHitData>k__BackingField"})

                                -- Special case for Food Court
                                if jump_name == "" and event_name == "evm12" then
                                    jump_name = "sa00"
                                end

                                if mHitData_val and jump_name ~= "" then
                                    local locked = scene_is_locked(jump_name)

                                    if locked and jump_name == "s100" and bypass_s100 then
                                        enable_hitdata(li, mHitData_val)
                                    elseif locked then
                                        disable_hitdata(li, mHitData_val)
                                    else
                                        enable_hitdata(li, mHitData_val)
                                    end
                                elseif mHitData_val and HITDATA_PATCHES[li] then
                                    enable_hitdata(li, mHitData_val)
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
    -- Try to rescan now, but also flag for retry if managers aren't ready
    pending_rescan = true
    rescan_current_area_doors()
end

function M.unlock_scene(scene_code)
    scene_code = tostring(scene_code)
    LOCKED_SCENES[scene_code] = nil
    -- Try to rescan now, but also flag for retry if managers aren't ready
    pending_rescan = true
    rescan_current_area_doors()
end

function M.is_scene_locked(scene_code)
    return scene_is_locked(tostring(scene_code))
end

function M.is_on_title_screen()
    return M.CurrentLevelPath == "SCN_s140"
end

function M.set_testing_mode(enabled)
    testing_mode = enabled == true
    M.log("Testing mode " .. (testing_mode and "enabled" or "disabled"))
    rescan_current_area_doors()
end

function M.get_testing_mode()
    return testing_mode
end

------------------------------------------------------------
-- Per-frame Update
------------------------------------------------------------

function M.on_frame()
    local area_index, level_path = get_area_info()
    if area_index and level_path then
        local area_changed = (area_index ~= last_area_index or level_path ~= last_level_path)

        if area_changed or pending_rescan then
            last_area_index = area_index
            last_level_path = level_path
            rescan_current_area_doors()
            -- Only clear pending if we successfully have managers
            if ahlm_mgr:get() then
                pending_rescan = false
            end
        end
    end
end

------------------------------------------------------------
-- REFramework UI
------------------------------------------------------------

re.on_draw_ui(function()
    if imgui.tree_node("DRAP: DoorSceneLock") then
        local changed, new_val = imgui.checkbox("Testing Mode (Unlock All Doors)", testing_mode)
        if changed then
            M.set_testing_mode(new_val)
        end

        -- Display current area info
        if M.CurrentLevelPath then
            imgui.text("Current Level: " .. tostring(M.CurrentLevelPath))
        end
        if M.CurrentAreaIndex then
            imgui.text("Area Index: " .. tostring(M.CurrentAreaIndex))
        end

        -- Display locked scenes
        if imgui.tree_node("Locked Scenes") then
            for code, info in pairs(SCENE_INFO) do
                local locked = LOCKED_SCENES[code] == true
                local status = locked and "[LOCKED]" or "[UNLOCKED]"
                imgui.text(string.format("%s %s (%s)", status, info.name, code))
            end
            imgui.tree_pop()
        end

        imgui.tree_pop()
    end
end)

return M