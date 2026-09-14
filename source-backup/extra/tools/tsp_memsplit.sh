#!/usr/bin/env bash
# TSP_MEMSPLIT_V1 - split the 193 MB. Two loads, no play session, no rebuild.
#
#   bash ~/Downloads/tsp_memsplit.sh a      # RECORDMEM on, textures ON
#   ... load your save, reach gameplay, quit through the menu ...
#   bash ~/Downloads/tsp_memsplit.sh pull a
#
#   bash ~/Downloads/tsp_memsplit.sh b      # RECORDMEM on, textures OFF
#   ... same save, same load, quit ...
#   bash ~/Downloads/tsp_memsplit.sh pull b   # prints a vs b side by side
#
#   bash ~/Downloads/tsp_memsplit.sh off    # restore: RECORDMEM unset, TSP_KTX=1
#
# ============================================================================
# WHAT THE 09-10 CAPTURE ESTABLISHED
# ============================================================================
# RSS grew +443.5 MB in the first 32 s and then went FLAT: from elap 66 to 186,
# two solid minutes of walking, the per-interval deltas were -0.6 -3.6 +1.5 -9.3
# -2.3 +0.1 +0.9 +0.3 +0.7 +0.1 +0.1 +4.1 MB. There is NO leak while walking.
# My exploreCell/global-map-overlay theory is dead, and the engine killed it twice:
# pending_removal_cams printed ZERO lines, and TSP_GMAP_MEM_V1 fired once at load
# with globalmap_read_kb=4 (it was 3223 before the 09-09 fix - that fix works).
#
# The whole thing is ONE phase gap during load:
#
#   23:36:32.217  mechanics-playerLoaded        inuse_kb=255710
#   23:36:45.722  projectile-casters-updated    inuse_kb=453533   +197,823 kB
#
# 193 MB in 13.5 s. That is 97% of everything the load allocates, and 13.5 s of a
# 23.3 s load frame, so it is also most of the loading bar. It never comes back,
# total lands at ~430-500 MB on a 1 GB device, the kernel thrashes that working set
# against swap for the rest of the session, and THAT is the hitching.
#
# It is also a regression: the 09-09 doc records load 1 at 271 MB inuse. Tonight
# load 1 (generation=1) completes at 444 MB. +173 MB.
#
# ============================================================================
# WHAT IS IN THAT WINDOW, AND HOW THESE TWO RUNS SPLIT IT
# ============================================================================
# Between those two phases the engine reads the remaining save records AND builds
# the initial scene (which is where textures are loaded and uploaded). Two
# candidates, and each run isolates one:
#
#   run a   TSP_RECORDMEM=1, textures ON.  Per-save-record-type byte accounting,
#           already compiled in and gated (SHIP-STATE doc: "~3x load time - leave
#           unset"). At 09-09 record reading came to ~60 MB (REC_CSTA +60,421).
#           If it is still ~60 MB, then ~130 MB of the gap is NOT records.
#
#   run b   TSP_RECORDMEM=1, TSP_KTX=0 (engine reads DDS from the three BSAs).
#           Same instrument, so the record bytes act as an internal control - they
#           must NOT change. If inuse at phase=complete drops by >100 MB, the
#           missing memory is texture data sitting in the resource cache, which
#           with TSP_NO_LOADPURGE=1 is held for the whole session. That would also
#           answer the ASTC question by the back door: a Mali driver that does not
#           take ASTC natively means gl4es decodes to RGBA, 8x larger, in glibc.
#
# Neither needs a play session. Load, reach gameplay, quit. RECORDMEM makes the
# load ~3x slower for these two runs only; off restores it.
#
# Rule Zero: file, not paste; r() uses -n, rin() takes the heredoc (NEVER -n).
# No grep -r. No $(grep -c x f || echo 0). No apostrophe inside any awk program.
# OPENMW_DEBUG_LEVEL is left alone - it is INFO and TSP_LOAD_TRACE needs it.

set -u
MODE="${1:-}"
SUB="${2:-}"
case "$MODE" in
    a|b|off) : ;;
    pull) case "$SUB" in a|b) : ;; *) echo "usage: bash $0 pull a|b"; exit 2 ;; esac ;;
    *) echo "usage: bash $0 a|b|pull a|pull b|off"; exit 2 ;;
