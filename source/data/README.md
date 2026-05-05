# Shared data

`drdr_shared.json` is the canonical source of truth for data shared between
the Python APWorld (seed generation) and the Lua mod (in-game enforcement):
areas, time keys, items, survivors, stickers.

## Sync rule (before every release and every commit that touches drdr_shared.json)

Two copies of this file exist in the repo. They MUST stay identical:

- `source/data/drdr_shared.json`   — shipped with the Lua mod
- `apworld/drdr/drdr_shared.json`  — bundled inside the .apworld zip

Only edit `source/data/drdr_shared.json`. Then sync by copying:

```bash
cp source/data/drdr_shared.json apworld/drdr/drdr_shared.json
```

A git pre-commit check or a diff before tagging a release will catch drift:

```bash
diff source/data/drdr_shared.json apworld/drdr/drdr_shared.json && echo "in sync"
```

If this file ever needs a schema change, bump `schema_version` and update both
loaders (`apworld/drdr/shared_data.py` and `source/autorun/DRAP/SharedData.lua`).
