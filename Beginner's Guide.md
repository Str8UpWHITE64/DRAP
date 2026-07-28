# Beginner's Guide

If this is your first time playing the Dead Rising Deluxe Remaster AP, please read this guide from beginning to end! I've even included helpful pictures for visual reference. If you're truly pressed for time, just look at the pictures.

## Additional Tools

Before playing, please consider installing [Universal Tracker](https://github.com/FarisTheAncient/Archipelago/releases?q=Tracker) and/or the [PopTracker](https://github.com/RazgrizEast/dead-rising-poptracker-razgriz/releases) made by Razgriz. Certain locations have logic for spawning items or are available in the opening earlier than one may expect. These tools, alongside the in-game AP Client, are helpful in knowing what you are able to do while playing. 

## Win Conditions

In Ending A and Ending S, your objective is to complete 13 story missions, return to the Security Room via the Warehouse, complete Memories, and head to the Heliport. Ending S also requires you to complete the Overtime missions. The 13 missions you must complete are always the same:

1. Santa Cabeza
2. Image in the Monitor
3. A Temporary Agreement
4. Girl Hunting
5. The Butcher
6. Professor's Past
7. Jessie's Discovery
8. Hideout
9. A Promise to Isabela
10. Rescue the Professor
11. Medicine Run
12. The Last Resort
13. Backup for Brad

Savior, on the other hand, only requires you to bring a certain number of survivors back to the Security Room. You can ignore the Main Scoops, as they only have filler items.

Please read the [Known Bugs]() document should you encounter a bug with survivors unloading.

## What is *Restricted Items*?

*Restricted Items* is a setting in DRDR AP that prevents you from picking up an item until it has been sent to you. For example, if you are sent "Baseball Bat" then you are able to pick up Baseball Bats. If *Restricted Items* is disabled, then you have no restrictions on items you can interact with.

To see what items have been sent to you, check the in-game AP Client **Items** tab (explained further down).

## What is *Scoopsanity*?

*Scoopsanity* is a setting that freezes the in-game timer after meeting Jessie in the Warehouse. Main Scoops will be assigned in a random order and must be completed in that order. Side Scoops that would normally require a specific time to activate or a specific Scoop to be completed first have these restrictions removed.

If you do not play with Scoopsanity, the Main Scoops will have to be completed in order. You may have to start a new save file in order to reload certain Scoops that were previously locked. This is intentional behavior, and your AP progress and Main Scoop completion carries over between saves.

## What is *Door Randomizer*?

*Door Randomizer* how doors are linked together. The door from Wonderland Plaza to Food Court could instead take you to the door from Paradise Plaza to Warehouse, while the door from Food Court to Wonderland Plaza could take you to the door from North Plaza to Crislip's Home Saloon. You can generate a map of the linked doors in the **Doors** tab of the AP client, explained further down.

*Note: DRDR AP 1.1 does not support the /get_logical_path function in UT.*

## Ignore the in-game Mission HUD

The in-game HUD is, as of 1.1, does not necessarily reflect what your current Scoop/Objective is. Only rely on the AP Client **Scoops** tab to know what comes next, which is pulled up by pressing a key on your keyboard (Default: Insert Key).

## AP Client Tabs meaning

The in-game AP Client has 4 tabs: **Items**, **Keys**, **Scoops**, and **Doors**. **Keys** shows you the keys you have. **Doors** creates an interactable .html file of the door links, which can be found in `steamapps\common\DEAD RISING DELUXE REMASTER\reframework\data`. The other tabs need a bit more thorough explanation.

## Understanding the AP Client **Scoops** tab

The in-game AP Client is powerful and informative, if not a little confusing at times. **Scoops** is the most important tab while playing, as it tells you what Scoops are available. For Main Scoops:

- GREY means the Scoop is completed
- RED means you do not have the Scoop unlocked
- BLUE means you have the Scoop unlocked but it is not your current Scoop
- GREEN means you have the Scoop unlocked and it is your current Scoop

Beneath the Main Scoops, you can see all other Side Scoops you have currently available. BLUE, in this case, means you have the Scoop unlocked but the conditions to complete it have yet to be met. Additionally, YELLOW means the Scoop is unlocked but being blocked by the completion of a different Scoop

You are able to click "Done" on your Side Scoops. DO NOT DO THIS unless the Scoop is bugged or otherwise not able to be completed. This does not send the corresponding checks; you will either need to have the Server Admin send you the check locations OR start a new save file and run to the mission to complete it. For more information, check out the [Known Bugs]() document.

## Understanding the AP Client **Items** tab

The **Items** tab represents two things: your ability to spawn items if you don't have *Restricted Items* enabled, and your ability to interact with items if you do have *Restricted Items* enabled. Let's say, for example, you are sent a Baseball Bat.

- If you do not have *Restricted Items* enabled, you can the item in the **Items** tab and then click "Spawn Item" to spawn one item near you in your world (Note: please see the [Known Bugs]() document before spawning items in your world)
- If you have *Restricted Items* enabled, you can now pick up the item if it already exists in the world. However, you can not spawn the item via the **Items** tab.

## Despawning Survivors

There is a known bug that Survivors in your party will not respawn should you load a save. This is being investigated and a fix will hopefully be implemented in a future update. If you encounter this bug, please read the [Known Bugs]() document to implement a workaround.

## Recommended Settings

*This section is entirely the opinions of the author and does not reflect the playstyle of anyone else.*

DRDR can be an intimidating AP to play at first. The HUD isn't entirely clear on what to do and there's a fair amount of toggling you have to do between the in-game AP Client and the game itself. With that acknowledged, I would encourage true beginners of this AP to enable the following settings in their YAML to get a feeling for everything before customizing it to their liking.

- Scoop_Sanity: Enabled
- pp_bonus_locations: Enabled
- restricted_item_mode: Disabled
- cult_limited: Enabled
- start_inventory_from_pool: Rooftop key: 1, Warehouse key: 1
- start_hints: Paradise Plaza key, Entrance Plaza key, Al Fresca Plaza key, Leisure Park key, Maintenance Tunnel key, Maintenance Tunnel Access Key
