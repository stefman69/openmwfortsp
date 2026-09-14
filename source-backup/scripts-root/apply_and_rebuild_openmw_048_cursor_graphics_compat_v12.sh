#!/bin/bash
set -euo pipefail

SOURCE_DIR="${1:-/root/openmw}"
BUILD_DIR="${2:-$SOURCE_DIR/build}"
OUTPUT_BINARY="${3:-/root/openmw_cursor_graphics_compat_v12}"

CPP="$SOURCE_DIR/apps/openmw/mwinput/inputmanagerimp.cpp"
WATER_CPP="$SOURCE_DIR/apps/openmw/mwrender/water.cpp"
WATERUTIL_CPP="$SOURCE_DIR/components/sceneutil/waterutil.cpp"
CMAKE_FILE="$SOURCE_DIR/CMakeLists.txt"
BUILT_BINARY="$BUILD_DIR/openmw"

echo "============================================================"
echo "OpenMW 0.48 TSP final simple-water compatibility revision"
echo "SCRIPT REVISION: V12-FIXED-HEIGHT-FIXED-FOG-WATER-2026-08-06"
echo "Keeps triangle water grid and all successful renderer fixes"
echo "Stops camera-relative water movement and black shader fog"
echo "============================================================"
echo "Source:          $SOURCE_DIR"
echo "Build:           $BUILD_DIR"
echo "Stripped output: $OUTPUT_BINARY"
echo ""

for required in \
    "$CPP" \
    "$WATER_CPP" \
    "$WATERUTIL_CPP" \
    "$CMAKE_FILE"
do
    if [ ! -f "$required" ]; then
        echo "ERROR: Required file is missing:"
        echo "$required"
        exit 1
    fi
done

if [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
    echo "ERROR: Existing OpenMW build cache was not found:"
    echo "$BUILD_DIR/CMakeCache.txt"
    exit 1
fi

VERSION_MAJOR="$(
    sed -n \
        's/^[[:space:]]*set(OPENMW_VERSION_MAJOR[[:space:]]*\([0-9][0-9]*\)).*/\1/p' \
        "$CMAKE_FILE" |
    head -1
)"
VERSION_MINOR="$(
    sed -n \
        's/^[[:space:]]*set(OPENMW_VERSION_MINOR[[:space:]]*\([0-9][0-9]*\)).*/\1/p' \
        "$CMAKE_FILE" |
    head -1
)"
VERSION_RELEASE="$(
    sed -n \
        's/^[[:space:]]*set(OPENMW_VERSION_RELEASE[[:space:]]*\([0-9][0-9]*\)).*/\1/p' \
        "$CMAKE_FILE" |
    head -1
)"

echo "Detected source version:"
echo "${VERSION_MAJOR:-?}.${VERSION_MINOR:-?}.${VERSION_RELEASE:-?}"
echo ""

if [ "${VERSION_MAJOR:-}" != "0" ] ||
   [ "${VERSION_MINOR:-}" != "48" ] ||
   [ "${VERSION_RELEASE:-}" != "0" ]
then
    echo "ERROR: This script is only for OpenMW 0.48.0."
    exit 1
fi

if ! grep -q 'TSP_MYGUI_CURSOR_V12' "$CPP"; then
    echo "ERROR: The working V12 pointer patch was not found."
    exit 1
fi

if ! grep -q 'TSP_GL4ES_WATER_TRIANGLE_GRID_V12' "$WATER_CPP"; then
    echo "ERROR: The successful triangle-grid water patch was not found."
    echo "Run this only after the water triangle-grid revision."
    exit 1
fi

if ! grep -q 'TSP_GL4ES_WATER_EXPLICIT_TRIANGLES_V12' "$WATERUTIL_CPP"; then
    echo "ERROR: Explicit triangle water geometry was not found."
    exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
cp -f "$WATER_CPP" \
    "$WATER_CPP.before-fixed-height-fixed-fog-v12.$STAMP"

echo "Created source backup:"
echo "$WATER_CPP.before-fixed-height-fixed-fog-v12.$STAMP"
echo ""

python3 - "$WATER_CPP" <<'PY_WATER'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

# ---------------------------------------------------------------
# 1. Stop moving the water plane relative to the camera.
#
# FudgeCallback exists only to work around artifacts caused by
# GL_DEPTH_CLAMP. The TSP build has already disabled GL_DEPTH_CLAMP,
# so retaining this callback is unnecessary. Raising its threshold
# from 0.2 to 2.0 made the visible water level move when the camera
# approached or crossed the surface, producing the "draining" effect.
# ---------------------------------------------------------------
height_marker = (
    "// TSP_GL4ES_WATER_FIXED_HEIGHT_V12: "
    "camera-relative FudgeCallback disabled."
)
callback_line = "    mWaterNode->addCullCallback(new FudgeCallback);"

if callback_line in text:
    text = text.replace(callback_line, "    " + height_marker, 1)
elif height_marker not in text:
    raise RuntimeError(
        "Could not locate or verify the water FudgeCallback attachment."
    )

# Restore the unused callback's original constant for source sanity.
text = re.sub(
    r'([ \t]*)// TSP_GL4ES_WATER_NEAR_CLIP_FUDGE_V12[ \t]*\n'
    r'[ \t]*const float fudge = 2\.0f?;',
    r'\1const float fudge = 0.2;',
    text,
    count=1,
)

