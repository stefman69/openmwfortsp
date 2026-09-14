#!/usr/bin/env bash
# TSP_SNDWARM_V2 - patch, build, deploy, verify. ONE command.
#
#   bash ~/Downloads/tsp_sndwarm_v2.sh          # patch + build + deploy + arm
#   bash ~/Downloads/tsp_sndwarm_v2.sh pull     # after playing: pull the results
#   bash ~/Downloads/tsp_sndwarm_v2.sh revert    # restore the .before-sndwarmv2 files + rebuild
#
# THE BUG, from the source you dumped - not a settings change, not a theory:
#
#   SoundBufferPool::loadSfx (soundbuffer.cpp:81) does
#       mBufferCacheSize += size;
#       if (mBufferCacheSize > mBufferCacheMax) unloadUnused();
#       mUnusedBuffers.push_front(sfx);
#   and unloadUnused() frees from the BACK of mUnusedBuffers.
#
#   tspWarmCellSounds never calls use() on anything it loads, so every warmed
#   buffer sits in mUnusedBuffers with mUses == 0 and the deque order IS warm
#   order. The back is the id warmed FIRST.
#
#   V1 warmed water, then the region ambients, then every weather ambient loop,
#   rain loop and thunder. Once the total passed `buffer cache max`, each further
#   load freed the earliest entries - water and the region ambients, the exact set
#   updateRegionSound starts playing seconds later - to make room for the weather
#   loops, which are the biggest files in the set and are never played unless the
#   weather changes.
#
#   updateRegionSound then re-decoded the region set one sound at a time on the
#   gameplay thread, ~33 ms each, and every decode evicted another member of the
#   same set, so the next pick missed too. That thrash runs until the played set
#   fits under `buffer cache min`. That is your 15-18 fps for ~45 seconds that
#   then recovers on its own.
#
#   And it was invisible: `warmed` counted load() calls, not survivors, and the
#   "No unused sound buffers to free" warning at soundbuffer.cpp:96 is dead code -
#   after unloadUnused() returns, !mUnusedBuffers.empty() && size > max can never
#   both be true. So the one diagnostic that would have shown cache pressure has
#   never printed once.
#
# THE FIX, three source edits:
#   soundbuffer.hpp      + 3 inline cache accessors
#   soundbuffer.cpp      the dead warning condition inverted so it can fire
#   soundmanagerimp.cpp  tspWarmCellSounds -> V2: deduped, split into a CORE tier
#                        (water + region ambients) and an OPTIONAL tier (weather),
#                        each capped by total cache bytes so the warm stays at or
#                        under `buffer cache min` and can never trigger an
#                        eviction, and it logs resident= survivors.

set -u

TSP="root@192.168.1.12"
SSH_OPTS="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes"
CONT="openmw_builder"
SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"
GAME="/mnt/SDCARD/data/ports/openmw"
BIN="$GAME/bin/openmw-0.51"
MARK="TSP_SNDWARM_V2"
STAMP="$(date +%Y%m%d-%H%M%S)"
PATCHER="/root/tsp_patch_sndwarm_v2.py"
PATCHER_MD5="c1655e3ca827b96af150dcc5628cc07d"

# Rule Zero #3: exactly two ssh wrappers, and nothing else calls ssh.
r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }      # command string. -n closes stdin.
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }      # heredoc callers ONLY. never -n.

die() { echo; echo "ABORT: $*"; exit 1; }
say() { echo; echo "=========== $* ==========="; }

MODE="${1:-deploy}"

# ----------------------------------------------------------------- pull mode ---
if [ "$MODE" = "pull" ]; then
    OUT="${HOME}/Downloads/tsp-sndwarm-v2-$STAMP.txt"
    {
    echo "########## THE WARM LINES ##########"
    echo "  resident_core must equal core. If it is lower, the warm is STILL"
    echo "  evicting itself and the core budget has to come down."
    r "grep -a 'TSP_SNDWARM_V' $GAME/config-0.51/openmw.log 2>/dev/null" | sed 's/^/  /'
    echo
    echo "########## CACHE PRESSURE - now that the warning can actually fire ##########"
    r "grep -a 'No unused sound buffers' $GAME/config-0.51/openmw.log 2>/dev/null" | sed 's/^/  /'
    echo "  (no lines here = the cache never ran out of evictable buffers: good)"
    echo
    echo "########## THE PER-FRAME SOUND PHASES ##########"
    echo "  TSP_SOUNDPHASE_V1 prints when sound total >= 15 ms. Fewer lines than"
    echo "  before the patch is the result we want; regionSound= is the one to watch."
    r "grep -a 'TSP_SOUNDPHASE_V1' $GAME/config-0.51/openmw.log 2>/dev/null" | sed 's/^/  /'
    echo
    echo "########## LOAD LADDER, for the timeline ##########"
    r "grep -a 'mechanics-playerLoaded\|projectile-casters-updated\|TSP_SNDWARM' $GAME/openmw_log.txt 2>/dev/null | tail -40" | sed 's/^/  /'
    echo
    echo "########## SANITY: is the deployed binary the patched one ##########"
    r "if grep -a -q '$MARK' $BIN; then echo '  DEVICE HAS $MARK'; else echo '  DEVICE IS MISSING $MARK - the numbers above are from OLD code'; fi"
    r "if [ -f /mnt/SDCARD/tsp_ring_off ]; then echo '  ring profiler: OFF (correct)'; else echo '  ring profiler: ARMED - it halves the framerate, that is not this bug'; fi"
    } 2>&1 | tee "$OUT"
    echo
    echo "full report: $OUT"
    exit 0
fi

# --------------------------------------------------------------- preflight -----
say "0. PREFLIGHT"
command -v docker >/dev/null 2>&1 || die "docker not on PATH"
docker ps --format '{{.Names}}' | grep -q "^${CONT}$" || die "container $CONT is not running"
docker exec "$CONT" test -d "$SRC/apps/openmw/mwsound" || die "no mwsound under $SRC"
docker exec "$CONT" test -f "$BUILD/build.ninja" \
    || die "$BUILD is not a ninja tree - do NOT use make here (agreement 22-A)"
r "test -f $BIN" || die "cannot reach $BIN on $TSP - is the device on and on the network"
echo "  container $CONT      OK"
echo "  ninja tree $BUILD    OK"
echo "  device $TSP          OK"
r "if [ -f /mnt/SDCARD/tsp_ring_off ]; then echo '  ring profiler OFF   OK'; else echo '  ring profiler ARMED - leaving it alone, but it will distort the run'; fi"
echo "  current sound settings on the device:"
r "grep -a -i 'buffer cache' $GAME/config-0.51/settings.cfg 2>/dev/null" | sed 's/^/    /'
r "grep -a -o 'TSP_SNDWARM_[A-Z]*=[^ ]*' /mnt/SDCARD/Roms/PORTS/Morrowind.sh 2>/dev/null | sort -u" | sed 's/^/    launcher: /'

# --------------------------------------------------------------- revert mode ---
if [ "$MODE" = "revert" ]; then
    say "REVERT"
    docker exec "$CONT" sh -s <<'REVEOF'
set -e
cd /root/openmw-0.51-tsp-src/apps/openmw/mwsound
N=0
for f in soundbuffer.hpp soundbuffer.cpp soundmanagerimp.cpp; do
    if [ -f "$f.before-sndwarmv2" ]; then
        cp -p "$f.before-sndwarmv2" "$f"
        echo "  restored $f"
        N=$((N+1))
    else
        echo "  no backup for $f - left as is"
    fi
done
[ "$N" -gt 0 ] || { echo "REFUSING: nothing to restore"; exit 1; }
REVEOF
    [ $? -eq 0 ] || die "revert refused, nothing changed"
    echo "  rebuilding"
    docker exec "$CONT" cmake --build "$BUILD" --target openmw -- -j2 || die "build failed"
    docker cp "$CONT:$BUILD/openmw" /tmp/openmw-staged || die "docker cp failed"
    if grep -a -q "$MARK" /tmp/openmw-staged; then die "reverted binary still has $MARK"; fi
    r "cp -p $BIN $BIN.before-revert-$STAMP" || die "device backup failed"
    rin "cat > $BIN.new" < /tmp/openmw-staged || die "upload failed"
    r "mv $BIN.new $BIN && chmod +x $BIN" || die "swap failed"
    echo "  REVERTED and deployed. Launch Morrowind from your ports menu."
    exit 0
