-- DRAP/Bridge.lua
-- Bridge between Archipelago client and Dead Rising mod

local Shared = require("DRAP/Shared")
local AP_REF = require("AP_REF/core")
local ItemEffects = require("DRAP/ItemEffects")
local Ledger = require("DRAP/LocationLedger")

local M = Shared.create_module("Bridge")

------------------------------------------------------------
-- Module-level state. Declared up front so every function in the file
-- can reference them, regardless of source position. Lua module-level
-- locals are only visible to code that follows their declaration --
-- declaring late means earlier functions silently fall through to the
-- (nil) global lookup, which is what caused checks/items to never
-- record locally.
------------------------------------------------------------

-- Location checks live in DRAP/LocationLedger (one persisted document per
-- slot/seed; Bug 5 Phases 1-2). These cache the identifiers between
-- set_completed_checks_filename() and load_completed_checks(), and drive
-- the sync-on-connect state machine in M.on_frame.
local ledger_slot = nil
local ledger_seed = nil
local sync_needed = false
local last_sync_try = 0.0
local last_ack_pull = 0.0
local pending_acks = {}   -- server-checked ids that arrived pre-init

local RECEIVED_ITEMS = {}
local RECEIVED_ITEMS_BY_NAME = {}
local last_item_index = -1
local RECEIVED_ITEMS_FILE = nil

-- Forward-declared local functions. M.check (early in the file) references
-- functions defined later; without these declarations the calls resolve to
-- nil globals.
local save_received_items

------------------------------------------------------------
-- Data Package
------------------------------------------------------------

local AP_ITEMS_BY_NAME = {}
local AP_LOCATIONS_BY_NAME = {}
local AP_LOCATIONS_BY_ID = {}
local data_package_ready = false
local pending_items = {}  -- Items received before data package was ready

AP_REF.on_data_package_changed = function(data_package)
    local ap_game = AP_REF.APClient and AP_REF.APClient:get_game() or AP_REF.APGameName
    local game_pkg = data_package.games[ap_game]

    if not game_pkg then
        M.log("No data package for game: " .. tostring(ap_game))
        return
    end

    AP_ITEMS_BY_NAME = game_pkg.item_name_to_id or {}
    AP_LOCATIONS_BY_NAME = game_pkg.location_name_to_id or {}
    AP_LOCATIONS_BY_ID = {}
    for name, id in pairs(AP_LOCATIONS_BY_NAME) do
        AP_LOCATIONS_BY_ID[tonumber(id) or id] = name
    end

    local item_count, loc_count = 0, 0
    for _ in pairs(AP_ITEMS_BY_NAME) do item_count = item_count + 1 end
    for _ in pairs(AP_LOCATIONS_BY_NAME) do loc_count = loc_count + 1 end

    M.log("Data package loaded: items=" .. tostring(item_count) .. " locations=" .. tostring(loc_count))

    data_package_ready = true
end

function M.get_item_id(name) return AP_ITEMS_BY_NAME[name] end
function M.get_location_id(name) return AP_LOCATIONS_BY_NAME[name] end

------------------------------------------------------------
-- Connection Helper
------------------------------------------------------------

-- The apclientpp module (with its State enum) is exported as AP_REF.AP.
-- The global AP is main.lua's module table and has no State field.
local function is_connected()
    if not AP_REF.APClient then return false end
    local st = AP_REF.APClient:get_state()
    local ap_mod = AP_REF.AP
    if not (ap_mod and ap_mod.State) then return true end  -- can't tell; assume up
    return st ~= ap_mod.State.DISCONNECTED
end

function M.is_connected()
    return is_connected()
end

------------------------------------------------------------
-- Goal Completion
------------------------------------------------------------

function M.send_goal_complete()
    if not AP_REF.APClient then
        M.log("Cannot send goal: APClient is nil")
        return false
    end

    -- CLIENT_GOAL status is 30 in Archipelago protocol
    local CLIENT_GOAL = 30

    -- Try StatusUpdate method (standard AP client method)
    if type(AP_REF.APClient.StatusUpdate) == "function" then
        local ok, err = pcall(AP_REF.APClient.StatusUpdate, AP_REF.APClient, CLIENT_GOAL)
        if ok then
            M.log("Goal completion sent successfully!")
            return true
        else
            M.log("StatusUpdate failed: " .. tostring(err))
            re.msg("Goal completion failed to send: " .. tostring(err))
        end
    else
        M.log("StatusUpdate method not found on APClient")
    end

    return false
end

------------------------------------------------------------
-- DeathLink
------------------------------------------------------------

M.deathlink_enabled = false

function M.set_deathlink_enabled(v)
    M.deathlink_enabled = (v == true)
    M.log("DeathLink enabled: " .. tostring(M.deathlink_enabled))
end

local function has_tag(tags, needle)
    if not tags or type(tags) ~= "table" then return false end
    for _, v in pairs(tags) do
        if v == needle then return true end
    end
    return false
end

