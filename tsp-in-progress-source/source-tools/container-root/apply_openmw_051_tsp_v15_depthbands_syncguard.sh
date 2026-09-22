#!/bin/bash
set -Eeuo pipefail

SOURCE_DIR="${1:-/root/openmw-0.51-tsp-src}"
BUILD_DIR="${2:-/root/openmw-0.51-tsp-build}"
PACKAGE_DIR="${3:-/root/openmw-0.51-tsp-package}"
OUTPUT_BINARY="${4:-/root/openmw-0.51-tsp-v15-depthbands-syncguard}"
JOBS="${OPENMW_JOBS:-1}"
PATCH_ONLY="${OPENMW_PATCH_ONLY:-0}"

STATE_CPP="$SOURCE_DIR/apps/openmw/mwstate/statemanagerimp.cpp"
ENGINE_CPP="$SOURCE_DIR/apps/openmw/engine.cpp"
RENDER_CPP="$SOURCE_DIR/apps/openmw/mwrender/renderingmanager.cpp"
STATEUP_CPP="$SOURCE_DIR/components/sceneutil/stateupdater.cpp"
WORLD_CPP="$SOURCE_DIR/apps/openmw/mwworld/worldimp.cpp"
CMAKE_FILE="$SOURCE_DIR/CMakeLists.txt"
BUILT_BINARY="$BUILD_DIR/openmw"
PACKAGE_BINARY="$PACKAGE_DIR/bin/openmw-0.51"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$SOURCE_DIR/.tsp-051-source-backups/v15-depthbands-syncguard-$STAMP"

restore_on_error() {
    rc=$?
    if [ "$rc" -ne 0 ] && [ -d "$BACKUP_DIR" ]; then
        echo
        echo "ERROR: V15 patch/build failed."
        echo "Restoring source files changed by this attempt..."
        for rel in \
            apps/openmw/mwstate/statemanagerimp.cpp \
            apps/openmw/engine.cpp \
            apps/openmw/mwrender/renderingmanager.cpp \
            components/sceneutil/stateupdater.cpp
        do
            [ -f "$BACKUP_DIR/$rel" ] && cp -f "$BACKUP_DIR/$rel" "$SOURCE_DIR/$rel"
        done
        echo "Source restoration complete."
        echo "Failed-attempt backup retained at:"
        echo "  $BACKUP_DIR"
    fi
    exit "$rc"
}
trap restore_on_error ERR

echo "============================================================"
echo "OpenMW 0.51 TSP V15"
echo "OFFICIAL DEPTH BANDS + SYNC WARM GUARD + CRASH PC"
echo "============================================================"
echo "Source:        $SOURCE_DIR"
echo "Build:         $BUILD_DIR"
echo "Output binary: $OUTPUT_BINARY"
echo "Jobs:          $JOBS"
echo "Backup:        $BACKUP_DIR"
echo "============================================================"

for required in "$STATE_CPP" "$ENGINE_CPP" "$RENDER_CPP" "$STATEUP_CPP" "$WORLD_CPP" "$CMAKE_FILE"; do
    if [ ! -f "$required" ]; then
        echo "ERROR: missing required source file: $required"
        exit 1
    fi
done

VERSION_MAJOR="$(sed -n 's/^[[:space:]]*set(OPENMW_VERSION_MAJOR[[:space:]]*\([0-9][0-9]*\)).*/\1/p' "$CMAKE_FILE" | head -1)"
VERSION_MINOR="$(sed -n 's/^[[:space:]]*set(OPENMW_VERSION_MINOR[[:space:]]*\([0-9][0-9]*\)).*/\1/p' "$CMAKE_FILE" | head -1)"
if [ "$VERSION_MAJOR" != "0" ] || [ "$VERSION_MINOR" != "51" ]; then
    echo "ERROR: expected OpenMW 0.51 source; detected ${VERSION_MAJOR:-?}.${VERSION_MINOR:-?}."
    exit 1
fi

for marker in 'TSP_SAFE_RELOAD_CONFIG_051_V13' 'TSP_LOAD_TRACE_051_V13' 'TSP_LOAD_WATCH_051_V13'; do
    grep -Fq "$marker" "$STATE_CPP" || { echo "ERROR: corrected V13 marker missing: $marker"; exit 1; }
done
grep -Fq 'TSP_WARM_LIFETIME_RESET_051_V13' "$WORLD_CPP" || { echo "ERROR: V13 world lifetime marker missing."; exit 1; }
grep -Fq 'TSP_DEPTH_DIAG_051_V13' "$ENGINE_CPP" || { echo "ERROR: V13 depth diagnostic missing."; exit 1; }
grep -Fq 'TSP_PLAYER_ANIMATION_SWAP_051_V13' "$RENDER_CPP" || { echo "ERROR: V13 player animation marker missing."; exit 1; }

