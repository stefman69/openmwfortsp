#!/bin/bash
set -Eeuo pipefail

# One-purpose repair for the OpenMW 0.51 final MyGUI link failure.
# Run inside the existing ARM64 Docker container as root.
#
# This script:
#   1. Preserves the completed OpenMW object files.
#   2. Builds a separate MyGUI 3.4.3 shared library for OpenMW 0.51.
#   3. Enables MYGUI_DONT_USE_OBSOLETE.
#   4. Disables MyGUI's hidden-visibility build mode.
#   5. Verifies that the required symbols are actually DEFINED/exported.
#   6. Reconfigures only the MyGUI library path in the existing OpenMW build.
#   7. Retries only the final OpenMW link.
#
# It does NOT delete:
#   /root/openmw-0.51-tsp-build
#   /root/openmw-0.51-tsp-src
#   /root/mygui-3.4.3-install

OPENMW_SRC="/root/openmw-0.51-tsp-src"
OPENMW_BUILD="/root/openmw-0.51-tsp-build"
OPENMW_PACKAGE="/root/openmw-0.51-tsp-package"

MYGUI_SRC="/root/mygui-3.4.3-src"
MYGUI_BUILD="/root/mygui-3.4.3-openmw051-gcc13-build"
MYGUI_PREFIX="/root/mygui-3.4.3-openmw051-gcc13-install"
MYGUI_HEADERS="/root/mygui-3.4.3-install/include/MYGUI"

CC_BIN="/usr/bin/gcc-13"
CXX_BIN="/usr/bin/g++-13"

JOBS="${OPENMW_JOBS:-$(nproc)}"
LOG="/root/openmw-0.51-mygui-link-repair.log"

exec > >(tee "$LOG") 2>&1

echo "=========================================="
echo "OpenMW 0.51 MyGUI final-link repair"
echo "Revision: mygui-separate-prefix-relink-2026-08-05"
echo "Architecture: $(uname -m)"
echo "Jobs: $JOBS"
echo "=========================================="

if [ "$(uname -m)" != "aarch64" ]; then
    echo "ERROR: Run this inside the ARM64/aarch64 Docker container."
    exit 1
fi

for required in \
    "$CC_BIN" \
    "$CXX_BIN" \
    "$OPENMW_SRC/CMakeLists.txt" \
    "$OPENMW_BUILD/CMakeCache.txt" \
    "$OPENMW_BUILD/build.ninja" \
    "$OPENMW_BUILD/apps/openmw/libopenmw-lib.a" \
    "$OPENMW_BUILD/components/libcomponents.a"
do
    if [ ! -e "$required" ]; then
        echo "ERROR: Required completed-build file is missing:"
        echo "  $required"
        exit 1
    fi
done

if [ ! -d "$MYGUI_HEADERS" ]; then
    echo "ERROR: Existing MyGUI headers are missing:"
    echo "  $MYGUI_HEADERS"
    exit 1
fi

echo
echo "Confirmed: completed OpenMW object libraries are present."
echo "They will not be deleted."

echo
echo "Preparing a clean MyGUI 3.4.3 source tree..."

if [ ! -d "$MYGUI_SRC/.git" ]; then
    rm -rf "$MYGUI_SRC"

    git clone \
        --branch MyGUI3.4.3 \
        --depth 1 \
        https://github.com/MyGUI/mygui.git \
        "$MYGUI_SRC"
else
    git -C "$MYGUI_SRC" fetch --tags --force origin MyGUI3.4.3
    git -C "$MYGUI_SRC" checkout -f MyGUI3.4.3
    git -C "$MYGUI_SRC" reset --hard MyGUI3.4.3
    git -C "$MYGUI_SRC" clean -fdx
fi

echo "MyGUI source revision:"
git -C "$MYGUI_SRC" describe --tags --always
git -C "$MYGUI_SRC" rev-parse HEAD

echo
echo "Creating a completely separate MyGUI build and install prefix..."

rm -rf \
    "$MYGUI_BUILD" \
    "$MYGUI_PREFIX"

mkdir -p \
    "$MYGUI_BUILD" \
    "$MYGUI_PREFIX"