esac

TSP="${TSP:-root@192.168.1.12}"
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6"
DL="${DL:-$HOME/Downloads}"
STAMP="$(date +%Y%m%d-%H%M%S)"

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }
die() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

r 'echo ok' >/dev/null 2>&1 || die "cannot reach the TSP at $TSP"

# ----------------------------------------------------------------------------
# arm / off  -  all three are the same conf edit with different values
# ----------------------------------------------------------------------------
if [ "$MODE" != "pull" ]; then
    case "$MODE" in
        a)   WANT_REC=1; WANT_KTX=1; LABEL="a  RECORDMEM on, textures ON" ;;
        b)   WANT_REC=1; WANT_KTX=0; LABEL="b  RECORDMEM on, textures OFF" ;;
        off) WANT_REC=0; WANT_KTX=1; LABEL="off  RECORDMEM off, textures ON (shipping state)" ;;
    esac
    REP="$DL/tsp-memsplit-arm-$MODE-$STAMP.txt"
    echo "MODE=$LABEL"
    echo

    rin "MODE=$MODE WANT_REC=$WANT_REC WANT_KTX=$WANT_KTX STAMP=$STAMP sh -s" <<'REMOTE' 2>&1 | tee "$REP"
# ---- TSP_MEMSPLIT_ARM_BEGIN ----
S=/mnt/SDCARD
G=$S/data/ports/openmw
CONF=$S/tsp_iotune.conf

[ -f "$CONF" ] || { echo "FAIL: $CONF missing"; exit 1; }
cp -p "$CONF" "$CONF.bak-memsplit-$STAMP" || { echo "FAIL: backup"; exit 1; }
echo "########## 1. CONF ##########"
echo "backed up $(basename "$CONF").bak-memsplit-$STAMP"

# TSP_RECORDMEM: set it, or remove the line entirely for the off case.
if [ "$WANT_REC" = "1" ]; then
    if grep -q '^[[:space:]]*export[[:space:]][[:space:]]*TSP_RECORDMEM=' "$CONF"; then
        sed 's/^\([[:space:]]*export[[:space:]][[:space:]]*TSP_RECORDMEM=\).*/\11/' "$CONF" > "$CONF.n1" \
            && mv "$CONF.n1" "$CONF"
    else
        printf 'export TSP_RECORDMEM=1\n' >> "$CONF"
    fi
else
    grep -v '^[[:space:]]*export[[:space:]][[:space:]]*TSP_RECORDMEM=' "$CONF" > "$CONF.n1" \
        && mv "$CONF.n1" "$CONF"
fi

# TSP_KTX: the line exists already (tsp_bisect relies on it); flip its value.
if grep -q '^[[:space:]]*export[[:space:]][[:space:]]*TSP_KTX=' "$CONF"; then
    sed "s/^\([[:space:]]*export[[:space:]][[:space:]]*TSP_KTX=\).*/\1$WANT_KTX/" "$CONF" > "$CONF.n2" \
        && mv "$CONF.n2" "$CONF"
else
    printf 'export TSP_KTX=%s\n' "$WANT_KTX" >> "$CONF"
fi

GOTR="$(sed -n 's/^[[:space:]]*export[[:space:]][[:space:]]*TSP_RECORDMEM=\(.*\)$/\1/p' "$CONF" | tail -1)"
GOTK="$(sed -n 's/^[[:space:]]*export[[:space:]][[:space:]]*TSP_KTX=\(.*\)$/\1/p' "$CONF" | tail -1)"
echo "  TSP_RECORDMEM=[${GOTR:-unset}]  want [$([ "$WANT_REC" = 1 ] && echo 1 || echo unset)]"
echo "  TSP_KTX=[${GOTK:-unset}]        want [$WANT_KTX]"

F=0
if [ "$WANT_REC" = "1" ]; then
    [ "$GOTR" = "1" ] || { echo "  FAIL RECORDMEM not set"; F=1; }
else
    [ -z "$GOTR" ] || { echo "  FAIL RECORDMEM still present as [$GOTR]"; F=1; }
fi
[ "$GOTK" = "$WANT_KTX" ] || { echo "  FAIL TSP_KTX wrong"; F=1; }

