#!/usr/bin/env python3
"""
Door Randomization Visualizer for Dead Rising Deluxe Remaster

Generates visual representations of door connections to verify randomization.
Outputs:
- Mermaid diagram (can paste into GitHub, Notion, etc.)
- Interactive HTML graph
- Text-based connection list
"""

import json
import sys
from typing import Dict, Set, List, Tuple
from dataclasses import dataclass

# Import from our DoorRandomization module
from DoorRandomization import (
    DoorRandomizer,
    AREA_NAMES,
    PROTECTED_AREAS,
    START_AREA,
    EMBEDDED_DOOR_DATA,
    generate_door_randomization_for_ap
)

# Color scheme for areas (for HTML visualization)
AREA_COLORS = {
    "s135": "#FFD700",  # Helipad - Gold
    "s136": "#90EE90",  # Safe Room - Light Green
    "s231": "#87CEEB",  # Rooftop - Sky Blue
    "s230": "#DDA0DD",  # Service Hallway - Plum
    "s200": "#FF6B6B",  # Paradise Plaza - Red
    "s100": "#4ECDC4",  # Entrance Plaza - Teal
    "s900": "#95E1D3",  # Al Fresca Plaza - Mint
    "sa00": "#F38181",  # Food Court - Coral
    "s300": "#AA96DA",  # Wonderland Plaza - Purple
    "s400": "#FCBAD3",  # North Plaza - Pink
    "s700": "#A8D8EA",  # Leisure Park - Light Blue
    "s501": "#FFB347",  # Crislip's - Orange
    "s503": "#B19CD9",  # Colby's - Light Purple
    "s401": "#77DD77",  # Hideout - Pastel Green
    "s600": "#808080",  # Maintenance Tunnel - Gray
    "s500": "#F0E68C",  # Grocery Store - Khaki
    "s601": "#CD5C5C",  # Butcher - Indian Red
}


def get_short_name(area_code: str) -> str:
    """Get a short display name for an area"""
    names = {
        "s135": "Helipad",
        "s136": "Safe Room",
        "s231": "Rooftop",
        "s230": "Svc Hall",
        "s200": "Paradise",
        "s100": "Entrance",
        "s900": "Al Fresca",
        "sa00": "Food Court",
        "s300": "Wonderland",
        "s400": "North Plaza",
        "s700": "Leisure Pk",
        "s501": "Crislip's",
        "s503": "Colby's",
        "s401": "Hideout",
        "s600": "Tunnels",
        "s500": "Grocery",
        "s601": "Butcher",
    }
    return names.get(area_code, area_code)


def build_connection_graph(randomizer: DoorRandomizer, use_redirects: bool = False) -> Dict[str, Set[str]]:
    """Build a graph of unique area-to-area connections"""
    graph: Dict[str, Set[str]] = {area: set() for area in randomizer.areas}

    for door_id, door in randomizer.doors.items():
        if use_redirects and door_id in randomizer.redirects:
            target_door_id = randomizer.redirects[door_id]
            target_door = randomizer.doors[target_door_id]
            graph[door.from_area].add(target_door.to_area)
        else:
            graph[door.from_area].add(door.to_area)

    return graph


def generate_mermaid_diagram(randomizer: DoorRandomizer, title: str = "Door Connections") -> str:
    """Generate a Mermaid flowchart diagram"""
    lines = [
        f"---",
        f"title: {title}",
        f"---",
        f"flowchart LR"
    ]

    # Add node definitions with short names
    for area_code in randomizer.areas:
        short_name = get_short_name(area_code)
        full_name = AREA_NAMES.get(area_code, area_code)
        lines.append(f'    {area_code}["{short_name}"]')

    # Build connection graph
    graph = build_connection_graph(randomizer, use_redirects=True)

    # Add edges
    seen_edges = set()
    for from_area, to_areas in graph.items():
        for to_area in to_areas:
            edge_key = f"{from_area}->{to_area}"
            if edge_key not in seen_edges:
                lines.append(f"    {from_area} --> {to_area}")
                seen_edges.add(edge_key)

    # Style protected areas
    for area in PROTECTED_AREAS:
        if area in randomizer.areas:
            lines.append(f"    style {area} fill:#90EE90,stroke:#333,stroke-width:3px")

    # Style start area
    lines.append(f"    style {START_AREA} fill:#FFD700,stroke:#333,stroke-width:4px")

    return "\n".join(lines)


