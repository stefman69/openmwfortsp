#!/bin/sh
# tsp_stallwatch.sh - record what happens during short fps stalls
#
# MEMTRACE in tsp_diag has no major-fault counter, and major faults are the
# one measurement that has actually distinguished causes so far (997 per 10 s
# during a thrash stall versus 0 while healthy). This samples that once a
# second alongside CPU time and memory, and flags the moments worth looking at.
#
# Writes to /mnt/UDISK (ext4, internal eMMC) on purpose - NOT to the SD card,
# because the SD card is the thing under investigation and logging to it would
# contaminate the measurement.
#
# Start it before or after the game; it waits for the process and exits when
# the game does. Leave it running in a second ssh window for the session.
#
#   sh /mnt/SDCARD/tsp_stallwatch.sh            # 1 s samples, default log
#   sh /mnt/SDCARD/tsp_stallwatch.sh /path.log  # custom log

OUT=${1:-/mnt/UDISK/tsp_stall.log}
FAULT_FLAG=20      # major faults in one second worth flagging
RSS_FLAG=20480     # kB of RSS movement in one second worth flagging
GAP_FLAG=3         # seconds between samples that means WE were starved too

echo "waiting for openmw-0.51 ..."
P=""
while [ -z "$P" ]; do
    P=$(pidof openmw-0.51 2>/dev/null)
    [ -z "$P" ] && sleep 2
done

{
    echo "# tsp_stallwatch pid=$P started $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# flags: FAULTBURST >${FAULT_FLAG} majflt/s | SYSSTALL sampler starved >${GAP_FLAG}s | RSSJUMP >${RSS_FLAG} kB/s"
    echo "# t clock majflt/s minflt/s utime/s stime/s rss_kb memavail_kb swap_kb threads"
} > "$OUT"

echo "logging to $OUT  (pid $P)"

P_MAJ=-1; P_MIN=-1; P_UT=-1; P_ST=-1; P_RSS=-1; P_UP=-1; T=0

while kill -0 "$P" 2>/dev/null; do
    read -r UP _ < /proc/uptime
    UP=${UP%%.*}

    MIN=0; MAJ=0; UT=0; ST=0
    read -r _l < "/proc/$P/stat" 2>/dev/null || break
    _r=${_l##*") "}
    set -- $_r
    MIN=${8}; MAJ=${10}; UT=${12}; ST=${13}

    RSS=0; THR=0
    while read -r k v _; do
        case "$k" in
            VmRSS:)   RSS=$v ;;
            Threads:) THR=$v ;;
        esac
    done < "/proc/$P/status" 2>/dev/null

    MA=0
    while read -r k v _; do
        case "$k" in MemAvailable:) MA=$v ;; esac
    done < /proc/meminfo

    SW=0
    while read -r f t s u p; do
        case "$f" in /*) SW=$u ;; esac
    done < /proc/swaps 2>/dev/null

    if [ "$P_MAJ" -ge 0 ]; then
        GAP=$(( UP - P_UP )); [ "$GAP" -lt 1 ] && GAP=1
        DMAJ=$(( (MAJ - P_MAJ) / GAP ))
        DMIN=$(( (MIN - P_MIN) / GAP ))
        DUT=$((  (UT  - P_UT ) / GAP ))
        DST=$((  (ST  - P_ST ) / GAP ))
        DRSS=$(( RSS - P_RSS )); [ "$DRSS" -lt 0 ] && DRSS=$(( -DRSS ))

        FLAG=""
        [ "$DMAJ" -gt "$FAULT_FLAG" ] && FLAG="$FLAG FAULTBURST"
        [ "$GAP"  -ge "$GAP_FLAG"   ] && FLAG="$FLAG SYSSTALL(${GAP}s)"
        [ "$DRSS" -gt "$RSS_FLAG"   ] && FLAG="$FLAG RSSJUMP"

        printf '%s %s %s %s %s %s %s %s %s %s%s\n' \
            "$T" "$(date '+%H:%M:%S')" "$DMAJ" "$DMIN" "$DUT" "$DST" \
            "$RSS" "$MA" "$SW" "$THR" "$FLAG" >> "$OUT"

        [ -n "$FLAG" ] && echo "t=$T$FLAG majflt/s=$DMAJ utime/s=$DUT rss=$RSS avail=$MA"
    fi

    P_MAJ=$MAJ; P_MIN=$MIN; P_UT=$UT; P_ST=$ST; P_RSS=$RSS; P_UP=$UP
    T=$(( T + 1 ))
    sleep 1
done

echo "# game exited at $(date '+%H:%M:%S'), $T samples" >> "$OUT"
echo "done - $OUT"