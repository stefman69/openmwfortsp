#!/usr/bin/env bash
# TSP_SNDFIX_V1 - raise the warm cap, name the failing sound. Config only, no
# rebuild, no profiler change, no memory increase.
#
#   bash ~/Downloads/tsp_sndfix.sh on     # then play normally
#   bash ~/Downloads/tsp_sndfix.sh pull
#   bash ~/Downloads/tsp_sndfix.sh off
#
# ============================================================================
# WHAT THE SOURCE SETTLED
# ============================================================================
# soundmanagerimp.cpp:829, verbatim:
#   "the first play of any sound decodes it synchronously on the calling thread
#    (OpenALOutput::loadSound: ffmpeg open + readAll + alBufferData), measured at
#    ~33 ms inside SoundManager::update()"
#
# ffmpeg open + readAll off the SD card, on the main thread. Our measured cluster
# was 36-41 ms. That is the same thing.
#
# TWO OF MY THEORIES ARE DEAD, both by this listing:
#
#   Eviction: first call reports warmed=18 cached=1 failed=1 = 20 items; later
#   calls report warmed=0 cached=13 failed=0 = 13 items. The TOTALS DIFFER, so
#   cached=13 is not "13 of 18 survived", it is "this call had 13 to check and all
#   13 were present". Nothing was ever evicted and the buffer-cache change I made
#   was pure cost. Reverted.
#
#   updateWaterSound: line 840 is "// Water: the two ids updateWaterSound can
#   play." and line 855 gates weather behind TSP_NO_SNDWARM_WEATHER. Region
#   ambients, water and weather are ALL already warmed. That was my next guess and
#   it was already handled.
#
# WHAT IS ACTUALLY LEFT, and both are in the listing:
#
#   line 868  TSP_SNDWARM_MAX - there is a CAP on how many sounds get warmed, read
#             from the environment. Anything past the cap is not warmed and still
#             pays the synchronous ~33 ms decode on first play. warmed=18 is a
#             suspiciously round number for a default cap.
#
#   failed=1  one sound fails to warm on EVERY launch, without exception. A failed
#             warm means no cached buffer, so that sound decodes synchronously the
#             first time it plays - guaranteed, repeatable, once per run. That is
#             the shape of "one to two stutters at the start of a run".
#
# ============================================================================
# WHAT THIS CHANGES, AND WHAT IT DELIBERATELY DOES NOT
# ============================================================================
#   TSP_SNDWARM_MAX=64   raise the cap so the whole set gets warmed
#   TSP_SNDWARM_LOG=1    line 894: logs at Debug::Warning instead of Info, so the
#                        counters appear even at WARNING level and cannot be
#                        filtered out
#
# NOT changed, because these are what I broke last time:
#   - the ring profiler stays OFF. No trigger change. Nothing costs a frame.
#   - no sound buffer cache change. No extra resident memory: the warm decodes
#     into the existing 16 MB cache, which is bounded by its own max regardless
#     of how many we ask it to warm.
#   - no vm knobs, no swappiness, no page-cluster.
#
# COST: the first warm takes longer, because it decodes more. 630 ms for 18 might
# become ~1.5 s for 45. That lands INSIDE the load window (scene.cpp:1269 comment:
# "the load screen is still up here"), so it is load time, not a gameplay freeze -
# and pull measures it so we see exactly what it cost.
#
# Rule Zero: file, not paste; r() uses -n, rin() takes the heredoc (NEVER -n).
# No grep -r on the device. No apostrophe inside any awk program.

set -u
MODE="${1:-}"
case "$MODE" in on|off|pull) : ;; *) echo "usage: bash $0 on|pull|off"; exit 2 ;; esac

TSP="${TSP:-root@192.168.1.12}"
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6"
DL="${DL:-$HOME/Downloads}"
STAMP="$(date +%Y%m%d-%H%M%S)"
WMAX="${WMAX:-64}"
REP="$DL/tsp-sndfix-$MODE-$STAMP.txt"
CONTAINER="${CONTAINER:-openmw_builder}"
SRC="${SRC:-/root/openmw-0.51-tsp-src}"

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }
die() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }
r 'echo ok' >/dev/null 2>&1 || die "cannot reach the TSP at $TSP"

