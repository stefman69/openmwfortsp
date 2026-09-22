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
OUT="$HOME/Downloads/visgrid-v22-1-upward-$STAMP.txt"
{
    echo "===== V22.1 INSTALL ====="
    ssh "${SSH[@]}" "$DEV" "sha256sum '$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua'; grep -n 'TSP_VISGRID_LUA_V22_1_UPWARD_ANTICIPATION' '$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua' | head -1"
    echo
    echo "===== V22.1 / RESIDENT / UPWARD SESSION ====="
    ssh "${SSH[@]}" "$DEV" "for f in '$ROOT/openmw_051_log.txt' '$ROOT/config-0.51/openmw.log'; do [ -s "\$f" ] || continue; echo; echo --- "\$f" ---; grep -hE 'TSP_VISGRID_V22\.1|TSP_VISGRID_V22|TSP_VISGRID_V21|TSP_VISGRID_V20|TSP_VISGRID_V15|TSP_VISGRID_V11|Lua.*ERROR|Lua.*error' "\$f" | tail -5000 || true; done"
} 2>&1 | tee "$OUT"
echo
echo "Saved: $OUT"
