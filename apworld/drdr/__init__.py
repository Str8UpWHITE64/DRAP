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

    def create_regions(self):
        # Create Regions
        regions: Dict[str, Region] = {}
        regions["Menu"] = self.create_region("Menu", [])
        regions.update({region_name: self.create_region(region_name, location_tables[region_name]) for region_name in [
            "Safe Room",
            "Entrance Plaza",
            "Rooftop",
            "Service Hallway",
            "Paradise Plaza",
            "Colby's Movieland",
            "Leisure Park",
            "Food Court",
            "Al Fresca Plaza",
            "Wonderland Plaza",
            "North Plaza",
            "Grocery Store",
            "Crislip's Hardware Store",
            "Level Ups"
        ]})

        # Connect Regions
        def create_connection(from_region: str, to_region: str):
            connection = Entrance(self.player, f"{from_region} -> {to_region}", regions[from_region])
            regions[from_region].exits.append(connection)
            connection.connect(regions[to_region])
            #print(f"Connecting {from_region} to {to_region} Using entrance: " + connection.name)

        create_connection("Menu", "Safe Room")
        create_connection("Safe Room", "Rooftop")
        create_connection("Rooftop", "Service Hallway")
        create_connection("Service Hallway", "Paradise Plaza")

        create_connection("Paradise Plaza", "Colby's Movieland")
        create_connection("Paradise Plaza", "Entrance Plaza")
        create_connection("Paradise Plaza", "Leisure Park")

        create_connection("Entrance Plaza", "Al Fresca Plaza")
        create_connection("Al Fresca Plaza", "Food Court")
        create_connection("Food Court", "Wonderland Plaza")
        create_connection("Wonderland Plaza", "North Plaza") 

        create_connection("Leisure Park", "Food Court")
        create_connection("Leisure Park", "North Plaza")     

        create_connection("North Plaza", "Grocery Store")   
        create_connection("North Plaza", "Crislip's Hardware Store")    

        create_connection("Menu", "Level Ups")
        
        
    # For each region, add the associated locations retrieved from the corresponding location_table
    def create_region(self, region_name, location_table) -> Region:
        new_region = Region(region_name, self.player, self.multiworld)
        #print("location table size: " + str(len(location_table)))
        for location in location_table:
            #print("Creating location: " + location.name)
            if location.category in self.enabled_location_categories and location.category not in [DRLocationCategory.SURVIVOR, DRLocationCategory.LEVEL_UP]:
                #print("Adding location: " + location.name + " with default item " + location.default_item)
                new_location = DRLocation(
                    self.player,
                    location.name,
                    location.category,
                    location.default_item,
                    self.location_name_to_id[location.name],
                    new_region
                )
                new_region.locations.append(new_location)
            elif location.category in [DRLocationCategory.SURVIVOR, DRLocationCategory.LEVEL_UP]:
                print("Adding location: " + location.name + " with default item " + location.default_item)
                locked_item = self.create_item(location.default_item)
                new_location = DRLocation(
                    self.player,
                    location.name,
                    location.category,
                    location.default_item,
                    self.location_name_to_id[location.name],
                    new_region
                )
                new_location.place_locked_item(locked_item)
                new_region.locations.append(new_location)
            elif location.category == DRLocationCategory.EVENT:
                # Remove non-randomized progression items as checks because of the use of a "filler" fake item.
                # Replace events with event items for spoiler log readability.
                event_item = self.create_item(location.default_item)
                #if event_item.classification != ItemClassification.progression:
                #    continue
                #print("Adding Location: " + location.name + " as an event with default item " + location.default_item)
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
                #print("Placing event: " + event_item.name + " in location: " + location.name)
                new_region.locations.append(new_location)

        #print("created " + str(len(new_region.locations)) + " locations")
        self.multiworld.regions.append(new_region)
        #print("adding region: " + region_name)
        return new_region


    def create_items(self):
        itempool: List[DRItem] = []
        itempoolSize = 0
        #print("Creating items")
        for location in self.multiworld.get_locations(self.player):
                #print("found item in category: " + str(location.category))
                item_data = item_dictionary[location.default_item_name]
                if item_data.category in [DRItemCategory.SKIP] or \
                        location.category in [DRLocationCategory.EVENT]:
                    #print(f"Adding vanilla item/event {location.default_item_name} to {location.name}")
                    item = self.create_item(location.default_item_name)
                    self.multiworld.get_location(location.name, self.player).place_locked_item(item)
                elif location.category in self.enabled_location_categories:
                    #print("Adding item: " + location.default_item_name)
                    itempoolSize += 1
                    #itempool.append(self.create_item(location.default_item_name))
        
        #print("Requesting itempool size: " + str(itempoolSize))
        foo = BuildItemPool(self.multiworld, itempoolSize, self.options)
        #print("Created item pool size: " + str(len(foo)))
        #for item in foo:
            #print(f"{item.name}")

        for item in foo:
            #print("Adding regular item: " + item.name)
            itempool.append(self.create_item(item.name))

        # Add regular items to itempool
        self.multiworld.itempool += itempool
        
        #print("Final Item pool: ")
        #for item in self.multiworld.itempool:
        #    print(item.name)


    def create_item(self, name: str) -> Item:
        useful_categories = []
        data = self.item_name_to_id[name]

        if name in key_item_names:
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
        
        set_rule(self.multiworld.get_entrance("Safe Room -> Rooftop", self.player), lambda state: state.has("Rooftop Key", self.player))

        set_rule(self.multiworld.get_entrance("Safe Room -> Rooftop", self.player), lambda state: state.has("Rooftop Key", self.player))

        self.multiworld.completion_condition[self.player] = lambda state: state.can_reach_location("Reach Level 50", self.player)
                
    def fill_slot_data(self) -> Dict[str, object]:
        slot_data: Dict[str, object] = {}


        name_to_dr_code = {item.name: item.dr_code for item in item_dictionary.values()}
        # Create the mandatory lists to generate the player's output file
        items_id = []
        items_address = []
        locations_id = []
        locations_address = []
        locations_target = []
        hints = {}
        
        for location in self.multiworld.get_filled_locations():


            if location.item.player == self.player:
                #we are the receiver of the item
                items_id.append(location.item.code)
                items_address.append(name_to_dr_code[location.item.name])


            if location.player == self.player:
                #we are the sender of the location check
                locations_address.append(item_dictionary[location_dictionary[location.name].default_item].dr_code)
                locations_id.append(location.address)
                if location.item.player == self.player:
                    locations_target.append(name_to_dr_code[location.item.name])
                else:
                    locations_target.append(0)
       

        slot_data = {
            "options": {
                "guaranteed_items": self.options.guaranteed_items.value,
            },
            "hints": hints,
            "seed": self.multiworld.seed_name,  # to verify the server's multiworld
            "slot": self.multiworld.player_name[self.player],  # to connect to server
            "base_id": self.base_id,  # to merge location and items lists
            "locationsId": locations_id,
            "locationsAddress": locations_address,
            "locationsTarget": locations_target,
            "itemsId": items_id,
            "itemsAddress": items_address
        }

        return slot_data
