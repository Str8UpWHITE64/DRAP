# world/drdr/DoorRandomization.py
"""
Door Randomization Logic for Dead Rising Deluxe Remaster Archipelago

This module generates valid door connection mappings that ensure:
1. All areas remain reachable from the starting location
2. No softlocks (player can always escape any area)
3. The game remains completable
"""

from typing import Dict, List, Set, Tuple, Optional
from dataclasses import dataclass
import random


@dataclass
class DoorEndpoint:
    """Represents one side of a door (the exit point when you go through it)"""
    door_id: str
    from_area: str
    to_area: str
    position: Tuple[float, float, float]
    angle: Tuple[float, float, float]
    door_no: int = 0


@dataclass
class AreaInfo:
    """Information about a game area"""
    code: str
    name: str
    outgoing_doors: List[str]  # door_ids that leave this area
    incoming_doors: List[str]  # door_ids that enter this area


# Area definitions with friendly names
AREA_NAMES = {
    "s135": "Helipad",
    "s136": "Safe Room",
    "s231": "Rooftop",
    "s230": "Service Hallway",
    "s200": "Paradise Plaza",
    "s100": "Entrance Plaza",
    "s900": "Al Fresca Plaza",
    "sa00": "Food Court",
    "s300": "Wonderland Plaza",
    "s400": "North Plaza",
    "s700": "Leisure Park",
    "s501": "Crislip's Hardware Store",
    "s503": "Colby's Movie Theater",
    "s401": "Hideout",
    "s600": "Maintenance Tunnel",
    "s500": "Grocery Store",
    "s601": "Butcher",
}

# Define which areas should NOT have their doors randomized
# (typically story-critical areas or starting areas)
PROTECTED_AREAS = {
    "s135",  # Helipad - needed for endings
    "s136",  # Safe Room - hub/save point
    "s601",  # Butcher - boss arena
}

# Areas that are "dead ends" with only one exit
DEAD_END_AREAS = {
    "s135": ["s136"],  # Helipad only connects to Safe Room
    "s401": ["s400"],  # Hideout only connects to North Plaza
    "s501": ["s400"],  # Crislip's only connects to North Plaza
    "s503": ["s200"],  # Colby's only connects to Paradise Plaza
    "s601": ["s600"],  # Butcher only connects to Maintenance Tunnel
}

# Starting area (player spawns here)
START_AREA = "s136"  # Safe Room


