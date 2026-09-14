#!/bin/bash
set -Eeuo pipefail

# OpenMW 0.51.0 TrimUI Smart Pro automatic text-entry + renderer compatibility rebuild.
#
# V5 keeps the successful V4 renderer/water patch unchanged, but removes the
# manual MENU-toggle mouse/hybrid mode. Native OpenMW 0.51 controller input is
# left alone everywhere except while OpenMW itself reports an active SDL text
# input session.
#
# Automatic text-entry behavior:
#   - OpenMW creates /tmp/openmw-tsp-text-active while SDL text input is active.
#   - The helper grabs TRIMUI Player1 only while that flag exists.
#   - As soon as text entry closes, the helper releases the controller and
#     native OpenMW 0.51 controller behavior resumes automatically.
#   - OpenMW displays the currently selected character near the bottom center.
#
# Text controls while an actual text-entry field is active:
#   - D-pad Up:    previous selectable character.
#   - D-pad Down:  next selectable character.
#   - D-pad Left:  move backward through already typed text.
#   - D-pad Right: move forward through already typed text.
#   - A:           type the currently selected character.
#   - B:           delete/backspace.
#   - X:           toggle Letters <-> Numbers/Alt/Space.
#   - Y:           toggle uppercase/lowercase; from Alt mode return to Letters.
#   - Start:       Enter / finish text.
#   - Menu:        leave/cancel text mode (Escape).
#
# Physical Start/Select mapping remains corrected for the TSP:
#   - Start  = evdev code 315
#   - Select = evdev code 314
#   - Menu   = evdev code 316
#
# There is intentionally no custom mouse mode. Native OpenMW 0.51 keeps full
# control of gamepad-driven GUI mouse movement. Because the TSP/GL4ES path does
# not visibly render SDL's hardware cursor, this patch mirrors OpenMW's own
# getCursorVisible() state to MyGUI's in-engine pointer instead.
#
# Renderer changes are the already-successful V4 graphics changes:
#   - smaller 64x64 water grid
#   - explicit GLES2-friendly triangles instead of GL_QUADS
#   - GL_DEPTH_CLAMP disabled
#   - camera-relative water-height callback disabled
#   - simple water forced to fixed-function fog instead of generated shader
#
# The still-under-investigation general GLSL resource issues remain separate.

SOURCE_DIR="${1:-/root/openmw-0.51-tsp-src}"
BUILD_DIR="${2:-/root/openmw-0.51-tsp-build}"
PACKAGE_DIR="${3:-/root/openmw-0.51-tsp-package}"
OUTPUT_BINARY="${4:-/root/openmw-0.51-tsp-input-graphics-v6}"
HELPER_OUTPUT="${5:-/root/tsp_openmw_controls}"
JOBS="${OPENMW_JOBS:-$(nproc)}"
PATCH_ONLY="${OPENMW_PATCH_ONLY:-0}"
NO_STRIP="${OPENMW_NO_STRIP:-0}"

CPP="$SOURCE_DIR/apps/openmw/mwinput/inputmanagerimp.cpp"
HPP="$SOURCE_DIR/apps/openmw/mwinput/inputmanagerimp.hpp"
WATER_CPP="$SOURCE_DIR/apps/openmw/mwrender/water.cpp"
WATERUTIL_CPP="$SOURCE_DIR/components/sceneutil/waterutil.cpp"
RENDERINGMANAGER_CPP="$SOURCE_DIR/apps/openmw/mwrender/renderingmanager.cpp"
CMAKE_FILE="$SOURCE_DIR/CMakeLists.txt"
BUILT_BINARY="$BUILD_DIR/openmw"
PACKAGE_BINARY="$PACKAGE_DIR/bin/openmw-0.51"
PACKAGE_HELPER="$PACKAGE_DIR/tsp_openmw_controls"
HELPER_SOURCE="${OPENMW_HELPER_SOURCE_OUT:-/root/tsp_openmw_controls.c}"
SCRIPT_REVISION="TSP-051-AUTO-TEXT-GRAPHICS-CURSOR-V6-AUDITED-2026-08-07"
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
        [ -f "$BACKUP_DIR/apps/openmw/mwrender/renderingmanager.cpp" ] && \
            cp -f "$BACKUP_DIR/apps/openmw/mwrender/renderingmanager.cpp" "$RENDERINGMANAGER_CPP"
        [ -f "$BACKUP_DIR/components/sceneutil/waterutil.cpp" ] && \
            cp -f "$BACKUP_DIR/components/sceneutil/waterutil.cpp" "$WATERUTIL_CPP"
        echo "Input/renderer source restoration completed."
        echo "Backups remain at: $BACKUP_DIR"
    fi
    exit "$result"
}
trap restore_on_patch_error ERR

