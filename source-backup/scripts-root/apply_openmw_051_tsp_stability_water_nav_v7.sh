#!/bin/bash
set -Eeuo pipefail

# OpenMW 0.51 / TrimUI Smart Pro S
# TSP stability + dense-water + optional navmeshtool package v7
#
# Baseline expected:
#   - OpenMW 0.51.0 source at /root/openmw-0.51-tsp-src
#   - existing configured Ninja build at /root/openmw-0.51-tsp-build
#   - legacy direct-framebuffer v2 already applied
#   - NiLOD overlap/reload v4 already applied
#   - existing GLES2 water compatibility:
#       * fixed water height / no camera-relative FudgeCallback
#       * no GL_DEPTH_CLAMP draw callback
#       * simple-water fixed-function fog
#       * explicit indexed GL_TRIANGLES + VBO
#
# Source changes:
#   1. Water grid: 32 cells / 64 segments -> 32 cells / 128 segments.
#      Keeps the improved far-water radius while returning triangle size to
#      the earlier, more stable 16-cell / 64-segment scale.
#   2. Animated simple-water textures are forced to LINEAR/LINEAR filtering.
#      This avoids asking the current GL4ES no-mipmap path for a mipmapped
#      minification filter.
#   3. Port the conservative 0.48 memory cleanup to 0.51:
#      after normal ResourceSystem cache expiry, call malloc_trim(0) at most
#      once every five seconds; also trim once after a full clearCache().
#
# Tooling/package changes:
#   4. Enable and build openmw-navmeshtool in the EXISTING CMake tree.
#      This requires one CMake regeneration only if BUILD_NAVMESHTOOL is
#      currently OFF; the build directory is NOT deleted or cleaned.
#   5. Package openmw-navmeshtool beside the game binary. It is never launched
#      automatically.
#   6. Package two helper scripts:
#        tools/apply-runtime-profile-v7.sh
#        tools/generate-navmesh.sh
#
# Runtime profile:
#   - near clip = 15 (user-tested good distant result)
#   - water culling = true
#   - object paging active grid = false
#   - cell preloading disabled
#   - cache expiry delay = 1
#   - navigator memory cache = 32 MiB
#   - navmesh updater threads = 1
#   - disk navmesh cache enabled + runtime writes enabled
#   - MOP + Project Atlas enabled in correct order/path
#
# Important:
#   openmw-navmeshtool is OPTIONAL. Merely shipping it does nothing until the
#   user explicitly runs tools/generate-navmesh.sh.
#
# This script does NOT:
#   - alter the working NiLOD v4 fix
#   - alter object paging source
#   - alter groundcover source
#   - enable shader water
#   - re-enable FBO/ping-pong rendering
#   - globally change GL4ES mipmap policy

SOURCE_DIR="${1:-/root/openmw-0.51-tsp-src}"
BUILD_DIR="${2:-/root/openmw-0.51-tsp-build}"
PACKAGE_DIR="${3:-/root/openmw-0.51-tsp-package}"
OUTPUT_BINARY="${4:-/root/openmw-0.51-tsp-stability-water-nav-v7}"

JOBS="${OPENMW_JOBS:-$(nproc)}"
PATCH_ONLY="${OPENMW_PATCH_ONLY:-0}"

WATER_CPP="$SOURCE_DIR/apps/openmw/mwrender/water.cpp"
WATERUTIL_CPP="$SOURCE_DIR/components/sceneutil/waterutil.cpp"
RESOURCE_CPP="$SOURCE_DIR/components/resource/resourcesystem.cpp"
POST_CPP="$SOURCE_DIR/apps/openmw/mwrender/postprocessor.cpp"
NIFLOADER_CPP="$SOURCE_DIR/components/nifosg/nifloader.cpp"
CMAKE_FILE="$SOURCE_DIR/CMakeLists.txt"

BUILT_BINARY="$BUILD_DIR/openmw"
PACKAGE_BINARY="$PACKAGE_DIR/bin/openmw-0.51"
PACKAGE_NAVTOOL="$PACKAGE_DIR/bin/openmw-navmeshtool"
PACKAGE_TOOLS_DIR="$PACKAGE_DIR/tools"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$SOURCE_DIR/.tsp-051-source-backups/stability-water-nav-v7-$STAMP"
SCRIPT_REVISION="TSP-051-STABILITY-WATER-NAV-V7-2026-08-07"

restore_on_error() {
    result=$?
    if [ "$result" -ne 0 ] && [ -d "$BACKUP_DIR" ]; then
        echo
        echo "ERROR: v7 patch/build failed."
        echo "Restoring source files modified by this script..."
        for rel in \
            apps/openmw/mwrender/water.cpp \
            components/resource/resourcesystem.cpp
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
echo "OpenMW 0.51 TSP stability + water + navmesh tooling v7"
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
    "$RESOURCE_CPP" \
    "$POST_CPP" \
    "$NIFLOADER_CPP" \
    "$CMAKE_FILE"
do
    if [ ! -f "$required" ]; then
        echo "ERROR: required source file is missing:"
        echo "  $required"
        exit 1
    fi
done

VERSION_MAJOR="$(
    sed -n \
        's/^[[:space:]]*set(OPENMW_VERSION_MAJOR[[:space:]]*\([0-9][0-9]*\)).*/\1/p' \
        "$CMAKE_FILE" | head -1
)"
VERSION_MINOR="$(
    sed -n \
        's/^[[:space:]]*set(OPENMW_VERSION_MINOR[[:space:]]*\([0-9][0-9]*\)).*/\1/p' \
        "$CMAKE_FILE" | head -1
)"

