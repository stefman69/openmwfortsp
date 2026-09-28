#!/bin/sh

# TSP_MEMWATCH_V1
#
# Usage:
#   tsp_memwatch_v1.sh OPENMW_PID OUTPUT_DIR
#
# BusyBox-friendly.  No Python, smem, pmap, gdb or other optional
# packages are required.

PID="$1"
OUT="${2:-/mnt/SDCARD/data/ports/openmw/tsp-memory-diag}"

mkdir -p "$OUT" 2>/dev/null || exit 1

TSV="$OUT/memory.tsv"
EVENTS="$OUT/events.log"
FINAL="$OUT/final.txt"

echo "TSP_MEMWATCH_V1 start pid=$PID date=$(date)" > "$EVENTS"

echo "epoch	memavail_kb	memfree_kb	cached_kb	buffers_kb	slab_kb	sreclaim_kb	shmem_kb	swaptotal_kb	swapfree_kb	vmrss_kb	vmsize_kb	vmdata_kb	vmswap_kb	rssanon_kb	rssfile_kb	threads	fds	pss_kb	private_dirty_kb	private_clean_kb	shared_dirty_kb	shared_clean_kb	psi_some_avg10	psi_full_avg10	zram_mem_bytes" > "$TSV"

threshold160=0
threshold120=0
threshold80=0

value()
{
    awk -v k="$1" '$1 == k":" {print $2; exit}' "$2" 2>/dev/null
}

