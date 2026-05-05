-- DRAP/Notify.lua
-- Native in-game notification channel using DialogueUI.show(string, Type).
--
-- Discovered through drap_message_probe: DialogueUI.show(System.String, Type)
-- accepts arbitrary strings AND processes inline markup. The supported tags
-- are REE-style — case matters on the OPENING tag:
--
--     <color XXXXXX>...</COLOR>     6-digit RGB hex, lowercase opening
--     <BOLD>...</BOLD>              bold (uppercase opening)
--     <ITALIC>...</ITALIC>          italic
--     <SIZE n>...</SIZE>            font size
--     <GLOW>...</GLOW>              outlined glow
--     \n                            newline
--
-- The engine itself uses this for its scoop / item-receive toasts, e.g.:
--   "You obtained the <color 00FF00>Maintenance Tunnel Key</COLOR>!"
--
-- DialogueUI has 8 typed channels (Default/Voice/Radio/Cutscene/Sound/
-- Broadcast/System/ToDo) which collapse into 2 simultaneous slots
-- (dialogue + sound). ToDo is the default for DRAP notifications.
--
-- The String overload of show() does NOT honor MessageDataUnit.DisplayTime —
-- raw strings stay on screen until hide() is called. We schedule auto-hide
-- via a single re.on_frame loop.

local M = {}

-- ---------------------------------------------------------------------------
-- Colors. Hex codes are 6-digit RGB suitable for the `<color XXXXXX>` markup.
-- Sourced from AP_REF/core.lua so the in-game toast palette matches the
-- imgui Archipelago client window.
-- ---------------------------------------------------------------------------

M.Colors = {
    -- AP item-flag based
    progression = "AF99EF",   -- soft purple
    useful      = "6D8BE8",   -- blue
    filler      = "00EEEE",   -- cyan
    trap        = "FA8072",   -- salmon
    -- AP categorical
    location    = "00FF7F",   -- spring green
    entrance    = "6495ED",   -- cornflower
    -- Generic
    white       = "FFFFFF",
    red         = "FA3D2F",
    yellow      = "D9D904",
    gray        = "AAAAAA",
}

-- DialogueUI.Type enum
local CHANNELS = {
    Default = 0, Voice = 1, Radio = 2, Cutscene = 3,
    Sound = 4, Broadcast = 5, System = 6, ToDo = 7,
}
M.Channels = CHANNELS

-- AP item flag bits → category name. Matches AP_REF parse_json_msg logic.
function M.color_from_flags(flags)
    flags = tonumber(flags) or 0
    if (flags & 1) > 0 then return "progression"
    elseif (flags & 2) > 0 then return "useful"
    elseif (flags & 4) > 0 then return "trap"
    else return "filler" end
end

-- Wrap a piece of text in markup. `color` accepts either a key from M.Colors
-- or a raw 6-digit hex string. `bold` is a boolean. Returns the wrapped string.
function M.span(text, color, bold)
    local s = tostring(text or "")
    if bold then s = "<BOLD>" .. s .. "</BOLD>" end
    if color and color ~= "" then
        local hex = M.Colors[color] or color
        s = "<color " .. hex .. ">" .. s .. "</COLOR>"
    end
    return s
end

-- ---------------------------------------------------------------------------
-- DialogueUI plumbing
-- ---------------------------------------------------------------------------

local Shared = require("DRAP/Shared")
local safe = Shared.safe

local cached_dlg = nil

-- Walk the transform tree under a via.Scene root, calling fn(go, t) for
-- every GameObject. Returns the first GameObject for which fn returns
-- truthy, or nil. Pattern lifted from drap_area_probe.lua.
local function _walk_scene_for_go(scene_root, predicate)
    local first
    pcall(function() first = scene_root:call("get_FirstTransform") end)
    if not first then return nil end
    local function visit(t)
        if not t then return nil end
        local go
        pcall(function() go = t:call("get_GameObject") end)
        if go and predicate(go) then return go end
        local child
        pcall(function() child = t:call("get_Child") end)
        if child then
            local hit = visit(child)
            if hit then return hit end
        end
        local nxt
        pcall(function() nxt = t:call("get_Next") end)
        if nxt then
            local hit = visit(nxt)
            if hit then return hit end
        end
        return nil
    end
    return visit(first)
end