if [ "$VERSION_MAJOR" != "0" ] || [ "$VERSION_MINOR" != "51" ]; then
    echo "ERROR: expected OpenMW 0.51 source."
    echo "Detected: ${VERSION_MAJOR:-?}.${VERSION_MINOR:-?}"
    exit 1
fi

if ! grep -q 'TSP_LEGACY_DIRECT_RENDER_051_V2' "$POST_CPP"; then
    echo "ERROR: working direct-framebuffer v2 marker is missing."
    exit 1
fi

if ! grep -q 'TSP_NILOD_OVERLAP_FIX_051_V4' "$NIFLOADER_CPP" \
    || ! grep -q 'TSP_NILOD_OVERLAP_APPLY_051_V4' "$NIFLOADER_CPP"
then
    echo "ERROR: known-good NiLOD v4 distant-texture fix is missing."
    echo "Refusing to modify a different renderer baseline."
    exit 1
fi

if ! grep -Eq \
    'TSP_GL4ES_WATER_(TRIANGLE_GRID|EXPANDED_GRID|PRECISION_GRID|DENSE_GRID)_051_V[0-9]+' \
    "$WATER_CPP"
then
    echo "ERROR: expected TSP water compatibility marker is missing."
    exit 1
fi

if ! grep -Eq \
    'TSP_GL4ES_WATER_FIXED_HEIGHT_051_V[12]' \
    "$WATER_CPP"
then
    echo "ERROR: fixed-height water marker is missing."
    exit 1
fi

if ! grep -Eq \
    'TSP_GL4ES_SIMPLE_WATER_FIXED_FOG_051_V[12]' \
    "$WATER_CPP"
then
    echo "ERROR: fixed-function simple-water fog marker is missing."
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
        echo "ERROR: waterutil.cpp lost required GLES2-safe code:"
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
        echo "ERROR: existing configured Ninja build tree is missing."
        exit 1
    fi
fi

mkdir -p \
    "$BACKUP_DIR/apps/openmw/mwrender" \
    "$BACKUP_DIR/components/resource" \
    "$PACKAGE_DIR/bin" \
    "$PACKAGE_TOOLS_DIR"

cp -f "$WATER_CPP" \
    "$BACKUP_DIR/apps/openmw/mwrender/water.cpp"
cp -f "$RESOURCE_CPP" \
    "$BACKUP_DIR/components/resource/resourcesystem.cpp"

echo
echo "Applying v7 source changes..."

python3 - "$WATER_CPP" "$WATERUTIL_CPP" "$RESOURCE_CPP" <<'PY_PATCH'
from pathlib import Path
import os
import re
import sys

water_path = Path(sys.argv[1])
waterutil_path = Path(sys.argv[2])
resource_path = Path(sys.argv[3])

water = water_path.read_text(encoding="utf-8")
waterutil = waterutil_path.read_text(encoding="utf-8")
resource = resource_path.read_text(encoding="utf-8")

GRID_MARKER = "// TSP_GL4ES_WATER_DENSE_GRID_051_V7"
FILTER_MARKER = "// TSP_GL4ES_WATER_LINEAR_FILTER_051_V7"
TRIM_UPDATE_MARKER = "// TSP_MEMORY_TRIM_UPDATE_051_V7"
TRIM_CLEAR_MARKER = "// TSP_MEMORY_TRIM_CLEAR_051_V7"