# OPENMW_DEBUG_LEVEL must be INFO or the phase ladder does not get logged at all.
DBG="$(sed -n 's/^[[:space:]]*export[[:space:]][[:space:]]*OPENMW_DEBUG_LEVEL=\(.*\)$/\1/p' "$CONF" | tail -1)"
echo "  OPENMW_DEBUG_LEVEL=[${DBG:-unset}]  (must be INFO - not touching it)"
case "${DBG:-}" in
    INFO|VERBOSE|DEBUG) echo "  OK   phase ladder will be logged" ;;
    *) echo "  FAIL OPENMW_DEBUG_LEVEL is not INFO - TSP_LOAD_TRACE will log NOTHING"; F=1 ;;
esac
if [ "$F" -ne 0 ]; then
    echo "  restoring the backup and stopping"
    cp -p "$CONF.bak-memsplit-$STAMP" "$CONF"
    exit 1
fi
echo "  VERIFIED"
grep -n 'TSP_RECORDMEM\|TSP_KTX\|OPENMW_DEBUG_LEVEL\|TSP_NO_LOADPURGE' "$CONF" | sed 's/^/    /'
echo

echo "########## 2. LOOSE TEXTURE STATE, FOR THE RECORD ##########"
printf '  loose .ktx files: %s\n' "$(find "$G/data/Data Files/textures" -name '*.ktx' 2>/dev/null | wc -l)"
echo "  (TSP_KTX=$WANT_KTX decides whether the engine reads them at all; the files"
echo "   stay where they are either way - nothing is moved by this script)"
echo

echo "########## 3. CLEAN CAPTURE ##########"
# openmw_log.txt is opened with exec >> - it APPENDS across launches, so it must
# be rotated or the reader sees the previous run mixed in.
if [ -s "$G/openmw_log.txt" ]; then
    mv "$G/openmw_log.txt" "$G/openmw_log.txt.memsplit-$MODE-$STAMP"
    echo "  log rotated to openmw_log.txt.memsplit-$MODE-$STAMP"
else
    echo "  log already empty"
fi
A="$S/tsp_hitch_archive_$STAMP"; k=0
for d in "$S"/tsp_ring.[0-9]*; do
    [ -f "$d" ] || continue
    mkdir -p "$A"; cp -p "$d" "$A/" && rm -f "$d" && k=$((k + 1))
done
echo "  ring dumps archived: $k"
touch "$S/tsp_iowatch_off"
echo "  iowatch sampler disabled for this run (one less variable)"
sync
echo "  Cached before drop: $(awk '/^Cached:/{print $2}' /proc/meminfo) kB"
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null && echo "  caches dropped" || echo "  WARNING: no drop_caches"
echo "  Cached after:       $(awk '/^Cached:/{print $2}' /proc/meminfo) kB"
echo "  swap in use:        $(awk '/^SwapTotal:/{t=$2}/^SwapFree:/{f=$2}END{print t-f}' /proc/meminfo) kB"
echo

echo "########## READY CHECK ##########"
G2=0
[ "$GOTK" = "$WANT_KTX" ] && echo "  OK   TSP_KTX=$GOTK" || { echo "  FAIL ktx"; G2=1; }
if [ "$WANT_REC" = "1" ]; then
    [ "$GOTR" = "1" ] && echo "  OK   TSP_RECORDMEM=1" || { echo "  FAIL recordmem"; G2=1; }
else
    [ -z "$GOTR" ] && echo "  OK   TSP_RECORDMEM unset" || { echo "  FAIL recordmem"; G2=1; }
fi
[ -s "$G/openmw_log.txt" ] && { echo "  FAIL log not empty"; G2=1; } || echo "  OK   log clean"
echo
if [ "$G2" -eq 0 ]; then echo "READY"; else echo "NOT READY"; fi
# ---- TSP_MEMSPLIT_ARM_END ----
REMOTE

    echo
    if [ "$MODE" = "off" ]; then
        echo "=================================================================="
        echo "  Restored to shipping state. RECORDMEM is off so loads are fast"
        echo "  again, and textures are back on."
        echo "=================================================================="
        exit 0
    fi
    echo "=================================================================="
    echo "  MODE $MODE. No play session needed."
    echo "    1. Launch Morrowind"
    echo "    2. Load your save. THE LOAD WILL BE ~3x SLOWER - that is"
    echo "       TSP_RECORDMEM counting every save record. Expected."
    echo "    3. As soon as you are standing in the world, quit through the menu"
    echo "    4. bash ~/Downloads/tsp_memsplit.sh pull $MODE"
    echo
    if [ "$MODE" = "a" ]; then
        echo "  Then run mode b for the texture half:"
        echo "    bash ~/Downloads/tsp_memsplit.sh b"
    else
        echo "  pull b will print a vs b side by side if you already pulled a."
    fi
    echo
    echo "  When done either way:  bash ~/Downloads/tsp_memsplit.sh off"
    echo "=================================================================="
    exit 0
