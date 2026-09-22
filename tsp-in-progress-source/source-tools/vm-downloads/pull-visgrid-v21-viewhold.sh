#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/Downloads"

DEV="${TSP_DEV:-root@192.168.1.25}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/visgrid-v21-viewhold-$STAMP.txt"

ssh "$DEV" '
ROOT="/mnt/SDCARD/data/ports/openmw51"
BASE="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid"

echo "===== V21 INSTALL ====="
sha256sum "$BASE/visgrid.lua" 2>/dev/null || true
grep -n "TSP_VISGRID_LUA_V21_DOORGRAPH_VIEWHOLD" "$BASE/visgrid.lua" 2>/dev/null || true
echo
cat "$BASE/REAL-DOOR-GRAPH-SUMMARY.txt" 2>/dev/null || true

echo
echo "===== V21 / PVS / RAY-HOLD SESSION ====="
for LOG in \
    "$ROOT/openmw_051_log.txt" \
    "$ROOT/log-0.51.txt" \
    "$ROOT/config-0.51/openmw.log" \
    "$ROOT/config-0.51/openmw.log.old"
do
    [ -s "$LOG" ] || continue
    echo
    echo "--- $LOG ---"
    tail -n 7000 "$LOG" |
    grep -E "TSP_VISGRID_V21|TSP_VISGRID_V20|TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS|v21=1|topology sector=|context switch|PVS floor=|first_.*error| ERROR #|sensor DISABLED" \
    || true
done
' | tee "$OUT"

echo
echo "Saved:"
echo "  $OUT"
