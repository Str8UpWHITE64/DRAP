"""Access rules for Dead Rising Deluxe Remaster.

Split out of __init__.py, which had grown to the point where the rules were
most of the file. This holds set_rules and the tables only the rules consult;
__init__ imports back the handful its other methods still read.
"""
import dataclasses
import re
from typing import Any, List

from BaseClasses import LocationProgressType

from rule_builder.rules import (
    And, AtLeast, CanReachLocation, CanReachRegion, Has, HasAll, Or, Rule, True_,
)

from .Locations import DRLocationCategory, location_tables
from .shared_data import (
    SCOOP_COMPLETION_MAP, SCOOP_EVENTS,
    AP_TRIGGER_LOCATIONS, expand_trigger_location_names,
    trigger_location_required_regions,
)

# Region(s) the player must physically reach to complete each scoop.
# Scoops in the Security Room (always reachable) are omitted.
SCOOP_REGION_REQUIREMENTS = {
    "Backup for Brad": ["Food Court", "Entrance Plaza"],
    "Rescue the Professor": ["Entrance Plaza", "Paradise Plaza"],
    "Medicine Run": ["Seon's Food and Stuff"],
    "Girl Hunting": ["North Plaza"],
    "A Promise to Isabela": ["North Plaza", "Rooftop"],
    "The Last Resort": ["Maintenance Tunnel", "Leisure Park"],
    "Hideout": ["Paradise Plaza", "Leisure Park", "North Plaza", "Carlito's Hideout"],
    "The Butcher": ["Maintenance Tunnel"],
}

# Split Keys only. These escorts walk a fixed route, so those doors must be
# open -- reaching the regions another way is not enough. The ScoopSanity
# loop rebuilds scoop rules from scratch and would otherwise drop them.
SPLIT_KEY_SCOOP_DOORS = {
    "Rescue the Professor": ["Entrance Plaza - Paradise Plaza Key"],
    "Hideout": ["Paradise Plaza - Warehouse Key", "Leisure Park - Paradise Plaza Key",
                "Leisure Park - North Plaza Key", "Carlito's Hideout - North Plaza Key"],
}

# Level requirements for each main scoop position (0-indexed) in the shuffled order.
# Scoops at higher positions require higher levels, spreading them across spheres.
# Uses the same level thresholds as LEVEL_SPHERE_GATES.
SCOOP_POSITION_LEVEL_GATES = [
    None,  # Position 0: no level gate (accessible ASAP)
    None,  # Position 1: no level gate
    7,     # Position 2: Rooftop sphere
    10,    # Position 3: Paradise Plaza sphere
    12,    # Position 4: Leisure Park sphere
    15,    # Position 5: Food Court sphere
    16,    # Position 6: Al Fresca Plaza sphere
    17,    # Position 7: Wonderland Plaza sphere
    18,    # Position 8: North Plaza sphere
    20,    # Position 9: Entrance Plaza sphere
    20,    # Position 10: Entrance Plaza sphere
    22,    # Position 11: Maintenance Tunnel sphere
    22,    # Position 12: Maintenance Tunnel sphere
]

# Survivor scoop item names (ScoopSanity: player must receive these to spawn NPCs)
SURVIVOR_SCOOP_NAMES = [
    "Barricade Pair", "A Mother's Lament", "Japanese Tourists",
    "Shadow of the North Plaza", "Lovers", "The Coward",
    "Twin Sisters", "Restaurant Man", "Hanging by a Thread",
    "Antique Lover", "The Woman Who Didn't Make it", "Dressed for Action",
    "Gun Shop Standoff", "The Drunkard", "A Sick Man",
    "The Woman Left Behind", "A Woman in Despair",
]

# Psychopath scoop item names (ScoopSanity: player must receive these to spawn bosses)
PSYCHOPATH_SCOOP_NAMES = [
    "Cut from the Same Cloth", "Photo Challenge", "Photographer's Pride",
    "Cletus", "The Convicts", "Out of Control",
    "The Hatchet Man", "Above the Law", "A Strange Group",
    "Long Haired Punk", "Mark of the Sniper", "The Cult",
]

# Survivor counts per scoop: (total_survivors, female_survivors)
# Used by ScoopSanity logic for "Escort 8 survivors at once" and "Frank the pimp"
# Excludes Kent chain (Tad requires 3 scoops) and free survivors (Bill, Jeff, Natalie)
SCOOP_SURVIVOR_COUNTS = {
    # Survivor scoops
    "Barricade Pair": (2, 0),               # Aaron Swoop (M), Burt Thompson (M)
    "A Mother's Lament": (1, 1),            # Leah Stein (F)
    "Japanese Tourists": (2, 0),            # Yuu Tanaka (M), Shinji Kitano (M)
    "Shadow of the North Plaza": (1, 0),    # David Bailey (M)
    "Lovers": (2, 1),                       # Tonya Waters (F), Ross Folk (M)
    "The Coward": (1, 0),                   # Gordon Stalworth (M)
    "Twin Sisters": (2, 2),                 # Heather Tompkins (F), Pamela Tompkins (F)
    "Restaurant Man": (1, 0),               # Ronald Shiner (M)
    "Hanging by a Thread": (2, 1),          # Sally Mills (F), Nick Evans (M)
    "Antique Lover": (1, 0),                # Floyd Sanders (M)
    "The Woman Who Didn't Make it": (2, 2), # Jolie Wu (F), Rachel Decker (F)
    "Dressed for Action": (1, 0),           # Kindell Johnson (M)
    "Gun Shop Standoff": (3, 1),            # Brett Styles (M), Jonathan Picardson (M), Alyssa Laurent (F)
    "The Drunkard": (1, 0),                 # Gil Jiminez (M)
    "A Sick Man": (1, 0),                   # Leroy McKenna (M)
    "The Woman Left Behind": (1, 1),        # Susan Walsh (F)
    "A Woman in Despair": (1, 1),           # Simone Ravendark (F)
    # Psychopath scoops that unlock survivors
    "Above the Law": (4, 4),                # Kay Nelson (F), Lilly Deacon (F), Kelly Carpenter (F), Janet Star (F)
    "The Hatchet Man": (3, 1),              # Josh Manning (M), Barbara Patterson (F), Rich Atkins (M)
    "Long Haired Punk": (3, 2),             # Mindy Baker (F), Debbie Willet (F), Paul Carson (M)
    "A Strange Group": (5, 3),              # Beth Shrake (F), Michelle Feltz (F), Nathan Crabbe (M), Ray Mathison (M), Cheryl Jones (F)
    "The Cult": (1, 1),                     # Jennifer Gorman (F)
    "Mark of the Sniper": (1, 0),           # Wayne Blackwell (M)
    "Out of Control": (1, 0),               # Greg Simpson (M)
    "The Convicts": (1, 1),                 # Sophie Richard (F)
}

# Determines the value of the region towards levels
REGION_LEVEL_VALUES = {
    "Security Room": 1,
    "Rooftop": 1,
    "Paradise Plaza": 3,
    "Entrance Plaza": 2,
    "Leisure Park": 3,
    "Al Fresca Plaza": 2,
    "Food Court": 2,
    "Wonderland Plaza": 3,
    "North Plaza": 2,
    "Maintenance Tunnel": 4,
    "Seon's Food and Stuff": 1,
    "Crislip's Home Saloon": 1,
    "Colby's Movieland": 1,
}

def get_reachable_region_points(state, player: int) -> int:
    return sum(value for region, value in REGION_LEVEL_VALUES.items()
               if state.can_reach_region(region, player))

@dataclasses.dataclass()
class RegionPointsAtLeast(Rule["DRWorld"], game="Dead Rising Deluxe Remaster"):
    """Level gates: every region the player can reach is worth points.

    A count over the whole state, so none of the builder's primitives fit.
    Holds only the threshold and the player id -- never the world, which
    would keep the MultiWorld alive past generation.
    """

    count: int

    def _instantiate(self, world) -> Rule.Resolved:
        return self.Resolved(self.count, player=world.player)

    class Resolved(Rule.Resolved):
        count: int

        def _evaluate(self, state) -> bool:
            return get_reachable_region_points(state, self.player) >= self.count

        def explain_json(self, state=None):
            have = get_reachable_region_points(state, self.player) if state else None
            return [
                {"type": "text", "text": "Region points "},
                {"type": "color",
                 "color": "green" if have is not None and have >= self.count else "salmon",
                 "text": "?" if have is None else str(have)},
                {"type": "text", "text": f" of {self.count}"},
            ]

# PP Sticker groups: (count, required_regions, required_locations)
# Used by milestone rules to dynamically count how many stickers the player can reach
PP_STICKER_GROUPS = [
    (1, ["Security Room"], []),                                                   # Sticker 97
    (14, ["Paradise Plaza"], []),                                                 # Stickers 1-14
    (1, ["Rooftop"], []),                                                         # Sticker 100
    (10, ["Colby's Movieland"], []),                                              # Stickers 15-24
    (4, ["Leisure Park"], []),                                                    # Stickers 86-89
    (11, ["Food Court"], []),                                                     # Stickers 46-56
    (11, ["Al Fresca Plaza"], []),                                                # Stickers 35-45
    (15, ["Wonderland Plaza"], []),                                               # Stickers 57-71
    (9, ["North Plaza"], []),                                                     # Stickers 72-73, 76-82
    (3, ["Seon's Food and Stuff"], []),                                           # Stickers 83-85
    (2, ["Crislip's Home Saloon"], []),                                           # Stickers 74-75
    (10, ["Entrance Plaza"], ["Escort Brad to see Dr Barnaby"]),                  # Stickers 25-34
    (7, ["Maintenance Tunnel"], []),                                              # Stickers 90-96
    (2, ["Paradise Plaza", "Leisure Park"], ["Get grabbed by the raincoats"]),    # Stickers 98-99
]

# Zones with a direct door into the Maintenance Tunnel. The Leisure Park
# ramp is separate -- it is the only tunnel entrance that never needs the
# Access Key (the physical copy is picked up inside the tunnels).
MAINTENANCE_TUNNEL_ZONES = [
    "Paradise Plaza", "Entrance Plaza", "Al Fresca Plaza",
    "Food Court", "Wonderland Plaza", "Seon's Food and Stuff",
]


