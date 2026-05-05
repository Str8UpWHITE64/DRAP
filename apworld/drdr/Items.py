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
    SCOOP = 7,
    SKILL = 8,         # 21 player-skill items (Useful)
    UPGRADE = 9,       # 6 progressive stat upgrades (Useful)
    BUFF = 10,         # 7 filler buff items (juice effects + Heal/Berserker/PP)


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
    ("Victory", 9000, DRItemCategory.EVENT),

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
    ("Acoustic Guitar", 40, DRItemCategory.WEAPON),
    ("Baking Ingredients", 41, DRItemCategory.WEAPON),
    ("Barbell", 42, DRItemCategory.WEAPON),
    ("Baseball Bat", 43, DRItemCategory.WEAPON),
    ("Bass Guitar", 44, DRItemCategory.WEAPON),
    ("Battle Axe", 45, DRItemCategory.WEAPON),
    ("Bench", 46, DRItemCategory.WEAPON),
    ("Boomerang", 47, DRItemCategory.WEAPON),
    ("Bowling Ball", 48, DRItemCategory.WEAPON),
    ("Bucket", 49, DRItemCategory.WEAPON),
    ("Cactus", 50, DRItemCategory.WEAPON),
    ("Can Drinks", 51, DRItemCategory.WEAPON),
    ("Canned Food", 52, DRItemCategory.WEAPON),
    ("Canned Sauce", 53, DRItemCategory.WEAPON),
    ("Cardboard Box", 54, DRItemCategory.WEAPON),
    ("Cash Register", 55, DRItemCategory.WEAPON),
    ("CDs", 56, DRItemCategory.WEAPON),
    ("Ceremonial Sword", 57, DRItemCategory.WEAPON),
    ("Chainsaw", 58, DRItemCategory.WEAPON),
    ("Chair", 59, DRItemCategory.WEAPON),
    ("Chair (White)", 60, DRItemCategory.WEAPON),
    ("Cleaver", 61, DRItemCategory.WEAPON),
    ("Condiment", 62, DRItemCategory.WEAPON),
    ("Cooking Oil", 63, DRItemCategory.WEAPON),
    ("Dishes", 64, DRItemCategory.WEAPON),
    ("Dumbbell", 65, DRItemCategory.WEAPON),
    ("Electric Guitar", 66, DRItemCategory.WEAPON),
    ("Excavator", 67, DRItemCategory.WEAPON),
    ("Fence", 68, DRItemCategory.WEAPON),
    ("Fire Ax", 69, DRItemCategory.WEAPON),
    ("Fire Extinguisher", 70, DRItemCategory.WEAPON),
    ("Frying Pan", 71, DRItemCategory.WEAPON),
    ("Garbage Can", 72, DRItemCategory.WEAPON),
    ("Gems", 73, DRItemCategory.WEAPON),
    ("Golf Club", 74, DRItemCategory.WEAPON),
    ("Gumball Machine", 75, DRItemCategory.WEAPON),
    ("Handbag", 76, DRItemCategory.WEAPON),
    ("Handgun", 77, DRItemCategory.WEAPON),
    ("Hanger", 78, DRItemCategory.WEAPON),
    ("HDTV", 79, DRItemCategory.WEAPON),
    ("Heavy Machinegun", 80, DRItemCategory.WEAPON),
    ("Hedge Trimmer", 81, DRItemCategory.WEAPON),
    ("Hockey Stick", 82, DRItemCategory.WEAPON),
    ("Hunk of Meat", 83, DRItemCategory.WEAPON),
    ("Hunting Knife", 84, DRItemCategory.WEAPON),
    ("Katana", 85, DRItemCategory.WEAPON),
    ("King Salmon", 86, DRItemCategory.WEAPON),
    ("Laser Sword", 87, DRItemCategory.WEAPON),
    ("Lawn Mower", 88, DRItemCategory.WEAPON),
    ("Lead Pipe", 89, DRItemCategory.WEAPON),
    ("Lipstick Prop", 90, DRItemCategory.WEAPON),
    ("Machete", 91, DRItemCategory.WEAPON),
    ("Machinegun", 92, DRItemCategory.WEAPON),
    ("Mailbox", 93, DRItemCategory.WEAPON),
    ("Mailbox Post", 94, DRItemCategory.WEAPON),
    ("Mannequin Female", 95, DRItemCategory.WEAPON),
    ("Mannequin Female Left Arm", 96, DRItemCategory.WEAPON),
    ("Mannequin Female Left Leg", 97, DRItemCategory.WEAPON),
    ("Mannequin Female Right Arm", 98, DRItemCategory.WEAPON),
    ("Mannequin Female Right Leg", 99, DRItemCategory.WEAPON),
    ("Mannequin Female Torso", 100, DRItemCategory.WEAPON),
    ("Mannequin Male", 101, DRItemCategory.WEAPON),
    ("Mannequin Male Left Arm", 102, DRItemCategory.WEAPON),
    ("Mannequin Male Left Leg", 103, DRItemCategory.WEAPON),
    ("Mannequin Male Right Arm", 104, DRItemCategory.WEAPON),
    ("Mannequin Male Right Leg", 105, DRItemCategory.WEAPON),
    ("Mannequin Male Torso", 106, DRItemCategory.WEAPON),
    ("Meat Cleaver", 107, DRItemCategory.WEAPON),
    ("Mega Buster", 108, DRItemCategory.WEAPON),
    ("Molotov Cocktail", 109, DRItemCategory.WEAPON),
    ("Nail Gun", 110, DRItemCategory.WEAPON),
    ("Nightstick", 111, DRItemCategory.WEAPON),
    ("Novelty Mask (Bear)", 112, DRItemCategory.WEAPON),
    ("Novelty Mask (Ghoul)", 113, DRItemCategory.WEAPON),
    ("Novelty Mask (Horse)", 114, DRItemCategory.WEAPON),
    ("Novelty Mask (Servbot)", 115, DRItemCategory.WEAPON),
    ("Oil Bucket", 116, DRItemCategory.WEAPON),
    ("Paint Can", 117, DRItemCategory.WEAPON),
    ("Painting", 118, DRItemCategory.WEAPON),
    ("Parasol", 119, DRItemCategory.WEAPON),
    ("Perfume Prop", 120, DRItemCategory.WEAPON),
    ("Pet Food", 121, DRItemCategory.WEAPON),
    ("Pickaxe", 122, DRItemCategory.WEAPON),
    ("Pie", 123, DRItemCategory.WEAPON),
    ("Plywood Panel", 124, DRItemCategory.WEAPON),
    ("Potted Plant Bamboo", 125, DRItemCategory.WEAPON),
    ("Potted Plant Small Fern", 126, DRItemCategory.WEAPON),
    ("Potted Plant Tall Bush", 127, DRItemCategory.WEAPON),
    ("Propane Tank", 128, DRItemCategory.WEAPON),
    ("Push Broom", 129, DRItemCategory.WEAPON),
    ("Push Broom Handle", 130, DRItemCategory.WEAPON),
    ("Pylon", 131, DRItemCategory.WEAPON),
    ("Queen", 132, DRItemCategory.WEAPON),
    ("Rat Saucer", 133, DRItemCategory.WEAPON),
    ("Rat Stick", 134, DRItemCategory.WEAPON),
    ("Real Mega Buster", 135, DRItemCategory.WEAPON),
    ("Rock", 136, DRItemCategory.WEAPON),
    ("Sausage Rack", 137, DRItemCategory.WEAPON),
    ("Saw Blade", 138, DRItemCategory.WEAPON),
    ("Shampoo", 139, DRItemCategory.WEAPON),
    ("Shelf", 140, DRItemCategory.WEAPON),
    ("Shopping Cart", 141, DRItemCategory.WEAPON),
    ("Shotgun", 142, DRItemCategory.WEAPON),
    ("Shovel", 143, DRItemCategory.WEAPON),
    ("Shower Head", 144, DRItemCategory.WEAPON),
    ("Sickle", 145, DRItemCategory.WEAPON),
    ("Sign", 146, DRItemCategory.WEAPON),
    ("Skateboard", 147, DRItemCategory.WEAPON),
    ("Skylight", 148, DRItemCategory.WEAPON),
    ("Sledgehammer", 149, DRItemCategory.WEAPON),
    ("Small Chainsaw", 150, DRItemCategory.WEAPON),
    ("Smokestack", 151, DRItemCategory.WEAPON),
    ("Sniper Rifle", 152, DRItemCategory.WEAPON),
    ("Soccer Ball", 153, DRItemCategory.WEAPON),
    ("Steel Rack", 154, DRItemCategory.WEAPON),
    ("Step Ladder", 155, DRItemCategory.WEAPON),
    ("Stool", 156, DRItemCategory.WEAPON),
    ("Store Display", 157, DRItemCategory.WEAPON),
    ("Stuffed Bear", 158, DRItemCategory.WEAPON),
    ("Stun Gun", 159, DRItemCategory.WEAPON),
    ("Submachine Gun", 160, DRItemCategory.WEAPON),
    ("Sword", 161, DRItemCategory.WEAPON),
    ("Toolbox", 162, DRItemCategory.WEAPON),
    ("Toy Cube", 163, DRItemCategory.WEAPON),
    ("Toy Laser Sword", 164, DRItemCategory.WEAPON),
    ("TV", 165, DRItemCategory.WEAPON),
    ("Vase", 166, DRItemCategory.WEAPON),
    ("Water Gun", 167, DRItemCategory.WEAPON),
    ("Weapon Cart", 168, DRItemCategory.WEAPON),
    ("Wine Cask", 169, DRItemCategory.WEAPON),

    # Books
    ("Book [Blender]", 170, DRItemCategory.CONSUMABLE),
    ("Book [Brainwashing Tips]", 171, DRItemCategory.CONSUMABLE),
    ("Book [Camera 1]", 172, DRItemCategory.CONSUMABLE),
    ("Book [Camera 2]", 173, DRItemCategory.CONSUMABLE),
    ("Book [Cooking]", 174, DRItemCategory.CONSUMABLE),
    ("Book [Criminal Biography]", 175, DRItemCategory.CONSUMABLE),
    ("Book [Cycling]", 176, DRItemCategory.CONSUMABLE),
    ("Book [Engineering]", 177, DRItemCategory.CONSUMABLE),
    ("Book [Entertainment]", 178, DRItemCategory.CONSUMABLE),
    ("Book [Fashion]", 179, DRItemCategory.CONSUMABLE),
    ("Book [Firearms]", 180, DRItemCategory.CONSUMABLE),
    ("Book [Firework]", 181, DRItemCategory.CONSUMABLE),
    ("Book [Focus]", 182, DRItemCategory.CONSUMABLE),
    ("Book [Health 1]", 183, DRItemCategory.CONSUMABLE),
    ("Book [Health 2]", 184, DRItemCategory.CONSUMABLE),
    ("Book [Hobby]", 185, DRItemCategory.CONSUMABLE),
    ("Book [Horror Novel 1]", 186, DRItemCategory.CONSUMABLE),
    ("Book [Horror Novel 2]", 187, DRItemCategory.CONSUMABLE),
    ("Book [Hypnosis]", 188, DRItemCategory.CONSUMABLE),
    ("Book [Infinite Durability]", 189, DRItemCategory.CONSUMABLE),
    ("Book [Interior Design]", 190, DRItemCategory.CONSUMABLE),
    ("Book [Japanese Conversation]", 191, DRItemCategory.CONSUMABLE),
    ("Book [Lifestyle Magazine]", 192, DRItemCategory.CONSUMABLE),
    ("Book [Martial Arts]", 193, DRItemCategory.CONSUMABLE),
    ("Book [Monster Pitcher]", 194, DRItemCategory.CONSUMABLE),
    ("Book [Recycle]", 195, DRItemCategory.CONSUMABLE),
    ("Book [Skateboarding]", 196, DRItemCategory.CONSUMABLE),
    ("Book [Sports]", 197, DRItemCategory.CONSUMABLE),
    ("Book [Survival]", 198, DRItemCategory.CONSUMABLE),
    ("Book [Toy]", 199, DRItemCategory.CONSUMABLE),
    ("Book [Travel]", 200, DRItemCategory.CONSUMABLE),
    ("Book [Wartime Photography]", 201, DRItemCategory.CONSUMABLE),
    ("Book [Weekly Photo Magazine]", 202, DRItemCategory.CONSUMABLE),
    ("Book [World News]", 203, DRItemCategory.CONSUMABLE),
    ("Book [Wrestling]", 204, DRItemCategory.CONSUMABLE),

    # Area locks
    ("Al Fresca Plaza key", 1000, DRItemCategory.LOCK),
    ("Colby's Movieland key", 1001, DRItemCategory.LOCK),
    ("Crislip's Home Saloon key", 1002, DRItemCategory.LOCK),
    ("Entrance Plaza key", 1003, DRItemCategory.LOCK),
    ("Food Court key", 1004, DRItemCategory.LOCK),
    ("Seon's Food and Stuff key", 1005, DRItemCategory.LOCK),
    ("Carlito's Hideout key", 1006, DRItemCategory.LOCK),
    ("Leisure Park key", 1007, DRItemCategory.LOCK),
    ("Maintenance Tunnel key", 1008, DRItemCategory.LOCK),
    ("North Plaza key", 1009, DRItemCategory.LOCK),
    ("Paradise Plaza key", 1010, DRItemCategory.LOCK),
    ("Rooftop key", 1011, DRItemCategory.LOCK),
    ("Warehouse key", 1012, DRItemCategory.LOCK),
    ("Wonderland Plaza key", 1013, DRItemCategory.LOCK),

    # Special Items
    ("Maintenance Tunnel Access Key", 1100, DRItemCategory.LOCK),

    # Time locks
    ("DAY2_06_AM", 2000, DRItemCategory.LOCK),
    ("DAY2_11_AM", 2001, DRItemCategory.LOCK),
    ("DAY3_00_AM", 2002, DRItemCategory.LOCK),
    ("DAY3_11_AM", 2003, DRItemCategory.LOCK),
    ("DAY4_12_PM", 2004, DRItemCategory.LOCK),

    # Main Scoops
    ("Backup for Brad", 3000, DRItemCategory.SCOOP),
    ("A Temporary Agreement", 3001, DRItemCategory.SCOOP),
    ("Image in the Monitor", 3002, DRItemCategory.SCOOP),
    ("Rescue the Professor", 3003, DRItemCategory.SCOOP),
    ("Medicine Run", 3004, DRItemCategory.SCOOP),
    ("Professor's Past", 3005, DRItemCategory.SCOOP),
    ("Girl Hunting", 3006, DRItemCategory.SCOOP),
    ("A Promise to Isabela", 3007, DRItemCategory.SCOOP),
    ("Santa Cabeza", 3008, DRItemCategory.SCOOP),
    ("The Last Resort", 3009, DRItemCategory.SCOOP),
    ("Carlito's Hideout", 3010, DRItemCategory.SCOOP),
    ("Jessie's Discovery", 3011, DRItemCategory.SCOOP),
    ("The Butcher", 3012, DRItemCategory.SCOOP),
    # ("The Facts", 3013, DRItemCategory.SCOOP),


    # Survivor Scoops
    ("Barricade Pair", 3100, DRItemCategory.SCOOP),
    ("A Mother's Lament", 3101, DRItemCategory.SCOOP),
    ("Japanese Tourists", 3102, DRItemCategory.SCOOP),
    ("Shadow of the North Plaza", 3103, DRItemCategory.SCOOP),
    ("Lovers", 3104, DRItemCategory.SCOOP),
    ("The Coward", 3105, DRItemCategory.SCOOP),
    ("Twin Sisters", 3106, DRItemCategory.SCOOP),
    ("Restaurant Man", 3107, DRItemCategory.SCOOP),
    ("Hanging by a Thread", 3108, DRItemCategory.SCOOP),
    ("Antique Lover", 3109, DRItemCategory.SCOOP),
    ("The Woman Who Didn't Make it", 3110, DRItemCategory.SCOOP),
    ("Dressed for Action", 3111, DRItemCategory.SCOOP),
    ("Gun Shop Standoff", 3112, DRItemCategory.SCOOP),
    ("The Drunkard", 3113, DRItemCategory.SCOOP),
    ("A Sick Man", 3114, DRItemCategory.SCOOP),
    ("The Woman Left Behind", 3115, DRItemCategory.SCOOP),
    ("A Woman in Despair", 3116, DRItemCategory.SCOOP),

    # Psychopath Scoops
    ("Cut from the Same Cloth", 3200, DRItemCategory.SCOOP),
    ("Photo Challenge", 3201, DRItemCategory.SCOOP),
    ("Photographer's Pride", 3202, DRItemCategory.SCOOP),
    ("Cletus", 3203, DRItemCategory.SCOOP),
    ("The Convicts", 3204, DRItemCategory.SCOOP),
    ("Out of Control", 3205, DRItemCategory.SCOOP),
    ("The Hatchet Man", 3206, DRItemCategory.SCOOP),
    ("Above the Law", 3207, DRItemCategory.SCOOP),
    ("A Strange Group", 3208, DRItemCategory.SCOOP),
    ("Long Haired Punk", 3209, DRItemCategory.SCOOP),
    ("Mark of the Sniper", 3210, DRItemCategory.SCOOP),
    ("The Cult", 3211, DRItemCategory.SCOOP),

    # Player skills (21) — handled by DRAP/effects/PlayerStats.lua
    # Each maps to a bit in PSM.PlayerSkill (PL_SKILL_BITS).
    ("Jump Kick",        4000, DRItemCategory.SKILL),
    ("Zombie Ride",      4001, DRItemCategory.SKILL),
    ("Kick Back",        4002, DRItemCategory.SKILL),
    ("Power Push",       4003, DRItemCategory.SKILL),
    ("Judo Throw",       4004, DRItemCategory.SKILL),
    ("Knee Drop",        4005, DRItemCategory.SKILL),
    ("Lift Up",          4006, DRItemCategory.SKILL),
    ("Wall Kick",        4007, DRItemCategory.SKILL),
    ("Face Crusher",     4008, DRItemCategory.SKILL),
    ("Football Tackle",  4009, DRItemCategory.SKILL),
    ("Giant Swing",      4010, DRItemCategory.SKILL),
    ("Hammer Throw",     4011, DRItemCategory.SKILL),
    ("Neck Twist",       4012, DRItemCategory.SKILL),
    ("Roundhouse Kick",  4013, DRItemCategory.SKILL),
    ("Disembowel",       4014, DRItemCategory.SKILL),
    ("Somersault Kick",  4015, DRItemCategory.SKILL),
    ("Flying Dodge",     4016, DRItemCategory.SKILL),
    ("Double Lariat",    4017, DRItemCategory.SKILL),
    ("Karate Chop",      4018, DRItemCategory.SKILL),
    ("Zombie Walk",      4019, DRItemCategory.SKILL),
    ("Suplex",           4020, DRItemCategory.SKILL),

    # Progressive stat upgrades (6 categories) — quantity per category controlled
    # by Options.enable_stat_items + enable_extra_stat_buffs in BuildItemPool.
    ("Progressive Health Upgrade",    4030, DRItemCategory.UPGRADE),
    ("Progressive Attack Upgrade",    4031, DRItemCategory.UPGRADE),
    ("Progressive Throw Upgrade",     4032, DRItemCategory.UPGRADE),
    ("Progressive Item Slot Upgrade", 4033, DRItemCategory.UPGRADE),
    ("Progressive Run Level Upgrade", 4034, DRItemCategory.UPGRADE),
    ("Progressive Speed Upgrade",     4035, DRItemCategory.UPGRADE),

    # Filler buffs (handled by DRAP/effects/PlayerBuffs.lua)
    ("Fleetfoot Effect",   4050, DRItemCategory.BUFF),
    ("Untouchable Effect", 4051, DRItemCategory.BUFF),
    ("Spitfire Effect",    4052, DRItemCategory.BUFF),
    ("Energizer Effect",   4053, DRItemCategory.BUFF),
    ("Toughness Effect",   4054, DRItemCategory.BUFF),
    ("Heal",               4055, DRItemCategory.BUFF),
    ("Berserker Mode",     4056, DRItemCategory.BUFF),
    ("PP Boost",           4057, DRItemCategory.BUFF),

    # Filler traps (handled by DRAP/effects/PlayerBuffs.lua + HostileSurvivorTrap.lua)
    # All trap items end with "Trap" so they're obviously traps in the AP UI.
    ("Stomach Ache Trap",   4070, DRItemCategory.TRAP),
    ("Zombait Trap",        4071, DRItemCategory.TRAP),
    ("Slow Trap",           4072, DRItemCategory.TRAP),
    ("Damage Player Trap",  4073, DRItemCategory.TRAP),
    ("Hostile NPC Trap",    4074, DRItemCategory.TRAP),
    ("Special Forces Trap", 4075, DRItemCategory.TRAP),
    # Note: Night Mode + Hardcore Zombies are NOT items — they are YAML
    # options (`night_mode_enabled`, `hardcore_zombies_enabled` in Options.py)
    # applied at slot-connect by DRAP/effects/ZombieEffects.lua.
]]

