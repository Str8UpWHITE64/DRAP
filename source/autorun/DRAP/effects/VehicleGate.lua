-- DRAP/effects/VehicleGate.lua
-- Car keys: the drivable vehicles stay locked until the key arrives.
--
-- The Overtime Humvee is NOT part of this -- OvertimeItemGate still owns it.
-- It shares its RIDE_CAR_TYPE with the convicts' vehicle, so matching on type
-- alone would gate it by accident. Name decides; type is only the fallback.
--
--   type  GameObject                        vehicle       where
--   1     Vehicle_om0098_4DoorCar           White Sedan   Maintenance Tunnel
--   2     Vehicle_om0009_2DoorCar           Sports Car    Leisure Park
--   3     Vehicle_om0099_Truck              Box Truck     Maintenance Tunnel
--   5     Vehicle_om009b_Bike               Motorcycle    Leisure Park, and
--                                                         North Plaza after
--                                                         Girl Hunting -- both
--                                                         share the one key
--   4     PREF_Vehicle_om009a_Hammer_Em4d   Convicts'     Leisure Park
--   4     Vehicle_om009a_Hammer_EV          Humvee        Overtime -- NOT ours
--
-- Two blocks, because the prompt and the boarding are separate paths:
--   * clearCurrentInteraction, so no "get in" prompt appears at all
--   * requestGetOnCar refused, so nothing gets in even if the prompt is missed
-- The Humvee gate needed the first because activating it never reaches
-- DoInteraction; the second is what actually makes this airtight.

local M = {}

local Shared = require("DRAP/Shared")
local log = Shared.create_logger("VehicleGate")
M.log = log

local safe = Shared.safe

local PIM_TYPE = "app.solid.PlayerInteractionManager"
local VC_TYPE = "app.solid.Vehicle.VehicleController"

-- RIDE_CAR_TYPE -> the item that unlocks it. Anything not listed is left
-- alone, which is what keeps the Humvee (4) and the bicycle/cart out of this.
local KEY_FOR_TYPE = {
    [1] = "Sedan Key",
    [2] = "Sports Car Key",
    [3] = "Truck Key",
    [5] = "Motorcycle Key",
}

-- By GameObject name. This is the authoritative table, not a convenience:
-- the convicts' vehicle reports HAMMER(4), the same type as the Overtime
-- Humvee, so type cannot tell them apart and name has to win. Putting 4 in
-- KEY_FOR_TYPE would gate the Humvee too, which belongs to OvertimeItemGate.
local KEY_FOR_NAME = {
    ["Vehicle_om0098_4DoorCar"]           = "Sedan Key",
    ["Vehicle_om0009_2DoorCar"]           = "Sports Car Key",
    ["Vehicle_om0099_Truck"]              = "Truck Key",
    ["Vehicle_om009b_Bike"]               = "Motorcycle Key",
    -- Em4d is the convict enemy; this is their Leisure Park vehicle.
    ["PREF_Vehicle_om009a_Hammer_Em4d"]   = "Convict Humvee Key",
    -- Vehicle_om009a_Hammer_EV, the Overtime Humvee, is deliberately absent.
}

local enabled = false
local hooks_installed = false
local told = {}

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

-- Debug only: item name -> held, standing in for the server. nil means defer
-- to the bridge, which is what a real run always does.
local debug_keys = nil

--- Same source OvertimeItemGate reads. Fails OPEN when the bridge is not up:
--- an unreadable inventory must not lock the player out of the vehicles, and
--- the gate is only armed on a slot connect anyway. That fail-open is also
--- why vanilla needs debug_enable below to test any of this -- with no bridge
--- every key reads as held and nothing is ever blocked.
local function has_received(item_name)
    if debug_keys ~= nil then return debug_keys[item_name] == true end
    local bridge = _G.AP and _G.AP.AP_BRIDGE
    if not (bridge and bridge.has_item_name) then return true end
    local ok, v = pcall(bridge.has_item_name, item_name)
    if not ok then return true end
    return v == true
