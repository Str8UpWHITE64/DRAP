-- DRAP/ScoopUnlocker.lua
-- Scoop-based NPC/Mission Spawning System v6
--
-- FLAG CONTROL PHILOSOPHY (v6 - Primary Flag Only):
--   - Each main scoop has a PRIMARY flag (mission trigger) and CASCADE flags (prerequisites)
--   - We ONLY control the PRIMARY flag - this blocks/allows mission start
--   - We NEVER touch cascade flags - let the game manage them freely
--   - This prevents loops while still blocking progression
--
-- Why this works:
--   - Player can't start a mission without its PRIMARY flag
--   - Cascade flags can do whatever they want - we don't care
--   - No enforcement loop because we're not fighting cascade behavior

local Shared = require("DRAP/Shared")

local M = Shared.create_module("ScoopUnlocker")

------------------------------------------------------------
-- Singleton Manager
------------------------------------------------------------

local efm_mgr = M:add_singleton("efm", "app.solid.gamemastering.EventFlagsManager")

------------------------------------------------------------
-- Scoop Definitions
--
-- Main Scoops:
--   primary_flag = The flag that STARTS the mission (we control this)
--   cascade_flags = Prerequisite flags (we ignore these completely)
--
-- Side Scoops:
--   flags = All flags needed (we enable these additively)
------------------------------------------------------------

