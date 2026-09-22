#!/usr/bin/env bash
# TSP_VRUN_V1 - install tsp_vsync.sh and run it on the dumps already on the card, plus
# read back the vsync-relevant settings. READ ONLY except for copying the reader over.
#
#   bash ~/Downloads/tsp_vrun.sh
#
# No play session, no launcher change, no rebuild. The dumps it reads were captured
# 03:14-13:17 on 2026-09-10, before any of the 2026-09-11 damage.
#
# Rule Zero: file, not paste; r() uses -n, rin() takes the heredoc.

set -u

TSP="${TSP:-root@192.168.1.12}"
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6"
DL="${DL:-$HOME/Downloads}"
REP="$DL/tsp-vsync-$(date +%Y%m%d-%H%M%S).txt"
EXPV=53f69f48273d488ad953037e1e73d58a

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }

r 'echo ok' >/dev/null 2>&1 || { echo "FAIL: cannot reach the TSP at $TSP" >&2; exit 1; }

LV="$(md5sum "$DL/tsp_vsync.sh" 2>/dev/null | cut -d' ' -f1)"
[ "${LV:-x}" = "$EXPV" ] || { echo "FAIL: $DL/tsp_vsync.sh md5 ${LV:-missing} != $EXPV"; exit 1; }
scp -q $SSH_OPTS "$DL/tsp_vsync.sh" "$TSP:/mnt/SDCARD/" </dev/null || exit 1
DV="$(r 'md5sum /mnt/SDCARD/tsp_vsync.sh' | cut -d' ' -f1)"
[ "$DV" = "$EXPV" ] || { echo "FAIL: landed as $DV"; exit 1; }
r 'chmod +x /mnt/SDCARD/tsp_vsync.sh'
echo "VERIFIED: tsp_vsync.sh on device at $DV"

rin 'sh -s' <<'REMOTE' > "$REP" 2>&1
# ---- TSP_VRUN_REMOTE_BEGIN ----
S="${S:-/mnt/SDCARD}"
G="${G:-$S/data/ports/openmw}"

BEST=""; BESTN=0
for d in "$S"/tsp_hitch_archive_*; do
    [ -d "$d" ] || continue
    n=0
    for f in "$d"/tsp_ring.[0-9]*; do [ -f "$f" ] && n=$((n + 1)); done
    if [ "$n" -gt "$BESTN" ]; then BESTN="$n"; BEST="$d"; fi
done
if [ "$BESTN" -eq 0 ]; then echo "no archived dumps found"; exit 0; fi
echo "using $BEST ($BESTN dumps)"
echo

echo "################ ALL DUMPS TOGETHER ################"
sh "$S/tsp_vsync.sh" "$BEST"/tsp_ring.[0-9]*
echo

echo "################ THE THREE DUMPS WITH THE MOST DISTINCT CHARACTER ################"
for d in 6 10 3; do
    f="$BEST/tsp_ring.$d"
    [ -f "$f" ] || continue
    echo "=============================================================="
    echo "tsp_ring.$d"
    echo "=============================================================="
    sh "$S/tsp_vsync.sh" "$f" | sed -n '/vblank alignment/,$p'
    echo
done

echo "################ IS VSYNC EVEN ON, AND AT WHAT RATE ################"
for c in "$G/config/settings.cfg" "$G/config-0.51/settings.cfg"; do
    if [ -f "$c" ]; then
        echo "-- $c --"
        grep -n -i 'vsync\|framerate limit\|frame limit\|resolution x\|resolution y\|\[Video\]' "$c"
    fi
done
echo
echo "-- the launcher's own vsync / framerate handling --"
L=""
for f in "$S"/Roms/PORTS/*.sh; do
    [ -f "$f" ] || continue
    if grep -q 'openmw' "$f" 2>/dev/null; then L="$f"; break; fi
done
if [ -n "$L" ]; then
    echo "launcher: $L"
    grep -n -i 'vsync\|framerate\|SDL_.*VSYNC\|swap.*interval\|LIBGL_.*SWAP\|LIBGL_VSYNC' "$L" | head -20
fi
echo
echo "-- what the generator writes vsync as (settings.cfg is regenerated each launch) --"
for a in "$S"/tsp_cells_on.awk "$S"/tsp_*.awk; do
    [ -f "$a" ] || continue
    if grep -qi 'vsync\|framerate' "$a" 2>/dev/null; then
        echo "-- $a --"; grep -n -i 'vsync\|framerate' "$a"
    fi
done
echo
echo "-- panel mode --"
cat /sys/class/graphics/fb0/mode 2>/dev/null || echo "(no fb0 mode)"
for p in /sys/class/drm/*/modes; do [ -f "$p" ] && { echo "$p:"; head -3 "$p"; }; done 2>/dev/null
# ---- TSP_VRUN_REMOTE_END ----
REMOTE

cat "$REP"
echo
echo "full report: $REP"
