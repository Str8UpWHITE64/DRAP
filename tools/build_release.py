"""Build the DRAP release artifacts.

Outputs into tools/release_out/:
  DRAP_<version>.zip  -- extract straight into the game install folder
  drdr.apworld        -- goes into Archipelago's custom_worlds

The bundled binaries are vendored at the repo root and pinned to the
builds this mod is tested against:
  dinput8.dll         REFramework (DD2 build)
  lua-apclientpp.dll  Archipelago client library
Replace them deliberately and retest; do not swap in untested builds.
"""
import json
import os
import re
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
OUT = os.path.join(HERE, "release_out")

LOGGER_LUA = os.path.join(REPO, "source", "autorun", "DRAP", "Logger.lua")


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
    apworld = build_apworld()

    zpath = os.path.join(OUT, f"DRAP_{version}.zip")
    autorun = os.path.join(REPO, "source", "autorun")
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(os.path.join(REPO, "dinput8.dll"), "dinput8.dll")
        z.write(os.path.join(REPO, "lua-apclientpp.dll"), "lua-apclientpp.dll")
        z.write(os.path.join(REPO, "THIRD-PARTY-LICENSES.md"), "THIRD-PARTY-LICENSES.md")
        z.write(os.path.join(REPO, "LICENSE"), "LICENSE-DRAP.txt")
        for root, dirs, files in os.walk(autorun):
            for f in files:
                full = os.path.join(root, f)
                arc = "reframework/autorun/" + os.path.relpath(full, autorun).replace(os.sep, "/")
                z.write(full, arc)

    entries = len(zipfile.ZipFile(zpath).namelist())
    print(f"built {os.path.basename(zpath)} ({entries} entries, world {version})")
    print(f"built {os.path.basename(apworld)}")


if __name__ == "__main__":
    main()
