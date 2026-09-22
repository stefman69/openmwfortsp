#!/usr/bin/env bash
set -euo pipefail
HOST="${TSP_HOST:-root@192.168.1.21}"

echo "===== AUTHENTICATE ONCE + STOP MONITOR ====="
ssh "$HOST" 'sh -s' <<'REMOTE'
set -eu
ROOT=""
for r in \
    /mnt/SDCARD/data/ports/openmw \
    /mnt/sdcard/mmcblk1p1/data/ports/openmw \
    /userdata/roms/ports/openmw \
    /mnt/mmc/ports/openmw \
    /mnt/sdcard/ports/openmw \
    /roms/ports/openmw \
    /storage/roms/ports/openmw
do
    [ -x "$r/bin/openmw-0.51" ] && { ROOT="$r"; break; }
done
[ -n "$ROOT" ] || exit 20
P="$ROOT/tsp_freeze_monitor/active.pid"
if [ -f "$P" ]; then
    read -r PID < "$P" 2>/dev/null || PID=""
    case "$PID" in
        ''|*[!0-9]*) ;;
        *) kill "$PID" 2>/dev/null || true ;;
    esac
    rm -f "$P"
fi
echo "PASS: external monitor stopped"
REMOTE
