#!/bin/bash
set -Eeuo pipefail

SOURCE_DIR="${1:-/root/openmw-0.51-tsp-src}"
BUILD_DIR="${2:-/root/openmw-0.51-tsp-build}"
PACKAGE_DIR="${3:-/root/openmw-0.51-tsp-package}"
OUTPUT_BINARY="${4:-/root/openmw-0.51-tsp-v15-visibility-freshguard}"

JOBS="${OPENMW_JOBS:-1}"
PATCH_ONLY="${OPENMW_PATCH_ONLY:-0}"

STATE_CPP="$SOURCE_DIR/apps/openmw/mwstate/statemanagerimp.cpp"
RENDER_CPP="$SOURCE_DIR/apps/openmw/mwrender/renderingmanager.cpp"
WORLD_CPP="$SOURCE_DIR/apps/openmw/mwworld/worldimp.cpp"
ENGINE_CPP="$SOURCE_DIR/apps/openmw/engine.cpp"
CMAKE_FILE="$SOURCE_DIR/CMakeLists.txt"
BUILT_BINARY="$BUILD_DIR/openmw"
PACKAGE_BINARY="$PACKAGE_DIR/bin/openmw-0.51"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$SOURCE_DIR/.tsp-051-source-backups/v15-visibility-freshguard-$STAMP"

restore_on_error() {
    rc=$?
    if [ "$rc" -ne 0 ] && [ -d "$BACKUP_DIR" ]; then
        echo
        echo "ERROR: V15 patch/build failed."
        echo "Restoring source files changed by this attempt..."
        [ -f "$BACKUP_DIR/apps/openmw/mwstate/statemanagerimp.cpp" ] && \
            cp -f "$BACKUP_DIR/apps/openmw/mwstate/statemanagerimp.cpp" "$STATE_CPP"
        [ -f "$BACKUP_DIR/apps/openmw/mwrender/renderingmanager.cpp" ] && \
            cp -f "$BACKUP_DIR/apps/openmw/mwrender/renderingmanager.cpp" "$RENDER_CPP"
        echo "Source restoration complete."
        echo "Failed-attempt backup retained at:"
        echo "  $BACKUP_DIR"
    fi
    exit "$rc"
}
trap restore_on_error ERR

echo "============================================================"
echo "OpenMW 0.51 TSP V15 VISIBILITY + FRESH-RELOAD GUARD"
echo "============================================================"
echo "Source:        $SOURCE_DIR"
echo "Build:         $BUILD_DIR"
echo "Package:       $PACKAGE_DIR"
echo "Output binary: $OUTPUT_BINARY"
echo "Patch only:    $PATCH_ONLY"
echo "Jobs:          $JOBS"
echo "Backup:        $BACKUP_DIR"
echo "============================================================"

for required in "$STATE_CPP" "$RENDER_CPP" "$WORLD_CPP" "$ENGINE_CPP" "$CMAKE_FILE"; do
    if [ ! -f "$required" ]; then
        echo "ERROR: missing required source file:"
        echo "  $required"
        exit 1
    fi
done

VERSION_MAJOR="$(sed -n 's/^[[:space:]]*set(OPENMW_VERSION_MAJOR[[:space:]]*\([0-9][0-9]*\)).*/\1/p' "$CMAKE_FILE" | head -1)"
VERSION_MINOR="$(sed -n 's/^[[:space:]]*set(OPENMW_VERSION_MINOR[[:space:]]*\([0-9][0-9]*\)).*/\1/p' "$CMAKE_FILE" | head -1)"
if [ "$VERSION_MAJOR" != "0" ] || [ "$VERSION_MINOR" != "51" ]; then
    echo "ERROR: expected OpenMW 0.51 source; detected ${VERSION_MAJOR:-?}.${VERSION_MINOR:-?}."
    exit 1
fi

for marker in \
    'TSP_DEPTH_PARTITION_051_V14' \
    'TSP_WARM_ASYNC_GUARD_051_V14' \
    'TSP_SAFE_RELOAD_CONFIG_051_V13' \
    'TSP_LOAD_TRACE_051_V13' \
    'TSP_LOAD_WATCH_051_V13' \
    'TSP_FRESH_PROCESS_LOAD_051_V12'
