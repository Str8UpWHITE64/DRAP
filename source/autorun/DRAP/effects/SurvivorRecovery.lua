-- DRAP/effects/SurvivorRecovery.lua
-- Self-healing for broken survivor spawns (the Twin Sisters bug class).
--
-- Problem: certain histories (e.g. an in-session reload crossing a scoop
-- receipt under pre-1.2.0 code) leave a scoop engine-active while its
-- survivor's NpcBaseInfo is missing or a zeroed corpse (state=0 hp=0 area=0
-- isDead). The engine never retries, so the survivor can never spawn.
-- Fix: clear the broken record and spawnNPC at the survivor's known position
-- via the same engine path HostileSurvivorTrap uses.
--
-- Two halves:
--   HARVESTER (passive): records the FIRST healthy sighting of each survivor
--   (position/area/state) into a persistent positions DB. Boss-gated NPCs
--   (hostages that only appear during/after psycho fights) are absent at
--   scoop-start and so never enter the DB at start-state.
--
--   REPAIR (area ENTRY only): for each DRAP-active Survivor-category scoop
--   whose survivor's DB home area was just entered, wait REPAIR_SETTLE_SECONDS
--   for the engine's lazy creation, then -- only if the record is STILL
--   missing or a zeroed corpse -- clear debris and respawn at the DB position.
--
-- Guards:
--   * area-ENTRY edge only -- avoids pre-empting NPCs the engine would spawn
--     itself on a later re-entry;
--   * settle delay + strict signature -- never races lazy creation;
--   * spawns only when no healthy record exists -- no duplicates;
--   * Survivor-category scoops only -- psycho-scoop NPCs (hostages, boss-gated
--     spawns) are never auto-spawned; use drap_recover_force for those.

local Shared = require("DRAP/Shared")
local SharedData = require("DRAP/SharedData")

local M = Shared.create_module("SurvivorRecovery")
M:set_throttle(1.0)

local npc_mgr = M:add_singleton("npc", "app.solid.gamemastering.NpcManager")
local am_mgr  = M:add_singleton("am",  "app.solid.gamemastering.AreaManager")

local DB_FILE = "./AP_DRDR_Items/AP_DRDR_survivor_positions.json"
local TRAP_POOL_MIN_STYPE = 59
local REPAIR_SETTLE_SECONDS = 5.0

------------------------------------------------------------
-- Survivor identity maps (from shared data)
------------------------------------------------------------

local stype_to_name = nil
local name_to_stype = nil

local function ensure_maps()
    if stype_to_name then return end
    stype_to_name, name_to_stype = {}, {}
    for _, row in ipairs(SharedData.survivors()) do
        local stype = tonumber(row.item_number)
        if row.name and stype and stype < TRAP_POOL_MIN_STYPE then
            stype_to_name[stype] = row.name
            name_to_stype[row.name] = stype
        end
    end
end

------------------------------------------------------------
-- Positions DB (persistent; first healthy sighting wins)
------------------------------------------------------------

local db = nil
local db_dirty = false

local function load_db()
    if db then return end
    -- Local harvests overlay the positions bundled in drdr_shared.json,
    -- so fresh installs ship with full coverage and local sightings can
    -- still refine or extend it.
    db = {}
    for stype_s, e in pairs(SharedData.survivor_positions()) do
        db[stype_s] = e
    end
    for stype_s, e in pairs(Shared.load_json_if_exists(DB_FILE) or {}) do
        db[stype_s] = e
    end
end

local function save_db()
    if not db_dirty then return end
    if Shared.save_json(DB_FILE, db, 2, M.log) then
        db_dirty = false
    end
end

local function db_get(stype)
    load_db()
    return db[tostring(stype)]
end

local function db_put(stype, entry)
    load_db()
    db[tostring(stype)] = entry
    db_dirty = true
end

------------------------------------------------------------
-- NpcBaseInfo access
------------------------------------------------------------

local function read_record(info)
    local e = { info = info }
    pcall(function()
        local v = info:get_field("<Name>k__BackingField")
        e.stype = tonumber(v) or tonumber(tostring(v))
    end)
    pcall(function() e.state = tonumber(info:get_field("mLiveState")) end)
    pcall(function() e.area = tonumber(info:get_field("mAreaNo")) end)
    pcall(function() e.hp = tonumber(info:get_field("mVitalNew")) end)
    pcall(function()
        local p = info:get_field("mPos")
        if p then e.x, e.y, e.z = p.x, p.y, p.z end
    end)
    local ok_d, dead = pcall(function() return info:call("isDead") end)
    e.is_dead = ok_d and dead == true
    return e
end

