-- DRAP/TrapBank.lua
-- Traps are owed, not fired on arrival. One that lands at the title screen or
-- somewhere it can't spawn used to be lost outright; hostile ones queued in
-- memory and were dropped after ten minutes. Here they wait, and drain one at
-- a time once the player can take them.
--
--     banked(item) = bridge:count_item_name(item) - consumed[item]
--
-- Only consumed is persisted. The received side is the bridge's lifetime
-- count, which replays deliberately do NOT increment -- so a subtraction is
-- safe where a running tally would pay every trap out again on reconnect.
--
-- A run predating this file has no tallies, so the first load marks everything
-- already received as paid. Without that it would fire a whole run's traps at
-- once.

local Shared = require("DRAP/Shared")
local Ledger = require("DRAP/LocationLedger")
local PlayerReady = require("DRAP/PlayerReady")

local M = Shared.create_module("TrapBank")
M:set_throttle(1.0)

local SECTION = "trap_bank"

-- One trap at a time, and well clear of each other. Raised from 8s after a
-- server !collect delivered nine items at once: two traps landed together, the
-- second fired 8s behind the first and the game went down. Traps do heavy
-- things -- emptying an inventory, breaking every item, re-dressing the player
-- -- and the engine needs room to settle between them.
local FIRE_INTERVAL_SECONDS = 30.0

local registry = {}      -- item_name -> { can_fire = fn|nil, fire = fn, label }
local order = {}         -- registration order, so draining is deterministic
local consumed = {}      -- item_name -> count already paid out
local loaded = false
local last_fire_at = 0
-- Nothing fires until the world has been settled this long after an area
-- change. Butterfingers emptied an inventory and nothing landed: the trap went
-- off about a second after the player walked into s136 with an escort, while
-- SceneFixups was still patching that scene (it rewrites mAreaIndex on the way
-- in). removeItem DROPS rather than deletes, so the items had to be PLACED,
-- and placing into a scene mid-fixup is where they went.
local WORLD_SETTLE_SECONDS = 8.0
local last_area_index = nil
local world_ready_at = nil
local was_in_game = false

-- TrapLink. A trap another game sent is NOT an owed item: it never touches
-- consumed[], lives only in memory, and is dropped if it cannot land soon.
-- It drains through the same 30 s gate as everything else, ahead of banked
-- item traps, and only while Frank is ready (PlayerReady).
local LINK_QUEUE_MAX = 3          -- newest wins when full
local LINK_EXPIRY_SECONDS = 120.0
local LINK_WINDOW_SECONDS = 300.0
local LINK_MAX_PER_WINDOW = 4     -- linked fires per window
local LINK_SAME_TRAP_GAP = 60.0   -- the same trap twice, at least this far apart
local linked = {}                 -- { name, source, at }
local link_fires = {}             -- os.clock() of recent linked fires
local link_last = {}              -- trap name -> last linked fire

--- Set by TrapLink.lua. Called with the trap name after an ITEM trap paid out
--- cleanly (never for a linked one), so it can be sent on.
M.on_item_fired = nil
--- Called just before a linked trap fires.
M.on_link_fire = nil
--- Return false to hold a linked trap back (e.g. the same timed effect is
--- already running).
M.link_gate = nil

------------------------------------------------------------
-- Registration
------------------------------------------------------------

