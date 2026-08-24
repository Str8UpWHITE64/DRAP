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
    And, CanReachLocation, CanReachRegion, Has, HasAll, NestedRule, Or, Rule,
    True_,
)

from .DoorRandomization import AREA_NAMES, EMBEDDED_DOOR_DATA
from .Locations import (DRLocationCategory, location_tables,
                        ZOMBIE_KILL_REGION_OF, ZOMBIE_KILL_TIERS, SURVIVOR_MILESTONES)
from .shared_data import (
    AREA_KEY_NAMES,
    SCOOP_COMPLETION_MAP, SCOOP_EVENTS, SCOOP_REGION_REQUIREMENTS,
    SCOOP_SPLIT_KEY_DOORS as SPLIT_KEY_SCOOP_DOORS,
)


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

# How much of the mall has to be open before a kill threshold counts, in the
# same currency as the level gates below. 25 rather than 26 at the top: 26 is
# every region, and a region of slack keeps an awkward key placement from
# making a check unreachable.
KILL_POINT_GATES = {
    250: 10, 500: 13, 1000: 17, 2000: 22,
    5000: 23, 10000: 24, 15000: 25, 20000: 25, 28594: 25,
}

# The threshold at which an area starts wanting a weapon, and the one at which
# it also wants the Queen.
KILL_WEAPON_FROM = 500
KILL_QUEEN_FROM = 2000

# Car Keys only: the two areas with drivable vehicles want a key for one that
# is actually parked there once the counts get high. The thresholds differ
# because the areas do -- Leisure Park tops out at 10000 and the Tunnel at
# 28594, so the Tunnel can afford to start later.
#
# The convicts' Humvee is deliberately not listed even though it sits in
# Leisure Park: it only exists once the convicts have spawned and been killed,
# which under ScoopSanity waits on their scoop. Putting it here would let the
# fill assume a vehicle the player may not be able to reach yet.
KILL_CAR_FROM = {
    "Leisure Park": 1000,
    "Maintenance Tunnel": 2000,
}
KILL_CAR_KEYS = {
    "Leisure Park": ("Sports Car Key", "Motorcycle Key"),
    "Maintenance Tunnel": ("Sedan Key", "Truck Key"),
}

# Where each car is parked. A key on its own is not a car -- the player has to
# reach it -- and under Door Randomizer vehicles cannot be driven between
# areas, so pairing each key with its home region is correct either way. The
# convicts' Humvee is absent for the same reason it is absent above: it does
# not exist until they have been dealt with.
CAR_HOME = {
    "Sedan Key": "Maintenance Tunnel",
    "Truck Key": "Maintenance Tunnel",
    "Sports Car Key": "Leisure Park",
    "Motorcycle Key": "Leisure Park",
}

# Where an SMG can actually be picked up, confirmed in game. Leisure Park has
# none, so naming the item there on its own would ask for something the area
# cannot supply -- it has to be carried in from one of these.
SMG_AREAS = ("Al Fresca Plaza", "Entrance Plaza", "Paradise Plaza",
             "Food Court", "Maintenance Tunnel")


def _smg_from_elsewhere():
    """SMG plus any one area that stocks one, as separate alternatives.

    Alternatives are ORed and the entries within one are ANDed, so this reads
    as: have the SMG, and be able to reach somewhere it spawns.
    """
    return [["Submachine Gun", "region:" + area] for area in SMG_AREAS]


# Restricted Items only: something to kill with. Everywhere else these are on
# the floor for the taking, so the points above carry those seeds instead.
#
# Each area lists alternatives; an alternative is everything that must hold at
# once. A "loc:" entry is a location to reach, a "region:" entry an area to
# reach, anything else is an item.
KILL_WEAPONS = {
    "Paradise Plaza":        [["Katana"], ["Submachine Gun"],
                              ["Hunting Knife"], ["Handgun"]],
    # No Katana in Al Fresca, so the Sledgehammer stands in. It had to join
    # specialty_items first: those are what get the progression
    # classification here, and Has() sees nothing else.
    "Al Fresca Plaza":       [["Sledgehammer"], ["Submachine Gun"],
                              ["Hunting Knife"], ["Handgun"]],
    "Entrance Plaza":        [["Submachine Gun"], ["Hunting Knife"], ["Katana"]],
    "Food Court":            [["Submachine Gun"]],
    "Wonderland Plaza":      [["Hunting Knife"], ["Handgun"],
                              ["loc:Kill Adam", "Small Chainsaw"]],
    "North Plaza":           [["Katana"], ["Hunting Knife"], ["Shotgun"],
                              ["Handgun"]],
    # Leisure Park has no SMG of its own, so it needs the item AND somewhere
    # that stocks one. See SMG_AREAS. The Tunnel has one, so it just needs the
    # item. From 1000 and 2000 respectively both also want a car key -- that is
    # KILL_CAR_FROM below, stacked on top of this rather than replacing it.
    "Leisure Park":          _smg_from_elsewhere(),
    "Maintenance Tunnel":    [["Submachine Gun"]],
    "Seon's Food and Stuff": [["Hunting Knife", "Queen"]],
    "Crislip's Home Saloon": [["Fire Ax", "Queen"],
                              ["loc:Kill Cliff", "Machete"]],
    "Colby's Movieland":     [["Baseball Bat", "Queen"]],
}


def _kill_weapon_rule(region):
    """The weapon half of a kill rule, as an Or over the area's alternatives."""
    alternatives = []
    for spec in KILL_WEAPONS.get(region, []):
        parts = []
        for name in spec:
            if name.startswith("loc:"):
                parts.append(CanReachLocation(name[4:]))
            elif name.startswith("region:"):
                parts.append(CanReachRegion(name[7:]))
            else:
                parts.append(Has(name))
        alternatives.append(parts[0] if len(parts) == 1 else And(*parts))
    if not alternatives:
        return None
    return alternatives[0] if len(alternatives) == 1 else Or(*alternatives)


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

class AtLeast(NestedRule["DRWorld"], game="Dead Rising Deluxe Remaster"):
    """True when at least `count` of the child rules pass.

    Archipelago grew its own AtLeast after 0.6.7, so importing it would make
    the apworld refuse to load on every released version. This is the same
    rule, kept local until the released builder has one.

    Weighted counts are expressed by listing a child once per unit it is
    worth, so an encounter worth 3 psychopaths appears three times.
    """

    count: int

    def __init__(self, count, *children, **kwargs):
        super().__init__(*children, **kwargs)
        self.count = count

    def _instantiate(self, world) -> Rule.Resolved:
        if self.count <= 0:
            return True_().resolve(world)
        return self.Resolved(
            tuple(c.resolve(world) for c in self.children),
            count=self.count,
            player=world.player,
            caching_enabled=getattr(world, "rule_caching_enabled", False),
        )

    def to_dict(self):
        data = super().to_dict()
        data["count"] = self.count
        return data

    @classmethod
    def from_dict(cls, data, world_cls):
        children = [world_cls.rule_from_dict(c) for c in data.get("children", ())]
        return cls(data["count"], *children)

    class Resolved(NestedRule.Resolved):
        count: int

        def _evaluate(self, state) -> bool:
            hits = 0
            for child in self.children:
                if child(state):
                    hits += 1
                    if hits >= self.count:
                        return True
            return False

        def explain_json(self, state=None):
            if state is None:
                head = str(self.count)
            else:
                passing = sum(1 for c in self.children if c(state))
                head = f"{passing}/{self.count}"
            out = [{"type": "text", "text": "At least "},
                   {"type": "color", "color": "cyan", "text": head},
                   {"type": "text", "text": " of ("}]
            for i, child in enumerate(self.children):
                if i:
                    out.append({"type": "text", "text": ", "})
                out.extend(child.explain_json(state))
            out.append({"type": "text", "text": ")"})
            return out


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
    (2, ["Paradise Plaza"], ["Get grabbed by the raincoats"]),                    # Stickers 98-99
]

# Zones with a direct door into the Maintenance Tunnel. The Leisure Park
# ramp is separate -- it is the only tunnel entrance that never needs the
# Access Key (the physical copy is picked up inside the tunnels).
MAINTENANCE_TUNNEL_ZONES = [
    "Paradise Plaza", "Entrance Plaza", "Al Fresca Plaza",
    "Food Court", "Wonderland Plaza", "Seon's Food and Stuff",
]