fi

# --------------------------------------------------------- 1. ship the patcher -
say "1. SHIP THE PATCHER INTO THE CONTAINER"
docker exec -i "$CONT" sh -c "base64 -d > $PATCHER" <<'B64EOF'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwojIFRTUF9TTkRXQVJNX1YyIHBhdGNoZXIuCiMKIyBUaHJl
ZSBlZGl0cywgYWxsIHNvdXJjZSwgYWxsIGluIGFwcHMvb3Blbm13L213c291bmQ6CiMKIyAgIDEu
IHNvdW5kYnVmZmVyLmhwcCAgLSBleHBvc2UgdGhlIGNhY2hlIGFjY291bnRpbmcgKDMgaW5saW5l
IGFjY2Vzc29ycykuCiMgICAyLiBzb3VuZGJ1ZmZlci5jcHAgIC0gZml4IHRoZSB1bnJlYWNoYWJs
ZSBvdmVyLWJ1ZGdldCB3YXJuaW5nIGluIGxvYWRTZnguCiMgICAzLiBzb3VuZG1hbmFnZXJpbXAu
Y3BwIC0gcmVwbGFjZSB0c3BXYXJtQ2VsbFNvdW5kcyB3aXRoIHRoZSBidWRnZXRlZCwgb3JkZXJl
ZCwKIyAgICAgICAgICAgICAgICAgICAgICAgICAgICBkZWR1cGVkIFYyIHRoYXQgcmVwb3J0cyBy
ZXNpZGVudCBzdXJ2aXZvcnMuCiMKIyBBbGwtb3Itbm90aGluZzogZXZlcnkgYW5jaG9yIGluIGV2
ZXJ5IGZpbGUgbXVzdCBtYXRjaCBleGFjdGx5IG9uY2UsIGJyYWNlIGJhbGFuY2UKIyBtdXN0IGJl
IHByZXNlcnZlZCwgb3IgTk9USElORyBpcyB3cml0dGVuLgojCiMgSWRlbXBvdGVudDogcmUtcnVu
bmluZyBhZnRlciBhIHN1Y2Nlc3NmdWwgYXBwbHkgY2hhbmdlcyBub3RoaW5nIGFuZCBleGl0cyAw
LgoKaW1wb3J0IG9zCmltcG9ydCByZQppbXBvcnQgc3lzCgpST09UID0gc3lzLmFyZ3ZbMV0gaWYg
bGVuKHN5cy5hcmd2KSA+IDEgZWxzZSAiL3Jvb3Qvb3Blbm13LTAuNTEtdHNwLXNyYyIKTVdTID0g
b3MucGF0aC5qb2luKFJPT1QsICJhcHBzIiwgIm9wZW5tdyIsICJtd3NvdW5kIikKCkhQUCA9IG9z
LnBhdGguam9pbihNV1MsICJzb3VuZGJ1ZmZlci5ocHAiKQpCVUYgPSBvcy5wYXRoLmpvaW4oTVdT
LCAic291bmRidWZmZXIuY3BwIikKU01JID0gb3MucGF0aC5qb2luKE1XUywgInNvdW5kbWFuYWdl
cmltcC5jcHAiKQoKIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tIGVkaXQgMTogaHBwIC0tLQojIFNpbmdsZS1saW5lIGFuY2hv
ci4gYHZvaWQgY2xlYXIoKTtgIG9jY3VycyBleGFjdGx5IG9uY2UgaW4gdGhlIGhlYWRlci4KSFBQ
X0FOQ0hPUiA9ICIgICAgICAgIHZvaWQgY2xlYXIoKTtcbiIKSFBQX01BUksgPSAidHNwR2V0Q2Fj
aGVTaXplIgpIUFBfSU5TRVJUID0gKAogICAgIiAgICAgICAgLy8gVFNQX1NORFdBUk1fVjIgLSB0
aGUgY2FjaGUgYWNjb3VudGluZyBhIGJ1ZGdldGVkIHdhcm0gbmVlZHMuIFJlYWQtb25seTtcbiIK
ICAgICIgICAgICAgIC8vIGlubGluZSwgc28gbm8gbmV3IHN5bWJvbHMgYW5kIG5vIGxpbmstb3Jk
ZXIgc3VycHJpc2VzLlxuIgogICAgIiAgICAgICAgc3RkOjpzaXplX3QgdHNwR2V0Q2FjaGVTaXpl
KCkgY29uc3Qgbm9leGNlcHQgeyByZXR1cm4gbUJ1ZmZlckNhY2hlU2l6ZTsgfVxuIgogICAgIiAg
ICAgICAgc3RkOjpzaXplX3QgdHNwR2V0Q2FjaGVNaW4oKSBjb25zdCBub2V4Y2VwdCB7IHJldHVy
biBtQnVmZmVyQ2FjaGVNaW47IH1cbiIKICAgICIgICAgICAgIHN0ZDo6c2l6ZV90IHRzcEdldENh
Y2hlTWF4KCkgY29uc3Qgbm9leGNlcHQgeyByZXR1cm4gbUJ1ZmZlckNhY2hlTWF4OyB9XG4iCiAg
ICAiXG4iCikKCiMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLSBlZGl0IDI6IGJ1ZiAtLS0KIyBUaGUgd2FybmluZyBiZWxvdyB0
aGlzIGxpbmUgY2FuIG5ldmVyIHByaW50LiBBZnRlciB1bmxvYWRVbnVzZWQoKSByZXR1cm5zLCBl
aXRoZXIKIyBtVW51c2VkQnVmZmVycyBpcyBlbXB0eSwgb3IgbUJ1ZmZlckNhY2hlU2l6ZSA8PSBt
QnVmZmVyQ2FjaGVNaW4gPD0gbUJ1ZmZlckNhY2hlTWF4LgojIFNvIGAhbVVudXNlZEJ1ZmZlcnMu
ZW1wdHkoKSAmJiBtQnVmZmVyQ2FjaGVTaXplID4gbUJ1ZmZlckNhY2hlTWF4YCBpcyBhbHdheXMg
ZmFsc2UsCiMgYW5kIHRoZSBvbmUgZGlhZ25vc3RpYyB0aGF0IHdvdWxkIGhhdmUgdG9sZCB1cyB0
aGUgc291bmQgY2FjaGUgd2FzIHRocmFzaGluZyBoYXMKIyBiZWVuIGRlYWQgc2luY2UgdGhlIHJl
ZmFjdG9yLiBJbnZlcnQgaXQgdG8gdXBzdHJlYW0ncyBpbnRlbnQuCkJVRl9PTEQgPSAiICAgICAg
ICAgICAgaWYgKCFtVW51c2VkQnVmZmVycy5lbXB0eSgpICYmIG1CdWZmZXJDYWNoZVNpemUgPiBt
QnVmZmVyQ2FjaGVNYXgpXG4iCkJVRl9ORVcgPSAoCiAgICAiICAgICAgICAgICAgLy8gVFNQX1NO
RENBQ0hFX1dBUk5fVjIgLSB3YXMgIW1VbnVzZWRCdWZmZXJzLmVtcHR5KCksIHdoaWNoIGlzXG4i
CiAgICAiICAgICAgICAgICAgLy8gdW5yZWFjaGFibGUgaGVyZTogdW5sb2FkVW51c2VkKCkgcmV0
dXJucyBvbmx5IHdoZW4gdGhlIGRlcXVlIGlzXG4iCiAgICAiICAgICAgICAgICAgLy8gZW1wdHkg
b3IgdGhlIGNhY2hlIGlzIGJhY2sgdW5kZXIgbWluLiBUaGUgd2FybmluZyBuZXZlciBwcmludGVk
LlxuIgogICAgIiAgICAgICAgICAgIGlmIChtVW51c2VkQnVmZmVycy5lbXB0eSgpICYmIG1CdWZm
ZXJDYWNoZVNpemUgPiBtQnVmZmVyQ2FjaGVNYXgpXG4iCikKQlVGX01BUksgPSAiVFNQX1NORENB
Q0hFX1dBUk5fVjIiCgojIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0gZWRpdCAzOiBzbWkgLS0tClNNSV9TSUcgPSAiICAgIHZv
aWQgU291bmRNYW5hZ2VyOjp0c3BXYXJtQ2VsbFNvdW5kcyhjb25zdCBFU006OlJlZklkJiByZWdp
b24pXG4iClNNSV9NQVJLID0gIlRTUF9TTkRXQVJNX1YyIgoKU01JX05FVyA9IHInJycgICAgLyog
VFNQX1NORFdBUk1fVjIgLSB0aGUgd2FybSBpcyBCVURHRVRFRCwgT1JERVJFRCBhbmQgREVEVVBF
RC4KCiAgICAgICBXaGF0IFYxIGRpZCB3cm9uZywgbWVjaGFuaWNhbGx5OgoKICAgICAgIFYxIG5h
bWVkIGV2ZXJ5IGlkIGl0IGNvdWxkIHJlYWNoIC0gdGhlIHR3byB3YXRlciBpZHMsIGV2ZXJ5IHJl
Z2lvbiBhbWJpZW50LAogICAgICAgYW5kIGV2ZXJ5IHdlYXRoZXIgYW1iaWVudCBsb29wLCByYWlu
IGxvb3AgYW5kIHRodW5kZXIgLSBhbmQgY2FsbGVkCiAgICAgICBtU291bmRCdWZmZXJzLmxvYWQo
KSBvbiBhbGwgb2YgdGhlbS4gbG9hZCgpIC0+IGxvYWRTZngoKSBkZWNvZGVzIHRvIHJhdyBQQ00K
ICAgICAgIGFuZCBkb2VzOgoKICAgICAgICAgICBtQnVmZmVyQ2FjaGVTaXplICs9IHNpemU7CiAg
ICAgICAgICAgaWYgKG1CdWZmZXJDYWNoZVNpemUgPiBtQnVmZmVyQ2FjaGVNYXgpIHVubG9hZFVu
dXNlZCgpOwogICAgICAgICAgIG1VbnVzZWRCdWZmZXJzLnB1c2hfZnJvbnQoc2Z4KTsKCiAgICAg
ICB1bmxvYWRVbnVzZWQoKSBmcmVlcyBmcm9tIHRoZSBCQUNLIG9mIG1VbnVzZWRCdWZmZXJzLiBO
b3RoaW5nIHRoZSB3YXJtIGxvYWRzCiAgICAgICBpcyBldmVyIHVzZWQoKSwgc28gZXZlcnkgd2Fy
bWVkIGJ1ZmZlciBzaXRzIGluIHRoYXQgZGVxdWUgd2l0aCBtVXNlcyA9PSAwIGFuZAogICAgICAg
dGhlIGRlcXVlIG9yZGVyIGlzIHdhcm0gb3JkZXIuIFRoZSBiYWNrIGlzIHRoZXJlZm9yZSB0aGUg
aWQgd2FybWVkIEZJUlNULgoKICAgICAgIFNvIG9uY2UgdGhlIHdhcm0ncyB0b3RhbCBwYXNzZWQg
YGJ1ZmZlciBjYWNoZSBtYXhgLCBlYWNoIGZ1cnRoZXIgbG9hZCBmcmVlZAogICAgICAgdGhlIGVh
cmxpZXN0IHRoaW5nIHRoZSB3YXJtIGhhZCBsb2FkZWQ6IHRoZSB3YXRlciBpZHMsIHRoZW4gdGhl
IHJlZ2lvbgogICAgICAgYW1iaWVudHMgLSB0aGUgZXhhY3Qgc2V0IHVwZGF0ZVJlZ2lvblNvdW5k
IHN0YXJ0cyBwbGF5aW5nIHNlY29uZHMgbGF0ZXIgLSB0bwogICAgICAgbWFrZSByb29tIGZvciB0
aGUgd2VhdGhlciBhbWJpZW5jZSBsb29wcywgd2hpY2ggYXJlIHRoZSBsYXJnZXN0IGZpbGVzIGlu
IHRoZQogICAgICAgc2V0IGFuZCBhcmUgbm90IHBsYXllZCBhdCBhbGwgdW5sZXNzIHRoZSB3ZWF0
aGVyIGNoYW5nZXMuCgogICAgICAgdXBkYXRlUmVnaW9uU291bmQgdGhlbiByZS1kZWNvZGVkIHRo
ZSByZWdpb24gc2V0IG9uZSBzb3VuZCBhdCBhIHRpbWUgb24gdGhlCiAgICAgICBnYW1lcGxheSB0
aHJlYWQgKE9wZW5BTE91dHB1dDo6bG9hZFNvdW5kOiBmZm1wZWcgb3BlbiArIHJlYWRBbGwgKwog
ICAgICAgYWxCdWZmZXJEYXRhLCB+MzMgbXMgZWFjaCksIGFuZCBlYWNoIG9mIHRob3NlIGRlY29k
ZXMgZXZpY3RlZCBhbm90aGVyIG1lbWJlcgogICAgICAgb2YgdGhlIHNhbWUgc2V0LCBzbyB0aGUg
bmV4dCBwaWNrIG1pc3NlZCB0b28uIFRoYXQgaXMgYSB0aHJhc2ggbG9vcCB0aGF0IHJ1bnMKICAg
ICAgIHVudGlsIHRoZSBzZXQgYWN0dWFsbHkgYmVpbmcgcGxheWVkIGZpdHMgdW5kZXIgYGJ1ZmZl
ciBjYWNoZSBtaW5gIC0gdGhlCiAgICAgICByZXBvcnRlZCAxNS0xOCBmcHMgZm9yIHJvdWdobHkg
dGhlIGZpcnN0IDQ1IHNlY29uZHMgb2YgcGxheSwgcmVjb3ZlcmluZyBvbgogICAgICAgaXRzIG93
bi4KCiAgICAgICBWMSBjb3VsZCBub3Qgc2hvdyBhbnkgb2YgdGhpcy4gYHdhcm1lZGAgY291bnRl
ZCBsb2FkKCkgY2FsbHMsIG5vdCBzdXJ2aXZvcnMsCiAgICAgICBzbyB3YXJtZWQ9MTggd2FzIHJl
cG9ydGVkIHdoaWxlIHNvbWUgb2YgdGhvc2UgMTggd2VyZSBhbHJlYWR5IGZyZWVkOyBhbmQgdGhl
CiAgICAgICAiTm8gdW51c2VkIHNvdW5kIGJ1ZmZlcnMgdG8gZnJlZSIgd2FybmluZyBpbiBsb2Fk
U2Z4IHdhcyB1bnJlYWNoYWJsZSAoc2VlCiAgICAgICBUU1BfU05EQ0FDSEVfV0FSTl9WMiksIHNv
IGNhY2hlIHByZXNzdXJlIHdhcyBpbnZpc2libGUuCgogICAgICAgVjI6CiAgICAgICAgIC0gZGVk
dXBlIHRoZSBpZCBsaXN0LCBzbyBgY2FjaGVkYCBtZWFucyAiYWxyZWFkeSByZXNpZGVudCIgYW5k
IG5vdGhpbmcgZWxzZQogICAgICAgICAgICh0aHVuZGVyIGlkcyByZXBlYXQgYWNyb3NzIHdlYXRo
ZXIgdHlwZXMgYW5kIGluZmxhdGVkIGl0KTsKICAgICAgICAgLSBzcGxpdCBpbnRvIGEgQ09SRSB0
aWVyIHRoYXQgZ2FtZXBsYXkgYWN0dWFsbHkgcGxheXMgKHdhdGVyICsgcmVnaW9uCiAgICAgICAg
ICAgYW1iaWVudHMpIGFuZCBhbiBPUFRJT05BTCB0aWVyIHRoYXQgaXQgdXN1YWxseSBkb2VzIG5v
dCAod2VhdGhlcik7CiAgICAgICAgIC0gY2FwIGVhY2ggdGllciBieSB0b3RhbCBjYWNoZSBieXRl
cywgY29yZSBhdCBgYnVmZmVyIGNhY2hlIG1pbmAgYW5kCiAgICAgICAgICAgb3B0aW9uYWwgYXQg
aGFsZiBvZiBpdC4gU3RheWluZyBhdCBvciB1bmRlciBtaW4gaXMgd2hhdCBndWFyYW50ZWVzCiAg
ICAgICAgICAgbG9hZFNmeCBuZXZlciBjYWxscyB1bmxvYWRVbnVzZWQoKSB3aGlsZSB0aGUgd2Fy
bSBpcyBydW5uaW5nLCBzbyB0aGUgd2FybQogICAgICAgICAgIGNhbiBubyBsb25nZXIgZXZpY3Qg
aXRzZWxmOwogICAgICAgICAtIHJlcG9ydCByZXNpZGVudD0gOiBob3cgbWFueSBvZiB0aGUgaWRz
IGFyZSBzdGlsbCBsb2FkZWQgd2hlbiB0aGUgd2FybQogICAgICAgICAgIHJldHVybnMuIHJlc2lk
ZW50IDwgd2FybWVkIG1lYW5zIHRoZSBidWRnZXQgaXMgU1RJTEwgdG9vIGxhcmdlIGFuZCB0aGUK
ICAgICAgICAgICBuZXh0IHN0ZXAgaXMgdG8gbG93ZXIgaXQsIG5vdCB0byBndWVzcyBhZ2Fpbi4g
Ki8KICAgIHZvaWQgU291bmRNYW5hZ2VyOjp0c3BXYXJtQ2VsbFNvdW5kcyhjb25zdCBFU006OlJl
ZklkJiByZWdpb24pCiAgICB7CiAgICAgICAgaWYgKG1PdXRwdXQtPmlzSW5pdGlhbGl6ZWQoKSA9
PSBmYWxzZSB8fCBzdGQ6OmdldGVudigiVFNQX05PX1NORFdBUk0iKSAhPSBudWxscHRyKQogICAg
ICAgICAgICByZXR1cm47CgogICAgICAgIC8vIFNoYXJlIG9mIGBidWZmZXIgY2FjaGUgbWluYCB0
aGUgb3B0aW9uYWwgdGllciBtYXkgb2NjdXB5LiBOYW1lZCBzbyB0dW5pbmcKICAgICAgICAvLyBp
dCBpcyBhIG9uZS10b2tlbiBzZWQsIG5vdCBhIG5ldyBwYXRjaC4KICAgICAgICBjb25zdCBkb3Vi
bGUgdHNwT3B0aW9uYWxTaGFyZSA9IDAuNTsKCiAgICAgICAgY29uc3QgYXV0byB0c3BXYXJtU3Rh
cnQgPSBzdGQ6OmNocm9ubzo6c3RlYWR5X2Nsb2NrOjpub3coKTsKCiAgICAgICAgc3RkOjp2ZWN0
b3I8RVNNOjpSZWZJZD4gdHNwQ29yZUlkczsKICAgICAgICBzdGQ6OnZlY3RvcjxFU006OlJlZklk
PiB0c3BPcHRJZHM7CgogICAgICAgIC8vIEhhbmQtcm9sbGVkIHJhdGhlciB0aGFuIHN0ZDo6Zmlu
ZCBzbyB0aGlzIGFkZHMgbm8gaW5jbHVkZSB0byBhIGZpbGUgdGhhdAogICAgICAgIC8vIGRvZXMg
bm90IGFscmVhZHkgaGF2ZSA8YWxnb3JpdGhtPi4KICAgICAgICBjb25zdCBhdXRvIHRzcEFkZElk
ID0gW10oc3RkOjp2ZWN0b3I8RVNNOjpSZWZJZD4mIHRzcEludG8sIGNvbnN0IEVTTTo6UmVmSWQm
IHRzcElkKSB7CiAgICAgICAgICAgIGlmICh0c3BJZC5lbXB0eSgpKQogICAgICAgICAgICAgICAg
cmV0dXJuOwogICAgICAgICAgICBmb3IgKGNvbnN0IEVTTTo6UmVmSWQmIHRzcFNlZW4gOiB0c3BJ
bnRvKQogICAgICAgICAgICB7CiAgICAgICAgICAgICAgICBpZiAodHNwU2VlbiA9PSB0c3BJZCkK
ICAgICAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgdHNw
SW50by5wdXNoX2JhY2sodHNwSWQpOwogICAgICAgIH07CgogICAgICAgIC8vIENPUkUsIHRpZXIg
MTogdGhlIHR3byBpZHMgdXBkYXRlV2F0ZXJTb3VuZCBjYW4gcGxheS4KICAgICAgICB0c3BBZGRJ
ZCh0c3BDb3JlSWRzLCBFU006OlJlZklkOjpzdHJpbmdSZWZJZChGYWxsYmFjazo6TWFwOjpnZXRT
dHJpbmcoIldhdGVyX05lYXJXYXRlckluZG9vcklEIikpKTsKICAgICAgICB0c3BBZGRJZCh0c3BD
b3JlSWRzLCBFU006OlJlZklkOjpzdHJpbmdSZWZJZChGYWxsYmFjazo6TWFwOjpnZXRTdHJpbmco
IldhdGVyX05lYXJXYXRlck91dGRvb3JJRCIpKSk7CgogICAgICAgIC8vIENPUkUsIHRpZXIgMjog
ZXhhY3RseSB0aGUgc2V0IFJlZ2lvblNvdW5kU2VsZWN0b3IgY2FuIHBpY2sgZnJvbSwgd2hpY2gg
aXMKICAgICAgICAvLyB0aGUgc2V0IHVwZGF0ZVJlZ2lvblNvdW5kIGJlZ2lucyBwbGF5aW5nIHdp
dGhpbiBzZWNvbmRzIG9mIHRoZSBsb2FkIHNjcmVlbgogICAgICAgIC8vIGxpZnRpbmcuIFRoaXMg
aXMgdGhlIHRpZXIgVjEgd2FzIGV2aWN0aW5nLgogICAgICAgIGlmIChyZWdpb24uZW1wdHkoKSA9
PSBmYWxzZSkKICAgICAgICB7CiAgICAgICAgICAgIGNvbnN0IE1XV29ybGQ6OkVTTVN0b3JlJiB0
c3BTdG9yZSA9ICpNV0Jhc2U6OkVudmlyb25tZW50OjpnZXQoKS5nZXRFU01TdG9yZSgpOwogICAg
ICAgICAgICBpZiAoY29uc3QgRVNNOjpSZWdpb24qIGNvbnN0IHRzcFJlZ2lvbiA9IHRzcFN0b3Jl
LmdldDxFU006OlJlZ2lvbj4oKS5zZWFyY2gocmVnaW9uKSkKICAgICAgICAgICAgewogICAgICAg
ICAgICAgICAgZm9yIChjb25zdCBFU006OlJlZ2lvbjo6U291bmRSZWYmIHRzcFJlZiA6IHRzcFJl
Z2lvbi0+bVNvdW5kTGlzdCkKICAgICAgICAgICAgICAgICAgICB0c3BBZGRJZCh0c3BDb3JlSWRz
LCB0c3BSZWYubVNvdW5kKTsKICAgICAgICAgICAgfQogICAgICAgIH0KCiAgICAgICAgLy8gT1BU
SU9OQUw6IHdlYXRoZXIgbG9vcHMgYW5kIHRodW5kZXIsIG9uY2UgcGVyIHNlc3Npb24uIExhcmdl
LCBhbmQgdW5wbGF5ZWQKICAgICAgICAvLyB1bmxlc3MgdGhlIHdlYXRoZXIgY2hhbmdlcy4gQSB3
ZWF0aGVyIGNoYW5nZSBhZ2FpbnN0IGEgY29sZCBidWZmZXIgY29zdHMKICAgICAgICAvLyBvbmUg
fjMzIG1zIGZyYW1lOyB0aGlzIHRpZXIgZGlzcGxhY2luZyB0aGUgY29yZSB0aWVyIGNvc3QgNDUg
c2Vjb25kcy4KICAgICAgICBpZiAocmVnaW9uLmVtcHR5KCkgPT0gZmFsc2UgJiYgbVRzcFdhcm1l
ZFdlYXRoZXIgPT0gZmFsc2UKICAgICAgICAgICAgJiYgc3RkOjpnZXRlbnYoIlRTUF9OT19TTkRX
QVJNX1dFQVRIRVIiKSA9PSBudWxscHRyKQogICAgICAgIHsKICAgICAgICAgICAgbVRzcFdhcm1l
ZFdlYXRoZXIgPSB0cnVlOwogICAgICAgICAgICBmb3IgKGNvbnN0IE1XV29ybGQ6OldlYXRoZXIm
IHRzcFdlYXRoZXIgOiBNV0Jhc2U6OkVudmlyb25tZW50OjpnZXQoKS5nZXRXb3JsZCgpLT5nZXRB
bGxXZWF0aGVyKCkpCiAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgIHRzcEFkZElkKHRzcE9w
dElkcywgdHNwV2VhdGhlci5tQW1iaWVudExvb3BTb3VuZElEKTsKICAgICAgICAgICAgICAgIHRz
cEFkZElkKHRzcE9wdElkcywgdHNwV2VhdGhlci5tUmFpbkxvb3BTb3VuZElEKTsKICAgICAgICAg
ICAgICAgIGZvciAoY29uc3QgRVNNOjpSZWZJZCYgdHNwVGh1bmRlciA6IHRzcFdlYXRoZXIubVRo
dW5kZXJTb3VuZElEKQogICAgICAgICAgICAgICAgICAgIHRzcEFkZElkKHRzcE9wdElkcywgdHNw
VGh1bmRlcik7CiAgICAgICAgICAgIH0KICAgICAgICB9CgogICAgICAgIGNvbnN0IGNoYXIqIGNv
bnN0IHRzcE1heEVudiA9IHN0ZDo6Z2V0ZW52KCJUU1BfU05EV0FSTV9NQVgiKTsKICAgICAgICBj
b25zdCBpbnQgdHNwTWF4UGFyc2VkID0gdHNwTWF4RW52ICE9IG51bGxwdHIgPyBzdGQ6OmF0b2ko
dHNwTWF4RW52KSA6IDA7CiAgICAgICAgY29uc3QgaW50IHRzcE1heCA9IHRzcE1heFBhcnNlZCA+
IDAgPyB0c3BNYXhQYXJzZWQgOiA0ODsKCiAgICAgICAgLy8gVGhlIGJ1ZGdldHMgYXJlIG9uIHRo
ZSBXSE9MRSBjYWNoZSwgbm90IG9uIHRoaXMgd2FybSdzIHNoYXJlIG9mIGl0OiB3aGF0CiAgICAg
ICAgLy8gaGFzIHRvIHN0YXkgdHJ1ZSBpcyBtQnVmZmVyQ2FjaGVTaXplIDw9IG1CdWZmZXJDYWNo
ZU1pbiwgYmVjYXVzZSB0aGF0IGlzCiAgICAgICAgLy8gd2hhdCBrZWVwcyBsb2FkU2Z4IGZyb20g
ZXZlciByZWFjaGluZyBpdHMgdW5sb2FkVW51c2VkKCkgYnJhbmNoLgogICAgICAgIGNvbnN0IHN0
ZDo6c2l6ZV90IHRzcEJ1ZGdldENvcmUgPSBtU291bmRCdWZmZXJzLnRzcEdldENhY2hlTWluKCk7
CiAgICAgICAgY29uc3Qgc3RkOjpzaXplX3QgdHNwQnVkZ2V0T3B0ID0gc3RhdGljX2Nhc3Q8c3Rk
OjpzaXplX3Q+KHRzcEJ1ZGdldENvcmUgKiB0c3BPcHRpb25hbFNoYXJlKTsKICAgICAgICBjb25z
dCBzdGQ6OnNpemVfdCB0c3BCeXRlc0JlZm9yZSA9IG1Tb3VuZEJ1ZmZlcnMudHNwR2V0Q2FjaGVT
aXplKCk7CgogICAgICAgIGludCB0c3BXYXJtZWQgPSAwOwogICAgICAgIGludCB0c3BDYWNoZWQg
PSAwOwogICAgICAgIGludCB0c3BGYWlsZWQgPSAwOwogICAgICAgIGludCB0c3BTa2lwcGVkID0g
MDsKCiAgICAgICAgY29uc3QgYXV0byB0c3BXYXJtTGlzdCA9IFsmXShjb25zdCBzdGQ6OnZlY3Rv
cjxFU006OlJlZklkPiYgdHNwSWRzLCBzdGQ6OnNpemVfdCB0c3BMaW1pdCkgewogICAgICAgICAg
ICBmb3IgKGNvbnN0IEVTTTo6UmVmSWQmIHRzcElkIDogdHNwSWRzKQogICAgICAgICAgICB7CiAg
ICAgICAgICAgICAgICBpZiAobVNvdW5kQnVmZmVycy5sb29rdXAodHNwSWQpICE9IG51bGxwdHIp
CiAgICAgICAgICAgICAgICB7CiAgICAgICAgICAgICAgICAgICAgKyt0c3BDYWNoZWQ7CiAgICAg
ICAgICAgICAgICAgICAgY29udGludWU7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAg
ICBpZiAodHNwV2FybWVkID49IHRzcE1heCB8fCBtU291bmRCdWZmZXJzLnRzcEdldENhY2hlU2l6
ZSgpID49IHRzcExpbWl0KQogICAgICAgICAgICAgICAgewogICAgICAgICAgICAgICAgICAgICsr
dHNwU2tpcHBlZDsKICAgICAgICAgICAgICAgICAgICBjb250aW51ZTsKICAgICAgICAgICAgICAg
IH0KICAgICAgICAgICAgICAgIGlmIChtU291bmRCdWZmZXJzLmxvYWQodHNwSWQpICE9IG51bGxw
dHIpCiAgICAgICAgICAgICAgICAgICAgKyt0c3BXYXJtZWQ7CiAgICAgICAgICAgICAgICBlbHNl
CiAgICAgICAgICAgICAgICAgICAgKyt0c3BGYWlsZWQ7CiAgICAgICAgICAgIH0KICAgICAgICB9
OwoKICAgICAgICB0c3BXYXJtTGlzdCh0c3BDb3JlSWRzLCB0c3BCdWRnZXRDb3JlKTsKICAgICAg
ICB0c3BXYXJtTGlzdCh0c3BPcHRJZHMsIHRzcEJ1ZGdldE9wdCk7CgogICAgICAgIC8vIFN1cnZp
dm9ycywgbm90IGxvYWQgY2FsbHMuIElmIHRoaXMgaXMgYmVsb3cgd2FybWVkLCB0aGUgd2FybSBp
cyBzdGlsbAogICAgICAgIC8vIGV2aWN0aW5nIGl0c2VsZiBhbmQgdHNwT3B0aW9uYWxTaGFyZSAv
IHRoZSBjb3JlIGJ1ZGdldCBtdXN0IGNvbWUgZG93bi4KICAgICAgICBpbnQgdHNwUmVzaWRlbnQg
PSAwOwogICAgICAgIGZvciAoY29uc3QgRVNNOjpSZWZJZCYgdHNwSWQgOiB0c3BDb3JlSWRzKQog
ICAgICAgIHsKICAgICAgICAgICAgaWYgKG1Tb3VuZEJ1ZmZlcnMubG9va3VwKHRzcElkKSAhPSBu
dWxscHRyKQogICAgICAgICAgICAgICAgKyt0c3BSZXNpZGVudDsKICAgICAgICB9CiAgICAgICAg
aW50IHRzcFJlc2lkZW50T3B0ID0gMDsKICAgICAgICBmb3IgKGNvbnN0IEVTTTo6UmVmSWQmIHRz
cElkIDogdHNwT3B0SWRzKQogICAgICAgIHsKICAgICAgICAgICAgaWYgKG1Tb3VuZEJ1ZmZlcnMu
bG9va3VwKHRzcElkKSAhPSBudWxscHRyKQogICAgICAgICAgICAgICAgKyt0c3BSZXNpZGVudE9w
dDsKICAgICAgICB9CgogICAgICAgIGNvbnN0IGRvdWJsZSB0c3BXYXJtTXMKICAgICAgICAgICAg
PSBzdGQ6OmNocm9ubzo6ZHVyYXRpb248ZG91YmxlLCBzdGQ6Om1pbGxpPihzdGQ6OmNocm9ubzo6
c3RlYWR5X2Nsb2NrOjpub3coKSAtIHRzcFdhcm1TdGFydCkuY291bnQoKTsKCiAgICAgICAgLy8g
VW5jb25kaXRpb25hbCwgYW5kIG9uIFdhcm5pbmc6IG9wZW5tdy5sb2cga2VlcHMgSW5mbywgYnV0
IFdhcm5pbmcgaXMgdGhlCiAgICAgICAgLy8gY2hhbm5lbCB0aGF0IGhhcyBuZXZlciBiZWVuIHN3
YWxsb3dlZCwgYW5kIG9uZSBsaW5lIHBlciBjZWxsIGxvYWQgaXMgbm90CiAgICAgICAgLy8gdm9s
dW1lLiBUU1BfU05EV0FSTV9MT0cgaXMgbm8gbG9uZ2VyIG5lZWRlZCBhbmQgaXMgaGFybWxlc3Mg
aWYgc3RpbGwgc2V0LgogICAgICAgIExvZyhEZWJ1Zzo6V2FybmluZykgPDwgIlRTUF9TTkRXQVJN
X1YyIHJlZ2lvbj0iIDw8IHJlZ2lvbiA8PCAiIGNvcmU9IiA8PCB0c3BDb3JlSWRzLnNpemUoKQog
ICAgICAgICAgICAgICAgICAgICAgICAgICAgPDwgIiBvcHQ9IiA8PCB0c3BPcHRJZHMuc2l6ZSgp
IDw8ICIgd2FybWVkPSIgPDwgdHNwV2FybWVkIDw8ICIgY2FjaGVkPSIgPDwgdHNwQ2FjaGVkCiAg
ICAgICAgICAgICAgICAgICAgICAgICAgICA8PCAiIGZhaWxlZD0iIDw8IHRzcEZhaWxlZCA8PCAi
IHNraXBwZWQ9IiA8PCB0c3BTa2lwcGVkCiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8PCAi
IHJlc2lkZW50X2NvcmU9IiA8PCB0c3BSZXNpZGVudCA8PCAiLyIgPDwgdHNwQ29yZUlkcy5zaXpl
KCkKICAgICAgICAgICAgICAgICAgICAgICAgICAgIDw8ICIgcmVzaWRlbnRfb3B0PSIgPDwgdHNw
UmVzaWRlbnRPcHQgPDwgIi8iIDw8IHRzcE9wdElkcy5zaXplKCkKICAgICAgICAgICAgICAgICAg
ICAgICAgICAgIDw8ICIgYnl0ZXM9IiA8PCBtU291bmRCdWZmZXJzLnRzcEdldENhY2hlU2l6ZSgp
IDw8ICIgd2FzPSIgPDwgdHNwQnl0ZXNCZWZvcmUKICAgICAgICAgICAgICAgICAgICAgICAgICAg
IDw8ICIgYnVkZ2V0X2NvcmU9IiA8PCB0c3BCdWRnZXRDb3JlIDw8ICIgYnVkZ2V0X29wdD0iIDw8
IHRzcEJ1ZGdldE9wdAogICAgICAgICAgICAgICAgICAgICAgICAgICAgPDwgIiBtaW49IiA8PCBt
U291bmRCdWZmZXJzLnRzcEdldENhY2hlTWluKCkgPDwgIiBtYXg9IiA8PCBtU291bmRCdWZmZXJz
LnRzcEdldENhY2hlTWF4KCkKICAgICAgICAgICAgICAgICAgICAgICAgICAgIDw8ICIgbXM9IiA8
PCB0c3BXYXJtTXM7CiAgICB9CicnJwoKCmRlZiBkaWUobXNnKToKICAgIHByaW50KCJSRUZVU0lO
RzogJXMiICUgbXNnKQogICAgcHJpbnQoIk5PVEhJTkcgV0FTIFdSSVRURU4uIikKICAgIHN5cy5l
eGl0KDEpCgoKZGVmIGJhbGFuY2VkKHRleHQsIGxhYmVsKToKICAgICIiIkJyYWNlIGJhbGFuY2Us
IGlnbm9yaW5nIG5vdGhpbmcgLSBhIGNydWRlIGJ1dCBzdWZmaWNpZW50IHdob2xlLWZpbGUgY2hl
Y2suIiIiCiAgICBuID0gdGV4dC5jb3VudCgieyIpIC0gdGV4dC5jb3VudCgifSIpCiAgICBpZiBu
ICE9IDA6CiAgICAgICAgZGllKCIlcyBicmFjZSBiYWxhbmNlIGlzIG9mZiBieSAlK2QiICUgKGxh
YmVsLCBuKSkKCgpkZWYgc3VydmV5KHRleHQsIHBhdHRlcm4sIGxhYmVsKToKICAgIHByaW50KCIg
IHN1cnZleSBvZiAlcyBpbiAlczoiICUgKHBhdHRlcm4sIGxhYmVsKSkKICAgIGZvciBpLCBsaW5l
IGluIGVudW1lcmF0ZSh0ZXh0LnNwbGl0bGluZXMoKSwgMSk6CiAgICAgICAgaWYgcmUuc2VhcmNo
KHBhdHRlcm4sIGxpbmUpOgogICAgICAgICAgICBwcmludCgiICAgICU2ZCAgJXMiICUgKGksIGxp
bmUpKQoKCmRlZiByZWFkKHBhdGgpOgogICAgaWYgbm90IG9zLnBhdGguaXNmaWxlKHBhdGgpOgog
ICAgICAgIGRpZSgibWlzc2luZyBmaWxlOiAlcyIgJSBwYXRoKQogICAgd2l0aCBvcGVuKHBhdGgs
ICJyIiwgZW5jb2Rpbmc9InV0Zi04IikgYXMgZmg6CiAgICAgICAgcmV0dXJuIGZoLnJlYWQoKQoK
CmRlZiBmaW5kX2Z1bmN0aW9uX3NwYW4odGV4dCwgc2lnKToKICAgICIiIlJldHVybiAoc3RhcnQs
IGVuZCkgY292ZXJpbmcgc2lnIHRocm91Z2ggdGhlIG1hdGNoaW5nIGNsb3NlIGJyYWNlLiIiIgog
ICAgYXQgPSB0ZXh0LmZpbmQoc2lnKQogICAgaWYgYXQgPCAwOgogICAgICAgIHJldHVybiBOb25l
CiAgICAjIHdhbGsgZm9yd2FyZCB0byB0aGUgZmlyc3QgJ3snIGFmdGVyIHRoZSBzaWduYXR1cmUK
ICAgIGkgPSBhdCArIGxlbihzaWcpCiAgICB3aGlsZSBpIDwgbGVuKHRleHQpIGFuZCB0ZXh0W2ld
ICE9ICJ7IjoKICAgICAgICBpZiB0ZXh0W2ldIG5vdCBpbiAiIFx0XHJcbiI6CiAgICAgICAgICAg
IGRpZSgidW5leHBlY3RlZCB0ZXh0IGJldHdlZW4gdGhlIHNpZ25hdHVyZSBhbmQgaXRzIG9wZW5p
bmcgYnJhY2UiKQogICAgICAgIGkgKz0gMQogICAgaWYgaSA+PSBsZW4odGV4dCk6CiAgICAgICAg
ZGllKCJubyBvcGVuaW5nIGJyYWNlIGFmdGVyIHRoZSBzaWduYXR1cmUiKQogICAgZGVwdGggPSAw
CiAgICB3aGlsZSBpIDwgbGVuKHRleHQpOgogICAgICAgIGlmIHRleHRbaV0gPT0gInsiOgogICAg
ICAgICAgICBkZXB0aCArPSAxCiAgICAgICAgZWxpZiB0ZXh0W2ldID09ICJ9IjoKICAgICAgICAg
ICAgZGVwdGggLT0gMQogICAgICAgICAgICBpZiBkZXB0aCA9PSAwOgogICAgICAgICAgICAgICAg
ZW5kID0gaSArIDEKICAgICAgICAgICAgICAgIGlmIGVuZCA8IGxlbih0ZXh0KSBhbmQgdGV4dFtl
bmRdID09ICJcbiI6CiAgICAgICAgICAgICAgICAgICAgZW5kICs9IDEKICAgICAgICAgICAgICAg
IHJldHVybiAoYXQsIGVuZCkKICAgICAgICBpICs9IDEKICAgIGRpZSgidW50ZXJtaW5hdGVkIGZ1
bmN0aW9uIGJvZHkiKQoKCmRlZiBtYWluKCk6CiAgICBwcmludCgiVFNQX1NORFdBUk1fVjIgcGF0
Y2hlciIpCiAgICBwcmludCgiICByb290OiAlcyIgJSBST09UKQoKICAgIGhwcCA9IHJlYWQoSFBQ
KQogICAgYnVmID0gcmVhZChCVUYpCiAgICBzbWkgPSByZWFkKFNNSSkKCiAgICBkb25lID0gW0hQ
UF9NQVJLIGluIGhwcCwgQlVGX01BUksgaW4gYnVmLCBTTUlfTUFSSyBpbiBzbWldCiAgICBpZiBh
bGwoZG9uZSk6CiAgICAgICAgcHJpbnQoIkFMUkVBRFkgQVBQTElFRDogYWxsIHRocmVlIG1hcmtl
cnMgcHJlc2VudC4gTm90aGluZyB0byBkby4iKQogICAgICAgIHByaW50KCJWRVJJRklFRDogVFNQ
X1NORFdBUk1fVjIiKQogICAgICAgIHJldHVybgogICAgaWYgYW55KGRvbmUpOgogICAgICAgIGRp
ZSgiUEFSVElBTExZIGFwcGxpZWQgKGhwcD0lcyBidWY9JXMgc21pPSVzKS4gUmVzdG9yZSB0aGUg
LmJlZm9yZS1zbmR3YXJtdjIgIgogICAgICAgICAgICAiYmFja3VwcyBhbmQgcmUtcnVuIHJhdGhl
ciB0aGFuIHBhdGNoaW5nIG92ZXIgaGFsZiBhIGNoYW5nZS4iCiAgICAgICAgICAgICUgdHVwbGUo
InllcyIgaWYgZCBlbHNlICJubyIgZm9yIGQgaW4gZG9uZSkpCgogICAgIyAtLS0tIGFzc2VydCBl
dmVyeSBhbmNob3IgZXhhY3RseSBvbmNlIEJFRk9SRSB3cml0aW5nIGFueXRoaW5nIC0tLS0tLS0t
LS0tLS0KICAgIGlmIGhwcC5jb3VudChIUFBfQU5DSE9SKSAhPSAxOgogICAgICAgIHN1cnZleSho
cHAsIHIidm9pZCBjbGVhciIsICJzb3VuZGJ1ZmZlci5ocHAiKQogICAgICAgIGRpZSgic291bmRi
dWZmZXIuaHBwIGFuY2hvciBtYXRjaGVkICVkIHRpbWVzLCBuZWVkIGV4YWN0bHkgMSIgJSBocHAu
Y291bnQoSFBQX0FOQ0hPUikpCiAgICBpZiBidWYuY291bnQoQlVGX09MRCkgIT0gMToKICAgICAg
ICBzdXJ2ZXkoYnVmLCByIm1VbnVzZWRCdWZmZXJzXC5lbXB0eSIsICJzb3VuZGJ1ZmZlci5jcHAi
KQogICAgICAgIGRpZSgic291bmRidWZmZXIuY3BwIGFuY2hvciBtYXRjaGVkICVkIHRpbWVzLCBu
ZWVkIGV4YWN0bHkgMSIgJSBidWYuY291bnQoQlVGX09MRCkpCiAgICBpZiBzbWkuY291bnQoU01J
X1NJRykgIT0gMToKICAgICAgICBzdXJ2ZXkoc21pLCByInRzcFdhcm1DZWxsU291bmRzIiwgInNv
dW5kbWFuYWdlcmltcC5jcHAiKQogICAgICAgIGRpZSgic291bmRtYW5hZ2VyaW1wLmNwcCBzaWdu
YXR1cmUgbWF0Y2hlZCAlZCB0aW1lcywgbmVlZCBleGFjdGx5IDEiICUgc21pLmNvdW50KFNNSV9T
SUcpKQoKICAgIHNwYW4gPSBmaW5kX2Z1bmN0aW9uX3NwYW4oc21pLCBTTUlfU0lHKQogICAgaWYg
c3BhbiBpcyBOb25lOgogICAgICAgIGRpZSgiY291bGQgbm90IGJyYWNlLW1hdGNoIHRzcFdhcm1D
ZWxsU291bmRzIikKICAgIHN0YXJ0LCBlbmQgPSBzcGFuCiAgICBvbGRfZm4gPSBzbWlbc3RhcnQ6
ZW5kXQogICAgaWYgb2xkX2ZuLmNvdW50KCJ7IikgIT0gb2xkX2ZuLmNvdW50KCJ9Iik6CiAgICAg
ICAgZGllKCJ0aGUgZnVuY3Rpb24gc3BhbiBJIG1hdGNoZWQgaXMgbm90IGJyYWNlIGJhbGFuY2Vk
IC0gcmVmdXNpbmciKQogICAgaWYgIm1Tb3VuZEJ1ZmZlcnMubG9hZCIgbm90IGluIG9sZF9mbjoK
ICAgICAgICBzdXJ2ZXkoc21pLCByInRzcFdhcm1DZWxsU291bmRzfG1Tb3VuZEJ1ZmZlcnNcLmxv
YWQiLCAic291bmRtYW5hZ2VyaW1wLmNwcCIpCiAgICAgICAgZGllKCJ0aGUgbWF0Y2hlZCBzcGFu
IGRvZXMgbm90IGNvbnRhaW4gbVNvdW5kQnVmZmVycy5sb2FkIC0gd3Jvbmcgc3BhbiIpCgogICAg
cHJpbnQoIiAgYW5jaG9yczogaHBwIDEsIGJ1ZiAxLCBzbWkgMSAgIChWMSBmdW5jdGlvbiBzcGFu
ICVkIGxpbmVzKSIKICAgICAgICAgICUgb2xkX2ZuLmNvdW50KCJcbiIpKQoKICAgICMgLS0tLSBi
dWlsZCB0aGUgbmV3IGNvbnRlbnRzIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0KICAgIG5ld19ocHAgPSBocHAucmVwbGFjZShIUFBfQU5DSE9SLCBIUFBfSU5T
RVJUICsgSFBQX0FOQ0hPUiwgMSkKICAgIG5ld19idWYgPSBidWYucmVwbGFjZShCVUZfT0xELCBC
VUZfTkVXLCAxKQogICAgbmV3X3NtaSA9IHNtaVs6c3RhcnRdICsgU01JX05FVyArIHNtaVtlbmQ6
XQoKICAgIGJhbGFuY2VkKG5ld19ocHAsICJzb3VuZGJ1ZmZlci5ocHAiKQogICAgYmFsYW5jZWQo
bmV3X2J1ZiwgInNvdW5kYnVmZmVyLmNwcCIpCiAgICBiYWxhbmNlZChuZXdfc21pLCAic291bmRt
YW5hZ2VyaW1wLmNwcCIpCgogICAgZm9yIHRleHQsIG1hcmssIGxhYmVsIGluICgobmV3X2hwcCwg
SFBQX01BUkssICJocHAiKSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgKG5ld19idWYs
IEJVRl9NQVJLLCAiYnVmIiksCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIChuZXdfc21p
LCBTTUlfTUFSSywgInNtaSIpKToKICAgICAgICBpZiBtYXJrIG5vdCBpbiB0ZXh0OgogICAgICAg
ICAgICBkaWUoInBvc3Qtd3JpdGUgY2hlY2s6ICVzIG1hcmtlciBtaXNzaW5nIGZyb20gJXMiICUg
KG1hcmssIGxhYmVsKSkKICAgICMgdGhlIFYxIHNoYXBlIG11c3QgYmUgZ29uZQogICAgaWYgInRz
cFdhcm1JZHMucHVzaF9iYWNrKEVTTTo6UmVmSWQ6OnN0cmluZ1JlZklkIiBpbiBuZXdfc21pOgog
ICAgICAgIGRpZSgicG9zdC13cml0ZSBjaGVjazogVjEgYm9keSBzdGlsbCBwcmVzZW50IGluIHNv
dW5kbWFuYWdlcmltcC5jcHAiKQoKICAgICMgLS0tLSB3cml0ZSAtLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KICAgIHN0YW1wID0g
b3MuZW52aXJvbi5nZXQoIlRTUF9TVEFNUCIsICJzbmR3YXJtdjIiKQogICAgZm9yIHBhdGgsIHRl
eHQgaW4gKChIUFAsIG5ld19ocHApLCAoQlVGLCBuZXdfYnVmKSwgKFNNSSwgbmV3X3NtaSkpOgog
ICAgICAgIGJhayA9ICIlcy5iZWZvcmUtJXMiICUgKHBhdGgsIHN0YW1wKQogICAgICAgIGlmIG5v
dCBvcy5wYXRoLmV4aXN0cyhiYWspOgogICAgICAgICAgICB3aXRoIG9wZW4oYmFrLCAidyIsIGVu
Y29kaW5nPSJ1dGYtOCIpIGFzIGZoOgogICAgICAgICAgICAgICAgZmgud3JpdGUocmVhZChwYXRo
KSkKICAgICAgICB3aXRoIG9wZW4ocGF0aCwgInciLCBlbmNvZGluZz0idXRmLTgiKSBhcyBmaDoK
ICAgICAgICAgICAgZmgud3JpdGUodGV4dCkKICAgICAgICBwcmludCgiICB3cm90ZSAlcyAgKGJh
Y2t1cCAlcykiICUgKG9zLnBhdGguYmFzZW5hbWUocGF0aCksIG9zLnBhdGguYmFzZW5hbWUoYmFr
KSkpCgogICAgcHJpbnQoIlZFUklGSUVEOiBUU1BfU05EV0FSTV9WMiIpCgoKaWYgX19uYW1lX18g
PT0gIl9fbWFpbl9fIjoKICAgIG1haW4oKQo=
B64EOF
GOT="$(docker exec "$CONT" md5sum "$PATCHER" | cut -d' ' -f1)"
echo "  expected md5: $PATCHER_MD5"
echo "  in container: $GOT"
[ "$GOT" = "$PATCHER_MD5" ] || die "patcher md5 mismatch - the payload was mangled in transit"
echo "  VERIFIED: patcher arrived intact"

