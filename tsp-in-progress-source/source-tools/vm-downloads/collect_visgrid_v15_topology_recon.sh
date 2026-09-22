#!/usr/bin/env bash
set -Eeuo pipefail

C="${TSP_BUILDER:-openmw_builder}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/visgrid-v15-topology-recon-$STAMP.txt"
ROOT="/mnt/SDCARD/data/ports/openmw51"
MOD="$ROOT/mods/TSPInteriorVisGrid"

if [ -f "$HOME/Downloads/visgrid-tools/device.env" ]; then
    # shellcheck disable=SC1091
    . "$HOME/Downloads/visgrid-tools/device.env" || true
fi
if [ -n "${TSP_IP:-}" ]; then
    DEV="root@$TSP_IP"
else
    DEV="${TSP_DEV:-root@192.168.1.25}"
fi

command -v docker >/dev/null
command -v ssh >/dev/null

if [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null || true)" != "true" ]; then
    docker start "$C" >/dev/null
fi

{
echo "######################################################################"
echo "VISGRID V15 TOPOLOGY / NAVMESH RECON"
echo "######################################################################"
echo "Generated: $(date)"
echo "Container: $C"
echo "Device:    $DEV"
echo

echo "######################################################################"
echo "SECTION 1 — EXACT ACTIVE DEVICE STATE"
echo "######################################################################"
ssh "$DEV" "
set +e
echo '--- date/hostname ---'
date; hostname
echo
echo '--- installed hashes ---'
sha256sum \
  '$ROOT/bin/openmw-0.51' \
  '$MOD/scripts/TSPInteriorVisGrid/visgrid.lua' \
  '$MOD/scripts/TSPInteriorVisGrid/interiormap.lua' \
  '$MOD/TSPInteriorVisGrid.omwscripts' 2>/dev/null
echo
echo '--- binary markers ---'
for m in \
 TSP_INTERIOR_VISGRID_051_V1 \
 TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG \
 TSP_INTERIOR_VISGRID_051_V4_CULLFOG \
 TSP_INTERIOR_VISGRID_051_V4B_BORDERFOG \
 TSP_INTERIOR_SCAN_051_V1 \
 TSP_LUAJIT_SAFE_051_V1
do
  if grep -a -q \"\$m\" '$ROOT/bin/openmw-0.51'; then echo \"YES \$m\"; else echo \"no  \$m\"; fi
done
echo
echo '--- active sensor markers ---'
grep -nE 'TSP_VISGRID_LUA|TSP_INTERIOR_VISGRID_LUA|LOADSAFE|POST_LOAD_ARM_DELAY|V14|V13' \
 '$MOD/scripts/TSPInteriorVisGrid/visgrid.lua' 2>/dev/null | head -120
echo
echo '--- exact active sensor ---'
cat '$MOD/scripts/TSPInteriorVisGrid/visgrid.lua' 2>/dev/null
echo
echo '--- exact active interiormap.lua ---'
cat '$MOD/scripts/TSPInteriorVisGrid/interiormap.lua' 2>/dev/null
echo
echo '--- scan header + Caldera + sample cells + footer ---'
head -8 '$ROOT/tsp_interior_scan.txt' 2>/dev/null
grep -F \"Caldera, Governor's Hall\" '$ROOT/tsp_interior_scan.txt' 2>/dev/null
grep '^CELL' '$ROOT/tsp_interior_scan.txt' 2>/dev/null | head -20
tail -8 '$ROOT/tsp_interior_scan.txt' 2>/dev/null
echo
echo '--- navmesh db ---'
ls -lh /mnt/UDISK/openmw51-nav/navmesh.db 2>/dev/null
sha256sum /mnt/UDISK/openmw51-nav/navmesh.db 2>/dev/null
if command -v sqlite3 >/dev/null 2>&1 && [ -s /mnt/UDISK/openmw51-nav/navmesh.db ]; then
  echo '.tables'
  sqlite3 /mnt/UDISK/openmw51-nav/navmesh.db '.tables' 2>/dev/null
  echo '.schema'
  sqlite3 /mnt/UDISK/openmw51-nav/navmesh.db '.schema' 2>/dev/null
fi
"

echo
echo "######################################################################"
echo "SECTION 2 — CURRENT CUSTOM VISGRID / FOG / SCANNER SOURCE"
echo "######################################################################"

docker exec -i "$C" bash -s <<'DOCK'
set +e
SRC=/root/openmw-0.51-tsp-src

full() {
    local f="$1"
    echo
    echo "======================================================================"
    echo "FULL FILE: $f"
    echo "======================================================================"
    if [ -f "$f" ]; then
        nl -ba "$f"
    else
        echo "MISSING: $f"
    fi
}

window() {
    local f="$1" pat="$2"
    echo
    echo "======================================================================"
    echo "WINDOWS: $f :: $pat"
    echo "======================================================================"
    [ -f "$f" ] || { echo "MISSING"; return; }
    grep -nE "$pat" "$f" | head -40
    for n in $(grep -nE "$pat" "$f" | head -20 | cut -d: -f1); do
        s=$((n-35)); [ "$s" -lt 1 ] && s=1
        e=$((n+90))
        echo "----- $f lines $s..$e -----"
        sed -n "${s},${e}p" "$f" | nl -ba -v"$s" -w6 -s'| '
    done
}

full "$SRC/apps/openmw/mwrender/interiorvisibility.hpp"
full "$SRC/apps/openmw/mwrender/interiorvisibility.cpp"

window "$SRC/apps/openmw/mwrender/renderingmanager.cpp" \
 'TSP_INTERIOR_VISGRID|TSP_INTERIOR_SCAN|CullNear|FogGuide|setViewDistance|void RenderingManager::update'

window "$SRC/apps/openmw/mwlua/camerabindings.cpp" \
 'InteriorVisibility|setInteriorVisibilityGrid|getInteriorVisibility|getViewDistance|viewportToWorldVector|worldToViewportVector'

echo
echo "######################################################################"
echo "SECTION 3 — CELL / WORLD / DOOR APIs"
echo "######################################################################"

for f in \
 "$SRC/apps/openmw/mwbase/environment.hpp" \
 "$SRC/apps/openmw/mwbase/world.hpp" \
 "$SRC/apps/openmw/mwworld/worldmodel.hpp" \
 "$SRC/apps/openmw/mwworld/worldmodel.cpp" \
 "$SRC/apps/openmw/mwworld/cellstore.hpp" \
 "$SRC/apps/openmw/mwworld/cellstore.cpp" \
 "$SRC/apps/openmw/mwworld/ptr.hpp" \
 "$SRC/apps/openmw/mwworld/livecellref.hpp"
do
    window "$f" 'getWorldModel|getInterior|forEach|load\(|getPosition|getRefId|getType|Door|door|bounds|Bound|AABB|Navigator|navmesh'
done

echo
echo "######################################################################"
echo "SECTION 4 — NAVIGATION / NAVMESH FILE INVENTORY"
echo "######################################################################"

find "$SRC/apps/openmw" "$SRC/components" -type f \
  \( -iname '*nav*.hpp' -o -iname '*nav*.cpp' -o -path '*/detournavigator/*' \) \
  2>/dev/null | sort

echo
echo "######################################################################"
echo "SECTION 5 — NAVIGATION SYMBOL SEARCH"
echo "######################################################################"

grep -RInE \
 'class Navigator|struct Navigator|getNavigator|Navigator::|NavMesh|navMesh|navmesh|DetourNavigator|dtNavMesh|findPath|findRandomPoint|findNearest|findStraight|tileCache|NavMeshDb|NavMeshDB|AreaType' \
 "$SRC/apps/openmw" "$SRC/components/detournavigator" \
 2>/dev/null | head -2500

echo
echo "######################################################################"
echo "SECTION 6 — LIKELY NAVIGATION HEADERS / CORE IMPLEMENTATION"
echo "######################################################################"

for f in $(find "$SRC/apps/openmw" "$SRC/components/detournavigator" -type f \
  \( -iname 'navigator.hpp' -o -iname 'navigator.cpp' \
     -o -iname 'navmesh.hpp' -o -iname 'navmesh.cpp' \
     -o -iname '*navmeshdb*.hpp' -o -iname '*navmeshdb*.cpp' \
     -o -iname '*navmeshtile*.hpp' -o -iname '*navmeshtile*.cpp' \
     -o -iname '*navigatorimpl*.hpp' -o -iname '*navigatorimpl*.cpp' \) \
  2>/dev/null | sort -u); do
    full "$f"
done

echo
echo "######################################################################"
echo "SECTION 7 — DOOR / NEARBY LUA APIs"
echo "######################################################################"

grep -RInE \
 'nearby.*doors|api\["doors"\]|castRay|COLLISION_TYPE.*Door|DoorState|isOpen|openState' \
 "$SRC/apps/openmw/mwlua" "$SRC/apps/openmw/mwworld" \
 2>/dev/null | head -1200

DOCK

echo
echo "######################################################################"
echo "SECTION 8 — CURRENT DEVICE RUNTIME EVIDENCE"
echo "######################################################################"
ssh "$DEV" "
set +e
echo '--- latest VISGRID / load / fog lines ---'
grep -hE \
 'TSP_VISGRID|TSP_INTERIOR_VISGRID|TSP_LOAD_FREEZE|TSP_WARMDRAW_GATE|Lua.*ERROR|Lua.*error' \
 '$ROOT/openmw_051_log.txt' '$ROOT/config-0.51/openmw.log' \
 2>/dev/null | tail -1200
echo
echo '--- perf tail ---'
tail -240 '$ROOT/openmw51_perf_latest.txt' 2>/dev/null
"

echo
echo "######################################################################"
echo "END V15 TOPOLOGY RECON"
echo "######################################################################"
} 2>&1 | tee "$OUT"

echo
echo "Saved complete recon:"
echo "  $OUT"
echo
echo "Upload that ONE .txt file back to ChatGPT."
