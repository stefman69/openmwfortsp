#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/Downloads"
DEV="${TSP_DEV:-root@192.168.1.25}"
ROOT="/mnt/SDCARD/data/ports/openmw51"
BASE="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid"
STAMP="$(date +%Y%m%d-%H%M%S)"
CORE="$HOME/Downloads/visgrid-v22-1e-entry-doorframe-core-$STAMP.txt"
RAW="$HOME/Downloads/visgrid-v22-1e-entry-doorframe-raw-$STAMP.txt"

{
    echo "===== INSTALLED SENSOR / DATA ====="
    ssh "$DEV" "sha256sum '$BASE/visgrid.lua' 2>/dev/null || true; grep -nE 'TSP_VISGRID_LUA_V22_1(D|E)' '$BASE/visgrid.lua' 2>/dev/null || true; echo topology_shards=\$(find '$BASE/topology_cells' -maxdepth 1 -type f -name 'c_*.lua' 2>/dev/null | wc -l); echo doorgraph_shards=\$(find '$BASE/doorgraph_cells' -maxdepth 1 -type f -name 'c_*.lua' 2>/dev/null | wc -l)"
    echo
    echo "===== V22.1E ENTRY / DOOR-FRAME TRACE ====="
    ssh "$DEV" '
        ROOT=/mnt/SDCARD/data/ports/openmw51
        for LOG in \
            "$ROOT/openmw_051_log.txt" \
            "$ROOT/log-0.51.txt" \
            "$ROOT/config-0.51/openmw.log" \
            "$ROOT/config-0.51/openmw.log.old"
        do
            [ -s "$LOG" ] || continue
            echo
            echo "--- $LOG ---"
            tail -n 20000 "$LOG" |
            grep -E "TSP_VISGRID_V22\\.1E|TSP_VISGRID_V22\\.1D|GRID LEARN-GRACE|ENTRY-NEAR PRELOAD|DOOR-SOURCE HALO|INTERCELL BEGIN|PVS SHADOW|PVS RELEASE|PVS floor=|context switch|v221e=1|first_.*error| ERROR #|sensor DISABLED|Changing to interior|Loading cell |Unloading cell " || true
        done
    '
} | tee "$CORE"

ssh "$DEV" '
    ROOT=/mnt/SDCARD/data/ports/openmw51
    for LOG in \
        "$ROOT/openmw_051_log.txt" \
        "$ROOT/log-0.51.txt" \
        "$ROOT/config-0.51/openmw.log" \
        "$ROOT/config-0.51/openmw.log.old"
    do
        [ -s "$LOG" ] || continue
        echo
        echo "--- $LOG ---"
        tail -n 20000 "$LOG"
    done
' > "$RAW"

echo
echo "Saved core trace: $CORE"
echo "Saved raw 20k-line tails: $RAW"
