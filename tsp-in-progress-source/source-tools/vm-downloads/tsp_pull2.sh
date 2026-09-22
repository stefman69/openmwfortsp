#!/usr/bin/env bash
# TSP_PULL2_V1 - read back the capture armed by tsp_ringarm.sh.
#
#   bash ~/Downloads/tsp_pull2.sh        (after quitting through the menu)
#
# Rule Zero: file, not paste; r() uses -n, rin() takes the heredoc.

set -u

TSP="${TSP:-root@192.168.1.12}"
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6"
DL="${DL:-$HOME/Downloads}"
REP="$DL/tsp-capture-$(date +%Y%m%d-%H%M%S).txt"

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }

r 'echo ok' >/dev/null 2>&1 || { echo "FAIL: cannot reach the TSP at $TSP" >&2; exit 1; }

rin 'sh -s' <<'REMOTE' > "$REP" 2>&1
# ---- TSP_PULL2_REMOTE_BEGIN ----
S="${S:-/mnt/SDCARD}"
G="${G:-$S/data/ports/openmw}"

echo "########## DID THE INSTRUMENT ACTUALLY RUN ##########"
echo "-- what the launcher announced --"
grep -a 'TSP_RINGARM_V2' "$S/tsp_prog.txt" 2>/dev/null | tail -3
echo "-- what the profiler saw (this is the line that matters) --"
grep -a 'TSP_RING_CONFIG' "$G/openmw_log.txt" 2>/dev/null | tail -2
echo "-- arm and dump events --"
printf 'TSP_RING_ARM:  %s\n' "$(grep -ac 'TSP_RING_ARM'  "$G/openmw_log.txt" 2>/dev/null; true)"
printf 'TSP_RING_DUMP: %s\n' "$(grep -ac 'TSP_RING_DUMP' "$G/openmw_log.txt" 2>/dev/null; true)"
grep -a 'TSP_RING_DUMP' "$G/openmw_log.txt" 2>/dev/null | tail -5
echo
echo "-- dumps written --"
if ls "$S"/tsp_ring.[0-9]* >/dev/null 2>&1; then
    ls -la "$S"/tsp_ring.[0-9]*
else
    echo "NO DUMPS. Read the TSP_RING_CONFIG line above:"
    echo "  path=(... unset ...)  -> the launcher did not export it"
    echo "  trigger_ms=0.0        -> the value arrived empty"
    echo "  trigger too high      -> nothing crossed it; lower TSP_RING_TRIG in"
    echo "                           /mnt/SDCARD/tsp_ring.conf and capture again"
fi
echo
printf 'fps smoothing fix live: '
if grep -q TSP_FPSAVG_V2 "$G/mods/TSPPerformance/scripts/TSPPerformance/dynamic_view.lua" 2>/dev/null; then
    echo "YES"
else
    echo "NO - this session ran the OLD smoothing"
fi
echo

echo "########## IS IT VSYNC QUANTISATION ##########"
if ls "$S"/tsp_ring.[0-9]* >/dev/null 2>&1; then
    sh "$S/tsp_vsync.sh" "$S"/tsp_ring.[0-9]*
else
    echo "(no dumps)"
fi
echo

echo "########## FAULTS AND SLOT SPLIT ##########"
if ls "$S"/tsp_ring.[0-9]* >/dev/null 2>&1; then
    sh "$S/tsp_hitch2.sh" "$S"/tsp_ring.[0-9]*
else
    echo "(no dumps)"
fi
echo

echo "########## THE THREE LARGEST DUMPS, PER FRAME ##########"
BIG="$(ls -S "$S"/tsp_ring.[0-9]* 2>/dev/null | head -3)"
if [ -n "$BIG" ]; then
    # shellcheck disable=SC2086
    sh "$S/tsp_hitch.sh" $BIG
else
    echo "(no dumps)"
fi
echo

echo "########## ADAPTIVE DRAW DISTANCE ##########"
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
    print  "PRE-FIX reference (unpatched, 2026-09-10): FELL +1.85 worst +4.62, view swing 1796"
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
    if (!c) { print "(no CULLDRAW lines)"; exit }
    printf "slow frames excluding load: %d   mean render %.1f   cull %.1f  draw %.1f  resid %.1f\n",
           c, sr / c, sc / c, sd / c, se / c
    printf "  35-50ms %d   50-100 %d   100-200 %d   200+ %d\n", b1, b2, b3, b4
    printf "  load frames >=300ms: %d (mean %.0f ms)\n", ld, (ld ? ldt / ld : 0)
    print  "caps at 300 lines per run; a total of exactly 300 means saturated"
}'
echo
grep -E 'MemAvailable|SwapFree' /proc/meminfo
printf 'SOUNDSLOW lines: %s\n' "$(grep -ac TSP_SOUNDSLOW_V1 "$G/openmw_log.txt" 2>/dev/null; true)"
printf 'ktx textures: %s\n' "$(find "$G/data/Data Files/textures" -name '*.ktx' 2>/dev/null | wc -l)"
# ---- TSP_PULL2_REMOTE_END ----
REMOTE

grep -vE '^  frame ' "$REP"
echo
echo "full report (with every per-frame line): $REP"