def find_function(text, signature_pattern, label):
    matches = list(re.finditer(signature_pattern, text, flags=re.MULTILINE))
    if len(matches) != 1:
        raise RuntimeError(
            f"{label}: expected exactly one function signature; found {len(matches)}"
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


def transactional_write(items):
    temps = []
    try:
        for path, text in items:
            tmp = Path(str(path) + ".tsp-v7.tmp")
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
# 1. WATER: KEEP 32-CELL COVERAGE, DOUBLE TESSELLATION
# =====================================================================

ctor_start, ctor_end = find_function(
    water,
    r"^[ \t]*Water::Water[ \t]*\(",
    "Water::Water",
)
ctor = water[ctor_start:ctor_end]

ctor = re.sub(
    r"^[ \t]*// TSP_GL4ES_WATER_(?:EXPANDED_GRID_051_V3|PRECISION_GRID_051_V[56]|DENSE_GRID_051_V7)[^\n]*\n",
    "",
    ctor,
    flags=re.MULTILINE,
)
ctor = re.sub(
    r"^[ \t]*// 32-cell width, 64x64 subdivisions:[^\n]*\n",
    "",
    ctor,
    flags=re.MULTILINE,
)
ctor = re.sub(
    r"^[ \t]*// 32-cell coverage with 128x128 subdivisions:[^\n]*\n",
    "",
    ctor,
    flags=re.MULTILINE,
)

geometry_pattern = re.compile(
    r"(?P<indent>^[ \t]*)"
    r"mWaterGeom[ \t]*=[ \t]*SceneUtil::createWaterGeometry[ \t]*\("
    r"[ \t\r\n]*Constants::CellSizeInUnits[ \t]*\*[ \t]*(?:16|32)"
    r"[ \t]*,[ \t]*(?:64|128)[ \t]*,[ \t]*(?:96|192)"
    r"[ \t]*\)[ \t]*;",
    flags=re.MULTILINE,
)

matches = list(geometry_pattern.finditer(ctor))
if len(matches) != 1:
    nearby = "\n".join(
        line for line in ctor.splitlines()
        if "createWaterGeometry" in line or "CellSizeInUnits" in line
    )
    raise RuntimeError(
        "Water geometry: expected one compatible constructor call; "
        f"found {len(matches)}.\nNearby:\n{nearby}"
    )

m = matches[0]
indent = m.group("indent")
replacement = (
    indent + GRID_MARKER + "\n"
    + indent + "// 32-cell coverage with 128x128 subdivisions: 2048-unit squares.\n"
    + indent + "mWaterGeom = SceneUtil::createWaterGeometry(\n"
    + indent + "    Constants::CellSizeInUnits * 32, 128, 192);"
)
ctor = ctor[:m.start()] + replacement + ctor[m.end():]

for forbidden in (
    "mWaterGeom->setDrawCallback(new DepthClampCallback);",
    "mWaterNode->addCullCallback(new FudgeCallback);",
):
    if forbidden in ctor:
        raise RuntimeError(
            "Water compatibility regression detected: " + forbidden
        )

water = water[:ctor_start] + ctor + water[ctor_end:]


# =====================================================================
# 2. WATER: NON-MIPMAPPED LINEAR FILTER FOR ANIMATED FRAMES
# =====================================================================

simple_start, simple_end = find_function(
    water,
    r"^[ \t]*void[ \t]+Water::createSimpleWaterStateSet[ \t]*\(",
    "Water::createSimpleWaterStateSet",
)
simple = water[simple_start:simple_end]

simple = re.sub(
    r"^[ \t]*// TSP_GL4ES_WATER_LINEAR_FILTER_051_V[67][^\n]*\n",
    "",
    simple,
    flags=re.MULTILINE,
)
simple = re.sub(
    r"^[ \t]*// GL4ES reports ignored/disabled mipmaps on this device\.[^\n]*\n",
    "",
    simple,
    flags=re.MULTILINE,
)
simple = re.sub(
    r"^[ \t]*tex->setFilter\(osg::Texture::MIN_FILTER,[ \t]*osg::Texture::LINEAR\);[ \t]*\n",
    "",
    simple,
    flags=re.MULTILINE,
)
simple = re.sub(
    r"^[ \t]*tex->setFilter\(osg::Texture::MAG_FILTER,[ \t]*osg::Texture::LINEAR\);[ \t]*\n",
    "",
    simple,
    flags=re.MULTILINE,
)

filter_pattern = re.compile(
    r"^(?P<indent>[ \t]*)"
    r"mResourceSystem->getSceneManager\(\)->applyFilterSettings\(tex\);[ \t]*$",
    flags=re.MULTILINE,
)
matches = list(filter_pattern.finditer(simple))
if len(matches) != 1:
    raise RuntimeError(
        "Simple water: expected exactly one applyFilterSettings(tex) call; "
        f"found {len(matches)}"
    )

m = matches[0]
indent = m.group("indent")
replacement = (
    m.group(0)
    + "\n"
    + indent + FILTER_MARKER + "\n"
    + indent + "tex->setFilter(osg::Texture::MIN_FILTER, osg::Texture::LINEAR);\n"
    + indent + "tex->setFilter(osg::Texture::MAG_FILTER, osg::Texture::LINEAR);"
)
simple = simple[:m.start()] + replacement + simple[m.end():]

if "GL_FOG" not in simple:
    raise RuntimeError("simple-water fixed-function fog path is missing")
if "sceneManager->recreateShaders(node);" in simple:
    raise RuntimeError("generated simple-water shader unexpectedly returned")

water = water[:simple_start] + simple + water[simple_end:]


# =====================================================================
# 3. 0.51 MEMORY TRIM
# =====================================================================

include_matches = list(
    re.finditer(r"^#include[^\n]*\n", resource, flags=re.MULTILINE)
)
if not include_matches:
    raise RuntimeError("resourcesystem.cpp: include insertion point not found")

missing = []
if "#include <atomic>" not in resource:
    missing.append("#include <atomic>\n")
if "#include <chrono>" not in resource:
    missing.append("#include <chrono>\n")
if "#include <cstdint>" not in resource:
    missing.append("#include <cstdint>\n")
if "#include <malloc.h>" not in resource:
    missing.append(
        "#if defined(__linux__) && defined(__GLIBC__)\n"
        "#include <malloc.h>\n"
        "#endif\n"
    )

if missing:
    insertion = include_matches[-1].end()
    resource = resource[:insertion] + "".join(missing) + resource[insertion:]


if TRIM_UPDATE_MARKER not in resource:
    start, end = find_function(
        resource,
        r"^[ \t]*void[ \t]+ResourceSystem::updateCache[ \t]*\([^)]*\)",
        "ResourceSystem::updateCache",
    )
    func = resource[start:end]
    closing = func.rfind("}")
    if closing < 0:
        raise RuntimeError("updateCache closing brace not found")

    block = r'''
#if defined(__linux__) && defined(__GLIBC__)
        // TSP_MEMORY_TRIM_UPDATE_051_V7
        // OpenMW's managers have already expired unreferenced resources.
        // glibc may retain those free heap pages inside the process, so ask it
        // to return releasable pages to Linux at most once every five seconds.
        using TspTrimClock = std::chrono::steady_clock;
        static std::atomic<std::int64_t> sTspLastTrimNs{ 0 };

        const std::int64_t tspNowNs
            = std::chrono::duration_cast<std::chrono::nanoseconds>(
                  TspTrimClock::now().time_since_epoch())
                  .count();

        std::int64_t tspLastNs
            = sTspLastTrimNs.load(std::memory_order_relaxed);

        constexpr std::int64_t TspTrimIntervalNs = 5000000000LL;

        if (tspNowNs - tspLastNs >= TspTrimIntervalNs
            && sTspLastTrimNs.compare_exchange_strong(
                tspLastNs, tspNowNs, std::memory_order_relaxed))
        {
            ::malloc_trim(0);
        }
#endif
'''
    func = func[:closing] + block + func[closing:]
    resource = resource[:start] + func + resource[end:]


if TRIM_CLEAR_MARKER not in resource:
    start, end = find_function(
        resource,
        r"^[ \t]*void[ \t]+ResourceSystem::clearCache[ \t]*\([^)]*\)",
        "ResourceSystem::clearCache",
    )
    func = resource[start:end]
    closing = func.rfind("}")
    if closing < 0:
        raise RuntimeError("clearCache closing brace not found")

    block = r'''
#if defined(__linux__) && defined(__GLIBC__)
        // TSP_MEMORY_TRIM_CLEAR_051_V7
        ::malloc_trim(0);
#endif
'''
    func = func[:closing] + block + func[closing:]
    resource = resource[:start] + func + resource[end:]


for token in (
    GRID_MARKER,
    "Constants::CellSizeInUnits * 32, 128, 192",
    FILTER_MARKER,
    "tex->setFilter(osg::Texture::MIN_FILTER, osg::Texture::LINEAR);",
    "tex->setFilter(osg::Texture::MAG_FILTER, osg::Texture::LINEAR);",
):
    if token not in water:
        raise RuntimeError("water.cpp verification missing: " + token)

for forbidden in (
    "mWaterGeom->setDrawCallback(new DepthClampCallback);",
    "mWaterNode->addCullCallback(new FudgeCallback);",
    "sceneManager->setForceShaders(true);",
    "sceneManager->recreateShaders(node);",
    "sceneManager->setForceShaders(oldValue);",
):
    if forbidden in water:
        raise RuntimeError(
            "water.cpp regained incompatible behavior: " + forbidden
        )

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

for token in (
    TRIM_UPDATE_MARKER,
    TRIM_CLEAR_MARKER,
    "::malloc_trim(0);",
    "TspTrimIntervalNs",
):
    if token not in resource:
        raise RuntimeError("resourcesystem.cpp verification missing: " + token)

transactional_write(
    (
        (water_path, water),
        (resource_path, resource),
    )
)

print("Patched and verified:")
print(" ", water_path)
print(" ", resource_path)
print()
print("Water:")
print("  coverage:     32 exterior cells full width")
print("  subdivisions: 128 x 128")
print("  square size:  2048 x 2048 world units")
print("  texture:      LINEAR / LINEAR")
print()
print("Memory:")
print("  periodic malloc_trim: <= once per 5 seconds")
print("  full-cache malloc_trim: enabled")
PY_PATCH

echo
echo "Verification markers:"
grep -n \
    -e 'TSP_GL4ES_WATER_DENSE_GRID_051_V7' \
    -e 'TSP_GL4ES_WATER_LINEAR_FILTER_051_V7' \
    "$WATER_CPP"
grep -n \
    -e 'TSP_MEMORY_TRIM_UPDATE_051_V7' \
    -e 'TSP_MEMORY_TRIM_CLEAR_051_V7' \
    "$RESOURCE_CPP"

echo
echo "Known-good v4 distant-render fix remains:"
grep -n \
    -e 'TSP_NILOD_OVERLAP_FIX_051_V4' \
    -e 'TSP_NILOD_OVERLAP_APPLY_051_V4' \
    "$NIFLOADER_CPP" | head -6

echo
echo "Known-good direct-render fix remains:"
grep -n 'TSP_LEGACY_DIRECT_RENDER_051_V2' "$POST_CPP" | head -3

if [ "$PATCH_ONLY" = "1" ]; then
    trap - ERR
    echo
    echo "PATCH_ONLY=1: source patching and verification completed."
    echo "Build and navmeshtool configuration intentionally skipped."
    exit 0
fi

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

if [ -n "$COLLADA_REAL" ]; then
    mkdir -p /root/openmw-0.51-tsp-link-compat
    ln -sfn \
        "$COLLADA_REAL" \
        /root/openmw-0.51-tsp-link-compat/libcollada-dom2.5-dp.so
    ln -sfn \
        "$COLLADA_REAL" \
        /usr/lib/libcollada-dom2.5-dp.so
fi

C_COMPILER_BEFORE="$(
    sed -n 's/^CMAKE_C_COMPILER:[^=]*=//p' \
        "$BUILD_DIR/CMakeCache.txt" | head -1
)"
CXX_COMPILER_BEFORE="$(
    sed -n 's/^CMAKE_CXX_COMPILER:[^=]*=//p' \
        "$BUILD_DIR/CMakeCache.txt" | head -1
)"
SDL2_DIR_BEFORE="$(
    sed -n 's/^SDL2_DIR:[^=]*=//p' \
        "$BUILD_DIR/CMakeCache.txt" | head -1
)"
MYGUI_LIBRARY_BEFORE="$(
    sed -n 's/^MyGUI_LIBRARY:[^=]*=//p' \
        "$BUILD_DIR/CMakeCache.txt" | head -1
)"

