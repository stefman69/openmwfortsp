#!/usr/bin/env bash
# TSP_GAPSCAN_V1 - twelve logs already on the card. Free retrospective A/B.
#
#   bash ~/Downloads/tsp_gapscan.sh
#
# READ ONLY. No run, no play session, nothing changed.
#
# ============================================================================
# WHY
# ============================================================================
# Every log from tonight carries a full TSP_LOAD_TRACE phase ladder, and tonight
# spanned wildly different configs: ktx0, ktx1, ktxband (892 files parked),
# iowatch, memsplit-a, memsplit-b, memsplit-off, and the pre-* runs. That is a
# dozen data points on the 191.8 MB step, already captured, never compared.
#
# If the step is the same in all twelve, it is structural and attributing it needs
# new trace points inside changeCellGrid, i.e. a rebuild. If it MOVES with any of
# those configs, that config is the lever and we skip the rebuild entirely.
#
# ============================================================================
# TWO FINDINGS FROM tsp_gapdump, kept straight
# ============================================================================
# The 13.3 s is explained. The 191.8 MB is not. They are different questions.
#
#   window total             13.3 s
#   TSP_WARMDRAW_GATE  2 x    7.9 s   59% of it
#   cell loading (9 cells)    2.1 s
#   TSP_SNDWARM_V1            0.8 s
#   unaccounted               2.6 s
#
# **The warm-draw gate is failing.** Both occurrences report
# `drained in 240 frames remaining=14`. shader-variant-precompile-and-warmdrain-
# 20260908.md defines success as `remaining=0 ms=<2000-5000>`, and describes
# TSP_WARMDRAIN_V3 as "(untested)". It shipped untested, it never drains, it runs
# TWICE, and it costs ~7.9 s of every load. That is an independent, actionable bug
# and it is most of the loading bar.
#
# It is NOT the memory: 14 osg::Program objects are not 191 MB.
#
# Also weakened: exactly 9 cells load (a 3x3 active grid, not an expanded one), so
# "view distance enlarged the grid" is not supported. 9 cells for 191 MB is ~21 MB
# per cell.
#
# ============================================================================
# AND A BUG IN tsp_gapdump I AM FIXING HERE
# ============================================================================
# It picked logs with `tail -2` over a shell glob, which sorts LEXICOGRAPHICALLY.
# "pre-*" sorts after "memsplit-*", so it analysed the 20:29 and 21:07 runs instead
# of the two memsplit runs. This orders by mtime and scans all of them.
#
# Rule Zero: file, not paste; r() uses -n, rin() takes the heredoc (NEVER -n).
# No grep -r. No $(grep -c x f || echo 0). No apostrophe inside any awk program.

set -u

TSP="${TSP:-root@192.168.1.12}"
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6"
DL="${DL:-$HOME/Downloads}"
STAMP="$(date +%Y%m%d-%H%M%S)"
REP="$DL/tsp-gapscan-$STAMP.txt"

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }
die() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

r 'echo ok' >/dev/null 2>&1 || die "cannot reach the TSP at $TSP"

rin 'sh -s' <<'REMOTE' 2>&1 | tee "$REP"
# ---- TSP_GAPSCAN_REMOTE_BEGIN ----
S=/mnt/SDCARD
G=$S/data/ports/openmw

echo "=================================================================="
echo " EVERY LOAD ON THE CARD, ONE ROW EACH.  kB unless marked."
echo "=================================================================="
echo
printf '%-42s %9s %9s %9s %7s %6s %6s %9s %8s\n' \
    "log (oldest first)" "gap_kb" "compl_kb" "rec_kb" "gap_s" "cells" "gates" "gate_ms" "remain"
printf '%-42s %9s %9s %9s %7s %6s %6s %9s %8s\n' \
    "------------------------------------------" "---------" "---------" "---------" "-------" "------" "------" "---------" "--------"

# ls -t is newest first; reverse it so the table reads chronologically. One awk per
# log, a dozen forks total, no per-line forks.
for f in $(ls -t "$G"/openmw_log.txt "$G"/openmw_log.txt.* 2>/dev/null | sed '1!G;h;$!d'); do
    [ -f "$f" ] || continue
    awk -v name="$(basename "$f")" '
    function tosec(s) { if (s == "") return -1; split(s, a, ":"); return a[1]*3600 + a[2]*60 + a[3] }
    {
        ts = ""
        if (match($0, /[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9]+/)) ts = substr($0, RSTART, RLENGTH)

        if ($0 ~ /phase=mechanics-playerLoaded/ && !gotA) {
            for (i = 1; i <= NF; i++) { k = index($i, "="); if (k && substr($i,1,k-1) == "inuse_kb") A = substr($i,k+1)+0 }
            tA = tosec(ts); gotA = 1
        }
        if ($0 ~ /phase=projectile-casters-updated/ && gotA && !gotB) {
            for (i = 1; i <= NF; i++) { k = index($i, "="); if (k && substr($i,1,k-1) == "inuse_kb") B = substr($i,k+1)+0 }
            tB = tosec(ts); gotB = 1
        }
        if ($0 ~ /phase=records-parsed/ && !gotR) {
            for (i = 1; i <= NF; i++) { k = index($i, "="); if (k && substr($i,1,k-1) == "inuse_kb") R = substr($i,k+1)+0 }
            gotR = 1
        }
        if ($0 ~ /phase=content-map-ready/ && !gotC0) {
            for (i = 1; i <= NF; i++) { k = index($i, "="); if (k && substr($i,1,k-1) == "inuse_kb") C0 = substr($i,k+1)+0 }
            gotC0 = 1
        }
        if ($0 ~ /phase=complete/ && !gotZ) {
            for (i = 1; i <= NF; i++) { k = index($i, "="); if (k && substr($i,1,k-1) == "inuse_kb") Z = substr($i,k+1)+0 }
            gotZ = 1
        }
        # only count events that fall inside the gap
        if (gotA && !gotB) {
            if ($0 ~ /Loading cell/) cells++
            if ($0 ~ /TSP_WARMDRAW_GATE/) {
                gates++
                for (i = 1; i <= NF; i++) {
                    k = index($i, "=")
                    if (!k) continue
                    key = substr($i,1,k-1); val = substr($i,k+1)
                    if (key == "ms")        gms += val + 0
                    if (key == "remaining") { rem = val + 0; remseen = 1 }
                }
            }
            if ($0 ~ /TSP_SNDWARM_V1/) {
                for (i = 1; i <= NF; i++) { k = index($i, "="); if (k && substr($i,1,k-1) == "ms") snd += substr($i,k+1)+0 }
            }
        }
    }
    END {
        if (!gotA || !gotB) { printf "%-42s %9s\n", name, "(no gap)"; exit }
        gs = (tA >= 0 && tB >= 0) ? tB - tA : -1
        printf "%-42s %9d %9d %9d %7s %6d %6d %9.0f %8s\n", \
            name, B - A, Z + 0, (gotR && gotC0 ? R - C0 : 0), \
            (gs >= 0 ? sprintf("%.1f", gs) : "?"), cells + 0, gates + 0, gms + 0, \
            (remseen ? sprintf("%d", rem) : "-")
    }' "$f"
