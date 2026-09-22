#!/bin/bash
set -Eeuo pipefail

SOURCE_DIR="${1:-/root/openmw-0.51-tsp-src}"
BUILD_DIR="${2:-/root/openmw-0.51-tsp-build}"
PACKAGE_DIR="${3:-/root/openmw-0.51-tsp-package}"
OUTPUT_BINARY="${4:-/root/openmw-0.51-tsp-v17-adaptive-depth-fps}"
JOBS="${OPENMW_JOBS:-1}"
PATCH_ONLY="${OPENMW_PATCH_ONLY:-0}"

STATE_CPP="$SOURCE_DIR/apps/openmw/mwstate/statemanagerimp.cpp"
RENDER_CPP="$SOURCE_DIR/apps/openmw/mwrender/renderingmanager.cpp"
STATEUP_CPP="$SOURCE_DIR/components/sceneutil/stateupdater.cpp"
ENGINE_CPP="$SOURCE_DIR/apps/openmw/engine.cpp"
WORLD_CPP="$SOURCE_DIR/apps/openmw/mwworld/worldimp.cpp"
CMAKE_FILE="$SOURCE_DIR/CMakeLists.txt"

BUILT_BINARY="$BUILD_DIR/openmw"
PACKAGE_BINARY="$PACKAGE_DIR/bin/openmw-0.51"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$SOURCE_DIR/.tsp-051-source-backups/v17-adaptive-depth-fps-$STAMP"

restore_on_error() {
    rc=$?
    if [ "$rc" -ne 0 ] && [ -d "$BACKUP_DIR" ]; then
        echo
        echo "ERROR: V17 patch/build failed."
        echo "Restoring the source files changed by this attempt..."

        [ -f "$BACKUP_DIR/apps/openmw/mwrender/renderingmanager.cpp" ] && \
            cp -f "$BACKUP_DIR/apps/openmw/mwrender/renderingmanager.cpp" "$RENDER_CPP"

        [ -f "$BACKUP_DIR/components/sceneutil/stateupdater.cpp" ] && \
            cp -f "$BACKUP_DIR/components/sceneutil/stateupdater.cpp" "$STATEUP_CPP"

        [ -f "$BACKUP_DIR/apps/openmw/engine.cpp" ] && \
            cp -f "$BACKUP_DIR/apps/openmw/engine.cpp" "$ENGINE_CPP"

        echo "Source restoration complete."
        echo "Failed-attempt backup retained at:"
        echo "  $BACKUP_DIR"
    fi
    exit "$rc"
}
trap restore_on_error ERR

echo "============================================================"
echo "OpenMW 0.51 TSP V17"
echo "ADAPTIVE DEPTH + FPS OVERLAY"
echo "============================================================"
echo "Source:        $SOURCE_DIR"
echo "Build:         $BUILD_DIR"
echo "Package:       $PACKAGE_DIR"
echo "Output binary: $OUTPUT_BINARY"
echo "Jobs:          $JOBS"
echo "Patch only:    $PATCH_ONLY"
echo "Backup:        $BACKUP_DIR"
echo "============================================================"

for required in \
    "$STATE_CPP" \
    "$RENDER_CPP" \
    "$STATEUP_CPP" \
    "$ENGINE_CPP" \
    "$WORLD_CPP" \
    "$CMAKE_FILE"
do
    if [ ! -f "$required" ]; then
        echo "ERROR: required source file is missing:"
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

echo
echo "===== STABLE-BASELINE VERIFICATION ====="

for marker in \
    'TSP_FRESH_DEFAULT_051_V15' \
    'TSP_FRESH_PROCESS_LOAD_051_V12' \
    'TSP_SAFE_RELOAD_CONFIG_051_V13' \
    'TSP_LOAD_TRACE_051_V13' \
    'TSP_LOAD_WATCH_051_V13'
do
    if ! grep -Fq "$marker" "$STATE_CPP"; then
        echo "ERROR: stable fresh-reload marker missing:"
        echo "  $marker"
        echo "V17 refuses to build on a source tree that is not the successful V15 baseline."
        exit 1
    fi
done

python3 - "$STATE_CPP" <<'PY_FRESH_CHECK'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
m = re.search(
    r'//\s*TSP_FRESH_DEFAULT_051_V15\s*\n\s*bool\s+enabled\s*=\s*true\s*;',
    text,
)
if not m:
    raise SystemExit(
        "ERROR: TSP_FRESH_DEFAULT_051_V15 exists but fresh-by-default is not intact."
    )
print("PASS: V15 active-save reload still defaults to fresh process.")
PY_FRESH_CHECK

for marker in \
    'TSP_DEPTH_DIAG_051_V13' \
    'TSP_DEPTH_PROJECTION_051_V13'
