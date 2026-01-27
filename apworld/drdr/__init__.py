# world/drdr/__init__.py
from typing import Dict, Set, List

from BaseClasses import MultiWorld, Region, Item, Entrance, Tutorial, ItemClassification

from worlds.AutoWorld import World, WebWorld
from worlds.generic.Rules import set_rule, add_rule, add_item_rule, forbid_item

from .Items import DRItem, DRItemCategory, item_dictionary, key_item_names, item_descriptions, BuildItemPool
from .Locations import DRLocation, DRLocationCategory, location_tables, location_dictionary
from .Options import DROption

class DRWeb(WebWorld):
    bug_report_page = ""
    theme = "stone"
    setup_en = Tutorial(
        "Multiworld Setup Guide",
        "A guide to setting up the Archipelago Dead Rising Deluxe Remaster randomizer on your computer.",
        "English",
        "setup_en.md",
        "setup/en",
        ["ArsonAssassin"]
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

    def generate_early(self):
        self.enabled_location_categories.add(DRLocationCategory.SURVIVOR)
        self.enabled_location_categories.add(DRLocationCategory.LEVEL_UP)
        self.enabled_location_categories.add(DRLocationCategory.PP_STICKER)
        self.enabled_location_categories.add(DRLocationCategory.MAIN_SCOOP)
        self.enabled_location_categories.add(DRLocationCategory.OVERTIME_SCOOP)
        self.enabled_location_categories.add(DRLocationCategory.PSYCHO_SCOOP)
        self.enabled_location_categories.add(DRLocationCategory.CHALLENGE)

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
        create_connection("Paradise Plaza", "Entrance Plaza")
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


    # For each region, add the associated locations retrieved from the corresponding location_table
    def create_region(self, region_name, location_table) -> Region:
        new_region = Region(region_name, self.player, self.multiworld)
        for location in location_table:
            if location.category in self.enabled_location_categories:
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
                # Skip Victory here - we'll handle it explicitly in create_items
                if location.name == "Ending S: Beat up Brock with your bare fists!":
                    # Create the location but don't place an item yet
                    new_location = DRLocation(
                        self.player,
                        location.name,
                        location.category,
                        location.default_item,
                        None,
                        new_region
                    )
                    new_region.locations.append(new_location)
                else:
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

        for location in self.multiworld.get_locations(self.player):
                item_data = item_dictionary[location.default_item_name]
                if item_data.category in [DRItemCategory.SKIP] or \
                        location.category in [DRLocationCategory.EVENT]:
                    # Skip the Ending S location - we handle Victory placement separately
                    if location.name == "Ending S: Beat up Brock with your bare fists!":
                        continue
                    item = self.create_item(location.default_item_name)
                    self.multiworld.get_location(location.name, self.player).place_locked_item(item)
                elif location.category in self.enabled_location_categories:
                    itempoolSize += 1

        # Place Victory event at the goal location
        self.get_location("Ending S: Beat up Brock with your bare fists!").place_locked_item(self.create_event("Victory"))

        foo = BuildItemPool(self.multiworld, itempoolSize, self.options)

        for item in foo:
            itempool.append(self.create_item(item.name))

        # Add regular items to itempool
        self.multiworld.itempool += itempool



    def create_item(self, name: str) -> Item:
        useful_categories = []
        data = self.item_name_to_id[name]

        if name in key_item_names or item_dictionary[name].category == DRItemCategory.LOCK:
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

    def set_rules(self) -> None:

        def set_indirect_rule(self, regionName, rule):
            region = self.multiworld.get_region(regionName, self.player)
            entrance = self.multiworld.get_entrance(regionName, self.player)
            set_rule(entrance, rule)
            self.multiworld.register_indirect_condition(region, entrance)

        #print("Setting rules")
        for region in self.multiworld.get_regions(self.player):
            for location in region.locations:
                    set_rule(location, lambda state: True)

        for level in range(3, 51):
            current_level_location = f"Reach Level {level}"
            previous_level_location = f"Reach Level {level - 1}"
            set_rule(self.multiworld.get_location(current_level_location, self.player), lambda state, prev=previous_level_location: state.can_reach_location(prev, self.player))

        # Areas unlocked by keys
        set_rule(self.multiworld.get_location("Victory", self.player), lambda state: state.can_reach_location("Ending S: Beat up Brock with your bare fists!", self.player))
        set_rule(self.multiworld.get_entrance("Safe Room -> Rooftop", self.player), lambda state: state.has("Rooftop key", self.player))
        set_rule(self.multiworld.get_entrance("Rooftop -> Service Hallway", self.player), lambda state: state.has("Service Hallway key", self.player))
        set_rule(self.multiworld.get_entrance("Service Hallway -> Paradise Plaza", self.player), lambda state: state.has("Paradise Plaza key", self.player))
        set_rule(self.multiworld.get_entrance("Paradise Plaza -> Colby's Movie Theater", self.player), lambda state: state.has("Colby's Movie Theater key", self.player))
        set_rule(self.multiworld.get_entrance("Paradise Plaza -> Leisure Park", self.player), lambda state: state.has("Leisure Park key", self.player))
        # set_rule(self.multiworld.get_entrance("Paradise Plaza -> Entrance Plaza", self.player), lambda state: state.has("Entrance Plaza key", self.player))
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

        set_rule(self.multiworld.get_location("Complete Backup for Brad", self.player), lambda state: state.can_reach_location("Meet Jessie in the Service Hallway", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Paradise Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.has("Food Court key", self.player))

        set_rule(self.multiworld.get_location("Escort Brad to see Dr Barnaby", self.player), lambda state: state.can_reach_location("Complete Backup for Brad", self.player) and state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.has("Entrance Plaza key", self.player))

        set_rule(self.multiworld.get_location("Complete Temporary Agreement", self.player), lambda state: state.can_reach_location("Escort Brad to see Dr Barnaby", self.player))

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

        set_rule(self.multiworld.get_location("Meet back at the safe room at 11am day 3", self.player), lambda state: state.can_reach_location("Complete Santa Cabeza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player))

        set_rule(self.multiworld.get_location("Complete Bomb Collector", self.player), lambda state: state.can_reach_location("Meet back at the safe room at 11am day 3", self.player) and state.can_reach_region("Maintenance Tunnel", self.player))

        set_rule(self.multiworld.get_location("Beat Drivin Carlito", self.player), lambda state: state.can_reach_location("Meet back at the safe room at 11am day 3", self.player) and state.can_reach_region("Maintenance Tunnel", self.player))

        set_rule(self.multiworld.get_location("Meet back at the safe room at 5pm day 3", self.player), lambda state: state.can_reach_location("Complete Bomb Collector", self.player) or state.can_reach_location("Beat Drivin Carlito", self.player))

        set_rule(self.multiworld.get_location("Escort Isabela to the Hideout and have a chat", self.player), lambda state: state.can_reach_location("Meet back at the safe room at 5pm day 3", self.player) and state.can_reach_region("Hideout", self.player))

        set_rule(self.multiworld.get_location("Complete Jessie's Discovery", self.player), lambda state: state.can_reach_location("Escort Isabela to the Hideout and have a chat", self.player))

        set_rule(self.multiworld.get_location("Meet Larry", self.player), lambda state: state.can_reach_location("Complete Jessie's Discovery", self.player))

        set_rule(self.multiworld.get_location("Complete The Butcher", self.player), lambda state: state.can_reach_location("Meet Larry", self.player))

        set_rule(self.multiworld.get_location("Complete Memories", self.player), lambda state: state.can_reach_location("Complete The Butcher", self.player))

        set_rule(self.multiworld.get_location("Head back to the safe room at the end of day 3", self.player), lambda state: state.can_reach_location("Complete Memories", self.player))

        set_rule(self.multiworld.get_location("Witness Special Forces 10pm day 3", self.player), lambda state: state.can_reach_location("Complete Memories", self.player))

        set_rule(self.multiworld.get_location("Ending A: Solve all of the cases and be on the helipad at 12pm", self.player), lambda state: state.can_reach_location("Complete Memories", self.player) and state.can_reach_region("Helipad", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.has("DAY4_12_PM", self.player))

        set_rule(self.multiworld.get_location("Get bit!", self.player), lambda state: state.can_reach_location("Ending A: Solve all of the cases and be on the helipad at 12pm", self.player))

        set_rule(self.multiworld.get_location("Gather the suppressants and generator and talk to Isabela", self.player), lambda state: state.can_reach_location("Get bit!", self.player) and (state.can_reach_region("Paradise Plaza", self.player) and state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Maintenance Tunnel", self.player) and state.can_reach_region("Wonderland Plaza", self.player)))

        set_rule(self.multiworld.get_location("See the crashed helicopter", self.player), lambda state: state.can_reach_location("Get bit!", self.player))

        set_rule(self.multiworld.get_location("Give Isabela 5 queens", self.player), lambda state: state.can_reach_location("Gather the suppressants and generator and talk to Isabela", self.player))

        set_rule(self.multiworld.get_location("Get to the humvee", self.player), lambda state: state.can_reach_location("Give Isabela 5 queens", self.player) and state.can_reach_region("Tunnels", self.player))

        set_rule(self.multiworld.get_location("Fight a tank and win", self.player), lambda state: state.can_reach_location("Get to the humvee", self.player))

        set_rule(self.multiworld.get_location("Ending S: Beat up Brock with your bare fists!", self.player), lambda state: state.can_reach_location("Fight a tank and win", self.player))

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
        set_rule(self.multiworld.get_location("Photograph PP Sticker 98", self.player), lambda state: state.can_reach_region("Leisure Park", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.can_reach_location("Get grabbed by the raincoats", self.player))
        set_rule(self.multiworld.get_location("Photograph PP Sticker 99", self.player), lambda state: state.can_reach_region("Leisure Park", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.can_reach_location("Get grabbed by the raincoats", self.player))
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

        set_rule(self.multiworld.get_location("Rescue Heather Tompkins", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.can_reach_location("Rescue Ross Folk", self.player) and state.can_reach_location("Rescue Tonya Waters", self.player))
        set_rule(self.multiworld.get_location("Rescue Pamela Tompkins", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.can_reach_location("Rescue Ross Folk", self.player) and state.can_reach_location("Rescue Tonya Waters", self.player))
        set_rule(self.multiworld.get_location("Rescue Ronald Shiner", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("Orange Juice", self.player))
        set_rule(self.multiworld.get_location("Rescue Jennifer Gorman", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player))
        set_rule(self.multiworld.get_location("Rescue Tad Hawthorne", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.can_reach_location("Kill Kent on day 3", self.player))
        set_rule(self.multiworld.get_location("Rescue Simone Ravendark", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player))

        set_rule(self.multiworld.get_location("Rescue Sophie Richard", self.player), lambda state: state.can_reach_region("Leisure Park", self.player))

        set_rule(self.multiworld.get_location("Rescue Gil Jiminez", self.player), lambda state: state.can_reach_region("Food Court", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player))

        set_rule(self.multiworld.get_location("Rescue Aaron Swoop", self.player), lambda state: state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Rescue Burt Thompson", self.player), lambda state: state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Rescue Leah Stein", self.player), lambda state: state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Rescue Gordon Stalworth", self.player), lambda state: state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player) and state.has("DAY2_06_AM", self.player))

        set_rule(self.multiworld.get_location("Rescue Bill Brenton", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Rescue Wayne Blackwell", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.can_reach_location("Meet the Hall family", self.player))
        set_rule(self.multiworld.get_location("Rescue Jolie Wu", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player))
        set_rule(self.multiworld.get_location("Rescue Rachel Decker", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player))
        set_rule(self.multiworld.get_location("Rescue Floyd Sanders", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Leisure Park", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player))

        set_rule(self.multiworld.get_location("Rescue Greg Simpson",  self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)))
        set_rule(self.multiworld.get_location("Rescue Yuu Tanaka", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.has("Book [Japanese Conversation]", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)))
        set_rule(self.multiworld.get_location("Rescue Shinji Kitano", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.has("Book [Japanese Conversation]", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)))
        set_rule(self.multiworld.get_location("Rescue Tonya Waters", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)) and state.has("DAY2_06_AM", self.player))
        set_rule(self.multiworld.get_location("Rescue Ross Folk", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)) and state.has("DAY2_06_AM", self.player))
        set_rule(self.multiworld.get_location("Rescue Kay Nelson", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.can_reach_location("Kill Jo", self.player))
        set_rule(self.multiworld.get_location("Rescue Lilly Deacon", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.can_reach_location("Kill Jo", self.player))
        set_rule(self.multiworld.get_location("Rescue Kelly Carpenter", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.can_reach_location("Kill Jo", self.player))
        set_rule(self.multiworld.get_location("Rescue Janet Star", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.can_reach_location("Kill Jo", self.player))
        set_rule(self.multiworld.get_location("Rescue Sally Mills", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player))
        set_rule(self.multiworld.get_location("Rescue Nick Evans", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player))
        set_rule(self.multiworld.get_location("Rescue Mindy Baker", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.can_reach_location("Defeat Paul", self.player))
        set_rule(self.multiworld.get_location("Rescue Debbie Willet", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and (state.can_reach_region("Food Court", self.player) or state.can_reach_region("North Plaza", self.player)) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.can_reach_location("Defeat Paul", self.player))
        set_rule(self.multiworld.get_location("Rescue Paul Carson", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.can_reach_location("Defeat Paul", self.player) and state.has("Fire Extinguisher", self.player))
        set_rule(self.multiworld.get_location("Rescue Leroy McKenna", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player))
        set_rule(self.multiworld.get_location("Rescue Susan Walsh", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player))

        set_rule(self.multiworld.get_location("Rescue David Bailey", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Rescue Josh Manning", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.has("DAY2_06_AM", self.player) and state.can_reach_location("Kill Cliff", self.player))
        set_rule(self.multiworld.get_location("Rescue Barbara Patterson", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.has("DAY2_06_AM", self.player) and state.can_reach_location("Kill Cliff", self.player))
        set_rule(self.multiworld.get_location("Rescue Rich Atkins", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.has("DAY2_06_AM", self.player) and state.can_reach_location("Kill Cliff", self.player))
        set_rule(self.multiworld.get_location("Rescue Kindell Johnson", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player))
        set_rule(self.multiworld.get_location("Rescue Brett Styles", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player))
        set_rule(self.multiworld.get_location("Rescue Jonathan Picardson", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player))
        set_rule(self.multiworld.get_location("Rescue Alyssa Laurent", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player))

        set_rule(self.multiworld.get_location("Rescue Beth Shrake", self.player), lambda state: state.can_reach_region("Colby's Movie Theater", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.can_reach_location("Kill Sean", self.player))
        set_rule(self.multiworld.get_location("Rescue Michelle Feltz", self.player), lambda state: state.can_reach_region("Colby's Movie Theater", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.can_reach_location("Kill Sean", self.player))
        set_rule(self.multiworld.get_location("Rescue Nathan Crabbe", self.player), lambda state: state.can_reach_region("Colby's Movie Theater", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.can_reach_location("Kill Sean", self.player))
        set_rule(self.multiworld.get_location("Rescue Ray Mathison", self.player), lambda state: state.can_reach_region("Colby's Movie Theater", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.can_reach_location("Kill Sean", self.player))
        set_rule(self.multiworld.get_location("Rescue Cheryl Jones", self.player), lambda state: state.can_reach_region("Colby's Movie Theater", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.can_reach_location("Kill Sean", self.player))

        # Psychopaths
        set_rule(self.multiworld.get_location("Watch the convicts kill that poor guy", self.player), lambda state: state.can_reach_region("Leisure Park", self.player))

        set_rule(self.multiworld.get_location("Meet Cletus", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Kill Cletus", self.player), lambda state: state.can_reach_location("Meet Cletus", self.player))

        set_rule(self.multiworld.get_location("Meet Adam", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player))
        set_rule(self.multiworld.get_location("Kill Adam", self.player), lambda state: state.can_reach_location("Meet Adam", self.player))

        set_rule(self.multiworld.get_location("Meet Cliff", self.player), lambda state: state.can_reach_region("Crislip's Hardware Store", self.player) and state.has("DAY2_06_AM", self.player))
        set_rule(self.multiworld.get_location("Kill Cliff", self.player), lambda state: state.can_reach_location("Meet Cliff", self.player))

        set_rule(self.multiworld.get_location("Meet Jo", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player))
        set_rule(self.multiworld.get_location("Kill Jo", self.player), lambda state: state.can_reach_location("Meet Jo", self.player))

        set_rule(self.multiworld.get_location("Meet the Hall family", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player))
        set_rule(self.multiworld.get_location("Kill Roger and Jack (and Thomas if you want) and chat with Wayne", self.player), lambda state: state.can_reach_location("Meet the Hall family", self.player))

        set_rule(self.multiworld.get_location("Witness Sean in Paradise Plaza", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player))
        set_rule(self.multiworld.get_location("Get grabbed by the raincoats", self.player), lambda state: state.can_reach_location("Witness Sean in Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Meet Sean", self.player), lambda state: state.can_reach_region("Colby's Movie Theater", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player))
        set_rule(self.multiworld.get_location("Kill Sean", self.player), lambda state: state.can_reach_location("Meet Sean", self.player))

        set_rule(self.multiworld.get_location("Meet Paul", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player))
        set_rule(self.multiworld.get_location("Defeat Paul", self.player), lambda state: state.can_reach_location("Meet Paul", self.player))

        set_rule(self.multiworld.get_location("Meet Kent on day 1", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Complete Kent's day 1 photoshoot", self.player), lambda state: state.can_reach_location("Meet Kent on day 1", self.player))
        set_rule(self.multiworld.get_location("Meet Kent on day 2", self.player), lambda state: state.can_reach_location("Complete Kent's day 1 photoshoot", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player))
        set_rule(self.multiworld.get_location("Complete Kent's day 2 photoshoot", self.player), lambda state: state.can_reach_location("Meet Kent on day 2", self.player))
        set_rule(self.multiworld.get_location("Meet Kent on day 3", self.player), lambda state: state.can_reach_location("Complete Kent's day 2 photoshoot", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player))
        set_rule(self.multiworld.get_location("Kill Kent on day 3", self.player), lambda state: state.can_reach_location("Meet Kent on day 3", self.player))

        # Challenges
        set_rule(self.multiworld.get_location("Reach max level", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player))
        set_rule(self.multiworld.get_location("Kill 500 zombies by hand", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player))
        set_rule(self.multiworld.get_location("Kill 500 zombies by vehicle", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player))
        set_rule(self.multiworld.get_location("Get 50 survivors to join", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.can_reach_location("Kill Kent on day 3", self.player) and state.can_reach_location("Kill Cliff", self.player) and state.can_reach_location("Kill Jo", self.player) and state.can_reach_location("Kill Adam", self.player) and state.can_reach_location("Kill Sean", self.player) and state.can_reach_location("Kill Roger and Jack (and Thomas if you want) and chat with Wayne", self.player) and state.can_reach_location("Defeat Paul", self.player))
        set_rule(self.multiworld.get_location("Encounter 50 survivors", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.can_reach_location("Kill Kent on day 3", self.player) and state.can_reach_location("Kill Cliff", self.player) and state.can_reach_location("Kill Jo", self.player) and state.can_reach_location("Kill Adam", self.player) and state.can_reach_location("Kill Sean", self.player) and state.can_reach_location("Kill Roger and Jack (and Thomas if you want) and chat with Wayne", self.player) and state.can_reach_location("Defeat Paul", self.player))
        set_rule(self.multiworld.get_location("Kill 10000 zombies", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player))
        set_rule(self.multiworld.get_location("Zombie Genocide", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player))
        set_rule(self.multiworld.get_location("Kill 10 Special Forces", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and state.has("DAY3_11_AM"))
        set_rule(self.multiworld.get_location("Destroy 30 dishes in the Food Court", self.player), lambda state: state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Spend 12 hours outdoors", self.player), lambda state: state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Kill 1 psychopath", self.player), lambda state: state.can_reach_location("Meet Cletus", self.player) or state.can_reach_location("Meet Adam", self.player) or state.can_reach_location("Meet Sean", self.player) or state.can_reach_location("Meet Jo", self.player) or state.can_reach_location("Meet Cliff", self.player) or state.can_reach_location("Meet Paul", self.player) or state.can_reach_location("Meet Steven", self.player) or state.can_reach_location("Meet Larry", self.player) or state.can_reach_location("Meet Kent on day 3", self.player))
        set_rule(self.multiworld.get_location("Kill 8 psychopaths", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.can_reach_location("Kill Kent on day 3", self.player) and state.can_reach_location("Kill Cliff", self.player) and state.can_reach_location("Kill Jo", self.player) and state.can_reach_location("Kill Adam", self.player) and state.can_reach_location("Kill Sean", self.player) and state.can_reach_location("Kill Roger and Jack (and Thomas if you want) and chat with Wayne", self.player) and state.can_reach_location("Defeat Paul", self.player))
        set_rule(self.multiworld.get_location("Hit 10 zombies with a parasol", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player) or state.can_reach_region("Al Fresca Plaza", self.player))
        set_rule(self.multiworld.get_location("Kill 100 cultists", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and state.can_reach_location("Witness Sean in Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Kill 100 zombies with an RPG", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player) and state.can_reach_location("Witness Special Forces 10pm day 3"))
        set_rule(self.multiworld.get_location("Photograph 30 survivors", self.player), lambda state: state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Entrance Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player))
        set_rule(self.multiworld.get_location("Build a profile for 87 survivors", self.player), lambda state: state.can_reach_location("Meet Larry", self.player) and state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Entrance Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player))
        set_rule(self.multiworld.get_location("Photograph all PP Stickers", self.player), lambda state: state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Paradise Plaza", self.player) and state.can_reach_region("Grocery Store", self.player) and state.can_reach_region("Crislip's Hardware Store", self.player) and state.can_reach_region("Colby's Movie Theater", self.player))
        set_rule(self.multiworld.get_location("Frank the pimp", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_location("Kill Jo", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Entrance Plaza", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player))
        set_rule(self.multiworld.get_location("Jump a vehicle 50 feet", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player))
        set_rule(self.multiworld.get_location("Bowl over 10 zombies", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player))
        set_rule(self.multiworld.get_location("Hit a golf ball 100 feet", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player))
        set_rule(self.multiworld.get_location("Fire 300 bullets", self.player), lambda state: state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Ride zombies for 50 feet", self.player), lambda state: state.can_reach_region("Maintenance Tunnel", self.player))
        set_rule(self.multiworld.get_location("Change into 50 new outfits", self.player), lambda state: state.can_reach_region("Leisure Park", self.player) and state.can_reach_region("Al Fresca Plaza", self.player) and state.can_reach_region("Wonderland Plaza", self.player) and state.can_reach_region("North Plaza", self.player) and state.can_reach_region("Entrance Plaza", self.player) and state.can_reach_region("Food Court", self.player) and state.can_reach_region("Paradise Plaza", self.player) and state.can_reach_region("Grocery Store", self.player) and state.can_reach_region("Crislip's Hardware Store", self.player) and state.can_reach_region("Colby's Movie Theater", self.player))
        set_rule(self.multiworld.get_location("Change into 5 new outfits", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Get 10000 PP in one photo", self.player), lambda state: state.can_reach_location("Photograph all PP Stickers", self.player))

        # Endings
        # set_rule(self.multiworld.get_location("Ending B: Don't solve all of the cases but be on the helipad at 12pm", self.player), lambda state: state.can_reach_region("Helipad", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.has("DAY4_12_PM", self.player) and state.can_reach_location("Ending S: Beat up Brock with your bare fists!", self.player))
        # set_rule(self.multiworld.get_location("Ending C: Solve all of the cases but don't meet Isabela at 10am", self.player), lambda state: state.can_reach_location("Complete Memories", self.player) and state.can_reach_region("Helipad", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.has("DAY4_12_PM", self.player) and state.can_reach_location("Ending S: Beat up Brock with your bare fists!", self.player))
        # set_rule(self.multiworld.get_location("Ending D: Be a prisoner when time runs out", self.player), lambda state: state.can_reach_location("Witness Special Forces 10pm day 3", self.player) and state.can_reach_region("Helipad", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.has("DAY4_12_PM", self.player) and state.can_reach_location("Ending S: Beat up Brock with your bare fists!", self.player))
        # set_rule(self.multiworld.get_location("Ending E: Don't solve all of the cases and don't be on the helipad at 12pm", self.player), lambda state: state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.has("DAY4_12_PM", self.player) and state.can_reach_location("Complete Backup for Brad", self.player) and state.can_reach_location("Ending S: Beat up Brock with your bare fists!", self.player))
        # set_rule(self.multiworld.get_location("Ending F: Fail to collect all of the bombs in time", self.player), lambda state: state.can_reach_location("Complete Bomb Collector", self.player))

        # Simple, until spheres are in place
        set_rule(self.multiworld.get_location("Reach Level 7", self.player), lambda state: state.can_reach_region("Rooftop", self.player))
        set_rule(self.multiworld.get_location("Reach Level 10", self.player), lambda state: state.can_reach_region("Paradise Plaza", self.player))
        set_rule(self.multiworld.get_location("Reach Level 15", self.player), lambda state: state.can_reach_region("Leisure Park", self.player))
        set_rule(self.multiworld.get_location("Reach Level 17", self.player), lambda state: state.can_reach_region("Food Court", self.player))
        set_rule(self.multiworld.get_location("Reach Level 20", self.player), lambda state: state.can_reach_region("Entrance Plaza", self.player))
        set_rule(self.multiworld.get_location("Reach Level 23", self.player), lambda state: state.can_reach_region("Grocery Store", self.player))
        set_rule(self.multiworld.get_location("Reach Level 25", self.player), lambda state: state.can_reach_region("Wonderland Plaza", self.player))
        set_rule(self.multiworld.get_location("Reach Level 30", self.player), lambda state: state.can_reach_location("Ending S: Beat up Brock with your bare fists!", self.player))
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

        death_link_enabled = bool(self.options.death_link.value)
        restricted_item_mode_enabled = bool(self.options.restricted_item_mode.value)

        slot_data = {
            "options": {
                "guaranteed_items": self.options.guaranteed_items.value,
                "death_link": death_link_enabled,  # optional (debug/UI)
                "restricted_item_mode": restricted_item_mode_enabled,  # optional (debug/UI)
            },
            "death_link": death_link_enabled,  # IMPORTANT: what Lua will read
            "restricted_item_mode": restricted_item_mode_enabled,  # IMPORTANT: what Lua will read for item restrictions
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