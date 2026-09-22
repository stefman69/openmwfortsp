#!/usr/bin/env bash
set -euo pipefail

HOST="${TSP_HOST:-root@192.168.1.21}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${1:-$HOME/Downloads/tsp_freeze_diag_v21_crashwatch_$STAMP.tar}"

echo "===== AUTHENTICATE ONCE + COLLECT ====="
echo "There is exactly one SSH connection in this collector."
echo "Output: $OUT"

ssh "$HOST" 'sh -s' > "$OUT" <<'REMOTE'
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
    if [ -x "$r/bin/openmw-0.51" ]; then ROOT="$r"; break; fi
done
[ -n "$ROOT" ] || { echo "ERROR: OpenMW root not found" >&2; exit 20; }

TMP="/tmp/tsp-freeze-collect.$$"
rm -rf "$TMP"
mkdir -p "$TMP/root" "$TMP/proc" "$TMP/pstore"

for f in \
    openmw_log.txt \
    openmw_perf_latest.txt \
    openmw_perf_previous.txt \
    tsp_freeze_diag_header.txt \
    tsp_crashwatch_latest.txt \
    tsp_crashwatch_previous.txt \
    openal_soft.log
do
    [ -f "$ROOT/$f" ] && cp -p "$ROOT/$f" "$TMP/root/$f"
done

[ -f "$ROOT/config/openmw.log" ] && {
    mkdir -p "$TMP/root/config"
    cp -p "$ROOT/config/openmw.log" "$TMP/root/config/openmw.log"
}

[ -d "$ROOT/tsp_ring" ] && cp -pr "$ROOT/tsp_ring" "$TMP/root/tsp_ring"

cat /proc/swaps > "$TMP/proc/swaps" 2>/dev/null || true
cat /proc/meminfo > "$TMP/proc/meminfo" 2>/dev/null || true
cat /proc/vmstat > "$TMP/proc/vmstat" 2>/dev/null || true
for p in cpu memory io; do
    cat "/proc/pressure/$p" > "$TMP/proc/pressure_$p" 2>/dev/null || true
done
dmesg > "$TMP/dmesg_after_reboot_or_run.txt" 2>/dev/null || true

if [ -d /sys/fs/pstore ]; then
    for p in /sys/fs/pstore/*; do
        [ -f "$p" ] || continue
        cp -p "$p" "$TMP/pstore/" 2>/dev/null || true
    done
fi

printf '%s\n' "$ROOT" > "$TMP/openmw_root.txt"
tar -cf - -C "$TMP" .
RC=$?
rm -rf "$TMP"
exit "$RC"
REMOTE

[ -s "$OUT" ] || { echo "ERROR: collector produced an empty archive"; exit 30; }

echo "PASS: collected $(du -h "$OUT" | awk '{print $1}')"
echo "$OUT"
