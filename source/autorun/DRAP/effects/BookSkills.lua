-- DRAP/effects/BookSkills.lua
-- Book-skill effects from AP item grants.
-- See docs/reframework/features/book_skills.md.
--
-- DRAP marks granted ITEM_NOs in a runtime set; a hook on
-- Inventory.checkItemSkill returns true for those IDs, activating the book's
-- effect without consuming an inventory slot.

local SharedData = require("DRAP/SharedData")
local ItemEffects = require("DRAP/ItemEffects")
local Ledger = require("DRAP/LocationLedger")

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

-- Player-facing per-book off switch, owned solely by the Books tab. Kept
-- separate from `granted` and `suppressed` because both of those are driven
-- by other systems that would clobber a player's choice: reapply() re-grants
-- every owned book on save-load, and BookGuards calls unsuppress on its
-- falling edge. A book is off here until the player turns it back on.
local user_disabled = {}

local LEDGER_SECTION = "book_toggles"

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

--- Is this book's effect actually live right now?
---
--- The single source of truth for the three independent layers: AP ownership
--- (`granted`), the guard system (`suppressed`), and the player's own switch
--- (`user_disabled`), plus the global diagnostic kill switch. The hook and the
--- Books tab both call this, so what the UI shows cannot drift from what the
--- engine is told.
--- @param item_no number
--- @return boolean
function M.is_effective(item_no)
    if books_disabled then return false end
    if not granted[item_no] then return false end
    if suppressed[item_no] then return false end
    if user_disabled[item_no] then return false end
    return true
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
        log.error("Inventory.checkItemSkill method not found")
        return false
    end

    local last_id = nil
    local ok, err = pcall(sdk.hook, m,
        function(args) last_id = argint(args[3]) end,
        function(retval)
            -- Only ever forces the answer to true: a book the player is
            -- physically carrying is the engine's business, so a disabled
            -- book falls through to the engine's own retval rather than
            -- being forced false.
            if last_id and M.is_effective(last_id) then
                return sdk.to_ptr(1)   -- true
            end
            return retval
        end)
    if not ok then
        log.error("hook install failed: " .. tostring(err))
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
-- Player toggles (Books tab)
------------------------------------------------------------

--- Books the player currently owns, sorted by display name.
--- Same ownership test reapply() uses. Returns
--- { { name=, item_number=, enabled=, effective=, guard= }, ... }
function M.acquired_books()
    local out = {}
    if not AP or not AP.AP_BRIDGE then return out end
    for _, book in ipairs(gather_book_entries()) do
        local item_no = book.item_number
        if book.name and item_no and AP.AP_BRIDGE.has_item_name(book.name) then
            table.insert(out, {
                name        = book.name,
                item_number = item_no,
                enabled     = not user_disabled[item_no],
                effective   = M.is_effective(item_no),
                guard       = suppressed[item_no],
            })
        end
    end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end

function M.is_user_enabled(item_no)
    return not user_disabled[item_no]
end

--- Turn one book's effect on or off for the player. Persists immediately so
--- a crash or hard exit cannot lose the choice.
function M.set_user_enabled(item_no, enabled)
    if type(item_no) ~= "number" then return end
    local now_disabled = (enabled == false) or nil
    if user_disabled[item_no] == now_disabled then return end
    user_disabled[item_no] = now_disabled
    log(string.format("Book ITEM_NO=%d turned %s by the player",
        item_no, enabled and "on" or "off"))
    M.save_user_toggles()
end

--- Persisted as the DISABLED list, so a missing or unreadable section means
--- "every book on" -- the vanilla-equivalent default -- and newly received
--- books switch on by themselves.
function M.save_user_toggles()
    if not Ledger.is_init() then return false end
    local ids = {}
    for id in pairs(user_disabled) do table.insert(ids, id) end
    table.sort(ids)   -- deterministic order on disk
    return Ledger.set_section(LEDGER_SECTION, { disabled = ids })
end

function M.reset_user_toggles()
    user_disabled = {}
end

--- Called on the save-load boundary. Resets first: without that, one slot's
--- choices would leak into the next run loaded in the same session.
function M.load_user_toggles()
    M.reset_user_toggles()
    local doc = Ledger.is_init() and Ledger.get_section(LEDGER_SECTION) or nil
    if type(doc) ~= "table" or type(doc.disabled) ~= "table" then return false end
    local n = 0
    for _, id in ipairs(doc.disabled) do
        local num = tonumber(id)
        if num then
            user_disabled[num] = true
            n = n + 1
        end
    end
    if n > 0 then
        log(string.format("Loaded %d player-disabled book(s)", n))
    end
    return true
end

------------------------------------------------------------
-- UI: Books Tab Drawing
------------------------------------------------------------

function M.draw_tab_content(debug)
    local books = M.acquired_books()

    local changed, new_val = imgui.checkbox("Disable all book effects", books_disabled)
    if changed then
        M.set_disabled(new_val)
    end
    imgui.text_colored(
        "Turning a book off keeps the item -- only its always-on effect stops.",
        0xFF888888)

    if debug then
        imgui.text(string.format("Books received: %d", #books))
    end

    imgui.separator()

    imgui.begin_child_window("BookList", Vector2f.new(0, 0), true, 0)

    for _, book in ipairs(books) do
        local label = string.format("%s##book_%d", book.name, book.item_number)
        local row_changed, row_val = imgui.checkbox(label, book.enabled)
        if row_changed then
            M.set_user_enabled(book.item_number, row_val)
        end

        -- A guard holding a book off would otherwise look like a broken
        -- toggle: the box is ticked but nothing happens in that area.
        if book.enabled and book.guard then
            imgui.same_line()
            imgui.text_colored("(paused here: " .. tostring(book.guard) .. ")", 0xFFFF8800)
        end

        if debug then
            imgui.same_line()
            imgui.text_colored(string.format("id=%d effective=%s",
                book.item_number, tostring(book.effective)), 0xFF888888)
        end
    end

    if #books == 0 then
        imgui.text_colored("No books received yet.", 0xFF888888)
    elseif books_disabled then
        imgui.separator()
        imgui.text_colored("All book effects are off via the master switch above.",
            0xFFFF8800)
    end

    imgui.end_child_window()
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
    local off = {}
    for id in pairs(user_disabled) do table.insert(off, id) end
    table.sort(off)
    if #off > 0 then
        log("player-disabled ids: " .. table.concat(off, ","))
    end
end

-- Console equivalent of the Books tab checkbox.
-- Example: drap_book_effect(172, false) to turn Hypnosis off.
_G.drap_book_effect = function(item_no, on)
    item_no = tonumber(item_no)
    if not item_no then log("usage: drap_book_effect(item_no, true|false)"); return end
    M.set_user_enabled(item_no, on ~= false)
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
