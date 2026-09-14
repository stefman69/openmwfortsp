#!/bin/sh
# tsp_ring_report.sh - read the tspprof ring dumps and say which slot ate the frame
#
# Reads /mnt/SDCARD/tsp_ring.txt and every triggered dump beside it
# (tsp_ring.txt.1, .2, ...). Prints a summary small enough to paste; a raw
# dump is ~900 lines and there can be eight of them.
#
# USAGE (on the device)
#     sh /mnt/SDCARD/tsp_ring_report.sh
#     sh /mnt/SDCARD/tsp_ring_report.sh /path/to/some_ring.txt
#
# Env:
#     TSP_SLOW_FACTOR   a frame is "slow" above this multiple of the median.
#                       default 2.0
#
# TWO TRAPS, BOTH FLAGGED BELOW
#     mech is double counted - engine.cpp and actors.cpp nest into one slot
#     anim, phys, ai are not instrumented and always read 0

BASE="${1:-/mnt/SDCARD/tsp_ring.txt}"
OUT="${TSP_RING_REPORT_OUT:-/mnt/SDCARD/tsp_ring_report.txt}"
FACTOR="${TSP_SLOW_FACTOR:-2.0}"
TMP="${TMPDIR:-/tmp}/tsp_ring.$$"

if ! : > "$OUT" 2>/dev/null; then OUT="$(dirname "$BASE")/tsp_ring_report.txt"; fi

analyse_one() {
    f="$1"
    echo "=============================================================="
    echo " $f    ($(wc -c < "$f") bytes)"
    echo "=============================================================="
    grep "^#" "$f" | sed 's/^/  /'

    grep -v "^#" "$f" > "$TMP" 2>/dev/null
    n=$(wc -l < "$TMP")
    if [ "${n:-0}" -lt 20 ]; then
        echo "  only $n frames - not enough to say anything. Was the ring armed?"
        echo
        return
    fi

    med=$(awk '{print $2}' "$TMP" | sort -n | awk -v n="$n" 'NR == int(n/2)+1 {print; exit}')
    p95=$(awk '{print $2}' "$TMP" | sort -n | awk -v n="$n" 'NR == int(n*0.95) {print; exit}')

    awk -v med="$med" -v p95="$p95" -v factor="$FACTOR" '
    BEGIN {
        nslot = 13
        split("mech char anim spell phys ai lua world gui event updt render sound", name, " ")
        thr = med * factor
        if (thr < med + 10) thr = med + 10
    }
    {
        n++
        tot = $2
        if (min == "" || tot < min) min = tot
        if (max == "" || tot > max) { max = tot; maxframe = $1 }
        sum += tot

        slow = (tot >= thr)
        if (slow) { ns++; ssum += tot } else { nn++; nsum += tot }

        for (k = 1; k <= nslot; k++) {
            v = $(2 + k)
            if (slow) sslot[k] += v; else nslot_sum[k] += v
        }
        # calls live after the "|" at field 16
        for (k = 1; k <= nslot; k++) ncalls[k] += $(16 + k)

        # keep the 8 slowest frames
        if (top_n < 8 || tot > top_v[top_n]) {
            i = (top_n < 8) ? ++top_n : 8
            while (i > 1 && top_v[i-1] < tot) {
                top_v[i] = top_v[i-1]; top_l[i] = top_l[i-1]; i--
            }
            top_v[i] = tot; top_l[i] = $0
        }
    }
    END {
        printf "\n  frames %d   median %.1f ms (%.0f fps)   p95 %.1f ms   max %.1f ms at frame %s\n",
               n, med, (med > 0 ? 1000/med : 0), p95, max, maxframe
        printf "  slow threshold %.1f ms  ->  %d slow frames, %d normal\n", thr, ns+0, nn+0

        if (ns == 0) {
            print "\n  No frame in this dump crossed the threshold. Either the dip is not"
            print "  in this capture, or the trigger fired on something milder than what"
            print "  you felt. Lower TSP_SLOW_FACTOR and re-run, or lower"
            print "  OPENMW_TSP_RING_TRIGGER_MS and capture again."
            print ""
            exit
        }

        printf "\n  mean frame:  normal %.1f ms   slow %.1f ms   (+%.1f ms)\n",
               nsum/nn, ssum/ns, ssum/ns - nsum/nn

        # extra time per slot, slow vs normal
        extra_total = 0
        for (k = 1; k <= nslot; k++) {
            nm[k] = (nn > 0) ? nslot_sum[k]/nn : 0
            sm[k] = sslot[k]/ns
            d[k]  = sm[k] - nm[k]
            if (d[k] > 0) extra_total += d[k]
        }

        print "\n  WHERE THE EXTRA TIME WENT"
        printf "  %-8s %11s %11s %11s %9s  %s\n",
               "slot", "normal_ms", "slow_ms", "delta_ms", "share", "note"
        printf "  %-8s %11s %11s %11s %9s  %s\n",
               "--------", "-----------", "-----------", "-----------", "---------", "----"

        # print sorted by delta, descending, by repeated max scan (no asort in busybox)
        for (pass = 1; pass <= nslot; pass++) {
            bi = 0; bv = -1e18
            for (k = 1; k <= nslot; k++)
                if (!done[k] && d[k] > bv) { bv = d[k]; bi = k }
            done[bi] = 1
            if (d[bi] < 0.05 && nm[bi] < 0.05 && sm[bi] < 0.05) continue

            note = ""
            if (name[bi] == "mech") note = "DOUBLE COUNTED (engine+actors)"
            else if (name[bi] == "anim" || name[bi] == "phys" || name[bi] == "ai")
                note = "not instrumented"
            else if (ncalls[bi] == 0) note = "never called"

            printf "  %-8s %11.2f %11.2f %11.2f %8.0f%%  %s\n",
                   name[bi], nm[bi], sm[bi], d[bi],
                   (extra_total > 0 ? 100 * (d[bi] > 0 ? d[bi] : 0) / extra_total : 0),
                   note
        }

        # accounting: top-level slots only. char and spell nest inside mech,
        # and mech itself is counted twice, so halve it for the estimate.
        acc_n = nm[7]+nm[8]+nm[9]+nm[10]+nm[11]+nm[12]+nm[13] + nm[1]/2
        acc_s = sm[7]+sm[8]+sm[9]+sm[10]+sm[11]+sm[12]+sm[13] + sm[1]/2
        printf "\n  accounted (lua+world+gui+event+updt+render+sound + mech/2)\n"
        printf "    normal  %.1f of %.1f ms   unaccounted %.1f ms\n",
               acc_n, nsum/nn, nsum/nn - acc_n
        printf "    slow    %.1f of %.1f ms   unaccounted %.1f ms\n",
               acc_s, ssum/ns, ssum/ns - acc_s
        print  "    mech is halved because engine.cpp and actors.cpp both scope"
        print  "    into it and the second nests inside the first. char and spell"
        print  "    are inside mech and are excluded to avoid counting them twice."
        print  "    Large unaccounted time on slow frames means the cost is OUTSIDE"
        print  "    every instrumented scope - swap, sleep, or the frame limiter."

        print "\n  SLOWEST FRAMES  (frame total, then the three biggest slots)"
        for (i = 1; i <= top_n; i++) {
            split(top_l[i], fld, " ")
            b1 = 0; b2 = 0; b3 = 0
            for (k = 1; k <= nslot; k++) {
                v = fld[2 + k] + 0
                if (v > fld[2 + b1] + 0 || b1 == 0) { b3 = b2; b2 = b1; b1 = k }
                else if (b2 == 0 || v > fld[2 + b2] + 0) { b3 = b2; b2 = k }
                else if (b3 == 0 || v > fld[2 + b3] + 0) { b3 = k }
            }
            printf "    frame %-8s %8.1f ms   %s=%.1f  %s=%.1f  %s=%.1f\n",
                   fld[1], fld[2] + 0,
                   name[b1], fld[2 + b1] + 0,
                   name[b2], fld[2 + b2] + 0,
                   name[b3], fld[2 + b3] + 0
        }
        print ""
    }' "$TMP"
}

