#!/bin/sh
# TSP_VSYNC_V1 - is the judder vsync quantisation, or real stalls?
#
# The question this answers: on a 60 Hz panel every frame costs a whole number of
# vblanks. If render lands just over the 2-vblank budget (33.3 ms) the frame costs 3
# (50.0 ms) instead, and the framerate flips between 30 and 20 with nothing actually
# stalling. That reads as constant hitching and no page fault or CPU spike explains it.
#
# So: bucket every rendered frame by how close it sits to k * (1000/Hz), report the
# distribution of k, and separate frames that were WAITING (blocked, no faults, main
# thread idle) from frames that were WORKING or FAULTING.
#
# usage: sh tsp_vsync.sh [dump ...]      no argument sweeps /mnt/SDCARD/tsp_ring.[0-9]*
#   TSP_HZ=60        panel refresh used for the vblank period
#   TSP_TOL=2.5      ms tolerance for calling a frame "aligned" to a vblank multiple
#   TSP_SAVEMS=300   frames at or above this are save/load and are excluded

HZ="${TSP_HZ:-60}"
TOL="${TSP_TOL:-2.5}"
SAVEMS="${TSP_SAVEMS:-300}"

if [ "$#" -eq 0 ]; then
    set -- /mnt/SDCARD/tsp_ring.[0-9]*
fi

KEEP=""
FOUND=0
for f in "$@"; do
    [ -f "$f" ] || continue
    if head -5 "$f" | grep -q "^# row: frame total"; then
        KEEP="$KEEP $f"; FOUND=$((FOUND + 1))
    else
        echo "NOT A TSPPROF DUMP, skipped: $f"
    fi
done
if [ "$FOUND" -eq 0 ]; then
    echo "no tspprof dumps to read"
    exit 1
fi
echo "vblank analysis over $FOUND dump(s) at ${HZ} Hz (period $(awk -v h="$HZ" 'BEGIN{printf "%.2f", 1000/h}') ms, tolerance ${TOL} ms)"
echo
set -- $KEEP

