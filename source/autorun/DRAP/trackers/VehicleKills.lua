-- DRAP/trackers/VehicleKills.lua
-- Zombies killed with a car or a motorcycle, for the "Kill N zombies by
-- vehicle" challenges.
--
-- The game's own vehicle-kill counter (SolidStorage.addZombieVehicleKillNum,
-- saved as zombieKilledVehicleTotal) also goes up for kills made on the
-- bicycle and the skateboard. The challenges are for the motor vehicles, so
-- this keeps its own count: a call to
-- addZombieVehicleKillNum is credited only when the player is driving one of
-- them at that moment.
--
-- What the player rides is PlayerManager.VehicleType, an
-- app.solid.Vehicle.RIDE_CAR_TYPE:
--
--   RIDE_4DOOR    White Sedan            counts
--   RIDE_2DOOR    Sports Car             counts
--   RIDE_TRUCK    Box Truck              counts
--   RIDE_HAMMER   Humvees                counts
--   RIDE_BIKE     Motorcycle             counts
--   RIDE_BIYCYCLE Bicycle (the game's spelling), in an Entrance Plaza shop
--   RIDE_RIDECART a ride cart
--   RIDE_NONE     not in a vehicle. The skateboard and the shopping cart are
--                 held items: riding one is a special control
--                 (SpControlStatus SkateBoard / ShoppingCart), and only
--                 boarding a vehicle sets VehicleType
--
-- The ride is read once a frame and cached, so the hook itself only does Lua
-- arithmetic. Credited kills are added to the run ledger in batches, so the
-- count is per seed and survives a relaunch.

local Shared = require("DRAP/Shared")

local M = Shared.create_module("VehicleKills")

local SOLID_STORAGE = "app.solid.SolidStorage"
local RIDE_TYPE = "app.solid.Vehicle.RIDE_CAR_TYPE"
local LEDGER_SECTION = "vehicle_kills"

-- Writes to the ledger: at most this often while kills are coming in.
local SAVE_EVERY_S = 5
-- Counted vehicle kills are summed into one log line per this many seconds.
local LOG_EVERY_S = 60
-- A cached ride older than this is not trusted (the frame loop stopped:
-- a load, the title screen, no slot).
local STALE_S = 1.0

-- RIDE_CAR_TYPE names that count as a car or a motorcycle.
M.COUNTED_RIDES = {
    RIDE_4DOOR  = true,
    RIDE_2DOOR  = true,
    RIDE_TRUCK  = true,
    RIDE_HAMMER = true,
    RIDE_BIKE   = true,
}

--- Whether a kill made on this ride counts. Anything not listed, an unknown
--- name and nil (the ride could not be read) do not.
--- @param name string|nil a RIDE_CAR_TYPE name
function M.counts(name)
    return name ~= nil and M.COUNTED_RIDES[name] == true
end

------------------------------------------------------------
-- State
------------------------------------------------------------

local pm_mgr = M:add_singleton("pm", "app.solid.PlayerManager")

local ride_names = nil      -- RIDE_CAR_TYPE value -> name
local ride = nil            -- the cached ride name
local ride_at = nil         -- os.clock() of the cache
local installed = false
local install_tries = 0

local pending = 0           -- credited kills not yet in the ledger
local seen = {}             -- ride name -> addZombieVehicleKillNum calls since the last log line
local noted = {}            -- uncounted ride names already logged once this session
local last_save = 0
local last_log = 0
local session = { counted = 0, skipped = 0 }

------------------------------------------------------------
-- Ride
------------------------------------------------------------

--- RIDE_CAR_TYPE value -> name, read from the enum itself so the values
--- never have to be copied here.
local function load_ride_names()
    local td = sdk.find_type_definition(RIDE_TYPE)
    if not td then return nil end
    local map = {}
    for _, f in ipairs(td:get_fields() or {}) do
        if f:is_static() then
            local ok, v = pcall(f.get_data, f, nil)
            v = ok and tonumber(v) or nil
            if v ~= nil then map[v] = f:get_name() end
        end
    end
    if next(map) == nil then return nil end
    return map
end

--- @param value number|nil a RIDE_CAR_TYPE value
--- @param names table|nil value -> name
function M.ride_name(value, names)
    value = tonumber(value)
    if value == nil then return nil end
    local n = names and names[value]
    if n then return n end
    return "RIDE_" .. tostring(value)
end

local function read_ride()
    if not ride_names then ride_names = load_ride_names() end
    local pm = pm_mgr:get()
    if not pm then return nil end
    local v = Shared.safe(function() return pm:get_field("<VehicleType>k__BackingField") end)
    return M.ride_name(v, ride_names)
end

------------------------------------------------------------
-- The hook
------------------------------------------------------------

--- One addZombieVehicleKillNum call. Pure Lua: runs inside the game's call.
--- @param now number os.clock()
function M.on_vehicle_kill(now)
    local r = ride
    if ride_at == nil or (now - ride_at) > STALE_S then r = nil end
    local key = r or "unknown"
    seen[key] = (seen[key] or 0) + 1
    if M.counts(r) then
        pending = pending + 1
        session.counted = session.counted + 1
    else
        session.skipped = session.skipped + 1
    end
end

--- Whether a vehicle kill right now would count. Pure Lua, for the Kills
--- tab's own hook on the same call.
function M.counts_now()
    if ride_at == nil or (os.clock() - ride_at) > STALE_S then return false end
    return M.counts(ride)
end

local function install_hook()
    if installed then return end
    install_tries = install_tries + 1
    local td = sdk.find_type_definition(SOLID_STORAGE)
    local method = td and td:get_method("addZombieVehicleKillNum(System.UInt32)")
    if not method then
        if install_tries > 600 then
            installed = true
            M.log.warn("addZombieVehicleKillNum not found -- vehicle kills are not counted")
        end
        return
    end
    -- The native address is unique in the il2cpp dump (not a folded stub).
    local ok, err = pcall(sdk.hook, method, function(args)
        pcall(M.on_vehicle_kill, os.clock())
    end, nil)
    installed = true
    if ok then
        M.log("counting car and motorcycle kills")
    else
        M.log.warn("could not hook addZombieVehicleKillNum: " .. tostring(err))
    end
end

------------------------------------------------------------
-- Ledger
------------------------------------------------------------

local function ledger()
    local ok, L = pcall(require, "DRAP/LocationLedger")
    if ok and L and L.is_init and L.is_init() then return L end
    return nil
end

local function stored(L)
    local doc = L and L.get_section(LEDGER_SECTION)
    return type(doc) == "table" and tonumber(doc.count) or 0
end

--- Write the pending kills into the ledger. With no ledger open (no seed)
--- they are dropped: there is nothing to count them toward.
function M.flush()
    if pending == 0 then return false end
    local L = ledger()
    local n = pending
    pending = 0
    if not L then return false end
    return L.set_section(LEDGER_SECTION, { count = stored(L) + n }) == true
end

--- Car and motorcycle kills this seed, including any not yet written.
function M.total()
    local L = ledger()
    if not L then return nil end
    return stored(L) + pending
end

------------------------------------------------------------
-- Frame
------------------------------------------------------------

local function log_seen()
    if next(seen) == nil then return end
    -- Counted kills are always summed; an uncounted ride (on foot, a
    -- skateboard, the bicycle) is named once a session, so routine kills
    -- don't fill the log. drap_vehicle_kills() still shows every count.
    local parts = {}
    for name, n in pairs(seen) do
        if M.counts(name ~= "unknown" and name or nil) then
            parts[#parts + 1] = string.format("%s x%d (counted)", name, n)
        elseif not noted[name] then
            noted[name] = true
            parts[#parts + 1] = string.format("%s x%d (not counted)", name, n)
        end
    end
    seen = {}
    if #parts == 0 then return end
    table.sort(parts)
    M.log(string.format("vehicle kill: %s; car and motorcycle kills this seed: %s",
        table.concat(parts, ", "), tostring(M.total())))
end

function M.on_frame()
    if not installed then install_hook() end
    ride = read_ride()
    ride_at = os.clock()

    if next(seen) ~= nil and (ride_at - last_log) >= LOG_EVERY_S then
        last_log = ride_at
        log_seen()
    end
    if pending > 0 and (ride_at - last_save) >= SAVE_EVERY_S then
        last_save = ride_at
        M.flush()
    end
end

------------------------------------------------------------
-- Console
------------------------------------------------------------

function M.status()
    return {
        ride = ride,
        counts_now = M.counts_now(),
        total = M.total(),
        pending = pending,
        counted = session.counted,
        skipped = session.skipped,
        installed = installed,
    }
end

_G.drap_vehicle_kills = function()
    local s = M.status()
    print(string.format("[VehicleKills] riding %s (%s); this seed %s; this session %d counted, %d not",
        tostring(s.ride), s.counts_now and "counts" or "does not count",
        tostring(s.total), s.counted, s.skipped))
    return s
end

return M
