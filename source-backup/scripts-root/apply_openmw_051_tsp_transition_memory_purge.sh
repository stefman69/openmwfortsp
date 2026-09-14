#!/bin/bash
set -Eeuo pipefail

# OpenMW 0.51 / TrimUI Smart Pro S
# Aggressive transition memory purge
#
# Revision-number agnostic: it does not care whether the surrounding TSP
# revision is v10, v11, v12, etc.
#
# HARD purge:
#   - save/reload Scene::clear
#   - transitions where all old active cells are detached
#
# SOFT purge:
#   - normal exterior cell-grid movement
#   - drops only cache entries with no external references
#
# Existing SafeNav, memtrace, cursor, water, renderer and LOD patches are not
# intentionally modified.
#
# Incremental Ninja build only. Final binary is NOT stripped.

SOURCE_DIR="${1:-/root/openmw-0.51-tsp-src}"
BUILD_DIR="${2:-/root/openmw-0.51-tsp-build}"
PACKAGE_DIR="${3:-/root/openmw-0.51-tsp-package}"
OUTPUT_BINARY="${4:-/root/openmw-0.51-tsp-transition-memory-purge}"

JOBS="${OPENMW_JOBS:-1}"
PATCH_ONLY="${OPENMW_PATCH_ONLY:-0}"

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
BACKUP_DIR="$SOURCE_DIR/.tsp-051-source-backups/transition-memory-purge-$STAMP"

restore_on_error() {
    rc=$?
    if [ "$rc" -ne 0 ] && [ -d "$BACKUP_DIR" ]; then
        echo
        echo "ERROR: transition-memory purge patch/build failed."
        echo "Restoring files modified by this attempt..."
        for rel in \
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
echo "OpenMW 0.51 TSP transition memory purge"
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
        echo "This patch intentionally does not regenerate CMake."
        exit 1
    fi
fi

echo
echo "Existing diagnostic feature checks:"
if grep -Fq 'TSP MEMPROC' "$RESOURCESYSTEM_CPP"; then
    echo "  memory process tracer: present"
else
    echo "  WARNING: TSP MEMPROC marker not found; purge still works, but process tracing may be absent."
fi
if grep -Fq 'TSP MEMSCENE' "$SCENEMANAGER_CPP"; then
    echo "  memory scene tracer:   present"
else
    echo "  WARNING: TSP MEMSCENE marker not found."
fi

mkdir -p \
    "$BACKUP_DIR/apps/openmw/mwworld" \
    "$BACKUP_DIR/components/resource" \
    "$PACKAGE_DIR/bin"

cp -f "$SCENE_CPP" "$BACKUP_DIR/apps/openmw/mwworld/scene.cpp"
cp -f "$OBJECTCACHE_HPP" "$BACKUP_DIR/components/resource/objectcache.hpp"
cp -f "$RESOURCEMANAGER_HPP" "$BACKUP_DIR/components/resource/resourcemanager.hpp"
cp -f "$RESOURCESYSTEM_HPP" "$BACKUP_DIR/components/resource/resourcesystem.hpp"
cp -f "$RESOURCESYSTEM_CPP" "$BACKUP_DIR/components/resource/resourcesystem.cpp"
cp -f "$SCENEMANAGER_HPP" "$BACKUP_DIR/components/resource/scenemanager.hpp"
cp -f "$SCENEMANAGER_CPP" "$BACKUP_DIR/components/resource/scenemanager.cpp"

echo
echo "Applying transition-memory purge source patch..."

python3 - \
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
    scene_path,
    objectcache_path,
    resourcemanager_path,
    resourcesystem_h_path,
    resourcesystem_cpp_path,
    scenemanager_h_path,
    scenemanager_cpp_path,
) = map(Path, sys.argv[1:])

scene = scene_path.read_text(encoding="utf-8")
objectcache = objectcache_path.read_text(encoding="utf-8")
resourcemanager = resourcemanager_path.read_text(encoding="utf-8")
resourcesystem_h = resourcesystem_h_path.read_text(encoding="utf-8")
resourcesystem_cpp = resourcesystem_cpp_path.read_text(encoding="utf-8")
scenemanager_h = scenemanager_h_path.read_text(encoding="utf-8")
scenemanager_cpp = scenemanager_cpp_path.read_text(encoding="utf-8")

