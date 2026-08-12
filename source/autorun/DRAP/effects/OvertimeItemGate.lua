-- DRAP/effects/OvertimeItemGate.lua
-- The player may reach for a suppressant before the multiworld has sent it.
-- The reach counts -- it sends the check -- but the pickup does not happen, so
-- the item is never collected and Overtime cannot be finished early.
--
-- Blocking the pickup rather than the hand-in is what makes this reliable.
-- Nothing the game consults when the player HAS an item could be found: not
-- the ToDo messages, not the key/telop/SCQ flags, not SolidSave, not the
-- visible inventory. An item never picked up sidesteps all of it.
--
-- Identities come from the game's own EventSetCookingEquipment.CookInfos,
-- recorded in drdr_shared.json as overtime_items.

local Shared = require("DRAP/Shared")
local SharedData = require("DRAP/SharedData")
local Activation = require("DRAP/Activation")
local ItemEffects = require("DRAP/ItemEffects")
local ScoopState = require("DRAP/scoops/ScoopState")

local M = Shared.create_module("OvertimeItemGate")

local PIM_TYPE = "app.solid.PlayerInteractionManager"
-- The component that offers the pickup and draws its icon. Clearing the
-- interaction hides the prompt but leaves the icon floating, because the
-- icon belongs to the object rather than to the interaction.
local KEY_ITEM_HANDLER = "solid.MT2RE.KeyItemHandler"

-- Off until a slot turns it on. A mistake here suppresses interactions, which
-- is far more visible than a wrong flag.
local enabled = false
-- Whether anything is actually held back. Separate from `enabled` because the
-- module still has to send the eight "Find the ..." checks with the gating
-- off; only the blocking is optional. Overtime Progression Gating sets it.
local gating = false
-- Log what it would block without blocking it.
local dry_run = false
-- Turning it on from the console is a deliberate act, so it stands in for the
-- slot connect the automatic path waits on. Without this the gate is untestable
-- offline, which is exactly where it gets tested.
local console_override = false
-- Log every DoInteraction, matched or not. Silence is ambiguous: the hook
-- may not be firing, or may be firing on a name we do not recognise.
local verbose = false
-- Say why nothing happened, once per reason.
local said = {}

-- Nothing here may touch the game before Overtime. There are two First Aid
-- Kits: one for Medicine Run in the main game and one for the suppressants.
-- They share the class name uOm21c, so the pickup block applied to Medicine
-- Run's kit as well -- it sat there and could not be taken, and Jessie would
-- not accept the one already held, with no way back. Reported 2026-08-11 from
-- a run where the item arrived 80 minutes before Overtime began.
--
-- "Get bit!" sets endgame, which is persisted, and the event reaches
-- ScoopUnlocker in every mode rather than only under ScoopSanity.
local overtime_override = false

local function in_overtime()
    if overtime_override then return true end
    local ok, v = pcall(ScoopState.is_endgame_reached)
    return ok and v == true
end

local function say_once(key, msg)
    if said[key] then return end
    said[key] = true
    M.log(msg)
end

local ITEMS = {}          -- class_name -> { name = ..., get_flag = ... }
local sent = {}           -- item name -> check already sent this session
local granted = {}        -- item name -> received (console override for testing)
local hook_installed = false
local muted = {}          -- object name -> handler we switched off
local sign_hooked = false
-- Guids seen on SignBoardUI while an item was muted. The pickup icon is a
-- SignBoard element, so its message Guid is what has to be suppressed --
-- DoorPromptOverlay reads the same field to spot door prompts.
local ICON_GUIDS = {}
local learning_until = 0
local sign_ui = nil       -- the live SignBoardUI, captured from its own hook
local pending_del = {}    -- element index -> true, deleted on the next frame

------------------------------------------------------------
-- The Cave
------------------------------------------------------------
-- Handing over the fifth queen opens a yes/no box, and Yes leaves for the
-- Cave. Every way of suppressing that box left Isabela unresponsive: its
-- callback tidies the conversation up as well as starting the cutscene. So the
-- callback still runs -- with ForceCancel set first, which makes it take the
-- No branch. Both buttons then read as No and she stays normal.
local CAVE_ITEM = "Cave Key"
local POP_TYPE = "app.solid.gui.PopUI_Base"
-- Identifies her prompt, so no other dialog in the game is touched.
local POP_MATCH = "absolutely sure"
local pop_hooked = false
local pop_is_target = false