def set_rules(world) -> None:


    # --------------------------------------------------------------------
    # Shared gates
    # --------------------------------------------------------------------
    # Helper: "Ending A reachable" gate used by a handful of challenge and
    # survivor rules as a proxy for late-game progression. When main scoops
    # are disabled (Savior+ScoopSanity), the Ending A location doesn't
    # exist, so calling state.can_reach_location on it would fail at rule
    # evaluation. In that mode we drop the gate — region requirements are
    # enough for Savior's purposes.
    if not world.main_scoops_enabled:
        ending_a_rule = True_()
    else:
        ending_a_rule = CanReachLocation(
            "Ending A: Solve all of the cases and be on the helipad at 12pm")
    # Default per-location rule: requires reaching the location's region.
    # Sphere-0 regions get True_() so fill can place progression items
    # there from the first sweep. More specific rules below tighten
    # access where needed (set_rule replaces — later calls win).
    SPHERE_0_REGIONS = {"Menu", "Heliport", "Security Room", "Level Ups", "Challenges"}

    # EP shutter gate. Entrance Plaza's storefronts stay closed until the
    # shutter cutscene plays, so anything inside them is unreachable even
    # once EP itself is. Defined here because both the PP-bonus rules below
    # and the sticker/survivor rules further down need it.
    # Vanilla: the shutters open during the Brad escort.
    # ScoopSanity: the EP trigger spot opens them once the player has
    # met Jessie (Warehouse reach) -- except when Backup for Brad is
    # first in the chain, where the runtime holds the trigger until the
    # Brad escort completes (the mission fires the cutscene itself).
    # Generation now keeps Backup out of the first slot, so that branch
    # is a safeguard for hand-edited orders.
    if (not world.options.scoop_sanity
            or (world.scoop_order and world.scoop_order[0] == "Backup for Brad")):
        _shutter = CanReachLocation("Escort Brad to see Dr Barnaby")
    else:
        _shutter = CanReachRegion("Warehouse")
    ep_shutter = And(CanReachRegion("Entrance Plaza"), _shutter)


    # --------------------------------------------------------------------
    # Default access: every location needs its region
    # --------------------------------------------------------------------
    for region in world.multiworld.get_regions(world.player):
        if region.name in SPHERE_0_REGIONS:
            for location in region.locations:
                world.set_rule(location, True_())
        else:
            for location in region.locations:
                world.set_rule(location, CanReachRegion(region.name))


    # --------------------------------------------------------------------
    # Region access: doors and entrances
    # --------------------------------------------------------------------
    if not world.options.door_randomizer:
        # Normal key-based entrance rules. Split Keys gives each door its
        # own key as an alternative to the area key; the two systems use
        # different items, so a seed can hand out either.
        def _door(area_key, split_key):
            if world.options.split_keys:
                return Or(Has(area_key), Has(split_key))
            return Has(area_key)

        world.set_rule(world.multiworld.get_entrance("Security Room -> Rooftop", world.player),
                      _door("Rooftop Key", "Rooftop - Security Room Key"))
        world.set_rule(world.multiworld.get_entrance("Rooftop -> Warehouse", world.player),
                      _door("Warehouse Key", "Rooftop - Warehouse Key"))
        world.set_rule(world.multiworld.get_entrance("Warehouse -> Paradise Plaza", world.player),
                      _door("Paradise Plaza Key", "Paradise Plaza - Warehouse Key"))
        world.set_rule(world.multiworld.get_entrance("Paradise Plaza -> Colby's Movieland", world.player),
                      _door("Colby's Movieland Key", "Colby's Movieland - Paradise Plaza Key"))
        world.set_rule(world.multiworld.get_entrance("Paradise Plaza -> Leisure Park", world.player),
                      _door("Leisure Park Key", "Leisure Park - Paradise Plaza Key"))
        world.set_rule(world.multiworld.get_entrance("Leisure Park -> Food Court", world.player),
                      _door("Food Court Key", "Food Court - Leisure Park Key"))
        world.set_rule(world.multiworld.get_entrance("Leisure Park -> North Plaza", world.player),
                      _door("North Plaza Key", "Leisure Park - North Plaza Key"))
        world.set_rule(world.multiworld.get_entrance("Leisure Park -> Maintenance Tunnel", world.player),
                      _door("Maintenance Tunnel Key", "Leisure Park - Maintenance Tunnel Key"))
        world.set_rule(world.multiworld.get_entrance("Leisure Park -> Paradise Plaza", world.player),
                      _door("Paradise Plaza Key", "Leisure Park - Paradise Plaza Key"))
        world.set_rule(world.multiworld.get_entrance("Food Court -> Al Fresca Plaza", world.player),
                      _door("Al Fresca Plaza Key", "Al Fresca Plaza - Food Court Key"))
        world.set_rule(world.multiworld.get_entrance("Food Court -> Wonderland Plaza", world.player),
                      _door("Wonderland Plaza Key", "Food Court - Wonderland Plaza Key"))
        world.set_rule(world.multiworld.get_entrance("Food Court -> Leisure Park", world.player),
                      _door("Leisure Park Key", "Food Court - Leisure Park Key"))
        world.set_rule(world.multiworld.get_entrance("Al Fresca Plaza -> Entrance Plaza", world.player),
                      _door("Entrance Plaza Key", "Al Fresca Plaza - Entrance Plaza Key"))
        world.set_rule(world.multiworld.get_entrance("Al Fresca Plaza -> Food Court", world.player),
                      _door("Food Court Key", "Al Fresca Plaza - Food Court Key"))
        world.set_rule(world.multiworld.get_entrance("Entrance Plaza -> Al Fresca Plaza", world.player),
                      _door("Al Fresca Plaza Key", "Al Fresca Plaza - Entrance Plaza Key"))
        world.set_rule(world.multiworld.get_entrance("Entrance Plaza -> Paradise Plaza", world.player),
                      _door("Paradise Plaza Key", "Entrance Plaza - Paradise Plaza Key"))
        world.set_rule(world.multiworld.get_entrance("Wonderland Plaza -> North Plaza", world.player),
                      _door("North Plaza Key", "North Plaza - Wonderland Plaza Key"))
        world.set_rule(world.multiworld.get_entrance("Wonderland Plaza -> Food Court", world.player),
                      _door("Food Court Key", "Food Court - Wonderland Plaza Key"))
        world.set_rule(world.multiworld.get_entrance("Seon's Food and Stuff -> North Plaza", world.player),
                      _door("North Plaza Key", "North Plaza - Seon's Food and Stuff Key"))
        world.set_rule(world.multiworld.get_entrance("North Plaza -> Leisure Park", world.player),
                      _door("Leisure Park Key", "Leisure Park - North Plaza Key"))
        world.set_rule(world.multiworld.get_entrance("North Plaza -> Wonderland Plaza", world.player),
                      _door("Wonderland Plaza Key", "North Plaza - Wonderland Plaza Key"))
        world.set_rule(world.multiworld.get_entrance("North Plaza -> Seon's Food and Stuff", world.player),
                      _door("Seon's Food and Stuff Key", "North Plaza - Seon's Food and Stuff Key"))
        world.set_rule(world.multiworld.get_entrance("North Plaza -> Carlito's Hideout", world.player),
                      _door("Carlito's Hideout Key", "Carlito's Hideout - North Plaza Key"))
        world.set_rule(world.multiworld.get_entrance("North Plaza -> Crislip's Home Saloon", world.player),
                      _door("Crislip's Home Saloon Key", "Crislip's Home Saloon - North Plaza Key"))

        # Split Keys gives the passage a key of its own on top of the scoop.
        _greg = CanReachLocation("Kill Adam")
        if world.options.split_keys:
            _greg = And(_greg, Has("Paradise Plaza - Wonderland Plaza Key"))
        world.set_rule(world.multiworld.get_entrance("Paradise Plaza -> Wonderland Plaza", world.player), _greg)
        world.set_rule(world.multiworld.get_entrance("Wonderland Plaza -> Paradise Plaza", world.player), _greg)
        world.set_rule(world.multiworld.get_entrance("Maintenance Tunnel -> Leisure Park", world.player),
                      _door("Leisure Park Key", "Leisure Park - Maintenance Tunnel Key"))

        # Maintenance Tunnel doors: every mall<->tunnel door needs the
        # Maintenance Tunnel Key plus the Access Key -- either the AP
        # item or the physical copy inside the tunnels, which is
        # reachable through the keyless Leisure Park ramp. Mall-side
        # exits also need the destination zone's key. The tunnel-to-EP
        # exit only exists in ScoopSanity (see create_connection).
        _mt_region = world.multiworld.get_region("Maintenance Tunnel", world.player)
        _tunnel_door = And(Has("Maintenance Tunnel Key"),
                           Or(Has("Maintenance Tunnel Access Key"),
                              CanReachRegion("Maintenance Tunnel")))
        for _zone in MAINTENANCE_TUNNEL_ZONES:
            _into = world.multiworld.get_entrance(f"{_zone} -> Maintenance Tunnel", world.player)
            world.set_rule(_into, _tunnel_door)
            world.multiworld.register_indirect_condition(_mt_region, _into)
            if _zone != "Entrance Plaza" or world.options.scoop_sanity:
                world.set_rule(world.multiworld.get_entrance(f"Maintenance Tunnel -> {_zone}", world.player),
                              And(Has("Maintenance Tunnel Key"), Has(f"{_zone} Key")))
        world.set_rule(world.multiworld.get_entrance("Maintenance Tunnel -> Leisure Park", world.player), And(Has("Maintenance Tunnel Key"), Has("Leisure Park Key")))

        if world.options.split_keys:
            world.set_rule(world.multiworld.get_entrance("Maintenance Tunnel -> Paradise Plaza", world.player), Has("Maintenance Tunnel - Paradise Plaza Key"))
            world.set_rule(world.multiworld.get_entrance("Maintenance Tunnel -> Al Fresca Plaza", world.player), Has("Al Fresca Plaza - Maintenance Tunnel Key"))
            world.set_rule(world.multiworld.get_entrance("Maintenance Tunnel -> Food Court", world.player), Has("Food Court - Maintenance Tunnel Key"))
            world.set_rule(world.multiworld.get_entrance("Maintenance Tunnel -> Wonderland Plaza", world.player), Has("Maintenance Tunnel - Wonderland Plaza Key"))
            world.set_rule(world.multiworld.get_entrance("Maintenance Tunnel -> Seon's Food and Stuff", world.player), Has("Maintenance Tunnel - Seon's Food and Stuff Key"))
            world.set_rule(world.multiworld.get_entrance("Paradise Plaza -> Maintenance Tunnel", world.player), Has("Maintenance Tunnel - Paradise Plaza Key"))
            world.set_rule(world.multiworld.get_entrance("Entrance Plaza -> Maintenance Tunnel", world.player), Has("Entrance Plaza - Maintenance Tunnel Key"))
            world.set_rule(world.multiworld.get_entrance("Al Fresca Plaza -> Maintenance Tunnel", world.player), Has("Al Fresca Plaza - Maintenance Tunnel Key"))
            world.set_rule(world.multiworld.get_entrance("Food Court -> Maintenance Tunnel", world.player), Has("Food Court - Maintenance Tunnel Key"))
            world.set_rule(world.multiworld.get_entrance("Wonderland Plaza -> Maintenance Tunnel", world.player), Has("Maintenance Tunnel - Wonderland Plaza Key"))
            world.set_rule(world.multiworld.get_entrance("Seon's Food and Stuff -> Maintenance Tunnel", world.player), Has("Maintenance Tunnel - Seon's Food and Stuff Key"))
        
        # ScoopSanity-only entrance rules:
        #   * Security Room -> Entrance Plaza requires Rooftop Key +
        #     Warehouse Key (the player must have been able to reach
        #     Jessie in the Warehouse for the cutscene to fire) plus
        #     Entrance Plaza Key (the door itself).
        #   * Paradise Plaza -> Entrance Plaza is open from the start
        #     (key only). Not modeled in vanilla: EP access always goes
        #     through Al Fresca first, and the shutter opens during the
        #     Rescue the Professor escort, which chains behind EP reach.
        if world.options.scoop_sanity:
            if world.options.split_keys:
                world.set_rule(world.multiworld.get_entrance("Security Room -> Entrance Plaza", world.player),
                              And(Has("Rooftop - Security Room Key"), Has("Rooftop - Warehouse Key"),
                                  Has("Entrance Plaza - Security Room Key")))
                world.set_rule(world.multiworld.get_entrance("Paradise Plaza -> Entrance Plaza", world.player),
                              Has("Entrance Plaza - Paradise Plaza Key"))
                world.set_rule(world.multiworld.get_entrance("Maintenance Tunnel -> Entrance Plaza", world.player),
                              Has("Entrance Plaza - Maintenance Tunnel Key"))
            else:
                world.set_rule(world.multiworld.get_entrance("Security Room -> Entrance Plaza", world.player),
                              And(Has("Rooftop Key"), Has("Warehouse Key"), Has("Entrance Plaza Key")))
                world.set_rule(world.multiworld.get_entrance("Paradise Plaza -> Entrance Plaza", world.player),
                              Has("Entrance Plaza Key"))


    # --------------------------------------------------------------------
    # Level-up checks
    # --------------------------------------------------------------------
    # Region-Based Levels
    for level in range(2, 7):      # Levels 2-6
        world.set_rule(world.multiworld.get_location(f"Reach Level {level}", world.player),
                      RegionPointsAtLeast(1))

    for level in range(7, 10):     # Levels 7-9
        world.set_rule(world.multiworld.get_location(f"Reach Level {level}", world.player),
                      RegionPointsAtLeast(2))

    for level in range(10, 12):    # Levels 10-11
        world.set_rule(world.multiworld.get_location(f"Reach Level {level}", world.player),
                      RegionPointsAtLeast(4))

    for level in range(12, 13):    # Levels 12
        world.set_rule(world.multiworld.get_location(f"Reach Level {level}", world.player),
                      RegionPointsAtLeast(5))

    for level in range(13, 16):    # Levels 13-15
        world.set_rule(world.multiworld.get_location(f"Reach Level {level}", world.player),
                      RegionPointsAtLeast(7))

    for level in range(16, 19):    # Levels 16-18
        world.set_rule(world.multiworld.get_location(f"Reach Level {level}", world.player),
                      RegionPointsAtLeast(10))

    for level in range(19, 22):    # Levels 19-21
        world.set_rule(world.multiworld.get_location(f"Reach Level {level}", world.player),
                      RegionPointsAtLeast(13))

    for level in range(22, 26):    # Levels 22-25
        world.set_rule(world.multiworld.get_location(f"Reach Level {level}", world.player),
                      RegionPointsAtLeast(17))

    for level in range(26, 31):    # Levels 26-30
        world.set_rule(world.multiworld.get_location(f"Reach Level {level}", world.player),
                      RegionPointsAtLeast(22))

    for level in range(31, 41):    # Levels 31-40
        world.set_rule(world.multiworld.get_location(f"Reach Level {level}", world.player),
                      RegionPointsAtLeast(23))

    for level in range(41, 51):    # Levels 41-50
        world.set_rule(world.multiworld.get_location(f"Reach Level {level}", world.player),
                      RegionPointsAtLeast(25))

    # Exclude Levels Above code
    if world.options.exclude_levels:
        threshold = world.options.exclude_levels_above.value

        # Only run if we're not effectively excluding nothing
        if threshold < 50:
            for location in world.multiworld.get_locations(world.player):
                name = location.name
                match = re.match(r"Reach Level (\d+)", name)

                if match:
                    level_number = int(match.group(1))
                    if level_number > threshold:
                        location.progress_type = LocationProgressType.EXCLUDED

                elif name == "Reach Level 30!":
                    if 30 > threshold:
                        location.progress_type = LocationProgressType.EXCLUDED

                elif name == "Reach Level 40!":
                    if 40 > threshold:
                        location.progress_type = LocationProgressType.EXCLUDED

                elif name == "Reach max level":
                    if 50 > threshold:
                        location.progress_type = LocationProgressType.EXCLUDED


    # --------------------------------------------------------------------
    # Main scoop chain
    # --------------------------------------------------------------------
    # "Meet Jessie in the Warehouse" is a prologue main scoop that
    # always exists (see PROLOGUE_MAIN_SCOOPS). Its rule is set outside
    # the main_scoops_enabled guard so Savior+ScoopSanity still gates it
    # correctly. Other rules that reference it from within the guard are
    # fine because they only run when it's guaranteed to exist.
    world.set_rule(world.multiworld.get_location("Meet Jessie in the Warehouse", world.player), CanReachRegion("Warehouse"))

    # Events — the rest of the main-scoop completion chain. These
    # locations are MAIN_SCOOP category and don't exist when
    # Savior+ScoopSanity is active (main scoops excluded). Skip the
    # block to avoid KeyErrors from get_location on nonexistent names.
    if world.main_scoops_enabled:
        # ScoopSanity overrides this rule per-event in the SCOOP_EVENTS
        # loop below; here is the vanilla path only (story chains from
        # Meet Jessie -> walk Brad through the mall to the safe room).
        world.set_rule(world.multiworld.get_location("Complete Backup for Brad", world.player),
                      And(CanReachLocation("Meet Jessie in the Warehouse"),
                          CanReachRegion("Leisure Park"), CanReachRegion("Paradise Plaza"),
                          CanReachRegion("Food Court")))

        world.set_rule(world.multiworld.get_location("Escort Brad to see Dr Barnaby", world.player),
                      And(CanReachLocation("Complete Backup for Brad"),
                          CanReachRegion("Entrance Plaza"), CanReachRegion("Al Fresca Plaza")))

        world.set_rule(world.multiworld.get_location("Complete Temporary Agreement", world.player), CanReachLocation("Escort Brad to see Dr Barnaby"))

        if not world.options.scoop_sanity:
            world.set_rule(world.multiworld.get_location("Meet back at the Security Room at 6am day 2", world.player), And(Has("DAY2_06_AM"), CanReachLocation("Complete Temporary Agreement")))

            world.set_rule(world.multiworld.get_location("Complete Image in the Monitor", world.player), CanReachLocation("Meet back at the Security Room at 6am day 2"))

        world.set_rule(world.multiworld.get_location("Complete Rescue the Professor", world.player),
                      And(CanReachLocation("Complete Image in the Monitor"),
                          Has("Entrance Plaza - Paradise Plaza Key") if world.options.split_keys else True_()))

        world.set_rule(world.multiworld.get_location("Meet Steven", world.player), And(CanReachLocation("Complete Rescue the Professor"), CanReachRegion("North Plaza"), CanReachRegion("Seon's Food and Stuff")))

        world.set_rule(world.multiworld.get_location("Clean up... Register 6!", world.player), CanReachLocation("Meet Steven"))

        world.set_rule(world.multiworld.get_location("Complete Medicine Run", world.player), CanReachLocation("Clean up... Register 6!"))

        world.set_rule(world.multiworld.get_location("Complete Professor's Past", world.player), And(CanReachLocation("Complete Medicine Run"), Has("DAY2_06_AM"), Has("DAY2_11_AM")))

        world.set_rule(world.multiworld.get_location("Complete Girl Hunting", world.player), CanReachLocation("Complete Professor's Past"))

        world.set_rule(world.multiworld.get_location("Beat up Isabela", world.player), CanReachLocation("Complete Girl Hunting"))

        world.set_rule(world.multiworld.get_location("Complete Promise to Isabela", world.player), And(CanReachLocation("Beat up Isabela"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))

        world.set_rule(world.multiworld.get_location("Save Isabela from the zombie", world.player), CanReachLocation("Complete Promise to Isabela"))

        world.set_rule(world.multiworld.get_location("Complete Transporting Isabela", world.player), CanReachLocation("Save Isabela from the zombie"))

        world.set_rule(world.multiworld.get_location("Carry Isabela back to the Security Room", world.player), CanReachLocation("Complete Transporting Isabela"))

        world.set_rule(world.multiworld.get_location("Complete Santa Cabeza", world.player), CanReachLocation("Carry Isabela back to the Security Room"))

        if not world.options.scoop_sanity:
            world.set_rule(world.multiworld.get_location("Meet back at the Security Room at 11am day 3", world.player), And(CanReachLocation("Complete Santa Cabeza"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), Has("DAY3_11_AM")))

            world.set_rule(world.multiworld.get_location("Complete Bomb Collector", world.player), And(CanReachLocation("Meet back at the Security Room at 11am day 3"), CanReachRegion("Maintenance Tunnel")))

            world.set_rule(world.multiworld.get_location("Beat Drivin Carlito", world.player), And(CanReachLocation("Complete Bomb Collector"), CanReachRegion("Maintenance Tunnel")))

            world.set_rule(world.multiworld.get_location("Meet back at the Security Room at 5pm day 3", world.player), Or(CanReachLocation("Complete Bomb Collector"), CanReachLocation("Beat Drivin Carlito")))

            world.set_rule(world.multiworld.get_location("Escort Isabela to Carlito's Hideout and have a chat", world.player),
                          And(CanReachLocation("Meet back at the Security Room at 5pm day 3"),
                              CanReachRegion("Carlito's Hideout"),
                              And(Has("Paradise Plaza - Warehouse Key"), Has("Leisure Park - Paradise Plaza Key"), Has("Leisure Park - North Plaza Key"), Has("Carlito's Hideout - North Plaza Key")) if world.options.split_keys else True_()))

        if world.options.scoop_sanity:
            world.multiworld.get_location("Beat Drivin Carlito", world.player).progress_type = LocationProgressType.EXCLUDED

            world.multiworld.get_location("Rescue Greg Simpson", world.player).progress_type = LocationProgressType.EXCLUDED

        world.set_rule(world.multiworld.get_location("Complete Jessie's Discovery", world.player), CanReachLocation("Escort Isabela to Carlito's Hideout and have a chat"))

        world.set_rule(world.multiworld.get_location("Meet Larry", world.player), CanReachLocation("Complete Jessie's Discovery"))

        world.set_rule(world.multiworld.get_location("Complete The Butcher", world.player), CanReachLocation("Meet Larry"))

        if not world.options.scoop_sanity:
            # Vanilla order ends the chain on The Butcher. Under ScoopSanity the
            # chain is shuffled, so Memories is re-pointed at whichever scoop
            # ends up last (see the anchor further down).
            world.set_rule(world.multiworld.get_location("Complete Memories", world.player), CanReachLocation("Complete The Butcher"))

            world.set_rule(world.multiworld.get_location("Head back to the Security Room at the end of day 3", world.player), CanReachLocation("Complete Memories"))

            world.set_rule(world.multiworld.get_location("Witness Special Forces 10pm day 3", world.player), CanReachLocation("Complete Memories"))

        world.set_rule(world.multiworld.get_location("Ending A: Solve all of the cases and be on the helipad at 12pm", world.player), And(CanReachLocation("Complete Memories"), CanReachRegion("Heliport"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), Has("DAY3_11_AM"), Has("DAY4_12_PM")))

    # Overtime rules only apply when goal is Ending S
    if world.options.goal.value == 0:
        world.set_rule(world.multiworld.get_location("Get bit!", world.player), CanReachLocation("Ending A: Solve all of the cases and be on the helipad at 12pm"))

        world.set_rule(world.multiworld.get_location("Gather the suppressants and generator and talk to Isabela", world.player), And(CanReachLocation("Get bit!"), And(CanReachRegion("Paradise Plaza"), CanReachRegion("Entrance Plaza"), CanReachRegion("Al Fresca Plaza"), CanReachRegion("Leisure Park"), CanReachRegion("Food Court"), CanReachRegion("Maintenance Tunnel"), CanReachRegion("Wonderland Plaza"))))

        world.set_rule(world.multiworld.get_location("See the crashed helicopter", world.player), CanReachLocation("Get bit!"))

        world.set_rule(world.multiworld.get_location("Frank sees a sick-ass RC Drone", world.player), CanReachLocation("Get bit!"))

        world.set_rule(world.multiworld.get_location("Give Isabela 5 queens", world.player), CanReachLocation("Gather the suppressants and generator and talk to Isabela"))

        world.set_rule(world.multiworld.get_location("Reach the end of the tunnel with Isabela", world.player), CanReachLocation("Give Isabela 5 queens"))

        world.set_rule(world.multiworld.get_location("Get to the Humvee", world.player), And(CanReachLocation("Give Isabela 5 queens"), CanReachRegion("Tunnels")))

        world.set_rule(world.multiworld.get_location("Fight a tank and win", world.player), CanReachLocation("Get to the Humvee"))

        world.set_rule(world.multiworld.get_location("Ending S: Beat up Brock with your bare fists!", world.player), CanReachLocation("Fight a tank and win"))

        world.set_rule(world.multiworld.get_location("Kill 10 Special Forces", world.player), And(CanReachRegion("Paradise Plaza"), Has("DAY3_11_AM"), CanReachLocation("Get bit!"), CanReachLocation("Ending A: Solve all of the cases and be on the helipad at 12pm")))

        world.set_rule(world.multiworld.get_location("Kill 100 zombies with an RPG", world.player), And(CanReachRegion("Maintenance Tunnel"), CanReachLocation("Get bit!")))

    # ScoopSanity: gate every event of every scoop uniformly on item
    # received, previous scoop's completion, scoop regions, and the
    # position-level gate. Replaces the vanilla event-to-event chain so
    # randomized order can't strand events behind the vanilla predecessor.
    # Day items aren't checked -- the engine sets time flags on chain advance.
    if world.options.scoop_sanity and world.scoop_order:
        for i, scoop_name in enumerate(world.scoop_order):
            prereq = ("Meet Jessie in the Warehouse" if i == 0
                      else SCOOP_COMPLETION_MAP[world.scoop_order[i - 1]])
            regions = SCOOP_REGION_REQUIREMENTS.get(scoop_name, [])
            level_req = (SCOOP_POSITION_LEVEL_GATES[i]
                         if i < len(SCOOP_POSITION_LEVEL_GATES)
                         else None)
            for event_name in SCOOP_EVENTS[scoop_name]:
                loc = world.multiworld.get_location(event_name, world.player)
                _scoop_rule = And(Has(scoop_name), CanReachLocation(prereq),
                                  *[CanReachRegion(r) for r in regions])
                if level_req is not None:
                    _scoop_rule = And(_scoop_rule,
                                      CanReachLocation(f"Reach Level {level_req}"))
                if world.options.split_keys:
                    _scoop_rule = And(_scoop_rule,
                                      *[Has(key) for key in
                                        SPLIT_KEY_SCOOP_DOORS.get(scoop_name, ())])
                world.set_rule(loc, _scoop_rule)

        # Complete Memories is the post-chain anchor; gates on the last
        # randomized scoop's completion regardless of which scoop that is.
        last_completion = SCOOP_COMPLETION_MAP[world.scoop_order[-1]]
        world.set_rule(world.multiworld.get_location("Complete Memories", world.player),
                      CanReachLocation(last_completion))


    # --------------------------------------------------------------------
    # Survivors
    # --------------------------------------------------------------------
    # Survivors in Rooftop
    world.set_rule(world.multiworld.get_location("Rescue Jeff Meyer", world.player), CanReachRegion("Rooftop"))
    world.set_rule(world.multiworld.get_location("Rescue Natalie Meyer", world.player), CanReachRegion("Rooftop"))

    # Survivors in Paradise Plaza
    world.set_rule(world.multiworld.get_location("Rescue Heather Tompkins", world.player), And(CanReachRegion("Paradise Plaza"), (Has("Twin Sisters") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), CanReachLocation("Rescue Ross Folk"), CanReachLocation("Rescue Tonya Waters")))))
    world.set_rule(world.multiworld.get_location("Rescue Pamela Tompkins", world.player), And(CanReachRegion("Paradise Plaza"), (Has("Twin Sisters") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), CanReachLocation("Rescue Ross Folk"), CanReachLocation("Rescue Tonya Waters")))))
    world.set_rule(world.multiworld.get_location("Rescue Ronald Shiner", world.player), And(CanReachRegion("Paradise Plaza"), (Has("Orange Juice") if world.options.restricted_item_mode else True_()), (Has("Restaurant Man") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
    world.set_rule(world.multiworld.get_location("Rescue Jennifer Gorman", world.player), And(CanReachRegion("Paradise Plaza"), (Has("The Cult") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
    world.set_rule(world.multiworld.get_location("Rescue Tad Hawthorne", world.player), And(CanReachRegion("Paradise Plaza"), CanReachLocation("Kill Kent on day 3"), (And(Has("Cut from the Same Cloth"), Has("Photo Challenge"), Has("Photographer's Pride")) if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), Has("DAY3_11_AM")))))
    world.set_rule(world.multiworld.get_location("Rescue Simone Ravendark", world.player), And(CanReachRegion("Paradise Plaza"), (Has("A Woman in Despair") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), Has("DAY3_11_AM"), CanReachLocation("Complete Santa Cabeza")))))
    ## 1.1.0 HAS A BUG WITH "Rescue Simone Ravendark", THIS NEXT LINE EXCLUDES THIS CHECK IN ALL PLAY MODES AND SHOULD BE REMOVED UPON FIX BEING IMPLEMENTED
    world.multiworld.get_location("Rescue Simone Ravendark", world.player).progress_type = LocationProgressType.EXCLUDED

    # Survivors in Leisure Park
    world.set_rule(world.multiworld.get_location("Rescue Sophie Richard", world.player), And(CanReachRegion("Leisure Park"), (Has("The Convicts") if world.options.scoop_sanity else True_())))

    # Survivors in Food Court
    world.set_rule(world.multiworld.get_location("Rescue Gil Jiminez", world.player), And(CanReachRegion("Food Court"), (Has("The Drunkard") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))))

    # Survivors in Al Fresca Plaza
    world.set_rule(world.multiworld.get_location("Rescue Aaron Swoop", world.player), And(CanReachRegion("Al Fresca Plaza"), (Has("Barricade Pair") if world.options.scoop_sanity else True_())))
    world.set_rule(world.multiworld.get_location("Rescue Burt Thompson", world.player), And(CanReachRegion("Al Fresca Plaza"), (Has("Barricade Pair") if world.options.scoop_sanity else True_())))
    world.set_rule(world.multiworld.get_location("Rescue Leah Stein", world.player), And(CanReachRegion("Al Fresca Plaza"), (Has("A Mother's Lament") if world.options.scoop_sanity else True_())))
    world.set_rule(world.multiworld.get_location("Rescue Gordon Stalworth", world.player), And(CanReachRegion("Al Fresca Plaza"), (Has("The Coward") if world.options.scoop_sanity else Has("DAY2_06_AM"))))

    # Survivors in Entrance Plaza
    world.set_rule(world.multiworld.get_location("Rescue Bill Brenton", world.player), ep_shutter)
    world.set_rule(world.multiworld.get_location("Rescue Wayne Blackwell", world.player), And(ep_shutter, (Has("Mark of the Sniper") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), CanReachLocation("Meet the Hall Family")))))
    world.set_rule(world.multiworld.get_location("Rescue Jolie Wu", world.player), And(ep_shutter, (Has("The Woman Who Didn't Make it") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
    world.set_rule(world.multiworld.get_location("Rescue Rachel Decker", world.player), And(ep_shutter, (Has("The Woman Who Didn't Make it") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
    world.set_rule(world.multiworld.get_location("Rescue Floyd Sanders", world.player), And(ep_shutter, (Has("Antique Lover") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))

    # Survivors in Wonderland Plaza
    world.set_rule(world.multiworld.get_location("Rescue Greg Simpson", world.player), And(CanReachRegion("Wonderland Plaza"), CanReachRegion("Paradise Plaza"), (Has("Out of Control") if world.options.scoop_sanity else True_()))) # Greg Simpson is the only Wonderland Plaza Survivor with additional Logic due to him unlocking the shortcut
    world.set_rule(world.multiworld.get_location("Rescue Yuu Tanaka", world.player), And(CanReachRegion("Wonderland Plaza"), (Has("Book [Japanese Conversation]") if world.options.restricted_item_mode else True_()), (Has("Japanese Tourists") if world.options.scoop_sanity else True_())))
    world.set_rule(world.multiworld.get_location("Rescue Shinji Kitano", world.player), And(CanReachRegion("Wonderland Plaza"), (Has("Book [Japanese Conversation]") if world.options.restricted_item_mode else True_()), (Has("Japanese Tourists") if world.options.scoop_sanity else True_())))
    world.set_rule(world.multiworld.get_location("Rescue Tonya Waters", world.player), And(CanReachRegion("Wonderland Plaza"), (Has("Lovers") if world.options.scoop_sanity else Has("DAY2_06_AM"))))
    world.set_rule(world.multiworld.get_location("Rescue Ross Folk", world.player), And(CanReachRegion("Wonderland Plaza"), (Has("Lovers") if world.options.scoop_sanity else Has("DAY2_06_AM"))))
    world.set_rule(world.multiworld.get_location("Rescue Kay Nelson", world.player), And(CanReachRegion("Wonderland Plaza"), (Has("Above the Law") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), CanReachLocation("Kill Jo")))))
    world.set_rule(world.multiworld.get_location("Rescue Lilly Deacon", world.player), And(CanReachRegion("Wonderland Plaza"), (Has("Above the Law") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), CanReachLocation("Kill Jo")))))
    world.set_rule(world.multiworld.get_location("Rescue Kelly Carpenter", world.player), And(CanReachRegion("Wonderland Plaza"), (Has("Above the Law") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), CanReachLocation("Kill Jo")))))
    world.set_rule(world.multiworld.get_location("Rescue Janet Star", world.player), And(CanReachRegion("Wonderland Plaza"), (Has("Above the Law") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), CanReachLocation("Kill Jo")))))
    world.set_rule(world.multiworld.get_location("Rescue Sally Mills", world.player), And(CanReachRegion("Wonderland Plaza"), (Has("Hanging by a Thread") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
    world.set_rule(world.multiworld.get_location("Rescue Nick Evans", world.player), And(CanReachRegion("Wonderland Plaza"), (Has("Hanging by a Thread") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
    world.set_rule(world.multiworld.get_location("Rescue Mindy Baker", world.player), And(CanReachRegion("Wonderland Plaza"), (Has("Long Haired Punk") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), CanReachLocation("Defeat Paul")))))
    world.set_rule(world.multiworld.get_location("Rescue Debbie Willet", world.player), And(CanReachRegion("Wonderland Plaza"), (Has("Long Haired Punk") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), CanReachLocation("Defeat Paul")))))
    world.set_rule(world.multiworld.get_location("Rescue Paul Carson", world.player), And(CanReachRegion("Wonderland Plaza"), (Has("Fire Extinguisher") if world.options.restricted_item_mode else True_()), (Has("Long Haired Punk") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), CanReachLocation("Defeat Paul")))))
    world.set_rule(world.multiworld.get_location("Rescue Leroy McKenna", world.player), And(CanReachRegion("Wonderland Plaza"), (Has("A Sick Man") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))))
    world.set_rule(world.multiworld.get_location("Rescue Susan Walsh", world.player), And(CanReachRegion("Wonderland Plaza"), (Has("The Woman Left Behind") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))))

    # Survivors in North Plaza
    world.set_rule(world.multiworld.get_location("Rescue David Bailey", world.player), And(CanReachRegion("North Plaza"), (Has("Shadow of the North Plaza") if world.options.scoop_sanity else True_())))
    world.set_rule(world.multiworld.get_location("Rescue Kindell Johnson", world.player), And(CanReachRegion("North Plaza"), (Has("Dressed for Action") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))))
    world.set_rule(world.multiworld.get_location("Rescue Brett Styles", world.player), And(CanReachRegion("North Plaza"), (Has("Gun Shop Standoff") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))))
    world.set_rule(world.multiworld.get_location("Rescue Jonathan Picardson", world.player), And(CanReachRegion("North Plaza"), (Has("Gun Shop Standoff") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))))
    world.set_rule(world.multiworld.get_location("Rescue Alyssa Laurent", world.player), And(CanReachRegion("North Plaza"), (Has("Gun Shop Standoff") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))))

    # Survivors locked behind Hatchet Man (requires both North Plaza and Crislip's Home Saloon)
    world.set_rule(world.multiworld.get_location("Rescue Josh Manning", world.player), And(CanReachRegion("North Plaza"), CanReachRegion("Crislip's Home Saloon"), (Has("The Hatchet Man") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), CanReachLocation("Kill Cliff")))))
    world.set_rule(world.multiworld.get_location("Rescue Barbara Patterson", world.player), And(CanReachRegion("North Plaza"), CanReachRegion("Crislip's Home Saloon"), (Has("The Hatchet Man") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), CanReachLocation("Kill Cliff")))))
    world.set_rule(world.multiworld.get_location("Rescue Rich Atkins", world.player), And(CanReachRegion("North Plaza"), CanReachRegion("Crislip's Home Saloon"), (Has("The Hatchet Man") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), CanReachLocation("Kill Cliff")))))

    # Survivors in Colby's Movieland
    world.set_rule(world.multiworld.get_location("Rescue Beth Shrake", world.player), And(CanReachRegion("Colby's Movieland"), (Has("A Strange Group") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), CanReachLocation("Kill Sean")))))
    world.set_rule(world.multiworld.get_location("Rescue Michelle Feltz", world.player), And(CanReachRegion("Colby's Movieland"), (Has("A Strange Group") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), CanReachLocation("Kill Sean")))))
    world.set_rule(world.multiworld.get_location("Rescue Nathan Crabbe", world.player), And(CanReachRegion("Colby's Movieland"), (Has("A Strange Group") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), CanReachLocation("Kill Sean")))))
    world.set_rule(world.multiworld.get_location("Rescue Ray Mathison", world.player), And(CanReachRegion("Colby's Movieland"), (Has("A Strange Group") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), CanReachLocation("Kill Sean")))))
    world.set_rule(world.multiworld.get_location("Rescue Cheryl Jones", world.player), And(CanReachRegion("Colby's Movieland"), (Has("A Strange Group") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), CanReachLocation("Kill Sean")))))

    # These five survivor-count milestones are gated behind nearly every
    # late-game scoop, so they only become reachable once most of the
    # progression chain is already solved -- a poor place for progression
    # or useful items, since they'd effectively be locked behind the rest
    # of the run. Mark them filler-only.
    for _name in (
        "Get 50 survivors to join",
        "Encounter 10 survivors",
        "Encounter 50 survivors",
        "Save 10 survivors",
        "Save 50 survivors",
    ):
        world.multiworld.get_location(_name, world.player).progress_type = LocationProgressType.EXCLUDED

    world.set_rule(world.multiworld.get_location("Kill 1000 zombies", world.player), CanReachRegion("Maintenance Tunnel"))
    world.set_rule(world.multiworld.get_location("Kill 2000 zombies", world.player), And(CanReachRegion("Maintenance Tunnel"), CanReachRegion("North Plaza"), CanReachRegion("Entrance Plaza")))
    world.set_rule(world.multiworld.get_location("Kill 5000 zombies", world.player), And(CanReachRegion("Maintenance Tunnel"), CanReachRegion("North Plaza"), CanReachRegion("Entrance Plaza"), CanReachRegion("Wonderland Plaza"), CanReachRegion("Al Fresca Plaza")))
    world.set_rule(world.multiworld.get_location("Kill 10000 zombies", world.player), And(CanReachRegion("Maintenance Tunnel"), CanReachRegion("North Plaza"), CanReachRegion("Entrance Plaza"), CanReachRegion("Wonderland Plaza"), CanReachRegion("Al Fresca Plaza"), ending_a_rule))
    world.set_rule(world.multiworld.get_location("Walk a quarter marathon", world.player), And(CanReachRegion("Leisure Park"), CanReachRegion("Al Fresca Plaza"), CanReachRegion("Wonderland Plaza"), CanReachRegion("North Plaza"), CanReachRegion("Entrance Plaza"), CanReachRegion("Food Court"), CanReachRegion("Paradise Plaza"), CanReachRegion("Seon's Food and Stuff"), CanReachRegion("Crislip's Home Saloon"), CanReachRegion("Colby's Movieland")))
    world.set_rule(world.multiworld.get_location("Destroy all of the wall plates in the Food Court", world.player), CanReachRegion("Food Court"))

    # --------------------------------------------------------------------
    # --------------------------------------------------------------------
    # Psychopaths
    world.set_rule(world.multiworld.get_location("Watch the convicts kill that poor guy", world.player), And(CanReachRegion("Leisure Park"), (Has("The Convicts") if world.options.scoop_sanity else True_())))

    world.set_rule(world.multiworld.get_location("Meet Cletus", world.player), And(CanReachRegion("North Plaza"), (Has("Cletus") if world.options.scoop_sanity else True_())))
    world.set_rule(world.multiworld.get_location("Kill Cletus", world.player), CanReachLocation("Meet Cletus"))

    world.set_rule(world.multiworld.get_location("Meet Adam", world.player), And(CanReachRegion("Wonderland Plaza"), (Has("Out of Control") if world.options.scoop_sanity else True_())))
    world.set_rule(world.multiworld.get_location("Kill Adam", world.player), CanReachLocation("Meet Adam"))

    world.set_rule(world.multiworld.get_location("Meet Cliff", world.player), And(CanReachRegion("Crislip's Home Saloon"), (Has("The Hatchet Man") if world.options.scoop_sanity else Has("DAY2_06_AM"))))
    world.set_rule(world.multiworld.get_location("Kill Cliff", world.player), CanReachLocation("Meet Cliff"))

    world.set_rule(world.multiworld.get_location("Meet Jo", world.player), And(CanReachRegion("Wonderland Plaza"), (Has("Above the Law") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
    world.set_rule(world.multiworld.get_location("Kill Jo", world.player), CanReachLocation("Meet Jo"))

    world.set_rule(world.multiworld.get_location("Meet the Hall Family", world.player), And(CanReachRegion("Entrance Plaza"), (Has("Mark of the Sniper") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
    world.set_rule(world.multiworld.get_location("Kill Roger and Jack (and Thomas if you want) and chat with Wayne", world.player), And(CanReachLocation("Meet the Hall Family"), (ep_shutter if world.options.scoop_sanity else True_())))

    world.set_rule(world.multiworld.get_location("Witness Sean in Paradise Plaza", world.player), And(CanReachRegion("Paradise Plaza"), (Or(Has("The Cult"), Has("A Strange Group")) if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
    world.set_rule(world.multiworld.get_location("Get grabbed by the raincoats", world.player), And(CanReachLocation("Witness Sean in Paradise Plaza"), CanReachRegion("Leisure Park")))
    world.set_rule(world.multiworld.get_location("Meet Sean", world.player), And(CanReachRegion("Colby's Movieland"), (Has("A Strange Group") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))))
    world.set_rule(world.multiworld.get_location("Kill Sean", world.player), CanReachLocation("Meet Sean"))

    world.set_rule(world.multiworld.get_location("Meet Paul", world.player), And(CanReachRegion("Wonderland Plaza"), (Has("Long Haired Punk") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))))
    world.set_rule(world.multiworld.get_location("Defeat Paul", world.player), CanReachLocation("Meet Paul"))

    world.set_rule(world.multiworld.get_location("Meet Kent on day 1", world.player), And(CanReachRegion("Paradise Plaza"), (Has("Cut from the Same Cloth") if world.options.scoop_sanity else True_())))
    world.set_rule(world.multiworld.get_location("Complete Kent's day 1 photoshoot", world.player), CanReachLocation("Meet Kent on day 1"))
    world.set_rule(world.multiworld.get_location("Meet Kent on day 2", world.player), And(CanReachLocation("Complete Kent's day 1 photoshoot"), (Or(Has("Novelty Mask (Bear)"), Has("Novelty Mask (Servbot)"), Has("Novelty Mask (Horse)")) if world.options.restricted_item_mode else True_()), (And(Has("Cut from the Same Cloth"), Has("Photo Challenge")) if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
    world.set_rule(world.multiworld.get_location("Complete Kent's day 2 photoshoot", world.player), CanReachLocation("Meet Kent on day 2"))
    world.set_rule(world.multiworld.get_location("Meet Kent on day 3", world.player), And(CanReachLocation("Complete Kent's day 2 photoshoot"), (And(Has("Cut from the Same Cloth"), Has("Photo Challenge"), Has("Photographer's Pride")) if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), Has("DAY3_11_AM")))))
    world.set_rule(world.multiworld.get_location("Kill Kent on day 3", world.player), CanReachLocation("Meet Kent on day 3"))

    # Psychopath encounter / photograph / kill lists.
    # Steven and Larry are MAIN_SCOOP-category locations (tied to the
    # Medicine Run and The Butcher story missions). When main scoops are
    # disabled (Savior+ScoopSanity), those locations don't exist, so we
    # drop them from these challenge rule lists. With 10 remaining
    # psycho events (7 meet + 3 Hall Family; or 7 kill + 3 Hall Family),
    # both "Photograph 8" and "Kill 8" remain achievable.
    meet_psycho_names = [
        "Meet Cletus", "Meet Adam", "Meet Sean", "Meet Jo", "Meet Cliff",
        "Meet Paul", "Meet Kent on day 3",
    ]
    photograph_psychos = [
        ("Meet Cletus", 1), ("Meet Adam", 1), ("Meet Cliff", 1),
        ("Meet Jo", 1), ("Meet the Hall Family", 3), ("Meet Sean", 1),
        ("Meet Paul", 1), ("Meet Kent on day 3", 1),
    ]
    kill_psychos = [
        ("Kill Cletus", 1), ("Kill Adam", 1), ("Kill Cliff", 1),
        ("Kill Jo", 1), ("Kill Roger and Jack (and Thomas if you want) and chat with Wayne", 3),
        ("Kill Sean", 1), ("Defeat Paul", 1), ("Kill Kent on day 3", 1),
    ]
    if world.main_scoops_enabled:
        meet_psycho_names.extend(["Meet Steven", "Meet Larry"])
        photograph_psychos.extend([("Meet Steven", 1), ("Meet Larry", 1)])
        kill_psychos.extend([("Clean up... Register 6!", 1), ("Complete The Butcher", 1)])

    world.set_rule(world.multiworld.get_location("Kill 1 psychopath", world.player),
                  Or(*[CanReachLocation(n) for n in meet_psycho_names]))
    # AtLeast counts children that pass, so an encounter worth 3 psychos is
    # simply listed three times; a weight of 0 drops out on its own.
    world.set_rule(world.multiworld.get_location("Photograph 8 psychopaths", world.player),
                  AtLeast(8, *[CanReachLocation(p) for p, c in photograph_psychos for _ in range(c)]))
    world.set_rule(world.multiworld.get_location("Kill 8 psychopaths", world.player),
                  AtLeast(8, *[CanReachLocation(p) for p, c in kill_psychos for _ in range(c)]))
    world.set_rule(world.multiworld.get_location("Hit 10 zombies with a parasol", world.player), (And(Or(CanReachRegion("Entrance Plaza"), CanReachRegion("Al Fresca Plaza"), CanReachRegion("Crislip's Home Saloon")), Has("Parasol")) if world.options.restricted_item_mode else Or(CanReachRegion("Entrance Plaza"), CanReachRegion("Al Fresca Plaza"), CanReachRegion("Crislip's Home Saloon"), And(Has("Parasol"), CanReachRegion("Paradise Plaza")))))
    world.set_rule(world.multiworld.get_location("Kill 50 cultists", world.player), And(CanReachRegion("Paradise Plaza"), CanReachLocation("Witness Sean in Paradise Plaza")))
    world.set_rule(world.multiworld.get_location("Photograph 30 survivors", world.player), And(CanReachRegion("Leisure Park"), CanReachRegion("Al Fresca Plaza"), CanReachRegion("Wonderland Plaza"), CanReachRegion("North Plaza"), CanReachRegion("Entrance Plaza"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))
    world.set_rule(world.multiworld.get_location("Escort 8 survivors at once", world.player), And(CanReachRegion("Paradise Plaza"), CanReachRegion("Al Fresca Plaza"), CanReachLocation("Kill Jo"), CanReachRegion("Food Court"), CanReachRegion("Entrance Plaza"), (AtLeast(8, *[Has(s) for s, c in SCOOP_SURVIVOR_COUNTS.items() for _ in range(c[0])]) if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
    world.set_rule(world.multiworld.get_location("Frank the pimp", world.player), And(CanReachRegion("Paradise Plaza"), CanReachRegion("Al Fresca Plaza"), CanReachLocation("Kill Jo"), CanReachRegion("Food Court"), CanReachRegion("Entrance Plaza"), (AtLeast(8, *[Has(s) for s, c in SCOOP_SURVIVOR_COUNTS.items() for _ in range(c[1])]) if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
    world.set_rule(world.multiworld.get_location("Jump a vehicle 50 feet", world.player), CanReachRegion("Leisure Park"))
    world.set_rule(world.multiworld.get_location("Bowl over 5 zombies", world.player), (And(Or(CanReachRegion("Paradise Plaza"), CanReachRegion("Wonderland Plaza")), Has("Bowling Ball")) if world.options.restricted_item_mode else Or(CanReachRegion("Paradise Plaza"), CanReachRegion("Wonderland Plaza"), And(Has("Bowling Ball"), Or(CanReachRegion("Paradise Plaza"), CanReachRegion("Entrance Plaza"))))))
    world.set_rule(world.multiworld.get_location("Hit a golf ball 100 feet", world.player), (And(Or(CanReachRegion("Paradise Plaza"), CanReachRegion("Entrance Plaza")), Has("Golf Club")) if world.options.restricted_item_mode else Or(CanReachRegion("Paradise Plaza"), CanReachRegion("Entrance Plaza"), And(Has("Golf Club"), CanReachRegion("Rooftop")))))

    # --------------------------------------------------------------------
    # --------------------------------------------------------------------
    # Challenges
    world.set_rule(world.multiworld.get_location("Reach Level 10!", world.player), CanReachLocation("Reach Level 10"))
    world.set_rule(world.multiworld.get_location("Reach Level 20!", world.player), CanReachLocation("Reach Level 20"))
    world.set_rule(world.multiworld.get_location("Reach Level 30!", world.player), CanReachLocation("Reach Level 30"))
    world.set_rule(world.multiworld.get_location("Reach Level 40!", world.player), CanReachLocation("Reach Level 40"))
    world.set_rule(world.multiworld.get_location("Reach max level", world.player), CanReachLocation("Reach Level 50"))
    world.set_rule(world.multiworld.get_location("Kill 500 zombies by vehicle", world.player), CanReachRegion("Maintenance Tunnel"))
    world.set_rule(world.multiworld.get_location("Kill 1000 zombies by vehicle", world.player), CanReachRegion("Maintenance Tunnel"))
    all_side_scoops = SURVIVOR_SCOOP_NAMES + PSYCHOPATH_SCOOP_NAMES
    world.set_rule(world.multiworld.get_location("Get 50 survivors to join", world.player), And(CanReachRegion("Paradise Plaza"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), Has("DAY3_11_AM"), CanReachLocation("Kill Kent on day 3"), CanReachLocation("Kill Cliff"), CanReachLocation("Kill Jo"), CanReachLocation("Kill Adam"), CanReachLocation("Kill Sean"), CanReachLocation("Kill Roger and Jack (and Thomas if you want) and chat with Wayne"), CanReachLocation("Defeat Paul"), (And(HasAll(*all_side_scoops), ending_a_rule) if world.options.scoop_sanity else True_())))
    world.set_rule(world.multiworld.get_location("Encounter 10 survivors", world.player), And(CanReachRegion("Paradise Plaza"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), Has("DAY3_11_AM"), CanReachLocation("Kill Kent on day 3"), CanReachLocation("Kill Cliff"), CanReachLocation("Kill Jo"), CanReachLocation("Kill Adam"), CanReachLocation("Kill Sean"), CanReachLocation("Kill Roger and Jack (and Thomas if you want) and chat with Wayne"), CanReachLocation("Defeat Paul")))
    world.set_rule(world.multiworld.get_location("Encounter 50 survivors", world.player), And(CanReachRegion("Paradise Plaza"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), Has("DAY3_11_AM"), CanReachLocation("Kill Kent on day 3"), CanReachLocation("Kill Cliff"), CanReachLocation("Kill Jo"), CanReachLocation("Kill Adam"), CanReachLocation("Kill Sean"), CanReachLocation("Kill Roger and Jack (and Thomas if you want) and chat with Wayne"), CanReachLocation("Defeat Paul"), (And(HasAll(*all_side_scoops), ending_a_rule) if world.options.scoop_sanity else True_())))
    world.set_rule(world.multiworld.get_location("Save 10 survivors", world.player), And(CanReachRegion("Paradise Plaza"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), Has("DAY3_11_AM"), Has("DAY4_12_PM"), CanReachLocation("Kill Kent on day 3"), CanReachLocation("Kill Cliff"), CanReachLocation("Kill Jo"), CanReachLocation("Kill Adam"), CanReachLocation("Kill Sean"), CanReachLocation("Kill Roger and Jack (and Thomas if you want) and chat with Wayne"), CanReachLocation("Defeat Paul"), (And(HasAll(*all_side_scoops), ending_a_rule) if world.options.scoop_sanity else True_())))
    world.set_rule(world.multiworld.get_location("Save 50 survivors", world.player), And(CanReachRegion("Paradise Plaza"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), Has("DAY3_11_AM"), Has("DAY4_12_PM"), CanReachLocation("Kill Kent on day 3"), CanReachLocation("Kill Cliff"), CanReachLocation("Kill Jo"), CanReachLocation("Kill Adam"), CanReachLocation("Kill Sean"), CanReachLocation("Kill Roger and Jack (and Thomas if you want) and chat with Wayne"), CanReachLocation("Defeat Paul"), (And(HasAll(*all_side_scoops), ending_a_rule) if world.options.scoop_sanity else True_())))

    # Challenge locations default to sphere 0 via the blanket rule above.
    # Falling far enough is awkward to arrange at the start, so this one is
    # pushed behind the Warehouse instead of being an early-game filler
    # slot nobody can identify (#14).
    world.set_rule(world.multiworld.get_location("Fall from a high height", world.player), CanReachRegion("Warehouse"))
    world.set_rule(world.multiworld.get_location("Fire 30 bullets", world.player), Or(CanReachLocation("Fire 300 bullets"), And(Has("Handgun"), Or(CanReachRegion("North Plaza"), CanReachRegion("Wonderland Plaza"), CanReachRegion("Paradise Plaza"), CanReachRegion("Al Fresca Plaza"))) if world.options.restricted_item_mode else Or(CanReachRegion("North Plaza"), CanReachRegion("Wonderland Plaza"), CanReachRegion("Paradise Plaza"), CanReachRegion("Al Fresca Plaza"))))
    world.set_rule(world.multiworld.get_location("Fire 300 bullets", world.player), (And(CanReachRegion("North Plaza"), Or(*[Has(g) for g in ("Handgun", "Submachine Gun", "Shotgun", "Sniper Rifle")])) if world.options.restricted_item_mode else Or(CanReachRegion("North Plaza"), And(Or(*[Has(g) for g in ("Handgun", "Submachine Gun", "Shotgun", "Sniper Rifle", "Heavy Machinegun", "Machinegun")]), CanReachRegion("Rooftop")))))
    # "Ride zombies for 50 feet" requires Zombie Ride only when that
    # skill is actually in the AP item pool. BuildItemPool adds skills
    # only when enable_skill_items is on AND vanilla_progression is
    # "replace" (mode 1) -- under "vanilla_only" or "extra_buffs_only"
    # the engine grants skills on level-up and they aren't AP items,
    # so the location is reachable purely via region access.
    _zombie_ride_is_pool_item = bool(world.options.enable_skill_items) and world.options.vanilla_progression.value == 1
    # Whether Zombie Ride is in the pool is settled at generation time, so
    # the branch belongs here rather than inside the rule.
    _ride_rule = CanReachRegion("Maintenance Tunnel")
    if _zombie_ride_is_pool_item:
        _ride_rule = And(_ride_rule, Has("Zombie Ride"))
    world.set_rule(world.multiworld.get_location("Ride zombies for 50 feet", world.player),
                  _ride_rule)
    world.set_rule(world.multiworld.get_location("Change into 46 new outfits", world.player), And(CanReachRegion("Leisure Park"), CanReachRegion("Al Fresca Plaza"), CanReachRegion("Wonderland Plaza"), CanReachRegion("North Plaza"), CanReachRegion("Entrance Plaza"), CanReachRegion("Food Court"), CanReachRegion("Paradise Plaza"), CanReachRegion("Seon's Food and Stuff"), CanReachRegion("Crislip's Home Saloon"), CanReachRegion("Colby's Movieland")))
    world.set_rule(world.multiworld.get_location("Change into 5 new outfits", world.player), CanReachRegion("Paradise Plaza"))

    # --------------------------------------------------------------------
    # PP Stickers
    # --------------------------------------------------------------------
    # PP Stickers Filler code (make all PP sticker checks excluded)
    if world.options.pp_stickers_filler:
        for location in world.multiworld.get_locations(world.player):
            name = location.name

            # "Photograph PP Sticker 1" to "Photograph PP Sticker 100"
            if re.match(r"Photograph PP Sticker \d+", name):
                location.progress_type = LocationProgressType.EXCLUDED
                continue

            # Milestone checks
            if name in {
                "Photograph 10 PP Stickers",
                "Photograph 20 PP Stickers",
                "Photograph 30 PP Stickers",
                "Photograph 40 PP Stickers",
                "Photograph 50 PP Stickers",
                "Photograph 60 PP Stickers",
                "Photograph 70 PP Stickers",
                "Photograph 80 PP Stickers",
                "Photograph 90 PP Stickers",
                "Photograph all PP Stickers",
            }:
                location.progress_type = LocationProgressType.EXCLUDED

    
    # PP Stickers in Paradise Plaza
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 1", world.player), CanReachRegion("Paradise Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 2", world.player), CanReachRegion("Paradise Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 3", world.player), CanReachRegion("Paradise Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 4", world.player), CanReachRegion("Paradise Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 5", world.player), CanReachRegion("Paradise Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 6", world.player), CanReachRegion("Paradise Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 7", world.player), CanReachRegion("Paradise Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 8", world.player), CanReachRegion("Paradise Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 9", world.player), CanReachRegion("Paradise Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 10", world.player), CanReachRegion("Paradise Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 11", world.player), CanReachRegion("Paradise Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 12", world.player), CanReachRegion("Paradise Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 13", world.player), CanReachRegion("Paradise Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 14", world.player), CanReachRegion("Paradise Plaza"))

    # PP Stickers in Colby's Movieland
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 15", world.player), CanReachRegion("Colby's Movieland"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 16", world.player), CanReachRegion("Colby's Movieland"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 17", world.player), CanReachRegion("Colby's Movieland"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 18", world.player), CanReachRegion("Colby's Movieland"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 19", world.player), CanReachRegion("Colby's Movieland"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 20", world.player), CanReachRegion("Colby's Movieland"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 21", world.player), CanReachRegion("Colby's Movieland"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 22", world.player), CanReachRegion("Colby's Movieland"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 23", world.player), CanReachRegion("Colby's Movieland"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 24", world.player), CanReachRegion("Colby's Movieland"))

    # PP Stickers in Entrance Plaza -- behind the shutters (25-34), as are
    # the EP survivors and Wayne's check further down. ep_shutter is
    # defined above, alongside the PP-bonus rules that also need it.
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 25", world.player), ep_shutter)
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 26", world.player), ep_shutter)
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 27", world.player), ep_shutter)
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 28", world.player), ep_shutter)
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 29", world.player), ep_shutter)
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 30", world.player), ep_shutter)
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 31", world.player), ep_shutter)
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 32", world.player), ep_shutter)
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 33", world.player), ep_shutter)
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 34", world.player), ep_shutter)

    # PP Stickers in Al Fresca Plaza
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 35", world.player), CanReachRegion("Al Fresca Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 36", world.player), CanReachRegion("Al Fresca Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 37", world.player), CanReachRegion("Al Fresca Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 38", world.player), CanReachRegion("Al Fresca Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 39", world.player), CanReachRegion("Al Fresca Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 40", world.player), CanReachRegion("Al Fresca Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 41", world.player), CanReachRegion("Al Fresca Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 42", world.player), CanReachRegion("Al Fresca Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 43", world.player), CanReachRegion("Al Fresca Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 44", world.player), CanReachRegion("Al Fresca Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 45", world.player), CanReachRegion("Al Fresca Plaza"))

    # PP Stickers in Food Court
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 46", world.player), CanReachRegion("Food Court"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 47", world.player), CanReachRegion("Food Court"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 48", world.player), CanReachRegion("Food Court"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 49", world.player), CanReachRegion("Food Court"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 50", world.player), CanReachRegion("Food Court"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 51", world.player), CanReachRegion("Food Court"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 52", world.player), CanReachRegion("Food Court"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 53", world.player), CanReachRegion("Food Court"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 54", world.player), CanReachRegion("Food Court"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 55", world.player), CanReachRegion("Food Court"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 56", world.player), CanReachRegion("Food Court"))

    # PP Stickers in Wonderland Plaza
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 57", world.player), CanReachRegion("Wonderland Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 58", world.player), CanReachRegion("Wonderland Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 59", world.player), CanReachRegion("Wonderland Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 60", world.player), CanReachRegion("Wonderland Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 61", world.player), CanReachRegion("Wonderland Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 62", world.player), CanReachRegion("Wonderland Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 63", world.player), CanReachRegion("Wonderland Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 64", world.player), CanReachRegion("Wonderland Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 65", world.player), CanReachRegion("Wonderland Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 66", world.player), CanReachRegion("Wonderland Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 67", world.player), CanReachRegion("Wonderland Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 68", world.player), CanReachRegion("Wonderland Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 69", world.player), CanReachRegion("Wonderland Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 70", world.player), CanReachRegion("Wonderland Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 71", world.player), CanReachRegion("Wonderland Plaza"))

    # PP Stickers in North Plaza
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 72", world.player), CanReachRegion("North Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 73", world.player), CanReachRegion("North Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 76", world.player), CanReachRegion("North Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 77", world.player), CanReachRegion("North Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 78", world.player), CanReachRegion("North Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 79", world.player), CanReachRegion("North Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 80", world.player), CanReachRegion("North Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 81", world.player), CanReachRegion("North Plaza"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 82", world.player), CanReachRegion("North Plaza"))

    # PP Stickers in Seon's Food and Stuff
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 83", world.player), CanReachRegion("Seon's Food and Stuff"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 84", world.player), CanReachRegion("Seon's Food and Stuff"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 85", world.player), CanReachRegion("Seon's Food and Stuff"))

    # PP Stickers in Crislip's Home Saloon
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 74", world.player), CanReachRegion("Crislip's Home Saloon"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 75", world.player), CanReachRegion("Crislip's Home Saloon"))

    # PP Stickers in Leisure Park
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 86", world.player), CanReachRegion("Leisure Park"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 87", world.player), CanReachRegion("Leisure Park"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 88", world.player), CanReachRegion("Leisure Park"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 89", world.player), CanReachRegion("Leisure Park"))

    # PP Stickers in Maintenance Tunnel
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 90", world.player), CanReachRegion("Maintenance Tunnel"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 91", world.player), CanReachRegion("Maintenance Tunnel"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 92", world.player), CanReachRegion("Maintenance Tunnel"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 93", world.player), CanReachRegion("Maintenance Tunnel"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 94", world.player), CanReachRegion("Maintenance Tunnel"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 95", world.player), CanReachRegion("Maintenance Tunnel"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 96", world.player), CanReachRegion("Maintenance Tunnel"))

    # PP Stickers in Security Room
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 97", world.player), CanReachRegion("Security Room"))

    # PP Stickers in Cultists' Hideout
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 98", world.player), And(CanReachRegion("Paradise Plaza"), CanReachRegion("Leisure Park"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), CanReachLocation("Get grabbed by the raincoats")))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 99", world.player), And(CanReachRegion("Paradise Plaza"), CanReachRegion("Leisure Park"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), CanReachLocation("Get grabbed by the raincoats")))

    # PP Stickers in Rooftop
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 100", world.player), CanReachRegion("Rooftop"))

    # PP Sticker group access for the "Photograph N PP Stickers"
    # challenge rules. Each group becomes (count, regions, locations,
    # predicate). The Brad-escort entry in the EP group (25-34) is a
    # marker for the EP shutter and is swapped for the mode-aware
    # ep_shutter predicate. Savior+SS additionally drops main-scoop
    # locations that don't exist in that mode.
    if not world.main_scoops_enabled:
        main_scoop_location_names = {
            loc.name
            for region_locs in location_tables.values()
            for loc in region_locs
            if loc.category == DRLocationCategory.MAIN_SCOOP
        }
    # Each group is a batch of stickers sharing one set of requirements.
    pp_sticker_group_rules = []
    for (count, regions, locs) in PP_STICKER_GROUPS:
        parts = []
        if "Escort Brad to see Dr Barnaby" in locs:
            locs = [l for l in locs if l != "Escort Brad to see Dr Barnaby"]
            parts.append(ep_shutter)
        if not world.main_scoops_enabled:
            locs = [l for l in locs if l not in main_scoop_location_names]
        parts.extend(CanReachRegion(r) for r in regions)
        parts.extend(CanReachLocation(l) for l in locs)
        pp_sticker_group_rules.append((count, And(*parts) if parts else True_()))

    # A milestone is a weighted count, so each group is listed once per
    # sticker it is worth and AtLeast does the summing.
    _sticker_children = [rule for count, rule in pp_sticker_group_rules
                         for _ in range(count)]

    for _n, _name in [
        (10, "Photograph 10 PP Stickers"), (20, "Photograph 20 PP Stickers"),
        (30, "Photograph 30 PP Stickers"), (40, "Photograph 40 PP Stickers"),
        (50, "Photograph 50 PP Stickers"), (60, "Photograph 60 PP Stickers"),
        (70, "Photograph 70 PP Stickers"), (80, "Photograph 80 PP Stickers"),
        (90, "Photograph 90 PP Stickers"), (100, "Photograph all PP Stickers"),
    ]:
        world.set_rule(world.multiworld.get_location(_name, world.player),
                      AtLeast(_n, *_sticker_children))
    world.set_rule(world.multiworld.get_location("Get 10000 PP in one photo", world.player), CanReachRegion("Rooftop"))

    world.set_rule(world.multiworld.get_location("Find Greg's secret passage", world.player), CanReachLocation("Kill Adam"))
    # Endings
    # set_rule(self.multiworld.get_location("Ending B: Don't solve all of the cases but be on the helipad at 12pm", self.player), lambda state: state.can_reach_region("Heliport", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.has("DAY4_12_PM", self.player) and state.can_reach_location("Ending S: Beat up Brock with your bare fists!", self.player))
    # set_rule(self.multiworld.get_location("Ending C: Solve all of the cases but don't meet Isabela at 10am", self.player), lambda state: state.can_reach_location("Complete Memories", self.player) and state.can_reach_region("Heliport", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.has("DAY4_12_PM", self.player) and state.can_reach_location("Ending S: Beat up Brock with your bare fists!", self.player))
    # set_rule(self.multiworld.get_location("Ending D: Be a prisoner when time runs out", self.player), lambda state: state.can_reach_location("Witness Special Forces 10pm day 3", self.player) and state.can_reach_region("Heliport", self.player) and state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.has("DAY4_12_PM", self.player) and state.can_reach_location("Ending S: Beat up Brock with your bare fists!", self.player))
    # set_rule(self.multiworld.get_location("Ending E: Don't solve all of the cases and don't be on the helipad at 12pm", self.player), lambda state: state.has("DAY2_06_AM", self.player) and state.has("DAY2_11_AM", self.player) and state.has("DAY3_00_AM", self.player) and state.has("DAY3_11_AM", self.player) and state.has("DAY4_12_PM", self.player) and state.can_reach_location("Complete Backup for Brad", self.player) and state.can_reach_location("Ending S: Beat up Brock with your bare fists!", self.player))
    # set_rule(self.multiworld.get_location("Ending F: Fail to collect all of the bombs in time", self.player), lambda state: state.can_reach_location("Complete Bomb Collector", self.player))

    if not world.options.scoop_sanity:
        world.set_rule(world.multiworld.get_location("Survive until 7pm on day 1", world.player), CanReachRegion("Paradise Plaza"))


    # --------------------------------------------------------------------
    # PP bonus events
    # --------------------------------------------------------------------
    # PP-bonus rules (per-count for "counted" entries). Per-location rule
    # combines: required_regions (ALL reachable; first may be bypassed by
    # alt_item), requires_location (extra location gate, e.g. First Aid
    # Kit needs Steven), restricted_mode_items_any (in restricted
    # mode, requires ANY one of the listed items), and ep_shutter (the
    # entry sits behind Entrance Plaza's storefront shutters).
    if world.options.pp_bonus_locations:
        restricted_mode_on = bool(world.options.restricted_item_mode.value)

        def _make_rule(required_regions, alt_item, req_loc, items_any,
                       restricted_on=restricted_mode_on):
            parts = []
            # Region gating: ALL required regions must be reachable,
            # except the first can be bypassed by alt_item.
            if required_regions:
                first = CanReachRegion(required_regions[0])
                if alt_item:
                    first = Or(first, Has(alt_item))
                parts.append(first)
                parts.extend(CanReachRegion(r) for r in required_regions[1:])
            if req_loc:
                parts.append(CanReachLocation(req_loc))
            if restricted_on and items_any:
                parts.append(Or(*[Has(it) for it in items_any]))
            return And(*parts) if parts else True_()

        # Entries flagged ep_shutter sit inside Entrance Plaza's
        # storefronts, so reaching EP is not enough -- the shutter
        # cutscene has to have played.
        def _gate_on_shutter(inner):
            return And(ep_shutter, inner)

        for _entry in AP_TRIGGER_LOCATIONS:
            _names = expand_trigger_location_names(_entry)
            if not _names:
                continue
            _shuttered = bool(_entry.get("ep_shutter"))
            _alt_item = _entry.get("alt_item")
            _req_loc = _entry.get("requires_location")
            _items_any = _entry.get("restricted_mode_items_any") or []
            _t = _entry.get("type")
            _max = int(_entry.get("max_count", 0))

            # A required-predecessor location may not exist this seed
            # (e.g. Savior+ScoopSanity disables MAIN_SCOOP). Drop the gate
            # gracefully when missing; region gating still applies.
            if _req_loc:
                try:
                    world.multiworld.get_location(_req_loc, world.player)
                except KeyError:
                    _req_loc = None

            # Zone-counted entries (region_counts): "Use n X" is
            # reachable when the reachable zones' item counts sum to n.
            # required_regions (e.g. Seon's as the microwave food
            # source) are always needed, unless one of alt_items_any
            # has been received in their place (e.g. Raw Meat /
            # Uncooked Pizza stand in for the grocery store). These
            # locations live in Security Room so the parent region
            # never blocks a zone alternative -- the rule does all the
            # gating.
            _region_counts = _entry.get("region_counts")
            if _t == "counted" and _region_counts:
                _required = list(_entry.get("required_regions") or [])
                _required_alts = _entry.get("alt_items_any") or []

                def _make_count_rule(n, counts=_region_counts,
                                     required=_required,
                                     alts=_required_alts,
                                     req_loc=_req_loc,
                                     items_any=_items_any,
                                     restricted_on=restricted_mode_on):
                    parts = []
                    if required:
                        req = And(*[CanReachRegion(r) for r in required])
                        # Outside restricted mode an alt item substitutes
                        # for the required regions entirely.
                        if not restricted_on and alts:
                            req = Or(req, *[Has(it) for it in alts])
                        parts.append(req)
                    if req_loc:
                        parts.append(CanReachLocation(req_loc))
                    if restricted_on and items_any:
                        parts.append(Or(*[Has(it) for it in items_any]))
                    # Each region carries a count toward the target, so it
                    # is listed once per unit it is worth.
                    parts.append(AtLeast(n, *[CanReachRegion(r)
                                              for r, c in counts.items()
                                              for _ in range(c)]))
                    return And(*parts) if len(parts) > 1 else parts[0]

                _targets = [(_names[_i], _i + 1)
                            for _i in range(min(_max, len(_names)))]
                if len(_names) > _max:
                    _targets.append((_names[-1], sum(_region_counts.values())))
                for _name, _n in _targets:
                    try:
                        _loc = world.multiworld.get_location(_name, world.player)
                    except KeyError:
                        continue
                    _rule = _make_count_rule(_n)
                    if _shuttered:
                        _rule = _gate_on_shutter(_rule)
                    world.set_rule(_loc, _rule)
                continue

            # Build a list of (location_name, required_regions) tuples
            # so each location gets its own rule reflecting its tier.
            _per_loc: List[Any] = []
            if _t == "single":
                _regions = trigger_location_required_regions(_entry)
                for _name in _names:
                    _per_loc.append((_name, _regions))
            elif _t == "counted":
                # Per-count entries
                for _i, _name in enumerate(_names[:_max]):
                    _count = _i + 1
                    _regions = trigger_location_required_regions(
                        _entry, count=_count)
                    _per_loc.append((_name, _regions))
                # all-X variant uses the highest-tier regions
                if len(_names) > _max:
                    _all_regions = trigger_location_required_regions(
                        _entry, is_all_variant=True)
                    _per_loc.append((_names[-1], _all_regions))

            for _name, _regions in _per_loc:
                try:
                    _loc = world.multiworld.get_location(_name, world.player)
                except KeyError:
                    continue
                _rule = _make_rule(_regions, _alt_item, _req_loc, _items_any)
                if _shuttered:
                    _rule = _gate_on_shutter(_rule)
                world.set_rule(_loc, _rule)


    # --------------------------------------------------------------------
    # Goal and victory
    # --------------------------------------------------------------------
    # Victory condition based on goal
    goal_location_name = world.GOAL_LOCATIONS[world.options.goal.value]
    world.set_rule(world.multiworld.get_location("Victory", world.player),
                  CanReachLocation(goal_location_name))

    # Savior goal: the synthetic goal location is reachable once the
    # player can reach at least `number_of_survivors` "Rescue X" locations.
    # We capture the target in a local so the closure doesn't pay the
    # options-attribute-lookup cost on every rule evaluation.
    if world.options.goal.value == 2:
        savior_target = world.options.number_of_survivors.value
        savior_player = world.player
        savior_rescue_locations = list(world.ALL_RESCUE_LOCATIONS)

        savior_rule = AtLeast(savior_target,
                              *[CanReachLocation(l) for l in savior_rescue_locations])

        world.set_rule(world.multiworld.get_location(world.SAVIOR_GOAL_LOCATION, world.player),
                      savior_rule)

        # When main scoops are enabled under Savior, Ending A still exists
        # as filler — mark it excluded from progression so fill doesn't
        # place useful items there.
        # When main scoops are disabled (Savior+ScoopSanity), Ending A
        # isn't created at all, so there's nothing to mark.
        # Ending S is EVENT-category and skipped when it isn't the active
        # goal (see GOAL_ONLY_EVENT_LOCATIONS), so no handling needed.
        if world.main_scoops_enabled:
            world.multiworld.get_location(
                "Ending A: Solve all of the cases and be on the helipad at 12pm",
                world.player
            ).progress_type = LocationProgressType.EXCLUDED

    # Victory Condition
    world.set_completion_rule(Has("Victory"))
