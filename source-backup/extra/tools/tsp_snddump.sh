#!/usr/bin/env bash
# TSP_SNDDUMP_V1 - dump every piece of the sound-load path, verbatim, with line
# numbers. READ ONLY. Nothing is built, nothing is patched, nothing is deployed.
#
#   bash ~/Downloads/tsp_snddump.sh
#
# Why this exists, and why it is not another patch:
#
# Four things I shipped for the sound problem were settings changes, and all four
# were wrong. The last one (buffer cache 24/32) tanked the framerate. The one
# before it (TSP_SNDWARM_MAX=64) did nothing because 18 was never a cap. Both were
# written off a theory about code I had not read. So: read the code first.
#
# The live hypothesis, which this dump either confirms or kills:
#
#   tspWarmCellSounds decodes 18 sounds to raw PCM in one burst at the end of the
#   load screen. 18 x 30s mono 44.1k 16-bit = 45 MB. 18 x 60s stereo = 182 MB.
#   `buffer cache max` is 16 MB. So either the pool evicts continuously from that
#   moment on, or the decode dumps tens of MB into the heap exactly when RSS is at
#   its peak - which is a reclaim storm that starts when the load screen lifts and
#   settles about 45 seconds later. That is the symptom described: 15-18 fps for
#   ~45 s after play starts, then it recovers.
#
# What I need to see to write the real fix, in order of importance:
#   1. tspWarmCellSounds, COMPLETE - what it iterates, what warmed/cached/failed
#      count, and whether it holds a reference that keeps 18 buffers alive forever.
#   2. the sound buffer pool - load, unload, evict, the cache accounting, and every
#      call site of unloadUnused. If the pool cannot hold 18 and the warm pins 18,
#      that is the bug and it is a source bug.
#   3. SoundManager::update() - the order of the phases and what runs every frame.
#   4. OpenALOutput::loadSound - the synchronous ffmpeg-open + readAll + alBufferData
#      that costs ~33 ms per first play.
#
# Output goes to a single text file, printed at the end.

set -u
OUT="${HOME}/Downloads/tsp-snddump-$(date +%Y%m%d-%H%M%S).txt"

# ---------------------------------------------------------------- discovery ---
FOUND_C=""
FOUND_ROOT=""
KNOWN_ROOT="/root/openmw-0.51-tsp-src"

