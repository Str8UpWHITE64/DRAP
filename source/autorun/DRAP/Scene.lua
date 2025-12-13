-- DRAP/Scene.lua
-- DRDR "scene" helper: detects when we've loaded into gameplay.

local Scene = {}

local GM_TYPE = "app.solid.gamemastering.GameManager"
local PS_TYPE = "app.solid.PlayerStatusManager"

Scene.gameManager = nil
Scene.statusManager = nil

------------------------------------------------------------
-- Safe singleton getter with caching + change detection
------------------------------------------------------------
local function get_singleton(type_name, cached)
    local cur = sdk.get_managed_singleton(type_name)
    if cur ~= cached then
        cached = cur
    end
    return cached, cur
end

function Scene.getGameManager()
    Scene.gameManager = get_singleton(GM_TYPE, Scene.gameManager)
    return Scene.gameManager
end

function Scene.getPlayerStatusManager()
    Scene.statusManager = get_singleton(PS_TYPE, Scene.statusManager)
    return Scene.statusManager
end

------------------------------------------------------------
-- "Loaded into game" detection
------------------------------------------------------------
function Scene.isInGame()
    local ps = Scene.getPlayerStatusManager()
    if not ps then return false end

    local td = ps:get_type_definition()
    if not td then return false end

    local f = td:get_field("PlayerLevel")
    if not f then return false end

    local ok, lvl = pcall(f.get_data, f, ps)
    if not ok or lvl == nil then return false end

    return true
end

function Scene.isGameLoading()
    local gm = Scene.getGameManager()
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