echo "============================================================"
echo "OpenMW 0.51 TSP automatic text-entry + graphics rebuild"
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

for required in "$CPP" "$HPP" "$WATER_CPP" "$WATERUTIL_CPP" "$RENDERINGMANAGER_CPP" "$CMAKE_FILE"; do
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

echo "Python runtime: $(python3 --version 2>&1)"

# Preflight the exact Python file-writing API used by every embedded patcher.
# This catches Python-version incompatibilities before any OpenMW source file is touched.
python3 - <<'PY_PREFLIGHT'
from pathlib import Path
import os
import tempfile

fd, name = tempfile.mkstemp(prefix="tsp-v6-preflight-", suffix=".txt")
os.close(fd)
path = Path(name)
try:
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write("ok\n")
    if path.read_text(encoding="utf-8") != "ok\n":
        raise RuntimeError("Python transactional-write preflight produced unexpected content")
finally:
    try:
        path.unlink()
    except FileNotFoundError:
        pass
print("Python file-write preflight: OK")
PY_PREFLIGHT

echo
mkdir -p "$BACKUP_DIR/apps/openmw/mwinput"
mkdir -p "$BACKUP_DIR/apps/openmw/mwrender"
mkdir -p "$BACKUP_DIR/components/sceneutil"
cp -f "$CPP" "$BACKUP_DIR/apps/openmw/mwinput/inputmanagerimp.cpp"
cp -f "$HPP" "$BACKUP_DIR/apps/openmw/mwinput/inputmanagerimp.hpp"
cp -f "$WATER_CPP" "$BACKUP_DIR/apps/openmw/mwrender/water.cpp"
cp -f "$RENDERINGMANAGER_CPP" "$BACKUP_DIR/apps/openmw/mwrender/renderingmanager.cpp"
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


marker = "TSP_AUTO_TEXT_ENTRY_051_V5"

# Remove markers and state members from the older cursor/hybrid experiments.
cpp = re.sub(
    r"^[ \t]*//[ \t]*TSP_MYGUI_CURSOR[^\n]*\n",
    "",
    cpp,
    flags=re.MULTILINE,
)
cpp = re.sub(
    r"^[ \t]*//[ \t]*TSP_AUTO_TEXT_ENTRY[^\n]*\n",
    "",
    cpp,
    flags=re.MULTILINE,
)

# V5 does not use the old MyGUI pointer code.
cpp = cpp.replace("#include <MyGUI_PointerManager.h>\n", "")

required_includes = (
    "#include <algorithm>\n",
    "#include <string>\n",
    "#include <MyGUI_Gui.h>\n",
    "#include <MyGUI_PointerManager.h>\n",
    "#include <MyGUI_RenderManager.h>\n",
    "#include <MyGUI_TextBox.h>\n",
    "#include <cstdio>\n",
    "#include <cstring>\n",
)

include_matches = list(re.finditer(r"^#include[^\n]*\n", cpp, flags=re.MULTILINE))
if not include_matches:
    raise RuntimeError("Could not find a C++ include insertion point.")
insertion = include_matches[-1].end()
for include in required_includes:
    if include not in cpp:
        cpp = cpp[:insertion] + include + cpp[insertion:]
        insertion += len(include)

