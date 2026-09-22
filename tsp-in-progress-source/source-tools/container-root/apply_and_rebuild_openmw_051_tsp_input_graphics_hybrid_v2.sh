#!/bin/bash
set -Eeuo pipefail

# OpenMW 0.51.0 TrimUI Smart Pro input/cursor + renderer compatibility rebuild.
#
# Builds two things from the existing ARM64 OpenMW build tree:
#   1. OpenMW with the TSP MyGUI cursor visibility patch.
#   2. tsp_openmw_controls_051_v1, a merged mouse/text helper based on
#      tsp_openmw_controls_v3.
#
# Controller behavior supplied by the helper:
#   - GAME: native OpenMW 0.51 controller input passes through untouched.
#   - MENU+START: toggle HYBRID mode.
#   - HYBRID sticks: mouse movement; R1 slows mouse.
#   - HYBRID R2/L2: left/right click.
#   - HYBRID D-pad Up/Down: previous/next character.
#   - HYBRID D-pad Right/A: type selected character.
#   - HYBRID D-pad Left/B: backspace.
#   - HYBRID Y: toggle selected character case.
#   - HYBRID X: Escape; Start: Enter.
#   - START+SELECT held ~2 seconds: emergency terminate openmw-0.51.
#
# The helper emits KEY_PAUSE when HYBRID mode toggles. The OpenMW source
# patch watches Pause and shows/hides MyGUI's in-engine cursor in GUI mode.
# SDL's hardware cursor stays disabled because it is unreliable through GL4ES.
#
# Renderer changes in this FULL version are the proven 0.48-derived water fixes:
#   - smaller 64x64 water grid
#   - explicit GLES2-friendly triangles instead of GL_QUADS
#   - GL_DEPTH_CLAMP disabled
#   - camera-relative water-height callback disabled
#   - simple water forced to fixed-function fog instead of generated shader
#
# This script does not patch the still-under-investigation 0.51 GLSL resource
# issues (for example fullscreen_tri.vert uniform initializers). Keep those
# runtime resource experiments separate until the exact final shader fix is known.

SOURCE_DIR="${1:-/root/openmw-0.51-tsp-src}"
BUILD_DIR="${2:-/root/openmw-0.51-tsp-build}"
PACKAGE_DIR="${3:-/root/openmw-0.51-tsp-package}"
OUTPUT_BINARY="${4:-/root/openmw-0.51-tsp-input-graphics-v2}"
HELPER_OUTPUT="${5:-/root/tsp_openmw_controls_051_v1}"
JOBS="${OPENMW_JOBS:-$(nproc)}"
PATCH_ONLY="${OPENMW_PATCH_ONLY:-0}"
NO_STRIP="${OPENMW_NO_STRIP:-0}"

CPP="$SOURCE_DIR/apps/openmw/mwinput/inputmanagerimp.cpp"
HPP="$SOURCE_DIR/apps/openmw/mwinput/inputmanagerimp.hpp"
WATER_CPP="$SOURCE_DIR/apps/openmw/mwrender/water.cpp"
WATERUTIL_CPP="$SOURCE_DIR/components/sceneutil/waterutil.cpp"
CMAKE_FILE="$SOURCE_DIR/CMakeLists.txt"
BUILT_BINARY="$BUILD_DIR/openmw"
PACKAGE_BINARY="$PACKAGE_DIR/bin/openmw-0.51"
PACKAGE_HELPER="$PACKAGE_DIR/tsp_openmw_controls_051_v1"
HELPER_SOURCE="${OPENMW_HELPER_SOURCE_OUT:-/root/tsp_openmw_controls_051_v1.c}"
SCRIPT_REVISION="TSP-051-INPUT-GRAPHICS-HYBRID-V2-2026-08-07"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$SOURCE_DIR/.tsp-051-source-backups/input-graphics-hybrid-$STAMP"

restore_on_patch_error() {
    result=$?
    if [ "$result" -ne 0 ] && [ -d "$BACKUP_DIR" ]; then
        echo
        echo "ERROR: Input patching failed. Restoring pre-patch InputManager files..."
        [ -f "$BACKUP_DIR/apps/openmw/mwinput/inputmanagerimp.cpp" ] && \
            cp -f "$BACKUP_DIR/apps/openmw/mwinput/inputmanagerimp.cpp" "$CPP"
        [ -f "$BACKUP_DIR/apps/openmw/mwinput/inputmanagerimp.hpp" ] && \
            cp -f "$BACKUP_DIR/apps/openmw/mwinput/inputmanagerimp.hpp" "$HPP"
        [ -f "$BACKUP_DIR/apps/openmw/mwrender/water.cpp" ] && \
            cp -f "$BACKUP_DIR/apps/openmw/mwrender/water.cpp" "$WATER_CPP"
        [ -f "$BACKUP_DIR/components/sceneutil/waterutil.cpp" ] && \
            cp -f "$BACKUP_DIR/components/sceneutil/waterutil.cpp" "$WATERUTIL_CPP"
        echo "Input/renderer source restoration completed."
        echo "Backups remain at: $BACKUP_DIR"
    fi
    exit "$result"
}
trap restore_on_patch_error ERR

echo "============================================================"
echo "OpenMW 0.51 TSP input + hybrid mouse/text + graphics rebuild"
echo "Revision: $SCRIPT_REVISION"
echo "============================================================"
echo "Source:            $SOURCE_DIR"
echo "Build:             $BUILD_DIR"
echo "Package:           $PACKAGE_DIR"
echo "Standalone OpenMW: $OUTPUT_BINARY"
echo "Standalone helper: $HELPER_OUTPUT"
echo "Jobs:              $JOBS"
echo "Patch only:        $PATCH_ONLY"
echo

for required in "$CPP" "$HPP" "$WATER_CPP" "$WATERUTIL_CPP" "$CMAKE_FILE"; do
    if [ ! -f "$required" ]; then
        echo "ERROR: Required OpenMW source file is missing:"
        echo "  $required"
        exit 1
    fi
done

VERSION_MAJOR="$(sed -n 's/^[[:space:]]*set(OPENMW_VERSION_MAJOR[[:space:]]*\([0-9][0-9]*\)).*/\1/p' "$CMAKE_FILE" | head -1)"
VERSION_MINOR="$(sed -n 's/^[[:space:]]*set(OPENMW_VERSION_MINOR[[:space:]]*\([0-9][0-9]*\)).*/\1/p' "$CMAKE_FILE" | head -1)"
VERSION_RELEASE="$(sed -n 's/^[[:space:]]*set(OPENMW_VERSION_RELEASE[[:space:]]*\([0-9][0-9]*\)).*/\1/p' "$CMAKE_FILE" | head -1)"

echo "Detected source version: ${VERSION_MAJOR:-?}.${VERSION_MINOR:-?}.${VERSION_RELEASE:-?}"
if [ "${VERSION_MAJOR:-}" != "0" ] || [ "${VERSION_MINOR:-}" != "51" ] || [ "${VERSION_RELEASE:-}" != "0" ]; then
    echo "ERROR: This patcher is only for OpenMW 0.51.0 source."
    exit 1
fi

