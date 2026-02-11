-- DRAP/ScoopUnlocker.lua
-- Scoop-based Mission Spawning System v7
--
-- Each main scoop has a PRIMARY flag (mission trigger) and CASCADE flags (prerequisites).
-- We ONLY control the PRIMARY flag. Cascade flags are left to the game.
-- Blacklisted flags are force-disabled every enforcement cycle.

local Shared = require("DRAP/Shared")

local M = Shared.create_module("ScoopUnlocker")

------------------------------------------------------------
-- Singleton
------------------------------------------------------------

local efm_mgr = M:add_singleton("efm", "app.solid.gamemastering.EventFlagsManager")

------------------------------------------------------------
-- Flag Blacklist
--
-- Flags listed here are ALWAYS disabled during enforcement,
-- regardless of scoop state, grace periods, or completion.
------------------------------------------------------------

local FLAG_BLACKLIST = {
    [300] = "Kills all NPCs when enabled"
}

------------------------------------------------------------
-- Flag Triggers
--
-- When the game enables a trigger flag, we reactively
-- enable or disable other flags. Runs in the evFlagOn hook.
------------------------------------------------------------

local FLAG_TRIGGERS = {
    [392] = { enable = { 300 } },
}

------------------------------------------------------------
-- Scoop Definitions
------------------------------------------------------------

