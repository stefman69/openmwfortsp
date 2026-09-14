#!/bin/bash
set -euo pipefail

SOURCE_DIR="${1:-/root/openmw}"
BUILD_DIR="${2:-$SOURCE_DIR/build}"
OUTPUT_BINARY="${3:-/root/openmw_cursor_menu_select_v4}"

CPP="$SOURCE_DIR/apps/openmw/mwinput/inputmanagerimp.cpp"
HPP="$SOURCE_DIR/apps/openmw/mwinput/inputmanagerimp.hpp"
CMAKE_FILE="$SOURCE_DIR/CMakeLists.txt"
BUILT_BINARY="$BUILD_DIR/openmw"

echo "============================================================"
echo "OpenMW 0.48 TSP cursor patch V4"
echo "Select changes profile; Menu+Select toggles visible pointer"
echo "============================================================"
echo "Source:          $SOURCE_DIR"
echo "Build:           $BUILD_DIR"
echo "Stripped output: $OUTPUT_BINARY"
echo ""

for required in "$CPP" "$HPP" "$CMAKE_FILE"; do
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
    echo "The separate OpenMW 0.51 source tree will not be touched."
    exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
CPP_BACKUP="$CPP.before-tsp-menu-select-cursor-v4.$STAMP"
HPP_BACKUP="$HPP.before-tsp-menu-select-cursor-v4.$STAMP"

cp -f "$CPP" "$CPP_BACKUP"
cp -f "$HPP" "$HPP_BACKUP"

echo "Created source backups:"
echo "$CPP_BACKUP"
echo "$HPP_BACKUP"
echo ""

python3 - "$CPP" "$HPP" <<'PY'
from pathlib import Path
import re
import sys

cpp_path = Path(sys.argv[1])
hpp_path = Path(sys.argv[2])

cpp = cpp_path.read_text(encoding="utf-8")
hpp = hpp_path.read_text(encoding="utf-8")


def find_function(text: str, signature_regex: str) -> tuple[int, int]:
    match = re.search(signature_regex, text, flags=re.MULTILINE)
    if not match:
        raise RuntimeError(
            "Could not locate InputManager::update by signature."
        )

    opening = text.find("{", match.end())
    if opening < 0:
        raise RuntimeError(
            "Located InputManager::update, but its opening brace is missing."
        )

    depth = 0
    in_string = False
    in_char = False
    escaped = False
    line_comment = False
    block_comment = False
    i = opening

    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""

        if line_comment:
            if ch == "\n":
                line_comment = False
            i += 1
            continue

        if block_comment:
            if ch == "*" and nxt == "/":
                block_comment = False
                i += 2
            else:
                i += 1
            continue

        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            i += 1
            continue

        if in_char:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == "'":
                in_char = False
            i += 1
            continue

        if ch == "/" and nxt == "/":
            line_comment = True
            i += 2
            continue

        if ch == "/" and nxt == "*":
            block_comment = True
            i += 2
            continue

        if ch == '"':
            in_string = True
            i += 1
            continue

        if ch == "'":
            in_char = True
            i += 1
            continue

        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return match.start(), i + 1

        i += 1

    raise RuntimeError(
        "InputManager::update opening brace was found, but its end was not."
    )


if "#include <MyGUI_PointerManager.h>" not in cpp:
    include_matches = list(
        re.finditer(r"^#include[^\n]*\n", cpp, flags=re.MULTILINE)
    )

    if not include_matches:
        raise RuntimeError(
            "Could not find an include insertion point."
        )

    insertion = include_matches[-1].end()
    cpp = (
        cpp[:insertion]
        + "#include <MyGUI_PointerManager.h>\n"
        + cpp[insertion:]
    )


