-- DRAP/trackers/KillTracker.lua
-- Sends the "Kill N zombies in <area>" checks.
--
-- Counting is hooked, not polled: addZombieKillNum fires once per kill, so
-- the hook credits the area the player is in at that moment. The save's own
-- counter only moves at an area transition, too late to attribute by.
--
-- Counts live in a DataStorage key per area, incremented with "add" so the
-- server does the arithmetic and two clients cannot clobber each other. The
-- ledger holds the same numbers, and on connect the two reconcile both ways:
-- the server wins where it is higher, and where it is behind the difference
-- is pushed, which is what heals a write dropped at quit.
--
-- The arithmetic lives in KillCounter.lua, which touches no engine state.

local Shared = require("DRAP/Shared")
local Counter = require("DRAP/trackers/KillCounter")

local M = Shared.create_module("KillTracker")

local SOLID_STORAGE = "app.solid.SolidStorage"
local LEDGER_SECTION = "zombie_kills"

-- Kills between writes. The ledger write is a whole-document save and the
-- push is a round trip, so neither belongs on a per-kill path. Crossing a
-- threshold flushes regardless, so a check never waits on this.
local FLUSH_EVERY = 25

local am_mgr = M:add_singleton("am", "app.solid.gamemastering.AreaManager")

local counter = Counter.new()
local enabled = false
-- Whether a slot has connected and handed us its thresholds. Separate from
-- `enabled` so the tab can say which kind of nothing it is showing.
local configured = false
local installed = false
local last_scene = nil

------------------------------------------------------------
-- Area
------------------------------------------------------------

local function current_scene()
    local am = am_mgr:get()
    if not am then return nil end
    local path = Shared.get_field_value(am, { "CurrentLevelPath" })
    if path == nil then return nil end
    return tostring(path)
end

------------------------------------------------------------
-- Server storage
------------------------------------------------------------

-- One key per area. Prefixed with team and slot so two slots on one server
-- never share a count.
local function storage_key(region)
    local AP_REF = _G.AP_REF
    if not (AP_REF and AP_REF.APClient) then return nil end
    local ok, key = pcall(function()
        return string.format("drap_kills_%d_%d_%s",
            tonumber(AP_REF.APClient:get_team_number()) or 0,
            tonumber(AP_REF.APClient:get_player_number()) or 0,
            region)
    end)
    return ok and key or nil
end

local key_to_region = {}

-- Nothing is pushed until the server's counts come back, or the two cross:
-- a push made during the read is not in the value already on its way back.
local awaiting_pull = false
local pull_started_at = nil
local PULL_TIMEOUT_SECONDS = 15
local pushed_ok, pushed_failed = 0, 0

-- Kills made while the read is in flight. Held rather than counted, because
-- the server's number is a baseline to add to, not a rival to take the larger
-- of, and only the sum knows whether a threshold was crossed.
local held = {}

-- The binding's Set signature is undocumented, so the shapes are tried in
-- order and the first that works is remembered. Best-effort: the ledger has
-- the count either way, so a refused write only costs cross-save continuity.
local set_variant = nil

local SET_VARIANTS = {
    {
        name = "Set(key, default, want_reply, operations)",
        call = function(client, key, delta)
            client:Set(key, 0, true, { { operation = "add", value = delta } })
        end,
    },
    {
        name = "Set(key, default, want_reply, {op})",
        call = function(client, key, delta)
            client:Set(key, 0, true, { operation = "add", value = delta })
        end,
    },
}

local function push_delta(region, delta)
    if delta <= 0 then return false end
    local AP_REF = _G.AP_REF
    if not (AP_REF and AP_REF.APClient) then return false end
    local key = storage_key(region)
    if not key then return false end
    key_to_region[key] = region

    if set_variant then
        local ok = pcall(SET_VARIANTS[set_variant].call, AP_REF.APClient, key, delta)
        if ok then
            pushed_ok = pushed_ok + 1
        else
            pushed_failed = pushed_failed + 1
            set_variant = nil
        end
        return ok
    end

    for i, variant in ipairs(SET_VARIANTS) do
        if pcall(variant.call, AP_REF.APClient, key, delta) then
            set_variant = i
            pushed_ok = pushed_ok + 1
            M.log("DataStorage writes using " .. variant.name)
            return true
        end
    end
    pushed_failed = pushed_failed + 1
    M.log.warn("DataStorage Set failed for every known signature -- counts "
        .. "stay local to this save")
    return false
