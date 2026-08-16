#!/bin/bash
set -Eeuo pipefail

# OpenMW 0.51 TrimUI Smart Pro resumable build/package script.
# Run INSIDE the existing ARM64 Docker container as root.
#
# Reuses completed dependencies:
#   /root/mygui-3.4.3-install
#   /root/sdl2-2.30.12-install
#   /usr/local OpenSceneGraph 3.6.5
#   /root/openmw-0.51-tsp-src
#
# Preserves the OpenMW build directory after compilation failures so Ninja
# can resume from already completed C and C++ object files.
#
# Output:
#   /root/openmw-0.51-tsp-package/
#   /root/openmw-0.51-tsp-build.log
#   /root/openmw-0.51-tsp-build.exitcode

TAG="${OPENMW_TAG:-openmw-0.51.0}"

SCRIPT_REVISION="v4-gcc13-format-cacheguard-2026-08-05"
TOOLCHAIN_MAJOR="13"

SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"
PACKAGE="/root/openmw-0.51-tsp-package"

MYGUI_SRC="/root/mygui-3.4.3-src"
MYGUI_BUILD="/root/mygui-3.4.3-build"
MYGUI_PREFIX="/root/mygui-3.4.3-install"

SDL_PREFIX="/root/sdl2-2.30.12-install"
SDL2_DIR="$SDL_PREFIX/lib/cmake/SDL2"

LOG="/root/openmw-0.51-tsp-build.log"
EXITCODE="/root/openmw-0.51-tsp-build.exitcode"

JOBS="${OPENMW_JOBS:-$(nproc)}"

exec > >(tee "$LOG") 2>&1

finish() {
    result=$?

    echo "$result" > "$EXITCODE"

    echo
    echo "=========================================="
    echo "Build script exit code: $result"
    echo "Log:      $LOG"
    echo "Exitcode: $EXITCODE"
    echo "Package:  $PACKAGE"
    echo "=========================================="
}

trap finish EXIT

echo "=========================================="
echo "OpenMW 0.51 TrimUI Smart Pro build"
echo "Date: $(date)"
echo "Architecture: $(uname -m)"
echo "Tag: $TAG"
echo "Script: $(readlink -f "$0")"
echo "Script revision: $SCRIPT_REVISION"
echo "Required toolchain: GCC $TOOLCHAIN_MAJOR"
echo "Parallel jobs: $JOBS"
echo "=========================================="

if [ "$(uname -m)" != "aarch64" ]; then
    echo "ERROR: This must run inside the ARM64/aarch64 Docker container."
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo
echo "Adding the GCC $TOOLCHAIN_MAJOR repository when necessary..."

apt-get update

apt-get install -y \
    software-properties-common

if ! grep -Rqs \
    'ubuntu-toolchain-r/test' \
    /etc/apt/sources.list \
    /etc/apt/sources.list.d 2>/dev/null
then
    add-apt-repository -y ppa:ubuntu-toolchain-r/test
fi

echo
echo "Installing/confirming build tools..."

apt-get update

apt-get install -y \
    git \
    cmake \
    ninja-build \
    make \
    "gcc-$TOOLCHAIN_MAJOR" \
    "g++-$TOOLCHAIN_MAJOR" \
    python3 \
    pkg-config \
    patchelf \
    rsync \
    ca-certificates \
    libfreetype6-dev \
    zlib1g-dev \
    libx11-dev \
    libgl1-mesa-dev

echo
echo "Selecting GCC $TOOLCHAIN_MAJOR for OpenMW 0.51..."

CC_BIN="/usr/bin/gcc-$TOOLCHAIN_MAJOR"
CXX_BIN="/usr/bin/g++-$TOOLCHAIN_MAJOR"

if [ ! -x "$CC_BIN" ]; then
    echo "ERROR: GCC $TOOLCHAIN_MAJOR C compiler was not installed:"
    echo "  $CC_BIN"
    exit 1
fi

if [ ! -x "$CXX_BIN" ]; then
    echo "ERROR: GCC $TOOLCHAIN_MAJOR C++ compiler was not installed:"
    echo "  $CXX_BIN"
    exit 1
fi

echo "C compiler:"
"$CC_BIN" --version | head -1

echo "C++ compiler:"
"$CXX_BIN" --version | head -1

echo
echo "Testing the exact C++20 features required by OpenMW 0.51..."

cat > /tmp/openmw-cxx20-test.cpp <<'CPP'
#include <array>
#include <concepts>
#include <format>
#include <span>
#include <string>

template<typename T>
concept Number = requires(T value)
{
    value + value;
};

constexpr std::size_t constexprStringSize()
{
    std::string value = "OpenMW";
    return value.size();
}

int main()
{
    std::array<int, 3> values{1, 2, 3};
    std::span<int> view(values);

    static_assert(Number<int>);
    static_assert(constexprStringSize() == 6);

    const std::string formatted = std::format("OpenMW {}", 51);

    return view.size() == 3 && formatted == "OpenMW 51" ? 0 : 1;
}
CPP

"$CXX_BIN" \
    -std=c++20 \
    /tmp/openmw-cxx20-test.cpp \
    -o /tmp/openmw-cxx20-test

