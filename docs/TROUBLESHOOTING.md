# Troubleshooting

## Bug reports and logs

The mod keeps a log of every play session. When you report something, **attach the log file** — it saves a lot of back-and-forth guessing.

Logs live in your game folder under:

```
reframework/data/DRAP/logs/
```

Each session gets its own file, named for when you started the game — `AP_2026-07-25_14-30-12.log` — so opening the game again never erases the log from the run where the bug happened. If you're not sure which file you want, `latest.json` in that folder names the most recent one. The ten newest keep their text; older ones are emptied. Grab the log from the session where the problem occurred, not just the newest one. Copying the file while the game is running is fine.

Every line is plain text with areas, items and locations by name, for example `14:03:22.118 INFO  [items]  Received Wooden Sword from Player2`. A `STATE` line every five minutes, and right after you connect, shows where you were, the day and time, health, and your item and check counts. Debug lines are off by default; set `"debug_log": true` in `reframework/data/DRAP/log_config.json` to include them.

If you're reporting a crash, send the log from the session that crashed — the last lines before it died are usually the useful part.

## The mod does not start

- If the mod reports that `lua-apclientpp.dll` could not load, re-extract the zip and make sure both `.dll` files sit next to `DRDR.exe`.
- If you do not see the Archipelago client window, press Insert, scroll down in the REFramework window to "Script Generated UI" and make sure "Show Archipelago Client UI" is checked.
- **Extract both folders.** `reframework/data` is not optional. Without it the mod loads but registers no items and finds no scoop data.
- A connection that hangs at "connecting to" with no server traffic can be an IPv6 versus IPv4 problem. Use `127.0.0.1` instead of `localhost` for a server on the same PC.

## REFramework

- **If you already have your own REFramework installed, let the zip overwrite it.** REFramework only learned about Dead Rising in **v1.5.8** — the `DD2.zip` build. Anything older loads and looks fine, but it cannot find one of the engine functions it needs to track object lifetimes, and the result is memory corruption: garbled text in the console, and occasional wrong behaviour or crashes that are impossible to trace. If you want to supply your own, use v1.5.8 or newer.
- **Let the zip overwrite `re2_fw_config.txt`.** It turns on REFramework's loose-file loader, which DRAP needs for the PP sticker logo, and it resets your other REFramework settings to defaults. If you keep your own config, set `LooseFileLoader_Enabled=true` in it instead.

## What the release zip contains

The zip is extracted into the game folder and contains everything the game side needs:

```
DEAD RISING DELUXE REMASTER
├── dinput8.dll             (REFramework v1.5.9.1, DD2 build)
├── lua-apclientpp.dll      (Archipelago client library)
├── re2_fw_config.txt       (turns on REFramework's loose-file loader)
├── natives                 (replacement PP sticker textures)
├── DRAP Music Builder.bat  (optional: adds your own songs, see docs/MUSIC.md)
├── DRAP Music Uninstall.bat
├── DRAP-MusicBuilder.ps1
├── DRAP Music Builder.sh   (the same for Linux / Steam Deck)
├── DRAP Music Uninstall.sh
├── drap_music_builder.py
├── Migrate Old AP Saves.bat  (copies seeds from older versions, see Saves)
├── Migrate-OldAPSaves.ps1
├── LICENSE-DRAP.txt
├── THIRD-PARTY-LICENSES.md
└── reframework
    ├── autorun
    │   ├── AP_DRDR_main.lua
    │   ├── AP_REF
    │   └── DRAP
    └── data                    (scoop/item/survivor data the mod reads at runtime)
```

## Fixed in recent versions

Update the mod if you are still seeing these:

- Leaving 10+ party members behind in another area crashed the game shortly after a loading screen or cutscene. The mod now guards the HUD widget responsible; when your scattered party exceeds 8, the other-map HP readout pauses until you regroup.
- "Use N Microwaves/Stoves/Clothing Racks" progress reset between play sessions.
- Survivors occasionally spawning dead or not at all (the "Burt bug") — broken NPC records are now detected and repaired automatically on area transitions.

## Known bugs

See [Known Bugs](../Known%20Bugs.md), and for a save that will not save, [Saves](SAVES.md).
