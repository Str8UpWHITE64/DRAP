-- DRAP/effects/ConvictHumvee.lua
-- Keep a Humvee in Leisure Park once the convicts are dead.
--
-- The convicts' Humvee is not a parked vehicle. It is the convict unit itself
-- (PREF_Vehicle_om009a_Hammer_Em4d carries their AI and save data), spawned on
-- entry by SCQ callback 10 until SET_PRISONER_1DAY (445) says the encounter is
-- spent. So once they are dead nothing spawns it again, and it is gone after
-- the first exit. Clearing 445 brings all three back alive, never the Humvee
-- alone.
--
-- Instead, on each entry with 445 on, this asks ItemManager for the item
-- layout Humvee (class uVehicleOm9a): a plain parked Vehicle_om009a_Hammer,
-- rideable, with no convicts. It is parked in the lot beside the sports car,
-- and since the area releases it on exit, it is asked for again on every
-- entry: like the other vehicles, it is back in the lot each time.
--
-- Nothing is spawned while a Humvee is already here (the convicts' own on the
-- visit they die, or theirs again after a Convicts Respawn Trap, which clears
-- 445) or while Frank drives one in. VehicleGate locks it behind the Convict
-- Humvee Key, the same as theirs.

local Shared = require("DRAP/Shared")

local M = Shared.create_module("ConvictHumvee")
M:set_throttle(0.5)

local safe = Shared.safe

local LEISURE_PARK  = 1792      -- AreaManager.mAreaIndex of s700
local FLAG_SPENT    = 445       -- SET_PRISONER_1DAY
local CLASS         = "uVehicleOm9a"
local RIDE_HAMMER   = 4
local SETTLE_S      = 2.0       -- after the area loads, before asking
local FIND_S        = 12.0      -- a request must show up within this
local MAX_TRIES     = 3
-- In the lot beside the sports car (-203.3, -129.6), facing the same way.
local LOT_SPOT      = { x = -208.0, y = 0.4, z = -129.6, yaw = 3.14 }

local visit = nil               -- per stay in Leisure Park
local stats = { spawned = 0, failed = 0 }

local function efm() return sdk.get_managed_singleton("app.solid.gamemastering.EventFlagsManager") end
local function area_index()
    local am = sdk.get_managed_singleton("app.solid.gamemastering.AreaManager")
    return am and tonumber(safe(function() return am:get_field("mAreaIndex") end))
end

local function convicts_dead()
    local e = efm()
    return e ~= nil and safe(function() return e:call("evFlagCheck", FLAG_SPENT) end) == true
end

