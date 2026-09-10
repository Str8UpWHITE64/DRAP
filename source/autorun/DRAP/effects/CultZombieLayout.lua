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
-- cult row is untouched. Rows are found by area, table type and their 326
-- gate, the original set number is kept, and the patch is reversible.
--
-- Rules:
--   Theater  (1283): patched whenever "A Strange Group" is NOT active --
--                    not received yet, or completed. While it is active the
--                    vanilla fight state stands: cultists, no zombies.
--   Food Court (2560): patched while the cult roams, i.e. not Cult Limited.

local Shared = require("DRAP/Shared")

local M = Shared.create_module("CultZombieLayout")
M:set_throttle(1.0)

local ELM_T = "app.solid.gamemastering.EnemyLayoutManager"
local elm_mgr = M:add_singleton("elm", ELM_T)

local CULT_FLAG   = 326
local ZOMBIE_TYPE = 1        -- rEnemySetControlTable.ETableType: zombie rows
local CULT_SCOOP  = "A Strange Group"

-- area -> how its cult-time zombie row is patched.
--   to_set: point the row at that set. Theater: set 0, the base layout
--           (40 zombies), measured to select, load and stream correctly
--           with the cult set alongside. The theater has no day/night
--           ladder, so a redirect is the only form that works there.
--   hide:   move the row to area 0 so no load matches it and the engine
--           falls through to the area's own day/night ladder. Food Court:
--           it has a full ladder (200/210, 220/230, 240/250), so hiding
--           the cult row gives the right density for the clock.
local AREAS = {
    [1283] = { name = "Colby's Movieland", to_set = 0, vanilla = 10000 },
    [2560] = { name = "Food Court",        hide = true },
}

local safe = Shared.safe

-- area -> { rows = {row objects}, original = set number or area, patched = bool }
local state = {}
local table_scanned = false

------------------------------------------------------------
-- Table access
------------------------------------------------------------

local function control_rows()
    local e = elm_mgr:get()
    local ud = e and safe(function() return e:get_field("EnemySetControlUserData") end)
    local tbl = ud and safe(function() return ud:get_field("mTable") end)
    return tbl and safe(function() return tbl:get_field("mEnemySetControlTableList") end)
end

--- Does this row's flag condition require 326 on?
local function gated_on_cult(row)
    local cond = safe(function() return row:get_field("mEventFlagCondition") end)
    local arr = cond and safe(function() return cond:get_field("mAnd") end)
    if not arr then return false end
    -- The probe's read: elements start at +0x20, capacity 8, terminated by
    -- 0xFFFFFFFF. get_size/get_element return nothing on this array type.
    for k = 0, 7 do
        local v = safe(function() return arr:read_dword(0x20 + k * 4) end)
        if v == nil or v == 0xFFFFFFFF then break end
        if v == CULT_FLAG then return true end
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
            if a and AREAS[a] and t == ZOMBIE_TYPE and gated_on_cult(r) then
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
        M.log(string.format("%s: %d cult-time zombie row(s), original %s",
            cfg.name, #st.rows, tostring(st.original)))
    end
    table_scanned = true
    return true
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
    M.log(string.format("%s: cult-time zombie row %s = %d (%s, %d row(s)); takes effect on the next entry",
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

local function cult_limited()
    local su = unlocker()
    if not (su and su.is_cult_limited_enabled) then return false end
    return safe(su.is_cult_limited_enabled) == true
end

local function want_theater()
    return not scoop_active(CULT_SCOOP)
end

local function want_food_court()
    return not cult_limited()
end

function M.on_frame()
    if not M:should_run() then return end
    if not Shared.is_in_game() then return end
    if not table_scanned and not scan_table() then return end
    apply(1283, want_theater())
    if AREAS[2560] then apply(2560, want_food_court()) end
end

_G.drap_cult_layout_status = function()
    for area, st in pairs(state) do
        M.log(string.format("%s: rows=%d original=%s patched=%s | strange group active=%s cult limited=%s",
            AREAS[area].name, #st.rows, tostring(st.original), tostring(st.patched),
            tostring(scoop_active(CULT_SCOOP)), tostring(cult_limited())))
    end
end

return M
