#!/bin/sh
# tsp_cull.sh - what makes the cull traversal spike to ~105 ms?
#
#   dump   read-only. No game run, no rebuild, no device writes. ONE file out.
#
# THE OBSERVATION, reproduced in two consecutive runs
#
#   01:47:06  render 127.2  cull 107.5  draw  8.0  resid 11.7
#   01:36:34  render 123.0  cull 105.5  draw  6.0  resid 11.4
#
# Cull normally runs 7-8 ms. That is 13x, with draw and residual completely
# normal, so it is not the GL side and not the update traversal - something
# inside the cull traversal itself does ~100 ms of work on one frame. Those are
# the frames behind the "under 10 fps" band (~3% of gameplay frames).
#
# THE SUSPECT, and why it is only a suspect
#
# Every logged sample reads
#   OcclusionCull: terrain tris=3200 verts=2025 bldg occluders=33 tris=4365
#                  verts=2713 total tris=7565 verts=4738 tested=194 occluded=15
#   OcclusionCache: mem_hits=0 db_hits=0 misses(built)=0 writes=0
#
# A 7.7% occlusion rate, and a cache reporting no hits, no misses and no writes
# at all - which means either it is disabled, or its keys never match, or those
# counters are never incremented. A cache that never writes has to rebuild
# whatever it builds, every time, and this runs in the cull traversal.
#
# But 50/50 at best. The other things that do real work inside cull on this
# build, any of which could be the 100 ms:
#   - ObjectPaging builds merged chunk geometry LAZILY, inside the cull
#     traversal, on first sight of a chunk. `object paging = true`,
#     `object paging active grid = true`, merge factor 50.
#   - The terrain quadtree creates and loads view data during cull, and
#     composite maps render on demand.
#   - Shadow-map cull traversals run the scene again per split.
# This dump covers all of them, plus what env or setting gates each, so the next
# step can be an env-only A/B with no rebuild.
#
# Section 1 is the one that could name it outright: every log line within +/- 3
# seconds of each big cull spike. Something else may well have logged at that
# exact instant.
#
# CONSTRAINT that applies to anything this leads to: ONE binary must serve both
# consoles (A55 Smart Pro and A53 original TSP). Runtime dispatch is fine,
# compile-time CPU targeting is not.

set -u
DEV="root@192.168.1.12"
G="/mnt/SDCARD/data/ports/openmw"
LOG="$G/openmw_log.txt"
CONT="openmw_builder"
SRC="/root/openmw-0.51-tsp-src"
SSHO="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/tsp_cull_$STAMP.txt"
THRESH="${2:-40}"

say() { printf '  %s\n' "$*"; }
hr()  { printf '\n########## %s ##########\n' "$1"; }
rin() { ssh $SSHO "$DEV" "sh -s" 2>&1; }
d()   { docker exec "$CONT" sh -c "$1" 2>&1; }
sec() { printf '\n\n==============================================================\n== %s\n==============================================================\n' "$1" >>"$OUT"
        printf '  .. %s\n' "$1"; }

ssh $SSHO -n "$DEV" "echo ok" 2>&1 | grep -q ok \
    || { printf '\n  STOPPING: cannot reach %s\n\n' "$DEV"; exit 1; }
HAVE_CONT=1
docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONT" || HAVE_CONT=0

mkdir -p "$HOME/Downloads"
: >"$OUT"
printf '# tsp_cull - %s  (cull spike threshold %s ms)\n' "$STAMP" "$THRESH" >>"$OUT"
hr "DUMPING WHAT RUNS INSIDE THE CULL TRAVERSAL"