local function items(list)
    local out = {}
    if not list then return out end
    local n = tonumber(safe(function() return list:call("get_Count") end))
        or tonumber(safe(function() return list:get_size() end)) or 0
    for i = 0, n - 1 do
        out[#out + 1] = safe(function() return list:call("get_Item", i) end)
            or safe(function() return list:get_element(i) end)
    end
    return out
end

local function scene_vehicles()
    local sm = sdk.get_native_singleton("via.SceneManager")
    local smt = sdk.find_type_definition("via.SceneManager")
    local scene = sm and safe(function() return sdk.call_native_func(sm, smt, "get_CurrentScene()") end)
    if not scene then return {} end
    return items(safe(function()
        return scene:call("findComponents(System.Type)", sdk.typeof("app.solid.Vehicle.VehicleController"))
    end))
end

--- The Humvee standing here, if any: { vc, name, x, y, z }.
local function humvee_here()
    for _, vc in ipairs(scene_vehicles()) do
        if tonumber(safe(function() return vc:call("get_VehicleType") end)) == RIDE_HAMMER then
            local go = safe(function() return vc:call("get_GameObject") end)
            local tr = go and safe(function() return go:call("get_Transform") end)
            local p = tr and safe(function() return tr:call("get_Position") end)
            if p then
                return { vc = vc, name = tostring(safe(function() return go:call("get_Name") end)),
                         x = p.x, y = p.y, z = p.z }
            end
        end
    end
    return nil
end

local function riding_hammer()
    local pm = sdk.get_managed_singleton("app.solid.PlayerManager")
    return pm ~= nil and tonumber(safe(function() return pm:call("get_VehicleType") end)) == RIDE_HAMMER
end

-- The area's Om folder: an object put elsewhere is not shown (CustomStickers).
local function om_folder()
    local am = sdk.get_managed_singleton("app.solid.gamemastering.AreaManager")
    for _, o in ipairs(items(am and safe(function() return am:get_field("OmList") end))) do
        local go = safe(function() return o:call("get_GameObject") end)
        local f = go and safe(function() return go:call("get_Folder") end)
        if f then return f end
    end
    return nil
end

local function request(at)
    local im = sdk.get_managed_singleton("app.solid.gamemastering.ItemManager")
    local key = sdk.create_instance("app.solid.gamemastering.ItemManager.SpecificKeyObject")
    local folder = om_folder()
    if not (im and key and folder) then return false end
    key = key:add_ref()
    key:set_field("ClassName", sdk.create_managed_string(CLASS))
    local h = (at.yaw or 0) / 2
    return pcall(function()
        im:call("instantiateOmItem(app.solid.gamemastering.ItemManager.SpecificKeyObject, via.vec3, via.Quaternion, System.Action`1<via.GameObject>, via.Folder)",
            key, Vector3f.new(at.x, at.y + 0.5, at.z), Quaternion.new(math.cos(h), 0, math.sin(h), 0), nil, folder)
    end)
end

-- An item layout registers each vehicle it places with InGameFlowManagerBase,
-- which is what records the ride when Frank gets in. Without it, driving the
-- Humvee through a door left it at the area origin under the map (HV-11).
local LAYOUT_NAME = "DRAP_ConvictHumvee"
local function register(vc)
    local addr = vc and safe(function() return vc:get_address() end)
    if not addr or visit.registered[addr] then return end
    visit.registered[addr] = true
    local td = sdk.find_type_definition("app.solid.gamemastering.InGameFlowManagerBase")
    local base = td and safe(function() return td:get_method("get_BaseInstance"):call(nil) end)
    local key = sdk.create_instance("app.solid.gamemastering.ItemManager.SpecificKeyObject")
    if not (base and key) then return end
    key = key:add_ref()
    key:set_field("ClassName", sdk.create_managed_string(CLASS))
    local ok = pcall(function()
        base:call("registorVehicleEvent(app.solid.Vehicle.VehicleController, System.String, System.Int32, app.solid.gamemastering.ItemManager.SpecificKeyObject)",
            vc, sdk.create_managed_string(LAYOUT_NAME), 0, key)
    end)
    if not ok then M.log.warn("could not register the Humvee as a vehicle") end
end

function M.on_frame()
    if not M:should_run() then return end
    if not Shared.is_in_game() or area_index() ~= LEISURE_PARK then
        visit = nil
        return
    end
    local now = os.clock()
    if not visit then
        visit = { since = now, tries = 0, rode_in = riding_hammer(), registered = {} }
        return
    end

    local hv = humvee_here()
    if hv then
        -- Only the one asked for on this visit: one driven in was registered
        -- when it was made.
        if visit.asked and hv.name == "Vehicle_om009a_Hammer" then register(hv.vc) end
        if visit.asked and not visit.found then
            visit.found = true
            stats.spawned = stats.spawned + 1
            M.log(string.format("Humvee parked at (%.1f, %.1f, %.1f)", hv.x, hv.y, hv.z))
        end
        return
    end

    if visit.rode_in or visit.found or not convicts_dead() then return end
    if visit.asked and now - visit.asked < FIND_S then return end
    if now - visit.since < SETTLE_S then return end
    if visit.tries >= MAX_TRIES then
        if not visit.gave_up then
            visit.gave_up = true
            stats.failed = stats.failed + 1
            M.log.warn("Humvee did not appear after " .. MAX_TRIES .. " requests")
        end
        return
    end
    if request(LOT_SPOT) then
        visit.tries = visit.tries + 1
        visit.asked = now
    end
end

function M.status()
    return { spot = LOT_SPOT, spawned = stats.spawned, failed = stats.failed,
             visit = visit and { tries = visit.tries, found = visit.found == true, rode_in = visit.rode_in } }
end

return M
