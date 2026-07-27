# Beginner's Guide

If this is your first time playing the DRDR AP, please read this guide from beginning to end! I've even included helpful pictures for visual reference.

## Additional Tools

Before playing, please consider installing [Universal Tracker](https://github.com/FarisTheAncient/Archipelago/releases?q=Tracker) and/or the [PopTracker](https://github.com/RazgrizEast/dead-rising-poptracker-razgriz/releases) made by Razgris. These tools, alongside the in-game AP Client, are helpful in knowing what you are able to do while playing.

## What is *Restricted Items*?

*Restricted Items* is a setting in DRDR AP that prevents you from picking up an item until it has been sent to you. For example, if you are sent "Baseball Bat" then you are able to pick up Baseball Bats. If *Restricted Items* is disabled, then you have no restrictions on items you can interact with.

To see what items have been sent to you, check the in-game AP Client **Items** tab (explained further down).

## Ignore the in-game Mission HUD

The AP has 13 Main Scoop missions that you are expected to complete in order to obtain Ending A. The in-game HUD is, as of 1.1.X, does not necessarily reflect what your current Scoop/Objective is. Only rely on the AP Client **Scoops** tab to know what comes next, which is pulled up by pressing a key on your keyboard (Default: Insert Key).

## AP Client Tabs meaning

The in-game AP Client has 4 tabs: **Items**, **Keys**, **Scoops**, **Doors**, and **Saves**. **Saves** does not function as intended and will be removed in a future update. **Keys** shows you the keys you have. **Doors** shows you the ways doors work if you have Door Randomizer enabled. The other tabs need a bit more thorough explanation.

## Understanding the AP Client **Scoops** tab

The in-game AP Client is powerful and informative, if not a little confusing at times. **Scoops** is the most important tab while playing, as it tells you what Scoops are available. For Main Scoops:

- RED means you do not have the Scoop unlocked
- BLUE means you have the Scoop unlocked but it is not your current Scoop
- GREEN means you have the Scoop unlocked and it is your current Scoop

Beneath the Main Scoops, you can see all other side scoops you have currently available.

- GREY means the Scoop is completed
- AAA means the Scoop is unlocked and able to be completed
- BBB means the Scoop is unlocked but being blocked by the completion of a different Scoop

You are able to click "Done" on your Side Scoops. DO NOT DO THIS unless the Scoop is bugged or otherwise not able to be completed. This does not send the corresponding checks; you will either need to have the Server Admin send you the check locations OR start a new save file and run to the mission to complete it. For more information, check out the [Known Bugs]() document.

## Understanding the AP Client **Items** tab

The **Items** tab represents two things: your ability to spawn items if you don't have *Restricted Items* enabled, and your ability to interact with items if you do have *Restricted Items* enabled. Let's say, for example, you are sent a Baseball Bat.

- If you do not have *Restricted Items* enabled, you can the item in the **Items** tab and then click "Spawn Item" to spawn one item near you in your world (Note: please see the [Known Bugs]() document before spawning items in your world)
- If you have *Restricted Items* enabled, you can now pick up the item if it already exists in the world. However, you can not spawn the item via the **Items** tab.

## Despawning Survivors

There is a knownm bug that Survivors in your party will not respawn should you load a save. This is being investigated and a fix will hopefully be implemented in a future update. If you encounter this bug, please read the [Known Bugs]() document to implement a workaround.

## Recommended Settings

*This section is entirely the opinions of the author and does not reflect the playstyle of anyone else.*

DRDR can be an intimidating AP to play at first. The HUD isn't entirely clear on what to do and there's a fair amount of toggling you have to do between the in-game AP Client and the game itself. With that acknowledged, I would encourage true beginners of this AP to enable the following settings in their YAML to get a feeling for everything before customizing it to their liking.

- Scoop_Sanity: Enabled
- pp_bonus_locations: Enabled
- restricted_item_mode: Disabled
- cult_limited: Enabled
- start_inventory_from_pool: Rooftop key: 1, Warehouse key: 1
- start_hints: Paradise Plaza key, Entrance Plaza key, Al Fresca Plaza key, Leisure Park key, Maintenance Tunnel key, Maintenance Tunnel Access Key