fi

# ----------------------------------------------------------------------------
# pull
# ----------------------------------------------------------------------------
RUN="$SUB"
RAW="$DL/tsp-memsplit-raw-$RUN-$STAMP.log"
SUM="$DL/tsp-memsplit-summary-$RUN.txt"
REP="$DL/tsp-memsplit-pull-$RUN-$STAMP.txt"

rin 'sh -s' <<'REMOTE' > "$RAW" 2>&1
S=/mnt/SDCARD
G=$S/data/ports/openmw
LG=$G/openmw_log.txt
echo "### CONF"
grep -n 'TSP_RECORDMEM\|TSP_KTX\|OPENMW_DEBUG_LEVEL\|TSP_NO_LOADPURGE' "$S/tsp_iotune.conf" 2>/dev/null
echo "### LOADTRACE"
grep -a 'TSP_LOAD_TRACE' "$LG" 2>/dev/null
echo "### RECORDMEM"
grep -a 'TSP_RECORDMEM' "$LG" 2>/dev/null
echo "### OTHERMEM"
grep -a 'TSP_PLAYERANIM_MEM_V1\|TSP_GMAP_MEM_V1\|TSP_WORLDCLEAR_MEM_V1\|TSP_LOADMEM_V1\|TSP_MEMGATE_V1' "$LG" 2>/dev/null
echo "### END"
REMOTE

LT="$(grep -c 'TSP_LOAD_TRACE' "$RAW" 2>/dev/null || true)"; LT="${LT:-0}"
RM="$(grep -c 'TSP_RECORDMEM' "$RAW" 2>/dev/null || true)"; RM="${RM:-0}"
echo "run $RUN:  LOAD_TRACE lines $LT    RECORDMEM lines $RM    ($RAW)"
[ "$LT" -ge 3 ] || die "only $LT LOAD_TRACE lines - did the save actually load? (needs OPENMW_DEBUG_LEVEL=INFO)"
echo

