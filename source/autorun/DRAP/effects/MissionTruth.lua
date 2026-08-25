-- DRAP/effects/MissionTruth.lua
-- Keeps the game's main mission box (top-left HUD, watch, and map screen)
-- showing the ScoopSanity player's CURRENT objective instead of the
-- vanilla story's stale/wrong case text.
--
-- Approach: we can't force a case box to render (text appears only when a
-- scenario is genuinely active) and GUI control writes crash the engine.
-- Instead we hook via.gui.message.get (the resolver every UI surface pulls
-- text from) and rewrite its RESULT -- runs on the engine thread, holds no
-- control refs, updates HUD/watch/map at once, crash-free. The engine's box
-- diverges from the randomized chain, so we LEARN whatever string it shows
-- (safe HUD text reads) and register that string -> our objective text. The
-- objective PIN is redirected at getSCQPosData (index rewrite).
--
-- Swaps are keyed on the message GUID (stable identity) with the string match
-- kept as a fallback -- see the GUID-KEYED SWAPS note below. That is what lets
-- a box be answered even when the engine's own result is empty, which the
-- string match could never key on.

local M = {}

local Shared = require("DRAP/Shared")
local log = Shared.create_logger("MissionTruth")
M.log = log

local State = require("DRAP/scoops/ScoopState")
local SharedData = require("DRAP/SharedData")

------------------------------------------------------------
-- State
------------------------------------------------------------

local enabled = false            -- master toggle (ScoopSanity only)
local target = nil               -- { title, info, combined, pos_tbl }
local scoop_unlocker = nil       -- set in init (avoid require cycle)

