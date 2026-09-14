#!/usr/bin/env bash
# TSP_SNDSRC_V1 - find the sound-warm source wherever it is and print it.
#
#   bash ~/Downloads/tsp_sndsrc.sh
#
# Read only. Nothing is built, nothing is changed, no container is started.
#
# My last attempt hardcoded /openmw inside the container and returned nothing.
# This discovers the container and the source root instead of assuming either,
# and searches the host VM too in case the tree lives there. If it still finds
# nothing it says exactly where it looked.
#
# What I am after, and why: the whole sound theory rests on what warmed / cached
# / failed actually COUNT in `TSP_SNDWARM_V1 ... warmed=18 cached=1 failed=1`.
# I asserted "18 decoded, 13 retained, 5 evicted" without reading the code. It
# reads equally well as "the region has 13 sounds, all already cached, nothing to
# do" - in which case nothing was wrong and I wasted a session. The source settles
# it in one look.
#
# Also wanted: the call sites the 09-08 doc named as the real spike source -
# updateRegionSound and updateWaterSound both ending in a synchronous playSound.
# A region-ambient warm would never cover the water one.

set -u
OUT="${HOME}/Downloads/tsp-sndsrc-$(date +%Y%m%d-%H%M%S).txt"
MARK="${MARK:-TSP_SNDWARM}"

{
echo "########## 1. CONTAINERS ##########"
if ! command -v docker >/dev/null 2>&1; then
    echo "  docker not on PATH - skipping containers, will search the host only"
    CONTS=""
else
    docker ps -a --format '{{.Names}}  {{.Status}}  {{.Image}}' 2>/dev/null | sed 's/^/  /'
    CONTS="$(docker ps -a --format '{{.Names}}' 2>/dev/null)"
    [ -n "$CONTS" ] || echo "  (no containers)"
fi
echo

echo "########## 2. WHERE IS THE OPENMW SOURCE ##########"
# A tree that contains apps/openmw/mwsound is the one we want. Bounded depth so
# this cannot turn into a full filesystem walk.
FOUND_C=""; FOUND_P=""
for c in $CONTS; do
    for root in / /root /home /src /build /openmw /opt /workspace; do
        hit="$(docker exec "$c" sh -c \
            "find $root -maxdepth 6 -type d -name mwsound 2>/dev/null | head -3" 2>/dev/null)"
        if [ -n "$hit" ]; then
            echo "  container [$c] has mwsound at:"
            echo "$hit" | sed 's/^/      /'
            FOUND_C="$c"
            FOUND_P="$(echo "$hit" | head -1)"
            break
        fi
    done
    [ -n "$FOUND_C" ] && break
done
if [ -z "$FOUND_C" ]; then
    echo "  no container had an apps/openmw/mwsound directory in the roots tried:"
    echo "      / /root /home /src /build /openmw /opt /workspace  (maxdepth 6)"
    echo "  -- searching this VM instead --"
    hit="$(find "$HOME" /src /build /opt /usr/src -maxdepth 7 -type d -name mwsound 2>/dev/null | head -3)"
    if [ -n "$hit" ]; then
        echo "$hit" | sed 's/^/      /'
        FOUND_P="$(echo "$hit" | head -1)"
    else
        echo "      nothing on the VM either"
    fi
fi
echo

echo "########## 3. THE MARKER, ANYWHERE IN THE TREE ##########"
runq() {   # runq <cmd>  - run in the container if we found one, else on the host
    if [ -n "$FOUND_C" ]; then docker exec "$FOUND_C" sh -c "$1" 2>/dev/null
    else sh -c "$1" 2>/dev/null; fi
}
if [ -z "$FOUND_P" ]; then
    echo "  no source tree located, so nothing to grep. See section 2 for where"
    echo "  I looked - tell me the real path and I will target it directly."
else
    # the repo root is the parent of apps/openmw/mwsound
    ROOT="$(dirname "$(dirname "$(dirname "$FOUND_P")")")"
    echo "  source root: $ROOT"
    echo "  (in container [$FOUND_C])"
    echo
    echo "  -- every file mentioning $MARK --"
    runq "grep -rln '$MARK' '$ROOT' 2>/dev/null | head -10" | sed 's/^/    /'
    echo
    echo "  -- every line, with file:line --"
    runq "grep -rn '$MARK' '$ROOT' 2>/dev/null | head -20" | sed 's/^/    /'
    echo

    F="$(runq "grep -rln '$MARK' '$ROOT' 2>/dev/null | head -1")"
    if [ -n "$F" ]; then
        echo "########## 4. THE FUNCTION THAT PRINTS THE COUNTERS ##########"
        echo "  file: $F"
        echo "  -- 60 lines before the marker through 10 after --"
        runq "grep -n '$MARK' '$F' | head -1 | cut -d: -f1" > /tmp/.ln.$$ 2>/dev/null
        LN="$(cat /tmp/.ln.$$ 2>/dev/null)"; rm -f /tmp/.ln.$$
        if [ -n "$LN" ]; then
            A=$((LN - 60)); [ "$A" -lt 1 ] && A=1
            B=$((LN + 10))
            runq "sed -n '${A},${B}p' '$F'" | sed 's/^/    /'
        fi
        echo
    fi

    echo "########## 5. THE CALL SITES THE 09-08 DOC BLAMED ##########"
    echo "  updateRegionSound / updateWaterSound, both ending in playSound."
    echo "  A region-ambient warm would not cover the water one at all."
    for fn in updateRegionSound updateWaterSound; do
        echo "  -- $fn --"
        runq "grep -rn '$fn' '$ROOT' 2>/dev/null | head -6" | sed 's/^/      /'
    done
    echo
    echo "  -- the sound buffer cache, to see if 'buffer cache max' is even read --"
    runq "grep -rn 'buffer cache' '$ROOT' 2>/dev/null | head -8" | sed 's/^/      /'
    echo
    echo "  -- other TSP_ sound markers in the tree --"
    runq "grep -rhon 'TSP_[A-Z_0-9]*' '$ROOT/apps/openmw/mwsound' 2>/dev/null | sort -u | head -20" | sed 's/^/      /'
fi
echo

echo "########## 6. WHAT THIS SHOULD TELL US ##########"
cat <<'NOTE'
  From section 4, three specific questions:
    - what does `warmed` increment on, and what does `cached` increment on
    - what collection does the loop iterate, and where does it come from
    - does it touch the engine sound buffer cache, or its own container

  If `cached` counts "was already present" then cached=13 forever is CORRECT
  behaviour, nothing is being evicted, and the buffer-cache change I made was
  pure cost. The 36-41 ms spikes would then be coming from a call site the warm
  never covers, and updateWaterSound is the named candidate.
NOTE
} 2>&1 | tee "$OUT"

echo
echo "full report: $OUT"
