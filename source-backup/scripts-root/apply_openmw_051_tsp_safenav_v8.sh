#!/bin/bash
set -Eeuo pipefail

# OpenMW 0.51 / TrimUI Smart Pro S
# TSP SafeNav hard-stability incremental rebuild v8
#
# Purpose:
#   Remove the runtime Recast/Detour navigation subsystem from the default TSP
#   gameplay path after the v7 pre-generated navmesh/cache work substantially
#   improved runtime but a later exterior/combat run still ended in SIGSEGV.
#
# Baseline expected:
#   - OpenMW 0.51.0 source at /root/openmw-0.51-tsp-src
#   - existing configured Ninja build at /root/openmw-0.51-tsp-build
#   - v7 water/memory/navmesh-tooling patch already applied
#   - legacy direct-framebuffer v2 retained (same renderer baseline as v7)
#   - NiLOD overlap/reload v4 retained
#
# v8 source changes:
#   1. World::init defaults to DetourNavigator::makeNavigatorStub().
#      The real Navigator is created only when BOTH:
#          OPENMW_TSP_ENABLE_NAVIGATOR=1
#          [Navigator] enable = true
#      Therefore normal v8 gameplay starts no Recast updater workers and does
#      not open/generate/write the navmesh database through the live Navigator.
#   2. PathFinder::buildPathByNavigatorImpl independently returns
#      Status::NavMeshNotFound unless OPENMW_TSP_ENABLE_NAVIGATOR=1.
#      Existing OpenMW code then uses its normal pathgrid/straight fallback.
#   3. Package a SafeNav runtime profile that sets:
#          [Navigator] enable = false
#          enable nav mesh disk cache = true
#          write to navmeshdb = false
#      The existing navmesh.db is PRESERVED, not deleted.
#   4. Do not strip the v8 OpenMW binary, improving the usefulness of a future
#      gdb stack trace if a non-navigation crash remains.
#   5. Best-effort package libncursesw.so.5/libtinfo.so.5 into package/lib so
#      the TSP's existing gdb crash helper can start when those ABI-5 libraries
#      are available from the build container.
#
# Build behavior:
#   - NO CMake reconfiguration
#   - NO clean build
#   - NO rebuild of MyGUI, SDL2, OSG, navmeshtool, or unchanged OpenMW files
#   - only source files changed by v8 are recompiled by Ninja
#
# Escape hatch for a later controlled cached-Navigator test:
#   export OPENMW_TSP_ENABLE_NAVIGATOR=1
#   and set [Navigator] enable = true
#   Keep write to navmeshdb = false for that test.

SOURCE_DIR="${1:-/root/openmw-0.51-tsp-src}"
BUILD_DIR="${2:-/root/openmw-0.51-tsp-build}"
PACKAGE_DIR="${3:-/root/openmw-0.51-tsp-package}"
OUTPUT_BINARY="${4:-/root/openmw-0.51-tsp-safenav-v8}"
OUTPUT_BUNDLE="${5:-/root/openmw-0.51-tsp-safenav-v8-bundle.tar.gz}"

JOBS="${OPENMW_JOBS:-$(nproc)}"
PATCH_ONLY="${OPENMW_PATCH_ONLY:-0}"

PATHFINDING_CPP="$SOURCE_DIR/apps/openmw/mwmechanics/pathfinding.cpp"
WORLDIMP_CPP="$SOURCE_DIR/apps/openmw/mwworld/worldimp.cpp"
WATER_CPP="$SOURCE_DIR/apps/openmw/mwrender/water.cpp"
RESOURCE_CPP="$SOURCE_DIR/components/resource/resourcesystem.cpp"
POST_CPP="$SOURCE_DIR/apps/openmw/mwrender/postprocessor.cpp"
NIFLOADER_CPP="$SOURCE_DIR/components/nifosg/nifloader.cpp"
CMAKE_FILE="$SOURCE_DIR/CMakeLists.txt"

BUILT_BINARY="$BUILD_DIR/openmw"
PACKAGE_BINARY="$PACKAGE_DIR/bin/openmw-0.51"
PACKAGE_TOOLS_DIR="$PACKAGE_DIR/tools"
PACKAGE_LIB_DIR="$PACKAGE_DIR/lib"
RUNTIME_HELPER="$PACKAGE_TOOLS_DIR/apply-runtime-profile-v8.sh"
README_V8="$PACKAGE_TOOLS_DIR/README_V8.txt"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$SOURCE_DIR/.tsp-051-source-backups/safenav-v8-$STAMP"
SCRIPT_REVISION="TSP-051-SAFENAV-V8-2026-08-08"

