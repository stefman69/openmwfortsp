#!/usr/bin/env bash
set -Eeuo pipefail

# OpenMW 0.51 / TrimUI Smart Pro
# READ-ONLY object visibility + activation + VISGRID recon collector.
#
# Purpose:
#   Capture the exact CURRENT Docker source and CURRENT TSP runtime needed to
#   diagnose:
#     - missing interior clutter / containers / gameplay refs
#     - VISGRID callback eligibility and PVS handling
#     - exterior object paging / paged-ref suppression
#     - activation ray -> PtrHolder / RefnumMarker resolution
#
# This script DOES NOT edit source, build OpenMW, replace device files,
# regenerate navmesh, or alter VISGRID data.

CTR="${TSP_BUILDER:-openmw_builder}"
DEV="${TSP_DEV:-root@192.168.1.25}"
SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"

ROOT="/mnt/SDCARD/data/ports/openmw51"
GAME="$ROOT/bin/openmw-0.51"
MOD="$ROOT/mods/TSPInteriorVisGrid"
BASE="$MOD/scripts/TSPInteriorVisGrid"
LIVE_LUA="$BASE/visgrid.lua"
TOPO="$BASE/topology.lua"
TOPO_CELLS="$BASE/topology_cells"
DOOR="$BASE/doorgraph.lua"
DOOR_CELLS="$BASE/doorgraph_cells"
DB="/mnt/UDISK/openmw51-nav/navmesh.db"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUTDIR="$HOME/Downloads/openmw51-object-visibility-recon-$STAMP"
MASTER="$OUTDIR/OPENMW51-OBJECT-VISIBILITY-RECON.txt"
ARCHIVE="$HOME/Downloads/openmw51-object-visibility-recon-$STAMP.tar.gz"

mkdir -p "$OUTDIR/source" "$OUTDIR/device" "$OUTDIR/diffs"

exec > >(tee "$MASTER") 2>&1

section() {
    echo
    echo "######################################################################"
    echo "# $*"
    echo "######################################################################"
}

safe_docker_file() {
    local rel="$1"
    if docker exec "$CTR" test -f "$SRC/$rel"; then
        mkdir -p "$OUTDIR/source/$(dirname "$rel")"
        docker cp "$CTR:$SRC/$rel" "$OUTDIR/source/$rel" >/dev/null
        echo "COPIED source/$rel"
    else
        echo "MISSING source/$rel"
    fi
}

dump_docker_file() {
    local rel="$1"
    section "FULL CURRENT SOURCE: $rel"
    docker exec "$CTR" bash -lc "
        if [ -f '$SRC/$rel' ]; then
            nl -ba '$SRC/$rel'
        else
            echo 'MISSING: $SRC/$rel'
        fi
    "
}

section "OPENMW 0.51 OBJECT / VISGRID / ACTIVATION RECON"
echo "Collected: $(date)"
echo "Host:      $(hostname)"
echo "Container: $CTR"
echo "Device:    $DEV"
echo "Output:    $MASTER"
echo
echo "READ-ONLY: no source/device mutation and no build."

section "1. VERIFY / START DOCKER"
command -v docker >/dev/null
if ! docker inspect "$CTR" >/dev/null 2>&1; then
    echo "ERROR: Docker container '$CTR' does not exist."
    exit 20
fi
if [ "$(docker inspect -f '{{.State.Running}}' "$CTR")" != "true" ]; then
    docker start "$CTR" >/dev/null
fi
docker exec "$CTR" test -d "$SRC"
echo "PASS: Docker source tree available."

