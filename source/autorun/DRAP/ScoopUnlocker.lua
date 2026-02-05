-- DRAP/ScoopUnlocker.lua
-- Scoop-based NPC Spawning System
-- Unlocks NPC spawn flags when scoops are received from Archipelago

local Shared = require("DRAP/Shared")

local M = Shared.create_module("ScoopUnlocker")

------------------------------------------------------------
-- Singleton Manager
------------------------------------------------------------

local efm_mgr = M:add_singleton("efm", "app.solid.gamemastering.EventFlagsManager")

------------------------------------------------------------
-- Scoop Definitions
------------------------------------------------------------

local SCOOP_DATA = {
    ------------------------
    -- Survivor Scoops
    ------------------------

    ["Barricade Pair"] = {
        flags = { 793, 802 },
        npcs = { "Burt Thompson", "Aaron Swoop" },
        category = "survivor",
    },

    ["A Mother's Lament"] = {
        flags = { 796 },
        npcs = { "Leah Stein" },
        category = "survivor",
    },

    ["Japanese Tourists"] = {
        flags = { 797, 803 },
        npcs = { "Yuu Tanaka", "Shinji Kitano" },
        category = "survivor",
    },

    ["Shadow of the North Plaza"] = {
        flags = { 789 },
        npcs = { "David Bailey" },
        category = "survivor",
    },

    ["Lovers"] = {
        flags = { 800, 804 },
        npcs = { "Tonya Waters", "Ross Folk" },
        category = "survivor",
    },

    ["The Coward"] = {
        flags = { 790 },
        npcs = { "Gordon Stalworth" },
        category = "survivor",
    },

    ["Twin Sisters"] = {
        flags = { 812, 820 },
        npcs = { "Heather Tompkins", "Pamela Tompkins" },
        category = "survivor",
    },

    ["Restaurant Man"] = {
        flags = { 791 },
        npcs = { "Ronald Shiner" },
        category = "survivor",
    },

    ["Hanging by a Thread"] = {
        flags = { 821, 817 },
        npcs = { "Nick Evans", "Sally Mills" },
        category = "survivor",
    },

    ["Antique Lover"] = {
        flags = { 792 },
        npcs = { "Floyd Sanders" },
        category = "survivor",
    },

    ["The Woman Who Didn't Make it"] = {
        flags = { 794, 795 },
        npcs = { "Jolie Wu", "Rachel Decker" },
        category = "survivor",
    },

    ["Dressed for Action"] = {
        flags = { 814 },
        npcs = { "Kindell Johnson" },
        category = "survivor",
    },

    ["Gun Shop Standoff"] = {
        flags = { 819, 823, 822 },
        npcs = { "Brett Styles", "Alyssa Laurent", "Jonathan Picardson" },
        category = "survivor",
    },

    ["The Drunkard"] = {
        flags = { 818 },
        npcs = { "Gil Jiminez" },
        category = "survivor",
    },

    ["A Sick Man"] = {
        flags = { 799 },
        npcs = { "Leroy McKenna" },
        category = "survivor",
    },

    ["The Woman Left Behind"] = {
        flags = { 817 },
        npcs = { "Sally Mills" },
        category = "survivor",
    },

    ["A Woman in Despair"] = {
        flags = { 801 },
        npcs = { "Simone Ravendark" },
        category = "survivor",
    },

    ------------------------
    -- Psychopath Scoops
    ------------------------

    ["Cut from the Same Cloth"] = {
        flags = { 779 },
        npcs = { "Kent Day 1" },
        category = "psychopath",
    },

    ["Cletus"] = {
        flags = { 807 },
        npcs = { "Cletus" },
        category = "psychopath",
    },

    ["Convicts"] = {
        flags = { 807, 2698 },
        npcs = { "Convicts", "Sophie Richard" },
        category = "psychopath",
    },

    ["Out of Control"] = {
        flags = { 807, 2711 },
        npcs = { "Convicts", "Greg Simpson" },
        category = "psychopath",
    },

    ["The Hatchet Man"] = {
        flags = { 782, 2706, 2705, 2707 },
        npcs = { "Cliff", "Barbara Patterson", "Josh Manning", "Rich Atkins" },
        category = "psychopath",
    },

    ["Above the Law"] = {
        flags = { 785, 2712, 2713, 2714, 2715 },
        npcs = { "Jo", "Kay Nelson", "Lilly Deacon", "Kelly Carpenter", "Janet Star" },
        category = "psychopath",
    },

    ["Mark of the Sniper"] = {
        flags = {  },
        npcs = { "" },
        category = "psychopath",
    },

    ["A Strange Group"] = {
        flags = { 783, 2700, 2701, 2702, 2703, 2704 },
        npcs = { "Sean", "Ray Mathison", "Nathan Crabbe", "Michelle Feltz", "Cheryl Jones", "Beth Shrake" },
        category = "psychopath",
    },

    ["Long Haired Punk"] = {
        flags = { 786, 2708, 2709 },
        npcs = { "Paul Carson", "Mindy Baker", "Debbie Willet" },
        category = "psychopath",
    },

}

