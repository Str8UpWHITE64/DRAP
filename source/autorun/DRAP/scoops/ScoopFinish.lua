-- DRAP/scoops/ScoopFinish.lua
-- Scoop finishes the game cannot make by itself, and the rule that DRAP never
-- takes one back.
--
-- The game finishes a scoop in one of two ways. A survivor or captive row is
-- finished when its people join Frank (NpcScoopGet writes its FINISH flag).
-- Every other row -- the psychopaths, the main cases and a few special rows --
-- is finished by SCQManager.startupQue, which only checks the rows holding one
-- of its 20 SCQMove slots. A running row (START on, FINISH off) takes a free
-- slot in table order and gives it back only when its FINISH goes on. With many
-- scoops running at once a row can wait a long time for a slot, and until it
-- gets one its finish never comes: a dead psychopath is placed again at 0 HP,
-- a main case still reads as running.
--
-- Three rules, applied from DRAP's frame tick:
--   1. DRAP never clears a row's FINISH or SUCCESS flag (never_off). A cleared
--      FINISH makes the row run again, take a slot back and never finish again.
--      The one exception is the cult respawn, which clears its rows' flags on
--      purpose; those rows are left alone here.
--   2. A row whose own finish rule holds (its success flag, or for a few rows
--      its finish flag) is finished through the game's own
--      SCQManager.finishSCQ once it has stayed unfinished for DWELL_SECONDS,
--      so the game always gets the first chance.
--   3. Repairs, for saves made before rule 1: a row with SUCCESS on and FINISH
--      off, and the case row of a main scoop DRAP has completed.
-- A main case only counts its wait while the game's SCQ loop runs. The loop
-- pauses while a Case File screen is open, and the game finishes the case
-- itself when the player presses Accept.
--
-- PURITY CONTRACT: no engine access. Flags arrive through ctx.check, and the
-- caller performs the finishes tick() returns. Unit-tested headlessly in
-- tools/logic_tests/test_scoop_finish.py.

local M = {}

M.DWELL_SECONDS = 0.5
-- A finish that doesn't take (its FINISH is still off at the next look) is
-- tried MAX_QUICK_ATTEMPTS times DWELL_SECONDS apart, then every
-- RETRY_SECONDS for as long as the row stays due. Seeing its FINISH on starts
-- the count again.
M.MAX_QUICK_ATTEMPTS = 3
M.RETRY_SECONDS = 5.0

