-- DRAP/effects/DoorPromptOverlay.lua
-- Toast overlay that shows the actual destination at randomized doors.
-- See docs/reframework/features/door_prompt_overlay.md.
--
-- Hooks SignBoardUI.setElement read-only, watches door-Guid prompts,
-- and fires Notify.send (same path as AP item-received toasts) with
-- "<vanilla> -> <actual>" while the player stands at a redirected door.

local M = {}

local Notify        = require("DRAP/Notify")
local DoorAreaGuids = require("DRAP/effects/DoorAreaGuids")

local Shared = require("DRAP/Shared")
local log = Shared.create_logger("DoorOverlay")

------------------------------------------------------------
-- State
------------------------------------------------------------

local _state = {
    enabled            = false,
    redirects_by_scene = {},   -- scene_code -> { [vanilla_dest_name] = actual_dest_name }
    anchors_by_scene   = {},   -- scene_code -> { {x, z, vanilla, to}, ... } (Door Locks)
    last_seen          = {},   -- door_guid_str -> os.clock() of last setElement fire
    active_guid        = nil,  -- current "in view" door Guid (or nil)
    last_shown_text    = nil,  -- text most recently sent (re-fire only on change)
    last_shown_at      = 0,    -- os.clock() of last successful send (for refresh timer)
    watchdog_timeout   = 0.20, -- seconds; if no setElement in this window, treat as gone
    refresh_interval   = 3.5,  -- seconds; re-fire send to keep the toast alive while at door
    notify_duration    = 5.0,  -- seconds; toast auto-hide window passed to M.send
    hook_installed     = false,
    on_frame_registered = false,
    -- Diagnostics
    diag_hook_fires    = 0,
    diag_door_hits     = 0,
    diag_show_calls    = 0,
    diag_skipped_calls = 0,
    diag_last_log      = 0,
}

------------------------------------------------------------
-- Engine accessors
------------------------------------------------------------

local safe = Shared.safe

-- Read AreaManager.CurrentLevelPath (e.g. "SCN_s230") and strip the prefix.
-- Used as the key into _state.redirects_by_scene.
local function get_current_scene_code()
    local am = sdk.get_managed_singleton("app.solid.gamemastering.AreaManager")
    if not am then return nil end
    local path = safe(function() return am:get_field("CurrentLevelPath") end)
    if not path then return nil end
    local s = tostring(path)
    if s == "" then return nil end
    return (s:gsub("^SCN_", ""))
end

-- Read player world position for door disambiguation. Returns (x, z) only
-- since the ambiguous doorways are at the same elevation -- y is dropped to
-- skip a needless coordinate. Returns nil if the player isn't spawned.
local function get_player_xyz()
    local pm = sdk.get_managed_singleton("app.solid.PlayerManager")
    if not pm then return nil end
    local cond = safe(function() return pm:call("get_CurrentPlayerCondition") end)
    if not cond then return nil end
    local pos = safe(function() return cond:get_field("LastPlayerPos") end)
    if not pos then return nil end
    local x, y, z
    pcall(function() x = pos.x; y = pos.y; z = pos.z end)
    return x, y, z
end

------------------------------------------------------------
-- 2-door same-destination disambiguation
--
-- The signboard Guid encodes only the destination area name, so two doors
-- in the same scene with the same vanilla destination both fire the same
-- "<destination>" message. The slot-data overlay map collapses them to a
-- single entry. To show the right "actual" destination for each, we pick
-- the door whose anchor position is closest to the player and look up that
-- specific door's redirect in DoorRandomizer.get_redirects().
--
-- This only applies to the Wonderland Plaza (s300) <-> North Plaza (s400)
-- pair -- the only place in the game with two passable doorways between
-- the same two areas. Anchors captured 2026-04-30 by averaging two samples
-- per doorway via _G.drap_player_pos().
------------------------------------------------------------

local AMBIGUOUS_DOOR_ANCHORS = {
    ["s300|s400"] = {
        { door_no = 0, x = -178.5, z = -103.9 },  -- west doorway
        { door_no = 1, x =  -85.2, z =  -79.2 },  -- east doorway
    },
    ["s400|s300"] = {
        { door_no = 0, x = -179.5, z = -104.7 },  -- west doorway
        { door_no = 1, x =  -85.3, z =  -80.5 },  -- east doorway
    },
}

