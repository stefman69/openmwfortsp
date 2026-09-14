#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="/mnt/SDCARD/data/ports/openmw51"
if [ -f "$HOME/Downloads/visgrid-tools/device.env" ]; then
    . "$HOME/Downloads/visgrid-tools/device.env" || true
fi
if [ -n "${TSP_DEV:-}" ]; then DEV="$TSP_DEV"
elif [ -n "${TSP_IP:-}" ]; then DEV="root@$TSP_IP"
else DEV="root@192.168.1.25"; fi
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/visgrid-v22-resident-$STAMP.txt"
BASE="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid"
{
    echo "===== V22 INSTALL ====="
    ssh "$DEV" "sha256sum '$BASE/visgrid.lua'; grep -n 'TSP_VISGRID_LUA_V22_RESIDENT_SECTORS' '$BASE/visgrid.lua' || true"
    echo
    echo "===== V22 RESIDENT / PVS SESSION ====="
    ssh "$DEV" "
      for f in '$ROOT/openmw_051_log.txt' '$ROOT/config-0.51/openmw.log'; do
        [ -s "\$f" ] || continue
        echo
        echo --- "\$f" ---
        grep -E 'TSP_VISGRID_V22|TSP_VISGRID_V21|TSP_VISGRID_V20|TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS|v22=1|topology sector=|context switch|PVS floor=| ERROR #|sensor DISABLED' "\$f" 2>/dev/null | tail -4200 || true
      done
    "
} 2>&1 | tee "$OUT"
echo
echo "Saved: $OUT"
