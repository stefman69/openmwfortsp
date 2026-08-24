#!/bin/bash
set -Eeuo pipefail

# OpenMW 0.51 / TrimUI Smart Pro S
# Ordinary-MyGUI test cursor v11
#
# Requires current v9 + v10 cursor diagnostic source.
# Draws a large "[+]" ordinary MyGUI TextBox on Popup at SDL mouse coords.
# No controller, text-entry, graphics, navmesh, or memory behavior changes.

SOURCE_DIR="${1:-/root/openmw-0.51-tsp-src}"
BUILD_DIR="${2:-/root/openmw-0.51-tsp-build}"
PACKAGE_DIR="${3:-/root/openmw-0.51-tsp-package}"
OUTPUT_BINARY="${4:-/root/openmw-0.51-tsp-test-cursor-v11}"

JOBS="${OPENMW_JOBS:-1}"
PATCH_ONLY="${OPENMW_PATCH_ONLY:-0}"

INPUT_CPP="$SOURCE_DIR/apps/openmw/mwinput/inputmanagerimp.cpp"
CMAKE_FILE="$SOURCE_DIR/CMakeLists.txt"

BUILT_BINARY="$BUILD_DIR/openmw"
PACKAGE_BINARY="$PACKAGE_DIR/bin/openmw-0.51"

V9_MARKER="// TSP_MYGUI_CURSOR_INPUT_FORCE_051_V9"
V10_MARKER="// TSP_CURSOR_RUNTIME_DEBUG_051_V10"
V11_MARKER="// TSP_ORDINARY_MYGUI_TEST_CURSOR_051_V11"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$SOURCE_DIR/.tsp-051-source-backups/test-cursor-v11-$STAMP"

restore_on_error() {
    rc=$?
    if [ "$rc" -ne 0 ] && [ -d "$BACKUP_DIR" ]; then
        echo
        echo "ERROR: v11 failed. Restoring inputmanagerimp.cpp..."
        if [ -f "$BACKUP_DIR/apps/openmw/mwinput/inputmanagerimp.cpp" ]; then
            cp -f \
                "$BACKUP_DIR/apps/openmw/mwinput/inputmanagerimp.cpp" \
                "$INPUT_CPP"
        fi
        echo "Source restored."
        echo "Failed-attempt backup:"
        echo "  $BACKUP_DIR"
    fi
    exit "$rc"
}
trap restore_on_error ERR

echo "============================================================"
echo "OpenMW 0.51 TSP ordinary MyGUI test cursor v11"
echo "============================================================"
echo "Source:  $SOURCE_DIR"
echo "Build:   $BUILD_DIR"
echo "Package: $PACKAGE_DIR"
echo "Backup:  $BACKUP_DIR"
echo "============================================================"

for required in "$INPUT_CPP" "$CMAKE_FILE"; do
    if [ ! -f "$required" ]; then
        echo "ERROR: missing required file:"
        echo "  $required"
        exit 1
    fi
done

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

if [ "$VERSION_MAJOR" != "0" ] || [ "$VERSION_MINOR" != "51" ]; then
    echo "ERROR: expected OpenMW 0.51 source."
    exit 1
fi

grep -Fq "$V9_MARKER" "$INPUT_CPP" || {
    echo "ERROR: v9 cursor marker missing."
    exit 1
}

grep -Fq "$V10_MARKER" "$INPUT_CPP" || {
    echo "ERROR: v10 cursor diagnostic marker missing."
    echo "Build v10 first."
    exit 1
}

