-- DRAP/effects/SaviorGoalEffects.lua
-- Implements the Savior goal: the player wins by rescuing a configurable
-- number of survivors. Completion fires when AP.NumberOfSurvivors distinct
-- "Rescue X" locations have been checked -- bridge sends the Savior goal
-- location, Python's Victory item is claimed, completion_condition resolves.
--
-- Only active when AP.Goal == 2. Otherwise the module is inert.
--
-- Counting is based on AP_BRIDGE.has_completed_check, which persists across
-- disconnects, so the running total survives reconnects and crashes without
-- needing its own save file.

local SharedData = require("DRAP/SharedData")

local M = {}

local GOAL_SAVIOR = 2
local GOAL_LOCATION_NAME = "Savior: Rescue enough survivors to escape"

local goal_sent = false

local Shared = require("DRAP/Shared")
local log = Shared.create_logger("SaviorGoalEffects")

-- Build the full list of survivor names the game knows about -- the 45 from
-- scoop_survivors plus the 3 free survivors (Bill, Jeff, Natalie) who arrive
-- without a dedicated scoop. Lazily computed so shared data doesn't have to
-- be available at require time.
local _survivor_universe = nil

local FREE_SURVIVORS = { "Bill Brenton", "Jeff Meyer", "Natalie Meyer" }

local function survivor_universe()
    if _survivor_universe then return _survivor_universe end
    _survivor_universe = {}
    local seen = {}
    for _, survivors in pairs(SharedData.scoop_survivors()) do
        for _, name in ipairs(survivors) do
            if not seen[name] then
                seen[name] = true
                table.insert(_survivor_universe, name)
            end
        end
    end
    for _, name in ipairs(FREE_SURVIVORS) do
        if not seen[name] then
            seen[name] = true
            table.insert(_survivor_universe, name)
        end
    end
    return _survivor_universe
end

-- Count rescue checks via the bridge. Iterates known survivors so the count
-- is bounded and doesn't pick up unrelated location names.
local function count_rescued()
    if not AP or not AP.AP_BRIDGE or not AP.AP_BRIDGE.has_completed_check then
        return 0
    end
    local n = 0
    for _, name in ipairs(survivor_universe()) do
        if AP.AP_BRIDGE.has_completed_check("Rescue " .. name) then
            n = n + 1
        end
    end
    return n
end

local function is_savior_goal()
    return AP and AP.Goal == GOAL_SAVIOR
end

local function target()
    return (AP and tonumber(AP.NumberOfSurvivors)) or 35
end

local function try_send_goal()
    if goal_sent then return end
    if not is_savior_goal() then return end
    local n = count_rescued()
    local t = target()
    if n >= t then
        log(string.format("Savior threshold reached (%d/%d). Sending goal check.", n, t))
        if AP.AP_BRIDGE and AP.AP_BRIDGE.check then
            AP.AP_BRIDGE.check(GOAL_LOCATION_NAME)
            goal_sent = true
        end
    end
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

function M.on_survivor_rescued(friendly_name)
    if not is_savior_goal() then return end
    try_send_goal()
end

-- Re-evaluate after save-load / reconnect in case the threshold was already
-- met but the goal check hadn't been sent (e.g. crash between rescue and
-- send). Idempotent; second sends are harmless.
function M.reapply()
    if not is_savior_goal() then return end
    try_send_goal()
end

function M.progress()
    return count_rescued(), target()
end

function M.register_all()
    if is_savior_goal() then
        log(string.format("Savior goal active: target = %d survivors", target()))
    end
end