do
    if ! grep -Fq "$marker" "$ENGINE_CPP" "$RENDER_CPP" 2>/dev/null; then
        echo "ERROR: depth diagnostic marker missing: $marker"
        exit 1
    fi
done

if ! grep -Fq 'TSP_WARM_LIFETIME_RESET_051_V13' "$WORLD_CPP"; then
    echo "ERROR: corrected V13 world-lifetime marker is missing."
    exit 1
fi

if ! grep -Fq 'TSP_ADAPTIVE_DEPTH_051_V17' "$RENDER_CPP"; then
    for marker in \
        'TSP_VISIBILITY_FIRST_051_V15' \
        'TSP_DEPTH_PARTITION_051_V14' \
        'TSP_WARM_ASYNC_GUARD_051_V14'
    do
        if ! grep -Fq "$marker" "$RENDER_CPP"; then
            echo "ERROR: expected V15/V14 renderer baseline marker missing:"
            echo "  $marker"
            echo "Nothing was changed."
            exit 1
        fi
    done

    if grep -Fq 'TSP_DEPTH_PARTITION_051_V15' "$RENDER_CPP" \
        || grep -Fq 'TSP_DEPTH_PARTITION_UNIFORM_051_V15' "$STATEUP_CPP"
    then
        echo "ERROR: an older experimental OSG depth-partition patch is present."
        echo "V17 will not stack on that experimental tree."
        echo "Restore/rebuild the successful V15 visibility/fresh-guard baseline first."
        exit 1
    fi
fi

if grep -RqiE \
    'TSP_TRANSITION_MEMORY_PURGE_051|TSP_UNREFERENCED_CACHE_PURGE_051|TSP MEMPURGE|tspPurgeTransitionMemory|clearUnreferencedCache' \
    "$SOURCE_DIR/apps/openmw/mwworld/scene.cpp" \
    "$SOURCE_DIR/components/resource" 2>/dev/null
then
    echo "ERROR: old transition-memory-purge experiment was found."
    echo "V17 refuses to layer on that source tree."
    exit 1
fi

if [ "$PATCH_ONLY" != "1" ]; then
    if [ ! -f "$BUILD_DIR/build.ninja" ] || [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
        echo "ERROR: configured Ninja build tree is missing."
        echo "This script intentionally does NOT rerun CMake."
        exit 1
    fi
fi

mkdir -p \
    "$BACKUP_DIR/apps/openmw/mwrender" \
    "$BACKUP_DIR/apps/openmw/mwstate" \
    "$BACKUP_DIR/apps/openmw" \
    "$BACKUP_DIR/components/sceneutil" \
    "$PACKAGE_DIR/bin"

cp -f "$RENDER_CPP" "$BACKUP_DIR/apps/openmw/mwrender/renderingmanager.cpp"
cp -f "$STATEUP_CPP" "$BACKUP_DIR/components/sceneutil/stateupdater.cpp"
cp -f "$ENGINE_CPP" "$BACKUP_DIR/apps/openmw/engine.cpp"
cp -f "$STATE_CPP" "$BACKUP_DIR/apps/openmw/mwstate/statemanagerimp.cpp"

STATE_SHA_BEFORE="$(sha256sum "$STATE_CPP" | awk '{print $1}')"

echo
echo "Protected state-manager SHA256:"
echo "  $STATE_SHA_BEFORE"

echo
echo "Applying V17 adaptive-depth + FPS source revision..."

python3 - "$RENDER_CPP" "$STATEUP_CPP" "$ENGINE_CPP" <<'PY_PATCH'
from pathlib import Path
import re
import sys

render_path, stateup_path, engine_path = map(Path, sys.argv[1:])

render = render_path.read_text(encoding="utf-8")
stateup = stateup_path.read_text(encoding="utf-8")
engine = engine_path.read_text(encoding="utf-8")

DEPTH_MARK = "TSP_ADAPTIVE_DEPTH_051_V17"
SETUP_MARK = "TSP_ADAPTIVE_DEPTH_SETUP_051_V17"
UNIFORM_MARK = "TSP_ADAPTIVE_DEPTH_UNIFORM_051_V17"
FPS_MARK = "TSP_FPS_OVERLAY_051_V17"


def write_lf(path: Path, text: str) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)


def ensure_include(text: str, include_line: str) -> str:
    if include_line in text:
        return text
    first = re.search(r"^#include[^\n]*\n", text, flags=re.MULTILINE)
    if not first:
        raise RuntimeError(f"include insertion anchor missing for {include_line}")
    return text[:first.end()] + include_line + "\n" + text[first.end():]


