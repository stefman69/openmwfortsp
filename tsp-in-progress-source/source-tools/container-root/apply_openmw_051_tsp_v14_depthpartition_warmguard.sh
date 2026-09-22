#!/bin/bash
set -Eeuo pipefail

SOURCE_DIR="${1:-/root/openmw-0.51-tsp-src}"
BUILD_DIR="${2:-/root/openmw-0.51-tsp-build}"
PACKAGE_DIR="${3:-/root/openmw-0.51-tsp-package}"
OUTPUT_BINARY="${4:-/root/openmw-0.51-tsp-v14-depthpartition-warmguard}"

JOBS="${OPENMW_JOBS:-1}"
PATCH_ONLY="${OPENMW_PATCH_ONLY:-0}"

STATE_CPP="$SOURCE_DIR/apps/openmw/mwstate/statemanagerimp.cpp"
WORLD_CPP="$SOURCE_DIR/apps/openmw/mwworld/worldimp.cpp"
ENGINE_CPP="$SOURCE_DIR/apps/openmw/engine.cpp"
RENDER_CPP="$SOURCE_DIR/apps/openmw/mwrender/renderingmanager.cpp"
CMAKE_FILE="$SOURCE_DIR/CMakeLists.txt"
BUILT_BINARY="$BUILD_DIR/openmw"
PACKAGE_BINARY="$PACKAGE_DIR/bin/openmw-0.51"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$SOURCE_DIR/.tsp-051-source-backups/v14-depthpartition-warmguard-$STAMP"

