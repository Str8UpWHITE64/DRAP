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
    KILL_FILLER = 11,  # KillSanity's own filler; never in the ordinary pool


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
    # ITEM_NO_ROCKET_R. Its name was blank in drdr_shared.json, so nothing
    # could register it and it was never obtainable -- while "Kill 100
    # zombies with an RPG" has always been a location.
    ("Rocket Launcher", 205, DRItemCategory.WEAPON),
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
    ("Al Fresca Plaza Key", 1000, DRItemCategory.LOCK),
    ("Colby's Movieland Key", 1001, DRItemCategory.LOCK),
    ("Crislip's Home Saloon Key", 1002, DRItemCategory.LOCK),
    ("Entrance Plaza Key", 1003, DRItemCategory.LOCK),
    ("Food Court Key", 1004, DRItemCategory.LOCK),
    ("Seon's Food and Stuff Key", 1005, DRItemCategory.LOCK),
    ("Carlito's Hideout Key", 1006, DRItemCategory.LOCK),
    ("Leisure Park Key", 1007, DRItemCategory.LOCK),
    ("Maintenance Tunnel Key", 1008, DRItemCategory.LOCK),
    ("North Plaza Key", 1009, DRItemCategory.LOCK),
    ("Paradise Plaza Key", 1010, DRItemCategory.LOCK),
    ("Rooftop Key", 1011, DRItemCategory.LOCK),
    ("Warehouse Key", 1012, DRItemCategory.LOCK),
    ("Wonderland Plaza Key", 1013, DRItemCategory.LOCK),
    ("Meat Processing Area Key", 1038, DRItemCategory.LOCK),

    # Split keys
    ("Rooftop - Security Room Key", 1014, DRItemCategory.LOCK),
    ("Rooftop - Warehouse Key", 1015, DRItemCategory.LOCK),
    ("Paradise Plaza - Warehouse Key", 1016, DRItemCategory.LOCK),
    ("Leisure Park - Paradise Plaza Key", 1017, DRItemCategory.LOCK),
    ("Colby's Movieland - Paradise Plaza Key", 1018, DRItemCategory.LOCK),
    ("Entrance Plaza - Paradise Plaza Key", 1019, DRItemCategory.LOCK),
    ("Entrance Plaza - Security Room Key", 1020, DRItemCategory.LOCK),
    ("Al Fresca Plaza - Entrance Plaza Key", 1021, DRItemCategory.LOCK),
    ("Al Fresca Plaza - Food Court Key", 1022, DRItemCategory.LOCK),
    ("Food Court - Leisure Park Key", 1023, DRItemCategory.LOCK),
    ("Food Court - Wonderland Plaza Key", 1024, DRItemCategory.LOCK),
    ("North Plaza - Wonderland Plaza Key", 1025, DRItemCategory.LOCK),
    ("Leisure Park - North Plaza Key", 1026, DRItemCategory.LOCK),
    ("Crislip's Home Saloon - North Plaza Key", 1027, DRItemCategory.LOCK),
    ("Carlito's Hideout - North Plaza Key", 1028, DRItemCategory.LOCK),
    ("North Plaza - Seon's Food and Stuff Key", 1029, DRItemCategory.LOCK),
    ("Leisure Park - Maintenance Tunnel Key", 1030, DRItemCategory.LOCK),
    ("Maintenance Tunnel - Paradise Plaza Key", 1031, DRItemCategory.LOCK),
    ("Entrance Plaza - Maintenance Tunnel Key", 1032, DRItemCategory.LOCK),
    ("Al Fresca Plaza - Maintenance Tunnel Key", 1033, DRItemCategory.LOCK),
    ("Food Court - Maintenance Tunnel Key", 1034, DRItemCategory.LOCK),
    ("Maintenance Tunnel - Wonderland Plaza Key", 1035, DRItemCategory.LOCK),
    ("Maintenance Tunnel - Seon's Food and Stuff Key", 1036, DRItemCategory.LOCK),
    ("Paradise Plaza - Wonderland Plaza Key", 1037, DRItemCategory.LOCK),
    ("Maintenance Tunnel - Meat Processing Area Key", 1039, DRItemCategory.LOCK),

    
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
    ("Hideout", 3010, DRItemCategory.SCOOP),
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
    ("Skipped Leg Day Trap", 4072, DRItemCategory.TRAP),
    ("Damage Player Trap",  4073, DRItemCategory.TRAP),
    ("Hostile NPC Trap",    4074, DRItemCategory.TRAP),
    ("Special Forces Trap", 4075, DRItemCategory.TRAP),
    # ScoopSanity only -- it waits on "The Convicts" scoop item, which only
    # exists in that mode. BuildItemPool drops it otherwise.
    ("Convicts Respawn Trap", 4076, DRItemCategory.TRAP),

    # Inventory traps (DRAP/effects/InventoryTraps.lua). Each declines and is
    # re-banked when the inventory is empty, so none is ever wasted.
    ("Butterfingers Trap",  4077, DRItemCategory.TRAP),
    ("Last Shot Trap",      4078, DRItemCategory.TRAP),
    ("Where'd Your Inventory Go? Trap", 4079, DRItemCategory.TRAP),

    # Costume traps (DRAP/effects/CostumeTraps.lua). Not reverted -- the
    # changing rooms are the way out, same as any other outfit.
    ("Bald Trap",           4080, DRItemCategory.TRAP),
    ("Goddamnit, Donut! Trap", 4081, DRItemCategory.TRAP),
    ("Boxers Trap",         4082, DRItemCategory.TRAP),

    # Timed traps (DRAP/effects/PlayerBuffs.lua), alongside Skipped Leg Day Trap.
    ("Skipped Arm Day Trap", 4083, DRItemCategory.TRAP),
    ("Oops More Zombies Trap", 4084, DRItemCategory.TRAP),
    ("Potty Mouth Trap",    4085, DRItemCategory.TRAP),

    # special_forces_mode = item. A scoop so it shows in the scoop list with
    # hover text; unlocking it sets flag 309 and the Overtime soldiers arrive.
    # It completes on BOTH of its checks, so the checks send them home.
    # Added to the pool ONLY in that mode -- see BuildItemPool.
    ("Special Forces", 4086, DRItemCategory.SCOOP),

    # Overtime suppressant ingredients. No longer items -- the checks come
    # from the pickup flags instead, so nothing holds them. Kept here so the
    # IDs stay put for anything already reading the table.
    ("Blender", 5000, DRItemCategory.LOCK),
    ("First Aid Kit", 5001, DRItemCategory.LOCK),
    ("Coffee Filters", 5002, DRItemCategory.LOCK),
    ("Magnifying Glass", 5003, DRItemCategory.LOCK),
    ("Camp Stove", 5004, DRItemCategory.LOCK),
    ("Developing Solution", 5005, DRItemCategory.LOCK),
    ("Perfume Bottle", 5006, DRItemCategory.LOCK),
    ("Cold Spray", 5007, DRItemCategory.LOCK),
    # Isabela will not leave for the tunnel without it.
    ("Clock Tower Tunnel Key", 5008, DRItemCategory.LOCK),
    # The Humvee will not start without it.
    ("Humvee Key", 5009, DRItemCategory.LOCK),
    # Car Keys: one per drivable vehicle type. Both motorcycles share the one
    # key -- the game gives them the same RIDE_CAR_TYPE, so there is nothing to
    # tell them apart even if we wanted to.
    ("Sedan Key", 5010, DRItemCategory.LOCK),
    ("Sports Car Key", 5011, DRItemCategory.LOCK),
    ("Truck Key", 5012, DRItemCategory.LOCK),
    ("Motorcycle Key", 5013, DRItemCategory.LOCK),
    # The convicts' vehicle. Shares its RIDE_CAR_TYPE with the Overtime
    # Humvee, so the runtime tells them apart by GameObject name.
    ("Convict Humvee Key", 5014, DRItemCategory.LOCK),

    # KillSanity filler. One per kill location, most of them placed straight
    # back onto kill locations so the multiworld pool is not flooded. They do
    # nothing in the game beyond existing.
    ("Zombie Guts", 5020, DRItemCategory.KILL_FILLER),
    ("Brains", 5021, DRItemCategory.KILL_FILLER),
    ("Rotten Flesh", 5022, DRItemCategory.KILL_FILLER),
    # Note: Night Mode + Hardcore Zombies are NOT items — they are YAML
    # options (`night_mode_enabled`, `hardcore_zombies_enabled` in Options.py)
    # applied at slot-connect by DRAP/effects/ZombieEffects.lua.
]]