restore_on_error() {
    result=$?
    if [ "$result" -ne 0 ] && [ -d "$BACKUP_DIR" ]; then
        echo
        echo "ERROR: v8 patch/build failed."
        echo "Restoring source files modified by v8..."
        for rel in \
            apps/openmw/mwmechanics/pathfinding.cpp \
            apps/openmw/mwworld/worldimp.cpp
        do
            if [ -f "$BACKUP_DIR/$rel" ]; then
                cp -f "$BACKUP_DIR/$rel" "$SOURCE_DIR/$rel"
            fi
        done
        echo "Source restoration complete."
        echo "Failed-attempt backup retained at:"
        echo "  $BACKUP_DIR"
    fi
    exit "$result"
}
trap restore_on_error ERR

echo "============================================================"
echo "OpenMW 0.51 TSP SafeNav hard-stability rebuild v8"
echo "Revision: $SCRIPT_REVISION"
echo "============================================================"
echo "Source:        $SOURCE_DIR"
echo "Build:         $BUILD_DIR"
echo "Package:       $PACKAGE_DIR"
echo "Output binary: $OUTPUT_BINARY"
echo "Output bundle: $OUTPUT_BUNDLE"
echo "Patch only:    $PATCH_ONLY"
echo "Jobs:          $JOBS"
echo "Backup:        $BACKUP_DIR"
echo "============================================================"

for required in \
    "$PATHFINDING_CPP" \
    "$WORLDIMP_CPP" \
    "$WATER_CPP" \
    "$RESOURCE_CPP" \
    "$POST_CPP" \
    "$NIFLOADER_CPP" \
    "$CMAKE_FILE"
do
    if [ ! -f "$required" ]; then
        echo "ERROR: required source file is missing:"
        echo "  $required"
        exit 1
    fi
done

VERSION_MAJOR="$(
    sed -n \
        's/^[[:space:]]*set(OPENMW_VERSION_MAJOR[[:space:]]*\([0-9][0-9]*\)).*/\1/p' \
        "$CMAKE_FILE" | head -1
)"
VERSION_MINOR="$(
    sed -n \
        's/^[[:space:]]*set(OPENMW_VERSION_MINOR[[:space:]]*\([0-9][0-9]*\)).*/\1/p' \
        "$CMAKE_FILE" | head -1
)"

if [ "$VERSION_MAJOR" != "0" ] || [ "$VERSION_MINOR" != "51" ]; then
    echo "ERROR: expected OpenMW 0.51 source."
    echo "Detected: ${VERSION_MAJOR:-?}.${VERSION_MINOR:-?}"
    exit 1
fi

# Verify the exact v7 baseline we are intentionally preserving.
for marker_file in \
    "TSP_GL4ES_WATER_DENSE_GRID_051_V7|$WATER_CPP" \
    "TSP_GL4ES_WATER_LINEAR_FILTER_051_V7|$WATER_CPP" \
    "TSP_MEMORY_TRIM_UPDATE_051_V7|$RESOURCE_CPP" \
    "TSP_MEMORY_TRIM_CLEAR_051_V7|$RESOURCE_CPP" \
    "TSP_LEGACY_DIRECT_RENDER_051_V2|$POST_CPP" \
    "TSP_NILOD_OVERLAP_FIX_051_V4|$NIFLOADER_CPP" \
    "TSP_NILOD_OVERLAP_APPLY_051_V4|$NIFLOADER_CPP"
do
    IFS='|' read -r marker file <<< "$marker_file"
    if ! grep -Fq "$marker" "$file"; then
        echo "ERROR: required v7 baseline marker is missing:"
        echo "  $marker"
        echo "from:"
        echo "  $file"
        echo "Refusing to patch a different source baseline."
        exit 1
    fi
done