if [ "$PATCH_ONLY" != "1" ] && { [ ! -f "$BUILD_DIR/build.ninja" ] || [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; }; then
    echo "ERROR: configured Ninja build tree is missing. This script does not rerun CMake."
    exit 1
fi

mkdir -p \
    "$BACKUP_DIR/apps/openmw/mwstate" \
    "$BACKUP_DIR/apps/openmw/mwrender" \
    "$BACKUP_DIR/apps/openmw" \
    "$BACKUP_DIR/components/sceneutil" \
    "$PACKAGE_DIR/bin"

cp -f "$STATE_CPP" "$BACKUP_DIR/apps/openmw/mwstate/statemanagerimp.cpp"
cp -f "$ENGINE_CPP" "$BACKUP_DIR/apps/openmw/engine.cpp"
cp -f "$RENDER_CPP" "$BACKUP_DIR/apps/openmw/mwrender/renderingmanager.cpp"
cp -f "$STATEUP_CPP" "$BACKUP_DIR/components/sceneutil/stateupdater.cpp"

echo
echo "Applying V15 source revision..."

python3 - "$STATE_CPP" "$ENGINE_CPP" "$RENDER_CPP" "$STATEUP_CPP" <<'PY_PATCH'
from pathlib import Path
import re
import sys

state_path, engine_path, render_path, stateup_path = map(Path, sys.argv[1:])
state = state_path.read_text(encoding="utf-8")
engine = engine_path.read_text(encoding="utf-8")
render = render_path.read_text(encoding="utf-8")
stateup = stateup_path.read_text(encoding="utf-8")

V15_DEPTH = "TSP_DEPTH_PARTITION_051_V15"
V15_UNIFORM = "TSP_DEPTH_PARTITION_UNIFORM_051_V15"
V15_SYNC = "TSP_SYNC_GUARD_051_V15"
V15_CRASH = "TSP_CRASH_PC_051_V15"

def write_lf(path, text):
    with path.open("w", encoding="utf-8", newline="\n") as f:
        f.write(text)

def ensure_include(text, include_line):
    if include_line in text:
        return text
    first = re.search(r'^#include[^\n]*\n', text, flags=re.MULTILINE)
    if not first:
        raise RuntimeError(f"include insertion anchor missing for {include_line}")
    return text[:first.end()] + include_line + "\n" + text[first.end():]

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

# ---------------------------------------------------------------------
# 1. Remove the V14 custom renderer and restore stock incremental compile.
# ---------------------------------------------------------------------
if "// TSP_DEPTH_PARTITION_051_V14" in render:
    marker = render.find("// TSP_DEPTH_PARTITION_051_V14")
    fstart, fend = find_function(
        render,
        r"^[ \t]*bool[ \t]+tspIncrementalCompileEnabled[ \t]*\(\)",
        "V14 tspIncrementalCompileEnabled",
    )
    if not (marker < fstart < fend):
        raise RuntimeError("renderingmanager.cpp: malformed V14 helper block")
    line_start = render.rfind("\n", 0, marker) + 1
    render = render[:line_start] + render[fend:]

if "TSP_WARM_ASYNC_GUARD_051_V14" in render:
    async_re = re.compile(
        r'(?P<indent>^[ \t]*)// TSP_WARM_ASYNC_GUARD_051_V14\n'
        r'(?P=indent)const bool tspUseIncrementalCompile = tspIncrementalCompileEnabled\(\);\n'
        r'(?P=indent)Log\(Debug::Info\) << "TSP_WARM_ASYNC_GUARD_051_V14 incremental_compile="\n'
        r'(?P=indent)[ \t]*<< \(tspUseIncrementalCompile \? 1 : 0\);\n'
        r'(?P=indent)if \(tspUseIncrementalCompile && std::getenv\("OPENMW_DONT_PRECOMPILE"\) == nullptr\)',
        flags=re.MULTILINE,
    )
    m = async_re.search(render)
    if not m:
        raise RuntimeError("renderingmanager.cpp: could not structurally remove V14 async guard")
    render = render[:m.start()] + m.group("indent") + \
        'if (getenv("OPENMW_DONT_PRECOMPILE") == nullptr)' + render[m.end():]

if "TSP_DEPTH_PARTITION_051_V14_NEARFAR" in render:
    nearfar_re = re.compile(
        r'(?P<indent>^[ \t]*)// TSP_DEPTH_PARTITION_051_V14_NEARFAR\n'
        r'(?P=indent)(?P<prefix>[^;\n]*setNearFar\()'
        r'tspWorldNearClip\(mNearClip, mViewDistance\), mViewDistance\);',
        flags=re.MULTILINE,
    )
    m = nearfar_re.search(render)
    if not m:
        raise RuntimeError("renderingmanager.cpp: V14 near/far marker exists but block was not recognized")
    render = render[:m.start()] + m.group("indent") + m.group("prefix") + \
        "mNearClip, mViewDistance);" + render[m.end():]

# ---------------------------------------------------------------------
# 2. V15 graphics: OSG's own two-band depth partition.
# ---------------------------------------------------------------------
render = ensure_include(render, "#include <algorithm>")
render = ensure_include(render, "#include <cstdlib>")
render = ensure_include(render, "#include <cstring>")
render = ensure_include(render, "#include <osgViewer/View>")

if V15_DEPTH not in render:
    ns = re.search(r'namespace\s+MWRender\s*\n?\{', render)
    if not ns:
        raise RuntimeError("renderingmanager.cpp: namespace MWRender anchor missing")

    helper = r'''

    // TSP_DEPTH_PARTITION_051_V15
    // TSP GL4ES: use two contiguous fixed-range bands with OSG's native
    // depth-partition implementation instead of V14's hand-built slave.
    static osg::ref_ptr<osgViewer::DepthPartitionSettings> sTspDepthPartitionSettings;
    static bool sTspDepthPartitionActive = false;

    bool tspV15EnvBool(const char* name, bool fallback)
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

    float tspV15EnvFloat(const char* name, float fallback)
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

    bool tspV15DepthPartitionEnabled()
    {
        return tspV15EnvBool("OPENMW_TSP_DEPTH_PARTITION", true);
    }

    float tspV15DepthNear(float configuredNear, float farClip)
    {
        float value = tspV15EnvFloat("OPENMW_TSP_DEPTH_NEAR", 5.f);
        value = std::max(value, 0.5f);
        value = std::min(value, configuredNear);
        value = std::min(value, farClip - 2.f);
        return value;
    }

    float tspV15DepthSplit(float nearClip, float farClip)
    {
        float value = tspV15EnvFloat("OPENMW_TSP_DEPTH_SPLIT", 70.f);
        value = std::max(value, nearClip + 2.f);
        value = std::min(value, farClip - 2.f);
        return value;
    }

    void tspV15UpdateDepthRanges(float configuredNear, float farClip)
    {
        if (!sTspDepthPartitionSettings)
            return;
        const float nearBand = tspV15DepthNear(configuredNear, farClip);
        const float split = tspV15DepthSplit(nearBand, farClip);
        sTspDepthPartitionSettings->_zNear = nearBand;
        sTspDepthPartitionSettings->_zMid = split;
        sTspDepthPartitionSettings->_zFar = farClip;
    }
'''
    render = render[:ns.end()] + helper + render[ns.end():]

# Replace updateProjectionMatrix wholesale. This guarantees the V14 master
# near=70 hack is gone while preserving the V13 projection diagnostic.
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

        Log(Debug::Info) << "TSP_DEPTH_PROJECTION_051_V13 near=" << mNearClip
                         << " far=" << mViewDistance
                         << " far_near_ratio="
                         << (mNearClip > 0.f ? mViewDistance / mNearClip : 0.f)
                         << " fov=" << fov
                         << " reversed=" << (SceneUtil::AutoDepth::isReversed() ? 1 : 0);

        if (sTspDepthPartitionActive && sTspDepthPartitionSettings)
        {
            tspV15UpdateDepthRanges(mNearClip, mViewDistance);
            Log(Debug::Info) << "TSP_DEPTH_PARTITION_051_V15 update=1"
                             << " near_band=" << sTspDepthPartitionSettings->_zNear
                             << " split=" << sTspDepthPartitionSettings->_zMid
                             << " far=" << sTspDepthPartitionSettings->_zFar;
        }

        osg::Matrix unreversedProjectionMatrix
            = osg::Matrix::perspective(fov, aspect, mNearClip, mViewDistance);
        osg::Matrix projectionMatrix = SceneUtil::AutoDepth::isReversed()
            ? SceneUtil::getReversedZProjectionMatrixAsPerspective(
                fov, aspect, mNearClip, mViewDistance)
            : unreversedProjectionMatrix;

        if (width != 0 && height != 0)
        {
            double offsetX = (mProjectionOffset.x() / width) * 2.0;
            double offsetY = (mProjectionOffset.y() / height) * 2.0;
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
            auto res = Stereo::Manager::instance().eyeResolution();
            setScreenRes(res.x(), res.y());
            Stereo::Manager::instance().setMasterProjectionMatrix(
                mPerViewUniformStateUpdater->getProjectionMatrix());
        }
        else
            setScreenRes(width, height);

        float distanceMult = std::cos(osg::DegreesToRadians(std::min(fov, 140.f)) / 2.f);
        mTerrain->setViewDistance(mViewDistance * (distanceMult ? 1.f / distanceMult : 1.f));
        if (mPostProcessor)
        {
            mPostProcessor->getStateUpdater()->setProjectionMatrix(
                mPerViewUniformStateUpdater->getProjectionMatrix());
            mPostProcessor->getStateUpdater()->setFov(fov);
        }
    }'''

render = render[:rstart] + new_projection + render[rend:]

if "TSP_DEPTH_PARTITION_SETUP_051_V15" not in render:
    anchor = '        mViewer->getCamera()->setClearMask(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);\n'
    pos = render.find(anchor)
    if pos < 0:
        raise RuntimeError("renderingmanager.cpp: master clear-mask constructor anchor missing")
    pos += len(anchor)

    setup = r'''

        // TSP_DEPTH_PARTITION_SETUP_051_V15
        if (tspV15DepthPartitionEnabled() && !reverseZ)
        {
            osg::Camera* master = mViewer->getCamera();
            const unsigned int oldSlaveCount = mViewer->getNumSlaves();

            const auto masterCullMask = master->getCullMask();
            const auto masterCullingMode = master->getCullingMode();
            const GLbitfield masterClearMask = master->getClearMask();
            const osg::Vec4 masterClearColor = master->getClearColor();
            const double masterClearDepth = master->getClearDepth();
            const int masterClearStencil = master->getClearStencil();

            sTspDepthPartitionSettings
                = new osgViewer::DepthPartitionSettings(osgViewer::DepthPartitionSettings::FIXED_RANGE);
            tspV15UpdateDepthRanges(mNearClip, mViewDistance);

            const bool partitionOk
                = mViewer->setUpDepthPartitionForCamera(master, sTspDepthPartitionSettings.get());

            if (partitionOk && mViewer->getNumSlaves() >= oldSlaveCount + 2)
            {
                osg::Camera* farCamera = mViewer->getSlave(oldSlaveCount)._camera.get();
                osg::Camera* nearCamera = mViewer->getSlave(oldSlaveCount + 1)._camera.get();

                if (farCamera && nearCamera)
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
                    farCamera->setAllowEventFocus(false);
                    nearCamera->setAllowEventFocus(false);

                    farCamera->setName("TSP V15 far depth band");
                    nearCamera->setName("TSP V15 near depth band");

                    // Far renders first and owns color/stencil clear. Near renders
                    // second, clearing depth only, so there is no visibility gap.
                    farCamera->setClearMask(masterClearMask);
                    nearCamera->setClearMask(GL_DEPTH_BUFFER_BIT);

                    // OSG replaces the renderable master with two slave cameras.
                    // Preserve callbacks that other OpenMW systems attached.
                    farCamera->setInitialDrawCallback(master->getInitialDrawCallback());
                    farCamera->setPreDrawCallback(master->getPreDrawCallback());
                    nearCamera->setPostDrawCallback(master->getPostDrawCallback());
                    nearCamera->setFinalDrawCallback(master->getFinalDrawCallback());

                    sTspDepthPartitionActive = true;
                    Log(Debug::Info) << "TSP_DEPTH_PARTITION_051_V15 enabled=1"
                                     << " implementation=osg-depth-partition"
                                     << " near_band=" << sTspDepthPartitionSettings->_zNear
                                     << " split=" << sTspDepthPartitionSettings->_zMid
                                     << " far=" << sTspDepthPartitionSettings->_zFar
                                     << " slaves=" << mViewer->getNumSlaves();
                }
            }

            if (!sTspDepthPartitionActive)
                Log(Debug::Warning)
                    << "TSP_DEPTH_PARTITION_051_V15 enabled=0 reason=osg-setup-failed";
        }
        else
        {
            Log(Debug::Info) << "TSP_DEPTH_PARTITION_051_V15 enabled=0"
                             << " reason="
                             << (reverseZ ? "reverse-z-active" : "environment-disabled");
        }
