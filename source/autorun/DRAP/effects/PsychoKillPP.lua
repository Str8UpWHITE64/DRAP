-- DRAP/effects/PsychoKillPP.lua
-- Psycho goal: killing a survivor pays the PP that rescuing them would have.
--
-- Under Psycho nobody can be rescued, so the escort PP a normal run lives on
-- never arrives and the level checks fall out of reach. Paying the same PP on
-- the kill keeps the level curve where the logic expects it.
--
-- The amounts are the game's own, read live from NpcManager rather than
-- copied into a table here. In the vanilla escort code:
--   * join:     calcScore(SCORE_NPC, mPP_EscortStart, 258 JOIN BONUS)
--               (NpcBase.setEscortEnable; skipped once mAttribute bit 8 says
--               the join bonus was paid, and the bit is set after paying)
--   * delivery: calcScore(SCORE_NPC, mEscortEndPP, 259 ESCORT COMPLETE)
--               where mEscortEndPP is the delivered group's mPP_EscortEnd
--               summed, times NPC_ESCORTEND_PPBONUS_TBL[group size] / 100
--               (NpcManager.replaceNpc, GameFsmNpcEscortEventAction.update)
--   * both are scaled by PP_NPC_BOOK14_RATIO (125) when the PP book (item
--     285) is held, and calcScore applies the Easy Mode rate itself.
-- A kill pays one survivor as a group of one: the join bonus unless it was
-- already paid, plus the delivery bonus. Jeff Meyer, for one, is 5000 + 10000.
--
-- Granted through calcScore with SCORE_NPC, the same call the escort makes.
-- Not SCORE_TOTAL (0): calcScore returns early for id 0, before its level-up
-- loop, so the PP banks and the level only moves on the next natural PP --
-- the lag PP Boost has always had.
--
-- Once per survivor per slot, recorded in the run ledger. A reload or a Start
-- Over brings the survivor back, but killing them again pays nothing: the
-- level and PP carry over a Start Over, and paying twice would put the level
-- ahead of the logic. (A reload to a save from before the kill loses that PP
-- with the save, and it is not paid again either.)
--
-- Runs from NpcTracker's frame poll, never from a hook.

local Shared = require("DRAP/Shared")
local Ledger = require("DRAP/LocationLedger")

local M = {}

local log = Shared.create_logger("PsychoKillPP")

local GRANT_ENABLED = true

local LEDGER_SECTION = "psycho_kill_pp"

local SCORE_NPC = 1
local MESSAGE_OFF = 65535
local ATTR_JOIN_PP_PAID = 0x8
local PP_BOOK_ITEM = 285            -- 0x11d, what the escort code checks
local DEFAULT_BOOK_RATIO = 125      -- PP_NPC_BOOK14_RATIO, measured
local DEFAULT_GROUP_PERCENT = 100   -- NPC_ESCORTEND_PPBONUS_TBL[1]

-- Grants made while the ledger was not up yet; folded in once it is.
local pending = {}

------------------------------------------------------------
-- Pure part
------------------------------------------------------------

--- PP a kill pays. All fields optional; the engine's integer maths
--- (truncating percent scaling) is kept so the number matches a rescue.
---   start, finish     mPP_EscortStart / mPP_EscortEnd
---   join_paid         the join bonus was already paid
---   group_percent     NPC_ESCORTEND_PPBONUS_TBL[1]
---   book              the PP book is held
---   book_ratio        PP_NPC_BOOK14_RATIO
function M.compute_award(p)
    local start = math.max(0, math.floor(tonumber(p.start) or 0))
    local finish = math.max(0, math.floor(tonumber(p.finish) or 0))
    local book_ratio = tonumber(p.book_ratio) or DEFAULT_BOOK_RATIO
    local group = tonumber(p.group_percent) or DEFAULT_GROUP_PERCENT
    if p.join_paid then start = 0 end
    if p.book then
        start = start * book_ratio // 100
        finish = finish * book_ratio // 100
    end
    finish = finish * group // 100
    return start + finish, start, finish
end

------------------------------------------------------------
-- Ledger
------------------------------------------------------------

local function ledger_doc()
    if not Ledger.is_init() then return nil end
    local doc = Ledger.get_section(LEDGER_SECTION)
    if type(doc) ~= "table" or type(doc.granted) ~= "table" then
        doc = { granted = {} }
    end
    return doc
end

function M.was_granted(name)
    if pending[name] then return true end
    local doc = ledger_doc()
    return doc ~= nil and doc.granted[name] ~= nil
end

