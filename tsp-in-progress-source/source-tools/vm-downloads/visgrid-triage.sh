#!/usr/bin/env bash
# visgrid-triage.sh
#
# Two jobs, one command. No rebuild.
#
# 1. RECON: dump the CUSTOM Lua bindings and the VISGRID/fog C++ out of the
#    builder container. Seven crashes now, every one at libluajit+0x94f0, and
#    the "errors" the sensor caught were bare numbers (2, 2, 93.741790771484)
#    rather than strings - that is Lua stack garbage, not a script error. The
#    only non-upstream Lua bindings in this build are ours
#    (setInteriorVisibilityGrid / getInteriorVisibilityStats /
#    getInteriorVisibilityFogGuide), so that is where to look.
#
# 2. CONFIG: set the device to the configuration that actually survived.
#      run A (16:50, interiormap covering 7 cells, no entry for Caldera,
#             cap=6200): armed 21s, reject peaked 82.8%, then containment
#             caught 3 bogus errors and disabled the sensor - AND THE GAME
#             KEPT RUNNING for another ~35s. The exit-139 was a separate
#             gl4es teardown crash (backtrace: __libc_start_main -> ld-linux
#             -> libGL destructor), not the Lua one.
#      run B (17:07, interiormap covering 1323 cells, cap=4517 for Caldera):
#             dead inside one second of arming. Zero status lines.
#    So the map made it fatal, and it was not buying the rejection anyway -
#    82.8% was reached with cap=6200. This moves interiormap.lua aside.
#
# Usage:
#   bash visgrid-triage.sh            # recon + disable the interior map
#   bash visgrid-triage.sh --map-on   # recon + put the interior map back
#   bash visgrid-triage.sh --recon    # recon only, change nothing
set -Eeuo pipefail

MODE="${1:---map-off}"

if [ -f "$HOME/Downloads/visgrid-tools/device.env" ]; then
    # shellcheck disable=SC1091
    . "$HOME/Downloads/visgrid-tools/device.env" || true
fi
if [ -n "${TSP_IP:-}" ]; then DEV="root@$TSP_IP"; else DEV="${TSP_DEV:-root@192.168.1.25}"; fi
C="${TSP_BUILDER:-openmw_builder}"
SRC="/root/openmw-0.51-tsp-src"
ROOT="/mnt/SDCARD/data/ports/openmw51"
MOD="$ROOT/mods/TSPInteriorVisGrid"
MAPLUA="$MOD/scripts/TSPInteriorVisGrid/interiormap.lua"
D="$HOME/tsp_visgrid_bindings_dump.txt"
: > "$D"