done

echo
echo "  gap_kb   = inuse_kb across mechanics-playerLoaded -> projectile-casters-updated"
echo "  compl_kb = inuse_kb at phase=complete"
echo "  rec_kb   = inuse_kb across content-map-ready -> records-parsed"
echo "  gates    = TSP_WARMDRAW_GATE occurrences INSIDE the gap; gate_ms their total"
echo "  remain   = the LAST remaining= value. Success per the 09-08 doc is 0."
echo
echo "READ IT LIKE THIS: if gap_kb is flat across every row, no config we tried"
echo "tonight touches it, it is structural, and attributing it needs trace points"
echo "inside changeCellGrid - a rebuild. If gap_kb MOVES with a row, that row's"
echo "config is the lever and there is no rebuild needed."
echo

echo "=================================================================="
echo " THE WARM-DRAW GATE, WHOLE FILE, NEWEST LOG"
echo "=================================================================="
NEW="$(ls -t "$G"/openmw_log.txt "$G"/openmw_log.txt.* 2>/dev/null | head -1)"
echo "log: $(basename "$NEW")"
echo
echo "-- every gate / drain / precompile summary line --"
grep -a -E 'TSP_WARMDRAW_GATE|TSP_WARMDRAIN|TSP_VARIANT_PRECOMPILE|TSP_PRGCACHE|TSP_SHCACHE' "$NEW" 2>/dev/null \
    | head -30 | sed 's/^/  /'
echo
echo "-- how many programs were ever queued vs what the gate had left --"
printf '  WARMDRAW queued lines:   %s\n' "$(grep -ac 'TSP_WARMDRAW queued' "$NEW" 2>/dev/null; true)"
printf '  PRECOMPILE queued lines: %s\n' "$(grep -ac 'TSP_PRECOMPILE queued' "$NEW" 2>/dev/null; true)"
printf '  highest queued n=:       %s\n' "$(grep -ao 'TSP_WARMDRAW queued program n=[0-9]*' "$NEW" 2>/dev/null | sed 's/.*n=//' | sort -n | tail -1)"
echo "  every distinct remaining= value seen anywhere in the file:"
grep -ao 'remaining=[0-9]*' "$NEW" 2>/dev/null | sort | uniq -c | sed 's/^/    /'
echo
echo "-- the drain knobs, current values --"
for kv in TSP_NO_SHADER_WARMDRAW TSP_NO_SHADER_PRECOMPILE TSP_NO_VARIANT_PRECOMPILE TSP_VARIANT_CACHE TSP_WARMDRAIN_MS TSP_WARMDRAIN_DEADLINE; do
    v="$(sed -n "s/^[[:space:]]*export[[:space:]][[:space:]]*$kv=\(.*\)\$/\1/p" "$S/tsp_iotune.conf" 2>/dev/null | tail -1)"
    printf '    %-30s %s\n' "$kv" "${v:-(unset)}"
done
echo
echo "-- does the binary contain the drain strings at all --"
BIN=""
for c in "$G/bin/openmw-0.51" "$G/bin/openmw" "$G/openmw"; do
    [ -x "$c" ] && { BIN="$c"; break; }
done
if [ -n "$BIN" ]; then
    echo "    binary: $BIN"
    for m in TSP_WARMDRAW_GATE TSP_WARMDRAIN_V3 TSP_WARMDRAIN_V2 TSP_VARIANT_PRECOMPILE_V1 TSP_RECORDMEM_V1; do
        c="$(grep -ac "$m" "$BIN" 2>/dev/null; true)"
        printf '    %-30s %s\n' "$m" "${c:-0}"
    done
    echo "    (TSP_RECORDMEM_V1 at 0 confirms it is not compiled in - the SHIP-STATE"
    echo "     doc listing it as available is stale)"
else
    echo "    binary not found under $G/bin"
fi
# ---- TSP_GAPSCAN_REMOTE_END ----
REMOTE

echo
echo "full report: $REP"
