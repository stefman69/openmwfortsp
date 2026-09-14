#!/bin/sh
# tsp_perf_dip.sh - find the fps dip in the launcher's own perf sampler log
#
# Reads $GAMEDIR/openmw51_perf_latest.txt, which the launcher already writes
# every 2 s with rss, vsz, threads, memavail, memfree, utime, stime and majflt.
# No new build and no new play session needed - the run you already did is in
# there.
#
# WHAT IT IS FOR
#   During a dip, was the process BLOCKED or was it COMPUTING?
#     cpu% collapses + majflt/s spikes  -> memory / I/O stall
#     cpu% stays high, no faults        -> compute or GL; memory is innocent
#     the sampler itself missed samples -> the whole system stalled, not just
#                                          the game
#
# USAGE (on the device)
#     sh /mnt/SDCARD/tsp_perf_dip.sh
#     sh /mnt/SDCARD/tsp_perf_dip.sh /path/to/some_other_perf_log.txt
#
# Output is deliberately small enough to paste.

GAMEDIR="${GAMEDIR:-/mnt/SDCARD/data/ports/openmw51}"
PERF="${1:-$GAMEDIR/openmw51_perf_latest.txt}"
OUT="${TSP_DIP_OUT:-/mnt/SDCARD/tsp_perf_dip.txt}"
TMP="${TMPDIR:-/tmp}/tsp_dip_norm.$$"

if ! : > "$OUT" 2>/dev/null; then OUT="$(dirname "$PERF")/tsp_perf_dip.txt"; fi

{
echo "=============================================================="
echo " TSP PERF DIP ANALYSIS   $(date)"
echo " perf log: $PERF"
echo "=============================================================="
echo

if [ ! -f "$PERF" ]; then
    echo "  MISSING: $PERF"
    echo "  The launcher writes this per launch. If the game has not been run"
    echo "  since, or GAMEDIR is different, point me at the file directly:"
    echo "      sh $0 /path/to/perf_log.txt"
    exit 1
fi

echo "  file: $(wc -c < "$PERF") bytes, $(wc -l < "$PERF") lines"
grep "^#" "$PERF" | head -3 | sed 's/^/  /'
echo

# ---------------------------------------------------------------------------
# Normalise: one row per sample with deltas already computed.
# columns out: t dt majflt_s cpu_pct rss_kb d_rss_kb memavail_kb threads flags
# ---------------------------------------------------------------------------
awk '
/^#/            { next }
NF < 12         { next }
{
    t = $1 + 0; rss = $2 + 0; vsz = $3 + 0; th = $4 + 0
    mav = $5 + 0; mfr = $6 + 0
    ut = $10 + 0; st = $11 + 0; mf = $12 + 0
    cpu = ut + st

    if (have) {
        dt = t - pt
        if (dt <= 0) dt = 0.001

        mfs  = (mf  - pmf)  / dt              # major faults per second
        # utime/stime are USER_HZ ticks (100/s), so ticks/second == % of one core
        pct  = (cpu - pcpu) / dt
        drss = rss - prss
        dth  = th - pth

        # one token, no spaces - downstream awk splits on whitespace
        flags = ""
        if (mfs  >= 20)    flags = flags "FAULTS+"
        if (pct  <  50)    flags = flags "IDLE+"
        if (drss >  20480) flags = flags "RSSJUMP+"
        if (drss < -20480) flags = flags "RSSDROP+"
        if (dth  <  -4)    flags = flags "THREADCOLLAPSE+"
        if (flags == "")   flags = "-"
        else               sub(/\+$/, "", flags)

        printf "%.1f %.2f %.1f %.1f %d %d %d %d %s\n",
               t, dt, mfs, pct, rss, drss, mav, th, flags

        # dt histogram for the nominal-interval estimate
        key = sprintf("%.1f", dt)
        seen[key]++
    }

    pt = t; pcpu = cpu; pmf = mf; prss = rss; pth = th
    have = 1
}
END {
    best = ""; bestn = 0
    for (k in seen) if (seen[k] > bestn) { bestn = seen[k]; best = k }
    printf "NOMINAL %s %d\n", best, bestn > "/dev/stderr"
}
' "$PERF" > "$TMP" 2> "$TMP.meta"

NOMINAL=$(awk '{print $2}' "$TMP.meta" 2>/dev/null)
[ -z "$NOMINAL" ] && NOMINAL=2.0
NSAMP=$(wc -l < "$TMP")

if [ "${NSAMP:-0}" -lt 2 ]; then
    echo "  Fewer than 2 usable samples. The sampler wrote a header and little"
    echo "  else - check that the launcher's telemetry block actually ran."
    rm -f "$TMP" "$TMP.meta"
    exit 1
fi

FIRST_T=$(head -1 "$TMP" | awk '{print $1}')
LAST_T=$(tail -1 "$TMP" | awk '{print $1}')
echo "  samples: $NSAMP    t=${FIRST_T}s .. ${LAST_T}s    nominal interval: ${NOMINAL}s"
echo

echo "--------------------------------------------------------------"
echo " 1. SAMPLER GAPS - the whole system stalled, not just the game"
echo "--------------------------------------------------------------"
awk -v nom="$NOMINAL" '$2 >= nom * 1.75 {
    printf "  t=%-8s the sampler was starved for %.2f s  (expected %.1f s)   cpu%%=%.0f  majflt/s=%.0f  memavail=%d kB\n",
           $1, $2, nom, $4, $3, $7
    n++
}
END {
    if (!n) printf "  none - the sampler kept its cadence the whole run.\n  Whatever the dip was, it did not stop the rest of the system.\n"
}' "$TMP"
echo

