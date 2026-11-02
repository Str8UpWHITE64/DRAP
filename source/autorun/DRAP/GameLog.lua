-- DRAP/GameLog.lua
-- The readable half of the session log: what happened, in the game's own
-- words. Areas, items, locations, survivors and scoops are written by name,
-- from the name tables in drdr_shared.json (through SharedData and
-- Shared.SCENE_INFO); an id the table does not know is written as
-- "unknown area 1234" so the gap is visible and gets added to the table.
--
-- Every function here is safe to call from anywhere and never throws: a
-- logging problem must not take a feature down with it.
--
-- Lines follow the Logger's format, with the standard categories:
--   start config conn items checks state death goal error
-- plus one STATE snapshot every five minutes and right after connect.

local Shared = require("DRAP/Shared")
local Logger = require("DRAP/Logger")
local SharedData = require("DRAP/SharedData")

local M = {}

local STATE_EVERY_S = 300.0
local POLL_EVERY_S = 0.5

local PSM_TYPE = "app.solid.PlayerStatusManager"
local PM_TYPE = "app.solid.PlayerManager"
local AM_TYPE = "app.solid.gamemastering.AreaManager"
local FLOW_TYPE = "app.solid.gamemastering.InGameFlowManagerBase"

------------------------------------------------------------
-- Names
------------------------------------------------------------

local survivor_by_game_id = nil
local survivor_by_number = nil
local item_by_number = nil

local function build_name_tables()
    if survivor_by_game_id then return end
    survivor_by_game_id, survivor_by_number, item_by_number = {}, {}, {}
    for _, s in ipairs(SharedData.survivors()) do
        if s.game_id then survivor_by_game_id[s.game_id] = s.name end
        if s.item_number then survivor_by_number[s.item_number] = s.name end
    end
    for _, it in ipairs(SharedData.items()) do
        if it.item_number and it.name and it.name ~= "" then
            item_by_number[it.item_number] = it.name
        end
    end
end

--- Readable area name for an engine area index or a scene code ("s200").
--- @param key number|string
--- @param with_id boolean|nil Append the scene code in brackets (default true)
--- @return string
function M.area_name(key, with_id)
    local code
    if type(key) == "number" then
        code = Shared.INDEX_TO_SCENE[key]
    elseif type(key) == "string" then
        code = key:gsub("^SCN_", "")
    end
    local info = code and Shared.SCENE_INFO[code]
    if not info then return "unknown area " .. tostring(key) end
    if with_id == false then return info.name end
    return string.format("%s (%s)", info.name, code)
end

--- Readable name of a game item number (the numbers in the items table).
--- @param number number
--- @return string
function M.item_name(number)
    build_name_tables()
    return item_by_number[tonumber(number)] or ("unknown item " .. tostring(number))
end

--- Readable name of a survivor from a game id ("Npc00_Burt") or item number.
--- @param key string|number
--- @return string
function M.npc_name(key)
    build_name_tables()
    local n = survivor_by_game_id[key] or survivor_by_number[tonumber(key) or -1]
    return n or ("unknown survivor " .. tostring(key))
end

--- Readable name of a vehicle from its RIDE_CAR_TYPE enum name.
--- @param ride string
--- @return string
function M.vehicle_name(ride)
    return SharedData.vehicles()[ride] or ("unknown vehicle " .. tostring(ride))
end

------------------------------------------------------------
-- Events
------------------------------------------------------------

local function emit(level, category, msg)
    pcall(Logger.write, category, level, msg)
end

local function say(category, msg) emit(Logger.LEVELS.INFO, category, msg) end

--- A caught error, with the failing call.
--- @param category string
--- @param msg string
function M.error(category, msg) emit(Logger.LEVELS.ERROR, category, msg) end

--- The config the client read at connect. Never the password.
--- @param host string
--- @param slot string
--- @param options string Already-formatted option summary
function M.config(host, slot, options)
    say("config", string.format("Server %s, slot %s%s", tostring(host), tostring(slot),
        (options and options ~= "") and (", " .. options) or ""))
end

--- @param seed any
--- @param slot string
--- @param slot_number any
--- @param slot_count any
function M.connected(seed, slot, slot_number, slot_count)
    local place = ""
    if slot_number ~= nil and slot_count ~= nil then
        place = string.format(" (slot %s of %s)", tostring(slot_number), tostring(slot_count))
    end
    say("conn", string.format("Connected to seed %s as %s%s", tostring(seed), tostring(slot), place))
