-- DRAP/npc/PartySnapshot.lua
-- Decides whether a saved escort party may be restored into the save the
-- player just loaded.
--
-- The failure modes are not equal. Failing to restore a survivor is
-- recoverable; restoring one wrongly is not, because the game cannot un-rescue
-- someone. So every rule refuses on doubt, and an unreadable signal means "ask
-- again later", never "probably fine".
--
-- Game time is deliberately NOT a signal: ScoopSanity freezes the clock, so
-- mDate is flat in exactly the mode this exists for.
--
-- PURITY CONTRACT: touches no engine state (no sdk, json, imgui, re.on_frame).
-- Signals arrive as plain numbers, so the rules are unit-testable outside the
-- game (tools/logic_tests/test_party_snapshot.py, under lupa).

local M = {}

M.VERSION = 1

M.STATUS = {
    ACCEPT = "accept",  -- fingerprint proves this save is at or past the snapshot
    REFUSE = "refuse",  -- proven earlier / different timeline; never restore
    RETRY  = "retry",   -- something was unreadable; ask again, do not act
    NONE   = "none",    -- nothing snapshotted yet
}

-- Ordered so the refusal message names the most meaningful signal first.
-- join_count leads because it answers this feature's exact question: had these
-- survivors been recruited yet in the loaded timeline?
local SIGNALS = { "join_count", "pp_total", "rescue_num", "level", "case" }

M.SIGNALS = SIGNALS

------------------------------------------------------------
-- Capture
------------------------------------------------------------

--- @param party table array of { stype = n, area = n }
--- @param signals table the monotonic fingerprint, any subset of SIGNALS
function M.capture(party, signals)
    local members, sig = {}, {}
    for _, m in ipairs(party or {}) do
        if type(m) == "table" and tonumber(m.stype) then
            table.insert(members, {
                stype = tonumber(m.stype),
                area = tonumber(m.area),
            })
        elseif tonumber(m) then
            table.insert(members, { stype = tonumber(m) })
        end
    end
    for _, k in ipairs(SIGNALS) do
        local v = tonumber((signals or {})[k])
        if v then sig[k] = v end
    end
    return { version = M.VERSION, party = members, signals = sig }
end

function M.party_size(snapshot)
    if type(snapshot) ~= "table" then return 0 end
    return #(snapshot.party or {})
end

------------------------------------------------------------
-- The gate
------------------------------------------------------------

--- Is the loaded save at or past the snapshot?
--- @param snapshot table|nil from M.capture
--- @param current table { join_count, pp_total, rescue_num, level, case,
---                        new_game = true|false|nil }
--- @return string status one of M.STATUS
--- @return string reason human-readable, always logged
function M.evaluate(snapshot, current)
    if type(snapshot) ~= "table" or type(snapshot.signals) ~= "table"
        or not next(snapshot.signals) then
        return M.STATUS.NONE, "no snapshot recorded"
    end
    if M.party_size(snapshot) == 0 then
        return M.STATUS.NONE, "snapshot has no party members"
    end

    current = current or {}

    -- Tri-state, same contract as ScoopUnlocker.is_new_game(): nil means the
    -- flags were unreadable, which is common inside the load window. Answering
    -- off an unreadable read is how you restore into a fresh game.
    if current.new_game == nil then
        return M.STATUS.RETRY, "new-game state unreadable"
    end
    if current.new_game == true then
        return M.STATUS.REFUSE, "new game in progress"
    end

    for _, key in ipairs(SIGNALS) do
        local was = snapshot.signals[key]
        if was ~= nil then
            local now = tonumber(current[key])
            if now == nil then
                return M.STATUS.RETRY, key .. " unreadable"
            end
            if now < was then
                return M.STATUS.REFUSE, string.format(
                    "%s regressed (%s now, %s at snapshot) -- this save is"
                        .. " earlier than the party we recorded",
                    key, tostring(now), tostring(was))
            end
        end
    end

    return M.STATUS.ACCEPT, "fingerprint is at or past the snapshot"
end

------------------------------------------------------------
-- Who to actually put back
------------------------------------------------------------

--- Filters an accepted snapshot down to the members genuinely missing.
---
--- is_rescued is what makes loading a LATER save safe -- without it, survivors
--- long since delivered would be dragged back out of the safe room. It means
--- rescued IN THIS SAVE, never "their AP check was sent": checks outlive the
--- save that earned them, and a player on a new game may be rescuing that
--- survivor again for the PP or a goal.
---
--- @param snapshot table
--- @param is_present function(stype) -> boolean  already there and following
--- @param is_rescued function(stype) -> boolean  already safe in THIS save
--- @return table array of { stype, area }, and a table of skip reasons
function M.to_restore(snapshot, is_present, is_rescued)
    local out, skipped = {}, {}
    for _, m in ipairs((snapshot or {}).party or {}) do
        if is_present and is_present(m.stype) then
            skipped[m.stype] = "already present"
        elseif is_rescued and is_rescued(m.stype) then
            skipped[m.stype] = "already rescued in this save"
        else
            table.insert(out, m)
        end
    end
    return out, skipped
end

return M
