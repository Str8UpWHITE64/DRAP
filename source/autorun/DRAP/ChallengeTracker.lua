-- Dead Rising Deluxe Remaster - Challenge Tracker (module)
-- Tracks app.solid.SolidStorage.SolidSave (mSaveWork) fields for challenge-style goals

local M = {}
-- callback:
--   function(field_name, def, index, target, prev, current, threshold_id)
M.on_challenge_threshold = nil

------------------------------------------------
-- Logging
------------------------------------------------

local function log(msg)
    print("[ChallengeTracker] " .. tostring(msg))
end

------------------------------------------------
-- Config
------------------------------------------------

local SolidStorage_TYPE_NAME = "app.solid.SolidStorage"
local SaveWork_FIELD_NAME    = "mSaveWork"

-- Check interval: number of frames between checks (tune for perf)
local CHECK_INTERVAL_FRAMES  = 240

local ss_instance         = nil   -- SolidStorage singleton
local ss_td               = nil   -- SolidStorage type definition
local save_td             = nil   -- SolidSave type definition
local save_field          = nil   -- mSaveWork field
local missing_save_warned = false

local last_save_obj       = nil   -- last seen SolidSave object
local frame_counter       = 0

------------------------------------------------
-- Challenge definitions
------------------------------------------------

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

    fullMarathonDist = {
        label   = "Walk a marathon",
        targets = {
            -- TODO: fill marathon distance thresholds (e.g. 42195)
        },
        location_ids = { "Walk a marathon" },
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
        targets = { 50 },
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

    psychoKillBit = {
        label   = "Psychopath kill bitfield",
        targets = {
            -- TODO: add specific bitmask thresholds if needed
        },
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

    PsyChoKill_total = {
        label   = "Psychopath kills (total)",
        targets = {
            -- TODO: fill thresholds
        },
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
        targets = { 50 },
        location_ids = { "Jump a vehicle 50 feet" },
    },

    GolfMaxDistance = {
        label   = "Longest golf shot",
        targets = { 100 },
        location_ids = { "Hit a golf ball 100 feet" },
    },
}

-- expose so AP logic can tweak thresholds / add location_ids if needed
M.CHALLENGES = CHALLENGES

------------------------------------------------
-- Runtime state for each challenge field
------------------------------------------------

local challenge_state = {} -- name -> { field, missing_warned, last_value, reached = {bool,...} }

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

------------------------------------------------
-- SolidStorage access
------------------------------------------------

local function reset_ss_cache()
    ss_td               = nil
    save_td             = nil
    save_field          = nil
    missing_save_warned = false
    last_save_obj       = nil
    reset_challenge_progress()
end

local function ensure_solid_storage()
    -- Always fetch current singleton each frame
    local current = sdk.get_managed_singleton(SolidStorage_TYPE_NAME)

    if current ~= ss_instance then
        if ss_instance ~= nil and current == nil then
            log("SolidStorage destroyed (likely title screen).")
        elseif ss_instance == nil and current ~= nil then
            log("SolidStorage created (likely entering game).")
        elseif ss_instance ~= nil and current ~= nil then
            log("SolidStorage instance changed.")
        end

        ss_instance = current
        reset_ss_cache()
    end

    if not ss_instance then
        return false
    end

    if not ss_td then
        ss_td = ss_instance:get_type_definition()
        if not ss_td then
            log("Failed to get SolidStorage type definition from instance.")
            return false
        end
    end

    if not save_field then
        save_field = ss_td:get_field(SaveWork_FIELD_NAME)
        if not save_field then
            if not missing_save_warned then
                log("mSaveWork field not found on SolidStorage.")
                missing_save_warned = true
            end
            return false
        end
    end

    return true
end

------------------------------------------------
-- Challenge field setup
------------------------------------------------

local function ensure_challenge_fields(save_obj)
    if not save_obj then
        return false
    end

    if not save_td then
        local ok_td, td = pcall(save_obj.get_type_definition, save_obj)
        if not ok_td or not td then
            log("Failed to get SolidSave type definition from mSaveWork.")
            return false
        end
        save_td = td
        log("SolidSave type: " .. (save_td:get_full_name() or "<unknown>"))
    end

    for field_name, def in pairs(CHALLENGES) do
        local state = challenge_state[field_name]
        if not state then
            state = {
                field          = nil,
                missing_warned = false,
                last_value     = nil,
                reached        = {},
                resolve_tries  = 0,
            }

            if def.targets then
                for i = 1, #def.targets do
                    state.reached[i] = false
                end
            end

            challenge_state[field_name] = state
        end

        -- ALWAYS retry resolving the field if it's nil.
        if not state.field then
            state.resolve_tries = (state.resolve_tries or 0) + 1

            local f = save_td:get_field(field_name)
            if f then
                state.field = f
                state.missing_warned = false
            else
                -- Only warn sometimes (don’t spam).
                if (not state.missing_warned) or (state.resolve_tries % 10 == 0) then
                    log(string.format(
                        "Field '%s' not found on SolidSave (try=%d). Will retry.",
                        field_name, state.resolve_tries
                    ))
                    state.missing_warned = true
                end
            end
        end
    end

    return true
end


------------------------------------------------
-- Challenge evaluation
------------------------------------------------

local function build_threshold_id(field_name, def, i, target)
    if def.location_ids and def.location_ids[i] then
        return def.location_ids[i]
    end
    return string.format("%s_%d", field_name, target)
end

local function fire_threshold(field_name, def, state, i, target, prev, current)
    local threshold_id = build_threshold_id(field_name, def, i, target)

    -- mark reached locally (still safe to re-send on baseline; AP is idempotent)
    state.reached = state.reached or {}
    state.reached[i] = true

    if M.on_challenge_threshold then
        pcall(
            M.on_challenge_threshold,
            field_name,
            def,
            i,
            target,
            prev,
            current,
            threshold_id
        )
    end
end

local function fire_ppsticker_area_check(prev, current, level_path)
    -- Call into PPStickerTracker to send a special location check
    if AP and AP.PPStickerTracker and AP.PPStickerTracker.on_pp_sticker_area_progress then
        pcall(AP.PPStickerTracker.on_pp_sticker_area_progress, prev, current, level_path)
    end
end

local function handle_challenge_progress(field_name, def, state, save_obj)
    if not state.field then return end
    if not def.targets or #def.targets == 0 then return end

    local ok_val, v = pcall(state.field.get_data, state.field, save_obj)
    if not ok_val or type(v) ~= "number" then return end

    local current = v

    -- First successful read: store baseline AND send all satisfied thresholds.
    if state.last_value == nil then
        state.last_value = current

        -- Emit all thresholds already met (catch-up for missed AP checks)
        for i, target in ipairs(def.targets) do
            if target ~= nil and current >= target then
                if not (state.reached and state.reached[i]) then
                    fire_threshold(field_name, def, state, i, target, current, current)
                end
            end
        end
        return
    end

    local prev = state.last_value
    if current == prev then return end

    -- Only care about increases for crossing thresholds
    if current > prev then

        --Special check for rooftop PP Sticker
        if field_name == "PPPhotoCount" then
            local level_path = (AP and AP.DoorSceneLock and AP.DoorSceneLock.CurrentLevelPath) or nil
            if level_path == "s231" then
                fire_ppsticker_area_check()
            end
        end

        for i, target in ipairs(def.targets) do
            if target ~= nil then
                local already = (state.reached and state.reached[i]) and true or false
                if (not already) and (current >= target) and (prev < target) then
                    fire_threshold(field_name, def, state, i, target, prev, current)
                end
            end
        end
    end

    state.last_value = current
end


------------------------------------------------
-- Public helpers (optional)
------------------------------------------------

function M.get_state()
    return challenge_state
end

------------------------------------------------
-- Main update entrypoint
------------------------------------------------

function M.on_frame()
    frame_counter = frame_counter + 1
    if (frame_counter % CHECK_INTERVAL_FRAMES) ~= 0 then
        return
    end

    if not ensure_solid_storage() then
        return
    end

    -- Read current mSaveWork (SolidSave)
    local ok_save, save_obj = pcall(save_field.get_data, save_field, ss_instance)
    if not ok_save or save_obj == nil then
        return
    end

    -- Detect changes in the underlying save object (new game / load)
    if save_obj ~= last_save_obj then
        if last_save_obj ~= nil then
            log("SolidSave object changed (new game / load). Resetting challenge progress state.")
        else
            log("SolidSave object detected for the first time.")
        end
        last_save_obj = save_obj
        reset_challenge_progress()
    end

    if not ensure_challenge_fields(save_obj) then
        return
    end

    -- Evaluate all challenges
    for field_name, def in pairs(CHALLENGES) do
        local state = challenge_state[field_name]
        if state then
            handle_challenge_progress(field_name, def, state, save_obj)
        end
    end
end

log("Module loaded. Tracking SolidStorage.mSaveWork")

return M