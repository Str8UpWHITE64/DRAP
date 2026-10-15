"""The release test must reject dev files and dev references.

    py -3.12 tools/test_release_no_dev.py

Feeds build_release.dev_problems a clean file list, then each kind of leak.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_release as br  # noqa: E402

CLEAN = {
    "reframework/autorun/AP_DRDR_main.lua": b'local X = require("DRAP/Logger")\n',
    "reframework/autorun/DRAP/Logger.lua": b"return {}\n",
    "reframework/data/drdr_shared.json": b"{}\n",
}


def run(files):
    return br.dev_problems(list(files), lambda n: files[n])


def main():
    assert run(CLEAN) == [], run(CLEAN)

    leaks = {
        "dev entry": {"reframework/autorun/DRAP_dev.lua": b""},
        "debug dir": {"reframework/autorun/DRAP/debug/StateProbe.lua": b""},
        "probes": {"reframework/autorun/probes/x.lua": b""},
        "devctl": {"reframework/autorun/DRAP_DevControl.lua": b"", "reframework/autorun/devctl/h4.lua": b""},
        "require": {"reframework/autorun/AP_DRDR_main.lua": b'require("DRAP/debug/StateProbe")'},
        "k.debug": {"reframework/autorun/DRAP/X.lua": b"k.debug.x()"},
    }
    for name, extra in leaks.items():
        got = run({**CLEAN, **extra})
        assert got, f"release test missed: {name}"
        print(f"  caught {name}: {len(got)} problem(s)")
    print("release no-dev test passed")


if __name__ == "__main__":
    main()
