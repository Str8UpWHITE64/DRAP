-- MusicLog: one log line a few seconds after an area loads, a psychopath fight
-- starts, or a main scoop is started, saying whether the game asked for music
-- and what its area music table needed.
--
-- The area music table (SoundBGMManager._Data.mTable.mBGMTableList) has rows of
-- a music file, event flags that must be on and event flags that must be off.
-- The line prints the current area's rows with the present value of each flag
-- (T on, F off, ? unreadable), next to the number of requestBGM and bgmControll
-- calls since the area was entered, the argument of the last requestBGM, and the
-- manager's _AreaBGMNo.
--
-- The two hooks only add to numbers; everything else is read on the frame.
-- Nothing here changes what plays. Lines are at least MIN_GAP apart.

local Shared = require("DRAP/Shared")
local Activation = require("DRAP/Activation")

local M = Shared.create_module("MusicLog")
M:set_throttle(0.5)

local BGM_T = "app.solid.SoundBGMManager"
local efm_mgr = M:add_singleton("efm", "app.solid.gamemastering.EventFlagsManager")

local SETTLE = { area = 6.0, boss = 3.0, mission = 3.0 }
local MIN_GAP = 4.0

-- Written by the hooks, read on the frame.
local calls = { request = 0, control = 0, last_arg = nil }
local hooks_installed = false

local watch = { area = nil, boss = false, mission = nil }
local pending = nil   -- { reason, due }
local last_logged = -1e9

local function install_hooks()
    if hooks_installed then return end
    hooks_installed = true
    local td = Shared.safe(function() return sdk.find_type_definition(BGM_T) end)
    if not td then return end
    local req = td:get_method("requestBGM")
    local ctl = td:get_method("bgmControll")
    if req then
        pcall(sdk.hook, req, function(args)
            calls.request = calls.request + 1
            local ok, v = pcall(sdk.to_int64, args[3])
            if ok and v then calls.last_arg = v & 0xffffffff end
        end, function(r) return r end)
    end
    if ctl then
        pcall(sdk.hook, ctl, function() calls.control = calls.control + 1 end, function(r) return r end)
    end
end

local function flag_state(id)
    local efm = efm_mgr:get()
    local v = efm and Shared.safe(function() return efm:call("evFlagCheck", id) end)
    if v == nil then return "?" end
    return v and "T" or "F"
end

local function flag_ids(arr)
    local out = {}
    local n = Shared.get_collection_count(arr) or 0
    for i = 0, n - 1 do
        local v = tonumber(Shared.get_collection_item(arr, i))
        if v and v > 0 and v ~= 0xFFFFFFFF then out[#out + 1] = string.format("%d:%s", v, flag_state(v)) end
    end
    return #out > 0 and table.concat(out, ",") or "-"
end

--- The current area's rows from the game's table, as text.
local function table_rows(mgr, area)
    local data = Shared.safe(function() return mgr:get_field("_Data") end)
    local tbl = data and Shared.safe(function() return data:get_field("mTable") end)
    local list = tbl and Shared.safe(function() return tbl:get_field("mBGMTableList") end)
    local n = list and Shared.get_collection_count(list) or 0
    local out = {}
    for i = 0, n - 1 do
        local t = Shared.get_collection_item(list, i)
        if t and tonumber(Shared.safe(function() return t:get_field("mAreaNo") end)) == area then
            local set = Shared.safe(function() return t:get_field("mInfoSet") end)
            local m = set and Shared.get_collection_count(set) or 0
            for j = 0, m - 1 do
                local info = Shared.get_collection_item(set, j)
                if info then
                    out[#out + 1] = string.format("%s on=%s off=%s",
                        tostring(Shared.safe(function() return info:get_field("mBGMFile") end)),
                        flag_ids(Shared.safe(function() return info:get_field("mEventFlag") end)),
                        flag_ids(Shared.safe(function() return info:get_field("mEventNotFlag") end)))
                end
            end
        end
    end
    return #out > 0 and table.concat(out, " | ") or "no row"
end

local function boss_active()
    local ok, BF = pcall(require, "DRAP/BossFight")
    return ok and BF and BF.active and BF.active() == true
end

local function running_mission()
    local ok, SS = pcall(require, "DRAP/scoops/ScoopState")
    if not (ok and SS and SS.running_main) then return nil end
    local ok2, name = pcall(SS.running_main)
    return ok2 and name or nil
end

local function write_line(mgr, why, area)
    local now = os.clock()
    if now - last_logged < MIN_GAP then return false end
    last_logged = now
    M.log(string.format(
        "music %s: area=%s mission=%s boss=%s requestBGM=%d bgmControll=%d last_arg=%s area_bgm=%s rows: %s",
        why, tostring(area), tostring(running_mission() or "-"), tostring(boss_active()),
        calls.request, calls.control, tostring(calls.last_arg),
        tostring(Shared.safe(function() return mgr:get_field("_AreaBGMNo") end)),
        table_rows(mgr, area)))
    return true
end

function M.on_frame()
    if not Activation.is_active() then return end
    if not Shared.is_in_game() then return end
    if not M:should_run() then return end
    install_hooks()

    local mgr = Shared.safe(function() return sdk.get_managed_singleton(BGM_T) end)
    if not mgr then return end
    local now = os.clock()
    local area = tonumber(Shared.safe(function() return mgr:get_field("_CurrentAreaNo") end))

    if area and area ~= watch.area then
        watch.area = area
        calls.request, calls.control, calls.last_arg = 0, 0, nil
        pending = { reason = "area", due = now + SETTLE.area }
    end
    local boss = boss_active()
    if boss and not watch.boss and not pending then
        pending = { reason = "boss", due = now + SETTLE.boss }
    end
    watch.boss = boss
    local mission = running_mission()
    if mission and mission ~= watch.mission and not pending then
        pending = { reason = "mission start (" .. tostring(mission) .. ")", due = now + SETTLE.mission }
    end
    watch.mission = mission

    if pending and now >= pending.due and area then
        if write_line(mgr, pending.reason, area) then pending = nil
        else pending.due = last_logged + MIN_GAP end
    end
end

return M
