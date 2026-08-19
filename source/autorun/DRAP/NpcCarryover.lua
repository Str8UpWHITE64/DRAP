-- DRAP/NpcCarryover.lua
-- NPC Carry-Over Handler for Door Randomizer
-- Rewrites NPC destinations when player goes through randomized doors

local Shared = require("DRAP/Shared")

local M = Shared.create_module("NpcCarryOver")

------------------------------------------------------------
-- Configuration
------------------------------------------------------------

local NPC_MANAGER_TYPE = "app.solid.gamemastering.NpcManager"
local NPC_PROXIMITY_THRESHOLD = 5.0  -- Max distance per axis for NPC to follow

-- A door crossing's carry-over pass runs within a couple of seconds of the
-- jump. Beyond this, a checkCarryOverNpc call belongs to something else
-- (cutscene, safety-area replacement) and must not see the old door's areas.
local STALE_TRANSITION_SECONDS = 10.0

------------------------------------------------------------
-- State
------------------------------------------------------------

local npc_mgr = M:add_singleton("npc", NPC_MANAGER_TYPE)

local hooks_installed = false
local hook_install_attempted = false

local check_carry_over_method = nil
local npc_manager_td = nil

-- Spread carried-over NPCs apart slightly so they don't all stack on the
-- player on arrival.
local carry_over_counter = 0
local CARRY_OVER_OFFSET_STEP = 0.40

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local extract_vec3 = Shared.vec3_extract
local make_vec3    = Shared.vec3_create

local function get_player_position()
    local player_mgr = sdk.get_managed_singleton("app.solid.PlayerManager")
    if player_mgr then
        local condition = nil
        pcall(function() condition = player_mgr:get_field("_CurrentPlayerCondition") end)
        if condition then
            local pos = nil
            pcall(function() pos = condition:get_field("LastPlayerPos") end)
            if pos then
                return extract_vec3(pos)
            end
        end
    end
    return nil
end

-- A corpse keeps the mLiveState it died with: a killed escort still reads
-- JOIN, measured on a real kill (hp 3500 -> 0, isDead true, state stayed 2).
-- So "is this a party member" has to ask isDead/hp, never the live state.
local function record_is_dead(info)
    local dead, hp = nil, nil
    pcall(function() dead = info:call("isDead") end)
    if dead == true then return true end
    pcall(function() hp = Shared.to_int(info:get_field("mVitalNew")) end)
    return hp ~= nil and hp <= 0
end

local function is_npc_near_player(npc_pos, player_pos)
    if not npc_pos or not player_pos then return true end
    local dx = math.abs((npc_pos.x or 0) - (player_pos.x or 0))
    local dy = math.abs((npc_pos.y or 0) - (player_pos.y or 0))
    local dz = math.abs((npc_pos.z or 0) - (player_pos.z or 0))
    return dx <= NPC_PROXIMITY_THRESHOLD and dy <= NPC_PROXIMITY_THRESHOLD and dz <= NPC_PROXIMITY_THRESHOLD
end

------------------------------------------------------------
-- NPC Rewriting
------------------------------------------------------------

local function rewrite_single_npc(npc_obj, dest, index)
    if not npc_obj or not dest then return false end

    -- Stagger arrivals along x so 6 carry-overs don't stack on the player.
    carry_over_counter = carry_over_counter + 1
    local offset = CARRY_OVER_OFFSET_STEP * (carry_over_counter % 6)

    local new_area = dest.area_no
    local new_x = (dest.pos and dest.pos.x or 0) + offset
    local new_y = dest.pos and dest.pos.y or 0
    local new_z = dest.pos and dest.pos.z or 0

    pcall(function() npc_obj:set_field("mAreaNo", new_area) end)

    local new_pos = make_vec3(new_x, new_y, new_z)
    if new_pos then
        pcall(function() npc_obj:set_field("mPos", new_pos) end)
    end

    pcall(function() npc_obj:set_field("mCarryOverFlag", true) end)

    return true
end

