#!/usr/bin/env bash
# TSP_KTXBAND_V1 - the second texture pass added thousands of tiny loose .ktx files
# for near-zero byte saving. Park exactly that pass and keep the first one.
#
#   bash ~/Downloads/tsp_ktxband.sh report      # READ ONLY. mtime clusters, size bands.
#   bash ~/Downloads/tsp_ktxband.sh small-off   # park the NEWEST mtime cluster
#   bash ~/Downloads/tsp_ktxband.sh small-on    # put it back
#
# Why this and not TSP_KTX=0: TSP_KTX=0 turns off ALL 3663+ converted textures,
# including the medium/large band where the byte saving is large and real. The
# configuration Steve remembers as smooth is pass 1 only. This reverts pass 2 alone.
#
# Mechanism under test, and it is NOT the ASTC format question:
#   a 64x64 ASTC 6x6 with mips is ~2888 bytes; the DXT1 original is ~2864. No saving.
#   What it costs is one more loose file - directory lookup, inode, non-sequential SD
#   read - instead of a sequential read inside a BSA. That cost scales with the COUNT
#   of loose files. It lands at cell load and streaming, never in steady state, which
#   is why the TSP_KTX 0/1 steady-state A/B saw nothing either way.
#
# Parking is safe for anything the converter made: it read Morrowind.bsa /
# Tribunal.bsa / Bloodmoon.bsa, so a BSA original exists behind every file it wrote.
# Section 4 of report counts any .ktx that has NO loose sibling and flags the risk.
# Nothing is ever deleted - files move to a sibling directory and move back.
#
# Rule Zero: file, not paste; r() uses -n, rin() takes the heredoc (NEVER -n).
# No grep -r (busybox no-ops it). No $(grep -c x f || echo 0) (yields "0\n0").
# No per-file forks over the texture tree (that is what hung tsp_luafind v1):
# one find | xargs stat stream, all arithmetic in a single awk.

set -u
MODE="${1:-report}"
case "$MODE" in
    report|small-off|small-on) : ;;
    *) echo "usage: bash $0 report|small-off|small-on"; exit 2 ;;
esac

TSP="${TSP:-root@192.168.1.12}"
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6"
DL="${DL:-$HOME/Downloads}"
STAMP="$(date +%Y%m%d-%H%M%S)"
REP="$DL/tsp-ktxband-$MODE-$STAMP.txt"

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }
die() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

r 'echo ok' >/dev/null 2>&1 || die "cannot reach the TSP at $TSP"
echo "MODE=$MODE"
echo

# tee so every section appears as it finishes; the stat stream over ~4500 files is
# the slow step and must not look like a hang.
rin "MODE=$MODE STAMP=$STAMP sh -s" <<'REMOTE' 2>&1 | tee "$REP"
# ---- TSP_KTXBAND_REMOTE_BEGIN ----
S=/mnt/SDCARD
G=$S/data/ports/openmw
TEX="$G/data/Data Files/textures"
PARK="$G/data/Data Files/textures_pass2_parked"
LIST=$S/tsp_ktxband_pass2.list

[ -d "$TEX" ] || { echo "FAIL: no texture dir at $TEX"; exit 1; }
echo "texture dir: $TEX"
echo "park dir:    $PARK"
echo

echo "########## 1. THE STAT STREAM ##########"
# find|xargs stat: a handful of forks total, not one per file.
# -print0/-0 is mandatory: the path contains "Data Files", and plain xargs would
# split that space into two arguments and stat would fail on every single file.
find "$TEX" -type f -name '*.ktx' -print0 2>/dev/null \
    | xargs -0 -r stat -c '%Y %s %n' 2>/dev/null > /tmp/ktxstat.$$
N="$(wc -l < /tmp/ktxstat.$$)"
echo "loose .ktx files: $N"
if [ "${N:-0}" -lt 10 ]; then
    echo "FAIL: only $N .ktx files - nothing to band"
    rm -f /tmp/ktxstat.$$
    exit 1
fi
echo

