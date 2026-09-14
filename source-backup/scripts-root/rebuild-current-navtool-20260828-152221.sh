#!/usr/bin/env bash
set -Eeuo pipefail

SRC='/root/openmw-0.51-tsp-src'
BUILD='/root/openmw-0.51-tsp-build'
RUN='/root/current-navtool-rebuild-20260828-152221'
LOG='/root/current-navtool-rebuild-20260828-152221/build.log'
STATUS='/root/current-navtool-rebuild-20260828-152221/status'
OUT='/root/current-navtool-rebuild-20260828-152221/output'

mkdir -p "$RUN" "$OUT"
rm -f "$STATUS"

finish_worker() {
    rc=$?
    trap - EXIT
    printf '%s\n' "$rc" > "$STATUS.tmp"
    mv -f "$STATUS.tmp" "$STATUS"
    sync
    exit "$rc"
}
trap finish_worker EXIT

exec </dev/null >"$LOG" 2>&1

echo "=================================================================="
echo "CURRENT OPENMW 0.51 NAVMESHTOOL BUILD"
echo "=================================================================="
date
echo "SRC=$SRC"
echo "BUILD=$BUILD"
echo

test -d "$SRC"
test -d "$BUILD"
test -s "$BUILD/CMakeCache.txt"

cache_value() {
    local key="$1"
    sed -n "s/^${key}:[^=]*=//p" "$BUILD/CMakeCache.txt" | head -1
}

C_BEFORE="$(cache_value CMAKE_C_COMPILER)"
CXX_BEFORE="$(cache_value CMAKE_CXX_COMPILER)"
SDL_BEFORE="$(cache_value SDL2_DIR)"
MYGUI_BEFORE="$(cache_value MyGUI_LIBRARY)"
TYPE_BEFORE="$(cache_value CMAKE_BUILD_TYPE)"
NAV_BEFORE="$(cache_value BUILD_NAVMESHTOOL)"

echo "Before reconfigure:"
echo "  BUILD_NAVMESHTOOL=$NAV_BEFORE"
echo "  C=$C_BEFORE"
echo "  CXX=$CXX_BEFORE"
echo "  SDL2_DIR=$SDL_BEFORE"
echo "  MyGUI_LIBRARY=$MYGUI_BEFORE"
echo "  BUILD_TYPE=$TYPE_BEFORE"

echo
echo "----- CURRENT SOURCE IDENTITY -----"
git -C "$SRC" rev-parse HEAD 2>/dev/null || true
git -C "$SRC" describe --always --dirty --tags 2>/dev/null || true
git -C "$SRC" status --short 2>/dev/null || true

echo
echo "----- ENABLE NAVMESHTOOL IN EXISTING BUILD TREE -----"
if [ "$NAV_BEFORE" != "ON" ]; then
    cmake -S "$SRC" -B "$BUILD" -DBUILD_NAVMESHTOOL=ON
else
    echo "BUILD_NAVMESHTOOL already ON."
fi

C_AFTER="$(cache_value CMAKE_C_COMPILER)"
CXX_AFTER="$(cache_value CMAKE_CXX_COMPILER)"
SDL_AFTER="$(cache_value SDL2_DIR)"
MYGUI_AFTER="$(cache_value MyGUI_LIBRARY)"
TYPE_AFTER="$(cache_value CMAKE_BUILD_TYPE)"
NAV_AFTER="$(cache_value BUILD_NAVMESHTOOL)"

echo
echo "After reconfigure:"
echo "  BUILD_NAVMESHTOOL=$NAV_AFTER"
echo "  C=$C_AFTER"
echo "  CXX=$CXX_AFTER"
echo "  SDL2_DIR=$SDL_AFTER"
echo "  MyGUI_LIBRARY=$MYGUI_AFTER"
echo "  BUILD_TYPE=$TYPE_AFTER"

[ "$NAV_AFTER" = "ON" ]

compare_if_known() {
    label="$1"
    before="$2"
    after="$3"
    if [ -n "$before" ] && [ "$before" != "$after" ]; then
        echo "ERROR: CMake reconfigure changed $label"
        echo "  before: $before"
        echo "  after:  $after"
        exit 31
    fi
}

compare_if_known "C compiler" "$C_BEFORE" "$C_AFTER"
compare_if_known "C++ compiler" "$CXX_BEFORE" "$CXX_AFTER"
compare_if_known "SDL2_DIR" "$SDL_BEFORE" "$SDL_AFTER"
compare_if_known "MyGUI_LIBRARY" "$MYGUI_BEFORE" "$MYGUI_AFTER"
compare_if_known "build type" "$TYPE_BEFORE" "$TYPE_AFTER"

echo
echo "----- VERIFY TARGET EXISTS -----"
TARGET_HELP="$(cmake --build "$BUILD" --target help 2>/dev/null || true)"
printf '%s\n' "$TARGET_HELP" | grep -F 'openmw-navmeshtool' >/dev/null || {
    echo "ERROR: openmw-navmeshtool target was not created."
    exit 32
}
echo "PASS: target exists."

echo
echo "----- FORCE ONLY NAVMESHTOOL EXECUTABLE TO RELINK -----"
if [ -f "$BUILD/openmw-navmeshtool" ]; then
    cp -p "$BUILD/openmw-navmeshtool" "$RUN/openmw-navmeshtool.before"
    sha256sum "$RUN/openmw-navmeshtool.before"
    rm -f "$BUILD/openmw-navmeshtool"
fi

echo
echo "----- BUILD NAVMESHTOOL ONLY, ONE JOB -----"
cmake --build "$BUILD" --target openmw-navmeshtool --parallel 1

NAVTOOL="$BUILD/openmw-navmeshtool"
if [ ! -x "$NAVTOOL" ]; then
    NAVTOOL="$(find "$BUILD" -type f -name openmw-navmeshtool -perm -111 -print -quit 2>/dev/null)"
fi

[ -n "${NAVTOOL:-}" ]
[ -x "$NAVTOOL" ]

echo
echo "----- VERIFY NEW ARTIFACT -----"
file "$NAVTOOL"
file "$NAVTOOL" | grep -Eiq 'ELF 64-bit.*(ARM aarch64|aarch64)' || {
    echo "ERROR: rebuilt navmeshtool is not ELF64 AArch64."
    exit 33
}

sha256sum "$NAVTOOL"
stat "$NAVTOOL"

cp -p "$NAVTOOL" "$OUT/openmw-navmeshtool"
cp -p "$SRC/files/settings-default.cfg" "$OUT/settings-default.current-source.cfg"

{
    echo "built=$(date)"
    echo "source_head=$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)"
    echo "source_describe=$(git -C "$SRC" describe --always --dirty --tags 2>/dev/null || true)"
    echo "navtool_sha=$(sha256sum "$NAVTOOL" | awk '{print $1}')"
    echo "settings_source_sha=$(sha256sum "$SRC/files/settings-default.cfg" | awk '{print $1}')"
    echo "camera_sha=$(sha256sum "$SRC/components/settings/categories/camera.hpp" | awk '{print $1}')"
    echo "build_navmeshtool=$NAV_AFTER"
    echo "c_compiler=$C_AFTER"
    echo "cxx_compiler=$CXX_AFTER"
} > "$OUT/BUILD_INFO.txt"

echo
echo "BUILD SUCCESS"
cat "$OUT/BUILD_INFO.txt"
