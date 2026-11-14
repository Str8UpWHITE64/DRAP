-- DRAP/effects/CameraLock.lua
-- Camera Item: the shutter stays locked until the Camera arrives.
--
-- There is no film. PhotoManager keeps a recharge timer, mCameraChargeTimer,
-- that climbs toward mCameraChargeTimeMax, and the shutter (photoTakeCheck)
-- only fires once it is full. The test is inlined in the shutter code, so
-- holding the timer at 0 refuses every shot without a hook. It is also the
-- state the game leaves the camera in after every photo, so nothing else
-- notices. Frank can still raise the camera, aim and zoom; story photo ops
-- open, refuse the shot and move on (measured in game, 2026-10-19).
--
-- The timer is not saved, and doStart / resetManager put it back to full, so
-- the hold is per frame against a manager looked up fresh each time: a load
-- or Back to Title makes a new one. The write runs on both sides of
-- UpdateBehavior and again on frame, so a manager created during the update
-- is emptied before the frame ends. Raising the camera takes many frames, so
-- the one frame it was born full cannot be used.
--
-- The saved battery count (the 093/100 readout, InGameFlowManager) is not
-- touched: it is saved, so holding it would mean restoring a value later.
--
-- When the item arrives the hold stops and the gauge is set full at once. A
-- manager that does not exist yet starts full on its own.
--
-- Off unless the slot asks (camera_item). Offline is vanilla; the console's
-- drap_camera_lock() stands in for the server when testing.

local Shared = require("DRAP/Shared")
local ItemEffects = require("DRAP/ItemEffects")

local M = Shared.create_module("CameraLock")

local ITEM = "Camera"
M.ITEM = ITEM

local PM_T = "app.solid.gamemastering.PhotoManager"
local PHOTO_MODE_TAKE = 1          -- PhotoManager.PhotoMode: camera raised
local NOTICE_COOLDOWN_S = 20

local enabled = false      -- slot_data.camera_item
local debug_held = nil     -- console: nil = the server decides, else held?
local released = false     -- the gauge was handed back this session
local last_addr = nil      -- the manager the hold last wrote to
local last_mode = nil
local last_notice = -math.huge
local stats = { writes = 0, managers = 0, raises = 0 }

------------------------------------------------------------
-- World access. One table so the unit test can replace it.
------------------------------------------------------------

local world = {}

function world.now() return os.clock() end

function world.active()
    local Activation = package.loaded["DRAP/Activation"]
    return Activation ~= nil and Activation.is_active ~= nil
        and Activation.is_active() == true
end

--- Fails OPEN like VehicleGate: an unreadable inventory must not take the
--- camera away, and the lock is only armed on a slot connect anyway.
function world.has_camera()
    local bridge = _G.AP and _G.AP.AP_BRIDGE
    if not (bridge and bridge.has_item_name) then return true end
    local ok, v = pcall(bridge.has_item_name, ITEM)
    if not ok then return true end
    return v == true
end

function world.manager() return sdk.get_managed_singleton(PM_T) end

function world.addr(pm)
    return Shared.safe(function() return pm:get_address() end)
end

function world.set_timer(pm, v)
    return Shared.safe(function()
        pm:set_field("mCameraChargeTimer", v)
        return true
    end) == true
end

function world.max(pm)
    return tonumber(Shared.safe(function()
        return pm:get_field("mCameraChargeTimeMax")
    end))
end

function world.mode(pm)
    return Shared.to_int(Shared.safe(function()
        return pm:get_field("CurrentPhotoMode")
    end))
end

function world.notify()
    local Notify = package.loaded["DRAP/Notify"] or require("DRAP/Notify")
    if not (Notify and Notify.send) then return end
    local name = Notify.span and Notify.span(ITEM, "location", true) or ITEM
    pcall(Notify.send, "You need the " .. name .. " to take photos.",
        { duration = 5.0 })
end

------------------------------------------------------------
-- The hold
------------------------------------------------------------

local function armed()
    return (enabled or debug_held ~= nil) and world.active()
end

local function locked()
    if debug_held ~= nil then return not debug_held end
    return not world.has_camera()
end

