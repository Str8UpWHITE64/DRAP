-- DRAP/scoops/ScoopState.lua
-- The pure scoop state machine: which scoops are AP-received, unlocked,
-- completed; the ScoopSanity chain; and the unified unlock-condition
-- (deferral) model.
--
-- PURITY CONTRACT: touches no engine state (no sdk, json, imgui,
-- re.on_frame). Everything external arrives through init() as data or
-- injected predicates/callbacks, so it is unit-testable outside the game
-- (tools/logic_tests/test_scoop_state.py, under lupa).
--
-- OWNERSHIP: the only writer of scoop state. ScoopUnlocker aliases the
-- exported tables (M.ap_received, M.received, M.completed,
-- M.completion_times, M.scoop_order) for cheap per-frame reads; they are
-- cleared in place and NEVER reassigned, so aliases stay valid.
--
-- UNLOCK CONDITIONS (one deferral model). Event-class retried on the
-- named event; poll-class retried each poll_deferred_retries() tick:
--   activation   - AP not activated yet (event: on activate)
--   conflict     - another conflict-group member active (event: on member complete)
--   main_block   - blocking main scoop active (event: on blocker complete)
--   prereq       - prerequisite scoops not completed (event: on any completion)
--   flag_prereq  - engine flag prerequisite not met (poll: injected check_flag)
--   item         - required AP item not owned (poll: injected has_item)

local M = {}

------------------------------------------------------------
-- Exported state tables (cleared in place, never reassigned)
------------------------------------------------------------

M.ap_received = {}       -- name -> true  (AP item arrived)
M.received = {}          -- name -> true  (unlocked in-game)
M.completed = {}         -- name -> true
M.completion_times = {}  -- name -> cfg.now() timestamp
M.scoop_order = {}       -- array of main-scoop names (ScoopSanity chain)

local scoop_order_set = false
local ap_activated = false
local time_frozen = false
local endgame_reached = false

-- Poll-class parking: { [name] = "flag_prereq" | "item" }
local poll_deferred = {}

------------------------------------------------------------
-- Config (data + injected adapters)
------------------------------------------------------------

local cfg = {
    scoop_data = {},           -- name -> { category, order, ... }
    conflict_groups = {},      -- group -> { names in order }
    main_blocks_side = {},     -- main name -> { side names }
    prerequisites = {},        -- name -> { required completed names }
    flag_prerequisites = {},   -- name -> { flag ids } (ANY-of)
    -- flag-prereq bypass: name -> "any_main_completed" (Mark of the
    -- Sniper: a completed main proves the EP scene is past the state
    -- the prereq protects against)
    flag_prereq_bypass = {},
    item_requirements = {},    -- name -> AP item name (Hideout key)
    chain_final = nil,         -- scoop auto-unlocked when the chain ends
    log = function(_) end,
    now = function() return 0 end,
    check_flag = function(_) return nil end,   -- true/false/nil(unreadable)
    has_item = function(_) return false end,
    on_unlock = function(_, _) end,            -- engine flag writes
    on_state_changed = function() end,         -- persistence trigger
}

-- Derived lookups
local scoop_to_conflict = {}   -- name -> { group, members }
local side_blocked_by = {}     -- side name -> { main names }

function M.init(options)
    for k, v in pairs(options or {}) do cfg[k] = v end

    scoop_to_conflict = {}
    for group_name, group_list in pairs(cfg.conflict_groups) do
        for _, scoop_name in ipairs(group_list) do
            scoop_to_conflict[scoop_name] = {
                group = group_name,
                members = group_list,
            }
        end
    end

    side_blocked_by = {}
    for main_name, side_list in pairs(cfg.main_blocks_side) do
        for _, side_name in ipairs(side_list) do
            side_blocked_by[side_name] = side_blocked_by[side_name] or {}
            table.insert(side_blocked_by[side_name], main_name)
        end
    end
end

local function clear_table(t)
    for k in pairs(t) do t[k] = nil end
end

------------------------------------------------------------
-- Queries
------------------------------------------------------------

function M.data(name) return cfg.scoop_data[name] end