-- Returns records grouped by stype: { [stype] = { entries... } }
local function scan_records()
    local mgr = npc_mgr:get()
    if not mgr then return nil end
    local list_field = npc_mgr:get_field("NpcInfoList")
    local list = list_field and Shared.safe_get_field(mgr, list_field)
    if not list then return nil end
    local by_stype = {}
    local count = Shared.get_collection_count(list) or 0
    for i = 0, count - 1 do
        local info = Shared.get_collection_item(list, i)
        if info then
            local e = read_record(info)
            if e.stype then
                by_stype[e.stype] = by_stype[e.stype] or {}
                table.insert(by_stype[e.stype], e)
            end
        end
    end
    return by_stype
end

local function is_zeroed_corpse(e)
    return e.is_dead and (e.state or 0) == 0 and (e.hp or 0) == 0
end

------------------------------------------------------------
-- Passive harvester
------------------------------------------------------------

-- First healthy sighting per stype: pre-recruit states only. States 0/1 are
-- free-standing survivors; state 5 is captive/hostage idle (Jennifer Gorman,
-- Jo's captives -- an earlier state<=1 filter wrongly rejected them). States 4
-- (joined/escorting) and 8 are post-recruit and never harvested, nor is anyone
-- in the safety rooms (a rescued NPC's position isn't their spawn point).
local HARVEST_STATES = { [0] = true, [1] = true, [5] = true }
local SAFETY_AREAS = { [288] = true, [292] = true }

local function harvest(by_stype)
    ensure_maps()
    local added = 0
    for stype, entries in pairs(by_stype) do
        if stype < TRAP_POOL_MIN_STYPE and stype_to_name[stype]
            and not db_get(stype) then
            for _, e in ipairs(entries) do
                if not e.is_dead and HARVEST_STATES[e.state or -1]
                    and (e.hp or 0) > 0
                    and not SAFETY_AREAS[e.area or -1]
                    and e.x and (e.x ~= 0 or e.z ~= 0) then
                    db_put(stype, {
                        name = stype_to_name[stype],
                        x = e.x, y = e.y, z = e.z,
                        area = e.area, state = e.state, hp = e.hp,
                    })
                    added = added + 1
                    M.log(string.format(
                        "harvested %s (stype=%d): area=%d pos=(%.2f, %.2f, %.2f) state=%d",
                        stype_to_name[stype], stype, e.area or -1,
                        e.x, e.y, e.z, e.state or -1))
                    break
                end
            end
        end
    end
    if added > 0 then save_db() end
end

------------------------------------------------------------
-- Repair
------------------------------------------------------------

-- stype -> scoop name for survivors whose SURVIVOR-category scoop is
-- currently active (received + not completed). Psycho-scoop NPCs are
-- deliberately excluded from auto-repair.
local function eligible_survivors()
    ensure_maps()
    local su = _G.AP and _G.AP.ScoopUnlocker
    if not su or not su.get_all_status then return {} end
    local out = {}
    local ok, status = pcall(su.get_all_status)
    if not ok or type(status) ~= "table" then return out end
    for _, s in ipairs(status) do
        if s.category == "Survivor" and s.received and not s.completed
            and type(s.npcs) == "table" then
            for _, npc_name in ipairs(s.npcs) do
                local stype = name_to_stype[npc_name]
                if stype then out[stype] = s.name end
            end
        end
    end
    return out
end

local function clear_records_for(stype)
    local mgr = npc_mgr:get()
    if not mgr then return 0 end
    local by_stype = scan_records()
    local removed = 0
    for _, e in ipairs((by_stype or {})[stype] or {}) do
        local ok = pcall(function()
            mgr:call("removeInformation(app.solid.npc.NpcBaseInfo)", e.info)
        end)
        if ok then removed = removed + 1 end
    end
    return removed
end

local spawn_pending = {}   -- stype -> { started, entry, scoop }

local function spawn_at(stype, entry, scoop_name, forced)
    local mgr = npc_mgr:get()
    if not mgr then return false end
    local pos, rot
    pcall(function() pos = Vector3f.new(entry.x, entry.y, entry.z) end)
    pcall(function() rot = Quaternion.new(1, 0, 0, 0) end)
    if not pos or not rot then return false end

    local removed = clear_records_for(stype)
    local ok = pcall(function()
        mgr:call("spawnNPC(app.solid.SurvivorDefine.SurvivorType, "
            .. "via.vec3, via.Quaternion, "
            .. "solid.MT2RE.cUnitPropertyContainer, "
            .. "System.Action`1<via.GameObject>)",
            stype, pos, rot, nil, nil)
    end)
    M.log(string.format(
        "REPAIR%s: respawning %s (stype=%d, scoop='%s') at (%.2f, %.2f, %.2f)"
            .. " -- cleared %d broken record(s), spawnNPC=%s",
        forced and " (forced)" or "", entry.name or "?", stype,
        scoop_name or "?", entry.x, entry.y, entry.z, removed,
        ok and "ok" or "FAILED"))
    if ok then
        spawn_pending[stype] = {
            started = os.clock(), entry = entry, scoop = scoop_name,
        }
    end
    return ok
end

local function finish_pending_spawns()
    if not next(spawn_pending) then return end
    local mgr = npc_mgr:get()
    if not mgr then return end
    for stype, st in pairs(spawn_pending) do
        local elapsed = os.clock() - st.started
        if elapsed > 30.0 then
            M.log(string.format("repair %s: BaseInfo never appeared (30s)",
                st.entry.name or stype))
            spawn_pending[stype] = nil
        elseif elapsed >= 1.0 then
            local info
            pcall(function() info = mgr:call("searchInformation", stype) end)
            if info then
                local dead
                pcall(function() dead = info:call("isDead") end)
                if dead == false then
                    pcall(function()
                        info:set_field("mAreaNo", st.entry.area)
                    end)
                    pcall(function()
                        info:call("setLiveState", st.entry.state or 1)
                    end)
                    M.log(string.format("repair %s: alive (%.1fs, state=%d)",
                        st.entry.name or stype, elapsed, st.entry.state or 1))
                    spawn_pending[stype] = nil
                end
            end
        end
    end
end

------------------------------------------------------------
-- Area-entry detection + settle timer
------------------------------------------------------------

local last_area = nil
local entry_check = nil   -- { area, at } pending settle check

local function get_area()
    local am = am_mgr:get()
    if not am then return nil end
    local f = am_mgr:get_field("mAreaIndex", false)
    if not f then return nil end
    return Shared.to_int(Shared.safe_get_field(am, f))
end

local function run_repair_check(area)
    local eligible = eligible_survivors()
    if not next(eligible) then return end
    local by_stype = scan_records()
    if not by_stype then return end

    for stype, scoop_name in pairs(eligible) do
        local entry = db_get(stype)
        if entry and entry.area == area then
            local entries = by_stype[stype]
            local healthy = false
            local corpse_only = true
            for _, e in ipairs(entries or {}) do
                if not is_zeroed_corpse(e) then corpse_only = false end
                if not e.is_dead and (e.hp or 0) > 0 then healthy = true end
            end
            local broken = (entries == nil)                  -- still missing
                or (#(entries or {}) > 0 and corpse_only)    -- only corpses
            if broken and not healthy and not spawn_pending[stype] then
                spawn_at(stype, entry, scoop_name, false)
            end
        end
    end
end

------------------------------------------------------------
-- Frame driver
------------------------------------------------------------

function M.on_frame()
    if not M:should_run() then return end
    if not Shared.is_in_game() then
        last_area = nil
        entry_check = nil
        return
    end

    finish_pending_spawns()

    local area = get_area()
    if area and area ~= last_area then
        -- Area-ENTRY edge: schedule the repair check after the engine's
        -- own lazy creation has had time to act.
        if last_area ~= nil then
            entry_check = { area = area, at = os.clock() + REPAIR_SETTLE_SECONDS }
        end
        last_area = area
    end

    if entry_check and os.clock() >= entry_check.at then
        local check = entry_check
        entry_check = nil
        if get_area() == check.area then
            run_repair_check(check.area)
        end
    end

    -- Passive harvest piggybacks the same throttle; cheap scan.
    local by_stype = scan_records()
    if by_stype then harvest(by_stype) end
end

------------------------------------------------------------
-- Console
------------------------------------------------------------

_G.drap_recover_status = function()
    load_db()
    ensure_maps()
    local n = 0
    for _ in pairs(db) do n = n + 1 end
    M.log(string.format("positions DB: %d survivors harvested -> %s", n, DB_FILE))
    local names = {}
    for stype_s, e in pairs(db) do
        table.insert(names, string.format("%s(%s@%s)",
            e.name or "?", stype_s, tostring(e.area)))
    end
    table.sort(names)
    M.log("  " .. table.concat(names, ", "))
end

-- Manual repair for anything auto-repair deliberately skips (psycho-scoop
-- NPCs, boss-gated hostages). Requires a DB entry.
_G.drap_recover_force = function(stype)
    stype = tonumber(stype)
    ensure_maps()
    local entry = db_get(stype)
    if not entry then
        M.log(string.format("no DB position for stype %s -- visit them on a "
            .. "healthy save first (harvester) ", tostring(stype)))
        return
    end
    spawn_at(stype, entry, "manual", true)
end

return M
