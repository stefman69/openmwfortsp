#!/bin/bash
set -Eeuo pipefail

# OpenMW 0.51 / TrimUI Smart Pro S
# Cursor diagnostic instrumentation v10
#
# DIAGNOSTIC ONLY. Requires the v9 cursor/load patch.
# No controls, cursor rules, graphics, navmesh, memory, or text behavior changes.

SOURCE_DIR="${1:-/root/openmw-0.51-tsp-src}"
BUILD_DIR="${2:-/root/openmw-0.51-tsp-build}"
PACKAGE_DIR="${3:-/root/openmw-0.51-tsp-package}"
OUTPUT_BINARY="${4:-/root/openmw-0.51-tsp-cursor-debug-v10}"
JOBS="${OPENMW_JOBS:-$(nproc)}"
PATCH_ONLY="${OPENMW_PATCH_ONLY:-0}"

INPUT_CPP="$SOURCE_DIR/apps/openmw/mwinput/inputmanagerimp.cpp"
CMAKE_FILE="$SOURCE_DIR/CMakeLists.txt"
BUILT_BINARY="$BUILD_DIR/openmw"
PACKAGE_BINARY="$PACKAGE_DIR/bin/openmw-0.51"

MARKER="// TSP_CURSOR_RUNTIME_DEBUG_051_V10"
V9_MARKER="// TSP_MYGUI_CURSOR_INPUT_FORCE_051_V9"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$SOURCE_DIR/.tsp-051-source-backups/cursor-debug-v10-$STAMP"