# ---------------------------------------------------------------
# 2. Use gl4es fixed-function fog for simple water.
#
# OpenMW forces a generated object shader here solely to calculate
# fog per pixel. On this GLES2/gl4es device that shader renders the
# fogged part of the water as black. The water mesh is now divided
# into 64 x 64 explicit triangles, so fixed-function per-vertex fog
# has enough geometry to interpolate smoothly.
# ---------------------------------------------------------------
fog_marker = "// TSP_GL4ES_SIMPLE_WATER_FIXED_FOG_V12"

state_anchor = (
    "    osg::ref_ptr<osg::StateSet> stateset = "
    "SceneUtil::createSimpleWaterStateSet("
    "alpha, MWRender::RenderBin_Water);\n"
)

state_block = (
    state_anchor
    + "\n"
    + "    " + fog_marker + "\n"
    + "    stateset->setMode(\n"
    + "        GL_FOG,\n"
    + "        osg::StateAttribute::ON\n"
    + "            | osg::StateAttribute::OVERRIDE);\n"
    + "    stateset->setMode(\n"
    + "        GL_LIGHTING,\n"
    + "        osg::StateAttribute::OFF\n"
    + "            | osg::StateAttribute::OVERRIDE);\n"
)

if fog_marker not in text:
    if state_anchor not in text:
        raise RuntimeError(
            "Could not locate the simple-water StateSet creation."
        )
    text = text.replace(state_anchor, state_block, 1)

shader_pattern = re.compile(
    r'^[ \t]*// use a shader to render the simple water,'
    r'.*?'
    r'^[ \t]*sceneManager->setForceShaders\(oldValue\);[ \t]*\n?',
    flags=re.MULTILINE | re.DOTALL,
)

shader_matches = list(shader_pattern.finditer(text))
shader_removed_marker = (
    "    // TSP_GL4ES_SIMPLE_WATER_GENERATED_SHADER_DISABLED_V12\n"
    "    // Fixed-function fog is used on the subdivided triangle grid.\n"
)

if shader_matches:
    if len(shader_matches) != 1:
        raise RuntimeError(
            "Expected one simple-water forced-shader block; found "
            + str(len(shader_matches))
        )
    text = shader_pattern.sub(shader_removed_marker, text, count=1)
elif "TSP_GL4ES_SIMPLE_WATER_GENERATED_SHADER_DISABLED_V12" not in text:
    raise RuntimeError(
        "Could not locate or verify the forced simple-water shader block."
    )

required = (
    "TSP_GL4ES_WATER_TRIANGLE_GRID_V12",
    "TSP_GL4ES_WATER_FIXED_HEIGHT_V12",
    "TSP_GL4ES_SIMPLE_WATER_FIXED_FOG_V12",
    "TSP_GL4ES_SIMPLE_WATER_GENERATED_SHADER_DISABLED_V12",
    "GL_FOG",
    "GL_LIGHTING",
)

for token in required:
    if token not in text:
        raise RuntimeError(
            "water.cpp verification failed: missing " + token
        )

for forbidden in (
    "mWaterNode->addCullCallback(new FudgeCallback);",
    "sceneManager->setForceShaders(true);",
    "sceneManager->recreateShaders(node);",
    "const float fudge = 2.0f;",
):
    if forbidden in text:
        raise RuntimeError(
            "water.cpp still contains incompatible code: " + forbidden
        )

with open(
    path,
    "w",
    encoding="utf-8",
    newline="\n",
) as handle:
    handle.write(text)

print("Updated:")
print(path)
PY_WATER

echo ""
echo "Patch verification:"
grep -n 'TSP_GL4ES_WATER_TRIANGLE_GRID_V12' "$WATER_CPP"
grep -n 'TSP_GL4ES_WATER_FIXED_HEIGHT_V12' "$WATER_CPP"
grep -n 'TSP_GL4ES_SIMPLE_WATER_FIXED_FOG_V12' "$WATER_CPP"
grep -n 'TSP_GL4ES_SIMPLE_WATER_GENERATED_SHADER_DISABLED_V12' "$WATER_CPP"
grep -n 'TSP_GL4ES_WATER_EXPLICIT_TRIANGLES_V12' "$WATERUTIL_CPP"
echo ""

echo "Incrementally rebuilding OpenMW 0.48..."
cmake --build \
    "$BUILD_DIR" \
    --target openmw \
    --parallel "$(nproc)"

if [ ! -x "$BUILT_BINARY" ]; then
    echo "ERROR: Build completed, but the executable was not found:"
    echo "$BUILT_BINARY"
    exit 1
fi

echo ""
echo "Creating stripped deployment binary..."
cp -f "$BUILT_BINARY" "$OUTPUT_BINARY"

STRIP_TOOL=""
if command -v aarch64-linux-gnu-strip >/dev/null 2>&1; then
    STRIP_TOOL="$(command -v aarch64-linux-gnu-strip)"
elif command -v strip >/dev/null 2>&1; then
    STRIP_TOOL="$(command -v strip)"
else
    echo "ERROR: No strip tool was found."
    exit 1
fi

"$STRIP_TOOL" --strip-unneeded "$OUTPUT_BINARY"
chmod +x "$OUTPUT_BINARY"

echo ""
echo "============================================================"
echo "Fixed-height fixed-fog V12 rebuild completed"
echo "============================================================"
echo "Deployment binary:"
ls -lh "$OUTPUT_BINARY"
file "$OUTPUT_BINARY"
echo ""
echo "Unchanged:"
echo "  - controls and pointer behavior"
echo "  - terrain, object paging and groundcover"
echo "  - distant textures and world fog"
echo "  - explicit triangle water geometry"
echo ""
echo "Changed:"
echo "  - water no longer moves relative to the camera"
echo "  - simple water no longer uses the black-fog shader path"
echo "  - simple water uses gl4es fixed-function fog"
echo "============================================================"