local function rewrite_npc_list(npc_list, dest, player_area, player_pos)
    if not npc_list or not dest or not dest.area_no then return 0 end

    local count = Shared.get_collection_count(npc_list)
    if count == 0 then return 0 end

    -- Filter chain: only rewrite NPCs that are (1) party members
    -- (mLiveState == 2), (2) currently in the player's area, and (3)
    -- physically near the player. Anything else is unrelated to this
    -- carry-over event.
    local rewritten = 0
    for i = 0, count - 1 do
        local item = Shared.get_collection_item(npc_list, i)
        if item then
            local live_state, npc_area, npc_pos = nil, nil, nil
            pcall(function() live_state = Shared.to_int(item:get_field("mLiveState")) end)
            pcall(function() npc_area = Shared.to_int(item:get_field("mAreaNo")) end)
            pcall(function() npc_pos = extract_vec3(item:get_field("mPos")) end)

            local include = live_state == 2
                and not record_is_dead(item)
                and (not player_area or not npc_area or npc_area == player_area)
                and (not player_pos or not npc_pos or is_npc_near_player(npc_pos, player_pos))

            if include and rewrite_single_npc(item, dest, i) then
                rewritten = rewritten + 1
            end
        end
    end

    return rewritten
end

------------------------------------------------------------
-- Method Discovery
------------------------------------------------------------

local function discover_methods()
    npc_manager_td = sdk.find_type_definition(NPC_MANAGER_TYPE)
    if not npc_manager_td then return false end

    local methods = npc_manager_td:get_methods()
    if not methods then return false end

    for _, method in ipairs(methods) do
        if method then
            local ok, name = pcall(method.get_name, method)
            if ok and name and name == "checkCarryOverNpc" then
                check_carry_over_method = method
            end
        end
    end

    return check_carry_over_method ~= nil
end

------------------------------------------------------------
-- Hook Installation
------------------------------------------------------------

local function install_hooks()
    if hooks_installed or hook_install_attempted then return end
    hook_install_attempted = true

    if not discover_methods() then
        M.log("ERROR: Could not find required methods")
        return
    end

    -- Hook checkCarryOverNpc - this is where we rewrite NPC destinations
    local hook1_ok = pcall(function()
        sdk.hook(
            check_carry_over_method,
            -- PRE: Spoof args to vanilla so game's validation passes.
            --
            -- Argument order is destination first, then the area being left.
            -- That contradicts the dumped signature
            -- (probes/managers/NpcManager.txt:112):
            --   checkCarryOverNpc(UInt16 oldArea, UInt16 nextArea, UInt32 door)
            -- and it was "corrected" to match on 2026-08-08. That broke
            -- carry-over outright: every crossing afterwards marked ZERO
            -- records (NpcSaveGuard census carry=0 on four consecutive
            -- redirected doors, against carry=10 before), and the party was
            -- left behind. Reverted the same day.
            --
            -- So the dumped parameter NAMES are not reliable here -- only the
            -- observed behaviour is. Do not "fix" this order again without a
            -- crossing that proves it: the census carry count on the autosave
            -- right after a door is the measurement.
            --
            -- The transition must also be FRESH: last_transition persists
            -- until the next door, so without the age check any engine
            -- checkCarryOverNpc call minutes later (cutscene and safety-area
            -- flows call it too) was spoofed with a long-dead door crossing.
            function(args)
                local tr = nil
                if AP and AP.DoorRandomizer and AP.DoorRandomizer.get_last_transition then
                    tr = AP.DoorRandomizer.get_last_transition()
                end

                if tr and tr.randomized and tr.randomized.was_redirected
                    and tr.vanilla and tr.at
                    and (os.clock() - tr.at) <= STALE_TRANSITION_SECONDS then
                    local v_new = tr.vanilla.area_no
                    local v_old = tr.vanilla.area_no_old
                    if v_new then pcall(function() args[3] = sdk.to_ptr(v_new) end) end
                    if v_old then pcall(function() args[4] = sdk.to_ptr(v_old) end) end
                end
                return args
            end,
            -- POST: Rewrite NPC list to randomized destination
            function(retval)
                local tr = nil
                if AP and AP.DoorRandomizer and AP.DoorRandomizer.get_last_transition then
                    tr = AP.DoorRandomizer.get_last_transition()
                end

                if tr and tr.randomized and tr.randomized.was_redirected
                    and tr.at
                    and (os.clock() - tr.at) <= STALE_TRANSITION_SECONDS then
                    -- checkCarryOverNpc returns System.Void, so retval holds
                    -- leftover register garbage -- never a usable list. Read
                    -- the manager's NpcInfoList directly; the JOIN+area+
                    -- proximity filter in rewrite_npc_list picks out the
                    -- party members this hook is meant to redirect.
                    local npc_list = nil
                    local mgr = npc_mgr:get()
                    if mgr then
                        pcall(function()
                            npc_list = mgr:get_field("NpcInfoList")
                        end)
                    end

                    if npc_list and Shared.get_collection_count(npc_list) > 0 then
                        local dest = {
                            area_no = tr.randomized.area_no,
                            pos = tr.randomized.pos,
                        }
                        local player_area = tr.vanilla and tr.vanilla.area_no_old or nil
                        local player_pos = get_player_position()

                        local rewritten = rewrite_npc_list(npc_list, dest, player_area, player_pos)
                        if rewritten > 0 then
                            M.log(string.format("Rewrote %d NPCs to area %d", rewritten, dest.area_no))
                        end
                    end
                end
                return retval
            end
        )
    end)

    if not hook1_ok then
        M.log("ERROR: Failed to hook checkCarryOverNpc")
        return
    end

    hooks_installed = true
    M.log("Hooks installed successfully")