class DoorRandomizer:
    """Handles door randomization logic"""

    def __init__(self, seed: Optional[int] = None):
        self.rng = random.Random(seed)
        self.doors: Dict[str, DoorEndpoint] = {}
        self.areas: Dict[str, AreaInfo] = {}
        self.redirects: Dict[str, str] = {}  # source_door_id -> target_door_id

    def load_doors_from_json(self, door_data: dict) -> None:
        """Load door data from the JSON format used by the Lua mod"""
        doors_dict = door_data.get("doors", door_data)

        for door_id, door_info in doors_dict.items():
            # Parse the door_id format: SCN_{from}|{to}|door{n}
            from_area = door_info.get("from_area_code", "")
            to_area = door_info.get("to_area_code", "")

            pos = door_info.get("position", {})
            angle = door_info.get("angle", {})

            endpoint = DoorEndpoint(
                door_id=door_id,
                from_area=from_area,
                to_area=to_area,
                position=(pos.get("x", 0), pos.get("y", 0), pos.get("z", 0)),
                angle=(angle.get("x", 0), angle.get("y", 0), angle.get("z", 0)),
                door_no=door_info.get("door_no", 0)
            )

            self.doors[door_id] = endpoint

            # Build area info
            if from_area not in self.areas:
                self.areas[from_area] = AreaInfo(
                    code=from_area,
                    name=AREA_NAMES.get(from_area, from_area),
                    outgoing_doors=[],
                    incoming_doors=[]
                )
            if to_area not in self.areas:
                self.areas[to_area] = AreaInfo(
                    code=to_area,
                    name=AREA_NAMES.get(to_area, to_area),
                    outgoing_doors=[],
                    incoming_doors=[]
                )

            self.areas[from_area].outgoing_doors.append(door_id)
            self.areas[to_area].incoming_doors.append(door_id)

    def add_missing_doors(self) -> None:
        """Add placeholder data for missing doors (Grocery Store connections)"""
        missing_doors = [
            # North Plaza -> Grocery Store
            DoorEndpoint(
                door_id="SCN_s400|s500|door0",
                from_area="s400",
                to_area="s500",
                position=(0, 5, -180),  # Estimated position
                angle=(0, 1.5, 0),
                door_no=0
            ),
            # Grocery Store -> North Plaza
            DoorEndpoint(
                door_id="SCN_s500|s400|door0",
                from_area="s500",
                to_area="s400",
                position=(0, 0, 0),  # Needs real position
                angle=(0, -1.5, 0),
                door_no=0
            ),
            # Grocery Store -> Maintenance Tunnel
            DoorEndpoint(
                door_id="SCN_s500|s600|door0",
                from_area="s500",
                to_area="s600",
                position=(0, 0, 50),  # Needs real position
                angle=(0, 0, 0),
                door_no=0
            ),
            # Maintenance Tunnel -> Grocery Store
            DoorEndpoint(
                door_id="SCN_s600|s500|door0",
                from_area="s600",
                to_area="s500",
                position=(-100, 0, 0),  # Needs real position
                angle=(0, 3.14, 0),
                door_no=0
            ),
        ]

        for door in missing_doors:
            if door.door_id not in self.doors:
                self.doors[door.door_id] = door

                if door.from_area not in self.areas:
                    self.areas[door.from_area] = AreaInfo(
                        code=door.from_area,
                        name=AREA_NAMES.get(door.from_area, door.from_area),
                        outgoing_doors=[],
                        incoming_doors=[]
                    )
                if door.to_area not in self.areas:
                    self.areas[door.to_area] = AreaInfo(
                        code=door.to_area,
                        name=AREA_NAMES.get(door.to_area, door.to_area),
                        outgoing_doors=[],
                        incoming_doors=[]
                    )

                self.areas[door.from_area].outgoing_doors.append(door.door_id)
                self.areas[door.to_area].incoming_doors.append(door.door_id)

    def get_door_pairs(self) -> List[Tuple[str, str]]:
        """
        Find door pairs (A->B and B->A) that represent the same physical connection.
        Returns list of (door_id_a_to_b, door_id_b_to_a) tuples.
        """
        pairs = []
        seen = set()

        for door_id, door in self.doors.items():
            if door_id in seen:
                continue

            # Look for the reverse door
            reverse_pattern = f"SCN_{door.to_area}|{door.from_area}|door{door.door_no}"

            if reverse_pattern in self.doors:
                pairs.append((door_id, reverse_pattern))
                seen.add(door_id)
                seen.add(reverse_pattern)
            else:
                # One-way door or missing pair
                pairs.append((door_id, None))
                seen.add(door_id)

        return pairs

    def get_randomizable_doors(self) -> List[str]:
        """Get list of door IDs that can be randomized (excluding protected areas)"""
        randomizable = []

        for door_id, door in self.doors.items():
            # Skip doors involving protected areas
            if door.from_area in PROTECTED_AREAS or door.to_area in PROTECTED_AREAS:
                continue
            randomizable.append(door_id)

        return randomizable

    def build_adjacency_graph(self, use_redirects: bool = False) -> Dict[str, Set[str]]:
        """
        Build a graph of area connections.
        If use_redirects is True, uses the randomized redirects.
        Returns {area_code: set of reachable area codes}
        """
        graph: Dict[str, Set[str]] = {area: set() for area in self.areas}

        for door_id, door in self.doors.items():
            if use_redirects and door_id in self.redirects:
                # Use randomized destination
                target_door_id = self.redirects[door_id]
                target_door = self.doors[target_door_id]
                # The redirect means: when you use this door, you end up at target_door's destination
                graph[door.from_area].add(target_door.to_area)
            else:
                # Use vanilla destination
                graph[door.from_area].add(door.to_area)

        return graph

    def is_fully_connected(self, graph: Dict[str, Set[str]], start: str = START_AREA) -> bool:
        """Check if all areas are reachable from the start using BFS"""
        if start not in graph:
            return False

        visited = set()
        queue = [start]

        while queue:
            current = queue.pop(0)
            if current in visited:
                continue
            visited.add(current)

            for neighbor in graph.get(current, set()):
                if neighbor not in visited:
                    queue.append(neighbor)

        # Check all areas are reachable
        return visited >= set(self.areas.keys())

    def can_escape_all_areas(self, graph: Dict[str, Set[str]]) -> bool:
        """
        Check that every area has at least one outgoing connection.
        This prevents softlocks where player enters an area with no exits.
        """
        for area in self.areas:
            if area in PROTECTED_AREAS:
                continue
            if not graph.get(area):
                return False
        return True

    def generate_spanning_tree_redirects(self) -> Dict[str, str]:
        """
        Generate redirects that form a spanning tree, ensuring all areas are connected.
        This is the first pass - remaining doors are randomized freely.
        """
        # Get all non-protected areas
        areas_to_connect = [a for a in self.areas if a not in PROTECTED_AREAS]

        # Start from areas adjacent to protected areas (they're our entry points)
        connected = {START_AREA}

        # Find areas directly connected to start
        for door_id, door in self.doors.items():
            if door.from_area == START_AREA:
                connected.add(door.to_area)

        redirects = {}

        # Use Prim's algorithm-like approach to build spanning tree
        while len(connected) < len(self.areas):
            # Find a door from connected area to unconnected area
            candidates = []

            for door_id, door in self.doors.items():
                if door.from_area in connected and door.to_area not in connected:
                    candidates.append(door_id)

            if not candidates:
                # Try to find any door that could bridge to unconnected area
                unconnected = set(self.areas.keys()) - connected
                for door_id, door in self.doors.items():
                    if door.to_area in unconnected:
                        candidates.append(door_id)

                if not candidates:
                    break  # No way to connect remaining areas

            # Pick a random candidate
            chosen = self.rng.choice(candidates)
            chosen_door = self.doors[chosen]

            # This door stays vanilla (or is the critical connection)
            connected.add(chosen_door.to_area)

        return redirects

    def randomize_paired(self, max_attempts: int = 500) -> Dict[str, str]:
        """
        Randomize doors in paired/bidirectional mode with individual door granularity.

        GUARANTEE: If you can travel from area A to area B, there WILL be a door
        in area B that takes you back to area A.

        Algorithm (Individual Door Swapping):
        Instead of swapping entire edges, we swap individual doors in groups of 4:
        - door1: A→B and door2: C→D swap to become A→D and C→B
        - door3: D→? and door4: B→? swap to become D→A and B→C
        This creates two new bidirectional connections (A↔D and B↔C) using 4 doors.

        This allows multiple doors between the same areas to be randomized differently.
        For example, the two Rooftop→Service Hallway doors can end up going to different areas.
        """
        randomizable_doors = list(self.get_randomizable_doors())

        # Build info about each door
        door_info = {}  # door_id -> (from_area, to_area)
        doors_from_area = {}  # area -> list of door_ids leaving that area

        for door_id in randomizable_doors:
            door = self.doors[door_id]
            door_info[door_id] = (door.from_area, door.to_area)
            if door.from_area not in doors_from_area:
                doors_from_area[door.from_area] = []
            doors_from_area[door.from_area].append(door_id)

        # Pre-compute templates for each destination
        templates_to_area: Dict[str, str] = {}
        for door_id, door in self.doors.items():
            if door.to_area not in templates_to_area:
                templates_to_area[door.to_area] = door_id

        for attempt in range(max_attempts):
            self.redirects = {}

            # Shuffle doors for random pairing
            shuffled_doors = randomizable_doors.copy()
            self.rng.shuffle(shuffled_doors)

            # Also shuffle the doors_from_area lists for variety
            shuffled_doors_from_area = {}
            for area, doors in doors_from_area.items():
                shuffled_list = doors.copy()
                self.rng.shuffle(shuffled_list)
                shuffled_doors_from_area[area] = shuffled_list

            # Track which doors have been used in a swap
            used_doors = set()
            swap_count = 0

            for i, door1_id in enumerate(shuffled_doors):
                if door1_id in used_doors:
                    continue

                from_a, to_b = door_info[door1_id]  # door1: A→B

                # Find door2: C→D where A,B,C,D are all different
                # Shuffle the search order for variety
                search_order = list(range(i + 1, len(shuffled_doors)))
                self.rng.shuffle(search_order)

                for j in search_order:
                    door2_id = shuffled_doors[j]
                    if door2_id in used_doors:
                        continue

                    from_c, to_d = door_info[door2_id]  # door2: C→D

                    # All 4 areas must be different for a clean swap
                    if len({from_a, to_b, from_c, to_d}) < 4:
                        continue

                    # Find door3: any unused door from D (for D→A return path)
                    door3_id = None
                    for d_id in shuffled_doors_from_area.get(to_d, []):
                        if d_id not in used_doors and d_id != door2_id:
                            door3_id = d_id
                            break

                    if not door3_id:
                        continue

                    # Find door4: any unused door from B (for B→C return path)
                    door4_id = None
                    for d_id in shuffled_doors_from_area.get(to_b, []):
                        if d_id not in used_doors and d_id != door1_id:
                            door4_id = d_id
                            break

                    if not door4_id:
                        continue

                    # We have a valid 4-door swap!
                    used_doors.update({door1_id, door2_id, door3_id, door4_id})
                    swap_count += 1

                    # Apply redirects:
                    # door1: A→B becomes A→D
                    template = templates_to_area.get(to_d)
                    if template and template != door1_id:
                        self.redirects[door1_id] = template

                    # door2: C→D becomes C→B
                    template = templates_to_area.get(to_b)
                    if template and template != door2_id:
                        self.redirects[door2_id] = template

                    # door3: D→? becomes D→A
                    template = templates_to_area.get(from_a)
                    if template and template != door3_id:
                        self.redirects[door3_id] = template

                    # door4: B→? becomes B→C
                    template = templates_to_area.get(from_c)
                    if template and template != door4_id:
                        self.redirects[door4_id] = template

                    break  # Move to next door1

            # Validate
            graph = self.build_adjacency_graph(use_redirects=True)

            if not self.is_fully_connected(graph):
                continue

            if not self.can_escape_all_areas(graph):
                continue

            # Check bidirectionality
            is_bidirectional = True
            for from_area, to_areas in graph.items():
                if from_area in PROTECTED_AREAS:
                    continue
                for to_area in to_areas:
                    if to_area in PROTECTED_AREAS:
                        continue
                    if from_area not in graph.get(to_area, set()):
                        is_bidirectional = False
                        break
                if not is_bidirectional:
                    break

            if is_bidirectional:
                print(
                    f"Found valid paired randomization on attempt {attempt + 1} ({swap_count} 4-door swaps, {len(self.redirects)} redirects)")
                return self.redirects

        print(f"Could not find valid paired randomization after {max_attempts} attempts")
        print("Falling back to chaos mode")
        return self.randomize_with_validation(max_attempts=50)

    def randomize_with_validation(self, max_attempts: int = 100) -> Dict[str, str]:
        """
        Randomize doors with validation to ensure the game remains completable.
        Uses multiple attempts to find a valid configuration.
        """
        randomizable = self.get_randomizable_doors()

        for attempt in range(max_attempts):
            self.redirects = {}

            # Create a shuffled list of destination doors
            destinations = randomizable.copy()
            self.rng.shuffle(destinations)

            # Map each door to a random destination
            for source, dest in zip(randomizable, destinations):
                if source != dest:  # Don't redirect to self
                    self.redirects[source] = dest

            # Validate
            graph = self.build_adjacency_graph(use_redirects=True)

            if self.is_fully_connected(graph) and self.can_escape_all_areas(graph):
                print(f"Found valid randomization on attempt {attempt + 1}")
                return self.redirects

        print(f"Could not find valid randomization after {max_attempts} attempts")
        self.redirects = {}
        return self.redirects

    def export_redirects_for_lua(self) -> Dict[str, dict]:
        """
        Export redirects in a format the Lua mod can use.
        Returns a dict mapping source_door_id to redirect info.
        """
        lua_redirects = {}

        for source_id, target_id in self.redirects.items():
            source_door = self.doors.get(source_id)
            target_door = self.doors.get(target_id)

            if not source_door or not target_door:
                continue

            lua_redirects[source_id] = {
                "target_area": target_door.to_area,
                "target_area_name": AREA_NAMES.get(target_door.to_area, target_door.to_area),
                "template_door_id": target_id,
                "position": {
                    "x": target_door.position[0],
                    "y": target_door.position[1],
                    "z": target_door.position[2],
                },
                "angle": {
                    "x": target_door.angle[0],
                    "y": target_door.angle[1],
                    "z": target_door.angle[2],
                },
            }

        return lua_redirects

    def print_summary(self) -> None:
        """Print a summary of areas and doors"""
        print(f"\n=== Door Randomizer Summary ===")
        print(f"Total areas: {len(self.areas)}")
        print(f"Total doors: {len(self.doors)}")
        print(f"Active redirects: {len(self.redirects)}")

        print(f"\nAreas:")
        for code, area in sorted(self.areas.items()):
            print(f"  {code} ({area.name}): {len(area.outgoing_doors)} exits, {len(area.incoming_doors)} entrances")

        if self.redirects:
            print(f"\nRedirects:")
            for source, target in self.redirects.items():
                src = self.doors[source]
                tgt = self.doors[target]
                print(f"  {src.from_area}->{src.to_area} now goes to {tgt.to_area}")


