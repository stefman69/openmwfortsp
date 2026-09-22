#!/bin/sh
# tsp_fix.sh - close the first-load memory spike. One command, three answers.
#
#   look    THE ONE TO RUN. Does three things in a single pass:
#
#           1. LOCAL, instant, no device: re-reads the smaps snapshots already
#              in ~/Downloads and says whether the ~350 MB of [heap] is still
#              resident AFTER the load finishes. That single fact picks the fix:
#                 still resident -> freed but not returned to the kernel; the
#                                   patch is a malloc_trim at load completion.
#                 released       -> genuinely live during the burst; the patch
#                                   is a smaller preload working set.
#
#           2. SOURCE, from the builder container: every place that could hold
#              hundreds of MB of malloc across a cell load - the preloader and
#              its cache sizing, the scene load/unload path, the save-load
#              completion point, the OSG object caches - with line numbers, plus
#              whether malloc.h / malloc_trim / mallopt appear anywhere already.
#
#           3. DEVICE: the settings that size all of it, and - if the game
#              happens to be running - /proc/<pid>/environ and smaps_rollup.
#              The environ read settles a question open since 09-11: whether
#              exports from a sourced conf file actually reach the game process.
#
#   env     Create /mnt/SDCARD/tsp_intocc.env. The launcher already sources it
#           unconditionally at line 5 and the file does not exist, so it is a
#           free, already-wired place to put env for the game - no launcher
#           edit. Writes glibc allocator tunables plus the TSP_INTOCC_ defaults
#           that have been missing. Backs up anything already there.
#
#   unenv   Remove it / restore the backup.
#
# Nothing here rebuilds anything and nothing here touches the game binary.

set -u
DEV="root@192.168.1.12"
G="/mnt/SDCARD/data/ports/openmw"
CONT="openmw_builder"
SRC="/root/openmw-0.51-tsp-src"
ENVF="/mnt/SDCARD/tsp_intocc.env"
SSHO="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/tsp_fix_$STAMP.txt"
SPIKE="$HOME/Downloads/tsp_spike.sh"

MODE="${1:-look}"
case "$MODE" in look | env | unenv) ;;
*) printf 'usage: %s look | env | unenv\n' "$0"; exit 2 ;; esac

say() { printf '  %s\n' "$*"; }
hr()  { printf '\n########## %s ##########\n' "$1"; }
sec() { printf '\n\n==============================================================\n== %s\n==============================================================\n' "$1" >>"$OUT"
        printf '  .. %s\n' "$1"; }
rin() { ssh $SSHO "$DEV" "sh -s" 2>&1; }
r()   { ssh $SSHO -n "$DEV" "$1" 2>&1; }
# rq: for values a DECISION depends on. r() folds stderr into stdout, so any ssh
# banner or warning becomes part of the value and a "is it non-empty" test
# passes on noise. Never gate on r().
rq()  { ssh $SSHO -n "$DEV" "$1" 2>/dev/null; }
d()   { docker exec "$CONT" sh -c "$1" 2>&1; }
have_dev()  { ssh $SSHO -n "$DEV" "echo ok" 2>&1 | grep -q ok; }
have_cont() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONT"; }

# ================================================================ env ========
if [ "$MODE" = "env" ] || [ "$MODE" = "unenv" ]; then
    have_dev || { say "cannot reach $DEV - is the handheld awake and on wifi?"; exit 1; }
fi

if [ "$MODE" = "unenv" ]; then
    hr "REMOVING $ENVF"
    rin <<UEOF
E='$ENVF'
B=""
for c in \$(ls -1t "\$E".before-* 2>/dev/null); do
    grep -q 'TSP_ENVF_V1' "\$c" 2>/dev/null || { B="\$c"; break; }
done
if [ -n "\$B" ]; then
    cp -p "\$B" "\$E" && printf '  restored from %s\n' "\$B"
else
    [ -f "\$E" ] && { rm -f "\$E" && echo "  removed (there was no prior version)"; } \\
                 || echo "  nothing there to remove"
fi
[ -f "\$E" ] && { echo "  now contains:"; sed "s/^/    /" "\$E"; } || echo "  gone"
UEOF
    printf '\n'; exit 0