'''
    render = render[:pos] + setup + render[pos:]

# ---------------------------------------------------------------------
# 3. Per-view shader projection must match the active partition camera.
# ---------------------------------------------------------------------
stateup = ensure_include(stateup, "#include <cstdlib>")
stateup = ensure_include(stateup, "#include <cstring>")
stateup = ensure_include(stateup, "#include <osgUtil/CullVisitor>")

if V15_UNIFORM not in stateup:
    ns = re.search(r'namespace\s+SceneUtil\s*\n?\{', stateup)
    if not ns:
        raise RuntimeError("stateupdater.cpp: namespace SceneUtil anchor missing")
    helper = r'''

    // TSP_DEPTH_PARTITION_UNIFORM_051_V15
    bool tspV15PartitionUniformEnabled()
    {
        const char* value = std::getenv("OPENMW_TSP_DEPTH_PARTITION");
        if (value == nullptr || *value == '\0')
            return true;
        return !(std::strcmp(value, "0") == 0 || std::strcmp(value, "false") == 0
            || std::strcmp(value, "off") == 0 || std::strcmp(value, "no") == 0);
    }
'''
    stateup = stateup[:ns.end()] + helper + stateup[ns.end():]

    old = '        stateset->getUniform("projectionMatrix")->set(mProjectionMatrix);\n'
    if old not in stateup:
        raise RuntimeError("stateupdater.cpp: projectionMatrix uniform anchor missing")

    new = r'''        // TSP_DEPTH_PARTITION_UNIFORM_051_V15_ACTIVE
        if (tspV15PartitionUniformEnabled() && !AutoDepth::isReversed()
            && nv != nullptr && nv->getVisitorType() == osg::NodeVisitor::CULL_VISITOR)
        {
            osgUtil::CullVisitor* cv = static_cast<osgUtil::CullVisitor*>(nv);
            const osg::RefMatrix* currentProjection = cv->getProjectionMatrix();
            if (currentProjection != nullptr)
                stateset->getUniform("projectionMatrix")->set(osg::Matrixf(*currentProjection));
            else
                stateset->getUniform("projectionMatrix")->set(mProjectionMatrix);
        }
        else
            stateset->getUniform("projectionMatrix")->set(mProjectionMatrix);