def generate_door_randomization(door_json: dict, seed: int) -> Dict[str, dict]:
    """
    Main entry point for generating door randomization.

    Args:
        door_json: Door data loaded from JSON file
        seed: Random seed for reproducible randomization

    Returns:
        Dict of redirects in Lua-compatible format
    """
    randomizer = DoorRandomizer(seed)
    randomizer.load_doors_from_json(door_json)
    randomizer.add_missing_doors()

    # Use validation-based randomization
    randomizer.randomize_with_validation()

    randomizer.print_summary()

    return randomizer.export_redirects_for_lua()


# Pre-built door data (embedded so we don't need external file during AP generation)
# This can be updated when you collect the remaining 4 doors
EMBEDDED_DOOR_DATA = {
    "SCN_s100|s136|door0": {"from_area_code": "s100", "to_area_code": "s136",
                            "position": {"x": 131.51, "y": 8.0, "z": 251.65}, "angle": {"x": 0.0, "y": 1.48, "z": 0.0},
                            "door_no": 0},
    "SCN_s100|s200|door0": {"from_area_code": "s100", "to_area_code": "s200",
                            "position": {"x": 145.53, "y": 0.0, "z": 84.66}, "angle": {"x": 0.0, "y": 2.42, "z": 0.0},
                            "door_no": 0},
    "SCN_s100|s900|door0": {"from_area_code": "s100", "to_area_code": "s900",
                            "position": {"x": 49.84, "y": 0.0, "z": 119.72}, "angle": {"x": 0.0, "y": -1.52, "z": 0.0},
                            "door_no": 0},
    "SCN_s135|s136|door0": {"from_area_code": "s135", "to_area_code": "s136",
                            "position": {"x": 145.98, "y": 14.0, "z": 249.69}, "angle": {"x": 0.0, "y": -4.0, "z": 0.0},
                            "door_no": 0},
    "SCN_s136|s100|door0": {"from_area_code": "s136", "to_area_code": "s100",
                            "position": {"x": 127.86, "y": 8.0, "z": 252.53}, "angle": {"x": 0.0, "y": -2.76, "z": 0.0},
                            "door_no": 0},
    "SCN_s136|s135|door0": {"from_area_code": "s136", "to_area_code": "s135",
                            "position": {"x": 142.5, "y": 14.0, "z": 250.5}, "angle": {"x": 0.0, "y": -3.0, "z": 0.0},
                            "door_no": 0},
    "SCN_s136|s231|door0": {"from_area_code": "s136", "to_area_code": "s231",
                            "position": {"x": 171.8, "y": 9.5, "z": 110.9}, "angle": {"x": 0.0, "y": 2.3, "z": 0.0},
                            "door_no": 0},
    "SCN_s200|s100|door0": {"from_area_code": "s200", "to_area_code": "s100",
                            "position": {"x": 137.3, "y": 0.0, "z": 92.67}, "angle": {"x": 0.0, "y": -0.66, "z": 0.0},
                            "door_no": 0},
    "SCN_s200|s230|door0": {"from_area_code": "s200", "to_area_code": "s230",
                            "position": {"x": 170.94, "y": 0.0, "z": 64.85}, "angle": {"x": 0.0, "y": 1.54, "z": 0.0},
                            "door_no": 0},
    "SCN_s200|s300|door0": {"from_area_code": "s200", "to_area_code": "s300",
                            "position": {"x": -113.0, "y": 0.0, "z": -68.6}, "angle": {"x": 0.0, "y": -2.0, "z": 0.0},
                            "door_no": 0},
    "SCN_s200|s503|door0": {"from_area_code": "s200", "to_area_code": "s503",
                            "position": {"x": 103.58, "y": -1.69, "z": -86.12},
                            "angle": {"x": 0.0, "y": 3.12, "z": 0.0}, "door_no": 0},
    "SCN_s200|s600|door0": {"from_area_code": "s200", "to_area_code": "s600",
                            "position": {"x": 199.1, "y": 0.0, "z": -28.2}, "angle": {"x": 0.0, "y": 3.14, "z": 0.0},
                            "door_no": 0},
    "SCN_s200|s700|door0": {"from_area_code": "s200", "to_area_code": "s700",
                            "position": {"x": 111.39, "y": 0.0, "z": -26.82}, "angle": {"x": 0.0, "y": -1.01, "z": 0.0},
                            "door_no": 0},
    "SCN_s230|s200|door0": {"from_area_code": "s230", "to_area_code": "s200",
                            "position": {"x": 163.49, "y": 0.0, "z": 64.39}, "angle": {"x": 0.0, "y": -1.58, "z": 0.0},
                            "door_no": 0},
    "SCN_s230|s231|door0": {"from_area_code": "s230", "to_area_code": "s231",
                            "position": {"x": 196.75, "y": 8.05, "z": 65.24}, "angle": {"x": 0.0, "y": -0.98, "z": 0.0},
                            "door_no": 0},
    "SCN_s230|s231|door1": {"from_area_code": "s230", "to_area_code": "s231",
                            "position": {"x": 195.0, "y": 8.0, "z": 100.0}, "angle": {"x": 0.0, "y": -1.0, "z": 0.0},
                            "door_no": 1},
    "SCN_s231|s136|door0": {"from_area_code": "s231", "to_area_code": "s136",
                            "position": {"x": 153.19, "y": 9.32, "z": 216.92}, "angle": {"x": 0.0, "y": 0.93, "z": 0.0},
                            "door_no": 0},
    "SCN_s231|s230|door0": {"from_area_code": "s231", "to_area_code": "s230",
                            "position": {"x": 197.0, "y": 8.05, "z": 67.8}, "angle": {"x": 0.0, "y": 0.8, "z": 0.0},
                            "door_no": 0},
    "SCN_s231|s230|door1": {"from_area_code": "s231", "to_area_code": "s230",
                            "position": {"x": 193.8, "y": 0.0, "z": 99.7}, "angle": {"x": 0.0, "y": -2.5, "z": 0.0},
                            "door_no": 1},
    "SCN_s300|s200|door0": {"from_area_code": "s300", "to_area_code": "s200",
                            "position": {"x": 205.4, "y": 0.0, "z": -15.0}, "angle": {"x": 0.0, "y": -3.0, "z": 0.0},
                            "door_no": 0},
    "SCN_s300|s400|door0": {"from_area_code": "s300", "to_area_code": "s400",
                            "position": {"x": -180.49, "y": 5.0, "z": -107.92},
                            "angle": {"x": 0.0, "y": -3.0, "z": 0.0}, "door_no": 0},
    "SCN_s300|s400|door1": {"from_area_code": "s300", "to_area_code": "s400",
                            "position": {"x": -85.04, "y": 5.0, "z": -84.02}, "angle": {"x": 0.0, "y": 3.0, "z": 0.0},
                            "door_no": 1},
    "SCN_s300|sa00|door0": {"from_area_code": "s300", "to_area_code": "sa00",
                            "position": {"x": -130.65, "y": 0.0, "z": 107.06}, "angle": {"x": 0.0, "y": 0.19, "z": 0.0},
                            "door_no": 0},
    "SCN_s400|s300|door0": {"from_area_code": "s400", "to_area_code": "s300",
                            "position": {"x": -175.12, "y": 5.0, "z": -101.03},
                            "angle": {"x": 0.0, "y": 0.87, "z": 0.0}, "door_no": 0},
    "SCN_s400|s300|door1": {"from_area_code": "s400", "to_area_code": "s300",
                            "position": {"x": -85.16, "y": 5.0, "z": -75.27}, "angle": {"x": 0.0, "y": 0.0, "z": 0.0},
                            "door_no": 1},
    "SCN_s400|s401|door0": {"from_area_code": "s400", "to_area_code": "s401",
                            "position": {"x": -9.4, "y": 9.7, "z": -203.2}, "angle": {"x": 0.0, "y": 1.5, "z": 0.0},
                            "door_no": 0},
    "SCN_s400|s501|door0": {"from_area_code": "s400", "to_area_code": "s501",
                            "position": {"x": 45.0, "y": 5.0, "z": -165.0}, "angle": {"x": 0.0, "y": 1.27, "z": 0.0},
                            "door_no": 0},
    "SCN_s400|s700|door0": {"from_area_code": "s400", "to_area_code": "s700",
                            "position": {"x": 20.01, "y": 5.0, "z": -142.11}, "angle": {"x": 0.0, "y": -0.15, "z": 0.0},
                            "door_no": 0},
    "SCN_s401|s400|door0": {"from_area_code": "s401", "to_area_code": "s400",
                            "position": {"x": -8.5, "y": 7.0, "z": -204.8}, "angle": {"x": 0.0, "y": -0.2, "z": 0.0},
                            "door_no": 0},
    "SCN_s501|s400|door0": {"from_area_code": "s501", "to_area_code": "s400",
                            "position": {"x": 37.0, "y": 5.0, "z": -165.0}, "angle": {"x": 0.0, "y": -1.45, "z": 0.0},
                            "door_no": 0},
    "SCN_s503|s200|door0": {"from_area_code": "s503", "to_area_code": "s200",
                            "position": {"x": 106.1, "y": 0.0, "z": -66.28}, "angle": {"x": 0.0, "y": 0.07, "z": 0.0},
                            "door_no": 0},
    "SCN_s600|s200|door0": {"from_area_code": "s600", "to_area_code": "s200",
                            "position": {"x": 198.7, "y": 0.0, "z": -24.3}, "angle": {"x": 0.0, "y": 0.0, "z": 0.0},
                            "door_no": 0},
    "SCN_s600|s601|door0": {"from_area_code": "s600", "to_area_code": "s601",
                            "position": {"x": -243.06, "y": -3.0, "z": -262.9},
                            "angle": {"x": 0.0, "y": -2.74, "z": 0.0}, "door_no": 0},
    "SCN_s600|s700|door0": {"from_area_code": "s600", "to_area_code": "s700",
                            "position": {"x": -195.38, "y": 0.1, "z": -147.9},
                            "angle": {"x": 0.0, "y": -1.57, "z": 0.0}, "door_no": 0},
    "SCN_s600|s900|door0": {"from_area_code": "s600", "to_area_code": "s900",
                            "position": {"x": -21.3, "y": 0.0, "z": 167.2}, "angle": {"x": 0.0, "y": -3.1, "z": 0.0},
                            "door_no": 0},
    "SCN_s600|sa00|door0": {"from_area_code": "s600", "to_area_code": "sa00",
                            "position": {"x": -133.5, "y": 0.0, "z": 115.4}, "angle": {"x": 0.0, "y": 1.4, "z": 0.0},
                            "door_no": 0},
    "SCN_s601|s600|door0": {"from_area_code": "s601", "to_area_code": "s600",
                            "position": {"x": -244.16, "y": -2.99, "z": -257.16},
                            "angle": {"x": 0.0, "y": 1.25, "z": 0.0}, "door_no": 0},
    "SCN_s700|s200|door0": {"from_area_code": "s700", "to_area_code": "s200",
                            "position": {"x": 116.8, "y": 0.0, "z": -33.7}, "angle": {"x": 0.0, "y": 1.33, "z": 0.0},
                            "door_no": 0},
    "SCN_s700|s400|door0": {"from_area_code": "s700", "to_area_code": "s400",
                            "position": {"x": 20.0, "y": 5.03, "z": -150.0}, "angle": {"x": 0.0, "y": -3.08, "z": 0.0},
                            "door_no": 0},
    "SCN_s700|s600|door0": {"from_area_code": "s700", "to_area_code": "s600",
                            "position": {"x": -169.35, "y": -2.25, "z": -147.5},
                            "angle": {"x": 0.0, "y": 1.53, "z": 0.0}, "door_no": 0},
    "SCN_s700|sa00|door0": {"from_area_code": "s700", "to_area_code": "sa00",
                            "position": {"x": -96.0, "y": 0.0, "z": 127.5}, "angle": {"x": 0.0, "y": -0.85, "z": 0.0},
                            "door_no": 0},
    "SCN_s900|s100|door0": {"from_area_code": "s900", "to_area_code": "s100",
                            "position": {"x": 57.22, "y": 0.0, "z": 120.1}, "angle": {"x": 0.0, "y": 1.66, "z": 0.0},
                            "door_no": 0},
    "SCN_s900|s600|door0": {"from_area_code": "s900", "to_area_code": "s600",
                            "position": {"x": -21.5, "y": 0.0, "z": 171.2}, "angle": {"x": 0.0, "y": 0.0, "z": 0.0},
                            "door_no": 0},
    "SCN_s900|sa00|door0": {"from_area_code": "s900", "to_area_code": "sa00",
                            "position": {"x": -73.0, "y": 0.0, "z": 162.0}, "angle": {"x": 0.0, "y": -1.68, "z": 0.0},
                            "door_no": 0},
    "SCN_sa00|s300|door0": {"from_area_code": "sa00", "to_area_code": "s300",
                            "position": {"x": -129.81, "y": 0.0, "z": 92.01}, "angle": {"x": 0.0, "y": -3.0, "z": 0.0},
                            "door_no": 0},
    "SCN_sa00|s600|door0": {"from_area_code": "sa00", "to_area_code": "s600",
                            "position": {"x": -137.5, "y": 0.0, "z": 115.55}, "angle": {"x": 0.0, "y": -1.5, "z": 0.0},
                            "door_no": 0},
    "SCN_sa00|s700|door0": {"from_area_code": "sa00", "to_area_code": "s700",
                            "position": {"x": -89.24, "y": 0.0, "z": 119.28}, "angle": {"x": 0.0, "y": 2.41, "z": 0.0},
                            "door_no": 0},
    "SCN_s400|s500|door0": {"from_area_code": "s400", "to_area_code": "s500",
                            "position": {"x": -182.5, "y": 5.0, "z": -213.0}, "angle": {"x": 0.0, "y": -2.98, "z": 0.0},
                            "door_no": 0},
    "SCN_s500|s400|door0": {"from_area_code": "s500", "to_area_code": "s400",
                            "position": {"x": -182.5, "y": 5.0, "z": -207.0}, "angle": {"x": 0.0, "y": 0.1, "z": 0.0},
                            "door_no": 0},
    "SCN_s500|s600|door0": {"from_area_code": "s500", "to_area_code": "s600",
                            "position": {"x": -230.5, "y": 5.0, "z": -249.0}, "angle": {"x": 0.0, "y": 3.14, "z": 0.0},
                            "door_no": 0},
    "SCN_s600|s500|door0": {"from_area_code": "s600", "to_area_code": "s500",
                            "position": {"x": -230.23, "y": 5.0, "z": -244.97}, "angle": {"x": 0.0, "y": -0.17, "z": 0.0},
                            "door_no": 0},
}