def find_function(text: str, signature_pattern: str, label: str):
    matches = list(re.finditer(signature_pattern, text, flags=re.MULTILINE))
    if len(matches) != 1:
        raise RuntimeError(f"{label}: expected one signature, found {len(matches)}")

    start = matches[0].start()
    opening = text.find("{", matches[0].end())
    if opening < 0:
        raise RuntimeError(f"{label}: opening brace not found")

    depth = 0
    i = opening
    in_string = False
    in_char = False
    in_line_comment = False
    in_block_comment = False
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


# =====================================================================
# 1. RENDERING: replace V14's custom slave with native OSG depth bands.
# =====================================================================
render = ensure_include(render, "#include <algorithm>")
render = ensure_include(render, "#include <cmath>")
render = ensure_include(render, "#include <cstdlib>")
render = ensure_include(render, "#include <cstring>")
render = ensure_include(render, "#include <osgViewer/View>")

if DEPTH_MARK not in render:
    old_marker_pos = render.find("// TSP_DEPTH_PARTITION_051_V14")
    if old_marker_pos < 0:
        raise RuntimeError("renderingmanager.cpp: V14 depth helper marker not found")

    inc_start, inc_end = find_function(
        render,
        r"^[ \t]*bool[ \t]+tspIncrementalCompileEnabled[ \t]*\(\)",
        "V14 tspIncrementalCompileEnabled",
    )

    if not (old_marker_pos < inc_start < inc_end):
        raise RuntimeError("renderingmanager.cpp: malformed V14 helper block")

    helper_start = render.rfind("\n", 0, old_marker_pos) + 1

    new_helper = r'''
    // TSP_ADAPTIVE_DEPTH_051_V17
    // OSG-native two-band depth partition for the TSP's conventional 24-bit
    // depth buffer. The split is geometric by default:
    //
    //     zMid = sqrt(zNear * zFar)
    //
    // This approximately equalizes the far/near ratio in the two partitions.
    static osg::ref_ptr<osgViewer::DepthPartitionSettings> sTspV17DepthSettings;
    static osg::ref_ptr<osg::Camera> sTspV17FarCamera;
    static osg::ref_ptr<osg::Camera> sTspV17NearCamera;
    static bool sTspV17DepthActive = false;

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

    bool tspV17AdaptiveDepthEnabled()
    {
        return tspEnvBool("OPENMW_TSP_ADAPTIVE_DEPTH", true);
    }

    float tspV17AdaptiveSplit(float nearClip, float farClip)
    {
        const float minSplit = nearClip + 1.f;
        const float maxSplit = farClip - 1.f;

        const float manual = tspEnvFloat("OPENMW_TSP_DEPTH_SPLIT", -1.f);
        if (manual > minSplit && manual < maxSplit)
            return manual;

        const double product
            = static_cast<double>(std::max(nearClip, 0.5f))
            * static_cast<double>(std::max(farClip, nearClip + 2.f));

        float split = static_cast<float>(std::sqrt(product));
        split = std::max(split, minSplit);
        split = std::min(split, maxSplit);
        return split;
    }

    void tspV17UpdateDepthRanges(float nearClip, float farClip)
    {
        if (!sTspV17DepthSettings)
            return;

        sTspV17DepthSettings->_zNear = std::max(nearClip, 0.5f);
        sTspV17DepthSettings->_zMid
            = tspV17AdaptiveSplit(sTspV17DepthSettings->_zNear, farClip);
        sTspV17DepthSettings->_zFar = farClip;
    }

    bool tspIncrementalCompileEnabled()
    {
        // Preserve the V14 handheld-safe default: incremental compile OFF.
        return tspEnvBool("OPENMW_TSP_INCREMENTAL_COMPILE", false);
    }
'''

    render = render[:helper_start] + new_helper + render[inc_end:]

    rstart, rend = find_function(
        render,
        r"^[ \t]*void[ \t]+RenderingManager::updateProjectionMatrix[ \t]*\(\)",
        "RenderingManager::updateProjectionMatrix",
    )

    new_projection = r'''    void RenderingManager::updateProjectionMatrix()
    {
        if (mNearClip < 0.0f)
            throw std::runtime_error("Near clip is less than zero");
        if (mViewDistance < mNearClip)
            throw std::runtime_error("Viewing distance is less than near clip");

        const int width = Settings::video().mResolutionX;
        const int height = Settings::video().mResolutionY;
        const double aspect = (height == 0) ? 1.0 : static_cast<double>(width) / height;
        const float fov = mFieldOfViewOverridden ? mFieldOfViewOverride : mFieldOfView;

        Log(Debug::Info) << "TSP_DEPTH_PROJECTION_051_V13"
                         << " near=" << mNearClip
                         << " far=" << mViewDistance
                         << " far_near_ratio="
                         << (mNearClip > 0.f ? mViewDistance / mNearClip : 0.f)
                         << " fov=" << fov
                         << " reversed=" << (SceneUtil::AutoDepth::isReversed() ? 1 : 0);

        if (sTspV17DepthActive && sTspV17DepthSettings)
        {
            tspV17UpdateDepthRanges(mNearClip, mViewDistance);

            const float nearRatio
                = sTspV17DepthSettings->_zMid / sTspV17DepthSettings->_zNear;
            const float farRatio
                = sTspV17DepthSettings->_zFar / sTspV17DepthSettings->_zMid;

            Log(Debug::Info) << "TSP_ADAPTIVE_DEPTH_051_V17"
                             << " update=1"
                             << " near=" << sTspV17DepthSettings->_zNear
                             << " split=" << sTspV17DepthSettings->_zMid
                             << " far=" << sTspV17DepthSettings->_zFar
                             << " near_ratio=" << nearRatio
                             << " far_ratio=" << farRatio;
        }

        osg::Matrix unreversedProjectionMatrix
            = osg::Matrix::perspective(fov, aspect, mNearClip, mViewDistance);

        osg::Matrix projectionMatrix = SceneUtil::AutoDepth::isReversed()
            ? SceneUtil::getReversedZProjectionMatrixAsPerspective(
                fov, aspect, mNearClip, mViewDistance)
            : unreversedProjectionMatrix;

        if (width != 0 && height != 0)
        {
            const double offsetX = (mProjectionOffset.x() / width) * 2.0;
            const double offsetY = (mProjectionOffset.y() / height) * 2.0;
            const osg::Matrix translation = osg::Matrix::translate(offsetX, offsetY, 0.0);
            projectionMatrix.postMult(translation);
            unreversedProjectionMatrix.postMult(translation);
        }

        mViewer->getCamera()->setProjectionMatrix(unreversedProjectionMatrix);
        mPerViewUniformStateUpdater->setProjectionMatrix(projectionMatrix);

        mSharedUniformStateUpdater->setNear(mNearClip);
        mSharedUniformStateUpdater->setFar(mViewDistance);

        if (Stereo::getStereo())
        {
            const auto res = Stereo::Manager::instance().eyeResolution();
            setScreenRes(res.x(), res.y());
            Stereo::Manager::instance().setMasterProjectionMatrix(
                mPerViewUniformStateUpdater->getProjectionMatrix());
        }
        else
            setScreenRes(width, height);

        const float distanceMult
            = std::cos(osg::DegreesToRadians(std::min(fov, 140.f)) / 2.f);

        mTerrain->setViewDistance(
            mViewDistance * (distanceMult ? 1.f / distanceMult : 1.f));

        if (mPostProcessor)
        {
            mPostProcessor->getStateUpdater()->setProjectionMatrix(
                mPerViewUniformStateUpdater->getProjectionMatrix());
            mPostProcessor->getStateUpdater()->setFov(fov);
        }
    }'''

    render = render[:rstart] + new_projection + render[rend:]

    if "TSP_DEPTH_PARTITION_051_V14_NEARFAR" in render:
        nearfar_re = re.compile(
            r'(?P<indent>^[ \t]*)// TSP_DEPTH_PARTITION_051_V14_NEARFAR\n'
            r'(?P=indent)(?P<prefix>[^;\n]*setNearFar\()'
            r'tspWorldNearClip\(mNearClip,\s*mViewDistance\),\s*mViewDistance\);',
            flags=re.MULTILINE,
        )
        nm = nearfar_re.search(render)
        if not nm:
            raise RuntimeError(
                "renderingmanager.cpp: V14 shared near/far marker exists "
                "but the block was not recognized"
            )

        render = (
            render[:nm.start()]
            + nm.group("indent")
            + nm.group("prefix")
            + "mNearClip, mViewDistance);"
            + render[nm.end():]
        )

    if SETUP_MARK not in render:
        anchor = (
            "        mViewer->getCamera()->setClearMask("
            "GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);\n"
        )
        pos = render.find(anchor)
        if pos < 0:
            raise RuntimeError(
                "renderingmanager.cpp: master clear-mask constructor anchor missing"
            )
        pos += len(anchor)

        setup = r'''
        // TSP_ADAPTIVE_DEPTH_SETUP_051_V17
        if (tspV17AdaptiveDepthEnabled() && !reverseZ)
        {
            osg::Camera* master = mViewer->getCamera();
            const unsigned int oldSlaveCount = mViewer->getNumSlaves();

            const auto masterCullMask = master->getCullMask();
            const auto masterCullingMode = master->getCullingMode();
            const GLbitfield masterClearMask = master->getClearMask();
            const osg::Vec4 masterClearColor = master->getClearColor();
            const double masterClearDepth = master->getClearDepth();
            const int masterClearStencil = master->getClearStencil();

            sTspV17DepthSettings = new osgViewer::DepthPartitionSettings(
                osgViewer::DepthPartitionSettings::FIXED_RANGE);
            tspV17UpdateDepthRanges(mNearClip, mViewDistance);

            const bool partitionOk
                = mViewer->setUpDepthPartitionForCamera(
                    master, sTspV17DepthSettings.get());

            if (partitionOk && mViewer->getNumSlaves() >= oldSlaveCount + 2)
            {
                osg::Camera* farCamera
                    = mViewer->getSlave(oldSlaveCount)._camera.get();
                osg::Camera* nearCamera
                    = mViewer->getSlave(oldSlaveCount + 1)._camera.get();

                if (farCamera != nullptr && nearCamera != nullptr)
                {
                    farCamera->setCullMask(masterCullMask);
                    nearCamera->setCullMask(masterCullMask);

                    farCamera->setCullingMode(masterCullingMode);
                    nearCamera->setCullingMode(masterCullingMode);

                    farCamera->setClearColor(masterClearColor);
                    nearCamera->setClearColor(masterClearColor);

                    farCamera->setClearDepth(masterClearDepth);
                    nearCamera->setClearDepth(masterClearDepth);

                    farCamera->setClearStencil(masterClearStencil);
                    nearCamera->setClearStencil(masterClearStencil);

                    // The master camera loses its GraphicsContext when OSG
                    // partitions it. Keep the NEAR camera eligible for pointer
                    // intersection tests so normal object activation still works.
                    farCamera->setAllowEventFocus(false);
                    nearCamera->setAllowEventFocus(true);

                    farCamera->setName("TSP V17 adaptive far depth band");
                    nearCamera->setName("TSP V17 adaptive near depth band");

                    sTspV17FarCamera = farCamera;
                    sTspV17NearCamera = nearCamera;

                    farCamera->setClearMask(masterClearMask);
                    nearCamera->setClearMask(GL_DEPTH_BUFFER_BIT);

                    farCamera->setInitialDrawCallback(
                        master->getInitialDrawCallback());
                    farCamera->setPreDrawCallback(
                        master->getPreDrawCallback());
                    nearCamera->setPostDrawCallback(
                        master->getPostDrawCallback());
                    nearCamera->setFinalDrawCallback(
                        master->getFinalDrawCallback());

                    sTspV17DepthActive = true;

                    Log(Debug::Info)
                        << "TSP_ADAPTIVE_DEPTH_051_V17"
                        << " enabled=1"
                        << " implementation=osg-native"
                        << " mode=geometric"
                        << " near=" << sTspV17DepthSettings->_zNear
                        << " split=" << sTspV17DepthSettings->_zMid
                        << " far=" << sTspV17DepthSettings->_zFar
                        << " slaves=" << mViewer->getNumSlaves();
                }
            }

            if (!sTspV17DepthActive)
            {
                Log(Debug::Warning)
                    << "TSP_ADAPTIVE_DEPTH_051_V17"
                    << " enabled=0 reason=osg-setup-failed";
            }
        }
        else
        {
            Log(Debug::Info)
                << "TSP_ADAPTIVE_DEPTH_051_V17"
                << " enabled=0 reason="
                << (reverseZ ? "reverse-z-active" : "environment-disabled");
        }
'''
        render = render[:pos] + setup + render[pos:]