--- @param item_name string the AP item
--- @param opts table { fire = function() -> boolean, can_fire = function() -> boolean }
---   fire returns false to decline THIS attempt (nothing is consumed, it is
---   retried later) -- e.g. no safe spawn target right now.
function M.register(item_name, opts)
    if type(item_name) ~= "string" or type(opts) ~= "table"
        or type(opts.fire) ~= "function" then
        M.log.warn("TrapBank.register needs an item name and a fire function")
        return
    end
    if not registry[item_name] then order[#order + 1] = item_name end
    registry[item_name] = {
        fire = opts.fire,
        can_fire = opts.can_fire,
        label = opts.label or item_name,
    }
end

------------------------------------------------------------
-- Persistence
------------------------------------------------------------

local function received_count(item_name)
    local bridge = AP and AP.AP_BRIDGE
    if not (bridge and bridge.count_item_name) then return 0 end
    local ok, n = pcall(bridge.count_item_name, item_name)
    return (ok and tonumber(n)) or 0
end

local function save()
    if not Ledger.is_init() then return end
    Ledger.set_section(SECTION, { consumed = consumed })
end

--- Load the paid-out tallies, or seed them on a run that predates this file.
function M.load()
    consumed = {}
    loaded = false
    if not Ledger.is_init() then return end

    local doc = Ledger.get_section(SECTION)
    if type(doc) == "table" and type(doc.consumed) == "table" then
        for name, n in pairs(doc.consumed) do
            consumed[name] = tonumber(n) or 0
        end
        loaded = true
        M.log("trap bank loaded")
        return
    end

    -- No section: pre-existing run. Everything already received counts as
    -- paid, or the player is about to eat every trap of their run at once.
    local seeded = 0
    for _, name in ipairs(order) do
        local n = received_count(name)
        consumed[name] = n
        seeded = seeded + n
    end
    save()
    loaded = true
    M.log(string.format(
        "trap bank initialised for an existing run -- %d previously received"
            .. " trap(s) marked as already applied", seeded))
end

------------------------------------------------------------
-- The bank
------------------------------------------------------------

--- Queue a trap that arrived over TrapLink. Returns true if it was queued.
function M.enqueue_link(item_name, source)
    if not registry[item_name] then
        M.log.warn("TrapLink: " .. tostring(item_name) .. " is not a registered trap")
        return false
    end
    linked[#linked + 1] = { name = item_name, source = source, at = os.clock() }
    while #linked > LINK_QUEUE_MAX do
        local dropped = table.remove(linked, 1)
        M.log(string.format("linked %s from %s dropped (queue full)",
            dropped.name, tostring(dropped.source)))
    end
    M.log(string.format("linked %s from %s queued (%d waiting)",
        item_name, tostring(source), #linked))
    return true
end

function M.pending_links() return #linked end

--- Testing: forget every pending linked trap and the rate history.
function M.reset_links()
    linked, link_fires, link_last = {}, {}, {}
end

local function try_linked(now)
    for i = #linked, 1, -1 do
        if now - linked[i].at > LINK_EXPIRY_SECONDS then
            M.log(string.format("linked %s from %s expired",
                linked[i].name, tostring(linked[i].source)))
            table.remove(linked, i)
        end
    end
    if #linked == 0 then return false end

    for i = #link_fires, 1, -1 do
        if now - link_fires[i] > LINK_WINDOW_SECONDS then table.remove(link_fires, i) end
    end
    if #link_fires >= LINK_MAX_PER_WINDOW then return false end
    if not PlayerReady.ready() then return false end

    for i, e in ipairs(linked) do
        local last = link_last[e.name]
        local spaced = not (last and (now - last) < LINK_SAME_TRAP_GAP)
        local open = true
        if spaced and M.link_gate then
            local ok, v = pcall(M.link_gate, e.name)
            open = ok and v ~= false
        end
        local entry = registry[e.name]
        if spaced and open and entry then
            local allowed = true
            if entry.can_fire then
                local ok, v = pcall(entry.can_fire)
                allowed = ok and v ~= false
            end
            if allowed then
                if M.on_link_fire then pcall(M.on_link_fire, e.name) end
                local ok, fired = pcall(entry.fire)
                if ok and fired ~= false then
                    table.remove(linked, i)
                    link_fires[#link_fires + 1] = now
                    link_last[e.name] = now
                    last_fire_at = now
                    M.log(string.format("%s applied from TrapLink (%s)",
                        entry.label, tostring(e.source)))
                    return true
                elseif not ok then
                    M.log.warn(string.format(
                        "linked %s failed to apply -- staying queued", entry.label))
                end
            end
        end
    end
    return false
end

function M.banked(item_name)
    return math.max(0, received_count(item_name) - (consumed[item_name] or 0))
end

function M.total_banked()
    local n = 0
    for _, name in ipairs(order) do n = n + M.banked(name) end
    return n
end

-- Out of gameplay, the next entry restarts the settle clock. Caught here
-- rather than in on_frame: the main loop does not tick modules outside the
-- game, so on_frame never saw it, and a save loaded into the same area (same
-- area index) skipped the settle wait entirely.
re.on_frame(function()
    if not Shared.is_in_game() then was_in_game = false end
end)

function M.on_frame()
    if not M:should_run() then return end
    if not Ledger.is_init() then return end
    if not loaded then M.load() end
    if not Shared.is_in_game() then return end

    local now = os.clock()

    -- Restart the settle clock whenever the world changes underfoot: a new
    -- area, or the player being (re)spawned.
    local area_index = Shared.safe(function()
        local am = sdk.get_managed_singleton("app.solid.gamemastering.AreaManager")
        return am and am:get_field("mAreaIndex")
    end)
    if area_index ~= nil and area_index ~= last_area_index then
        last_area_index = area_index
        world_ready_at = now
    end
    if not was_in_game then
        was_in_game = true
        world_ready_at = now
    end

    if world_ready_at and (now - world_ready_at) < WORLD_SETTLE_SECONDS then
        return
    end
    if (now - last_fire_at) < FIRE_INTERVAL_SECONDS then return end

    if try_linked(now) then return end

    for _, name in ipairs(order) do
        if M.banked(name) > 0 then
            local entry = registry[name]
            local allowed = true
            if entry.can_fire then
                local ok, v = pcall(entry.can_fire)
                allowed = ok and v ~= false
            end
            if allowed then
                local ok, fired = pcall(entry.fire)
                -- Only a clean fire is paid for; anything else leaves the
                -- debt standing to be retried.
                if ok and fired ~= false then
                    consumed[name] = (consumed[name] or 0) + 1
                    save()
                    last_fire_at = now
                    M.log(string.format("%s applied (%d still banked)",
                        entry.label, M.banked(name)))
                    if M.on_item_fired then pcall(M.on_item_fired, name) end
                    return          -- one per interval
                elseif not ok then
                    M.log.warn(string.format(
                        "%s failed to apply -- staying banked", entry.label))
                end
            end
        end
    end
end

------------------------------------------------------------
-- Console
------------------------------------------------------------

_G.drap_trap_bank = function()
    if not Ledger.is_init() then M.log("ledger not initialised (connect first)"); return end
    if not loaded then M.load() end
    M.log("trap bank:")
    for _, name in ipairs(order) do
        M.log(string.format("  %-24s received=%d consumed=%d banked=%d",
            name, received_count(name), consumed[name] or 0, M.banked(name)))
    end
    M.log(string.format("  total banked: %d  (one fires every %.0fs while in game)",
        M.total_banked(), FIRE_INTERVAL_SECONDS))
end

return M