local function remember(name, amount)
    local doc = ledger_doc()
    if not doc then
        pending[name] = amount
        return
    end
    for n, a in pairs(pending) do
        if doc.granted[n] == nil then doc.granted[n] = a end
    end
    pending = {}
    doc.granted[name] = amount
    Ledger.set_section(LEDGER_SECTION, doc)
end

------------------------------------------------------------
-- Engine reads
------------------------------------------------------------

local function int_field(obj, name)
    if not obj then return nil end
    return tonumber(Shared.safe(function() return obj:get_field(name) end))
end

local function find_info(mgr, stype)
    local list = Shared.safe(function() return mgr:get_field("NpcInfoList") end)
    if not list then return nil end
    for _, info in Shared.iter_collection(list) do
        if info then
            local who = Shared.safe(function()
                return info:get_field("<Name>k__BackingField")
            end)
            if tonumber(who) == stype then return info end
        end
    end
    return nil
end

local function group_percent(mgr)
    local ud = Shared.safe(function() return mgr:get_field("NpcEscortDefineUserdata") end)
    local tbl = ud and Shared.safe(function()
        return ud:get_field("NPC_ESCORTEND_PPBONUS_TBL")
    end)
    if not tbl then return nil end
    local n = tonumber(Shared.safe(function() return tbl:call("get_Count") end)) or 0
    if n <= 1 then return nil end
    return tonumber(Shared.safe(function() return tbl:call("get_Item", 1) end))
end

local function book_held()
    local pm = sdk.get_managed_singleton("app.solid.PlayerManager")
    if not pm then return false end
    return Shared.safe(function()
        return pm:call("checkItemSkill", PP_BOOK_ITEM)
    end) == true
end

local function read_book_ratio()
    local td = sdk.find_type_definition("app.solid.PlayerStatusManager")
    local f = td and td:get_field("PP_NPC_BOOK14_RATIO")
    return f and tonumber(Shared.safe(function() return f:get_data(nil) end)) or nil
end

--- Everything compute_award needs, read from the game. nil if the survivor
--- has no init param (not a real survivor type).
function M.read_params(stype)
    local mgr = sdk.get_managed_singleton("app.solid.gamemastering.NpcManager")
    if not mgr then return nil end
    local ip = Shared.safe(function()
        return mgr:call("getInitParam(app.solid.SurvivorDefine.SurvivorType)", stype)
    end)
    if not ip then return nil end
    local info = find_info(mgr, stype)
    local attr = int_field(info, "mAttribute") or 0
    return {
        start = int_field(ip, "mPP_EscortStart"),
        finish = int_field(ip, "mPP_EscortEnd"),
        join_paid = (attr & ATTR_JOIN_PP_PAID) ~= 0,
        group_percent = group_percent(mgr),
        book = book_held(),
        book_ratio = read_book_ratio(),
    }
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

--- Pay the rescue PP for a survivor the player killed. Psycho only, once per
--- survivor per slot. Returns the amount paid, or nil.
function M.on_survivor_killed(stype, name)
    if not GRANT_ENABLED then return nil end
    if not (AP and AP.PsychoMode) then return nil end
    stype = tonumber(stype)
    if not stype or not name then return nil end
    if M.was_granted(name) then
        log(string.format("%s: rescue PP already paid on this slot", name))
        return nil
    end

    local p = M.read_params(stype)
    if not p then
        log(string.format("%s: no init param for stype %d -- no PP", name, stype))
        return nil
    end
    local amount, s, f = M.compute_award(p)
    if amount <= 0 then return nil end

    local psm = sdk.get_managed_singleton("app.solid.PlayerStatusManager")
    if not psm then return nil end
    local lvl0 = int_field(psm, "PlayerLevel")
    local ok, err = pcall(function()
        psm:call("calcScore", SCORE_NPC, amount, MESSAGE_OFF, 0, false)
    end)
    if not ok then
        log(string.format("%s: calcScore failed: %s", name, tostring(err)))
        return nil
    end
    remember(name, amount)
    log(string.format("%s: paid %d PP for the kill (join %d%s, escort %d); level %s -> %s",
        name, amount, s, p.join_paid and " already paid" or "", f,
        tostring(lvl0), tostring(int_field(psm, "PlayerLevel"))))
    local okn, Notify = pcall(require, "DRAP/Notify")
    if okn and Notify and Notify.info then
        pcall(Notify.info, string.format("+%d PP (%s)", amount, name))
    end
    return amount
end


_G.drap_psycho_pp_status = function()
    local doc = ledger_doc()
    local n, total = 0, 0
    for name, a in pairs((doc and doc.granted) or pending) do
        n = n + 1
        total = total + (tonumber(a) or 0)
        log(string.format("  %s: %s", name, tostring(a)))
    end
    log(string.format("rescue PP paid for %d kill(s), %d PP", n, total))
end

return M
