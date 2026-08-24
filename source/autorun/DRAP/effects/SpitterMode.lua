-- DRAP/effects/SpitterMode.lua
-- Spitter Only: the spit is the whole arsenal.
--
-- The apworld half already takes every weapon out of the pool and forces
-- Restricted Item Mode on, so nothing on the floor can be picked up and swung.
-- This is the other half -- the two things that are the player's state rather
-- than the seed's contents:
--
--   MELEE   floored to a percent that barely scratches a zombie. Not zero:
--           the engine's attack percent scales damage, and a value of 0 has
--           not been measured, while a small one demonstrably has (the
--           Skipped Arm Day Trap uses the same call).
--
--   SPIT    the Spitfire juice effect, kept on for the whole run.
--
-- WHY THE SPIT IS REFRESHED RATHER THAN SET ONCE: setMixJuiceTimerAll takes a
-- duration in seconds, not a flag -- there is no "on until further notice".
-- A single enormous duration would rely on the engine accepting a number no
-- normal juice ever uses, which is the sort of guess this codebase has been
-- punished for. Re-arming on a timer costs one call every REFRESH_SECONDS and
-- cannot drift out of sync with a save, a load or an area change.
--
-- The refresh interval is deliberately well under the duration, so a missed
-- frame or a loading screen cannot leave a gap the player would feel.

local Shared = require("DRAP/Shared")

local M = Shared.create_module("SpitterMode")
M:set_throttle(1.0)

local PlayerStats = require("DRAP/effects/PlayerStats")
local PlayerBuffs = require("DRAP/effects/PlayerBuffs")

-- Attack percent while the mode is on. 100 is normal, and the Skipped Arm Day
-- Trap runs at 1, so the low end of this scale is known to work.
--
-- NOT 1, on purpose, and NOT final. It is unmeasured whether the Spitfire
-- effect's damage scales with this same attack percent. If it does, flooring
-- melee floors the spit as well and the mode has no way to kill anything --
-- so this starts somewhere survivable and drap_spitter_melee() exists to find
-- the real number in game rather than guess it here.
local MELEE_FLOOR_PCT = 10

-- Spit duration to ask for, and how often to ask again. The gap between them
-- is the safety margin -- a load screen or a stalled frame has to eat more
-- than 40 seconds before the effect can lapse.
local SPIT_DURATION = 60.0
local REFRESH_SECONDS = 20.0

local enabled = false
local floor_applied = false
local next_refresh = 0

--- Turn the mode on or off. Called from the slot connect.
function M.set_enabled(on)
    enabled = (on == true)
    if not enabled then
        floor_applied = false
        return
    end
    -- The floor is applied on the first frame in game rather than here: at
    -- slot-connect time the player is usually still at the title screen and
    -- PlayerStatusManager has nothing to write to.
    floor_applied = false
    next_refresh = 0
    M.log(string.format(
        "Spitter Only on -- melee floored to %d%%, Spitfire refreshed every %.0fs",
        MELEE_FLOOR_PCT, REFRESH_SECONDS))
end

function M.is_enabled()
    return enabled
end

function M.on_frame()
    if not enabled then return end
    if not M:should_run() then return end
    if not Shared.is_in_game() then return end

    if not floor_applied then
        if PlayerStats and PlayerStats.set_melee_floor then
            PlayerStats.set_melee_floor(MELEE_FLOOR_PCT)
            floor_applied = true
            M.log(string.format("melee floored to %d%%", MELEE_FLOOR_PCT))
        end
    end

    local now = os.clock()
    if now >= next_refresh then
        next_refresh = now + REFRESH_SECONDS
        -- Played from the frame thread on purpose -- the same call from the
        -- console reports success and does nothing.
        if PlayerBuffs and PlayerBuffs.spitfire_effect then
            PlayerBuffs.spitfire_effect(SPIT_DURATION)
        end
    end
end

--- Testing: arm the mode without a server. Pairs with drap_activate_debug().
---
--- Turns Restricted Item Mode on with it, because a real seed always does:
--- the apworld forces the option, and the slot connect applies it. Without
--- that the offline test is only half the mode -- melee is floored but the
--- mall is still full of weapons to pick up and swing.
_G.drap_spitter_mode = function(on)
    on = (on ~= false)
    M.set_enabled(on)
    if _G.drap_restrict then _G.drap_restrict(on) end
    M.log("Spitter Only " .. (M.is_enabled() and "ON" or "off")
          .. " (Restricted Item Mode follows it)")
end

--- Testing: try a different melee floor without a redeploy. The point is to
--- find where melee is useless but the spit still kills.
_G.drap_spitter_melee = function(pct)
    pct = tonumber(pct)
    if not pct then
        M.log(string.format("usage: drap_spitter_melee(10)  -- currently %d",
                            MELEE_FLOOR_PCT))
        return
    end
    MELEE_FLOOR_PCT = pct
    if enabled and PlayerStats and PlayerStats.set_melee_floor then
        PlayerStats.set_melee_floor(MELEE_FLOOR_PCT)
    end
    M.log(string.format("melee floor now %d%%", MELEE_FLOOR_PCT))
end

--- Testing: what the mode currently holds, so a silent failure is visible.
_G.drap_spitter_status = function()
    M.log(string.format(
        "enabled=%s  floor applied=%s  next spit refresh in %.1fs",
        tostring(enabled), tostring(floor_applied),
        math.max(0, next_refresh - os.clock())))
    if _G.drap_stats_attack then _G.drap_stats_attack() end
end

return M
