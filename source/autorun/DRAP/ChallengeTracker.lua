-- Dead Rising Deluxe Remaster - Challenge Tracker (module)
-- Tracks app.solid.SolidStorage.SolidSave (mSaveWork) fields for challenge-style goals

local M = {}
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
        label   = "Player Level",
        targets = { 50 },
    },

    zombieKilledHandTotal = {
        label   = "Zombies killed (hand)",
        targets = { 100 },
    },

    zombieKilledVehicleTotal = {
        label   = "Zombies killed (vehicle)",
        targets = { 500 },
    },

    fullMarathonDist = {
        label   = "Full marathon distance",
        targets = {
            -- TODO: fill marathon distance thresholds (e.g. 42195)
        },
    },

    changeClothNum = {
        label   = "Outfit changes",
        targets = { 5, 50 },
    },

    npcnum = {
        label   = "Total survivors encountered",
        targets = { 10, 50 },
    },

    NpcJoinCount = {
        label   = "Survivors joined (ever)",
        targets = { 25 },
    },

    zombieKill_1Play = {
        label   = "Zombies killed",
        targets = { 1000, 10000, 53594 },
    },

    secretForceKill = {
        label   = "Special forces killed",
        targets = { 10 },
    },

    foodCourtDishFlag = {
        label   = "Food court dishes tried",
        targets = { 30 },
    },

    firedBulletCount = {
        label   = "Bullets fired",
        targets = { 300 },
    },

    ZombieRideDist = {
        label   = "Zombie ride distance",
        targets = { 50 },
    },

    indoorTime = {
        label   = "Indoor time",
        targets = { 300000 },
    },

    outdoorTime = {
        label   = "Outdoor time",
        targets = { 300000 },
    },

    psychoKillNum = {
        label   = "Psychopaths killed",
        targets = { 1, 10 },
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
    },

    parasolHitNum_1Play = {
        label   = "Parasol hits (1 play)",
        targets = { 10 },
    },

    enemyRPGKillNum = {
        label   = "RPG kills",
        targets = { 100 },
    },

    npcPhotoCount_1Play = {
        label   = "Survivor photos (1 play)",
        targets = { 10, 30 },
    },

    psychoPhotoCount_1Play = {
        label   = "Psychopath photos (1 play)",
        targets = { 4 },
    },

    PPPhotoCount = {
        label   = "PP stickers photographed (total)",
        targets = { 10, 100 },
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
    },

    FemaleNPCJoinMax = {
        label   = "Max female survivors escorted at once",
        targets = { 8 },
    },

    NPCProfileMax = {
        label   = "Survivor profiles obtained",
        targets = { 87 },
    },

    ResultNPCCountMax = {
        label   = "Survivors saved in result",
        targets = { 10, 50 },
    },

    PhotoPointMax = {
        label   = "Max photo PP in one shot",
        targets = { 10000 },
    },

    PhotoTargetMax = {
        label   = "Photo targets in one shot",
        targets = { 50 },
    },

    FallingHeightMax = {
        label   = "Max falling height",
        targets = { 500 },
    },

    StrikeHitMax = {
        label   = "Zombie bowling",
        targets = { 10 },
    },

    VehicleJumpDistanceMax = {
        label   = "Vehicle jump distance",
        targets = { 50 },
    },

    GolfMaxDistance = {
        label   = "Longest golf shot",
        targets = { 100 },
    },
}

-- expose so AP logic can tweak thresholds if needed
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
        else
            log("Found SolidStorage.mSaveWork field.")
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
            }

            if def.targets then
                for i = 1, #def.targets do
                    state.reached[i] = false
                end
            end

            challenge_state[field_name] = state
        end

        if not state.field and not state.missing_warned then
            local f = save_td:get_field(field_name)
            if not f then
                state.missing_warned = true
                log("Field '" .. field_name .. "' not found on SolidSave.")
            else
                state.field = f
                log("Now tracking SolidSave field '" .. field_name .. "'.")
            end
        end
    end

    return true
end

------------------------------------------------
-- Challenge evaluation
------------------------------------------------

local function handle_challenge_progress(field_name, def, state, save_obj)
    if not state.field then
        return
    end
    if not def.targets or #def.targets == 0 then
        return
    end

    local ok_val, v = pcall(state.field.get_data, state.field, save_obj)
    if not ok_val or type(v) ~= "number" then
        return
    end

    local current = v

    -- First sample for this save: just store and bail
    if state.last_value == nil then
        state.last_value = current
        return
    end

    local prev = state.last_value
    if current == prev then
        return
    end

    -- Only care about increases for challenge thresholds
    if current > prev then
        for i, target in ipairs(def.targets) do
            if target ~= nil and not state.reached[i] and current >= target and prev < target then
                local label = def.label or field_name
                log(string.format(
                    "Challenge reached: %s >= %d (field=%s, %d -> %d)",
                    label, target, field_name, prev, current
                ))
                state.reached[i] = true

                -- AP hook
                if M.on_challenge_threshold then
                    pcall(M.on_challenge_threshold,
                        field_name, def, i, target, prev, current)
                end
            end
        end
    end

    state.last_value = current
end

------------------------------------------------
-- Public helpers (optional)
------------------------------------------------

-- If you ever want to query from AP-side:
function M.get_state()
    return challenge_state
end

------------------------------------------------
-- Main update entrypoint (called by central on_frame)
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