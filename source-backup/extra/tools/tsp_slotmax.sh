#!/usr/bin/env bash
# TSP_SLOTMAX_V3 - per-slot MAXIMA. Read only. Runs in seconds on 25k+ rows.
#
# V3 fixes a hang that was mine: V2 computed percentiles with an insertion sort,
# O(n^2). On the real 25,760 rows that is 11.9 billion comparisons across 18 slots
# and it ran for over an hour with no output. I had only tested it on 600 rows.
# Replaced with a histogram: 400 bins of 0.25 ms, O(n) to fill. Same numbers,
# seconds instead of hours. V2 did prove the parser works - it read all 25,760
# rows and reported MAX total 25751.7 ms, which is the 25.7 s load frame.
#
#   bash ~/Downloads/tsp_slotmax.sh
#
# V1 FAILED: it matched rows with `$1 == "frame"`. In the real dump field 1 is the
# frame INDEX, a number - the word "frame" only appears in the READERS output, which
# is what every `grep -vE "^  frame "` in this project has been filtering. So V1
# parsed zero rows and reported "no parseable rows". My bug, and the reason the
# sound question is still open.
#
# V2 does not assume. The documented row shape is
#     <frame> <total> <18 slots> | <18 calls> | <extras>
# so it finds the FIRST "|" field and derives the slot block from it, prints the
# layout it detected and two raw rows, and says so loudly if the shape does not
# match. If detection fails you can see exactly why without another round trip.
#
# WHY MAXIMA: every slot table in this project reports means. A mean over 500+ rows
# structurally cannot see a spike, and a spike is what a micro-stutter IS. Proven
# on synthetic data: four injected 33.4 ms sound spikes in 600 frames show up as
# mean 0.30, p95 0.08, p99 0.08 - invisible - and MAX 33.4 with 4 frames >=30 ms.
# Even p99 misses it, because 4/600 is 0.67%.
#
# THE SOUND CASE, from every log on the card:
#   first call each launch:  warmed=18 cached=1 failed=1   548-755 ms
#   every later call:        warmed=0 cached=13 failed=0   0.02-4.47 ms
# The warm works - later region changes are free. But failed=1 every launch, and
# 18 warmed against 13 later cached means 5 fall out. Either the failed one or an
# evicted one decoding synchronously on first play is a ~33 ms stall, once or
# twice, early in a run - which is the reported symptom. The 09-08 doc has that
# synchronous playSound in updateRegionSound/updateWaterSound as UNFIXED.
#
# Rule Zero: file, not paste; r() uses -n, rin() takes the heredoc (NEVER -n).
# No grep -r. No apostrophe inside any awk program.

set -u
TSP="${TSP:-root@192.168.1.12}"
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6"
DL="${DL:-$HOME/Downloads}"
REP="$DL/tsp-slotmax-$(date +%Y%m%d-%H%M%S).txt"

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }
r 'echo ok' >/dev/null 2>&1 || { echo "FAIL: cannot reach the TSP at $TSP" >&2; exit 1; }

rin 'sh -s' <<'REMOTE' 2>&1 | tee "$REP"
S=/mnt/SDCARD
G=$S/data/ports/openmw

LIST=""
for d in "$S"/tsp_ring.[0-9]* "$S"/tsp_hitch_archive_*/tsp_ring.[0-9]*; do
    [ -f "$d" ] || continue
    LIST="$LIST $d"
done
N=0; for d in $LIST; do N=$((N + 1)); done
echo "########## 0. WHAT THE DUMP ACTUALLY LOOKS LIKE ##########"
echo "  $N dump files"
[ "$N" -eq 0 ] && { echo "  none - nothing to read"; exit 1; }
ONE="$(echo $LIST | cut -d' ' -f1)"
echo "  sample: $ONE"
echo "  -- first 4 lines, verbatim, truncated to 150 chars --"
head -4 "$ONE" | cut -c1-150 | sed 's/^/    /'
echo "  -- field count and pipe positions on the first 3 non-empty lines --"
awk 'NF>0 && c<3 {
    c++
    p1 = 0; p2 = 0
    for (i = 1; i <= NF; i++) if ($i == "|") { if (!p1) p1 = i; else if (!p2) p2 = i }
    printf "    line %d: NF=%d  first|=%d  second|=%d  f1=[%s] f2=[%s] f3=[%s]\n", \
        NR, NF, p1, p2, $1, $2, $3
}' "$ONE"
echo