end

--- An item arrived from the server.
--- @param item string
--- @param sender string
--- @param location string|nil The location it came from
--- @param replay boolean|nil A replay of an item already applied earlier
function M.received(item, sender, location, replay)
    local where = (location and location ~= "") and (" (" .. location .. ")") or ""
    local level = replay and Logger.LEVELS.DEBUG or Logger.LEVELS.INFO
    emit(level, "items", string.format("%s %s from %s%s",
        replay and "Replayed" or "Received", tostring(item), tostring(sender), where))
end

--- An item's effect ran in game. A replay after reconnecting or loading a
--- save logs at DEBUG: the same items are re-applied every time.
--- @param item string
--- @param replay boolean|nil
function M.applied(item, replay)
    emit(replay and Logger.LEVELS.DEBUG or Logger.LEVELS.INFO, "items", "Applied " .. tostring(item))
end

--- A location was sent to the server.
--- @param location string
function M.checked(location)
    say("checks", "Checked " .. tostring(location))
end

--- @param direction string "sent" or "received"
--- @param who string|nil
--- @param cause string|nil
function M.deathlink(direction, who, cause)
    if direction == "sent" then
        say("death", string.format("DeathLink sent: \"%s\"", tostring(cause)))
    else
        say("death", string.format("DeathLink received from %s: \"%s\"",
            tostring(who or "unknown"), tostring(cause)))
    end
end

--- @param name string
function M.goal_complete(name)
    say("goal", "Goal complete: " .. tostring(name))
end

--- The save the player is in was loaded or a new game began.
--- @param is_new boolean
function M.session_entered(is_new)
    say("state", is_new and "New game started" or "Save loaded")
end

------------------------------------------------------------
-- Live reads (each one safe: nil when the game is not ready)
------------------------------------------------------------

local function singleton(name)
    return Shared.safe(function() return sdk.get_managed_singleton(name) end)
end

local function field(obj, name)
    if not obj then return nil end
    return Shared.safe(function() return obj:get_field(name) end)
end

local function read_area_index()
    local am = singleton(AM_TYPE)
    return am and Shared.to_int(field(am, "mAreaIndex")) or nil
end

local function read_flow()
    local td = Shared.safe(function() return sdk.find_type_definition(FLOW_TYPE) end)
    local get = td and td:get_method("get_BaseInstance")
    local mgr = get and Shared.safe(function() return get:call(nil) end)
    return mgr and tonumber(Shared.safe(function() return mgr:call("getGameFlow") end)) or nil
end

local function read_clock()
    local TG = package.loaded["DRAP/TimeGate"]
    if not (TG and TG.get_game_time) then return nil end
    local ok, day, hour, minute = pcall(TG.get_game_time)
    if ok and day then return day, hour, minute end
    return nil
end

local function read_health()
    local psm = singleton(PSM_TYPE)
    if not psm then return nil end
    local hp = tonumber(Shared.safe(function() return psm:call("getVitalNew") end))
    local max = tonumber(field(psm, "PlayerVitalMax"))
    local level = tonumber(field(psm, "PlayerLevel"))
    return hp, max, level
end

local function read_dead()
    local psm = singleton(PSM_TYPE)
    if not psm then return nil end
    local vc = Shared.safe(function() return psm:call("get_PlayerVitalController") end)
    if not vc then return nil end
    return Shared.safe(function() return vc:call("get_IsDead") end) == true
end

local function read_vehicle()
    local VK = package.loaded["DRAP/trackers/VehicleKills"]
    if not (VK and VK.current_ride) then return nil end
    local ok, ride = pcall(VK.current_ride)
    if ok and ride and ride ~= "RIDE_NONE" then return M.vehicle_name(ride) end
    return nil
end

local function bridge()
    return _G.AP and _G.AP.AP_BRIDGE or nil
end

local function read_items_received()
    local B = bridge()
    if not (B and B.get_diag_state) then return nil end
    local ok, st = pcall(B.get_diag_state)
    return ok and st and st.received_items_count or nil
end

