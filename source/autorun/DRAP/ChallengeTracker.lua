-- DRAP/ChallengeTracker.lua
-- Tracks app.solid.SolidStorage.SolidSave (mSaveWork) fields for challenge-style goals

local Shared = require("DRAP/Shared")

local M = Shared.create_module("ChallengeTracker")

------------------------------------------------------------
-- Configuration
------------------------------------------------------------

local CHECK_INTERVAL_FRAMES = 240

------------------------------------------------------------
-- Singleton Manager
------------------------------------------------------------

local ss_mgr = M:add_singleton("ss", "app.solid.SolidStorage")

------------------------------------------------------------
-- Challenge Definitions
------------------------------------------------------------

local CHALLENGES = {
    PlayerLevel = {
        label   = "Reach Level",
        targets = { 50 },
        location_ids = { "Reach max level" },
    },
    zombieKilledHandTotal = {
        label   = "Zombie kills by hand",
        targets = { 100 },
        location_ids = { "Kill 500 zombies by hand" },
    },
    zombieKilledVehicleTotal = {
        label   = "Zombie Vehicle kills",
        targets = { 500 },
        location_ids = { "Kill 500 zombies by vehicle" },
    },
    changeClothNum = {
        label   = "Outfit changes",
        targets = { 5, 50 },
        location_ids = { "Change into 5 new outfits", "Change into 50 new outfits" },
    },
    npcnum = {
        label   = "Total survivors encountered",
        targets = { 10, 50 },
        location_ids = { "Encounter 10 survivors", "Encounter 50 survivors" },
    },
    NpcJoinCount = {
        label   = "Survivors joined (ever)",
        targets = { 25 },
        location_ids = { "Get 50 survivors to join" },
    },
    zombieKill_1Play = {
        label   = "Zombies killed",
        targets = { 1000, 10000, 53594 },
        location_ids = { "Kill 1000 zombies", "Kill 10000 zombies", "Zombie Genocide" },
    },
    secretForceKill = {
        label   = "Special forces killed",
        targets = { 10 },
        location_ids = { "Kill 10 Special Forces" },
    },
    foodCourtDishFlag = {
        label   = "Food court dishes destroyed",
        targets = { 262143 },
        location_ids = { "Destroy 30 dishes in the Food Court" },
    },
    firedBulletCount = {
        label   = "Bullets fired",
        targets = { 300 },
        location_ids = { "Fire 300 Bullets" },
    },
    ZombieRideDist = {
        label   = "Zombie ride distance",
        targets = { 1000 },
        location_ids = { "Ride zombies for 50 feet" },
    },
    indoorTime = {
        label   = "Indoor time",
        targets = { 300000 },
        location_ids = { "Spend 12 hours indoors" },
    },
    outdoorTime = {
        label   = "Outdoor time",
        targets = { 300000 },
        location_ids = { "Spend 12 hours outdoors" },
    },
    psychoKillNum = {
        label   = "Psychopaths killed",
        targets = { 1, 8 },
        location_ids = { "Kill 1 psychopath", "Kill 8 psychopaths" },
    },
    cultKillNum = {
        label   = "Cultists killed",
        targets = { 100 },
        location_ids = { "Kill 100 cultists" },
    },
    parasolHitNum_1Play = {
        label   = "Parasol hits (1 play)",
        targets = { 10 },
        location_ids = { "Hit 10 zombies with a parasol" },
    },
    enemyRPGKillNum = {
        label   = "RPG kills",
        targets = { 100 },
        location_ids = { "Kill 100 zombies with an RPG" },
    },
    npcPhotoCount_1Play = {
        label   = "Survivor photos (1 play)",
        targets = { 10, 30 },
        location_ids = { "Photograph 10 survivors", "Photograph 30 survivors" },
    },
    psychoPhotoCount_1Play = {
        label   = "Psychopath photos (1 play)",
        targets = { 4 },
        location_ids = { "Photograph 4 psychopaths" },
    },
    PPPhotoCount = {
        label   = "PP stickers photographed (total)",
        targets = { 10, 100 },
        location_ids = { "Photograph 10 PP Stickers", "Photograph all PP Stickers" },
    },
    NPCJoinMax = {
        label   = "Max survivors escorted at once",
        targets = { 8 },
        location_ids = { "Escort 8 survivors at once" },
    },
    FemaleNPCJoinMax = {
        label   = "Max female survivors escorted at once",
        targets = { 8 },
        location_ids = { "Frank the pimp" },
    },
    NPCProfileMax = {
        label   = "Survivor profiles obtained",
        targets = { 87 },
        location_ids = { "Build a profile for 87 survivors" },
    },
    ResultNPCCountMax = {
        label   = "Survivors saved in result",
        targets = { 10, 50 },
        location_ids = { "Save 10 survivors", "Save 50 survivors" },
    },
    PhotoPointMax = {
        label   = "Max photo PP in one shot",
        targets = { 10000 },
        location_ids = { "Get 10000 PP in one photo" },
    },
    PhotoTargetMax = {
        label   = "Photo targets in one shot",
        targets = { 50 },
        location_ids = { "Get 50 targets in one photo" },
    },
    FallingHeightMax = {
        label   = "Max falling height",
        targets = { 500 },
        location_ids = { "Fall from a high height" },
    },
    StrikeHitMax = {
        label   = "Zombie bowling",
        targets = { 10 },
        location_ids = { "Bowl over 10 zombies" },
    },
    VehicleJumpDistanceMax = {
        label   = "Vehicle jump distance",
        targets = { 1000 },
        location_ids = { "Jump a vehicle 50 feet" },
    },
    GolfMaxDistance = {
        label   = "Longest golf shot",
        targets = { 10000 },
        location_ids = { "Hit a golf ball 100 feet" },
    },
}

