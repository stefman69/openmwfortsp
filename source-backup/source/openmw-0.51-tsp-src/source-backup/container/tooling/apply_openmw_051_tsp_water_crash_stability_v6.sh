#!/bin/bash
set -Eeuo pipefail

# OpenMW 0.51 / TrimUI Smart Pro S
# Water precision + texture stability v6
#
# Intended baseline:
#   - TSP legacy direct-framebuffer v2
#   - existing 0.51 GLES2 water compatibility
#   - LOD/reload v4 (the build that fixed distant-texture flicker)
#
# WATER SOURCE CHANGES ONLY:
#   1. 32-cell / 64-segment water -> 16-cell / 128-segment water.
#      This reduces the local coordinate range and makes each water triangle
#      much smaller while keeping a wide +/-8-cell radius around the current
#      exterior cell.
#   2. Force the animated simple-water DDS frames to LINEAR minification and
#      magnification after OpenMW applies global texture filtering.
#      GL4ES on this device reports ignored/disabled mipmaps, so the water
#      texture must not depend on a mipmapped minification filter.
#
# PRESERVED:
#   - NiLOD overlap v4 distant-texture fix
#   - stock 0.51 object-paging behavior restored by v4
#   - direct framebuffer v2
#   - fixed-height water (no FudgeCallback)
#   - no GL_DEPTH_CLAMP draw callback
#   - fixed-function simple-water fog
#   - explicit GL_TRIANGLES / VBO waterutil path
#   - runtime shader compatibility edits
#
# DEVICE-SIDE crash-stability settings are intentionally applied separately
# over SSH, because they live on the TSP rather than in this Docker source tree.
#
# Build strategy:
#   - incremental Ninja build only
#   - NO CMake reconfigure

SOURCE_DIR="${1:-/root/openmw-0.51-tsp-src}"
BUILD_DIR="${2:-/root/openmw-0.51-tsp-build}"
PACKAGE_DIR="${3:-/root/openmw-0.51-tsp-package}"
OUTPUT_BINARY="${4:-/root/openmw-0.51-tsp-water-crash-stability-v6}"

JOBS="${OPENMW_JOBS:-$(nproc)}"
PATCH_ONLY="${OPENMW_PATCH_ONLY:-0}"

WATER_CPP="$SOURCE_DIR/apps/openmw/mwrender/water.cpp"
WATERUTIL_CPP="$SOURCE_DIR/components/sceneutil/waterutil.cpp"
POST_CPP="$SOURCE_DIR/apps/openmw/mwrender/postprocessor.cpp"
NIFLOADER_CPP="$SOURCE_DIR/components/nifosg/nifloader.cpp"

BUILT_BINARY="$BUILD_DIR/openmw"
PACKAGE_BINARY="$PACKAGE_DIR/bin/openmw-0.51"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$SOURCE_DIR/.tsp-051-source-backups/water-crash-stability-v6-$STAMP"
SCRIPT_REVISION="TSP-051-WATER-CRASH-STABILITY-V6-2026-08-07"

restore_on_error() {
    result=$?
    if [ "$result" -ne 0 ] && [ -d "$BACKUP_DIR" ]; then
        echo
        echo "ERROR: v6 source patch or build failed."
        echo "Restoring water.cpp..."
        if [ -f "$BACKUP_DIR/apps/openmw/mwrender/water.cpp" ]; then
            cp -f \
                "$BACKUP_DIR/apps/openmw/mwrender/water.cpp" \
                "$WATER_CPP"
        fi
        echo "Source restoration complete."
        echo "Failed-attempt backup retained at:"
        echo "  $BACKUP_DIR"
    fi
    exit "$result"
}
trap restore_on_error ERR

echo "============================================================"
echo "OpenMW 0.51 TSP water + crash-stability source pass v6"
echo "Revision: $SCRIPT_REVISION"
echo "============================================================"
echo "Source:     $SOURCE_DIR"
echo "Build:      $BUILD_DIR"
echo "Package:    $PACKAGE_DIR"
echo "Patch only: $PATCH_ONLY"
echo "Backup:     $BACKUP_DIR"
echo "============================================================"

for required in \
    "$WATER_CPP" \
    "$WATERUTIL_CPP" \
    "$POST_CPP" \
    "$NIFLOADER_CPP"
