# world/drdr/__init__.py
from typing import Dict, Set, List

from BaseClasses import MultiWorld, Region, Item, Entrance, Tutorial, ItemClassification, LocationProgressType

from worlds.AutoWorld import World, WebWorld
from worlds.generic.Rules import set_rule, add_rule, add_item_rule, forbid_item

from .Items import DRItem, DRItemCategory, item_dictionary, key_item_names, item_descriptions, BuildItemPool, specialty_items
from .Locations import DRLocation, DRLocationCategory, location_tables, location_dictionary
from .Options import DROption

import re

from .DoorRandomization import generate_door_randomization_for_ap, DOOR_MODE_CHAOS, DOOR_MODE_PAIRED

# Main scoop names eligible for randomized ordering (ScoopSanity)
# These must match the scoop names in ScoopUnlocker.lua's SCOOP_DATA
# and the item names in Items.py (category SCOOP, dr_code 3000-3012)
MAIN_SCOOP_NAMES = [
    "Backup for Brad",
    "A Temporary Agreement",
    "Image in the Monitor",
    "Rescue the Professor",
    "Medicine Run",
    "Professor's Past",
    "Girl Hunting",
    "A Promise to Isabela",
    "Santa Cabeza",
    "The Last Resort",
    "Hideout",
    "Jessie's Discovery",
    "The Butcher",
]

# Maps each main scoop name to its completion event location name
# (from ScoopUnlocker.lua SCOOP_DATA completion_event fields)
SCOOP_COMPLETION_MAP = {
    # "Backup for Brad": "Complete Backup for Brad",
    "Backup for Brad": "Escort Brad to see Dr Barnaby",
    # "An Odd Old Man": "Escort Brad to see Dr Barnaby",
    "A Temporary Agreement": "Complete Temporary Agreement",
    "Image in the Monitor": "Complete Image in the Monitor",
    "Rescue the Professor": "Complete Rescue the Professor",
    "Medicine Run": "Complete Medicine Run",
    "Professor's Past": "Complete Professor's Past",
    "Girl Hunting": "Complete Girl Hunting",
    "A Promise to Isabela": "Carry Isabela back to the Safe Room",
    "Santa Cabeza": "Complete Santa Cabeza",
    "The Last Resort": "Complete Bomb Collector",
    "Hideout": "Escort Isabela to the Hideout and have a chat",
    "Jessie's Discovery": "Complete Jessie's Discovery",
    "The Butcher": "Complete The Butcher",
}

# Region(s) the player must physically reach to complete each scoop.
# Scoops in the Safe Room (always reachable) are omitted.
SCOOP_REGION_REQUIREMENTS = {
    "Backup for Brad": ["Food Court", "Entrance Plaza"],
    # "An Odd Old Man": ["Entrance Plaza"],
    "Rescue the Professor": ["Entrance Plaza"],
    "Medicine Run": ["Grocery Store"],
    "Girl Hunting": ["North Plaza"],
    "A Promise to Isabela": ["North Plaza"],
    "The Last Resort": ["Maintenance Tunnel"],
    "Hideout": ["Hideout"],
    "The Butcher": ["Maintenance Tunnel"],
}

# Level requirements for each main scoop position (0-indexed) in the shuffled order.
# Scoops at higher positions require higher levels, spreading them across spheres.
# Uses the same level thresholds as LEVEL_SPHERE_GATES.
SCOOP_POSITION_LEVEL_GATES = [
    None,  # Position 0: no level gate (accessible ASAP)
    None,  # Position 1: no level gate
    7,     # Position 2: Rooftop sphere
    10,    # Position 3: Paradise Plaza sphere
    12,    # Position 4: Leisure Park sphere
    15,    # Position 5: Food Court sphere
    16,    # Position 6: Al Fresca Plaza sphere
    17,    # Position 7: Wonderland Plaza sphere
    18,    # Position 8: North Plaza sphere
    20,    # Position 9: Entrance Plaza sphere
    20,    # Position 10: Entrance Plaza sphere
    22,    # Position 11: Maintenance Tunnel sphere
    22,    # Position 12: Maintenance Tunnel sphere
]

# Survivor scoop item names (ScoopSanity: player must receive these to spawn NPCs)
SURVIVOR_SCOOP_NAMES = [
    "Barricade Pair", "A Mother's Lament", "Japanese Tourists",
    "Shadow of the North Plaza", "Lovers", "The Coward",
    "Twin Sisters", "Restaurant Man", "Hanging by a Thread",
    "Antique Lover", "The Woman Who Didn't Make it", "Dressed for Action",
    "Gun Shop Standoff", "The Drunkard", "A Sick Man",
    "The Woman Left Behind", "A Woman in Despair",
]

# Psychopath scoop item names (ScoopSanity: player must receive these to spawn bosses)
PSYCHOPATH_SCOOP_NAMES = [
    "Cut from the Same Cloth", "Photo Challenge", "Photographer's Pride",
    "Cletus", "The Convicts", "Out of Control",
    "The Hatchet Man", "Above the Law", "A Strange Group",
    "Long Haired Punk", "Mark of the Sniper", "The Cult",
]

# Survivor counts per scoop: (total_survivors, female_survivors)
# Used by ScoopSanity logic for "Escort 8 survivors at once" and "Frank the pimp"
# Excludes Kent chain (Tad requires 3 scoops) and free survivors (Bill, Jeff, Natalie)
SCOOP_SURVIVOR_COUNTS = {
    # Survivor scoops
    "Barricade Pair": (2, 0),               # Aaron Swoop (M), Burt Thompson (M)
    "A Mother's Lament": (1, 1),            # Leah Stein (F)
    "Japanese Tourists": (2, 0),            # Yuu Tanaka (M), Shinji Kitano (M)
    "Shadow of the North Plaza": (1, 0),    # David Bailey (M)
    "Lovers": (2, 1),                       # Tonya Waters (F), Ross Folk (M)
    "The Coward": (1, 0),                   # Gordon Stalworth (M)
    "Twin Sisters": (2, 2),                 # Heather Tompkins (F), Pamela Tompkins (F)
    "Restaurant Man": (1, 0),               # Ronald Shiner (M)
    "Hanging by a Thread": (2, 1),          # Sally Mills (F), Nick Evans (M)
    "Antique Lover": (1, 0),                # Floyd Sanders (M)
    "The Woman Who Didn't Make it": (2, 2), # Jolie Wu (F), Rachel Decker (F)
    "Dressed for Action": (1, 0),           # Kindell Johnson (M)
    "Gun Shop Standoff": (3, 1),            # Brett Styles (M), Jonathan Picardson (M), Alyssa Laurent (F)
    "The Drunkard": (1, 0),                 # Gil Jiminez (M)
    "A Sick Man": (1, 0),                   # Leroy McKenna (M)
    "The Woman Left Behind": (1, 1),        # Susan Walsh (F)
    "A Woman in Despair": (1, 1),           # Simone Ravendark (F)
    # Psychopath scoops that unlock survivors
    "Above the Law": (4, 4),                # Kay Nelson (F), Lilly Deacon (F), Kelly Carpenter (F), Janet Star (F)
    "The Hatchet Man": (3, 1),              # Josh Manning (M), Barbara Patterson (F), Rich Atkins (M)
    "Long Haired Punk": (3, 2),             # Mindy Baker (F), Debbie Willet (F), Paul Carson (M)
    "A Strange Group": (5, 3),              # Beth Shrake (F), Michelle Feltz (F), Nathan Crabbe (M), Ray Mathison (M), Cheryl Jones (F)
    "The Cult": (1, 1),                     # Jennifer Gorman (F)
    "Mark of the Sniper": (1, 0),           # Wayne Blackwell (M)
    "Out of Control": (1, 0),               # Greg Simpson (M)
    "The Convicts": (1, 1),                 # Sophie Richard (F)
}

# PP Sticker groups: (count, required_regions, required_locations)
# Used by milestone rules to dynamically count how many stickers the player can reach
PP_STICKER_GROUPS = [
    (1, ["Safe Room"], []),                                                     # Sticker 97
    (14, ["Paradise Plaza"], []),                                                # Stickers 1-14
    (1, ["Rooftop"], []),                                                        # Sticker 100
    (10, ["Colby's Movie Theater", "Paradise Plaza"], []),                       # Stickers 15-24
    (4, ["Leisure Park", "Paradise Plaza"], []),                                  # Stickers 86-89
    (11, ["Food Court", "Leisure Park"], []),                                     # Stickers 46-56
    (11, ["Al Fresca Plaza", "Leisure Park", "Food Court"], []),                  # Stickers 35-45
    (15, ["Wonderland Plaza", "Leisure Park", "Food Court"], []),                 # Stickers 57-71
    (9, ["North Plaza", "Leisure Park"], []),                                     # Stickers 72-73, 76-82
    (3, ["Grocery Store", "North Plaza", "Leisure Park"], []),                    # Stickers 83-85
    (2, ["Crislip's Hardware Store", "North Plaza", "Leisure Park"], []),         # Stickers 74-75
    (10, ["Entrance Plaza"], ["Escort Brad to see Dr Barnaby"]),                  # Stickers 25-34
    (7, ["Maintenance Tunnel", "Leisure Park"], []),                              # Stickers 90-96
    (2, ["Paradise Plaza", "Leisure Park"], ["Get grabbed by the raincoats"]),    # Stickers 98-99
]