end

--- True once the server's counts have arrived, or once waiting for them has
--- gone on long enough that the run should not be held up any further.
local function pull_settled()
    if not awaiting_pull then return true end
    if pull_started_at and (os.clock() - pull_started_at) > PULL_TIMEOUT_SECONDS then
        awaiting_pull = false
        M.log.warn(string.format(
            "no DataStorage reply after %ds -- treating the local counts as "
            .. "authoritative and pushing from here",
            PULL_TIMEOUT_SECONDS))
        return true
    end
    return false
end

--- Ask the server for every area's stored count. The reply lands in
--- M.on_retrieved.
function M.pull_counts()
    local AP_REF = _G.AP_REF
    if not (enabled and AP_REF and AP_REF.APClient) then return false end
    local keys = {}
    key_to_region = {}
    for _, region in ipairs(counter.regions()) do
        local key = storage_key(region)
        if key then
            table.insert(keys, key)
            key_to_region[key] = region
        end
    end
    if #keys == 0 then return false end

    awaiting_pull = true
    pull_started_at = os.clock()
    local ok = pcall(function() AP_REF.APClient:Get(keys) end)
    if not ok then
        awaiting_pull = false
        M.log.warn("DataStorage Get failed -- starting from the local counts")
    else
        M.log(string.format("asked the server for %d area count(s)", #keys))
    end
    return ok
end

local GOAL_GENOCIDE = 3
local GENOCIDE_GOAL_LOCATION = "Zombie Genocider: Kill 53,594 zombies across the mall"

local genocide_goal_sent = false

--- Has every area been cleared to the top of its ladder?
---
--- The Genocider goal forces the top tier, so the thresholds the counter was
--- configured with ARE the genocide ones and the last of each is what that
--- area takes to clear. Reading them back beats re-deriving the numbers from
--- shared data, which would be a second copy to keep in step.
local function all_areas_cleared()
    local any = false
    for region, list in pairs(counter.thresholds or {}) do
        local top = list[#list]
        if top then
            any = true
            if counter.count(region) < top then return false end
        end
    end
    return any
end

--- The Genocider goal, which nothing used to send.
---
--- The location exists, carries Victory and has a rule, but no runtime ever
--- told the server it had been done -- so the goal could not be won. Savior
--- and Psycho each had a module doing this; this is the missing one.
---
--- Held for the ending rather than sent here, the same as Savior.
local function check_genocide_goal(force)
    if genocide_goal_sent then return end
    local AP = _G.AP
    if not force and not (AP and tonumber(AP.Goal) == GOAL_GENOCIDE) then return end
    if not force and not all_areas_cleared() then return end

    genocide_goal_sent = true
    local ok, Ending = pcall(require, "DRAP/effects/EndingSequence")
    if ok and Ending and Ending.request_ending then
        M.log("every area cleared -- holding the Genocider goal for the ending")
        -- The mall empties as the reward: bodies everywhere on the walk back.
        Ending.request_ending(GENOCIDE_GOAL_LOCATION, { clear_mall = true })
        return
    end

    M.log("every area cleared -- sending the Genocider goal")
    if AP.AP_BRIDGE and AP.AP_BRIDGE.check then
        pcall(AP.AP_BRIDGE.check, GENOCIDE_GOAL_LOCATION)
    end
end

--- Announce a threshold: send the check and toast it.
local function announce(names)
    local AP = _G.AP
    for _, name in ipairs(names or {}) do
        if AP and AP.AP_BRIDGE and AP.AP_BRIDGE.check then
            pcall(AP.AP_BRIDGE.check, name)
        end
        if AP and AP.Notify and AP.Notify.send then
            pcall(AP.Notify.send, name)
        end
    end
    -- Every path that moves a count comes through here, so this is the one
    -- place the goal has to be tested from.
    check_genocide_goal()
end

--- Apply the kills held during the read. Also runs on timeout, so a server
--- that never answers does not strand them.
--- @return table location names that came due
-- KillSanity names waiting to go out as one packet. Never ledgered: the
-- count is their record (see KillCounter.due_kills), and a ledger entry per
-- zombie would rewrite the file on every kill.
local kill_batch = {}

local function queue_kills(kills)
    for _, name in ipairs(kills or {}) do table.insert(kill_batch, name) end
end

local function send_kill_batch()
    if #kill_batch == 0 then return end
    local AP = _G.AP
    if not (AP and AP.AP_BRIDGE and AP.AP_BRIDGE.check_batch) then return end
    local batch = kill_batch
    kill_batch = {}
    local ok, sent = pcall(AP.AP_BRIDGE.check_batch, batch)
    if not (ok and sent) then
        -- Back on the table for the next flush.
        counter.forget_sent(batch)
        for _, name in ipairs(batch) do table.insert(kill_batch, name) end
    end
end

local function drain_held()
    local due, total = {}, 0
    for region, n in pairs(held) do
        total = total + n
        local _, names, kills = counter.record_region(region, n)
        for _, name in ipairs(names) do table.insert(due, name) end
        queue_kills(kills)
    end
    held = {}
    if total > 0 then
        M.log(string.format("applied %d kill(s) held during the read", total))
    end
    return due
end

--- Count kills against a region, or hold them if the server's baseline has
--- not arrived yet.
--- @return table location names that came due (empty while holding)
local function record_kills(region, n)
    if not region then return {} end
    if not pull_settled() then
        held[region] = (held[region] or 0) + n
        return {}
    end
    -- The wait may have just timed out with kills still held; they go in
    -- first so the thresholds come out in the order they were reached.
    local due = drain_held()
    local _, names, kills = counter.record_region(region, n)
    for _, name in ipairs(names) do table.insert(due, name) end
    queue_kills(kills)
    return due
end

--- SetReply handler, forwarded from Bridge. The only direct confirmation that
--- a write landed, so it is logged rather than swallowed.
local set_reply_shape_logged = false

function M.on_set_reply(message)
    if not enabled or type(message) ~= "table" then return end
    if not set_reply_shape_logged then
        set_reply_shape_logged = true
        local fields = {}
        for k, v in pairs(message) do
            table.insert(fields, tostring(k) .. "=" .. type(v))
        end
        table.sort(fields)
        -- The reply's shape is undocumented; record it once so a mismatch is
        -- diagnosable from a log rather than by guessing.
        M.log("SetReply fields: " .. table.concat(fields, ", "))
    end
    local key = message.key
    local region = key and key_to_region[tostring(key)]
    if not region then return end
    local value = tonumber(message.value)
    M.log(string.format("server confirms %s = %s", region,
        value and string.format("%d", value) or tostring(message.value)))
    -- The server is authoritative. If it is ahead of us -- another client, or
    -- a push we made before a reload -- take its number.
    if value and counter.seed(region, value) then
        M.save()
        M.send_due()
    end
end

--- Retrieved handler. Bridge owns the real callback and forwards here, since
--- the binding allows only one.
function M.on_retrieved(...)
    if not enabled then return end

    -- The server's number per area, for the keys we asked about.
    local server = {}
    for _, candidate in ipairs({ ... }) do
        if type(candidate) == "table" then
            for key, region in pairs(key_to_region) do
                local value = candidate[key]
                if value ~= nil then server[region] = tonumber(value) or 0 end
            end
        end
    end

    local adopted = 0
    for region, value in pairs(server) do
        if counter.seed(region, value) then adopted = adopted + 1 end
    end
    awaiting_pull = false

    -- Now that the baseline is in, apply what was killed while waiting. Done
    -- after seeding so a threshold crossed by the sum still fires.
    announce(drain_held())

    -- And the other way: where the local count is ahead, push the difference.
    -- The deltas are gone by then, but the totals still say what is missing.
    counter.take_pending()
    local behind = 0
    for _, region in ipairs(counter.regions()) do
        local mine = counter.count(region)
        local theirs = server[region] or 0
        if mine > theirs then
            behind = behind + 1
            push_delta(region, mine - theirs)
        end
    end

    if adopted > 0 then
        M.log(string.format("adopted %d area count(s) from the server", adopted))
    end
    if behind > 0 then
        M.log(string.format("pushed %d area count(s) the server was missing",
            behind))
    end
    if adopted == 0 and behind == 0 then
        M.log("counts already agree with the server")
    end
    M.save()
    -- A count that arrived ahead of its checks -- a fresh save file continuing
    -- an old slot -- still owes them.
    M.send_due()
end

------------------------------------------------------------
-- Persistence + sending
------------------------------------------------------------

local function ledger()
    local ok, L = pcall(require, "DRAP/LocationLedger")
    return ok and L or nil
end

function M.save()
    local L = ledger()
    if not (L and L.is_init and L.is_init()) then return false end
    return L.set_section(LEDGER_SECTION, counter.serialize()) == true
end

function M.load()
    local L = ledger()
    if not (L and L.get_section) then return 0 end
    return counter.restore(L.get_section(LEDGER_SECTION))
end

--- Send every threshold the counts have already passed. Safe to call twice:
--- the counter only yields a name once, and the Bridge dedupes besides.
function M.send_due()
    local AP = _G.AP
    if not (AP and AP.AP_BRIDGE and AP.AP_BRIDGE.check) then return 0 end
    local due = counter.due_checks()
    for _, name in ipairs(due) do
        pcall(AP.AP_BRIDGE.check, name)
    end
    queue_kills(counter.due_kills())
    send_kill_batch()
    return #due
end

--- Write the pending kills to the ledger and push them to the server.
--- Held while the server's own counts are still in flight -- see awaiting_pull.
function M.flush()
    if not pull_settled() then
        -- The ledger is still written, so nothing is lost if the game closes
        -- before the reply lands; only the push waits.
        M.save()
        return false
    end
    local pending = counter.take_pending()
    local any = false
    for region, delta in pairs(pending) do
        if delta > 0 then
            any = true
            push_delta(region, delta)
        end
    end
    if any then M.save() end
    send_kill_batch()
    return any
end

------------------------------------------------------------
-- The hook
------------------------------------------------------------

local function on_kill()
    local scene = current_scene()
    -- Leaving an area banks it. The first kill after a move is the cheapest
    -- boundary signal there is, and keeps this off the frame loop.
    if scene ~= last_scene then
        if last_scene ~= nil then M.flush() end
        last_scene = scene
    end

    local region = counter.region_for(scene)
    if not region then return end
    local due = record_kills(region, 1)
    -- KillSanity names go out as they happen (kills in the same frame
    -- share a packet); the count push and the ledger keep their cadence.
    send_kill_batch()

    if #due > 0 then
        announce(due)
        M.flush()
    elseif counter.pending_total() >= FLUSH_EVERY then
        M.flush()
    end
end

local function install_hook()
    if installed then return true end
    local td = sdk.find_type_definition(SOLID_STORAGE)
    if not td then return false end
    local method = td:get_method("addZombieKillNum(System.UInt32)")
    if not method then
        M.log.warn("addZombieKillNum not found -- area kill checks are off")
        installed = true   -- the type is loaded and the method is not there
        return false
    end
    local ok, err = pcall(sdk.hook, method, function(args)
        pcall(on_kill)
    end, nil)
    if not ok then
        M.log.warn("could not hook addZombieKillNum: " .. tostring(err))
        return false
    end
    installed = true
    M.log("counting kills in " .. #counter.regions() .. " area(s)")
    return true
end

------------------------------------------------------------
-- Slot connect
------------------------------------------------------------

local function scene_map()
    local scenes = {}
    local ok, SharedData = pcall(require, "DRAP/SharedData")
    if ok and SharedData and SharedData.areas then
        for _, area in ipairs(SharedData.areas() or {}) do
            if area.scene_code and area.name then
                scenes[area.scene_code] = area.name
            end
        end
    end
    return scenes
end

--- @param thresholds table {region -> {n,...}} from slot data
--- @param kill_caps table|nil {region -> n} KillSanity caps from slot data
function M.configure(thresholds, kill_caps)
    counter.configure(thresholds or {}, scene_map(), kill_caps)
    configured = true
    enabled = counter.is_enabled()
    if not enabled then
        M.log("no area kill checks this seed")
        return
    end

    M.load()
    M.pull_counts()
    M.send_due()
    install_hook()
end

--- Turn the tracker on with no slot, using the tier table from
--- drdr_shared.json -- the same numbers a real seed would send.
---
--- Counting, thresholds, the tab and the toasts behave normally; the checks
--- themselves are dropped by the Bridge with no slot connected.
--- @param tier string|nil one of none/normal/nightmare/genocide
function M.debug_enable(tier)
    tier = tostring(tier or "genocide"):lower()

    local ok, SharedData = pcall(require, "DRAP/SharedData")
    local tiers = (ok and SharedData and SharedData.zombie_kill_tiers
        and SharedData.zombie_kill_tiers()) or {}
    if not next(tiers) then
        M.log.warn("drdr_shared.json has no zombie_kill_tiers -- is "
            .. "reframework/data/drdr_shared.json up to date?")
        return false
    end

    local thresholds = {}
    local known_tier = false
    for region, by_tier in pairs(tiers) do
        local list = by_tier[tier]
        if list ~= nil then
            known_tier = true
            if #list > 0 then thresholds[region] = list end
        end
    end
    if not known_tier then
        M.log.warn(string.format("'%s' is not a tier -- try none, normal, "
            .. "nightmare or genocide", tier))
        return false
    end

    M.configure(thresholds)
    M.log(string.format("debug: %s tier enabled without a slot (%d area(s))",
        tier, #counter.regions()))
    return enabled
end

_G.drap_kills_debug = function(tier)
    if M.debug_enable(tier) then
        print("[KillTracker] tier on -- open the Archipelago window, Kills tab")
    else
        print("[KillTracker] not enabled (see the log)")
    end
end

-- Connecting from the title screen gets here before SolidStorage exists, so
-- one attempt would leave the seed counting nothing. Retries until it shows
-- up, then stops -- the only per-frame work in the module.
local install_tries = 0
re.on_frame(function()
    if installed or not enabled then return end
    install_tries = install_tries + 1
    if install_tries > 3600 then
        installed = true
        M.log.warn("SolidStorage never appeared -- area kill checks are off")
        return
    end
    pcall(install_hook)
end)

------------------------------------------------------------
-- GUI + console
------------------------------------------------------------

--- Rows for the Kills tab: region, count, next threshold, final threshold.
function M.progress()
    local rows = {}
    for _, region in ipairs(counter.regions()) do
        local next_up = counter.next_threshold(region)
        table.insert(rows, {
            region = region,
            count = counter.count(region),
            next_threshold = next_up,
            done = next_up == nil,
        })
    end
    return rows
end

function M.is_enabled() return enabled end

------------------------------------------------------------
-- Debug
--
-- These add kills straight to the count and then take the same path a real
-- kill would: the check sends, the toast fires, the count is written. Not a
-- shortcut around the code being tested.
------------------------------------------------------------

--- Add kills to an area without killing anything.
--- @return number|nil the new count
function M.debug_add(region, n)
    if not enabled then
        M.log.warn("no area kill checks this seed")
        return nil
    end
    n = tonumber(n) or 100
    if not counter.has_region(region) then
        M.log.warn(string.format("'%s' is not an area with kill checks",
            tostring(region)))
        return nil
    end
    local due = record_kills(region, n)
    announce(due)
    M.flush()

    M.log(string.format("debug: +%d in %s -> %d (%d check(s) sent)",
        n, region, counter.count(region), #due))
    return counter.count(region)
end

--- Zero the local counts so a threshold can be driven again. The server keeps
--- its own, so the next pull restores them; sent checks stay sent.
function M.debug_clear_local()
    counter.reset_counts()
    M.save()
    M.log("debug: local counts cleared (the server still has its own)")
    return true
end

_G.drap_kills_add = function(region, n)
    local count = M.debug_add(region, n)
    if count then
        print(string.format("[KillTracker] %s is now at %d", region, count))
    end
end

_G.drap_kills_clear = function() M.debug_clear_local() end

--- Why the Genocider goal has or has not fired.
---
--- The goal is held until every area tops its ladder, so "nothing happened"
--- has several causes that look identical from the game. Name them.
_G.drap_genocide_status = function()
    local AP = _G.AP
    local goal = AP and tonumber(AP.Goal)
    print(string.format("[Genocide] goal=%s (needs %d) sent=%s",
        tostring(goal), GOAL_GENOCIDE, tostring(genocide_goal_sent)))
    if goal ~= GOAL_GENOCIDE then
        print("[Genocide] this seed is not a Genocider seed -- the goal will"
            .. " NOT send. drap_genocide_force() runs the chain anyway.")
    end
    local any, short = false, 0
    for region, list in pairs(counter.thresholds or {}) do
        local top = list[#list]
        if top then
            any = true
            local have = counter.count(region)
            local done = have >= top
            if not done then short = short + 1 end
            print(string.format("[Genocide]   %-24s %6d / %-6d %s",
                region, have, top, done and "CLEARED" or ""))
        end
    end
    if not any then
        print("[Genocide] no thresholds configured -- run"
            .. " drap_kills_debug(\"genocide\") first")
        return false
    end
    print(string.format("[Genocide] %s (%d area(s) short)",
        short == 0 and "ALL AREAS CLEARED" or "not cleared", short))
    return short == 0
end

--- Run the goal chain regardless of this seed's goal or the counts.
---
--- Exists so the Savior/Genocide ending hand-off can be exercised without
--- regenerating a seed as Genocider. It takes the same path the real trigger
--- does, including the hold for EndingSequence.
_G.drap_genocide_force = function()
    print("[Genocide] forcing the goal chain (ignoring goal and counts)")
    check_genocide_goal(true)
end

--- What the server side of this is actually doing. The counts alone cannot
--- show whether a write landed, so this reports the plumbing.
_G.drap_kills_sync = function()
    local AP_REF = _G.AP_REF
    local connected = (AP_REF and AP_REF.APClient) ~= nil
    print(string.format("[KillTracker] enabled=%s client=%s awaiting_pull=%s",
        tostring(enabled), tostring(connected), tostring(awaiting_pull)))
    print(string.format("[KillTracker] Set signature: %s",
        set_variant and SET_VARIANTS[set_variant].name or "not established yet"))
    print(string.format("[KillTracker] writes ok=%d failed=%d, unpushed=%d",
        pushed_ok, pushed_failed, counter.pending_total()))
    local key = storage_key(counter.regions()[1] or "")
    print(string.format("[KillTracker] key format: %s", tostring(key)))
end

function M.draw_tab_content(debug)
    if not enabled then
        -- Say which kind of nothing this is. "No tab" and "empty tab" both
        -- read as broken; naming the reason does not.
        if not configured then
            imgui.text_colored("No slot connected yet, so no tier is known.",
                0xFF888888)
        else
            imgui.text_colored("This seed has no area kill checks.", 0xFF888888)
        end
        if debug then
            imgui.separator()
            imgui.text_colored(
                "Turn it on without a slot to test in vanilla:", 0xFF66CCFF)
            for _, tier in ipairs({ "normal", "nightmare", "genocide" }) do
                if imgui.button(tier .. "##kills_tier") then
                    M.debug_enable(tier)
                end
                imgui.same_line()
            end
            imgui.text("")
            imgui.text_colored('  or: drap_kills_debug("genocide")', 0xFF888888)
        end
        return
    end

    imgui.text_colored(
        "Zombies killed per area. Kills count where you are standing.",
        0xFF888888)
    imgui.separator()

    if debug then
        imgui.text_colored(
            "Debug: +N adds kills for real -- the check sends and the count "
            .. "is written.", 0xFF66CCFF)
    end

    imgui.begin_child_window("KillList", Vector2f.new(0, 0), true, 0)
    for _, row in ipairs(M.progress()) do
        if row.done then
            imgui.text_colored(string.format("%-24s %7d  all done",
                row.region, row.count), 0xFF66CC66)
        else
            local remaining = row.next_threshold - row.count
            imgui.text(string.format("%-24s %7d / %-7d (%d to go)",
                row.region, row.count, row.next_threshold, remaining))
        end

        if debug then
            imgui.same_line()
            if imgui.button("+100##kills_" .. row.region) then
                M.debug_add(row.region, 100)
            end
            imgui.same_line()
            -- Whatever it takes to cross the next line, so one click proves
            -- the check, the toast and the write in one go.
            if imgui.button("+next##kills_" .. row.region) then
                if row.next_threshold then
                    M.debug_add(row.region, row.next_threshold - row.count)
                end
            end
        end
    end
    imgui.end_child_window()

    if debug then
        imgui.separator()
        imgui.text(string.format("pending=%d scene=%s",
            counter.pending_total(), tostring(last_scene)))
        if imgui.button("Flush now") then M.flush() end
        imgui.same_line()
        if imgui.button("Pull from server") then M.pull_counts() end
        imgui.same_line()
        if imgui.button("Clear local counts") then M.debug_clear_local() end
    end
end

_G.drap_kills = function()
    if not enabled then
        print("[KillTracker] no area kill checks this seed")
        return
    end
    for _, row in ipairs(M.progress()) do
        print(string.format("[KillTracker] %-24s %6d / %s", row.region,
            row.count, row.done and "done" or tostring(row.next_threshold)))
    end
end

return M
