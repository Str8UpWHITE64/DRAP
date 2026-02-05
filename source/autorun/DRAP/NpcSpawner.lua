-- DRAP/NpcSpawner.lua
-- NPC/Event Spawner Tool
-- Provides a UI to manually trigger NPC spawns via event flags

local Shared = require("DRAP/Shared")

local M = Shared.create_module("NpcSpawner")

------------------------------------------------------------
-- Singleton Manager
------------------------------------------------------------

local efm_mgr = M:add_singleton("efm", "app.solid.gamemastering.EventFlagsManager")

------------------------------------------------------------
-- Spawn Flags Database (sorted by flag number)
------------------------------------------------------------

local SPAWN_FLAGS = {
    { id = 779,  name = "Kent Day 1",                     category = "Psychopath" },
    { id = 782,  name = "Cliff",                          category = "Psychopath" },
    { id = 783,  name = "Sean",                           category = "Psychopath" },
    { id = 784,  name = "Adam",                           category = "Psychopath" },
    { id = 785,  name = "Jo",                             category = "Psychopath" },
    { id = 786,  name = "Paul",                           category = "Psychopath" },
    { id = 789,  name = "David Bailey",                   category = "Survivor" },
    { id = 790,  name = "Gordon Stalworth",               category = "Survivor" },
    { id = 791,  name = "Ronald Shiner",                  category = "Survivor" },
    { id = 792,  name = "Floyd Sanders",                  category = "Survivor" },
    { id = 793,  name = "Burt Thompson",                  category = "Survivor" },
    { id = 794,  name = "Jolie Wu",                       category = "Survivor" },
    { id = 795,  name = "Rachel Decker",                  category = "Survivor" },
    { id = 796,  name = "Leah Stein",                     category = "Survivor" },
    { id = 797,  name = "Yuu Tanaka",                     category = "Survivor" },
    { id = 799,  name = "Leroy McKenna",                  category = "Survivor" },
    { id = 800,  name = "Tonya Waters",                   category = "Survivor" },
    { id = 801,  name = "Simone Ravendark",               category = "Survivor" },
    { id = 802,  name = "Aaron Swoop",                    category = "Survivor" },
    { id = 803,  name = "Shinji Kitano",                  category = "Survivor" },
    { id = 804,  name = "Ross Folk",                      category = "Survivor" },
    { id = 807,  name = "Convicts Day 1",                 category = "Psychopath" },
    { id = 810,  name = "Cletus",                         category = "Psychopath" },
    { id = 811,  name = "Cult Cutscene + Raincoats",      category = "Event" },
    { id = 812,  name = "Heather Tompkins",               category = "Survivor" },
    { id = 814,  name = "Kindell Johnson",                category = "Survivor" },
    { id = 815,  name = "Susan Walsh",                    category = "Survivor" },
    { id = 816,  name = "Natalie, Jeff, Bill Brenton",    category = "Survivor" },
    { id = 817,  name = "Sally Mills",                    category = "Survivor" },
    { id = 818,  name = "Gil Jiminez",                    category = "Survivor" },
    { id = 819,  name = "Brett Styles",                   category = "Survivor" },
    { id = 820,  name = "Pamela Tompkins",                category = "Survivor" },
    { id = 821,  name = "Nick Evans",                     category = "Survivor" },
    { id = 822,  name = "Jonathan Picardson",             category = "Survivor" },
    { id = 823,  name = "Alyssa Laurent",                 category = "Survivor" },
    { id = 2698, name = "Sophie Richard",                 category = "Survivor" },
    { id = 2699, name = "Jennifer Gorman",                category = "Survivor" },
    { id = 2700, name = "Ray Mathison",                   category = "Survivor" },
    { id = 2701, name = "Nathan Crabbe",                  category = "Survivor" },
    { id = 2702, name = "Michelle Feltz",                 category = "Survivor" },
    { id = 2703, name = "Cheryl Jones",                   category = "Survivor" },
    { id = 2704, name = "Beth Shrake",                    category = "Survivor" },
    { id = 2705, name = "Josh Manning",                   category = "Survivor" },
    { id = 2706, name = "Barbara Patterson",              category = "Survivor" },
    { id = 2707, name = "Rich Atkins",                    category = "Survivor" },
    { id = 2708, name = "Mindy Baker",                    category = "Survivor" },
    { id = 2709, name = "Debbie Willet",                  category = "Survivor" },
    { id = 2711, name = "Greg Simpson",                   category = "Survivor" },
    { id = 2712, name = "Kay Nelson",                     category = "Survivor" },
    { id = 2713, name = "Lilly Deacon",                   category = "Survivor" },
    { id = 2714, name = "Kelly Carpenter",                category = "Survivor" },
    { id = 2715, name = "Janet Star",                     category = "Survivor" },
}

