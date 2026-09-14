#!/usr/bin/env bash
set -Eeuo pipefail

# OpenMW 0.51 / TSP
# READ-ONLY object-class + physics creation recon.
#
# This collector is intentionally pure shell. It contains NO embedded Python
# and makes NO source, build, or device changes.

CTR="${TSP_BUILDER:-openmw_builder}"
DEV="${TSP_DEV:-root@192.168.1.25}"
SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"
ROOT="/mnt/SDCARD/data/ports/openmw51"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/openmw51-object-creation-physics-recon-$STAMP.txt"

section() {
    echo
    echo "######################################################################"
    echo "# $*"
    echo "######################################################################"
}

dump_if_exists() {
    local rel="$1"
    section "FULL FILE: $rel"
    docker exec "$CTR" bash -lc "
        if [ -f '$SRC/$rel' ]; then
            sha256sum '$SRC/$rel'
            nl -ba '$SRC/$rel'
        else
            echo 'MISSING: $SRC/$rel'
        fi
    "
}

exec > >(tee "$OUT") 2>&1

section "OPENMW 0.51 OBJECT CREATION / PHYSICS RECON"
echo "Collected: $(date)"
echo "Host:      $(hostname)"
echo "Container: $CTR"
echo "Device:    $DEV"
echo "Output:    $OUT"
echo
echo "READ-ONLY: no patch, no build, no install, no navmesh changes."

section "1. VERIFY CURRENT DOCKER TREE"
if ! docker inspect "$CTR" >/dev/null 2>&1; then
    echo "ERROR: Docker container '$CTR' does not exist."
    exit 20
fi
if [ "$(docker inspect -f '{{.State.Running}}' "$CTR")" != "true" ]; then
    docker start "$CTR" >/dev/null
fi
docker exec "$CTR" test -d "$SRC"