def generate_comparison_mermaid(randomizer: DoorRandomizer) -> str:
    """Generate a Mermaid diagram showing vanilla vs randomized (changed edges highlighted)"""
    lines = [
        "---",
        "title: Door Randomization Changes",
        "---",
        "flowchart LR"
    ]

    # Add node definitions
    for area_code in randomizer.areas:
        short_name = get_short_name(area_code)
        lines.append(f'    {area_code}["{short_name}"]')

    # Build both graphs
    vanilla_graph = build_connection_graph(randomizer, use_redirects=False)
    rando_graph = build_connection_graph(randomizer, use_redirects=True)

    # Find unchanged and changed edges
    seen_edges = set()

    for from_area in randomizer.areas:
        vanilla_dests = vanilla_graph.get(from_area, set())
        rando_dests = rando_graph.get(from_area, set())

        # Unchanged edges (in both)
        for dest in vanilla_dests & rando_dests:
            edge_key = f"{from_area}->{dest}"
            if edge_key not in seen_edges:
                lines.append(f"    {from_area} --> {dest}")
                seen_edges.add(edge_key)

        # Removed edges (only in vanilla) - shown as dashed red
        for dest in vanilla_dests - rando_dests:
            edge_key = f"{from_area}-.removed.->{dest}"
            if edge_key not in seen_edges:
                lines.append(f"    {from_area} -.-> {dest}")
                seen_edges.add(edge_key)

        # New edges (only in rando) - shown as thick green
        for dest in rando_dests - vanilla_dests:
            edge_key = f"{from_area}==new==>{dest}"
            if edge_key not in seen_edges:
                lines.append(f"    {from_area} ==> {dest}")
                seen_edges.add(edge_key)

    # Add legend
    lines.append("")
    lines.append("    subgraph Legend")
    lines.append('        L1[Unchanged] --> L2[" "]')
    lines.append('        L3[Removed] -.-> L4[" "]')
    lines.append('        L5[New] ==> L6[" "]')
    lines.append("    end")

    return "\n".join(lines)