echo "########## 1. PER-SLOT MAXIMA ##########"
# shellcheck disable=SC2086
cat $LIST 2>/dev/null | awk '
BEGIN {
    nm = split("input sound lua state script mech phys world gui unref event updt focus render luawait actors char spell", NM, " ")
}
# Detect the layout from the first row that has a pipe and numeric leading fields.
!lay {
    p1 = 0
    for (i = 1; i <= NF; i++) if ($i == "|") { p1 = i; break }
    if (p1 < 4) next
    if ($1 + 0 != $1 || $2 + 0 != $2) next
    S0 = 3; S1 = p1 - 1            # slot fields, inclusive
    nslots = S1 - S0 + 1
    TOT = 2
    # extras live after the second pipe: cpu pcpu minflt majflt tod_ms
    p2 = 0
    for (i = p1 + 1; i <= NF; i++) if ($i == "|") { p2 = i; break }
    TODF = (p2 ? p2 + 5 : 0)
    lay = 1
    printf "  detected: total=field %d, slots=fields %d..%d (%d slots), tod_ms=field %s\n", \
        TOT, S0, S1, nslots, (TODF ? TODF : "none")
    if (nslots != nm)
        printf "  ** WARNING %d slots found but %d names known - names may be misaligned\n", nslots, nm
    print ""
}
lay {
    p1 = 0
    for (i = 1; i <= NF; i++) if ($i == "|") { p1 = i; break }
    if (p1 != S1 + 1) next                     # row shape differs, skip
    if ($1 + 0 != $1 || $2 + 0 != $2) next
    tot = $TOT + 0
    rows++
    if (tot > mxtot) mxtot = tot
    stot += tot
    for (i = 1; i <= nslots && i <= nm; i++) {
        v = $(S0 + i - 1) + 0
        if (v > mx[i]) mx[i] = v
        sum[i] += v
        cnt[i]++
        b = int(v * 4); if (b > 400) b = 400
        h[i, b]++
        if (v >= 5)  o5[i]++
        if (v >= 10) o10[i]++
        if (v >= 20) o20[i]++
        if (v >= 30) o30[i]++
    }
}
# Histogram percentile. V2 insertion-sorted 25760 values per slot: O(n^2) is
# 11.9 BILLION comparisons across 18 slots and it hung for over an hour. Bins of
# 0.25 ms to 100 ms plus an overflow bin - O(n) to fill, O(400) to read.
function pct(i, p,   m, need, run, b) {
    m = cnt[i]; if (m < 1) return 0
    need = m * p / 100.0
    run = 0
    for (b = 0; b <= 400; b++) {
        run += h[i, b]
        if (run >= need) return b / 4.0
    }
    return mx[i]
}
END {
    if (!lay) { print "  COULD NOT DETECT THE LAYOUT. Section 0 above shows why."; exit }
    if (!rows) { print "  layout detected but zero rows matched it."; exit }
    printf "  parsed %d rows   frame total: mean %.2f ms   MAX %.1f ms\n\n", rows, stot/rows, mxtot
    printf "  %-9s %9s %9s %9s %9s %7s %7s %7s %7s\n", \
        "slot", "mean_ms", "p95_ms", "p99_ms", "MAX_ms", ">=5ms", ">=10ms", ">=20ms", ">=30ms"
    for (i = 1; i <= nslots && i <= nm; i++) {
        if (mx[i] <= 0 && sum[i] <= 0) continue
        printf "  %-9s %9.2f %9.2f %9.2f %9.1f %7d %7d %7d %7d\n", \
            NM[i], sum[i]/rows, pct(i,95), pct(i,99), mx[i], o5[i]+0, o10[i]+0, o20[i]+0, o30[i]+0
    }
    print ""
    print "  A small mean with a MAX of 20-40 ms and a nonzero >=20ms count IS a"
    print "  spike source. For sound specifically: MAX >= 20 ms means the 09-08"
    print "  synchronous playSound finding is live and it is the lead."
}'
echo