NAVMESH_ENABLED="$(
    sed -n 's/^BUILD_NAVMESHTOOL:BOOL=//p' \
        "$BUILD_DIR/CMakeCache.txt" | head -1
)"

if [ "$NAVMESH_ENABLED" != "ON" ]; then
    echo
    echo "Enabling openmw-navmeshtool in the existing build tree..."
    echo "This does NOT delete or clean compiled objects."
    cmake \
        -S "$SOURCE_DIR" \
        -B "$BUILD_DIR" \
        -DBUILD_NAVMESHTOOL=ON
else
    echo
    echo "BUILD_NAVMESHTOOL is already ON; skipping CMake regeneration."
fi

C_COMPILER_AFTER="$(
    sed -n 's/^CMAKE_C_COMPILER:[^=]*=//p' \
        "$BUILD_DIR/CMakeCache.txt" | head -1
)"
CXX_COMPILER_AFTER="$(
    sed -n 's/^CMAKE_CXX_COMPILER:[^=]*=//p' \
        "$BUILD_DIR/CMakeCache.txt" | head -1
)"
SDL2_DIR_AFTER="$(
    sed -n 's/^SDL2_DIR:[^=]*=//p' \
        "$BUILD_DIR/CMakeCache.txt" | head -1
)"
MYGUI_LIBRARY_AFTER="$(
    sed -n 's/^MyGUI_LIBRARY:[^=]*=//p' \
        "$BUILD_DIR/CMakeCache.txt" | head -1
)"