item_descriptions = {}

item_dictionary = {item_data.name: item_data for item_data in _all_items}

kill_filler_items = [item.name for item in _all_items
                     if item.category == DRItemCategory.KILL_FILLER]

# Specialty items that must be included in the pool for Restricted mode
# These are required for specific scoops/psychopaths and are progression when RestrictedItemMode is enabled
specialty_items = {
    "Book [Japanese Conversation]",
    "Bowling Ball",
    "Fire Extinguisher",
    "Golf Club",
    "Orange Juice",
    "Parasol",
    # Required for the bullet checks in restricted_item_mode:
    "Handgun",
    "Shotgun",
    "Sniper Rifle",
    "Submachine Gun",
    # "Kill 100 zombies with an RPG" in restricted_item_mode: either the RPG
    # itself in Overtime, or the two halves the blender turns into one.
    "Rocket Launcher",
    "Mega Buster",
    # Required for Kent Day 2 and Costume Party in restricted_item_mode.
    # The Ghoul mask is the Entrance Plaza one; the other three are in
    # Paradise Plaza.
    "Novelty Mask (Bear)",
    "Novelty Mask (Horse)",
    "Novelty Mask (Servbot)",
    "Novelty Mask (Ghoul)",
    # Required for PP-bonus location gating in restricted_item_mode:
    "Frying Pan",      # gates "Heat a pan on N stoves" locations
    "Uncooked Pizza",  # gates "Use N Microwaves" (alongside Raw Meat)
    "Raw Meat",        # gates "Use N Microwaves" (alongside Uncooked Pizza)
    # Required for Honey Hunt in restricted_item_mode:
    "Queen",
    # Something to kill 500+ zombies in an area with, for the Zombie Kill
    # Tiers checks. Only restricted mode needs them in the pool -- everywhere
    # else these are lying on the floor, so those checks lean on how much of
    # the mall is open instead. Handgun/Shotgun/Submachine Gun are above.
    "Katana",
    "Hunting Knife",
    "Sledgehammer",
    "Machete",
    "Baseball Bat",
    "Fire Ax",
    "Small Chainsaw",
}

