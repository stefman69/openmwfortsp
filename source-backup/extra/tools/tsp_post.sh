#!/bin/sh
# TSP_POST_V1 - what happens in the seconds AFTER the spike.
#
# Steve: "the worst hitching seems to happen right after game loads."
#
# The other readers average a whole 900-frame dump, which hides a decay. This one
# finds the largest frame in each dump (the spike the ring armed on - a save load is
# 20+ seconds) and reports the frames after it in time buckets, so a cold-page-cache
# recovery shows up as a curve instead of a single average.
#
# usage: sh tsp_post.sh [dump ...]      no argument sweeps /mnt/SDCARD/tsp_ring.[0-9]*
#   TSP_BUCKET=5     seconds per bucket
#   TSP_SAVEMS=300   frames at or above this are loads, excluded from the buckets

BUCKET="${TSP_BUCKET:-5}"
SAVEMS="${TSP_SAVEMS:-300}"

if [ "$#" -eq 0 ]; then
    set -- /mnt/SDCARD/tsp_ring.[0-9]*
fi

for f in "$@"; do
    [ -f "$f" ] || continue
    if ! head -5 "$f" | grep -q "^# row: frame total"; then
        echo "NOT A TSPPROF DUMP, skipped: $f"
        continue
    fi
    echo "=================================================================="
    echo "$f"
    echo "=================================================================="
    awk -v bucket="$BUCKET" -v savems="$SAVEMS" '
    function slot(nm) { return sidx[nm] ? $(2 + sidx[nm]) + 0 : 0 }
    /^# nested:/ { for (i = 3; i <= NF; i++) nested[$i] = 1; next }
    /^# extra:/  { for (i = 3; i <= NF; i++) { ne++; ename[ne] = $i }; next }
    /^# frame /  { for (i = 4; i <= NF; i++) { ns++; sname[ns] = $i; sidx[$i] = ns }; next }
    /^#/ { next }
    NF < 6 { next }
    {
        b1 = 0; b2 = 0
        for (i = 1; i <= NF; i++) if ($i == "|") { if (!b1) b1 = i; else if (!b2) b2 = i }
        if (!b1 || !b2 || b1 - 3 != ns) next
        if ($1 == 0) next
        nr++
        fr[nr] = $1; tt[nr] = $2 + 0
        for (j = 1; j <= ne; j++) e[ename[j]] = $(b2 + j) + 0
        cp[nr] = e["cpu"]; mj[nr] = e["majflt"]; mn[nr] = e["minflt"]; td[nr] = e["tod_ms"]
        rn[nr] = slot("render"); me[nr] = slot("mech"); wo[nr] = slot("world")
        if (tt[nr] > peak) { peak = tt[nr]; pk = nr }
    }
    END {
        if (!nr) { print "no rows"; exit }
        if (!pk)  { print "no peak found"; exit }
        printf "spike: frame %s at %.1f ms   (row %d of %d)\n", fr[pk], tt[pk], pk, nr
        printf "bucket size %d s   frames at or above %d ms are treated as loads\n\n", bucket, savems

        # ---- baseline: rendered frames BEFORE the spike
        bn = 0; bt = 0; bmj = 0; bf = 0; blo = 0; bhi = 0
        for (i = 1; i < pk; i++) {
            if (tt[i] < 1.0 || tt[i] >= savems) continue
            bn++; bt += tt[i]; bmj += mj[i]; if (mj[i] > 0) bf++
            if (!blo || td[i] < blo) blo = td[i]
            if (td[i] > bhi) bhi = td[i]
        }
        if (bn > 1) {
            bs = bt / 1000.0
            printf "BEFORE the spike: %d frames  mean %.1f ms (%.1f fps)  majflt %d = %.1f/s  faulting %.1f%%\n\n",
                   bn, bt / bn, 1000.0 * bn / bt, bmj, bmj / bs, 100.0 * bf / bn
        } else {
            print "BEFORE the spike: too few frames to summarise\n"
        }

        # ---- after the spike, in time buckets
        t0 = td[pk]
        nb = 0
        for (i = pk + 1; i <= nr; i++) {
            if (tt[i] < 1.0 || tt[i] >= savems) continue
            b = int((td[i] - t0) / (bucket * 1000.0))
            if (b < 0) b = 0
            if (b > nb) nb = b
            cnt[b]++; sum[b] += tt[i]; mjs[b] += mj[i]; mns[b] += mn[i]
            if (mj[i] > 0) flt[b]++
            rs[b] += rn[i]; ms[b] += me[i]; ws[b] += wo[i]
            cs[b] += cp[i]
            if (tt[i] > wst[b]) wst[b] = tt[i]
        }
        if (!cnt[0] && nb == 0) { print "AFTER the spike: nothing captured"; exit }

        print "AFTER the spike, by elapsed time"
        printf "%9s %7s %8s %7s %9s %9s %9s %8s %8s %8s\n",
               "since", "frames", "mean ms", "fps", "majflt/s", "faulting", "worst ms", "render", "mech", "cpu"
        for (b = 0; b <= nb; b++) {
            if (!cnt[b]) continue
            secs = sum[b] / 1000.0
            printf "%4d-%-4d %7d %8.1f %7.1f %9.1f %8.1f%% %9.1f %8.2f %8.2f %8.2f\n",
                   b * bucket, (b + 1) * bucket, cnt[b], sum[b] / cnt[b], 1000.0 * cnt[b] / sum[b],
                   (secs > 0 ? mjs[b] / secs : 0), 100.0 * flt[b] / cnt[b], wst[b],
                   rs[b] / cnt[b], ms[b] / cnt[b], cs[b] / cnt[b]
        }
        print ""

        # ---- is it decaying
        # A bucket with a handful of frames is noise - one 78 ms frame in a 1-frame
        # bucket read as "RISING" on a capture that was plainly decaying. Only buckets
        # with MINB frames are used for the shape call.
        MINB = 20
        f0 = 0; l0 = 0; nfirst = 0; used = 0
        for (b = 0; b <= nb; b++) {
            if (cnt[b] < MINB) continue
            used++
            if (!nfirst) { nfirst = 1; s0 = sum[b] / 1000.0; f0 = (s0 > 0) ? mjs[b] / s0 : 0; m0 = sum[b] / cnt[b] }
            sl = sum[b] / 1000.0; l0 = (sl > 0) ? mjs[b] / sl : 0; ml = sum[b] / cnt[b]
        }
        if (used < 2) {
            printf "only %d bucket(s) with >= %d frames - too short to call a shape.\n", used, MINB
            print "The ring keeps 225 frames after the trigger, which at 40 ms is about 9 s,"
            print "so a single load cannot show a longer decay. Compare ACROSS dumps instead."
            exit
        }
        printf "first bucket %.1f majflt/s at %.1f ms   ->   last bucket %.1f majflt/s at %.1f ms\n",
               f0, m0, l0, ml
        if (f0 > 2 && l0 < f0 * 0.6)
            print "DECAYING. The fault rate falls as the capture goes on, which is a cold page"
        else if (f0 > 2 && l0 > f0 * 1.4)
            print "RISING. The fault rate climbs through the capture - not a cache warming up."
        else if (f0 > 2)
            print "FLAT and faulting. A steady fault rate, not a warm-up transient."
        else
            print "LOW fault rate throughout. Whatever this spike was, it is not paging."
        if (f0 > 2 && l0 < f0 * 0.6)
            print "cache refilling after the spike evicted the working set. The cost is bounded"
        if (f0 > 2 && l0 < f0 * 0.6)
            print "and self-limiting, and prefetching the working set would remove it."
    }' "$f"
    echo
done
