-- DRAP/DRAP_GUI.lua
-- Unified GUI window for Archipelago modules
-- Combines ItemSpawner and ScoopUnlocker into a single tabbed window

local Shared = require("DRAP/Shared")

local M = Shared.create_module("DRAP_GUI")

------------------------------------------------------------
-- Module References (lazy-loaded)
------------------------------------------------------------

local ItemSpawner = nil
local ScoopUnlocker = nil
local DoorVisualizer = nil

local function ensure_modules()
    if not ItemSpawner then
        local ok, mod = pcall(require, "DRAP/ItemSpawner")
        if ok then ItemSpawner = mod end
    end
    if not ScoopUnlocker then
        local ok, mod = pcall(require, "DRAP/ScoopUnlocker")
        if ok then ScoopUnlocker = mod end
    end
    if not DoorVisualizer then
        local ok, mod = pcall(require, "DRAP/DoorVisualizer")
        if ok then DoorVisualizer = mod end
    end
end

------------------------------------------------------------
-- Window State
------------------------------------------------------------

local window_visible = false
local show_window = true
local debug_mode = false
local active_tab = "Items"

------------------------------------------------------------
-- Drawing
------------------------------------------------------------

local TAB_LIST = { "Items", "Keys", "Scoops", "Doors" }

local function draw_window()
    if not window_visible then return end

    imgui.set_next_window_size(Vector2f.new(700, 800), 4)  -- ImGuiCond_FirstUseEver

    show_window = imgui.begin_window("Archipelago", show_window, 0)

    if not show_window then
        imgui.end_window()
        return
    end

    -- Tab buttons
    for i, tab_name in ipairs(TAB_LIST) do
        if i > 1 then imgui.same_line() end
        local is_active = (active_tab == tab_name)
        if is_active then
            imgui.push_style_color(21, 0xFF885522)  -- ImGuiCol_Button - highlight active
        end
        if imgui.button(tab_name) then
            active_tab = tab_name
        end
        if is_active then
            imgui.pop_style_color(1)
        end
    end

    imgui.separator()

    -- Tab content
    if active_tab == "Items" then
        if ItemSpawner and ItemSpawner.draw_tab_content then
            ItemSpawner.draw_tab_content(debug_mode)
        else
            imgui.text_colored("ItemSpawner not loaded", 0xFFFF8800)
        end
    elseif active_tab == "Keys" then
        if ItemSpawner and ItemSpawner.draw_keys_tab_content then
            ItemSpawner.draw_keys_tab_content(debug_mode)
        else
            imgui.text_colored("ItemSpawner not loaded", 0xFFFF8800)
        end
    elseif active_tab == "Scoops" then
        if ScoopUnlocker and ScoopUnlocker.draw_tab_content then
            ScoopUnlocker.draw_tab_content(debug_mode)
        else
            imgui.text_colored("ScoopUnlocker not loaded", 0xFFFF8800)
        end
    elseif active_tab == "Doors" then
        if DoorVisualizer and DoorVisualizer.draw_tab_content then
            DoorVisualizer.draw_tab_content(debug_mode)
        else
            imgui.text_colored("DoorVisualizer not loaded", 0xFFFF8800)
        end
    end

    imgui.end_window()
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

function M.show_window() show_window = true end
function M.hide_window() show_window = false end
function M.toggle_window() show_window = not show_window end
function M.is_window_visible() return show_window end
function M.is_debug() return debug_mode end
function M.set_debug(val) debug_mode = val end

------------------------------------------------------------
-- REFramework Hooks
------------------------------------------------------------

re.on_frame(function()
    ensure_modules()
    if window_visible then
        draw_window()
    end
end)

re.on_draw_ui(function()
    local changed, new_val = imgui.checkbox("Show Archipelago Window", show_window)
    if changed then
        show_window = new_val
    end
    local dbg_changed, dbg_val = imgui.checkbox("Debug Mode", debug_mode)
    if dbg_changed then
        debug_mode = dbg_val
    end
end)

re.on_pre_application_entry("UpdateBehavior", function()
    window_visible = reframework:is_drawing_ui() and show_window
end)

------------------------------------------------------------
-- Console Helpers
------------------------------------------------------------

_G.ap_gui = function() M.show_window() end

M.log("DRAP_GUI loaded")

return M