# --------------------------------------------------------------- 2. the patch --
say "2. PATCH THE SOURCE (all-or-nothing, idempotent, backs up first)"
docker exec "$CONT" env TSP_STAMP=sndwarmv2 python3 "$PATCHER" "$SRC"
[ $? -eq 0 ] || die "the patcher refused - see its survey above. Nothing was written."
docker exec "$CONT" grep -q "$MARK" "$SRC/apps/openmw/mwsound/soundmanagerimp.cpp" \
    || die "source gate: $MARK not in soundmanagerimp.cpp"
docker exec "$CONT" grep -q "tspGetCacheMin" "$SRC/apps/openmw/mwsound/soundbuffer.hpp" \
    || die "source gate: accessors not in soundbuffer.hpp"
docker exec "$CONT" grep -q "TSP_SNDCACHE_WARN_V2" "$SRC/apps/openmw/mwsound/soundbuffer.cpp" \
    || die "source gate: warning fix not in soundbuffer.cpp"
echo "  VERIFIED: all three source edits present"

# -------------------------------------------------- 3. commit BEFORE building --
say "3. COMMIT (agreement 20 - before the build, never after)"
docker exec "$CONT" sh -c "cd $SRC && git add -A && (git diff --cached --quiet && echo 'nothing to commit' || git commit -q -m 'TSP_SNDWARM_V2: budgeted ordered sound warm; unreachable cache warning fixed') && git log --oneline -1"

