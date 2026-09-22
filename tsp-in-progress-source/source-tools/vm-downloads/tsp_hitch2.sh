#!/bin/sh
# TSP_HITCH_READER_V3B - the aggregate across every dump.
#
# Reader v1 reports per dump. This one answers the two questions that decided the
# readahead fix: what share of frames take a major fault, and what share of total
# frame time those frames hold. Frames at or above TSP_HITCH_SAVEMS are save/load
# and are reported separately rather than counted as hitches.
#
# It also breaks the slot means down by frame class, because a slot that is large
# only on faulting frames means something different from one that is large always.
#
# usage: sh tsp_hitch2.sh [dump ...]    no argument sweeps /mnt/SDCARD/tsp_ring.*

SAVEMS="${TSP_HITCH_SAVEMS:-300}"

if [ "$#" -eq 0 ]; then
    set -- /mnt/SDCARD/tsp_ring.[0-9]*
fi

FOUND=0
KEEP=""
for f in "$@"; do
    [ -f "$f" ] || continue
    if head -5 "$f" | grep -q "^# row: frame total"; then
        KEEP="$KEEP $f"; FOUND=$((FOUND + 1))
    else
        echo "NOT A TSPPROF DUMP, skipped: $f"
    fi
done
if [ "$FOUND" -eq 0 ]; then
    echo "FAILED CAPTURE: no tspprof dumps to aggregate."
    echo "  Either nothing crossed the trigger, the dump slots were already full"
    echo "  (OPENMW_TSP_RING_MAX_DUMPS), or the profiler was off. Check:"
    echo "    ls /mnt/SDCARD/tsp_ring.[0-9]*   cat /mnt/SDCARD/tsp_ring.conf"
    echo "    ls /mnt/SDCARD/tsp_ring_off*     grep TSP_RING /mnt/SDCARD/tsp_prog.txt"
    exit 1
fi
echo "aggregating $FOUND dump(s)"
echo
set -- $KEEP

awk -v savems="$SAVEMS" '
FNR == 1 { ns = 0; ne = 0; nd++ }
/^# nested:/ { for (i = 3; i <= NF; i++) nested[$i] = 1; next }
/^# extra:/  { for (i = 3; i <= NF; i++) { ne++; ename[ne] = $i }; next }
/^# frame /  { for (i = 4; i <= NF; i++) { ns++; sname[ns] = $i; allslot[$i] = 1 }; next }
/^#/ { next }
NF < 6 { next }
{
    b1 = 0; b2 = 0
    for (i = 1; i <= NF; i++) if ($i == "|") { if (!b1) b1 = i; else if (!b2) b2 = i }
    if (!b1 || !b2 || b1 - 3 != ns) { skipped++; next }
    if ($1 == 0) next

    total = $2 + 0
    for (j = 1; j <= ne; j++) e[ename[j]] = $(b2 + j) + 0
    cpu = e["cpu"]; mjf = e["majflt"]; mnf = e["minflt"]; tod = e["tod_ms"]

    if (total >= savems) { sv++; svtime += total; svmnf += mnf; svmjf += mjf; next }

    g++; gtime += total; gmjf += mjf; gmnf += mnf; gcpu += cpu
    if (span_lo[FILENAME] == 0 || tod < span_lo[FILENAME]) span_lo[FILENAME] = tod
    if (tod > span_hi[FILENAME]) span_hi[FILENAME] = tod

    # Rows under 1 ms are not rendered frames; everything below is per rendered frame.
    if (total < 1.0) { subms++; next }
    rf++; rtime += total

    cls = (mjf > 0) ? "fault" : "clean"
    cn[cls]++; ct[cls] += total
    for (j = 1; j <= ns; j++) {
        nm = sname[j]; if (nm in nested) continue
        v = $(2 + j) + 0
        sl[cls, nm] += v; slall[nm] += v
    }
    if (mjf > mjfmax) mjfmax = mjf
}
END {
    if (skipped) printf "!! %d rows skipped as malformed or header-mismatched\n\n", skipped
    if (!g) { print "no gameplay frames"; exit }

    # Accounted gameplay time, not the tod range: the range spans the excluded
    # save/load frames, which inflated one dump fault rate by 4.6x.
    span = gtime / 1000.0
    todspan = 0
    for (k in span_hi) todspan += (span_hi[k] - span_lo[k]) / 1000.0

    print "=== gameplay totals (save/load excluded) ==="
    printf "dumps %d   rows %d   accounted %.1f s   tod span %.1f s   mean %.1f ms/row   mean cpu %.1f ms\n",
           nd, g, span, todspan, gtime / g, gcpu / g
    printf "sub-millisecond rows %d (%.1f%%)   rows >= 1 ms %d\n", subms, 100.0 * subms / g, rf
    if (rf > 0)
        printf "REAL FRAME ESTIMATE: %.1f ms = %.1f fps  (treating sub-ms rows as sub-frame boundaries)\n",
               gtime / rf, (gtime > 0) ? 1000.0 * rf / gtime : 0
    if (sv) printf "save/load: %d frames, %.1f s, %d minflt, %d majflt (reported, not counted)\n",
                   sv, svtime / 1000.0, svmnf, svmjf
    print ""

    print "=== the major-fault correlation ==="
    printf "major faults %d over %.1f s = %.1f/s   worst single frame %d   minor faults %d\n",
           gmjf, span, (span > 0) ? gmjf / span : 0, mjfmax, gmnf
    if (cn["fault"] > 0 && cn["clean"] > 0) {
        fm = ct["fault"] / cn["fault"]; cm = ct["clean"] / cn["clean"]
        printf "%-22s %8d frames  %6.2f%% of rendered  mean %8.2f ms\n", "take a major fault", cn["fault"], 100.0 * cn["fault"] / rf, fm
        printf "%-22s %8d frames  %6.2f%% of rendered  mean %8.2f ms\n", "clean", cn["clean"], 100.0 * cn["clean"] / rf, cm
        printf "a faulting frame is %.2fx slower and faulting frames hold %.2f%% of all frame time\n",
               (cm > 0) ? fm / cm : 0, 100.0 * ct["fault"] / rtime
    } else if (cn["fault"] > 0) {
        print "every gameplay frame took a major fault"
    } else {
        print "NO major faults on any gameplay frame - this is not an SD/memory hitch"
    }
    print ""

    print "=== mean ms per slot, split by frame class ==="
    printf "%-9s %10s %10s %10s\n", "slot", "all", "faulting", "clean"
    for (si = 1; si <= ns; si++) {
        nm = sname[si]
        if (nm in nested) continue
        a = slall[nm] / rf
        if (a < 0.05) continue
        fv = (cn["fault"] > 0) ? sl["fault", nm] / cn["fault"] : 0
        cv = (cn["clean"] > 0) ? sl["clean", nm] / cn["clean"] : 0
        printf "%-9s %10.2f %10.2f %10.2f\n", nm, a, fv, cv
    }
    print ""
    print "reading it: a slot large in BOTH columns is baseline scene cost (view distance,"
    print "draw-call count). A slot large only in the faulting column is I/O or memory."
}' "$@"
