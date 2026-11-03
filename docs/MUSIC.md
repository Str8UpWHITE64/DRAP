# Custom music and Music Shuffle

## Music Shuffle (the yaml option)

Add this to your yaml to turn it on (it's off by default):

```yaml
  music_shuffle: true
```

When you connect to your seed, the game's music is shuffled in two groups:

- **Mall Music:** the songs on the mall's PA speakers.
- **Action Music:** psychopath fights, story and event music.

Songs only swap within their own group, so the PA always sounds like the PA. The shuffle is the same every time you connect to the same seed. When you aren't connected, or the option is off, the game plays its normal music.

## Custom Music (your own songs)

You can add your own songs to Music Shuffle. DRAP doesn't include any music; you bring your own.

Your songs are **added** to the game; none of the game's own music is changed. They only play while you're connected to a seed with `music_shuffle: true`. Offline, and in seeds without the option, you hear the normal game music.

### Setup

1. **Install DRAP from the release zip** as described in the [install steps](../README.md#install). The zip puts these files in the game folder, next to `DRDR.exe`:
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

### Linux and Steam Deck (Proton)

The Windows `.bat` files don't run on Linux. Use the two `.sh` files instead; they do the same job and write the same files. The setup above applies, with these differences:

1. **Find the game folder.** In Steam, right-click Dead Rising Deluxe Remaster, then **Manage > Browse local files**. It's usually `~/.steam/steam/steamapps/common/DEAD RISING DELUXE REMASTER`. Extract the release zip there as on Windows. It includes `DRAP Music Builder.sh`, `DRAP Music Uninstall.sh` and `drap_music_builder.py`.
2. **You need python3.** Most Linux systems and SteamOS already have it; check with `python3 --version`.
3. **Get ffmpeg.**
   - On a desktop system, install it with your package manager, for example `sudo apt install ffmpeg` (Ubuntu, Debian, Mint, Pop!_OS), `sudo dnf install ffmpeg` (Fedora) or `sudo pacman -S ffmpeg` (Arch, Manjaro).
   - On a Steam Deck, or anywhere you can't install packages, download a Linux build from one of the links on [ffmpeg.org/download.html](https://ffmpeg.org/download.html) and copy its `ffmpeg` file into the `DRAP Music` folder.
4. **Run the builder from a terminal**, with the game closed:
   ```sh
   cd ~/.steam/steam/steamapps/common/"DEAD RISING DELUXE REMASTER"
   sh "DRAP Music Builder.sh"
   ```
   Run it once to create the song folders, put your songs in them, then run it again, exactly as in steps 3-5 above. To remove your songs, run `sh "DRAP Music Uninstall.sh"`.
5. **Volume, changing songs and the log file** work the same as on Windows.

### Changing your songs

Add or remove files in the two folders, then run `DRAP Music Builder.bat` again with the game closed. It replaces its previous build each time.

### Volume

Every song is set a little quieter than the game's own music. If a group still sounds too loud or too quiet:

1. Open `DRAP Music\settings.json` in Notepad. It looks like this:
   ```json
   { "mall_gain_db": 0, "action_gain_db": 0 }
   ```
2. Lower a number to make that group quieter (for example `-3`), or raise it to make it louder (for example `3`).
3. Save the file and run `DRAP Music Builder.bat` again.

### Removing custom music

Close the game and double-click `DRAP Music Uninstall.bat`. It removes only the files the builder made. Your songs stay in their folders.

### If something goes wrong

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
| Linux: `python3 was not found` | Install python3 with your package manager, then run the `.sh` again. |
| Linux: `ffmpeg was not found` | Install ffmpeg with your package manager, or put a Linux `ffmpeg` file in the `DRAP Music` folder (Linux step 3). |
| Linux: `Dead Rising is running` | Close the game and wait for Steam to show it as stopped. Proton can take a few seconds to exit. |
| Linux: `Permission denied` when running the `.sh` | Run it as `sh "DRAP Music Builder.sh"`, not `./DRAP Music Builder.sh`. |
| Linux: the songs never play in game | Check `re2_fw_config.txt` in the game folder contains `LooseFileLoader_Enabled=true`. |