# --------------------------------------------------------------- 4. the build --
say "4. INCREMENTAL BUILD (full output, not truncated)"
echo "  soundbuffer.hpp changed, so every TU that includes it rebuilds."
echo "  That is soundbuffer.cpp, soundmanagerimp.cpp and the handful that pull in"
echo "  soundmanagerimp.hpp - not a full rebuild."
echo
docker exec "$CONT" cmake --build "$BUILD" --target openmw -- -j2
BS=$?
if [ "$BS" -ne 0 ]; then
    echo
    echo "  build failed with $BS. Under qemu cc1plus SIGSEGVs intermittently -"
    echo "  that is an ICE, not a source error. Retrying at -j1 once."
    docker exec "$CONT" cmake --build "$BUILD" --target openmw -- -j1 \
        || die "build failed at -j1 too. The source is patched and committed; nothing was deployed."
fi

# ------------------------------------------------------------ 5. binary gate ---
say "5. BINARY GATE"
rm -f /tmp/openmw-staged
docker cp "$CONT:$BUILD/openmw" /tmp/openmw-staged || die "docker cp failed"
if grep -a -q "$MARK" /tmp/openmw-staged; then
    echo "  VERIFIED: '$MARK' is in the freshly built binary"
else
    die "'$MARK' is NOT in the built binary - nothing will be deployed"
