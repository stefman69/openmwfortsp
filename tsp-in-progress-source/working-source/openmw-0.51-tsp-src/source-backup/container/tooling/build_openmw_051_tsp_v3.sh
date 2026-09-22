#!/bin/bash
set -Eeuo pipefail

# OpenMW 0.51 TrimUI Smart Pro unattended build/package script.
# Run INSIDE the existing ARM64 Docker container as root.
#
# It does not overwrite the working OpenMW 0.48 source, build, or package.
# Output:
#   /root/openmw-0.51-tsp-package/
#   /root/openmw-0.51-tsp-build.log
#   /root/openmw-0.51-tsp-build.exitcode

TAG="${OPENMW_TAG:-openmw-0.51.0}"
SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"
PACKAGE="/root/openmw-0.51-tsp-package"
MYGUI_SRC="/root/mygui-3.4.3-src"
MYGUI_BUILD="/root/mygui-3.4.3-build"
MYGUI_PREFIX="/root/mygui-3.4.3-install"
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
echo "Parallel jobs: $JOBS"
echo "=========================================="

if [ "$(uname -m)" != "aarch64" ]; then
    echo "ERROR: This must run inside the ARM64/aarch64 Docker container."
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo
echo "Installing/confirming build tools..."
apt-get update
apt-get install -y \
    git \
    cmake \
    ninja-build \
    make \
    gcc \
    g++ \
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
        echo "FOUND pkg-config: $pkg $(pkg-config --modversion "$pkg" 2>/dev/null || true)"
    else
        echo "NOTE: pkg-config entry not found: $pkg"
    fi
done

echo
echo "Locating the patched OSG installation..."
OSG_PREFIX=""
OSG_LIBRARY=""
OSG_HEADER=""

# First check likely prefixes, accepting real files or symlinks and any OSG SONAME.
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
            \( -path '*/include/osg/Version' -o -path '*/include/osg/Version.in' \) \
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

# If the likely locations did not match, search the complete container.
if [ -z "$OSG_PREFIX" ]; then
    echo "Likely OSG prefixes did not match."
    echo "Searching the complete container filesystem..."

    OSG_LIBRARY="$(
        find / \
            \( -path /proc -o -path /sys -o -path /dev -o -path /run \) \
            -prune -o \
            \( -type f -o -type l \) \
            -name 'libosg.so*' \
            -print 2>/dev/null |
        head -1
    )"

    OSG_HEADER="$(
        find / \
            \( -path /proc -o -path /sys -o -path /dev -o -path /run \) \
            -prune -o \
            -type f \
            \( -path '*/include/osg/Version' -o -path '*/include/osg/Version.in' \) \
            -print 2>/dev/null |
        head -1
    )"

    if [ -n "$OSG_LIBRARY" ] && [ -n "$OSG_HEADER" ]; then
        OSG_LIB_DIR="$(dirname "$OSG_LIBRARY")"
        OSG_INCLUDE_DIR="$(dirname "$(dirname "$OSG_HEADER")")"

        # Prefer a common parent when possible. CMake also receives the explicit
        # include and library directories below, so this does not need to be exact.
        OSG_PREFIX="$(dirname "$OSG_LIB_DIR")"
    fi
fi

if [ -z "$OSG_LIBRARY" ] || [ -z "$OSG_HEADER" ]; then
    echo "ERROR: Could not locate both the OSG library and OSG headers."
    echo
    echo "Libraries found:"
    find /root /usr/local /usr /opt \
        \( -type f -o -type l \) \
        -name 'libosg.so*' \
        -print 2>/dev/null || true
    echo
    echo "Headers found:"
    find /root /usr/local /usr /opt \
        -type f \
        \( -path '*/include/osg/Version' -o -path '*/include/osg/Version.in' \) \
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
echo "Building MyGUI 3.4.3"
echo "=========================================="

rm -rf "$MYGUI_SRC" "$MYGUI_BUILD" "$MYGUI_PREFIX"

git clone \
    --branch MyGUI3.4.3 \
    --depth 1 \
    https://github.com/MyGUI/mygui.git \
    "$MYGUI_SRC"

echo "MyGUI revision:"
git -C "$MYGUI_SRC" describe --tags --always
git -C "$MYGUI_SRC" rev-parse HEAD

mkdir -p "$MYGUI_BUILD" "$MYGUI_PREFIX"

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
    --target MyGUIEngine \
    --parallel "$JOBS"

cmake --install "$MYGUI_BUILD"

MYGUI_LIBRARY="$(
    find "$MYGUI_PREFIX" \
        \( -type f -o -type l \) \
        -name 'libMyGUIEngine.so*' \
        -print |
    head -1
)"

MYGUI_INCLUDE_DIR="$MYGUI_PREFIX/include/MYGUI"