-- The game's SCQ table (rSCQTable.mEventQueDatas), in table order. finish is
-- mQueEndFlag, success mQueSuccessFlag (0 = none), attr mFinishAttr, param
-- mFinishParam. Comments name the DRAP scoops whose start sets hold the row's
-- START flag.
M.ROWS = {
    { tbl = 0, scq = 121, start = 3648, finish = 3649, success = 3650, attr = 0x05, param = 261, extend = true },
    { tbl = 1, scq = 122, start = 3652, finish = 3653, success = 3654, attr = 0x05, param = 263, extend = true },
    { tbl = 2, scq = 123, start = 3656, finish = 3657, success = 3658, attr = 0x0C, param = 265, extend = true },
    { tbl = 3, scq = 124, start = 3660, finish = 3661, success = 3662, attr = 0x0C, param = 268, extend = true },
    { tbl = 4, scq = 125, start = 3664, finish = 3665, success = 3666, attr = 0x05, param = 317, extend = true },
    { tbl = 5, scq = 1, start = 769, finish = 833, success = 2433, attr = 0x15, param = 273 },    -- case 1
    { tbl = 6, scq = 2, start = 770, finish = 834, success = 2434, attr = 0x15, param = 2192 },   -- case 2
    { tbl = 7, scq = 3, start = 771, finish = 835, success = 2435, attr = 0x15, param = 283 },    -- case 3
    { tbl = 8, scq = 4, start = 772, finish = 836, success = 2436, attr = 0x15, param = 286 },    -- case 4
    { tbl = 9, scq = 5, start = 773, finish = 837, success = 2437, attr = 0x15, param = 292 },    -- case 5
    { tbl = 10, scq = 6, start = 774, finish = 838, success = 2438, attr = 0x15, param = 313 },   -- case 6
    { tbl = 11, scq = 7, start = 775, finish = 839, success = 2439, attr = 0x15, param = 298 },   -- case 7
    { tbl = 12, scq = 8, start = 776, finish = 840, success = 2440, attr = 0x15, param = 304 },   -- case 8
    { tbl = 13, scq = 9, start = 777, finish = 841, success = 2441, attr = 0x15, param = 305 },   -- case 9
    { tbl = 14, scq = 126, start = 3668, finish = 3669, success = 3670, attr = 0x05, param = 317, extend = true },
    { tbl = 15, scq = 127, start = 3672, finish = 3673, success = 3674, attr = 0x0C, param = 317, extend = true },
    { tbl = 16, scq = 255, start = 824, finish = 888, success = 0, attr = 0x00, param = 0 },      -- no finish rule
    { tbl = 17, scq = 32, start = 779, finish = 843, success = 2443, attr = 0x40, param = 0 },    -- Kent, day 1
    { tbl = 18, scq = 33, start = 780, finish = 844, success = 2444, attr = 0x40, param = 1 },    -- Kent, day 2
    { tbl = 19, scq = 34, start = 781, finish = 845, success = 2445, attr = 0x40, param = 2 },    -- Kent, day 3
    { tbl = 20, scq = 35, start = 782, finish = 846, success = 2446, attr = 0x40, param = 3 },    -- The Hatchet Man
    { tbl = 21, scq = 36, start = 783, finish = 847, success = 2447, attr = 0x40, param = 4 },    -- A Strange Group
    { tbl = 22, scq = 37, start = 784, finish = 848, success = 2448, attr = 0x40, param = 5 },    -- Out of Control
    { tbl = 23, scq = 38, start = 785, finish = 849, success = 2449, attr = 0x40, param = 6 },    -- Above the Law
    { tbl = 24, scq = 39, start = 786, finish = 850, success = 2450, attr = 0x40, param = 7 },    -- Long Haired Punk
    { tbl = 25, scq = 64, start = 788, finish = 852, success = 2452, attr = 0x20, param = 0 },
    { tbl = 26, scq = 65, start = 789, finish = 853, success = 2453, attr = 0x20, param = 0 },    -- Shadow of the North Plaza
    { tbl = 27, scq = 66, start = 790, finish = 854, success = 2454, attr = 0x20, param = 0 },    -- The Coward
    { tbl = 28, scq = 67, start = 791, finish = 855, success = 2455, attr = 0x20, param = 0 },    -- Restaurant Man
    { tbl = 29, scq = 161, start = 808, finish = 872, success = 2472, attr = 0x03, param = 2493 }, -- Mark of the Sniper
    { tbl = 30, scq = 74, start = 798, finish = 862, success = 2462, attr = 0x20, param = 0 },    -- Mark of the Sniper
    { tbl = 31, scq = 69, start = 793, finish = 857, success = 2457, attr = 0x20, param = 0 },    -- Barricade Pair
    { tbl = 32, scq = 78, start = 802, finish = 866, success = 2466, attr = 0x20, param = 0 },    -- Barricade Pair
    { tbl = 33, scq = 70, start = 794, finish = 858, success = 2458, attr = 0x20, param = 0 },    -- The Woman Who Didn't Make it
    { tbl = 34, scq = 71, start = 795, finish = 859, success = 2459, attr = 0x20, param = 0 },    -- The Woman Who Didn't Make it
    { tbl = 35, scq = 72, start = 796, finish = 860, success = 2460, attr = 0x20, param = 0 },    -- A Mother's Lament
    { tbl = 36, scq = 73, start = 797, finish = 861, success = 2461, attr = 0x20, param = 0 },    -- Japanese Tourists
    { tbl = 37, scq = 79, start = 803, finish = 867, success = 2467, attr = 0x20, param = 0 },    -- Japanese Tourists
    { tbl = 38, scq = 68, start = 792, finish = 856, success = 2456, attr = 0x20, param = 0 },    -- Antique Lover
    { tbl = 39, scq = 75, start = 799, finish = 863, success = 2463, attr = 0x20, param = 0 },    -- A Sick Man
    { tbl = 40, scq = 76, start = 800, finish = 864, success = 2464, attr = 0x20, param = 0 },    -- Lovers
    { tbl = 41, scq = 80, start = 804, finish = 864, success = 2468, attr = 0x20, param = 0 },    -- Lovers
    { tbl = 42, scq = 77, start = 801, finish = 865, success = 2465, attr = 0x20, param = 0 },    -- A Woman in Despair
    { tbl = 43, scq = 96, start = 805, finish = 869, success = 2469, attr = 0x80, param = 0 },
    { tbl = 44, scq = 97, start = 806, finish = 870, success = 2470, attr = 0x80, param = 0 },
    { tbl = 45, scq = 99, start = 826, finish = 890, success = 2489, attr = 0x80, param = 0 },
    { tbl = 46, scq = 100, start = 827, finish = 891, success = 2490, attr = 0x80, param = 0 },
    { tbl = 47, scq = 101, start = 828, finish = 892, success = 2491, attr = 0x80, param = 0 },
    { tbl = 48, scq = 102, start = 829, finish = 893, success = 2492, attr = 0x80, param = 0 },
    { tbl = 49, scq = 160, start = 807, finish = 871, success = 2471, attr = 0x02, param = 0 },   -- The Convicts
    { tbl = 50, scq = 162, start = 809, finish = 873, success = 2473, attr = 0x02, param = 1 },
    { tbl = 51, scq = 163, start = 810, finish = 874, success = 2474, attr = 0x07, param = 1302 }, -- Cletus
    { tbl = 52, scq = 164, start = 811, finish = 875, success = 2475, attr = 0x07, param = 1294 }, -- A Strange Group, The Cult
    { tbl = 53, scq = 176, start = 812, finish = 876, success = 0, attr = 0x20, param = 0 },      -- Twin Sisters
    { tbl = 54, scq = 177, start = 813, finish = 877, success = 0, attr = 0x20, param = 0 },
    { tbl = 55, scq = 178, start = 814, finish = 878, success = 0, attr = 0x20, param = 0 },      -- Dressed for Action
    { tbl = 56, scq = 179, start = 815, finish = 879, success = 0, attr = 0x20, param = 0 },      -- The Woman Left Behind
    { tbl = 57, scq = 180, start = 816, finish = 880, success = 0, attr = 0x20, param = 0 },
    { tbl = 58, scq = 181, start = 817, finish = 881, success = 0, attr = 0x20, param = 0 },      -- Hanging by a Thread
    { tbl = 59, scq = 182, start = 818, finish = 882, success = 0, attr = 0x20, param = 0 },      -- The Drunkard
    { tbl = 60, scq = 183, start = 819, finish = 883, success = 0, attr = 0x20, param = 0 },      -- Gun Shop Standoff
    { tbl = 61, scq = 184, start = 820, finish = 884, success = 0, attr = 0x20, param = 0 },      -- Twin Sisters
    { tbl = 62, scq = 185, start = 821, finish = 885, success = 0, attr = 0x20, param = 0 },      -- Hanging by a Thread
    { tbl = 63, scq = 186, start = 822, finish = 886, success = 0, attr = 0x20, param = 0 },      -- Gun Shop Standoff
    { tbl = 64, scq = 187, start = 823, finish = 887, success = 0, attr = 0x20, param = 0 },      -- Gun Shop Standoff
    { tbl = 65, scq = 208, start = 0, finish = 0, success = 0, attr = 0x02, param = 0 },
    { tbl = 66, scq = 209, start = 830, finish = 894, success = 0, attr = 0x07, param = 315 },
    { tbl = 67, scq = 210, start = 0, finish = 0, success = 0, attr = 0x02, param = 0 },
    { tbl = 68, scq = 112, start = 2689, finish = 2721, success = 2753, attr = 0x07, param = 2071 },
    { tbl = 69, scq = 113, start = 2690, finish = 2722, success = 2754, attr = 0x07, param = 2079 },
    { tbl = 70, scq = 114, start = 2691, finish = 2723, success = 2755, attr = 0x07, param = 2072 },
    { tbl = 71, scq = 115, start = 2692, finish = 2724, success = 2756, attr = 0x07, param = 2073 },
    { tbl = 72, scq = 116, start = 2693, finish = 2725, success = 2757, attr = 0x07, param = 2074 },
    { tbl = 73, scq = 117, start = 2694, finish = 2726, success = 2758, attr = 0x07, param = 2075 },
    { tbl = 74, scq = 118, start = 2695, finish = 2727, success = 2759, attr = 0x07, param = 2076 },
    { tbl = 75, scq = 119, start = 2696, finish = 2728, success = 2760, attr = 0x07, param = 2077 },
    { tbl = 76, scq = 188, start = 2697, finish = 2729, success = 0, attr = 0x20, param = 0 },
    { tbl = 77, scq = 189, start = 2698, finish = 2730, success = 0, attr = 0x20, param = 0 },    -- The Convicts
    { tbl = 78, scq = 190, start = 2699, finish = 2731, success = 0, attr = 0x20, param = 0 },    -- The Cult
    { tbl = 79, scq = 191, start = 2700, finish = 2732, success = 0, attr = 0x20, param = 0 },    -- A Strange Group
    { tbl = 80, scq = 192, start = 2701, finish = 2733, success = 0, attr = 0x20, param = 0 },    -- A Strange Group
    { tbl = 81, scq = 193, start = 2702, finish = 2734, success = 0, attr = 0x20, param = 0 },    -- A Strange Group
    { tbl = 82, scq = 194, start = 2703, finish = 2735, success = 0, attr = 0x20, param = 0 },    -- A Strange Group
    { tbl = 83, scq = 195, start = 2704, finish = 2736, success = 0, attr = 0x20, param = 0 },    -- A Strange Group
    { tbl = 84, scq = 196, start = 2705, finish = 2737, success = 0, attr = 0x20, param = 0 },    -- The Hatchet Man
    { tbl = 85, scq = 197, start = 2706, finish = 2738, success = 0, attr = 0x20, param = 0 },    -- The Hatchet Man
    { tbl = 86, scq = 198, start = 2707, finish = 2739, success = 0, attr = 0x20, param = 0 },    -- The Hatchet Man
    { tbl = 87, scq = 199, start = 2708, finish = 2740, success = 0, attr = 0x20, param = 0 },    -- Long Haired Punk
    { tbl = 88, scq = 200, start = 2709, finish = 2741, success = 0, attr = 0x20, param = 0 },    -- Long Haired Punk
    { tbl = 89, scq = 201, start = 2710, finish = 2742, success = 0, attr = 0x20, param = 0 },    -- Kent, day 3
    { tbl = 90, scq = 202, start = 2711, finish = 2743, success = 0, attr = 0x20, param = 0 },    -- Out of Control
    { tbl = 91, scq = 203, start = 2712, finish = 2744, success = 0, attr = 0x20, param = 0 },    -- Above the Law
    { tbl = 92, scq = 204, start = 2713, finish = 2745, success = 0, attr = 0x20, param = 0 },    -- Above the Law
    { tbl = 93, scq = 205, start = 2714, finish = 2746, success = 0, attr = 0x20, param = 0 },    -- Above the Law
    { tbl = 94, scq = 206, start = 2715, finish = 2747, success = 0, attr = 0x20, param = 0 },    -- Above the Law
    { tbl = 95, scq = 128, start = 3676, finish = 3677, success = 3678, attr = 0x05, param = 442, extend = true },
    { tbl = 96, scq = 120, start = 2716, finish = 2748, success = 2767, attr = 0x07, param = 2061 },
    { tbl = 97, scq = 129, start = 3680, finish = 3681, success = 3682, attr = 0x05, param = 151, extend = true },
    { tbl = 98, scq = 130, start = 3684, finish = 3685, success = 3686, attr = 0x05, param = 139, extend = true },
}

