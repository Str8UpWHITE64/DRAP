-- DRAP/ItemEffects.lua
-- Declarative item-effect registry.
--
-- When the AP bridge receives an item, it calls ItemEffects.dispatch(...).
-- Dispatch looks up a handler by item id, then by name, then falls back to a
-- category handler if the entry has one. Each entry may declare an on_replay
-- policy ("apply" or "skip") controlling what happens when the bridge replays
-- previously-received items on reconnect.
--
-- This module replaces the ad hoc name/id handler tables that used to live in
-- DRAP/Bridge.lua. The bridge now owns just the reception + replay plumbing;
-- all "what does this item do" logic lives in DRAP/effects/ files that call
-- ItemEffects.register(...) at require time.
--
-- Registration API:
--
--   ItemEffects.register(name, {
--     apply = function(ctx) ... end,         -- required unless the entry is only
--                                             --   a category tag (see below)
--     on_replay = "apply" | "skip",           -- optional (see resolution rules)
--     category = "TRAP"|"REWARD"|...,         -- optional; enables category fallback
--   })
--
--   ItemEffects.register_by_id(id, entry)     -- same shape, keyed by numeric id
--
--   ItemEffects.register_category("TRAP", {
--     apply = function(ctx) ... end,          -- required
--     on_replay = "apply" | "skip",           -- optional (default "apply")
--   })
--
--   ItemEffects.tag_item_category(name, "TRAP")
--     -- Lightweight way to say "this item is a TRAP" without defining a
--     -- per-item apply. Useful when a single category handler covers many
--     -- items. If a full entry already exists for `name`, its category field
--     -- is set only if previously nil.
--
-- Dispatch resolution:
--
--   entry           = ID_HANDLERS[id] or NAME_HANDLERS[name]  (id wins)
--   category_entry  = entry.category and CATEGORY_HANDLERS[entry.category]
--
--   apply_fn  = entry.apply       or category_entry.apply
--   on_replay = entry.on_replay   or category_entry.on_replay  or "apply"
--
--   if is_replay and on_replay == "skip": return true (handled by skipping)
--   if apply_fn: call apply_fn(ctx); return true
--   else: return false (bridge logs "unhandled")
--
-- ctx = { net_item, item_name, sender_name, is_replay }

local M = {}

local NAME_HANDLERS = {}
local ID_HANDLERS = {}
local CATEGORY_HANDLERS = {}

local Shared = require("DRAP/Shared")
local log = Shared.create_logger("ItemEffects")

local function validate_on_replay(value, where)
    if value == nil then return nil end
    if value ~= "apply" and value ~= "skip" then
        log(string.format("WARNING: invalid on_replay=%s at %s (expected 'apply' or 'skip')",
            tostring(value), tostring(where)))
        return "apply"
    end
    return value
end

------------------------------------------------------------
-- Registration
------------------------------------------------------------

-- Stats on silent overwrites, so consumers can surface a single summary line
-- instead of one warning per collision.
local silent_name_overwrites = 0
local silent_id_overwrites = 0

function M.register(name, entry, opts)
    if type(name) ~= "string" or name == "" then
        log("register(): name must be a non-empty string")
        return
    end
    if type(entry) ~= "table" then
        log("register(" .. name .. "): entry must be a table")
        return
    end
    entry.on_replay = validate_on_replay(entry.on_replay, "register(" .. name .. ")")
    if NAME_HANDLERS[name] and NAME_HANDLERS[name].apply and entry.apply then
        if opts and opts.silent then
            silent_name_overwrites = silent_name_overwrites + 1
        else
            log(string.format("WARNING: overwriting existing name handler for '%s'", name))
        end
    end
    NAME_HANDLERS[name] = entry
end

function M.register_by_id(id, entry, opts)
    if type(id) ~= "number" then
        log("register_by_id(): id must be a number")
        return
    end
    if type(entry) ~= "table" then
        log("register_by_id(" .. tostring(id) .. "): entry must be a table")
        return
    end
    entry.on_replay = validate_on_replay(entry.on_replay, "register_by_id(" .. tostring(id) .. ")")
    if ID_HANDLERS[id] and ID_HANDLERS[id].apply and entry.apply then
        if opts and opts.silent then
            silent_id_overwrites = silent_id_overwrites + 1
        else
            log(string.format("WARNING: overwriting existing id handler for %d", id))
        end
    end
    ID_HANDLERS[id] = entry
end

function M.get_silent_overwrite_counts()
    return { names = silent_name_overwrites, ids = silent_id_overwrites }
end

function M.register_category(category, entry)
    if type(category) ~= "string" or category == "" then
        log("register_category(): category must be a non-empty string")
        return
    end
    if type(entry) ~= "table" or type(entry.apply) ~= "function" then
        log("register_category(" .. category .. "): entry.apply must be a function")
        return
    end
    entry.on_replay = validate_on_replay(entry.on_replay, "register_category(" .. category .. ")")
        or "apply"
    CATEGORY_HANDLERS[category] = entry
end

function M.tag_item_category(name, category)
    if type(name) ~= "string" or type(category) ~= "string" then return end
    local existing = NAME_HANDLERS[name]
    if not existing then
        NAME_HANDLERS[name] = { category = category }
    elseif not existing.category then
        existing.category = category
    end
end

------------------------------------------------------------
-- Introspection helpers (for tests / debugging)
------------------------------------------------------------

function M.has_name_handler(name)
    return NAME_HANDLERS[name] ~= nil
end

function M.has_id_handler(id)
    return ID_HANDLERS[id] ~= nil
end

function M.has_category_handler(category)
    return CATEGORY_HANDLERS[category] ~= nil
end

function M.stats()
    local name_count, id_count, cat_count = 0, 0, 0
    for _ in pairs(NAME_HANDLERS) do name_count = name_count + 1 end
    for _ in pairs(ID_HANDLERS) do id_count = id_count + 1 end
    for _ in pairs(CATEGORY_HANDLERS) do cat_count = cat_count + 1 end
    return { names = name_count, ids = id_count, categories = cat_count }
end

------------------------------------------------------------
-- Dispatch
------------------------------------------------------------

-- Returns true if a handler was found (even if skipped due to replay policy),
-- false otherwise. The bridge is responsible for the "unhandled item" log.
function M.dispatch(net_item, item_name, sender_name, is_replay)
    local id = net_item and net_item.item
    local entry = (id and ID_HANDLERS[id]) or (item_name and NAME_HANDLERS[item_name]) or nil

    local cat_entry = nil
    if entry and entry.category then
        cat_entry = CATEGORY_HANDLERS[entry.category]
    end

    local apply_fn = (entry and entry.apply) or (cat_entry and cat_entry.apply)
    if not apply_fn then
        return false
    end

    local on_replay = (entry and entry.on_replay)
                   or (cat_entry and cat_entry.on_replay)
                   or "apply"

    if is_replay and on_replay == "skip" then
        return true
    end

    local ctx = {
        net_item = net_item,
        item_name = item_name,
        sender_name = sender_name,
        is_replay = is_replay and true or false,
    }

    local ok, err = pcall(apply_fn, ctx)
    if not ok then
        log(string.format("Error in handler for id=%s name='%s': %s",
            tostring(id), tostring(item_name), tostring(err)))
    end
    return true
end

return M
