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
    default = 1


class RandomizeRooftopServiceHallwayDoors(Toggle):
    """
    When enabled (and Door Randomizer is on), the doors between Rooftop and
    Warehouse are included in the randomization pool.

    When disabled (the default), those two doors are left vanilla even with
    Door Randomizer on, so the opening sequence behaves as expected. Only
    affects the Rooftop <-> Warehouse pair; all other doors still
    randomize normally.

    Has no effect if Door Randomizer is disabled.
    """
    display_name = "Randomize Rooftop/Warehouse Doors"
    default = False

class Goal(Choice):
    """
    Determines the victory condition for the game.

    Ending S: Complete all overtime missions and defeat Brock on the tank.
              This is the full game experience including overtime mode.

    Ending A: Solve all of the cases and reach the helipad by 12pm on Day 4.
              Overtime scoops are removed from the pool, making for a shorter run.

    Savior:   Rescue a specified number of survivors to win (see
              "Number of Survivors" below). Ending S / Ending A locations still
              exist as normal checks but are filler-only and not the goal.
    """
    display_name = "Goal"
    option_ending_s = 0
    option_ending_a = 1
    option_savior = 2
    default = 0


class NumberOfSurvivors(Range):
    """
    The number of survivors that must be rescued for the Savior goal. Only has
    an effect when Goal is set to Savior.

    The maximum (48) requires rescuing every survivor in the game — 45 from
    survivor/psychopath scoops plus the 3 free survivors (Bill Brenton,
    Jeff Meyer, Natalie Meyer) who arrive without a dedicated scoop.
    """
    display_name = "Number of Survivors"
    range_start = 1
    range_end = 48
    default = 35


