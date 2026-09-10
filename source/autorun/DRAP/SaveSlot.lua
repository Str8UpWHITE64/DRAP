-- DRAP/SaveSlot.lua
-- AP-aware save mount redirect: gives each slot/seed its own save tree via
-- via.storage.saveService.SaveService.set_SaveMountPath.
--
-- Vanilla saves go through Steam remote storage, which caps this game at
-- 30 files across everything under userdata/<id>/2527390/remote, Cloud
-- sync on or off. Each seed's folder spent one file per slot plus its
-- autosave, so a few seeds on top of a full vanilla folder hit the cap and
-- every save that had to create a file was refused (result 51,
-- Failed_Steam_SaveError). Measured 2026-09-10.
--
-- The service has a second backend: with ForceWindows set it writes the
-- mount path as a plain directory under the game folder and Steam never
-- sees it. Under a redirect this module switches it on, so AP saves live
-- in <game>/AP_Saves/<slot>_s<seed>/ with no cap and no cloud sync, one
-- folder players can find and clean out; it is switched off again
-- whenever the mount goes back to vanilla. Saves a seed made under the
-- old layout stay in Steam's win64_save_AP_* folders; the README says
-- how to copy them over by hand.

local Shared = require("DRAP/Shared")

local M = Shared.create_module("SaveSlot")

------------------------------------------------------------
-- Configuration
------------------------------------------------------------

local SaveService_TYPE_NAME = "via.storage.saveService.SaveService"
local BASE_SAVE_MOUNT = "./win64_save"
local AP_SAVE_ROOT = "./AP_Saves"          -- under the game folder

------------------------------------------------------------
-- Internal State
------------------------------------------------------------

local init_cleanup_done = false
local redirect_active = false
local pending_space_report = false

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

--- "<slot>_s<seed>": the seed's folder name under AP_Saves.
local function seed_folder_name(slot_name, seed)
    local safe_slot = Shared.sanitize_token(slot_name)
    local safe_seed = Shared.sanitize_token(seed)
    local seed_part = (safe_seed ~= "" and safe_seed ~= "nil") and ("_s" .. safe_seed) or ""
    return safe_slot .. seed_part
end

local function build_redirect_path(slot_name, seed)
    return AP_SAVE_ROOT .. "/" .. seed_folder_name(slot_name, seed)
end

-- Old-layout mounts (_AP_) count too: the engine persists the mount path
-- across launches, so one from a previous version can still be live.
local function is_redirected_mount(path)
    return path:find("AP_Saves", 1, true) ~= nil or path:find("_AP_", 1, true) ~= nil
end

local function get_service()
    return sdk.get_managed_singleton(SaveService_TYPE_NAME)
        or sdk.get_native_singleton(SaveService_TYPE_NAME)
end

-- The service is a native singleton: methods go through the type
-- definition, never svc:call.
local function svc_call(name, ...)
    local td = sdk.find_type_definition(SaveService_TYPE_NAME)
    local svc = get_service()
    local m = td and td:get_method(name)
    if not (svc and m) then return nil, "no " .. name end
    local args = table.pack(...)
    local ok, v = pcall(function() return m:call(svc, table.unpack(args, 1, args.n)) end)
    if not ok then return nil, v end
    return v
end

--- Select the save backend: true = plain files under the game folder,
--- false = Steam remote storage (vanilla). Logged only when it changes.
local function set_force_windows(flag)
    flag = flag and true or false
    local before = svc_call("get_ForceWindows")
    if before == flag then return true end
    local _, err = svc_call("set_ForceWindows", flag)
    local after = svc_call("get_ForceWindows")
    M.log(string.format("ForceWindows %s -> %s%s", tostring(before), tostring(after),
        err and (" (error: " .. tostring(err) .. ")") or ""))
    return after == flag
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

    local set_mount_m = td:get_method("set_SaveMountPath")
    if not set_mount_m then
        M.log("Missing set_SaveMountPath on SaveService.")
        return false
    end

    local new_mount = build_redirect_path(slot_name, seed)

    -- Plain-file backend before the mount, so the new path is created
    -- under the game folder and never through Steam.
    set_force_windows(true)

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
    -- The storage layer's space and error figures after the redirect, so a
    -- connect log shows the mount's state without waiting for a failure.
    -- Read on the next frame, not inside the slot-connected callback: the
    -- readout froze a connect from there (2026-09-10).
    pending_space_report = true
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

    set_force_windows(false)

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
    if is_redirected_mount(current_path_str) then
        M.log("Detected stale AP redirect on load: " .. current_path_str)
        if M.clear_redirect() then
            M.log("Cleaned up stale redirect.")
        end
    elseif svc_call("get_ForceWindows") == true then
        M.log("Detected stale ForceWindows on load; vanilla saves go through Steam.")
        set_force_windows(false)
    end

    init_cleanup_done = true
end

function M.on_frame()
    if not init_cleanup_done then
        pcall(try_init_cleanup)
    end
    if pending_space_report then
        pending_space_report = false
        local diag = AP and AP.SaveDiagnostics
        if diag and diag.space_lines then
            local ok, lines = pcall(diag.space_lines)
            if ok then
                for _, ln in ipairs(lines) do M.log("after redirect:" .. ln) end
            end
        end
    end
end

return M
