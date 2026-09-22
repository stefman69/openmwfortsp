#!/bin/sh
# tsp_memaudit.sh - inventory every memory-related change made to this port
#
# Run INSIDE the openmw_builder container. Produces one compact report at
# /root/tsp_memaudit.txt describing what has been changed to make OpenMW fit
# in 986 MB - purges, cache expiry, unload paths, the save-load full reload,
# and the GL object flush behaviour.
#
# The report is built to be small enough to send: full diffs only for files
# whose changes are memory-related, marker listings for everything else.

SRC=${SRC:-/root/openmw-0.51-tsp-src}
OUT=${OUT:-/root/tsp_memaudit.txt}

MEMWORDS='purge\|Purge\|unload\|Unload\|releaseGLObjects\|flushDeleted\|flushAllDeleted\|expiry\|Expiry\|clearCache\|updateCache\|setExpiryDelay\|evict\|prune\|MTFREE\|reload\|Reload\|preload\|Preload\|cacheSize\|CacheSize\|freeMemory\|lowMemory\|LOW_MEM\|MEMORY'

{
echo "=============================================================="
echo " TSP MEMORY AUDIT   $(date)"
echo " source: $SRC"
echo "=============================================================="
echo

echo "##############################################################"
echo "# 1. BACKUP FILES = THE CHANGE LOG"
echo "#    Every .before-* / .tsp* / .bak* backup paired with its"
echo "#    current file, with how much changed."
echo "##############################################################"
echo
find "$SRC" \( -name '*.before-*' -o -name '*.tspaudit-*' -o -name '*.tspvpfix-*' \
            -o -name '*.tsphandler-*' -o -name '*.tspvp29-*' -o -name '*.bak' \
            -o -name '*.bak-*' -o -name '*.orig' \) 2>/dev/null | sort | while read -r b; do
    cur=$(echo "$b" | sed 's/\.\(before\|tspaudit\|tspvpfix\|tsphandler\|tspvp29\|bak\|orig\)[-.].*$//; s/\.bak$//; s/\.orig$//')
    [ -f "$cur" ] || continue
    n=$(diff "$b" "$cur" 2>/dev/null | grep -c '^[<>]')
    printf '%6s changed lines   %s\n' "$n" "${cur#$SRC/}"
    printf '                      vs %s\n' "${b##*/}"
done
echo

echo "##############################################################"
echo "# 2. EVERY TSP MARKER IN THE SOURCE, BY FILE"
echo "##############################################################"
echo
grep -rn "TSP_[A-Z_0-9]*" "$SRC/apps" "$SRC/components" \
     --include=*.cpp --include=*.hpp --include=*.h 2>/dev/null \
  | grep -v '\.before-\|\.bak\|\.orig\|\.tsp[a-z]*-' \
  | sed 's/:.*\(TSP_[A-Z_0-9]*\).*/  \1/' | sort -u \
  | awk -F: '{ f=$1; sub(/^.*openmw-0.51-tsp-src\//,"",f); print f "  " $2 }' \
  | sort | uniq -c | sort -rn | head -80
echo

echo "##############################################################"
echo "# 3. MEMORY-RELATED CODE, WITH CONTEXT"
echo "##############################################################"
echo
for f in \
    apps/openmw/mwworld/scene.cpp \
    apps/openmw/mwworld/worldimp.cpp \
    apps/openmw/mwstate/statemanagerimp.cpp \
    apps/openmw/mwrender/renderingmanager.cpp \
    apps/openmw/engine.cpp \
    components/resource/resourcesystem.cpp \
    components/resource/scenemanager.cpp \
    components/resource/objectcache.hpp \
    components/sceneutil/workqueue.cpp \
    components/terrain/world.cpp \
    components/terrain/compositemaprenderer.cpp
do
    [ -f "$SRC/$f" ] || continue
    hits=$(grep -n "$MEMWORDS" "$SRC/$f" 2>/dev/null | wc -l)
    [ "$hits" -eq 0 ] && continue
    echo "-------------------------------------------------------------"
    echo "--- $f   ($hits matches)"
    echo "-------------------------------------------------------------"
    grep -n -B2 -A6 "$MEMWORDS" "$SRC/$f" 2>/dev/null | head -400
    echo
done

echo "##############################################################"
echo "# 4. THE SAVE-LOAD FULL RELOAD PATH"
echo "##############################################################"
echo
grep -rn -B3 -A12 "reloadContent\|fullReload\|TSP_.*RELOAD\|TSP_.*PURGE" \
     "$SRC/apps" "$SRC/components" --include=*.cpp --include=*.hpp 2>/dev/null \
  | grep -v '\.before-\|\.bak\|\.orig' | head -200
echo

echo "##############################################################"
echo "# 5. GL OBJECT FLUSH / OSG CACHE BUDGETING"
echo "##############################################################"
echo
grep -rn "flushDeletedGLObjects\|flushAllDeletedGLObjects\|setTargetFrameRate\|releaseGLObjects\|setUnRefImageDataAfterApply" \
     "$SRC/apps" "$SRC/components" --include=*.cpp --include=*.hpp 2>/dev/null \
  | grep -v '\.before-\|\.bak\|\.orig' | head -60
echo

echo "##############################################################"
echo "# 6. SHIM SOURCES: purge / free paths"
echo "##############################################################"
echo
for f in /root/tsp_diag.c /root/tsp_warm.c /root/tsp_fullscreen_scaler_v35.c; do
    [ -f "$f" ] || continue
    echo "--- $f"
    grep -n "MTFREE\|purge\|free\|Delete\|delete" "$f" 2>/dev/null | head -40
    echo
done

echo "##############################################################"
echo "# 7. gl4es fork: memory handling"
echo "##############################################################"
echo
if [ -d /root/gl4es-tsps ]; then
    grep -rn "TSP_.*MEM\|purge\|Purge\|free_texture\|deltex" /root/gl4es-tsps/src \
        --include=*.c --include=*.h 2>/dev/null | head -40
fi

echo
echo "=============================================================="
echo " END OF AUDIT"
echo "=============================================================="
} > "$OUT" 2>&1

echo "written: $OUT"
wc -l "$OUT"
du -h "$OUT"