# Door randomization modes
DOOR_MODE_CHAOS = 0
DOOR_MODE_PAIRED = 1


def generate_door_randomization_for_ap(random_source, mode: int = DOOR_MODE_CHAOS, use_embedded: bool = True) -> Dict[
    str, dict]:
    """
    Generate door randomization for Archipelago world generation.

    Args:
        random_source: The multiworld.random object for seeded randomization
        mode: DOOR_MODE_CHAOS (0) for full random, DOOR_MODE_PAIRED (1) for bidirectional pairs
        use_embedded: If True, use embedded door data. If False, requires external file.

    Returns:
        Dict of redirects in Lua-compatible format
    """
    # Create randomizer with a seed derived from the AP random
    randomizer = DoorRandomizer(seed=random_source.randint(0, 2 ** 31))

    if use_embedded:
        randomizer.load_doors_from_json({"doors": EMBEDDED_DOOR_DATA})

    randomizer.add_missing_doors()

    # Generate randomization based on mode
    if mode == DOOR_MODE_PAIRED:
        randomizer.randomize_paired(max_attempts=500)
    else:
        # Default to chaos mode
        randomizer.randomize_with_validation(max_attempts=100)

    return randomizer.export_redirects_for_lua()


def generate_door_map_html(redirects: Dict[str, dict], title: str = "Door Randomization Map") -> str:
    """
    Generate an HTML visualization of door redirects for inclusion in AP output.

    Args:
        redirects: The door redirects dictionary from export_redirects_for_lua()
        title: Title for the HTML page

    Returns:
        HTML string content
    """
    import json

    # Color scheme for areas
    area_colors = {
        "s135": "#FFD700", "s136": "#90EE90", "s231": "#87CEEB", "s230": "#DDA0DD",
        "s200": "#FF6B6B", "s100": "#4ECDC4", "s900": "#95E1D3", "sa00": "#F38181",
        "s300": "#AA96DA", "s400": "#FCBAD3", "s700": "#A8D8EA", "s501": "#FFB347",
        "s503": "#B19CD9", "s401": "#77DD77", "s600": "#808080", "s500": "#F0E68C",
        "s601": "#CD5C5C",
    }

    short_names = {
        "s135": "Helipad", "s136": "Safe Room", "s231": "Rooftop", "s230": "Svc Hall",
        "s200": "Paradise", "s100": "Entrance", "s900": "Al Fresca", "sa00": "Food Court",
        "s300": "Wonderland", "s400": "North Plaza", "s700": "Leisure Pk", "s501": "Crislip's",
        "s503": "Colby's", "s401": "Hideout", "s600": "Tunnels", "s500": "Grocery",
        "s601": "Butcher",
    }

    # Rebuild door info from redirects to build graph
    # Parse door IDs to get from_area, and use target_area for destination
    all_areas = set()
    edges = []  # (from_area, to_area, is_new)

    # Track vanilla connections from embedded data
    vanilla_connections = {}  # from_area -> set of to_areas
    for door_id, door_data in EMBEDDED_DOOR_DATA.items():
        from_area = door_data.get("from_area_code", "")
        to_area = door_data.get("to_area_code", "")
        if from_area and to_area:
            all_areas.add(from_area)
            all_areas.add(to_area)
            if from_area not in vanilla_connections:
                vanilla_connections[from_area] = set()
            vanilla_connections[from_area].add(to_area)

    # Build randomized connections from redirects - track door counts
    rando_connections = {}  # from_area -> {to_area -> count}
    for door_id, redirect_info in redirects.items():
        # Parse door_id: SCN_{from}|{to}|door{n}
        parts = door_id.replace("SCN_", "").split("|")
        if len(parts) >= 2:
            from_area = parts[0]
            target_area = redirect_info.get("target_area", "")
            if from_area and target_area:
                all_areas.add(from_area)
                all_areas.add(target_area)
                if from_area not in rando_connections:
                    rando_connections[from_area] = {}
                if target_area not in rando_connections[from_area]:
                    rando_connections[from_area][target_area] = 0
                rando_connections[from_area][target_area] += 1

    # Add non-redirected connections (doors that weren't changed)
    for door_id, door_data in EMBEDDED_DOOR_DATA.items():
        if door_id not in redirects:
            from_area = door_data.get("from_area_code", "")
            to_area = door_data.get("to_area_code", "")
            if from_area and to_area:
                if from_area not in rando_connections:
                    rando_connections[from_area] = {}
                if to_area not in rando_connections[from_area]:
                    rando_connections[from_area][to_area] = 0
                rando_connections[from_area][to_area] += 1

    # Build nodes data
    nodes_data = []
    for area_code in sorted(all_areas):
        color = area_colors.get(area_code, "#CCCCCC")
        label = short_names.get(area_code, area_code)
        full_name = AREA_NAMES.get(area_code, area_code)
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

    # Build edges data - consolidate bidirectional connections
    edges_data = []
    processed_pairs = set()  # Track area pairs we've already handled

    for from_area, to_areas_dict in rando_connections.items():
        for to_area, door_count_forward in to_areas_dict.items():
            # Create a canonical pair key (alphabetically sorted) to avoid duplicates
            pair_key = tuple(sorted([from_area, to_area]))
            if pair_key in processed_pairs:
                continue
            processed_pairs.add(pair_key)

            # Check if reverse connection exists (bidirectional)
            reverse_count = rando_connections.get(to_area, {}).get(from_area, 0)
            is_bidirectional = reverse_count > 0

            # Check if either direction is new
            vanilla_dests_forward = vanilla_connections.get(from_area, set())
            vanilla_dests_reverse = vanilla_connections.get(to_area, set())
            is_new_forward = to_area not in vanilla_dests_forward
            is_new_reverse = from_area not in vanilla_dests_reverse if is_bidirectional else False
            is_new = is_new_forward or is_new_reverse

            color = "#00AA00" if is_new else "#888888"
            width = 3 if is_new else 1

            from_name = short_names.get(from_area, from_area)
            to_name = short_names.get(to_area, to_area)

            if is_bidirectional:
                # Bidirectional: show both directions with arrows on each end
                arrows = {"to": {"enabled": True}, "from": {"enabled": True}}

                # Build label showing door counts for both directions
                total_doors = door_count_forward + reverse_count
                if door_count_forward > 1 or reverse_count > 1:
                    # Show counts per direction if different, or total if same
                    if door_count_forward == reverse_count:
                        edge_label = str(door_count_forward) if door_count_forward > 1 else ""
                    else:
                        edge_label = f"{door_count_forward}|{reverse_count}"
                else:
                    edge_label = ""

                # Build tooltip
                fwd_str = f" (x{door_count_forward})" if door_count_forward > 1 else ""
                rev_str = f" (x{reverse_count})" if reverse_count > 1 else ""
                new_marker = "NEW: " if is_new else ""
                edge_title = f"{new_marker}{from_name} <-> {to_name}\n{from_name}->{to_name}{fwd_str}\n{to_name}->{from_name}{rev_str}"
            else:
                # One-way: single arrow
                arrows = "to"
                count_str = f" (x{door_count_forward})" if door_count_forward > 1 else ""
                edge_title = f"{'NEW: ' if is_new else ''}{from_name} -> {to_name}{count_str}"
                edge_label = str(door_count_forward) if door_count_forward > 1 else ""

            edges_data.append({
                "from": from_area,
                "to": to_area,
                "arrows": arrows,
                "color": {"color": color, "highlight": "#FF0000"},
                "width": width,
                "dashes": False,
                "title": edge_title,
                "label": edge_label,
                "font": {"size": 10, "color": "#FFFFFF", "strokeWidth": 2, "strokeColor": "#000000"}
            })

    # Generate redirect list HTML
    redirect_list_html = ""
    for source_id, redirect_info in sorted(redirects.items()):
        parts = source_id.replace("SCN_", "").split("|")
        if len(parts) >= 2:
            orig_from = short_names.get(parts[0], parts[0])
            orig_to = short_names.get(parts[1], parts[1])
            new_to = short_names.get(redirect_info.get("target_area", "?"), "?")
            redirect_list_html += f'<div class="redirect-item"><span class="orig">{orig_from} to {orig_to}</span> <span class="arrow">=&gt;</span> <span class="new">{new_to}</span></div>\n'

    nodes_json = json.dumps(nodes_data)
    edges_json = json.dumps(edges_data)

    # Calculate total doors and unique connections
    total_doors = sum(sum(counts.values()) for counts in rando_connections.values())
    total_unique_connections = sum(len(counts) for counts in rando_connections.values())

    html = f'''<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>{title}</title>
    <script src="https://unpkg.com/vis-network@9.1.6/dist/vis-network.min.js"></script>
    <style>
        * {{ margin: 0; padding: 0; box-sizing: border-box; }}
        body {{ font-family: Arial, sans-serif; display: flex; height: 100vh; background: #1a1a2e; color: #eee; }}
        #graph-container {{ flex: 1; height: 100%; background: #1a1a2e; }}
        #error-msg {{ color: #ff6b6b; padding: 20px; display: none; }}
        #sidebar {{ width: 350px; background: #16213e; padding: 20px; overflow-y: auto; border-left: 2px solid #0f3460; }}
        h1 {{ font-size: 1.4em; margin-bottom: 15px; color: #e94560; }}
        h2 {{ font-size: 1.1em; margin: 15px 0 10px 0; color: #0f3460; background: #e94560; padding: 5px 10px; border-radius: 4px; }}
        .stats {{ background: #0f3460; padding: 10px; border-radius: 4px; margin-bottom: 15px; }}
        .stats div {{ margin: 5px 0; }}
        .redirect-item {{ background: #0f3460; padding: 8px; margin: 5px 0; border-radius: 4px; font-size: 0.9em; }}
        .redirect-item .orig {{ color: #ff6b6b; text-decoration: line-through; }}
        .redirect-item .arrow {{ color: #ffd93d; margin: 0 5px; }}
        .redirect-item .new {{ color: #6bcb77; font-weight: bold; }}
        .legend {{ margin-top: 20px; padding: 10px; background: #0f3460; border-radius: 4px; }}
        .legend-item {{ display: flex; align-items: center; margin: 5px 0; }}
        .legend-color {{ width: 30px; height: 4px; margin-right: 10px; border-radius: 2px; }}
        .legend-color.new {{ background: #00AA00; height: 6px; }}
        .legend-color.unchanged {{ background: #888888; }}
    </style>
</head>
<body>
    <div id="graph-container"><div id="error-msg"></div></div>
    <div id="sidebar">
        <h1>Door Randomization Map</h1>
        <div class="stats">
            <div>Areas: {len(all_areas)}</div>
            <div>Total Doors: {total_doors}</div>
            <div>Unique Connections: {total_unique_connections}</div>
            <div>Redirects: {len(redirects)}</div>
        </div>
        <div class="legend">
            <strong>Legend:</strong>
            <div class="legend-item"><div class="legend-color new"></div><span>New/Changed Connection</span></div>
            <div class="legend-item"><div class="legend-color unchanged"></div><span>Unchanged Connection</span></div>
            <div class="legend-item"><span style="margin-left: 5px;">&lt;--&gt; Bidirectional (arrows both ends)</span></div>
            <div class="legend-item"><span style="margin-left: 5px;">Numbers show door count (or A|B for each direction)</span></div>
        </div>
        <h2>Door Redirects</h2>
        <div id="redirect-list">{redirect_list_html}</div>
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
                physics: {{ enabled: true, solver: "forceAtlas2Based", forceAtlas2Based: {{ gravitationalConstant: -100, centralGravity: 0.01, springLength: 150, springConstant: 0.08, damping: 0.4 }}, stabilization: {{ iterations: 200 }} }},
                nodes: {{ shape: "box", margin: 10, shadow: true }},
                edges: {{ smooth: {{ type: "curvedCW", roundness: 0.2 }}, shadow: true }},
                interaction: {{ hover: true, tooltipDelay: 100 }}
            }};
            var network = new vis.Network(container, data, options);
            network.on("stabilizationIterationsDone", function() {{ network.setOptions({{ physics: {{ enabled: false }} }}); }});
        }} catch (e) {{
            document.getElementById("error-msg").style.display = "block";
            document.getElementById("error-msg").innerText = "Error: " + e.message;
            console.error(e);
        }}
    </script>
</body>
</html>'''

    return html


# For testing
if __name__ == "__main__":
    import json
    import random as stdlib_random

    # Test with embedded data
    print("Testing with embedded door data...")


    class MockRandom:
        def randint(self, a, b):
            return stdlib_random.randint(a, b)


    mock_random = MockRandom()
    result = generate_door_randomization_for_ap(mock_random)

    print(f"\nGenerated {len(result)} door redirects")
    print("\nSample output (first 3):")
    for i, (door_id, redirect) in enumerate(list(result.items())[:3]):
        print(f"  {door_id}: -> {redirect['target_area_name']}")

    print("\nFull JSON export:")
    print(json.dumps(result, indent=2)[:1000] + "...")