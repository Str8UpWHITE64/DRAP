-- DRAP/SceneFixups.lua
-- Per-scene fixups applied automatically on scene load.
-- See docs/reframework/features/scene_fixups.md.
--
-- Hooks AreaManager.onLoadMapEvent. Each registered scene path runs a
-- precondition check and applies its tweak, with per-frame retry until the
-- targeted state is populated.

local M = {}

local Shared = require("DRAP/Shared")
local log = Shared.create_logger("SceneFixups")
M.log = log

------------------------------------------------------------
-- State
------------------------------------------------------------

local hook_installed = false
local frame_cb_installed = false
local pending = {}        -- { [scene_name] = fixup_fn }
local frames_waited = {}  -- { [scene_name] = count }

-- Forward reference; set after the require chain runs.
local function get_scoop_unlocker()
    return _G.AP and _G.AP.ScoopUnlocker
end

------------------------------------------------------------
-- Per-scene fixup functions
-- Each returns true on success (stop retrying), false to keep trying.
------------------------------------------------------------

-- Area codes used by AreaManager.
local AREA_S100 = 256   -- Entrance Plaza
local AREA_S136 = 288   -- Security Room
local AREA_S138 = 290   -- "Zombie hallway" safe-room variant (the trigger we hijack)
local AREA_S231 = 535   -- Rooftop (canonical "from-area" for the rescue cutscene)

-- Forward declaration: get_escort_count is defined further down but referenced
-- from fixup_s136 below. Without this, Lua resolves the name as a (nil) global
-- at parse time and every fixup call throws silently inside pcall, burning
-- the full retry budget. See scene_fixups.md.
local get_escort_count

-- s136 (Security Room): disable the south-door barricade and, if the player
-- arrived via an EP->s136 redirect with an escorted NPC, patch
-- AreaManager.mAreaIndex/mOldAreaIndex so the rescue cutscene fires.
-- See scene_fixups.md.
local function fixup_s136()
    local su = get_scoop_unlocker()
    if not su or not su.is_ap_activated or not su.is_ap_activated() then
        return true   -- precondition not met -- bail
    end

    local am = sdk.get_managed_singleton("app.solid.gamemastering.AreaManager")
    if not am then return false end

    -- If escorted, patch area indices so the rescue cutscene's s231->s136
    -- check matches our redirected entries.
    if get_escort_count() > 0 then
        local mai, moai
        pcall(function() mai = am:get_field("mAreaIndex") end)
        pcall(function() moai = am:get_field("mOldAreaIndex") end)
        mai = tonumber(mai) or 0
        moai = tonumber(moai) or 0
        log(string.format("s136 entry with escort: mAreaIndex=%d mOldAreaIndex=%d",
            mai, moai))
        pcall(function() am:set_field("mAreaIndex", AREA_S136) end)
        pcall(function() am:set_field("mOldAreaIndex", AREA_S231) end)
        log(string.format("s136: patched mAreaIndex->%d mOldAreaIndex->%d",
            AREA_S136, AREA_S231))
    end

    -- Disable PREF_uOm114 barricade.
    local list
    pcall(function() list = am:get_field("OmList") end)
    if not list then return false end
    local count
    pcall(function() count = list:call("get_Count") end)
    count = tonumber(count) or 0
    if count == 0 then return false end

    for i = 0, count - 1 do
        local om
        pcall(function() om = list:call("get_Item", i) end)
        if om then
            local td = om:get_type_definition()
            local tname = (td and td:get_full_name()) or ""
            if tname == "solid.MT2RE.uOm114" then
                local go
                pcall(function() go = om:call("get_GameObject") end)
                if go then
                    pcall(function() go:call("set_UpdateSelf", false) end)
                    pcall(function() go:call("set_DrawSelf", false) end)
                    log(string.format("s136: disabled uOm114 (OmList[%d])", i))
                    return true
                end
            end
        end
    end
    return false  -- keep waiting; OmList might not have populated yet
end