# ----------------------------------------------------------------------------
if [ "$MODE" = "on" ]; then
echo "=================================================================="
echo " PART 1 - THE EXACT FUNCTION, so the next step needs no guessing"
echo "=================================================================="
if command -v docker >/dev/null 2>&1; then
    F="$SRC/apps/openmw/mwsound/soundmanagerimp.cpp"
    echo "  $F lines 826-901"
    docker exec "$CONTAINER" sh -c "sed -n '826,901p' '$F'" 2>/dev/null | sed 's/^/    /' \
        || echo "    (could not read it - is the container running?)"
    echo
    echo "  -- what TSP_SNDWARM_MAX defaults to --"
    docker exec "$CONTAINER" sh -c "sed -n '860,880p' '$F'" 2>/dev/null | sed 's/^/    /'
    echo
    echo "  -- the two call sites in scene.cpp --"
    docker exec "$CONTAINER" sh -c "sed -n '1264,1276p;1564,1576p' '$SRC/apps/openmw/mwworld/scene.cpp'" 2>/dev/null | sed 's/^/    /'
else
    echo "  docker not on PATH here - skipping the source dump, the config"
    echo "  change below does not depend on it"
fi
echo
fi

# ----------------------------------------------------------------------------
if [ "$MODE" = "pull" ]; then
rin 'sh -s' <<'REMOTE' 2>&1 | tee "$REP"
S=/mnt/SDCARD
G=$S/data/ports/openmw
LG=$G/openmw_log.txt

echo "########## 1. DID THE CAP ACTUALLY RISE ##########"
echo "  BEFORE: every launch, first call warmed=18 cached=1 failed=1"
echo "  If the cap was the limit, warmed should now be HIGHER than 18."
echo
grep -a 'TSP_SNDWARM' "$LG" 2>/dev/null | awk '{
    ts = ""
    if (match($0, /[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9]+/)) ts = substr($0, RSTART, RLENGTH)
    w=""; c=""; f=""; ms=""
    for (i = 1; i <= NF; i++) {
        k = index($i, "="); if (!k) continue
        key = substr($i,1,k-1); v = substr($i,k+1)
        if (key == "warmed") w = v
        if (key == "cached") c = v
        if (key == "failed") f = v
        if (key == "ms")     ms = v
    }
    printf "  %s  warmed=%-4s cached=%-4s failed=%-4s %9.2f ms   total considered=%d\n", \
        ts, w, c, f, ms + 0, w + c + f
    n++
    if (n == 1) { fw = w; ff = f; fms = ms }
}
END {
    print ""
    if (!n) { print "  NO SNDWARM LINES AT ALL."
              print "  TSP_SNDWARM_LOG=1 should make these log at WARNING level, so if"
              print "  they are missing the conf change did not reach the process."
              exit }
    printf "  first call: warmed=%s failed=%s in %.0f ms\n", fw, ff, fms + 0
    if (fw + 0 > 18) printf "  => CAP WAS THE LIMIT. warmed %s, was 18. %s more sounds now pre-decoded.\n", fw, fw - 18
    else if (fw + 0 == 18) print "  => STILL 18. The cap is NOT what limited it - 18 is the real set size,"
    else if (fw + 0 == 18) print "     so the spikes come from sounds outside the warm set entirely."
    else printf "  => warmed DROPPED to %s. Unexpected; do not act on this without a re-run.\n", fw
    print ""
    if (ff + 0 > 0) printf "  failed=%s STILL. Section 2 should now name it.\n", ff
    else            print "  failed=0 - the failing sound is gone too."
}'
echo

echo "########## 2. WHICH SOUND FAILED ##########"
echo "  TSP_SNDWARM_LOG=1 raises the log level; any warn/error from the warm or"
echo "  from the decoder should now be visible:"
grep -a -i -E 'TSP_SNDWARM|failed to (open|load|decode)|sound.*(not found|missing|error|fail)|ffmpeg|loadSound' "$LG" 2>/dev/null \
    | head -25 | sed 's/^/    /'
echo
echo "  -- every WARNING and ERROR line this run, in case it is worded differently --"
grep -a -E '^\[[0-9:.]+ (W|E)\]' "$LG" 2>/dev/null | head -20 | sed 's/^/    /'
echo

echo "########## 3. DID THE SPIKES GO ##########"
if ls "$S"/tsp_ring.[0-9]* >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    cat "$S"/tsp_ring.[0-9]* 2>/dev/null | awk '
    !lay { p1=0
        for (i=1;i<=NF;i++) if ($i=="|") { p1=i; break }
        if (p1<4) next
        if ($1+0 != $1 || $2+0 != $2) next
        S0=3; S1=p1-1; lay=1 }
    lay { p1=0
        for (i=1;i<=NF;i++) if ($i=="|") { p1=i; break }
        if (p1 != S1+1) next
        if ($1+0 != $1 || $2+0 != $2) next
        rows++
        snd=$(S0+1)+0
        if (snd>mx) mx=snd
        if (snd>=30) o30++
        if (snd>=20) o20++
        if (snd>=5)  o5++
        if (snd>=3) printf "  frame %-8s total %8.1f ms   sound %7.2f ms\n", $1, $2+0, snd }
    END {
        if (!rows) { print "  (no parseable rows)"; exit }
        printf "\n  %d rows   sound MAX %.1f   >=5ms %d   >=20ms %d   >=30ms %d\n", rows, mx, o5+0, o20+0, o30+0
        print  "  BEFORE, 33 dumps / 25760 rows: MAX 207.4, >=5ms 26, >=20ms 12, >=30ms 11" }'