------------------------------------------------------------
-- State Tracking
------------------------------------------------------------

local unlocked_scoops = {}  -- { ["Scoop Name"] = true }

------------------------------------------------------------
-- Flag Operations
------------------------------------------------------------

local function check_flag(flag_id)
    local efm = efm_mgr:get()
    if not efm then return nil end

    local ok, result = pcall(function()
        return efm:call("evFlagCheck", flag_id)
    end)

    if ok then
        return result == true
    end
    return nil
end

local function set_flag_on(flag_id)
    local efm = efm_mgr:get()
    if not efm then return false end

    local ok = pcall(function()
        efm:call("evFlagOn", flag_id)
    end)

    return ok
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

--- Unlock a scoop by name, turning on all associated NPC flags
--- @param scoop_name string The name of the scoop (must match AP item name)
--- @return boolean success Whether the scoop was found and unlocked
--- @return number count Number of flags turned on
function M.unlock_scoop(scoop_name)
    local scoop = SCOOP_DATA[scoop_name]
    if not scoop then
        M.log(string.format("WARNING: Unknown scoop '%s'", tostring(scoop_name)))
        return false, 0
    end

    local count = 0
    for _, flag_id in ipairs(scoop.flags) do
        if set_flag_on(flag_id) then
            count = count + 1
        end
    end

    unlocked_scoops[scoop_name] = true

    local npc_list = scoop.npcs and table.concat(scoop.npcs, ", ") or "unknown"
    M.log(string.format("Unlocked scoop '%s' (%d flags): %s", scoop_name, count, npc_list))

    return true, count
end

--- Check if a scoop has been unlocked (all flags are on)
--- @param scoop_name string The name of the scoop
--- @return boolean|nil is_unlocked True if all flags are on, false if any are off, nil if scoop unknown
function M.is_scoop_unlocked(scoop_name)
    local scoop = SCOOP_DATA[scoop_name]
    if not scoop then return nil end

    for _, flag_id in ipairs(scoop.flags) do
        if not check_flag(flag_id) then
            return false
        end
    end

    return true
end

--- Check if we've received this scoop from AP (tracked locally)
--- @param scoop_name string The name of the scoop
--- @return boolean has_received Whether we've received this scoop
function M.has_received_scoop(scoop_name)
    return unlocked_scoops[scoop_name] == true
end

--- Get the scoop data for a given scoop name
--- @param scoop_name string The name of the scoop
--- @return table|nil scoop_data The scoop data or nil if not found
function M.get_scoop_data(scoop_name)
    return SCOOP_DATA[scoop_name]
end

