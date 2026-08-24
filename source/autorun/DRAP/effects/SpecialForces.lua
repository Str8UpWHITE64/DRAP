-- DRAP/effects/SpecialForces.lua
-- The Overtime soldiers, loose in the mall during the 72 hours.
--
-- Driven by the slot-data option `special_forces_mode`:
--   0 none       vanilla
--   1 item       the "Special Forces" scoop turns them on; it completes once
--                both its checks are sent, and clear_on_complete drops the
--                flag ONCE -- see below
--   2 permanent  on from Jessie onward, no item involved
--
-- ScoopSanity only -- the apworld already falls the mode back to none without
-- it, so nothing here has to re-check that.
--
-- FLAG 309 IS THE WHOLE MECHANISM. Measured in game: 309 ON (with 311 off, its
-- default) selects the enemy-set rows that put Special Forces in every area,
-- without failing the story and without the cultists that forcing game flow
-- to 31900 dragged along. See docs/BACKLOG.md.
--
-- In `item` mode this module sets nothing: the scoop carries flags = [309], so
-- ScoopUnlocker turns it on at unlock and clears it on completion. All that is
-- left is the music, which a flag row cannot express.
--
-- THE CLEAR IS ONE-SHOT, and it has to be. The story raises 309 again by
-- itself at 10pm on day 3. The side-completed policy used to claim it off on
-- every reconciler pass, so the game turned the soldiers on and DRAP turned
-- them off a tick later, replaying the cutscene without end. It now clears
-- once and leaves the flag alone -- see FlagPolicies.
--
-- THE MUSIC. Flag 309 also starts a loud track that plays continuously and is
-- re-requested on every area load. Stopping it does not hold -- requestStopBGM
-- silences it until the next load, and PoliceBGMCheck, bgmCheckSkipRequest and
-- areaBGMstop all did nothing. Blocking `SoundBGMManager.bgmControll` with a
-- SKIP_ORIGINAL pre-hook does hold. It is a load-time call (skip count rose
-- 1 -> 8 across several area transitions, versus areaBGMChange's 6856 in the
-- same window), so blocking it is cheap.
--
-- The block MIRRORS flag 309 rather than the mode, so it lifts by itself when
-- the scoop completes, and never runs in a mode that has no soldiers.
--
-- Everything here stops at Overtime. Overtime ships its own Special Forces and
-- its own music, so past that point this module has nothing to add and would
-- only be fighting content that already works.

local Shared = require("DRAP/Shared")
local Activation = require("DRAP/Activation")
local State = require("DRAP/scoops/ScoopState")

local M = Shared.create_module("SpecialForces")

local efm_mgr = M:add_singleton("efm", "app.solid.gamemastering.EventFlagsManager")

local BGM_TYPE = "app.solid.SoundBGMManager"

local SF_FLAG = 309          -- EV_EVENT47: the soldiers
local SF_EXCLUDE_FLAG = 311  -- EV_EVENT49: their rows require this OFF
local JESSIE_FLAG = 769      -- nothing before Jessie, same as every scoop

local MODE_NONE, MODE_ITEM, MODE_PERMANENT = 0, 1, 2

local mode = MODE_NONE

------------------------------------------------------------
-- Flags
------------------------------------------------------------

local function flag_get(id)
    local efm = efm_mgr:get()
    if not efm then return nil end
    return Shared.safe(function() return efm:call("evFlagCheck", id) end)
end

local function flag_set(id, on)
    local efm = efm_mgr:get()
    if not efm then return false end
    return pcall(function()
        efm:call(on and "evFlagOn" or "evFlagOff", id)
    end)
end

------------------------------------------------------------
-- The music block
------------------------------------------------------------
-- Installed once and left in place; the boolean gates it, because REFramework
-- has no unhook and re-running would stack duplicates.

local music_blocked = false
local block_installed = false
local block_skips = 0

local function install_block()
    if block_installed then return end
    local td = Shared.safe(function() return sdk.find_type_definition(BGM_TYPE) end)
    local m = td and td:get_method("bgmControll")
    if not m then
        M.log("bgmControll not found -- the Special Forces music cannot be silenced")
        return
    end
    local ok = pcall(function()
        sdk.hook(m, function()
            if music_blocked then
                block_skips = block_skips + 1
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
        end, function(retval) return retval end)
    end)
    block_installed = ok
    if not ok then M.log("failed to hook bgmControll") end
end

local function set_music_blocked(on)
    if on == music_blocked then return end
    if on then install_block() end
    music_blocked = on
    M.log(on and "music silenced while the Special Forces are out"
             or "music restored")
end

------------------------------------------------------------
-- Frame
------------------------------------------------------------

function M.on_frame()
    if not Activation.is_active() then return end
    if not Shared.is_in_game() then return end

    -- Hands off from Overtime on. Overtime has its own Special Forces as part
    -- of the story, with their own music -- holding 309 or silencing the mall
    -- past that point is meddling with content that already works. Lift the
    -- block too, so Overtime sounds the way it should.
    if State.is_endgame_reached() then
        if music_blocked then
            set_music_blocked(false)
            M.log("Overtime reached -- Special Forces handling stands down")
        end
        return
    end

    -- Nothing before Jessie, exactly as in a new game.
    if flag_get(JESSIE_FLAG) ~= true then return end

    if mode == MODE_PERMANENT then
        -- No scoop to carry the flag in this mode, so hold it here. Re-checked
        -- rather than set once: the engine clears it across some transitions.
        if flag_get(SF_FLAG) ~= true then
            if flag_set(SF_FLAG, true) then
                M.log("Special Forces deployed (permanent)")
            end
        end
        -- Their rows need this OFF. It is off by default, so this only matters
        -- if something else turns it on.
        if flag_get(SF_EXCLUDE_FLAG) == true then
            flag_set(SF_EXCLUDE_FLAG, false)
        end
    end

    -- Mirror the FLAG, and deliberately not the mode. In item mode the scoop
    -- owns 309 -- ScoopUnlocker sets it at unlock and clear_on_complete drops
    -- it once both checks are sent -- so the flag is the only thing that
    -- reliably says whether soldiers are out. Gating this on `mode` meant the
    -- music played whenever set_mode had not been told the mode, even though
    -- the scoop had already deployed them.
    set_music_blocked(flag_get(SF_FLAG) == true)
end

------------------------------------------------------------
-- Setup
------------------------------------------------------------

--- @param value integer 0 none, 1 item, 2 permanent
function M.set_mode(value)
    value = tonumber(value) or MODE_NONE
    if value ~= MODE_NONE and value ~= MODE_ITEM and value ~= MODE_PERMANENT then
        value = MODE_NONE
    end
    mode = value
    M.log(string.format("mode = %s", value == MODE_ITEM and "item"
        or value == MODE_PERMANENT and "permanent" or "none"))
end

function M.get_mode() return mode end

--- Put everything back. Used on a reload into a different save.
function M.reset()
    set_music_blocked(false)
end

_G.drap_sf_status = function()
    M.log(string.format(
        "mode=%d flag %d=%s flag %d=%s | music_blocked=%s hooked=%s skips=%d",
        mode, SF_FLAG, tostring(flag_get(SF_FLAG)),
        SF_EXCLUDE_FLAG, tostring(flag_get(SF_EXCLUDE_FLAG)),
        tostring(music_blocked), tostring(block_installed), block_skips))
end

--- Offline testing without a seed: force a mode from the console.
_G.drap_sf_mode = function(v) M.set_mode(v) end

return M