{
echo "=============================================================="
echo " TSP RING REPORT   $(date)"
echo " base: $BASE     slow factor: ${FACTOR}x median"
echo "=============================================================="
echo

found=0
for f in "$BASE" "$BASE".*; do
    [ -f "$f" ] || continue
    case "$f" in *tsp_ring_report.txt) continue ;; esac
    found=$((found + 1))
    analyse_one "$f"
done

if [ "$found" -eq 0 ]; then
    echo "  NO RING FILES AT ALL."
    echo
    echo "  Check the liveness line first - the profiler announces itself on"
    echo "  stderr on its very first frame, and the launcher appends stderr to"
    echo "  /mnt/SDCARD/tsp_prog.txt:"
    echo
    echo "      grep TSP_RING /mnt/SDCARD/tsp_prog.txt | tail -20"
    echo
    echo "  no TSP_RING_CONFIG line   -> the build does not have the V2 header,"
    echo "                               or the binary in bin/ is not that build"
    echo "  path=(OPENMW_TSP_RING unset) -> the launcher is not exporting it"
    echo "  CONFIG present, no ARM    -> no frame ever crossed trigger_ms;"
    echo "                               lower it and play again"
    echo "  ARM present, no DUMP      -> the game exited inside the countdown"
fi

echo "=============================================================="
echo " END"
echo "=============================================================="
} 2>&1 | tee "$OUT"

rm -f "$TMP"
echo
if [ -f "$OUT" ]; then echo "written: $OUT"; else echo "no copy written; the report above is all of it"; fi