item_descriptions = {}

item_dictionary = {item_data.name: item_data for item_data in _all_items}

# Specialty items that must be included in the pool for Restricted mode
# These are required for specific scoops/psychopaths and are progression when RestrictedItemMode is enabled
specialty_items = {
    "Book [Japanese Conversation]",
    "Bowling Ball",
    "Fire Extinguisher",
    "Golf Club",
    "Handgun",
    "Orange Juice",
    "Parasol",
    # Required for PP-bonus location gating in restricted_item_mode:
    "Frying Pan",      # gates "Heat a pan on N stoves" locations
    "Uncooked Pizza",  # gates "Use N Microwaves" (alongside Raw Meat)
    "Raw Meat",        # gates "Use N Microwaves" (alongside Uncooked Pizza)
}

# Items widely considered overpowered. Removed from the filler pool when
# Options.exclude_overpowered_items is on. Guaranteed-items overrides still
# win — listing one here AND in Guaranteed Items will keep it in the pool.
overpowered_items = {
    "Book [Infinite Durability]",  # weapons never break
    "Book [Martial Arts]",          # massively-boosted unarmed damage
    "Laser Sword",                  # high-damage, high-durability weapon
    "Real Mega Buster",             # high-damage ranged weapon
}

# Skill items that gate logic when Options.enable_skill_items is on, and
# therefore must be classified as progression (not Useful) so AP's fill
# algorithm treats them as real keys. Without this, any rule that calls
# state.has("X", player) for a skill in this set raises FillError because
# AP only considers progression items when checking accessibility.
#
# Zombie Ride: gates "Ride zombies for 50 feet" challenge.
progression_skills = {
    "Zombie Ride",
}