if [ "$PATCH_ONLY" != "1" ] && [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
    echo "ERROR: Existing OpenMW 0.51 build cache was not found:"
    echo "  $BUILD_DIR/CMakeCache.txt"
    exit 1
fi

mkdir -p "$BACKUP_DIR/apps/openmw/mwinput"
mkdir -p "$BACKUP_DIR/apps/openmw/mwrender"
mkdir -p "$BACKUP_DIR/components/sceneutil"
cp -f "$CPP" "$BACKUP_DIR/apps/openmw/mwinput/inputmanagerimp.cpp"
cp -f "$HPP" "$BACKUP_DIR/apps/openmw/mwinput/inputmanagerimp.hpp"
cp -f "$WATER_CPP" "$BACKUP_DIR/apps/openmw/mwrender/water.cpp"
cp -f "$WATERUTIL_CPP" "$BACKUP_DIR/components/sceneutil/waterutil.cpp"
echo "Created input/renderer source backup: $BACKUP_DIR"

python3 - "$CPP" "$HPP" <<'PY_INPUT_PATCH'
from pathlib import Path
import os
import re
import sys

cpp_path = Path(sys.argv[1])
hpp_path = Path(sys.argv[2])
cpp = cpp_path.read_text(encoding="utf-8")
hpp = hpp_path.read_text(encoding="utf-8")


def find_function(text, signature_pattern):
    matches = list(re.finditer(signature_pattern, text, flags=re.MULTILINE))
    if len(matches) != 1:
        raise RuntimeError(
            "Expected exactly one function matching {!r}; found {}".format(
                signature_pattern, len(matches)
            )
        )
    start = matches[0].start()
    brace = text.find("{", matches[0].end())
    if brace < 0:
        raise RuntimeError("Function opening brace was not found.")

    depth = 0
    index = brace
    in_string = False
    in_char = False
    in_line_comment = False
    in_block_comment = False
    escaped = False

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
    raise RuntimeError("Function closing brace was not found.")


def write_transactionally(path_to_text):
    temporary_paths = []
    try:
        for path, text in path_to_text:
            temporary = Path(str(path) + ".tsp051.tmp")
            with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
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


marker = "TSP_MYGUI_CURSOR_051_HYBRID_V1"
cpp = re.sub(
    r"^[ \t]*//[ \t]*TSP_MYGUI_CURSOR[^\n]*\n",
    "",
    cpp,
    flags=re.MULTILINE,
)

if "#include <MyGUI_PointerManager.h>" not in cpp:
    include_matches = list(re.finditer(r"^#include[^\n]*\n", cpp, flags=re.MULTILINE))
    if not include_matches:
        raise RuntimeError("Could not find a C++ include insertion point.")
    insertion = include_matches[-1].end()
    cpp = cpp[:insertion] + "#include <MyGUI_PointerManager.h>\n" + cpp[insertion:]

new_update = r'''    // TSP_MYGUI_CURSOR_051_HYBRID_V1
    void InputManager::update(float dt, bool disableControls, bool disableEvents)
    {
        mControlsDisabled = disableControls;

        MWBase::WindowManager* windowManager
            = MWBase::Environment::get().getWindowManager();

        // The TrimUI/gl4es path does not reliably display SDL's hardware
        // cursor. Always use MyGUI's in-engine pointer instead.
        mInputWrapper->setMouseVisible(false);
        mInputWrapper->capture(disableEvents);

        // tsp_openmw_controls_051_v1 emits a short Pause key press whenever
        // MENU+START enters or leaves the merged HYBRID mouse/text mode.
        const Uint8* keyboardState = SDL_GetKeyboardState(nullptr);
        const bool cursorChordPressed
            = keyboardState != nullptr
            && keyboardState[SDL_SCANCODE_PAUSE] != 0;

        if (cursorChordPressed && !mTspCursorChordWasPressed)
            mTspCursorVisible = !mTspCursorVisible;

        mTspCursorChordWasPressed = cursorChordPressed;

        const bool showMyGuiPointer
            = mTspCursorVisible
            && windowManager->isGuiMode();

        MyGUI::PointerManager::getInstance().setVisible(showMyGuiPointer);

        if (disableControls)
        {
            mMouseManager->updateCursorMode();
            return;
        }

        // Preserve the stock OpenMW 0.51 input update sequence.
        mBindingsManager->update(dt);
        mMouseManager->updateCursorMode();
        mControllerManager->update(dt);
        mMouseManager->update(dt);
        mSensorManager->update(dt);
        mActionManager->update(dt);

        if (Settings::input().mEnableGyroscope)
        {
            bool controllerAvailable = mControllerManager->isGyroAvailable();
            bool sensorAvailable = mSensorManager->isGyroAvailable();
            if (controllerAvailable || sensorAvailable)
            {
                mGyroManager->update(
                    dt,
                    controllerAvailable
                        ? mControllerManager->getGyroValues()
                        : mSensorManager->getGyroValues());
            }
        }
    }
'''

update_start, update_end = find_function(
    cpp,
    r"^[ \t]*void[ \t]+InputManager::update[ \t]*\(",
)
cpp = cpp[:update_start] + new_update + cpp[update_end:]

hpp = re.sub(
    r"^[ \t]*//[ \t]*TSP_MYGUI_CURSOR[^\n]*\n",
    "",
    hpp,
    flags=re.MULTILINE,
)
for member_name in (
    "mTspMouseModeEnabled",
    "mTspTextModeEnabled",
    "mTspSelectWasPressed",
    "mTspLeftShoulderWasPressed",
    "mTspCursorVisible",
    "mTspLeftStickWasPressed",
    "mTspCursorChordWasPressed",
    "mTspSelectConsumedByChord",
):
    hpp = re.sub(
        r"^[ \t]*bool[ \t]+" + re.escape(member_name) + r"[ \t]*=[ \t]*false;[ \t]*\n",
        "",
        hpp,
        flags=re.MULTILINE,
    )

member_pattern = re.compile(
    r"^(?P<indent>[ \t]*)std::unique_ptr<GyroManager>[ \t]+mGyroManager;[ \t]*$",
    flags=re.MULTILINE,
)
member_matches = list(member_pattern.finditer(hpp))
if len(member_matches) != 1:
    raise RuntimeError(
        "Expected exactly one GyroManager member; found {}.".format(len(member_matches))
    )
member_match = member_matches[0]
indent = member_match.group("indent")
member_block = (
    member_match.group(0)
    + "\n\n"
    + indent + "// TSP_MYGUI_CURSOR_051_HYBRID_V1\n"
    + indent + "bool mTspCursorVisible = false;\n"
    + indent + "bool mTspCursorChordWasPressed = false;"
)
hpp = hpp[:member_match.start()] + member_block + hpp[member_match.end():]

for token in (
    marker,
    "SDL_SCANCODE_PAUSE",
    "mTspCursorVisible",
    "mTspCursorChordWasPressed",
    "MyGUI::PointerManager",
    "mControllerManager->update(dt);",
    "mActionManager->update(dt);",
    "Settings::input().mEnableGyroscope",
):
    if token not in cpp:
        raise RuntimeError("inputmanagerimp.cpp is missing: " + token)

if hpp.count("bool mTspCursorVisible = false;") != 1:
    raise RuntimeError("Expected exactly one mTspCursorVisible member.")
if hpp.count("bool mTspCursorChordWasPressed = false;") != 1:
    raise RuntimeError("Expected exactly one mTspCursorChordWasPressed member.")

write_transactionally(((cpp_path, cpp), (hpp_path, hpp)))
print("Patched and verified:")
print(cpp_path)
print(hpp_path)
PY_INPUT_PATCH

echo
echo "Applying 0.48-derived OpenMW 0.51 water/GL4ES renderer patches..."
python3 - \
    "$WATER_CPP" \
    "$WATERUTIL_CPP" <<'PY_PATCH'
from pathlib import Path
import os
import re
import sys

water_path = Path(sys.argv[1])
waterutil_path = Path(sys.argv[2])

water = water_path.read_text(encoding="utf-8")
waterutil = waterutil_path.read_text(encoding="utf-8")


def find_function(text, signature_pattern):
    """Return the complete source range of one brace-delimited function."""
    matches = list(re.finditer(signature_pattern, text, flags=re.MULTILINE))

    if len(matches) != 1:
        raise RuntimeError(
            "Expected exactly one function matching {!r}; found {}".format(
                signature_pattern,
                len(matches),
            )
        )

    start = matches[0].start()
    brace = text.find("{", matches[0].end())

    if brace < 0:
        raise RuntimeError("Function opening brace was not found.")

    depth = 0
    index = brace
    in_string = False
    in_char = False
    in_line_comment = False
    in_block_comment = False
    escaped = False

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

    raise RuntimeError("Function closing brace was not found.")


def write_transactionally(path_to_text):
    temporary_paths = []

    try:
        for path, text in path_to_text:
            temporary = Path(str(path) + ".tsp051.tmp")

            with open(
                temporary,
                "w",
                encoding="utf-8",
                newline="\n",
            ) as handle:
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
# 1. Smaller, more finely divided water plane
# =====================================================================

geometry_marker = "// TSP_GL4ES_WATER_TRIANGLE_GRID_051_V2"

if geometry_marker not in water:
    # Accept the previous graphics-only marker as already patched.
    if "TSP_GL4ES_WATER_TRIANGLE_GRID_051_V1" not in water:
        geometry_pattern = re.compile(
            r"^[ \t]*mWaterGeom[ \t]*=[ \t]*"
            r"SceneUtil::createWaterGeometry[ \t]*\([^;]*?\)[ \t]*;[ \t]*$",
            flags=re.MULTILINE | re.DOTALL,
        )
        geometry_matches = list(geometry_pattern.finditer(water))

        if len(geometry_matches) != 1:
            raise RuntimeError(
                "Expected exactly one water geometry constructor; found {}.".format(
                    len(geometry_matches)
                )
            )

        geometry_indent_match = re.match(
            r"[ \t]*",
            geometry_matches[0].group(0),
        )
        geometry_indent = geometry_indent_match.group(0)

        geometry_replacement = (
            geometry_indent
            + geometry_marker
            + "\n"
            + geometry_indent
            + "mWaterGeom = SceneUtil::createWaterGeometry(\n"
            + geometry_indent
            + "    Constants::CellSizeInUnits * 16, 64, 96);"
        )

        water = (
            water[: geometry_matches[0].start()]
            + geometry_replacement
            + water[geometry_matches[0].end() :]
        )


# =====================================================================
# 2. Disable GL_DEPTH_CLAMP and camera-relative water movement
# =====================================================================

depth_marker = (
    "// TSP_GL4ES_WATER_DEPTH_051_V2: "
    "GL_DEPTH_CLAMP disabled for gl4es/GLES2."
)

if depth_marker not in water:
    if "TSP_GL4ES_WATER_DEPTH_051_V1" not in water:
        depth_pattern = re.compile(
            r"^(?P<indent>[ \t]*)mWaterGeom->setDrawCallback[ \t]*\("
            r"[ \t]*new[ \t]+DepthClampCallback[ \t]*\)[ \t]*;[ \t]*$",
            flags=re.MULTILINE,
        )
        depth_matches = list(depth_pattern.finditer(water))

        if len(depth_matches) != 1:
            raise RuntimeError(
                "Expected exactly one water DepthClampCallback attachment; "
                "found {}.".format(len(depth_matches))
            )

        replacement = depth_matches[0].group("indent") + depth_marker
        water = depth_pattern.sub(replacement, water, count=1)

height_marker = (
    "// TSP_GL4ES_WATER_FIXED_HEIGHT_051_V2: "
    "camera-relative FudgeCallback disabled."
)

if height_marker not in water:
    if "TSP_GL4ES_WATER_FIXED_HEIGHT_051_V1" not in water:
        height_pattern = re.compile(
            r"^(?P<indent>[ \t]*)mWaterNode->addCullCallback[ \t]*\("
            r"[ \t]*new[ \t]+FudgeCallback[ \t]*\)[ \t]*;[ \t]*$",
            flags=re.MULTILINE,
        )
        height_matches = list(height_pattern.finditer(water))

        if len(height_matches) != 1:
            raise RuntimeError(
                "Expected exactly one water FudgeCallback attachment; "
                "found {}.".format(len(height_matches))
            )

        replacement = height_matches[0].group("indent") + height_marker
        water = height_pattern.sub(replacement, water, count=1)

# The callback is now unattached. Restore its original constant if an older
# water experiment changed it to 2.0.
water = re.sub(
    r"(?P<indent>[ \t]*)//[ \t]*TSP_GL4ES_WATER_NEAR_CLIP_FUDGE[^\n]*\n"
    r"[ \t]*const[ \t]+float[ \t]+fudge[ \t]*=[ \t]*2\.0f?[ \t]*;",
    r"\g<indent>const float fudge = 0.2;",
    water,
    count=1,
)


# =====================================================================
# 3. Simple water: fixed-function fog, no generated object shader
# =====================================================================

simple_start, simple_end = find_function(
    water,
    r"^[ \t]*void[ \t]+Water::createSimpleWaterStateSet[ \t]*\(",
)
simple_function = water[simple_start:simple_end]

fog_marker = "// TSP_GL4ES_SIMPLE_WATER_FIXED_FOG_051_V2"

if (
    fog_marker not in simple_function
    and "TSP_GL4ES_SIMPLE_WATER_FIXED_FOG_051_V1" not in simple_function
):
    state_pattern = re.compile(
        r"^(?P<indent>[ \t]*)osg::ref_ptr<osg::StateSet>[ \t]+stateset"
        r"[ \t]*=[ \t]*SceneUtil::createSimpleWaterStateSet[ \t]*\("
        r"[ \t]*alpha[ \t]*,[ \t]*MWRender::RenderBin_Water[ \t]*\)"
        r"[ \t]*;[ \t]*$",
        flags=re.MULTILINE,
    )
    state_matches = list(state_pattern.finditer(simple_function))

    if len(state_matches) != 1:
        raise RuntimeError(
            "Expected exactly one simple-water StateSet creation; "
            "found {}.".format(len(state_matches))
        )

    state_match = state_matches[0]
    state_indent = state_match.group("indent")

    state_block = (
        state_match.group(0)
        + "\n\n"
        + state_indent
        + fog_marker
        + "\n"
        + state_indent
        + "stateset->setMode(\n"
        + state_indent
        + "    GL_FOG,\n"
        + state_indent
        + "    osg::StateAttribute::ON\n"
        + state_indent
        + "        | osg::StateAttribute::OVERRIDE);\n"
        + state_indent
        + "stateset->setMode(\n"
        + state_indent
        + "    GL_LIGHTING,\n"
        + state_indent
        + "    osg::StateAttribute::OFF\n"
        + state_indent
        + "        | osg::StateAttribute::OVERRIDE);"
    )

    simple_function = (
        simple_function[: state_match.start()]
        + state_block
        + simple_function[state_match.end() :]
    )

shader_marker = "TSP_GL4ES_SIMPLE_WATER_SHADER_DISABLED_051_V2"

if (
    shader_marker not in simple_function
    and "TSP_GL4ES_SIMPLE_WATER_SHADER_DISABLED_051_V1"
    not in simple_function
):
    shader_pattern = re.compile(
        r"^[ \t]*//[ \t]*use a shader to render the simple water,.*?"
        r"^[ \t]*sceneManager->setForceShaders[ \t]*\("
        r"[ \t]*oldValue[ \t]*\)[ \t]*;[ \t]*\n?",
        flags=re.MULTILINE | re.DOTALL | re.IGNORECASE,
    )
    shader_matches = list(shader_pattern.finditer(simple_function))

    if len(shader_matches) == 1:
        shader_indent_match = re.match(
            r"[ \t]*",
            shader_matches[0].group(0),
        )
        shader_indent = shader_indent_match.group(0)

        shader_replacement = (
            shader_indent
            + "// TSP_GL4ES_SIMPLE_WATER_SHADER_DISABLED_051_V2\n"
            + shader_indent
            + "// Fixed-function fog is used on the subdivided triangle grid.\n"
        )

        simple_function = shader_pattern.sub(
            shader_replacement,
            simple_function,
            count=1,
        )
    elif len(shader_matches) == 0:
        # OpenMW 0.51 source exists in two forms that we have encountered:
        #
        #   A) an older/alternate block that temporarily forces shaders:
        #        sceneManager->setForceShaders(true);
        #        sceneManager->recreateShaders(node);
        #        sceneManager->setForceShaders(oldValue);
        #
        #   B) the current source used by this TSP build, which simply does:
        #        Resource::SceneManager* sceneManager = ...;
        #        sceneManager->recreateShaders(node);
        #
        # Both paths generate the simple-water shader that we intentionally
        # disable for GL4ES. Detect either form without assuming one revision.
        force_true = simple_function.find(
            "sceneManager->setForceShaders(true);"
        )
        recreate = simple_function.find(
            "sceneManager->recreateShaders(node);"
        )
        restore = simple_function.find(
            "sceneManager->setForceShaders(oldValue);"
        )

        lines = simple_function.splitlines(keepends=True)
        offsets = []
        cursor = 0

        for line in lines:
            offsets.append(cursor)
            cursor += len(line)

        def line_for_offset(offset):
            result = 0

            for index, line_offset in enumerate(offsets):
                if line_offset > offset:
                    break

                result = index

            return result

        if 0 <= force_true < recreate < restore:
            first_line = line_for_offset(force_true)
            last_line = line_for_offset(restore)
            block_start = first_line

            # Include the oldValue/sceneManager declarations immediately before
            # setForceShaders(true), plus their explanatory comment.
            for index in range(first_line - 1, max(-1, first_line - 12), -1):
                stripped = lines[index].strip()

                if (
                    "oldValue" in stripped
                    or "sceneManager" in stripped
                    or stripped.startswith("//")
                    or stripped == ""
                ):
                    block_start = index
                    continue

                break

            indent_match = re.match(r"[ \t]*", lines[first_line])
            block_indent = indent_match.group(0)

            replacement_lines = [
                block_indent
                + "// TSP_GL4ES_SIMPLE_WATER_SHADER_DISABLED_051_V2\n",
                block_indent
                + "// Fixed-function fog is used on the subdivided triangle grid.\n",
            ]

            lines[block_start : last_line + 1] = replacement_lines
            simple_function = "".join(lines)

        elif recreate >= 0 and force_true < 0 and restore < 0:
            # Current OpenMW 0.51 source: remove the explanatory comments,
            # SceneManager declaration, and recreateShaders(node) call.
            recreate_line = line_for_offset(recreate)
            block_start = recreate_line

            declaration_line = None
            for index in range(recreate_line - 1, max(-1, recreate_line - 12), -1):
                stripped = lines[index].strip()

                if (
                    "Resource::SceneManager* sceneManager" in stripped
                    and "mResourceSystem->getSceneManager()" in stripped
                ):
                    declaration_line = index
                    block_start = index
                    break

            if declaration_line is None:
                raise RuntimeError(
                    "Found sceneManager->recreateShaders(node), but could not "
                    "locate its SceneManager declaration."
                )

            # Include the immediately preceding explanatory comment block and
            # blank separator, but never consume executable statements above it.
            for index in range(declaration_line - 1, max(-1, declaration_line - 8), -1):
                stripped = lines[index].strip()
                if stripped.startswith("//") or stripped == "":
                    block_start = index
                    continue
                break

            indent_match = re.match(r"[ \t]*", lines[declaration_line])
            block_indent = indent_match.group(0)

            replacement_lines = [
                block_indent
                + "// TSP_GL4ES_SIMPLE_WATER_SHADER_DISABLED_051_V2\n",
                block_indent
                + "// Fixed-function fog is used on the subdivided triangle grid.\n",
            ]

            lines[block_start : recreate_line + 1] = replacement_lines
            simple_function = "".join(lines)

        else:
            raise RuntimeError(
                "Could not locate a supported OpenMW 0.51 simple-water "
                "shader recreation block."
            )
    else:
        raise RuntimeError(
            "Found multiple possible forced simple-water shader blocks."
        )

water = water[:simple_start] + simple_function + water[simple_end:]


# =====================================================================
# 4. GLES2-compatible explicit water triangles instead of GL_QUADS
# =====================================================================

triangles_marker = "// TSP_GL4ES_WATER_EXPLICIT_TRIANGLES_051_V2"

if (
    triangles_marker not in waterutil
    and "TSP_GL4ES_WATER_EXPLICIT_TRIANGLES_051_V1"
    not in waterutil
):
    primitive_pattern = re.compile(
        r"^(?P<indent>[ \t]*)waterGeom->addPrimitiveSet[ \t]*\("
        r"[ \t]*new[ \t]+osg::DrawArrays[ \t]*\("
        r"[ \t]*osg::PrimitiveSet::QUADS[ \t]*,[ \t]*"
        r"0[ \t]*,[ \t]*verts->size\(\)[ \t]*\)[ \t]*\)"
        r"[ \t]*;[ \t]*$",
        flags=re.MULTILINE,
    )
    primitive_matches = list(primitive_pattern.finditer(waterutil))

    if len(primitive_matches) != 1:
        raise RuntimeError(
            "Expected exactly one GL_QUADS water primitive; "
            "found {}.".format(len(primitive_matches))
        )

    primitive_match = primitive_matches[0]
    primitive_indent = primitive_match.group("indent")

    triangle_block = (
        primitive_indent
        + triangles_marker
        + "\n"
        + primitive_indent
        + "osg::ref_ptr<osg::DrawElementsUShort> indices(\n"
        + primitive_indent
        + "    new osg::DrawElementsUShort("
        + "osg::PrimitiveSet::TRIANGLES));\n"
        + primitive_indent
        + "indices->reserve((verts->size() / 4) * 6);\n\n"
        + primitive_indent
        + "for (unsigned int i = 0;\n"
        + primitive_indent
        + "     i + 3 < static_cast<unsigned int>(verts->size());\n"
        + primitive_indent
        + "     i += 4)\n"
        + primitive_indent
        + "{\n"
        + primitive_indent
        + "    indices->push_back(static_cast<unsigned short>(i));\n"
        + primitive_indent
        + "    indices->push_back(static_cast<unsigned short>(i + 1));\n"
        + primitive_indent
        + "    indices->push_back(static_cast<unsigned short>(i + 2));\n\n"
        + primitive_indent
        + "    indices->push_back(static_cast<unsigned short>(i));\n"
        + primitive_indent
        + "    indices->push_back(static_cast<unsigned short>(i + 2));\n"
        + primitive_indent
        + "    indices->push_back(static_cast<unsigned short>(i + 3));\n"
        + primitive_indent
        + "}\n\n"
        + primitive_indent
        + "waterGeom->addPrimitiveSet(indices);\n"
        + primitive_indent
        + "waterGeom->setUseDisplayList(false);\n"
        + primitive_indent
        + "waterGeom->setUseVertexBufferObjects(true);"
    )

    waterutil = (
        waterutil[: primitive_match.start()]
        + triangle_block
        + waterutil[primitive_match.end() :]
    )


# =====================================================================
# Final source verification
# =====================================================================

required_water_groups = (
    (
        "TSP_GL4ES_WATER_TRIANGLE_GRID_051_V2",
        "TSP_GL4ES_WATER_TRIANGLE_GRID_051_V1",
    ),
    (
        "TSP_GL4ES_WATER_DEPTH_051_V2",
        "TSP_GL4ES_WATER_DEPTH_051_V1",
    ),
    (
        "TSP_GL4ES_WATER_FIXED_HEIGHT_051_V2",
        "TSP_GL4ES_WATER_FIXED_HEIGHT_051_V1",
    ),
    (
        "TSP_GL4ES_SIMPLE_WATER_FIXED_FOG_051_V2",
        "TSP_GL4ES_SIMPLE_WATER_FIXED_FOG_051_V1",
    ),
    (
        "TSP_GL4ES_SIMPLE_WATER_SHADER_DISABLED_051_V2",
        "TSP_GL4ES_SIMPLE_WATER_SHADER_DISABLED_051_V1",
    ),
)

for alternatives in required_water_groups:
    if not any(token in water for token in alternatives):
        raise RuntimeError(
            "water.cpp is missing one of: " + ", ".join(alternatives)
        )

for token in (
    "Constants::CellSizeInUnits * 16, 64, 96",
    "GL_FOG",
    "GL_LIGHTING",
):
    if token not in water:
        raise RuntimeError("water.cpp is missing: " + token)

required_waterutil_groups = (
    (
        "TSP_GL4ES_WATER_EXPLICIT_TRIANGLES_051_V2",
        "TSP_GL4ES_WATER_EXPLICIT_TRIANGLES_051_V1",
    ),
)

for alternatives in required_waterutil_groups:
    if not any(token in waterutil for token in alternatives):
        raise RuntimeError(
            "waterutil.cpp is missing one of: " + ", ".join(alternatives)
        )

for token in (
    "osg::DrawElementsUShort",
    "osg::PrimitiveSet::TRIANGLES",
    "setUseDisplayList(false)",
    "setUseVertexBufferObjects(true)",
):
    if token not in waterutil:
        raise RuntimeError("waterutil.cpp is missing: " + token)

for forbidden in (
    "mWaterGeom->setDrawCallback(new DepthClampCallback);",
    "mWaterNode->addCullCallback(new FudgeCallback);",
    "sceneManager->setForceShaders(true);",
    "sceneManager->recreateShaders(node);",
    "sceneManager->setForceShaders(oldValue);",
):
    if forbidden in water:
        raise RuntimeError("water.cpp still contains: " + forbidden)

if "osg::PrimitiveSet::QUADS" in waterutil:
    raise RuntimeError(
        "waterutil.cpp still contains a GL_QUADS water primitive."
    )

write_transactionally(
    (
        (water_path, water),
        (waterutil_path, waterutil),
    )
)

print("Patched and verified:")
print(water_path)
print(waterutil_path)
PY_PATCH

cat > "$HELPER_SOURCE" <<'C_HELPER_SOURCE'
#define _GNU_SOURCE

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define DEVICE_NAME "TRIMUI Player1"

#define KEY_TSP_A       305
#define KEY_TSP_B       304
#define KEY_TSP_X       308
#define KEY_TSP_Y       307
#define KEY_TSP_L1      310
#define KEY_TSP_R1      311
#define KEY_TSP_L3      317
#define KEY_TSP_R3      318
#define KEY_TSP_START   314
#define KEY_TSP_SELECT  315
#define KEY_TSP_MENU    316

#define ABS_TSP_LX      0
#define ABS_TSP_LY      1
#define ABS_TSP_L2      2
#define ABS_TSP_RX      3
#define ABS_TSP_RY      4
#define ABS_TSP_R2      5
#define ABS_TSP_DPAD_X  16
#define ABS_TSP_DPAD_Y  17

#define TRIGGER_THRESHOLD 128
#define STICK_DEADZONE 4000
#define STICK_MAX 32760
#define TICK_MS 10
#define EMERGENCY_HOLD_MS 2000
#define CURSOR_SIGNAL_HOLD_MS 120

typedef enum {
    MODE_GAME = 0,
    MODE_HYBRID = 1
} control_mode;

static volatile sig_atomic_t running = 1;
static int controller_fd = -1;
static int uinput_fd = -1;
static FILE *log_file = NULL;
static bool grabbed = false;

static int lx = 0;
static int ly = 0;
static int rx = 0;
static int ry = 0;
static int dpad_x = 0;
static int dpad_y = 0;
static bool l2_down = false;
static bool r2_down = false;
static bool r1_down = false;
static bool start_down = false;
static bool select_down = false;
static bool menu_down = false;
static bool hybrid_chord_latched = false;
static bool emergency_active = false;
static struct timespec emergency_started;

static control_mode mode = MODE_GAME;
static const char text_charset[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz 0123456789!?";
static size_t text_index = 0;

static void handle_signal(int sig)
{
    (void)sig;
    running = 0;
}

static const char *mode_name(control_mode value)
{
    return value == MODE_HYBRID ? "HYBRID" : "GAME";
}

static const char *key_name(unsigned int code)
{
    switch (code) {
        case KEY_TSP_A: return "A";
        case KEY_TSP_B: return "B";
        case KEY_TSP_X: return "X";
        case KEY_TSP_Y: return "Y";
        case KEY_TSP_L1: return "L1";
        case KEY_TSP_R1: return "R1";
        case KEY_TSP_L3: return "L3";
        case KEY_TSP_R3: return "R3";
        case KEY_TSP_START: return "START";
        case KEY_TSP_SELECT: return "SELECT";
        case KEY_TSP_MENU: return "MENU";
        default: return "OTHER";
    }
}

static const char *abs_name(unsigned int code)
{
    switch (code) {
        case ABS_TSP_L2: return "L2";
        case ABS_TSP_R2: return "R2";
        case ABS_TSP_DPAD_X: return "DPAD_X";
        case ABS_TSP_DPAD_Y: return "DPAD_Y";
        default: return "OTHER";
    }
}

static void log_line(const char *message)
{
    if (log_file != NULL) {
        fprintf(log_file, "%s\n", message);
        fflush(log_file);
    }
}

static void log_raw_key(const struct input_event *event)
{
    if (log_file != NULL) {
        fprintf(
            log_file,
            "RAW KEY name=%s code=%u value=%d mode=%d(%s) grabbed=%d\n",
            key_name(event->code), event->code, event->value,
            (int)mode, mode_name(mode), grabbed ? 1 : 0);
        fflush(log_file);
    }
}

static void log_raw_abs(const struct input_event *event)
{
    if (log_file != NULL) {
        fprintf(
            log_file,
            "RAW ABS name=%s code=%u value=%d mode=%d(%s) grabbed=%d\n",
            abs_name(event->code), event->code, event->value,
            (int)mode, mode_name(mode), grabbed ? 1 : 0);
        fflush(log_file);
    }
}

static void emit_event(int type, int code, int value)
{
    struct input_event event;
    memset(&event, 0, sizeof(event));
    gettimeofday(&event.time, NULL);
    event.type = (uint16_t)type;
    event.code = (uint16_t)code;
    event.value = value;

    if (write(uinput_fd, &event, sizeof(event)) < 0 && errno != EAGAIN)
        perror("write uinput event");
}

static void sync_events(void)
{
    emit_event(EV_SYN, SYN_REPORT, 0);
}

static void tap_key(int keycode)
{
    emit_event(EV_KEY, keycode, 1);
    sync_events();
    emit_event(EV_KEY, keycode, 0);
    sync_events();
}

static void tap_key_held(int keycode, int hold_ms)
{
    emit_event(EV_KEY, keycode, 1);
    sync_events();
    usleep((useconds_t)hold_ms * 1000U);
    emit_event(EV_KEY, keycode, 0);
    sync_events();
}

static void set_mouse_button(int button, bool pressed)
{
    emit_event(EV_KEY, button, pressed ? 1 : 0);
    sync_events();
}

static void tap_shifted_key(int keycode)
{
    emit_event(EV_KEY, KEY_LEFTSHIFT, 1);
    emit_event(EV_KEY, keycode, 1);
    sync_events();
    emit_event(EV_KEY, keycode, 0);
    emit_event(EV_KEY, KEY_LEFTSHIFT, 0);
    sync_events();
}

static void type_character(char ch)
{
    if (ch >= 'a' && ch <= 'z') {
        tap_key(KEY_A + (ch - 'a'));
        return;
    }
    if (ch >= 'A' && ch <= 'Z') {
        tap_shifted_key(KEY_A + (ch - 'A'));
        return;
    }
    if (ch >= '1' && ch <= '9') {
        tap_key(KEY_1 + (ch - '1'));
        return;
    }

    switch (ch) {
        case '0': tap_key(KEY_0); break;
        case ' ': tap_key(KEY_SPACE); break;
        case '!': tap_shifted_key(KEY_1); break;
        case '?': tap_shifted_key(KEY_SLASH); break;
        default: break;
    }
}

static int find_controller(void)
{
    char path[64];
    char name[256];

    for (int index = 0; index < 64; index++) {
        snprintf(path, sizeof(path), "/dev/input/event%d", index);
        int fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0)
            continue;

        memset(name, 0, sizeof(name));
        if (ioctl(fd, EVIOCGNAME(sizeof(name)), name) >= 0 &&
            strcmp(name, DEVICE_NAME) == 0) {
            if (log_file != NULL) {
                fprintf(log_file, "Controller: %s | %s\n", path, name);
                fflush(log_file);
            }
            return fd;
        }
        close(fd);
    }
    return -1;
}

static int create_uinput_device(void)
{
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd < 0) {
        perror("open /dev/uinput");
        return -1;
    }

    if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0 ||
        ioctl(fd, UI_SET_EVBIT, EV_REL) < 0 ||
        ioctl(fd, UI_SET_RELBIT, REL_X) < 0 ||
        ioctl(fd, UI_SET_RELBIT, REL_Y) < 0 ||
        ioctl(fd, UI_SET_KEYBIT, BTN_LEFT) < 0 ||
        ioctl(fd, UI_SET_KEYBIT, BTN_RIGHT) < 0) {
        perror("configure uinput");
        close(fd);
        return -1;
    }

    for (int key = KEY_ESC; key <= KEY_MICMUTE; key++)
        ioctl(fd, UI_SET_KEYBIT, key);

    struct uinput_setup setup;
    memset(&setup, 0, sizeof(setup));
    snprintf(setup.name, UINPUT_MAX_NAME_SIZE, "TSP OpenMW 0.51 Hybrid Input");
    setup.id.bustype = BUS_USB;
    setup.id.vendor = 0x1209;
    setup.id.product = 0x0511;
    setup.id.version = 1;

    if (ioctl(fd, UI_DEV_SETUP, &setup) < 0) {
        perror("UI_DEV_SETUP");
        close(fd);
        return -1;
    }
    if (ioctl(fd, UI_DEV_CREATE) < 0) {
        perror("UI_DEV_CREATE");
        close(fd);
        return -1;
    }

    usleep(250000);
    return fd;
}

