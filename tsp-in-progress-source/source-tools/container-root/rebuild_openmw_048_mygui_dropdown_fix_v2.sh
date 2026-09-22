#!/bin/bash
set -euo pipefail

# ============================================================
# OpenMW 0.48 / MyGUI visible dropdown repair
# ============================================================
#
# This keeps the existing patched OpenMW 0.48 source and build tree.
# It rebuilds MyGUI 3.4.2 with MYGUI_DONT_USE_OBSOLETE=OFF, then
# reconfigures and incrementally rebuilds the existing OpenMW binary.
#
# Existing OpenMW:
#   source: /root/openmw
#   build:  /root/openmw/build
#
# Separate fixed MyGUI:
#   source: /root/mygui-3.4.2-openmw048-dropdown-src
#   build:  /root/mygui-3.4.2-openmw048-dropdown-build
#   install:/root/mygui-3.4.2-openmw048-dropdown-install
#
# Output:
#   /root/openmw-0.48-dropdown-fix/
#   /root/openmw-0.48-dropdown-fix-aarch64.tar.gz
# ============================================================

OPENMW_SOURCE="${1:-/root/openmw}"
OPENMW_BUILD="${2:-$OPENMW_SOURCE/build}"

MYGUI_SOURCE="/root/mygui-3.4.2-openmw048-dropdown-src"
MYGUI_BUILD="/root/mygui-3.4.2-openmw048-dropdown-build"
MYGUI_PREFIX="/root/mygui-3.4.2-openmw048-dropdown-install"

OUTPUT_DIR="/root/openmw-0.48-dropdown-fix"
OUTPUT_ARCHIVE="/root/openmw-0.48-dropdown-fix-aarch64.tar.gz"

JOBS="${JOBS:-$(nproc)}"

echo "=========================================="
echo "OpenMW 0.48 visible dropdown repair"
echo "=========================================="
echo "OpenMW source: $OPENMW_SOURCE"
echo "OpenMW build:  $OPENMW_BUILD"
echo "MyGUI source:  $MYGUI_SOURCE"
echo "MyGUI build:   $MYGUI_BUILD"
echo "MyGUI install: $MYGUI_PREFIX"
echo "Jobs:          $JOBS"
echo "=========================================="
echo

for command in cmake git python3 file readelf; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "ERROR: Required command is missing: $command"
        exit 1
    fi
done

if ! command -v ninja >/dev/null 2>&1; then
    echo "ERROR: Ninja is required to build the separate MyGUI tree."
    exit 1
fi

if [ ! -f "$OPENMW_SOURCE/CMakeLists.txt" ]; then
    echo "ERROR: OpenMW source tree was not found:"
    echo "  $OPENMW_SOURCE"
    exit 1
fi

if [ ! -f "$OPENMW_BUILD/CMakeCache.txt" ]; then
    echo "ERROR: Existing OpenMW build cache was not found:"
    echo "  $OPENMW_BUILD/CMakeCache.txt"
    exit 1
fi

VERSION_MAJOR="$(
    sed -n \
        's/^[[:space:]]*set(OPENMW_VERSION_MAJOR[[:space:]]*\([0-9][0-9]*\)).*/\1/p' \
        "$OPENMW_SOURCE/CMakeLists.txt" |
    head -1
)"

VERSION_MINOR="$(
    sed -n \
        's/^[[:space:]]*set(OPENMW_VERSION_MINOR[[:space:]]*\([0-9][0-9]*\)).*/\1/p' \
        "$OPENMW_SOURCE/CMakeLists.txt" |
    head -1
)"

VERSION_RELEASE="$(
    sed -n \
        's/^[[:space:]]*set(OPENMW_VERSION_RELEASE[[:space:]]*\([0-9][0-9]*\)).*/\1/p' \
        "$OPENMW_SOURCE/CMakeLists.txt" |
    head -1
)"

echo "Detected OpenMW source version:"
echo "  ${VERSION_MAJOR:-?}.${VERSION_MINOR:-?}.${VERSION_RELEASE:-?}"
echo

if [ "${VERSION_MAJOR:-}" != "0" ] ||
   [ "${VERSION_MINOR:-}" != "48" ] ||
   [ "${VERSION_RELEASE:-}" != "0" ]
then
    echo "ERROR: This script is only for the existing OpenMW 0.48.0 tree."
    echo "The separate OpenMW 0.51 tree will not be touched."
    exit 1
fi

CACHE_VALUE() {
    local key="$1"

    sed -n \
        "s|^${key}:[^=]*=||p" \
        "$OPENMW_BUILD/CMakeCache.txt" |
    head -1
}

