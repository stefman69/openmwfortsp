#!/bin/bash
set -Eeuo pipefail

# Continue after MyGUIEngine built successfully but cmake --install failed
# because the optional DummyPlatform target was not built.
#
# This script does NOT rebuild OpenMW or MyGUI.
# It uses the already-built MyGUIEngine and retries only the final OpenMW link.

OPENMW_SRC="/root/openmw-0.51-tsp-src"
OPENMW_BUILD="/root/openmw-0.51-tsp-build"
OPENMW_PACKAGE="/root/openmw-0.51-tsp-package"

MYGUI_BUILD="/root/mygui-3.4.3-openmw051-gcc13-build"
MYGUI_LIBRARY="$MYGUI_BUILD/lib/libMyGUIEngine.so.3.4.3"
MYGUI_HEADERS="/root/mygui-3.4.3-install/include/MYGUI"

LOG="/root/openmw-0.51-final-link.log"
JOBS="${OPENMW_JOBS:-$(nproc)}"

exec > >(tee "$LOG") 2>&1

echo "=========================================="
echo "OpenMW 0.51 final-link continuation"
echo "Revision: use-built-mygui-no-install-2026-08-05"
echo "=========================================="

for required in \
    "$OPENMW_SRC/CMakeLists.txt" \
    "$OPENMW_BUILD/CMakeCache.txt" \
    "$OPENMW_BUILD/build.ninja" \
    "$OPENMW_BUILD/apps/openmw/libopenmw-lib.a" \
    "$OPENMW_BUILD/components/libcomponents.a" \
    "$MYGUI_LIBRARY" \
    "$MYGUI_HEADERS/MyGUI.h"
do
    if [ ! -e "$required" ]; then
        echo "ERROR: Required file is missing:"
        echo "  $required"
        exit 1
    fi
done

echo
echo "Using the MyGUI library that already built successfully:"
echo "  $MYGUI_LIBRARY"

echo
echo "Verifying required MyGUI symbols are DEFINED..."

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
        echo "ERROR: The built MyGUI library does not define:"
        echo "  $description"
        echo
        echo "Related symbols found:"

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
echo "MyGUI symbol verification passed."

echo
echo "Reconfiguring the existing OpenMW build with this exact MyGUI library..."

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
    echo "ERROR: CMake did not select the new MyGUI library."
    echo "Selected: ${CONFIGURED_MYGUI_LIBRARY:-missing}"
    echo "Required: $MYGUI_LIBRARY"
    exit 1
fi

echo "CMake selected:"
echo "  $CONFIGURED_MYGUI_LIBRARY"

echo
echo "Verifying the generated final link command..."

LINK_COMMAND="$(
    ninja -C "$OPENMW_BUILD" -t commands openmw |
    grep -F ' -o openmw ' |
    tail -1 || true
)"

if [ -z "$LINK_COMMAND" ]; then
    echo "ERROR: Could not locate the OpenMW link command."
    exit 1
fi

case "$LINK_COMMAND" in
    *"$MYGUI_LIBRARY"*)
        echo "The OpenMW link command uses the newly built MyGUI library."
        ;;
    *)
        echo "ERROR: The link command still references another MyGUI library."
        echo "$LINK_COMMAND"
        exit 1
        ;;
esac

echo
echo "Removing only the failed executable output..."

rm -f "$OPENMW_BUILD/openmw"

echo
echo "Retrying only the remaining OpenMW link steps..."

cmake --build "$OPENMW_BUILD" \
    --target openmw \
    --parallel "$JOBS"

if [ ! -x "$OPENMW_BUILD/openmw" ]; then
    echo "ERROR: OpenMW was not produced."
    exit 1
fi

echo
echo "OpenMW linked successfully."

echo
echo "Packaging the binary and matching MyGUI runtime..."

mkdir -p \
    "$OPENMW_PACKAGE/bin" \
    "$OPENMW_PACKAGE/lib"

cp -f \
    "$OPENMW_BUILD/openmw" \
    "$OPENMW_PACKAGE/bin/openmw-0.51"

chmod +x "$OPENMW_PACKAGE/bin/openmw-0.51"

cp -Lf \
    "$MYGUI_LIBRARY" \
    "$OPENMW_PACKAGE/lib/libMyGUIEngine.so.3.4.3"

ln -sfn \
    libMyGUIEngine.so.3.4.3 \
    "$OPENMW_PACKAGE/lib/libMyGUIEngine.so"

patchelf \
    --set-rpath '$ORIGIN/../lib' \
    "$OPENMW_PACKAGE/bin/openmw-0.51"

echo
echo "Final verification:"

file "$OPENMW_PACKAGE/bin/openmw-0.51"

echo
echo "Runtime path:"

patchelf \
    --print-rpath \
    "$OPENMW_PACKAGE/bin/openmw-0.51"

echo
echo "MyGUI dependency:"

readelf -d \
    "$OPENMW_PACKAGE/bin/openmw-0.51" |
    grep -F 'libMyGUIEngine' || true

echo
echo "=========================================="
echo "SUCCESS"
echo "=========================================="
echo "Packaged binary:"
echo "  $OPENMW_PACKAGE/bin/openmw-0.51"
echo "Packaged MyGUI:"
echo "  $OPENMW_PACKAGE/lib/libMyGUIEngine.so.3.4.3"
echo "Log:"
echo "  $LOG"
