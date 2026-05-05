-- DRAP/effects/BookGuards.lua
-- Per-book runtime guards that temporarily disable a granted book's
-- always-on effect during specific gameplay sequences where the override
-- breaks vanilla behavior. Each guard is a predicate polled per frame; on
-- transition the targeted book is suppressed/unsuppressed via BookSkills.
--
-- Currently registered:
--   * book 68 (Brainwashing Tips / Cult Initiation Guide) -> Burt Thompson
--     in the Barricade Pair scoop. The book overrides the persuade dialog
--     used to defuse Burt and can lock in his NpcBaseInfo in a hostile /
--     dead state when it's active during any engine evaluation of Burt's
--     spawn. Empirically: a tight "in-area + scoop-active" window doesn't
--     close the bug -- saves from a fresh playthrough where the symptom
--     was never visible still showed Burt corrupted on reload. So the
--     guard is now just: "in Al Fresca Plaza? suppress." That covers any
--     spawn evaluation the engine does while the player is in s900,
--     regardless of scoop state or Burt's current condition. Once the
--     player leaves the area the book reactivates for normal use.
--     Run `_G.drap_burt_reset()` for recovery when an existing save
--     already has Burt in a bad state.

local BookSkills = require("DRAP/effects/BookSkills")
local Shared = require("DRAP/Shared")

local M = {}
local log = Shared.create_logger("BookGuards")

------------------------------------------------------------
-- Constants
------------------------------------------------------------

local AL_FRESCA_AREA_INDEX = 2304    -- AreaManager.mAreaIndex for s900
local BURT_NPC_ID          = 0       -- NpcName enum value (Npc00_Burt)
local BOOK_BRAINWASHING    = 68      -- ITEM_NO_BOOK_CULT_INITIATION_GUIDE

------------------------------------------------------------
-- State
------------------------------------------------------------

local guards = {}          -- list of { item_no, predicate, active, label }
local on_frame_throttle = 0

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function get_current_area_index()
    local am = sdk.get_managed_singleton("app.solid.gamemastering.AreaManager")
    if not am then return nil end
    local td = am:get_type_definition()
    if not td then return nil end
    local f = td:get_field("mAreaIndex")
    if not f then return nil end
    local ok, v = pcall(f.get_data, f, am)
    if not ok then return nil end
    return tonumber(v)
end

------------------------------------------------------------
-- Guard predicates
------------------------------------------------------------

-- Simple area-gated suppression. The earlier predicate also gated on scoop
-- completion + Burt's mLiveState (using searchInformation as a probe), but
-- field reports showed Burt's NpcBaseInfo getting corrupted on saves where
-- the player never visibly hit the bug -- the tight window wasn't closing
-- the engine's evaluation surface. The simpler "any time we're in s900
-- with the book granted, suppress it" closes that window for the whole
-- area regardless of scoop state. Side benefit: no per-frame
-- searchInformation(0) call, which was a possible source of zombie
-- BaseInfo creation if the engine creates entries on miss.
local function should_suppress_brainwashing()
    if not BookSkills.is_granted(BOOK_BRAINWASHING) then return false end
    return get_current_area_index() == AL_FRESCA_AREA_INDEX
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