do
    if [ ! -f "$required" ]; then
        echo "ERROR: required source file is missing:"
        echo "  $required"
        exit 1
    fi
done

if ! grep -q 'TSP_LEGACY_DIRECT_RENDER_051_V2' "$POST_CPP"; then
    echo "ERROR: legacy direct-render v2 marker is missing."
    echo "Refusing to patch a different renderer baseline."
    exit 1
fi

if ! grep -q 'TSP_NILOD_OVERLAP_FIX_051_V4' "$NIFLOADER_CPP" \
    || ! grep -q 'TSP_NILOD_OVERLAP_APPLY_051_V4' "$NIFLOADER_CPP"
then
    echo "ERROR: known-good NiLOD v4 fix is missing."
    echo "This script will not risk the now-fixed distant renderer."
    exit 1
fi

if ! grep -Eq \
    'TSP_GL4ES_WATER_(TRIANGLE_GRID|EXPANDED_GRID|PRECISION_GRID)_051_V[123456]' \
    "$WATER_CPP"
then
    echo "ERROR: expected TSP water-grid compatibility marker was not found."
    exit 1
fi

if ! grep -Eq \
    'TSP_GL4ES_WATER_EXPLICIT_TRIANGLES_051_V[12]' \
    "$WATERUTIL_CPP"
then
    echo "ERROR: explicit-triangle water marker is missing."
    exit 1
fi

for token in \
    'osg::DrawElementsUShort' \
    'osg::PrimitiveSet::TRIANGLES' \
    'setUseDisplayList(false)' \
    'setUseVertexBufferObjects(true)'
do
    if ! grep -Fq "$token" "$WATERUTIL_CPP"; then
        echo "ERROR: waterutil.cpp lost required GLES2 triangle code:"
        echo "  $token"
        exit 1
    fi
done

if grep -Fq 'osg::PrimitiveSet::QUADS' "$WATERUTIL_CPP"; then
    echo "ERROR: GL_QUADS unexpectedly returned to waterutil.cpp."
    exit 1
fi

if [ "$PATCH_ONLY" != "1" ]; then
    if [ ! -f "$BUILD_DIR/build.ninja" ] \
        || [ ! -f "$BUILD_DIR/CMakeCache.txt" ]
    then
        echo "ERROR: configured Ninja build tree is missing."
        echo "This script intentionally will NOT rerun CMake."
        exit 1
    fi
fi

mkdir -p \
    "$BACKUP_DIR/apps/openmw/mwrender" \
    "$(dirname "$PACKAGE_BINARY")"

cp -f \
    "$WATER_CPP" \
    "$BACKUP_DIR/apps/openmw/mwrender/water.cpp"

echo
echo "Applying v6 water source changes..."

python3 - "$WATER_CPP" "$WATERUTIL_CPP" <<'PY_PATCH'
from pathlib import Path
import os
import re
import sys

water_path = Path(sys.argv[1])
waterutil_path = Path(sys.argv[2])

water = water_path.read_text(encoding="utf-8")
waterutil = waterutil_path.read_text(encoding="utf-8")

GRID_MARKER = "// TSP_GL4ES_WATER_PRECISION_GRID_051_V6"
FILTER_MARKER = "// TSP_GL4ES_WATER_LINEAR_FILTER_051_V6"


def find_function(text, signature_pattern, label):
    matches = list(re.finditer(signature_pattern, text, flags=re.MULTILINE))
    if len(matches) != 1:
        raise RuntimeError(
            f"{label}: expected one function signature, found {len(matches)}"
        )

    start = matches[0].start()
    opening = text.find("{", matches[0].end())
    if opening < 0:
        raise RuntimeError(f"{label}: opening brace not found")

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

    raise RuntimeError(f"{label}: closing brace not found")


