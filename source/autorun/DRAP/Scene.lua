-- DRAP/Scene.lua
-- DRDR "scene" helper: detects when we've loaded into gameplay.

local Shared = require("DRAP/Shared")

local Scene = Shared.create_module("Scene")

-- Singleton managers
local gm_mgr = Scene:add_singleton("gm", "app.solid.gamemastering.GameManager")
local ps_mgr = Scene:add_singleton("ps", "app.solid.PlayerStatusManager")

------------------------------------------------------------
-- Public API
------------------------------------------------------------

function Scene.getGameManager()
    return gm_mgr:get()
end

function Scene.getPlayerStatusManager()
    return ps_mgr:get()
end

--- Checks if we're currently in gameplay
--- @return boolean True if in game
function Scene.isInGame()
    local ps = ps_mgr:get()
    if not ps then return false end

    local f = ps_mgr:get_field("PlayerLevel")
    if not f then return false end

    local ok, lvl = pcall(f.get_data, f, ps)
    if not ok or lvl == nil then return false end

    return true
end

--- Checks if the game is currently loading
--- @return boolean|nil True if loading, nil if unknown
function Scene.isGameLoading()
    local gm = gm_mgr:get()
    if not gm then return nil end

    local candidates = {
        "get_IsSceneLoading",
        "get_IsLoading",
        "get_IsNowLoading",
        "isSceneLoading",
        "isLoading",
        "get_IsGameTimeMove"
    }

    for _, name in ipairs(candidates) do
        local ok, val = pcall(function()
            return gm:call(name)
        end)
        if ok and type(val) == "boolean" then
            return val
        end
    end

    return nil
end

return Scene