# ---------------------------------------------------------------------------
# Psycho goal
# ---------------------------------------------------------------------------
# Psycho replaces every "Rescue <name>" check with "Kill <name>". The access
# rule is the same either way -- both need you to reach the survivor -- so the
# rules below are written once and land on whichever check this seed has.
#
# Deliberately conservative: a kill does not need the escort route a rescue
# needs (Greg's split key, for one), so a few kills are gated later than they
# strictly must be. That costs placement freedom, never winnability.
def _survivor_name(world, rescue_name):
    if getattr(world, "psycho_mode", False):
        return "Kill " + rescue_name[len("Rescue "):]
    return rescue_name


def _survivor_location(world, rescue_name):
    return world.multiworld.get_location(_survivor_name(world, rescue_name),
                                         world.player)


def set_rules(world) -> None:

    # Locations this seed never created. Spitter Only drops every check that
    # needs something in Frank's hands, so their rules have nothing to attach
    # to -- each site below asks this rather than looking the location up and
    # failing.
    _dropped = (world.SPITTER_EXCLUDED_LOCATIONS if world.spitter_only
                else frozenset())

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
    # Under ScoopSanity the trigger spot always answers, whoever leads. It is
    # only held shut while Backup for Brad is running, and that scoop cannot
    # start until the Food Court and Entrance Plaza are reachable -- which is
    # exactly what completing it needs. So either the trigger opens them or
    # the mission can be finished.
    if not world.options.scoop_sanity:
        _shutter = CanReachLocation("Escort Brad to see Dr Barnaby")
    else:
        # Meeting Jessie by name, not Warehouse reach. The trigger spot only
        # answers once AP is activated, which is that milestone; reaching the
        # Warehouse merely coincides with it during the prologue. The scoop
        # loop already words the same condition this way.
        _shutter = CanReachLocation("Meet Jessie in the Warehouse")
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
    # The Leisure Park <-> Maintenance Tunnel ramp, named because the Car Keys
    # rules need the same door: it is the only route a vehicle can take
    # between those two, so reaching either by another door proves nothing.
    # Free until the door rules below say otherwise.
    _ramp_to_tunnel = True_()
    _ramp_to_park = True_()

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
        world.set_rule(world.multiworld.get_entrance("Maintenance Tunnel -> Meat Processing Area", world.player),
                      _door("Meat Processing Area Key", "Maintenance Tunnel - Meat Processing Area Key"))
        _ramp_to_tunnel = _door("Maintenance Tunnel Key", "Leisure Park - Maintenance Tunnel Key")
        world.set_rule(world.multiworld.get_entrance("Leisure Park -> Maintenance Tunnel", world.player),
                      _ramp_to_tunnel)
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
        _ramp_to_park = _door("Leisure Park Key", "Leisure Park - Maintenance Tunnel Key")
        world.set_rule(world.multiworld.get_entrance("Maintenance Tunnel -> Leisure Park", world.player),
                      _ramp_to_park)

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

    elif world.door_locks_active:
        # Door Locks. The shuffle moves where a door leads, so the door has no
        # fixed identity left to hang a key on -- but the area it lands in
        # does. Every way into a keyed area needs that area's key, whichever
        # door the player walked through to get there.
        _keyed = set(AREA_KEY_NAMES)

        def _dest_key(region_name, also=None):
            _rule = Has(f"{region_name} Key") if f"{region_name} Key" in _keyed else True_()
            return And(_rule, also) if also is not None else _rule

        for _entrance in world.multiworld.get_entrances(world.player):
            if _entrance.connected_region:
                world.set_rule(_entrance, _dest_key(_entrance.connected_region.name))

        # Greg's passage isn't in the door table, so the shuffle leaves it
        # where it is and it keeps its scoop gate.
        for _from, _to in (("Paradise Plaza", "Wonderland Plaza"),
                           ("Wonderland Plaza", "Paradise Plaza")):
            world.set_rule(world.multiworld.get_entrance(f"{_from} -> {_to}", world.player),
                          _dest_key(_to, CanReachLocation("Kill Adam")))

        # The Security Room <-> Entrance Plaza doors are barricaded until the
        # Jessie cutscene plays, and under ScoopSanity they are the only way
        # out of the safe room besides the Rooftop stairs. The shuffle changes
        # where they lead, not when they open, so the gate travels with the
        # door to wherever it landed -- without it the fill will happily put
        # the Warehouse Key behind a door that only Jessie opens, and Jessie
        # is in the Warehouse.
        #
        # Gating both ends can catch a pair some ordinary door also joins, but
        # the mall is only enterable through the Warehouse, so Jessie is always
        # reachable by the time that matters and the extra gate never binds.
        # Under-gating deadlocks the seed; over-gating costs nothing.
        if world.options.scoop_sanity:
            for _id, _door in EMBEDDED_DOOR_DATA.items():
                _src = AREA_NAMES.get(_door.get("from_area_code"))
                if {_src, AREA_NAMES.get(_door.get("to_area_code"))} != \
                        {"Security Room", "Entrance Plaza"}:
                    continue
                _redirect = world.door_redirects.get(_id)
                _dst = AREA_NAMES.get((_redirect or {}).get("target_area")
                                      or _door.get("to_area_code"))
                if not _dst or _dst == _src:
                    continue
                for _a, _b in ((_src, _dst), (_dst, _src)):
                    world.set_rule(world.multiworld.get_entrance(f"{_a} -> {_b}", world.player),
                                  _dest_key(_b, CanReachLocation("Meet Jessie in the Warehouse")))


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

    # Zombie kill checks. They sit in their own region, so every one needs its
    # rule spelled out -- see the note in Locations.py.
    #
    # Every one asks for its area, Entrance Plaza's smallest included. Those
    # two used to be free, on the grounds that the prologue puts the player
    # there without a key -- but that made them sphere 0, so a new player
    # cleared them in the opening without ever knowing the checks existed.
    for _kill_name, _kill_region in ZOMBIE_KILL_REGION_OF.items():
        try:
            _kill_loc = world.multiworld.get_location(_kill_name, world.player)
        except KeyError:
            continue        # not created at this tier
        _threshold = int(re.match(r"Kill (\d+) ", _kill_name).group(1))

        _parts = [CanReachRegion(_kill_region)]

        # Applies in both item modes: it is about progress through the run,
        # not about pickups.
        _points = KILL_POINT_GATES.get(_threshold)
        if _points:
            _parts.append(RegionPointsAtLeast(_points))

        # A car for the areas that have one, once the count is past what is
        # reasonable on foot. Independent of item mode.
        if world.options.car_keys:
            _car_from = KILL_CAR_FROM.get(_kill_region)
            if _car_from is not None and _threshold >= _car_from:
                _parts.append(Or(*[Has(k)
                                   for k in KILL_CAR_KEYS[_kill_region]]))

        # Something to kill with, and the Queen on top from 2000.
        #
        # Spitter Only skips the weapon half -- the spit is always to hand, so
        # the threshold rests on how much of the mall is open instead. Grinding
        # a thousand zombies that way is slow, which suits the mode. The Queen
        # is still in the pool and still required.
        if world.options.restricted_item_mode and _threshold >= KILL_WEAPON_FROM:
            if not world.spitter_only:
                _weapon = _kill_weapon_rule(_kill_region)
                if _weapon is not None:
                    _parts.append(_weapon)
            if _threshold >= KILL_QUEEN_FROM:
                _parts.append(Has("Queen"))

        world.set_rule(_kill_loc,
                       _parts[0] if len(_parts) == 1 else And(*_parts))

    # Zombie Genocider: the top threshold in every area, which is the same
    # 53,594 kills as clearing all 92 checks and eleven rules instead of 92.
    if world.options.goal.value == 3:
        _tops = [
            CanReachLocation(f"Kill {max(_tiers['genocide'])} zombies in {_region}")
            for _region, _tiers in ZOMBIE_KILL_TIERS.items()
        ]
        world.set_rule(
            world.multiworld.get_location(
                "Zombie Genocider: Kill 53,594 zombies across the mall",
                world.player),
            And(*_tops))

    # Exclude Rescues Above code
    rescue_threshold = world.options.exclude_rescues_above.value

    # 48 is every survivor in the mall, so it excludes nothing -- which is how
    # the slider turns itself off, and why there is no separate toggle.
    if rescue_threshold < 48:
        for location in world.multiworld.get_locations(world.player):
            match = re.fullmatch(r"Rescue (\d+) survivors", location.name)
            if match and int(match.group(1)) > rescue_threshold:
                location.progress_type = LocationProgressType.EXCLUDED

    # Exclude Levels Above code
    threshold = world.options.exclude_levels_above.value

    # 50 is max level, so it excludes nothing -- the slider's own off switch.
    if threshold < 50:
        for location in world.multiworld.get_locations(world.player):
            name = location.name
            match = re.match(r"Reach Level (\d+)", name)

            if match:
                # re.match ignores the suffix, so this covers the plain
                # "Reach Level 12" and the "Reach Level 20!" achievement
                # milestones in one pass.
                if int(match.group(1)) > threshold:
                    location.progress_type = LocationProgressType.EXCLUDED

            elif name == "Reach max level":
                # Level 50 under a name with no digits in it, so it never
                # matched the regex. It used to sit inside the branch above
                # and could not be reached at all, which left it collectable
                # at every threshold. The outer guard is already threshold<50.
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

            # The five bombs are collected during the same run through the
            # tunnel, so they share Bomb Collector's own prerequisite rather
            # than chaining off it -- gating them behind its completion would
            # put them a sphere later than they are actually reachable.
            world.set_rule(world.multiworld.get_location("Bomb Collector - Entrance Plaza Truck", world.player), And(CanReachLocation("Meet back at the Security Room at 11am day 3"), CanReachRegion("Maintenance Tunnel")))
            world.set_rule(world.multiworld.get_location("Bomb Collector - North Plaza Truck", world.player), And(CanReachLocation("Meet back at the Security Room at 11am day 3"), CanReachRegion("Maintenance Tunnel")))
            world.set_rule(world.multiworld.get_location("Bomb Collector - Al Fresca Plaza Truck", world.player), And(CanReachLocation("Meet back at the Security Room at 11am day 3"), CanReachRegion("Maintenance Tunnel")))
            world.set_rule(world.multiworld.get_location("Bomb Collector - Wonderland Plaza Truck", world.player), And(CanReachLocation("Meet back at the Security Room at 11am day 3"), CanReachRegion("Maintenance Tunnel")))
            world.set_rule(world.multiworld.get_location("Bomb Collector - Seon's Food and Stuff Truck", world.player), And(CanReachLocation("Meet back at the Security Room at 11am day 3"), CanReachRegion("Maintenance Tunnel")))

            world.set_rule(world.multiworld.get_location("Beat Drivin Carlito", world.player), And(CanReachLocation("Complete Bomb Collector"), CanReachRegion("Maintenance Tunnel")))

            world.set_rule(world.multiworld.get_location("Meet back at the Security Room at 5pm day 3", world.player), Or(CanReachLocation("Complete Bomb Collector"), CanReachLocation("Beat Drivin Carlito")))

            world.set_rule(world.multiworld.get_location("Escort Isabela to Carlito's Hideout and have a chat", world.player),
                          And(CanReachLocation("Meet back at the Security Room at 5pm day 3"),
                              CanReachRegion("Carlito's Hideout"),
                              And(Has("Paradise Plaza - Warehouse Key"), Has("Leisure Park - Paradise Plaza Key"), Has("Leisure Park - North Plaza Key"), Has("Carlito's Hideout - North Plaza Key")) if world.options.split_keys else True_()))

        if world.options.scoop_sanity:
            world.multiworld.get_location("Beat Drivin Carlito", world.player).progress_type = LocationProgressType.EXCLUDED

            _survivor_location(world, "Rescue Greg Simpson").progress_type = LocationProgressType.EXCLUDED

        world.set_rule(world.multiworld.get_location("Complete Jessie's Discovery", world.player), CanReachLocation("Escort Isabela to Carlito's Hideout and have a chat"))

        world.set_rule(world.multiworld.get_location("Meet Larry", world.player), And(CanReachLocation("Complete Jessie's Discovery"), CanReachRegion("Meat Processing Area")))

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
        # Overtime Progression Gating decides whether any of this sits behind
        # an item. With it off every check still exists -- nothing holds them.
        _gating = bool(world.options.overtime_progression_gating.value)

        world.set_rule(world.multiworld.get_location("Get bit!", world.player), CanReachLocation("Ending A: Solve all of the cases and be on the helipad at 12pm"))

        # Where each ingredient actually is. The items were removed, so this is
        # what ties a hand-in to having been somewhere to pick it up -- Has()
        # used to do that job.
        _where = {
            "Blender": Or(CanReachRegion("Food Court"),
                          CanReachRegion("Al Fresca Plaza"),
                          CanReachRegion("Paradise Plaza")),
            "First Aid Kit": CanReachRegion("Seon's Food and Stuff"),
            "Coffee Filters": CanReachRegion("Security Room"),
            "Magnifying Glass": CanReachRegion("Wonderland Plaza"),
            "Camp Stove": CanReachRegion("Entrance Plaza"),
            "Perfume Bottle": CanReachRegion("Entrance Plaza"),
            "Developing Solution": CanReachRegion("Paradise Plaza"),
            "Cold Spray": CanReachRegion("Paradise Plaza"),
        }
        for _name, _where_rule in _where.items():
            world.set_rule(
                world.multiworld.get_location(f"Find the {_name}", world.player),
                And(CanReachLocation("Get bit!"), _where_rule))
            world.set_rule(
                world.multiworld.get_location(f"Give Isabela the {_name}",
                                              world.player),
                And(CanReachLocation("Get bit!"),
                    CanReachRegion("Carlito's Hideout"), _where_rule))


        # The mission needs all eight ingredients, and each is reachable
        # exactly when its own hand-in is.
        world.set_rule(world.multiworld.get_location("Scramble for a Suppressant", world.player),
                       And(*[CanReachLocation(f"Give Isabela the {_n}")
                             for _n in _where]))

        world.set_rule(world.multiworld.get_location("See the crashed helicopter", world.player), And(CanReachRegion("Leisure Park"), CanReachLocation("Get bit!")))
        world.set_rule(world.multiworld.get_location("Hella Copter - Shoot down the Special Forces Helicopter", world.player), CanReachLocation("See the crashed helicopter"))

        world.set_rule(world.multiworld.get_location("Frank sees a sick-ass RC Drone", world.player), CanReachLocation("Get bit!"))

        # She accepts them one at a time, so each hand-in is its own check
        # -- gated on the item, because the mod holds the pickup until then.
        world.set_rule(world.multiworld.get_location("Give Isabela the Generator", world.player), And(CanReachLocation("Scramble for a Suppressant"), CanReachRegion("Carlito's Hideout"), CanReachLocation("See the crashed helicopter")))

        # Queens are handed over after the serum is made.
        _needs_queen = (world.options.restricted_item_mode
                        or world.options.scoop_sanity)
        world.set_rule(world.multiworld.get_location("Give Isabela 1 Queen", world.player), And(CanReachLocation("Scramble for a Suppressant"), CanReachRegion("Carlito's Hideout"), Has("Queen") if _needs_queen else True_()))
        world.set_rule(world.multiworld.get_location("Give Isabela 2 Queens", world.player), And(CanReachLocation("Scramble for a Suppressant"), CanReachRegion("Carlito's Hideout"), Has("Queen") if _needs_queen else True_()))
        world.set_rule(world.multiworld.get_location("Give Isabela 3 Queens", world.player), And(CanReachLocation("Scramble for a Suppressant"), CanReachRegion("Carlito's Hideout"), Has("Queen") if _needs_queen else True_()))
        world.set_rule(world.multiworld.get_location("Give Isabela 4 Queens", world.player), And(CanReachLocation("Scramble for a Suppressant"), CanReachRegion("Carlito's Hideout"), Has("Queen") if _needs_queen else True_()))
        world.set_rule(world.multiworld.get_location("Honey Hunt", world.player), And(CanReachLocation("Scramble for a Suppressant"), Has("Queen") if _needs_queen else True_()))

        world.set_rule(world.multiworld.get_location("Proceed through the cave with Isabela", world.player), CanReachLocation("Honey Hunt"))

        # Isabela refuses to leave without the key, so the tunnel is behind it
        # however the player got to her.
        if _gating:
            for _entrance in ("Carlito's Hideout -> Clock Tower Tunnel",
                              "Leisure Park -> Clock Tower Tunnel"):
                world.set_rule(world.multiworld.get_entrance(_entrance, world.player),
                              Has("Clock Tower Tunnel Key"))

        # The tunnel in the order it is walked: Isabela crawls through the first
        # gate, opens the second, then the lever raises the last one.
        world.set_rule(world.multiworld.get_location("Open Gate 1", world.player), CanReachLocation("Proceed through the cave with Isabela"))
        world.set_rule(world.multiworld.get_location("Open Gate 2", world.player), CanReachLocation("Open Gate 1"))
        world.set_rule(world.multiworld.get_location("Raise the final gate", world.player), CanReachLocation("Open Gate 2"))

        world.set_rule(world.multiworld.get_location("Get to the Humvee", world.player), And(Has("Humvee Key") if _gating else True_(), CanReachLocation("Raise the final gate"), CanReachRegion("Clock Tower Tunnel")))

        world.set_rule(world.multiworld.get_location("Fight a tank and win", world.player), CanReachLocation("Get to the Humvee"))

        world.set_rule(world.multiworld.get_location("Ending S: Beat up Brock with your bare fists!", world.player), CanReachLocation("Fight a tank and win"))

        world.set_rule(world.multiworld.get_location("Kill 10 Special Forces", world.player), And(CanReachRegion("Paradise Plaza"), Has("DAY3_11_AM"), CanReachLocation("Get bit!"), CanReachLocation("Ending A: Solve all of the cases and be on the helipad at 12pm")))


    # ScoopSanity: gate every event of every scoop uniformly on item
    # received, previous scoop's completion, scoop regions, and the
    # position-level gate. Replaces the vanilla event-to-event chain so
    # randomized order can't strand events behind the vanilla predecessor.
    # Day items aren't checked -- the engine sets time flags on chain advance.
    if world.options.scoop_sanity and world.scoop_order:
        for i, scoop_name in enumerate(world.scoop_order):
            # Any Order drops the chain link: every scoop answers only to
            # meeting Jessie, its own item, its regions and its level gate.
            if world.options.main_scoops_any_order or i == 0:
                prereq = "Meet Jessie in the Warehouse"
            else:
                prereq = SCOOP_COMPLETION_MAP[world.scoop_order[i - 1]]
            regions = SCOOP_REGION_REQUIREMENTS.get(scoop_name, [])
            # The level gates spread a CHAIN across spheres. Choosing the order
            # already does that, and the mod does not enforce them, so keeping
            # them would only put scoops in logic the player can already start.
            level_req = None
            if not world.options.main_scoops_any_order:
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

        # Complete Memories is the post-chain anchor. In a chain, finishing the
        # last scoop proves every earlier one is done, so it gates on that
        # alone. Any Order breaks that implication -- the last-placed scoop can
        # be taken first -- so there it has to name all of them.
        if world.options.main_scoops_any_order:
            _memories = And(*[CanReachLocation(SCOOP_COMPLETION_MAP[s])
                              for s in world.scoop_order])
        else:
            _memories = CanReachLocation(
                SCOOP_COMPLETION_MAP[world.scoop_order[-1]])
        world.set_rule(world.multiworld.get_location("Complete Memories", world.player),
                      _memories)


    # --------------------------------------------------------------------
    # Survivors
    # --------------------------------------------------------------------
    # Survivors in Rooftop
    world.set_rule(_survivor_location(world, "Rescue Jeff Meyer"), CanReachRegion("Rooftop"))
    world.set_rule(_survivor_location(world, "Rescue Natalie Meyer"), CanReachRegion("Rooftop"))

    # Survivors in Paradise Plaza
    world.set_rule(_survivor_location(world, "Rescue Heather Tompkins"), And(CanReachRegion("Paradise Plaza"), (Has("Twin Sisters") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), CanReachLocation(_survivor_name(world, "Rescue Ross Folk")), CanReachLocation(_survivor_name(world, "Rescue Tonya Waters"))))))
    world.set_rule(_survivor_location(world, "Rescue Pamela Tompkins"), And(CanReachRegion("Paradise Plaza"), (Has("Twin Sisters") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), CanReachLocation(_survivor_name(world, "Rescue Ross Folk")), CanReachLocation(_survivor_name(world, "Rescue Tonya Waters"))))))
    world.set_rule(_survivor_location(world, "Rescue Ronald Shiner"), And(CanReachRegion("Paradise Plaza"), (Has("Orange Juice") if world.options.restricted_item_mode else True_()), (Has("Restaurant Man") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
    world.set_rule(_survivor_location(world, "Rescue Jennifer Gorman"), And(CanReachRegion("Paradise Plaza"), (Has("The Cult") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
    world.set_rule(_survivor_location(world, "Rescue Tad Hawthorne"), And(CanReachRegion("Paradise Plaza"), CanReachLocation("Kill Kent on day 3"), (Has("Photographer's Pride") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), Has("DAY3_11_AM")))))
    world.set_rule(_survivor_location(world, "Rescue Simone Ravendark"), And(CanReachRegion("Paradise Plaza"), (Has("A Woman in Despair") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), Has("DAY3_11_AM"), CanReachLocation("Complete Santa Cabeza")))))
    ## 1.1.0 HAS A BUG WITH "Rescue Simone Ravendark", THIS NEXT LINE EXCLUDES THIS CHECK IN ALL PLAY MODES AND SHOULD BE REMOVED UPON FIX BEING IMPLEMENTED
    _survivor_location(world, "Rescue Simone Ravendark").progress_type = LocationProgressType.EXCLUDED

    # Survivors in Leisure Park
    world.set_rule(_survivor_location(world, "Rescue Sophie Richard"), And(CanReachRegion("Leisure Park"), (Has("The Convicts") if world.options.scoop_sanity else True_())))

    # Survivors in Food Court
    world.set_rule(_survivor_location(world, "Rescue Gil Jiminez"), And(CanReachRegion("Food Court"), (Has("The Drunkard") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))))

    # Survivors in Al Fresca Plaza
    world.set_rule(_survivor_location(world, "Rescue Aaron Swoop"), And(CanReachRegion("Al Fresca Plaza"), (Has("Barricade Pair") if world.options.scoop_sanity else True_())))
    world.set_rule(_survivor_location(world, "Rescue Burt Thompson"), And(CanReachRegion("Al Fresca Plaza"), (Has("Barricade Pair") if world.options.scoop_sanity else True_())))
    world.set_rule(_survivor_location(world, "Rescue Leah Stein"), And(CanReachRegion("Al Fresca Plaza"), (Has("A Mother's Lament") if world.options.scoop_sanity else True_())))
    world.set_rule(_survivor_location(world, "Rescue Gordon Stalworth"), And(CanReachRegion("Al Fresca Plaza"), (Has("The Coward") if world.options.scoop_sanity else Has("DAY2_06_AM"))))

    # Survivors in Entrance Plaza
    world.set_rule(_survivor_location(world, "Rescue Bill Brenton"), ep_shutter)
    world.set_rule(_survivor_location(world, "Rescue Wayne Blackwell"), And(ep_shutter, (Has("Mark of the Sniper") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), CanReachLocation("Meet the Hall Family")))))
    world.set_rule(_survivor_location(world, "Rescue Jolie Wu"), And(ep_shutter, (Has("The Woman Who Didn't Make it") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
    world.set_rule(_survivor_location(world, "Rescue Rachel Decker"), And(ep_shutter, (Has("The Woman Who Didn't Make it") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
    world.set_rule(_survivor_location(world, "Rescue Floyd Sanders"), And(ep_shutter, (Has("Antique Lover") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))

    # Survivors in Wonderland Plaza
    # Greg is the one Wonderland survivor with extra logic: he opens the
    # passage. Under Split Keys the door has its own key, and without it he
    # will not join -- reaching both areas by another route is not enough.
    world.set_rule(_survivor_location(world, "Rescue Greg Simpson"), And(CanReachRegion("Wonderland Plaza"), CanReachRegion("Paradise Plaza"), (Has("Out of Control") if world.options.scoop_sanity else True_()), (Has("Paradise Plaza - Wonderland Plaza Key") if world.options.split_keys else True_())))
    world.set_rule(_survivor_location(world, "Rescue Yuu Tanaka"), And(CanReachRegion("Wonderland Plaza"), (Has("Book [Japanese Conversation]") if world.options.restricted_item_mode else True_()), (Has("Japanese Tourists") if world.options.scoop_sanity else True_())))
    world.set_rule(_survivor_location(world, "Rescue Shinji Kitano"), And(CanReachRegion("Wonderland Plaza"), (Has("Book [Japanese Conversation]") if world.options.restricted_item_mode else True_()), (Has("Japanese Tourists") if world.options.scoop_sanity else True_())))
    world.set_rule(_survivor_location(world, "Rescue Tonya Waters"), And(CanReachRegion("Wonderland Plaza"), (Has("Lovers") if world.options.scoop_sanity else Has("DAY2_06_AM"))))
    world.set_rule(_survivor_location(world, "Rescue Ross Folk"), And(CanReachRegion("Wonderland Plaza"), (Has("Lovers") if world.options.scoop_sanity else Has("DAY2_06_AM"))))
    world.set_rule(_survivor_location(world, "Rescue Kay Nelson"), And(CanReachRegion("Wonderland Plaza"), (Has("Above the Law") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), CanReachLocation("Kill Jo")))))
    world.set_rule(_survivor_location(world, "Rescue Lilly Deacon"), And(CanReachRegion("Wonderland Plaza"), (Has("Above the Law") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), CanReachLocation("Kill Jo")))))
    world.set_rule(_survivor_location(world, "Rescue Kelly Carpenter"), And(CanReachRegion("Wonderland Plaza"), (Has("Above the Law") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), CanReachLocation("Kill Jo")))))
    world.set_rule(_survivor_location(world, "Rescue Janet Star"), And(CanReachRegion("Wonderland Plaza"), (Has("Above the Law") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), CanReachLocation("Kill Jo")))))
    world.set_rule(_survivor_location(world, "Rescue Sally Mills"), And(CanReachRegion("Wonderland Plaza"), (Has("Hanging by a Thread") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
    world.set_rule(_survivor_location(world, "Rescue Nick Evans"), And(CanReachRegion("Wonderland Plaza"), (Has("Hanging by a Thread") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
    world.set_rule(_survivor_location(world, "Rescue Mindy Baker"), And(CanReachRegion("Wonderland Plaza"), (Has("Long Haired Punk") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), CanReachLocation("Defeat Paul")))))
    world.set_rule(_survivor_location(world, "Rescue Debbie Willet"), And(CanReachRegion("Wonderland Plaza"), (Has("Long Haired Punk") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), CanReachLocation("Defeat Paul")))))
    if _survivor_name(world, "Rescue Paul Carson") not in _dropped:
        world.set_rule(_survivor_location(world, "Rescue Paul Carson"), And(CanReachRegion("Wonderland Plaza"), (Has("Fire Extinguisher") if world.options.restricted_item_mode and not world.spitter_only else True_()), (Has("Long Haired Punk") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), CanReachLocation("Defeat Paul")))))
    world.set_rule(_survivor_location(world, "Rescue Leroy McKenna"), And(CanReachRegion("Wonderland Plaza"), (Has("A Sick Man") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))))
    world.set_rule(_survivor_location(world, "Rescue Susan Walsh"), And(CanReachRegion("Wonderland Plaza"), (Has("The Woman Left Behind") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))))

    # Survivors in North Plaza
    world.set_rule(_survivor_location(world, "Rescue David Bailey"), And(CanReachRegion("North Plaza"), (Has("Shadow of the North Plaza") if world.options.scoop_sanity else True_())))
    world.set_rule(_survivor_location(world, "Rescue Kindell Johnson"), And(CanReachRegion("North Plaza"), (Has("Dressed for Action") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))))
    world.set_rule(_survivor_location(world, "Rescue Brett Styles"), And(CanReachRegion("North Plaza"), (Has("Gun Shop Standoff") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))))
    world.set_rule(_survivor_location(world, "Rescue Jonathan Picardson"), And(CanReachRegion("North Plaza"), (Has("Gun Shop Standoff") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))))
    world.set_rule(_survivor_location(world, "Rescue Alyssa Laurent"), And(CanReachRegion("North Plaza"), (Has("Gun Shop Standoff") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))))

    # Survivors locked behind Hatchet Man (requires both North Plaza and Crislip's Home Saloon)
    world.set_rule(_survivor_location(world, "Rescue Josh Manning"), And(CanReachRegion("North Plaza"), CanReachRegion("Crislip's Home Saloon"), (Has("The Hatchet Man") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), CanReachLocation("Kill Cliff")))))
    world.set_rule(_survivor_location(world, "Rescue Barbara Patterson"), And(CanReachRegion("North Plaza"), CanReachRegion("Crislip's Home Saloon"), (Has("The Hatchet Man") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), CanReachLocation("Kill Cliff")))))
    world.set_rule(_survivor_location(world, "Rescue Rich Atkins"), And(CanReachRegion("North Plaza"), CanReachRegion("Crislip's Home Saloon"), (Has("The Hatchet Man") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), CanReachLocation("Kill Cliff")))))

    # Survivors in Colby's Movieland
    world.set_rule(_survivor_location(world, "Rescue Beth Shrake"), And(CanReachRegion("Colby's Movieland"), (Has("A Strange Group") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), CanReachLocation("Kill Sean")))))
    world.set_rule(_survivor_location(world, "Rescue Michelle Feltz"), And(CanReachRegion("Colby's Movieland"), (Has("A Strange Group") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), CanReachLocation("Kill Sean")))))
    world.set_rule(_survivor_location(world, "Rescue Nathan Crabbe"), And(CanReachRegion("Colby's Movieland"), (Has("A Strange Group") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), CanReachLocation("Kill Sean")))))
    world.set_rule(_survivor_location(world, "Rescue Ray Mathison"), And(CanReachRegion("Colby's Movieland"), (Has("A Strange Group") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), CanReachLocation("Kill Sean")))))
    world.set_rule(_survivor_location(world, "Rescue Cheryl Jones"), And(CanReachRegion("Colby's Movieland"), (Has("A Strange Group") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), CanReachLocation("Kill Sean")))))

    # These survivor-count milestones are gated behind nearly every
    # late-game scoop, so they only become reachable once most of the
    # progression chain is already solved -- a poor place for progression
    # or useful items, since they'd effectively be locked behind the rest
    # of the run. Mark them filler-only.
    for _name in (
        "Get 50 survivors to join",
        "Encounter 10 survivors",
        "Encounter 50 survivors",
    ):
        # "Get 50 survivors to join" does not exist under Psycho -- nobody
        # joins a psychopath -- so ask rather than assume.
        if _name in world.PSYCHO_EXCLUDED_LOCATIONS and world.psycho_mode:
            continue
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
    world.set_rule(world.multiworld.get_location("Kill the convicts", world.player), CanReachLocation("Watch the convicts kill that poor guy"))

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
    world.set_rule(world.multiworld.get_location("Get grabbed by the raincoats", world.player), CanReachLocation("Witness Sean in Paradise Plaza"))
    world.set_rule(world.multiworld.get_location("Meet Sean", world.player), And(CanReachRegion("Colby's Movieland"), (Has("A Strange Group") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))))
    world.set_rule(world.multiworld.get_location("Kill Sean", world.player), CanReachLocation("Meet Sean"))

    world.set_rule(world.multiworld.get_location("Meet Paul", world.player), And(CanReachRegion("Wonderland Plaza"), (Has("Long Haired Punk") if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))))
    world.set_rule(world.multiworld.get_location("Defeat Paul", world.player), CanReachLocation("Meet Paul"))

    # Kent's three days are INDEPENDENT under ScoopSanity. KentChain arms each
    # day's measured start set and clears the other days' residue, so any order
    # works in game -- each location needs only its OWN scoop item and Paradise
    # Plaza. Without ScoopSanity the vanilla schedule applies, so the days stay
    # chained on each other and on their time keys.
    world.set_rule(world.multiworld.get_location("Meet Kent on day 1", world.player), And(CanReachRegion("Paradise Plaza"), (Has("Cut from the Same Cloth") if world.options.scoop_sanity else True_())))
    world.set_rule(world.multiworld.get_location("Complete Kent's day 1 photoshoot", world.player), CanReachLocation("Meet Kent on day 1"))
    if "Meet Kent on day 2" not in _dropped:
        world.set_rule(world.multiworld.get_location("Meet Kent on day 2", world.player), And(CanReachRegion("Paradise Plaza"), (Or(Has("Novelty Mask (Bear)"), Has("Novelty Mask (Servbot)"), Has("Novelty Mask (Horse)")) if world.options.restricted_item_mode else True_()), (Has("Photo Challenge") if world.options.scoop_sanity else And(CanReachLocation("Complete Kent's day 1 photoshoot"), Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
        world.set_rule(world.multiworld.get_location("Complete Kent's day 2 photoshoot", world.player), CanReachLocation("Meet Kent on day 2"))
    world.set_rule(world.multiworld.get_location("Meet Kent on day 3", world.player), And(CanReachRegion("Paradise Plaza"), (Has("Photographer's Pride") if world.options.scoop_sanity else And(CanReachLocation("Complete Kent's day 2 photoshoot"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), Has("DAY3_11_AM")))))
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
    # Kill 100 zombies with an RPG. The blender turns a Mega Buster and a Fire
    # Extinguisher into one long before Overtime, which is why this is a
    # Challenge rather than an Overtime check -- every goal can reach it.
    #
    # Obtaining an ingredient differs by mode: without Restricted you can pick
    # one off the floor, so being sent it OR being able to walk to it is
    # enough. Restricted can only use what it was sent, and still has to go
    # and collect it, so it needs both.
    _restricted = bool(world.options.restricted_item_mode)

    # Every area a fire extinguisher is confirmed to stay in. NOT the
    # Warehouse: the one Frank drops in the Jessie cutscene despawns early in
    # the run, so a rule leaning on it promises something that is not there.
    FIRE_EXTINGUISHER_AREAS = ("Al Fresca Plaza", "Food Court",
                               "Crislip's Home Saloon",
                               "Seon's Food and Stuff", "Wonderland Plaza")

    def _obtainable(item_name, *regions):
        if len(regions) > 1:
            somewhere = Or(*[CanReachRegion(r) for r in regions])
        else:
            somewhere = CanReachRegion(regions[0])
        if _restricted:
            return And(Has(item_name), somewhere)
        return Or(Has(item_name), somewhere)

    _rpg_blend = [
        _obtainable("Mega Buster", "Colby's Movieland"),
        _obtainable("Fire Extinguisher", *FIRE_EXTINGUISHER_AREAS),
        Has("Book [Blender]"),
    ]
    # Restricted cannot pick the blender's output up either.
    if _restricted:
        _rpg_blend.append(Has("Rocket Launcher"))
    _rpg_rule = And(*_rpg_blend)

    if world.options.goal.value == 0:
        # Overtime is the other way to find one -- Ending S only, and naming
        # "Get bit!" on any other goal would not resolve.
        _rpg_ot = [CanReachLocation("Get bit!")]
        if _restricted:
            _rpg_ot.append(Has("Rocket Launcher"))
        _rpg_rule = Or(_rpg_rule, And(*_rpg_ot))

    if "Kill 100 zombies with an RPG" not in _dropped:
        world.set_rule(world.multiworld.get_location("Kill 100 zombies with an RPG", world.player), _rpg_rule)

    if "Hit 10 zombies with a parasol" not in _dropped:
        world.set_rule(world.multiworld.get_location("Hit 10 zombies with a parasol", world.player), (And(Or(CanReachRegion("Entrance Plaza"), CanReachRegion("Al Fresca Plaza"), CanReachRegion("Crislip's Home Saloon")), Has("Parasol")) if world.options.restricted_item_mode else Or(CanReachRegion("Entrance Plaza"), CanReachRegion("Al Fresca Plaza"), CanReachRegion("Crislip's Home Saloon"), And(Has("Parasol"), CanReachRegion("Paradise Plaza")))))
    world.set_rule(world.multiworld.get_location("Kill 50 cultists", world.player), And(CanReachRegion("Paradise Plaza"), CanReachLocation("Witness Sean in Paradise Plaza")))
    world.set_rule(world.multiworld.get_location("Photograph 30 survivors", world.player), And(CanReachRegion("Leisure Park"), CanReachRegion("Al Fresca Plaza"), CanReachRegion("Wonderland Plaza"), CanReachRegion("North Plaza"), CanReachRegion("Entrance Plaza"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM")))
    # Needs survivors alive and willing to follow, which Psycho does
    # not allow. create_region drops these, so do not rule them either.
    if not world.psycho_mode:
        world.set_rule(world.multiworld.get_location("Escort 8 survivors at once", world.player), And(CanReachRegion("Paradise Plaza"), CanReachRegion("Al Fresca Plaza"), CanReachLocation("Kill Jo"), CanReachRegion("Food Court"), CanReachRegion("Entrance Plaza"), (AtLeast(8, *[Has(s) for s, c in SCOOP_SURVIVOR_COUNTS.items() for _ in range(c[0])]) if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
        world.set_rule(world.multiworld.get_location("Frank the pimp", world.player), And(CanReachRegion("Paradise Plaza"), CanReachRegion("Al Fresca Plaza"), CanReachLocation("Kill Jo"), CanReachRegion("Food Court"), CanReachRegion("Entrance Plaza"), (AtLeast(8, *[Has(s) for s, c in SCOOP_SURVIVOR_COUNTS.items() for _ in range(c[1])]) if world.options.scoop_sanity else And(Has("DAY2_06_AM"), Has("DAY2_11_AM")))))
    # Car Keys moves the vehicle challenges behind the key for a vehicle that
    # is actually in the region. Leisure Park parks the sports car and a
    # motorcycle; the Maintenance Tunnels have the sedan and the box truck.
    if world.options.car_keys:
        # Door Randomizer stops vehicles being driven between areas, so a car
        # is only usable where it is parked. Without it they can be driven
        # anywhere, and only collecting them is region-bound.
        _cars_travel = not world.options.door_randomizer

        # A car crossing between the two areas has to take the ramp, so the
        # ramp's own door is required on top of reaching the far side. Region
        # access alone is not enough: Leisure Park also opens from North Plaza
        # and Paradise, and neither of those is drivable.
        def _drive_from(key_name):
            home = CAR_HOME[key_name]
            if home == "Maintenance Tunnel":
                return And(Has(key_name), CanReachRegion(home), _ramp_to_park)
            return And(Has(key_name), CanReachRegion(home), _ramp_to_tunnel)

        # The ramp is in Leisure Park and only these two can take it.
        _jump_alts = [And(Has("Sports Car Key"), CanReachRegion("Leisure Park"))]
        if _cars_travel:
            # The sedan lives in the Tunnel, so this route means fetching it
            # and driving it over the ramp.
            _jump_alts.append(_drive_from("Sedan Key"))
        _jump_rule = Or(*_jump_alts) if len(_jump_alts) > 1 else _jump_alts[0]

        # Counts this high are only practical in the Tunnel, so it stays
        # required either way. What can satisfy it is what differs: any car
        # when they can be driven over, only a Tunnel one when they cannot.
        if _cars_travel:
            _usable = [And(Has(_k), CanReachRegion(_r))
                       if _r == "Maintenance Tunnel" else _drive_from(_k)
                       for _k, _r in CAR_HOME.items()]
            _kill_rule = And(CanReachRegion("Maintenance Tunnel"), Or(*_usable))
        else:
            _kill_rule = And(CanReachRegion("Maintenance Tunnel"),
                             Or(Has("Sedan Key"), Has("Truck Key")))
    else:
        _jump_rule = CanReachRegion("Leisure Park")
        _kill_rule = CanReachRegion("Maintenance Tunnel")
    world.set_rule(world.multiworld.get_location("Jump a vehicle 50 feet", world.player), _jump_rule)
    if "Bowl over 5 zombies" not in _dropped:
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
    world.set_rule(world.multiworld.get_location("Kill 500 zombies by vehicle", world.player), _kill_rule)
    world.set_rule(world.multiworld.get_location("Kill 1000 zombies by vehicle", world.player), _kill_rule)
    all_side_scoops = SURVIVOR_SCOOP_NAMES + PSYCHOPATH_SCOOP_NAMES
    if world.spitter_only:
        # Photo Challenge arms Kent's day 2, which this mode drops, so the
        # item is not in the pool and cannot be part of "the story is done".
        all_side_scoops = [_s for _s in all_side_scoops
                           if _s != "Photo Challenge"]
    # Needs survivors alive and willing to follow, which Psycho does
    # not allow. create_region drops these, so do not rule them either.
    if not world.psycho_mode:
        world.set_rule(world.multiworld.get_location("Get 50 survivors to join", world.player), And(CanReachRegion("Paradise Plaza"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), Has("DAY3_11_AM"), CanReachLocation("Kill Kent on day 3"), CanReachLocation("Kill Cliff"), CanReachLocation("Kill Jo"), CanReachLocation("Kill Adam"), CanReachLocation("Kill Sean"), CanReachLocation("Kill Roger and Jack (and Thomas if you want) and chat with Wayne"), CanReachLocation("Defeat Paul"), (And(HasAll(*all_side_scoops), ending_a_rule) if world.options.scoop_sanity else True_())))
    world.set_rule(world.multiworld.get_location("Encounter 10 survivors", world.player), And(CanReachRegion("Paradise Plaza"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), Has("DAY3_11_AM"), CanReachLocation("Kill Kent on day 3"), CanReachLocation("Kill Cliff"), CanReachLocation("Kill Jo"), CanReachLocation("Kill Adam"), CanReachLocation("Kill Sean"), CanReachLocation("Kill Roger and Jack (and Thomas if you want) and chat with Wayne"), CanReachLocation("Defeat Paul")))
    world.set_rule(world.multiworld.get_location("Encounter 50 survivors", world.player), And(CanReachRegion("Paradise Plaza"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), Has("DAY3_00_AM"), Has("DAY3_11_AM"), CanReachLocation("Kill Kent on day 3"), CanReachLocation("Kill Cliff"), CanReachLocation("Kill Jo"), CanReachLocation("Kill Adam"), CanReachLocation("Kill Sean"), CanReachLocation("Kill Roger and Jack (and Thomas if you want) and chat with Wayne"), CanReachLocation("Defeat Paul"), (And(HasAll(*all_side_scoops), ending_a_rule) if world.options.scoop_sanity else True_())))
    # The rescue ladder, or the kill ladder in its place. Only one of the two
    # sets of locations exists in a seed, and both count to the same numbers.
    if world.psycho_mode:
        _kill_locs = [CanReachLocation(_l) for _l in world.ALL_KILL_LOCATIONS
                      if _l not in _dropped]
        for _n in SURVIVOR_MILESTONES:
            world.set_rule(
                world.multiworld.get_location("Kill {} survivors".format(_n),
                                              world.player),
                AtLeast(_n, *_kill_locs))
    else:
        # Paul is not rescuable in Spitter Only, so he cannot count toward
        # a milestone either.
        _rescue_locs = [CanReachLocation(_l) for _l in world.ALL_RESCUE_LOCATIONS
                        if _l not in _dropped]
        for _n in SURVIVOR_MILESTONES:
            if "Rescue {} survivors".format(_n) in _dropped:
                continue
            world.set_rule(
                world.multiworld.get_location("Rescue {} survivors".format(_n),
                                              world.player),
                AtLeast(_n, *_rescue_locs))

    # Challenge locations default to sphere 0 via the blanket rule above.
    # Falling far enough is awkward to arrange at the start, so this one is
    # pushed behind the Warehouse instead of being an early-game filler
    # slot nobody can identify (#14).
    world.set_rule(world.multiworld.get_location("Fall from a high height", world.player), CanReachRegion("Warehouse"))
    if "Fire 30 bullets" not in _dropped:
        world.set_rule(world.multiworld.get_location("Fire 30 bullets", world.player), Or(CanReachLocation("Fire 300 bullets"), And(Has("Handgun"), Or(CanReachRegion("North Plaza"), CanReachRegion("Wonderland Plaza"), CanReachRegion("Paradise Plaza"), CanReachRegion("Al Fresca Plaza"))) if world.options.restricted_item_mode else Or(CanReachRegion("North Plaza"), CanReachRegion("Wonderland Plaza"), CanReachRegion("Paradise Plaza"), CanReachRegion("Al Fresca Plaza"))))
        world.set_rule(world.multiworld.get_location("Fire 300 bullets", world.player), (And(CanReachRegion("North Plaza"), Or(*[Has(g) for g in (("Handgun", "Shotgun", "Sniper Rifle") if world.options.door_randomizer else ("Handgun", "Submachine Gun", "Shotgun", "Sniper Rifle"))])) if world.options.restricted_item_mode else Or(CanReachRegion("North Plaza"), And(Or(*[Has(g) for g in ("Handgun", "Submachine Gun", "Shotgun", "Sniper Rifle", "Heavy Machinegun", "Machinegun")]), CanReachRegion("Rooftop")))))
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
    world.set_rule(world.multiworld.get_location("Change into 5 new outfits", world.player), Or(CanReachRegion("Paradise Plaza"), CanReachRegion("Entrance Plaza"), CanReachRegion("Wonderland Plaza")))

    # --------------------------------------------------------------------
    # --------------------------------------------------------------------
    # Special Forces in the mall
    # --------------------------------------------------------------------
    # The two Special Forces checks are normally Overtime-only. When
    # special_forces_mode puts the soldiers in the mall during the 72 hours
    # they are reached there instead, so these rules REPLACE the Overtime ones
    # set above (same location, different way in -- the check itself is the
    # same accomplishment either way).
    #
    # Set after the Ending S block deliberately: set_rule overwrites, so with
    # the mode on the mall rule wins, and with it off the Overtime rule stands.
    if world.options.special_forces_mode.value and world.options.scoop_sanity:
        _sf_item_mode = world.options.special_forces_mode.value == 1

        # Killing them needs nothing but the soldiers being present. In item
        # mode that is the scoop; in permanent they are there from Jessie on.
        _kill_reqs = []
        if _sf_item_mode:
            _kill_reqs.append(Has("Special Forces"))
        world.set_rule(
            world.multiworld.get_location("Kill 10 Special Forces", world.player),
            And(*_kill_reqs) if _kill_reqs else CanReachRegion("Paradise Plaza"))

        # The helicopter is over Leisure Park and has to be SHOT down, so
        # reaching the park is not enough on its own -- under door
        # randomization the first door can open onto Leisure Park with no gun
        # anywhere behind the player.
        #
        # Any of three guns will do it (the Handgun turns out to be plenty),
        # and each is found in its own set of regions:
        _PISTOL_REGIONS = ("Paradise Plaza", "Al Fresca Plaza",
                           "Wonderland Plaza", "North Plaza")
        _SNIPER_REGIONS = ("North Plaza",)
        _SMG_REGIONS = ("Al Fresca Plaza", "Entrance Plaza",
                        "Paradise Plaza", "Food Court")

        if world.options.restricted_item_mode:
            # Restricted: a gun only exists once its item has arrived, and it
            # still has to be picked up where it spawns -- so both halves are
            # required, per gun.
            _armed = Or(
                And(Has("Handgun"),
                    Or(*[CanReachRegion(r) for r in _PISTOL_REGIONS])),
                And(Has("Sniper Rifle"),
                    Or(*[CanReachRegion(r) for r in _SNIPER_REGIONS])),
                And(Has("Submachine Gun"),
                    Or(*[CanReachRegion(r) for r in _SMG_REGIONS])),
            )
        else:
            # Otherwise guns lie around the mall, so reaching any region that
            # has one is enough -- or simply being sent one as an item.
            _gun_regions = sorted(set(_PISTOL_REGIONS + _SNIPER_REGIONS
                                      + _SMG_REGIONS))
            _armed = Or(
                Or(*[CanReachRegion(r) for r in _gun_regions]),
                Or(*[Has(g) for g in
                     ("Handgun", "Sniper Rifle", "Submachine Gun")]),
            )

        _heli_reqs = [CanReachRegion("Leisure Park"), _armed]
        if _sf_item_mode:
            _heli_reqs.append(Has("Special Forces"))
        world.set_rule(
            world.multiworld.get_location(
                "Hella Copter - Shoot down the Special Forces Helicopter",
                world.player),
            And(*_heli_reqs))

    # Overtime checks as filler
    # --------------------------------------------------------------------
    # Keyed off the category rather than the names: Overtime picks up checks
    # over time and a name list would quietly fall behind.
    #
    # Items are deliberately untouched. The Clock Tower Tunnel Key and Humvee
    # Key stay progression -- the ask was to stop needing what is IN Overtime,
    # not to stop needing a key to get through it.
    if world.options.overtime_checks_filler:
        _overtime_names = {
            _d.name
            for _table in location_tables.values()
            for _d in _table
            if _d.category == DRLocationCategory.OVERTIME_SCOOP
            or (_d.category == DRLocationCategory.SPECIAL_FORCES_SCOOP
                and not world.options.special_forces_mode.value)
        }
        for location in world.multiworld.get_locations(world.player):
            if location.name in _overtime_names:
                location.progress_type = LocationProgressType.EXCLUDED

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
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 95", world.player), CanReachRegion("Meat Processing Area"))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 96", world.player), CanReachRegion("Meat Processing Area"))

    # PP Stickers in Security Room
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 97", world.player), CanReachRegion("Security Room"))

    # PP Stickers in Cultists' Hideout. The exit is redirected into Paradise
    # Plaza, so Leisure Park is no longer needed to get back out.
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 98", world.player), And(CanReachRegion("Paradise Plaza"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), CanReachLocation("Get grabbed by the raincoats")))
    world.set_rule(world.multiworld.get_location("Photograph PP Sticker 99", world.player), And(CanReachRegion("Paradise Plaza"), Has("DAY2_06_AM"), Has("DAY2_11_AM"), CanReachLocation("Get grabbed by the raincoats")))

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
    # Extra PP for using things around the mall. Most need only the region
    # they sit in, which the default rule already gives, so only the ones
    # asking for more are here -- treadmills, dishes and sandbags have no
    # rule on purpose. set_rule REPLACES that default, so each line below
    # names its own region.
    if world.options.pp_bonus_locations:
        restricted_mode_on = bool(world.options.restricted_item_mode.value)

        # A player sent the Access Key opens that door without going down.
        world.set_rule(world.multiworld.get_location("Obtain Maintenance Tunnel Key", world.player), Or(CanReachRegion("Maintenance Tunnel"), Has("Maintenance Tunnel Access Key")))

        # Behind the Seon's register scoop, so it is not created on a seed
        # where main scoops are not checks.
        try:
            _first_aid = world.multiworld.get_location("Obtain First Aid Kit", world.player)
        except KeyError:
            _first_aid = None
        if _first_aid is not None:
            world.set_rule(_first_aid, And(CanReachRegion("Seon's Food and Stuff"), CanReachLocation("Clean up... Register 6!")))

        # A microwave needs food. Seon's is where it comes from; being sent it
        # is just as good, except in restricted mode which needs both.
        if restricted_mode_on:
            microwave_food = And(CanReachRegion("Seon's Food and Stuff"),
                                 Or(Has("Uncooked Pizza"), Has("Raw Meat")))
        else:
            microwave_food = Or(CanReachRegion("Seon's Food and Stuff"),
                                Has("Uncooked Pizza"), Has("Raw Meat"))

        world.set_rule(world.multiworld.get_location("Use the Microwave in Jill's Sandwiches", world.player), And(CanReachRegion("Paradise Plaza"), microwave_food))
        world.set_rule(world.multiworld.get_location("Use the Microwave in Chris's Fine Foods", world.player), And(CanReachRegion("Food Court"), microwave_food))
        world.set_rule(world.multiworld.get_location("Use the Microwave in That's a Spicy Meatball!", world.player), And(CanReachRegion("Food Court"), microwave_food))
        world.set_rule(world.multiworld.get_location("Use the Microwave in Central Tacos", world.player), And(CanReachRegion("Food Court"), microwave_food))
        world.set_rule(world.multiworld.get_location("Use the Microwave in Meaty's Burgers", world.player), And(CanReachRegion("Food Court"), microwave_food))
        world.set_rule(world.multiworld.get_location("Use the Microwave in Jade Paradise", world.player), And(CanReachRegion("Food Court"), microwave_food))
        world.set_rule(world.multiworld.get_location("Use the Microwave in Teresa's Oven", world.player), And(CanReachRegion("Food Court"), microwave_food))
        world.set_rule(world.multiworld.get_location("Use the Microwave in Colombian Roastmasters - Al Fresca Plaza", world.player), And(CanReachRegion("Al Fresca Plaza"), microwave_food))
        world.set_rule(world.multiworld.get_location("Use the Microwave in Hamburger Fiefdom", world.player), And(CanReachRegion("Al Fresca Plaza"), microwave_food))

        # Outside restricted mode a pan is always to hand. Spitter Only has
        # no pan at all, and drops the stove checks instead.
        if restricted_mode_on and not world.spitter_only:
            world.set_rule(world.multiworld.get_location("Heat a pan on the Stove in Colombian Roastmasters - Paradise Plaza", world.player), And(CanReachRegion("Paradise Plaza"), Has("Frying Pan")))
            world.set_rule(world.multiworld.get_location("Heat a pan on the Stove in Jill's Sandwiches", world.player), And(CanReachRegion("Paradise Plaza"), Has("Frying Pan")))
            world.set_rule(world.multiworld.get_location("Heat a pan on the Stove in Chris's Fine Foods", world.player), And(CanReachRegion("Food Court"), Has("Frying Pan")))
            world.set_rule(world.multiworld.get_location("Heat a pan on the Stove in That's a Spicy Meatball!", world.player), And(CanReachRegion("Food Court"), Has("Frying Pan")))
            world.set_rule(world.multiworld.get_location("Heat a pan on the Stove in Colombian Roastmasters - Al Fresca Plaza", world.player), And(CanReachRegion("Al Fresca Plaza"), Has("Frying Pan")))

        # The racks are inside Entrance Plaza's storefronts. ep_shutter
        # already carries CanReachRegion("Entrance Plaza").
        world.set_rule(world.multiworld.get_location("Spin the Display Rack at Shootingstar Sporting Goods Right", world.player), ep_shutter)
        world.set_rule(world.multiworld.get_location("Spin the Display Rack at Shootingstar Sporting Goods Left", world.player), ep_shutter)
        world.set_rule(world.multiworld.get_location("Spin the Display Rack at Jason Wayne's Sporting Goods Front", world.player), ep_shutter)
        world.set_rule(world.multiworld.get_location("Spin the Display Rack at Jason Wayne's Sporting Goods Back", world.player), ep_shutter)

        # Microwaves and stoves are counted mall-wide, so these name every
        # region holding one. Their own region is the Security Room, which is
        # sphere 0 and adds nothing.
        world.set_rule(world.multiworld.get_location("Use All Microwaves", world.player), And(CanReachRegion("Paradise Plaza"), CanReachRegion("Food Court"), CanReachRegion("Al Fresca Plaza"), microwave_food))
        if "Heat a pan on all stoves" not in _dropped:
            if restricted_mode_on:
                world.set_rule(world.multiworld.get_location("Heat a pan on all stoves", world.player), And(CanReachRegion("Paradise Plaza"), CanReachRegion("Food Court"), CanReachRegion("Al Fresca Plaza"), Has("Frying Pan")))
            else:
                world.set_rule(world.multiworld.get_location("Heat a pan on all stoves", world.player), And(CanReachRegion("Paradise Plaza"), CanReachRegion("Food Court"), CanReachRegion("Al Fresca Plaza")))
        world.set_rule(world.multiworld.get_location("Spin All Display Racks", world.player), ep_shutter)

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
        savior_rescue_locations = [_l for _l in world.ALL_RESCUE_LOCATIONS
                                   if _l not in _dropped]

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

    if world.psycho_mode:
        psycho_rule = AtLeast(world.options.number_of_kills.value,
                              *[CanReachLocation(l) for l in world.ALL_KILL_LOCATIONS
                                if l not in _dropped])

        world.set_rule(world.multiworld.get_location(world.PSYCHO_GOAL_LOCATION,
                                                     world.player),
                       psycho_rule)

        # Same treatment Savior gives Ending A: it still exists as filler when
        # main scoops are on, so keep progression out of it.
        if world.main_scoops_enabled:
            world.multiworld.get_location(
                "Ending A: Solve all of the cases and be on the helipad at 12pm",
                world.player
            ).progress_type = LocationProgressType.EXCLUDED

    # Victory Condition
    world.set_completion_rule(Has("Victory"))
