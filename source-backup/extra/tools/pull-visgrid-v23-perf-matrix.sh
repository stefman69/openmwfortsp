#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/Downloads"
DEV="${TSP_DEV:-root@192.168.1.25}"
ROOT='/mnt/SDCARD/data/ports/openmw51'
LUA='/mnt/SDCARD/data/ports/openmw51/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua'
LAUNCHER='/mnt/sdcard/mmcblk1p1/Roms/PORTS/Morrowind_51.sh'
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/visgrid-v23-perf-matrix-$STAMP.txt"
RINGOUT="$HOME/Downloads/tsp_ring-v23-$STAMP.txt"
{
  echo '===== ACTIVE V23 PROFILE ====='
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" "
    sha256sum '$LUA'
    grep -n -E 'TSP_VISGRID_LUA_V23_PERF_MATRIX|TSP_VISGRID_LUA_V22_1G_STRUCTURAL_PVS_SAFETY' '$LUA' | head -8 || true
    echo
    echo 'Launcher selection:'
    grep -E '^VISGRID_(BASELINE|TOPOLOGY|PERFORMANCE)=' '$LAUNCHER' || true
  "
  echo
  echo '===== COMPACT V23 PERF / MACRO TRACE ====='
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" "
    for f in '$ROOT/openmw_051_log.txt' '$ROOT/config-0.51/openmw.log'; do
      [ -s \"\$f\" ] || continue
      echo \"--- \$f ---\"
      tail -n 30000 \"\$f\" | grep -E 'TSP_VISGRID_V23PERF|TSP_VISGRID_V23MACRO|TSP_VISGRID_V23\]|sensor DISABLED| ERROR #' | tail -n 1400 || true
    done
  "
  echo
  echo '===== RECENT LEGACY SENSOR STATUS ====='
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" "
    for f in '$ROOT/openmw_051_log.txt' '$ROOT/config-0.51/openmw.log'; do
      [ -s \"\$f\" ] || continue
      echo \"--- \$f ---\"
      tail -n 30000 \"\$f\" | grep -E 'TSP_VISGRID_V11\].*budget=|Changing to interior|Loading cell ' | tail -n 300 || true
    done
  "
} | tee "$OUT"
if scp -q -o BatchMode=yes -o ConnectTimeout=8 "$DEV:/mnt/SDCARD/tsp_ring.txt" "$RINGOUT" 2>/dev/null; then
  echo "Ring capture: $RINGOUT"
else
  echo 'No /mnt/SDCARD/tsp_ring.txt copied.'
fi
echo "Trace: $OUT"
