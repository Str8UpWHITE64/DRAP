# DRAP
Dead Rising Deluxe Remaster Archipelago Implementation

## Warning

This is very much an early alpha.  Expect bugs, missing features, and general instability. I plan to make a lot of updates on this, but please be patient.

There aren't a ton of crashes, but you should expect some.  Please report any you find on the issue tracker or in the DRDR AP Discord thread.  Please try to be as detailed as possible.

I have only tested this using the 1.5.7 build of REFramework.  Other versions may or may not work.  More testing will be needed.
## About
There are about 300 locations at the present time. More may be added in the future, it will just take time and testing.

These include:
- Main story scoops
- Survivor rescues
- PP Sticker locations
- Level ups
- Challenges

I have implemented door locking and time locking.  This means that in order to go to any areas past the Safe Room, you will need to get a key for it.  That means, if you are playing solo and cant get to the Rooftop, you likely can do some checks in the Entrance Plaza in the opening sequence. Which leads to:

It is possible to soft lock yourself, so don't be hesitant to start the game over on top of your current progress to focus on side missions. When you start a new game, any items you received over the run will be granted again at the start.

Currently, there is only one goal, to get Ending S and beat Brock. We may add more goals in the future.

## Setup
1. Download the APWorld from the Releases page and place it into your custom worlds folder.
2. Download the REFramework mod for Dead Rising Deluxe Remaster from [here](https://www.nexusmods.com/deadrisingdeluxeremaster/mods/2).  Extract and place the dinput8.dll file into you Dead Rising Deluxe Remaster installation folder.
3. Open up your Dead Rising Deluxe Remaster installation folder.  From Steam, that is usually located at: `C:\Program Files (x86)\Steam\steamapps\common\DEAD RISING DELUXE REMASTER`
4. Create a folder called `reframework` in the Dead Rising Deluxe Remaster installation folder.
5. Create a folder called `autorun` inside the `reframework` folder.
6. Download the DRAP mod zip from the Releases page, and place the files in their respective folders.  It should look like this:
```DEAD RISING DELUXE REMASTER
└── reframework
    ├── autorun
        ├── DRAP
        │   ├── ChallangeTracker.lua
        │   ├── DoorSceneLock.lua
        │   └── etc...
        ├── AP_REF
        │   ├── core.lua
        │   ├── GUI.lua
        │   └── etc...
        ├── ap_drdr_bridge.lua
        ├── AP_DRDR_main.lua
    └── data
        ├── drdr_items.json
        ├── PPStickers.json
        └── survivors.json
```
7. Download and place the lua-apclientpp.dll into the Dead Rising Deluxe Remaster installation folder from [here](https://github.com/TheRealSolidusSnake/RE3R_AP_Client/blob/main/lua-apclientpp.dll).  I don't yet have permission to post this myself, but will do so if and when I do. 
8. Upon loading into the game, you should see the AP client connect window pop up, along with the REFramework window.  If you do not see the AP client connect window, scroll down in the REFramework window to "Script Generated UI" and make sure "Show Archipelago Client UI" is checked.
9. Generate a template and a world in Archipelago then enter your connection information at the title screen, and wait for it to connect.
10. Upon connecting, a new save file path is created, so no need to worry about overwriting your existing saves.  Each AP world you play will create a new save file location here for Steam users: ```C:\Program Files (x86)\Steam\userdata\{STEAMID}\2527390\remote```. The original saves are under ```win64_save```.
11. Start a new game and enjoy!

## Gameplay Notes
- There are two main ways items are handled in this mod: Granted items and Restricted items.  This is determined by the options selected in your APWorld YAML file.
  - Granted items show up in the AP Items window (see below) and can be spawned at any time.  These items are added to the list of items you have received from the APWorld, and can be spawned at any time.
  - Restricted items are items that you are allowed to pick up in the world after you have received them from the APWorld.  These items will show up in the AP Items window, but you cannot spawn them.  Instead, you must find them in the world like normal.  If you haven't gotten the item from the APWorld yet, you will not be able to pick it up in the world.
- Door locks and time locks gate your progress.  If you can't get to an area, you likely need to find the key for it. If you notice time isn't progressing towards a main scoop, you likely need an item.
- If you disconnect while playing, you will send challenge and level locations on reconnect, but events and PP stickers wont go automatically.  I will try to add this in the future.
- To open the ItemSpawner window, go into the REFramework window, scroll down to "Script Generated UI" and check "Show AP Items Window".  This will open a new window where you can spawn items you have received from the APWorld.

## Known Bugs
Spawning items is by far the most buggy part of this mod.  When spawning items using the AP Items Window, try not to spam the spawn button.  Wait a few seconds after spawning an item before spawning another one.  If you do spawn multiple items quickly, you increase your chances of the game crashing.

Some users are experiencing an issue where they are unable to save after connecting to the APWorld.  If you have this issue, close the game, open the AP_DRDR_main.lua file in a text file editor and change ``local redirect_save_path = true`` to ``local redirect_save_path = false``.  This will make it so the AP saves will use your default save directory, so make sure you are only loading saves for the APWorld. 

PP Stickers are a little iffy.  They usually send without issue, but I have seen them not send until you leave the area and re-enter it.  I have also seen them send the wrong one, too.  Nothing too major, just keep it in mind.

## Final note
I spent countless hours playing the original game when I was younger, and spent plenty playing this version when it came out.  I hope you enjoy this implementation, and I look forward to seeing how people play it!

A lot of time went into making this, and I hope to continue improving it.  Please be patient as I work through bugs and add new features.  This is my first time making an REFramework mod, and it will show.

Shoutout to ArsonAssassin for the APWorld help.  Check out his GitHub page [here](https://github.com/ArsonAssassin) for other mods he has done.