-- Getting into the Humvee is what starts the tank fight, so the key gates the
-- whole tail of the run.
--
-- It is an interaction point rather than a rideable vehicle, so it is named
-- like a door or an NPC prompt, not like a car -- and it is not in the dump
-- under any spelling of Humvee. The real name has to be read from a live
-- session, so the gate logs every interaction it sees down here and
-- drap_humvee_name() sets the match without a redeploy.
--
-- If hitting "Get in" logs nothing at all, then it does not go through
-- DoInteraction and this is the wrong hook -- which is the useful answer.
local HUMVEE_ITEM = "Humvee Key"
-- Vehicle_om009a_Hammer_EV, read from the interaction list in game. Hammer as
-- in HMMWV, which also explains sb03's EV_B03_SET_HAMMER.
local humvee_patterns = { "hammer" }
local humvee_seen = {}

-- Told by proximity rather than by the interaction, the same way the Door
-- Locks overlay names a locked door. The interaction is a bad trigger here:
-- the gate clears it every frame, so it drops out and returns constantly.
-- Position is steady, so a plain enter/exit edge works and the player is told
-- once each time they walk up.
--
-- Read with drap_player_pos() standing at the Humvee.
local HUMVEE_SCENE = "sb02"
local HUMVEE_POS = { x = -0.799, y = -51.948, z = -419.491 }
local HUMVEE_RADIUS_SQ = 8.0 * 8.0      -- DoorPromptOverlay.ANCHOR_RADIUS_SQ
local near_humvee = false

local function build_items()
    ITEMS = {}
    local n = 0
    for _, e in ipairs(SharedData.overtime_items()) do
        if e.class_name and e.name then
            ITEMS[e.class_name] = {
                name = e.name,
                get_flag = e.get_flag,
                pickup_flags = e.pickup_flags or { e.get_flag },
            }
            n = n + 1
        end
    end
    return n
end

--- Receiving the item hands it over outright: setting the flags the pickup
--- would have set puts it in Key Items and despawns the world object, so the
--- player never walks back for something they already own.

------------------------------------------------------------
-- Identity
------------------------------------------------------------

