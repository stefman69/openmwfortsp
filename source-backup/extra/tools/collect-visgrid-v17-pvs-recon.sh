#!/usr/bin/env bash
set -Eeuo pipefail

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/visgrid-v17-pvs-recon-$STAMP.txt"
CTR="openmw_builder"
SRC="/root/openmw-0.51-tsp-src"
DEV="${TSP_DEV:-root@192.168.1.25}"
ROOT="/mnt/SDCARD/data/ports/openmw51"

err() {
    rc=$?
    line=$1
    cmd=$2
    trap - ERR
    {
        echo
        echo "=================================================================="
        echo "V17 PVS RECON STOPPED"
        echo "=================================================================="
        echo "Exit code: $rc"
        echo "Line: $line"
        echo "Command: $cmd"
        echo "Partial recon preserved: $OUT"
    } | tee -a "$OUT"
    exit "$rc"
}
trap 'err "$LINENO" "$BASH_COMMAND"' ERR

exec > >(tee "$OUT") 2>&1

echo "######################################################################"
echo "VISGRID V17 NAVMESH-PVS SOURCE RECON"
echo "######################################################################"
echo "Generated: $(date)"
echo "Host: $(hostname)"
echo "Container: $CTR"
echo "Output: $OUT"
echo

echo "===== 1/8 VERIFY / START CONTAINER ====="
if ! docker inspect "$CTR" >/dev/null 2>&1; then
    echo "ERROR: Docker container '$CTR' does not exist."
    exit 20
fi
if [ "$(docker inspect -f '{{.State.Running}}' "$CTR")" != "true" ]; then
    docker start "$CTR" >/dev/null
fi
docker exec "$CTR" test -d "$SRC"
echo "PASS: container/source available."
echo

echo "===== 2/8 SOURCE STATE + HASHES ====="
docker exec "$CTR" bash -lc "
set -e
cd '$SRC'
echo '--- git ---'
git rev-parse HEAD || true
git branch --show-current || true
git status --short || true
echo
echo '--- source hashes ---'
sha256sum \
  apps/openmw/mwrender/interiorvisibility.hpp \
  apps/openmw/mwrender/interiorvisibility.cpp \
  apps/openmw/mwrender/animation.hpp \
  apps/openmw/mwrender/animation.cpp \
  apps/openmw/mwrender/objects.hpp \
  apps/openmw/mwrender/objects.cpp \
  apps/openmw/mwlua/camerabindings.cpp \
  apps/openmw/CMakeLists.txt \
  components/sceneutil/lightmanager.cpp \
  apps/openmw/mwworld/ptr.hpp \
  apps/openmw/mwworld/refdata.hpp \
  apps/openmw/mwworld/refdata.cpp 2>/dev/null || true
"
echo

echo "===== 3/8 CURRENT DEVICE STATE (BEST EFFORT) ====="
ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" "
  date
  hostname
  sha256sum \
    '$ROOT/bin/openmw-0.51' \
    '$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua' \
    '$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/topology.lua' \
    '$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/interiormap.lua' 2>/dev/null || true
  echo
  grep -aE 'TSP_INTERIOR_VISGRID_051_V1|TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG|TSP_INTERIOR_VISGRID_051_V4_CULLFOG|TSP_LUAJIT_SAFE_051_V1' \
    '$ROOT/bin/openmw-0.51' 2>/dev/null | head -30 || true
" || echo "WARNING: device unavailable; source recon continues."
echo

echo "===== 4/8 EXACT CURRENT VISGRID ENGINE SOURCE ====="
for f in \
    apps/openmw/mwrender/interiorvisibility.hpp \
    apps/openmw/mwrender/interiorvisibility.cpp \
    apps/openmw/mwlua/camerabindings.cpp \
    components/sceneutil/lightmanager.cpp
do
    echo
    echo "######################################################################"
    echo "FULL FILE: $SRC/$f"
    echo "######################################################################"
    docker exec "$CTR" bash -lc "nl -ba '$SRC/$f'"
done
echo

