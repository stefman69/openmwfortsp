#!/usr/bin/env bash
# TSP_KTXAB_V1 - one-variable A/B on the ASTC texture conversion.
#
#   bash ~/Downloads/tsp_ktxab.sh 0     # engine ignores .ktx, reads DDS from the BSAs
#   bash ~/Downloads/tsp_ktxab.sh 1     # engine prefers .ktx (current shipping state)
#
# TSP_KTX gates tspPreferKtx() in components/misc/resourcehelpers.cpp. With it at 0 the
# 4555 loose .ktx files are ignored and every texture comes out of Morrowind.bsa /
# Tribunal.bsa / Bloodmoon.bsa, which is the pre-conversion read pattern. Same binary,
# same mods, same save. One variable.
#
# It also DROPS THE PAGE CACHE before you launch. Every comparison so far has been
# confounded by cache state: loads have ranged 3.3 s to 25.8 s and Cached has ranged
# 26 MB to 200 MB across runs, which moved the post-load fault rate far more than
# anything being tested. Both arms of this A/B start cold.
#
# Rule Zero: file, not paste; r() uses -n, rin() takes the heredoc (NEVER -n).

set -u
MODE="${1:-}"
case "$MODE" in
    0|1) ;;
    *) echo "usage: bash $0 0|1   (0 = DDS from BSAs, 1 = prefer .ktx)"; exit 2 ;;
esac

TSP="${TSP:-root@192.168.1.12}"
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6"
STAMP="$(date +%Y%m%d-%H%M%S)"
CONF=/mnt/SDCARD/tsp_iotune.conf

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }
die() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

r 'echo ok' >/dev/null 2>&1 || die "cannot reach the TSP at $TSP"

echo "########## 1. THE CONF AS IT IS NOW ##########"
r "grep -n 'TSP_KTX' '$CONF' || echo '(no TSP_KTX line at all)'"
echo

rin "MODE=$MODE STAMP=$STAMP sh -s" <<'REMOTE'
CONF=/mnt/SDCARD/tsp_iotune.conf
S=/mnt/SDCARD
G=$S/data/ports/openmw

[ -f "$CONF" ] || { echo "FAIL: $CONF does not exist"; exit 1; }

# Read before writing. The tsp_ring.conf incident came from writing a value taken
# from a doc without reading the file first.
BEFORE="$(grep -c 'TSP_KTX' "$CONF" ; true)"
if [ "$BEFORE" -lt 1 ]; then
    echo "FAIL: no TSP_KTX line to change; refusing to invent one"
    exit 1
fi

cp -p "$CONF" "$CONF.before-ktxab-$STAMP" || { echo "FAIL: backup failed"; exit 1; }
echo "backed up to $(basename "$CONF").before-ktxab-$STAMP"

sed "s/^\([[:space:]]*export[[:space:]][[:space:]]*TSP_KTX=\).*/\1$MODE/" "$CONF" > "$CONF.new" \
    || { echo "FAIL: sed"; rm -f "$CONF.new"; exit 1; }

BL="$(wc -l < "$CONF")"; AL="$(wc -l < "$CONF.new")"
GOT="$(sed -n 's/^[[:space:]]*export[[:space:]][[:space:]]*TSP_KTX=\(.*\)$/\1/p' "$CONF.new")"
DIFFN="$(diff "$CONF" "$CONF.new" 2>/dev/null | grep -c '^[<>]' ; true)"

echo "  lines $BL -> $AL          (must be equal)"
echo "  TSP_KTX now [$GOT]        (must be $MODE)"
echo "  changed lines: $DIFFN     (must be 0 or 2)"

OK=1
[ "$BL" = "$AL" ] || OK=0
[ "$GOT" = "$MODE" ] || OK=0
[ "$DIFFN" -le 2 ] || OK=0
if [ "$OK" -ne 1 ]; then
    rm -f "$CONF.new"
    echo "REFUSED - conf untouched, backup left in place"
    exit 1
fi
mv "$CONF.new" "$CONF"
echo "  VERIFIED: export TSP_KTX=$MODE"
echo
echo "-- the whole TSP_KTX context, for the record --"
grep -n -B1 -A1 'TSP_KTX' "$CONF"

echo
echo "########## 2. CLEAN CAPTURE ##########"
A="$S/tsp_hitch_archive_$STAMP"; n=0
for d in "$S"/tsp_ring.[0-9]*; do
    [ -f "$d" ] || continue
    mkdir -p "$A"; cp -p "$d" "$A/" && rm -f "$d" && n=$((n+1))
done
echo "dumps archived: $n"
touch "$S/tsp_ktxwarm_off"
if [ -f "$S/tsp_ring_off" ]; then mv "$S/tsp_ring_off" "$S/tsp_ring_off.parked-$STAMP"; fi
printf 'TSP_RING_TRIG=60\nTSP_RING_MAX=12\n' > "$S/tsp_ring.conf"
if [ -s "$G/openmw_log.txt" ]; then mv "$G/openmw_log.txt" "$G/openmw_log.txt.ktx$MODE-$STAMP"; fi
sync

echo
echo "########## 3. DROP THE PAGE CACHE - THE CONTROL ##########"
echo "Cached before: $(awk '/^Cached:/{print $2}' /proc/meminfo) kB"
sync
if echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; then
    echo "caches dropped"
else
    echo "WARNING: could not drop caches - this arm is NOT comparable to the other"
fi
echo "Cached after:  $(awk '/^Cached:/{print $2}' /proc/meminfo) kB"

echo
echo "########## READY CHECK ##########"
F=0
V="$(sed -n 's/^[[:space:]]*export[[:space:]][[:space:]]*TSP_KTX=\(.*\)$/\1/p' "$CONF")"
if [ "$V" = "$MODE" ]; then echo "  OK   TSP_KTX=$V"; else echo "  FAIL TSP_KTX is [$V]"; F=1; fi
if [ -f "$S/tsp_ring_off" ]; then echo "  FAIL profiler off"; F=1; else echo "  OK   profiler enabled"; fi
if ls "$S"/tsp_ring.[0-9]* >/dev/null 2>&1; then echo "  FAIL dumps present"; F=1; else echo "  OK   dump slots free"; fi
if [ -s "$G/openmw_log.txt" ]; then echo "  FAIL log not empty"; F=1; else echo "  OK   log clean"; fi
if [ -f "$S/tsp_ktxwarm_off" ]; then echo "  OK   prefetch off"; else echo "  FAIL prefetch on"; F=1; fi
echo "  OK   cache cold: $(awk '/^Cached:/{print $2}' /proc/meminfo) kB"
echo
if [ "$F" -eq 0 ]; then echo "READY - launch NOW, while the cache is still cold"; else echo "NOT READY"; fi
REMOTE

echo
echo "=================================================================="
echo "  TSP_KTX=$MODE"
echo "  1. Launch 'Morrowind' NOW. Do not wait - the cold cache is the control."
echo "  2. Load the SAME save as the other arm, into an exterior."
echo "  3. Walk the SAME route for 60-90 s. Then quit through the menu."
echo "  4. bash ~/Downloads/tsp_prun.sh"
echo "=================================================================="
echo
echo "Run both arms back to back, same save, same route, same order of steps."
echo "The number to compare is the 0-5 s bucket after the load: majflt/s and"
echo "the faulting percentage. Also compare the load duration itself."