function M.is_activated() return ap_activated end
function M.is_time_frozen() return time_frozen end
function M.is_endgame_reached() return endgame_reached end
function M.has_ap_received(name) return M.ap_received[name] == true end
function M.has_received(name) return M.received[name] == true end
function M.is_completed(name) return M.completed[name] == true end
function M.is_scoop_order_set() return scoop_order_set end

function M.conflict_info(name) return scoop_to_conflict[name] end
function M.blocked_by_mains(name) return side_blocked_by[name] end

-- A scoop is "active" for blocking purposes when unlocked but not done.
local function is_active(name)
    return M.received[name] == true and not M.completed[name]
end
M.is_active = is_active

function M.is_conflict_blocked(scoop_name)
    local info = scoop_to_conflict[scoop_name]
    if not info then return false end
    for _, member in ipairs(info.members) do
        if member ~= scoop_name and is_active(member) then
            return true, member
        end
    end
    return false
end

function M.is_blocked_by_active_main(scoop_name)
    local blockers = side_blocked_by[scoop_name]
    if not blockers then return false end
    for _, main_name in ipairs(blockers) do
        if is_active(main_name) then
            return true, main_name
        end
    end
    return false
end

function M.has_prerequisites_met(scoop_name)
    local prereqs = cfg.prerequisites[scoop_name]
    if not prereqs then return true end
    for _, req_name in ipairs(prereqs) do
        if not M.completed[req_name] then
            return false
        end
    end
    return true
end

-- Any completed main-category scoop, or nil. Used by the EP-shutter
-- special cases in ScoopUnlocker and the flag-prereq bypass here.
function M.find_completed_main()
    for name, data in pairs(cfg.scoop_data) do
        if data.category == "Main" and M.completed[name] then
            return name
        end
    end
    return nil
end

-- ANY-of semantics; returns (true, nil) or (false, flag_list).
function M.has_flag_prerequisites_met(scoop_name)
    local flag_list = cfg.flag_prerequisites[scoop_name]
    if not flag_list then return true, nil end
    for _, fid in ipairs(flag_list) do
        if cfg.check_flag(fid) then return true, nil end
    end
    if cfg.flag_prereq_bypass[scoop_name] == "any_main_completed"
        and M.find_completed_main() then
        return true, nil
    end
    return false, flag_list
end

function M.is_item_deferred(scoop_name)
    return poll_deferred[scoop_name] == "item"
end

function M.get_poll_deferred()
    return poll_deferred
end

------------------------------------------------------------
-- Chain (ScoopSanity main-scoop order)
------------------------------------------------------------

function M.get_chain_position(scoop_name)
    for i, name in ipairs(M.scoop_order) do
        if name == scoop_name then return i end
    end
    return nil
end

function M.get_current_chain_index()
    if not scoop_order_set or #M.scoop_order == 0 then return 0 end
    for i, name in ipairs(M.scoop_order) do
        if not M.completed[name] then return i end
    end
    return #M.scoop_order + 1
end

function M.get_current_chain_scoop()
    local idx = M.get_current_chain_index()
    if idx > 0 and idx <= #M.scoop_order then
        return M.scoop_order[idx]
    end
    return nil
end