new_update = r'''    // TSP_MYGUI_CURSOR_V4
    void InputManager::update(float dt, bool disableControls, bool disableEvents)
    {
        mControlsDisabled = disableControls;

        MWBase::WindowManager* windowManager
            = MWBase::Environment::get().getWindowManager();

        // The TSP/GL4ES display path does not reliably render SDL's
        // hardware cursor. Keep it disabled and use MyGUI's existing
        // in-engine pointer instead.
        mInputWrapper->setMouseVisible(false);
        mInputWrapper->capture(disableEvents);

        const bool selectPressed
            = mControllerManager->isButtonPressed(
                SDL_CONTROLLER_BUTTON_BACK);

        const bool leftShoulderPressed
            = mControllerManager->isButtonPressed(
                SDL_CONTROLLER_BUTTON_LEFTSHOULDER);

        // gptokeyb2 emits the otherwise unused Pause key only for the
        // Menu+Select chord. Menu/Guide remains hidden from OpenMW itself,
        // so an ordinary Menu press cannot trigger native Quick Save.
        const Uint8* keyboardState = SDL_GetKeyboardState(nullptr);
        const bool cursorChordPressed
            = keyboardState != nullptr
            && keyboardState[SDL_SCANCODE_PAUSE] != 0;

        // L1 changes the gptokeyb2 profile from cursor mode to text mode.
        if (leftShoulderPressed
            && !mTspLeftShoulderWasPressed
            && mTspMouseModeEnabled)
        {
            mTspTextModeEnabled = true;
        }

        // Menu+Select consumes this Select press so it cannot also enter or
        // leave the mouse-control profile. The visible pointer can only be
        // toggled while that profile is active and text entry is inactive.
        if (cursorChordPressed
            && !mTspCursorChordWasPressed
            && selectPressed)
        {
            mTspSelectConsumedByChord = true;

            if (mTspMouseModeEnabled && !mTspTextModeEnabled)
                mTspCursorVisible = !mTspCursorVisible;
        }

        // Process Select on release rather than press. This gives the
        // Menu+Select chord time to claim the press before the profile
        // state is changed.
        if (!selectPressed && mTspSelectWasPressed)
        {
            if (!mTspSelectConsumedByChord)
            {
                if (mTspTextModeEnabled)
                {
                    mTspTextModeEnabled = false;
                }
                else
                {
                    mTspMouseModeEnabled = !mTspMouseModeEnabled;
                    mTspCursorVisible = false;
                }
            }

            mTspSelectConsumedByChord = false;
        }

        if (!mTspMouseModeEnabled)
            mTspCursorVisible = false;

        mTspSelectWasPressed = selectPressed;
        mTspLeftShoulderWasPressed = leftShoulderPressed;
        mTspCursorChordWasPressed = cursorChordPressed;

        const bool showMyGuiPointer
            = mTspMouseModeEnabled
            && mTspCursorVisible
            && windowManager->isGuiMode();

        MyGUI::PointerManager::getInstance().setVisible(
            showMyGuiPointer);

        if (disableControls)
        {
            mMouseManager->updateCursorMode();
            return;
        }

        mBindingsManager->update(dt);

        mMouseManager->updateCursorMode();
        bool controllerMove = mControllerManager->update(dt);
        mMouseManager->update(dt);
        mSensorManager->update(dt);
        mActionManager->update(dt, controllerMove);

        if (mGyroManager->isEnabled())
        {
            bool controllerAvailable
                = mControllerManager->isGyroAvailable();
            bool sensorAvailable
                = mSensorManager->isGyroAvailable();

            if (controllerAvailable || sensorAvailable)
            {
                mGyroManager->update(
                    dt,
                    controllerAvailable
                        ? mControllerManager->getGyroValues()
                        : mSensorManager->getGyroValues());
            }
        }
    }'''

start, end = find_function(
    cpp,
    r"^[ \t]*void[ \t]+InputManager::update[ \t]*\("
)
cpp = cpp[:start] + new_update + cpp[end:]


hpp = re.sub(
    r"^[ \t]*// TSP_MYGUI_CURSOR_V[0-9]+\s*\n",
    "",
    hpp,
    flags=re.MULTILINE,
)

old_member_names = (
    "mTspMouseModeEnabled",
    "mTspTextModeEnabled",
    "mTspSelectWasPressed",
    "mTspLeftShoulderWasPressed",
    "mTspCursorVisible",
    "mTspLeftStickWasPressed",
    "mTspCursorChordWasPressed",
    "mTspSelectConsumedByChord",
)