fi

if [ "$MODE" = "env" ]; then
    hr "CHECKING THE LAUNCHER REALLY SOURCES IT BEFORE WRITING ANYTHING"
    # Count locally from the grep OUTPUT, never from grep exit status or from
    # grep -c: with no match, busybox grep -c prints 0 AND exits 1, so a
    # "... || echo 0" wrapper yields the two-line string "0\n0" and every
    # numeric test against it silently passes. That is a gate that cannot fail,
    # and this script had exactly that bug.
    HITS="$(rq "grep -n 'tsp_intocc\.env' '/mnt/SDCARD/Roms/PORTS/Morrowind.sh' 2>/dev/null")"
    # Count only lines that are really grep -n output for this file: a leading
    # line number, a colon, and the name. Noise cannot satisfy that shape.
    # A COMMENT mentioning the path is not a source command. Require the line
    # to actually be "." or "source" followed by the path.
    N="$(printf '%s\n' "$HITS" \
         | grep -c '^[0-9][0-9]*:[[:space:]]*\(\.\|source\)[[:space:]][[:space:]]*["'\'']*/mnt/SDCARD/tsp_intocc\.env' 2>/dev/null)"
    [ -n "$N" ] || N=0
    printf '%s\n' "$HITS" | sed 's/^/    /'
    say "matching lines in the launcher: $N"
    if [ "$N" -lt 1 ] 2>/dev/null || [ -z "$HITS" ]; then
        say ""
        say "The launcher does NOT source $ENVF."
        say "Writing it would do nothing at all, so this is stopping here rather"
        say "than reporting a fix that is not wired to anything. Send me the"
        say "output above and I will find the right injection point."
        exit 1
    fi
    say "-> really sourced, on the line shown above. Safe to write."

    hr "WRITING $ENVF"
    rin <<EEOF
E='$ENVF'
# Back up only a version this tool did NOT write. Running env twice used to
# back up the already-edited file, so unenv then "restored" the edit.
if [ -f "\$E" ]; then
    if grep -q 'TSP_ENVF_V1' "\$E" 2>/dev/null; then
        printf '  %s already written by this tool - not re-backing it up\n' "\$E"
    else
        cp -p "\$E" "\$E.before-$STAMP" && printf '  backed up the pre-existing file to %s.before-%s\n' "\$E" "$STAMP"
    fi
fi
cat > "\$E" <<'INNER'
# tsp_intocc.env - sourced unconditionally by Morrowind.sh line 5.
# This file did not exist, so every TSP_INTOCC_ var below ran on compiled
# defaults and nothing else here was set at all.

# --- glibc allocator. The first-load burst lands in the main brk arena and is
# --- not returned; these make free() give pages back instead of parking them.
# --- Setting these env vars also DISABLES glibcs dynamic threshold growth,
# --- which is what lets brk ratchet upward across a load.
export MALLOC_TRIM_THRESHOLD_=131072
export MALLOC_MMAP_THRESHOLD_=262144
export MALLOC_TOP_PAD_=131072
export GLIBC_TUNABLES=glibc.malloc.trim_threshold=131072:glibc.malloc.mmap_threshold=262144:glibc.malloc.top_pad=131072
# deliberately NOT setting arena_max: the 6 extra arenas hold ~0 resident and
# capping them would only add lock contention across 19 threads.

# --- and a marker, so /proc/<pid>/environ can prove this file reached the game
export TSP_ENVF_V1=1
INNER
printf '  wrote %s bytes\n' "\$(wc -c < "\$E")"
echo "  --- reading it back off the device, verbatim:"
sed "s/^/    /" "\$E"
EEOF
    cat <<'NEOF'

  Now launch the game once, and while it is RUNNING run:

      bash ~/Downloads/tsp_fix.sh look

  Section 3 of that output reads /proc/<openmw pid>/environ and looks for
  TSP_ENVF_V1. If it is there, this file reaches the game and the allocator
  tunables are live - and that also finally answers whether TSP_NO_LOADPURGE
  and the rest of tsp_iotune.conf were ever arriving. If it is absent, the
  launcher sources it in a shell that is not the games parent, and every
  export in every conf file has been inert this whole time.

