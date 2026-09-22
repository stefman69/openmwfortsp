#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/Downloads"
ROOT="/mnt/SDCARD/data/ports/openmw51"
if [ -f "$HOME/Downloads/visgrid-tools/device.env" ]; then
    . "$HOME/Downloads/visgrid-tools/device.env" || true
fi
if [ -n "${TSP_DEV:-}" ]; then DEV="$TSP_DEV"
elif [ -n "${TSP_IP:-}" ]; then DEV="root@$TSP_IP"
else DEV="root@192.168.1.25"; fi
SSH=(-o BatchMode=yes -o ConnectTimeout=8)
STAMP="$(date +%Y%m%d-%H%M%S)"
CORE="$HOME/Downloads/visgrid-v22-1d-intercell-core-$STAMP.txt"
RAW="$HOME/Downloads/visgrid-v22-1d-intercell-raw-$STAMP.txt"

{
    echo "===== INSTALLED SENSOR / DATA ====="
    ssh "${SSH[@]}" "$DEV" "
LUA='$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua'
sha256sum \"\$LUA\"
grep -nE 'TSP_VISGRID_LUA_V22_1_UPWARD_ANTICIPATION|TSP_VISGRID_LUA_V22_1D_INTERCELL_PVS_QUARANTINE' \"\$LUA\" | head -4
printf 'topology_shards='; find '$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/topology_cells' -type f -name '*.lua' | wc -l
printf 'doorgraph_shards='; find '$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/doorgraph_cells' -type f -name '*.lua' | wc -l
"
} > "$CORE"

ssh "${SSH[@]}" "$DEV" "
for f in '$ROOT/openmw_051_log.txt' '$ROOT/config-0.51/openmw.log'; do
    [ -s \"\$f\" ] || continue
    echo
    echo '================================================================'
    echo \"RAW LOG: \$f\"
    echo '================================================================'
    tail -n 20000 \"\$f\"
done
" > "$RAW"

{
    echo
    echo "===== CORE INTERCELL TRACE ====="
    grep -Ei \
'TSP_VISGRID_V22\.1D|TSP_VISGRID_V22\.1|TSP_VISGRID_V22|TSP_VISGRID_V21|TSP_VISGRID_V20|TSP_VISGRID_V15|TSP_VISGRID_V11|Changing to interior|Loading cell|Unloading cell|TSP_LOAD_FREEZE|sensor DISABLED|first_.*error|Lua.*error|exception|segfault' \
        "$RAW" || true

    echo
    echo "===== NON-STAT RENDER ERROR SUMMARY ====="
    grep -F 'Bad LiveCellRef cast to STAT from' "$RAW" \
        | sed -E 's/.*Bad LiveCellRef cast to STAT from ([A-Za-z_]+).*/\1/' \
        | sort | uniq -c | sort -nr || true

    echo
    echo "===== FIRST 40 NON-STAT RENDER ERRORS ====="
    grep -F 'Bad LiveCellRef cast to STAT from' "$RAW" | head -40 || true
} >> "$CORE"

cat "$CORE"
echo
echo "Saved core trace:"
echo "  $CORE"
echo "Saved unfiltered 20k-line log tails:"
echo "  $RAW"
