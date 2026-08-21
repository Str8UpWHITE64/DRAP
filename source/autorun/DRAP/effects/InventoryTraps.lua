-- DRAP/effects/InventoryTraps.lua
-- Traps that go after what the player is carrying.
--
--   Butterfingers Trap            everything hits the floor
--   Last Shot Trap                everything is one hit from breaking
--   Where'd Your Inventory Go?    everything shatters
--
-- Three rules learned in game, each of which cost a rewrite:
--
-- 1. `Inventory.removeItem(itemNo)` DROPS the item rather than deleting it,
--    carrying durability and ammo with it. That makes Butterfingers a plain
--    removal loop -- recording and respawning produced two of everything,
--    because the second copy was the original.
--
-- 2. `setDurability` is an INITIALISER: it drags max down to match, so an item
--    set to 25 reads 25/25 and the gauge shows FULL while breaking in two
--    hits. Writing `mDurability` on the uItem's own ITEM_SAVE_WORK sets
--    current only, and that is the copy an inventory slot syncs from.
--
-- 3. Breaking needs the inventory to have ticked. Zeroing durability and
--    calling processCurrentItemBroken in the same frame fails every time, and
--    pairing "zero the held item" with "break the current item" desynchronises
--    after the first break. Zero every slot first, then pop breaks.
--
-- And one hard limit: processCurrentItemBroken must be called with
-- noClash=false, or the game dies inside Wwise a few seconds later. See the
-- note on break_no_clash below. BREAK_INTERVAL spaces the breaks out too,
-- which reads better and keeps the audio comfortable.
--
-- ItemRestriction.lua documents why the other inventory calls are unusable
-- (clearItem silently does nothing, dropItem corrupts the slot). Read it
-- before adding anything here.

local Shared = require("DRAP/Shared")
local ItemEffects = require("DRAP/ItemEffects")
local TrapBank = require("DRAP/TrapBank")

local M = Shared.create_module("InventoryTraps")

local PM_TYPE = "app.solid.PlayerManager"
local pm_mgr = M:add_singleton("pm", PM_TYPE)

local BUTTERFINGERS = "Butterfingers Trap"
local LAST_SHOT     = "Last Shot Trap"
local VANISH        = "Where'd Your Inventory Go? Trap"

-- Frames between destructive steps. The break interval is the one that keeps
-- Wwise alive; the removal interval is because inventory writes need a tick to
-- settle before the next one reads a correct held count.
local REMOVE_INTERVAL = 3
local BREAK_INTERVAL  = 24
local ZERO_SETTLE     = 3
local MAX_STALL       = 12      -- attempts on one item before giving up
local MAX_FRAMES      = 3000    -- absolute ceiling on any one trap run

-- processCurrentItemBroken(checkSub, noClash).
--
-- noClash MUST be false. With it true nothing audible happens and the game
-- dies seconds later inside Wwise, a dozen recursive AK frames deep -- the
-- break event is posted but never resolves. With it false every break plays
-- its sound and the trap is stable. The silence was the tell: a Wwise crash
-- with no sound is an event that never resolved, not an overloaded mixer.
local break_check_sub = false
local break_no_clash  = false

------------------------------------------------------------
-- Inventory access
------------------------------------------------------------

local function inventory()
    local pm = pm_mgr:get()
    if not pm then return nil end
    return Shared.safe(function() return pm:call("get_Inventory") end)
end

local function held_count(inv)
    local n = Shared.safe(function() return inv:call("get_CurrentItemNumbers") end)
    return n and Shared.to_int(n) or nil
end

local function max_slot(inv)
    local n = Shared.safe(function() return inv:call("get_MaxSlot") end)
    return (n and Shared.to_int(n)) or 8
end

--- The uItem's own ITEM_SAVE_WORK -- the authoritative copy. The one hanging
--- off the slot is downstream and gets overwritten by a resync.
local function item_save_work(item)
    local u = Shared.safe(function() return item:call("get_uItem") end)
    if not u then return nil end
    return Shared.safe(function() return u:get_field("mItemSaveWork") end)
end

--- Current durability and ammo, never max: writing max is what makes the
--- gauge read full on a nearly broken item.
local function set_current(item, durability, ammo)
    local sw = item_save_work(item)
    if not sw then return false end
    if durability then
        Shared.safe(function() sw:set_field("mDurability", durability) end)
    end
    if ammo then
        Shared.safe(function() sw:set_field("mDurabilitySub", ammo) end)
    end
    return true
end

