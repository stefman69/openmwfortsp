#!/usr/bin/env bash
# TSP_NAVWRITE_V1 - let the engine cache the navmesh it generates.
#
#   bash ~/Downloads/tsp_navwrite.sh          then TWO load cycles, then tsp_prun.sh
#
# FOUND 2026-09-10: settings.cfg has
#     [Navigator]
#     write to navmeshdb = false
#     max navmeshdb file size = 1610612736
#     async num threads = 2
# The engine reads /mnt/UDISK/openmw-nav/navmesh.db (891 MB, mtime Sep 5) but cannot
# write it. Any cell whose geometry does not match what base-navmesh.db was baked
# against is generated at runtime by the 2 async workers, thrown away, and regenerated
# on the next load. Forever. That matches the measurements: mech 3.09 vs 1.4-1.8 on
# post-load frames, "OTHER THREAD ATE THE CPU" on up to 421 of 900 frames, and a fault
# storm that decays within a load but never gets better across loads.
#
# Setting it true costs some extra write I/O the first time an area is visited and then
# nothing. Headroom: the cap is 1.5 GB against an 891 MB file, and UDISK has 3.2 GB free.
#
# THE PREDICTION, which is what makes this a real test: the SECOND load of the same
# save in the same conditions should be materially cheaper than the first, because the
# first one populated the cache. Every A/B tonight was ruined by cache state differing
# between runs; this compares two loads under one arming.
#
# Rule Zero: file, not paste; r() uses -n, rin() takes the heredoc (NEVER -n).

set -u
TSP="${TSP:-root@192.168.1.12}"
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6"
STAMP="$(date +%Y%m%d-%H%M%S)"

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }
die() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

r 'echo ok' >/dev/null 2>&1 || die "cannot reach the TSP at $TSP"

rin "STAMP=$STAMP sh -s" <<'REMOTE'
S=/mnt/SDCARD
G=$S/data/ports/openmw
CFG="$G/config/settings.cfg"
DB=/mnt/UDISK/openmw-nav/navmesh.db

echo "########## 1. BEFORE ##########"
[ -f "$CFG" ] || { echo "FAIL: $CFG missing"; exit 1; }
grep -n -A4 '^\[Navigator\]' "$CFG"
echo
echo "live db:"; ls -l "$DB" 2>/dev/null || echo "  ABSENT"
echo "udisk free:"; df -h /mnt/UDISK | tail -1
echo

echo "########## 2. ENABLE THE WRITE ##########"
N="$(grep -c '^write to navmeshdb' "$CFG" ; true)"
if [ "$N" -ne 1 ]; then
    echo "FAIL: expected exactly one 'write to navmeshdb' line, found $N"
    grep -n 'navmeshdb' "$CFG"
    exit 1
fi
CUR="$(sed -n 's/^write to navmeshdb = \(.*\)$/\1/p' "$CFG")"
if [ "$CUR" = "true" ]; then
    echo "already true - nothing to change"
    SKIP=1
else
    SKIP=0
fi
if [ "$SKIP" -eq 0 ]; then
cp -p "$CFG" "$CFG.before-navwrite-$STAMP" || { echo "FAIL: backup"; exit 1; }
echo "backed up to $(basename "$CFG").before-navwrite-$STAMP"

sed 's/^write to navmeshdb = false$/write to navmeshdb = true/' "$CFG" > "$CFG.new" \
    || { echo "FAIL: sed"; rm -f "$CFG.new"; exit 1; }

BL="$(wc -l < "$CFG")"; AL="$(wc -l < "$CFG.new")"
GOT="$(sed -n 's/^write to navmeshdb = \(.*\)$/\1/p' "$CFG.new")"
DIFFN="$(diff "$CFG" "$CFG.new" 2>/dev/null | grep -c '^[<>]' ; true)"
echo "  lines $BL -> $AL      (must be equal)"
echo "  value now [$GOT]      (must be true)"
echo "  changed lines $DIFFN  (must be 2)"
OK=1
[ "$BL" = "$AL" ] || OK=0
[ "$GOT" = "true" ] || OK=0
[ "$DIFFN" -eq 2 ] || OK=0
if [ "$OK" -ne 1 ]; then rm -f "$CFG.new"; echo "REFUSED - settings.cfg untouched"; exit 1; fi
mv "$CFG.new" "$CFG"
echo "  VERIFIED"
fi
grep -n -A4 '^\[Navigator\]' "$CFG"

