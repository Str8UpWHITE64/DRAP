-- DRAP/effects/MusicShuffle.lua
-- Music Shuffle: every music cue plays a different piece of the game's music,
-- fixed per seed and slot. Two pools, shuffled separately:
--   Mall Music    the PA songs. They play through the speaker mixers, so a
--                 PA slot keeps its PA sound whatever lands in it.
--   Action Music  the music containers and full mixes, which go straight to
--                 the music bus (event, psycho and story music).
--
-- Every music request in the game ends in one table,
-- SoundBGMManager._Settings.TriggerList: one row per BGMType holding the Wwise
-- trigger to start it and the one to stop it. The area cues (the BGM table ->
-- fileToBGMType), the mall PA (requestBGMSpeaker) and the psycho fights
-- (requestBGM) all look their trigger up there when they play. Moving a row's
-- Trigger/StopTrigger pair to another row reroutes that cue, from the next
-- request on, with nothing hooked. Measured 2026-10-11: swapping rows 42 and
-- 18 put the psycho battle theme on the mall PA after an area load.
--
-- What each row plays, read from BGM_e.bnk / BGM_m.bnk via BGM.wel:
--   0, 2-13, 16-20   interactive music (Wwise music containers), 42-247 s
--   14               a music switch on its OWN state group (2967954950), with
--                    no default path: anywhere that group is unset it plays
--                    silence. Kept out (measured 2026-10-11: the PA went
--                    silent when it drew 14). 8-13 and 20 switch on group
--                    70266178, which the game keeps set, and play anywhere.
--   1, 33, 34        full-mix streamed tracks, 73-97 s
--   22-32            the mall PA songs (mono, two sources each), 50-106 s
--   21               32 s -- the one short cue, kept out
--   15               plays from a bank outside BGM, kept out
--   35-74            DLC music (BGM100-121 / BGM200-221). The audio lives only
--                    in the DLC paks, so it is never a SOURCE; the rows are
--                    still given base music so a player with DLC music
--                    selected in the options hears the shuffle on the PA too.
--
-- Custom music: the DRAP Music Builder ADDS the player's songs to the game's
-- Wwise files as new tracks with their own trigger pairs -- no vanilla object
-- is changed -- and lists them in reframework/data/DRAP_Music.json. When a
-- pool has custom songs, its cue rows point at those pairs instead of the
-- vanilla ones; with none (or no file) the pool does the vanilla shuffle.
-- Nothing asks for the custom triggers until this writes them, which only
-- happens after a slot connect with music_shuffle on.
--
-- Pairs move together so a cue's stop trigger always stops what its start
-- trigger began. The vanilla table is kept as a constant: a script reset
-- mid-session would otherwise capture an already-shuffled table as "vanilla".

local Shared = require("DRAP/Shared")

local M = Shared.create_module("MusicShuffle")
M:set_throttle(2.0)

local BGM_T = "app.solid.SoundBGMManager"

