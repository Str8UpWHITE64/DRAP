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
    ("Zuchini", 31, DRItemCategory.CONSUMABLE),
    ("Energizer Smoothie", 32, DRItemCategory.CONSUMABLE),
    ("Nectar Smoothie", 33, DRItemCategory.CONSUMABLE),
    ("Fleetfoot Smoothie", 34, DRItemCategory.CONSUMABLE),
    ("Randomizer Smoothie", 35, DRItemCategory.CONSUMABLE),
    ("Spitfire Smoothie", 36, DRItemCategory.CONSUMABLE),
    ("Untouchable Smoothie", 37, DRItemCategory.CONSUMABLE),
    ("Zombait Smoothie", 38, DRItemCategory.CONSUMABLE),

    # Weapons
    ("2 x 4", 39, DRItemCategory.CONSUMABLE),
    ("Baking Ingredients", 40, DRItemCategory.CONSUMABLE),
    ("Barbell", 41, DRItemCategory.CONSUMABLE),
    ("Baseball Bat", 42, DRItemCategory.CONSUMABLE),
    ("Battle Axe", 43, DRItemCategory.CONSUMABLE),
    ("Bench", 44, DRItemCategory.CONSUMABLE),
    ("Bicycle", 45, DRItemCategory.CONSUMABLE),
    ("Boomerang", 46, DRItemCategory.CONSUMABLE),
    ("Bowling Ball", 47, DRItemCategory.CONSUMABLE),
    ("Bucket", 48, DRItemCategory.CONSUMABLE),
    ("Cactus", 49, DRItemCategory.CONSUMABLE),
    ("Can Drinks", 50, DRItemCategory.CONSUMABLE),
    ("Canned Food", 51, DRItemCategory.CONSUMABLE),
    ("Canned Sauce", 52, DRItemCategory.CONSUMABLE),
    ("Cardboard Box", 53, DRItemCategory.CONSUMABLE),
    ("Cash Register", 54, DRItemCategory.CONSUMABLE),
    ("CDs", 55, DRItemCategory.CONSUMABLE),
    ("Ceremonial Sword", 56, DRItemCategory.CONSUMABLE),
    ("Chainsaw", 57, DRItemCategory.CONSUMABLE),
    ("Chair", 58, DRItemCategory.CONSUMABLE),
    ("Chair (White)", 59, DRItemCategory.CONSUMABLE),
    ("Cleaver", 60, DRItemCategory.CONSUMABLE),
    ("Condiment", 61, DRItemCategory.CONSUMABLE),
    ("Convertible", 62, DRItemCategory.CONSUMABLE),
    ("Cooking Oil", 63, DRItemCategory.CONSUMABLE),
    ("Delivery Truck", 64, DRItemCategory.CONSUMABLE),
    ("Dishes", 65, DRItemCategory.CONSUMABLE),
    ("Dumbbell", 66, DRItemCategory.CONSUMABLE),
    ("Excavator", 67, DRItemCategory.CONSUMABLE),
    ("Fence", 68, DRItemCategory.CONSUMABLE),
    ("Fire Ax", 69, DRItemCategory.CONSUMABLE),
    ("Fire Extinguisher", 70, DRItemCategory.CONSUMABLE),
    ("Frying Pan (heated)", 71, DRItemCategory.CONSUMABLE),
    ("Frying Pan (unheated)", 72, DRItemCategory.CONSUMABLE),
    ("Garbage Can", 73, DRItemCategory.CONSUMABLE),
    ("Gems", 74, DRItemCategory.CONSUMABLE),
    ("Golf Club", 75, DRItemCategory.CONSUMABLE),
    ("Acoustic Guitar", 76, DRItemCategory.CONSUMABLE),
    ("Bass Guitar", 77, DRItemCategory.CONSUMABLE),
    ("Electric Guitar", 78, DRItemCategory.CONSUMABLE),
    ("Gumball Machine", 79, DRItemCategory.CONSUMABLE),
    ("Hand Gun", 80, DRItemCategory.CONSUMABLE),
    ("Handbag", 81, DRItemCategory.CONSUMABLE),
    ("Hanger", 82, DRItemCategory.CONSUMABLE),
    ("HDTV", 83, DRItemCategory.CONSUMABLE),
    ("Heavy Machinegun", 84, DRItemCategory.CONSUMABLE),
    ("Hedge Trimmer", 85, DRItemCategory.CONSUMABLE),
    ("Hockey Stick", 86, DRItemCategory.CONSUMABLE),
    ("Hunk of Meat", 87, DRItemCategory.CONSUMABLE),
    ("Hunting Knife", 88, DRItemCategory.CONSUMABLE),
    ("Jeep", 89, DRItemCategory.CONSUMABLE),
    ("Katana", 90, DRItemCategory.CONSUMABLE),
    ("King Salmon", 91, DRItemCategory.CONSUMABLE),
    ("Laser Sword", 92, DRItemCategory.CONSUMABLE),
    ("Lawn Mower", 93, DRItemCategory.CONSUMABLE),
    ("Lead Pipe", 94, DRItemCategory.CONSUMABLE),
    ("Lipstick Prop", 95, DRItemCategory.CONSUMABLE),
    ("Machete", 96, DRItemCategory.CONSUMABLE),
    ("Machinegun", 97, DRItemCategory.CONSUMABLE),
    ("Mailbox", 98, DRItemCategory.CONSUMABLE),
    ("Mailbox Post", 99, DRItemCategory.CONSUMABLE),
    ("Mannequin", 100, DRItemCategory.CONSUMABLE),
    ("Mannequin", 101, DRItemCategory.CONSUMABLE),
    ("Mannequin Leg", 102, DRItemCategory.CONSUMABLE),
    ("Mannequin Torso", 103, DRItemCategory.CONSUMABLE),
    ("Meat Cleaver", 104, DRItemCategory.CONSUMABLE),
    ("Mega Buster", 105, DRItemCategory.CONSUMABLE),
    ("Molotov Cocktail", 106, DRItemCategory.CONSUMABLE),
    ("Motorcycle", 107, DRItemCategory.CONSUMABLE),
    ("Nail Gun", 108, DRItemCategory.CONSUMABLE),
    ("Nightstick", 109, DRItemCategory.CONSUMABLE),
    ("Novelty Mask (Bear)", 110, DRItemCategory.CONSUMABLE),
    ("Novelty Mask (Ghoul)", 111, DRItemCategory.CONSUMABLE),
    ("Novelty Mask (Horse)", 112, DRItemCategory.CONSUMABLE),
    ("Novelty Mask (Servbot)", 113, DRItemCategory.CONSUMABLE),
    ("Oil Bucket", 114, DRItemCategory.CONSUMABLE),
    ("Paint Can", 115, DRItemCategory.CONSUMABLE),
    ("Painting", 116, DRItemCategory.CONSUMABLE),
    ("Parasol", 117, DRItemCategory.CONSUMABLE),
    ("Perfume Prop", 118, DRItemCategory.CONSUMABLE),
    ("Pet Food", 119, DRItemCategory.CONSUMABLE),
    ("Pickaxe", 120, DRItemCategory.CONSUMABLE),
    ("Pie", 121, DRItemCategory.CONSUMABLE),
    ("Plywood Panel", 122, DRItemCategory.CONSUMABLE),
    ("Potted Plant Bamboo", 123, DRItemCategory.CONSUMABLE),
    ("Potted Plant Tall Bush", 124, DRItemCategory.CONSUMABLE),
    ("Potted Plant Small Fern", 125, DRItemCategory.CONSUMABLE),
    ("Propane Tank", 126, DRItemCategory.CONSUMABLE),
    ("Push Broom", 127, DRItemCategory.CONSUMABLE),
    ("Push Broom Handle", 128, DRItemCategory.CONSUMABLE),
    ("Pylon", 129, DRItemCategory.CONSUMABLE),
    ("Queen", 130, DRItemCategory.CONSUMABLE),
    ("Rat Saucer", 131, DRItemCategory.CONSUMABLE),
    ("Rat Stick", 132, DRItemCategory.CONSUMABLE),
    ("Real Mega Buster", 133, DRItemCategory.CONSUMABLE),
    ("Rock", 134, DRItemCategory.CONSUMABLE),
    ("Sausage Rack", 135, DRItemCategory.CONSUMABLE),
    ("Saw Blade", 136, DRItemCategory.CONSUMABLE),
    ("Shampoo", 137, DRItemCategory.CONSUMABLE),
    ("Shelf", 138, DRItemCategory.CONSUMABLE),
    ("Shopping Cart", 139, DRItemCategory.CONSUMABLE),
    ("Shotgun", 140, DRItemCategory.CONSUMABLE),
    ("Shovel", 141, DRItemCategory.CONSUMABLE),
    ("Shower Head", 142, DRItemCategory.CONSUMABLE),
    ("Sickle", 143, DRItemCategory.CONSUMABLE),
    ("Sign", 144, DRItemCategory.CONSUMABLE),
    ("Skateboard", 145, DRItemCategory.CONSUMABLE),
    ("Skylight", 146, DRItemCategory.CONSUMABLE),
    ("Sledgehammer", 147, DRItemCategory.CONSUMABLE),
    ("Small Chainsaw", 148, DRItemCategory.CONSUMABLE),
    ("Smokestack", 149, DRItemCategory.CONSUMABLE),
    ("Sniper Rifle", 150, DRItemCategory.CONSUMABLE),
    ("Soccer Ball", 151, DRItemCategory.CONSUMABLE),
    ("Steel Rack", 152, DRItemCategory.CONSUMABLE),
    ("Step Ladder", 153, DRItemCategory.CONSUMABLE),
    ("Stool", 154, DRItemCategory.CONSUMABLE),
    ("Store Display", 155, DRItemCategory.CONSUMABLE),
    ("Stuffed Bear", 156, DRItemCategory.CONSUMABLE),
    ("Stun Gun", 157, DRItemCategory.CONSUMABLE),
    ("Sub-machine Gun", 158, DRItemCategory.CONSUMABLE),
    ("Sword", 159, DRItemCategory.CONSUMABLE),
    ("Toolbox", 160, DRItemCategory.CONSUMABLE),
    ("Toy Cube", 161, DRItemCategory.CONSUMABLE),
    ("Toy Laser Sword", 162, DRItemCategory.CONSUMABLE),
    ("TV", 163, DRItemCategory.CONSUMABLE),
    ("Vase", 164, DRItemCategory.CONSUMABLE),
    ("Water Gun", 165, DRItemCategory.CONSUMABLE),
    ("CONSUMABLE Cart", 166, DRItemCategory.CONSUMABLE),
    ("White Sedan", 167, DRItemCategory.CONSUMABLE),
    ("Wine Cask", 168, DRItemCategory.CONSUMABLE),

    # Area locks
    ("Helipad key", 169, DRItemCategory.CONSUMABLE),
    ("Safe Room key", 170, DRItemCategory.CONSUMABLE),
    ("Rooftop key", 171, DRItemCategory.CONSUMABLE),
    ("Warehouse key", 172, DRItemCategory.CONSUMABLE),
    ("Paradise Plaza key", 173, DRItemCategory.CONSUMABLE),
    ("Colby's Movie Theater key", 174, DRItemCategory.CONSUMABLE),
    ("Leisure Park key", 175, DRItemCategory.CONSUMABLE),
    ("North Plaza key", 176, DRItemCategory.CONSUMABLE),
    ("Crisip's Hardware Store key", 177, DRItemCategory.CONSUMABLE),
    ("Food Court key", 178, DRItemCategory.CONSUMABLE),
    ("Wonderland Plaza key", 179, DRItemCategory.CONSUMABLE),
    ("Al Fresca Plaza key", 180, DRItemCategory.CONSUMABLE),
    ("Entrance Plaza key", 181, DRItemCategory.CONSUMABLE),
    ("Grocery Store key", 182, DRItemCategory.CONSUMABLE),
    ("Maintenance Tunnel key", 183, DRItemCategory.CONSUMABLE),
    ("Hideout key", 184, DRItemCategory.CONSUMABLE),

    # Time locks
    ("DAY2_06_AM", 185, DRItemCategory.CONSUMABLE),
    ("DAY2_11_AM", 186, DRItemCategory.CONSUMABLE),
    ("DAY3_00_AM", 187, DRItemCategory.CONSUMABLE),
    ("DAY3_11_AM", 188, DRItemCategory.CONSUMABLE),
    ("DAY4_12_PM", 189, DRItemCategory.CONSUMABLE),

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
    for i in range(remaining_count):
        item = multiworld.random.choice(itemList)
        item_pool.append(item)

    multiworld.random.shuffle(item_pool)
    return item_pool
