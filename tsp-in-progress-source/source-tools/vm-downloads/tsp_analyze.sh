#!/usr/bin/env bash
# TSP_ANALYZE_V1 - answer "what is hitching the framerate" from data already on the
# card, and collect exactly what is needed to make the profiler safe to re-enable.
#
#   bash ~/Downloads/tsp_analyze.sh
#
# READ ONLY on the device. Changes nothing, launches nothing, needs no play session.
# The dumps it reads are the 12 archived by tsp_arm.sh, captured 03:14-13:17 on
# 2026-09-10 - real gameplay, before any of the 2026-09-11 damage.
#
# Rule Zero: file, not paste; r() uses -n, rin() takes the heredoc.

set -u

TSP="${TSP:-root@192.168.1.12}"
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6"
DL="${DL:-$HOME/Downloads}"
REP="$DL/tsp-analyze-$(date +%Y%m%d-%H%M%S).txt"
EXP1=66a62043c74efebd83b3e496507ded72
EXP2=885f9c68d749282179e63223089fbf43

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }

r 'echo ok' >/dev/null 2>&1 || { echo "FAIL: cannot reach the TSP at $TSP" >&2; exit 1; }

# The readers must be the corrected ones or the numbers are wrong again.
D1="$(r 'md5sum /mnt/SDCARD/tsp_hitch.sh  2>/dev/null' | cut -d' ' -f1)"
D2="$(r 'md5sum /mnt/SDCARD/tsp_hitch2.sh 2>/dev/null' | cut -d' ' -f1)"
if [ "${D1:-x}" != "$EXP1" ] || [ "${D2:-x}" != "$EXP2" ]; then
    echo "readers on device are not the corrected build; re-copying from $DL"
    L1="$(md5sum "$DL/tsp_hitch.sh"  2>/dev/null | cut -d' ' -f1)"
    L2="$(md5sum "$DL/tsp_hitch2.sh" 2>/dev/null | cut -d' ' -f1)"
    [ "${L1:-x}" = "$EXP1" ] || { echo "FAIL: $DL/tsp_hitch.sh md5 ${L1:-missing} != $EXP1"; exit 1; }
    [ "${L2:-x}" = "$EXP2" ] || { echo "FAIL: $DL/tsp_hitch2.sh md5 ${L2:-missing} != $EXP2"; exit 1; }
    scp -q $SSH_OPTS "$DL/tsp_hitch.sh" "$DL/tsp_hitch2.sh" "$TSP:/mnt/SDCARD/" </dev/null || exit 1
    r 'chmod +x /mnt/SDCARD/tsp_hitch.sh /mnt/SDCARD/tsp_hitch2.sh'
    echo "corrected readers installed"
else
    echo "readers verified: corrected build already on device"
fi

echo
echo "########## LOCAL: how tspprof reads its config ##########"
if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -q openmw_builder; then
    H=/root/openmw-0.51-tsp-src/apps/openmw/tspprof.h
    docker exec openmw_builder sh -c "
        if [ -f $H ]; then
            echo '-- every OPENMW_TSP_RING getenv and its default --'
            grep -n -B3 -A6 'OPENMW_TSP_RING' $H
            echo
            echo '-- the trigger comparison that decides whether to arm --'
            grep -n -B2 -A4 'trigger' $H | head -60
            echo
            echo \"md5 \$(md5sum $H | cut -d' ' -f1)   lines \$(wc -l < $H)\"
        else
            echo \"tspprof.h not at $H\"
            find /root/openmw-0.51-tsp-src -name 'tspprof.h' 2>/dev/null
        fi"
else
    echo "(openmw_builder container not running - start it, or I will work from the"
    echo " device-side evidence alone: trigger_ms=0.0 with max_dumps=8 already proves"
    echo " the compiled defaults are trigger 0 / max 8)"
fi

