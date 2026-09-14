#!/bin/sh
# tsp_purge_report.sh - summarise the TSP_PURGE timing lines from openmw.log
#
# Prints a compact report and writes the same thing to
# /mnt/SDCARD/tsp_purge_report.txt. Nothing here is large enough to be a
# problem to paste - that is the whole point of it.
#
# Reads:  $GAMEDIR/config-0.51/openmw.log   (truncated per launch)
#         $GAMEDIR/openmw51_perf_latest.txt (launcher telemetry, for context)
#
# Usage on the device:
#     sh /mnt/SDCARD/tsp_purge_report.sh
#
# Optional first argument: a different log path (e.g. a copy you kept aside).

GAMEDIR="${GAMEDIR:-/mnt/SDCARD/data/ports/openmw51}"
LOG="${1:-$GAMEDIR/config-0.51/openmw.log}"
PERF="$GAMEDIR/openmw51_perf_latest.txt"
OUT="${TSP_REPORT_OUT:-/mnt/SDCARD/tsp_purge_report.txt}"
# fall back to the log's own directory if /mnt/SDCARD is not writable
if ! : > "$OUT" 2>/dev/null; then OUT="$(dirname "$LOG")/tsp_purge_report.txt"; fi

# BusyBox grep does not always have -a. Find out rather than assume.
GA="-a"
echo x | grep -a x >/dev/null 2>&1 || GA=""

