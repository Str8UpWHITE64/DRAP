-- DRAP/SaveSlot.lua
-- AP-aware Save Mount Redirect: per-slot/per-seed save tree via
-- via.storage.saveService.SaveService.set_SaveMountPath.
-- See docs/reframework/features/save_slot.md for the full mechanism
-- (including the B4 accumulated-folders bug and the bidirectional swap).

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
-- Auto-prune accumulated AP redirect folders (BACKLOG B4 fix).
-- Mechanism is fully documented in save_slot.md; the short version
-- is that >N win64_save_AP_* folders sitting in remote/ break the
-- engine's storage init, so we keep at most one (the active slot).
------------------------------------------------------------

local DRDR_APP_ID = "2527390"

-- Capture stdout of a cmd.exe-invoked command as a trimmed string, or
-- nil on failure/empty.
local function _run_capture(cmd)
    local handle = io.popen(cmd .. " 2>nul")
    if not handle then return nil end
    local out = handle:read("*a") or ""
    handle:close()
    out = out:gsub("^%s+", ""):gsub("%s+$", "")
    if out == "" then return nil end
    return out
end

-- Read Steam install path from the Windows registry via PowerShell.
-- Returns forward-slashed path (e.g. "C:/Program Files (x86)/Steam") or nil.
-- Tries the 32-bit Wow6432Node hive first since Steam usually installs there.
local function _detect_steam_install()
    local ps = [[powershell -NoProfile -Command "(Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction SilentlyContinue).InstallPath"]]
    local out = _run_capture(ps)
    if out then return out:gsub("\\", "/") end
    ps = [[powershell -NoProfile -Command "(Get-ItemProperty 'HKLM:\SOFTWARE\Valve\Steam' -ErrorAction SilentlyContinue).InstallPath"]]
    out = _run_capture(ps)
    if out then return out:gsub("\\", "/") end
    return nil
end

-- Locate the active Steam user's DR-DR `remote/` folder. Picks the user
-- whose <APP_ID>/remote subfolder has the most recent LastWriteTime.
local function _find_userdata_remote()
    local steam = _detect_steam_install()
    if not steam then
        M.log("could not detect Steam install path from registry")
        return nil
    end
    local userdata = steam .. "/userdata"

    local ps = string.format(
        [[powershell -NoProfile -Command "Get-ChildItem '%s' -Directory ^| ForEach-Object { $p = Join-Path $_.FullName '%s/remote'; if (Test-Path $p) { [PSCustomObject]@{Path=$p; Time=(Get-Item $p).LastWriteTime} } } ^| Sort-Object Time -Descending ^| Select-Object -First 1 -ExpandProperty Path"]],
        userdata, DRDR_APP_ID)
    local remote = _run_capture(ps)
    if remote then return remote:gsub("\\", "/") end
    M.log("no DR-DR userdata/remote folder found under " .. userdata)
    return nil
end

-- Win-style backslashed path for cmd.exe consumption.
local function _w(p) return (p:gsub("/", "\\")) end

local function _rmdir_if_exists(path)
    local p = _w(path)
    return os.execute(string.format(
        'if exist "%s" (rmdir /S /Q "%s") else (exit /b 0)', p, p))
end

-- Pre-delete of dst is critical: Windows `move` won't overwrite a
-- non-empty target directory; without it the swap silently no-ops.
local function _move_dir(src, dst)
    _rmdir_if_exists(dst)
    return os.execute(string.format('move "%s" "%s" >nul 2>&1',
        _w(src), _w(dst)))
end

local function _move_named(src_root, dst_root, name)
    local src = src_root .. "/" .. name
    local dst = dst_root .. "/" .. name
    local exists = os.execute(string.format('dir /B /AD "%s" >nul 2>&1', _w(src)))
    if not exists then return false end
    return _move_dir(src, dst)
end

-- Bidirectional swap between `remote/` and `remote/_DRAP_AP_ARCHIVE/`:
-- restore the active run's archived folder if present, then archive every
-- other win64_save_AP_* folder. Leaves remote/ with exactly one AP folder.
-- Full algorithm + rationale in save_slot.md.
function M.prune_old_ap_folders(current_mount_path)
    local current_name = current_mount_path
        and current_mount_path:match("([^/\\]+)$")
        or nil
    if not current_name or not current_name:match("^win64_save_AP_") then
        M.log("prune skipped (no valid current mount path)")
        return false
    end

    local remote = _find_userdata_remote()
    if not remote then
        M.log("prune skipped (could not detect Steam userdata remote)")
        return false
    end
    M.log("scanning " .. remote)

    local archive = remote .. "/_DRAP_AP_ARCHIVE"
    -- Ensure archive root exists (idempotent)
    os.execute(string.format('mkdir "%s" 2>nul', _w(archive)))

    -- STEP 1: restore the current run's folder from archive if archived.
    local restored = false
    do
        local arch_path = archive .. "/" .. current_name
        local arch_exists = os.execute(string.format(
            'dir /B /AD "%s" >nul 2>&1', _w(arch_path)))
        if arch_exists then
            local ok = _move_dir(arch_path, remote .. "/" .. current_name)
            if ok then
                restored = true
                M.log("restored from archive: " .. current_name)
            else
                M.log("FAILED to restore: " .. current_name)
            end
        end
    end

    -- STEP 2: archive every OTHER win64_save_AP_* folder in remote.
    local list = _run_capture(string.format(
        'dir /B /AD "%s"', _w(remote))) or ""
    local archived_count = 0
    for line in list:gmatch("[^\r\n]+") do
        if line:match("^win64_save_AP_") and line ~= current_name then
            local ok = _move_named(remote, archive, line)
            if ok then
                archived_count = archived_count + 1
                M.log("archived: " .. line)
            else
                M.log("FAILED to archive: " .. line)
            end
        end
    end

    M.log(string.format(
        "swap complete: active=%s restored=%s archived=%d",
        current_name, tostring(restored), archived_count))
    return true