rin 'sh -s' <<'REMOTE' > "$REP" 2>&1
# ---- TSP_ANALYZE_REMOTE_BEGIN ----
S="${S:-/mnt/SDCARD}"
G="${G:-$S/data/ports/openmw}"

echo "########## THE ARCHIVED DUMPS ##########"
BEST=""
BESTN=0
for d in "$S"/tsp_hitch_archive_*; do
    [ -d "$d" ] || continue
    n=0
    for f in "$d"/tsp_ring.[0-9]*; do [ -f "$f" ] && n=$((n + 1)); done
    printf '  %s : %d dumps\n' "$d" "$n"
    if [ "$n" -gt "$BESTN" ]; then BESTN="$n"; BEST="$d"; fi
done
if [ "$BESTN" -eq 0 ]; then
    echo "  NO ARCHIVED DUMPS FOUND under $S/tsp_hitch_archive_*"
    echo "  Loose dumps on the card:"
    ls -la "$S"/tsp_ring.[0-9]* 2>/dev/null || echo "    none"
    exit 0
fi
echo
echo "using $BEST ($BESTN dumps)"
echo

echo "########## AGGREGATE, CORRECTED READER ##########"
sh "$S/tsp_hitch2.sh" "$BEST"/tsp_ring.[0-9]*
echo

echo "########## THE THREE LARGEST DUMPS, PER FRAME ##########"
BIG="$(ls -S "$BEST"/tsp_ring.[0-9]* 2>/dev/null | head -3)"
# shellcheck disable=SC2086
sh "$S/tsp_hitch.sh" $BIG
echo

echo "########## LAUNCHER RING BLOCK, VERBATIM ##########"
LAUNCHER=""
for f in "$S"/Roms/PORTS/*.sh; do
    [ -f "$f" ] || continue
    if grep -q 'OPENMW_TSP_RING' "$f" 2>/dev/null; then LAUNCHER="$f"; break; fi
done
if [ -n "$LAUNCHER" ]; then
    echo "launcher: $LAUNCHER"
    echo "md5 $(md5sum "$LAUNCHER" | cut -d' ' -f1)   lines $(wc -l < "$LAUNCHER")"
    echo "-- 12 lines of context around every OPENMW_TSP_RING / TSP_RING reference --"
    grep -n -B6 -A6 'OPENMW_TSP_RING\|TSP_RING_TRIG\|TSP_RING_MAX\|tsp_ring' "$LAUNCHER"
else
    echo "no launcher mentions OPENMW_TSP_RING"
    ls "$S"/Roms/PORTS/*.sh 2>/dev/null
fi
echo
echo "-- every tsp_ring.conf and backup on the card --"
for f in "$S"/tsp_ring.conf*; do
    [ -f "$f" ] || continue
    printf '  %-52s %s\n' "$(basename "$f")" "$(tr '\n' ' ' < "$f")"
done
echo
echo "-- ring off switch --"
ls -la "$S"/tsp_ring_off* 2>/dev/null || echo "  none present"

echo
echo "########## WHERE dynamic_view.lua IS INSTALLED FROM ##########"
echo "-- every copy on the card --"
find "$S" -name 'dynamic_view.lua*' 2>/dev/null | while read -r c; do
    printf '  %s  %s lines  md5 %s  %s\n' \
        "$c" "$(wc -l < "$c")" "$(md5sum "$c" | cut -d' ' -f1)" \
        "$(grep -q TSP_FPSAVG_V2 "$c" && echo 'HAS_V2' || echo '-')"
done
echo
echo "-- does the launcher force-install TSPPerformance --"
if [ -n "$LAUNCHER" ]; then
    grep -n 'TSPPerformance\|v30_profiles\|defaults/' "$LAUNCHER" | head -20
fi
# ---- TSP_ANALYZE_REMOTE_END ----
REMOTE

grep -vE '^  frame ' "$REP"
echo
echo "full report (with per-frame lines): $REP"