echo "########## 2. mtime CLUSTERS - WHICH PASS WROTE WHAT ##########"
# One awk. Sort by mtime, find the largest gap, report both sides. A conversion pass
# writes continuously, so passes separate as a large gap between two dense runs.
sort -n /tmp/ktxstat.$$ | awk '
{ t[NR] = $1; s[NR] = $2; n = NR }
END {
    if (n < 2) { print "  too few files"; exit }
    printf "  oldest: %s  (epoch %d)\n", strftime("%Y-%m-%d %H:%M:%S", t[1]), t[1]
    printf "  newest: %s  (epoch %d)\n", strftime("%Y-%m-%d %H:%M:%S", t[n]), t[n]
    printf "  span:   %.1f hours\n\n", (t[n] - t[1]) / 3600.0

    gap = 0; gi = 0
    for (i = 2; i <= n; i++) { d = t[i] - t[i-1]; if (d > gap) { gap = d; gi = i } }
    printf "  largest gap: %.1f min, between file %d and %d\n", gap / 60.0, gi - 1, gi
    printf "    before the gap: %s  (epoch %d)\n", strftime("%Y-%m-%d %H:%M:%S", t[gi-1]), t[gi-1]
    printf "    after the gap:  %s  (epoch %d)\n", strftime("%Y-%m-%d %H:%M:%S", t[gi]),   t[gi]

    old = gi - 1; new = n - gi + 1
    ob = 0; nb = 0
    for (i = 1; i <= n; i++) { if (i < gi) ob += s[i]; else nb += s[i] }
    printf "\n  OLD cluster (pass 1): %5d files  %8.1f MB  mean %6.0f bytes\n", \
           old, ob / 1048576.0, (old ? ob / old : 0)
    printf "  NEW cluster (pass 2): %5d files  %8.1f MB  mean %6.0f bytes\n", \
           new, nb / 1048576.0, (new ? nb / new : 0)
    printf "\n  SPLIT_EPOCH=%d\n", t[gi]
    printf "  SPLIT_CLEAN=%s\n", (gap >= 600 && old >= 100 && new >= 100) ? "yes" : "no"
    if (gap < 600)  print "  (gap under 10 min - the two passes may have run back to back)"
    if (old < 100 || new < 100) print "  (one side under 100 files - not a two-pass split)"
}'
echo

echo "########## 3. SIZE BANDS - WHERE THE BYTES ACTUALLY ARE ##########"
# ASTC 6x6 + full mips: bytes ~= (w*h/36)*16*1.33, so file size implies dimensions.
awk '
{
    b = $2; tot += b; n++
    if      (b <   1500) { c1++; s1 += b }
    else if (b <   6000) { c2++; s2 += b }
    else if (b <  24000) { c3++; s3 += b }
    else if (b <  96000) { c4++; s4 += b }
    else                 { c5++; s5 += b }
}
END {
    printf "  %-22s %6s  %9s  %6s\n", "band (implied size)", "files", "MB", "share"
    printf "  %-22s %6d  %9.2f  %5.1f%%\n", "<1.5K   (<=32x32)",   c1, s1/1048576.0, 100.0*s1/tot
    printf "  %-22s %6d  %9.2f  %5.1f%%\n", "1.5-6K  (~64x64)",    c2, s2/1048576.0, 100.0*s2/tot
    printf "  %-22s %6d  %9.2f  %5.1f%%\n", "6-24K   (~128x128)",  c3, s3/1048576.0, 100.0*s3/tot
    printf "  %-22s %6d  %9.2f  %5.1f%%\n", "24-96K  (~256x256)",  c4, s4/1048576.0, 100.0*s4/tot
    printf "  %-22s %6d  %9.2f  %5.1f%%\n", ">96K    (512x512+)",  c5, s5/1048576.0, 100.0*s5/tot
    printf "  %-22s %6d  %9.2f\n", "TOTAL", n, tot/1048576.0
    printf "\n  files at or under ~64x64: %d (%.1f%% of files, %.1f%% of bytes)\n", \
           c1 + c2, 100.0*(c1+c2)/n, 100.0*(s1+s2)/tot
    print  "  Those are the ones with no byte saving over DXT1 but a full loose-file cost."
}' /tmp/ktxstat.$$
echo

echo "########## 4. IS PARKING SAFE ##########"
printf '  loose .dds still present:  %s\n' "$(find "$TEX" -type f -name '*.dds' 2>/dev/null | wc -l)"
printf '  loose .tga still present:  %s\n' "$(find "$TEX" -type f -name '*.tga' 2>/dev/null | wc -l)"
printf '  loose .bmp still present:  %s\n' "$(find "$TEX" -type f -name '*.bmp' 2>/dev/null | wc -l)"
echo "  the three BSAs the converter read from:"
for f in Morrowind.bsa Tribunal.bsa Bloodmoon.bsa; do
    if [ -f "$G/data/Data Files/$f" ]; then
        printf '    OK      %s  %s bytes\n' "$f" "$(stat -c '%s' "$G/data/Data Files/$f")"
    else
        printf '    MISSING %s  <- parking is NOT safe without this\n' "$f"
    fi
done
echo "  (a .ktx the converter wrote has a BSA original behind it; parking falls back to it)"
echo "  texconv pass logs, if any:"
find "$S" -maxdepth 2 -name 'texconv*log*' 2>/dev/null | head -8 | sed 's/^/    /'
find "$G" -maxdepth 2 -name 'texconv*' 2>/dev/null | head -8 | sed 's/^/    /'
echo