------------------------------------------------------------
-- State
------------------------------------------------------------

local gui_visible = false
local selected_flags = {}  -- { [flag_id] = true/false }
local filter_category = "All"
local show_only_unset = false

------------------------------------------------------------
-- Flag Operations
------------------------------------------------------------

local function check_flag(flag_id)
    local efm = efm_mgr:get()
    if not efm then return nil end

    local ok, result = pcall(function()
        return efm:call("evFlagCheck", flag_id)
    end)

    if ok then
        return result == true
    end
    return nil
end

local function set_flag_on(flag_id)
    local efm = efm_mgr:get()
    if not efm then
        M.log("ERROR: EventFlagsManager not available")
        return false
    end

    local ok, err = pcall(function()
        efm:call("evFlagOn", flag_id)
    end)

    if ok then
        M.log(string.format("Flag %d set ON", flag_id))
        return true
    end

    M.log(string.format("Could not set flag %d ON: %s", flag_id, tostring(err)))
    return false
end

------------------------------------------------------------
-- Spawn Functions
------------------------------------------------------------

function M.spawn_flag(flag_id)
    return set_flag_on(flag_id)
end

function M.spawn_selected()
    local count = 0
    for flag_id, is_selected in pairs(selected_flags) do
        if is_selected then
            if set_flag_on(flag_id) then
                count = count + 1
            end
        end
    end
    M.log(string.format("Spawned %d NPCs/Events", count))
    return count
end

function M.spawn_all()
    local count = 0
    for _, entry in ipairs(SPAWN_FLAGS) do
        if set_flag_on(entry.id) then
            count = count + 1
        end
    end
    M.log(string.format("Spawned ALL %d NPCs/Events", count))
    return count
end

function M.spawn_category(category)
    local count = 0
    for _, entry in ipairs(SPAWN_FLAGS) do
        if entry.category == category then
            if set_flag_on(entry.id) then
                count = count + 1
            end
        end
    end
    M.log(string.format("Spawned %d %s entries", count, category))
    return count
end

function M.select_all()
    for _, entry in ipairs(SPAWN_FLAGS) do
        selected_flags[entry.id] = true
    end
end

function M.select_none()
    selected_flags = {}
end

function M.select_category(category)
    for _, entry in ipairs(SPAWN_FLAGS) do
        if entry.category == category then
            selected_flags[entry.id] = true
        end
    end
end

------------------------------------------------------------
-- GUI Drawing
------------------------------------------------------------

local function get_category_color(category)
    if category == "Psychopath" then
        return 0xFFFF6666  -- Red
    elseif category == "Survivor" then
        return 0xFF66FF66  -- Green
    elseif category == "Event" then
        return 0xFF66FFFF  -- Cyan
    else
        return 0xFFFFFFFF  -- White
    end
end