'''
    stateup = stateup.replace(old, new, 1)

# ---------------------------------------------------------------------
# 4. V15 warm-load lifetime experiment: create Physics and Lua workers
#    synchronously without permanently changing the user's settings.cfg.
# ---------------------------------------------------------------------
if V15_SYNC not in engine:
    engine = ensure_include(engine, "#include <cstdlib>")
    engine = ensure_include(engine, "#include <cstring>")

    class_match = re.search(r"^[ \\t]*class[ \\t]+IdentifyOpenGLOperation\\b", engine, flags=re.MULTILINE)
    if not class_match:
        raise RuntimeError("engine.cpp: IdentifyOpenGLOperation anchor missing")

    helper = r'''
// TSP_SYNC_GUARD_051_V15
// Preserve the user's configured values on disk. During prepareEngine only,
// temporarily set the engine-worker settings to zero so PhysicsSystem and
// MWLua::Worker are constructed in synchronous/main-thread mode.
int gTspV15SavedPhysicsThreads = 0;
int gTspV15SavedLuaThreads = 0;
bool gTspV15SyncSettingsApplied = false;

bool tspV15EnvEnabled(const char* name)
{
    const char* value = std::getenv(name);
    if (value == nullptr || *value == '\0')
        return false;
    return !(std::strcmp(value, "0") == 0 || std::strcmp(value, "false") == 0
        || std::strcmp(value, "off") == 0 || std::strcmp(value, "no") == 0);
}

void tspV15ApplySyncSettings()
{
    auto& physicsThreads = Settings::get<int>("Physics", "async num threads");
    auto& luaThreads = Settings::get<int>("Lua", "lua num threads");

    gTspV15SavedPhysicsThreads = physicsThreads;
    gTspV15SavedLuaThreads = luaThreads;

    const bool asyncPhysics = tspV15EnvEnabled("OPENMW_TSP_ASYNC_PHYSICS");
    const bool asyncLua = tspV15EnvEnabled("OPENMW_TSP_ASYNC_LUA");

    if (!asyncPhysics)
        physicsThreads.set(0);
    if (!asyncLua)
        luaThreads.set(0);

    gTspV15SyncSettingsApplied = true;

    Log(Debug::Info) << "TSP_SYNC_GUARD_051_V15 domain=physics configured="
                     << gTspV15SavedPhysicsThreads
                     << " selected=" << static_cast<int>(physicsThreads);
    Log(Debug::Info) << "TSP_SYNC_GUARD_051_V15 domain=lua configured="
                     << gTspV15SavedLuaThreads
                     << " selected=" << static_cast<int>(luaThreads);
}

