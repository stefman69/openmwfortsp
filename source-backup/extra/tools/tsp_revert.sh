#!/usr/bin/env bash
# TSP_REVERT_V1 - undo everything I changed tonight except the one thing Steve
# said to keep, verify each undo, then collect the facts I should have had first.
#
#   bash ~/Downloads/tsp_revert.sh
#
# ============================================================================
# WHAT I BROKE, AND WHICH ONE IS THE FRAMERATE
# ============================================================================
# 1. TSP_RING_TRIG 1000 -> 60.  I did this so a 36 ms sound spike inside an 80 ms
#    frame would be captured. The baseline frame is 27 ms with p95 render at
#    32.5 ms, so a 60 ms trigger arms the ring constantly during normal play.
#    claude/INCIDENT-profiler-trigger-zero-halved-the-framerate-20260911.md is
#    about exactly this: an over-eager trigger took 30 fps to 15. I wrote that
#    incident report and then did a milder version of the same thing.
#
# 2. buffer cache 14/16 -> 24/32 MB.  That is +16 MB of resident RAM on a device
#    measured at 660 MB RSS with 100-134 MB already in swap and Cached down at
#    40-60 MB. More anonymous memory on a machine that is already reclaiming is a
#    direct framerate cost. I noted it as a 2.4% risk and shipped it anyway.
#
# Either would drop fps. Both together certainly would. Both are reverted here.
#
# ============================================================================
# AND THE THEORY WAS BUILT ON A GUESS I NEVER CHECKED
# ============================================================================
# I read `warmed=18 cached=1 failed=1` then `warmed=0 cached=13 failed=0` and
# asserted it meant "18 decoded, only 13 retained, five evicted". I never read the
# code that prints those counters.
#
# They are equally consistent with: the region has 13 ambient sounds; the first
# call warmed 18 items (a superset), and every later call finds all 13 already
# cached and does nothing. Under that reading **nothing is being evicted and there
# was no problem to fix** - which matches the result: cached stayed 13, and the
# only thing that changed was 16 MB of wasted RAM.
#
# I do not know which reading is right, and I am not going to theorise a third
# time. Section 3 asks for the source that settles it.
#
# KEPT, because Steve measured it as a small win: the UDISK texture data= line.
#
# Rule Zero: file, not paste; r() uses -n, rin() takes the heredoc (NEVER -n).
# No grep -r. No apostrophe inside any awk program. Single-value /proc and /sys
# reads use cat, never `read -r x < file`.

set -u
TSP="${TSP:-root@192.168.1.12}"
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6"
DL="${DL:-$HOME/Downloads}"
STAMP="$(date +%Y%m%d-%H%M%S)"
REP="$DL/tsp-revert-$STAMP.txt"

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }
die() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }
r 'echo ok' >/dev/null 2>&1 || die "cannot reach the TSP at $TSP"

rin "STAMP=$STAMP sh -s" <<'REMOTE' 2>&1 | tee "$REP"
# ---- TSP_REVERT_BEGIN ----
S=/mnt/SDCARD
G=$S/data/ports/openmw
CONF=$S/tsp_iotune.conf
F=0

echo "=================================================================="
echo " PART 1 - REVERT"
echo "=================================================================="
echo
echo "########## 1a. RING PROFILER - OFF ENTIRELY ##########"
echo "  Not just back to 1000. Off, so it cannot cost a single frame until"
echo "  we deliberately re-arm it."
printf 'TSP_RING_TRIG=1000\nTSP_RING_MAX=12\n' > "$S/tsp_ring.conf"
touch "$S/tsp_ring_off"
n=0
A="$S/tsp_hitch_archive_$STAMP"
for d in "$S"/tsp_ring.[0-9]*; do
    [ -f "$d" ] || continue
    mkdir -p "$A"; cp -p "$d" "$A/" && rm -f "$d" && n=$((n + 1))
done
echo "  dumps archived and cleared: $n"
[ -f "$S/tsp_ring_off" ] && echo "  OK   tsp_ring_off present - profiler disabled" \
                         || { echo "  FAIL off switch not created"; F=1; }
echo "  conf: $(tr '\n' ' ' < "$S/tsp_ring.conf")"
echo

echo "########## 1b. SOUND BUFFER CACHE - BACK TO 14/16 ##########"
CFGS=""
for c in "$G/config/settings.cfg" "$G/config-0.51/settings.cfg"; do
    [ -f "$c" ] && CFGS="$CFGS $c"
done
for c in $(find "$G" -maxdepth 3 -name 'settings.cfg' 2>/dev/null); do
    case " $CFGS " in *" $c "*) : ;; *) CFGS="$CFGS $c" ;; esac
