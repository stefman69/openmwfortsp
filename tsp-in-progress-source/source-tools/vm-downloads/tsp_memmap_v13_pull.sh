#!/bin/sh
(
ROOT="/mnt/mmc/ports/openmw"
PORTS="/mnt/mmc/ROMS/Ports"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/tsp_memmap_v13_$STAMP.tar"
TMP="$ROOT/.tsp_memmap_v13_pull_$$"

cleanup_pull() {
    rm -rf "$TMP" 2>/dev/null || true
}

echo "========================================"
echo "V13 MEMORY + MAP DIAGNOSTIC PULL"
echo "========================================"
echo "$OUT"
echo

rm -rf "$TMP" 2>/dev/null || true

if ! mkdir -p "$TMP"; then
    echo "ERROR: could not create $TMP"
else
    echo "[1/7] Identity"
    {
        echo "collected=$(date)"
        uname -a 2>/dev/null || true
        echo
        echo "===== V13 LAUNCHER ====="
        sha256sum "$PORTS/Morrowind-TSP-MEMMAP-DIAG-V13.sh" 2>/dev/null || true
        echo
        echo "===== PRODUCTION LIBGL ====="
        sha256sum "$ROOT/lib/libGL.so.1" 2>/dev/null || true
        echo
        echo "===== TSP V13 LIBGL ====="
        sha256sum "$ROOT/lib.tsp-pvr-texture-v2/libGL.so.1" 2>/dev/null || true
        echo
        echo "===== PRODUCTION OPENMW ====="
        sha256sum "$ROOT/bin/openmw-0.51" 2>/dev/null || true
        echo
        echo "===== TSP V13 OPENMW ====="
        sha256sum "$ROOT/bin/openmw-0.51.tsp-memmap-v13" 2>/dev/null || true
        echo
        echo "===== MAP-DIAG IDENTITY ====="
        cat "$ROOT/tsp_map_diag/latest/identity.txt" 2>/dev/null || true
    } > "$TMP/identity.txt" 2>&1

    echo "[2/7] Complete map/native diagnostics"
    if [ -d "$ROOT/tsp_map_diag/latest" ]; then
        cp -pr "$ROOT/tsp_map_diag/latest" "$TMP/map-diag-latest" 2>/dev/null || true
    else
        echo "MISSING: tsp_map_diag/latest" > "$TMP/map-diag-MISSING.txt"
    fi

    echo "[3/7] OpenMW + focused events"
    [ -f "$ROOT/openmw_log.txt" ] && cp -p "$ROOT/openmw_log.txt" "$TMP/" 2>/dev/null || true
    {
        echo "===== MAP CAMERA / RTT ====="
        grep -E \
          'TSP_RTTOCC_WRONGCAM_V13|TSP_LOCALMAP_CAMERA_DRAIN_V13|TSP_MAPLIFE_V2|TSP_GMAP_MEM_V1' \
          "$ROOT/openmw_log.txt" 2>/dev/null || true
        echo
        echo "===== LOAD MEMORY ====="
        grep -E \
          'TSP_LOADMEM_V1|TSP_LOAD_TRACE_051_V13|TSP_MEMGATE_V1|cleanup-done' \
          "$ROOT/openmw_log.txt" 2>/dev/null || true
        echo
        echo "===== SHADER PREWARM ====="
        grep -E \
          'TSP_WARMDRAW|TSP_PRECOMPILE|TSP_DEDUP|TSP_VARIANT|TSP_LOAD_FREEZE' \
          "$ROOT/openmw_log.txt" 2>/dev/null || true
    } > "$TMP/v13-focused-openmw.txt" 2>&1

    echo "[4/7] Freeze monitor"
    [ -d "$ROOT/tsp_freeze_monitor/latest" ] \
        && cp -pr "$ROOT/tsp_freeze_monitor/latest" "$TMP/freeze-monitor-latest" 2>/dev/null || true

    echo "[5/7] PowerVR + memory state"
    {
        echo "===== PVR DRIVER STATS ====="
        cat /sys/kernel/debug/pvr/driver_stats 2>/dev/null || true
        echo
        echo "===== PVR DEFER/FREE ====="
        for f in /sys/kernel/debug/pvr/*defer* /sys/kernel/debug/pvr/*free*; do
            [ -f "$f" ] || continue
            echo "--- $f ---"
            head -n 1000 "$f" 2>/dev/null || true
        done
        echo
        echo "===== MEMINFO ====="
        cat /proc/meminfo 2>/dev/null || true
        echo
        echo "===== SWAPS ====="
        cat /proc/swaps 2>/dev/null || true
        echo
        echo "===== ZRAM ====="
        zramctl 2>/dev/null || true
        cat /sys/block/zram0/mm_stat 2>/dev/null || true
        echo
        echo "===== VMSTAT ====="
        grep -E \
          '^(pgmajfault|pswpin|pswpout|pgscan_|pgsteal_|allocstall|compact_|oom_kill)' \
          /proc/vmstat 2>/dev/null || true
    } > "$TMP/current-system.txt" 2>&1

    echo "[6/7] Kernel log"
    dmesg > "$TMP/dmesg.txt" 2>/dev/null || true

    echo "[7/7] Building archive"
    cd "$ROOT" 2>/dev/null || true

    if [ "$PWD" != "$ROOT" ]; then
        echo "ERROR: could not enter $ROOT"
        cleanup_pull
    else
        rm -f "$OUT" 2>/dev/null || true
        if tar -cf "$OUT" "$(basename "$TMP")"; then
            cleanup_pull
            sync
            echo
            echo "========================================"
            echo "V13 DIAGNOSTIC PULL COMPLETE"
            echo "========================================"
            echo "$OUT"
            sha256sum "$OUT" 2>/dev/null || true
            ls -lh "$OUT" 2>/dev/null || true
            if tar -tf "$OUT" >/dev/null 2>&1; then
                echo "PASS: archive readable"
            else
                echo "ERROR: archive validation failed"
            fi
        else
            RC=$?
            echo "ERROR: tar failed rc=$RC"
            echo "LobiShell should remain open."
            rm -f "$OUT" 2>/dev/null || true
            cleanup_pull
        fi
    fi
fi

echo
echo "Returned safely to LobiShell."
)
