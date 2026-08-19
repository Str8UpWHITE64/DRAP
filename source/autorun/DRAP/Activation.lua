-- DRAP/Activation.lua
-- DRAP does nothing to the game until a slot connect succeeds.
--
-- The mod used to arm at load, and every mall scene starts locked in
-- DoorSceneLock until a key item opens it -- so a player who never connected
-- was sealed in the Security Room after the prologue.
--
-- One way per session. A dropped server leaves the run as it is; reverting
-- would unlock the whole mall on a network blip.
--
-- Debug Mode arms it too, so the mod can be exercised offline without
-- standing up a server. Same one-way rule: switching debug back off does not
-- disarm, for the reason above.

local Shared = require("DRAP/Shared")

local M = Shared.create_module("Activation")

local active = false
local listeners = {}

function M.is_active()
    return active
end

--- @param reason string what activated it, for the log
--- @return boolean true if this call was the one that flipped it
function M.activate(reason)
    if active then return false end
    active = true
    M.log("active -- " .. tostring(reason) .. " (dormant until now)")
    for _, fn in ipairs(listeners) do
        local ok, err = pcall(fn)
        if not ok then M.log.warn("activation listener failed: " .. tostring(err)) end
    end
    return true
end

--- Runs once on the dormant -> active flip, in registration order.
function M.on_activate(fn)
    if type(fn) ~= "function" then return end
    if active then
        pcall(fn)
        return
    end
    listeners[#listeners + 1] = fn
end

_G.drap_active = function()
    M.log(active and "active -- connected to a slot"
                  or "dormant -- vanilla, no slot connected")
end

-- Arm without a server, for offline testing. Same call the Debug Mode
-- checkbox makes, so the console works with the GUI closed.
_G.drap_activate_debug = function()
    if M.activate("debug mode") then
        M.log("armed by console -- offline testing")
    else
        M.log("already active")
    end
end

return M