--- Walks occupied slots, calling fn(slot, item, save_work, item_no).
local function each_occupied_slot(inv, fn)
    for i = 0, max_slot(inv) - 1 do
        local slot = Shared.safe(function() return inv:call("getItemSlot", i) end)
        local item = slot and Shared.get_field_value(slot, { "Item" })
        if item then
            -- A slot does not carry the item number; its SAVE_WORK does.
            local slot_sw = Shared.get_field_value(slot, { "SAVE_WORK" })
            local no = slot_sw and Shared.get_field_value(slot_sw, { "mItemNo" })
            fn(slot, item, slot_sw, no and Shared.to_int(no) or nil)
        end
    end
end

------------------------------------------------------------
-- Trap state
------------------------------------------------------------
-- One trap at a time. TrapBank retries a declined fire, so a trap arriving
-- mid-run is banked rather than dropped.

local active = nil      -- { kind, queue, wait, tries, zeroed, done, frames }

local function busy() return active ~= nil end

local function notify(text)
    local Notify = package.loaded["DRAP/Notify"]
    if Notify and Notify.send then
        pcall(Notify.send, text, { duration = 5.0 })
    end
end

------------------------------------------------------------
-- Butterfingers: drop everything
------------------------------------------------------------
-- removeItem takes the number BY VALUE and leaves the inventory consistent.
-- It also drops rather than deletes, which is exactly what this trap wants --
-- the items keep their durability and ammo because they ARE the originals.