end

-- Mid-session connect detection. If a save has already been loaded,
-- the engine's in-memory state is sticky to the previous mount and saves
-- will fail this session -- we warn the user to restart.
local function _is_player_in_session()
    local pm = sdk.get_managed_singleton("app.solid.PlayerManager")
    if not pm then return false end
    local ok, player = pcall(function() return pm:call("get_CurrentPlayer") end)
    return ok and player ~= nil
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

--- Applies the save redirect for a specific AP slot/seed
--- @param slot_name string The slot name
--- @param seed string The seed identifier
function M.apply_for_slot(slot_name, seed)
    redirect_active = true
    init_cleanup_done = true
    local clean_slot = Shared.sanitize_token(slot_name)
    local clean_seed = Shared.sanitize_token(seed)
    M.log("Applying redirect -> Slot: " .. clean_slot .. " | Seed: " .. clean_seed)

    -- Compute target path first so prune knows which folder to keep.
    local target_path = build_redirect_path(BASE_SAVE_MOUNT, slot_name, seed)

    -- Prune BEFORE the redirect (BACKLOG B4: too many win64_save_AP_*
    -- folders break engine storage init).
    pcall(M.prune_old_ap_folders, target_path)

    if _is_player_in_session() then
        M.log("WARNING: connecting to AP mid-session; engine state may be stale.")
        M.log("  If saves fail this session, restart DR-DR (your AP folders are clean now).")
    end

    local ok = apply_mount_redirect(slot_name, seed)
    if not ok then
        M.log("AP save mount redirect FAILED.")
    else
        M.log("AP save mount redirect OK.")
    end
end

function M.clear_redirect()
    local td = sdk.find_type_definition(SaveService_TYPE_NAME)
    if not td then
        M.log("SaveService type definition not found.")
        return false
    end

    local svc = sdk.get_managed_singleton(SaveService_TYPE_NAME)
    if not svc then
        svc = sdk.get_native_singleton(SaveService_TYPE_NAME)
    end

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

    -- Refresh the save file list so UI updates
    local upd_m = td:get_method("updateSaveFileDetailTbl")
    if upd_m then
        local ok_upd, err_upd = pcall(function()
            upd_m:call(svc)
        end)
        if ok_upd then
            M.log("Save list refreshed.")
        else
            M.log("Failed to refresh save list: " .. tostring(err_upd))
        end
    end

    return true
end

------------------------------------------------------------
-- Initialization: Reset redirect on script load
------------------------------------------------------------

local function try_init_cleanup()
    if init_cleanup_done then return end
    if redirect_active then
        init_cleanup_done = true
        return
    end

    local td = sdk.find_type_definition(SaveService_TYPE_NAME)
    if not td then return end

    local svc = sdk.get_managed_singleton(SaveService_TYPE_NAME)
    if not svc then
        svc = sdk.get_native_singleton(SaveService_TYPE_NAME)
    end
    if not svc then return end

    local get_mount_m = td:get_method("get_SaveMountPath")
    if not get_mount_m then return end

    local current_path_obj = get_mount_m:call(svc)
    local current_path_str = clean_path(current_path_obj)

    -- Check if path has an AP redirect that needs cleanup
    if current_path_str:find("_AP_", 1, true) then
        M.log("Detected stale AP redirect on load: " .. current_path_str)
        if M.clear_redirect() then
            M.log("Cleaned up stale redirect.")
        end
    end

    init_cleanup_done = true
end

------------------------------------------------------------
-- Per-frame Update (for deferred init cleanup)
------------------------------------------------------------

function M.on_frame()
    if not init_cleanup_done then
        pcall(try_init_cleanup)
    end
end

------------------------------------------------------------
-- Console helpers
------------------------------------------------------------

-- Manual prune. With no arg, reads the active mount via get_SaveMountPath
-- so it's safe to call mid-session (the active folder is preserved).
_G.drap_save_prune_old_ap_folders = function(current_mount_path)
    if not current_mount_path then
        -- Try to read the active mount from the SaveService
        local td = sdk.find_type_definition(SaveService_TYPE_NAME)
        local svc = sdk.get_managed_singleton(SaveService_TYPE_NAME)
                 or sdk.get_native_singleton(SaveService_TYPE_NAME)
        if td and svc then
            local get_mount_m = td:get_method("get_SaveMountPath")
            if get_mount_m then
                local p = get_mount_m:call(svc)
                current_mount_path = clean_path(p)
            end
        end
    end
    M.log(string.format("manual prune (keep: %s)",
        tostring(current_mount_path or "<none>")))
    M.prune_old_ap_folders(current_mount_path)
end

return M