-- Reverse lookup: area name (as displayed) -> scene code. Built once at
-- module load from Shared.SCENE_INFO so we can derive the target scene
-- code from the signboard's vanilla name.
local NAME_TO_SCENE_CODE = {}
for code, info in pairs(Shared.SCENE_INFO) do
    if info and info.name then
        NAME_TO_SCENE_CODE[info.name] = code
    end
end

-- Pick the door_no whose anchor is closest to the current player position.
-- Returns 0 if either the (scene, target) pair isn't ambiguous (single-door
-- edge -- door_no=0 is a safe default) or the player position is unreadable.
local function resolve_door_no(scene_code, target_code)
    local key = scene_code .. "|" .. target_code
    local candidates = AMBIGUOUS_DOOR_ANCHORS[key]
    if not candidates then return 0 end

    local px, _, pz = get_player_xyz()
    if px == nil then return 0 end

    local best_d2, best_door = math.huge, 0
    for _, c in ipairs(candidates) do
        local dx = px - c.x
        local dz = pz - c.z
        local d2 = dx * dx + dz * dz
        if d2 < best_d2 then
            best_d2 = d2
            best_door = c.door_no
        end
    end
    return best_door
end

-- For ambiguous (scene, target) pairs, override the area-name-keyed lookup
-- using the per-door DoorRandomizer.get_redirects() table. Returns:
--   resolved_actual_name (string) -- if the specific door is redirected to a
--                                    non-vanilla destination
--   nil + true              -- if the specific door is NOT redirected (vanilla)
--   fallback                -- if the override doesn't apply (single-door edge,
--                              missing data, etc.) -- caller uses its default
--                              area-name-keyed lookup
local function override_actual_name(scene_code, vanilla_name)
    if not (scene_code and vanilla_name) then return nil, false end
    local target_code = NAME_TO_SCENE_CODE[vanilla_name]
    if not target_code then return nil, false end
    if not AMBIGUOUS_DOOR_ANCHORS[scene_code .. "|" .. target_code] then
        return nil, false
    end

    local door_no = resolve_door_no(scene_code, target_code)
    local door_id = string.format("SCN_%s|%s|door%d", scene_code, target_code, door_no)

    local DR = _G.AP and _G.AP.DoorRandomizer
    if not (DR and DR.get_redirects) then return nil, false end
    local redirects = DR.get_redirects() or {}
    local redirect = redirects[door_id]
    if not (redirect and redirect.target_area) then
        -- Door has no redirect entry at all -- it stays vanilla. Suppress.
        return nil, true
    end

    local actual_info = Shared.SCENE_INFO[redirect.target_area]
    local actual_resolved = actual_info and actual_info.name
    if not actual_resolved then return nil, false end
    if actual_resolved == vanilla_name then
        -- This specific door's redirect is a vanilla pass-through. Suppress.
        return nil, true
    end
    return actual_resolved, true
end

------------------------------------------------------------
-- SignBoardUI hook (read-only)
------------------------------------------------------------

local function install_hook()
    if _state.hook_installed then return true end
    local td = sdk.find_type_definition("app.solid.gui.SignBoardUI")
    if not td then log("SignBoardUI type missing"); return false end

    -- Pick the 2-param setElement overload explicitly.
    local m
    for _, method in ipairs(td:get_methods() or {}) do
        if method:get_name() == "setElement" then
            local np = 0
            pcall(function() np = method:get_num_params() end)
            if np == 2 then m = method; break end
        end
    end
    if not m then log("setElement(2p) method missing"); return false end

    sdk.hook(m,
        function(args)
            if not _state.enabled then return end
            _state.diag_hook_fires = _state.diag_hook_fires + 1
            -- args[3]=index, args[4]=Element. Don't filter on bIsVisible --
            -- engine sets visibility in a later phase of the same frame.
            -- See door_prompt_overlay.md § Gotchas.
            local elem = safe(function() return sdk.to_managed_object(args[4]) end)
            if not elem then return end
            local guid_obj
            pcall(function() guid_obj = elem:get_field("mMessageId") end)
            if not guid_obj then return end
            local guid_str = safe(function() return guid_obj:call("ToString") end)
            if not guid_str then return end
            guid_str = tostring(guid_str)
            if not DoorAreaGuids.IS_DOOR_GUID[guid_str] then return end
            _state.diag_door_hits = _state.diag_door_hits + 1
            _state.last_seen[guid_str] = os.clock()
        end,
        function(retval) return retval end)

    _state.hook_installed = true
    log("SignBoardUI.setElement read-only hook installed")
    return true
