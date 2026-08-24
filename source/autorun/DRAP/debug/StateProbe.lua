-- DRAP/debug/StateProbe.lua
-- Read what the game actually stores, rather than inferring it from what moves.
--
-- A flag trace only shows transitions, so anything held as a counter, an array
-- or an object field is invisible to it. Chasing the Overtime suppressants
-- through flags cost four wrong hypotheses before this existed.
--
--   drap_save_fields()            every SolidSave field, with values
--   drap_save_snapshot() / _diff() what changed across an action
--   drap_obj(type[, path])        walk any managed singleton
--   drap_obj_methods(type[, filt]) find the method worth hooking

local Shared = require("DRAP/Shared")

local M = Shared.create_module("StateProbe")

local ss_mgr = M:add_singleton("ss", "app.solid.SolidStorage")

local snapshot = nil

-- Arrays are read element-wise into one string so a diff can name the index
-- that moved.
local MAX_ELEMS = 512

local function encode(v)
    local n = tonumber(v)
    if n then return tostring(n) end
    if type(v) == "boolean" then return tostring(v) end
    if type(v) ~= "userdata" then return nil end

    local count
    pcall(function() count = v:call("get_Length") end)
    if count == nil then pcall(function() count = v:call("get_Count") end) end
    count = tonumber(count)
    if not count or count <= 0 then return nil end

    local parts = {}
    for i = 0, math.min(count, MAX_ELEMS) - 1 do
        local e
        pcall(function() e = v:call("get_Item", i) end)
        parts[#parts + 1] = tostring(tonumber(e) or "?")
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

local function array_delta(was, now)
    if not was or not now then return "" end
    if was:sub(1, 1) ~= "[" then return "" end
    local a, b, out = {}, {}, {}
    for x in was:gmatch("[^%[%],]+") do a[#a + 1] = x end
    for x in now:gmatch("[^%[%],]+") do b[#b + 1] = x end
    for i = 1, math.max(#a, #b) do
        if a[i] ~= b[i] then
            out[#out + 1] = string.format("[%d] %s->%s", i - 1,
                tostring(a[i]), tostring(b[i]))
        end
    end
    return table.concat(out, "  ")
end

------------------------------------------------------------
-- Any object
------------------------------------------------------------

--- Follow a dotted field path, e.g.
--- "InteractionData.<CurrentInteraction>k__BackingField"
local function index_into(obj, i)
    local v
    pcall(function() v = obj:call("get_Item", i) end)
    if v == nil then
        -- Lists keep their storage in _items; arrays answer get_Item directly.
        local backing
        pcall(function() backing = obj:get_field("_items") end)
        if backing then pcall(function() v = backing:call("get_Item", i) end) end
    end
    return v
end

local function walk(obj, path)
    if not path or path == "" then return obj end
    for part in tostring(path):gmatch("[^%.]+") do
        if not obj then return nil, part end
        local name, idx = part:match("^(.-)%[(%d+)%]$")
        local key = name or part
        local nxt
        if key ~= "" then
            pcall(function() nxt = obj:get_field(key) end)
            if nxt == nil then
                -- Properties are often only reachable through their getter.
                pcall(function() nxt = obj:call("get_" .. key) end)
            end
        else
            nxt = obj
        end
        if nxt ~= nil and idx then nxt = index_into(nxt, tonumber(idx)) end
        if nxt == nil then return nil, part end
        obj = nxt
    end
    return obj
end

local function collection_count(obj)
    local n
    pcall(function() n = obj:call("get_Count") end)
    if n == nil then pcall(function() n = obj:call("get_Length") end) end
    if n == nil then pcall(function() n = obj:get_field("_size") end) end
    return tonumber(n)
end

local function dump_object(obj, label)
    local ok_td, td = pcall(obj.get_type_definition, obj)
    if not ok_td or not td then M.log("  " .. label .. ": no type"); return end
    M.log(string.format("=== %s : %s", label, td:get_full_name() or "?"))
    local n = 0
    for _, field in ipairs(Shared.get_fields_array(td)) do
        local name, ftype
        pcall(function() name = field:get_name() end)
        pcall(function() ftype = field:get_type():get_full_name() end)
        if name then
            n = n + 1
            local ok, v = pcall(field.get_data, field, obj)
            local enc = ok and encode(v) or nil
            if enc == nil and ok and v ~= nil then enc = tostring(v) end
            if enc and #enc > 70 then enc = enc:sub(1, 70) .. "..." end
            M.log(string.format("  %-42s %-32s %s", name,
                ftype or "?", enc or "(unreadable)"))
        end
    end
    M.log(string.format("  %d field(s)", n))
end

--- @param type_name string a managed singleton
--- @param path string|nil dotted field path to follow first
function M.obj(type_name, path)
    local root = sdk.get_managed_singleton(tostring(type_name))
    if not root then M.log("singleton not found: " .. tostring(type_name)); return end
    local target, missing = walk(root, path)
    if not target then
        M.log(string.format("path stopped at '%s'", tostring(missing)))
        dump_object(root, tostring(type_name))
        return
    end
    dump_object(target, tostring(type_name) .. (path and ("." .. path) or ""))
end

--- @param filter string|nil substring, case-insensitive
function M.methods(type_name, filter)
    local td = sdk.find_type_definition(tostring(type_name))
    if not td then M.log("type not found: " .. tostring(type_name)); return end
    local needle = tostring(filter or ""):lower()
    local n = 0
    local ok, methods = pcall(td.get_methods, td)
    if not ok or not methods then M.log("  no methods"); return end
    for _, m in ipairs(methods) do
        local name
        pcall(function() name = m:get_name() end)
        if name and (needle == "" or name:lower():find(needle, 1, true)) then
            n = n + 1
            M.log("  " .. name)
        end
    end
    M.log(string.format("  %d method(s) matching '%s'", n, tostring(filter or "")))
end

------------------------------------------------------------
-- SolidSave
------------------------------------------------------------

local function save_object()
    local ss = ss_mgr:get()
    if not ss then return nil end
    local f = ss_mgr:get_field("mSaveWork")
    if not f then return nil end
    return Shared.safe_get_field(ss, f)
end

local function read_all()
    local sw = save_object()
    if not sw then
        M.log.warn("SolidStorage.mSaveWork unreadable -- load a save first")
        return nil
    end
    local ok_td, td = pcall(sw.get_type_definition, sw)
    if not ok_td or not td then return nil end
    local out, count = {}, 0
    for _, field in ipairs(Shared.get_fields_array(td)) do
        local name
        pcall(function() name = field:get_name() end)
        if name then
            local ok, v = pcall(field.get_data, field, sw)
            if ok then
                local enc = encode(v)
                if enc then out[name] = enc; count = count + 1 end
            end
        end
    end
    return out, count
end

function M.snapshot()
    local vals, n = read_all()
    if not vals then return end
    snapshot = vals
    M.log(string.format("baseline captured: %d comparable fields", n))
end

--- Prints only what moved, then re-baselines so calls can chain.
function M.diff()
    if not snapshot then M.log("no baseline -- drap_save_snapshot() first"); return end
    local vals = read_all()
    if not vals then return end
    local changed = 0
    for name, v in pairs(vals) do
        local was = snapshot[name]
        if was ~= v then
            changed = changed + 1
            local delta = array_delta(was, v)
            if delta ~= "" then
                M.log(string.format("  %-40s %s", name, delta))
            else
                M.log(string.format("  %-40s %s -> %s", name, tostring(was), tostring(v)))
            end
        end
    end
    if changed == 0 then M.log("  nothing changed") end
    snapshot = vals
end

function M.save_fields()
    local sw = save_object()
    if not sw then M.log.warn("no save object"); return end
    dump_object(sw, "SolidSave")
end

--- What the player is looking at right now, resolved to something nameable.
--- The interaction only carries a gameObject, so the name is the identity we
--- would key a gate on.
function M.interaction()
    local pim = sdk.get_managed_singleton("app.solid.PlayerInteractionManager")
    if not pim then M.log("PlayerInteractionManager unavailable"); return end

    local has
    pcall(function() has = pim:call("get_HasInteraction") end)
    if has ~= true then M.log("  nothing in range"); return end

    local cur
    pcall(function() cur = pim:call("get_CurrentInteraction") end)
    if not cur then M.log("  no current interaction"); return end

    local function fld(name)
        local v
        pcall(function() v = cur:get_field(name) end)
        return v
    end

    local itype, prio = fld("Type"), fld("Priority")
    M.log(string.format("  Type=%s  Priority=%s", tostring(itype), tostring(prio)))

    local go = fld("gameObject")
    if go then
        local name
        pcall(function() name = go:call("get_Name") end)
        M.log("  gameObject = " .. tostring(name))
        local t
        pcall(function() t = go:get_type_definition():get_full_name() end)
        M.log("  goType     = " .. tostring(t))
    else
        M.log("  gameObject unreadable")
    end

    -- Item interactions may name the item outright.
    for _, m in ipairs({ "IsItemInteraction", "getCurrentInteractionType",
                         "IsShowChangeIcon", "IsAreaWarpInteraction" }) do
        local v
        pcall(function() v = pim:call(m) end)
        if v ~= nil then M.log(string.format("  %-26s %s", m, tostring(v))) end
    end

    local item
    pcall(function() item = pim:call("get_ItemReserved") end)
    if item then
        local n
        pcall(function() n = item:call("get_ItemNo") end)
        if n == nil then pcall(function() n = item:get_field("ItemNo") end) end
        M.log("  ItemReserved ItemNo = " .. tostring(n))
    end
end

------------------------------------------------------------
-- Passive interaction log
------------------------------------------------------------
-- The suppressant pickups are world objects, not catalogue items, so the only
-- identity they carry is the gameObject name (PREF_uOm224 is the Magnifying
-- Glass). Logging each name as the player looks at it builds the map without
-- eight trips across the mall -- the flag trace supplies the correlation,
-- since the pickup flag fires moments after the name appears.

local watching = false
local last_seen = nil
local last_poll = 0

local function poll_interaction()
    if not watching then return end
    local now = os.clock()
    if now - last_poll < 0.25 then return end
    last_poll = now

    local pim = sdk.get_managed_singleton("app.solid.PlayerInteractionManager")
    if not pim then return end
    local has
    pcall(function() has = pim:call("get_HasInteraction") end)
    if has ~= true then last_seen = nil; return end

    local cur
    pcall(function() cur = pim:call("get_CurrentInteraction") end)
    if not cur then return end
    local go
    pcall(function() go = cur:get_field("gameObject") end)
    if not go then return end
    local name
    pcall(function() name = go:call("get_Name") end)
    if not name or name == last_seen then return end
    last_seen = name

    local itype
    pcall(function() itype = cur:get_field("Type") end)
    M.log(string.format("looking at %-24s (Type=%s)", tostring(name), tostring(itype)))
end

-- Declared above the frame loop that uses it: below, it was out of scope
-- there and the closure read and wrote a global instead.
local pop_pending = nil

re.on_frame(function()
    pcall(poll_interaction)
    if pop_pending then
        local box = pop_pending
        pop_pending = nil
        -- closePop(ForceCancel = true): the game's own "close as cancelled".
        local ok = pcall(function() box:call("closePop", true) end)
        M.log("closePop(true) called: " .. tostring(ok))
    end
end)

--- @param on boolean|nil omit to toggle
function M.watch(on)
    if on == nil then on = not watching end
    watching = on == true
    last_seen = nil
    M.log("interaction watch " .. (watching and "ON" or "off"))
end

--- Print one line per element of a collection: its type, and the named field
--- if you give one. Dumping a 30-entry list one index at a time is unusable.
--- @param field string|nil field or get_<field>() to show per element
function M.each(type_name, path, field, limit)
    local root = sdk.get_managed_singleton(tostring(type_name))
    if not root then M.log("singleton not found: " .. tostring(type_name)); return end
    local coll, missing = walk(root, path)
    if not coll then M.log("path stopped at '" .. tostring(missing) .. "'"); return end

    local n = collection_count(coll)
    if not n then
        -- Not a list. Show what it actually is -- UserData usually wraps its
        -- array in a field, and that field name is the next step.
        M.log("  not a collection -- dumping it instead:")
        dump_object(coll, tostring(type_name) .. "." .. tostring(path))
        return
    end
    M.log(string.format("=== %s.%s -- %d element(s)", tostring(type_name),
        tostring(path), n))

    local cap = math.min(n, tonumber(limit) or 64)
    for i = 0, cap - 1 do
        local e = index_into(coll, i)
        if e == nil then
            M.log(string.format("  [%d] (unreadable)", i))
        else
            local shown
            if field and field ~= "" then
                pcall(function() shown = e:get_field(field) end)
                if shown == nil then pcall(function() shown = e:call("get_" .. field) end) end
            end
            local t
            pcall(function() t = e:get_type_definition():get_full_name() end)
            M.log(string.format("  [%d] %-46s %s", i, tostring(t),
                shown ~= nil and tostring(shown) or ""))
        end
    end
    if cap < n then M.log(string.format("  ... %d more (raise the limit)", n - cap)) end
end

------------------------------------------------------------
-- Scene components
------------------------------------------------------------
-- Event scripts like EventSetCookingEquipment are components on a GameObject,
-- not managed singletons, so get_managed_singleton never finds them.

local function current_scene()
    local ns = sdk.get_native_singleton("via.SceneManager")
    if not ns then return nil end
    local td = sdk.find_type_definition("via.SceneManager")
    if not td then return nil end
    local scene
    pcall(function()
        scene = sdk.call_native_func(ns, td, "get_CurrentScene")
    end)
    return scene
end

--- Find every live component of `type_name`, optionally walking into each.
--- @param path string|nil field path inside the component
--- @param field string|nil per-element field when the path lands on a list
function M.components(type_name, path, field)
    local scene = current_scene()
    if not scene then M.log("no current scene"); return end

    local list
    pcall(function()
        list = scene:call("findComponents(System.Type)", sdk.typeof(tostring(type_name)))
    end)
    if not list then
        M.log("findComponents failed for " .. tostring(type_name))
        return
    end
    local n = collection_count(list) or 0
    M.log(string.format("=== %s -- %d instance(s) in the scene", tostring(type_name), n))
    if n == 0 then
        M.log("  (the event may only exist while its scene is loaded)")
        return
    end

    for i = 0, n - 1 do
        local comp = index_into(list, i)
        if comp then
            if not path or path == "" then
                dump_object(comp, string.format("%s[%d]", tostring(type_name), i))
            else
                local target, missing = walk(comp, path)
                if not target then
                    M.log(string.format("  [%d] path stopped at '%s'", i, tostring(missing)))
                else
                    local cnt = collection_count(target)
                    if cnt then
                        M.log(string.format("  [%d] %s -- %d element(s)", i, path, cnt))
                        for j = 0, cnt - 1 do
                            local e = index_into(target, j)
                            local shown
                            if e and field and field ~= "" then
                                pcall(function() shown = e:get_field(field) end)
                                if shown == nil then
                                    pcall(function() shown = e:call("get_" .. field) end)
                                end
                                M.log(string.format("      [%d] %s = %s", j,
                                    field, tostring(shown)))
                            elseif e then
                                dump_object(e, string.format("%s[%d]", path, j))
                            end
                        end
                    else
                        dump_object(target, string.format("[%d].%s", i, path))
                    end
                end
            end
        end
    end
end

------------------------------------------------------------
-- Hook a method and dump `this` when it runs
------------------------------------------------------------
-- Scene components are hard to find and easy to miss. Hooking the method that
-- uses the data is deterministic: whatever placed the objects has to call it.

local hooked = {}

--- @param type_name string
--- @param method string
--- @param path string|nil list field on `this` to enumerate
--- @param fields table|nil field names to print per element
function M.hook_dump(type_name, method, path, fields)
    local key = type_name .. "." .. method
    if hooked[key] then M.log("already hooked: " .. key); return end

    local td = sdk.find_type_definition(tostring(type_name))
    if not td then M.log("type not found: " .. tostring(type_name)); return end
    local m = td:get_method(tostring(method))
    if not m then M.log("method not found: " .. tostring(method)); return end

    local ok = pcall(sdk.hook, m, function(args)
        local this = sdk.to_managed_object(args[2])
        if not this then return end
        M.log("=== " .. key .. " fired")
        if not path or path == "" then
            dump_object(this, key)
            return
        end
        local target = walk(this, path)
        if not target then M.log("  '" .. path .. "' unreadable"); return end
        local n = collection_count(target)
        if not n then dump_object(target, path); return end
        M.log(string.format("  %s -- %d element(s)", path, n))
        for i = 0, n - 1 do
            local e = index_into(target, i)
            if e then
                local parts = {}
                for _, fname in ipairs(fields or {}) do
                    local v
                    pcall(function() v = e:get_field(fname) end)
                    if v == nil then pcall(function() v = e:call("get_" .. fname) end) end
                    parts[#parts + 1] = string.format("%s=%s", fname, tostring(v))
                end
                if #parts == 0 then
                    dump_object(e, string.format("[%d]", i))
                else
                    M.log(string.format("    [%d] %s", i, table.concat(parts, "  ")))
                end
            end
        end
    end, function(retval) return retval end)

    if ok then
        hooked[key] = true
        M.log("hooked " .. key .. " -- trigger it and the dump lands in this log")
    else
        M.log.warn("hook install failed for " .. key)
    end
end

--- The one we actually want: every CookInfo, with both flags.
_G.drap_cook_hook = function()
    for _, method in ipairs({ "setCookingEquipment", "doEvent" }) do
        M.hook_dump("app.solid.gamemastering.EventSetCookingEquipment", method,
            "CookInfos", { "ClassName", "ShowFlag", "GetFlag" })
    end
end

--- Hook every method on a type and report the first time each one fires.
--- For "something opens this box, but what?" -- searching the dump for a
--- likely name has a poor hit rate; watching what actually runs does not.
--- Skips the hot per-frame ones by default so the log stays readable.
local fired = {}
-- Which methods drap_skip is currently refusing, and which are already
-- hooked -- a method can only be hooked once, so the flag is what toggles.
local skipping = {}
local skip_hooked = {}
local skip_said = {}
local SKIP = { update = true, lateUpdate = true, doUpdate = true,
               [".ctor"] = true, doAwake = true, getDisplaySize = true }

--- @param filter string|nil only hook methods whose name contains this
function M.hook_type(type_name, filter)
    local td = sdk.find_type_definition(tostring(type_name))
    if not td then M.log("type not found: " .. tostring(type_name)); return end
    local needle = tostring(filter or ""):lower()
    local n = 0
    for _, m in ipairs(td:get_methods() or {}) do
        local name
        pcall(function() name = m:get_name() end)
        if name and not SKIP[name]
           and (needle == "" or name:lower():find(needle, 1, true)) then
            local key = type_name .. "." .. name
            if not fired[key] then
                fired[key] = false
                local ok = pcall(sdk.hook, m,
                    function(args)
                        if fired[key] == false then
                            fired[key] = true
                            M.log("FIRED  " .. key)
                        end
                    end,
                    function(retval) return retval end)
                if ok then n = n + 1 else fired[key] = nil end
            end
        end
    end
    M.log(string.format("hooked %d method(s) on %s -- trigger it and watch",
        n, tostring(type_name)))
end

------------------------------------------------------------
-- Confirmation-box experiment
------------------------------------------------------------
-- PopUI_Base is the yes/no box. It carries a ForceCancel bool, which looks
-- like the game's own way to decline a prompt -- much better than intercepting
-- a button. This tries that, and skipping openPop outright, so the real gate
-- can be built on whichever actually works.
--
-- DEBUG ONLY: it blocks EVERY pop dialog, save prompts included.

local pop_mode = nil            -- nil | "close" | "skip" | "dismiss"
local pop_hooked = false
-- Answering the box beats suppressing it: skipping openPop leaves the
-- conversation wedged until the area reloads. closePop takes a ForceCancel
-- parameter -- it is a argument, not a field, which is why setting a field
-- called ForceCancel did nothing.
-- Set while the box currently open is the one we mean to neutralise, so
-- invokeCallbackOnClose can be skipped for that box only.
local pop_is_target = false
local pop_invoke_hooked = false
-- Substring that identifies Isabela's departure prompt.
local POP_MATCH = "absolutely sure"

--- Skip the method that acts on the answer. The box still opens and closes
--- normally; only the consequence is dropped. Clearing CallbackOnClose did not
--- take and forcing Mode only changed the buttons -- the callback ran either
--- way -- so this targets the invoke itself.
local function install_invoke_hook()
    if pop_invoke_hooked then return end
    local td = sdk.find_type_definition("app.solid.gui.PopUI_Base")
    if not td then return end
    local m = td:get_method("invokeCallbackOnClose")
    if not m then M.log("invokeCallbackOnClose not found"); return end
    local ok = pcall(sdk.hook, m,
        function(args)
            if not pop_is_target then return end

            if pop_mode == "forceno" then
                -- Let the callback run -- it also tidies the conversation up,
                -- which is why dropping it leaves her unresponsive -- but flip
                -- the answer to cancelled first so it takes the No branch.
                local this = sdk.to_managed_object(args[2])
                if this then
                    local ok = pcall(function()
                        this:set_field("ForceCancel", true)
                    end)
                    M.log("ForceCancel set before invoke: " .. tostring(ok))
                end
                pop_is_target = false
                return
            end

            if pop_mode == "noinvoke" then
                pop_is_target = false
                M.log("invokeCallbackOnClose skipped -- answer dropped")
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
        end,
        function(retval) return retval end)
    pop_invoke_hooked = true
    M.log(ok and "invokeCallbackOnClose hooked"
              or "could not hook invokeCallbackOnClose")
end

local function install_pop_hook()
    if pop_hooked then return end
    local td = sdk.find_type_definition("app.solid.gui.PopUI_Base")
    if not td then M.log("PopUI_Base not found"); return end
    local m = td:get_method("openPop")
    if not m then M.log("openPop not found"); return end

    local ok = pcall(sdk.hook, m,
        function(args)
            if not pop_mode then return end
            if pop_mode == "skip" then
                M.log("openPop skipped -- the box never opens")
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
            local this = sdk.to_managed_object(args[2])
            if not this then return end

            -- Identify the box. DialogData carries Name/Header/Message, so the
            -- real gate can target one prompt instead of every dialog.
            local data
            pcall(function() data = sdk.to_managed_object(args[3]) end)
            if data then
                local function fld(n)
                    local v
                    pcall(function() v = data:get_field(n) end)
                    return v ~= nil and tostring(v) or "?"
                end
                local msg = fld("Message")
                pop_is_target = msg:lower():find(POP_MATCH, 1, true) ~= nil
                M.log(string.format("openPop  Mode=%s  target=%s",
                    fld("Mode"), tostring(pop_is_target)))
                M.log("         Message=" .. msg)
            end

            if pop_mode == "watch" then return end
            if pop_mode == "noinvoke" or pop_mode == "forceno" then
                return                                  -- handled on invoke
            end

            if pop_mode == "close" then
                -- Next frame, not here: closing inside openPop re-enters the
                -- box while it is still opening.
                pop_pending = this
                return
            end

            if pop_mode == "nullcb" and data then
                -- CallbackOnClose is Action<Result> -- the thing YES runs.
                -- Clear it and the box still closes, it just does nothing.
                local ok_set = pcall(function()
                    data:set_field("CallbackOnClose", nil)
                end)
                M.log("CallbackOnClose cleared: " .. tostring(ok_set))
                return
            end

            if pop_mode == "mode" and data then
                -- Mode picks which buttons exist. Try the no-button variant.
                local ok_set = pcall(function() data:set_field("Mode", 0) end)
                M.log("Mode forced to 0: " .. tostring(ok_set))
            end
        end,
        function(retval) return retval end)
    pop_hooked = true
    M.log(ok and "PopUI_Base.openPop hooked" or "could not hook openPop")
end

--- @param mode string|nil "cancel" sets ForceCancel, "skip" blocks the box,
---   nil or "off" turns it back off
function M.pop_block(mode)
    if mode == nil or mode == false or mode == "off" then
        pop_mode = nil
        M.log("pop block off")
        return
    end
    local allowed = { skip = true, watch = true, close = true,
                      nullcb = true, mode = true, noinvoke = true,
                      forceno = true }
    pop_mode = allowed[mode] and mode or "watch"
    if not allowed[mode] then
        M.log("unknown mode -- using watch. try: watch, forceno, noinvoke, nullcb, close, mode, skip")
    end
    install_pop_hook()
    install_invoke_hook()
    M.log("pop block: " .. pop_mode .. "  (DEBUG -- affects every pop dialog)")
end

_G.drap_pop_block = function(mode) M.pop_block(mode) end
_G.drap_hook_type = function(t, f) M.hook_type(t, f) end

--- Skip a method outright, to find out whether refusing it stops something.
---
--- Hooking to observe is safe; skipping is not -- the engine may rely on the
--- call having happened. Crashing or wedging is a normal outcome here, and is
--- itself an answer: that method is load bearing. Toggle off, or reload.
---
---   drap_skip("app.solid.gamemastering.AreaManager", "applyNextAreaDoorNo")
---   drap_skip(nil)   -- stop skipping everything
_G.drap_skip = function(type_name, method_name, on)
    if type_name == nil then
        for key in pairs(skipping) do skipping[key] = nil end
        M.log("skip: nothing is being skipped now")
        return
    end
    local td = sdk.find_type_definition(tostring(type_name))
    if not td then M.log("skip: type not found: " .. tostring(type_name)); return end

    local want = tostring(method_name or ""):lower()
    local n = 0
    for _, m in ipairs(td:get_methods() or {}) do
        local ok, name = pcall(m.get_name, m)
        if ok and name and not SKIP[name]
           and (want == "" or name:lower():find(want, 1, true)) then
            local key = type_name .. "." .. name
            skipping[key] = (on ~= false)
            if skip_hooked[key] == nil then
                skip_hooked[key] = true
                pcall(sdk.hook, m,
                    function()
                        if skipping[key] then
                            if not skip_said[key] then
                                skip_said[key] = true
                                M.log("SKIPPING " .. key)
                            end
                            return sdk.PreHookResult.SKIP_ORIGINAL
                        end
                    end,
                    function(retval) return retval end)
            end
            n = n + 1
        end
    end
    M.log(string.format("skip: %s %d method(s) matching '%s' on %s",
        (on ~= false) and "now skipping" or "no longer skipping",
        n, want == "" and "*" or want, tostring(type_name)))
end
_G.drap_hook_dump  = function(t, m, p, f) M.hook_dump(t, m, p, f) end
_G.drap_components = function(t, p, f) M.components(t, p, f) end
_G.drap_obj_each = function(t, p, f, n) M.each(t, p, f, n) end
--- Every component on the object the player is looking at. The pickup icon
--- survives clearCurrentInteraction, so it belongs to the object rather than
--- to the interaction -- this is how we find which component draws it.
function M.interaction_components()
    local pim = sdk.get_managed_singleton("app.solid.PlayerInteractionManager")
    if not pim then M.log("PlayerInteractionManager unavailable"); return end
    local cur
    pcall(function() cur = pim:call("get_CurrentInteraction") end)
    if not cur then
        pcall(function() cur = pim:get_field("<CurrentInteraction>k__BackingField") end)
    end
    if not cur then M.log("  no current interaction"); return end
    local go
    pcall(function() go = cur:get_field("gameObject") end)
    if not go then M.log("  no gameObject"); return end

    local name
    pcall(function() name = go:call("get_Name") end)
    M.log("=== components on " .. tostring(name))

    local comps
    pcall(function() comps = go:call("get_Components") end)
    if not comps then
        -- Older signature: walk the component chain instead.
        local c
        pcall(function() c = go:call("get_Component") end)
        if c then dump_object(c, "component") end
        M.log("  get_Components unavailable")
        return
    end
    local n = collection_count(comps) or 0
    for i = 0, n - 1 do
        local c = index_into(comps, i)
        if c then
            local t, enabled
            pcall(function() t = c:get_type_definition():get_full_name() end)
            pcall(function() enabled = c:call("get_Enabled") end)
            M.log(string.format("  [%d] %-56s enabled=%s", i, tostring(t),
                tostring(enabled)))
        end
    end
    M.log(string.format("  %d component(s)", n))
end

--- List a GameObject's components by name, with their enabled state, and
--- remember the result. Run it before and after disabling something in the
--- ObjectViewer and drap_components_diff() names what changed -- the
--- interaction-based dump cannot help once the interaction is gone.
local last_components = nil
local last_object = nil

local function find_object(name)
    local ns = sdk.get_native_singleton("via.SceneManager")
    if not ns then return nil end
    local td = sdk.find_type_definition("via.SceneManager")
    if not td then return nil end
    local scene
    pcall(function() scene = sdk.call_native_func(ns, td, "get_CurrentScene") end)
    if not scene then return nil end
    local go
    pcall(function()
        go = scene:call("findGameObject(System.String)", tostring(name))
    end)
    return go
end

local function component_states(go)
    local out = {}
    local comps
    pcall(function() comps = go:call("get_Components") end)
    if not comps then return out end
    local n = collection_count(comps) or 0
    for i = 0, n - 1 do
        local c = index_into(comps, i)
        if c then
            local t, enabled
            pcall(function() t = c:get_type_definition():get_full_name() end)
            pcall(function() enabled = c:call("get_Enabled") end)
            out[#out + 1] = { type = tostring(t), enabled = enabled }
        end
    end
    return out
end

--- @param name string exact GameObject name, e.g. "PREF_uNp0d"
function M.components_of(name)
    local go = find_object(name)
    if not go then
        M.log("no GameObject named " .. tostring(name)
              .. " in the current scene")
        return
    end
    local states = component_states(go)
    M.log(string.format("=== %s -- %d component(s)", tostring(name), #states))
    for i, c in ipairs(states) do
        M.log(string.format("  [%d] %-56s enabled=%s", i - 1, c.type,
            tostring(c.enabled)))
    end
    last_components, last_object = states, tostring(name)
end

--- What changed since the last components_of() on the same object.
function M.components_diff()
    if not last_components then
        M.log("nothing captured -- drap_components_of(\"name\") first")
        return
    end
    local go = find_object(last_object)
    if not go then M.log("object gone: " .. tostring(last_object)); return end
    local now = component_states(go)
    local changed = 0
    for i, c in ipairs(now) do
        local was = last_components[i]
        if was and was.type == c.type and was.enabled ~= c.enabled then
            changed = changed + 1
            M.log(string.format("  %-56s %s -> %s", c.type,
                tostring(was.enabled), tostring(c.enabled)))
        end
    end
    if changed == 0 then M.log("  no component changed state") end
    last_components = now
end

_G.drap_components_of   = function(n) M.components_of(n) end
_G.drap_components_diff = function() M.components_diff() end
_G.drap_interaction_components = function() M.interaction_components() end
_G.drap_interaction_watch = function(on) M.watch(on) end
_G.drap_interaction   = function() M.interaction() end
_G.drap_obj           = function(t, p) M.obj(t, p) end
_G.drap_obj_methods   = function(t, f) M.methods(t, f) end
_G.drap_save_fields   = function() M.save_fields() end
_G.drap_save_snapshot = function() M.snapshot() end
_G.drap_save_diff     = function() M.diff() end

return M