if [ "$PATCH_ONLY" != "1" ]; then
    if [ ! -f "$BUILD_DIR/build.ninja" ] || [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
        echo "ERROR: existing configured Ninja build tree is missing."
        echo "This v8 script intentionally does not reconfigure from scratch."
        exit 1
    fi
fi

mkdir -p \
    "$BACKUP_DIR/apps/openmw/mwmechanics" \
    "$BACKUP_DIR/apps/openmw/mwworld" \
    "$PACKAGE_DIR/bin" \
    "$PACKAGE_TOOLS_DIR" \
    "$PACKAGE_LIB_DIR"

cp -f "$PATHFINDING_CPP" \
    "$BACKUP_DIR/apps/openmw/mwmechanics/pathfinding.cpp"
cp -f "$WORLDIMP_CPP" \
    "$BACKUP_DIR/apps/openmw/mwworld/worldimp.cpp"

echo
echo "Applying v8 SafeNav source changes..."

python3 - "$PATHFINDING_CPP" "$WORLDIMP_CPP" <<'PY_PATCH'
from pathlib import Path
import os
import re
import sys

pathfinding_path = Path(sys.argv[1])
worldimp_path = Path(sys.argv[2])

pathfinding = pathfinding_path.read_text(encoding="utf-8")
worldimp = worldimp_path.read_text(encoding="utf-8")

PATH_MARKER = "// TSP_SAFENAV_PATH_QUERY_BYPASS_051_V8"
WORLD_MARKER = "// TSP_SAFENAV_FORCE_STUB_051_V8"
ENV_NAME = "OPENMW_TSP_ENABLE_NAVIGATOR"


def find_function(text, signature_pattern, label):
    matches = list(re.finditer(signature_pattern, text, flags=re.MULTILINE))
    if len(matches) != 1:
        raise RuntimeError(
            f"{label}: expected exactly one function signature; found {len(matches)}"
        )

    start = matches[0].start()
    opening = text.find("{", matches[0].end())
    if opening < 0:
        raise RuntimeError(f"{label}: opening brace not found")

    depth = 0
    in_string = False
    in_char = False
    in_line_comment = False
    in_block_comment = False
    escaped = False
    index = opening

    while index < len(text):
        char = text[index]
        next_char = text[index + 1] if index + 1 < len(text) else ""

        if in_line_comment:
            if char == "\n":
                in_line_comment = False
            index += 1
            continue

        if in_block_comment:
            if char == "*" and next_char == "/":
                in_block_comment = False
                index += 2
                continue
            index += 1
            continue

        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            index += 1
            continue

        if in_char:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == "'":
                in_char = False
            index += 1
            continue

        if char == "/" and next_char == "/":
            in_line_comment = True
            index += 2
            continue

        if char == "/" and next_char == "*":
            in_block_comment = True
            index += 2
            continue

        if char == '"':
            in_string = True
            index += 1
            continue

        if char == "'":
            in_char = True
            index += 1
            continue

        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                end = index + 1
                if end < len(text) and text[end] == "\n":
                    end += 1
                return start, opening, end

        index += 1

    raise RuntimeError(f"{label}: closing brace not found")


def ensure_cstdlib(text, label):
    if "#include <cstdlib>" in text:
        return text

    includes = list(re.finditer(r"^#include[^\n]*\n", text, flags=re.MULTILINE))
    if not includes:
        raise RuntimeError(f"{label}: include insertion point not found")

    pos = includes[-1].end()
    return text[:pos] + "#include <cstdlib>\n" + text[pos:]


def transactional_write(items):
    temps = []
    try:
        for path, text in items:
            tmp = Path(str(path) + ".tsp-v8.tmp")
            with tmp.open("w", encoding="utf-8", newline="\n") as handle:
                handle.write(text)
            temps.append((path, tmp))

        for path, tmp in temps:
            os.replace(str(tmp), str(path))
    finally:
        for _, tmp in temps:
            try:
                tmp.unlink()
            except FileNotFoundError:
                pass


pathfinding = ensure_cstdlib(pathfinding, "pathfinding.cpp")
worldimp = ensure_cstdlib(worldimp, "worldimp.cpp")

# =====================================================================
# 1. PATHFINDER: HARD DEFAULT BYPASS OF DETOUR QUERIES
# =====================================================================

if PATH_MARKER not in pathfinding:
    start, opening, end = find_function(
        pathfinding,
        r"^[ \t]*DetourNavigator::Status[ \t]+PathFinder::buildPathByNavigatorImpl[ \t]*\(",
        "PathFinder::buildPathByNavigatorImpl",
    )
    func = pathfinding[start:end]
    local_opening = opening - start

    if "DetourNavigator::findPath(" not in func:
        raise RuntimeError(
            "buildPathByNavigatorImpl no longer contains DetourNavigator::findPath"
        )

    body_insert = local_opening + 1
    block = r'''
        // TSP_SAFENAV_PATH_QUERY_BYPASS_051_V8
        // Default-safe TrimUI path: never enter Detour queries unless explicitly
        // opted back in through OPENMW_TSP_ENABLE_NAVIGATOR=1.
        const char* tspEnableNavigator = std::getenv("OPENMW_TSP_ENABLE_NAVIGATOR");
        if (tspEnableNavigator == nullptr || tspEnableNavigator[0] != '1'
            || tspEnableNavigator[1] != '\0')
        {
            return DetourNavigator::Status::NavMeshNotFound;
        }
'''
    func = func[:body_insert] + block + func[body_insert:]
    pathfinding = pathfinding[:start] + func + pathfinding[end:]

# =====================================================================
# 2. WORLD INIT: DO NOT START NAVIGATOR/RECAST WORKERS BY DEFAULT
# =====================================================================

if WORLD_MARKER not in worldimp:
    start, opening, end = find_function(
        worldimp,
        r"^[ \t]*void[ \t]+World::init[ \t]*\(",
        "World::init",
    )
    func = worldimp[start:end]

    nav_pattern = re.compile(
        r"(?P<indent>^[ \t]*)if[ \t]*\([ \t]*Settings::navigator\(\)\.mEnable[ \t]*\)[ \t\r\n]*"
        r"\{[ \t\r\n]*"
        r"auto[ \t]+navigatorSettings[ \t]*=[ \t]*DetourNavigator::makeSettingsFromSettingsManager\(maxRecastLogLevel\);[ \t\r\n]*"
        r"navigatorSettings\.mRecast\.mSwimHeightScale[ \t]*=[ \t]*mSwimHeightScale;[ \t\r\n]*"
        r"mNavigator[ \t]*=[ \t]*DetourNavigator::makeNavigator\(navigatorSettings,[ \t]*mUserDataPath\);[ \t\r\n]*"
        r"\}[ \t\r\n]*else[ \t\r\n]*\{[ \t\r\n]*"
        r"mNavigator[ \t]*=[ \t]*DetourNavigator::makeNavigatorStub\(\);[ \t\r\n]*"
        r"\}",
        flags=re.MULTILINE,
    )

    matches = list(nav_pattern.finditer(func))
    if len(matches) != 1:
        nearby = "\n".join(
            line
            for line in func.splitlines()
            if "navigator" in line.lower() or "mNavigator" in line
        )
        raise RuntimeError(
            "World::init Navigator block: expected exactly one stock-compatible block; "
            f"found {len(matches)}.\nNearby:\n{nearby}"
        )

    m = matches[0]
    indent = m.group("indent")
    inner = indent + "    "
    replacement = (
        indent + WORLD_MARKER + "\n"
        + indent + "const char* tspEnableNavigator = std::getenv(\"OPENMW_TSP_ENABLE_NAVIGATOR\");\n"
        + indent + "const bool tspNavigatorOptIn = tspEnableNavigator != nullptr\n"
        + inner + "&& tspEnableNavigator[0] == '1' && tspEnableNavigator[1] == '\\0';\n\n"
        + indent + "if (tspNavigatorOptIn && Settings::navigator().mEnable)\n"
        + indent + "{\n"
        + inner + "auto navigatorSettings = DetourNavigator::makeSettingsFromSettingsManager(maxRecastLogLevel);\n"
        + inner + "navigatorSettings.mRecast.mSwimHeightScale = mSwimHeightScale;\n"
        + inner + "mNavigator = DetourNavigator::makeNavigator(navigatorSettings, mUserDataPath);\n"
        + indent + "}\n"
        + indent + "else\n"
        + indent + "{\n"
        + inner + "if (Settings::navigator().mEnable)\n"
        + inner + "    Log(Debug::Info) << \"TSP SafeNav v8: Navigator forced to stub; \"\n"
        + inner + "                     << \"set OPENMW_TSP_ENABLE_NAVIGATOR=1 to opt back in.\";\n"
        + inner + "mNavigator = DetourNavigator::makeNavigatorStub();\n"
        + indent + "}"
    )

    func = func[:m.start()] + replacement + func[m.end():]
    worldimp = worldimp[:start] + func + worldimp[end:]


for token in (
    PATH_MARKER,
    'std::getenv("OPENMW_TSP_ENABLE_NAVIGATOR")',
    "return DetourNavigator::Status::NavMeshNotFound;",
):
    if token not in pathfinding:
        raise RuntimeError("pathfinding.cpp verification missing: " + token)

for token in (
    WORLD_MARKER,
    'std::getenv("OPENMW_TSP_ENABLE_NAVIGATOR")',
    "DetourNavigator::makeNavigatorStub()",
    "tspNavigatorOptIn && Settings::navigator().mEnable",
):
    if token not in worldimp:
        raise RuntimeError("worldimp.cpp verification missing: " + token)

transactional_write(
    (
        (pathfinding_path, pathfinding),
        (worldimp_path, worldimp),
    )
)

print("Patched and verified:")
print(" ", pathfinding_path)
print(" ", worldimp_path)
print()
print("SafeNav v8 default:")
print("  - real Navigator creation: blocked")
print("  - Recast background workers: blocked")
print("  - Detour path queries: blocked")
print("  - OpenMW pathgrid/straight fallback: preserved")
print("  - opt-in escape hatch: OPENMW_TSP_ENABLE_NAVIGATOR=1")
PY_PATCH

echo
echo "v8 source verification markers:"
grep -n \
    -e 'TSP_SAFENAV_PATH_QUERY_BYPASS_051_V8' \
    -e 'OPENMW_TSP_ENABLE_NAVIGATOR' \
    "$PATHFINDING_CPP" | head -10

grep -n \
    -e 'TSP_SAFENAV_FORCE_STUB_051_V8' \
    -e 'OPENMW_TSP_ENABLE_NAVIGATOR' \
    "$WORLDIMP_CPP" | head -12

echo
echo "Preserved v7 markers:"
grep -n \
    -e 'TSP_GL4ES_WATER_DENSE_GRID_051_V7' \
    -e 'TSP_GL4ES_WATER_LINEAR_FILTER_051_V7' \
    "$WATER_CPP"
grep -n \
    -e 'TSP_MEMORY_TRIM_UPDATE_051_V7' \
    -e 'TSP_MEMORY_TRIM_CLEAR_051_V7' \
    "$RESOURCE_CPP"
grep -n 'TSP_LEGACY_DIRECT_RENDER_051_V2' "$POST_CPP" | head -3
grep -n \
    -e 'TSP_NILOD_OVERLAP_FIX_051_V4' \
    -e 'TSP_NILOD_OVERLAP_APPLY_051_V4' \
    "$NIFLOADER_CPP" | head -6

if [ "$PATCH_ONLY" = "1" ]; then
    trap - ERR
    echo
    echo "PATCH_ONLY=1: SafeNav source patching and verification completed."
    echo "Incremental build intentionally skipped."
    exit 0
fi

echo
echo "CMake/build-tree verification:"
CXX_COMPILER="$(
    sed -n 's/^CMAKE_CXX_COMPILER:[^=]*=//p' \
        "$BUILD_DIR/CMakeCache.txt" | head -1
)"
BUILD_TYPE="$(
    sed -n 's/^CMAKE_BUILD_TYPE:[^=]*=//p' \
        "$BUILD_DIR/CMakeCache.txt" | head -1
)"
NAVMESH_ENABLED="$(
    sed -n 's/^BUILD_NAVMESHTOOL:BOOL=//p' \
        "$BUILD_DIR/CMakeCache.txt" | head -1
)"
printf '  C++ compiler:       %s\n' "${CXX_COMPILER:-unknown}"
printf '  CMake build type:   %s\n' "${BUILD_TYPE:-unknown}"
printf '  BUILD_NAVMESHTOOL:  %s\n' "${NAVMESH_ENABLED:-unknown}"
echo "  CMake regeneration: SKIPPED intentionally"