end

--- Every key this gate knows about, deduplicated across both tables.
local function all_keys()
    local seen, list = {}, {}
    for _, t in ipairs({ KEY_FOR_TYPE, KEY_FOR_NAME }) do
        for _, item in pairs(t) do
            if not seen[item] then
                seen[item] = true
                table.insert(list, item)
            end
        end
    end
    table.sort(list)
    return list
end

local function vehicle_type(vc)
    local v = safe(function() return vc:call("get_VehicleType") end)
    if v == nil then v = safe(function() return vc:get_field("VehicleType") end) end
    if v == nil then
        v = safe(function() return vc:get_field("<VehicleType>k__BackingField") end)
    end
    return tonumber(v)
end

--- The key this vehicle needs, or nil if it is not one of ours. Name first:
--- it is the only thing that separates the convicts' vehicle from the Humvee,
--- which shares its type and must stay untouched.
local function key_for(vc)
    local go = safe(function() return vc:call("get_GameObject") end)
    local name = go and safe(function() return go:call("get_Name") end)
    if name then
        local by_name = KEY_FOR_NAME[tostring(name)]
        if by_name then return by_name end
        -- A known vehicle object that is not in the table is intentionally
        -- ungated (the Humvee); do not fall through to the type.
        if tostring(name):find("Hammer", 1, true) then return nil end
    end
    local t = vehicle_type(vc)
    return t and KEY_FOR_TYPE[t] or nil
end

local function say_once(tag, msg)
    if told[tag] then return end
    told[tag] = true
    log(msg)
end

--- Told on approach rather than on the interaction: the gate clears the
--- interaction every frame, so it would fire constantly. Same reasoning as the
--- Humvee prompt.
local function notify(item_name)
    local Notify = package.loaded["DRAP/Notify"] or require("DRAP/Notify")
    if not (Notify and Notify.send) then return end
    -- Green and bold on the key name, matching how DoorPromptOverlay marks the
    -- name that matters. Notify.span falls back to plain text if the markup
    -- helper is missing, so the toast still reads either way.
    local name = Notify.span and Notify.span(item_name, "location", true)
        or item_name
    pcall(Notify.send, "You need the " .. name .. " to drive this.",
        { duration = 5.0 })
end

------------------------------------------------------------
-- Blocks
------------------------------------------------------------

local near_locked = nil

--- Take the "get in" prompt away for a car whose key has not arrived.
local function suppress_current()
    if not enabled then near_locked = nil; return end
    local pim = sdk.get_managed_singleton(PIM_TYPE)
    if not pim then return end
    local cur = safe(function() return pim:call("get_CurrentInteraction") end)
    if not cur then
        cur = safe(function()
            return pim:get_field("<CurrentInteraction>k__BackingField")
        end)
    end
    if not cur then near_locked = nil; return end
    local go = safe(function() return cur:get_field("gameObject") end)
    local name = go and safe(function() return go:call("get_Name") end)
    if not name then near_locked = nil; return end

    local item = KEY_FOR_NAME[tostring(name)]
    if not item or has_received(item) then near_locked = nil; return end

    pcall(function() pim:call("clearCurrentInteraction") end)
    -- Edge-triggered: the interaction is cleared every frame, so this would
    -- repeat without the latch.
    if near_locked ~= name then
        near_locked = name
        notify(item)
        log(string.format("held %s -- no %s", tostring(name), item))
    end
end

