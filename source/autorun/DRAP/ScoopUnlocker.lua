-- DRAP/ScoopUnlocker.lua

local Shared = require("DRAP/Shared")
local Ledger = require("DRAP/LocationLedger")
local SharedData = require("DRAP/SharedData")
local State = require("DRAP/scoops/ScoopState")
local FlagPolicies = require("DRAP/scoops/FlagPolicies")
local Reconciler = require("DRAP/scoops/FlagReconciler")

local M = Shared.create_module("ScoopUnlocker")

local efm_mgr = M:add_singleton("efm", "app.solid.gamemastering.EventFlagsManager")
local am_mgr  = M:add_singleton("am",  "app.solid.gamemastering.AreaManager")

local FLAG_BLACKLIST = {
    [300] = "Kills all NPCs when enabled"
}

local FLAG_TRIGGERS = {
    [392] = { enable = { 300 } },   -- Carlito's Hideout: enable 300 so player can enter
    [355] = { disable = { 300 } },  -- Carlito's Hideout: disable 300 once inside (kills NPCs if left on)
}

local TIME_SKIP_TRIGGERS = {
    [1311] = { target_mdate = 41200, name = "Zombie Jessie to Get Bit!" },
}

local HIDEOUT_AREA_INDEX = 1025
local NORTH_PLAZA_AREA_INDEX = 1024
local PARADISE_PLAZA_AREA_INDEX = 512
local ENTRANCE_PLAZA_AREA_INDEX = 256   -- AreaManager mAreaIndex for s100

-- ScoopSanity-only EP-shutter trigger box: entering this AABB in Entrance
-- Plaza fires flag 270 once (plays the "Backup for Brad" cutscene that opens
-- the EP shutter). Tune via _G.drap_ep270_set_box / _G.drap_ep270_show_pos.
local EP270_TRIGGER_BOX = {
    min_x = 120.0, max_x = 130.0,
    min_y = 0.0,   max_y = 3.0,
    min_z = 130.0, max_z = 140.0,
}

-- Simone Ravendark's corner of Paradise Plaza. Flag 295 tells the game Isabela
-- is back in the Security Room, which Simone checks before agreeing to follow.
-- 295 is also a Santa Cabeza byproduct, so once that mission completes the
-- cascade sweep clears it every cycle and she can never be recruited -- the
-- long-standing "Rescue Simone Ravendark" bug.
--
-- Rather than dropping 295 from the cascade (it is there for a reason we no
-- longer have), hold it on just around her: ~8m of her spawn point, the same
-- shape as the flag 301 Hideout toggle below. Outside the box the sweep goes
-- back to clearing it.
local SIMONE_FLAG = 295
local SIMONE_BOX = {
    min_x = 130.5, max_x = 146.5,
    min_y = -6.0,  max_y = 8.0,
    min_z = 11.5,  max_z = 27.5,
}

-- Engine's "EP-shutter cutscene played" markers, set only by that cutscene's
-- tail (in no CASCADE/COMPLETION table). They live in save state, so a save
-- reload resets them and our trigger refires -- no DRAP-side persistence.
--   765  = EV_RADIO_MES_FLAG_S100  (radio message after the cutscene)
--   2280 = EV_MESSAGE_68           (post-cutscene message banner)
local EP270_GATE_FLAGS = { 765, 2280 }

local time_skips_fired = {}
local active_time_skip = nil

-- Scoop definitions come from drdr_shared.json (schema v2), the same file the
-- Python generation side derives its scoop tables from (names validated
-- against Items.py / Locations.py at generation), so the two can't drift.
-- completion_event is omitted when the entry sets lua_event_tracking = false
-- (Hideout: EventTracker fires too early; completion comes via
-- COMPLETION_FLAGS[2322] instead).
local SCOOP_DATA = {}
local SCOOP_DESCRIPTIONS = {}

local function build_scoop_data()
    SCOOP_DATA = {}
    SCOOP_DESCRIPTIONS = {}
    for _, e in ipairs(SharedData.scoops()) do
        if e.name and e.category then
            local d = {
                category = e.category,
                order = e.order,
                primary_flag = e.primary_flag,
                secondary_flags = e.secondary_flags,
                disable_flags = e.disable_flags,
                disable_on_unlock = e.disable_on_unlock,
                flags = e.flags,
                npcs = e.npcs,
                clear_on_complete = e.clear_on_complete,
                disp_flag = e.disp_flag,
                disp_end_flag = e.disp_end_flag,
                extra_disp_flags = e.extra_disp_flags,  -- 2nd box for pairs
                description = e.description,   -- MissionTruth box text
                guide = e.guide,              -- MissionTruth pin redirect
                repurpose = e.repurpose,      -- borrowed-box text swap
            }
            if e.completion_event and e.lua_event_tracking ~= false then
                d.completion_event = e.completion_event
            end
            SCOOP_DATA[e.name] = d
            if e.description then
                SCOOP_DESCRIPTIONS[e.name] = e.description
            end
        end
    end
    local n = 0
    for _ in pairs(SCOOP_DATA) do n = n + 1 end
    if n == 0 then
        M.log("ERROR: no scoop definitions loaded -- drdr_shared.json is missing "
            .. "or predates schema v2. The scoop system is DISABLED. "
            .. "Update reframework/data/drdr_shared.json to match this mod version.")
    end
    return n
end

build_scoop_data()

local COMPLETION_EVENT_TO_SCOOP = {}
local PRIMARY_FLAG_TO_SCOOP = {}
local CONTROLLED_FLAGS = {}
local ALL_SIDE_SCOOP_FLAGS = {}

local function build_lookup_tables()
    COMPLETION_EVENT_TO_SCOOP = {}
    PRIMARY_FLAG_TO_SCOOP = {}
    CONTROLLED_FLAGS = {}
    ALL_SIDE_SCOOP_FLAGS = {}

    for scoop_name, data in pairs(SCOOP_DATA) do
        if data.completion_event then
            COMPLETION_EVENT_TO_SCOOP[data.completion_event] = scoop_name
        end
        if data.primary_flag then
            PRIMARY_FLAG_TO_SCOOP[data.primary_flag] = scoop_name
        end
        if data.category == "Main" then
            if data.primary_flag then
                CONTROLLED_FLAGS[data.primary_flag] = scoop_name
            end
            if data.secondary_flags then
                for _, flag_id in ipairs(data.secondary_flags) do
                    CONTROLLED_FLAGS[flag_id] = scoop_name
                end
            end
        end
        if data.category ~= "Main" and data.category ~= "Special" and data.flags then
            for _, flag_id in ipairs(data.flags) do
                if flag_id and flag_id ~= 0 then
                    ALL_SIDE_SCOOP_FLAGS[flag_id] = scoop_name
                end
            end
        end
    end
end

build_lookup_tables()

local CONFLICT_GROUPS = {
    kent = {
        "Cut from the Same Cloth",  -- Kent Day 1
        "Photo Challenge",          -- Kent Day 2
        "Photographer's Pride",     -- Kent Day 3
    },
    gun_shop = {
        "Cletus",
        "Gun Shop Standoff",
    },
}

-- Side scoops that must be suppressed while a specific main scoop is active (crash prevention)
local MAIN_BLOCKS_SIDE = {
    ["Rescue the Professor"] = { "Mark of the Sniper" },
    ["Backup for Brad"] = { "Mark of the Sniper" },
}

-- Prerequisite scoops that must be completed before a scoop can be unlocked (ordering enforcement)
local SCOOP_PREREQUISITES = {
    ["Photo Challenge"]      = { "Cut from the Same Cloth" },                          -- Kent Day 2 needs Day 1 done
    ["Photographer's Pride"] = { "Cut from the Same Cloth", "Photo Challenge" },       -- Kent Day 3 needs Day 1+2 done
}

-- Engine-flag prerequisites: unlock parks (poll-deferred, retried each frame)
-- until ANY listed flag is on. Distinct from SCOOP_PREREQUISITES, which gates
-- on other scoop completions.
-- Mark of the Sniper: gated on the EP-shutter cutscene (765/2280, same set as
-- ep270_gates_open). Activating it earlier makes the engine reconfigure s100
-- around the sniper flags (798, 808) so the shutter never opens even when
-- flag 270 fires. Deferring lets the cutscene play first, then MOTS unlocks.
local SCOOP_FLAG_PREREQUISITES = {
    ["Mark of the Sniper"] = { 765, 2280 },
}

-- Flag-id -> AP event mapping, loaded from drdr_shared.json "completion_flags".
-- Event strings are validated against apworld location names at generation
-- time (a mismatched name silently sends an unresolvable check).
local COMPLETION_FLAGS = {}

local function build_completion_flags()
    COMPLETION_FLAGS = {}
    for _, row in ipairs(SharedData.completion_flags()) do
        if row.flag and row.event then
            COMPLETION_FLAGS[row.flag] = { event = row.event, scoop = row.scoop }
        end
    end
end

build_completion_flags()