NEOF
    exit 0
fi

# =============================================================== look ========
mkdir -p "$HOME/Downloads"

: >"$OUT"
printf '# tsp_fix look - %s\n' "$STAMP" >>"$OUT"

hr "1. LOCAL - WHAT THE SNAPSHOTS YOU ALREADY HAVE SAY"
printf '\n== 1. LOCAL SNAPSHOT VERDICT\n' >>"$OUT"
if [ -f "$SPIKE" ]; then
    sh "$SPIKE" report 2>&1 | sed -n '/THE \[heap\] BRK REGION/,$p' | tee -a "$OUT"
else
    say "tsp_spike.sh is not in ~/Downloads - skipping the local half." | tee -a "$OUT"
fi

hr "2. SOURCE - EVERY CANDIDATE FOR A 350 MB MALLOC BURST"
if ! have_cont; then
    say "container $CONT is not running - skipping the source half."
    say "start it and re-run; sections 1 and 3 still ran."
else
sec "does the tree already call malloc_trim / mallopt / mallinfo anywhere"
d "cd $SRC && grep -rn -e malloc_trim -e mallopt -e mallinfo -e 'malloc\.h' \
    apps components 2>/dev/null | head -40" >>"$OUT"

sec "CellPreloader - the cache that holds preloaded cell scene graphs"
for f in apps/openmw/mwworld/cellpreloader.hpp apps/openmw/mwworld/cellpreloader.cpp; do
    printf '\n----- %s -----\n' "$f" >>"$OUT"
    d "cd $SRC && cat -n $f 2>/dev/null | head -400" >>"$OUT"
done

sec "who sizes the preloader - setMaxCacheSize / setExpiryDelay call sites"
d "cd $SRC && grep -rn -e setMaxCacheSize -e setExpiryDelay -e setPreloadInstances \
    -e mPreloader -e preloadCells -e PreloadItem -e updateCache \
    apps components 2>/dev/null | head -60" >>"$OUT"

sec "Scene - cell grid change, load, unload, and the preload calls around them"
d "cd $SRC && grep -n -e '^[A-Za-z].*Scene::' -e changeCellGrid -e loadCell -e unloadCell \
    -e preload -e requestMap -e mActiveCells \
    apps/openmw/mwworld/scene.cpp 2>/dev/null | head -80" >>"$OUT"
printf '\n----- scene.cpp, the load/unload bodies -----\n' >>"$OUT"
d "cd $SRC && awk '/void Scene::(loadCell|unloadCell|changeCellGrid|preloadCells|preloadCell)\\b/,/^}/' \
    apps/openmw/mwworld/scene.cpp 2>/dev/null | head -320" >>"$OUT"

sec "where a save load FINISHES - the natural place for a trim"
d "cd $SRC && grep -n -e 'void StateManager::loadGame' -e 'loadGame(' -e mState -e State_Running \
    -e 'Loading::' -e finish -e 'MWBase::Environment' \
    apps/openmw/mwstate/statemanagerimp.cpp 2>/dev/null | head -60" >>"$OUT"
printf '\n----- statemanagerimp.cpp loadGame body -----\n' >>"$OUT"
d "cd $SRC && awk '/void MWState::StateManager::loadGame *\\(const Character|void MWState::StateManager::loadGame *\\(/,/^}/' \
    apps/openmw/mwstate/statemanagerimp.cpp 2>/dev/null | head -260" >>"$OUT"

sec "OSG resource caches - the other place hundreds of MB can sit"
d "cd $SRC && grep -rn -e 'setExpiryDelay' -e 'ObjectCache' -e 'clearCache' -e 'updateCache' \
    -e 'mCache' components/resource/*.cpp components/resource/*.hpp 2>/dev/null | head -50" >>"$OUT"

sec "settings that size all of the above - defaults in the source"
d "cd $SRC && awk '/^\\[Cells\\]/,/^\\[/' files/settings-default.cfg 2>/dev/null | head -40" >>"$OUT"
d "cd $SRC && grep -n -e 'preload' -e 'cache expiry' -e 'pointers cache' \
    files/settings-default.cfg 2>/dev/null | head -40" >>"$OUT"