-- BGMType -> { Trigger, StopTrigger }, dumped from the live table 2026-10-11.
local VANILLA = {
    [0] = { 850095394, 2229493699 },
    [1] = { 2263746872, 154058866 },
    [2] = { 1899750917, 318767388 },
    [3] = { 2408948004, 2944701447 },
    [4] = { 2997348205, 3699802195 },
    [5] = { 4177354288, 2452221283 },
    [6] = { 3189081890, 1948754511 },
    [7] = { 3847399910, 346998659 },
    [8] = { 899860724, 851817294 },
    [9] = { 2938796606, 4107021179 },
    [10] = { 4032101203, 2153834774 },
    [11] = { 1815847388, 3365936247 },
    [12] = { 887858432, 2188013044 },
    [13] = { 2693194987, 3407768161 },
    [14] = { 1520466949, 2951385113 },
    [15] = { 24828309, 2055424657 },
    [16] = { 3139299591, 3593781555 },
    [17] = { 3833340916, 1891811707 },
    [18] = { 108434568, 548671757 },
    [19] = { 1630495137, 690852075 },
    [20] = { 1870617053, 2428992327 },
    [21] = { 1379772432, 1820400127 },
    [22] = { 3924813669, 2383573638 },
    [23] = { 3175392588, 574548017 },
    [24] = { 2951492368, 6974858 },
    [25] = { 2883606947, 639927436 },
    [26] = { 1218408765, 2068897743 },
    [27] = { 2450375718, 1595817185 },
    [28] = { 2996294864, 1333425689 },
    [29] = { 2153783312, 2913491726 },
    [30] = { 3116128280, 2757867723 },
    [31] = { 4188039649, 2037876920 },
    [32] = { 4277157721, 1922139512 },
    [33] = { 3161488032, 1915552768 },
    [34] = { 1540532642, 791758819 },
    [35] = { 3936537932, 3025686257 },
    [36] = { 1600196890, 205206779 },
    [37] = { 2186766184, 4015567166 },
    [38] = { 2312082189, 1053293202 },
    [39] = { 3715417260, 3610663189 },
    [40] = { 3428604682, 3173697869 },
    [41] = { 2779038181, 4073302192 },
    [42] = { 202812721, 284866585 },
    [43] = { 4232356830, 2460844596 },
    [44] = { 2154042852, 2241941384 },
    [45] = { 914628284, 3881950528 },
    [46] = { 1837322647, 3826081354 },
    [47] = { 934167074, 332997382 },
    [48] = { 1489434898, 3646874798 },
    [49] = { 3333302214, 4034128302 },
    [50] = { 2147506126, 3123302509 },
    [51] = { 2107615237, 140153792 },
    [52] = { 3620889979, 3149397626 },
    [53] = { 2897128563, 290309838 },
    [54] = { 3368297212, 2865507303 },
    [55] = { 1694261967, 2482938482 },
    [56] = { 3147404666, 3480852917 },
    [57] = { 4190588945, 3073160627 },
    [58] = { 3646365121, 1510528310 },
    [59] = { 558919509, 585969891 },
    [60] = { 1475183267, 3990356633 },
    [61] = { 2266246259, 1589388461 },
    [62] = { 2062452872, 2515173271 },
    [63] = { 3574910385, 1896108649 },
    [64] = { 2835100576, 458753138 },
    [65] = { 2227063472, 3396825229 },
    [66] = { 1554872146, 2646237529 },
    [67] = { 2482844887, 4013870635 },
    [68] = { 3767483676, 1930014965 },
    [69] = { 2472192358, 514915011 },
    [70] = { 1789078862, 793596764 },
    [71] = { 1263973857, 3825601667 },
    [72] = { 3545681152, 1491974342 },
    [73] = { 2180523371, 3184258768 },
    [74] = { 2872365442, 3890350127 },
}

-- Rows that are both shuffled and drawn from: everything with base-game audio
-- except the short cue (21), the out-of-bank one (15) and the switch on its
-- own state group (14). Each pool only ever trades within itself.
local MALL_POOL = { 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32 }
local ACTION_POOL = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13,
                      16, 17, 18, 19, 20, 33, 34 }
-- DLC music rows are PA songs too, so they draw from Mall Music.
local DLC_LO, DLC_HI = 35, 74

