#!/bin/bash
set -Eeuo pipefail

# OpenMW 0.51 / TrimUI Smart Pro S
# Software cursor + POT-safe mipmap experiment v8
#
# CURSOR:
#   Stock OpenMW 0.51 converts MyGUI pointer resources into SDL hardware
#   cursors, then hides MyGUI's software pointer.
#   v8 bypasses SDL hardware cursors on TSP and renders MyGUI's pointer
#   inside the GUI framebuffer.
#
# TEXTURES:
#   Current TSP launcher:
#       LIBGL_MIPMAP=3
#       LIBGL_FORCENPOT=1
#   GL4ES mode 3 disables mipmap creation/use globally.
#
#   v8 runtime:
#       LIBGL_MIPMAP=2
#       LIBGL_FORCENPOT=0
#
#   OpenMW source gate:
#       POT Texture2D + mipmap request -> keep mipmap filter
#       NPOT/unknown Texture2D         -> strip mipmap filter safely
#
# PRESERVED:
#   direct framebuffer v2
#   NiLOD v4 distant-object fix
#   v7 32-cell / 128x128 water grid
#   v7 malloc_trim memory cleanup
#   Project Atlas + MOP
#   near clip = 15
#   fixed-height water / no FudgeCallback
#   fixed-function water fog
#   explicit triangle water
#   LIBGL_NOTEST=1
#
# No CMake regeneration is performed.

SOURCE_DIR="${1:-/root/openmw-0.51-tsp-src}"
BUILD_DIR="${2:-/root/openmw-0.51-tsp-build}"
PACKAGE_DIR="${3:-/root/openmw-0.51-tsp-package}"
OUTPUT_BINARY="${4:-/root/openmw-0.51-tsp-software-cursor-mipmap-v8}"

JOBS="${OPENMW_JOBS:-$(nproc)}"
PATCH_ONLY="${OPENMW_PATCH_ONLY:-0}"

WINDOW_CPP="$SOURCE_DIR/apps/openmw/mwgui/windowmanagerimp.cpp"
SCENE_CPP="$SOURCE_DIR/components/resource/scenemanager.cpp"
WATER_CPP="$SOURCE_DIR/apps/openmw/mwrender/water.cpp"
RESOURCE_CPP="$SOURCE_DIR/components/resource/resourcesystem.cpp"
POST_CPP="$SOURCE_DIR/apps/openmw/mwrender/postprocessor.cpp"
NIFLOADER_CPP="$SOURCE_DIR/components/nifosg/nifloader.cpp"
WATERUTIL_CPP="$SOURCE_DIR/components/sceneutil/waterutil.cpp"
CMAKE_FILE="$SOURCE_DIR/CMakeLists.txt"

BUILT_BINARY="$BUILD_DIR/openmw"
PACKAGE_BINARY="$PACKAGE_DIR/bin/openmw-0.51"
PACKAGE_NAVTOOL="$PACKAGE_DIR/bin/openmw-navmeshtool"
PACKAGE_TOOLS="$PACKAGE_DIR/tools"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$SOURCE_DIR/.tsp-051-source-backups/software-cursor-mipmap-v8-$STAMP"

restore_on_error() {
    rc=$?
    if [ "$rc" -ne 0 ] && [ -d "$BACKUP_DIR" ]; then
        echo
        echo "ERROR: v8 failed. Restoring files changed by v8..."
        for rel in \
            apps/openmw/mwgui/windowmanagerimp.cpp \
            components/resource/scenemanager.cpp \
            apps/openmw/mwrender/water.cpp
        do
            if [ -f "$BACKUP_DIR/$rel" ]; then
                cp -f "$BACKUP_DIR/$rel" "$SOURCE_DIR/$rel"
            fi
        done
        echo "Source restored."
        echo "Failed-attempt backup:"
        echo "  $BACKUP_DIR"
    fi
    exit "$rc"
}
trap restore_on_error ERR