class ScoopSanity(Toggle):
    """
    When enabled, scoops are sent to the player as items and the game time is frozen
    after completing the Entrance Plaza prologue.

    The order for main scoops will be randomized and the player will need
    to receive the scoop item in order for the next scoop to spawn in the world.

    An example:
    The player's scoop order is 1. Girl Hunting, 2. Carlito's Hideout, 3. Backup for Brad.
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


class ExcludeLevels(Toggle):
    """
    When enabled, high level-up checks are prevented from having progression items.
    This can be used to limit grinding and allows more control over the potential length of a run.
    """
    display_name = "Exclude Levels"
    default = True


class ExcludeLevelsAbove(Range):
    """
    If 'Exclude Levels' is enabled, any level-ups above the chosen value will still
    exist as checks but will be prevented from having progression items.
    If 'Exclude Levels' is disabled, this value can be ignored.
    """

    display_name = "Exclude Levels Above"
    range_start = 25
    range_end = 50
    default = 30


class EnableSkillItems(DefaultOnToggle):
    """
    When enabled, Frank's 21 combat skills (Jump Kick, Suplex, etc.) become AP
    items in the pool. They are classified as Useful — guaranteed to be in
    the multiworld but not in progression logic.

    Has no effect if Vanilla Progression is set to 'vanilla_only' (in that mode
    the skills are granted normally on level-up and not duplicated as items).
    """
    display_name = "Enable Skill Items"


class EnableStatItems(DefaultOnToggle):
    """
    When enabled, Progressive stat upgrades become AP items in the pool:
    Health (+1000), Attack (+25%), Throw (+25), Item Slot (+1), Run Level (+1).
    Classified as Useful.

    Has no effect if Vanilla Progression is set to 'vanilla_only'.
    """
    display_name = "Enable Stat Items"


class EnableExtraStatBuffs(Toggle):
    """
    When enabled, additional stat-upgrade items push past vanilla L50 caps:
       * +4 Health (cap 16000)
       * +10 Attack (cap 500%)
       * +8 Throw (cap 400)
       * +3 Item Slot (cap 15)
       * +10 Speed Multiplier (cap 1.5x — DRAP-only category)

    Useful for longer multiworld pools or harder-mode runs. Note that pushing
    Attack past 250% breaks the in-game UI bar count (combat damage still
    scales correctly).
    """
    display_name = "Enable Extra Stat Buffs"
    default = False


class VanillaProgression(Choice):
    """
    Controls how Frank's natural level-up rewards interact with AP items.

    vanilla_only:
        Engine grants skills/stats normally on level-up. AP skill/stat items
        are NOT in the pool. Use this if you only want scoop/door
        randomization without touching Frank's progression.

    replace:
        Engine's level-up grants are suppressed (re-overridden each level).
        AP items are the only source of skills and stats. The default.

    extra_buffs_only:
        Engine grants normally, AP items contain ONLY the over-vanilla extras
        (cap-pushing items). Best paired with Enable Extra Stat Buffs = true.
    """
    display_name = "Vanilla Progression"
    option_vanilla_only = 0
    option_replace = 1
    option_extra_buffs_only = 2
    default = 1


class TrapPercentage(Range):
    """
    Percentage of filler-item slots that become traps. 0 = no traps,
    25 = balanced default, 50 = aggressive, 100 = chaos. The selected
    fraction of filler slots is dedicated to traps and round-robin
    distributed across all six trap types (Stomach Ache Trap, Zombait
    Trap, Slow Trap, Damage Player Trap, Hostile NPC Trap, Special
    Forces Trap) so every type appears at least once before any
    repeats.
    """
    display_name = "Trap Percentage"
    range_start = 0
    range_end = 100
    default = 25


class HostileSurvivorCountMin(Range):
    """
    Minimum number of hostile NPCs spawned per Hostile NPC Trap.
    Each trap rolls between min and max (inclusive) at fire time.
    """
    display_name = "Hostile NPC Count Min"
    range_start = 1
    range_end = 5
    default = 1


class HostileSurvivorCountMax(Range):
    """
    Maximum number of hostile NPCs spawned per Hostile NPC Trap.
    Capped by the trap pool's available stypes (~10 cutscene-only NPCs).
    """
    display_name = "Hostile NPC Count Max"
    range_start = 1
    range_end = 10
    default = 3


class NightModeEnabled(Toggle):
    """
    When enabled, zombies behave as if it is always night, regardless of
    the in-game time. The night-side parameters of `ZombieDefinitionUserData`
    (HoldMissRate, HoldBlockRate, HoldBlockFallRate) are written over the
    day-side fields, and `ZombieManager.isHourNight()` is hooked to always
    return true.

    Effects:
      * Higher chance for grabs to land (Day 5% miss → Night 15% miss)
      * Higher chance for zombies to block counterattacks (Day 45% → Night 55%)
      * Slightly more aggressive overall behavior

    The "glowing eyes" visual effect that normally accompanies night does
    NOT carry over — that's tied to a separate render pass. This is purely
    a difficulty modifier.
    """
    display_name = "Night Mode"
    default = False


class HardcoreZombiesEnabled(Toggle):
    """
    When enabled, zombies become significantly more dangerous on top of
    Night Mode. **Implies Night Mode** — turning this on without enabling
    Night Mode auto-enables it.

    Amplified parameters:
      * Bite damage: -1000 → -3000 HP per tick (3×)
      * Downed-bite damage: -3000 → -9000 HP per tick (3×)
      * Scratch damage rate: 3.5 → 7.0 (2×)
      * Player aggro radius: 9 → 25 units (much harder to sneak past)
      * General aggro radius: 13 → 35 units
      * NPC aggro radius: 10 → 25 units (zombies notice survivors faster)
      * Grab escape mash count: 15 → 30 (2× harder to escape)
      * Mash decay rate: 0.02 → 0.05 (gauge drains faster while mashing)

    Recommended only for experienced players seeking a challenge run.
    """
    display_name = "Hardcore Zombies"
    default = False


class RandomStartingCostume(Toggle):
    """
    When enabled, Frank's outfit is randomized once at the start of each
    play session (after the save loads or on a fresh new game). One
    consistent randomized look per seed.

    Randomization rules:
      * Body slot (0..42 regular costumes by default; 0..62 if DLC outfits
        are enabled below) is always picked first.
      * If the rolled Body is a regular costume (0..42), Foot / Hat /
        Glasses are also randomized to give Frank a chaotic accessorized
        outfit.
      * If the rolled Body is a DLC anchor (43..62, requires Dlc Outfits
        Enabled), it acts as a full-outfit replacement and the engine
        overrides the other slots automatically — Foot / Hat / Glasses are
        left alone since the DLC outfit dictates the whole look.

    Independent of the Costume Chaos Mode option below.
    """
    display_name = "Random Starting Costume"
    default = False


class CostumeChaosMode(Toggle):
    """
    When enabled, Frank's outfit is re-randomized on every area transition
    (i.e. every door / loading-zone change). Frank looks different in every
    area, with a fresh random outfit each time.

    Uses the same Body-first randomization rules as Random Starting Costume.
    Each area transition will count toward the "Change into 8 different
    outfits" achievement, which may complete that location very quickly.

    Compatible with Random Starting Costume. If both are on, the starting
    costume picks the look at session start and chaos mode reshuffles on
    every door from there.
    """
    display_name = "Costume Chaos Mode"
    default = False


class PpBonusLocations(DefaultOnToggle):
    """
    Adds ~57 extra AP location checks tied to PP-bonus events and key-item
    pickup banners that DRAP detects via the MsgEvents watcher:

    Single-fire checks:
      * Realign Servbot Head (Paradise Plaza fountain)
      * Ride the Space Rider
      * Obtain Mall Map and Transceiver (Otis bundle)
      * Obtain Maintenance Tunnel Key
      * Obtain First Aid Kit (in Seon's Food and Stuff, gated on defeating Steven)

    Counted-progression checks (per-instance + ALL-X final):
      * Walk on N Treadmills (1..6, plus All Treadmills)         -- Al Fresca
      * Destroy N Sandbags (1..4, plus All Sandbags)             -- Al Fresca
      * Spin N Display Racks (1..4, plus All Display Racks)      -- Entrance
      * Break N Food Court Wall Plates (1..18, no separate "all")
      * Microwave N Items (1..9, plus Microwave All Items)
      * Heat N Pans (1..5, plus Heat All Pans)

    Logic gating: each check requires the relevant region. Microwave/Heat
    locations require Food Court access (the most restrictive of the regions
    those events occur in). In Restricted Item Mode, microwave checks
    additionally require Uncooked Pizza or Raw Meat, and stove checks
    require Frying Pan.
    """
    display_name = "PP-Bonus Locations"


class DLCOutfitsEnabled(Toggle):
    """
    When enabled, the costume randomizer's Body pool includes the 20 DLC
    outfit IDs (43..62) on top of the 43 regular Body costumes. DLC IDs
    function as full-outfit anchors — picking one applies a complete DLC
    outfit (e.g. Mega Man armor, knight set) instead of a partial body.

    REQUIRES the player owns the corresponding DR-DR DLC. If the DLC is not
    installed, applying these IDs is expected to fail silently (the engine
    rejects the swap and Frank stays in his current outfit). Leave this
    OFF if you don't own the DLC to keep the randomizer pool in the safe
    range.
    """
    display_name = "DLC Outfits Enabled"
    default = False


class ExcludeOverpoweredItems(Toggle):
    """
    When enabled, removes a curated set of items widely considered too
    powerful from the AP item pool:

      * Book [Infinite Durability]  (weapons never break)
      * Book [Martial Arts]         (massively-boosted unarmed damage)
      * Laser Sword                 (high-damage, high-durability weapon)
      * Real Mega Buster            (high-damage ranged weapon)

    Disabled by default. Players who want these items to remain in
    rotation should leave it off; players who want a more balanced run
    should enable it.

    Note: items explicitly listed under Guaranteed Items are still added
    even when this option is on, since that's an explicit user override.
    """
    display_name = "Exclude Overpowered Items"
    default = False


@dataclass
class DROption(PerGameCommonOptions):
    goal: Goal
    number_of_survivors: NumberOfSurvivors
    guaranteed_items: GuaranteedItemsOption
    death_link: DeathLink
    restricted_item_mode: RestrictedItemMode
    door_randomizer: DoorRandomizer
    door_randomizer_mode: DoorRandomizerMode
    randomize_rooftop_service_hallway_doors: RandomizeRooftopServiceHallwayDoors
    scoop_sanity: ScoopSanity
    exclude_levels: ExcludeLevels
    exclude_levels_above: ExcludeLevelsAbove
    enable_skill_items: EnableSkillItems
    enable_stat_items: EnableStatItems
    enable_extra_stat_buffs: EnableExtraStatBuffs
    vanilla_progression: VanillaProgression
    exclude_overpowered_items: ExcludeOverpoweredItems
    trap_percentage: TrapPercentage
    hostile_survivor_count_min: HostileSurvivorCountMin
    hostile_survivor_count_max: HostileSurvivorCountMax
    night_mode_enabled: NightModeEnabled
    hardcore_zombies_enabled: HardcoreZombiesEnabled
    random_starting_costume: RandomStartingCostume
    costume_chaos_mode: CostumeChaosMode
    dlc_outfits_enabled: DLCOutfitsEnabled
    pp_bonus_locations: PpBonusLocations