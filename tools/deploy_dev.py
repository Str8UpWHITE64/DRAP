"""Copy a working tree into the game install for testing.

Both halves are required. source/autorun becomes reframework/autorun, and
source/data becomes reframework/data -- SharedData reads drdr_shared.json from
there at runtime. Copying only the autorun half leaves the mod running against
stale data, which looks exactly like a code bug: a table reads empty and every
lookup silently misses. That cost a debugging session once already.

Usage:
    py -3.12 deploy_dev.py [game_dir]

Defaults to the Steam install; override with DRAP_GAME_DIR or the argument.
"""
import json
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SRC_AUTORUN = os.path.join(REPO, "source", "autorun")
# Dev-only package (debug modules, DRAP_dev.lua). Installed here, never packed
# by build_release.py. Lands in the same reframework/autorun tree.
SRC_DEV_AUTORUN = os.path.join(REPO, "source", "dev", "autorun")
SRC_DATA = os.path.join(REPO, "source", "data")
# Loose asset overrides (PP sticker logo). Land at <game>/natives, which
# REFramework's LooseFileLoader reads -- and only when it is enabled.
SRC_NATIVES = os.path.join(REPO, "source", "natives")

DEFAULT_GAME = (
    r"C:\Program Files (x86)\Steam\steamapps\common\DEAD RISING DELUXE REMASTER"
)

# Files the manifest has never seen but earlier deploys put in autorun/.
LEGACY_REMOVE = ("DRAP/debug/ScoopExplorer.lua",)
MANIFEST = ".drap_deploy_manifest.json"

# Contributor notes rather than runtime assets; build_release skips these too.
SKIP_DATA = {".md", ".txt"}


def copy_tree(src: str, dst: str, copied=None) -> int:
    n = 0
    for root, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if d != "__pycache__"]
        for name in files:
            full = os.path.join(root, name)
            rel = os.path.relpath(full, src)
            out = os.path.join(dst, rel)
            os.makedirs(os.path.dirname(out), exist_ok=True)
            shutil.copyfile(full, out)
            if copied is not None:
                copied.append(rel.replace(os.sep, "/"))
            n += 1
    return n


def remove_stale(autorun_dir: str, fw: str, now: list) -> int:
    """Delete autorun files a previous deploy installed and this one did not,
    so a renamed or removed module stops being a live hook."""
    mpath = os.path.join(fw, MANIFEST)
    old = list(LEGACY_REMOVE)
    try:
        with open(mpath, encoding="utf-8") as f:
            old += json.load(f).get("autorun", [])
    except (OSError, ValueError):
        pass
    gone = 0
    for rel in sorted(set(old) - set(now)):
        path = os.path.join(autorun_dir, *rel.split("/"))
        if os.path.isfile(path):
            os.remove(path)
            gone += 1
            print(f"  removed stale {rel}")
    with open(mpath, "w", encoding="utf-8") as f:
        json.dump({"autorun": sorted(set(now))}, f, indent=1)
    return gone


def main() -> int:
    game = (sys.argv[1] if len(sys.argv) > 1
            else os.environ.get("DRAP_GAME_DIR", DEFAULT_GAME))
    fw = os.path.join(game, "reframework")
    if not os.path.isdir(fw):
        print(f"no reframework directory under {game}")
        return 1

    autorun_dir = os.path.join(fw, "autorun")
    copied = []
    n_lua = copy_tree(SRC_AUTORUN, autorun_dir, copied)
    n_dev = 0
    if os.path.isdir(SRC_DEV_AUTORUN):
        n_dev = copy_tree(SRC_DEV_AUTORUN, autorun_dir, copied)
    remove_stale(autorun_dir, fw, copied)

    n_data = 0
    data_out = os.path.join(fw, "data")
    os.makedirs(data_out, exist_ok=True)
    for name in os.listdir(SRC_DATA):
        full = os.path.join(SRC_DATA, name)
        if not os.path.isfile(full):
            continue
        if os.path.splitext(name)[1].lower() in SKIP_DATA:
            continue
        shutil.copyfile(full, os.path.join(data_out, name))
        n_data += 1

    n_nat = 0
    if os.path.isdir(SRC_NATIVES):
        n_nat = copy_tree(SRC_NATIVES, os.path.join(game, "natives"))

    print(f"  {n_lua} script(s) -> reframework/autorun")
    print(f"  {n_dev} dev script(s) -> reframework/autorun")
    print(f"  {n_data} data file(s) -> reframework/data")
    print(f"  {n_nat} loose asset(s) -> natives")
    print(f"  deployed to {game}")

    deploy_apworld()
    return 0


# Archipelago's real install -- the one that generates seeds. NOT the source
# checkout, which the test harness rebuilds on every run.
AP_INSTALL = r"C:\ProgramData\Archipelago"


def deploy_apworld():
    """Zip apworld/drdr into the AP install so new options are testable.

    Same shape gen_test.py builds, but aimed at the real install rather than
    the source checkout. Skipped quietly if Archipelago is not installed here.
    """
    import zipfile

    src = os.path.join(REPO, "apworld", "drdr")
    out_dir = os.path.join(AP_INSTALL, "custom_worlds")
    if not os.path.isdir(src):
        return
    if not os.path.isdir(AP_INSTALL):
        print(f"  apworld skipped -- {AP_INSTALL} not found")
        return

    os.makedirs(out_dir, exist_ok=True)
    dst = os.path.join(out_dir, "drdr.apworld")
    with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
        for root, dirs, files in os.walk(src):
            dirs[:] = [d for d in dirs if d != "__pycache__"]
            for f in files:
                full = os.path.join(root, f)
                arc = os.path.relpath(
                    full, os.path.join(REPO, "apworld")).replace(os.sep, "/")
                z.write(full, arc)
    print(f"  apworld -> {dst}")


if __name__ == "__main__":
    sys.exit(main())