fi
NEWMD5="$(md5sum /tmp/openmw-staged | cut -d' ' -f1)"
OLDMD5="$(r "md5sum $BIN" | cut -d' ' -f1)"
echo "  built:    $NEWMD5"
echo "  on device: $OLDMD5"
if [ "$NEWMD5" = "$OLDMD5" ]; then
    if r "grep -a -q '$MARK' $BIN"; then
        echo "  ALREADY DEPLOYED: the device has this exact binary. Nothing to build, nothing"
        echo "  to send, and the log is left alone so a capture in progress is not destroyed."
        echo
        echo "  Play the first 60-90 seconds outdoors, then:"
        echo "      bash ~/Downloads/tsp_sndwarm_v2.sh pull"
        exit 0
    fi
    die "the built binary is identical to the deployed one yet lacks $MARK - the build did not pick up the patch"
fi

# ------------------------------------------------- 6. arm: rotate the log ------
say "6. ARM (agreement 27 - rotate before measuring)"
rin "sh -s" <<ARMEOF
set -e
G=$GAME
if [ -f "\$G/openmw_log.txt" ]; then
    mv "\$G/openmw_log.txt" "\$G/openmw_log.txt.sndwarmv2-$STAMP"
    echo "  rotated openmw_log.txt -> openmw_log.txt.sndwarmv2-$STAMP"