for member_name in old_member_names:
    hpp = re.sub(
        rf"^[ \t]*bool[ \t]+{member_name}[ \t]*=[ \t]*false;[ \t]*\n",
        "",
        hpp,
        flags=re.MULTILINE,
    )

member_anchor = "        std::unique_ptr<GyroManager> mGyroManager;\n"

if member_anchor not in hpp:
    raise RuntimeError(
        "Could not find the GyroManager member insertion point."
    )

member_block = (
    member_anchor
    + "\n"
    + "        // TSP_MYGUI_CURSOR_V4\n"
    + "        bool mTspMouseModeEnabled = false;\n"
    + "        bool mTspTextModeEnabled = false;\n"
    + "        bool mTspSelectWasPressed = false;\n"
    + "        bool mTspLeftShoulderWasPressed = false;\n"
    + "        bool mTspCursorVisible = false;\n"
    + "        bool mTspCursorChordWasPressed = false;\n"
    + "        bool mTspSelectConsumedByChord = false;\n"
)

hpp = hpp.replace(member_anchor, member_block, 1)

for token in (
    "TSP_MYGUI_CURSOR_V4",
    "SDL_SCANCODE_PAUSE",
    "mTspCursorChordWasPressed",
    "mTspSelectConsumedByChord",
    "MyGUI::PointerManager",
):
    if token not in cpp:
        raise RuntimeError(
            f"CPP verification failed: missing {token}"
        )

for token in (
    "TSP_MYGUI_CURSOR_V4",
    "mTspMouseModeEnabled",
    "mTspCursorVisible",
    "mTspCursorChordWasPressed",
    "mTspSelectConsumedByChord",
):
    if token not in hpp:
        raise RuntimeError(
            f"HPP verification failed: missing {token}"
        )

cpp_path.write_text(cpp, encoding="utf-8", newline="\n")
hpp_path.write_text(hpp, encoding="utf-8", newline="\n")

print("Updated:")
print(cpp_path)
print(hpp_path)
PY

echo ""
echo "Patch verification:"
grep -n "TSP_MYGUI_CURSOR_V4" "$CPP" "$HPP"
grep -n "SDL_SCANCODE_PAUSE" "$CPP"
grep -n "mTspSelectConsumedByChord" "$CPP" "$HPP"
echo ""

echo "MyGUI selected by the existing OpenMW build:"
grep -E \
    '^(MyGUI_INCLUDE_DIR|MyGUI_LIBRARY):' \
    "$BUILD_DIR/CMakeCache.txt" || true
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
echo "Creating separate stripped deployment binary..."
cp -f "$BUILT_BINARY" "$OUTPUT_BINARY"

STRIP_TOOL=""

if command -v aarch64-linux-gnu-strip >/dev/null 2>&1; then
    STRIP_TOOL="$(command -v aarch64-linux-gnu-strip)"
elif command -v strip >/dev/null 2>&1; then
    STRIP_TOOL="$(command -v strip)"
else
    echo "ERROR: No strip tool was found."
    echo "The unstripped binary remains available at:"
    echo "$BUILT_BINARY"
    exit 1
fi

"$STRIP_TOOL" --strip-unneeded "$OUTPUT_BINARY"
chmod +x "$OUTPUT_BINARY"

echo ""
echo "============================================================"
echo "Patch, rebuild, and stripping completed"
echo "============================================================"
echo "Unstripped build binary:"
ls -lh "$BUILT_BINARY"
file "$BUILT_BINARY"
echo ""
echo "Stripped deployment binary:"
ls -lh "$OUTPUT_BINARY"
file "$OUTPUT_BINARY"
echo ""
echo "Copy this file to the SD card as:"
echo "  D:\\Data\\ports\\openmw\\openmw"
echo ""
echo "Keep the dropdown-fixed libMyGUIEngine.so files already installed."
echo ""
echo "Use the updated gptokeyb2 profile as:"
echo "  D:\\Data\\ports\\openmw\\openmw.ini"
echo "============================================================"
