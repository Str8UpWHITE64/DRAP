import typing
from dataclasses import dataclass
from Options import Toggle, DefaultOnToggle, Option, Range, Choice, ItemDict, DeathLink, PerGameCommonOptions, StartInventoryPool, OptionGroup, OptionSet


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


class DamageLink(Toggle):
    """
    Share damage with the rest of the multiworld. Taking a hit sends damage
    out; damage from another player takes health here.

    One damage point is one of Frank's health blocks, so a point costs the
    same fraction of his health however far he has levelled. Small hits are
    added up rather than sent one at a time.

    Damage arriving this way CAN kill, and death runs the game's own path, so
    it behaves like any other death (including DeathLink, if that is on too).
    """
    display_name = "DamageLink"
    default = False


class SpitterOnly(Toggle):
    """
    Spitter Only. No weapon ever reaches the item pool, so with Restricted
    Item Mode there is nothing to pick up and swing -- the spit is the whole
    arsenal. Melee is left barely able to scratch a zombie.

    Turning this on forces Restricted Item Mode on, because without it the
    mall is still full of weapons to grab.

    The checks that are nothing but a weapon -- the bullet counts, bowling,
    golf, the parasol and the RPG -- are dropped, since no amount of spitting
    finishes them. A few things that happen to be weapons stay in: the fire
    extinguisher Paul is waiting on, Kent's masks, the frying pan the stoves
    need and Isabela's queen.
    """
    display_name = "Spitter Only"
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


class DoorLocks(Toggle):
    """
    When enabled (and Door Randomizer is on), the area keys still lock doors.
    Normally every key is given to you at the start when doors are randomized,
    because the logic tracks the vanilla layout rather than the shuffled one.
    With this on, the logic follows the doors where they actually go and a door
    is locked by the key for wherever it now leads.

    Paired mode only. A door is locked by the key for the area it now leads to,
    so this needs the area keys. Selecting 'Door Randomizer', 'Door Locks' and
    'Split Keys' together swaps the per-door keys out and uses the area keys
    for that run.

    Has no effect if Door Randomizer is disabled.
    """
    display_name = "Door Locks"
    default = False


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
              "Number of Survivors" below). In ScoopSanity, there will not be any
              Main Scoop locations. If ScoopSanity is off, then Ending S / Ending A
              locations still exist as normal but are filler-only and not the goal.

    Zombie Genocider:
              Kill 53,594 zombies spread across every area of the mall. Forces
              "Zombie Kill Tiers" to genocide whatever it is set to. Like
              Savior, ScoopSanity drops the Main Scoop locations; without
              ScoopSanity they stay as ordinary checks.

    Psycho:   Savior turned inside out. Every survivor becomes a target: their
              "Rescue" checks are replaced by "Kill" checks, and you win by
              killing the number set in "Number of Kills" below. Survivors turn
              hostile once their scoop starts, and only kills you land yourself
              count -- one lost to the zombies is a target gone for good, so
              set the number well under the 48 in the mall.
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


class RandomizeScoopOrder(DefaultOnToggle):
    """
    When enabled (the default), the main scoop chain is shuffled and you
    receive the scoops in that new order.

    When disabled, the chain keeps its vanilla order, starting with Backup for
    Brad. You still have to receive each scoop as an item before you can do it,
    and the level requirements per position still apply, so the run is paced
    the same as a randomized one.

    Has no effect if ScoopSanity is disabled.
    """
    display_name = "Randomize Scoop Order"


class MainScoopsAnyOrder(Toggle):
    """
    When enabled, any main scoop you have received can be started as soon as
    you can reach it, instead of waiting for its turn in the chain. Activate
    the one you want from the Scoops window; only one runs at a time.

    The per-position level requirements do not apply in this mode. They exist
    to spread a fixed chain across the run, which choosing the order already
    does, so a scoop is available as soon as you can reach it.

    Has no effect if ScoopSanity is disabled.
    """
    display_name = "Main Scoops In Any Order"
    default = False


class ExcludeLevelsAbove(Range):
    """
    Level-ups above this value still exist as checks but are prevented from
    holding progression items, which limits how much grinding a run can
    demand.

    50 is max level, so setting it there excludes nothing.
    """

    display_name = "Exclude Levels Above"
    range_start = 25
    range_end = 50
    default = 30


class ExcludeRescuesAbove(Range):
    """
    "Rescue N survivors" checks above this value still exist as checks but are
    prevented from holding progression items. The later ones need most of the
    mall rescued, so an item behind one sits at the end of the run.

    The checks are every fifth survivor up to 45, plus 48 -- every survivor in
    the mall. Setting it to 48 excludes nothing.
    """

    display_name = "Exclude Rescues Above"
    range_start = 5
    range_end = 48
    default = 35