new_update = r'''    // TSP_AUTO_TEXT_ENTRY_051_V5
    void InputManager::update(float dt, bool disableControls, bool disableEvents)
    {
        mControlsDisabled = disableControls;

        MWBase::WindowManager* windowManager
            = MWBase::Environment::get().getWindowManager();

        // Stock OpenMW 0.51 already knows exactly when a GUI cursor should be
        // visible, including controller-driven mouse menus such as Settings.
        // SDL's hardware cursor moves but is invisible through this TSP/GL4ES
        // display path, so keep the SDL cursor hidden and mirror OpenMW's own
        // cursor-visible state to MyGUI's in-engine pointer.
        mInputWrapper->setMouseVisible(false);

        mInputWrapper->capture(disableEvents);

        // SDL text-input state is controlled by OpenMW/MyGUI when an EditBox
        // actually owns text focus. This gives the helper an automatic,
        // context-sensitive trigger instead of stealing game/menu controls.
        const bool tspTextEntryActive = SDL_IsTextInputActive() == SDL_TRUE;

        static bool tspPreviousTextEntryActive = false;
        static MyGUI::TextBox* tspTextIndicator = nullptr;
        static std::string tspLastIndicatorCaption;

        if (tspTextEntryActive != tspPreviousTextEntryActive)
        {
            if (tspTextEntryActive)
            {
                if (std::FILE* flag = std::fopen(
                        "/tmp/openmw-tsp-text-active", "w"))
                {
                    std::fputs("1\n", flag);
                    std::fclose(flag);
                }
            }
            else
            {
                std::remove("/tmp/openmw-tsp-text-active");
                std::remove("/tmp/openmw-tsp-text-char");

                if (tspTextIndicator != nullptr)
                {
                    MyGUI::Gui::getInstance().destroyWidget(tspTextIndicator);
                    tspTextIndicator = nullptr;
                    tspLastIndicatorCaption.clear();
                }
            }

            tspPreviousTextEntryActive = tspTextEntryActive;
        }

        if (tspTextEntryActive)
        {
            if (tspTextIndicator == nullptr)
            {
                const MyGUI::IntSize viewSize
                    = MyGUI::RenderManager::getInstance().getViewSize();

                const int indicatorWidth = 260;
                const int indicatorHeight = 48;
                const int indicatorX
                    = std::max(0, (viewSize.width - indicatorWidth) / 2);
                const int indicatorY
                    = std::max(0, viewSize.height - indicatorHeight - 46);

                tspTextIndicator
                    = MyGUI::Gui::getInstance().createWidget<MyGUI::TextBox>(
                        "ProgressText",
                        MyGUI::IntCoord(
                            indicatorX,
                            indicatorY,
                            indicatorWidth,
                            indicatorHeight),
                        MyGUI::Align::Default,
                        "Popup");

                tspTextIndicator->setTextAlign(MyGUI::Align::Center);
                tspTextIndicator->setFontHeight(28);
                tspTextIndicator->setCaption("[ A ]");
                tspLastIndicatorCaption = "[ A ]";
            }

            char captionBuffer[128] = {};
            if (std::FILE* captionFile
                = std::fopen("/tmp/openmw-tsp-text-char", "r"))
            {
                if (std::fgets(
                        captionBuffer,
                        static_cast<int>(sizeof(captionBuffer)),
                        captionFile)
                    != nullptr)
                {
                    const std::size_t length = std::strlen(captionBuffer);
                    if (length > 0 && captionBuffer[length - 1] == '\n')
                        captionBuffer[length - 1] = '\0';
                }
                std::fclose(captionFile);
            }

            if (captionBuffer[0] != '\0')
            {
                const std::string caption(captionBuffer);
                if (caption != tspLastIndicatorCaption)
                {
                    tspTextIndicator->setCaption(caption);
                    tspLastIndicatorCaption = caption;
                }
            }
        }

        if (disableControls)
        {
            mMouseManager->updateCursorMode();
            mInputWrapper->setMouseVisible(false);
            MyGUI::PointerManager::getInstance().setVisible(windowManager->getCursorVisible());
            return;
        }

        // Preserve the stock OpenMW 0.51 input update sequence.
        mBindingsManager->update(dt);
        mMouseManager->updateCursorMode();
        mControllerManager->update(dt);
        mMouseManager->update(dt);
        mSensorManager->update(dt);
        mActionManager->update(dt);

        // updateCursorMode can request SDL cursor visibility. Override it after
        // the stock 0.51 input update and render the same state with MyGUI.
        mInputWrapper->setMouseVisible(false);
        MyGUI::PointerManager::getInstance().setVisible(windowManager->getCursorVisible());

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

# Strip every state member inserted by the old 0.48/0.51 cursor experiments.
hpp = re.sub(
    r"^[ \t]*//[ \t]*TSP_MYGUI_CURSOR[^\n]*\n",
    "",
    hpp,
    flags=re.MULTILINE,
)
hpp = re.sub(
    r"^[ \t]*//[ \t]*TSP_AUTO_TEXT_ENTRY[^\n]*\n",
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
        r"^[ \t]*bool[ \t]+" + re.escape(member_name)
        + r"[ \t]*=[ \t]*false;[ \t]*\n",
        "",
        hpp,
        flags=re.MULTILINE,
    )

for token in (
    marker,
    "SDL_IsTextInputActive()",
    "/tmp/openmw-tsp-text-active",
    "/tmp/openmw-tsp-text-char",
    "MyGUI::TextBox",
    "ProgressText",
    "MyGUI::PointerManager::getInstance().setVisible",
    "windowManager->getCursorVisible()",
    "mInputWrapper->setMouseVisible(false)",
    "mControllerManager->update(dt);",
    "mActionManager->update(dt);",
    "Settings::input().mEnableGyroscope",
):
    if token not in cpp:
        raise RuntimeError("inputmanagerimp.cpp is missing: " + token)

for forbidden in (
    "mTspCursorVisible",
    "mTspCursorChordWasPressed",
    "SDL_SCANCODE_PAUSE",
):
    if forbidden in cpp or forbidden in hpp:
        raise RuntimeError(
            "V5 automatic text patch still contains old cursor state: "
            + forbidden
        )

write_transactionally(((cpp_path, cpp), (hpp_path, hpp)))
print("Patched and verified:")
print(cpp_path)
print(hpp_path)
PY_INPUT_PATCH

echo
echo "Applying TSP GL4ES normals-render-target compatibility patch..."
python3 - "$RENDERINGMANAGER_CPP" <<'PY_NORMALS_RT'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
marker = "// TSP_GL4ES_DISABLE_NORMALS_RT_051_V6"

if marker not in text:
    pattern = re.compile(
        r"^(?P<indent>[ \t]*)resourceSystem->getSceneManager\(\)->setSupportsNormalsRT\(\s*"
        r"mPostProcessor->getSupportsNormalsRT\(\)\s*\);[ \t]*$",
        flags=re.MULTILINE,
    )
    matches = list(pattern.finditer(text))
    if len(matches) != 1:
        raise RuntimeError(
            "Expected exactly one SceneManager normals-RT capability assignment; found {}.".format(len(matches))
        )
    m = matches[0]
    indent = m.group("indent")
    replacement = (
        indent + marker + "\n"
        + indent + "// GL4ES/OpenGL 2.1 on the TSP does not expose glColorMaski.\n"
        + indent + "// The normals MRT path requires indexed color masks on attachment 1,\n"
        + indent + "// so force the optional normals render target off for this build.\n"
        + indent + "resourceSystem->getSceneManager()->setSupportsNormalsRT(false);"
    )
    text = text[:m.start()] + replacement + text[m.end():]

if "setSupportsNormalsRT(mPostProcessor->getSupportsNormalsRT())" in text:
    raise RuntimeError("Stock normals-RT capability assignment remains after patch.")
if marker not in text or "setSupportsNormalsRT(false);" not in text:
    raise RuntimeError("Normals-RT compatibility patch verification failed.")

with path.open("w", encoding="utf-8", newline="\n") as handle:
    handle.write(text)
print("Patched and verified:")
print(path)
PY_NORMALS_RT

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
    # OpenMW 0.51 wraps verts->size() in static_cast<...>(), while the
    # older 0.48 source used verts->size() directly. Accept either form.
    primitive_pattern = re.compile(
        r"^(?P<indent>[ \t]*)waterGeom->addPrimitiveSet[ \t]*\("
        r"[ \t\r\n]*new[ \t]+osg::DrawArrays[ \t]*\("
        r"[ \t]*osg::PrimitiveSet::QUADS[ \t]*,[ \t]*"
        r"0[ \t]*,[ \t]*"
        r"(?:verts->size\(\)|"
        r"static_cast[ \t]*<[^>\n]+>[ \t]*\([ \t]*verts->size\(\)[ \t]*\))"
        r"[ \t]*\)[ \t]*\)[ \t]*;[ \t]*$",
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

#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/time.h>
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

/* Corrected physical button identities on this TrimUI Smart Pro S. */
#define KEY_TSP_START   315
#define KEY_TSP_SELECT  314
#define KEY_TSP_MENU    316

#define ABS_TSP_DPAD_X  16
#define ABS_TSP_DPAD_Y  17

#define TICK_MS 10

#define TEXT_ACTIVE_FLAG "/tmp/openmw-tsp-text-active"
#define TEXT_CHAR_FILE   "/tmp/openmw-tsp-text-char"
#define TEXT_CHAR_TMP    "/tmp/openmw-tsp-text-char.tmp"

typedef enum {
    MODE_GAME = 0,
    MODE_TEXT = 1
} control_mode;

typedef enum {
    CHARSET_LETTERS = 0,
    CHARSET_ALT = 1
} charset_mode;

static volatile sig_atomic_t running = 1;
static int controller_fd = -1;
static int uinput_fd = -1;
static FILE *log_file = NULL;
static bool grabbed = false;
static bool suppress_auto_text = false;

static int dpad_x = 0;
static int dpad_y = 0;

static control_mode mode = MODE_GAME;
static charset_mode charset = CHARSET_LETTERS;
static bool uppercase = true;
static size_t text_index = 0;

/* X toggles to this compact numbers / punctuation / space bank. */
static const char letters[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
static const char alt_chars[] = " 0123456789!?.,'-_/():;@#$%&+";

static void handle_signal(int sig)
{
    (void)sig;
    running = 0;
}

static const char *mode_name(control_mode value)
{
    return value == MODE_TEXT ? "TEXT" : "GAME";
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
            key_name(event->code),
            event->code,
            event->value,
            (int)mode,
            mode_name(mode),
            grabbed ? 1 : 0);
        fflush(log_file);
    }
}

static void log_raw_abs(const struct input_event *event)
{
    if (log_file != NULL) {
        fprintf(
            log_file,
            "RAW ABS name=%s code=%u value=%d mode=%d(%s) grabbed=%d\n",
            abs_name(event->code),
            event->code,
            event->value,
            (int)mode,
            mode_name(mode),
            grabbed ? 1 : 0);
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

static void tap_shifted_key(int keycode)
{
    emit_event(EV_KEY, KEY_LEFTSHIFT, 1);
    emit_event(EV_KEY, keycode, 1);
    sync_events();
    emit_event(EV_KEY, keycode, 0);
    emit_event(EV_KEY, KEY_LEFTSHIFT, 0);
    sync_events();
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

    if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0) {
        perror("configure uinput");
        close(fd);
        return -1;
    }

    for (int key = KEY_ESC; key <= KEY_MICMUTE; key++)
        ioctl(fd, UI_SET_KEYBIT, key);

    struct uinput_setup setup;
    memset(&setup, 0, sizeof(setup));
    snprintf(
        setup.name,
        UINPUT_MAX_NAME_SIZE,
        "TSP OpenMW 0.51 Automatic Text Input");
    setup.id.bustype = BUS_USB;
    setup.id.vendor = 0x1209;
    setup.id.product = 0x0512;
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
            fprintf(
                log_file,
                "EVIOCGRAB(%d) failed: %s\n",
                enable ? 1 : 0,
                strerror(errno));
            fflush(log_file);
        }
        return;
    }

    grabbed = enable;

    if (log_file != NULL) {
        fprintf(
            log_file,
            "CONTROLLER GRAB changed: grabbed=%d mode=%d(%s)\n",
            grabbed ? 1 : 0,
            (int)mode,
            mode_name(mode));
        fflush(log_file);
    }
}

static char selected_character(void)
{
    if (charset == CHARSET_ALT)
        return alt_chars[text_index % (sizeof(alt_chars) - 1)];

    char value = letters[text_index % (sizeof(letters) - 1)];
    if (!uppercase)
        value = (char)(value - 'A' + 'a');
    return value;
}

static const char *charset_name(void)
{
    return charset == CHARSET_ALT ? "ALT" : (uppercase ? "ABC" : "abc");
}

static void publish_selected_character(void)
{
    char value = selected_character();

    FILE *file = fopen(TEXT_CHAR_TMP, "w");
    if (file != NULL) {
        if (value == ' ')
            fprintf(file, "[ SPACE ]");
        else
            fprintf(file, "[ %c ]", value);
        fclose(file);
        rename(TEXT_CHAR_TMP, TEXT_CHAR_FILE);
    }

    if (log_file != NULL) {
        if (value == ' ')
            fprintf(log_file, "TEXT_CHAR=SPACE MODE=%s INDEX=%zu\n",
                    charset_name(), text_index);
        else
            fprintf(log_file, "TEXT_CHAR=%c MODE=%s INDEX=%zu\n",
                    value, charset_name(), text_index);
        fflush(log_file);
    }
}

static void set_mode(control_mode new_mode)
{
    if (new_mode == mode)
        return;

    mode = new_mode;

    if (mode == MODE_TEXT) {
        charset = CHARSET_LETTERS;
        uppercase = true;
        text_index = 0;
        set_grab(true);
        publish_selected_character();
        log_line("MODE=TEXT (automatic OpenMW text focus)");
    } else {
        set_grab(false);
        unlink(TEXT_CHAR_FILE);
        unlink(TEXT_CHAR_TMP);
        log_line("MODE=GAME (native OpenMW controller passthrough)");
    }
}

static bool openmw_text_active(void)
{
    return access(TEXT_ACTIVE_FLAG, F_OK) == 0;
}

static void sync_automatic_mode(void)
{
    const bool active = openmw_text_active();

    if (!active) {
        suppress_auto_text = false;
        if (mode != MODE_GAME)
            set_mode(MODE_GAME);
        return;
    }

    if (active && !suppress_auto_text && mode != MODE_TEXT)
        set_mode(MODE_TEXT);
}

static void change_text_index(int direction)
{
    const size_t length = charset == CHARSET_ALT
        ? sizeof(alt_chars) - 1
        : sizeof(letters) - 1;

    if (direction > 0)
        text_index = (text_index + 1) % length;
    else
        text_index = (text_index + length - 1) % length;

    publish_selected_character();
}

static void toggle_alt_charset(void)
{
    charset = charset == CHARSET_LETTERS
        ? CHARSET_ALT
        : CHARSET_LETTERS;

    text_index = 0;
    publish_selected_character();
}

static void toggle_case_or_return_to_letters(void)
{
    if (charset == CHARSET_ALT) {
        charset = CHARSET_LETTERS;
        text_index = 0;
    } else {
        uppercase = !uppercase;
    }

    publish_selected_character();
}

static int letter_keycode(char lower)
{
    /*
     * Linux input KEY_* values follow physical keyboard scan-code order, not
     * alphabetical order. KEY_A + n therefore produces A,S,D,F,... rather
     * than A,B,C,D,... . Map every letter explicitly.
     */
    switch (lower) {
        case 'a': return KEY_A;
        case 'b': return KEY_B;
        case 'c': return KEY_C;
        case 'd': return KEY_D;
        case 'e': return KEY_E;
        case 'f': return KEY_F;
        case 'g': return KEY_G;
        case 'h': return KEY_H;
        case 'i': return KEY_I;
        case 'j': return KEY_J;
        case 'k': return KEY_K;
        case 'l': return KEY_L;
        case 'm': return KEY_M;
        case 'n': return KEY_N;
        case 'o': return KEY_O;
        case 'p': return KEY_P;
        case 'q': return KEY_Q;
        case 'r': return KEY_R;
        case 's': return KEY_S;
        case 't': return KEY_T;
        case 'u': return KEY_U;
        case 'v': return KEY_V;
        case 'w': return KEY_W;
        case 'x': return KEY_X;
        case 'y': return KEY_Y;
        case 'z': return KEY_Z;
        default: return -1;
    }
}

static void type_character(char ch)
{
    if (ch >= 'a' && ch <= 'z') {
        int keycode = letter_keycode(ch);
        if (keycode >= 0)
            tap_key(keycode);
        return;
    }

    if (ch >= 'A' && ch <= 'Z') {
        int keycode = letter_keycode((char)(ch - 'A' + 'a'));
        if (keycode >= 0)
            tap_shifted_key(keycode);
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
        case '.': tap_key(KEY_DOT); break;
        case ',': tap_key(KEY_COMMA); break;
        case '\'': tap_key(KEY_APOSTROPHE); break;
        case '-': tap_key(KEY_MINUS); break;
        case '_': tap_shifted_key(KEY_MINUS); break;
        case '/': tap_key(KEY_SLASH); break;
        case '(': tap_shifted_key(KEY_9); break;
        case ')': tap_shifted_key(KEY_0); break;
        case ':': tap_shifted_key(KEY_SEMICOLON); break;
        case ';': tap_key(KEY_SEMICOLON); break;
        case '@': tap_shifted_key(KEY_2); break;
        case '#': tap_shifted_key(KEY_3); break;
        case '$': tap_shifted_key(KEY_4); break;
        case '%': tap_shifted_key(KEY_5); break;
        case '&': tap_shifted_key(KEY_7); break;
        case '+': tap_shifted_key(KEY_EQUAL); break;
        default: break;
    }
}

static void leave_text_mode(void)
{
    log_line("MENU: leave/cancel text entry (Escape).");
    suppress_auto_text = true;
    tap_key(KEY_ESC);
    set_mode(MODE_GAME);
}

static void handle_key_event(const struct input_event *event)
{
    const bool pressed = event->value != 0;
    log_raw_key(event);

    if (mode != MODE_TEXT) {
        /*
         * Native OpenMW receives the physical controller because EVIOCGRAB is
         * off. The helper intentionally does not remap anything in GAME mode.
         */
        if (event->code == KEY_TSP_MENU && pressed && suppress_auto_text) {
            suppress_auto_text = false;
            sync_automatic_mode();
        }
        return;
    }

    if (!pressed)
        return;

    switch (event->code) {
        case KEY_TSP_A:
            type_character(selected_character());
            break;
        case KEY_TSP_B:
            tap_key(KEY_BACKSPACE);
            break;
        case KEY_TSP_X:
            toggle_alt_charset();
            break;
        case KEY_TSP_Y:
            toggle_case_or_return_to_letters();
            break;
        case KEY_TSP_START:
            tap_key(KEY_ENTER);
            break;
        case KEY_TSP_MENU:
            leave_text_mode();
            break;
        default:
            break;
    }
}

static void handle_abs_event(const struct input_event *event)
{
    if (event->code != ABS_TSP_DPAD_X &&
        event->code != ABS_TSP_DPAD_Y)
        return;

    log_raw_abs(event);

    if (mode != MODE_TEXT)
        return;

    if (event->code == ABS_TSP_DPAD_X) {
        const int old_value = dpad_x;
        dpad_x = event->value;

        if (old_value == 0) {
            if (dpad_x > 0)
                tap_key(KEY_RIGHT);
            else if (dpad_x < 0)
                tap_key(KEY_LEFT);
        }
        return;
    }

    if (event->code == ABS_TSP_DPAD_Y) {
        const int old_value = dpad_y;
        dpad_y = event->value;

        if (old_value == 0) {
            if (dpad_y > 0)
                change_text_index(1);
            else if (dpad_y < 0)
                change_text_index(-1);
        }
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

    /*
     * Clear crash leftovers before OpenMW starts. OpenMW will recreate the
     * active flag only when a real text-entry session begins.
     */
    unlink(TEXT_ACTIVE_FLAG);
    unlink(TEXT_CHAR_FILE);
    unlink(TEXT_CHAR_TMP);

    controller_fd = find_controller();
    if (controller_fd < 0) {
        log_line("ERROR: TRIMUI Player1 was not found.");
        if (log_file != NULL)
            fclose(log_file);
        return 1;
    }

    uinput_fd = create_uinput_device();
    if (uinput_fd < 0) {
        log_line("ERROR: Could not create virtual keyboard.");
        close(controller_fd);
        if (log_file != NULL)
            fclose(log_file);
        return 1;
    }

    log_line("TSP OpenMW 0.51 automatic text helper V5 started.");
    log_line("GAME: helper does not grab or remap the controller.");
    log_line("TEXT mode activates only while OpenMW reports active SDL text input.");
    log_line("Up/Down: previous/next character.");
    log_line("Left/Right: move backward/forward through typed text.");
    log_line("A: type selected character; B: backspace/delete.");
    log_line("X: Letters <-> Numbers/Alt/Space.");
    log_line("Y: uppercase/lowercase; from Alt return to Letters.");
    log_line("Start: Enter/finish text; Menu: leave/cancel text mode.");
    log_line("Corrected physical codes: Start=315 Select=314 Menu=316.");

    while (running) {
        sync_automatic_mode();

        struct pollfd poll_fd;
        poll_fd.fd = controller_fd;
        poll_fd.events = POLLIN;
        poll_fd.revents = 0;

        const int result = poll(&poll_fd, 1, TICK_MS);

        if (result > 0 && (poll_fd.revents & POLLIN)) {
            struct input_event events[32];
            const ssize_t count =
                read(controller_fd, events, sizeof(events));

            if (count > 0) {
                const size_t event_count =
                    (size_t)count / sizeof(struct input_event);

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
    }

    set_mode(MODE_GAME);
    unlink(TEXT_ACTIVE_FLAG);
    unlink(TEXT_CHAR_FILE);
    unlink(TEXT_CHAR_TMP);

    if (uinput_fd >= 0) {
        ioctl(uinput_fd, UI_DEV_DESTROY);
        close(uinput_fd);
    }

    if (controller_fd >= 0)
        close(controller_fd);

    log_line("TSP OpenMW 0.51 automatic text helper V5 stopped.");

    if (log_file != NULL)
        fclose(log_file);

    return 0;
}
C_HELPER_SOURCE


echo
echo "Input patch markers:"
grep -n "TSP_AUTO_TEXT_ENTRY_051_V5" "$CPP"
echo
echo "Renderer patch markers:"
grep -n "TSP_GL4ES_DISABLE_NORMALS_RT_051_V6" "$RENDERINGMANAGER_CPP"
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
    echo "V6 also forces the unsupported normals MRT path off to avoid glColorMaski on GL4ES."
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
echo "Building TSP automatic text-entry helper with: $HELPER_CC"
"$HELPER_CC" -O2 -std=gnu11 -Wall -Wextra -Werror "$HELPER_SOURCE" -lm -o "$HELPER_OUTPUT"
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
[ ! -e "$PACKAGE_BINARY" ] || cp -f "$PACKAGE_BINARY" "$PACKAGE_BINARY.before-input-graphics-v6-audited-$STAMP"
[ ! -e "$PACKAGE_HELPER" ] || cp -f "$PACKAGE_HELPER" "$PACKAGE_HELPER.before-$STAMP"

cp -f "$BUILT_BINARY" "$OUTPUT_BINARY"
cp -f "$BUILT_BINARY" "$PACKAGE_BINARY"
cp -f "$HELPER_OUTPUT" "$PACKAGE_HELPER"
chmod +x "$OUTPUT_BINARY" "$PACKAGE_BINARY" "$PACKAGE_HELPER"

# Source patching, helper compilation, OpenMW compilation, and deployment copies all succeeded.
trap - ERR

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
echo "OpenMW 0.51 AUTO TEXT + GRAPHICS rebuild completed"
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
echo "  - normals MRT disabled to avoid unsupported glColorMaski"
echo "  - native OpenMW cursor state rendered through MyGUI"
echo
echo "Launcher requirement: start $PACKAGE_HELPER alongside OpenMW."
echo "Outside active text entry the helper leaves native OpenMW controls untouched."
echo "============================================================"