-- GUID-KEYED SWAPS. The string-keyed table further down is REACTIVE: it can
-- only answer for text it has already seen. A stale entry keeps answering
-- after it should have been dropped (the "box sticks on Santa Cabeza"
-- report), and an unseen string has no entry at all (the blank box this
-- file's header used to call an accepted bug).
--
-- via.gui.message.get takes a GUID identifying the message, which is stable
-- identity rather than volatile content. We store the GUID's ROLE -- "title",
-- "info", or "combined" (the map/watch form, which carries title + GOAL +
-- description in one message) -- and never the text: the replacement is
-- derived from the LIVE
-- target on every call, so a target change re-points every known GUID at once
-- and no invalidation is needed. That is what makes the Santa Cabeza class
-- impossible rather than merely unlikely.
--
-- The GUID is captured in a PRE-hook and consumed in the POST-hook, paired
-- through thread.get_hook_storage(). Rolling our own thread key does NOT
-- work: post hooks receive only retval, with no args to key on, and the game
-- runs update work as jobs migrating across a worker pool.
--
-- Cost: the pre-hook stashes raw pointers only. Resolving a GUID to a string
-- happens lazily in the post-hook, when there is a decision to make.
--
-- The catalog below is seeded at enable, so a box can be answered from the
-- first frame -- including one whose text we have never observed, which is
-- what the learn-from-text path could never do. Harvested in game
-- (drap_mt_observe / drap_mt_catalog). The game is years past its last
-- update, so these are stable.
--
-- INCOMPLETE: learning stays on and logs "NEW message GUID" for anything
-- missing here. Fold those in until a full run adds none.
local MSG_GUID_ROLE = {
    ["f112e394-7f98-42fa-99ec-ba075c78bffc"] = "combined",   -- 72-Hour Nightmare
    ["1f9592f8-69ee-48cf-8822-a47290a80e12"] = "combined",   -- CASE 1-2: Backup for Brad
    ["f817325e-301b-42a3-944e-9508e7e138ea"] = "combined",   -- CASE 1-3: An Odd Old Man
    ["6c9d6274-13b3-4e5d-983d-678aa4ed2b0a"] = "combined",   -- CASE 1-4: A Temporary Agreement
    ["89caa1ef-a133-40ab-9218-090eeaf3244e"] = "combined",   -- CASE 2-1: Image in the Monitor
    ["62550236-a5e1-4cd0-8b73-99822706a1e2"] = "combined",   -- CASE 2-2: Rescue the Professor
    ["416ae380-ba2f-4b54-bbf2-13a69d81b88c"] = "combined",   -- CASE 2-3: Medicine Run
    ["ccc4d0da-a7ff-4348-98d9-29cc2f66778f"] = "combined",   -- CASE 2-3: Medicine Run
    ["c7a7b4ae-a045-4496-b2cf-0801b8a526fc"] = "combined",   -- CASE 3-1: The Professor's Past
    ["a3bcc113-97e0-4c73-977b-b9994bd08ffb"] = "combined",   -- CASE 4-1: Another Source
    ["cad3d856-4309-486d-995a-cc3522265e06"] = "combined",   -- CASE 4-2: Girl Hunting
    ["a0d1c4b8-4dad-4b09-a9aa-7c50928e5fe0"] = "combined",   -- CASE 5-1: A Promise to Isabela
    ["64b70207-5c9c-43b9-8bbb-1c328e2b7612"] = "combined",   -- CASE 5-2: Transporting Isabela
    ["ebdd8743-3655-435d-9174-0d5882cda201"] = "combined",   -- CASE 6-1: Santa Cabeza
    ["1d30d2de-046d-4070-8ad1-74fa732cd40f"] = "combined",   -- CASE 7-1: The Last Resort
    ["49e36b2b-fb4c-43a7-94bd-1ed299dd8560"] = "combined",   -- CASE 7-2: Bomb Collector
    ["ced05ffa-f6b2-42d3-bc41-28af860e640d"] = "combined",   -- CASE 8-1: Finding Carlito
    ["357fdc5f-07ce-440f-ab58-88e1073bc244"] = "combined",   -- CASE 8-2: Hideout
    ["294730f2-ad95-46ff-a854-71691327f76d"] = "combined",   -- CASE 8-3: Jessie's Discovery
    ["9a5b3a99-23ba-49a6-b597-496078d23d44"] = "combined",   -- CASE 8-4: The Butcher
    ["9c41c421-a512-4db8-b7b6-05031a4fd7d4"] = "combined",   -- Run for your life!
    ["ae718e59-be8b-4cd4-8e12-cc49125b463c"] = "combined",   -- Something's wrong...
    ["2c918002-6617-45c0-b3ab-b262afd6b749"] = "combined",   -- Start investigating!
    ["1e3b2588-bda4-46cd-b25f-662f62b2a4a4"] = "combined",   -- THE FACTS: Memories
    ["fe4a3c9e-39a5-41ff-92e8-f377a7f3d311"] = "combined",   -- Time to Escape
    ["998649b4-5c6a-4851-9744-d1c5cd813c87"] = "title",   -- 72-Hour Nightmare
    ["e143a8eb-7d0a-4878-9e31-1812e0474ec9"] = "title",   -- A Promise to Isabela
    ["eba41b34-1839-4b09-a6b1-3290d0d50860"] = "title",   -- A Temporary Agreement
    ["1748eddb-e739-4f52-a6a5-e7f115ce7b84"] = "title",   -- An Odd Old Man
    ["8eab61c9-e4ed-44cc-8a00-4e1ebf02076a"] = "title",   -- Another Source
    ["bd08321e-dfd4-4c4d-bbec-cc669aafb99c"] = "title",   -- Backup for Brad
    ["f2602e1d-b57f-43ad-8574-a61388816a13"] = "title",   -- Bomb Collector
    ["3726c837-0fbf-44e1-81c4-6a9c96236668"] = "title",   -- Finding Carlito
    ["4e3e484f-910d-495a-bed3-bbd8fa1985f0"] = "title",   -- Girl Hunting
    ["b10d0723-38d9-428c-b6c3-a0c2c404fa2e"] = "title",   -- Hideout
    ["0ed67c2f-458b-4d43-9d61-b0b39429fab9"] = "title",   -- Image in the Monitor
    ["70c54c9b-9659-46c9-9ec7-37f26ed0eb3e"] = "title",   -- Jessie's Discovery
    ["a300327c-3390-4ccf-8921-aa01a118f09f"] = "title",   -- Medicine Run
    ["ead4338c-9aa5-47cb-a218-b76e3afbb93b"] = "title",   -- Rescue the Professor
    ["29bbe7fd-fd5b-480d-a214-830f6fe4cf4d"] = "title",   -- Run for your life!
    ["dc0241b3-d795-4be7-9c81-04c4cc096c9b"] = "title",   -- Santa Cabeza
    ["31fa8574-ae83-4b4a-ab09-d7d8925cd3db"] = "title",   -- Something's wrong...
    ["18a0fa9a-88b4-4e55-ae12-926c5b481028"] = "title",   -- Start investigating!
    ["4a7e31c8-8c44-454b-b0d2-56eb2325b896"] = "title",   -- The Butcher
    ["eb5cadda-7ed7-4bd6-a3e6-c31bdcf000b4"] = "title",   -- The Last Resort
    ["d55cb070-95fe-4d4f-b9e6-c2a3bb9ed3d3"] = "title",   -- Time to Escape
    ["1985ceac-44fd-44a4-9214-6ffe7985a4d1"] = "title",   -- Transporting Isabela
}

local guid_roles = {}
local guid_swap_count = 0
local guid_seeded = 0            -- how many came from the table above
local guid_text = {}             -- guid -> the ENGINE string first seen with it
-- Harvest mode: learn and record, but never rewrite. The box then shows the
-- game's own text, so a catalog run is not reading back our own swaps.
local observe_only = false
local harvest_file = "AP_DRDR_msg_guids.txt"   -- reframework/data
local harvest_count = 0
local harvest_seen = {}          -- guid -> true, dedupe across the run
local guid_learn_hits = 0
local guid_path_hits = 0         -- answered by GUID identity
local string_path_hits = 0       -- answered by matching engine text
local guid_resolve_fail = 0
local guid_no_storage = 0

-- message-swap table: engine string -> our replacement
local msg_swaps = {}
local msg_swap_count = 0
local learned_titles = {}        -- our currently-registered "from" titles
local seen = {}                  -- engine strings already learned this target

-- pin redirect: main-case pos-table indices the engine queries for the
-- objective marker (from main_case_guides); when it asks for one of
-- these we answer with the current objective's pos_tbl instead.
local MAIN_CASE_POS = {}         -- set: pos_tbl -> true
local target_pos_tbl = nil

local WAITING_TITLE = "Waiting for Mission"
local WAITING_INFO =
    "Next mission will unlock once it is sent to you."

-- Repurposed survivor boxes: six indicator-less survivor scoops borrow a
-- vanilla-only spare display entry (e.g. spare 2533 shows "Kindell's
-- Betrayal"); we swap its placeholder to the real survivor. message.get
-- yields two forms: the short title (swap by exact match) and a combined
-- "<title>\r\nGOAL: ...\r\n<desc>" string (swap by placeholder containment).
local repurposed_scoops = {}     -- { {name, placeholder, title, combined}, ... }
local repurpose_short = {}       -- placeholder -> title (exact, fast path)
local repurpose_list = {}        -- active { placeholder, combined } for combined
local function repurpose_combined_match(s)
    if #repurpose_list == 0 then return nil end
    if not s:find("GOAL:", 1, true) then return nil end
    for _, e in ipairs(repurpose_list) do
        if s:find(e.placeholder, 1, true) then return e.combined end
    end
    return nil
end

------------------------------------------------------------
-- Hooks (installed once)
------------------------------------------------------------

local msg_hooked = false
local pos_hooked = false

-- Map panel resolves title+GOAL+description as one combined string
-- ("CASE ...\r\n..."); match it by containment of a learned title so we
-- never have to touch MapUI's controls.
local function combined_match(s)
    if not (target and target.combined) then return nil end
    if s:sub(1, 5) ~= "CASE " then return nil end
    for t in pairs(learned_titles) do
        if s:find(t, 1, true) then return target.combined end
    end
    return nil
end

--- Turn a captured arg pointer into a GUID string. Tries the value-type
--- route first (System.Guid is passed by value) then the managed-object
--- route, because which one applies depends on the call signature.
local function guid_string(ptr)
    if not ptr then return nil end
    local out
    pcall(function()
        local vt = sdk.to_valuetype(ptr, "System.Guid")
        if vt then out = vt:call("ToString") end
    end)
    if not out then
        pcall(function()
            local mo = sdk.to_managed_object(ptr)
            if mo then out = mo:call("ToString") end
        end)
    end
    if out == nil then
        guid_resolve_fail = guid_resolve_fail + 1
        return nil
    end
    return tostring(out)
end

--- Which of the captured args actually holds the GUID depends on whether the
--- method is static. Try both and keep whichever resolves.
local function resolve_pending(slot)
    if not slot then return nil end
    return guid_string(slot.a2) or guid_string(slot.a3)
end

local function ensure_msg_hook()
    if msg_hooked then return true end
    local td = sdk.find_type_definition("via.gui.message")
    if not td then log("via.gui.message type n/a"); return false end
    local hooked = 0
    for _, sig in ipairs({ "get(System.Guid)",
                           "get(System.Guid, via.Language)" }) do
        local m = td:get_method(sig)
        if m then
            local ok = pcall(sdk.hook, m, function(args)
                -- PRE: stash the arg pointers only -- cheap. They are
                -- resolved to a GUID string lazily in the post hook, and only
                -- when there is a decision to make; message.get is called
                -- constantly and ToString on every call would be a real cost.
                --
                -- thread.get_hook_storage() is the table REFramework shares
                -- between the PRE and POST of the SAME invocation, so the
                -- pairing is correct even though the game runs its update
                -- work as jobs migrating across a worker pool. Hand-rolling a
                -- thread key does NOT work here: post hooks receive only
                -- retval, with no args to key on.
                -- Harvest runs INDEPENDENT of ScoopSanity: SS manipulates
                -- the story flags, so the boxes the engine shows under it are
                -- not the vanilla set (measured: the box opens on A Temporary
                -- Agreement rather than Backup for Brad). A clean catalog has
                -- to come from an unmodified run.
                if not (enabled or observe_only) then return end
                pcall(function()
                    local st = thread.get_hook_storage()
                    if st then st.mt_a2, st.mt_a3 = args[2], args[3] end
                end)
            end, function(retval)
                if not (enabled or observe_only) then return retval end

                -- HARVEST: record EVERY message the UI resolves, not just the
                -- ones we would swap, so the catalog can be built offline.
                -- Deduped by GUID, so the per-call cost falls away quickly
                -- once the common messages are recorded. Written to a file
                -- because the session log would not hold it all.
                if observe_only then
                    local hslot
                    pcall(function()
                        local st = thread.get_hook_storage()
                        if st and (st.mt_a2 or st.mt_a3) then
                            hslot = { a2 = st.mt_a2, a3 = st.mt_a3 }
                            st.mt_a2, st.mt_a3 = nil, nil
                        end
                    end)
                    local hg = resolve_pending(hslot)
                    if hg and not harvest_seen[hg] then
                        harvest_seen[hg] = true
                        local ht
                        pcall(function()
                            local mo = sdk.to_managed_object(retval)
                            if mo then ht = mo:call("ToString()") end
                        end)
                        ht = (type(ht) == "string") and ht or ""
                        guid_text[hg] = ht
                        harvest_count = harvest_count + 1
                        local NLC = "[" .. string.char(13) .. string.char(10) .. "]+"
                        local flat = ht:gsub(NLC, " | ")
                        pcall(function()
                            local fh = io.open(harvest_file, "a")
                            if fh then
                                fh:write(hg .. "	" .. flat .. string.char(10))
                                fh:close()
                            end
                        end)
                    end
                    return retval
                end
                local slot
                pcall(function()
                    local st = thread.get_hook_storage()
                    if st and (st.mt_a2 or st.mt_a3) then
                        slot = { a2 = st.mt_a2, a3 = st.mt_a3 }
                        st.mt_a2, st.mt_a3 = nil, nil
                    end
                end)
                if not slot then guid_no_storage = guid_no_storage + 1 end
                if msg_swap_count == 0 and guid_swap_count == 0 and not target
                    and #repurpose_list == 0 then return retval end
                local s
                pcall(function()
                    local mo = sdk.to_managed_object(retval)
                    if mo then s = mo:call("ToString()") end
                end)

                -- GUID path first: authoritative, and works even when the
                -- engine's own result is empty (the blank-box case).
                local rep, g
                -- GUID path first: authoritative, and it answers even when
                -- the engine's own result is empty (the blank-box case the
                -- string path could never key on).
                if guid_swap_count > 0 or type(s) ~= "string" or s == "" then
                    g = resolve_pending(slot)
                    local role = g and guid_roles[g]
                    if role and target then
                        -- "combined" is the map/watch form: one message
                        -- carrying title + GOAL + description together.
                        if role == "title" then
                            rep = target.title
                        elseif role == "combined" then
                            rep = target.combined
                        else
                            rep = target.info
                        end
                        if rep then guid_path_hits = guid_path_hits + 1 end
                    end
                end

                if not rep then
                    if type(s) ~= "string" or s == "" then return retval end
                    -- Only the MAIN box is GUID-learned. Repurposed survivor
                    -- boxes are a different mechanism keyed on a placeholder
                    -- string and must keep using it.
                    local main_rep = msg_swaps[s]
                    rep = main_rep or repurpose_short[s]
                        or combined_match(s) or repurpose_combined_match(s)
                    if main_rep then
                        string_path_hits = string_path_hits + 1
                        g = g or resolve_pending(slot)
                        if g and not guid_roles[g] then
                            guid_roles[g] = learned_titles[s] and "title" or "info"
                            guid_swap_count = guid_swap_count + 1
                            guid_learn_hits = guid_learn_hits + 1
                            -- Missing from MSG_GUID_ROLE: fold it in.
                            guid_text[g] = guid_text[g] or s
                            log(string.format(
                                "NEW message GUID %s as %s -- add to MSG_GUID_ROLE"
                                .. "  (engine text: %q)",
                                g, guid_roles[g], tostring(s)))
                        end
                    end
                end

                -- Harvest mode: everything above still ran (so the GUID is
                -- learned and its role recorded), but the engine's own text
                -- is returned untouched.
                if observe_only then
                    if g and s and s ~= "" and not guid_text[g] then
                        guid_text[g] = s
                        log(string.format("OBSERVED %s [%s] %q", g,
                            tostring(guid_roles[g]), s))
                    end
                    return retval
                end

                if rep then
                    local out
                    pcall(function()
                        out = sdk.to_ptr(sdk.create_managed_string(rep))
                    end)
                    if out then return out end
                end
                return retval
            end)
            if ok then hooked = hooked + 1 end
        end
    end
    msg_hooked = hooked > 0
    return msg_hooked
end

-- Repurposed-box pins: each spare's pin reads getSCQPosData(pos_tbl); those
-- entries are vanilla-only, so we overwrite mPos with the survivor's coords.
-- Re-asserted on a slow cadence to survive a save reload rebuilding the table.
local SCQ_TYPE = "app.solid.gamemastering.SCQManager"
local last_pin_apply = 0
local function apply_repurpose_pins()
    local scq = sdk.get_managed_singleton(SCQ_TYPE)
    if not scq then return end
    for _, e in ipairs(repurposed_scoops) do
        if e.x then
            -- overwrite BOTH the scoop's own pos entry (map icon) and the
            -- pool slot the rendered pin polls (dispTbl+8, verified live)
            for _, idx in ipairs({ e.pos_tbl, e.pin_slot }) do
                if idx then
                    pcall(function()
                        local pd = scq:call("getSCQPosData", idx)
                        if pd then
                            pd:set_field("mPos", Vector3f.new(e.x, e.y, e.z))
                        end
                    end)
                end
            end
        end
    end
end

-- Main-scoop pin: overwrite the current target's pos entry with its
-- harvested objective coords so the redirect (MAIN_CASE_POS -> target.pos_tbl)
-- lands right. One target at a time, so shared case-level pos_tbls are safe.
-- The compass follows too (mains read the guide off getSCQPosData).
local function apply_main_pin()
    if not (target and target.pos_tbl and target.x) then return end
    local scq = sdk.get_managed_singleton(SCQ_TYPE)
    if not scq then return end
    pcall(function()
        local pd = scq:call("getSCQPosData", target.pos_tbl)
        if pd then pd:set_field("mPos", Vector3f.new(target.x, target.y, target.z)) end
    end)
end

local function ensure_pos_hook()
    if pos_hooked then return true end
    local td = sdk.find_type_definition("app.solid.gamemastering.SCQManager")
    if not td then return false end
    local m = td:get_method("getSCQPosData")
    if not m then return false end
    local ok = pcall(sdk.hook, m, function(args)
        if not enabled or not target_pos_tbl then return end
        local idx
        pcall(function() idx = sdk.to_int64(args[3]) end)
        idx = idx and tonumber(idx) or nil
        if idx and MAIN_CASE_POS[idx] and idx ~= target_pos_tbl then
            pcall(function() args[3] = sdk.to_ptr(target_pos_tbl) end)
        end
    end, nil)
    pos_hooked = ok
    return pos_hooked
end

------------------------------------------------------------
-- BattleHudUI text reads (safe: reads only, never writes/walks MapUI)
------------------------------------------------------------

local hud_gui = nil
local hud_view_addr = nil
local hud_ctrls = nil            -- { title = {..}, info = {..} }

local function battle_hud_gui()
    local sm = sdk.get_native_singleton("via.SceneManager")
             or sdk.get_managed_singleton("via.SceneManager")
    local sm_td = sdk.find_type_definition("via.SceneManager")
    local scene
    pcall(function() scene = sdk.call_native_func(sm, sm_td, "get_CurrentScene") end)
    if not scene then pcall(function() scene = sm:call("get_CurrentScene") end) end
    if not scene then return nil end
    local first
    pcall(function() first = scene:call("get_FirstTransform") end)
    local stack = { first }
    while #stack > 0 do
        local t = table.remove(stack)
        if t then
            local go, name
            pcall(function() go = t:call("get_GameObject") end)
            if go then
                pcall(function() name = go:call("get_Name") end)
                if name == "BattleHudUI_0_Default" then
                    local comps
                    pcall(function() comps = go:call("get_Components") end)
                    local okl, elems = pcall(function() return comps:get_elements() end)
                    for _, c in ipairs(okl and elems or {}) do
                        local tn
                        pcall(function() tn = c:get_type_definition():get_full_name() end)
                        if tn == "via.gui.GUI" then return c end
                    end
                end
            end
            local child, nxt
            pcall(function() child = t:call("get_Child") end)
            pcall(function() nxt = t:call("get_Next") end)
            if child then table.insert(stack, child) end
            if nxt then table.insert(stack, nxt) end
        end
    end
    return nil
end

-- Resolve the two mission text controls once per View rebuild.
local function resolve_hud_controls()
    if not hud_gui then hud_gui = battle_hud_gui() end
    if not hud_gui then return end
    local view
    pcall(function() view = hud_gui:call("get_View") end)
    if not view then hud_gui = nil; return end
    local cache = { title = {}, info = {} }
    local stack = { { view, "View" } }
    local visited = 0
    while #stack > 0 and visited < 4000 do
        local top = table.remove(stack)
        local ctrl, path = top[1], top[2]
        visited = visited + 1
        if not path:find("/si_", 1, true) then
            local nm
            pcall(function() nm = ctrl:call("get_Name") end)
            if nm == "m_MissionName" then table.insert(cache.title, ctrl)
            elseif nm == "m_Caseinfo" then table.insert(cache.info, ctrl) end
        end
        local child, nxt
        pcall(function() child = ctrl:call("get_Child") end)
        pcall(function() nxt = ctrl:call("get_Next") end)
        if child then
            local n; pcall(function() n = child:call("get_Name") end)
            table.insert(stack, { child, path .. "/" .. tostring(n) })
        end
        if nxt then
            local n; pcall(function() n = nxt:call("get_Name") end)
            local parent = path:match("^(.*)/[^/]*$") or path
            table.insert(stack, { nxt, parent .. "/" .. tostring(n) })
        end
    end
    hud_ctrls = cache
end

-- Read the box's current on-screen title/info (first non-empty of each).
local function read_box()
    if not hud_ctrls then resolve_hud_controls() end
    if not hud_ctrls then return nil, nil end
    local et, ei
    for _, c in ipairs(hud_ctrls.title or {}) do
        local s; pcall(function() s = tostring(c:call("get_Message")) end)
        if s and s ~= "" then et = s; break end
    end
    for _, c in ipairs(hud_ctrls.info or {}) do
        local s; pcall(function() s = tostring(c:call("get_Message")) end)
        if s and s ~= "" then ei = s; break end
    end
    return et, ei
end

------------------------------------------------------------
-- Learn-and-swap scan
------------------------------------------------------------

local function clear_swaps()
    msg_swaps = {}
    msg_swap_count = 0
    learned_titles = {}
    seen = {}
end

local function learn(from, to, is_title)
    if not from or from == "" or from == to or seen[from] then return end
    seen[from] = true
    if not msg_swaps[from] then msg_swap_count = msg_swap_count + 1 end
    msg_swaps[from] = to
    if is_title then learned_titles[from] = true end
end

local last_scan = 0
local scan_full_at = 0

local function scan()
    if not enabled or not target then return end
    -- re-resolve controls only when the View rebuilt, or every 5s as a
    -- safety net -- reads are safe, control walks are heavy
    if not hud_gui then hud_gui = battle_hud_gui() end
    if not hud_gui then return end
    local addr
    local ok = pcall(function()
        local v = hud_gui:call("get_View")
        if v then addr = v:get_address() end
    end)
    if not ok then hud_gui = nil; return end
    local now = os.clock()
    if addr ~= hud_view_addr or now - scan_full_at > 5.0 then
        hud_view_addr = addr
        scan_full_at = now
        hud_ctrls = nil
    end
    local et, ei = read_box()
    learn(et, target.title, true)
    learn(ei, target.info, false)
end

------------------------------------------------------------
-- Target (what the box should say) from chain state
------------------------------------------------------------

local function objective_text(name)
    local d = State.data(name)
    local desc = d and d.description
    if not desc then return "" end
    return desc.description or desc.trigger or ""
end

local function make_target(title, info, loc, guide)
    return {
        title = title,
        info = info,
        combined = "CASE: " .. title .. "\r\nGOAL: " .. (loc or "?")
            .. "\r\n" .. info,
        pos_tbl = guide and guide.pos_tbl or nil,
        x = guide and guide.x, y = guide and guide.y, z = guide and guide.z,
    }
end

local function target_for_main(name)
    local d = State.data(name)
    local loc = d and d.description and d.description.location or "?"
    return make_target(name, objective_text(name), loc, d and d.guide)
end

-- Any active main scoop (received, not completed). Fallback when there's
-- no formal chain order set -- e.g. debug/manual unlocking without a seed.
local function find_active_main()
    for _, s in ipairs(SharedData.scoops()) do
        if s.category == "Main" and scoop_unlocker.is_scoop_active(s.name) then
            return s.name
        end
    end
    return nil
end

------------------------------------------------------------
-- The goal, when there is no mission to show
------------------------------------------------------------
-- The count-based goals used to leave the box on "Waiting for Mission" for
-- the whole run, which tells a player nothing about what they are meant to be
-- doing. Show the goal and how far along it is instead, and once it is met,
-- say where to go -- the run does not finish until the player is back in the
-- Security Room, and nothing else on screen says so.

local GOAL_SAVIOR, GOAL_GENOCIDE, GOAL_PSYCHO = 2, 3, 4

local GOAL_DONE_TITLE = "Goal Complete"
local GOAL_DONE_INFO =
    "Return to the Security Room to finish the run."

--- How many areas still owe kills, for the Genocider box.
--- @return integer|nil left, integer|nil total
local function genocide_areas_left()
    local kt = AP and AP.KillTracker
    if not (kt and kt.progress) then return nil, nil end
    local ok, rows = pcall(kt.progress)
    if not ok or type(rows) ~= "table" or #rows == 0 then return nil, nil end
    local left, total = 0, 0
    for _, row in ipairs(rows) do
        total = total + 1
        if not row.done then left = left + 1 end
    end
    return left, total
end

--- The box for a count-based goal, or nil if this seed has none.
---
--- Deliberately reads the same progress() the goals themselves use, so the
--- box cannot drift from the thing it is reporting.
local function goal_target()
    local goal = AP and tonumber(AP.Goal)
    if not goal then return nil end

    -- Goal met: the box's job is now to point at the Security Room.
    local ok_e, Ending = pcall(require, "DRAP/effects/EndingSequence")
    if ok_e and Ending and Ending.is_pending and Ending.is_pending() then
        return make_target(GOAL_DONE_TITLE, GOAL_DONE_INFO, "Security Room", nil)
    end

    if goal == GOAL_SAVIOR then
        local sg = AP and AP.effects and AP.effects.SaviorGoalEffects
        if not (sg and sg.progress) then return nil end
        local ok, n, t = pcall(sg.progress)
        if not ok or not n or not t then return nil end
        return make_target("Savior",
            string.format("Rescue %d survivors and escape. Rescued %d of %d.",
                t, n, t),
            "Anywhere in the mall", nil)
    end

    if goal == GOAL_PSYCHO then
        local pg = AP and AP.effects and AP.effects.PsychoGoalEffects
        if not (pg and pg.progress) then return nil end
        local ok, n, t = pcall(pg.progress)
        if not ok or not n or not t then return nil end
        return make_target("Psycho",
            string.format("Kill %d survivors and escape. Killed %d of %d.",
                t, n, t),
            "Anywhere in the mall", nil)
    end

    if goal == GOAL_GENOCIDE then
        local left, total = genocide_areas_left()
        if not left then return nil end
        return make_target("Zombie Genocider",
            left == 0
                and "Every area is cleared."
                or string.format(
                    "Kill 53,594 zombies across the mall. %d of %d area%s"
                    .. " still to clear.", left, total, left == 1 and "" or "s"),
            "Anywhere in the mall", nil)
    end

    return nil
end

-- Under ScoopSanity the main box never shows the vanilla story objective:
-- show the current mission, else a "Waiting for Mission" placeholder. Only
-- the endgame leaves the box to the engine (the finale plays normally).
local function compute_target()
    if not scoop_unlocker then return nil end
    if State.is_endgame_reached() then return nil end
    -- Any Order has no "next" scoop -- the player picks. Show the one they
    -- actually started, or the placeholder. Falling back to the chain here
    -- put the first unfinished scoop in the box just for being held, so the
    -- HUD named a mission that was not running.
    if State.is_any_order() then
        local running = State.active_main_scoop()
        if running then return target_for_main(running) end
        return goal_target()
            or make_target(WAITING_TITLE, WAITING_INFO, nil, nil)
    end

    -- current objective: chain order if set, else any manually-active main
    local current = scoop_unlocker.get_current_chain_scoop()
    if current and (scoop_unlocker.is_scoop_active(current)
        or scoop_unlocker.has_received_scoop(current)) then
        return target_for_main(current)
    end
    local active_main = find_active_main()
    if active_main then return target_for_main(active_main) end
    -- SS on, no active main -> the goal, if this seed has a counted one,
    -- else the placeholder. This is the branch a run spends most of its time
    -- in, so it is the one that matters.
    return goal_target()
        or make_target(WAITING_TITLE, WAITING_INFO, nil, nil)
end

local function target_key(t)
    if not t then return "" end
    return t.title .. "\1" .. t.info .. "\1" .. tostring(t.pos_tbl)
end

-- Rebuild the active repurpose swap set. Cheap + idempotent (safe every
-- tick); a box's placeholder is swapped only while its survivor is active.
local function update_repurpose()
    local short, list = {}, {}
    for _, e in ipairs(repurposed_scoops) do
        if scoop_unlocker and scoop_unlocker.is_scoop_active(e.name) then
            short[e.placeholder] = e.title
            table.insert(list, { placeholder = e.placeholder,
                                 combined = e.combined })
        end
    end
    repurpose_short = short
    repurpose_list = list
end

-- Recompute the target; reset learn/swap state only when it actually
-- changed (avoids thrashing). Called from the frame loop, so no wiring
-- into every state mutation is needed.
local last_grace = false

function M.refresh()
    if not enabled then return end
    -- While a story flag is held through an area load (see
    -- PROTECTED_PRIMARY_FLAGS.until_transition -- 272 is held so Brad
    -- despawns), the ENGINE repaints the mission box with that mission's
    -- text. Our computed target has not changed, so the dedupe below would
    -- skip the re-assert and the HUD would name a mission that is not
    -- running. Force a re-learn on each edge of that window.
    local grace = false
    if scoop_unlocker and scoop_unlocker.transition_grace_active then
        local ok, v = pcall(scoop_unlocker.transition_grace_active)
        grace = ok and v == true
    end
    if grace ~= last_grace then
        last_grace = grace
        target = nil
    end

    local t = compute_target()
    if target_key(t) == target_key(target) then return end
    target = t
    target_pos_tbl = t and t.pos_tbl or nil
    clear_swaps()
    if t then
        log(string.format("box -> %q / %q (pin %s)", t.title, t.info,
            tostring(target_pos_tbl)))
    else
        log("no chain target -- box left to engine")
    end
end

------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------

local frame_installed = false

function M.init(deps)
    scoop_unlocker = deps and deps.scoop_unlocker
    -- Both tables are rebuilt, not appended to. init used to only append, so
    -- a second call left every repurposed box listed twice and the HUD drew
    -- the same objective once per copy.
    MAIN_CASE_POS = {}
    repurposed_scoops = {}
    -- main-case pos-table indices (redirect-from set)
    for _, g in ipairs(SharedData.main_case_guides()) do
        if g.pos_tbl then MAIN_CASE_POS[g.pos_tbl] = true end
    end
    -- repurposed survivor boxes (borrowed vanilla-only spare entries)
    for _, s in ipairs(SharedData.scoops()) do
        local rp = s.repurpose
        if rp and rp.placeholder and rp.title then
            table.insert(repurposed_scoops, {
                name = s.name,
                placeholder = rp.placeholder,
                title = rp.title,
                combined = rp.title .. "\r\nGOAL: " .. (rp.goal or "?")
                    .. "\r\n" .. (rp.desc or ""),
                pos_tbl = rp.pos_tbl,   -- spare pos entry (map icon)
                pin_slot = rp.pin_slot, -- pool slot the pin actually reads
                x = rp.x, y = rp.y, z = rp.z,
            })
        end
    end
    if not frame_installed then
        frame_installed = true
        re.on_frame(function()
            if not enabled then return end
            if os.clock() - last_scan < 0.5 then return end
            last_scan = os.clock()
            pcall(M.refresh)          -- recompute main target if changed
            pcall(scan)               -- learn engine strings -> target
            pcall(update_repurpose)   -- refresh active survivor box swaps
            pcall(apply_main_pin)     -- keep main pin/compass on the target
            if os.clock() - last_pin_apply > 3.0 then
                last_pin_apply = os.clock()
                pcall(apply_repurpose_pins)   -- keep spare pins on survivors
            end
        end)
    end
    log(string.format("initialized (%d repurposed boxes)", #repurposed_scoops))
end

--- Seed the GUID table from the hardcoded catalog. Idempotent.
local function seed_guid_roles()
    if guid_seeded > 0 then return end
    for g, role in pairs(MSG_GUID_ROLE) do
        if not guid_roles[g] then
            guid_roles[g] = role
            guid_swap_count = guid_swap_count + 1
            guid_seeded = guid_seeded + 1
        end
    end
    log(string.format("seeded %d message GUIDs from the catalog", guid_seeded))
end

function M.set_enabled(on)
    on = not not on
    if on == enabled then return end
    enabled = on
    if on then seed_guid_roles() end
    if enabled then
        ensure_msg_hook()
        ensure_pos_hook()
        M.refresh()
        pcall(apply_repurpose_pins)   -- point spare pins at survivors
        log("enabled")
    else
        target = nil
        target_pos_tbl = nil
        clear_swaps()
        repurpose_short = {}
        repurpose_list = {}
        log("disabled")
    end
end

function M.is_enabled() return enabled end

--- What the GUID layer has learned. guid_swap_count > 0 means the box is
--- being answered by identity rather than by matching engine text.
--- Paste-able catalog of everything learned, for hardcoding once a full run
--- has exercised every box. Same shape as DoorAreaGuids.
_G.drap_mt_catalog = function()
    log("-- MissionTruth message GUIDs, harvested in game")
    log("local MSG_GUID_ROLE = {")
    for g, role in pairs(guid_roles) do
        -- Flatten CR/LF so each catalog entry stays on one line. Built with
        -- string.char because a literal escape here is easily mangled by the
        -- tooling these files get edited through.
        local NL_CLASS = "[" .. string.char(13) .. string.char(10) .. "]+"
        local txt = guid_text[g]
        log(string.format("    [%q] = %q,%s", g, role,
            txt and ("   -- " .. txt:gsub(NL_CLASS, " ")) or ""))
    end
    log("}")
    log(string.format("-- %d entries", guid_swap_count))
end

--- Harvest mode: learn GUIDs but leave the box showing the game's own text,
--- so a catalog run is not reading back our own replacements.
_G.drap_mt_observe = function(on)
    if on ~= nil then observe_only = (on == true) end
    -- Install the hook ourselves: set_enabled only runs under ScoopSanity,
    -- and a catalog run has to be possible without it.
    if observe_only then ensure_msg_hook() end
    log(string.format("observe-only: %s%s", tostring(observe_only),
        observe_only and "  (box NOT overwritten -- harvesting every message)"
        or ""))
    if observe_only then
        log(string.format("   %d GUIDs captured so far -> reframework/data/%s",
            harvest_count, harvest_file))
    end
end

--- How much the harvest has collected.
_G.drap_mt_harvest = function()
    log(string.format("harvest: %d distinct message GUIDs -> %s",
        harvest_count, harvest_file))
end

_G.drap_mt_guids = function()
    log(string.format(
        "GUID swaps: %d total (%d seeded, %d learned), %d resolve failures, %d no-storage",
        guid_swap_count, guid_seeded, guid_learn_hits, guid_resolve_fail,
        guid_no_storage))
    log(string.format(
        "   answered by GUID: %d | by engine text: %d  (GUID should dominate"
        .. " once learned)", guid_path_hits, string_path_hits))
    for g, role in pairs(guid_roles) do
        log(string.format("   %s -> %s", g, role))
    end
    if guid_swap_count == 0 then
        log("   none yet -- the string path is still doing all the work")
    end
    log(string.format("   current target: %s",
        target and string.format("%q / %q", target.title, target.info) or "none"))
end


return M
