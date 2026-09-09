-- DRAP/trackers/KillCounter.lua
-- Per-area zombie kill counts, and the decision about when a check is due.
--
-- The engine has no per-area kill counter -- every counter it keeps is global
-- -- so these are DRAP's own, accumulated from the per-kill increment.
--
-- Counts only ever move forward. A check that has been sent cannot be unsent,
-- so a save reloaded from an earlier point keeps the progress rather than
-- rewinding into a state where a sent check has no count behind it.
--
-- PURITY CONTRACT: touches no engine state (no sdk, json, imgui, re.on_frame).
-- Scene codes and kills arrive as plain values, so it is unit-testable outside
-- the game (tools/logic_tests/test_kill_counter.py, under lupa).

local M = {}

-- Rooms that count toward a bigger area. Without these, killing in the Meat
-- Processing Area would move nothing and read as broken.
M.FOLD_SCENES = {
    s601 = "s600",   -- Meat Processing Area -> Maintenance Tunnel
    s401 = "s400",   -- Carlito's Hideout -> North Plaza
}

--- Build a counter.
--- @param opts table {thresholds = {region -> {n,...}}, scenes = {code -> region}}
function M.new(opts)
    opts = opts or {}
    local self = {
        thresholds = {},
        scenes = {},
        counts = {},
        -- Kills not yet written to the ledger or pushed to the server.
        pending = {},
        sent = {},
    }

    --- @param kill_caps table|nil {region -> n}: KillSanity, every kill up
    --- to n in that region is its own location. Only regions that have
    --- tier thresholds count, which is also how the apworld builds it.
    function self.configure(thresholds, scenes, kill_caps)
        self.thresholds = {}
        for region, list in pairs(thresholds or {}) do
            -- Ascending, so the first unmet threshold is the next one due.
            local copy = {}
            for _, n in ipairs(list) do table.insert(copy, n) end
            table.sort(copy)
            self.thresholds[region] = copy
            self.counts[region] = self.counts[region] or 0
        end
        self.scenes = scenes or {}
        self.kill_caps = {}
        for region, cap in pairs(kill_caps or {}) do
            cap = tonumber(cap) or 0
            if cap > 0 and self.thresholds[region] then
                self.kill_caps[region] = cap
            end
        end
    end

    function self.kill_name(k, region)
        return string.format("Zombie Kill %d in %s", k, region)
    end

    --- The region a scene code belongs to. Whether that region has any checks
    --- is record_region's call, not this one's.
    function self.region_for(scene_code)
        if type(scene_code) ~= "string" then return nil end
        local code = scene_code:match("(s%w+)$") or scene_code
        code = M.FOLD_SCENES[code] or code
        return self.scenes[code]
    end

    function self.location_name(threshold, region)
        return string.format("Kill %d zombies in %s", threshold, region)
    end

    --- Record kills against a region directly, skipping the scene lookup.
    --- The debug "add kills" path uses this; normal play goes through record.
    --- @return string|nil region, table newly-crossed location names
    function self.record_region(region, n)
        n = n or 1
        if not region or not self.thresholds[region] then return nil, {}, {} end

        local before = self.counts[region] or 0
        local after = before + n
        self.counts[region] = after
        self.pending[region] = (self.pending[region] or 0) + n

        local due = {}
        for _, threshold in ipairs(self.thresholds[region]) do
            if after >= threshold and before < threshold then
                local name = self.location_name(threshold, region)
                if not self.sent[name] then
                    self.sent[name] = true
                    table.insert(due, name)
                end
            end
        end
        -- KillSanity: the kills themselves, up to the cap. Returned apart
        -- from the thresholds so the caller can batch them without a
        -- toast each.
        local kills = {}
        local cap = self.kill_caps[region]
        if cap then
            for k = before + 1, math.min(after, cap) do
                local name = self.kill_name(k, region)
                if not self.sent[name] then
                    self.sent[name] = true
                    table.insert(kills, name)
                end
            end
        end
        return region, due, kills
    end

    --- Record kills in a scene.
    --- @return string|nil region, table newly-crossed location names
    function self.record(scene_code, n)
        return self.record_region(self.region_for(scene_code), n)
    end

    --- Adopt a count from the ledger or the server. Never lowers a count --
    --- see the forward-only note at the top.
    --- @return boolean whether the stored value won
    function self.seed(region, value)
        value = tonumber(value) or 0
        if not self.thresholds[region] then return false end
        if value <= (self.counts[region] or 0) then return false end
        self.counts[region] = value
        return true
    end

    --- Every threshold at or below the current count, whether or not this
    --- session sent it. Used on connect to catch up a count that arrived from
    --- the server ahead of the checks.
    function self.due_checks()
        local out = {}
        for region, list in pairs(self.thresholds) do
            local count = self.counts[region] or 0
            for _, threshold in ipairs(list) do
                if count >= threshold then
                    local name = self.location_name(threshold, region)
                    if not self.sent[name] then
                        self.sent[name] = true
                        table.insert(out, name)
                    end
                end
            end
        end
        table.sort(out)
        return out
    end

    --- Every KillSanity kill at or below the current count that this
    --- session has not sent. The count is the only record kept of them --
    --- a kill at or below it is sent by definition, and the server dedupes
    --- a resend -- so a reload yields them all once, in one batch.
    function self.due_kills()
        local out = {}
        for region, cap in pairs(self.kill_caps) do
            for k = 1, math.min(self.counts[region] or 0, cap) do
                local name = self.kill_name(k, region)
                if not self.sent[name] then
                    self.sent[name] = true
                    table.insert(out, name)
                end
            end
        end
        return out
    end

    --- A batch that failed to send goes back on the table.
    function self.forget_sent(list)
        for _, name in ipairs(list or {}) do self.sent[name] = nil end
    end

    function self.count(region) return self.counts[region] or 0 end

    --- Whether this region has any checks at the configured tier.
    function self.has_region(region)
        return region ~= nil and self.thresholds[region] ~= nil
    end

    --- Zero every count and forget what was sent, keeping the configuration.
    --- Debug only: the server's counts are untouched, so the next pull raises
    --- these again, and sent checks stay sent.
    function self.reset_counts()
        for region in pairs(self.thresholds) do self.counts[region] = 0 end
        self.pending = {}
        self.sent = {}
    end

    --- The next threshold not yet reached, or nil when the area is finished.
    function self.next_threshold(region)
        local count = self.counts[region] or 0
        for _, threshold in ipairs(self.thresholds[region] or {}) do
            if count < threshold then return threshold end
        end
        return nil
    end

    function self.regions()
        local out = {}
        for region in pairs(self.thresholds) do table.insert(out, region) end
        table.sort(out)
        return out
    end

    function self.is_enabled() return next(self.thresholds) ~= nil end

    --- Hand back everything unflushed and clear it. The caller owns the deltas
    --- from here, so the ledger write and the push happen in the same pass.
    function self.take_pending()
        local out = self.pending
        self.pending = {}
        return out
    end

    function self.pending_total()
        local n = 0
        for _, v in pairs(self.pending) do n = n + v end
        return n
    end

    function self.serialize()
        local counts = {}
        for region, n in pairs(self.counts) do counts[region] = n end
        return { counts = counts }
    end

    function self.restore(doc)
        if type(doc) ~= "table" or type(doc.counts) ~= "table" then return 0 end
        local n = 0
        for region, value in pairs(doc.counts) do
            if self.seed(region, value) then n = n + 1 end
        end
        return n
    end

    self.configure(opts.thresholds, opts.scenes, opts.kill_caps)
    return self
end

return M