void tspV15RestoreSyncSettings()
{
    if (!gTspV15SyncSettingsApplied)
        return;

    Settings::get<int>("Physics", "async num threads").set(gTspV15SavedPhysicsThreads);
    Settings::get<int>("Lua", "lua num threads").set(gTspV15SavedLuaThreads);
    gTspV15SyncSettingsApplied = false;

    Log(Debug::Info) << "TSP_SYNC_GUARD_051_V15 settings_restored=1"
                     << " physics=" << gTspV15SavedPhysicsThreads
                     << " lua=" << gTspV15SavedLuaThreads;
}

'''
    engine = engine[:class_match.start()] + helper + engine[class_match.start():]

    pstart, pend = find_function(
        engine,
        r"^[ \\t]*void[ \\t]+OMW::Engine::prepareEngine[ \\t]*\\(\\)",
        "OMW::Engine::prepareEngine",
    )
    pfunc = engine[pstart:pend]

    if "tspV15ApplySyncSettings();" not in pfunc:
        opening = pfunc.find("{")
        if opening < 0:
            raise RuntimeError("engine.cpp: prepareEngine opening brace missing")
        pfunc = pfunc[:opening + 1] + "\n    tspV15ApplySyncSettings();" + pfunc[opening + 1:]

    worker_anchor = "    mLuaWorker = std::make_unique<MWLua::Worker>(*mLuaManager);\n"
    if worker_anchor not in pfunc:
        raise RuntimeError("engine.cpp: Lua Worker construction anchor missing")
    pfunc = pfunc.replace(
        worker_anchor,
        worker_anchor + "    tspV15RestoreSyncSettings();\n",
        1,
    )

    engine = engine[:pstart] + pfunc + engine[pend:]

# ---------------------------------------------------------------------
# 5. Real AArch64 crash PC/LR/SP tracer chained to OpenMW's crash handler.
# ---------------------------------------------------------------------
if V15_CRASH not in state:
    for inc in (
        "#include <cstdint>",
        "#include <fstream>",
        "#include <iomanip>",
        "#include <string>",
        "#include <csignal>",
        "#if defined(__linux__)\n#include <signal.h>\n#include <ucontext.h>\n#include <unistd.h>\n#endif",
    ):
        if inc not in state:
            first = re.search(r'^#include[^\n]*\n', state, flags=re.MULTILINE)
            if not first:
                raise RuntimeError("statemanagerimp.cpp: include anchor missing")
            state = state[:first.end()] + inc + "\n" + state[first.end():]

    ns = re.search(r'namespace\s+MWState\s*\n?\{', state)
    if not ns:
        raise RuntimeError("statemanagerimp.cpp: namespace MWState anchor missing")

    crash_block = r'''
namespace
{
    // TSP_CRASH_PC_051_V15
    volatile sig_atomic_t gTspCrashStage051V15 = 0;

#if defined(__linux__) && defined(__aarch64__)
    struct sigaction gTspOldSegv051V15 {};
    struct sigaction gTspOldIll051V15 {};
    struct sigaction gTspOldBus051V15 {};
    struct sigaction gTspOldAbrt051V15 {};
    bool gTspCrashTracerInstalled051V15 = false;

    uintptr_t gTspExeLoadBase051V15 = 0;
    uintptr_t gTspExeTextStart051V15 = 0;
    uintptr_t gTspExeTextEnd051V15 = 0;

    const char* tspCrashStageName051V15(sig_atomic_t stage)
    {
        switch (stage)
        {
            case 1: return "load-begin";
            case 2: return "cleanup-begin";
            case 3: return "cleanup-sound";
            case 4: return "cleanup-dialogue";
            case 5: return "cleanup-journal";
            case 6: return "cleanup-scripts";
            case 7: return "cleanup-window";
            case 8: return "cleanup-world";
            case 9: return "cleanup-input";
            case 10: return "cleanup-mechanics";
            case 11: return "cleanup-done";
            case 12: return "reader-open";
            case 13: return "content-map-ready";
            case 14: return "records-parsed";
            case 15: return "world-saveLoaded";
            case 16: return "actor-id-map-applied";
            case 17: return "player-setup";
            case 18: return "player-rendered";
            case 19: return "window-player-updated";
            case 20: return "mechanics-playerLoaded";
            case 21: return "projectile-casters-updated";
            case 22: return "startup-scripts-added";
            case 23: return "lua-gameLoaded";
            case 24: return "load-complete";
            default: return "unknown";
        }
    }

    size_t tspAppendLiteral051V15(char* out, size_t pos, size_t cap, const char* text)
    {
        if (text == nullptr)
            return pos;
        while (*text != '\0' && pos + 1 < cap)
            out[pos++] = *text++;
        return pos;
    }

    size_t tspAppendUnsigned051V15(char* out, size_t pos, size_t cap, uintptr_t value)
    {
        char tmp[32];
        size_t n = 0;
        do
        {
            tmp[n++] = static_cast<char>('0' + (value % 10));
            value /= 10;
        } while (value != 0 && n < sizeof(tmp));
        while (n > 0 && pos + 1 < cap)
            out[pos++] = tmp[--n];
        return pos;
    }

    size_t tspAppendHex051V15(char* out, size_t pos, size_t cap, uintptr_t value)
    {
        static constexpr char digits[] = "0123456789abcdef";
        char tmp[2 * sizeof(uintptr_t)];
        size_t n = 0;
        do
        {
            tmp[n++] = digits[value & 0xfu];
            value >>= 4u;
        } while (value != 0 && n < sizeof(tmp));
        pos = tspAppendLiteral051V15(out, pos, cap, "0x");
        while (n > 0 && pos + 1 < cap)
            out[pos++] = tmp[--n];
        return pos;
    }

    struct sigaction* tspOldAction051V15(int signalNumber)
    {
        switch (signalNumber)
        {
            case SIGSEGV: return &gTspOldSegv051V15;
            case SIGILL: return &gTspOldIll051V15;
            case SIGBUS: return &gTspOldBus051V15;
            case SIGABRT: return &gTspOldAbrt051V15;
            default: return nullptr;
        }
    }