sec "1. THE SPIKES THEMSELVES, and every log line around each one"
rin <<CEOF >>"$OUT"
L='$LOG'
T='$THRESH'
[ -f "\$L" ] || { echo "no log at \$L"; exit 0; }
echo "--- every TSP_CULLDRAW line whose cull exceeds \$T ms"
awk -v t="\$T" '
/TSP_CULLDRAW/ {
    if (!match(\$0, /cull=[0-9.]+/)) next
    c = substr(\$0, RSTART + 5, RLENGTH - 5) + 0
    if (c < t) next
    ts = ""
    if (match(\$0, /[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) ts = substr(\$0, RSTART, 8)
    printf "%s  cull=%.1f   %s\n", ts, c, \$0
}' "\$L"
echo ""
echo "--- and for each of those seconds, EVERY log line within +/- 3 s"
awk -v t="\$T" '
/TSP_CULLDRAW/ {
    if (!match(\$0, /cull=[0-9.]+/)) next
    c = substr(\$0, RSTART + 5, RLENGTH - 5) + 0
    if (c < t) next
    if (!match(\$0, /[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) next
    ts = substr(\$0, RSTART, 8)
    split(ts, a, ":")
    s = a[1] * 3600 + a[2] * 60 + a[3]
    for (k = s - 3; k <= s + 3; k++) want[k] = 1
    tag[s] = sprintf("%.1f", c)
}
END { for (k in want) print k > "/tmp/tsp_cull_secs" }
' "\$L"
if [ -s /tmp/tsp_cull_secs ]; then
    awk '
    FILENAME == "/tmp/tsp_cull_secs" { want[\$1 + 0] = 1; next }
    {
        if (!match(\$0, /[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) next
        ts = substr(\$0, RSTART, 8)
        split(ts, a, ":")
        s = a[1] * 3600 + a[2] * 60 + a[3]
        if (s in want) print
    }' /tmp/tsp_cull_secs "\$L" | head -400
    rm -f /tmp/tsp_cull_secs
else
    echo "    (no cull spike above \$T ms in this log)"
fi
CEOF

sec "2. what the occlusion system reports, and how often"
rin <<OEOF >>"$OUT"
L='$LOG'
echo "--- every distinct OcclusionCull line, with how many times it occurred"
grep -h 'OcclusionCull' "\$L" 2>/dev/null | sed 's/^\[[^]]*\] *//' | sort | uniq -c | sort -rn | head -20
echo ""
echo "--- every distinct OcclusionCache line"
grep -h 'OcclusionCache' "\$L" 2>/dev/null | sed 's/^\[[^]]*\] *//' | sort | uniq -c | sort -rn | head -20
echo ""
echo "--- how many of each in total, and the first and last of each"
for k in OcclusionCull OcclusionCache; do
    printf '    %-16s %s lines\n' "\$k" "\$(grep -c "\$k" "\$L" 2>/dev/null)"
    grep -h "\$k" "\$L" 2>/dev/null | head -1 | sed 's/^/      first: /'
    grep -h "\$k" "\$L" 2>/dev/null | tail -1 | sed 's/^/      last:  /'
done
echo ""
echo "--- anything else in the log that mentions occlusion, paging, chunk or quadtree"
grep -h -i -e 'occlu' -e 'objectpaging' -e 'object paging' -e 'chunk' -e 'quadtree' \
     -e 'composite' "\$L" 2>/dev/null | sed 's/^\[[^]]*\] *//' | sort | uniq -c | sort -rn | head -25
OEOF

sec "3. the settings and env that gate every cull-side system"
rin <<SEOF >>"$OUT"
G='$G'
echo "--- the whole [Terrain] and [Objects] sections"
awk '/^\[Terrain\]/,/^\[[A-Z]/{ if (NR>1) printf "%5d | %s\n", NR, \$0 }' "\$G/config/settings.cfg" 2>/dev/null | head -40
echo ""
grep -n -e 'object paging' -e 'composite map' -e 'distant terrain' -e 'viewing distance' \
        -e 'shadow' -e 'max lights' -e 'lighting method' \
        "\$G/config/settings.cfg" 2>/dev/null
echo ""
echo "--- every occlusion / paging related env var the game actually has"
P="\$(pidof openmw-0.51 2>/dev/null | awk '{print \$1}')"
[ -n "\$P" ] || P="\$(ps -e 2>/dev/null | grep '[o]penmw-0.51' | awk '{print \$1}' | head -1)"
if [ -n "\$P" ]; then
    tr '\0' '\n' < "/proc/\$P/environ" 2>/dev/null \
      | grep -i -e occl -e pag -e cull -e terrain -e shadow -e intocc | sort | sed 's/^/    /'
    echo "    (pid \$P)"
else
    echo "    game not running - launch it and re-run for the live environ"
fi
echo ""
echo "--- the env file and any occlusion flag files"
[ -f /mnt/SDCARD/tsp_intocc.env ] && sed 's/^/    /' /mnt/SDCARD/tsp_intocc.env
ls -1 /mnt/SDCARD/tsp_* 2>/dev/null | sed 's/^/    /'
SEOF

if [ "$HAVE_CONT" = "0" ]; then
    say "container $CONT is not running - skipping the source half"
    say "(sections 1-3 still ran; start the container and re-run for 4-7)"
else

sec "4. THE OCCLUSION SYSTEM IN THE SOURCE - every file and every call site"
d "cd $SRC && grep -rn -e 'OcclusionCull' -e 'OcclusionCache' -e 'mem_hits' -e 'db_hits' \
    -e 'TSP_OCCL' -e 'TSP_INTOCC' apps components 2>/dev/null \
    | grep -v -e '\.before-' -e '\.preoverlay' -e '\.abandoned-' -e '\.pre-resync' | head -80" >>"$OUT"
printf '\n-- count, so nothing is hidden by a head limit --\n' >>"$OUT"
d "cd $SRC && grep -rn -e 'OcclusionCull' -e 'OcclusionCache' apps components 2>/dev/null \
    | grep -v -e '\.before-' -e '\.preoverlay' -e '\.abandoned-' | wc -l" >>"$OUT"
printf '\n-- the file that owns it, listed --\n' >>"$OUT"
d "cd $SRC && grep -rl 'OcclusionCache' apps components 2>/dev/null | grep -v '\.before-' | head -6" >>"$OUT"

sec "5. WHERE THE CACHE IS READ AND WRITTEN - why would all four counters be 0"
d "cd $SRC && for f in \$(grep -rl 'OcclusionCache' apps components 2>/dev/null | grep -v '\.before-' | head -3); do
     echo \"----- \$f -----\"; cat -n \"\$f\" | head -420; done" >>"$OUT"

sec "6. OBJECT PAGING - it builds chunk geometry INSIDE the cull traversal"
d "cd $SRC && grep -n -e 'getChunk' -e 'createChunk' -e 'ChunkId' -e 'cull' -e 'Cull' \
    -e 'mergeGeometry' -e 'LODRange' -e 'operator()' \
    apps/openmw/mwrender/objectpaging.cpp 2>/dev/null | head -60" >>"$OUT"
printf '\n----- objectpaging.cpp: the chunk build path -----\n' >>"$OUT"
d "cd $SRC && awk '/ObjectPaging::getChunk|ObjectPaging::createChunk/,/^    }\$/' \
    apps/openmw/mwrender/objectpaging.cpp 2>/dev/null | head -260" >>"$OUT"

sec "7. TERRAIN AND SHADOWS in the cull traversal, plus every cull callback"
d "cd $SRC && grep -rn -e 'class.*CullCallback' -e ': public osg::NodeCallback' \
    -e 'CULL_VISITOR' -e 'CullVisitor' -e 'cull_traversal' \
    components/terrain components/sceneutil apps/openmw/mwrender 2>/dev/null \
    | grep -v -e '\.before-' -e '\.abandoned-' | head -60" >>"$OUT"
printf '\n----- the terrain quadtree cull / view-data path -----\n' >>"$OUT"
d "cd $SRC && grep -n -e 'traverse' -e 'ViewData' -e 'getView' -e 'loadRenderingNode' \
    -e 'ensureLoaded' -e 'cull' components/terrain/quadtreeworld.cpp 2>/dev/null | head -50" >>"$OUT"
printf '\n----- composite map rendering budget -----\n' >>"$OUT"
d "cd $SRC && grep -rn -e 'TSP_COMPOS' -e 'setTargetFrameRate' -e 'CompositeMapRenderer' \
    components/terrain apps/openmw/mwrender 2>/dev/null | grep -v '\.before-' | head -30" >>"$OUT"

fi

hr "SUMMARY"
say "saved to $OUT  ($(wc -l < "$OUT") lines)"
say ""
say "Read section 1 first. If something else logged at 01:47:06 and 01:36:34 it"
say "names the cause outright and the rest is unnecessary. If nothing did, then"
say "sections 4-6 decide between the occlusion cache never writing and"
say "ObjectPaging building a chunk inside cull - and both have an env or setting"
say "that can be flipped for a one-boot A/B without a rebuild."
printf '\n'
