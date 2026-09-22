#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/Downloads"
if [ -f "$HOME/Downloads/visgrid-tools/device.env" ]; then
    . "$HOME/Downloads/visgrid-tools/device.env" || true
fi
if [ -n "${TSP_DEV:-}" ]; then DEV="$TSP_DEV"
elif [ -n "${TSP_IP:-}" ]; then DEV="root@$TSP_IP"
else DEV="root@192.168.1.25"; fi
ROOT="/mnt/SDCARD/data/ports/openmw51"
LUA="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/visgrid-v22-2-intercell-$STAMP.txt"
{
    echo "===== V22.2 INSTALL ====="
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" "sha256sum '$LUA'; grep -nF 'TSP_VISGRID_LUA_V22_2_INTERCELL_HANDOFF' '$LUA' | head -1"
    echo
    echo "===== INTERIOR TRANSITION SESSION ====="
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" '
ROOT="/mnt/SDCARD/data/ports/openmw51"
for LOG in "$ROOT/openmw_051_log.txt" "$ROOT/config-0.51/openmw.log"; do
    [ -s "$LOG" ] || continue
    echo
    echo "--- $LOG ---"
    tail -n 14000 "$LOG" | grep -Ei \
"Changing to interior|Loading cell|Unloading cell|TSP_LOAD_FREEZE|load-safe|TSP_VISGRID_V22\\.2|TSP_VISGRID_V22\\.1|TSP_VISGRID_V22|TSP_VISGRID_V21|TSP_VISGRID_V20|TSP_VISGRID_V15|reset reason=cell-change|enter interior|doors cell=|PVS floor=|v222=1|Lua.*ERROR|Lua.*error|exception|failed" || true
done
'
} | tee "$OUT"
echo
echo "Saved: $OUT"