CACHE_MARKER = "TSP_UNREFERENCED_CACHE_PURGE_051"
SCENE_MARKER = "TSP_TRANSITION_MEMORY_PURGE_051"


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


def transactional_write(items):
    temps = []
    try:
        for path, content in items:
            tmp = Path(str(path) + ".tsp-transition-memory.tmp")
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


# 1. GenericObjectCache: reference-safe purge.

if "#include <cstddef>" not in objectcache:
    anchor = "#include <algorithm>\n"
    if anchor not in objectcache:
        raise RuntimeError("objectcache.hpp: include anchor not found")
    objectcache = objectcache.replace(
        anchor,
        anchor + "#include <cstddef>\n",
        1,
    )

if CACHE_MARKER not in objectcache:
    anchor = "        /** Remove all objects in the cache regardless of having external references or expiry times.*/\n"
    if anchor not in objectcache:
        raise RuntimeError("objectcache.hpp: clear() documentation anchor not found")

    block = r'''        // TSP_UNREFERENCED_CACHE_PURGE_051
        // Remove cache ownership only when no object outside the cache owns it.
        // Active-cell assets have referenceCount() > 1 and remain reusable.
        std::size_t clearUnreferenced()
        {
            std::vector<osg::ref_ptr<osg::Object>> objectsToRemove;
            std::size_t removed = 0;

            {
                std::lock_guard<std::mutex> lock(mMutex);

                std::erase_if(mItems, [&](auto& value) {
                    Item& item = value.second;

                    if (item.mValue != nullptr && item.mValue->referenceCount() > 1)
                        return false;

                    ++removed;
                    ++mExpired;

                    if (item.mValue != nullptr)
                        objectsToRemove.push_back(std::move(item.mValue));

                    return true;
                });
            }

            // Destroy outside mMutex; object destruction can cascade to other caches.
            objectsToRemove.clear();
            return removed;
        }

'''
    objectcache = objectcache.replace(anchor, block + anchor, 1)


# 2. Resource-manager interface.

if "#include <cstddef>" not in resourcemanager:
    anchor = "#include <osg/ref_ptr>\n"
    if anchor not in resourcemanager:
        raise RuntimeError("resourcemanager.hpp: include anchor not found")
    resourcemanager = resourcemanager.replace(
        anchor,
        "#include <cstddef>\n\n" + anchor,
        1,
    )

if CACHE_MARKER not in resourcemanager:
    base_anchor = "        virtual void clearCache() = 0;\n"
    if base_anchor not in resourcemanager:
        raise RuntimeError("resourcemanager.hpp: BaseResourceManager clearCache anchor not found")

    resourcemanager = resourcemanager.replace(
        base_anchor,
        base_anchor
        + "        // TSP_UNREFERENCED_CACHE_PURGE_051\n"
        + "        virtual std::size_t clearUnreferencedCache() { return 0; }\n",
        1,
    )

    generic_anchor = "        void clearCache() override { mCache->clear(); }\n"
    if generic_anchor not in resourcemanager:
        raise RuntimeError("resourcemanager.hpp: GenericResourceManager clearCache anchor not found")

    resourcemanager = resourcemanager.replace(
        generic_anchor,
        generic_anchor
        + "        std::size_t clearUnreferencedCache() override { return mCache->clearUnreferenced(); }\n",
        1,
    )


# 3. ResourceSystem aggregate purge.

if "#include <cstddef>" not in resourcesystem_h:
    anchor = "#include <memory>\n"
    if anchor not in resourcesystem_h:
        raise RuntimeError("resourcesystem.hpp: include anchor not found")
    resourcesystem_h = resourcesystem_h.replace(
        anchor,
        "#include <cstddef>\n" + anchor,
        1,
    )

if CACHE_MARKER not in resourcesystem_h:
    anchor = "        void clearCache();\n"
    if anchor not in resourcesystem_h:
        raise RuntimeError("resourcesystem.hpp: clearCache declaration anchor not found")
    resourcesystem_h = resourcesystem_h.replace(
        anchor,
        anchor
        + "        // TSP_UNREFERENCED_CACHE_PURGE_051\n"
        + "        std::size_t clearUnreferencedCache();\n",
        1,
    )