-- Custom Mall Music is per AREA. The game plays one PA song mall-wide: every
-- plaza and store requests the same row (42 with DLC music 7), and Colby's
-- requests that song's theater version (62) -- measured 2026-10-13 with
-- probes/drap_pa_walk.lua. So per-area songs come from rewriting the PA rows
-- whenever the player changes area. These are the areas with PA speakers;
-- Colby's is its own slot. (Food Court, Leisure Park, the Rooftop/Warehouse/
-- Security Room have none.)
local PA_AREAS = { 256, 512, 768, 1024, 2304, 1280, 1281, 1283 }
-- Colby's plays the theater version of a PA song (vanilla: row 62 for 42).
local THEATER_AREA = 1283
local PA_ROWS = {}
for _, t in ipairs(MALL_POOL) do PA_ROWS[#PA_ROWS + 1] = t end
for t = DLC_LO, DLC_HI do PA_ROWS[#PA_ROWS + 1] = t end
local IS_PA_ROW = {}
for _, t in ipairs(PA_ROWS) do IS_PA_ROW[t] = true end
local IDLE_SPEAKER = 75   -- Speaker.Bgm while a speaker is not playing

local CUSTOM_FILE = "DRAP_Music.json"

local config = { enabled = false, key = nil }
-- BGMType -> { trigger, stop, label } it plays. Empty when off.
local mapping = {}
-- area index -> the custom Mall song pair for that area (only areas that got one)
local area_song = {}
-- The pair every PA row plays in the current area, or nil for the base mapping.
local pa_override = nil
local watch = { area = nil }
-- Songs the Music Builder installed: { mall = {pair...}, action = {pair...} }
local custom = { mall = {}, action = {} }
local custom_pairs = {}
-- What the table currently holds as far as we know: "vanilla", "shuffled".
local applied = "vanilla"
local warned_layout = false

------------------------------------------------------------
-- Seeded RNG (independent of math.random, which other modules use)
------------------------------------------------------------

local function fnv1a(s)
    local h = 2166136261
    for i = 1, #s do
        h = h ~ s:byte(i)
        h = (h * 16777619) & 0xFFFFFFFF
    end
    return h
end

local function make_rng(key)
    local x = fnv1a(key)
    if x == 0 then x = 0x9E3779B9 end
    return function(n)  -- uniform-ish integer in 1..n
        x = x ~ ((x << 13) & 0xFFFFFFFF)
        x = x ~ (x >> 17)
        x = x ~ ((x << 5) & 0xFFFFFFFF)
        return (x % n) + 1
    end
end

local function shuffled(list, rnd)
    local out = {}
    for i, v in ipairs(list) do out[i] = v end
    for i = #out, 2, -1 do
        local j = rnd(i)
        out[i], out[j] = out[j], out[i]
    end
    return out
end

local function as_u32(v)
    v = tonumber(v)
    if not v then return nil end
    return math.tointeger(v) or math.floor(v)
end

--- Reads the Music Builder's song list. Missing or unreadable means none.
local function load_custom()
    custom, custom_pairs = { mall = {}, action = {} }, {}
    local ok, data = pcall(json.load_file, CUSTOM_FILE)
    if not ok or type(data) ~= "table" then return end
    for _, pool in ipairs({ "mall", "action" }) do
        for _, song in ipairs(type(data[pool]) == "table" and data[pool] or {}) do
            local p, st = as_u32(song.play), as_u32(song.stop)
            if p and st then
                local entry = { p, st, tostring(song.name) }
                -- Mall songs also carry a theater version (Colby's).
                local tp, ts = as_u32(song.theater_play), as_u32(song.theater_stop)
                if tp and ts then
                    entry.theater = { tp, ts, tostring(song.name) .. " (theater)" }
                    custom_pairs[tp .. ":" .. ts] = true
                end
                table.insert(custom[pool], entry)
                custom_pairs[p .. ":" .. st] = true
            end
        end
    end
end

local function vanilla(t) local p = VANILLA[t]; return { p[1], p[2], "BGMType " .. t } end

--- Each custom song is used at most once. Slots are filled in a per-seed
--- shuffled order until the songs run out; the remaining slots keep the
--- (vanilla) music they would have had anyway. Returns the row mapping and
--- the per-area Mall songs.
local function build_mapping(key)
    local rnd = make_rng(key)
    local m, areas = {}, {}
    -- Base: the vanilla shuffle, every pool trading only within itself.
    for _, pool in ipairs({ MALL_POOL, ACTION_POOL }) do
        local order = shuffled(pool, rnd)
        for i, t in ipairs(pool) do m[t] = vanilla(order[i]) end
    end
    -- DLC rows: one pass over a second Mall shuffle, so each PA song is used
    -- about as often as any other.
    local extra = shuffled(MALL_POOL, rnd)
    for t = DLC_LO, DLC_HI do
        m[t] = vanilla(extra[((t - DLC_LO) % #extra) + 1])
    end
    -- Action: custom songs take shuffled cue rows, one row each.
    if #custom.action > 0 then
        local songs, rows = shuffled(custom.action, rnd), shuffled(ACTION_POOL, rnd)
        for i = 1, math.min(#songs, #rows) do m[rows[i]] = songs[i] end
    end
    -- Mall: custom songs take shuffled PA areas, one area each.
    if #custom.mall > 0 then
        local songs, slots = shuffled(custom.mall, rnd), shuffled(PA_AREAS, rnd)
        for i = 1, math.min(#songs, #slots) do
            local song = songs[i]
            areas[slots[i]] = (slots[i] == THEATER_AREA and song.theater) or song
        end
    end
    return m, areas
end

------------------------------------------------------------
-- Table access
------------------------------------------------------------

local function safe(fn) local ok, v = pcall(fn); if ok then return v end end

local function trigger_rows()
    local mgr = safe(function() return sdk.get_managed_singleton(BGM_T) end)
    local st = mgr and safe(function() return mgr:get_field("_Settings") end)
    local arr = st and safe(function() return st:get_field("TriggerList") end)
    if not arr then return nil end
    local n = safe(function() return arr:get_size() end)
        or safe(function() return arr:call("get_Length") end) or 0
    local rows = {}
    for i = 0, n - 1 do
        local e = safe(function() return arr:get_element(i) end)
            or safe(function() return arr:call("GetValue(System.Int32)", i) end)
        local t = e and tonumber(safe(function() return e:get_field("Type") end))
        if t then rows[t] = e end
    end
    return rows, n
end

--- The table must hold exactly the vanilla pairs, in any order. Anything else
--- (a game update) and we leave it alone rather than write ids we don't know.
local function layout_matches(rows)
    local want = {}
    for _, p in pairs(VANILLA) do want[p[1] .. ":" .. p[2]] = true end
    for k in pairs(custom_pairs) do want[k] = true end
    local seen = 0
    for _, e in pairs(rows) do
        local tr = safe(function() return e:get_field("Trigger") end)
        local sp = safe(function() return e:get_field("StopTrigger") end)
        if not want[tostring(tr) .. ":" .. tostring(sp)] then return false end
        seen = seen + 1
    end
    return seen == 75
end

local function target_pair(t)
    if pa_override and IS_PA_ROW[t] then return pa_override end
    return mapping[t] or VANILLA[t]
end

--- True when every row already holds what it should.
local function in_place(rows)
    for t, e in pairs(rows) do
        local p = target_pair(t)
        if p then
            if safe(function() return e:get_field("Trigger") end) ~= p[1]
                or safe(function() return e:get_field("StopTrigger") end) ~= p[2] then
                return false
            end
        end
    end
    return true
end

local function write_all(rows)
    local n = 0
    for t, e in pairs(rows) do
        local p = target_pair(t)
        if p then
            local ok = pcall(function()
                e:set_field("Trigger", p[1])
                e:set_field("StopTrigger", p[2])
            end)
            if ok then n = n + 1 end
        end
    end
    return n
end

------------------------------------------------------------
-- Public
------------------------------------------------------------

--- Called at slot connect. key is seed + slot; same key, same music.
function M.setup(enabled, seed, slot)
    config.enabled = enabled == true
    config.key = tostring(seed or "") .. "|" .. tostring(slot or "")
    load_custom()
    if config.enabled then
        mapping, area_song = build_mapping(config.key)
    else
        mapping, area_song = {}, {}
    end
    pa_override, watch.area = nil, nil
    M.log(string.format("Music Shuffle %s (custom songs: %d mall, %d action)",
        config.enabled and "ON" or "off", #custom.mall, #custom.action))
end

--- Runs on the frame thread. Writes only when the table differs from what it
--- should hold, so a manager rebuilt by the game is caught and re-patched.
-- Console test cues. A cue fired by hand has no game state behind it, so the
-- manager's areaBGMset runs right after, stops it and re-requests the PA
-- (measured 2026-10-13: requestBGM(18) -> areaBGMset -> requestStopBGM(18)
-- -> requestBGMSpeaker(42)). In real play the game only requests a cue when
-- its state holds, and the shuffle only changes WHICH audio a row plays, so
-- routed cues live exactly as long as the vanilla ones. For the test, a
-- pre-hook skips areaBGMset while a test cue is held. The hook is installed
-- only on first use (address checked unique with check_fold.py) and does
-- nothing but read a Lua boolean.
local cue_queue = {}
local hold = { on = false, area = nil, hooked = false, release = false }

local function install_hold_hook()
    if hold.hooked then return end
    local td = sdk.find_type_definition(BGM_T)
    local m = td and td:get_method("areaBGMset")
    if not m then return end
    sdk.hook(m, function(args)
        if hold.on then return sdk.PreHookResult.SKIP_ORIGINAL end
    end, nil)
    hold.hooked = true
end

local function drain_cues()
    if #cue_queue == 0 and not hold.on and not hold.release then return end
    local mgr = safe(function() return sdk.get_managed_singleton(BGM_T) end)
    if not mgr then return end
    if hold.release then
        hold.release = false
        hold.on = false
        pcall(function() mgr:call("areaBGMset") end)
        M.log("test cue released; area music re-requested")
    end
    if hold.on and tonumber(safe(function() return mgr:get_field("_CurrentAreaNo") end)) ~= hold.area then
        hold.on = false
        pcall(function() mgr:call("areaBGMset") end)
        M.log("test cue released by the area change")
    end
    if #cue_queue == 0 then return end
    local q = cue_queue
    cue_queue = {}
    install_hold_hook()
    for _, t in ipairs(q) do
        hold.on = true
        hold.area = tonumber(safe(function() return mgr:get_field("_CurrentAreaNo") end))
        local ok = pcall(function()
            for s = 0, DLC_HI do
                mgr:call("requestStopBGM(app.solid.SoundBGMManager.BGMType, System.Boolean)", s, false)
            end
            mgr:call("requestBGM(app.solid.SoundBGMManager.BGMType)", t)
        end)
        M.log(string.format("test cue: requestBGM(%d) -> %s (area music held until drap_music_cue() or a door)",
            t, ok and "called" or "failed"))
    end
end

--- Per-area Mall songs. Every frame (one field read) while any area has a
--- custom song: on an area change the PA rows are pointed at that area's song
--- (or back to the base mapping). If the game already asked for the PA in
--- the new area -- its speakers are playing a row -- it is asked again from
--- here, the frame thread, so the new song replaces the old one.
local function watch_area(rows_fn)
    if not config.enabled or next(area_song) == nil then return end
    local mgr = safe(function() return sdk.get_managed_singleton(BGM_T) end)
    if not mgr then return end
    local a = tonumber(safe(function() return mgr:get_field("_CurrentAreaNo") end))
    if a == nil or a == watch.area then return end
    watch.area = a
    -- Already playing? Speakers hold the row they play (75 while idle). It
    -- has to be stopped while its row still holds the OLD pair, or the stop
    -- would go to the new song and the old one would keep playing.
    local playing = nil
    local list = safe(function() return mgr:get_field("_SpeakerList") end)
    local cnt = list and tonumber(safe(function() return list:call("get_Count") end)) or 0
    for i = 0, cnt - 1 do
        local sp = safe(function() return list:call("get_Item", i) end)
        local b = sp and tonumber(safe(function() return sp:get_field("Bgm") end))
        if b and b ~= IDLE_SPEAKER and IS_PA_ROW[b] then playing = b; break end
    end
    if playing then
        pcall(function() mgr:call("requestStopBGM(app.solid.SoundBGMManager.BGMType, System.Boolean)", playing, true) end)
    end
    pa_override = area_song[a]
    local rows = rows_fn()
    local n = 0
    for t, e in pairs(rows or {}) do
        if IS_PA_ROW[t] then
            local p = target_pair(t)
            if pcall(function() e:set_field("Trigger", p[1]); e:set_field("StopTrigger", p[2]) end) then n = n + 1 end
        end
    end
    if playing then
        pcall(function() mgr:call("requestBGMSpeaker(app.solid.SoundBGMManager.BGMType)", playing) end)
    end
    M.log(string.format("area %d: PA plays %s (%d rows; %s)", a,
        pa_override and pa_override[3] or "its shuffled vanilla song", n,
        playing and ("re-requested row " .. playing) or "set before the PA request"))
end

function M.on_frame()
    drain_cues()
    watch_area(trigger_rows)
    if not M:should_run() then return end
    -- Off and never touched: nothing to do, not even a read.
    if not config.enabled and applied == "vanilla" then return end
    local rows, n = trigger_rows()
    if not rows then return end
    if not layout_matches(rows) then
        if not warned_layout then
            M.log(string.format("TriggerList does not match the known layout (%d rows) -- leaving it alone", n or 0))
            warned_layout = true
        end
        return
    end
    if in_place(rows) then
        applied = config.enabled and "shuffled" or "vanilla"
        return
    end
    local wrote = write_all(rows)
    applied = config.enabled and "shuffled" or "vanilla"
    M.log(string.format("TriggerList %s (%d rows written); takes effect on the next music cue",
        applied, wrote))
end

--- Put every row back. Used by the console and when the option is off.
function M.restore()
    config.enabled = false
    mapping, area_song, pa_override, watch.area = {}, {}, nil, nil
end

_G.drap_music_status = function()
    M.log(string.format("enabled=%s applied=%s key=%s", tostring(config.enabled),
        applied, tostring(config.key)))
    for t = 0, DLC_HI do
        if mapping[t] then
            M.log(string.format("  BGMType %d plays %s", t, mapping[t][3]))
        end
    end
    for _, a in ipairs(PA_AREAS) do
        M.log(string.format("  PA area %d plays %s", a, area_song[a] and area_song[a][3] or "its shuffled vanilla song"))
    end
end

--- Offline test: drap_music_cue(n) stops every music cue and plays BGMType n
--- (with the shuffle on, whatever that row now points at), holding the area
--- music off until drap_music_cue() or the next door. Needs the mod active
--- (drap_activate_debug offline).
_G.drap_music_cue = function(n)
    if tonumber(n) then
        cue_queue[#cue_queue + 1] = math.tointeger(tonumber(n))
    else
        hold.release = true
    end
end

--- Offline test: drap_music_shuffle("anything") turns it on with that key,
--- drap_music_shuffle() or drap_music_shuffle("") turns it off and restores
--- the vanilla table. Either way it is heard from the next music cue.
_G.drap_music_shuffle = function(key)
    if key == nil or key == "" or key == false then
        M.restore()
        M.log("Music Shuffle off; vanilla table goes back on the next tick")
    else
        config.enabled = true
        config.key = tostring(key)
        load_custom()
        mapping, area_song = build_mapping(config.key)
        pa_override, watch.area = nil, nil
        M.log("Music Shuffle ON with key " .. config.key)
    end
end

return M
