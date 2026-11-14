-- DRAP/CustomStickers.lua
-- Custom PP stickers: our own photo checks, placed by a data table.
--
-- How the game does stickers (measured in game):
--   * A sticker is spawned from its area's item layout through ItemManager.instantiateOmItem with class "uOm13f"
--     (prefab Item/Prefab/OmItem/PREF_uOm13f.pfb). A bare prefab instantiate lacks the uOm13f class and never works.
--     The area owns the object: an area change releases it, so ours are spawned again whenever they are missing.
--   * The photo is credited to photoHitObj.mScoopId (the hit objects behind SolidModelAttribute.mPhotoHitObjList),
--     not to the sticker's mPhotoId. The hit objects come from the PhotoSealUserData row whose mPhotoId matches.
--   * Collected = PhotoRating.mScoopTotalCount[id] >= uOm13f.mMaxCount, read every frame by the sticker itself.
--
-- What we do:
--   * Every custom sticker uses one spare scoop id (229, outside the 100 vanilla ids 128..227). A seal row for 229
--     points at sticker 164's hit data (164 is centred: sphere offset ~0, no view rotation; 174 sits 0.85 m off axis
--     and is never rated from the front). Each spawned sticker then gets its OWN copies of those hit objects with
--     mScoopId = 229, so a photo of it touches no vanilla sticker, no PP photo counter and so no "PP Sticker 100".
--   * Which sticker was photographed comes from the rating itself: PhotoRating.mTarget[i].FuncParam is the photographed
--     GameObject. Only a rating that started after the shot counts (the lists keep the last photo's rows; the game
--     zeroes mTargetNum when a rating starts, so rows past mTargetNum are stale), and only rows i < mTargetNum.
--   * PP: 1 per photo (extra stickers must not move levels). A non-PP id is paid its scoop points
--     unscaled, and a 0-point target gets the game's 999 floor, so the spare id's points are set to 1; DRAP adds none.
--   * Uncollected stickers hold mMaxCount at 0xFFFF so the shared count never flips them; a detected one gets
--     mMaxCount 0 and plays the game's own collected animation. The spare count is reset to 0 after each photo.
--   * Collected = the location is checked in the ledger. Collected stickers are spawned too, with no photo target, and show greyed out.
--   * Never move a spawned sticker by its transform; spawn it where it belongs.
--
-- One more sticker is always on, on every slot: a visible marker on the Rooftop vent (photo id 174, "Photograph
-- PP Sticker 100"). It is a visual only: it keeps vanilla id 174 as its scoop id, so the game's own count makes it glow
-- until the vent is photographed and grey after, reloads included. Its hit list is emptied, so it is no second photo
-- target; the vanilla vent object stays the one that credits 174.
--
-- The extra stickers are off unless the slot asks (slot_data.extra_pp_stickers). Camera Item needs nothing here: no Camera, no photo.
-- Console (testing): drap_extra_pp_stickers(true) / drap_extra_pp_stickers_reset() (offline, no seed or server),
-- drap_cstick_enable(true), drap_cstick_add("s231", x, y, z, yaw, n), drap_cstick_status().
-- Test spots (drap_cstick_spot, drap_cstick_remove) are test stickers: they work without a slot or test
-- mode, a photo marks them in the test file and never sends a check. An edit or removal despawns the old one.

local Shared = require("DRAP/Shared")
local SharedData = require("DRAP/SharedData")

local M = Shared.create_module("CustomStickers")

local SPARE_ID = 229
local TEMPLATE_ID = 164
local CLASS = "uOm13f"
local HOLD_MAX = 0xFFFF
-- PP: the game pays our id its scoop points unscaled (a flat 5000 at 72% framing), and pays 999 when they are
-- 0. Extra stickers are worth nothing towards levels, so every score is 1 and DRAP grants nothing;
-- the camera rate is still logged.
local POINTS = 1
local PP_BASE_FALLBACK = 5000
local RESPAWN_SETTLE_S = 0.5     -- after an area change, before spawning
local LOAD_QUIET_S = 0.5         -- and the area's Om set must have stayed loaded this long
local FIND_TIMEOUT_S = 10.0      -- a requested sticker must appear within this
local OM_LIST_WAIT_S = 20.0      -- how long to wait for the area's Om list before using the player's folder
local MAINT_INTERVAL_S = 0.5     -- steady state
local FAST_INTERVAL_S = 0.1      -- while an area's stickers are still being spawned
-- PP (the camera's percentage readout x 5000): getPpScoreRate = (share of the photo sphere's screen rect inside the
-- frame) x (viewing-angle factor) x (size factor: 0 below a minimum size, partial up to the camera's good size).
-- Keep the template's own sphere so frame coverage matches a vanilla sticker (a quarter-radius sphere sat
-- fully in frame and scored 5000 where the vanilla stand-in scored 2294). The minimum size is the one difference:
-- the game uses 0.4096 for ids 128..227 and 0.0256 for ours (ratingSub), which only matters for far, tiny shots.
local RADIUS_SCALE = 1.0
-- Photo zone direction (PhotoRating.getPpScoreRate): a hit scores only when the camera sits inside a cone around the
-- hit's WorldVector, which is the sticker's own face direction (its Z axis, so it follows turn, tilt and roll) turned
-- further by the hit's mRotX / mRotY. With fan = mFanRate the score is full within acos(cos^2(fan / 4)) of that
-- direction, falls off linearly, and is 0 past fan / 2. The template's fan is 1.0: full within 20 degrees, 0 past 29,
-- so a ceiling sticker, seen 40 to 60 degrees off its face from where a player stands, never rated. Every copy gets
-- PHOTO_FAN instead: full within 58 degrees, 0 past 86.
local PHOTO_FAN = 3.0

-- the vent marker (see above): Visual = the vanilla photo id it stands for
local VISUAL_ROWS = {
    -- on the vent opening's outer face, where the Security Room vent door lands the player, facing them
    { Number = 174001, Visual = 174, Area = "s231", Pos = { x = 171.21, y = 10.84, z = 111.21 }, Yaw = 0.9035, Pitch = 0, Roll = 0 },
}

local enabled = false
local debug_enabled = nil        -- console override
local debug_rows = {}            -- console-added table rows
local doomed = {}                -- removed or edited stickers still to take away: { om, go, known, pos, t }

-- number -> { row, go, om, attr, addr, state = "pending"|"live", t, hits_ok, collected }
local live = {}
local go_to_number = {}          -- GameObject address -> number
local area_index, area_since = nil, 0
local next_maint = 0
local want_fast = false          -- some sticker of this area is not live yet
local quiet_since = nil          -- since when the area's Om set has not been loading
local area_timing = nil          -- per area change: when it was seen, when loading went quiet, first spawn
local seal_ready = false
local photo = { mode = nil, armed = false, stale = {} }
local stats = { spawned = 0, respawned = 0, detected = 0, photos = 0, stale_skipped = 0 }

M.on_check = nil                 -- function(location_name, number), wired in AP_DRDR_main

------------------------------------------------------------
-- small helpers
------------------------------------------------------------

local function pc(fn, ...) local ok, a = pcall(fn, ...); if ok then return a end return nil end
local function num(v) if v == nil then return nil end if type(v) == "number" then return v end return tonumber(tostring(v)) end
local function fld(o, n) if not o then return nil end return pc(function() return o:get_field(n) end) end
local function items(list)
    local out = {}
    if not list then return out end
    local n = num(pc(function() return list:call("get_Count") end)) or num(pc(function() return list:get_size() end)) or 0
    for i = 0, n - 1 do
        out[#out + 1] = pc(function() return list:call("get_Item", i) end) or pc(function() return list:get_element(i) end)
    end
    return out
end
local function addr(o) return o and pc(function() return o:get_address() end) end
local function go_of(c) return c and pc(function() return c:call("get_GameObject") end) end
local function go_tr(go) return go and pc(function() return go:call("get_Transform") end) end
local function go_pos(go)
    local t = go_tr(go)
    local p = t and pc(function() return t:call("get_Position") end)
    return p and { x = p.x, y = p.y, z = p.z } or nil
end
local function comp(go, tn) return go and pc(function() return go:call("getComponent(System.Type)", sdk.typeof(tn)) end) end
local function dist(a, b) local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z; return math.sqrt(dx * dx + dy * dy + dz * dz) end

local function photo_mgr() return sdk.get_managed_singleton("app.solid.gamemastering.PhotoManager") end
local function rating() return fld(photo_mgr(), "mRating") end
local function area_mgr() return sdk.get_managed_singleton("app.solid.gamemastering.AreaManager") end

local function set_count(id, v)
    local arr = fld(rating(), "mScoopTotalCount")
    return arr and pc(function() arr:write_dword(0x20 + 4 * id, v); return true end) or false
end
local function get_count(id)
    local arr = fld(rating(), "mScoopTotalCount")
    return arr and num(pc(function() return arr:read_dword(0x20 + 4 * id) end)) or nil
end

local function table_on()
    if debug_enabled ~= nil then return debug_enabled end
    if not enabled then return false end
    local Activation = package.loaded["DRAP/Activation"]
    return Activation ~= nil and Activation.is_active ~= nil and Activation.is_active() == true
end
local function visual_on()
    local Activation = package.loaded["DRAP/Activation"]
    return Activation ~= nil and Activation.is_active ~= nil and Activation.is_active() == true
end
-- test spots run on their own, with the table off
local function is_on() return table_on() or visual_on() or #debug_rows > 0 or next(doomed) ~= nil end

------------------------------------------------------------
-- the table
------------------------------------------------------------

-- rows: { Number, LocationName, Area = "s231", Pos = {x,y,z}, Yaw, Pitch, Roll } (radians)
local function rows()
    local out = {}
    if table_on() then
        for _, r in ipairs(SharedData.custom_stickers and SharedData.custom_stickers() or {}) do out[#out + 1] = r end
    end
    if visual_on() then
        for _, r in ipairs(VISUAL_ROWS) do out[#out + 1] = r end
    end
    for _, r in ipairs(debug_rows) do out[#out + 1] = r end
    return out
end

local function area_index_of(code)
    local info = Shared.SCENE_INFO and Shared.SCENE_INFO[code]
    return info and info.index or nil
end

-- Offline testing (drap_extra_pp_stickers): no slot, so no ledger to remember what was photographed. Debug mode keeps
-- its own list in reframework/data/DRAP_extra_stickers_test.json; drap_extra_pp_stickers_reset() clears it.
local TEST_FILE = "DRAP_extra_stickers_test.json"
local test_collected = nil
local function test_load()
    if test_collected then return test_collected end
    local d = pc(function() return json.load_file(TEST_FILE) end)
    test_collected = (type(d) == "table" and type(d.collected) == "table") and d.collected or {}
    return test_collected
end
local function test_save()
    pc(function() json.dump_file(TEST_FILE, { collected = test_collected or {} }) end)
end

local function is_collected(r)
    if r.Visual then return false end    -- the game's own count greys it
    if (debug_enabled or r.Test) and test_load()[tostring(r.Number)] then return true end
    local Ledger = package.loaded["DRAP/LocationLedger"]
    if r.LocationName and Ledger and Ledger.is_init and Ledger.is_init() and Ledger.is_checked then
        return Ledger.is_checked(r.LocationName) == true
    end
    return false
end

------------------------------------------------------------
-- seal row and own hit copies
------------------------------------------------------------

local function seal_rows(seal_ud) return items(fld(seal_ud, "mPhotoSealList")) end
local function seal_row(seal_ud, id)
    for _, r in ipairs(seal_rows(seal_ud)) do if num(fld(r, "mPhotoId")) == id then return r end end
    return nil
end

-- the spare id's scoop points: a copy of the template sticker's (score per photo kind, trend, message)
local SCOOP_FIELDS = { "mNormal", "mAttack", "mDamage", "mAmputate", "mDie", "mRelive", "mPanic", "mLaugh", "mSad",
                       "mAngry", "mBucket", "mPanty", "mBreast", "mSpecial", "mMsgId", "mTrNormal", "mTrAttack",
                       "mTrDamage", "mTrAmputate", "mTrDie", "mTrRelive", "mTrPanic", "mTrLaugh", "mTrSad", "mTrAngry",
                       "mTrBucket", "mTrPanty", "mTrBreast", "mTrSpecial" }
local scoop_ready = false
local pp_base = nil              -- the template's mNormal (5000), read before the spare entry is zeroed
local function ensure_scoop_points()
    if scoop_ready then return true end
    local pm = photo_mgr()
    local src = pm and pc(function() return pm:call("getScoopData(System.UInt16)", TEMPLATE_ID) end)
    local dst = pm and pc(function() return pm:call("getScoopData(System.UInt16)", SPARE_ID) end)
    if not src or not dst then return false end
    pp_base = num(fld(src, "mNormal")) or PP_BASE_FALLBACK
    for _, f in ipairs(SCOOP_FIELDS) do
        local v = fld(src, f)
        -- scores zeroed (DRAP pays the vanilla way, see PP above); trends and the message stay the template's
        if f:sub(1, 3) ~= "mTr" and f ~= "mMsgId" then v = POINTS end
        if v ~= nil then pc(function() dst:set_field(f, v) end) end
    end
    scoop_ready = num(fld(dst, "mNormal")) == POINTS
    M.log(string.format("Scoop points for spare id %d copied from %d (normal %s): %s", SPARE_ID, TEMPLATE_ID,
        tostring(fld(dst, "mNormal")), tostring(scoop_ready)))
    return scoop_ready
end

-- Loading another save rebuilds the spare id's scoop data with 0 points, and the game pays a 0-point target its
-- 999 floor. So the points are checked on the live object, not trusted to a flag, and set again when reset.
local function verify_scoop_points()
    if not scoop_ready then return ensure_scoop_points() end
    local pm = photo_mgr()
    local dst = pm and pc(function() return pm:call("getScoopData(System.UInt16)", SPARE_ID) end)
    if dst and num(fld(dst, "mNormal")) ~= POINTS then
        scoop_ready = false
        M.log("Scoop points for spare id " .. SPARE_ID .. " were reset; setting them again")
        return ensure_scoop_points()
    end
    return true
end

-- the PhotoSealUserData is the shared resource every sticker's SolidModelAttribute points at
local function ensure_seal_row(attr)
    ensure_scoop_points()
    if seal_ready then return true end
    local seal_ud = fld(attr, "mPhotoRatingData")
    if not seal_ud then return false end
    if seal_row(seal_ud, SPARE_ID) then seal_ready = true; return true end
    local tmpl = seal_row(seal_ud, TEMPLATE_ID)
    local list = fld(seal_ud, "mPhotoSealList")
    if not tmpl or not list then return false end
    local r = sdk.create_instance("solid.MT2RE.uPhotoSealData")
    if not r then return false end
    r = r:add_ref()
    r:set_field("mPhotoRatingData", fld(tmpl, "mPhotoRatingData"))
    r:set_field("mDispFlag", 0)
    r:set_field("mPhotoId", SPARE_ID)
    r:set_field("mScoopId", SPARE_ID)
    r:set_field("mCount", num(fld(tmpl, "mCount")) or 1)
    local ok = pcall(function() list:call("Add", r) end)
    seal_ready = ok
    M.log(string.format("Seal row for spare id %d on %d's hit data: %s", SPARE_ID, TEMPLATE_ID, tostring(ok)))
    return ok
end

local HIT_FIELDS = { "mJntOfs", "mFanRate", "mRotX", "mRotY", "mRadius", "mDistance", "mScoopId2", "mScoopId", "mBeFlag", "mJointNo", "mKind" }
local function copy_hit(e)
    local c = pc(function() return e:call("MemberwiseClone") end)
    if not c then
        c = sdk.create_instance("solid.MT2RE.photoHitObj")
        if c then for _, f in ipairs(HIT_FIELDS) do local v = fld(e, f); if v ~= nil then pc(function() c:set_field(f, v) end) end end end
    end
    return c and (pc(function() return c:add_ref() end) or c)
end

-- a list of our own hit objects for this sticker: a shallow copy of its list with a cloned backing array whose
-- slots point at copies carrying the spare id (creating a List<photoHitObj> directly returns nil). Each copy faces
-- the sticker's own way (no extra rotation unless the row asks: PhotoPitch / PhotoYaw, radians) with the wide fan.
local function own_hits(attr, r)
    local src = fld(attr, "mPhotoHitObjList")
    local elems = items(src)
    if #elems == 0 then return false end
    local first = num(fld(elems[1], "mScoopId"))
    if first == SPARE_ID then
        -- already ours, unless it is still the shared template list (then its id would be the template's)
        return true
    end
    local list = pc(function() return src:call("MemberwiseClone") end)
    local backing = fld(src, "_items")
    local arr = backing and pc(function() return backing:call("Clone") end)
    if not list or not arr then return false end
    list = pc(function() return list:add_ref() end) or list
    arr = pc(function() return arr:add_ref() end) or arr
    for i, e in ipairs(elems) do
        local c = copy_hit(e)
        if not c then return false end
        pc(function() c:set_field("mScoopId", SPARE_ID) end)
        local rad = num(fld(e, "mRadius"))
        if rad then pc(function() c:set_field("mRadius", rad * RADIUS_SCALE) end) end
        pc(function() c:set_field("mFanRate", PHOTO_FAN) end)
        pc(function() c:set_field("mRotX", num(r and r.PhotoPitch) or 0.0) end)
        pc(function() c:set_field("mRotY", num(r and r.PhotoYaw) or 0.0) end)
        local put = pc(function() arr:call("SetValue(System.Object, System.Int32)", c, i - 1); return true end)
        if not put then return false end
    end
    if not pc(function() list:set_field("_items", arr); return true end) then return false end
    if not pc(function() attr:set_field("mPhotoHitObjList", list); return true end) then return false end
    local now = items(fld(attr, "mPhotoHitObjList"))
    return #now == #elems and num(fld(now[1], "mScoopId")) == SPARE_ID and num(fld(elems[1], "mScoopId")) == first
end

-- a visual marker takes part in no photo: its own hit list, with no entries (never the shared one)
local function no_hits(attr)
    local src = fld(attr, "mPhotoHitObjList")
    if not src then return true end
    if #items(src) == 0 then return true end
    local list = pc(function() return src:call("MemberwiseClone") end)
    local backing = fld(src, "_items")
    local arr = backing and pc(function() return backing:call("Clone") end)
    if not list or not arr then return false end
    list = pc(function() return list:add_ref() end) or list
    arr = pc(function() return arr:add_ref() end) or arr
    pc(function() list:set_field("_items", arr) end)
    pc(function() list:set_field("_size", 0) end)
    pc(function() attr:set_field("mPhotoHitObjList", list) end)
    pc(function() attr:set_field("mPhotoHitObjCount", 0) end)
    return #items(fld(attr, "mPhotoHitObjList")) == 0
end

------------------------------------------------------------
-- spawning
------------------------------------------------------------

local function om_folder()
    -- the folder the area's own Om objects live in, so ours are released with the area like theirs
    for _, o in ipairs(items(fld(area_mgr(), "OmList"))) do
        local go = pc(function() return o:call("get_GameObject") end) or fld(o, "<GameObject>k__BackingField")
        local f = go and pc(function() return go:call("get_Folder") end)
        if f then return f, "omlist" end
    end
    local pm = sdk.get_managed_singleton("app.solid.PlayerManager")
    local pgo = pm and pc(function() return pm:call("get_CurrentPlayer") end)
    return pgo and pc(function() return pgo:call("get_Folder") end), "player"
end

local function scene_stickers()
    local sm = sdk.get_native_singleton("via.SceneManager")
    local smt = sdk.find_type_definition("via.SceneManager")
    local scene = sm and pc(function() return sdk.call_native_func(sm, smt, "get_CurrentScene()") end)
    if not scene then return {} end
    return items(pc(function() return scene:call("findComponents(System.Type)", sdk.typeof("solid.MT2RE.uOm13f")) end))
end

-- Yaw about Y, then Pitch about X, then Roll about Z (radians; Pitch +90 lies flat facing down, for a ceiling).
-- Rotation is yaw * pitch * roll. Quaternion.new(w, x, y, z).
local function qmul(a, b)
    return { w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
             x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
             y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
             z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w }
end
local function rotation(r)
    local y, p, ro = num(r.Yaw) or 0, num(r.Pitch) or 0, num(r.Roll) or 0
    local q = qmul(qmul({ w = math.cos(y / 2), x = 0, y = math.sin(y / 2), z = 0 },
                        { w = math.cos(p / 2), x = math.sin(p / 2), y = 0, z = 0 }),
                   { w = math.cos(ro / 2), x = 0, y = 0, z = math.sin(ro / 2) })
    return Quaternion.new(q.w, q.x, q.y, q.z)
end

local function request_spawn(r)
    local im = sdk.get_managed_singleton("app.solid.gamemastering.ItemManager")
    local key = sdk.create_instance("app.solid.gamemastering.ItemManager.SpecificKeyObject")
    if not im or not key then return false, "no ItemManager" end
    key = key:add_ref()
    key:set_field("ClassName", sdk.create_managed_string(CLASS))
    local p = r.Pos
    local folder, where = om_folder()
    -- The area's Om list is empty until the area has loaded its objects; a sticker put in the player's folder then
    -- never shows. Wait for the list (a few seconds at most, for an area that really has none).
    if where ~= "omlist" and os.clock() - area_since < OM_LIST_WAIT_S then return false, "wait" end
    local known = {}
    for _, c in ipairs(scene_stickers()) do local a = addr(c); if a then known[a] = true end end
    local ok, err = pcall(function()
        im:call("instantiateOmItem(app.solid.gamemastering.ItemManager.SpecificKeyObject, via.vec3, via.Quaternion, System.Action`1<via.GameObject>, via.Folder)",
            key, Vector3f.new(p.x, p.y, p.z), rotation(r), nil, folder)
    end)
    if not ok then return false, tostring(err) end
    live[r.Number] = { row = r, state = "pending", t = os.clock(), known = known, folder = where,
                       pos = { x = p.x, y = p.y, z = p.z } }
    return true
end

local function find_spawned(e)
    local p = e.pos or e.row.Pos
    for _, c in ipairs(scene_stickers()) do
        local a = addr(c)
        if a and not e.known[a] then
            local go = go_of(c)
            local gp = go_pos(go)
            if gp and dist(gp, p) < 0.5 then return c, go end
        end
    end
    return nil
end

local function finish_spawn(n, e, om, go)
    local attr = comp(go, "app.solid.character.SolidModelAttribute")
    if not attr then return false end
    local visual = e.row.Visual
    if not visual and is_collected(e.row) then e.collected, e.born_collected = true, true end
    attr:set_field("mPhotoId", visual or SPARE_ID)
    attr:set_field("HavingUniqueEvent", 0)
    e.om, e.go, e.attr, e.addr = om, go, attr, addr(go)
    e.state, e.t = "live", os.clock()
    if not visual then go_to_number[e.addr] = n end
    stats.spawned = stats.spawned + 1
    return true
end

-- setup may run before or after our id is written; whichever, bring the sticker to: our id, our hit copies,
-- mMaxCount held (uncollected) or 0 (collected)
local function settle(n, e)
    local om, attr = e.om, e.attr
    local vis = e.row.Visual
    if vis then
        if num(fld(om, "mMyScoopId")) ~= vis then pc(function() om:set_field("mMyScoopId", vis) end) end
        -- every tick, as below: a late setup puts the vanilla hit list back
        e.hits_ok = no_hits(attr)
        local r = e.row
        local a = fld(om, "mStartAngle")
        local px, py, pz = num(r.Pitch) or 0, num(r.Yaw) or 0, num(r.Roll) or 0
        if not a or math.abs(a.x - px) > 1e-3 or math.abs(a.y - py) > 1e-3 or math.abs(a.z - pz) > 1e-3 then
            pc(function() om:set_field("mStartAngle", Vector3f.new(px, py, pz)) end)
            pc(function() om:set_field("mRotAngY", 0.0) end)
        end
        return    -- mMaxCount stays the game's: its own count decides glow or grey
    end
    if num(fld(om, "mMyScoopId")) ~= SPARE_ID then
        pc(function() om:set_field("mMyScoopId", SPARE_ID) end)
        pc(function() attr:call("setSMAdd(System.Int32)", SPARE_ID) end)
    end
    -- every tick: a late setup (setSMAdd) puts the shared template list back, which would credit 164
    -- (a sticker collected before it spawned is no photo target at all: it only shows greyed out)
    if e.born_collected then e.hits_ok = no_hits(attr) else e.hits_ok = own_hits(attr, e.row) end
    -- the sticker re-applies uOm13f.mStartAngle (Euler radians x = pitch, y = yaw, z = roll) whenever it changes
    -- collected state, so the row's orientation has to live there too, or it snaps to the default facing
    local r = e.row
    local a = fld(om, "mStartAngle")
    local px, py, pz = num(r.Pitch) or 0, num(r.Yaw) or 0, num(r.Roll) or 0
    if not a or math.abs(a.x - px) > 1e-3 or math.abs(a.y - py) > 1e-3 or math.abs(a.z - pz) > 1e-3 then
        pc(function() om:set_field("mStartAngle", Vector3f.new(px, py, pz)) end)
        pc(function() om:set_field("mRotAngY", 0.0) end)
    end
    local want = e.collected and 0 or HOLD_MAX
    if num(fld(om, "mMaxCount")) ~= want then pc(function() om:set_field("mMaxCount", want) end) end
end

local function alive(e)
    if not e.om or not e.go then return false end
    -- the area releases its Om objects on a change; ours must still be in the scene
    for _, c in ipairs(scene_stickers()) do if addr(c) == addr(e.om) then return true end end
    return false
end

local function maintain()
    local am = area_mgr()
    if not am then return end
    local idx = num(fld(am, "mAreaIndex"))
    if idx ~= area_index then
        area_index, area_since = idx, os.clock()
        live, go_to_number, doomed = {}, {}, {}
        quiet_since = nil
        area_timing = { quiet = nil, first = nil }
        return
    end
    for k, d in pairs(doomed) do
        if not d.om then
            local om, go = find_spawned(d)
            if om then d.om, d.go = om, go end
        end
        if d.om then
            pc(function() d.go:call("set_DrawSelf", false) end)
            pc(function() d.om:set_field("mMaxCount", 0) end)
            local tr = go_tr(d.go)
            local q = tr and pc(function() return tr:call("get_Position") end)
            if q and q.y > -500 then pc(function() tr:call("set_Position", Vector3f.new(q.x, q.y - 1000.0, q.z)) end) end
            doomed[k] = nil
        elseif os.clock() - d.t > FIND_TIMEOUT_S then
            doomed[k] = nil
        end
    end
    if pc(function() return am:call("isOmSetLoading") end) == true then
        -- a load drops what was requested before it, so nothing pending can still appear
        quiet_since = nil
        for n, e in pairs(live) do if e.state == "pending" then live[n] = nil end end
        want_fast = true
        return
    end
    local now = os.clock()
    if not quiet_since then
        quiet_since = now
        if area_timing then area_timing.quiet = now - area_since end
    end
    if now - area_since < RESPAWN_SETTLE_S or now - quiet_since < LOAD_QUIET_S then want_fast = true; return end
    want_fast = false
    local extras = false
    for _, e in pairs(live) do if not e.row.Visual then extras = true; break end end
    if extras then verify_scoop_points() end

    for _, r in ipairs(rows()) do
        if r.Number and r.Pos and area_index_of(r.Area) == idx then
            local e = live[r.Number]
            if e == nil then
                -- collected ones are spawned too, and show greyed out
                local ok, err = request_spawn(r)
                if not ok and err ~= "wait" then M.log("Spawn failed for custom sticker " .. tostring(r.Number) .. ": " .. tostring(err)) end
                want_fast = true
            elseif e.state == "pending" then
                want_fast = true
                local om, go = find_spawned(e)
                if om then
                    if finish_spawn(r.Number, e, om, go) and not r.Visual and not (seal_ready and scoop_ready) then ensure_seal_row(e.attr) end
                    if area_timing and not area_timing.first then
                        area_timing.first = os.clock() - area_since
                        M.log(string.format("First custom sticker in %s %.2f s after the area change (Om set quiet after %s s)",
                            tostring(r.Area), area_timing.first, area_timing.quiet and string.format("%.2f", area_timing.quiet) or "?"))
                    end
                    M.log(string.format("Custom sticker %d spawned in %s (folder: %s)", r.Number, tostring(r.Area), e.folder))
                elseif os.clock() - e.t > FIND_TIMEOUT_S then
                    M.log("Custom sticker " .. tostring(r.Number) .. " never appeared (folder: " .. tostring(e.folder) .. "); retrying")
                    live[r.Number] = nil
                end
            elseif e.state == "live" then
                if not alive(e) then
                    if e.addr then go_to_number[e.addr] = nil end
                    live[r.Number] = nil
                    stats.respawned = stats.respawned + 1
                else
                    if not r.Visual and not (seal_ready and scoop_ready) then ensure_seal_row(e.attr) end
                    settle(r.Number, e)
                end
            end
        end
    end
end

------------------------------------------------------------
-- detection
------------------------------------------------------------

-- The last photo's result, for a tool to show on screen (drap_cstick_last_photo): { seq, hit, number, text }.
M.last_photo = nil
local function photo_result(hit, n, text)
    M.last_photo = { seq = ((M.last_photo and M.last_photo.seq) or 0) + 1, hit = hit, number = n, text = text }
    M.log(text)
end
local function cam_view()
    local cam = pc(function() return sdk.get_primary_camera() end)
    local tr = go_tr(cam and pc(function() return cam:call("get_GameObject") end))
    local p = tr and pc(function() return tr:call("get_Position") end)
    local m = tr and pc(function() return tr:call("get_WorldMatrix") end)
    local z = m and pc(function() return m[2] end)
    if not p or not z then return nil end
    -- RE Engine cameras look down -Z
    return { pos = { x = p.x, y = p.y, z = p.z }, fwd = { x = -z.x, y = -z.y, z = -z.z } }
end
local function unit(v)
    local l = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    if l < 1e-6 then return nil end
    return { x = v.x / l, y = v.y / l, z = v.z / l }, l
end
local function angle(a, b) return math.deg(math.acos(math.max(-1, math.min(1, a.x * b.x + a.y * b.y + a.z * b.z)))) end
-- where the camera stood against sticker e at the shot: distance, degrees off its face, degrees off the view centre,
-- and the zone's full / zero limits from its fan
local function shot_geometry(e, cam)
    local gp = e.go and go_pos(e.go)
    local tr = go_tr(e.go)
    local m = tr and pc(function() return tr:call("get_WorldMatrix") end)
    local z = m and pc(function() return m[2] end)
    if not gp or not z or not cam then return nil end
    local face = unit({ x = z.x, y = z.y, z = z.z })
    local to_cam, d = unit({ x = cam.pos.x - gp.x, y = cam.pos.y - gp.y, z = cam.pos.z - gp.z })
    local fwd = unit(cam.fwd)
    if not face or not to_cam or not fwd then return nil end
    local h = items(fld(e.attr, "mPhotoHitObjList"))[1]
    local fan = num(fld(h, "mFanRate")) or PHOTO_FAN
    local full, zero = 90, 180
    if fan > 0 and fan < 2 * math.pi then
        local c = math.cos(fan / 4)
        full, zero = math.deg(math.acos(c * c)), math.deg(fan / 2)
    end
    return { dist = d, off_face = angle(face, to_cam), full = full, zero = zero,
             off_centre = angle(fwd, { x = -to_cam.x, y = -to_cam.y, z = -to_cam.z }) }
end
local function describe_shot(g)
    if not g then return "" end
    return string.format("%.1f m away, %d deg off its face (full up to %d, none past %d), %d deg off centre", g.dist,
        math.floor(g.off_face + 0.5), math.floor(g.full + 0.5), math.floor(g.zero + 0.5), math.floor(g.off_centre + 0.5))
end
local function miss_hint(g, rate)
    if not g then return "" end
    if g.off_centre > 15 then return "off centre: put it in the middle of the frame" end
    if g.off_face > g.zero then return "too steep: stand more in front of its face" end
    if g.off_face > g.full then return "steep: only part marks, stand more in front of its face" end
    if (rate or 0) <= 0 and g.dist > 6 then return "too far: move closer" end
    if (rate or 0) <= 0 then return "zero camera percentage: something in the way, or too far" end
    return "angle and distance look fine: something in the way?"
end

local function on_detect(n, game_score)
    local e = live[n]
    if not e or e.collected then return end
    photo.got_one = true
    e.collected = true
    stats.detected = stats.detected + 1
    local r = e.row
    local test = debug_enabled or r.Test
    local how = describe_shot(shot_geometry(e, photo.cam))
    if r.Spot then
        photo_result(true, n, string.format("Placement spot %s photographed: camera %.0f%% (custom sticker %d; %s)",
            tostring(r.Spot), (photo.rate_at_shot or 0) * 100, n, how))
    else
        photo_result(true, n, string.format("Custom sticker %d photographed (%s): camera %.0f%% (%s)", n,
            tostring(r.LocationName), (photo.rate_at_shot or 0) * 100, how))
    end
    pc(function() e.om:set_field("mMaxCount", 0) end)
    if test then
        test_load()[tostring(n)] = true
        test_save()
        M.log(string.format("Test mode: Extra PP Sticker %d marked collected locally (%s; no check is sent without a slot)",
            n, tostring(r.LocationName)))
    end
    -- test mode sends nothing: Bridge would journal the check and replay it on the next real connect
    if not test and M.on_check and r.LocationName then pcall(M.on_check, r.LocationName, n) end
    local rate = photo.rate_at_shot or 0
    local target = math.floor((pp_base or PP_BASE_FALLBACK) * rate + 0.5)
    local paid = game_score or 0
    local grant = 0
    stats.last_rate, stats.last_grant, stats.last_game_score, stats.last_total = rate, grant, paid, paid + grant
    M.log(string.format("Custom sticker %d: camera rate %.3f (a vanilla sticker would pay %d); the game paid %d", n, rate, target, paid))
    local PB = package.loaded["DRAP/effects/PlayerBuffs"]
    if PB and PB.pp_boost and grant > 0 then pcall(PB.pp_boost, grant) end   -- grant is 0: the game's 1 point is all
end

-- per frame while any of ours is live. Arm when the photo mode enters rating (2) and remember the rows already in
-- the lists at that moment: they belong to the previous photo (a stand-in photo just before left mTargetNum at
-- 1, the first read of the new rating saw only that stale row, and the old code disarmed on it and missed ours).
-- While rating, check rows 0..mTargetNum-1 every frame, skipping the stale ones; disarm when rating ends.
local function row_key(t)
    local go = fld(t, "FuncParam")
    return tostring(go and addr(go) or 0) .. ":" .. tostring(num(fld(t, "Score"))) .. ":" .. tostring(num(fld(t, "ScoopId")))
end
local function watch_photo()
    local pm = photo_mgr()
    if not pm then return end
    local mode = num(fld(pm, "CurrentPhotoMode"))
    local pr = rating()
    -- the camera's PP rate (the on-screen percentage) while aiming; the last one before the shutter is the photo's
    if mode == 1 then photo.rate = num(fld(pr, "mPPSealRate")) or 0 end
    if mode == 2 and photo.mode ~= 2 then
        photo.rate_at_shot = photo.rate or 0
        photo.cam = cam_view()
        photo.armed = true
        stats.photos = stats.photos + 1
        photo.stale = {}
        local tn0 = num(fld(pr, "mTargetNum")) or 0
        local arr0 = fld(pr, "mTarget")
        for i = 0, tn0 - 1 do
            local t = arr0 and pc(function() return arr0:get_element(i) end)
            if t then photo.stale[row_key(t)] = true end
        end
    end
    if mode ~= 2 and photo.mode == 2 then
        photo.armed = false
        -- a photo with none of ours in it while one is close: say which, and why it may not have rated.
        -- The one meant: the uncollected sticker within 15 m nearest the middle of the frame
        if not photo.got_one and photo.cam then
            local best, bg
            for n2, e2 in pairs(live) do
                if e2.state == "live" and not e2.collected and not e2.row.Visual and e2.go then
                    local g = shot_geometry(e2, photo.cam)
                    if g and g.dist < 15 and (not bg or g.off_centre < bg.off_centre) then best, bg = n2, g end
                end
            end
            if best then
                local rb = live[best].row
                local name = rb.Spot and ("placement spot " .. tostring(rb.Spot)) or ("custom sticker " .. tostring(best))
                photo_result(false, best, string.format("Missed %s: camera %.0f%%, %s (%s)", name,
                    (photo.rate_at_shot or 0) * 100, miss_hint(bg, photo.rate_at_shot), describe_shot(bg)))
            end
        end
        photo.got_one = false
        local c = get_count(SPARE_ID)
        if c and c > 0 then set_count(SPARE_ID, 0) end
    end
    photo.mode = mode
    if not photo.armed then return end
    local tn = num(fld(pr, "mTargetNum")) or 0
    if tn <= 0 then return end
    local arr = fld(pr, "mTarget")
    for i = 0, tn - 1 do
        local t = arr and pc(function() return arr:get_element(i) end)
        if t then
            local key = row_key(t)
            if photo.stale[key] then
                stats.stale_skipped = stats.stale_skipped + 1
            else
                photo.stale[key] = true
                local go = fld(t, "FuncParam")
                local n = go and go_to_number[addr(go)]
                if n then on_detect(n, num(fld(t, "Score"))) end
            end
        end
    end
end

------------------------------------------------------------
-- public
------------------------------------------------------------

function M.setup(on)
    enabled = on == true
    M.log("Custom PP stickers: " .. (enabled and "on" or "off"))
end

function M.on_frame()
    if not is_on() then return end
    if next(live) ~= nil then pcall(watch_photo) end   -- a marker alone gives it no rows to match
    local now = os.clock()
    if now < next_maint then return end
    -- an area change is picked up within a tenth of a second, and an area still spawning is polled as fast
    local am = area_mgr()
    local idx = am and num(fld(am, "mAreaIndex"))
    next_maint = now + ((want_fast or idx ~= area_index) and FAST_INTERVAL_S or MAINT_INTERVAL_S)
    local ok, err = pcall(maintain)
    if not ok then M.log("maintain error: " .. tostring(err)) end
end

function M.status()
    local out = { enabled = enabled, debug = debug_enabled, area = area_index, seal_ready = seal_ready,
                  scoop_ready = scoop_ready, radius_scale = RADIUS_SCALE, stats = stats, live = {} }
    for n, e in pairs(live) do
        out.live[#out.live + 1] = { number = n, state = e.state, hits_ok = e.hits_ok, collected = e.collected == true,
                                    folder = e.folder, max_count = e.om and num(fld(e.om, "mMaxCount")) or nil,
                                    scoop_id = e.om and num(fld(e.om, "mMyScoopId")) or nil, pos = e.go and go_pos(e.go) or nil }
    end
    out.spare_count = get_count(SPARE_ID)
    return out
end

rawset(_G, "drap_cstick_enable", function(on) debug_enabled = (on ~= false); return debug_enabled end)

-- Offline test, no seed or server: drap_extra_pp_stickers(true) turns the table stickers on. They spawn in
-- their own areas (now, and on every area load), a photo pays the PP and marks them collected in TEST_FILE, so they
-- are not spawned again. drap_extra_pp_stickers(false) turns them off (already spawned ones stay until the area is left).
rawset(_G, "drap_extra_pp_stickers", function(on)
    debug_enabled = (on ~= false)
    if not debug_enabled then debug_enabled = nil end
    local n = #rows()
    local done = 0
    for _ in pairs(test_load()) do done = done + 1 end
    local msg = debug_enabled and string.format("Extra PP Stickers test mode on: %d stickers, %d already collected", n, done)
        or "Extra PP Stickers test mode off"
    M.log(msg)
    return msg
end)
-- forget what test mode has collected; stickers already collected in this area come back on the next area load
rawset(_G, "drap_extra_pp_stickers_reset", function()
    test_collected = {}
    test_save()
    for _, e in pairs(live) do e.collected = nil end
    M.log("Extra PP Stickers test mode: collected list cleared")
    return "cleared"
end)
rawset(_G, "drap_cstick_add", function(area, x, y, z, yaw, n, name, pitch, roll)
    n = num(n) or (900 + #debug_rows + 1)
    debug_rows[#debug_rows + 1] = { Number = n, LocationName = name or ("Photograph Extra PP Sticker " .. tostring(n)),
                                    Area = area, Pos = { x = num(x), y = num(y), z = num(z) }, Yaw = num(yaw) or 0.0,
                                    Pitch = num(pitch) or 0.0, Roll = num(roll) or 0.0 }
    return n
end)
rawset(_G, "drap_cstick_status", function() return M.status() end)
rawset(_G, "drap_cstick_last_photo", function() return M.last_photo end)
-- take a spawned (or still spawning) sticker away; the area owns it, so it is hidden and dropped under the map
local function despawn(n)
    local e = live[n]
    if not e then return end
    live[n] = nil
    if e.addr then go_to_number[e.addr] = nil end
    local d = { om = e.om, go = e.go, known = e.known or {}, pos = e.pos or e.row.Pos, t = os.clock() }
    doomed[d] = d
end
rawset(_G, "drap_cstick_remove", function(n)
    n = num(n)
    despawn(n)
    for i, r in ipairs(debug_rows) do if r.Number == n then table.remove(debug_rows, i); return true end end
    return false
end)
-- Add or replace test sticker n at a spot. A replaced one is despawned and spawned afresh where
-- the spot now is, and is photographable again (its test-file mark is cleared).
-- photo_pitch / photo_yaw (radians, optional): turn the photo zone off the sticker's face (rows: PhotoPitch, PhotoYaw).
rawset(_G, "drap_cstick_spot", function(n, area, x, y, z, yaw, pitch, roll, spot, photo_pitch, photo_yaw)
    n = num(n)
    if not n then return nil end
    despawn(n)
    for i, r in ipairs(debug_rows) do if r.Number == n then table.remove(debug_rows, i); break end end
    local tc = test_load()
    if tc[tostring(n)] then tc[tostring(n)] = nil; test_save() end
    debug_rows[#debug_rows + 1] = { Number = n, Test = true, Spot = spot, LocationName = "Placement spot " .. tostring(spot or n),
                                    Area = area, Pos = { x = num(x), y = num(y), z = num(z) }, Yaw = num(yaw) or 0.0,
                                    Pitch = num(pitch) or 0.0, Roll = num(roll) or 0.0,
                                    PhotoPitch = num(photo_pitch), PhotoYaw = num(photo_yaw) }
    return n
end)
rawset(_G, "drap_cstick_radius_scale", function(x) RADIUS_SCALE = num(x) or RADIUS_SCALE; return RADIUS_SCALE end)

M.log("CustomStickers loaded (spare id " .. SPARE_ID .. ", template " .. TEMPLATE_ID .. ")")

return M
