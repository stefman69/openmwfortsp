#!/bin/bash
set -euo pipefail

SOURCE_DIR="${1:-/root/openmw}"
BUILD_DIR="${2:-$SOURCE_DIR/build}"

CPP="$SOURCE_DIR/apps/openmw/mwinput/inputmanagerimp.cpp"
HPP="$SOURCE_DIR/apps/openmw/mwinput/inputmanagerimp.hpp"
CMAKE_FILE="$SOURCE_DIR/CMakeLists.txt"

echo "=========================================="
echo "OpenMW 0.48 TSP MyGUI cursor patch V2"
echo "=========================================="
echo "Source: $SOURCE_DIR"
echo "Build:  $BUILD_DIR"
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
    echo "ERROR: Refusing to patch this source tree."
    echo "This script is only for OpenMW 0.48.0."
    echo ""
    echo "Your 0.51 source should remain in its separate directory."
    exit 1
fi

if grep -q "TSP_MYGUI_CURSOR_V2" "$CPP" &&
   grep -q "mTspMouseModeEnabled" "$HPP"; then
    echo ""
    echo "The V2 cursor patch is already applied."
else
    if grep -q "TSP_SOFTWARE_CURSOR_V1" "$CPP" 2>/dev/null; then
        OLD_CPP_BACKUP="$CPP.before-tsp-software-cursor"
        OLD_HPP_BACKUP="$HPP.before-tsp-software-cursor"

        if [ -f "$OLD_CPP_BACKUP" ] && [ -f "$OLD_HPP_BACKUP" ]; then
            echo "Restoring clean files from the first patch attempt..."
            cp -f "$OLD_CPP_BACKUP" "$CPP"
            cp -f "$OLD_HPP_BACKUP" "$HPP"
        else
            echo "ERROR: Old cursor marker found, but its backups are missing."
            exit 1
        fi
    fi

    STAMP="$(date +%Y%m%d-%H%M%S)"
    cp -f "$CPP" "$CPP.before-tsp-mygui-cursor-v2.$STAMP"
    cp -f "$HPP" "$HPP.before-tsp-mygui-cursor-v2.$STAMP"

    python3 - "$CPP" "$HPP" <<'PY'
from pathlib import Path
import re
import sys

cpp_path = Path(sys.argv[1])
hpp_path = Path(sys.argv[2])

cpp = cpp_path.read_text(encoding="utf-8")
hpp = hpp_path.read_text(encoding="utf-8")

MARKER = "TSP_MYGUI_CURSOR_V2"

def find_function(text, signature_regex):
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
    anchor = "#include <osgViewer/ViewerEventHandlers>\n"
    if anchor not in cpp:
        raise RuntimeError(
            "Could not find the osgViewer include insertion point."
        )

    cpp = cpp.replace(
        anchor,
        anchor + "\n#include <MyGUI_PointerManager.h>\n",
        1,
    )

new_update = r'''    // TSP_MYGUI_CURSOR_V2
    void InputManager::update(float dt, bool disableControls, bool disableEvents)
    {
        mControlsDisabled = disableControls;

        MWBase::WindowManager* windowManager
            = MWBase::Environment::get().getWindowManager();

        // The TSPS/GL4ES display path does not render SDL's hardware
        // cursor reliably. Keep it disabled and render MyGUI's existing
        // in-engine pointer instead.
        mInputWrapper->setMouseVisible(false);
        mInputWrapper->capture(disableEvents);

        const bool selectPressed
            = mControllerManager->isButtonPressed(
                SDL_CONTROLLER_BUTTON_BACK);

        const bool leftShoulderPressed
            = mControllerManager->isButtonPressed(
                SDL_CONTROLLER_BUTTON_LEFTSHOULDER);

        // L1 changes the mapper from mouse mode to text mode. Both modes
        // should retain the visible in-engine pointer.
        if (leftShoulderPressed
            && !mTspLeftShoulderWasPressed
            && mTspMouseModeEnabled)
        {
            mTspTextModeEnabled = true;
        }

        // Select follows the same state sequence as openmw.ini:
        // normal -> mouse
        // mouse  -> normal
        // text   -> mouse
        if (selectPressed && !mTspSelectWasPressed)
        {
            if (mTspTextModeEnabled)
            {
                mTspTextModeEnabled = false;
            }
            else
            {
                mTspMouseModeEnabled = !mTspMouseModeEnabled;
            }
        }

        mTspSelectWasPressed = selectPressed;
        mTspLeftShoulderWasPressed = leftShoulderPressed;

        const bool showMyGuiPointer
            = mTspMouseModeEnabled
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

member_anchor = (
    "        std::unique_ptr<GyroManager> mGyroManager;\n"
)

if "mTspMouseModeEnabled" not in hpp:
    if member_anchor not in hpp:
        raise RuntimeError(
            "Could not find the GyroManager member insertion point."
        )

    hpp = hpp.replace(
        member_anchor,
        member_anchor
        + "\n"
        + "        // TSP_MYGUI_CURSOR_V2\n"
        + "        bool mTspMouseModeEnabled = false;\n"
        + "        bool mTspTextModeEnabled = false;\n"
        + "        bool mTspSelectWasPressed = false;\n"
        + "        bool mTspLeftShoulderWasPressed = false;\n",
        1,
    )

if MARKER not in cpp:
    raise RuntimeError("CPP marker verification failed.")

if "mTspMouseModeEnabled" not in hpp:
    raise RuntimeError("HPP member verification failed.")

with open(cpp_path, "w", encoding="utf-8", newline="\n") as handle:
    handle.write(cpp)

with open(hpp_path, "w", encoding="utf-8", newline="\n") as handle:
    handle.write(hpp)

print("Patched:")
print(cpp_path)
print(hpp_path)
PY
fi

echo ""
echo "Patch verification:"
grep -n "TSP_MYGUI_CURSOR_V2" "$CPP" "$HPP"
grep -n "MyGUI_PointerManager" "$CPP"
echo ""

if [ -f "$BUILD_DIR/CMakeCache.txt" ]; then
    echo "Compiler retained by the existing 0.48 build:"
    grep '^CMAKE_CXX_COMPILER:FILEPATH=' \
        "$BUILD_DIR/CMakeCache.txt" || true
    echo ""
fi

echo "Incrementally rebuilding the OpenMW 0.48 executable..."
cmake --build "$BUILD_DIR" --target openmw -- -j"$(nproc)"

OPENMW_BINARY="$BUILD_DIR/openmw"

if [ ! -x "$OPENMW_BINARY" ]; then
    echo ""
    echo "ERROR: Build completed, but the executable was not found:"
    echo "$OPENMW_BINARY"
    exit 1
fi

echo ""
echo "=========================================="
echo "Patch and incremental rebuild completed"
echo "=========================================="
file "$OPENMW_BINARY"
echo ""
echo "New binary:"
echo "$OPENMW_BINARY"
echo ""
echo "Copy this binary out of Docker and replace only the"
echo "openmw executable on the SD card."
