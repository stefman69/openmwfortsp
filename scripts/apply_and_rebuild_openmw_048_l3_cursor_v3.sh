#!/bin/bash
set -euo pipefail

SOURCE_DIR="${1:-/root/openmw}"
BUILD_DIR="${2:-$SOURCE_DIR/build}"
OUTPUT_BINARY="${3:-/root/openmw_cursor_l3_v3}"

CPP="$SOURCE_DIR/apps/openmw/mwinput/inputmanagerimp.cpp"
HPP="$SOURCE_DIR/apps/openmw/mwinput/inputmanagerimp.hpp"
CMAKE_FILE="$SOURCE_DIR/CMakeLists.txt"
BUILT_BINARY="$BUILD_DIR/openmw"

echo "============================================================"
echo "OpenMW 0.48 TSP cursor patch V3"
echo "Select changes profile; L3 toggles visible pointer"
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

if [ ! -d "$BUILD_DIR" ]; then
    echo "ERROR: Existing OpenMW build directory was not found:"
    echo "$BUILD_DIR"
    exit 1
fi

VERSION_MAJOR="$(sed -n 's/^[[:space:]]*set(OPENMW_VERSION_MAJOR[[:space:]]*\([0-9][0-9]*\)).*/\1/p' "$CMAKE_FILE" | head -1)"
VERSION_MINOR="$(sed -n 's/^[[:space:]]*set(OPENMW_VERSION_MINOR[[:space:]]*\([0-9][0-9]*\)).*/\1/p' "$CMAKE_FILE" | head -1)"
VERSION_RELEASE="$(sed -n 's/^[[:space:]]*set(OPENMW_VERSION_RELEASE[[:space:]]*\([0-9][0-9]*\)).*/\1/p' "$CMAKE_FILE" | head -1)"

echo "Detected source version: ${VERSION_MAJOR:-?}.${VERSION_MINOR:-?}.${VERSION_RELEASE:-?}"

if [ "${VERSION_MAJOR:-}" != "0" ] ||
   [ "${VERSION_MINOR:-}" != "48" ] ||
   [ "${VERSION_RELEASE:-}" != "0" ]; then
    echo ""
    echo "ERROR: This script is only for the OpenMW 0.48.0 source tree."
    echo "It will not patch the separate OpenMW 0.51 source tree."
    exit 1
fi

if ! grep -q "TSP_MYGUI_CURSOR_V2\|TSP_MYGUI_CURSOR_V3" "$CPP"; then
    echo ""
    echo "ERROR: The existing TSP MyGUI cursor patch was not found."
    echo "Apply the previous V2 patch first, then run this V3 updater."
    exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
CPP_BACKUP="$CPP.before-tsp-mygui-cursor-v3.$STAMP"
HPP_BACKUP="$HPP.before-tsp-mygui-cursor-v3.$STAMP"

cp -f "$CPP" "$CPP_BACKUP"
cp -f "$HPP" "$HPP_BACKUP"

echo ""
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
        raise RuntimeError("Could not locate InputManager::update by signature.")

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
    raise RuntimeError("The previous MyGUI cursor patch include is missing.")

