# Options

Set these in your `Dead Rising Deluxe Remaster.yaml`. The key is the name you write in the file. Every option's full description is in the template that the Archipelago Launcher makes (**Generate Template Options**).

Common ones:

```yaml
Dead Rising Deluxe Remaster:
  goal: ending_a
  scoop_sanity: true
  music_shuffle: false
```

Music Shuffle is described in [Custom music](MUSIC.md). The goals are described in [Getting started](GETTING_STARTED.md).

| Key | Name | Default | What it does |
|---|---|---|---|
| `exclude_locations` | Exclude Locations |  | Locations that will not hold progression items (standard Archipelago option). |
| `priority_locations` | Priority Locations |  | Locations that will hold progression items (standard Archipelago option). |
| `start_location_hints` | Start Location Hints |  | Locations hinted at the start (standard Archipelago option). |
| `start_inventory_from_pool` | Start Inventory From Pool |  | Items you start with that are taken from the pool (standard Archipelago option). |
| `guaranteed_items` | Guaranteed Items |  | Guarantees that the specified items will be in the item pool |
| `death_link` | Death Link | false | Share deaths with other DeathLink players (standard Archipelago option). |
| `damage_link` | DamageLink | false | Share damage with the rest of the multiworld. |
| `damage_link_group` | Damage Link Group |  | Damage Link only applies to players with an identical Group name. |
| `knockback_link` | KnockbackLink | false | Share being knocked about with the rest of the multiworld. |
| `trap_link` | Trap Link | false | Share traps with the rest of the multiworld, the Trap Link protocol that Sonic Adventure 2, Super Mario World and others already speak. |
| `goal` | Goal | ending_a | Victory condition: `ending_s`, `ending_a`, `savior`, `zombie_genocider` or `psycho`. |
| `number_of_survivors` | Savior Survivor Goal | 35 | The number of survivors that must be rescued for the Savior goal. |
| `number_of_kills` | Psycho Kill Goal | 25 | The number of survivors that must be killed for the Psycho goal. |
| `scoop_sanity` | ScoopSanity | true | When enabled, time freezes after the Entrance Plaza prologue. |
| `scoopsanity_order` | Scoopsanity Order | shuffled | How the main scoops are ordered when ScoopSanity is on. |
| `randomize_scoop_order` | Randomize Scoop Order | true | Replaced by Scoopsanity Order. |
| `main_scoops_any_order` | Main Scoops In Any Order | false | Replaced by Scoopsanity Order. |
| `zombie_kill_tiers` | Zombie Kill Tiers | easy | Adds "Kill N zombies in <area>" checks, counted per area as you kill. |
| `kill_sanity` | KillSanity | false | Every zombie kill in each area is its own check, up to the number specified in the Zombie Kill Tier. |
| `pp_bonus_locations` | PP-Bonus Locations | true | Adds extra AP location checks tied to PP-bonus events that DRAP detects via the MsgEvents watcher. |
| `exclude_levels_above` | Exclude Levels Above | 30 | Level-ups above this value still exist as checks but are prevented from holding progression items. |
| `exclude_rescues_above` | Exclude Rescues Above | 35 | "Rescue N survivors" checks above this value still exist but will not hold progression items. |
| `overtime_checks_filler` | Overtime Checks Filler | false | When enabled, every check in Overtime still exists but will only ever hold filler, so no progression is placed past the point of no return. |
| `pp_stickers_filler` | PP Stickers Filler | false | When enabled, PP stickers and their milestone checks (such as "Photograph 10 PP Stickers") will still exist but will only have filler. |
| `extra_pp_stickers` | Extra PP Stickers | false | Adds 40 extra PP stickers to the mall, in places the vanilla game has none. |
| `door_randomizer` | Door Randomizer | false | When enabled, door connections throughout the mall are randomized depending on the setting chosen below. |
| `door_randomizer_mode` | Door Randomizer Mode | paired | Controls how doors are randomized when Door Randomizer is enabled. |
| `door_locks` | Door Locks | false | When enabled (and Door Randomizer is on), moving to a new area will require having that area's key. |
| `randomize_rooftop_service_hallway_doors` | Randomize Rooftop/Warehouse Doors | false | When enabled (and Door Randomizer is on), this option adds the doors between Rooftop and Warehouse into the randomization pool. |
| `restricted_item_mode` | Restricted Item Mode | false | When enabled, players cannot pick up items in the world unless they have been sent to them by the Archipelago server. |
| `item_sanity` | ItemSanity | false | Picking up each kind of item for the first time is a check: the first chair, the first Katana, the first carton of milk off a shelf, and so on. |
| `car_keys` | Car Keys | false | When enabled, the mall's drivable vehicles stay locked until you receive their key. |
| `camera_item` | Camera Item | false | The camera becomes an item. |
| `split_keys` | Split Keys | false | Normally, an area key opens all doors leading into an area. |
| `start_with_all_keys` | Start With Every Door Key | false | You start with every door key, so the whole mall is open from the start. |
| `overtime_progression_gating` | Extra Overtime Keys | false | Adds two key items that are required to complete Overtime mode. |
| `exclude_overpowered_items` | Exclude Overpowered Items | false | When enabled, removes a curated set of items widely considered too powerful from the AP item pool: * Book [Infinite Durability] (weapons never... |
| `enable_skill_items` | Enable Skill Items | true | When enabled, Frank's 21 combat skills (Jump Kick, Suplex, etc.) become AP items in the pool. |
| `enable_stat_items` | Enable Stat Items | true | When enabled, Progressive stat upgrades become AP items in the pool: Health (+1000), Attack (+25%), Throw (+25), Item Slot (+1), Run Level (+1). |
| `enable_extra_stat_buffs` | Enable Extra Stat Buffs | false | When enabled, additional stat-upgrade items push past vanilla L50 caps: * +4 Health (cap 16000) * +10 Attack (cap 500%) * +8 Throw (cap 400) * +3... |
| `vanilla_progression` | Vanilla Progression | replace | Controls how Frank's natural level-up rewards interact with AP items. |
| `enabled_traps` | Enabled Traps | all traps | Which traps can appear in the pool. |
| `trap_percentage` | Trap Percentage | 10 | Percentage of filler-item slots that become traps. |
| `hostile_survivor_count_min` | Hostile NPC Count Min | 1 | Minimum number of hostile NPCs spawned per Hostile NPC Trap. |
| `hostile_survivor_count_max` | Hostile NPC Count Max | 3 | Maximum number of hostile NPCs spawned per Hostile NPC Trap. |
| `cult_limited` | Cult Limited | false | In ScoopSanity, cultists will appear after beginning either "The Cult" or "A Strange Group", and they will remain in the mall indefinitely. |
| `special_forces_mode` | Special Forces Mode | none | Puts the Special Forces in the mall prior to Overtime. |
| `spitter_only` | Spitter Only | false | This mode limits Frank to Spitfire only. |
| `night_mode_enabled` | Night Mode | false | When enabled, zombies behave as if it is always night, regardless of the in-game time. |
| `hardcore_zombies_enabled` | Hardcore Zombies | false | When enabled, zombies become significantly more dangerous on top of Night Mode. |
| `zombie_spawn_multiplier` | Zombie Spawn Multiplier | 1 | Multiplies the number of zombies each area spawns. |
| `infinity_drain` | Infinity Drain | false | Infinity Mode's health drain, in a normal run. |
| `infinity_drain_rate` | Infinity Drain Rate | 100 | Seconds for the Infinity Drain to empty one health block. |
| `random_starting_costume` | Random Starting Costume | false | When enabled, Frank's outfit is randomized once at the start of each play session (after the save loads or on a fresh new game). |
| `costume_chaos_mode` | Costume Chaos Mode | false | When enabled, Frank's outfit is re-randomized on every area transition (i.e. |
| `dlc_outfits_enabled` | DLC Outfits Enabled | false | When enabled, the costume randomizer's Body pool includes the 20 DLC outfit IDs (43 to 62) on top of the 43 regular Body costumes. |
| `music_shuffle` | Music Shuffle | false | Shuffles the game's music in two groups. |