end

------------------------------------------------------------
-- Party parking: moves the farthest party members' records into another
-- area so post-transition spawn waves stay small. Parked members remain
-- in the party (JOIN) and spawn normally when the player visits the park
-- area to collect them.
------------------------------------------------------------

--- Parks all but the nearest keep_n party members into park_area.
--- @param keep_n number|nil How many to keep with the player (default 8)
--- @param park_area number|nil Explicit mAreaNo to park into; when omitted,
---        uses the most common area found on non-party NPC records.
function M.park_party(keep_n, park_area)
    keep_n = tonumber(keep_n) or 8
    local mgr = npc_mgr:get()
    if not mgr then M.log("park: NpcManager unavailable") return 0 end
    local list = nil
    pcall(function() list = mgr:get_field("NpcInfoList") end)
    if not list then M.log("park: NpcInfoList unavailable") return 0 end

    local player_pos = get_player_position()
    local join, other_areas = {}, {}
    local count = Shared.get_collection_count(list)
    for i = 0, count - 1 do
        local info = Shared.get_collection_item(list, i)
        if info then
            local state, area, pos = nil, nil, nil
            pcall(function() state = Shared.to_int(info:get_field("mLiveState")) end)
            pcall(function() area = Shared.to_int(info:get_field("mAreaNo")) end)
            pcall(function() pos = extract_vec3(info:get_field("mPos")) end)
            if state == 2 and not record_is_dead(info) then  -- JOIN: party member
                local d = math.huge
                if pos and player_pos then
                    local dx = (pos.x or 0) - (player_pos.x or 0)
                    local dy = (pos.y or 0) - (player_pos.y or 0)
                    local dz = (pos.z or 0) - (player_pos.z or 0)
                    d = dx * dx + dy * dy + dz * dz
                end
                table.insert(join, { info = info, dist = d, area = area })
            elseif area and area >= 0 then
                other_areas[area] = (other_areas[area] or 0) + 1
            end
        end
    end

    if #join <= keep_n then
        M.log(string.format("park: party=%d <= keep=%d; nothing to do", #join, keep_n))
        return 0
    end

    -- The party's own area = modal mAreaNo among JOIN records.
    local join_area_counts = {}
    for _, j in ipairs(join) do
        if j.area then
            join_area_counts[j.area] = (join_area_counts[j.area] or 0) + 1
        end
    end
    local current_area, cur_n = nil, -1
    for a, n in pairs(join_area_counts) do
        if n > cur_n then current_area, cur_n = a, n end
    end

    park_area = tonumber(park_area)
    if not park_area then
        local best_n = -1
        for a, n in pairs(other_areas) do
            if a ~= current_area and n > best_n then park_area, best_n = a, n end
        end
    end
    if not park_area then
        M.log("park: no park area could be derived -- call drap_party_park(keep_n, area_no)")
        return 0
    end
    if park_area == current_area then
        M.log(string.format("park: derived area %d equals the party's area -- pass an explicit area_no", park_area))
        return 0
    end

    -- Keep the nearest keep_n; park the rest. mCarryOverFlag routes their
    -- eventual spawn through the carry-over appear points instead of their
    -- stale coordinates.
    table.sort(join, function(a, b) return a.dist < b.dist end)
    local parked = 0
    for i = keep_n + 1, #join do
        local ok = pcall(function()
            join[i].info:set_field("mAreaNo", park_area)
            join[i].info:set_field("mCarryOverFlag", true)
        end)
        if ok then parked = parked + 1 end
    end

    M.log(string.format(
        "park: parked %d of %d party members to area %d (kept nearest %d). "
        .. "Visit that area to collect them.", parked, #join, park_area, keep_n))
    return parked
end

_G.drap_party_park = function(keep_n, park_area)
    local n = M.park_party(keep_n, park_area)
    print(string.format("[DRAP] parked %d party member(s) -- see NpcCarryOver log for details", n))
end

--- Clears mCarryOverFlag on every JOIN record (optionally only in one
--- area). Parked members keep their park area but spawn via their stored
--- position instead of the carry-over path.
function M.unpark_party(area_filter)
    area_filter = tonumber(area_filter)
    local mgr = npc_mgr:get()
    if not mgr then M.log("unpark: NpcManager unavailable") return 0 end
    local list = nil
    pcall(function() list = mgr:get_field("NpcInfoList") end)
    if not list then M.log("unpark: NpcInfoList unavailable") return 0 end

    local cleared = 0
    local count = Shared.get_collection_count(list)
    for i = 0, count - 1 do
        local info = Shared.get_collection_item(list, i)
        if info then
            local state, area, carry = nil, nil, nil
            pcall(function() state = Shared.to_int(info:get_field("mLiveState")) end)
            pcall(function() area = Shared.to_int(info:get_field("mAreaNo")) end)
            pcall(function() carry = info:get_field("mCarryOverFlag") end)
            if state == 2 and carry == true
                and (not area_filter or area == area_filter) then
                local ok = pcall(function()
                    info:set_field("mCarryOverFlag", false)
                end)
                if ok then cleared = cleared + 1 end
            end
        end
    end
    M.log(string.format("unpark: cleared carry-over flag on %d record(s)%s",
        cleared, area_filter and (" in area " .. area_filter) or ""))
    return cleared
end

_G.drap_party_unpark = function(area_filter)
    local n = M.unpark_party(area_filter)
    print(string.format("[DRAP] cleared carry-over flag on %d record(s)", n))
end

------------------------------------------------------------
-- Armed auto-park: run park_party automatically on the next entry into
-- gameplay. For saves where a crashing cutscene triggers within seconds of
-- loading, there is no time to type the park command manually -- arm this
-- at the TITLE SCREEN, then load the save.
------------------------------------------------------------

local autopark_pending = nil   -- { keep_n, park_area } or nil
local autopark_was_in_game = false

_G.drap_party_autopark = function(keep_n, park_area)
    autopark_pending = { keep_n = tonumber(keep_n) or 8,
                         park_area = tonumber(park_area) }
    print(string.format("[DRAP] auto-park ARMED: keep %d on next game entry"
        .. " -- load your save now", autopark_pending.keep_n))
end

_G.drap_party_autopark_cancel = function()
    autopark_pending = nil
    print("[DRAP] auto-park disarmed")
end

local function autopark_tick()
    local in_game = Shared.is_in_game()
    if not in_game then
        autopark_was_in_game = false
        return
    end
    if autopark_was_in_game then return end
    autopark_was_in_game = true
    if not autopark_pending then return end

    local p = autopark_pending
    autopark_pending = nil
    local n = M.park_party(p.keep_n, p.park_area)
    M.log(string.format("auto-park fired on game entry: parked %d", n))
    print(string.format("[DRAP] auto-park fired: parked %d party member(s)", n))
end

-- Own frame hook: the main loop only calls M.on_frame while in-game, which
-- would blind the menu->game edge detection above.
re.on_frame(function()
    pcall(autopark_tick)
end)

------------------------------------------------------------
-- Public API
------------------------------------------------------------

function M.get_hook_status()
    return hooks_installed
end

function M.on_frame()
    if hooks_installed or hook_install_attempted then return end
    if not Shared.is_in_game() then return end
    install_hooks()
end

return M