{
echo "=============================================================="
echo " TSP PURGE REPORT   $(date)"
echo " log: $LOG"
echo "=============================================================="
echo

if [ ! -f "$LOG" ]; then
    echo "  MISSING: $LOG"
    echo "  openmw.log is truncated on every launch. If the game has been"
    echo "  relaunched since the run you care about, that run is gone."
    exit 1
fi

echo "  log size: $(wc -c < "$LOG") bytes, $(wc -l < "$LOG") lines"
echo

echo "--------------------------------------------------------------"
echo " 1. DID THE PATCH LOAD?   (these three MUST be here)"
echo "--------------------------------------------------------------"
n_cfg=$(grep $GA -c -E "TSP_PURGE_CONFIG|TSP_CELL_GLRELEASE_CONFIG" "$LOG" 2>/dev/null)
if [ "${n_cfg:-0}" -eq 0 ]; then
    echo "  NONE FOUND."
    echo "  Either the binary in \$GAMEDIR/bin/ is not the one that was built,"
    echo "  or the log level is filtering Warning - check with:"
    echo "      grep -a -c TSP_PURGE_CONFIG \$GAMEDIR/bin/openmw-0.51"
else
    grep $GA -E "TSP_PURGE_CONFIG|TSP_CELL_GLRELEASE_CONFIG" "$LOG" | sed 's/^/  /'
fi
echo

echo "--------------------------------------------------------------"
echo " 2. PURGE EVENTS - how many, how long, how bad"
echo "--------------------------------------------------------------"
grep $GA -E "TSP_PURGE |TSP_CELL_GLRELEASE action=" "$LOG" 2>/dev/null | awk '
function key_of(line,   k) {
    if (line ~ /TSP_PURGE updateCache/)      return "updateCache"
    if (line ~ /TSP_PURGE malloc_trim/)      return "malloc_trim"
    if (line ~ /TSP_PURGE clearCache/)       return "clearCache"
    if (line ~ /TSP_PURGE releaseGLObjects/) return "releaseGLObjects"
    if (line ~ /TSP_CELL_GLRELEASE action=released/) return "cellGLRelease"
    if (line ~ /TSP_CELL_GLRELEASE action=skipped/)  return "cellGLSkipped"
    return ""
}
function ms_of(line,   p, v) {
    p = index(line, "ms=")
    if (p == 0) return -1
    v = substr(line, p + 3)
    return v + 0
}
{
    k = key_of($0)
    if (k == "") next
    if (!(k in n)) nkeys++
    n[k]++
    if (k == "cellGLSkipped") next

    v = ms_of($0)
    if (v < 0) next
    sum[k] += v
    if (!(k in mn) || v < mn[k]) mn[k] = v
    if (!(k in mx) || v > mx[k]) { mx[k] = v; mxline[k] = $0 }
    if (v >= 16.0) over16[k]++
    if (v >= 33.0) over33[k]++
    if (v >= 100.0) over100[k]++

    # keep the 8 slowest lines overall
    if (top_n < 8 || v > top_v[top_n]) {
        i = (top_n < 8) ? ++top_n : 8
        while (i > 1 && top_v[i-1] < v) { top_v[i] = top_v[i-1]; top_l[i] = top_l[i-1]; i-- }
        top_v[i] = v; top_l[i] = $0
    }
}
END {
    if (nkeys == 0) {
        print "  NO PURGE EVENTS AT ALL."
        print "  Expected at minimum some TSP_CELL_GLRELEASE action=skipped lines"
        print "  after any cell change. If there are none, the hook did not run."
        exit
    }
    printf "  %-17s %7s %10s %9s %9s %9s   %6s %6s %6s\n",
           "event", "count", "total_ms", "min_ms", "mean_ms", "MAX_ms",
           ">16ms", ">33ms", ">100ms"
    printf "  %-17s %7s %10s %9s %9s %9s   %6s %6s %6s\n",
           "-----------------", "-------", "----------", "---------",
           "---------", "---------", "------", "------", "------"
    order = "updateCache malloc_trim clearCache releaseGLObjects cellGLRelease cellGLSkipped"
    split(order, ord, " ")
    for (i = 1; i <= 6; i++) {
        k = ord[i]
        if (!(k in n)) continue
        if (k == "cellGLSkipped") {
            printf "  %-17s %7d %10s %9s %9s %9s   %6s %6s %6s\n",
                   k, n[k], "-", "-", "-", "-", "-", "-", "-"
            continue
        }
        printf "  %-17s %7d %10.1f %9.2f %9.2f %9.2f   %6d %6d %6d\n",
               k, n[k], sum[k], mn[k], sum[k]/n[k], mx[k],
               over16[k]+0, over33[k]+0, over100[k]+0
    }
    print ""
    print "  A 25 fps frame is 40 ms. Anything in the >33ms column dropped a"
    print "  frame on its own; anything in >100ms is a visible hitch."
    print ""
    print "  --- slowest individual events ---"
    for (i = 1; i <= top_n; i++) printf "  %s\n", top_l[i]
}'
echo

echo "--------------------------------------------------------------"
echo " 3. MEMORY AT THE TIME OF EACH CELL RELEASE"
echo "--------------------------------------------------------------"
grep $GA "TSP_CELL_GLRELEASE action=released" "$LOG" 2>/dev/null | tail -12 | sed 's/^/  /'
n_skip=$(grep $GA -c "TSP_CELL_GLRELEASE action=skipped" "$LOG" 2>/dev/null)
n_rel=$(grep $GA -c "TSP_CELL_GLRELEASE action=released" "$LOG" 2>/dev/null)
echo
echo "  released=${n_rel:-0}  skipped=${n_skip:-0}"
echo "  (skipped means MemAvailable stayed above the floor - that is the"
echo "   pressure gate doing its job, not a failure.)"
echo

echo "--------------------------------------------------------------"
echo " 4. LOWEST MemAvailable SEEN (launcher telemetry)"
echo "--------------------------------------------------------------"
if [ -f "$PERF" ]; then
    echo "  header:"
    head -1 "$PERF" | sed 's/^/    /'
    echo
    echo "  three samples with the least memavail_kb (column 5):"
    awk 'NR>1 && NF>=5' "$PERF" | sort -k5 -n | head -3 | sed 's/^/    /'
    echo
    echo "  rows: $(wc -l < "$PERF")"
else
    echo "  no $PERF"
fi
echo

echo "--------------------------------------------------------------"
echo " 5. SWAP"
echo "--------------------------------------------------------------"
free 2>/dev/null | sed 's/^/  /'
echo
grep -E "^(SwapTotal|SwapFree|MemAvailable|MemFree):" /proc/meminfo | sed 's/^/  /'
echo
echo "=============================================================="
echo " END"
echo "=============================================================="
} 2>&1 | tee "$OUT"

echo
if [ -f "$OUT" ]; then echo "written: $OUT"; else echo "could not write a copy; the report above is all of it"; fi