from enum import IntEnum
from typing import Optional, NamedTuple, Dict

from BaseClasses import Location, Region
from .Items import DRItem


class DRLocationCategory(IntEnum):
    SKIP = 0,
    EVENT = 1,
    SURVIVOR = 2,
    LEVEL_UP = 3,
    PP_STICKER = 4,
    MAIN_SCOOP = 5,
    OVERTIME_SCOOP = 6,
    PSYCHO_SCOOP = 7,
    CHALLENGE = 8


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
            "Grocery Store",
            "Food Court",
            "Crislip's Hardware Store",
            "Colby's Movie Theater",
            "Maintenance Tunnel",
            "Hideout",
            "Tunnels",
            "Level Ups",
            "Challenges"
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
    "Helipad": [
        DRLocationData("Victory", "Victory", DRLocationCategory.EVENT),
        # Events in Helipad
        DRLocationData("Get bit!", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Ending A: Solve all of the cases and be on the helipad at 12pm", "Milk", DRLocationCategory.MAIN_SCOOP),
        # DRLocationData("Ending B: Don't solve all of the cases but be on the helipad at 12pm", "Milk", DRLocationCategory.MAIN_SCOOP),
        # DRLocationData("Ending C: Solve all of the cases but don't meet Isabela at 10am", "Milk", DRLocationCategory.MAIN_SCOOP),

    ],

    "Safe Room": [
        # Events in Safe Room
        # First events in Entrance Plaza
        DRLocationData("Entrance Plaza Cutscene 1", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Help barricade the door!", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Get to the stairs!", "Milk", DRLocationCategory.MAIN_SCOOP),

        # Main Events
        DRLocationData("Complete Temporary Agreement", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Survive until 7pm on day 1", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Meet back at the Safe Room at 6am day 2", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Complete Image in the Monitor", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Complete Medicine Run", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Complete Professor's Past", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Complete Transporting Isabela", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Carry Isabela back to the Safe Room", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Complete Santa Cabeza", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Meet back at the safe room at 11am day 3", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Meet back at the safe room at 5pm day 3", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Complete Jessie's Discovery", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Head back to the safe room at the end of day 3", "Milk", DRLocationCategory.MAIN_SCOOP),
        # DRLocationData("Ending E: Don't solve all of the cases and don't be on the helipad at 12pm", "Milk", DRLocationCategory.MAIN_SCOOP),
        # DRLocationData("Ending F: Fail to collect all of the bombs in time", "Milk", DRLocationCategory.MAIN_SCOOP),

        # PP Stickers in Safe Room
        DRLocationData("Photograph PP Sticker 97", "Coffee Creamer", DRLocationCategory.PP_STICKER),

    ],

    "Rooftop": [
        # Survivors rescued from Heliport
        DRLocationData("Rescue Jeff Meyer", "Orange Juice", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Natalie Meyer", "Uncooked Pizza", DRLocationCategory.SURVIVOR),

        # PP Stickers in Rooftop
        DRLocationData("Photograph PP Sticker 100", "Yogurt", DRLocationCategory.PP_STICKER),

    ],

    "Service Hallway": [
        # Events in Service Hallway
        DRLocationData("Stomp the queen", "Milk", DRLocationCategory.EVENT),
        DRLocationData("Meet Jessie in the Service Hallway", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Witness Special Forces 10pm day 3", "Milk", DRLocationCategory.EVENT),

    ],


    "Paradise Plaza": [
        # Events in Paradise Plaza
        DRLocationData("Witness Sean in Paradise Plaza", "Milk", DRLocationCategory.PSYCHO_SCOOP),
        DRLocationData("Meet Kent on day 1", "Milk", DRLocationCategory.PSYCHO_SCOOP),
        DRLocationData("Complete Kent's day 1 photoshoot", "Milk", DRLocationCategory.PSYCHO_SCOOP),
        DRLocationData("Meet Kent on day 2", "Milk", DRLocationCategory.PSYCHO_SCOOP),
        DRLocationData("Complete Kent's day 2 photoshoot", "Milk", DRLocationCategory.PSYCHO_SCOOP),
        DRLocationData("Meet Kent on day 3", "Milk", DRLocationCategory.PSYCHO_SCOOP),
        DRLocationData("Kill Kent on day 3", "Milk", DRLocationCategory.PSYCHO_SCOOP),
        DRLocationData("Get grabbed by the raincoats", "Milk", DRLocationCategory.EVENT),

        # Survivors rescued from Paradise Plaza
        DRLocationData("Rescue Heather Tompkins", "Milk", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Pamela Tompkins", "Coffee Creamer", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Ronald Shiner", "Wine", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Jennifer Gorman", "Well Done Steak", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Tad Hawthorne", "Yogurt", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Simone Ravendark", "Apple", DRLocationCategory.SURVIVOR),

        # PP Stickers in Paradise Plaza
        DRLocationData("Photograph PP Sticker 1", "Pie", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 2", "Pie", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 3", "Baguette", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 4", "Orange Juice", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 5", "Uncooked Pizza", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 6", "Milk", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 7", "Coffee Creamer", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 8", "Wine", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 9", "Well Done Steak", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 10", "Yogurt", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 11", "Apple", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 12", "Pie", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 13", "Baguette", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 14", "Orange Juice", DRLocationCategory.PP_STICKER),
    ],

    "Entrance Plaza": [
        # Events in Entrance Plaza
        DRLocationData("Escort Brad to see Dr Barnaby", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Complete Rescue the Professor", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Meet the Hall family", "Milk", DRLocationCategory.PSYCHO_SCOOP),
        DRLocationData("Kill Roger and Jack (and Thomas if you want) and chat with Wayne", "Milk", DRLocationCategory.PSYCHO_SCOOP),

        # Survivors rescued from Entrance Plaza
        DRLocationData("Rescue Bill Brenton", "Milk", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Wayne Blackwell", "Coffee Creamer", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Jolie Wu", "Wine", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Rachel Decker", "Well Done Steak", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Floyd Sanders", "Yogurt", DRLocationCategory.SURVIVOR),

        # PP Stickers in Entrance Plaza
        DRLocationData("Photograph PP Sticker 25", "Uncooked Pizza", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 26", "Milk", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 27", "Coffee Creamer", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 28", "Wine", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 29", "Well Done Steak", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 30", "Yogurt", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 31", "Apple", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 32", "Pie", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 33", "Baguette", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 34", "Orange Juice", DRLocationCategory.PP_STICKER),
    ],

    "Al Fresca Plaza": [
        # Survivors rescued from Al Fresca Plaza
        DRLocationData("Rescue Aaron Swoop", "Milk", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Burt Thompson", "Coffee Creamer", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Leah Stein", "Wine", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Gordon Stalworth", "Well Done Steak", DRLocationCategory.SURVIVOR),

        # PP Stickers in Al Fresca Plaza
        DRLocationData("Photograph PP Sticker 35", "Uncooked Pizza", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 36", "Milk", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 37", "Coffee Creamer", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 38", "Wine", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 39", "Well Done Steak", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 40", "Yogurt", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 41", "Apple", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 42", "Pie", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 43", "Baguette", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 44", "Orange Juice", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 45", "Uncooked Pizza", DRLocationCategory.PP_STICKER),
    ],

    "Leisure Park": [
        # Events in Leisure Park
        DRLocationData("Watch the convicts kill that poor guy", "Milk", DRLocationCategory.PSYCHO_SCOOP),

        # Survivors rescued from Leisure Park
        DRLocationData("Rescue Sophie Richard", "Milk", DRLocationCategory.SURVIVOR),

        # Events in Leisure Park
        DRLocationData("See the crashed helicopter", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        # DRLocationData("Ending D: Be a prisoner when time runs out", "Milk", DRLocationCategory.MAIN_SCOOP),

        # PP Stickers in Leisure Park
        DRLocationData("Photograph PP Sticker 86", "Milk", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 87", "Coffee Creamer", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 88", "Wine", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 89", "Well Done Steak", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 98", "Wine", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 99", "Well Done Steak", DRLocationCategory.PP_STICKER),
    ],

    "Wonderland Plaza": [
        # Events in Wonderland Plaza
        DRLocationData("Meet Paul", "Milk", DRLocationCategory.PSYCHO_SCOOP),
        DRLocationData("Defeat Paul", "Milk", DRLocationCategory.PSYCHO_SCOOP),
        DRLocationData("Meet Adam", "Milk", DRLocationCategory.PSYCHO_SCOOP),
        DRLocationData("Kill Adam", "Milk", DRLocationCategory.PSYCHO_SCOOP),
        DRLocationData("Meet Jo", "Milk", DRLocationCategory.PSYCHO_SCOOP),
        DRLocationData("Kill Jo", "Milk", DRLocationCategory.PSYCHO_SCOOP),
        DRLocationData("Find Greg's secret passage", "Milk", DRLocationCategory.EVENT),

        # Survivors rescued from Wonderland Plaza
        DRLocationData("Rescue Greg Simpson", "Milk", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Yuu Tanaka", "Coffee Creamer", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Shinji Kitano", "Wine", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Tonya Waters", "Well Done Steak", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Ross Folk", "Yogurt", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Kay Nelson", "Apple", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Lilly Deacon", "Milk", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Kelly Carpenter", "Coffee Creamer", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Janet Star", "Wine", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Sally Mills", "Well Done Steak", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Nick Evans", "Yogurt", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Mindy Baker", "Apple", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Debbie Willet", "Milk", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Paul Carson", "Coffee Creamer", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Leroy McKenna", "Wine", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Susan Walsh", "Well Done Steak", DRLocationCategory.SURVIVOR),

        # PP Stickers in Wonderland Plaza
        DRLocationData("Photograph PP Sticker 57", "Coffee Creamer", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 58", "Wine", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 59", "Well Done Steak", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 60", "Yogurt", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 61", "Apple", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 62", "Pie", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 63", "Baguette", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 64", "Orange Juice", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 65", "Uncooked Pizza", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 66", "Milk", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 67", "Coffee Creamer", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 68", "Wine", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 69", "Well Done Steak", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 70", "Yogurt", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 71", "Apple", DRLocationCategory.PP_STICKER),
    ],

    "North Plaza": [
        # Events in North Plaza
        DRLocationData("Complete Girl Hunting", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Beat up Isabela", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Complete Promise to Isabela", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Save Isabela from the zombie", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Frank sees a sick-ass RC Drone", "Milk", DRLocationCategory.EVENT),
        DRLocationData("Meet Cletus", "Milk", DRLocationCategory.PSYCHO_SCOOP),
        DRLocationData("Kill Cletus", "Milk", DRLocationCategory.PSYCHO_SCOOP),

        # Survivors rescued from North Plaza
        DRLocationData("Rescue David Bailey", "Milk", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Josh Manning", "Coffee Creamer", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Barbara Patterson", "Well Done Steak", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Rich Atkins", "Yogurt", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Kindell Johnson", "Apple", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Brett Styles", "Milk", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Jonathan Picardson", "Coffee Creamer", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Alyssa Laurent", "Well Done Steak", DRLocationCategory.SURVIVOR),

        # PP Stickers in North Plaza
        DRLocationData("Photograph PP Sticker 72", "Pie", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 73", "Baguette", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 76", "Milk", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 77", "Coffee Creamer", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 78", "Wine", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 79", "Well Done Steak", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 80", "Yogurt", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 81", "Apple", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 82", "Pie", DRLocationCategory.PP_STICKER),

    ],
    "Grocery Store": [
        # Events in Grocery Store
        DRLocationData("Meet Steven", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Clean up... Register 6!", "Milk", DRLocationCategory.MAIN_SCOOP),

        # PP Stickers in Grocery Store
        DRLocationData("Photograph PP Sticker 83", "Baguette", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 84", "Orange Juice", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 85", "Uncooked Pizza", DRLocationCategory.PP_STICKER),
    ],
    "Food Court": [
        # Events in Food Court
        DRLocationData("Complete Backup for Brad", "Milk", DRLocationCategory.MAIN_SCOOP),

        # Survivors rescued from the Food Court
        DRLocationData("Rescue Gil Jiminez", "Milk", DRLocationCategory.SURVIVOR),

        # PP Stickers in Food Court
        DRLocationData("Photograph PP Sticker 46", "Milk", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 47", "Coffee Creamer", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 48", "Wine", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 49", "Well Done Steak", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 50", "Yogurt", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 51", "Pie", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 52", "Pie", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 53", "Baguette", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 54", "Orange Juice", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 55", "Uncooked Pizza", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 56", "Milk", DRLocationCategory.PP_STICKER),
    ],
    "Crislip's Hardware Store": [
        # Events in Crislip's Hardware Store
        DRLocationData("Meet Cliff", "Milk", DRLocationCategory.PSYCHO_SCOOP),
        DRLocationData("Kill Cliff", "Milk", DRLocationCategory.PSYCHO_SCOOP),

        # PP Stickers in Crislip's Hardware Store
        DRLocationData("Photograph PP Sticker 74", "Orange Juice", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 75", "Uncooked Pizza", DRLocationCategory.PP_STICKER),
    ],

    "Colby's Movie Theater": [
        # Events in Colby's Movie Theater
        DRLocationData("Meet Sean", "Milk", DRLocationCategory.PSYCHO_SCOOP),
        DRLocationData("Kill Sean", "Milk", DRLocationCategory.PSYCHO_SCOOP),

        # Survivors rescued from Colby's Movie Theater
        DRLocationData("Rescue Beth Shrake", "Milk", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Michelle Feltz", "Coffee Creamer", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Nathan Crabbe", "Well Done Steak", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Ray Mathison", "Yogurt", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Cheryl Jones", "Apple", DRLocationCategory.SURVIVOR),

        # PP Stickers in Colby's Movie Theater
        DRLocationData("Photograph PP Sticker 15", "Uncooked Pizza", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 16", "Milk", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 17", "Coffee Creamer", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 18", "Wine", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 19", "Well Done Steak", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 20", "Yogurt", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 21", "Apple", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 22", "Pie", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 23", "Baguette", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 24", "Orange Juice", DRLocationCategory.PP_STICKER),
    ],

    "Maintenance Tunnel": [
        # Events in Maintenance Tunnel
        DRLocationData("Complete Bomb Collector", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Beat Drivin Carlito", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Meet Larry", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Complete The Butcher", "Milk", DRLocationCategory.MAIN_SCOOP),

        # PP Stickers in Maintenance Tunnel
        DRLocationData("Photograph PP Sticker 90", "Yogurt", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 91", "Apple", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 92", "Pie", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 93", "Baguette", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 94", "Orange Juice", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 95", "Uncooked Pizza", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 96", "Milk", DRLocationCategory.PP_STICKER),
    ],

    "Hideout":[
        # Events in Hideout
        DRLocationData("Escort Isabela to the Hideout and have a chat", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Complete Memories", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Gather the suppressants and generator and talk to Isabela", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Give Isabela 5 queens", "Milk", DRLocationCategory.OVERTIME_SCOOP),

    ],

    "Tunnels": [
        DRLocationData("Get to the humvee", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Fight a tank and win", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Ending S: Beat up Brock with your bare fists!", "Victory", DRLocationCategory.EVENT),
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
        DRLocationData("Reach Level 50", "Milk", DRLocationCategory.LEVEL_UP),
    ],

    "Challenges": [
        DRLocationData("Reach max level", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Kill 500 zombies by hand", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Kill 500 zombies by vehicle", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Walk a marathon", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Change into 5 new outfits", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Change into 50 new outfits", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Encounter 10 survivors", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Encounter 50 survivors", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Get 50 survivors to join", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Kill 1000 zombies", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Kill 10000 zombies", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Zombie Genocide", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Kill 10 Special Forces", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Destroy 30 dishes in the Food Court", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Fire 300 bullets", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Ride zombies for 50 feet", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Spend 12 hours indoors", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Spend 12 hours outdoors", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Kill 1 psychopath", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Kill 8 psychopaths", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Kill 100 cultists", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Hit 10 zombies with a parasol", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Kill 100 zombies with an RPG", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Photograph 10 survivors", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Photograph 30 survivors", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Photograph 4 psychopaths", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Photograph 10 PP Stickers", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Photograph all PP Stickers", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Escort 8 survivors at once", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Frank the pimp", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Build a profile for 87 survivors", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Save 10 survivors", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Save 50 survivors", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Get 10000 PP in one photo", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Get 50 targets in one photo", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Fall from a high height", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Bowl over 10 zombies", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Jump a vehicle 50 feet", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Hit a golf ball 100 feet", "Milk", DRLocationCategory.CHALLENGE),

    ]
}

location_dictionary: Dict[str, DRLocationData] = {}
for location_table in location_tables.values():
    location_dictionary.update({location_data.name: location_data for location_data in location_table})