-- Mission byproduct flags cleared each cycle (only when owning mission is inactive).
-- Excludes: CONTROLLED_FLAGS, FLAG_BLACKLIST, case step/radio/SCQ flags (game recalculates).
local CASCADE_FLAGS = {
    -- Backup for Brad
    [269]  = "Backup for Brad",
    [1282] = "Backup for Brad",
    [418]  = "Backup for Brad",

    -- An Odd Old Man
    [270]  = "Backup for Brad",
    [271]  = "Backup for Brad",

    -- Another Source
    [2433] = "Another Source",

    -- Rescue the Professor (276 deliberately omitted -- managed in on_frame
    -- with area gating so the EP door is open when Professor isn't active)
    [415]  = "Rescue the Professor",
    [1283] = "Rescue the Professor",
    [137]  = "Rescue the Professor",

    -- Medicine Run
    [280]  = "Medicine Run",
    [281]  = "Medicine Run",
    [408]  = "Medicine Run",
    [834]  = "Medicine Run",
    [1287] = "Medicine Run",
    [2192] = "Medicine Run",
    [2434] = "Medicine Run",
    [2435] = "Medicine Run",

    -- Girl Hunting
    [285]  = "Girl Hunting",
    [1288] = "Girl Hunting",
    [2436] = "Girl Hunting",

    -- A Promise to Isabela
    [2437]  = "A Promise to Isabela",

    -- Santa Cabeza
    [295]  = "Santa Cabeza",
    [2438] = "Santa Cabeza",

    -- The Last Resort
    [296]  = "The Last Resort",
    [422]  = "The Last Resort",
    [1284] = "The Last Resort",
    [297]  = "The Last Resort",
    [443]  = "The Last Resort",
    [298]  = "The Last Resort",
    [318]  = "The Last Resort",
    [319]  = "The Last Resort",
    [452]  = "The Last Resort",
    [2193] = "The Last Resort",
    [2194] = "The Last Resort",
    [2439] = "The Last Resort",

    -- Hideout
    [392]  = "Hideout",

    -- The Butcher
    [304]  = "The Butcher",
    [1285] = "The Butcher",
    [409]  = "The Butcher",
    [2440] = "The Butcher",
}

-- Read-only aliases into DRAP/scoops/ScoopState (the pure state machine).
-- The tables are cleared in place, never reassigned, so they stay valid;
-- ALL writes go through State.* methods.
local ap_received = State.ap_received
local received_scoops = State.received
local completed_scoops = State.completed
local completion_times = State.completion_times
local scoop_order = State.scoop_order

local currently_unlocking = false
local hooks_installed = false
local hook_install_attempted = false
local verbose_logging = false
local enforcement_enabled = true
local last_enforcement_time = 0
local ENFORCEMENT_COOLDOWN = 1.0
local COMPLETION_GRACE_SECONDS = 3
local pending_suppress = {}
local on_completion_detected_callback = nil

-- Log-spam suppression: last cascade-clear signature + completion events
-- already logged. Without it, the Savior-mode oscillation between force-
-- enabling flag 270 and CASCADE_FLAGS clearing it logs every frame.
local _last_cascade_signature = nil
local _logged_completion_events = {}   -- event_name -> true
local scoop_sanity_enabled = false
local cult_limited_enabled = false
local door_randomizer_enabled = false
local goal_mode = 0   -- 0 = Ending S, 1 = Ending A, 2 = Savior
local on_ap_activated_callback = nil
local on_time_freeze_callback = nil
local on_time_unfreeze_callback = nil
local professor_276_disabled = false -- tracks one-time disable of flag 276 for Rescue the Professor
local save_filename = nil

local MILESTONE_EVENTS = {
    ["Get to the stairs!"] = "time_freeze",
    ["Meet Jessie in the Warehouse"] = "activate",
    ["Get bit!"] = "time_freeze",
}

local JESSIE_FLAG = 769  -- ON after talking to Jessie; OFF = player reloaded pre-Jessie save
-- Reload-detector dwell: 769 must read confirmed-false this long before the
-- destructive deactivation runs (failed/pre-restore reads reset the timer).
local RELOAD_CONFIRM_SECONDS = 2.0
local jessie_false_since = nil

function M.is_currently_unlocking()
    return currently_unlocking
end

local function count_keys(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

-- true/false for a confirmed read, nil when the read failed (EFM missing or
-- call error -- typical during load screens). Never treat nil as "flag off":
-- doing so lets the reload detector and time-freeze sync clobber persisted
-- state during load windows.
local function raw_check_flag(flag_id)
    local efm = efm_mgr:get()
    if not efm then return nil end
    local ok, result = pcall(function()
        return efm:call("evFlagCheck", flag_id)
    end)
    if not ok then return nil end
    return result == true
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

-- True while a play session exists (gameplay or cutscene -- the player
-- object persists through cutscenes). False at the title screen, where
-- the EFM holds cleared/menu flag state that enforcement must not fight.
local function is_player_session()
    local pm = sdk.get_managed_singleton("app.solid.PlayerManager")
    if not pm then return false end
    local ok, player = pcall(function() return pm:call("get_CurrentPlayer") end)
    return ok and player ~= nil
end

local function save_state()
    if not save_filename then return false end

    local data = State.serialize()

    -- The run ledger (one file per seed) is the primary store; the legacy
    -- standalone file is only written as a fallback pre-connect.
    local ok
    if Ledger.is_init() then
        ok = Ledger.set_section("scoops", data)
    else
        ok = pcall(json.dump_file, save_filename, data)
    end
    if ok then
        if verbose_logging then
            M.log(string.format("Saved state (%d completed)", #data.completed_scoops))
        end
    else
        M.log("ERROR: Failed to save scoop state")
    end
    return ok
end

local function load_state()
    -- Prefer the run ledger; fall back to (and migrate from) the legacy
    -- standalone file for seeds saved by older versions.
    local data = Ledger.is_init() and Ledger.get_section("scoops") or nil
    local from_legacy = false
    if not data and save_filename then
        data = Shared.load_json_if_exists(save_filename)
        from_legacy = data ~= nil
    end
    if not data then
        M.log("No existing scoop state (ledger or legacy file)")
        return false
    end
    if from_legacy and Ledger.is_init() then
        Ledger.set_section("scoops", data)
        M.log("Migrated scoop state into the run ledger")
    end

    return State.restore(data)
end

-- Blocking/prerequisite queries live in the state machine; these shims
-- keep the many call sites below unchanged.
local function is_conflict_blocked(scoop_name)
    return State.is_conflict_blocked(scoop_name)
end

local function is_blocked_by_active_main(scoop_name)
    return State.is_blocked_by_active_main(scoop_name)
end

local function has_prerequisites_met(scoop_name)
    return State.has_prerequisites_met(scoop_name)
end

-- Any completed main-category scoop, or nil. Used by the EP-shutter
-- special cases (try_fire_ep270_in_scoop_sanity, Backup for Brad's
-- conditional shutter reset) and State's Mark-of-the-Sniper flag-prereq
-- bypass.
local function find_completed_main_scoop()
    return State.find_completed_main()
end

-- Live player position via PlayerManager.CurrentPlayerCondition.LastPlayerPos.
-- Returns x, y, z numbers, or nil when the player isn't spawned (title menu /
-- between scenes).
local function get_player_pos_xyz()
    local pm = sdk.get_managed_singleton("app.solid.PlayerManager")
    if not pm then return nil end
    local cond
    pcall(function() cond = pm:call("get_CurrentPlayerCondition") end)
    if not cond then return nil end
    local pos
    pcall(function() pos = cond:get_field("LastPlayerPos") end)
    if not pos then return nil end
    local x, y, z
    pcall(function() x = pos.x; y = pos.y; z = pos.z end)
    if not (x and y and z) then return nil end
    return x, y, z
end

local function in_ep270_box(x, y, z)
    return x >= EP270_TRIGGER_BOX.min_x and x <= EP270_TRIGGER_BOX.max_x
       and y >= EP270_TRIGGER_BOX.min_y and y <= EP270_TRIGGER_BOX.max_y
       and z >= EP270_TRIGGER_BOX.min_z and z <= EP270_TRIGGER_BOX.max_z
end

-- True iff the EP-shutter cutscene has already played in the currently
-- loaded save. Reads the engine's own post-cutscene markers, so this
-- automatically tracks across save/load and resets on rollback or new game.
local function ep270_gates_open()
    for _, fid in ipairs(EP270_GATE_FLAGS) do
        if raw_check_flag(fid) then return true end
    end
    return false
end

-- Session-only timestamp of our last flag-270 fire. The cutscene takes a
-- few seconds to land 765/2280; this grace window prevents a refire while
-- the cutscene is mid-playback.
local _ep_270_fired_at_clock = 0

-- Pending flag clears scheduled from inside the evFlagOn pre-hook (e.g.
-- after ss_block suppresses a pre-fired completion). Processed at the top
-- of M.on_frame so the engine's evFlagOn implementation has already run
-- and we're not racing it.
local pending_flag_clears = {}

-- ScoopSanity-only: fire flag 270 (EP-shutter cutscene) the first time the
-- player walks into the configured AABB in Entrance Plaza after AP activates.
-- Persisted via engine flags 765/2280 so save reload/new game come for free.
-- Skipped while a first-in-chain Backup for Brad is pending -- its natural
-- flow fires 270 itself, so pre-firing would race its completion.
local function try_fire_ep270_in_scoop_sanity()
    if not scoop_sanity_enabled then return end
    if not State.is_activated() then return end
    if ep270_gates_open() then return end

    -- Any later completed main already opened the shutters, so the cutscene
    -- is redundant (and would re-show closed-shutter state the world moved past).
    local later_main = find_completed_main_scoop()
    if later_main then return end

    -- Don't pre-fire while a first-in-chain Backup for Brad is pending -- its
    -- mission flow fires 270 itself. received/completed, NOT
    -- get_current_chain_scoop() (which reads the next uncompleted main before
    -- its AP item arrives, so a late-randomized Backup would block forever).
    if scoop_order[1] == "Backup for Brad"
        and received_scoops["Backup for Brad"]
        and not completed_scoops["Backup for Brad"] then
        return
    end

    -- Grace window: 765/2280 land near the cutscene's end, so gates_open()
    -- stays false for a few seconds after firing. Don't refire meanwhile.
    if (os.clock() - _ep_270_fired_at_clock) < 8.0 then return end

    local am = am_mgr:get()
    if not am then return end
    local af = am_mgr:get_field("mAreaIndex", false)
    if not af then return end
    local area = Shared.to_int(Shared.safe_get_field(am, af))
    if area ~= ENTRANCE_PLAZA_AREA_INDEX then return end
    local x, y, z = get_player_pos_xyz()
    if not x then return end
    if not in_ep270_box(x, y, z) then return end

    -- Suppress the evFlagOn -> COMPLETION_FLAGS[270] handler while we set it
    -- (270 = "Complete Backup for Brad"; don't send that check pre-earn).
    currently_unlocking = true
    raw_set_flag_on(270)
    currently_unlocking = false
    _ep_270_fired_at_clock = os.clock()
    M.log(string.format("ScoopSanity: fired flag 270 (EP shutter cutscene) at (%.2f, %.2f, %.2f)",
        x, y, z))
end

local function get_current_area_index()
    local am = am_mgr:get()
    if not am then return nil end
    local f = am_mgr:get_field("mAreaIndex", false)
    if not f then return nil end
    return Shared.to_int(Shared.safe_get_field(am, f))
end

-- Is the player standing with Simone? Area first, so the position read is
-- skipped everywhere else.
local function player_is_with_simone()
    if get_current_area_index() ~= PARADISE_PLAZA_AREA_INDEX then return false end
    local x, y, z = get_player_pos_xyz()
    if not x then return false end
    return x >= SIMONE_BOX.min_x and x <= SIMONE_BOX.max_x
       and y >= SIMONE_BOX.min_y and y <= SIMONE_BOX.max_y
       and z >= SIMONE_BOX.min_z and z <= SIMONE_BOX.max_z
end

local function each_conflict_scoop()
    local names = {}
    for _, group_list in pairs(CONFLICT_GROUPS) do
        for _, scoop_name in ipairs(group_list) do
            names[scoop_name] = true
        end
    end
    return pairs(names)
end

-- Current scene path (e.g. "s503" = Colby's theater); Cult Limited keys on it.
local function get_current_scene()
    local am = am_mgr:get()
    if not am then return nil end
    local scene
    pcall(function() scene = am:get_field("CurrentLevelPath") end)
    scene = tostring(scene or "")
    if scene == "" then return nil end
    return scene
end

local function get_all_conflict_blocked_flags()
    local blocked_flags = {}
    for scoop_name in each_conflict_scoop() do
        if not completed_scoops[scoop_name] then
            local blocked, _ = is_conflict_blocked(scoop_name)
            if blocked then
                local data = SCOOP_DATA[scoop_name]
                if data and data.flags then
                    for _, flag_id in ipairs(data.flags) do
                        if flag_id and flag_id ~= 0 then
                            blocked_flags[flag_id] = scoop_name
                        end
                    end
                end
            end
        end
    end
    return blocked_flags
end

-- Enforcement flag lists, shared by the legacy loops and the reconciler
-- policies. This is the only copy.
local ENDGAME_FLAGS = { 2052, 514 }
-- 265 (EV_EVENT08_00) is deliberately NOT enforced steady-state. It's a
-- main-event PHASE flag (naturally on in the prologue, one-shot at activation,
-- Hideout's secondary while active). Holding it on post-Jessie is a state
-- vanilla never sees and is the suspected (unproven) cause of the Twin Sisters
-- no-spawn -- keep it phase-managed only.
local POST_JESSIE_FLAGS = { 267, 315, 513, 515 }
local CULT_ON = { 326, 811, 1166, 2063 }
local CULT_OFF = {
    783,                                      -- scoop start flags
    4131, 738, 847, 875, 1173, 1294,          -- fight/kill flags
    2447, 2475, 335, 403, 3329, 1182,         -- post-kill flags
    462,                                      -- cult fight flag
}

-- Primary flags enforcement must not touch. while_active (optional) protects
-- only while that OTHER scoop is active (received + not completed).
-- 292: Isabela despawn; Santa Cabeza needs 292 AND 774, so leaving it is safe.
-- 272: game sets it during Backup for Brad's ending; don't touch until 2280
--      (Backup complete), then manage normally for A Temporary Agreement.
local PROTECTED_PRIMARY_FLAGS = {
    [292] = { scoop = "Santa Cabeza" },
    [272] = { scoop = "A Temporary Agreement", while_active = "Backup for Brad" },
}

local function is_protected_primary(flag_id, scoop_name)
    local entry = PROTECTED_PRIMARY_FLAGS[flag_id]
    if not entry then return false end
    if entry.scoop ~= scoop_name then return false end
    if entry.while_active then
        -- Only protected while the guarding scoop is active (received + not completed)
        return received_scoops[entry.while_active] == true
           and not completed_scoops[entry.while_active]
    end
    return true
end

local function is_in_completion_grace(scoop_name)
    local t = completion_times[scoop_name]
    return t ~= nil and (os.clock() - t < COMPLETION_GRACE_SECONDS)
end

local function enforce_blacklist()
    for flag_id, reason in pairs(FLAG_BLACKLIST) do
        -- Skip 300 while player is entering hideout (392 on, 355 not yet)
        if flag_id == 300 and raw_check_flag(392) and not raw_check_flag(355) then
        elseif raw_check_flag(flag_id) then
            if raw_set_flag_off(flag_id) then
                if verbose_logging then
                    M.log(string.format("Blacklist: disabled flag %d (%s)", flag_id, reason))
                end
            end
        end
    end
end

-- The legacy write loops. Authoritative while the reconciler runs in
-- shadow mode; deleted once shadow shows sustained agreement.
local function enforce_flags_legacy()
    -- Overtime: skip all enforcement except endgame flags + hideout 301 cutscene prevention
    if State.is_endgame_reached() then
        for _, fid in ipairs(ENDGAME_FLAGS) do
            if not raw_check_flag(fid) then
                currently_unlocking = true
                raw_set_flag_on(fid)
                currently_unlocking = false
                if verbose_logging then
                    M.log(string.format("Endgame: enforced flag %d", fid))
                end
            end
        end

        if get_current_area_index() == HIDEOUT_AREA_INDEX then
            if not raw_check_flag(301) then
                currently_unlocking = true
                raw_set_flag_on(301)
                currently_unlocking = false
                if verbose_logging then
                    M.log("Overtime: enabled flag 301 (player in Carlito's Hideout)")
                end
            end
        else
            if raw_check_flag(301) then
                raw_set_flag_off(301)
                if verbose_logging then
                    M.log("Overtime: disabled flag 301 (player left Carlito's Hideout)")
                end
            end
        end

        return
    end

    enforce_blacklist()

    -- Ensure post-Jessie flags stay enabled (267 = progression, 315 = queen spawning; 265 excluded -- see POST_JESSIE_FLAGS)
    if State.is_activated() then
        local post_jessie_flags = { table.unpack(POST_JESSIE_FLAGS) }
        -- Savior mode (without ScoopSanity): force flag 270 always-on so the
        -- EP-shutter cutscene plays naturally when the player walks into EP.
        -- Under ScoopSanity, use the position-gated single-fire path
        -- (try_fire_ep270_in_scoop_sanity) so the cutscene plays once and
        -- doesn't loop after CASCADE_FLAGS clears 270.
        if goal_mode == 2 and not scoop_sanity_enabled then
            table.insert(post_jessie_flags, 270)
        end
        for _, fid in ipairs(post_jessie_flags) do
            if not raw_check_flag(fid) then
                raw_set_flag_on(fid)
                if verbose_logging then
                    M.log(string.format("Enforced post-Jessie flag %d", fid))
                end
            end
        end
    end

    -- NOTE: Flag 276 (Entrance Plaza door / Rescue the Professor) management
    -- has been moved to on_frame() so it runs regardless of scoop_sanity_enabled.

    -- Toggle flag 355 based on area: ON in North Plaza, OFF in Carlito's Hideout.
    -- While Hideout is active (received + not completed), skip area toggling
    -- so the game can manage 355 on its own (it enables 355 for a cutscene).
    -- The one-time disable at unlock (disable_on_unlock) ensures 355 starts OFF.
    if State.is_activated() then
        local hideout_active = received_scoops["Hideout"]
                           and not completed_scoops["Hideout"]
        if not hideout_active then
            local area = get_current_area_index()
            if area == NORTH_PLAZA_AREA_INDEX then
                if not raw_check_flag(355) then
                    currently_unlocking = true
                    raw_set_flag_on(355)
                    currently_unlocking = false
                    if verbose_logging then
                        M.log("Area toggle: enabled flag 355 (player in North Plaza)")
                    end
                end
            elseif area == HIDEOUT_AREA_INDEX then
                if raw_check_flag(355) then
                    raw_set_flag_off(355)
                    if verbose_logging then
                        M.log("Area toggle: disabled flag 355 (player in Carlito's Hideout)")
                    end
                end
            end
        end
    end

    -- Simone will not follow unless 295 says Isabela is in the Security Room.
    -- Holding the cascade is not enough on its own: by the time the player
    -- walks up, the sweep has already cleared it. Set it while they are next
    -- to her, the same way flag 301 is handled in the Hideout.
    if State.is_activated() and player_is_with_simone() and not raw_check_flag(SIMONE_FLAG) then
        currently_unlocking = true
        raw_set_flag_on(SIMONE_FLAG)
        currently_unlocking = false
        if verbose_logging then
            M.log("Area toggle: enabled flag 295 (player with Simone Ravendark)")
        end
    end

    -- After "A Strange Group" is completed, keep the Raincoat cult spawning.
    -- Suppress completion/death flags but enforce the three cult-spawn flags.
    -- Flags auto-re-enabled by 326 (1222, 327, 1157, 3722, 1217, 1219, 1221, 1223, 3600)
    -- are left alone -- the game handles those.
    -- Cult Limited instead keeps them in Colby's outside the boss room.
    if completed_scoops["A Strange Group"] then
        if M.is_cult_limited_enabled() then
            -- Cult Limited: keep cultists in Colby's (s503) by clearing the
            -- spawn flag everywhere else -- keyed on scene, not area, since
            -- door-rando can reroute the theater exit.
            local scene = get_current_scene()
            if scene and not scene:find("s503") and raw_check_flag(2063) then
                raw_set_flag_off(2063)
                if verbose_logging then
                    M.log("Cult Limited: cleared flag 2063 outside Colby's (" .. scene .. ")")
                end
            end
        else
            for _, fid in ipairs(CULT_ON) do
                if not raw_check_flag(fid) then
                    currently_unlocking = true
                    raw_set_flag_on(fid)
                    currently_unlocking = false
                    if verbose_logging then
                        M.log(string.format("Cult respawn: enabled flag %d", fid))
                    end
                end
            end
            for _, fid in ipairs(CULT_OFF) do
                if raw_check_flag(fid) then
                    raw_set_flag_off(fid)
                    if verbose_logging then
                        M.log(string.format("Cult respawn: suppressed flag %d", fid))
                    end
                end
            end
        end
    end

    if door_randomizer_enabled and not raw_check_flag(514) then
        currently_unlocking = true
        raw_set_flag_on(514)
        currently_unlocking = false
        if verbose_logging then
            M.log("DoorRandomizer: re-enabled flag 514")
        end
    end

    if not State.is_activated() then
        for flag_id, scoop_name in pairs(ALL_SIDE_SCOOP_FLAGS) do
            if raw_check_flag(flag_id) then
                if raw_set_flag_off(flag_id) then
                    if verbose_logging then
                        M.log(string.format("Pre-activation: suppressed flag %d ('%s')",
                            flag_id, scoop_name))
                    end
                end
            end
        end
        return
    end

    for flag_id, _ in pairs(pending_suppress) do
        local scoop_name = CONTROLLED_FLAGS[flag_id]
        if scoop_name and is_protected_primary(flag_id, scoop_name) then
            if verbose_logging then
                M.log(string.format("Protected primary flag %d (%s) -- skipping suppression",
                    flag_id, scoop_name))
            end
        elseif scoop_name and is_in_completion_grace(scoop_name) then
            if verbose_logging then
                M.log(string.format("Grace period: skipping flag %d (%s)", flag_id, scoop_name))
            end
        elseif raw_check_flag(flag_id) then
            raw_set_flag_off(flag_id)
            if verbose_logging then
                M.log(string.format("Suppressed hook-flagged flag %d (%s)",
                    flag_id, scoop_name or "?"))
            end
        end
    end
    pending_suppress = {}

    -- Controlled flags: ON if scoop received + not completed, OFF otherwise
    local disabled_count = 0
    for flag_id, scoop_name in pairs(CONTROLLED_FLAGS) do
        local should_be_on = (received_scoops[scoop_name] == true)
                         and (not completed_scoops[scoop_name])

        if is_protected_primary(flag_id, scoop_name) then
            -- Leave this flag entirely alone; the game manages it.
        elseif should_be_on then
            if not raw_check_flag(flag_id) then
                currently_unlocking = true
                raw_set_flag_on(flag_id)
                currently_unlocking = false
                if verbose_logging then
                    M.log(string.format("Re-enabled controlled flag %d for active '%s'",
                        flag_id, scoop_name))
                end
            end
        else
            if not is_in_completion_grace(scoop_name)
               and raw_check_flag(flag_id) then
                raw_set_flag_off(flag_id)
                disabled_count = disabled_count + 1
                if verbose_logging then
                    M.log(string.format("Disabled controlled flag %d (%s)", flag_id, scoop_name))
                end
            end
        end
    end

    if disabled_count > 0 and not verbose_logging then
        M.log(string.format("Disabled %d controlled flags", disabled_count))
    end

    -- Cascade: clear byproduct flags for inactive missions
    local cascade_count = 0
    local cascade_details = {}
    for flag_id, owner_scoop in pairs(CASCADE_FLAGS) do
        local mission_active = received_scoops[owner_scoop] and not completed_scoops[owner_scoop]
        -- 295 is Santa Cabeza's byproduct but also what Simone checks, so it
        -- stays on while the player is next to her (see SIMONE_BOX).
        local held = (flag_id == SIMONE_FLAG) and player_is_with_simone()
        if not mission_active and not held
            and not is_in_completion_grace(owner_scoop) and raw_check_flag(flag_id) then
            raw_set_flag_off(flag_id)
            cascade_count = cascade_count + 1
            table.insert(cascade_details, string.format("%d(%s)", flag_id, owner_scoop))
            if verbose_logging then
                M.log(string.format("Cascade: cleared flag %d (%s)", flag_id, owner_scoop))
            end
        end
    end
    if cascade_count > 0 and not verbose_logging then
        -- Dedup: only log when the set of cleared flags changes. Otherwise
        -- the Post-Jessie flag 270 oscillation in Savior mode spams the
        -- log every frame.
        table.sort(cascade_details)
        local sig = table.concat(cascade_details, ",")
        if sig ~= _last_cascade_signature then
            M.log(string.format("Cascade: cleared %d flags: %s",
                cascade_count, table.concat(cascade_details, ", ")))
            _last_cascade_signature = sig
        end
    elseif cascade_count == 0 then
        _last_cascade_signature = nil   -- reset so a future clearing re-logs
    end

    -- disable_flags for all active scoops (Main, Psychopath, etc.)
    for scoop_name, _ in pairs(received_scoops) do
        if not completed_scoops[scoop_name] then
            local data = SCOOP_DATA[scoop_name]
            if data and data.disable_flags then
                for _, flag_id in ipairs(data.disable_flags) do
                    if raw_check_flag(flag_id) then
                        raw_set_flag_off(flag_id)
                        if verbose_logging then
                            M.log(string.format("Disable_flag: turned off %d for active '%s'",
                                flag_id, scoop_name))
                        end
                    end
                end
            end
        end
    end

    local conflict_blocked = get_all_conflict_blocked_flags()
    for flag_id, scoop_name in pairs(conflict_blocked) do
        if raw_check_flag(flag_id) then
            if raw_set_flag_off(flag_id) then
                if verbose_logging then
                    M.log(string.format("Conflict suppressed flag %d ('%s' blocked by group)",
                        flag_id, scoop_name))
                end
            end
        end
    end

    -- Suppress side scoops blocked by an active main scoop (crash prevention)
    for _, side_list in pairs(MAIN_BLOCKS_SIDE) do
      for _, side_name in ipairs(side_list) do
        local blocked, active_blocker = State.is_blocked_by_active_main(side_name)
        if blocked then
            local data = SCOOP_DATA[side_name]
            if data and data.flags then
                for _, flag_id in ipairs(data.flags) do
                    if flag_id and flag_id ~= 0 and raw_check_flag(flag_id) then
                        raw_set_flag_off(flag_id)
                        if verbose_logging then
                            M.log(string.format("Main-blocked: suppressed flag %d ('%s' blocked by active '%s')",
                                flag_id, side_name, active_blocker))
                        end
                    end
                end
            end
        end
      end
    end

    -- Re-enable flags for active side scoops
    for scoop_name, _ in pairs(received_scoops) do
        if not completed_scoops[scoop_name] then
            local data = SCOOP_DATA[scoop_name]
            if data and data.category ~= "Main" and data.flags then
                local blocked = is_conflict_blocked(scoop_name) or is_blocked_by_active_main(scoop_name) or not has_prerequisites_met(scoop_name)
                if not blocked then
                    for _, flag_id in ipairs(data.flags) do
                        if flag_id and flag_id ~= 0 then
                            if not raw_check_flag(flag_id) then
                                currently_unlocking = true
                                if raw_set_flag_on(flag_id) then
                                    if verbose_logging then
                                        M.log(string.format("Re-enabled flag %d for active '%s'",
                                            flag_id, scoop_name))
                                    end
                                end
                                currently_unlocking = false
                            end
                        end
                    end
                end
            end
        end
    end

end

------------------------------------------------------------
-- Flag reconciler. Policies declare desired flag state; the reconciler
-- resolves claims by priority and (in active mode) writes the diff. In
-- shadow mode the legacy loops stay authoritative and it just logs any
-- divergence ("SHADOW DIVERGENCE" lines).
------------------------------------------------------------

-- Default active. The earlier cutover's twins-no-spawn was root-caused to
-- holding 265 on during activation (engine marks the scoop active without
-- creating the survivor's NpcBaseInfo, persisted); 265 is no longer
-- steady-state enforced. drap_reconciler("shadow") reverts live.
local reconciler_mode = "active"   -- off | shadow | active
local reconciler_policies = nil
local last_reconciler_stats = nil

local reconciler_io = {
    read = raw_check_flag,
    set = function(fid, on, shielded)
        if shielded then currently_unlocking = true end
        if on then raw_set_flag_on(fid) else raw_set_flag_off(fid) end
        if shielded then currently_unlocking = false end
    end,
}

local function get_reconciler_policies()
    if not reconciler_policies then
        reconciler_policies = FlagPolicies.build({
            scoop_data = SCOOP_DATA,
            controlled_flags = CONTROLLED_FLAGS,
            cascade_flags = CASCADE_FLAGS,
            all_side_scoop_flags = ALL_SIDE_SCOOP_FLAGS,
            blacklist = FLAG_BLACKLIST,
            protected_primary_flags = PROTECTED_PRIMARY_FLAGS,
            main_blocks_side = MAIN_BLOCKS_SIDE,
            post_jessie_flags = POST_JESSIE_FLAGS,
            cult_on = CULT_ON,
            cult_off = CULT_OFF,
            endgame_flags = ENDGAME_FLAGS,
        })
    end
    return reconciler_policies
end

-- Reconciler findings go to the console + re2_framework_log.txt (M.log)
-- AND into the flag-trace JSONL, where the offline analyzer sees them
-- alongside the flag transitions that caused them.
local function reconciler_log(msg)
    M.log(msg)
    local rec = _G.AP and _G.AP.FlagTraceRecorder
    if rec and rec.note then pcall(rec.note, msg) end
end

local function build_reconciler_ctx()
    return {
        activated = State.is_activated(),
        endgame = State.is_endgame_reached(),
        scoop_sanity = scoop_sanity_enabled,
        cult_limited = cult_limited_enabled,
        scene = get_current_scene(),   -- for the Cult Limited policy
        goal_mode = goal_mode,
        door_randomizer = door_randomizer_enabled,
        area = get_current_area_index(),
        hideout_area = HIDEOUT_AREA_INDEX,
        north_plaza_area = NORTH_PLAZA_AREA_INDEX,
        check_flag = raw_check_flag,
        in_grace = is_in_completion_grace,
        is_active = State.is_active,
        is_completed = State.is_completed,
        is_conflict_blocked = State.is_conflict_blocked,
        is_blocked_by_active_main = State.is_blocked_by_active_main,
        has_prerequisites_met = State.has_prerequisites_met,
        chain_disp_flag = (function()
            local cur = State.get_current_chain_scoop()
            local data = cur and SCOOP_DATA[cur]
            return data and data.disp_flag or nil
        end)(),
    }
end

local function enforce_flags()
    if not enforcement_enabled then return end
    if not scoop_sanity_enabled then return end

    local now = os.clock()
    if now - last_enforcement_time < ENFORCEMENT_COOLDOWN then return end
    last_enforcement_time = now

    if reconciler_mode == "active" then
        -- The controlled-off claims subsume hook-flagged suppression;
        -- drop the queue so it can't grow unbounded.
        pending_suppress = {}
        last_reconciler_stats = Reconciler.tick(
            get_reconciler_policies(), build_reconciler_ctx(),
            reconciler_io, "active", reconciler_log)
        return
    end

    enforce_flags_legacy()

    if reconciler_mode == "shadow" then
        last_reconciler_stats = Reconciler.tick(
            get_reconciler_policies(), build_reconciler_ctx(),
            reconciler_io, "shadow", reconciler_log)
    end
end

function M.set_reconciler_mode(mode)
    if mode ~= "off" and mode ~= "shadow" and mode ~= "active" then
        M.log("Reconciler mode must be off | shadow | active")
        return false
    end
    reconciler_mode = mode
    Reconciler.reset_log_dedup()
    M.log("Reconciler mode: " .. mode)
    return true
end

function M.get_reconciler_mode() return reconciler_mode end
function M.get_reconciler_stats() return last_reconciler_stats end

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

                if currently_unlocking then return args end

                if FLAG_BLACKLIST[flag_id] then
                    if verbose_logging then
                        M.log(string.format("Blacklist: blocked flag %d in hook", flag_id))
                    end
                end

                local completion = COMPLETION_FLAGS[flag_id]
                if completion and not completed_scoops[completion.scoop] then
                    -- ScoopSanity guard: a main scoop counts as completed only
                    -- once its AP item is received AND the mission is finished.
                    -- Suppress the check when the item isn't received yet --
                    -- e.g. the position-gated EP-shutter trigger plays the
                    -- cutscene early and fires 2308 before Backup for Brad has
                    -- arrived. We don't mark _logged_completion_events, so the
                    -- legitimate completion can still fire later.
                    local ss_block = scoop_sanity_enabled
                                  and completion.scoop
                                  and SCOOP_DATA[completion.scoop]
                                  and SCOOP_DATA[completion.scoop].category == "Main"
                                  and not received_scoops[completion.scoop]
                    if ss_block then
                        if verbose_logging then
                            M.log(string.format(
                                "ScoopSanity guard: flag %d -> '%s' suppressed ('%s' not yet received as AP item)",
                                flag_id, completion.event, completion.scoop))
                        end
                        -- Clear next frame, not here: the engine's evFlagOn
                        -- body runs after we return and would re-set the flag.
                        -- Clearing later restores the off->on transition for
                        -- the legitimate completion.
                        pending_flag_clears[flag_id] = true
                    elseif not _logged_completion_events[completion.event] then
                        -- Dedup once per event per session: the engine re-asserts
                        -- event-only flags every frame, which would otherwise
                        -- spam the log and resend the (idempotent) AP check.
                        _logged_completion_events[completion.event] = true
                        M.log(string.format("COMPLETION: Flag %d -> '%s'",
                            flag_id, completion.event))
                        if completion.scoop then
                            M.complete_scoop(completion.scoop)
                        end
                        if on_completion_detected_callback then
                            pcall(on_completion_detected_callback,
                                completion.event, flag_id, completion.scoop)
                        end
                    end
                end

                -- ScoopSanity-only: flag triggers, time skips, and controlled flag suppression
                if scoop_sanity_enabled then
                    local trigger = FLAG_TRIGGERS[flag_id]
                    if trigger then
                        if trigger.enable then
                            for _, target in ipairs(trigger.enable) do
                                raw_set_flag_on(target)
                                M.log(string.format("Trigger: flag %d -> enabled %d", flag_id, target))
                            end
                        end
                        if trigger.disable then
                            for _, target in ipairs(trigger.disable) do
                                raw_set_flag_off(target)
                                M.log(string.format("Trigger: flag %d -> disabled %d", flag_id, target))
                            end
                        end
                    end

                    local skip = TIME_SKIP_TRIGGERS[flag_id]
                    if skip and not time_skips_fired[flag_id] and not active_time_skip then
                        time_skips_fired[flag_id] = true
                        active_time_skip = {
                            flag = flag_id,
                            target_mdate = skip.target_mdate,
                            name = skip.name,
                        }
                        M.log(string.format("Time skip activated: flag %d -> advance to %d (%s)",
                            flag_id, skip.target_mdate, skip.name))
                    end

                    if CONTROLLED_FLAGS[flag_id] then
                        local scoop_name = CONTROLLED_FLAGS[flag_id]
                        if is_protected_primary(flag_id, scoop_name) then
                            if verbose_logging then
                                M.log(string.format("Hook: allowing protected primary %d (%s)",
                                    flag_id, scoop_name))
                            end
                        elseif is_in_completion_grace(scoop_name) then
                            if verbose_logging then
                                M.log(string.format("Hook: grace period for flag %d (%s)",
                                    flag_id, scoop_name))
                            end
                        else
                            pending_suppress[flag_id] = true
                            if verbose_logging then
                                M.log(string.format("Hook: flagging controlled flag %d (%s) for suppression",
                                    flag_id, scoop_name))
                            end
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

local function get_chain_position(scoop_name)
    return State.get_chain_position(scoop_name)
end

local function activate_ap(reason)
    if State.is_activated() then return false end
    State.set_activated(true)
    M.log(reason or "AP enforcement activated")
    -- Enable flags needed after Meet Jessie
    local post_jessie_flags = { 265, 267, 315, 514 }
    -- Savior mode (without ScoopSanity): fire flag 270 immediately so the
    -- EP-shutter cutscene plays naturally on EP entry. Under ScoopSanity,
    -- the position-gated path (try_fire_ep270_in_scoop_sanity) handles it
    -- so it fires once and doesn't loop after the cascade clears the flag.
    if goal_mode == 2 and not scoop_sanity_enabled then
        table.insert(post_jessie_flags, 270)
    end
    for _, fid in ipairs(post_jessie_flags) do
        if not raw_check_flag(fid) then
            raw_set_flag_on(fid)
            M.log(string.format("Post-Jessie: enabled flag %d", fid))
        end
    end
    State.on_activated()
    if on_ap_activated_callback then pcall(on_ap_activated_callback) end
    -- If the player is already standing in a fixup-eligible scene (e.g. s136
    -- when Jessie is met), apply now since onLoadMapEvent won't fire again.
    if _G.AP and _G.AP.SceneFixups and _G.AP.SceneFixups.apply_for_current_scene then
        pcall(_G.AP.SceneFixups.apply_for_current_scene)
    end
    save_state()
    return true
end

local function process_milestone(event_desc)
    local milestone = MILESTONE_EVENTS[event_desc]
    if not milestone then return false end

    if milestone == "activate" and scoop_sanity_enabled then
        return activate_ap("MILESTONE: AP enforcement activated (Meet Jessie)")

    elseif milestone == "time_freeze" and scoop_sanity_enabled and not State.is_time_frozen() then
        State.set_time_frozen(true)
        M.log("MILESTONE: Time freeze triggered (ScoopSanity)")

        if on_time_freeze_callback then
            pcall(on_time_freeze_callback)
        end
        save_state()
        return true
    end

    return false
end

-- Engine-side effects of a scoop unlock: disable lists, the Backup for
-- Brad EP-shutter reset, then the mission flags themselves. Runs as
-- State's on_unlock callback -- all eligibility/deferral decisions are
-- made in ScoopState.request_unlock before this fires.
local function apply_unlock_writes(scoop_name, scoop)
    currently_unlocking = true

    -- disable_flags BEFORE enabling mission flags -- prevents stale flags from
    -- triggering immediate completion (e.g. 292 left over from Santa Cabeza).
    -- disable_on_unlock is the same but only fires here (not in the enforcement
    -- loop), so the game can re-enable the flag later (e.g. 355 for Hideout cutscene).
    for _, list in ipairs({ scoop.disable_flags, scoop.disable_on_unlock }) do
        if list then
            for _, flag_id in ipairs(list) do
                if raw_check_flag(flag_id) then
                    raw_set_flag_off(flag_id)
                    M.log(string.format("Disabled conflicting flag %d for '%s'", flag_id, scoop_name))
                end
            end
        end
    end

    -- Backup for Brad: conditional EP-shutter reset. A pre-fired 270 (with
    -- 765/2280 set) leaves the shutters open, so the natural flow can't replay
    -- the cutscene and COMPLETION_FLAGS[270] never fires -- clear all three so
    -- the mission runs vanilla-style. BUT skip if any later main already
    -- completed (Backup is vanilla's first): the open shutters are now
    -- post-progression state and re-closing them breaks late-game traversal.
    if scoop_name == "Backup for Brad" then
        local blocker = find_completed_main_scoop()
        if blocker then
            M.log(string.format("Backup for Brad: skipping EP-shutter reset (later main scoop '%s' already completed)",
                blocker))
        else
            for _, fid in ipairs({ 270, 765, 2280 }) do
                if raw_check_flag(fid) then
                    raw_set_flag_off(fid)
                    M.log(string.format("Cleared EP-shutter flag %d for Backup for Brad unlock", fid))
                end
            end
        end
    end

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
        M.log(string.format("Unlocked MAIN '%s' (%d flags, primary=%d)",
            scoop_name, count, scoop.primary_flag or 0))

        -- On-screen mission announcement via DRAP toast. The engine's own
        -- case box can't be retargeted safely -- its levers (scenario start
        -- flags, including NPC-killer 300 for case 8) carry world side effects
        -- -- so the box may still show the vanilla case; this names the real
        -- current mission.
        local notify = _G.AP and _G.AP.Notify
        if notify and notify.info then
            local desc = SCOOP_DESCRIPTIONS[scoop_name]
            local where = desc and desc.location and (" -- " .. desc.location) or ""
            pcall(notify.info, "Current Mission: " .. scoop_name .. where,
                { channel = "drap_mission" })
        end
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
end

-- Wire the pure state machine to this module's engine adapters. Must run
-- after the locals it captures (raw_check_flag,
-- apply_unlock_writes, save_state) are defined.
-- Scoop -> the area codes it needs reachable, from drdr_shared.json's
-- required_regions. Region names are mapped through the areas table so the
-- rules and the mod stay keyed on the same list.
-- Scoop -> the split keys its route needs, from drdr_shared.json. Only
-- consulted when Split Keys is on; the other modes have no such items.
local function build_split_key_doors()
    local out, n = {}, 0
    for _, scoop in ipairs(SharedData.scoops()) do
        local keys = scoop.required_split_keys
        if scoop.name and keys and #keys > 0 then
            out[scoop.name] = keys
            n = n + 1
        end
    end
    M.log(string.format("Split-key routes loaded for %d scoop(s)", n))
    return out
end

local function build_region_requirements()
    local code_for = {}
    for _, area in ipairs(SharedData.areas()) do
        if area.name and area.scene_code then
            code_for[area.name] = area.scene_code
        end
    end
    local out, n = {}, 0
    for _, scoop in ipairs(SharedData.scoops()) do
        local regions = scoop.required_regions
        if scoop.name and regions and #regions > 0 then
            local codes = {}
            for _, region in ipairs(regions) do
                local code = code_for[region]
                if code then
                    codes[#codes + 1] = code
                else
                    M.log(string.format(
                        "region requirement '%s' for '%s' has no area code",
                        tostring(region), tostring(scoop.name)))
                end
            end
            if #codes > 0 then
                out[scoop.name] = codes
                n = n + 1
            end
        end
    end
    M.log(string.format("Region requirements loaded for %d scoop(s)", n))
    return out
end

State.init({
    scoop_data = SCOOP_DATA,
    conflict_groups = CONFLICT_GROUPS,
    main_blocks_side = MAIN_BLOCKS_SIDE,
    prerequisites = SCOOP_PREREQUISITES,
    flag_prerequisites = SCOOP_FLAG_PREREQUISITES,
    flag_prereq_bypass = { ["Mark of the Sniper"] = "any_main_completed" },
    -- Hideout used to wait on "Carlito's Hideout Key" by name, which does not
    -- exist under Split Keys. Its required_regions already include Carlito's
    -- Hideout, and reaching that asks the right question in every mode.
    item_requirements = {},
    chain_final = "The Facts",
    log = M.log,
    now = os.clock,
    check_flag = raw_check_flag,
    has_item = function(item_name)
        local bridge = AP and AP.AP_BRIDGE
        return (bridge and bridge.has_item_name and bridge.has_item_name(item_name)) == true
    end,
    on_unlock = apply_unlock_writes,
    on_state_changed = function() save_state() end,
    region_requirements = build_region_requirements(),
    split_key_doors = build_split_key_doors(),
    can_reach_area = function(code)
        local dsl = AP and AP.DoorSceneLock
        -- No lock module means no locks to respect; never hold a
        -- scoop back on a question we cannot answer.
        if not (dsl and dsl.can_reach_area) then return true end
        return dsl.can_reach_area(code)
    end,
})


-- World-stability gate: unlock flag-writes must never land during load
-- screens, the title screen, or just after a load. An item replaying on
-- reconnect into a half-loaded world makes the engine mark the scoop active
-- WITHOUT creating the survivor's NpcBaseInfo, permanently unspawnable
-- (sweeper: 'MISSING record'). Unstable-window unlocks park here and drain
-- after WORLD_STABLE_SECONDS of stable gameplay.
local WORLD_STABLE_SECONDS = 2.0
local world_stable_since = nil
local pending_world_unlocks = {}
local pending_world_reapply = false

local function world_stable()
    return world_stable_since ~= nil
        and (os.clock() - world_stable_since) >= WORLD_STABLE_SECONDS
end

function M.unlock_scoop(scoop_name)
    if not world_stable() then
        pending_world_unlocks[scoop_name] = true
        M.log(string.format(
            "World not stable -- parking unlock of '%s' until gameplay settles",
            scoop_name))
        return false, "world"
    end
    return State.request_unlock(scoop_name)
end

local function update_world_stability()
    if is_player_session() and Shared.is_in_game() then
        world_stable_since = world_stable_since or os.clock()
    else
        world_stable_since = nil
        return
    end
    if not world_stable() then return end

    if pending_world_reapply then
        pending_world_reapply = false
        M.log("World stable -- running parked reapply")
        State.reapply()
    end
    if next(pending_world_unlocks) then
        local names = {}
        for n in pairs(pending_world_unlocks) do table.insert(names, n) end
        table.sort(names)
        pending_world_unlocks = {}
        for _, n in ipairs(names) do
            M.log(string.format("World stable -- applying parked unlock '%s'", n))
            State.request_unlock(n)
        end
    end
end

function M.complete_scoop(scoop_name)
    -- Chain advance, conflict-group advance, blocked-side retries, and
    -- persistence all happen inside the state machine.
    return State.complete(scoop_name)
end

local ENDGAME_EVENTS = {
    ["Get bit!"] = true,
    ["Ending A: Solve all of the cases and be on the helipad at 12pm"] = true,
}

function M.on_event_tracked(event_desc)
    process_milestone(event_desc)

    if ENDGAME_EVENTS[event_desc] and not State.is_endgame_reached() then
        State.set_endgame_reached(true)
        M.log(string.format("Endgame reached: '%s' -- enforcing flags 2052, 514", event_desc))
        save_state()
    end

    local scoop_name = COMPLETION_EVENT_TO_SCOOP[event_desc]
    if scoop_name then
        M.complete_scoop(scoop_name)
        return true
    end
    return false
end

function M.reapply_unlocked_scoops()
    if not world_stable() then
        pending_world_reapply = true
        M.log("World not stable -- reapply parked until gameplay settles")
        return
    end
    State.reapply()
end

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
        local blocked, blocker = is_conflict_blocked(name)
        local main_blocked, main_blocker = is_blocked_by_active_main(name)
        local conflict_info = State.conflict_info(name)
        table.insert(status, {
            name = name,
            flags_active = M.is_scoop_active(name),
            received = M.has_received_scoop(name),
            ap_item_received = ap_received[name] == true,
            completed = M.is_scoop_completed(name),
            conflict_blocked = blocked,
            conflict_blocker = blocker,
            main_blocked = main_blocked,
            main_blocker = main_blocker,
            conflict_group = conflict_info and conflict_info.group or nil,
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

local EVENT_ITEM_NAMES = nil

local function build_event_item_set()
    EVENT_ITEM_NAMES = {}
    for scoop_name, _ in pairs(SCOOP_DATA) do
        EVENT_ITEM_NAMES[scoop_name] = true
    end
    for event_name, _ in pairs(MILESTONE_EVENTS) do
        EVENT_ITEM_NAMES[event_name] = true
    end
end

function M.is_event_item(name)
    if not name then return false end
    if not EVENT_ITEM_NAMES then build_event_item_set() end
    return EVENT_ITEM_NAMES[name] == true
end

function M.get_completion_flags()
    local result = {}
    for flag_id, data in pairs(COMPLETION_FLAGS) do
        table.insert(result, { flag_id = flag_id, event = data.event, scoop = data.scoop })
    end
    table.sort(result, function(a, b) return a.flag_id < b.flag_id end)
    return result
end

function M.reset_all()
    time_skips_fired = {}
    active_time_skip = nil
    State.reset_all()
end

local NEW_GAME_FLAGS = { 263, 264 }

-- Returns true/false when every flag read is CONFIRMED, nil when any read
-- failed. Callers must treat nil as "ask again later" -- answering "new
-- game" off unreadable flags would wipe side-scoop progress spuriously.
function M.is_new_game()
    local efm = efm_mgr:get()
    if not efm then return nil end

    for _, flag_id in ipairs(NEW_GAME_FLAGS) do
        local v = raw_check_flag(flag_id)
        if v == nil then return nil end
        if v == true then return false end
    end
    return true
end

function M.reset_for_new_game()
    time_skips_fired = {}
    active_time_skip = nil

    -- Reset log-spam dedup state so a fresh run logs anew.
    _last_cascade_signature = nil
    _logged_completion_events = {}

    State.reset_for_new_game()
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

function M.unlock_all()
    local count = M.unlock_category("Main")
    for name, data in pairs(SCOOP_DATA) do
        if data.category ~= "Main" then
            M.unlock_scoop(name)
            count = count + 1
        end
    end
    M.log(string.format("Unlocked ALL %d scoops", count))
    return count
end

function M.generate_random_test_order()
    M.reset_all()
    local mains = {}
    for name, data in pairs(SCOOP_DATA) do
        if data.category == "Main" and name ~= "The Facts" then
            table.insert(mains, name)
        end
    end

    math.randomseed(os.clock() * 1000 + os.time())
    for i = #mains, 2, -1 do
        local j = math.random(1, i)
        mains[i], mains[j] = mains[j], mains[i]
    end

    M.set_scoop_order(mains)
    for _, name in ipairs(mains) do
        State.mark_ap_received(name)
    end

    M.log(string.format("Random test order generated: %d main scoops shuffled -- waiting for milestones", #mains))
end

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
    enforce_flags()
end

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

function M.add_trigger(trigger_flag, enable_flags, disable_flags)
    FLAG_TRIGGERS[trigger_flag] = {
        enable = enable_flags,
        disable = disable_flags,
    }
    M.log(string.format("Added trigger: flag %d -> enable %s, disable %s",
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

function M.set_completion_callback(callback)
    on_completion_detected_callback = callback
    M.log("Completion callback " .. (callback and "SET" or "CLEARED"))
end

function M.set_scoop_order(order_list)
    return State.set_scoop_order(order_list)
end

function M.get_scoop_order()
    return scoop_order
end

function M.is_scoop_order_set()
    return State.is_scoop_order_set()
end

function M.get_current_chain_index()
    return State.get_current_chain_index()
end

function M.get_current_chain_scoop()
    return State.get_current_chain_scoop()
end

function M.is_ap_activated()
    return State.is_activated()
end

function M.is_time_frozen()
    return State.is_time_frozen()
end

function M.set_scoop_sanity_enabled(enabled)
    scoop_sanity_enabled = enabled
    M.log("ScoopSanity " .. (enabled and "ENABLED" or "DISABLED"))
    -- MissionTruth drives the mission box only under ScoopSanity.
    local ok, MissionTruth = pcall(require, "DRAP/effects/MissionTruth")
    if ok and MissionTruth then
        pcall(MissionTruth.set_enabled, enabled)
    end
end

function M.is_scoop_sanity_enabled()
    return scoop_sanity_enabled
end

-- Any Order: the chain stops auto-advancing and the player starts main
-- scoops from the GUI instead. State owns the rules; this just forwards.
function M.set_split_keys_enabled(enabled)
    State.set_split_keys(enabled == true)
    M.log("Split key routes " .. (enabled and "ENFORCED" or "off"))
end

function M.set_any_order_enabled(enabled)
    State.set_any_order(enabled == true)
    M.log("Main scoops in any order " .. (enabled and "ENABLED" or "DISABLED"))
end

function M.main_scoop_menu()
    return State.main_scoop_menu()
end

function M.activate_main_scoop(name)
    return State.activate_main_scoop(name)
end

function M.set_cult_limited_enabled(enabled)
    cult_limited_enabled = enabled
    M.log("Cultists " .. (enabled and "ENABLED" or "DISABLED"))
end

function M.is_cult_limited_enabled()
    return cult_limited_enabled
end

function M.set_goal_mode(goal)
    goal_mode = tonumber(goal) or 0
    local names = { [0] = "Ending S", [1] = "Ending A", [2] = "Savior" }
    M.log("Goal mode: " .. (names[goal_mode] or tostring(goal_mode)))
end

function M.set_door_randomizer_enabled(enabled)
    door_randomizer_enabled = enabled
    M.log("DoorRandomizer " .. (enabled and "ENABLED" or "DISABLED"))
    if enabled then
        currently_unlocking = true
        raw_set_flag_on(514)
        currently_unlocking = false
        M.log("DoorRandomizer: set flag 514 for door softlock prevention")
    end
end

function M.set_ap_activated_callback(callback)
    on_ap_activated_callback = callback
    M.log("AP activated callback " .. (callback and "SET" or "CLEARED"))
end

function M.set_time_freeze_callback(callback)
    on_time_freeze_callback = callback
    M.log("Time freeze callback " .. (callback and "SET" or "CLEARED"))
end

function M.set_time_unfreeze_callback(callback)
    on_time_unfreeze_callback = callback
    M.log("Time unfreeze callback " .. (callback and "SET" or "CLEARED"))
end

function M.force_activate()
    activate_ap("FORCED: AP enforcement activated")
end

function M.set_save_filename(slot, seed)
    -- Sanitized: reserved characters in slot/seed made json.dump_file fail
    -- silently, resetting progress every session.
    save_filename = string.format("./AP_DRDR_Scoops/DRAP_scoops_%s_%s.json",
        Shared.sanitize_token(slot or "unknown"),
        Shared.sanitize_token(seed or "unknown"))
    M.log("Save filename: " .. save_filename)
end

function M.load_save()
    return load_state()
end

function M.save()
    return save_state()
end

function M.register_with_ap_bridge(ap_bridge)
    if not ap_bridge or not ap_bridge.register_item_handler_by_name then
        M.log("ERROR: Invalid AP bridge")
        return 0
    end

    local count = 0
    for scoop_name, data in pairs(SCOOP_DATA) do
        ap_bridge.register_item_handler_by_name(scoop_name, function(net_item, item_name, sender_name)
            M.log(string.format("Received scoop '%s' from %s", tostring(item_name), tostring(sender_name or "?")))

            State.mark_ap_received(scoop_name)
            save_state()

            if data.category == "Main" and State.is_scoop_order_set() then
                State.try_advance_chain()
            else
                M.unlock_scoop(scoop_name)
            end
        end)
        count = count + 1
    end

    M.log(string.format("Registered %d scoop handlers with AP bridge", count))
    return count
end

local filter_category = "All"
local show_only_received = false
local hide_completed = false

local CATEGORY_COLORS = {
    Main = 0xFFFFFF00,
    Survivor = 0xFF66FF66,
    Psychopath = 0xFFFF6666,
}

function M.draw_tab_content(debug)
    if debug then
        local efm = efm_mgr:get()
        imgui.text_colored(efm and "EFM: OK" or "EFM: N/A", efm and 0xFF00FF00 or 0xFFFF0000)
        imgui.same_line()
        imgui.text_colored(hooks_installed and "Hook: ON" or "Hook: OFF", hooks_installed and 0xFF00FF00 or 0xFFFF0000)
        imgui.same_line()
        imgui.text_colored(enforcement_enabled and "Enforce: ON" or "Enforce: OFF",
            enforcement_enabled and 0xFF00FF00 or 0xFFFFFF00)
        imgui.same_line()
        local gui_activated = State.is_activated()
        imgui.text_colored(gui_activated and "AP: ACTIVE" or "AP: WAITING",
            gui_activated and 0xFF00FF00 or 0xFFFF8800)
        imgui.same_line()
        local gui_frozen = State.is_time_frozen()
        imgui.text_colored(gui_frozen and "Time: FROZEN" or "Time: NORMAL",
            gui_frozen and 0xFF88CCFF or 0xFFAAAAAA)
        imgui.same_line()
        if imgui.button(scoop_sanity_enabled and "ScoopSanity: ON" or "ScoopSanity: OFF") then
            M.set_scoop_sanity_enabled(not scoop_sanity_enabled)
        end
        imgui.same_line()
        local rec_stats = last_reconciler_stats
        local rec_str = "Rec: " .. reconciler_mode
        if rec_stats and rec_stats.mismatches then
            rec_str = rec_str .. string.format(" (%d div)", rec_stats.mismatches)
        end
        local rec_color = 0xFFAAAAAA
        if reconciler_mode == "shadow" then
            rec_color = (rec_stats and rec_stats.mismatches and rec_stats.mismatches > 0)
                and 0xFF0088FF or 0xFF00FF00
        elseif reconciler_mode == "active" then
            rec_color = 0xFF00FFFF
        end
        imgui.text_colored(rec_str, rec_color)
        if active_time_skip then
            imgui.text_colored(string.format("TIME SKIP: %s -> %d",
                active_time_skip.name, active_time_skip.target_mdate), 0xFF00FFFF)
        end

        imgui.text(string.format("Recv: %d | Done: %d | Blacklist: %d | Triggers: %d",
            count_keys(received_scoops), count_keys(completed_scoops),
            count_keys(FLAG_BLACKLIST), count_keys(FLAG_TRIGGERS)))
    end

    if State.is_scoop_order_set() and #scoop_order > 0 then
        local current_chain_name = M.get_current_chain_scoop()

        if current_chain_name then
            local info = SCOOP_DESCRIPTIONS[current_chain_name]
            imgui.text_colored("Current Quest: " .. current_chain_name, 0xFF00FF00)
            if info then
                imgui.text_colored("  Location:    " .. info.location, 0xFFFFFF00)
                imgui.text_colored("  Trigger:     " .. info.trigger, 0xFFFFFF00)
                imgui.text_colored("  Description: " .. info.description, 0xFFFFFF00)
            end
        elseif received_scoops["The Facts"] and not completed_scoops["The Facts"] then
            local info = SCOOP_DESCRIPTIONS["The Facts"]
            imgui.text_colored("Current Quest: The Facts", 0xFF00FF00)
            if info then
                imgui.text_colored("  Location:    " .. info.location, 0xFFFFFF00)
                imgui.text_colored("  Trigger:     " .. info.trigger, 0xFFFFFF00)
                imgui.text_colored("  Description: " .. info.description, 0xFFFFFF00)
            end
        else
            imgui.text_colored("All main scoops complete!", 0xFF00FF00)
        end

        imgui.separator()

        if not debug then
            local any_order = State.is_any_order()
            local running = any_order and State.active_main_scoop() or nil
            imgui.text(any_order and "Main Story (pick one):" or "Main Story:")
            for i, name in ipairs(scoop_order) do
                local color
                local has_item = ap_received[name] or received_scoops[name]
                -- In any-order there is no "current" scoop, so the highlight
                -- follows whichever one the player started.
                local highlight = any_order and running or current_chain_name
                if completed_scoops[name] then
                    color = 0xFF888888          -- gray: completed
                elseif name == highlight and has_item then
                    color = 0xFF00FF00          -- green: current + received
                elseif name == highlight then
                    color = 0xFF0000FF          -- red: current + not received (yellow was confusing)
                elseif has_item then
                    color = 0xFFFF8800          -- blue: received + not current
                else
                    color = 0xFF0000FF          -- red: not received + not current
                end

                local label = string.format("  %d. %s", i, name)
                if any_order and not completed_scoops[name] then
                    local blocker = State.main_scoop_blocker(name)
                    if blocker == nil then
                        if imgui.button("Start##" .. name) then
                            M.activate_main_scoop(name)
                        end
                        imgui.same_line()
                        imgui.text_colored(label, color)
                    else
                        -- Say why rather than dropping the row; "where did it
                        -- go" is a worse question than "why can I not."
                        imgui.text_colored(label .. "  -- " .. blocker, color)
                    end
                else
                    imgui.text_colored(label, color)
                end
            end
        else
            local chain_idx = M.get_current_chain_index()
            if current_chain_name then
                imgui.text_colored(
                    string.format("Chain: %d/%d -> %s", chain_idx, #scoop_order, current_chain_name),
                    0xFF00FFFF)
            else
                imgui.text_colored(
                    string.format("Chain: COMPLETE (%d/%d)", #scoop_order, #scoop_order),
                    0xFF00FF00)
            end
        end
    elseif debug then
        imgui.text_colored("Chain: No order set", 0xFFFF8800)
    end

    imgui.separator()

    if debug then
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
        if not State.is_activated() then
            if imgui.button("Force Activate") then M.force_activate() end
        end

        -- Debug god mode: composition of Untouchable+Toughness juices,
        -- heal ticks, and pinned speed (PlayerBuffs.set_god_mode). For
        -- fast story walkthroughs with the recorder collecting flags.
        local pb = _G.AP and _G.AP.effects and _G.AP.effects.PlayerBuffs
        if pb and pb.is_god_mode then
            local god_changed, god_val = imgui.checkbox("God Mode", pb.is_god_mode())
            if god_changed then pcall(pb.set_god_mode, god_val) end
            imgui.same_line()
            if imgui.button("Give MegaBuster+Laser Sword") then
                local spawner = _G.AP and _G.AP.ItemSpawner
                if spawner and spawner.add_received_item then
                    pcall(spawner.add_received_item, 58, "Real Mega Buster", "GodMode")
                    pcall(spawner.add_received_item, 12, "Laser Sword", "GodMode")
                end
            end
        end

        if imgui.button("Random Test Order") then M.generate_random_test_order() end
        if imgui.is_item_hovered() then
            imgui.set_tooltip("Reset, shuffle main scoops, mark all items as AP-received.\nChain starts after Get to the Stairs + Meet Jessie milestones,\njust like a real AP session.")
        end

        local enforce_changed, enforce_val = imgui.checkbox("Enforcement", enforcement_enabled)
        if enforce_changed then M.set_enforcement_enabled(enforce_val) end
        imgui.same_line()
        local verbose_changed, verbose_val = imgui.checkbox("Verbose", verbose_logging)
        if verbose_changed then M.set_verbose_logging(verbose_val) end

        imgui.separator()

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
        imgui.same_line()
        local hide_changed, hide_val = imgui.checkbox("Hide completed", hide_completed)
        if hide_changed then hide_completed = hide_val end

        imgui.separator()
    end

    imgui.begin_child_window("ScoopList", Vector2f.new(0, 0), true, 0)

    local status_list = M.get_all_status()
    local current_chain_scoop = M.get_current_chain_scoop()
    local side_header_shown = false

    if not debug and not State.is_activated() then
        local pending = 0
        for name, _ in pairs(ap_received) do
            local data = SCOOP_DATA[name]
            if data and data.category ~= "Main" and not received_scoops[name] then
                pending = pending + 1
            end
        end
        if pending > 0 then
            imgui.text_colored(
                string.format("Waiting for Meet Jessie: %d side scoop%s pending",
                    pending, pending > 1 and "s" or ""),
                0xFFFF8800)
        end
    end

    if State.is_item_deferred("Hideout") then
        imgui.text_colored("Hideout deferred: waiting for Carlito's Hideout Key", 0xFF00AAFF)
    end

    for _, s in ipairs(status_list) do
        local show = true
        local is_deferred = s.ap_item_received and (s.conflict_blocked or s.main_blocked)
        if filter_category ~= "All" and s.category ~= filter_category then show = false end
        if show_only_received and not s.received and not is_deferred then show = false end
        if hide_completed and s.completed then show = false end
        if not debug and s.category == "Main" then show = false end
        -- "Special" is not a scoop the player works on -- it is the
        -- Maintenance Tunnel Access Key, which lives here only so receiving
        -- the item sets its flag. It belongs in the Keys tab, not this list.
        if not debug and s.category == "Special" then show = false end
        -- Show side scoops that are received OR deferred (AP item received but blocked)
        if not debug and s.category ~= "Main" and not s.received and not is_deferred then show = false end

        if show then
            local color = CATEGORY_COLORS[s.category] or 0xFFFFFFFF
            local is_current_chain = (s.name == current_chain_scoop)

            local status_str = ""
            if s.completed then
                color = 0xFF888888
            elseif is_current_chain and s.received then
                status_str = " [CURRENT]"
                color = 0xFF00FF00          -- green: current + received
            elseif is_current_chain then
                status_str = " [CURRENT]"
                color = 0xFF00AAFF          -- orange: current + not received
            elseif s.main_blocked and s.ap_item_received then
                status_str = " - deferred (" .. tostring(s.main_blocker) .. " active)"
                color = 0xFF00AAFF          -- orange: blocked by active main
            elseif s.conflict_blocked and s.ap_item_received then
                status_str = " - deferred (" .. tostring(s.conflict_blocker) .. " active)"
                color = 0xFF00AAFF          -- orange: blocked by conflict group
            elseif s.received and s.category == "Main" then
                status_str = " [RECV]"
                color = 0xFFFF8800          -- blue: received + not current (main)
            elseif s.received and debug then
                status_str = " [RECV]"
            end

            -- Partial-rescue signal: if the scoop has rescuable survivors and
            -- some (but not all) have been rescued, tint amber so the player
            -- knows they're missing someone. Overrides the cascade above
            -- (except completion, which always wins -- see s.completed branch).
            if not s.completed and AP.effects and AP.effects.SurvivorScoopCompletion then
                local n_rescued, total = AP.effects.SurvivorScoopCompletion.progress(s.name)
                if total > 0 and n_rescued > 0 and n_rescued < total then
                    color = 0xFFFFAA00  -- amber: partially rescued
                    status_str = status_str .. string.format(" [%d/%d rescued]", n_rescued, total)
                end
            end

            if debug then
                if s.completed then
                    status_str = " [DONE]"
                end
                if s.flags_active then
                    status_str = status_str .. " [ON]"
                end

                local chain_str = ""
                if State.is_scoop_order_set() and s.category == "Main" then
                    local chain_pos = get_chain_position(s.name)
                    if chain_pos then
                        chain_str = string.format(" (%d/%d)", chain_pos, #scoop_order)
                    end
                end

                if imgui.button("Unlock##" .. s.name) then
                    State.mark_ap_received(s.name)
                    M.unlock_scoop(s.name)
                end
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
                    if s.conflict_group then
                        tip = tip .. "\nConflict group: " .. s.conflict_group
                    end
                    if s.conflict_blocked and s.conflict_blocker then
                        tip = tip .. "\nBlocked by: " .. s.conflict_blocker
                    end
                    if tip ~= "" then imgui.set_tooltip(tip) end
                end
            else
                if not side_header_shown and s.category ~= "Main" then
                    side_header_shown = true
                    imgui.text("Side Quests:")
                end

                if s.completion_event and not s.completed then
                    if imgui.button("Done##" .. s.name) then M.complete_scoop(s.name) end
                    imgui.same_line()
                end

                imgui.text_colored(s.name .. status_str, color)
            end
        end
    end

    imgui.end_child_window()
end

function M.on_frame()
    if not hooks_installed and not hook_install_attempted then
        if Shared.is_in_game and Shared.is_in_game() then
            install_hooks()
        end
    end

    -- World-stability tracking + parked unlock/reapply draining.
    update_world_stability()

    -- Process flag clears scheduled from the evFlagOn pre-hook. The one-frame
    -- delay lets the engine's evFlagOn body finish so the clear sticks.
    if next(pending_flag_clears) then
        for fid, _ in pairs(pending_flag_clears) do
            if raw_check_flag(fid) then
                raw_set_flag_off(fid)
                if verbose_logging then
                    M.log(string.format(
                        "ScoopSanity guard: cleared flag %d (suppressed completion -> allow legitimate refire)",
                        fid))
                end
            end
            pending_flag_clears[fid] = nil
        end
    end

    -- Detect save reload (flag 769 off = pre-Jessie). Deactivation is
    -- destructive (wipes side-scoop unlocks + persists), so guard it two ways:
    -- gameplay-only (the title screen reads 769 confirmed-false forever) and a
    -- RELOAD_CONFIRM_SECONDS dwell (failed/pre-restore reads reset the timer).
    local in_game = Shared.is_in_game()
    if not in_game then
        jessie_false_since = nil
    end
    if in_game and State.is_activated() then
        local jessie_on = raw_check_flag(JESSIE_FLAG)
        if jessie_on == false then
            jessie_false_since = jessie_false_since or os.clock()
            if os.clock() - jessie_false_since >= RELOAD_CONFIRM_SECONDS then
                jessie_false_since = nil
                M.log("RELOAD DETECTED: Flag 769 off -- deactivating until Meet Jessie replays")
                State.deactivate_for_reload()
            end
        else
            jessie_false_since = nil
        end
    elseif in_game and not State.is_activated() and scoop_sanity_enabled then
        jessie_false_since = nil
        local jessie_on = raw_check_flag(JESSIE_FLAG)
        if jessie_on == true then
            activate_ap("RELOAD DETECTED: Flag 769 on -- activating AP enforcement")
        end
    end

    -- ScoopSanity: keep time freeze matching game state (past stairs or Meet
    -- Jessie). Gameplay-gated like the reload detector -- title-screen flags
    -- read confirmed-false and the unfreeze branch used to fire on every exit.
    if in_game and scoop_sanity_enabled and efm_mgr:get() then
        local past_stairs = raw_check_flag(NEW_GAME_FLAGS[1]) and raw_check_flag(NEW_GAME_FLAGS[2])
        local jessie_on = raw_check_flag(JESSIE_FLAG)

        -- Freezing on a confirmed-true read is always safe; unfreezing
        -- requires confirmed-false on both flags -- a failed read during a
        -- load screen must not unfreeze.
        if (past_stairs == true or jessie_on == true) and not State.is_time_frozen() then
            State.set_time_frozen(true)
            M.log(string.format("ScoopSanity: time freeze applied (past_stairs=%s, jessie=%s)",
                tostring(past_stairs), tostring(jessie_on)))
            if on_time_freeze_callback then pcall(on_time_freeze_callback) end
            save_state()
        elseif past_stairs == false and jessie_on == false and State.is_time_frozen() then
            State.set_time_frozen(false)
            M.log("ScoopSanity: pre-stairs -- clearing time freeze")
            if on_time_unfreeze_callback then pcall(on_time_unfreeze_callback) end
        end
    end

    if active_time_skip then
        local ok_tg, TimeGate = pcall(require, "DRAP/TimeGate")
        if ok_tg and TimeGate then
            -- Run TimeGate frame logic here so turbo is maintained even when
            -- the main loop skips it (e.g. during cutscenes where isInGame() is false)
            TimeGate.on_frame()

            local md = TimeGate.get_current_mdate()
            if md and tonumber(md) >= active_time_skip.target_mdate then
                M.log(string.format("Time skip complete: %s (reached %s)",
                    active_time_skip.name, tostring(md)))
                active_time_skip = nil
                if TimeGate.is_turbo_active() then
                    TimeGate.cancel_turbo()
                end
                TimeGate.enable()
            elseif not TimeGate.is_turbo_active() then
                M.log(string.format("Time skip re-triggering turbo -> %d (%s)",
                    active_time_skip.target_mdate, active_time_skip.name))
                TimeGate.turbo_advance_to(active_time_skip.target_mdate)
            end
        end
    end

    -- Suppress door randomization while Hideout is active so Isabela follows
    -- through doors correctly. Uses flag checks so it works with or without ScoopSanity.
    -- Flag 776 = Hideout primary, flag 2322 = Hideout completion.
    if door_randomizer_enabled and efm_mgr:get() then
        local hideout_flag_on = raw_check_flag(776)
        local hideout_done    = raw_check_flag(2322) or completed_scoops["Hideout"]
        local should_suppress = hideout_flag_on and not hideout_done
        local dr = AP and AP.DoorRandomizer
        if dr and dr.set_suppressed then
            dr.set_suppressed(should_suppress == true)
        end
    end

    -- ScoopSanity EP-shutter trigger: position-gated, single-fire,
    -- persisted via in-game flags 765/2280.
    try_fire_ep270_in_scoop_sanity()

    -- Manage Entrance Plaza door (flag 276) for Rescue the Professor.
    -- Uses raw flag checks so it works with or without ScoopSanity.
    -- Flag 275 = Rescue the Professor primary flag.
    -- When professor is active: one-time disable of 276, then hands-off so
    -- the game can re-enable it during the completion cutscene.
    -- When professor is NOT active: enable 276 in Paradise Plaza, disable elsewhere.
    if State.is_activated() and efm_mgr:get() then
        local professor_flag_on = raw_check_flag(275)
        local professor_done = completed_scoops["Rescue the Professor"]
        local professor_active = professor_flag_on and not professor_done

        if professor_active then
            -- One-time disable: turn 276 OFF the first frame after
            -- Rescue the Professor becomes active.
            if not professor_276_disabled then
                if raw_check_flag(276) then
                    raw_set_flag_off(276)
                    M.log("Entrance Plaza door: disabled flag 276 (Rescue the Professor activated)")
                end
                professor_276_disabled = true
            end
            -- After one-time disable, leave 276 alone -- the game will
            -- enable it at the right moment for the completion cutscene.
        else
            professor_276_disabled = false  -- reset for next activation
            if get_current_area_index() == PARADISE_PLAZA_AREA_INDEX then
                if not raw_check_flag(276) then
                    currently_unlocking = true
                    raw_set_flag_on(276)
                    currently_unlocking = false
                end
            else
                if raw_check_flag(276) then
                    raw_set_flag_off(276)
                end
            end
        end
    end

    -- Poll-class deferral retries (flag prereqs + required items, e.g.
    -- the Carlito's Hideout Key). The state machine only checks scoops
    -- that previously deferred, so the common case is a single next().
    State.poll_deferred_retries()

    -- Session-gated: never reconcile flags against the title screen's
    -- cleared/menu state. Cutscenes keep their player session, so
    -- enforcement behavior there is unchanged. (Console force_enforce
    -- remains ungated for manual use.)
    if is_player_session() then
        enforce_flags()
    end
end

re.on_frame(function()
    M.on_frame()
end)

_G.scoop_unlock     = function(name) return M.unlock_scoop(name) end
_G.scoop_complete   = function(name) return M.complete_scoop(name) end
_G.scoop_unlock_all = function() return M.unlock_all() end
_G.scoop_enforce    = function() M.force_enforce() end
_G.scoop_activate   = function() M.force_activate() end
_G.scoop_newgame_reset = function() M.reset_for_new_game() end
_G.scoop_blacklist     = function(flag_id, reason) M.blacklist_flag(flag_id, reason) end
_G.scoop_unblacklist   = function(flag_id) M.unblacklist_flag(flag_id) end

-- ScoopSanity EP-shutter (flag 270) tuning helpers. Use these to identify the
-- right trigger area while standing in Entrance Plaza, then tighten the box.
_G.drap_ep270_show_pos = function()
    local x, y, z = get_player_pos_xyz()
    if not x then
        M.log("EP270: player not spawned (no position available)")
        return
    end
    local area = get_current_area_index()
    local f765 = raw_check_flag(765)
    local f2280 = raw_check_flag(2280)
    M.log(string.format(
        "EP270: pos=(%.2f, %.2f, %.2f) area=%s in_box=%s gates_open=%s (765=%s 2280=%s)",
        x, y, z, tostring(area), tostring(in_ep270_box(x, y, z)),
        tostring(ep270_gates_open()), tostring(f765), tostring(f2280)))
end
-- Simone's box was sized from her bundled spawn point, not measured in game.
-- Stand next to her and call this to see whether she is covered; widen with
-- drap_simone_set_box if the flag is not being held.
_G.drap_simone_status = function()
    local x, y, z = get_player_pos_xyz()
    if not x then
        M.log("Simone: player not spawned (no position available)")
        return
    end
    M.log(string.format(
        "Simone: pos=(%.2f, %.2f, %.2f) area=%s in_box=%s flag295=%s"
            .. " box=x[%.1f,%.1f] y[%.1f,%.1f] z[%.1f,%.1f]",
        x, y, z, tostring(get_current_area_index()),
        tostring(player_is_with_simone()), tostring(raw_check_flag(SIMONE_FLAG)),
        SIMONE_BOX.min_x, SIMONE_BOX.max_x, SIMONE_BOX.min_y,
        SIMONE_BOX.max_y, SIMONE_BOX.min_z, SIMONE_BOX.max_z))
end
_G.drap_simone_set_box = function(min_x, max_x, min_y, max_y, min_z, max_z)
    SIMONE_BOX = {
        min_x = tonumber(min_x), max_x = tonumber(max_x),
        min_y = tonumber(min_y), max_y = tonumber(max_y),
        min_z = tonumber(min_z), max_z = tonumber(max_z),
    }
    M.log(string.format("Simone: box set to x[%.1f,%.1f] y[%.1f,%.1f] z[%.1f,%.1f]",
        SIMONE_BOX.min_x, SIMONE_BOX.max_x, SIMONE_BOX.min_y,
        SIMONE_BOX.max_y, SIMONE_BOX.min_z, SIMONE_BOX.max_z))
end

_G.drap_ep270_set_box = function(min_x, max_x, min_y, max_y, min_z, max_z)
    EP270_TRIGGER_BOX = {
        min_x = tonumber(min_x), max_x = tonumber(max_x),
        min_y = tonumber(min_y), max_y = tonumber(max_y),
        min_z = tonumber(min_z), max_z = tonumber(max_z),
    }
    M.log(string.format(
        "EP270: trigger box -> x=[%.2f, %.2f] y=[%.2f, %.2f] z=[%.2f, %.2f]",
        EP270_TRIGGER_BOX.min_x, EP270_TRIGGER_BOX.max_x,
        EP270_TRIGGER_BOX.min_y, EP270_TRIGGER_BOX.max_y,
        EP270_TRIGGER_BOX.min_z, EP270_TRIGGER_BOX.max_z))
end
-- Force-clear the engine's gate flags (765 and 2280). Use only for testing
-- when you want to re-trigger the cutscene without rolling back the save.
-- In normal play, just load an earlier save; the gate flags reset naturally.
_G.drap_ep270_force_retry = function()
    currently_unlocking = true
    raw_set_flag_off(765)
    raw_set_flag_off(2280)
    currently_unlocking = false
    _ep_270_fired_at_clock = 0
    M.log("EP270: cleared gate flags 765 and 2280 -- next EP entry will re-fire")
end
_G.scoop_gui = function()
    local gui = require("DRAP/GUI")
    if gui then gui.show_window() end
end
_G.drap_reconciler = function(mode)
    if mode then M.set_reconciler_mode(mode) end
    local stats = M.get_reconciler_stats()
    local detail = ""
    if stats then
        local extra = stats.mismatches
            and string.format(" mismatches=%d", stats.mismatches)
            or (stats.applied and string.format(" writes=%d", #stats.applied) or "")
        detail = string.format(" | claims=%d conflicts=%d%s",
            stats.claims or 0, stats.conflicts or 0, extra)
    end
    print("Reconciler mode=" .. M.get_reconciler_mode() .. detail)
end
_G.scoop_verbose = function(on)
    if on == nil then on = not verbose_logging end
    M.set_verbose_logging(on)
end
_G.scoop_newgame = function()
    print("New game: " .. tostring(M.is_new_game()))
    print("Use scoop_newgame_reset() to force reset")
end
_G.scoop_chain = function()
    if not State.is_scoop_order_set() then print("No scoop order set"); return end
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
        tostring(State.is_activated()), tostring(State.is_time_frozen()), tostring(State.is_scoop_order_set())))
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

M.log(string.format("ScoopUnlocker loaded | Controlled: %d | Cascade: %d | Side: %d | Completion: %d | Blacklist: %d | Triggers: %d | Conflicts: %d",
    count_keys(CONTROLLED_FLAGS), count_keys(CASCADE_FLAGS), count_keys(ALL_SIDE_SCOOP_FLAGS), count_keys(COMPLETION_FLAGS),
    count_keys(FLAG_BLACKLIST), count_keys(FLAG_TRIGGERS), count_keys(CONFLICT_GROUPS)))

return M