static void set_grab(bool enable)
{
    if (controller_fd < 0 || grabbed == enable)
        return;

    if (ioctl(controller_fd, EVIOCGRAB, enable ? 1 : 0) < 0) {
        if (log_file != NULL) {
            fprintf(log_file, "EVIOCGRAB(%d) failed: %s\n",
                    enable ? 1 : 0, strerror(errno));
            fflush(log_file);
        }
        return;
    }

    grabbed = enable;
    if (log_file != NULL) {
        fprintf(log_file, "CONTROLLER GRAB changed: grabbed=%d mode=%d(%s)\n",
                grabbed ? 1 : 0, (int)mode, mode_name(mode));
        fflush(log_file);
    }
}

static void reset_virtual_buttons(void)
{
    set_mouse_button(BTN_LEFT, false);
    set_mouse_button(BTN_RIGHT, false);
}

static void signal_cursor_toggle(void)
{
    log_line("Sending KEY_PAUSE to OpenMW cursor patch.");
    tap_key_held(KEY_PAUSE, CURSOR_SIGNAL_HOLD_MS);
}

static void set_mode(control_mode new_mode, bool notify_openmw)
{
    if (new_mode == mode)
        return;

    reset_virtual_buttons();
    mode = new_mode;

    if (mode == MODE_GAME) {
        set_grab(false);
        log_line("MODE=GAME");
    } else {
        set_grab(true);
        log_line("MODE=HYBRID");
        if (log_file != NULL) {
            fprintf(log_file, "TEXT_CHAR=%c INDEX=%zu\n",
                    text_charset[text_index], text_index);
            fflush(log_file);
        }
    }

    if (notify_openmw)
        signal_cursor_toggle();
}

