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

function M.banked(item_name)
    return math.max(0, received_count(item_name) - (consumed[item_name] or 0))
end

function M.total_banked()
    local n = 0
    for _, name in ipairs(order) do n = n + M.banked(name) end
    return n
end

function M.on_frame()
    if not M:should_run() then return end
    if not Ledger.is_init() then return end
    if not loaded then M.load() end
    if not Shared.is_in_game() then
        -- Out of gameplay: the next entry restarts the settle clock.
        was_in_game = false
        return
    end

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
