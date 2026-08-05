-- DRAP/trackers/AchievementTracker.lua
-- Turns in-game achievement pop-ups into AP location checks.
--
-- ChallengeTracker polls counted SolidSave fields; achievements instead fire
-- their own event, and SolidAchievementManager.Unlock is the one point every
-- unlock passes through. Verified in game that it still fires when the Steam
-- account already owns the achievement -- an account-guarded call site would
-- have left these checks unobtainable for returning players.

local Shared = require("DRAP/Shared")

local M = Shared.create_module("AchievementTracker")

------------------------------------------------------------
-- Configuration
------------------------------------------------------------

local SAM_TYPE = "app.solid.SolidAchievementManager"
local CHALLENGE_ENUM = "app.solid.gamemastering.ChallengeManager.Challenge"

local UNLOCK_SIG = "Unlock(app.solid.gamemastering.ChallengeManager.Challenge, "
    .. "System.Single, "
    .. "System.Action`2<via.network.Error,via.network.achievements.Info>)"

-- Challenge enum name -> AP location name. Keyed by NAME, never by the raw
-- int: the values are resolved from the enum at load so a game patch that
-- renumbers them can't silently point a check at the wrong achievement.
local ACHIEVEMENT_LOCATIONS = {
    WelcomeToHell   = "Welcome to Hell",
    PhotoJournalist = "Photojournalist",
}

------------------------------------------------------------
-- State
------------------------------------------------------------

local by_value = {}          -- challenge int -> AP location name
local hook_installed = false
local resolve_failed = false

--- Assigned by AP_DRDR_main.lua; called with the AP location name.
M.on_location_earned = nil

------------------------------------------------------------
-- Enum resolution
------------------------------------------------------------

-- Enum constants are static fields carrying their own value.
local function resolve_enum()
    local td = sdk.find_type_definition(CHALLENGE_ENUM)
    if not td then return false end
    local fields = td:get_fields()
    if not fields then return false end

    local found = 0
    for _, field in ipairs(fields) do
        local ok_name, name = pcall(field.get_name, field)
        if ok_name and name and ACHIEVEMENT_LOCATIONS[name] then
            local static = false
            pcall(function() static = field:is_static() end)
            if static then
                local value = nil
                pcall(function() value = field:get_data(nil) end)
                local v = value and (tonumber(value) or tonumber(tostring(value)))
                if v then
                    by_value[v] = ACHIEVEMENT_LOCATIONS[name]
                    found = found + 1
                    M.log(string.format("Mapped challenge %s (%d) -> %s",
                        name, v, ACHIEVEMENT_LOCATIONS[name]))
                end
            end
        end
    end

    local wanted = 0
    for _ in pairs(ACHIEVEMENT_LOCATIONS) do wanted = wanted + 1 end
    if found < wanted then
        M.log.error(string.format(
            "Only resolved %d of %d achievement challenges; the rest will never fire",
            found, wanted))
    end
    return found > 0
end

------------------------------------------------------------
-- Hook
------------------------------------------------------------

local function install_hook()
    local td = sdk.find_type_definition(SAM_TYPE)
    if not td then return false end
    local m = td:get_method(UNLOCK_SIG)
    if not m then
        M.log.error("SolidAchievementManager.Unlock not found")
        resolve_failed = true
        return false
    end

    local pending = nil
    local ok, err = pcall(sdk.hook, m,
        function(args)
            -- args[1] vmctx, args[2] this, args[3] the challenge id.
            local v = nil
            pcall(function() v = sdk.to_int64(args[3]) end)
            pending = v and tonumber(v) or nil
        end,
        function(retval)
            local loc = pending and by_value[pending] or nil
            pending = nil
            if loc and M.on_location_earned then
                M.log(string.format("Achievement unlocked -> %s", loc))
                pcall(M.on_location_earned, loc)
            end
            return retval
        end)

    if not ok then
        M.log.error("hook install failed: " .. tostring(err))
        resolve_failed = true
        return false
    end
    M.log("Hook on SolidAchievementManager.Unlock installed.")
    return true
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

-- The achievement types aren't loaded at script load, so setup retries on
-- frame until they are.
function M.on_frame()
    if hook_installed or resolve_failed then return end
    if next(by_value) == nil then
        if not resolve_enum() then return end
    end
    hook_installed = install_hook()
end

function M.is_ready() return hook_installed end

------------------------------------------------------------
-- Console
------------------------------------------------------------

_G.drap_achievements_status = function()
    M.log(string.format("hook=%s", tostring(hook_installed)))
    for value, loc in pairs(by_value) do
        M.log(string.format("  challenge %d -> %s", value, loc))
    end
end

return M