-- rSCQTable.mEnemyInfoSets, by index: members in the game's order. type 0 is
-- an appearance with a time limit, 1 a success flag, 2 a fail flag, 3 the end
-- of the list.
M.ENEMY_SETS = {
    [0] = { { flag = 342, type = 1 }, { flag = 2541, type = 0 }, { flag = 346, type = 2 }, { flag = 1290, type = 2 } },
    [1] = { { flag = 352, type = 1 }, { flag = 2542, type = 0 }, { flag = 346, type = 2 }, { flag = 1291, type = 2 } },
    [2] = { { flag = 1292, type = 1 }, { flag = 1155, type = 0 } },
    [3] = { { flag = 1293, type = 1 }, { flag = 324, type = 0 } },
    [4] = { { flag = 1294, type = 1 }, { flag = 327, type = 0 } },
    [5] = { { flag = 1295, type = 1 }, { flag = 329, type = 0 } },
    [6] = { { flag = 1296, type = 1 }, { flag = 337, type = 0 } },
    [7] = { { flag = 1297, type = 1 }, { flag = 331, type = 0 } },
    [8] = { { flag = 1302, type = 1 }, { flag = 325, type = 0 } },
}

-- mFinishAttr bits, as SCQManager.checkQueFinish reads them.
local ATTR_FLAG = 0x01      -- finished once mFinishParam's flag is on
local ATTR_SUCCESS = 0x04   -- ...and that finish is a success
local ATTR_FLAGS = 0x08     -- a flag or a flag list (other game modes only; not modelled)
local ATTR_CASE = 0x10      -- a main case
local ATTR_NPC = 0x20       -- survivor or captive: finished at the join
local ATTR_ENEMY = 0x40     -- mFinishParam indexes ENEMY_SETS