# DRItemCategory.WEAPON means "anything Frank can hold", not "weapon" -- the
# frying pan, Kent's masks and Paul's fire extinguisher all sit in it. Spitter
# Only drops the category, so anything in it that a check still needs has to be
# named here. Everything else those items gated is dropped as a location
# instead (SPITTER_EXCLUDED_LOCATIONS); the queen is the one kept, because
# handing Isabela a bee is not swinging anything.
spitter_kept_weapons = {
    "Queen",
}

# Scoops with nothing left to open once Spitter Only drops their checks.
spitter_dropped_scoops = {
    "Photo Challenge",      # arms Kent's day 2, which needs a novelty mask
}

# Upgrades with nothing to improve once the weapons are gone. Melee is meant
# to be barely worth swinging in this mode, and there is nothing left to
# throw, so both would be dead slots in the pool.
spitter_dropped_upgrades = {
    "Progressive Attack Upgrade",
    "Progressive Throw Upgrade",
}

# Food items that stand in for Seon's Food and Stuff access in the
# microwave rules. Progression whenever PP-bonus locations exist, in any
# item mode -- state.has() only sees progression items.
microwave_food_items = {
    "Uncooked Pizza",
    "Raw Meat",
}

# Tools that can replace their spawn zones in the challenge rules when
# received outside restricted mode (golf, bowling, parasol, gun checks).
# Progression for the same reason as microwave_food_items.
challenge_tool_items = {
    "Golf Club",
    "Bowling Ball",
    "Parasol",
    "Handgun",
    "Heavy Machinegun",
    "Machinegun",
    "Submachine Gun",
    "Shotgun",
    "Sniper Rifle",
}

