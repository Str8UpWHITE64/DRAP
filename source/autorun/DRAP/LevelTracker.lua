-- DRAP/LevelTracker.lua
-- Tracks app.solid.PlayerStatusManager.PlayerLevel changes (level ups)

local Shared = require("DRAP/Shared")

local M = Shared.create_module("LevelTracker")
M:set_throttle(1.0)  -- CHECK_INTERVAL = 1 second

------------------------------------------------------------
-- Configuration
------------------------------------------------------------

local ARMED_AFTER_GAME_TIME = 11200   -- known-safe time
local BACKOFF_MAX = 5.0

------------------------------------------------------------
-- Singleton Manager
------------------------------------------------------------

local ps_mgr = M:add_singleton("ps", "app.solid.PlayerStatusManager")

------------------------------------------------------------
-- Internal State
------------------------------------------------------------

local armed = false
local next_try_at = 0.0
local backoff = 0.5
local last_level = nil

------------------------------------------------------------
-- Public Callback
------------------------------------------------------------

M.on_level_changed = nil

------------------------------------------------------------
-- Internal Helpers
------------------------------------------------------------

local function reset_state()
    last_level = nil
    armed = false
    next_try_at = 0.0
    backoff = 0.5
end

-- Reset state when singleton changes
ps_mgr.on_instance_changed = function(old, new)
    reset_state()
end

------------------------------------------------------------
-- Per-frame Update
------------------------------------------------------------

function M.on_frame()
    if not M:should_run() then return end

    local now = os.clock()

    -- Don't touch managed singletons until we're truly "in game"
    if not Shared.is_in_game() then
        reset_state()
        return
    end

    -- Arm using GAME time (much more reliable than waiting real time)
    if not armed then
        if AP and AP.TimeGate and AP.TimeGate.get_current_mdate then
            local ok, t = pcall(AP.TimeGate.get_current_mdate)
            if not ok or not t or t <= ARMED_AFTER_GAME_TIME then
                return
            end
            armed = true
            last_level = nil
            M.log("Armed after game-time gate; caches reset.")
        else
            return
        end
    end

    -- Backoff after native throws
    if now < next_try_at then
        return
    end

    -- Update singleton (may throw)
    local ok_single, ps = pcall(function()
        return ps_mgr:get()
    end)

    if not ok_single or not ps then
        next_try_at = now + backoff
        backoff = math.min(backoff * 2.0, BACKOFF_MAX)
        return
    end

    -- Get level field
    local level_field = ps_mgr:get_field("PlayerLevel")
    if not level_field then
        return
    end

    -- Read level value
    local ok_lvl, current_level = pcall(function()
        return level_field:get_data(ps)
    end)

    if not ok_lvl or type(current_level) ~= "number" then
        next_try_at = now + backoff
        backoff = math.min(backoff * 2.0, BACKOFF_MAX)
        return
    end

    -- Success: reset backoff
    backoff = 0.5
    next_try_at = 0.0

    -- First read: initialize + resend levels up to current
    if last_level == nil then
        last_level = current_level
        M.log(string.format("Initial PlayerLevel: %d", current_level))

        if M.on_level_changed then
            for lvl = 2, current_level do
                M.log(string.format("  [AP] Processing initial level-up step: %d -> %d", lvl - 1, lvl))
                pcall(M.on_level_changed, lvl - 1, lvl)
            end
        end
        return
    end

    -- Detect changes
    if current_level ~= last_level then
        if current_level > last_level then
            if M.on_level_changed then
                for lvl = last_level + 1, current_level do
                    M.log(string.format("  [AP] Processing level-up step: %d -> %d", lvl - 1, lvl))
                    pcall(M.on_level_changed, lvl - 1, lvl)
                end
            end
        elseif current_level < last_level then
            M.log(string.format("Player level decreased: %d -> %d", last_level, current_level))
        end
        last_level = current_level
    end
end

return M