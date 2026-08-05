# world/drdr/__init__.py
from typing import Any, Dict, Set, List

from BaseClasses import MultiWorld, Region, Item, Entrance, Tutorial, ItemClassification, LocationProgressType

from worlds.AutoWorld import World, WebWorld

from .Items import DRItem, DRItemCategory, item_dictionary, key_item_names, item_descriptions, BuildItemPool, specialty_items, progression_skills, microwave_food_items, challenge_tool_items
from .Locations import DRLocation, DRLocationCategory, location_tables, location_dictionary
from .Options import DROption, dr_option_groups

import re

import dataclasses

from rule_builder.rules import (
    And, AtLeast, CanReachLocation, CanReachRegion, Has, HasAll, Or, Rule, True_,
)

from .DoorRandomization import generate_door_randomization_for_ap, DOOR_MODE_CHAOS, DOOR_MODE_PAIRED, AREA_NAMES, EMBEDDED_DOOR_DATA

# Region names in the AP graph match AREA_NAMES values, so explain_path can go
# from a region back to the area code the door table is keyed on.
AREA_TO_CODE = {name: code for code, name in AREA_NAMES.items()}

# Region edges that are not doors in the shuffle table, so the door graph
# cannot describe them. Greg's passage is held out of the shuffle on
# purpose -- randomizing it causes problems -- so it is named here
# instead.
NON_DOOR_ENTRANCES = {
    "Paradise Plaza -> Wonderland Plaza":
        "Greg's secret passage, open once Out of Control is done",
    "Wonderland Plaza -> Paradise Plaza":
        "Greg's secret passage, open once Out of Control is done",
}
from .shared_data import (
    AREA_KEY_NAMES, SPLIT_AREA_NAMES, TIME_KEY_NAMES,
    AP_TRIGGER_LOCATIONS, expand_trigger_location_names,
    trigger_location_required_regions,
    SCOOPS, COMPLETION_FLAGS,
)

# Scoop tables below are derived from drdr_shared.json (schema v2), the same
# file ScoopUnlocker.lua builds SCOOP_DATA from. _validate_shared_scoops()
# turns any name mismatch into a loud generation failure.

# Main scoop names eligible for randomized ordering (ScoopSanity), in
# vanilla order. "The Facts" is main but chain-ineligible (auto-triggered
# after the chain completes).
MAIN_SCOOP_NAMES = [
    s["name"]
    for s in sorted(
        (s for s in SCOOPS if s.get("category") == "Main" and s.get("chain_eligible")),
        key=lambda s: s.get("order", 0),
    )
]

# Each main scoop name -> its completion event location name.
SCOOP_COMPLETION_MAP = {
    s["name"]: s["completion_event"]
    for s in SCOOPS
    if s.get("category") == "Main" and s.get("chain_eligible")
    and s.get("completion_event")
}

# Event list per scoop. Drives the ScoopSanity per-event override loop in
# set_rules (each event is gated on the scoop). SCOOP_COMPLETION_MAP[scoop]
# must appear in the list (it need not be last -- e.g. The Last Resort gates
# an extra "Beat Drivin Carlito" after its completion).
SCOOP_EVENTS = {
    s["name"]: s["events"] for s in SCOOPS if s.get("events")
}


def _validate_shared_scoops() -> None:
    """Fail generation loudly if the shared scoop data disagrees with the
    item/location tables. Every failure here used to be a silent bug: a
    check that never sends, or an item that unlocks nothing."""
    problems: List[str] = []

    all_locations = set(location_dictionary.keys())
    all_items = set(item_dictionary.keys())

    for s in SCOOPS:
        name = s.get("name", "?")
        # Items exist for chain-eligible mains and all side scoops.
        # "Special" entries and chain-ineligible mains ("The Facts",
        # auto-triggered after the chain) are never AP items.
        needs_item = (
            s.get("category") in ("Survivor", "Psychopath")
            or (s.get("category") == "Main" and s.get("chain_eligible"))
        )
        if needs_item and name not in all_items:
            problems.append(f"scoop '{name}' is not an item in Items.py")
        event = s.get("completion_event")
        if event and event not in all_locations:
            problems.append(
                f"scoop '{name}' completion_event '{event}' is not a "
                "location in Locations.py")
        for ev in s.get("events", []):
            if ev not in all_locations:
                problems.append(
                    f"scoop '{name}' event '{ev}' is not a location in "
                    "Locations.py")

    for name, events in SCOOP_EVENTS.items():
        if events and name in SCOOP_COMPLETION_MAP \
                and SCOOP_COMPLETION_MAP[name] not in events:
            problems.append(
                f"scoop '{name}': completion_event "
                f"'{SCOOP_COMPLETION_MAP[name]}' is not among its events")

    for row in COMPLETION_FLAGS:
        event = row.get("event")
        if event and event not in all_locations:
            problems.append(
                f"completion_flags[{row.get('flag')}] event '{event}' is "
                "not a location in Locations.py")

    if len(MAIN_SCOOP_NAMES) != 13:
        problems.append(
            f"expected 13 chain-eligible main scoops, got {len(MAIN_SCOOP_NAMES)}")

    if problems:
        raise ValueError(
            "drdr_shared.json scoop data does not match Items/Locations:\n  "
            + "\n  ".join(problems))


_validate_shared_scoops()

# Region(s) the player must physically reach to complete each scoop.
# Scoops in the Security Room (always reachable) are omitted.
SCOOP_REGION_REQUIREMENTS = {
    "Backup for Brad": ["Food Court", "Entrance Plaza"],
    "Rescue the Professor": ["Entrance Plaza", "Paradise Plaza"],
    "Medicine Run": ["Seon's Food and Stuff"],
    "Girl Hunting": ["North Plaza"],
    "A Promise to Isabela": ["North Plaza", "Rooftop"],
    "The Last Resort": ["Maintenance Tunnel", "Leisure Park"],
    "Hideout": ["Paradise Plaza", "Leisure Park", "North Plaza", "Carlito's Hideout"],
    "The Butcher": ["Maintenance Tunnel"],
}