awk -v hz="$HZ" -v tol="$TOL" -v savems="$SAVEMS" '
FNR == 1 { ns = 0; ne = 0; nd++ }
/^# nested:/ { for (i = 3; i <= NF; i++) nested[$i] = 1; next }
/^# extra:/  { for (i = 3; i <= NF; i++) { ne++; ename[ne] = $i }; next }
/^# frame /  { for (i = 4; i <= NF; i++) { ns++; sname[ns] = $i }; next }
/^#/ { next }
NF < 6 { next }
{
    b1 = 0; b2 = 0
    for (i = 1; i <= NF; i++) if ($i == "|") { if (!b1) b1 = i; else if (!b2) b2 = i }
    if (!b1 || !b2 || b1 - 3 != ns) { skipped++; next }
    if ($1 == 0) next

    total = $2 + 0
    if (total >= savems) next
    if (total < 1.0) next            # sub-frame row, not a rendered frame

    for (j = 1; j <= ne; j++) e[ename[j]] = $(b2 + j) + 0
    cpu = e["cpu"]; pcpu = e["pcpu"]; mjf = e["majflt"]
    other = pcpu - cpu; if (other < 0) other = 0
    blocked = total - cpu; if (blocked < 0) blocked = 0

    n++; sumtotal += total; sumcpu += cpu; sumblocked += blocked

    # which vblank multiple is this frame nearest to
    p = 1000.0 / hz
    k = int(total / p + 0.5)
    if (k < 1) k = 1
    d = total - k * p
    ad = (d < 0) ? -d : d
    kn[k]++
    ktime[k] += total
    if (ad <= tol) { aligned++; kna[k]++ } else { unaligned++ }

    # 5 ms histogram
    h = int(total / 5)
    if (h > 20) h = 20
    hist[h]++

    # what kind of frame is it
    if (mjf >= 5)                            cls = "fault"
    else if (cpu >= 0.70 * total)             cls = "cpu"
    else if (blocked >= 8.0 && other < blocked && mjf == 0) cls = "wait"
    else                                      cls = "mixed"
    cn[cls]++; ct[cls] += total; cb[cls] += blocked; cc[cls] += cpu
    if (cls == "wait" && ad <= tol && k >= 2) waitaligned++
}
END {
    if (skipped) printf "!! %d rows skipped as malformed\n\n", skipped
    if (!n) { print "no rendered frames"; exit }
    p = 1000.0 / hz

    printf "rendered frames %d   mean %.2f ms (%.1f fps)   mean cpu %.2f   mean blocked %.2f\n\n",
           n, sumtotal / n, 1000.0 * n / sumtotal, sumcpu / n, sumblocked / n

    print "=== frame time histogram (5 ms buckets) ==="
    for (i = 0; i <= 20; i++) {
        if (!(i in hist)) continue
        lo = i * 5; hi = lo + 5
        mark = ""
        for (kk = 1; kk <= 6; kk++) { v = kk * p; if (v >= lo && v < hi) mark = mark sprintf("  <- %dx vblank = %.1f ms", kk, v) }
        bar = ""
        w = int(60.0 * hist[i] / n + 0.5)
        for (j = 0; j < w; j++) bar = bar "#"
        printf "  %3d-%3d ms %6d %5.1f%% %-61s%s\n", lo, (i == 20 ? 999 : hi), hist[i], 100.0 * hist[i] / n, bar, mark
    }
    print ""

    print "=== vblank alignment ==="
    printf "within %.1f ms of a vblank multiple: %d of %d = %.1f%%   (off-grid %.1f%%)\n",
           tol, aligned, n, 100.0 * aligned / n, 100.0 * unaligned / n
    print "  k   ideal ms   frames    share   aligned   mean ms"
    for (k = 1; k <= 8; k++) {
        if (!(k in kn)) continue
        printf "  %d   %8.1f %8d %7.1f%% %8d %9.2f\n",
               k, k * p, kn[k], 100.0 * kn[k] / n, kna[k] + 0, ktime[k] / kn[k]
    }
    print ""

    print "=== what those frames were doing ==="
    printf "%-8s %8s %7s %10s %10s\n", "class", "frames", "share", "mean ms", "mean blocked"
    split("fault cpu wait mixed", order, " ")
    for (i = 1; i <= 4; i++) {
        c = order[i]
        if (!(c in cn)) continue
        printf "%-8s %8d %6.1f%% %10.2f %10.2f\n", c, cn[c], 100.0 * cn[c] / n, ct[c] / cn[c], cb[c] / cn[c]
    }
    print ""
    print "  fault = majflt >= 5, SD/memory"
    print "  cpu   = main thread burned >= 70% of the frame, real work"
    print "  wait  = blocked >= 8 ms, no major faults, no other thread busier than the"
    print "          block. Nothing was stalling and nothing was computing: a vsync wait."
    print "  mixed = none of the above cleanly"
    printf "\n  of the 'wait' frames, %d sat on a vblank multiple of 2 or more\n", waitaligned + 0

    print ""
    print "=== verdict ==="
    dom = 0; domk = 0
    for (k = 1; k <= 8; k++) if (k in kn && kn[k] > dom) { dom = kn[k]; domk = k }
    printf "modal frame is %dx vblank (%.1f ms, %.1f fps) holding %.1f%% of frames\n",
           domk, domk * p, 1000.0 / (domk * p), 100.0 * dom / n
    if (100.0 * aligned / n >= 60.0 && domk >= 2) {
        print "VSYNC-QUANTISED. Most frames land on a vblank multiple, so frame time is"
        print "stepping between whole vblanks rather than varying smoothly. Shaving render"
        print "cost below the next lower multiple is worth a whole step; shaving less than"
        print "that is worth nothing at all."
        printf "  to reach %dx vblank (%.1f ms, %.1f fps) the frame must lose %.1f ms\n",
               domk - 1, (domk - 1) * p, 1000.0 / ((domk - 1) * p), sumtotal / n - (domk - 1) * p
    } else if (100.0 * aligned / n < 35.0) {
        print "NOT vsync-quantised. Frame times are off-grid, so the cost is real work or"
        print "real stalls; read the class table above."
    } else {
        print "MIXED. Some frames are on the vblank grid and some are not. Compare the"
        print "class table: a large 'wait' share with a large aligned share is vsync."
    }
}' "$@"
