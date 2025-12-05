from enum import IntEnum
from typing import Optional, NamedTuple, Dict

from BaseClasses import Location, Region
from .Items import DRItem


class DRLocationCategory(IntEnum):
    SKIP = 0,
    EVENT = 1,
    SURVIVOR = 2,
    LEVEL_UP = 3,


class DRLocationData(NamedTuple):
    name: str
    default_item: str
    category: DRLocationCategory


class DRLocation(Location):
    game: str = "Dead Rising Deluxe Remaster"
    category: DRLocationCategory
    default_item_name: str

    def __init__(
            self,
            player: int,
            name: str,
            category: DRLocationCategory,
            default_item_name: str,
            address: Optional[int] = None,
            parent: Optional[Region] = None
    ):
        super().__init__(player, name, address, parent)
        self.default_item_name = default_item_name
        self.category = category
        self.name = name

    @staticmethod
    def get_name_to_id() -> dict:
        base_id = 1230000
        table_offset = 1000

        table_order = [
            "Rooftop",
            "Paradise Plaza",
            "Entrance Plaza",
            "Al Fresca Plaza",
            "Leisure Park",
            "Wonderland Plaza",
            "North Plaza",
            "Level Ups"
        ]

        output = {}
        for i, region_name in enumerate(table_order):
            if len(location_tables[region_name]) > table_offset:
                raise Exception("A location table has {} entries, that is more than {} entries (table #{})".format(
                    len(location_tables[region_name]), table_offset, i))

            output.update({location_data.name: id for id, location_data in
                           enumerate(location_tables[region_name], base_id + (table_offset * i))})

        return output

    def place_locked_item(self, item: DRItem):
        self.item = item
        self.locked = True
        item.location = self


# To ensure backwards compatibility, do not reorder locations or insert new ones in the middle of a list.
location_tables = {
    "Rooftop": [
        # Survivors rescued from Heliport
        DRLocationData("Rescue Jeff Meyer", "Orange Juice", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Natalie Meyer", "Uncooked Pizza", DRLocationCategory.SURVIVOR),
    ],

    "Paradise Plaza": [
        # Survivors rescued from Paradise Plaza
        DRLocationData("Rescue Heather Tompkins", "Milk", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Pamela Tompkins", "Coffee Creamer", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Ronald Shiner", "Wine", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Jennifer Gorman", "Well Done Steak", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Tad Hawthorne", "Yogurt", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Simone Ravendark", "Apple", DRLocationCategory.SURVIVOR),
    ],

    "Entrance Plaza": [
        # Survivors rescued from Entrance Plaza
        DRLocationData("Rescue Bill Brenton", "Milk", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Wayne Blackwell", "Coffee Creamer", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Jolie Wu", "Wine", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Rachel Decker", "Well Done Steak", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Floyd Sanders", "Yogurt", DRLocationCategory.SURVIVOR)
    ],

    "Al Fresca Plaza": [
        # Survivors rescued from Al Fresca Plaza
        DRLocationData("Rescue Aaron Swoop", "Milk", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Burt Thompson", "Coffee Creamer", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Leah Stein", "Wine", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Gordon Stalworth", "Well Done Steak", DRLocationCategory.SURVIVOR)
    ],

    "Leisure Park": [
        # Survivors rescued from Leisure Park
        DRLocationData("Rescue Sophie Richard", "Milk", DRLocationCategory.SURVIVOR)
    ],

    "Wonderland Plaza": [
        # Survivors rescued from Wonderland Plaza
        DRLocationData("Rescue Greg Simpson", "Milk", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Yuu Tanaka", "Coffee Creamer", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Shinji Kitano", "Wine", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Tonya Waters", "Well Done Steak", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Ross Folk", "Yogurt", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Kay Nelson", "Apple", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Lilly Deadon", "Milk", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Kelly Carpenter", "Coffee Creamer", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Janet Star", "Wine", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Sally Mills", "Well Done Steak", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Nick Evans", "Yogurt", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Mindy Baker", "Apple", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Debbie Willet", "Milk", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Paul Carson", "Coffee Creamer", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Leroy McKenna", "Wine", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Susan Walsh", "Well Done Steak", DRLocationCategory.SURVIVOR)
    ],

    "North Plaza": [
        # Survivors rescued from North Plaza
        DRLocationData("Rescue David Bailey", "Milk", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Josh Manning", "Coffee Creamer", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Barbara Patterson", "Well Done Steak", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Rich Atkins", "Yogurt", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Kindell Johnson", "Apple", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Brett Styles", "Milk", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Jonathan Picardson", "Coffee Creamer", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Alyssa Laurent", "Well Done Steak", DRLocationCategory.SURVIVOR)
    ],

    "Food Court": [
        # Survivors rescued from the Food Court
        DRLocationData("Rescue Gil Jiminez", "Milk", DRLocationCategory.SURVIVOR)
    ],

    "Colby's Movieland": [
        DRLocationData("Rescue Beth Shrake", "Milk", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Michelle Feltz", "Coffee Creamer", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Nathan Crabbe", "Well Done Steak", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Ray Mathison", "Yogurt", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Cheryl Jones", "Apple", DRLocationCategory.SURVIVOR),
    ],

    "Level Ups": [
        # Level up rewards (50 levels)
        DRLocationData("Reach Level 2", "Pie", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 3", "Baguette", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 4", "Orange Juice", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 5", "Uncooked Pizza", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 6", "Milk", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 7", "Coffee Creamer", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 8", "Wine", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 9", "Well Done Steak", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 10", "Yogurt", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 11", "Apple", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 12", "Pie", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 13", "Baguette", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 14", "Orange Juice", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 15", "Uncooked Pizza", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 16", "Milk", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 17", "Coffee Creamer", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 18", "Wine", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 19", "Well Done Steak", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 20", "Yogurt", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 21", "Apple", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 22", "Pie", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 23", "Baguette", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 24", "Orange Juice", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 25", "Uncooked Pizza", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 26", "Milk", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 27", "Coffee Creamer", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 28", "Wine", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 29", "Well Done Steak", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 30", "Yogurt", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 31", "Apple", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 32", "Pie", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 33", "Baguette", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 34", "Orange Juice", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 35", "Uncooked Pizza", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 36", "Milk", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 37", "Coffee Creamer", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 38", "Wine", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 39", "Well Done Steak", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 40", "Yogurt", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 41", "Apple", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 42", "Pie", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 43", "Baguette", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 44", "Orange Juice", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 45", "Uncooked Pizza", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 46", "Milk", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 47", "Coffee Creamer", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 48", "Wine", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 49", "Well Done Steak", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 50", "Victory", DRLocationCategory.LEVEL_UP),
    ]
}

location_dictionary: Dict[str, DRLocationData] = {}
for location_table in location_tables.values():
    location_dictionary.update({location_data.name: location_data for location_data in location_table})