# Items widely considered overpowered. Removed from the filler pool when
# Options.exclude_overpowered_items is on. Guaranteed-items overrides still
# win — listing one here AND in Guaranteed Items will keep it in the pool.
overpowered_items = {
    "Book [Infinite Durability]",  # weapons never break
    "Book [Martial Arts]",          # massively-boosted unarmed damage
    "Laser Sword",                  # high-damage, high-durability weapon
    "Real Mega Buster",             # high-damage ranged weapon
    "Rocket Launcher",              # one-shots almost anything
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


def BuildItemPool(multiworld, count, options, excluded_scoop_names=(),
                  door_locks_active=False):
    """Build the item pool for this world.

    excluded_scoop_names: iterable of scoop item names to omit from the pool
    even when ScoopSanity is enabled. Used by the Savior goal to drop main
    scoops (they would advance story state the goal doesn't need).

    door_locks_active: keep the area keys in the pool under door
    randomization instead of dropping them as precollected.
    """
    item_pool = []
    included_itemcount = 0

    # Area keys to skip when door randomizer is enabled
    area_key_names = {
        "Rooftop Key", "Warehouse Key", "Paradise Plaza Key",
        "Colby's Movieland Key", "Leisure Park Key", "North Plaza Key",
        "Crislip's Home Saloon Key", "Food Court Key", "Wonderland Plaza Key",
        "Al Fresca Plaza Key", "Entrance Plaza Key", "Seon's Food and Stuff Key",
        "Maintenance Tunnel Key", "Carlito's Hideout Key", "Maintenance Tunnel Access Key",
        "Meat Processing Area Key"
    }

    # Keys in Split Keys mode, skipped otherwise
    split_key_names = {
        "Rooftop - Warehouse Key", "Rooftop - Security Room Key", "Paradise Plaza - Warehouse Key",
        "Leisure Park - Paradise Plaza Key", "Colby's Movieland - Paradise Plaza Key", "Entrance Plaza - Paradise Plaza Key",
        "Entrance Plaza - Security Room Key", "Al Fresca Plaza - Entrance Plaza Key", "Al Fresca Plaza - Food Court Key",
        "Food Court - Leisure Park Key", "Food Court - Wonderland Plaza Key",
        "North Plaza - Wonderland Plaza Key", "Leisure Park - North Plaza Key", "Crislip's Home Saloon - North Plaza Key",
        "Carlito's Hideout - North Plaza Key", "North Plaza - Seon's Food and Stuff Key", "Leisure Park - Maintenance Tunnel Key",
        "Maintenance Tunnel - Paradise Plaza Key", "Entrance Plaza - Maintenance Tunnel Key", "Food Court - Maintenance Tunnel Key",
        "Al Fresca Plaza - Maintenance Tunnel Key", "Maintenance Tunnel - Wonderland Plaza Key", "Maintenance Tunnel - Seon's Food and Stuff Key",
        "Maintenance Tunnel - Meat Processing Area Key",
        "Paradise Plaza - Wonderland Plaza Key"
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

    spitter_only = bool(getattr(options, "spitter_only",
                                type("X", (), {"value": False})()).value)

    if options.restricted_item_mode.value:
        for item_name in specialty_items:
            # Spitter Only forces Restricted on, and most of the specialty
            # list is there to satisfy checks it has just dropped.
            if spitter_only and item_name not in spitter_kept_weapons and                     item_dictionary[item_name].category == DRItemCategory.WEAPON:
                continue
            item = item_dictionary[item_name]
            item_pool.append(item)
            remaining_count = remaining_count - 1
            included_itemcount = included_itemcount + 1
    elif options.scoop_sanity.value:
        # Queen spawning across the mall waits for this item under ScoopSanity,
        # so one has to exist even when Restricted mode is off -- otherwise the
        # five Isabela hand-ins have nothing to collect. Restricted mode already
        # supplies it through specialty_items.
        item = item_dictionary["Queen"]
        item_pool.append(item)
        remaining_count = remaining_count - 1
        included_itemcount = included_itemcount + 1

    # Book [Blender] is the one thing both RPG routes need, and on any goal
    # without Overtime it is the only route -- so one has to exist in every
    # mode, the same reasoning as the Queen above.
    if "Book [Blender]" not in (options.guaranteed_items.value or {}):
        item = item_dictionary["Book [Blender]"]
        item_pool.append(item)
        remaining_count = remaining_count - 1
        included_itemcount = included_itemcount + 1

    itemList = [item for item in _all_items]
    lockList = [item for item in _all_items if item.category == DRItemCategory.LOCK]
    scoopList = [item for item in _all_items if item.category == DRItemCategory.SCOOP]
    # "Special Forces" is a scoop only in special_forces_mode = item. In none
    # and permanent it must not reach the pool at all -- in permanent the mode
    # turns the soldiers on directly, so an item that also turns them on would
    # be a no-op the player still has to find.
    if int(getattr(options.special_forces_mode, "value", 0)) != 1:
        scoopList = [item for item in scoopList if item.name != "Special Forces"]
    consumableList = [item for item in _all_items if item.category == DRItemCategory.CONSUMABLE]
    skillList = [item for item in _all_items if item.category == DRItemCategory.SKILL]
    upgradeList = [item for item in _all_items if item.category == DRItemCategory.UPGRADE]
    buffList = [item for item in _all_items if item.category == DRItemCategory.BUFF]

    # Trap subset of fillers — gated by options.trap_percentage on a per-roll
    # basis when filling remaining slots.
    trapList = [item for item in _all_items if item.category == DRItemCategory.TRAP]
    # The convicts only fail to come back when the clock is frozen, and the
    # trap keys off a scoop item that does not exist outside ScoopSanity.
    if not options.scoop_sanity:
        trapList = [item for item in trapList
                    if item.name != "Convicts Respawn Trap"]
    # Player's own list. An empty set means no traps at all, which is the same
    # as a trap percentage of zero -- honoured rather than treated as "unset",
    # because emptying the list is a deliberate thing to do.
    _enabled_traps = getattr(options, "enabled_traps", None)
    if _enabled_traps is not None:
        _keep = set(_enabled_traps.value)
        trapList = [item for item in trapList if item.name in _keep]
    nonTrapFiller = [item for item in itemList if item.category in (
        DRItemCategory.MISC, DRItemCategory.WEAPON, DRItemCategory.CONSUMABLE,
        DRItemCategory.BUFF
    )]

    # Spitter Only: nothing to swing. Food and magazines are CONSUMABLE and
    # survive, which leaves the filler shorter -- the fill loop reshuffles on
    # wrap-around, so it just repeats sooner.
    if spitter_only:
        nonTrapFiller = [it for it in nonTrapFiller
                         if it.category != DRItemCategory.WEAPON
                         or it.name in spitter_kept_weapons]

    # Strip overpowered filler entries when the option is on. Guaranteed
    # Items (added unconditionally above) and Restricted-mode specialty items
    # are unaffected -- this only filters the filler list.
    #
    # Rocket Launcher is overpowered AND a Restricted specialty: excluding it
    # drops the filler copies while the guaranteed one survives, so the RPG
    # check stays reachable.
    if getattr(options, "exclude_overpowered_items",
               type("X", (), {"value": False})()).value:
        nonTrapFiller = [it for it in nonTrapFiller if it.name not in overpowered_items]

    fillerList = nonTrapFiller + trapList

    # Everything Overtime Progression Gating puts behind the multiworld. Their
    # locations are Ending-S only, so the items have to be too, or the pool
    # outgrows the locations -- and with the gating off nothing enforces them,
    # so they would be items with nothing to open.
    overtime_gating_on = bool(getattr(options, "overtime_progression_gating",
                                      type("X", (), {"value": False})()).value)
    # Dropped as items entirely: their checks read the pickup flags now.
    suppressant_names = {
        "Blender", "First Aid Kit", "Coffee Filters", "Magnifying Glass",
        "Camp Stove", "Developing Solution", "Perfume Bottle", "Cold Spray",
    }
    overtime_item_names = {
        "Clock Tower Tunnel Key",
        "Humvee Key",
    }
    # Only exist when Car Keys is on; without it nothing locks the vehicles,
    # so they would be items with nothing to open.
    car_key_names = {
        "Sedan Key", "Sports Car Key", "Truck Key", "Motorcycle Key",
        "Convict Humvee Key",
    }
    car_keys_on = bool(getattr(options, "car_keys",
                               type("X", (), {"value": False})()).value)

    for lock in lockList:
        if lock.name in suppressant_names:
            continue
        if lock.name in overtime_item_names                 and (options.goal.value != 0 or not overtime_gating_on):
            continue
        if lock.name in car_key_names and not car_keys_on:
            continue
        # Area keys are precollected under door randomization, and replaced by
        # the per-door keys under Split Keys
        if (options.door_randomizer or options.split_keys) and lock.name in area_key_names:
            # Door Locks is the exception -- the area keys are what the locks
            # check, so they have to come from the pool. The Access Key opens
            # the tunnel doors rather than an area and stays precollected.
            if not door_locks_active or lock.name == "Maintenance Tunnel Access Key":
                continue
        # Skip time keys if scoop sanity is enabled
        if options.scoop_sanity and lock.name in time_key_names:
            continue
        # Split keys exist only in their own mode, and door randomization
        # precollects them
        if lock.name in split_key_names and (not options.split_keys or options.door_randomizer):
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
            if spitter_only and scoop.name in spitter_dropped_scoops:
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
            if spitter_only and upg.name in spitter_dropped_upgrades:
                continue
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
