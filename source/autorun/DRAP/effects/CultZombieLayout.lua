-- DRAP/effects/CultZombieLayout.lua
-- Zombies in the areas the cult empties out.
--
-- The enemy set control table picks each area's zombie layout at load. With
-- the cult active (flag 326) the theater's zombie-table row selects set
-- 10000, EM_NO_SET, and the Food Court's selects a thin set; the cult rows
-- live in their own sub-table and are gated on the same flag, so no flag
-- can give an area both. Measured 2026-09-09 with the layout probes; the
-- selection is re-derived during the load from the chosen ROW, so nothing
-- written to the selected set survives, and spawning zombies directly
-- crashes the game (render and audio faults; see the backlog).
--
-- What does work, with nothing hooked: change the row's set number in the
-- in-memory table. Every selection from it then produces a real zombie
-- layout, loaded, prefabbed and streamed by the engine itself, while the
-- cult row is untouched. Rows are found by area, table type and their flag
-- gate, the original value is kept, and the patch is reversible.
--
-- Rules:
--   Theater  (1283): patched whenever "A Strange Group" is NOT active --
--                    not received yet, or completed. While it is active the
--                    vanilla fight state stands: cultists, no zombies.
--   Food Court (2560): both of its flag-gated rows hidden whenever they
--                    exist: the cult row (326) and the Special Forces row
--                    (309, set 9). The cult row's flag is on from "The Cult" until
--                    the end of the run whatever Cult Limited says: Cult
--                    Limited only clears the roaming flag (2063) outside
--                    Colby's once "A Strange Group" is completed, so the
--                    thin set was still being selected with no cultists
--                    in sight (tester report, Cult Limited on).
--   Cult rows (Cult Limited): once "A Strange Group" is completed, every
--                    cult row (table type 2) gated on 326 is hidden except
--                    the theater's. 326 itself is left to the game: the
--                    Paradise Plaza cutscene turns it on and nothing turns
--                    it off before Sean's kill, so the cult stayed in the
--                    whole mall. Holding 326 off instead emptied Colby's
--                    too, and since the layout is picked during the load,
--                    a flag keyed on the current scene always lands one
--                    area late in both directions. The rows don't care
--                    which way the player is walking.

local Shared = require("DRAP/Shared")
local State = require("DRAP/scoops/ScoopState")

local M = Shared.create_module("CultZombieLayout")
M:set_throttle(1.0)

local ELM_T = "app.solid.gamemastering.EnemyLayoutManager"
local elm_mgr = M:add_singleton("elm", ELM_T)

local CULT_FLAG   = 326
local SF_FLAG     = 309      -- the Special Forces; their zombie row is thin too
local ZOMBIE_TYPE = 1        -- rEnemySetControlTable.ETableType: zombie rows
local CULT_TYPE   = 2        -- ETableType.eCult: the cult rows
local THEATER     = 1283     -- s503, the one area that keeps its cult rows
local CULT_SCOOP  = "A Strange Group"