cmake \
    -S "$MYGUI_SRC" \
    -B "$MYGUI_BUILD" \
    -G Ninja \
    -DCMAKE_C_COMPILER="$CC_BIN" \
    -DCMAKE_CXX_COMPILER="$CXX_BIN" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$MYGUI_PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DMYGUI_STATIC=OFF \
    -DMYGUI_DONT_USE_OBSOLETE=ON \
    -DMYGUI_GCC_VISIBILITY=FALSE \
    -DMYGUI_DISABLE_PLUGINS=ON \
    -DMYGUI_BUILD_PLUGINS=OFF \
    -DMYGUI_BUILD_DEMOS=OFF \
    -DMYGUI_BUILD_TOOLS=OFF \
    -DMYGUI_BUILD_UNITTESTS=OFF \
    -DMYGUI_BUILD_TEST_APP=OFF \
    -DMYGUI_BUILD_WRAPPER=OFF \
    -DMYGUI_INSTALL_DEMOS=OFF \
    -DMYGUI_INSTALL_TOOLS=OFF \
    -DMYGUI_INSTALL_DOCS=OFF \
    -DMYGUI_USE_FREETYPE=ON \
    -DMYGUI_MSDF_FONTS=OFF \
    -DMYGUI_RENDERSYSTEM=1

echo
echo "Verifying MyGUI configuration before compiling..."

grep -E \
    '^(CMAKE_CXX_COMPILER|MYGUI_DONT_USE_OBSOLETE|MYGUI_GCC_VISIBILITY|MYGUI_STATIC):' \
    "$MYGUI_BUILD/CMakeCache.txt" || true

MYGUI_OBSOLETE_VALUE="$(
    sed -n \
        's/^MYGUI_DONT_USE_OBSOLETE:[^=]*=//p' \
        "$MYGUI_BUILD/CMakeCache.txt" |
    head -1
)"

MYGUI_VISIBILITY_VALUE="$(
    sed -n \
        's/^MYGUI_GCC_VISIBILITY:[^=]*=//p' \
        "$MYGUI_BUILD/CMakeCache.txt" |
    head -1
)"

if [ "$MYGUI_OBSOLETE_VALUE" != "ON" ]; then
    echo "ERROR: MYGUI_DONT_USE_OBSOLETE is not ON."
    exit 1
fi

if [ "$MYGUI_VISIBILITY_VALUE" != "FALSE" ] && \
   [ "$MYGUI_VISIBILITY_VALUE" != "OFF" ]
then
    echo "ERROR: MyGUI hidden visibility was not disabled."
    echo "Value: ${MYGUI_VISIBILITY_VALUE:-missing}"
    exit 1
fi

MYGUI_COMMAND="$(
    ninja -C "$MYGUI_BUILD" -t commands MyGUIEngine |
    grep -m1 -F '/usr/bin/g++-13' || true
)"

if [ -z "$MYGUI_COMMAND" ]; then
    echo "ERROR: Could not find the MyGUIEngine GCC 13 compile command."
    exit 1
fi

echo "First MyGUI C++ command:"
echo "  $MYGUI_COMMAND"

case "$MYGUI_COMMAND" in
    *"-DMYGUI_DONT_USE_OBSOLETE"*)
        ;;
    *)
        echo "ERROR: MyGUI compile command lacks MYGUI_DONT_USE_OBSOLETE."
        exit 1
        ;;
esac

case "$MYGUI_COMMAND" in
    *"-fvisibility=hidden"*|*"-fvisibility-inlines-hidden"*)
        echo "ERROR: MyGUI compile command still enables hidden visibility."
        exit 1
        ;;
    *)
        echo "MyGUI compile command has default symbol visibility."
        ;;
esac

echo
echo "Building only MyGUIEngine..."

cmake --build "$MYGUI_BUILD" \
    --target MyGUIEngine \
    --parallel "$JOBS"

cmake --install "$MYGUI_BUILD"

MYGUI_LIBRARY="$MYGUI_PREFIX/lib/libMyGUIEngine.so.3.4.3"

if [ ! -f "$MYGUI_LIBRARY" ]; then
    echo "ERROR: New MyGUI library was not installed:"
    echo "  $MYGUI_LIBRARY"

    find "$MYGUI_PREFIX" \
        -maxdepth 4 \
        -name 'libMyGUIEngine.so*' \
        -print || true

    exit 1
fi

echo
echo "Verifying that the NEW library defines the missing symbols..."

SYMBOLS="/tmp/openmw051-mygui-defined-symbols.txt"

nm -D \
    --defined-only \
    -C \
    "$MYGUI_LIBRARY" > "$SYMBOLS"

check_symbol() {
    description="$1"
    pattern="$2"

    if grep -Fq "$pattern" "$SYMBOLS"; then
        echo "FOUND: $description"
    else
        echo "ERROR: New MyGUI library does not define:"
        echo "  $description"
        echo
        echo "Related exported symbols:"

        grep -E \
            'getLayerItem|resizeLayerItem|registerLoadXmlDelegate|_getItemCount|getContentSize' \
            "$SYMBOLS" || true

        exit 1
    fi
}