restore_on_error() {
    rc=$?
    if [ "$rc" -ne 0 ] && [ -d "$BACKUP_DIR" ]; then
        echo
        echo "ERROR: V14 patch/build failed."
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
echo "OpenMW 0.51 TSP V14 DEPTH PARTITION + WARM GUARD"
echo "============================================================"
echo "Source:        $SOURCE_DIR"
echo "Build:         $BUILD_DIR"
echo "Package:       $PACKAGE_DIR"
echo "Output binary: $OUTPUT_BINARY"
echo "Patch only:    $PATCH_ONLY"
echo "Jobs:          $JOBS"
echo "Backup:        $BACKUP_DIR"
echo "============================================================"

for required in "$STATE_CPP" "$WORLD_CPP" "$ENGINE_CPP" "$RENDER_CPP" "$CMAKE_FILE"; do
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
    'TSP_SAFE_RELOAD_CONFIG_051_V13' \
    'TSP_LOAD_TRACE_051_V13' \
    'TSP_LOAD_WATCH_051_V13'
do
    if ! grep -Fq "$marker" "$STATE_CPP"; then
        echo "ERROR: corrected V13 baseline marker missing: $marker"
        echo "Nothing was changed."
        exit 1
    fi
done

if ! grep -Fq 'TSP_WARM_LIFETIME_RESET_051_V13' "$WORLD_CPP"; then
    echo "ERROR: corrected V13 world lifetime marker missing."
    exit 1
fi

for marker in \
    'TSP_DEPTH_PROJECTION_051_V13' \
    'TSP_PLAYER_ANIMATION_SWAP_051_V13'
do
    if ! grep -Fq "$marker" "$RENDER_CPP"; then
        echo "ERROR: corrected V13 rendering marker missing: $marker"
        exit 1
    fi
done

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
echo "Applying V14 source revision..."

python3 - "$STATE_CPP" "$RENDER_CPP" <<'PY_PATCH'
from pathlib import Path
import re
import sys

state_path, render_path = map(Path, sys.argv[1:])
state = state_path.read_text(encoding="utf-8")
render = render_path.read_text(encoding="utf-8")

DEPTH_MARK = "TSP_DEPTH_PARTITION_051_V14"
ASYNC_MARK = "TSP_WARM_ASYNC_GUARD_051_V14"


def find_function(text, signature_pattern, label):
    matches = list(re.finditer(signature_pattern, text, flags=re.MULTILINE))
    if len(matches) != 1:
        raise RuntimeError(f"{label}: expected one signature, found {len(matches)}")
    start = matches[0].start()
    opening = text.find("{", matches[0].end())
    if opening < 0:
        raise RuntimeError(f"{label}: opening brace not found")

    depth = 0
    i = opening
    in_string = in_char = in_line_comment = in_block_comment = False
    escaped = False

    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
        elif in_block_comment:
            if ch == "*" and nxt == "/":
                in_block_comment = False
                i += 1
        elif in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
        elif in_char:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == "'":
                in_char = False
        else:
            if ch == "/" and nxt == "/":
                in_line_comment = True
                i += 1
            elif ch == "/" and nxt == "*":
                in_block_comment = True
                i += 1
            elif ch == '"':
                in_string = True
            elif ch == "'":
                in_char = True
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return start, i + 1
        i += 1
    raise RuntimeError(f"{label}: closing brace not found")


def write_lf(path, text):
    with path.open("w", encoding="utf-8", newline="\n") as f:
        f.write(text)


# 1) Helper state/functions.
if DEPTH_MARK not in render:
    first_include = re.search(r'^#include[^\n]*\n', render, flags=re.MULTILINE)
    if not first_include:
        raise RuntimeError("renderingmanager.cpp: include anchor not found")

    extra = ""
    if "#include <algorithm>" not in render:
        extra += "#include <algorithm>\n"
    if "#include <cstdlib>" not in render:
        extra += "#include <cstdlib>\n"
    if "#include <cstring>" not in render:
        extra += "#include <cstring>\n"
    if extra:
        render = render[:first_include.end()] + extra + render[first_include.end():]

    ns = re.search(r'namespace\s+MWRender\s*\n?\{', render)
    if not ns:
        raise RuntimeError("renderingmanager.cpp: namespace MWRender anchor missing")

    helper = r'''

    // TSP_DEPTH_PARTITION_051_V14
    static osg::ref_ptr<osg::Camera> sTspNearDepthCamera;

    bool tspEnvBool(const char* name, bool fallback)
    {
        const char* value = std::getenv(name);
        if (value == nullptr || *value == '\0')
            return fallback;
        if (std::strcmp(value, "0") == 0 || std::strcmp(value, "false") == 0
            || std::strcmp(value, "off") == 0 || std::strcmp(value, "no") == 0)
            return false;
        if (std::strcmp(value, "1") == 0 || std::strcmp(value, "true") == 0
            || std::strcmp(value, "on") == 0 || std::strcmp(value, "yes") == 0)
            return true;
        return fallback;
    }

    float tspEnvFloat(const char* name, float fallback)
    {
        const char* value = std::getenv(name);
        if (value == nullptr || *value == '\0')
            return fallback;
        char* end = nullptr;
        const float parsed = std::strtof(value, &end);
        if (end == value || *end != '\0')
            return fallback;
        return parsed;
    }

    bool tspDepthPartitionEnabled()
    {
        return tspEnvBool("OPENMW_TSP_DEPTH_PARTITION", true);
    }

    float tspWorldNearClip(float configuredNear, float farClip)
    {
        if (!tspDepthPartitionEnabled() || SceneUtil::AutoDepth::isReversed())
            return configuredNear;

        float requested = tspEnvFloat("OPENMW_TSP_WORLD_NEAR", 70.f);
        requested = std::max(requested, configuredNear);
        requested = std::max(requested, 1.f);
        requested = std::min(requested, farClip - 2.f);
        return requested;
    }

    float tspNearPassFarClip(float worldNear, float farClip)
    {
        float requested = tspEnvFloat("OPENMW_TSP_NEAR_PASS_FAR", 110.f);
        requested = std::max(requested, worldNear + 2.f);
        requested = std::min(requested, farClip);
        return requested;
    }

    bool tspIncrementalCompileEnabled()
    {
        return tspEnvBool("OPENMW_TSP_INCREMENTAL_COMPILE", false);
    }
'''
    render = render[:ns.end()] + helper + render[ns.end():]


# 2) Disable OSG IncrementalCompileOperation by default.
if ASYNC_MARK not in render:
    pat = re.compile(
        r'(?P<indent>^[ \t]*)if\s*\(\s*(?:std::)?getenv\("OPENMW_DONT_PRECOMPILE"\)\s*==\s*nullptr\s*\)',
        flags=re.MULTILINE,
    )
    m = pat.search(render)
    if not m:
        raise RuntimeError(
            "renderingmanager.cpp: OPENMW_DONT_PRECOMPILE incremental-compile anchor missing"
        )

    ind = m.group("indent")
    repl = (
        ind + '// TSP_WARM_ASYNC_GUARD_051_V14\n'
        + ind + 'const bool tspUseIncrementalCompile = tspIncrementalCompileEnabled();\n'
        + ind + 'Log(Debug::Info) << "TSP_WARM_ASYNC_GUARD_051_V14 incremental_compile="\n'
        + ind + '                 << (tspUseIncrementalCompile ? 1 : 0);\n'
        + ind + 'if (tspUseIncrementalCompile && std::getenv("OPENMW_DONT_PRECOMPILE") == nullptr)'
    )
    render = render[:m.start()] + repl + render[m.end():]


# 3) V14 projection partition.
sig = r"^[ \t]*void[ \t]+RenderingManager::updateProjectionMatrix[ \t]*\(\)"
rstart, rend = find_function(render, sig, "RenderingManager::updateProjectionMatrix")
rfunc = render[rstart:rend]

if DEPTH_MARK + "_ACTIVE" not in rfunc:
    persp_re = re.compile(
        r'(?P<indent>^[ \t]*)osg::Matrix(?:d)?\s+unreversedProjectionMatrix\s*=\s*'
        r'osg::Matrix(?:d)?::perspective\(\s*fov\s*,\s*aspect\s*,\s*mNearClip\s*,\s*mViewDistance\s*\)\s*;',
        flags=re.MULTILINE,
    )
    pm = persp_re.search(rfunc)
    if not pm:
        raise RuntimeError(
            "renderingmanager.cpp: updateProjectionMatrix perspective anchor missing"
        )

    ind = pm.group("indent")
    replacement = r'''__IND__// TSP_DEPTH_PARTITION_051_V14_ACTIVE
__IND__const bool tspPartition = tspDepthPartitionEnabled() && !SceneUtil::AutoDepth::isReversed();
__IND__const float tspFarPassNear = tspWorldNearClip(mNearClip, mViewDistance);
__IND__const float tspNearPassFar = tspNearPassFarClip(tspFarPassNear, mViewDistance);
__IND__
__IND__osg::Matrix unreversedProjectionMatrix
__IND__    = osg::Matrix::perspective(fov, aspect, tspFarPassNear, mViewDistance);
__IND__
__IND__Log(Debug::Info) << "TSP_DEPTH_PARTITION_051_V14"
__IND__                 << " enabled=" << (tspPartition ? 1 : 0)
__IND__                 << " configured_near=" << mNearClip
__IND__                 << " far_pass_near=" << tspFarPassNear
__IND__                 << " near_pass_far=" << tspNearPassFar
__IND__                 << " far=" << mViewDistance
__IND__                 << " far_ratio="
__IND__                 << (tspFarPassNear > 0.f ? mViewDistance / tspFarPassNear : 0.f);
'''.replace("__IND__", ind)

    rfunc = rfunc[:pm.start()] + replacement + rfunc[pm.end():]

    master_re = re.compile(
        r'(?P<indent>^[ \t]*)mViewer->getCamera\(\)->setProjectionMatrix\(unreversedProjectionMatrix\);',
        flags=re.MULTILINE,
    )
    mm = master_re.search(rfunc)
    if not mm:
        raise RuntimeError(
            "renderingmanager.cpp: master setProjectionMatrix anchor missing"
        )

    mind = mm.group("indent")
    near_block = r'''

__IND__if (tspPartition)
__IND__{
__IND__    osg::Camera* masterCamera = mViewer->getCamera();
__IND__
__IND__    if (!sTspNearDepthCamera)
__IND__    {
__IND__        sTspNearDepthCamera = new osg::Camera;
__IND__        sTspNearDepthCamera->setName("TSP V14 near depth partition");
__IND__        sTspNearDepthCamera->setGraphicsContext(masterCamera->getGraphicsContext());
__IND__        sTspNearDepthCamera->setViewport(masterCamera->getViewport());
__IND__        sTspNearDepthCamera->setRenderTargetImplementation(masterCamera->getRenderTargetImplementation());
__IND__        sTspNearDepthCamera->setDrawBuffer(masterCamera->getDrawBuffer());
__IND__        sTspNearDepthCamera->setReadBuffer(masterCamera->getReadBuffer());
__IND__        sTspNearDepthCamera->setClearMask(GL_DEPTH_BUFFER_BIT);
__IND__        sTspNearDepthCamera->setClearDepth(1.0);
__IND__        sTspNearDepthCamera->setComputeNearFarMode(
__IND__            osg::CullSettings::DO_NOT_COMPUTE_NEAR_FAR);
__IND__        sTspNearDepthCamera->setCullMask(masterCamera->getCullMask());
__IND__        sTspNearDepthCamera->setAllowEventFocus(false);
__IND__        sTspNearDepthCamera->setRenderOrder(osg::Camera::POST_RENDER, 10);
__IND__
__IND__        mViewer->addSlave(
__IND__            sTspNearDepthCamera.get(), osg::Matrixd(), osg::Matrixd(), true);
__IND__
__IND__        Log(Debug::Info)
__IND__            << "TSP_DEPTH_PARTITION_051_V14 near_camera_created=1";
__IND__    }
__IND__
__IND__    sTspNearDepthCamera->setGraphicsContext(masterCamera->getGraphicsContext());
__IND__    sTspNearDepthCamera->setViewport(masterCamera->getViewport());
__IND__    sTspNearDepthCamera->setCullMask(masterCamera->getCullMask());
__IND__
__IND__    const osg::Matrixd tspNearProjection
__IND__        = osg::Matrixd::perspective(fov, aspect, mNearClip, tspNearPassFar);
__IND__    osg::Matrixd tspInverseFar;
__IND__    if (!tspInverseFar.invert(osg::Matrixd(unreversedProjectionMatrix)))
__IND__        Log(Debug::Warning)
__IND__            << "TSP_DEPTH_PARTITION_051_V14 inverse_far_projection_failed=1";
__IND__    else if (osgViewer::View::Slave* tspSlave
__IND__        = mViewer->findSlaveForCamera(sTspNearDepthCamera.get()))
__IND__    {
__IND__        tspSlave->_projectionOffset = tspInverseFar * tspNearProjection;
__IND__        tspSlave->_viewOffset.makeIdentity();
__IND__        tspSlave->_useMastersSceneData = true;
__IND__    }
__IND__}
__IND__else if (sTspNearDepthCamera)
__IND__{
__IND__    bool tspRemovedNearSlave = false;
__IND__    for (unsigned int tspSlaveIndex = 0;
__IND__         tspSlaveIndex < mViewer->getNumSlaves();
__IND__         ++tspSlaveIndex)
__IND__    {
__IND__        if (mViewer->getSlave(tspSlaveIndex)._camera.get()
__IND__            == sTspNearDepthCamera.get())
__IND__        {
__IND__            mViewer->removeSlave(tspSlaveIndex);
__IND__            tspRemovedNearSlave = true;
__IND__            break;
__IND__        }
__IND__    }
__IND__
__IND__    Log(Debug::Info)
__IND__        << "TSP_DEPTH_PARTITION_051_V14 near_camera_removed="
__IND__        << (tspRemovedNearSlave ? 1 : 0);
__IND__
__IND__    sTspNearDepthCamera = nullptr;
__IND__}
'''.replace("__IND__", mind)

    rfunc = rfunc[:mm.end()] + near_block + rfunc[mm.end():]
    render = render[:rstart] + rfunc + render[rend:]


# 4) Keep far-pass shader near/far consistent where the renderer exposes it.
if "TSP_DEPTH_PARTITION_051_V14_NEARFAR" not in render:
    nearfar_re = re.compile(
        r'(?P<indent>^[ \t]*)(?P<prefix>[^;\n]*setNearFar\()\s*mNearClip\s*,\s*mViewDistance\s*\)\s*;',
        flags=re.MULTILINE,
    )
    nm = nearfar_re.search(render)
    if nm:
        ind = nm.group("indent")
        replacement = (
            ind + "// TSP_DEPTH_PARTITION_051_V14_NEARFAR\n"
            + ind + nm.group("prefix").lstrip()
            + "tspWorldNearClip(mNearClip, mViewDistance), mViewDistance);"
        )
        render = render[:nm.start()] + replacement + render[nm.end():]


for required in (
    "TSP_DEPTH_PARTITION_051_V14",
    "TSP_DEPTH_PARTITION_051_V14_ACTIVE",
    "OPENMW_TSP_DEPTH_PARTITION",
    "OPENMW_TSP_WORLD_NEAR",
    "OPENMW_TSP_NEAR_PASS_FAR",
    "near_camera_created=1",
    "TSP_WARM_ASYNC_GUARD_051_V14",
    "OPENMW_TSP_INCREMENTAL_COMPILE",
):
    if required not in render:
        raise RuntimeError(
            f"renderingmanager.cpp: V14 verification string missing: {required}"
        )

for required in (
    "TSP_SAFE_RELOAD_CONFIG_051_V13",
    "TSP_SAFE_RELOAD_051_V13 action=warm",
    "TSP_LOAD_TRACE_051_V13",
    "TSP_LOAD_WATCH_051_V13",
):
    if required not in state:
        raise RuntimeError(
            f"statemanagerimp.cpp: V13 safe-reload marker lost: {required}"
        )

write_lf(render_path, render)
write_lf(state_path, state)

print("V14 source revision applied.")
print("  graphics: two-pass depth partition, defaults far-near=70 / near-far=110")
print("  stability: OSG incremental compile disabled by default")
print("  loading: V13 warm/default + safe-reload toggle preserved")
PY_PATCH

echo
echo "===== SOURCE VERIFICATION ====="
echo "V14 depth partition:"
grep -n -m 24 \
    -e 'TSP_DEPTH_PARTITION_051_V14' \
    -e 'OPENMW_TSP_DEPTH_PARTITION' \
    -e 'OPENMW_TSP_WORLD_NEAR' \
    -e 'OPENMW_TSP_NEAR_PASS_FAR' \
    "$RENDER_CPP"

echo
echo "V14 warm async guard:"
grep -n -m 12 \
    -e 'TSP_WARM_ASYNC_GUARD_051_V14' \
    -e 'OPENMW_TSP_INCREMENTAL_COMPILE' \
    "$RENDER_CPP"

echo
echo "V13 safe reload retained:"
grep -n -m 12 \
    -e 'TSP_SAFE_RELOAD_CONFIG_051_V13' \
    -e 'TSP_SAFE_RELOAD_051_V13' \
    "$STATE_CPP"

echo
echo "V13 depth diagnostics retained:"
grep -n -m 12 \
    -e 'TSP_DEPTH_REQUEST_051_V13' \
    -e 'TSP_DEPTH_DIAG_051_V13' \
    "$ENGINE_CPP" || true
grep -n -m 6 \
    -e 'TSP_DEPTH_PROJECTION_051_V13' \
    "$RENDER_CPP"

if [ "$PATCH_ONLY" = "1" ]; then
    trap - ERR
    echo
    echo "PATCH_ONLY=1: V14 source patch/verification completed."
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
    cp -f "$PACKAGE_BINARY" "$PACKAGE_BINARY.before-v14-$STAMP"
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
    'TSP_DEPTH_PARTITION_051_V14' \
    'TSP_WARM_ASYNC_GUARD_051_V14' \
    'OPENMW_TSP_DEPTH_PARTITION' \
    'OPENMW_TSP_WORLD_NEAR' \
    'OPENMW_TSP_NEAR_PASS_FAR' \
    'OPENMW_TSP_INCREMENTAL_COMPILE' \
    'TSP_SAFE_RELOAD_CONFIG_051_V13' \
    'TSP_LOAD_TRACE_051_V13' \
    'TSP_LOAD_WATCH_051_V13' \
    'TSP_DEPTH_DIAG_051_V13'
do
    if ! strings "$PACKAGE_BINARY" | grep -F "$marker" >/dev/null; then
        echo "ERROR: required runtime marker missing from rebuilt binary: $marker"
        exit 1
    fi
done

echo "  PASS: V14 runtime markers present."
echo "  PASS: corrected V13 safe-reload/load-watch markers retained."

echo
echo "SafeNav marker (expected):"
strings "$PACKAGE_BINARY" | grep -F -m 3 'TSP SafeNav' || \
    echo "WARNING: SafeNav marker string not found; inspect before enabling navigator."

trap - ERR

echo
echo "============================================================"
echo "SUCCESS: OpenMW 0.51 V14 build complete"
echo "============================================================"
echo "Package binary:"
echo "  $PACKAGE_BINARY"
echo "Container backup copy:"
echo "  $OUTPUT_BINARY"
echo "Source backup:"
echo "  $BACKUP_DIR"
echo
echo "Default V14 behavior:"
echo "  [TSP] safe reload = 0       -> warm in-process loads; NO ESM reparse"
echo "  depth partition             -> ON"
echo "  far/master near             -> 70"
echo "  near overlay far            -> 110"
echo "  incremental compile         -> OFF"
echo
echo "Runtime switches (no rebuild):"
echo "  OPENMW_TSP_DEPTH_PARTITION=0|1"
echo "  OPENMW_TSP_WORLD_NEAR=70"
echo "  OPENMW_TSP_NEAR_PASS_FAR=110"
echo "  OPENMW_TSP_INCREMENTAL_COMPILE=0|1"
echo
echo "Existing safe reload setting remains:"
echo "  [TSP]"
echo "  safe reload = 0"
echo "or"
echo "  safe reload = 1"
echo "============================================================"
