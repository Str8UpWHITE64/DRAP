# Save data and the "Failed to Save" error

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