/tmp/openmw-cxx20-test

rm -f \
    /tmp/openmw-cxx20-test.cpp \
    /tmp/openmw-cxx20-test

echo "C++20 <format> and constexpr std::string test passed."

export CC="$CC_BIN"
export CXX="$CXX_BIN"

echo
echo "Checking core dependencies already used by the 0.48 build..."

for pkg in \
    sdl2 \
    openal \
    bullet \
    osg \
    mygui \
    lua5.1 \
    luajit \
    yaml-cpp
do
    if pkg-config --exists "$pkg" 2>/dev/null; then
        echo \
            "FOUND pkg-config: $pkg" \
            "$(pkg-config --modversion "$pkg" 2>/dev/null || true)"
    else
        echo "NOTE: pkg-config entry not found: $pkg"
    fi
done

echo
echo "Locating the patched OSG installation..."

OSG_PREFIX=""
OSG_LIBRARY=""
OSG_HEADER=""

for candidate in \
    /root/osg-install \
    /root/osg-3.6.5-install \
    /root/openmw-deps \
    /root/openmw-0.48-package \
    /root/openmw-package \
    /opt/osg \
    /usr/local \
    /usr
do
    [ -e "$candidate" ] || continue

    library="$(
        find "$candidate" \
            \( -type f -o -type l \) \
            -name 'libosg.so*' \
            -print 2>/dev/null |
        head -1
    )"

    header="$(
        find "$candidate" \
            -type f \
            \( \
                -path '*/include/osg/Version' \
                -o \
                -path '*/include/osg/Version.in' \
            \) \
            -print 2>/dev/null |
        head -1
    )"

    if [ -n "$library" ] && [ -n "$header" ]; then
        OSG_LIBRARY="$library"
        OSG_HEADER="$header"
        OSG_PREFIX="$candidate"
        break
    fi
done

if [ -z "$OSG_PREFIX" ]; then
    echo "Likely OSG prefixes did not match."
    echo "Searching the complete container filesystem..."

    OSG_LIBRARY="$(
        find / \
            \( \
                -path /proc \
                -o -path /sys \
                -o -path /dev \
                -o -path /run \
            \) \
            -prune \
            -o \
            \( -type f -o -type l \) \
            -name 'libosg.so*' \
            -print 2>/dev/null |
        head -1
    )"

    OSG_HEADER="$(
        find / \
            \( \
                -path /proc \
                -o -path /sys \
                -o -path /dev \
                -o -path /run \
            \) \
            -prune \
            -o \
            -type f \
            \( \
                -path '*/include/osg/Version' \
                -o \
                -path '*/include/osg/Version.in' \
            \) \
            -print 2>/dev/null |
        head -1
    )"

    if [ -n "$OSG_LIBRARY" ] && [ -n "$OSG_HEADER" ]; then
        OSG_LIB_DIR="$(dirname "$OSG_LIBRARY")"
        OSG_INCLUDE_DIR="$(dirname "$(dirname "$OSG_HEADER")")"
        OSG_PREFIX="$(dirname "$OSG_LIB_DIR")"
    fi
fi

if [ -z "$OSG_LIBRARY" ] || [ -z "$OSG_HEADER" ]; then
    echo "ERROR: Could not locate both the OSG library and OSG headers."

    echo
    echo "Libraries found:"

    find \
        /root \
        /usr/local \
        /usr \
        /opt \
        \( -type f -o -type l \) \
        -name 'libosg.so*' \
        -print 2>/dev/null || true

    echo
    echo "Headers found:"

    find \
        /root \
        /usr/local \
        /usr \
        /opt \
        -type f \
        \( \
            -path '*/include/osg/Version' \
            -o \
            -path '*/include/osg/Version.in' \
        \) \
        -print 2>/dev/null || true

    exit 1
fi

OSG_LIB_DIR="$(dirname "$OSG_LIBRARY")"
OSG_INCLUDE_DIR="$(dirname "$(dirname "$OSG_HEADER")")"

echo "OSG library: $OSG_LIBRARY"
echo "OSG headers: $OSG_INCLUDE_DIR"
echo "OSG prefix candidate: $OSG_PREFIX"

export CMAKE_PREFIX_PATH="$OSG_PREFIX:/usr/local:/usr:${CMAKE_PREFIX_PATH:-}"

export PKG_CONFIG_PATH="$OSG_LIB_DIR/pkgconfig:$OSG_PREFIX/lib/pkgconfig:$OSG_PREFIX/lib/aarch64-linux-gnu/pkgconfig:/usr/local/lib/pkgconfig:/usr/local/lib/aarch64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"

export LD_LIBRARY_PATH="$OSG_LIB_DIR:$OSG_PREFIX/lib:$OSG_PREFIX/lib/aarch64-linux-gnu:/usr/local/lib:/usr/local/lib/aarch64-linux-gnu:${LD_LIBRARY_PATH:-}"

echo
echo "=========================================="
echo "Checking MyGUI 3.4.3"
echo "=========================================="

MYGUI_LIBRARY="$(
    find "$MYGUI_PREFIX" \
        \( -type f -o -type l \) \
        -name 'libMyGUIEngine.so*' \
        -print 2>/dev/null |
    head -1
)"

