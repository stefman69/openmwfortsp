#!/bin/bash
set -Eeuo pipefail

# OpenMW 0.51 / TrimUI Smart Pro S
# TSP GL4ES LOD + reload hardening v4
#
# Intended baseline:
#   - legacy direct-framebuffer v2 already applied
#   - water triangle/fixed-height/fixed-fog compatibility already applied
#   - water/distant/groundcover v3 may already be applied
#
# This revision deliberately DOES NOT add another speculative water geometry
# change. The device-side settings accompanying this build disable OpenMW's
# terrain water-culling heuristic instead.
#
# Source changes:
#   1. Restore stock OpenMW 0.51 object-paging merge/billboard/display-list
#      decisions, undoing the v3 experiment that increased flicker on TSP.
#   2. Backport OpenMW 0.52's NiLODNode overlap correction (#8134) into the
#      0.51 NIF->OSG loader. Morrowind selects only the last matching child;
#      osg::LOD otherwise draws every overlapping child, which can z-fight.
#   3. Make PostProcessor::disableDynamicShaders() a no-op in the TSP legacy
#      direct-render path, avoiding unused postprocess graph mutation during
#      save/death reload teardown.
#
# Build strategy:
#   - existing Ninja tree only
#   - NO CMake reconfigure

SOURCE_DIR="${1:-/root/openmw-0.51-tsp-src}"
BUILD_DIR="${2:-/root/openmw-0.51-tsp-build}"
PACKAGE_DIR="${3:-/root/openmw-0.51-tsp-package}"
OUTPUT_BINARY="${4:-/root/openmw-0.51-tsp-lod-water-reload-v4}"

JOBS="${OPENMW_JOBS:-$(nproc)}"
PATCH_ONLY="${OPENMW_PATCH_ONLY:-0}"

POST_CPP="$SOURCE_DIR/apps/openmw/mwrender/postprocessor.cpp"
OBJECTPAGING_CPP="$SOURCE_DIR/apps/openmw/mwrender/objectpaging.cpp"
NIFLOADER_CPP="$SOURCE_DIR/components/nifosg/nifloader.cpp"
WATER_CPP="$SOURCE_DIR/apps/openmw/mwrender/water.cpp"
WATERUTIL_CPP="$SOURCE_DIR/components/sceneutil/waterutil.cpp"

BUILT_BINARY="$BUILD_DIR/openmw"
PACKAGE_BINARY="$PACKAGE_DIR/bin/openmw-0.51"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$SOURCE_DIR/.tsp-051-source-backups/lod-water-reload-v4-$STAMP"
SCRIPT_REVISION="TSP-051-LOD-WATER-RELOAD-V4-2026-08-07"

restore_on_error() {
    result=$?
    if [ "$result" -ne 0 ] && [ -d "$BACKUP_DIR" ]; then
        echo
        echo "ERROR: v4 patch or build failed. Restoring modified source files..."
        for rel in \
            apps/openmw/mwrender/postprocessor.cpp \
            apps/openmw/mwrender/objectpaging.cpp \
            components/nifosg/nifloader.cpp
        do
            if [ -f "$BACKUP_DIR/$rel" ]; then
                cp -f "$BACKUP_DIR/$rel" "$SOURCE_DIR/$rel"
            fi
        done
        echo "Source restoration complete."
        echo "Failed-attempt backup retained at:"
        echo "  $BACKUP_DIR"
    fi
    exit "$result"
}
trap restore_on_error ERR

echo "============================================================"
echo "OpenMW 0.51 TSP LOD + water/reload compatibility v4"
echo "Revision: $SCRIPT_REVISION"
echo "============================================================"
echo "Source:     $SOURCE_DIR"
echo "Build:      $BUILD_DIR"
echo "Package:    $PACKAGE_DIR"
echo "Patch only: $PATCH_ONLY"
echo "Backup:     $BACKUP_DIR"
echo "============================================================"

for path in \
    "$POST_CPP" \
    "$OBJECTPAGING_CPP" \
    "$NIFLOADER_CPP" \
    "$WATER_CPP" \
    "$WATERUTIL_CPP"
do
    if [ ! -f "$path" ]; then
        echo "ERROR: required source file is missing:"
        echo "  $path"
        exit 1
    fi
done

if ! grep -q 'TSP_LEGACY_DIRECT_RENDER_051_V2' "$POST_CPP"; then
    echo "ERROR: working legacy direct-render v2 marker was not found:"
    echo "  $POST_CPP"
    echo "Refusing to patch a different renderer baseline."
    exit 1
