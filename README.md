# DRAP

An [Archipelago](https://archipelago.gg) randomizer for Dead Rising Deluxe Remaster. Scoops, survivor rescues, PP stickers, level ups and challenges become checks, and the keys that open the mall (and the items you would normally find) arrive from other players' worlds.

## What you need

- Dead Rising Deluxe Remaster on Steam, on Windows. Linux and Steam Deck work through Proton.
- [Archipelago](https://github.com/ArchipelagoMW/Archipelago/releases) 0.6.4 or newer.
- The two downloads from the [DRAP releases page](https://github.com/Str8UpWHITE64/DRAP/releases): `DRAP_<version>.zip` and `drdr.apworld`.

The zip already contains the mod loader (REFramework 1.5.9.1) and the Archipelago client library, so you install nothing else.

## Install

1. Close the game. Open its folder: in Steam, right-click the game, then **Manage**, then **Browse local files**. This is the "game folder" below.
2. Extract `DRAP_<version>.zip` into the game folder, next to `DRDR.exe`. Let it overwrite `dinput8.dll` and `re2_fw_config.txt`.
3. Check that `reframework/autorun/AP_DRDR_main.lua` and `reframework/data/drdr_shared.json` now exist. Without the `data` folder the mod loads but registers no items.
4. Put `drdr.apworld` in the `custom_worlds` folder of your Archipelago install.
5. Start the game. The Archipelago client window opens next to the REFramework window. If it does not, press **Insert**, scroll to **Script Generated UI** and tick **Show Archipelago Client UI**.

If the mod says `lua-apclientpp.dll` could not load, extract the zip again and make sure both `.dll` files sit next to `DRDR.exe`.

Already have REFramework? Let the zip replace it. Versions older than 1.5.8 do not support this game and fail in ways that are hard to trace. If you keep your own `re2_fw_config.txt`, it must contain `LooseFileLoader_Enabled=true`.

## Play

1. **Generate.** In the Archipelago Launcher choose **Generate Template Options**, open `Dead Rising Deluxe Remaster.yaml`, set your name (for example `Player1`) and your options, and put it in the `Players` folder. Then choose **Generate** and host the result, or upload it to archipelago.gg.
2. **Connect.** At the title screen, in the Archipelago client window, enter the server (for example `localhost:38281`), your slot name (`Player1`) and the password if there is one. Wait for it to connect.
3. **Start.** Begin a new game. Items you have already received are given again at the start of a new game.

Each seed saves to its own folder, `AP_Saves/<slot>_s<seed>`, inside the game folder, so your normal saves are not touched. See [Saves](docs/SAVES.md).

The options that matter most are `goal`, `scoop_sanity` and `music_shuffle`. See [Options](docs/OPTIONS.md) for all of them and [Getting started](docs/GETTING_STARTED.md) for how the game plays.

## Logs

Each play session writes its own log, named for when you started the game, in `reframework/data/DRAP/logs/` inside the game folder; `latest.json` there names the newest one. When you report a bug, attach the log from the session where it happened. For a crash, that is the session that crashed.

## Known issues

- Expect some crashes. Report them with the log.
- You can soft lock a run; starting a new game over your current progress is fine.
- The on-screen mission list is not the real one. Use the Scoops tab of the client window.
- More answers: [Known Bugs](Known%20Bugs.md).

## More

- [Getting started](docs/GETTING_STARTED.md): modes, items, doors and the in-game windows.
- [Options](docs/OPTIONS.md)
- [Custom music](docs/MUSIC.md): add your own songs to Music Shuffle.
- [Saves and "Failed to Save"](docs/SAVES.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [About and credits](docs/ABOUT.md)
- [Beginner's Guide](Beginner's%20Guide.md)
- Licences: [DRAP](LICENSE) and [third-party](THIRD-PARTY-LICENSES.md). REFramework is by [praydog](https://github.com/praydog/REFramework) and lua-apclientpp by [black-sliver](https://github.com/black-sliver/lua-apclientpp), both MIT.

Thanks to Razgriz for helping build ScoopSanity and to ArsonAssassin for help with the APWorld.