local function read_checks()
    local B = bridge()
    if not (B and B.get_diag_state) then return nil end
    local ok, st = pcall(B.get_diag_state)
    local sent = ok and st and st.completed_checks_count or nil
    if not sent then return nil end
    -- The server knows the slot's whole location list; the client may not
    -- expose it, in which case only the sent count is reported.
    local total
    local client = B.AP_REF and B.AP_REF.APClient
    if client and client.get_checked_locations and client.get_missing_locations then
        local c = Shared.safe(function() return client:get_checked_locations() end)
        local m = Shared.safe(function() return client:get_missing_locations() end)
        if type(c) == "table" and type(m) == "table" then total = #c + #m end
    end
    return sent, total
end

local function read_active_scoops()
    local SU = package.loaded["DRAP/ScoopUnlocker"]
    if not (SU and SU.get_all_status) then return nil end
    local ok, rows = pcall(SU.get_all_status)
    if not ok or type(rows) ~= "table" then return nil end
    local names = {}
    for _, r in ipairs(rows) do
        if r.flags_active and not r.completed and not r.failed then
            names[#names + 1] = r.name
        end
    end
    return names
end

local function read_psycho()
    if not (_G.AP and _G.AP.PsychoMode) then return nil end
    local NT = package.loaded["DRAP/trackers/NpcTracker"]
    if not (NT and NT.player_kill_count) then return nil end
    local ok, n = pcall(NT.player_kill_count)
    if not ok then return nil end
    return n, tonumber(_G.AP.NumberOfKills) or 25
end

------------------------------------------------------------
-- STATE snapshot
------------------------------------------------------------

--- Builds the snapshot text. Fields that cannot be read are left out rather
--- than guessed.
--- @return string
function M.state_text()
    local parts = {}
    local function add(k, v) if v ~= nil then parts[#parts + 1] = k .. "=" .. tostring(v) end end

    local area = read_area_index()
    add("area", area and M.area_name(area, false) or nil)

    local day, hour, minute = read_clock()
    if day then
        add("day", day)
        add("time", string.format("%02d:%02d", hour, minute))
    end
    add("flow", read_flow())

    local hp, max, level = read_health()
    if hp then add("hp", max and (math.floor(hp) .. "/" .. math.floor(max)) or math.floor(hp)) end
    add("level", level)

    add("items", read_items_received())
    local sent, total = read_checks()
    if sent then add("checks", total and (sent .. "/" .. total) or sent) end

    local scoops = read_active_scoops()
    if scoops and #scoops > 0 then
        table.sort(scoops)
        add("scoops", table.concat(scoops, ", "))
    end

    local kills, target = read_psycho()
    if kills then add("psycho", kills .. "/" .. target) end

    add("vehicle", read_vehicle())
    return "STATE " .. table.concat(parts, " ")
end

--- Writes one STATE line.
function M.state()
    local ok, text = pcall(M.state_text)
    if ok then
        say("state", text)
    else
        M.error("state", "STATE snapshot failed: " .. tostring(text))
    end
end

------------------------------------------------------------
-- Frame watcher
------------------------------------------------------------

local last_area = nil
local last_day = nil
local last_dead = nil
local next_poll = 0
local next_state = nil

--- Restarts the watchers, so the first read after a load logs where the
--- player now is. Also arms the snapshot timer.
function M.reset_watch()
    last_area, last_day, last_dead = nil, nil, nil
    next_state = os.clock() + STATE_EVERY_S
end

--- Called every frame while a slot is connected and the player is in game.
function M.on_frame()
    local now = os.clock()
    if now < next_poll then return end
    next_poll = now + POLL_EVERY_S

    local area = read_area_index()
    if area and area ~= last_area then
        last_area = area
        say("state", "Entered " .. M.area_name(area))
    end

    local day, hour, minute = read_clock()
    if day and day ~= last_day then
        last_day = day
        say("state", string.format("Day %d, %02d:%02d", day, hour, minute))
    end

    local dead = read_dead()
    if dead ~= nil and dead ~= last_dead then
        if dead and last_dead ~= nil then say("death", "Frank died") end
        last_dead = dead
    end

    if next_state == nil then
        next_state = now + STATE_EVERY_S
    elseif now >= next_state then
        next_state = now + STATE_EVERY_S
        M.state()
    end
end

return M
