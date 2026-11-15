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
| `guaranteed_items` | Guaranteed Items |  | Items that are guaranteed to be in the item pool, with the number of copies set for each. See below. |
| `death_link` | Death Link | false | Share deaths with other DeathLink players (standard Archipelago option). |
| `damage_link` | DamageLink | false | Share damage with the rest of the multiworld. Eighty damage points are one health block, and one packet is capped at one block. |
| `damage_link_group` | Damage Link Group |  | Damage Link only applies to players with an identical Group name. |
| `knockback_link` | KnockbackLink | false | Share being knocked about with the rest of the multiworld. It carries no damage of its own. |
| `trap_link` | Trap Link | false | Share traps with the rest of the multiworld, the Trap Link protocol that Sonic Adventure 2, Super Mario World, and others already speak. |
| `goal` | Goal | ending_a | Victory condition: `ending_s`, `ending_a`, `savior`, `zombie_genocider`, or `psycho`. |
| `number_of_survivors` | Savior Survivor Goal | 35 | The number of survivors that must be rescued for the Savior goal. Only has an effect when Goal is set to Savior. |
| `number_of_kills` | Psycho Kill Goal | 25 | The number of survivors that must be killed for the Psycho goal. Only has an effect when Goal is set to Psycho. |
| `scoop_sanity` | ScoopSanity | true | When enabled, time freezes after the Entrance Plaza prologue. Scoops are added to the item pool and will not begin until the player receives them. |
| `scoopsanity_order` | Scoopsanity Order | shuffled | How the main scoops are ordered when ScoopSanity is on: `shuffled` (default), `vanilla`, or `any_order`. |
| `randomize_scoop_order` | Randomize Scoop Order |  | Replaced by Scoopsanity Order. Still read from old YAMLs. |
| `main_scoops_any_order` | Main Scoops In Any Order |  | Replaced by Scoopsanity Order. Still read from old YAMLs. |
| `kent_scoop_order` | Kent Scoop Order | progressive | How Kent's three scoops reach you with ScoopSanity: `progressive` (default) or `separate`. |
| `zombie_kill_tiers` | Zombie Kill Tiers | easy | Adds "Kill N zombies in <area>" checks, counted per area: `none`, `easy` (default), `normal`, `nightmare`, or `genocide`. |
| `kill_sanity` | KillSanity | false | Every zombie kill in each area is its own check, up to the number set by Zombie Kill Tiers. Adds many filler items. Genocide needs to be allowed in the `host.yaml` of whoever generates. |
| `item_sanity` | ItemSanity | false | Picking up each kind of item for the first time is a check, for about 180 checks. Items can no longer be spawned from the window. Cannot be combined with Spitter Only. |
| `pp_bonus_locations` | PP-Bonus Locations | true | Adds extra checks for PP-bonus events, such as the treadmills, sandbags, display racks, microwaves, and pans. |
| `exclude_levels_above` | Exclude Levels Above | 30 | Level-ups above this value still exist as checks but are prevented from holding progression items. This setting can be used to limit how much grinding a run may demand. |
| `exclude_rescues_above` | Exclude Rescues Above | 35 | "Rescue N survivors" checks above this value still exist but will not hold progression items. This option prevents the player from having to rescue every single survivor in the mall to retrieve an important item. |
| `overtime_checks_filler` | Overtime Checks Filler | false | When enabled, every check in Overtime still exists but will only ever hold filler, so no progression is placed past the point of no return. |
| `pp_stickers_filler` | PP Stickers Filler | false | When enabled, PP stickers and their milestone checks (such as "Photograph 10 PP Stickers") will still exist but will only have filler. |
| `extra_pp_stickers` | Extra PP Stickers | false | Adds 100 extra PP stickers to the mall in places the vanilla game has none. Photograph them the same way you would a vanilla PP sticker. Each photo is worth only 1 PP. |
| `door_randomizer` | Door Randomizer | false | When enabled, door connections throughout the mall are randomized depending on the setting chosen below. Each entrance will lead to an unexpected location. |
| `door_randomizer_mode` | Door Randomizer Mode | paired | `paired` (default) or `chaos`. Chaos gives you every area key at the start. |
| `door_locks` | Door Locks | false | When enabled (and Door Randomizer is on), moving to a new area will require having that area's key. Logic will be updated to reflect your randomized layout. |
| `randomize_rooftop_service_hallway_doors` | Randomize Rooftop/Warehouse Doors | false | When enabled (and Door Randomizer is on), this option adds the doors between Rooftop and Warehouse into the randomization pool. |
| `restricted_item_mode` | Restricted Item Mode | false | When enabled, players cannot pick up items in the world unless they have been sent to them by the Archipelago server. This creates a more challenging experience where you must rely on items from other players or your own location checks. |
| `car_keys` | Car Keys | false | The mall's drivable vehicles stay locked until you receive their key (Sedan, Sports Car, Truck, Motorcycle, and Convict Humvee). Restricted Item Mode turns this on automatically. |
| `camera_item` | Camera Item | false | The camera becomes an item. Until you receive the Camera, Frank can still raise it and aim, but the shutter will not fire. |
| `split_keys` | Split Keys | false | Normally, an area key opens all doors leading into an area. The 'Wonderland Plaza Key' opens the doors to it from both North Plaza and the Food Court. |
| `start_with_all_keys` | Start With Every Door Key | false | You start with every door key, so the whole mall is open from the start. The keys are taken out of the item pool and filler takes their place. |
| `overtime_progression_gating` | Extra Overtime Keys | false | Adds two key items that Overtime needs: the Clock Tower Tunnel Key and the Humvee Key. Only matters for Ending S. |
| `exclude_overpowered_items` | Exclude Overpowered Items | false | Removes the Book [Infinite Durability], Book [Martial Arts], Laser Sword, Real Mega Buster, and Rocket Launcher from the item pool. With it off, at least one of each is always in the pool. Items named in Guaranteed Items are still added. |
| `enable_skill_items` | Enable Skill Items | true | Frank's 21 combat skills (Jump Kick, Suplex, and so on) become items in the pool. They are Useful, not progression. |
| `enable_stat_items` | Enable Stat Items | true | When enabled, Progressive stat upgrades become AP items in the pool: Health (+1000), Attack (+25%), Throw (+25), Item Slot (+1), Run Level (+1). Classified as Useful. |
| `enable_extra_stat_buffs` | Enable Extra Stat Buffs | false | Adds extra stat-upgrade items that push past the vanilla level 50 caps (more Health, Attack, Throw, Item Slots, and speed). |
| `vanilla_progression` | Vanilla Progression | replace | How level-up rewards and AP skill and stat items interact: `vanilla_only`, `replace` (default), or `extra_buffs_only`. |
| `trap_weights` | Trap Weights | all 1 | How likely each trap is among the traps in the pool. Weight 0 turns a trap off, 4 is twice as likely as 2, and any trap you leave out keeps weight 1. See below. |
| `trap_percentage` | Trap Percentage | 10 | Percentage of filler-item slots that become traps. 0 is no traps, 10 is the default, and 100 is all filler. |
| `hostile_survivor_count_min` | Hostile NPC Count Min | 1 | Minimum number of hostile NPCs spawned per Hostile NPC Trap. Each trap rolls between min and max (inclusive) at fire time. |
| `hostile_survivor_count_max` | Hostile NPC Count Max | 3 | Maximum number of hostile NPCs spawned per Hostile NPC Trap (1 to 10). |
| `cult_limited` | Cult Limited | false | In ScoopSanity, cultists will appear after beginning either "The Cult" or "A Strange Group", and they will remain in the mall indefinitely. |
| `special_forces_mode` | Special Forces Mode | none | Puts the Special Forces in the mall before Overtime: `none` (default), `item`, or `permanent`. |
| `spitter_only` | Spitter Only | false | This mode limits Frank to Spitfire only. Other weapons are removed from the item pool; skills, stats, keys, traps, and healing items stay. |
| `night_mode_enabled` | Night Mode | false | When enabled, zombies behave as if it is always night, regardless of the in-game time. |
| `hardcore_zombies_enabled` | Hardcore Zombies | false | When enabled, zombies become significantly more dangerous on top of Night Mode. Turning this on without enabling Night Mode auto-enables it. |
| `zombie_spawn_multiplier` | Zombie Spawn Multiplier | 1 | Multiplies the number of zombies each area spawns. |
| `infinity_drain` | Infinity Drain | false | Infinity Mode's health drain, in a normal run. Frank slowly loses health over time, and food is how you keep him going. |
| `infinity_drain_rate` | Infinity Drain Rate | 100 | Seconds for the Infinity Drain to empty one health block. 100 is vanilla Infinity Mode: ten health a second. Lower is harsher. |
| `random_starting_costume` | Random Starting Costume | false | When enabled, Frank's outfit is randomized once at the start of each play session (after the save loads or on a fresh new game). One consistent randomized look per seed. |
| `costume_chaos_mode` | Costume Chaos Mode | false | When enabled, Frank's outfit is re-randomized on every area transition (i.e. every door / loading-zone change). Frank looks different in every area, with a fresh random outfit each time. |
| `dlc_outfits_enabled` | DLC Outfits Enabled | false | The costume randomizer can also pick the 20 DLC outfits. Leave it off unless you own the DLC. |
| `music_shuffle` | Music Shuffle | false | Shuffles the game's music in two groups, Mall Music and Action Music. See [Custom music](MUSIC.md). |

## Guaranteed Items

`guaranteed_items` takes item names with a number of copies:

```yaml
Dead Rising Deluxe Remaster:
  guaranteed_items:
    Rocket Launcher: 2
    Book [Infinite Durability]: 1
```

The count is exact for items that otherwise only come as filler, and for the overpowered items. For items the game adds itself (keys, scoops, Progressive Kent Scoop, skills, and stat upgrades), the total is the larger of the usual amount and your count, so a guarantee never removes copies the logic needs. A count of 0 is the same as not listing the item. Items named here are added even when Exclude Overpowered Items is on.

## Trap Weights

`trap_weights` lists traps and a weight for each. A trap you leave out keeps weight 1, and a weight of 0 means it never appears (including when it arrives over Trap Link):

```yaml
Dead Rising Deluxe Remaster:
  trap_percentage: 20
  trap_weights:
    Teleport Trap: 0
    Bonk Trap: 4
```

The trap names are listed in the template that **Generate Template Options** makes. Some traps drop out on their own: Convicts Respawn needs ScoopSanity, and Night is left out when Night Mode or Hardcore Zombies is on.
