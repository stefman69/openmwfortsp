#!/bin/sh
# tsp_ring_report_v3.sh - read tspprof v3 ring dumps and name the cost
#
# Reads /mnt/SDCARD/tsp_ring.txt and every triggered dump beside it
# (.1, .2, ...). Prints a summary small enough to paste.
#
# v3 changes:
#   - slot names are read from the dump's own "# frame total ..." header, so
#     adding a slot in tspprof.h needs no change here
#   - nested slots are read from the "# nested:" line and excluded from the
#     accounting sum instead of the old mech/2 fudge
#   - a frame-length HISTOGRAM, because mean-below-median in the v2 reports
#     implied a large population of very short frames and that needed settling
#   - each slot's worst single frame is shown next to its mean, and flagged
#     when one frame carries most of the slot's slow-frame total. In the v2
#     data lua showed 40 ms mean on slow frames and 97% of it was ONE frame.
#
# USAGE (on the device)
#     sh /mnt/SDCARD/tsp_ring_report_v3.sh
#     sh /mnt/SDCARD/tsp_ring_report_v3.sh /path/to/some_ring.txt
#
# Env:
#     TSP_SLOW_FACTOR   slow = above this multiple of the median. default 2.0

BASE="${1:-/mnt/SDCARD/tsp_ring.txt}"
OUT="${TSP_RING_REPORT_OUT:-/mnt/SDCARD/tsp_ring_report.txt}"
FACTOR="${TSP_SLOW_FACTOR:-2.0}"
TMP="${TMPDIR:-/tmp}/tsp_ring3.$$"

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
        echo "  only $n frames - not enough to say anything."
        echo
        return
    fi

    # drop phantom records (zero elapsed, zero calls) before the percentiles
    nslotf=$(awk '/^# frame total/{print NF-3; exit}' "$f")
    awk -v ns="$nslotf" '{ c=0; for (k=1;k<=ns;k++) c+=$(3+ns+k);
                           if (!($2+0 <= 0.001 && c == 0)) print $2 }' "$TMP" \
        | sort -n > "$TMP.tot"
    nreal=$(wc -l < "$TMP.tot")
    if [ "${nreal:-0}" -lt 20 ]; then
        echo "  only $nreal real frames after dropping phantoms - not enough."
        echo
        return
    fi
    med=$(awk -v n="$nreal" 'NR == int(n/2)+1 {print; exit}' "$TMP.tot")
    p95=$(awk -v n="$nreal" 'NR == int(n*0.95) {print; exit}' "$TMP.tot")

    awk -v med="$med" -v p95="$p95" -v factor="$FACTOR" -v file="$f" '
    BEGIN { thr = med * factor; if (thr < med + 10) thr = med + 10 }

    /^# frame total/ {
        # fields: # frame total <name1> <name2> ...
        nslot = NF - 3
        for (k = 1; k <= nslot; k++) name[k] = $(k + 3)
        next
    }
    /^# nested:/ { for (k = 2; k <= NF; k++) isnested[$k] = 1; next }
    /^#/ { next }

    {
        tot = $2

        # A record with zero elapsed time AND zero calls in every slot is not
        # a frame - it is a second endFrame() firing with nothing accumulated.
        # Measured on device: these alternate 1:1 with real frames, so leaving
        # them in halves every mean and doubles the apparent frame rate.
        anycalls = 0
        for (k = 1; k <= nslot; k++) anycalls += $(3 + nslot + k)
        if (tot <= 0.001 && anycalls == 0) { phantom++; next }

        n++

        # histogram - settles whether there is a population of near-zero frames
        if      (tot <   5) h1++
        else if (tot <  10) h2++
        else if (tot <  20) h3++
        else if (tot <  30) h4++
        else if (tot <  40) h5++
        else if (tot <  60) h6++
        else if (tot < 100) h7++
        else if (tot < 300) h8++
        else                h9++

        if (max == "" || tot > max) { max = tot; maxframe = $1 }

        slow = (tot >= thr)
        if (slow) { ns++; ssum += tot } else { nn++; nsum += tot }

        for (k = 1; k <= nslot; k++) {
            v = $(2 + k) + 0
            if (slow) {
                sslot[k] += v
                if (v > worst[k]) { worst[k] = v; worstf[k] = $1 }
            } else nslotsum[k] += v
            calls[k] += $(3 + nslot + k)
        }

        if (top_n < 8 || tot > top_v[top_n]) {
            i = (top_n < 8) ? ++top_n : 8
            while (i > 1 && top_v[i-1] < tot) {
                top_v[i] = top_v[i-1]; top_l[i] = top_l[i-1]; i--
            }
            top_v[i] = tot; top_l[i] = $0
        }
    }
    END {
        if (nslot == 0) {
            print "\n  Could not read the slot names from this file - is it a v3 dump?"
            print "  Expected a line starting: # frame total input sound lua ..."
            exit
        }

        printf "\n  frames %d   median %.1f ms (%.0f fps)   p95 %.1f ms   max %.1f ms at frame %s\n",
               n, med, (med > 0 ? 1000/med : 0), p95, max, maxframe
        if (phantom > 0)
            printf "  DROPPED %d phantom records (zero elapsed, zero calls) - a second\n          endFrame() firing with nothing accumulated. Not real frames.\n", phantom

        print "\n  FRAME LENGTH HISTOGRAM"
        printf "    %-12s %6d  %4.0f%%\n", "< 5 ms",     h1+0, 100*(h1+0)/n
        printf "    %-12s %6d  %4.0f%%\n", "5 - 10 ms",  h2+0, 100*(h2+0)/n
        printf "    %-12s %6d  %4.0f%%\n", "10 - 20 ms", h3+0, 100*(h3+0)/n
        printf "    %-12s %6d  %4.0f%%\n", "20 - 30 ms", h4+0, 100*(h4+0)/n
        printf "    %-12s %6d  %4.0f%%\n", "30 - 40 ms", h5+0, 100*(h5+0)/n
        printf "    %-12s %6d  %4.0f%%\n", "40 - 60 ms", h6+0, 100*(h6+0)/n
        printf "    %-12s %6d  %4.0f%%\n", "60 - 100 ms",h7+0, 100*(h7+0)/n
        printf "    %-12s %6d  %4.0f%%\n", "100 - 300 ms",h8+0, 100*(h8+0)/n
        printf "    %-12s %6d  %4.0f%%\n", "> 300 ms",   h9+0, 100*(h9+0)/n
        if ((h1+h2)/n > 0.25)
            print "    NOTE a large share of frames are under 10 ms. Either the loop\n         genuinely idles, or endFrame is firing more than once per frame."

        printf "\n  slow threshold %.1f ms  ->  %d slow, %d normal\n", thr, ns+0, nn+0
        if (ns == 0) {
            print "\n  Nothing crossed the threshold in this dump. Lower TSP_SLOW_FACTOR,\n  or lower OPENMW_TSP_RING_TRIGGER_MS and capture again."
            print ""
            exit
        }
        printf "  mean frame:  normal %.1f ms   slow %.1f ms   (+%.1f ms)\n",
               nsum/nn, ssum/ns, ssum/ns - nsum/nn

        extra_total = 0
        for (k = 1; k <= nslot; k++) {
            nm[k] = (nn > 0) ? nslotsum[k]/nn : 0
            sm[k] = sslot[k]/ns
            d[k]  = sm[k] - nm[k]
            if (d[k] > 0) extra_total += d[k]
        }

        print "\n  WHERE THE EXTRA TIME WENT"
        printf "  %-8s %10s %10s %10s %7s %11s  %s\n",
               "slot", "normal_ms", "slow_ms", "delta_ms", "share", "worst_frame", "note"
        printf "  %-8s %10s %10s %10s %7s %11s  %s\n",
               "--------", "----------", "----------", "----------",
               "-------", "-----------", "----"

        for (pass = 1; pass <= nslot; pass++) {
            bi = 0; bv = -1e18
            for (k = 1; k <= nslot; k++)
                if (!done[k] && d[k] > bv) { bv = d[k]; bi = k }
            done[bi] = 1
            if (d[bi] < 0.05 && nm[bi] < 0.05 && sm[bi] < 0.05) continue

            note = ""
            if (isnested[name[bi]]) note = "nested - not in the sum"
            else if (calls[bi] == 0) note = "NEVER CALLED"
            # only meaningful with enough slow frames for that to be a claim
            if (ns >= 4 && sslot[bi] > 0 && worst[bi] / sslot[bi] > 0.5)
                note = note (note ? "; " : "") \
                       sprintf("%.0f%% of this is frame %s alone", 100*worst[bi]/sslot[bi], worstf[bi])

            printf "  %-8s %10.2f %10.2f %10.2f %6.0f%% %11.1f  %s\n",
                   name[bi], nm[bi], sm[bi], d[bi],
                   (extra_total > 0 ? 100 * (d[bi] > 0 ? d[bi] : 0) / extra_total : 0),
                   worst[bi]+0, note
        }

        acc_n = 0; acc_s = 0
        for (k = 1; k <= nslot; k++)
            if (!isnested[name[k]]) { acc_n += nm[k]; acc_s += sm[k] }
        printf "\n  ACCOUNTING  (top-level slots only; nested ones excluded)\n"
        printf "    normal  %.1f accounted of %.1f ms   unaccounted %.1f ms\n",
               acc_n, nsum/nn, nsum/nn - acc_n
        printf "    slow    %.1f accounted of %.1f ms   unaccounted %.1f ms\n",
               acc_s, ssum/ns, ssum/ns - acc_s
        print  "    Unaccounted time is outside Engine::frame entirely - the frame"
        print  "    rate limiter (engine.cpp:1380), mViewer->advance (1349), or the"
        print  "    loop condition. If it is large, that is the next place to look."

        print "\n  SLOWEST FRAMES  (total, then the three biggest slots)"
        for (i = 1; i <= top_n; i++) {
            nf = split(top_l[i], fld, " ")
            # three DISTINCT slots by repeated max scan - the previous
            # comparison chain could name the same slot twice (mech=2.6 mech=2.6)
            for (k = 1; k <= nslot; k++) used[k] = 0
            b1 = 0; b2 = 0; b3 = 0
            for (rank = 1; rank <= 3; rank++) {
                bi = 0; bv = -1e18
                for (k = 1; k <= nslot; k++) {
                    if (used[k]) continue
                    v = fld[2 + k] + 0
                    if (v > bv) { bv = v; bi = k }
                }
                if (bi == 0) continue
                used[bi] = 1
                if (rank == 1) b1 = bi; else if (rank == 2) b2 = bi; else b3 = bi
            }
            if (b1 == 0) b1 = 1
            if (b2 == 0) b2 = b1
            if (b3 == 0) b3 = b2
            printf "    frame %-8s %9.1f ms   %s=%.1f  %s=%.1f  %s=%.1f\n",
                   fld[1], fld[2] + 0,
                   name[b1], fld[2 + b1] + 0,
                   name[b2], fld[2 + b2] + 0,
                   name[b3], fld[2 + b3] + 0
        }
        print ""
    }' "$f"
}