if [ "$PATCH_ONLY" != "1" ]; then
    if [ ! -f "$BUILD_DIR/build.ninja" ] || [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
        echo "ERROR: configured Ninja build tree missing."
        exit 1
    fi
fi

mkdir -p \
    "$BACKUP_DIR/apps/openmw/mwinput" \
    "$PACKAGE_DIR/bin"

cp -f "$INPUT_CPP" "$BACKUP_DIR/apps/openmw/mwinput/inputmanagerimp.cpp"

echo
echo "Applying ordinary MyGUI test cursor..."

python3 - "$INPUT_CPP" <<'PY_PATCH'
from pathlib import Path
import os
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

v9_marker = "// TSP_MYGUI_CURSOR_INPUT_FORCE_051_V9"
v10_marker = "// TSP_CURSOR_RUNTIME_DEBUG_051_V10"
v11_marker = "// TSP_ORDINARY_MYGUI_TEST_CURSOR_051_V11"

if v9_marker not in text:
    raise RuntimeError("v9 marker missing")

if v10_marker not in text:
    raise RuntimeError("v10 marker missing")

if v11_marker not in text:
    for include in (
        "#include <MyGUI_Gui.h>\n",
        "#include <MyGUI_TextBox.h>\n",
    ):
        if include not in text:
            matches = list(
                re.finditer(r"^#include[^\n]*\n", text, flags=re.MULTILINE)
            )
            if not matches:
                raise RuntimeError("Could not find include insertion point")
            at = matches[-1].end()
            text = text[:at] + include + text[at:]

    marker_pos = text.find(v10_marker)
    if marker_pos < 0:
        raise RuntimeError("Could not locate v10 marker")

    logger_end = text.find("        };\n", marker_pos)
    if logger_end < 0:
        raise RuntimeError("Could not locate end of v10 logger lambda")
    logger_end += len("        };\n")

    cursor_code = r'''
        // TSP_ORDINARY_MYGUI_TEST_CURSOR_051_V11
        // Ordinary widget diagnostic cursor. This bypasses PointerManager's
        // special pointer rendering and uses the same general widget path as
        // normal OpenMW menu text.
        auto tspUpdateOrdinaryTestCursor = [&]()
        {
            static MyGUI::TextBox* testCursor = nullptr;
            static bool lastVisible = false;

            int mouseX = 0;
            int mouseY = 0;
            SDL_GetMouseState(&mouseX, &mouseY);

            const bool shouldShow = windowManager->isGuiMode();

            if (testCursor == nullptr)
            {
                testCursor
                    = MyGUI::Gui::getInstance().createWidget<MyGUI::TextBox>(
                        "ProgressText",
                        MyGUI::IntCoord(0, 0, 72, 56),
                        MyGUI::Align::Default,
                        "Popup");

                testCursor->setTextAlign(MyGUI::Align::Center);
                testCursor->setFontHeight(38);
                testCursor->setCaption("[+]");
                testCursor->setNeedMouseFocus(false);
                testCursor->setVisible(false);

                std::fprintf(
                    stderr,
                    "TSP_TEST_CURSOR created=1 skin=ProgressText "
                    "layer=Popup size=72x56\n");
                std::fflush(stderr);
            }

            int x = mouseX - 36;
            int y = mouseY - 28;

            if (x < 0)
                x = 0;
            if (y < 0)
                y = 0;

            testCursor->setPosition(x, y);
            testCursor->setVisible(shouldShow);

            if (shouldShow != lastVisible)
            {
                std::fprintf(
                    stderr,
                    "TSP_TEST_CURSOR visible=%d mouse=%d,%d widget=%d,%d\n",
                    shouldShow ? 1 : 0,
                    mouseX,
                    mouseY,
                    x,
                    y);
                std::fflush(stderr);
                lastVisible = shouldShow;
            }
        };
'''

    text = text[:logger_end] + cursor_code + text[logger_end:]

    debug_call = "tspLogCursorState();"

    if text.count(debug_call) != 2:
        raise RuntimeError(
            "Expected exactly two v10 logger calls, found "
            + str(text.count(debug_call))
        )

    first = text.find(debug_call)
    first_end = first + len(debug_call)
    text = (
        text[:first_end]
        + "\n            tspUpdateOrdinaryTestCursor();"
        + text[first_end:]
    )

    second = text.find(
        debug_call,
        first_end + len("\n            tspUpdateOrdinaryTestCursor();"),
    )

    if second < 0:
        raise RuntimeError("Could not find second v10 logger call")

    second_end = second + len(debug_call)
    text = (
        text[:second_end]
        + "\n        tspUpdateOrdinaryTestCursor();"
        + text[second_end:]
    )

for token in (
    v11_marker,
    "createWidget<MyGUI::TextBox>",
    '"ProgressText"',
    '"Popup"',
    'setCaption("[+]")',
    "SDL_GetMouseState(&mouseX, &mouseY)",
    "testCursor->setPosition(x, y)",
    "testCursor->setVisible(shouldShow)",
    '"TSP_TEST_CURSOR created=1',
):
    if token not in text:
        raise RuntimeError("Missing v11 token: " + token)

if text.count("tspUpdateOrdinaryTestCursor();") != 2:
    raise RuntimeError(
        "Expected exactly two v11 cursor-update calls, found "
        + str(text.count("tspUpdateOrdinaryTestCursor();"))
    )

start = text.find(v11_marker)
end = text.find("        };\n", start)
if end < 0:
    raise RuntimeError("Could not isolate v11 cursor block")
block = text[start:end]

for forbidden in (
    "SDL_CONTROLLER_BUTTON_A",
    "SDL_CONTROLLER_BUTTON_START",
    "KEY_ENTER",
    "KEY_SPACE",
):
    if forbidden in block:
        raise RuntimeError(
            "v11 cursor block unexpectedly contains input mapping token: "
            + forbidden
        )

tmp = Path(str(path) + ".tsp-v11.tmp")
tmp.write_text(text, encoding="utf-8")
os.replace(str(tmp), str(path))

print("v11 ordinary MyGUI test cursor applied:")
print(" ", path)
print("Test marker: [+]")
print("Skin: ProgressText")
print("Layer: Popup")
print("Size: 72x56")
PY_PATCH

echo
echo "===== V11 VERIFICATION ====="
grep -n \
    -e 'TSP_ORDINARY_MYGUI_TEST_CURSOR_051_V11' \
    -e 'TSP_TEST_CURSOR' \
    -e 'tspUpdateOrdinaryTestCursor' \
    "$INPUT_CPP"

if [ "$PATCH_ONLY" = "1" ]; then
    trap - ERR
    echo
    echo "PATCH_ONLY=1: source patch completed."
    exit 0
fi

echo
echo "Incrementally rebuilding OpenMW only..."
cmake --build "$BUILD_DIR" --target openmw --parallel "$JOBS"

if [ ! -x "$BUILT_BINARY" ]; then
    echo "ERROR: rebuilt OpenMW executable missing:"
    echo "  $BUILT_BINARY"
    exit 1
fi

if [ -e "$OUTPUT_BINARY" ]; then
    cp -f "$OUTPUT_BINARY" "$OUTPUT_BINARY.before-$STAMP"
fi

if [ -e "$PACKAGE_BINARY" ]; then
    cp -f \
        "$PACKAGE_BINARY" \
        "$PACKAGE_BINARY.before-test-cursor-v11-$STAMP"
fi

cp -f "$BUILT_BINARY" "$OUTPUT_BINARY"
cp -f "$BUILT_BINARY" "$PACKAGE_BINARY"
chmod +x "$OUTPUT_BINARY" "$PACKAGE_BINARY"

STRIP_TOOL=""

if command -v aarch64-linux-gnu-strip >/dev/null 2>&1; then
    STRIP_TOOL="$(command -v aarch64-linux-gnu-strip)"
elif command -v strip >/dev/null 2>&1; then
    STRIP_TOOL="$(command -v strip)"
fi

if [ -n "$STRIP_TOOL" ]; then
    "$STRIP_TOOL" --strip-unneeded "$OUTPUT_BINARY"
    "$STRIP_TOOL" --strip-unneeded "$PACKAGE_BINARY"
fi

trap - ERR

echo
echo "============================================================"
echo "SUCCESS: OpenMW 0.51 TSP test cursor v11 built"
echo "============================================================"
echo "Package binary:"
echo "  $PACKAGE_BINARY"
echo
echo "Standalone binary:"
echo "  $OUTPUT_BINARY"
echo
echo "Expected:"
echo "  GUI/menu: large [+] follows controller-driven mouse"
echo "  Gameplay: [+] hidden"
echo
echo "Search runtime log for:"
echo "  TSP_TEST_CURSOR"
echo "  TSP_CURSOR_DEBUG"
echo "============================================================"