end

------------------------------------------------------------
-- Per-frame driver
------------------------------------------------------------

-- Most-recently-stamped door Guid that's still inside the watchdog window.
-- Prunes stale entries as we go.
local function pick_active_guid()
    local now = os.clock()
    local most_recent_guid, most_recent_ts = nil, 0
    for guid, ts in pairs(_state.last_seen) do
        if now - ts >= _state.watchdog_timeout then
            _state.last_seen[guid] = nil
        elseif ts > most_recent_ts then
            most_recent_guid, most_recent_ts = guid, ts
        end
    end
    return most_recent_guid
end

local function build_overlay_text(vanilla_name, actual_name)
    local v = Notify.span(vanilla_name, "gray",     false)
    local a = Notify.span(actual_name,  "location", true)
    return v .. " -> " .. a
end

-- Send, honouring the change/refresh throttle. Both the signboard path and
-- the proximity fallback go through here so a toast cannot be sent twice.
local function send_overlay(text)
    local now = os.clock()
    if _state.last_shown_text == text
       and (now - _state.last_shown_at) < _state.refresh_interval then
        return true
    end
    if Notify.send(text, { duration = _state.notify_duration }) then
        _state.diag_show_calls = _state.diag_show_calls + 1
        _state.last_shown_text = text
        _state.last_shown_at = now
        return true
    end
    _state.diag_skipped_calls = _state.diag_skipped_calls + 1
    return false
end

------------------------------------------------------------
-- Proximity fallback
--
-- A locked door has its hit data disabled, so the game raises no signboard
-- and the hook above never fires -- leaving the player no way to find out
-- where a door goes until they have already unlocked it. Standing near the
-- door answers instead, using the per-door anchors from slot data.
--
-- Only used when the signboard is absent, so an openable door still gets its
-- prompt-driven toast and nothing fires twice.
------------------------------------------------------------

-- Where the hint speaks from. Eight metres around a landing-spot anchor
-- with no height check fired it from a balcony a floor above the door
-- (tester report). Now the door's own trigger is used when DoorSceneLock
-- has recorded it: the engine's interaction point with its cylinder, the
-- same volume the engine prompts from, plus a small margin. Anchors are
-- only the fallback, at 2 metres on the plane and 1 metre of height.
--
-- The Food Court's tunnel and Wonderland doorways are only 8.8 apart, so
-- the nearest wins rather than the first in range.
local TRIGGER_MARGIN = 0.5           -- metres beyond the door's own radius
local TRIGGER_MIN_HEIGHT = 1.0       -- band when the cylinder has no height
local ANCHOR_RADIUS_SQ = 2.0 * 2.0
local ANCHOR_HEIGHT_BAND = 1.0

--- The recorded trigger for this anchor's vanilla door, nearest to the
--- player if the destination has more than one door.
local function trigger_for(scene, anchor, px, pz)
    local lock = _G.AP and _G.AP.DoorSceneLock
    if not (lock and lock.door_triggers) then return nil end
    local to_code = NAME_TO_SCENE_CODE[anchor.vanilla]
    if not to_code then return nil end
    local best, best_d2 = nil, math.huge
    for _, t in ipairs(lock.door_triggers(scene)) do
        if t.to == to_code then
            local dx, dz = px - t.x, pz - t.z
            local d2 = dx * dx + dz * dz
            if d2 < best_d2 then best, best_d2 = t, d2 end
        end
    end
    return best
end

