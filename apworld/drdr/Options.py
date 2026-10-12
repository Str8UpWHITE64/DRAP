import typing
from dataclasses import dataclass
import settings
from Options import Toggle, DefaultOnToggle, FreeText, Option, Range, Choice, ItemDict, DeathLink, PerGameCommonOptions, StartInventoryPool, OptionGroup, OptionSet
from Options import ExcludeLocations, PriorityLocations, StartLocationHints
from .Locations import location_tables, kill_sanity_location_groups


class DRDRSettings(settings.Group):
    """host.yaml settings for the machine that generates. A player's YAML
    cannot turn these on; only whoever runs generation can, because the cost
    lands on the whole multiworld."""

    class KillsanityGenocideAllowed(settings.Bool):
        """Allow kill_sanity with zombie_kill_tiers: genocide. That is 53,594
        locations for one player, about two minutes to generate on its own,
        and it grows with the player count."""

    killsanity_genocide_allowed: typing.Union[KillsanityGenocideAllowed, bool] = False


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


class KillSanity(Toggle):
    """
    Every zombie kill in each area is its own check, up to the number
    specified in the Zombie Kill Tier. This will add a lot of useless
    filler items, but most of it will be placed in your game.
    
    Each tier adds this many locations:

    None: 0
    Easy: 2300
    Normal: 6400
    Nightmare: 15000
    Genocide: 53594

    NOTE: Due to the number of locations it adds and because it increases
    generation time dramaticlly, KillSanity with Genocide needs to be
    enabled in the host.yaml file of whoever is generating the multiworld.
    """
    display_name = "KillSanity"
    default = False


class DamageLink(Toggle):
    """
    Share damage with the rest of the multiworld. Taking a hit sends damage
    out; damage from another player takes health here.

    Eighty damage points are one of Frank's health blocks, the same rate Ship
    of Harkinian uses for a heart. A single packet is capped at one block, so
    one hit from the room cannot kill Frank unless he is already on his last
    block. Small hits are added up rather than sent one at a time. Type
    /damagelink off in the client window to leave the link mid-session.

    Damage arriving this way CAN kill, and it behaves like any other death
    (including triggering DeathLink, if that is on too).
    """
    display_name = "DamageLink"
    default = False


class DamageLinkGroup(FreeText):
    """
    Damage Link only applies to players with an identical Group name.

    Leave it empty to share damage with everyone, which is what games without
    this option do. Games that do not support groups count as having an empty
    group name.
    """
    display_name = "Damage Link Group"
    rich_text_doc = True


class KnockbackLink(Toggle):
    """
    Share being knocked about with the rest of the multiworld. Getting thrown
    sends the knockback out; a knockback from another player staggers Frank,
    knocks him down or sends him flying, picked at random.

    It carries no damage of its own -- this shares being staggered, not being
    hurt. Turn DamageLink on as well if you want both.
    """
    display_name = "KnockbackLink"
    default = False


class SpitterOnly(Toggle):
    """
    This mode limits Frank to Spitfire only, and it is always active. Other
    weapons are removed from the item pool, leaving only healing items.

    Any location that requires an item is removed in this mode (the bowling
    achievment, firing bullets, etc). The logic for Kent's Day 2 Photoshoot is
    set to require an outtake photo from a survivor, such as Ronald, Gil, or
    Paul (if Psycho goal is chosen, only the Paul photo will be available).

    Obviously enabling this mode will dramatically increase the game's difficulty.
    """
    display_name = "Spitter Only"
    default = False


class DoorRandomizer(Toggle):
    """
    When enabled, door connections throughout the mall are randomized depending on
    the setting chosen below. Each entrance will lead to an unexpected location.

    The randomizer ensures all areas remain reachable and no softlocks occur.

    In-game, a tab in the Archipelago menu allows access to a map showing connections.
    """
    display_name = "Door Randomizer"
    default = False


