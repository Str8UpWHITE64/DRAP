-- EscortVoice.lua -- speak the delivery line the engine skips.
--
-- Survivors delivered to the Security Room through the redirected Entrance
-- Plaza door complete the escort but never say their thank-you line. Measured
-- against a working vent delivery, the whole escort machinery is IDENTICAL --
-- NpcManager, the behaviour-tree escort family, the completion camera, the
-- flags, the autosave. The only difference is one call:
--
--   MessageManager.set(messageId, list, flag)
--
-- On the vent it fires once; through the Entrance Plaza it never fires at all.
-- Everything downstream (doQueue, the queue, playMessageVoice, the subtitle)
-- already works on both routes. So this supplies that one call and nothing
-- else -- the line then plays through the game's own path.
--
-- WHY NOT FIX THE CAUSE: five candidate causes were each disproved by direct
-- test (the arg spoof, the carry-over area pair, the carry-over verdict, the
-- escort-end gate, the barricade). The engine's reason for staying quiet is
-- still unidentified; see BACKLOG. This does not paper over a broken escort --
-- the escort itself completes correctly, the check sends and PP is awarded.
--
-- SELECTION: the engine plays ONE line for a whole delivered group, chosen by
-- the LOWEST npc number. Measured over two deliveries: Jeff(05)+Natalie(02)
-- picked Natalie, and Jeff(05) -> Natalie(02) -> Bill(14) joined in that order
-- also picked Natalie -- which rules out both first-joined and last-joined.
--
-- SAFETY: if the engine did speak, this does nothing. That makes the fix
-- self-limiting -- it cannot double up on a route that already works, and it
-- needs no knowledge of which doors are redirected.

local Shared = require("DRAP/Shared")

local M = Shared.create_module("EscortVoice")

local MSG_MANAGER_TYPE = "app.solid.gamemastering.MessageManager"
local SURVIVOR_TYPE = "app.solid.SurvivorDefine.SurvivorType"

-- The Voice list byte, and the queue flag the engine uses for a delivery line.
-- Both captured from a working vent delivery: set id=405 list=18 flag=0.
local VOICE_LIST = 18
local QUEUE_FLAG = 0

-- How long to wait after a rescue before deciding the engine is not going to
-- speak. On the vent the engine's set() lands within a frame or two of the
-- rescue; this is generous enough to cover a slow frame without being long
-- enough for the player to walk away from the group.
local DECISION_DELAY = 2.0

-- Delivery lines sit at 400 + the npc number: npc02 -> 402, npc05 -> 405.
-- Treated as a HINT only -- the guid is checked before the id is used, and a
-- full scan follows if the guess is wrong. A two-point pattern is not a fact.
local ID_GUESS_BASE = 400
local SCAN_LIMIT = 8000

local msg_mgr = M:add_singleton("msg", MSG_MANAGER_TYPE)

------------------------------------------------------------
-- State
------------------------------------------------------------

local hooks_installed = false
local engine_spoke_at = nil     -- os.clock() of the engine's last Voice set()
local pending = nil             -- { stypes = {...}, started_at, due_at }

local stype_names = nil         -- SurvivorType value -> "Npc05_Jeff"
local finish_id_cache = {}      -- stype -> message id, or false if unresolvable

------------------------------------------------------------
-- Resolving a survivor's delivery line
------------------------------------------------------------

--- SurvivorType value -> enum name. The name carries the npc number in HEX
--- (Npc05_Jeff, Npc0A_Susan, Npc14_Bill) and the spoken line is named for the
--- same string, so no lookup table is needed.
local function survivor_type_name(value)
    if stype_names == nil then
        stype_names = {}
        local td = Shared.safe(function()
            return sdk.find_type_definition(SURVIVOR_TYPE)
        end)
        for _, f in ipairs(td and td:get_fields() or {}) do
            local static = Shared.safe(function() return f:is_static() end)
            local literal = Shared.safe(function() return f:is_literal() end)
            if static and literal then
                local d = Shared.safe(function() return f:get_data(nil) end)
                if d ~= nil then stype_names[tonumber(d)] = f:get_name() end
            end
        end
    end
    return value and stype_names[value] or nil
end

--- "Npc05_Jeff" -> "Voice_npc05_Finish_00", plus the npc number for ordering.
local function finish_line_name(stype)
    local nm = survivor_type_name(stype)
    if not nm then return nil end
    local hex = nm:match("^Npc(%x%x)_")
    if not hex then return nil end
    return "Voice_npc" .. hex .. "_Finish_00", tonumber(hex, 16)
end

local function guid_string_of(guid)
    if not guid then return nil end
    local s = Shared.safe(function() return tostring(guid:call("ToString")) end)
    if not s or s == "" then return nil end
    return s:lower()
end

--- The guid for a message name, via the static via.gui.message resolver.
local function guid_for_name(name)
    local td = Shared.safe(function()
        return sdk.find_type_definition("via.gui.message")
    end)
    local m = td and td:get_method("getGuidByName(System.String)")
    if not m then return nil end
    return guid_string_of(Shared.safe(function()
        return m:call(nil, name)
    end))
end

