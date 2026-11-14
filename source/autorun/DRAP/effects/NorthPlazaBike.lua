-- DRAP/effects/NorthPlazaBike.lua
-- Keep the North Plaza motorcycle there from Meet Jessie on.
--
-- The bike is the only entry of one item layout, which the game loads in
-- GameFlow mode: only while the game flow equals one of the numbers its
-- registor lists (230, 250 and up, none lower). In the vanilla story that is
-- from Girl Hunting on, and the flow only rises, so it stays. Missions come in
-- any order here, and each one leaves the flow where it put it, so the bike
-- came and went with whichever mission was done last.
--
-- Once Jessie has been met, this switches that registor to Default mode,
-- which loads at any flow. The area builds its registors afresh on every load,
-- so the write is repeated while North Plaza is loaded. The layout's own
-- once-flag is left alone, as are the car keys (VehicleGate).
--
-- Overtime is left to the game: its flows run in order there, as in vanilla,
-- and the bike comes and goes exactly as it does without the mod.

local Shared = require("DRAP/Shared")

local M = Shared.create_module("NorthPlazaBike")
M:set_throttle(0.5)

local safe = Shared.safe

local LAYOUT_FILE  = "ITL_itemlayout400_250"
local REGISTOR_T   = "app.solid.gamemastering.ItemLayoutRegistor"
local MODE_DEFAULT = 0

local patched_total = 0

local function met_jessie()
    local su = _G.AP and _G.AP.ScoopUnlocker
    if not (su and su.has_met_jessie) then return false end
    local ok, met = pcall(su.has_met_jessie)
    return ok and met == true
end

local function in_overtime()
    local S = package.loaded["DRAP/scoops/ScoopState"]
    if not (S and S.is_endgame_reached) then return false end
    local ok, v = pcall(S.is_endgame_reached)
    return ok and v == true
end

local function registors()
    local sm = sdk.get_native_singleton("via.SceneManager")
    local smt = sdk.find_type_definition("via.SceneManager")
    if not (sm and smt) then return {} end
    local scene = safe(function() return sdk.call_native_func(sm, smt, "get_CurrentScene") end)
    if not scene then return {} end
    local comps = safe(function()
        return scene:call("findComponents(System.Type)", sdk.typeof(REGISTOR_T))
    end)
    return comps and safe(function() return comps:get_elements() end) or {}
end

--- Put the bike's registor in Default mode; true when it was written.
local function patch_registor(reg)
    local ud = safe(function() return reg:get_field("mHitAreaLayoutUserData") end)
    local path = ud and safe(function() return tostring(ud:call("get_Path")) end)
    if not (path and path:find(LAYOUT_FILE, 1, true)) then return false end
    local mode = tonumber(safe(function() return reg:get_field("Mode") end))
    if mode == MODE_DEFAULT then return false end
    return pcall(function() reg:set_field("Mode", MODE_DEFAULT) end)
end

function M.on_frame()
    if not M:should_run() then return end
    if not Shared.is_in_game() then return end
    if not met_jessie() then return end
    if in_overtime() then return end
    for _, reg in ipairs(registors()) do
        if patch_registor(reg) then
            patched_total = patched_total + 1
            M.log(string.format("North Plaza motorcycle layout set to load at any flow (%d so far)",
                patched_total))
        end
    end
end

return M