echo
echo "########## 3. RECORD THE DB SO WE CAN SEE IT GROW ##########"
if [ -f "$DB" ]; then
    printf 'BASELINE db bytes=%s mtime=%s\n' "$(wc -c < "$DB")" "$(ls -l "$DB" | awk '{print $(NF-3), $(NF-2), $(NF-1)}')"
    printf 'BASELINE db bytes=%s\n' "$(wc -c < "$DB")" > "$S/tsp_navdb_baseline.txt"
else
    echo "live db ABSENT - the engine will create it"
    echo "BASELINE db bytes=0" > "$S/tsp_navdb_baseline.txt"
fi

echo
echo "########## 4. CLEAN CAPTURE, LOADS ONLY ##########"
A="$S/tsp_hitch_archive_$STAMP"; n=0
for d in "$S"/tsp_ring.[0-9]*; do
    [ -f "$d" ] || continue
    mkdir -p "$A"; cp -p "$d" "$A/" && rm -f "$d" && n=$((n+1))
done
echo "dumps archived: $n"
# 1000 ms so only a real load arms the ring. A 60 ms startup spike was burning the
# first dump and the 900-frame cooldown then ran straight through the save load.
printf 'TSP_RING_TRIG=1000\nTSP_RING_MAX=12\n' > "$S/tsp_ring.conf"
touch "$S/tsp_ktxwarm_off"
if [ -f "$S/tsp_ring_off" ]; then mv "$S/tsp_ring_off" "$S/tsp_ring_off.parked-$STAMP"; fi
if [ -s "$G/openmw_log.txt" ]; then mv "$G/openmw_log.txt" "$G/openmw_log.txt.pre-$STAMP"; fi
sync

echo
echo "########## READY CHECK ##########"
F=0
V="$(sed -n 's/^write to navmeshdb = \(.*\)$/\1/p' "$CFG")"
if [ "$V" = "true" ]; then echo "  OK   write to navmeshdb = true"; else echo "  FAIL value is [$V]"; F=1; fi
echo "  OK   ring trigger: $(tr '\n' ' ' < "$S/tsp_ring.conf")"
if [ -f "$S/tsp_ring_off" ]; then echo "  FAIL profiler off"; F=1; else echo "  OK   profiler enabled"; fi
if ls "$S"/tsp_ring.[0-9]* >/dev/null 2>&1; then echo "  FAIL dumps present"; F=1; else echo "  OK   dump slots free"; fi
if [ -s "$G/openmw_log.txt" ]; then echo "  FAIL log not empty"; F=1; else echo "  OK   log clean"; fi
echo
[ "$F" -eq 0 ] && echo "READY" || echo "NOT READY"
REMOTE

echo
echo "=================================================================="
echo "  TWO cycles, same save, same route. Do not re-run this script"
echo "  between them - both loads must land under one arming."
echo
echo "  CYCLE 1: launch 'Morrowind', load the save into an exterior,"
echo "           walk 60 s, quit through the menu."
echo "  CYCLE 2: launch again, load the SAME save, SAME route, 60 s,"
echo "           quit through the menu."
echo
echo "  Then:  bash ~/Downloads/tsp_prun.sh"
echo "=================================================================="
echo
echo "With the trigger at 1000 ms only real loads arm the ring, so"
echo "tsp_ring.1 is cycle 1's load and tsp_ring.2 is cycle 2's."
echo
echo "THE PREDICTION: cycle 2's 0-5 s bucket should be materially better"
echo "than cycle 1's - fewer majflt/s, lower faulting %, shorter load."
echo "If the two are the same, navmesh caching is not the cause and I was"
echo "wrong again. Reference, TSP_KTX=1 with a cold cache:"
echo "    162.7 majflt/s   50.0% faulting   worst 201 ms   load 22.2 s"
echo
echo "Also check the db actually grew, which proves writing happened:"
echo "  ssh -n $TSP 'cat /mnt/SDCARD/tsp_navdb_baseline.txt; printf \"now  db bytes=%s\\n\" \"\$(wc -c < /mnt/UDISK/openmw-nav/navmesh.db)\"; ls -l /mnt/UDISK/openmw-nav/navmesh.db'"
echo
echo "Revert:  ssh -n $TSP \"sed -i 's/^write to navmeshdb = true\$/write to navmeshdb = false/' '/mnt/SDCARD/data/ports/openmw/config/settings.cfg'\""