echo "===== 5/8 OBJECT ROOT / POSITION / CALLBACK CONTEXT ====="
docker exec "$CTR" bash -lc "
set -e
echo '--- animation: constructors + object root + cull callbacks ---'
grep -nE -B35 -A70 \
  'Animation::Animation|mObjectRoot|InteriorVisibilityCullCallback|LightListCallback|isActor\\(\\)' \
  '$SRC/apps/openmw/mwrender/animation.cpp' || true

echo
echo '--- animation.hpp relevant state ---'
grep -nE -B30 -A45 \
  'class Animation|mObjectRoot|MWWorld::Ptr|mPtr|LightListCallback' \
  '$SRC/apps/openmw/mwrender/animation.hpp' || true

echo
echo '--- objects.cpp creation/insertion/position paths ---'
grep -nE -B35 -A80 \
  'insert|addObject|create|Animation|ObjectAnimation|getRefData\\(\\).*getPosition|getPosition\\(\\)|getCellRef|setPosition|mObjects' \
  '$SRC/apps/openmw/mwrender/objects.cpp' || true

echo
echo '--- objects.hpp relevant declarations ---'
grep -nE -B25 -A55 \
  'class Objects|insert|addObject|Animation|ObjectAnimation|mObjects' \
  '$SRC/apps/openmw/mwrender/objects.hpp' || true
"
echo

echo "===== 6/8 MWWorld POSITION / TYPE APIs ====="
docker exec "$CTR" bash -lc "
set -e
for f in \
  apps/openmw/mwworld/ptr.hpp \
  apps/openmw/mwworld/refdata.hpp \
  apps/openmw/mwworld/refdata.cpp
do
  echo
  echo '######################################################################'
  echo \"FILE: $SRC/\$f\"
  echo '######################################################################'
  grep -nE -B30 -A60 \
    'getRefData|getPosition|setPosition|getCell|isActor|getTypeName|getClass|asVec|Position' \
    \"$SRC/\$f\" || true
done

echo
echo '--- all current renderer uses of placed object position ---'
grep -RInE \
  'getRefData\\(\\)\\.getPosition\\(\\)|getPosition\\(\\).*asVec|\\.pos\\[[012]\\]' \
  '$SRC/apps/openmw/mwrender' \
  '$SRC/apps/openmw/mwworld' 2>/dev/null | head -500 || true
"
echo

echo "===== 7/8 CELL/OBJECT LOAD PATH + STATIC TYPE CHECKS ====="
docker exec "$CTR" bash -lc "
set -e
echo '--- scene object insertion/navmesh registration ---'
grep -nE -B40 -A90 \
  'addObject\\(|insertObject|insertMesh|loadCell|addCell|isActor\\(\\)|ESM::Static|DoorShapes|ObjectShapes' \
  '$SRC/apps/openmw/mwworld/scene.cpp' || true

echo
echo '--- type/class helpers used to distinguish statics/doors/actors ---'
grep -RInE \
  'ESM::Static|isActor\\(\\)|getTypeName\\(\\)|getClass\\(\\).*isActor|typeid\\(ESM::Static' \
  '$SRC/apps/openmw/mwrender' '$SRC/apps/openmw/mwworld' 2>/dev/null | head -700 || true
"
echo

echo "===== 8/8 BUILD / LINK CONTEXT ====="
docker exec "$CTR" bash -lc "
set -e
echo '--- CMake VISGRID entries ---'
grep -nE -B15 -A25 'interiorvisibility|mwrender/animation|mwrender/objects' '$SRC/apps/openmw/CMakeLists.txt' || true
echo
echo '--- existing source backups touching target files ---'
find '$SRC/.tsp-051-source-backups' -maxdepth 3 -type f 2>/dev/null \
  | grep -E 'interiorvisibility|animation|objects|camerabindings' \
  | tail -200 || true
"
echo

echo "######################################################################"
echo "V17 PVS RECON COMPLETE"
echo "######################################################################"
echo "Saved directly in Downloads:"
echo "  $OUT"
echo
echo "Send that one file back to ChatGPT."
