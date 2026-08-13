# world/drdr/__init__.py
import re
from typing import Any, Dict, Set, List

from BaseClasses import MultiWorld, Region, Item, Entrance, Tutorial, ItemClassification
from Options import OptionError

from worlds.AutoWorld import World, WebWorld

from .Items import DRItem, DRItemCategory, item_dictionary, key_item_names, item_descriptions, BuildItemPool, specialty_items, progression_skills, microwave_food_items, challenge_tool_items
from .Locations import (DRLocation, DRLocationCategory, location_tables,
                        location_dictionary, ZOMBIE_KILL_TIERS,
                        ZOMBIE_KILL_TIER_NAMES, zombie_kill_locations,
                        ZOMBIE_KILL_REGION_OF)
from .Options import DROption, dr_option_groups


from .DoorRandomization import (
    generate_door_randomization_for_ap, AREA_NAMES, EMBEDDED_DOOR_DATA,
    DOOR_MODE_PAIRED,
)

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
    AREA_GRAPH,
    AREA_KEY_NAMES, SPLIT_KEY_NAMES, TIME_KEY_NAMES,
    AP_TRIGGER_LOCATIONS, expand_trigger_location_names,
    SCOOPS, COMPLETION_FLAGS, SCOOP_COMPLETION_MAP, SCOOP_EVENTS,
)
from . import Rules
from .Rules import MAINTENANCE_TUNNEL_ZONES