local SCOOP_DATA = {

    ------------------------
    -- Main Scoops
    -- primary_flag: Controls mission availability
    -- cascade_flags: Listed for reference, but we DON'T touch them
    ------------------------

    ["Backup for Brad"] = {
        primary_flag = 268,
        cascade_flags = { 2336 },
        category = "Main",
        order = 2,
        completion_event = "Complete Backup for Brad",
    },

    ["An Odd Old Man"] = {
        primary_flag = 271,
        secondary_flags = { 270 },
        cascade_flags = { 2336, 2337 },
        category = "Main",
        order = 3,
        completion_event = "Escort Brad to see Dr Barnaby",
    },

    ["A Temporary Agreement"] = {
        primary_flag = 272,
        cascade_flags = { 2336, 2337, 2338 },
        category = "Main",
        order = 4,
        completion_event = "Complete Temporary Agreement",
    },

    ["Image in the Monitor"] = {
        primary_flag = 273,
        secondary_flags = { 770 },  -- Additional flags to enable with primary
        cascade_flags = { 2336, 2337, 2338, 2340 },
        category = "Main",
        order = 5,
        completion_event = "Complete Image in the Monitor",
    },

    ["Rescue the Professor"] = {
        primary_flag = 275,
        secondary_flags = { 515, 536, 2310 },  -- Shutter flags
        cascade_flags = { 2336, 2337, 2338, 2340, 2341 },
        category = "Main",
        order = 6,
        completion_event = "Complete Rescue the Professor",
    },

    ["Medicine Run"] = {
        primary_flag = 2311,
        secondary_flags = { 277 },
        cascade_flags = { 2336, 2337, 2338, 2340, 2341, 2342, 2343 },
        category = "Main",
        order = 7,
        completion_event = "Complete Medicine Run",
    },

    ["Another Source"] = {
        primary_flag = 772,
        cascade_flags = { 2336, 2337, 2338, 2340, 2341, 2342, 2343, 2344 },
        category = "Main",
        order = 8,
        completion_event = "Complete Professor's Past",
    },

    ["Girl Hunting"] = {
        primary_flag = 284,
        cascade_flags = { 2336, 2337, 2338, 2340, 2341, 2342, 2343, 2344, 2345, 2346 },
        category = "Main",
        order = 9,
        completion_event = "Complete Girl Hunting",
    },

    ["A Promise to Isabella"] = {
        primary_flag = 773,
        secondary_flags = { 286 },
        cascade_flags = { 2336, 2337, 2338, 2340, 2341, 2342, 2343, 2344, 2345, 2346, 2347 },
        category = "Main",
        order = 10,
        completion_event = "Carry Isabela back to the Safe Room",
    },

    ["Santa Cabeza"] = {
        primary_flag = 292,
        secondary_flags = { 774 },
        cascade_flags = { 2336, 2337, 2338, 2340, 2341, 2342, 2343, 2344, 2345, 2346, 2347, 2348 },
        category = "Main",
        order = 11,
        completion_event = "Complete Santa Cabeza",
    },

    ["The Last Resort"] = {
        primary_flag = 294,
        secondary_flags = { 775, 313 },
        cascade_flags = { 2336, 2337, 2338, 2340, 2341, 2342, 2343, 2344, 2345, 2346, 2347, 2348, 2349 },
        category = "Main",
        order = 12,
        completion_event = "Complete Bomb Collector",
    },

    ["Hideout"] = {
        primary_flag = 776,
        secondary_flags = { 265 },  -- Yes, the same flag is both primary and secondary here
        cascade_flags = { 2336, 2337, 2338, 2340, 2341, 2342, 2343, 2344, 2345, 2346, 2347, 2348, 2349, 2350, 2351 },
        category = "Main",
        order = 13,
        completion_event = "Escort Isabela to the Hideout and have a chat",
    },

    ["Jessie's Discovery"] = {
        primary_flag = 301,
        cascade_flags = { 2336, 2337, 2338, 2340, 2341, 2342, 2343, 2344, 2345, 2346, 2347, 2348, 2349, 2350, 2351 },
        category = "Main",
        order = 14,
        completion_event = "Complete Jessie's Discovery",
    },

    ["The Butcher"] = {
        primary_flag = 302,
        cascade_flags = { 2336, 2337, 2338, 2340, 2341, 2342, 2343, 2344, 2345, 2346, 2347, 2348, 2349, 2350, 2351, 2352 },
        category = "Main",
        order = 15,
        completion_event = "Complete The Butcher",
    },

    ["The Facts"] = {
        primary_flag = 305,
        secondary_flags = { 348 },
        cascade_flags = { 2336, 2337, 2338, 2340, 2341, 2342, 2343, 2344, 2345, 2346, 2347, 2348, 2349, 2350, 2351, 2352, 2356 },
        category = "Main",
        order = 16,
        completion_event = "Complete Memories",
    },

    ------------------------
    -- Survivor Scoops (additive, can all be active)
    ------------------------

    ["Barricade Pair"] = {
        flags = { 793, 802 },
        npcs = { "Burt Thompson", "Aaron Swoop" },
        category = "Survivor",
    },

    ["A Mother's Lament"] = {
        flags = { 796 },
        npcs = { "Leah Stein" },
        category = "Survivor",
    },

    ["Japanese Tourists"] = {
        flags = { 797, 803 },
        npcs = { "Yuu Tanaka", "Shinji Kitano" },
        category = "Survivor",
    },

    ["Shadow of the North Plaza"] = {
        flags = { 789 },
        npcs = { "David Bailey" },
        category = "Survivor",
    },

    ["Lovers"] = {
        flags = { 800, 804 },
        npcs = { "Tonya Waters", "Ross Folk" },
        category = "Survivor",
    },

    ["The Coward"] = {
        flags = { 790 },
        npcs = { "Gordon Stalworth" },
        category = "Survivor",
    },

    ["Twin Sisters"] = {
        flags = { 812, 820 },
        npcs = { "Heather Tompkins", "Pamela Tompkins" },
        category = "Survivor",
    },

    ["Restaurant Man"] = {
        flags = { 791 },
        npcs = { "Ronald Shiner" },
        category = "Survivor",
    },

    ["Hanging by a Thread"] = {
        flags = { 821, 817 },
        npcs = { "Nick Evans", "Sally Mills" },
        category = "Survivor",
    },

    ["Antique Lover"] = {
        flags = { 792 },
        npcs = { "Floyd Sanders" },
        category = "Survivor",
    },

    ["The Woman Who Didn't Make it"] = {
        flags = { 794, 795 },
        npcs = { "Jolie Wu", "Rachel Decker" },
        category = "Survivor",
    },

    ["Dressed for Action"] = {
        flags = { 814 },
        npcs = { "Kindell Johnson" },
        category = "Survivor",
    },

    ["Gun Shop Standoff"] = {
        flags = { 819, 823, 822 },
        npcs = { "Brett Styles", "Alyssa Laurent", "Jonathan Picardson" },
        category = "Survivor",
    },

    ["The Drunkard"] = {
        flags = { 818 },
        npcs = { "Gil Jiminez" },
        category = "Survivor",
    },

    ["A Sick Man"] = {
        flags = { 799 },
        npcs = { "Leroy McKenna" },
        category = "Survivor",
    },

    ["The Woman Left Behind"] = {
        flags = { 815 },
        npcs = { "Susan Walsh" },
        category = "Survivor",
    },

    ["A Woman in Despair"] = {
        flags = { 801 },
        npcs = { "Simone Ravendark" },
        category = "Survivor",
    },

    ------------------------
    -- Psychopath Scoops (additive, can all be active)
    ------------------------

    ["Cut from the Same Cloth"] = {
        flags = { 779 },
        npcs = { "Kent Day 1" },
        category = "Psychopath",
        completion_event = "Complete Kent's day 1 photoshoot",
    },

    ["Photo Challenge"] = {
        flags = {},
        npcs = { "Kent Day 2" },
        category = "Psychopath",
        completion_event = "Complete Kent's day 2 photoshoot",
    },

    ["Photographer's Pride"] = {
        flags = {},
        npcs = { "Kent Day 3", "Tad Hawthorne" },
        category = "Psychopath",
        completion_event = "Kill Kent on day 3",
    },

    ["Cletus the Gunshop Owner"] = {
        flags = { 810 },
        npcs = { "Cletus" },
        category = "Psychopath",
        completion_event = "Kill Cletus",
    },

    ["Convicts"] = {
        flags = { 807, 2698 },
        npcs = { "Convicts", "Sophie Richard" },
        category = "Psychopath",
    },

    ["Out of Control"] = {
        flags = { 2711 },
        npcs = { "Greg Simpson" },
        category = "Psychopath",
    },

    ["The Hatchet Man"] = {
        flags = { 782, 2705, 2706, 2707 },
        npcs = { "Cliff", "Josh Manning", "Barbara Patterson", "Rich Atkins" },
        category = "Psychopath",
        completion_event = "Kill Cliff",
    },

    ["Above the Law"] = {
        flags = { 785, 2712, 2713, 2714, 2715 },
        npcs = { "Jo", "Kay Nelson", "Lilly Deacon", "Kelly Carpenter", "Janet Star" },
        category = "Psychopath",
        completion_event = "Kill Jo",
    },

    ["Mark of the Sniper"] = {
        flags = {},
        npcs = {},
        category = "Psychopath",
    },

    ["A Strange Group"] = {
        flags = { 783, 811, 2700, 2701, 2702, 2703, 2704 },
        npcs = { "Sean", "Cult Cutscene", "Ray Mathison", "Nathan Crabbe", "Michelle Feltz", "Cheryl Jones", "Beth Shrake" },
        category = "Psychopath",
        completion_event = "Kill Sean",
    },

    ["Long Haired Punk"] = {
        flags = { 786, 2708, 2709 },
        npcs = { "Paul Carson", "Mindy Baker", "Debbie Willet" },
        category = "Psychopath",
        completion_event = "Defeat Paul",
    },

    ["Adam the Clown"] = {
        flags = { 784 },
        npcs = { "Adam MacIntyre" },
        category = "Psychopath",
        completion_event = "Kill Adam",
    },

    ["The Hall Family"] = {
        flags = {},
        npcs = { "Roger Hall", "Jack Hall", "Thomas Hall" },
        category = "Psychopath",
        completion_event = "Kill Roger and Jack (and Thomas if you want) and chat with Wayne",
    },
}

