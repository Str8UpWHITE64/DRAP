-- Dead Rising Deluxe Remaster - Level Tracker (module)
-- Tracks app.solid.PlayerStatusManager.PlayerLevel changes (level ups)

local M = {}
M.on_level_changed = nil

------------------------------------------------
-- Logging
------------------------------------------------

local function log(msg)
    print("[LevelTracker] " .. tostring(msg))
end

------------------------------------------------
-- Config
------------------------------------------------

local StatusManager_TYPE_NAME = "app.solid.PlayerStatusManager"

local ps_instance          = nil   -- current PlayerStatusManager singleton
local ps_td                = nil   -- PlayerStatusManager type definition
local level_field           = nil   -- PlayerLevel field
local missing_level_warned = false

local last_level           = nil   -- last seen PlayerLevel

local last_check_time = 0
local CHECK_INTERVAL  = 1  -- seconds

------------------------------------------------
-- PlayerStatusManager access
------------------------------------------------

local function reset_ps_cache()
    ps_td                = nil
    level_field          = nil
    missing_level_warned = false
    last_level           = nil
end

local function ensure_player_status_manager()
    -- Always fetch the current singleton each frame
    local current = sdk.get_managed_singleton(StatusManager_TYPE_NAME)

    -- Detect instance changes (destroyed / recreated)
    if current ~= ps_instance then
        if ps_instance ~= nil and current == nil then
            log("PlayerStatusManager destroyed (likely title screen).")
        elseif ps_instance == nil and current ~= nil then
            log("PlayerStatusManager created (likely entering game).")
        elseif ps_instance ~= nil and current ~= nil then
            log("PlayerStatusManager instance changed (scene load?).")
        end

        ps_instance = current
        reset_ps_cache()
    end

    -- If there is no current PlayerStatusManager, we can't read anything this frame
    if not ps_instance then
        return false
    end

    -- Get type definition from the instance
    if not ps_td then
        local ok, td = pcall(function()
            return ps_instance:get_type_definition()
        end)
        if not ok or not td then
            log("Failed to get PlayerStatusManager type definition from instance.")
            return false
        end
        ps_td = td
    end


    -- Get PlayerLevel field
    if not level_field then
        local ok, f = pcall(function()
            return ps_td:get_field("PlayerLevel")
        end)
        if not ok then
            return false
        end
        level_field = f

        if not level_field then
            if not missing_level_warned then
                log("PlayerLevel field not found on PlayerStatusManager (likely title screen or wrong context).")
                missing_level_warned = true
            end
            return false
        end
    end


    return true
end

------------------------------------------------
-- Main update entrypoint
------------------------------------------------

function M.on_frame()
    -- Throttle checks to reduce performance impact
    local now = os.clock()
    if now - last_check_time < CHECK_INTERVAL then
        return
    end
    last_check_time = now

    -- Make sure we can access PlayerStatusManager and PlayerLevel
    if not ensure_player_status_manager() then
        return
    end

    -- Safely read current PlayerLevel (avoid indexing get_data outside pcall)
    local ok_lvl, current_level = pcall(function()
        return level_field:get_data(ps_instance)
    end)
    if not ok_lvl then
        return
    end


    -- First successful read for this PlayerStatusManager instance:
    if last_level == nil then
        last_level = current_level
        log(string.format("Initial PlayerLevel: %d", current_level))
        return
    end

    -- Detect changes
    if current_level ~= last_level then
        if current_level > last_level then
            local diff = current_level - last_level
            if M.on_level_changed then
                for lvl = last_level + 1, current_level do
                    log(string.format("  [AP] Processing level-up step: %d -> %d", lvl - 1, lvl))
                    pcall(M.on_level_changed, lvl - 1, lvl)
                end
            end

        elseif current_level < last_level then
            log(string.format(
                "Player level decreased (reset or debug?): %d -> %d",
                last_level, current_level
            ))
        end
        last_level = current_level
    end
end

log("Module loaded. Tracking PlayerStatusManager.PlayerLevel.")

return M