echo
echo "Incrementally rebuilding only the changed OpenMW target..."
cmake --build \
    "$BUILD_DIR" \
    --target openmw \
    --parallel "$JOBS"

if [ ! -x "$BUILT_BINARY" ]; then
    echo "ERROR: rebuilt OpenMW executable is missing:"
    echo "  $BUILT_BINARY"
    exit 1
fi

echo
echo "Packaging UNSTRIPPED v8 binary..."
if [ -e "$OUTPUT_BINARY" ]; then
    cp -f "$OUTPUT_BINARY" "$OUTPUT_BINARY.before-$STAMP"
fi
if [ -e "$PACKAGE_BINARY" ]; then
    cp -f \
        "$PACKAGE_BINARY" \
        "$PACKAGE_BINARY.before-safenav-v8-$STAMP"
fi

cp -f "$BUILT_BINARY" "$OUTPUT_BINARY"
cp -f "$BUILT_BINARY" "$PACKAGE_BINARY"
chmod +x "$OUTPUT_BINARY" "$PACKAGE_BINARY"

# Deliberately DO NOT strip the v8 OpenMW binaries. If another SIGSEGV remains,
# keeping the symbol table gives the device crash debugger a better chance of
# returning useful function names.

echo
echo "Creating SafeNav v8 runtime profile helper..."
cat > "$RUNTIME_HELPER" <<'EOF_RUNTIME'
#!/bin/bash
set -eu