-- Locate the live DialogueUI controller. Cached after first non-nil read.
-- Resolution order (each falls through if the previous returns nil):
--   1. Cache hit
--   2. MessageManager.MessageUIController -- populated once any engine
--      message has fired. Will be nil if the player hasn't seen a
--      message yet this session.
--   3. via.SceneManager → MainScene → walk transforms to find a GameObject
--      named "DialogueUI_0_Default" and grab its app.solid.gui.DialogueUI
--      component. Slower but works pre-first-message.
--
-- Earlier versions tried `findGameObjectByName(System.String)` directly on
-- via.Scene, but that method doesn't exist with that signature on this
-- engine build (verified via drap_notify_check 2026-04-27 -- it returned
-- nil). The transform-tree walk replaces it.
local function get_dialog()
    if cached_dlg ~= nil then return cached_dlg end

    -- Path 2: MessageManager.MessageUIController
    local mm = sdk.get_managed_singleton("app.solid.gamemastering.MessageManager")
    if mm then
        local ctrl = safe(function() return mm:get_field("MessageUIController") end)
        if ctrl ~= nil then
            cached_dlg = ctrl
            return ctrl
        end
    end

    -- Path 3: scene-tree walk for the DialogueUI GameObject
    local sm_td = sdk.find_type_definition("via.SceneManager")
    if not sm_td then return nil end
    local sm = sdk.get_native_singleton("via.SceneManager")
               or sdk.get_managed_singleton("via.SceneManager")
    if not sm then return nil end
    local main_method = sm_td:get_method("get_MainScene")
    if not main_method then return nil end
    local main = safe(function() return main_method:call(sm) end)
    if not main then return nil end

    local DLG_TYPE = sdk.typeof("app.solid.gui.DialogueUI")
    local target_go = _walk_scene_for_go(main, function(go)
        local n
        pcall(function() n = go:call("get_Name") end)
        return n == "DialogueUI_0_Default"
    end)
    if not target_go then return nil end

    local comp = safe(function()
        return target_go:call("getComponent(System.Type)", DLG_TYPE)
    end)
    if comp then
        cached_dlg = comp
        return comp
    end
    return nil
end

-- Auto-hide scheduler. One re.on_frame loop, single shared deadline table.
local loop_installed = false
local pending_hides = {} -- channel_int → deadline (os.clock seconds)