# OSG's native partition detaches the GraphicsContext from OpenMW's master
# camera. OpenMW still writes changing fog/background clear colors to that
# master, so mirror those writes to the actual V17 rendering cameras.
CLEAR_MARK = "TSP_ADAPTIVE_DEPTH_CLEARCOLOR_051_V17"
if CLEAR_MARK not in render:
    fstart, fend = find_function(
        render,
        r"^[ \t]*void[ \t]+RenderingManager::setFogColor[ \t]*\(const osg::Vec4f& color\)",
        "RenderingManager::setFogColor",
    )
    ffunc = render[fstart:fend]
    old_clear = "        mViewer->getCamera()->setClearColor(color);\n"
    if old_clear not in ffunc:
        raise RuntimeError("renderingmanager.cpp: setFogColor clear-color anchor missing")
    new_clear = r'''        // TSP_ADAPTIVE_DEPTH_CLEARCOLOR_051_V17
        mViewer->getCamera()->setClearColor(color);
        if (sTspV17FarCamera)
            sTspV17FarCamera->setClearColor(color);
        if (sTspV17NearCamera)
            sTspV17NearCamera->setClearColor(color);
'''
    ffunc = ffunc.replace(old_clear, new_clear, 1)
    render = render[:fstart] + ffunc + render[fend:]