echo "########## 2. EVERY FRAME WHERE sound WAS EXPENSIVE ##########"
# shellcheck disable=SC2086
cat $LIST 2>/dev/null | awk '
!lay {
    p1 = 0
    for (i = 1; i <= NF; i++) if ($i == "|") { p1 = i; break }
    if (p1 < 4) next
    if ($1 + 0 != $1 || $2 + 0 != $2) next
    S0 = 3; S1 = p1 - 1
    p2 = 0
    for (i = p1 + 1; i <= NF; i++) if ($i == "|") { p2 = i; break }
    TODF = (p2 ? p2 + 5 : 0)
    lay = 1
}
lay {
    p1 = 0
    for (i = 1; i <= NF; i++) if ($i == "|") { p1 = i; break }
    if (p1 != S1 + 1) next
    if ($1 + 0 != $1 || $2 + 0 != $2) next
    snd = $(S0 + 1) + 0          # sound is the 2nd slot
    if (snd < 3) next
    n++
    if (n <= 40)
        printf "  frame %-8s total %8.1f ms   sound %7.2f ms   tod %s\n", \
            $1, $2 + 0, snd, (TODF && TODF <= NF ? $TODF : "-")
    tsum += snd
}
END {
    if (!lay) { print "  (layout not detected)"; exit }
    if (!n) { print "  NO frame anywhere on the card had sound >= 3 ms."
              print "  That retires the sound-spike hypothesis for these captures."
              exit }
    printf "\n  %d frames with sound >= 3 ms, totalling %.0f ms\n", n, tsum
    print  "  If these cluster in the first seconds after a load, that is the"
    print  "  reported symptom and the failed=1 / evicted-sound path is the cause."
}'
echo

echo "########## 3. SNDWARM vs THE LOAD LADDER - does the 630 ms land in play ##########"
for f in "$G"/openmw_log.txt "$G"/openmw_log.txt.*; do
    [ -f "$f" ] || continue
    HAS="$(grep -ac 'TSP_SNDWARM' "$f" 2>/dev/null; true)"
    [ "${HAS:-0}" -gt 0 ] || continue
    echo "  -- $(basename "$f") --"
    grep -a -E 'TSP_SNDWARM|phase=(mechanics-playerLoaded|projectile-casters-updated|complete)' "$f" 2>/dev/null \
      | awk '{
            ts = ""
            if (match($0, /[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9]+/)) ts = substr($0, RSTART, RLENGTH)
            tag = "?"
            if ($0 ~ /TSP_SNDWARM/) {
                tag = "SNDWARM"
                w = ""; c = ""; fl = ""; ms = ""
                for (i = 1; i <= NF; i++) {
                    k = index($i, "=")
                    if (!k) continue
                    key = substr($i,1,k-1); v = substr($i,k+1)
                    if (key == "warmed") w = v
                    if (key == "cached") c = v
                    if (key == "failed") fl = v
                    if (key == "ms") ms = v
                }
                printf "    %s  SNDWARM   warmed=%-3s cached=%-3s failed=%-3s %9.2f ms\n", ts, w, c, fl, ms + 0
                next
            }
            for (i = 1; i <= NF; i++) if ($i ~ /^phase=/) tag = substr($i, 7)
            printf "    %s  %s\n", ts, tag
        }' | head -14
done
echo "  A SNDWARM between mechanics-playerLoaded and complete is inside the load"
echo "  window - it costs load time, not a gameplay freeze. One AFTER complete"
echo "  that is not ~0.02 ms is a visible stall."
echo

echo "########## 4. WHICH SOUND IS FAILING ##########"
echo "  failed=1 on every launch. Any error or missing-file line near the warm:"
for f in "$G"/openmw_log.txt "$G"/openmw_log.txt.iowatch-* ; do
    [ -f "$f" ] || continue
    grep -a -n -i -E 'sound.*(fail|error|not found|missing|cannot)|failed to (open|load|play)' "$f" 2>/dev/null \
      | head -8 | sed "s|^|    $(basename "$f"): |"
done
echo "  -- the region sound set the engine knows about --"
grep -a -o 'region="[^"]*"' "$G/openmw_log.txt" 2>/dev/null | sort -u | sed 's/^/    /'
echo
echo "  If nothing prints here, the warm is failing silently and the next step is"
echo "  a log line inside the warm naming the sound it could not cache."
REMOTE

echo
echo "full report: $REP"