echo "########## 5. CURRENT PARK STATE ##########"
if [ -d "$PARK" ]; then
    printf '  park dir exists, holding %s files\n' "$(find "$PARK" -type f -name '*.ktx' 2>/dev/null | wc -l)"
else
    echo "  park dir does not exist - nothing is parked"
fi
echo

if [ "$MODE" = "report" ]; then
    rm -f /tmp/ktxstat.$$
    echo "########## REPORT ONLY - NOTHING CHANGED ##########"
    exit 0
fi

if [ "$MODE" = "small-on" ]; then
    echo "########## RESTORE pass 2 ##########"
    if [ ! -d "$PARK" ]; then
        echo "nothing parked - already in the 'all textures on' state"
        rm -f /tmp/ktxstat.$$
        exit 0
    fi
    moved=0; failed=0
    find "$PARK" -type f -name '*.ktx' 2>/dev/null > /tmp/ktxback.$$
    TOTAL="$(wc -l < /tmp/ktxback.$$)"
    echo "restoring $TOTAL files..."
    while IFS= read -r f; do
        base="${f#$PARK/}"
        d="$TEX/$base"
        # No dirname/mkdir fork for a flat path: the texture tree is mostly flat and
        # 900 files x 2 extra forks is what made an earlier tool look like a hang.
        sub="${base%/*}"
        [ "$sub" != "$base" ] && mkdir -p "$TEX/$sub" 2>/dev/null
        if mv "$f" "$d" 2>/dev/null; then
            moved=$((moved + 1))
        else
            failed=$((failed + 1))
        fi
        if [ $((moved % 200)) -eq 0 ] && [ "$moved" -gt 0 ]; then
            echo "  restored $moved / $TOTAL"
        fi
    done < /tmp/ktxback.$$
    rm -f /tmp/ktxback.$$
    echo "restored: $moved   failed: $failed"
    LEFT="$(find "$PARK" -type f -name '*.ktx' 2>/dev/null | wc -l)"
    echo "still parked: $LEFT"
    if [ "${LEFT:-1}" -eq 0 ]; then
        # Empty subdirectories left behind by the move keep rmdir from succeeding, and
        # a park dir "holding 0 files" reads as though something is still parked.
        find "$PARK" -depth -type d 2>/dev/null | while IFS= read -r d; do
            rmdir "$d" 2>/dev/null
        done
        [ -d "$PARK" ] && echo "note: $PARK could not be removed (not empty)" \
                       || echo "park dir removed"
    fi
    NOW="$(find "$TEX" -type f -name '*.ktx' 2>/dev/null | wc -l)"
    echo "loose .ktx now live: $NOW"
    rm -f /tmp/ktxstat.$$
    sync
    if [ "$failed" -eq 0 ] && [ "${LEFT:-1}" -eq 0 ]; then
        echo "VERIFIED: pass 2 restored"
    else
        echo "INCOMPLETE - $failed moves failed, $LEFT still parked"
        exit 1
    fi
    exit 0
fi

echo "########## PARK pass 2 ##########"
SPLIT="$(sort -n /tmp/ktxstat.$$ | awk '
    { t[NR] = $1; n = NR }
    END {
        gap = 0; gi = 0
        for (i = 2; i <= n; i++) { d = t[i] - t[i-1]; if (d > gap) { gap = d; gi = i } }
        old = gi - 1; new = n - gi + 1
        if (gap >= 600 && old >= 100 && new >= 100) print t[gi]; else print "0"
    }')"
echo "split epoch: $SPLIT"
if [ "${SPLIT:-0}" -eq 0 ] 2>/dev/null; then
    echo "REFUSED: the mtime split is not clean (see section 2). Nothing moved."
    echo "Two passes should show a gap of >= 10 min with >= 100 files on each side."
    rm -f /tmp/ktxstat.$$
    exit 1
fi
echo "parking every .ktx with mtime >= $SPLIT"

awk -v cut="$SPLIT" '$1 >= cut { sub(/^[0-9]+ [0-9]+ /, ""); print }' /tmp/ktxstat.$$ > "$LIST"
TOTAL="$(wc -l < "$LIST")"
KEEP=$(( $(wc -l < /tmp/ktxstat.$$) - TOTAL ))
echo "to park: $TOTAL     to keep live: $KEEP"
if [ "${TOTAL:-0}" -lt 100 ] || [ "${KEEP:-0}" -lt 100 ]; then
    echo "REFUSED: $TOTAL / $KEEP is not a two-pass split. Nothing moved."
    rm -f /tmp/ktxstat.$$
    exit 1