{
echo "########## CONF AS IT RAN ##########"
sed -n '/^### CONF/,/^### LOADTRACE/p' "$RAW" | grep -v '^###' | sed 's/^/  /'
echo
echo "########## THE PHASE LADDER - WHERE THE ALLOCATION IS ##########"
awk '
/TSP_LOAD_TRACE|TSP_PLAYERANIM_MEM_V1/ {
    ts = ""; gen = ""; ph = ""; kb = ""
    if (match($0, /[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9]+/))
        ts = substr($0, RSTART, RLENGTH)
    for (i = 1; i <= NF; i++) {
        k = index($i, "=")
        if (!k) continue
        key = substr($i, 1, k - 1); val = substr($i, k + 1)
        if (key == "generation") gen = val
        if (key == "phase")      ph  = val
        if (key == "inuse_kb")   kb  = val + 0
    }
    if (ph == "" || kb == "") next
    n++
    T[n] = ts; GN[n] = gen; P[n] = ph; K[n] = kb
}
function tosec(s) {
    if (s == "") return -1
    split(s, a, ":")
    return a[1] * 3600 + a[2] * 60 + a[3]
}
END {
    if (n < 2) { print "  (fewer than 2 phases with inuse_kb)"; exit }
    printf "  %-34s %10s %11s %8s\n", "phase", "inuse_kb", "delta_kb", "gap_s"
    for (i = 1; i <= n; i++) {
        d = ""; g = ""
        if (i > 1) {
            d = sprintf("%+d", K[i] - K[i-1])
            s1 = tosec(T[i-1]); s2 = tosec(T[i])
            if (s1 >= 0 && s2 >= 0) g = sprintf("%.3f", s2 - s1)
            dd = K[i] - K[i-1]
            if (dd > big) { big = dd; bigi = i }
            tot += (dd > 0 ? dd : 0)
        }
        mark = ""
        if (i > 1 && K[i] - K[i-1] > 50000) mark = "   <<<< "
        printf "  %-34s %10d %11s %8s%s\n", (GN[i] != "" ? "g" GN[i] " " P[i] : P[i]), K[i], d, g, mark
    }
    print ""
    printf "  first %d kB -> last %d kB    net %+d kB = %+.1f MB\n", \
        K[1], K[n], K[n] - K[1], (K[n] - K[1]) / 1024.0
    if (bigi) {
        printf "  BIGGEST STEP: %s -> %s   %+d kB = %+.1f MB", \
            P[bigi-1], P[bigi], big, big / 1024.0
        s1 = tosec(T[bigi-1]); s2 = tosec(T[bigi])
        if (s1 >= 0 && s2 >= 0) printf "   over %.1f s", s2 - s1
        printf "\n"
        printf "  that is %.0f%% of all positive allocation in the ladder\n", (tot > 0 ? 100.0*big/tot : 0)
    }
    print  "  09-10 reference: mechanics-playerLoaded -> projectile-casters-updated"
    print  "                   255710 -> 453533 = +197823 kB (+193 MB) over 13.5 s"
    print  "  09-09 reference: load 1 completed at ~271 MB inuse"
}' "$RAW"

echo
echo "########## PER-RECORD-TYPE BYTES (TSP_RECORDMEM) ##########"
if [ "$RM" -eq 0 ]; then
    echo "  NO TSP_RECORDMEM LINES."
    echo "  Either TSP_RECORDMEM=1 did not reach the process (check the conf block"
    echo "  above), or this build gates it behind a different name. Without it the"
    echo "  ladder above still localises the window but cannot split it by record."
else
    # The exact field layout of TSP_RECORDMEM_V1 is not documented in the project,
    # so this does both: a generic key=value tabulation AND the raw lines, rather
    # than guessing a format and silently printing nothing.
    echo "  -- grouped by record type: the first non-numeric field on each line is"
    echo "     taken as the type, and every numeric field on that line attributed to"
    echo "     it. This is the ranked table; whatever tops it is the patch site. --"
    awk '
    /TSP_RECORDMEM/ {
        typ = ""
        for (i = 1; i <= NF; i++) {
            k = index($i, "="); if (!k) continue
            val = substr($i, k + 1)
            if (!(val + 0 == val && val != "")) { typ = $i; break }
        }
        if (typ == "") typ = "(none)"
        for (i = 1; i <= NF; i++) {
            k = index($i, "="); if (!k) continue
            key = substr($i, 1, k - 1); val = substr($i, k + 1)
            if (val + 0 == val && val != "") { g[typ SUBSEP key] += val + 0; ks[key] = 1; ty[typ] = 1 }
        }
    }
    END {
        printf "%14s  %-26s %s\n", "value", "field", "record type"
        for (t in ty) for (k in ks) if (g[t SUBSEP k] > 0) printf "%14d  %-26s %s\n", g[t SUBSEP k], k, t
    }' "$RAW" 2>/dev/null | sort -rn | head -30 | sed 's/^/     /'
    echo
    echo "  -- generic key=value tabulation, largest numeric value first --"
    awk '
    /TSP_RECORDMEM/ {
        for (i = 1; i <= NF; i++) {
            k = index($i, "=")
            if (!k) continue
            key = substr($i, 1, k - 1); val = substr($i, k + 1)
            if (val + 0 == val && val != "") { sum[key] += val + 0; cnt[key]++ }
            else { seen[key "=" val]++ }
        }
    }
    END {
        for (k in sum) printf "     %-24s total %12d   over %d lines\n", k, sum[k], cnt[k]
        print "     -- non-numeric fields seen --"
        for (k in seen) printf "     %-40s x%d\n", k, seen[k]
    }' "$RAW" | sort -k4 -rn
    echo
    echo "  -- every RECORDMEM line, verbatim (capped at 60) --"
    grep -a 'TSP_RECORDMEM' "$RAW" | head -60 | sed 's/^/     /'
fi

echo
echo "########## OTHER ENGINE MEMORY LINES ##########"
sed -n '/^### OTHERMEM/,/^### END/p' "$RAW" | grep -v '^###' | sed 's/^/  /'
} > "$REP" 2>&1