# =====================================================================
# 2. SHADER PROJECTION: each cull camera must expose its own projection.
# =====================================================================
stateup = ensure_include(stateup, "#include <cstdlib>")
stateup = ensure_include(stateup, "#include <cstring>")
stateup = ensure_include(stateup, "#include <osgUtil/CullVisitor>")

if UNIFORM_MARK not in stateup:
    if "TSP_DEPTH_PARTITION_UNIFORM_051_V15" in stateup:
        raise RuntimeError(
            "stateupdater.cpp: older experimental partition-uniform patch present"
        )

    ns = re.search(r"namespace\s+SceneUtil\s*\n?\{", stateup)
    if not ns:
        raise RuntimeError("stateupdater.cpp: namespace SceneUtil anchor missing")

    helper = r'''

    // TSP_ADAPTIVE_DEPTH_UNIFORM_051_V17
    bool tspV17AdaptiveDepthUniformEnabled()
    {
        const char* value = std::getenv("OPENMW_TSP_ADAPTIVE_DEPTH");
        if (value == nullptr || *value == '\0')
            return true;

        return !(std::strcmp(value, "0") == 0
            || std::strcmp(value, "false") == 0
            || std::strcmp(value, "off") == 0
            || std::strcmp(value, "no") == 0);
    }
'''

    stateup = stateup[:ns.end()] + helper + stateup[ns.end():]

    old = (
        '        stateset->getUniform("projectionMatrix")->set(mProjectionMatrix);\n'
    )

    if old not in stateup:
        raise RuntimeError(
            "stateupdater.cpp: projectionMatrix uniform anchor missing"
        )

    new = r'''        // TSP_ADAPTIVE_DEPTH_UNIFORM_051_V17_ACTIVE
        if (tspV17AdaptiveDepthUniformEnabled()
            && !AutoDepth::isReversed()
            && nv != nullptr
            && nv->getVisitorType() == osg::NodeVisitor::CULL_VISITOR)
        {
            osgUtil::CullVisitor* cv
                = static_cast<osgUtil::CullVisitor*>(nv);

            const osg::RefMatrix* currentProjection
                = cv->getProjectionMatrix();

            if (currentProjection != nullptr)
            {
                stateset->getUniform("projectionMatrix")->set(
                    osg::Matrixf(*currentProjection));
            }
            else
            {
                stateset->getUniform("projectionMatrix")->set(
                    mProjectionMatrix);
            }
        }
        else
        {
            stateset->getUniform("projectionMatrix")->set(
                mProjectionMatrix);
        }
'''

    stateup = stateup.replace(old, new, 1)