-- area -> how its cult-time zombie row is patched.
--   to_set: point the row at that set. Theater: set 0, the base layout
--           (40 zombies), measured to select, load and stream correctly
--           with the cult set alongside. The theater has no day/night
--           ladder, so a redirect is the only form that works there.
--   hide:   move the row to area 0 so no load matches it and the engine
--           falls through to the area's own day/night ladder. Food Court:
--           it has a full ladder (200/210, 220/230, 240/250), so hiding
--           the cult row gives the right density for the clock. The
--           cultists come from their own sub-table and are not affected.
-- flags: a row is taken when its "and" condition carries any of these.
-- The Food Court is the one area with a zombie row of its own for the
-- Special Forces (set 9, gated 309): soldiers and next to no zombies
-- (tester report). Hidden the same way, so the ladder stands under the
-- Special Forces item and the soldiers still come from their own rows.
local AREAS = {
    [1283] = { name = "Colby's Movieland", to_set = 0, vanilla = 10000, flags = { CULT_FLAG } },
    [2560] = { name = "Food Court",        hide = true, flags = { CULT_FLAG, SF_FLAG } },
    -- Entrance Plaza has two zombie rows of its own for the Special Forces,
    -- sets 6009 and 9, both gated 309 (read 2026-09-24): soldiers and next
    -- to no zombies (#59). Its ladder is the same shape as the Food Court's.
    [256]  = { name = "Entrance Plaza",    hide = true, flags = { SF_FLAG } },
}

local safe = Shared.safe

-- area -> { rows = {row objects}, original = set number or area, patched = bool }
local state = {}
local table_scanned = false

-- The cult rows Cult Limited hides: { row = obj, area = original area }.
-- Hidden the same way as the Food Court's zombie row, by moving the row to
-- area 0. A row found already at 0 (a script reset mid-session) has lost
-- its area and stays hidden until the game restarts.
local cult_rows = {}
local cult_hidden = false

------------------------------------------------------------
-- Table access
------------------------------------------------------------

local function control_rows()
    local e = elm_mgr:get()
    local ud = e and safe(function() return e:get_field("EnemySetControlUserData") end)
    local tbl = ud and safe(function() return ud:get_field("mTable") end)
    return tbl and safe(function() return tbl:get_field("mEnemySetControlTableList") end)
end

--- Does this row's "and" condition require any of these flags on?
local function gated_on(row, flags)
    local cond = safe(function() return row:get_field("mEventFlagCondition") end)
    local arr = cond and safe(function() return cond:get_field("mAnd") end)
    if not arr then return false end
    -- The probe's read: elements start at +0x20, capacity 8, terminated by
    -- 0xFFFFFFFF. get_size/get_element return nothing on this array type.
    for k = 0, 7 do
        local v = safe(function() return arr:read_dword(0x20 + k * 4) end)
        if v == nil or v == 0xFFFFFFFF then break end
        for _, f in ipairs(flags) do
            if v == f then return true end
        end
    end
    return false
end

--- Find every area's cult-time zombie row once. Rows are userdata that
--- live for the session, so holding them is fine.
local function scan_table()
    local list = control_rows()
    if not list then return false end
    local n = safe(function() return list:call("get_Count") end) or 0
    if n == 0 then return false end
    for area, cfg in pairs(AREAS) do
        state[area] = state[area] or { rows = {}, original = nil, patched = false }
    end
    for i = 0, n - 1 do
        local r = safe(function() return list:call("get_Item", i) end)
        if r then
            local a = tonumber(safe(function() return r:get_field("mAreaNo") end))
            local t = tonumber(safe(function() return r:get_field("mType") end))
            if a and a ~= THEATER and t == CULT_TYPE and gated_on(r, { CULT_FLAG }) then
                table.insert(cult_rows, { row = r, area = (a ~= 0) and a or nil })
            end
            if a and AREAS[a] and t == ZOMBIE_TYPE and gated_on(r, AREAS[a].flags) then
                local st = state[a]
                local field = AREAS[a].hide and "mAreaNo" or "mEmSetNo"
                local v = tonumber(safe(function() return r:get_field(field) end))
                table.insert(st.rows, r)
                if st.original == nil then st.original = v end
            end
        end
    end
    for area, st in pairs(state) do
        local cfg = AREAS[area]
        -- A row already carrying the patch value (a probe wrote it earlier
        -- in the session, or a script reset re-scanned) must not be taken
        -- as the original, or "restore" would keep the patch.
        if cfg.hide then
            if st.original == 0 then st.original = area end
        elseif st.original == cfg.to_set then
            st.original = cfg.vanilla
        end
        M.log(string.format("%s: %d flag-gated zombie row(s), original %s",
            cfg.name, #st.rows, tostring(st.original)))
    end
    local areas = {}
    cult_hidden = #cult_rows > 0
    for _, c in ipairs(cult_rows) do
        if c.area then cult_hidden = false end
    end
    for _, c in ipairs(cult_rows) do table.insert(areas, tostring(c.area or "0 (hidden earlier)")) end
    M.log(string.format("Cult rows outside the theater: %d (areas %s)", #cult_rows, table.concat(areas, ",")))
    table_scanned = true
    return true
end

local function apply_cult(want_hidden)
    if #cult_rows == 0 or cult_hidden == want_hidden then return end
    local ok_n = 0
    for _, c in ipairs(cult_rows) do
        local to = want_hidden and 0 or c.area
        if to ~= nil then
            local ok = pcall(function() c.row:set_field("mAreaNo", to) end)
            if ok then ok_n = ok_n + 1 end
        end
    end
    cult_hidden = want_hidden
    M.log(string.format("Cult rows outside the theater %s (%d of %d); takes effect on the next entry",
        want_hidden and "hidden" or "restored", ok_n, #cult_rows))
end

local function apply(area, want_patched)
    local st = state[area]
    if not st or #st.rows == 0 or st.patched == want_patched then return end
    local cfg = AREAS[area]
    local field = cfg.hide and "mAreaNo" or "mEmSetNo"
    local to
    if want_patched then to = cfg.hide and 0 or cfg.to_set else to = st.original end
    if to == nil then return end
    local ok_n = 0
    for _, r in ipairs(st.rows) do
        local ok = pcall(function() r:set_field(field, to) end)
        if ok then ok_n = ok_n + 1 end
    end
    st.patched = want_patched
    M.log(string.format("%s: flag-gated zombie row %s = %d (%s, %d row(s)); takes effect on the next entry",
        cfg.name, field, to, want_patched and "patched" or "restored", ok_n))
end

------------------------------------------------------------
-- Rules
------------------------------------------------------------

local function unlocker() return AP and AP.ScoopUnlocker end

local function scoop_active(name)
    local su = unlocker()
    if not su then return false end
    local ok1, received = pcall(su.has_received_scoop, name)
    local ok2, done = pcall(su.is_scoop_completed, name)
    return ok1 and received == true and not (ok2 and done == true)
end

local function want_theater()
    return not scoop_active(CULT_SCOOP)
end

local function want_food_court()
    return true
end

--- Cult Limited, Sean done: the cult stays only in the theater.
local function want_cult_hidden()
    local su = unlocker()
    if not su then return false end
    local ok1, limited = pcall(su.is_cult_limited_enabled)
    local ok2, sanity = pcall(su.is_scoop_sanity_enabled)
    local ok3, done = pcall(su.is_scoop_completed, CULT_SCOOP)
    return ok1 and limited == true and ok2 and sanity == true and ok3 and done == true
end

function M.on_frame()
    if not M:should_run() then return end
    if not Shared.is_in_game() then return end
    if not table_scanned and not scan_table() then return end
    -- Overtime runs its own Special Forces on flag 309; every row goes back
    -- to vanilla so its layouts are the game's.
    if State.is_endgame_reached() then
        for area in pairs(AREAS) do apply(area, false) end
        apply_cult(false)
        return
    end
    apply(1283, want_theater())
    if AREAS[2560] then apply(2560, want_food_court()) end
    if AREAS[256] then apply(256, true) end
    apply_cult(want_cult_hidden())
end

_G.drap_cult_layout_status = function()
    for area, st in pairs(state) do
        M.log(string.format("%s: rows=%d original=%s patched=%s | strange group active=%s",
            AREAS[area].name, #st.rows, tostring(st.original), tostring(st.patched),
            tostring(scoop_active(CULT_SCOOP))))
    end
    M.log(string.format("Cult rows outside the theater: %d, hidden=%s (wanted %s)",
        #cult_rows, tostring(cult_hidden), tostring(want_cult_hidden())))
end

return M