static int scaled_axis(int value, bool slow)
{
    int magnitude = abs(value);
    if (magnitude <= STICK_DEADZONE)
        return 0;

    double normalized =
        (double)(magnitude - STICK_DEADZONE) /
        (double)(STICK_MAX - STICK_DEADZONE);
    if (normalized > 1.0)
        normalized = 1.0;

    double speed = normalized * normalized * 18.0;
    if (slow)
        speed *= 0.30;

    int result = (int)lrint(speed);
    if (result < 1)
        result = 1;
    return value < 0 ? -result : result;
}

static int stronger_axis(int first, int second)
{
    return abs(first) >= abs(second) ? first : second;
}

static void update_mouse(void)
{
    if (mode != MODE_HYBRID)
        return;

    int x_axis = stronger_axis(lx, rx);
    int y_axis = stronger_axis(ly, ry);
    int dx = scaled_axis(x_axis, r1_down);
    int dy = scaled_axis(y_axis, r1_down);

    if (dx != 0 || dy != 0) {
        emit_event(EV_REL, REL_X, dx);
        emit_event(EV_REL, REL_Y, dy);
        sync_events();
    }
}

static void change_text_index(int direction)
{
    size_t length = strlen(text_charset);
    if (direction > 0)
        text_index = (text_index + 1) % length;
    else
        text_index = (text_index + length - 1) % length;

    if (log_file != NULL) {
        fprintf(log_file, "TEXT_CHAR=%c INDEX=%zu\n",
                text_charset[text_index], text_index);
        fflush(log_file);
    }
}