-- s100 (Entrance Plaza): when AP is active, register a DoorRandomizer
-- callback that catches the EP->s138 trigger and resolves the destination
-- at crossing time (door rando vs vanilla, solo vs escort). See scene_fixups.md.
-- door_id format: "<from_area>|<area_jump_name>|door<door_no>"
local STATIC_REDIRECT_DOOR_ID = "SCN_s100|s138|door0"

-- Canonical Rooftop->SafeRoom arrival (sourced from DoorRandomization.py's
-- "SCN_s231|s136|door0" entry); used for the escort path under non-randomizer
-- routing so the engine's rescue-complete cutscene trigger fires.
local NPC_TARGET_POS   = { x = 153.19, y = 9.32,  z = 216.92 }
local NPC_TARGET_ANGLE = { x = 0.0,    y = 0.93,  z = 0.0 }

-- Manual override for the NPC arrival; nil = use the canonical values.
local npc_target_index = nil

function M.set_npc_target_index(idx)
    npc_target_index = tonumber(idx)
    log("NPC redirect target index override = " .. tostring(npc_target_index))
end

-- Look up the AHL_areahits100_UD layouts list. Returns nil if not loaded.
local function get_ep_ahl_layouts()
    local ahlm = sdk.get_managed_singleton("app.solid.gamemastering.AreaHitLayoutManager")
    if not ahlm then return nil end
    local res_list
    pcall(function() res_list = ahlm:get_field("mAreaHitResource") end)
    if not res_list then return nil end
    local count
    pcall(function() count = res_list:call("get_Count") end)
    count = tonumber(count) or 0
    for i = 0, count - 1 do
        local entry
        pcall(function() entry = res_list:call("get_Item", i) end)
        if entry then
            local file
            pcall(function() file = entry:get_field("file") end)
            if tostring(file or "") == "AHL_areahits100_UD" then
                local pres
                pcall(function() pres = entry:get_field("pResource") end)
                if pres then
                    local layouts
                    pcall(function() layouts = pres:get_field("mpLayoutInfoList") end)
                    return layouts
                end
            end
        end
    end
    return nil
end

-- Diagnostic: log s136-bound entries in AHL_areahits100_UD (idx + positions).
-- Used to identify the air-vent doorway index for set_npc_target_index().
function M.list_s136_targets()
    local layouts = get_ep_ahl_layouts()
    if not layouts then
        log("AHL_areahits100_UD not loaded -- must be in EP")
        return
    end
    local lcount
    pcall(function() lcount = layouts:call("get_Count") end)
    lcount = tonumber(lcount) or 0
    log(string.format("s136-bound entries in AHL_areahits100_UD (%d total layouts):", lcount))
    for j = 0, lcount - 1 do
        local info
        pcall(function() info = layouts:call("get_Item", j) end)
        if info then
            local jump
            pcall(function() jump = info:get_field("AREA_JUMP_NAME") end)
            if tostring(jump or "") == "s136" then
                local trigger, arrival
                pcall(function() trigger = info:get_field("p__mCursorWorldPos") end)
                pcall(function() arrival = info:get_field("AREA_JUMP_POS__") end)
                local tx, ty, tz, ax, ay, az = 0,0,0, 0,0,0
                if trigger then pcall(function() tx = trigger.x; ty = trigger.y; tz = trigger.z end) end
                if arrival then pcall(function() ax = arrival.x; ay = arrival.y; az = arrival.z end) end
                log(string.format(
                    "  [%2d] trigger=(%.1f,%.1f,%.1f)  arrival=(%.1f,%.1f,%.1f)",
                    j, tx, ty, tz, ax, ay, az))
            end
        end
    end
end

-- Returns the count of escorted NPCs (0 if none or unable to query).
-- NOTE: assigns to the forward-declared local at the top of the file -- do
-- NOT add `local` here, that would shadow the forward decl and leave
-- fixup_s136's reference resolving to nil.
function get_escort_count()
    local mgr = sdk.get_managed_singleton("app.solid.gamemastering.NpcManager")
    if not mgr then return 0 end
    local n = 0
    pcall(function() n = tonumber(mgr:call("getEscortNpcNum", 0)) or 0 end)
    return n
end