class DoorRandomizerMode(Choice):
    """
    Controls how doors are randomized when Door Randomizer is enabled.

    Chaos: Doors are fully randomized. Going through door A to reach area B
           does NOT mean the door in B will take you back to A. Navigation
           requires careful attention to the door map. All area keys are
           given at the start of a run when this mode is selected, so the
           entire mall is available from the beginning.

    Paired: Doors are randomized in pairs. If door A leads to area B, then
            a door in B will lead back to A. This creates a more intuitive
            but still randomized layout. Area keys are an option in this mode
            if the Door Locks option is enabled. Otherwise, area keys are
            given at the start and the whole mall will be open right away.
    """
    display_name = "Door Randomizer Mode"
    option_chaos = 0
    option_paired = 1
    default = 1


class DoorLocks(Toggle):
    """
    When enabled (and Door Randomizer is on), moving to a new area will require
    having that area's key. Logic will be updated to reflect your randomized layout.

    Door Locks is only possible with Paired Mode, and it is not compatible with the
    Split Keys option.

    Has no effect if Door Randomizer is disabled.
    """
    display_name = "Door Locks"
    default = False


class RandomizeRooftopServiceHallwayDoors(Toggle):
    """
    When enabled (and Door Randomizer is on), this option adds the doors
    between Rooftop and Warehouse into the randomization pool.

    When disabled (the default), those two doors are left vanilla even with
    Door Randomizer on. The reason for this is that the cutscene with Jessie
    in the Warehouse is required at the start of every run. If these doors are
    randomized, finding the Warehouse to begin with is much more difficult.

    Has no effect if Door Randomizer is disabled.
    """
    display_name = "Randomize Rooftop/Warehouse Doors"
    default = False

class Goal(Choice):
    """
    Determines the victory condition for the game.

    Ending S: Complete all Overtime missions and defeat Brock on the tank.
              This is the full game experience including Overtime Mode.

    Ending A: Solve all of the cases and reach the helipad by 12pm on Day 4.
              Overtime locations are removed from the pool, making for a shorter run.

    Savior:   Rescue a specified number of survivors (see "Number of Survivors"
              below). In ScoopSanity, there will not be any Main Scoop locations.
              If ScoopSanity is off, then Ending S / Ending A locations still exist
              but are filler-only and not the goal.

    Zombie Genocider:
              Kill 53,594 zombies spread across every area of the mall. Forces
              "Zombie Kill Tiers" to Genocide regardless of what it is set to.
              Like Savior, ScoopSanity drops the Main Scoop locations. Without
              ScoopSanity they remain as ordinary checks.

    Psycho:   Kill a specified number of survivors (see "Number of Kills"
              below). Survivors will turn hostile once they are encountered.
              Only kills done by Frank count, not ones from zombies, so setting
              the goal number below 48 leaves a bit of room for missed kills.
              In ScoopSanity, there are no Main Scoops. If ScoopSanity is on,
              Main Scoop locations still exist but will be filler-only.
    """
    display_name = "Goal"
    option_ending_s = 0
    option_ending_a = 1
    option_savior = 2
    option_zombie_genocider = 3
    option_psycho = 4
    default = 1


class NumberOfSurvivors(Range):
    """
    The number of survivors that must be rescued for the Savior goal. Only has
    an effect when Goal is set to Savior.

    The maximum (48) requires rescuing every survivor in the game.
    """
    display_name = "Number of Survivors"
    range_start = 1
    range_end = 48
    default = 35


class ScoopSanity(Toggle):
    """
    When enabled, time freezes after the Entrance Plaza prologue. Scoops are
    added to the item pool and will not begin until the player recieves them.
    Main Scoops will also not trigger until the player reaches their position
    in the randomized order, which is listed in the in-game Archipelago window.

    For example, if the scoop order is 1. Girl Hunting, 2. Hideout, players need
    to wait until they receive "Girl Hunting" as an item and can reach North Plaza
    to trigger it. Even if they receive the "Hideout" item first, they cannot start
    it until all prior main scoops have been completed. Even if you begin a new run,
    Main Scoop progress will be saved and they do not need to be repeated.

    Side Scoops are also items, and they spawn into the world right away. For
    example, receiving "Lovers" spawns Tonya and Ross in Wonderland Plaza. If
    you begin a new run, all Side Scoops will respawn in the mall.

    If ScoopSanity is disabled, time will move normally and the game plays similarly
    to the vanilla experience. Scoops will unlock based on time, not by items.
    """
    display_name = "ScoopSanity"
    default = True


