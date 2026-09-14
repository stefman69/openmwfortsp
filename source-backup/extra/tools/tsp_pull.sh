#!/usr/bin/env bash
# TSP_PULL_V1 - read back one measured play session, per working agreement 27.
# Run from the VM, after quitting Morrowind through the menu:
#   bash ~/Downloads/tsp_pull.sh
#
# A file, not a paste: see the header of tsp_arm.sh. Every ssh that takes a command
# string passes -n so it cannot consume this script.

set -u

TSP="${TSP:-root@192.168.1.12}"
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6"
DL="${DL:-$HOME/Downloads}"
REP="$DL/tsp-hitch-$(date +%Y%m%d-%H%M%S).txt"

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }

r 'echo ok' >/dev/null 2>&1 || { echo "FAIL: cannot reach the TSP at $TSP" >&2; exit 1; }

rin 'sh -s' <<'REMOTE' > "$REP" 2>&1
G=/mnt/SDCARD/data/ports/openmw
S=/mnt/SDCARD
L="$G/mods/TSPPerformance/scripts/TSPPerformance/dynamic_view.lua"

echo "########## WAS THE FIX LIVE FOR THIS SESSION ##########"
if grep -q TSP_FPSAVG_V2 "$L" 2>/dev/null; then
    echo "TSP_FPSAVG_V2: LIVE   lines $(wc -l < "$L")   md5 $(md5sum "$L" | cut -d' ' -f1)"
else
    echo "TSP_FPSAVG_V2: NOT PRESENT - this session ran the OLD smoothing"
fi
printf 'log: %s bytes (rotated at arm time, so this session only)\n' \
    "$(wc -c < "$G/openmw_log.txt" 2>/dev/null || echo 0)"
echo

echo "########## CAPTURE ##########"
if ls "$S"/tsp_ring.[0-9]* >/dev/null 2>&1; then
    ls -la "$S"/tsp_ring.[0-9]*
else
    echo "FAILED CAPTURE: no dumps. Check in this order:"
    echo "  1. did the profiler see its env?  grep -a TSP_RING $G/openmw_log.txt"
    echo "  2. was it disabled?               ls $S/tsp_ring_off*"
    echo "  3. was the trigger too high?      cat $S/tsp_ring.conf"
fi
printf 'TSP_RING lines in the log: %s\n' "$(grep -ac 'TSP_RING' "$G/openmw_log.txt" 2>/dev/null; true)"
grep -a 'TSP_RING' "$G/openmw_log.txt" 2>/dev/null | head -6
echo

echo "########## AGGREGATE ##########"
sh "$S/tsp_hitch2.sh"
echo

echo "########## TWO NEWEST, PER DUMP ##########"
N="$(ls -t "$S"/tsp_ring.[0-9]* 2>/dev/null | head -2)"
if [ -n "$N" ]; then
    # shellcheck disable=SC2086
    sh "$S/tsp_hitch.sh" $N
else
    echo "(no dumps to detail)"
fi
echo

echo "########## SMOOTHING BIAS - THE FIX VERIFIED ##########"
grep -a 'TSP_DYNVIEW_V37MAP. status' "$G/openmw_log.txt" 2>/dev/null | awk '
{
    r = ""; s = ""
    for (i = 1; i <= NF; i++) {
        if ($i ~ /^raw_fps=/)    r = substr($i, 9) + 0
        if ($i ~ /^smooth_fps=/) s = substr($i, 12) + 0
        if ($i ~ /^view=/)       v = substr($i, 6) + 0
    }
    if (r == "" || s == "") next
    n++; b = s - r; sr += r; ss += s; sv += v
    if (v > vmax || vmax == 0) vmax = v
    if (v < vmin || vmin == 0) vmin = v
    if (b > worst) worst = b
    if (n > 1) {
        if      (r < pr - 0.5) { fn++; fb += b; if (b > fw) fw = b }
        else if (r > pr + 0.5) { rn++; rb += b }
        else                   { qn++; qb += b }
    }
    pr = r
}
END {
    if (!n) { print "(no status lines - TSP_DIAG_FPS or OPENMW_DEBUG_LEVEL=INFO is off)"; exit }
    printf "samples %d   mean raw %.2f   mean smooth %.2f   bias %+.2f   worst %+.2f\n",
           n, sr / n, ss / n, (ss - sr) / n, worst
    printf "  raw FELL  n=%-4d mean bias %+6.2f   worst %+6.2f\n", fn, (fn ? fb / fn : 0), fw
    printf "  raw flat  n=%-4d mean bias %+6.2f\n", qn, (qn ? qb / qn : 0)
    printf "  raw ROSE  n=%-4d mean bias %+6.2f\n", rn, (rn ? rb / rn : 0)
    printf "view: mean %.0f  min %.0f  max %.0f  swing %.0f\n", sv / n, vmin, vmax, vmax - vmin
    print  ""
    print  "PRE-FIX reference (25 samples, 2026-09-10, unpatched):"
    print  "  raw FELL  mean bias +1.85   worst +4.62"
    print  "  raw flat  mean bias +0.11"
    print  "  raw ROSE  mean bias -0.47"
    print  "  view: mean 4597  min 3909  max 5705  swing 1796"
    print  ""
    print  "The defect only shows when raw fps falls HARD, so this comparison is only"
    print  "meaningful if FELL n is reasonably large and the session had real drops."
    print  "The fix works if FELL bias is near 0 with worst under about +1.5."
}'
echo

echo "########## FRAME COST ##########"
grep -a 'TSP_CULLDRAW_V6' "$G/openmw_log.txt" 2>/dev/null | awk '
{
    for (i = 1; i <= NF; i++) { k = index($i, "="); if (k) x[substr($i, 1, k - 1)] = substr($i, k + 1) }
    rr = x["render"] + 0
    if (rr >= 300) { ld++; ldt += rr; next }
    c++; sr += rr; sc += x["cull"] + 0; sd += x["draw"] + 0; se += x["resid"] + 0
    if      (rr < 50)  b1++
    else if (rr < 100) b2++
    else if (rr < 200) b3++
    else               b4++
}
END {
    if (!c) { print "(no CULLDRAW lines - nothing exceeded 35 ms)"; exit }
    printf "slow frames excluding load: %d   mean render %.1f   cull %.1f  draw %.1f  resid %.1f\n",
           c, sr / c, sc / c, sd / c, se / c
    printf "  35-50ms %d   50-100 %d   100-200 %d   200+ %d\n", b1, b2, b3, b4
    printf "  load frames >=300ms separated: %d (mean %.0f ms)\n", ld, (ld ? ldt / ld : 0)
    print  "NOTE: this counter caps at 300 lines per run. If the total is 300 it is"
    print  "saturated and the buckets are a floor, not a count."
    print  "Reference 2026-09-10 (unpatched): 36 / 7 / 2 / 0 over 45 frames, mean render 48.1"
}'
echo

grep -E 'MemAvailable|SwapFree' /proc/meminfo
printf 'SOUNDSLOW lines: %s\n' "$(grep -ac TSP_SOUNDSLOW_V1 "$G/openmw_log.txt" 2>/dev/null; true)"
REMOTE

# Per-frame detail stays in the file; the terminal gets the readable part.
grep -vE '^  frame ' "$REP"
echo
echo "full report (with every slowest-frame line): $REP"