echo "============================================================"
echo "OpenMW 0.51 TSP software cursor + POT-safe mipmaps v8"
echo "============================================================"
echo "Source:  $SOURCE_DIR"
echo "Build:   $BUILD_DIR"
echo "Package: $PACKAGE_DIR"
echo "Backup:  $BACKUP_DIR"
echo "============================================================"

for f in \
    "$WINDOW_CPP" \
    "$SCENE_CPP" \
    "$WATER_CPP" \
    "$RESOURCE_CPP" \
    "$POST_CPP" \
    "$NIFLOADER_CPP" \
    "$WATERUTIL_CPP" \
    "$CMAKE_FILE"
do
    if [ ! -f "$f" ]; then
        echo "ERROR: missing required source file:"
        echo "  $f"
        exit 1
    fi
done

VERSION_MAJOR="$(
    sed -n 's/^[[:space:]]*set(OPENMW_VERSION_MAJOR[[:space:]]*\([0-9][0-9]*\)).*/\1/p' "$CMAKE_FILE" | head -1
)"
VERSION_MINOR="$(
    sed -n 's/^[[:space:]]*set(OPENMW_VERSION_MINOR[[:space:]]*\([0-9][0-9]*\)).*/\1/p' "$CMAKE_FILE" | head -1
)"

if [ "$VERSION_MAJOR" != "0" ] || [ "$VERSION_MINOR" != "51" ]; then
    echo "ERROR: expected OpenMW 0.51 source."
    echo "Detected: ${VERSION_MAJOR:-?}.${VERSION_MINOR:-?}"
    exit 1
fi

for marker_file in \
    "TSP_LEGACY_DIRECT_RENDER_051_V2|$POST_CPP" \
    "TSP_NILOD_OVERLAP_FIX_051_V4|$NIFLOADER_CPP" \
    "TSP_NILOD_OVERLAP_APPLY_051_V4|$NIFLOADER_CPP" \
    "TSP_GL4ES_WATER_DENSE_GRID_051_V7|$WATER_CPP" \
    "TSP_MEMORY_TRIM_UPDATE_051_V7|$RESOURCE_CPP" \
    "TSP_MEMORY_TRIM_CLEAR_051_V7|$RESOURCE_CPP"
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

if ! grep -Eq 'TSP_GL4ES_WATER_EXPLICIT_TRIANGLES_051_V[12]' "$WATERUTIL_CPP"; then
    echo "ERROR: explicit-triangle water baseline marker missing."
    exit 1
fi

