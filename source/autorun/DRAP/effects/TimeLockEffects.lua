-- DRAP/effects/TimeLockEffects.lua
-- Item-effect handlers for the time-lock progression chain.
-- Chain entries come from drdr_shared.json's `time_keys` section. Each entry
-- declares a cap constant (in AP.TimeGate.TIME_CAPS) and an unlock function
-- (on AP.TimeGate). Receiving a time key advances the chain if -- and only if --
-- every earlier key has already been received.

local SharedData = require("DRAP/SharedData")
local ItemEffects = require("DRAP/ItemEffects")

local M = {}

-- Cached, resolved chain: { { key, cap, unlock }, ... }
-- Populated by register_all() after AP.TimeGate is available.
local CHAIN = {}

local Shared = require("DRAP/Shared")
local log = Shared.create_logger("TimeLockEffects")

local function build_chain()
    CHAIN = {}
    if not AP or not AP.TimeGate then
        log("WARNING: AP.TimeGate not loaded; chain is empty")
        return
    end
    local TIME_CAPS = AP.TimeGate.TIME_CAPS or {}

    for _, entry in ipairs(SharedData.time_keys()) do
        local cap = TIME_CAPS[entry.cap_constant]
        local unlock_fn = AP.TimeGate[entry.unlock_function]
        if cap == nil then
            log(string.format("WARNING: time_key '%s' references unknown cap_constant '%s'",
                tostring(entry.name), tostring(entry.cap_constant)))
        end
        if type(unlock_fn) ~= "function" then
            log(string.format("WARNING: time_key '%s' references unknown unlock_function '%s'",
                tostring(entry.name), tostring(entry.unlock_function)))
        end
        table.insert(CHAIN, {
            key = entry.name,
            cap = cap,
            unlock = function()
                if type(unlock_fn) == "function" then unlock_fn() end
            end,
        })
    end
end

-- Evaluate the received state and advance the chain as far as it can go.
-- Idempotent; safe to call on every time-key receipt and on save-load.
function M.reapply()
    if #CHAIN == 0 then return end
    if not AP or not AP.TimeGate or not AP.TimeGate.set_time_cap then return end
    if not AP.AP_BRIDGE or not AP.AP_BRIDGE.has_item_name then return end

    local last_unlocked_index = 0

    for i, step in ipairs(CHAIN) do
        if AP.AP_BRIDGE.has_item_name(step.key) then
            if i == last_unlocked_index + 1 then
                step.unlock()
                last_unlocked_index = i
                log(string.format("Time chain unlocked: %s (step %d/%d)", step.key, i, #CHAIN))
            else
                log(string.format("Time chain blocked: have %s but missing earlier step", step.key))
                break
            end
        else
            break
        end
    end

    if last_unlocked_index >= #CHAIN then
        log("Time chain fully unlocked.")
        return
    end

    local next_step = CHAIN[last_unlocked_index + 1]
    if next_step and next_step.cap then
        AP.TimeGate.set_time_cap(next_step.cap)
        log(string.format("Time cap set to: %s (cap=%s)", next_step.key, tostring(next_step.cap)))
    end
end

function M.register_all()
    build_chain()
    local count = 0
    for _, step in ipairs(CHAIN) do
        ItemEffects.register(step.key, {
            on_replay = "apply",
            apply = function(ctx)
                log(string.format("Received time item '%s' from %s; re-evaluating time locks",
                    tostring(ctx.item_name), tostring(ctx.sender_name or "?")))
                M.reapply()
            end,
        })
        count = count + 1
    end
    log(string.format("Registered %d time-lock handlers", count))
end

return M
