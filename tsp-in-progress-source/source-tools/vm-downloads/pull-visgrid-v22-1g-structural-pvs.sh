#!/usr/bin/env bash
set -u
cd "$HOME/Downloads" || return 1 2>/dev/null || true
DEV="${TSP_DEV:-root@192.168.1.25}"
ROOT="/mnt/SDCARD/data/ports/openmw51"
LUA="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/visgrid-v22-1g-structural-pvs-$STAMP.txt"
{
    echo "===== INSTALLED SENSOR ====="
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" "sha256sum '$LUA'; grep -n 'TSP_VISGRID_LUA_V22_1[DEFG]' '$LUA' | head -24" 2>&1 || true
    echo
    echo "===== V22.1G STRUCTURAL-PVS / RAY / GRID TRACE ====="
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" '
        ROOT="/mnt/SDCARD/data/ports/openmw51"
        for LOG in "$ROOT/openmw_051_log.txt" "$ROOT/config-0.51/openmw.log"; do
            [ -s "$LOG" ] || continue
            echo "--- $LOG ---"
            tail -n 24000 "$LOG" | grep -E "TSP_VISGRID_V22\\.1G|STRUCT-SHELL|TSP_VISGRID_V22\\.1F|RAY-PVS|REVISIT-TRAIL|TSP_VISGRID_V22\\.1E|ENTRY-NEAR PRELOAD|DOOR-SOURCE HALO|context switch|PVS floor=|v221g=1|v221f=1|v221e=1|Changing to interior|Loading cell |Unloading cell |sensor DISABLED| ERROR #" || true
        done
    ' 2>&1 || true
} | tee "$OUT"
echo
echo "Saved: $OUT"
