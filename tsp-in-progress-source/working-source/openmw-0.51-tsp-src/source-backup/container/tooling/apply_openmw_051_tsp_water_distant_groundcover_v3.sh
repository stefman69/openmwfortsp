#!/bin/bash
set -Eeuo pipefail

# OpenMW 0.51 / TrimUI Smart Pro S
# TSP GL4ES water + distant-object + groundcover compatibility v3
#
# IMPORTANT:
#   This patch is intended to run AFTER:
#     apply_openmw_051_tsp_legacy_direct_render_v2.sh
#
# It deliberately leaves the working direct-framebuffer renderer untouched.
#
# It ports the remaining proven OpenMW 0.48/TSP GL4ES compatibility work:
#   - disable distant-object geometry merging/flattening
#   - disable distant billboard optimization
#   - stop forcing display-list compilation for paged objects
#   - replace groundcover instancing with ordinary transforms
#
# It also adjusts the already-patched 0.51 water:
#   - keeps GL_DEPTH_CLAMP disabled
#   - keeps the camera-relative FudgeCallback detached
#   - keeps fixed-function simple-water fog
#   - keeps explicit GLES2 triangle geometry
#   - expands the finite water plane from 16 cells to 32 cells while keeping
#     the same 64x64 subdivision count (same water triangle count)
#
# Build strategy:
#   - incremental Ninja build only
#   - NO CMake reconfigure
#
# Default tree:
#   source:  /root/openmw-0.51-tsp-src
#   build:   /root/openmw-0.51-tsp-build
#   package: /root/openmw-0.51-tsp-package

SOURCE_DIR="${1:-/root/openmw-0.51-tsp-src}"
BUILD_DIR="${2:-/root/openmw-0.51-tsp-build}"
PACKAGE_DIR="${3:-/root/openmw-0.51-tsp-package}"
OUTPUT_BINARY="${4:-/root/openmw-0.51-tsp-water-distant-v3}"

JOBS="${OPENMW_JOBS:-$(nproc)}"
PATCH_ONLY="${OPENMW_PATCH_ONLY:-0}"

POST_CPP="$SOURCE_DIR/apps/openmw/mwrender/postprocessor.cpp"
WATER_CPP="$SOURCE_DIR/apps/openmw/mwrender/water.cpp"
WATERUTIL_CPP="$SOURCE_DIR/components/sceneutil/waterutil.cpp"
OBJECTPAGING_CPP="$SOURCE_DIR/apps/openmw/mwrender/objectpaging.cpp"
GROUNDCOVER_CPP="$SOURCE_DIR/apps/openmw/mwrender/groundcover.cpp"

BUILT_BINARY="$BUILD_DIR/openmw"
PACKAGE_BINARY="$PACKAGE_DIR/bin/openmw-0.51"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$SOURCE_DIR/.tsp-051-source-backups/water-distant-groundcover-v3-$STAMP"
SCRIPT_REVISION="TSP-051-WATER-DISTANT-GROUNDCOVER-V3-2026-08-07"

