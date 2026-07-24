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
--   post_jessie_flags, cult_on, cult_off, endgame_flags
function M.build(deps)
    local D = deps

    local function is_protected_primary(ctx, flag_id, scoop_name)
        local entry = D.protected_primary_flags[flag_id]
        if not entry then return false end
        if entry.scoop ~= scoop_name then return false end
        if entry.while_active then
            return ctx.is_active(entry.while_active)
        end
        return true
    end

    local policies = {}
    local function policy(p) table.insert(policies, p) end

    ----------------------------------------------------------------
    policy{
        name = "endgame", priority = 100,
        collect = function(ctx, claim)
            if not ctx.endgame then return end
            for _, fid in ipairs(D.endgame_flags) do
                claim(fid, "on")
            end
            -- Hideout 301 cutscene prevention: ON inside the hideout,
            -- OFF everywhere else.
            if ctx.area == ctx.hideout_area then
                claim(301, "on")
            else
                claim(301, "off")
            end
        end,
    }

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
                if data.flags and not ctx.is_completed(scoop_name)
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
                        if data and data.flags then
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
                if data.disable_flags and ctx.is_active(scoop_name) then
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
                if data.category ~= "Main" and data.flags
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
    policy{
        -- Completed-scoop flag cleanup, OPT-IN via clear_on_complete.
        -- DRAP-forced scoops never run the engine's end-of-scoop cleanup
        -- (finishSCQ never fires), so e.g. Cletus's flag stayed on and
        -- suppressed Gun Shop Standoff's room. Must NOT be category-wide:
        -- most scoops have content living past their AP completion
        -- (cutscene checks, extra survivors, hostages). Today: Cletus alone.
        name = "side-completed", priority = 45,
        collect = function(ctx, claim)
            if ctx.endgame or not ctx.activated then return end
            for scoop_name, data in pairs(D.scoop_data) do
                if data.clear_on_complete and data.flags
                    and ctx.is_completed(scoop_name)
                    and not ctx.in_grace(scoop_name) then
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
                        for _, f in ipairs(boxes) do claim(f, "on") end
                        if data.disp_end_flag then
                            claim(data.disp_end_flag, "off")
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
