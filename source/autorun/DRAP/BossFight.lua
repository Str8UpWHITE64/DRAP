-- DRAP/BossFight.lua
-- Whether a psychopath fight is on, so nothing DRAP does moves Frank out of it.
--
-- A warp out of a boss fight can leave the psychopath despawned and the fight
-- unwinnable, so the Teleport Trap waits (stays banked) and the manual warps
-- refuse while this says a fight is on.
--
-- The signal is EnemyManager's active psychopath list: a fight is on while
-- any psychopath in it is alive (HP above 0, not dead). The list holds only
-- the psychopaths placed in the loaded area, and a defeated one stays in it
-- at 0 HP for a while, which is why HP is read and not just the count.
-- Polled from the frame, no hook.
--
-- It also holds after the last one goes down, in the same area, until the
-- defeat scene has played (or 30 s pass with none): the defeat event moves
-- Frank back to the fight's area, so a warp fired the moment the psychopath
-- dies is undone and the Teleport Trap is wasted. PlayerReady covers the
-- scene itself.

local Shared = require("DRAP/Shared")

local M = {}
local log = Shared.create_logger("BossFight")

local EM_TYPE = "app.solid.EnemyManager"
local HPC_TYPE = "app.solid.HitPointController"
local CHECK_EVERY = 0.25

-- Psychopaths that never count. The convicts (Em4D) roam Leisure Park and stay
-- spawned when Frank leaves, so a warp away loses nothing, and counting them
-- held every trap for as long as he was in the park.
local NOT_A_FIGHT = {
    [0x4D] = "the convicts",
}
local AFTER_FIGHT_HOLD = 30.0
local ETM_TYPE = "app.solid.gamemastering.EventTimelineManager"
local AM_TYPE = "app.solid.gamemastering.AreaManager"

local active = false
local who = nil             -- e.g. "Em45" (kinds only, so a hold logs once)
local next_check = 0
local ended_at = nil        -- os.clock() of the last on -> off edge
local ended_level = nil     -- the scene it ended in
local scene_since_end = false   -- a cutscene has started since then

local function cutscene_playing()
    local etm = sdk.get_managed_singleton(ETM_TYPE)
    return etm ~= nil and Shared.safe(function() return etm:call("isEventPlaying") end) == true
end

local function level_path()
    local am = sdk.get_managed_singleton(AM_TYPE)
    local p = am and Shared.safe(function() return am:get_field("CurrentLevelPath") end)
    return p and tostring(p) or nil
end

local function hit_points(ctrl)
    local hpc = Shared.safe(function() return ctrl:call("get_HitPoint") end)
    if not hpc then
        local go = Shared.safe(function() return ctrl:call("get_GameObject") end)
        hpc = go and Shared.safe(function()
            return go:call("getComponent(System.Type)", sdk.typeof(HPC_TYPE))
        end)
    end
    if not hpc then return nil end
    local hp = Shared.to_int(Shared.safe(function() return hpc:call("get_CurrentHitPoint") end))
    local dead = Shared.safe(function() return hpc:call("get_IsDead") end) == true
    return hp, dead
end

--- The living psychopaths in the loaded area: kinds, and kinds with HP.
local function living_psychos()
    local em = sdk.get_managed_singleton(EM_TYPE)
    if not em then return {}, {} end
    local list = Shared.safe(function() return em:call("get_ActivePsychoList") end)
    if not list then return {}, {} end
    local out, detail = {}, {}
    for _, ctrl in Shared.iter_collection(list) do
        if ctrl then
            local hp, dead = hit_points(ctrl)
            -- An unreadable HP counts as alive: refusing a warp by mistake
            -- costs a moment, warping out of a fight can cost the run.
            local kind = Shared.to_int(Shared.safe(function() return ctrl:call("get_KindID") end))
            if not dead and (hp == nil or hp > 0) and not (kind and NOT_A_FIGHT[kind]) then
                out[#out + 1] = string.format("Em%X", kind or 0)
                detail[#detail + 1] = string.format("Em%X hp %s", kind or 0, tostring(hp))
            end
        end
    end
    return out, detail
end

local function update()
    local now_active, label, detail = false, nil, nil
    if Shared.is_in_game() then
        local alive, hp = living_psychos()
        if #alive > 0 then
            now_active, label, detail = true, table.concat(alive, ", "), table.concat(hp, ", ")
        end
    end
    if now_active ~= active then
        if now_active then
            log("boss fight on: " .. detail)
        else
            log("boss fight off" .. (who and (" (was " .. who .. ")") or ""))
            ended_at, ended_level, scene_since_end = os.clock(), level_path(), false
        end
    end
    active, who = now_active, label
    if ended_at and not scene_since_end and cutscene_playing() then
        scene_since_end = true
    end
end

re.on_frame(function()
    local now = os.clock()
    if now < next_check then return end
    next_check = now + CHECK_EVERY
    pcall(update)
end)

--- True while a living psychopath is in the loaded area.
function M.active()
    return active
end

--- True after a fight ended, while Frank is still in that area and the
--- defeat scene has not started yet (at most AFTER_FIGHT_HOLD seconds).
local function just_ended()
    if not ended_at or scene_since_end then return false end
    if os.clock() - ended_at >= AFTER_FIGHT_HOLD then return false end
    return level_path() == ended_level
end

--- Why a warp has to wait, or nil when it need not.
function M.blocked_by()
    if not active then
        if just_ended() then return "boss fight just ended" end
        return nil
    end
    return "boss fight (" .. tostring(who) .. ")"
end

_G.drap_boss_fight = function()
    pcall(update)
    log(string.format("active=%s  %s", tostring(active), tostring(who)))
    return active
end

return M