echo "--------------------------------------------------------------"
echo " 2. WORST MAJOR-FAULT BURSTS   (memory thrash signature)"
echo "--------------------------------------------------------------"
printf "  %8s %6s %10s %7s %10s %10s %12s %4s  %s\n" \
       "t" "dt" "majflt/s" "cpu%" "rss_kb" "d_rss_kb" "memavail_kb" "thr" "flags"
sort -k3 -nr "$TMP" | head -12 | awk '{
    printf "  %8s %6s %10s %7s %10s %10s %12s %4s  %s\n",
           $1, $2, $3, $4, $5, $6, $7, $8, $9
}'
echo

echo "--------------------------------------------------------------"
echo " 3. WORST BLOCKED SAMPLES   (lowest cpu% = process not running)"
echo "--------------------------------------------------------------"
printf "  %8s %6s %10s %7s %10s %10s %12s %4s  %s\n" \
       "t" "dt" "majflt/s" "cpu%" "rss_kb" "d_rss_kb" "memavail_kb" "thr" "flags"
sort -k4 -n "$TMP" | head -12 | awk '{
    printf "  %8s %6s %10s %7s %10s %10s %12s %4s  %s\n",
           $1, $2, $3, $4, $5, $6, $7, $8, $9
}'
echo

echo "--------------------------------------------------------------"
echo " 4. DO THE TWO COINCIDE?"
echo "--------------------------------------------------------------"
awk '
{
    n++
    idle   = ($4 < 50)
    faults = ($3 >= 20)
    if (idle)            n_idle++
    if (faults)          n_faults++
    if (idle && faults)  n_both++
    if (idle && !faults) n_idle_only++
}
END {
    printf "  samples total                       %d\n", n
    printf "  blocked (cpu%% < 50)                 %d\n", n_idle+0
    printf "  fault bursts (majflt/s >= 20)       %d\n", n_faults+0
    printf "  BOTH at once                        %d\n", n_both+0
    printf "  blocked with NO faults              %d\n", n_idle_only+0
    print ""
    if (n_idle == 0)
        print "  VERDICT  the process never stopped running. Whatever the dip was,\n           it was not a stall - it was slow frames, i.e. compute or GL."
    else if (n_both >= n_idle * 0.5)
        print "  VERDICT  the blocked samples line up with fault bursts. Memory /\n           page-cache is still the story."
    else
        print "  VERDICT  the process blocked WITHOUT major faults. That is not\n           page-cache thrash - look at I/O on the fuseblk SD card, at a\n           lock, or at the driver, not at RAM pressure."
}' "$TMP"
echo

