#!/bin/sh
# TSP_FREEZE_MONITOR_V1
# External freeze monitor. Does not modify or launch Morrowind/OpenMW.
# Run only after the save has loaded into gameplay.
set -u

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
[ -n "$ROOT" ] || { echo "ERROR: OpenMW root not found"; exit 20; }

find_openmw_pid() {
    for d in /proc/[0-9]*; do
        [ -r "$d/comm" ] || continue
        IFS= read -r c < "$d/comm" || continue
        case "$c" in
            openmw-0.51|openmw) echo "${d##*/}"; return 0 ;;
        esac
    done
    return 1
}

PID="$(find_openmw_pid || true)"
[ -n "$PID" ] || {
    echo "ERROR: OpenMW is not running."
    echo "Load the save into gameplay first, then start this monitor."
    exit 21
}

RUNS="$ROOT/tsp_freeze_monitor"
mkdir -p "$RUNS"
STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
DIR="$RUNS/run-$STAMP"
mkdir -p "$DIR"

echo "$DIR" > "$RUNS/latest.path"
echo "$PID" > "$DIR/openmw.pid"
echo "$$" > "$DIR/monitor.pid"

# ---------- one-shot identity / binary / GL proof ----------
{
    echo "TSP_FREEZE_MONITOR_V1"
    echo "started=$(date 2>/dev/null)"
    echo "root=$ROOT"
    echo "openmw_pid=$PID"
    echo "monitor_pid=$$"
    echo "kernel=$(uname -a 2>/dev/null)"
    echo "uptime=$(cat /proc/uptime 2>/dev/null)"
    echo "--- os-release ---"
    cat /etc/os-release 2>/dev/null || true
    echo "--- cmdline ---"
    tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null || true
    echo
    echo "--- relevant environment ---"
    tr '\0' '\n' < "/proc/$PID/environ" 2>/dev/null | \
        grep -E '^(LD_PRELOAD|LD_LIBRARY_PATH|LIBGL_|OSG_|OPENMW_|TSP_)' 2>/dev/null || true
    echo "--- loaded GL / GPU / shim mappings ---"
    grep -Ei 'libGL|GLES|EGL|pvr|mali|tsp_|OpenThreads|osg' "/proc/$PID/maps" 2>/dev/null || true
    echo "--- hashes ---"
    for f in \
        "$ROOT/bin/openmw-0.51" \
        "$ROOT/lib/libGL.so.1" \
        "$ROOT/lib/libtsp_warm.so" \
        "$ROOT/lib/libtsp_fullscreen_scaler.so"
    do
        [ -r "$f" ] && sha256sum "$f" 2>/dev/null
    done
    echo "--- libGL diagnostic marker census ---"
    if [ -r "$ROOT/lib/libGL.so.1" ]; then
        for m in \
            TSP_MAXCOLORATTACH TSP_PASSSTATE_V5 LIBGL_TSP_FBODUMP \
            GL_PIXEL_UNPACK_BUFFER TSP_VBO_ORPHAN TSP_RTT
        do
            n="$(grep -a -c "$m" "$ROOT/lib/libGL.so.1" 2>/dev/null || true)"
            echo "$m=$n"
        done
    fi
    echo "--- modules ---"
    cat /proc/modules 2>/dev/null || true
    echo "--- gpu-ish interrupts ---"
    grep -Ei 'pvr|powervr|rogue|sgx|gpu|mali' /proc/interrupts 2>/dev/null || true
    echo "--- proc pvr entries ---"
    if [ -d /proc/pvr ]; then
        for f in /proc/pvr/*; do
            [ -r "$f" ] || continue
            echo "### $f"
            head -n 80 "$f" 2>/dev/null || true
        done
    fi
    echo "--- GPU sysfs discovery ---"
    for f in \
        /sys/devices/platform/gpu/scenectrl/status \
        /sys/devices/platform/gpu/scenectrl/command \
        /sys/class/devfreq/*gpu*/name \
        /sys/class/devfreq/*gpu*/cur_freq \
        /sys/class/devfreq/*gpu*/governor
    do
        [ -r "$f" ] || continue
        echo "### $f"
        cat "$f" 2>/dev/null || true
    done
    echo "--- pstore at start ---"
    if [ -d /sys/fs/pstore ]; then
        ls -l /sys/fs/pstore 2>/dev/null || true
    fi
} > "$DIR/identity.txt" 2>&1