local SCOOP_DATA = {

    -- Main Scoops (primary_flag controls mission availability)
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
        secondary_flags = { 770 },
        cascade_flags = { 2336, 2337, 2338, 2340 },
        category = "Main",
        order = 5,
        completion_event = "Complete Image in the Monitor",
    },

    ["Rescue the Professor"] = {
        primary_flag = 275,
        secondary_flags = { 515, 536, 2310 },
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
        primary_flag = 286,
        secondary_flags = { 773 },
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
        secondary_flags = { 265 },
        disable_flags = { 304 },
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

    -- Survivor Scoops
    ["Barricade Pair"] = {
        flags = { 793, 802 },
        npcs = { "Burt Thompson", "Aaron Swoop" },
        category = "Survivor",
        completion_event = "Rescue Burt Thompson",
    },

    ["A Mother's Lament"] = {
        flags = { 796 },
        npcs = { "Leah Stein" },
        category = "Survivor",
        completion_event = "Rescue Leah Stein",
    },

    ["Japanese Tourists"] = {
        flags = { 797, 803 },
        npcs = { "Yuu Tanaka", "Shinji Kitano" },
        category = "Survivor",
        completion_event = "Rescue Yuu Tanaka",
    },

    ["Shadow of the North Plaza"] = {
        flags = { 789 },
        npcs = { "David Bailey" },
        category = "Survivor",
        completion_event = "Rescue David Bailey",
    },

    ["Lovers"] = {
        flags = { 800, 804 },
        npcs = { "Tonya Waters", "Ross Folk" },
        category = "Survivor",
        completion_event = "Rescue Ross Folk",
    },

    ["The Coward"] = {
        flags = { 790 },
        npcs = { "Gordon Stalworth" },
        category = "Survivor",
        completion_event = "Rescue Gordon Stalworth",
    },

    ["Twin Sisters"] = {
        flags = { 812, 820 },
        npcs = { "Heather Tompkins", "Pamela Tompkins" },
        category = "Survivor",
        completion_event = "Rescue Pamela Tompkins",
    },

    ["Restaurant Man"] = {
        flags = { 791 },
        npcs = { "Ronald Shiner" },
        category = "Survivor",
        completion_event = "Rescue Ronald Shiner",
    },

    ["Hanging by a Thread"] = {
        flags = { 821, 817 },
        npcs = { "Nick Evans", "Sally Mills" },
        category = "Survivor",
        completion_event = "Rescue Nick Evans",
    },

    ["Antique Lover"] = {
        flags = { 792 },
        npcs = { "Floyd Sanders" },
        category = "Survivor",
        completion_event = "Rescue Floyd Sanders",
    },

    ["The Woman Who Didn't Make it"] = {
        flags = { 794, 795 },
        npcs = { "Jolie Wu", "Rachel Decker" },
        category = "Survivor",
        completion_event = "Rescue Jolie Wu",
    },

    ["Dressed for Action"] = {
        flags = { 814 },
        npcs = { "Kindell Johnson" },
        category = "Survivor",
        completion_event = "Rescue Kindell Johnson",
    },

    ["Gun Shop Standoff"] = {
        flags = { 819, 823, 822 },
        npcs = { "Brett Styles", "Alyssa Laurent", "Jonathan Picardson" },
        category = "Survivor",
        completion_event = "Rescue Brett Styles",
    },

    ["The Drunkard"] = {
        flags = { 818 },
        npcs = { "Gil Jiminez" },
        category = "Survivor",
        completion_event = "Rescue Gil Jiminez",
    },

    ["A Sick Man"] = {
        flags = { 799 },
        npcs = { "Leroy McKenna" },
        category = "Survivor",
        completion_event = "Rescue Leroy McKenna",
    },

    ["The Woman Left Behind"] = {
        flags = { 815 },
        npcs = { "Susan Walsh" },
        category = "Survivor",
        completion_event = "Rescue Susan Walsh",
    },

    ["A Woman in Despair"] = {
        flags = { 801 },
        npcs = { "Simone Ravendark" },
        category = "Survivor",
        completion_event = "Rescue Simone Ravendark",
    },

    -- Psychopath Scoops
    ["Cut from the Same Cloth"] = {
        flags = { 779 },
        npcs = { "Kent Day 1" },
        category = "Psychopath",
        completion_event = "Complete Kent's day 1 photoshoot",
    },

    ["Photo Challenge"] = {
        flags = {779, 1225},
        npcs = { "Kent Day 2" },
        category = "Psychopath",
        completion_event = "Complete Kent's day 2 photoshoot",
    },

    ["Photographer's Pride"] = {
        flags = {781, 2710},
        npcs = { "Kent Day 3", "Tad Hawthorne" },
        category = "Psychopath",
        completion_event = "Kill Kent on day 3",
    },

    ["Cletus"] = {
        flags = { 810 },
        npcs = { "Cletus" },
        category = "Psychopath",
        completion_event = "Kill Cletus",
    },

    ["The Convicts"] = {
        flags = { 807, 2698 },
        npcs = { "Convicts", "Sophie Richard" },
        category = "Psychopath",
        completion_event = "Watch the convicts kill that poor guy",
    },

    ["Out of Control"] = {
        flags = { 784, 2711 },
        npcs = { "Adam", "Greg Simpson" },
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

    ["A Strange Group"] = {
        flags = { 783, 811, 2700, 2701, 2702, 2703, 2704 },
        npcs = { "Sean", "Ray Mathison", "Nathan Crabbe", "Michelle Feltz", "Cheryl Jones", "Beth Shrake" },
        category = "Psychopath",
        completion_event = "Kill Sean",
    },

    ["Long Haired Punk"] = {
        flags = { 786, 2708, 2709 },
        npcs = { "Paul Carson", "Mindy Baker", "Debbie Willet" },
        category = "Psychopath",
        completion_event = "Defeat Paul",
    },

    ["Mark of the Sniper"] = {
        flags = {798, 808},
        npcs = { "Wayne Blackwell", "Roger Hall", "Jack Hall", "Thomas Hall" },
        category = "Psychopath",
        completion_event = "Kill Roger and Jack (and Thomas if you want) and chat with Wayne",
    },

    ["The Cult"] = {
        flags = { 787, 811, 2699 },
        npcs = { "Raincoats", "Jennifer Gorman" },
        category = "Psychopath",
        completion_event = "Witness Sean in Paradise Plaza",
    },

    --Special items
    ["Maintenance Tunnel Access key"] = {
        flags = { 2082 },
        npcs = { "" },
        category = "Special",
    },
}

------------------------------------------------------------
-- Lookup Tables
------------------------------------------------------------

local COMPLETION_EVENT_TO_SCOOP = {}
local PRIMARY_FLAG_TO_SCOOP = {}
local ALL_PRIMARY_FLAGS = {}

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
-- Completion Flag Detection
--
-- When the GAME enables these flags, it means the player
-- completed something. Used to send AP location checks.
------------------------------------------------------------

local COMPLETION_FLAGS = {
    [270] = { event = "Complete Backup for Brad", scoop = "Backup for Brad" },
    [272] = { event = "Escort Brad to see Dr Barnaby", scoop = "An Odd Old Man" },
    [273] = { event = "Complete Temporary Agreement", scoop = "A Temporary Agreement" },
    [275] = { event = "Complete Image in the Monitor", scoop = "Image in the Monitor" },
    [277] = { event = "Complete Rescue the Professor", scoop = "Rescue the Professor" },
    [772] = { event = "Complete Medicine Run", scoop = "Medicine Run" },
    [284] = { event = "Complete Professor's Past", scoop = "Another Source" },
    [286] = { event = "Complete Girl Hunting", scoop = "Girl Hunting" },
    [292] = { event = "Carry Isabela back to the Safe Room", scoop = "A Promise to Isabella" },
    [294] = { event = "Complete Santa Cabeza", scoop = "Santa Cabeza" },
    [839] = { event = "Complete Bomb Collector", scoop = "The Last Resort" },
    [301] = { event = "Escort Isabela to the Hideout and have a chat", scoop = "Hideout" },
    [302] = { event = "Complete Jessie's Discovery", scoop = "Jessie's Discovery" },
    [304] = { event = "Complete The Butcher", scoop = "The Butcher" },
}

------------------------------------------------------------
-- State
------------------------------------------------------------

local ap_received = {}
local received_scoops = {}
local completed_scoops = {}
local currently_unlocking = false

local hooks_installed = false
local hook_install_attempted = false
local verbose_logging = false

local enforcement_enabled = true
local last_enforcement_time = 0
local ENFORCEMENT_COOLDOWN = 1.0

-- Grace periods: when game enables a flag, wait before disabling
local FLAG_GRACE_PERIOD = 10.0
local flag_grace_until = {}  -- { [flag_id] = expiry timestamp }

local on_completion_detected_callback = nil

------------------------------------------------------------
-- AP Scoop Ordering & Milestones
--
-- Enforcement only starts after "Meet Jessie" milestone.
------------------------------------------------------------

local scoop_order = {}           -- Ordered list of main scoop names from AP
local scoop_order_set = false    -- Has AP provided the ordering?
local ap_activated = false       -- True after "Meet Jessie" milestone
local time_frozen = false        -- True after "Get to the Stairs!" milestone

-- Callbacks for main script
local on_ap_activated_callback = nil   -- Called when enforcement activates
local on_time_freeze_callback = nil    -- Called when time should freeze

-- Persistence
local save_filename = nil        -- Set via set_save_filename(slot, seed)

local MILESTONE_EVENTS = {
    ["Get to the stairs!"] = "time_freeze",
    ["Meet Jessie in the Service Hallway"] = "activate",
    ["Get bit!"] = "time_freeze",
}

------------------------------------------------------------
-- Public: Unlock state queries for other modules
------------------------------------------------------------

function M.is_currently_unlocking()
    return currently_unlocking
end

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
    local ok = pcall(function() efm:call("evFlagOn", flag_id) end)
    return ok
end

local function raw_set_flag_off(flag_id)
    local efm = efm_mgr:get()
    if not efm then return false end
    local ok = pcall(function() efm:call("evFlagOff", flag_id) end)
    return ok
end

------------------------------------------------------------
-- Persistence
------------------------------------------------------------

local function save_state()
    if not save_filename then return false end

    local completed_list = {}
    for name, _ in pairs(completed_scoops) do
        table.insert(completed_list, name)
    end
    table.sort(completed_list)

    local ap_received_list = {}
    for name, _ in pairs(ap_received) do
        table.insert(ap_received_list, name)
    end
    table.sort(ap_received_list)

    local data = {
        version = 2,
        ap_activated = ap_activated,
        time_frozen = time_frozen,
        scoop_order = scoop_order,
        completed_scoops = completed_list,
        ap_received = ap_received_list,
    }

    local ok = pcall(json.dump_file, save_filename, data)
    if ok then
        if verbose_logging then
            M.log(string.format("Saved state (%d completed) to %s", #completed_list, save_filename))
        end
    else
        M.log("ERROR: Failed to save state to " .. tostring(save_filename))
    end
    return ok
end

local function load_state()
    if not save_filename then return false end

    local data = json.load_file(save_filename)
    if not data then
        M.log("No existing save at " .. save_filename)
        return false
    end

    -- Restore milestones
    if data.ap_activated then
        ap_activated = true
        M.log("Restored: AP activated")
    end
    if data.time_frozen then
        time_frozen = true
        M.log("Restored: Time frozen")
    end

    -- Restore scoop order (only if AP hasn't already set it this session)
    if data.scoop_order and #data.scoop_order > 0 and not scoop_order_set then
        scoop_order = data.scoop_order
        scoop_order_set = true
        M.log(string.format("Restored scoop order (%d entries)", #scoop_order))
    end

    -- Restore completed scoops
    if data.completed_scoops then
        for _, name in ipairs(data.completed_scoops) do
            completed_scoops[name] = true
        end
        M.log(string.format("Restored %d completed scoops", #data.completed_scoops))
    end

    -- Restore AP received items
    if data.ap_received then
        for _, name in ipairs(data.ap_received) do
            ap_received[name] = true
        end
        M.log(string.format("Restored %d AP received scoops", #data.ap_received))
    end

    return true
end

------------------------------------------------------------
-- Blacklist Enforcement
--
-- Force-disable any blacklisted flag that is currently on.
-- Runs every enforcement cycle, ignores grace periods.
------------------------------------------------------------

local function enforce_blacklist()
    for flag_id, reason in pairs(FLAG_BLACKLIST) do
        if raw_check_flag(flag_id) then
            if raw_set_flag_off(flag_id) then
                if verbose_logging then
                    M.log(string.format("Blacklist: disabled flag %d (%s)", flag_id, reason))
                end
            end
        end
    end
end

------------------------------------------------------------
-- Primary Flag Enforcement
--
-- If scoop NOT received → disable primary flag (after grace)
-- If scoop received AND completed → disable (after grace)
-- Completion protection: don't disable if flag marks a
--   completed scoop in the COMPLETION_FLAGS table.
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
    if now - last_enforcement_time < ENFORCEMENT_COOLDOWN then return end
    last_enforcement_time = now

    -- Always run blacklist enforcement
    enforce_blacklist()

    -- Main scoop flag enforcement only runs after AP activation
    if not ap_activated then return end

    -- Build set of flags that active scoops want suppressed
    -- These override completion protection
    local active_disable_flags = {}
    for scoop_name, _ in pairs(received_scoops) do
        if not completed_scoops[scoop_name] then
            local data = SCOOP_DATA[scoop_name]
            if data and data.disable_flags then
                for _, flag_id in ipairs(data.disable_flags) do
                    active_disable_flags[flag_id] = scoop_name
                end
            end
        end
    end

    local disabled_count = 0

    for flag_id, _ in pairs(ALL_PRIMARY_FLAGS) do
        local scoop_name = PRIMARY_FLAG_TO_SCOOP[flag_id]
        local scoop_received = received_scoops[scoop_name] == true
        local scoop_completed = completed_scoops[scoop_name] == true
        local should_disable = not scoop_received or (scoop_received and scoop_completed)

        if should_disable then
            local is_on = raw_check_flag(flag_id)
            if is_on then
                -- Active scoop wants this flag off — overrides completion protection
                if active_disable_flags[flag_id] then
                    if raw_set_flag_off(flag_id) then
                        disabled_count = disabled_count + 1
                        if verbose_logging then
                            M.log(string.format("Disabled flag %d (required by active '%s')",
                                flag_id, active_disable_flags[flag_id]))
                        end
                    end
                    goto continue
                end

                -- Completion protection: if this flag marks a completed scoop, leave it
                local completion_data = COMPLETION_FLAGS[flag_id]
                if completion_data and completion_data.scoop and completed_scoops[completion_data.scoop] then
                    if verbose_logging then
                        M.log(string.format("Flag %d marks completed '%s' - skipping",
                            flag_id, completion_data.scoop))
                    end
                    goto continue
                end

                if is_flag_in_grace(flag_id) then
                    if verbose_logging then
                        M.log(string.format("Flag %d in grace (%.1fs) - skipping",
                            flag_id, get_flag_grace_remaining(flag_id)))
                    end
                else
                    if raw_set_flag_off(flag_id) then
                        disabled_count = disabled_count + 1
                        if verbose_logging then
                            M.log(string.format("Disabled flag %d (%s)", flag_id, scoop_name))
                        end
                    end
                end
            end
        end
        ::continue::
    end

    if disabled_count > 0 and not verbose_logging then
        M.log(string.format("Disabled %d mission flags", disabled_count))
    end

    -- Second pass: enforce disable_flags that aren't primary flags
    -- (e.g. completion flags from other scoops that conflict)
    for flag_id, requesting_scoop in pairs(active_disable_flags) do
        if not ALL_PRIMARY_FLAGS[flag_id] then
            if raw_check_flag(flag_id) then
                if raw_set_flag_off(flag_id) then
                    if verbose_logging then
                        M.log(string.format("Disabled non-primary flag %d (required by active '%s')",
                            flag_id, requesting_scoop))
                    else
                        M.log(string.format("Disabled conflicting flag %d for '%s'", flag_id, requesting_scoop))
                    end
                end
            end
        end
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

    local hook_ok = pcall(function()
        sdk.hook(
            ev_flag_on_method,
            function(args)
                local flag_id = sdk.to_int64(args[3]) & 0xFFFFFFFF

                -- Ignore flags we're enabling ourselves
                if currently_unlocking then return args end

                -- Block blacklisted flags immediately
                if FLAG_BLACKLIST[flag_id] then
                    if verbose_logging then
                        M.log(string.format("Blacklist: blocked flag %d in hook", flag_id))
                    end
                    -- We can't skip the call, but enforcement will clean it up
                end

                -- Detect game-triggered completion flags
                local completion = COMPLETION_FLAGS[flag_id]
                if completion and not completed_scoops[completion.scoop] then
                    M.log(string.format("COMPLETION: Flag %d → '%s'", flag_id, completion.event))
                    completed_scoops[completion.scoop] = true

                    if on_completion_detected_callback then
                        pcall(on_completion_detected_callback, completion.event, flag_id, completion.scoop)
                    end
                end

                -- Process flag triggers (reactive enable/disable)
                local trigger = FLAG_TRIGGERS[flag_id]
                if trigger then
                    if trigger.enable then
                        for _, target in ipairs(trigger.enable) do
                            raw_set_flag_on(target)
                            M.log(string.format("Trigger: flag %d → enabled %d", flag_id, target))
                        end
                    end
                    if trigger.disable then
                        for _, target in ipairs(trigger.disable) do
                            raw_set_flag_off(target)
                            M.log(string.format("Trigger: flag %d → disabled %d", flag_id, target))
                        end
                    end
                end

                -- Start grace period for unreceived primary flags
                if ALL_PRIMARY_FLAGS[flag_id] then
                    local scoop_name = PRIMARY_FLAG_TO_SCOOP[flag_id]
                    if not received_scoops[scoop_name] then
                        flag_grace_until[flag_id] = os.clock() + FLAG_GRACE_PERIOD
                        if verbose_logging then
                            M.log(string.format("Grace started for flag %d (%.0fs)", flag_id, FLAG_GRACE_PERIOD))
                        end
                    end
                end

                return args
            end,
            function(retval) return retval end
        )
    end)

    if hook_ok then
        hooks_installed = true
        M.log("evFlagOn hook installed")
    else
        M.log("ERROR: Failed to hook evFlagOn")
    end
end

------------------------------------------------------------
-- Scoop Chain Advancement
--
-- When a main scoop completes, find the next one in the
-- AP-provided order and unlock it.
------------------------------------------------------------

local function get_chain_position(scoop_name)
    for i, name in ipairs(scoop_order) do
        if name == scoop_name then return i end
    end
    return nil
end

local function try_advance_chain()
    if not scoop_order_set or #scoop_order == 0 then return end
    if not ap_activated then return end

    -- Find the first uncompleted scoop in the chain
    for i, name in ipairs(scoop_order) do
        if not completed_scoops[name] then
            -- This is the current chain position
            if received_scoops[name] then
                -- Already unlocked (flags enabled), just waiting for completion
                return
            end

            if ap_received[name] then
                -- AP sent us this item AND it's next in chain → unlock it
                M.log(string.format("Chain: Unlocking '%s' (%d/%d) — received and ready",
                    name, i, #scoop_order))
                M.unlock_scoop(name)
            else
                if verbose_logging then
                    M.log(string.format("Chain: Waiting for AP item '%s' (%d/%d)",
                        name, i, #scoop_order))
                end
            end
            return
        end
    end

    M.log("Chain: All main scoops completed!")
end

------------------------------------------------------------
-- Milestone Processing
--
-- Special events that trigger AP activation or time freeze.
-- Called from on_event_tracked when matching events fire.
------------------------------------------------------------

local function process_milestone(event_desc)
    local milestone = MILESTONE_EVENTS[event_desc]
    if not milestone then return false end

    if milestone == "activate" and not ap_activated then
        ap_activated = true
        M.log("MILESTONE: AP enforcement activated (Meet Jessie)")

        -- Try to unlock the first scoop if we have it
        try_advance_chain()

        if on_ap_activated_callback then
            pcall(on_ap_activated_callback)
        end
        save_state()
        return true

    elseif milestone == "time_freeze" and not time_frozen then
        time_frozen = true
        M.log("MILESTONE: Time freeze triggered (Get to the Stairs!)")

        if on_time_freeze_callback then
            pcall(on_time_freeze_callback)
        end
        save_state()
        return true
    end

    return false
end

------------------------------------------------------------
-- Public API: Unlock / Complete
------------------------------------------------------------

function M.unlock_scoop(scoop_name)
    local scoop = SCOOP_DATA[scoop_name]
    if not scoop then
        M.log(string.format("WARNING: Unknown scoop '%s'", tostring(scoop_name)))
        return false, 0
    end

    if received_scoops[scoop_name] then return true, 0 end
    received_scoops[scoop_name] = true
    currently_unlocking = true

    local count = 0

    if scoop.category == "Main" then
        if scoop.primary_flag and raw_set_flag_on(scoop.primary_flag) then
            count = count + 1
        end
        if scoop.secondary_flags then
            for _, flag_id in ipairs(scoop.secondary_flags) do
                if raw_set_flag_on(flag_id) then count = count + 1 end
            end
        end
        -- Disable conflicting flags from previous missions
        if scoop.disable_flags then
            for _, flag_id in ipairs(scoop.disable_flags) do
                if raw_check_flag(flag_id) then
                    raw_set_flag_off(flag_id)
                    M.log(string.format("Disabled conflicting flag %d for '%s'", flag_id, scoop_name))
                end
            end
        end
        M.log(string.format("Unlocked MAIN '%s' (%d flags, primary=%d)",
            scoop_name, count, scoop.primary_flag or 0))
    else
        if scoop.flags then
            for _, flag_id in ipairs(scoop.flags) do
                if flag_id and flag_id ~= 0 and raw_set_flag_on(flag_id) then
                    count = count + 1
                end
            end
        end
        M.log(string.format("Unlocked %s '%s' (%d flags)",
            scoop.category, scoop_name, count))
    end

    currently_unlocking = false
    return true, count
end

function M.complete_scoop(scoop_name)
    local scoop = SCOOP_DATA[scoop_name]
    if not scoop then return false end
    if completed_scoops[scoop_name] then return true end
    completed_scoops[scoop_name] = true
    M.log(string.format("Completed %s '%s'", scoop.category, scoop_name))

    -- Chain advancement: check if the next scoop is ready
    if scoop.category == "Main" and scoop_order_set then
        try_advance_chain()
    end

    -- Persist
    save_state()
    return true
end

------------------------------------------------------------
-- Event Tracker Integration
------------------------------------------------------------

function M.on_event_tracked(event_desc)
    -- Check milestones first
    process_milestone(event_desc)

    -- Then check scoop completions
    local scoop_name = COMPLETION_EVENT_TO_SCOOP[event_desc]
    if scoop_name then
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
    local main_count, side_count = 0, 0

    -- If using AP ordering, only reapply the current chain scoop
    if scoop_order_set and ap_activated then
        local current = M.get_current_chain_scoop()
        if current and not completed_scoops[current] then
            received_scoops[current] = nil  -- Clear so unlock re-enables flags
            M.unlock_scoop(current)
            main_count = 1
        end
    else
        -- Fallback: reapply all received main scoops
        for scoop_name, _ in pairs(received_scoops) do
            if not completed_scoops[scoop_name] then
                local data = SCOOP_DATA[scoop_name]
                if data and data.category == "Main" then
                    received_scoops[scoop_name] = nil
                    M.unlock_scoop(scoop_name)
                    main_count = main_count + 1
                end
            end
        end
    end

    -- Always reapply side scoops
    for scoop_name, _ in pairs(received_scoops) do
        if not completed_scoops[scoop_name] then
            local data = SCOOP_DATA[scoop_name]
            if data and data.category ~= "Main" then
                received_scoops[scoop_name] = nil
                M.unlock_scoop(scoop_name)
                side_count = side_count + 1
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
            if flag_id ~= 0 and not raw_check_flag(flag_id) then return false end
        end
        return true
    end
    return nil
end

function M.has_received_scoop(scoop_name)
    return received_scoops[scoop_name] == true
end

function M.has_ap_received(scoop_name)
    return ap_received[scoop_name] == true
end

function M.is_scoop_completed(scoop_name)
    return completed_scoops[scoop_name] == true
end

function M.get_all_scoop_names()
    local names = {}
    for name, _ in pairs(SCOOP_DATA) do table.insert(names, name) end
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
    for _, m in ipairs(mains) do table.insert(result, m.name) end
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
        if a.order and b.order then return a.order < b.order end
        return a.name < b.name
    end)
    return status
end

function M.get_completion_flags()
    local result = {}
    for flag_id, data in pairs(COMPLETION_FLAGS) do
        table.insert(result, { flag_id = flag_id, event = data.event, scoop = data.scoop })
    end
    table.sort(result, function(a, b) return a.flag_id < b.flag_id end)
    return result
end

------------------------------------------------------------
-- Bulk Operations
------------------------------------------------------------

function M.reset_all()
    ap_received = {}
    received_scoops = {}
    completed_scoops = {}
    ap_activated = false
    time_frozen = false
    scoop_order = {}
    scoop_order_set = false
    M.log("Reset all scoop tracking")
    save_state()
end

function M.unlock_all()
    local count = 0
    for _, name in ipairs(M.get_main_scoops_in_order()) do
        M.unlock_scoop(name)
        count = count + 1
    end
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
    return count
end

------------------------------------------------------------
-- Settings
------------------------------------------------------------

function M.set_verbose_logging(enabled)
    verbose_logging = enabled
    M.log("Verbose " .. (enabled and "ON" or "OFF"))
end

function M.set_enforcement_enabled(enabled)
    enforcement_enabled = enabled
    M.log("Enforcement " .. (enabled and "ON" or "OFF"))
end

function M.force_enforce()
    last_enforcement_time = 0
    enforce_primary_flags()
end

------------------------------------------------------------
-- Blacklist API
------------------------------------------------------------

function M.blacklist_flag(flag_id, reason)
    FLAG_BLACKLIST[flag_id] = reason or "no reason"
    if raw_check_flag(flag_id) then raw_set_flag_off(flag_id) end
    M.log(string.format("Blacklisted flag %d: %s", flag_id, FLAG_BLACKLIST[flag_id]))
end

function M.unblacklist_flag(flag_id)
    FLAG_BLACKLIST[flag_id] = nil
    M.log(string.format("Removed flag %d from blacklist", flag_id))
end

function M.get_blacklist()
    return FLAG_BLACKLIST
end

------------------------------------------------------------
-- Flag Triggers API
------------------------------------------------------------

function M.add_trigger(trigger_flag, enable_flags, disable_flags)
    FLAG_TRIGGERS[trigger_flag] = {
        enable = enable_flags,
        disable = disable_flags,
    }
    M.log(string.format("Added trigger: flag %d → enable %s, disable %s",
        trigger_flag,
        enable_flags and table.concat(enable_flags, ",") or "none",
        disable_flags and table.concat(disable_flags, ",") or "none"))
end

function M.remove_trigger(trigger_flag)
    FLAG_TRIGGERS[trigger_flag] = nil
    M.log(string.format("Removed trigger for flag %d", trigger_flag))
end

function M.get_triggers()
    return FLAG_TRIGGERS
end

------------------------------------------------------------
-- Completion Detection Callback
------------------------------------------------------------

function M.set_completion_callback(callback)
    on_completion_detected_callback = callback
    M.log("Completion callback " .. (callback and "SET" or "CLEARED"))
end

------------------------------------------------------------
-- AP Scoop Ordering API
------------------------------------------------------------

function M.set_scoop_order(order_list)
    if type(order_list) ~= "table" or #order_list == 0 then
        M.log("ERROR: Invalid scoop order (empty or not a table)")
        return false
    end

    scoop_order = order_list
    scoop_order_set = true

    local names = {}
    for i, name in ipairs(scoop_order) do
        table.insert(names, string.format("%d.%s", i, name))
    end
    M.log(string.format("Scoop order set (%d entries): %s", #scoop_order, table.concat(names, ", ")))

    -- If already activated, try to advance the chain
    if ap_activated then
        try_advance_chain()
    end

    save_state()
    return true
end

function M.get_scoop_order()
    return scoop_order
end

function M.is_scoop_order_set()
    return scoop_order_set
end

function M.get_current_chain_index()
    if not scoop_order_set or #scoop_order == 0 then return 0 end
    for i, name in ipairs(scoop_order) do
        if not completed_scoops[name] then return i end
    end
    return #scoop_order + 1  -- All done
end

function M.get_current_chain_scoop()
    local idx = M.get_current_chain_index()
    if idx > 0 and idx <= #scoop_order then
        return scoop_order[idx]
    end
    return nil
end

------------------------------------------------------------
-- Milestone API
------------------------------------------------------------

function M.is_ap_activated()
    return ap_activated
end

function M.is_time_frozen()
    return time_frozen
end

function M.set_ap_activated_callback(callback)
    on_ap_activated_callback = callback
    M.log("AP activated callback " .. (callback and "SET" or "CLEARED"))
end

function M.set_time_freeze_callback(callback)
    on_time_freeze_callback = callback
    M.log("Time freeze callback " .. (callback and "SET" or "CLEARED"))
end

-- Force activation (for testing or manual override)
function M.force_activate()
    if ap_activated then return end
    ap_activated = true
    M.log("FORCED: AP enforcement activated")

    try_advance_chain()

    if on_ap_activated_callback then
        pcall(on_ap_activated_callback)
    end
    save_state()
end

------------------------------------------------------------
-- Persistence API
------------------------------------------------------------

function M.set_save_filename(slot, seed)
    save_filename = string.format("DRAP_scoops_%s_%s.json",
        tostring(slot or "unknown"), tostring(seed or "unknown"))
    M.log("Save filename: " .. save_filename)
end

function M.load_save()
    return load_state()
end

function M.save()
    return save_state()
end

------------------------------------------------------------
-- AP Bridge Integration
------------------------------------------------------------

function M.register_with_ap_bridge(ap_bridge)
    if not ap_bridge or not ap_bridge.register_item_handler_by_name then
        M.log("ERROR: Invalid AP bridge")
        return 0
    end

    local count = 0
    for scoop_name, data in pairs(SCOOP_DATA) do
        ap_bridge.register_item_handler_by_name(scoop_name, function(net_item, item_name, sender_name)
            M.log(string.format("Received scoop '%s' from %s", tostring(item_name), tostring(sender_name or "?")))

            -- Mark as received from AP
            ap_received[scoop_name] = true
            save_state()

            if data.category == "Main" and scoop_order_set then
                -- Main scoops gate through the chain — only unlock if it's next
                try_advance_chain()
            else
                -- Non-main scoops (Survivor, Psychopath) unlock immediately
                M.unlock_scoop(scoop_name)
            end
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

local CATEGORY_COLORS = {
    Main = 0xFFFFFF00,
    Survivor = 0xFF66FF66,
    Psychopath = 0xFFFF6666,
}

local function draw_main_window()
    if not gui_visible then return end

    imgui.set_next_window_size(Vector2f.new(700, 800), 4)
    local still_open = imgui.begin_window("Scoop Unlocker v8", true, 0)
    if not still_open then
        gui_visible = false
        imgui.end_window()
        return
    end

    -- Status bar
    local efm = efm_mgr:get()
    imgui.text_colored(efm and "EFM: OK" or "EFM: N/A", efm and 0xFF00FF00 or 0xFFFF0000)
    imgui.same_line()
    imgui.text_colored(hooks_installed and "Hook: ON" or "Hook: OFF", hooks_installed and 0xFF00FF00 or 0xFFFF0000)
    imgui.same_line()
    imgui.text_colored(enforcement_enabled and "Enforce: ON" or "Enforce: OFF",
        enforcement_enabled and 0xFF00FF00 or 0xFFFFFF00)
    imgui.same_line()
    imgui.text_colored(ap_activated and "AP: ACTIVE" or "AP: WAITING",
        ap_activated and 0xFF00FF00 or 0xFFFF8800)
    imgui.same_line()
    imgui.text_colored(time_frozen and "Time: FROZEN" or "Time: NORMAL",
        time_frozen and 0xFF88CCFF or 0xFFAAAAAA)

    -- Counts
    local received_count, completed_count = 0, 0
    for _ in pairs(received_scoops) do received_count = received_count + 1 end
    for _ in pairs(completed_scoops) do completed_count = completed_count + 1 end

    local blacklist_count = 0
    for _ in pairs(FLAG_BLACKLIST) do blacklist_count = blacklist_count + 1 end

    local trigger_count = 0
    for _ in pairs(FLAG_TRIGGERS) do trigger_count = trigger_count + 1 end

    imgui.text(string.format("Recv: %d | Done: %d | Blacklist: %d | Triggers: %d",
        received_count, completed_count, blacklist_count, trigger_count))

    -- Chain status
    if scoop_order_set then
        local chain_idx = M.get_current_chain_index()
        local current_scoop = M.get_current_chain_scoop()
        if current_scoop then
            imgui.text_colored(
                string.format("Chain: %d/%d → %s", chain_idx, #scoop_order, current_scoop),
                0xFF00FFFF)
        else
            imgui.text_colored(
                string.format("Chain: COMPLETE (%d/%d)", #scoop_order, #scoop_order),
                0xFF00FF00)
        end
    else
        imgui.text_colored("Chain: No order set", 0xFFFF8800)
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
    imgui.same_line()
    if not ap_activated then
        if imgui.button("Force Activate") then M.force_activate() end
    end

    local enforce_changed, enforce_val = imgui.checkbox("Enforcement", enforcement_enabled)
    if enforce_changed then M.set_enforcement_enabled(enforce_val) end
    imgui.same_line()
    local verbose_changed, verbose_val = imgui.checkbox("Verbose", verbose_logging)
    if verbose_changed then M.set_verbose_logging(verbose_val) end

    imgui.separator()

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
    local current_chain_scoop = M.get_current_chain_scoop()

    for _, s in ipairs(status_list) do
        local show = true
        if filter_category ~= "All" and s.category ~= filter_category then show = false end
        if show_only_received and not s.received then show = false end

        if show then
            local color = CATEGORY_COLORS[s.category] or 0xFFFFFFFF
            local is_current_chain = (s.name == current_chain_scoop)

            local status_str = ""
            if s.completed then
                status_str = " [DONE]"
                color = 0xFF888888
            elseif is_current_chain then
                status_str = " [CURRENT]"
                color = 0xFF00FFFF
            elseif s.received then
                status_str = " [RECV]"
            end
            if s.flags_active then
                status_str = status_str .. " [ON]"
            end

            -- Show chain position for main scoops
            local chain_str = ""
            if scoop_order_set and s.category == "Main" then
                local chain_pos = get_chain_position(s.name)
                if chain_pos then
                    chain_str = string.format(" (%d/%d)", chain_pos, #scoop_order)
                end
            end

            if imgui.button("Unlock##" .. s.name) then M.unlock_scoop(s.name) end
            imgui.same_line()

            if s.completion_event then
                if imgui.button("Done##" .. s.name) then M.complete_scoop(s.name) end
                imgui.same_line()
            end

            local order_str = s.order and string.format(" #%d", s.order) or ""
            local flag_str = s.primary_flag and string.format(" [%d]", s.primary_flag) or ""
            local npc_str = s.npcs and #s.npcs > 0 and (" - " .. table.concat(s.npcs, ", ")) or ""

            imgui.text_colored(
                string.format("%s [%s%s]%s%s%s%s", s.name, s.category or "?", order_str, flag_str, chain_str, status_str, npc_str),
                color
            )

            if imgui.is_item_hovered() then
                local tip = ""
                if s.primary_flag then tip = "Primary: " .. s.primary_flag end
                if s.flags and #s.flags > 0 then
                    tip = tip .. (tip ~= "" and "\n" or "") .. "Flags: " .. table.concat(s.flags, ", ")
                end
                if s.completion_event then tip = tip .. "\nCompletes: " .. s.completion_event end
                if tip ~= "" then imgui.set_tooltip(tip) end
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
    if not hooks_installed and not hook_install_attempted then
        if Shared.is_in_game and Shared.is_in_game() then
            install_hooks()
        end
    end
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
_G.scoop_gui = function() M.show_window() end
_G.scoop_unlock_all = function() return M.unlock_all() end
_G.scoop_enforce = function() M.force_enforce() end
_G.scoop_verbose = function(on)
    if on == nil then on = not verbose_logging end
    M.set_verbose_logging(on)
end
_G.scoop_blacklist = function(flag_id, reason) M.blacklist_flag(flag_id, reason) end
_G.scoop_unblacklist = function(flag_id) M.unblacklist_flag(flag_id) end
_G.scoop_activate = function() M.force_activate() end
_G.scoop_chain = function()
    if not scoop_order_set then
        print("No scoop order set")
        return
    end
    local current = M.get_current_chain_scoop()
    for i, name in ipairs(scoop_order) do
        local done = completed_scoops[name] and "D" or "."
        local recv = received_scoops[name] and "R" or "."
        local marker = (name == current) and " <<<" or ""
        print(string.format("  %d. [%s%s] %s%s", i, recv, done, name, marker))
    end
end
_G.scoop_status = function()
    print(string.format("AP Activated: %s | Time Frozen: %s | Chain Set: %s",
        tostring(ap_activated), tostring(time_frozen), tostring(scoop_order_set)))
    print(string.format("Save: %s", tostring(save_filename or "none")))
    for _, s in ipairs(M.get_all_status()) do
        local m = (s.received and "R" or ".") .. (s.flags_active and "A" or ".") .. (s.completed and "C" or ".")
        print(string.format("[%s] %s (%s)", m, s.name, s.category or "?"))
    end
end
_G.scoop_main = function()
    for i, name in ipairs(M.get_main_scoops_in_order()) do
        local data = SCOOP_DATA[name]
        local recv = received_scoops[name] and "R" or "."
        local done = completed_scoops[name] and "D" or "."
        local flag_on = data.primary_flag and raw_check_flag(data.primary_flag) and "ON" or "off"
        print(string.format("  %d. [%s%s] %s (flag %d = %s)",
            i, recv, done, name, data.primary_flag or 0, flag_on))
    end
end

------------------------------------------------------------
-- Module Load
------------------------------------------------------------

local primary_count = 0
for _ in pairs(ALL_PRIMARY_FLAGS) do primary_count = primary_count + 1 end

local completion_count = 0
for _ in pairs(COMPLETION_FLAGS) do completion_count = completion_count + 1 end

local blacklist_count = 0
for _ in pairs(FLAG_BLACKLIST) do blacklist_count = blacklist_count + 1 end

local trigger_count = 0
for _ in pairs(FLAG_TRIGGERS) do trigger_count = trigger_count + 1 end

M.log(string.format("ScoopUnlocker v8 loaded | Primary: %d | Completion: %d | Blacklist: %d | Triggers: %d | Grace: %.0fs",
    primary_count, completion_count, blacklist_count, trigger_count, FLAG_GRACE_PERIOD))

return M