MYGUI_INCLUDE_DIR="$MYGUI_PREFIX/include/MYGUI"

if [ -n "$MYGUI_LIBRARY" ] && [ -d "$MYGUI_INCLUDE_DIR" ]; then
    echo "MyGUI 3.4.3 is already installed."
    echo "Skipping MyGUI clone, configure, build, and install."
else
    echo "MyGUI 3.4.3 installation is missing or incomplete."
    echo "Building MyGUI 3.4.3 now."

    rm -rf \
        "$MYGUI_SRC" \
        "$MYGUI_BUILD" \
        "$MYGUI_PREFIX"

    git clone \
        --branch MyGUI3.4.3 \
        --depth 1 \
        https://github.com/MyGUI/mygui.git \
        "$MYGUI_SRC"

    echo "MyGUI revision:"
    git -C "$MYGUI_SRC" describe --tags --always
    git -C "$MYGUI_SRC" rev-parse HEAD

    mkdir -p \
        "$MYGUI_BUILD" \
        "$MYGUI_PREFIX"

    cmake \
        -S "$MYGUI_SRC" \
        -B "$MYGUI_BUILD" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$MYGUI_PREFIX" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DBUILD_SHARED_LIBS=ON \
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

    cmake --build "$MYGUI_BUILD" \
        --parallel "$JOBS"

    cmake --install "$MYGUI_BUILD"

    MYGUI_LIBRARY="$(
        find "$MYGUI_PREFIX" \
            \( -type f -o -type l \) \
            -name 'libMyGUIEngine.so*' \
            -print 2>/dev/null |
        head -1
    )"

    MYGUI_INCLUDE_DIR="$MYGUI_PREFIX/include/MYGUI"
fi

if [ -z "$MYGUI_LIBRARY" ] || [ ! -d "$MYGUI_INCLUDE_DIR" ]; then
    echo "ERROR: MyGUI 3.4.3 is not installed correctly."
    echo "Library: ${MYGUI_LIBRARY:-not found}"
    echo "Include: $MYGUI_INCLUDE_DIR"

    find "$MYGUI_PREFIX" \
        -maxdepth 4 \
        -print 2>/dev/null || true

    exit 1
fi

echo "MyGUI library: $MYGUI_LIBRARY"
echo "MyGUI headers: $MYGUI_INCLUDE_DIR"

MYGUI_VERSION_HEADER="$MYGUI_INCLUDE_DIR/MyGUI_Prerequest.h"

if [ -f "$MYGUI_VERSION_HEADER" ]; then
    grep -E \
        'MYGUI_VERSION_(MAJOR|MINOR|PATCH)' \
        "$MYGUI_VERSION_HEADER" || true
fi

export CMAKE_PREFIX_PATH="$MYGUI_PREFIX:$CMAKE_PREFIX_PATH"
export PKG_CONFIG_PATH="$MYGUI_PREFIX/lib/pkgconfig:$PKG_CONFIG_PATH"
export LD_LIBRARY_PATH="$MYGUI_PREFIX/lib:$LD_LIBRARY_PATH"

echo
echo "=========================================="
echo "Checking SDL2 2.30.12"
echo "=========================================="

if [ ! -f "$SDL2_DIR/SDL2Config.cmake" ]; then
    echo "ERROR: The custom SDL2 installation is missing:"
    echo "  $SDL2_DIR/SDL2Config.cmake"

    echo
    echo "Contents of the SDL2 prefix:"

    find "$SDL_PREFIX" \
        -maxdepth 5 \
        -print 2>/dev/null || true

    exit 1
fi

if [ ! -f "$SDL2_DIR/SDL2ConfigVersion.cmake" ]; then
    echo "ERROR: SDL2ConfigVersion.cmake is missing:"
    echo "  $SDL2_DIR/SDL2ConfigVersion.cmake"
    exit 1
fi

SDL2_LIBRARY="$(
    find "$SDL_PREFIX/lib" \
        \( -type f -o -type l \) \
        \( \
            -name 'libSDL2-2.0.so*' \
            -o \
            -name 'libSDL2.so*' \
        \) \
        -print 2>/dev/null |
    head -1
)"

if [ -z "$SDL2_LIBRARY" ]; then
    echo "ERROR: The custom SDL2 shared library is missing."

    find "$SDL_PREFIX/lib" \
        -maxdepth 4 \
        -print 2>/dev/null || true

    exit 1
fi

SDL2_INCLUDE_DIR=""

for candidate in \
    "$SDL_PREFIX/include/SDL2" \
    "$SDL_PREFIX/include"
do
    if [ -f "$candidate/SDL.h" ]; then
        SDL2_INCLUDE_DIR="$candidate"
        break
    fi
done

if [ -z "$SDL2_INCLUDE_DIR" ]; then
    echo "ERROR: SDL.h was not found under:"
    echo "  $SDL_PREFIX/include"

    find "$SDL_PREFIX/include" \
        -maxdepth 3 \
        -print 2>/dev/null || true

    exit 1
fi