echo "=================================================================="
echo "PART 1  RECON - THE CUSTOM LUA BINDINGS AND THE FOG C++"
echo "=================================================================="
command -v docker >/dev/null
if [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" != "true" ]; then
    docker start "$C" >/dev/null
fi

{
echo "########## TSP VISGRID BINDING RECON - $(date) ##########"
docker exec -i "$C" bash -s <<'DOCK'
SRC=/root/openmw-0.51-tsp-src
full() {
  if [ ! -f "$1" ]; then echo "!! MISSING FILE: $1"; return 0; fi
  echo "########## FULL: $1 ($(wc -l < "$1") lines) ##########"
  cat -n "$1"
}
w() {
  F="$1"; P="$2"; A=${3:-4}; Z=${4:-45}; M=${5:-8}
  if [ ! -f "$F" ]; then echo "!! MISSING FILE: $F"; return 0; fi
  echo "----- windows: $F  pattern=[$P] -----"
  grep -nE "$P" "$F" | head -$M
  for L in $(grep -nE "$P" "$F" | head -$M | cut -d: -f1); do
    S=$((L-A)); if [ $S -lt 1 ]; then S=1; fi
    echo "--- $F lines $S..$((L+Z)) ---"
    sed -n "${S},$((L+Z))p" "$F" | nl -ba -v$S -w6 -s"| "
  done
}

echo "########## SECTION 0: where the bindings live ##########"
grep -rn "setInteriorVisibilityGrid\|getInteriorVisibilityStats\|clearInteriorVisibilityGrid\|resetInteriorVisibilityStats\|getInteriorVisibilityFogGuide" \
    $SRC/apps/openmw --include=*.cpp --include=*.hpp | grep -v '\.tsp' | head -40
echo
echo "-- luajit build flags visible in the tree --"
grep -rn "LUAJIT_ENABLE_GC64\|LJ_GC64\|luajit" $SRC/CMakeLists.txt $SRC/cmake/*.cmake 2>/dev/null | head -10

echo "########## SECTION 1: interiorvisibility.hpp (FULL) ##########"
full $SRC/apps/openmw/mwrender/interiorvisibility.hpp

echo "########## SECTION 2: interiorvisibility.cpp (FULL) ##########"
full $SRC/apps/openmw/mwrender/interiorvisibility.cpp

echo "########## SECTION 3: the Lua binding bodies in mwlua ##########"
for f in $(grep -rl "InteriorVisibility" $SRC/apps/openmw/mwlua --include=*.cpp 2>/dev/null | grep -v '\.tsp' | head -4); do
  echo "===== $f ====="
  w "$f" "InteriorVisibility" 8 40 8
done

echo "########## SECTION 4: renderingmanager.cpp - grid API + fog block ##########"
w $SRC/apps/openmw/mwrender/renderingmanager.cpp "setInteriorVisibilityGrid|getInteriorVisibilityFogGuide|isInteriorVisibilityGridEnabled" 4 35 6
w $SRC/apps/openmw/mwrender/renderingmanager.cpp "TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG" 4 70 1

echo "########## SECTION 5: renderingmanager.hpp - declarations ##########"
grep -nE "InteriorVisibility|FogGuide" $SRC/apps/openmw/mwrender/renderingmanager.hpp | head -20

echo "########## SECTIONS EMITTED: 6 ##########"
DOCK
} 2>&1 | tee -a "$D"

if grep -q "SECTIONS EMITTED: 6" "$D"; then
    echo
    echo "RECON OK ($(wc -l < "$D") lines) -> $D"
else
    echo
    echo "RECON FAILED - paste the output above."
fi

echo
echo "=================================================================="
echo "PART 2  DEVICE CONFIGURATION"
echo "=================================================================="
if [ "$MODE" = "--recon" ]; then
    echo "  --recon given; device left exactly as it is."
    echo
    echo "Send me: $D"
    exit 0
fi

if ssh "$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
    echo "ERROR: OpenMW is running. Exit it, then rerun."
    exit 20
fi

if [ "$MODE" = "--map-on" ]; then
    ssh "$DEV" "
set -e
if [ -s '$MAPLUA.disabled' ]; then
    mv -f '$MAPLUA.disabled' '$MAPLUA'
    sync
    echo 'interior map RE-ENABLED'
else
    if [ -s '$MAPLUA' ]; then echo 'interior map already enabled'; else echo 'no interiormap.lua to enable'; fi
fi
"
else
    ssh "$DEV" "
set -e
if [ -s '$MAPLUA' ]; then
    mv -f '$MAPLUA' '$MAPLUA.disabled'
    sync
    echo 'interior map DISABLED (kept at interiormap.lua.disabled)'
else
    echo 'no interiormap.lua present - nothing to disable'
fi
"
fi

echo
ssh "$DEV" "
echo -n 'active sensor   : '
grep -Fq 'TSP_VISGRID_V11_LOADSAFE_12S' '$MOD/scripts/TSPInteriorVisGrid/visgrid.lua' && echo 'V11a (hold present)' || echo 'NOT V11a'
echo -n 'interior map    : '
[ -s '$MAPLUA' ] && echo 'ENABLED' || echo 'disabled'
echo -n 'scan cells file : '
[ -s '$ROOT/tsp_interior_scan_cells.txt' ] && wc -l < '$ROOT/tsp_interior_scan_cells.txt' || echo 'absent'
"

echo
echo "=================================================================="
echo "WHAT TO EXPECT ON THE NEXT LAUNCH"
echo "=================================================================="
echo "  [TSP_VISGRID_V11] no interior map installed - raycast-only mode"
echo "  ... 12s hold ..."
echo "  [TSP_VISGRID_V11] load-safe hold complete -> VISGRID may arm"
echo "  [TSP_VISGRID_V11] enter interior \"...\" -> wall-model grid active"
echo "  then one status line per second with reject=..."
echo
echo "This is the configuration that reached reject=82.8% and, when it did"
echo "trip, was CAUGHT: the sensor disabled itself and the game kept running."
echo "It is not a fix for the underlying LuaJIT fault - that needs the"
echo "binding source in $D."
echo
echo "Measure, then pull:"
echo "  ~/Downloads/pull-visgrid-perf.sh"
echo
echo "Put the map back at any time:"
echo "  bash ~/Downloads/visgrid-triage.sh --map-on"
echo "=================================================================="