local function start_butterfingers(inv)
    local queue = {}
    each_occupied_slot(inv, function(_, _, _, no)
        if no and no ~= 0 then queue[#queue + 1] = no end
    end)
    if #queue == 0 then return false end
    active = { kind = "drop", queue = queue, wait = 0, done = 0, frames = 0,
               stall = 0 }
    M.log(string.format("butterfingers: dropping %d item(s)", #queue))
    notify("You fumble everything you were carrying!")
    return true
end

local function step_butterfingers(inv)
    local no = active.queue[1]
    if not no then
        M.log(string.format("butterfingers done -- %d dropped", active.done))
        return true
    end
    table.remove(active.queue, 1)

    local before = held_count(inv)
    Shared.safe(function() inv:call("removeItem", no) end)
    local after = held_count(inv)
    if before and after and after < before then
        active.done = active.done + 1
    else
        -- Not fatal: the slot may already have been emptied by the player.
        M.log(string.format("butterfingers: item %s did not leave the inventory",
            tostring(no)))
    end
    active.wait = REMOVE_INTERVAL
    return false
end

------------------------------------------------------------
-- Last Shot: everything one hit from breaking
------------------------------------------------------------
-- A single pass, no staging: nothing is destroyed, so there is no bookkeeping
-- for the engine to catch up on. Max is deliberately untouched so the gauge
-- reads nearly empty rather than full.

local function fire_last_shot(inv)
    local n, guns = 0, 0
    each_occupied_slot(inv, function(_, item)
        local u = Shared.safe(function() return item:call("get_uItem") end)
        if not u then return end
        local has = Shared.safe(function() return u:call("isDurability") end)
        if has ~= true then return end

        -- Ammo only where there is ammo to spend, so a melee weapon's sub
        -- value is left alone.
        local sub = Shared.safe(function() return u:call("getDurabilitySub") end)
        sub = sub and Shared.to_int(sub) or nil
        local set_ammo = (sub and sub > 1) and 1 or nil
        if set_ammo then guns = guns + 1 end

        if set_current(item, 1, set_ammo) then n = n + 1 end
    end)
    if n == 0 then return false end
    M.log(string.format("last shot: %d item(s) set to 1 durability (%d with ammo)",
        n, guns))
    notify("Everything you carry is about to break.")
    return true
end

------------------------------------------------------------
-- Where'd Your Inventory Go?: break everything
------------------------------------------------------------
-- Zero EVERY slot first, then pop breaks. Pairing per-item zeroing with
-- per-item breaking desynchronised: getFirstItem is slot order while
-- processCurrentItemBroken acts on whatever is equipped, and after the first
-- break those stop agreeing -- every other item then refused to break.

local function start_vanish(inv)
    if (held_count(inv) or 0) == 0 then return false end
    active = { kind = "break", wait = 0, tries = 0, zeroed = false, done = 0,
               frames = 0 }
    notify("Your inventory shatters!")
    return true
end

local function step_vanish(inv)
    if not active.zeroed then
        local n = 0
        each_occupied_slot(inv, function(_, item, slot_sw)
            if set_current(item, 0, 0) then n = n + 1 end
            -- The slot copy too, so a resync cannot undo it.
            if slot_sw then
                Shared.safe(function() slot_sw:set_field("mDurability", 0) end)
            end
        end)
        active.zeroed = true
        active.wait = ZERO_SETTLE
        M.log(string.format("vanish: spent %d slot(s), breaking", n))
        return false
    end

    local before = held_count(inv)
    if not before or before == 0 then
        M.log(string.format("vanish done -- %d broken", active.done))
        return true
    end

    -- Log the item BEFORE breaking it. The crash is a stack overflow inside
    -- Wwise (a dozen recursive AK::WriteBytesCount::SetCount frames), it
    -- arrives seconds late, and it took several firings to show up -- so the
    -- last line written before a crash is the only way to pin it on a
    -- specific item rather than on the count or the cadence.
    local held = Shared.safe(function() return inv:call("getFirstItem") end)
    local held_no
    if held then
        local sw = item_save_work(held)
        local v = sw and Shared.get_field_value(sw, { "mItemNo" })
        held_no = v and Shared.to_int(v) or nil
    end
    M.log(string.format("vanish: breaking item_no=%s (%d left)",
        tostring(held_no), before))

    Shared.safe(function()
        inv:call("processCurrentItemBroken(System.Boolean, System.Boolean)",
            break_check_sub, break_no_clash)
    end)
    local after = held_count(inv)

    if after and after < before then
        active.done = active.done + 1
        active.tries = 0
    else
        active.tries = active.tries + 1
        if active.tries >= MAX_STALL then
            -- Whatever will not break gets dropped instead. Losing the visual
            -- on one item beats leaving the trap half-applied.
            local no
            each_occupied_slot(inv, function(_, _, _, slot_no)
                no = no or slot_no
            end)
            if no then
                Shared.safe(function() inv:call("removeItem", no) end)
                M.log(string.format("vanish: item %s would not break, dropped",
                    tostring(no)))
            end
            active.tries = 0
            if not no then
                M.log("vanish: nothing left that can be removed, stopping")
                return true
            end
        end
    end

    -- Load-bearing: breaks any faster than this crash the game inside Wwise.
    active.wait = BREAK_INTERVAL
    return false
end

------------------------------------------------------------
-- Frame driver
------------------------------------------------------------

function M.on_frame()
    if not active then return end
    if not Shared.is_in_game() then
        -- An area transition mid-run would act on a stale inventory.
        M.log("inventory trap abandoned -- left the game world")
        active = nil
        return
    end

    active.frames = active.frames + 1
    if active.frames > MAX_FRAMES then
        M.log(string.format("inventory trap (%s) timed out after %d frames",
            tostring(active.kind), active.frames))
        active = nil
        return
    end

    if active.wait > 0 then
        active.wait = active.wait - 1
        return
    end

    local inv = inventory()
    if not inv then return end

    local finished
    if active.kind == "drop" then
        finished = step_butterfingers(inv)
    else
        finished = step_vanish(inv)
    end
    if finished then active = nil end
end

------------------------------------------------------------
-- Registration
------------------------------------------------------------
-- fire() returns false to decline: TrapBank keeps it banked and retries, so a
-- trap that lands with an empty inventory or during another run is not wasted.

local function guarded(start_fn)
    return function()
        if busy() then return false end
        if not Shared.is_in_game() then return false end
        local inv = inventory()
        if not inv then return false end
        if (held_count(inv) or 0) == 0 then return false end
        return start_fn(inv) ~= false
    end
end

function M.register()
    TrapBank.register(BUTTERFINGERS, { fire = guarded(start_butterfingers) })
    TrapBank.register(LAST_SHOT,     { fire = guarded(fire_last_shot) })
    TrapBank.register(VANISH,        { fire = guarded(start_vanish) })

    -- Logs the arrival where every other item's is; TrapBank does the work.
    for _, name in ipairs({ BUTTERFINGERS, LAST_SHOT, VANISH }) do
        ItemEffects.register(name, {
            on_replay = "skip",
            apply = function()
                M.log(string.format("%s banked (%d owed)", name,
                    TrapBank.banked(name)))
            end,
        })
    end
end

--- Console helpers, so each trap can be fired without waiting on a seed.
_G.drap_trap_butterfingers = function()
    local inv = inventory()
    if not inv then M.log("no Inventory"); return end
    if busy() then M.log("a trap is already running"); return end
    start_butterfingers(inv)
end

_G.drap_trap_lastshot = function()
    local inv = inventory()
    if not inv then M.log("no Inventory"); return end
    fire_last_shot(inv)
end

--- Try the other processCurrentItemBroken flag combinations. The default is
--- (checkSub=false, noClash=true); if noClash is what leaks the sound, (false,
--- false) should survive where the default does not.
_G.drap_trap_break_flags = function(check_sub, no_clash)
    break_check_sub = (check_sub == true)
    break_no_clash  = (no_clash ~= false)
    M.log(string.format("processCurrentItemBroken(checkSub=%s, noClash=%s)",
        tostring(break_check_sub), tostring(break_no_clash)))
end

_G.drap_trap_vanish = function()
    local inv = inventory()
    if not inv then M.log("no Inventory"); return end
    if busy() then M.log("a trap is already running"); return end
    start_vanish(inv)
end

return M