local MEMBER_SUCCESS, MEMBER_FAIL, MEMBER_END = 1, 2, 3

-- KentChain arms and retires Kent's first two days itself, and holds day 1's
-- FINISH off on purpose while day 2 runs. Day 3 ends in a fight and is
-- finished like any psychopath.
local KENTCHAIN_ROWS = { [32] = true, [33] = true }

local PROTECTED = {}   -- flag -> row
local EXCLUDED = {}    -- scq -> why the rules leave it alone
local OWNED_BY = {}    -- scq -> psychopath scoops whose start set starts it
local CASE_OF = {}     -- scq -> main scoop whose completion ends that case

local state = { enabled = true, due = {}, attempts = {}, refused = {} }

--- The row's own finish rule, read from flags only: "success" (the game writes
--- FINISH and SUCCESS), "end" (a flag finish without the success bit: FINISH
--- only), "fail", or nil while it doesn't hold. Time limits aren't modelled:
--- they only ever end a scoop as a failure, and failures stay the game's.
function M.outcome(row, is_on)
    local attr = row.attr
    if attr & ATTR_ENEMY ~= 0 then
        for _, m in ipairs(M.ENEMY_SETS[row.param] or {}) do
            if m.type == MEMBER_END then return nil end
            if m.type == MEMBER_SUCCESS and is_on(m.flag) == true then return "success" end
            if m.type == MEMBER_FAIL and is_on(m.flag) == true then return "fail" end
        end
        return nil
    end
    if attr & ATTR_FLAGS == 0 and attr & ATTR_FLAG ~= 0 and row.param ~= 0
            and is_on(row.param) == true then
        return (attr & ATTR_SUCCESS ~= 0) and "success" or "end"
    end
    return nil