if [ "$PATCH_ONLY" != "1" ]; then
    if [ ! -f "$BUILD_DIR/build.ninja" ] || [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
        echo "ERROR: configured Ninja build tree missing."
        exit 1
    fi
fi

mkdir -p \
    "$BACKUP_DIR/apps/openmw/mwgui" \
    "$BACKUP_DIR/components/resource" \
    "$BACKUP_DIR/apps/openmw/mwrender" \
    "$PACKAGE_DIR/bin" \
    "$PACKAGE_TOOLS"

cp -f "$WINDOW_CPP" "$BACKUP_DIR/apps/openmw/mwgui/windowmanagerimp.cpp"
cp -f "$SCENE_CPP" "$BACKUP_DIR/components/resource/scenemanager.cpp"
cp -f "$WATER_CPP" "$BACKUP_DIR/apps/openmw/mwrender/water.cpp"

echo
echo "Applying v8 source changes..."

python3 - "$WINDOW_CPP" "$SCENE_CPP" "$WATER_CPP" <<'PY_PATCH'
from pathlib import Path
import os
import re
import sys

window_path = Path(sys.argv[1])
scene_path = Path(sys.argv[2])
water_path = Path(sys.argv[3])

window = window_path.read_text(encoding="utf-8")
scene = scene_path.read_text(encoding="utf-8")
water = water_path.read_text(encoding="utf-8")

CURSOR_MARKER = "// TSP_GL4ES_SOFTWARE_CURSOR_051_V8"
CURSOR_VIS_MARKER = "// TSP_GL4ES_SOFTWARE_CURSOR_VISIBILITY_051_V8"
FILTER_MARKER = "// TSP_GL4ES_POT_SAFE_MIPMAPS_051_V8"
WATER_MARKER = "// TSP_GL4ES_WATER_POT_SAFE_MIPMAPS_051_V8"


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly 1 match, found {count}")
    return text.replace(old, new, 1)


def replace_regex_once(text, pattern, repl, label, flags=0):
    new_text, count = re.subn(pattern, repl, text, count=1, flags=flags)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly 1 regex match, found {count}")
    return new_text


def transactional_write(items):
    temps = []
    try:
        for path, text in items:
            tmp = Path(str(path) + ".tsp-v8.tmp")
            tmp.write_text(text, encoding="utf-8")
            temps.append((path, tmp))
        for path, tmp in temps:
            os.replace(str(tmp), str(path))
    finally:
        for _, tmp in temps:
            try:
                tmp.unlink()
            except FileNotFoundError:
                pass


# ---------------------------------------------------------------------
# CURSOR
# ---------------------------------------------------------------------

if CURSOR_MARKER not in window:
    old = """        // Create all cursors in advance
        createCursors();
        onCursorChange(MyGUI::PointerManager::getInstance().getDefaultPointer());
        mCursorManager->setEnabled(true);

        // hide mygui's pointer
        MyGUI::PointerManager::getInstance().setVisible(false);
"""
    new = f"""        {CURSOR_MARKER}
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
    window = replace_once(window, old, new, "cursor initialization")

if "// TSP_GL4ES_SOFTWARE_CURSOR_CHANGE_051_V8" not in window:
    pattern = (
        r"    void WindowManager::onCursorChange\(std::string_view name\)\n"
        r"    \{\n"
        r"        mCursorManager->cursorChanged\(name\);\n"
        r"    \}\n"
    )
    repl = """    void WindowManager::onCursorChange(std::string_view /*name*/)
    {
        // TSP_GL4ES_SOFTWARE_CURSOR_CHANGE_051_V8
        // MyGUI already changed the software pointer resource.
        // Do not forward this to SDL's invisible hardware-cursor path.
    }
"""
    window = replace_regex_once(
        window, pattern, repl, "onCursorChange", flags=re.MULTILINE
    )

if CURSOR_VIS_MARKER not in window:
    old = """    void WindowManager::setCursorVisible(bool visible)
    {
        mCursorVisible = visible;
    }

    void WindowManager::setCursorActive(bool active)
    {
        mCursorActive = active;
    }
"""
    new = f"""    void WindowManager::setCursorVisible(bool visible)
    {{
        mCursorVisible = visible;

        {CURSOR_VIS_MARKER}
        // GUI-mode visibility is authoritative on TSP. Controller focus can
        // otherwise suppress the pointer while the helper is emulating mouse.
        MyGUI::PointerManager::getInstance().setVisible(mCursorVisible);
    }}

    void WindowManager::setCursorActive(bool active)
    {{
        mCursorActive = active;

        // Preserve the state for normal engine bookkeeping, but do not let the
        // controller-only cursor state hide the framebuffer software pointer.
        MyGUI::PointerManager::getInstance().setVisible(mCursorVisible);
    }}
"""
    window = replace_once(window, old, new, "cursor visibility methods")

if "// TSP_GL4ES_SOFTWARE_CURSOR_GET_VISIBLE_051_V8" not in window:
    old = """    bool WindowManager::getCursorVisible()
    {
        return mCursorVisible && mCursorActive;
    }
"""
    new = """    bool WindowManager::getCursorVisible()
    {
        // TSP_GL4ES_SOFTWARE_CURSOR_GET_VISIBLE_051_V8
        return mCursorVisible;
    }
"""
    window = replace_once(window, old, new, "getCursorVisible")


# ---------------------------------------------------------------------
# POT-SAFE MIPMAP FILTERING
# ---------------------------------------------------------------------

if "#include <osg/Texture2D>" not in scene:
    anchor = "#include <osg/Group>\n"
    if anchor not in scene:
        raise RuntimeError("scenemanager.cpp: osg include anchor not found")
    scene = scene.replace(anchor, anchor + "#include <osg/Texture2D>\n", 1)

if FILTER_MARKER not in scene:
    anchor = "namespace Resource\n{\n"
    if scene.count(anchor) != 1:
        raise RuntimeError(
            f"scenemanager.cpp: expected one Resource namespace anchor, found {scene.count(anchor)}"
        )

    helper = r"""namespace
{
    // TSP_GL4ES_POT_SAFE_MIPMAPS_051_V8
    bool tspIsPowerOfTwo(int value)
    {
        return value > 0 && (value & (value - 1)) == 0;
    }

    bool tspUsesMipmaps(osg::Texture::FilterMode mode)
    {
        return mode == osg::Texture::NEAREST_MIPMAP_NEAREST
            || mode == osg::Texture::LINEAR_MIPMAP_NEAREST
            || mode == osg::Texture::NEAREST_MIPMAP_LINEAR
            || mode == osg::Texture::LINEAR_MIPMAP_LINEAR;
    }

    osg::Texture::FilterMode tspBaseFilter(osg::Texture::FilterMode mode)
    {
        if (mode == osg::Texture::NEAREST_MIPMAP_NEAREST
            || mode == osg::Texture::NEAREST_MIPMAP_LINEAR)
            return osg::Texture::NEAREST;

        return osg::Texture::LINEAR;
    }

    osg::Texture::FilterMode tspSafeMinFilter(
        osg::Texture* texture, osg::Texture::FilterMode requested)
    {
        if (!texture || !tspUsesMipmaps(requested))
            return requested;

        osg::Texture2D* texture2D = dynamic_cast<osg::Texture2D*>(texture);
        if (!texture2D)
            return tspBaseFilter(requested);

        osg::Image* image = texture2D->getImage();
        if (!image)
            return tspBaseFilter(requested);

        if (!tspIsPowerOfTwo(image->s()) || !tspIsPowerOfTwo(image->t()))
            return tspBaseFilter(requested);

        return requested;
    }
}

"""
    scene = scene.replace(anchor, helper + anchor, 1)

old = "                    tex->setFilter(osg::Texture::MIN_FILTER, mMinFilter);\n"
new = "                    tex->setFilter(osg::Texture::MIN_FILTER, tspSafeMinFilter(tex.get(), mMinFilter));\n"
if new not in scene:
    scene = replace_once(scene, old, new, "FlipController min filter")

old = "                tex->setFilter(osg::Texture::MIN_FILTER, mMinFilter);\n"
new = "                tex->setFilter(osg::Texture::MIN_FILTER, tspSafeMinFilter(tex, mMinFilter));\n"
if new not in scene:
    scene = replace_once(scene, old, new, "StateSet min filter")

if "TSP_GL4ES_POT_SAFE_MIPMAP_APPLY_051_V8" not in scene:
    old = """    void SceneManager::applyFilterSettings(osg::Texture* tex)
    {
        tex->setFilter(osg::Texture::MIN_FILTER, mMinFilter);
        tex->setFilter(osg::Texture::MAG_FILTER, mMagFilter);
        tex->setMaxAnisotropy(mMaxAnisotropy);
    }
"""
    new = """    void SceneManager::applyFilterSettings(osg::Texture* tex)
    {
        // TSP_GL4ES_POT_SAFE_MIPMAP_APPLY_051_V8
        tex->setFilter(osg::Texture::MIN_FILTER, tspSafeMinFilter(tex, mMinFilter));
        tex->setFilter(osg::Texture::MAG_FILTER, mMagFilter);
        tex->setMaxAnisotropy(mMaxAnisotropy);
    }
"""
    scene = replace_once(scene, old, new, "applyFilterSettings")


# ---------------------------------------------------------------------
# WATER
# ---------------------------------------------------------------------

if "TSP_GL4ES_WATER_LINEAR_FILTER_051_V7" in water:
    pattern = (
        r"[ \t]*// TSP_GL4ES_WATER_LINEAR_FILTER_051_V7[^\n]*\n"
        r"[ \t]*tex->setFilter\(osg::Texture::MIN_FILTER, osg::Texture::LINEAR\);\n"
        r"[ \t]*tex->setFilter\(osg::Texture::MAG_FILTER, osg::Texture::LINEAR\);\n"
    )
    water, count = re.subn(pattern, "", water, count=1)
    if count != 1:
        raise RuntimeError(
            "water.cpp: v7 filter marker exists but expected LINEAR override was not found"
        )

if WATER_MARKER not in water:
    needle = "            mResourceSystem->getSceneManager()->applyFilterSettings(tex);\n"
    if water.count(needle) != 1:
        raise RuntimeError(
            "water.cpp: expected exactly one applyFilterSettings(tex) in simple water"
        )
    replacement = (
        "            " + WATER_MARKER + "\n"
        "            // POT water frames may use mipmaps; NPOT frames are safely\n"
        "            // downgraded by SceneManager.\n"
        + needle
    )
    water = water.replace(needle, replacement, 1)


# ---------------------------------------------------------------------
# VERIFY
# ---------------------------------------------------------------------

for token in (
    "TSP_GL4ES_SOFTWARE_CURSOR_051_V8",
    "TSP_GL4ES_SOFTWARE_CURSOR_VISIBILITY_051_V8",
    "TSP_GL4ES_SOFTWARE_CURSOR_CHANGE_051_V8",
    "TSP_GL4ES_SOFTWARE_CURSOR_GET_VISIBLE_051_V8",
):
    if token not in window:
        raise RuntimeError("windowmanagerimp.cpp missing marker: " + token)

if "MyGUI::PointerManager::getInstance().setVisible(false);" in window:
    raise RuntimeError(
        "windowmanagerimp.cpp still contains stock global MyGUI pointer hide"
    )

for token in (
    "TSP_GL4ES_POT_SAFE_MIPMAPS_051_V8",
    "TSP_GL4ES_POT_SAFE_MIPMAP_APPLY_051_V8",
    "tspSafeMinFilter",
    "tspIsPowerOfTwo",
):
    if token not in scene:
        raise RuntimeError("scenemanager.cpp missing marker/function: " + token)

for token in (
    "TSP_GL4ES_WATER_DENSE_GRID_051_V7",
    "TSP_GL4ES_WATER_POT_SAFE_MIPMAPS_051_V8",
):
    if token not in water:
        raise RuntimeError("water.cpp missing marker: " + token)

if "TSP_GL4ES_WATER_LINEAR_FILTER_051_V7" in water:
    raise RuntimeError("water.cpp still contains v7 forced-linear marker")

transactional_write(
    (
        (window_path, window),
        (scene_path, scene),
        (water_path, water),
    )
)

print("v8 source patch applied:")
print(" ", window_path)
print(" ", scene_path)
print(" ", water_path)
print()
print("Cursor: framebuffer-rendered MyGUI software pointer.")
print("Textures: mipmaps retained only for known POT Texture2D images.")
print("Water: POT-safe policy now applies to animated water frames.")
PY_PATCH

echo
echo "v8 verification markers:"
grep -n \
    -e 'TSP_GL4ES_SOFTWARE_CURSOR_051_V8' \
    -e 'TSP_GL4ES_SOFTWARE_CURSOR_VISIBILITY_051_V8' \
    -e 'TSP_GL4ES_SOFTWARE_CURSOR_CHANGE_051_V8' \
    -e 'TSP_GL4ES_SOFTWARE_CURSOR_GET_VISIBLE_051_V8' \
    "$WINDOW_CPP"

grep -n \
    -e 'TSP_GL4ES_POT_SAFE_MIPMAPS_051_V8' \
    -e 'TSP_GL4ES_POT_SAFE_MIPMAP_APPLY_051_V8' \
    "$SCENE_CPP"

grep -n \
    -e 'TSP_GL4ES_WATER_DENSE_GRID_051_V7' \
    -e 'TSP_GL4ES_WATER_POT_SAFE_MIPMAPS_051_V8' \
    "$WATER_CPP"

if [ "$PATCH_ONLY" = "1" ]; then
    trap - ERR
    echo
    echo "PATCH_ONLY=1: source patch and verification completed."
    exit 0
fi

COLLADA_REAL=""
for candidate in \
    /usr/lib/libcollada-dom2.4-dp.so \
    /usr/lib/aarch64-linux-gnu/libcollada-dom2.4-dp.so \
    /usr/local/lib/libcollada-dom2.4-dp.so
do
    if [ -e "$candidate" ]; then
        COLLADA_REAL="$(readlink -f "$candidate")"
        break
    fi
done

if [ -n "$COLLADA_REAL" ]; then
    mkdir -p /root/openmw-0.51-tsp-link-compat
    ln -sfn "$COLLADA_REAL" /root/openmw-0.51-tsp-link-compat/libcollada-dom2.5-dp.so
    ln -sfn "$COLLADA_REAL" /usr/lib/libcollada-dom2.5-dp.so
fi

echo
echo "Incrementally rebuilding OpenMW..."
cmake --build "$BUILD_DIR" --target openmw --parallel "$JOBS"

if cmake --build "$BUILD_DIR" --target help 2>/dev/null | grep -q 'openmw-navmeshtool'; then
    echo
    echo "Relinking openmw-navmeshtool against updated components..."
    cmake --build "$BUILD_DIR" --target openmw-navmeshtool --parallel "$JOBS"
fi

if [ ! -x "$BUILT_BINARY" ]; then
    echo "ERROR: rebuilt OpenMW executable missing:"
    echo "  $BUILT_BINARY"
    exit 1
fi

if [ -e "$OUTPUT_BINARY" ]; then
    cp -f "$OUTPUT_BINARY" "$OUTPUT_BINARY.before-$STAMP"
fi
if [ -e "$PACKAGE_BINARY" ]; then
    cp -f "$PACKAGE_BINARY" "$PACKAGE_BINARY.before-software-cursor-mipmap-v8-$STAMP"
fi

cp -f "$BUILT_BINARY" "$OUTPUT_BINARY"
cp -f "$BUILT_BINARY" "$PACKAGE_BINARY"
chmod +x "$OUTPUT_BINARY" "$PACKAGE_BINARY"

NAVMESH_TOOL="$(
    find "$BUILD_DIR" \
        -type f \
        -name 'openmw-navmeshtool' \
        -perm -111 \
        -print 2>/dev/null \
        | head -1
)"

if [ -n "$NAVMESH_TOOL" ]; then
    cp -f "$NAVMESH_TOOL" "$PACKAGE_NAVTOOL"
    chmod +x "$PACKAGE_NAVTOOL"
fi

STRIP_TOOL=""
if command -v aarch64-linux-gnu-strip >/dev/null 2>&1; then
    STRIP_TOOL="$(command -v aarch64-linux-gnu-strip)"
elif command -v strip >/dev/null 2>&1; then
    STRIP_TOOL="$(command -v strip)"
fi

if [ -n "$STRIP_TOOL" ]; then
    "$STRIP_TOOL" --strip-unneeded "$OUTPUT_BINARY"
    "$STRIP_TOOL" --strip-unneeded "$PACKAGE_BINARY"
    if [ -f "$PACKAGE_NAVTOOL" ]; then
        "$STRIP_TOOL" --strip-unneeded "$PACKAGE_NAVTOOL"
    fi
fi

if readelf -d "$PACKAGE_BINARY" 2>/dev/null \
    | grep -q 'Shared library: \[libcollada-dom2.5-dp'
then
    echo "ERROR: packaged OpenMW retained fake COLLADA 2.5 runtime name."
    exit 1
fi

cat > "$PACKAGE_TOOLS/apply-runtime-profile-v8.sh" <<'EOF_RUNTIME'
#!/bin/bash
set -Eeuo pipefail

GAMEDIR="${OPENMW51_GAMEDIR:-/mnt/SDCARD/data/ports/openmw51}"
SETTINGS="$GAMEDIR/config-0.51/settings.cfg"

LAUNCHER=""
for candidate in \
    /mnt/SDCARD/Roms/PORTS/Morrowind_51.sh \
    /mnt/SDCARD/Emus/PORTS/../../Roms/PORTS/Morrowind_51.sh
do
    if [ -f "$candidate" ]; then
        LAUNCHER="$(readlink -f "$candidate" 2>/dev/null || printf '%s' "$candidate")"
        break
    fi
done

if [ ! -f "$SETTINGS" ]; then
    echo "ERROR: settings.cfg not found:"
    echo "  $SETTINGS"
    exit 1
fi

if [ -z "$LAUNCHER" ] || [ ! -f "$LAUNCHER" ]; then
    echo "ERROR: Morrowind_51.sh launcher not found."
    exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
SETTINGS_BACKUP="$SETTINGS.before-v8-$STAMP"
LAUNCHER_BACKUP="$LAUNCHER.before-v8-$STAMP"

cp -f "$SETTINGS" "$SETTINGS_BACKUP"
cp -f "$LAUNCHER" "$LAUNCHER_BACKUP"

echo "Backups:"
echo "  $SETTINGS_BACKUP"
echo "  $LAUNCHER_BACKUP"

python3 - "$SETTINGS" <<'PY_SETTINGS'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace")

changes = {
    "Camera": {
        "near clip": "15",
    },
    "General": {
        "texture mag filter": "linear",
        "texture min filter": "linear",
        "texture mipmap": "nearest",
        "anisotropy": "1",
    },
}

def set_key(source, section, key, value):
    section_re = re.compile(rf"(?mi)^\[{re.escape(section)}\][ \t]*$")
    match = section_re.search(source)

    if not match:
        if source and not source.endswith("\n"):
            source += "\n"
        return source + f"\n[{section}]\n{key} = {value}\n"

    next_section = re.search(r"(?m)^\[[^\]]+\][ \t]*$", source[match.end():])
    end = match.end() + next_section.start() if next_section else len(source)
    body = source[match.end():end]

    lines = body.splitlines()
    result = []
    replaced = False

    for line in lines:
        if re.match(rf"(?i)^[ \t]*{re.escape(key)}[ \t]*=", line):
            if replaced:
                continue
            indent = re.match(r"^[ \t]*", line).group(0)
            result.append(f"{indent}{key} = {value}")
            replaced = True
        else:
            result.append(line)

    if not replaced:
        result.insert(0, f"{key} = {value}")

    body = "\n".join(result)
    if source[match.end():end].endswith("\n") and not body.endswith("\n"):
        body += "\n"

    return source[:match.end()] + body + source[end:]

for section, entries in changes.items():
    for key, value in entries.items():
        text = set_key(text, section, key, value)

path.write_text(text, encoding="utf-8")
PY_SETTINGS

python3 - "$LAUNCHER" <<'PY_LAUNCHER'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace")

def set_export(source, name, value):
    pattern = re.compile(rf"(?m)^[ \t]*export[ \t]+{re.escape(name)}=.*$")
    matches = list(pattern.finditer(source))
    if len(matches) != 1:
        raise RuntimeError(
            f"Expected exactly one 'export {name}=...' line; found {len(matches)}"
        )
    return pattern.sub(f"export {name}={value}", source, count=1)

text = set_export(text, "LIBGL_MIPMAP", "2")
text = set_export(text, "LIBGL_FORCENPOT", "0")

if not re.search(r"(?m)^[ \t]*export[ \t]+LIBGL_NOTEST=1[ \t]*$", text):
    raise RuntimeError("Expected known-good 'export LIBGL_NOTEST=1' launcher setting")

path.write_text(text, encoding="utf-8")
PY_LAUNCHER

echo
echo "===== V8 TEXTURE SETTINGS ====="
awk '
/^\[/ { section=$0 }
$0 ~ /^(near clip|texture mag filter|texture min filter|texture mipmap|anisotropy)[[:space:]]*=/ {
    if (section == "[Camera]" || section == "[General]")
        print section " " $0
}
' "$SETTINGS"

echo
echo "===== V8 GL4ES SETTINGS ====="
grep -nE 'export LIBGL_(MIPMAP|FORCENPOT|NOTEST)=' "$LAUNCHER"

grep -q '^export LIBGL_MIPMAP=2$' "$LAUNCHER"
grep -q '^export LIBGL_FORCENPOT=0$' "$LAUNCHER"
grep -q '^export LIBGL_NOTEST=1$' "$LAUNCHER"

echo
echo "V8 runtime profile applied."
echo "POT mipmaps enabled through GL4ES/OpenMW safety gate."
echo "NPOT textures remain non-mipmapped."
echo "near clip remains 15."
EOF_RUNTIME

chmod +x "$PACKAGE_TOOLS/apply-runtime-profile-v8.sh"

cat > "$PACKAGE_TOOLS/README_V8_CURSOR_MIPMAP.txt" <<'EOF_README'
OpenMW 0.51 TSP v8 - software cursor + POT-safe mipmaps
=======================================================

Install:
  /mnt/SDCARD/data/ports/openmw51/bin/openmw-0.51

Then run once:
  /mnt/SDCARD/data/ports/openmw51/tools/apply-runtime-profile-v8.sh

Cursor:
  SDL hardware cursor = disabled
  MyGUI framebuffer cursor = enabled
  No extra cursor image should be required.

Texture experiment:
  LIBGL_MIPMAP=2
  LIBGL_FORCENPOT=0
  LIBGL_NOTEST=1

  POT Texture2D  -> mipmap filtering allowed
  NPOT Texture2D -> base filtering only

settings.cfg:
  texture mag filter = linear
  texture min filter = linear
  texture mipmap = nearest
  anisotropy = 1

Test:
  - lily pads
  - known wobbling boulder
  - distant water while stationary
  - distant water while moving
  - small bog ponds at increasing distance
  - menu pointer movement/clicks
  - resize pointer shapes
  - inventory drag/drop

Preserved:
  direct framebuffer v2
  NiLOD v4
  v7 dense water
  v7 memory trim
  Project Atlas/MOP
  near clip 15
EOF_README

echo
echo "Packaged runtime helper:"
ls -lh \
    "$PACKAGE_TOOLS/apply-runtime-profile-v8.sh" \
    "$PACKAGE_TOOLS/README_V8_CURSOR_MIPMAP.txt"

echo
echo "Binary verification:"
file "$PACKAGE_BINARY"
"$PACKAGE_BINARY" --version || true

trap - ERR

echo
echo "============================================================"
echo "SUCCESS: OpenMW 0.51 TSP v8 built"
echo "============================================================"
echo "Standalone binary:"
echo "  $OUTPUT_BINARY"
echo
echo "Package binary:"
echo "  $PACKAGE_BINARY"
echo
echo "Runtime helper:"
echo "  $PACKAGE_TOOLS/apply-runtime-profile-v8.sh"
echo
echo "Source backup:"
echo "  $BACKUP_DIR"
echo
echo "V8 changes:"
echo "  - framebuffer-rendered MyGUI software cursor"
echo "  - SDL hardware cursor bypass"
echo "  - POT-safe SceneManager mipmap filtering"
echo "  - POT-safe animated water filtering"
echo "  - runtime LIBGL_MIPMAP 3 -> 2"
echo "  - runtime LIBGL_FORCENPOT 1 -> 0"
echo "============================================================"