else
    echo "  The ring profiler is OFF and staying off - it is what tanked your"
    echo "  framerate last round. No dumps, by design."
    echo "  Judge this one by feel first. If it is better, we arm the ring once,"
    echo "  briefly, to put a number on it."
fi
echo

echo "########## 4. LOAD TIME COST ##########"
awk '/TSP_LOAD_TRACE/ && /phase=(mechanics-playerLoaded|projectile-casters-updated|complete)/ {
    ts=""
    if (match($0,/[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9]+/)) ts=substr($0,RSTART,RLENGTH)
    ph=""
    for (i=1;i<=NF;i++) if ($i ~ /^phase=/) ph=substr($i,7)
    printf "  %s  %s\n", ts, ph
}' "$LG" 2>/dev/null
echo "  the warm sits inside this window, so a longer warm costs load time, not fps"
REMOTE
echo
echo "=================================================================="
echo "  Section 1 is the verdict: warmed > 18 means the cap was the limit."
echo "  Section 2 should finally name the sound that fails every launch."
echo "  Revert:  bash ~/Downloads/tsp_sndfix.sh off"
echo "=================================================================="
exit 0
fi

# ----------------------------------------------------------------------------
if [ "$MODE" = "on" ]; then WANT_MAX="$WMAX"; WANT_LOG=1; LBL="on   TSP_SNDWARM_MAX=$WMAX, TSP_SNDWARM_LOG=1"
else                        WANT_MAX="";      WANT_LOG=""; LBL="off  both removed"; fi
echo "=================================================================="
echo " PART 2 - THE CONFIG CHANGE"
echo "=================================================================="
echo "MODE=$LBL"
echo

rin "WANT_MAX=$WANT_MAX WANT_LOG=$WANT_LOG STAMP=$STAMP MODE=$MODE sh -s" <<'REMOTE' 2>&1 | tee -a "$REP"
# ---- TSP_SNDFIX_ARM_BEGIN ----
S=/mnt/SDCARD
G=$S/data/ports/openmw
CONF=$S/tsp_iotune.conf
F=0

[ -f "$CONF" ] || { echo "FAIL: $CONF missing"; exit 1; }
cp -p "$CONF" "$CONF.bak-sndfix-$STAMP" || { echo "FAIL: backup"; exit 1; }
echo "########## 1. SET THE TWO VARS ##########"
echo "  backed up $(basename "$CONF").bak-sndfix-$STAMP"
echo "  NOTE these need 'export' - the conf is SOURCED, not exported for you."

setvar() {   # setvar KEY VALUE   (empty VALUE removes the line)
    k="$1"; v="$2"
    if [ -z "$v" ]; then
        if grep -q "^[[:space:]]*export[[:space:]][[:space:]]*$k=" "$CONF" 2>/dev/null; then
            grep -v "^[[:space:]]*export[[:space:]][[:space:]]*$k=" "$CONF" > "$CONF.n" && mv "$CONF.n" "$CONF"
            echo "  removed $k"
        else
            echo "  $k already absent"
        fi
        return
    fi
    if grep -q "^[[:space:]]*export[[:space:]][[:space:]]*$k=" "$CONF" 2>/dev/null; then
        sed "s|^\([[:space:]]*export[[:space:]][[:space:]]*$k=\).*|\1$v|" "$CONF" > "$CONF.n" && mv "$CONF.n" "$CONF"
    else
        printf 'export %s=%s\n' "$k" "$v" >> "$CONF"
    fi
    got="$(sed -n "s|^[[:space:]]*export[[:space:]][[:space:]]*$k=\(.*\)$|\1|p" "$CONF" | tail -1)"
    if [ "$got" = "$v" ]; then printf '  OK   export %s=%s\n' "$k" "$got"
    else printf '  FAIL %s got [%s] want [%s]\n' "$k" "$got" "$v"; F=1; fi
}
setvar TSP_SNDWARM_MAX "$WANT_MAX"
setvar TSP_SNDWARM_LOG "$WANT_LOG"
echo
echo "  -- the sound-related conf lines now --"
grep -n 'TSP_SNDWARM\|TSP_NO_SNDWARM\|OPENMW_DEBUG_LEVEL' "$CONF" 2>/dev/null | sed 's/^/    /'
echo "  (TSP_NO_SNDWARM absent = the warm is enabled, which is what we want)"
echo

