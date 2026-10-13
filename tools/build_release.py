"""Build the DRAP release artifacts.

Outputs into tools/release_out/:
  DRAP_<version>.zip  -- extract straight into the game install folder
  drdr.apworld        -- goes into Archipelago's custom_worlds

The zip also carries source/natives as natives/ at the game root (loose asset
overrides; see below).

The zip carries source/autorun as reframework/autorun AND source/data as
reframework/data. Both halves are required: SharedData reads drdr_shared.json
from the data folder at runtime, DoorRandomizer reads drdr_doors.json and
DoorVisualizer reads Mall.png. A zip without them installs a mod that loads
and then finds no scoop data and registers no item handlers.

The bundled binaries are vendored at the repo root and pinned to the
builds this mod is tested against:
  dinput8.dll         REFramework v1.5.9.1 (DD2 build)
  lua-apclientpp.dll  Archipelago client library
Replace them deliberately and retest; do not swap in untested builds.

dinput8.dll must stay at v1.5.8 or newer. That release added Dead Rising
support; older builds cannot resolve the engine's Context::LocalFrameGC, so
object-lifetime tracking breaks and the Lua heap gets corrupted (garbled log
output, and worse). Diagnosed 2026-07-25 -- see
docs/reframework/features/logging.md.
"""
import json
import os
import re
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
OUT = os.path.join(HERE, "release_out")

LOGGER_LUA = os.path.join(REPO, "source", "autorun", "DRAP", "Logger.lua")
SHARED_LUA = os.path.join(REPO, "source", "data", "drdr_shared.json")
SHARED_PY = os.path.join(REPO, "apworld", "drdr", "drdr_shared.json")

# Contributor notes, not a runtime asset -- everything else under source/data
# ships, including the legacy JSONs, so an install never ends up short.
DATA_SKIP = {"README.md"}


def world_version():
    path = os.path.join(REPO, "apworld", "drdr", "archipelago.json")
    with open(path, encoding="utf-8") as f:
        return json.load(f)["world_version"]


def logger_version():
    """Version the client stamps into every session log header."""
    with open(LOGGER_LUA, encoding="utf-8") as f:
        m = re.search(r'^Logger\.VERSION\s*=\s*"([^"]+)"', f.read(), re.M)
    if not m:
        raise SystemExit(f"could not find Logger.VERSION in {LOGGER_LUA}")
    return m.group(1)


def check_versions(world):
    """Every log a player sends us names its own build, so that name has to be
    right. A silent drift here means months of misattributed bug reports."""
    lua = logger_version()
    if lua != world:
        raise SystemExit(
            f"version mismatch: Logger.VERSION is {lua!r} but world_version is "
            f"{world!r}.\nBump Logger.VERSION in source/autorun/DRAP/Logger.lua "
            f"to match apworld/drdr/archipelago.json."
        )


def check_shared_data():
    """The mod and the generator must agree on the same data. They are two
    files, so they can drift, and a drifted pair fails as wrong logic at play
    time rather than as an error at build time."""
    with open(SHARED_LUA, "rb") as f:
        lua = f.read()
    with open(SHARED_PY, "rb") as f:
        py = f.read()
    if lua != py:
        raise SystemExit(
            "drdr_shared.json copies differ:\n"
            f"  {SHARED_LUA}\n  {SHARED_PY}\n"
            "Copy one over the other before building."
        )


def build_apworld():
    dst = os.path.join(OUT, "drdr.apworld")
    src = os.path.join(REPO, "apworld", "drdr")
    with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
        for root, dirs, files in os.walk(src):
            dirs[:] = [d for d in dirs if d != "__pycache__"]
            for f in files:
                full = os.path.join(root, f)
                arc = "drdr/" + os.path.relpath(full, src).replace(os.sep, "/")
                z.write(full, arc)
    return dst


def main():
    os.makedirs(OUT, exist_ok=True)
    version = world_version()
    check_versions(version)
    check_shared_data()
    apworld = build_apworld()

    zpath = os.path.join(OUT, f"DRAP_{version}.zip")
    autorun = os.path.join(REPO, "source", "autorun")
    data = os.path.join(REPO, "source", "data")
    natives = os.path.join(REPO, "source", "natives")
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(os.path.join(REPO, "dinput8.dll"), "dinput8.dll")
        z.write(os.path.join(REPO, "lua-apclientpp.dll"), "lua-apclientpp.dll")
        z.write(os.path.join(REPO, "THIRD-PARTY-LICENSES.md"), "THIRD-PARTY-LICENSES.md")
        z.write(os.path.join(REPO, "LICENSE"), "LICENSE-DRAP.txt")
        # Copies seeds saved in Steam's store before 1.2.0 into AP_Saves.
        # Lands next to DRDR.exe, which is where it has to run from.
        migrate = os.path.join(REPO, "tools", "migrate")
        for f in ("Migrate Old AP Saves.bat", "Migrate-OldAPSaves.ps1"):
            z.write(os.path.join(migrate, f), f)
        # Music Builder: adds the player's own songs to the game's music as new
        # tracks (nothing vanilla is replaced); Music Shuffle plays them only
        # when connected. Next to DRDR.exe, where it finds the paks and
        # natives/. Ships no audio and no ffmpeg; the script finds the
        # player's own ffmpeg.
        music = os.path.join(REPO, "tools", "music")
        for f in ("DRAP Music Builder.bat", "DRAP Music Uninstall.bat",
                  "DRAP-MusicBuilder.ps1"):
            z.write(os.path.join(music, f), f)
        for root, dirs, files in os.walk(autorun):
            for f in files:
                full = os.path.join(root, f)
                arc = "reframework/autorun/" + os.path.relpath(full, autorun).replace(os.sep, "/")
                z.write(full, arc)
        # SharedData reads drdr_shared.json from reframework/data at runtime,
        # DoorRandomizer reads drdr_doors.json and DoorVisualizer reads
        # Mall.png. Omitting them shipped a mod that loaded and then had no
        # data at all.
        for root, dirs, files in os.walk(data):
            for f in files:
                if f in DATA_SKIP:
                    continue
                full = os.path.join(root, f)
                arc = "reframework/data/" + os.path.relpath(full, data).replace(os.sep, "/")
                z.write(full, arc)
        # Turns REFramework's loose-file loader on (it is off by default, so
        # without this the natives/ overrides below never load). Measured
        # 2026-10-11: a config holding only this key is accepted and REFramework
        # fills every other setting with its defaults. Extracting over an
        # existing config replaces it, so their other REFramework settings
        # reset; see docs/BACKLOG.md. Lua cannot do this itself (its io is
        # sandboxed to reframework/data).
        z.write(os.path.join(REPO, "re2_fw_config.txt"), "re2_fw_config.txt")
        # Loose asset overrides (PP sticker logo) sit beside reframework/ at
        # the game root, where REFramework's LooseFileLoader looks. They are
        # only read when LooseFileLoader_Enabled=true in re2_fw_config.txt.
        if os.path.isdir(natives):
            for root, dirs, files in os.walk(natives):
                for f in files:
                    full = os.path.join(root, f)
                    arc = "natives/" + os.path.relpath(full, natives).replace(os.sep, "/")
                    z.write(full, arc)

    entries = len(zipfile.ZipFile(zpath).namelist())
    print(f"built {os.path.basename(zpath)} ({entries} entries, world {version})")
    print(f"built {os.path.basename(apworld)}")


if __name__ == "__main__":
    main()