local function nearest_anchor(scene, px, py, pz)
    local list = scene and _state.anchors_by_scene[scene] or nil
    if not list then return nil end
    local best, best_d2 = nil, math.huge
    for _, anchor in ipairs(list) do
        local t = trigger_for(scene, anchor, px, pz)
        local d2, within
        if t then
            local dx, dz = px - t.x, pz - t.z
            d2 = dx * dx + dz * dz
            local reach = (t.radius or 0) + TRIGGER_MARGIN
            local band = math.max(t.height or 0, TRIGGER_MIN_HEIGHT)
            within = d2 <= reach * reach
                and (py == nil or math.abs(py - t.y) <= band)
        else
            local dx, dz = px - anchor.x, pz - anchor.z
            d2 = dx * dx + dz * dz
            within = d2 <= ANCHOR_RADIUS_SQ
                and (anchor.y == nil or py == nil
                     or math.abs(py - anchor.y) <= ANCHOR_HEIGHT_BAND)
        end
        if within and d2 < best_d2 then best, best_d2 = anchor, d2 end
    end
    return best
end

-- The key hint waits for the first Entrance Plaza cutscene (event 2, which
-- the engine records in EV_EVENT02_1 / EV_EVENT02_2). Before it the player
-- is still in the opening and a "needs <key>" toast reads as a bug. Read
-- from the flags, not the ledger: a new game on the same seed starts over.
local EP_INTRO_FLAGS = { 259, 256 }
local ep_intro_seen = false

local function ep_intro_done()
    if ep_intro_seen then return true end
    local efm = sdk.get_managed_singleton("app.solid.gamemastering.EventFlagsManager")
    if not efm then return false end
    for _, id in ipairs(EP_INTRO_FLAGS) do
        if safe(function() return efm:call("evFlagCheck", id) end) == true then
            ep_intro_seen = true
            return true
        end
    end
    return false
end

------------------------------------------------------------
-- Key hints
------------------------------------------------------------
-- A locked door raises no prompt at all, so a new player walks up to the vent
-- or the elevator, gets nothing, and reads it as a broken game. Naming the key
-- it wants also tells them what to hint for.
--
-- Built from shared data rather than slot data: the area and split-key tables
-- already carry key_item, and split_areas lists BOTH directions of every
-- transition, which is what makes the hint appear on either side of a door.

local key_for_scene, key_for_transition = nil, nil

local function build_key_tables()
    if key_for_scene then return end
    key_for_scene, key_for_transition = {}, {}
    local ok, SharedData = pcall(require, "DRAP/SharedData")
    if not ok or not SharedData then return end
    for _, a in ipairs((SharedData.areas and SharedData.areas()) or {}) do
        if a.scene_code and a.key_item then
            key_for_scene[a.scene_code] = a.key_item
        end
    end
    for _, sa in ipairs((SharedData.split_areas and SharedData.split_areas()) or {}) do
        for _, t in ipairs(sa.transitions or {}) do
            if t.origin and t.destination and sa.key_item then
                key_for_transition[t.origin .. "|" .. t.destination] = sa.key_item
            end
        end
    end
end

--- The key a door is waiting on, or nil when it is already open.
---
--- Asks DoorSceneLock rather than tracking received items here, so the hint
--- disappears exactly when the door starts working -- one source of truth.
local function locked_key_for(origin_code, dest_code)
    if not (origin_code and dest_code) then return nil end
    local lock = _G.AP and _G.AP.DoorSceneLock
    if not lock then return nil end
    build_key_tables()

    if lock.get_split_keys_enabled and lock.get_split_keys_enabled() then
        if lock.is_transition_locked
            and lock.is_transition_locked(origin_code, dest_code) then
            return key_for_transition[origin_code .. "|" .. dest_code]
        end
        return nil
    end

    if lock.is_scene_locked and lock.is_scene_locked(dest_code) then
        return key_for_scene[dest_code]
    end
    return nil
end