echo "SDL2 CMake directory: $SDL2_DIR"
echo "SDL2 library: $SDL2_LIBRARY"
echo "SDL2 include directory: $SDL2_INCLUDE_DIR"

if [ -f "$SDL_PREFIX/lib/pkgconfig/sdl2.pc" ]; then
    echo -n "SDL2 version: "

    PKG_CONFIG_PATH="$SDL_PREFIX/lib/pkgconfig" \
        pkg-config --modversion sdl2
fi

export CMAKE_PREFIX_PATH="$SDL_PREFIX:$CMAKE_PREFIX_PATH"
export PKG_CONFIG_PATH="$SDL_PREFIX/lib/pkgconfig:$PKG_CONFIG_PATH"
export LD_LIBRARY_PATH="$SDL_PREFIX/lib:$LD_LIBRARY_PATH"

echo
echo "=========================================="
echo "Checking OpenMW source"
echo "=========================================="

if [ -d "$SRC/.git" ] && \
   git -C "$SRC" rev-parse --verify HEAD >/dev/null 2>&1
then
    echo "OpenMW source already exists."
    echo "Reusing:"
    echo "  $SRC"
else
    echo "OpenMW source is missing or incomplete."
    echo "Cloning $TAG..."

    rm -rf "$SRC"

    git clone \
        --branch "$TAG" \
        --depth 1 \
        https://gitlab.com/OpenMW/openmw.git \
        "$SRC"
fi

cd "$SRC"

echo "Revision:"
git describe --tags --always
git rev-parse HEAD

echo
echo "Applying TrimUI/GL4ES source safeguards..."

python3 - "$SRC" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
patched = []

patterns = [
    re.compile(
        r'(?P<indent>[ \t]*)'
        r'glGetIntegerv\('
        r'\s*GL_MAX_TEXTURE_IMAGE_UNITS\s*,'
        r'\s*&(?P<var>[A-Za-z_][A-Za-z0-9_]*)\s*'
        r'\);'
    ),
    re.compile(
        r'(?P<indent>[ \t]*)'
        r'GLint\s+'
        r'(?P<var>[A-Za-z_][A-Za-z0-9_]*)'
        r'\s*=\s*0\s*;\s*\n'
        r'(?P=indent)'
        r'glGetIntegerv\('
        r'\s*GL_MAX_TEXTURE_IMAGE_UNITS\s*,'
        r'\s*&(?P=var)\s*'
        r'\);'
    ),
]

for path in root.rglob("*"):
    if path.suffix not in {
        ".cpp",
        ".cxx",
        ".cc",
        ".c",
        ".hpp",
        ".h",
    }:
        continue

    try:
        text = path.read_text(encoding="utf-8")
    except Exception:
        continue

    if "GL_MAX_TEXTURE_IMAGE_UNITS" not in text:
        continue

    if "using GLES2 minimum fallback of 8" in text:
        continue

    original = text
    match = patterns[0].search(text)

    if match:
        indent = match.group("indent")
        variable = match.group("var")

        replacement = (
            match.group(0)
            + "\n"
            + indent
            + f"if ({variable} <= 0)\n"
            + indent
            + "{\n"
            + indent
            + f'    Log(Debug::Warning) '
            f'<< "GL_MAX_TEXTURE_IMAGE_UNITS returned " '
            f'<< {variable}\n'
            + indent
            + '                        '
            '<< "; using GLES2 minimum fallback of 8";\n'
            + indent
            + f"    {variable} = 8;\n"
            + indent
            + "}"
        )

        text = (
            text[:match.start()]
            + replacement
            + text[match.end():]
        )

    if text != original:
        path.write_text(text, encoding="utf-8")
        patched.append(str(path.relative_to(root)))

print("Texture-unit fallback patched files:")

if patched:
    for item in patched:
        print("  " + item)
else:
    print("  No matching source query was patched.")
    print(
        "  This can be normal if 0.51 already validates "
        "the value upstream."
    )
PY

echo
echo "Checking for the fallback marker..."

grep -R \
    --line-number \
    --include='*.cpp' \
    --include='*.cxx' \
    --include='*.cc' \
    'using GLES2 minimum fallback of 8' \
    "$SRC" || true

echo
echo "=========================================="
echo "Preparing resumable OpenMW build"
echo "=========================================="

# A build tree generated by an older script can keep compiler paths in both
# CMakeCache.txt and build.ninja. Remove it automatically if either file
# references any compiler other than the required GCC toolchain.
if [ -d "$BUILD" ]; then
    STALE_TOOLCHAIN_REFERENCE="$(
        grep -hE             '/usr/bin/(gcc|g\+\+)-[0-9]+'             "$BUILD/CMakeCache.txt"             "$BUILD/build.ninja"             2>/dev/null |
        grep -vF "$CC_BIN" |
        grep -vF "$CXX_BIN" |
        head -1 || true
    )"

    if [ -n "$STALE_TOOLCHAIN_REFERENCE" ]; then
        echo "Old compiler reference found in the OpenMW build tree:"
        echo "  $STALE_TOOLCHAIN_REFERENCE"
        echo
        echo "Removing only the stale OpenMW build directory:"
        echo "  $BUILD"

        rm -rf "$BUILD"
    fi
