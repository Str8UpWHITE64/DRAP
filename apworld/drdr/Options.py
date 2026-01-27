import typing
from dataclasses import dataclass
from Options import Toggle, DefaultOnToggle, Option, Range, Choice, ItemDict, DeathLink, PerGameCommonOptions, OptionGroup

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


@dataclass
class DROption(PerGameCommonOptions):
    guaranteed_items: GuaranteedItemsOption
    death_link: DeathLink
    restricted_item_mode: RestrictedItemMode