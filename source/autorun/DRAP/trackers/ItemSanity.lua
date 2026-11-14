-- DRAP/trackers/ItemSanity.lua
-- ItemSanity: the first pickup of each item type sends "Pick up <item>".
--
-- Measured in game: every pickup goes through Inventory.PickItem(Item,
-- Boolean) once and returns true, a grab off a shelf as well as an item off
-- the floor, and the Item argument carries the item number (Item.ItemNo).
-- A shelf grab also calls PlayerCondition.getShelfItem, which adds nothing,
-- so it is not hooked. PickItem's address is unique in the dump, not a
-- folded stub.
--
-- The hooks only read the number and queue it. The check is sent from the
-- frame, never from inside the game's call. Whether a type was already sent
-- is the location's own checked state (ledger and server), so a reload or a
-- second pickup sends nothing.
--
-- The item types, their numbers and their locations come from
-- drdr_shared.json item_sanity, the same list the apworld builds from.

local Shared = require("DRAP/Shared")
local SharedData = require("DRAP/SharedData")

local M = Shared.create_module("ItemSanity")

local INVENTORY_T = "app.solid.character.player.Inventory"

local enabled = false
local location_of = nil     -- item number -> location name
local queue = {}            -- item numbers from the hooks, drained on the frame
local pick_no = nil         -- PickItem's item, from its pre-hook to its post-hook
local sent = {}             -- location name -> true, sent this session
local installed = false
local install_tries = 0
local stats = { picks = 0, picks_refused = 0, sent = 0, repeats = 0, unlisted = 0 }

------------------------------------------------------------
-- The list
------------------------------------------------------------

--- item number -> location name, from the shared item_sanity entries.
--- @param entries table|nil
--- @return table
function M.build_map(entries)
    local map = {}
    for _, e in ipairs(entries or {}) do
        local name = e.location_name
        if type(name) == "string" and name ~= "" then
            for _, no in ipairs(e.item_numbers or {}) do
                no = tonumber(no)
                if no then map[no] = name end
            end
        end
    end
    return map
end

local function item_map()
    if not location_of then
        location_of = M.build_map(SharedData.item_sanity and SharedData.item_sanity() or {})
    end
    return location_of
end

--- @param item_no number
--- @return string|nil the location this item number counts for
function M.location_for(item_no)
    return item_map()[tonumber(item_no) or -1]
end

------------------------------------------------------------
-- The hooks
------------------------------------------------------------

--- One pickup seen by a hook. Pure Lua: runs inside the game's call.
--- @param item_no number|nil
function M.on_pickup(item_no)
    if not enabled then return end
    item_no = tonumber(item_no)
    if not item_no or item_no <= 0 then return end
    queue[#queue + 1] = item_no
end

local function field(obj, name)
    local ok, v = pcall(obj.get_field, obj, name)
    if ok then return v end
    return nil
end

--- The item number of PickItem's Item argument. Field reads only.
local function item_number_of(item)
    if not item then return nil end
    local no = tonumber(field(item, "ItemNo"))
    if no then return no end
    local u = field(item, "<uItem>k__BackingField")
    return u and tonumber(field(u, "mItemNo")) or nil
end

local function install_hooks()
    if installed then return end
    install_tries = install_tries + 1
    local inv = sdk.find_type_definition(INVENTORY_T)
    local pick = inv and inv:get_method("PickItem")
    if not pick then
        if install_tries > 600 then
            installed = true
            M.log.warn("PickItem not found -- ItemSanity sends nothing")
        end
        return
    end
    installed = true

    local ok, err = pcall(sdk.hook, pick,
        function(args)
            pick_no = nil
            if not enabled then return end
            local item = Shared.safe(sdk.to_managed_object, args[3])
            pick_no = item_number_of(item)
            -- Restricted Item Mode refuses what was not sent, and its answer
            -- must decide the check whichever hook ran first (a skipped call
            -- leaves no reliable return value to read afterwards).
            local r = _G.AP and _G.AP.ItemRestriction
            if pick_no and r and r.is_enabled and r.is_enabled()
                and r.is_allowed and not r.is_allowed(pick_no) then
                stats.picks_refused = stats.picks_refused + 1
                pick_no = nil
            end
        end,
        function(retval)
            -- False is a pickup someone refused, so it is not counted.
            if pick_no then
                if (Shared.to_int(retval) or 0) & 1 == 1 then
                    stats.picks = stats.picks + 1
                    M.on_pickup(pick_no)
                else
                    stats.picks_refused = stats.picks_refused + 1
                end
                pick_no = nil
            end
            return retval
        end)

    if ok then
        M.log("watching PickItem")
    else
        M.log.warn("PickItem hook failed: " .. tostring(err))
    end
end

------------------------------------------------------------
-- Sending
------------------------------------------------------------

local function bridge()
    return _G.AP and _G.AP.AP_BRIDGE or nil
end

--- Send the queued pickups. A type already sent, here or in an earlier
--- session, sends nothing.
--- @param b table|nil the bridge (check, is_check_recorded)
--- @return number checks sent
function M.drain(b)
    if #queue == 0 then return 0 end
    local q = queue
    queue = {}
    b = b or bridge()
    if not b then return 0 end
    local n = 0
    for _, no in ipairs(q) do
        local name = M.location_for(no)
        if not name then
            stats.unlisted = stats.unlisted + 1
        elseif sent[name] or (b.is_check_recorded and b.is_check_recorded(name)) then
            stats.repeats = stats.repeats + 1
        else
            sent[name] = true
            stats.sent = stats.sent + 1
            n = n + 1
            M.log(string.format("first pickup of item %d: %s", no, name))
            b.check(name)
        end
    end
    return n
end

function M.set_enabled(on)
    enabled = on == true
    if not enabled then queue = {} end
    M.log("ItemSanity " .. (enabled and "on" or "off"))
end

function M.is_enabled() return enabled end

function M.on_frame()
    if not enabled then return end
    if not installed then install_hooks() end
    M.drain()
end

function M.status()
    local s = { enabled = enabled, installed = installed, queued = #queue }
    for k, v in pairs(stats) do s[k] = v end
    return s
end

_G.drap_itemsanity = function()
    local s = M.status()
    local parts = {}
    for k, v in pairs(s) do parts[#parts + 1] = k .. "=" .. tostring(v) end
    table.sort(parts)
    M.log(table.concat(parts, " "))
    return s
end

return M