snapshot()
{
    tag="$1"
    dir="$OUT/snapshot-$tag"
    mkdir -p "$dir" 2>/dev/null || return

    date > "$dir/date.txt" 2>/dev/null
    cat /proc/meminfo > "$dir/meminfo.txt" 2>/dev/null
    cat /proc/swaps > "$dir/swaps.txt" 2>/dev/null
    cat /proc/pressure/memory > "$dir/pressure-memory.txt" 2>/dev/null

    cat "/proc/$PID/status" \
        > "$dir/openmw-status.txt" 2>/dev/null

    cat "/proc/$PID/smaps_rollup" \
        > "$dir/openmw-smaps-rollup.txt" 2>/dev/null

    cat "/proc/$PID/limits" \
        > "$dir/openmw-limits.txt" 2>/dev/null

    if [ -d "/proc/$PID/fd" ]; then
        ls "/proc/$PID/fd" 2>/dev/null \
            > "$dir/openmw-fds.txt"
    fi

    if [ -d "/proc/$PID/task" ]; then
        for t in /proc/"$PID"/task/*; do
            [ -r "$t/status" ] || continue
            {
                echo "===== $t ====="
                grep -E \
                    '^(Name|Pid|Tgid|State|VmRSS|VmSize|VmData|VmSwap|Threads):' \
                    "$t/status" 2>/dev/null
            } >> "$dir/threads.txt"
        done
    fi

    for z in /sys/block/zram*; do
        [ -d "$z" ] || continue

        zn="$(basename "$z")"

        {
            echo "===== $zn ====="
            cat "$z/mm_stat" 2>/dev/null
            cat "$z/stat" 2>/dev/null
        } > "$dir/$zn.txt"
    done

    if [ -r /sys/kernel/debug/dma_buf/bufinfo ]; then
        cat /sys/kernel/debug/dma_buf/bufinfo \
            > "$dir/dma-buf.txt" 2>/dev/null
    fi

    CACHE="/mnt/SDCARD/data/ports/openmw/savegame/tsp-localmap-cache-v7"

    if [ -d "$CACHE" ]; then
        {
            echo -n "files="
            find "$CACHE" -type f 2>/dev/null | wc -l
            du -sk "$CACHE" 2>/dev/null
        } > "$dir/localmap-cache.txt"
    fi

    echo "snapshot=$tag date=$(date)" >> "$EVENTS"
}

while kill -0 "$PID" 2>/dev/null
do
    MEM="/proc/meminfo"
    STATUS="/proc/$PID/status"
    ROLL="/proc/$PID/smaps_rollup"

    [ -r "$STATUS" ] || break

    epoch="$(date +%s)"

    memavail="$(value MemAvailable "$MEM")"
    memfree="$(value MemFree "$MEM")"
    cached="$(value Cached "$MEM")"
    buffers="$(value Buffers "$MEM")"
    slab="$(value Slab "$MEM")"
    sreclaim="$(value SReclaimable "$MEM")"
    shmem="$(value Shmem "$MEM")"
    swaptotal="$(value SwapTotal "$MEM")"
    swapfree="$(value SwapFree "$MEM")"

    vmrss="$(value VmRSS "$STATUS")"
    vmsize="$(value VmSize "$STATUS")"
    vmdata="$(value VmData "$STATUS")"
    vmswap="$(value VmSwap "$STATUS")"
    rssanon="$(value RssAnon "$STATUS")"
    rssfile="$(value RssFile "$STATUS")"
    threads="$(value Threads "$STATUS")"

    fds=0
    if [ -d "/proc/$PID/fd" ]; then
        fds="$(ls "/proc/$PID/fd" 2>/dev/null | wc -l)"
    fi

    pss=""
    pdirty=""
    pclean=""
    sdirty=""
    sclean=""

    if [ -r "$ROLL" ]; then
        pss="$(value Pss "$ROLL")"
        pdirty="$(value Private_Dirty "$ROLL")"
        pclean="$(value Private_Clean "$ROLL")"
        sdirty="$(value Shared_Dirty "$ROLL")"
        sclean="$(value Shared_Clean "$ROLL")"
    fi

    psi_some=""
    psi_full=""

    if [ -r /proc/pressure/memory ]; then
        psi_some="$(
            awk '/^some / {
                for(i=1;i<=NF;i++)
                    if($i ~ /^avg10=/) {
                        sub("avg10=","",$i)
                        print $i
                    }
            }' /proc/pressure/memory
        )"

        psi_full="$(
            awk '/^full / {
                for(i=1;i<=NF;i++)
                    if($i ~ /^avg10=/) {
                        sub("avg10=","",$i)
                        print $i
                    }
            }' /proc/pressure/memory
        )"
    fi

    zram_mem=0

    for z in /sys/block/zram*/mm_stat; do
        [ -r "$z" ] || continue
        n="$(awk '{print $3}' "$z" 2>/dev/null)"
        case "$n" in
            ''|*[!0-9]*) ;;
            *) zram_mem=$((zram_mem + n)) ;;
        esac
    done

    echo "$epoch	${memavail:-0}	${memfree:-0}	${cached:-0}	${buffers:-0}	${slab:-0}	${sreclaim:-0}	${shmem:-0}	${swaptotal:-0}	${swapfree:-0}	${vmrss:-0}	${vmsize:-0}	${vmdata:-0}	${vmswap:-0}	${rssanon:-0}	${rssfile:-0}	${threads:-0}	$fds	${pss:-0}	${pdirty:-0}	${pclean:-0}	${sdirty:-0}	${sclean:-0}	${psi_some:-0}	${psi_full:-0}	$zram_mem" >> "$TSV"

    ma="${memavail:-999999}"

    if [ "$ma" -lt 163840 ] && [ "$threshold160" -eq 0 ]; then
        threshold160=1
        snapshot "160mb"
    fi

    if [ "$ma" -lt 122880 ] && [ "$threshold120" -eq 0 ]; then
        threshold120=1
        snapshot "120mb"
    fi

    if [ "$ma" -lt 81920 ] && [ "$threshold80" -eq 0 ]; then
        threshold80=1
        snapshot "80mb"
    fi

    if [ "$ma" -lt 81920 ]; then
        sleep 2
    elif [ "$ma" -lt 163840 ]; then
        sleep 5
    else
        sleep 10
    fi
done

{
    echo "TSP_MEMWATCH_V1 final"
    echo "date=$(date)"
    echo "pid=$PID"
    echo
    echo "===== MEMINFO ====="
    cat /proc/meminfo 2>/dev/null
    echo
    echo "===== SWAPS ====="
    cat /proc/swaps 2>/dev/null
    echo
    echo "===== MEMORY PRESSURE ====="
    cat /proc/pressure/memory 2>/dev/null
} > "$FINAL"

echo "TSP_MEMWATCH_V1 stop pid=$PID date=$(date)" >> "$EVENTS"

exit 0
