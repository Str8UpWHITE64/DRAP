# DRAP
Dead Rising Deluxe Remaster Archipelago Implementation

## Warning

There aren't a ton of crashes, but you should expect some.  Please report any you find on the issue tracker or in the DRDR AP Discord thread.  Please try to be as detailed as possible.

This is tested against the 1.5.9.1 build of REFramework, which ships in the release zip.  Anything older than 1.5.8 will misbehave in ways that are hard to trace — see the note in Setup.
## About
There are about 300 locations at the present time. More may be added in the future, it will just take time and testing.

These include:
- Main story scoops
- Survivor rescues
- PP Sticker locations
- Level Ups
- Challenges

I have implemented door locking and time locking.  This means that in order to go to any areas past the Security Room, you will need to get a key for it.  That means, if you are playing solo and cant get to the Rooftop, you likely can do some checks in the Entrance Plaza in the opening sequence. Which leads to:

It is possible to soft lock yourself, so don't be hesitant to start the game over on top of your current progress to focus on side missions. When you start a new game, any items you received over the run will be granted again at the start.

Currently, there is only one goal, to get Ending S and beat Brock. We may add more goals in the future.

## Setup
1. Download `DRAP_<version>.zip` from the Releases page and extract everything into your Dead Rising Deluxe Remaster installation folder.  From Steam, that is usually located at: `C:\Program Files (x86)\Steam\steamapps\common\DEAD RISING DELUXE REMASTER`.  The zip contains everything the game side needs, already laid out:
```DEAD RISING DELUXE REMASTER
├── dinput8.dll             (REFramework v1.5.9.1, DD2 build)
├── lua-apclientpp.dll      (Archipelago client library)
├── THIRD-PARTY-LICENSES.md
└── reframework
    ├── autorun
    │   ├── AP_DRDR_main.lua
    │   ├── AP_REF
    │   └── DRAP
    └── data                    (scoop/item/survivor data the mod reads at runtime)
```
> **Extract both folders.** `reframework/data` is not optional — without it the mod loads but registers no items and finds no scoop data.
> **If you already have your own REFramework installed, let the zip overwrite it.** REFramework only learned about Dead Rising in **v1.5.8** (25 Oct 2024) — the `DD2.zip` build. Anything older loads and looks fine, but it cannot find one of the engine functions it needs to track object lifetimes, and the result is memory corruption: garbled text in the console, and occasional wrong behaviour or crashes that are impossible to trace. If you want to supply your own, use v1.5.8 or newer.

2. Download `drdr.apworld` from the Releases page and place it into your Archipelago `custom_worlds` folder.
3. Launch the game.  You should see the AP client connect window pop up, along with the REFramework window.  If you do not see the AP client connect window, scroll down in the REFramework window to "Script Generated UI" and make sure "Show Archipelago Client UI" is checked.  If the mod reports that `lua-apclientpp.dll` could not load, re-extract the zip and make sure both dll files sit next to the game exe.
4. Generate a template and a world in Archipelago, then enter your connection information at the title screen and wait for it to connect.
5. Upon connecting, a new save file path is created, so no need to worry about overwriting your existing saves.  Each AP world you play will create a new save file location here for Steam users: ```C:\Program Files (x86)\Steam\userdata\{STEAMID}\2527390\remote```. The original saves are under ```win64_save```.
6. Start a new game and enjoy!

REFramework is by [praydog](https://github.com/praydog/REFramework) and lua-apclientpp is by [black-sliver](https://github.com/black-sliver/lua-apclientpp); both are bundled under the MIT license (see THIRD-PARTY-LICENSES.md).

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
- To open the ItemSpawner window, go into the REFramework window, scroll down to "Script Generated UI" and check "Show AP Items Window".  This will open a new window where you can spawn items you have received from the APWorld, view your scoop statuses, your keys to areas, and generate your DoorSanity HTML file.

## Save Data and the "Failed to Save" Error

Steam limits this game's save data to roughly **200 MB total** — counted across *everything* in
`C:\Program Files (x86)\Steam\userdata\{Your SteamID}\2527390\remote`, including your vanilla saves
AND every AP seed's save folder (`win64_save_AP_*`). Each save slot is about 9 MB, so vanilla's 21
slots alone nearly fill the limit, and every AP seed you play stacks on top of that. When you cross
it, the game shows the generic "Failed to Save" error. Steam enforces this limit even if you have
Steam Cloud disabled for the game.

**To fix it:**

1. **Disable Steam Cloud for this game** (recommended for AP players): in your Steam Library,
   right-click *Dead Rising Deluxe Remaster* → **Properties** → **General**, and uncheck
   **"Keep games saves in the Steam Cloud"**. This stops Steam from re-syncing old save folders
   you delete. (The ~200 MB limit still applies to new saves, so step 2 is still needed.)
2. **Delete old save folders.** Close the game, then open File Explorer and go to:
   ```
   C:\Program Files (x86)\Steam\userdata\{Your SteamID}\2527390\remote
   ```
   (If you don't know your SteamID, there is usually only one folder inside `userdata`.)
   Inside `remote` you will see:
   - `win64_save` — your **vanilla** saves. Don't delete this unless you also want those gone.
   - `win64_save_AP_YourName_s123...` — one folder per AP seed you've played.

   Delete the `win64_save_AP_*` folders for seeds you are finished with. Each one frees up to
   ~190 MB depending on how many slots you used. You can also delete individual old save slots
   from inside the game's load menu to free ~9 MB each.

## Reporting a Bug

The mod keeps a log of every play session. When you report something, **attach the log file** — it saves a lot of back-and-forth guessing.

Logs live in your game folder under:

```
reframework/data/DRAP_Logs/
```

Each session gets its own file, named for when you started the game — `drap_20260725_143012.log` — so opening the game again never erases the log from the run where the bug happened. If you're not sure which file you want, `latest.json` in that folder names the most recent one. Grab the log from the session where the problem occurred, not just the newest one.

You can also find the exact path in-game: open the Archipelago window and click the **Log** tab. It shows the file path along with a running count of any warnings and errors. Copying the file while the game is running is fine.

If you're reporting a crash, send the log from the session that crashed — the last lines before it died are usually the useful part.

## Known Bugs

Please check out the [Known Bugs](https://github.com/Str8UpWHITE64/DRAP/blob/main/Known%20Bugs.md) document to see if it answers your question. If not, please feel free to post a message in the AP After Dark Discord channel! 

~~~

Fixed in recent versions (update the mod if you're still seeing these):
- Leaving 10+ party members behind in another area crashed the game shortly after a loading screen or cutscene. The mod now guards the HUD widget responsible; when your scattered party exceeds 8, the other-map HP readout pauses until you regroup.
- "Use N Microwaves/Stoves/Clothing Racks" progress reset between play sessions.
- Survivors occasionally spawning dead or not at all (the "Burt bug") — broken NPC records are now detected and repaired automatically on area transitions.

~~~

## Final note
I spent countless hours playing the original game when I was younger, and spent plenty playing this version when it came out.  I hope you enjoy this implementation, and I look forward to seeing how people play it!

A lot of time went into making this, and I hope to continue improving it.  Shoutout to Razgriz for spending tons of their free time helping me get ScoopSanity implemented.  We probably each added a few hundred hours to our play time to make sure its in as good a spot as it is now.

Please be patient as I work through bugs and add new features.  This is my first time making an REFramework mod, and it will show.

Shoutout to ArsonAssassin for the APWorld help.  Check out his GitHub page [here](https://github.com/ArsonAssassin) for other mods he has done.
