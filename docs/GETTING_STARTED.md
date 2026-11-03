# Getting started

How the randomizer plays. For installing, see the [README](../README.md).

## Warning

There aren't a ton of crashes, but you should expect some.  Please report any you find on the issue tracker or in the DRDR AP Discord thread.  Please try to be as detailed as possible.

This is tested against the 1.5.9.1 build of REFramework, which ships in the release zip.  Anything older than 1.5.8 will misbehave in ways that are hard to trace; see [Troubleshooting](TROUBLESHOOTING.md).

## About
There are about 300 locations at the present time. More may be added in the future, it will just take time and testing.

These include:
- Main story scoops
- Survivor rescues
- PP Sticker locations
- Level Ups
- Challenges

The mod adds door locking and time locking.  This means that in order to go to any areas past the Security Room, you will need to get a key for it.  That means, if you are playing solo and cant get to the Rooftop, you likely can do some checks in the Entrance Plaza in the opening sequence. Which leads to:

It is possible to soft lock yourself, so don't be hesitant to start the game over on top of your current progress to focus on side missions. When you start a new game, any items you received over the run will be granted again at the start.

The goal is set by the `goal` option: Ending S (the default is Ending A), Savior, Zombie Genocider or Psycho. See [Options](OPTIONS.md).
## Gameplay Notes
There are two main modes for this: ScoopSanity and regular.  ScoopSanity is the default and recommended mode as it adds a new way to play the game and more random-ness.

### ScoopSanity

All scoops, main story and side missions, are randomized.  Time is frozen after you complete the prologue mission "Get to the stairs!".  The order for main scoops is randomized and are sent as items to the player.  In order to progress through the now randomized story, you must be sent and complete each main scoop in order.

Side scoops are also randomized, and are active the moment you receive them. This means that if you receive the side scoop "Above the Law", you can immediately go to Wonderland Plaza and fight Jo.  All side scoops are added to the pool of items to be sent to you, and all psychos and survivors are in the location pool to complete.  

You can view the main scoops you have completed in the AP Client UI, and the side scoops you have active in the "Scoop Status" section of the AP Items Window.  You can also view the main scoop order in the spoiler log of the APWorld.

### Non-ScoopSanity
The main story scoops are in their normal order, but time-lock items are added to the pool.  This means that in order to progress through the story, you need to get sent items that allow you to progress time until the next main scoop.  There are 5 time-lock items, meaning that in order to win the game, you need to get each of the 5 time-locks and complete the main scoops. 


### General
- There are two main ways items are handled in this mod: Granted items and Restricted items.  This is determined by the options selected in your APWorld YAML file.
  - Granted items show up in the AP Items window (see below) and can be spawned at any time.  These items are added to the list of items You have received from the APWorld, and can be spawned at any time.
  - Restricted items are items that You are allowed to pick up in the world after You have received them from the APWorld.  These items will show up in the AP Items window, but You cannot spawn them.  Instead, You must find them in the world like normal.  If You haven't gotten the item from the APWorld yet, You will not be able to pick it up in the world.
- Door locks and time locks gate your progress.  If You can't get to an area, You likely need to find the key for it. If You notice time isn't progressing towards a main scoop, You likely need an item.  Time-locks are sent on connection for ScoopSanity, and missions are sent to You as items.  DoorSanity also grants all door-locks on first connection.
- With DoorSanity enabled, You can generate a map HTML file with each of the door redirections.  You can find this in the "Doors" section of the Archipelago window.
- If you disconnect while playing, you will send challenge and level locations on reconnect.
- To open the ItemSpawner window, go into the REFramework window, scroll down to "Script Generated UI" and check "Show Archipelago Window".  This will open a new window where you can spawn items you have received from the APWorld, view your scoop statuses, your keys to areas, and generate your DoorSanity HTML file.