if "ResourceSystem::clearUnreferencedCache" not in resourcesystem_cpp:
    _, end = find_function(
        resourcesystem_cpp,
        r"^[ \t]*void[ \t]+ResourceSystem::clearCache[ \t]*\([^)]*\)",
        "ResourceSystem::clearCache",
    )

    block = r'''
    // TSP_UNREFERENCED_CACHE_PURGE_051
    std::size_t ResourceSystem::clearUnreferencedCache()
    {
        std::size_t removed = 0;
        for (BaseResourceManager* manager : mResourceManagers)
            removed += manager->clearUnreferencedCache();
        return removed;
    }
'''
    resourcesystem_cpp = resourcesystem_cpp[:end] + block + resourcesystem_cpp[end:]


# 4. SceneManager: soft purge includes shared OSG texture/StateSet lists.

if CACHE_MARKER not in scenemanager_h:
    anchor = "        void clearCache() override;\n"
    if anchor not in scenemanager_h:
        raise RuntimeError("scenemanager.hpp: clearCache declaration anchor not found")
    scenemanager_h = scenemanager_h.replace(
        anchor,
        anchor
        + "        // TSP_UNREFERENCED_CACHE_PURGE_051\n"
        + "        std::size_t clearUnreferencedCache() override;\n",
        1,
    )

if "SceneManager::clearUnreferencedCache" not in scenemanager_cpp:
    _, end = find_function(
        scenemanager_cpp,
        r"^[ \t]*void[ \t]+SceneManager::clearCache[ \t]*\([^)]*\)",
        "SceneManager::clearCache",
    )

    block = r'''
    // TSP_UNREFERENCED_CACHE_PURGE_051
    std::size_t SceneManager::clearUnreferencedCache()
    {
        std::size_t removed = ResourceManager::clearUnreferencedCache();

        {
            std::lock_guard<std::mutex> lock(mSharedStateMutex);

            const std::size_t before
                = mSharedStateManager->getNumSharedTextures()
                + mSharedStateManager->getNumSharedStateSets();

            mSharedStateManager->prune();

            const std::size_t after
                = mSharedStateManager->getNumSharedTextures()
                + mSharedStateManager->getNumSharedStateSets();

            if (before > after)
                removed += before - after;
        }

        if (mIncrementalCompileOperation)
        {
            std::lock_guard<OpenThreads::Mutex> lock(
                *mIncrementalCompileOperation->getToCompiledMutex());

            osgUtil::IncrementalCompileOperation::CompileSets& sets
                = mIncrementalCompileOperation->getToCompile();

            for (auto it = sets.begin(); it != sets.end();)
            {
                int refcount = (*it)->_subgraphToCompile->referenceCount();
                if ((*it)->_subgraphToCompile->asDrawable())
                    refcount -= 1;

                if (refcount <= 2)
                {
                    it = sets.erase(it);
                    ++removed;
                }
                else
                    ++it;
            }
        }

        return removed;
    }
'''
    scenemanager_cpp = scenemanager_cpp[:end] + block + scenemanager_cpp[end:]


# 5. Scene transition hooks.

if "#include <malloc.h>" not in scene:
    anchor = "#include <limits>\n"
    if anchor not in scene:
        raise RuntimeError("scene.cpp: standard include anchor not found")
    scene = scene.replace(
        anchor,
        anchor
        + "\n#if defined(__linux__) && defined(__GLIBC__)\n"
        + "#include <malloc.h>\n"
        + "#endif\n",
        1,
    )

