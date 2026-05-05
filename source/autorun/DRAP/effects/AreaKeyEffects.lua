-- DRAP/effects/AreaKeyEffects.lua
-- Item-effect handlers for area keys.
-- Each area's key_item (from drdr_shared.json) unlocks its scene via
-- AP.DoorSceneLock. Scene unlocks are idempotent, so on_replay = "apply".

local SharedData = require("DRAP/SharedData")
local ItemEffects = require("DRAP/ItemEffects")

local M = {}

local Shared = require("DRAP/Shared")
local log = Shared.create_logger("AreaKeyEffects")

function M.register_all()
    local count = 0
    for _, area in ipairs(SharedData.areas()) do
        if area.key_item and area.scene_code then
            local scene = area.scene_code
            ItemEffects.register(area.key_item, {
                on_replay = "apply",
                apply = function(ctx)
                    log(string.format("Applying progression item '%s' from %s",
                        tostring(ctx.item_name), tostring(ctx.sender_name or "?")))
                    if AP and AP.DoorSceneLock then
                        AP.DoorSceneLock.unlock_scene(scene)
                    end
                end,
            })
            count = count + 1
        end
    end
    log(string.format("Registered %d area-key handlers", count))
end

-- Re-apply scene unlocks for every area key the bridge already has.
-- Called on save-load / reconnect, after RECEIVED_ITEMS is restored.
function M.reapply()
    if not AP or not AP.AP_BRIDGE or not AP.DoorSceneLock then return end
    for _, area in ipairs(SharedData.areas()) do
        if area.key_item and area.scene_code
                and AP.AP_BRIDGE.has_item_name(area.key_item) then
            AP.DoorSceneLock.unlock_scene(area.scene_code)
        end
    end
end

return M