local function show_nearby_door()
    if next(_state.anchors_by_scene) == nil then return end
    local px, py, pz = get_player_xyz()
    if px == nil then return end

    local anchor = nearest_anchor(get_current_scene_code(), px, py, pz)
    if not anchor then
        _state.last_shown_text = nil
        return
    end

    local scene = get_current_scene_code()
    local key = locked_key_for(scene, NAME_TO_SCENE_CODE[anchor.to])
    if key and not ep_intro_done() then key = nil end
    local redirected = anchor.to ~= anchor.vanilla

    -- Anchors are sent for every seed now, so this path runs even with the
    -- randomizer off -- and naming the destination of an ordinary unlocked
    -- door would be noise at every doorway in the mall. Speak only when there
    -- is something the player cannot already see: a redirect, a key they are
    -- waiting on, or Door Locks, where a locked door raises no prompt at all
    -- and naming plain destinations is the point.
    local lock = _G.AP and _G.AP.DoorSceneLock
    local door_locks = (lock and lock.get_door_locks_enabled
        and lock.get_door_locks_enabled()) or false
    if not (redirected or key or door_locks) then
        _state.last_shown_text = nil
        return
    end

    local text
    if redirected then
        text = build_overlay_text(anchor.vanilla, anchor.to)
    else
        text = Notify.span(anchor.to, "location", true)
    end

    -- Say what it wants, not just where it goes.
    if key then
        -- Purple, not the green used for the destination in this same toast:
        -- two bold greens read as one phrase. Purple is the AP progression
        -- color, which is what a key is.
        text = text .. "  --  needs " .. Notify.span(key, "progression", true)
    end

    send_overlay(text)
end

local function update_overlay()
    if not _state.enabled then return end
    local guid = pick_active_guid()
    local guid_changed = (guid ~= _state.active_guid)
    _state.active_guid = guid

    -- No door in view. Either there is genuinely none, or the door is locked
    -- and raises no prompt -- so fall back to standing near one before
    -- dropping our state.
    if guid == nil then
        local had_text = _state.last_shown_text ~= nil
        show_nearby_door()
        if had_text and _state.last_shown_text == nil then
            log("active door cleared")
        end
        return
    end

    local vanilla_name = DoorAreaGuids.GUID_TO_NAME[guid]
    if not vanilla_name then
        if guid_changed then log("active door guid=" .. guid .. " (no name)") end
        _state.last_shown_text = nil
        return
    end

    local scene = get_current_scene_code()
    local scene_table = scene and _state.redirects_by_scene[scene] or nil
    local actual_name = scene_table and scene_table[vanilla_name] or nil

    -- For known 2-door same-destination edges (Wonderland<->North Plaza),
    -- override the area-name-keyed lookup with a per-door lookup. The
    -- area-name map collapses door0 + door1, so without this the overlay
    -- would mis-promise where the player is going for whichever door
    -- happens to lose the collapse race.
    local override, override_handled = override_actual_name(scene, vanilla_name)
    if override_handled then
        actual_name = override   -- string => use it; nil => suppress overlay
    end

    if not actual_name then
        -- Door isn't redirected for this seed/scene -- vanilla prompt is correct.
        if guid_changed then
            log(string.format("active door '%s' (scene=%s) -- not redirected, vanilla prompt OK",
                vanilla_name, tostring(scene)))
        end
        _state.last_shown_text = nil
        return
    end

    if send_overlay(build_overlay_text(vanilla_name, actual_name)) then
        if guid_changed then
            log(string.format("active door '%s' redirected -> '%s' (scene=%s) toast sent",
                vanilla_name, actual_name, tostring(scene)))
        end
    elseif guid_changed then
        log(string.format("active door '%s' redirected -> '%s' but Notify.send failed -- will retry",
            vanilla_name, actual_name))
    end
end

-- Periodic counter dump. Helps debug "the overlay isn't firing" reports
-- without having to enable verbose logging.
local function maybe_log_diagnostics()
    local now = os.clock()
    if now - _state.diag_last_log < 30.0 then return end
    _state.diag_last_log = now
    log(string.format(
        "diag: hook_fires=%d door_hits=%d shows=%d skipped=%d active=%s",
        _state.diag_hook_fires, _state.diag_door_hits,
        _state.diag_show_calls, _state.diag_skipped_calls,
        tostring(_state.active_guid)))
end