class RandomizeScoopOrder(DefaultOnToggle):
    """
    When enabled (the default), the main scoop order is shuffled. The in-game
    Archipelago window has a Scoop tab that lists the randomized order.

    When disabled, it will instead keep the vanilla order, starting with Backup for
    Brad. You still have to receive each scoop as an item before you can do it.

    Has no effect if ScoopSanity is disabled.
    """
    display_name = "Randomize Scoop Order"


class MainScoopsAnyOrder(Toggle):
    """
    When enabled, Main Scoops can be completed in any order. The player still
    needs to receive the scoop item, and they must also be able to complete it
    before it can be triggered. Main Scoops must be activated manually from the
    in-game Archipelago scoop tab. Only one main scoop can be active at a time.

    Has no effect if ScoopSanity is disabled.
    """
    display_name = "Main Scoops In Any Order"
    default = False


class ExcludeLevelsAbove(Range):
    """
    Level-ups above this value still exist as checks but are prevented from
    holding progression items. This setting can be used to limit how much
    grinding a run may demand.

    50 is max level, so setting it there excludes nothing.
    """

    display_name = "Exclude Levels Above"
    range_start = 25
    range_end = 50
    default = 30


class ExcludeRescuesAbove(Range):
    """
    "Rescue N survivors" checks above this value still exist but will not hold
    progression items. This option prevents the player from having to rescue
    every single survivor in the mall to retrieve an important item.

    The checks are every fifth survivor up to 45, plus one more at 48 for the
    max number of survivors. Setting it to 48 excludes nothing.
    """

    display_name = "Exclude Rescues Above"
    range_start = 5
    range_end = 48
    default = 35


class ZombieKillTiers(Choice):
    """
    Adds "Kill N zombies in <area>" checks, counted per area as you kill.
    This incentivizes combat throughout the entire mall, not just hopping
    into a car and driving over a few thousand in the Maintenance Tunnel.

    Kills can be tracked using the in-game Archipelago Kills tab. Obviously,
    choosing the higher tiers can add a significant grind to your game.

    none:      no area kill checks at all.
    easy:      100 in main plazas and Food Court, 50 in small stores and
               Warehouse, 500 in Leisure Park, 1000 in the Maintenance Tunnel.
    normal:    500 in the main plazas and Food Court, 100 in small stores and
               Warehouse, 1000 in Leisure Park, 2000 in the Maintenance Tunnel.
    nightmare: 1000 in the main plazas and Food Court, 500 in small stores and
               Warehouse, 2000 in Leisure Park, 5000 in the Maintenance Tunnel.
    genocide:  2000 in main plazas and Food Court, 1000 in small stores and
               Warehouse, 10000 in Leisure Park, 27594 in the Maintenance tunnel
               (bringing the total to 53594 kills -- the Zombie Genocider count).
    """
    display_name = "Zombie Kill Tiers"
    option_none = 0
    option_easy = 1
    option_normal = 2
    option_nightmare = 3
    option_genocide = 4
    default = 1


class EnabledTraps(OptionSet):
    """
    Which traps can appear in the pool. Remove any you would rather not get.

    Defaults to all of them. Emptying the list is the same as setting the trap
    percentage to zero.

    Inventory:  Butterfingers (drops everything on the floor), Last Shot
                (everything one hit from breaking), Where'd Your Inventory Go?
                (it all shatters).
    Costume:    Bald, Boxers, Goddamnit, Donut! (heart boxers and bare feet).
    Effects:    Stomach Ache, Zombait, Damage Player, Skipped Arm Day (no
                strength for 30s), Skipped Leg Day (no speed for 30s), Oops
                More Zombies (double spawns for a minute), Potty Mouth (Frank
                swears at you).
    NPC:        Hostile NPC, Special Forces, Convicts Respawn.

    Some traps drop out on their own regardless of this list: Convicts Respawn
    is ScoopSanity-only, since it waits on a scoop item that does not otherwise
    exist.
    """
    display_name = "Enabled Traps"
    valid_keys = {
        "Stomach Ache Trap",
        "Zombait Trap",
        "Skipped Leg Day Trap",
        "Damage Player Trap",
        "Hostile NPC Trap",
        "Special Forces Trap",
        "Convicts Respawn Trap",
        "Butterfingers Trap",
        "Last Shot Trap",
        "Where'd Your Inventory Go? Trap",
        "Bald Trap",
        "Goddamnit, Donut! Trap",
        "Boxers Trap",
        "Skipped Arm Day Trap",
        "Oops More Zombies Trap",
        "Potty Mouth Trap",
    }
    default = frozenset(valid_keys)