# Split Keys only. These escorts walk a fixed route, so those doors must be
# open -- reaching the regions another way is not enough. The ScoopSanity
# loop rebuilds scoop rules from scratch and would otherwise drop them.
SPLIT_KEY_SCOOP_DOORS = {
    "Rescue the Professor": ["Entrance - Paradise Key"],
    "Hideout": ["Paradise - Warehouse Key", "Leisure - Paradise Key",
                "Leisure - North Key", "Hideout - North Key"],
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

# Determines the value of the region towards levels
REGION_LEVEL_VALUES = {
    "Security Room": 1,
    "Rooftop": 1,
    "Paradise Plaza": 3,
    "Entrance Plaza": 2,
    "Leisure Park": 3,
    "Al Fresca Plaza": 2,
    "Food Court": 2,
    "Wonderland Plaza": 3,
    "North Plaza": 2,
    "Maintenance Tunnel": 4,
    "Seon's Food and Stuff": 1,
    "Crislip's Home Saloon": 1,
    "Colby's Movieland": 1,
}

def get_reachable_region_points(state, player: int) -> int:
    return sum(value for region, value in REGION_LEVEL_VALUES.items()
               if state.can_reach_region(region, player))


@dataclasses.dataclass()
class RegionPointsAtLeast(Rule["DRWorld"], game="Dead Rising Deluxe Remaster"):
    """Level gates: every region the player can reach is worth points.

    A count over the whole state, so none of the builder's primitives fit.
    Holds only the threshold and the player id -- never the world, which
    would keep the MultiWorld alive past generation.
    """

    count: int

    def _instantiate(self, world) -> Rule.Resolved:
        return self.Resolved(self.count, player=world.player)

    class Resolved(Rule.Resolved):
        count: int

        def _evaluate(self, state) -> bool:
            return get_reachable_region_points(state, self.player) >= self.count

        def explain_json(self, state=None):
            have = get_reachable_region_points(state, self.player) if state else None
            return [
                {"type": "text", "text": "Region points "},
                {"type": "color",
                 "color": "green" if have is not None and have >= self.count else "salmon",
                 "text": "?" if have is None else str(have)},
                {"type": "text", "text": f" of {self.count}"},
            ]

# PP Sticker groups: (count, required_regions, required_locations)
# Used by milestone rules to dynamically count how many stickers the player can reach
PP_STICKER_GROUPS = [
    (1, ["Security Room"], []),                                                   # Sticker 97
    (14, ["Paradise Plaza"], []),                                                 # Stickers 1-14
    (1, ["Rooftop"], []),                                                         # Sticker 100
    (10, ["Colby's Movieland"], []),                                              # Stickers 15-24
    (4, ["Leisure Park"], []),                                                    # Stickers 86-89
    (11, ["Food Court"], []),                                                     # Stickers 46-56
    (11, ["Al Fresca Plaza"], []),                                                # Stickers 35-45
    (15, ["Wonderland Plaza"], []),                                               # Stickers 57-71
    (9, ["North Plaza"], []),                                                     # Stickers 72-73, 76-82
    (3, ["Seon's Food and Stuff"], []),                                           # Stickers 83-85
    (2, ["Crislip's Home Saloon"], []),                                           # Stickers 74-75
    (10, ["Entrance Plaza"], ["Escort Brad to see Dr Barnaby"]),                  # Stickers 25-34
    (7, ["Maintenance Tunnel"], []),                                              # Stickers 90-96
    (2, ["Paradise Plaza", "Leisure Park"], ["Get grabbed by the raincoats"]),    # Stickers 98-99
]

# Zones with a direct door into the Maintenance Tunnel. The Leisure Park
# ramp is separate -- it is the only tunnel entrance that never needs the
# Access Key (the physical copy is picked up inside the tunnels).
MAINTENANCE_TUNNEL_ZONES = [
    "Paradise Plaza", "Entrance Plaza", "Al Fresca Plaza",
    "Food Court", "Wonderland Plaza", "Seon's Food and Stuff",
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

    option_groups = dr_option_groups


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
                # Universal Tracker re-generation: use the connected slot's
                # actual order (see interpret_slot_data) instead of rolling
                # a fresh one, so tracker logic matches the real seed.
                _passthrough = getattr(self.multiworld, "re_gen_passthrough", None)
                _ut_order = None
                if _passthrough and self.game in _passthrough:
                    _ut_order = (_passthrough[self.game] or {}).get("scoop_order")
                if _ut_order:
                    self.scoop_order = list(_ut_order)
                else:
                    scoop_order = list(MAIN_SCOOP_NAMES)
                    self.random.shuffle(scoop_order)
                    # Backup for Brad never leads the chain -- its mission
                    # owns the EP shutter cutscene and holds the trigger
                    # spot closed until the escort completes.
                    if scoop_order[0] == "Backup for Brad":
                        swap = self.random.randrange(1, len(scoop_order))
                        scoop_order[0], scoop_order[swap] = scoop_order[swap], scoop_order[0]
                    self.scoop_order = scoop_order
            # else: Savior+ScoopSanity — scoop_order stays empty.

        # Softlock prevention
        if self.options.door_randomizer and self.options.scoop_sanity:
            self.multiworld.push_precollected(self.create_item("Out of Control"))

        # Split Keys mode starts with Maintenance Tunnel Access Key, other keys determine access through those doors
        if self.options.split_keys:
            self.multiworld.push_precollected(self.create_item("Maintenance Tunnel Access Key"))

    
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
        #   * Security Room -> Entrance Plaza opens after the player meets
        #     Jessie in the Warehouse (the in-game cutscene now opens this
        #     pathway instead of being one-shot). Access requires Rooftop
        #     key + Warehouse key (proxy for "got to Jessie") plus the
        #     Entrance Plaza key (the door itself).
        if self.options.scoop_sanity:
            create_connection("Security Room", "Entrance Plaza")
            create_connection("Paradise Plaza", "Entrance Plaza")

        # Maintenance Tunnel doors work in every mode and both directions,
        # with one exception: vanilla Entrance Plaza access always comes
        # through Al Fresca Plaza, so the tunnel-to-EP door (and the
        # Paradise -> EP shutter above) are only modeled in ScoopSanity.
        # The keyless Leisure Park ramp is created with the other Leisure
        # Park connections below.
        for _zone in MAINTENANCE_TUNNEL_ZONES:
            create_connection(_zone, "Maintenance Tunnel")
            if _zone != "Entrance Plaza" or self.options.scoop_sanity:
                create_connection("Maintenance Tunnel", _zone)
        create_connection("Maintenance Tunnel", "Leisure Park")

        create_connection("Al Fresca Plaza", "Entrance Plaza")
        create_connection("Al Fresca Plaza", "Food Court")
        
        create_connection("Entrance Plaza", "Al Fresca Plaza")
        create_connection("Entrance Plaza", "Paradise Plaza")

        create_connection("Food Court", "Al Fresca Plaza")
        create_connection("Food Court", "Wonderland Plaza")
        create_connection("Food Court", "Leisure Park")

        create_connection("Wonderland Plaza", "North Plaza")
        create_connection("Wonderland Plaza", "Food Court")

        # Greg's secret passage: no area key, opens once Out of Control is done.
        create_connection("Paradise Plaza", "Wonderland Plaza")
        create_connection("Wonderland Plaza", "Paradise Plaza")

        create_connection("Leisure Park", "Food Court")
        create_connection("Leisure Park", "North Plaza")
        create_connection("Leisure Park", "Maintenance Tunnel")
        create_connection("Leisure Park", "Paradise Plaza")

        create_connection("North Plaza", "Leisure Park")
        create_connection("North Plaza", "Wonderland Plaza")
        create_connection("North Plaza", "Seon's Food and Stuff")
        create_connection("North Plaza", "Crislip's Home Saloon")
        create_connection("North Plaza", "Carlito's Hideout")
        
        create_connection("Seon's Food and Stuff", "North Plaza")

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
        elif name in microwave_food_items and self.options.pp_bonus_locations:
            # Food items bypass the Seon's requirement in the microwave
            # rules, so state.has must be able to see them in every mode.
            item_classification = ItemClassification.progression
        elif name in challenge_tool_items:
            # A sent tool can satisfy the challenge rules -- replacing its
            # spawn zones outside restricted mode, whitelisting the pickup
            # inside it -- so state.has must see it in every mode.
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
        return "Rotten Pizza"

    def interpret_slot_data(self, slot_data):
        # Universal Tracker support: returning the slot data makes the
        # tracker re-generate with it attached as re_gen_passthrough, so
        # generate_early can adopt the seed's real scoop order.
        return slot_data

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
        if not self.main_scoops_enabled:
            ending_a_rule = True_()
        else:
            ending_a_rule = CanReachLocation(
                "Ending A: Solve all of the cases and be on the helipad at 12pm")
        # Default per-location rule: requires reaching the location's region.
        # Sphere-0 regions get True_() so fill can place progression items
        # there from the first sweep. More specific rules below tighten
        # access where needed (set_rule replaces — later calls win).
        SPHERE_0_REGIONS = {"Menu", "Heliport", "Security Room", "Level Ups", "Challenges"}

        for region in self.multiworld.get_regions(self.player):
            if region.name in SPHERE_0_REGIONS:
                for location in region.locations:
                    self.set_rule(location, True_())
            else:
                for location in region.locations:
                    self.set_rule(location, CanReachRegion(region.name))

        # Region-Based Levels
        for level in range(2, 7):      # Levels 2-6
            self.set_rule(self.multiworld.get_location(f"Reach Level {level}", self.player),
                          RegionPointsAtLeast(1))

        for level in range(7, 10):     # Levels 7-9
            self.set_rule(self.multiworld.get_location(f"Reach Level {level}", self.player),
                          RegionPointsAtLeast(2))

        for level in range(10, 12):    # Levels 10-11
            self.set_rule(self.multiworld.get_location(f"Reach Level {level}", self.player),
                          RegionPointsAtLeast(4))

        for level in range(12, 13):    # Levels 12
            self.set_rule(self.multiworld.get_location(f"Reach Level {level}", self.player),
                          RegionPointsAtLeast(5))

        for level in range(13, 16):    # Levels 13-15
            self.set_rule(self.multiworld.get_location(f"Reach Level {level}", self.player),
                          RegionPointsAtLeast(7))

        for level in range(16, 19):    # Levels 16-18
            self.set_rule(self.multiworld.get_location(f"Reach Level {level}", self.player),
                          RegionPointsAtLeast(10))

        for level in range(19, 22):    # Levels 19-21
            self.set_rule(self.multiworld.get_location(f"Reach Level {level}", self.player),
                          RegionPointsAtLeast(13))

        for level in range(22, 26):    # Levels 22-25
            self.set_rule(self.multiworld.get_location(f"Reach Level {level}", self.player),
                          RegionPointsAtLeast(17))

        for level in range(26, 31):    # Levels 26-30
            self.set_rule(self.multiworld.get_location(f"Reach Level {level}", self.player),
                          RegionPointsAtLeast(22))

        for level in range(31, 41):    # Levels 31-40
            self.set_rule(self.multiworld.get_location(f"Reach Level {level}", self.player),
                          RegionPointsAtLeast(23))

        for level in range(41, 51):    # Levels 41-50
            self.set_rule(self.multiworld.get_location(f"Reach Level {level}", self.player),
                          RegionPointsAtLeast(25))

        # Exclude Levels Above code
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


        # PP Stickers Filler code (make all PP sticker checks excluded)
        if self.options.pp_stickers_filler:
            for location in self.multiworld.get_locations(self.player):
                name = location.name

                # "Photograph PP Sticker 1" to "Photograph PP Sticker 100"
                if re.match(r"Photograph PP Sticker \d+", name):
                    location.progress_type = LocationProgressType.EXCLUDED
                    continue

                # Milestone checks
                if name in {
                    "Photograph 10 PP Stickers",
                    "Photograph 20 PP Stickers",
                    "Photograph 30 PP Stickers",
                    "Photograph 40 PP Stickers",
                    "Photograph 50 PP Stickers",
                    "Photograph 60 PP Stickers",
                    "Photograph 70 PP Stickers",
                    "Photograph 80 PP Stickers",
                    "Photograph 90 PP Stickers",
                    "Photograph all PP Stickers",
                }:
                    location.progress_type = LocationProgressType.EXCLUDED

        
        # Victory condition based on goal
        goal_location_name = self.GOAL_LOCATIONS[self.options.goal.value]
        self.set_rule(self.multiworld.get_location("Victory", self.player),
                      CanReachLocation(goal_location_name))

        # Savior goal: the synthetic goal location is reachable once the
        # player can reach at least `number_of_survivors` "Rescue X" locations.
        # We capture the target in a local so the closure doesn't pay the
        # options-attribute-lookup cost on every rule evaluation.
        if self.options.goal.value == 2:
            savior_target = self.options.number_of_survivors.value
            savior_player = self.player
            savior_rescue_locations = list(self.ALL_RESCUE_LOCATIONS)

            savior_rule = AtLeast(savior_target,
                                  *[CanReachLocation(l) for l in savior_rescue_locations])

            self.set_rule(self.multiworld.get_location(self.SAVIOR_GOAL_LOCATION, self.player),
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

        # EP shutter gate. Entrance Plaza's storefronts stay closed until the
        # shutter cutscene plays, so anything inside them is unreachable even
        # once EP itself is. Defined here because both the PP-bonus rules below
        # and the sticker/survivor rules further down need it.
        # Vanilla: the shutters open during the Brad escort.
        # ScoopSanity: the EP trigger spot opens them once the player has
        # met Jessie (Warehouse reach) -- except when Backup for Brad is
        # first in the chain, where the runtime holds the trigger until the
        # Brad escort completes (the mission fires the cutscene itself).
        # Generation now keeps Backup out of the first slot, so that branch
        # is a safeguard for hand-edited orders.
        if (not self.options.scoop_sanity
                or (self.scoop_order and self.scoop_order[0] == "Backup for Brad")):
            _shutter = CanReachLocation("Escort Brad to see Dr Barnaby")
        else:
            _shutter = CanReachRegion("Warehouse")
        ep_shutter = And(CanReachRegion("Entrance Plaza"), _shutter)

        # PP-bonus rules (per-count for "counted" entries). Per-location rule
        # combines: required_regions (ALL reachable; first may be bypassed by
        # alt_item), requires_location (extra location gate, e.g. First Aid
        # Kit needs Steven), restricted_mode_items_any (in restricted
        # mode, requires ANY one of the listed items), and ep_shutter (the
        # entry sits behind Entrance Plaza's storefront shutters).
        if self.options.pp_bonus_locations:
            restricted_mode_on = bool(self.options.restricted_item_mode.value)

            def _make_rule(required_regions, alt_item, req_loc, items_any,
                           restricted_on=restricted_mode_on):
                parts = []
                # Region gating: ALL required regions must be reachable,
                # except the first can be bypassed by alt_item.
                if required_regions:
                    first = CanReachRegion(required_regions[0])
                    if alt_item:
                        first = Or(first, Has(alt_item))
                    parts.append(first)
                    parts.extend(CanReachRegion(r) for r in required_regions[1:])
                if req_loc:
                    parts.append(CanReachLocation(req_loc))
                if restricted_on and items_any:
                    parts.append(Or(*[Has(it) for it in items_any]))
                return And(*parts) if parts else True_()

            # Entries flagged ep_shutter sit inside Entrance Plaza's
            # storefronts, so reaching EP is not enough -- the shutter
            # cutscene has to have played.
            def _gate_on_shutter(inner):
                return And(ep_shutter, inner)

            for _entry in AP_TRIGGER_LOCATIONS:
                _names = expand_trigger_location_names(_entry)
                if not _names:
                    continue
                _shuttered = bool(_entry.get("ep_shutter"))
                _alt_item = _entry.get("alt_item")
                _req_loc = _entry.get("requires_location")
                _items_any = _entry.get("restricted_mode_items_any") or []
                _t = _entry.get("type")
                _max = int(_entry.get("max_count", 0))

                # A required-predecessor location may not exist this seed
                # (e.g. Savior+ScoopSanity disables MAIN_SCOOP). Drop the gate
                # gracefully when missing; region gating still applies.
                if _req_loc:
                    try:
                        self.multiworld.get_location(_req_loc, self.player)
                    except KeyError:
                        _req_loc = None

                # Zone-counted entries (region_counts): "Use n X" is
                # reachable when the reachable zones' item counts sum to n.
                # required_regions (e.g. Seon's as the microwave food
                # source) are always needed, unless one of alt_items_any
                # has been received in their place (e.g. Raw Meat /
                # Uncooked Pizza stand in for the grocery store). These
                # locations live in Security Room so the parent region
                # never blocks a zone alternative -- the rule does all the
                # gating.
                _region_counts = _entry.get("region_counts")
                if _t == "counted" and _region_counts:
                    _required = list(_entry.get("required_regions") or [])
                    _required_alts = _entry.get("alt_items_any") or []

                    def _make_count_rule(n, counts=_region_counts,
                                         required=_required,
                                         alts=_required_alts,
                                         req_loc=_req_loc,
                                         items_any=_items_any,
                                         restricted_on=restricted_mode_on):
                        parts = []
                        if required:
                            req = And(*[CanReachRegion(r) for r in required])
                            # Outside restricted mode an alt item substitutes
                            # for the required regions entirely.
                            if not restricted_on and alts:
                                req = Or(req, *[Has(it) for it in alts])
                            parts.append(req)
                        if req_loc:
                            parts.append(CanReachLocation(req_loc))
                        if restricted_on and items_any:
                            parts.append(Or(*[Has(it) for it in items_any]))
                        # Each region carries a count toward the target, so it
                        # is listed once per unit it is worth.
                        parts.append(AtLeast(n, *[CanReachRegion(r)
                                                  for r, c in counts.items()
                                                  for _ in range(c)]))
                        return And(*parts) if len(parts) > 1 else parts[0]

                    _targets = [(_names[_i], _i + 1)
                                for _i in range(min(_max, len(_names)))]
                    if len(_names) > _max:
                        _targets.append((_names[-1], sum(_region_counts.values())))
                    for _name, _n in _targets:
                        try:
                            _loc = self.multiworld.get_location(_name, self.player)
                        except KeyError:
                            continue
                        _rule = _make_count_rule(_n)
                        if _shuttered:
                            _rule = _gate_on_shutter(_rule)
                        self.set_rule(_loc, _rule)
                    continue

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
                    _rule = _make_rule(_regions, _alt_item, _req_loc, _items_any)
                    if _shuttered:
                        _rule = _gate_on_shutter(_rule)
                    self.set_rule(_loc, _rule)

        if not self.options.door_randomizer:
            # Normal key-based entrance rules. Split Keys gives each door its
            # own key as an alternative to the area key; the two systems use
            # different items, so a seed can hand out either.
            def _door(area_key, split_key):
                if self.options.split_keys:
                    return Or(Has(area_key), Has(split_key))
                return Has(area_key)

            self.set_rule(self.multiworld.get_entrance("Security Room -> Rooftop", self.player),
                          _door("Rooftop key", "Rooftop - Security Key"))
            self.set_rule(self.multiworld.get_entrance("Rooftop -> Warehouse", self.player),
                          _door("Warehouse key", "Rooftop - Warehouse Key"))
            self.set_rule(self.multiworld.get_entrance("Warehouse -> Paradise Plaza", self.player),
                          _door("Paradise Plaza key", "Paradise - Warehouse Key"))
            self.set_rule(self.multiworld.get_entrance("Paradise Plaza -> Colby's Movieland", self.player),
                          _door("Colby's Movieland key", "Colby's - Paradise Key"))
            self.set_rule(self.multiworld.get_entrance("Paradise Plaza -> Leisure Park", self.player),
                          _door("Leisure Park key", "Leisure - Paradise Key"))
            self.set_rule(self.multiworld.get_entrance("Leisure Park -> Food Court", self.player),
                          _door("Food Court key", "Food - Leisure Key"))
            self.set_rule(self.multiworld.get_entrance("Leisure Park -> North Plaza", self.player),
                          _door("North Plaza key", "Leisure - North Key"))
            self.set_rule(self.multiworld.get_entrance("Leisure Park -> Maintenance Tunnel", self.player),
                          _door("Maintenance Tunnel key", "Leisure - Maintenance Key"))
            self.set_rule(self.multiworld.get_entrance("Leisure Park -> Paradise Plaza", self.player),
                          _door("Paradise Plaza key", "Leisure - Paradise Key"))
            self.set_rule(self.multiworld.get_entrance("Food Court -> Al Fresca Plaza", self.player),
                          _door("Al Fresca Plaza key", "Food - Fresca Key"))
            self.set_rule(self.multiworld.get_entrance("Food Court -> Wonderland Plaza", self.player),
                          _door("Wonderland Plaza key", "Food - Wonderland Key"))
            self.set_rule(self.multiworld.get_entrance("Food Court -> Leisure Park", self.player),
                          _door("Leisure Park key", "Food - Leisure Key"))
            self.set_rule(self.multiworld.get_entrance("Al Fresca Plaza -> Entrance Plaza", self.player),
                          _door("Entrance Plaza key", "Entrance - Fresca Key"))
            self.set_rule(self.multiworld.get_entrance("Al Fresca Plaza -> Food Court", self.player),
                          _door("Food Court key", "Food - Fresca Key"))
            self.set_rule(self.multiworld.get_entrance("Entrance Plaza -> Al Fresca Plaza", self.player),
                          _door("Al Fresca Plaza key", "Entrance - Fresca Key"))
            self.set_rule(self.multiworld.get_entrance("Entrance Plaza -> Paradise Plaza", self.player),
                          _door("Paradise Plaza key", "Entrance - Paradise Key"))
            self.set_rule(self.multiworld.get_entrance("Wonderland Plaza -> North Plaza", self.player),
                          _door("North Plaza key", "North - Wonderland Key"))
            self.set_rule(self.multiworld.get_entrance("Wonderland Plaza -> Food Court", self.player),
                          _door("Food Court key", "Food - Wonderland Key"))
            self.set_rule(self.multiworld.get_entrance("Seon's Food and Stuff -> North Plaza", self.player),
                          _door("North Plaza key", "North - Seon's Key"))
            self.set_rule(self.multiworld.get_entrance("North Plaza -> Leisure Park", self.player),
                          _door("Leisure Park key", "Leisure - North Key"))
            self.set_rule(self.multiworld.get_entrance("North Plaza -> Wonderland Plaza", self.player),
                          _door("Wonderland Plaza key", "North - Wonderland Key"))
            self.set_rule(self.multiworld.get_entrance("North Plaza -> Seon's Food and Stuff", self.player),
                          _door("Seon's Food and Stuff key", "North - Seon's Key"))
            self.set_rule(self.multiworld.get_entrance("North Plaza -> Carlito's Hideout", self.player),
                          _door("Carlito's Hideout key", "Hideout - North Key"))
            self.set_rule(self.multiworld.get_entrance("North Plaza -> Crislip's Home Saloon", self.player),
                          _door("Crislip's Home Saloon key", "Crislip's - North Key"))

            # Split Keys gives the passage a key of its own on top of the scoop.
            _greg = CanReachLocation("Kill Adam")
            if self.options.split_keys:
                _greg = And(_greg, Has("Paradise - Wonderland Key"))
            self.set_rule(self.multiworld.get_entrance("Paradise Plaza -> Wonderland Plaza", self.player), _greg)
            self.set_rule(self.multiworld.get_entrance("Wonderland Plaza -> Paradise Plaza", self.player), _greg)
            self.set_rule(self.multiworld.get_entrance("Maintenance Tunnel -> Leisure Park", self.player),
                          _door("Leisure Park key", "Leisure - Maintenance Key"))

            # Maintenance Tunnel doors: every mall<->tunnel door needs the
            # Maintenance Tunnel key plus the Access Key -- either the AP
            # item or the physical copy inside the tunnels, which is
            # reachable through the keyless Leisure Park ramp. Mall-side
            # exits also need the destination zone's key. The tunnel-to-EP
            # exit only exists in ScoopSanity (see create_connection).
            _mt_region = self.multiworld.get_region("Maintenance Tunnel", self.player)
            _tunnel_door = And(Has("Maintenance Tunnel key"),
                               Or(Has("Maintenance Tunnel Access Key"),
                                  CanReachRegion("Maintenance Tunnel")))
            for _zone in MAINTENANCE_TUNNEL_ZONES:
                _into = self.multiworld.get_entrance(f"{_zone} -> Maintenance Tunnel", self.player)
                self.set_rule(_into, _tunnel_door)
                self.multiworld.register_indirect_condition(_mt_region, _into)
                if _zone != "Entrance Plaza" or self.options.scoop_sanity:
                    self.set_rule(self.multiworld.get_entrance(f"Maintenance Tunnel -> {_zone}", self.player),
                                  And(Has("Maintenance Tunnel key"), Has(f"{_zone} key")))
            self.set_rule(self.multiworld.get_entrance("Maintenance Tunnel -> Leisure Park", self.player), And(Has("Maintenance Tunnel key"), Has("Leisure Park key")))

            if self.options.split_keys:
                self.set_rule(self.multiworld.get_entrance("Maintenance Tunnel -> Paradise Plaza", self.player), Has("Maintenance - Paradise Key"))
                self.set_rule(self.multiworld.get_entrance("Maintenance Tunnel -> Al Fresca Plaza", self.player), Has("Fresca - Maintenance Key"))
                self.set_rule(self.multiworld.get_entrance("Maintenance Tunnel -> Food Court", self.player), Has("Food - Maintenance Key"))
                self.set_rule(self.multiworld.get_entrance("Maintenance Tunnel -> Wonderland Plaza", self.player), Has("Maintenance - Wonderland Key"))
                self.set_rule(self.multiworld.get_entrance("Maintenance Tunnel -> Seon's Food and Stuff", self.player), Has("Maintenance - Seon's Key"))
                self.set_rule(self.multiworld.get_entrance("Paradise Plaza -> Maintenance Tunnel", self.player), Has("Maintenance - Paradise Key"))
                self.set_rule(self.multiworld.get_entrance("Entrance Plaza -> Maintenance Tunnel", self.player), Has("Entrance - Maintenance Key"))
                self.set_rule(self.multiworld.get_entrance("Al Fresca Plaza -> Maintenance Tunnel", self.player), Has("Fresca - Maintenance Key"))
                self.set_rule(self.multiworld.get_entrance("Food Court -> Maintenance Tunnel", self.player), Has("Food - Maintenance Key"))
                self.set_rule(self.multiworld.get_entrance("Wonderland Plaza -> Maintenance Tunnel", self.player), Has("Maintenance - Wonderland Key"))
                self.set_rule(self.multiworld.get_entrance("Seon's Food and Stuff -> Maintenance Tunnel", self.player), Has("Maintenance - Seon's Key"))
            
            # ScoopSanity-only entrance rules:
            #   * Security Room -> Entrance Plaza requires Rooftop key +
            #     Warehouse key (the player must have been able to reach
            #     Jessie in the Warehouse for the cutscene to fire) plus
            #     Entrance Plaza key (the door itself).
            #   * Paradise Plaza -> Entrance Plaza is open from the start
            #     (key only). Not modeled in vanilla: EP access always goes
            #     through Al Fresca first, and the shutter opens during the
            #     Rescue the Professor escort, which chains behind EP reach.
            if self.options.scoop_sanity:
                if self.options.split_keys:
                    self.set_rule(self.multiworld.get_entrance("Security Room -> Entrance Plaza", self.player),
                                  And(Has("Rooftop - Security Key"), Has("Rooftop - Warehouse Key"),
                                      Has("Entrance - Security Key")))
                    self.set_rule(self.multiworld.get_entrance("Paradise Plaza -> Entrance Plaza", self.player),
                                  Has("Entrance - Paradise Key"))
                    self.set_rule(self.multiworld.get_entrance("Maintenance Tunnel -> Entrance Plaza", self.player),
                                  Has("Entrance - Maintenance Key"))
                else:
                    self.set_rule(self.multiworld.get_entrance("Security Room -> Entrance Plaza", self.player),
                                  And(Has("Rooftop key"), Has("Warehouse key"), Has("Entrance Plaza key")))
                    self.set_rule(self.multiworld.get_entrance("Paradise Plaza -> Entrance Plaza", self.player),
                                  Has("Entrance Plaza key"))

        # "Meet Jessie in the Warehouse" is a prologue main scoop that
        # always exists (see PROLOGUE_MAIN_SCOOPS). Its rule is set outside
        # the main_scoops_enabled guard so Savior+ScoopSanity still gates it
        # correctly. Other rules that reference it from within the guard are
        # fine because they only run when it's guaranteed to exist.
        self.set_rule(self.multiworld.get_location("Meet Jessie in the Warehouse", self.player), CanReachRegion("Warehouse"))

        # Events — the rest of the main-scoop completion chain. These
        # locations are MAIN_SCOOP category and don't exist when
        # Savior+ScoopSanity is active (main scoops excluded). Skip the
        # block to avoid KeyErrors from get_location on nonexistent names.
        if self.main_scoops_enabled:
            # ScoopSanity overrides this rule per-event in the SCOOP_EVENTS
            # loop below; here is the vanilla path only (story chains from
            # Meet Jessie -> walk Brad through the mall to the safe room).
            self.set_rule(self.multiworld.get_location("Complete Backup for Brad", self.player),
                          And(CanReachLocation("Meet Jessie in the Warehouse"),
                              CanReachRegion("Leisure Park"), CanReachRegion("Paradise Plaza"),
                              CanReachRegion("Food Court")))

            self.set_rule(self.multiworld.get_location("Escort Brad to see Dr Barnaby", self.player),
                          And(CanReachLocation("Complete Backup for Brad"),
                              CanReachRegion("Entrance Plaza"), CanReachRegion("Al Fresca Plaza")))

            self.set_rule(self.multiworld.get_location("Complete Temporary Agreement", self.player), CanReachLocation("Escort Brad to see Dr Barnaby"))

            if not self.options.scoop_sanity:
                self.set_rule(self.multiworld.get_location("Meet back at the Security Room at 6am day 2", self.player), And(Has("DAY2_06_AM"), CanReachLocation("Complete Temporary Agreement")))

                self.set_rule(self.multiworld.get_location("Complete Image in the Monitor", self.player), CanReachLocation("Meet back at the Security Room at 6am day 2"))

            self.set_rule(self.multiworld.get_location("Complete Rescue the Professor", self.player),
                          And(CanReachLocation("Complete Image in the Monitor"),
                              Has("Entrance - Paradise Key") if self.options.split_keys else True_()))

            self.set_rule(self.multiworld.get_location("Meet Steven", self.player), And(CanReachLocation("Complete Rescue the Professor"), CanReachRegion("North Plaza"), CanReachRegion("Seon's Food and Stuff")))

            self.set_rule(self.multiworld.get_location("Clean up... Register 6!", self.player), CanReachLocation("Meet Steven"))

            self.set_rule(self.multiworld.get_location("Complete Medicine Run", self.player), CanReachLocation("Clean up... Register 6!"))

            self.set_rule(self.multiworld.get_location("Complete Professor's Past", self.player), And(CanReachLocation("Complete Medicine Run"), Has("DAY2_06_AM"), Has("DAY2_11_AM")))

            self.set_rule(self.multiworld.get_location("Complete Girl Hunting", self.player), CanReachLocation("Complete Professor's Past"))

            self.set_rule(self.multiworld.get_location("Beat up Isabela", self.player), CanReachLocation("Complete Girl Hunting"))

            self.set_rule(self.multiworld.get_location("Complete Promise to Isabela", self.player), And(CanReachLocation("Beat up Isabela"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))

            self.set_rule(self.multiworld.get_location("Save Isabela from the zombie", self.player), CanReachLocation("Complete Promise to Isabela"))

            self.set_rule(self.multiworld.get_location("Complete Transporting Isabela", self.player), CanReachLocation("Save Isabela from the zombie"))

            self.set_rule(self.multiworld.get_location("Carry Isabela back to the Security Room", self.player), CanReachLocation("Complete Transporting Isabela"))

            self.set_rule(self.multiworld.get_location("Complete Santa Cabeza", self.player), CanReachLocation("Carry Isabela back to the Security Room"))

            if not self.options.scoop_sanity:
                self.set_rule(self.multiworld.get_location("Meet back at the Security Room at 11am day 3", self.player), And(CanReachLocation("Complete Santa Cabeza"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), Has("DAY3_11_AM")))

                self.set_rule(self.multiworld.get_location("Complete Bomb Collector", self.player), And(CanReachLocation("Meet back at the Security Room at 11am day 3"), CanReachRegion("Maintenance Tunnel")))

                self.set_rule(self.multiworld.get_location("Beat Drivin Carlito", self.player), And(CanReachLocation("Complete Bomb Collector"), CanReachRegion("Maintenance Tunnel")))

                self.set_rule(self.multiworld.get_location("Meet back at the Security Room at 5pm day 3", self.player), Or(CanReachLocation("Complete Bomb Collector"), CanReachLocation("Beat Drivin Carlito")))

                self.set_rule(self.multiworld.get_location("Escort Isabela to Carlito's Hideout and have a chat", self.player),
                              And(CanReachLocation("Meet back at the Security Room at 5pm day 3"),
                                  CanReachRegion("Carlito's Hideout"),
                                  And(Has("Paradise - Warehouse Key"), Has("Leisure - Paradise Key"), Has("Leisure - North Key"), Has("Hideout - North Key")) if self.options.split_keys else True_()))

            if self.options.scoop_sanity:
                self.multiworld.get_location("Beat Drivin Carlito", self.player).progress_type = LocationProgressType.EXCLUDED

                self.multiworld.get_location("Rescue Greg Simpson", self.player).progress_type = LocationProgressType.EXCLUDED

            self.set_rule(self.multiworld.get_location("Complete Jessie's Discovery", self.player), CanReachLocation("Escort Isabela to Carlito's Hideout and have a chat"))

            self.set_rule(self.multiworld.get_location("Meet Larry", self.player), CanReachLocation("Complete Jessie's Discovery"))

            self.set_rule(self.multiworld.get_location("Complete The Butcher", self.player), CanReachLocation("Meet Larry"))

            self.set_rule(self.multiworld.get_location("Complete Memories", self.player), CanReachLocation("Complete The Butcher"))

            if not self.options.scoop_sanity:
                self.set_rule(self.multiworld.get_location("Head back to the Security Room at the end of day 3", self.player), CanReachLocation("Complete Memories"))

                self.set_rule(self.multiworld.get_location("Witness Special Forces 10pm day 3", self.player), CanReachLocation("Complete Memories"))

            self.set_rule(self.multiworld.get_location("Ending A: Solve all of the cases and be on the helipad at 12pm", self.player), And(CanReachLocation("Complete Memories"), CanReachRegion("Heliport"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), Has("DAY3_11_AM"), Has("DAY4_12_PM")))

        # Overtime rules only apply when goal is Ending S
        if self.options.goal.value == 0:
            self.set_rule(self.multiworld.get_location("Get bit!", self.player), CanReachLocation("Ending A: Solve all of the cases and be on the helipad at 12pm"))

            self.set_rule(self.multiworld.get_location("Gather the suppressants and generator and talk to Isabela", self.player), And(CanReachLocation("Get bit!"), And(CanReachRegion("Paradise Plaza"), CanReachRegion("Entrance Plaza"), CanReachRegion("Al Fresca Plaza"), CanReachRegion("Leisure Park"), CanReachRegion("Food Court"), CanReachRegion("Maintenance Tunnel"), CanReachRegion("Wonderland Plaza"))))

            self.set_rule(self.multiworld.get_location("See the crashed helicopter", self.player), CanReachLocation("Get bit!"))

            self.set_rule(self.multiworld.get_location("Frank sees a sick-ass RC Drone", self.player), CanReachLocation("Get bit!"))

            self.set_rule(self.multiworld.get_location("Give Isabela 5 queens", self.player), CanReachLocation("Gather the suppressants and generator and talk to Isabela"))

            self.set_rule(self.multiworld.get_location("Reach the end of the tunnel with Isabela", self.player), CanReachLocation("Give Isabela 5 queens"))

            self.set_rule(self.multiworld.get_location("Get to the Humvee", self.player), And(CanReachLocation("Give Isabela 5 queens"), CanReachRegion("Tunnels")))

            self.set_rule(self.multiworld.get_location("Fight a tank and win", self.player), CanReachLocation("Get to the Humvee"))

            self.set_rule(self.multiworld.get_location("Ending S: Beat up Brock with your bare fists!", self.player), CanReachLocation("Fight a tank and win"))

            self.set_rule(self.multiworld.get_location("Kill 10 Special Forces", self.player), And(CanReachRegion("Paradise Plaza"), Has("DAY3_11_AM"), CanReachLocation("Get bit!"), CanReachLocation("Ending A: Solve all of the cases and be on the helipad at 12pm")))

            self.set_rule(self.multiworld.get_location("Kill 100 zombies with an RPG", self.player), And(CanReachRegion("Maintenance Tunnel"), CanReachLocation("Get bit!")))

        # ScoopSanity: gate every event of every scoop uniformly on item
        # received, previous scoop's completion, scoop regions, and the
        # position-level gate. Replaces the vanilla event-to-event chain so
        # randomized order can't strand events behind the vanilla predecessor.
        # Day items aren't checked -- the engine sets time flags on chain advance.
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
                    _scoop_rule = And(Has(scoop_name), CanReachLocation(prereq),
                                      *[CanReachRegion(r) for r in regions])
                    if level_req is not None:
                        _scoop_rule = And(_scoop_rule,
                                          CanReachLocation(f"Reach Level {level_req}"))
                    if self.options.split_keys:
                        _scoop_rule = And(_scoop_rule,
                                          *[Has(key) for key in
                                            SPLIT_KEY_SCOOP_DOORS.get(scoop_name, ())])
                    self.set_rule(loc, _scoop_rule)

            # Complete Memories is the post-chain anchor; gates on the last
            # randomized scoop's completion regardless of which scoop that is.
            last_completion = SCOOP_COMPLETION_MAP[self.scoop_order[-1]]
            self.set_rule(self.multiworld.get_location("Complete Memories", self.player),
                          CanReachLocation(last_completion))


        # PP STICKER LOGIC
        # PP Stickers in Paradise Plaza
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 1", self.player), CanReachRegion("Paradise Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 2", self.player), CanReachRegion("Paradise Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 3", self.player), CanReachRegion("Paradise Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 4", self.player), CanReachRegion("Paradise Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 5", self.player), CanReachRegion("Paradise Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 6", self.player), CanReachRegion("Paradise Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 7", self.player), CanReachRegion("Paradise Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 8", self.player), CanReachRegion("Paradise Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 9", self.player), CanReachRegion("Paradise Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 10", self.player), CanReachRegion("Paradise Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 11", self.player), CanReachRegion("Paradise Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 12", self.player), CanReachRegion("Paradise Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 13", self.player), CanReachRegion("Paradise Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 14", self.player), CanReachRegion("Paradise Plaza"))

        # PP Stickers in Colby's Movieland
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 15", self.player), CanReachRegion("Colby's Movieland"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 16", self.player), CanReachRegion("Colby's Movieland"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 17", self.player), CanReachRegion("Colby's Movieland"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 18", self.player), CanReachRegion("Colby's Movieland"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 19", self.player), CanReachRegion("Colby's Movieland"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 20", self.player), CanReachRegion("Colby's Movieland"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 21", self.player), CanReachRegion("Colby's Movieland"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 22", self.player), CanReachRegion("Colby's Movieland"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 23", self.player), CanReachRegion("Colby's Movieland"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 24", self.player), CanReachRegion("Colby's Movieland"))

        # PP Stickers in Entrance Plaza -- behind the shutters (25-34), as are
        # the EP survivors and Wayne's check further down. ep_shutter is
        # defined above, alongside the PP-bonus rules that also need it.
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 25", self.player), ep_shutter)
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 26", self.player), ep_shutter)
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 27", self.player), ep_shutter)
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 28", self.player), ep_shutter)
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 29", self.player), ep_shutter)
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 30", self.player), ep_shutter)
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 31", self.player), ep_shutter)
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 32", self.player), ep_shutter)
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 33", self.player), ep_shutter)
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 34", self.player), ep_shutter)

        # PP Stickers in Al Fresca Plaza
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 35", self.player), CanReachRegion("Al Fresca Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 36", self.player), CanReachRegion("Al Fresca Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 37", self.player), CanReachRegion("Al Fresca Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 38", self.player), CanReachRegion("Al Fresca Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 39", self.player), CanReachRegion("Al Fresca Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 40", self.player), CanReachRegion("Al Fresca Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 41", self.player), CanReachRegion("Al Fresca Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 42", self.player), CanReachRegion("Al Fresca Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 43", self.player), CanReachRegion("Al Fresca Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 44", self.player), CanReachRegion("Al Fresca Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 45", self.player), CanReachRegion("Al Fresca Plaza"))

        # PP Stickers in Food Court
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 46", self.player), CanReachRegion("Food Court"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 47", self.player), CanReachRegion("Food Court"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 48", self.player), CanReachRegion("Food Court"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 49", self.player), CanReachRegion("Food Court"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 50", self.player), CanReachRegion("Food Court"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 51", self.player), CanReachRegion("Food Court"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 52", self.player), CanReachRegion("Food Court"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 53", self.player), CanReachRegion("Food Court"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 54", self.player), CanReachRegion("Food Court"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 55", self.player), CanReachRegion("Food Court"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 56", self.player), CanReachRegion("Food Court"))

        # PP Stickers in Wonderland Plaza
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 57", self.player), CanReachRegion("Wonderland Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 58", self.player), CanReachRegion("Wonderland Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 59", self.player), CanReachRegion("Wonderland Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 60", self.player), CanReachRegion("Wonderland Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 61", self.player), CanReachRegion("Wonderland Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 62", self.player), CanReachRegion("Wonderland Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 63", self.player), CanReachRegion("Wonderland Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 64", self.player), CanReachRegion("Wonderland Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 65", self.player), CanReachRegion("Wonderland Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 66", self.player), CanReachRegion("Wonderland Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 67", self.player), CanReachRegion("Wonderland Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 68", self.player), CanReachRegion("Wonderland Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 69", self.player), CanReachRegion("Wonderland Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 70", self.player), CanReachRegion("Wonderland Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 71", self.player), CanReachRegion("Wonderland Plaza"))

        # PP Stickers in North Plaza
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 72", self.player), CanReachRegion("North Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 73", self.player), CanReachRegion("North Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 76", self.player), CanReachRegion("North Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 77", self.player), CanReachRegion("North Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 78", self.player), CanReachRegion("North Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 79", self.player), CanReachRegion("North Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 80", self.player), CanReachRegion("North Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 81", self.player), CanReachRegion("North Plaza"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 82", self.player), CanReachRegion("North Plaza"))

        # PP Stickers in Seon's Food and Stuff
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 83", self.player), CanReachRegion("Seon's Food and Stuff"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 84", self.player), CanReachRegion("Seon's Food and Stuff"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 85", self.player), CanReachRegion("Seon's Food and Stuff"))

        # PP Stickers in Crislip's Home Saloon
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 74", self.player), CanReachRegion("Crislip's Home Saloon"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 75", self.player), CanReachRegion("Crislip's Home Saloon"))

        # PP Stickers in Leisure Park
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 86", self.player), CanReachRegion("Leisure Park"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 87", self.player), CanReachRegion("Leisure Park"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 88", self.player), CanReachRegion("Leisure Park"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 89", self.player), CanReachRegion("Leisure Park"))

        # PP Stickers in Maintenance Tunnel
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 90", self.player), CanReachRegion("Maintenance Tunnel"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 91", self.player), CanReachRegion("Maintenance Tunnel"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 92", self.player), CanReachRegion("Maintenance Tunnel"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 93", self.player), CanReachRegion("Maintenance Tunnel"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 94", self.player), CanReachRegion("Maintenance Tunnel"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 95", self.player), CanReachRegion("Maintenance Tunnel"))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 96", self.player), CanReachRegion("Maintenance Tunnel"))

        # PP Stickers in Security Room
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 97", self.player), CanReachRegion("Security Room"))

        # PP Stickers in Cultists' Hideout
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 98", self.player), And(CanReachRegion("Paradise Plaza"), CanReachRegion("Leisure Park"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), CanReachLocation("Get grabbed by the raincoats")))
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 99", self.player), And(CanReachRegion("Paradise Plaza"), CanReachRegion("Leisure Park"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), CanReachLocation("Get grabbed by the raincoats")))

        # PP Stickers in Rooftop
        self.set_rule(self.multiworld.get_location("Photograph PP Sticker 100", self.player), CanReachRegion("Rooftop"))

        # SURVIVORS LOGIC
        # Survivors in Rooftop
        self.set_rule(self.multiworld.get_location("Rescue Jeff Meyer", self.player), CanReachRegion("Rooftop"))
        self.set_rule(self.multiworld.get_location("Rescue Natalie Meyer", self.player), CanReachRegion("Rooftop"))

        # Survivors in Paradise Plaza
        self.set_rule(self.multiworld.get_location("Rescue Heather Tompkins", self.player), And(CanReachRegion("Paradise Plaza"), (Has("Twin Sisters") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), CanReachLocation("Rescue Ross Folk"), CanReachLocation("Rescue Tonya Waters")))))
        self.set_rule(self.multiworld.get_location("Rescue Pamela Tompkins", self.player), And(CanReachRegion("Paradise Plaza"), (Has("Twin Sisters") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), CanReachLocation("Rescue Ross Folk"), CanReachLocation("Rescue Tonya Waters")))))
        self.set_rule(self.multiworld.get_location("Rescue Ronald Shiner", self.player), And(CanReachRegion("Paradise Plaza"), (Has("Orange Juice") if self.options.restricted_item_mode else True_()), (Has("Restaurant Man") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
        self.set_rule(self.multiworld.get_location("Rescue Jennifer Gorman", self.player), And(CanReachRegion("Paradise Plaza"), (Has("The Cult") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
        self.set_rule(self.multiworld.get_location("Rescue Tad Hawthorne", self.player), And(CanReachRegion("Paradise Plaza"), CanReachLocation("Kill Kent on day 3"), (And(Has("Cut from the Same Cloth"), Has("Photo Challenge"), Has("Photographer's Pride")) if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), Has("DAY3_11_AM")))))
        self.set_rule(self.multiworld.get_location("Rescue Simone Ravendark", self.player), And(CanReachRegion("Paradise Plaza"), (Has("A Woman in Despair") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), Has("DAY3_11_AM"), CanReachLocation("Complete Santa Cabeza")))))
        ## 1.1.0 HAS A BUG WITH "Rescue Simone Ravendark", THIS NEXT LINE EXCLUDES THIS CHECK IN ALL PLAY MODES AND SHOULD BE REMOVED UPON FIX BEING IMPLEMENTED
        self.multiworld.get_location("Rescue Simone Ravendark", self.player).progress_type = LocationProgressType.EXCLUDED

        # Survivors in Leisure Park
        self.set_rule(self.multiworld.get_location("Rescue Sophie Richard", self.player), And(CanReachRegion("Leisure Park"), (Has("The Convicts") if self.options.scoop_sanity else True_())))

        # Survivors in Food Court
        self.set_rule(self.multiworld.get_location("Rescue Gil Jiminez", self.player), And(CanReachRegion("Food Court"), (Has("The Drunkard") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))))

        # Survivors in Al Fresca Plaza
        self.set_rule(self.multiworld.get_location("Rescue Aaron Swoop", self.player), And(CanReachRegion("Al Fresca Plaza"), (Has("Barricade Pair") if self.options.scoop_sanity else True_())))
        self.set_rule(self.multiworld.get_location("Rescue Burt Thompson", self.player), And(CanReachRegion("Al Fresca Plaza"), (Has("Barricade Pair") if self.options.scoop_sanity else True_())))
        self.set_rule(self.multiworld.get_location("Rescue Leah Stein", self.player), And(CanReachRegion("Al Fresca Plaza"), (Has("A Mother's Lament") if self.options.scoop_sanity else True_())))
        self.set_rule(self.multiworld.get_location("Rescue Gordon Stalworth", self.player), And(CanReachRegion("Al Fresca Plaza"), (Has("The Coward") if self.options.scoop_sanity else Has("DAY2_06_AM"))))

        # Survivors in Entrance Plaza
        self.set_rule(self.multiworld.get_location("Rescue Bill Brenton", self.player), ep_shutter)
        self.set_rule(self.multiworld.get_location("Rescue Wayne Blackwell", self.player), And(ep_shutter, (Has("Mark of the Sniper") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), CanReachLocation("Meet the Hall Family")))))
        self.set_rule(self.multiworld.get_location("Rescue Jolie Wu", self.player), And(ep_shutter, (Has("The Woman Who Didn't Make it") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
        self.set_rule(self.multiworld.get_location("Rescue Rachel Decker", self.player), And(ep_shutter, (Has("The Woman Who Didn't Make it") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
        self.set_rule(self.multiworld.get_location("Rescue Floyd Sanders", self.player), And(ep_shutter, (Has("Antique Lover") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))

        # Survivors in Wonderland Plaza
        self.set_rule(self.multiworld.get_location("Rescue Greg Simpson", self.player), And(CanReachRegion("Wonderland Plaza"), CanReachRegion("Paradise Plaza"), (Has("Out of Control") if self.options.scoop_sanity else True_()))) # Greg Simpson is the only Wonderland Plaza Survivor with additional Logic due to him unlocking the shortcut
        self.set_rule(self.multiworld.get_location("Rescue Yuu Tanaka", self.player), And(CanReachRegion("Wonderland Plaza"), (Has("Book [Japanese Conversation]") if self.options.restricted_item_mode else True_()), (Has("Japanese Tourists") if self.options.scoop_sanity else True_())))
        self.set_rule(self.multiworld.get_location("Rescue Shinji Kitano", self.player), And(CanReachRegion("Wonderland Plaza"), (Has("Book [Japanese Conversation]") if self.options.restricted_item_mode else True_()), (Has("Japanese Tourists") if self.options.scoop_sanity else True_())))
        self.set_rule(self.multiworld.get_location("Rescue Tonya Waters", self.player), And(CanReachRegion("Wonderland Plaza"), (Has("Lovers") if self.options.scoop_sanity else Has("DAY2_06_AM"))))
        self.set_rule(self.multiworld.get_location("Rescue Ross Folk", self.player), And(CanReachRegion("Wonderland Plaza"), (Has("Lovers") if self.options.scoop_sanity else Has("DAY2_06_AM"))))
        self.set_rule(self.multiworld.get_location("Rescue Kay Nelson", self.player), And(CanReachRegion("Wonderland Plaza"), (Has("Above the Law") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), CanReachLocation("Kill Jo")))))
        self.set_rule(self.multiworld.get_location("Rescue Lilly Deacon", self.player), And(CanReachRegion("Wonderland Plaza"), (Has("Above the Law") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), CanReachLocation("Kill Jo")))))
        self.set_rule(self.multiworld.get_location("Rescue Kelly Carpenter", self.player), And(CanReachRegion("Wonderland Plaza"), (Has("Above the Law") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), CanReachLocation("Kill Jo")))))
        self.set_rule(self.multiworld.get_location("Rescue Janet Star", self.player), And(CanReachRegion("Wonderland Plaza"), (Has("Above the Law") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), CanReachLocation("Kill Jo")))))
        self.set_rule(self.multiworld.get_location("Rescue Sally Mills", self.player), And(CanReachRegion("Wonderland Plaza"), (Has("Hanging by a Thread") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
        self.set_rule(self.multiworld.get_location("Rescue Nick Evans", self.player), And(CanReachRegion("Wonderland Plaza"), (Has("Hanging by a Thread") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
        self.set_rule(self.multiworld.get_location("Rescue Mindy Baker", self.player), And(CanReachRegion("Wonderland Plaza"), (Has("Long Haired Punk") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), CanReachLocation("Defeat Paul")))))
        self.set_rule(self.multiworld.get_location("Rescue Debbie Willet", self.player), And(CanReachRegion("Wonderland Plaza"), (Has("Long Haired Punk") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), CanReachLocation("Defeat Paul")))))
        self.set_rule(self.multiworld.get_location("Rescue Paul Carson", self.player), And(CanReachRegion("Wonderland Plaza"), (Has("Fire Extinguisher") if self.options.restricted_item_mode else True_()), (Has("Long Haired Punk") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), CanReachLocation("Defeat Paul")))))
        self.set_rule(self.multiworld.get_location("Rescue Leroy McKenna", self.player), And(CanReachRegion("Wonderland Plaza"), (Has("A Sick Man") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))))
        self.set_rule(self.multiworld.get_location("Rescue Susan Walsh", self.player), And(CanReachRegion("Wonderland Plaza"), (Has("The Woman Left Behind") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))))

        # Survivors in North Plaza
        self.set_rule(self.multiworld.get_location("Rescue David Bailey", self.player), And(CanReachRegion("North Plaza"), (Has("Shadow of the North Plaza") if self.options.scoop_sanity else True_())))
        self.set_rule(self.multiworld.get_location("Rescue Kindell Johnson", self.player), And(CanReachRegion("North Plaza"), (Has("Dressed for Action") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))))
        self.set_rule(self.multiworld.get_location("Rescue Brett Styles", self.player), And(CanReachRegion("North Plaza"), (Has("Gun Shop Standoff") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))))
        self.set_rule(self.multiworld.get_location("Rescue Jonathan Picardson", self.player), And(CanReachRegion("North Plaza"), (Has("Gun Shop Standoff") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))))
        self.set_rule(self.multiworld.get_location("Rescue Alyssa Laurent", self.player), And(CanReachRegion("North Plaza"), (Has("Gun Shop Standoff") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))))

        # Survivors locked behind Hatchet Man (requires both North Plaza and Crislip's Home Saloon)
        self.set_rule(self.multiworld.get_location("Rescue Josh Manning", self.player), And(CanReachRegion("North Plaza"), CanReachRegion("Crislip's Home Saloon"), (Has("The Hatchet Man") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), CanReachLocation("Kill Cliff")))))
        self.set_rule(self.multiworld.get_location("Rescue Barbara Patterson", self.player), And(CanReachRegion("North Plaza"), CanReachRegion("Crislip's Home Saloon"), (Has("The Hatchet Man") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), CanReachLocation("Kill Cliff")))))
        self.set_rule(self.multiworld.get_location("Rescue Rich Atkins", self.player), And(CanReachRegion("North Plaza"), CanReachRegion("Crislip's Home Saloon"), (Has("The Hatchet Man") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), CanReachLocation("Kill Cliff")))))

        # Survivors in Colby's Movieland
        self.set_rule(self.multiworld.get_location("Rescue Beth Shrake", self.player), And(CanReachRegion("Colby's Movieland"), (Has("A Strange Group") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), CanReachLocation("Kill Sean")))))
        self.set_rule(self.multiworld.get_location("Rescue Michelle Feltz", self.player), And(CanReachRegion("Colby's Movieland"), (Has("A Strange Group") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), CanReachLocation("Kill Sean")))))
        self.set_rule(self.multiworld.get_location("Rescue Nathan Crabbe", self.player), And(CanReachRegion("Colby's Movieland"), (Has("A Strange Group") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), CanReachLocation("Kill Sean")))))
        self.set_rule(self.multiworld.get_location("Rescue Ray Mathison", self.player), And(CanReachRegion("Colby's Movieland"), (Has("A Strange Group") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), CanReachLocation("Kill Sean")))))
        self.set_rule(self.multiworld.get_location("Rescue Cheryl Jones", self.player), And(CanReachRegion("Colby's Movieland"), (Has("A Strange Group") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), CanReachLocation("Kill Sean")))))

        # Psychopaths
        self.set_rule(self.multiworld.get_location("Watch the convicts kill that poor guy", self.player), And(CanReachRegion("Leisure Park"), (Has("The Convicts") if self.options.scoop_sanity else True_())))

        self.set_rule(self.multiworld.get_location("Meet Cletus", self.player), And(CanReachRegion("North Plaza"), (Has("Cletus") if self.options.scoop_sanity else True_())))
        self.set_rule(self.multiworld.get_location("Kill Cletus", self.player), CanReachLocation("Meet Cletus"))

        self.set_rule(self.multiworld.get_location("Meet Adam", self.player), And(CanReachRegion("Wonderland Plaza"), (Has("Out of Control") if self.options.scoop_sanity else True_())))
        self.set_rule(self.multiworld.get_location("Kill Adam", self.player), CanReachLocation("Meet Adam"))

        self.set_rule(self.multiworld.get_location("Meet Cliff", self.player), And(CanReachRegion("Crislip's Home Saloon"), (Has("The Hatchet Man") if self.options.scoop_sanity else Has("DAY2_06_AM"))))
        self.set_rule(self.multiworld.get_location("Kill Cliff", self.player), CanReachLocation("Meet Cliff"))

        self.set_rule(self.multiworld.get_location("Meet Jo", self.player), And(CanReachRegion("Wonderland Plaza"), (Has("Above the Law") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
        self.set_rule(self.multiworld.get_location("Kill Jo", self.player), CanReachLocation("Meet Jo"))

        self.set_rule(self.multiworld.get_location("Meet the Hall Family", self.player), And(CanReachRegion("Entrance Plaza"), (Has("Mark of the Sniper") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
        self.set_rule(self.multiworld.get_location("Kill Roger and Jack (and Thomas if you want) and chat with Wayne", self.player), And(CanReachLocation("Meet the Hall Family"), (ep_shutter if self.options.scoop_sanity else True_())))

        self.set_rule(self.multiworld.get_location("Witness Sean in Paradise Plaza", self.player), And(CanReachRegion("Paradise Plaza"), (Or(Has("The Cult"), Has("A Strange Group")) if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
        self.set_rule(self.multiworld.get_location("Get grabbed by the raincoats", self.player), And(CanReachLocation("Witness Sean in Paradise Plaza"), CanReachRegion("Leisure Park")))
        self.set_rule(self.multiworld.get_location("Meet Sean", self.player), And(CanReachRegion("Colby's Movieland"), (Has("A Strange Group") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))))
        self.set_rule(self.multiworld.get_location("Kill Sean", self.player), CanReachLocation("Meet Sean"))

        self.set_rule(self.multiworld.get_location("Meet Paul", self.player), And(CanReachRegion("Wonderland Plaza"), (Has("Long Haired Punk") if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))))
        self.set_rule(self.multiworld.get_location("Defeat Paul", self.player), CanReachLocation("Meet Paul"))

        self.set_rule(self.multiworld.get_location("Meet Kent on day 1", self.player), And(CanReachRegion("Paradise Plaza"), (Has("Cut from the Same Cloth") if self.options.scoop_sanity else True_())))
        self.set_rule(self.multiworld.get_location("Complete Kent's day 1 photoshoot", self.player), CanReachLocation("Meet Kent on day 1"))
        self.set_rule(self.multiworld.get_location("Meet Kent on day 2", self.player), And(CanReachLocation("Complete Kent's day 1 photoshoot"), (Or(Has("Novelty Mask (Bear)"), Has("Novelty Mask (Servbot)"), Has("Novelty Mask (Horse)")) if self.options.restricted_item_mode else True_()), (And(Has("Cut from the Same Cloth"), Has("Photo Challenge")) if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
        self.set_rule(self.multiworld.get_location("Complete Kent's day 2 photoshoot", self.player), CanReachLocation("Meet Kent on day 2"))
        self.set_rule(self.multiworld.get_location("Meet Kent on day 3", self.player), And(CanReachLocation("Complete Kent's day 2 photoshoot"), (And(Has("Cut from the Same Cloth"), Has("Photo Challenge"), Has("Photographer's Pride")) if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), Has("DAY3_11_AM")))))
        self.set_rule(self.multiworld.get_location("Kill Kent on day 3", self.player), CanReachLocation("Meet Kent on day 3"))

        # Challenges
        self.set_rule(self.multiworld.get_location("Reach Level 10!", self.player), CanReachLocation("Reach Level 10"))
        self.set_rule(self.multiworld.get_location("Reach Level 20!", self.player), CanReachLocation("Reach Level 20"))
        self.set_rule(self.multiworld.get_location("Reach Level 30!", self.player), CanReachLocation("Reach Level 30"))
        self.set_rule(self.multiworld.get_location("Reach Level 40!", self.player), CanReachLocation("Reach Level 40"))
        self.set_rule(self.multiworld.get_location("Reach max level", self.player), CanReachLocation("Reach Level 50"))
        self.set_rule(self.multiworld.get_location("Kill 500 zombies by vehicle", self.player), CanReachRegion("Maintenance Tunnel"))
        self.set_rule(self.multiworld.get_location("Kill 1000 zombies by vehicle", self.player), CanReachRegion("Maintenance Tunnel"))
        all_side_scoops = SURVIVOR_SCOOP_NAMES + PSYCHOPATH_SCOOP_NAMES
        self.set_rule(self.multiworld.get_location("Get 50 survivors to join", self.player), And(CanReachRegion("Paradise Plaza"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), Has("DAY3_11_AM"), CanReachLocation("Kill Kent on day 3"), CanReachLocation("Kill Cliff"), CanReachLocation("Kill Jo"), CanReachLocation("Kill Adam"), CanReachLocation("Kill Sean"), CanReachLocation("Kill Roger and Jack (and Thomas if you want) and chat with Wayne"), CanReachLocation("Defeat Paul"), (And(HasAll(*all_side_scoops), ending_a_rule) if self.options.scoop_sanity else True_())))
        self.set_rule(self.multiworld.get_location("Encounter 10 survivors", self.player), And(CanReachRegion("Paradise Plaza"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), Has("DAY3_11_AM"), CanReachLocation("Kill Kent on day 3"), CanReachLocation("Kill Cliff"), CanReachLocation("Kill Jo"), CanReachLocation("Kill Adam"), CanReachLocation("Kill Sean"), CanReachLocation("Kill Roger and Jack (and Thomas if you want) and chat with Wayne"), CanReachLocation("Defeat Paul")))
        self.set_rule(self.multiworld.get_location("Encounter 50 survivors", self.player), And(CanReachRegion("Paradise Plaza"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), Has("DAY3_11_AM"), CanReachLocation("Kill Kent on day 3"), CanReachLocation("Kill Cliff"), CanReachLocation("Kill Jo"), CanReachLocation("Kill Adam"), CanReachLocation("Kill Sean"), CanReachLocation("Kill Roger and Jack (and Thomas if you want) and chat with Wayne"), CanReachLocation("Defeat Paul"), (And(HasAll(*all_side_scoops), ending_a_rule) if self.options.scoop_sanity else True_())))
        self.set_rule(self.multiworld.get_location("Save 10 survivors", self.player), And(CanReachRegion("Paradise Plaza"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), Has("DAY3_11_AM"), Has("DAY4_12_PM"), CanReachLocation("Kill Kent on day 3"), CanReachLocation("Kill Cliff"), CanReachLocation("Kill Jo"), CanReachLocation("Kill Adam"), CanReachLocation("Kill Sean"), CanReachLocation("Kill Roger and Jack (and Thomas if you want) and chat with Wayne"), CanReachLocation("Defeat Paul"), (And(HasAll(*all_side_scoops), ending_a_rule) if self.options.scoop_sanity else True_())))
        self.set_rule(self.multiworld.get_location("Save 50 survivors", self.player), And(CanReachRegion("Paradise Plaza"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), Has("DAY3_11_AM"), Has("DAY4_12_PM"), CanReachLocation("Kill Kent on day 3"), CanReachLocation("Kill Cliff"), CanReachLocation("Kill Jo"), CanReachLocation("Kill Adam"), CanReachLocation("Kill Sean"), CanReachLocation("Kill Roger and Jack (and Thomas if you want) and chat with Wayne"), CanReachLocation("Defeat Paul"), (And(HasAll(*all_side_scoops), ending_a_rule) if self.options.scoop_sanity else True_())))

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

        self.set_rule(self.multiworld.get_location("Kill 1000 zombies", self.player), CanReachRegion("Maintenance Tunnel"))
        self.set_rule(self.multiworld.get_location("Kill 2000 zombies", self.player), And(CanReachRegion("Maintenance Tunnel"), CanReachRegion("North Plaza"), CanReachRegion("Entrance Plaza")))
        self.set_rule(self.multiworld.get_location("Kill 5000 zombies", self.player), And(CanReachRegion("Maintenance Tunnel"), CanReachRegion("North Plaza"), CanReachRegion("Entrance Plaza"), CanReachRegion("Wonderland Plaza"), CanReachRegion("Al Fresca Plaza")))
        self.set_rule(self.multiworld.get_location("Kill 10000 zombies", self.player), And(CanReachRegion("Maintenance Tunnel"), CanReachRegion("North Plaza"), CanReachRegion("Entrance Plaza"), CanReachRegion("Wonderland Plaza"), CanReachRegion("Al Fresca Plaza"), ending_a_rule))
        self.set_rule(self.multiworld.get_location("Walk a quarter marathon", self.player), And(CanReachRegion("Leisure Park"), CanReachRegion("Al Fresca Plaza"), CanReachRegion("Wonderland Plaza"), CanReachRegion("North Plaza"), CanReachRegion("Entrance Plaza"), CanReachRegion("Food Court"), CanReachRegion("Paradise Plaza"), CanReachRegion("Seon's Food and Stuff"), CanReachRegion("Crislip's Home Saloon"), CanReachRegion("Colby's Movieland")))
        self.set_rule(self.multiworld.get_location("Destroy all of the wall plates in the Food Court", self.player), CanReachRegion("Food Court"))
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

        self.set_rule(self.multiworld.get_location("Kill 1 psychopath", self.player),
                      Or(*[CanReachLocation(n) for n in meet_psycho_names]))
        # AtLeast counts children that pass, so an encounter worth 3 psychos is
        # simply listed three times; a weight of 0 drops out on its own.
        self.set_rule(self.multiworld.get_location("Photograph 8 psychopaths", self.player),
                      AtLeast(8, *[CanReachLocation(p) for p, c in photograph_psychos for _ in range(c)]))
        self.set_rule(self.multiworld.get_location("Kill 8 psychopaths", self.player),
                      AtLeast(8, *[CanReachLocation(p) for p, c in kill_psychos for _ in range(c)]))
        self.set_rule(self.multiworld.get_location("Hit 10 zombies with a parasol", self.player), (And(Or(CanReachRegion("Entrance Plaza"), CanReachRegion("Al Fresca Plaza"), CanReachRegion("Crislip's Home Saloon")), Has("Parasol")) if self.options.restricted_item_mode else Or(CanReachRegion("Entrance Plaza"), CanReachRegion("Al Fresca Plaza"), CanReachRegion("Crislip's Home Saloon"), And(Has("Parasol"), CanReachRegion("Paradise Plaza")))))
        self.set_rule(self.multiworld.get_location("Kill 50 cultists", self.player), And(CanReachRegion("Paradise Plaza"), CanReachLocation("Witness Sean in Paradise Plaza")))
        self.set_rule(self.multiworld.get_location("Photograph 30 survivors", self.player), And(CanReachRegion("Leisure Park"), CanReachRegion("Al Fresca Plaza"), CanReachRegion("Wonderland Plaza"), CanReachRegion("North Plaza"), CanReachRegion("Entrance Plaza"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))
        self.set_rule(self.multiworld.get_location("Escort 8 survivors at once", self.player), And(CanReachRegion("Paradise Plaza"), CanReachRegion("Al Fresca Plaza"), CanReachLocation("Kill Jo"), CanReachRegion("Food Court"), CanReachRegion("Entrance Plaza"), (AtLeast(8, *[Has(s) for s, c in SCOOP_SURVIVOR_COUNTS.items() for _ in range(c[0])]) if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
        self.set_rule(self.multiworld.get_location("Frank the pimp", self.player), And(CanReachRegion("Paradise Plaza"), CanReachRegion("Al Fresca Plaza"), CanReachLocation("Kill Jo"), CanReachRegion("Food Court"), CanReachRegion("Entrance Plaza"), (AtLeast(8, *[Has(s) for s, c in SCOOP_SURVIVOR_COUNTS.items() for _ in range(c[1])]) if self.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
        self.set_rule(self.multiworld.get_location("Jump a vehicle 50 feet", self.player), CanReachRegion("Leisure Park"))
        self.set_rule(self.multiworld.get_location("Bowl over 5 zombies", self.player), (And(Or(CanReachRegion("Paradise Plaza"), CanReachRegion("Wonderland Plaza")), Has("Bowling Ball")) if self.options.restricted_item_mode else Or(CanReachRegion("Paradise Plaza"), CanReachRegion("Wonderland Plaza"), And(Has("Bowling Ball"), Or(CanReachRegion("Paradise Plaza"), CanReachRegion("Entrance Plaza"))))))
        self.set_rule(self.multiworld.get_location("Hit a golf ball 100 feet", self.player), (And(Or(CanReachRegion("Paradise Plaza"), CanReachRegion("Entrance Plaza")), Has("Golf Club")) if self.options.restricted_item_mode else Or(CanReachRegion("Paradise Plaza"), CanReachRegion("Entrance Plaza"), And(Has("Golf Club"), CanReachRegion("Rooftop")))))
        # Challenge locations default to sphere 0 via the blanket rule above.
        # Falling far enough is awkward to arrange at the start, so this one is
        # pushed behind the Warehouse instead of being an early-game filler
        # slot nobody can identify (#14).
        self.set_rule(self.multiworld.get_location("Fall from a high height", self.player), CanReachRegion("Warehouse"))
        self.set_rule(self.multiworld.get_location("Fire 30 bullets", self.player), Or(CanReachLocation("Fire 300 bullets"), And(Has("Handgun"), Or(CanReachRegion("North Plaza"), CanReachRegion("Wonderland Plaza"), CanReachRegion("Paradise Plaza"), CanReachRegion("Al Fresca Plaza"))) if self.options.restricted_item_mode else Or(CanReachRegion("North Plaza"), CanReachRegion("Wonderland Plaza"), CanReachRegion("Paradise Plaza"), CanReachRegion("Al Fresca Plaza"))))
        self.set_rule(self.multiworld.get_location("Fire 300 bullets", self.player), (And(CanReachRegion("North Plaza"), Or(*[Has(g) for g in ("Handgun", "Submachine Gun", "Shotgun", "Sniper Rifle")])) if self.options.restricted_item_mode else Or(CanReachRegion("North Plaza"), And(Or(*[Has(g) for g in ("Handgun", "Submachine Gun", "Shotgun", "Sniper Rifle", "Heavy Machinegun", "Machinegun")]), CanReachRegion("Rooftop")))))
        # "Ride zombies for 50 feet" requires Zombie Ride only when that
        # skill is actually in the AP item pool. BuildItemPool adds skills
        # only when enable_skill_items is on AND vanilla_progression is
        # "replace" (mode 1) -- under "vanilla_only" or "extra_buffs_only"
        # the engine grants skills on level-up and they aren't AP items,
        # so the location is reachable purely via region access.
        _zombie_ride_is_pool_item = bool(self.options.enable_skill_items) and self.options.vanilla_progression.value == 1
        # Whether Zombie Ride is in the pool is settled at generation time, so
        # the branch belongs here rather than inside the rule.
        _ride_rule = CanReachRegion("Maintenance Tunnel")
        if _zombie_ride_is_pool_item:
            _ride_rule = And(_ride_rule, Has("Zombie Ride"))
        self.set_rule(self.multiworld.get_location("Ride zombies for 50 feet", self.player),
                      _ride_rule)
        self.set_rule(self.multiworld.get_location("Change into 46 new outfits", self.player), And(CanReachRegion("Leisure Park"), CanReachRegion("Al Fresca Plaza"), CanReachRegion("Wonderland Plaza"), CanReachRegion("North Plaza"), CanReachRegion("Entrance Plaza"), CanReachRegion("Food Court"), CanReachRegion("Paradise Plaza"), CanReachRegion("Seon's Food and Stuff"), CanReachRegion("Crislip's Home Saloon"), CanReachRegion("Colby's Movieland")))
        self.set_rule(self.multiworld.get_location("Change into 5 new outfits", self.player), CanReachRegion("Paradise Plaza"))
        # PP Sticker group access for the "Photograph N PP Stickers"
        # challenge rules. Each group becomes (count, regions, locations,
        # predicate). The Brad-escort entry in the EP group (25-34) is a
        # marker for the EP shutter and is swapped for the mode-aware
        # ep_shutter predicate. Savior+SS additionally drops main-scoop
        # locations that don't exist in that mode.
        if not self.main_scoops_enabled:
            main_scoop_location_names = {
                loc.name
                for region_locs in location_tables.values()
                for loc in region_locs
                if loc.category == DRLocationCategory.MAIN_SCOOP
            }
        # Each group is a batch of stickers sharing one set of requirements.
        pp_sticker_group_rules = []
        for (count, regions, locs) in PP_STICKER_GROUPS:
            parts = []
            if "Escort Brad to see Dr Barnaby" in locs:
                locs = [l for l in locs if l != "Escort Brad to see Dr Barnaby"]
                parts.append(ep_shutter)
            if not self.main_scoops_enabled:
                locs = [l for l in locs if l not in main_scoop_location_names]
            parts.extend(CanReachRegion(r) for r in regions)
            parts.extend(CanReachLocation(l) for l in locs)
            pp_sticker_group_rules.append((count, And(*parts) if parts else True_()))

        # A milestone is a weighted count, so each group is listed once per
        # sticker it is worth and AtLeast does the summing.
        _sticker_children = [rule for count, rule in pp_sticker_group_rules
                             for _ in range(count)]

        for _n, _name in [
            (10, "Photograph 10 PP Stickers"), (20, "Photograph 20 PP Stickers"),
            (30, "Photograph 30 PP Stickers"), (40, "Photograph 40 PP Stickers"),
            (50, "Photograph 50 PP Stickers"), (60, "Photograph 60 PP Stickers"),
            (70, "Photograph 70 PP Stickers"), (80, "Photograph 80 PP Stickers"),
            (90, "Photograph 90 PP Stickers"), (100, "Photograph all PP Stickers"),
        ]:
            self.set_rule(self.multiworld.get_location(_name, self.player),
                          AtLeast(_n, *_sticker_children))
        self.set_rule(self.multiworld.get_location("Get 10000 PP in one photo", self.player), CanReachRegion("Rooftop"))

        self.set_rule(self.multiworld.get_location("Find Greg's secret passage", self.player), CanReachLocation("Kill Adam"))
        # Endings
        # set_rule(self.multiworld.get_location("Ending B: Don't solve all of the cases but be on the helipad at 12pm", self.player), lambda state: state.can_reach_region("Heliport", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.has("DAY4_12_PM", self.player) and state.can_reach_location("Ending S: Beat up Brock with your bare fists!", self.player))
        # set_rule(self.multiworld.get_location("Ending C: Solve all of the cases but don't meet Isabela at 10am", self.player), lambda state: state.can_reach_location("Complete Memories", self.player) and state.can_reach_region("Heliport", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.has("DAY4_12_PM", self.player) and state.can_reach_location("Ending S: Beat up Brock with your bare fists!", self.player))
        # set_rule(self.multiworld.get_location("Ending D: Be a prisoner when time runs out", self.player), lambda state: state.can_reach_location("Witness Special Forces 10pm day 3", self.player) and state.can_reach_region("Heliport", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.has("DAY4_12_PM", self.player) and state.can_reach_location("Ending S: Beat up Brock with your bare fists!", self.player))
        # set_rule(self.multiworld.get_location("Ending E: Don't solve all of the cases and don't be on the helipad at 12pm", self.player), lambda state: state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.has("DAY4_12_PM", self.player) and state.can_reach_location("Complete Backup for Brad", self.player) and state.can_reach_location("Ending S: Beat up Brock with your bare fists!", self.player))
        # set_rule(self.multiworld.get_location("Ending F: Fail to collect all of the bombs in time", self.player), lambda state: state.can_reach_location("Complete Bomb Collector", self.player))

        if not self.options.scoop_sanity:
            self.set_rule(self.multiworld.get_location("Survive until 7pm on day 1", self.player), CanReachRegion("Paradise Plaza"))

        # Victory Condition
        self.set_completion_rule(Has("Victory"))


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
        pp_stickers_filler_enabled = bool(self.options.pp_stickers_filler.value)

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
        cult_limited_enabled = bool(self.options.cult_limited.value)
        split_keys_enabled = bool(self.options.split_keys.value)
        survivor_respawn_enabled = bool(self.options.survivor_respawn.value)
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
                "cult_limited": cult_limited_enabled,
                "split_keys": split_keys_enabled,
                "survivor_respawn": survivor_respawn_enabled,
                "night_mode_enabled": night_mode_enabled,
                "hardcore_zombies_enabled": hardcore_zombies_enabled,
                "random_starting_costume": random_starting_costume,
                "costume_chaos_mode": costume_chaos_mode,
                "dlc_outfits_enabled": dlc_outfits_enabled,
                "pp_bonus_locations": pp_bonus_locations_enabled,
                "pp_stickers_filler": pp_stickers_filler_enabled,
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
            "cult_limited": cult_limited_enabled,
            "split_keys": split_keys_enabled,
            "survivor_respawn": survivor_respawn_enabled,
            "night_mode_enabled": night_mode_enabled,
            "hardcore_zombies_enabled": hardcore_zombies_enabled,
            "random_starting_costume": random_starting_costume,
            "costume_chaos_mode": costume_chaos_mode,
            "dlc_outfits_enabled": dlc_outfits_enabled,
            "pp_stickers_filler": pp_stickers_filler_enabled,
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

    def _shuffled_door_graph(self):
        """area code -> [(door_id, vanilla target, where it leads now), ...].

        A door leads wherever its redirect says, or where it always led if the
        shuffle left it alone. Sorted so a given seed always explains a route
        the same way. Built once; UT asks per hop.
        """
        if getattr(self, "_door_graph", None) is None:
            graph = {}
            for door_id in sorted(EMBEDDED_DOOR_DATA):
                door = EMBEDDED_DOOR_DATA[door_id]
                vanilla = door.get("to_area_code")
                redirect = self.door_redirects.get(door_id)
                target = redirect["target_area"] if redirect else vanilla
                graph.setdefault(door.get("from_area_code"), []).append(
                    (door_id, vanilla, target))
            self._door_graph = graph
        return self._door_graph

    def explain_path(self, entrance, state):
        """Spell out the doors to walk for one hop of /get_logical_path.

        Under door randomization the region graph stays vanilla -- every area
        key is precollected, so no entrance needs a key rule -- while the
        doors underneath move. A hop like "Warehouse -> Paradise Plaza" can
        take two or three doors through areas the path never names, so it is
        resolved against the shuffled graph rather than assumed to be one
        door. Nothing filters on reachability: with the shuffle on, every area
        is already open.

        Returning [] (falsy but not None) defers to UT's normal printing;
        None would drop the hop from the path entirely.
        """
        if not self.door_redirects:
            return []          # doors are vanilla; UT's own wording is fine

        described = NON_DOOR_ENTRANCES.get(entrance.name)
        if described is not None:
            return [{"type": "color", "color": "green", "text": entrance.name},
                    {"type": "text", "text": ": " + described}]

        src = entrance.parent_region.name if entrance.parent_region else None
        dst = entrance.connected_region.name if entrance.connected_region else None
        src_code = AREA_TO_CODE.get(src)
        dst_code = AREA_TO_CODE.get(dst)

        # Only shuffled doors can be explained from the door graph. An edge with
        # no door of its own would otherwise be answered with a route through
        # some unrelated door that happens to link the same two areas -- walkable,
        # but not the way the player was asking about, and possibly behind a key
        # they do not hold.
        if not any(d.get("from_area_code") == src_code
                   and d.get("to_area_code") == dst_code
                   for d in EMBEDDED_DOOR_DATA.values()):
            return []
        if not src_code or not dst_code:
            return []          # Menu, Level Ups, Challenges and friends

        route = self._route_between(src_code, dst_code)
        if not route:
            return []          # can't model it; better UT's wording than a guess

        steps = []
        for i, (door_id, vanilla, target) in enumerate(route):
            if door_id in self.door_redirects:
                step = f"the door that normally leads to {AREA_NAMES.get(vanilla, vanilla)}"
            else:
                step = "the usual door"
            if i < len(route) - 1:
                step += f" (into {AREA_NAMES.get(target, target)})"
            steps.append(step)

        return [
            {"type": "color", "color": "green", "text": entrance.name},
            {"type": "text", "text": ": " + ", then ".join(steps)},
        ]

    def _route_between(self, src_code, dst_code):
        """Fewest doors from one area to another, as [(door_id, vanilla, target)]."""
        from collections import deque

        graph = self._shuffled_door_graph()
        queue = deque([(src_code, [])])
        seen = {src_code}
        while queue:
            area, path = queue.popleft()
            for door_id, vanilla, target in graph.get(area, ()):
                if target == dst_code:
                    return path + [(door_id, vanilla, target)]
                if target not in seen:
                    seen.add(target)
                    queue.append((target, path + [(door_id, vanilla, target)]))
        return None

    def write_spoiler(self, spoiler_handle) -> None:
        if self.options.scoop_sanity and self.scoop_order:
            player_name = self.multiworld.get_player_name(self.player)
            spoiler_handle.write(f"\nScoopSanity Main Scoop Order ({player_name}):\n")
            for i, scoop_name in enumerate(self.scoop_order):
                spoiler_handle.write(f"  {i + 1}. {scoop_name}\n")

    def generate_output(self, output_directory: str) -> None:
        # Door map HTML is now generated on-demand by the Lua-side DoorVisualizer
        pass
