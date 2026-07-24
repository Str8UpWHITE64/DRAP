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
-- Empty boxes (entry flag on, no engine string to swap) are an accepted rare
-- bug -- nothing to key a swap on, and writing the control crashes.

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

local function ensure_msg_hook()
    if msg_hooked then return true end
    local td = sdk.find_type_definition("via.gui.message")
    if not td then log("via.gui.message type n/a"); return false end
    local hooked = 0
    for _, sig in ipairs({ "get(System.Guid)",
                           "get(System.Guid, via.Language)" }) do
        local m = td:get_method(sig)
        if m then
            local ok = pcall(sdk.hook, m, nil, function(retval)
                if not enabled then return retval end
                if msg_swap_count == 0 and not target
                    and #repurpose_list == 0 then return retval end
                local s
                pcall(function()
                    local mo = sdk.to_managed_object(retval)
                    if mo then s = mo:call("ToString()") end
                end)
                if type(s) ~= "string" or s == "" then return retval end
                local rep = msg_swaps[s] or repurpose_short[s]
                    or combined_match(s) or repurpose_combined_match(s)
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

-- Under ScoopSanity the main box never shows the vanilla story objective:
-- show the current mission, else a "Waiting for Mission" placeholder. Only
-- the endgame leaves the box to the engine (the finale plays normally).
local function compute_target()
    if not scoop_unlocker then return nil end
    if State.is_endgame_reached() then return nil end
    -- current objective: chain order if set, else any manually-active main
    local current = scoop_unlocker.get_current_chain_scoop()
    if current and (scoop_unlocker.is_scoop_active(current)
        or scoop_unlocker.has_received_scoop(current)) then
        return target_for_main(current)
    end
    local active_main = find_active_main()
    if active_main then return target_for_main(active_main) end
    -- SS on, no active main -> override the vanilla box with a placeholder
    return make_target(WAITING_TITLE, WAITING_INFO, nil, nil)
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
function M.refresh()
    if not enabled then return end
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

function M.set_enabled(on)
    on = not not on
    if on == enabled then return end
    enabled = on
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

return M