if SCENE_MARKER not in scene:
    _, end = find_function(
        scene,
        r"^[ \t]*void[ \t]+sortCellsToLoad[ \t]*\(",
        "sortCellsToLoad",
    )

    helper = r'''
    // TSP_TRANSITION_MEMORY_PURGE_051
    void tspPurgeTransitionMemory(
        MWRender::RenderingManager& rendering,
        std::string_view reason,
        bool hard,
        std::size_t activeCells)
    {
        Resource::ResourceSystem* resourceSystem = rendering.getResourceSystem();
        if (resourceSystem == nullptr)
            return;

        if (hard)
        {
            resourceSystem->clearCache();

#if defined(__linux__) && defined(__GLIBC__)
            ::malloc_trim(0);
#endif

            Log(Debug::Info)
                << "TSP MEMPURGE reason=" << reason
                << " mode=hard active_cells=" << activeCells
                << " removed_entries=all";
        }
        else
        {
            const std::size_t removed
                = resourceSystem->clearUnreferencedCache();

#if defined(__linux__) && defined(__GLIBC__)
            ::malloc_trim(0);
#endif

            Log(Debug::Info)
                << "TSP MEMPURGE reason=" << reason
                << " mode=soft active_cells=" << activeCells
                << " removed_entries=" << removed;
        }
    }
'''
    scene = scene[:end] + helper + scene[end:]

    # Save/load full scene clear.
    clear_start, clear_end = find_function(
        scene,
        r"^[ \t]*void[ \t]+Scene::clear[ \t]*\([^)]*\)",
        "Scene::clear",
    )
    clear_func = scene[clear_start:clear_end]
    clear_open = clear_func.find("{")
    if clear_open < 0:
        raise RuntimeError("Scene::clear opening brace missing")

    clear_func = (
        clear_func[:clear_open + 1]
        + "\n        const bool tspHadActiveCells = !mActiveCells.empty();"
        + clear_func[clear_open + 1:]
    )

    anchor = "        mPreloader->clear();\n"
    if anchor not in clear_func:
        raise RuntimeError("Scene::clear mPreloader->clear anchor missing")

    clear_func = clear_func.replace(
        anchor,
        anchor
        + "\n"
        + "        if (tspHadActiveCells)\n"
        + '            tspPurgeTransitionMemory(mRendering, "scene-clear", true, mActiveCells.size());\n',
        1,
    )
    scene = scene[:clear_start] + clear_func + scene[clear_end:]

    # Transition to interior: old active set is empty before load.
    interior_start, interior_end = find_function(
        scene,
        r"^[ \t]*void[ \t]+Scene::changeToInteriorCell[ \t]*\(",
        "Scene::changeToInteriorCell",
    )
    interior_func = scene[interior_start:interior_end]

    anchor = "        assert(mActiveCells.empty());\n"
    if anchor not in interior_func:
        raise RuntimeError("changeToInteriorCell active-cell assertion anchor missing")

    interior_func = interior_func.replace(
        anchor,
        anchor
        + "\n"
        + "        mPreloader->clear();\n"
        + '        tspPurgeTransitionMemory(mRendering, "to-interior", true, mActiveCells.size());\n',
        1,
    )
    scene = scene[:interior_start] + interior_func + scene[interior_end:]

    # Exterior-grid transition.
    grid_start, grid_end = find_function(
        scene,
        r"^[ \t]*void[ \t]+Scene::changeCellGrid[ \t]*\(",
        "Scene::changeCellGrid",
    )
    grid_func = scene[grid_start:grid_end]

    anchor = "        const int playerCellY = playerCellIndex.mY;\n"
    if anchor not in grid_func:
        raise RuntimeError("changeCellGrid playerCellY anchor missing")

    grid_func = grid_func.replace(
        anchor,
        anchor
        + "        const std::size_t tspActiveBeforeUnload = mActiveCells.size();\n",
        1,
    )

    bounds_anchor = "        const DetourNavigator::CellGridBounds cellGridBounds{\n"
    if bounds_anchor not in grid_func:
        raise RuntimeError("changeCellGrid CellGridBounds anchor missing")

    purge_block = r'''        const bool tspUnloadedCells
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
    grid_func = grid_func.replace(
        bounds_anchor,
        purge_block + bounds_anchor,
        1,
    )
    scene = scene[:grid_start] + grid_func + scene[grid_end:]


contents = {
    objectcache_path: objectcache,
    resourcemanager_path: resourcemanager,
    resourcesystem_h_path: resourcesystem_h,
    resourcesystem_cpp_path: resourcesystem_cpp,
    scenemanager_h_path: scenemanager_h,
    scenemanager_cpp_path: scenemanager_cpp,
    scene_path: scene,
}

checks = {
    objectcache_path: [
        CACHE_MARKER,
        "std::size_t clearUnreferenced()",
        "referenceCount() > 1",
    ],
    resourcemanager_path: [
        CACHE_MARKER,
        "clearUnreferencedCache()",
    ],
    resourcesystem_h_path: [
        CACHE_MARKER,
        "std::size_t clearUnreferencedCache();",
    ],
    resourcesystem_cpp_path: [
        CACHE_MARKER,
        "ResourceSystem::clearUnreferencedCache",
    ],
    scenemanager_h_path: [
        CACHE_MARKER,
        "clearUnreferencedCache() override",
    ],
    scenemanager_cpp_path: [
        CACHE_MARKER,
        "SceneManager::clearUnreferencedCache",
        "mSharedStateManager->prune();",
    ],
    scene_path: [
        SCENE_MARKER,
        "TSP MEMPURGE reason=",
        "exterior-grid-shift",
        "scene-clear",
        "to-interior",
        "to-exterior",
        "::malloc_trim(0);",
    ],
}

for path, tokens in checks.items():
    content = contents[path]
    for token in tokens:
        if token not in content:
            raise RuntimeError(f"{path}: verification missing token: {token}")

transactional_write(
    [
        (scene_path, scene),
        (objectcache_path, objectcache),
        (resourcemanager_path, resourcemanager),
        (resourcesystem_h_path, resourcesystem_h),
        (resourcesystem_cpp_path, resourcesystem_cpp),
        (scenemanager_h_path, scenemanager_h),
        (scenemanager_cpp_path, scenemanager_cpp),
    ]
)

print("Transition-memory purge patch applied and verified.")
print()
print("Policy:")
print("  save/reload Scene::clear:        HARD")
print("  transition to interior:          HARD")
print("  interior/worldspace -> exterior: HARD")
print("  ordinary exterior grid shift:    SOFT (unreferenced only)")
PY_PATCH

echo
echo "===== TRANSITION MEMORY PURGE VERIFICATION ====="
grep -n \
    -e 'TSP_TRANSITION_MEMORY_PURGE_051' \
    -e 'TSP MEMPURGE reason=' \
    -e 'exterior-grid-shift' \
    -e 'scene-clear' \
    -e 'to-interior' \
    -e 'to-exterior' \
    "$SCENE_CPP"

echo
grep -n \
    -e 'TSP_UNREFERENCED_CACHE_PURGE_051' \
    -e 'clearUnreferencedCache' \
    "$OBJECTCACHE_HPP" \
    "$RESOURCEMANAGER_HPP" \
    "$RESOURCESYSTEM_HPP" \
    "$RESOURCESYSTEM_CPP" \
    "$SCENEMANAGER_HPP" \
    "$SCENEMANAGER_CPP" | head -80

if [ "$PATCH_ONLY" = "1" ]; then
    trap - ERR
    echo
    echo "PATCH_ONLY=1: source patch and verification completed."
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
    cp -f "$PACKAGE_BINARY" "$PACKAGE_BINARY.before-transition-memory-purge-$STAMP"
fi

cp -f "$BUILT_BINARY" "$OUTPUT_BINARY"
cp -f "$BUILT_BINARY" "$PACKAGE_BINARY"
chmod +x "$OUTPUT_BINARY" "$PACKAGE_BINARY"

echo
echo "Binary verification:"
file "$PACKAGE_BINARY"
sha256sum "$PACKAGE_BINARY"
"$PACKAGE_BINARY" --version || true

echo
echo "Marker strings in binary:"
strings "$PACKAGE_BINARY" | grep -E \
    'TSP MEMPURGE|TSP MEMPROC|TSP MEMSCENE|TSP SafeNav|TSP_TEST_CURSOR' \
    | head -40 || true

trap - ERR

echo
echo "============================================================"
echo "SUCCESS: OpenMW 0.51 TSP transition memory purge built"
echo "============================================================"
echo "Standalone unstripped binary:"
echo "  $OUTPUT_BINARY"
echo
echo "Packaged unstripped binary:"
echo "  $PACKAGE_BINARY"
echo
echo "Source backup:"
echo "  $BACKUP_DIR"
echo
echo "Runtime behavior:"
echo "  HARD: save reload / empty-world interior-exterior transitions"
echo "  SOFT: ordinary exterior cell-grid shifts"
echo
echo "Look for these lines in openmw.log:"
echo "  TSP MEMPURGE reason=scene-clear mode=hard"
echo "  TSP MEMPURGE reason=to-interior mode=hard"
echo "  TSP MEMPURGE reason=to-exterior mode=hard"
echo "  TSP MEMPURGE reason=exterior-grid-shift mode=soft"
echo "============================================================"