check_symbol \
    "Widget::getLayerItemByPoint non-virtual thunk" \
    "non-virtual thunk to MyGUI::Widget::getLayerItemByPoint(int, int) const"

check_symbol \
    "Widget::getLayerItemCoord non-virtual thunk" \
    "non-virtual thunk to MyGUI::Widget::getLayerItemCoord() const"

check_symbol \
    "Widget::resizeLayerItemView non-virtual thunk" \
    "non-virtual thunk to MyGUI::Widget::resizeLayerItemView("

check_symbol \
    "ResourceManager string_view XML delegate" \
    "MyGUI::ResourceManager::registerLoadXmlDelegate(std::basic_string_view<char"

rm -f "$SYMBOLS"

echo
echo "New MyGUI library passed all defined-symbol checks:"
echo "  $MYGUI_LIBRARY"

echo
echo "Pointing the EXISTING OpenMW build at the new MyGUI library..."
echo "The include directory remains unchanged, so completed C++ objects remain reusable."

cmake \
    -S "$OPENMW_SRC" \
    -B "$OPENMW_BUILD" \
    -DMyGUI_INCLUDE_DIR="$MYGUI_HEADERS" \
    -DMyGUI_LIBRARY="$MYGUI_LIBRARY"

CONFIGURED_MYGUI_LIBRARY="$(
    sed -n \
        's/^MyGUI_LIBRARY:[^=]*=//p' \
        "$OPENMW_BUILD/CMakeCache.txt" |
    head -1
)"

if [ "$CONFIGURED_MYGUI_LIBRARY" != "$MYGUI_LIBRARY" ]; then
    echo "ERROR: OpenMW CMake cache did not accept the new MyGUI library."
    echo "Selected: ${CONFIGURED_MYGUI_LIBRARY:-missing}"
    echo "Required: $MYGUI_LIBRARY"
    exit 1
fi

echo
echo "Checking the generated OpenMW link command..."

OPENMW_LINK_COMMAND="$(
    ninja -C "$OPENMW_BUILD" -t commands openmw |
    grep -F ' -o openmw ' |
    tail -1 || true
)"

if [ -z "$OPENMW_LINK_COMMAND" ]; then
    echo "ERROR: Could not locate the generated OpenMW link command."
    exit 1
fi

case "$OPENMW_LINK_COMMAND" in
    *"$MYGUI_LIBRARY"*)
        echo "OpenMW link command now uses the NEW MyGUI library."
        ;;
    *)
        echo "ERROR: OpenMW link command still uses the old MyGUI library."
        echo "$OPENMW_LINK_COMMAND"
        exit 1
        ;;
esac

echo
echo "Removing only the failed OpenMW executable output..."

rm -f "$OPENMW_BUILD/openmw"

echo
echo "Retrying only the remaining OpenMW build/link steps..."

cmake --build "$OPENMW_BUILD" \
    --target openmw \
    --parallel "$JOBS"

if [ ! -x "$OPENMW_BUILD/openmw" ]; then
    echo "ERROR: OpenMW still was not produced."
    exit 1
fi

echo
echo "Final link succeeded."

echo
echo "Installing OpenMW into the existing package directory..."

cmake --install "$OPENMW_BUILD" || true

mkdir -p \
    "$OPENMW_PACKAGE/bin" \
    "$OPENMW_PACKAGE/lib"

cp -f \
    "$OPENMW_BUILD/openmw" \
    "$OPENMW_PACKAGE/bin/openmw-0.51"

chmod +x "$OPENMW_PACKAGE/bin/openmw-0.51"

rm -f "$OPENMW_PACKAGE/lib"/libMyGUIEngine.so*

cp -a \
    "$MYGUI_PREFIX/lib"/libMyGUIEngine.so* \
    "$OPENMW_PACKAGE/lib/"

echo
echo "Result:"
file "$OPENMW_BUILD/openmw"
"$OPENMW_BUILD/openmw" --version || true

echo
echo "=========================================="
echo "SUCCESS: MyGUI repaired and OpenMW linked"
echo "=========================================="
echo "Binary:"
echo "  $OPENMW_BUILD/openmw"
echo "Packaged binary:"
echo "  $OPENMW_PACKAGE/bin/openmw-0.51"
echo "New MyGUI runtime:"
echo "  $MYGUI_PREFIX/lib/libMyGUIEngine.so.3.4.3"
echo "Log:"
echo "  $LOG"