for pair in \
    "C compiler|$C_COMPILER_BEFORE|$C_COMPILER_AFTER" \
    "C++ compiler|$CXX_COMPILER_BEFORE|$CXX_COMPILER_AFTER" \
    "SDL2_DIR|$SDL2_DIR_BEFORE|$SDL2_DIR_AFTER" \
    "MyGUI_LIBRARY|$MYGUI_LIBRARY_BEFORE|$MYGUI_LIBRARY_AFTER"
do
    IFS='|' read -r label before after <<< "$pair"
    if [ -n "$before" ] && [ "$before" != "$after" ]; then
        echo "ERROR: CMake regeneration changed $label."
        echo "Before: $before"
        echo "After:  $after"
        exit 1
    fi
done

TARGET_HELP="$(cmake --build "$BUILD_DIR" --target help 2>/dev/null || true)"
if ! printf '%s\n' "$TARGET_HELP" | grep 'openmw-navmeshtool' >/dev/null
then
    echo "ERROR: openmw-navmeshtool target was not created."
    exit 1
fi

echo
echo "Incrementally rebuilding OpenMW 0.51..."
cmake --build \
    "$BUILD_DIR" \
    --target openmw \
    --parallel "$JOBS"

echo
echo "Building optional openmw-navmeshtool..."
cmake --build \
    "$BUILD_DIR" \
    --target openmw-navmeshtool \
    --parallel "$JOBS"

if [ ! -x "$BUILT_BINARY" ]; then
    echo "ERROR: rebuilt OpenMW executable is missing:"
    echo "  $BUILT_BINARY"
    exit 1
fi