class SpecialForcesMode(Choice):
    """
    Puts the Special Forces in the mall prior to Overtime.

    Be careful with this setting. Depending on which option you choose
    and how unlucky you are, this could mean having Special Forces in
    the Warehouse when you have few weapons and only early-game stats.

    This is only compatible with ScoopSanity. Without it, this does nothing.

    none:      the default. Special Forces will only be present in Overtime.
    item:      an AP item turns them on, and they will be in every area of
               the mall until you complete both "Kill 10 Special Forces" and
               "Hella Copter - Shoot down the Special Forces Helicopter".
               Once those locations are completed, Special Forces will leave.
    permanent: Special Forces will be on for the whole run, from the Jessie
               cutscene onward. This is a significant increase in difficulty,
               especially early game in the Warehouse. Caution is advised.
    """
    display_name = "Special Forces Mode"
    option_none = 0
    option_item = 1
    option_permanent = 2
    default = 0


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
        Level-ups grant skills/stats normally. AP skill/stat items are
        NOT in the pool. Use this if you do not want to change Frank's
        progression.

    replace:
        Level-ups rewards are suppressed (re-overridden each level).
        AP items are the only source of skills and stats. The default.

    extra_buffs_only:
        Level-ups grants rewards normally, AP items ONLY give the over-vanilla
        extras. Best paired with Enable Extra Stat Buffs = true.
    """
    display_name = "Vanilla Progression"
    option_vanilla_only = 0
    option_replace = 1
    option_extra_buffs_only = 2
    default = 1


class TrapPercentage(Range):
    """
    Percentage of filler-item slots that become traps. 0 = no traps,
    10 = default, 50 = aggressive, 100 = chaos. The selected
    fraction of filler slots is dedicated to traps and round-robin
    distributed across all trap types so they each appears at least once
    before any repeats.
    """
    display_name = "Trap Percentage"
    range_start = 0
    range_end = 100
    default = 10


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


class CultLimited(Toggle):
    """
    In ScoopSanity, cultists will appear after beginning either "The Cult" or
    "A Strange Group", and they will remain in the mall indefinitely.

    If this option is enabled, the cultists will instead disappear from the mall
    after Sean is killed like they do in the regular game. However, they will
    still be clustered outside the boss room in Colby's movie theater so you
    can complete any cult-related checks with them there.

    This option has no effect if ScoopSanity is off.
    """
    display_name = "Cult Limited"
    default = False


class NumberOfKills(Range):
    """
    The number of survivors that must be killed for the Psycho goal. Only has
    an effect when Goal is set to Psycho.

    All 48 survivors in the mall are targets, but only kills you land yourself
    count. A survivor the zombies get to first is gone, so a number close to
    48 leaves very little room for accidents.
    """
    display_name = "Number of Kills"
    range_start = 5
    range_end = 48
    default = 25


class OvertimeProgressionGating(Toggle):
    """
    This option adds two key items that are required to complete Overtime
    mode. Isabela will not leave the mall without the Clock Tower Tunnel
    Key, and the military humvee will not start without the Humvee Key.

    This option has no effect unless the goal is Ending S.
    """
    display_name = "Overtime Progression Gating"


class NightModeEnabled(Toggle):
    """
    When enabled, zombies behave as if it is always night, regardless of
    the in-game time. The night-side parameters of `ZombieDefinitionUserData`
    (HoldMissRate, HoldBlockRate, HoldBlockFallRate) are written over the
    day-side fields, and `ZombieManager.isHourNight()` is always on.

    Effects:
      * Higher chance for grabs to land (Day 5% miss → Night 15% miss)
      * Higher chance for zombies to block counterattacks (Day 45% → Night 55%)
      * Slightly more aggressive overall behavior

    The glowing red eyes come with it. Every zombie gets them, including ones
    that spawn later, so the mall looks like night even in daylight.

    With ScoopSanity on, the mall lighting goes to night as well. This begins once
    you have met Jessie in the warehouse.

    Without ScoopSanity the lighting is left alone. The clock is still running
    in that mode and the game cycles into night on its own. Only behavior changes.
    """
    display_name = "Night Mode"
    default = False


class CarKeys(Toggle):
    """
    When enabled, the mall's drivable vehicles stay locked until you receive
    their key. Five keys cover every vehicle:

      * Sedan Key          — the white sedan in the Maintenance Tunnel
      * Sports Car Key     — the red sports car in Leisure Park
      * Truck Key          — the box truck in the Maintenance Tunnel
      * Motorcycle Key     — both motorcycles, in Leisure Park and (after
                             Girl Hunting) North Plaza
      * Convict Humvee Key — the convicts' vehicle in Leisure Park

    For locations that require vehicles, logic is updated to reflect these
    items. "Kill N zombies by vehicle" checks take any car, and "Jump a
    vehicle 50 feet" needs the sedan or the sports car.

    If Zombie Kill Tiers is active, the per-area zombie kill checks in
    Leisure Park and the Maintenance Tunnel also require a car in that
    region.

    Restricted Item Mode turns this on automatically. It can also be run on
    its own, without any other item restrictions.

    The Overtime military humvee is unaffected; it has its own key under
    Overtime Progression Gating.
    """
    display_name = "Car Keys"
    default = False


class ZombieSpawnMultiplier(Range):
    """
    Multiplies the number of zombies each area spawns.

    1 is vanilla and 5 is the maximum. At 5 an area that normally holds a
    hundred zombies will hold roughly five hundred.

    This costs performance. Every extra zombie is more to draw, animate and
    path, so higher values are not recommended on lower-end machines. If the
    frame rate suffers, lower the value.
    """
    display_name = "Zombie Spawn Multiplier"
    range_start = 1
    range_end = 5
    default = 1


class HardcoreZombiesEnabled(Toggle):
    """
    When enabled, zombies become significantly more dangerous on top of
    Night Mode. Turning this on without enabling Night Mode auto-enables it.

    Amplified parameters:
      * Bite damage: -1000 -> -3000 HP per tick (3×)
      * Downed-bite damage: -3000 > -9000 HP per tick (3×)
      * Scratch damage rate: 3.5 -> 7.0 (2×)
      * Player aggro radius: 9 -> 25 units (much harder to sneak past)
      * General aggro radius: 13 -> 35 units
      * NPC aggro radius: 10 -> 25 units (zombies notice survivors faster)
      * Grab escape mash count: 15 -> 30 (2× harder to escape)
      * Mash decay rate: 0.02 -> 0.05 (gauge drains faster while mashing)

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
    Each area transition will count toward the "Change into 5 different
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
      * Walk on N Treadmills (1 to 6, plus All Treadmills)         -- Al Fresca
      * Destroy N Sandbags (1 to 4, plus All Sandbags)             -- Al Fresca
      * Spin N Display Racks (1 to 4, plus All Display Racks)      -- Entrance
      * Break N Food Court Wall Plates (1 to 18, no separate "all")
      * Microwave N Items (1 to 9, plus Microwave All Items)
      * Heat N Pans (1 to 5, plus Heat All Pans)

    Logic gating: each check requires the relevant region. In Restricted Item Mode,
    microwave checks additionally require Uncooked Pizza or Raw Meat, as well as
    access to Seon's. Stove checks require Frying Pan.
    """
    display_name = "PP-Bonus Locations"


class DLCOutfitsEnabled(Toggle):
    """
    When enabled, the costume randomizer's Body pool includes the 20 DLC
    outfit IDs (43 to 62) on top of the 43 regular Body costumes. DLC IDs
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


