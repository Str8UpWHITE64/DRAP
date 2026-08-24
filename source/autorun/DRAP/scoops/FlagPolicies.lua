-- DRAP/scoops/FlagPolicies.lua
-- Declarative flag policies for the ScoopSanity reconciler (Phase 3 of
-- the ScoopUnlocker rework). Each policy answers "what should these
-- flags be right now" as CLAIMS; it never writes anything.
--
-- PURITY CONTRACT: no engine access. Data tables arrive via build();
-- per-tick game state arrives via the ctx object. Unit-tested headlessly
-- in tools/logic_tests/test_flag_policies.py.
--
-- Priority encodes legacy statement order (later loop won). Same-flag
-- claims resolve to the higher priority, and the reconciler logs the
-- conflict with both owners named.
--
--   100 endgame        (exclusive: gates everything else off)
--    90 blacklist
--    85 pre-activation side suppression
--    80 post-jessie    (unshielded: writes stay visible to the evFlagOn hook)
--    70 cult respawn
--    60 area toggle 355
--    56 active side-scoop flags          (> 55/54: active flags beat a
--                                         suppressed sibling's shared flag)
--    55 conflict-group suppression
--    54 main-blocks-side suppression
--    52 disable_flags of active scoops   (above controlled: legacy ran it later)
--    50 controlled main-scoop flags
--    45 completed side-scoop cleanup
--    35 door-randomizer 514
--    30 cascade cleanup
--
-- ctx fields (built per tick by ScoopUnlocker):
--   activated, endgame, scoop_sanity, cult_limited, scene, goal_mode,
--   door_randomizer, area, hideout_area, north_plaza_area,
--   check_flag(fid) -> true/false/nil,
--   in_grace(name), is_active(name), is_completed(name),
--   is_conflict_blocked(name), is_blocked_by_active_main(name),
--   has_prerequisites_met(name)

local M = {}

-- deps: the data tables owned by ScoopUnlocker.
--   scoop_data, controlled_flags, cascade_flags, all_side_scoop_flags,
--   blacklist, protected_primary_flags, main_blocks_side,
--   post_jessie_flags, queen_spawn_flag, cult_on, cult_off,
function M.build(deps)
    local D = deps

    local function is_protected_primary(ctx, flag_id, scoop_name)
        local entry = D.protected_primary_flags[flag_id]
        if not entry then return false end
        if entry.scoop ~= scoop_name then return false end
        -- until_transition: also protected for one area load after
        -- while_active lapses. ScoopUnlocker owns the latch (it needs state
        -- across ticks); this stays a pure ctx read.
        if entry.until_transition and ctx.in_transition_grace
                and ctx.in_transition_grace(flag_id) then
            return true
        end
        if entry.while_active then
            return ctx.is_active(entry.while_active)
        end
        return true
    end

    local policies = {}
    local function policy(p) table.insert(policies, p) end

    ----------------------------------------------------------------
    -- Nothing is claimed in Overtime, deliberately. The game already puts
    -- the world in the state Overtime needs on the way in: a vanilla save
    -- measured at the Overtime spawn had 301, 2322, 265, 355, 2052 and 514
    -- already on, with no mod running at all.
    --
    -- What used to be here forced 2052/514 on -- which the game does itself --
    -- and drove 301 on inside the hideout and OFF everywhere else. That last
    -- one was the only difference from vanilla we could find, and vanilla
    -- never turns 301 off. Every other policy below already returns early on
    -- ctx.endgame; this finishes the rule rather than starting a new one.

    ----------------------------------------------------------------
    policy{
        name = "blacklist", priority = 90,
        collect = function(ctx, claim)
            if ctx.endgame then return end
            for flag_id, _ in pairs(D.blacklist) do
                -- Hideout entry window: 392 on + 355 not yet -> leave 300
                -- alone so the player can enter.
                local in_window = flag_id == 300
                    and ctx.check_flag(392) and not ctx.check_flag(355)
                if not in_window then
                    claim(flag_id, "off")
                end
            end
        end,
    }

    ----------------------------------------------------------------
    policy{
        name = "pre-activation-sides", priority = 85,
        collect = function(ctx, claim)
            if ctx.endgame or ctx.activated then return end
            for flag_id, _ in pairs(D.all_side_scoop_flags) do
                claim(flag_id, "off")
            end
        end,
    }

    ----------------------------------------------------------------
    policy{
        name = "post-jessie", priority = 80, unshielded = true,
        collect = function(ctx, claim)
            if ctx.endgame or not ctx.activated then return end
            for _, fid in ipairs(D.post_jessie_flags) do
                claim(fid, "on")
            end
            -- Savior without ScoopSanity: force the EP-shutter chain
            -- flag. (Unreachable inside the SS-only reconciler today;
            -- encoded for fidelity with the legacy loop.)
            if ctx.goal_mode == 2 and not ctx.scoop_sanity then
                claim(270, "on")
            end
        end,
    }

    ----------------------------------------------------------------
    policy{
        name = "queen-spawning", priority = 80, unshielded = true,
        collect = function(ctx, claim)
            if ctx.endgame or not ctx.activated then return end
            if not D.queen_spawn_flag then return end
            -- Off is claimed as well as on: meeting Jessie turns this on by
            -- itself, so not claiming it would let queens spawn anyway.
            claim(D.queen_spawn_flag, ctx.queens_unlocked and "on" or "off")
        end,
    }

    ----------------------------------------------------------------
    policy{
        name = "cult-respawn", priority = 70,
        collect = function(ctx, claim)
            if ctx.endgame then return end
            if not ctx.is_completed("A Strange Group") then return end
            if ctx.cult_limited then
                -- Cult Limited: keep cultists in Colby's theater (scene
                -- s503) by clearing the spawn flag everywhere else. Keyed
                -- on scene, not area -- door-rando can reroute the exit.
                if ctx.scene and not ctx.scene:find("s503") then
                    claim(2063, "off")
                end
            else
                for _, fid in ipairs(D.cult_on) do claim(fid, "on") end
                for _, fid in ipairs(D.cult_off) do claim(fid, "off") end
            end
        end,
    }

    ----------------------------------------------------------------
    policy{
        name = "area-355", priority = 60,
        collect = function(ctx, claim)
            if ctx.endgame or not ctx.activated then return end
            -- While the Hideout scoop is active the game manages 355
            -- itself (cutscene) -- no claim at all.
            if ctx.is_active("Hideout") then return end
            if ctx.area == ctx.north_plaza_area then
                claim(355, "on")
            elseif ctx.area == ctx.hideout_area then
                claim(355, "off")
            end
        end,
    }

    ----------------------------------------------------------------
    policy{
        name = "conflict-suppress", priority = 55,
        collect = function(ctx, claim)
            if ctx.endgame or not ctx.activated then return end
            for scoop_name, data in pairs(D.scoop_data) do
                -- chain_managed (Kent): the days' start sets are CUMULATIVE
                -- and share flags (day 3's set contains day 1/2's STARTs),
                -- so suppressing a blocked sibling's list here clears the
                -- ACTIVE day's own flags out from under KentChain. The
                -- chain module is the only writer for these.
                if data.flags and not data.chain_managed
                    and not ctx.is_completed(scoop_name)
                    and ctx.is_conflict_blocked(scoop_name) then
                    for _, flag_id in ipairs(data.flags) do
                        if flag_id and flag_id ~= 0 then
                            claim(flag_id, "off")
                        end
                    end
                end
            end
        end,
    }

    ----------------------------------------------------------------
    policy{
        name = "main-block-suppress", priority = 54,
        collect = function(ctx, claim)
            if ctx.endgame or not ctx.activated then return end
            for _, side_list in pairs(D.main_blocks_side) do
                for _, side_name in ipairs(side_list) do
                    if ctx.is_blocked_by_active_main(side_name) then
                        local data = D.scoop_data[side_name]
                        if data and data.flags and not data.chain_managed then
                            for _, flag_id in ipairs(data.flags) do
                                if flag_id and flag_id ~= 0 then
                                    claim(flag_id, "off")
                                end
                            end
                        end
                    end
                end
            end
        end,
    }

    ----------------------------------------------------------------
    policy{
        name = "disable-active", priority = 52,
        collect = function(ctx, claim)
            if ctx.endgame or not ctx.activated then return end
            for scoop_name, data in pairs(D.scoop_data) do
                if data.disable_flags and not data.chain_managed
                    and ctx.is_active(scoop_name) then
                    for _, flag_id in ipairs(data.disable_flags) do
                        claim(flag_id, "off")
                    end
                end
            end
        end,
    }

    ----------------------------------------------------------------
    policy{
        name = "controlled", priority = 50,
        collect = function(ctx, claim)
            if ctx.endgame or not ctx.activated then return end
            for flag_id, scoop_name in pairs(D.controlled_flags) do
                if not is_protected_primary(ctx, flag_id, scoop_name) then
                    if ctx.is_active(scoop_name) then
                        claim(flag_id, "on")
                    elseif not ctx.in_grace(scoop_name) then
                        claim(flag_id, "off")
                    end
                end
            end
        end,
    }

    ----------------------------------------------------------------
    policy{
        -- Priority 56 > suppressors (55/54): a flag shared between an
        -- ACTIVE scoop and a suppressed sibling must net ON (e.g. Kent
        -- day1/day2 share 779; a lower priority pins 779 off forever).
        name = "side-active", priority = 56,
        collect = function(ctx, claim)
            if ctx.endgame or not ctx.activated then return end
            for scoop_name, data in pairs(D.scoop_data) do
                -- chain_managed (the Kent days): KentChain arms these ONCE
                -- per transition and the engine drives from there. Holding
                -- them per tick is what respawned day-2 Kent (1225
                -- re-asserted in the retire window). Never claim them here.
                if data.category ~= "Main" and data.flags
                    and not data.chain_managed
                    and ctx.is_active(scoop_name)
                    and not ctx.is_conflict_blocked(scoop_name)
                    and not ctx.is_blocked_by_active_main(scoop_name)
                    and ctx.has_prerequisites_met(scoop_name) then
                    for _, flag_id in ipairs(data.flags) do
                        if flag_id and flag_id ~= 0 then
                            claim(flag_id, "on")
                        end
                    end
                end
            end
        end,
    }

    ----------------------------------------------------------------
    -- Flags this policy has already put back. It stands in for the engine's
    -- end-of-scoop cleanup, which happens ONCE -- so once the flag is
    -- observed off, the flag goes back to being the game's business.
    --
    -- Claiming it off on every pass instead was a bug with teeth: flag 309 is
    -- the Special Forces, and the story raises it again at 10pm on day 3.
    -- Holding it down meant the game turned the soldiers on, the reconciler
    -- turned them off a tick later, and the cutscene replayed without end.
    local cleanup_done = {}

    policy{
        -- Completed-scoop flag cleanup, OPT-IN via clear_on_complete.
        -- DRAP-forced scoops never run the engine's end-of-scoop cleanup
        -- (finishSCQ never fires), so e.g. Cletus's flag stayed on and
        -- suppressed Gun Shop Standoff's room. Must NOT be category-wide:
        -- most scoops have content living past their AP completion
        -- (cutscene checks, extra survivors, hostages).
        name = "side-completed", priority = 45,
        collect = function(ctx, claim)
            if ctx.endgame or not ctx.activated then return end
            for scoop_name, data in pairs(D.scoop_data) do
                if data.clear_on_complete and data.flags
                    and ctx.is_completed(scoop_name)
                    -- Only for a scoop that finished in this session. A
                    -- completed scoop loaded from the ledger finished long
                    -- ago, and re-running the tidy-up on every load would
                    -- clear a flag the game has since raised for its own
                    -- reasons.
                    and ctx.completed_this_session(scoop_name)
                    and not ctx.in_grace(scoop_name) then
                    for _, flag_id in ipairs(data.flags) do
                        if flag_id and flag_id ~= 0
                            and not cleanup_done[flag_id] then
                            if ctx.check_flag(flag_id) == false then
                                cleanup_done[flag_id] = true
                            else
                                claim(flag_id, "off")
                            end
                        end
                    end
                end
            end
        end,
    }

    ----------------------------------------------------------------
    policy{
        -- Mission-box display for the ScoopSanity chain: show the current
        -- chain scoop's per-case box, hide the others, hold its END flag
        -- off. Fixes the Jessie cutscene lighting case-1's box for players
        -- whose randomized chain starts elsewhere.
        name = "chain-display", priority = 20,
        collect = function(ctx, claim)
            -- DISABLED pending the real main-box mechanism: setting a main
            -- DISP flag yields a BLANK box -- main boxes are driven by
            -- case-scenario state (mCase / EV_CASE_PROGRES), not DISP flags.
            -- Side boxes ARE edge-controllable (see side-display below).
            if true then return end
            if ctx.endgame or not ctx.activated then return end
            if not ctx.scoop_sanity then return end
            local current = ctx.chain_disp_flag   -- nil when no chain scoop
            local all_boxes, all_ends = {}, {}
            for _, data in pairs(D.scoop_data) do
                if data.category == "Main" and data.disp_flag then
                    all_boxes[data.disp_flag] = true
                    if data.disp_end_flag then
                        all_ends[data.disp_flag] = data.disp_end_flag
                    end
                end
            end
            for box in pairs(all_boxes) do
                if box == current then
                    claim(box, "on")
                    if all_ends[box] then claim(all_ends[box], "off") end
                else
                    claim(box, "off")
                end
            end
        end,
    }

    ----------------------------------------------------------------
    policy{
        -- Side-scoop mission-box display (ScoopSanity). Unlike main-case
        -- boxes, side boxes are cleanly level-controllable: DISP on shows
        -- the box with correct vanilla text, END (or DISP off) retires it.
        -- Show each active, available side scoop's box; retire the rest.
        -- END wins over DISP, so an active box must also hold END off.
        -- Covers Survivor + Psychopath (the 3 cutscene psychopaths --
        -- Cletus/Convicts/Cult -- have no disp_flag and are skipped).
        --
        -- `engine_owns_box` marks a scoop whose box the ENGINE drives -- the
        -- Kent chain, where completing one day hands over by setting the next
        -- day's entry flag and SCQManager re-asserts it every tick. For those,
        -- DRAP may turn a box ON but must never force the entry flag off, and
        -- must not override the engine's END flag either. Both rules were
        -- measured in game; see docs/Kent_flag_tests.md.
        name = "side-display", priority = 45,
        collect = function(ctx, claim)
            if ctx.endgame or not ctx.activated then return end
            if not ctx.scoop_sanity then return end
            local DISPLAY_CATS = { Survivor = true, Psychopath = true }
            for scoop_name, data in pairs(D.scoop_data) do
                if DISPLAY_CATS[data.category] and data.disp_flag then
                    local show = ctx.is_active(scoop_name)
                        and not ctx.is_conflict_blocked(scoop_name)
                        and not ctx.is_blocked_by_active_main(scoop_name)
                        and ctx.has_prerequisites_met(scoop_name)
                    -- A scoop may own more than one box (paired survivor
                    -- scoops: Lovers, Barricade Pair, Japanese Tourists --
                    -- a box per person, sharing one END flag).
                    local boxes = { data.disp_flag }
                    if data.extra_disp_flags then
                        for _, f in ipairs(data.extra_disp_flags) do
                            table.insert(boxes, f)
                        end
                    end
                    if show then
                        -- Engine-owned boxes get NO show claim either: the
                        -- engine sets their entry flags itself (2507 on its
                        -- schedule, 2508/2509 in the completion handoff
                        -- cluster), and DRAP setting one EARLY pre-empts
                        -- that handoff -- the queue enqueues the entry as
                        -- StateSub NONE before the engine can create-and-
                        -- activate it, and the day never becomes ready
                        -- (vanilla-order day-2 no-spawn, measured via
                        -- drap_kent_scq 2026-08-22).
                        if data.engine_owns_box then
                            -- no claim in either direction
                        else
                            for _, f in ipairs(boxes) do claim(f, "on") end
                        end
                        -- Holding END off keeps a shown box alive, but on an
                        -- engine-owned box it overrides the engine's own end
                        -- for the display. Measured on Kent day 1: the engine
                        -- sets DISP_END20 about a minute before the player
                        -- finishes, DRAP cleared it 0.25s later, and the scoop
                        -- then closed through the TIMEOUT path -- FINISH and
                        -- NPC21_FIRST_TIMEOUT set together, SUCCESS never set,
                        -- "Scoop Chance Lost" on screen.
                        if data.disp_end_flag and not data.engine_owns_box then
                            claim(data.disp_end_flag, "off")
                        end
                    elseif data.engine_owns_box then
                        -- Retire it with its END flag, never by clearing the
                        -- ENTRY flag: the engine re-asserts a cleared entry
                        -- flag within a frame and every rising edge enqueues
                        -- ANOTHER display entry, filling the side panel.
                        --
                        -- ONLY while the scoop has never been received. Once
                        -- it is ours the END flag belongs to the engine again:
                        -- disable_on_unlock clears it once at unlock, and a
                        -- scoop can sit unlocked-but-not-shown for a long time
                        -- (prerequisites, conflict group), so re-asserting
                        -- here would undo that one-shot clear and the box
                        -- could never come back.
                        --
                        -- Getting the box back is not this policy's job. A
                        -- per-tick "END off" while shown is what overrode the
                        -- engine's own ending and made day 1 time out.
                        --
                        -- The END claim itself is ONLY for a scoop we have
                        -- never been given. A received-but-not-shown day
                        -- (conflict-blocked, prerequisites pending) and a
                        -- completed one both keep their box state: their END
                        -- flag is the engine's, and disable_on_unlock already
                        -- cleared it once at unlock.
                        --
                        -- The invariant is that an engine-owned box NEVER
                        -- reaches the entry-clearing branch below, whatever
                        -- its state.
                        --
                        -- And NEVER assert a box-end living in the psycho
                        -- appear/timeout block (1153..1182): those are
                        -- engine spawn-state records, and holding one on
                        -- suppresses spawns. Pride's box-end is 1155
                        -- (EM45_THIRD_APPEAR); asserting it stopped day-2
                        -- Kent's set from placing in vanilla order
                        -- (measured 2026-08-22). Cost: that box may show
                        -- early -- one early box beats a broken spawn.
                        if data.disp_end_flag
                                and not (data.disp_end_flag >= 1153
                                         and data.disp_end_flag <= 1182)
                                and not ctx.is_active(scoop_name)
                                and not ctx.is_completed(scoop_name) then
                            claim(data.disp_end_flag, "on")
                        end
                    else
                        for _, f in ipairs(boxes) do claim(f, "off") end
                    end
                end
            end
        end,
    }

    ----------------------------------------------------------------
    policy{
        name = "door-rando-514", priority = 35,
        collect = function(ctx, claim)
            if ctx.endgame then return end
            if ctx.door_randomizer then
                claim(514, "on")
            end
        end,
    }

    ----------------------------------------------------------------
    policy{
        name = "cascade", priority = 30,
        collect = function(ctx, claim)
            if ctx.endgame or not ctx.activated then return end
            for flag_id, owner_scoop in pairs(D.cascade_flags) do
                if not ctx.is_active(owner_scoop)
                    and not ctx.in_grace(owner_scoop) then
                    claim(flag_id, "off")
                end
            end
        end,
    }

    return policies
end

return M