NAVMESH_TOOL="$(
    find "$BUILD_DIR" \
        -type f \
        -name 'openmw-navmeshtool' \
        -perm -111 \
        -print -quit 2>/dev/null
)"

if [ -z "$NAVMESH_TOOL" ]; then
    echo "ERROR: navmeshtool target built but executable could not be found."
    exit 1
fi

echo
echo "Packaging binaries..."

if [ -e "$OUTPUT_BINARY" ]; then
    cp -f "$OUTPUT_BINARY" "$OUTPUT_BINARY.before-$STAMP"
fi
if [ -e "$PACKAGE_BINARY" ]; then
    cp -f \
        "$PACKAGE_BINARY" \
        "$PACKAGE_BINARY.before-stability-water-nav-v7-$STAMP"
fi
if [ -e "$PACKAGE_NAVTOOL" ]; then
    cp -f \
        "$PACKAGE_NAVTOOL" \
        "$PACKAGE_NAVTOOL.before-stability-water-nav-v7-$STAMP"
fi

cp -f "$BUILT_BINARY" "$OUTPUT_BINARY"
cp -f "$BUILT_BINARY" "$PACKAGE_BINARY"
cp -f "$NAVMESH_TOOL" "$PACKAGE_NAVTOOL"

chmod +x \
    "$OUTPUT_BINARY" \
    "$PACKAGE_BINARY" \
    "$PACKAGE_NAVTOOL"

STRIP_TOOL=""
if command -v aarch64-linux-gnu-strip >/dev/null 2>&1; then
    STRIP_TOOL="$(command -v aarch64-linux-gnu-strip)"
elif command -v strip >/dev/null 2>&1; then
    STRIP_TOOL="$(command -v strip)"
fi

if [ -n "$STRIP_TOOL" ]; then
    "$STRIP_TOOL" --strip-unneeded "$OUTPUT_BINARY"
    "$STRIP_TOOL" --strip-unneeded "$PACKAGE_BINARY"
    "$STRIP_TOOL" --strip-unneeded "$PACKAGE_NAVTOOL"
fi

for binary in "$PACKAGE_BINARY" "$PACKAGE_NAVTOOL"; do
    if readelf -d "$binary" 2>/dev/null \
        | grep 'Shared library: \[libcollada-dom2.5-dp' >/dev/null
    then
        echo "ERROR: packaged binary retained fake COLLADA 2.5 runtime name:"
        echo "  $binary"
        exit 1
    fi
done

cat > "$PACKAGE_TOOLS_DIR/apply-runtime-profile-v7.sh" <<'EOF_RUNTIME'
#!/bin/bash
set -eu

GAMEDIR="${OPENMW51_GAMEDIR:-/mnt/SDCARD/data/ports/openmw51}"
CFG="$GAMEDIR/config-0.51/openmw.cfg"
COMPAT="$GAMEDIR/config-0.51/openmw/openmw.cfg"
SETTINGS="$GAMEDIR/config-0.51/settings.cfg"

STAMP="$(date +%Y%m%d-%H%M%S)"

for required in "$CFG" "$SETTINGS"; do
    if [ ! -f "$required" ]; then
        echo "ERROR: missing:"
        echo "  $required"
        exit 1
    fi
done

ATLAS_CORE="$GAMEDIR/mods/Project Atlas/00 Core"
ATLAS_TEXTURES="$GAMEDIR/mods/Project Atlas/01 Textures - Vanilla"
MOP_CORE="$GAMEDIR/mods/Morrowind Optimization Patch/00 Core"

for required in "$MOP_CORE" "$ATLAS_CORE" "$ATLAS_TEXTURES"; do
    if [ ! -d "$required" ]; then
        echo "ERROR: required optimization-mod directory is missing:"
        echo "  $required"
        exit 1
    fi
done

cp -f "$CFG" "$CFG.before-v7-$STAMP"
cp -f "$SETTINGS" "$SETTINGS.before-v7-$STAMP"

python3 - "$CFG" "$GAMEDIR" <<'PY_CFG'
from pathlib import Path
import sys

path = Path(sys.argv[1])
gamedir = sys.argv[2]

text = path.read_text(encoding="utf-8", errors="replace")
lines = text.splitlines()

filtered = []
for line in lines:
    if "/mods/Morrowind Optimization Patch/" in line:
        continue
    if "/mods/Project Atlas/" in line:
        continue
    if "/mods/ProjectAtlas/" in line:
        continue
    if line.strip() in (
        "# Morrowind Optimization Patch",
        "# Project Atlas",
        "# TSP optimization mods",
    ):
        continue
    filtered.append(line)

while filtered and not filtered[-1].strip():
    filtered.pop()

filtered.extend(
    [
        "",
        "# TSP optimization mods",
        f'data="{gamedir}/mods/Morrowind Optimization Patch/00 Core"',
        f'data="{gamedir}/mods/Project Atlas/00 Core"',
        f'data="{gamedir}/mods/Project Atlas/01 Textures - Vanilla"',
        "",
    ]
)

