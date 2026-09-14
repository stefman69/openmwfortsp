#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="/mnt/SDCARD/data/ports/openmw51"
if [ -f "$HOME/Downloads/visgrid-tools/device.env" ]; then
  . "$HOME/Downloads/visgrid-tools/device.env" || true
fi
if [ -n "${TSP_DEV:-}" ]; then DEV="$TSP_DEV"
elif [ -n "${TSP_IP:-}" ]; then DEV="root@$TSP_IP"
else DEV="root@192.168.1.25"; fi
SSH=(-o BatchMode=yes -o ConnectTimeout=8)
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/visgrid-v19-pvs-trace-$STAMP.txt"
{
  echo "=================================================================="
  echo "VISGRID V19 RAY-AUTHORITY PVS TRACE"
  echo "=================================================================="
  echo "Ubuntu date: $(date)"
  ssh "${SSH[@]}" "$DEV" 'date; hostname'
  echo
  echo "===== V19 / PVS / VISGRID ====="
  ssh "${SSH[@]}" "$DEV" "
    grep -hE \
      'TSP_VISGRID_V19|TSP_VISGRID_V11|TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS|TSP_INTERIOR_VISGRID|TSP_LOAD_FREEZE|Lua.*ERROR|Lua.*error' \
      '$ROOT/openmw_051_log.txt' '$ROOT/config-0.51/openmw.log' \
      2>/dev/null | tail -5200 || true
  "
  echo
  echo "===== PERF ====="
  ssh "${SSH[@]}" "$DEV" "
    [ -f '$ROOT/openmw51_perf_latest.txt' ] &&
      tail -1000 '$ROOT/openmw51_perf_latest.txt' || true
  "
  echo
  echo "===== HASHES ====="
  ssh "${SSH[@]}" "$DEV" "
    sha256sum \
      '$ROOT/bin/openmw-0.51' \
      '$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua' \
      '$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/topology.lua' \
      2>/dev/null || true
  "
} 2>&1 | tee "$OUT"
echo "Saved directly in Downloads:"
echo "  $OUT"