GAMEDIR="${OPENMW51_GAMEDIR:-/mnt/SDCARD/data/ports/openmw51}"
CFG="$GAMEDIR/config-0.51/openmw.cfg"
COMPAT="$GAMEDIR/config-0.51/openmw/openmw.cfg"
SETTINGS="$GAMEDIR/config-0.51/settings.cfg"
NAVDB="$GAMEDIR/savegame-0.51/navmesh.db"
STAMP="$(date +%Y%m%d-%H%M%S)"

for required in "$CFG" "$SETTINGS"; do
    if [ ! -f "$required" ]; then
        echo "ERROR: missing:"
        echo "  $required"
        exit 1
    fi
done

cp -f "$CFG" "$CFG.before-safenav-v8-$STAMP"
cp -f "$SETTINGS" "$SETTINGS.before-safenav-v8-$STAMP"

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
    "Terrain": {
        "object paging active grid": "false",
        "water culling": "true",
    },
    "Cells": {
        "preload enabled": "false",
        "cache expiry delay": "1",
    },
    "Navigator": {
        # v8 hard-safe runtime profile. The v8 executable ALSO defaults to a
        # Navigator stub, so this remains safe even if another config source
        # accidentally contains different Navigator values.
        "enable": "false",
        "wait until min distance to player": "0",
        "enable nav mesh disk cache": "true",
        "write to navmeshdb": "false",
        "async nav mesh updater threads": "1",
        "max nav mesh tiles cache size": "33554432",
        "wait for all jobs on exit": "false",
    },
}


