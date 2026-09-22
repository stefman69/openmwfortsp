#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/Downloads"
DEV="${TSP_DEV:-root@192.168.1.25}"
ROOT="/mnt/SDCARD/data/ports/openmw51"
LUA="$ROOT/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/visgrid-v21-1-stable-aperture-$STAMP.txt"
{
    echo "===== V21.1 SENSOR ====="
    ssh "$DEV" "sha256sum '$LUA'; grep -n 'TSP_VISGRID_LUA_V21_1_STABLE_APERTURE' '$LUA' || true"
    echo
    echo "===== V21.1 SESSION ====="
    ssh "$DEV" '
ROOT="/mnt/SDCARD/data/ports/openmw51"
for LOG in "$ROOT/openmw_051_log.txt" "$ROOT/config-0.51/openmw.log"; do
  [ -s "$LOG" ] || continue
  echo
  echo "--- $LOG ---"
  tail -n 7000 "$LOG" | grep -E "TSP_VISGRID_V21\\.1|TSP_VISGRID_V21|TSP_VISGRID_V20|topology sector=|v21=1| ERROR #|sensor DISABLED" || true
done
'
} | tee "$OUT"
echo
echo "Saved:"
echo "  $OUT"