static void toggle_text_case(void)
{
    char current = text_charset[text_index];
    if (current >= 'A' && current <= 'Z') {
        char target = (char)(current - 'A' + 'a');
        const char *position = strchr(text_charset, target);
        if (position != NULL)
            text_index = (size_t)(position - text_charset);
    } else if (current >= 'a' && current <= 'z') {
        char target = (char)(current - 'a' + 'A');
        const char *position = strchr(text_charset, target);
        if (position != NULL)
            text_index = (size_t)(position - text_charset);
    }

    if (log_file != NULL) {
        fprintf(log_file, "TEXT_CHAR=%c INDEX=%zu\n",
                text_charset[text_index], text_index);
        fflush(log_file);
    }
}

static long elapsed_ms(const struct timespec *start, const struct timespec *end)
{
    long sec = (long)(end->tv_sec - start->tv_sec);
    long nsec = end->tv_nsec - start->tv_nsec;
    return sec * 1000L + nsec / 1000000L;
}

static bool looks_like_openmw_cmdline(const char *buffer, ssize_t length)
{
    if (length <= 0)
        return false;

    char copy[4096];
    size_t usable = (size_t)length;
    if (usable >= sizeof(copy))
        usable = sizeof(copy) - 1;
    memcpy(copy, buffer, usable);
    copy[usable] = '\0';

    for (size_t i = 0; i < usable; i++) {
        if (copy[i] == '\0')
            copy[i] = ' ';
    }

    return strstr(copy, "openmw-0.51") != NULL;
}

