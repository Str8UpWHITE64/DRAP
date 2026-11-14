-- DRAP/scoops/FlagReconciler.lua
-- Claim resolution + application for the ScoopSanity flag reconciler.
--
-- Every tick: collect claims from all policies, resolve each flag to the
-- highest-priority claim, then either
--   * mode "active": diff desired vs actual and write the difference, or
--   * mode "shadow": compare desired vs actual AFTER the legacy loops
--     ran and report divergence (the legacy code just asserted its own
--     desired state, so post-hoc equality means the two implementations
--     agree).
--
-- Conflicting claims (two policies wanting different values for one
-- flag) are resolved deterministically by priority and LOGGED with both
-- owners named -- once per unique conflict signature, not per tick.
--
-- An "off" claim on a flag ctx.never_off() names (an SCQ row's FINISH or
-- SUCCESS, see ScoopFinish) is refused before it is counted: whatever
-- the priority, no policy can take a finished scoop back. Refusals are
-- logged once per flag and owner.
--
-- PURITY CONTRACT: no engine access. Reads/writes go through the
-- injected io adapter { read(fid) -> true/false/nil,
-- set(fid, on, shielded) }; logging through the injected log fn.
-- Unit-tested headlessly in tools/logic_tests/test_flag_policies.py.

local M = {}

-- Dedup state (per-process; reset via M.reset_log_dedup())
local logged_conflict_sigs = {}
local logged_refusal_sigs = {}
local last_apply_sig = nil
local last_shadow_sig = nil

function M.reset_log_dedup()
    logged_conflict_sigs = {}
    logged_refusal_sigs = {}
    last_apply_sig = nil
    last_shadow_sig = nil
end

-- Returns desired = { [flag_id] = { want = "on"/"off", owner, priority,
-- unshielded } }, conflicts = list of { flag, winner, loser } where the
-- two disagreed on the value. The "off" claims ctx.never_off turned away
-- are appended to `refused` ({ flag, owner }) when the caller passes one.
function M.resolve(policies, ctx, refused)
    local desired = {}
    local conflicts = {}
    refused = refused or {}
    local never_off = ctx and ctx.never_off

    for _, pol in ipairs(policies) do
        local function claim(flag_id, want)
            if want == "off" and never_off and never_off(flag_id) then
                table.insert(refused, { flag = flag_id, owner = pol.name })
                return
            end
            local cur = desired[flag_id]
            if not cur then
                desired[flag_id] = {
                    want = want, owner = pol.name,
                    priority = pol.priority,
                    unshielded = pol.unshielded == true,
                }
                return
            end
            if cur.want ~= want then
                -- Disagreement: keep the higher priority, record it.
                local winner, loser
                if pol.priority > cur.priority then
                    winner = { want = want, owner = pol.name,
                               priority = pol.priority,
                               unshielded = pol.unshielded == true }
                    loser = cur
                    desired[flag_id] = winner
                else
                    winner, loser = cur, {
                        want = want, owner = pol.name, priority = pol.priority,
                    }
                end
                table.insert(conflicts, {
                    flag = flag_id, winner = winner, loser = loser,
                })
            elseif pol.priority > cur.priority then
                -- Same value, higher priority: adopt owner/shielding.
                desired[flag_id] = {
                    want = want, owner = pol.name, priority = pol.priority,
                    unshielded = pol.unshielded == true,
                }
            end
        end

        pol.collect(ctx, claim)
    end

    return desired, conflicts
end

local function log_refusals(refused, log)
    for _, r in ipairs(refused) do
        local sig = string.format("%d:%s", r.flag, r.owner)
        if not logged_refusal_sigs[sig] then
            logged_refusal_sigs[sig] = true
            log(string.format(
                "REFUSED flag %d off (%s): a scoop's FINISH/SUCCESS flag is never cleared",
                r.flag, r.owner))
        end
    end
end

local function log_conflicts(conflicts, log)
    for _, c in ipairs(conflicts) do
        local sig = string.format("%d:%s>%s", c.flag, c.winner.owner, c.loser.owner)
        if not logged_conflict_sigs[sig] then
            logged_conflict_sigs[sig] = true
            log(string.format(
                "CLAIM CONFLICT flag %d: %s(%d) wants %s, %s(%d) wants %s -- %s wins",
                c.flag, c.winner.owner, c.winner.priority, c.winner.want,
                c.loser.owner, c.loser.priority or 0, c.loser.want or "?",
                c.winner.owner))
        end
    end
end

-- One reconciliation pass. Returns stats: { claims, writes|mismatches,
-- conflicts }.
function M.tick(policies, ctx, io, mode, log)
    local refused = {}
    local desired, conflicts = M.resolve(policies, ctx, refused)
    log_conflicts(conflicts, log)
    log_refusals(refused, log)

    local n_claims = 0
    for _ in pairs(desired) do n_claims = n_claims + 1 end

    if mode == "active" then
        local applied = {}
        for flag_id, d in pairs(desired) do
            local actual = io.read(flag_id)
            local want_on = d.want == "on"
            -- nil read = unreadable (load screen); never write blind.
            if actual ~= nil and actual ~= want_on then
                io.set(flag_id, want_on, not d.unshielded)
                table.insert(applied, string.format("%d>%s(%s)",
                    flag_id, d.want, d.owner))
            end
        end
        if #applied > 0 then
            table.sort(applied)
            local sig = table.concat(applied, ",")
            if sig ~= last_apply_sig then
                log(string.format("Reconciler: %d writes: %s",
                    #applied, table.concat(applied, ", ")))
                last_apply_sig = sig
            end
        else
            last_apply_sig = nil
        end
        return { claims = n_claims, writes = 0, conflicts = #conflicts,
                 applied = applied }
    end

    if mode == "shadow" then
        local mismatches = {}
        for flag_id, d in pairs(desired) do
            local actual = io.read(flag_id)
            local want_on = d.want == "on"
            if actual ~= nil and actual ~= want_on then
                table.insert(mismatches, string.format("%d:want=%s(%s),is=%s",
                    flag_id, d.want, d.owner, actual and "on" or "off"))
            end
        end
        if #mismatches > 0 then
            table.sort(mismatches)
            local sig = table.concat(mismatches, ",")
            if sig ~= last_shadow_sig then
                log(string.format("SHADOW DIVERGENCE (%d): %s",
                    #mismatches, table.concat(mismatches, ", ")))
                last_shadow_sig = sig
            end
        else
            last_shadow_sig = nil
        end
        return { claims = n_claims, mismatches = #mismatches,
                 conflicts = #conflicts }
    end

    return { claims = n_claims, conflicts = #conflicts }
end

return M
