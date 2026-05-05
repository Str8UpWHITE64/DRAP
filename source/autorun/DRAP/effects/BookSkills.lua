-- DRAP/effects/BookSkills.lua
-- Book-skill effects from AP item grants.
-- See docs/reframework/features/book_skills.md.
--
-- DRAP marks granted ITEM_NOs in a runtime set; a hook on
-- Inventory.checkItemSkill returns true for those IDs, activating the book's
-- effect without consuming an inventory slot.

local SharedData = require("DRAP/SharedData")
local ItemEffects = require("DRAP/ItemEffects")

local M = {}

local Shared = require("DRAP/Shared")
local log = Shared.create_logger("BookSkills")

------------------------------------------------------------
-- Runtime state
------------------------------------------------------------

-- Set of game ITEM_NO ints that DRAP has granted. The hook returns true for
-- checkItemSkill(id) iff id is a key in this set.
local granted = {}
local hook_installed = false

-- Diagnostic kill switch: when true the hook stops claiming any book is held,
-- so we can test whether a given book's always-on effect is causing some bug
-- (e.g. Burt Thompson refusing to defuse from hostile in the Barricade Pair
-- scoop -- suspected Hypnosis / Brainwashing / Cult Initiation interactions).
-- Toggle via _G.drap_books_disable() / _G.drap_books_enable().
local books_disabled = false

-- Per-id runtime suppression. Set by guard modules (see BookGuards.lua) to
-- temporarily stop a granted book's effect during specific gameplay
-- sequences where always-on breaks vanilla behavior. Suppress is
-- idempotent and the granted set is untouched -- a paired unsuppress
-- restores the book without needing to re-grant it.
-- Values are the suppression source string (for diagnostics).
local suppressed = {}

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function argint(a)
    if a == nil then return -1 end
    local ok, v = pcall(sdk.to_int64, a)
    if ok and v ~= nil then return tonumber(v) or -1 end
    return -1
end

-- Build the list of book entries from shared_data: items whose game_id
-- starts with "ITEM_NO_BOOK_". Returns { { name=..., item_number=... }, ... }
local function gather_book_entries()
    local out = {}
    for _, it in ipairs(SharedData.items()) do
        if it and it.game_id and it.game_id:sub(1, 13) == "ITEM_NO_BOOK_" then
            table.insert(out, it)
        end
    end
    return out
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

function M.grant(item_no)
    if type(item_no) ~= "number" then return end
    if not granted[item_no] then
        granted[item_no] = true
        log(string.format("Granted book skill for ITEM_NO=%d", item_no))
    end
end

function M.revoke(item_no)
    if type(item_no) ~= "number" then return end
    if granted[item_no] then
        granted[item_no] = nil
        log(string.format("Revoked book skill for ITEM_NO=%d", item_no))
    end
end

function M.is_granted(item_no)
    return granted[item_no] == true
end

------------------------------------------------------------
-- Hook on Inventory.checkItemSkill
------------------------------------------------------------

local function install_hook()
    if hook_installed then return true end
    local td = sdk.find_type_definition("app.solid.character.player.Inventory")
    if not td then return false end
    local m = td:get_method("checkItemSkill")
    if not m then
        log("ERROR: Inventory.checkItemSkill method not found")
        return false
    end

    local last_id = nil
    local ok, err = pcall(sdk.hook, m,
        function(args) last_id = argint(args[3]) end,
        function(retval)
            if not books_disabled and last_id
                and granted[last_id] and not suppressed[last_id] then
                return sdk.to_ptr(1)   -- true
            end
            return retval
        end)
    if not ok then
        log("ERROR: hook install failed: " .. tostring(err))
        return false
    end
    hook_installed = true
    log("Hook on Inventory.checkItemSkill installed.")
    return true
end

------------------------------------------------------------
-- Registration with ItemEffects
------------------------------------------------------------