CC_BIN="$(CACHE_VALUE CMAKE_C_COMPILER)"
CXX_BIN="$(CACHE_VALUE CMAKE_CXX_COMPILER)"
BUILD_TYPE="$(CACHE_VALUE CMAKE_BUILD_TYPE)"

CC_BIN="${CC_BIN:-/usr/bin/cc}"
CXX_BIN="${CXX_BIN:-/usr/bin/c++}"
BUILD_TYPE="${BUILD_TYPE:-Release}"

if [ ! -x "$CC_BIN" ]; then
    echo "ERROR: Existing C compiler was not found:"
    echo "  $CC_BIN"
    exit 1
fi

if [ ! -x "$CXX_BIN" ]; then
    echo "ERROR: Existing C++ compiler was not found:"
    echo "  $CXX_BIN"
    exit 1
fi

echo "Existing OpenMW compiler configuration:"
echo "  C:          $CC_BIN"
echo "  C++:        $CXX_BIN"
echo "  Build type: $BUILD_TYPE"
echo

echo "Existing MyGUI selection in OpenMW cache:"
grep -E \
    '^(MyGUI_INCLUDE_DIR|MyGUI_LIBRARY):' \
    "$OPENMW_BUILD/CMakeCache.txt" || true
echo

echo "=========================================="
echo "Preparing MyGUI 3.4.2"
echo "=========================================="

if [ -d "$MYGUI_SOURCE/.git" ]; then
    git -C "$MYGUI_SOURCE" fetch --tags --force origin MyGUI3.4.2
    git -C "$MYGUI_SOURCE" checkout -f MyGUI3.4.2
    git -C "$MYGUI_SOURCE" reset --hard MyGUI3.4.2
    git -C "$MYGUI_SOURCE" clean -fdx
else
    rm -rf "$MYGUI_SOURCE"

    git clone \
        --branch MyGUI3.4.2 \
        --depth 1 \
        https://github.com/MyGUI/mygui.git \
        "$MYGUI_SOURCE"
fi

echo "MyGUI revision:"
git -C "$MYGUI_SOURCE" describe --tags --always
git -C "$MYGUI_SOURCE" rev-parse HEAD
echo

rm -rf "$MYGUI_BUILD" "$MYGUI_PREFIX"
mkdir -p "$MYGUI_BUILD" "$MYGUI_PREFIX"

echo "=========================================="
echo "Configuring MyGUI"
echo "=========================================="
echo "Critical setting:"
echo "  MYGUI_DONT_USE_OBSOLETE=OFF"
echo

cmake \
    -S "$MYGUI_SOURCE" \
    -B "$MYGUI_BUILD" \
    -G Ninja \
    -DCMAKE_C_COMPILER="$CC_BIN" \
    -DCMAKE_CXX_COMPILER="$CXX_BIN" \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DCMAKE_INSTALL_PREFIX="$MYGUI_PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_SHARED_LIBS=ON \
    -DMYGUI_STATIC=OFF \
    -DMYGUI_DONT_USE_OBSOLETE=OFF \
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
    -DMYGUI_RENDERSYSTEM=1 \
    -DMYGUI_BUILD_RENDERSYSTEMS=1

echo
echo "MyGUI cache verification:"
grep -E \
    '^(CMAKE_CXX_COMPILER|MYGUI_DONT_USE_OBSOLETE|MYGUI_GCC_VISIBILITY|MYGUI_STATIC):' \
    "$MYGUI_BUILD/CMakeCache.txt" || true
echo

MYGUI_OBSOLETE_VALUE="$(
    sed -n \
        's/^MYGUI_DONT_USE_OBSOLETE:[^=]*=//p' \
        "$MYGUI_BUILD/CMakeCache.txt" |
    head -1
)"

if [ "$MYGUI_OBSOLETE_VALUE" != "OFF" ]; then
    echo "ERROR: MyGUI was not configured with obsolete properties enabled."
    echo "Expected MYGUI_DONT_USE_OBSOLETE=OFF."
    exit 1
fi

echo "Building and installing MyGUI 3.4.2..."
cmake --build "$MYGUI_BUILD" --parallel "$JOBS"
cmake --install "$MYGUI_BUILD"

MYGUI_HEADERS="$MYGUI_PREFIX/include/MYGUI"
MYGUI_LIBRARY="$(
    find "$MYGUI_PREFIX/lib" \
        -maxdepth 1 \
        \( -type f -o -type l \) \
        -name 'libMyGUIEngine.so.3.4.2' \
        -print |
    head -1
)"

if [ ! -d "$MYGUI_HEADERS" ]; then
    echo "ERROR: Fixed MyGUI headers were not installed:"
    echo "  $MYGUI_HEADERS"
    exit 1
fi