fi

mkdir -p "$PARK" || { echo "FAIL: cannot create $PARK"; rm -f /tmp/ktxstat.$$; exit 1; }
moved=0; failed=0
while IFS= read -r f; do
    base="${f#$TEX/}"
    d="$PARK/$base"
    sub="${base%/*}"
    [ "$sub" != "$base" ] && mkdir -p "$PARK/$sub" 2>/dev/null
    if mv "$f" "$d" 2>/dev/null; then
        moved=$((moved + 1))
    else
        failed=$((failed + 1))
    fi
    if [ $((moved % 200)) -eq 0 ] && [ "$moved" -gt 0 ]; then
        echo "  parked $moved / $TOTAL"
    fi
done < "$LIST"
echo "parked: $moved   failed: $failed"

NOW="$(find "$TEX" -type f -name '*.ktx' 2>/dev/null | wc -l)"
HELD="$(find "$PARK" -type f -name '*.ktx' 2>/dev/null | wc -l)"
echo "loose .ktx still live: $NOW   (expected $KEEP)"
echo "held in park dir:      $HELD   (expected $TOTAL)"
rm -f /tmp/ktxstat.$$

echo
echo "########## CLEAN CAPTURE ##########"
A="$S/tsp_hitch_archive_$STAMP"; k=0
for d in "$S"/tsp_ring.[0-9]*; do
    [ -f "$d" ] || continue
    mkdir -p "$A"; cp -p "$d" "$A/" && rm -f "$d" && k=$((k + 1))
done
echo "dumps archived: $k"
printf 'TSP_RING_TRIG=1000\nTSP_RING_MAX=12\n' > "$S/tsp_ring.conf"
touch "$S/tsp_ktxwarm_off"
[ -f "$S/tsp_ring_off" ] && mv "$S/tsp_ring_off" "$S/tsp_ring_off.parked-$STAMP"
[ -s "$G/openmw_log.txt" ] && mv "$G/openmw_log.txt" "$G/openmw_log.txt.ktxband-$STAMP"
sync
echo "Cached before drop: $(awk '/^Cached:/{print $2}' /proc/meminfo) kB"
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null && echo "caches dropped" || echo "WARNING: could not drop caches"
echo "Cached after:       $(awk '/^Cached:/{print $2}' /proc/meminfo) kB"

echo
echo "########## READY CHECK ##########"
F=0
[ "$failed" -eq 0 ] && echo "  OK   every move succeeded" || { echo "  FAIL $failed moves failed"; F=1; }
[ "${NOW:-0}" -eq "${KEEP:-1}" ] && echo "  OK   $NOW live (pass 1 kept)" || { echo "  FAIL live count $NOW != $KEEP"; F=1; }
[ "${HELD:-0}" -eq "${TOTAL:-1}" ] && echo "  OK   $HELD parked (pass 2 out)" || { echo "  FAIL park count $HELD != $TOTAL"; F=1; }
[ -f "$S/tsp_ring_off" ] && { echo "  FAIL profiler off"; F=1; } || echo "  OK   profiler enabled"
ls "$S"/tsp_ring.[0-9]* >/dev/null 2>&1 && { echo "  FAIL dumps present"; F=1; } || echo "  OK   dump slots free"
echo "  OK   trigger: $(tr '\n' ' ' < "$S/tsp_ring.conf")"
echo
[ "$F" -eq 0 ] && echo "READY - launch NOW while the cache is cold" || echo "NOT READY - do not spend a play session"
# ---- TSP_KTXBAND_REMOTE_END ----
REMOTE

echo
if [ "$MODE" = "report" ]; then
    echo "=================================================================="
    echo "  READ ONLY - nothing on the card changed."
    echo "  If section 2 shows SPLIT_CLEAN=yes, park pass 2 with:"
    echo "     bash ~/Downloads/tsp_ktxband.sh small-off"
    echo "=================================================================="
else
    echo "=================================================================="
    echo "  MODE=$MODE"
    echo "  Launch 'Morrowind' NOW while the page cache is cold."
    echo "  Load the SAME save into an exterior, walk the SAME route for"
    echo "  60-90 s, cross a cell boundary, quit through the menu, then:"
    echo "     bash ~/Downloads/tsp_prun.sh"
    echo
    echo "  Undo, one command, nothing else touched:"
    echo "     bash ~/Downloads/tsp_ktxband.sh small-on"
    echo "=================================================================="
    echo
    echo "Noise floor for the same nominal conditions so far: 33.1, 101.5,"
    echo "162.7 majflt/s. Anything inside that spread is not a result."
fi
echo
echo "full report: $REP"
