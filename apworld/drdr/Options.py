import typing
from dataclasses import dataclass
from Options import Toggle, DefaultOnToggle, Option, Range, Choice, ItemDict, DeathLink, PerGameCommonOptions, \
    OptionGroup


class GuaranteedItemsOption(ItemDict):
    """Guarantees that the specified items will be in the item pool"""
    display_name = "Guaranteed Items"


class RestrictedItemMode(Toggle):
    """
    When enabled, players cannot pick up items in the world unless they have been sent
    to them by the Archipelago server. This creates a more challenging experience where
    you must rely on items from other players or your own location checks.

    Items received from AP will be shown in the Items window, and only those items
    can be picked up from the ground or dispensers in the game world.
    """
    display_name = "Restricted Item Mode"
    default = False


class DoorRandomizer(Toggle):
    """
    When enabled, door connections throughout the mall are randomized.
    All area keys are given to you at the start, and doors lead to unexpected locations.

    The randomizer ensures all areas remain reachable and no softlocks occur.
    """
    display_name = "Door Randomizer"
    default = False


class DoorRandomizerMode(Choice):
    """
    Controls how doors are randomized when Door Randomizer is enabled.

    Chaos: Doors are fully randomized. Going through door A to reach area B
           does NOT mean the door in B will take you back to A. Navigation
           requires careful attention to the door map.

    Paired: Doors are randomized in pairs. If door A leads to area B, then
            a door in B will lead back to A. This creates a more intuitive
            but still randomized layout.
    """
    display_name = "Door Randomizer Mode"
    option_chaos = 0
    option_paired = 1
    default = 0

class ScoopSanity(Toggle):
    """
    When enabled, scoops are sent to the player as items and the game time is frozen
    after completing the Entrance Plaza prologue.

    The order for main scoops will be randomized and the player will need
    to receive the scoop item in order for the next scoop to spawn in the world.

    An example:
    The player's scoop order is 1. Girl Hunting, 2. Hideout, 3. Backup for Brad.
    After completing the Entrance Plaza prologue, the player will need to wait
    until they receive the Girl Hunting scoop item from AP before they can do the mission.
    If they receive a later mission, like Backup for Brad, they will not be able to do it until they
    receive and complete the prior missions.

    Players will also receive side scoops as items, which will spawn the NPCs into
    the world right away.

    An example:
    The player receives "Lovers".  Tonya and Ross will now spawn into the world in
    Wonderland plaza and are rescuable.
    """
    display_name = "ScoopSanity"
    default = True


@dataclass
class DROption(PerGameCommonOptions):
    guaranteed_items: GuaranteedItemsOption
    death_link: DeathLink
    restricted_item_mode: RestrictedItemMode
    door_randomizer: DoorRandomizer
    door_randomizer_mode: DoorRandomizerMode
    scoop_sanity: ScoopSanity