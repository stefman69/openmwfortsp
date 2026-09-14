#!/usr/bin/env bash
set -u
cd "$HOME/Downloads" || return 1 2>/dev/null || true
DEV="${TSP_DEV:-root@192.168.1.25}"
ROOT="/mnt/SDCARD/data/ports/openmw51"
LUA="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/visgrid-v22-1f-revisit-trail-$STAMP.txt"
{
    echo "===== INSTALLED SENSOR ====="
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" "sha256sum '$LUA'; grep -n 'TSP_VISGRID_LUA_V22_1[DEF]' '$LUA' | head -20" 2>&1 || true
    echo
    echo "===== V22.1F REVISIT / RAY-PVS / GRID TRACE ====="
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" '
        ROOT="/mnt/SDCARD/data/ports/openmw51"
        for LOG in "$ROOT/openmw_051_log.txt" "$ROOT/config-0.51/openmw.log"; do
            [ -s "$LOG" ] || continue
            echo "--- $LOG ---"
            tail -n 20000 "$LOG" | grep -E "TSP_VISGRID_V22\.1F|TSP_VISGRID_V22\.1E|REVISIT-TRAIL|RAY-PVS|ENTRY-NEAR PRELOAD|DOOR-SOURCE HALO|context switch|PVS floor=|v221f=1|v221e=1|Changing to interior|Loading cell |Unloading cell |sensor DISABLED| ERROR #" || true
        done
    ' 2>&1 || true
} | tee "$OUT"
echo
echo "Saved: $OUT"
