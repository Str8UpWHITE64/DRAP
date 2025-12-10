--------------------------------
-- Dead Rising Deluxe Remaster - Time Gate (module)
-- Freezes / restores in-game time for Archipelago progression gating
--------------------------------

local M = {}

------------------------------------------------
-- Logging
------------------------------------------------
local function log(msg)
    print("[TimeGate] " .. tostring(msg))
end

------------------------------------------------
-- Config
------------------------------------------------

local GameManager_TYPE_NAME = "app.solid.gamemastering.GameManager"

local gm_instance        = nil   -- current GameManager singleton
local gm_missing_warned  = false

-- gate state
local freeze_enabled     = false -- true = time frozen
local saved_time_add     = nil   -- original mTimeAdd before freezing

------------------------------------------------
-- GameManager access
------------------------------------------------

local function ensure_game_manager()
    local current = sdk.get_managed_singleton(GameManager_TYPE_NAME)

    if current == nil then
        if not gm_missing_warned then
            log("GameManager singleton not found; timer control unavailable.")
            gm_missing_warned = true
        end
        gm_instance = nil
        return nil
    end

    if current ~= gm_instance then
        gm_instance = current
        gm_missing_warned = false
        log("GameManager singleton updated.")
    end

    return gm_instance
end

------------------------------------------------
-- Core time control
------------------------------------------------

local function apply_gate_state()
    local gm = ensure_game_manager()
    if not gm then return end

    if freeze_enabled then
        -- First time enabling: capture current speed
        if saved_time_add == nil then
            saved_time_add = gm.mTimeAdd or 30
            log(string.format("Captured current time speed: %s", tostring(saved_time_add)))
        end

        -- Force freeze
        if gm.mTimeAdd ~= 0 then
            gm.mTimeAdd = 0
            log("Time frozen (mTimeAdd set to 0).")
        end
    else
        -- Restoring original speed if we have one
        if saved_time_add ~= nil and gm.mTimeAdd ~= saved_time_add then
            gm.mTimeAdd = saved_time_add
            log(string.format("Time restored (mTimeAdd = %s).", tostring(saved_time_add)))
        end
    end
end

--------------------------------
-- Public API
--------------------------------

function M.is_enabled()
    return freeze_enabled
end

function M.enable()
    if freeze_enabled then return end
    freeze_enabled = true
    log("Gate enabled; will freeze in-game time.")
    apply_gate_state()
end

function M.disable()
    if not freeze_enabled then return end
    freeze_enabled = false
    log("Gate disabled; restoring in-game time.")
    apply_gate_state()
end

-- Convenience wrapper for boolean control
function M.set_frozen(frozen)
    if frozen then
        M.enable()
    else
        M.disable()
    end
end

--------------------------------
-- Main update entrypoint
--------------------------------

function M.on_frame()
    -- Only touch GameManager when we care about the gate, or have something to restore
    if freeze_enabled or saved_time_add ~= nil then
        apply_gate_state()
    else
        -- Keep gm_instance pointer fresh
        ensure_game_manager()
    end
end

log("Module loaded. Use M.enable/disable/set_frozen from your AP logic.")

return M