fi

if [ -f "$BUILD/CMakeCache.txt" ]; then
    CACHED_C_COMPILER="$(
        sed -n \
            's/^CMAKE_C_COMPILER:[^=]*=//p' \
            "$BUILD/CMakeCache.txt" |
        head -1
    )"

    CACHED_CXX_COMPILER="$(
        sed -n \
            's/^CMAKE_CXX_COMPILER:[^=]*=//p' \
            "$BUILD/CMakeCache.txt" |
        head -1
    )"

    CACHED_SDL2_DIR="$(
        sed -n \
            's/^SDL2_DIR:[^=]*=//p' \
            "$BUILD/CMakeCache.txt" |
        head -1
    )"

    CLEAR_BUILD=0

    if [ "$CACHED_C_COMPILER" != "$CC_BIN" ]; then
        echo "C compiler cache mismatch:"
        echo "  Cached:   ${CACHED_C_COMPILER:-unknown}"
        echo "  Required: $CC_BIN"
        CLEAR_BUILD=1
    fi

    if [ "$CACHED_CXX_COMPILER" != "$CXX_BIN" ]; then
        echo "C++ compiler cache mismatch:"
        echo "  Cached:   ${CACHED_CXX_COMPILER:-unknown}"
        echo "  Required: $CXX_BIN"
        CLEAR_BUILD=1
    fi

    if [ -n "$CACHED_SDL2_DIR" ] && \
       [ "$CACHED_SDL2_DIR" != "$SDL2_DIR" ]
    then
        echo "SDL2 cache mismatch:"
        echo "  Cached:   $CACHED_SDL2_DIR"
        echo "  Required: $SDL2_DIR"
        CLEAR_BUILD=1
    fi

    if [ "$CLEAR_BUILD" -eq 1 ]; then
        echo
        echo "Clearing only the incompatible OpenMW build directory:"
        echo "  $BUILD"

        rm -rf "$BUILD"
    else
        echo "Compatible existing OpenMW build tree found."
        echo "Ninja will reuse already completed object files."
    fi
fi

mkdir -p "$BUILD"

# Recreate only the package output. This does not affect the resumable
# compilation objects stored in the separate OpenMW build directory.
rm -rf "$PACKAGE"
mkdir -p "$PACKAGE"

echo
echo "Configuring OpenMW 0.51..."

CMAKE_ARGS=(
    -S "$SRC"
    -B "$BUILD"
    -G Ninja

    -DCMAKE_C_COMPILER="$CC_BIN"
    -DCMAKE_CXX_COMPILER="$CXX_BIN"

    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="$PACKAGE"

    -DCMAKE_PREFIX_PATH="$CMAKE_PREFIX_PATH"

    -DOSG_INCLUDE_DIR="$OSG_INCLUDE_DIR"
    -DOSG_LIBRARY="$OSG_LIBRARY"

    -DMyGUI_INCLUDE_DIR="$MYGUI_INCLUDE_DIR"
    -DMyGUI_LIBRARY="$MYGUI_LIBRARY"

    -DSDL2_DIR="$SDL2_DIR"
    -DSDL2_INCLUDE_DIR="$SDL2_INCLUDE_DIR"

    -DCMAKE_INSTALL_RPATH='$ORIGIN/lib'
    -DCMAKE_BUILD_RPATH_USE_ORIGIN=ON

    -DBUILD_OPENMW=ON
    -DBUILD_OPENCS=OFF
    -DBUILD_LAUNCHER=OFF
    -DBUILD_WIZARD=OFF
    -DBUILD_ESMTOOL=OFF
    -DBUILD_BSATOOL=OFF
    -DBUILD_NIFTEST=OFF
    -DBUILD_NAVMESHTOOL=OFF
    -DBUILD_BULLETOBJECTTOOL=OFF

    -DUSE_SYSTEM_TINYXML=ON
)

cmake "${CMAKE_ARGS[@]}"

echo
echo "CMake compiler and dependency summary:"

grep -E \
    '^(CMAKE_C_COMPILER|CMAKE_CXX_COMPILER|OPENMW_VERSION|OPENSCENEGRAPH|OSG_|SDL2_|MYGUI_|BULLET_|OPENAL_|LUA|LuaJIT|YAML)' \
    "$BUILD/CMakeCache.txt" || true

echo
echo "Verifying selected compilers..."

CONFIGURED_C_COMPILER="$(
    sed -n \
        's/^CMAKE_C_COMPILER:[^=]*=//p' \
        "$BUILD/CMakeCache.txt" |
    head -1
)"

CONFIGURED_CXX_COMPILER="$(
    sed -n \
        's/^CMAKE_CXX_COMPILER:[^=]*=//p' \
        "$BUILD/CMakeCache.txt" |
    head -1
)"
if [ "$CONFIGURED_C_COMPILER" != "$CC_BIN" ]; then
    echo "ERROR: CMake did not select GCC $TOOLCHAIN_MAJOR."
    echo "Selected: ${CONFIGURED_C_COMPILER:-unknown}"
    echo "Required: $CC_BIN"
    exit 1
fi

