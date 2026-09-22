#!/bin/bash
set -Eeuo pipefail

SOURCE_DIR="${1:-/root/openmw-0.51-tsp-src}"
BUILD_DIR="${2:-/root/openmw-0.51-tsp-build}"
PACKAGE_DIR="${3:-/root/openmw-0.51-tsp-package}"
OUTPUT_BINARY="${4:-/root/openmw-0.51-tsp-freshload-stability}"

JOBS="${OPENMW_JOBS:-1}"
PATCH_ONLY="${OPENMW_PATCH_ONLY:-0}"

STATE_CPP="$SOURCE_DIR/apps/openmw/mwstate/statemanagerimp.cpp"
SCENE_CPP="$SOURCE_DIR/apps/openmw/mwworld/scene.cpp"
OBJECTCACHE_HPP="$SOURCE_DIR/components/resource/objectcache.hpp"
RESOURCEMANAGER_HPP="$SOURCE_DIR/components/resource/resourcemanager.hpp"
RESOURCESYSTEM_HPP="$SOURCE_DIR/components/resource/resourcesystem.hpp"
RESOURCESYSTEM_CPP="$SOURCE_DIR/components/resource/resourcesystem.cpp"
SCENEMANAGER_HPP="$SOURCE_DIR/components/resource/scenemanager.hpp"
SCENEMANAGER_CPP="$SOURCE_DIR/components/resource/scenemanager.cpp"
CMAKE_FILE="$SOURCE_DIR/CMakeLists.txt"

BUILT_BINARY="$BUILD_DIR/openmw"
PACKAGE_BINARY="$PACKAGE_DIR/bin/openmw-0.51"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$SOURCE_DIR/.tsp-051-source-backups/freshload-stability-$STAMP"

restore_on_error() {
    rc=$?
    if [ "$rc" -ne 0 ] && [ -d "$BACKUP_DIR" ]; then
        echo
        echo "ERROR: fresh-load stability patch/build failed."
        echo "Restoring source files modified by this attempt..."
        for rel in \
            apps/openmw/mwstate/statemanagerimp.cpp \
            apps/openmw/mwworld/scene.cpp \
            components/resource/objectcache.hpp \
            components/resource/resourcemanager.hpp \
            components/resource/resourcesystem.hpp \
            components/resource/resourcesystem.cpp \
            components/resource/scenemanager.hpp \
            components/resource/scenemanager.cpp
        do
            if [ -f "$BACKUP_DIR/$rel" ]; then
                cp -f "$BACKUP_DIR/$rel" "$SOURCE_DIR/$rel"
            fi
        done
        echo "Source restoration complete."
        echo "Failed-attempt backup retained at:"
        echo "  $BACKUP_DIR"
    fi
    exit "$rc"
}
trap restore_on_error ERR

echo "============================================================"
echo "OpenMW 0.51 TSP FRESH-LOAD STABILITY REVISION"
echo "============================================================"
echo "Source:        $SOURCE_DIR"
echo "Build:         $BUILD_DIR"
echo "Package:       $PACKAGE_DIR"
echo "Output binary: $OUTPUT_BINARY"
echo "Patch only:    $PATCH_ONLY"
echo "Jobs:          $JOBS"
echo "Backup:        $BACKUP_DIR"
echo "============================================================"

for required in \
    "$STATE_CPP" \
    "$SCENE_CPP" \
    "$OBJECTCACHE_HPP" \
    "$RESOURCEMANAGER_HPP" \
    "$RESOURCESYSTEM_HPP" \
    "$RESOURCESYSTEM_CPP" \
    "$SCENEMANAGER_HPP" \
    "$SCENEMANAGER_CPP" \
    "$CMAKE_FILE"
do
    if [ ! -f "$required" ]; then
        echo "ERROR: missing required source file:"
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