def generate_html_visualization(randomizer: DoorRandomizer, title: str = "Door Randomization Map") -> str:
    """Generate an interactive HTML visualization using vis.js"""
    import json

    # Build graph data
    rando_graph = build_connection_graph(randomizer, use_redirects=True)
    vanilla_graph = build_connection_graph(randomizer, use_redirects=False)

    # Prepare nodes as proper Python dicts, then JSON serialize
    nodes_data = []
    for area_code, area_info in randomizer.areas.items():
        color = AREA_COLORS.get(area_code, "#CCCCCC")
        label = get_short_name(area_code)
        full_name = AREA_NAMES.get(area_code, area_code)

        # Mark protected areas
        border_width = 4 if area_code in PROTECTED_AREAS else 2
        border_color = "#FFD700" if area_code == START_AREA else "#333333"

        nodes_data.append({
            "id": area_code,
            "label": label,
            "title": full_name,
            "color": {
                "background": color,
                "border": border_color,
                "highlight": {"background": color, "border": "#FF0000"}
            },
            "borderWidth": border_width,
            "font": {"size": 14, "face": "arial"}
        })

    # Prepare edges as proper Python dicts
    edges_data = []
    seen_edges = set()

    for from_area, to_areas in rando_graph.items():
        for to_area in to_areas:
            edge_key = f"{from_area}->{to_area}"
            if edge_key in seen_edges:
                continue
            seen_edges.add(edge_key)

            # Check if this is a new edge (not in vanilla)
            is_new = to_area not in vanilla_graph.get(from_area, set())

            color = "#00AA00" if is_new else "#888888"
            width = 3 if is_new else 1

            edge_title = f"{'NEW: ' if is_new else ''}{get_short_name(from_area)} -> {get_short_name(to_area)}"

            edges_data.append({
                "from": from_area,
                "to": to_area,
                "arrows": "to",
                "color": {"color": color, "highlight": "#FF0000"},
                "width": width,
                "dashes": False,
                "title": edge_title
            })

    # JSON serialize the data
    nodes_json = json.dumps(nodes_data)
    edges_json = json.dumps(edges_data)

    # Generate redirect list for sidebar
    redirect_list_html = ""
    for source_id, target_id in randomizer.redirects.items():
        source_door = randomizer.doors[source_id]
        target_door = randomizer.doors[target_id]

        orig_from = get_short_name(source_door.from_area)
        orig_to = get_short_name(source_door.to_area)
        new_to = get_short_name(target_door.to_area)

        redirect_list_html += f'<div class="redirect-item"><span class="orig">{orig_from} to {orig_to}</span> <span class="arrow">=&gt;</span> <span class="new">{new_to}</span></div>\n'

    html = f'''<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>{title}</title>
    <script src="https://unpkg.com/vis-network@9.1.6/dist/vis-network.min.js"></script>
    <style>
        * {{ margin: 0; padding: 0; box-sizing: border-box; }}
        body {{ 
            font-family: Arial, sans-serif; 
            display: flex; 
            height: 100vh;
            background: #1a1a2e;
            color: #eee;
        }}
        #graph-container {{
            flex: 1;
            height: 100%;
            background: #1a1a2e;
        }}
        #error-msg {{
            color: #ff6b6b;
            padding: 20px;
            display: none;
        }}
        #sidebar {{
            width: 350px;
            background: #16213e;
            padding: 20px;
            overflow-y: auto;
            border-left: 2px solid #0f3460;
        }}
        h1 {{ 
            font-size: 1.4em; 
            margin-bottom: 15px;
            color: #e94560;
        }}
        h2 {{
            font-size: 1.1em;
            margin: 15px 0 10px 0;
            color: #0f3460;
            background: #e94560;
            padding: 5px 10px;
            border-radius: 4px;
        }}
        .stats {{
            background: #0f3460;
            padding: 10px;
            border-radius: 4px;
            margin-bottom: 15px;
        }}
        .stats div {{
            margin: 5px 0;
        }}
        .redirect-item {{
            background: #0f3460;
            padding: 8px;
            margin: 5px 0;
            border-radius: 4px;
            font-size: 0.9em;
        }}
        .redirect-item .orig {{
            color: #ff6b6b;
            text-decoration: line-through;
        }}
        .redirect-item .arrow {{
            color: #ffd93d;
            margin: 0 5px;
        }}
        .redirect-item .new {{
            color: #6bcb77;
            font-weight: bold;
        }}
        .legend {{
            margin-top: 20px;
            padding: 10px;
            background: #0f3460;
            border-radius: 4px;
        }}
        .legend-item {{
            display: flex;
            align-items: center;
            margin: 5px 0;
        }}
        .legend-color {{
            width: 30px;
            height: 4px;
            margin-right: 10px;
            border-radius: 2px;
        }}
        .legend-color.new {{ background: #00AA00; height: 6px; }}
        .legend-color.unchanged {{ background: #888888; }}
    </style>
</head>
<body>
    <div id="graph-container">
        <div id="error-msg"></div>
    </div>
    <div id="sidebar">
        <h1>Door Randomization Map</h1>

        <div class="stats">
            <div>Areas: {len(randomizer.areas)}</div>
            <div>Total Doors: {len(randomizer.doors)}</div>
            <div>Redirects: {len(randomizer.redirects)}</div>
        </div>

        <div class="legend">
            <strong>Legend:</strong>
            <div class="legend-item">
                <div class="legend-color new"></div>
                <span>New/Changed Connection</span>
            </div>
            <div class="legend-item">
                <div class="legend-color unchanged"></div>
                <span>Unchanged Connection</span>
            </div>
        </div>

        <h2>Door Redirects</h2>
        <div id="redirect-list">
            {redirect_list_html}
        </div>
    </div>

    <script>
        try {{
            var nodesData = {nodes_json};
            var edgesData = {edges_json};

            var nodes = new vis.DataSet(nodesData);
            var edges = new vis.DataSet(edgesData);

            var container = document.getElementById("graph-container");
            var data = {{ nodes: nodes, edges: edges }};
            var options = {{
                physics: {{
                    enabled: true,
                    solver: "forceAtlas2Based",
                    forceAtlas2Based: {{
                        gravitationalConstant: -100,
                        centralGravity: 0.01,
                        springLength: 150,
                        springConstant: 0.08,
                        damping: 0.4
                    }},
                    stabilization: {{
                        iterations: 200
                    }}
                }},
                nodes: {{
                    shape: "box",
                    margin: 10,
                    shadow: true
                }},
                edges: {{
                    smooth: {{
                        type: "curvedCW",
                        roundness: 0.2
                    }},
                    shadow: true
                }},
                interaction: {{
                    hover: true,
                    tooltipDelay: 100
                }}
            }};

            var network = new vis.Network(container, data, options);

            network.on("stabilizationIterationsDone", function() {{
                network.setOptions({{ physics: {{ enabled: false }} }});
            }});
        }} catch (e) {{
            document.getElementById("error-msg").style.display = "block";
            document.getElementById("error-msg").innerText = "Error: " + e.message;
            console.error(e);
        }}
    </script>
</body>
</html>'''

    return html


