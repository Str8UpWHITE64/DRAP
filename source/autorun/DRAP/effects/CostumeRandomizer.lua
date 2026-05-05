-- DRAP/effects/CostumeRandomizer.lua
-- Costume randomization driven by three slot-data toggles:
-- random_starting_costume / costume_chaos_mode / dlc_outfits_enabled.
-- See docs/reframework/features/costume_randomizer.md.
--
-- Body pool 0..42 (regular) or 0..62 with DLC. Body in 0..42 also rolls
-- Foot/Hat/Glasses; DLC anchor (43..62) is a full-outfit replacement so
-- the engine handles the rest of the slots itself.

local M = {}

local FRANK_CHAR    = 285212929
local CHANGER_TYPE  = "app.solid.PlayerCostumeChanger"
local PM_TYPE       = "app.solid.PlayerManager"
local AM_TYPE       = "app.solid.gamemastering.AreaManager"

-- Valid pools per slot (verified empirically via drap_costume_cycle runs).
local POOL = {
    body_regular_hi = 42,                        -- IDs 0..42
    body_dlc_hi     = 62,                        -- IDs 0..62 when DLC enabled
    foot            = { lo = 0, hi = 9 },        -- IDs 0..9
    hat             = { lo = 0, hi = 19 },       -- IDs 0..19
    glasses_set     = { 0, 1, 2, 3, 4, 5, 6, 7, 10 },  -- non-contiguous (0 = "no glasses")
}

local config = {
    chaos_mode       = false,
    starting_costume = false,
    dlc_enabled      = false,
}

local state = {
    chaos_hook_installed = false,
    starting_pending     = false,
    starting_done        = false,
    on_frame_registered  = false,
}

local Shared = require("DRAP/Shared")
local log = Shared.create_logger("CostumeRandomizer")

-- Resolve the live PlayerCostumeChanger component (or nil if Frank isn't
-- spawned yet -- e.g. during the title screen).
local function get_changer()
    local pm = sdk.get_managed_singleton(PM_TYPE)
    if not pm then return nil end
    local ok_go, go = pcall(function() return pm:call("get_CurrentPlayer") end)
    if not ok_go or not go then return nil end
    local ok_c, comp = pcall(function()
        return go:call("getComponent(System.Type)", sdk.typeof(CHANGER_TYPE))
    end)
    if not ok_c then return nil end
    return comp
end