M.CHALLENGES = CHALLENGES

------------------------------------------------------------
-- Internal State
------------------------------------------------------------

local challenge_state = {}
local save_td = nil
local last_save_obj = nil
local frame_counter = 0

------------------------------------------------------------
-- Public Callback
------------------------------------------------------------

M.on_challenge_threshold = nil

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function build_threshold_id(field_name, def, i, target)
    if def.location_ids and def.location_ids[i] then
        return def.location_ids[i]
    end
    return string.format("%s_%d", field_name, target)
end

local function fire_threshold(field_name, def, state, i, target, prev, current)
    local threshold_id = build_threshold_id(field_name, def, i, target)
    state.reached = state.reached or {}
    state.reached[i] = true

    if M.on_challenge_threshold then
        pcall(M.on_challenge_threshold, field_name, def, i, target, prev, current, threshold_id)
    end
end

local function send_pp_sticker_100()
    if AP and AP.PPStickerTracker and AP.PPStickerTracker.send_pp_sticker_100 then
        pcall(AP.PPStickerTracker.send_pp_sticker_100)
    end
end

local function reset_challenge_progress()
    for _, state in pairs(challenge_state) do
        state.last_value = nil
        if state.reached then
            for i = 1, #state.reached do
                state.reached[i] = false
            end
        end
    end
end

local function ensure_challenge_fields(save_obj)
    if not save_obj then return false end

    if not save_td then
        local ok_td, td = pcall(save_obj.get_type_definition, save_obj)
        if not ok_td or not td then return false end
        save_td = td
        M.log("SolidSave type: " .. (save_td:get_full_name() or "<unknown>"))
    end

    for field_name, def in pairs(CHALLENGES) do
        local state = challenge_state[field_name]
        if not state then
            state = { field = nil, missing_warned = false, resolve_tries = 0, reached = {} }
            if def.targets then
                for i = 1, #def.targets do state.reached[i] = false end
            end
            challenge_state[field_name] = state
        end

        if not state.field then
            state.resolve_tries = (state.resolve_tries or 0) + 1
            local f = save_td:get_field(field_name)
            if f then
                state.field = f
                state.missing_warned = false
            elseif not state.missing_warned or (state.resolve_tries % 10 == 0) then
                M.log(string.format("Field '%s' not found (try=%d)", field_name, state.resolve_tries))
                state.missing_warned = true
            end
        end
    end
    return true
end

local function handle_challenge_progress(field_name, def, state, save_obj)
    if not state.field or not def.targets or #def.targets == 0 then return end

    local ok_val, v = pcall(state.field.get_data, state.field, save_obj)
    if not ok_val or type(v) ~= "number" then return end

    local current = v

    if state.last_value == nil then
        state.last_value = current
        for i, target in ipairs(def.targets) do
            if target and current >= target and not (state.reached and state.reached[i]) then
                fire_threshold(field_name, def, state, i, target, current, current)
            end
        end
        return
    end

    local prev = state.last_value
    if current == prev then return end

    if current > prev then
        if field_name == "PPPhotoCount" then
            local level_path = AP and AP.DoorSceneLock and AP.DoorSceneLock.CurrentLevelPath
            local area_index = AP and AP.DoorSceneLock and AP.DoorSceneLock.CurrentAreaIndex
            if level_path == "s231" or area_index == 535 then
                send_pp_sticker_100()
            end
        end

        for i, target in ipairs(def.targets) do
            if target then
                local already = state.reached and state.reached[i]
                if not already and current >= target and prev < target then
                    fire_threshold(field_name, def, state, i, target, prev, current)
                end
            end
        end
    end

    state.last_value = current
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

function M.get_state()
    return challenge_state
end

------------------------------------------------------------
-- Per-frame Update
------------------------------------------------------------

ss_mgr.on_instance_changed = function(old, new)
    save_td = nil
    last_save_obj = nil
    reset_challenge_progress()
end

function M.on_frame()
    frame_counter = frame_counter + 1
    if (frame_counter % CHECK_INTERVAL_FRAMES) ~= 0 then return end

    local ss = ss_mgr:get()
    if not ss then return end

    local save_field = ss_mgr:get_field("mSaveWork")
    if not save_field then return end

    local ok_save, save_obj = pcall(save_field.get_data, save_field, ss)
    if not ok_save or save_obj == nil then return end

    if save_obj ~= last_save_obj then
        if last_save_obj then
            M.log("SolidSave object changed. Resetting progress.")
        else
            M.log("SolidSave object detected.")
        end
        last_save_obj = save_obj
        reset_challenge_progress()
    end

    if not ensure_challenge_fields(save_obj) then return end

    for field_name, def in pairs(CHALLENGES) do
        local state = challenge_state[field_name]
        if state then
            handle_challenge_progress(field_name, def, state, save_obj)
        end
    end
end

return M