static int terminate_openmw_processes(void)
{
    DIR *dir = opendir("/proc");
    if (dir == NULL) {
        log_line("EMERGENCY KILL: could not open /proc.");
        return 0;
    }

    pid_t self = getpid();
    pid_t victims[32];
    size_t victim_count = 0;
    struct dirent *entry;

    while ((entry = readdir(dir)) != NULL && victim_count < 32) {
        if (!isdigit((unsigned char)entry->d_name[0]))
            continue;

        char *endptr = NULL;
        long value = strtol(entry->d_name, &endptr, 10);
        if (endptr == entry->d_name || *endptr != '\0' || value <= 1)
            continue;

        pid_t pid = (pid_t)value;
        if (pid == self)
            continue;

        char path[128];
        snprintf(path, sizeof(path), "/proc/%ld/cmdline", value);
        int fd = open(path, O_RDONLY | O_CLOEXEC);
        if (fd < 0)
            continue;

        char buffer[4096];
        ssize_t count = read(fd, buffer, sizeof(buffer));
        close(fd);

        if (looks_like_openmw_cmdline(buffer, count))
            victims[victim_count++] = pid;
    }
    closedir(dir);

    if (victim_count == 0) {
        log_line("EMERGENCY KILL: no openmw-0.51 process was found.");
        return 0;
    }

    for (size_t i = 0; i < victim_count; i++) {
        if (log_file != NULL) {
            fprintf(log_file, "EMERGENCY KILL: SIGTERM pid=%ld\n",
                    (long)victims[i]);
            fflush(log_file);
        }
        kill(victims[i], SIGTERM);
    }

    usleep(750000);

    for (size_t i = 0; i < victim_count; i++) {
        if (kill(victims[i], 0) == 0) {
            if (log_file != NULL) {
                fprintf(log_file, "EMERGENCY KILL: SIGKILL pid=%ld\n",
                        (long)victims[i]);
                fflush(log_file);
            }
            kill(victims[i], SIGKILL);
        }
    }

    return (int)victim_count;
}

