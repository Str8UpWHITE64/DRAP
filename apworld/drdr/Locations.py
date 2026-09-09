from enum import IntEnum
from typing import Optional, NamedTuple, Dict, List

from BaseClasses import Location, Region
from .Items import DRItem
from .shared_data import ZOMBIE_KILL_TIERS as SHARED_ZOMBIE_KILL_TIERS


class DRLocationCategory(IntEnum):
    SKIP = 0,
    EVENT = 1,
    SURVIVOR = 2,
    LEVEL_UP = 3,
    PP_STICKER = 4,
    MAIN_SCOOP = 5,
    OVERTIME_SCOOP = 6,
    PSYCHO_SCOOP = 7,
    CHALLENGE = 8,
    PP_BONUS = 9,
    ZOMBIE_KILL = 10,
    KILL_SURVIVOR = 11,
    # The two Special Forces checks. Their own category because
    # they are reachable two different ways: in Overtime on the
    # Ending S goal, or during the 72 hours when
    # special_forces_mode puts the soldiers in the mall. Either
    # condition enables them; the access rule decides which.
    SPECIAL_FORCES_SCOOP = 12
    # The three camera upgrades sitting in camera shops. Standalone pickups
    # with no scoop behind them, so they get their own category rather than
    # borrowing a scoop's and inheriting its gating.
    CAMERA_PART = 13
    # KillSanity: one location per zombie kill, per area. Its own table,
    # far past the 1000-per-table slot, so it takes the ID range after
    # every other table.
    KILL_SANITY = 14


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
            "Seon's Food and Stuff",
            "Food Court",
            "Crislip's Home Saloon",
            "Colby's Movieland",
            "Maintenance Tunnel",
            "Carlito's Hideout",
            "Clock Tower Tunnel",
            "Level Ups",
            "Challenges",
            "Meat Processing Area",
            "Zombie Kills"
        ]

        output = {}
        for i, region_name in enumerate(table_order):
            if len(location_tables[region_name]) > table_offset:
                raise Exception("A location table has {} entries, that is more than {} entries (table #{})".format(
                    len(location_tables[region_name]), table_offset, i))

            output.update({location_data.name: id for id, location_data in
                           enumerate(location_tables[region_name], base_id + (table_offset * i))})

        # KillSanity is 53,594 entries in one table, so it sits after the
        # last ordinary slot and nothing may ever be appended behind it.
        output.update({location_data.name: id for id, location_data in
                       enumerate(location_tables["Kill Sanity"],
                                 base_id + (table_offset * len(table_order)))})

        return output

    def place_locked_item(self, item: DRItem):
        self.item = item
        self.locked = True
        item.location = self