do
    if ! grep -Fq "$marker" "$STATE_CPP" "$RENDER_CPP" 2>/dev/null; then
        echo "ERROR: required V12/V13/V14 baseline marker missing: $marker"
        echo "This V15 patch expects the source tree used to build V14."
        echo "Nothing was changed."
        exit 1
    fi
done

if ! grep -Fq 'TSP_WARM_LIFETIME_RESET_051_V13' "$WORLD_CPP"; then
    echo "ERROR: corrected V13 world lifetime marker missing."
    exit 1
fi

if [ "$PATCH_ONLY" != "1" ]; then
    if [ ! -f "$BUILD_DIR/build.ninja" ] || [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
        echo "ERROR: configured Ninja build tree is missing."
        echo "This script intentionally does not re-run CMake."
        exit 1
    fi
fi

mkdir -p \
    "$BACKUP_DIR/apps/openmw/mwstate" \
    "$BACKUP_DIR/apps/openmw/mwrender" \
    "$PACKAGE_DIR/bin"

cp -f "$STATE_CPP"  "$BACKUP_DIR/apps/openmw/mwstate/statemanagerimp.cpp"
cp -f "$RENDER_CPP" "$BACKUP_DIR/apps/openmw/mwrender/renderingmanager.cpp"

echo
echo "Applying V15 visibility/fresh-guard source revision..."

python3 - "$STATE_CPP" "$RENDER_CPP" <<'PY_PATCH'
from pathlib import Path
import re
import sys

state_path, render_path = map(Path, sys.argv[1:])
state = state_path.read_text(encoding="utf-8")
render = render_path.read_text(encoding="utf-8")

VIS_MARK = "TSP_VISIBILITY_FIRST_051_V15"
FRESH_MARK = "TSP_FRESH_DEFAULT_051_V15"


def write_lf(path, text):
    with path.open("w", encoding="utf-8", newline="\n") as f:
        f.write(text)


# 1) VISIBILITY FIRST
# V14 changed the MASTER camera near plane to ~70 and duplicated the full scene
# through a 12..110 slave camera. V15 keeps that code for an explicit A/B test,
# but defaults the partition OFF. With it off, tspWorldNearClip() naturally
# returns mNearClip and the renderer collapses back to one normal scene camera.
if VIS_MARK not in render:
    old_func = '''    bool tspDepthPartitionEnabled()\n    {\n        return tspEnvBool("OPENMW_TSP_DEPTH_PARTITION", true);\n    }'''
    new_func = '''    // TSP_VISIBILITY_FIRST_051_V15\n    // Safe/default path: one normal scene camera. The V14 depth partition\n    // remains opt-in via OPENMW_TSP_DEPTH_PARTITION=1 for controlled A/B tests.\n    bool tspDepthPartitionEnabled()\n    {\n        const bool enabled = tspEnvBool("OPENMW_TSP_DEPTH_PARTITION", false);\n        static bool logged = false;\n        if (!logged)\n        {\n            Log(Debug::Info) << "TSP_VISIBILITY_FIRST_051_V15"\n                             << " depth_partition=" << (enabled ? 1 : 0)\n                             << " default=0";\n            logged = true;\n        }\n        return enabled;\n    }'''
    if old_func not in render:
        raise RuntimeError(
            "renderingmanager.cpp: exact V14 tspDepthPartitionEnabled() baseline not found"
        )
    render = render.replace(old_func, new_func, 1)
else:
    if 'OPENMW_TSP_DEPTH_PARTITION", false' not in render:
        raise RuntimeError(
            "renderingmanager.cpp: V15 visibility marker exists but default-off policy is not intact"
        )


# 2) FRESH-RELOAD CRASH GUARD
# V13's safe-reload setting already uses the proven V12 exec-based reload.
# Change only the absence/default case from warm to fresh. Explicit setting/env
# values still override it, so safe reload=0 remains available for diagnostics.
if FRESH_MARK not in state:
    struct_re = re.compile(
        r'(?P<prefix>struct\s+TspSafeReloadSetting\s*\{\s*)'
        r'bool\s+enabled\s*=\s*false\s*;',
        flags=re.DOTALL,
    )
    sm = struct_re.search(state)
    if not sm:
        raise RuntimeError(
            "statemanagerimp.cpp: V13 TspSafeReloadSetting default-false anchor not found"
        )
    replacement = sm.group("prefix") + "// TSP_FRESH_DEFAULT_051_V15\n        bool enabled = true;"
    state = state[:sm.start()] + replacement + state[sm.end():]

    active_hook = "            if (tspSafeReload.enabled)\n"
    if active_hook not in state:
        raise RuntimeError(
            "statemanagerimp.cpp: V13 safe-reload enabled-test anchor not found"
        )
    v15_log = (
        '            Log(Debug::Info) << "TSP_FRESH_DEFAULT_051_V15"\n'
        '                             << " effective_fresh=" << (tspSafeReload.enabled ? 1 : 0)\n'
        '                             << " explicit=" << (tspSafeReload.found ? 1 : 0)\n'
        '                             << " source=" << tspSafeReload.source;\n'
    )
    state = state.replace(active_hook, v15_log + active_hook, 1)
else:
    default_re = re.compile(
        r'// TSP_FRESH_DEFAULT_051_V15\s*\n\s*bool\s+enabled\s*=\s*true\s*;'
    )
    if not default_re.search(state):
        raise RuntimeError(
            "statemanagerimp.cpp: V15 fresh-default marker exists but enabled=true is not intact"
        )


for required in (
    VIS_MARK,
    'OPENMW_TSP_DEPTH_PARTITION", false',
    'TSP_DEPTH_PARTITION_051_V14',
    'TSP_WARM_ASYNC_GUARD_051_V14',
):
    if required not in render:
        raise RuntimeError(f"renderingmanager.cpp: V15 verification missing: {required}")

for required in (
    FRESH_MARK,
    "bool enabled = true;",
    "TSP_SAFE_RELOAD_CONFIG_051_V13",
    "TSP_SAFE_RELOAD_051_V13 action=fresh",
    "TSP_SAFE_RELOAD_051_V13 action=warm",
    "TSP_LOAD_TRACE_051_V13",
    "TSP_LOAD_WATCH_051_V13",
    "TSP_FRESH_PROCESS_LOAD_051_V12",
):
    if required not in state:
        raise RuntimeError(f"statemanagerimp.cpp: V15 verification missing: {required}")

write_lf(state_path, state)
write_lf(render_path, render)

print("V15 source revision applied.")
print("  graphics: V14 duplicate full-scene depth partition DEFAULT OFF")
print("  graphics: V14 partition retained as OPENMW_TSP_DEPTH_PARTITION=1 A/B switch")
print("  loading: fresh-process active save reload DEFAULT when [TSP] key is absent")
print("  loading: explicit [TSP] safe reload = 0 still permits warm-load diagnostics")
print("  diagnostics: V13 load/watch/depth + V14 async guard preserved")
PY_PATCH

echo
echo "===== SOURCE VERIFICATION ====="
echo "V15 visibility policy:"
grep -n -m 12 \
    -e 'TSP_VISIBILITY_FIRST_051_V15' \
    -e 'OPENMW_TSP_DEPTH_PARTITION' \
    "$RENDER_CPP"

echo
echo "V15 fresh-reload default:"
grep -n -m 16 \
    -e 'TSP_FRESH_DEFAULT_051_V15' \
    -e 'TSP_SAFE_RELOAD_CONFIG_051_V13' \
    -e 'TSP_SAFE_RELOAD_051_V13' \
    "$STATE_CPP"

echo
echo "V13/V14 diagnostics retained:"
grep -n -m 12 \
    -e 'TSP_DEPTH_PARTITION_051_V14' \
    -e 'TSP_WARM_ASYNC_GUARD_051_V14' \
    -e 'TSP_DEPTH_PROJECTION_051_V13' \
    "$RENDER_CPP"
grep -n -m 12 \
    -e 'TSP_LOAD_TRACE_051_V13' \
    -e 'TSP_LOAD_WATCH_051_V13' \
    "$STATE_CPP"

echo
echo "Transition-memory purge must remain absent:"
if grep -RniE \
    'TSP_TRANSITION_MEMORY_PURGE_051|TSP_UNREFERENCED_CACHE_PURGE_051|TSP MEMPURGE|tspPurgeTransitionMemory|clearUnreferencedCache' \
    "$SOURCE_DIR/apps/openmw/mwworld/scene.cpp" \
    "$SOURCE_DIR/components/resource" 2>/dev/null
then
    echo "ERROR: transition-memory-purge remnant found."
    exit 1
else
    echo "  PASS: transition-memory-purge experiment remains absent."
fi

if [ "$PATCH_ONLY" = "1" ]; then
    trap - ERR
    echo
    echo "PATCH_ONLY=1: V15 source patch/verification completed."
    exit 0
fi

echo
echo "Incrementally rebuilding OpenMW 0.51 (UNSTRIPPED)..."
cmake --build "$BUILD_DIR" --target openmw --parallel "$JOBS"

if [ ! -x "$BUILT_BINARY" ]; then
    echo "ERROR: rebuilt OpenMW executable is missing:"
    echo "  $BUILT_BINARY"
    exit 1
fi

if [ -e "$OUTPUT_BINARY" ]; then
    cp -f "$OUTPUT_BINARY" "$OUTPUT_BINARY.before-$STAMP"
fi
if [ -e "$PACKAGE_BINARY" ]; then
    cp -f "$PACKAGE_BINARY" "$PACKAGE_BINARY.before-v15-$STAMP"
fi

cp -f "$BUILT_BINARY" "$OUTPUT_BINARY"
cp -f "$BUILT_BINARY" "$PACKAGE_BINARY"
chmod +x "$OUTPUT_BINARY" "$PACKAGE_BINARY"

echo
echo "===== BINARY VERIFICATION ====="
file "$PACKAGE_BINARY"
sha256sum "$PACKAGE_BINARY"
"$PACKAGE_BINARY" --version || true

for marker in \
    'TSP_VISIBILITY_FIRST_051_V15' \
    'TSP_FRESH_DEFAULT_051_V15' \
    'TSP_DEPTH_PARTITION_051_V14' \
    'TSP_WARM_ASYNC_GUARD_051_V14' \
    'TSP_SAFE_RELOAD_CONFIG_051_V13' \
    'TSP_LOAD_TRACE_051_V13' \
    'TSP_LOAD_WATCH_051_V13' \
    'TSP_DEPTH_DIAG_051_V13' \
    'TSP_FRESH_PROCESS_LOAD_051_V12'
do
    if ! strings "$PACKAGE_BINARY" | grep -F "$marker" >/dev/null; then
        echo "ERROR: required runtime marker missing from rebuilt binary: $marker"
        exit 1
    fi
done

echo "  PASS: V15 runtime markers present."
echo "  PASS: V12/V13/V14 safety and diagnostic markers retained."

if strings "$PACKAGE_BINARY" | grep -E \
    'TSP MEMPURGE|TSP_TRANSITION_MEMORY_PURGE_051|TSP_UNREFERENCED_CACHE_PURGE_051' >/dev/null
then
    echo "ERROR: transition-memory-purge marker unexpectedly present in binary."
    exit 1
else
    echo "  PASS: transition-memory-purge markers absent from binary."
fi

echo
echo "SafeNav marker (expected):"
strings "$PACKAGE_BINARY" | grep -F -m 3 'TSP SafeNav' || \
    echo "WARNING: SafeNav marker string not found; inspect before enabling navigator."

trap - ERR

echo
echo "============================================================"
echo "SUCCESS: OpenMW 0.51 V15 visibility/fresh-guard build complete"
echo "============================================================"
echo "Package binary:"
echo "  $PACKAGE_BINARY"
echo "Container backup copy:"
echo "  $OUTPUT_BINARY"
echo "Source backup:"
echo "  $BACKUP_DIR"
echo
echo "Default V15 behavior:"
echo "  V14 duplicate depth slave   = OFF"
echo "  normal configured near clip = used directly"
echo "  active save reload          = FRESH process by default"
echo "  incremental compile         = OFF (V14 guard retained)"
echo
echo "Runtime / config switches:"
echo "  OPENMW_TSP_DEPTH_PARTITION=1    # old V14 A/B test ONLY"
echo "  OPENMW_TSP_DEPTH_PARTITION=0    # V15/default visibility path"
echo "  OPENMW_TSP_SAFE_RELOAD=1        # force fresh"
echo "  OPENMW_TSP_SAFE_RELOAD=0        # force warm diagnostic test"
echo "  [TSP] safe reload = 1           # explicit fresh"
echo "  [TSP] safe reload = 0           # explicit warm"
echo
echo "First graphics test recommendation:"
echo "  [Camera] near clip = 15"
echo "  Do NOT set OPENMW_TSP_DEPTH_PARTITION=1 for the first V15 test."
echo "============================================================"