    void tspCrashHandler051V15(int signalNumber, siginfo_t* info, void* context)
    {
        uintptr_t pc = 0;
        uintptr_t lr = 0;
        uintptr_t sp = 0;

        if (context != nullptr)
        {
            ucontext_t* uc = static_cast<ucontext_t*>(context);
            pc = static_cast<uintptr_t>(uc->uc_mcontext.pc);
            lr = static_cast<uintptr_t>(uc->uc_mcontext.regs[30]);
            sp = static_cast<uintptr_t>(uc->uc_mcontext.sp);
        }

        const uintptr_t fault
            = info != nullptr ? reinterpret_cast<uintptr_t>(info->si_addr) : 0;

        char buffer[768];
        size_t pos = 0;
        pos = tspAppendLiteral051V15(buffer, pos, sizeof(buffer), "TSP_CRASH_PC_051_V15 signal=");
        pos = tspAppendUnsigned051V15(buffer, pos, sizeof(buffer), static_cast<uintptr_t>(signalNumber));
        pos = tspAppendLiteral051V15(buffer, pos, sizeof(buffer), " stage=");
        pos = tspAppendUnsigned051V15(buffer, pos, sizeof(buffer), static_cast<uintptr_t>(gTspCrashStage051V15));
        pos = tspAppendLiteral051V15(buffer, pos, sizeof(buffer), " stage_name=");
        pos = tspAppendLiteral051V15(buffer, pos, sizeof(buffer), tspCrashStageName051V15(gTspCrashStage051V15));
        pos = tspAppendLiteral051V15(buffer, pos, sizeof(buffer), " fault=");
        pos = tspAppendHex051V15(buffer, pos, sizeof(buffer), fault);
        pos = tspAppendLiteral051V15(buffer, pos, sizeof(buffer), " pc=");
        pos = tspAppendHex051V15(buffer, pos, sizeof(buffer), pc);
        pos = tspAppendLiteral051V15(buffer, pos, sizeof(buffer), " lr=");
        pos = tspAppendHex051V15(buffer, pos, sizeof(buffer), lr);
        pos = tspAppendLiteral051V15(buffer, pos, sizeof(buffer), " sp=");
        pos = tspAppendHex051V15(buffer, pos, sizeof(buffer), sp);

        if (gTspExeLoadBase051V15 != 0 && pc >= gTspExeTextStart051V15 && pc < gTspExeTextEnd051V15)
        {
            pos = tspAppendLiteral051V15(buffer, pos, sizeof(buffer), " exe_off=");
            pos = tspAppendHex051V15(buffer, pos, sizeof(buffer), pc - gTspExeLoadBase051V15);
        }

        if (pos + 1 < sizeof(buffer))
            buffer[pos++] = '\n';
        const ssize_t ignored = ::write(STDERR_FILENO, buffer, pos);
        (void)ignored;

        struct sigaction* oldAction = tspOldAction051V15(signalNumber);
        if (oldAction != nullptr)
            ::sigaction(signalNumber, oldAction, nullptr);
        else
        {
            struct sigaction defaultAction {};
            defaultAction.sa_handler = SIG_DFL;
            ::sigemptyset(&defaultAction.sa_mask);
            ::sigaction(signalNumber, &defaultAction, nullptr);
        }

        ::raise(signalNumber);
        ::_exit(128 + signalNumber);
    }

    void tspRememberExecutableMap051V15(const std::string& line)
    {
        if (line.find("openmw-0.51") == std::string::npos || line.find("r-x") == std::string::npos)
            return;

        unsigned long long start = 0;
        unsigned long long end = 0;
        unsigned long long offset = 0;
        if (std::sscanf(line.c_str(), "%llx-%llx %*4s %llx", &start, &end, &offset) == 3)
        {
            gTspExeTextStart051V15 = static_cast<uintptr_t>(start);
            gTspExeTextEnd051V15 = static_cast<uintptr_t>(end);
            gTspExeLoadBase051V15 = static_cast<uintptr_t>(start - offset);
        }
    }

    void tspInstallCrashTracer051V15()
    {
        if (gTspCrashTracerInstalled051V15)
            return;

        std::ifstream maps("/proc/self/maps");
        std::string line;
        while (std::getline(maps, line))
        {
            if (line.find("r-x") != std::string::npos)
            {
                Log(Debug::Info) << "TSP_CRASH_MAP_051_V15 " << line;
                tspRememberExecutableMap051V15(line);
            }
        }

        struct sigaction action {};
        action.sa_sigaction = &tspCrashHandler051V15;
        ::sigemptyset(&action.sa_mask);
        action.sa_flags = SA_SIGINFO | SA_NODEFER;

        ::sigaction(SIGSEGV, &action, &gTspOldSegv051V15);
        ::sigaction(SIGILL, &action, &gTspOldIll051V15);
        ::sigaction(SIGBUS, &action, &gTspOldBus051V15);
        ::sigaction(SIGABRT, &action, &gTspOldAbrt051V15);

        gTspCrashTracerInstalled051V15 = true;

        Log(Debug::Info) << "TSP_CRASH_PC_051_V15 installed=1"
                         << " exe_load_base=0x" << std::hex << gTspExeLoadBase051V15
                         << " exe_text_start=0x" << gTspExeTextStart051V15
                         << " exe_text_end=0x" << gTspExeTextEnd051V15
                         << std::dec;
    }
#else
    void tspInstallCrashTracer051V15() {}
#endif
}