def set_key(source, section, key, value):
    section_pat = re.compile(rf"(?mi)^\[{re.escape(section)}\][ \t]*$")
    match = section_pat.search(source)

    if not match:
        if source and not source.endswith("\n"):
            source += "\n"
        source += f"\n[{section}]\n{key} = {value}\n"
        return source

    next_section = re.search(r"(?m)^\[[^\]]+\][ \t]*$", source[match.end():])
    end = match.end() + next_section.start() if next_section else len(source)
    body = source[match.end():end]

    key_pat = re.compile(
        rf"(?mi)^(?P<prefix>[ \t]*){re.escape(key)}[ \t]*=.*$"
    )
    matches = list(key_pat.finditer(body))

    if matches:
        first = matches[0]
        replacement = first.group("prefix") + f"{key} = {value}"
        body = body[:first.start()] + replacement + body[first.end():]

        body_lines = body.splitlines()
        seen = False
        cleaned = []
        for line in body_lines:
            if re.match(rf"(?i)^[ \t]*{re.escape(key)}[ \t]*=", line):
                if seen:
                    continue
                seen = True
            cleaned.append(line)
        body = "\n".join(cleaned)
        if source[match.end():end].endswith("\n") and not body.endswith("\n"):
            body += "\n"
    else:
        if body and not body.startswith("\n"):
            body = "\n" + body
        body = "\n" + f"{key} = {value}" + body

    return source[:match.end()] + body + source[end:]


for section, values in changes.items():
    for key, value in values.items():
        text = set_key(text, section, key, value)

# Do not use Path.write_text(..., newline=...): the Python version used by the
# user's build/device workflow does not support that keyword on Path.write_text.
with path.open("w", encoding="utf-8", newline="\n") as handle:
    handle.write(text)