echo "########## 2. CONFIRM I AM NOT REPEATING LAST ROUND ##########"
if [ -f "$S/tsp_ring_off" ]; then
    echo "  OK   tsp_ring_off present - the profiler stays OFF. No frame cost."
else
    echo "  ring profiler is ENABLED. Turning it off - it is what tanked the fps."
    touch "$S/tsp_ring_off"
    printf 'TSP_RING_TRIG=1000\nTSP_RING_MAX=12\n' > "$S/tsp_ring.conf"
    echo "  OK   now off, trigger back to 1000"
fi
BMIN="$(sed -n 's/^buffer cache min[[:space:]]*=[[:space:]]*\(.*\)$/\1/p' "$G/config/settings.cfg" 2>/dev/null | tail -1)"
BMAX="$(sed -n 's/^buffer cache max[[:space:]]*=[[:space:]]*\(.*\)$/\1/p' "$G/config/settings.cfg" 2>/dev/null | tail -1)"
printf '  sound buffer cache: min=%s max=%s\n' "${BMIN:-default}" "${BMAX:-default}"
if [ "${BMAX:-16}" = "16" ] || [ -z "${BMAX:-}" ]; then
    echo "  OK   back at the default - no extra resident memory from me"
else
    echo "  ** still raised. Run: bash ~/Downloads/tsp_revert.sh"
    F=1
fi
printf '  vm.swappiness %s   page-cluster %s\n' \
    "$(cat /proc/sys/vm/swappiness 2>/dev/null)" "$(cat /proc/sys/vm/page-cluster 2>/dev/null)"
echo

echo "########## 3. CLEAN LOG ##########"
[ -s "$G/openmw_log.txt" ] && mv "$G/openmw_log.txt" "$G/openmw_log.txt.sndfix-$MODE-$STAMP" \
    && echo "  log rotated"
DBG="$(sed -n 's/^[[:space:]]*export[[:space:]][[:space:]]*OPENMW_DEBUG_LEVEL=\(.*\)$/\1/p' "$CONF" | tail -1)"
echo "  OPENMW_DEBUG_LEVEL=${DBG:-unset}"
echo "  (TSP_SNDWARM_LOG=1 logs at WARNING, so the counters show even if this is"
echo "   not INFO - that is why it is being set)"
sync
echo

echo "########## READY CHECK ##########"
if [ -n "$WANT_MAX" ]; then
    [ "$(sed -n 's|^[[:space:]]*export[[:space:]][[:space:]]*TSP_SNDWARM_MAX=\(.*\)$|\1|p' "$CONF" | tail -1)" = "$WANT_MAX" ] \
        && echo "  OK   TSP_SNDWARM_MAX=$WANT_MAX" || { echo "  FAIL max"; F=1; }
    [ "$(sed -n 's|^[[:space:]]*export[[:space:]][[:space:]]*TSP_SNDWARM_LOG=\(.*\)$|\1|p' "$CONF" | tail -1)" = "1" ] \
        && echo "  OK   TSP_SNDWARM_LOG=1" || { echo "  FAIL log"; F=1; }
else
    grep -q 'TSP_SNDWARM_MAX' "$CONF" 2>/dev/null && { echo "  FAIL max still set"; F=1; } || echo "  OK   max removed"
fi
[ -f "$S/tsp_ring_off" ] && echo "  OK   profiler off" || { echo "  FAIL profiler on"; F=1; }
[ -s "$G/openmw_log.txt" ] && { echo "  FAIL log not empty"; F=1; } || echo "  OK   log clean"
echo
[ "$F" -eq 0 ] && echo "READY" || echo "NOT READY"
# ---- TSP_SNDFIX_ARM_END ----
REMOTE

echo
if [ "$MODE" = "off" ]; then
    echo "=================================================================="
    echo "  Both vars removed. Back to the shipped warm behaviour."
    echo "=================================================================="
    exit 0
fi
cat <<'GO'
==================================================================
  Launch and play normally. Nothing is timed, nothing is armed,
  the profiler is off so it cannot cost you a frame.

  What to feel for: the one or two stutters at the start of a run.
  The load may be a bit longer - the warm now decodes more, and it
  runs while the load screen is up.

  When you quit:
     bash ~/Downloads/tsp_sndfix.sh pull

  Two numbers decide it:
     warmed > 18   the cap was the limit and more sounds are now
                   pre-decoded, so fewer can stall mid-frame
     failed        should finally be NAMED in section 2, and if it
                   is still 1 that one sound is a separate bug

  Revert:  bash ~/Downloads/tsp_sndfix.sh off
==================================================================
GO