echo "--------------------------------------------------------------"
echo " 5. SAVE LOADS / RELOADS   (thread or RSS collapse)"
echo "--------------------------------------------------------------"
awk '$9 ~ /THREADCOLLAPSE|RSSDROP/ {
    printf "  t=%-8s threads=%-3s rss=%d kB  d_rss=%d kB  cpu%%=%s  %s\n",
           $1, $8, $5, $6, $4, $9
    n++
}
END {
    if (!n) print "  none - no save load or full reload happened during this run."
    else    print "\n  These are the port'"'"'s full BSA/ESM/OMW reload on save load.\n  A 15-20 s freeze here is that, not a memory stall - do not confuse\n  the two when picking out the dip."
}' "$TMP"
echo

echo "--------------------------------------------------------------"
echo " 6. SHAPE OF THE RUN   (every ~20th sample)"
echo "--------------------------------------------------------------"
printf "  %8s %10s %7s %10s %12s %4s\n" "t" "majflt/s" "cpu%" "rss_kb" "memavail_kb" "thr"
awk -v n="$NSAMP" 'BEGIN { step = int(n / 20); if (step < 1) step = 1 }
    (NR - 1) % step == 0 {
        printf "  %8s %10s %7s %10s %12s %4s\n", $1, $3, $4, $5, $7, $8
    }' "$TMP"
echo

echo "--------------------------------------------------------------"
echo " 7. TOTALS"
echo "--------------------------------------------------------------"
awk '
{
    n++
    tot_mf += $3 * $2
    if (max_rss == "" || $5 > max_rss) { max_rss = $5; max_rss_t = $1 }
    if (min_av == "" || $7 < min_av)   { min_av  = $7; min_av_t  = $1 }
    if (max_mfs == "" || $3 > max_mfs) { max_mfs = $3; max_mfs_t = $1 }
    sum_pct += $4
}
END {
    printf "  major faults over the whole run     %d\n", tot_mf
    printf "  peak major faults/s                 %s   at t=%ss\n", max_mfs, max_mfs_t
    printf "  peak RSS                            %d kB   at t=%ss\n", max_rss, max_rss_t
    printf "  lowest MemAvailable                 %d kB   at t=%ss\n", min_av, min_av_t
    printf "  mean cpu%% across the run            %.0f%%  (100%% = one core saturated)\n", sum_pct / n
}' "$TMP"
echo

echo "--------------------------------------------------------------"
echo " 8. SWAP RIGHT NOW"
echo "--------------------------------------------------------------"
grep -E "^(SwapTotal|SwapFree|MemAvailable|MemFree):" /proc/meminfo | sed 's/^/  /'
echo

echo "--------------------------------------------------------------"
echo " HOW TO READ THIS"
echo "--------------------------------------------------------------"
cat <<'EOT'
  cpu% is ticks of CPU per second of wall clock, so 100% = one core fully
  busy. This build pins the main thread to one big core with background work
  on two little ones, so a healthy frame-bound run sits well above 100%.

  A dip where cpu% stays high  -> the game was working, just slowly.
                                  Memory is not the cause. Look at draw calls,
                                  shader compiles, terrain paging.

  A dip where cpu% falls to near zero -> the game was stopped, waiting.
     ...with majflt/s spiking   -> pages being fetched back from disk/swap.
     ...with no faults          -> blocked on something else: SD-card I/O
                                  through fuseblk, a lock, or the GL driver.

  Section 1 is the strongest single signal. The sampler is a separate cheap
  process; if IT missed its cadence, the stall was system-wide.
EOT
echo
echo "=============================================================="
echo " END"
echo "=============================================================="
} 2>&1 | tee "$OUT"

rm -f "$TMP" "$TMP.meta"
echo
if [ -f "$OUT" ]; then echo "written: $OUT"; else echo "no copy written; the report above is all of it"; fi