-- The canonical EP-to-SR door ID. When the door randomizer is active and
-- ScoopSanity has unlocked this edge (see DoorRandomization.SR_EP_EDGES),
-- this entry in DoorRandomizer.get_redirects() is the source of truth for
-- where pressing the EP-to-SR transition should send the player.
local EP_TO_SR_DOOR_ID = "SCN_s100|s136|door0"

-- Resolve the redirect target at door-crossing time. Order of precedence:
--
--   1. Door randomizer is active AND randomized SCN_s100|s136|door0: defer
--      to the randomizer's destination (regardless of escort count -- the
--      escort is carried along by NpcCarryover). This is the door we added
--      to the pool in DoorRandomization.SR_EP_EDGES under ScoopSanity.
--   2. Escort > 0 (non-randomizer or randomizer didn't pool the SR door):
--      route to the canonical Rooftop arrival point in s136 so the engine's
--      rescue-complete cutscene fires. Override via npc_target_index for
--      manual debugging.
--   3. Solo (non-randomizer or randomizer didn't pool the SR door): pick
--      the s136 entry whose trigger volume is closest to s138's trigger
--      volume. Original DRAP behavior preserved for non-rando configs.
local function resolve_redirect_target()
    local layouts = get_ep_ahl_layouts()
    if not layouts then return nil end
    local lcount
    pcall(function() lcount = layouts:call("get_Count") end)
    lcount = tonumber(lcount) or 0

    -- Tier 1: door randomizer's choice for the canonical EP->SR door.
    -- Applies regardless of escort count -- if the seed randomized the SR
    -- door, both player and any escorts go to the randomized destination.
    local dr = _G.AP and _G.AP.DoorRandomizer
    if dr and dr.is_enabled and dr.is_enabled() and dr.get_redirects then
        local redirects = dr.get_redirects() or {}
        local sr_redirect = redirects[EP_TO_SR_DOOR_ID]
        if sr_redirect and sr_redirect.target_area then
            log(string.format("Redirect target: DOOR_RANDOMIZER -> %s (via %s)",
                tostring(sr_redirect.target_area), EP_TO_SR_DOOR_ID))
            return {
                target_area = sr_redirect.target_area,
                target_pos = sr_redirect.target_pos,
                target_angle = sr_redirect.target_angle,
            }
        end
    end

    local escort = get_escort_count()

    -- Tier 2: escort path (non-randomizer routing). Route to the canonical
    -- Rooftop arrival point so the rescue-complete cutscene fires.
    if escort > 0 then
        if npc_target_index ~= nil then
            -- Manual override: use a specific AHL entry's arrival data.
            local info
            pcall(function() info = layouts:call("get_Item", npc_target_index) end)
            if info then
                local pos, angle
                pcall(function() pos = info:get_field("AREA_JUMP_POS__") end)
                pcall(function() angle = info:get_field("AREA_JUMP_ANGLE") end)
                if pos and angle then
                    log(string.format("Redirect target: NPC OVERRIDE idx=%d (escort=%d)",
                        npc_target_index, escort))
                    return { target_area = "s136", target_pos = pos, target_angle = angle }
                end
            end
            log(string.format(
                "NPC target idx=%d unreadable, falling back to canonical rooftop arrival",
                npc_target_index))
        end
        log(string.format("Redirect target: ROOFTOP ARRIVAL (escort=%d)", escort))
        return {
            target_area = "s136",
            target_pos = NPC_TARGET_POS,
            target_angle = NPC_TARGET_ANGLE,
        }
    end

    -- Tier 3: solo path -- pick the s136 entry closest to s138.
    local s138_pos
    for j = 0, lcount - 1 do
        local info
        pcall(function() info = layouts:call("get_Item", j) end)
        if info then
            local jump
            pcall(function() jump = info:get_field("AREA_JUMP_NAME") end)
            if tostring(jump or "") == "s138" then
                pcall(function() s138_pos = info:get_field("p__mCursorWorldPos") end)
                if s138_pos then break end
            end
        end
    end
    if not s138_pos then return nil end
    local sx, sy, sz = 0, 0, 0
    pcall(function() sx = s138_pos.x; sy = s138_pos.y; sz = s138_pos.z end)

    local best_dist, best_pos, best_angle, best_idx = math.huge, nil, nil, -1
    for j = 0, lcount - 1 do
        local info
        pcall(function() info = layouts:call("get_Item", j) end)
        if info then
            local jump
            pcall(function() jump = info:get_field("AREA_JUMP_NAME") end)
            if tostring(jump or "") == "s136" then
                local cur
                pcall(function() cur = info:get_field("p__mCursorWorldPos") end)
                if cur then
                    local cx, cy, cz = 0, 0, 0
                    pcall(function() cx = cur.x; cy = cur.y; cz = cur.z end)
                    local dx, dy, dz = cx - sx, cy - sy, cz - sz
                    local d = math.sqrt(dx*dx + dy*dy + dz*dz)
                    if d < best_dist then
                        best_dist = d
                        pcall(function() best_pos = info:get_field("AREA_JUMP_POS__") end)
                        pcall(function() best_angle = info:get_field("AREA_JUMP_ANGLE") end)
                        best_idx = j
                    end
                end
            end
        end
    end

    if not best_pos or not best_angle then return nil end
    log(string.format("Redirect target: SOLO idx=%d", best_idx))
    return { target_area = "s136", target_pos = best_pos, target_angle = best_angle }
end

local function fixup_s100()
    -- Both gates must be on for the redirect to apply:
    --   * ScoopSanity: in non-ScoopSanity, the EP<->SR door follows vanilla
    --     story flow (Backup for Brad cutscene opens it). DRAP shouldn't
    --     touch the s138 trigger -- the engine handles it.
    --   * AP activated: even under ScoopSanity, the redirect only makes
    --     sense after Jessie is met (which is what activates AP).
    -- Belt-and-suspenders: checking both makes the gate survive the debug
    -- `M.force_activate()` path, which sets ap_activated without going
    -- through the ScoopSanity milestone.
    local su = get_scoop_unlocker()
    local ss_on = su and su.is_scoop_sanity_enabled and su.is_scoop_sanity_enabled()
    local ap_on = su and su.is_ap_activated and su.is_ap_activated()
    if not su or not ss_on or not ap_on then
        local dr = _G.AP and _G.AP.DoorRandomizer
        if dr and dr.remove_static_redirect then
            pcall(dr.remove_static_redirect, STATIC_REDIRECT_DOOR_ID)
        end
        return true
    end

    local dr = _G.AP and _G.AP.DoorRandomizer
    if not dr or not dr.add_static_redirect then return true end

    -- Idempotent: if already registered, the callback resolves the target
    -- dynamically each crossing, so nothing to do.
    local existing = dr.get_static_redirects and dr.get_static_redirects() or {}
    if existing[STATIC_REDIRECT_DOOR_ID] then return true end

    -- Wait until AHL is loaded so resolve_redirect_target can find the entries.
    if not get_ep_ahl_layouts() then return false end

    dr.add_static_redirect(STATIC_REDIRECT_DOOR_ID, resolve_redirect_target)
    log("s100: registered EP->s138 -> s136 callback redirect (resolves at crossing)")
    return true
end

local FIXUPS = {
    SCN_s136 = fixup_s136,
    SCN_s100 = fixup_s100,
}

------------------------------------------------------------
-- Hook + frame loop
------------------------------------------------------------

local function install_load_hook()
    if hook_installed then return true end
    local td = sdk.find_type_definition("app.solid.gamemastering.AreaManager")
    if not td then log("AreaManager type missing"); return false end
    local m = td:get_method("onLoadMapEvent")
    if not m then log("onLoadMapEvent method missing"); return false end

    sdk.hook(m,
        function(args)
            local scene
            pcall(function()
                local arg = sdk.to_managed_object(args[3])
                if arg then
                    local atd = arg:get_type_definition()
                    if atd and atd:get_full_name() == "System.String" then
                        scene = arg:call("ToString")
                    end
                end
            end)
            if scene and FIXUPS[scene] then
                pending[scene] = FIXUPS[scene]
                frames_waited[scene] = 0
            end
        end,
        function(retval) return retval end)

    hook_installed = true
    return true
end

-- Watch for AP activation while already in a fixup scene -- onLoadMapEvent
-- only fires on actual transitions, so we queue fixups manually on the
-- false->true edge.
local last_ap_active = false

local function check_ap_state_transition()
    local su = get_scoop_unlocker()
    local now = (su and su.is_ap_activated and su.is_ap_activated()) and true or false
    if now and not last_ap_active then
        log("AP state transitioned to ACTIVE -- applying fixups for current scene")
        if M.apply_for_current_scene then M.apply_for_current_scene() end
    end
    last_ap_active = now
end

-- Frame budget for retry. 600 (~10s @ 60FPS) handles slow scene loads where
-- the targeted state isn't populated by the time the fixup first runs.
local MAX_FRAMES = 600

-- On give-up: log OmList type bins so the user can diagnose missing targets.
local function _dump_omlist_for_diagnosis(scene)
    local am = sdk.get_managed_singleton("app.solid.gamemastering.AreaManager")
    if not am then
        log(string.format("  diag: AreaManager unavailable at give-up (scene=%s)", scene))
        return
    end
    local cur
    pcall(function() cur = am:get_field("CurrentLevelPath") end)
    log(string.format("  diag: CurrentLevelPath=%s", tostring(cur)))
    local list
    pcall(function() list = am:get_field("OmList") end)
    if not list then log("  diag: OmList nil"); return end
    local count
    pcall(function() count = list:call("get_Count") end)
    count = tonumber(count) or 0
    log(string.format("  diag: OmList count=%d", count))
    -- Bin by type name so we don't blast pages of duplicates.
    local bins = {}
    for i = 0, math.min(count - 1, 511) do
        local om
        pcall(function() om = list:call("get_Item", i) end)
        if om then
            local td = om:get_type_definition()
            local tname = (td and td:get_full_name()) or "?"
            bins[tname] = (bins[tname] or 0) + 1
        end
    end
    for tname, n in pairs(bins) do
        log(string.format("  diag:   %dx %s", n, tname))
    end
end

local function install_frame_cb()
    if frame_cb_installed then return end
    re.on_frame(function()
        check_ap_state_transition()
        if next(pending) == nil then return end
        for scene, fn in pairs(pending) do
            frames_waited[scene] = (frames_waited[scene] or 0) + 1
            local ok, done = pcall(fn)
            if ok and done then
                pending[scene] = nil
                frames_waited[scene] = nil
            elseif frames_waited[scene] > MAX_FRAMES then
                log(string.format("Gave up on %s fixup after %d frames", scene, MAX_FRAMES))
                _dump_omlist_for_diagnosis(scene)
                pending[scene] = nil
                frames_waited[scene] = nil
            end
        end
    end)
    frame_cb_installed = true
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

-- Register all fixups + install hook + frame callback. Idempotent.
function M.register()
    if not install_load_hook() then return false end
    install_frame_cb()
    log("Registered fixups: " ..
        (function()
            local names = {}
            for k, _ in pairs(FIXUPS) do table.insert(names, k) end
            return table.concat(names, ", ")
        end)())
    return true
end

-- Manually queue all fixups against the current scene. Use after a state
-- change that would have made a fixup eligible (e.g. AP activation while
-- standing in s136), since onLoadMapEvent only fires on actual transitions.
function M.apply_for_current_scene()
    local am = sdk.get_managed_singleton("app.solid.gamemastering.AreaManager")
    if not am then return end
    local cur
    pcall(function() cur = am:get_field("CurrentLevelPath") end)
    cur = tostring(cur or "")
    if cur ~= "" and FIXUPS[cur] then
        pending[cur] = FIXUPS[cur]
        frames_waited[cur] = 0
        log("Queued fixup for current scene: " .. cur)
    end
end

-- Console shortcuts for live debugging.
_G.drap_list_s136_targets = function() return M.list_s136_targets() end
_G.drap_set_npc_target_index = function(idx) return M.set_npc_target_index(idx) end

return M
