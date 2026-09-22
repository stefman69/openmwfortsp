#!/usr/bin/env bash
set -euo pipefail

HOST="${TSP_HOST:-root@192.168.1.21}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${1:-$HOME/Downloads/tsp_freeze_monitor_v1_$STAMP.tar}"

echo "===== AUTHENTICATE ONCE + COLLECT ====="
echo "Exactly one SSH connection is used."
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
    [ -x "$r/bin/openmw-0.51" ] && { ROOT="$r"; break; }
done
[ -n "$ROOT" ] || { echo "ERROR: OpenMW root not found" >&2; exit 20; }

TMP="/tmp/tsp-freeze-monitor-collect.$$"
rm -rf "$TMP"
mkdir -p "$TMP/root" "$TMP/postreboot" "$TMP/pstore"

[ -d "$ROOT/tsp_freeze_monitor" ] && cp -pr "$ROOT/tsp_freeze_monitor" "$TMP/root/"

for f in openmw_log.txt openal_soft.log tsp_helper_last.log; do
    [ -f "$ROOT/$f" ] && cp -p "$ROOT/$f" "$TMP/root/$f"
done

[ -f "$ROOT/config/openmw.log" ] && {
    mkdir -p "$TMP/root/config"
    cp -p "$ROOT/config/openmw.log" "$TMP/root/config/openmw.log"
}

cat /proc/meminfo > "$TMP/postreboot/meminfo.txt" 2>/dev/null || true
cat /proc/vmstat > "$TMP/postreboot/vmstat.txt" 2>/dev/null || true
cat /proc/swaps > "$TMP/postreboot/swaps.txt" 2>/dev/null || true
cat /proc/interrupts > "$TMP/postreboot/interrupts.txt" 2>/dev/null || true
dmesg > "$TMP/postreboot/dmesg.txt" 2>/dev/null || true
uname -a > "$TMP/postreboot/uname.txt" 2>/dev/null || true

if [ -d /sys/fs/pstore ]; then
    for p in /sys/fs/pstore/*; do
        [ -f "$p" ] || continue
        cp -p "$p" "$TMP/pstore/" 2>/dev/null || true
    done
fi

PLAY=""
for p in \
    /roms/ports/Morrowind.sh \
    /mnt/mmc/ROMS/Ports/Morrowind.sh \
    /mnt/mmc/Roms/PORTS/Morrowind.sh \
    /mnt/SDCARD/Roms/PORTS/Morrowind.sh \
    /userdata/roms/ports/Morrowind.sh \
    /storage/roms/ports/Morrowind.sh
do
    [ -f "$p" ] && { PLAY="$p"; break; }
done

{
    echo "root=$ROOT"
    echo "launcher=$PLAY"
    [ -n "$PLAY" ] && echo "launcher_sha256=$(sha256sum "$PLAY" | awk '{print $1}')"
    echo "openmw_sha256=$(sha256sum "$ROOT/bin/openmw-0.51" 2>/dev/null | awk '{print $1}')"
    echo "libgl_sha256=$(sha256sum "$ROOT/lib/libGL.so.1" 2>/dev/null | awk '{print $1}')"
} > "$TMP/manifest.txt"

tar -cf - -C "$TMP" .
RC=$?
rm -rf "$TMP"
exit "$RC"
REMOTE

[ -s "$OUT" ] || { echo "ERROR: empty archive"; exit 30; }
echo "PASS: collected $(du -h "$OUT" | awk '{print $1}')"
echo "$OUT"
