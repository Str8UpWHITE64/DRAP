# world/drdr/DoorRandomization.py
"""
Door Randomization Logic for Dead Rising Deluxe Remaster Archipelago

Ensures all areas remain reachable, no softlocks, and the game stays completable.
"""

from typing import Dict, List, Set, Tuple, Optional
from dataclasses import dataclass
import random


@dataclass
class DoorEndpoint:
    door_id: str
    from_area: str
    to_area: str
    position: Tuple[float, float, float]
    angle: Tuple[float, float, float]
    door_no: int = 0


@dataclass
class AreaInfo:
    code: str
    name: str
    outgoing_doors: List[str]
    incoming_doors: List[str]


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

PROTECTED_AREAS = {
    "s135",  # Helipad
    "s136",  # Safe Room
    "s601",  # Butcher
}

DEAD_END_AREAS = {
    "s135": ["s136"],
    "s401": ["s400"],
    "s501": ["s400"],
    "s503": ["s200"],
    "s601": ["s600"],
}

START_AREA = "s136"


class DoorRandomizer:
    def __init__(self, seed: Optional[int] = None):
        self.rng = random.Random(seed)
        self.doors: Dict[str, DoorEndpoint] = {}
        self.areas: Dict[str, AreaInfo] = {}
        self.redirects: Dict[str, str] = {}

    def load_doors_from_json(self, door_data: dict) -> None:
        doors_dict = door_data.get("doors", door_data)

        for door_id, door_info in doors_dict.items():
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

            if from_area not in self.areas:
                self.areas[from_area] = AreaInfo(
                    code=from_area, name=AREA_NAMES.get(from_area, from_area),
                    outgoing_doors=[], incoming_doors=[]
                )
            if to_area not in self.areas:
                self.areas[to_area] = AreaInfo(
                    code=to_area, name=AREA_NAMES.get(to_area, to_area),
                    outgoing_doors=[], incoming_doors=[]
                )

            self.areas[from_area].outgoing_doors.append(door_id)
            self.areas[to_area].incoming_doors.append(door_id)

    def add_missing_doors(self) -> None:
        """Add placeholder data for missing doors (Grocery Store connections)."""
        missing_doors = [
            DoorEndpoint("SCN_s400|s500|door0", "s400", "s500", (0, 5, -180), (0, 1.5, 0), 0),
            DoorEndpoint("SCN_s500|s400|door0", "s500", "s400", (0, 0, 0), (0, -1.5, 0), 0),
            DoorEndpoint("SCN_s500|s600|door0", "s500", "s600", (0, 0, 50), (0, 0, 0), 0),
            DoorEndpoint("SCN_s600|s500|door0", "s600", "s500", (-100, 0, 0), (0, 3.14, 0), 0),
        ]

        for door in missing_doors:
            if door.door_id not in self.doors:
                self.doors[door.door_id] = door

                if door.from_area not in self.areas:
                    self.areas[door.from_area] = AreaInfo(
                        code=door.from_area, name=AREA_NAMES.get(door.from_area, door.from_area),
                        outgoing_doors=[], incoming_doors=[]
                    )
                if door.to_area not in self.areas:
                    self.areas[door.to_area] = AreaInfo(
                        code=door.to_area, name=AREA_NAMES.get(door.to_area, door.to_area),
                        outgoing_doors=[], incoming_doors=[]
                    )

                self.areas[door.from_area].outgoing_doors.append(door.door_id)
                self.areas[door.to_area].incoming_doors.append(door.door_id)

    def get_door_pairs(self) -> List[Tuple[str, str]]:
        """Find bidirectional door pairs (A->B and B->A)."""
        pairs = []
        seen = set()

        for door_id, door in self.doors.items():
            if door_id in seen:
                continue
            reverse_pattern = f"SCN_{door.to_area}|{door.from_area}|door{door.door_no}"
            if reverse_pattern in self.doors:
                pairs.append((door_id, reverse_pattern))
                seen.add(door_id)
                seen.add(reverse_pattern)
            else:
                pairs.append((door_id, None))
                seen.add(door_id)

        return pairs

    def get_randomizable_doors(self) -> List[str]:
        """Get door IDs that can be randomized (excluding protected areas)."""
        return [
            door_id for door_id, door in self.doors.items()
            if door.from_area not in PROTECTED_AREAS and door.to_area not in PROTECTED_AREAS
        ]

    def build_adjacency_graph(self, use_redirects: bool = False) -> Dict[str, Set[str]]:
        """Build area connection graph, optionally following redirects."""
        graph: Dict[str, Set[str]] = {area: set() for area in self.areas}

        for door_id, door in self.doors.items():
            if use_redirects and door_id in self.redirects:
                target_door = self.doors[self.redirects[door_id]]
                graph[door.from_area].add(target_door.to_area)
            else:
                graph[door.from_area].add(door.to_area)

        return graph

    def is_fully_connected(self, graph: Dict[str, Set[str]], start: str = START_AREA) -> bool:
        """BFS check that all areas are reachable from start."""
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

        return visited >= set(self.areas.keys())

    def can_escape_all_areas(self, graph: Dict[str, Set[str]]) -> bool:
        """Check every non-protected area has at least one exit."""
        for area in self.areas:
            if area in PROTECTED_AREAS:
                continue
            if not graph.get(area):
                return False
        return True

    def generate_spanning_tree_redirects(self) -> Dict[str, str]:
        """Generate redirects forming a spanning tree to ensure connectivity."""
        connected = {START_AREA}
        for door_id, door in self.doors.items():
            if door.from_area == START_AREA:
                connected.add(door.to_area)

        redirects = {}

        while len(connected) < len(self.areas):
            candidates = [
                door_id for door_id, door in self.doors.items()
                if door.from_area in connected and door.to_area not in connected
            ]
            if not candidates:
                unconnected = set(self.areas.keys()) - connected
                candidates = [
                    door_id for door_id, door in self.doors.items()
                    if door.to_area in unconnected
                ]
                if not candidates:
                    break

            chosen_door = self.doors[self.rng.choice(candidates)]
            connected.add(chosen_door.to_area)

        return redirects

    def randomize_paired(self, max_attempts: int = 500) -> Dict[str, str]:
        """
        Randomize doors in bidirectional paired mode using 4-door swaps.
        If A->B and C->D swap, return paths D->A and B->C are also created.
        """
        randomizable_doors = list(self.get_randomizable_doors())

        door_info = {}
        doors_from_area = {}
        for door_id in randomizable_doors:
            door = self.doors[door_id]
            door_info[door_id] = (door.from_area, door.to_area)
            if door.from_area not in doors_from_area:
                doors_from_area[door.from_area] = []
            doors_from_area[door.from_area].append(door_id)

        templates: Dict[str, Dict[str, str]] = {}
        for door_id, door in self.doors.items():
            if door.from_area not in templates:
                templates[door.from_area] = {}
            if door.to_area not in templates[door.from_area]:
                templates[door.from_area][door.to_area] = door_id

        for attempt in range(max_attempts):
            self.redirects = {}

            shuffled_doors = randomizable_doors.copy()
            self.rng.shuffle(shuffled_doors)

            shuffled_doors_from_area = {}
            for area, doors in doors_from_area.items():
                shuffled_list = doors.copy()
                self.rng.shuffle(shuffled_list)
                shuffled_doors_from_area[area] = shuffled_list

            used_doors = set()
            swap_count = 0

            for i, door1_id in enumerate(shuffled_doors):
                if door1_id in used_doors:
                    continue

                from_a, to_b = door_info[door1_id]

                search_order = list(range(i + 1, len(shuffled_doors)))
                self.rng.shuffle(search_order)

                for j in search_order:
                    door2_id = shuffled_doors[j]
                    if door2_id in used_doors:
                        continue

                    from_c, to_d = door_info[door2_id]

                    if len({from_a, to_b, from_c, to_d}) < 4:
                        continue

                    # Find return path doors
                    door3_id = None
                    for d_id in shuffled_doors_from_area.get(to_d, []):
                        if d_id not in used_doors and d_id != door2_id:
                            door3_id = d_id
                            break
                    if not door3_id:
                        continue

                    door4_id = None
                    for d_id in shuffled_doors_from_area.get(to_b, []):
                        if d_id not in used_doors and d_id != door1_id:
                            door4_id = d_id
                            break
                    if not door4_id:
                        continue

                    _, to_e = door_info[door3_id]
                    _, to_f = door_info[door4_id]

                    door1_num = door1_id.split("|")[-1]
                    door2_num = door2_id.split("|")[-1]
                    door3_num = door3_id.split("|")[-1]
                    door4_num = door4_id.split("|")[-1]

                    # Build reverse door IDs for proper spawn positions
                    reverse3_id = f"SCN_{to_e}|{to_d}|{door3_num}"
                    reverse1_id = f"SCN_{to_b}|{from_a}|{door1_num}"
                    reverse4_id = f"SCN_{to_f}|{to_b}|{door4_num}"
                    reverse2_id = f"SCN_{to_d}|{from_c}|{door2_num}"

                    if not all(r in self.doors for r in [reverse3_id, reverse1_id, reverse4_id, reverse2_id]):
                        continue

                    used_doors.update({door1_id, door2_id, door3_id, door4_id})
                    swap_count += 1

                    # Apply redirects using reverse door positions for correct spawning
                    if reverse3_id != door1_id:
                        self.redirects[door1_id] = reverse3_id
                    if reverse4_id != door2_id:
                        self.redirects[door2_id] = reverse4_id
                    if reverse1_id != door3_id:
                        self.redirects[door3_id] = reverse1_id
                    if reverse2_id != door4_id:
                        self.redirects[door4_id] = reverse2_id

                    break

            graph = self.build_adjacency_graph(use_redirects=True)

            if not self.is_fully_connected(graph):
                continue
            if not self.can_escape_all_areas(graph):
                continue

            # Verify bidirectionality
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
                print(f"Found valid paired randomization on attempt {attempt + 1} "
                      f"({swap_count} 4-door swaps, {len(self.redirects)} redirects)")
                return self.redirects

        print(f"Could not find valid paired randomization after {max_attempts} attempts with current seed")
        return None

    def randomize_paired_with_retry(self, max_attempts_per_seed: int = 500, max_reseeds: int = 100) -> Dict[str, str]:
        """Attempts paired mode randomization, reseeding if necessary."""
        for reseed_attempt in range(max_reseeds):
            if reseed_attempt > 0:
                new_seed = self.rng.randint(0, 2 ** 31 - 1)
                self.rng = random.Random(new_seed)
                print(f"Reseeding (attempt {reseed_attempt + 1}/{max_reseeds}) with seed {new_seed}")

            result = self.randomize_paired(max_attempts=max_attempts_per_seed)
            if result is not None:
                return result

        print(f"ERROR: Could not find valid paired randomization after {max_reseeds} reseeds!")
        print("Returning empty redirects (vanilla door layout)")
        return {}

    def randomize_with_validation(self, max_attempts: int = 100) -> Dict[str, str]:
        """Chaos mode: shuffle all randomizable doors, validate connectivity."""
        randomizable = self.get_randomizable_doors()

        for attempt in range(max_attempts):
            self.redirects = {}

            destinations = randomizable.copy()
            self.rng.shuffle(destinations)

            for source, dest in zip(randomizable, destinations):
                if source != dest:
                    self.redirects[source] = dest

            graph = self.build_adjacency_graph(use_redirects=True)
            if self.is_fully_connected(graph) and self.can_escape_all_areas(graph):
                print(f"Found valid randomization on attempt {attempt + 1}")
                return self.redirects

        print(f"Could not find valid randomization after {max_attempts} attempts")
        self.redirects = {}
        return self.redirects

    def export_redirects_for_lua(self) -> Dict[str, dict]:
        """Export redirects in Lua-compatible format."""
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
                "position": {"x": target_door.position[0], "y": target_door.position[1], "z": target_door.position[2]},
                "angle": {"x": target_door.angle[0], "y": target_door.angle[1], "z": target_door.angle[2]},
            }
        return lua_redirects

    def print_summary(self) -> None:
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
    """Main entry point for generating door randomization."""
    randomizer = DoorRandomizer(seed)
    randomizer.load_doors_from_json(door_json)
    randomizer.add_missing_doors()
    randomizer.randomize_with_validation()
    randomizer.print_summary()
    return randomizer.export_redirects_for_lua()

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
                            "position": {"x": -230.23, "y": 5.0, "z": -244.97},
                            "angle": {"x": 0.0, "y": -0.17, "z": 0.0},
                            "door_no": 0},
}

