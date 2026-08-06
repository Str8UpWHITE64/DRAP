-- DRAP/effects/SplitKeyEffects.lua
-- Item-effect handlers for split keys.
-- Where an area key opens a whole scene, a split key opens one door pair --
-- both transitions listed for it in drdr_shared.json. Unlocks are idempotent,
-- so on_replay = "apply".

local SharedData = require("DRAP/SharedData")
local ItemEffects = require("DRAP/ItemEffects")

local M = {}

local Shared = require("DRAP/Shared")
local log = Shared.create_logger("SplitKeyEffects")

local function unlock_entry(entry)
    if not (AP and AP.DoorSceneLock) then return end
    for _, t in ipairs(entry.transitions or {}) do
        if t.origin and t.destination then
            AP.DoorSceneLock.unlock_transition(t.origin, t.destination)
        end
    end
end

function M.register_all()
    local count = 0
    for _, entry in ipairs(SharedData.split_areas()) do
        if entry.key_item and entry.transitions then
            local captured = entry
            ItemEffects.register(entry.key_item, {
                on_replay = "apply",
                apply = function(ctx)
                    log(string.format("Applying progression item '%s' from %s",
                        tostring(ctx.item_name), tostring(ctx.sender_name or "?")))
                    unlock_entry(captured)
                end,
            })
            count = count + 1
        end
    end
    log(string.format("Registered %d split-key handlers", count))
end

-- Re-apply door unlocks for every split key the bridge already has.
-- Called on save-load / reconnect, after RECEIVED_ITEMS is restored.
function M.reapply()
    if not AP or not AP.AP_BRIDGE or not AP.DoorSceneLock then return end
    if not AP.DoorSceneLock.get_split_keys_enabled() then return end
    for _, entry in ipairs(SharedData.split_areas()) do
        if entry.key_item and AP.AP_BRIDGE.has_item_name(entry.key_item) then
            unlock_entry(entry)
        end
    end
end

return M
