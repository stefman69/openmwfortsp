#!/bin/bash
set -Eeuo pipefail

# OpenMW 0.51 / TrimUI Smart Pro S
# Cursor + Load Game controller fix v9
#
# Scope is intentionally narrow:
#   1. Undo ONLY v8's WindowManager cursor-routing experiment.
#   2. Restore stock OpenMW 0.51 WindowManager cursor bookkeeping.
#   3. Use the proven 0.48/TSP strategy at the InputManager layer:
#        - SDL hardware cursor always hidden on TSP.
#        - MyGUI software pointer forced visible whenever OpenMW is in GUI mode.
#   4. In Load Game only, allow BOTH A and Start to accept the highlighted save.
#
# No graphics, navmesh, water, LOD, memory, or runtime texture changes are made.
# No CMake regeneration is performed.

SOURCE_DIR="${1:-/root/openmw-0.51-tsp-src}"
BUILD_DIR="${2:-/root/openmw-0.51-tsp-build}"
PACKAGE_DIR="${3:-/root/openmw-0.51-tsp-package}"
OUTPUT_BINARY="${4:-/root/openmw-0.51-tsp-cursor-load-v9}"

JOBS="${OPENMW_JOBS:-$(nproc)}"
PATCH_ONLY="${OPENMW_PATCH_ONLY:-0}"

WINDOW_CPP="$SOURCE_DIR/apps/openmw/mwgui/windowmanagerimp.cpp"
INPUT_CPP="$SOURCE_DIR/apps/openmw/mwinput/inputmanagerimp.cpp"
SAVE_CPP="$SOURCE_DIR/apps/openmw/mwgui/savegamedialog.cpp"
CMAKE_FILE="$SOURCE_DIR/CMakeLists.txt"

POST_CPP="$SOURCE_DIR/apps/openmw/mwrender/postprocessor.cpp"
NIFLOADER_CPP="$SOURCE_DIR/components/nifosg/nifloader.cpp"
WATER_CPP="$SOURCE_DIR/apps/openmw/mwrender/water.cpp"
RESOURCE_CPP="$SOURCE_DIR/components/resource/resourcesystem.cpp"
SCENE_CPP="$SOURCE_DIR/components/resource/scenemanager.cpp"

BUILT_BINARY="$BUILD_DIR/openmw"
PACKAGE_BINARY="$PACKAGE_DIR/bin/openmw-0.51"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$SOURCE_DIR/.tsp-051-source-backups/cursor-load-v9-$STAMP"

restore_on_error() {
    rc=$?

    if [ "$rc" -ne 0 ] && [ -d "$BACKUP_DIR" ]; then
        echo
        echo "ERROR: v9 failed. Restoring the three UI/input source files..."

        [ ! -f "$BACKUP_DIR/apps/openmw/mwgui/windowmanagerimp.cpp" ] || \
            cp -f "$BACKUP_DIR/apps/openmw/mwgui/windowmanagerimp.cpp" "$WINDOW_CPP"

        [ ! -f "$BACKUP_DIR/apps/openmw/mwinput/inputmanagerimp.cpp" ] || \
            cp -f "$BACKUP_DIR/apps/openmw/mwinput/inputmanagerimp.cpp" "$INPUT_CPP"

        [ ! -f "$BACKUP_DIR/apps/openmw/mwgui/savegamedialog.cpp" ] || \
            cp -f "$BACKUP_DIR/apps/openmw/mwgui/savegamedialog.cpp" "$SAVE_CPP"

        echo "Source restored."
        echo "Failed-attempt backup:"
        echo "  $BACKUP_DIR"
    fi

    exit "$rc"
}
trap restore_on_error ERR

echo "============================================================"
echo "OpenMW 0.51 TSP cursor + Load Game controls v9"
echo "============================================================"
echo "Source:  $SOURCE_DIR"
echo "Build:   $BUILD_DIR"
echo "Package: $PACKAGE_DIR"
echo "Backup:  $BACKUP_DIR"
echo "============================================================"

for required in \
    "$WINDOW_CPP" \
    "$INPUT_CPP" \
    "$SAVE_CPP" \
    "$CMAKE_FILE" \
    "$POST_CPP" \
    "$NIFLOADER_CPP" \
    "$WATER_CPP" \
    "$RESOURCE_CPP" \
    "$SCENE_CPP"