{
echo "=============================================================="
echo " TSP RING REPORT v3   $(date)"
echo " base: $BASE     slow factor: ${FACTOR}x median"
echo "=============================================================="
echo

found=0
for f in "$BASE" "$BASE".*; do
    [ -f "$f" ] || continue
    case "$f" in *_report.txt) continue ;; esac
    found=$((found + 1))
    analyse_one "$f"
done

if [ "$found" -eq 0 ]; then
    echo "  NO RING FILES AT ALL."
    echo
    echo "  The profiler announces itself on stderr on its first frame and the"
    echo "  launcher appends stderr to /mnt/SDCARD/tsp_prog.txt:"
    echo
    echo "      grep TSP_RING /mnt/SDCARD/tsp_prog.txt | tail -20"
    echo
    echo "  no TSP_RING_CONFIG line      -> binary in bin/ is not the new build"
    echo "  path=(OPENMW_TSP_RING unset) -> launcher is not exporting it"
    echo "  CONFIG but no ARM            -> nothing crossed trigger_ms"
    echo "  ARM but no DUMP              -> quit inside the 225-frame countdown"
fi

echo "=============================================================="
echo " END"
echo "=============================================================="
} 2>&1 | tee "$OUT"

rm -f "$TMP" "$TMP.tot"
echo
if [ -f "$OUT" ]; then echo "written: $OUT"; else echo "no copy written; the report above is all of it"; fi