function M.register_all()
    table.insert(guards, {
        item_no   = BOOK_BRAINWASHING,
        predicate = should_suppress_brainwashing,
        active    = false,
        label     = "Brainwashing/Burt-Barricade-Pair",
    })
    log(string.format("Registered %d book guard(s)", #guards))
end

-- Polled at ~6 Hz (every 10 frames). Each guard's predicate runs and the
-- book toggles suppress state on the rising/falling edge.
function M.on_frame()
    on_frame_throttle = on_frame_throttle + 1
    if (on_frame_throttle % 10) ~= 0 then return end

    for _, g in ipairs(guards) do
        local should = false
        local ok, ret = pcall(g.predicate)
        if ok then should = ret == true end
        if should ~= g.active then
            g.active = should
            if should then
                BookSkills.suppress(g.item_no, g.label)
            else
                BookSkills.unsuppress(g.item_no)
            end
        end
    end
end

function M.list_guards()
    local out = {}
    for _, g in ipairs(guards) do
        table.insert(out, { item_no = g.item_no, label = g.label, active = g.active })
    end
    return out
end

------------------------------------------------------------
-- Console helpers
------------------------------------------------------------

_G.drap_book_guards_status = function()
    local list = M.list_guards()
    log(string.format("Active guards: %d", #list))
    for _, g in ipairs(list) do
        log(string.format("  book=%d  label=%s  active=%s",
            g.item_no, g.label, tostring(g.active)))
    end
end

-- Iterate NpcInfoList and remove every NpcBaseInfo whose <Name> field
-- matches `target_stype`. Uses the (NpcBaseInfo info) overload of
-- removeInformation explicitly -- the (SurvivorType) overload only removes
-- the canonical entry per call, which leaves zombie duplicates intact when
-- the same stype appears multiple times in the list.
--
-- Returns (removed_count, total_match_count). Removed_count may be lower
-- than total_match_count if some removeInformation calls fail.
local function clear_all_entries_for_stype(target_stype)
    local mgr = sdk.get_managed_singleton("app.solid.gamemastering.NpcManager")
    if not mgr then return 0, 0 end

    local mgr_td = mgr:get_type_definition()
    local list_field = mgr_td and mgr_td:get_field("NpcInfoList")
    if not list_field then return 0, 0 end
    local list = Shared.safe_get_field(mgr, list_field)
    if not list then return 0, 0 end

    local count = Shared.get_collection_count(list) or 0
    local matches = {}
    local name_f = nil

    for i = 0, count - 1 do
        local info = Shared.get_collection_item(list, i)
        if info then
            if not name_f then
                local td = info:get_type_definition()
                name_f = td and td:get_field("<Name>k__BackingField")
            end
            if name_f then
                local ok, v = pcall(name_f.get_data, name_f, info)
                if ok and v ~= nil then
                    local stype = type(v) == "number" and v or tonumber(tostring(v))
                    if stype == target_stype then
                        table.insert(matches, info)
                    end
                end
            end
        end
    end

    -- Removing modifies the list, so iterate the captured array, not the
    -- live list. Each removeInformation call walks the list to find the
    -- target by reference -- O(n) per remove, but the per-stype counts are
    -- tiny so this is fine.
    local removed = 0
    for _, info in ipairs(matches) do
        local ok = pcall(function()
            mgr:call("removeInformation(app.solid.npc.NpcBaseInfo)", info)
        end)
        if ok then removed = removed + 1 end
    end

    return removed, #matches
end

-- Recovery for Burt's "didn't spawn" / "spawned dead" state. The engine
-- accumulates zombie NpcBaseInfo entries for stype 0 (state=0, hp=0,
-- isDead=true) -- each failed spawn attempt seems to leave one behind.
-- This walks the full list and removes every Burt entry, not just the
-- canonical one. Run BEFORE re-entering Al Fresca so the engine doesn't
-- re-spawn duplicates on top of the cleared state.
_G.drap_burt_reset = function()
    local removed, total = clear_all_entries_for_stype(BURT_NPC_ID)
    if total == 0 then
        log(string.format("drap_burt_reset: no entries found for stype %d (Burt)",
            BURT_NPC_ID))
    else
        log(string.format("drap_burt_reset: removed %d/%d Burt entries (stype %d). "
            .. "Run drap_npc_dump_list() to verify.",
            removed, total, BURT_NPC_ID))
    end
end

-- Generalized cleanup: for every stype that appears more than once in
-- NpcInfoList, remove duplicates. Useful for save-state recovery if other
-- survivors also got zombie entries. Keeps no entries -- the engine will
-- recreate the canonical one on next encounter (same as how drap_burt_reset
-- works for Burt specifically).
_G.drap_npc_clear_duplicates = function()
    local mgr = sdk.get_managed_singleton("app.solid.gamemastering.NpcManager")
    if not mgr then
        log("drap_npc_clear_duplicates: NpcManager unavailable")
        return
    end

    local mgr_td = mgr:get_type_definition()
    local list_field = mgr_td and mgr_td:get_field("NpcInfoList")
    local list = list_field and Shared.safe_get_field(mgr, list_field)
    if not list then
        log("drap_npc_clear_duplicates: NpcInfoList unavailable")
        return
    end

    local count = Shared.get_collection_count(list) or 0
    local stype_counts = {}
    local name_f = nil
    for i = 0, count - 1 do
        local info = Shared.get_collection_item(list, i)
        if info then
            if not name_f then
                local td = info:get_type_definition()
                name_f = td and td:get_field("<Name>k__BackingField")
            end
            if name_f then
                local ok, v = pcall(name_f.get_data, name_f, info)
                if ok and v ~= nil then
                    local stype = type(v) == "number" and v or tonumber(tostring(v))
                    if stype then
                        stype_counts[stype] = (stype_counts[stype] or 0) + 1
                    end
                end
            end
        end
    end

    local total_removed = 0
    for stype, n in pairs(stype_counts) do
        if n > 1 then
            local r, t = clear_all_entries_for_stype(stype)
            log(string.format("  stype=%d: removed %d/%d", stype, r, t))
            total_removed = total_removed + r
        end
    end
    log(string.format("drap_npc_clear_duplicates: %d entries removed total", total_removed))
end

-- Dump every entry in NpcManager.NpcInfoList with its key fields. Used to
-- investigate cases where the same survivor appears multiple times in the
-- list (suggests the engine grew duplicate NpcBaseInfo records, which would
-- explain "Burt won't spawn / spawns dead" if a stale duplicate is winning
-- the lookup). Output is one line per entry.
--
-- LIVE_STATE legend (from npc_enums.txt):
--  -1 INVALID       0 UNKNOWN       1 FOUND         2 JOIN
--   3 ENTER_SAFTY   4 SAFTY_AREA    5 RESTRAINT     6 CONFINE
--   7 DEFECT        8 ESCORT        9 SLEEP        10 ZOMBIE
--  11 LOST         12 RAGE
_G.drap_npc_dump_list = function()
    local mgr = sdk.get_managed_singleton("app.solid.gamemastering.NpcManager")
    if not mgr then
        log("drap_npc_dump_list: NpcManager not available -- in-game?")
        return
    end

    local mgr_td = mgr:get_type_definition()
    local list_field = mgr_td and mgr_td:get_field("NpcInfoList")
    if not list_field then
        log("drap_npc_dump_list: NpcInfoList field not found")
        return
    end

    local list = Shared.safe_get_field(mgr, list_field)
    if not list then
        log("drap_npc_dump_list: NpcInfoList field returned nil")
        return
    end

    local count = Shared.get_collection_count(list) or 0
    log(string.format("=== NpcInfoList: %d entries ===", count))
    log("idx | stype | name                       | state | area | hp     | isDead | dieFlag")

    -- Cache the field accessors after the first lookup. They're the same
    -- across all entries since every entry is an NpcBaseInfo.
    local name_f, state_f, area_f, vital_f, dieflag_f
    local field_lookup_done = false

    local function ensure_fields(info)
        if field_lookup_done then return true end
        local td = info:get_type_definition()
        if not td then return false end
        name_f    = td:get_field("<Name>k__BackingField")
        state_f   = td:get_field("mLiveState")
        area_f    = td:get_field("mAreaNo")
        vital_f   = td:get_field("mVitalNew")
        dieflag_f = td:get_field("mDieFlag")
        field_lookup_done = true
        return true
    end

    local function read_int(field, info)
        if not field then return nil end
        local ok, v = pcall(field.get_data, field, info)
        if not ok then return nil end
        if v == nil then return nil end
        return tonumber(v) or tonumber(tostring(v))
    end

    -- Track stype occurrences so we can flag duplicates at the end.
    local stype_counts = {}

    for i = 0, count - 1 do
        local info = Shared.get_collection_item(list, i)
        if info and ensure_fields(info) then
            local stype = read_int(name_f, info)
            local state = read_int(state_f, info)
            local area  = read_int(area_f, info)
            local vital = read_int(vital_f, info)

            local dieflag = nil
            if dieflag_f then
                local ok, v = pcall(dieflag_f.get_data, dieflag_f, info)
                if ok then dieflag = tostring(v) end
            end

            local is_dead = nil
            local ok_d, dv = pcall(function() return info:call("isDead") end)
            if ok_d then is_dead = tostring(dv) end

            local friendly = "?"
            if AP and AP.NpcTracker and AP.NpcTracker.get_survivor_friendly_name and stype then
                local f = AP.NpcTracker.get_survivor_friendly_name(stype)
                if f and f ~= "" then friendly = f end
            end

            log(string.format(
                "%3d | %5s | %-26s | %5s | %4s | %6s | %6s | %s",
                i,
                tostring(stype),
                friendly:sub(1, 26),
                tostring(state),
                tostring(area),
                tostring(vital),
                tostring(is_dead),
                tostring(dieflag)))

            if stype ~= nil then
                stype_counts[stype] = (stype_counts[stype] or 0) + 1
            end
        else
            log(string.format("%3d | <unreadable>", i))
        end
    end

    -- Flag any stype that appears more than once.
    local dupes = {}
    for stype, n in pairs(stype_counts) do
        if n > 1 then
            local friendly = "?"
            if AP and AP.NpcTracker and AP.NpcTracker.get_survivor_friendly_name then
                friendly = AP.NpcTracker.get_survivor_friendly_name(stype) or "?"
            end
            table.insert(dupes, string.format("stype=%d (%s) x%d", stype, friendly, n))
        end
    end
    if #dupes > 0 then
        log("=== DUPLICATES (same stype appears multiple times) ===")
        for _, d in ipairs(dupes) do log("  " .. d) end
    else
        log("=== No duplicates ===")
    end
end

return M