do
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
    echo "Detected: ${VERSION_MAJOR:-?}.${VERSION_MINOR:-?}"
    exit 1
fi

# Refuse to operate if our known-good renderer/stability baseline disappeared.
for marker_file in \
    "TSP_LEGACY_DIRECT_RENDER_051_V2|$POST_CPP" \
    "TSP_NILOD_OVERLAP_FIX_051_V4|$NIFLOADER_CPP" \
    "TSP_GL4ES_WATER_DENSE_GRID_051_V7|$WATER_CPP" \
    "TSP_MEMORY_TRIM_UPDATE_051_V7|$RESOURCE_CPP" \
    "TSP_GL4ES_POT_SAFE_MIPMAPS_051_V8|$SCENE_CPP"
do
    IFS='|' read -r marker file <<< "$marker_file"

    if ! grep -Fq "$marker" "$file"; then
        echo "ERROR: known-good baseline marker missing:"
        echo "  $marker"
        echo "from:"
        echo "  $file"
        exit 1
    fi
done

if [ "$PATCH_ONLY" != "1" ]; then
    if [ ! -f "$BUILD_DIR/build.ninja" ] || [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
        echo "ERROR: configured Ninja build tree missing."
        echo "v9 intentionally does not regenerate CMake."
        exit 1
    fi
fi

mkdir -p \
    "$BACKUP_DIR/apps/openmw/mwgui" \
    "$BACKUP_DIR/apps/openmw/mwinput" \
    "$PACKAGE_DIR/bin"

cp -f "$WINDOW_CPP" "$BACKUP_DIR/apps/openmw/mwgui/windowmanagerimp.cpp"
cp -f "$INPUT_CPP" "$BACKUP_DIR/apps/openmw/mwinput/inputmanagerimp.cpp"
cp -f "$SAVE_CPP" "$BACKUP_DIR/apps/openmw/mwgui/savegamedialog.cpp"

echo
echo "Applying v9 UI/input patch..."

python3 - "$WINDOW_CPP" "$INPUT_CPP" "$SAVE_CPP" <<'PY_PATCH'
from pathlib import Path
import os
import re
import sys

window_path = Path(sys.argv[1])
input_path = Path(sys.argv[2])
save_path = Path(sys.argv[3])

window = window_path.read_text(encoding="utf-8")
input_cpp = input_path.read_text(encoding="utf-8")
save_cpp = save_path.read_text(encoding="utf-8")

V8_INIT = "// TSP_GL4ES_SOFTWARE_CURSOR_051_V8"
V8_VIS = "// TSP_GL4ES_SOFTWARE_CURSOR_VISIBILITY_051_V8"
V8_CHANGE = "// TSP_GL4ES_SOFTWARE_CURSOR_CHANGE_051_V8"
V8_GET = "// TSP_GL4ES_SOFTWARE_CURSOR_GET_VISIBLE_051_V8"

V9_CURSOR = "// TSP_MYGUI_CURSOR_INPUT_FORCE_051_V9"
V9_LOAD = "// TSP_LOAD_CONFIRM_A_START_051_V9"


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise RuntimeError(
            f"{label}: expected exactly one match, found {count}"
        )
    return text.replace(old, new, 1)


def replace_regex_once(text, pattern, replacement, label, flags=0):
    updated, count = re.subn(
        pattern,
        replacement,
        text,
        count=1,
        flags=flags,
    )
    if count != 1:
        raise RuntimeError(
            f"{label}: expected exactly one regex match, found {count}"
        )
    return updated


def write_transactionally(items):
    temp_paths = []

    try:
        for path, content in items:
            tmp = Path(str(path) + ".tsp-v9.tmp")
            tmp.write_text(content, encoding="utf-8")
            temp_paths.append((path, tmp))

        for path, tmp in temp_paths:
            os.replace(str(tmp), str(path))
    finally:
        for _, tmp in temp_paths:
            try:
                tmp.unlink()
            except FileNotFoundError:
                pass


# =====================================================================
# 1. RESTORE WINDOWMANAGER CURSOR LOGIC TO STOCK OPENMW 0.51
# =====================================================================

stock_init = """        // Create all cursors in advance
        createCursors();
        onCursorChange(MyGUI::PointerManager::getInstance().getDefaultPointer());
        mCursorManager->setEnabled(true);

        // hide mygui's pointer
        MyGUI::PointerManager::getInstance().setVisible(false);
"""

if V8_INIT in window:
    v8_init = """        // TSP_GL4ES_SOFTWARE_CURSOR_051_V8
        // The TSP display path does not reliably expose SDL's hardware cursor
        // plane. Render OpenMW's existing MyGUI pointer inside the framebuffer.
        //
        // Do not call createCursors(): that function only converts these same
        // pointer resources into SDL hardware cursors.
        mCursorManager->setEnabled(false);
        MyGUI::PointerManager::getInstance().setVisible(true);
        Log(Debug::Info)
            << "TSP GL4ES: MyGUI software cursor enabled; SDL hardware cursor disabled.";
"""
    window = replace_once(
        window,
        v8_init,
        stock_init,
        "restore stock cursor initialization",
    )
elif stock_init not in window:
    raise RuntimeError(
        "WindowManager cursor initialization is neither recognized v8 nor stock 0.51."
    )


stock_cursor_change = """    void WindowManager::onCursorChange(std::string_view name)
    {
        mCursorManager->cursorChanged(name);
    }
"""

if V8_CHANGE in window:
    pattern = (
        r"    void WindowManager::onCursorChange\(std::string_view /\*name\*/\)\n"
        r"    \{\n"
        r"        // TSP_GL4ES_SOFTWARE_CURSOR_CHANGE_051_V8\n"
        r".*?"
        r"    \}\n"
    )
    window = replace_regex_once(
        window,
        pattern,
        stock_cursor_change,
        "restore stock onCursorChange",
        flags=re.DOTALL,
    )
elif stock_cursor_change not in window:
    raise RuntimeError(
        "WindowManager::onCursorChange is neither recognized v8 nor stock 0.51."
    )


stock_visibility = """    void WindowManager::setCursorVisible(bool visible)
    {
        mCursorVisible = visible;
    }

    void WindowManager::setCursorActive(bool active)
    {
        mCursorActive = active;
    }
"""

if V8_VIS in window:
    pattern = (
        r"    void WindowManager::setCursorVisible\(bool visible\)\n"
        r"    \{\n"
        r".*?"
        r"    \}\n\n"
        r"    void WindowManager::setCursorActive\(bool active\)\n"
        r"    \{\n"
        r".*?"
        r"    \}\n"
    )
    window = replace_regex_once(
        window,
        pattern,
        stock_visibility,
        "restore stock cursor visibility bookkeeping",
        flags=re.DOTALL,
    )
elif stock_visibility not in window:
    raise RuntimeError(
        "WindowManager cursor visibility methods are neither recognized v8 nor stock 0.51."
    )


stock_get_visible = """    bool WindowManager::getCursorVisible()
    {
        return mCursorVisible && mCursorActive;
    }
"""

if V8_GET in window:
    v8_get_visible = """    bool WindowManager::getCursorVisible()
    {
        // TSP_GL4ES_SOFTWARE_CURSOR_GET_VISIBLE_051_V8
        return mCursorVisible;
    }
"""
    window = replace_once(
        window,
        v8_get_visible,
        stock_get_visible,
        "restore stock getCursorVisible",
    )
elif stock_get_visible not in window:
    raise RuntimeError(
        "WindowManager::getCursorVisible is neither recognized v8 nor stock 0.51."
    )


# =====================================================================
# 2. PROVEN TSP SOFTWARE-CURSOR LAYER: INPUTMANAGER
# =====================================================================

if "#include <MyGUI_PointerManager.h>" not in input_cpp:
    include_matches = list(
        re.finditer(r"^#include[^\n]*\n", input_cpp, flags=re.MULTILINE)
    )
    if not include_matches:
        raise RuntimeError(
            "inputmanagerimp.cpp: could not find include insertion point."
        )
    insertion = include_matches[-1].end()
    input_cpp = (
        input_cpp[:insertion]
        + "#include <MyGUI_PointerManager.h>\n"
        + input_cpp[insertion:]
    )

# Current TSP 0.51 audited input patch already has exactly two visibility
# mirrors. Replace the state-dependent condition with GUI-mode visibility.
old_pointer_call = (
    "MyGUI::PointerManager::getInstance().setVisible("
    "windowManager->getCursorVisible());"
)
new_pointer_call = (
    "MyGUI::PointerManager::getInstance().setVisible("
    "windowManager->isGuiMode());"
)

if V9_CURSOR not in input_cpp:
    count = input_cpp.count(old_pointer_call)

    if count != 2:
        raise RuntimeError(
            "inputmanagerimp.cpp: expected exactly two current MyGUI "
            f"cursor visibility calls, found {count}."
        )

    input_cpp = input_cpp.replace(
        old_pointer_call,
        new_pointer_call,
    )

    anchor = (
        "        // Stock OpenMW 0.51 already knows exactly when a GUI cursor should be\n"
    )

    if anchor in input_cpp:
        input_cpp = input_cpp.replace(
            anchor,
            "        " + V9_CURSOR + "\n"
            "        // Use the same layer that produced the working OpenMW 0.48\n"
            "        // TSP cursor: InputManager owns the final software-pointer\n"
            "        // visibility decision. In GUI mode the MyGUI pointer is always\n"
            "        // visible, independent of SDL hardware-cursor state.\n"
            + anchor,
            1,
        )
    else:
        # Still mark the source even if an earlier patch revision changed comments.
        function_anchor = (
            "    void InputManager::update(float dt, bool disableControls, bool disableEvents)\n"
            "    {\n"
        )
        if function_anchor not in input_cpp:
            raise RuntimeError(
                "inputmanagerimp.cpp: InputManager::update anchor not found."
            )
        input_cpp = input_cpp.replace(
            function_anchor,
            function_anchor
            + "        " + V9_CURSOR + "\n",
            1,
        )

# Ensure SDL hardware cursor is still forced off before capture and again
# after MouseManager::updateCursorMode().
if input_cpp.count("mInputWrapper->setMouseVisible(false);") < 2:
    raise RuntimeError(
        "inputmanagerimp.cpp: expected TSP SDL hardware-cursor suppression "
        "before and after stock cursor updates."
    )

if input_cpp.count(new_pointer_call) != 2:
    raise RuntimeError(
        "inputmanagerimp.cpp: v9 must have exactly two GUI-mode MyGUI "
        "visibility calls."
    )

# Preserve critical OpenMW 0.51 update calls.
for required_call in (
    "mControllerManager->update(dt);",
    "mActionManager->update(dt);",
    "Settings::input().mEnableGyroscope",
):
    if required_call not in input_cpp:
        raise RuntimeError(
            "inputmanagerimp.cpp lost required 0.51 update behavior: "
            + required_call
        )


# =====================================================================
# 3. LOAD GAME: A OR START ACCEPTS THE HIGHLIGHTED SLOT
# =====================================================================

if V9_LOAD not in save_cpp:
    function_anchor = """    bool SaveGameDialog::onControllerButtonEvent(const SDL_ControllerButtonEvent& arg)
    {
"""

    if save_cpp.count(function_anchor) != 1:
        raise RuntimeError(
            "savegamedialog.cpp: controller-handler anchor not found exactly once."
        )

    load_handler = """        // TSP_LOAD_CONFIRM_A_START_051_V9
        // Loading is list-driven on the TSP. A and Start both confirm the
        // currently highlighted save slot. Save mode keeps stock A behavior;
        // Start during text entry remains owned by the TSP text helper.
        if (!mSaving
            && (arg.button == SDL_CONTROLLER_BUTTON_A
                || arg.button == SDL_CONTROLLER_BUTTON_START))
        {
            if (mCurrentSlot)
            {
                accept();
                MWBase::Environment::get().getWindowManager()->playSound(
                    ESM::RefId::stringRefId("Menu Click"));
            }
            return true;
        }

"""

    save_cpp = save_cpp.replace(
        function_anchor,
        function_anchor + load_handler,
        1,
    )

# Keep stock A handler after our load-only interception so saving remains normal.
stock_a = "        if (arg.button == SDL_CONTROLLER_BUTTON_A)\n"
if stock_a not in save_cpp:
    raise RuntimeError(
        "savegamedialog.cpp: stock A-button handler disappeared."
    )

for token in (
    V9_LOAD,
    "SDL_CONTROLLER_BUTTON_START",
    "mCurrentSlot",
    "accept();",
):
    if token not in save_cpp:
        raise RuntimeError(
            "savegamedialog.cpp missing required v9 load-control token: "
            + token
        )


# =====================================================================
# FINAL VERIFICATION + ATOMIC WRITE
# =====================================================================

for old_marker in (
    V8_INIT,
    V8_VIS,
    V8_CHANGE,
    V8_GET,
):
    if old_marker in window:
        raise RuntimeError(
            "windowmanagerimp.cpp still contains v8 cursor marker: "
            + old_marker
        )

for stock_token in (
    "createCursors();",
    "mCursorManager->setEnabled(true);",
    "MyGUI::PointerManager::getInstance().setVisible(false);",
    "mCursorManager->cursorChanged(name);",
    "return mCursorVisible && mCursorActive;",
):
    if stock_token not in window:
        raise RuntimeError(
            "windowmanagerimp.cpp missing restored stock cursor token: "
            + stock_token
        )

if V9_CURSOR not in input_cpp:
    raise RuntimeError("inputmanagerimp.cpp missing v9 cursor marker.")

write_transactionally(
    (
        (window_path, window),
        (input_path, input_cpp),
        (save_path, save_cpp),
    )
)

print("v9 source patch applied:")
print(" ", window_path)
print(" ", input_path)
print(" ", save_path)
print()
print("WindowManager: stock OpenMW 0.51 cursor routing restored.")
print("InputManager: MyGUI pointer forced visible whenever GUI mode is active.")
print("Load Game: A and Start both accept the highlighted save.")
PY_PATCH

echo
echo "===== V9 VERIFICATION ====="

echo
echo "-- WindowManager stock cursor behavior --"
grep -n \
    -e 'createCursors();' \
    -e 'mCursorManager->setEnabled(true);' \
    -e 'mCursorManager->cursorChanged(name);' \
    -e 'return mCursorVisible && mCursorActive;' \
    "$WINDOW_CPP"

echo
echo "-- InputManager TSP software cursor --"
grep -n \
    -e 'TSP_MYGUI_CURSOR_INPUT_FORCE_051_V9' \
    -e 'setMouseVisible(false)' \
    -e 'setVisible(windowManager->isGuiMode())' \
    "$INPUT_CPP"

echo
echo "-- Load Game A + Start --"
grep -n \
    -e 'TSP_LOAD_CONFIRM_A_START_051_V9' \
    -e 'SDL_CONTROLLER_BUTTON_START' \
    "$SAVE_CPP"

if [ "$PATCH_ONLY" = "1" ]; then
    trap - ERR
    echo
    echo "PATCH_ONLY=1: source patch and verification completed."
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
    cp -f "$PACKAGE_BINARY" "$PACKAGE_BINARY.before-cursor-load-v9-$STAMP"
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

echo
echo "Binary verification:"
file "$PACKAGE_BINARY"
"$PACKAGE_BINARY" --version || true

trap - ERR

echo
echo "============================================================"
echo "SUCCESS: OpenMW 0.51 TSP cursor/load v9 built"
echo "============================================================"
echo "Standalone binary:"
echo "  $OUTPUT_BINARY"
echo
echo "Package binary:"
echo "  $PACKAGE_BINARY"
echo
echo "Source backup:"
echo "  $BACKUP_DIR"
echo
echo "Changes:"
echo "  - restored stock WindowManager cursor bookkeeping"
echo "  - SDL hardware cursor suppressed in InputManager"
echo "  - MyGUI pointer visible throughout GUI mode"
echo "  - Load Game A confirms highlighted save"
echo "  - Load Game Start confirms highlighted save"
echo
echo "NOT changed:"
echo "  - renderer / water / LOD"
echo "  - memory cleanup"
echo "  - navmesh generator/cache"
echo "  - controller text-entry helper"
echo "============================================================"