# Main scoop names eligible for randomized ordering (ScoopSanity), in vanilla
# order. "The Facts" is main but chain-ineligible (auto-triggered after the
# chain completes). Derived from drdr_shared.json, the same file
# ScoopUnlocker.lua builds SCOOP_DATA from; _validate_shared_scoops() turns a
# name mismatch into a loud generation failure.
MAIN_SCOOP_NAMES = [
    s["name"]
    for s in sorted(
        (s for s in SCOOPS if s.get("category") == "Main" and s.get("chain_eligible")),
        key=lambda s: s.get("order", 0),
    )
]


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
            self.options.goal.value in (2, 3) and self.options.scoop_sanity
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
        # Every kill location exists in the tables so IDs stay stable; the
        # tier decides which are created.
        self.zombie_kill_tier = ZOMBIE_KILL_TIER_NAMES[
            self.options.zombie_kill_tiers.value]
        # The Genocider goal is the top tier by definition, so it forces it
        # rather than generating a seed that cannot be won.
        if self.options.goal.value == 3:
            self.zombie_kill_tier = "genocide"
        # Restricted Item Mode implies Car Keys -- the keys were asked for as
        # part of that mode, and locking every pickup while leaving the cars
        # free to drive reads as an oversight. Promoted here so the item pool,
        # the rules and slot_data all agree without repeating the condition.
        if self.options.restricted_item_mode:
            self.options.car_keys.value = 1
        _kill_active = set(zombie_kill_locations(self.zombie_kill_tier))
        self._zombie_kill_excluded_names = {
            n for n in zombie_kill_locations("genocide") if n not in _kill_active
        }
        if _kill_active:
            self.enabled_location_categories.add(DRLocationCategory.ZOMBIE_KILL)
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

        # Door Locks needs the shuffled layout in the region graph and a
        # two-way guarantee, so it is paired mode only.
        self.door_locks_active = bool(
            self.options.door_randomizer
            and self.options.door_locks
            and self.options.door_randomizer_mode.value == DOOR_MODE_PAIRED
        )

        # Door Locks gates each door by the key for the area it now leads to,
        # so the area keys are the ones that have to be in play. Split Keys
        # names door pairs instead, which the shuffle has already broken.
        # Clamped at the option rather than tracked alongside it, because the
        # item pool and the rules both read it in a dozen places and a second
        # flag would only have to agree with this one.
        self.split_keys_clamped = bool(
            self.door_locks_active and self.options.split_keys)
        if self.split_keys_clamped:
            self.options.split_keys.value = 0

        # Under ScoopSanity the mall opens off the Security Room door, and that
        # door only opens after Jessie -- who is in the Warehouse. So the route
        # to her has to be the one route the shuffle cannot move, or the seed
        # can put her key behind her own door.
        if (self.door_locks_active and self.options.scoop_sanity
                and self.options.randomize_rooftop_service_hallway_doors):
            raise OptionError(
                f"{self.player_name}: Door Locks with ScoopSanity needs the "
                "Rooftop and Warehouse doors left alone -- meeting Jessie is "
                "what opens the way into the mall, and she is behind those "
                "doors. Turn off randomize_rooftop_service_hallway_doors."
            )

        # If door randomizer is enabled, precollect all area keys
        if self.options.door_randomizer:
            # Door Locks is the exception -- the point of it is that the keys
            # still mean something, so they stay in the pool and gate the area
            # they open onto.
            if not self.door_locks_active:
                for key_name in AREA_KEY_NAMES:
                    self.multiworld.push_precollected(self.create_item(key_name))
            # The Access Key opens the tunnel doors themselves rather than an
            # area, so the shuffle has nothing to say about it either way.
            self.multiworld.push_precollected(self.create_item("Maintenance Tunnel Access Key"))
            # Split Keys rules still name the per-door keys, so hand those over
            # as well rather than leaving the rules asking for nothing
            if self.options.split_keys:
                for key_name in SPLIT_KEY_NAMES:
                    self.multiworld.push_precollected(self.create_item(key_name))

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
                elif not self.options.randomize_scoop_order:
                    # Vanilla order, so Backup for Brad leads. set_rules gates
                    # the Entrance Plaza shutter on the Brad escort in that
                    # case, and the runtime lets the mission fire the cutscene.
                    self.scoop_order = list(MAIN_SCOOP_NAMES)
                else:
                    # Backup for Brad may lead. It used to be swapped out of
                    # the first slot because its mission holds the EP shutter
                    # trigger shut, but the scoop can no longer start before
                    # its regions are reachable, and until it starts the
                    # trigger spot opens the shutters on its own.
                    scoop_order = list(MAIN_SCOOP_NAMES)
                    self.random.shuffle(scoop_order)
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
            "Meat Processing Area",
            "Carlito's Hideout",
            "Cave",
            "Level Ups",
            "Challenges",
            "Zombie Kills"
        ]})

        # Area pairs that a real door joins in the vanilla table. Under Door
        # Locks the shuffled builder owns every one of them, so the hardcoded
        # vanilla calls below have to stand down -- otherwise they re-add a
        # pair the shuffle moved, or duplicate one it already made.
        _door_backed_pairs = {
            (d.get("from_area_code"), d.get("to_area_code"))
            for d in EMBEDDED_DOOR_DATA.values()
        }
        _connected = set()

        def create_connection(from_region: str, to_region: str):
            if (from_region, to_region) in _connected:
                return
            if self.door_locks_active:
                codes = (AREA_TO_CODE.get(from_region), AREA_TO_CODE.get(to_region))
                if codes in _door_backed_pairs or codes[::-1] in _door_backed_pairs:
                    return
            _connected.add((from_region, to_region))
            connection = Entrance(self.player, f"{from_region} -> {to_region}", regions[from_region])
            regions[from_region].exits.append(connection)
            connection.connect(regions[to_region])

        def create_shuffled_connections():
            """Wire the mall from where the doors actually lead.

            Without this the region graph is the vanilla layout while the
            doors have moved, which is harmless only because every key is
            precollected. Once a door can be locked, logic has to follow it.

            Paired mode guarantees a way back, so each pair is added in both
            directions. Regions outside the door table (Menu, the Tunnels
            pseudo-region, Greg's passage) are wired by the caller as usual.
            """
            seen = set()
            for door_id, door in EMBEDDED_DOOR_DATA.items():
                src_code = door.get("from_area_code")
                redirect = self.door_redirects.get(door_id)
                dst_code = (redirect or {}).get("target_area") or door.get("to_area_code")
                a, b = AREA_NAMES.get(src_code), AREA_NAMES.get(dst_code)
                if not a or not b or a == b:
                    continue
                if a not in regions or b not in regions:
                    continue
                for x, y in ((a, b), (b, a)):
                    if (x, y) in seen:
                        continue
                    seen.add((x, y))
                    _connected.add((x, y))
                    connection = Entrance(self.player, f"{x} -> {y}", regions[x])
                    regions[x].exits.append(connection)
                    connection.connect(regions[y])
            return len(seen)

        create_connection("Menu", "Heliport")

        if self.door_locks_active:
            create_shuffled_connections()
        else:
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
        #     key + Warehouse Key (proxy for "got to Jessie") plus the
        #     Entrance Plaza Key (the door itself).
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
        # The Meat Processing Area hangs off the tunnels and nothing else.
        create_connection("Maintenance Tunnel", "Meat Processing Area")
        create_connection("Meat Processing Area", "Maintenance Tunnel")

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

        create_connection("Carlito's Hideout", "Cave")
        create_connection("Leisure Park", "Cave")

        create_connection("Menu", "Level Ups")
        create_connection("Menu", "Challenges")
        # Reached from Menu, not from the areas they name: their rules are
        # written out in Rules.py so the prologue ones can skip the area.
        create_connection("Menu", "Zombie Kills")


    GOAL_LOCATIONS = {
        0: "Ending S: Beat up Brock with your bare fists!",   # Ending S
        1: "Ending A: Solve all of the cases and be on the helipad at 12pm",  # Ending A
        2: "Savior: Rescue enough survivors to escape",        # Savior (count-based)
        3: "Zombie Genocider: Kill 53,594 zombies across the mall",
    }

    # Name of the goal location used by the Savior goal. Must match the entry
    # added at the end of location_tables["Security Room"] in Locations.py.
    SAVIOR_GOAL_LOCATION = "Savior: Rescue enough survivors to escape"

    # All "Rescue <name>" location names. Used by the Savior goal's access
    # rule and by the "Rescue N survivors" milestones to count reachable
    # survivors. Built once at class load from Locations.py.
    #
    # The milestones are themselves named "Rescue N survivors", so they are
    # excluded here -- otherwise each milestone would count itself and the
    # Savior goal would count all ten of them as survivors.
    ALL_RESCUE_LOCATIONS = [
        loc.name
        for region_locs in location_tables.values()
        for loc in region_locs
        if loc.name.startswith("Rescue ")
        and not re.fullmatch(r"Rescue \d+ survivors", loc.name)
    ]

    # EVENT-category goal locations that carry default_item="Victory". If they
    # aren't the active goal, they must be skipped entirely — otherwise the
    # EVENT branch below would create a duplicate Victory event item, which
    # would instantly satisfy the completion condition regardless of goal.
    GOAL_ONLY_EVENT_LOCATIONS = {
        "Ending S: Beat up Brock with your bare fists!",
        "Savior: Rescue enough survivors to escape",
        "Zombie Genocider: Kill 53,594 zombies across the mall",
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
                if (location.category == DRLocationCategory.ZOMBIE_KILL
                        and location.name in self._zombie_kill_excluded_names):
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
                            excluded_scoop_names=excluded_scoops,
                            door_locks_active=self.door_locks_active)

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
        elif name == "Queen" and self.options.scoop_sanity:
            # Gates queen spawning, so state.has must be able to see it.
            item_classification = ItemClassification.progression
        elif name in ("Mega Buster", "Fire Extinguisher"):
            # The RPG rule asks whether each blender ingredient is obtainable
            # in every mode -- "sent it OR can walk to it" without Restricted,
            # both with it -- so state.has must see them either way.
            item_classification = ItemClassification.progression
        elif name == "Book [Blender]":
            # Both routes to "Kill 100 zombies with an RPG" go through it, and
            # on goals without Overtime it is the only route, so state.has
            # must see it in every mode.
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
        # Security Room's stairs are never shuffled, so Rooftop Key is the
        # first gate under Door Locks too.
        if not self.options.door_randomizer or self.door_locks_active:
            self.multiworld.early_items[self.player]["Rooftop Key"] = 1

        # scoop_order is empty for Savior+ScoopSanity (main scoops excluded).
        if self.options.scoop_sanity and self.scoop_order:
            self.multiworld.early_items[self.player][self.scoop_order[0]] = 1

    def set_rules(self) -> None:
        Rules.set_rules(self)


    def _door_locks_area_graph(self) -> Dict[str, List[str]]:
        """{scene_code: [scene_code, ...]} of where the doors actually lead.

        The runtime reachability search walks the vanilla graph from shared
        data, which is harmless while nothing is locked but wrong as soon as a
        key matters. Built from the same redirects as the region graph so the
        mod and the logic agree on what the player can get to.
        """
        graph = {code: set(targets) for code, targets in AREA_GRAPH.items()}

        # Drop every vanilla door edge first -- a door the shuffle moved must
        # not leave its old edge behind, and a two-pass walk keeps a redirect
        # that lands back on a vanilla pair from erasing itself.
        for door in EMBEDDED_DOOR_DATA.values():
            src, dst = door.get("from_area_code"), door.get("to_area_code")
            for a, b in ((src, dst), (dst, src)):
                if a in graph:
                    graph[a].discard(b)

        for door_id, door in EMBEDDED_DOOR_DATA.items():
            src = door.get("from_area_code")
            redirect = self.door_redirects.get(door_id)
            dst = (redirect or {}).get("target_area") or door.get("to_area_code")
            if src and dst and src != dst:
                graph.setdefault(src, set()).add(dst)
                graph.setdefault(dst, set()).add(src)

        return {code: sorted(targets) for code, targets in sorted(graph.items()) if targets}

    def _door_locks_anchors(self) -> Dict[str, List[Dict[str, Any]]]:
        """{scene_code: [{x, z, vanilla, to}]} -- where each door stands on the
        side the player walks up to, and where it now leads.

        Door Locks disables a locked door's hit data, so the game shows no
        prompt and the overlay that names the real destination never fires --
        the player cannot see where a door goes until after they open it. The
        mod falls back to standing near the door instead, which needs a
        position per door.

        A door's recorded position is on the far side (it is where the player
        lands coming through), so the near-side spot is the reverse door's
        landing position. Checked against the two hand-captured
        Wonderland/North Plaza anchors: within 4.4 units, for doorways 93
        apart.
        """
        by_key = {(d.get("from_area_code"), d.get("to_area_code"), d.get("door_no", 0)): d
                  for d in EMBEDDED_DOOR_DATA.values()}

        out: Dict[str, List[Dict[str, Any]]] = {}
        for door_id, door in EMBEDDED_DOOR_DATA.items():
            src, vanilla = door.get("from_area_code"), door.get("to_area_code")
            door_no = door.get("door_no", 0)
            reverse = by_key.get((vanilla, src, door_no)) or by_key.get((vanilla, src, 0))
            position = (reverse or {}).get("position")
            if not (src and vanilla and position):
                continue
            redirect = self.door_redirects.get(door_id)
            actual = (redirect or {}).get("target_area") or vanilla
            out.setdefault(src, []).append({
                "x": round(position["x"], 2),
                "z": round(position["z"], 2),
                "vanilla": AREA_NAMES.get(vanilla, vanilla),
                "to": AREA_NAMES.get(actual, actual),
            })
        return out

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
        exclude_rescues_enabled = bool(self.options.exclude_rescues.value)
        # Per-region thresholds the Lua tracker sends checks at. Regions
        # with none at this tier are left out entirely.
        zombie_kill_thresholds = {
            region: list(tiers[self.zombie_kill_tier])
            for region, tiers in ZOMBIE_KILL_TIERS.items()
            if tiers[self.zombie_kill_tier]
        }
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
        any_order_enabled = bool(self.options.main_scoops_any_order.value)
        survivor_respawn_enabled = bool(self.options.survivor_respawn.value)
        overtime_gating_enabled = bool(
            self.options.overtime_progression_gating.value)
        # Hardcore implies Night — auto-enable Night when Hardcore is on so
        # the Lua side can rely on the single flag without extra logic.
        night_mode_enabled = bool(self.options.night_mode_enabled.value)
        hardcore_zombies_enabled = bool(self.options.hardcore_zombies_enabled.value)
        if hardcore_zombies_enabled:
            night_mode_enabled = True
        # 1 is vanilla; the Lua side clamps to the same maximum.
        zombie_spawn_multiplier = int(self.options.zombie_spawn_multiplier.value)
        car_keys_enabled = bool(self.options.car_keys.value)

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
                "exclude_rescues": exclude_rescues_enabled,
                "exclude_rescues_above": self.options.exclude_rescues_above.value,
                "zombie_kill_tiers": self.zombie_kill_tier,
                "enable_skill_items": enable_skill_items,
                "enable_stat_items": enable_stat_items,
                "enable_extra_stat_buffs": enable_extra_stat_buffs,
                "vanilla_progression": vanilla_progression_value,
                "trap_percentage": trap_percentage,
                "hostile_survivor_count_min": hostile_min,
                "hostile_survivor_count_max": hostile_max,
                "cult_limited": cult_limited_enabled,
                "split_keys": split_keys_enabled,
                "main_scoops_any_order": any_order_enabled,
                "survivor_respawn": survivor_respawn_enabled,
                "overtime_progression_gating": overtime_gating_enabled,
                "night_mode_enabled": night_mode_enabled,
                "hardcore_zombies_enabled": hardcore_zombies_enabled,
                "zombie_spawn_multiplier": zombie_spawn_multiplier,
                "car_keys": car_keys_enabled,
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
            "door_locks": self.door_locks_active,
            # Per-door positions so the overlay can name a destination the
            # player cannot get a prompt for. Only needed under Door Locks.
            "door_anchors": (
                self._door_locks_anchors() if self.door_locks_active else {}
            ),
            # Where the doors actually lead. Only sent under Door Locks, where
            # the vanilla graph in shared data would answer the wrong question.
            "area_graph": (
                self._door_locks_area_graph() if self.door_locks_active else {}
            ),
            # Per-scene {vanilla_dest: actual_dest} for the Lua door-prompt
            # overlay. Empty when door_randomizer is off.
            "door_overlay_data": (
                self._build_door_overlay_data() if door_randomizer_enabled else {}
            ),
            "scoop_sanity": scoop_sanity_enabled,
            "exclude_levels": exclude_levels_enabled,
            "exclude_rescues": exclude_rescues_enabled,
            "zombie_kill_tier": self.zombie_kill_tier,
            "zombie_kill_thresholds": zombie_kill_thresholds,
            "scoop_order": self.scoop_order if scoop_sanity_enabled else {},
            # Player-stats slot data (read by Lua on slot connect)
            "vanilla_progression": vanilla_progression_value,
            "trap_percentage": trap_percentage,
            "hostile_survivor_count_min": hostile_min,
            "hostile_survivor_count_max": hostile_max,
            "cult_limited": cult_limited_enabled,
            "split_keys": split_keys_enabled,
            "main_scoops_any_order": any_order_enabled,
            "survivor_respawn": survivor_respawn_enabled,
            "overtime_progression_gating": overtime_gating_enabled,
            "night_mode_enabled": night_mode_enabled,
            "hardcore_zombies_enabled": hardcore_zombies_enabled,
            "zombie_spawn_multiplier": zombie_spawn_multiplier,
            "car_keys": car_keys_enabled,
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