def transactional_write(path, text):
    tmp = Path(str(path) + ".tsp-water-v6.tmp")
    try:
        with tmp.open("w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
        os.replace(str(tmp), str(path))
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


# ---------------------------------------------------------------------
# 1. Denser water geometry with smaller local coordinates.
# ---------------------------------------------------------------------
#
# 16 full cells => +/-8 cells around current exterior-cell center.
# 128*128 quads * 4 duplicated vertices = exactly 65536 vertices.
# The existing DrawElementsUShort path therefore uses indices 0..65535,
# which fit exactly in GL_UNSIGNED_SHORT.
#
# 16 cells / 128 segments = 1024 world units per square.
# Current v3 geometry (32 / 64) = 4096 units per square.

ctor_start, ctor_end = find_function(
    water,
    r"^[ \t]*Water::Water[ \t]*\(",
    "Water::Water",
)
ctor = water[ctor_start:ctor_end]

geometry_pattern = re.compile(
    r"(?P<indent>^[ \t]*)"
    r"(?://[ \t]*TSP_GL4ES_WATER_"
    r"(?:TRIANGLE_GRID|EXPANDED_GRID|PRECISION_GRID)_051_V[0-9]+"
    r"[^\n]*\n(?P=indent))?"
    r"mWaterGeom[ \t]*=[ \t]*SceneUtil::createWaterGeometry[ \t]*\("
    r"[ \t\r\n]*Constants::CellSizeInUnits[ \t]*\*[ \t]*(?:16|32)"
    r"[ \t]*,[ \t]*(?:64|128)[ \t]*,[ \t]*(?:96|192)"
    r"[ \t]*\)[ \t]*;",
    flags=re.MULTILINE,
)

if GRID_MARKER not in ctor:
    matches = list(geometry_pattern.finditer(ctor))
    if len(matches) != 1:
        raise RuntimeError(
            "Water geometry: expected one compatible constructor call; "
            f"found {len(matches)}"
        )

    match = matches[0]
    indent = match.group("indent")
    replacement = (
        indent + GRID_MARKER + "\n"
        + indent + "mWaterGeom = SceneUtil::createWaterGeometry(\n"
        + indent + "    Constants::CellSizeInUnits * 16, 128, 96);"
    )
    ctor = ctor[:match.start()] + replacement + ctor[match.end():]
elif "Constants::CellSizeInUnits * 16, 128, 96" not in ctor:
    raise RuntimeError("v6 water-grid marker exists but v6 geometry is missing")

water = water[:ctor_start] + ctor + water[ctor_end:]


# ---------------------------------------------------------------------
# 2. Force non-mipmapped linear filtering for animated simple water.
# ---------------------------------------------------------------------
#
# OpenMW's normal filtering path can choose a mipmapped MIN_FILTER.
# This TSP's GL4ES runtime explicitly reports ignored/disabled mipmaps.
# Override only the animated simple-water frames after normal settings have
# been applied. Other world textures are untouched.

simple_start, simple_end = find_function(
    water,
    r"^[ \t]*void[ \t]+Water::createSimpleWaterStateSet[ \t]*\(",
    "Water::createSimpleWaterStateSet",
)
simple = water[simple_start:simple_end]

if FILTER_MARKER not in simple:
    filter_pattern = re.compile(
        r"^(?P<indent>[ \t]*)"
        r"mResourceSystem->getSceneManager\(\)->applyFilterSettings\(tex\);"
        r"[ \t]*$",
        flags=re.MULTILINE,
    )
    matches = list(filter_pattern.finditer(simple))
    if len(matches) != 1:
        raise RuntimeError(
            "Simple water: expected one applyFilterSettings(tex) call; "
            f"found {len(matches)}"
        )

    match = matches[0]
    indent = match.group("indent")
    replacement = (
        match.group(0)
        + "\n"
        + indent + FILTER_MARKER + "\n"
        + indent + "// GL4ES reports ignored/disabled mipmaps on this device.\n"
        + indent + "tex->setFilter(osg::Texture::MIN_FILTER, osg::Texture::LINEAR);\n"
        + indent + "tex->setFilter(osg::Texture::MAG_FILTER, osg::Texture::LINEAR);"
    )
    simple = simple[:match.start()] + replacement + simple[match.end():]

water = water[:simple_start] + simple + water[simple_end:]


# ---------------------------------------------------------------------
# Final verification.
# ---------------------------------------------------------------------

for token in (
    GRID_MARKER,
    "Constants::CellSizeInUnits * 16, 128, 96",
    FILTER_MARKER,
    "tex->setFilter(osg::Texture::MIN_FILTER, osg::Texture::LINEAR);",
    "tex->setFilter(osg::Texture::MAG_FILTER, osg::Texture::LINEAR);",
):
    if token not in water:
        raise RuntimeError("water.cpp verification missing: " + token)

# Keep the earlier fixed-height/no-depth-clamp work intact.
for forbidden in (
    "mWaterGeom->setDrawCallback(new DepthClampCallback);",
    "mWaterNode->addCullCallback(new FudgeCallback);",
    "sceneManager->setForceShaders(true);",
    "sceneManager->recreateShaders(node);",
    "sceneManager->setForceShaders(oldValue);",
):
    if forbidden in water:
        raise RuntimeError(
            "water.cpp regained incompatible code: " + forbidden
        )

# Keep the existing fixed-function fog path. v6 deliberately does NOT turn
# water fog off.
simple_start, simple_end = find_function(
    water,
    r"^[ \t]*void[ \t]+Water::createSimpleWaterStateSet[ \t]*\(",
    "Water::createSimpleWaterStateSet verification",
)
simple_verify = water[simple_start:simple_end]

if "GL_FOG" not in simple_verify:
    raise RuntimeError("simple-water fixed-function fog path is missing")
if "GL_LIGHTING" not in simple_verify:
    raise RuntimeError("simple-water fixed-function lighting override is missing")

# The GLES2-safe index/VBO path must remain unchanged.
for token in (
    "osg::DrawElementsUShort",
    "osg::PrimitiveSet::TRIANGLES",
    "setUseDisplayList(false)",
    "setUseVertexBufferObjects(true)",
):
    if token not in waterutil:
        raise RuntimeError("waterutil.cpp verification missing: " + token)

if "osg::PrimitiveSet::QUADS" in waterutil:
    raise RuntimeError("waterutil.cpp contains GL_QUADS again")

transactional_write(water_path, water)

print("Patched and verified:")
print(" ", water_path)
print()
print("v6 water geometry:")
print("  full width:      16 cells")
print("  visible radius:   approximately 8 cells")
print("  segments:         128 x 128")
print("  water vertices:   65536")
print("  maximum index:    65535")
print("  square size:      1024 x 1024 world units")
print("  animated texture: LINEAR min / LINEAR mag, no mipmap dependency")
PY_PATCH

echo
echo "Verification markers:"
grep -n \
    -e 'TSP_GL4ES_WATER_PRECISION_GRID_051_V6' \
    -e 'TSP_GL4ES_WATER_LINEAR_FILTER_051_V6' \
    "$WATER_CPP"

echo
echo "Known-good distant-render fix remains:"
grep -n \
    -e 'TSP_NILOD_OVERLAP_FIX_051_V4' \
    -e 'TSP_NILOD_OVERLAP_APPLY_051_V4' \
    "$NIFLOADER_CPP" \
    | head -6

echo
echo "Direct-render fix remains:"
grep -n \
    'TSP_LEGACY_DIRECT_RENDER_051_V2' \
    "$POST_CPP" \
    | head -3

if [ "$PATCH_ONLY" = "1" ]; then
    trap - ERR
    echo
    echo "PATCH_ONLY=1: v6 source patching and verification completed."
    echo "Build intentionally skipped."
    exit 0
fi

# Preserve the existing build-only COLLADA 2.5 -> installed 2.4 alias.
# Do not rerun CMake.
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
        echo "ERROR: configured linker requests collada-dom2.5-dp,"
        echo "but the installed 2.4 double-precision library was not found."
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
    echo "ERROR: build completed but the executable is missing:"
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
        "$PACKAGE_BINARY.before-water-crash-stability-v6-$STAMP"
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
echo "SUCCESS: OpenMW 0.51 TSP v6 source rebuild completed"
echo "============================================================"
echo "Standalone binary:"
echo "  $OUTPUT_BINARY"
echo "Packaged binary:"
echo "  $PACKAGE_BINARY"
echo "Source backup:"
echo "  $BACKUP_DIR"
echo
echo "Changed in source:"
echo "  - water: 32 cells / 64 segments -> 16 cells / 128 segments"
echo "  - animated water DDS frames forced to LINEAR/LINEAR filtering"
echo
echo "Preserved:"
echo "  - NiLOD v4 distant-texture fix"
echo "  - direct framebuffer v2"
echo "  - fixed water height / no FudgeCallback"
echo "  - no GL_DEPTH_CLAMP callback"
echo "  - fixed-function water fog"
echo "  - explicit GLES2 triangle/VBO path"
echo "============================================================"
