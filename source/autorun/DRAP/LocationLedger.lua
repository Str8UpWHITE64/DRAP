-- DRAP/LocationLedger.lua
-- Single persisted record of every location check this slot/seed has ever
-- detected locally, plus what the server has confirmed.
--
-- Replaces Bridge's COMPLETED_CHECKS list (Bug 5 Phase 1). One JSON
-- document per slot/seed:
--
--   {
--     "schema_version": 1,
--     "slot": "...", "seed": "...",
--     "locations": {
--       "<location name>": {
--         "source": "check|pre-connect|legacy|server",
--         "detected_at": <os.time()>,
--         "acked": <bool>        -- true once the SERVER reported it checked
--       }, ...
--     }
--   }
--
-- Name-keyed: names are stable across sessions while AP ids need the data
-- package. Bridge owns id resolution and network traffic; this module is
-- pure state + persistence.
--
-- Sections: other trackers ("scoops", "player_stats", "stickers") store
-- their whole per-seed documents here too, so a run is one file.
--
-- Write policy: new records/sections persist immediately; ack marking is
-- batched -- callers flush() once per server update.

local Shared = require("DRAP/Shared")

local M = {}
local log = Shared.create_logger("LocationLedger")

local SCHEMA_VERSION = 2   -- v2: added "sections"; v1 files load unchanged

local FILE = nil
local L = nil          -- the document, nil until init()
local dirty = false

------------------------------------------------------------
-- Persistence
------------------------------------------------------------

local function save()
    if not FILE or not L then return end
    Shared.save_json(FILE, L, 2, log)
    dirty = false
end

local load_json_if_exists = Shared.load_json_if_exists

------------------------------------------------------------
-- Public API
------------------------------------------------------------

--- Initializes (or re-initializes) the ledger for a slot/seed.
--- @param slot string
--- @param seed string
--- @param legacy_names table|nil Array of location names from the old
---        AP_DRDR_checks file, imported once when no ledger file exists.
--- @return number count of locations in the ledger after init
function M.init(slot, seed, legacy_names)
    local safe_slot = Shared.sanitize_token(slot or "unknown")
    local safe_seed = Shared.sanitize_token(seed or "unknown")
    FILE = string.format("./AP_DRDR_Items/AP_DRDR_ledger_%s_%s.json",
        safe_slot, safe_seed)

    local data = load_json_if_exists(FILE)
    if data and type(data.locations) == "table" then
        L = data
        L.schema_version = L.schema_version or SCHEMA_VERSION
    else
        L = {
            schema_version = SCHEMA_VERSION,
            slot = tostring(slot or "unknown"),
            seed = tostring(seed or "unknown"),
            locations = {},
        }
        local migrated = 0
        for _, name in ipairs(legacy_names or {}) do
            if type(name) == "string" and not L.locations[name] then
                L.locations[name] = {
                    source = "legacy",
                    detected_at = os.time(),
                    acked = false,
                }
                migrated = migrated + 1
            end
        end
        save()
        if migrated > 0 then
            log(string.format("migrated %d location(s) from legacy checks file", migrated))
        end
    end

    local count = 0
    for _ in pairs(L.locations) do count = count + 1 end
    log(string.format("ledger ready: %s (%d locations)", FILE, count))
    return count
end

function M.is_init()
    return L ~= nil
end

--- Records a locally-detected check. Persists immediately when new.
--- @param name string Location name
--- @param source string|nil Where it came from (default "check")
--- @return boolean true if this is a NEW entry
function M.record(name, source)
    if not L or type(name) ~= "string" or name == "" then return false end
    if L.locations[name] then return false end
    L.locations[name] = {
        source = source or "check",
        detected_at = os.time(),
        acked = false,
    }
    save()
    return true
end

--- Has this location ever been detected (locally or via server import)?
function M.is_checked(name)
    return L ~= nil and L.locations[name] ~= nil
end

--- Marks a location as server-confirmed. Batched: call flush() after.
--- Creates the entry (source "server") if the server knows a check we
--- don't -- self-heals a lost/deleted local file.
--- @return boolean true if anything changed
function M.mark_acked(name)
    if not L or type(name) ~= "string" then return false end
    local entry = L.locations[name]
    if not entry then
        L.locations[name] = {
            source = "server",
            detected_at = os.time(),
            acked = true,
        }
        dirty = true
        return true
    end
    if not entry.acked then
        entry.acked = true
        dirty = true
        return true
    end
    return false
end

--- Persists pending batched changes (ack marks).
function M.flush()
    if dirty then save() end
end

--- Array of names the server has not yet confirmed.
function M.unacked_names()
    local out = {}
    if not L then return out end
    for name, entry in pairs(L.locations) do
        if not entry.acked then table.insert(out, name) end
    end
    table.sort(out)
    return out
end

--- Array of every known location name.
function M.all_names()
    local out = {}
    if not L then return out end
    for name in pairs(L.locations) do table.insert(out, name) end
    table.sort(out)
    return out
end

function M.stats()
    local total, acked = 0, 0
    if L then
        for _, entry in pairs(L.locations) do
            total = total + 1
            if entry.acked then acked = acked + 1 end
        end
    end
    return { total = total, acked = acked, file = FILE }
end

------------------------------------------------------------
-- Sections: whole-document storage for other trackers
------------------------------------------------------------

--- Returns a section's stored document, or nil if never written.
--- The returned table is live -- treat it as read-only and write back
--- through set_section.
function M.get_section(name)
    if not L or type(L.sections) ~= "table" then return nil end
    return L.sections[name]
end

--- Replaces a section's document and persists immediately.
--- @return boolean success
function M.set_section(name, doc)
    if not L or type(name) ~= "string" then return false end
    L.sections = L.sections or {}
    L.sections[name] = doc
    save()
    return true
end

--- Wipes the location records (console recovery path). Sections are
--- intentionally preserved -- resetting checks must not destroy scoop or
--- stat state.
function M.reset()
    if not L then return end
    L.locations = {}
    save()
    log("ledger reset (locations only; sections preserved)")
end

return M