def BuildItemPool(multiworld, count, options, excluded_scoop_names=()):
    """Build the item pool for this world.

    excluded_scoop_names: iterable of scoop item names to omit from the pool
    even when ScoopSanity is enabled. Used by the Savior goal to drop main
    scoops (they would advance story state the goal doesn't need).
    """
    item_pool = []
    included_itemcount = 0

    # Area keys to skip when door randomizer is enabled
    area_key_names = {
        "Rooftop key", "Warehouse key", "Paradise Plaza key",
        "Colby's Movieland key", "Leisure Park key", "North Plaza key",
        "Crislip's Home Saloon key", "Food Court key", "Wonderland Plaza key",
        "Al Fresca Plaza key", "Entrance Plaza key", "Seon's Food and Stuff key",
        "Maintenance Tunnel key", "Carlito's Hideout key", "Maintenance Tunnel Access Key"
    }

    # Time keys to skip when scoop sanity is enabled
    time_key_names = {
        "DAY2_06_AM", "DAY2_11_AM", "DAY3_00_AM", "DAY3_11_AM", "DAY4_12_PM"
    }

    if options.guaranteed_items.value:
        for item_name in options.guaranteed_items.value:
            item = item_dictionary[item_name]
            item_pool.append(item)
            included_itemcount = included_itemcount + 1
    remaining_count = count - included_itemcount

    if options.restricted_item_mode.value:
        for item_name in specialty_items:
            item = item_dictionary[item_name]
            item_pool.append(item)
            remaining_count = remaining_count - 1
            included_itemcount = included_itemcount + 1

    itemList = [item for item in _all_items]
    lockList = [item for item in _all_items if item.category == DRItemCategory.LOCK]
    scoopList = [item for item in _all_items if item.category == DRItemCategory.SCOOP]
    consumableList = [item for item in _all_items if item.category == DRItemCategory.CONSUMABLE]
    weaponList = [item for item in _all_items if item.category == DRItemCategory.WEAPON]
    skillList = [item for item in _all_items if item.category == DRItemCategory.SKILL]
    upgradeList = [item for item in _all_items if item.category == DRItemCategory.UPGRADE]
    buffList = [item for item in _all_items if item.category == DRItemCategory.BUFF]

    # Trap subset of fillers — gated by options.trap_percentage on a per-roll
    # basis when filling remaining slots.
    trapList = [item for item in _all_items if item.category == DRItemCategory.TRAP]
    nonTrapFiller = [item for item in itemList if item.category in (
        DRItemCategory.MISC, DRItemCategory.WEAPON, DRItemCategory.CONSUMABLE,
        DRItemCategory.BUFF
    )]

    # Strip overpowered filler entries when the option is on. Guaranteed
    # Items (added unconditionally above) and Restricted-mode specialty
    # items (none of which overlap with overpowered_items) are unaffected.
    if getattr(options, "exclude_overpowered_items",
               type("X", (), {"value": False})()).value:
        nonTrapFiller = [it for it in nonTrapFiller if it.name not in overpowered_items]

    fillerList = nonTrapFiller + trapList

    for lock in lockList:
        # Skip area keys if door randomizer is enabled (they're precollected)
        if options.door_randomizer and lock.name in area_key_names:
            continue
        # Skip time keys if scoop sanity is enabled
        if options.scoop_sanity and lock.name in time_key_names:
            continue

        item = item_dictionary[lock.name]
        item_pool.append(item)
        remaining_count = remaining_count - 1
        included_itemcount = included_itemcount + 1

    if options.scoop_sanity:
        excluded = set(excluded_scoop_names)
        for scoop in scoopList:
            # Skip "Out of Control" if door randomizer is also enabled (it's precollected for softlock prevention)
            if options.door_randomizer and scoop.name == "Out of Control":
                continue
            # Skip scoops the caller has explicitly excluded (e.g. main scoops
            # under the Savior goal).
            if scoop.name in excluded:
                continue
            item = item_dictionary[scoop.name]
            item_pool.append(item)
            remaining_count = remaining_count - 1
            included_itemcount = included_itemcount + 1


    # Useful items: skills + stat upgrades. Quantity per stat depends on
    # whether extras are enabled. Modes:
    #   * vanilla_only    — neither skills nor stat upgrades added
    #   * replace         — full core pool (extras add more if enabled)
    #   * extra_buffs_only — only the extra/over-vanilla pool added
    progression_mode = getattr(options, "vanilla_progression",
                               type("X", (), {"value": 1})()).value
    # Match Options.py Choice: 0=vanilla_only, 1=replace, 2=extra_buffs_only
    extras_enabled = bool(getattr(options, "enable_extra_stat_buffs",
                                  type("X", (), {"value": False})()).value)

    if getattr(options, "enable_skill_items",
               type("X", (), {"value": True})()).value and progression_mode != 0:
        if progression_mode != 2:   # skills only in replace, not extra_buffs_only
            for skill in skillList:
                item_pool.append(skill)
                remaining_count -= 1
                included_itemcount += 1

    # Per-stat counts: (base_when_replace, extras_addition_if_enabled)
    UPGRADE_COUNTS = {
        "Progressive Health Upgrade":    (8, 4),
        "Progressive Attack Upgrade":    (6, 10),
        "Progressive Throw Upgrade":     (4, 8),
        "Progressive Item Slot Upgrade": (8, 3),
        "Progressive Run Level Upgrade": (2, 0),
        "Progressive Speed Upgrade":     (0, 10),    # extras-only category
    }
    if getattr(options, "enable_stat_items",
               type("X", (), {"value": True})()).value and progression_mode != 0:
        for upg in upgradeList:
            base, extra = UPGRADE_COUNTS.get(upg.name, (0, 0))
            count_to_add = 0
            if progression_mode == 1:   # replace
                count_to_add = base + (extra if extras_enabled else 0)
            elif progression_mode == 2:   # extra_buffs_only
                count_to_add = extra
            for _ in range(count_to_add):
                item_pool.append(upg)
                remaining_count -= 1
                included_itemcount += 1

    # Fill remaining filler slots. trap_percentage controls what fraction of
    # those slots become traps; the rest are random non-trap fillers.
    #
    # Earlier revisions used a per-encounter roll (walk the shuffled
    # nonTrapFiller+trapList, roll trap_pct% to keep each trap candidate).
    # That approach produced a far lower trap rate than advertised because
    # trap candidates were only ~5/155 of the shuffled list -- the
    # effective trap density was trap_pct% * 3%, so the default of 25%
    # produced under one trap per run on average. Testers reported never
    # seeing certain trap types (Hostile NPC Trap in particular).
    #
    # The two-bucket approach below makes trap_percentage mean what the
    # docstring says it means. Trap slots are filled by cycling through a
    # shuffled trapList, so every trap type appears at least once before
    # any repeats -- this guarantees Hostile NPC Trap and the others all
    # show up in the pool whenever the trap-slot count is >= len(trapList).
    trap_pct = int(getattr(options, "trap_percentage",
                            type("X", (), {"value": 25})()).value)
    remaining_count = max(0, remaining_count)
    trap_slot_count = (
        min(int(round(remaining_count * trap_pct / 100)), remaining_count)
        if trapList else 0
    )
    non_trap_slot_count = remaining_count - trap_slot_count

    # Trap slots: round-robin through a shuffled trapList so each trap type
    # gets equal representation (with a fresh shuffle on every full cycle).
    if trap_slot_count > 0 and trapList:
        trap_cycle = []
        for _ in range(trap_slot_count):
            if not trap_cycle:
                trap_cycle = list(trapList)
                multiworld.random.shuffle(trap_cycle)
            item_pool.append(trap_cycle.pop())

    # Non-trap filler slots: shuffle once, walk in order, reshuffle on
    # wrap-around. This keeps the existing "unique-first, then duplicates"
    # property of the original algorithm.
    if non_trap_slot_count > 0 and nonTrapFiller:
        shuffled_filler = list(nonTrapFiller)
        multiworld.random.shuffle(shuffled_filler)
        filler_index = 0
        for _ in range(non_trap_slot_count):
            if filler_index >= len(shuffled_filler):
                multiworld.random.shuffle(shuffled_filler)
                filler_index = 0
            item_pool.append(shuffled_filler[filler_index])
            filler_index += 1

    multiworld.random.shuffle(item_pool)
    return item_pool