local function handle_bounced(json_rows)
    if not M.deathlink_enabled then return end
    if not json_rows or type(json_rows) ~= "table" then return end

    if not has_tag(json_rows["tags"], "DeathLink") then return end

    local data = json_rows["data"] or {}
    local source = data["source"] or data["player"] or "Unknown"
    local cause = data["cause"] or ("DeathLink from " .. tostring(source))

    M.log("DeathLink received: " .. tostring(cause))

    if _G.AP and _G.AP.DeathLink and _G.AP.DeathLink.kill_player then
        pcall(_G.AP.DeathLink.kill_player, "DeathLink: " .. tostring(cause))
    else
        M.log("DeathLink received, but AP.DeathLink.kill_player unavailable")
    end
end

function M.send_deathlink(data)
    if not M.deathlink_enabled then return false end
    if not AP_REF.APClient then return false end
    if not is_connected() then return false end

    local time_of_death = math.floor(os.time())
    if AP_REF.APClient.get_server_time then
        local ok, t = pcall(AP_REF.APClient.get_server_time, AP_REF.APClient)
        if ok and t then time_of_death = math.floor(tonumber(t) or os.time()) end
    end

    local my_alias = "DRDR Player"
    if AP_REF.APClient.get_player_alias and AP_REF.APClient.get_slot then
        local ok_slot, slot = pcall(AP_REF.APClient.get_slot, AP_REF.APClient)
        if ok_slot and slot then
            local ok_alias, alias = pcall(AP_REF.APClient.get_player_alias, AP_REF.APClient, slot)
            if ok_alias and alias then my_alias = Shared.clean_string(alias) end
        end
    end
    my_alias = Shared.clean_string((data and data.source) or my_alias)

    local deathLinkData = {
        time = (data and data.time) or time_of_death,
        cause = (data and data.cause) or (my_alias .. " died."),
        source = my_alias
    }

    if type(AP_REF.APClient.Bounce) == "function" then
        local ok, err = pcall(AP_REF.APClient.Bounce, AP_REF.APClient, deathLinkData, nil, nil, { "DeathLink" })
        if ok then
            M.log("Sent DeathLink: " .. tostring(deathLinkData.cause))
            return true
        end
        M.log("DeathLink send failed: " .. tostring(err))
    end

    return false
end

------------------------------------------------------------
-- Bounced Handler
------------------------------------------------------------

local user_on_bounced = nil

function M.set_on_bounced(fn)
    user_on_bounced = fn
end

AP_REF.on_bounced = function(json_rows)
    pcall(handle_bounced, json_rows)
    if user_on_bounced then pcall(user_on_bounced, json_rows) end
end

------------------------------------------------------------
-- Client Binding
------------------------------------------------------------

function M.bind_client()
    if not AP_REF.APClient then return false end

    AP_REF.APClient:set_items_received_handler(function(items)
        if AP_REF.on_items_received then AP_REF.on_items_received(items) end
    end)

    AP_REF.APClient:set_data_package_changed_handler(function(dp)
        if AP_REF.on_data_package_changed then AP_REF.on_data_package_changed(dp) end
    end)

    AP_REF.APClient:set_slot_connected_handler(function(slot_data)
        if AP_REF.on_slot_connected then AP_REF.on_slot_connected(slot_data) end
    end)

    AP_REF.APClient:set_location_checked_handler(function(locations)
        if AP_REF.on_location_checked then AP_REF.on_location_checked(locations) end
    end)

    AP_REF.APClient:set_retrieved_handler(function(map, keys, extra)
        if AP_REF.on_retrieved then AP_REF.on_retrieved(map, keys, extra) end
    end)

    AP_REF.APClient:set_room_info_handler(function()
        if AP_REF.on_room_info then AP_REF.on_room_info() end
    end)

    M.log("Rebound APClient handlers.")
    return true
end

------------------------------------------------------------
-- Location Checks
------------------------------------------------------------

local function resolve_location_id(name)
    if not AP_REF.APClient or not AP_REF.APClient.get_location_id then return nil end
    local ok, id = pcall(AP_REF.APClient.get_location_id, AP_REF.APClient, name, nil)
    if ok then return id end
    return nil
end

local _warned_no_checks_file = false

-- Pre-connect journal: checks detected before the first slot-connect of a
-- session have no per-slot/seed file yet. Without a journal they were lost
-- permanently -- the trackers are edge-triggered and never refire. The
-- journal is global (slot/seed unknown at write time) and is merged into
-- whichever slot connects next, which is the save the player was playing.
local PENDING_CHECKS_FILE = "./AP_DRDR_Items/AP_DRDR_checks_pending.json"
local PENDING_CHECKS = {}

local function save_pending_checks()
    local list = {}
    for name, _ in pairs(PENDING_CHECKS) do
        table.insert(list, name)
    end
    table.sort(list)
    Shared.save_json(PENDING_CHECKS_FILE, { checks = list }, 4, M.log)
end