{
echo "########## 0. WHERE THE SOURCE IS ##########"
if ! command -v docker >/dev/null 2>&1; then
    echo "  docker not on PATH"
    CONTS=""
else
    CONTS="$(docker ps -a --format '{{.Names}}' 2>/dev/null)"
    docker ps -a --format '{{.Names}}  {{.Status}}' 2>/dev/null | sed 's/^/  /'
fi

# fast path: the root written down in source-and-build-map.md
for c in $CONTS; do
    if docker exec "$c" test -d "$KNOWN_ROOT/apps/openmw/mwsound" 2>/dev/null; then
        FOUND_C="$c"; FOUND_ROOT="$KNOWN_ROOT"
        break
    fi
done
# slow path: go looking
if [ -z "$FOUND_ROOT" ]; then
    for c in $CONTS; do
        hit="$(docker exec "$c" sh -c \
            "find / /root /home /src /build /opt -maxdepth 6 -type d -name mwsound 2>/dev/null | head -1" \
            2>/dev/null)"
        if [ -n "$hit" ]; then
            FOUND_C="$c"
            FOUND_ROOT="$(dirname "$(dirname "$(dirname "$hit")")")"
            break
        fi
    done
fi
if [ -z "$FOUND_ROOT" ]; then
    hit="$(find "$HOME" /src /build /opt -maxdepth 7 -type d -name mwsound 2>/dev/null | head -1)"
    if [ -n "$hit" ]; then
        FOUND_ROOT="$(dirname "$(dirname "$(dirname "$hit")")")"
    fi
fi

if [ -z "$FOUND_ROOT" ]; then
    echo "  NOT FOUND. Looked in these containers for apps/openmw/mwsound:"
    echo "      $CONTS"
    echo "  and on this VM under \$HOME /src /build /opt."
    echo "  Tell me the real path and I will target it directly."
    exit 0
fi

echo "  container:   ${FOUND_C:-<none, host tree>}"
echo "  source root: $FOUND_ROOT"
echo

# ------------------------------------------------------------------ helpers ---
runq() {
    if [ -n "$FOUND_C" ]; then docker exec "$FOUND_C" sh -c "$1" 2>/dev/null
    else sh -c "$1" 2>/dev/null; fi
}

# show FILE FIRST LAST LABEL   - verbatim with real line numbers
show() {
    echo "  ---- $4"
    if [ "$3" = "999999" ]; then echo "  ---- $1  (whole file)"
    else echo "  ---- $1  lines $2-$3"; fi
    runq "awk -v a=$2 -v b=$3 '{ if (NR>=a && NR<=b) printf \"%6d  %s\\n\", NR, \$0 }' '$1'" \
        | sed 's/^/  /'
    echo
}

# lineof FILE PATTERN          - first matching line number, or empty
lineof() {
    runq "grep -n -e '$2' '$1' | head -1 | cut -d: -f1"
}

# showfn FILE PATTERN SPAN LABEL
showfn() {
    ln="$(lineof "$1" "$2")"
    if [ -z "$ln" ]; then
        echo "  ---- $4: PATTERN NOT FOUND in $1"
        echo "  ---- pattern was: $2"
        echo "  ---- every function definition in that file, for the survey:"
        runq "grep -n -e '^[A-Za-z_].*::.*(' '$1' | head -40" | sed 's/^/      /'
        echo
        return
    fi
    a=$((ln - 4)); [ "$a" -lt 1 ] && a=1
    b=$((ln + $3))
    show "$1" "$a" "$b" "$4"
}

MWS="$FOUND_ROOT/apps/openmw/mwsound"

echo "########## 1. WHAT IS IN mwsound ##########"
runq "ls -la '$MWS'" | sed 's/^/  /'
echo
echo "  -- every TSP_ marker in mwsound, file:line --"
runq "grep -rn 'TSP_[A-Z_0-9]*' '$MWS' | head -40" | sed 's/^/    /'
echo

echo "########## 2. tspWarmCellSounds - COMPLETE ##########"
echo "  Question 1: what collection does it iterate, and how big can it be."
echo "  Question 2: what do warmed / cached / failed actually increment on."
echo "  Question 3: does anything it creates outlive the function. If it keeps a"
echo "              Sound_Buffer* or a handle alive, 18 buffers are PINNED and the"
echo "              pool can never evict them - that is the bug, in source."
echo
SRC="$MWS/soundmanagerimp.cpp"
showfn "$SRC" "tspWarmCellSounds" 110 "tspWarmCellSounds (from its comment header)"

echo "########## 3. THE SOUND BUFFER POOL ##########"
echo "  If loadSound/lookup returns something ref-counted and the warm holds it,"
echo "  mBufferCacheMax is irrelevant and the 16 MB budget is permanently blown."
echo
for f in soundbuffer.hpp soundbuffer.cpp sound_buffer.hpp sound_buffer.cpp; do
    if runq "test -f '$MWS/$f' && echo yes" | grep -q yes; then
        show "$MWS/$f" 1 999999 "$f - WHOLE FILE"
    fi
done
echo "  -- every unloadUnused call site in the tree --"
runq "grep -rn 'unloadUnused' '$FOUND_ROOT/apps' '$FOUND_ROOT/components' | head -20" | sed 's/^/    /'
echo
echo "  -- every mBufferCache / buffer cache reference --"
runq "grep -rn 'mBufferCache\|buffer cache\|BufferCache' '$FOUND_ROOT/apps' '$FOUND_ROOT/components' | head -30" | sed 's/^/    /'
echo

echo "########## 4. SoundManager::update - THE PER-FRAME ORDER ##########"
echo "  The 09-08 doc put the spike in updateRegionSound / updateWaterSound, both"
echo "  ending in a synchronous playSound. Both are called from here."
echo
#   NOTE: the pattern keeps the open paren on purpose. Without it, grep matches
#   `void SoundManager::updateRegionSound` first - it is ~280 lines earlier in the
#   file - and this section would dump the wrong function and never show update()
#   at all. Caught by running this script against a fixture, not by reading it.
showfn "$SRC" "void SoundManager::update(" 130 "SoundManager::update"
showfn "$SRC" "void SoundManager::updateRegionSound" 45 "updateRegionSound"
showfn "$SRC" "void SoundManager::updateWaterSound" 45 "updateWaterSound"
echo "  -- the TSP_SOUNDPHASE_V1 markers and the 130 lines they sit in --"
PH="$(lineof "$SRC" "TSP_SOUNDPHASE")"
if [ -n "$PH" ]; then
    a=$((PH - 20)); [ "$a" -lt 1 ] && a=1
    show "$SRC" "$a" "$((PH + 130))" "soundmanagerimp.cpp around the phase markers"
else
    echo "    no TSP_SOUNDPHASE marker in $SRC"
    echo
fi

echo "########## 5. THE SYNCHRONOUS DECODE ITSELF ##########"
echo "  ffmpeg open + readAll + alBufferData on the calling thread, ~33 ms each."
echo "  This is what the warm was built to move off the gameplay thread, and what"
echo "  the real fix has to either budget across frames or stream."
echo
for f in openal_output.cpp openal_output.hpp; do
    if runq "test -f '$MWS/$f' && echo yes" | grep -q yes; then
        showfn "$MWS/$f" "OpenAL_Output::loadSound" 80 "$f :: loadSound"
        showfn "$MWS/$f" "OpenAL_Output::unloadSound" 20 "$f :: unloadSound"
    fi
done
echo "  -- anything named loadSound anywhere, in case the names differ --"
runq "grep -rn 'loadSound' '$FOUND_ROOT/apps/openmw/mwsound' | head -20" | sed 's/^/    /'
echo

echo "########## 6. THE CALL INTO THE WARM, FROM THE LOAD SCREEN ##########"
echo "  scene.cpp:1269 says the load screen is still up at this point. If the warm"
echo "  is on the load screen but the DECODE is deferred, the cost lands in play."
echo
SCN="$FOUND_ROOT/apps/openmw/mwworld/scene.cpp"
runq "grep -n 'tspWarmCellSounds\|TSP_SNDWARM' '$SCN'" | sed 's/^/    /'
echo
for L in $(runq "grep -n 'tspWarmCellSounds' '$SCN' | cut -d: -f1"); do
    a=$((L - 12)); [ "$a" -lt 1 ] && a=1
    b=$((L + 8))
    show "$SCN" "$a" "$b" "scene.cpp call site at line $L"
done

echo "########## 7. THE HEADER, SO I CAN SEE WHAT IS A MEMBER ##########"
HDR="$MWS/soundmanagerimp.hpp"
runq "grep -n 'tspWarm\|mSoundBuffers\|SoundBufferPool\|mBufferCache\|TSP_' '$HDR'" | sed 's/^/    /'
echo
for L in $(runq "grep -n 'tspWarm' '$HDR' | cut -d: -f1 | head -1"); do
    a=$((L - 10)); [ "$a" -lt 1 ] && a=1
    b=$((L + 10))
    show "$HDR" "$a" "$b" "soundmanagerimp.hpp around the warm declaration"
done

echo "########## 8. GIT LOG - WHEN THE WARM WENT IN ##########"
echo "  Steve says the stutters appeared around when this was added. The commit"
echo "  dates settle that without another play session."
runq "cd '$FOUND_ROOT' && git log --oneline -20 -- apps/openmw/mwsound apps/openmw/mwworld/scene.cpp" \
    | sed 's/^/    /'
echo
runq "cd '$FOUND_ROOT' && git log --oneline -12" | sed 's/^/    /'
echo

echo "########## 9. WHAT I WILL DO WITH THIS ##########"
cat <<'NOTE'
  Three outcomes, and the fix each one implies. No settings in any of them.

  A. The warm PINS the 18 buffers (holds a ref, or inserts into a container that
     outlives the call, or marks them non-evictable). Then the pool is permanently
     over budget from the end of the load, evicts on every update, and the fix is
     in the warm: release after warming, or warm into the pool the way a real play
     does and let the pool own the lifetime.

  B. The warm does NOT pin, and cached=13 is just "already present". Then nothing
     is evicted, the warm is harmless, and the 36-41 ms spikes come from a call
     site the warm never covers. updateWaterSound is already covered, so the next
     candidate is whatever playSound path the region set does not include - and
     the fix is to make loadSound non-blocking for the FIRST play, not to warm more.

  C. The decode itself is the allocation spike: 18 sounds to raw PCM in one burst,
     tens of MB, at peak RSS. Then the fix is to spread the warm over frames with a
     real byte budget, or to warm only what the current cell can actually play, or
     to decode at a lower rate. Sizing it needs the actual PCM bytes, which is why
     section 3 wants the pool accounting.

  All three are source patches to apps/openmw/mwsound. None is a settings change.
NOTE
} 2>&1 | tee "$OUT"

echo
echo "full report: $OUT"