-- Fire one part swap via the canonical CHANGER.change(charType, costume, part)
-- primitive. Wrapped in pcall so a single bad costume can't crash the run.
local function fire_change(part, id)
    local changer = get_changer()
    if not changer then return false end
    local ok = pcall(function()
        changer:call("change", FRANK_CHAR, id, part)
    end)
    return ok
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Pick + apply a random outfit. Returns true if attempted, false if the
-- player isn't spawned yet.
function M.do_random_swap()
    if not get_changer() then
        return false
    end

    -- 1. Body pick.
    local body_hi = config.dlc_enabled and POOL.body_dlc_hi or POOL.body_regular_hi
    local body = math.random(0, body_hi)
    fire_change(0, body)

    if body >= 43 then
        -- DLC anchor: engine swaps the other slots itself.
        log(string.format("Random outfit (DLC anchor): body=%d", body))
        return true
    end

    -- 2. Regular body: also randomize accessories.
    local foot    = math.random(POOL.foot.lo, POOL.foot.hi)
    local hat     = math.random(POOL.hat.lo, POOL.hat.hi)
    local glasses = POOL.glasses_set[math.random(1, #POOL.glasses_set)]
    fire_change(1, foot)
    fire_change(2, hat)
    fire_change(3, glasses)
    log(string.format("Random outfit: body=%d foot=%d hat=%d glasses=%d",
        body, foot, hat, glasses))
    return true
end

-- Install the chaos-mode hook on AreaManager.onLoadMapEvent. Idempotent.
local function install_chaos_hook()
    if state.chaos_hook_installed then return true end
    local td = sdk.find_type_definition(AM_TYPE)
    if not td then log("AreaManager type missing"); return false end
    local m = td:get_method("onLoadMapEvent")
    if not m then log("onLoadMapEvent method missing"); return false end
    sdk.hook(m,
        function(args) end,
        function(retval)
            -- Gate on the live config flag so toggling chaos off via reload
            -- (or setup re-run) silences the hook without an unhook primitive.
            if not config.chaos_mode then return retval end
            -- The player may not be spawned for non-gameplay scenes (title,
            -- menu); do_random_swap returns early in that case.
            M.do_random_swap()
            return retval
        end)
    state.chaos_hook_installed = true
    log("chaos-mode hook installed (AreaManager.onLoadMapEvent)")
    return true
end

-- Cycle-tester state for the diagnostic stepper. cycle.active gates the
-- per-frame loop; cycle.next_at is an os.clock() deadline for the next swap.
local cycle = {
    active   = false,
    part     = 0,           -- 0=body, 1=foot, 2=hat, 3=glasses
    list     = {},          -- ordered list of ids to walk
    idx      = 1,
    interval = 1.0,         -- seconds
    next_at  = 0,
    label    = "",
}

local function cycle_stop(reason)
    if not cycle.active then return end
    cycle.active = false
    log(string.format("cycle stopped: %s", reason or "manual"))
end

local function cycle_step()
    if not cycle.active then return end
    if os.clock() < cycle.next_at then return end
    if cycle.idx > #cycle.list then
        cycle_stop("complete")
        return
    end
    local id = cycle.list[cycle.idx]
    log(string.format("cycle [%s] %d/%d -> id=%d",
        cycle.label, cycle.idx, #cycle.list, id))
    fire_change(cycle.part, id)
    cycle.idx = cycle.idx + 1
    cycle.next_at = os.clock() + cycle.interval
end

-- Per-frame waiter that drives starting-costume application once the player
-- is spawned. Registered at module load (registering re.on_frame from within
-- another on_frame disrupts REFramework's iteration).
re.on_frame(function()
    if state.starting_pending and not state.starting_done then
        local changer = get_changer()
        if changer then
            state.starting_done    = true
            state.starting_pending = false
            log("Applying random starting costume...")
            M.do_random_swap()
        end
    end
    cycle_step()
end)

-- Configure from slot data. Called from AP_DRDR_main on slot-connect.
function M.setup(opts)
    opts = opts or {}
    config.chaos_mode       = opts.chaos_mode       and true or false
    config.starting_costume = opts.starting_costume and true or false
    config.dlc_enabled      = opts.dlc_enabled      and true or false
    log(string.format("setup: chaos=%s starting=%s dlc=%s",
        tostring(config.chaos_mode),
        tostring(config.starting_costume),
        tostring(config.dlc_enabled)))

    if config.chaos_mode then
        install_chaos_hook()
    end

    if config.starting_costume and not state.starting_done then
        state.starting_pending = true
    end
end

-- Manual re-roll of the starting-costume (dev console).
function M.reroll_starting_costume()
    state.starting_done    = false
    state.starting_pending = true
end

function M.register()
    -- No-op at module load time. setup() drives behavior based on slot data.
end

_G.drap_random_outfit       = function() M.do_random_swap() end
_G.drap_costume_set_chaos   = function(b) config.chaos_mode = b and true or false
                                          if config.chaos_mode then install_chaos_hook() end
                                          log("chaos_mode = " .. tostring(config.chaos_mode)) end
_G.drap_costume_set_dlc     = function(b) config.dlc_enabled = b and true or false
                                          log("dlc_enabled = " .. tostring(config.dlc_enabled)) end

-- Reset Frank to Body=0 / Foot=0 / Hat=0 / Glasses=0 (useful for isolating
-- a costume-specific model bug from a general aim-IK / mesh issue).
_G.drap_costume_reset_vanilla = function()
    fire_change(0, 0)
    fire_change(1, 0)
    fire_change(2, 0)
    fire_change(3, 0)
    log("reset to vanilla: body=0 foot=0 hat=0 glasses=0")
end

-- Apply a specific costume part by index/id (e.g. drap_costume_set(0, 21) = body 21).
_G.drap_costume_set = function(part, id)
    part = tonumber(part); id = tonumber(id)
    if not part or not id then log("usage: drap_costume_set(part_idx, id)"); return end
    fire_change(part, id)
    log(string.format("set part=%d id=%d", part, id))
end

-- Cycle through every id for a given part, swapping once per `interval` seconds.
-- Used to identify which costume entry causes Frank to render invisible: watch
-- the screen, note the id logged when invisibility hits.
local function start_cycle(part, label, ids, interval)
    if not get_changer() then
        log("cycle: player not spawned -- enter gameplay first")
        return false
    end
    cycle.active   = true
    cycle.part     = part
    cycle.list     = ids
    cycle.idx      = 1
    cycle.interval = tonumber(interval) or 1.0
    cycle.next_at  = 0   -- fire first swap immediately
    cycle.label    = label
    log(string.format("cycle started: part=%d (%s) ids=%d..%d step=%ss",
        part, label, ids[1], ids[#ids], tostring(cycle.interval)))
    return true
end

local function range(lo, hi)
    local out = {}
    for i = lo, hi do out[#out + 1] = i end
    return out
end

-- drap_costume_cycle_bodies([interval])
-- Cycles body ids (0..42 always; 0..62 if DLC enabled). 1-second default.
_G.drap_costume_cycle_bodies = function(interval)
    local hi = config.dlc_enabled and POOL.body_dlc_hi or POOL.body_regular_hi
    start_cycle(0, "body", range(0, hi), interval)
end

-- drap_costume_cycle_feet([interval])
_G.drap_costume_cycle_feet = function(interval)
    start_cycle(1, "foot", range(POOL.foot.lo, POOL.foot.hi), interval)
end

-- drap_costume_cycle_hats([interval])
_G.drap_costume_cycle_hats = function(interval)
    start_cycle(2, "hat", range(POOL.hat.lo, POOL.hat.hi), interval)
end

-- drap_costume_cycle_glasses([interval])
_G.drap_costume_cycle_glasses = function(interval)
    local ids = {}
    for _, v in ipairs(POOL.glasses_set) do ids[#ids + 1] = v end
    start_cycle(3, "glasses", ids, interval)
end

-- drap_costume_cycle_stop()
_G.drap_costume_cycle_stop = function() cycle_stop("manual") end

return M