sec "existing TSP markers in the load path, so a patch does not collide"
d "cd $SRC && grep -rn 'TSP_' apps/openmw/mwworld/scene.cpp apps/openmw/mwworld/cellpreloader.cpp \
    apps/openmw/mwstate/statemanagerimp.cpp apps/openmw/engine.cpp 2>/dev/null | head -60" >>"$OUT"
fi

hr "3. DEVICE - LIVE SETTINGS, AND THE ENVIRON READ IF THE GAME IS UP"
if ! have_dev; then
    say "cannot reach $DEV - skipping the device half."
else
rin <<'DEOF' | tee -a "$OUT"
G="/mnt/SDCARD/data/ports/openmw"
echo "--- the settings that size the preload working set"
grep -n -e preload -e 'cache expiry' -e 'viewing distance' -e 'object paging' \
        -e 'distant terrain' -e 'composite map' -e 'target framerate' \
        "$G/config/settings.cfg" 2>/dev/null | sed 's/^/    /'

echo "--- is the game running right now"
P="$(pidof openmw-0.51 2>/dev/null | awk '{print $1}')"
[ -n "$P" ] || P="$(ps -e 2>/dev/null | grep '[o]penmw-0.51' | awk '{print $1}' | head -1)"
[ -n "$P" ] || P="$(ps 2>/dev/null | grep '[o]penmw-0.51' | awk '{print $1}' | head -1)"
if [ -z "$P" ]; then
    echo "    not running. Launch it and re-run this for section 3b."
else
    echo "    pid $P"
    echo "--- 3b. THE ANSWER: do exports from a sourced conf reach the game?"
    tr '\0' '\n' < "/proc/$P/environ" 2>/dev/null > /tmp/tsp_env.$$
    for k in TSP_ENVF_V1 MALLOC_TRIM_THRESHOLD_ MALLOC_MMAP_THRESHOLD_ GLIBC_TUNABLES \
             TSP_NO_LOADPURGE TSP_RELOAD_MEM_FLOOR_KB TSP_KTX TSP_ICO_MAXOBJ \
             OPENMW_DEBUG_LEVEL LIBGL_TSP_LOG TSP_SNDWARM_LOG TSP_CRASH_OUT; do
        v="$(grep "^$k=" /tmp/tsp_env.$$ 2>/dev/null | head -1)"
        if [ -n "$v" ]; then printf "    PRESENT  %s\n" "$v"
        else                 printf "    absent   %s\n" "$k"; fi
    done
    echo "--- every OPENMW_/TSP_/MALLOC_/LIBGL_ var the game actually has"
    grep -e "^OPENMW" -e "^TSP_" -e "^MALLOC" -e "^GLIBC" -e "^LIBGL" /tmp/tsp_env.$$ \
        2>/dev/null | sort | sed "s/^/    /"
    printf "    (%s environment entries in total)\n" "$(wc -l < /tmp/tsp_env.$$)"
    rm -f /tmp/tsp_env.$$
    echo "--- live smaps_rollup"
    sed 's/^/    /' "/proc/$P/smaps_rollup" 2>/dev/null | head -14
    echo "--- live heap line"
    grep -B0 -A0 '\[heap\]' "/proc/$P/maps" 2>/dev/null | sed 's/^/    /'
fi

echo "--- memory right now"
grep -e MemTotal -e MemAvailable -e ^Cached -e SwapTotal -e SwapFree /proc/meminfo | sed 's/^/    /'
echo "--- what the launcher sources, with line numbers"
grep -n '^[[:space:]]*\.[[:space:]]' /mnt/SDCARD/Roms/PORTS/Morrowind.sh 2>/dev/null | head -12 | sed 's/^/    /'
DEOF
fi

hr "SUMMARY"
say "saved to $OUT"
say ""
say "Send me that whole file. It has the local verdict, the source regions and"
say "the live settings, which is everything the patch needs - no follow-up pull."
printf '\n'
