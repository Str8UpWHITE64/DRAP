-- DRAP/SaveSlot.lua
-- AP-aware Save Mount Redirect
-- Uses via.storage.saveService.SaveService to move saves into a per-slot/per-seed tree.

local Shared = require("DRAP/Shared")

local M = Shared.create_module("APSaveRedirect")

------------------------------------------------------------
-- Configuration
------------------------------------------------------------

local SaveService_TYPE_NAME = "via.storage.saveService.SaveService"
local BASE_SAVE_MOUNT = "./win64_save"

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

------------------------------------------------------------
-- Core Logic
------------------------------------------------------------

local function apply_mount_redirect(slot_name, seed)
    local td = sdk.find_type_definition(SaveService_TYPE_NAME)
    if not td then
        M.log("SaveService type definition not found; are you in-game yet?")
        return false
    end

    -- Try managed first, then native
    local svc = sdk.get_managed_singleton(SaveService_TYPE_NAME)
    if not svc then
        svc = sdk.get_native_singleton(SaveService_TYPE_NAME)
    end

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

    local orig_mount_str = BASE_SAVE_MOUNT
    if not orig_mount_str or orig_mount_str == "" then
        M.log("Original SaveMountPath is empty/unreadable.")
        return false
    end

    -- Read current path
    local current_path_obj = get_mount_m:call(svc)
    local current_path_str = clean_path(current_path_obj)

    -- Build new mount for this AP slot/seed
    local new_mount = build_redirect_path(current_path_str, slot_name, seed)

    -- Apply new mount
    local ok_set, err = pcall(function()
        set_mount_m:call(svc, sdk.create_managed_string(new_mount))
    end)

    if not ok_set then
        M.log("Failed to set SaveMountPath: " .. tostring(err))
        return false
    end

    M.log("SaveMountPath successfully redirected.")

    -- Try to call updateSaveFileDetailTbl() if it exists, so UI refreshes
    local upd_m = td:get_method("updateSaveFileDetailTbl")
    if upd_m then
        local ok_upd, err_upd = pcall(function()
            upd_m:call(svc)
        end)
        if ok_upd then
            M.log("updateSaveFileDetailTbl() called successfully.")
        else
            M.log("updateSaveFileDetailTbl() call failed: " .. tostring(err_upd))
        end
    else
        M.log("updateSaveFileDetailTbl() not found; you may need to call it manually.")
    end

    return true
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

--- Applies the save redirect for a specific AP slot/seed
--- @param slot_name string The slot name
--- @param seed string The seed identifier
function M.apply_for_slot(slot_name, seed)
    local clean_slot = Shared.sanitize_token(slot_name)
    local clean_seed = Shared.sanitize_token(seed)
    M.log("Applying redirect -> Slot: " .. clean_slot .. " | Seed: " .. clean_seed)

    local ok = apply_mount_redirect(slot_name, seed)
    if not ok then
        M.log("AP save mount redirect FAILED.")
    else
        M.log("AP save mount redirect OK.")
    end
end

return M