local function load_pending_checks()
    PENDING_CHECKS = {}
    -- Existence check first: json.load_file logs a loud parse error for a
    -- missing/empty file, which reads like data loss to players. io.open
    -- resolves relative to reframework/data, same root as json.load_file
    -- (verified: probe scripts' io.open logs land there).
    local probe = io.open(PENDING_CHECKS_FILE, "r")
    if not probe then return end
    local has_content = probe:read(1) ~= nil
    probe:close()
    if not has_content then return end

    local data = Shared.load_json(PENDING_CHECKS_FILE)
    if data and data.checks then
        for _, name in ipairs(data.checks) do
            PENDING_CHECKS[name] = true
        end
    end
end
load_pending_checks()

function M.check(loc_name)
    M.log("Sending location check: " .. tostring(loc_name))

    -- Record every check for resend-on-reconnect, even if the send fails
    if loc_name and Ledger.is_init() then
        Ledger.record(loc_name, "check")
    elseif loc_name then
        -- Not slot-connected yet: journal the check so the next slot-connect
        -- merges and sends it.
        if not PENDING_CHECKS[loc_name] then
            PENDING_CHECKS[loc_name] = true
            save_pending_checks()
        end
        if not _warned_no_checks_file then
            _warned_no_checks_file = true
            M.log("Note: not slot-connected yet; checks are journaled to "
                .. PENDING_CHECKS_FILE .. " and will merge+send on connect.")
        end
    end

    if not AP_REF.APClient then
        M.log("APClient is nil")
        sync_needed = true   -- the sync loop retries once connected
        return false
    end

    if not is_connected() then
        M.log("Disconnected; cannot send (sync will retry)")
        sync_needed = true
        return false
    end

    local loc_id = resolve_location_id(loc_name)
    if not loc_id then
        M.log("Could not resolve location: " .. tostring(loc_name) .. " (sync will retry)")
        sync_needed = true
        return false
    end

    loc_id = tonumber(loc_id) or loc_id
    local ok, ret = pcall(AP_REF.APClient.LocationChecks, AP_REF.APClient, { loc_id })
    M.log("LocationChecks ok=" .. tostring(ok))
    if not ok then sync_needed = true end
    return ok
end

------------------------------------------------------------
-- Filename Sanitizer
------------------------------------------------------------

local function safe_filename(s)
    s = tostring(s or "unknown")
    s = s:gsub("[^%w%-%._]", "_")
    return s
end

------------------------------------------------------------
-- Location Ledger integration (Bug 5 Phases 1-2)
--
-- The ledger (DRAP/LocationLedger) is the single store for every location
-- this slot/seed has detected. Bridge owns id resolution and traffic:
--   * server acks arrive via AP_REF.on_location_checked (full checked set
--     at connect + deltas), marking entries acked and reverse-importing
--     server-known checks we lost locally;
--   * a sync state machine (M.on_frame) batch-resends every unacked name
--     once the data package can resolve ids, retrying every ~2s -- this
--     replaces the old one-shot resend that silently dropped names when
--     the data package raced the connect.
-- The legacy per-name COMPLETED_CHECKS file is imported once and kept on
-- disk for rollback; it is no longer written.
------------------------------------------------------------

-- Sync diagnostics persist to a file (console prints don't reach the
-- framework log).
local function sync_diag(msg)
    M.log(msg)
    local f = io.open("drap_sync_diag.log", "a")
    if f then
        f:write(string.format("[%s] %s\n", os.date("%m-%d %H:%M:%S"), msg))
        f:close()
    end
end

-- Coerce a location id from the binding (number, int64 userdata, or
-- string) into the numeric key space used by AP_LOCATIONS_BY_ID.
local function coerce_id(id)
    local n = tonumber(id)
    if n then return n end
    local ok, v = pcall(sdk.to_int64, id)
    if ok and v then
        n = tonumber(v)
        if n then return n end
    end
    return tonumber(tostring(id))
end

-- Resolve a location id to its name. The mirror table only fills when
-- data_package_changed fires, which it doesn't when apclientpp's package
-- cache is current -- so fall through to the client's own resolver.
local function location_name_from_id(key)
    local name = AP_LOCATIONS_BY_ID[key]
    if name then return name end
    if not AP_REF.APClient then return nil end
    local ok, raw = pcall(function()
        return AP_REF.APClient:get_location_name(key, nil)
    end)
    if not ok or raw == nil then return nil end
    name = Shared.clean_string(raw)
    if name == "" or name == "Unknown" then return nil end
    return name
end

-- Apply a batch of server-checked location ids to the ledger.
local function apply_ack_ids(ids)
    local changed, imported = 0, 0
    for _, id in ipairs(ids) do
        local key = coerce_id(id)
        local name = key and location_name_from_id(key)
        if name then
            local was_known = Ledger.is_checked(name)
            if Ledger.mark_acked(name) then
                changed = changed + 1
                if not was_known then imported = imported + 1 end
            end
        end
    end
    if changed > 0 then
        Ledger.flush()
        sync_diag(string.format(
            "server sync: %d location(s) confirmed%s", changed,
            imported > 0 and (", " .. imported .. " imported from server") or ""))
    end
end

-- Server acks can arrive before the ledger init; buffer them and drain
-- from on_frame once it's ready. (Name resolution goes through the client
-- itself, so the mirror table is not a precondition.)
local function drain_pending_acks()
    if #pending_acks == 0 then return end
    if not Ledger.is_init() then return end
    local ids = pending_acks
    pending_acks = {}
    apply_ack_ids(ids)
end