done
for c in $CFGS; do
    cp -p "$c" "$c.bak-revert-$STAMP" 2>/dev/null
    for kv in "buffer cache min|14" "buffer cache max|16"; do
        key="${kv%|*}"; val="${kv#*|}"
        if grep -q "^$key[[:space:]]*=" "$c" 2>/dev/null; then
            awk -v k="$key" -v v="$val" '
                index($0, k) == 1 { print k " = " v; next }
                { print }' "$c" > "$c.n" && mv "$c.n" "$c"
        fi
    done
    GMIN="$(sed -n 's/^buffer cache min[[:space:]]*=[[:space:]]*\(.*\)$/\1/p' "$c" | tail -1)"
    GMAX="$(sed -n 's/^buffer cache max[[:space:]]*=[[:space:]]*\(.*\)$/\1/p' "$c" | tail -1)"
    if [ "${GMIN:-14}" = "14" ] && [ "${GMAX:-16}" = "16" ]; then
        printf '  OK   %s  min=%s max=%s\n' "$c" "${GMIN:-absent}" "${GMAX:-absent}"
    else
        printf '  FAIL %s  min=[%s] max=[%s]\n' "$c" "$GMIN" "$GMAX"; F=1
    fi
done
echo

echo "########## 1c. THE INERT tsp_iotune.conf LINES I ADDED ##########"
echo "  TSP_SWAPPINESS=10 and TSP_NO_SHADER_WARMDRAW=1 both proved to be no-ops,"
echo "  but they are clutter and one of them misrepresents the real swappiness."
cp -p "$CONF" "$CONF.bak-revert-$STAMP" 2>/dev/null
for k in TSP_NO_SHADER_WARMDRAW; do
    if grep -q "^[[:space:]]*export[[:space:]][[:space:]]*$k=" "$CONF" 2>/dev/null; then
        grep -v "^[[:space:]]*export[[:space:]][[:space:]]*$k=" "$CONF" > "$CONF.n" && mv "$CONF.n" "$CONF"
        echo "  removed $k"
    else
        echo "  $k already absent"
    fi
done
if grep -q '^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}TSP_SWAPPINESS=' "$CONF" 2>/dev/null; then
    sed 's/^\([[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}TSP_SWAPPINESS=\).*/\1150/' "$CONF" > "$CONF.n" \
        && mv "$CONF.n" "$CONF"
    echo "  TSP_SWAPPINESS set back to 150 (its pre-tonight value)"
fi
echo "  conf now:"
grep -n 'TSP_SWAPPINESS\|TSP_NO_SHADER_WARMDRAW\|TSP_KTX\|TSP_RECORDMEM\|OPENMW_DEBUG_LEVEL\|TSP_ICO' "$CONF" 2>/dev/null | sed 's/^/    /'
echo

echo "########## 1d. KERNEL VM KNOBS - back to the pre-tonight values ##########"
for kv in "swappiness 150" "page-cluster 3" "watermark_scale_factor 10"; do
    set -- $kv
    [ -e "/proc/sys/vm/$1" ] || continue
    echo "$2" > "/proc/sys/vm/$1" 2>/dev/null
    printf '  vm.%-24s %s\n' "$1" "$(cat "/proc/sys/vm/$1" 2>/dev/null)"
done
echo

echo "########## 1e. ANY SAMPLER STILL RUNNING ##########"
k=0
for p in $(ps 2>/dev/null | awk '/[t]sp_(iowatch|relief|swaptune|zram)_(sampler|applier)/{print $1}'); do
    kill "$p" 2>/dev/null && k=$((k + 1))
done
echo "  helpers killed: $k"
touch "$S/tsp_iowatch_off" "$S/tsp_swaptune_off" "$S/tsp_zram_off" 2>/dev/null
echo "  off switches set for all of them"
echo

echo "########## 1f. KEPT ON PURPOSE ##########"
UD=/mnt/UDISK/openmw-tex
if grep -q "^data=$UD\$" "$G/config/openmw.cfg" 2>/dev/null; then
    echo "  KEPT the UDISK texture data= line - you measured ~1 fps for it."
    printf '    %s files there\n' "$(find "$UD" -name '*.ktx' 2>/dev/null | wc -l)"
    echo "    remove with: bash ~/Downloads/tsp_texmove.sh off"
else
    echo "  the UDISK texture line is not currently active"
fi
echo

echo "########## REVERT RESULT ##########"
[ "$F" -eq 0 ] && echo "  ALL REVERTS VERIFIED" || echo "  SOMETHING DID NOT REVERT - see the FAIL lines above"
echo "  Play once and confirm the framerate is back before anything else happens."
echo