path.write_text("\n".join(filtered), encoding="utf-8", newline="\n")
PY_CFG

mkdir -p "$(dirname "$COMPAT")"
cp -f "$CFG" "$COMPAT"

python3 - "$SETTINGS" <<'PY_SETTINGS'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace")

changes = {
    "Camera": {
        "near clip": "15",
    },
    "Terrain": {
        "object paging active grid": "false",
        "water culling": "true",
    },
    "Cells": {
        "preload enabled": "false",
        "cache expiry delay": "1",
    },
    "Navigator": {
        "enable": "true",
        "wait until min distance to player": "0",
        "enable nav mesh disk cache": "true",
        "write to navmeshdb": "true",
        "async nav mesh updater threads": "1",
        "max nav mesh tiles cache size": "33554432",
    },
}

def set_key(source, section, key, value):
    section_pat = re.compile(
        rf"(?mi)^\[{re.escape(section)}\][ \t]*$"
    )
    match = section_pat.search(source)

    if not match:
        if source and not source.endswith("\n"):
            source += "\n"
        source += f"\n[{section}]\n{key} = {value}\n"
        return source

    next_section = re.search(r"(?m)^\[[^\]]+\][ \t]*$", source[match.end():])
    end = match.end() + next_section.start() if next_section else len(source)

    body = source[match.end():end]
    key_pat = re.compile(
        rf"(?mi)^(?P<prefix>[ \t]*){re.escape(key)}[ \t]*=.*$"
    )

    matches = list(key_pat.finditer(body))
    if matches:
        first = matches[0]
        replacement = first.group("prefix") + f"{key} = {value}"
        body = body[:first.start()] + replacement + body[first.end():]

        body_lines = body.splitlines()
        seen = False
        cleaned = []
        for line in body_lines:
            if re.match(rf"(?i)^[ \t]*{re.escape(key)}[ \t]*=", line):
                if seen:
                    continue
                seen = True
            cleaned.append(line)
        body = "\n".join(cleaned)
        if source[match.end():end].endswith("\n") and not body.endswith("\n"):
            body += "\n"
    else:
        if body and not body.startswith("\n"):
            body = "\n" + body
        body = "\n" + f"{key} = {value}" + body

    return source[:match.end()] + body + source[end:]

for section, values in changes.items():
    for key, value in values.items():
        text = set_key(text, section, key, value)

path.write_text(text, encoding="utf-8", newline="\n")
PY_SETTINGS

echo
echo "===== V7 PROJECT ATLAS / MOP ====="
grep -n \
    -e 'Morrowind Optimization Patch' \
    -e 'Project Atlas' \
    "$CFG"

echo
echo "===== V7 MEMORY / WATER SETTINGS ====="
awk '
/^\[/ { section=$0 }
$0 ~ /^(near clip|object paging active grid|water culling|preload enabled|cache expiry delay|enable|wait until min distance to player|enable nav mesh disk cache|write to navmeshdb|async nav mesh updater threads|max nav mesh tiles cache size)[[:space:]]*=/ {
    if (section == "[Camera]" || section == "[Terrain]" || section == "[Cells]" || section == "[Navigator]")
        print section " " $0
}
' "$SETTINGS"

echo
echo "Runtime profile v7 applied."
echo "Project Atlas remains ENABLED."
echo "near clip remains 15."
echo "navmesh cache is persistent and capped at 32 MiB in RAM."
EOF_RUNTIME

chmod +x "$PACKAGE_TOOLS_DIR/apply-runtime-profile-v7.sh"

cat > "$PACKAGE_TOOLS_DIR/generate-navmesh.sh" <<'EOF_NAV'
#!/bin/bash
set -eu

GAMEDIR="${OPENMW51_GAMEDIR:-/mnt/SDCARD/data/ports/openmw51}"
TOOL="$GAMEDIR/bin/openmw-navmeshtool"
MAIN_CFG="$GAMEDIR/openmw.cfg"
BIN_CFG="$GAMEDIR/bin/openmw.cfg"
CONFIG_DIR="$GAMEDIR/config-0.51"
USER_DATA="$GAMEDIR/savegame-0.51"

THREADS="${NAVMESH_THREADS:-1}"
INTERIORS="${NAVMESH_INTERIORS:-false}"
REMOVE_UNUSED="${NAVMESH_REMOVE_UNUSED:-true}"

if [ ! -x "$TOOL" ]; then
    echo "ERROR: openmw-navmeshtool is missing or not executable:"
    echo "  $TOOL"
    exit 1
fi

if [ ! -f "$MAIN_CFG" ]; then
    echo "ERROR: persistent OpenMW config is missing:"
    echo "  $MAIN_CFG"
    exit 1
fi

if [ ! -f "$CONFIG_DIR/openmw.cfg" ]; then
    echo "ERROR: user content config is missing:"
    echo "  $CONFIG_DIR/openmw.cfg"
    exit 1
fi

case "$THREADS" in
    ''|*[!0-9]*|0)
        echo "ERROR: NAVMESH_THREADS must be an integer >= 1."
        exit 1
        ;;