local function install_hooks()
    if hooks_installed then return end
    local td = sdk.find_type_definition(VC_TYPE)
    if not td then
        log.warn("VehicleController not found -- car keys inactive")
        return
    end
    -- Both Boolean overloads are player-facing; the NPC and enemy ones return
    -- void and are left alone so survivors and convicts still ride.
    local n = 0
    for _, sig in ipairs({
        "requestGetOnCar(System.Int32, via.GameObject, app.solid.Vehicle.IVehicleDriverInterface, System.Boolean, app.solid.Vehicle.VehicleController.DriverType)",
        "requestGetOnCar(app.solid.Vehicle.VehicleController.VehicleSeat, via.GameObject, app.solid.Vehicle.IVehicleDriverInterface, System.Boolean, app.solid.Vehicle.VehicleController.DriverType)",
    }) do
        local fn = td:get_method(sig)
        if fn then
            local ok = pcall(function()
                sdk.hook(fn,
                    function(args)
                        if not enabled then return end
                        local this = safe(function()
                            return sdk.to_managed_object(args[2])
                        end)
                        if not this then return end
                        local item = key_for(this)
                        if not item or has_received(item) then return end
                        say_once("refuse:" .. item,
                            "refused boarding -- no " .. item)
                        return sdk.PreHookResult.SKIP_ORIGINAL
                    end,
                    function(retval) return retval end)
            end)
            if ok then n = n + 1 end
        end
    end
    hooks_installed = n > 0
    if hooks_installed then
        log(string.format("requestGetOnCar hooked (%d overload(s))", n))
    else
        log.warn("could not hook requestGetOnCar -- prompt suppression only")
    end
end

re.on_frame(function()
    pcall(suppress_current)
end)

------------------------------------------------------------
-- Public
------------------------------------------------------------

function M.set_enabled(on)
    enabled = (on == true)
    if enabled then install_hooks() end
    log("Car keys " .. (enabled and "ENABLED" or "off"))
    return true
end

function M.is_enabled() return enabled end

function M.register()
    -- Slot-data driven; nothing to register against item handlers.
    log("VehicleGate loaded (slot-data driven)")
end

------------------------------------------------------------
-- Debug: exercise the gate with no slot connected
------------------------------------------------------------

--- Arm the gate in vanilla and stand in for the server's inventory. Every key
--- starts NOT held, so all five vehicles are locked immediately and there is
--- something to test; hand them over one at a time with drap_cars_give.
--- @param held table|nil item names to start with, or nil for none
function M.debug_enable(held)
    debug_keys = {}
    for _, item in ipairs(all_keys()) do debug_keys[item] = false end
    for _, item in ipairs(held or {}) do debug_keys[item] = true end
    enabled = true
    install_hooks()
    log("debug: car keys armed without a slot -- every vehicle locked")
    return true
end

--- Hand back to the server (or, in vanilla, back to failing open).
function M.debug_disable()
    debug_keys = nil
    enabled = false
    log("debug: car keys released")
    return true
end

function M.debug_set(item_name, held)
    if debug_keys == nil then
        log.warn("debug not armed -- run drap_cars_debug() first")
        return false
    end
    item_name = tostring(item_name)
    if debug_keys[item_name] == nil then
        log.warn(string.format("'%s' is not a car key", item_name))
        return false
    end
    debug_keys[item_name] = (held == true)
    log(string.format("debug: %s -> %s", item_name,
        held and "HELD" or "not held"))
    return true
end

_G.drap_cars = function()
    log("car keys enabled=" .. tostring(enabled)
        .. (debug_keys and "  (DEBUG: server inventory faked)" or ""))
    for _, item in ipairs(all_keys()) do
        log(string.format("  %-20s held=%s", item, tostring(has_received(item))))
    end
end

--- drap_cars_debug()                    -- lock everything, then test
--- drap_cars_debug("Sedan Key")         -- start holding just that one
_G.drap_cars_debug = function(...)
    local held = { ... }
    M.debug_enable(#held > 0 and held or nil)
    _G.drap_cars()
end

_G.drap_cars_give = function(item) return M.debug_set(item, true) end
_G.drap_cars_take = function(item) return M.debug_set(item, false) end
_G.drap_cars_off = function() return M.debug_disable() end

return M