end

--- deps:
---   exempt_flags           flags DRAP clears on purpose (the cult respawn)
---   scoop_data             name -> { category, flags, chain_managed }
---   main_completion_flags  flag -> the main scoop it completes
function M.configure(deps)
    deps = deps or {}
    local exempt = {}
    for _, f in ipairs(deps.exempt_flags or {}) do exempt[f] = true end
    PROTECTED, EXCLUDED, OWNED_BY, CASE_OF = {}, {}, {}, {}

    local by_start = {}
    for _, row in ipairs(M.ROWS) do
        if row.start ~= 0 then by_start[row.start] = row end
        for _, f in ipairs({ row.finish, row.success }) do
            if f ~= 0 and not exempt[f] then PROTECTED[f] = row end
        end
        if row.finish == 0 then
            EXCLUDED[row.scq] = "no flags"
        elseif row.extend then
            EXCLUDED[row.scq] = "other game modes"
        elseif exempt[row.finish] or exempt[row.success] then
            EXCLUDED[row.scq] = "cleared on purpose by the cult respawn"
        elseif KENTCHAIN_ROWS[row.scq] then
            EXCLUDED[row.scq] = "KentChain finishes it"
        end
    end

    for name, data in pairs(deps.scoop_data or {}) do
        if data.category == "Psychopath" and not data.chain_managed then
            for _, f in ipairs(data.flags or {}) do
                local row = by_start[f]
                -- Never a captive's row: captives finish with their own rescues.
                if row and row.attr & ATTR_NPC == 0 then
                    OWNED_BY[row.scq] = OWNED_BY[row.scq] or {}
                    table.insert(OWNED_BY[row.scq], name)
                end
            end
        end
    end

    -- A case row ends on the completion flag of the main that closes the case
    -- (A Temporary Agreement's 273 ends case 1), or is that completion itself
    -- (The Last Resort completes on case 7's FINISH).
    for flag, name in pairs(deps.main_completion_flags or {}) do
        for _, row in ipairs(M.ROWS) do
            if row.attr & ATTR_CASE ~= 0 and (row.param == flag or row.finish == flag) then
                CASE_OF[row.scq] = name
            end
        end
    end
end

--- Rule 1: true when DRAP must never clear this flag.
function M.never_off(flag_id)
    return state.enabled and PROTECTED[flag_id] ~= nil
end

--- True the first time a caller is turned away for this flag this session
--- (so it logs once).
function M.first_refusal(flag_id, who)
    local sig = tostring(flag_id) .. ":" .. tostring(who)
    if state.refused[sig] then return false end
    state.refused[sig] = true
    return true
end

function M.row_of(flag_id) return PROTECTED[flag_id] end
function M.excluded(scq) return EXCLUDED[scq] end
function M.case_of(scq) return CASE_OF[scq] end
function M.owners(scq) return OWNED_BY[scq] end

-- Rows whose FINISH and SUCCESS the game writes together: a survivor's at the
-- join, and every row it finishes by its own check. SUCCESS on with FINISH
-- off is never a state the game leaves on one of these.
local function writes_both(row)
    return row.success ~= 0
        and row.attr & (ATTR_FLAG | ATTR_CASE | ATTR_NPC | ATTR_ENEMY) ~= 0
end

local function completed_owner(row, ctx)
    for _, name in ipairs(OWNED_BY[row.scq] or {}) do
        if ctx.is_completed(name) then return name end
    end
    return nil
end

--- Why a row should be finished now, or nil. Returns reason, success.
function M.why_due(row, ctx)
    local check = ctx.check
    if check(row.finish) ~= false then return nil end   -- finished, or unreadable
    if writes_both(row) and check(row.success) == true then
        return "SUCCESS on, FINISH off", true
    end
    -- The rule is only the game's while the row runs. Cletus's START is
    -- cleared once his scoop completes, and the row still belongs to a scoop
    -- that has been won.
    local owner = nil
    local running = check(row.start) == true
    if not running then owner = completed_owner(row, ctx) end
    if running or owner then
        local out = M.outcome(row, check)
        if out == "success" or out == "end" then
            local why = owner and ("own finish rule holds, '" .. owner .. "' completed")
                or "own finish rule holds"
            return why, out == "success"
        end
    end
    local case = CASE_OF[row.scq]
    if case and ctx.is_completed(case) then
        return "'" .. case .. "' completed", true
    end
    return nil
end

--- ctx:
---   check(flag) -> true/false/nil  (nil = unreadable, treated as not finished-able)
---   now          seconds
---   active       the caller's gates hold (ScoopSanity, activated, not Overtime,
---                world stable)
---   loop_running the game's SCQ loop is running (a main case waits otherwise)
---   is_completed(name) -> bool, DRAP's view
--- Returns the rows to finish now: { row, success, reason, since, attempt }.
--- attempt counts the calls since the row's FINISH was last seen on.
function M.tick(ctx)
    local finish = {}
    if not state.enabled or not ctx.active then
        state.due = {}
        return finish
    end
    for _, row in ipairs(M.ROWS) do
        local scq = row.scq
        if not EXCLUDED[scq] then
            local reason, success = M.why_due(row, ctx)
            if ctx.check(row.finish) == true then state.attempts[scq] = nil end
            local waits = row.attr & ATTR_CASE ~= 0 and not ctx.loop_running
            if not reason or waits then
                state.due[scq] = nil
            else
                local since = state.due[scq] or ctx.now
                state.due[scq] = since
                local n = state.attempts[scq] or 0
                local wait = n < M.MAX_QUICK_ATTEMPTS and M.DWELL_SECONDS or M.RETRY_SECONDS
                if ctx.now - since >= wait then
                    state.due[scq] = nil
                    state.attempts[scq] = n + 1
                    finish[#finish + 1] = { row = row, success = success, reason = reason,
                                            since = since, attempt = n + 1 }
                end
            end
        end
    end
    return finish
end

--- Off, DRAP neither guards these flags nor finishes any row: the behaviour
--- before this module, for comparison.
function M.set_enabled(on)
    state.enabled = on ~= false
    state.due = {}
    return state.enabled
end

function M.is_enabled() return state.enabled end

--- A new session (a load or a new game): forget waits, attempts and refusals.
function M.reset()
    state.due, state.attempts, state.refused = {}, {}, {}
end

function M.status()
    local function copy(t)
        local c = {}
        for k, v in pairs(t) do c[k] = v end
        return c
    end
    local n = 0
    for _ in pairs(PROTECTED) do n = n + 1 end
    return { enabled = state.enabled, protected = n, due = copy(state.due),
             attempts = copy(state.attempts), excluded = copy(EXCLUDED),
             case_of = copy(CASE_OF) }
end

M.configure()

return M