restore_on_error() {
    rc=$?
    if [ "$rc" -ne 0 ] && [ -d "$BACKUP_DIR" ]; then
        echo
        echo "ERROR: v10 diagnostic patch failed. Restoring inputmanagerimp.cpp..."
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
echo "OpenMW 0.51 TSP cursor diagnostic v10"
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

if ! grep -Fq "$V9_MARKER" "$INPUT_CPP"; then
    echo "ERROR: v9 cursor patch marker not found."
    echo "Apply the current v9 cursor/load patch first."
    exit 1
fi

if [ "$PATCH_ONLY" != "1" ]; then
    if [ ! -f "$BUILD_DIR/build.ninja" ] || [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
        echo "ERROR: configured Ninja build tree is missing."
        exit 1
    fi
fi

mkdir -p "$BACKUP_DIR/apps/openmw/mwinput" "$PACKAGE_DIR/bin"
cp -f \
    "$INPUT_CPP" \
    "$BACKUP_DIR/apps/openmw/mwinput/inputmanagerimp.cpp"

echo
echo "Adding cursor runtime diagnostics..."

python3 - "$INPUT_CPP" <<'PY_PATCH'
from pathlib import Path
import os
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

marker = "// TSP_CURSOR_RUNTIME_DEBUG_051_V10"
v9_marker = "// TSP_MYGUI_CURSOR_INPUT_FORCE_051_V9"

if v9_marker not in text:
    raise RuntimeError("v9 cursor marker is missing from inputmanagerimp.cpp")

if marker not in text:
    if "#include <cstdio>\n" not in text:
        includes = list(re.finditer(r"^#include[^\n]*\n", text, flags=re.MULTILINE))
        if not includes:
            raise RuntimeError("Could not locate include insertion point")
        at = includes[-1].end()
        text = text[:at] + "#include <cstdio>\n" + text[at:]

    anchor = (
        "        MWBase::WindowManager* windowManager\n"
        "            = MWBase::Environment::get().getWindowManager();\n"
    )

    if text.count(anchor) != 1:
        raise RuntimeError(
            "Expected exactly one WindowManager acquisition anchor; found "
            + str(text.count(anchor))
        )

    logger = r'''
        // TSP_CURSOR_RUNTIME_DEBUG_051_V10
        // Diagnostic only. No input/cursor state is modified here.
        auto tspLogCursorState = [&]()
        {
            static bool initialized = false;
            static bool lastGui = false;
            static bool lastWindowCursor = false;
            static bool lastMyGuiVisible = false;
            static bool lastText = false;
            static int lastSdlCursor = -999;
            static unsigned int frames = 0;

            int mouseX = 0;
            int mouseY = 0;
            SDL_GetMouseState(&mouseX, &mouseY);

            const bool gui = windowManager->isGuiMode();
            const bool windowCursor = windowManager->getCursorVisible();
            const bool myGuiVisible
                = MyGUI::PointerManager::getInstance().isVisible();
            const bool textActive = SDL_IsTextInputActive() == SDL_TRUE;
            const int sdlCursor = SDL_ShowCursor(SDL_QUERY);

            ++frames;

            const bool changed
                = !initialized
                || gui != lastGui
                || windowCursor != lastWindowCursor
                || myGuiVisible != lastMyGuiVisible
                || textActive != lastText
                || sdlCursor != lastSdlCursor;

            if (changed || (frames % 120u) == 0u)
            {
                std::fprintf(
                    stderr,
                    "TSP_CURSOR_DEBUG "
                    "gui=%d windowCursor=%d myguiVisible=%d "
                    "sdlCursor=%d text=%d mouse=%d,%d\n",
                    gui ? 1 : 0,
                    windowCursor ? 1 : 0,
                    myGuiVisible ? 1 : 0,
                    sdlCursor,
                    textActive ? 1 : 0,
                    mouseX,
                    mouseY);
                std::fflush(stderr);

                initialized = true;
                lastGui = gui;
                lastWindowCursor = windowCursor;
                lastMyGuiVisible = myGuiVisible;
                lastText = textActive;
                lastSdlCursor = sdlCursor;
            }
        };
'''

    text = text.replace(anchor, anchor + logger, 1)

    pointer_call = (
        "MyGUI::PointerManager::getInstance().setVisible("
        "windowManager->isGuiMode());"
    )

    if text.count(pointer_call) != 2:
        raise RuntimeError(
            "Expected exactly two v9 MyGUI visibility calls; found "
            + str(text.count(pointer_call))
        )

    first = text.find(pointer_call)
    first_end = first + len(pointer_call)
    text = (
        text[:first_end]
        + "\n            tspLogCursorState();"
        + text[first_end:]
    )

    second = text.find(pointer_call, first_end + len("\n            tspLogCursorState();"))
    if second < 0:
        raise RuntimeError("Could not locate second v9 visibility call")

    second_end = second + len(pointer_call)
    text = (
        text[:second_end]
        + "\n        tspLogCursorState();"
        + text[second_end:]
    )

for token in (
    marker,
    "MyGUI::PointerManager::getInstance().isVisible()",
    "SDL_ShowCursor(SDL_QUERY)",
    "SDL_GetMouseState(&mouseX, &mouseY)",
    '"TSP_CURSOR_DEBUG "',
):
    if token not in text:
        raise RuntimeError("Missing diagnostic token: " + token)

if text.count("tspLogCursorState();") != 2:
    raise RuntimeError(
        "Expected exactly two cursor logger calls; found "
        + str(text.count("tspLogCursorState();"))
    )

tmp = Path(str(path) + ".tsp-v10.tmp")
tmp.write_text(text, encoding="utf-8")
os.replace(str(tmp), str(path))

print("Patched and verified:")
print(path)
PY_PATCH

echo
echo "Verification:"
grep -n \
    -e 'TSP_CURSOR_RUNTIME_DEBUG_051_V10' \
    -e 'TSP_CURSOR_DEBUG' \
    -e 'isVisible()' \
    -e 'SDL_ShowCursor(SDL_QUERY)' \
    "$INPUT_CPP"

if [ "$PATCH_ONLY" = "1" ]; then
    trap - ERR
    echo
    echo "PATCH_ONLY=1: diagnostic source patch completed."
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
    cp -f "$PACKAGE_BINARY" "$PACKAGE_BINARY.before-cursor-debug-v10-$STAMP"
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
echo "SUCCESS: cursor diagnostic v10 built"
echo "============================================================"
echo "Package binary:"
echo "  $PACKAGE_BINARY"
echo
echo "When running on the TSP, search the launcher/OpenMW log for:"
echo "  TSP_CURSOR_DEBUG"
echo
echo "No runtime behavior was intentionally changed."
echo "============================================================"