AP_REF.on_location_checked = function(locations)
    if type(locations) ~= "table" then return end
    if not Ledger.is_init() then
        for _, id in ipairs(locations) do
            table.insert(pending_acks, id)
        end
        return
    end
    apply_ack_ids(locations)
end

function M.set_completed_checks_filename(slot_name, seed)
    ledger_slot = slot_name
    ledger_seed = seed
end

-- Initializes the ledger for the current slot/seed: loads (or creates) the
-- ledger file, importing the legacy checks file once, then merges the
-- pre-connect journal.
function M.load_completed_checks()
    if not ledger_slot then
        M.log("load_completed_checks: slot/seed not set yet")
        return
    end

    -- Legacy import source (only consumed when no ledger file exists yet).
    local legacy = nil
    local legacy_file = "./AP_DRDR_Items/AP_DRDR_checks_"
        .. safe_filename(ledger_slot) .. "_" .. safe_filename(ledger_seed) .. ".json"
    local probe = io.open(legacy_file, "r")
    if probe then
        local has_content = probe:read(1) ~= nil
        probe:close()
        if has_content then
            local data = Shared.load_json(legacy_file)
            if data and type(data.checks) == "table" then
                legacy = data.checks
            end
        end
    end

    Ledger.init(ledger_slot, ledger_seed, legacy)

    -- Merge the pre-connect journal: checks detected before this connect
    -- belong to this slot now; the sync loop sends them.
    local merged = 0
    for name, _ in pairs(PENDING_CHECKS) do
        if Ledger.record(name, "pre-connect") then
            merged = merged + 1
        end
    end
    if next(PENDING_CHECKS) then
        PENDING_CHECKS = {}
        save_pending_checks()
    end
    if merged > 0 then
        M.log(string.format("merged %d pre-connect check(s) into the ledger", merged))
    end

    drain_pending_acks()
end

-- Public getter: has this location already been recorded as checked? Used by
-- AP_LocationTriggers to bootstrap per-counted-entry counters on startup --
-- e.g. if "Walk on 4 Treadmills" was sent in a previous session, the
-- treadmill counter starts at 4 so the 5th walk correctly sends count 5.
function M.is_completed(loc_name)
    return Ledger.is_checked(loc_name)
end

-- Arms the sync machine: on the next on_frame ticks, every unacked ledger
-- name is resolved and sent as ONE batched LocationChecks (the server
-- dedups). Names that can't resolve yet (data package still loading) keep
-- the machine armed and it retries every ~2s.
function M.arm_sync()
    sync_needed = true
end

-- Compat alias: main.lua's slot-connect handler calls this.
function M.resend_all_checks()
    M.arm_sync()
end

-- Diagnostic ack pull via the DataStorage API: the server keeps a
-- read-only key "_read_location_checks_{team}_{slot}" with the slot's
-- checked location ids. Normal ack flow is the location_checked push
-- (fires on RoomUpdate); this pull remains for manual diagnostics.
local pull_diagnosed = false
local ack_storage_key = nil

local function ack_key()
    if ack_storage_key then return ack_storage_key end
    local ok, key = pcall(function()
        local team = AP_REF.APClient:get_team_number()
        local slot = AP_REF.APClient:get_player_number()
        return string.format("_read_location_checks_%d_%d",
            tonumber(team) or 0, tonumber(slot) or 0)
    end)
    if ok and key then
        ack_storage_key = key
    end
    return ack_storage_key
end

local function pull_server_acks()
    if not is_connected() then return end
    if not Ledger.is_init() then return end

    local key = ack_key()
    if not key then return end

    local ok, err = pcall(function()
        AP_REF.APClient:Get({ key })
    end)
    if not pull_diagnosed then
        pull_diagnosed = true
        if ok then
            sync_diag("ack pull: DataStorage Get sent for " .. key)
        else
            sync_diag("ack pull: DataStorage Get FAILED (" .. tostring(err)
                .. ") -- acks disabled, resend-on-connect still covers sync")
        end
    end
end

-- Retrieved responses arrive as three tables; which one carries the
-- { [key] = value } map is undocumented, so probe all three. The first
-- invocation logs a preview of each argument.
local retrieved_diagnosed = false

local function table_preview(t)
    if type(t) ~= "table" then return type(t) end
    local ks, n = {}, 0
    for k, v in pairs(t) do
        n = n + 1
        if n <= 4 then
            table.insert(ks, tostring(k) .. "=" .. type(v))
        end
    end
    return string.format("table[%d]{%s}", n, table.concat(ks, ", "))
end

