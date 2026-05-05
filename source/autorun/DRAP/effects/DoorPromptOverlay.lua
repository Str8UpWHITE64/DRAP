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
local function get_player_xz()
    local pm = sdk.get_managed_singleton("app.solid.PlayerManager")
    if not pm then return nil end
    local cond = safe(function() return pm:call("get_CurrentPlayerCondition") end)
    if not cond then return nil end
    local pos = safe(function() return cond:get_field("LastPlayerPos") end)
    if not pos then return nil end
    local x, z
    pcall(function() x = pos.x; z = pos.z end)
    return x, z
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

    local px, pz = get_player_xz()
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

local function update_overlay()
    if not _state.enabled then return end
    local guid = pick_active_guid()
    local guid_changed = (guid ~= _state.active_guid)
    _state.active_guid = guid

    -- No door in view: drop our state. Toast (if any) auto-hides via Notify.
    if guid == nil then
        if _state.last_shown_text ~= nil then
            _state.last_shown_text = nil
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

    local text = build_overlay_text(vanilla_name, actual_name)
    local now = os.clock()
    local need_send =
        _state.last_shown_text ~= text
        or (now - _state.last_shown_at) >= _state.refresh_interval
    if not need_send then return end

    local ok = Notify.send(text, { duration = _state.notify_duration })
    if ok then
        _state.diag_show_calls = _state.diag_show_calls + 1
        _state.last_shown_text = text
        _state.last_shown_at = now
        if guid_changed then
            log(string.format("active door '%s' redirected -> '%s' (scene=%s) toast sent",
                vanilla_name, actual_name, tostring(scene)))
        end
    else
        _state.diag_skipped_calls = _state.diag_skipped_calls + 1
        if guid_changed then
            log(string.format("active door '%s' redirected -> '%s' but Notify.send failed -- will retry",
                vanilla_name, actual_name))
        end
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
function M.setup(door_overlay_data)
    if type(door_overlay_data) ~= "table"
       or next(door_overlay_data) == nil then
        _state.enabled = false
        _state.redirects_by_scene = {}
        _state.last_shown_text = nil
        log("disabled (no door redirects this seed)")
        return
    end
    _state.redirects_by_scene = door_overlay_data
    _state.enabled = true
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
_G.drap_player_pos = function()
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
        log("drap_player_pos: PlayerManager.CurrentPlayerCondition.LastPlayerPos unavailable")
        return
    end

    log(string.format("scene=%s pos=(%.3f, %.3f, %.3f) door=%s",
        scene, x, y, z, active_door))
end

return M