class PPStickersFiller(Toggle):
    """
    When enabled, PP stickers and their milestone checks (such as
    "Photograph 10 PP Stickers") will still exist but will only have filler.

    This option pairs well with certain Door Randomizer options. If the entire
    mall is accessible from the start, then PP stickers alone will put 108
    locations into early spheres of the multiworld.
    """
    display_name = "PP Stickers Filler"
    default = False


class OvertimeChecksFiller(Toggle):
    """
    When enabled, every check in Overtime still exists but will only ever hold
    filler, so no progression is placed past the point of no return. This means
    that no key items will be placed at the very end of your game.

    Has no effect on Ending A, which drops the Overtime checks entirely.
    """
    display_name = "Overtime Checks Filler"
    default = False


class SplitKeys(Toggle):
    """
    Normally, an area key opens all doors leading into an area. The 'Wonderland
    Plaza Key' opens the doors to it from both North Plaza and the Food Court.

    In Split Keys, each individual entrance has its own key. Entering Wonderland
    Plaza from North Plaza would require the 'North Plaza - Wonderland Plaza Key'. Entering
    from Food Court, however, would require the 'Food Court - Wonderland Plaza Key'.

    Keys work in both directions. The 'Leisure Park - Paradise Plaza Key' opens the door from
    both Leisure Park into Paradise Plaza and from Paradise Plaza into Leisure Park.

    Each key is named alphabetically using full area names, such as
    "Crislip's Home Saloon - North Plaza Key", "Al Fresca Plaza - Food Court Key", etc.

    This makes the mall even more mazelike, increasing the difficulty. It also means
    that, even if you already have access to an area through another path, each key
    you are sent still matters because they open new shortcuts.

    Selecting this with 'Door Randomizer' and 'Door Locks' swaps back to the
    area keys for that run. Door Locks gates a door by the key for the area it
    now leads to, which a per-door key cannot name once the doors have moved.
    """
    display_name = "Split Keys"
    default = False
    