# keep a one-line summary per run so pull b can compare against pull a
COMPLETE="$(awk '/TSP_LOAD_TRACE/ && /phase=complete/ { for (i=1;i<=NF;i++) { k=index($i,"="); if (k && substr($i,1,k-1)=="inuse_kb") v=substr($i,k+1)+0 } } END { print v+0 }' "$RAW")"
BIGSTEP="$(awk '
/TSP_LOAD_TRACE|TSP_PLAYERANIM_MEM_V1/ { for (i=1;i<=NF;i++) { k=index($i,"="); if (k && substr($i,1,k-1)=="inuse_kb") { n++; K[n]=substr($i,k+1)+0 } } }
END { for (i=2;i<=n;i++) { d=K[i]-K[i-1]; if (d>b) b=d } print b+0 }' "$RAW")"
printf 'run=%s complete_kb=%s biggest_step_kb=%s stamp=%s\n' "$RUN" "$COMPLETE" "$BIGSTEP" "$STAMP" > "$SUM"

cat "$REP"

OTHER="a"; [ "$RUN" = "a" ] && OTHER="b"
OSUM="$DL/tsp-memsplit-summary-$OTHER.txt"
if [ -f "$OSUM" ]; then
    echo
    echo "=================================================================="
    echo " A vs B"
    echo "=================================================================="
    awk -v me="$SUM" -v other="$OSUM" '
    BEGIN {
        while ((getline l < me) > 0)    parse(l, "me")
        while ((getline l < other) > 0) parse(l, "ot")
        ra = (mr == "a" ? "me" : "ot"); rb = (mr == "a" ? "ot" : "me")
        printf "  %-34s %12s %12s %12s\n", "", "a (ktx ON)", "b (ktx OFF)", "difference"
        printf "  %-34s %12d %12d %+12d\n", "inuse at phase=complete (kb)", \
            C[ra], C[rb], C[rb] - C[ra]
        printf "  %-34s %12d %12d %+12d\n", "biggest single step (kb)", \
            B[ra], B[rb], B[rb] - B[ra]
        d = C[ra] - C[rb]
        print ""
        if (C[ra] == 0 || C[rb] == 0) {
            print "  one run has no phase=complete - cannot compare yet"
        } else if (d > 102400) {
            printf "  => TEXTURES. Turning them off saves %.1f MB of glibc at load.\n", d/1024.0
            print  "     With TSP_NO_LOADPURGE=1 the resource cache holds them for the whole"
            print  "     session, which is why RSS steps at load and then stays flat. It also"
            print  "     means the Mali driver is very likely NOT taking ASTC natively - gl4es"
            print  "     is decoding to RGBA, 8x larger, into the heap. Patch target: the"
            print  "     texture path, not the save records."
        } else if (d < -102400) {
            printf "  => turning textures OFF made it WORSE by %.1f MB. Unexpected;\n", -d/1024.0
            print  "     the DDS-from-BSA path is costing more than the ASTC path. Re-check"
            print  "     before acting on it."
        } else {
            printf "  => NOT TEXTURES. Only %.1f MB difference.\n", d/1024.0
            print  "     The allocation is save-record reading and scene construction. Use the"
            print  "     per-record-type table above: whatever dominates it is the patch site."
        }
    }
    function parse(l, who) {
        split(l, f, " ")
        for (i in f) {
            k = index(f[i], "=")
            if (!k) continue
            key = substr(f[i], 1, k - 1); val = substr(f[i], k + 1)
            if (key == "run")             { R[who] = val; if (who == "me") mr = val }
            if (key == "complete_kb")     C[who] = val + 0
            if (key == "biggest_step_kb") B[who] = val + 0
        }
    }' /dev/null
else
    echo
    echo "run $OTHER not pulled yet - do that and this will print the comparison:"
    echo "   bash ~/Downloads/tsp_memsplit.sh $OTHER"
fi

echo
echo "full report: $REP"
echo "raw log:     $RAW"