def generate_text_report(randomizer: DoorRandomizer) -> str:
    """Generate a text-based report of all connections"""
    lines = [
        "=" * 60,
        "DOOR RANDOMIZATION REPORT",
        "=" * 60,
        "",
        f"Total Areas: {len(randomizer.areas)}",
        f"Total Doors: {len(randomizer.doors)}",
        f"Active Redirects: {len(randomizer.redirects)}",
        "",
        "-" * 60,
        "CONNECTIONS BY AREA (after randomization)",
        "-" * 60,
    ]

    rando_graph = build_connection_graph(randomizer, use_redirects=True)
    vanilla_graph = build_connection_graph(randomizer, use_redirects=False)

    for area_code in sorted(randomizer.areas.keys()):
        area_name = AREA_NAMES.get(area_code, area_code)
        rando_dests = rando_graph.get(area_code, set())
        vanilla_dests = vanilla_graph.get(area_code, set())

        lines.append(f"\n{area_name} ({area_code}):")

        for dest in sorted(rando_dests):
            dest_name = get_short_name(dest)
            if dest in vanilla_dests:
                lines.append(f"  → {dest_name}")
            else:
                lines.append(f"  → {dest_name}  ★ NEW")

        # Show removed connections
        removed = vanilla_dests - rando_dests
        if removed:
            for dest in sorted(removed):
                dest_name = get_short_name(dest)
                lines.append(f"  ✗ {dest_name}  (removed)")

    lines.extend([
        "",
        "-" * 60,
        "REDIRECT DETAILS",
        "-" * 60,
    ])

    for source_id, target_id in sorted(randomizer.redirects.items()):
        source_door = randomizer.doors[source_id]
        target_door = randomizer.doors[target_id]

        orig_from = get_short_name(source_door.from_area)
        orig_to = get_short_name(source_door.to_area)
        new_to = get_short_name(target_door.to_area)

        lines.append(f"{orig_from} → {orig_to}  ⟹  {orig_from} → {new_to}")

    # Verify connectivity
    lines.extend([
        "",
        "-" * 60,
        "CONNECTIVITY CHECK",
        "-" * 60,
    ])

    if randomizer.is_fully_connected(rando_graph):
        lines.append("✓ All areas are reachable from Safe Room")
    else:
        lines.append("✗ WARNING: Some areas may be unreachable!")

    if randomizer.can_escape_all_areas(rando_graph):
        lines.append("✓ All areas have at least one exit")
    else:
        lines.append("✗ WARNING: Some areas have no exits (softlock possible)!")

    return "\n".join(lines)


def main():
    """Main function to generate visualizations"""
    import random as stdlib_random

    # Create a mock random for testing
    class MockRandom:
        def __init__(self, seed=42):
            self._rng = stdlib_random.Random(seed)

        def randint(self, a, b):
            return self._rng.randint(a, b)

    # Get seed from command line or use default
    seed = int(sys.argv[1]) if len(sys.argv) > 1 else 42
    print(f"Using seed: {seed}")

    # Create and populate randomizer
    mock_random = MockRandom(seed)
    randomizer = DoorRandomizer(seed=mock_random.randint(0, 2 ** 31))
    randomizer.load_doors_from_json({"doors": EMBEDDED_DOOR_DATA})
    randomizer.add_missing_doors()
    randomizer.randomize_with_validation(max_attempts=100)

    # Generate outputs
    print("\n" + "=" * 60)
    print("Generating visualizations...")
    print("=" * 60)

    # Text report
    text_report = generate_text_report(randomizer)
    print(text_report)

    with open("door_report.txt", "w", encoding="utf-8") as f:
        f.write(text_report)
    print("\n[OK] Saved: door_report.txt")

    # Mermaid diagram
    mermaid = generate_mermaid_diagram(randomizer, f"Door Connections (Seed: {seed})")
    with open("door_graph.mmd", "w", encoding="utf-8") as f:
        f.write(mermaid)
    print("[OK] Saved: door_graph.mmd")

    # Comparison Mermaid
    comparison_mermaid = generate_comparison_mermaid(randomizer)
    with open("door_changes.mmd", "w", encoding="utf-8") as f:
        f.write(comparison_mermaid)
    print("[OK] Saved: door_changes.mmd")

    # HTML visualization
    html = generate_html_visualization(randomizer, f"Door Randomization (Seed: {seed})")
    with open("door_map.html", "w", encoding="utf-8") as f:
        f.write(html)
    print("[OK] Saved: door_map.html")

    print("\n" + "=" * 60)
    print("Done! Open door_map.html in a browser for interactive view.")
    print("=" * 60)


if __name__ == "__main__":
    main()