------------------------------------------------------------
-- Build lookup tables
------------------------------------------------------------

local COMPLETION_EVENT_TO_SCOOP = {}
local PRIMARY_FLAG_TO_SCOOP = {}  -- For quick lookup: which scoop owns this primary flag?
local ALL_PRIMARY_FLAGS = {}      -- Set of all primary flags we control

local function build_lookup_tables()
    COMPLETION_EVENT_TO_SCOOP = {}
    PRIMARY_FLAG_TO_SCOOP = {}
    ALL_PRIMARY_FLAGS = {}

    for scoop_name, data in pairs(SCOOP_DATA) do
        if data.completion_event then
            COMPLETION_EVENT_TO_SCOOP[data.completion_event] = scoop_name
        end

        if data.primary_flag then
            PRIMARY_FLAG_TO_SCOOP[data.primary_flag] = scoop_name
            ALL_PRIMARY_FLAGS[data.primary_flag] = true
        end
    end
end

build_lookup_tables()

------------------------------------------------------------
-- State Tracking
------------------------------------------------------------

local received_scoops = {}    -- { ["Scoop Name"] = true }
local completed_scoops = {}   -- { ["Scoop Name"] = true }

-- Track flags WE are enabling (to distinguish from game enabling them)
-- Time-based: stores when we enabled the flag, valid for MOD_FLAG_WINDOW seconds
local flags_enabled_by_mod = {}  -- { [flag_id] = os.clock() timestamp }
local MOD_FLAG_WINDOW = 2.0      -- Flags we enabled are "ours" for 2 seconds

-- Track when we're in the middle of an unlock operation (batch)
local currently_unlocking = false

------------------------------------------------------------
-- Public: Check if we're currently enabling flags
-- Other modules (like EventTracker) should call this before sending checks
------------------------------------------------------------

function M.is_currently_unlocking()
    return currently_unlocking
end

function M.was_flag_enabled_by_us(flag_id)
    local timestamp = flags_enabled_by_mod[flag_id]
    if not timestamp then return false end
    return (os.clock() - timestamp) < MOD_FLAG_WINDOW
end

------------------------------------------------------------
-- Completion Flag Detection
--
-- When the GAME (not us) enables these flags, it means the player
-- completed something. We detect this and send AP location checks.
--
-- Format: flag_id → { event = "AP Location Name", scoop = "Scoop to complete" }
------------------------------------------------------------

