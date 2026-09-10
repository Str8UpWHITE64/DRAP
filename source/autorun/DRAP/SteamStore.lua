-- DRAP/SteamStore.lua
-- What Steam holds for this game, for the save diagnostics.
--
-- Vanilla saves go through Steam remote storage, which caps the game at 30
-- files across everything under userdata/<account>/2527390/remote. Until
-- 2026-09-10 the redirect kept every seed there too (win64_save_AP_*), so
-- a few seeds on a full vanilla folder hit the cap and any save that had
-- to create a file was refused (result 51). Seeds now save under
-- <game>/AP_Saves through the plain-file backend (SaveSlot); this readout
-- remains so a vanilla failure dump shows the count.
--
-- REFramework's io library refuses absolute paths and "..", so Steam's
-- tree is reached through the engine's own via.io.file, which is not
-- sandboxed: findFile("<dir>/") lists a directory recursively. Measured
-- 2026-09-10.

local Shared = require("DRAP/Shared")

local M = Shared.create_module("SteamStore")

M.APP_ID = "2527390"

------------------------------------------------------------
-- Engine file API
------------------------------------------------------------

local function io_call(sig, ...)
    local td = sdk.find_type_definition("via.io.file")
    local m = td and td:get_method(sig)
    if not m then return nil, "via.io.file." .. sig .. " not found" end
    local args = table.pack(...)
    for i = 1, args.n do
        if type(args[i]) == "string" then args[i] = sdk.create_managed_string(args[i]) end
    end
    local ok, v = pcall(function() return m:call(nil, table.unpack(args, 1, args.n)) end)
    if not ok then return nil, v end
    return v
end

local function norm(s)
    return (Shared.clean_string(s):gsub("\\", "/"):gsub("/+$", ""))
end

--- Steam's install folder, from the environment Steam gives the game.
local function steam_path()
    local td = sdk.find_type_definition("System.Environment")
    local m = td and td:get_method("GetEnvironmentVariable(System.String)")
    if not m then return nil end
    local ok, v = pcall(function() return m:call(nil, sdk.create_managed_string("SteamPath")) end)
    if not ok or v == nil then return nil end
    local p = norm(v)
    return p ~= "" and p or nil
end

------------------------------------------------------------
-- Steam's store
------------------------------------------------------------

--- Every file Steam holds for the game, as { path, folder, name }, folder
--- being the part under remote/. nil, reason when Steam cannot be found.
function M.steam_files()
    local steam = steam_path()
    if not steam then return nil, "SteamPath not set" end
    local arr, err = io_call("findFile(System.String)", steam .. "/userdata/")
    if not arr then return nil, err or "findFile failed" end
    local n = Shared.safe(function() return arr:get_size() end) or 0
    local files = {}
    local marker = "/" .. M.APP_ID .. "/remote/"
    for i = 0, n - 1 do
        local s = Shared.safe(function() return arr:get_element(i) end)
        local path = s and norm(s) or ""
        local rel = path:match(marker .. "(.+)$")
        if rel then
            local folder, name = rel:match("^(.*)/([^/]+)$")
            table.insert(files, { path = path, folder = folder or "", name = name or rel })
        end
    end
    return files
end

--- One line per folder in Steam's store, for the diagnostics readout.
function M.store_lines()
    local files, why = M.steam_files()
    if not files then return { "  Steam store: unavailable (" .. tostring(why) .. ")" } end
    local counts, order = {}, {}
    for _, f in ipairs(files) do
        if not counts[f.folder] then counts[f.folder] = 0; table.insert(order, f.folder) end
        counts[f.folder] = counts[f.folder] + 1
    end
    table.sort(order)
    local out = { string.format("  Steam store: %d file(s) in %d folder(s) (cap 30)", #files, #order) }
    for _, folder in ipairs(order) do
        table.insert(out, string.format("    %-48s %2d file(s)", folder == "" and "(root)" or folder, counts[folder]))
    end
    return out
end

_G.drap_save_store = function()
    for _, ln in ipairs(M.store_lines()) do M.log(ln) end
end

return M
