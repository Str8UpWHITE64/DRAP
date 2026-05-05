-- DRAP/effects/VictoryEffects.lua
-- Registers the "Victory" item handler that notifies the AP server of goal
-- completion. Sending goal-complete is idempotent on the server side, so
-- on_replay = "apply" is safe.

local ItemEffects = require("DRAP/ItemEffects")

local M = {}

local Shared = require("DRAP/Shared")
local log = Shared.create_logger("VictoryEffects")

function M.register_all()
    ItemEffects.register("Victory", {
        on_replay = "apply",
        apply = function(ctx)
            log("Victory received! Sending goal completion to server...")
            if AP and AP.AP_BRIDGE and AP.AP_BRIDGE.send_goal_complete then
                AP.AP_BRIDGE.send_goal_complete()
            end
        end,
    })
end

return M
