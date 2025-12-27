--------------------------------
-- Dead Rising Deluxe Remaster - DeathLink (module)
-- Tracks player death via PlayerVitalController
-- and provides a DeathLink-compatible "kill player" trigger
-- using InGameFlowManagerBase.playerDead().
--------------------------------

local M = {}

------------------------------------------------
-- Logging
------------------------------------------------
local function log(msg)
    print("[DeathLink] " .. tostring(msg))
end

------------------------------------------------
-- Config
------------------------------------------------
local PlayerStatusManager_TYPE = "app.solid.PlayerStatusManager"
local GameManager_TYPE        = "app.solid.gamemastering.GameManager"
local InGameFlowManagerBase_TYPE = "app.solid.gamemastering.InGameFlowManagerBase"

local CHECK_INTERVAL_FRAMES = 15

------------------------------------------------
-- Internal state
------------------------------------------------
local frame_counter = 0

-- PlayerStatusManager / VitalController
local psm_singleton = nil
local psm_t = nil

-- GameManager / InGameFlowManager
local gm_singleton = nil
local gm_t = nil
local igfm_cached = nil
local igfm_cache_kind = nil
local igfm_cache_name = nil
local igfm_base_t = nil

-- Death tracking
local last_is_dead = nil
local last_is_live = nil
local has_announced_death_this_life = false

------------------------------------------------
-- Public api
------------------------------------------------
M.on_death_detected = nil
M.on_revive_detected = nil

------------------------------------------------
-- Helpers: PlayerStatusManager
------------------------------------------------
local function get_psm()
    if psm_singleton ~= nil then return psm_singleton end

    if psm_t == nil then
        psm_t = sdk.find_type_definition(PlayerStatusManager_TYPE)
        if not psm_t then return nil end
    end

    local ok, inst = pcall(sdk.get_managed_singleton, PlayerStatusManager_TYPE)
    if ok and inst then
        psm_singleton = inst
        return psm_singleton
    end

    return nil
end

local function get_vital_controller(psm)
    if not psm then return nil end

    -- Backing field
    local ok, vc = pcall(psm.get_field, psm, "<PlayerVitalController>k__BackingField")
    if ok and vc then return vc end

    -- Accessor
    if psm.get_PlayerVitalController then
        local ok2, v2 = pcall(psm.get_PlayerVitalController, psm)
        if ok2 then return v2 end
    end

    return nil
end

local function vital_is_dead(vc)
    if not vc then return nil end
    if vc.get_IsDead then
        local ok, v = pcall(vc.get_IsDead, vc)
        if ok then return v end
    end
    return nil
end

local function vital_is_live(vc)
    if not vc then return nil end
    if vc.get_IsLive then
        local ok, v = pcall(vc.get_IsLive, vc)
        if ok then return v end
    end
    return nil
end

------------------------------------------------
-- Helpers: GameManager / InGameFlowManagerBase
------------------------------------------------
local function get_gm()
    if gm_singleton ~= nil then return gm_singleton end

    if gm_t == nil then
        gm_t = sdk.find_type_definition(GameManager_TYPE)
        if not gm_t then return nil end
    end

    local ok, inst = pcall(sdk.get_managed_singleton, GameManager_TYPE)
    if ok and inst then
        gm_singleton = inst
        return gm_singleton
    end

    return nil
end

local IGFM_GETTER_METHOD = "get_MainInstance"

local function get_ingame_flow_manager()
    if igfm_cached then
        return igfm_cached
    end

    local gm = get_gm()
    if not gm then
        log("get_ingame_flow_manager: GameManager singleton is nil")
        return nil
    end

    -- Call the known getter
    local ok, v = pcall(function()
        return gm:call(IGFM_GETTER_METHOD)
    end)

    if ok and v then
        igfm_cached = v
        return igfm_cached
    end

    -- Stale / not ready yet
    igfm_cached = nil
    log("get_ingame_flow_manager: gm:call(" .. tostring(IGFM_GETTER_METHOD) .. ") failed ok=" .. tostring(ok) .. " v=" .. tostring(v))
    return nil
end

------------------------------------------------
-- Kill logic (DeathLink receive)
------------------------------------------------
function M.kill_player(reason)
    -- Avoid spamming if already dead
    local psm = get_psm()
    local vc = get_vital_controller(psm)
    if vc then
        local is_dead = vital_is_dead(vc)
        if is_dead == true then
            log("kill_player: already dead; ignoring. reason=" .. tostring(reason))
            return false
        end
    end

    local igfm = get_ingame_flow_manager()
    if not igfm then
        log("kill_player: InGameFlowManagerBase not available yet. reason=" .. tostring(reason))
        return false
    end

    if not igfm.playerDead then
        -- cache likely stale after load
        igfm_cached = nil
        log("kill_player: playerDead() not bound; cache cleared.")
        return false
    end

    local ok = pcall(igfm.playerDead, igfm)
    if ok then
        log("kill_player: playerDead() invoked. reason=" .. tostring(reason))
        return true
    end

    igfm_cached = nil
    log("kill_player: playerDead() call failed; cache cleared.")
    return false
end

------------------------------------------------
-- Death polling
------------------------------------------------
local function poll_death_state()
    local psm = get_psm()
    if not psm then return end

    local vc = get_vital_controller(psm)
    if not vc then return end

    local is_dead = vital_is_dead(vc)
    local is_live = vital_is_live(vc)

    if last_is_dead == nil and is_dead ~= nil then
        last_is_dead = is_dead
        last_is_live = is_live
        has_announced_death_this_life = (is_dead == true)
        return
    end

    -- Revive detection
    if last_is_dead == true and is_dead == false then
        has_announced_death_this_life = false
        if M.on_revive_detected then
            pcall(M.on_revive_detected)
        end
    end

    -- Death detection
    if (last_is_dead == false or last_is_dead == nil) and is_dead == true then
        if not has_announced_death_this_life then
            has_announced_death_this_life = true
            log("Detected player death.")
            if M.on_death_detected then
                pcall(M.on_death_detected)
            end
        end
    end

    last_is_dead = is_dead
    last_is_live = is_live
end

------------------------------------------------
-- Per-frame
------------------------------------------------
function M.on_frame()
    frame_counter = frame_counter + 1

    if (frame_counter % CHECK_INTERVAL_FRAMES) ~= 0 then
        return
    end

    poll_death_state()
end

return M
