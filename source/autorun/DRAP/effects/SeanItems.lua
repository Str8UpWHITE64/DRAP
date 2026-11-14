-- DRAP/effects/SeanItems.lua
-- Keep Sean's sword and the Brainwashing Tips book in Colby's after he is down.
--
-- Both lie in one item layout that the game loads only while flag 335 is on.
-- The cult respawn clears 335 once A Strange Group is done (it also picks the
-- theater's zombie set, so the flag has to stay off), and the layout then
-- never loaded again: the items were gone after the first exit from Colby's.
--
-- 335 is left alone. This writes 0 over the layout's own copy of that flag,
-- a slot the loader skips, once Sean is down. The area builds that copy
-- afresh on every load, so the write is repeated while Colby's is loaded.
-- The items appear when the player walks up to them, as on any layout.

local Shared = require("DRAP/Shared")

local M = Shared.create_module("SeanItems")
M:set_throttle(0.5)

local safe = Shared.safe

local SCOOP        = "A Strange Group"
local LAYOUT_FILE  = "ITL_itemlayout503_evb16"
local EVENT_FLAG   = 335
local REGISTOR_T   = "app.solid.gamemastering.ItemLayoutRegistor"
local ARRAY_COUNT  = 0x1c      -- UInt32[]: length, then elements from +0x20
local ARRAY_DATA   = 0x20
local FLAG_ARRAY   = 0x10      -- GameFlowData.mEventFlag

local patched_total = 0

local function sean_down()
    local su = _G.AP and _G.AP.ScoopUnlocker
    if not (su and su.is_scoop_completed) then return false end
    local ok, done = pcall(su.is_scoop_completed, SCOOP)
    return ok and done == true
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

--- Zero the 335 slot of one flag entry; true when a slot was written.
local function clear_entry(entry)
    local ptr = safe(function() return entry:read_qword(FLAG_ARRAY) end)
    if not ptr or ptr == 0 then return false end
    local arr = safe(function() return sdk.to_managed_object(ptr) end)
    local n = arr and safe(function() return arr:read_dword(ARRAY_COUNT) end)
    if not n then return false end
    local wrote = false
    for i = 0, math.min(n, 16) - 1 do
        local off = ARRAY_DATA + 4 * i
        if safe(function() return arr:read_dword(off) end) == EVENT_FLAG then
            if pcall(function() arr:write_dword(off, 0) end) then wrote = true end
        end
    end
    return wrote
end

local function patch_registor(reg)
    local ud = safe(function() return reg:get_field("mHitAreaLayoutUserData") end)
    local path = ud and safe(function() return tostring(ud:call("get_Path")) end)
    if not (path and path:find(LAYOUT_FILE, 1, true)) then return false end
    local list = safe(function() return reg:get_field("GameFlowFlagsDatas") end)
    local count = list and tonumber(safe(function() return list:call("get_Count") end)) or 0
    local wrote = false
    for i = 0, count - 1 do
        local entry = safe(function() return list:call("get_Item", i) end)
        if entry and clear_entry(entry) then wrote = true end
    end
    return wrote
end

function M.on_frame()
    if not M:should_run() then return end
    if not Shared.is_in_game() then return end
    if not sean_down() then return end
    for _, reg in ipairs(registors()) do
        if patch_registor(reg) then
            patched_total = patched_total + 1
            M.log(string.format("Sean's item layout: flag %d slot cleared (%d so far)",
                EVENT_FLAG, patched_total))
        end
    end
end

return M