if [ "$PATCH_ONLY" != "1" ]; then
    if [ ! -f "$BUILD_DIR/build.ninja" ] || [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
        echo "ERROR: configured Ninja build tree is missing."
        echo "This revision intentionally does NOT regenerate CMake."
        exit 1
    fi
fi

mkdir -p \
    "$BACKUP_DIR/apps/openmw/mwstate" \
    "$BACKUP_DIR/apps/openmw/mwworld" \
    "$BACKUP_DIR/components/resource" \
    "$PACKAGE_DIR/bin"

cp -f "$STATE_CPP" "$BACKUP_DIR/apps/openmw/mwstate/statemanagerimp.cpp"
cp -f "$SCENE_CPP" "$BACKUP_DIR/apps/openmw/mwworld/scene.cpp"
cp -f "$OBJECTCACHE_HPP" "$BACKUP_DIR/components/resource/objectcache.hpp"
cp -f "$RESOURCEMANAGER_HPP" "$BACKUP_DIR/components/resource/resourcemanager.hpp"
cp -f "$RESOURCESYSTEM_HPP" "$BACKUP_DIR/components/resource/resourcesystem.hpp"
cp -f "$RESOURCESYSTEM_CPP" "$BACKUP_DIR/components/resource/resourcesystem.cpp"
cp -f "$SCENEMANAGER_HPP" "$BACKUP_DIR/components/resource/scenemanager.hpp"
cp -f "$SCENEMANAGER_CPP" "$BACKUP_DIR/components/resource/scenemanager.cpp"

echo
echo "Applying fresh-load stability source revision..."

python3 - \
    "$STATE_CPP" \
    "$SCENE_CPP" \
    "$OBJECTCACHE_HPP" \
    "$RESOURCEMANAGER_HPP" \
    "$RESOURCESYSTEM_HPP" \
    "$RESOURCESYSTEM_CPP" \
    "$SCENEMANAGER_HPP" \
    "$SCENEMANAGER_CPP" <<'PY_PATCH'
from pathlib import Path
import os
import re
import sys

(
    state_path,
    scene_path,
    objectcache_path,
    resourcemanager_path,
    resourcesystem_h_path,
    resourcesystem_cpp_path,
    scenemanager_h_path,
    scenemanager_cpp_path,
) = map(Path, sys.argv[1:])

state = state_path.read_text(encoding="utf-8")
scene = scene_path.read_text(encoding="utf-8")
objectcache = objectcache_path.read_text(encoding="utf-8")
resourcemanager = resourcemanager_path.read_text(encoding="utf-8")
resourcesystem_h = resourcesystem_h_path.read_text(encoding="utf-8")
resourcesystem_cpp = resourcesystem_cpp_path.read_text(encoding="utf-8")
scenemanager_h = scenemanager_h_path.read_text(encoding="utf-8")
scenemanager_cpp = scenemanager_cpp_path.read_text(encoding="utf-8")

PURGE_CACHE_MARKER = "TSP_UNREFERENCED_CACHE_PURGE_051"
PURGE_SCENE_MARKER = "TSP_TRANSITION_MEMORY_PURGE_051"
FRESH_MARKER = "TSP_FRESH_PROCESS_LOAD_051_V12"


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
                return start, end

        index += 1

    raise RuntimeError(f"{label}: closing brace not found")


def remove_function(text, signature_pattern, label, marker=None):
    start, end = find_function(text, signature_pattern, label)
    if marker is not None:
        marker_pos = text.rfind(marker, 0, start)
        if marker_pos >= 0:
            marker_line = text.rfind("\n", 0, marker_pos) + 1
            between = text[marker_pos + len(marker):start]
            if between.strip() == "":
                start = marker_line
    return text[:start] + text[end:]


def transactional_write(items):
    temps = []
    try:
        for path, content in items:
            tmp = Path(str(path) + ".tsp-freshload-stability.tmp")
            with tmp.open("w", encoding="utf-8", newline="\n") as handle:
                handle.write(content)
            temps.append((path, tmp))

        for path, tmp in temps:
            os.replace(str(tmp), str(path))
    finally:
        for _, tmp in temps:
            try:
                tmp.unlink()
            except FileNotFoundError:
                pass


# =====================================================================
# 1. REMOVE THE EXPERIMENTAL TRANSITION-MEMORY PURGE
# =====================================================================

# GenericObjectCache::clearUnreferenced() was inserted immediately before
# the existing clear() documentation comment.
if PURGE_CACHE_MARKER in objectcache:
    start = objectcache.find("        // TSP_UNREFERENCED_CACHE_PURGE_051\n")
    anchor = "        /** Remove all objects in the cache regardless of having external references or expiry times.*/\n"
    end = objectcache.find(anchor, start)
    if start < 0 or end < 0:
        raise RuntimeError("objectcache.hpp: could not isolate transition-purge block")
    objectcache = objectcache[:start] + objectcache[end:]

# Base/Generic resource-manager virtual hooks.
resourcemanager = resourcemanager.replace(
    "        // TSP_UNREFERENCED_CACHE_PURGE_051\n"
    "        virtual std::size_t clearUnreferencedCache() { return 0; }\n",
    "",
)
resourcemanager = resourcemanager.replace(
    "        std::size_t clearUnreferencedCache() override { return mCache->clearUnreferenced(); }\n",
    "",
)

# ResourceSystem declaration.
resourcesystem_h = resourcesystem_h.replace(
    "        // TSP_UNREFERENCED_CACHE_PURGE_051\n"
    "        std::size_t clearUnreferencedCache();\n",
    "",
)

# SceneManager declaration.
scenemanager_h = scenemanager_h.replace(
    "        // TSP_UNREFERENCED_CACHE_PURGE_051\n"
    "        std::size_t clearUnreferencedCache() override;\n",
    "",
)

# ResourceSystem implementation.
if "ResourceSystem::clearUnreferencedCache" in resourcesystem_cpp:
    resourcesystem_cpp = remove_function(
        resourcesystem_cpp,
        r"^[ \t]*std::size_t[ \t]+ResourceSystem::clearUnreferencedCache[ \t]*\([^)]*\)",
        "ResourceSystem::clearUnreferencedCache",
        PURGE_CACHE_MARKER,
    )

# SceneManager implementation.
if "SceneManager::clearUnreferencedCache" in scenemanager_cpp:
    scenemanager_cpp = remove_function(
        scenemanager_cpp,
        r"^[ \t]*std::size_t[ \t]+SceneManager::clearUnreferencedCache[ \t]*\([^)]*\)",
        "SceneManager::clearUnreferencedCache",
        PURGE_CACHE_MARKER,
    )

# Scene transition helper.
if "void tspPurgeTransitionMemory" in scene:
    scene = remove_function(
        scene,
        r"^[ \t]*void[ \t]+tspPurgeTransitionMemory[ \t]*\(",
        "tspPurgeTransitionMemory",
        PURGE_SCENE_MARKER,
    )

# Scene::clear additions.
scene = scene.replace(
    "\n        const bool tspHadActiveCells = !mActiveCells.empty();",
    "",
)
scene = scene.replace(
    "\n        if (tspHadActiveCells)\n"
    "            tspPurgeTransitionMemory(mRendering, \"scene-clear\", true, mActiveCells.size());\n",
    "",
)

# changeToInteriorCell additions.
scene = scene.replace(
    "\n        mPreloader->clear();\n"
    "        tspPurgeTransitionMemory(mRendering, \"to-interior\", true, mActiveCells.size());\n",
    "",
)

# changeCellGrid additions.
scene = scene.replace(
    "        const std::size_t tspActiveBeforeUnload = mActiveCells.size();\n",
    "",
)

purge_grid_block = r'''        const bool tspUnloadedCells
            = mActiveCells.size() < tspActiveBeforeUnload;

        if (tspUnloadedCells)
        {
            if (mActiveCells.empty())
            {
                mPreloader->clear();
                tspPurgeTransitionMemory(
                    mRendering, "to-exterior", true, mActiveCells.size());
            }
            else
            {
                tspPurgeTransitionMemory(
                    mRendering, "exterior-grid-shift", false, mActiveCells.size());
            }
        }

'''
scene = scene.replace(purge_grid_block, "")

# The malloc.h include in scene.cpp belonged only to this experiment. Keep it
# if another surviving scene patch actually uses malloc_trim.
if "malloc_trim" not in scene:
    scene = scene.replace(
        "\n#if defined(__linux__) && defined(__GLIBC__)\n"
        "#include <malloc.h>\n"
        "#endif\n",
        "",
    )

# Strictly reject a partially removed transition purge. It is better to stop
# and restore the backup than to build a mixed lifetime policy.
for path, content in (
    (scene_path, scene),
    (objectcache_path, objectcache),
    (resourcemanager_path, resourcemanager),
    (resourcesystem_h_path, resourcesystem_h),
    (resourcesystem_cpp_path, resourcesystem_cpp),
    (scenemanager_h_path, scenemanager_h),
    (scenemanager_cpp_path, scenemanager_cpp),
):
    for forbidden in (
        PURGE_CACHE_MARKER,
        PURGE_SCENE_MARKER,
        "tspPurgeTransitionMemory",
        "clearUnreferencedCache",
        "clearUnreferenced()",
        "TSP MEMPURGE",
        "tspActiveBeforeUnload",
        "tspHadActiveCells",
    ):
        if forbidden in content:
            raise RuntimeError(f"{path}: transition-purge remnant still present: {forbidden}")


# =====================================================================
# 2. ADD FRESH-PROCESS SAVE LOADING
# =====================================================================

# Required Linux/POSIX + standard includes. These are intentionally explicit
# rather than relying on transitive includes from OpenMW headers.
include_anchor = '#include <filesystem>\n'
if include_anchor not in state:
    raise RuntimeError("statemanagerimp.cpp: #include <filesystem> anchor not found")

extra_includes = """#include <cerrno>\n#include <cstdlib>\n#include <cstring>\n#include <fstream>\n#include <iostream>\n#include <string>\n#include <vector>\n\n#if defined(__linux__)\n#include <dirent.h>\n#include <fcntl.h>\n#include <unistd.h>\n#endif\n"""

if FRESH_MARKER not in state:
    # Add only missing include lines while retaining a compact include block.
    missing_lines = []
    for line in extra_includes.splitlines(keepends=True):
        if line.strip() and line.startswith("#include") and line.strip() in state:
            continue
        missing_lines.append(line)

    # For the #if block, insert as a whole only when unistd is not already present.
    standard_lines = []
    for inc in (
        "#include <cerrno>\n",
        "#include <cstdlib>\n",
        "#include <cstring>\n",
        "#include <fstream>\n",
        "#include <iostream>\n",
        "#include <string>\n",
        "#include <vector>\n",
    ):
        if inc.strip() not in state:
            standard_lines.append(inc)

    linux_block = ""
    if "#include <unistd.h>" not in state:
        linux_block = (
            "\n#if defined(__linux__)\n"
            "#include <dirent.h>\n"
            "#include <fcntl.h>\n"
            "#include <unistd.h>\n"
            "#endif\n"
        )
    else:
        # If unistd already exists, still make sure dirent/fcntl do too.
        for inc in ("#include <dirent.h>\n", "#include <fcntl.h>\n"):
            if inc.strip() not in state:
                standard_lines.append(inc)

    insertion = "".join(standard_lines) + linux_block
    if insertion:
        state = state.replace(include_anchor, include_anchor + insertion, 1)

    # Helper lives at file scope immediately before the first StateManager method.
    helper_anchor = "void MWState::StateManager::cleanup(bool force)\n"
    if helper_anchor not in state:
        raise RuntimeError("statemanagerimp.cpp: cleanup() anchor not found")

    helper = r'''// TSP_FRESH_PROCESS_LOAD_051_V12
// On this low-memory GL4ES handheld, loading a new save into an already-live
// OpenMW process has repeatedly produced low-address SIGSEGVs. For an in-game
// load, quickload, or death reload, replace the process image before reading
// the next save. The startup load sees State_NoGame and proceeds normally.
namespace
{
    bool tspFreshProcessLoadsEnabled()
    {
        const char* value = std::getenv("OPENMW_TSP_FRESH_LOADS");
        return value == nullptr || std::strcmp(value, "0") != 0;
    }

#if defined(__linux__)
    void tspMarkNonStdioDescriptorsCloseOnExec()
    {
        DIR* directory = ::opendir("/proc/self/fd");
        if (directory == nullptr)
            return;

        const int directoryFd = ::dirfd(directory);
        while (dirent* entry = ::readdir(directory))
        {
            char* end = nullptr;
            errno = 0;
            const long parsed = std::strtol(entry->d_name, &end, 10);
            if (errno != 0 || end == entry->d_name || *end != '\0')
                continue;
            if (parsed < 3 || parsed == directoryFd)
                continue;

            const int fd = static_cast<int>(parsed);
            const int flags = ::fcntl(fd, F_GETFD);
            if (flags >= 0)
                ::fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
        }

        ::closedir(directory);
    }

    void tspRestartForSaveLoad(const std::filesystem::path& filepath)
    {
        std::ifstream commandLine("/proc/self/cmdline", std::ios::binary);
        if (!commandLine)
            throw std::runtime_error("TSP FRESHLOAD: unable to read /proc/self/cmdline");

        std::vector<std::string> oldArgs;
        std::string arg;
        while (std::getline(commandLine, arg, '\0'))
        {
            if (!arg.empty())
                oldArgs.push_back(arg);
        }

        if (oldArgs.empty())
            throw std::runtime_error("TSP FRESHLOAD: current command line is empty");

        std::vector<std::string> newArgs;
        newArgs.reserve(oldArgs.size() + 2);
        newArgs.push_back(oldArgs.front());

        for (std::size_t i = 1; i < oldArgs.size(); ++i)
        {
            const std::string& current = oldArgs[i];

            if (current == "--load-savegame")
            {
                if (i + 1 < oldArgs.size())
                    ++i;
                continue;
            }
            if (current.rfind("--load-savegame=", 0) == 0)
                continue;

            if (current == "--skip-menu")
            {
                if (i + 1 < oldArgs.size()
                    && (oldArgs[i + 1] == "0" || oldArgs[i + 1] == "1"
                        || oldArgs[i + 1] == "true" || oldArgs[i + 1] == "false"))
                    ++i;
                continue;
            }
            if (current.rfind("--skip-menu=", 0) == 0)
                continue;

            // A stale startup-new-game flag must not survive into a save load.
            if (current == "--new-game")
            {
                if (i + 1 < oldArgs.size()
                    && (oldArgs[i + 1] == "0" || oldArgs[i + 1] == "1"
                        || oldArgs[i + 1] == "true" || oldArgs[i + 1] == "false"))
                    ++i;
                continue;
            }
            if (current.rfind("--new-game=", 0) == 0)
                continue;

            newArgs.push_back(current);
        }

        const std::filesystem::path absoluteSave
            = std::filesystem::absolute(filepath).lexically_normal();
        newArgs.emplace_back("--load-savegame=" + absoluteSave.string());
        newArgs.emplace_back("--skip-menu=1");

        Log(Debug::Info)
            << "TSP_FRESH_PROCESS_LOAD_051_V12 "
            << "TSP FRESHLOAD restarting process for save: "
            << absoluteSave;

        // Keep the launcher's stdout/stderr log, but prevent old EGL, DRM,
        // ALSA/OpenAL and other library descriptors from crossing exec().
        tspMarkNonStdioDescriptorsCloseOnExec();

        std::cout.flush();
        std::cerr.flush();

        std::vector<char*> argv;
        argv.reserve(newArgs.size() + 1);
        for (std::string& value : newArgs)
            argv.push_back(value.data());
        argv.push_back(nullptr);

        ::execv("/proc/self/exe", argv.data());

        const int error = errno;
        throw std::runtime_error(
            "TSP FRESHLOAD: execv(/proc/self/exe) failed: "
            + std::string(std::strerror(error)));
    }
#endif
}

'''
    state = state.replace(helper_anchor, helper + helper_anchor, 1)

    # Hook the single private loadGame path that all UI load, quickload and
    # death-reload routes eventually use. Keep the hook inside the existing
    # try block so an exec preparation failure is reported as a normal load
    # error rather than terminating the engine.
    load_sig = r"^[ \t]*void[ \t]+MWState::StateManager::loadGame[ \t]*\(const Character\* character,[ \t]*const std::filesystem::path& filepath\)"
    load_start, load_end = find_function(state, load_sig, "StateManager::loadGame(Character*, path)")
    load_func = state[load_start:load_end]

    try_anchor = "    try\n    {\n"
    if try_anchor not in load_func:
        raise RuntimeError("statemanagerimp.cpp: loadGame try-block anchor not found")

    hook = r'''#if defined(__linux__)
        if (mState != State_NoGame && tspFreshProcessLoadsEnabled())
            tspRestartForSaveLoad(filepath);
#endif

'''
    load_func = load_func.replace(try_anchor, try_anchor + hook, 1)
    state = state[:load_start] + load_func + state[load_end:]

# Idempotent verification of the fresh-load patch.
for required in (
    FRESH_MARKER,
    "TSP FRESHLOAD restarting process for save:",
    '::execv("/proc/self/exe", argv.data());',
    "tspMarkNonStdioDescriptorsCloseOnExec();",
    "mState != State_NoGame && tspFreshProcessLoadsEnabled()",
    'newArgs.emplace_back("--skip-menu=1");',
):
    if required not in state:
        raise RuntimeError(f"statemanagerimp.cpp: fresh-load verification missing: {required}")


# =====================================================================
# 3. LIGHTEN THE EXISTING MEMORY DIAGNOSTICS
# =====================================================================

# The tracer remains useful if a pure exploration crash survives, but reading
# /proc and writing eleven log lines every two seconds is unnecessary now.
if "TSP_MEMORY_PROCESS_TRACE_051_V10" in resourcesystem_cpp:
    resourcesystem_cpp, count = re.subn(
        r"constexpr std::int64_t TspMemTraceIntervalNs = [0-9]+LL;",
        "constexpr std::int64_t TspMemTraceIntervalNs = 10000000000LL;",
        resourcesystem_cpp,
        count=1,
    )
    if count != 1:
        raise RuntimeError("resourcesystem.cpp: could not set 10-second MEMPROC interval")

if "TSP_MEMORY_SCENE_TRACE_051_V10" in scenemanager_cpp:
    scenemanager_cpp, count = re.subn(
        r"constexpr std::int64_t TspSceneTraceIntervalNs = [0-9]+LL;",
        "constexpr std::int64_t TspSceneTraceIntervalNs = 10000000000LL;",
        scenemanager_cpp,
        count=1,
    )
    if count != 1:
        raise RuntimeError("scenemanager.cpp: could not set 10-second MEMSCENE interval")


# =====================================================================
# 4. FINAL SOURCE VERIFICATION + ATOMIC WRITE
# =====================================================================

# SafeNav is expected to remain present in this source lineage. The exact
# marker location can differ across our revisions, so this source-stage check
# is informational; final binary verification runs after the rebuild.
safenav_present = False
for candidate in (
    state_path.parents[1] / "mwworld" / "worldimp.cpp",
    state_path.parents[3] / "components" / "detournavigator" / "navigator.cpp",
):
    try:
        text = candidate.read_text(encoding="utf-8")
    except (FileNotFoundError, OSError):
        continue
    if "TSP SafeNav" in text or "OPENMW_TSP_ENABLE_NAVIGATOR" in text:
        safenav_present = True
        break

if not safenav_present:
    # Do not fail solely because the marker location differs; the final binary
    # verification below is authoritative. Emit a source-stage warning instead.
    print("WARNING: SafeNav source marker not found at expected candidate paths.")

transactional_write(
    [
        (state_path, state),
        (scene_path, scene),
        (objectcache_path, objectcache),
        (resourcemanager_path, resourcemanager),
        (resourcesystem_h_path, resourcesystem_h),
        (resourcesystem_cpp_path, resourcesystem_cpp),
        (scenemanager_h_path, scenemanager_h),
        (scenemanager_cpp_path, scenemanager_cpp),
    ]
)

print("Fresh-load stability source revision applied and verified.")
print("  transition-memory purge: REMOVED")
print("  normal cache lifetime:   RESTORED")
print("  fresh in-game loads:     ENABLED by default")
print("  disable escape hatch:    OPENMW_TSP_FRESH_LOADS=0")
print("  memory trace interval:   10 seconds when v10 tracer is present")
PY_PATCH

echo
echo "===== SOURCE VERIFICATION ====="
echo "Fresh-load marker:"
grep -n -m 4 \
    -e 'TSP_FRESH_PROCESS_LOAD_051_V12' \
    -e 'TSP FRESHLOAD restarting process for save:' \
    -e 'execv("/proc/self/exe"' \
    "$STATE_CPP"

echo
echo "Transition-purge markers should be absent:"
if grep -RniE \
    'TSP_TRANSITION_MEMORY_PURGE_051|TSP_UNREFERENCED_CACHE_PURGE_051|TSP MEMPURGE|clearUnreferencedCache|tspPurgeTransitionMemory' \
    "$SCENE_CPP" \
    "$OBJECTCACHE_HPP" \
    "$RESOURCEMANAGER_HPP" \
    "$RESOURCESYSTEM_HPP" \
    "$RESOURCESYSTEM_CPP" \
    "$SCENEMANAGER_HPP" \
    "$SCENEMANAGER_CPP"
then
    echo "ERROR: transition-purge source remnants remain."
    exit 1
else
    echo "  PASS: no transition-purge remnants found."
fi

echo
echo "Existing TSP features (informational):"
grep -Rni -m 8 \
    -e 'TSP SafeNav' \
    -e 'OPENMW_TSP_ENABLE_NAVIGATOR' \
    -e 'TSP MEMPROC' \
    -e 'TSP MEMSCENE' \
    "$SOURCE_DIR/apps/openmw" "$SOURCE_DIR/components" 2>/dev/null || true

if [ "$PATCH_ONLY" = "1" ]; then
    trap - ERR
    echo
    echo "PATCH_ONLY=1: source revision and verification completed."
    exit 0
fi

echo
echo "Incrementally rebuilding OpenMW 0.51 (UNSTRIPPED)..."
cmake --build \
    "$BUILD_DIR" \
    --target openmw \
    --parallel "$JOBS"

if [ ! -x "$BUILT_BINARY" ]; then
    echo "ERROR: rebuilt OpenMW executable is missing:"
    echo "  $BUILT_BINARY"
    exit 1
fi

if [ -e "$OUTPUT_BINARY" ]; then
    cp -f "$OUTPUT_BINARY" "$OUTPUT_BINARY.before-$STAMP"
fi

if [ -e "$PACKAGE_BINARY" ]; then
    cp -f "$PACKAGE_BINARY" "$PACKAGE_BINARY.before-freshload-stability-$STAMP"
fi

cp -f "$BUILT_BINARY" "$OUTPUT_BINARY"
cp -f "$BUILT_BINARY" "$PACKAGE_BINARY"
chmod +x "$OUTPUT_BINARY" "$PACKAGE_BINARY"

echo
echo "===== BINARY VERIFICATION ====="
file "$PACKAGE_BINARY"
sha256sum "$PACKAGE_BINARY"
"$PACKAGE_BINARY" --version || true

echo
echo "Required marker strings:"
strings "$PACKAGE_BINARY" | grep -F 'TSP_FRESH_PROCESS_LOAD_051_V12' >/dev/null
strings "$PACKAGE_BINARY" | grep -F 'TSP FRESHLOAD restarting process for save:' >/dev/null
strings "$PACKAGE_BINARY" | grep -F 'OPENMW_TSP_FRESH_LOADS' >/dev/null
printf '  PASS: fresh-load stability markers present.\n'

echo
echo "Transition-purge marker strings should be absent:"
if strings "$PACKAGE_BINARY" | grep -E \
    'TSP MEMPURGE|TSP_TRANSITION_MEMORY_PURGE_051|TSP_UNREFERENCED_CACHE_PURGE_051' >/dev/null
then
    echo "ERROR: rebuilt binary still contains transition-purge markers."
    exit 1
else
    echo "  PASS: transition-purge markers absent."
fi

echo
echo "SafeNav marker (expected to remain):"
if strings "$PACKAGE_BINARY" | grep -F -m 3 'TSP SafeNav'; then
    :
else
    echo "WARNING: TSP SafeNav marker string was not found in the final binary."
fi

trap - ERR

echo
echo "============================================================"
echo "SUCCESS: OpenMW 0.51 fresh-load stability revision built"
echo "============================================================"
echo "Packaged binary:"
echo "  $PACKAGE_BINARY"
echo
echo "Standalone container copy:"
echo "  $OUTPUT_BINARY"
echo
echo "Source backup:"
echo "  $BACKUP_DIR"
echo
echo "Runtime policy:"
echo "  First title-screen load: normal OpenMW load"
echo "  In-game Load:           fresh exec -> --load-savegame --skip-menu"
echo "  Quickload:              fresh exec -> --load-savegame --skip-menu"
echo "  Death reload:           fresh exec -> --load-savegame --skip-menu"
echo "  Transition caches:      normal OpenMW lifetime (purge experiment removed)"
echo "============================================================"