static void update_emergency_kill(void)
{
    if (start_down && select_down) {
        if (!emergency_active) {
            clock_gettime(CLOCK_MONOTONIC, &emergency_started);
            emergency_active = true;
            log_line("EMERGENCY KILL chord armed: hold START+SELECT for 2 seconds.");
            return;
        }

        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (elapsed_ms(&emergency_started, &now) >= EMERGENCY_HOLD_MS) {
            log_line("EMERGENCY KILL chord fired.");
            terminate_openmw_processes();
            running = 0;
        }
    } else if (emergency_active) {
        emergency_active = false;
        log_line("EMERGENCY KILL chord cancelled.");
    }
}

static void handle_key_event(const struct input_event *event)
{
    bool pressed = event->value != 0;
    log_raw_key(event);

    if (event->code == KEY_TSP_START)
        start_down = pressed;
    else if (event->code == KEY_TSP_SELECT)
        select_down = pressed;
    else if (event->code == KEY_TSP_MENU)
        menu_down = pressed;
    else if (event->code == KEY_TSP_R1)
        r1_down = pressed;

    if (menu_down && start_down && !hybrid_chord_latched) {
        hybrid_chord_latched = true;
        log_line("MENU+START chord: toggling GAME/HYBRID mode.");
        set_mode(mode == MODE_GAME ? MODE_HYBRID : MODE_GAME, true);
        return;
    }

    if (!menu_down || !start_down)
        hybrid_chord_latched = false;

    if (event->code == KEY_TSP_START || event->code == KEY_TSP_SELECT) {
        update_emergency_kill();
        if (!running)
            return;
    }

    if (mode == MODE_GAME)
        return;

    if (event->code == KEY_TSP_R1)
        return;

    if (event->code == KEY_TSP_START && pressed) {
        tap_key(KEY_ENTER);
        return;
    }

    if (!pressed)
        return;

    switch (event->code) {
        case KEY_TSP_A:
            type_character(text_charset[text_index]);
            break;
        case KEY_TSP_B:
            tap_key(KEY_BACKSPACE);
            break;
        case KEY_TSP_X:
            tap_key(KEY_ESC);
            break;
        case KEY_TSP_Y:
            toggle_text_case();
            break;
        case KEY_TSP_L1:
            set_mouse_button(BTN_LEFT, true);
            set_mouse_button(BTN_LEFT, false);
            break;
        default:
            break;
    }

}

static void handle_abs_event(const struct input_event *event)
{
    if (event->code == ABS_TSP_L2 || event->code == ABS_TSP_R2 ||
        event->code == ABS_TSP_DPAD_X || event->code == ABS_TSP_DPAD_Y)
        log_raw_abs(event);

    switch (event->code) {
        case ABS_TSP_LX:
            lx = event->value;
            break;
        case ABS_TSP_LY:
            ly = event->value;
            break;
        case ABS_TSP_RX:
            rx = event->value;
            break;
        case ABS_TSP_RY:
            ry = event->value;
            break;
        case ABS_TSP_DPAD_X: {
            int old_value = dpad_x;
            dpad_x = event->value;
            if (mode == MODE_HYBRID && old_value == 0) {
                if (dpad_x > 0)
                    type_character(text_charset[text_index]);
                else if (dpad_x < 0)
                    tap_key(KEY_BACKSPACE);
            }
            break;
        }
        case ABS_TSP_DPAD_Y: {
            int old_value = dpad_y;
            dpad_y = event->value;
            if (mode == MODE_HYBRID && old_value == 0) {
                if (dpad_y > 0)
                    change_text_index(1);
                else if (dpad_y < 0)
                    change_text_index(-1);
            }
            break;
        }
        case ABS_TSP_L2: {
            bool new_down = event->value >= TRIGGER_THRESHOLD;
            if (mode == MODE_HYBRID && new_down != l2_down)
                set_mouse_button(BTN_RIGHT, new_down);
            l2_down = new_down;
            break;
        }
        case ABS_TSP_R2: {
            bool new_down = event->value >= TRIGGER_THRESHOLD;
            if (mode == MODE_HYBRID && new_down != r2_down)
                set_mouse_button(BTN_LEFT, new_down);
            r2_down = new_down;
            break;
        }
        default:
            break;
    }
}