function M.register_all()
    -- One-time hook install.
    install_hook()

    -- Per-book ItemEffects registration. on_replay = "apply" so the grant
    -- re-fires on save-load (DRAP replays AP items into the bridge).
    local books = gather_book_entries()
    local count = 0
    for _, book in ipairs(books) do
        local item_no = book.item_number
        local name    = book.name
        if name and item_no then
            ItemEffects.register(name, {
                on_replay = "apply",
                apply = function(ctx)
                    M.grant(item_no)
                end,
            })
            count = count + 1
        end
    end
    log(string.format("Registered %d book-skill handlers", count))
end

-- Called from AP_DRDR_main.lua after RECEIVED_ITEMS is restored on
-- save-load / reconnect, so previously-granted books are re-granted.
function M.reapply()
    if not AP or not AP.AP_BRIDGE then return end
    local books = gather_book_entries()
    local re_count = 0
    for _, book in ipairs(books) do
        if book.name and book.item_number
                and AP.AP_BRIDGE.has_item_name(book.name) then
            M.grant(book.item_number)
            re_count = re_count + 1
        end
    end
    if re_count > 0 then
        log(string.format("Reapplied %d previously-granted books", re_count))
    end
end

------------------------------------------------------------
-- Diagnostic
------------------------------------------------------------

function M.list_granted()
    local out = {}
    for id in pairs(granted) do table.insert(out, id) end
    table.sort(out)
    return out
end

function M.set_disabled(v)
    books_disabled = v and true or false
    log(string.format("books_disabled = %s (hook %s)",
        tostring(books_disabled),
        books_disabled and "passes through retval" or "returns true for granted ids"))
end

function M.is_disabled() return books_disabled end

-- Mark a granted book as runtime-suppressed (hook reports it as not-held
-- to the engine). Source is a free-form string for diagnostics. Idempotent.
function M.suppress(item_no, source)
    if type(item_no) ~= "number" then return end
    if not suppressed[item_no] then
        suppressed[item_no] = source or "manual"
        log(string.format("Suppressed book ITEM_NO=%d (source=%s)",
            item_no, tostring(suppressed[item_no])))
    end
end

function M.unsuppress(item_no)
    if type(item_no) ~= "number" then return end
    if suppressed[item_no] then
        local src = suppressed[item_no]
        suppressed[item_no] = nil
        log(string.format("Unsuppressed book ITEM_NO=%d (was source=%s)",
            item_no, tostring(src)))
    end
end

function M.is_suppressed(item_no)
    return suppressed[item_no] ~= nil
end

function M.list_suppressed()
    local out = {}
    for id, src in pairs(suppressed) do
        table.insert(out, { id = id, source = src })
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

------------------------------------------------------------
-- Console helpers for live testing
------------------------------------------------------------

-- Diagnostic: turn off the always-on book hook to verify whether a granted
-- book's effect is causing a gameplay bug (Burt Thompson hostility, etc.).
_G.drap_books_disable = function() M.set_disabled(true) end
_G.drap_books_enable  = function() M.set_disabled(false) end
_G.drap_books_status  = function()
    local ids = M.list_granted()
    log(string.format("disabled=%s | granted count=%d",
        tostring(books_disabled), #ids))
    if #ids > 0 then
        log("granted ids: " .. table.concat(ids, ","))
    end
    local sup = M.list_suppressed()
    if #sup > 0 then
        local parts = {}
        for _, s in ipairs(sup) do
            table.insert(parts, string.format("%d(%s)", s.id, tostring(s.source)))
        end
        log("suppressed ids: " .. table.concat(parts, ", "))
    end
end

-- Surgical narrowing: revoke a single granted id (suspects: 68 Brainwashing/Cult
-- Initiation, 172 Hypnosis, 155 Wrestling, 177 Martial Art, 179 Firearms).
-- Example: drap_book_revoke(68) ; try Burt ; drap_book_grant(68) to restore.
_G.drap_book_revoke = function(item_no)
    item_no = tonumber(item_no)
    if not item_no then log("usage: drap_book_revoke(item_no)"); return end
    M.revoke(item_no)
end
_G.drap_book_grant = function(item_no)
    item_no = tonumber(item_no)
    if not item_no then log("usage: drap_book_grant(item_no)"); return end
    M.grant(item_no)
end

return M
