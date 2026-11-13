-- DRAP/effects/PharmacyKey.lua
-- Give back the pharmacy key on a new game after Medicine Run.
--
-- The key is flag 2052 (EV_PHARMACY_KEY). The game raises it in the scene
-- after Steven is beaten (1287 EV_SUPER_DIE, then 281 EV_EVENT23), and the
-- pharmacy door in Seon's opens for it (555 UNLOCK_500_1), which is how the
-- First Aid Kit is reached.
--
-- A completed main is not handed out again after a Save and Start Over, so
-- in the new world Medicine Run never replays, Steven is never placed and
-- the key never comes: the kit stays behind a locked door. When Steven's
-- check was sent in this slot and Medicine Run is done, the key is raised
-- again. Nothing new is sent by it: the key is not a check.
--
-- The First Aid Kit behind that door is not there in the new world: the
-- game places it (PREF_uOm21c, an event prop on the pharmacy counter, not an
-- inventory item) only in its own sequence after Steven's defeat, and
-- replaying that sequence pays out his PP again. Taking the prop gives Frank
-- nothing to carry; it sets 722 (EV_TELOP_FLAG11) and 2065 (EV_FIRST_AID_KIT),
-- and that record is all the kit is. So when Frank walks up to the counter
-- with the kit still not taken in this world, those two are set as the
-- pickup would. "Obtain First Aid Kit" is sent from the case's ToDo entry,
-- not from the pickup, so this sends nothing.
--
-- ScoopSanity only. Without it the story replays as the game has it and
-- Steven gives the key himself. Not in Overtime, which sets the key itself.

local Shared = require("DRAP/Shared")

local M = Shared.create_module("PharmacyKey")
M:set_throttle(1.0)

local KEY_FLAG = 2052                  -- EV_PHARMACY_KEY
local KIT_FLAG = 2065                  -- EV_FIRST_AID_KIT, the kit taken
local KIT_TELOP_FLAG = 722             -- EV_TELOP_FLAG11, set with it at the pickup
local PHARMACY_SCENE = "s500"
local COUNTER = { x = -221.54, z = -219.39 }   -- where the game puts the kit
local COUNTER_RADIUS = 3.0
local ENDING_FLAG = 312
local STEVEN_CHECK = "Clean up... Register 6!"
local CASE_SCOOP = "Medicine Run"

--- Whether the key should be raised now.
--- s: { active, scoop_sanity, past_prologue, endgame, ending_flag,
---      steven_sent, case_done, key }
--- Returns ok, reason.
function M.should_raise(s)
    if not s.active then return false, "no slot connected" end
    if s.scoop_sanity ~= true then return false, "ScoopSanity off" end
    if not s.past_prologue then return false, "prologue" end
    if s.endgame or s.ending_flag then return false, "ending reached" end
    if s.key ~= false then return false, "key held or unreadable" end
    if not s.steven_sent then return false, "Steven not beaten in this slot" end
    if not s.case_done then return false, "Medicine Run not done" end
    return true, nil
end

--- Whether the kit should be recorded as taken now.
--- k: { raise (should_raise's preconditions bar the key), key, kit, scene, dist }
function M.should_take_kit(k)
    if not k.ready then return false, "not ready" end
    if k.key ~= true then return false, "no key" end
    if k.kit ~= false then return false, "kit taken or unreadable" end
    if k.scene ~= PHARMACY_SCENE then return false, "not in Seon's" end
    if type(k.dist) ~= "number" or k.dist > COUNTER_RADIUS then return false, "not at the counter" end
    return true, nil
end

local function efm()
    return sdk.get_managed_singleton("app.solid.gamemastering.EventFlagsManager")
end

--- true / false, or nil when the flag cannot be read (a load).
local function flag(id)
    local m = efm()
    if not m then return nil end
    local ok, v = pcall(function() return m:call("evFlagCheck", id) end)
    if not ok then return nil end
    return v == true
end

local function snapshot()
    local A = package.loaded["DRAP/Activation"]
    local S = package.loaded["DRAP/scoops/ScoopState"]
    local L = package.loaded["DRAP/LocationLedger"]
    local U = package.loaded["DRAP/ScoopUnlocker"]
    local ledger_ok = L ~= nil and L.is_init ~= nil and L.is_init()
    local function call(f, ...) if not f then return nil end local ok, v = pcall(f, ...); return ok and v or nil end
    return {
        active = A ~= nil and call(A.is_active) == true,
        scoop_sanity = U ~= nil and call(U.is_scoop_sanity_enabled) == true,
        past_prologue = Shared.past_prologue(),
        endgame = S ~= nil and call(S.is_endgame_reached) == true,
        ending_flag = flag(ENDING_FLAG),
        steven_sent = ledger_ok and call(L.is_checked, STEVEN_CHECK) == true,
        case_done = U ~= nil and call(U.is_scoop_completed, CASE_SCOOP) == true,
        key = flag(KEY_FLAG),
    }
end

local function current_scene()
    local am = sdk.get_managed_singleton("app.solid.gamemastering.AreaManager")
    local p = am and Shared.safe(function() return am:get_field("CurrentLevelPath") end)
    return p and tostring(p):gsub("^SCN_", "") or nil
end

local function counter_dist()
    local pm = sdk.get_managed_singleton("app.solid.PlayerManager")
    local cond = pm and Shared.safe(function() return pm:get_field("_CurrentPlayerCondition") end)
    local pos = cond and Shared.safe(function() return cond:get_field("LastPlayerPos") end)
    if not pos then return nil end
    local x, z = Shared.safe(function() return pos.x end), Shared.safe(function() return pos.z end)
    if not (x and z) then return nil end
    return math.sqrt((x - COUNTER.x) ^ 2 + (z - COUNTER.z) ^ 2)
end

local function set_on(id)
    local m = efm()
    if not m then return false end
    return pcall(function() m:call("evFlagOn", id) end)
end

function M.on_frame()
    if not M:should_run() then return end
    if not Shared.is_in_game() then return end
    local s = snapshot()
    local ready = M.should_raise(s)
    if ready then
        if set_on(KEY_FLAG) and flag(KEY_FLAG) == true then
            M.log("Pharmacy key flag 2052 on: Steven was beaten in this slot and Medicine Run is done")
        end
        return
    end
    -- The same preconditions with the key already held.
    s.key = false
    if not M.should_raise(s) then return end
    local k = { ready = true, key = flag(KEY_FLAG), kit = flag(KIT_FLAG),
                scene = current_scene(), dist = counter_dist() }
    if not M.should_take_kit(k) then return end
    set_on(KIT_TELOP_FLAG)
    if set_on(KIT_FLAG) and flag(KIT_FLAG) == true then
        M.log("First Aid Kit taken at the pharmacy counter (722, 2065 on): the game does not place it again after Medicine Run")
    end
end

return M