new_update = r'''    // TSP_MYGUI_CURSOR_V3
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

        const bool leftStickPressed
            = mControllerManager->isButtonPressed(
                SDL_CONTROLLER_BUTTON_LEFTSTICK);

        // L1 changes the gptokeyb2 profile from cursor mode to text mode.
        if (leftShoulderPressed
            && !mTspLeftShoulderWasPressed
            && mTspMouseModeEnabled)
        {
            mTspTextModeEnabled = true;
        }

        // Select follows the gptokeyb2 profile sequence:
        // normal -> cursor profile
        // cursor -> normal profile
        // text   -> cursor profile
        //
        // Select no longer displays the pointer. Entering or leaving the
        // cursor profile always begins with the pointer hidden.
        if (selectPressed && !mTspSelectWasPressed)
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

        // L3 toggles the visible pointer only while the cursor profile is
        // active. Normal-gameplay L3 therefore remains available for Sneak.
        if (leftStickPressed
            && !mTspLeftStickWasPressed
            && mTspMouseModeEnabled
            && !mTspTextModeEnabled)
        {
            mTspCursorVisible = !mTspCursorVisible;
        }

        // Never retain a visible pointer after cursor mode has ended.
        if (!mTspMouseModeEnabled)
            mTspCursorVisible = false;

        mTspSelectWasPressed = selectPressed;
        mTspLeftShoulderWasPressed = leftShoulderPressed;
        mTspLeftStickWasPressed = leftStickPressed;

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

hpp = hpp.replace(
    "// TSP_MYGUI_CURSOR_V2",
    "// TSP_MYGUI_CURSOR_V3",
)

if "mTspMouseModeEnabled" not in hpp:
    raise RuntimeError(
        "The existing V2 cursor-state members were not found in the header."
    )

member_anchor = "        bool mTspLeftShoulderWasPressed = false;\n"

if "mTspCursorVisible" not in hpp:
    if member_anchor not in hpp:
        raise RuntimeError(
            "Could not find the V2 member insertion point in the header."
        )

    hpp = hpp.replace(
        member_anchor,
        member_anchor
        + "        bool mTspCursorVisible = false;\n"
        + "        bool mTspLeftStickWasPressed = false;\n",
        1,
    )

required_cpp = (
    "TSP_MYGUI_CURSOR_V3",
    "SDL_CONTROLLER_BUTTON_LEFTSTICK",
    "mTspCursorVisible",
    "mTspLeftStickWasPressed",
)

for token in required_cpp:
    if token not in cpp:
        raise RuntimeError(f"CPP verification failed: missing {token}")

required_hpp = (
    "TSP_MYGUI_CURSOR_V3",
    "mTspCursorVisible",
    "mTspLeftStickWasPressed",
)

for token in required_hpp:
    if token not in hpp:
        raise RuntimeError(f"HPP verification failed: missing {token}")

cpp_path.write_text(cpp, encoding="utf-8", newline="\n")
hpp_path.write_text(hpp, encoding="utf-8", newline="\n")

print("Updated:")
print(cpp_path)
print(hpp_path)
PY

echo ""
echo "Patch verification:"
grep -n "TSP_MYGUI_CURSOR_V3" "$CPP" "$HPP"
grep -n "SDL_CONTROLLER_BUTTON_LEFTSTICK" "$CPP"
grep -n "mTspCursorVisible" "$CPP" "$HPP"
grep -n "mTspLeftStickWasPressed" "$CPP" "$HPP"
echo ""

if [ -f "$BUILD_DIR/CMakeCache.txt" ]; then
    echo "Compiler retained by the existing 0.48 build:"
    grep '^CMAKE_CXX_COMPILER:FILEPATH=' \
        "$BUILD_DIR/CMakeCache.txt" || true
    echo ""
fi

echo "Incrementally rebuilding OpenMW 0.48..."
cmake --build "$BUILD_DIR" --target openmw -- -j"$(nproc)"

if [ ! -x "$BUILT_BINARY" ]; then
    echo ""
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
    echo "ERROR: No strip tool was found in the container."
    echo "The rebuilt binary remains available at:"
    echo "$BUILT_BINARY"
    exit 1
fi

"$STRIP_TOOL" --strip-unneeded "$OUTPUT_BINARY"
chmod +x "$OUTPUT_BINARY"

echo ""
echo "============================================================"
echo "Patch, incremental rebuild, and stripping completed"
echo "============================================================"
echo ""
echo "Unstripped build binary:"
ls -lh "$BUILT_BINARY"
file "$BUILT_BINARY"
echo ""
echo "Stripped deployment binary:"
ls -lh "$OUTPUT_BINARY"
file "$OUTPUT_BINARY"
echo ""
echo "Install the stripped deployment binary on the SD card as:"
echo "data/ports/openmw/openmw"
echo ""
echo "Use it with the updated controller profile:"
echo "openmw_select_profile_l3_cursor.ini"