--- Scene objects are named "PREF_" .. class_name, sometimes with an instance
--- suffix ("PREF_uOm10a_117"). Matching on the class plus an optional "_N"
--- keeps the decorative uOm222 blenders from matching the quest uOm222_1_1.
local function item_for(go_name)
    if not go_name then return nil end
    local bare = tostring(go_name):gsub("^PREF_", "")
    local exact = ITEMS[bare]
    if exact then return exact end
    for class_name, item in pairs(ITEMS) do
        if bare:sub(1, #class_name + 1) == class_name .. "_" then
            return item
        end
    end
    return nil
end

local function has_received(name)
    if granted[name] then return true end
    local bridge = AP and AP.AP_BRIDGE
    if not (bridge and bridge.has_item_name) then return false end
    local ok, v = pcall(bridge.has_item_name, name)
    return ok and v == true
end

--- RegisterInteraction is handed the interaction being offered. We do not
--- know which argument, so try each and take the first that yields a
--- gameObject name.
local function name_from_args(args)
    for i = 3, 6 do
        local a = args[i]
        if a ~= nil then
            local obj
            pcall(function() obj = sdk.to_managed_object(a) end)
            if obj then
                local go
                pcall(function() go = obj:get_field("gameObject") end)
                if not go then
                    pcall(function() go = obj:call("get_gameObject") end)
                end
                if go then
                    local name
                    pcall(function() name = go:call("get_Name") end)
                    if name then return tostring(name), i end
                end
                -- The argument may itself be the GameObject.
                local name
                pcall(function() name = obj:call("get_Name") end)
                if name then return tostring(name), i end
            end
        end
    end
    return nil
end

local function current_object_name(pim)
    -- Deliberately not gated on get_HasInteraction: the manager may clear it
    -- before the interaction body runs, and then the name is gone.
    local cur
    pcall(function() cur = pim:call("get_CurrentInteraction") end)
    if not cur then
        pcall(function() cur = pim:get_field("<CurrentInteraction>k__BackingField") end)
    end
    if not cur then return nil end
    local go
    pcall(function() go = cur:get_field("gameObject") end)
    if not go then return nil end
    local name
    pcall(function() name = go:call("get_Name") end)
    return name
end

------------------------------------------------------------
-- The gate
------------------------------------------------------------

--- Read from CurrentLevelPath rather than the area index, so it answers for
--- scenes we have no index for.
local function current_scene_code()
    local am = sdk.get_managed_singleton("app.solid.gamemastering.AreaManager")
    if not am then return nil end
    local path
    pcall(function() path = am:get_field("CurrentLevelPath") end)
    if not path then return nil end
    local code = tostring(path)
    if code == "" then return nil end
    return (code:gsub("^SCN_", ""))
end

--- True when the named object looks like the Humvee.
local function is_humvee(go_name)
    local lower = tostring(go_name):lower()
    for _, pat in ipairs(humvee_patterns) do
        if lower:find(pat, 1, true) then return true end
    end
    return false
end

--- Names every interactable in a Cave scene, once each. This is how the
--- Humvee was identified as Vehicle_om009a_Hammer_EV, and it is the tool to
--- reach for if a patch renames it and the gate stops holding.
local function note_cave_interaction(go_name)
    if humvee_seen[go_name] then return end
    humvee_seen[go_name] = true
    M.log("interaction seen in the Cave: " .. tostring(go_name)
        .. (is_humvee(go_name) and "  <- matches the Humvee patterns" or ""))
end

--- @return boolean true when the pickup should be suppressed
local function should_block(pim)
    if not enabled then return false end
    -- uOm21c is both First Aid Kits. Holding it outside Overtime blocks
    -- Medicine Run, which is what the soft lock report was.
    if not in_overtime() then return false end

    local go_name = current_object_name(pim)
    if verbose then
        M.log(string.format("DoInteraction -> %s (%s)", tostring(go_name),
            go_name and (item_for(go_name) and "KNOWN" or "not ours") or "no name"))
    end
    if not go_name then return false end

    -- Confined to the Cave, and that is load bearing rather than tidiness:
    -- the patterns are broad guesses, and "car" would otherwise match the
    -- convicts' vehicle and the cars in Leisure Park. The Overtime Humvee only
    -- exists here, so nothing outside can be caught by a wrong guess.
    local scene = Shared.SCENE_INFO[current_scene_code() or ""]
    local in_cave = scene ~= nil
                    and tostring(scene.name):find("Cave", 1, true) ~= nil
    if in_cave then
        -- Few interactables down here, so naming them all is cheap and is how
        -- the Humvee's real name gets found.
        note_cave_interaction(go_name)
    end

    -- Ingredients are no longer held: their checks come from the pickup
    -- flags. Only the Cave and the Humvee gate anything now, and both are
    -- handled elsewhere.
    return false
end

local function cave_blocked()
    if not (enabled and gating and in_overtime()) then return false end
    if not (Activation.is_active() or console_override) then return false end
    return not has_received(CAVE_ITEM)
end

local function install_cave_hooks()
    if pop_hooked then return end
    local td = sdk.find_type_definition(POP_TYPE)
    if not td then return end
    local open_m = td:get_method("openPop")
    local invoke_m = td:get_method("invokeCallbackOnClose")
    if not (open_m and invoke_m) then
        M.log.warn("PopUI_Base methods missing -- the Cave is not gated")
        pop_hooked = true
        return
    end

    local ok_open = pcall(sdk.hook, open_m,
        function(args)
            pop_is_target = false
            if not cave_blocked() then return end
            local data
            pcall(function() data = sdk.to_managed_object(args[3]) end)
            if not data then return end
            local msg
            pcall(function() msg = data:get_field("Message") end)
            if not msg then return end
            pop_is_target = tostring(msg):lower():find(POP_MATCH, 1, true) ~= nil
        end,
        function(retval) return retval end)

    local ok_invoke = pcall(sdk.hook, invoke_m,
        function(args)
            if not pop_is_target then return end
            pop_is_target = false
            -- Re-checked here as well as at openPop: the key can land while
            -- the box is up, and there is no reason to refuse it then.
            if not cave_blocked() then return end
            local this = sdk.to_managed_object(args[2])
            if not this then return end
            pcall(function() this:set_field("ForceCancel", true) end)
            M.log("Cave departure declined -- no " .. CAVE_ITEM)

            -- Every time, not once: answering Yes and going nowhere reads as a
            -- bug, and the player may well try again an hour later.
            local Notify = package.loaded["DRAP/Notify"] or require("DRAP/Notify")
            if Notify and Notify.send then
                pcall(Notify.send,
                    "Isabela will not leave without the " .. CAVE_ITEM .. ".",
                    { duration = 6.0 })
            end
        end,
        function(retval) return retval end)

    pop_hooked = true
    if ok_open and ok_invoke then
        M.log("Cave gate armed on " .. POP_TYPE)
    else
        M.log.warn("could not hook PopUI_Base -- the Cave is not gated")
    end
end

local function install_hook()
    if hook_installed then return end
    local td = sdk.find_type_definition(PIM_TYPE)
    if not td then return end
    local m = td:get_method("DoInteraction")
    if not m then
        M.log.warn("DoInteraction not found -- gate inactive")
        hook_installed = true      -- do not retry every frame
        return
    end

    local ok = pcall(sdk.hook, m,
        function(args)
            if not enabled then return end
            local pim = sdk.to_managed_object(args[2])
            if not pim then return end
            local blocked = false
            local ok_call, res = pcall(should_block, pim)
            if ok_call then blocked = res end
            if blocked then return sdk.PreHookResult.SKIP_ORIGINAL end
        end,
        function(retval) return retval end)

    hook_installed = true
    if ok then
        M.log("DoInteraction hooked")
    else
        M.log.warn("could not hook DoInteraction -- gate inactive")
    end
end

local register_hooked = false

--- Once the check is sent the prompt has no purpose, so stop registering the
--- interaction. The item stays visible; Frank simply will not reach for it.
local function install_register_hook()
    if register_hooked then return end
    local td = sdk.find_type_definition(PIM_TYPE)
    if not td then return end
    local m = td:get_method("RegisterInteraction")
    if not m then
        M.log.warn("RegisterInteraction not found -- the prompt will keep showing")
        register_hooked = true
        return
    end

    local ok = pcall(sdk.hook, m,
        function(args)
            if not enabled then return end
            if not (Activation.is_active() or console_override) then return end

            local go_name, idx = name_from_args(args)
            if not go_name then return end
            local item = item_for(go_name)
            if not item then return end
            if has_received(item.name) then return end
            if not sent[item.name] then return end   -- let them reach for it once

            if verbose then
                say_once("hide:" .. item.name, string.format(
                    "hiding the %s prompt (arg %d) -- check already sent",
                    item.name, idx or -1))
            end
            if dry_run then return end
            return sdk.PreHookResult.SKIP_ORIGINAL
        end,
        function(retval) return retval end)

    register_hooked = true
    if ok then
        M.log("RegisterInteraction hooked -- prompts hide once their check is sent")
    else
        M.log.warn("could not hook RegisterInteraction")
    end
end

--- Suppress the pickup icon. Learns its Guid the first time an item is muted,
--- then refuses that element for as long as anything is muted.
local function install_sign_hook()
    if sign_hooked then return end
    local td = sdk.find_type_definition("app.solid.gui.SignBoardUI")
    if not td then return end

    -- The 2-param overload is the one that carries (index, Element).
    local m
    for _, method in ipairs(td:get_methods() or {}) do
        if method:get_name() == "setElement" then
            local np = 0
            pcall(function() np = method:get_num_params() end)
            if np == 2 then m = method; break end
        end
    end
    if not m then
        M.log.warn("setElement(2 params) not found -- the icon will stay")
        sign_hooked = true
        return
    end

    local ok = pcall(sdk.hook, m,
        function(args)
            if not enabled then return end
            if not next(muted) then return end

            local elem
            pcall(function() elem = sdk.to_managed_object(args[4]) end)
            if not elem then return end
            local guid
            pcall(function() guid = elem:get_field("mMessageId") end)
            if not guid then return end
            local key
            pcall(function() key = tostring(guid:call("ToString")) end)
            if not key then return end

            if ICON_GUIDS[key] then
                if dry_run then return end
                -- Refusing setElement stops it being redrawn, but an element
                -- already on screen has to be removed: delElement(index).
                local idx
                pcall(function() idx = sdk.to_int64(args[3]) & 0xFFFFFFFF end)
                if idx then pending_del[idx] = true end
                pcall(function() sign_ui = sdk.to_managed_object(args[2]) end)
                return sdk.PreHookResult.SKIP_ORIGINAL
            end

            -- Anything drawn while an item is muted is a candidate: the player
            -- is standing at a held pickup, so this is its prompt.
            if os.clock() < learning_until then
                ICON_GUIDS[key] = true
                pcall(function() sign_ui = sdk.to_managed_object(args[2]) end)
                local idx
                pcall(function() idx = sdk.to_int64(args[3]) & 0xFFFFFFFF end)
                if idx then pending_del[idx] = true end
                M.log(string.format("icon Guid learned: %s (element %s)",
                    key, tostring(idx)))
            end
        end,
        function(retval) return retval end)

    sign_hooked = true
    if ok then
        M.log("SignBoardUI.setElement hooked -- pickup icons suppressed once learned")
    else
        M.log.warn("could not hook setElement")
    end
end



function M.register()
    -- Nothing to register: the ingredients are not items. ITEMS is still
    -- built because the flag poll below needs their pickup flags.
    local n = build_items()
    M.log(string.format("%d Overtime ingredient(s) tracked for checks", n))
end

--- RegisterInteraction only fires as an object comes into range, so skipping
--- it does nothing for one already registered -- which is always the case by
--- the time the player has pressed the button. Clearing the current
--- interaction each frame is what actually takes the prompt away.
local function suppress_current()
    if not in_overtime() then return end
    local pim = sdk.get_managed_singleton(PIM_TYPE)
    if not pim then return end
    local go_name = current_object_name(pim)
    if not go_name then return end

    -- The Humvee is in the interaction list but activating it never reaches
    -- DoInteraction, so there is no call to refuse. Clearing it every frame
    -- means there is nothing current to activate when the button is pressed.
    if is_humvee(go_name) then
        if not gating then return end
        if not (Activation.is_active() or console_override) then return end
        if has_received(HUMVEE_ITEM) then return end
        if dry_run then
            say_once("wouldhold:humvee", "would hold the Humvee (" .. go_name .. ")")
            return
        end
        pcall(function() pim:call("clearCurrentInteraction") end)
        say_once("hold:humvee",
            "holding the Humvee (" .. go_name .. ") -- no " .. HUMVEE_ITEM)
        return
    end

    if not gating then return end

    local item = item_for(go_name)
    if not item then return end
    if has_received(item.name) then return end
    if not sent[item.name] then return end      -- the first reach must land

    if dry_run then
        say_once("wouldhide:" .. item.name,
            "would hide the " .. item.name .. " prompt")
        return
    end

    -- Switch off the object's own handler: that takes the icon with it.
    -- Clearing the interaction only hides the prompt.
    if not muted[go_name] then
        local cur
        pcall(function() cur = pim:call("get_CurrentInteraction") end)
        local go
        if cur then pcall(function() go = cur:get_field("gameObject") end) end
        if go then
            local handler
            pcall(function()
                handler = go:call("getComponent(System.Type)",
                                  sdk.typeof(KEY_ITEM_HANDLER))
            end)
            if handler then
                local ok = pcall(function() handler:call("set_Enabled", false) end)
                if ok then
                    muted[go_name] = handler
                    -- Watch the next second of SignBoard traffic: whatever it
                    -- draws now is this item's prompt.
                    learning_until = os.clock() + 1.0
                    M.log(string.format(
                        "muted %s -- learning its icon Guid", item.name))
                else
                    M.log.warn("could not disable the handler on " .. go_name)
                end
            else
                say_once("nohandler:" .. go_name,
                    "no KeyItemHandler on " .. go_name .. " -- falling back to clearing")
            end
        end
    end

    pcall(function() pim:call("clearCurrentInteraction") end)
    say_once("hide:" .. item.name,
        "hiding the " .. item.name .. " prompt -- its check is already sent")
end

--- Give an object its handler back, so a granted item can be taken normally.
local function unmute(go_name)
    local handler = muted[go_name]
    if not handler then return end
    pcall(function() handler:call("set_Enabled", true) end)
    muted[go_name] = nil
    M.log("unmuted " .. tostring(go_name))
end

--- The prompt is held, so without this the Humvee reads as scenery and the
--- player has no idea what they are missing.
local function check_humvee_proximity()
    if not (gating and in_overtime()) then near_humvee = false; return end
    if has_received(HUMVEE_ITEM) then near_humvee = false; return end
    if current_scene_code() ~= HUMVEE_SCENE then near_humvee = false; return end

    local pm = sdk.get_managed_singleton("app.solid.PlayerManager")
    if not pm then return end
    local cond
    pcall(function() cond = pm:call("get_CurrentPlayerCondition") end)
    if not cond then return end
    local pos
    pcall(function() pos = cond:get_field("LastPlayerPos") end)
    if not pos then return end

    local dx, dy, dz
    pcall(function()
        dx, dy, dz = pos.x - HUMVEE_POS.x, pos.y - HUMVEE_POS.y, pos.z - HUMVEE_POS.z
    end)
    if not dx then return end

    local inside = (dx * dx + dy * dy + dz * dz) <= HUMVEE_RADIUS_SQ
    if inside == near_humvee then return end
    near_humvee = inside
    if not inside then return end

    local Notify = package.loaded["DRAP/Notify"] or require("DRAP/Notify")
    if Notify and Notify.send then
        pcall(Notify.send,
            "You need the " .. HUMVEE_ITEM .. " to drive the Humvee.",
            { duration = 6.0 })
    end
    M.log("player reached the Humvee without the " .. HUMVEE_ITEM)
end

--- The only way an ingredient check is sent. Reading the pickup flags rather
--- than hooking the grab also catches one collected before the player ever
--- connected, the same way the convict flags work. Nothing sets these flags on
--- the player's behalf any more, so a check cannot be handed to someone who
--- never went looking.
local flag_poll_at = 0

local function poll_pickup_flags()
    local now = os.clock()
    if now - flag_poll_at < 2.0 then return end
    flag_poll_at = now

    local efm = sdk.get_managed_singleton("app.solid.gamemastering.EventFlagsManager")
    if not efm then return end

    for _, item in pairs(ITEMS) do
        if not sent[item.name] then
            for _, flag in ipairs(item.pickup_flags or {}) do
                local ok, on = pcall(function() return efm:call("evFlagCheck", flag) end)
                if ok and on == true then
                    sent[item.name] = true
                    local bridge = AP and AP.AP_BRIDGE
                    if bridge and bridge.check then
                        pcall(bridge.check, "Find the " .. item.name)
                    end
                    M.log(string.format("%s already collected (flag %d) -- check sent",
                        item.name, flag))
                    break
                end
            end
        end
    end
end

function M.on_frame()
    if not enabled then return end
    if not hook_installed then install_hook() end
    if not register_hooked then install_register_hook() end
    if not sign_hooked then install_sign_hook() end
    if not pop_hooked then install_cave_hooks() end

    -- Remove any element we refused. Done here rather than inside the hook so
    -- we are not calling back into the UI mid-update.
    if sign_ui and next(pending_del) then
        for idx in pairs(pending_del) do
            pcall(function() sign_ui:call("delElement", idx) end)
            pending_del[idx] = nil
        end
    end
    if not (Activation.is_active() or console_override) then return end
    pcall(suppress_current)
    pcall(check_humvee_proximity)
    pcall(poll_pickup_flags)
end

-- Own loop rather than the main one. The console override has to work while
-- dormant, and the main loop skips this module entirely until a slot connects
-- -- which is exactly where the gate gets tested. Registered here means one
-- tick per frame in both cases.
re.on_frame(function()
    if not enabled then return end
    pcall(M.on_frame)
end)

--- @param on boolean
--- @param on boolean Ending S, so the module runs at all
--- @param gate boolean|nil Overtime Progression Gating; nil keeps the current
---   value, so the console toggle does not silently turn gating on
function M.set_enabled(on, from_console, gate)
    enabled = on == true
    if gate ~= nil then gating = gate == true end
    if from_console then console_override = enabled end
    said = {}
    if enabled then
        install_hook(); install_register_hook(); install_sign_hook()
        install_cave_hooks()
    end
    M.log(string.format("gate %s, gating %s%s",
        enabled and "ON" or "off (not Ending S)",
        gating and "ON" or "off (checks only, nothing held)",
        console_override and " (console override -- ignores the slot gate)" or ""))
end

function M.is_gating() return gating end

function M.set_gating(on)
    gating = on == true
    M.log("gating " .. (gating and "ON" or "off -- nothing will be held"))
    return gating
end

function M.is_enabled() return enabled end

------------------------------------------------------------
-- Console
------------------------------------------------------------

_G.drap_ot_gate = function(on)
    if on == nil then on = not enabled end
    M.set_enabled(on, true)
end

--- Forces the Overtime check, for testing the gate before Get bit!.
_G.drap_ot_overtime = function(on)
    overtime_override = (on ~= false)
    M.log("Overtime override " .. (overtime_override and "ON" or "off")
        .. " (real state: " .. tostring(select(2, pcall(ScoopState.is_endgame_reached))) .. ")")
    return overtime_override
end

--- drap_ot_gating(true) -- stands in for Overtime Progression Gating being on
_G.drap_ot_gating = function(on)
    if on == nil then on = not M.is_gating() end
    return M.set_gating(on)
end

_G.drap_ot_gate_verbose = function(on)
    if on == nil then on = not verbose end
    verbose = on == true
    M.log("verbose " .. (verbose and "ON -- every DoInteraction is logged" or "off"))
end

_G.drap_ot_gate_dry = function(on)
    if on == nil then on = not dry_run end
    dry_run = on == true
    M.log("dry run " .. (dry_run and "ON -- logging only, nothing blocked"
                                  or "off -- pickups are held"))
end

--- Pretend the multiworld sent one, so the gate can be tested without a slot.
--- Stands in for a slot sending the item, so the gates can be tested with no
--- server. Any name works, including "Cave Key" and "Humvee Key", which are
--- pure gate items with nothing to unlock in the world.
---
---   drap_ot_gate_grant("Humvee Key")         -- receive it
---   drap_ot_gate_grant("Humvee Key", false)  -- take it back and re-test
_G.drap_ot_gate_grant = function(name, on)
    if not name then
        M.log("usage: drap_ot_gate_grant(\"Cave Key\" [, false])")
        return
    end
    name = tostring(name)

    if on == false then
        granted[name] = nil
        M.log("revoked " .. name)
        return
    end

    granted[name] = true
    -- Anything muted for this item has to be takeable again.
    for go_name, _ in pairs(muted) do
        local item = item_for(go_name)
        if item and item.name == name then unmute(go_name) end
    end
    M.log("granted " .. name)
end

_G.drap_ot_gate_icons = function()
    local n = 0
    for guid in pairs(ICON_GUIDS) do n = n + 1; M.log("  " .. guid) end
    M.log(string.format("  %d icon Guid(s) learned, signboard=%s",
        n, tostring(sign_ui ~= nil)))
end

--- Forget the learned Guids, e.g. after catching a neighbouring prompt.
_G.drap_ot_gate_icons_reset = function()
    ICON_GUIDS = {}
    M.log("learned icon Guids cleared")
end

_G.drap_ot_gate_unmute_all = function()
    for go_name, _ in pairs(muted) do unmute(go_name) end
    M.log("all handlers restored")
end

--- drap_humvee_name("PREF_uOm231")  -- once the real name is known
--- drap_humvee_name()               -- show what is being matched
_G.drap_humvee_name = function(name)
    -- Nothing is hooked while the gate is off, so the discovery log stays
    -- silent and looks like the Humvee simply is not an interaction. Say so.
    if not enabled then
        M.log.warn("the gate is off -- run drap_ot_gate(true) first, "
            .. "or nothing is hooked and no interaction can be seen")
    end
    if name == nil then
        M.log("Humvee patterns: " .. table.concat(humvee_patterns, ", "))
        return humvee_patterns
    end
    humvee_patterns = { tostring(name):lower() }
    M.log("Humvee now matched on '" .. tostring(name):lower() .. "'")
    return humvee_patterns
end

_G.drap_ot_cave = function()
    M.log(string.format("Cave: blocked=%s  %s received=%s  hooked=%s",
        tostring(cave_blocked()), CAVE_ITEM,
        tostring(has_received(CAVE_ITEM)), tostring(pop_hooked)))
end

_G.drap_ot_gate_status = function()
    M.log(string.format(
        "enabled=%s dry_run=%s do_hook=%s reg_hook=%s active=%s override=%s",
        tostring(enabled), tostring(dry_run), tostring(hook_installed),
        tostring(register_hooked), tostring(Activation.is_active()),
        tostring(console_override)))
    for class_name, item in pairs(ITEMS) do
        M.log(string.format("  %-12s %-20s received=%s check_sent=%s",
            class_name, item.name, tostring(has_received(item.name)),
            tostring(sent[item.name] == true)))
    end
    M.log(string.format("  in Overtime: %s%s", tostring(in_overtime()),
        overtime_override and " (forced)" or ""))
end

return M
