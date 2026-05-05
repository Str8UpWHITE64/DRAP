# world/drdr/__init__.py
from typing import Any, Dict, Set, List

from BaseClasses import MultiWorld, Region, Item, Entrance, Tutorial, ItemClassification, LocationProgressType

from worlds.AutoWorld import World, WebWorld
from worlds.generic.Rules import set_rule, add_rule, add_item_rule, forbid_item

from .Items import DRItem, DRItemCategory, item_dictionary, key_item_names, item_descriptions, BuildItemPool, specialty_items, progression_skills
from .Locations import DRLocation, DRLocationCategory, location_tables, location_dictionary
from .Options import DROption

import re

from .DoorRandomization import generate_door_randomization_for_ap, DOOR_MODE_CHAOS, DOOR_MODE_PAIRED, AREA_NAMES
from .shared_data import (
    AREA_KEY_NAMES, TIME_KEY_NAMES,
    AP_TRIGGER_LOCATIONS, expand_trigger_location_names,
    trigger_location_required_regions,
)

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
    "Carlito's Hideout",
    "Jessie's Discovery",
    "The Butcher",
]

# Maps each main scoop name to its completion event location name
# (from ScoopUnlocker.lua SCOOP_DATA completion_event fields)
SCOOP_COMPLETION_MAP = {
    "Backup for Brad": "Escort Brad to see Dr Barnaby",
    "A Temporary Agreement": "Complete Temporary Agreement",
    "Image in the Monitor": "Complete Image in the Monitor",
    "Rescue the Professor": "Complete Rescue the Professor",
    "Medicine Run": "Complete Medicine Run",
    "Professor's Past": "Complete Professor's Past",
    "Girl Hunting": "Beat up Isabela",
    "A Promise to Isabela": "Carry Isabela back to the Security Room",
    "Santa Cabeza": "Complete Santa Cabeza",
    "The Last Resort": "Complete Bomb Collector",
    "Carlito's Hideout": "Escort Isabela to Carlito's Hideout and have a chat",
    "Jessie's Discovery": "Complete Jessie's Discovery",
    "The Butcher": "Complete The Butcher",
}

# Ordered event chain per scoop (first event -> completion). Drives the
# ScoopSanity per-event override loop in set_rules; the last entry of each
# list must equal SCOOP_COMPLETION_MAP[scoop].
SCOOP_EVENTS = {
    "Backup for Brad": [
        "Complete Backup for Brad",
        "Escort Brad to see Dr Barnaby",
    ],
    "A Temporary Agreement": [
        "Complete Temporary Agreement",
    ],
    "Image in the Monitor": [
        "Complete Image in the Monitor",
    ],
    "Rescue the Professor": [
        "Complete Rescue the Professor",
    ],
    "Medicine Run": [
        "Meet Steven",
        "Clean up... Register 6!",
        "Complete Medicine Run",
    ],
    "Professor's Past": [
        "Complete Professor's Past",
    ],
    "Girl Hunting": [
        "Complete Girl Hunting",
        "Beat up Isabela",
    ],
    "A Promise to Isabela": [
        "Complete Promise to Isabela",
        "Save Isabela from the zombie",
        "Complete Transporting Isabela",
        "Carry Isabela back to the Security Room",
    ],
    "Santa Cabeza": [
        "Complete Santa Cabeza",
    ],
    "The Last Resort": [
        "Complete Bomb Collector",
    ],
    "Carlito's Hideout": [
        "Escort Isabela to Carlito's Hideout and have a chat",
    ],
    "Jessie's Discovery": [
        "Complete Jessie's Discovery",
    ],
    "The Butcher": [
        "Meet Larry",
        "Complete The Butcher",
    ],
}

# Region(s) the player must physically reach to complete each scoop.
# Scoops in the Security Room (always reachable) are omitted.
SCOOP_REGION_REQUIREMENTS = {
    "Backup for Brad": ["Food Court", "Entrance Plaza"],
    "Rescue the Professor": ["Entrance Plaza"],
    "Medicine Run": ["Seon's Food and Stuff"],
    "Girl Hunting": ["North Plaza"],
    "A Promise to Isabela": ["North Plaza"],
    "The Last Resort": ["Maintenance Tunnel"],
    "Carlito's Hideout": ["Carlito's Hideout"],
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
    (1, ["Security Room"], []),                                                     # Sticker 97
    (14, ["Paradise Plaza"], []),                                                # Stickers 1-14
    (1, ["Rooftop"], []),                                                        # Sticker 100
    (10, ["Colby's Movieland", "Paradise Plaza"], []),                       # Stickers 15-24
    (4, ["Leisure Park", "Paradise Plaza"], []),                                  # Stickers 86-89
    (11, ["Food Court", "Leisure Park"], []),                                     # Stickers 46-56
    (11, ["Al Fresca Plaza", "Leisure Park", "Food Court"], []),                  # Stickers 35-45
    (15, ["Wonderland Plaza", "Leisure Park", "Food Court"], []),                 # Stickers 57-71
    (9, ["North Plaza", "Leisure Park"], []),                                     # Stickers 72-73, 76-82
    (3, ["Seon's Food and Stuff", "North Plaza", "Leisure Park"], []),                    # Stickers 83-85
    (2, ["Crislip's Home Saloon", "North Plaza", "Leisure Park"], []),         # Stickers 74-75
    (10, ["Entrance Plaza"], ["Escort Brad to see Dr Barnaby"]),                  # Stickers 25-34
    (7, ["Maintenance Tunnel", "Leisure Park"], []),                              # Stickers 90-96
    (2, ["Paradise Plaza", "Leisure Park"], ["Get grabbed by the raincoats"]),    # Stickers 98-99
]

# AREA_KEY_NAMES and TIME_KEY_NAMES are imported from .shared_data above.
# The underlying data lives in drdr_shared.json (shared with the Lua mod).