--- Get all scoop names
--- @return table scoop_names Array of all scoop names
function M.get_all_scoop_names()
    local names = {}
    for name, _ in pairs(SCOOP_DATA) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

--- Get scoops by category
--- @param category string The category to filter by
--- @return table scoop_names Array of scoop names in that category
function M.get_scoops_by_category(category)
    local names = {}
    for name, data in pairs(SCOOP_DATA) do
        if data.category == category then
            table.insert(names, name)
        end
    end
    table.sort(names)
    return names
end

--- Get the raw scoop data table (for debugging/inspection)
--- @return table SCOOP_DATA The full scoop data table
function M.get_scoop_table()
    return SCOOP_DATA
end

--- Reapply all unlocked scoops (call after loading a save)
--- @return number count Number of scoops reapplied
function M.reapply_unlocked_scoops()
    local count = 0
    for scoop_name, _ in pairs(unlocked_scoops) do
        local success, _ = M.unlock_scoop(scoop_name)
        if success then
            count = count + 1
        end
    end
    M.log(string.format("Reapplied %d unlocked scoops", count))
    return count
end

--- Clear all unlocked scoops tracking (for new game)
function M.reset_unlocked()
    unlocked_scoops = {}
    M.log("Reset unlocked scoops tracking")
end

--- Get status of all scoops
--- @return table status Array of { name, unlocked, received, npcs, category }
function M.get_all_status()
    local status = {}
    for name, data in pairs(SCOOP_DATA) do
        table.insert(status, {
            name = name,
            unlocked = M.is_scoop_unlocked(name),
            received = M.has_received_scoop(name),
            npcs = data.npcs,
            category = data.category,
        })
    end
    table.sort(status, function(a, b) return a.name < b.name end)
    return status
end

------------------------------------------------------------
-- AP Bridge Integration Helper
--
-- Call this to register all scoops as item handlers with the AP bridge.
-- This should be called from AP_DRDR_main.lua after loading this module.
------------------------------------------------------------

function M.register_with_ap_bridge(ap_bridge)
    if not ap_bridge or not ap_bridge.register_item_handler_by_name then
        M.log("ERROR: Invalid AP bridge provided")
        return 0
    end

    local count = 0
    for scoop_name, _ in pairs(SCOOP_DATA) do
        ap_bridge.register_item_handler_by_name(scoop_name, function(net_item, item_name, sender_name)
            M.log(string.format("Received scoop '%s' from %s", tostring(item_name), tostring(sender_name or "?")))
            M.unlock_scoop(scoop_name)
        end)
        count = count + 1
    end

    M.log(string.format("Registered %d scoop handlers with AP bridge", count))
    return count
end

------------------------------------------------------------
-- Console Helpers
------------------------------------------------------------

_G.scoop_unlock = function(name)
    return M.unlock_scoop(name)
end

_G.scoop_check = function(name)
    local unlocked = M.is_scoop_unlocked(name)
    local received = M.has_received_scoop(name)
    print(string.format("Scoop '%s': unlocked=%s, received=%s",
        tostring(name), tostring(unlocked), tostring(received)))
    return unlocked
end

_G.scoop_list = function()
    local names = M.get_all_scoop_names()
    for _, name in ipairs(names) do
        local data = SCOOP_DATA[name]
        local npcs = data.npcs and table.concat(data.npcs, ", ") or "?"
        print(string.format("  %s [%s]: %s", name, data.category or "?", npcs))
    end
    return names
end

_G.scoop_status = function()
    local status = M.get_all_status()
    for _, s in ipairs(status) do
        local marker = s.unlocked and "[X]" or "[ ]"
        print(string.format("%s %s (%s)", marker, s.name, s.category or "?"))
    end
end

------------------------------------------------------------
-- Module Load
------------------------------------------------------------

M.log("ScoopUnlocker loaded")
M.log("Commands: scoop_unlock(name), scoop_check(name), scoop_list(), scoop_status()")

return M