class ZombieKillTiers(Choice):
    """
    Adds "Kill N zombies in <area>" checks, counted per area as you kill.

    Right now the only reason to kill zombies anywhere in particular is the
    Maintenance Tunnel, where a car makes the global kill counts trivial.
    These spread the killing across the mall.

    none:      no area kill checks at all.
    easy:      the default. Stops at 100 in the plazas, 50 in the small
               stores, 500 in Leisure Park and 1000 in the Maintenance
               Tunnel -- enough to get you fighting around the mall without
               becoming a grind.
    normal:    one for each main plaza, two in Leisure Park, three in the
               Maintenance Tunnel. The small stores get none.
    nightmare: two per main plaza, one per small store, and more outdoors.
    genocide:  every threshold, up to 28594 in the Maintenance Tunnel. Clearing
               all of them is 53594 kills -- the Zombie Genocider count.
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
    Effects:    Stomach Ache, Zombait, Slow, Damage Player, Skipped Arm Day
                (no strength for 30s), Oops More Zombies (double spawns for a
                minute), Potty Mouth (Frank swears at you).
    NPC:        Hostile NPC, Special Forces, Convicts Respawn.

    Some traps drop out on their own regardless of this list: Convicts Respawn
    is ScoopSanity-only, since it waits on a scoop item that does not otherwise
    exist.
    """
    display_name = "Enabled Traps"
    valid_keys = {
        "Stomach Ache Trap",
        "Zombait Trap",
        "Slow Trap",
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
    Puts the Overtime Special Forces in the mall during the 72 hours.

    They are the soldiers who normally only show up after the story ends.
    Zombies stay where they are -- the soldiers are added on top, not swapped
    in -- and the mall's background music is silenced while they are around.

    Requires ScoopSanity -- without it this does nothing.

    Nothing happens until you have talked to Jessie, the same as every scoop.

    none:      the default. Vanilla -- no Special Forces before Overtime.
    item:      an AP item turns them on. They leave once you have both
               "Kill 10 Special Forces" and "Hella Copter - Shoot down the
               Special Forces Helicopter", so the checks are what sends them
               home. Those two move into the main pool for this mode.
    permanent: on for the whole run, from Jessie onward.
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
    10 = default, 50 = aggressive, 100 = chaos. The selected
    fraction of filler slots is dedicated to traps and round-robin
    distributed across all six trap types (Stomach Ache Trap, Zombait
    Trap, Slow Trap, Damage Player Trap, Hostile NPC Trap, Special
    Forces Trap) so every type appears at least once before any
    repeats.
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
    In ScoopSanity, cultists will appear after beginning either 'The Cult' or
    'A Strange Group', and they will remain in the mall indefinitely.

    If this option is enabled, the cult will instead disappear from the mall
    after Sean is killed like they do in the regular game. However, they will
    still be clustered outside the boss room in Colby's movie theater so you
    can complete any cult-related checks.

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


class SurvivorRespawn(DefaultOnToggle):
    """
    A survivor's "Rescue" check can only be sent when they reach the Security
    Room, so if a survivor dies that location cannot be collected unless the player
    restarts the run and rescues the survivor again.

    With this option enabled, a survivor who dies during a rescue reappears at
    the spot they originally spawned, so you can go back and pick them up
    again. They return already following you, because survivors who normally
    spawn as part of a group can misbehave when spawned on their own.

    Turn this off for the vanilla rule, where a dead survivor is gone for good
    until a new run starts.

    This option has no effect if ScoopSanity is off.
    """
    display_name = "Survivor Respawn"


class OvertimeProgressionGating(Toggle):
    """
    Adds gates to Overtime so Ending S is a longer run than Ending A rather
    than the same run with a different ending.

    With this off, Overtime plays as it always has. Its checks still exist --
    the queens, the gates in the tunnel, the suppressant hand-ins and the rest --
    they are simply not held back by anything.

    With this on, two things are gated behind items the multiworld has to send
    you. Isabela will not leave for the tunnel without the Clock Tower Tunnel
    Key, and the Humvee will not start without the Humvee Key.

    The suppressant ingredients are not gated either way -- they are picked up
    normally and their checks fire when you collect them.

    This option has no effect unless the goal is Ending S.
    """
    display_name = "Overtime Progression Gating"


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

    The glowing red eyes come with it. Every zombie gets them, including ones
    that spawn later, so the mall looks like night even in daylight.

    With ScoopSanity on, the mall lighting goes to night as well — the sun
    goes down and the interior lights come up — starting once you have met
    Jessie in the warehouse, so the prologue plays in its intended daylight.

    Without ScoopSanity the lighting is left alone. The clock is still running
    in that mode and the game cycles into night on its own, so there is no
    reason to override it.
    """
    display_name = "Night Mode"
    default = False


class CarKeys(Toggle):
    """
    When enabled, the mall's drivable vehicles stay locked until the
    multiworld sends you their key. Five keys cover every vehicle:

      * Sedan Key          — the white sedan in the Maintenance Tunnels
      * Sports Car Key     — the red sports car in Leisure Park
      * Truck Key          — the box truck in the Maintenance Tunnels
      * Motorcycle Key     — both motorcycles, in Leisure Park and (after
                             Girl Hunting) North Plaza
      * Convict Humvee Key — the convicts' vehicle in Leisure Park

    The vehicle challenges move behind the keys they can be done with: the
    "Kill N zombies by vehicle" checks take any car, and "Jump a vehicle 50
    feet" needs the sedan or the sports car.

    The per-area zombie kill checks in Leisure Park and the Maintenance
    Tunnels also want a car once the counts climb — from 1,000 and 2,000
    respectively. The convicts' Humvee never counts toward logic, since it
    only exists after the convicts have been dealt with.

    Restricted Item Mode turns this on automatically. It can also be run on
    its own, without item restriction.

    The Overtime Humvee is unaffected; it has its own key under Overtime
    Progression Gating.
    """
    display_name = "Car Keys"
    default = False


class ZombieSpawnMultiplier(Range):
    """
    Multiplies the number of zombies each area spawns.

    1 is vanilla and 5 is the maximum. At 5 an area that normally holds a
    hundred zombies will hold roughly five hundred, which changes how you move
    through the mall — crowds become walls, and routes that were a jog become
    a fight.

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


class PPStickersFiller(Toggle):
    """
    When enabled, PP stickers and their milestone checks (such as
    "Photograph 10 PP Stickers") will still exist but will only have filler.
    """
    display_name = "PP Stickers Filler"
    default = False


class OvertimeChecksFiller(Toggle):
    """
    When enabled, every check in Overtime still exists but will only ever hold
    filler, so no progression is placed past the point of no return.

    The Overtime items are untouched: the Clock Tower Tunnel Key and the Humvee
    Key are still progression and can still be what the multiworld sends you.
    This only stops Overtime's own checks from holding anything you need.

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
    

@dataclass
class DROption(PerGameCommonOptions):
    start_inventory_from_pool: StartInventoryPool
    goal: Goal
    number_of_survivors: NumberOfSurvivors
    number_of_kills: NumberOfKills
    guaranteed_items: GuaranteedItemsOption
    death_link: DeathLink
    damage_link: DamageLink
    restricted_item_mode: RestrictedItemMode
    spitter_only: SpitterOnly
    door_randomizer: DoorRandomizer
    door_randomizer_mode: DoorRandomizerMode
    door_locks: DoorLocks
    randomize_rooftop_service_hallway_doors: RandomizeRooftopServiceHallwayDoors
    scoop_sanity: ScoopSanity
    randomize_scoop_order: RandomizeScoopOrder
    main_scoops_any_order: MainScoopsAnyOrder
    exclude_levels_above: ExcludeLevelsAbove
    exclude_rescues_above: ExcludeRescuesAbove
    zombie_kill_tiers: ZombieKillTiers
    special_forces_mode: SpecialForcesMode
    enabled_traps: EnabledTraps
    enable_skill_items: EnableSkillItems
    enable_stat_items: EnableStatItems
    enable_extra_stat_buffs: EnableExtraStatBuffs
    vanilla_progression: VanillaProgression
    exclude_overpowered_items: ExcludeOverpoweredItems
    overtime_checks_filler: OvertimeChecksFiller
    trap_percentage: TrapPercentage
    hostile_survivor_count_min: HostileSurvivorCountMin
    hostile_survivor_count_max: HostileSurvivorCountMax
    cult_limited: CultLimited
    survivor_respawn: SurvivorRespawn
    overtime_progression_gating: OvertimeProgressionGating
    night_mode_enabled: NightModeEnabled
    hardcore_zombies_enabled: HardcoreZombiesEnabled
    zombie_spawn_multiplier: ZombieSpawnMultiplier
    car_keys: CarKeys
    random_starting_costume: RandomStartingCostume
    costume_chaos_mode: CostumeChaosMode
    dlc_outfits_enabled: DLCOutfitsEnabled
    pp_bonus_locations: PpBonusLocations
    pp_stickers_filler: PPStickersFiller
    split_keys: SplitKeys

dr_option_groups = [
    OptionGroup("Goal and Location Settings",
        [
            Goal,
            NumberOfSurvivors,
            NumberOfKills,
            ScoopSanity,
            RandomizeScoopOrder,
            MainScoopsAnyOrder,
            PpBonusLocations,
            ExcludeLevelsAbove,
            ExcludeRescuesAbove,
            ZombieKillTiers,
            SpecialForcesMode,
            PPStickersFiller,
            OvertimeProgressionGating,
            OvertimeChecksFiller,
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
        "Item Settings",
        [
            RestrictedItemMode,
            SpitterOnly,
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
            SurvivorRespawn,
            SplitKeys,
            NightModeEnabled,
            HardcoreZombiesEnabled,
            ZombieSpawnMultiplier,
            CarKeys,
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
]