if [ "$CONFIGURED_CXX_COMPILER" != "$CXX_BIN" ]; then
    echo "ERROR: CMake did not select G++ $TOOLCHAIN_MAJOR."
    echo "Selected: ${CONFIGURED_CXX_COMPILER:-unknown}"
    echo "Required: $CXX_BIN"
    exit 1
fi

echo "CMake selected GCC $TOOLCHAIN_MAJOR successfully."

echo
echo "Verifying generated Ninja compiler commands..."

FIRST_NINJA_CXX_COMMAND="$(
    ninja -C "$BUILD" -t commands openmw 2>/dev/null |
    grep -m1 -E '/usr/bin/g\+\+-[0-9]+' || true
)"

if [ -z "$FIRST_NINJA_CXX_COMMAND" ]; then
    echo "ERROR: Could not find a C++ compiler command in the generated Ninja files."
    exit 1
fi

echo "First generated C++ command:"
echo "  $FIRST_NINJA_CXX_COMMAND"

case "$FIRST_NINJA_CXX_COMMAND" in
    *"$CXX_BIN"*)
        echo "Ninja is configured to use $CXX_BIN."
        ;;
    *)
        echo "ERROR: Ninja is configured with the wrong C++ compiler."
        echo "Required compiler: $CXX_BIN"
        exit 1
        ;;
esac

echo
echo "Verifying selected SDL2..."

CONFIGURED_SDL2_DIR="$(
    sed -n \
        's/^SDL2_DIR:[^=]*=//p' \
        "$BUILD/CMakeCache.txt" |
    head -1
)"

if [ -n "$CONFIGURED_SDL2_DIR" ] && \
   [ "$CONFIGURED_SDL2_DIR" != "$SDL2_DIR" ]
then
    echo "ERROR: CMake selected the wrong SDL2 configuration."
    echo "Selected: $CONFIGURED_SDL2_DIR"
    echo "Required: $SDL2_DIR"
    exit 1
fi

echo "CMake selected the custom SDL2 installation."

echo
echo "Building OpenMW 0.51..."
echo "This stage is resumable."
echo "If compilation fails, fix the error and run this same script again."
echo "Ninja will not rebuild successfully completed object files."

cmake --build "$BUILD" \
    --target openmw \
    --parallel "$JOBS"

echo
echo "Installing matching files..."

cmake --install "$BUILD" || true

OPENMW_BINARY="$(
    find "$BUILD" \
        -type f \
        -name openmw \
        -perm -111 \
        -print |
    head -1
)"

if [ -z "$OPENMW_BINARY" ]; then
    echo "ERROR: The OpenMW executable was not produced."
    exit 1
fi

mkdir -p \
    "$PACKAGE/bin" \
    "$PACKAGE/resources" \
    "$PACKAGE/lib"

cp -f \
    "$OPENMW_BINARY" \
    "$PACKAGE/bin/openmw-0.51"

chmod +x "$PACKAGE/bin/openmw-0.51"

echo
echo "Copying matching OpenMW 0.51 resources..."

copy_resource_tree() {
    source_dir="$1"

    if [ -d "$source_dir" ]; then
        rsync -a \
            "$source_dir/" \
            "$PACKAGE/resources/"

        return 0
    fi

    return 1
}

RESOURCE_COPIED=0

for candidate in \
    "$BUILD/resources" \
    "$BUILD/files" \
    "$SRC/resources" \
    "$SRC/files"
do
    if [ -d "$candidate" ]; then
        echo "Resource candidate: $candidate"
    fi
done

if copy_resource_tree "$BUILD/resources"; then
    RESOURCE_COPIED=1
elif copy_resource_tree "$SRC/resources"; then
    RESOURCE_COPIED=1
fi

if [ -d "$SRC/files" ]; then
    mkdir -p "$PACKAGE/openmw-files"

    rsync -a \
        "$SRC/files/" \
        "$PACKAGE/openmw-files/"
fi

if [ -d "$BUILD/files" ]; then
    mkdir -p "$PACKAGE/openmw-build-files"

    rsync -a \
        "$BUILD/files/" \
        "$PACKAGE/openmw-build-files/"
fi

if [ "$RESOURCE_COPIED" -eq 0 ]; then
    echo "WARNING: No resources directory was copied automatically."
fi

echo
echo "Locating matching defaults.bin..."

DEFAULTS="$(
    find \
        "$BUILD" \
        "$SRC" \
        -type f \
        -name defaults.bin \
        -print 2>/dev/null |
    head -1
)"

if [ -n "$DEFAULTS" ]; then
    cp -f \
        "$DEFAULTS" \
        "$PACKAGE/defaults.bin"

    echo "defaults.bin: $DEFAULTS"
else
    echo "WARNING: defaults.bin was not found automatically."
fi

echo
echo "Copying runtime libraries not guaranteed to exist on CrossMix..."