--- The message id whose guid matches, or nil.
---
--- MessageManager names messages positionally (Voice_0405) while via.gui.message
--- names them descriptively (Voice_npc05_Finish_00), and the two namespaces do
--- not overlap -- searching MessageManager names for "Finish" finds nothing.
--- getMessageGuid is the bridge between them.
local function find_id_by_guid(mgr, want, hint)
    local function guid_at(id)
        return guid_string_of(Shared.safe(function()
            return mgr:call("getMessageGuid", id, VOICE_LIST)
        end))
    end
    if hint and guid_at(hint) == want then return hint end
    for id = 0, SCAN_LIMIT do
        if id ~= hint and guid_at(id) == want then return id end
    end
    return nil
end

--- Message id for a survivor's delivery line. Cached, including failures, so a
--- survivor with no such line costs one scan and never repeats it.
local function finish_message_id(stype)
    local cached = finish_id_cache[stype]
    if cached ~= nil then return cached or nil end

    local name, npc_no = finish_line_name(stype)
    if not name then
        finish_id_cache[stype] = false
        return nil
    end
    local want = guid_for_name(name)
    if not want then
        M.log(string.format("no message named %s -- nothing to say", name))
        finish_id_cache[stype] = false
        return nil
    end
    local mgr = msg_mgr:get()
    if not mgr then return nil end     -- not cached: retry when it exists

    local id = find_id_by_guid(mgr, want, npc_no and (ID_GUESS_BASE + npc_no))
    if not id then
        M.log(string.format("%s resolved to a guid but no message id", name))
        finish_id_cache[stype] = false
        return nil
    end
    finish_id_cache[stype] = id
    M.log(string.format("%s -> id %d", name, id))
    return id
end

------------------------------------------------------------
-- Watching for the engine's own line
------------------------------------------------------------

local function install_hooks()
    if hooks_installed then return end
    local td = Shared.safe(function()
        return sdk.find_type_definition(MSG_MANAGER_TYPE)
    end)
    if not td then return end

    -- Both set overloads: the MESS_LIST one forwards to the Byte one, and both
    -- were seen firing on a working delivery. Either counts as the engine
    -- having spoken. Addresses verified unique -- see investigation/sdk/
    -- check_fold.py; hooking a folded stub here would take Wwise down.
    for _, sig in ipairs({
        "set(System.UInt32, System.Byte, app.solid.gamemastering.MessageManager.MESS_QUEUE_FLAG)",
        "set(System.UInt32, app.solid.gamemastering.MessageManager.MESS_LIST, app.solid.gamemastering.MessageManager.MESS_QUEUE_FLAG)",
    }) do
        local m = td:get_method(sig)
        if m then
            pcall(function()
                sdk.hook(m, function(args)
                    -- Field-free read only; no managed calls inside a hook.
                    local list = nil
                    pcall(function()
                        list = sdk.to_int64(args[4]) & 0xFF
                    end)
                    if list == VOICE_LIST then engine_spoke_at = os.clock() end
                end, function(retval) return retval end)
            end)
        end
    end
    hooks_installed = true
end

------------------------------------------------------------
-- Public
------------------------------------------------------------

--- Called for every rescue, from the main dispatch. Batches the group: the
--- engine speaks once for all of them, so one line is queued per delivery.
function M.on_survivor_rescued(npc_id)
    if not npc_id then return end
    install_hooks()
    local now = os.clock()
    if pending == nil then
        pending = { stypes = {}, started_at = now }
    end
    pending.stypes[#pending.stypes + 1] = npc_id
    pending.due_at = now + DECISION_DELAY
end

--- Speak for the lowest-numbered survivor of the batch, if the engine did not.
local function resolve_pending()
    local batch = pending
    pending = nil

    if engine_spoke_at and engine_spoke_at >= batch.started_at then
        return      -- the engine handled it; this route is not affected
    end

    local best, best_no = nil, nil
    for _, stype in ipairs(batch.stypes) do
        local _, npc_no = finish_line_name(stype)
        if npc_no and (best_no == nil or npc_no < best_no) then
            best, best_no = stype, npc_no
        end
    end
    if not best then return end

    local id = finish_message_id(best)
    if not id then return end

    local mgr = msg_mgr:get()
    if not mgr then return end
    -- Called from the frame thread. The same call from elsewhere reports
    -- success and is silent.
    local ok = pcall(function()
        mgr:call("set(System.UInt32, System.Byte, app.solid.gamemastering.MessageManager.MESS_QUEUE_FLAG)",
            id, VOICE_LIST, QUEUE_FLAG)
    end)
    M.log(string.format("engine stayed quiet on delivery -- spoke for %s (id %d)%s",
        tostring(survivor_type_name(best)), id, ok and "" or " FAILED"))
end

function M.on_frame()
    install_hooks()
    if pending and os.clock() >= (pending.due_at or 0) then
        resolve_pending()
    end
end

--- Testing: force the line for one survivor type, ignoring the engine check.
_G.drap_escort_voice_test = function(stype)
    stype = tonumber(stype)
    if not stype then
        M.log("usage: drap_escort_voice_test(<SurvivorType value>)")
        return
    end
    pending = { stypes = { stype }, started_at = os.clock(), due_at = 0 }
    engine_spoke_at = nil
    M.log(string.format("queued a delivery line for %s",
        tostring(survivor_type_name(stype))))
end

return M
