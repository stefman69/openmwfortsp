#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="/mnt/SDCARD/data/ports/openmw51"
TOOLS_OLD="$HOME/Downloads/visgrid-tools"

# Reuse an old device.env if it exists, but this helper itself lives directly
# in ~/Downloads and writes its output directly there.
if [ -f "$TOOLS_OLD/device.env" ]; then
    # shellcheck disable=SC1090
    . "$TOOLS_OLD/device.env" || true
fi

if [ -n "${TSP_DEV:-}" ]; then
    DEV="$TSP_DEV"
elif [ -n "${TSP_IP:-}" ]; then
    DEV="root@$TSP_IP"
else
    DEV="root@192.168.1.25"
fi

SSH=(-o BatchMode=yes -o ConnectTimeout=8)
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/visgrid-v17-pvs-trace-$STAMP.txt"

{
    echo "=================================================================="
    echo "VISGRID V17 NAVMESH-PVS TRACE"
    echo "=================================================================="
    echo "Ubuntu date: $(date)"
    echo "Device: $DEV"
    echo

    ssh "${SSH[@]}" "$DEV" 'date; hostname'

    echo
    echo "===== V17 / VISGRID / LOAD / PVS ====="
    ssh "${SSH[@]}" "$DEV" "
      grep -hE \
        'TSP_VISGRID_V17|TSP_VISGRID_V11|TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS|TSP_INTERIOR_VISGRID|TSP_LOAD_FREEZE|Lua.*ERROR|Lua.*error' \
        '$ROOT/openmw_051_log.txt' '$ROOT/config-0.51/openmw.log' \
        2>/dev/null | tail -4200 || true
    "

    echo
    echo "===== PERF ====="
    ssh "${SSH[@]}" "$DEV" "
      [ -f '$ROOT/openmw51_perf_latest.txt' ] &&
        tail -900 '$ROOT/openmw51_perf_latest.txt' || true
    "

    echo
    echo "===== INSTALLED HASHES ====="
    ssh "${SSH[@]}" "$DEV" "
      sha256sum \
        '$ROOT/bin/openmw-0.51' \
        '$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua' \
        '$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/topology.lua' \
        2>/dev/null || true
    "

    echo
    echo "===== BINARY MARKERS ====="
    ssh "${SSH[@]}" "$DEV" "
      for m in \
        TSP_INTERIOR_VISGRID_051_V1 \
        TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG \
        TSP_INTERIOR_VISGRID_051_V4_CULLFOG \
        TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS
      do
        if grep -a -q \"\$m\" '$ROOT/bin/openmw-0.51'; then
          echo \"YES \$m\"
        else
          echo \"no  \$m\"
        fi
      done
    "
} 2>&1 | tee "$OUT"

echo
echo "Saved directly in Downloads:"
echo "  $OUT"