# List of all area key names for door randomizer
AREA_KEY_NAMES = [
    "Rooftop key",
    "Service Hallway key",
    "Paradise Plaza key",
    "Colby's Movie Theater key",
    "Leisure Park key",
    "North Plaza key",
    "Crislip's Hardware Store key",
    "Food Court key",
    "Wonderland Plaza key",
    "Al Fresca Plaza key",
    "Entrance Plaza key",
    "Grocery Store key",
    "Maintenance Tunnel key",
    "Hideout key",
]

TIME_KEY_NAMES = [
    "DAY2_06_AM",
    "DAY2_11_AM",
    "DAY3_00_AM",
    "DAY3_11_AM",
    "DAY4_12_PM"
]

# Locations that require waiting for in-game time to pass.
# When ScoopSanity is enabled, time is frozen, so these are unobtainable.
SCOOP_SANITY_EXCLUDED_LOCATIONS = {
    "Survive until 7pm on day 1",
    "Meet back at the Safe Room at 6am day 2",
    "Meet back at the safe room at 11am day 3",
    "Meet back at the safe room at 5pm day 3",
    "Head back to the safe room at the end of day 3",
    "Witness Special Forces 10pm day 3",
}

class DRWeb(WebWorld):
    bug_report_page = ""
    theme = "stone"
    setup_en = Tutorial(
        "Multiworld Setup Guide",
        "A guide to setting up the Archipelago Dead Rising Deluxe Remaster randomizer on your computer.",
        "English",
        "setup_en.md",
        "setup/en",
        ["Str8UpWHITE64"]
    )
    game_info_languages = ["en"]
    tutorials = [setup_en]


