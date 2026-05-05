# apworld/drdr/shared_data.py
# Single source of truth for static data shared between Python (AP generation)
# and Lua (in-game enforcement): areas, time keys, items, survivors, stickers.
#
# The canonical JSON lives at source/data/drdr_shared.json (shipped alongside
# the Lua mod). A copy is committed here at apworld/drdr/drdr_shared.json so
# Python can find it when the apworld is packaged as a zip and the repo tree
# is not available.
#
# IMPORTANT: source/data/drdr_shared.json and apworld/drdr/drdr_shared.json
# MUST stay identical. Only edit the source/data/ copy, then run:
#     cp source/data/drdr_shared.json apworld/drdr/drdr_shared.json
# See source/data/README.md for the full sync rule.

import json
from pathlib import Path
from typing import Any, Dict, List, Optional


def _load() -> Dict[str, Any]:
    """Load drdr_shared.json from the package. Works whether the apworld is
    a packaged zip (.apworld) or an unpacked directory in the repo.

    Order of attempts:
      1. Filesystem path next to __file__ — works in the unpacked repo tree
         and when Archipelago has extracted the .apworld to disk.
      2. Loader-based read — works when __file__ points inside a zip
         (.apworld packed) and the package's loader can serve resources
         (zipimporter supports get_data(path)).
      3. Repo dev fallback — for generators run outside the apworld package.
    """
    # (1) Try the filesystem path first. Inside a packaged .apworld zip this
    # path won't resolve, so Path.is_file() returns False and we fall through.
    here = Path(__file__).resolve().parent
    fs_path = here / "drdr_shared.json"
    if fs_path.is_file():
        with fs_path.open("r", encoding="utf-8") as f:
            return json.load(f)

    # (2) Inside a zip: ask the module's loader for the file bytes. zipimporter
    # exposes get_data(fullpath) where fullpath is the absolute path that
    # __file__ claims to be. We derive the sibling drdr_shared.json path from
    # __file__ and hand it to the loader.
    loader = globals().get("__loader__")
    if loader is not None and hasattr(loader, "get_data"):
        resource_path = str(fs_path)
        try:
            data = loader.get_data(resource_path)
        except (OSError, FileNotFoundError):
            data = None
        if data:
            if isinstance(data, bytes):
                data = data.decode("utf-8")
            return json.loads(data)

    # (3) Repo dev fallback for tooling run outside Archipelago.
    dev_path = here.parent.parent / "source" / "data" / "drdr_shared.json"
    if dev_path.is_file():
        with dev_path.open("r", encoding="utf-8") as f:
            return json.load(f)

    raise FileNotFoundError(
        "drdr_shared.json not found: neither filesystem read, loader resource "
        f"read, nor repo fallback ({dev_path}) succeeded. If building a "
        ".apworld zip, ensure drdr_shared.json is committed inside "
        "apworld/drdr/ so it ends up bundled."
    )


_DATA: Dict[str, Any] = _load()

SCHEMA_VERSION: int = _DATA.get("schema_version", 0)

AREAS: List[Dict[str, Any]] = _DATA.get("areas", [])
TIME_KEYS: List[Dict[str, Any]] = _DATA.get("time_keys", [])
ITEMS: List[Dict[str, Any]] = _DATA.get("items", [])
SURVIVORS: List[Dict[str, Any]] = _DATA.get("survivors", [])
STICKERS: List[Dict[str, Any]] = _DATA.get("stickers", [])

# Scoop name -> list of survivor display names rescued as part of that scoop.
# Only includes scoops whose Lua SCOOP_DATA.npcs contains at least one name
# matching a "Rescue X" location in Locations.py.
SCOOP_SURVIVORS: Dict[str, List[str]] = _DATA.get("scoop_survivors", {})

# AP-trigger locations: PP-bonus events + key-item ToDo banners that DRAP
# detects via MsgEvents and converts into AP location checks. See the
# "ap_trigger_locations" section of drdr_shared.json for the schema.
AP_TRIGGER_LOCATIONS: List[Dict[str, Any]] = _DATA.get("ap_trigger_locations", [])


def expand_trigger_location_names(entry: Dict[str, Any]) -> List[str]:
    """Generate the full list of location names produced by one trigger entry.

    For "single" entries, returns a one-element list with the location_name.
    For "counted" entries, returns max_count names (using singular template
    for n=1, plural template for n>1) plus the all_location_name (if set).
    """
    t = entry.get("type")
    if t == "single":
        n = entry.get("location_name")
        return [n] if n else []
    if t == "counted":
        names: List[str] = []
        max_count = int(entry.get("max_count", 0))
        sing = entry.get("location_template_singular", "")
        plur = entry.get("location_template_plural", "")
        for n in range(1, max_count + 1):
            if n == 1 and sing:
                names.append(sing)
            elif plur:
                names.append(plur.format(n=n))
        all_name = entry.get("all_location_name")
        if all_name:
            names.append(all_name)
        return names
    return []


def _tier_for_count(entry: Dict[str, Any], count: int) -> Optional[Dict[str, Any]]:
    """Find the count_tier whose max_count is >= count. Returns the dict
    with `regions`. None if no count_tiers field is set on this entry."""
    tiers = entry.get("count_tiers")
    if not tiers:
        return None
    for tier in tiers:
        if count <= int(tier.get("max_count", 0)):
            return tier
    # Fall through to last tier if count exceeds the highest declared max
    return tiers[-1] if tiers else None


def trigger_location_region(entry: Dict[str, Any], count: Optional[int] = None,
                             is_all_variant: bool = False) -> Optional[str]:
    """Return the AP region the location at `count` should be placed in.

    For "single" entries, returns entry.region. For "counted" entries with
    count_tiers, returns the most-recently-added region for the tier
    covering this count (regions[-1]). For all-variant locations, uses the
    highest tier's last region. Falls back to entry.region if no tiers are
    declared (existing single-region entries keep the simple field).
    """
    if is_all_variant:
        tiers = entry.get("count_tiers")
        if tiers:
            return tiers[-1]["regions"][-1]
        return entry.get("region")
    if count is not None:
        tier = _tier_for_count(entry, count)
        if tier and tier.get("regions"):
            return tier["regions"][-1]
    return entry.get("region")


def trigger_location_required_regions(entry: Dict[str, Any],
                                       count: Optional[int] = None,
                                       is_all_variant: bool = False) -> List[str]:
    """Return the full list of regions that must be reachable to satisfy
    the rule for the location at `count`. For tier-aware entries, returns
    all regions in the matching tier. For non-tiered entries, returns
    [entry.region] if set."""
    if is_all_variant:
        tiers = entry.get("count_tiers")
        if tiers:
            return list(tiers[-1].get("regions", []))
        r = entry.get("region")
        return [r] if r else []
    if count is not None:
        tier = _tier_for_count(entry, count)
        if tier:
            return list(tier.get("regions", []))
    r = entry.get("region")
    return [r] if r else []

# Convenience views for generation-side use.

# Key item names that belong in the AP item pool (excludes starting areas
# like Heliport/Security Room, which Lua tracks but Python does not precollect).
AREA_KEY_NAMES: List[str] = [
    a["key_item"]
    for a in AREAS
    if a.get("in_item_pool") and a.get("key_item")
]

TIME_KEY_NAMES: List[str] = [t["name"] for t in TIME_KEYS if t.get("name")]


def area_by_name(name: str) -> Optional[Dict[str, Any]]:
    for a in AREAS:
        if a.get("name") == name:
            return a
    return None
