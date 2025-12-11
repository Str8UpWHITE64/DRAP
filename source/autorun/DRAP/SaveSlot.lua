-- Dead Rising Deluxe Remaster - AP-aware Save Mount Redirect (module)
-- Uses via.storage.saveService.SaveService to move saves into a per-slot/per-seed tree.
--
-- Public API:
--   SaveSlot.apply_for_slot(slot_name, seed)
--
-- Example:
--   Original SaveMountPath: C:\Users\You\AppData\Local\CAPCOM\DEADRISING\
--   Slot: "DeadRising", Seed: 123456
--   New SaveMountPath:     C:\Users\You\AppData\Local\CAPCOM\DEADRISING_AP_DeadRising_s123456\
--
-- The game then uses that new mount for all save IO.
-- We also attempt to call updateSaveFileDetailTbl() so the UI updates.

local M = {}

------------------------------------------------
-- Logging
------------------------------------------------

local function log(msg)
    print("[APSaveRedirect] " .. tostring(msg))
end

------------------------------------------------
-- Config
------------------------------------------------

local SaveService_TYPE_NAME = "via.storage.saveService.SaveService"

------------------------------------------------
-- Helpers
------------------------------------------------

-- Safely convert a managed System.String to a Lua string
local function as_lua_string(obj)
    if obj == nil then return nil end

    local ok, s = pcall(sdk.to_string, obj)
    if ok and s then
        return s
    end

    return tostring(obj)
end

-- Sanitize slot name to be filesystem-friendly-ish
local function sanitize_slot_name(name)
    if not name or name == "" then
        return "slot"
    end
    name = tostring(name)
    -- replace non-alphanumeric with underscore
    name = name:gsub("[^%w]+", "_")
    -- trim leading/trailing underscores
    name = name:gsub("^_+", ""):gsub("_+$", "")
    if name == "" then
        name = "slot"
    end
    return name
end

-- Build the new mount path from original + slot + seed
local function build_new_mount(orig_mount_str, slot_name, seed)
    local trimmed = orig_mount_str:gsub("[\\/]+$", "")

    local parent, leaf = trimmed:match("^(.*[\\/])([^\\/]+)$")
    local base_leaf
    if parent and leaf then
        base_leaf = leaf
    else
        parent    = trimmed .. "\\"
        base_leaf = "DRDR"
    end

    local safe_slot = sanitize_slot_name(slot_name)
    local seed_part = seed and ("_s" .. tostring(seed)) or ""

    local new_leaf  = base_leaf .. "_AP_" .. safe_slot .. seed_part
    local new_mount = parent .. new_leaf .. "\\"

    log(("Original mount '%s' -> new mount '%s'"):format(trimmed, new_mount))
    return new_mount
end

------------------------------------------------
-- GameManager access
------------------------------------------------

-- Core function that actually changes SaveMountPath + updates save table
local function apply_mount_redirect(slot_name, seed)
    local td = sdk.find_type_definition(SaveService_TYPE_NAME)
    if not td then
        log("SaveService type definition not found; are you in-game yet?")
        return false
    end

    -- Try managed first, then native
    local svc = sdk.get_managed_singleton(SaveService_TYPE_NAME)
    if not svc then
        svc = sdk.get_native_singleton(SaveService_TYPE_NAME)
    end

    if not svc then
        log("SaveService singleton not found; are you in-game yet?")
        return false
    end

    local get_mount_m = td:get_method("get_SaveMountPath")
    local set_mount_m = td:get_method("set_SaveMountPath")

    if not get_mount_m or not set_mount_m then
        log("Missing get_SaveMountPath/set_SaveMountPath on SaveService.")
        return false
    end

    -- Read original mount
    local ok, ret = pcall(function()
        return get_mount_m:call(svc)
    end)
    if not ok or not ret then
        ok, ret = pcall(function()
            return sdk.call_native_func(svc, td, "get_SaveMountPath")
        end)
    end

    if not ok or not ret then
        log("Failed to call get_SaveMountPath.")
        return false
    end

    local orig_mount_str = as_lua_string(ret)
    if not orig_mount_str or orig_mount_str == "" then
        log("Original SaveMountPath is empty/unreadable.")
        return false
    end

    log("Original SaveMountPath: " .. orig_mount_str)

    -- Build new mount for this AP slot/seed
    local new_mount = build_new_mount(orig_mount_str, slot_name, seed)

    -- Apply new mount
    local ok_set, err = pcall(function()
        set_mount_m:call(svc, sdk.create_managed_string(new_mount))
    end)

    if not ok_set then
        log("Failed to set SaveMountPath: " .. tostring(err))
        return false
    end

    log("SaveMountPath successfully redirected.")

    -- Try to call updateSaveFileDetailTbl() if it exists, so UI refreshes
    local upd_m = td:get_method("updateSaveFileDetailTbl")
    if upd_m then
        local ok_upd, err_upd = pcall(function()
            upd_m:call(svc)
        end)
        if ok_upd then
            log("updateSaveFileDetailTbl() called successfully.")
        else
            log("updateSaveFileDetailTbl() call failed: " .. tostring(err_upd))
        end
    else
        log("updateSaveFileDetailTbl() not found; you may need to call it manually.")
    end

    return true
end

------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------

-- Call this once after you've connected and know slot/seed
function M.apply_for_slot(slot_name, seed)
    log(("Applying AP save mount for slot='%s', seed='%s'")
        :format(tostring(slot_name), tostring(seed)))
    local ok = apply_mount_redirect(slot_name, seed)
    if not ok then
        log("AP save mount redirect FAILED.")
    else
        log("AP save mount redirect OK.")
    end
end

log("AP-aware save mount redirect module loaded.")

return M