esac

mkdir -p "$GAMEDIR/bin" "$USER_DATA"
cp -f "$MAIN_CFG" "$BIN_CFG"

export LD_LIBRARY_PATH="$GAMEDIR/lib:$GAMEDIR/libs:$GAMEDIR/lib/aarch64:/mnt/SDCARD/System/lib:/usr/trimui/lib:${LD_LIBRARY_PATH:-}"
export OSG_LIBRARY_PATH="$GAMEDIR/osgPlugins-3.6.5"

echo "============================================================"
echo "OpenMW 0.51 optional navmesh pre-generator"
echo "============================================================"
echo "Game directory: $GAMEDIR"
echo "Database:       $USER_DATA/navmesh.db"
echo "Workers:        $THREADS"
echo "Interiors:      $INTERIORS"
echo "Remove stale:   $REMOVE_UNUSED"
echo
echo "This tool is NOT run automatically by the port."
echo "It uses the currently active OpenMW data/content/mod profile."
echo "============================================================"

exec "$TOOL" \
    --resources "$GAMEDIR/resources" \
    --config "$CONFIG_DIR" \
    --user-data "$USER_DATA" \
    --threads "$THREADS" \
    --process-interior-cells "$INTERIORS" \
    --remove-unused-tiles "$REMOVE_UNUSED" \
    "$@"
EOF_NAV

chmod +x "$PACKAGE_TOOLS_DIR/generate-navmesh.sh"

cat > "$PACKAGE_TOOLS_DIR/README_V7.txt" <<'EOF_README'
OpenMW 0.51 TrimUI Smart Pro S - v7 optional tools
===================================================

apply-runtime-profile-v7.sh
---------------------------
Run once on the TSP after installing the v7 binary.

It keeps:
  near clip = 15
  Project Atlas enabled

It sets:
  water culling = true
  object paging active grid = false
  preload enabled = false
  cache expiry delay = 1
  navigator in-memory tile cache = 32 MiB
  navmesh updater threads = 1
  navmesh disk cache = enabled
  runtime navmesh database writes = enabled

generate-navmesh.sh
-------------------
OPTIONAL. The launcher does not call this.

Run manually to pre-generate navmesh.db using the currently installed
Morrowind data files and active OpenMW mod/content profile.

Default:
  NAVMESH_THREADS=1
  exterior worldspaces only

Examples:

  /mnt/SDCARD/data/ports/openmw51/tools/generate-navmesh.sh

Include interiors:
  NAVMESH_INTERIORS=true \
  /mnt/SDCARD/data/ports/openmw51/tools/generate-navmesh.sh

Use two workers:
  NAVMESH_THREADS=2 \
  /mnt/SDCARD/data/ports/openmw51/tools/generate-navmesh.sh

The generated database is:
  /mnt/SDCARD/data/ports/openmw51/savegame-0.51/navmesh.db

If mods that change collision/world geometry are added or removed, run the
tool again. By default it removes cached tiles not used by the current content
profile and updates the tiles that need regeneration.
EOF_README

echo
echo "Packaged optional tools:"
ls -lh \
    "$PACKAGE_NAVTOOL" \
    "$PACKAGE_TOOLS_DIR/apply-runtime-profile-v7.sh" \
    "$PACKAGE_TOOLS_DIR/generate-navmesh.sh" \
    "$PACKAGE_TOOLS_DIR/README_V7.txt"

echo
echo "Binary verification:"
file "$PACKAGE_BINARY"
file "$PACKAGE_NAVTOOL"
"$PACKAGE_BINARY" --version || true
"$PACKAGE_NAVTOOL" --version || true

trap - ERR

echo
echo "============================================================"
echo "SUCCESS: OpenMW 0.51 TSP v7 completed"
echo "============================================================"
echo "Standalone OpenMW:"
echo "  $OUTPUT_BINARY"
echo
echo "Package OpenMW:"
echo "  $PACKAGE_BINARY"
echo
echo "Optional navmesh tool:"
echo "  $PACKAGE_NAVTOOL"
echo
echo "Device helper scripts:"
echo "  $PACKAGE_TOOLS_DIR/apply-runtime-profile-v7.sh"
echo "  $PACKAGE_TOOLS_DIR/generate-navmesh.sh"
echo
echo "Source backup:"
echo "  $BACKUP_DIR"
echo
echo "Source changes:"
echo "  - 32-cell / 128x128 dense water grid"
echo "  - LINEAR animated simple-water filtering"
echo "  - periodic ResourceSystem malloc_trim"
echo "  - malloc_trim after ResourceSystem::clearCache"
echo
echo "Preserved:"
echo "  - NiLOD v4 distant texture fix"
echo "  - direct framebuffer v2"
echo "  - Project Atlas (runtime helper explicitly enables it)"
echo "  - MOP"
echo "  - fixed-height water / no FudgeCallback"
echo "  - fixed-function water fog"
echo "  - GL4ES global mipmap policy unchanged"
echo "============================================================"