# ---------------------------------------------------------------------------
# Location pickers without the KillSanity names (#60)
# ---------------------------------------------------------------------------
# The Options Creator lists every location in the datapackage for a location
# option and filters it by substring as the player types, with no limit. With
# KillSanity that is 54,000 names, and "Kil" or an area name matched tens of
# thousands and hung it. It only pulls the datapackage when the option says
# to verify location names, so these offer their own list instead: every
# location except the KillSanity ones, plus a group per area and one for all
# of them. A YAML may still name any location; verify() checks them against
# the world exactly as the stock options do.
_OFFERED_LOCATIONS = sorted(
    {loc.name for table_name, table in location_tables.items()
     if table_name != "Kill Sanity" for loc in table}
    | set(kill_sanity_location_groups))


class _BoundedLocationSet:
    verify_location_name = False   # keeps the Creator off the full datapackage
    convert_name_groups = True
    valid_keys = _OFFERED_LOCATIONS

    def verify_keys(self) -> None:
        pass   # any real location is allowed; verify() checks it below

    def verify(self, world, player_name, plando_options) -> None:
        super().verify(world, player_name, plando_options)
        expanded = set()
        for name in self.value:
            expanded |= world.location_name_groups.get(name, {name})
        for name in expanded:
            if name not in world.location_names:
                raise Exception(f"Location '{name}' from option '{self}' is not a valid "
                                f"location name from '{world.game}'.")
        self.value = expanded


class DRExcludeLocations(_BoundedLocationSet, ExcludeLocations):
    __doc__ = ExcludeLocations.__doc__
    rich_text_doc = True


class DRPriorityLocations(_BoundedLocationSet, PriorityLocations):
    __doc__ = PriorityLocations.__doc__
    rich_text_doc = True


class DRStartLocationHints(_BoundedLocationSet, StartLocationHints):
    __doc__ = StartLocationHints.__doc__
    rich_text_doc = True