AP_REF.on_retrieved = function(a1, a2, a3)
    if not retrieved_diagnosed then
        retrieved_diagnosed = true
        sync_diag(string.format("retrieved fired: a1=%s a2=%s a3=%s",
            table_preview(a1), table_preview(a2), table_preview(a3)))
    end

    local key = ack_storage_key
    if not key then return end
    for _, cand in ipairs({ a1, a2, a3 }) do
        if type(cand) == "table" then
            local value = cand[key]
            if type(value) == "table" and #value > 0 then
                sync_diag(string.format(
                    "ack retrieved: %d checked id(s) from datastorage", #value))
                if not Ledger.is_init() then
                    for _, id in ipairs(value) do
                        table.insert(pending_acks, id)
                    end
                else
                    apply_ack_ids(value)
                end
                return
            end
        end
    end
end

-- Console: probe the binding's Get signature variants, logging each pcall
-- outcome. Run while connected; then watch for "retrieved handler FIRED".
_G.drap_bridge_get_test = function()
    if not AP_REF.APClient or not is_connected() then
        print("[Bridge] connect first")
        return
    end
    local key = ack_key()
    if not key then
        print("[Bridge] could not derive datastorage key")
        return
    end
    retrieved_diagnosed = false   -- re-log the arg preview for each response
    for label, call in pairs({
        ["Get({key})"]        = function() AP_REF.APClient:Get({ key }) end,
        ["Get({key}, {})"]    = function() AP_REF.APClient:Get({ key }, {}) end,
    }) do
        local ok, err = pcall(call)
        local msg = string.format("get test %s -> ok=%s%s", label, tostring(ok),
            ok and "" or (" err=" .. tostring(err)))
        print("[Bridge] " .. msg)
        sync_diag(msg)
    end
    print("[Bridge] now wait ~10s and check drap_sync_diag.log for 'retrieved handler FIRED'")
end

local function try_sync()
    if not is_connected() then return end

    local unacked = Ledger.unacked_names()
    if #unacked == 0 then
        sync_needed = false
        return
    end

    local ids, unresolved = {}, 0
    for _, name in ipairs(unacked) do
        local id = resolve_location_id(name)
        if id then
            table.insert(ids, tonumber(id) or id)
        else
            unresolved = unresolved + 1
        end
    end

    -- Nothing resolves -> the data package almost certainly isn't loaded
    -- yet; stay armed and retry.
    if #ids == 0 then return end

    local ok = pcall(AP_REF.APClient.LocationChecks, AP_REF.APClient, ids)
    if ok then
        sync_diag(string.format("sync: sent %d location check(s) in one batch%s",
            #ids, unresolved > 0
                and string.format(" (%d name(s) not in this seed's data package)", unresolved)
                or ""))
        sync_needed = false
        -- The server answers this batch with a RoomUpdate carrying the full
        -- checked set; the location_checked push applies it as acks.
    end
end

-- Sync tick. Runs on its own re.on_frame below: the main loop only calls
-- module on_frame while in-game, but connects happen at the title screen.
local function sync_tick()
    drain_pending_acks()
    if sync_needed and os.clock() - last_sync_try > 2.0 then
        last_sync_try = os.clock()
        pcall(try_sync)
    end
    -- NOTE: no periodic datastorage pull. Acks arrive via the
    -- location_checked push, which fires on every RoomUpdate -- and the
    -- connect-time batch resend itself triggers one, so every session
    -- reconciles without polling. (The datastorage Get response map also
    -- marshals empty on this binding; drap_bridge_pull_acks remains for
    -- diagnostics.)
end

-- Console: dump the APClient binding's available methods (sol2 usertype
-- metatable walk). Used to discover whether this lua-apclientpp build
-- exposes checked-location state under any name -- get_checked_locations
-- is absent (verified 2026-07-05) and the location_checked push never
-- fires, so if nothing shows up here, acks are permanently unavailable on
-- this DLL and resend-on-connect is the accepted sync mechanism.
_G.drap_bridge_client_methods = function()
    if not AP_REF.APClient then
        print("[Bridge] no APClient (connect first)")
        return
    end
    local mt = getmetatable(AP_REF.APClient)
    if not mt then
        print("[Bridge] client has no metatable (unexpected)")
        return
    end
    local names = {}
    local function collect(t)
        if type(t) ~= "table" then return end
        for k, v in pairs(t) do
            if type(k) == "string" then
                table.insert(names, k .. " (" .. type(v) .. ")")
            end
        end
    end
    collect(mt)
    local ok_idx = pcall(function() collect(mt.__index) end)
    table.sort(names)
    print(string.format("[Bridge] client metatable entries (%d):", #names))
    for _, n in ipairs(names) do
        print("  " .. n)
    end
    if #names == 0 then
        print("  (none visible -- sol2 may hide members behind a function __index)")
    end
end

-- Console: force an immediate ack pull, reporting every precondition so a
-- no-op is never silent.
_G.drap_bridge_pull_acks = function()
    if not AP_REF.APClient then
        print("[Bridge] pull blocked: no APClient (connect first)")
        return
    end
    if not is_connected() then
        print("[Bridge] pull blocked: not connected")
        return
    end
    if not Ledger.is_init() then
        print("[Bridge] pull blocked: ledger not initialized (slot-connect incomplete)")
        return
    end
    pull_diagnosed = false   -- re-log the diagnostic verdict
    pull_server_acks()
    local s = Ledger.stats()
    print(string.format("[Bridge] ledger: %d known, %d acked", s.total, s.acked))
end

local bound_once = false

re.on_frame(function()
    -- Handler rebinding must not wait for gameplay: connects happen at the
    -- title screen, where main's module loop (which used to trigger this
    -- via M.on_frame) never runs.
    if not bound_once and AP_REF.APClient then
        bound_once = true
        pcall(M.bind_client)
    end
    pcall(sync_tick)
end)

function M.reset_completed_checks()
    Ledger.reset()
    M.log("Completed checks reset")
end

-- Returns true if the given location name has been checked in this slot/seed.
-- Used by effect modules that need to reconstruct per-location state after a
-- reload.
function M.has_completed_check(loc_name)
    return Ledger.is_checked(loc_name)
end

-- Returns a fresh array of all completed-check location names. Used for
-- diagnostics ("what's actually in here?") rather than per-name queries.
function M.get_completed_checks()
    return Ledger.all_names()
end

-- Diagnostic: returns the file paths and counts so we can verify slot-connect
-- ran set_*_filename properly. Called from drap_bridge_diag console command.
function M.get_diag_state()
    local ls = Ledger.stats()
    return {
        ledger_file            = ls.file,
        completed_checks_count = ls.total,
        acked_count            = ls.acked,
        sync_armed             = sync_needed,
        received_items_file    = RECEIVED_ITEMS_FILE,
        received_items_count   = #RECEIVED_ITEMS,
        last_item_index        = last_item_index,
    }
end

-- Force-set the filenames using a provided slot/seed. Recovery path when
-- slot-connect fired but somehow didn't reach the set_*_filename calls
-- (e.g. an unhandled exception earlier in the slot-connect handler).
function M.force_init_files(slot, seed)
    slot = slot or (AP_REF and AP_REF.APSlot) or "unknown"
    seed = seed or "unknown"
    M.set_received_items_filename(slot, seed)
    M.set_completed_checks_filename(slot, seed)
    M.load_completed_checks()
    local ls = Ledger.stats()
    M.log(string.format("force_init_files: slot=%s seed=%s -> LEDGER=%s RI_FILE=%s",
        slot, seed,
        tostring(ls.file), tostring(RECEIVED_ITEMS_FILE)))
end

_G.drap_bridge_diag = function()
    local s = M.get_diag_state()
    print(string.format("[Bridge-diag] LEDGER_FILE           = %s", tostring(s.ledger_file)))
    print(string.format("[Bridge-diag] RECEIVED_ITEMS_FILE   = %s", tostring(s.received_items_file)))
    print(string.format("[Bridge-diag] locations known        = %d (%d server-acked)",
        s.completed_checks_count, s.acked_count))
    print(string.format("[Bridge-diag] sync armed             = %s", tostring(s.sync_armed)))
    print(string.format("[Bridge-diag] received_items count   = %d", s.received_items_count))
    print(string.format("[Bridge-diag] last_item_index        = %s", tostring(s.last_item_index)))
    print(string.format("[Bridge-diag] AP_REF.APSlot          = %s",
        tostring(AP_REF and AP_REF.APSlot)))
end

-- Manual recovery: re-initialize the file paths if slot-connect didn't
-- complete. Pass slot + seed (look at the existing JSON filenames in the
-- data dir to find them; e.g. AP_DRDR_checks_<slot>_<seed>.json).
_G.drap_bridge_force_init = function(slot, seed)
    slot = slot or (AP_REF and AP_REF.APSlot)
    if not slot or not seed then
        print("[Bridge-init] Usage: drap_bridge_force_init('slot_name', 'seed_name')")
        print("[Bridge-init] Look at the JSON filenames in your reframework/data/AP_DRDR_Items/ dir")
        print("[Bridge-init] e.g. AP_DRDR_checks_<slot>_<seed>.json -> drap_bridge_force_init('<slot>', '<seed>')")
        return
    end
    M.force_init_files(slot, seed)
    print("[Bridge-init] Done. Run drap_bridge_diag to verify.")
end

re.on_config_save(function() Ledger.flush() end)
re.on_script_reset(function() Ledger.flush() end)

------------------------------------------------------------
-- Game Item Number Mapping
------------------------------------------------------------

-- Maps item names to their game item numbers (for spawning)
local ITEM_NAME_TO_GAME_NO = {}

--- Registers a mapping from item name to game item number
--- @param item_name string The AP item name
--- @param game_item_no number The game's internal item number
function M.register_game_item_number(item_name, game_item_no)
    ITEM_NAME_TO_GAME_NO[item_name] = game_item_no
end

--- Gets the game item number for an item name
--- @param item_name string The AP item name
--- @return number|nil The game item number or nil
function M.get_game_item_number(item_name)
    return ITEM_NAME_TO_GAME_NO[item_name]
end

------------------------------------------------------------
-- Item Tracking & Persistence
-- (RECEIVED_ITEMS / RECEIVED_ITEMS_BY_NAME / last_item_index /
--  RECEIVED_ITEMS_FILE declared at top of file)
------------------------------------------------------------


function M.set_received_items_filename(slot_name, seed)
    local slot = safe_filename(slot_name)
    local sd = safe_filename(seed)
    RECEIVED_ITEMS_FILE = "./AP_DRDR_Items/AP_DRDR_items_" .. slot .. "_" .. sd .. ".json"
end

save_received_items = function()
    if not RECEIVED_ITEMS_FILE then return end
    local data = {
        last_item_index = last_item_index or -1,
        items = RECEIVED_ITEMS or {},
    }
    Shared.save_json(RECEIVED_ITEMS_FILE, data, 4, M.log)
end

function M.reset_received_items()
    M.log("Resetting received items file for fresh sync")
    RECEIVED_ITEMS = {}
    RECEIVED_ITEMS_BY_NAME = {}
    last_item_index = -1
    pending_items = {}
    save_received_items()
end

-- Restore RECEIVED_ITEMS / last_item_index from disk on slot connect. The
-- on_items_received filter (`index > last_item_index`) then naturally splits
-- the server's item-history replay into:
--   * already-applied items  -> skipped (index <= last_item_index)
--   * received-while-offline  -> applied as fresh (index > last_item_index)
-- Without this, reset_received_items() wipes last_item_index back to -1 and
-- every history item gets re-applied as fresh -- which causes traps with
-- on_replay="skip" to fire again on every reconnect, since on_replay is
-- only consulted by the manual reapply path, not the on-connect dispatch.
function M.load_received_items()
    if not RECEIVED_ITEMS_FILE then
        M.log("load_received_items: filename not set yet")
        return
    end
    local data = Shared.load_json(RECEIVED_ITEMS_FILE, M.log)
    if not data then
        M.log("No existing received-items file; starting fresh")
        RECEIVED_ITEMS = {}
        RECEIVED_ITEMS_BY_NAME = {}
        last_item_index = -1
        pending_items = {}
        return
    end
    RECEIVED_ITEMS = data.items or {}
    RECEIVED_ITEMS_BY_NAME = {}
    for _, entry in ipairs(RECEIVED_ITEMS) do
        local n = entry and entry.item_name
        if n and n ~= "" then
            RECEIVED_ITEMS_BY_NAME[n] = (RECEIVED_ITEMS_BY_NAME[n] or 0) + 1
        end
    end
    last_item_index = tonumber(data.last_item_index) or -1
    pending_items = {}
    M.log(string.format("Loaded %d received items, last_item_index=%d",
        #RECEIVED_ITEMS, last_item_index))
end

re.on_config_save(save_received_items)
re.on_script_reset(save_received_items)

------------------------------------------------------------
-- Item Check Helpers
------------------------------------------------------------

function M.has_item_name(name)
    return (RECEIVED_ITEMS_BY_NAME[name] or 0) > 0
end

function M.get_all_received_items()
    return RECEIVED_ITEMS
end

------------------------------------------------------------
-- Item Handlers Registry
------------------------------------------------------------
--
-- The actual registry lives in DRAP/ItemEffects.lua. The two functions below
-- are legacy shims: they forward (name, fn) / (id, fn) registrations into the
-- new declarative registry with on_replay="apply" (the pre-ItemEffects default
-- behavior). New code should call ItemEffects.register(...) directly so it can
-- opt into category dispatch and on_replay="skip" semantics (traps).

-- Silent: the legacy path feeds in per-item auto-registrations where duplicate
-- display names are expected (e.g. multiple "Chair" variants in drdr_items.json).
-- A collision between two NEW effect modules -- which is a real bug signal --
-- still warns because those callers use ItemEffects.register() directly.
local SHIM_OPTS = { silent = true }

function M.register_item_handler_by_name(name, fn)
    ItemEffects.register(name, {
        apply = function(ctx) fn(ctx.net_item, ctx.item_name, ctx.sender_name) end,
        on_replay = "apply",
    }, SHIM_OPTS)
end

function M.register_item_handler_by_id(id, fn)
    ItemEffects.register_by_id(id, {
        apply = function(ctx) fn(ctx.net_item, ctx.item_name, ctx.sender_name) end,
        on_replay = "apply",
    }, SHIM_OPTS)
end

function M.default_item_handler(net_item, item_name, sender_name)
    M.log("Unhandled item id=" .. tostring(net_item.item) .. " name=" .. tostring(item_name) .. " from " .. tostring(sender_name))
end

------------------------------------------------------------
-- Item Application
------------------------------------------------------------

local function handle_net_item(net_item, is_replay)
    local item_id = net_item.item
    local sender = net_item.player
    local index = net_item.index or -1

    local item_name_raw = AP_REF.APClient:get_item_name(item_id, nil)
    local sender_name_raw = AP_REF.APClient:get_player_alias(sender)

    -- Clean strings from AP client to remove any binary garbage
    local item_name = Shared.clean_string(item_name_raw)
    local sender_name = Shared.clean_string(sender_name_raw)

    M.log("Applying item index=" .. tostring(index) .. " id=" .. tostring(item_id) .. " (" .. item_name .. ") from " .. sender_name .. " (replay=" .. tostring(is_replay) .. ")")

    -- Look up the game item number from our registered mappings
    local game_item_no = ITEM_NAME_TO_GAME_NO[item_name]

    if not is_replay then
        table.insert(RECEIVED_ITEMS, {
            index = index,
            item_id = item_id,
            item_name = item_name,
            sender = sender,
            game_item_no = game_item_no,  -- Store game item number for spawning
        })

        if item_name and item_name ~= "" then
            RECEIVED_ITEMS_BY_NAME[item_name] = (RECEIVED_ITEMS_BY_NAME[item_name] or 0) + 1
        end

        -- Persist immediately so a crash/reset doesn't lose the receipt.
        -- Mirrors the per-check save in M.check above.
        save_received_items()
    end

    local handled = ItemEffects.dispatch(net_item, item_name, sender_name, is_replay)
    if not handled then
        M.default_item_handler(net_item, item_name, sender_name)
    end

    -- Native in-game toast for the item-receive (skip replays -- those are
    -- save-load reapplies, not new items, so no notification noise).
    -- Lazy require so Notify only loads if/when an item actually arrives.
    if not is_replay and AP_REF.APClient then
        local ok_n, Notify = pcall(require, "DRAP/Notify")
        if ok_n and Notify then
            local self_player = AP_REF.APClient:get_player_number()
            local is_self = (sender == self_player)
            local flags = tonumber(net_item.flags) or 0
            pcall(Notify.item_received, item_name, flags, sender_name, is_self)
        end
    end
end

AP_REF.on_items_received = function(items)
    if not items then return end

    for _, net_item in ipairs(items) do
        if net_item.index and net_item.index > last_item_index then
            -- Check if data package is actually ready by testing name resolution
            local test_name = AP_REF.APClient:get_item_name(net_item.item, nil)
            local resolvable = test_name ~= nil and test_name ~= "Unknown"
            -- Queue when unresolvable, OR when older items are already queued:
            -- processing this one now would advance last_item_index past the
            -- queued indices, and the on_frame drain (index > last_item_index)
            -- would then discard them forever.
            if not resolvable or #pending_items > 0 then
                M.log("Queuing item index=" .. tostring(net_item.index) .. " id=" .. tostring(net_item.item)
                    .. (resolvable and " (preserving queue order)" or " (data package not ready)"))
                table.insert(pending_items, net_item)
            else
                last_item_index = net_item.index
                handle_net_item(net_item, false)
            end
        end
    end
end

-- Sent-item toast: when an "ItemSend" PrintJSON arrives where WE are the
-- source and the receiver is someone else, show a native notification with
-- the same color scheme as item_received (item-flag colored, names bold).
-- The imgui Archipelago client window already shows these in its chat log;
-- this just mirrors them on the in-game UI.
AP_REF.on_print_json = function(msg, extra)
    if not extra or not AP_REF.APClient then return end
    -- Only ItemSend (other types: Hint, ItemCheat, Tutorial, etc. -- skip)
    if extra.type ~= "ItemSend" then return end
    if not extra.item or not extra.receiving then return end

    local self_player = AP_REF.APClient:get_player_number()
    local sender_slot = tonumber(extra.item.player)
    local receiver_slot = tonumber(extra.receiving)
    if not sender_slot or not receiver_slot then return end

    -- Skip cases handled elsewhere:
    --   * Self -> self ("Found your X") -- already toasted by on_items_received
    --   * Anyone -> us -- already toasted by on_items_received
    -- We only want WE -> others.
    if sender_slot ~= self_player then return end
    if receiver_slot == self_player then return end

    local item_id = tonumber(extra.item.item)
    local item_flags = tonumber(extra.item.flags) or 0
    if not item_id then return end

    local recv_game = AP_REF.APClient:get_player_game(receiver_slot)
    local item_name_raw = AP_REF.APClient:get_item_name(item_id, recv_game)
    if not item_name_raw or item_name_raw == "" or item_name_raw == "Unknown" then
        return
    end
    local item_name = Shared.clean_string(item_name_raw)
    local sender_name = Shared.clean_string(AP_REF.APClient:get_player_alias(sender_slot))
    local recv_name = Shared.clean_string(AP_REF.APClient:get_player_alias(receiver_slot))

    local ok_n, Notify = pcall(require, "DRAP/Notify")
    if ok_n and Notify then
        pcall(Notify.item_sent, sender_name, item_name, item_flags, recv_name)
    end
end

function M.reapply_all_items()
    M.log("Reapplying " .. tostring(#RECEIVED_ITEMS) .. " previously received items...")

    for _, entry in ipairs(RECEIVED_ITEMS) do
        local fake_net_item = {
            index = entry.index,
            item = entry.item_id,
            player = entry.sender
        }
        handle_net_item(fake_net_item, true)
    end
end

------------------------------------------------------------
-- Per-frame Update
------------------------------------------------------------

function M.on_frame()
    -- (Handler binding happens in the ungated re.on_frame hook above --
    -- this in-game loop only drains the pending-items queue.)

    -- Process queued items once data package is actually available
    if #pending_items > 0 then
        local test_name = AP_REF.APClient and AP_REF.APClient:get_item_name(pending_items[1].item, nil)
        if test_name and test_name ~= "Unknown" then
            M.log("Processing " .. tostring(#pending_items) .. " items queued before data package")
            local queue = pending_items
            pending_items = {}
            -- Strictly ascending index order so last_item_index never jumps
            -- past an unprocessed entry.
            table.sort(queue, function(a, b)
                return (a.index or 0) < (b.index or 0)
            end)
            for _, queued in ipairs(queue) do
                if queued.index and queued.index > last_item_index then
                    last_item_index = queued.index
                    handle_net_item(queued, false)
                end
            end
        end
    end
end

M.AP_REF = AP_REF
return M