docker exec "$CTR" bash -lc "
    cd '$SRC'
    echo '--- git identity ---'
    git rev-parse HEAD || true
    git branch --show-current || true
    echo
    echo '--- status ---'
    git status --short || true
    echo
    echo '--- current build ---'
    for f in '$BUILD/openmw' '$BUILD/apps/openmw/openmw' '/root/openmw-0.51-tsp-package/bin/openmw-0.51'; do
        [ -f \"\$f\" ] || continue
        file \"\$f\"
        sha256sum \"\$f\"
    done
"

section "2. DEVICE BINARY / DIAGNOSTIC STATE"
ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" "
    set +e
    date
    sha256sum '$ROOT/bin/openmw-0.51' 2>/dev/null
    grep -aE \
      'TSP_OBJECT_DIAG_051_V1|TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS|TSP_SAFENAV' \
      '$ROOT/bin/openmw-0.51' 2>/dev/null | head -40 || true
" || echo "WARNING: device unavailable; Docker recon continues."

section "3. CLASS REGISTRATION / VIRTUAL DISPATCH"
for rel in \
    apps/openmw/mwclass/classes.cpp \
    apps/openmw/mwclass/classes.hpp \
    apps/openmw/mwworld/class.cpp \
    apps/openmw/mwworld/class.hpp
do
    dump_if_exists "$rel"
done

section "4. ALL RELEVANT MWCLASS IMPLEMENTATIONS"
for base in \
    container misc book weapon ingredient potion apparatus armor clothing \
    activator light static door lockpick probe repair
do
    for ext in cpp hpp; do
        rel="apps/openmw/mwclass/$base.$ext"
        if docker exec "$CTR" test -f "$SRC/$rel"; then
            dump_if_exists "$rel"
        fi
    done
done

section "5. MWCLASS INSERT / RENDER / PHYSICS METHOD INDEX"
docker exec "$CTR" bash -lc "
    cd '$SRC'
    grep -RInE -B5 -A18 \
      'insertObjectRendering|insertObjectPhysics|insertObject\\(|getModel\\(|RegisteredClass|registerClass' \
      apps/openmw/mwclass apps/openmw/mwworld/class.cpp apps/openmw/mwworld/class.hpp \
      2>/dev/null || true
"

section "6. EXACT PHYSICS OBJECT CREATION SOURCE"
for rel in \
    apps/openmw/mwphysics/physicssystem.cpp \
    apps/openmw/mwphysics/physicssystem.hpp \
    apps/openmw/mwphysics/object.cpp \
    apps/openmw/mwphysics/object.hpp \
    apps/openmw/mwphysics/collisiontype.cpp \
    apps/openmw/mwphysics/collisiontype.hpp \
    apps/openmw/mwphysics/ptrholder.cpp \
    apps/openmw/mwphysics/ptrholder.hpp
do
    if docker exec "$CTR" test -f "$SRC/$rel"; then
        dump_if_exists "$rel"
    fi
done

section "7. PHYSICS addObject / getObject / SHAPE DECISION INDEX"
docker exec "$CTR" bash -lc "
    cd '$SRC'
    grep -RInE -B15 -A70 \
      'PhysicsSystem::addObject|addObject\\(|getObject\\(|mObjects|BulletShape|ShapeInstance|CollisionType_World|VisualCollisionType|markAsNonSolid' \
      apps/openmw/mwphysics \
      2>/dev/null || true
"

section "8. BULLET / COLLISION SHAPE RESOURCE SOURCE"
docker exec "$CTR" bash -lc "
    cd '$SRC'
    find components -maxdepth 3 -type f \
      \\( -iname '*bullet*shape*.cpp' -o -iname '*bullet*shape*.hpp' \
         -o -path '*/nifbullet/*.cpp' -o -path '*/nifbullet/*.hpp' \\) \
      -print | sort
"

while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    dump_if_exists "$rel"
done < <(
    docker exec "$CTR" bash -lc "
        cd '$SRC'
        find components -maxdepth 3 -type f \
          \\( -iname '*bullet*shape*.cpp' -o -iname '*bullet*shape*.hpp' \
             -o -path '*/nifbullet/*.cpp' -o -path '*/nifbullet/*.hpp' \\) \
          -print | sort
    "
)

section "9. ALL TSP MARKERS IN CLASS / PHYSICS / COLLISION AREAS"
docker exec "$CTR" bash -lc "
    cd '$SRC'
    grep -RInE \
      'TSP_|OPENMW_TSP|Free FPS|FREEFPS|small object|small-object|collision.*skip|skip.*collision|physics.*skip|skip.*physics' \
      apps/openmw/mwclass \
      apps/openmw/mwphysics \
      apps/openmw/mwworld/class.cpp \
      apps/openmw/mwworld/class.hpp \
      components/resource \
      components/nifbullet \
      2>/dev/null || true
"

section "10. CURRENT TREE DIFF VS GIT HEAD"
docker exec "$CTR" bash -lc "
    cd '$SRC'
    echo '--- diff stat ---'
    git diff --stat HEAD -- \
      apps/openmw/mwclass \
      apps/openmw/mwphysics \
      apps/openmw/mwworld/class.cpp \
      apps/openmw/mwworld/class.hpp \
      components/resource \
      components/nifbullet || true

    echo
    echo '--- changed names ---'
    git diff --name-status HEAD -- \
      apps/openmw/mwclass \
      apps/openmw/mwphysics \
      apps/openmw/mwworld/class.cpp \
      apps/openmw/mwworld/class.hpp \
      components/resource \
      components/nifbullet || true

    echo
    echo '--- complete diff ---'
    git diff --no-ext-diff --unified=80 HEAD -- \
      apps/openmw/mwclass \
      apps/openmw/mwphysics \
      apps/openmw/mwworld/class.cpp \
      apps/openmw/mwworld/class.hpp \
      components/resource \
      components/nifbullet || true
"

section "11. HISTORY OF OBJECT-CLASS / PHYSICS SOURCE"
docker exec "$CTR" bash -lc "
    cd '$SRC'
    git log --all --date=iso --pretty=format:'%H | %ad | %d | %s' -n 160 -- \
      apps/openmw/mwclass \
      apps/openmw/mwphysics \
      apps/openmw/mwworld/class.cpp \
      apps/openmw/mwworld/class.hpp \
      components/resource \
      components/nifbullet || true
"

section "12. SOURCE BACKUPS TOUCHING CLASS / PHYSICS"
docker exec "$CTR" bash -lc "
    set +e
    find '$SRC/.tsp-051-source-backups' -type f 2>/dev/null \
      | grep -E \
        '/(mwclass|mwphysics)/|/mwworld/class\\.(cpp|hpp)$|bullet.*shape|nifbullet' \
      | sort \
      | tail -600
"

section "13. BACKUP HASH / METHOD SNAPSHOT"
docker exec "$CTR" bash -lc "
    set +e
    find '$SRC/.tsp-051-source-backups' -type f 2>/dev/null \
      | grep -E \
        '/mwclass/(container|misc|book|weapon|ingredient|potion|apparatus|armor|clothing|activator|light|static|door)\\.cpp$|/mwphysics/physicssystem\\.cpp$|/mwworld/class\\.cpp$' \
      | sort \
      | tail -250 \
      | while read -r f; do
          echo
          echo \"===== BACKUP: \$f =====\"
          sha256sum \"\$f\"
          grep -nE -B4 -A16 \
            'insertObjectRendering|insertObjectPhysics|insertObject\\(|PhysicsSystem::addObject|registerClass|RegisteredClass' \
            \"\$f\" 2>/dev/null || true
        done
"

section "14. GLOBAL SEARCH FOR INSERTION SHORT-CIRCUITS"
docker exec "$CTR" bash -lc "
    cd '$SRC'
    grep -RInE -B12 -A35 \
      'insertObjectRendering|insertObjectPhysics|PhysicsSystem::addObject|mObjects\\.emplace|mObjects\\.insert|mObjects\\[|getClass\\(\\)\\.insertObject' \
      apps/openmw \
      2>/dev/null | head -12000 || true
"

section "15. RECON COMPLETE"
echo
echo "This report should answer:"
echo "  - whether the affected MWClass overrides were removed or bypassed"
echo "  - whether class registration is incomplete/wrong"
echo "  - whether PhysicsSystem::addObject rejects these object classes/shapes"
echo "  - whether a TSP patch touched the shared creation path"
echo "  - which exact backup/git state contains the last correct code"
echo
echo "Saved:"
echo "  $OUT"
echo
echo "Upload that ONE .txt file back to ChatGPT."