@dataclass
class DROption(PerGameCommonOptions):
    exclude_locations: DRExcludeLocations
    priority_locations: DRPriorityLocations
    start_location_hints: DRStartLocationHints
    start_inventory_from_pool: StartInventoryPool
    guaranteed_items: GuaranteedItemsOption
    death_link: DeathLink
    damage_link: DamageLink
    damage_link_group: DamageLinkGroup
    knockback_link: KnockbackLink
    goal: Goal
    number_of_survivors: NumberOfSurvivors
    number_of_kills: NumberOfKills
    scoop_sanity: ScoopSanity
    randomize_scoop_order: RandomizeScoopOrder
    main_scoops_any_order: MainScoopsAnyOrder
    zombie_kill_tiers: ZombieKillTiers
    kill_sanity: KillSanity
    pp_bonus_locations: PpBonusLocations
    exclude_levels_above: ExcludeLevelsAbove
    exclude_rescues_above: ExcludeRescuesAbove
    overtime_checks_filler: OvertimeChecksFiller
    pp_stickers_filler: PPStickersFiller
    door_randomizer: DoorRandomizer
    door_randomizer_mode: DoorRandomizerMode
    door_locks: DoorLocks
    randomize_rooftop_service_hallway_doors: RandomizeRooftopServiceHallwayDoors
    restricted_item_mode: RestrictedItemMode
    car_keys: CarKeys
    split_keys: SplitKeys
    overtime_progression_gating: OvertimeProgressionGating
    exclude_overpowered_items: ExcludeOverpoweredItems
    enable_skill_items: EnableSkillItems
    enable_stat_items: EnableStatItems
    enable_extra_stat_buffs: EnableExtraStatBuffs
    vanilla_progression: VanillaProgression
    enabled_traps: EnabledTraps
    trap_percentage: TrapPercentage
    hostile_survivor_count_min: HostileSurvivorCountMin
    hostile_survivor_count_max: HostileSurvivorCountMax
    cult_limited: CultLimited
    special_forces_mode: SpecialForcesMode
    spitter_only: SpitterOnly
    night_mode_enabled: NightModeEnabled
    hardcore_zombies_enabled: HardcoreZombiesEnabled
    zombie_spawn_multiplier: ZombieSpawnMultiplier    
    random_starting_costume: RandomStartingCostume
    costume_chaos_mode: CostumeChaosMode
    dlc_outfits_enabled: DLCOutfitsEnabled
    
dr_option_groups = [
    OptionGroup("Goal and Location Settings",
        [
            Goal,
            NumberOfSurvivors,
            NumberOfKills,
            ScoopSanity,
            RandomizeScoopOrder,
            MainScoopsAnyOrder,
            ZombieKillTiers,
            KillSanity,
            PpBonusLocations,
            ExcludeLevelsAbove,
            ExcludeRescuesAbove,
            OvertimeChecksFiller,
            PPStickersFiller,
        ],
    ),
    OptionGroup(
        "Door Randomizer Settings",
        [
            DoorRandomizer,
            DoorRandomizerMode,
            DoorLocks,
            RandomizeRooftopServiceHallwayDoors
        ],
    ),
    OptionGroup(
        "Item and Key Settings",
        [
            RestrictedItemMode,
            CarKeys,
            SplitKeys,
            OvertimeProgressionGating,
            ExcludeOverpoweredItems,
        ],
    ),
    OptionGroup(
        "Skill and Stat Settings",
        [
            EnableSkillItems,
            EnableStatItems,
            EnableExtraStatBuffs,
            VanillaProgression,
        ],
    ),
    OptionGroup(
        "Trap Settings",
        [
            EnabledTraps,
            TrapPercentage,
            HostileSurvivorCountMin,
            HostileSurvivorCountMax,
        ],
    ),
    OptionGroup(
        "Difficulty Settings",
        [
            CultLimited,
            SpecialForcesMode,
            SpitterOnly,
            NightModeEnabled,
            HardcoreZombiesEnabled,
            ZombieSpawnMultiplier,
        ],
    ),
    OptionGroup(
        "Costume Settings",
        [
            RandomStartingCostume,
            CostumeChaosMode,
            DLCOutfitsEnabled,
        ],
    ),
    OptionGroup(
        "Item & Location Options",
        [
            DRStartLocationHints,
            DRExcludeLocations,
            DRPriorityLocations,
        ],
        True,
    ),
]