fi

# Preserve the proven runtime-water source baseline. This v4 does not rewrite
# it, but refuses to proceed if the compatibility work has somehow disappeared.
if ! grep -Eq 'TSP_GL4ES_WATER_(TRIANGLE_GRID|EXPANDED_GRID)_051_V[123]' "$WATER_CPP"; then
    echo "ERROR: expected TSP water-grid compatibility marker was not found."
    exit 1
fi
if ! grep -Eq 'TSP_GL4ES_WATER_EXPLICIT_TRIANGLES_051_V[12]' "$WATERUTIL_CPP"; then
    echo "ERROR: expected explicit-triangle water marker was not found."
    exit 1
fi

if [ "$PATCH_ONLY" != "1" ]; then
    if [ ! -f "$BUILD_DIR/build.ninja" ] || [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
        echo "ERROR: existing configured Ninja build tree is missing."
        echo "This script intentionally will NOT rerun CMake."
        exit 1
    fi
fi

mkdir -p \
    "$BACKUP_DIR/apps/openmw/mwrender" \
    "$BACKUP_DIR/components/nifosg" \
    "$(dirname "$PACKAGE_BINARY")"

cp -f "$POST_CPP" "$BACKUP_DIR/apps/openmw/mwrender/postprocessor.cpp"
cp -f "$OBJECTPAGING_CPP" "$BACKUP_DIR/apps/openmw/mwrender/objectpaging.cpp"
cp -f "$NIFLOADER_CPP" "$BACKUP_DIR/components/nifosg/nifloader.cpp"

echo
echo "Applying source changes..."

python3 - "$POST_CPP" "$OBJECTPAGING_CPP" "$NIFLOADER_CPP" <<'PY_PATCH'
from pathlib import Path
import os
import re
import sys

post_path = Path(sys.argv[1])
objectpaging_path = Path(sys.argv[2])
nifloader_path = Path(sys.argv[3])

post = post_path.read_text(encoding="utf-8")
objectpaging = objectpaging_path.read_text(encoding="utf-8")
nifloader = nifloader_path.read_text(encoding="utf-8")

DIRECT_MARKER = "// TSP_LEGACY_DIRECT_RENDER_051_V2"
RELOAD_MARKER = "// TSP_LEGACY_DIRECT_RENDER_RELOAD_GUARD_051_V4"
LOD_VISITOR_MARKER = "// TSP_NILOD_OVERLAP_FIX_051_V4"
LOD_CALL_MARKER = "// TSP_NILOD_OVERLAP_APPLY_051_V4"

OLD_MERGE_MARKER = "// TSP_GL4ES_OBJECT_PAGING_051_V3"
OLD_BILLBOARD_MARKER = "// TSP_GL4ES_OBJECT_BILLBOARD_051_V3"
OLD_DISPLAYLIST_MARKER = "// TSP_GL4ES_OBJECT_NO_DISPLAYLIST_051_V3"

if DIRECT_MARKER not in post:
    raise RuntimeError("legacy direct-render v2 marker is missing")


def transactional_write(items):
    temps = []
    try:
        for path, text in items:
            tmp = Path(str(path) + ".tsp-v4.tmp")
            with tmp.open("w", encoding="utf-8", newline="\n") as handle:
                handle.write(text)
            temps.append((path, tmp))
        for path, tmp in temps:
            os.replace(str(tmp), str(path))
    finally:
        for _, tmp in temps:
            try:
                tmp.unlink()
            except FileNotFoundError:
                pass


# =====================================================================
# 1. UNDO THE V3 OBJECT-PAGING EXPERIMENT
# =====================================================================
# The TSP test reported more rapid distant flicker after v3. Restore the exact
# stock 0.51 decisions rather than stacking another paging workaround on top.

v3_merge = re.compile(
    r'^(?P<i>[ \t]*)// TSP_GL4ES_OBJECT_PAGING_051_V3[ \t]*\n'
    r'(?P=i)const bool merge = false;[ \t]*$',
    re.MULTILINE,
)
if OLD_MERGE_MARKER in objectpaging:
    objectpaging, count = v3_merge.subn(
        lambda m: m.group("i") + "const bool merge = mergeBenefit > mergeCost;",
        objectpaging,
        count=1,
    )
    if count != 1:
        raise RuntimeError("could not restore stock object-paging merge decision")
elif "const bool merge = mergeBenefit > mergeCost;" not in objectpaging:
    raise RuntimeError("neither v3 nor stock object-paging merge decision found")

v3_billboard = re.compile(
    r'^(?P<i>[ \t]*)// TSP_GL4ES_OBJECT_BILLBOARD_051_V3[ \t]*\n'
    r'(?P=i)copyop\.mOptimizeBillboards = false;[ \t]*$',
    re.MULTILINE,
)
if OLD_BILLBOARD_MARKER in objectpaging:
    objectpaging, count = v3_billboard.subn(
        lambda m: m.group("i") + "copyop.mOptimizeBillboards = (size > 1 / 4.f);",
        objectpaging,
        count=1,
    )
    if count != 1:
        raise RuntimeError("could not restore stock billboard optimization decision")
elif "copyop.mOptimizeBillboards = (size > 1 / 4.f);" not in objectpaging:
    raise RuntimeError("neither v3 nor stock billboard decision found")

v3_display = re.compile(
    r'^(?P<i>[ \t]*)// TSP_GL4ES_OBJECT_NO_DISPLAYLIST_051_V3[ \t]*\n'
    r'(?P=i)// Keep COMPILE_STATE_ATTRIBUTES only; do not force display lists\.[ \t]*$',
    re.MULTILINE,
)
if OLD_DISPLAYLIST_MARKER in objectpaging:
    def restore_display(m):
        i = m.group("i")
        return (
            i + "if (!merge)\n"
            + i + "    mode |= osgUtil::GLObjectsVisitor::COMPILE_DISPLAY_LISTS;"
        )
    objectpaging, count = v3_display.subn(restore_display, objectpaging, count=1)
    if count != 1:
        raise RuntimeError("could not restore stock display-list compilation block")
elif (
    "mode |= osgUtil::GLObjectsVisitor::COMPILE_DISPLAY_LISTS;"
    not in objectpaging
):
    raise RuntimeError("neither v3 nor stock display-list block found")

for stale in (OLD_MERGE_MARKER, OLD_BILLBOARD_MARKER, OLD_DISPLAYLIST_MARKER):
    if stale in objectpaging:
        raise RuntimeError("stale v3 object-paging marker remains: " + stale)

for required in (
    "const bool merge = mergeBenefit > mergeCost;",
    "copyop.mOptimizeBillboards = (size > 1 / 4.f);",
    "mode |= osgUtil::GLObjectsVisitor::COMPILE_DISPLAY_LISTS;",
):
    if required not in objectpaging:
        raise RuntimeError("stock object-paging restoration missing: " + required)


# =====================================================================
# 2. BACKPORT OPENMW #8134: REMOVE OVERLAPPING NiLODNode RANGES
# =====================================================================
# OpenMW 0.52 fixed a semantic mismatch: Morrowind's NiLODNode selects one
# matching child (last matching child wins), while osg::LOD draws every child
# whose range overlaps the eye distance. Overlaps can therefore draw two mesh
# levels simultaneously and z-fight. The visitor below is the upstream fix,
# adapted verbatim in behavior to the 0.51 loader structure.

if LOD_VISITOR_MARKER not in nifloader:
    anchor = "    void getAllNiNodes(const Nif::NiAVObject* node, std::vector<int>& outIndices)\n"
    if anchor not in nifloader:
        raise RuntimeError("NiLOD visitor insertion anchor not found")

    visitor = r'''    // TSP_NILOD_OVERLAP_FIX_051_V4
    // Backport of OpenMW #8134 / 0.52: NiLODNode only uses the last child
    // with a compatible range; osg::LOD uses every matching child. Remove
    // overlaps after the NIF scene has been constructed.
    struct RemoveLodOverlapVisitor : public osg::NodeVisitor
    {
        RemoveLodOverlapVisitor()
            : osg::NodeVisitor(TRAVERSE_ALL_CHILDREN)
        {
        }

        void apply(osg::LOD& lod) override
        {
            traverse(lod);
            std::vector<std::vector<Nif::NiLODNode::LODRange>> ranges;
            for (unsigned int i = 0; i < lod.getNumRanges(); ++i)
            {
                Nif::NiLODNode::LODRange newRange{ lod.getMinRange(i), lod.getMaxRange(i) };
                for (std::vector<Nif::NiLODNode::LODRange>& rangeVec : ranges)
                {
                    std::vector<Nif::NiLODNode::LODRange> newRangeVec;
                    newRangeVec.reserve(rangeVec.size());
                    for (const Nif::NiLODNode::LODRange& existing : rangeVec)
                    {
                        if (existing.mMinRange >= newRange.mMinRange
                            && existing.mMaxRange <= newRange.mMaxRange)
                            continue;
                        if (existing.mMinRange >= newRange.mMinRange
                            && existing.mMinRange < newRange.mMaxRange)
                            newRangeVec.push_back({ newRange.mMaxRange, existing.mMaxRange });
                        else if (existing.mMaxRange > newRange.mMinRange
                            && existing.mMaxRange <= newRange.mMaxRange)
                            newRangeVec.push_back({ existing.mMinRange, newRange.mMinRange });
                        else if (existing.mMinRange < newRange.mMinRange
                            && existing.mMaxRange > newRange.mMaxRange)
                        {
                            newRangeVec.push_back({ existing.mMinRange, newRange.mMinRange });
                            newRangeVec.push_back({ newRange.mMaxRange, existing.mMaxRange });
                        }
                        else
                            newRangeVec.push_back(existing);
                    }
                    rangeVec = std::move(newRangeVec);
                }
                ranges.push_back({ newRange });
            }

            std::vector<osg::ref_ptr<osg::Node>> originalChildren;
            originalChildren.reserve(lod.getNumChildren());
            for (unsigned int i = 0; i < lod.getNumChildren(); ++i)
                originalChildren.push_back(lod.getChild(i));

            lod.removeChildren(0, lod.getNumChildren());
            unsigned int originalChildIndex = 0;
            for (const auto& rangeVec : ranges)
            {
                for (const auto& range : rangeVec)
                {
                    if (range.mMinRange < range.mMaxRange
                        && originalChildIndex < originalChildren.size())
                        lod.addChild(originalChildren[originalChildIndex],
                            range.mMinRange, range.mMaxRange);
                }
                originalChildIndex++;
            }
        }
    };

'''
    nifloader = nifloader.replace(anchor, visitor + anchor, 1)

if LOD_CALL_MARKER not in nifloader:
    anchor = "            handleQueuedParticleEmitters(created, nif);\n"
    if anchor not in nifloader:
        raise RuntimeError("NiLOD apply insertion anchor not found")
    call = (
        anchor
        + "\n"
        + "            " + LOD_CALL_MARKER + "\n"
        + "            RemoveLodOverlapVisitor removeLodOverlaps;\n"
        + "            created->accept(removeLodOverlaps);\n"
    )
    nifloader = nifloader.replace(anchor, call, 1)

for required in (
    LOD_VISITOR_MARKER,
    LOD_CALL_MARKER,
    "struct RemoveLodOverlapVisitor",
    "created->accept(removeLodOverlaps);",
):
    if required not in nifloader:
        raise RuntimeError("NiLOD overlap backport verification failed: " + required)


# =====================================================================
# 3. DIRECT-RENDER SAVE/DEATH RELOAD HARDENING
# =====================================================================
# The legacy direct path never uses postprocessing techniques. Do not mutate
# the unused technique graph when load-game cleanup disables dynamic shaders.
if RELOAD_MARKER not in post:
    pattern = re.compile(
        r'^(?P<i>[ \t]*)void PostProcessor::disableDynamicShaders\(\)[ \t]*\n'
        r'(?P=i)\{[ \t]*$',
        re.MULTILINE,
    )
    matches = list(pattern.finditer(post))
    if len(matches) != 1:
        raise RuntimeError(
            "PostProcessor::disableDynamicShaders opening: expected one, found {}".format(len(matches))
        )
    m = matches[0]
    i = m.group("i")
    body_i = i + "    "
    guard = (
        "\n"
        + body_i + RELOAD_MARKER + "\n"
        + body_i + "if (TspLegacyDirectRender)\n"
        + body_i + "    return;"
    )
    post = post[:m.end()] + guard + post[m.end():]

if RELOAD_MARKER not in post:
    raise RuntimeError("reload hardening marker missing after patch")


transactional_write(
    (
        (post_path, post),
        (objectpaging_path, objectpaging),
        (nifloader_path, nifloader),
    )
)

print("Patched and verified:")
print(post_path)
print(objectpaging_path)
print(nifloader_path)
PY_PATCH

echo
echo "Verification markers / restored behavior:"
grep -n 'TSP_LEGACY_DIRECT_RENDER_RELOAD_GUARD_051_V4' "$POST_CPP"
grep -n 'TSP_NILOD_OVERLAP_FIX_051_V4' "$NIFLOADER_CPP"
grep -n 'TSP_NILOD_OVERLAP_APPLY_051_V4' "$NIFLOADER_CPP"
grep -n 'const bool merge = mergeBenefit > mergeCost;' "$OBJECTPAGING_CPP"
grep -n 'copyop.mOptimizeBillboards = (size > 1 / 4.f);' "$OBJECTPAGING_CPP"
grep -n 'COMPILE_DISPLAY_LISTS' "$OBJECTPAGING_CPP" | head -3

if [ "$PATCH_ONLY" = "1" ]; then
    trap - ERR
    echo
    echo "PATCH_ONLY=1: source patching and verification completed."
    echo "Build intentionally skipped."
    exit 0
fi

# Preserve the existing COLLADA build-only compatibility alias without
# reconfiguring CMake.
if ninja -C "$BUILD_DIR" -t commands openmw 2>/dev/null \
    | grep -F ' -o openmw ' \
    | tail -1 \
    | grep -Fq -- '-lcollada-dom2.5-dp'
then
    COLLADA_REAL=""

    for candidate in \
        /usr/lib/libcollada-dom2.4-dp.so \
        /usr/lib/aarch64-linux-gnu/libcollada-dom2.4-dp.so \
        /usr/local/lib/libcollada-dom2.4-dp.so
    do
        if [ -e "$candidate" ]; then
            COLLADA_REAL="$(readlink -f "$candidate")"
            break
        fi
    done

    if [ -z "$COLLADA_REAL" ]; then
        echo "ERROR: Ninja requests collada-dom2.5-dp but the installed"
        echo "COLLADA 2.4 double-precision library could not be found."
        exit 1
    fi

    mkdir -p /root/openmw-0.51-tsp-link-compat
    ln -sfn "$COLLADA_REAL" \
        /root/openmw-0.51-tsp-link-compat/libcollada-dom2.5-dp.so
    ln -sfn "$COLLADA_REAL" /usr/lib/libcollada-dom2.5-dp.so
fi

echo
echo "Incrementally rebuilding OpenMW 0.51..."
echo "CMake configure is intentionally skipped."
cmake --build \
    "$BUILD_DIR" \
    --target openmw \
    --parallel "$JOBS"

if [ ! -x "$BUILT_BINARY" ]; then
    echo "ERROR: build completed but the OpenMW executable is missing:"
    echo "  $BUILT_BINARY"
    exit 1
fi

echo
echo "Packaging rebuilt binary..."

if [ -e "$OUTPUT_BINARY" ]; then
    cp -f "$OUTPUT_BINARY" "$OUTPUT_BINARY.before-$STAMP"
fi
if [ -e "$PACKAGE_BINARY" ]; then
    cp -f "$PACKAGE_BINARY" "$PACKAGE_BINARY.before-lod-water-reload-v4-$STAMP"
fi

cp -f "$BUILT_BINARY" "$OUTPUT_BINARY"
cp -f "$BUILT_BINARY" "$PACKAGE_BINARY"
chmod +x "$OUTPUT_BINARY" "$PACKAGE_BINARY"

if readelf -d "$PACKAGE_BINARY" 2>/dev/null \
    | grep -q 'Shared library: \[libcollada-dom2.5-dp'
then
    echo "ERROR: packaged binary retained the fake COLLADA 2.5 runtime name."
    exit 1
fi

trap - ERR

echo
echo "============================================================"
echo "SUCCESS: OpenMW 0.51 TSP v4 completed"
echo "============================================================"
echo "Standalone binary:"
echo "  $OUTPUT_BINARY"
echo "Packaged binary:"
echo "  $PACKAGE_BINARY"
echo "Source backup:"
echo "  $BACKUP_DIR"
echo
echo "Source changes in this build:"
echo "  - restored stock 0.51 object-paging merge/billboard/display-list behavior"
echo "  - backported OpenMW #8134 NiLODNode overlap correction"
echo "  - direct-render disableDynamicShaders reload guard"
echo
echo "Intentionally preserved:"
echo "  - legacy direct framebuffer renderer v2"
echo "  - existing TSP water triangle/fixed-height/fixed-fog source changes"
echo "  - existing groundcover compatibility fallback"
echo "  - runtime shader flattening / GL4ES shader edits"
echo "============================================================"
