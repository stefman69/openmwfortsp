#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: patch_v20_door_bypass.py SOURCE_ROOT BACKUP_ROOT")

src = Path(sys.argv[1])
backup = Path(sys.argv[2])
rel = Path("apps/openmw/mwrender/animation.cpp")
p = src / rel

if not p.is_file():
    raise SystemExit("ERROR: missing " + str(p))

t = p.read_text()

v20 = '''        if (!mPtr.getClass().isActor() && !mPtr.getClass().isDoor())
        {
            // TSP_INTERIOR_VISGRID_051_V6_DOOR_BYPASS
            // Real ESM doors never enter the VISGRID screen-depth callback.
            // This is intentionally independent of topology: teleport/load
            // doors must remain drawable even when no navmesh portal exists.
            // Structural PVS already only applies to ESM::Static objects.
            // TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS
'''

v17 = '''        if (!mPtr.getClass().isActor())
        {
            // TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS
'''

if v20 in t:
    if "new InteriorVisibilityCullCallback(tspPvsOrigin, tspPvsRadius, tspPvsEligible)" not in t:
        raise SystemExit("ERROR: V20 marker exists but V17 callback body is incomplete.")
    print("SOURCE_STATE=V20_ALREADY_PATCHED")
    raise SystemExit(0)

if t.count(v17) != 1:
    raise SystemExit(
        "ERROR: expected exactly one V17 animation callback anchor; found %d. "
        "ZERO source edits." % t.count(v17)
    )

bp = backup / rel
bp.parent.mkdir(parents=True, exist_ok=True)
bp.write_bytes(p.read_bytes())
if bp.read_bytes() != p.read_bytes():
    raise SystemExit("ERROR: source backup byte verification failed. ZERO source edits.")

t = t.replace(v17, v20, 1)

for needle in (
    "TSP_INTERIOR_VISGRID_051_V6_DOOR_BYPASS",
    "!mPtr.getClass().isDoor()",
    "new InteriorVisibilityCullCallback(tspPvsOrigin, tspPvsRadius, tspPvsEligible)",
):
    if needle not in t:
        raise SystemExit("ERROR: postcondition missing: " + needle)

p.write_text(t)
print("SOURCE_STATE=V20_PATCHED")
print("BACKUP=" + str(bp))