section "2. CURRENT SOURCE / BUILD IDENTITY"
docker exec "$CTR" bash -lc "
    set +e
    cd '$SRC'
    echo '--- git HEAD / branch ---'
    git rev-parse HEAD
    git branch --show-current
    git status --short
    echo
    echo '--- recent commits touching object/VISGRID paths ---'
    git log --all --date=iso --pretty=format:'%H | %ad | %d | %s' -n 80 -- \
      apps/openmw/mwrender/animation.cpp \
      apps/openmw/mwrender/interiorvisibility.cpp \
      apps/openmw/mwrender/objects.cpp \
      apps/openmw/mwrender/objectpaging.cpp \
      apps/openmw/mwrender/renderingmanager.cpp \
      apps/openmw/mwworld/scene.cpp \
      apps/openmw/mwworld/worldimp.cpp
    echo
    echo
    echo '--- build binaries ---'
    for f in '$BUILD/openmw' '$BUILD/apps/openmw/openmw' '/root/openmw-0.51-tsp-package/bin/openmw-0.51'; do
        [ -f \"\$f\" ] || continue
        file \"\$f\"
        sha256sum \"\$f\"
    done
"

SOURCE_FILES=(
    "apps/openmw/mwrender/interiorvisibility.hpp"
    "apps/openmw/mwrender/interiorvisibility.cpp"
    "apps/openmw/mwrender/animation.hpp"
    "apps/openmw/mwrender/animation.cpp"
    "apps/openmw/mwrender/objects.hpp"
    "apps/openmw/mwrender/objects.cpp"
    "apps/openmw/mwrender/objectpaging.hpp"
    "apps/openmw/mwrender/objectpaging.cpp"
    "apps/openmw/mwrender/renderingmanager.hpp"
    "apps/openmw/mwrender/renderingmanager.cpp"
    "apps/openmw/mwworld/scene.hpp"
    "apps/openmw/mwworld/scene.cpp"
    "apps/openmw/mwworld/worldimp.hpp"
    "apps/openmw/mwworld/worldimp.cpp"
    "apps/openmw/mwlua/camerabindings.cpp"
    "apps/openmw/CMakeLists.txt"
)

section "3. COPY EXACT CURRENT SOURCE FILES"
for rel in "${SOURCE_FILES[@]}"; do
    safe_docker_file "$rel"
done

section "4. HASH EXACT CURRENT SOURCE"
docker exec "$CTR" bash -lc "
    cd '$SRC'
    sha256sum \
      apps/openmw/mwrender/interiorvisibility.hpp \
      apps/openmw/mwrender/interiorvisibility.cpp \
      apps/openmw/mwrender/animation.hpp \
      apps/openmw/mwrender/animation.cpp \
      apps/openmw/mwrender/objects.hpp \
      apps/openmw/mwrender/objects.cpp \
      apps/openmw/mwrender/objectpaging.hpp \
      apps/openmw/mwrender/objectpaging.cpp \
      apps/openmw/mwrender/renderingmanager.hpp \
      apps/openmw/mwrender/renderingmanager.cpp \
      apps/openmw/mwworld/scene.hpp \
      apps/openmw/mwworld/scene.cpp \
      apps/openmw/mwworld/worldimp.hpp \
      apps/openmw/mwworld/worldimp.cpp \
      apps/openmw/mwlua/camerabindings.cpp \
      apps/openmw/CMakeLists.txt \
      2>/dev/null || true
"

section "5. ALL TSP / VISGRID / PAGING MARKERS IN RELEVANT CURRENT SOURCE"
docker exec "$CTR" bash -lc "
    cd '$SRC'
    grep -RInE \
      'TSP_INTERIOR_VISGRID|TSP_VISGRID|TSP_INTMERGE|TSP_INTOCC|TSP_SCENE|TSP_.*PAGING|TSP_.*CULL|TSP_.*NAV' \
      apps/openmw/mwrender/animation.cpp \
      apps/openmw/mwrender/interiorvisibility.cpp \
      apps/openmw/mwrender/interiorvisibility.hpp \
      apps/openmw/mwrender/objects.cpp \
      apps/openmw/mwrender/objectpaging.cpp \
      apps/openmw/mwrender/renderingmanager.cpp \
      apps/openmw/mwworld/scene.cpp \
      apps/openmw/mwworld/worldimp.cpp \
      apps/openmw/mwlua/camerabindings.cpp \
      2>/dev/null || true
"

section "6. VISGRID CALLBACK ATTACHMENT / PVS TYPE CLASSIFICATION"
docker exec "$CTR" bash -lc "
    cd '$SRC'
    grep -nE -B70 -A150 \
      'InteriorVisibilityCullCallback|tspIsStatic|tspPvsEligible|tspPvsRadius|isActor\\(\\)|isDoor\\(\\)|ESM::Static' \
      apps/openmw/mwrender/animation.cpp 2>/dev/null || true
    echo
    echo '--- callback implementation ---'
    grep -nE -B80 -A220 \
      'InteriorVisibilityCullCallback|nearestSurface|pvsEligible|Pvs|Topology|sector|shouldCull' \
      apps/openmw/mwrender/interiorvisibility.cpp \
      apps/openmw/mwrender/interiorvisibility.hpp 2>/dev/null || true
"

section "7. OBJECT INSERTION: NORMAL NODE VS PAGED PLACEHOLDER"
docker exec "$CTR" bash -lc "
    cd '$SRC'
    grep -nE -B80 -A180 \
      'void addObject\\(|insertObjectRendering|pagedNode|mPagedRefs|isPagedRef|removeFromPagedRefs|insertCell\\(' \
      apps/openmw/mwworld/scene.cpp 2>/dev/null || true
    echo
    echo '--- renderer-side object insertion / PtrHolder / masks ---'
    grep -nE -B70 -A180 \
      'Objects::|PtrHolder|setBaseNode|setNodeMask\\(Mask_Object|Mask_Static|ObjectAnimation|insertMesh|insertModel' \
      apps/openmw/mwrender/objects.cpp \
      apps/openmw/mwrender/objects.hpp 2>/dev/null || true
"

section "8. OBJECT PAGING TYPE ELIGIBILITY / CONTAINERS / CLUTTER"
docker exec "$CTR" bash -lc "
    cd '$SRC'
    grep -nE -B80 -A180 \
      'REC_STAT|REC_CONT|REC_BOOK|REC_WEAP|REC_MISC|REC_INGR|REC_ALCH|REC_APPA|REC_CLOT|REC_ARMO|REC_ACTI|REC_DOOR|getModel\\(|getPagedRefnums|RefnumMarker|AddRefnumMarker|mRefTracker|mActiveGrid|mMinSize|mMergeFactor|mergeBenefit|mergeCost' \
      apps/openmw/mwrender/objectpaging.cpp \
      apps/openmw/mwrender/objectpaging.hpp 2>/dev/null || true
"

section "9. EXTERIOR mPagedRefs POPULATION VS INTERIOR CLEAR"
docker exec "$CTR" bash -lc "
    cd '$SRC'
    grep -nE -B90 -A180 \
      'mPagedRefs\\.clear|getPagedRefnums|changeCellGrid|changeToInteriorCell|Changing to interior|loadCell\\(|insertCell\\(' \
      apps/openmw/mwworld/scene.cpp 2>/dev/null || true
"

section "10. ACTIVATION / PICKING / INTERSECTION PATH"
docker exec "$CTR" bash -lc "
    cd '$SRC'
    echo '--- RenderingManager intersection machinery ---'
    grep -nE -B100 -A240 \
      'getIntersectionResult|getIntersectionVisitor|RenderingManager::castRay|castCameraToViewportRay|PtrHolder|RefnumMarker|setTraversalMask' \
      apps/openmw/mwrender/renderingmanager.cpp 2>/dev/null || true

    echo
    echo '--- gameplay activation / focus callers across OpenMW ---'
    grep -RInE -B25 -A70 \
      'getFocusObject|getFacedObject|getMaxActivationDistance|castCameraToViewportRay|mRendering->castRay|activate.*Object|activate\\(' \
      apps/openmw \
      2>/dev/null | head -7000 || true
"

section "11. NAVIGATOR OBJECT REGISTRATION VS RENDER REGISTRATION"
docker exec "$CTR" bash -lc "
    cd '$SRC'
    grep -nE -B80 -A180 \
      'Navigator|navigator|addObject\\(|addAgent|removeObject|updateNavigatorObject|ObjectShapes|DoorShapes|isInterior' \
      apps/openmw/mwworld/scene.cpp 2>/dev/null || true
"

section "12. PRE-VISGRID V1 SOURCE BACKUP DIFF"
docker exec "$CTR" bash -lc "
    set +e
    BK=\$(cat /root/openmw51-visgrid-v1-source-backup-path.txt 2>/dev/null)
    echo \"Recorded pre-VISGRID backup: \${BK:-NONE}\"
    if [ -n \"\$BK\" ] && [ -d \"\$BK\" ]; then
        echo
        echo '--- backup contents ---'
        find \"\$BK\" -type f -maxdepth 7 -print | sort
        echo
        for rel in \
          apps/openmw/CMakeLists.txt \
          apps/openmw/mwrender/animation.cpp \
          apps/openmw/mwlua/camerabindings.cpp \
          apps/openmw/mwrender/renderingmanager.cpp
        do
            echo
            echo \"================ DIFF PRE-V1 -> CURRENT: \$rel ================\"
            if [ -f \"\$BK/\$rel\" ] && [ -f '$SRC/'\"\$rel\" ]; then
                diff -u \"\$BK/\$rel\" '$SRC/'\"\$rel\" || true
            else
                echo 'missing one side'
            fi
        done
    else
        echo 'No recorded V1 source backup directory found.'
    fi
"

section "13. HISTORICAL animation.cpp BACKUPS / VISGRID EVOLUTION"
docker exec "$CTR" bash -lc "
    set +e
    find '$SRC/.tsp-051-source-backups' \
      -type f -path '*/apps/openmw/mwrender/animation.cpp' 2>/dev/null |
      sort |
      tail -120 |
      while read -r f; do
          printf '\\n--- %s ---\\n' \"\$f\"
          sha256sum \"\$f\"
          grep -nE \
            'TSP_INTERIOR_VISGRID_051_V1|TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS|TSP_INTERIOR_VISGRID_051_V6_DOOR_BYPASS|InteriorVisibilityCullCallback|tspIsStatic|tspPvsEligible|isDoor\\(\\)' \
            \"\$f\" 2>/dev/null | head -80 || true
      done
"

section "14. CURRENT DEVICE IDENTITY"
if ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" 'true'; then
    echo "SSH PASS"
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" "
        set +e
        date
        hostname
        echo
        echo '--- process state ---'
        pidof openmw-0.51 || pidof openmw || echo 'OpenMW not running'
        echo
        echo '--- hashes ---'
        sha256sum '$GAME' '$LIVE_LUA' '$TOPO' '$DOOR' 2>/dev/null || true
        echo
        printf 'topology_shards='
        find '$TOPO_CELLS' -maxdepth 1 -type f -name '*.lua' 2>/dev/null | wc -l
        printf 'doorgraph_shards='
        find '$DOOR_CELLS' -maxdepth 1 -type f -name '*.lua' 2>/dev/null | wc -l
        echo
        echo '--- navmesh db ---'
        stat -c '%s %Y %n' '$DB' 2>/dev/null || true
        echo
        echo '--- binary VISGRID/TSP markers ---'
        grep -aEo \
          'TSP_INTERIOR_VISGRID_051_V[0-9A-Z_\\.]+|TSP_SCENE_[A-Za-z0-9_\\.-]+|TSP_INTMERGE_[A-Za-z0-9_\\.-]+|TSP_INTOCC_[A-Za-z0-9_\\.-]+' \
          '$GAME' 2>/dev/null | sort -u | head -300 || true
    "
else
    echo "WARNING: device unavailable. Docker/source recon still completed."
fi

section "15. COPY CURRENT DEVICE VISGRID / TOPOLOGY / DOORGRAPH / LAUNCHER"
if ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" 'true'; then
    LAUNCHER="$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" '
        for p in \
          /mnt/sdcard/mmcblk1p1/Roms/PORTS/Morrowind_51.sh \
          /mnt/SDCARD/Roms/PORTS/Morrowind_51.sh \
          /mnt/SDCARD/Emus/PORTS/../../Roms/PORTS/Morrowind_51.sh
        do
            if [ -f "$p" ]; then
                readlink -f "$p" 2>/dev/null || printf "%s\n" "$p"
                exit 0
            fi
        done
        exit 1
    ' || true)"

    echo "Resolved launcher: ${LAUNCHER:-NOT FOUND}"

    scp -q "$DEV:$LIVE_LUA" "$OUTDIR/device/visgrid.lua" 2>/dev/null || true
    scp -q "$DEV:$TOPO" "$OUTDIR/device/topology.lua" 2>/dev/null || true
    scp -q "$DEV:$DOOR" "$OUTDIR/device/doorgraph.lua" 2>/dev/null || true
    if [ -n "${LAUNCHER:-}" ]; then
        scp -q "$DEV:$LAUNCHER" "$OUTDIR/device/Morrowind_51.sh" 2>/dev/null || true
    fi

    for remote in \
      "$ROOT/config-0.51/settings.cfg" \
      "$ROOT/config-0.51/openmw.cfg" \
      "$ROOT/settings.cfg" \
      "$ROOT/openmw.cfg"
    do
        base="$(echo "$remote" | sed 's#^/##; s#/#__#g')"
        scp -q "$DEV:$remote" "$OUTDIR/device/$base" 2>/dev/null || true
    done

    for f in "$OUTDIR/device/visgrid.lua" "$OUTDIR/device/Morrowind_51.sh"; do
        [ -f "$f" ] || continue
        section "FULL DEVICE FILE: $(basename "$f")"
        nl -ba "$f"
    done

    if [ -f "$OUTDIR/device/topology.lua" ]; then
        section "DEVICE GLOBAL TOPOLOGY LOADER / HEADER"
        nl -ba "$OUTDIR/device/topology.lua" | head -700
    fi

    if [ -f "$OUTDIR/device/doorgraph.lua" ]; then
        section "DEVICE REAL-DOOR GRAPH LOADER / HEADER"
        nl -ba "$OUTDIR/device/doorgraph.lua" | head -500
    fi
fi

section "16. CURRENT DEVICE SETTINGS: PAGING / CULLING / DISTANCE"
if ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" 'true'; then
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" "
        set +e
        for f in \
          '$ROOT/config-0.51/settings.cfg' \
          '$ROOT/config-0.51/openmw.cfg' \
          '$ROOT/settings.cfg' \
          '$ROOT/openmw.cfg'
        do
            [ -f \"\$f\" ] || continue
            echo
            echo \"--- \$f ---\"
            grep -niE \
              'object paging|active grid|merge factor|min size|small feature culling|viewing distance|preload|distant|occlusion|navigator|navmesh|actors processing range' \
              \"\$f\" 2>/dev/null || true
        done
    "
fi

section "17. CURRENT VISGRID LUA: TOPOLOGY / RAY / EXTERIOR DISARM"
if [ -f "$OUTDIR/device/visgrid.lua" ]; then
    grep -nE -B50 -A120 \
      'setInteriorVisibilityGrid|clearInteriorVisibilityGrid|setInteriorTopologyPvs|clearInteriorTopologyPvs|cell.isExterior|exitInterior|publishGrid|chooseAndCast|v23RayMode|v23TopologyMode|TSP_VISGRID_V23PERF' \
      "$OUTDIR/device/visgrid.lua" 2>/dev/null || true
fi

section "18. RECENT DEVICE VISGRID / OBJECT / PAGING / ACTIVATION LOG EVIDENCE"
if ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" 'true'; then
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" "
        set +e
        for f in \
          '$ROOT/openmw_051_log.txt' \
          '$ROOT/config-0.51/openmw.log' \
          '$ROOT/config-0.51/openmw.log.old'
        do
            [ -s \"\$f\" ] || continue
            echo
            echo \"--- \$f ---\"
            tail -n 50000 \"\$f\" |
              grep -E \
                'TSP_VISGRID|TSP_INTERIOR_VISGRID|TSP_SCENE|TSP_INTMERGE|TSP_INTOCC|paged|paging|failed to render|Tried to add|activation|activate|Lua.*ERROR|Lua.*error' \
              | tail -10000 || true
        done
    "
fi

section "19. FULL CURRENT SOURCE FILES"
echo "The following are exact copies from the live Docker source tree."
for rel in "${SOURCE_FILES[@]}"; do
    dump_docker_file "$rel"
done

section "20. RECON MANIFEST"
(
    cd "$OUTDIR"
    find . -type f -print0 | sort -z | xargs -0 sha256sum
) | tee "$OUTDIR/SHA256SUMS.txt"

section "21. PACKAGE"
tar -C "$OUTDIR" -czf "$ARCHIVE" .
sha256sum "$MASTER" "$ARCHIVE"

echo
echo "======================================================================"
echo "RECON COMPLETE"
echo "======================================================================"
echo
echo "Upload this ONE text file to ChatGPT first:"
echo "  $MASTER"
echo
echo "Full exact-source/device bundle:"
echo "  $ARCHIVE"
echo
echo "No files on the TSP or in Docker were modified."
echo "======================================================================"