--- Told when the camera comes up, not on the shutter: the press itself is
--- refused inside the game's own update and never reaches Lua.
local function watch_raise(pm)
    local mode = world.mode(pm)
    if mode == PHOTO_MODE_TAKE and last_mode ~= PHOTO_MODE_TAKE then
        stats.raises = stats.raises + 1
        local now = world.now()
        if now - last_notice >= NOTICE_COOLDOWN_S then
            last_notice = now
            world.notify()
        end
    end
    last_mode = mode
end

local function release(pm)
    released = true
    last_addr, last_mode = nil, nil
    if not pm then
        M.log("Camera received -- no PhotoManager yet, it will start full")
        return
    end
    local mx = world.max(pm)
    if mx and mx > 0 and world.set_timer(pm, mx) then
        M.log(string.format("Camera received -- gauge set full (%.2f)", mx))
    else
        M.log("Camera received -- hold stopped, the gauge refills on its own")
    end
end

--- One pass. Runs before and after UpdateBehavior and on frame; each pass is
--- a lookup and at most one field write.
function M.tick()
    if not armed() then return end
    local pm = world.manager()
    if not locked() then
        if not released then release(pm) end
        return
    end
    released = false
    if not pm then
        last_addr, last_mode = nil, nil
        return
    end
    if world.set_timer(pm, 0.0) then stats.writes = stats.writes + 1 end
    local a = world.addr(pm)
    if a ~= last_addr then
        last_addr = a
        stats.managers = stats.managers + 1
        M.log(string.format("holding PhotoManager 0x%x (no %s yet)", a or 0, ITEM))
    end
    watch_raise(pm)
end

local function safe_tick()
    local ok, err = pcall(M.tick)
    if not ok then M.log.warn("tick failed: " .. tostring(err)) end
end

if re then
    re.on_pre_application_entry("UpdateBehavior", safe_tick)
    re.on_application_entry("UpdateBehavior", safe_tick)
    re.on_frame(safe_tick)
end

------------------------------------------------------------
-- Public
------------------------------------------------------------

--- From slot data.
function M.setup(on)
    enabled = (on == true)
    released = false
    last_addr, last_mode = nil, nil
    M.log("Camera item " .. (enabled and "ON -- shutter locked until the Camera arrives" or "off"))
end

function M.is_enabled() return enabled end

--- True while the shutter is being held.
function M.is_locked() return armed() and locked() end

function M.register()
    ItemEffects.register(ITEM, {
        on_replay = "apply",
        apply = function(ctx)
            -- The frame pass sees it through the bridge; this is the record.
            if not (ctx and ctx.is_replay) then
                M.log("Camera arrived from " .. tostring(ctx and ctx.sender_name))
            end
        end,
    })
end

--- Testing hook: replace world access.
function M._set_world(w)
    for k, v in pairs(w) do world[k] = v end
end

--- Testing hook: back to a fresh start.
function M._reset()
    enabled, debug_held, released = false, nil, false
    last_addr, last_mode, last_notice = nil, nil, -math.huge
    stats = { writes = 0, managers = 0, raises = 0 }
end

function M._stats() return stats end

local function status_line()
    return string.format(
        "camera_item(slot)=%s debug=%s locked=%s released=%s writes=%d managers=%d raises=%d",
        tostring(enabled),
        debug_held == nil and "off" or (debug_held and "held" or "not held"),
        tostring(M.is_locked()), tostring(released),
        stats.writes, stats.managers, stats.raises)
end

------------------------------------------------------------
-- Console
------------------------------------------------------------

--- drap_camera()          status
--- drap_camera_lock()     DEBUG: lock with no slot (needs drap_activate_debug())
--- drap_camera_give()     DEBUG: hand the Camera over
--- drap_camera_off()      DEBUG: back to the slot setting
_G.drap_camera = function() M.log(status_line()) end

_G.drap_camera_lock = function()
    debug_held = false
    released = false
    M.log("DEBUG: shutter locked without a slot")
    if not world.active() then
        M.log("DRAP is dormant: run drap_activate_debug() or nothing is held")
    end
    M.log(status_line())
end

_G.drap_camera_give = function()
    if debug_held == nil then
        M.log.warn("debug not armed -- run drap_camera_lock() first")
        return
    end
    debug_held = true
    M.log("DEBUG: Camera handed over")
end

_G.drap_camera_off = function()
    debug_held = nil
    released = false
    M.log("DEBUG: back to the slot setting")
end

return M