# =====================================================================
# 3. FPS OVERLAY: automatically perform the same first toggle as F3.
# =====================================================================
engine = ensure_include(engine, "#include <cstdlib>")
engine = ensure_include(engine, "#include <cstring>")
engine = ensure_include(engine, "#include <osgGA/GUIEventAdapter>")

if FPS_MARK not in engine:
    ns = re.search(r"namespace\s*\n?\{", engine)
    if not ns:
        raise RuntimeError("engine.cpp: anonymous namespace anchor missing")

    fps_helper = r'''

    // TSP_FPS_OVERLAY_051_V17
    bool tspV17ShowFpsEnabled()
    {
        const char* value = std::getenv("OPENMW_TSP_SHOW_FPS");
        if (value == nullptr || *value == '\0')
            return true;

        return !(std::strcmp(value, "0") == 0
            || std::strcmp(value, "false") == 0
            || std::strcmp(value, "off") == 0
            || std::strcmp(value, "no") == 0);
    }
'''

    engine = engine[:ns.end()] + fps_helper + engine[ns.end():]

    anchor = "    mViewer->addEventHandler(statsHandler);\n"
    if anchor not in engine:
        raise RuntimeError(
            "engine.cpp: profiler addEventHandler anchor missing"
        )

    fps_hook = r'''
    if (tspV17ShowFpsEnabled())
    {
        mViewer->getEventQueue()->keyPress(
            osgGA::GUIEventAdapter::KEY_F3);
        mViewer->getEventQueue()->keyRelease(
            osgGA::GUIEventAdapter::KEY_F3);

        Log(Debug::Info)
            << "TSP_FPS_OVERLAY_051_V17 enabled=1 key=F3 page=fps";
    }
    else
    {
        Log(Debug::Info)
            << "TSP_FPS_OVERLAY_051_V17 enabled=0";
    }

'''

    engine = engine.replace(anchor, anchor + fps_hook, 1)