if [ -z "$MYGUI_LIBRARY" ] || [ ! -e "$MYGUI_LIBRARY" ]; then
    echo "ERROR: Fixed MyGUI engine library was not installed."
    find "$MYGUI_PREFIX" -name 'libMyGUIEngine.so*' -print || true
    exit 1
fi

echo
echo "Fixed MyGUI headers:"
echo "  $MYGUI_HEADERS"
echo "Fixed MyGUI library:"
echo "  $MYGUI_LIBRARY"
file "$MYGUI_LIBRARY"
echo

echo "=========================================="
echo "Reconfiguring existing OpenMW 0.48 build"
echo "=========================================="

cmake \
    -S "$OPENMW_SOURCE" \
    -B "$OPENMW_BUILD" \
    -DMyGUI_INCLUDE_DIR="$MYGUI_HEADERS" \
    -DMyGUI_LIBRARY="$MYGUI_LIBRARY"

echo
echo "OpenMW cache after MyGUI replacement:"
grep -E \
    '^(MyGUI_INCLUDE_DIR|MyGUI_LIBRARY):' \
    "$OPENMW_BUILD/CMakeCache.txt" || true
echo

SELECTED_MYGUI_LIBRARY="$(CACHE_VALUE MyGUI_LIBRARY)"
SELECTED_MYGUI_INCLUDE="$(CACHE_VALUE MyGUI_INCLUDE_DIR)"

if [ "$SELECTED_MYGUI_LIBRARY" != "$MYGUI_LIBRARY" ]; then
    echo "ERROR: OpenMW cache did not select the fixed MyGUI library."
    echo "Selected: ${SELECTED_MYGUI_LIBRARY:-missing}"
    echo "Wanted:   $MYGUI_LIBRARY"
    exit 1
fi

if [ "$SELECTED_MYGUI_INCLUDE" != "$MYGUI_HEADERS" ]; then
    echo "ERROR: OpenMW cache did not select the fixed MyGUI headers."
    echo "Selected: ${SELECTED_MYGUI_INCLUDE:-missing}"
    echo "Wanted:   $MYGUI_HEADERS"
    exit 1
fi

echo "Incrementally rebuilding the patched OpenMW 0.48 executable..."
cmake --build \
    "$OPENMW_BUILD" \
    --target openmw \
    --parallel "$JOBS"

OPENMW_BINARY="$OPENMW_BUILD/openmw"

if [ ! -x "$OPENMW_BINARY" ]; then
    echo "ERROR: Rebuilt OpenMW executable was not found:"
    echo "  $OPENMW_BINARY"
    exit 1
fi

echo
echo "Rebuilt OpenMW binary:"
file "$OPENMW_BINARY"
echo

echo "Dynamic MyGUI dependency:"
readelf -d "$OPENMW_BINARY" |
    grep -E 'NEEDED.*MyGUIEngine' || true
echo

echo "=========================================="
echo "Creating runtime export"
echo "=========================================="

rm -rf "$OUTPUT_DIR" "$OUTPUT_ARCHIVE"
mkdir -p "$OUTPUT_DIR/lib"

cp -f "$OPENMW_BINARY" "$OUTPUT_DIR/openmw"
cp -a "$MYGUI_PREFIX/lib"/libMyGUIEngine.so* "$OUTPUT_DIR/lib/"

cat > "$OUTPUT_DIR/INSTALL.txt" <<'EOF_INSTALL'
OpenMW 0.48 visible-dropdown repair

Copy:
  openmw
to:
  D:\Data\ports\openmw\openmw

Copy every:
  lib\libMyGUIEngine.so*
to:
  D:\Data\ports\openmw\lib\

Replace the existing MyGUIEngine files with these matching files.

This binary preserves the source patches already present in /root/openmw.
The MyGUI library was rebuilt with:
  MYGUI_DONT_USE_OBSOLETE=OFF

After installation, remove this obsolete experimental override if present:
  D:\Data\ports\openmw\savegame\data\mygui\openmw_savegame_dialog.layout

Use the previously functional launcher rather than the temporary dropdown
layout override. The MyGUI repair fixes dropdown/list item height globally.
EOF_INSTALL

tar \
    -C "$(dirname "$OUTPUT_DIR")" \
    -czf "$OUTPUT_ARCHIVE" \
    "$(basename "$OUTPUT_DIR")"

echo
echo "=========================================="
echo "Dropdown repair build completed"
echo "=========================================="
echo "Export directory:"
echo "  $OUTPUT_DIR"
echo
echo "Export archive:"
echo "  $OUTPUT_ARCHIVE"
echo
echo "Files to install on SD:"
find "$OUTPUT_DIR" -maxdepth 2 -type f -o -type l | sort
echo "=========================================="
