-- DRAP/DoorVisualizer.lua
-- Door Randomization Map Visualizer
-- Generates an interactive HTML visualization of door connections on Mall.png
-- and opens it in the default browser on demand.

local Shared = require("DRAP/Shared")

local M = Shared.create_module("DoorVisualizer")

------------------------------------------------------------
-- Configuration
------------------------------------------------------------

local HTML_OUTPUT_PATH = "door_map.html"
local MALL_PNG_PATH = "Mall.png"

------------------------------------------------------------
-- Base64 Encoder
------------------------------------------------------------

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64_encode(data)
    local parts = {}
    local len = #data
    for i = 1, len, 3 do
        local b1 = data:byte(i)
        local b2 = (i + 1 <= len) and data:byte(i + 1) or 0
        local b3 = (i + 2 <= len) and data:byte(i + 2) or 0

        local n = b1 * 65536 + b2 * 256 + b3

        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64

        local remaining = len - i + 1
        if remaining >= 3 then
            parts[#parts + 1] = b64chars:sub(c1+1,c1+1) .. b64chars:sub(c2+1,c2+1) ..
                                b64chars:sub(c3+1,c3+1) .. b64chars:sub(c4+1,c4+1)
        elseif remaining == 2 then
            parts[#parts + 1] = b64chars:sub(c1+1,c1+1) .. b64chars:sub(c2+1,c2+1) ..
                                b64chars:sub(c3+1,c3+1) .. "="
        else
            parts[#parts + 1] = b64chars:sub(c1+1,c1+1) .. b64chars:sub(c2+1,c2+1) .. "=="
        end
    end
    return table.concat(parts)
end

local function load_mall_png_base64()
    local file = io.open(MALL_PNG_PATH, "rb")
    if not file then
        M.log("WARNING: Could not open " .. MALL_PNG_PATH)
        return nil
    end
    local data = file:read("*a")
    file:close()
    if not data or #data == 0 then
        M.log("WARNING: " .. MALL_PNG_PATH .. " is empty")
        return nil
    end
    M.log(string.format("Read %s (%d bytes)", MALL_PNG_PATH, #data))
    return base64_encode(data)
end

------------------------------------------------------------
-- Static Data: Area Colors (17 areas)
------------------------------------------------------------

local AREA_COLORS = {
    s200 = "#FF1744",  -- Paradise Plaza
    sa00 = "#FF6D00",  -- Food Court
    s135 = "#FFD600",  -- Helipad
    s401 = "#76FF03",  -- Hideout
    s136 = "#00C853",  -- Safe Room
    s100 = "#00BFA5",  -- Entrance Plaza
    s700 = "#00E5FF",  -- Leisure Park
    s231 = "#2979FF",  -- Rooftop
    s503 = "#304FFE",  -- Colby's
    s300 = "#AA00FF",  -- Wonderland Plaza
    s230 = "#D500F9",  -- Service Hallway
    s400 = "#FF4081",  -- North Plaza
    s601 = "#8D6E63",  -- Butcher
    s600 = "#78909C",  -- Maintenance Tunnel
    s500 = "#FFFFFF",  -- Grocery Store
    s501 = "#CE93D8",  -- Crislip's
    s900 = "#AED581",  -- Al Fresca Plaza
}

------------------------------------------------------------
-- Static Data: Area Short Names
------------------------------------------------------------

local AREA_SHORT_NAMES = {
    s135 = "Helipad",       s136 = "Safe Room",     s231 = "Rooftop",
    s230 = "Svc Hall",      s200 = "Paradise",      s100 = "Entrance",
    s900 = "Al Fresca",     sa00 = "Food Court",    s300 = "Wonderland",
    s400 = "North Plaza",   s700 = "Leisure Pk",    s501 = "Crislip's",
    s503 = "Colby's",       s401 = "Hideout",       s600 = "Tunnels",
    s500 = "Grocery",       s601 = "Butcher",
}

------------------------------------------------------------
-- Static Data: Door Map Positions (pixel x,y on Mall.png)
------------------------------------------------------------

local DOOR_MAP_POSITIONS = {
    ["SCN_s900|s100|door0"] = {496.2, 513.2},
    ["SCN_s900|s600|door0"] = {354.2, 582.1},
    ["SCN_s900|sa00|door0"] = {264.4, 570.1},
    ["SCN_sa00|s300|door0"] = {207.2, 511.6},
    ["SCN_sa00|s600|door0"] = {203.2, 526.2},
    ["SCN_sa00|s700|door0"] = {253.1, 518.9},
    ["SCN_s100|s136|door0"] = {712.4, 731.4},
    ["SCN_s100|s200|door0"] = {545.9, 500.1},
    ["SCN_s100|s900|door0"] = {507.7, 512.3},
    ["SCN_s135|s136|door0"] = {754.1, 660.3},
    ["SCN_s601|s600|door0"] = {99.0, 79.1},
    ["SCN_s700|s200|door0"] = {530.2, 317.5},
    ["SCN_s700|s400|door0"] = {407.2, 162.3},
    ["SCN_s700|s600|door0"] = {121.3, 149.5},
    ["SCN_s700|sa00|door0"] = {260.5, 510.0},
    ["SCN_s503|s200|door0"] = {524.3, 203.6},
    ["SCN_s600|s200|door0"] = {649.0, 306.6},
    ["SCN_s600|s500|door0"] = {57.9, 23.1},
    ["SCN_s600|s601|door0"] = {98.8, 92.2},
    ["SCN_s600|s700|door0"] = {133.6, 149.9},
    ["SCN_s600|s900|door0"] = {354.7, 598.3},
    ["SCN_s600|sa00|door0"] = {189.5, 531.9},
    ["SCN_s501|s400|door0"] = {447.7, 128.7},
    ["SCN_s500|s400|door0"] = {131.6, 52.4},
    ["SCN_s500|s600|door0"] = {72.3, 23.5},
    ["SCN_s401|s400|door0"] = {366.3, 58.0},
    ["SCN_s400|s401|door0"] = {366.3, 78.0},
    ["SCN_s400|s500|door0"] = {132.3, 68.6},
    ["SCN_s400|s501|door0"] = {433.4, 128.8},
    ["SCN_s400|s700|door0"] = {407.0, 148.3},
    ["SCN_s200|s100|door0"] = {556.7, 490.1},
    ["SCN_s200|s230|door0"] = {601.4, 438.2},
    ["SCN_s200|s300|door0"] = {661.7, 331.7},
    ["SCN_s200|s503|door0"] = {523.0, 216.8},
    ["SCN_s200|s600|door0"] = {648.7, 320.2},
    ["SCN_s200|s700|door0"] = {540.6, 307.2},
    ["SCN_s231|s136|door0"] = {707.8, 457.3},
    ["SCN_s231|s230|door0"] = {738.5, 476.6},
    ["SCN_s231|s230|door1"] = {703.3, 482.5},
    ["SCN_s136|s100|door0"] = {724.8, 730.9},
    ["SCN_s136|s135|door0"] = {734.1, 714.5},
    ["SCN_s136|s231|door0"] = {734.6, 687.8},
    ["SCN_s230|s200|door0"] = {622.5, 441.5},
    ["SCN_s230|s231|door0"] = {650.1, 448.7},
    ["SCN_s230|s231|door1"] = {647.1, 490.0},
    ["SCN_s300|s200|door0"] = {228.1, 316.5},
    ["SCN_s300|s400|door0"] = {135.9, 213.0},
    ["SCN_s400|s300|door0"] = {131.9, 197.0},
    ["SCN_s400|s300|door1"] = {262.1, 233.5},
    ["SCN_s300|s400|door1"] = {262.7, 249.2},
    ["SCN_s300|sa00|door0"] = {204.2, 497.4},
}

------------------------------------------------------------
-- Static Data: Vanilla Door Definitions
-- from_area, to_area, door_no for each door in the game
------------------------------------------------------------

local VANILLA_DOORS = {
    ["SCN_s100|s136|door0"] = {from_area = "s100", to_area = "s136", door_no = 0},
    ["SCN_s100|s200|door0"] = {from_area = "s100", to_area = "s200", door_no = 0},
    ["SCN_s100|s900|door0"] = {from_area = "s100", to_area = "s900", door_no = 0},
    ["SCN_s135|s136|door0"] = {from_area = "s135", to_area = "s136", door_no = 0},
    ["SCN_s136|s100|door0"] = {from_area = "s136", to_area = "s100", door_no = 0},
    ["SCN_s136|s135|door0"] = {from_area = "s136", to_area = "s135", door_no = 0},
    ["SCN_s136|s231|door0"] = {from_area = "s136", to_area = "s231", door_no = 0},
    ["SCN_s200|s100|door0"] = {from_area = "s200", to_area = "s100", door_no = 0},
    ["SCN_s200|s230|door0"] = {from_area = "s200", to_area = "s230", door_no = 0},
    ["SCN_s200|s300|door0"] = {from_area = "s200", to_area = "s300", door_no = 0},
    ["SCN_s200|s503|door0"] = {from_area = "s200", to_area = "s503", door_no = 0},
    ["SCN_s200|s600|door0"] = {from_area = "s200", to_area = "s600", door_no = 0},
    ["SCN_s200|s700|door0"] = {from_area = "s200", to_area = "s700", door_no = 0},
    ["SCN_s230|s200|door0"] = {from_area = "s230", to_area = "s200", door_no = 0},
    ["SCN_s230|s231|door0"] = {from_area = "s230", to_area = "s231", door_no = 0},
    ["SCN_s230|s231|door1"] = {from_area = "s230", to_area = "s231", door_no = 1},
    ["SCN_s231|s136|door0"] = {from_area = "s231", to_area = "s136", door_no = 0},
    ["SCN_s231|s230|door0"] = {from_area = "s231", to_area = "s230", door_no = 0},
    ["SCN_s231|s230|door1"] = {from_area = "s231", to_area = "s230", door_no = 1},
    ["SCN_s300|s200|door0"] = {from_area = "s300", to_area = "s200", door_no = 0},
    ["SCN_s300|s400|door0"] = {from_area = "s300", to_area = "s400", door_no = 0},
    ["SCN_s300|s400|door1"] = {from_area = "s300", to_area = "s400", door_no = 1},
    ["SCN_s300|sa00|door0"] = {from_area = "s300", to_area = "sa00", door_no = 0},
    ["SCN_s400|s300|door0"] = {from_area = "s400", to_area = "s300", door_no = 0},
    ["SCN_s400|s300|door1"] = {from_area = "s400", to_area = "s300", door_no = 1},
    ["SCN_s400|s401|door0"] = {from_area = "s400", to_area = "s401", door_no = 0},
    ["SCN_s400|s500|door0"] = {from_area = "s400", to_area = "s500", door_no = 0},
    ["SCN_s400|s501|door0"] = {from_area = "s400", to_area = "s501", door_no = 0},
    ["SCN_s400|s700|door0"] = {from_area = "s400", to_area = "s700", door_no = 0},
    ["SCN_s401|s400|door0"] = {from_area = "s401", to_area = "s400", door_no = 0},
    ["SCN_s500|s400|door0"] = {from_area = "s500", to_area = "s400", door_no = 0},
    ["SCN_s500|s600|door0"] = {from_area = "s500", to_area = "s600", door_no = 0},
    ["SCN_s501|s400|door0"] = {from_area = "s501", to_area = "s400", door_no = 0},
    ["SCN_s503|s200|door0"] = {from_area = "s503", to_area = "s200", door_no = 0},
    ["SCN_s600|s200|door0"] = {from_area = "s600", to_area = "s200", door_no = 0},
    ["SCN_s600|s500|door0"] = {from_area = "s600", to_area = "s500", door_no = 0},
    ["SCN_s600|s601|door0"] = {from_area = "s600", to_area = "s601", door_no = 0},
    ["SCN_s600|s700|door0"] = {from_area = "s600", to_area = "s700", door_no = 0},
    ["SCN_s600|s900|door0"] = {from_area = "s600", to_area = "s900", door_no = 0},
    ["SCN_s600|sa00|door0"] = {from_area = "s600", to_area = "sa00", door_no = 0},
    ["SCN_s601|s600|door0"] = {from_area = "s601", to_area = "s600", door_no = 0},
    ["SCN_s700|s200|door0"] = {from_area = "s700", to_area = "s200", door_no = 0},
    ["SCN_s700|s400|door0"] = {from_area = "s700", to_area = "s400", door_no = 0},
    ["SCN_s700|s600|door0"] = {from_area = "s700", to_area = "s600", door_no = 0},
    ["SCN_s700|sa00|door0"] = {from_area = "s700", to_area = "sa00", door_no = 0},
    ["SCN_s900|s100|door0"] = {from_area = "s900", to_area = "s100", door_no = 0},
    ["SCN_s900|s600|door0"] = {from_area = "s900", to_area = "s600", door_no = 0},
    ["SCN_s900|sa00|door0"] = {from_area = "s900", to_area = "sa00", door_no = 0},
    ["SCN_sa00|s300|door0"] = {from_area = "sa00", to_area = "s300", door_no = 0},
    ["SCN_sa00|s600|door0"] = {from_area = "sa00", to_area = "s600", door_no = 0},
    ["SCN_sa00|s700|door0"] = {from_area = "sa00", to_area = "s700", door_no = 0},
}

------------------------------------------------------------
-- JSON Serialization Helpers
------------------------------------------------------------

local function escape_json_string(s)
    return s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r')
end

local function serialize_connections_json(connections)
    local items = {}
    for _, c in ipairs(connections) do
        items[#items + 1] = string.format(
            '{"id":"%s","sx":%.1f,"sy":%.1f,"dx":%.1f,"dy":%.1f,' ..
            '"fromArea":"%s","toAreaVanilla":"%s","toAreaEffective":"%s",' ..
            '"redirected":%s,"doorNo":%d,"label":"%s"}',
            escape_json_string(c.id), c.sx, c.sy, c.dx, c.dy,
            c.fromArea, c.toAreaVanilla, c.toAreaEffective,
            c.redirected and "true" or "false", c.doorNo,
            escape_json_string(c.label))
    end
    return "[" .. table.concat(items, ",") .. "]"
end

local function serialize_object_json(tbl)
    local items = {}
    for k, v in pairs(tbl) do
        items[#items + 1] = string.format('"%s":"%s"', k, escape_json_string(v))
    end
    return "{" .. table.concat(items, ",") .. "}"
end

------------------------------------------------------------
-- Connection Building Logic
------------------------------------------------------------

local function build_connections()
    local DoorRandomizer = require("DRAP/DoorRandomizer")
    local redirects = DoorRandomizer.get_redirects()
    local connections = {}

    for door_id, door in pairs(VANILLA_DOORS) do
        local src_pos = DOOR_MAP_POSITIONS[door_id]
        if src_pos then
            local is_redirected = (redirects[door_id] ~= nil)
            local effective_to_area = door.to_area
            local dest_pos = nil

            if is_redirected then
                local redirect = redirects[door_id]
                effective_to_area = redirect.target_area
                local template_door_id = redirect.template_door_id

                -- Find destination position via template door's reverse
                if template_door_id and VANILLA_DOORS[template_door_id] then
                    local target_door = VANILLA_DOORS[template_door_id]
                    local reverse_id = string.format("SCN_%s|%s|door%d",
                        target_door.to_area, target_door.from_area, target_door.door_no)
                    if DOOR_MAP_POSITIONS[reverse_id] then
                        dest_pos = DOOR_MAP_POSITIONS[reverse_id]
                    end
                end
                -- Fallback: template door's own position
                if not dest_pos and template_door_id then
                    dest_pos = DOOR_MAP_POSITIONS[template_door_id]
                end
                -- Fallback: any reverse door from dest area back to source area
                if not dest_pos then
                    for other_id, other_door in pairs(VANILLA_DOORS) do
                        if other_door.from_area == effective_to_area
                           and other_door.to_area == door.from_area
                           and DOOR_MAP_POSITIONS[other_id] then
                            dest_pos = DOOR_MAP_POSITIONS[other_id]
                            break
                        end
                    end
                end
            end

            -- Non-redirected or all redirected lookups failed
            if not dest_pos then
                local ideal_reverse = string.format("SCN_%s|%s|door%d",
                    effective_to_area, door.from_area, door.door_no)
                if DOOR_MAP_POSITIONS[ideal_reverse] then
                    dest_pos = DOOR_MAP_POSITIONS[ideal_reverse]
                else
                    for other_id, other_door in pairs(VANILLA_DOORS) do
                        if other_door.from_area == effective_to_area
                           and other_door.to_area == door.from_area
                           and DOOR_MAP_POSITIONS[other_id] then
                            dest_pos = DOOR_MAP_POSITIONS[other_id]
                            break
                        end
                    end
                end
            end

            -- Last resort: any door whose from_area is the destination
            if not dest_pos then
                for other_id, other_door in pairs(VANILLA_DOORS) do
                    if other_door.from_area == effective_to_area
                       and DOOR_MAP_POSITIONS[other_id] then
                        dest_pos = DOOR_MAP_POSITIONS[other_id]
                        break
                    end
                end
            end

            if dest_pos then
                local from_name = AREA_SHORT_NAMES[door.from_area] or door.from_area
                local vanilla_to_name = AREA_SHORT_NAMES[door.to_area] or door.to_area
                local effective_to_name = AREA_SHORT_NAMES[effective_to_area] or effective_to_area
                local label
                if is_redirected then
                    label = from_name .. " -> " .. vanilla_to_name .. "  =>  " .. effective_to_name
                else
                    label = from_name .. " -> " .. effective_to_name
                end

                connections[#connections + 1] = {
                    id = door_id,
                    sx = src_pos[1], sy = src_pos[2],
                    dx = dest_pos[1], dy = dest_pos[2],
                    fromArea = door.from_area,
                    toAreaVanilla = door.to_area,
                    toAreaEffective = effective_to_area,
                    redirected = is_redirected,
                    doorNo = door.door_no,
                    label = label,
                }
            end
        end
    end
    return connections
end

------------------------------------------------------------
-- HTML Generation Helpers
------------------------------------------------------------

local function build_redirect_list_html(redirects)
    local items = {}
    -- Collect and sort redirect door IDs for consistent ordering
    local sorted_ids = {}
    for door_id, _ in pairs(redirects) do
        sorted_ids[#sorted_ids + 1] = door_id
    end
    table.sort(sorted_ids)

    for _, door_id in ipairs(sorted_ids) do
        local redirect = redirects[door_id]
        local vanilla = VANILLA_DOORS[door_id]
        if vanilla and redirect then
            local orig_from = AREA_SHORT_NAMES[vanilla.from_area] or vanilla.from_area
            local orig_to = AREA_SHORT_NAMES[vanilla.to_area] or vanilla.to_area
            local new_to = AREA_SHORT_NAMES[redirect.target_area] or redirect.target_area
            local door_tag = ""
            if vanilla.door_no > 0 then
                door_tag = " #" .. vanilla.door_no
            end
            items[#items + 1] = string.format(
                '<div class="redir-item" data-door-id="%s">' ..
                '<span class="ri-orig">%s &rarr; %s%s</span>' ..
                ' <span class="ri-arrow">&rArr;</span> ' ..
                '<span class="ri-new">%s</span></div>',
                door_id, orig_from, orig_to, door_tag, new_to)
        end
    end
    return table.concat(items, "\n")
end

local function build_area_chips_html(connections)
    -- Collect unique from-areas from connections
    local area_set = {}
    for _, c in ipairs(connections) do
        area_set[c.fromArea] = true
    end
    -- Sort by short name
    local areas = {}
    for area, _ in pairs(area_set) do
        areas[#areas + 1] = area
    end
    table.sort(areas, function(a, b)
        return (AREA_SHORT_NAMES[a] or a) < (AREA_SHORT_NAMES[b] or b)
    end)

    local chips = {}
    for _, area_code in ipairs(areas) do
        local color = AREA_COLORS[area_code] or "#888"
        local name = AREA_SHORT_NAMES[area_code] or area_code
        chips[#chips + 1] = string.format(
            '<button class="area-chip" data-area="%s" style="--chip-color:%s">%s</button>',
            area_code, color, name)
    end
    return table.concat(chips, "\n")
end

------------------------------------------------------------
-- HTML Generation: Full Interactive Map Visualization
------------------------------------------------------------

local function generate_html()
    local DoorRandomizer = require("DRAP/DoorRandomizer")
    local redirects = DoorRandomizer.get_redirects()
    local connections = build_connections()

    -- Serialize data for JS injection
    local connections_json = serialize_connections_json(connections)
    local area_colors_json = serialize_object_json(AREA_COLORS)
    local area_names_json = serialize_object_json(AREA_SHORT_NAMES)

    -- Count stats
    local num_areas = 0
    local area_set = {}
    for _, conn in ipairs(connections) do
        if not area_set[conn.fromArea] then
            area_set[conn.fromArea] = true
            num_areas = num_areas + 1
        end
    end
    local num_redirects = DoorRandomizer.get_redirect_config_count()

    -- Build dynamic HTML fragments
    local redir_html = build_redirect_list_html(redirects)
    local chips_html = build_area_chips_html(connections)

    -- Load Mall.png and embed as base64 data URI
    local mall_b64 = load_mall_png_base64()
    local img_src
    if mall_b64 then
        img_src = "data:image/png;base64," .. mall_b64
    else
        img_src = "Mall.png"  -- fallback to relative path
    end

    -- Build full HTML using efficient table.concat pattern
    local parts = {}
    local function emit(s) parts[#parts + 1] = s end

    -- HEAD + CSS
    emit([==[<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Door Randomization Map</title>
<style>
:root {
    --bg-primary: #0f1117;
    --bg-sidebar: #161920;
    --bg-card: #1e2028;
    --bg-card-hover: #262830;
    --border: #2a2d35;
    --text-primary: #e4e4e7;
    --text-secondary: #8b8d98;
    --text-muted: #5f6170;
    --accent: #22c997;
    --accent-hover: #1db385;
    --accent-dim: rgba(34,201,151,0.15);
    --red: #ef5350;
    --red-dim: rgba(239,83,80,0.12);
    --yellow: #fbbf24;
    --green: #4ade80;
}
* { margin:0; padding:0; box-sizing:border-box; }
body { font-family:'Inter','Segoe UI',system-ui,sans-serif; background:var(--bg-primary); color:var(--text-primary); display:flex; height:100vh; overflow:hidden; }

/* Sidebar */
#sidebar {
    width:370px; min-width:370px; background:var(--bg-sidebar);
    display:flex; flex-direction:column; border-right:1px solid var(--border);
    transition:margin-left 0.25s ease, opacity 0.25s ease;
}
#sidebar.collapsed { margin-left:-370px; opacity:0; pointer-events:none; }

#sidebar-toggle {
    position:absolute; top:16px; left:16px; z-index:150;
    width:36px; height:36px; border:1px solid var(--border); border-radius:8px;
    background:rgba(22,25,32,0.92); color:var(--text-secondary);
    font-size:1.1em; cursor:pointer; display:flex; align-items:center; justify-content:center;
    backdrop-filter:blur(8px); -webkit-backdrop-filter:blur(8px);
    transition:all 0.15s; box-shadow:0 2px 10px rgba(0,0,0,0.3);
}
#sidebar-toggle:hover { background:var(--bg-card-hover); color:var(--text-primary); border-color:#444; }

#sidebar-header { padding:16px; border-bottom:1px solid var(--border); }
#sidebar-header h1 { font-size:1.15em; color:var(--text-primary); margin-bottom:8px; font-weight:700; letter-spacing:-0.02em; }
.stats {
    background:var(--bg-card); padding:10px 12px; border-radius:6px;
    font-size:0.82em; margin:8px 0; display:flex; gap:16px; color:var(--text-secondary);
    border:1px solid var(--border);
}
.stats span { white-space:nowrap; }
.stats strong { color:var(--text-primary); font-weight:600; }

.legend { display:flex; gap:16px; font-size:0.75em; padding:6px 0 2px; flex-wrap:wrap; color:var(--text-secondary); }
.legend-item { display:flex; align-items:center; gap:5px; }
.legend-swatch { width:20px; height:3px; border-radius:2px; }

/* Floating filter panel */
#filter-panel {
    position:absolute; bottom:16px; left:16px; z-index:100;
    background:rgba(22,25,32,0.92); border:1px solid var(--border);
    border-radius:10px; padding:10px 14px; max-width:360px;
    backdrop-filter:blur(12px); -webkit-backdrop-filter:blur(12px);
    box-shadow:0 4px 20px rgba(0,0,0,0.4);
}
.filter-panel-label {
    font-size:0.7em; color:var(--text-muted); margin-bottom:6px;
    font-weight:600; text-transform:uppercase; letter-spacing:0.06em;
}
#area-chips { display:flex; gap:4px; flex-wrap:wrap; }
.area-chip {
    padding:3px 10px; border:1.5px solid var(--chip-color, #888); border-radius:20px;
    background:transparent; color:var(--text-secondary); cursor:pointer; font-size:0.7em;
    font-weight:600; transition:all 0.15s; white-space:nowrap;
}
.area-chip:hover { background:color-mix(in srgb, var(--chip-color) 20%, transparent); color:var(--text-primary); }
.area-chip.active { background:var(--chip-color); color:#111; border-color:var(--chip-color); }

.filter-bar { display:flex; gap:4px; margin:6px 0; }
.filter-bar button {
    padding:5px 12px; border:1px solid var(--border); border-radius:6px;
    background:var(--bg-card); color:var(--text-secondary); cursor:pointer;
    font-size:0.75em; transition:all 0.15s; font-weight:600;
}
.filter-bar button:hover { background:var(--bg-card-hover); color:var(--text-primary); }
.filter-bar button.active { background:var(--accent); color:#fff; border-color:var(--accent); }

/* Redirect list */
.section-title {
    font-size:0.82em; font-weight:700; color:var(--text-primary);
    padding:6px 0 4px; margin:8px 0 2px; border-bottom:1px solid var(--border);
}
#redir-list { flex:1; overflow-y:auto; padding:6px 12px; }
#redir-list::-webkit-scrollbar { width:6px; }
#redir-list::-webkit-scrollbar-track { background:transparent; }
#redir-list::-webkit-scrollbar-thumb { background:var(--border); border-radius:3px; }
#redir-list::-webkit-scrollbar-thumb:hover { background:#444; }

.redir-item {
    background:var(--bg-card); padding:8px 10px; margin:3px 0; border-radius:6px;
    font-size:0.8em; cursor:pointer; border-left:3px solid transparent;
    transition:all 0.12s; border:1px solid transparent;
}
.redir-item:hover { background:var(--bg-card-hover); border-color:var(--border); }
.redir-item.highlight { border-left-color:var(--accent); background:var(--accent-dim); border-color:var(--accent); }
.redir-item.hidden { display:none; }
.ri-orig { color:var(--red); text-decoration:line-through; opacity:0.85; }
.ri-arrow { color:var(--text-muted); margin:0 2px; }
.ri-new  { color:var(--green); font-weight:600; }

/* Map */
#map-area { flex:1; position:relative; overflow:hidden; background:#0a0a0c; cursor:grab; }
#map-area.grabbing { cursor:grabbing; }
#map-container { position:absolute; transform-origin:0 0; }
#map-image { display:block; }
canvas#overlay { position:absolute; top:0; left:0; pointer-events:none; }

/* Tooltip */
#tooltip {
    position:fixed; background:rgba(15,17,23,0.95); color:var(--text-primary);
    padding:8px 12px; border-radius:8px; font-size:0.8em;
    pointer-events:none; z-index:200; display:none;
    max-width:340px; line-height:1.5; border:1px solid var(--border);
    backdrop-filter:blur(8px); -webkit-backdrop-filter:blur(8px);
    box-shadow:0 4px 20px rgba(0,0,0,0.4);
}

/* Zoom controls */
#zoom-ctrls {
    position:absolute; bottom:16px; right:16px;
    display:flex; flex-direction:column; gap:3px; z-index:100;
}
#zoom-ctrls button {
    width:32px; height:32px; border:1px solid var(--border); border-radius:6px;
    background:rgba(22,25,32,0.9); color:var(--text-secondary); font-size:1.1em;
    cursor:pointer; display:flex; align-items:center; justify-content:center;
    backdrop-filter:blur(8px); -webkit-backdrop-filter:blur(8px);
    transition:all 0.15s;
}
#zoom-ctrls button:hover { background:var(--bg-card-hover); color:var(--text-primary); border-color:#444; }

/* Pathway Mode */
#pathway-section {
    border-top:1px solid var(--border); padding:0 12px 12px;
    display:flex; flex-direction:column;
}
#pathway-header {
    display:flex; align-items:center; justify-content:space-between;
    padding:10px 0 6px;
}
#pathway-header h3 { font-size:0.82em; font-weight:700; color:var(--text-primary); margin:0; }
#pathway-toggle {
    padding:4px 12px; border:1.5px solid var(--accent); border-radius:20px;
    background:transparent; color:var(--accent); cursor:pointer;
    font-size:0.7em; font-weight:700; transition:all 0.15s;
}
#pathway-toggle:hover { background:var(--accent-dim); }
#pathway-toggle.active { background:var(--accent); color:#111; }
#pathway-actions { display:flex; gap:4px; margin:4px 0 6px; }
#pathway-actions button {
    padding:4px 10px; border:1px solid var(--border); border-radius:5px;
    background:var(--bg-card); color:var(--text-secondary); cursor:pointer;
    font-size:0.7em; font-weight:600; transition:all 0.12s;
}
#pathway-actions button:hover { background:var(--bg-card-hover); color:var(--text-primary); }
#pathway-actions button:disabled { opacity:0.35; cursor:default; }
#pathway-list { flex:1; overflow-y:auto; max-height:200px; }
#pathway-list::-webkit-scrollbar { width:6px; }
#pathway-list::-webkit-scrollbar-track { background:transparent; }
#pathway-list::-webkit-scrollbar-thumb { background:var(--border); border-radius:3px; }
.path-step {
    display:flex; align-items:center; gap:8px;
    padding:6px 10px; margin:2px 0; border-radius:6px;
    background:var(--bg-card); font-size:0.78em;
    border-left:3px solid var(--accent); transition:all 0.12s;
}
.path-step:hover { background:var(--bg-card-hover); }
.path-step .step-num {
    width:20px; height:20px; border-radius:50%; background:var(--accent);
    color:#111; font-size:0.72em; font-weight:700; display:flex;
    align-items:center; justify-content:center; flex-shrink:0;
}
.path-step .step-label { color:var(--text-primary); flex:1; }
.path-step .step-arrow { color:var(--text-muted); font-size:0.9em; }
.path-step .step-remove {
    background:none; border:none; color:var(--text-muted); cursor:pointer;
    font-size:0.9em; padding:2px; border-radius:4px; transition:color 0.12s;
}
.path-step .step-remove:hover { color:var(--red); }
#pathway-empty {
    color:var(--text-muted); font-size:0.75em; text-align:center;
    padding:12px 0; font-style:italic;
}
.pathway-mode-hint {
    position:absolute; top:16px; left:50%; transform:translateX(-50%);
    background:var(--accent); color:#111; padding:6px 16px; border-radius:20px;
    font-size:0.78em; font-weight:700; z-index:100; pointer-events:none;
    box-shadow:0 2px 12px rgba(34,201,151,0.3);
    display:none;
}
.pathway-mode-hint.show { display:block; }
</style>
</head>
<body>
]==])

    -- SIDEBAR
    emit('<div id="sidebar">\n')
    emit('  <div id="sidebar-header">\n')
    emit('    <h1>Door Randomization Map</h1>\n')
    emit(string.format(
        '    <div class="stats">' ..
        '<span><strong>%d</strong> Areas</span>' ..
        '<span><strong>%d</strong> Doors</span>' ..
        '<span><strong>%d</strong> Redirects</span></div>\n',
        num_areas, #connections, num_redirects))
    emit([==[
    <div class="legend">
        <div class="legend-item"><div class="legend-swatch" style="background:var(--red);height:4px;"></div> Redirected</div>
        <div class="legend-item"><div class="legend-swatch" style="background:#666;"></div> Unchanged</div>
        <div class="legend-item"><div class="legend-swatch" style="background:var(--yellow);height:4px;"></div> Highlighted</div>
    </div>
    <div class="filter-bar">
        <button class="active" data-filter="redirected">Redirected</button>
        <button data-filter="all">All Doors</button>
    </div>
]==])
    emit(string.format('    <div class="section-title" id="redir-title">Door Redirects (%d)</div>\n', num_redirects))
    emit('  </div>\n')
    emit('  <div id="redir-list">')
    emit(redir_html)
    emit('</div>\n')
    emit([==[
  <div id="pathway-section">
    <div id="pathway-header">
      <h3>Pathway Builder</h3>
      <button id="pathway-toggle">OFF</button>
    </div>
    <div id="pathway-actions">
      <button id="path-undo" disabled>Undo</button>
      <button id="path-clear" disabled>Clear</button>
    </div>
    <div id="pathway-list">
      <div id="pathway-empty">Enable pathway mode and click doors on the map to build a route.</div>
    </div>
  </div>
</div>
]==])

    -- MAP AREA
    emit([==[
<div id="map-area">
  <button id="sidebar-toggle" title="Toggle sidebar">&#9776;</button>
  <div class="pathway-mode-hint" id="pathway-hint">PATHWAY MODE &mdash; Click doors to build route</div>
  <div id="filter-panel">
    <div class="filter-panel-label">Filter by area</div>
    <div id="area-chips">
]==])
    emit(chips_html)
    emit([==[
    </div>
  </div>
  <div id="map-container">
    <img id="map-image" src="]==])
    emit(img_src)
    emit([==[" draggable="false">
    <canvas id="overlay"></canvas>
  </div>
  <div id="zoom-ctrls">
    <button onclick="zoomIn()">+</button>
    <button onclick="zoomOut()">&minus;</button>
    <button onclick="zoomFit()" title="Fit">&#8690;</button>
  </div>
</div>

<div id="tooltip"></div>

]==])

    -- JAVASCRIPT
    emit('<script>\n')
    emit('const CONNECTIONS = ')
    emit(connections_json)
    emit(';\n')
    emit('const AREA_COLORS = ')
    emit(area_colors_json)
    emit(';\n')
    emit('const AREA_NAMES = ')
    emit(area_names_json)
    emit(';\n')
    emit(string.format('const TOTAL_REDIRECTS = %d;\n', num_redirects))

    emit([==[
// STATE
let scale = 1, panX = 0, panY = 0;
let isPanning = false, panSX = 0, panSY = 0, panSPX = 0, panSPY = 0;
let typeFilter = 'redirected';
let selectedAreas = new Set();
let highlightDoorId = null;

// Pathway state
let pathwayMode = false;
let pathwaySteps = [];

const mapArea = document.getElementById('map-area');
const mapCont = document.getElementById('map-container');
const mapImg  = document.getElementById('map-image');
const canvas  = document.getElementById('overlay');
const ctx     = canvas.getContext('2d');
const tooltip = document.getElementById('tooltip');

// IMAGE LOAD
mapImg.onload = () => { zoomFit(); draw(); };
if (mapImg.complete && mapImg.naturalWidth) mapImg.onload();

// VISIBILITY
function isVisible(c) {
    if (typeFilter === 'redirected' && !c.redirected) return false;
    if (selectedAreas.size > 0) {
        if (!selectedAreas.has(c.fromArea) && !selectedAreas.has(c.toAreaEffective)) return false;
    }
    return true;
}

function getVisible() { return CONNECTIONS.filter(isVisible); }

function updateSidebar() {
    const items = document.querySelectorAll('.redir-item');
    let visCount = 0;
    items.forEach(el => {
        const doorId = el.dataset.doorId;
        const conn = CONNECTIONS.find(c => c.id === doorId);
        if (!conn) { el.classList.add('hidden'); return; }
        const show = isVisible(conn);
        el.classList.toggle('hidden', !show);
        if (show) visCount++;
    });
    const title = document.getElementById('redir-title');
    title.textContent = visCount < TOTAL_REDIRECTS
        ? `Door Redirects (${visCount} / ${TOTAL_REDIRECTS})`
        : `Door Redirects (${TOTAL_REDIRECTS})`;
}

// TRANSFORM
function applyTransform() {
    mapCont.style.transform = `translate(${panX}px,${panY}px) scale(${scale})`;
}
function zoomFit() {
    const r = mapArea.getBoundingClientRect();
    const iw = mapImg.naturalWidth || 800, ih = mapImg.naturalHeight || 800;
    scale = Math.min(r.width / iw, r.height / ih) * 0.95;
    panX = (r.width - iw * scale) / 2;
    panY = (r.height - ih * scale) / 2;
    applyTransform();
}
function zoomAt(cx, cy, f) {
    const ns = Math.max(0.15, Math.min(12, scale * f));
    const r = ns / scale;
    panX = cx - r * (cx - panX);
    panY = cy - r * (cy - panY);
    scale = ns;
    applyTransform();
}
function zoomIn()  { const r = mapArea.getBoundingClientRect(); zoomAt(r.width/2, r.height/2, 1.25); }
function zoomOut() { const r = mapArea.getBoundingClientRect(); zoomAt(r.width/2, r.height/2, 0.8); }

mapArea.addEventListener('wheel', e => {
    e.preventDefault();
    const r = mapArea.getBoundingClientRect();
    zoomAt(e.clientX - r.left, e.clientY - r.top, e.deltaY < 0 ? 1.12 : 0.89);
}, { passive: false });

// PAN
let hasDragged = false;
mapArea.addEventListener('mousedown', e => {
    if (e.button === 0 || e.button === 1) {
        isPanning = true;
        hasDragged = false;
        panSX = e.clientX; panSY = e.clientY;
        panSPX = panX; panSPY = panY;
        if (!pathwayMode) mapArea.classList.add('grabbing');
    }
});
window.addEventListener('mousemove', e => {
    if (isPanning) {
        const dx = e.clientX - panSX, dy = e.clientY - panSY;
        if (Math.abs(dx) > 3 || Math.abs(dy) > 3) hasDragged = true;
        if (hasDragged) {
            panX = panSPX + dx;
            panY = panSPY + dy;
            applyTransform();
            if (pathwayMode) mapArea.classList.add('grabbing');
        }
    } else {
        handleHover(e);
    }
});
window.addEventListener('mouseup', () => {
    isPanning = false;
    mapArea.classList.remove('grabbing');
});
mapArea.addEventListener('contextmenu', e => e.preventDefault());

// DRAW
function draw() {
    const iw = mapImg.naturalWidth || 800;
    const ih = mapImg.naturalHeight || 800;
    canvas.width = iw;
    canvas.height = ih;
    canvas.style.width = iw + 'px';
    canvas.style.height = ih + 'px';
    ctx.clearRect(0, 0, iw, ih);

    const visible = getVisible();

    for (const c of visible) {
        if (c.id !== highlightDoorId) drawArrow(c, false);
    }
    for (const c of visible) {
        if (c.id !== highlightDoorId) drawDot(c.sx, c.sy, c.fromArea, c.toAreaEffective, c.redirected, false);
    }
    const hl = visible.find(c => c.id === highlightDoorId);
    if (hl) {
        drawArrow(hl, true);
        drawDot(hl.sx, hl.sy, hl.fromArea, hl.toAreaEffective, hl.redirected, true);
        drawDot(hl.dx, hl.dy, hl.toAreaEffective, hl.fromArea, false, true);
    }
    if (pathwaySteps.length > 0) {
        drawPathway();
    }
}

function drawDot(x, y, fromArea, toArea, isRedirected, isHighlight) {
    const r = isHighlight ? 9 : 6;
    const colorFrom = AREA_COLORS[fromArea] || '#888';
    const colorTo   = AREA_COLORS[toArea]   || '#888';

    if (isHighlight) {
        ctx.beginPath();
        ctx.arc(x, y, r + 4, 0, Math.PI * 2);
        ctx.fillStyle = 'rgba(251,191,36,0.25)';
        ctx.fill();
    }

    ctx.save();
    ctx.beginPath();
    ctx.arc(x, y, r, 0, Math.PI * 2);
    ctx.clip();

    ctx.fillStyle = colorFrom;
    ctx.beginPath();
    ctx.moveTo(x - r - 1, y - r - 1);
    ctx.lineTo(x + r + 1, y - r - 1);
    ctx.lineTo(x - r - 1, y + r + 1);
    ctx.closePath();
    ctx.fill();

    ctx.fillStyle = colorTo;
    ctx.beginPath();
    ctx.moveTo(x + r + 1, y - r - 1);
    ctx.lineTo(x + r + 1, y + r + 1);
    ctx.lineTo(x - r - 1, y + r + 1);
    ctx.closePath();
    ctx.fill();

    ctx.restore();

    ctx.beginPath();
    ctx.arc(x, y, r, 0, Math.PI * 2);
    ctx.lineWidth = isHighlight ? 2.5 : 1.5;
    ctx.strokeStyle = isHighlight ? '#fbbf24' : (isRedirected ? '#ef5350' : 'rgba(255,255,255,0.6)');
    ctx.stroke();

    if (isHighlight) {
        const fromName = AREA_NAMES[fromArea] || fromArea;
        const toName = AREA_NAMES[toArea] || toArea;
        const name = fromName === toName ? fromName : fromName + ' \u2192 ' + toName;
        ctx.font = '600 11px Inter, Segoe UI, system-ui, sans-serif';
        const tw = ctx.measureText(name).width;
        const lx = x - tw / 2, ly = y - r - 7;
        ctx.fillStyle = 'rgba(15,17,23,0.88)';
        ctx.beginPath();
        ctx.roundRect(lx - 6, ly - 12, tw + 12, 17, 4);
        ctx.fill();
        ctx.strokeStyle = 'rgba(251,191,36,0.5)';
        ctx.lineWidth = 1;
        ctx.stroke();
        ctx.fillStyle = '#fbbf24';
        ctx.fillText(name, lx, ly);
    }
}

function drawArrow(c, isHighlight) {
    const sx = c.sx, sy = c.sy, dx = c.dx, dy = c.dy;
    const angle = Math.atan2(dy - sy, dx - sx);
    const x1 = sx + Math.cos(angle) * 8;
    const y1 = sy + Math.sin(angle) * 8;
    const x2 = dx - Math.cos(angle) * 10;
    const y2 = dy - Math.sin(angle) * 10;

    const alpha = isHighlight ? 1.0 : (c.redirected ? 0.6 : 0.2);
    const width = isHighlight ? 3.5 : (c.redirected ? 2 : 0.8);

    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.lineWidth = width;
    ctx.strokeStyle = isHighlight ? '#fbbf24' : (c.redirected ? '#ef5350' : '#888888');

    const mx = (x1 + x2) / 2, my = (y1 + y2) / 2;
    const dist = Math.hypot(x2 - x1, y2 - y1);
    const bulge = Math.min(dist * 0.15, 30);
    const nx = -(y2 - y1) / dist, ny = (x2 - x1) / dist;
    const cpx = mx + nx * bulge, cpy = my + ny * bulge;

    ctx.beginPath();
    ctx.moveTo(x1, y1);
    ctx.quadraticCurveTo(cpx, cpy, x2, y2);
    ctx.stroke();

    const headLen = isHighlight ? 12 : 7;
    const t = 0.98;
    const tpx = 2*(1-t)*(cpx - x1) + 2*t*(x2 - cpx);
    const tpy = 2*(1-t)*(cpy - y1) + 2*t*(y2 - cpy);
    const endAngle = Math.atan2(tpy, tpx);
    ctx.beginPath();
    ctx.moveTo(x2, y2);
    ctx.lineTo(x2 - headLen * Math.cos(endAngle - 0.4), y2 - headLen * Math.sin(endAngle - 0.4));
    ctx.moveTo(x2, y2);
    ctx.lineTo(x2 - headLen * Math.cos(endAngle + 0.4), y2 - headLen * Math.sin(endAngle + 0.4));
    ctx.stroke();

    ctx.restore();
}

// HOVER
function handleHover(e) {
    const r = mapArea.getBoundingClientRect();
    const mx = (e.clientX - r.left - panX) / scale;
    const my = (e.clientY - r.top  - panY) / scale;

    const visible = getVisible();
    let closest = null, closestDist = 14;
    for (const c of visible) {
        const d = Math.hypot(c.sx - mx, c.sy - my);
        if (d < closestDist) { closestDist = d; closest = c; }
    }

    if (closest) {
        tooltip.style.display = 'block';
        tooltip.style.left = (e.clientX + 14) + 'px';
        tooltip.style.top  = (e.clientY + 14) + 'px';
        const status = closest.redirected
            ? '<span style="color:#ef5350;font-weight:600">REDIRECTED</span>'
            : '<span style="color:#5f6170">Unchanged</span>';
        tooltip.innerHTML = `<b>${closest.label}</b><br>${status}<br><span style="color:#5f6170;font-size:0.85em">${closest.id}</span>`;
        if (highlightDoorId !== closest.id) {
            highlightDoorId = closest.id;
            draw();
            document.querySelectorAll('.redir-item').forEach(el => el.classList.remove('highlight'));
            const sideEl = document.querySelector(`.redir-item[data-door-id="${closest.id}"]`);
            if (sideEl) { sideEl.classList.add('highlight'); sideEl.scrollIntoView({ block:'nearest' }); }
        }
    } else {
        tooltip.style.display = 'none';
        if (highlightDoorId) {
            highlightDoorId = null;
            draw();
            document.querySelectorAll('.redir-item').forEach(el => el.classList.remove('highlight'));
        }
    }
}

// AREA CHIP TOGGLE
document.querySelectorAll('.area-chip').forEach(chip => {
    chip.addEventListener('click', () => {
        const area = chip.dataset.area;
        if (chip.classList.contains('active')) {
            chip.classList.remove('active');
            selectedAreas.delete(area);
        } else {
            chip.classList.add('active');
            selectedAreas.add(area);
        }
        draw();
        updateSidebar();
    });
});

// TYPE FILTER
document.querySelectorAll('.filter-bar button').forEach(btn => {
    btn.addEventListener('click', () => {
        document.querySelectorAll('.filter-bar button').forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        typeFilter = btn.dataset.filter;
        draw();
        updateSidebar();
    });
});

// SIDEBAR CLICK -> HIGHLIGHT ON MAP
document.querySelectorAll('.redir-item').forEach(el => {
    el.addEventListener('click', () => {
        const doorId = el.dataset.doorId;
        document.querySelectorAll('.redir-item').forEach(x => x.classList.remove('highlight'));
        el.classList.add('highlight');
        highlightDoorId = doorId;
        draw();
        const conn = CONNECTIONS.find(c => c.id === doorId);
        if (conn) {
            const r = mapArea.getBoundingClientRect();
            panX = r.width / 2 - conn.sx * scale;
            panY = r.height / 2 - conn.sy * scale;
            applyTransform();
        }
    });
    el.addEventListener('mouseleave', () => {
        highlightDoorId = null;
        el.classList.remove('highlight');
        draw();
    });
});

// PATHWAY DRAWING
function drawPathway() {
    if (pathwaySteps.length === 0) return;

    for (let i = 0; i < pathwaySteps.length; i++) {
        const step = pathwaySteps[i];

        ctx.save();
        ctx.globalAlpha = 0.9;
        ctx.lineWidth = 4;
        ctx.strokeStyle = '#22c997';
        ctx.setLineDash([]);

        const angle = Math.atan2(step.dy - step.sy, step.dx - step.sx);
        const x1 = step.sx + Math.cos(angle) * 10;
        const y1 = step.sy + Math.sin(angle) * 10;
        const x2 = step.dx - Math.cos(angle) * 12;
        const y2 = step.dy - Math.sin(angle) * 12;

        const mx = (x1 + x2) / 2, my = (y1 + y2) / 2;
        const dist = Math.hypot(x2 - x1, y2 - y1);
        const bulge = Math.min(dist * 0.12, 25);
        const nx = -(y2 - y1) / (dist || 1), ny = (x2 - x1) / (dist || 1);
        const cpx = mx + nx * bulge, cpy = my + ny * bulge;

        ctx.shadowColor = 'rgba(34,201,151,0.5)';
        ctx.shadowBlur = 10;
        ctx.beginPath();
        ctx.moveTo(x1, y1);
        ctx.quadraticCurveTo(cpx, cpy, x2, y2);
        ctx.stroke();
        ctx.shadowBlur = 0;

        const headLen = 13;
        const t = 0.98;
        const tpx = 2*(1-t)*(cpx - x1) + 2*t*(x2 - cpx);
        const tpy = 2*(1-t)*(cpy - y1) + 2*t*(y2 - cpy);
        const endAngle = Math.atan2(tpy, tpx);
        ctx.beginPath();
        ctx.moveTo(x2, y2);
        ctx.lineTo(x2 - headLen * Math.cos(endAngle - 0.35), y2 - headLen * Math.sin(endAngle - 0.35));
        ctx.moveTo(x2, y2);
        ctx.lineTo(x2 - headLen * Math.cos(endAngle + 0.35), y2 - headLen * Math.sin(endAngle + 0.35));
        ctx.stroke();
        ctx.restore();

        if (i < pathwaySteps.length - 1) {
            const next = pathwaySteps[i + 1];
            ctx.save();
            ctx.globalAlpha = 0.5;
            ctx.lineWidth = 2;
            ctx.strokeStyle = '#22c997';
            ctx.setLineDash([6, 4]);
            ctx.beginPath();
            ctx.moveTo(step.dx, step.dy);
            ctx.lineTo(next.sx, next.sy);
            ctx.stroke();
            ctx.setLineDash([]);
            ctx.restore();
        }
    }

    for (let i = 0; i < pathwaySteps.length; i++) {
        const step = pathwaySteps[i];

        drawDot(step.sx, step.sy, step.fromArea, step.toAreaEffective, false, false);
        ctx.beginPath();
        ctx.arc(step.sx, step.sy, 6, 0, Math.PI * 2);
        ctx.lineWidth = 3;
        ctx.strokeStyle = '#22c997';
        ctx.stroke();

        drawDot(step.dx, step.dy, step.toAreaEffective, step.fromArea, false, false);
        ctx.beginPath();
        ctx.arc(step.dx, step.dy, 6, 0, Math.PI * 2);
        ctx.lineWidth = 2;
        ctx.strokeStyle = '#22c997';
        ctx.stroke();

        const numStr = String(i + 1);
        ctx.fillStyle = '#22c997';
        ctx.beginPath();
        ctx.arc(step.sx + 10, step.sy - 10, 10, 0, Math.PI * 2);
        ctx.fill();
        ctx.fillStyle = '#111';
        ctx.font = '700 11px Inter, Segoe UI, system-ui, sans-serif';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText(numStr, step.sx + 10, step.sy - 10);
        ctx.textAlign = 'start';
        ctx.textBaseline = 'alphabetic';
    }
}

// PATHWAY MODE CONTROLS
const pathToggle = document.getElementById('pathway-toggle');
const pathUndo = document.getElementById('path-undo');
const pathClear = document.getElementById('path-clear');
const pathList = document.getElementById('pathway-list');
const pathEmpty = document.getElementById('pathway-empty');
const pathHint = document.getElementById('pathway-hint');

pathToggle.addEventListener('click', () => {
    pathwayMode = !pathwayMode;
    pathToggle.textContent = pathwayMode ? 'ON' : 'OFF';
    pathToggle.classList.toggle('active', pathwayMode);
    pathHint.classList.toggle('show', pathwayMode);
    mapArea.style.cursor = pathwayMode ? 'crosshair' : 'grab';
});

pathUndo.addEventListener('click', () => {
    if (pathwaySteps.length > 0) {
        pathwaySteps.pop();
        updatePathwayUI();
        draw();
    }
});

pathClear.addEventListener('click', () => {
    pathwaySteps = [];
    updatePathwayUI();
    draw();
});

function updatePathwayUI() {
    pathUndo.disabled = pathwaySteps.length === 0;
    pathClear.disabled = pathwaySteps.length === 0;

    if (pathwaySteps.length === 0) {
        pathList.innerHTML = '<div id="pathway-empty">Enable pathway mode and click doors on the map to build a route.</div>';
        return;
    }

    let html = '';
    for (let i = 0; i < pathwaySteps.length; i++) {
        const step = pathwaySteps[i];
        const fromName = AREA_NAMES[step.fromArea] || step.fromArea;
        const toName = AREA_NAMES[step.toAreaEffective] || step.toAreaEffective;
        const vanillaName = AREA_NAMES[step.toAreaVanilla] || step.toAreaVanilla;
        const redirectNote = step.redirected ? ` <span style="color:var(--red);font-size:0.85em">(was ${vanillaName})</span>` : '';
        html += `<div class="path-step" data-step-idx="${i}">` +
            `<span class="step-num">${i + 1}</span>` +
            `<span class="step-label">${fromName} \u2192 ${toName}${redirectNote}</span>` +
            `<button class="step-remove" title="Remove this step" data-step-idx="${i}">&times;</button>` +
            `</div>`;
    }
    pathList.innerHTML = html;

    pathList.querySelectorAll('.step-remove').forEach(btn => {
        btn.addEventListener('click', (e) => {
            e.stopPropagation();
            const idx = parseInt(btn.dataset.stepIdx);
            pathwaySteps.splice(idx, 1);
            updatePathwayUI();
            draw();
        });
    });

    pathList.querySelectorAll('.path-step').forEach(el => {
        el.addEventListener('mouseenter', () => {
            const idx = parseInt(el.dataset.stepIdx);
            const step = pathwaySteps[idx];
            if (step) {
                highlightDoorId = step.id;
                draw();
            }
        });
        el.addEventListener('mouseleave', () => {
            highlightDoorId = null;
            draw();
        });
        el.addEventListener('click', () => {
            const idx = parseInt(el.dataset.stepIdx);
            const step = pathwaySteps[idx];
            if (step) {
                const r = mapArea.getBoundingClientRect();
                panX = r.width / 2 - step.sx * scale;
                panY = r.height / 2 - step.sy * scale;
                applyTransform();
            }
        });
    });
}

// PATHWAY CLICK ON MAP
mapArea.addEventListener('click', (e) => {
    if (!pathwayMode) return;
    if (hasDragged) return;

    const r = mapArea.getBoundingClientRect();
    const mx = (e.clientX - r.left - panX) / scale;
    const my = (e.clientY - r.top  - panY) / scale;

    let closest = null, closestDist = 20;
    for (const c of CONNECTIONS) {
        const d = Math.hypot(c.sx - mx, c.sy - my);
        if (d < closestDist) { closestDist = d; closest = c; }
    }

    if (closest) {
        if (pathwaySteps.length > 0 && pathwaySteps[pathwaySteps.length - 1].id === closest.id) {
            return;
        }
        pathwaySteps.push(closest);
        updatePathwayUI();
        draw();
    }
});

// SIDEBAR TOGGLE
document.getElementById('sidebar-toggle').addEventListener('click', () => {
    const sb = document.getElementById('sidebar');
    sb.classList.toggle('collapsed');
});

// Initial sidebar state
updateSidebar();
]==])

    emit('</script>\n</body>\n</html>')

    return table.concat(parts)
end

------------------------------------------------------------
-- File I/O
------------------------------------------------------------

local function write_html()
    local html = generate_html()
    if not html or #html == 0 then
        M.log("ERROR: Failed to generate HTML")
        return false, "Failed to generate HTML"
    end

    local file, err = io.open(HTML_OUTPUT_PATH, "w")
    if not file then
        M.log("ERROR: Could not write file: " .. tostring(err))
        return false, "Could not write file: " .. tostring(err)
    end

    file:write(html)
    file:close()
    M.log(string.format("Door map written to %s (%d bytes)", HTML_OUTPUT_PATH, #html))

    return true, nil
end

------------------------------------------------------------
-- GUI Tab Content
------------------------------------------------------------

local last_generate_status = nil  -- nil, "success", or error message
local last_generate_time = 0

function M.draw_tab_content(debug)
    local DoorRandomizer = require("DRAP/DoorRandomizer")

    if debug then
        imgui.text_colored(
            DoorRandomizer.is_enabled() and "Door Rando: ON" or "Door Rando: OFF",
            DoorRandomizer.is_enabled() and 0xFF00FF00 or 0xFFFF0000)
        imgui.same_line()
        imgui.text(string.format("Redirects: %d", DoorRandomizer.get_redirect_config_count()))
    end

    if not DoorRandomizer.is_enabled() then
        imgui.text_colored("Door Randomizer is not enabled for this slot.", 0xFFFF8800)
        imgui.text("Enable 'Door Randomizer' in your AP YAML to use this feature.")
        return
    end

    imgui.text(string.format("Door redirects loaded: %d", DoorRandomizer.get_redirect_config_count()))
    imgui.spacing()

    if imgui.button("Generate Door Map") then
        local ok, err_msg = write_html()
        if ok then
            last_generate_status = "success"
        else
            last_generate_status = err_msg or "Unknown error"
        end
        last_generate_time = os.clock()
    end

    -- Status message (auto-fades after 5 seconds)
    if last_generate_status then
        local elapsed = os.clock() - last_generate_time
        if elapsed < 5 then
            if last_generate_status == "success" then
                imgui.text_colored("Door map saved to " .. HTML_OUTPUT_PATH .. "!", 0xFF00FF00)
            else
                imgui.text_colored("Error: " .. last_generate_status, 0xFFFF0000)
            end
        else
            last_generate_status = nil
        end
    end

    imgui.spacing()
    imgui.text_colored("The map shows all door connections overlaid on the mall map.", 0xFFAAAAAA)
    imgui.text_colored("Redirected doors are highlighted in red.", 0xFFAAAAAA)
end

------------------------------------------------------------
-- Module Init
------------------------------------------------------------

M.log("DoorVisualizer loaded")

return M