if [ -z "$MYGUI_LIBRARY" ] || [ ! -d "$MYGUI_INCLUDE_DIR" ]; then
    echo "ERROR: MyGUI 3.4.3 did not install correctly."
    echo "Library: ${MYGUI_LIBRARY:-not found}"
    echo "Include: $MYGUI_INCLUDE_DIR"
    find "$MYGUI_PREFIX" -maxdepth 4 -print || true
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

# Put the new MyGUI ahead of the older /usr/local 3.4.2 installation.
export CMAKE_PREFIX_PATH="$MYGUI_PREFIX:$CMAKE_PREFIX_PATH"
export PKG_CONFIG_PATH="$MYGUI_PREFIX/lib/pkgconfig:$PKG_CONFIG_PATH"
export LD_LIBRARY_PATH="$MYGUI_PREFIX/lib:$LD_LIBRARY_PATH"

echo
echo "Downloading OpenMW source..."
rm -rf "$SRC" "$BUILD" "$PACKAGE"

git clone \
    --branch "$TAG" \
    --depth 1 \
    https://gitlab.com/OpenMW/openmw.git \
    "$SRC"

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

# OpenMW queries GL_MAX_TEXTURE_IMAGE_UNITS during graphics capability setup.
# CrossMix GL4ES can return zero when its EGL capability probe fails. Preserve
# upstream behavior but replace a non-positive result with the GLES2 minimum.
patterns = [
    re.compile(
        r'(?P<indent>[ \t]*)glGetIntegerv\(\s*GL_MAX_TEXTURE_IMAGE_UNITS\s*,\s*&(?P<var>[A-Za-z_][A-Za-z0-9_]*)\s*\);'
    ),
    re.compile(
        r'(?P<indent>[ \t]*)GLint\s+(?P<var>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*0\s*;\s*\n'
        r'(?P=indent)glGetIntegerv\(\s*GL_MAX_TEXTURE_IMAGE_UNITS\s*,\s*&(?P=var)\s*\);'
    ),
]

for path in root.rglob("*"):
    if path.suffix not in {".cpp", ".cxx", ".cc", ".c", ".hpp", ".h"}:
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

    # Most common one-line query.
    m = patterns[0].search(text)
    if m:
        indent = m.group("indent")
        var = m.group("var")
        replacement = (
            m.group(0)
            + "\n"
            + indent + f"if ({var} <= 0)\n"
            + indent + "{\n"
            + indent + f'    Log(Debug::Warning) << "GL_MAX_TEXTURE_IMAGE_UNITS returned " << {var}\n'
            + indent + '                        << "; using GLES2 minimum fallback of 8";\n'
            + indent + f"    {var} = 8;\n"
            + indent + "}"
        )
        text = text[:m.start()] + replacement + text[m.end():]

    if text != original:
        path.write_text(text, encoding="utf-8")
        patched.append(str(path.relative_to(root)))

print("Texture-unit fallback patched files:")
if patched:
    for item in patched:
        print("  " + item)
else:
    print("  No matching source query was patched.")
    print("  This can be normal if 0.51 already validates the value upstream.")
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
echo "Configuring OpenMW 0.51..."

mkdir -p "$BUILD" "$PACKAGE"

CMAKE_ARGS=(
    -S "$SRC"
    -B "$BUILD"
    -G Ninja
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="$PACKAGE"
    -DCMAKE_PREFIX_PATH="$CMAKE_PREFIX_PATH"
    -DOSG_INCLUDE_DIR="$OSG_INCLUDE_DIR"
    -DOSG_LIBRARY="$OSG_LIBRARY"
    -DMyGUI_INCLUDE_DIR="$MYGUI_INCLUDE_DIR"
    -DMyGUI_LIBRARY="$MYGUI_LIBRARY"
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
echo "CMake dependency summary:"
grep -E \
    '^(OPENMW_VERSION|OPENSCENEGRAPH|OSG_|SDL2_|MYGUI_|BULLET_|OPENAL_|LUA|LuaJIT|YAML)' \
    "$BUILD/CMakeCache.txt" || true

echo
echo "Building OpenMW 0.51..."
cmake --build "$BUILD" --target openmw --parallel "$JOBS"

echo
echo "Installing matching files..."
# Some OpenMW configurations do not expose an install target when only the game
# executable is selected. Try it, then package manually if needed.
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

cp -f "$OPENMW_BINARY" "$PACKAGE/bin/openmw-0.51"
chmod +x "$PACKAGE/bin/openmw-0.51"

echo
echo "Copying matching OpenMW 0.51 resources..."

copy_resource_tree() {
    source_dir="$1"
    if [ -d "$source_dir" ]; then
        rsync -a "$source_dir/" "$PACKAGE/resources/"
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

# Prefer generated build resources, then source resources.
if copy_resource_tree "$BUILD/resources"; then
    RESOURCE_COPIED=1
elif copy_resource_tree "$SRC/resources"; then
    RESOURCE_COPIED=1
fi

# The source "files" tree contains defaults, Lua, fonts, shaders, and config
# assets in many OpenMW releases. Preserve its hierarchy separately.
if [ -d "$SRC/files" ]; then
    mkdir -p "$PACKAGE/openmw-files"
    rsync -a "$SRC/files/" "$PACKAGE/openmw-files/"
fi

if [ -d "$BUILD/files" ]; then
    mkdir -p "$PACKAGE/openmw-build-files"
    rsync -a "$BUILD/files/" "$PACKAGE/openmw-build-files/"
fi

echo
echo "Locating matching defaults.bin..."
DEFAULTS="$(
    find "$BUILD" "$SRC" \
        -type f \
        -name defaults.bin \
        -print |
    head -1
)"

if [ -n "$DEFAULTS" ]; then
    cp -f "$DEFAULTS" "$PACKAGE/defaults.bin"
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
        awk -v n="$name" '$1 == n { print $NF; exit }'
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
        cp -Lf "$resolved" "$PACKAGE/lib/$name"
        echo "  $name <- $resolved"
    else
        echo "  WARNING: could not resolve $name"
    fi
}