DOOR_MODE_CHAOS = 0
DOOR_MODE_PAIRED = 1


def generate_door_randomization_for_ap(random_source, mode: int = DOOR_MODE_CHAOS, use_embedded: bool = True) -> Dict[str, dict]:
    """Generate door randomization for Archipelago world generation."""
    randomizer = DoorRandomizer(seed=random_source.randint(0, 2 ** 31))

    if use_embedded:
        randomizer.load_doors_from_json({"doors": EMBEDDED_DOOR_DATA})

    randomizer.add_missing_doors()

    if mode == DOOR_MODE_PAIRED:
        randomizer.randomize_paired_with_retry(max_attempts_per_seed=500, max_reseeds=100)
    else:
        randomizer.randomize_with_validation(max_attempts=100)

    return randomizer.export_redirects_for_lua()


def generate_door_map_html(redirects: Dict[str, dict], title: str = "Door Randomization Map") -> str:
    """Generate an HTML visualization of door redirects for AP output."""
    import json

    area_colors = {
        "s200": "#FF1744", "sa00": "#FF6D00", "s135": "#FFD600", "s401": "#76FF03",
        "s136": "#00C853", "s100": "#00BFA5", "s700": "#00E5FF", "s231": "#2979FF",
        "s503": "#304FFE", "s300": "#AA00FF", "s230": "#D500F9", "s400": "#FF4081",
        "s601": "#8D6E63", "s600": "#78909C", "s500": "#FFFFFF", "s501": "#CE93D8",
        "s900": "#AED581",
    }

    short_names = {
        "s135": "Helipad", "s136": "Safe Room", "s231": "Rooftop", "s230": "Svc Hall",
        "s200": "Paradise", "s100": "Entrance", "s900": "Al Fresca", "sa00": "Food Court",
        "s300": "Wonderland", "s400": "North Plaza", "s700": "Leisure Pk", "s501": "Crislip's",
        "s503": "Colby's", "s401": "Hideout", "s600": "Tunnels", "s500": "Grocery",
        "s601": "Butcher",
    }

    all_areas = set()
    vanilla_connections = {}
    for door_id, door_data in EMBEDDED_DOOR_DATA.items():
        from_area = door_data.get("from_area_code", "")
        to_area = door_data.get("to_area_code", "")
        if from_area and to_area:
            all_areas.add(from_area)
            all_areas.add(to_area)
            if from_area not in vanilla_connections:
                vanilla_connections[from_area] = set()
            vanilla_connections[from_area].add(to_area)

    rando_connections = {}
    for door_id, redirect_info in redirects.items():
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

    nodes_data = []
    for area_code in sorted(all_areas):
        color = area_colors.get(area_code, "#CCCCCC")
        label = short_names.get(area_code, area_code)
        full_name = AREA_NAMES.get(area_code, area_code)
        border_width = 4 if area_code in PROTECTED_AREAS else 2
        border_color = "#fbbf24" if area_code == START_AREA else "#2a2d35"

        nodes_data.append({
            "id": area_code, "label": label, "title": full_name,
            "color": {"background": color, "border": border_color, "highlight": {"background": color, "border": "#fbbf24"}},
            "borderWidth": border_width, "font": {"size": 14, "face": "arial"}
        })

    edges_data = []
    processed_pairs = set()

    for from_area, to_areas_dict in rando_connections.items():
        for to_area, door_count_forward in to_areas_dict.items():
            pair_key = tuple(sorted([from_area, to_area]))
            if pair_key in processed_pairs:
                continue
            processed_pairs.add(pair_key)

            reverse_count = rando_connections.get(to_area, {}).get(from_area, 0)
            is_bidirectional = reverse_count > 0

            vanilla_dests_forward = vanilla_connections.get(from_area, set())
            vanilla_dests_reverse = vanilla_connections.get(to_area, set())
            is_new = (to_area not in vanilla_dests_forward) or (is_bidirectional and from_area not in vanilla_dests_reverse)

            color = "#22c997" if is_new else "#555"
            width = 3 if is_new else 1
            from_name = short_names.get(from_area, from_area)
            to_name = short_names.get(to_area, to_area)

            if is_bidirectional:
                arrows = {"to": {"enabled": True}, "from": {"enabled": True}}
                if door_count_forward > 1 or reverse_count > 1:
                    edge_label = str(door_count_forward) if door_count_forward == reverse_count else f"{door_count_forward}|{reverse_count}"
                else:
                    edge_label = ""
                fwd_str = f" (x{door_count_forward})" if door_count_forward > 1 else ""
                rev_str = f" (x{reverse_count})" if reverse_count > 1 else ""
                new_marker = "NEW: " if is_new else ""
                edge_title = f"{new_marker}{from_name} <-> {to_name}\n{from_name}->{to_name}{fwd_str}\n{to_name}->{from_name}{rev_str}"
            else:
                arrows = "to"
                count_str = f" (x{door_count_forward})" if door_count_forward > 1 else ""
                edge_title = f"{'NEW: ' if is_new else ''}{from_name} -> {to_name}{count_str}"
                edge_label = str(door_count_forward) if door_count_forward > 1 else ""

            edges_data.append({
                "from": from_area, "to": to_area, "arrows": arrows,
                "color": {"color": color, "highlight": "#fbbf24"},
                "width": width, "dashes": False, "title": edge_title, "label": edge_label,
                "font": {"size": 10, "color": "#FFFFFF", "strokeWidth": 2, "strokeColor": "#000000"}
            })

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
        body {{ font-family: 'Inter','Segoe UI',system-ui,sans-serif; display: flex; height: 100vh; background: #0f1117; color: #e4e4e7; }}
        #graph-container {{ flex: 1; height: 100%; background: #0f1117; }}
        #error-msg {{ color: #ef5350; padding: 20px; display: none; }}
        #sidebar {{ width: 350px; background: #161920; padding: 20px; overflow-y: auto; border-left: 1px solid #2a2d35; }}
        h1 {{ font-size: 1.3em; margin-bottom: 15px; color: #e4e4e7; font-weight: 700; }}
        h2 {{ font-size: 1em; margin: 15px 0 10px; color: #e4e4e7; background: #1e2028; padding: 6px 10px; border-radius: 6px; border: 1px solid #2a2d35; font-weight: 600; }}
        .stats {{ background: #1e2028; padding: 10px 12px; border-radius: 6px; margin-bottom: 15px; border: 1px solid #2a2d35; font-size: 0.85em; color: #8b8d98; }}
        .stats div {{ margin: 4px 0; }}
        .redirect-item {{ background: #1e2028; padding: 8px 10px; margin: 4px 0; border-radius: 6px; font-size: 0.85em; border: 1px solid transparent; }}
        .redirect-item:hover {{ border-color: #2a2d35; background: #262830; }}
        .redirect-item .orig {{ color: #ef5350; text-decoration: line-through; opacity: 0.85; }}
        .redirect-item .arrow {{ color: #5f6170; margin: 0 4px; }}
        .redirect-item .new {{ color: #4ade80; font-weight: 600; }}
        .legend {{ margin-top: 16px; padding: 10px 12px; background: #1e2028; border-radius: 6px; border: 1px solid #2a2d35; }}
        .legend-item {{ display: flex; align-items: center; margin: 5px 0; font-size: 0.85em; color: #8b8d98; }}
        .legend-color {{ width: 24px; height: 3px; margin-right: 10px; border-radius: 2px; }}
        .legend-color.new {{ background: #22c997; height: 5px; }}
        .legend-color.unchanged {{ background: #666; }}
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
            <div class="legend-item"><div class="legend-color new"></div><span>New/Changed</span></div>
            <div class="legend-item"><div class="legend-color unchanged"></div><span>Unchanged</span></div>
            <div class="legend-item"><span style="margin-left: 5px;">&lt;--&gt; Bidirectional</span></div>
        </div>
        <h2>Door Redirects</h2>
        <div id="redirect-list">{redirect_list_html}</div>
    </div>
    <script>
        try {{
            var nodes = new vis.DataSet({nodes_json});
            var edges = new vis.DataSet({edges_json});
            var container = document.getElementById("graph-container");
            var options = {{
                physics: {{ enabled: true, solver: "forceAtlas2Based", forceAtlas2Based: {{ gravitationalConstant: -100, centralGravity: 0.01, springLength: 150, springConstant: 0.08, damping: 0.4 }}, stabilization: {{ iterations: 200 }} }},
                nodes: {{ shape: "box", margin: 10, shadow: true }},
                edges: {{ smooth: {{ type: "curvedCW", roundness: 0.2 }}, shadow: true }},
                interaction: {{ hover: true, tooltipDelay: 100 }}
            }};
            var network = new vis.Network(container, {{ nodes: nodes, edges: edges }}, options);
            network.on("stabilizationIterationsDone", function() {{ network.setOptions({{ physics: {{ enabled: false }} }}); }});
        }} catch (e) {{
            document.getElementById("error-msg").style.display = "block";
            document.getElementById("error-msg").innerText = "Error: " + e.message;
        }}
    </script>
</body>
</html>'''

    return html


if __name__ == "__main__":
    import json
    import random as stdlib_random

    print("Testing with embedded door data...")

    class MockRandom:
        def randint(self, a, b):
            return stdlib_random.randint(a, b)

    result = generate_door_randomization_for_ap(MockRandom())
    print(f"\nGenerated {len(result)} door redirects")
    print("\nSample output (first 3):")
    for i, (door_id, redirect) in enumerate(list(result.items())[:3]):
        print(f"  {door_id}: -> {redirect['target_area_name']}")