-- Per-frame driver registered at module load (registering re.on_frame from
-- within another on_frame disrupts REFramework's iteration).
re.on_frame(function()
    if not _state.enabled then return end
    update_overlay()
    maybe_log_diagnostics()
end)

------------------------------------------------------------
-- Public API
------------------------------------------------------------

-- Called from AP_DRDR_main on slot connect. Pass nil/empty to disable.
-- door_anchors is the Door Locks per-door position table; without it the
-- overlay only answers when the game raises a prompt.
function M.setup(door_overlay_data, door_anchors)
    local have_overlay = type(door_overlay_data) == "table"
                         and next(door_overlay_data) ~= nil
    local have_anchors = type(door_anchors) == "table"
                         and next(door_anchors) ~= nil

    if not (have_overlay or have_anchors) then
        _state.enabled = false
        _state.redirects_by_scene = {}
        _state.anchors_by_scene = {}
        _state.last_shown_text = nil
        log("disabled (no door redirects this seed)")
        return
    end
    _state.redirects_by_scene = have_overlay and door_overlay_data or {}
    _state.anchors_by_scene = have_anchors and door_anchors or {}
    _state.enabled = true

    if have_anchors then
        local anchor_count = 0
        for _, list in pairs(_state.anchors_by_scene) do
            anchor_count = anchor_count + #list
        end
        log(string.format("proximity fallback armed with %d door anchors", anchor_count))
    end
    install_hook()
    local scene_count, redirect_count = 0, 0
    for _, t in pairs(door_overlay_data) do
        scene_count = scene_count + 1
        for _ in pairs(t) do redirect_count = redirect_count + 1 end
    end
    log(string.format("enabled: %d scenes, %d redirected doors total",
        scene_count, redirect_count))
end

function M.register()
    -- No-op: hook + on_frame install lazily on first setup() call.
end

------------------------------------------------------------
-- Console commands
------------------------------------------------------------

_G.drap_door_overlay_dump = function()
    log("enabled = " .. tostring(_state.enabled))
    log("active_guid = " .. tostring(_state.active_guid))
    log(string.format(
        "counters: hook_fires=%d door_hits=%d shows=%d skipped=%d",
        _state.diag_hook_fires, _state.diag_door_hits,
        _state.diag_show_calls, _state.diag_skipped_calls))
    local scene = get_current_scene_code()
    log("current scene = " .. tostring(scene))
    log("redirects in current scene:")
    if scene and _state.redirects_by_scene[scene] then
        for vanilla, actual in pairs(_state.redirects_by_scene[scene]) do
            log(string.format("  %s -> %s", vanilla, actual))
        end
    else
        log("  (none)")
    end
end

-- Capture-helper for the 2-door / same-destination disambiguation. Walk up
-- to a specific doorway with the signboard panel showing, run this in the
-- REFramework console, and the printed (x, y, z) is the player position to
-- associate with that specific door. Used when assembling the hardcoded
-- per-door overrides for the s300<->s400 (Wonderland<->North) pairs.
--- The capture used to map the Maintenance Tunnel doorways: stand in a spot,
--- run it, and the printed position is what to associate with that door.
---
--- Also prints the raw area index, which SCENE_INFO needs and nothing else
--- reports. The index is not derivable from the scene code -- most look like
--- hex but s135 is 287, not 309 -- so for any area we have not catalogued it
--- has to be read here.
function M.capture_position()
    local pm = sdk.get_managed_singleton("app.solid.PlayerManager")
    local x, y, z = nil, nil, nil
    if pm then
        local cond = safe(function() return pm:call("get_CurrentPlayerCondition") end)
        if cond then
            local pos = safe(function() return cond:get_field("LastPlayerPos") end)
            if pos then
                pcall(function() x = pos.x; y = pos.y; z = pos.z end)
            end
        end
    end

    local scene = get_current_scene_code() or "?"
    local active_guid = pick_active_guid()
    local active_door = (active_guid and DoorAreaGuids.GUID_TO_NAME[active_guid])
                        or "<no door panel active>"

    if x == nil then
        log("capture_position: PlayerManager.CurrentPlayerCondition.LastPlayerPos unavailable")
        return
    end

    local area_index
    local am = sdk.get_managed_singleton("app.solid.gamemastering.AreaManager")
    if am then
        area_index = safe(function() return am:get_field("mAreaIndex") end)
    end

    log(string.format("scene=%s index=%s pos=(%.3f, %.3f, %.3f) door=%s",
        scene, tostring(area_index), x, y, z, active_door))
    return x, y, z, scene, area_index
end

_G.drap_player_pos = function() return M.capture_position() end

return M
