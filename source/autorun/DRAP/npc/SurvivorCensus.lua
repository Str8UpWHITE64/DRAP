-- DRAP/npc/SurvivorCensus.lua
-- Observation history for survivor records, and the single verdict on what a
-- record's current shape actually means.
--
-- WHY THIS EXISTS: an NpcBaseInfo that is isDead with mLiveState=UNKNOWN and
-- hp=0 has three completely different causes -- a newborn record still being
-- initialised, a corrupt record the flag-spawn never filled in, and a survivor
-- the player killed before ever meeting them. Judging that shape from a single
-- frame cannot tell them apart, so killed survivors were being reported broken,
-- removed, and resurrected. History is what separates them: a survivor we once
-- saw alive and now see as a corpse is dead, not broken.
--
-- PURITY CONTRACT: touches no engine state (no sdk, json, imgui, re.on_frame).
-- Records arrive as plain tables, so it is unit-testable outside the game
-- (tools/logic_tests/test_survivor_census.py, under lupa).

local M = {}

M.VERDICT = {
    HEALTHY       = "healthy",        -- alive; nothing to do
    KILLED        = "killed",         -- died legitimately; never repair
    CORRUPT       = "corrupt",        -- record exists but was never filled in
    VANISHED      = "vanished",       -- we saw them alive, now no record at all
    NEVER_SPAWNED = "never_spawned",  -- no record and never seen; not yet created
}

local LIVE_STATE_UNKNOWN = 0
local LIVE_STATE_JOIN = 2

-- stype -> { ever_alive, ever_joined, death_seen, max_state, last_state, last_area }
local history = {}
local dirty = false

local cfg = {
    log = function(_) end,
    -- Which stypes are worth remembering. Callers exclude the HostileSurvivor
    -- trap pool, which is spawned and killed constantly and would rewrite the
    -- persisted census every tick for survivors no repair path cares about.
    should_track = function(_) return true end,
}

function M.init(options)
    for k, v in pairs(options or {}) do cfg[k] = v end
end

------------------------------------------------------------
-- Record shape helpers
------------------------------------------------------------

-- A record is only evidence of life when the engine has actually filled it in;
-- a half-initialised one reads as hp=0 and isDead=true, same as a corpse.
local function is_alive(e)
    return (not e.is_dead) and (tonumber(e.hp) or 0) > 0
end

-- The ambiguous shape: dead, never progressed past UNKNOWN, no health. Every
-- cause listed at the top of this file produces exactly this.
local function is_zeroed_corpse(e)
    return e.is_dead
        and (tonumber(e.state) or 0) == LIVE_STATE_UNKNOWN
        and (tonumber(e.hp) or 0) == 0
end

M.is_alive = is_alive
M.is_zeroed_corpse = is_zeroed_corpse

------------------------------------------------------------
-- Observation
------------------------------------------------------------

local function blank()
    return {
        ever_alive = false, ever_joined = false, death_seen = false,
        max_state = 0, last_state = nil, last_area = nil,
    }
end

function M.get(stype)
    return history[stype]
end

local function fold(h, e)
    local state = tonumber(e.state) or 0

    if is_alive(e) then
        h.ever_alive = true
        -- Reload safety: seeing them alive again after a recorded death means
        -- the player loaded a save from before it, so the death is not real.
        h.death_seen = false
    elseif e.is_dead and h.ever_alive then
        h.death_seen = true
    end

    if state > (h.max_state or 0) then h.max_state = state end
    if state == LIVE_STATE_JOIN then h.ever_joined = true end
    h.last_state = state
    h.last_area = tonumber(e.area)
end

-- Only the persisted fields, so a frame that changes nothing durable does not
-- mark the census dirty and trigger a ledger write every tick.
local function signature(h)
    return table.concat({
        tostring(h.ever_alive), tostring(h.ever_joined),
        tostring(h.death_seen), tostring(h.max_state),
    }, "/")
end

--- Folds one frame's scan into the history.
--- @param by_stype table stype -> array of record tables
function M.observe(by_stype)
    for stype, records in pairs(by_stype or {}) do
        if cfg.should_track(stype) then
            local h = history[stype]
            if not h then
                h = blank()
                history[stype] = h
                dirty = true
            end
            local before = signature(h)
            for _, e in ipairs(records) do fold(h, e) end
            if signature(h) ~= before then dirty = true end
        end
    end
end

------------------------------------------------------------
-- Verdict
------------------------------------------------------------

--- What a survivor's current records mean, given what we have seen before.
--- @param records table|nil array of record tables for one stype
--- @param h table|nil that stype's history
--- @return string one of M.VERDICT
function M.verdict(records, h)
    h = h or {}
    local n = records and #records or 0

    if n == 0 then
        -- Never had a record: the engine creates them lazily on area entry, so
        -- this is normal until their area is visited.
        if h.ever_alive then return M.VERDICT.VANISHED end
        return M.VERDICT.NEVER_SPAWNED
    end

    local any_alive, all_zeroed = false, true
    for _, e in ipairs(records) do
        if is_alive(e) then any_alive = true end
        if not is_zeroed_corpse(e) then all_zeroed = false end
    end

    if any_alive then return M.VERDICT.HEALTHY end

    -- Dead with a state the engine advanced past UNKNOWN: unambiguous corpse.
    if not all_zeroed then return M.VERDICT.KILLED end

    -- Ambiguous shape. History decides: anything proving they once existed
    -- properly means the player killed them.
    if h.ever_alive or h.death_seen or (tonumber(h.max_state) or 0) > 0 then
        return M.VERDICT.KILLED
    end
    return M.VERDICT.CORRUPT
end

--- Verdict using the stored history for that stype.
function M.verdict_for(stype, records)
    return M.verdict(records, history[stype])
end

------------------------------------------------------------
-- Persistence
------------------------------------------------------------

function M.is_dirty() return dirty end
function M.clear_dirty() dirty = false end

function M.serialize()
    local survivors = {}
    for stype, h in pairs(history) do
        survivors[tostring(stype)] = {
            ever_alive = h.ever_alive or false,
            ever_joined = h.ever_joined or false,
            death_seen = h.death_seen or false,
            max_state = h.max_state or 0,
            last_state = h.last_state,
            last_area = h.last_area,
        }
    end
    return { version = 1, survivors = survivors }
end

function M.restore(doc)
    history = {}
    dirty = false
    local survivors = doc and doc.survivors
    if type(survivors) ~= "table" then return false end
    local n = 0
    for stype_s, h in pairs(survivors) do
        local stype = tonumber(stype_s)
        if stype and type(h) == "table" then
            history[stype] = {
                ever_alive = h.ever_alive == true,
                ever_joined = h.ever_joined == true,
                death_seen = h.death_seen == true,
                max_state = tonumber(h.max_state) or 0,
                last_state = tonumber(h.last_state),
                last_area = tonumber(h.last_area),
            }
            n = n + 1
        end
    end
    cfg.log(string.format("census restored: %d survivor(s)", n))
    return true
end

function M.reset()
    history = {}
    dirty = false
end

--- Counts by verdict-relevant history, for status commands.
function M.stats()
    local total, alive_seen, deaths, joined = 0, 0, 0, 0
    for _, h in pairs(history) do
        total = total + 1
        if h.ever_alive then alive_seen = alive_seen + 1 end
        if h.death_seen then deaths = deaths + 1 end
        if h.ever_joined then joined = joined + 1 end
    end
    return { total = total, ever_alive = alive_seen,
             deaths = deaths, ever_joined = joined }
end

return M