-- Diagnostic: show Savior goal state and what the per-survivor count is
-- looking at. Useful when "I rescued enough but the goal didn't fire".
function M.print_progress()
    local n, t = M.progress()
    log(string.format("AP.Goal=%s (savior=%d) | AP.NumberOfSurvivors=%s | goal_sent=%s",
        tostring(AP and AP.Goal), GOAL_SAVIOR,
        tostring(AP and AP.NumberOfSurvivors), tostring(goal_sent)))
    log(string.format("Universe: %d survivors | Rescued: %d / %d",
        #survivor_universe(), n, t))
    if n < t then
        log("Survivors NOT yet rescued (per bridge COMPLETED_CHECKS):")
        for _, name in ipairs(survivor_universe()) do
            local check_name = "Rescue " .. name
            local rescued = AP and AP.AP_BRIDGE and AP.AP_BRIDGE.has_completed_check
                          and AP.AP_BRIDGE.has_completed_check(check_name)
            if not rescued then
                log("  " .. name)
            end
        end
    end

    -- Dump everything in COMPLETED_CHECKS so we can see if rescue entries exist
    -- in a different format (e.g., wrong prefix, partial name).
    if AP and AP.AP_BRIDGE and type(AP.AP_BRIDGE.get_completed_checks) == "function" then
        local all_checks = AP.AP_BRIDGE.get_completed_checks() or {}
        log(string.format("--- COMPLETED_CHECKS dump (total: %d) ---", #all_checks))
        local rescue_count = 0
        local rescue_names = {}
        for _, name in ipairs(all_checks) do
            if type(name) == "string" and name:lower():find("rescue") then
                rescue_count = rescue_count + 1
                table.insert(rescue_names, name)
            end
        end
        log(string.format("Entries containing 'rescue' (any case): %d", rescue_count))
        if rescue_count > 0 then
            table.sort(rescue_names)
            for _, name in ipairs(rescue_names) do
                log("  " .. name)
            end
        else
            log("  (none -- so no rescue checks reached COMPLETED_CHECKS)")
            log("--- Sample of other checks (up to 10): ---")
            local shown = 0
            for _, name in ipairs(all_checks) do
                if shown >= 10 then break end
                log("  " .. tostring(name))
                shown = shown + 1
            end
        end
    end
end

_G.drap_savior_progress = function()
    M.print_progress()
    -- Cross-check: NpcTracker's in-memory rescued_survivors count.
    if AP and AP.NpcTracker and AP.NpcTracker.get_rescued_survivors then
        local rescued = AP.NpcTracker.get_rescued_survivors() or {}
        local n = 0
        for _ in pairs(rescued) do n = n + 1 end
        log(string.format("NpcTracker.get_rescued_survivors() count: %d", n))
        if n == 0 then
            log("(NpcTracker has detected zero rescues -- either not in gameplay,")
            log(" or polling hasn't picked them up yet, or singleton issue)")
        end
    end
end
_G.drap_savior_reset = function()
    goal_sent = false
    log("goal_sent reset; calling reapply() to re-evaluate against current rescue count")
    M.reapply()
end

-- Recovery: directly scan NpcManager.NpcInfoList for survivors currently in
-- a safe-room state and send Rescue checks for each. Bypasses NpcTracker
-- entirely -- useful when in-memory state has been lost (e.g., script reset,
-- corrupted COMPLETED_CHECKS file) and the goal isn't firing despite
-- in-game rescues being present.
_G.drap_savior_force_scan = function()
    if not AP or not AP.AP_BRIDGE or not AP.AP_BRIDGE.check then
        log("[Scan] AP_BRIDGE not loaded")
        return
    end

    local mgr = sdk.get_managed_singleton("app.solid.gamemastering.NpcManager")
    if not mgr then
        log("[Scan] NpcManager not available -- are you in-game?")
        return
    end

    local td = mgr:get_type_definition()
    local list_field = td and td:get_field("NpcInfoList")
    if not list_field then
        log("[Scan] NpcInfoList field not found")
        return
    end

    local ok_list, list = pcall(list_field.get_data, list_field, mgr)
    if not ok_list or not list then
        log("[Scan] Could not read NpcInfoList")
        return
    end

    local ok_count, count = pcall(function() return list:call("get_Count") end)
    if not ok_count or not count then
        log("[Scan] Could not get NpcInfoList count")
        return
    end
    count = tonumber(count) or 0

    -- LIVE_STATE values from NpcTracker:
    --   3 = ENTER_SAFTY_AREA, 4 = SAFTY_AREA
    local IN_SAFE = { [3] = true, [4] = true }
    local sent = 0
    local already = 0
    local skipped_unnamed = 0

    for i = 0, count - 1 do
        local ok_item, npc_info = pcall(function() return list:call("get_Item", i) end)
        if ok_item and npc_info then
            local info_td = npc_info:get_type_definition()
            local name_field = info_td and info_td:get_field("<Name>k__BackingField")
            local state_field = info_td and info_td:get_field("mLiveState")
            if name_field and state_field then
                local _, name_enum = pcall(name_field.get_data, name_field, npc_info)
                local _, state_raw = pcall(state_field.get_data, state_field, npc_info)
                local npc_id = nil
                if name_enum ~= nil then
                    npc_id = type(name_enum) == "number" and name_enum or tonumber(tostring(name_enum))
                end
                local state = state_raw and (tonumber(state_raw) or 0) or 0
                if npc_id and IN_SAFE[state] then
                    local friendly = AP.NpcTracker and AP.NpcTracker.get_survivor_friendly_name
                                   and AP.NpcTracker.get_survivor_friendly_name(npc_id)
                    if friendly and friendly ~= "" then
                        local check_name = "Rescue " .. friendly
                        if AP.AP_BRIDGE.has_completed_check(check_name) then
                            already = already + 1
                        else
                            AP.AP_BRIDGE.check(check_name)
                            sent = sent + 1
                            log("[Scan] Sent: " .. check_name)
                        end
                    else
                        skipped_unnamed = skipped_unnamed + 1
                    end
                end
            end
        end
    end

    log(string.format(
        "[Scan] Done. Scanned %d NPCs | sent %d new rescues | %d already in checks | %d unnamed",
        count, sent, already, skipped_unnamed))

    -- Re-evaluate Savior goal now that COMPLETED_CHECKS is updated.
    M.reapply()
end

return M