# =====================================================================
# 4. FINAL SOURCE VERIFICATION.
# =====================================================================
for required in (
    DEPTH_MARK,
    SETUP_MARK,
    "TSP_ADAPTIVE_DEPTH_CLEARCOLOR_051_V17",
    "osgViewer::DepthPartitionSettings",
    "setUpDepthPartitionForCamera",
    "std::sqrt",
    "OPENMW_TSP_ADAPTIVE_DEPTH",
    "OPENMW_TSP_DEPTH_SPLIT",
    "sTspV17FarCamera",
    "sTspV17NearCamera",
    "nearCamera->setAllowEventFocus(true)",
    "TSP_DEPTH_PROJECTION_051_V13",
    "TSP_WARM_ASYNC_GUARD_051_V14",
    "OPENMW_TSP_INCREMENTAL_COMPILE",
):
    if required not in render:
        raise RuntimeError(
            f"renderingmanager.cpp: V17 verification missing: {required}"
        )

for forbidden in (
    "TSP_DEPTH_PARTITION_051_V14_ACTIVE",
    "sTspNearDepthCamera",
    "tspWorldNearClip",
    "tspNearPassFarClip",
    "TSP_VISIBILITY_FIRST_051_V15",
):
    if forbidden in render:
        raise RuntimeError(
            f"renderingmanager.cpp: obsolete custom-partition residue: {forbidden}"
        )

for required in (
    UNIFORM_MARK,
    "currentProjection",
    "osgUtil::CullVisitor",
    "OPENMW_TSP_ADAPTIVE_DEPTH",
):
    if required not in stateup:
        raise RuntimeError(
            f"stateupdater.cpp: V17 verification missing: {required}"
        )

for required in (
    FPS_MARK,
    "OPENMW_TSP_SHOW_FPS",
    "KEY_F3",
    "keyPress",
    "keyRelease",
):
    if required not in engine:
        raise RuntimeError(
            f"engine.cpp: V17 FPS verification missing: {required}"
        )

write_lf(render_path, render)
write_lf(stateup_path, stateup)
write_lf(engine_path, engine)

print("V17 source patch applied and verified.")
print("  reload stability source: NOT TOUCHED")
print("  depth: OSG native two-band partition")
print("  split: geometric sqrt(near * far), optional manual override")
print("  V14 incremental-compile guard: retained")
print("  per-cull projection uniform: enabled")
print("  FPS overlay: automatic OpenMW F3 first page")
PY_PATCH

echo
echo "===== SOURCE VERIFICATION ====="

echo
echo "-- V17 adaptive depth --"
grep -n -m 30 \
    -e 'TSP_ADAPTIVE_DEPTH_051_V17' \
    -e 'TSP_ADAPTIVE_DEPTH_SETUP_051_V17' \
    -e 'OPENMW_TSP_ADAPTIVE_DEPTH' \
    -e 'OPENMW_TSP_DEPTH_SPLIT' \
    -e 'setUpDepthPartitionForCamera' \
    "$RENDER_CPP"

echo
echo "-- V17 per-cull projection --"
grep -n -m 20 \
    -e 'TSP_ADAPTIVE_DEPTH_UNIFORM_051_V17' \
    -e 'currentProjection' \
    "$STATEUP_CPP"

echo
echo "-- V17 FPS overlay --"
grep -n -m 20 \
    -e 'TSP_FPS_OVERLAY_051_V17' \
    -e 'OPENMW_TSP_SHOW_FPS' \
    -e 'KEY_F3' \
    "$ENGINE_CPP"

echo
echo "-- V14 incremental-compile safety guard retained --"
grep -n -m 12 \
    -e 'TSP_WARM_ASYNC_GUARD_051_V14' \
    -e 'OPENMW_TSP_INCREMENTAL_COMPILE' \
    "$RENDER_CPP"

echo
echo "-- V15 fresh reload MUST remain untouched --"
STATE_SHA_AFTER="$(sha256sum "$STATE_CPP" | awk '{print $1}')"

echo "Before: $STATE_SHA_BEFORE"
echo "After:  $STATE_SHA_AFTER"

if [ "$STATE_SHA_BEFORE" != "$STATE_SHA_AFTER" ]; then
    echo "ERROR: statemanagerimp.cpp changed unexpectedly."
    exit 1
fi

echo "PASS: statemanagerimp.cpp is byte-for-byte unchanged."

for marker in \
    'TSP_FRESH_DEFAULT_051_V15' \
    'TSP_FRESH_PROCESS_LOAD_051_V12' \
    'TSP_SAFE_RELOAD_CONFIG_051_V13' \
    'TSP_LOAD_TRACE_051_V13' \
    'TSP_LOAD_WATCH_051_V13'