-- Auto-hide loop registered at module load. Registering re.on_frame from
-- within another on_frame disrupts REFramework's iteration and surfaces
-- as "Unknown error in on_frame" the first time.
re.on_frame(function()
    if not next(pending_hides) then return end
    local now = os.clock()
    for typ, deadline in pairs(pending_hides) do
        if now >= deadline then
            local ui = get_dialog()
            if ui then
                pcall(function()
                    ui:call("hide(app.solid.gui.DialogueUI.Type)", typ)
                end)
            end
            pending_hides[typ] = nil
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Show free-form (already-formatted) text in a DialogueUI channel.
-- opts = {
--     duration = 4,            -- seconds before auto-hide; default 4
--     channel  = "ToDo",       -- channel name from M.Channels; default "ToDo"
-- }
-- Returns true if the call dispatched, false if no DialogueUI was available.
function M.send(text, opts)
    opts = opts or {}
    local channel_name = opts.channel or "ToDo"
    local channel = CHANNELS[channel_name] or CHANNELS.ToDo
    local duration = tonumber(opts.duration) or 4

    local ui = get_dialog()
    if not ui then
        print("[Notify] send: no DialogueUI available (no scene loaded?)")
        return false
    end

    local payload = tostring(text or "")
    pcall(function()
        ui:call("hide(app.solid.gui.DialogueUI.Type)", channel)
    end)
    local ok, err = pcall(function()
        ui:call("show(System.String, app.solid.gui.DialogueUI.Type)",
            payload, channel)
    end)
    if not ok then
        print("[Notify] show failed: err=" .. tostring(err) ..
            " channel=" .. tostring(channel) ..
            " text=" .. payload:sub(1, 80))
        return false
    end

    pending_hides[channel] = os.clock() + duration
    return true
end

-- Hide whatever is currently showing in a channel.
function M.hide(channel_name)
    local ui = get_dialog()
    if not ui then return false end
    local channel = CHANNELS[channel_name or "ToDo"] or CHANNELS.ToDo
    pcall(function() ui:call("hide(app.solid.gui.DialogueUI.Type)", channel) end)
    pending_hides[channel] = nil
    return true
end

-- AP item-received notification.
-- Matches GUI.AddReceivedItemText semantics:
--   self  → "Found your <ITEM>!"
--   other → "Received <ITEM> from <SENDER>!"
-- item_flags is the AP NetworkItem flags bitmask (1=progression, 2=useful, 4=trap).
function M.item_received(item_name, item_flags, sender_name, is_self, opts)
    local color = M.color_from_flags(item_flags)
    local item_span = M.span(item_name, color, false)
    local msg
    if is_self then
        msg = "Found your " .. item_span .. "!"
    else
        local sender_span = M.span(sender_name or "?", "white", true)
        msg = "Received " .. item_span .. " from " .. sender_span .. "!"
    end
    return M.send(msg, opts)
end

-- AP item-sent notification.
-- Matches GUI.AddSentItemText:  "<SENDER> sent <ITEM> to <RECEIVER>!"
function M.item_sent(sender_name, item_name, item_flags, receiver_name, opts)
    local color = M.color_from_flags(item_flags)
    local item_span = M.span(item_name, color, false)
    local sender_span = M.span(sender_name or "?", "white", true)
    local recv_span = M.span(receiver_name or "?", "white", true)
    local msg = sender_span .. " sent " .. item_span .. " to " .. recv_span .. "!"
    return M.send(msg, opts)
end

-- Generic categorical helpers — useful for trap activation, victory, etc.
function M.info(text, opts)    return M.send(text, opts) end
function M.warn(text, opts)
    return M.send(M.span(text, "yellow", true), opts)
end
function M.error(text, opts)
    return M.send(M.span(text, "red", true),
        { duration = (opts and opts.duration) or 6, channel = (opts and opts.channel) })
end

-- Trap-fire toast. Uses the AP trap color (salmon, FA8072) to match the
-- imgui Archipelago client window. Trap items end in "Trap" (e.g.
-- "Hostile NPC Trap"), so we render the name as-is rather than prepending
-- a redundant "Trap: " label -- the salmon color signals trap status.
--   trap_name: e.g. "Stomach Ache Trap", "Hostile NPC Trap"
--   detail:    optional sub-message (e.g. "3 attackers spawned")
function M.trap_fired(trap_name, detail, opts)
    local title = M.span(tostring(trap_name or "?"), "trap", true)
    local msg = title
    if detail and detail ~= "" then
        msg = title .. "\n" .. tostring(detail)
    end
    return M.send(msg, opts)
end

-- Diagnostic: print which DialogueUI resolution path is alive. Useful when
-- notifications aren't appearing -- run this from the REFramework console:
--     drap_notify_check()
_G.drap_notify_check = function()
    local function p(s) print("[Notify-check] " .. tostring(s)) end
    p("cached_dlg = " .. tostring(cached_dlg))

    local mm = sdk.get_managed_singleton("app.solid.gamemastering.MessageManager")
    p("MessageManager singleton = " .. tostring(mm))
    if mm then
        local ctrl
        local ok, err = pcall(function() ctrl = mm:get_field("MessageUIController") end)
        p(string.format("  ok=%s MessageUIController=%s", tostring(ok), tostring(ctrl)))
        if not ok then p("  err=" .. tostring(err)) end
    end

    local sm_td = sdk.find_type_definition("via.SceneManager")
    p("via.SceneManager type = " .. tostring(sm_td))
    if sm_td then
        local sm = sdk.get_native_singleton("via.SceneManager")
                or sdk.get_managed_singleton("via.SceneManager")
        p("  singleton = " .. tostring(sm))
        if sm then
            local main_method = sm_td:get_method("get_MainScene")
            local main
            pcall(function() main = main_method:call(sm) end)
            p("  MainScene = " .. tostring(main))
            if main then
                local first_t
                pcall(function() first_t = main:call("get_FirstTransform") end)
                p("  MainScene.FirstTransform = " .. tostring(first_t))
                local target = _walk_scene_for_go(main, function(go)
                    local n; pcall(function() n = go:call("get_Name") end)
                    return n == "DialogueUI_0_Default"
                end)
                p("  walk found 'DialogueUI_0_Default' GO = " .. tostring(target))
                if target then
                    local comp
                    pcall(function()
                        comp = target:call("getComponent(System.Type)",
                                           sdk.typeof("app.solid.gui.DialogueUI"))
                    end)
                    p("  DialogueUI component = " .. tostring(comp))
                end
            end
        end
    end

    local resolved = get_dialog()
    p("get_dialog() now returns = " .. tostring(resolved))
end

return M
