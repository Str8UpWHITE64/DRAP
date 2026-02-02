from enum import IntEnum
from typing import NamedTuple
from BaseClasses import Item
from Options import OptionError


class DRItemCategory(IntEnum):
    SKIP = 0,
    EVENT = 1,
    CONSUMABLE = 2,
    MISC = 3,
    TRAP = 4,
    LOCK = 5,
    WEAPON = 6,


class DRItemData(NamedTuple):
    name: str
    dr_code: int
    category: DRItemCategory


class DRItem(Item):
    game: str = "Dead Rising Deluxe Remaster"

    @staticmethod
    def get_name_to_id() -> dict:
        base_id = 1230000
        return {item_data.name: (base_id + item_data.dr_code if item_data.dr_code is not None else None) for item_data
                in _all_items}


key_item_names = {
}

_all_items = [DRItemData(row[0], row[1], row[2]) for row in [
    # Events
    ("Victory", 1000, DRItemCategory.EVENT),

    # Consumables (starting at dr_code 1)
    ("Apple", 1, DRItemCategory.CONSUMABLE),
    ("Baguette", 2, DRItemCategory.CONSUMABLE),
    ("Cabbage", 3, DRItemCategory.CONSUMABLE),
    ("Cheese", 4, DRItemCategory.CONSUMABLE),
    ("Coffee Creamer", 5, DRItemCategory.CONSUMABLE),
    ("Cookies", 6, DRItemCategory.CONSUMABLE),
    ("Corn", 7, DRItemCategory.CONSUMABLE),
    ("Frozen Vegetables", 8, DRItemCategory.CONSUMABLE),
    ("Golden Brown Pizza", 9, DRItemCategory.CONSUMABLE),
    ("Grapefruit", 10, DRItemCategory.CONSUMABLE),
    ("Ice Pops", 11, DRItemCategory.CONSUMABLE),
    ("Japanese Radish", 12, DRItemCategory.CONSUMABLE),
    ("Lettuce", 13, DRItemCategory.CONSUMABLE),
    ("Melon", 14, DRItemCategory.CONSUMABLE),
    ("Melted Ice Pops", 15, DRItemCategory.CONSUMABLE),
    ("Milk", 16, DRItemCategory.CONSUMABLE),
    ("Orange", 17, DRItemCategory.CONSUMABLE),
    ("Orange Juice", 18, DRItemCategory.CONSUMABLE),
    ("Pie", 19, DRItemCategory.CONSUMABLE),
    ("Raw Meat", 20, DRItemCategory.CONSUMABLE),
    ("Red Cabbage", 21, DRItemCategory.CONSUMABLE),
    ("Rotten Pizza", 22, DRItemCategory.CONSUMABLE),
    ("Snack", 23, DRItemCategory.CONSUMABLE),
    ("Squash", 24, DRItemCategory.CONSUMABLE),
    ("Spoiled Meat", 25, DRItemCategory.CONSUMABLE),
    ("Thawed Vegetables", 26, DRItemCategory.CONSUMABLE),
    ("Uncooked Pizza", 27, DRItemCategory.CONSUMABLE),
    ("Well Done Steak", 28, DRItemCategory.CONSUMABLE),
    ("Wine", 29, DRItemCategory.CONSUMABLE),
    ("Yogurt", 30, DRItemCategory.CONSUMABLE),
    ("Zucchini", 31, DRItemCategory.CONSUMABLE),
    ("Juice [Energizer]", 32, DRItemCategory.CONSUMABLE),
    ("Juice [Nectar]", 33, DRItemCategory.CONSUMABLE),
    ("Juice [Quickstep]", 34, DRItemCategory.CONSUMABLE),
    ("Juice [Randomizer]", 35, DRItemCategory.CONSUMABLE),
    ("Juice [Spitfire]", 36, DRItemCategory.CONSUMABLE),
    ("Juice [Untouchable]", 37, DRItemCategory.CONSUMABLE),
    ("Juice [Zombait]", 38, DRItemCategory.CONSUMABLE),

    # Weapons
    ("2 x 4", 39, DRItemCategory.WEAPON),
    ("Baking Ingredients", 40, DRItemCategory.WEAPON),
    ("Barbell", 41, DRItemCategory.WEAPON),
    ("Baseball Bat", 42, DRItemCategory.WEAPON),
    ("Battle Axe", 43, DRItemCategory.WEAPON),
    ("Bench", 44, DRItemCategory.WEAPON),
    # ("Bicycle", 45, DRItemCategory.WEAPON),
    ("Boomerang", 46, DRItemCategory.WEAPON),
    ("Bowling Ball", 47, DRItemCategory.WEAPON),
    ("Bucket", 48, DRItemCategory.WEAPON),
    ("Cactus", 49, DRItemCategory.WEAPON),
    ("Can Drinks", 50, DRItemCategory.WEAPON),
    ("Canned Food", 51, DRItemCategory.WEAPON),
    ("Canned Sauce", 52, DRItemCategory.WEAPON),
    ("Cardboard Box", 53, DRItemCategory.WEAPON),
    ("Cash Register", 54, DRItemCategory.WEAPON),
    ("CDs", 55, DRItemCategory.WEAPON),
    ("Ceremonial Sword", 56, DRItemCategory.WEAPON),
    ("Chainsaw", 57, DRItemCategory.WEAPON),
    ("Chair", 58, DRItemCategory.WEAPON),
    ("Chair (White)", 59, DRItemCategory.WEAPON),
    ("Cleaver", 60, DRItemCategory.WEAPON),
    ("Condiment", 61, DRItemCategory.WEAPON),
    ("Cooking Oil", 63, DRItemCategory.WEAPON),
    ("Dishes", 65, DRItemCategory.WEAPON),
    ("Dumbbell", 66, DRItemCategory.WEAPON),
    ("Excavator", 67, DRItemCategory.WEAPON),
    ("Fence", 68, DRItemCategory.WEAPON),
    ("Fire Ax", 69, DRItemCategory.WEAPON),
    ("Fire Extinguisher", 70, DRItemCategory.WEAPON),
    ("Frying Pan", 71, DRItemCategory.WEAPON),
    # ("Frying Pan (unheated)", 72, DRItemCategory.WEAPON),
    ("Garbage Can", 73, DRItemCategory.WEAPON),
    ("Gems", 74, DRItemCategory.WEAPON),
    ("Golf Club", 75, DRItemCategory.WEAPON),
    ("Acoustic Guitar", 76, DRItemCategory.WEAPON),
    ("Bass Guitar", 77, DRItemCategory.WEAPON),
    ("Electric Guitar", 78, DRItemCategory.WEAPON),
    ("Gumball Machine", 79, DRItemCategory.WEAPON),
    ("Handgun", 80, DRItemCategory.WEAPON),
    ("Handbag", 81, DRItemCategory.WEAPON),
    ("Hanger", 82, DRItemCategory.WEAPON),
    ("HDTV", 83, DRItemCategory.WEAPON),
    ("Heavy Machinegun", 84, DRItemCategory.WEAPON),
    ("Hedge Trimmer", 85, DRItemCategory.WEAPON),
    ("Hockey Stick", 86, DRItemCategory.WEAPON),
    ("Hunk of Meat", 87, DRItemCategory.WEAPON),
    ("Hunting Knife", 88, DRItemCategory.WEAPON),
    ("Katana", 90, DRItemCategory.WEAPON),
    ("King Salmon", 91, DRItemCategory.WEAPON),
    ("Laser Sword", 92, DRItemCategory.WEAPON),
    ("Lawn Mower", 93, DRItemCategory.WEAPON),
    ("Lead Pipe", 94, DRItemCategory.WEAPON),
    ("Lipstick Prop", 95, DRItemCategory.WEAPON),
    ("Machete", 96, DRItemCategory.WEAPON),
    ("Machinegun", 97, DRItemCategory.WEAPON),
    ("Mailbox", 98, DRItemCategory.WEAPON),
    ("Mailbox Post", 99, DRItemCategory.WEAPON),
    ("Meat Cleaver", 104, DRItemCategory.WEAPON),
    ("Mega Buster", 105, DRItemCategory.WEAPON),
    ("Molotov Cocktail", 106, DRItemCategory.WEAPON),
    ("Nail Gun", 108, DRItemCategory.WEAPON),
    ("Nightstick", 109, DRItemCategory.WEAPON),
    ("Novelty Mask (Bear)", 110, DRItemCategory.WEAPON),
    ("Novelty Mask (Ghoul)", 111, DRItemCategory.WEAPON),
    ("Novelty Mask (Horse)", 112, DRItemCategory.WEAPON),
    ("Novelty Mask (Servbot)", 113, DRItemCategory.WEAPON),
    ("Oil Bucket", 114, DRItemCategory.WEAPON),
    ("Paint Can", 115, DRItemCategory.WEAPON),
    ("Painting", 116, DRItemCategory.WEAPON),
    ("Parasol", 117, DRItemCategory.WEAPON),
    ("Perfume Prop", 118, DRItemCategory.WEAPON),
    ("Pet Food", 119, DRItemCategory.WEAPON),
    ("Pickaxe", 120, DRItemCategory.WEAPON),
    ("Pie", 121, DRItemCategory.WEAPON),
    ("Plywood Panel", 122, DRItemCategory.WEAPON),
    ("Potted Plant Bamboo", 123, DRItemCategory.WEAPON),
    ("Potted Plant Tall Bush", 124, DRItemCategory.WEAPON),
    ("Potted Plant Small Fern", 125, DRItemCategory.WEAPON),
    ("Propane Tank", 126, DRItemCategory.WEAPON),
    ("Push Broom", 127, DRItemCategory.WEAPON),
    ("Push Broom Handle", 128, DRItemCategory.WEAPON),
    ("Pylon", 129, DRItemCategory.WEAPON),
    ("Queen", 130, DRItemCategory.WEAPON),
    ("Rat Saucer", 131, DRItemCategory.WEAPON),
    ("Rat Stick", 132, DRItemCategory.WEAPON),
    ("Real Mega Buster", 133, DRItemCategory.WEAPON),
    ("Rock", 134, DRItemCategory.WEAPON),
    ("Sausage Rack", 135, DRItemCategory.WEAPON),
    ("Saw Blade", 136, DRItemCategory.WEAPON),
    ("Shampoo", 137, DRItemCategory.WEAPON),
    ("Shelf", 138, DRItemCategory.WEAPON),
    ("Shopping Cart", 139, DRItemCategory.WEAPON),
    ("Shotgun", 140, DRItemCategory.WEAPON),
    ("Shovel", 141, DRItemCategory.WEAPON),
    ("Shower Head", 142, DRItemCategory.WEAPON),
    ("Sickle", 143, DRItemCategory.WEAPON),
    ("Sign", 144, DRItemCategory.WEAPON),
    ("Skateboard", 145, DRItemCategory.WEAPON),
    ("Skylight", 146, DRItemCategory.WEAPON),
    ("Sledgehammer", 147, DRItemCategory.WEAPON),
    ("Small Chainsaw", 148, DRItemCategory.WEAPON),
    ("Smokestack", 149, DRItemCategory.WEAPON),
    ("Sniper Rifle", 150, DRItemCategory.WEAPON),
    ("Soccer Ball", 151, DRItemCategory.WEAPON),
    ("Steel Rack", 152, DRItemCategory.WEAPON),
    ("Step Ladder", 153, DRItemCategory.WEAPON),
    ("Stool", 154, DRItemCategory.WEAPON),
    ("Store Display", 155, DRItemCategory.WEAPON),
    ("Stuffed Bear", 156, DRItemCategory.WEAPON),
    ("Stun Gun", 157, DRItemCategory.WEAPON),
    ("Submachine Gun", 158, DRItemCategory.WEAPON),
    ("Sword", 159, DRItemCategory.WEAPON),
    ("Toolbox", 160, DRItemCategory.WEAPON),
    ("Toy Cube", 161, DRItemCategory.WEAPON),
    ("Toy Laser Sword", 162, DRItemCategory.WEAPON),
    ("TV", 163, DRItemCategory.WEAPON),
    ("Vase", 164, DRItemCategory.WEAPON),
    ("Water Gun", 165, DRItemCategory.WEAPON),
    ("Weapon Cart", 166, DRItemCategory.WEAPON),
    ("Wine Cask", 168, DRItemCategory.WEAPON),

    ("Mannequin Male", 204, DRItemCategory.WEAPON),
    ("Mannequin Male Torso", 205, DRItemCategory.WEAPON),
    ("Mannequin Male Right Arm", 206, DRItemCategory.WEAPON),
    ("Mannequin Male Left Arm", 207, DRItemCategory.WEAPON),
    ("Mannequin Male Right Leg", 208, DRItemCategory.WEAPON),
    ("Mannequin Male Left Leg", 209, DRItemCategory.WEAPON),
    ("Mannequin Female", 210, DRItemCategory.WEAPON),
    ("Mannequin Female Torso", 211, DRItemCategory.WEAPON),
    ("Mannequin Female Right Arm", 212, DRItemCategory.WEAPON),
    ("Mannequin Female Left Arm", 213, DRItemCategory.WEAPON),
    ("Mannequin Female Right Leg", 214, DRItemCategory.WEAPON),
    ("Mannequin Female Left Leg", 215, DRItemCategory.WEAPON),

    # Books
    ("Book [Camera 2]", 169, DRItemCategory.CONSUMABLE),
    ("Book [Survival]", 170, DRItemCategory.CONSUMABLE),
    ("Book [Brainwashing Tips]", 171, DRItemCategory.CONSUMABLE),
    ("Book [Japanese Conversation]", 172, DRItemCategory.CONSUMABLE),
    ("Book [Wrestling]", 173, DRItemCategory.CONSUMABLE),
    ("Book [Toy]", 174, DRItemCategory.CONSUMABLE),
    ("Book [Firework]", 175, DRItemCategory.CONSUMABLE),
    ("Book [Hypnosis]", 176, DRItemCategory.CONSUMABLE),
    ("Book [Focus]", 177, DRItemCategory.CONSUMABLE),
    ("Book [Blender]", 178, DRItemCategory.CONSUMABLE),
    ("Book [Monster Pitcher]", 179, DRItemCategory.CONSUMABLE),
    ("Book [Recycle]", 180, DRItemCategory.CONSUMABLE),
    ("Book [Martial Arts]", 181, DRItemCategory.CONSUMABLE),
    ("Book [Fashion]", 182, DRItemCategory.CONSUMABLE),
    ("Book [Firearms]", 183, DRItemCategory.CONSUMABLE),
    ("Book [Infinite Durability]", 184, DRItemCategory.CONSUMABLE),
    ("Book [Hobby]", 185, DRItemCategory.CONSUMABLE),
    ("Book [Cooking]", 186, DRItemCategory.CONSUMABLE),
    ("Book [Lifestyle Magazine]", 187, DRItemCategory.CONSUMABLE),
    ("Book [Engineering]", 188, DRItemCategory.CONSUMABLE),
    ("Book [Sports]", 189, DRItemCategory.CONSUMABLE),
    ("Book [Criminal Biography]", 190, DRItemCategory.CONSUMABLE),
    ("Book [Travel]", 191, DRItemCategory.CONSUMABLE),
    ("Book [Interior Design]", 192, DRItemCategory.CONSUMABLE),
    ("Book [Entertainment]", 193, DRItemCategory.CONSUMABLE),
    ("Book [Camera 1]", 194, DRItemCategory.CONSUMABLE),
    ("Book [Skateboarding]", 195, DRItemCategory.CONSUMABLE),
    ("Book [Wartime Photography]", 196, DRItemCategory.CONSUMABLE),
    ("Book [Weekly Photo Magazine]", 197, DRItemCategory.CONSUMABLE),
    ("Book [Horror Novel 1]", 198, DRItemCategory.CONSUMABLE),
    ("Book [World News]", 199, DRItemCategory.CONSUMABLE),
    ("Book [Health 1]", 200, DRItemCategory.CONSUMABLE),
    ("Book [Cycling]", 201, DRItemCategory.CONSUMABLE),
    ("Book [Health 2]", 202, DRItemCategory.CONSUMABLE),
    ("Book [Horror Novel 2]", 203, DRItemCategory.CONSUMABLE),

    # Area locks
    # ("Helipad key", 1000, DRItemCategory.LOCK),
    # ("Safe Room key", 1001, DRItemCategory.LOCK),
    ("Rooftop key", 1002, DRItemCategory.LOCK),
    # ("Warehouse key", 1003, DRItemCategory.LOCK),
    ("Paradise Plaza key", 1004, DRItemCategory.LOCK),
    ("Colby's Movie Theater key", 1005, DRItemCategory.LOCK),
    ("Leisure Park key", 1006, DRItemCategory.LOCK),
    ("North Plaza key", 1007, DRItemCategory.LOCK),
    ("Crislip's Hardware Store key", 1008, DRItemCategory.LOCK),
    ("Food Court key", 1009, DRItemCategory.LOCK),
    ("Wonderland Plaza key", 1010, DRItemCategory.LOCK),
    ("Al Fresca Plaza key", 1011, DRItemCategory.LOCK),
    ("Entrance Plaza key", 1012, DRItemCategory.LOCK),
    ("Grocery Store key", 1013, DRItemCategory.LOCK),
    ("Maintenance Tunnel key", 1014, DRItemCategory.LOCK),
    ("Hideout key", 1015, DRItemCategory.LOCK),
    ("Service Hallway key", 1016, DRItemCategory.LOCK),

    # Time locks
    ("DAY2_06_AM", 2000, DRItemCategory.LOCK),
    ("DAY2_11_AM", 2001, DRItemCategory.LOCK),
    ("DAY3_00_AM", 2002, DRItemCategory.LOCK),
    ("DAY3_11_AM", 2003, DRItemCategory.LOCK),
    ("DAY4_12_PM", 2004, DRItemCategory.LOCK),
]]