echo "=================================================================="
echo " PART 2 - WHAT I NEED FROM THE DEVICE, no theory attached"
echo "=================================================================="
echo
echo "########## 2a. WHICH config DIRECTORY DOES THE ENGINE ACTUALLY READ ##########"
echo "  This is why the cache setting may never have applied. OpenMW prints its"
echo "  config search path at startup."
grep -a -i -E 'config|user-data|resource' "$G/openmw_log.txt" 2>/dev/null | head -12 | sed 's/^/    /'
echo "  -- what the launcher passes on the command line --"
grep -n -E '\-\-config|\-\-user-data|\-\-resources' "$S/Roms/PORTS/Morrowind.sh" 2>/dev/null | head -8 | sed 's/^/    /'
echo "  -- every settings.cfg and its mtime, so we can see which one is live --"
for c in $CFGS; do printf '    %s  %s\n' "$(ls -l "$c" | awk '{print $6, $7, $8}')" "$c"; done
echo

echo "########## 2b. WHAT DOES THE ENGINE THINK THE SOUND CACHE IS ##########"
grep -a -i -E 'buffer cache|sound.*cache|audio' "$G/openmw_log.txt" 2>/dev/null | head -10 | sed 's/^/    /'
echo "    (if nothing prints, the engine never logs the value and the only way to"
echo "     know it took is the source or a new log line)"
echo

echo "########## 2c. EVERY SNDWARM LINE, RAW, WITH NO INTERPRETATION ##########"
grep -a 'TSP_SNDWARM' "$G/openmw_log.txt" 2>/dev/null | sed 's/^/    /'
echo

echo "########## 2d. FRAMERATE EVIDENCE THAT DOES NOT NEED THE PROFILER ##########"
echo "  CULLDRAW is a separate log line, not the ring, so it costs nothing:"
grep -a 'TSP_CULLDRAW' "$G/openmw_log.txt" 2>/dev/null | tail -6 | sed 's/^/    /'
printf '    CULLDRAW lines this run: %s\n' "$(grep -ac 'TSP_CULLDRAW' "$G/openmw_log.txt" 2>/dev/null; true)"
echo "  memory right now:"
grep -E 'MemFree|MemAvailable|^Cached|SwapFree|SwapTotal' /proc/meminfo | sed 's/^/    /'
echo

echo "########## 2e. EVERY FILE I TOUCHED TONIGHT, WITH BACKUPS ##########"
echo "  so you can see the full blast radius and revert any of it by hand:"
ls -lt "$S"/tsp_iotune.conf.bak-* 2>/dev/null | head -6 | sed 's/^/    /'
ls -lt "$G"/config/settings.cfg.bak-* 2>/dev/null | head -6 | sed 's/^/    /'
ls -lt "$G"/config/openmw.cfg.bak-* 2>/dev/null | head -4 | sed 's/^/    /'
echo
echo "  markers currently in the launcher:"
grep -n 'TSP_RINGARM_V2\|TSP_TEXMOVE' "$S/Roms/PORTS/Morrowind.sh" 2>/dev/null | head -6 | sed 's/^/    /'
# ---- TSP_REVERT_END ----
REMOTE

cat <<'ASK'

==================================================================
 PART 3 - THE ONE THING I NEED THAT IS NOT ON THE DEVICE
==================================================================

The counters I built the whole sound theory on are printed by our own code, and
I never read it. Please run this against the build container and paste the
result. It is read-only.

  docker exec openmw_builder sh -c '
    grep -rn "TSP_SNDWARM" --include=*.cpp --include=*.hpp /openmw 2>/dev/null | head -20'

and then, using whatever file that points at:

  docker exec openmw_builder sh -c '
    grep -n -B30 "TSP_SNDWARM" $(docker exec openmw_builder sh -c \
      "grep -rl TSP_SNDWARM --include=*.cpp /openmw | head -1")'

If the paths are different in your container, just tell me the repo root and I
will adjust. What I specifically need to see:

  - what warmed / cached / failed are actually COUNTING
  - what set of sounds the warm iterates over, and where that set comes from
  - whether it consults the engine sound cache at all, or its own map

Because "cached=13 forever" reads two completely different ways and I picked one
without checking:
  (a) 18 decoded, only 13 retained  -> eviction, which is what I assumed
  (b) the region has 13 sounds, all already cached, nothing to do
      -> nothing is wrong and I wasted your session and 16 MB of RAM

Under (b) the 36-41 ms spikes are still real, but they come from somewhere the
warm never covers - the 09-08 doc names updateWaterSound as the other half of
the alternating pair, and a region-ambient warm would not touch water at all.

==================================================================

ASK
echo "full report: $REP"