restore_on_error() {
    result=$?
    if [ "$result" -ne 0 ] && [ -d "$BACKUP_DIR" ]; then
        echo
        echo "ERROR: water/distant compatibility patch or build failed."
        echo "Restoring the four source files changed by this script..."

        for rel in \
            apps/openmw/mwrender/water.cpp \
            components/sceneutil/waterutil.cpp \
            apps/openmw/mwrender/objectpaging.cpp \
            apps/openmw/mwrender/groundcover.cpp
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
echo "OpenMW 0.51 TSP water + distant renderer compatibility"
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
    "$WATER_CPP" \
    "$WATERUTIL_CPP" \
    "$OBJECTPAGING_CPP" \
    "$GROUNDCOVER_CPP"
do
    if [ ! -f "$path" ]; then
        echo "ERROR: required source file is missing:"
        echo "  $path"
        exit 1
    fi
done

# This is intentionally chained onto the renderer that finally restored the
# world graphics. Refuse to touch a source tree where that patch is absent.
if ! grep -q 'TSP_LEGACY_DIRECT_RENDER_051_V2' "$POST_CPP"; then
    echo "ERROR: working legacy direct-render v2 marker was not found:"
    echo "  $POST_CPP"
    echo "Refusing to patch a different renderer baseline."
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
    "$BACKUP_DIR/components/sceneutil" \
    "$(dirname "$PACKAGE_BINARY")"

cp -f "$WATER_CPP" \
    "$BACKUP_DIR/apps/openmw/mwrender/water.cpp"
cp -f "$WATERUTIL_CPP" \
    "$BACKUP_DIR/components/sceneutil/waterutil.cpp"
cp -f "$OBJECTPAGING_CPP" \
    "$BACKUP_DIR/apps/openmw/mwrender/objectpaging.cpp"
cp -f "$GROUNDCOVER_CPP" \
    "$BACKUP_DIR/apps/openmw/mwrender/groundcover.cpp"

echo
echo "Applying source changes..."

python3 - \
    "$WATER_CPP" \
    "$WATERUTIL_CPP" \
    "$OBJECTPAGING_CPP" \
    "$GROUNDCOVER_CPP" <<'PY_PATCH'
from pathlib import Path
import os
import re
import sys

water_path = Path(sys.argv[1])
waterutil_path = Path(sys.argv[2])
objectpaging_path = Path(sys.argv[3])
groundcover_path = Path(sys.argv[4])

water = water_path.read_text(encoding="utf-8")
waterutil = waterutil_path.read_text(encoding="utf-8")
objectpaging = objectpaging_path.read_text(encoding="utf-8")
groundcover = groundcover_path.read_text(encoding="utf-8")

WATER_MARKER = "// TSP_GL4ES_WATER_EXPANDED_GRID_051_V3"
OBJECT_MERGE_MARKER = "// TSP_GL4ES_OBJECT_PAGING_051_V3"
OBJECT_BILLBOARD_MARKER = "// TSP_GL4ES_OBJECT_BILLBOARD_051_V3"
OBJECT_DISPLAYLIST_MARKER = "// TSP_GL4ES_OBJECT_NO_DISPLAYLIST_051_V3"
GROUNDCOVER_MARKER = "// TSP_GL4ES_GROUNDCOVER_051_V3"


def find_function(text, signature_pattern, label):
    matches = list(re.finditer(signature_pattern, text, flags=re.MULTILINE))
    if len(matches) != 1:
        raise RuntimeError(
            "{}: expected exactly one function signature; found {}".format(
                label, len(matches)
            )
        )

    start = matches[0].start()
    opening = text.find("{", matches[0].end())
    if opening < 0:
        raise RuntimeError("{}: opening brace not found".format(label))

    depth = 0
    in_string = False
    in_char = False
    in_line_comment = False
    in_block_comment = False
    escaped = False
    index = opening

    while index < len(text):
        char = text[index]
        next_char = text[index + 1] if index + 1 < len(text) else ""

        if in_line_comment:
            if char == "\n":
                in_line_comment = False
            index += 1
            continue

        if in_block_comment:
            if char == "*" and next_char == "/":
                in_block_comment = False
                index += 2
                continue
            index += 1
            continue

        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            index += 1
            continue

        if in_char:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == "'":
                in_char = False
            index += 1
            continue

        if char == "/" and next_char == "/":
            in_line_comment = True
            index += 2
            continue

        if char == "/" and next_char == "*":
            in_block_comment = True
            index += 2
            continue

        if char == '"':
            in_string = True
            index += 1
            continue

        if char == "'":
            in_char = True
            index += 1
            continue

        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                end = index + 1
                if end < len(text) and text[end] == "\n":
                    end += 1
                return start, end

        index += 1

    raise RuntimeError("{}: closing brace not found".format(label))


def transactional_write(items):
    temporary_paths = []
    try:
        for path, text in items:
            temporary = Path(str(path) + ".tsp-water-distant-v3.tmp")
            with temporary.open("w", encoding="utf-8", newline="\n") as handle:
                handle.write(text)
            temporary_paths.append((path, temporary))

        for path, temporary in temporary_paths:
            os.replace(str(temporary), str(path))
    finally:
        for _, temporary in temporary_paths:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


# =====================================================================
# 1. WATER
# =====================================================================
#
# The existing 0.51 TSP patch deliberately reduced stock OpenMW's enormous
# 150-cell water mesh to 16 cells while increasing subdivisions to 64.
#
# Keep the successful 64x64 triangle count, but double full width to 32 cells.
# This increases visible radius from ~8 cells to ~16 cells with no increase in
# vertex/triangle count. Texture repeats are doubled proportionally.
#
# Require the already-proven water compatibility markers before changing this
# source. This prevents accidentally replacing stock water on the wrong tree.

required_water_groups = (
    (
        "TSP_GL4ES_WATER_TRIANGLE_GRID_051_V2",
        "TSP_GL4ES_WATER_TRIANGLE_GRID_051_V1",
        "TSP_GL4ES_WATER_EXPANDED_GRID_051_V3",
    ),
    (
        "TSP_GL4ES_WATER_FIXED_HEIGHT_051_V2",
        "TSP_GL4ES_WATER_FIXED_HEIGHT_051_V1",
    ),
    (
        "TSP_GL4ES_SIMPLE_WATER_FIXED_FOG_051_V2",
        "TSP_GL4ES_SIMPLE_WATER_FIXED_FOG_051_V1",
    ),
)

for alternatives in required_water_groups:
    if not any(token in water for token in alternatives):
        raise RuntimeError(
            "Existing proven water patch is incomplete; missing one of: "
            + ", ".join(alternatives)
        )

if not (
    "TSP_GL4ES_WATER_EXPLICIT_TRIANGLES_051_V2" in waterutil
    or "TSP_GL4ES_WATER_EXPLICIT_TRIANGLES_051_V1" in waterutil
):
    raise RuntimeError(
        "Existing explicit-triangle water patch was not found in waterutil.cpp"
    )

water_ctor_start, water_ctor_end = find_function(
    water,
    r"^[ \t]*Water::Water[ \t]*\(",
    "Water::Water",
)
water_ctor = water[water_ctor_start:water_ctor_end]

geometry_pattern = re.compile(
    r"^(?P<indent>[ \t]*)"
    r"mWaterGeom[ \t]*=[ \t]*SceneUtil::createWaterGeometry[ \t]*\("
    r"[ \t\r\n]*Constants::CellSizeInUnits[ \t]*\*[ \t]*(?:16|32)"
    r"[ \t]*,[ \t]*64[ \t]*,[ \t]*(?:96|192)[ \t]*\)[ \t]*;[ \t]*$",
    flags=re.MULTILINE,
)

geometry_matches = list(geometry_pattern.finditer(water_ctor))
if len(geometry_matches) != 1:
    nearby = "\n".join(
        line for line in water_ctor.splitlines()
        if "createWaterGeometry" in line
        or "CellSizeInUnits" in line
        or "TRIANGLE_GRID" in line
        or "EXPANDED_GRID" in line
    )
    raise RuntimeError(
        "Expected exactly one already-patched 16/32-cell water geometry; "
        "found {}.\nNearby:\n{}".format(len(geometry_matches), nearby)
    )

match = geometry_matches[0]
indent = match.group("indent")

if WATER_MARKER not in water_ctor:
    geometry_replacement = (
        indent + WATER_MARKER + "\n"
        + indent
        + "// 32-cell width, 64x64 subdivisions: same triangle count as the 16-cell patch.\n"
        + indent + "mWaterGeom = SceneUtil::createWaterGeometry(\n"
        + indent + "    Constants::CellSizeInUnits * 32, 64, 192);"
    )

    water_ctor = (
        water_ctor[: match.start()]
        + geometry_replacement
        + water_ctor[match.end() :]
    )
else:
    current_geometry = match.group(0)
    if (
        "Constants::CellSizeInUnits * 32" not in current_geometry
        or ", 64, 192" not in current_geometry
    ):
        raise RuntimeError(
            "V3 water marker is present but the expected 32-cell geometry is not."
        )

# The two callback calls must remain absent. The old 0.48 testing established
# that camera-relative FudgeCallback movement produced the fill/drain behavior
# on this GL4ES path, while DepthClampCallback is unsafe here.
for forbidden in (
    "mWaterGeom->setDrawCallback(new DepthClampCallback);",
    "mWaterNode->addCullCallback(new FudgeCallback);",
):
    if forbidden in water_ctor:
        raise RuntimeError(
            "Water compatibility regression detected; callback is active: "
            + forbidden
        )

water = (
    water[:water_ctor_start]
    + water_ctor
    + water[water_ctor_end:]
)

# Do not disturb the fixed-function fog/simple-water work.
for forbidden in (
    "sceneManager->setForceShaders(true);",
    "sceneManager->recreateShaders(node);",
    "sceneManager->setForceShaders(oldValue);",
):
    simple_start, simple_end = find_function(
        water,
        r"^[ \t]*void[ \t]+Water::createSimpleWaterStateSet[ \t]*\(",
        "Water::createSimpleWaterStateSet",
    )
    simple_function = water[simple_start:simple_end]
    if forbidden in simple_function:
        raise RuntimeError(
            "Simple-water generated shader unexpectedly returned: " + forbidden
        )

for token in (
    "osg::DrawElementsUShort",
    "osg::PrimitiveSet::TRIANGLES",
    "setUseDisplayList(false)",
    "setUseVertexBufferObjects(true)",
):
    if token not in waterutil:
        raise RuntimeError(
            "waterutil.cpp lost the GLES2 triangle patch: " + token
        )

if "osg::PrimitiveSet::QUADS" in waterutil:
    raise RuntimeError("waterutil.cpp contains GL_QUADS again")


# =====================================================================
# 2. DISTANT OBJECT PAGING
# =====================================================================
#
# Port the proven 0.48 TSP V12 approach:
#   - never send paged objects to mergeGroup
#   - never freeze/optimize billboard orientation against build-time viewpoint
#   - compile state attributes, but do not force display lists
#
# These three stock 0.51 operations still exist and are especially risky for
# alpha-tested distant meshes through old GL4ES.

if OBJECT_MERGE_MARKER not in objectpaging:
    merge_pattern = re.compile(
        r"^(?P<indent>[ \t]*)const[ \t]+bool[ \t]+merge[ \t]*=[ \t]*"
        r"mergeBenefit[ \t]*>[ \t]*mergeCost[ \t]*;[ \t]*$",
        flags=re.MULTILINE,
    )
    merge_matches = list(merge_pattern.finditer(objectpaging))
    if len(merge_matches) != 1:
        raise RuntimeError(
            "Object paging: expected one merge decision; found {}".format(
                len(merge_matches)
            )
        )

    objectpaging = merge_pattern.sub(
        lambda m: (
            m.group("indent") + OBJECT_MERGE_MARKER + "\n"
            + m.group("indent") + "const bool merge = false;"
        ),
        objectpaging,
        count=1,
    )

if OBJECT_BILLBOARD_MARKER not in objectpaging:
    billboard_pattern = re.compile(
        r"^(?P<indent>[ \t]*)copyop\.mOptimizeBillboards[ \t]*=[ \t]*"
        r"\([ \t]*size[ \t]*>[ \t]*1[ \t]*/[ \t]*4\.f[ \t]*\)"
        r"[ \t]*;[ \t]*$",
        flags=re.MULTILINE,
    )
    billboard_matches = list(billboard_pattern.finditer(objectpaging))
    if len(billboard_matches) != 1:
        raise RuntimeError(
            "Object paging: expected one billboard optimization assignment; "
            "found {}".format(len(billboard_matches))
        )

    objectpaging = billboard_pattern.sub(
        lambda m: (
            m.group("indent") + OBJECT_BILLBOARD_MARKER + "\n"
            + m.group("indent") + "copyop.mOptimizeBillboards = false;"
        ),
        objectpaging,
        count=1,
    )

if OBJECT_DISPLAYLIST_MARKER not in objectpaging:
    display_pattern = re.compile(
        r"^(?P<indent>[ \t]*)if[ \t]*\([ \t]*!merge[ \t]*\)[ \t]*\n"
        r"(?P=indent)[ \t]+mode[ \t]*\|=[ \t]*"
        r"osgUtil::GLObjectsVisitor::COMPILE_DISPLAY_LISTS[ \t]*;[ \t]*$",
        flags=re.MULTILINE,
    )
    display_matches = list(display_pattern.finditer(objectpaging))
    if len(display_matches) != 1:
        raise RuntimeError(
            "Object paging: expected one conditional display-list compile block; "
            "found {}".format(len(display_matches))
        )

    objectpaging = display_pattern.sub(
        lambda m: (
            m.group("indent") + OBJECT_DISPLAYLIST_MARKER + "\n"
            + m.group("indent")
            + "// Keep COMPILE_STATE_ATTRIBUTES only; do not force display lists."
        ),
        objectpaging,
        count=1,
    )

for token in (
    OBJECT_MERGE_MARKER,
    "const bool merge = false;",
    OBJECT_BILLBOARD_MARKER,
    "copyop.mOptimizeBillboards = false;",
    OBJECT_DISPLAYLIST_MARKER,
):
    if token not in objectpaging:
        raise RuntimeError(
            "objectpaging.cpp verification failed; missing: " + token
        )


# =====================================================================
# 3. GROUNDCOVER
# =====================================================================
#
# OpenMW 0.51 still uses instanced draw calls plus VertexAttribDivisor for
# attributes 6 and 7. Old GL4ES/GLES2 is much more reliable with ordinary node
# transforms. This is the same compatibility strategy that worked in 0.48.

position_include = (
    "#include <components/sceneutil/positionattitudetransform.hpp>\n"
)

if position_include not in groundcover:
    include_anchor = "#include <components/sceneutil/nodecallback.hpp>\n"
    if include_anchor not in groundcover:
        raise RuntimeError(
            "Groundcover PositionAttitudeTransform include anchor not found"
        )
    groundcover = groundcover.replace(
        include_anchor,
        include_anchor + position_include,
        1,
    )

if GROUNDCOVER_MARKER not in groundcover:
    removed_divisors = 0
    for attribute in (6, 7):
        divisor_pattern = re.compile(
            r"^[ \t]*mStateset->setAttribute\([ \t]*new[ \t]+"
            r"osg::VertexAttribDivisor\([ \t]*"
            + str(attribute)
            + r"[ \t]*,[ \t]*1[ \t]*\)[ \t]*\)[ \t]*;[ \t]*\n?",
            flags=re.MULTILINE,
        )
        groundcover, count = divisor_pattern.subn(
            "",
            groundcover,
            count=1,
        )
        removed_divisors += count

    if removed_divisors != 2:
        raise RuntimeError(
            "Groundcover: expected to remove both VertexAttribDivisor "
            "assignments; removed {}".format(removed_divisors)
        )

    chunk_start, chunk_end = find_function(
        groundcover,
        r"^[ \t]*osg::ref_ptr<osg::Node>[ \t]+"
        r"Groundcover::createChunk[ \t]*\(",
        "Groundcover::createChunk",
    )

    new_groundcover_chunk = r'''    osg::ref_ptr<osg::Node> Groundcover::createChunk(
        InstanceMap& instances, const osg::Vec2f& center)
    {
        // TSP_GL4ES_GROUNDCOVER_051_V3
        // Compatibility fallback: ordinary transforms and ordinary mesh
        // rendering instead of glDraw*Instanced plus vertex divisors.
        osg::ref_ptr<osg::Group> group = new osg::Group;
        const osg::Vec3f worldCenter
            = osg::Vec3f(center.x(), center.y(), 0)
              * ESM::Land::REAL_SIZE;

        for (const auto& [model, entries] : instances)
        {
            const osg::Node* temp = mSceneManager->getTemplate(model);

            // Keep the original cached mesh alive while it is shared by all
            // of the normal placement transforms in this chunk.
            group->getOrCreateUserDataContainer()->addUserObject(
                new Resource::TemplateRef(temp));

            for (const GroundcoverEntry& entry : entries)
            {
                osg::ref_ptr<SceneUtil::PositionAttitudeTransform> trans
                    = new SceneUtil::PositionAttitudeTransform;

                trans->setPosition(entry.mPos.asVec3() - worldCenter);
                trans->setScale(
                    osg::Vec3f(entry.mScale, entry.mScale, entry.mScale));
                trans->setAttitude(
                    Misc::Convert::makeOsgQuat(entry.mPos));
                trans->addChild(const_cast<osg::Node*>(temp));
                group->addChild(trans);
            }
        }

        osg::ComputeBoundsVisitor cbv;
        group->accept(cbv);
        const osg::BoundingBox box = cbv.getBoundingBox();

        group->addCullCallback(
            new ViewDistanceCallback(getViewDistance(), box));
        group->setStateSet(mStateset);
        group->setNodeMask(Mask_Groundcover);

        if (Settings::groundcover().mPointLighting)
            group->addCullCallback(new SceneUtil::LightListCallback);

        // Do not recreate the dedicated "groundcover" shader here: it expects
        // instanced attributes 6 and 7, which this compatibility path removes.
        mSceneManager->shareState(group);
        group->getBound();
        return group;
    }
'''

    groundcover = (
        groundcover[:chunk_start]
        + new_groundcover_chunk
        + groundcover[chunk_end:]
    )

for token in (
    GROUNDCOVER_MARKER,
    "SceneUtil::PositionAttitudeTransform",
    "Misc::Convert::makeOsgQuat(entry.mPos)",
):
    if token not in groundcover:
        raise RuntimeError(
            "groundcover.cpp verification failed; missing: " + token
        )

for forbidden in (
    "mStateset->setAttribute(new osg::VertexAttribDivisor(6, 1));",
    "mStateset->setAttribute(new osg::VertexAttribDivisor(7, 1));",
    'mSceneManager->recreateShaders(group, "groundcover", mProgramTemplate);',
):
    if forbidden in groundcover:
        raise RuntimeError(
            "groundcover.cpp still contains incompatible code: " + forbidden
        )


# =====================================================================
# FINAL WRITE
# =====================================================================

transactional_write(
    (
        (water_path, water),
        (waterutil_path, waterutil),
        (objectpaging_path, objectpaging),
        (groundcover_path, groundcover),
    )
)

print("Patched and verified:")
print(water_path)
print(waterutil_path)
print(objectpaging_path)
print(groundcover_path)
PY_PATCH

echo
echo "Verification markers:"
grep -n \
    -e 'TSP_GL4ES_WATER_EXPANDED_GRID_051_V3' \
    "$WATER_CPP"

grep -n \
    -e 'TSP_GL4ES_OBJECT_PAGING_051_V3' \
    -e 'TSP_GL4ES_OBJECT_BILLBOARD_051_V3' \
    -e 'TSP_GL4ES_OBJECT_NO_DISPLAYLIST_051_V3' \
    "$OBJECTPAGING_CPP"

grep -n \
    'TSP_GL4ES_GROUNDCOVER_051_V3' \
    "$GROUNDCOVER_CPP"

echo
echo "Confirming legacy direct-render v2 is still present..."
grep -n \
    'TSP_LEGACY_DIRECT_RENDER_051_V2' \
    "$POST_CPP"

if [ "$PATCH_ONLY" = "1" ]; then
    trap - ERR
    echo
    echo "PATCH_ONLY=1: source patching and verification completed."
    echo "Build intentionally skipped."
    exit 0
fi

# Preserve the already-working COLLADA link workaround without touching CMake.
# The configured Ninja command may still ask for -lcollada-dom2.5-dp even
# though Ubuntu Focal provides the 2.4 double-precision library.
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

    ln -sfn \
        "$COLLADA_REAL" \
        /root/openmw-0.51-tsp-link-compat/libcollada-dom2.5-dp.so

    ln -sfn \
        "$COLLADA_REAL" \
        /usr/lib/libcollada-dom2.5-dp.so
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
    cp -f \
        "$OUTPUT_BINARY" \
        "$OUTPUT_BINARY.before-$STAMP"
fi

if [ -e "$PACKAGE_BINARY" ]; then
    cp -f \
        "$PACKAGE_BINARY" \
        "$PACKAGE_BINARY.before-water-distant-v3-$STAMP"
fi

cp -f "$BUILT_BINARY" "$OUTPUT_BINARY"
cp -f "$BUILT_BINARY" "$PACKAGE_BINARY"
chmod +x "$OUTPUT_BINARY" "$PACKAGE_BINARY"

# The compatibility symlink is build-only. Ensure the produced executable
# resolves to the real library SONAME rather than retaining the fake name.
if readelf -d "$PACKAGE_BINARY" 2>/dev/null \
    | grep -q 'Shared library: \[libcollada-dom2.5-dp'
then
    echo "ERROR: packaged binary retained the fake COLLADA 2.5 runtime name."
    exit 1
fi

trap - ERR

echo
echo "============================================================"
echo "SUCCESS: OpenMW 0.51 water + distant renderer v3 completed"
echo "============================================================"
echo "Standalone binary:"
echo "  $OUTPUT_BINARY"
echo "Packaged binary:"
echo "  $PACKAGE_BINARY"
echo "Source backup:"
echo "  $BACKUP_DIR"
echo
echo "Preserved:"
echo "  - working legacy direct-framebuffer renderer v2"
echo "  - runtime fragment shader flattening"
echo "  - runtime GL4ES shader compatibility edits"
echo "  - controller / automatic text helper work"
echo
echo "Changed:"
echo "  - water full width: 16 cells -> 32 cells"
echo "  - water subdivision count remains 64x64"
echo "  - water FudgeCallback remains disabled"
echo "  - water GL_DEPTH_CLAMP remains disabled"
echo "  - object paging geometry merge disabled"
echo "  - object paging billboard optimization disabled"
echo "  - object paging forced display lists disabled"
echo "  - groundcover instancing disabled"
echo "============================================================"