local COMPLETION_FLAGS = {
    -- Main Story Completion Flags
    -- When mission N completes, these flags turn on

    -- Backup for Brad completion → enables An Odd Old Man
    [270] = { event = "Complete Backup for Brad", scoop = "Backup for Brad" },

    -- An Odd Old Man completion → enables A Temporary Agreement
    [272] = { event = "Escort Brad to see Dr Barnaby", scoop = "An Odd Old Man" },

    -- A Temporary Agreement completion
    [273] = { event = "Complete Temporary Agreement", scoop = "A Temporary Agreement" },

    -- Image in the Monitor completion
    [275] = { event = "Complete Image in the Monitor", scoop = "Image in the Monitor" },

    -- Rescue the Professor completion
    [277] = { event = "Complete Rescue the Professor", scoop = "Rescue the Professor" },

    -- Medicine Run completion
    [772] = { event = "Complete Medicine Run", scoop = "Medicine Run" },

    -- Another Source (Professor's Past) completion
    [284] = { event = "Complete Professor's Past", scoop = "Another Source" },

    -- Girl Hunting completion
    [286] = { event = "Complete Girl Hunting", scoop = "Girl Hunting" },

    -- A Promise to Isabella completion
    [292] = { event = "Carry Isabela back to the Safe Room", scoop = "A Promise to Isabella" },

    -- Santa Cabeza completion
    [294] = { event = "Complete Santa Cabeza", scoop = "Santa Cabeza" },

    -- The Last Resort completion
    [839] = { event = "Complete Bomb Collector", scoop = "The Last Resort" },

    -- Hideout completion
    [301] = { event = "Escort Isabela to the Hideout and have a chat", scoop = "Hideout" },

    -- Jessie's Discovery completion
    [302] = { event = "Complete Jessie's Discovery", scoop = "Jessie's Discovery" },

    -- The Butcher completion
    [304] = { event = "Complete The Butcher", scoop = "The Butcher" },

    -- The Facts (Memories) completion
    -- [???] = { event = "Complete Memories", scoop = "The Facts" },

    -- Add more completion flags here as you discover them
    -- Example: [271] = { event = "Complete Backup for Brad", scoop = "Backup for Brad" },
}

-- Callback for when completion is detected
-- Set this from outside: M.on_completion_detected = function(event_name, flag_id) ... end
local on_completion_detected_callback = nil

------------------------------------------------------------
-- Hook State
------------------------------------------------------------

local hooks_installed = false
local hook_install_attempted = false
local verbose_logging = false

-- Enforcement timing
local enforcement_enabled = true
local last_enforcement_time = 0
local ENFORCEMENT_COOLDOWN = 1.0  -- Only check once per second

-- Per-flag grace periods
-- When the game enables a flag, we give it 15 seconds before we disable it again
-- This allows cutscenes to complete their flag checks
local FLAG_GRACE_PERIOD = 15.0
local flag_grace_until = {}  -- { [flag_id] = os.clock() time when grace expires }

------------------------------------------------------------
-- Raw Flag Operations
------------------------------------------------------------

local function raw_check_flag(flag_id)
    local efm = efm_mgr:get()
    if not efm then return nil end

    local ok, result = pcall(function()
        return efm:call("evFlagCheck", flag_id)
    end)

    return ok and result == true
end

local function raw_set_flag_on(flag_id)
    local efm = efm_mgr:get()
    if not efm then return false end

    -- Mark that WE are enabling this flag with timestamp
    -- Other systems can check this to know we enabled it
    flags_enabled_by_mod[flag_id] = os.clock()

    local ok = pcall(function()
        efm:call("evFlagOn", flag_id)
    end)

    return ok
end

local function raw_set_flag_off(flag_id)
    local efm = efm_mgr:get()
    if not efm then return false end

    local ok = pcall(function()
        efm:call("evFlagOff", flag_id)
    end)

    return ok
end

------------------------------------------------------------
-- Primary Flag Enforcement
--
-- ONLY controls primary flags:
-- - If scoop NOT received and primary flag is ON → disable it (after grace period)
-- - We do NOT re-enable primary flags here (that happens on unlock)
-- - We NEVER touch cascade flags
-- - 15 second grace period after game enables a flag (for cutscenes)
------------------------------------------------------------

local function is_flag_in_grace(flag_id)
    local grace_time = flag_grace_until[flag_id]
    if not grace_time then return false end
    return os.clock() < grace_time
end

local function get_flag_grace_remaining(flag_id)
    local grace_time = flag_grace_until[flag_id]
    if not grace_time then return 0 end
    local remaining = grace_time - os.clock()
    return remaining > 0 and remaining or 0
end

local function enforce_primary_flags()
    if not enforcement_enabled then return end

    local now = os.clock()
    if now - last_enforcement_time < ENFORCEMENT_COOLDOWN then
        return
    end
    last_enforcement_time = now

    local disabled_count = 0
    local grace_count = 0

    for flag_id, _ in pairs(ALL_PRIMARY_FLAGS) do
        local scoop_name = PRIMARY_FLAG_TO_SCOOP[flag_id]
        local scoop_received = received_scoops[scoop_name] == true
        local scoop_completed = completed_scoops[scoop_name] == true

        -- Disable if:
        -- 1. Scoop NOT received (block progression)
        -- 2. Scoop received AND completed (allow previous content to work)
        local should_disable = not scoop_received or (scoop_received and scoop_completed)

        if should_disable then
            local is_on = raw_check_flag(flag_id)
            if is_on then
                -- Check grace period
                if is_flag_in_grace(flag_id) then
                    grace_count = grace_count + 1
                    if verbose_logging then
                        M.log(string.format("Flag %d in grace (%.1fs remaining) - not blocking",
                            flag_id, get_flag_grace_remaining(flag_id)))
                    end
                else
                    if raw_set_flag_off(flag_id) then
                        disabled_count = disabled_count + 1
                        if verbose_logging then
                            local reason = not scoop_received and "not received" or "completed"
                            M.log(string.format("Disabled primary flag %d (%s) - %s",
                                flag_id, scoop_name, reason))
                        end
                    end
                end
            end
        end
    end

    if disabled_count > 0 and not verbose_logging then
        M.log(string.format("Disabled %d mission flags", disabled_count))
    end
end

------------------------------------------------------------
-- Hook Installation
------------------------------------------------------------

local function install_hooks()
    if hooks_installed or hook_install_attempted then return end
    hook_install_attempted = true

    local efm_td = sdk.find_type_definition("app.solid.gamemastering.EventFlagsManager")
    if not efm_td then
        M.log("ERROR: Could not find EventFlagsManager type")
        return
    end

    local ev_flag_on_method = efm_td:get_method("evFlagOn")
    if not ev_flag_on_method then
        M.log("ERROR: Could not find evFlagOn method")
        return
    end

    -- Hook evFlagOn to:
    -- 1. Detect when GAME completes missions (completion flags)
    -- 2. Start grace periods for primary flags
    local hook_ok = pcall(function()
        sdk.hook(
            ev_flag_on_method,
            function(args)
                local flag_id = sdk.to_int64(args[3]) & 0xFFFFFFFF

                -- Check if WE are enabling this flag (ignore if so)
                -- Either during an unlock operation OR this specific flag was just enabled by us
                if currently_unlocking or M.was_flag_enabled_by_us(flag_id) then
                    if verbose_logging then
                        M.log(string.format("Flag %d enabled by US - ignoring", flag_id))
                    end
                    return args
                end

                -- GAME is enabling this flag (not us)

                -- Check if this is a completion flag
                local completion = COMPLETION_FLAGS[flag_id]
                if completion then
                    -- Don't fire completion if scoop is already completed
                    if not completed_scoops[completion.scoop] then
                        M.log(string.format("COMPLETION DETECTED: Flag %d → '%s'",
                            flag_id, completion.event))

                        -- Mark scoop as completed
                        if completion.scoop then
                            completed_scoops[completion.scoop] = true
                        end

                        -- Fire callback to send AP location check
                        if on_completion_detected_callback then
                            local ok, err = pcall(on_completion_detected_callback, completion.event, flag_id, completion.scoop)
                            if not ok then
                                M.log(string.format("ERROR in completion callback: %s", tostring(err)))
                            end
                        end
                    end
                end

                -- Check if this is a primary flag we should grace-period
                if ALL_PRIMARY_FLAGS[flag_id] then
                    local scoop_name = PRIMARY_FLAG_TO_SCOOP[flag_id]
                    local scoop_received = received_scoops[scoop_name] == true

                    if not scoop_received then
                        -- Start grace period - let cutscenes complete before we disable
                        flag_grace_until[flag_id] = os.clock() + FLAG_GRACE_PERIOD

                        if verbose_logging then
                            M.log(string.format("Flag %d enabled by game - grace period started (%.0fs)",
                                flag_id, FLAG_GRACE_PERIOD))
                        end
                    end
                end

                return args
            end,
            function(retval)
                -- POST hook: Nothing to do here
                return retval
            end
        )
    end)

    if hook_ok then
        hooks_installed = true
        M.log("evFlagOn hook installed - monitoring primary flags only")
    else
        M.log("ERROR: Failed to hook evFlagOn")
    end
end

------------------------------------------------------------
-- Public API: Unlock Scoop
------------------------------------------------------------

function M.unlock_scoop(scoop_name)
    local scoop = SCOOP_DATA[scoop_name]
    if not scoop then
        M.log(string.format("WARNING: Unknown scoop '%s'", tostring(scoop_name)))
        return false, 0
    end

    -- Already received?
    if received_scoops[scoop_name] then
        M.log(string.format("Scoop '%s' already received", scoop_name))
        return true, 0
    end

    received_scoops[scoop_name] = true

    -- Mark that WE are enabling flags (so hooks ignore these flag changes)
    currently_unlocking = true

    local count = 0

    if scoop.category == "Main" then
        -- MAIN SCOOP: Enable primary flag (and secondary flags if any)
        if scoop.primary_flag then
            if raw_set_flag_on(scoop.primary_flag) then
                count = count + 1
            end
        end

        if scoop.secondary_flags then
            for _, flag_id in ipairs(scoop.secondary_flags) do
                if raw_set_flag_on(flag_id) then
                    count = count + 1
                end
            end
        end

        -- NOTE: We do NOT enable cascade flags - let the game handle those!

        M.log(string.format("Unlocked MAIN scoop '%s' (enabled %d flags, primary=%d)",
            scoop_name, count, scoop.primary_flag or 0))
    else
        -- SURVIVOR/PSYCHOPATH: Enable all flags
        if scoop.flags then
            for _, flag_id in ipairs(scoop.flags) do
                if flag_id and flag_id ~= 0 then
                    if raw_set_flag_on(flag_id) then
                        count = count + 1
                    end
                end
            end
        end

        local npc_list = scoop.npcs and table.concat(scoop.npcs, ", ") or ""
        M.log(string.format("Unlocked %s scoop '%s' (%d flags) %s",
            scoop.category, scoop_name, count, npc_list))
    end

    -- Done enabling flags
    currently_unlocking = false

    return true, count
end

------------------------------------------------------------
-- Public API: Complete Scoop
------------------------------------------------------------

function M.complete_scoop(scoop_name)
    local scoop = SCOOP_DATA[scoop_name]
    if not scoop then
        M.log(string.format("WARNING: Unknown scoop '%s' for completion", tostring(scoop_name)))
        return false
    end

    if completed_scoops[scoop_name] then
        return true
    end

    completed_scoops[scoop_name] = true
    M.log(string.format("Completed %s scoop '%s'", scoop.category, scoop_name))

    return true
end

------------------------------------------------------------
-- Event Tracker Integration
------------------------------------------------------------

function M.on_event_tracked(event_desc)
    local scoop_name = COMPLETION_EVENT_TO_SCOOP[event_desc]
    if scoop_name then
        M.log(string.format("Event '%s' completes scoop '%s'", event_desc, scoop_name))
        M.complete_scoop(scoop_name)
        return true
    end
    return false
end

------------------------------------------------------------
-- Reapply on Game Load
------------------------------------------------------------

function M.reapply_unlocked_scoops()
    M.log("Reapplying unlocked scoops...")

    local main_count = 0
    local side_count = 0

    for scoop_name, _ in pairs(received_scoops) do
        if not completed_scoops[scoop_name] then
            local data = SCOOP_DATA[scoop_name]
            if data then
                -- Re-enable flags
                received_scoops[scoop_name] = nil  -- Clear so unlock works
                M.unlock_scoop(scoop_name)

                if data.category == "Main" then
                    main_count = main_count + 1
                else
                    side_count = side_count + 1
                end
            end
        end
    end

    M.log(string.format("Reapplied: %d main, %d side scoops", main_count, side_count))
end

------------------------------------------------------------
-- Query Functions
------------------------------------------------------------

function M.is_scoop_active(scoop_name)
    local scoop = SCOOP_DATA[scoop_name]
    if not scoop then return nil end

    if scoop.primary_flag then
        return raw_check_flag(scoop.primary_flag)
    elseif scoop.flags and #scoop.flags > 0 then
        for _, flag_id in ipairs(scoop.flags) do
            if flag_id ~= 0 and not raw_check_flag(flag_id) then
                return false
            end
        end
        return true
    end

    return nil
end

function M.has_received_scoop(scoop_name)
    return received_scoops[scoop_name] == true
end

function M.is_scoop_completed(scoop_name)
    return completed_scoops[scoop_name] == true
end

function M.get_scoop_data(scoop_name)
    return SCOOP_DATA[scoop_name]
end

function M.get_all_scoop_names()
    local names = {}
    for name, _ in pairs(SCOOP_DATA) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

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

function M.get_main_scoops_in_order()
    local mains = {}
    for name, data in pairs(SCOOP_DATA) do
        if data.category == "Main" then
            table.insert(mains, { name = name, order = data.order or 0 })
        end
    end
    table.sort(mains, function(a, b) return a.order < b.order end)

    local result = {}
    for _, m in ipairs(mains) do
        table.insert(result, m.name)
    end
    return result
end

function M.get_all_status()
    local status = {}
    for name, data in pairs(SCOOP_DATA) do
        table.insert(status, {
            name = name,
            flags_active = M.is_scoop_active(name),
            received = M.has_received_scoop(name),
            completed = M.is_scoop_completed(name),
            npcs = data.npcs,
            category = data.category,
            completion_event = data.completion_event,
            primary_flag = data.primary_flag,
            flags = data.flags,
            order = data.order,
        })
    end
    table.sort(status, function(a, b)
        if a.category ~= b.category then
            local order = { Main = 1, Survivor = 2, Psychopath = 3 }
            return (order[a.category] or 9) < (order[b.category] or 9)
        end
        if a.order and b.order then
            return a.order < b.order
        end
        return a.name < b.name
    end)
    return status
end

function M.get_scoop_table()
    return SCOOP_DATA
end

function M.get_completion_map()
    return COMPLETION_EVENT_TO_SCOOP
end

------------------------------------------------------------
-- Bulk Operations
------------------------------------------------------------

function M.reset_all()
    received_scoops = {}
    completed_scoops = {}
    M.log("Reset all scoop tracking")
end

function M.unlock_all()
    local count = 0
    -- Unlock in order for main scoops
    for _, name in ipairs(M.get_main_scoops_in_order()) do
        M.unlock_scoop(name)
        count = count + 1
    end
    -- Unlock all others
    for name, data in pairs(SCOOP_DATA) do
        if data.category ~= "Main" then
            M.unlock_scoop(name)
            count = count + 1
        end
    end
    M.log(string.format("Unlocked ALL %d scoops", count))
    return count
end

function M.unlock_category(category)
    local count = 0
    if category == "Main" then
        for _, name in ipairs(M.get_main_scoops_in_order()) do
            M.unlock_scoop(name)
            count = count + 1
        end
    else
        for name, data in pairs(SCOOP_DATA) do
            if data.category == category then
                M.unlock_scoop(name)
                count = count + 1
            end
        end
    end
    M.log(string.format("Unlocked %d scoops in category '%s'", count, category))
    return count
end

------------------------------------------------------------
-- Settings
------------------------------------------------------------

function M.set_verbose_logging(enabled)
    verbose_logging = enabled
    M.log("Verbose logging " .. (enabled and "ENABLED" or "DISABLED"))
end

function M.set_enforcement_enabled(enabled)
    enforcement_enabled = enabled
    M.log("Enforcement " .. (enabled and "ENABLED" or "DISABLED"))
end

function M.is_enforcement_enabled()
    return enforcement_enabled
end

function M.force_enforce()
    last_enforcement_time = 0
    enforce_primary_flags()
end

------------------------------------------------------------
-- Completion Detection API
--
-- Set a callback to be notified when the GAME completes missions.
-- This is used to send AP location checks.
------------------------------------------------------------

-- Set the callback: function(event_name, flag_id, scoop_name)
function M.set_completion_callback(callback)
    on_completion_detected_callback = callback
    M.log("Completion detection callback " .. (callback and "SET" or "CLEARED"))
end

-- Add a completion flag mapping
function M.add_completion_flag(flag_id, event_name, scoop_name)
    COMPLETION_FLAGS[flag_id] = { event = event_name, scoop = scoop_name }
    if verbose_logging then
        M.log(string.format("Added completion flag %d → '%s'", flag_id, event_name))
    end
end

-- Remove a completion flag mapping
function M.remove_completion_flag(flag_id)
    COMPLETION_FLAGS[flag_id] = nil
end

-- Get all completion flags
function M.get_completion_flags()
    local result = {}
    for flag_id, data in pairs(COMPLETION_FLAGS) do
        table.insert(result, {
            flag_id = flag_id,
            event = data.event,
            scoop = data.scoop,
        })
    end
    table.sort(result, function(a, b) return a.flag_id < b.flag_id end)
    return result
end

-- Check if a flag is a completion flag
function M.is_completion_flag(flag_id)
    return COMPLETION_FLAGS[flag_id] ~= nil
end

------------------------------------------------------------
-- AP Bridge Integration
------------------------------------------------------------

function M.register_with_ap_bridge(ap_bridge)
    if not ap_bridge or not ap_bridge.register_item_handler_by_name then
        M.log("ERROR: Invalid AP bridge provided")
        return 0
    end

    local count = 0
    for scoop_name, data in pairs(SCOOP_DATA) do
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
-- GUI
------------------------------------------------------------

local gui_visible = false
local filter_category = "All"
local show_only_received = false
local show_debug_panel = false

local function get_category_color(category)
    if category == "Main" then
        return 0xFFFFFF00  -- Yellow
    elseif category == "Survivor" then
        return 0xFF66FF66  -- Green
    elseif category == "Psychopath" then
        return 0xFFFF6666  -- Red
    else
        return 0xFFFFFFFF  -- White
    end
end

local function draw_main_window()
    if not gui_visible then return end

    imgui.set_next_window_size(Vector2f.new(700, 800), 4)

    local still_open = imgui.begin_window("Scoop Unlocker v6.3", true, 0)
    if not still_open then
        gui_visible = false
        imgui.end_window()
        return
    end

    -- Status
    local efm = efm_mgr:get()
    imgui.text_colored(efm and "EFM: OK" or "EFM: N/A", efm and 0xFF00FF00 or 0xFFFF0000)
    imgui.same_line()
    imgui.text_colored(hooks_installed and "Hook: ON" or "Hook: OFF", hooks_installed and 0xFF00FF00 or 0xFFFF0000)
    imgui.same_line()
    imgui.text_colored(enforcement_enabled and "Enforce: ON" or "Enforce: OFF",
        enforcement_enabled and 0xFF00FF00 or 0xFFFFFF00)

    -- Counts
    local received_count, completed_count = 0, 0
    for _ in pairs(received_scoops) do received_count = received_count + 1 end
    for _ in pairs(completed_scoops) do completed_count = completed_count + 1 end

    local primary_count = 0
    for _ in pairs(ALL_PRIMARY_FLAGS) do primary_count = primary_count + 1 end

    -- Count flags in grace
    local grace_count = 0
    local now = os.clock()
    for flag_id, grace_time in pairs(flag_grace_until) do
        if grace_time > now then
            grace_count = grace_count + 1
        end
    end

    imgui.text(string.format("Scoops: %d received / %d completed | Primary flags: %d",
        received_count, completed_count, primary_count))

    -- Show grace period indicator if any flags are in grace
    if grace_count > 0 then
        imgui.same_line()
        imgui.text_colored(string.format("| GRACE: %d flags", grace_count), 0xFFFF8800)
    end

    imgui.separator()

    -- Bulk actions
    if imgui.button("Unlock ALL") then M.unlock_all() end
    imgui.same_line()
    if imgui.button("Unlock Main") then M.unlock_category("Main") end
    imgui.same_line()
    if imgui.button("Unlock Survivors") then M.unlock_category("Survivor") end
    imgui.same_line()
    if imgui.button("Unlock Psychos") then M.unlock_category("Psychopath") end

    if imgui.button("Reset All") then M.reset_all() end
    imgui.same_line()
    if imgui.button("Reapply") then M.reapply_unlocked_scoops() end
    imgui.same_line()
    if imgui.button("Force Enforce") then M.force_enforce() end

    local enforce_changed, enforce_val = imgui.checkbox("Enforcement", enforcement_enabled)
    if enforce_changed then M.set_enforcement_enabled(enforce_val) end
    imgui.same_line()
    local verbose_changed, verbose_val = imgui.checkbox("Verbose", verbose_logging)
    if verbose_changed then M.set_verbose_logging(verbose_val) end

    local debug_changed, debug_val = imgui.checkbox("Debug Panel", show_debug_panel)
    if debug_changed then show_debug_panel = debug_val end

    imgui.separator()

    -- Debug panel
    if show_debug_panel then
        imgui.text("Primary Flags (controlled):")
        local primary_list = {}
        for flag_id, _ in pairs(ALL_PRIMARY_FLAGS) do
            local scoop = PRIMARY_FLAG_TO_SCOOP[flag_id]
            local recv = received_scoops[scoop] and "R" or "."
            local grace_remaining = get_flag_grace_remaining(flag_id)
            if grace_remaining > 0 then
                table.insert(primary_list, string.format("%d[%s G:%.0f]", flag_id, recv, grace_remaining))
            else
                table.insert(primary_list, string.format("%d[%s]", flag_id, recv))
            end
        end
        table.sort(primary_list)
        imgui.text_wrapped(table.concat(primary_list, " "))

        -- Show flags currently in grace
        local grace_list = {}
        local now = os.clock()
        for flag_id, grace_time in pairs(flag_grace_until) do
            if grace_time > now then
                local scoop = PRIMARY_FLAG_TO_SCOOP[flag_id] or "?"
                table.insert(grace_list, string.format("%d (%.1fs) - %s", flag_id, grace_time - now, scoop))
            end
        end
        if #grace_list > 0 then
            imgui.text_colored("Flags in Grace Period:", 0xFFFF8800)
            for _, g in ipairs(grace_list) do
                imgui.text("  " .. g)
            end
        end

        imgui.separator()
    end

    -- Filter
    imgui.text("Filter:")
    imgui.same_line()
    if imgui.button("All##f") then filter_category = "All" end
    imgui.same_line()
    if imgui.button("Main##f") then filter_category = "Main" end
    imgui.same_line()
    if imgui.button("Survivor##f") then filter_category = "Survivor" end
    imgui.same_line()
    if imgui.button("Psycho##f") then filter_category = "Psychopath" end

    local recv_changed, recv_val = imgui.checkbox("Show only received", show_only_received)
    if recv_changed then show_only_received = recv_val end

    imgui.separator()

    -- Scoop list
    imgui.begin_child_window("ScoopList", Vector2f.new(0, 0), true, 0)

    local status_list = M.get_all_status()
    for _, s in ipairs(status_list) do
        local show = true
        if filter_category ~= "All" and s.category ~= filter_category then show = false end
        if show_only_received and not s.received then show = false end

        if show then
            local color = get_category_color(s.category)

            local status_str = ""
            if s.completed then
                status_str = " [DONE]"
                color = 0xFF888888
            elseif s.received then
                status_str = " [RECV]"
            end
            if s.flags_active then
                status_str = status_str .. " [ON]"
            end

            if imgui.button("Unlock##" .. s.name) then
                M.unlock_scoop(s.name)
            end
            imgui.same_line()

            if s.completion_event then
                if imgui.button("Done##" .. s.name) then
                    M.complete_scoop(s.name)
                end
                imgui.same_line()
            end

            local order_str = s.order and string.format(" #%d", s.order) or ""
            local flag_str = s.primary_flag and string.format(" [%d]", s.primary_flag) or ""
            local npc_str = s.npcs and #s.npcs > 0 and (" - " .. table.concat(s.npcs, ", ")) or ""

            imgui.text_colored(
                string.format("%s [%s%s]%s%s%s", s.name, s.category or "?", order_str, flag_str, status_str, npc_str),
                color
            )

            if imgui.is_item_hovered() then
                local tip = ""
                if s.primary_flag then
                    tip = "Primary flag: " .. s.primary_flag
                end
                if s.flags and #s.flags > 0 then
                    tip = tip .. (tip ~= "" and "\n" or "") .. "Flags: " .. table.concat(s.flags, ", ")
                end
                if s.completion_event then
                    tip = tip .. "\nCompletes on: " .. s.completion_event
                end
                if tip ~= "" then
                    imgui.set_tooltip(tip)
                end
            end
        end
    end

    imgui.end_child_window()
    imgui.end_window()
end

------------------------------------------------------------
-- Public GUI API
------------------------------------------------------------

function M.show_window() gui_visible = true end
function M.hide_window() gui_visible = false end
function M.toggle_window() gui_visible = not gui_visible end

------------------------------------------------------------
-- Per-Frame Update
------------------------------------------------------------

function M.on_frame()
    -- Install hooks if needed
    if not hooks_installed and not hook_install_attempted then
        if Shared.is_in_game and Shared.is_in_game() then
            install_hooks()
        end
    end

    -- Enforce primary flags (with cooldown)
    enforce_primary_flags()
end

------------------------------------------------------------
-- REFramework Hooks
------------------------------------------------------------

re.on_frame(function()
    M.on_frame()
    if gui_visible then draw_main_window() end
end)

re.on_draw_ui(function()
    local changed, new_val = imgui.checkbox("Show Scoop Unlocker", gui_visible)
    if changed then gui_visible = new_val end
end)

------------------------------------------------------------
-- Console Helpers
------------------------------------------------------------

_G.scoop_unlock = function(name) return M.unlock_scoop(name) end
_G.scoop_complete = function(name) return M.complete_scoop(name) end
_G.scoop_check = function(name)
    local active = M.is_scoop_active(name)
    local received = M.has_received_scoop(name)
    local completed = M.is_scoop_completed(name)
    print(string.format("Scoop '%s': active=%s, received=%s, completed=%s",
        tostring(name), tostring(active), tostring(received), tostring(completed)))
end
_G.scoop_list = function()
    for _, name in ipairs(M.get_all_scoop_names()) do
        local data = SCOOP_DATA[name]
        local npcs = data.npcs and table.concat(data.npcs, ", ") or ""
        print(string.format("  %s [%s]: %s", name, data.category or "?", npcs))
    end
end
_G.scoop_status = function()
    for _, s in ipairs(M.get_all_status()) do
        local m = (s.received and "R" or ".") .. (s.flags_active and "A" or ".") .. (s.completed and "C" or ".")
        print(string.format("[%s] %s (%s)", m, s.name, s.category or "?"))
    end
end
_G.scoop_gui = function() M.show_window() end
_G.scoop_unlock_all = function() return M.unlock_all() end
_G.scoop_main = function()
    print("Main scoop order (with primary flags):")
    for i, name in ipairs(M.get_main_scoops_in_order()) do
        local data = SCOOP_DATA[name]
        local recv = received_scoops[name] and "R" or "."
        local done = completed_scoops[name] and "D" or "."
        local flag_on = data.primary_flag and raw_check_flag(data.primary_flag) and "ON" or "off"
        print(string.format("  %d. [%s%s] %s (flag %d = %s)",
            i, recv, done, name, data.primary_flag or 0, flag_on))
    end
end
_G.scoop_enforce = function() M.force_enforce() end
_G.scoop_verbose = function(enabled)
    if enabled == nil then enabled = not verbose_logging end
    M.set_verbose_logging(enabled)
end
_G.scoop_grace = function()
    local now = os.clock()
    local count = 0
    print(string.format("Grace period: %.0f seconds", FLAG_GRACE_PERIOD))
    print("Flags currently in grace:")
    for flag_id, grace_time in pairs(flag_grace_until) do
        if grace_time > now then
            local scoop = PRIMARY_FLAG_TO_SCOOP[flag_id] or "?"
            print(string.format("  Flag %d: %.1fs remaining (%s)", flag_id, grace_time - now, scoop))
            count = count + 1
        end
    end
    if count == 0 then
        print("  (none)")
    end
end
_G.scoop_completions = function()
    print("Completion flags (game enables these when missions complete):")
    local flags = M.get_completion_flags()
    for _, f in ipairs(flags) do
        local is_on = raw_check_flag(f.flag_id) and "ON" or "off"
        print(string.format("  Flag %d [%s] → '%s' (%s)",
            f.flag_id, is_on, f.event, f.scoop or "?"))
    end
    print(string.format("Total: %d completion flags", #flags))
end

------------------------------------------------------------
-- Module Load
------------------------------------------------------------

local primary_flag_count = 0
for _ in pairs(ALL_PRIMARY_FLAGS) do primary_flag_count = primary_flag_count + 1 end

local completion_flag_count = 0
for _ in pairs(COMPLETION_FLAGS) do completion_flag_count = completion_flag_count + 1 end

M.log("ScoopUnlocker v6.3 (Primary + Grace + Completion Detection) loaded")
M.log("  Controls primary flags only - disables after completion too")
M.log("  Exports is_currently_unlocking(), was_flag_enabled_by_us() for other modules")
M.log(string.format("  Primary: %d | Completion: %d | Grace: %.0fs",
    primary_flag_count, completion_flag_count, FLAG_GRACE_PERIOD))
M.log("Commands: scoop_gui(), scoop_unlock(name), scoop_main()")
M.log("          scoop_completions(), scoop_grace(), scoop_verbose([true/false])")

return M