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
├── re2_fw_config.txt       (turns on REFramework's loose-file loader)
├── natives                 (replacement PP sticker textures)
├── DRAP Music Builder.bat  (optional: adds your own songs, see Music Shuffle and Custom Music)
├── DRAP Music Uninstall.bat
├── DRAP-MusicBuilder.ps1
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
> **Let the zip overwrite `re2_fw_config.txt`.** It turns on REFramework's loose-file loader, which DRAP needs for the PP sticker logo, and it resets your other REFramework settings to defaults. If you keep your own config, set `LooseFileLoader_Enabled=true` in it instead.

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

## Music Shuffle and Custom Music

### Music Shuffle (the yaml option)

Add this to your yaml to turn it on (it's off by default):

```yaml
  music_shuffle: true
```

When you connect to your seed, the game's music is shuffled in two groups:

- **Mall Music:** the songs on the mall's PA speakers.
- **Action Music:** psychopath fights, story and event music.

Songs only swap within their own group, so the PA always sounds like the PA. The shuffle is the same every time you connect to the same seed. When you aren't connected, or the option is off, the game plays its normal music.

### Custom Music (your own songs)

You can add your own songs to Music Shuffle. DRAP doesn't include any music; you bring your own.

Your songs are **added** to the game; none of the game's own music is changed. They only play while you're connected to a seed with `music_shuffle: true`. Offline, and in seeds without the option, you hear the normal game music.

#### Setup

1. **Install DRAP from the release zip** as described in [Setup](#setup). The zip puts these files in the game folder, next to `DRDR.exe`:
   - `DRAP Music Builder.bat`
   - `DRAP Music Uninstall.bat`
   - `DRAP-MusicBuilder.ps1` (the script the two .bat files run)

   Let the zip's `re2_fw_config.txt` overwrite yours. Custom music needs the loose-file loader it turns on.
2. **Get ffmpeg.** DRAP uses it to convert your songs, and it isn't included.
   - Download a Windows build from one of the links on [ffmpeg.org/download.html](https://ffmpeg.org/download.html).
   - Unzip it and find `ffmpeg.exe` inside its `bin` folder.
   - Copy `ffmpeg.exe` into the `DRAP Music` folder (step 3 creates it). Or put it next to `DRDR.exe`, or add its `bin` folder to your Windows PATH; the builder looks in all three places.
3. **Close the game** and double-click `DRAP Music Builder.bat` once. It creates the song folders:
   ```
   DEAD RISING DELUXE REMASTER
   └── DRAP Music
       ├── Mall Music      songs for the mall's PA speakers
       └── Action Music    fight, story and event music
   ```
4. **Add your songs.** Put audio files (`mp3`, `ogg`, `flac`, `wav`, `m4a`, `opus`, `wma`, `aac`) in those two folders. Subfolders are fine.
   - Each seed uses up to **8 Mall songs**, one for each area with PA speakers: Entrance Plaza, Paradise Plaza, Wonderland Plaza, North Plaza, Al Fresca Plaza, Seon's, Crislip's and Colby's Movieland.
   - Each seed uses up to **21 Action songs**, one for each fight, story or event cue.
   - Each song is used at most once per seed. If you add fewer songs than there are slots, the rest play the game's own music. If you add more, each seed picks a different set.
5. **With the game closed**, double-click `DRAP Music Builder.bat` again. It lists each song as it adds it, usually in under a minute; longer songs and bigger folders take a little longer. When it finishes, the window says:
   ```
   Done. Added X Mall Music and Y Action Music song(s).
   ```
   `DRAP Music\Installed songs.txt` lists what was added.
6. **Play.** Connect to a seed that has `music_shuffle: true`. Each mall area plays its own song, and the fight and event music plays your Action songs. Songs loop until the game moves on.

#### Changing your songs

Add or remove files in the two folders, then run `DRAP Music Builder.bat` again with the game closed. It replaces its previous build each time.

#### Volume

Every song is set a little quieter than the game's own music. If a group still sounds too loud or too quiet:

1. Open `DRAP Music\settings.json` in Notepad. It looks like this:
   ```json
   { "mall_gain_db": 0, "action_gain_db": 0 }
   ```
2. Lower a number to make that group quieter (for example `-3`), or raise it to make it louder (for example `3`).
3. Save the file and run `DRAP Music Builder.bat` again.

#### Removing custom music

Close the game and double-click `DRAP Music Uninstall.bat`. It removes only the files the builder made. Your songs stay in their folders.

#### If something goes wrong

The window says what happened, and the same text is saved to `DRAP Music\Music Builder log.txt`. Attach that file if you report a problem.

| The window says | What to do |
|---|---|
| `Dead Rising is running.` | Close the game completely, then run the builder again. |
| `ffmpeg was not found.` | Do step 2 above. |
| `No songs found yet.` | Put songs in the `Mall Music` / `Action Music` folders. |
| `Could not find the game's music in its .pak files` | The builder files must be in the game folder, next to `DRDR.exe` and `re_chunk_000.pak`. If they are, use Steam's "Verify integrity of game files". |
| `DRDR.exe is not in this folder` | The builder files must be in the game folder, next to `DRDR.exe`. Re-extract the release zip there. |
| `These music files are already in the game folder, and the DRAP Music Builder did not make them` | Another mod changes the game's music. Remove that mod, then run the builder again. |
| `The game's music no longer matches this version of DRAP` | A game update changed the music files. Nothing was changed; check for a newer DRAP release. |
| `...larger than 3.5 GB...` | Too much music for one build. Remove some songs, or use shorter ones. Mall songs take about 2.6 MB per minute, Action songs about 11.5 MB per minute. |
| `Failed: ...` | Nothing in the game folder was changed. Send the log file. |

## Save Data and the "Failed to Save" Error

With **Redirect Saves** on, every seed saves to its own folder inside the game's install folder:

```
C:\Program Files (x86)\Steam\steamapps\common\DEAD RISING DELUXE REMASTER\AP_Saves\{Slot}_s{Seed}
```

These saves never go through Steam, so they are not backed up to Steam Cloud, and they are not
counted against Steam's limits. To clean up, delete the folders inside `AP_Saves` for seeds you are
finished with. Your vanilla saves are untouched and stay in Steam's store as always.

Seeds you played on an older version of the mod kept their saves in Steam's store
(`C:\Program Files (x86)\Steam\userdata\{Your SteamID}\2527390\remote\win64_save_AP_*`). To keep
playing one of those, close the game and copy that seed's files into `AP_Saves\{Slot}_s{Seed}`
(create the folder if it is not there yet; the name is the part after `win64_save_AP_`).
The release includes `Migrate Old AP Saves.bat` in the game folder: with the game closed,
double-click it and it copies every old seed over for you. It never deletes the originals and
skips any seed that already has saves in `AP_Saves`.

**Why this changed.** Steam caps this game's save store at 30 files, whether or not Steam Cloud is
enabled. Vanilla alone can use 23 of them, and every seed used to add its autosave plus one file per
slot. Once the count reached 30, any save that had to create a new file was refused and the game
showed the generic "Failed to Save" error, while saving over an existing slot still worked. If you
ever see "Failed to Save" on a **vanilla** save, that cap is the reason: delete old slots from the
load menu, or delete leftover `win64_save_AP_*` folders from Steam's store.

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