local function draw_main_window()
    if not gui_visible then return end

    imgui.set_next_window_size(Vector2f.new(450, 600), 4)

    local still_open = imgui.begin_window("NPC Spawner", true, 0)
    if not still_open then
        gui_visible = false
        imgui.end_window()
        return
    end

    -- Status
    local efm = efm_mgr:get()
    local status_color = efm and 0xFF00FF00 or 0xFFFF0000
    local status_text = efm and "EventFlagsManager: OK" or "EventFlagsManager: NOT AVAILABLE"
    imgui.text_colored(status_text, status_color)

    imgui.separator()

    -- Action buttons row 1
    if imgui.button("Spawn Selected") then
        M.spawn_selected()
    end
    imgui.same_line()
    if imgui.button("Spawn ALL") then
        M.spawn_all()
    end

    -- Action buttons row 2
    if imgui.button("Spawn Survivors") then
        M.spawn_category("Survivor")
    end
    imgui.same_line()
    if imgui.button("Spawn Psychopaths") then
        M.spawn_category("Psychopath")
    end
    imgui.same_line()
    if imgui.button("Spawn Events") then
        M.spawn_category("Event")
    end

    imgui.separator()

    -- Selection buttons
    if imgui.button("Select All") then
        M.select_all()
    end
    imgui.same_line()
    if imgui.button("Select None") then
        M.select_none()
    end
    imgui.same_line()
    if imgui.button("Select Survivors") then
        M.select_category("Survivor")
    end
    imgui.same_line()
    if imgui.button("Select Psychos") then
        M.select_category("Psychopath")
    end

    imgui.separator()

    -- Filter options
    imgui.text("Filter:")
    imgui.same_line()
    if imgui.button("All") then filter_category = "All" end
    imgui.same_line()
    if imgui.button("Survivors") then filter_category = "Survivor" end
    imgui.same_line()
    if imgui.button("Psychopaths") then filter_category = "Psychopath" end
    imgui.same_line()
    if imgui.button("Events") then filter_category = "Event" end

    local changed, new_val = imgui.checkbox("Show only unset flags", show_only_unset)
    if changed then show_only_unset = new_val end

    imgui.separator()

    -- Count selected
    local selected_count = 0
    for _, v in pairs(selected_flags) do
        if v then selected_count = selected_count + 1 end
    end
    imgui.text(string.format("Selected: %d / %d", selected_count, #SPAWN_FLAGS))

    imgui.separator()

    -- Scrollable flag list
    imgui.begin_child_window("FlagList", Vector2f.new(0, 0), true, 0)

    for _, entry in ipairs(SPAWN_FLAGS) do
        -- Apply category filter
        if filter_category == "All" or entry.category == filter_category then
            local is_set = check_flag(entry.id)

            -- Apply unset filter
            if not show_only_unset or not is_set then
                local is_selected = selected_flags[entry.id] or false

                -- Checkbox for selection
                local changed, new_selected = imgui.checkbox("##sel_" .. entry.id, is_selected)
                if changed then
                    selected_flags[entry.id] = new_selected
                end

                imgui.same_line()

                -- Quick spawn button
                if imgui.button("Spawn##" .. entry.id) then
                    set_flag_on(entry.id)
                end

                imgui.same_line()

                -- Flag info with color coding
                local color = get_category_color(entry.category)
                local set_indicator = is_set and " [SET]" or ""
                if is_set then
                    color = 0xFF888888  -- Dim if already set
                end

                imgui.text_colored(
                    string.format("%d: %s (%s)%s", entry.id, entry.name, entry.category, set_indicator),
                    color
                )
            end
        end
    end

    imgui.end_child_window()

    imgui.end_window()
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

function M.show_window()
    gui_visible = true
end

function M.hide_window()
    gui_visible = false
end

function M.toggle_window()
    gui_visible = not gui_visible
end

function M.is_visible()
    return gui_visible
end

function M.get_spawn_flags()
    return SPAWN_FLAGS
end

------------------------------------------------------------
-- REFramework Hooks
------------------------------------------------------------

re.on_frame(function()
    if gui_visible then
        draw_main_window()
    end
end)

re.on_draw_ui(function()
    local changed, new_val = imgui.checkbox("Show NPC Spawner", gui_visible)
    if changed then
        gui_visible = new_val
    end
end)

------------------------------------------------------------
-- Console Helpers
------------------------------------------------------------

_G.npc_spawn = function(id)
    return M.spawn_flag(id)
end

_G.npc_spawn_all = function()
    return M.spawn_all()
end

_G.npc_spawn_survivors = function()
    return M.spawn_category("Survivor")
end

_G.npc_spawn_psychos = function()
    return M.spawn_category("Psychopath")
end

_G.npc_spawner = function()
    M.show_window()
end

------------------------------------------------------------
-- Module Load
------------------------------------------------------------

M.log("NpcSpawner loaded")
M.log("Commands: npc_spawn(id), npc_spawn_all(), npc_spawn_survivors(), npc_spawn_psychos(), npc_spawner()")

return M