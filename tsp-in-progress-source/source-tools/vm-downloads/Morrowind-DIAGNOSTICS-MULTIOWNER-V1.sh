#!/bin/sh

run_multiowner() {
    GAME=""
    for G in /mnt/SDCARD/data/ports/openmw /mnt/sdcard/mmcblk1p1/data/ports/openmw /mnt/mmc/ports/openmw /userdata/roms/ports/openmw; do
        [ -x "$G/bin/openmw-0.51" ] && { GAME="$G"; break; }
    done
    [ -z "$GAME" ] && { echo "ERROR: OpenMW game directory not found"; return 1; }

    SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
    OLD="$SELF_DIR/Morrowind-DIAGNOSTICS-GLOWNER-V1-remade.sh"
    if [ ! -f "$OLD" ]; then
        OLD="$(find /mnt/SDCARD/Roms/PORTS /mnt/SDCARD/Emus/PORTS /mnt/sdcard/mmcblk1p1/ROMS/PORTS /mnt/sdcard/mmcblk1p1/Emus/PORTS -maxdepth 2 -type f -name 'Morrowind-DIAGNOSTICS-GLOWNER-V1-remade.sh' 2>/dev/null | head -1)"
    fi
    [ -z "$OLD" ] || [ ! -f "$OLD" ] && { echo "ERROR: existing GLOWNER launcher not found"; return 1; }

    D="$GAME/tsp-multiowner-v1"
    ARCHIVE="$GAME/tsp-multiowner-v1.tar.gz"
    rm -rf "$D" "$ARCHIVE" 2>/dev/null
    mkdir -p "$D"
    export LIBGL_TSP_OWNER_DIAG="$D/gl4es-owner.log"

    {
        echo "TSP MULTI-OWNER V1"; date; uname -a; echo
        echo "GAME=$GAME"; echo "BASE_LAUNCHER=$OLD"; echo
        echo "===== HASHES ====="
        sha256sum "$GAME/bin/openmw-0.51" "$GAME/lib/libGL.so.1" "$OLD" 2>/dev/null
        echo "===== LIBGL MARKERS ====="
        grep -ao 'TSP_[A-Z0-9_]*V[0-9][A-Z0-9_]*' "$GAME/lib/libGL.so.1" 2>/dev/null | sort -u | head -200
        echo "===== ENV ====="
        env | sort | grep -E '^(LIBGL|OPENMW|OSG|TSP_)' || true
    } > "$D/identity.txt" 2>&1

    {
        echo "===== MEMINFO START ====="; cat /proc/meminfo 2>/dev/null
        echo "===== VMSTAT START ====="; cat /proc/vmstat 2>/dev/null
        echo "===== ZRAM START ====="
        for Z in /sys/block/zram*/mm_stat; do [ -r "$Z" ] && { echo "--- $Z"; cat "$Z"; }; done
        echo "===== GPU/PVR CANDIDATES ====="
        find /sys/kernel/debug /sys/class -maxdepth 5 -type f 2>/dev/null | grep -Ei '(pvr|powervr|gpu|mali|dma_buf|ion).*(mem|heap|stat|usage|info)' | head -100
        if [ -r /sys/kernel/debug/dma_buf/bufinfo ]; then
            echo "===== DMA BUF START ====="; head -n 1000 /sys/kernel/debug/dma_buf/bufinfo
        fi
    } > "$D/system-start.txt" 2>&1

    monitor_process() {
        PID=""
        while [ -z "$PID" ]; do
            PID="$(pgrep -o -f "$GAME/bin/openmw-0.51" 2>/dev/null)"
            [ -z "$PID" ] && PID="$(pgrep -o -f 'openmw-0.51' 2>/dev/null)"
            [ -z "$PID" ] && sleep 1
        done

        echo "PID=$PID" > "$D/pid.txt"; date >> "$D/pid.txt"
        cp "/proc/$PID/maps" "$D/maps-start.txt" 2>/dev/null
        N=0

        while kill -0 "$PID" 2>/dev/null; do
            TS="$(date '+%Y-%m-%dT%H:%M:%S%z')"
            STATUS="$(cat "/proc/$PID/status" 2>/dev/null)"
            RSS="$(printf '%s\n' "$STATUS" | awk '/^VmRSS:/ {print $2}')"
            SIZE="$(printf '%s\n' "$STATUS" | awk '/^VmSize:/ {print $2}')"
            DATA="$(printf '%s\n' "$STATUS" | awk '/^VmData:/ {print $2}')"
            SWAP="$(printf '%s\n' "$STATUS" | awk '/^VmSwap:/ {print $2}')"
            ANON="$(printf '%s\n' "$STATUS" | awk '/^RssAnon:/ {print $2}')"
            FILE="$(printf '%s\n' "$STATUS" | awk '/^RssFile:/ {print $2}')"
            SHMEM="$(printf '%s\n' "$STATUS" | awk '/^RssShmem:/ {print $2}')"
            THR="$(printf '%s\n' "$STATUS" | awk '/^Threads:/ {print $2}')"
            FD="$(find "/proc/$PID/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
            MAPS="$(wc -l < "/proc/$PID/maps" 2>/dev/null)"

            echo "$TS pid=$PID vmrss_kb=${RSS:-0} vmsize_kb=${SIZE:-0} vmdata_kb=${DATA:-0} vmswap_kb=${SWAP:-0} rssanon_kb=${ANON:-0} rssfile_kb=${FILE:-0} rssshmem_kb=${SHMEM:-0} threads=${THR:-0} fds=${FD:-0} maps=${MAPS:-0}" >> "$D/process-samples.log"

            { echo "===== $TS ====="; cat "/proc/$PID/smaps_rollup" 2>/dev/null; } >> "$D/smaps-rollup.log"

            awk -v ts="$TS" '
                BEGIN { cat="anon" }
                /^[0-9a-fA-F]+-[0-9a-fA-F]+/ {
                    line=tolower($0); cat="anon";
                    if (line ~ /\[heap\]/) cat="heap";
                    else if (line ~ /libgl|libgles|powervr|pvr|mali/) cat="gpu_lib";
                    else if (line ~ /\[stack/) cat="stack";
                    else if ($0 ~ /\//) cat="file";
                }
                /^Rss:/ {rss[cat]+=$2} /^Pss:/ {pss[cat]+=$2} /^Private_Dirty:/ {pd[cat]+=$2}
                END { printf "%s",ts; for(c in rss) printf " %s_rss_kb=%d %s_pss_kb=%d %s_private_dirty_kb=%d",c,rss[c],c,pss[c],c,pd[c]; printf "\n" }
            ' "/proc/$PID/smaps" 2>/dev/null >> "$D/smaps-categories.log"

            awk -v ts="$TS" '
                /^MemAvailable:/ {a=$2} /^MemFree:/ {f=$2} /^Cached:/ {c=$2} /^Slab:/ {s=$2}
                /^SReclaimable:/ {sr=$2} /^SUnreclaim:/ {su=$2} /^CmaTotal:/ {ct=$2} /^CmaFree:/ {cf=$2}
                /^SwapTotal:/ {st=$2} /^SwapFree:/ {sf=$2}
                END { printf "%s memavail_kb=%d memfree_kb=%d cached_kb=%d slab_kb=%d sreclaim_kb=%d sunreclaim_kb=%d cma_total_kb=%d cma_free_kb=%d swap_total_kb=%d swap_free_kb=%d\n",ts,a,f,c,s,sr,su,ct,cf,st,sf }
            ' /proc/meminfo >> "$D/system-memory-samples.log"

            awk -v ts="$TS" 'BEGIN{printf "%s",ts} /^(nr_free_pages|nr_slab_reclaimable|nr_slab_unreclaimable|nr_anon_pages|nr_file_pages|nr_page_table_pages|pgscan_|pgsteal_|compact_|oom_kill)/ {printf " %s=%s",$1,$2} END{printf "\n"}' /proc/vmstat 2>/dev/null >> "$D/vmstat-samples.log"

            for Z in /sys/block/zram*/mm_stat; do [ -r "$Z" ] && echo "$TS $Z $(cat "$Z" 2>/dev/null)" >> "$D/zram-samples.log"; done

            N=$((N + 1))
            if [ $((N % 6)) -eq 0 ]; then
                { echo "===== $TS PID=$PID ====="; ps -T -p "$PID" -o pid,tid,stat,pcpu,rss,vsz,comm 2>/dev/null; } >> "$D/thread-samples.log"
                cp "/proc/$PID/maps" "$D/maps-latest.txt" 2>/dev/null
            fi
            sleep 10
        done
        date > "$D/monitor-ended.txt"
    }

    monitor_process &
    MON_PID=$!

    echo "============================================================"
    echo "TSP MULTI-OWNER V1"
    echo "Using base launcher: $OLD"
    echo "============================================================"

    "$OLD"
    GAME_RC=$?

    kill "$MON_PID" 2>/dev/null
    wait "$MON_PID" 2>/dev/null

    {
        echo "GAME_RC=$GAME_RC"; date
        echo "===== MEMINFO END ====="; cat /proc/meminfo 2>/dev/null
        echo "===== VMSTAT END ====="; cat /proc/vmstat 2>/dev/null
        if [ -r /sys/kernel/debug/dma_buf/bufinfo ]; then echo "===== DMA BUF END ====="; head -n 1000 /sys/kernel/debug/dma_buf/bufinfo; fi
    } > "$D/system-end.txt" 2>&1

    [ -f "$GAME/tsp-glowner-v1.tar.gz" ] && cp -f "$GAME/tsp-glowner-v1.tar.gz" "$D/glowner-run.tar.gz" 2>/dev/null
    [ -d "$GAME/tsp-glowner-v1" ] && cp -a "$GAME/tsp-glowner-v1" "$D/glowner-directory" 2>/dev/null

    tar -C "$GAME" -czf "$ARCHIVE" tsp-multiowner-v1 2>"$D/tar-error.log"
    TAR_RC=$?
    mkdir -p /root/diagnostics 2>/dev/null

    if [ "$TAR_RC" -eq 0 ] && [ -s "$ARCHIVE" ]; then
        cp -f "$ARCHIVE" /root/diagnostics/tsp-multiowner-v1.tar.gz 2>/dev/null
        echo "============================================================"
        echo "MULTI-OWNER DIAGNOSTIC READY"
        echo "============================================================"
        ls -lh "$ARCHIVE"; sha256sum "$ARCHIVE" 2>/dev/null
        echo "/root/diagnostics/tsp-multiowner-v1.tar.gz"
    else
        echo "ERROR: archive creation failed. Raw diagnostics: $D"
        cat "$D/tar-error.log" 2>/dev/null
    fi

    return "$GAME_RC"
}

run_multiowner "$@"