item_descriptions = {}

item_dictionary = {item_data.name: item_data for item_data in _all_items}


def BuildItemPool(multiworld, count, options):
    item_pool = []
    included_itemcount = 0

    if options.guaranteed_items.value:
        for item_name in options.guaranteed_items.value:
            item = item_dictionary[item_name]
            item_pool.append(item)
            included_itemcount = included_itemcount + 1
    remaining_count = count - included_itemcount

    itemList = [item for item in _all_items]
    lockList = [item for item in _all_items if item.category == DRItemCategory.LOCK]
    consumableList = [item for item in _all_items if item.category == DRItemCategory.CONSUMABLE]
    weaponList = [item for item in _all_items if item.category == DRItemCategory.WEAPON]
    fillerList = [item for item in itemList if item.category in (DRItemCategory.MISC, DRItemCategory.TRAP, DRItemCategory.WEAPON, DRItemCategory.CONSUMABLE)]
    
    for lock in lockList:
        item = item_dictionary[lock.name]
        item_pool.append(item)
        remaining_count = remaining_count - 1
        included_itemcount = included_itemcount + 1

    for i in range(remaining_count):
        item = multiworld.random.choice(fillerList)
        item_pool.append(item)

    multiworld.random.shuffle(item_pool)
    return item_pool