# Package the matching MyGUI 3.4.3 runtime required by OpenMW 0.51.
cp -Lf "$MYGUI_LIBRARY" "$PACKAGE/lib/$(basename "$MYGUI_LIBRARY")"

# Also provide the unversioned/SONAME forms when available.
for mygui_candidate in "$MYGUI_PREFIX"/lib/libMyGUIEngine.so*; do
    if [ -e "$mygui_candidate" ]; then
        cp -Lf "$mygui_candidate" "$PACKAGE/lib/$(basename "$mygui_candidate")"
    fi
done

# Preserve the patched OSG libraries that made the 0.48 build render safely.
for library in \
    libOpenThreads.so.21 \
    libosg.so.162 \
    libosgDB.so.162 \
    libosgGA.so.162 \
    libosgParticle.so.162 \
    libosgShadow.so.162 \
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

# Use the known-good patched OSG/runtime stack already installed for 0.48.
export LD_LIBRARY_PATH="$GAMEDIR/lib:$GAMEDIR/libs:$GAMEDIR/lib/aarch64:${LD_LIBRARY_PATH:-}"
export OSG_LIBRARY_PATH="$GAMEDIR/osgPlugins-3.6.5"

# The critical CrossMix GL4ES workaround.
export OPENMW_DECOMPRESS_TEXTURES=1
export LIBGL_STREAM=1
export LIBGL_NOTEST=1
export LIBGL_FORCENPOT=1
export LIBGL_MIPMAP=3
export LIBGL_TEXPATH="$GAMEDIR/texcache-0.51/"
export LIBGL_RECOMPTEX=0
export LIBGL_NOMIPMAPS=0
export LIBGL_SHRINK=0

# Exact measured TrimUI Smart Pro SDL mapping.
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

tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8", newline="\n") as handle:
    config.write(handle, space_around_delimiters=True)
os.replace(tmp, path)
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
    echo "Source revision: $(git -C "$SRC" rev-parse HEAD)"
    echo "Build date: $(date)"
    echo "Architecture: $(uname -m)"
    echo "OSG prefix: $OSG_PREFIX"
    echo "Binary source: $OPENMW_BINARY"
    echo "defaults.bin source: ${DEFAULTS:-not found}"
    echo
    echo "Binary:"
    file "$PACKAGE/bin/openmw-0.51"
    echo
    echo "Dependencies:"
    readelf -d "$PACKAGE/bin/openmw-0.51" | grep NEEDED || true
    echo
    echo "Package files:"
    find "$PACKAGE" -maxdepth 3 -type f -printf '%P\n' | sort
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
echo "  $PACKAGE/bin/openmw-0.51"
echo "      -> /mnt/SDCARD/data/ports/openmw/openmw-0.51"
echo
echo "  $PACKAGE/resources/"
echo "      -> /mnt/SDCARD/data/ports/openmw/resources-0.51/"
echo
echo "  $PACKAGE/defaults.bin"
echo "      -> /mnt/SDCARD/data/ports/openmw/resources-0.51/defaults.bin"
echo
echo "  $PACKAGE/Morrowind-0.51-test.sh"
echo "      -> /mnt/SDCARD/Roms/PORTS/Morrowind 0.51 Test.sh"
echo
echo "Keep the existing 0.48 binary, resources, config, and launcher untouched."