do
    grep -Fq "$marker" "$STATE_CPP" || {
        echo "ERROR: protected reload marker disappeared: $marker"
        exit 1
    }
done

echo "PASS: V12/V13/V15 fresh-reload markers retained."

echo
echo "-- Transition-memory purge must remain absent --"
if grep -RniE \
    'TSP_TRANSITION_MEMORY_PURGE_051|TSP_UNREFERENCED_CACHE_PURGE_051|TSP MEMPURGE|tspPurgeTransitionMemory|clearUnreferencedCache' \
    "$SOURCE_DIR/apps/openmw/mwworld/scene.cpp" \
    "$SOURCE_DIR/components/resource" 2>/dev/null
then
    echo "ERROR: transition-memory-purge remnant found."
    exit 1
else
    echo "PASS: old transition-memory-purge experiment remains absent."
fi

if [ "$PATCH_ONLY" = "1" ]; then
    trap - ERR
    echo
    echo "PATCH_ONLY=1: V17 source patch/verification complete."
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

echo
echo "Packaging V17 binary..."

if [ -e "$OUTPUT_BINARY" ]; then
    cp -f "$OUTPUT_BINARY" "$OUTPUT_BINARY.before-$STAMP"
fi

if [ -e "$PACKAGE_BINARY" ]; then
    cp -f "$PACKAGE_BINARY" "$PACKAGE_BINARY.before-v17-$STAMP"
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
    'TSP_ADAPTIVE_DEPTH_051_V17' \
    'TSP_ADAPTIVE_DEPTH_SETUP_051_V17' \
    'TSP_ADAPTIVE_DEPTH_UNIFORM_051_V17' \
    'TSP_FPS_OVERLAY_051_V17' \
    'OPENMW_TSP_ADAPTIVE_DEPTH' \
    'OPENMW_TSP_DEPTH_SPLIT' \
    'OPENMW_TSP_SHOW_FPS' \
    'TSP_FRESH_DEFAULT_051_V15' \
    'TSP_FRESH_PROCESS_LOAD_051_V12' \
    'TSP_SAFE_RELOAD_CONFIG_051_V13' \
    'TSP_LOAD_TRACE_051_V13' \
    'TSP_LOAD_WATCH_051_V13' \
    'TSP_DEPTH_DIAG_051_V13' \
    'TSP_WARM_ASYNC_GUARD_051_V14'
do
    if ! strings "$PACKAGE_BINARY" | grep -F "$marker" >/dev/null; then
        echo "ERROR: required runtime marker missing from rebuilt binary:"
        echo "  $marker"
        exit 1
    fi
done

if strings "$PACKAGE_BINARY" | grep -F \
    'TSP_DEPTH_PARTITION_051_V14 near_camera_created=1' >/dev/null
then
    echo "ERROR: obsolete V14 custom near-camera runtime string remains."
    exit 1
fi

if strings "$PACKAGE_BINARY" | grep -E \
    'TSP MEMPURGE|TSP_TRANSITION_MEMORY_PURGE_051|TSP_UNREFERENCED_CACHE_PURGE_051' \
    >/dev/null
then
    echo "ERROR: obsolete transition-memory-purge marker in binary."
    exit 1
fi

echo "PASS: V17 adaptive-depth markers present."
echo "PASS: automatic FPS-overlay marker present."
echo "PASS: successful V15 fresh-reload markers retained."
echo "PASS: obsolete V14 custom near-camera marker absent."

trap - ERR

echo
echo "============================================================"
echo "SUCCESS: OpenMW 0.51 V17 build complete"
echo "============================================================"
echo "Package binary:"
echo "  $PACKAGE_BINARY"
echo
echo "Container standalone copy:"
echo "  $OUTPUT_BINARY"
echo
echo "Source backup:"
echo "  $BACKUP_DIR"
echo
echo "Protected state-manager SHA256:"
echo "  $STATE_SHA_AFTER"
echo
echo "V17 defaults:"
echo "  V15 fresh active-save reload = UNCHANGED / ON"
echo "  adaptive depth partition     = ON"
echo "  partition near               = configured [Camera] near clip"
echo "  partition split              = sqrt(near * view distance)"
echo "  FPS overlay                  = ON (OpenMW F3 first page)"
echo "  incremental compile          = OFF (existing V14 safety default)"
echo
echo "Runtime switches:"
echo "  OPENMW_TSP_ADAPTIVE_DEPTH=0|1"
echo "  OPENMW_TSP_DEPTH_SPLIT=<distance>   # optional manual override"
echo "  OPENMW_TSP_SHOW_FPS=0|1"
echo "============================================================"
