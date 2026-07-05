-- DRAP/SaveSlot.lua
-- AP-aware save mount redirect: gives each slot/seed its own save tree via
-- via.storage.saveService.SaveService.set_SaveMountPath.
--
-- Save writes go through Steam RemoteStorage, which enforces a ~200 MB
-- quota across everything under userdata/<id>/2527390/remote and rejects
-- mount paths outside it. Cleanup is manual -- see the README's
-- "Save Data and the Failed to Save Error" section.

local Shared = require("DRAP/Shared")

local M = Shared.create_module("SaveSlot")

------------------------------------------------------------
-- Configuration
------------------------------------------------------------

local SaveService_TYPE_NAME = "via.storage.saveService.SaveService"
local BASE_SAVE_MOUNT = "./win64_save"

------------------------------------------------------------
-- Internal State
------------------------------------------------------------

local init_cleanup_done = false
local redirect_active = false

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function clean_path(p)
    p = Shared.clean_string(p)
    p = p:gsub("[%c\128-\255]", "")
    p = p:gsub("\\", "/")
    p = p:gsub("/+$", "")
    return p
end

local function build_redirect_path(current_path, slot_name, seed)
    local norm_path = clean_path(current_path)

    local safe_slot = Shared.sanitize_token(slot_name)
    local safe_seed = Shared.sanitize_token(seed)

    local seed_part = (safe_seed ~= "" and safe_seed ~= "nil") and ("_s" .. safe_seed) or ""
    local folder_suffix = "_AP_" .. safe_slot .. seed_part

    if norm_path:find(folder_suffix, 1, true) then
        return norm_path
    end

    local existing_ap_idx = norm_path:find("_AP_", 1, true)
    if existing_ap_idx then
        norm_path = norm_path:sub(1, existing_ap_idx - 1):gsub("/+$", "")
    end

    return norm_path .. folder_suffix
end

local function get_service()
    return sdk.get_managed_singleton(SaveService_TYPE_NAME)
        or sdk.get_native_singleton(SaveService_TYPE_NAME)
end

-- A play session (gameplay or cutscene) holds engine save state that is
-- sticky to the mount active when it loaded.
local function _is_player_in_session()
    local pm = sdk.get_managed_singleton("app.solid.PlayerManager")
    if not pm then return false end
    local ok, player = pcall(function() return pm:call("get_CurrentPlayer") end)
    return ok and player ~= nil
end

------------------------------------------------------------
-- Core Logic
------------------------------------------------------------

local function apply_mount_redirect(slot_name, seed)
    local td = sdk.find_type_definition(SaveService_TYPE_NAME)
    if not td then
        M.log("SaveService type definition not found; are you in-game yet?")
        return false
    end

    local svc = get_service()
    if not svc then
        M.log("SaveService singleton not found; are you in-game yet?")
        return false
    end

    local get_mount_m = td:get_method("get_SaveMountPath")
    local set_mount_m = td:get_method("set_SaveMountPath")

    if not get_mount_m or not set_mount_m then
        M.log("Missing get_SaveMountPath/set_SaveMountPath on SaveService.")
        return false
    end

    local current_path_obj = get_mount_m:call(svc)
    local current_path_str = clean_path(current_path_obj)

    local new_mount = build_redirect_path(current_path_str, slot_name, seed)

    local ok_set, err = pcall(function()
        set_mount_m:call(svc, sdk.create_managed_string(new_mount))
    end)

    if not ok_set then
        M.log("Failed to set SaveMountPath: " .. tostring(err))
        return false
    end

    M.log("SaveMountPath redirected to " .. new_mount)

    -- Refresh the save file list so the UI reflects the new mount.
    local upd_m = td:get_method("updateSaveFileDetailTbl")
    if upd_m then
        pcall(function() upd_m:call(svc) end)
    end

    return true
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

-- Set on mid-session connect (saves will fail until restart). Read by
-- SaveDiagnostics' GUI tab for a persistent banner.
M.mid_session_warning = false

--- Reads the engine's current SaveMountPath (or nil).
function M.get_current_mount()
    local td = sdk.find_type_definition(SaveService_TYPE_NAME)
    local svc = get_service()
    if not td or not svc then return nil end
    local get_mount_m = td:get_method("get_SaveMountPath")
    if not get_mount_m then return nil end
    local ok, p = pcall(function() return get_mount_m:call(svc) end)
    if not ok or p == nil then return nil end
    return clean_path(p)
end

--- Applies the save redirect for a specific AP slot/seed.
function M.apply_for_slot(slot_name, seed)
    redirect_active = true
    init_cleanup_done = true
    M.log(string.format("Applying redirect -> Slot: %s | Seed: %s",
        Shared.sanitize_token(slot_name), Shared.sanitize_token(seed)))

    if _is_player_in_session() then
        -- The engine's storage state is sticky to the previous mount;
        -- every save this session will fail. Make it unmissable.
        M.mid_session_warning = true
        M.log("WARNING: connecting to AP mid-session; saves will fail until restart.")
        pcall(re.msg,
            "DRAP: Connected to Archipelago mid-game.\n"
            .. "Saving will FAIL for the rest of this session.\n"
            .. "Restart Dead Rising Deluxe Remaster, then connect from the title screen.")
    end

    if apply_mount_redirect(slot_name, seed) then
        M.log("AP save mount redirect OK.")
    else
        M.log("AP save mount redirect FAILED.")
    end
end

function M.clear_redirect()
    local td = sdk.find_type_definition(SaveService_TYPE_NAME)
    if not td then
        M.log("SaveService type definition not found.")
        return false
    end

    local svc = get_service()
    if not svc then
        M.log("SaveService singleton not found.")
        return false
    end

    local set_mount_m = td:get_method("set_SaveMountPath")
    if not set_mount_m then
        M.log("set_SaveMountPath method not found.")
        return false
    end

    local ok_set, err = pcall(function()
        set_mount_m:call(svc, sdk.create_managed_string(BASE_SAVE_MOUNT))
    end)

    if not ok_set then
        M.log("Failed to set SaveMountPath: " .. tostring(err))
        return false
    end

    M.log("SaveMountPath reset to default: " .. BASE_SAVE_MOUNT)
    redirect_active = false

    local upd_m = td:get_method("updateSaveFileDetailTbl")
    if upd_m then
        pcall(function() upd_m:call(svc) end)
    end

    return true
end

------------------------------------------------------------
-- Initialization: reset a stale redirect left by a previous session
------------------------------------------------------------

local function try_init_cleanup()
    if init_cleanup_done then return end
    if redirect_active then
        init_cleanup_done = true
        return
    end

    local td = sdk.find_type_definition(SaveService_TYPE_NAME)
    if not td then return end
    local svc = get_service()
    if not svc then return end

    local get_mount_m = td:get_method("get_SaveMountPath")
    if not get_mount_m then return end

    local current_path_str = clean_path(get_mount_m:call(svc))
    if current_path_str:find("_AP_", 1, true) then
        M.log("Detected stale AP redirect on load: " .. current_path_str)
        if M.clear_redirect() then
            M.log("Cleaned up stale redirect.")
        end
    end

    init_cleanup_done = true
end

function M.on_frame()
    if not init_cleanup_done then
        pcall(try_init_cleanup)
    end
end

return M