int main(int argc, char **argv)
{
    const char *log_path =
        argc > 1 ? argv[1] : "/tmp/tsp_openmw_controls_051.log";

    log_file = fopen(log_path, "w");
    if (log_file == NULL)
        perror("open log");

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);
    signal(SIGHUP, handle_signal);

    controller_fd = find_controller();
    if (controller_fd < 0) {
        log_line("ERROR: TRIMUI Player1 was not found.");
        return 1;
    }

    uinput_fd = create_uinput_device();
    if (uinput_fd < 0) {
        log_line("ERROR: Could not create virtual mouse/keyboard.");
        close(controller_fd);
        return 1;
    }

    log_line("TSP OpenMW 0.51 hybrid control helper v1 started.");
    log_line("GAME mode: physical controller passes through to OpenMW native input.");
    log_line("MENU+START: toggle HYBRID mouse/text mode and MyGUI cursor state.");
    log_line("HYBRID sticks: mouse; R1: slow mouse; R2/L2: left/right click.");
    log_line("HYBRID D-pad Up/Down: character; Right: type; Left: backspace.");
    log_line("HYBRID A/D-pad Right: type; B/D-pad Left: backspace; Y: case.");
    log_line("HYBRID X: Escape; Start: Enter; L1/R2: left click; L2: right click.");
    log_line("START+SELECT held 2 seconds: emergency terminate openmw-0.51.");
    set_mode(MODE_GAME, false);

    struct pollfd poll_fd;
    poll_fd.fd = controller_fd;
    poll_fd.events = POLLIN;
    poll_fd.revents = 0;

    while (running) {
        int result = poll(&poll_fd, 1, TICK_MS);
        if (result > 0 && (poll_fd.revents & POLLIN)) {
            struct input_event events[32];
            ssize_t count = read(controller_fd, events, sizeof(events));
            if (count > 0) {
                size_t event_count = (size_t)count / sizeof(struct input_event);
                for (size_t index = 0; index < event_count; index++) {
                    if (events[index].type == EV_KEY)
                        handle_key_event(&events[index]);
                    else if (events[index].type == EV_ABS)
                        handle_abs_event(&events[index]);
                }
            }
        } else if (result < 0 && errno != EINTR) {
            if (log_file != NULL) {
                fprintf(log_file, "poll failed: %s\n", strerror(errno));
                fflush(log_file);
            }
            break;
        }

        update_emergency_kill();
        update_mouse();
    }

    reset_virtual_buttons();
    set_grab(false);

    if (uinput_fd >= 0) {
        ioctl(uinput_fd, UI_DEV_DESTROY);
        close(uinput_fd);
    }
    if (controller_fd >= 0)
        close(controller_fd);

    log_line("TSP OpenMW 0.51 hybrid control helper v1 stopped.");
    if (log_file != NULL)
        fclose(log_file);
    return 0;
}
C_HELPER_SOURCE

trap - ERR

echo
echo "Input patch markers:"
grep -n "TSP_MYGUI_CURSOR_051_HYBRID_V1" "$CPP" "$HPP"
echo
echo "Renderer patch markers:"
grep -n -E "TSP_GL4ES_WATER_TRIANGLE_GRID_051_V[12]" "$WATER_CPP"
grep -n -E "TSP_GL4ES_WATER_DEPTH_051_V[12]" "$WATER_CPP"
grep -n -E "TSP_GL4ES_WATER_FIXED_HEIGHT_051_V[12]" "$WATER_CPP"
grep -n -E "TSP_GL4ES_SIMPLE_WATER_FIXED_FOG_051_V[12]" "$WATER_CPP"
grep -n -E "TSP_GL4ES_SIMPLE_WATER_SHADER_DISABLED_051_V[12]" "$WATER_CPP"
grep -n -E "TSP_GL4ES_WATER_EXPLICIT_TRIANGLES_051_V[12]" "$WATERUTIL_CPP"
echo "Generated helper source: $HELPER_SOURCE"

if [ "$PATCH_ONLY" = "1" ]; then
    echo "============================================================"
    echo "PATCH-ONLY MODE COMPLETED"
    echo "============================================================"
    echo "OpenMW input + renderer source was patched and helper source was generated."
    echo "No binaries were built."
    exit 0
fi

HELPER_CC=""
if command -v gcc-13 >/dev/null 2>&1; then
    HELPER_CC="$(command -v gcc-13)"
elif command -v gcc >/dev/null 2>&1; then
    HELPER_CC="$(command -v gcc)"
elif command -v cc >/dev/null 2>&1; then
    HELPER_CC="$(command -v cc)"
else
    echo "ERROR: No C compiler was found for the controller helper."
    exit 1
fi

echo
echo "Building TSP hybrid controller helper with: $HELPER_CC"
"$HELPER_CC" -O2 -std=gnu11 -Wall -Wextra "$HELPER_SOURCE" -lm -o "$HELPER_OUTPUT"
chmod +x "$HELPER_OUTPUT"

echo
echo "Incrementally rebuilding OpenMW 0.51..."
cmake --build "$BUILD_DIR" --target openmw --parallel "$JOBS"

if [ ! -x "$BUILT_BINARY" ]; then
    echo "ERROR: Build completed, but the OpenMW executable was not found:"
    echo "  $BUILT_BINARY"
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT_BINARY")" "$(dirname "$PACKAGE_BINARY")" "$(dirname "$PACKAGE_HELPER")"
[ ! -e "$OUTPUT_BINARY" ] || cp -f "$OUTPUT_BINARY" "$OUTPUT_BINARY.before-$STAMP"
[ ! -e "$PACKAGE_BINARY" ] || cp -f "$PACKAGE_BINARY" "$PACKAGE_BINARY.before-input-graphics-v2-$STAMP"
[ ! -e "$PACKAGE_HELPER" ] || cp -f "$PACKAGE_HELPER" "$PACKAGE_HELPER.before-$STAMP"

cp -f "$BUILT_BINARY" "$OUTPUT_BINARY"
cp -f "$BUILT_BINARY" "$PACKAGE_BINARY"
cp -f "$HELPER_OUTPUT" "$PACKAGE_HELPER"
chmod +x "$OUTPUT_BINARY" "$PACKAGE_BINARY" "$PACKAGE_HELPER"

if [ "$NO_STRIP" != "1" ]; then
    STRIP_TOOL=""
    if command -v aarch64-linux-gnu-strip >/dev/null 2>&1; then
        STRIP_TOOL="$(command -v aarch64-linux-gnu-strip)"
    elif command -v strip >/dev/null 2>&1; then
        STRIP_TOOL="$(command -v strip)"
    fi
    if [ -n "$STRIP_TOOL" ]; then
        "$STRIP_TOOL" --strip-unneeded "$OUTPUT_BINARY" || true
        "$STRIP_TOOL" --strip-unneeded "$PACKAGE_BINARY" || true
        "$STRIP_TOOL" --strip-unneeded "$HELPER_OUTPUT" || true
        "$STRIP_TOOL" --strip-unneeded "$PACKAGE_HELPER" || true
    fi
fi

echo
echo "Verifying deployment binaries..."
file "$BUILT_BINARY"
file "$OUTPUT_BINARY"
file "$HELPER_OUTPUT"
"$BUILT_BINARY" --version || true

echo
echo "============================================================"
echo "OpenMW 0.51 INPUT + GRAPHICS rebuild completed"
echo "============================================================"
echo "OpenMW test binary: $OUTPUT_BINARY"
echo "Helper binary:      $HELPER_OUTPUT"
echo "Packaged OpenMW:    $PACKAGE_BINARY"
echo "Packaged helper:    $PACKAGE_HELPER"
echo "Source backups:     $BACKUP_DIR"
echo
echo "Included renderer changes:"
echo "  - smaller 64x64 explicit-triangle water grid"
echo "  - GL_DEPTH_CLAMP disabled"
echo "  - fixed-height water"
echo "  - fixed-function simple-water fog"
echo
echo "IMPORTANT: the launcher still needs to start tsp_openmw_controls_051_v1"
echo "alongside OpenMW for MENU+START hybrid mode and START+SELECT emergency kill."
echo "============================================================"