cp -f "/proc/$PID/maps" "$DIR/openmw.maps" 2>/dev/null || true
cp -f "/proc/$PID/smaps_rollup" "$DIR/openmw.smaps_rollup.start" 2>/dev/null || true

# ---------- continuous kernel log capture ----------
KLOG_PID=""
dmesg_stream() {
    dmesg -w >> "$DIR/kernel-live.txt" 2>&1
}
dmesg_fallback() {
    i=0
    while kill -0 "$PID" 2>/dev/null; do
        {
            echo "===== dmesg snapshot t=$i ====="
            dmesg 2>/dev/null | tail -n 120
        } >> "$DIR/kernel-live.txt"
        i=$((i + 10))
        sleep 10
    done
}

: > "$DIR/kernel-live.txt"
dmesg_stream &
KLOG_PID=$!
sleep 1
if ! kill -0 "$KLOG_PID" 2>/dev/null; then
    wait "$KLOG_PID" 2>/dev/null || true
    dmesg_fallback &
    KLOG_PID=$!
    echo "kernel_log_mode=fallback-snapshot" >> "$DIR/identity.txt"
else
    echo "kernel_log_mode=dmesg-w" >> "$DIR/identity.txt"
fi

cleanup() {
    [ -n "${KLOG_PID:-}" ] && kill "$KLOG_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

# ---------- TSV header ----------
cat > "$DIR/system.tsv" <<'EOF'
# TSP_FREEZE_MONITOR_V1
# t proc_state rss_kb vsz_kb data_kb vmswap_kb rssanon_kb rssfile_kb rssshmem_kb threads fd_count memavail_kb memfree_kb cached_kb sreclaim_kb slab_kb shmem_kb cmafree_kb swapfree_kb swapcached_kb psi_cpu psi_mem psi_io minflt majflt utime stime pgmajfault pswpin pswpout scan_direct steal_direct allocstall oom_kill ctxt running blocked io_read io_write gpu_irq temp_max_mC cpu_khz gpu_khz
EOF

snapshot_stall() {
    n="$1"
    S="$DIR/stall-$n"
    mkdir -p "$S"
    cp -f "/proc/$PID/status" "$S/status.txt" 2>/dev/null || true
    cp -f "/proc/$PID/smaps_rollup" "$S/smaps_rollup.txt" 2>/dev/null || true
    cp -f /proc/meminfo "$S/meminfo.txt" 2>/dev/null || true
    cp -f /proc/vmstat "$S/vmstat.txt" 2>/dev/null || true
    cp -f /proc/interrupts "$S/interrupts.txt" 2>/dev/null || true
    cp -f /proc/swaps "$S/swaps.txt" 2>/dev/null || true
    {
        echo "stall_snapshot=$(date 2>/dev/null)"
        echo "--- thread state / ticks / cpu / wchan ---"
        for td in /proc/"$PID"/task/[0-9]*; do
            [ -r "$td/stat" ] || continue
            IFS= read -r sl < "$td/stat" || continue
            rest=${sl##*) }
            set -- $rest
            state=${1:-?}
            ut=${12:-0}
            st=${13:-0}
            cpu=${37:-?}
            w="$(cat "$td/wchan" 2>/dev/null)"
            echo "tid=${td##*/} state=$state ticks=$((ut + st)) cpu=$cpu wchan=$w"
        done
        echo "--- gpu-ish interrupts ---"
        grep -Ei 'pvr|powervr|rogue|sgx|gpu|mali' /proc/interrupts 2>/dev/null || true
        echo "--- proc pvr ---"
        if [ -d /proc/pvr ]; then
            for f in /proc/pvr/*; do
                [ -r "$f" ] || continue
                echo "### $f"
                head -n 100 "$f" 2>/dev/null || true
            done
        fi
        echo "--- GPU sysfs ---"
        for f in \
            /sys/devices/platform/gpu/scenectrl/status \
            /sys/devices/platform/gpu/scenectrl/command \
            /sys/class/devfreq/*gpu*/cur_freq \
            /sys/class/devfreq/*gpu*/governor
        do
            [ -r "$f" ] || continue
            echo "### $f"
            cat "$f" 2>/dev/null || true
        done
        echo "--- dmesg tail ---"
        dmesg 2>/dev/null | tail -n 160
    } > "$S/detail.txt" 2>&1
}

T=0
LAST_TICKS=""
STILL=0
STALLN=0

while kill -0 "$PID" 2>/dev/null; do
    STATE=na; RSS=na; VSZ=na; DATA=na; VMSWAP=na; ANON=na; FILE=na; SHM=na; THR=na
    while read -r k v _; do
        case "$k" in
            State:) STATE=$v ;;
            VmRSS:) RSS=$v ;;
            VmSize:) VSZ=$v ;;
            VmData:) DATA=$v ;;
            VmSwap:) VMSWAP=$v ;;
            RssAnon:) ANON=$v ;;
            RssFile:) FILE=$v ;;
            RssShmem:) SHM=$v ;;
            Threads:) THR=$v ;;
        esac
    done < "/proc/$PID/status"

    FD=0
    for f in /proc/"$PID"/fd/*; do [ -e "$f" ] && FD=$((FD + 1)); done

    MA=na; MF=na; CACHED=na; SREC=na; SLAB=na; SHMEM=na; CMA=na; SWFREE=na; SWCACHED=na
    while read -r k v _; do
        case "$k" in
            MemAvailable:) MA=$v ;;
            MemFree:) MF=$v ;;
            Cached:) CACHED=$v ;;
            SReclaimable:) SREC=$v ;;
            Slab:) SLAB=$v ;;
            Shmem:) SHMEM=$v ;;
            CmaFree:) CMA=$v ;;
            SwapFree:) SWFREE=$v ;;
            SwapCached:) SWCACHED=$v ;;
        esac
    done < /proc/meminfo

    PC=na; PM=na; PI=na
    if [ -r /proc/pressure/cpu ]; then
        while read -r kind rest; do
            [ "$kind" = some ] && { set -- $rest; PC=${1#avg10=}; break; }
        done < /proc/pressure/cpu
    fi
    if [ -r /proc/pressure/memory ]; then
        while read -r kind rest; do
            [ "$kind" = some ] && { set -- $rest; PM=${1#avg10=}; break; }
        done < /proc/pressure/memory
    fi
    if [ -r /proc/pressure/io ]; then
        while read -r kind rest; do
            [ "$kind" = some ] && { set -- $rest; PI=${1#avg10=}; break; }
        done < /proc/pressure/io
    fi

    MINFLT=na; MAJFLT=na; UT=na; ST=na; TICKS=""
    if IFS= read -r STATLINE < "/proc/$PID/stat"; then
        REST=${STATLINE##*) }
        set -- $REST
        MINFLT=${8:-na}; MAJFLT=${10:-na}; UT=${12:-na}; ST=${13:-na}
        case "$UT:$ST" in
            *[!0-9:]*|"") TICKS="" ;;
            *) TICKS=$((UT + ST)) ;;
        esac
    fi

    PGMAJ=na; PSIN=na; PSOUT=na; SCAN=0; STEAL=0; ALSTALL=0; OOMK=0
    while read -r k v _; do
        case "$k" in
            pgmajfault) PGMAJ=$v ;;
            pswpin) PSIN=$v ;;
            pswpout) PSOUT=$v ;;
            pgscan_direct|pgscan_direct_*) SCAN=$((SCAN + v)) ;;
            pgsteal_direct|pgsteal_direct_*) STEAL=$((STEAL + v)) ;;
            allocstall|allocstall_*) ALSTALL=$((ALSTALL + v)) ;;
            oom_kill) OOMK=$v ;;
        esac
    done < /proc/vmstat

    CTXT=na; RUN=na; BLOCK=na
    while read -r k v _; do
        case "$k" in
            ctxt) CTXT=$v ;;
            procs_running) RUN=$v ;;
            procs_blocked) BLOCK=$v ;;
        esac
    done < /proc/stat

    IOR=na; IOW=na
    if [ -r "/proc/$PID/io" ]; then
        while read -r k v; do
            case "$k" in
                read_bytes:) IOR=$v ;;
                write_bytes:) IOW=$v ;;
            esac
        done < "/proc/$PID/io"
    fi

    GPU_IRQ=0
    while IFS= read -r line; do
        case "$line" in
            *pvr*|*PVR*|*powervr*|*PowerVR*|*rogue*|*Rogue*|*sgx*|*SGX*|*gpu*|*GPU*|*mali*|*Mali*)
                set -- $line
                shift
                for x in "$@"; do
                    case "$x" in
                        *[!0-9]*) break ;;
                        *) GPU_IRQ=$((GPU_IRQ + x)) ;;
                    esac
                done
                ;;
        esac
    done < /proc/interrupts

    TEMP=na
    Tmax=-1
    for z in /sys/class/thermal/thermal_zone*/temp; do
        [ -r "$z" ] || continue
        IFS= read -r tv < "$z" || continue
        case "$tv" in ''|*[!0-9]*) continue ;; esac
        [ "$tv" -gt "$Tmax" ] && Tmax=$tv
    done
    [ "$Tmax" -ge 0 ] && TEMP=$Tmax

    CPUKHZ=na
    for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
        [ -r "$c" ] || continue
        IFS= read -r cv < "$c" || continue
        case "$cv" in ''|*[!0-9]*) continue ;; esac
        case "$CPUKHZ" in na) CPUKHZ=$cv ;; *) [ "$cv" -gt "$CPUKHZ" ] && CPUKHZ=$cv ;; esac
    done

    GPUKHZ=na
    for g in /sys/class/devfreq/*gpu*/cur_freq; do
        [ -r "$g" ] || continue
        IFS= read -r gv < "$g" || continue
        [ -n "$gv" ] && { GPUKHZ=$gv; break; }
    done

    printf '%s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s\n' \
        "$T" "$STATE" "$RSS" "$VSZ" "$DATA" "$VMSWAP" "$ANON" "$FILE" "$SHM" "$THR" "$FD" \
        "$MA" "$MF" "$CACHED" "$SREC" "$SLAB" "$SHMEM" "$CMA" "$SWFREE" "$SWCACHED" \
        "$PC" "$PM" "$PI" "$MINFLT" "$MAJFLT" "$UT" "$ST" "$PGMAJ" "$PSIN" "$PSOUT" \
        "$SCAN" "$STEAL" "$ALSTALL" "$OOMK" "$CTXT" "$RUN" "$BLOCK" "$IOR" "$IOW" \
        "$GPU_IRQ" "$TEMP" "$CPUKHZ" "$GPUKHZ" >> "$DIR/system.tsv"

    if [ -n "$TICKS" ]; then
        if [ -n "$LAST_TICKS" ] && [ "$TICKS" = "$LAST_TICKS" ]; then
            STILL=$((STILL + 1))
        else
            STILL=0
        fi
        LAST_TICKS=$TICKS
    fi

    # Five consecutive seconds with no OpenMW CPU progress while the process
    # still exists is suspicious enough to take a detailed snapshot.
    if [ "$STILL" -eq 5 ]; then
        STALLN=$((STALLN + 1))
        snapshot_stall "$STALLN"
    fi

    T=$((T + 1))
    sleep 1
done

{
    echo "ended=$(date 2>/dev/null)"
    echo "elapsed_s=$T"
    echo "openmw_pid=$PID"
    echo "process_alive=no"
} > "$DIR/end.txt"

cp -f "/proc/$PID/smaps_rollup" "$DIR/openmw.smaps_rollup.end" 2>/dev/null || true
exit 0