'''
    state = state[:ns.start()] + crash_block + state[ns.start():]

    # Ensure sscanf declaration.
    state = ensure_include(state, "#include <cstdio>")

    candidates = []
    for m in re.finditer(r'StateManager::loadGame\s*\(', state):
        brace = state.find("{", m.end())
        if brace < 0:
            continue
        prelude = state[m.start():brace]
        if "Character*" in prelude and ("filesystem::path" in prelude or "path" in prelude):
            candidates.append((m.start(), brace))

    if len(candidates) != 1:
        raise RuntimeError(
            f"statemanagerimp.cpp: expected one Character/path loadGame overload, found {len(candidates)}"
        )

    load_start, opening = candidates[0]

    # Find the matching closing brace.
    depth = 0
    i = opening
    in_str = in_chr = in_line = in_block = False
    esc = False
    closing = None
    while i < len(state):
        ch = state[i]
        nxt = state[i + 1] if i + 1 < len(state) else ""
        if in_line:
            if ch == "\n":
                in_line = False
        elif in_block:
            if ch == "*" and nxt == "/":
                in_block = False
                i += 1
        elif in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
        elif in_chr:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == "'":
                in_chr = False
        else:
            if ch == "/" and nxt == "/":
                in_line = True
                i += 1
            elif ch == "/" and nxt == "*":
                in_block = True
                i += 1
            elif ch == '"':
                in_str = True
            elif ch == "'":
                in_chr = True
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    closing = i + 1
                    break
        i += 1

    if closing is None:
        raise RuntimeError("statemanagerimp.cpp: loadGame closing brace not found")

    func = state[load_start:closing]
    if "tspInstallCrashTracer051V15();" not in func:
        brace_rel = func.find("{")
        func = func[:brace_rel + 1] + \
            "\n        tspInstallCrashTracer051V15();\n        gTspCrashStage051V15 = 1;\n" + \
            func[brace_rel + 1:]

    phase_stage = {
        "begin": 1,
        "cleanup-begin": 2,
        "cleanup-sound": 3,
        "cleanup-dialogue": 4,
        "cleanup-journal": 5,
        "cleanup-scripts": 6,
        "cleanup-window": 7,
        "cleanup-world": 8,
        "cleanup-input": 9,
        "cleanup-mechanics": 10,
        "cleanup-done": 11,
        "reader-open": 12,
        "content-map-ready": 13,
        "records-parsed": 14,
        "world-saveLoaded": 15,
        "actor-id-map-applied": 16,
        "player-setup": 17,
        "player-rendered": 18,
        "window-player-updated": 19,
        "mechanics-playerLoaded": 20,
        "projectile-casters-updated": 21,
        "startup-scripts-added": 22,
        "lua-gameLoaded": 23,
        "complete": 24,
    }

    rebuilt = []
    for line in func.splitlines(keepends=True):
        if "tspTraceLoadPhase" in line:
            for phase, stage_num in phase_stage.items():
                if f'"{phase}"' in line:
                    indent = line[:len(line) - len(line.lstrip())]
                    rebuilt.append(f"{indent}gTspCrashStage051V15 = {stage_num};\n")
                    break
        rebuilt.append(line)

    func = "".join(rebuilt)
    state = state[:load_start] + func + state[closing:]

# ---------------------------------------------------------------------
# Verification.
# ---------------------------------------------------------------------
for forbidden in (
    "TSP_DEPTH_PARTITION_051_V14",
    "TSP_WARM_ASYNC_GUARD_051_V14",
    "sTspNearDepthCamera",
    "tspIncrementalCompileEnabled",
):
    if forbidden in render:
        raise RuntimeError(f"renderingmanager.cpp: old V14 residue remains: {forbidden}")

for required in (
    "TSP_DEPTH_PARTITION_051_V15",
    "TSP_DEPTH_PARTITION_SETUP_051_V15",
    "osgViewer::DepthPartitionSettings",
    "setUpDepthPartitionForCamera",
    "OPENMW_TSP_DEPTH_NEAR",
    "OPENMW_TSP_DEPTH_SPLIT",
    "TSP_DEPTH_PROJECTION_051_V13",
    "TSP_PLAYER_ANIMATION_SWAP_051_V13",
):
    if required not in render:
        raise RuntimeError(f"renderingmanager.cpp: V15 verification missing: {required}")

for required in ("TSP_DEPTH_PARTITION_UNIFORM_051_V15", "currentProjection"):
    if required not in stateup:
        raise RuntimeError(f"stateupdater.cpp: V15 verification missing: {required}")

for required in (
    "TSP_SYNC_GUARD_051_V15",
    "OPENMW_TSP_ASYNC_PHYSICS",
    "OPENMW_TSP_ASYNC_LUA",
    "tspV15ApplySyncSettings();",
    "tspV15RestoreSyncSettings();",
    "Settings::get<int>(\"Physics\", \"async num threads\")",
    "Settings::get<int>(\"Lua\", \"lua num threads\")",
    "TSP_DEPTH_DIAG_051_V13",
):
    if required not in engine:
        raise RuntimeError(f"engine.cpp: V15 verification missing: {required}")

for required in (
    "TSP_CRASH_PC_051_V15",
    "TSP_CRASH_MAP_051_V15",
    "tspInstallCrashTracer051V15();",
    "TSP_SAFE_RELOAD_CONFIG_051_V13",
    "TSP_LOAD_TRACE_051_V13",
    "TSP_LOAD_WATCH_051_V13",
):
    if required not in state:
        raise RuntimeError(f"statemanagerimp.cpp: V15 verification missing: {required}")

if "OPENMW_TSP_WARM_LOADS_BEFORE_FRESH" in state or "periodic-reset" in state:
    raise RuntimeError("statemanagerimp.cpp: obsolete automatic hybrid reload logic has returned")

write_lf(state_path, state)
write_lf(engine_path, engine)
write_lf(render_path, render)
write_lf(stateup_path, stateup)

print("V15 source revision applied.")
print("  V14 custom slave renderer removed")
print("  stock incremental compile restored")
print("  OSG native 2-band partition added: 5..70 and 70..far")
print("  per-cull shader projection fixed")
print("  physics/Lua worker threads default to 0")
print("  real AArch64 signal PC/LR/SP tracer added")
PY_PATCH

echo
echo "===== SOURCE VERIFICATION ====="

echo "-- V14 renderer residue --"
if grep -n -e 'TSP_DEPTH_PARTITION_051_V14' -e 'TSP_WARM_ASYNC_GUARD_051_V14' "$RENDER_CPP"; then
    echo "ERROR: V14 renderer residue remains."
    exit 1
else
    echo "PASS: V14 renderer hacks removed."
fi

echo
echo "-- V15 graphics --"
grep -n -m 30 \
    -e 'TSP_DEPTH_PARTITION_051_V15' \
    -e 'OPENMW_TSP_DEPTH_NEAR' \
    -e 'OPENMW_TSP_DEPTH_SPLIT' \
    -e 'setUpDepthPartitionForCamera' \
    "$RENDER_CPP"
grep -n -m 15 \
    -e 'TSP_DEPTH_PARTITION_UNIFORM_051_V15' \
    -e 'currentProjection' \
    "$STATEUP_CPP"

echo
echo "-- V15 warm-load sync guard --"
grep -n -m 20 \
    -e 'TSP_SYNC_GUARD_051_V15' \
    -e 'OPENMW_TSP_ASYNC_PHYSICS' \
    -e 'OPENMW_TSP_ASYNC_LUA' \
    "$ENGINE_CPP"

echo
echo "-- V15 crash tracer --"
grep -n -m 25 \
    -e 'TSP_CRASH_PC_051_V15' \
    -e 'TSP_CRASH_MAP_051_V15' \
    -e 'gTspCrashStage051V15' \
    "$STATE_CPP"

echo
echo "-- V13 safe reload retained --"
grep -n -m 10 \
    -e 'TSP_SAFE_RELOAD_CONFIG_051_V13' \
    -e 'TSP_SAFE_RELOAD_051_V13' \
    "$STATE_CPP"

if [ "$PATCH_ONLY" = "1" ]; then
    trap - ERR
    echo "PATCH_ONLY=1: source patch/verification completed."
    exit 0
fi

echo
echo "Incrementally rebuilding OpenMW 0.51 (UNSTRIPPED)..."
cmake --build "$BUILD_DIR" --target openmw --parallel "$JOBS"

[ -x "$BUILT_BINARY" ] || { echo "ERROR: rebuilt binary missing: $BUILT_BINARY"; exit 1; }

[ ! -e "$OUTPUT_BINARY" ] || cp -f "$OUTPUT_BINARY" "$OUTPUT_BINARY.before-$STAMP"
[ ! -e "$PACKAGE_BINARY" ] || cp -f "$PACKAGE_BINARY" "$PACKAGE_BINARY.before-v15-$STAMP"

cp -f "$BUILT_BINARY" "$OUTPUT_BINARY"
cp -f "$BUILT_BINARY" "$PACKAGE_BINARY"
chmod +x "$OUTPUT_BINARY" "$PACKAGE_BINARY"

echo
echo "===== BINARY VERIFICATION ====="
file "$PACKAGE_BINARY"
sha256sum "$PACKAGE_BINARY"
"$PACKAGE_BINARY" --version || true

for marker in \
    'TSP_DEPTH_PARTITION_051_V15' \
    'TSP_SYNC_GUARD_051_V15' \
    'TSP_CRASH_PC_051_V15' \
    'TSP_CRASH_MAP_051_V15' \
    'OPENMW_TSP_DEPTH_NEAR' \
    'OPENMW_TSP_DEPTH_SPLIT' \
    'OPENMW_TSP_ASYNC_PHYSICS' \
    'OPENMW_TSP_ASYNC_LUA' \
    'TSP_SAFE_RELOAD_CONFIG_051_V13' \
    'TSP_LOAD_TRACE_051_V13' \
    'TSP_LOAD_WATCH_051_V13' \
    'TSP_DEPTH_DIAG_051_V13'
do
    strings "$PACKAGE_BINARY" | grep -F "$marker" >/dev/null || {
        echo "ERROR: required runtime marker missing: $marker"
        exit 1
    }
done

if strings "$PACKAGE_BINARY" | grep -F 'TSP_DEPTH_PARTITION_051_V14' >/dev/null; then
    echo "ERROR: obsolete V14 runtime partition string remains."
    exit 1
fi

echo "PASS: V15 runtime markers present."
echo "PASS: V14 runtime partition marker absent."
echo "PASS: corrected V13 safe-reload markers retained."

trap - ERR

echo
echo "============================================================"
echo "SUCCESS: OpenMW 0.51 V15 build complete"
echo "============================================================"
echo "Package binary: $PACKAGE_BINARY"
echo "Container copy: $OUTPUT_BINARY"
echo "Source backup:  $BACKUP_DIR"
echo
echo "Defaults:"
echo "  safe reload = 0 -> warm reload / no ESM reparse"
echo "  depth bands     -> 5..70 and 70..view-distance"
echo "  physics threads -> 0"
echo "  Lua threads     -> 0"
echo "  incremental compile -> restored to stock"
echo
echo "Startup switches:"
echo "  OPENMW_TSP_DEPTH_PARTITION=0|1"
echo "  OPENMW_TSP_DEPTH_NEAR=5"
echo "  OPENMW_TSP_DEPTH_SPLIT=70"
echo "  OPENMW_TSP_ASYNC_PHYSICS=0|1"
echo "  OPENMW_TSP_ASYNC_LUA=0|1"
echo "============================================================"