function M.try_advance_chain()
    if not scoop_order_set or #M.scoop_order == 0 then return end
    if not ap_activated then return end

    for i, name in ipairs(M.scoop_order) do
        if not M.completed[name] then
            if M.received[name] then
                return
            end
            if M.ap_received[name] then
                cfg.log(string.format("Chain: Unlocking '%s' (%d/%d) -- received and ready",
                    name, i, #M.scoop_order))
                M.request_unlock(name)
            end
            return
        end
    end

    cfg.log("Chain: All main scoops completed!")

    local final = cfg.chain_final
    if final and not M.received[final] and not M.completed[final] then
        cfg.log(string.format("Chain: Triggering '%s' -- go back to the Security Room", final))
        M.request_unlock(final)
    end
end

function M.set_scoop_order(order_list)
    if type(order_list) ~= "table" or #order_list == 0 then
        cfg.log("ERROR: Invalid scoop order (empty or not a table)")
        return false
    end

    clear_table(M.scoop_order)
    for i, name in ipairs(order_list) do M.scoop_order[i] = name end
    scoop_order_set = true

    local names = {}
    for i, name in ipairs(M.scoop_order) do
        table.insert(names, string.format("%d.%s", i, name))
    end
    cfg.log(string.format("Scoop order set (%d entries): %s",
        #M.scoop_order, table.concat(names, ", ")))

    if ap_activated then
        M.try_advance_chain()
    end

    cfg.on_state_changed()
    return true
end

------------------------------------------------------------
-- Unlock (with unified conditions)
------------------------------------------------------------

-- Returns (true, nil) when the scoop was newly unlocked or already was;
-- (false, reason) when deferred. cfg.on_unlock fires only on a NEW unlock.
function M.request_unlock(scoop_name)
    local scoop = cfg.scoop_data[scoop_name]
    if not scoop then
        cfg.log(string.format("WARNING: Unknown scoop '%s'", tostring(scoop_name)))
        return false, "unknown"
    end

    if M.received[scoop_name] then return true, nil end

    if not ap_activated then
        cfg.log(string.format("Activation deferred: '%s' -- waiting for Meet Jessie", scoop_name))
        return false, "activation"
    end

    if scoop.category ~= "Main" then
        local blocked, blocker = M.is_conflict_blocked(scoop_name)
        if blocked then
            cfg.log(string.format("Conflict deferred: '%s' blocked by active '%s'",
                scoop_name, tostring(blocker)))
            return false, "conflict"
        end
        local main_blocked, main_blocker = M.is_blocked_by_active_main(scoop_name)
        if main_blocked then
            cfg.log(string.format("Main-blocked deferred: '%s' blocked by active '%s'",
                scoop_name, tostring(main_blocker)))
            return false, "main_block"
        end
        if not M.has_prerequisites_met(scoop_name) then
            cfg.log(string.format("Prerequisite deferred: '%s' -- missing required completions", scoop_name))
            return false, "prereq"
        end
    end

    local flags_ok, missing_flags = M.has_flag_prerequisites_met(scoop_name)
    if not flags_ok then
        poll_deferred[scoop_name] = "flag_prereq"
        cfg.log(string.format("Flag-prereq deferred: '%s' -- waiting for any of flags %s",
            scoop_name, table.concat(missing_flags, ",")))
        return false, "flag_prereq"
    end

    local item = cfg.item_requirements[scoop_name]
    if item and not cfg.has_item(item) then
        poll_deferred[scoop_name] = "item"
        cfg.log(string.format("Item deferred: '%s' -- waiting for '%s'", scoop_name, item))
        return false, "item"
    end

    poll_deferred[scoop_name] = nil
    M.received[scoop_name] = true
    cfg.on_unlock(scoop_name, scoop)
    return true, nil
end

-- Poll-class retries (flag_prereq + item), called from on_frame. Only
-- scoops that previously deferred are checked, so the common case is a
-- single next() test.
function M.poll_deferred_retries()
    if not next(poll_deferred) then return end
    local to_retry = {}
    for scoop_name, reason in pairs(poll_deferred) do
        if M.ap_received[scoop_name] and not M.received[scoop_name] then
            local ready = false
            if reason == "flag_prereq" then
                ready = M.has_flag_prerequisites_met(scoop_name)
            elseif reason == "item" then
                local item = cfg.item_requirements[scoop_name]
                ready = item and cfg.has_item(item)
            end
            if ready then table.insert(to_retry, scoop_name) end
        else
            -- No longer relevant (completed elsewhere or never AP-received)
            if M.received[scoop_name] then poll_deferred[scoop_name] = nil end
        end
    end
    for _, scoop_name in ipairs(to_retry) do
        cfg.log(string.format("Deferred condition met -- retrying '%s' activation", scoop_name))
        -- Chain scoops re-enter via the chain so ordering rules hold.
        local data = cfg.scoop_data[scoop_name]
        if data and data.category == "Main" and scoop_order_set then
            poll_deferred[scoop_name] = nil
            M.try_advance_chain()
        else
            M.request_unlock(scoop_name)
        end
    end
end

------------------------------------------------------------
-- Completion
------------------------------------------------------------

local function try_advance_conflict_group(completed_name)
    local info = scoop_to_conflict[completed_name]
    if not info then return end

    for _, member in ipairs(info.members) do
        if member ~= completed_name and M.ap_received[member] and not M.completed[member] then
            if not M.received[member] then
                cfg.log(string.format("Conflict group '%s': '%s' completed -> unlocking '%s'",
                    info.group, completed_name, member))
                M.request_unlock(member)
            end
            return
        end
    end
end

function M.complete(scoop_name)
    local scoop = cfg.scoop_data[scoop_name]
    if not scoop then return false end
    if M.completed[scoop_name] then return true end
    M.completed[scoop_name] = true
    M.completion_times[scoop_name] = cfg.now()
    cfg.log(string.format("Completed %s '%s'", scoop.category, scoop_name))

    if scoop.category == "Main" and scoop_order_set then
        M.try_advance_chain()
    end

    try_advance_conflict_group(scoop_name)

    -- Retry side scoops this main was blocking.
    local blocked_sides = cfg.main_blocks_side[scoop_name]
    if blocked_sides then
        for _, side_name in ipairs(blocked_sides) do
            if M.ap_received[side_name] and not M.received[side_name] then
                local still_blocked, new_blocker = M.is_blocked_by_active_main(side_name)
                if not still_blocked then
                    cfg.log(string.format("Retrying deferred side scoop '%s' (blocker '%s' completed)",
                        side_name, scoop_name))
                    M.request_unlock(side_name)
                else
                    cfg.log(string.format("Side scoop '%s' still blocked by '%s'",
                        side_name, tostring(new_blocker)))
                end
            end
        end
    end

    cfg.on_state_changed()
    return true
end

------------------------------------------------------------
-- AP item receipt / activation / milestones
------------------------------------------------------------

function M.mark_ap_received(scoop_name)
    M.ap_received[scoop_name] = true
end

-- Activation is split so ScoopUnlocker can write its post-Jessie engine
-- flags between the two steps, preserving the historical order:
--   set_activated(true) -> engine writes -> on_activated()
function M.set_activated(v)
    ap_activated = v == true
end

function M.on_activated()
    M.try_advance_chain()

    -- Flush side scoops that arrived pre-activation.
    local flushed = 0
    for scoop_name, _ in pairs(M.ap_received) do
        local data = cfg.scoop_data[scoop_name]
        if data and data.category ~= "Main" and not M.received[scoop_name] then
            M.request_unlock(scoop_name)
            flushed = flushed + 1
        end
    end
    if flushed > 0 then
        cfg.log(string.format("Flushed %d pending scoops after activation", flushed))
    end
end

function M.set_time_frozen(v)
    time_frozen = v == true
end

function M.set_endgame_reached(v)
    endgame_reached = v == true
end

------------------------------------------------------------
-- Reapply (after save load)
------------------------------------------------------------

function M.reapply()
    cfg.log("Reapplying unlocked scoops...")
    local main_count, side_count = 0, 0

    -- Snapshot names first: request_unlock() re-inserts into M.received,
    -- and mutating a table while pairs() iterates it is undefined.
    local mains, sides = {}, {}
    for scoop_name, _ in pairs(M.received) do
        if not M.completed[scoop_name] then
            local data = cfg.scoop_data[scoop_name]
            if data and data.category == "Main" then
                table.insert(mains, scoop_name)
            elseif data then
                table.insert(sides, scoop_name)
            end
        end
    end

    if scoop_order_set and ap_activated then
        M.try_advance_chain()
    else
        for _, scoop_name in ipairs(mains) do
            M.received[scoop_name] = nil
            M.request_unlock(scoop_name)
            main_count = main_count + 1
        end
    end

    for _, scoop_name in ipairs(sides) do
        M.received[scoop_name] = nil
        M.request_unlock(scoop_name)
        side_count = side_count + 1
    end

    cfg.log(string.format("Reapplied: %d main, %d side scoops", main_count, side_count))
end

------------------------------------------------------------
-- Resets
------------------------------------------------------------

function M.reset_all()
    clear_table(M.ap_received)
    clear_table(M.received)
    clear_table(M.completed)
    clear_table(M.completion_times)
    clear_table(M.scoop_order)
    clear_table(poll_deferred)
    scoop_order_set = false
    ap_activated = false
    time_frozen = false
    endgame_reached = false
    cfg.log("Reset all scoop tracking")
    cfg.on_state_changed()
end

-- New game: side-scoop progress resets, main completions persist.
function M.reset_for_new_game()
    cfg.log("NEW GAME detected -- resetting side scoop progress")

    local side_reset, main_preserved = 0, 0
    for name in pairs(M.completed) do
        local data = cfg.scoop_data[name]
        if data and data.category == "Main" then
            main_preserved = main_preserved + 1
        else
            M.completed[name] = nil
            M.completion_times[name] = nil
            side_reset = side_reset + 1
        end
    end

    for name in pairs(M.received) do
        local data = cfg.scoop_data[name]
        if not (data and data.category == "Main") then
            M.received[name] = nil
        end
    end

    time_frozen = false
    ap_activated = false
    endgame_reached = false
    clear_table(poll_deferred)

    cfg.log(string.format("Reset %d side scoops, preserved %d main completions",
        side_reset, main_preserved))
    cfg.on_state_changed()
    return side_reset, main_preserved
end

-- Pre-Jessie save reload: deactivate and clear side unlocks (they will
-- re-flush after Meet Jessie replays).
function M.deactivate_for_reload()
    ap_activated = false
    time_frozen = false

    local cleared = 0
    for scoop_name in pairs(M.received) do
        local data = cfg.scoop_data[scoop_name]
        if data and data.category ~= "Main" then
            M.received[scoop_name] = nil
            cleared = cleared + 1
        end
    end
    if cleared > 0 then
        cfg.log(string.format("Cleared %d side scoop unlocks for pre-Jessie state", cleared))
    end
    cfg.on_state_changed()
    return cleared
end

------------------------------------------------------------
-- Persistence (plain-table serialization; storage IO stays outside)
------------------------------------------------------------

function M.serialize()
    local completed_list = {}
    for name in pairs(M.completed) do table.insert(completed_list, name) end
    table.sort(completed_list)

    local ap_received_list = {}
    for name in pairs(M.ap_received) do table.insert(ap_received_list, name) end
    table.sort(ap_received_list)

    local order = {}
    for i, name in ipairs(M.scoop_order) do order[i] = name end

    return {
        version = 2,
        ap_activated = ap_activated,
        time_frozen = time_frozen,
        endgame_reached = endgame_reached,
        scoop_order = order,
        completed_scoops = completed_list,
        ap_received = ap_received_list,
    }
end

-- Restores from a serialize()-shaped table. Mirrors the old load_state
-- semantics: only ever turns state ON (a restore never clears progress),
-- and respects an already-set scoop order.
function M.restore(data)
    if type(data) ~= "table" then return false end

    if data.ap_activated then
        ap_activated = true
        cfg.log("Restored: AP activated")
    end
    if data.time_frozen then
        time_frozen = true
        cfg.log("Restored: Time frozen")
    end
    if data.endgame_reached then
        endgame_reached = true
        cfg.log("Restored: Endgame reached (flags 2052, 514 enforced)")
    end

    if data.scoop_order and #data.scoop_order > 0 and not scoop_order_set then
        clear_table(M.scoop_order)
        for i, name in ipairs(data.scoop_order) do M.scoop_order[i] = name end
        scoop_order_set = true
        cfg.log(string.format("Restored scoop order (%d entries)", #M.scoop_order))
    end

    if data.completed_scoops then
        for _, name in ipairs(data.completed_scoops) do
            M.completed[name] = true
        end
        cfg.log(string.format("Restored %d completed scoops", #data.completed_scoops))
    end

    if data.ap_received then
        for _, name in ipairs(data.ap_received) do
            M.ap_received[name] = true
        end
        cfg.log(string.format("Restored %d AP received scoops", #data.ap_received))
    end

    return true
end

return M