# To ensure backwards compatibility, do not reorder locations or insert new ones in the middle of a list.
location_tables = {
    "Heliport": [
        DRLocationData("Victory", "Victory", DRLocationCategory.EVENT),
        # Events in Heliport
        DRLocationData("Get bit!", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Ending A: Solve all of the cases and be on the helipad at 12pm", "Milk", DRLocationCategory.MAIN_SCOOP),
        # DRLocationData("Ending B: Don't solve all of the cases but be on the helipad at 12pm", "Milk", DRLocationCategory.MAIN_SCOOP),
        # DRLocationData("Ending C: Solve all of the cases but don't meet Isabela at 10am", "Milk", DRLocationCategory.MAIN_SCOOP),

    ],

    "Security Room": [
        # Events in Security Room
        # First events in Entrance Plaza
        DRLocationData("Entrance Plaza Cutscene 1", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Help barricade the door!", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Get to the stairs!", "Milk", DRLocationCategory.MAIN_SCOOP),

        # Main Events
        DRLocationData("Complete Temporary Agreement", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Survive until 7pm on day 1", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Meet back at the Security Room at 6am day 2", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Complete Image in the Monitor", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Complete Medicine Run", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Complete Professor's Past", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Complete Transporting Isabela", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Carry Isabela back to the Security Room", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Complete Santa Cabeza", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Meet back at the Security Room at 11am day 3", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Meet back at the Security Room at 5pm day 3", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Complete Jessie's Discovery", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Head back to the Security Room at the end of day 3", "Milk", DRLocationCategory.MAIN_SCOOP),
        # DRLocationData("Ending E: Don't solve all of the cases and don't be on the helipad at 12pm", "Milk", DRLocationCategory.MAIN_SCOOP),
        # DRLocationData("Ending F: Fail to collect all of the bombs in time", "Milk", DRLocationCategory.MAIN_SCOOP),

        # PP Stickers in Security Room
        DRLocationData("Photograph PP Sticker 97", "Coffee Creamer", DRLocationCategory.PP_STICKER),

        # Synthetic goal location for the Savior goal. Only populated as a real
        # checkable location when Goal == Savior; otherwise created as an event
        # with no ID. Lua sends this check once the player has rescued their
        # target number of survivors.
        DRLocationData("Savior: Rescue enough survivors to escape", "Victory", DRLocationCategory.EVENT),


        # Overtime suppressant ingredients. Named "Find the ..." so the
        # Overtime First Aid Kit cannot be confused with the story one,
        # which is also in Seon's.
        DRLocationData("Find the Coffee Filters", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Obtain Mall Map and Transceiver", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Use All Microwaves", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Heat a pan on all stoves", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Psycho: Kill enough survivors to escape", "Victory", DRLocationCategory.EVENT),
    ],

    "Rooftop": [
        # Survivors rescued from Heliport
        DRLocationData("Rescue Jeff Meyer", "Orange Juice", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Natalie Meyer", "Uncooked Pizza", DRLocationCategory.SURVIVOR),

        # PP Stickers in Rooftop
        DRLocationData("Photograph PP Sticker 100", "Yogurt", DRLocationCategory.PP_STICKER),

        DRLocationData("Kill Jeff Meyer", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Natalie Meyer", "Milk", DRLocationCategory.KILL_SURVIVOR),
    ],

    "Warehouse": [
        # Events in Warehouse
        # DRLocationData("Stomp the queen", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Meet Jessie in the Warehouse", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Witness Special Forces 10pm day 3", "Milk", DRLocationCategory.MAIN_SCOOP),

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
        DRLocationData("Get grabbed by the raincoats", "Milk", DRLocationCategory.PSYCHO_SCOOP),

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


        # Overtime suppressant ingredients. Named "Find the ..." so the
        # Overtime First Aid Kit cannot be confused with the story one,
        # which is also in Seon's.
        DRLocationData("Find the Developing Solution", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Find the Cold Spray", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Camera Part [Flash]", "Milk", DRLocationCategory.CAMERA_PART),
        DRLocationData("Realign Servbot Head", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Use the Microwave in Jill's Sandwiches", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Heat a pan on the Stove in Colombian Roastmasters - Paradise Plaza", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Heat a pan on the Stove in Jill's Sandwiches", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Kill Heather Tompkins", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Pamela Tompkins", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Ronald Shiner", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Jennifer Gorman", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Tad Hawthorne", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Simone Ravendark", "Milk", DRLocationCategory.KILL_SURVIVOR),
    ],

    "Entrance Plaza": [
        # Events in Entrance Plaza
        DRLocationData("Escort Brad to see Dr Barnaby", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Complete Rescue the Professor", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Meet the Hall Family", "Milk", DRLocationCategory.PSYCHO_SCOOP),
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


        # Overtime suppressant ingredients. Named "Find the ..." so the
        # Overtime First Aid Kit cannot be confused with the story one,
        # which is also in Seon's.
        DRLocationData("Find the Camp Stove", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Find the Perfume Bottle", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Spin the Display Rack at Shootingstar Sporting Goods Right", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Spin the Display Rack at Shootingstar Sporting Goods Left", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Spin the Display Rack at Jason Wayne's Sporting Goods Front", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Spin the Display Rack at Jason Wayne's Sporting Goods Back", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Spin All Display Racks", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Kill Bill Brenton", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Wayne Blackwell", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Jolie Wu", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Rachel Decker", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Floyd Sanders", "Milk", DRLocationCategory.KILL_SURVIVOR),
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
        DRLocationData("Walk on Treadmill 1", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Walk on Treadmill 2", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Walk on Treadmill 3", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Walk on Treadmill 4", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Walk on Treadmill 5", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Walk on Treadmill 6", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Walk on All Treadmills", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Destroy Sandbag 1", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Destroy Sandbag 2", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Destroy Sandbag 3", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Destroy Sandbag 4", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Destroy All Sandbags", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Use the Microwave in Colombian Roastmasters - Al Fresca Plaza", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Use the Microwave in Hamburger Fiefdom", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Heat a pan on the Stove in Colombian Roastmasters - Al Fresca Plaza", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Kill Aaron Swoop", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Burt Thompson", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Leah Stein", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Gordon Stalworth", "Milk", DRLocationCategory.KILL_SURVIVOR),
    ],

    "Leisure Park": [
        # Events in Leisure Park
        DRLocationData("Watch the convicts kill that poor guy", "Milk", DRLocationCategory.PSYCHO_SCOOP),

        # Survivors rescued from Leisure Park
        DRLocationData("Rescue Sophie Richard", "Milk", DRLocationCategory.SURVIVOR),

        # Events in Leisure Park
        DRLocationData("See the crashed helicopter", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Hella Copter - Shoot down the Special Forces Helicopter", "Milk", DRLocationCategory.SPECIAL_FORCES_SCOOP),
        # DRLocationData("Ending D: Be a prisoner when time runs out", "Milk", DRLocationCategory.MAIN_SCOOP),

        # PP Stickers in Leisure Park
        DRLocationData("Photograph PP Sticker 86", "Milk", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 87", "Coffee Creamer", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 88", "Wine", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 89", "Well Done Steak", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 98", "Wine", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 99", "Well Done Steak", DRLocationCategory.PP_STICKER),

        # Appended rather than filed with the other convict entry above, since
        # ids come from list position.
        DRLocationData("Kill the convicts", "Milk", DRLocationCategory.PSYCHO_SCOOP),
        DRLocationData("Kill Sophie Richard", "Milk", DRLocationCategory.KILL_SURVIVOR),
    ],

    "Wonderland Plaza": [
        # Events in Wonderland Plaza
        DRLocationData("Meet Paul", "Milk", DRLocationCategory.PSYCHO_SCOOP),
        DRLocationData("Defeat Paul", "Milk", DRLocationCategory.PSYCHO_SCOOP),
        DRLocationData("Meet Adam", "Milk", DRLocationCategory.PSYCHO_SCOOP),
        DRLocationData("Kill Adam", "Milk", DRLocationCategory.PSYCHO_SCOOP),
        DRLocationData("Meet Jo", "Milk", DRLocationCategory.PSYCHO_SCOOP),
        DRLocationData("Kill Jo", "Milk", DRLocationCategory.PSYCHO_SCOOP),
        DRLocationData("Find Greg's secret passage", "Milk", DRLocationCategory.PSYCHO_SCOOP),

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


        # Overtime suppressant ingredients. Named "Find the ..." so the
        # Overtime First Aid Kit cannot be confused with the story one,
        # which is also in Seon's.
        DRLocationData("Find the Magnifying Glass", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Camera Part [Brightness]", "Milk", DRLocationCategory.CAMERA_PART),
        DRLocationData("Ride the Space Rider", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Kill Greg Simpson", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Yuu Tanaka", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Shinji Kitano", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Tonya Waters", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Ross Folk", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Kay Nelson", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Lilly Deacon", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Kelly Carpenter", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Janet Star", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Sally Mills", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Nick Evans", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Mindy Baker", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Debbie Willet", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Paul Carson", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Leroy McKenna", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Susan Walsh", "Milk", DRLocationCategory.KILL_SURVIVOR),
    ],

    "North Plaza": [
        # Events in North Plaza
        DRLocationData("Complete Girl Hunting", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Beat up Isabela", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Complete Promise to Isabela", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Save Isabela from the zombie", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Frank sees a sick-ass RC Drone", "Milk", DRLocationCategory.OVERTIME_SCOOP),
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

        DRLocationData("Camera Part [Focus]", "Milk", DRLocationCategory.CAMERA_PART),
        DRLocationData("Kill David Bailey", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Josh Manning", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Barbara Patterson", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Rich Atkins", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Kindell Johnson", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Brett Styles", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Jonathan Picardson", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Alyssa Laurent", "Milk", DRLocationCategory.KILL_SURVIVOR),
    ],
    "Seon's Food and Stuff": [
        # Events in Seon's Food and Stuff
        DRLocationData("Meet Steven", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Clean up... Register 6!", "Milk", DRLocationCategory.MAIN_SCOOP),

        # PP Stickers in Seon's Food and Stuff
        DRLocationData("Photograph PP Sticker 83", "Baguette", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 84", "Orange Juice", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 85", "Uncooked Pizza", DRLocationCategory.PP_STICKER),


        # Overtime suppressant ingredients. Named "Find the ..." so the
        # Overtime First Aid Kit cannot be confused with the story one,
        # which is also in Seon's.
        DRLocationData("Find the First Aid Kit", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Obtain First Aid Kit", "Milk", DRLocationCategory.PP_BONUS),
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


        # Overtime suppressant ingredients. Named "Find the ..." so the
        # Overtime First Aid Kit cannot be confused with the story one,
        # which is also in Seon's.
        DRLocationData("Find the Blender", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Break Dish 1 in Row 1 in Chris's Fine Foods", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Break Dish 2 in Row 1 in Chris's Fine Foods", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Break Dish 3 in Row 1 in Chris's Fine Foods", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Break Dish 4 in Row 1 in Chris's Fine Foods", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Break Dish 5 in Row 1 in Chris's Fine Foods", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Break Dish 1 in Row 2 in Chris's Fine Foods", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Break Dish 2 in Row 2 in Chris's Fine Foods", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Break Dish 3 in Row 2 in Chris's Fine Foods", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Break Dish 4 in Row 2 in Chris's Fine Foods", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Break Dish 1 in Row 3 in Chris's Fine Foods", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Break Dish 2 in Row 3 in Chris's Fine Foods", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Break Dish 3 in Row 3 in Chris's Fine Foods", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Break Dish 4 in Row 3 in Chris's Fine Foods", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Break Dish 1 in Row 4 in Chris's Fine Foods", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Break Dish 2 in Row 4 in Chris's Fine Foods", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Break Dish 3 in Row 4 in Chris's Fine Foods", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Break Dish 4 in Row 4 in Chris's Fine Foods", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Break Dish 5 in Row 4 in Chris's Fine Foods", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Use the Microwave in Chris's Fine Foods", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Use the Microwave in That's a Spicy Meatball!", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Use the Microwave in Central Tacos", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Use the Microwave in Meaty's Burgers", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Use the Microwave in Jade Paradise", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Use the Microwave in Teresa's Oven", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Heat a pan on the Stove in Chris's Fine Foods", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Heat a pan on the Stove in That's a Spicy Meatball!", "Milk", DRLocationCategory.PP_BONUS),
        DRLocationData("Kill Gil Jiminez", "Milk", DRLocationCategory.KILL_SURVIVOR),
    ],
    "Crislip's Home Saloon": [
        # Events in Crislip's Home Saloon
        DRLocationData("Meet Cliff", "Milk", DRLocationCategory.PSYCHO_SCOOP),
        DRLocationData("Kill Cliff", "Milk", DRLocationCategory.PSYCHO_SCOOP),

        # PP Stickers in Crislip's Home Saloon
        DRLocationData("Photograph PP Sticker 74", "Orange Juice", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 75", "Uncooked Pizza", DRLocationCategory.PP_STICKER),
    ],

    "Colby's Movieland": [
        # Events in Colby's Movieland
        DRLocationData("Meet Sean", "Milk", DRLocationCategory.PSYCHO_SCOOP),
        DRLocationData("Kill Sean", "Milk", DRLocationCategory.PSYCHO_SCOOP),

        # Survivors rescued from Colby's Movieland
        DRLocationData("Rescue Beth Shrake", "Milk", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Michelle Feltz", "Coffee Creamer", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Nathan Crabbe", "Well Done Steak", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Ray Mathison", "Yogurt", DRLocationCategory.SURVIVOR),
        DRLocationData("Rescue Cheryl Jones", "Apple", DRLocationCategory.SURVIVOR),

        # PP Stickers in Colby's Movieland
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
        DRLocationData("Kill Beth Shrake", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Michelle Feltz", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Nathan Crabbe", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Ray Mathison", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill Cheryl Jones", "Milk", DRLocationCategory.KILL_SURVIVOR),
    ],

    "Maintenance Tunnel": [
        # Events in Maintenance Tunnel
        DRLocationData("Complete Bomb Collector", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Beat Drivin Carlito", "Milk", DRLocationCategory.MAIN_SCOOP),

        # PP Stickers in Maintenance Tunnel
        DRLocationData("Photograph PP Sticker 90", "Yogurt", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 91", "Apple", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 92", "Pie", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 93", "Baguette", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 94", "Orange Juice", DRLocationCategory.PP_STICKER),

        # The five Bomb Collector trucks, named for the plaza each sits under.
        # Flags EV_TIMER_BOM00..04 (2066-2070), set on COLLECTING each bomb.
        # Appended last: location IDs are position-based per region.
        DRLocationData("Bomb Collector - Entrance Plaza Truck", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Bomb Collector - North Plaza Truck", "Coffee Creamer", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Bomb Collector - Al Fresca Plaza Truck", "Yogurt", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Bomb Collector - Wonderland Plaza Truck", "Apple", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Bomb Collector - Seon's Food and Stuff Truck", "Orange Juice", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Obtain Maintenance Tunnel Key", "Milk", DRLocationCategory.PP_BONUS),
    ],

    # Off the Maintenance Tunnel and nothing else, so its key gates all four.
    "Meat Processing Area": [
        # Events in the Meat Processing Area
        DRLocationData("Meet Larry", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Complete The Butcher", "Milk", DRLocationCategory.MAIN_SCOOP),

        # PP Stickers in the Meat Processing Area
        DRLocationData("Photograph PP Sticker 95", "Uncooked Pizza", DRLocationCategory.PP_STICKER),
        DRLocationData("Photograph PP Sticker 96", "Milk", DRLocationCategory.PP_STICKER),
    ],

    "Carlito's Hideout":[
        # Events in Carlito's Hideout
        DRLocationData("Escort Isabela to Carlito's Hideout and have a chat", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Complete Memories", "Milk", DRLocationCategory.MAIN_SCOOP),
        DRLocationData("Scramble for a Suppressant", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Honey Hunt", "Milk", DRLocationCategory.OVERTIME_SCOOP),


        # The Generator is the ninth cooking-equipment entry and is not
        # gated: it can arrive by cutscene instead of being picked up, and
        # that path sets no flags. Only its delivery is a check.
        DRLocationData("Give Isabela the Generator", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Give Isabela the Blender", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Give Isabela the First Aid Kit", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Give Isabela the Coffee Filters", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Give Isabela the Magnifying Glass", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Give Isabela the Camp Stove", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Give Isabela the Developing Solution", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Give Isabela the Perfume Bottle", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Give Isabela the Cold Spray", "Milk", DRLocationCategory.OVERTIME_SCOOP),

        # Queens one to four. The fifth is Honey Hunt, which the game
        # already marks with its own flag.
        DRLocationData("Give Isabela 1 Queen", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Give Isabela 2 Queens", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Give Isabela 3 Queens", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Give Isabela 4 Queens", "Milk", DRLocationCategory.OVERTIME_SCOOP),
    ],

    "Clock Tower Tunnel": [
        DRLocationData("Proceed through the cave with Isabela", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Open Gate 1", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Open Gate 2", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Raise the final gate", "Milk", DRLocationCategory.OVERTIME_SCOOP),
        DRLocationData("Get to the Humvee", "Milk", DRLocationCategory.OVERTIME_SCOOP),
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

        # Secondary level up rewards
        DRLocationData("Reach Level 10!", "Milk", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 20!", "Milk", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 30!", "Milk", DRLocationCategory.LEVEL_UP),
        DRLocationData("Reach Level 40!", "Milk", DRLocationCategory.LEVEL_UP),
    ],

    "Challenges": [
        DRLocationData("Reach max level", "Milk", DRLocationCategory.CHALLENGE),
        # DRLocationData("Kill 50 zombies by hand", "Milk", DRLocationCategory.CHALLENGE),
        # DRLocationData("Kill 100 zombies by hand", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Kill 500 zombies by vehicle", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Kill 1000 zombies by vehicle", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Walk a quarter marathon", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Change into 5 new outfits", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Change into 46 new outfits", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Encounter 10 survivors", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Encounter 50 survivors", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Get 50 survivors to join", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Kill 1000 zombies", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Kill 2000 zombies", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Kill 5000 zombies", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Kill 10000 zombies", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Kill 10 Special Forces", "Milk", DRLocationCategory.SPECIAL_FORCES_SCOOP),
        DRLocationData("Destroy all of the wall plates in the Food Court", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Fire 30 bullets", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Fire 300 bullets", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Ride zombies for 50 feet", "Milk", DRLocationCategory.CHALLENGE),
        # DRLocationData("Spend 12 hours indoors", "Milk", DRLocationCategory.CHALLENGE),
        # DRLocationData("Spend 12 hours outdoors", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Kill 1 psychopath", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Kill 8 psychopaths", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Kill 50 cultists", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Hit 10 zombies with a parasol", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Kill 100 zombies with an RPG", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Photograph 10 survivors", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Photograph 30 survivors", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Photograph 8 psychopaths", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Photograph 10 PP Stickers", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Photograph 20 PP Stickers", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Photograph 30 PP Stickers", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Photograph 40 PP Stickers", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Photograph 50 PP Stickers", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Photograph 60 PP Stickers", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Photograph 70 PP Stickers", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Photograph 80 PP Stickers", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Photograph 90 PP Stickers", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Photograph all PP Stickers", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Escort 8 survivors at once", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Frank the pimp", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Rescue 5 survivors", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Rescue 10 survivors", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Rescue 15 survivors", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Rescue 20 survivors", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Rescue 25 survivors", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Rescue 30 survivors", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Rescue 35 survivors", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Rescue 40 survivors", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Rescue 45 survivors", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Rescue 48 survivors", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Get 10000 PP in one photo", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Get 50 targets in one photo", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Fall from a high height", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Bowl over 5 zombies", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Jump a vehicle 50 feet", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Hit a golf ball 100 feet", "Milk", DRLocationCategory.CHALLENGE),
        # Appended, never inserted: ids are positional within the table.
        # Both are sphere 0 by way of the Challenges blanket rule.
        DRLocationData("Welcome to Hell", "Milk", DRLocationCategory.CHALLENGE),
        DRLocationData("Photojournalist", "Milk", DRLocationCategory.CHALLENGE),

        DRLocationData("Kill 5 survivors", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill 10 survivors", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill 15 survivors", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill 20 survivors", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill 25 survivors", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill 30 survivors", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill 35 survivors", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill 40 survivors", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill 45 survivors", "Milk", DRLocationCategory.KILL_SURVIVOR),
        DRLocationData("Kill 48 survivors", "Milk", DRLocationCategory.KILL_SURVIVOR),
    ]
}

location_dictionary: Dict[str, DRLocationData] = {}
for location_table in location_tables.values():
    location_dictionary.update({location_data.name: location_data for location_data in location_table})


# ----------------------------------------------------------------------------
# Zombie Kills
#
# Kills are counted per area at runtime by hooking the engine's own increment,
# so a check lands the moment the kill happens rather than on the way out of
# the area. There is no engine-side per-area counter -- these are DRAP's.
#
# Each area's top threshold is what it takes to clear: 6 mains at 2000, 3
# minors at 1000, Leisure Park at 10000 and the Tunnels at 28594 come to
# 53594, the Zombie Genocider number.
# ----------------------------------------------------------------------------

# Indexed by ZombieKillTiers.value, so the order is the option order.
ZOMBIE_KILL_TIER_NAMES = ["none", "easy", "normal", "nightmare", "genocide"]

# region -> {tier: [thresholds]}, from drdr_shared.json so the runtime can
# read the same numbers. A tier lists every threshold active at it, not just
# the ones it adds.
ZOMBIE_KILL_TIERS: Dict[str, Dict[str, List[int]]] = SHARED_ZOMBIE_KILL_TIERS


def zombie_kill_location_name(threshold: int, region: str) -> str:
    return f"Kill {threshold} zombies in {region}"


def zombie_kill_locations(tier: str) -> List[str]:
    """Every kill location active at a tier, in table order."""
    out: List[str] = []
    for region, tiers in ZOMBIE_KILL_TIERS.items():
        for threshold in tiers.get(tier, []):
            out.append(zombie_kill_location_name(threshold, region))
    return out


# Kill locations live in their own table rather than in each area's, because
# their rules are not just "can you reach this area" -- they also carry
# mall-progress, car and weapon requirements. A location cannot escape its
# region's reachability, so the region is a neutral one and Rules.py writes
# out every rule.
#
# Every threshold is listed; the ZombieKillTiers option decides which are
# created, in __init__.create_regions.
location_tables["Zombie Kills"] = [
    DRLocationData("Kill 10 zombies in Paradise Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 25 zombies in Paradise Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 50 zombies in Paradise Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 100 zombies in Paradise Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 250 zombies in Paradise Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 500 zombies in Paradise Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 1000 zombies in Paradise Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 2000 zombies in Paradise Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 10 zombies in Entrance Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 25 zombies in Entrance Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 50 zombies in Entrance Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 100 zombies in Entrance Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 250 zombies in Entrance Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 500 zombies in Entrance Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 1000 zombies in Entrance Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 2000 zombies in Entrance Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 10 zombies in Al Fresca Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 25 zombies in Al Fresca Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 50 zombies in Al Fresca Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 100 zombies in Al Fresca Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 250 zombies in Al Fresca Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 500 zombies in Al Fresca Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 1000 zombies in Al Fresca Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 2000 zombies in Al Fresca Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 10 zombies in Food Court", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 25 zombies in Food Court", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 50 zombies in Food Court", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 100 zombies in Food Court", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 250 zombies in Food Court", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 500 zombies in Food Court", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 1000 zombies in Food Court", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 2000 zombies in Food Court", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 10 zombies in Wonderland Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 25 zombies in Wonderland Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 50 zombies in Wonderland Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 100 zombies in Wonderland Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 250 zombies in Wonderland Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 500 zombies in Wonderland Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 1000 zombies in Wonderland Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 2000 zombies in Wonderland Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 10 zombies in North Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 25 zombies in North Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 50 zombies in North Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 100 zombies in North Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 250 zombies in North Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 500 zombies in North Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 1000 zombies in North Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 2000 zombies in North Plaza", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 10 zombies in Crislip's Home Saloon", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 25 zombies in Crislip's Home Saloon", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 50 zombies in Crislip's Home Saloon", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 100 zombies in Crislip's Home Saloon", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 250 zombies in Crislip's Home Saloon", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 500 zombies in Crislip's Home Saloon", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 1000 zombies in Crislip's Home Saloon", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 10 zombies in Seon's Food and Stuff", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 25 zombies in Seon's Food and Stuff", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 50 zombies in Seon's Food and Stuff", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 100 zombies in Seon's Food and Stuff", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 250 zombies in Seon's Food and Stuff", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 500 zombies in Seon's Food and Stuff", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 1000 zombies in Seon's Food and Stuff", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 10 zombies in Colby's Movieland", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 25 zombies in Colby's Movieland", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 50 zombies in Colby's Movieland", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 100 zombies in Colby's Movieland", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 250 zombies in Colby's Movieland", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 500 zombies in Colby's Movieland", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 1000 zombies in Colby's Movieland", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 10 zombies in Leisure Park", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 25 zombies in Leisure Park", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 50 zombies in Leisure Park", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 100 zombies in Leisure Park", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 250 zombies in Leisure Park", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 500 zombies in Leisure Park", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 1000 zombies in Leisure Park", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 2000 zombies in Leisure Park", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 5000 zombies in Leisure Park", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 10000 zombies in Leisure Park", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 10 zombies in Maintenance Tunnel", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 25 zombies in Maintenance Tunnel", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 50 zombies in Maintenance Tunnel", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 100 zombies in Maintenance Tunnel", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 250 zombies in Maintenance Tunnel", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 500 zombies in Maintenance Tunnel", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 1000 zombies in Maintenance Tunnel", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 2000 zombies in Maintenance Tunnel", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 5000 zombies in Maintenance Tunnel", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 10000 zombies in Maintenance Tunnel", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 15000 zombies in Maintenance Tunnel", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 20000 zombies in Maintenance Tunnel", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Kill 28594 zombies in Maintenance Tunnel", "Milk", DRLocationCategory.ZOMBIE_KILL),
    DRLocationData("Zombie Genocider: Kill 53,594 zombies across the mall", "Victory", DRLocationCategory.EVENT),
]


# KillSanity: every kill in an area up to its genocide threshold is a
# location. Built in full so IDs are stable; the option and the tier decide
# how many are created. The area tops sum to the Genocider count.
KILL_SANITY_TOPS: Dict[str, int] = {
    _region: max(_tiers["genocide"]) for _region, _tiers in ZOMBIE_KILL_TIERS.items()
}
KILL_SANITY_MAX = sum(KILL_SANITY_TOPS.values())


def kill_sanity_location_name(n: int, region: str) -> str:
    return f"Zombie Kill {n} in {region}"


location_tables["Kill Sanity"] = [
    DRLocationData(kill_sanity_location_name(_n, _region), "Milk", DRLocationCategory.KILL_SANITY)
    for _region, _top in KILL_SANITY_TOPS.items()
    for _n in range(1, _top + 1)
]

# The area each kill location counts for. The region above is a neutral one,
# so the name is the only place the area survives -- Rules.py needs it back.
ZOMBIE_KILL_REGION_OF = {
    zombie_kill_location_name(_threshold, _region): _region
    for _region, _tiers in ZOMBIE_KILL_TIERS.items()
    for _threshold in _tiers["genocide"]
}

# ---------------------------------------------------------------------------
# Psycho goal
# ---------------------------------------------------------------------------
# There is one "Kill <name>" beside every "Rescue <name>", in the same region.
# This maps a survivor's name to their kill location so the rules can be built
# from the rescue rules rather than written out twice.
KILL_LOCATION_OF: dict = {
    _d.name[len("Kill "):]: _d.name
    for _table in location_tables.values()
    for _d in _table
    if _d.category == DRLocationCategory.KILL_SURVIVOR
    and not _d.name.endswith(" survivors")
}

# The survivor ladder. Psycho counts kills where a normal seed counts
# rescues, so both use these numbers -- 48 rather than 50 because Brad,
# Barnaby and Isabela cannot be counted.
SURVIVOR_MILESTONES = [5, 10, 15, 20, 25, 30, 35, 40, 45, 48]


location_dictionary.update({
    location_data.name: location_data
    for location_table in location_tables.values()
    for location_data in location_table
})