copy_needed_library() {
    name="$1"
    resolved=""

    resolved="$(
        ldconfig -p 2>/dev/null |
        awk -v n="$name" \
            '$1 == n { print $NF; exit }'
    )"

    if [ -z "$resolved" ]; then
        resolved="$(
            find \
                "$OSG_PREFIX" \
                /usr/local \
                /usr \
                -type f \
                -name "$name" \
                -print 2>/dev/null |
            head -1
        )"
    fi

    if [ -n "$resolved" ] && [ -f "$resolved" ]; then
        cp -Lf \
            "$resolved" \
            "$PACKAGE/lib/$name"

        echo "  $name <- $resolved"
    else
        echo "  WARNING: could not resolve $name"
    fi
}

echo "Copying MyGUI 3.4.3 runtime..."

for mygui_candidate in \
    "$MYGUI_PREFIX"/lib/libMyGUIEngine.so*
do
    if [ -e "$mygui_candidate" ]; then
        cp -Lf \
            "$mygui_candidate" \
            "$PACKAGE/lib/$(basename "$mygui_candidate")"
    fi
done

echo "Copying SDL2 2.30.12 runtime..."

for sdl_candidate in \
    "$SDL_PREFIX"/lib/libSDL2.so* \
    "$SDL_PREFIX"/lib/libSDL2-2.0.so*
do
    if [ -e "$sdl_candidate" ]; then
        cp -Lf \
            "$sdl_candidate" \
            "$PACKAGE/lib/$(basename "$sdl_candidate")"
    fi
done

echo "Copying GCC $TOOLCHAIN_MAJOR runtime libraries..."

for runtime_library in \
    libstdc++.so.6 \
    libgcc_s.so.1
do
    runtime_path="$(
        "$CXX_BIN" -print-file-name="$runtime_library"
    )"

    if [ -n "$runtime_path" ] && [ -f "$runtime_path" ]; then
        cp -Lf \
            "$runtime_path" \
            "$PACKAGE/lib/$runtime_library"

        echo "  $runtime_library <- $runtime_path"
    else
        echo "  WARNING: could not resolve $runtime_library"
    fi
done

echo "Copying patched OpenSceneGraph runtime..."

for library in \
    libOpenThreads.so.21 \
    libosg.so.162 \
    libosgAnimation.so.162 \
    libosgDB.so.162 \
    libosgFX.so.162 \
    libosgGA.so.162 \
    libosgParticle.so.162 \
    libosgShadow.so.162 \
    libosgSim.so.162 \
    libosgText.so.162 \
    libosgUtil.so.162 \
    libosgViewer.so.162
do
    copy_needed_library "$library"
done

echo
echo "Creating TrimUI 0.51 test launcher template..."

cat > "$PACKAGE/Morrowind-0.51-test.sh" <<'LAUNCHER'
#!/bin/bash

if [ -z "${BASH_VERSION:-}" ]; then
    exec /bin/bash "$0" "$@"
fi

GAMEDIR="/mnt/SDCARD/data/ports/openmw"
BIN="$GAMEDIR/openmw-0.51"
RESOURCES="$GAMEDIR/resources-0.51"
CONFIG_DIR="$GAMEDIR/config-0.51"
SAVE_DIR="$GAMEDIR/savegame"
LOG="$GAMEDIR/log-0.51.txt"

mkdir -p \
    "$CONFIG_DIR" \
    "$SAVE_DIR" \
    "$SAVE_DIR/data" \
    "$SAVE_DIR/screenshots" \
    "$GAMEDIR/texcache-0.51"

rm -f "$LOG"
exec >> "$LOG" 2>&1

export XDG_RUNTIME_DIR="/tmp/runtime-root"

mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"

export XDG_DATA_HOME="$CONFIG_DIR"
export XDG_CONFIG_HOME="$CONFIG_DIR"
export OPENMW_RESOURCES="$RESOURCES"

export LD_LIBRARY_PATH="$GAMEDIR/lib:$GAMEDIR/libs:$GAMEDIR/lib/aarch64:${LD_LIBRARY_PATH:-}"
export OSG_LIBRARY_PATH="$GAMEDIR/osgPlugins-3.6.5"

export OPENMW_DECOMPRESS_TEXTURES=1
export LIBGL_STREAM=1
export LIBGL_NOTEST=1
export LIBGL_FORCENPOT=1
export LIBGL_MIPMAP=3
export LIBGL_TEXPATH="$GAMEDIR/texcache-0.51/"
export LIBGL_RECOMPTEX=0
export LIBGL_NOMIPMAPS=0
export LIBGL_SHRINK=0

export SDL_GAMECONTROLLERCONFIG='0300a3845e0400008e02000014010000,TRIMUI Player1,a:b1,b:b0,x:b3,y:b2,back:b6,start:b7,leftstick:b9,rightstick:b10,leftshoulder:b4,rightshoulder:b5,lefttrigger:a2,righttrigger:a5,leftx:a0,lefty:a1,rightx:a3,righty:a4,dpup:h0.1,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,platform:Linux,'

export OSG_NOTIFY_LEVEL=WARN
export OPENMW_DEBUG_LEVEL=warning
export OPENMW_RECAST_MAX_LOG_LEVEL=warning

if [ ! -x "$BIN" ]; then
    echo "ERROR: Missing OpenMW 0.51 binary:"
    echo "$BIN"
    exit 1
fi

if [ ! -d "$RESOURCES" ]; then
    echo "ERROR: Missing matching OpenMW 0.51 resources:"
    echo "$RESOURCES"
    exit 1