class DRWorld(World):
    """
    Dead Rising is a game about re-killing people and taking photos.
    """

    game: str = "Dead Rising Deluxe Remaster"
    options_dataclass = DROption
    options: DROption
    topology_present: bool = False  # Turn on when entrance randomizer is available.
    web = DRWeb()
    data_version = 0
    base_id = 1230000
    enabled_location_categories: Set[DRLocationCategory]
    enabled_hint_locations = []
    required_client_version = (0, 5, 0)
    item_name_to_id = DRItem.get_name_to_id()
    location_name_to_id = DRLocation.get_name_to_id()
    item_name_groups = {}
    item_descriptions = item_descriptions

    def __init__(self, multiworld: MultiWorld, player: int):
        super().__init__(multiworld, player)
        self.locked_items = []
        self.locked_locations = []
        self.enabled_location_categories = set()
        self.door_redirects = {}
        self.scoop_order = []

    def generate_early(self):
        self.enabled_location_categories.add(DRLocationCategory.SURVIVOR)
        self.enabled_location_categories.add(DRLocationCategory.LEVEL_UP)
        self.enabled_location_categories.add(DRLocationCategory.PP_STICKER)
        self.enabled_location_categories.add(DRLocationCategory.MAIN_SCOOP)
        if self.options.goal.value == 0:  # Ending S
            self.enabled_location_categories.add(DRLocationCategory.OVERTIME_SCOOP)
        self.enabled_location_categories.add(DRLocationCategory.PSYCHO_SCOOP)
        self.enabled_location_categories.add(DRLocationCategory.CHALLENGE)

        # If door randomizer is enabled, precollect all area keys
        if self.options.door_randomizer:
            for key_name in AREA_KEY_NAMES:
                self.multiworld.push_precollected(self.create_item(key_name))
            self.multiworld.push_precollected(self.create_item("Maintenance Tunnel Access Key"))

            # Get the door randomizer mode (0 = chaos, 1 = paired)
            door_mode = self.options.door_randomizer_mode.value

            # Generate door redirects for this player using per-slot random
            # This ensures each player gets a unique door layout even with the same server seed
            self.door_redirects = generate_door_randomization_for_ap(
                self.multiworld.per_slot_randoms[self.player],
                mode=door_mode
            )

        # If ScoopSanity is enabled, generate a randomized main scoop order and precollect all time keys
        if self.options.scoop_sanity:
            for time_key in TIME_KEY_NAMES:
                self.multiworld.push_precollected(self.create_item(time_key))
            scoop_order = list(MAIN_SCOOP_NAMES)
            self.multiworld.per_slot_randoms[self.player].shuffle(scoop_order)
            self.scoop_order = scoop_order

        # Softlock prevention
        if self.options.door_randomizer and self.options.scoop_sanity:
            self.multiworld.push_precollected(self.create_item("Out of Control"))


    def create_regions(self):
        # Create Regions
        regions: Dict[str, Region] = {}
        regions["Menu"] = self.create_region("Menu", [])
        regions.update({region_name: self.create_region(region_name, location_tables[region_name]) for region_name in [
            "Helipad",
            "Safe Room",
            "Rooftop",
            "Service Hallway",
            "Paradise Plaza",
            "Entrance Plaza",
            "Al Fresca Plaza",
            "Leisure Park",
            "Wonderland Plaza",
            "North Plaza",
            "Food Court",
            "Colby's Movie Theater",
            "Grocery Store",
            "Crislip's Hardware Store",
            "Maintenance Tunnel",
            "Hideout",
            "Tunnels",
            "Level Ups",
            "Challenges"
        ]})

        # Connect Regions
        def create_connection(from_region: str, to_region: str):
            connection = Entrance(self.player, f"{from_region} -> {to_region}", regions[from_region])
            regions[from_region].exits.append(connection)
            connection.connect(regions[to_region])
            #print(f"Connecting {from_region} to {to_region} Using entrance: " + connection.name)

        create_connection("Menu", "Helipad")
        create_connection("Helipad", "Safe Room")
        create_connection("Safe Room", "Rooftop")
        create_connection("Rooftop", "Service Hallway")
        create_connection("Service Hallway", "Paradise Plaza")

        create_connection("Paradise Plaza", "Colby's Movie Theater")
        create_connection("Paradise Plaza", "Leisure Park")

        create_connection("Al Fresca Plaza", "Entrance Plaza")
        create_connection("Food Court", "Al Fresca Plaza")
        create_connection("Food Court", "Wonderland Plaza")
        create_connection("Wonderland Plaza", "North Plaza")

        create_connection("Leisure Park", "Food Court")
        create_connection("Leisure Park", "North Plaza")
        create_connection("Leisure Park", "Maintenance Tunnel")

        create_connection("North Plaza", "Grocery Store")
        create_connection("North Plaza", "Crislip's Hardware Store")
        create_connection("North Plaza", "Hideout")

        create_connection("Hideout", "Tunnels")
        create_connection("Leisure Park", "Tunnels")

        create_connection("Menu", "Level Ups")
        create_connection("Menu", "Challenges")


    GOAL_LOCATIONS = {
        0: "Ending S: Beat up Brock with your bare fists!",   # Ending S
        1: "Ending A: Solve all of the cases and be on the helipad at 12pm",  # Ending A
    }

    # For each region, add the associated locations retrieved from the corresponding location_table
    def create_region(self, region_name, location_table) -> Region:
        new_region = Region(region_name, self.player, self.multiworld)
        goal_location_name = self.GOAL_LOCATIONS[self.options.goal.value]

        for location in location_table:
            # Skip time-wait locations when ScoopSanity is enabled (time is frozen)
            if self.options.scoop_sanity and location.name in SCOOP_SANITY_EXCLUDED_LOCATIONS:
                continue

            # Skip Ending S location entirely when goal is Ending A (overtime is removed)
            if self.options.goal.value == 1 and location.name == "Ending S: Beat up Brock with your bare fists!":
                continue

            # Goal location: create but don't place an item (Victory placed in create_items)
            if location.name == goal_location_name:
                new_location = DRLocation(
                    self.player,
                    location.name,
                    location.category,
                    location.default_item,
                    self.location_name_to_id[location.name],
                    new_region
                )
                new_region.locations.append(new_location)
            elif location.category in self.enabled_location_categories:
                new_location = DRLocation(
                    self.player,
                    location.name,
                    location.category,
                    location.default_item,
                    self.location_name_to_id[location.name],
                    new_region
                )
                new_region.locations.append(new_location)
            elif location.category == DRLocationCategory.EVENT:
                # Replace events with event items for spoiler log readability.
                event_item = self.create_item(location.default_item)
                new_location = DRLocation(
                    self.player,
                    location.name,
                    location.category,
                    location.default_item,
                    None,
                    new_region
                )
                event_item.code = None
                new_location.place_locked_item(event_item)
                new_region.locations.append(new_location)

        self.multiworld.regions.append(new_region)
        return new_region

    def create_event(self, name: str) -> DRItem:
        """Create an event item (no code/ID, progression classification)"""
        return DRItem(name, ItemClassification.progression, None, self.player)


    def create_items(self):
        itempool: List[DRItem] = []
        itempoolSize = 0
        goal_location_name = self.GOAL_LOCATIONS[self.options.goal.value]

        for location in self.multiworld.get_locations(self.player):
                item_data = item_dictionary[location.default_item_name]
                if item_data.category in [DRItemCategory.SKIP] or \
                        location.category in [DRLocationCategory.EVENT]:
                    # Skip the goal location - we handle Victory placement separately
                    if location.name == goal_location_name:
                        continue
                    item = self.create_item(location.default_item_name)
                    self.multiworld.get_location(location.name, self.player).place_locked_item(item)
                elif location.category in self.enabled_location_categories:
                    # Skip the goal location from the item pool (it gets Victory instead)
                    if location.name == goal_location_name:
                        continue
                    itempoolSize += 1

        # Place Victory event at the goal location
        self.get_location(goal_location_name).place_locked_item(self.create_item("Victory"))

        foo = BuildItemPool(self.multiworld, itempoolSize, self.options)

        for item in foo:
            itempool.append(self.create_item(item.name))

        # Add regular items to itempool
        self.multiworld.itempool += itempool



    def create_item(self, name: str) -> Item:
        useful_categories = []
        data = self.item_name_to_id[name]

        if name in key_item_names or item_dictionary[name].category in [DRItemCategory.LOCK, DRItemCategory.EVENT]:
            item_classification = ItemClassification.progression
        elif item_dictionary[name].category == DRItemCategory.SCOOP and self.options.scoop_sanity:
            item_classification = ItemClassification.progression
        elif name in specialty_items and self.options.restricted_item_mode:
            item_classification = ItemClassification.progression
        elif item_dictionary[name].category in useful_categories:
            item_classification = ItemClassification.useful
        elif item_dictionary[name].category == DRItemCategory.TRAP:
            item_classification = ItemClassification.trap
        else:
            item_classification = ItemClassification.filler

        return DRItem(name, item_classification, data, self.player)


    def get_filler_item_name(self) -> str:
        return "1 PP"

    def pre_fill(self) -> None:
        """Guarantee early key placement so the player isn't stuck in Sphere 0.

        Without this, the fill algorithm *can* legally place the Rooftop key
        (the first gate in the chain) deep in another player's world, leaving
        the Dead Rising player with only Safe Room + Level Ups for a long time.

        early_items tells the fill algorithm to prioritize placing these items
        in early spheres (ideally Sphere 0 locations) so the player always has
        something to unlock within the first few checks.
        """
        if not self.options.door_randomizer:
            # Standard key progression: make sure the first key arrives early
            self.multiworld.early_items[self.player]["Rooftop key"] = 1

        if self.options.scoop_sanity:
            # Ensure the first main scoop item arrives early so the player has something to do
            self.multiworld.early_items[self.player][self.scoop_order[0]] = 1

    def set_rules(self) -> None:

        def set_indirect_rule(self, regionName, rule):
            region = self.multiworld.get_region(regionName, self.player)
            entrance = self.multiworld.get_entrance(regionName, self.player)
            set_rule(entrance, rule)
            self.multiworld.register_indirect_condition(region, entrance)

        # ──────────────────────────────────────────────────────
        # DEFAULT RULES: Every location requires reaching its region.
        #
        # Archipelago locations inherit their region's accessibility
        # automatically, but ONLY if no explicit rule overrides it.
        # Previously we set every location to `lambda: True`, which
        # defeated the sphere system entirely — the fill algorithm
        # thought everything was Sphere 0 and had no reason to place
        # keys early.  Now each location explicitly requires its own
        # region, and more specific rules below will further tighten
        # access where needed (set_rule replaces, so later calls win).
        # ──────────────────────────────────────────────────────────
        # Regions that are always reachable from the start (no key required).
        # Locations in these regions form Sphere 0 — the fill algorithm
        # can place progression items here from the very first sweep.
        SPHERE_0_REGIONS = {"Menu", "Helipad", "Safe Room", "Level Ups", "Challenges"}

        for region in self.multiworld.get_regions(self.player):
            if region.name in SPHERE_0_REGIONS:
                # Sphere 0: accessible immediately, no items needed
                for location in region.locations:
                    set_rule(location, lambda state: True)
            else:
                # All other locations require reaching their region first.
                # This lets the fill algorithm know they are NOT Sphere 0
                # and that a key (or chain of keys) must be placed first.
                for location in region.locations:
                    set_rule(location, lambda state, r=region.name:
                             state.can_reach_region(r, self.player))

        # Level-up sphere gates: higher levels require deeper mall access
        LEVEL_SPHERE_GATES = {
            7:  "Rooftop",
            10: "Paradise Plaza",
            12: "Leisure Park",
            15: "Food Court",
            16: "Al Fresca Plaza",
            17: "Wonderland Plaza",
            18: "North Plaza",
            20: "Entrance Plaza",
            22: "Maintenance Tunnel",
        }

        current_gate = None  # None = Sphere 0, no region requirement

        for level in range(2, 51):
            # Check if this level introduces a new region gate
            if level in LEVEL_SPHERE_GATES:
                current_gate = LEVEL_SPHERE_GATES[level]

            loc = self.multiworld.get_location(f"Reach Level {level}", self.player)

            if level >= 3:
                prev = f"Reach Level {level - 1}"
                if current_gate:
                    set_rule(loc, lambda state, p=prev, g=current_gate:
                             state.can_reach_location(p, self.player) and
                             state.can_reach_region(g, self.player))
                else:
                    set_rule(loc, lambda state, p=prev:
                             state.can_reach_location(p, self.player))
            else:
                # Level 2: always accessible (Sphere 0)
                if current_gate:
                    set_rule(loc, lambda state, g=current_gate:
                             state.can_reach_region(g, self.player))
                # else: already set to True above

        if self.options.exclude_levels:
            threshold = self.options.exclude_levels_above.value

            # Only run if we're not effectively excluding nothing
            if threshold < 50:
                for location in self.multiworld.get_locations(self.player):
                    name = location.name
                    match = re.match(r"Reach Level (\d+)", name)

                    if match:
                        level_number = int(match.group(1))
                        if level_number > threshold:
                            location.progress_type = LocationProgressType.EXCLUDED

                    elif name == "Reach Level 30!":
                        if 30 > threshold:
                            location.progress_type = LocationProgressType.EXCLUDED

                    elif name == "Reach Level 40!":
                        if 40 > threshold:
                            location.progress_type = LocationProgressType.EXCLUDED

                    elif name == "Reach max level":
                        if 50 > threshold:
                            location.progress_type = LocationProgressType.EXCLUDED

        # Victory condition based on goal
        goal_location_name = self.GOAL_LOCATIONS[self.options.goal.value]
        set_rule(self.multiworld.get_location("Victory", self.player), lambda state: state.can_reach_location(goal_location_name, self.player))

        if not self.options.door_randomizer:
            # Normal key-based entrance rules
            set_rule(self.multiworld.get_entrance("Safe Room -> Rooftop", self.player), lambda state: state.has("Rooftop key", self.player))
            set_rule(self.multiworld.get_entrance("Rooftop -> Service Hallway", self.player), lambda state: state.has("Service Hallway key", self.player))
            set_rule(self.multiworld.get_entrance("Service Hallway -> Paradise Plaza", self.player), lambda state: state.has("Paradise Plaza key", self.player))
            set_rule(self.multiworld.get_entrance("Paradise Plaza -> Colby's Movie Theater", self.player), lambda state: state.has("Colby's Movie Theater key", self.player))
            set_rule(self.multiworld.get_entrance("Paradise Plaza -> Leisure Park", self.player), lambda state: state.has("Leisure Park key", self.player))
            set_rule(self.multiworld.get_entrance("Leisure Park -> Food Court", self.player), lambda state: state.has("Food Court key", self.player))
            set_rule(self.multiworld.get_entrance("Leisure Park -> North Plaza", self.player), lambda state: state.has("North Plaza key", self.player))
            set_rule(self.multiworld.get_entrance("Leisure Park -> Maintenance Tunnel", self.player), lambda state: state.has("Maintenance Tunnel key", self.player))
            set_rule(self.multiworld.get_entrance("Food Court -> Al Fresca Plaza", self.player), lambda state: state.has("Al Fresca Plaza key", self.player))
            set_rule(self.multiworld.get_entrance("Food Court -> Wonderland Plaza", self.player), lambda state: state.has("Wonderland Plaza key", self.player))
            set_rule(self.multiworld.get_entrance("Al Fresca Plaza -> Entrance Plaza", self.player), lambda state: state.has("Entrance Plaza key", self.player))
            set_rule(self.multiworld.get_entrance("Wonderland Plaza -> North Plaza", self.player), lambda state: state.has("North Plaza key", self.player))
            set_rule(self.multiworld.get_entrance("North Plaza -> Grocery Store", self.player), lambda state: state.has("Grocery Store key", self.player))
            set_rule(self.multiworld.get_entrance("North Plaza -> Hideout", self.player), lambda state: state.has("Hideout key", self.player))
            set_rule(self.multiworld.get_entrance("North Plaza -> Crislip's Hardware Store", self.player), lambda state: state.has("Crislip's Hardware Store key", self.player))

        # Events
        set_rule(self.multiworld.get_location("Meet Jessie in the Service Hallway", self.player), lambda state: state.can_reach_region("Service Hallway", self.player))

        set_rule(self.multiworld.get_location("Complete Backup for Brad", self.player), lambda state: state.can_reach_location("Meet Jessie in the Service Hallway", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Paradise Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.has("Food Court key", self.player) and (not self.options.scoop_sanity or (state.has("Backup for Brad", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.has("Entrance Plaza key", self.player))))

        set_rule(self.multiworld.get_location("Escort Brad to see Dr Barnaby", self.player), lambda state: state.can_reach_location("Complete Backup for Brad", self.player) and state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.has("Entrance Plaza key", self.player))

        set_rule(self.multiworld.get_location("Complete Temporary Agreement", self.player), lambda state: state.can_reach_location("Escort Brad to see Dr Barnaby", self.player))

        if not self.options.scoop_sanity:
            set_rule(self.multiworld.get_location("Meet back at the Safe Room at 6am day 2", self.player), lambda state: state.has("DAY2_06_AM", self.player) and state.can_reach_location("Complete Temporary Agreement", self.player))

            set_rule(self.multiworld.get_location("Complete Image in the Monitor", self.player), lambda state: state.can_reach_location("Meet back at the Safe Room at 6am day 2", self.player))

        set_rule(self.multiworld.get_location("Complete Rescue the Professor", self.player), lambda state: state.can_reach_location("Complete Image in the Monitor", self.player))

        set_rule(self.multiworld.get_location("Meet Steven", self.player), lambda state: state.can_reach_location("Complete Rescue the Professor", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Grocery Store", self.player))

        set_rule(self.multiworld.get_location("Clean up... Register 6!", self.player), lambda state: state.can_reach_location("Meet Steven", self.player))

        set_rule(self.multiworld.get_location("Complete Medicine Run", self.player), lambda state: state.can_reach_location("Clean up... Register 6!", self.player))

        set_rule(self.multiworld.get_location("Complete Professor's Past", self.player), lambda state: state.can_reach_location("Complete Medicine Run", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player))

        set_rule(self.multiworld.get_location("Complete Girl Hunting", self.player), lambda state: state.can_reach_location("Complete Professor's Past", self.player))

        set_rule(self.multiworld.get_location("Beat up Isabela", self.player), lambda state: state.can_reach_location("Complete Girl Hunting", self.player))

        set_rule(self.multiworld.get_location("Complete Promise to Isabela", self.player), lambda state: state.can_reach_location("Beat up Isabela", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player))

        set_rule(self.multiworld.get_location("Save Isabela from the zombie", self.player), lambda state: state.can_reach_location("Complete Promise to Isabela", self.player))

        set_rule(self.multiworld.get_location("Complete Transporting Isabela", self.player), lambda state: state.can_reach_location("Save Isabela from the zombie", self.player))

        set_rule(self.multiworld.get_location("Carry Isabela back to the Safe Room", self.player), lambda state: state.can_reach_location("Complete Transporting Isabela", self.player))

        set_rule(self.multiworld.get_location("Complete Santa Cabeza", self.player), lambda state: state.can_reach_location("Carry Isabela back to the Safe Room", self.player))

        if not self.options.scoop_sanity:
            set_rule(self.multiworld.get_location("Meet back at the safe room at 11am day 3", self.player), lambda state: state.can_reach_location("Complete Santa Cabeza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player))

            set_rule(self.multiworld.get_location("Complete Bomb Collector", self.player), lambda state: state.can_reach_location("Meet back at the safe room at 11am day 3", self.player) and state.can_reach_region("Maintenance Tunnel", self.player))

            set_rule(self.multiworld.get_location("Beat Drivin Carlito", self.player), lambda state: state.can_reach_location("Complete Bomb Collector", self.player) and state.can_reach_region("Maintenance Tunnel", self.player))

            set_rule(self.multiworld.get_location("Meet back at the safe room at 5pm day 3", self.player), lambda state: state.can_reach_location("Complete Bomb Collector", self.player) or state.can_reach_location("Beat Drivin Carlito", self.player))

            set_rule(self.multiworld.get_location("Escort Isabela to the Hideout and have a chat", self.player), lambda state: state.can_reach_location("Meet back at the safe room at 5pm day 3", self.player) and state.can_reach_region("Hideout", self.player))

        if self.options.scoop_sanity:
            self.multiworld.get_location("Beat Drivin Carlito", self.player).progress_type = LocationProgressType.EXCLUDED

        set_rule(self.multiworld.get_location("Complete Jessie's Discovery", self.player), lambda state: state.can_reach_location("Escort Isabela to the Hideout and have a chat", self.player))

        set_rule(self.multiworld.get_location("Meet Larry", self.player), lambda state: state.can_reach_location("Complete Jessie's Discovery", self.player))

        set_rule(self.multiworld.get_location("Complete The Butcher", self.player), lambda state: state.can_reach_location("Meet Larry", self.player))

        set_rule(self.multiworld.get_location("Complete Memories", self.player), lambda state: state.can_reach_location("Complete The Butcher", self.player))

        if not self.options.scoop_sanity:
            set_rule(self.multiworld.get_location("Head back to the safe room at the end of day 3", self.player), lambda state: state.can_reach_location("Complete Memories", self.player))

            set_rule(self.multiworld.get_location("Witness Special Forces 10pm day 3", self.player), lambda state: state.can_reach_location("Complete Memories", self.player))

        set_rule(self.multiworld.get_location("Ending A: Solve all of the cases and be on the helipad at 12pm", self.player), lambda state: state.can_reach_location("Complete Memories", self.player) and state.can_reach_region("Helipad", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.has("DAY4_12_PM", self.player))

        # Overtime rules only apply when goal is Ending S
        if self.options.goal.value == 0:
            set_rule(self.multiworld.get_location("Get bit!", self.player), lambda state: state.can_reach_location("Ending A: Solve all of the cases and be on the helipad at 12pm", self.player))

            set_rule(self.multiworld.get_location("Gather the suppressants and generator and talk to Isabela", self.player), lambda state: state.can_reach_location("Get bit!", self.player) and (state.can_reach_region("Paradise Plaza", self.player) and state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Maintenance Tunnel", self.player) and state.can_reach_region("Wonderland Plaza", self.player)))

            set_rule(self.multiworld.get_location("See the crashed helicopter", self.player), lambda state: state.can_reach_location("Get bit!", self.player))

            set_rule(self.multiworld.get_location("Frank sees a sick-ass RC Drone", self.player), lambda state: state.can_reach_location("Get bit!", self.player))

            set_rule(self.multiworld.get_location("Give Isabela 5 queens", self.player), lambda state: state.can_reach_location("Gather the suppressants and generator and talk to Isabela", self.player))

            set_rule(self.multiworld.get_location("Reach the end of the tunnel with Isabela", self.player), lambda state: state.can_reach_location("Give Isabela 5 queens", self.player))

            set_rule(self.multiworld.get_location("Get to the Humvee", self.player), lambda state: state.can_reach_location("Give Isabela 5 queens", self.player) and state.can_reach_region("Tunnels", self.player))

            set_rule(self.multiworld.get_location("Fight a tank and win", self.player), lambda state: state.can_reach_location("Get to the Humvee", self.player))

            set_rule(self.multiworld.get_location("Ending S: Beat up Brock with your bare fists!", self.player), lambda state: state.can_reach_location("Fight a tank and win", self.player))

        # ScoopSanity: Override main scoop completion rules with randomized order + item requirements + region access + level gates
        if self.options.scoop_sanity:
            for i, scoop_name in enumerate(self.scoop_order):
                completion = SCOOP_COMPLETION_MAP[scoop_name]
                loc = self.multiworld.get_location(completion, self.player)
                regions = SCOOP_REGION_REQUIREMENTS.get(scoop_name, [])
                level_req = SCOOP_POSITION_LEVEL_GATES[i] if i < len(SCOOP_POSITION_LEVEL_GATES) else None
                if i == 0:
                    set_rule(loc, lambda state, sn=scoop_name, rn=regions, lv=level_req:
                        state.has(sn, self.player) and
                        state.can_reach_location("Meet Jessie in the Service Hallway", self.player) and
                        all(state.can_reach_region(r, self.player) for r in rn) and
                        (lv is None or state.can_reach_location(f"Reach Level {lv}", self.player)))
                else:
                    prev_completion = SCOOP_COMPLETION_MAP[self.scoop_order[i - 1]]
                    set_rule(loc, lambda state, sn=scoop_name, pc=prev_completion, rn=regions, lv=level_req:
                        state.has(sn, self.player) and
                        state.can_reach_location(pc, self.player) and
                        all(state.can_reach_region(r, self.player) for r in rn) and
                        (lv is None or state.can_reach_location(f"Reach Level {lv}", self.player)))

            # Complete Memories chains to the last scoop in randomized order
            last_completion = SCOOP_COMPLETION_MAP[self.scoop_order[-1]]
            set_rule(self.multiworld.get_location("Complete Memories", self.player),
                lambda state, lc=last_completion: state.can_reach_location(lc, self.player))


        # PP Stickers
        set_rule(self.multiworld.get_location("Photograph PP Sticker 1", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 2", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 3", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 4", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 5", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 6", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 7", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 8", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 9", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 10", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 11", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 12", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 13", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 14", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 15", self.player), lambda state: state.can_reach_region("Colby's Movie Theater", self.player) and state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 16", self.player), lambda state: state.can_reach_region("Colby's Movie Theater", self.player) and state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 17", self.player), lambda state: state.can_reach_region("Colby's Movie Theater", self.player) and state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 18", self.player), lambda state: state.can_reach_region("Colby's Movie Theater", self.player) and state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 19", self.player), lambda state: state.can_reach_region("Colby's Movie Theater", self.player) and state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 20", self.player), lambda state: state.can_reach_region("Colby's Movie Theater", self.player) and state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 21", self.player), lambda state: state.can_reach_region("Colby's Movie Theater", self.player) and state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 22", self.player), lambda state: state.can_reach_region("Colby's Movie Theater", self.player) and state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 23", self.player), lambda state: state.can_reach_region("Colby's Movie Theater", self.player) and state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 24", self.player), lambda state: state.can_reach_region("Colby's Movie Theater", self.player) and state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 25", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 26", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 27", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 28", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 29", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 30", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 31", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 32", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 33", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 34", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 35", self.player), lambda state: state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 36", self.player), lambda state: state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 37", self.player), lambda state: state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 38", self.player), lambda state: state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 39", self.player), lambda state: state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 40", self.player), lambda state: state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 41", self.player), lambda state: state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 42", self.player), lambda state: state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 43", self.player), lambda state: state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 44", self.player), lambda state: state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 45", self.player), lambda state: state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 46", self.player), lambda state: state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 47", self.player), lambda state: state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 48", self.player), lambda state: state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 49", self.player), lambda state: state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 50", self.player), lambda state: state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 51", self.player), lambda state: state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 52", self.player), lambda state: state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 53", self.player), lambda state: state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 54", self.player), lambda state: state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 55", self.player), lambda state: state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 56", self.player), lambda state: state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 57", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 58", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 59", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 60", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 61", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 62", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 63", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 64", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 65", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 66", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 67", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 68", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 69", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 70", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 71", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 72", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 73", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 76", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 77", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 78", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 79", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 80", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 81", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 82", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 83", self.player), lambda state: state.can_reach_region("Grocery Store", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 84", self.player), lambda state: state.can_reach_region("Grocery Store", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 85", self.player), lambda state: state.can_reach_region("Grocery Store", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 74", self.player), lambda state: state.can_reach_region("Crislip's Hardware Store", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 75", self.player), lambda state: state.can_reach_region("Crislip's Hardware Store", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 86", self.player), lambda state: state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 87", self.player), lambda state: state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 88", self.player), lambda state: state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 89", self.player), lambda state: state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 90", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 91", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 92", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 93", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 94", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 95", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 96", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 97", self.player), lambda state: state.can_reach_region("Safe Room", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 98", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.can_reach_location("Get grabbed by the raincoats", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 99", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.can_reach_location("Get grabbed by the raincoats", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 100", self.player), lambda state: state.can_reach_region("Rooftop", self.player))

        # Survivors
        set_rule(self.multiworld.get_location("Rescue Jeff Meyer", self.player), lambda state: state.can_reach_region("Rooftop", self.player))
        set_rule(self.multiworld.get_location("Rescue Natalie Meyer", self.player), lambda state: state.can_reach_region("Rooftop", self.player))

        set_rule(self.multiworld.get_location("Rescue Heather Tompkins", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.can_reach_location("Rescue Ross Folk", self.player) and state.can_reach_location("Rescue Tonya Waters", self.player)) or (self.options.scoop_sanity and state.has("Twin Sisters", self.player))))
        set_rule(self.multiworld.get_location("Rescue Pamela Tompkins", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.can_reach_location("Rescue Ross Folk", self.player) and state.can_reach_location("Rescue Tonya Waters", self.player)) or (self.options.scoop_sanity and state.has("Twin Sisters", self.player))))
        set_rule(self.multiworld.get_location("Rescue Ronald Shiner", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and (not self.options.restricted_item_mode or state.has("Orange Juice", self.player))) or (self.options.scoop_sanity and state.has("Restaurant Man", self.player))))
        set_rule(self.multiworld.get_location("Rescue Jennifer Gorman", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player)) or (self.options.scoop_sanity and state.has("The Cult", self.player))))
        set_rule(self.multiworld.get_location("Rescue Tad Hawthorne", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.can_reach_location("Kill Kent on day 3", self.player)) or (self.options.scoop_sanity and state.has("Cut from the Same Cloth", self.player) and state.has("Photo Challenge", self.player) and state.has("Photographer's Pride", self.player))))
        set_rule(self.multiworld.get_location("Rescue Simone Ravendark", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player)) or (self.options.scoop_sanity and state.has("A Woman in Despair", self.player))))

        set_rule(self.multiworld.get_location("Rescue Sophie Richard", self.player), lambda state: state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity) or (self.options.scoop_sanity and state.has("The Convicts", self.player))))

        set_rule(self.multiworld.get_location("Rescue Gil Jiminez", self.player), lambda state: state.can_reach_region("Food Court", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player)) or (self.options.scoop_sanity and state.has("The Drunkard", self.player))))

        set_rule(self.multiworld.get_location("Rescue Aaron Swoop", self.player), lambda state: state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity) or (self.options.scoop_sanity and state.has("Barricade Pair", self.player))))
        set_rule(self.multiworld.get_location("Rescue Burt Thompson", self.player), lambda state: state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity) or (self.options.scoop_sanity and state.has("Barricade Pair", self.player))))
        set_rule(self.multiworld.get_location("Rescue Leah Stein", self.player), lambda state: state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity) or (self.options.scoop_sanity and state.has("A Mother's Lament", self.player))))
        set_rule(self.multiworld.get_location("Rescue Gordon Stalworth", self.player), lambda state: state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player)) or (self.options.scoop_sanity and state.has("The Coward", self.player))))

        set_rule(self.multiworld.get_location("Rescue Bill Brenton", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player)) or (self.options.scoop_sanity)))
        set_rule(self.multiworld.get_location("Rescue Wayne Blackwell", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.can_reach_location("Meet the Hall Family", self.player) and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player)) or (self.options.scoop_sanity and state.has("Mark of the Sniper", self.player))))
        set_rule(self.multiworld.get_location("Rescue Jolie Wu", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player)) or (self.options.scoop_sanity and state.has("The Woman Who Didn't Make it", self.player))))
        set_rule(self.multiworld.get_location("Rescue Rachel Decker", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player)) or (self.options.scoop_sanity and state.has("The Woman Who Didn't Make it", self.player))))
        set_rule(self.multiworld.get_location("Rescue Floyd Sanders", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player)) or (self.options.scoop_sanity and state.has("Antique Lover", self.player))))

        set_rule(self.multiworld.get_location("Rescue Greg Simpson", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)) and ((not self.options.scoop_sanity) or (self.options.scoop_sanity and state.has("Out of Control", self.player))))
        set_rule(self.multiworld.get_location("Rescue Yuu Tanaka", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)) and (not self.options.restricted_item_mode or state.has("Book [Japanese Conversation]", self.player)) and ((not self.options.scoop_sanity) or (self.options.scoop_sanity and state.has("Japanese Tourists", self.player))))
        set_rule(self.multiworld.get_location("Rescue Shinji Kitano", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)) and (not self.options.restricted_item_mode or state.has("Book [Japanese Conversation]", self.player)) and ((not self.options.scoop_sanity) or (self.options.scoop_sanity and state.has("Japanese Tourists", self.player))))
        set_rule(self.multiworld.get_location("Rescue Tonya Waters", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player)) or (self.options.scoop_sanity and state.has("Lovers", self.player))))
        set_rule(self.multiworld.get_location("Rescue Ross Folk", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player)) or (self.options.scoop_sanity and state.has("Lovers", self.player))))
        set_rule(self.multiworld.get_location("Rescue Kay Nelson", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.can_reach_location("Kill Jo", self.player)) or (self.options.scoop_sanity and state.has("Above the Law", self.player))))
        set_rule(self.multiworld.get_location("Rescue Lilly Deacon", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.can_reach_location("Kill Jo", self.player)) or (self.options.scoop_sanity and state.has("Above the Law", self.player))))
        set_rule(self.multiworld.get_location("Rescue Kelly Carpenter", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.can_reach_location("Kill Jo", self.player)) or (self.options.scoop_sanity and state.has("Above the Law", self.player))))
        set_rule(self.multiworld.get_location("Rescue Janet Star", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.can_reach_location("Kill Jo", self.player)) or (self.options.scoop_sanity and state.has("Above the Law", self.player))))
        set_rule(self.multiworld.get_location("Rescue Sally Mills", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player)) or (self.options.scoop_sanity and state.has("Hanging by a Thread", self.player))))
        set_rule(self.multiworld.get_location("Rescue Nick Evans", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player)) or (self.options.scoop_sanity and state.has("Hanging by a Thread", self.player))))
        set_rule(self.multiworld.get_location("Rescue Mindy Baker", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.can_reach_location("Defeat Paul", self.player)) or (self.options.scoop_sanity and state.has("Long Haired Punk", self.player))))
        set_rule(self.multiworld.get_location("Rescue Debbie Willet", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.can_reach_location("Defeat Paul", self.player)) or (self.options.scoop_sanity and state.has("Long Haired Punk", self.player))))
        set_rule(self.multiworld.get_location("Rescue Paul Carson", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and (not self.options.restricted_item_mode or state.has("Fire Extinguisher", self.player)) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.can_reach_location("Defeat Paul", self.player)) or (self.options.scoop_sanity and state.can_reach_region("Leisure Park", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)) and state.has("Long Haired Punk", self.player))))
        set_rule(self.multiworld.get_location("Rescue Leroy McKenna", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player)) or (self.options.scoop_sanity and state.can_reach_region("Leisure Park", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)) and state.has("A Sick Man", self.player))))
        set_rule(self.multiworld.get_location("Rescue Susan Walsh", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player)) or (self.options.scoop_sanity and state.can_reach_region("Leisure Park", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)) and state.has("The Woman Left Behind", self.player))))

        set_rule(self.multiworld.get_location("Rescue David Bailey", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity) or (self.options.scoop_sanity and state.has("Shadow of the North Plaza", self.player))))
        set_rule(self.multiworld.get_location("Rescue Josh Manning", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.can_reach_location("Kill Cliff", self.player)) or (self.options.scoop_sanity and state.has("The Hatchet Man", self.player))))
        set_rule(self.multiworld.get_location("Rescue Barbara Patterson", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.can_reach_location("Kill Cliff", self.player)) or (self.options.scoop_sanity and state.has("The Hatchet Man", self.player))))
        set_rule(self.multiworld.get_location("Rescue Rich Atkins", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.can_reach_location("Kill Cliff", self.player)) or (self.options.scoop_sanity and state.has("The Hatchet Man", self.player))))
        set_rule(self.multiworld.get_location("Rescue Kindell Johnson", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player)) or (self.options.scoop_sanity and state.has("Dressed for Action", self.player))))
        set_rule(self.multiworld.get_location("Rescue Brett Styles", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player)) or (self.options.scoop_sanity and state.has("Gun Shop Standoff", self.player))))
        set_rule(self.multiworld.get_location("Rescue Jonathan Picardson", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player)) or (self.options.scoop_sanity and state.has("Gun Shop Standoff", self.player))))
        set_rule(self.multiworld.get_location("Rescue Alyssa Laurent", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player)) or (self.options.scoop_sanity and state.has("Gun Shop Standoff", self.player))))

        set_rule(self.multiworld.get_location("Rescue Beth Shrake", self.player), lambda state: state.can_reach_region("Colby's Movie Theater", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.can_reach_location("Kill Sean", self.player)) or (self.options.scoop_sanity and state.has("A Strange Group", self.player))))
        set_rule(self.multiworld.get_location("Rescue Michelle Feltz", self.player), lambda state: state.can_reach_region("Colby's Movie Theater", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.can_reach_location("Kill Sean", self.player)) or (self.options.scoop_sanity and state.has("A Strange Group", self.player))))
        set_rule(self.multiworld.get_location("Rescue Nathan Crabbe", self.player), lambda state: state.can_reach_region("Colby's Movie Theater", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.can_reach_location("Kill Sean", self.player)) or (self.options.scoop_sanity and state.has("A Strange Group", self.player))))
        set_rule(self.multiworld.get_location("Rescue Ray Mathison", self.player), lambda state: state.can_reach_region("Colby's Movie Theater", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.can_reach_location("Kill Sean", self.player)) or (self.options.scoop_sanity and state.has("A Strange Group", self.player))))
        set_rule(self.multiworld.get_location("Rescue Cheryl Jones", self.player), lambda state: state.can_reach_region("Colby's Movie Theater", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.can_reach_location("Kill Sean", self.player)) or (self.options.scoop_sanity and state.has("A Strange Group", self.player))))

        # Psychopaths
        set_rule(self.multiworld.get_location("Watch the convicts kill that poor guy", self.player), lambda state: state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity) or (self.options.scoop_sanity and state.has("The Convicts", self.player))))

        set_rule(self.multiworld.get_location("Meet Cletus", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity) or (self.options.scoop_sanity and state.has("Cletus", self.player))))
        set_rule(self.multiworld.get_location("Kill Cletus", self.player), lambda state: state.can_reach_location("Meet Cletus", self.player))

        set_rule(self.multiworld.get_location("Meet Adam", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and ((not self.options.scoop_sanity) or (self.options.scoop_sanity and state.has("Out of Control", self.player))))
        set_rule(self.multiworld.get_location("Kill Adam", self.player), lambda state: state.can_reach_location("Meet Adam", self.player))

        set_rule(self.multiworld.get_location("Meet Cliff", self.player), lambda state: state.can_reach_region("Crislip's Hardware Store", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player)) or (self.options.scoop_sanity and state.has("The Hatchet Man", self.player))))
        set_rule(self.multiworld.get_location("Kill Cliff", self.player), lambda state: state.can_reach_location("Meet Cliff", self.player))

        set_rule(self.multiworld.get_location("Meet Jo", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player)) or (self.options.scoop_sanity and state.has("Above the Law", self.player))))
        set_rule(self.multiworld.get_location("Kill Jo", self.player), lambda state: state.can_reach_location("Meet Jo", self.player))

        set_rule(self.multiworld.get_location("Meet the Hall Family", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player)) or (self.options.scoop_sanity and state.has("Mark of the Sniper", self.player))))
        set_rule(self.multiworld.get_location("Kill Roger and Jack (and Thomas if you want) and chat with Wayne", self.player), lambda state: state.can_reach_location("Meet the Hall Family", self.player))

        set_rule(self.multiworld.get_location("Witness Sean in Paradise Plaza", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player)) or (self.options.scoop_sanity and (state.has("The Cult", self.player)) or (state.has("A Strange Group", self.player)))))
        set_rule(self.multiworld.get_location("Get grabbed by the raincoats", self.player), lambda state: state.can_reach_location("Witness Sean in Paradise Plaza", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Meet Sean", self.player), lambda state: state.can_reach_region("Colby's Movie Theater", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player)) or (self.options.scoop_sanity and state.has("A Strange Group", self.player))))
        set_rule(self.multiworld.get_location("Kill Sean", self.player), lambda state: state.can_reach_location("Meet Sean", self.player))

        set_rule(self.multiworld.get_location("Meet Paul", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player)) or (self.options.scoop_sanity and state.has("Long Haired Punk", self.player))))
        set_rule(self.multiworld.get_location("Defeat Paul", self.player), lambda state: state.can_reach_location("Meet Paul", self.player))

        set_rule(self.multiworld.get_location("Meet Kent on day 1", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and ((not self.options.scoop_sanity) or (self.options.scoop_sanity and state.has("Cut from the Same Cloth", self.player))))
        set_rule(self.multiworld.get_location("Complete Kent's day 1 photoshoot", self.player), lambda state: state.can_reach_location("Meet Kent on day 1", self.player))
        set_rule(self.multiworld.get_location("Meet Kent on day 2", self.player), lambda state: state.can_reach_location("Complete Kent's day 1 photoshoot", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player)) or (self.options.scoop_sanity and state.has("Cut from the Same Cloth", self.player) and state.has("Photo Challenge", self.player))))
        set_rule(self.multiworld.get_location("Complete Kent's day 2 photoshoot", self.player), lambda state: state.can_reach_location("Meet Kent on day 2", self.player))
        set_rule(self.multiworld.get_location("Meet Kent on day 3", self.player), lambda state: state.can_reach_location("Complete Kent's day 2 photoshoot", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player)) or (self.options.scoop_sanity and state.has("Cut from the Same Cloth", self.player) and state.has("Photo Challenge", self.player) and state.has("Photographer's Pride", self.player))))
        set_rule(self.multiworld.get_location("Kill Kent on day 3", self.player), lambda state: state.can_reach_location("Meet Kent on day 3", self.player))

        # Challenges
        set_rule(self.multiworld.get_location("Reach Level 10!", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Reach Level 20!", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Reach Level 30!", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("North Plaza", self.player))
        set_rule(self.multiworld.get_location("Reach Level 40!", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Maintenance Tunnel", self.player) and state.can_reach_location("Ending A: Solve all of the cases and be on the helipad at 12pm", self.player))
        set_rule(self.multiworld.get_location("Reach max level", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Maintenance Tunnel", self.player) and state.can_reach_location("Ending A: Solve all of the cases and be on the helipad at 12pm", self.player))
        set_rule(self.multiworld.get_location("Kill 500 zombies by vehicle", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player))
        set_rule(self.multiworld.get_location("Kill 1000 zombies by vehicle", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player))
        all_side_scoops = SURVIVOR_SCOOP_NAMES + PSYCHOPATH_SCOOP_NAMES
        set_rule(self.multiworld.get_location("Get 50 survivors to join", self.player), lambda state, scoops=all_side_scoops: state.can_reach_region("Paradise Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.can_reach_location("Kill Kent on day 3", self.player) and state.can_reach_location("Kill Cliff", self.player) and state.can_reach_location("Kill Jo", self.player) and state.can_reach_location("Kill Adam", self.player) and state.can_reach_location("Kill Sean", self.player) and state.can_reach_location("Kill Roger and Jack (and Thomas if you want) and chat with Wayne", self.player) and state.can_reach_location("Defeat Paul", self.player) and ((not self.options.scoop_sanity) or (self.options.scoop_sanity and state.has_all(scoops, self.player) and state.can_reach_location("Ending A: Solve all of the cases and be on the helipad at 12pm", self.player))))
        set_rule(self.multiworld.get_location("Encounter 10 survivors", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.can_reach_location("Kill Kent on day 3", self.player) and state.can_reach_location("Kill Cliff", self.player) and state.can_reach_location("Kill Jo", self.player) and state.can_reach_location("Kill Adam", self.player) and state.can_reach_location("Kill Sean", self.player) and state.can_reach_location("Kill Roger and Jack (and Thomas if you want) and chat with Wayne", self.player) and state.can_reach_location("Defeat Paul", self.player))
        set_rule(self.multiworld.get_location("Encounter 50 survivors", self.player), lambda state, scoops=all_side_scoops: state.can_reach_region("Paradise Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.can_reach_location("Kill Kent on day 3", self.player) and state.can_reach_location("Kill Cliff", self.player) and state.can_reach_location("Kill Jo", self.player) and state.can_reach_location("Kill Adam", self.player) and state.can_reach_location("Kill Sean", self.player) and state.can_reach_location("Kill Roger and Jack (and Thomas if you want) and chat with Wayne", self.player) and state.can_reach_location("Defeat Paul", self.player) and ((not self.options.scoop_sanity) or (self.options.scoop_sanity and state.has_all(scoops, self.player) and state.can_reach_location("Ending A: Solve all of the cases and be on the helipad at 12pm", self.player))))
        set_rule(self.multiworld.get_location("Save 10 survivors", self.player), lambda state, scoops=all_side_scoops: state.can_reach_region("Paradise Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.has("DAY4_12_PM", self.player) and state.can_reach_location("Kill Kent on day 3", self.player) and state.can_reach_location("Kill Cliff", self.player) and state.can_reach_location("Kill Jo", self.player) and state.can_reach_location("Kill Adam", self.player) and state.can_reach_location("Kill Sean", self.player) and state.can_reach_location("Kill Roger and Jack (and Thomas if you want) and chat with Wayne", self.player) and state.can_reach_location("Defeat Paul", self.player) and ((not self.options.scoop_sanity) or (self.options.scoop_sanity and state.has_all(scoops, self.player) and state.can_reach_location("Ending A: Solve all of the cases and be on the helipad at 12pm", self.player))))
        set_rule(self.multiworld.get_location("Save 50 survivors", self.player), lambda state, scoops=all_side_scoops: state.can_reach_region("Paradise Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.has("DAY4_12_PM", self.player) and state.can_reach_location("Kill Kent on day 3", self.player) and state.can_reach_location("Kill Cliff", self.player) and state.can_reach_location("Kill Jo", self.player) and state.can_reach_location("Kill Adam", self.player) and state.can_reach_location("Kill Sean", self.player) and state.can_reach_location("Kill Roger and Jack (and Thomas if you want) and chat with Wayne", self.player) and state.can_reach_location("Defeat Paul", self.player) and ((not self.options.scoop_sanity) or (self.options.scoop_sanity and state.has_all(scoops, self.player) and state.can_reach_location("Ending A: Solve all of the cases and be on the helipad at 12pm", self.player))))


        set_rule(self.multiworld.get_location("Kill 1000 zombies", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player))
        set_rule(self.multiworld.get_location("Kill 2000 zombies", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Entrance Plaza", self.player))
        set_rule(self.multiworld.get_location("Kill 5000 zombies", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player))
        set_rule(self.multiworld.get_location("Kill 10000 zombies", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_location("Ending A: Solve all of the cases and be on the helipad at 12pm", self.player))
        set_rule(self.multiworld.get_location("Walk a quarter marathon", self.player), lambda state: state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Paradise Plaza", self.player) and state.can_reach_region("Grocery Store", self.player) and state.can_reach_region("Crislip's Hardware Store", self.player) and state.can_reach_region("Colby's Movie Theater", self.player))
        if self.options.goal.value == 0:  # Ending S — overtime locations exist
            set_rule(self.multiworld.get_location("Kill 10 Special Forces", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and state.has("DAY3_11_AM", self.player) and state.can_reach_location("Get bit!", self.player) and state.can_reach_location("Ending A: Solve all of the cases and be on the helipad at 12pm", self.player))
        set_rule(self.multiworld.get_location("Destroy all of the wall plates in the Food Court", self.player), lambda state: state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Kill 1 psychopath", self.player), lambda state: state.can_reach_location("Meet Cletus", self.player) or state.can_reach_location("Meet Adam", self.player) or state.can_reach_location("Meet Sean", self.player) or state.can_reach_location("Meet Jo", self.player) or state.can_reach_location("Meet Cliff", self.player) or state.can_reach_location("Meet Paul", self.player) or state.can_reach_location("Meet Steven", self.player) or state.can_reach_location("Meet Larry", self.player) or state.can_reach_location("Meet Kent on day 3", self.player))
        set_rule(self.multiworld.get_location("Photograph 8 psychopaths", self.player), lambda state: state.can_reach_location("Meet Cletus", self.player) and state.can_reach_location("Meet Adam", self.player) and state.can_reach_location("Meet Sean", self.player) and state.can_reach_location("Meet Jo", self.player) or state.can_reach_location("Meet Cliff", self.player) and state.can_reach_location("Meet Paul", self.player) or state.can_reach_location("Meet Steven", self.player) and state.can_reach_location("Meet Larry", self.player) and state.can_reach_location("Meet Kent on day 3", self.player) and state.can_reach_location("Kill Roger and Jack (and Thomas if you want) and chat with Wayne", self.player))
        set_rule(self.multiworld.get_location("Kill 8 psychopaths", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.can_reach_location("Kill Kent on day 3", self.player) and state.can_reach_location("Kill Cliff", self.player) and state.can_reach_location("Kill Jo", self.player) and state.can_reach_location("Kill Adam", self.player) and state.can_reach_location("Kill Sean", self.player) and state.can_reach_location("Kill Roger and Jack (and Thomas if you want) and chat with Wayne", self.player) and state.can_reach_location("Defeat Paul", self.player))
        set_rule(self.multiworld.get_location("Hit 10 zombies with a parasol", self.player), lambda state: (state.can_reach_region("Entrance Plaza", self.player) or state.can_reach_region("Al Fresca Plaza", self.player)) and (not self.options.restricted_item_mode or state.has("Parasol", self.player)))
        set_rule(self.multiworld.get_location("Kill 50 cultists", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and state.can_reach_location("Witness Sean in Paradise Plaza", self.player))
        if self.options.goal.value == 0:  # Ending S — overtime locations exist
            set_rule(self.multiworld.get_location("Kill 100 zombies with an RPG", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player) and state.can_reach_location("Get bit!", self.player))
        set_rule(self.multiworld.get_location("Photograph 30 survivors", self.player), lambda state: state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Entrance Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player))
        set_rule(self.multiworld.get_location("Escort 8 survivors at once", self.player), lambda state, counts=SCOOP_SURVIVOR_COUNTS: state.can_reach_region("Paradise Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_location("Kill Jo", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Entrance Plaza", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player)) or (self.options.scoop_sanity and sum(c[0] for s, c in counts.items() if state.has(s, self.player)) >= 8)))
        set_rule(self.multiworld.get_location("Frank the pimp", self.player), lambda state, counts=SCOOP_SURVIVOR_COUNTS: state.can_reach_region("Paradise Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_location("Kill Jo", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Entrance Plaza", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player)) or (self.options.scoop_sanity and sum(c[1] for s, c in counts.items() if state.has(s, self.player)) >= 8)))
        set_rule(self.multiworld.get_location("Jump a vehicle 50 feet", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player))
        set_rule(self.multiworld.get_location("Bowl over 5 zombies", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and (not self.options.restricted_item_mode or state.has("Bowling Ball", self.player)))
        set_rule(self.multiworld.get_location("Hit a golf ball 100 feet", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and (not self.options.restricted_item_mode or state.has("Golf Club", self.player)))
        set_rule(self.multiworld.get_location("Fire 30 bullets", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and (not self.options.restricted_item_mode or state.has("Handgun", self.player)))
        set_rule(self.multiworld.get_location("Fire 300 bullets", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and (not self.options.restricted_item_mode or state.has("Handgun", self.player)))
        set_rule(self.multiworld.get_location("Ride zombies for 50 feet", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player))
        set_rule(self.multiworld.get_location("Change into 46 new outfits", self.player), lambda state: state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Paradise Plaza", self.player) and state.can_reach_region("Grocery Store", self.player) and state.can_reach_region("Crislip's Hardware Store", self.player) and state.can_reach_region("Colby's Movie Theater", self.player))
        set_rule(self.multiworld.get_location("Change into 5 new outfits", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph 10 PP Stickers", self.player), lambda state, groups=PP_STICKER_GROUPS: sum(g[0] for g in groups if all(state.can_reach_region(r, self.player) for r in g[1]) and all(state.can_reach_location(l, self.player) for l in g[2])) >= 10)
        set_rule(self.multiworld.get_location("Photograph 20 PP Stickers", self.player), lambda state, groups=PP_STICKER_GROUPS: sum(g[0] for g in groups if all(state.can_reach_region(r, self.player) for r in g[1]) and all(state.can_reach_location(l, self.player) for l in g[2])) >= 20)
        set_rule(self.multiworld.get_location("Photograph 30 PP Stickers", self.player), lambda state, groups=PP_STICKER_GROUPS: sum(g[0] for g in groups if all(state.can_reach_region(r, self.player) for r in g[1]) and all(state.can_reach_location(l, self.player) for l in g[2])) >= 30)
        set_rule(self.multiworld.get_location("Photograph 40 PP Stickers", self.player), lambda state, groups=PP_STICKER_GROUPS: sum(g[0] for g in groups if all(state.can_reach_region(r, self.player) for r in g[1]) and all(state.can_reach_location(l, self.player) for l in g[2])) >= 40)
        set_rule(self.multiworld.get_location("Photograph 50 PP Stickers", self.player), lambda state, groups=PP_STICKER_GROUPS: sum(g[0] for g in groups if all(state.can_reach_region(r, self.player) for r in g[1]) and all(state.can_reach_location(l, self.player) for l in g[2])) >= 50)
        set_rule(self.multiworld.get_location("Photograph 60 PP Stickers", self.player), lambda state, groups=PP_STICKER_GROUPS: sum(g[0] for g in groups if all(state.can_reach_region(r, self.player) for r in g[1]) and all(state.can_reach_location(l, self.player) for l in g[2])) >= 60)
        set_rule(self.multiworld.get_location("Photograph 70 PP Stickers", self.player), lambda state, groups=PP_STICKER_GROUPS: sum(g[0] for g in groups if all(state.can_reach_region(r, self.player) for r in g[1]) and all(state.can_reach_location(l, self.player) for l in g[2])) >= 70)
        set_rule(self.multiworld.get_location("Photograph 80 PP Stickers", self.player), lambda state, groups=PP_STICKER_GROUPS: sum(g[0] for g in groups if all(state.can_reach_region(r, self.player) for r in g[1]) and all(state.can_reach_location(l, self.player) for l in g[2])) >= 80)
        set_rule(self.multiworld.get_location("Photograph 90 PP Stickers", self.player), lambda state, groups=PP_STICKER_GROUPS: sum(g[0] for g in groups if all(state.can_reach_region(r, self.player) for r in g[1]) and all(state.can_reach_location(l, self.player) for l in g[2])) >= 90)
        set_rule(self.multiworld.get_location("Photograph all PP Stickers", self.player), lambda state, groups=PP_STICKER_GROUPS: sum(g[0] for g in groups if all(state.can_reach_region(r, self.player) for r in g[1]) and all(state.can_reach_location(l, self.player) for l in g[2])) >= 100)
        set_rule(self.multiworld.get_location("Get 10000 PP in one photo", self.player), lambda state: state.can_reach_region("Rooftop", self.player))

        set_rule(self.multiworld.get_location("Find Greg's secret passage", self.player), lambda state: state.can_reach_location("Kill Adam", self.player))
        # Endings
        # set_rule(self.multiworld.get_location("Ending B: Don't solve all of the cases but be on the helipad at 12pm", self.player), lambda state: state.can_reach_region("Helipad", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.has("DAY4_12_PM", self.player) and state.can_reach_location("Ending S: Beat up Brock with your bare fists!", self.player))
        # set_rule(self.multiworld.get_location("Ending C: Solve all of the cases but don't meet Isabela at 10am", self.player), lambda state: state.can_reach_location("Complete Memories", self.player) and state.can_reach_region("Helipad", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.has("DAY4_12_PM", self.player) and state.can_reach_location("Ending S: Beat up Brock with your bare fists!", self.player))
        # set_rule(self.multiworld.get_location("Ending D: Be a prisoner when time runs out", self.player), lambda state: state.can_reach_location("Witness Special Forces 10pm day 3", self.player) and state.can_reach_region("Helipad", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.has("DAY4_12_PM", self.player) and state.can_reach_location("Ending S: Beat up Brock with your bare fists!", self.player))
        # set_rule(self.multiworld.get_location("Ending E: Don't solve all of the cases and don't be on the helipad at 12pm", self.player), lambda state: state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.has("DAY4_12_PM", self.player) and state.can_reach_location("Complete Backup for Brad", self.player) and state.can_reach_location("Ending S: Beat up Brock with your bare fists!", self.player))
        # set_rule(self.multiworld.get_location("Ending F: Fail to collect all of the bombs in time", self.player), lambda state: state.can_reach_location("Complete Bomb Collector", self.player))

        if not self.options.scoop_sanity:
            set_rule(self.multiworld.get_location("Survive until 7pm on day 1", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player))

        # Victory Condition
        self.multiworld.completion_condition[self.player] = lambda state: state.has("Victory", self.player)


    def fill_slot_data(self) -> Dict[str, object]:
        slot_data: Dict[str, object] = {}

        name_to_dr_code = {item.name: item.dr_code for item in item_dictionary.values()}
        items_id = []
        items_address = []
        locations_id = []
        locations_address = []
        locations_target = []
        hints = {}

        for location in self.multiworld.get_filled_locations():
            if location.item.player == self.player:
                items_id.append(location.item.code)
                items_address.append(name_to_dr_code[location.item.name])

            if location.player == self.player:
                locations_address.append(item_dictionary[location_dictionary[location.name].default_item].dr_code)
                locations_id.append(location.address)
                if location.item.player == self.player:
                    locations_target.append(name_to_dr_code[location.item.name])
                else:
                    locations_target.append(0)

        goal = self.options.goal.value  # 0 = Ending S, 1 = Ending A
        death_link_enabled = bool(self.options.death_link.value)
        restricted_item_mode_enabled = bool(self.options.restricted_item_mode.value)
        door_randomizer_enabled = bool(self.options.door_randomizer.value)
        door_randomizer_mode = self.options.door_randomizer_mode.value
        scoop_sanity_enabled = bool(self.options.scoop_sanity.value)
        exclude_levels_enabled = bool(self.options.exclude_levels.value)

        slot_data = {
            "options": {
                "goal": goal,
                "guaranteed_items": self.options.guaranteed_items.value,
                "death_link": death_link_enabled,
                "restricted_item_mode": restricted_item_mode_enabled,
                "door_randomizer": door_randomizer_enabled,
                "door_randomizer_mode": door_randomizer_mode,
                "scoop_sanity": scoop_sanity_enabled,
                "exclude_levels": exclude_levels_enabled,
                "exclude_levels_above": self.options.exclude_levels_above.value,
            },
            "goal": goal,
            "death_link": death_link_enabled,
            "restricted_item_mode": restricted_item_mode_enabled,
            "door_randomizer": door_randomizer_enabled,
            "door_randomizer_mode": door_randomizer_mode,  # For Lua: 0 = chaos, 1 = paired
            "door_redirects": self.door_redirects if door_randomizer_enabled else {},
            "scoop_sanity": scoop_sanity_enabled,
            "exclude_levels": exclude_levels_enabled,
            "scoop_order": self.scoop_order if scoop_sanity_enabled else {},
            "hints": hints,
            "seed": self.multiworld.seed_name,
            "slot": self.multiworld.player_name[self.player],
            "base_id": self.base_id,
            "locationsId": locations_id,
            "locationsAddress": locations_address,
            "locationsTarget": locations_target,
            "itemsId": items_id,
            "itemsAddress": items_address
        }

        return slot_data

    def write_spoiler(self, spoiler_handle) -> None:
        if self.options.scoop_sanity:
            player_name = self.multiworld.get_player_name(self.player)
            spoiler_handle.write(f"\nScoopSanity Main Scoop Order ({player_name}):\n")
            for i, scoop_name in enumerate(self.scoop_order):
                spoiler_handle.write(f"  {i + 1}. {scoop_name}\n")

    def generate_output(self, output_directory: str) -> None:
        # Door map HTML is now generated on-demand by the Lua-side DoorVisualizer
        pass