PY_SETTINGS

mkdir -p "$(dirname "$COMPAT")"
cp -f "$CFG" "$COMPAT"

echo
echo "===== V8 SAFENAV SETTINGS ====="
awk '
/^\[/ { section=$0 }
$0 ~ /^(near clip|object paging active grid|water culling|preload enabled|cache expiry delay|enable|wait until min distance to player|enable nav mesh disk cache|write to navmeshdb|async nav mesh updater threads|max nav mesh tiles cache size|wait for all jobs on exit)[[:space:]]*=/ {
    if (section == "[Camera]" || section == "[Terrain]" || section == "[Cells]" || section == "[Navigator]")
        print section " " $0
}
' "$SETTINGS"

echo
if [ -f "$NAVDB" ]; then
    echo "Existing pre-generated navmesh cache PRESERVED:"
    ls -lh "$NAVDB"
else
    echo "No navmesh.db is currently present; v8 does not create or require one."
fi

echo
echo "SafeNav v8 runtime profile applied."
echo "Navigator is disabled in settings."
echo "The v8 binary independently defaults to the Navigator stub."
echo "Runtime navmesh DB writes are disabled."
echo "Do NOT set OPENMW_TSP_ENABLE_NAVIGATOR=1 during this stability test."
EOF_RUNTIME
chmod +x "$RUNTIME_HELPER"

cat > "$README_V8" <<'EOF_README'
OpenMW 0.51 TrimUI Smart Pro S - SafeNav hard-stability v8
===========================================================

WHAT V8 CHANGES
---------------
The v8 executable defaults to a Navigator stub instead of starting the live
Recast/Detour Navigator. It also short-circuits Detour path queries to
NavMeshNotFound unless OPENMW_TSP_ENABLE_NAVIGATOR=1 is explicitly exported.

Normal v8 gameplay therefore uses OpenMW's existing pathgrid/straight-path
fallback and does not run the live Recast navmesh updater.

The existing pre-generated navmesh.db is preserved. It is simply dormant in
the default SafeNav test so we can isolate the navigation subsystem as a crash
source without throwing away the expensive cache generation work.

RUNTIME PROFILE
---------------
Run once after installing v8:

  /mnt/SDCARD/data/ports/openmw51/tools/apply-runtime-profile-v8.sh

It preserves the existing v7 memory/render settings and sets:

  [Navigator]
  enable = false
  wait until min distance to player = 0
  enable nav mesh disk cache = true
  write to navmeshdb = false
  async nav mesh updater threads = 1
  max nav mesh tiles cache size = 33554432
  wait for all jobs on exit = false

EXPECTED LOG
------------
When an existing settings source still says Navigator is enabled, the binary
may print once during startup:

  TSP SafeNav v8: Navigator forced to stub; set OPENMW_TSP_ENABLE_NAVIGATOR=1 to opt back in.

During the SafeNav test there should be NO new messages such as:

  Added ... collision shape to navmeshdb with id ...

and no runtime Recast tile-generation activity should be required.

LATER CACHED-NAVIGATOR RETEST
-----------------------------
Only after SafeNav has been stability-tested, the real Navigator can be
explicitly re-enabled by BOTH:

  export OPENMW_TSP_ENABLE_NAVIGATOR=1

and:

  [Navigator]
  enable = true
  write to navmeshdb = false

Keeping write to navmeshdb=false makes that later test read-only with respect
to the persistent database. Missing/changed tiles may still be generated in
RAM by the real Navigator, which is why that mode is NOT the v8 stability
default.

DEBUGGER
--------
The v8 OpenMW executable is intentionally left unstripped. The build script
also makes a best-effort attempt to place libncursesw.so.5 and libtinfo.so.5 in
package/lib for the TSP crash handler's gdb dependency.
EOF_README

# ---------------------------------------------------------------------
# Best-effort debugger compatibility libraries.
# ---------------------------------------------------------------------
echo
echo "Checking for gdb ncurses ABI-5 compatibility libraries..."

find_compat_lib() {
    soname="$1"
    find /lib /usr/lib /usr/local/lib \
        -name "${soname}*" \
        -print 2>/dev/null | head -1 || true
}

NCURSESW5="$(find_compat_lib libncursesw.so.5)"
TINFO5="$(find_compat_lib libtinfo.so.5)"

if [ -z "$NCURSESW5" ] && command -v apt-cache >/dev/null 2>&1; then
    if apt-cache show libncursesw5 >/dev/null 2>&1; then
        echo "libncursesw.so.5 not currently installed; attempting focal ABI-5 package install..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y libncursesw5 libtinfo5 || true
        NCURSESW5="$(find_compat_lib libncursesw.so.5)"
        TINFO5="$(find_compat_lib libtinfo.so.5)"
    fi
fi

if [ -n "$NCURSESW5" ]; then
    cp -Lf "$NCURSESW5" "$PACKAGE_LIB_DIR/libncursesw.so.5"
    echo "  packaged: $PACKAGE_LIB_DIR/libncursesw.so.5"
else
    echo "  WARNING: libncursesw.so.5 not found; device gdb may still fail to start."
fi

if [ -n "$TINFO5" ]; then
    cp -Lf "$TINFO5" "$PACKAGE_LIB_DIR/libtinfo.so.5"
    echo "  packaged: $PACKAGE_LIB_DIR/libtinfo.so.5"
else
    echo "  NOTE: libtinfo.so.5 not found in build container."
fi

# Build a small overlay bundle that can be extracted directly into openmw51.
echo
echo "Creating v8 deployment overlay bundle..."
rm -f "$OUTPUT_BUNDLE"

BUNDLE_ITEMS=(
    "bin/openmw-0.51"
    "tools/apply-runtime-profile-v8.sh"
    "tools/README_V8.txt"
)

if [ -f "$PACKAGE_LIB_DIR/libncursesw.so.5" ]; then
    BUNDLE_ITEMS+=("lib/libncursesw.so.5")
fi
if [ -f "$PACKAGE_LIB_DIR/libtinfo.so.5" ]; then
    BUNDLE_ITEMS+=("lib/libtinfo.so.5")
fi

tar -C "$PACKAGE_DIR" -czf "$OUTPUT_BUNDLE" "${BUNDLE_ITEMS[@]}"

# Verify SafeNav markers made it into the unstripped executable where strings
# are retained. This is diagnostic only; source verification above is primary.
echo
echo "Binary/package verification:"
file "$OUTPUT_BINARY"
file "$PACKAGE_BINARY"
"$OUTPUT_BINARY" --version || true

if command -v strings >/dev/null 2>&1; then
    if strings "$OUTPUT_BINARY" | grep -Fq 'TSP SafeNav v8: Navigator forced to stub'; then
        echo "  SafeNav log marker found in binary."
    else
        echo "  WARNING: SafeNav log marker not found by strings."
    fi
fi

echo
echo "Packaged v8 files:"
ls -lh "$OUTPUT_BINARY" "$OUTPUT_BUNDLE" "$RUNTIME_HELPER" "$README_V8"
[ ! -f "$PACKAGE_LIB_DIR/libncursesw.so.5" ] || ls -lh "$PACKAGE_LIB_DIR/libncursesw.so.5"
[ ! -f "$PACKAGE_LIB_DIR/libtinfo.so.5" ] || ls -lh "$PACKAGE_LIB_DIR/libtinfo.so.5"

trap - ERR

echo
echo "============================================================"
echo "SUCCESS: OpenMW 0.51 TSP SafeNav v8 completed"
echo "============================================================"
echo "Standalone unstripped OpenMW:"
echo "  $OUTPUT_BINARY"
echo
echo "Device overlay bundle:"
echo "  $OUTPUT_BUNDLE"
echo
echo "Packaged OpenMW:"
echo "  $PACKAGE_BINARY"
echo
echo "Device runtime helper:"
echo "  $RUNTIME_HELPER"
echo
echo "Source backup:"
echo "  $BACKUP_DIR"
echo
echo "v8 hard safety behavior:"
echo "  - Navigator defaults to stub"
echo "  - Recast updater workers do not start"
echo "  - Detour path queries return NavMeshNotFound"
echo "  - pathgrid/straight fallback remains active"
echo "  - navmesh.db is preserved"
echo "  - runtime DB writes are disabled by v8 profile"
echo "  - OpenMW binary remains unstripped for crash diagnostics"
echo
echo "Intentional opt-in escape hatch:"
echo "  OPENMW_TSP_ENABLE_NAVIGATOR=1"
echo "============================================================"