fi

chmod +x "$BIN"

SETTINGS="$CONFIG_DIR/settings.cfg"

python3 - "$SETTINGS" <<'PY'
import configparser
import os
import sys

path = sys.argv[1]

config = configparser.ConfigParser(
    interpolation=None,
    strict=False,
    empty_lines_in_values=False,
)

config.optionxform = str

if os.path.isfile(path):
    try:
        config.read(path, encoding="utf-8")
    except Exception:
        pass

values = {
    "Video": {
        "resolution x": "1280",
        "resolution y": "720",
        "fullscreen": "true",
        "window border": "false",
        "antialiasing": "0",
        "vsync": "false",
    },
    "Shaders": {
        "force shaders": "true",
        "force per pixel lighting": "false",
    },
    "Water": {
        "shader": "false",
        "refraction": "false",
        "reflection detail": "0",
    },
    "Shadows": {
        "enable shadows": "false",
    },
    "Post Processing": {
        "enabled": "false",
    },
    "Terrain": {
        "distant terrain": "false",
    },
    "Input": {
        "enable controller": "true",
        "gamepad cursor speed": "0.30",
        "joystick dead zone": "0.05",
    },
    "GUI": {
        "controller menus": "true",
        "controller tooltips": "true",
    },
}

for section, settings in values.items():
    if not config.has_section(section):
        config.add_section(section)

    for key, value in settings.items():
        config.set(section, key, value)

temporary_path = path + ".tmp"

with open(
    temporary_path,
    "w",
    encoding="utf-8",
    newline="\n",
) as handle:
    config.write(
        handle,
        space_around_delimiters=True,
    )

os.replace(temporary_path, path)
PY

echo "=========================================="
echo "Launching OpenMW 0.51 test"
echo "Date: $(date)"
echo "Binary: $BIN"
echo "Resources: $RESOURCES"
echo "Config: $CONFIG_DIR"
echo "=========================================="

"$BIN" \
    --resources "$RESOURCES" \
    --user-data-dir "$SAVE_DIR" \
    --config "$CONFIG_DIR" &

OPENMW_PID=$!

wait "$OPENMW_PID"
RESULT=$?

echo "OpenMW 0.51 exited with code: $RESULT"

exit "$RESULT"
LAUNCHER

chmod +x "$PACKAGE/Morrowind-0.51-test.sh"

echo
echo "Writing installation manifest..."

{
    echo "OpenMW tag: $TAG"
    echo "Build script revision: $SCRIPT_REVISION"
    echo "Source revision: $(git -C "$SRC" rev-parse HEAD)"
    echo "Build date: $(date)"
    echo "Architecture: $(uname -m)"
    echo "C compiler: $CC_BIN"
    echo "C++ compiler: $CXX_BIN"
    echo "SDL2 prefix: $SDL_PREFIX"
    echo "SDL2 CMake directory: $SDL2_DIR"
    echo "SDL2 library: $SDL2_LIBRARY"
    echo "MyGUI prefix: $MYGUI_PREFIX"
    echo "MyGUI library: $MYGUI_LIBRARY"
    echo "OSG prefix: $OSG_PREFIX"
    echo "Binary source: $OPENMW_BINARY"
    echo "defaults.bin source: ${DEFAULTS:-not found}"

    echo
    echo "Binary:"
    file "$PACKAGE/bin/openmw-0.51"

    echo
    echo "Dependencies:"
    readelf -d \
        "$PACKAGE/bin/openmw-0.51" |
        grep NEEDED || true

    echo
    echo "Package files:"

    find "$PACKAGE" \
        -maxdepth 3 \
        -type f \
        -printf '%P\n' |
        sort
} > "$PACKAGE/BUILD-MANIFEST.txt"

echo
echo "Stripping executable..."

strip "$PACKAGE/bin/openmw-0.51" || true

echo
echo "Final verification:"

file "$PACKAGE/bin/openmw-0.51"
"$PACKAGE/bin/openmw-0.51" --version || true

echo
echo "Package size:"

du -sh "$PACKAGE"

echo
echo "=========================================="
echo "SUCCESS"
echo "=========================================="

echo
echo "Package directory:"
echo "$PACKAGE"

echo
echo "Copy these items to the SD card without replacing 0.48:"

echo
echo "  $PACKAGE/bin/openmw-0.51"
echo "      -> /mnt/SDCARD/data/ports/openmw/openmw-0.51"

echo
echo "  $PACKAGE/resources/"
echo "      -> /mnt/SDCARD/data/ports/openmw/resources-0.51/"

echo
echo "  $PACKAGE/defaults.bin"
echo "      -> /mnt/SDCARD/data/ports/openmw/resources-0.51/defaults.bin"

echo
echo "  $PACKAGE/lib/"
echo "      -> /mnt/SDCARD/data/ports/openmw/lib/"

echo
echo "  $PACKAGE/Morrowind-0.51-test.sh"
echo "      -> /mnt/SDCARD/Roms/PORTS/Morrowind 0.51 Test.sh"

echo
echo "Keep the existing 0.48 binary, resources, config, and launcher untouched."