else
    echo "  no openmw_log.txt to rotate"
fi
if [ -f "\$G/config-0.51/openmw.log" ]; then
    mv "\$G/config-0.51/openmw.log" "\$G/config-0.51/openmw.log.sndwarmv2-$STAMP"
    echo "  rotated openmw.log (it is truncated each launch anyway)"
fi
ARMEOF

# ------------------------------------------------------------- 7. deploy -------
say "7. DEPLOY"
rin "cat > $BIN.new" < /tmp/openmw-staged || die "upload failed - $BIN.new may be partial, nothing was swapped"
rin "sh -s" <<DEPEOF
set -e
B=$BIN
cp -p "\$B" "\$B.before-sndwarmv2-$STAMP"
mv "\$B.new" "\$B"
chmod +x "\$B"
if grep -a -q "$MARK" "\$B"; then
    echo "  DEVICE VERIFIED: $MARK"
else
    echo "  DEVICE FAIL"
    exit 1
fi
echo "  backup: \$B.before-sndwarmv2-$STAMP"
DEPEOF
[ $? -eq 0 ] || die "device verification failed"

say "8. WHAT TO DO NOW"
cat <<'NOTE'
  Launch MORROWIND from your ports menu - the main entry, not an instrumented one.

  Play the first 60-90 seconds outdoors, the same way you normally reproduce it:
  load the save, walk. That first minute is the whole test.

  Then run:

      bash ~/Downloads/tsp_sndwarm_v2.sh pull

  What the numbers mean:

    resident_core=13/13   the warm held. The region set is loaded and stays
                          loaded, so updateRegionSound never decodes on the
                          gameplay thread. This is the fix working.

    resident_core=7/13    still evicting itself. The core budget is too large;
                          say the word and I lower tspOptionalShare and the core
                          cap in one sed - no new patch.

    bytes= far below min  the set never came close to the cache ceiling, which
                          kills the eviction theory outright. Then the 45 seconds
                          is somewhere else and the resident/bytes numbers tell
                          me where to look next instead of guessing.

    skipped= > 0          the weather tier was dropped for want of budget. That
                          is intended: a weather change then costs one ~33 ms
                          frame instead of costing you 45 seconds every load.

  If it made things worse:

      bash ~/Downloads/tsp_sndwarm_v2.sh revert
NOTE
echo
echo "done."