# Locations that require waiting for in-game time to pass.
# When ScoopSanity is enabled, time is frozen, so these are unobtainable.
SCOOP_SANITY_EXCLUDED_LOCATIONS = {
    "Survive until 7pm on day 1",
    "Meet back at the Security Room at 6am day 2",
    "Meet back at the Security Room at 11am day 3",
    "Meet back at the Security Room at 5pm day 3",
    "Head back to the Security Room at the end of day 3",
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
        # Savior+ScoopSanity drops main scoops entirely — the player wins by
        # rescuing survivors, so main scoops would only advance unused state.
        self.main_scoops_enabled = not (
            self.options.goal.value == 2 and self.options.scoop_sanity
        )

        self.enabled_location_categories.add(DRLocationCategory.SURVIVOR)
        self.enabled_location_categories.add(DRLocationCategory.LEVEL_UP)
        self.enabled_location_categories.add(DRLocationCategory.PP_STICKER)
        if self.main_scoops_enabled:
            self.enabled_location_categories.add(DRLocationCategory.MAIN_SCOOP)
        if self.options.goal.value == 0:  # Ending S
            self.enabled_location_categories.add(DRLocationCategory.OVERTIME_SCOOP)
        self.enabled_location_categories.add(DRLocationCategory.PSYCHO_SCOOP)
        self.enabled_location_categories.add(DRLocationCategory.CHALLENGE)
        if self.options.pp_bonus_locations:
            self.enabled_location_categories.add(DRLocationCategory.PP_BONUS)

        # PP-bonus entries whose requires_location predecessor isn't enabled
        # this seed (e.g. First Aid Kit needs "Clean up... Register 6!" which
        # is MAIN_SCOOP-only). Filtered from both create_region and rule-build.
        self._pp_bonus_excluded_names: Set[str] = set()
        if self.options.pp_bonus_locations:
            for _entry in AP_TRIGGER_LOCATIONS:
                _req = _entry.get("requires_location")
                if not _req:
                    continue
                _req_data = location_dictionary.get(_req)
                if not _req_data:
                    # Predecessor isn't even in the static table -- bad data;
                    # skip the entry to be safe.
                    for _n in expand_trigger_location_names(_entry):
                        self._pp_bonus_excluded_names.add(_n)
                    continue
                if _req_data.category not in self.enabled_location_categories:
                    for _n in expand_trigger_location_names(_entry):
                        self._pp_bonus_excluded_names.add(_n)

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
                self.random,
                mode=door_mode,
                randomize_rooftop_service_hallway=bool(
                    self.options.randomize_rooftop_service_hallway_doors
                ),
                # ScoopSanity unlocks the Security Room <-> Entrance Plaza
                # door pair (no longer cutscene-only after Jessie), so they
                # become randomizable+walkable.
                scoop_sanity=bool(self.options.scoop_sanity.value),
            )

        # If ScoopSanity is enabled, generate a randomized main scoop order and precollect all time keys
        if self.options.scoop_sanity:
            for time_key in TIME_KEY_NAMES:
                self.multiworld.push_precollected(self.create_item(time_key))
            if self.main_scoops_enabled:
                scoop_order = list(MAIN_SCOOP_NAMES)
                self.random.shuffle(scoop_order)
                self.scoop_order = scoop_order
            # else: Savior+ScoopSanity — scoop_order stays empty.

        # Softlock prevention
        if self.options.door_randomizer and self.options.scoop_sanity:
            self.multiworld.push_precollected(self.create_item("Out of Control"))


    def create_regions(self):
        regions: Dict[str, Region] = {}
        regions["Menu"] = self.create_region("Menu", [])
        regions.update({region_name: self.create_region(region_name, location_tables[region_name]) for region_name in [
            "Heliport",
            "Security Room",
            "Rooftop",
            "Warehouse",
            "Paradise Plaza",
            "Entrance Plaza",
            "Al Fresca Plaza",
            "Leisure Park",
            "Wonderland Plaza",
            "North Plaza",
            "Food Court",
            "Colby's Movieland",
            "Seon's Food and Stuff",
            "Crislip's Home Saloon",
            "Maintenance Tunnel",
            "Carlito's Hideout",
            "Tunnels",
            "Level Ups",
            "Challenges"
        ]})

        def create_connection(from_region: str, to_region: str):
            connection = Entrance(self.player, f"{from_region} -> {to_region}", regions[from_region])
            regions[from_region].exits.append(connection)
            connection.connect(regions[to_region])

        create_connection("Menu", "Heliport")
        create_connection("Heliport", "Security Room")
        create_connection("Security Room", "Rooftop")
        create_connection("Rooftop", "Warehouse")
        create_connection("Warehouse", "Paradise Plaza")

        create_connection("Paradise Plaza", "Colby's Movieland")
        create_connection("Paradise Plaza", "Leisure Park")

        # ScoopSanity-only entrances:
        #   * Paradise Plaza -> Entrance Plaza is open from the start.
        #   * Security Room -> Entrance Plaza opens after the player meets
        #     Jessie in the Warehouse (the in-game cutscene now opens this
        #     pathway instead of being one-shot). Access requires Rooftop
        #     key + Warehouse key (proxy for "got to Jessie") plus the
        #     Entrance Plaza key (the door itself).
        if self.options.scoop_sanity:
            create_connection("Paradise Plaza", "Entrance Plaza")
            create_connection("Security Room", "Entrance Plaza")

        create_connection("Al Fresca Plaza", "Entrance Plaza")

        # Maintenance Tunnel Access Key connections
        # In-game, the player can grab a physical Access Key from inside the Maintenance Tunnel,
        # so these are available in either mode once the player can reach the Maintenance Tunnel.
        # In ScoopSanity, the player can also receive the key as an item, bypassing Leisure Park.
        create_connection("Paradise Plaza", "Maintenance Tunnel")
        create_connection("Entrance Plaza", "Maintenance Tunnel")
        create_connection("Al Fresca Plaza", "Maintenance Tunnel")
        create_connection("Food Court", "Maintenance Tunnel")
        create_connection("Wonderland Plaza", "Maintenance Tunnel")
        create_connection("Seon's Food and Stuff", "Maintenance Tunnel")
        
        create_connection("Food Court", "Al Fresca Plaza")
        create_connection("Food Court", "Wonderland Plaza")
        create_connection("Wonderland Plaza", "North Plaza")

        create_connection("Leisure Park", "Food Court")
        create_connection("Leisure Park", "North Plaza")
        create_connection("Leisure Park", "Maintenance Tunnel")

        create_connection("North Plaza", "Seon's Food and Stuff")
        create_connection("North Plaza", "Crislip's Home Saloon")
        create_connection("North Plaza", "Carlito's Hideout")

        create_connection("Carlito's Hideout", "Tunnels")
        create_connection("Leisure Park", "Tunnels")

        create_connection("Menu", "Level Ups")
        create_connection("Menu", "Challenges")


    GOAL_LOCATIONS = {
        0: "Ending S: Beat up Brock with your bare fists!",   # Ending S
        1: "Ending A: Solve all of the cases and be on the helipad at 12pm",  # Ending A
        2: "Savior: Rescue enough survivors to escape",        # Savior (count-based)
    }

    # Name of the goal location used by the Savior goal. Must match the entry
    # added at the end of location_tables["Security Room"] in Locations.py.
    SAVIOR_GOAL_LOCATION = "Savior: Rescue enough survivors to escape"

    # All "Rescue X" location names. Used by the Savior goal's access rule to
    # count reachable survivors. Built once at class load from Locations.py.
    ALL_RESCUE_LOCATIONS = [
        loc.name
        for region_locs in location_tables.values()
        for loc in region_locs
        if loc.name.startswith("Rescue ")
    ]

    # EVENT-category goal locations that carry default_item="Victory". If they
    # aren't the active goal, they must be skipped entirely — otherwise the
    # EVENT branch below would create a duplicate Victory event item, which
    # would instantly satisfy the completion condition regardless of goal.
    GOAL_ONLY_EVENT_LOCATIONS = {
        "Ending S: Beat up Brock with your bare fists!",
        "Savior: Rescue enough survivors to escape",
    }

    # MAIN_SCOOP-category locations that fire automatically during the forced
    # intro. These happen regardless of AP state, so they're kept as real checkable
    # locations even when the rest of MAIN_SCOOP is disabled (Savior+ScoopSanity).
    PROLOGUE_MAIN_SCOOPS = {
        "Entrance Plaza Cutscene 1",
        "Help barricade the door!",
        "Get to the stairs!",
        "Meet Jessie in the Warehouse",
    }

    # For each region, add the associated locations retrieved from the corresponding location_table
    def create_region(self, region_name, location_table) -> Region:
        new_region = Region(region_name, self.player, self.multiworld)
        goal_location_name = self.GOAL_LOCATIONS[self.options.goal.value]

        for location in location_table:
            # Skip time-wait locations when ScoopSanity is enabled (time is frozen)
            if self.options.scoop_sanity and location.name in SCOOP_SANITY_EXCLUDED_LOCATIONS:
                continue

            # Skip goal-only EVENT locations that aren't the active goal.
            # Covers Ending S (previously hand-coded) and Savior (new).
            if (location.name in self.GOAL_ONLY_EVENT_LOCATIONS
                    and location.name != goal_location_name):
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
                # Skip PP-bonus locations whose required predecessor wasn't
                # created this seed (set populated in __init__ above).
                if (location.category == DRLocationCategory.PP_BONUS
                        and location.name in self._pp_bonus_excluded_names):
                    continue
                new_location = DRLocation(
                    self.player,
                    location.name,
                    location.category,
                    location.default_item,
                    self.location_name_to_id[location.name],
                    new_region
                )
                new_region.locations.append(new_location)
            elif location.name in self.PROLOGUE_MAIN_SCOOPS:
                # Always-included prologue main-scoop locations — they fire
                # during the forced intro regardless of AP state, so they're
                # real checks even when the rest of MAIN_SCOOP is disabled.
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
                elif (location.category in self.enabled_location_categories
                      or location.name in self.PROLOGUE_MAIN_SCOOPS):
                    # Skip the goal location from the item pool (it gets Victory instead)
                    if location.name == goal_location_name:
                        continue
                    # Prologue main-scoop locations are always real checkable
                    # locations (see PROLOGUE_MAIN_SCOOPS), even when MAIN_SCOOP
                    # category isn't enabled (Savior+ScoopSanity). They need
                    # items in the pool just like any other checkable location.
                    itempoolSize += 1

        self.get_location(goal_location_name).place_locked_item(self.create_item("Victory"))

        # Under Savior+ScoopSanity, drop main scoop items from the pool —
        # their locations don't exist and their completion would only advance
        # story state the goal doesn't need.
        excluded_scoops = MAIN_SCOOP_NAMES if not self.main_scoops_enabled else ()
        foo = BuildItemPool(self.multiworld, itempoolSize, self.options,
                            excluded_scoop_names=excluded_scoops)

        for item in foo:
            itempool.append(self.create_item(item.name))

        self.multiworld.itempool += itempool



    def create_item(self, name: str) -> Item:
        # Skills and stat-upgrade items get Useful classification — guaranteed
        # in the multiworld pool (when enabled) but not part of progression
        # logic. Buffs go to filler. Traps stay trap-classified.
        useful_categories = [DRItemCategory.SKILL, DRItemCategory.UPGRADE]
        data = self.item_name_to_id[name]

        if name in key_item_names or item_dictionary[name].category in [DRItemCategory.LOCK, DRItemCategory.EVENT]:
            item_classification = ItemClassification.progression
        elif item_dictionary[name].category == DRItemCategory.SCOOP and self.options.scoop_sanity:
            item_classification = ItemClassification.progression
        elif name in specialty_items and self.options.restricted_item_mode:
            item_classification = ItemClassification.progression
        elif (name in progression_skills
              and self.options.enable_skill_items
              and self.options.vanilla_progression.value == 1):
            # Skills that gate AP locations need to be progression so the
            # fill algorithm treats them as accessibility keys. Without this,
            # `state.has("Zombie Ride", ...)` rules cause FillError because
            # only progression items count toward accessibility checks.
            # (Mirrors BuildItemPool: skills only join the pool when
            # enable_skill_items is on AND vanilla_progression == replace.)
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
        """Force early placement of the first gate key + first scoop item.
        Prevents Sphere-0 starvation (only Security Room + Level Ups reachable
        until the first key arrives, which fill can otherwise defer arbitrarily).
        """
        if not self.options.door_randomizer:
            self.multiworld.early_items[self.player]["Rooftop key"] = 1

        # scoop_order is empty for Savior+ScoopSanity (main scoops excluded).
        if self.options.scoop_sanity and self.scoop_order:
            self.multiworld.early_items[self.player][self.scoop_order[0]] = 1

    def set_rules(self) -> None:

        # Helper: "Ending A reachable" gate used by a handful of challenge and
        # survivor rules as a proxy for late-game progression. When main scoops
        # are disabled (Savior+ScoopSanity), the Ending A location doesn't
        # exist, so calling state.can_reach_location on it would fail at rule
        # evaluation. In that mode we drop the gate — region requirements are
        # enough for Savior's purposes.
        def ending_a_ok(state):
            if not self.main_scoops_enabled:
                return True
            return state.can_reach_location(
                "Ending A: Solve all of the cases and be on the helipad at 12pm",
                self.player,
            )

        # Default per-location rule: requires reaching the location's region.
        # Sphere-0 regions get `lambda: True` so fill can place progression
        # items there from the first sweep. More specific rules below tighten
        # access where needed (set_rule replaces — later calls win).
        SPHERE_0_REGIONS = {"Menu", "Heliport", "Security Room", "Level Ups", "Challenges"}

        for region in self.multiworld.get_regions(self.player):
            if region.name in SPHERE_0_REGIONS:
                for location in region.locations:
                    set_rule(location, lambda state: True)
            else:
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

        # Savior goal: the synthetic goal location is reachable once the
        # player can reach at least `number_of_survivors` "Rescue X" locations.
        # We capture the target in a local so the closure doesn't pay the
        # options-attribute-lookup cost on every rule evaluation.
        if self.options.goal.value == 2:
            savior_target = self.options.number_of_survivors.value
            savior_player = self.player
            savior_rescue_locations = list(self.ALL_RESCUE_LOCATIONS)

            def savior_rule(state, _target=savior_target, _player=savior_player,
                            _locs=savior_rescue_locations):
                reached = 0
                for loc_name in _locs:
                    if state.can_reach_location(loc_name, _player):
                        reached += 1
                        if reached >= _target:
                            return True
                return False

            set_rule(self.multiworld.get_location(self.SAVIOR_GOAL_LOCATION, self.player),
                     savior_rule)

            # When main scoops are enabled under Savior, Ending A still exists
            # as filler — mark it excluded from progression so fill doesn't
            # place useful items there.
            # When main scoops are disabled (Savior+ScoopSanity), Ending A
            # isn't created at all, so there's nothing to mark.
            # Ending S is EVENT-category and skipped when it isn't the active
            # goal (see GOAL_ONLY_EVENT_LOCATIONS), so no handling needed.
            if self.main_scoops_enabled:
                self.multiworld.get_location(
                    "Ending A: Solve all of the cases and be on the helipad at 12pm",
                    self.player
                ).progress_type = LocationProgressType.EXCLUDED

        # PP-bonus rules (per-count for "counted" entries). Per-location rule
        # combines: required_regions (ALL reachable; first may be bypassed by
        # alt_item), requires_location (extra location gate, e.g. First Aid
        # Kit needs Steven), and restricted_mode_items_any (in restricted
        # mode, requires ANY one of the listed items).
        if self.options.pp_bonus_locations:
            restricted_mode_on = bool(self.options.restricted_item_mode.value)

            def _make_rule(required_regions, alt_item, req_loc, items_any,
                           restricted_on=restricted_mode_on,
                           player=self.player):
                def rule(state):
                    # Region gating: ALL required regions must be reachable,
                    # except the first can be bypassed by alt_item.
                    if required_regions:
                        first = required_regions[0]
                        first_ok = state.can_reach_region(first, player)
                        if not first_ok and alt_item:
                            first_ok = state.has(alt_item, player)
                        if not first_ok:
                            return False
                        for r in required_regions[1:]:
                            if not state.can_reach_region(r, player):
                                return False
                    if req_loc and not state.can_reach_location(req_loc, player):
                        return False
                    if restricted_on and items_any:
                        if not any(state.has(it, player) for it in items_any):
                            return False
                    return True
                return rule

            for _entry in AP_TRIGGER_LOCATIONS:
                _names = expand_trigger_location_names(_entry)
                if not _names:
                    continue
                _alt_item = _entry.get("alt_item")
                _req_loc = _entry.get("requires_location")
                _items_any = _entry.get("restricted_mode_items_any") or []
                _t = _entry.get("type")
                _max = int(_entry.get("max_count", 0))

                # If the entry references a required location (e.g. First Aid
                # Kit needs Steven defeated at "Clean up... Register 6!"),
                # check that location was actually created in this seed --
                # it might not exist when the corresponding category is
                # disabled (Savior + ScoopSanity disables MAIN_SCOOP).
                # Drop the gate gracefully when the location is missing;
                # region gating still applies.
                if _req_loc:
                    try:
                        self.multiworld.get_location(_req_loc, self.player)
                    except KeyError:
                        _req_loc = None

                # Build a list of (location_name, required_regions) tuples
                # so each location gets its own rule reflecting its tier.
                _per_loc: List[Any] = []
                if _t == "single":
                    _regions = trigger_location_required_regions(_entry)
                    for _name in _names:
                        _per_loc.append((_name, _regions))
                elif _t == "counted":
                    # Per-count entries
                    for _i, _name in enumerate(_names[:_max]):
                        _count = _i + 1
                        _regions = trigger_location_required_regions(
                            _entry, count=_count)
                        _per_loc.append((_name, _regions))
                    # all-X variant uses the highest-tier regions
                    if len(_names) > _max:
                        _all_regions = trigger_location_required_regions(
                            _entry, is_all_variant=True)
                        _per_loc.append((_names[-1], _all_regions))

                for _name, _regions in _per_loc:
                    try:
                        _loc = self.multiworld.get_location(_name, self.player)
                    except KeyError:
                        continue
                    set_rule(_loc, _make_rule(
                        _regions, _alt_item, _req_loc, _items_any))

        if not self.options.door_randomizer:
            # Normal key-based entrance rules
            set_rule(self.multiworld.get_entrance("Security Room -> Rooftop", self.player), lambda state: state.has("Rooftop key", self.player))
            set_rule(self.multiworld.get_entrance("Rooftop -> Warehouse", self.player), lambda state: state.has("Warehouse key", self.player))
            set_rule(self.multiworld.get_entrance("Warehouse -> Paradise Plaza", self.player), lambda state: state.has("Paradise Plaza key", self.player))
            set_rule(self.multiworld.get_entrance("Paradise Plaza -> Colby's Movieland", self.player), lambda state: state.has("Colby's Movieland key", self.player))
            set_rule(self.multiworld.get_entrance("Paradise Plaza -> Leisure Park", self.player), lambda state: state.has("Leisure Park key", self.player))
            set_rule(self.multiworld.get_entrance("Leisure Park -> Food Court", self.player), lambda state: state.has("Food Court key", self.player))
            set_rule(self.multiworld.get_entrance("Leisure Park -> North Plaza", self.player), lambda state: state.has("North Plaza key", self.player))
            set_rule(self.multiworld.get_entrance("Leisure Park -> Maintenance Tunnel", self.player), lambda state: state.has("Maintenance Tunnel key", self.player))
            set_rule(self.multiworld.get_entrance("Food Court -> Al Fresca Plaza", self.player), lambda state: state.has("Al Fresca Plaza key", self.player))
            set_rule(self.multiworld.get_entrance("Food Court -> Wonderland Plaza", self.player), lambda state: state.has("Wonderland Plaza key", self.player))
            set_rule(self.multiworld.get_entrance("Al Fresca Plaza -> Entrance Plaza", self.player), lambda state: state.has("Entrance Plaza key", self.player))
            set_rule(self.multiworld.get_entrance("Wonderland Plaza -> North Plaza", self.player), lambda state: state.has("North Plaza key", self.player))
            set_rule(self.multiworld.get_entrance("North Plaza -> Seon's Food and Stuff", self.player), lambda state: state.has("Seon's Food and Stuff key", self.player))
            set_rule(self.multiworld.get_entrance("North Plaza -> Carlito's Hideout", self.player), lambda state: state.has("Carlito's Hideout key", self.player))
            set_rule(self.multiworld.get_entrance("North Plaza -> Crislip's Home Saloon", self.player), lambda state: state.has("Crislip's Home Saloon key", self.player))

            # ScoopSanity-only entrance rules:
            #   * Paradise Plaza -> Entrance Plaza requires Entrance Plaza key.
            #   * Security Room -> Entrance Plaza requires Rooftop key +
            #     Warehouse key (the player must have been able to reach
            #     Jessie in the Warehouse for the cutscene to fire) plus
            #     Entrance Plaza key (the door itself).
            if self.options.scoop_sanity:
                set_rule(self.multiworld.get_entrance("Paradise Plaza -> Entrance Plaza", self.player),
                         lambda state: state.has("Entrance Plaza key", self.player))
                set_rule(self.multiworld.get_entrance("Security Room -> Entrance Plaza", self.player),
                         lambda state: state.has("Rooftop key", self.player)
                                       and state.has("Warehouse key", self.player)
                                       and state.has("Entrance Plaza key", self.player))

            # Maintenance Tunnel Access Key connections
            # Requires MT key + either: already able to reach MT (physical key pickup) OR has the sent Access Key item
            for entrance_name in [
                "Paradise Plaza -> Maintenance Tunnel",
                "Entrance Plaza -> Maintenance Tunnel",
                "Al Fresca Plaza -> Maintenance Tunnel",
                "Food Court -> Maintenance Tunnel",
                "Wonderland Plaza -> Maintenance Tunnel",
                "Seon's Food and Stuff -> Maintenance Tunnel",
            ]:
                set_rule(self.multiworld.get_entrance(entrance_name, self.player),
                         lambda state: state.has("Maintenance Tunnel key", self.player) and
                                       (state.can_reach_region("Maintenance Tunnel", self.player) or
                                        state.has("Maintenance Tunnel Access Key", self.player)))

        # "Meet Jessie in the Warehouse" is a prologue main scoop that
        # always exists (see PROLOGUE_MAIN_SCOOPS). Its rule is set outside
        # the main_scoops_enabled guard so Savior+ScoopSanity still gates it
        # correctly. Other rules that reference it from within the guard are
        # fine because they only run when it's guaranteed to exist.
        set_rule(self.multiworld.get_location("Meet Jessie in the Warehouse", self.player), lambda state: state.can_reach_region("Warehouse", self.player))

        # Events — the rest of the main-scoop completion chain. These
        # locations are MAIN_SCOOP category and don't exist when
        # Savior+ScoopSanity is active (main scoops excluded). Skip the
        # block to avoid KeyErrors from get_location on nonexistent names.
        if self.main_scoops_enabled:
            # ScoopSanity overrides this rule per-event in the SCOOP_EVENTS
            # loop below; here is the vanilla path only (story chains from
            # Meet Jessie -> walk Brad through the mall to the safe room).
            set_rule(self.multiworld.get_location("Complete Backup for Brad", self.player), lambda state: state.can_reach_location("Meet Jessie in the Warehouse", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Paradise Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.has("Food Court key", self.player))

            set_rule(self.multiworld.get_location("Escort Brad to see Dr Barnaby", self.player), lambda state: state.can_reach_location("Complete Backup for Brad", self.player) and state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.has("Entrance Plaza key", self.player))

            set_rule(self.multiworld.get_location("Complete Temporary Agreement", self.player), lambda state: state.can_reach_location("Escort Brad to see Dr Barnaby", self.player))

            if not self.options.scoop_sanity:
                set_rule(self.multiworld.get_location("Meet back at the Security Room at 6am day 2", self.player), lambda state: state.has("DAY2_06_AM", self.player) and state.can_reach_location("Complete Temporary Agreement", self.player))

                set_rule(self.multiworld.get_location("Complete Image in the Monitor", self.player), lambda state: state.can_reach_location("Meet back at the Security Room at 6am day 2", self.player))

            set_rule(self.multiworld.get_location("Complete Rescue the Professor", self.player), lambda state: state.can_reach_location("Complete Image in the Monitor", self.player))

            set_rule(self.multiworld.get_location("Meet Steven", self.player), lambda state: state.can_reach_location("Complete Rescue the Professor", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Seon's Food and Stuff", self.player))

            set_rule(self.multiworld.get_location("Clean up... Register 6!", self.player), lambda state: state.can_reach_location("Meet Steven", self.player))

            set_rule(self.multiworld.get_location("Complete Medicine Run", self.player), lambda state: state.can_reach_location("Clean up... Register 6!", self.player))

            set_rule(self.multiworld.get_location("Complete Professor's Past", self.player), lambda state: state.can_reach_location("Complete Medicine Run", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player))

            set_rule(self.multiworld.get_location("Complete Girl Hunting", self.player), lambda state: state.can_reach_location("Complete Professor's Past", self.player))

            set_rule(self.multiworld.get_location("Beat up Isabela", self.player), lambda state: state.can_reach_location("Complete Girl Hunting", self.player))

            set_rule(self.multiworld.get_location("Complete Promise to Isabela", self.player), lambda state: state.can_reach_location("Beat up Isabela", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player))

            set_rule(self.multiworld.get_location("Save Isabela from the zombie", self.player), lambda state: state.can_reach_location("Complete Promise to Isabela", self.player))

            set_rule(self.multiworld.get_location("Complete Transporting Isabela", self.player), lambda state: state.can_reach_location("Save Isabela from the zombie", self.player))

            set_rule(self.multiworld.get_location("Carry Isabela back to the Security Room", self.player), lambda state: state.can_reach_location("Complete Transporting Isabela", self.player))

            set_rule(self.multiworld.get_location("Complete Santa Cabeza", self.player), lambda state: state.can_reach_location("Carry Isabela back to the Security Room", self.player))

            if not self.options.scoop_sanity:
                set_rule(self.multiworld.get_location("Meet back at the Security Room at 11am day 3", self.player), lambda state: state.can_reach_location("Complete Santa Cabeza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player))

                set_rule(self.multiworld.get_location("Complete Bomb Collector", self.player), lambda state: state.can_reach_location("Meet back at the Security Room at 11am day 3", self.player) and state.can_reach_region("Maintenance Tunnel", self.player))

                set_rule(self.multiworld.get_location("Beat Drivin Carlito", self.player), lambda state: state.can_reach_location("Complete Bomb Collector", self.player) and state.can_reach_region("Maintenance Tunnel", self.player))

                set_rule(self.multiworld.get_location("Meet back at the Security Room at 5pm day 3", self.player), lambda state: state.can_reach_location("Complete Bomb Collector", self.player) or state.can_reach_location("Beat Drivin Carlito", self.player))

                set_rule(self.multiworld.get_location("Escort Isabela to Carlito's Hideout and have a chat", self.player), lambda state: state.can_reach_location("Meet back at the Security Room at 5pm day 3", self.player) and state.can_reach_region("Carlito's Hideout", self.player))

            if self.options.scoop_sanity:
                self.multiworld.get_location("Beat Drivin Carlito", self.player).progress_type = LocationProgressType.EXCLUDED

            set_rule(self.multiworld.get_location("Complete Jessie's Discovery", self.player), lambda state: state.can_reach_location("Escort Isabela to Carlito's Hideout and have a chat", self.player))

            set_rule(self.multiworld.get_location("Meet Larry", self.player), lambda state: state.can_reach_location("Complete Jessie's Discovery", self.player))

            set_rule(self.multiworld.get_location("Complete The Butcher", self.player), lambda state: state.can_reach_location("Meet Larry", self.player))

            set_rule(self.multiworld.get_location("Complete Memories", self.player), lambda state: state.can_reach_location("Complete The Butcher", self.player))

            if not self.options.scoop_sanity:
                set_rule(self.multiworld.get_location("Head back to the Security Room at the end of day 3", self.player), lambda state: state.can_reach_location("Complete Memories", self.player))

                set_rule(self.multiworld.get_location("Witness Special Forces 10pm day 3", self.player), lambda state: state.can_reach_location("Complete Memories", self.player))

            set_rule(self.multiworld.get_location("Ending A: Solve all of the cases and be on the helipad at 12pm", self.player), lambda state: state.can_reach_location("Complete Memories", self.player) and state.can_reach_region("Heliport", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.has("DAY4_12_PM", self.player))

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

        # ScoopSanity: gate every event of every scoop uniformly on
        # (item received, previous scoop's completion, scoop regions,
        # position-level gate). Replaces the vanilla event-to-event chain
        # so randomized order can't strand intermediate events behind the
        # vanilla predecessor. Day items aren't checked here -- the engine
        # sets time flags directly on chain advance in ScoopSanity.
        if self.options.scoop_sanity and self.scoop_order:
            for i, scoop_name in enumerate(self.scoop_order):
                prereq = ("Meet Jessie in the Warehouse" if i == 0
                          else SCOOP_COMPLETION_MAP[self.scoop_order[i - 1]])
                regions = SCOOP_REGION_REQUIREMENTS.get(scoop_name, [])
                level_req = (SCOOP_POSITION_LEVEL_GATES[i]
                             if i < len(SCOOP_POSITION_LEVEL_GATES)
                             else None)
                for event_name in SCOOP_EVENTS[scoop_name]:
                    loc = self.multiworld.get_location(event_name, self.player)
                    set_rule(loc,
                        lambda state, sn=scoop_name, p=prereq,
                               rn=regions, lv=level_req:
                            state.has(sn, self.player) and
                            state.can_reach_location(p, self.player) and
                            all(state.can_reach_region(r, self.player) for r in rn) and
                            (lv is None or
                             state.can_reach_location(f"Reach Level {lv}", self.player)))

            # Complete Memories is the post-chain anchor; gates on the last
            # randomized scoop's completion regardless of which scoop that is.
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
        set_rule(self.multiworld.get_location("Photograph PP Sticker 15", self.player), lambda state: state.can_reach_region("Colby's Movieland", self.player) and state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 16", self.player), lambda state: state.can_reach_region("Colby's Movieland", self.player) and state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 17", self.player), lambda state: state.can_reach_region("Colby's Movieland", self.player) and state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 18", self.player), lambda state: state.can_reach_region("Colby's Movieland", self.player) and state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 19", self.player), lambda state: state.can_reach_region("Colby's Movieland", self.player) and state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 20", self.player), lambda state: state.can_reach_region("Colby's Movieland", self.player) and state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 21", self.player), lambda state: state.can_reach_region("Colby's Movieland", self.player) and state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 22", self.player), lambda state: state.can_reach_region("Colby's Movieland", self.player) and state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 23", self.player), lambda state: state.can_reach_region("Colby's Movieland", self.player) and state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 24", self.player), lambda state: state.can_reach_region("Colby's Movieland", self.player) and state.can_reach_region("Paradise Plaza", self.player))
        # EP shutter gate (used by EP stickers, EP survivors, Hall Family).
        # Vanilla: gated on Brad escort. ScoopSanity: gated on first scoop
        # received (plus the escort if Backup for Brad is first). Savior+SS:
        # gated on Warehouse reach (Meet Jessie milestone fires flag 514).
        if self.options.scoop_sanity and self.scoop_order:
            first_scoop = self.scoop_order[0]
            ep_shutter = lambda state, fs=first_scoop: state.has(fs, self.player) and (fs != "Backup for Brad" or state.can_reach_location("Escort Brad to see Dr Barnaby", self.player))
        elif self.options.scoop_sanity:
            # Savior+ScoopSanity path — shutter gated on Warehouse access.
            ep_shutter = lambda state: state.can_reach_region("Warehouse", self.player)
        else:
            ep_shutter = None
        set_rule(self.multiworld.get_location("Photograph PP Sticker 25", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and ((not self.options.scoop_sanity and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player)) or (self.options.scoop_sanity and ep_shutter(state))))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 26", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and ((not self.options.scoop_sanity and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player)) or (self.options.scoop_sanity and ep_shutter(state))))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 27", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and ((not self.options.scoop_sanity and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player)) or (self.options.scoop_sanity and ep_shutter(state))))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 28", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and ((not self.options.scoop_sanity and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player)) or (self.options.scoop_sanity and ep_shutter(state))))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 29", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and ((not self.options.scoop_sanity and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player)) or (self.options.scoop_sanity and ep_shutter(state))))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 30", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and ((not self.options.scoop_sanity and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player)) or (self.options.scoop_sanity and ep_shutter(state))))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 31", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and ((not self.options.scoop_sanity and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player)) or (self.options.scoop_sanity and ep_shutter(state))))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 32", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and ((not self.options.scoop_sanity and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player)) or (self.options.scoop_sanity and ep_shutter(state))))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 33", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and ((not self.options.scoop_sanity and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player)) or (self.options.scoop_sanity and ep_shutter(state))))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 34", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and ((not self.options.scoop_sanity and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player)) or (self.options.scoop_sanity and ep_shutter(state))))
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
        set_rule(self.multiworld.get_location("Photograph PP Sticker 83", self.player), lambda state: state.can_reach_region("Seon's Food and Stuff", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 84", self.player), lambda state: state.can_reach_region("Seon's Food and Stuff", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 85", self.player), lambda state: state.can_reach_region("Seon's Food and Stuff", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 74", self.player), lambda state: state.can_reach_region("Crislip's Home Saloon", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 75", self.player), lambda state: state.can_reach_region("Crislip's Home Saloon", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player))
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
        set_rule(self.multiworld.get_location("Photograph PP Sticker 97", self.player), lambda state: state.can_reach_region("Security Room", self.player))
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

        set_rule(self.multiworld.get_location("Rescue Bill Brenton", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player)) or (self.options.scoop_sanity and ep_shutter(state))))
        set_rule(self.multiworld.get_location("Rescue Wayne Blackwell", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.can_reach_location("Meet the Hall Family", self.player) and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player)) or (self.options.scoop_sanity and state.has("Mark of the Sniper", self.player) and ep_shutter(state))))
        set_rule(self.multiworld.get_location("Rescue Jolie Wu", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player)) or (self.options.scoop_sanity and state.has("The Woman Who Didn't Make it", self.player) and ep_shutter(state))))
        set_rule(self.multiworld.get_location("Rescue Rachel Decker", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player)) or (self.options.scoop_sanity and state.has("The Woman Who Didn't Make it", self.player) and ep_shutter(state))))
        set_rule(self.multiworld.get_location("Rescue Floyd Sanders", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.can_reach_location("Escort Brad to see Dr Barnaby", self.player)) or (self.options.scoop_sanity and state.has("Antique Lover", self.player) and ep_shutter(state))))

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
        set_rule(self.multiworld.get_location("Rescue Josh Manning", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Crislip's Home Saloon", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.can_reach_location("Kill Cliff", self.player)) or (self.options.scoop_sanity and state.has("The Hatchet Man", self.player))))
        set_rule(self.multiworld.get_location("Rescue Barbara Patterson", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Crislip's Home Saloon", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.can_reach_location("Kill Cliff", self.player)) or (self.options.scoop_sanity and state.has("The Hatchet Man", self.player))))
        set_rule(self.multiworld.get_location("Rescue Rich Atkins", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Crislip's Home Saloon", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.can_reach_location("Kill Cliff", self.player)) or (self.options.scoop_sanity and state.has("The Hatchet Man", self.player))))
        set_rule(self.multiworld.get_location("Rescue Kindell Johnson", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player)) or (self.options.scoop_sanity and state.has("Dressed for Action", self.player))))
        set_rule(self.multiworld.get_location("Rescue Brett Styles", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player)) or (self.options.scoop_sanity and state.has("Gun Shop Standoff", self.player))))
        set_rule(self.multiworld.get_location("Rescue Jonathan Picardson", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player)) or (self.options.scoop_sanity and state.has("Gun Shop Standoff", self.player))))
        set_rule(self.multiworld.get_location("Rescue Alyssa Laurent", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player)) or (self.options.scoop_sanity and state.has("Gun Shop Standoff", self.player))))

        set_rule(self.multiworld.get_location("Rescue Beth Shrake", self.player), lambda state: state.can_reach_region("Colby's Movieland", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.can_reach_location("Kill Sean", self.player)) or (self.options.scoop_sanity and state.has("A Strange Group", self.player))))
        set_rule(self.multiworld.get_location("Rescue Michelle Feltz", self.player), lambda state: state.can_reach_region("Colby's Movieland", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.can_reach_location("Kill Sean", self.player)) or (self.options.scoop_sanity and state.has("A Strange Group", self.player))))
        set_rule(self.multiworld.get_location("Rescue Nathan Crabbe", self.player), lambda state: state.can_reach_region("Colby's Movieland", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.can_reach_location("Kill Sean", self.player)) or (self.options.scoop_sanity and state.has("A Strange Group", self.player))))
        set_rule(self.multiworld.get_location("Rescue Ray Mathison", self.player), lambda state: state.can_reach_region("Colby's Movieland", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.can_reach_location("Kill Sean", self.player)) or (self.options.scoop_sanity and state.has("A Strange Group", self.player))))
        set_rule(self.multiworld.get_location("Rescue Cheryl Jones", self.player), lambda state: state.can_reach_region("Colby's Movieland", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.can_reach_location("Kill Sean", self.player)) or (self.options.scoop_sanity and state.has("A Strange Group", self.player))))

        # Psychopaths
        set_rule(self.multiworld.get_location("Watch the convicts kill that poor guy", self.player), lambda state: state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity) or (self.options.scoop_sanity and state.has("The Convicts", self.player))))

        set_rule(self.multiworld.get_location("Meet Cletus", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and ((not self.options.scoop_sanity) or (self.options.scoop_sanity and state.has("Cletus", self.player))))
        set_rule(self.multiworld.get_location("Kill Cletus", self.player), lambda state: state.can_reach_location("Meet Cletus", self.player))

        set_rule(self.multiworld.get_location("Meet Adam", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and ((not self.options.scoop_sanity) or (self.options.scoop_sanity and state.has("Out of Control", self.player))))
        set_rule(self.multiworld.get_location("Kill Adam", self.player), lambda state: state.can_reach_location("Meet Adam", self.player))

        set_rule(self.multiworld.get_location("Meet Cliff", self.player), lambda state: state.can_reach_region("Crislip's Home Saloon", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player)) or (self.options.scoop_sanity and state.has("The Hatchet Man", self.player))))
        set_rule(self.multiworld.get_location("Kill Cliff", self.player), lambda state: state.can_reach_location("Meet Cliff", self.player))

        set_rule(self.multiworld.get_location("Meet Jo", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player)) or (self.options.scoop_sanity and state.has("Above the Law", self.player))))
        set_rule(self.multiworld.get_location("Kill Jo", self.player), lambda state: state.can_reach_location("Meet Jo", self.player))

        set_rule(self.multiworld.get_location("Meet the Hall Family", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player)) or (self.options.scoop_sanity and state.has("Mark of the Sniper", self.player))))
        set_rule(self.multiworld.get_location("Kill Roger and Jack (and Thomas if you want) and chat with Wayne", self.player), lambda state: state.can_reach_location("Meet the Hall Family", self.player) and ((not self.options.scoop_sanity) or (self.options.scoop_sanity and ep_shutter(state))))

        set_rule(self.multiworld.get_location("Witness Sean in Paradise Plaza", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player)) or (self.options.scoop_sanity and (state.has("The Cult", self.player)) or (state.has("A Strange Group", self.player)))))
        set_rule(self.multiworld.get_location("Get grabbed by the raincoats", self.player), lambda state: state.can_reach_location("Witness Sean in Paradise Plaza", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Meet Sean", self.player), lambda state: state.can_reach_region("Colby's Movieland", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player)) or (self.options.scoop_sanity and state.has("A Strange Group", self.player))))
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
        set_rule(self.multiworld.get_location("Reach Level 40!", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Maintenance Tunnel", self.player) and ending_a_ok(state))
        set_rule(self.multiworld.get_location("Reach max level", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Maintenance Tunnel", self.player) and ending_a_ok(state))
        set_rule(self.multiworld.get_location("Kill 500 zombies by vehicle", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player))
        set_rule(self.multiworld.get_location("Kill 1000 zombies by vehicle", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player))
        all_side_scoops = SURVIVOR_SCOOP_NAMES + PSYCHOPATH_SCOOP_NAMES
        set_rule(self.multiworld.get_location("Get 50 survivors to join", self.player), lambda state, scoops=all_side_scoops: state.can_reach_region("Paradise Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.can_reach_location("Kill Kent on day 3", self.player) and state.can_reach_location("Kill Cliff", self.player) and state.can_reach_location("Kill Jo", self.player) and state.can_reach_location("Kill Adam", self.player) and state.can_reach_location("Kill Sean", self.player) and state.can_reach_location("Kill Roger and Jack (and Thomas if you want) and chat with Wayne", self.player) and state.can_reach_location("Defeat Paul", self.player) and ((not self.options.scoop_sanity) or (self.options.scoop_sanity and state.has_all(scoops, self.player) and ending_a_ok(state))))
        set_rule(self.multiworld.get_location("Encounter 10 survivors", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.can_reach_location("Kill Kent on day 3", self.player) and state.can_reach_location("Kill Cliff", self.player) and state.can_reach_location("Kill Jo", self.player) and state.can_reach_location("Kill Adam", self.player) and state.can_reach_location("Kill Sean", self.player) and state.can_reach_location("Kill Roger and Jack (and Thomas if you want) and chat with Wayne", self.player) and state.can_reach_location("Defeat Paul", self.player))
        set_rule(self.multiworld.get_location("Encounter 50 survivors", self.player), lambda state, scoops=all_side_scoops: state.can_reach_region("Paradise Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.can_reach_location("Kill Kent on day 3", self.player) and state.can_reach_location("Kill Cliff", self.player) and state.can_reach_location("Kill Jo", self.player) and state.can_reach_location("Kill Adam", self.player) and state.can_reach_location("Kill Sean", self.player) and state.can_reach_location("Kill Roger and Jack (and Thomas if you want) and chat with Wayne", self.player) and state.can_reach_location("Defeat Paul", self.player) and ((not self.options.scoop_sanity) or (self.options.scoop_sanity and state.has_all(scoops, self.player) and ending_a_ok(state))))
        set_rule(self.multiworld.get_location("Save 10 survivors", self.player), lambda state, scoops=all_side_scoops: state.can_reach_region("Paradise Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.has("DAY4_12_PM", self.player) and state.can_reach_location("Kill Kent on day 3", self.player) and state.can_reach_location("Kill Cliff", self.player) and state.can_reach_location("Kill Jo", self.player) and state.can_reach_location("Kill Adam", self.player) and state.can_reach_location("Kill Sean", self.player) and state.can_reach_location("Kill Roger and Jack (and Thomas if you want) and chat with Wayne", self.player) and state.can_reach_location("Defeat Paul", self.player) and ((not self.options.scoop_sanity) or (self.options.scoop_sanity and state.has_all(scoops, self.player) and ending_a_ok(state))))
        set_rule(self.multiworld.get_location("Save 50 survivors", self.player), lambda state, scoops=all_side_scoops: state.can_reach_region("Paradise Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.has("DAY4_12_PM", self.player) and state.can_reach_location("Kill Kent on day 3", self.player) and state.can_reach_location("Kill Cliff", self.player) and state.can_reach_location("Kill Jo", self.player) and state.can_reach_location("Kill Adam", self.player) and state.can_reach_location("Kill Sean", self.player) and state.can_reach_location("Kill Roger and Jack (and Thomas if you want) and chat with Wayne", self.player) and state.can_reach_location("Defeat Paul", self.player) and ((not self.options.scoop_sanity) or (self.options.scoop_sanity and state.has_all(scoops, self.player) and ending_a_ok(state))))

        # These five survivor-count milestones are gated behind nearly every
        # late-game scoop, so they only become reachable once most of the
        # progression chain is already solved -- a poor place for progression
        # or useful items, since they'd effectively be locked behind the rest
        # of the run. Mark them filler-only.
        for _name in (
            "Get 50 survivors to join",
            "Encounter 10 survivors",
            "Encounter 50 survivors",
            "Save 10 survivors",
            "Save 50 survivors",
        ):
            self.multiworld.get_location(_name, self.player).progress_type = LocationProgressType.EXCLUDED

        set_rule(self.multiworld.get_location("Kill 1000 zombies", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player))
        set_rule(self.multiworld.get_location("Kill 2000 zombies", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Entrance Plaza", self.player))
        set_rule(self.multiworld.get_location("Kill 5000 zombies", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player))
        set_rule(self.multiworld.get_location("Kill 10000 zombies", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and ending_a_ok(state))
        set_rule(self.multiworld.get_location("Walk a quarter marathon", self.player), lambda state: state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Paradise Plaza", self.player) and state.can_reach_region("Seon's Food and Stuff", self.player) and state.can_reach_region("Crislip's Home Saloon", self.player) and state.can_reach_region("Colby's Movieland", self.player))
        if self.options.goal.value == 0:  # Ending S — overtime locations exist
            set_rule(self.multiworld.get_location("Kill 10 Special Forces", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and state.has("DAY3_11_AM", self.player) and state.can_reach_location("Get bit!", self.player) and state.can_reach_location("Ending A: Solve all of the cases and be on the helipad at 12pm", self.player))
        set_rule(self.multiworld.get_location("Destroy all of the wall plates in the Food Court", self.player), lambda state: state.can_reach_region("Food Court", self.player))
        # Psychopath encounter / photograph / kill lists.
        # Steven and Larry are MAIN_SCOOP-category locations (tied to the
        # Medicine Run and The Butcher story missions). When main scoops are
        # disabled (Savior+ScoopSanity), those locations don't exist, so we
        # drop them from these challenge rule lists. With 10 remaining
        # psycho events (7 meet + 3 Hall Family; or 7 kill + 3 Hall Family),
        # both "Photograph 8" and "Kill 8" remain achievable.
        meet_psycho_names = [
            "Meet Cletus", "Meet Adam", "Meet Sean", "Meet Jo", "Meet Cliff",
            "Meet Paul", "Meet Kent on day 3",
        ]
        photograph_psychos = [
            ("Meet Cletus", 1), ("Meet Adam", 1), ("Meet Cliff", 1),
            ("Meet Jo", 1), ("Meet the Hall Family", 3), ("Meet Sean", 1),
            ("Meet Paul", 1), ("Meet Kent on day 3", 1),
        ]
        kill_psychos = [
            ("Kill Cletus", 1), ("Kill Adam", 1), ("Kill Cliff", 1),
            ("Kill Jo", 1), ("Kill Roger and Jack (and Thomas if you want) and chat with Wayne", 3),
            ("Kill Sean", 1), ("Defeat Paul", 1), ("Kill Kent on day 3", 1),
        ]
        if self.main_scoops_enabled:
            meet_psycho_names.extend(["Meet Steven", "Meet Larry"])
            photograph_psychos.extend([("Meet Steven", 1), ("Meet Larry", 1)])
            kill_psychos.extend([("Clean up... Register 6!", 1), ("Complete The Butcher", 1)])

        set_rule(self.multiworld.get_location("Kill 1 psychopath", self.player),
                 lambda state, names=meet_psycho_names: any(state.can_reach_location(n, self.player) for n in names))
        set_rule(self.multiworld.get_location("Photograph 8 psychopaths", self.player),
                 lambda state, psychopaths=photograph_psychos: sum(c for p, c in psychopaths if state.can_reach_location(p, self.player)) >= 8)
        set_rule(self.multiworld.get_location("Kill 8 psychopaths", self.player),
                 lambda state, psychopaths=kill_psychos: sum(c for p, c in psychopaths if state.can_reach_location(p, self.player)) >= 8)
        set_rule(self.multiworld.get_location("Hit 10 zombies with a parasol", self.player), lambda state: (state.can_reach_region("Entrance Plaza", self.player) or state.can_reach_region("Al Fresca Plaza", self.player)) and (not self.options.restricted_item_mode or state.has("Parasol", self.player)))
        set_rule(self.multiworld.get_location("Kill 50 cultists", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and state.can_reach_location("Witness Sean in Paradise Plaza", self.player))
        if self.options.goal.value == 0:  # Ending S — overtime locations exist
            set_rule(self.multiworld.get_location("Kill 100 zombies with an RPG", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player) and state.can_reach_location("Get bit!", self.player))
        set_rule(self.multiworld.get_location("Photograph 30 survivors", self.player), lambda state: state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Entrance Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player))
        set_rule(self.multiworld.get_location("Escort 8 survivors at once", self.player), lambda state, counts=SCOOP_SURVIVOR_COUNTS: state.can_reach_region("Paradise Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_location("Kill Jo", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Entrance Plaza", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player)) or (self.options.scoop_sanity and sum(c[0] for s, c in counts.items() if state.has(s, self.player)) >= 8)))
        set_rule(self.multiworld.get_location("Frank the pimp", self.player), lambda state, counts=SCOOP_SURVIVOR_COUNTS: state.can_reach_region("Paradise Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_location("Kill Jo", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Entrance Plaza", self.player) and ((not self.options.scoop_sanity and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player)) or (self.options.scoop_sanity and sum(c[1] for s, c in counts.items() if state.has(s, self.player)) >= 8)))
        set_rule(self.multiworld.get_location("Jump a vehicle 50 feet", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player))
        set_rule(self.multiworld.get_location("Bowl over 5 zombies", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and (not self.options.restricted_item_mode or state.has("Bowling Ball", self.player)))
        set_rule(self.multiworld.get_location("Hit a golf ball 100 feet", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and (not self.options.restricted_item_mode or state.has("Golf Club", self.player)))
        set_rule(self.multiworld.get_location("Fire 30 bullets", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and (not self.options.restricted_item_mode or state.has("Handgun", self.player)))
        set_rule(self.multiworld.get_location("Fire 300 bullets", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and (not self.options.restricted_item_mode or state.has("Handgun", self.player)))
        # "Ride zombies for 50 feet" requires Zombie Ride only when that
        # skill is actually in the AP item pool. BuildItemPool adds skills
        # only when enable_skill_items is on AND vanilla_progression is
        # "replace" (mode 1) -- under "vanilla_only" or "extra_buffs_only"
        # the engine grants skills on level-up and they aren't AP items,
        # so the location is reachable purely via region access.
        _zombie_ride_is_pool_item = bool(self.options.enable_skill_items) and self.options.vanilla_progression.value == 1
        set_rule(self.multiworld.get_location("Ride zombies for 50 feet", self.player),
                 lambda state, gated=_zombie_ride_is_pool_item:
                     state.can_reach_region("Maintenance Tunnel", self.player)
                     and (not gated or state.has("Zombie Ride", self.player)))
        set_rule(self.multiworld.get_location("Change into 46 new outfits", self.player), lambda state: state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Paradise Plaza", self.player) and state.can_reach_region("Seon's Food and Stuff", self.player) and state.can_reach_region("Crislip's Home Saloon", self.player) and state.can_reach_region("Colby's Movieland", self.player))
        set_rule(self.multiworld.get_location("Change into 5 new outfits", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player))
        # PP Sticker group access for the "Photograph N PP Stickers" challenge
        # rules. The vanilla table gates the EP sticker block (25-34) on
        # "Escort Brad to see Dr Barnaby", a MAIN_SCOOP location that doesn't
        # exist under Savior+ScoopSanity. Strip such gates when main scoops
        # are disabled — in that mode the EP shutter opens on the Meet Jessie
        # milestone instead, and the remaining region requirement already
        # gates reachability correctly.
        if self.main_scoops_enabled:
            pp_sticker_groups = PP_STICKER_GROUPS
        else:
            main_scoop_location_names = {
                loc.name
                for region_locs in location_tables.values()
                for loc in region_locs
                if loc.category == DRLocationCategory.MAIN_SCOOP
            }
            pp_sticker_groups = [
                (count, regions, [loc for loc in locs if loc not in main_scoop_location_names])
                for (count, regions, locs) in PP_STICKER_GROUPS
            ]

        set_rule(self.multiworld.get_location("Photograph 10 PP Stickers", self.player), lambda state, groups=pp_sticker_groups: sum(g[0] for g in groups if all(state.can_reach_region(r, self.player) for r in g[1]) and all(state.can_reach_location(l, self.player) for l in g[2])) >= 10)
        set_rule(self.multiworld.get_location("Photograph 20 PP Stickers", self.player), lambda state, groups=pp_sticker_groups: sum(g[0] for g in groups if all(state.can_reach_region(r, self.player) for r in g[1]) and all(state.can_reach_location(l, self.player) for l in g[2])) >= 20)
        set_rule(self.multiworld.get_location("Photograph 30 PP Stickers", self.player), lambda state, groups=pp_sticker_groups: sum(g[0] for g in groups if all(state.can_reach_region(r, self.player) for r in g[1]) and all(state.can_reach_location(l, self.player) for l in g[2])) >= 30)
        set_rule(self.multiworld.get_location("Photograph 40 PP Stickers", self.player), lambda state, groups=pp_sticker_groups: sum(g[0] for g in groups if all(state.can_reach_region(r, self.player) for r in g[1]) and all(state.can_reach_location(l, self.player) for l in g[2])) >= 40)
        set_rule(self.multiworld.get_location("Photograph 50 PP Stickers", self.player), lambda state, groups=pp_sticker_groups: sum(g[0] for g in groups if all(state.can_reach_region(r, self.player) for r in g[1]) and all(state.can_reach_location(l, self.player) for l in g[2])) >= 50)
        set_rule(self.multiworld.get_location("Photograph 60 PP Stickers", self.player), lambda state, groups=pp_sticker_groups: sum(g[0] for g in groups if all(state.can_reach_region(r, self.player) for r in g[1]) and all(state.can_reach_location(l, self.player) for l in g[2])) >= 60)
        set_rule(self.multiworld.get_location("Photograph 70 PP Stickers", self.player), lambda state, groups=pp_sticker_groups: sum(g[0] for g in groups if all(state.can_reach_region(r, self.player) for r in g[1]) and all(state.can_reach_location(l, self.player) for l in g[2])) >= 70)
        set_rule(self.multiworld.get_location("Photograph 80 PP Stickers", self.player), lambda state, groups=pp_sticker_groups: sum(g[0] for g in groups if all(state.can_reach_region(r, self.player) for r in g[1]) and all(state.can_reach_location(l, self.player) for l in g[2])) >= 80)
        set_rule(self.multiworld.get_location("Photograph 90 PP Stickers", self.player), lambda state, groups=pp_sticker_groups: sum(g[0] for g in groups if all(state.can_reach_region(r, self.player) for r in g[1]) and all(state.can_reach_location(l, self.player) for l in g[2])) >= 90)
        set_rule(self.multiworld.get_location("Photograph all PP Stickers", self.player), lambda state, groups=pp_sticker_groups: sum(g[0] for g in groups if all(state.can_reach_region(r, self.player) for r in g[1]) and all(state.can_reach_location(l, self.player) for l in g[2])) >= 100)
        set_rule(self.multiworld.get_location("Get 10000 PP in one photo", self.player), lambda state: state.can_reach_region("Rooftop", self.player))

        set_rule(self.multiworld.get_location("Find Greg's secret passage", self.player), lambda state: state.can_reach_location("Kill Adam", self.player))
        # Endings
        # set_rule(self.multiworld.get_location("Ending B: Don't solve all of the cases but be on the helipad at 12pm", self.player), lambda state: state.can_reach_region("Heliport", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.has("DAY4_12_PM", self.player) and state.can_reach_location("Ending S: Beat up Brock with your bare fists!", self.player))
        # set_rule(self.multiworld.get_location("Ending C: Solve all of the cases but don't meet Isabela at 10am", self.player), lambda state: state.can_reach_location("Complete Memories", self.player) and state.can_reach_region("Heliport", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.has("DAY4_12_PM", self.player) and state.can_reach_location("Ending S: Beat up Brock with your bare fists!", self.player))
        # set_rule(self.multiworld.get_location("Ending D: Be a prisoner when time runs out", self.player), lambda state: state.can_reach_location("Witness Special Forces 10pm day 3", self.player) and state.can_reach_region("Heliport", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.has("DAY4_12_PM", self.player) and state.can_reach_location("Ending S: Beat up Brock with your bare fists!", self.player))
        # set_rule(self.multiworld.get_location("Ending E: Don't solve all of the cases and don't be on the helipad at 12pm", self.player), lambda state: state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.has("DAY4_12_PM", self.player) and state.can_reach_location("Complete Backup for Brad", self.player) and state.can_reach_location("Ending S: Beat up Brock with your bare fists!", self.player))
        # set_rule(self.multiworld.get_location("Ending F: Fail to collect all of the bombs in time", self.player), lambda state: state.can_reach_location("Complete Bomb Collector", self.player))

        if not self.options.scoop_sanity:
            set_rule(self.multiworld.get_location("Survive until 7pm on day 1", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player))

        # Victory Condition
        self.multiworld.completion_condition[self.player] = lambda state: state.has("Victory", self.player)


    def _build_door_overlay_data(self) -> Dict[str, Dict[str, str]]:
        """{scene_code: {vanilla_dest_name: actual_dest_name}} for the Lua
        DoorPromptOverlay. Source ids are 'SCN_<scene>|<vanilla_target>|door<n>';
        AREA_NAMES inverts the vanilla code to the on-screen prompt name.
        No-op redirects are filtered out.
        """
        out: Dict[str, Dict[str, str]] = {}
        for source_id, redirect in (self.door_redirects or {}).items():
            parts = source_id.split("|")
            if len(parts) < 3 or not parts[0].startswith("SCN_"):
                continue
            src_scene = parts[0][4:]              # strip "SCN_"
            vanilla_target_code = parts[1]
            vanilla_target_name = AREA_NAMES.get(vanilla_target_code, vanilla_target_code)
            actual_target_name = redirect.get("target_area_name")
            if not actual_target_name:
                continue
            # Skip no-op redirects (door points to its vanilla destination)
            if actual_target_name == vanilla_target_name:
                continue
            out.setdefault(src_scene, {})[vanilla_target_name] = actual_target_name
        return out

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

        goal = self.options.goal.value  # 0 = Ending S, 1 = Ending A, 2 = Savior
        number_of_survivors = self.options.number_of_survivors.value
        death_link_enabled = bool(self.options.death_link.value)
        restricted_item_mode_enabled = bool(self.options.restricted_item_mode.value)
        door_randomizer_enabled = bool(self.options.door_randomizer.value)
        door_randomizer_mode = self.options.door_randomizer_mode.value
        scoop_sanity_enabled = bool(self.options.scoop_sanity.value)
        exclude_levels_enabled = bool(self.options.exclude_levels.value)

        # Player-stats / progression options (PlayerStats + PlayerBuffs +
        # HostileSurvivorTrap on the Lua side read these from slot_data).
        # vanilla_progression is a Choice; index value 0=vanilla_only,
        # 1=replace, 2=extra_buffs_only — Lua expects the string form.
        _vp_strings = ["vanilla_only", "replace", "extra_buffs_only"]
        vanilla_progression_value = _vp_strings[self.options.vanilla_progression.value]
        enable_skill_items = bool(self.options.enable_skill_items.value)
        enable_stat_items = bool(self.options.enable_stat_items.value)
        enable_extra_stat_buffs = bool(self.options.enable_extra_stat_buffs.value)
        trap_percentage = int(self.options.trap_percentage.value)
        hostile_min = int(self.options.hostile_survivor_count_min.value)
        hostile_max = int(self.options.hostile_survivor_count_max.value)
        # Hardcore implies Night — auto-enable Night when Hardcore is on so
        # the Lua side can rely on the single flag without extra logic.
        night_mode_enabled = bool(self.options.night_mode_enabled.value)
        hardcore_zombies_enabled = bool(self.options.hardcore_zombies_enabled.value)
        if hardcore_zombies_enabled:
            night_mode_enabled = True

        # Costume randomizer toggles. Body-first randomization rule (DLC
        # anchor overrides accessories, regular Body co-randomizes
        # Foot/Hat/Glasses) is implemented Lua-side.
        random_starting_costume = bool(self.options.random_starting_costume.value)
        costume_chaos_mode      = bool(self.options.costume_chaos_mode.value)
        dlc_outfits_enabled     = bool(self.options.dlc_outfits_enabled.value)

        # PP-bonus location toggle + the per-entry firing-rule data the Lua
        # side needs to convert MsgEvents fires into AP location checks.
        # Each entry tells Lua: "when this (list, msg_no) fires the Nth time,
        # send the corresponding location_name as a check". For "single"
        # entries the Nth thing is just a single name. For "counted" entries
        # we send a per-N list plus an all_location_name keyed off all_msg_no.
        pp_bonus_locations_enabled = bool(self.options.pp_bonus_locations.value)
        pp_bonus_trigger_data: List[Dict[str, Any]] = []
        if pp_bonus_locations_enabled:
            for _entry in AP_TRIGGER_LOCATIONS:
                _names = expand_trigger_location_names(_entry)
                if not _names:
                    continue
                # Skip entries whose required-predecessor location wasn't
                # created this seed (matches the create_region filter).
                # Lua wouldn't be able to resolve these names to AP IDs
                # anyway -- pruning here saves the failed lookups.
                if any(n in self._pp_bonus_excluded_names for n in _names):
                    continue
                _t = _entry.get("type")
                _d: Dict[str, Any] = {
                    "id":      _entry.get("id"),
                    "list":    _entry.get("list"),
                    "msg_no":  _entry.get("msg_no"),
                    "type":    _t,
                }
                if _t == "single":
                    _d["location_name"] = _entry.get("location_name")
                elif _t == "counted":
                    # Per-count names: index N-1 -> name for count N
                    _max = int(_entry.get("max_count", 0))
                    # The first _max items in _names are the per-count names
                    _d["count_names"] = _names[:_max]
                    if _entry.get("all_msg_no") is not None:
                        _d["all_msg_no"]      = _entry["all_msg_no"]
                        _d["all_location_name"] = _entry.get("all_location_name")
                pp_bonus_trigger_data.append(_d)

        slot_data = {
            "options": {
                "goal": goal,
                "number_of_survivors": number_of_survivors,
                "guaranteed_items": self.options.guaranteed_items.value,
                "death_link": death_link_enabled,
                "restricted_item_mode": restricted_item_mode_enabled,
                "door_randomizer": door_randomizer_enabled,
                "door_randomizer_mode": door_randomizer_mode,
                "scoop_sanity": scoop_sanity_enabled,
                "exclude_levels": exclude_levels_enabled,
                "exclude_levels_above": self.options.exclude_levels_above.value,
                "enable_skill_items": enable_skill_items,
                "enable_stat_items": enable_stat_items,
                "enable_extra_stat_buffs": enable_extra_stat_buffs,
                "vanilla_progression": vanilla_progression_value,
                "trap_percentage": trap_percentage,
                "hostile_survivor_count_min": hostile_min,
                "hostile_survivor_count_max": hostile_max,
                "night_mode_enabled": night_mode_enabled,
                "hardcore_zombies_enabled": hardcore_zombies_enabled,
                "random_starting_costume": random_starting_costume,
                "costume_chaos_mode": costume_chaos_mode,
                "dlc_outfits_enabled": dlc_outfits_enabled,
                "pp_bonus_locations": pp_bonus_locations_enabled,
            },
            "goal": goal,
            "number_of_survivors": number_of_survivors,
            "death_link": death_link_enabled,
            "restricted_item_mode": restricted_item_mode_enabled,
            "door_randomizer": door_randomizer_enabled,
            "door_randomizer_mode": door_randomizer_mode,  # For Lua: 0 = chaos, 1 = paired
            "door_redirects": self.door_redirects if door_randomizer_enabled else {},
            # Per-scene {vanilla_dest: actual_dest} for the Lua door-prompt
            # overlay. Empty when door_randomizer is off.
            "door_overlay_data": (
                self._build_door_overlay_data() if door_randomizer_enabled else {}
            ),
            "scoop_sanity": scoop_sanity_enabled,
            "exclude_levels": exclude_levels_enabled,
            "scoop_order": self.scoop_order if scoop_sanity_enabled else {},
            # Player-stats slot data (read by Lua on slot connect)
            "vanilla_progression": vanilla_progression_value,
            "trap_percentage": trap_percentage,
            "hostile_survivor_count_min": hostile_min,
            "hostile_survivor_count_max": hostile_max,
            "night_mode_enabled": night_mode_enabled,
            "hardcore_zombies_enabled": hardcore_zombies_enabled,
            "random_starting_costume": random_starting_costume,
            "costume_chaos_mode": costume_chaos_mode,
            "dlc_outfits_enabled": dlc_outfits_enabled,
            "pp_bonus_locations": pp_bonus_locations_enabled,
            "pp_bonus_trigger_data": pp_bonus_trigger_data,
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
        if self.options.scoop_sanity and self.scoop_order:
            player_name = self.multiworld.get_player_name(self.player)
            spoiler_handle.write(f"\nScoopSanity Main Scoop Order ({player_name}):\n")
            for i, scoop_name in enumerate(self.scoop_order):
                spoiler_handle.write(f"  {i + 1}. {scoop_name}\n")

    def generate_output(self, output_directory: str) -> None:
        # Door map HTML is now generated on-demand by the Lua-side DoorVisualizer
        pass