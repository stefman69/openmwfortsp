#!/usr/bin/env bash
set -Eeuo pipefail
set -o pipefail

C="${TSP_DOCKER:-openmw_builder}"
DEV="${TSP_DEV:-root@192.168.1.25}"

SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"
OPENMW_BIN="$BUILD/openmw"

CMAKE="$SRC/apps/openmw/CMakeLists.txt"
ANIM="$SRC/apps/openmw/mwrender/animation.cpp"
CAMERA_BIND="$SRC/apps/openmw/mwlua/camerabindings.cpp"
RENDERING="$SRC/apps/openmw/mwrender/renderingmanager.cpp"
VIS_HPP="$SRC/apps/openmw/mwrender/interiorvisibility.hpp"
VIS_CPP="$SRC/apps/openmw/mwrender/interiorvisibility.cpp"

STAMP="$(date +%Y%m%d-%H%M%S)"
PKG="$HOME/Downloads/openmw51-interior-visgrid-v1-$STAMP"
REMOTE_ROOT="/mnt/SDCARD/data/ports/openmw51"
REMOTE_BIN="$REMOTE_ROOT/bin/openmw-0.51"
REMOTE_CONFIG="$REMOTE_ROOT/config-0.51"
REMOTE_MOD="$REMOTE_ROOT/mods/TSPInteriorVisGrid"
REMOTE_BACKUP="$REMOTE_ROOT/backups/interior-visgrid-v1-$STAMP"

STATE_LOG="$PKG/logs/source-state.log"
PATCH_LOG="$PKG/logs/source-patch.log"
BUILD_LOG="$PKG/logs/build.log"

mkdir -p "$PKG/logs" "$PKG/source-backup" \
    "$PKG/patched-source/apps/openmw/mwrender" \
    "$PKG/patched-source/apps/openmw/mwlua" \
    "$PKG/mod/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid" \
    "$PKG/device-backup"

fail_report() {
    local rc="${1:-1}" line="${2:-unknown}" cmd="${3:-unknown}"
    trap - ERR
    set +e
    local report="$PKG/STOPPED_ERROR.txt"
    {
        echo
        echo "=================================================================="
        echo "VISGRID V1 STOPPED SAFELY"
        echo "=================================================================="
        echo "Date: $(date)"
        echo "Exit code: $rc"
        echo "Script line: $line"
        echo "Failing command:"
        echo "  $cmd"
        for f in "$STATE_LOG" "$PATCH_LOG" "$BUILD_LOG"; do
            if [ -f "$f" ]; then
                echo
                echo "----- $(basename "$f") : LAST 220 LINES -----"
                tail -220 "$f" || true
            fi
        done
        echo
        echo "Everything produced so far is preserved at:"
        echo "  $PKG"
        echo "Error report:"
        echo "  $report"
        echo "=================================================================="
    } 2>&1 | tee "$report"
    echo
    echo "SCRIPT STOPPED. TERMINAL REMAINS OPEN."
    if [ -t 0 ]; then
        read -r -p "Press Enter to return to the shell... " _ || true
    fi
    exit "$rc"
}
trap 'fail_report "$?" "$LINENO" "$BASH_COMMAND"' ERR

echo "=================================================================="
echo "OPENMW 0.51 TSP — INTERIOR VISIBILITY GRID PROTOTYPE V1"
echo "=================================================================="
echo "Lua sensor: 8x5 World+Door room-depth grid"
echo "C++: conservative non-actor object-root culling before LightListCallback"
echo "Real far plane stays >= grid maximum while the grid is active."
echo "Package: $PKG"
echo

command -v docker >/dev/null
docker inspect "$C" >/dev/null
if [ "$(docker inspect -f '{{.State.Running}}' "$C")" != "true" ]; then
    docker start "$C"
fi

echo "===== 1/11 VERIFY EXACT SOURCE STATE ====="
set +e
docker exec -i "$C" python3 <<'PYSTATE' 2>&1 | tee "$STATE_LOG"
from pathlib import Path
import hashlib

root = Path("/root/openmw-0.51-tsp-src")
p = {
    "cmake": root / "apps/openmw/CMakeLists.txt",
    "anim": root / "apps/openmw/mwrender/animation.cpp",
    "cam": root / "apps/openmw/mwlua/camerabindings.cpp",
    "render": root / "apps/openmw/mwrender/renderingmanager.cpp",
    "hpp": root / "apps/openmw/mwrender/interiorvisibility.hpp",
    "cpp": root / "apps/openmw/mwrender/interiorvisibility.cpp",
}
for key in ("cmake", "anim", "cam", "render"):
    if not p[key].is_file():
        raise SystemExit("ERROR: required source missing: %s" % p[key])

text = {k: (v.read_text() if v.is_file() else "") for k, v in p.items()}
MARK = "TSP_INTERIOR_VISGRID_051_V1"
state_bits = {
    "cmake": "interiorvisibility" in text["cmake"],
    "anim": MARK in text["anim"],
    "cam": MARK in text["cam"],
    "render": MARK in text["render"],
    "hpp": MARK in text["hpp"],
    "cpp": MARK in text["cpp"],
}
if all(state_bits.values()):
    for key, needle in (
        ("anim", "new InteriorVisibilityCullCallback"),
        ("cam", "setInteriorVisibilityGrid"),
        ("cam", "getInteriorVisibilityStats"),
        ("render", "getInteriorVisibilityFarFloor"),
        ("hpp", "class InteriorVisibilityCullCallback"),
        ("cpp", "nearestSurface"),
    ):
        if needle not in text[key]:
            raise SystemExit("ERROR: partial/corrupt V1 source: %s missing %s" % (key, needle))
    print("PASS: complete V1 source already present.")
    print("STATE=V1_ALREADY_PATCHED")
    raise SystemExit(0)
if any(state_bits.values()):
    print("ERROR: mixed pre-V1/V1 source:")
    for k, v in state_bits.items():
        print("  %-7s %s" % (k, "V1" if v else "pre-V1"))
    raise SystemExit("Refusing to patch a partial V1 state.")

def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024*1024), b""):
            h.update(chunk)
    return h.hexdigest()

expected_anim = "68fdd19429f94078e4f7795f7536b9df20cd5e1eb588cb326017875e914154d8"
expected_render = "2714f91640dbfc1b4eb5dfdc2444daef109ed9ec21668c7eff8aa4cdeb9d5b40"
if sha(p["anim"]) != expected_anim:
    raise SystemExit("ERROR: animation.cpp no longer matches uploaded source. No edits made.")
if sha(p["render"]) != expected_render:
    raise SystemExit("ERROR: renderingmanager.cpp no longer matches uploaded source. No edits made.")

cmake_anchor = "    actorutil distortion animationpriority bonegroup blendmask animblendcontroller occlusionculling\n    )"
anim_anchor = """        if (!mLightListCallback)
            mLightListCallback = new SceneUtil::LightListCallback;
        mObjectRoot->addCullCallback(mLightListCallback);"""
cam_anchor = """        api["setViewDistance"]
            = [renderingManager](const FiniteFloat d) { renderingManager->setViewDistance(d, true); };

        api["getViewTransform"]"""
render_anchor = """    void RenderingManager::setViewDistance(float distance, bool delay)
    {
        mViewDistance = distance;"""
for label, body, anchor in (
    ("CMake", text["cmake"], cmake_anchor),
    ("animation", text["anim"], anim_anchor),
    ("camera", text["cam"], cam_anchor),
    ("rendering", text["render"], render_anchor),
):
    if body.count(anchor) != 1:
        raise SystemExit("ERROR: %s anchor is not unique. No edits made." % label)
if text["anim"].count('#include "animation.hpp"') != 1:
    raise SystemExit("ERROR: animation include anchor is not unique.")
if text["cam"].count('#include "../mwrender/renderingmanager.hpp"') != 1:
    raise SystemExit("ERROR: camera include anchor is not unique.")
if text["render"].count('#include "groundcover.hpp"') != 1:
    raise SystemExit("ERROR: rendering include anchor is not unique.")
print("PASS: current pre-V1 source matches the uploaded renderer baseline.")
print("PASS: all four edit anchors are unique.")
print("STATE=PATCH_NEEDED")
PYSTATE
STATE_RC=${PIPESTATUS[0]}
set -e
[ "$STATE_RC" -eq 0 ] || exit "$STATE_RC"
SOURCE_STATE="$(grep '^STATE=' "$STATE_LOG" | tail -1 | cut -d= -f2-)"
[ -n "$SOURCE_STATE" ]
echo "Detected: $SOURCE_STATE"

SOURCE_BACKUP=""
if [ "$SOURCE_STATE" = "PATCH_NEEDED" ]; then
    echo
    echo "===== 2/11 BACK UP TOUCHED SOURCE BEFORE PATCH ====="
    SOURCE_BACKUP="$SRC/.tsp-051-source-backups/interior-visgrid-v1-$STAMP"
    docker exec -i "$C" python3 - "$SOURCE_BACKUP" <<'PYBACKUP' | tee "$PATCH_LOG"
from pathlib import Path
import hashlib, shutil, sys
root = Path("/root/openmw-0.51-tsp-src")
backup = Path(sys.argv[1])
sources = [
    root/"apps/openmw/CMakeLists.txt",
    root/"apps/openmw/mwrender/animation.cpp",
    root/"apps/openmw/mwlua/camerabindings.cpp",
    root/"apps/openmw/mwrender/renderingmanager.cpp",
]
newfiles = [
    root/"apps/openmw/mwrender/interiorvisibility.hpp",
    root/"apps/openmw/mwrender/interiorvisibility.cpp",
]
def sha(p):
    h=hashlib.sha256()
    with p.open("rb") as f:
        for c in iter(lambda:f.read(1024*1024), b""): h.update(c)
    return h.hexdigest()
for src in sources:
    dst=backup/src.relative_to(root)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src,dst)
for src in sources:
    dst=backup/src.relative_to(root)
    if sha(src)!=sha(dst): raise SystemExit("ERROR: backup SHA mismatch: %s"%src)
    print("BACKUP PASS", sha(src), src)
for p in newfiles:
    if p.exists(): raise SystemExit("ERROR: new V1 file unexpectedly exists: %s"%p)
(backup/"NEW_FILES_WERE_ABSENT.txt").write_text("\n".join(map(str,newfiles))+"\n")
Path("/root/openmw51-visgrid-v1-source-backup-path.txt").write_text(str(backup)+"\n")
print("VERIFIED BACKUP:", backup)
PYBACKUP
    docker exec "$C" test -d "$SOURCE_BACKUP"

    echo
    echo "===== 3/11 APPLY VISGRID V1 SOURCE ====="
    docker exec -i "$C" python3 <<'PYPATCH' | tee -a "$PATCH_LOG"
from pathlib import Path

root = Path("/root/openmw-0.51-tsp-src")
cmake = root/"apps/openmw/CMakeLists.txt"
anim = root/"apps/openmw/mwrender/animation.cpp"
cam = root/"apps/openmw/mwlua/camerabindings.cpp"
render = root/"apps/openmw/mwrender/renderingmanager.cpp"
hpp = root/"apps/openmw/mwrender/interiorvisibility.hpp"
cpp = root/"apps/openmw/mwrender/interiorvisibility.cpp"
MARK = "TSP_INTERIOR_VISGRID_051_V1"

def once(text, old, new, label):
    n=text.count(old)
    if n!=1: raise RuntimeError("%s anchor matched %d times"%(label,n))
    return text.replace(old,new,1)

c=cmake.read_text()
a=anim.read_text()
b=cam.read_text()
r=render.read_text()

c=once(c,
'''    actorutil distortion animationpriority bonegroup blendmask animblendcontroller occlusionculling
    )''',
'''    actorutil distortion animationpriority bonegroup blendmask animblendcontroller occlusionculling interiorvisibility
    )''',"CMake")

a=once(a, '#include "animation.hpp"\n',
'''#include "animation.hpp"
#include "interiorvisibility.hpp" // TSP_INTERIOR_VISGRID_051_V1
''',"animation include")

a=once(a,
'''        if (!mLightListCallback)
            mLightListCallback = new SceneUtil::LightListCallback;
        mObjectRoot->addCullCallback(mLightListCallback);''',
'''        // TSP_INTERIOR_VISGRID_051_V1
        // The VISGRID callback is deliberately installed first, outside the
        // normal LightList callback. A rejected object therefore avoids the
        // ordinary per-object light/state traversal. Actors remain untouched V1.
        if (!mPtr.getClass().isActor())
            mObjectRoot->addCullCallback(new InteriorVisibilityCullCallback);

        if (!mLightListCallback)
            mLightListCallback = new SceneUtil::LightListCallback;
        mObjectRoot->addCullCallback(mLightListCallback);''',"animation callback")

b=once(b, '#include "../mwrender/renderingmanager.hpp"\n',
'''#include "../mwrender/renderingmanager.hpp"
#include "../mwrender/interiorvisibility.hpp" // TSP_INTERIOR_VISGRID_051_V1
''',"camera include")
if "#include <vector>\n" not in b:
    pos=b.find("namespace MWLua")
    if pos<0: raise RuntimeError("camera namespace missing")
    b=b[:pos]+'#include <vector>\n#include <stdexcept>\n\n'+b[pos:]

b=once(b,
'''        api["setViewDistance"]
            = [renderingManager](const FiniteFloat d) { renderingManager->setViewDistance(d, true); };

        api["getViewTransform"]''',
'''        api["setViewDistance"]
            = [renderingManager](const FiniteFloat d) { renderingManager->setViewDistance(d, true); };

        // TSP_INTERIOR_VISGRID_051_V1
        // Generic Lua -> renderer bridge. Lua owns the room sensor; this API
        // only transports a conservative camera-space depth field.
        api["setInteriorVisibilityGrid"]
            = [](int cols, int rows, const sol::table& values, const FiniteFloat padding) {
                  const int count = cols * rows;
                  if (cols <= 0 || rows <= 0 || count <= 0 || count > MWRender::sInteriorVisibilityMaxTiles)
                      throw std::runtime_error("Invalid interior visibility grid dimensions");

                  std::vector<float> depths;
                  depths.reserve(static_cast<std::size_t>(count));
                  for (int i = 1; i <= count; ++i)
                      depths.push_back(values.get<float>(i));

                  MWRender::setInteriorVisibilityGrid(
                      cols, rows, std::span<const float>(depths.data(), depths.size()), padding);
              };

        api["clearInteriorVisibilityGrid"] = [] { MWRender::clearInteriorVisibilityGrid(); };
        api["resetInteriorVisibilityStats"] = [] { MWRender::resetInteriorVisibilityStats(); };

        api["getInteriorVisibilityStats"] = [lua]() {
            const MWRender::InteriorVisibilityStats stats = MWRender::getInteriorVisibilityStats();
            sol::table out(lua, sol::create);
            out["enabled"] = stats.mEnabled;
            out["cols"] = stats.mCols;
            out["rows"] = stats.mRows;
            out["farFloor"] = stats.mFarFloor;
            out["padding"] = stats.mPadding;
            out["tested"] = static_cast<double>(stats.mTested);
            out["culled"] = static_cast<double>(stats.mCulled);
            return out;
        };

        api["getViewTransform"]''',"camera API")

r=once(r, '#include "groundcover.hpp"\n',
'''#include "groundcover.hpp"
#include "interiorvisibility.hpp" // TSP_INTERIOR_VISGRID_051_V1
''',"render include")
r=once(r,
'''    void RenderingManager::setViewDistance(float distance, bool delay)
    {
        mViewDistance = distance;''',
'''    void RenderingManager::setViewDistance(float distance, bool delay)
    {
        // TSP_INTERIOR_VISGRID_051_V1
        // VISGRID is an additional culling volume, not a smaller projection.
        // While active, older scalar interior controllers may not shorten the
        // real far plane underneath the grid.
        if (isInteriorVisibilityGridEnabled())
            distance = std::max(distance, getInteriorVisibilityFarFloor());

        mViewDistance = distance;''',"view-distance floor")

hpp_text = r'''#ifndef OPENMW_MWRENDER_INTERIORVISIBILITY_H
#define OPENMW_MWRENDER_INTERIORVISIBILITY_H

// TSP_INTERIOR_VISGRID_051_V1

#include <components/sceneutil/nodecallback.hpp>

#include <cstdint>
#include <span>

namespace osg
{
    class Node;
}

namespace osgUtil
{
    class CullVisitor;
}

namespace MWRender
{
    constexpr int sInteriorVisibilityMaxTiles = 64;

    struct InteriorVisibilityStats
    {
        bool mEnabled = false;
        int mCols = 0;
        int mRows = 0;
        float mFarFloor = 0.f;
        float mPadding = 0.f;
        std::uint64_t mTested = 0;
        std::uint64_t mCulled = 0;
    };

    void setInteriorVisibilityGrid(int cols, int rows, std::span<const float> depths, float padding);
    void clearInteriorVisibilityGrid();
    bool isInteriorVisibilityGridEnabled();
    float getInteriorVisibilityFarFloor();
    InteriorVisibilityStats getInteriorVisibilityStats();
    void resetInteriorVisibilityStats();

    class InteriorVisibilityCullCallback
        : public SceneUtil::NodeCallback<InteriorVisibilityCullCallback, osg::Node*, osgUtil::CullVisitor*>
    {
    public:
        InteriorVisibilityCullCallback() = default;
        InteriorVisibilityCullCallback(const InteriorVisibilityCullCallback& copy, const osg::CopyOp& copyop)
            : osg::Object(copy, copyop)
            , SceneUtil::NodeCallback<InteriorVisibilityCullCallback, osg::Node*, osgUtil::CullVisitor*>(copy, copyop)
        {
        }

        META_Object(MWRender, InteriorVisibilityCullCallback)

        void operator()(osg::Node* node, osgUtil::CullVisitor* cv);
    };
}

#endif
'''

cpp_text = r'''#include "interiorvisibility.hpp"

// TSP_INTERIOR_VISGRID_051_V1

#include <components/debug/debuglog.hpp>
#include <components/misc/constants.hpp>
#include <components/sceneutil/util.hpp>

#include <osg/BoundingSphere>
#include <osg/Camera>
#include <osg/Matrix>
#include <osg/Vec3d>
#include <osgUtil/CullVisitor>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <limits>

namespace MWRender
{
    namespace
    {
        std::atomic<bool> sEnabled{ false };
        std::atomic<int> sCols{ 0 };
        std::atomic<int> sRows{ 0 };
        std::atomic<float> sPadding{ 0.f };
        std::atomic<float> sFarFloor{ 0.f };
        std::array<std::atomic<float>, sInteriorVisibilityMaxTiles> sDepths{};
        std::atomic<std::uint64_t> sTested{ 0 };
        std::atomic<std::uint64_t> sCulled{ 0 };

        bool finitePositive(float value)
        {
            return std::isfinite(value) && value > 0.f;
        }

        bool projectEyePoint(
            const osg::Vec3d& eyePoint, const osg::Matrixd& projection, double& u, double& v)
        {
            if (!std::isfinite(eyePoint.x()) || !std::isfinite(eyePoint.y())
                || !std::isfinite(eyePoint.z()))
                return false;

            const osg::Vec3d ndc = eyePoint * projection;
            if (!std::isfinite(ndc.x()) || !std::isfinite(ndc.y()))
                return false;

            u = (ndc.x() + 1.0) * 0.5;
            v = (1.0 - ndc.y()) * 0.5;
            return std::isfinite(u) && std::isfinite(v);
        }
    }

    void setInteriorVisibilityGrid(
        int cols, int rows, std::span<const float> depths, float padding)
    {
        const int count = cols * rows;
        if (cols <= 0 || rows <= 0 || count <= 0 || count > sInteriorVisibilityMaxTiles
            || static_cast<int>(depths.size()) < count)
        {
            clearInteriorVisibilityGrid();
            return;
        }

        const bool wasEnabled = sEnabled.load(std::memory_order_acquire);

        // If cull overlaps an update, disabled means "render normally" for safety.
        sEnabled.store(false, std::memory_order_release);

        float farFloor = 0.f;
        for (int i = 0; i < count; ++i)
        {
            float d = depths[static_cast<std::size_t>(i)];
            if (!finitePositive(d))
                d = std::numeric_limits<float>::max() / 1024.f;
            sDepths[static_cast<std::size_t>(i)].store(d, std::memory_order_relaxed);
            farFloor = std::max(farFloor, d);
        }

        sCols.store(cols, std::memory_order_relaxed);
        sRows.store(rows, std::memory_order_relaxed);
        sPadding.store(std::max(0.f, padding), std::memory_order_relaxed);
        sFarFloor.store(farFloor, std::memory_order_relaxed);
        sEnabled.store(true, std::memory_order_release);

        if (!wasEnabled)
            Log(Debug::Info) << "TSP_INTERIOR_VISGRID_051_V1 active cols=" << cols
                             << " rows=" << rows << " far_floor=" << farFloor
                             << " padding=" << std::max(0.f, padding);
    }

    void clearInteriorVisibilityGrid()
    {
        const bool wasEnabled = sEnabled.exchange(false, std::memory_order_acq_rel);
        sCols.store(0, std::memory_order_relaxed);
        sRows.store(0, std::memory_order_relaxed);
        sFarFloor.store(0.f, std::memory_order_relaxed);
        if (wasEnabled)
            Log(Debug::Info) << "TSP_INTERIOR_VISGRID_051_V1 inactive";
    }

    bool isInteriorVisibilityGridEnabled()
    {
        return sEnabled.load(std::memory_order_acquire);
    }

    float getInteriorVisibilityFarFloor()
    {
        return sFarFloor.load(std::memory_order_relaxed);
    }

    InteriorVisibilityStats getInteriorVisibilityStats()
    {
        InteriorVisibilityStats out;
        out.mEnabled = sEnabled.load(std::memory_order_acquire);
        out.mCols = sCols.load(std::memory_order_relaxed);
        out.mRows = sRows.load(std::memory_order_relaxed);
        out.mFarFloor = sFarFloor.load(std::memory_order_relaxed);
        out.mPadding = sPadding.load(std::memory_order_relaxed);
        out.mTested = sTested.load(std::memory_order_relaxed);
        out.mCulled = sCulled.load(std::memory_order_relaxed);
        return out;
    }

    void resetInteriorVisibilityStats()
    {
        sTested.store(0, std::memory_order_relaxed);
        sCulled.store(0, std::memory_order_relaxed);
    }

    void InteriorVisibilityCullCallback::operator()(osg::Node* node, osgUtil::CullVisitor* cv)
    {
        if (!sEnabled.load(std::memory_order_acquire) || node == nullptr || cv == nullptr)
        {
            traverse(node, cv);
            return;
        }

        // Main scene camera only: never affect maps, reflections, shadows or previews.
        osg::Camera* currentCamera = cv->getCurrentCamera();
        if (currentCamera == nullptr || currentCamera->getName() != Constants::SceneCamera)
        {
            traverse(node, cv);
            return;
        }

        const int cols = sCols.load(std::memory_order_relaxed);
        const int rows = sRows.load(std::memory_order_relaxed);
        const int count = cols * rows;
        if (cols <= 0 || rows <= 0 || count <= 0 || count > sInteriorVisibilityMaxTiles)
        {
            traverse(node, cv);
            return;
        }

        osg::BoundingSphere bound = node->getBound();
        if (!bound.valid() || !std::isfinite(bound.radius()) || bound.radius() <= 0.f)
        {
            traverse(node, cv);
            return;
        }

        // mObjectRoot is under the object's PAT, so model-view already contains
        // world placement. This mirrors LightListCallback's view-space strategy.
        SceneUtil::transformBoundingSphere(*cv->getModelViewMatrix(), bound);

        const osg::Vec3d center(bound.center());
        const double radius = static_cast<double>(bound.radius());

        // Near-camera/behind-camera/inside-bound cases are deliberately left alone.
        if (center.z() >= -1.0 || center.length() <= radius + 32.0)
        {
            traverse(node, cv);
            return;
        }

        const osg::Matrixd projection(*cv->getProjectionMatrix());
        double uc=0.0, vc=0.0, ux0=0.0, vx0=0.0, ux1=0.0, vx1=0.0;
        double uy0=0.0, vy0=0.0, uy1=0.0, vy1=0.0;

        if (!projectEyePoint(center, projection, uc, vc)
            || !projectEyePoint(center + osg::Vec3d(radius,0.0,0.0), projection, ux0, vx0)
            || !projectEyePoint(center - osg::Vec3d(radius,0.0,0.0), projection, ux1, vx1)
            || !projectEyePoint(center + osg::Vec3d(0.0,radius,0.0), projection, uy0, vy0)
            || !projectEyePoint(center - osg::Vec3d(0.0,radius,0.0), projection, uy1, vy1))
        {
            traverse(node, cv);
            return;
        }

        double uMin=std::min({uc,ux0,ux1,uy0,uy1});
        double uMax=std::max({uc,ux0,ux1,uy0,uy1});
        double vMin=std::min({vc,vx0,vx1,vy0,vy1});
        double vMax=std::max({vc,vx0,vx1,vy0,vy1});

        if (uMax < 0.0 || uMin > 1.0 || vMax < 0.0 || vMin > 1.0)
        {
            traverse(node, cv);
            return;
        }

        uMin=std::clamp(uMin,0.0,0.999999);
        uMax=std::clamp(uMax,0.0,0.999999);
        vMin=std::clamp(vMin,0.0,0.999999);
        vMax=std::clamp(vMax,0.0,0.999999);

        int col0=static_cast<int>(std::floor(uMin*cols));
        int col1=static_cast<int>(std::floor(uMax*cols));
        int row0=static_cast<int>(std::floor(vMin*rows));
        int row1=static_cast<int>(std::floor(vMax*rows));

        // Conservative one-tile expansion of every projected object bound.
        col0=std::max(0,col0-1); col1=std::min(cols-1,col1+1);
        row0=std::max(0,row0-1); row1=std::min(rows-1,row1+1);

        float allowedDepth=0.f;
        for (int row=row0; row<=row1; ++row)
            for (int col=col0; col<=col1; ++col)
            {
                const int idx=row*cols+col;
                const float d=sDepths[static_cast<std::size_t>(idx)].load(std::memory_order_relaxed);
                if (!finitePositive(d))
                {
                    traverse(node, cv);
                    return;
                }
                allowedDepth=std::max(allowedDepth,d);
            }

        const double nearestSurface=std::max(0.0, center.length()-radius);
        const double safety=static_cast<double>(sPadding.load(std::memory_order_relaxed));
        sTested.fetch_add(1,std::memory_order_relaxed);

        if (nearestSurface > static_cast<double>(allowedDepth)+safety)
        {
            sCulled.fetch_add(1,std::memory_order_relaxed);
            return;
        }

        traverse(node, cv);
    }
}
'''

for label,text,needs in (
    ("cmake",c,["interiorvisibility"]),
    ("animation",a,[MARK,"new InteriorVisibilityCullCallback"]),
    ("camera",b,[MARK,"setInteriorVisibilityGrid","getInteriorVisibilityStats"]),
    ("render",r,[MARK,"getInteriorVisibilityFarFloor"]),
    ("hpp",hpp_text,[MARK,"class InteriorVisibilityCullCallback"]),
    ("cpp",cpp_text,[MARK,"nearestSurface","Constants::SceneCamera"]),
):
    for n in needs:
        if n not in text: raise RuntimeError("%s candidate missing %s"%(label,n))
    if text.count("{")!=text.count("}"): raise RuntimeError("%s brace imbalance"%label)

for path,text in ((cmake,c),(anim,a),(cam,b),(render,r),(hpp,hpp_text),(cpp,cpp_text)):
    tmp=Path("/tmp")/("visgrid-v1-"+path.name)
    tmp.write_text(text)
    tmp.replace(path)
    print("PATCH PASS:",path)

print("PASS: V1 source written only after all candidates validated.")
PYPATCH

    echo
    echo "===== 4/11 VERIFY PATCH VS BACKUP ====="
    docker exec -i "$C" python3 - "$SOURCE_BACKUP" <<'PYVERIFY' | tee -a "$PATCH_LOG"
from pathlib import Path
import hashlib,sys
root=Path("/root/openmw-0.51-tsp-src"); backup=Path(sys.argv[1])
mods=[
 root/"apps/openmw/CMakeLists.txt",
 root/"apps/openmw/mwrender/animation.cpp",
 root/"apps/openmw/mwlua/camerabindings.cpp",
 root/"apps/openmw/mwrender/renderingmanager.cpp",
]
new=[
 root/"apps/openmw/mwrender/interiorvisibility.hpp",
 root/"apps/openmw/mwrender/interiorvisibility.cpp",
]
def sha(p):
 h=hashlib.sha256()
 with p.open("rb") as f:
  for c in iter(lambda:f.read(1024*1024),b""): h.update(c)
 return h.hexdigest()
for p in mods:
 old=backup/p.relative_to(root)
 if not old.is_file() or sha(old)==sha(p): raise SystemExit("ERROR: patch verification failed: %s"%p)
 print("PASS changed",p)
for p in new:
 if not p.is_file() or "TSP_INTERIOR_VISGRID_051_V1" not in p.read_text():
  raise SystemExit("ERROR: V1 new source missing: %s"%p)
 print("PASS new",p)
print("PASS: source backup is intact and current source is V1.")
PYVERIFY
else
    echo
    echo "===== 2-4/11 SOURCE PATCH SKIPPED: COMPLETE V1 ALREADY PRESENT ====="
    SOURCE_BACKUP="$(docker exec "$C" bash -lc 'cat /root/openmw51-visgrid-v1-source-backup-path.txt 2>/dev/null || true')"
    echo "Original V1 source backup: ${SOURCE_BACKUP:-not recorded}"
fi
echo
echo "===== 5/11 BUILD / RESUME OPENMW ====="
PRE_SHA="$(docker exec "$C" bash -lc 'test -f /root/openmw-0.51-tsp-build/openmw && sha256sum /root/openmw-0.51-tsp-build/openmw | awk "{print \$1}" || true')"
echo "Pre-build SHA: ${PRE_SHA:-none}"

set +e
docker exec "$C" bash -lc '
set -o pipefail
cmake --build /root/openmw-0.51-tsp-build --target openmw -- -j4
' 2>&1 | tee "$BUILD_LOG"
BUILD_RC=${PIPESTATUS[0]}
set -e
[ "$BUILD_RC" -eq 0 ] || exit "$BUILD_RC"

if ! docker exec "$C" grep -a -q 'TSP_INTERIOR_VISGRID_051_V1' "$OPENMW_BIN"; then
    echo
    echo "V1 marker absent after normal build; forcing only V1-related objects + final link."
    docker exec "$C" bash -lc '
    set -euo pipefail
    B=/root/openmw-0.51-tsp-build
    find "$B" -type f \( -name "interiorvisibility.cpp.o" -o -name "animation.cpp.o" \
        -o -name "camerabindings.cpp.o" -o -name "renderingmanager.cpp.o" \) -print -delete
    rm -fv "$B/openmw" "$B/apps/openmw/openmw"
    '
    set +e
    docker exec "$C" bash -lc '
    set -o pipefail
    cmake --build /root/openmw-0.51-tsp-build --target openmw -- -j4
    ' 2>&1 | tee -a "$BUILD_LOG"
    BUILD_RC=${PIPESTATUS[0]}
    set -e
    [ "$BUILD_RC" -eq 0 ] || exit "$BUILD_RC"
fi

echo
echo "===== 6/11 VERIFY BUILD ====="
docker exec "$C" bash -lc '
set -euo pipefail
B=/root/openmw-0.51-tsp-build/openmw
S=/root/openmw-0.51-tsp-src
test -x "$B"
readelf -h "$B" | grep -E "Class:|Machine:|Type:"
readelf -h "$B" | grep -q "AArch64"

grep -Fq "class InteriorVisibilityCullCallback" "$S/apps/openmw/mwrender/interiorvisibility.hpp"
grep -Fq "nearestSurface" "$S/apps/openmw/mwrender/interiorvisibility.cpp"
grep -Fq "setInteriorVisibilityGrid" "$S/apps/openmw/mwlua/camerabindings.cpp"
grep -Fq "getInteriorVisibilityFarFloor" "$S/apps/openmw/mwrender/renderingmanager.cpp"
grep -a -q "TSP_INTERIOR_VISGRID_051_V1" "$B"

CM="$S/apps/openmw/mwinput/controllermanager.cpp"
if grep -Fq "TSP_MOUSE_CURSOR_CLEAR_051_V60" "$CM"; then
    grep -a -q "TSP_MOUSE_CURSOR_CLEAR_051_V60" "$B"
    echo "PASS: V60 controller/mouse fix retained"
fi
if grep -Fq "TSP_MOUSE_MENU_OFF_051_V59" "$CM"; then
    grep -a -q "TSP_MOUSE_MENU_OFF_051_V59" "$B"
    echo "PASS: V59 MENU mouse-off retained"
fi
grep -a -q "r3=force-text-reset" "$B"
grep -a -q "tx_cursor.dds" "$B"

echo "PASS: AArch64 + V1 source/runtime + current controller invariants"
sha256sum "$B"
'
POST_SHA="$(docker exec "$C" sha256sum "$OPENMW_BIN" | awk '{print $1}')"
echo "Post-build SHA: $POST_SHA"
if [ "$SOURCE_STATE" = "PATCH_NEEDED" ] && [ -n "$PRE_SHA" ] && [ "$PRE_SHA" = "$POST_SHA" ]; then
    echo "ERROR: first V1 source patch did not change OpenMW SHA."
    exit 1
fi

echo
echo "===== 7/11 CREATE STANDALONE LUA SENSOR MOD ====="
cat > "$PKG/mod/TSPInteriorVisGrid/TSPInteriorVisGrid.omwscripts" <<'EOF_OMW'
PLAYER: scripts/TSPInteriorVisGrid/visgrid.lua
EOF_OMW

cat > "$PKG/mod/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua" <<'EOF_LUA'
-- TSP_INTERIOR_VISGRID_LUA_V1
-- Sensor-only half of TSP_INTERIOR_VISGRID_051_V1.
--
-- V1 intentionally keeps the proven World+Door physics-ray sensor so this
-- test isolates the NEW mechanism: a tiled visibility volume rather than one
-- scalar far plane.

local camera = require('openmw.camera')
local core = require('openmw.core')
local nearby = require('openmw.nearby')
local self = require('openmw.self')
local util = require('openmw.util')

local COLS = 8
local ROWS = 5
local COUNT = COLS * ROWS
local MAX_DIST = 5500.0
local PADDING = 350.0
local RAYS_PER_FRAME = 5

local RESET_MOVE = 48.0
local RESET_YAW = math.rad(6.0)
local RESET_PITCH = math.rad(5.0)
local CLOSE_CONFIRM_TOLERANCE = 180.0
local PRINT_PERIOD = 2.0

local RAY_MASK = nearby.COLLISION_TYPE.World + (nearby.COLLISION_TYPE.Door or 0)

local depth = {}
local pendingClose = {}
local order = {}
local orderPos = 1
local inInterior = false
local anchorPos = nil
local anchorYaw = nil
local anchorPitch = nil
local lastPrint = 0.0
local lastStatsTested = 0.0
local lastStatsCulled = 0.0

local function angleDiff(a, b)
    local d = a - b
    while d > math.pi do d = d - 2.0 * math.pi end
    while d < -math.pi do d = d + 2.0 * math.pi end
    return math.abs(d)
end

local function buildOrder()
    order = {}
    local cx = (COLS + 1) * 0.5
    local cy = (ROWS + 1) * 0.5
    for row = 1, ROWS do
        for col = 1, COLS do
            local idx = (row - 1) * COLS + col
            local dx = col - cx
            local dy = row - cy
            order[#order + 1] = { idx = idx, score = dx * dx + dy * dy }
        end
    end
    table.sort(order, function(a, b) return a.score < b.score end)
end

local function fillMax()
    for i = 1, COUNT do
        depth[i] = MAX_DIST
        pendingClose[i] = nil
    end
    orderPos = 1
end

local function publishGrid()
    -- 3x3 max-dilation: openings deliberately protect neighboring screen tiles.
    local out = {}
    for row = 1, ROWS do
        for col = 1, COLS do
            local best = 0.0
            for rr = math.max(1, row - 1), math.min(ROWS, row + 1) do
                for cc = math.max(1, col - 1), math.min(COLS, col + 1) do
                    local idx = (rr - 1) * COLS + cc
                    if depth[idx] > best then best = depth[idx] end
                end
            end
            out[(row - 1) * COLS + col] = best
        end
    end
    camera.setInteriorVisibilityGrid(COLS, ROWS, out, PADDING)
    return out
end

local function resetForCamera(pos, yaw, pitch, reason)
    fillMax()
    anchorPos = pos
    anchorYaw = yaw
    anchorPitch = pitch
    publishGrid()
    print(string.format('[TSP_VISGRID_V1] reset reason=%s max=%.0f',
        reason or 'unknown', MAX_DIST))
end

local function acceptDepth(idx, measured)
    measured = math.max(1.0, math.min(MAX_DIST, measured))
    local current = depth[idx] or MAX_DIST

    -- Expansions are safe and immediate.
    if measured >= current then
        depth[idx] = measured
        pendingClose[idx] = nil
        return
    end

    -- A contraction can hide geometry, so require a second similar observation.
    local pending = pendingClose[idx]
    if pending ~= nil and math.abs(pending - measured) <= CLOSE_CONFIRM_TOLERANCE then
        depth[idx] = math.max(pending, measured)
        pendingClose[idx] = nil
    else
        pendingClose[idx] = measured
    end
end

local function sampleTile(idx, eye)
    local row = math.floor((idx - 1) / COLS) + 1
    local col = ((idx - 1) % COLS) + 1
    local u = (col - 0.5) / COLS
    local v = (row - 0.5) / ROWS

    local okDir, dir = pcall(camera.viewportToWorldVector, util.vector2(u, v))
    if not okDir or dir == nil then
        acceptDepth(idx, MAX_DIST)
        return
    end

    local okNorm, norm = pcall(function() return dir:normalize() end)
    if not okNorm or norm == nil then
        acceptDepth(idx, MAX_DIST)
        return
    end

    local dest = eye + norm * MAX_DIST
    local okRay, res = pcall(nearby.castRay, eye, dest, { collisionType = RAY_MASK })
    if not okRay or res == nil then
        acceptDepth(idx, MAX_DIST)
        return
    end

    local d = MAX_DIST
    if res.hit and res.hitPos ~= nil then
        d = (res.hitPos - eye):length()
    end
    acceptDepth(idx, d)
end

local function printStatus(published)
    local now = core.getRealTime()
    if now == nil or now - lastPrint < PRINT_PERIOD then return end
    lastPrint = now

    local minD, maxD, sum = MAX_DIST, 0.0, 0.0
    for i = 1, COUNT do
        local d = published[i] or MAX_DIST
        minD = math.min(minD, d)
        maxD = math.max(maxD, d)
        sum = sum + d
    end

    local stats = camera.getInteriorVisibilityStats()
    local tested = stats.tested or 0.0
    local culled = stats.culled or 0.0
    local dt = tested - lastStatsTested
    local dc = culled - lastStatsCulled
    lastStatsTested = tested
    lastStatsCulled = culled

    local pct = 0.0
    if dt > 0.0 then pct = dc * 100.0 / dt end

    print(string.format(
        '[TSP_VISGRID_V1] grid=%dx%d min=%.0f mean=%.0f max=%.0f tested_delta=%.0f culled_delta=%.0f reject=%.1f%% total_tested=%.0f total_culled=%.0f',
        COLS, ROWS, minD, sum / COUNT, maxD, dt, dc, pct, tested, culled))
end

local function onInit()
    buildOrder()
    fillMax()
    if camera.clearInteriorVisibilityGrid ~= nil then
        camera.clearInteriorVisibilityGrid()
    end
    print('[TSP_VISGRID_V1] Lua prototype loaded')
end

local function onFrame(dt)
    if dt == nil or dt <= 0.0 then return end
    local cell = self.cell
    if cell == nil then return end

    if cell.isExterior then
        if inInterior then
            inInterior = false
            camera.clearInteriorVisibilityGrid()
            anchorPos, anchorYaw, anchorPitch = nil, nil, nil
            print('[TSP_VISGRID_V1] exit interior -> grid off')
        end
        return
    end

    local eye = camera.getPosition()
    if eye == nil then return end
    local yaw = camera.getYaw() or 0.0
    local pitch = camera.getPitch() or 0.0

    if not inInterior then
        inInterior = true
        camera.resetInteriorVisibilityStats()
        lastStatsTested, lastStatsCulled = 0.0, 0.0
        resetForCamera(eye, yaw, pitch, 'enter-interior')
    else
        local moved = anchorPos ~= nil and (eye - anchorPos):length() or 0.0
        local yawMoved = anchorYaw ~= nil and angleDiff(yaw, anchorYaw) or 0.0
        local pitchMoved = anchorPitch ~= nil and angleDiff(pitch, anchorPitch) or 0.0
        if moved >= RESET_MOVE or yawMoved >= RESET_YAW or pitchMoved >= RESET_PITCH then
            resetForCamera(eye, yaw, pitch, 'camera-change')
        end
    end

    -- C++ also clamps future setViewDistance calls while the grid is live.
    local live = camera.getViewDistance() or MAX_DIST
    if live < MAX_DIST - 1.0 then
        camera.setViewDistance(MAX_DIST)
    end

    for _ = 1, RAYS_PER_FRAME do
        local entry = order[orderPos]
        if entry == nil then
            orderPos = 1
            entry = order[orderPos]
        end
        sampleTile(entry.idx, eye)
        orderPos = orderPos + 1
        if orderPos > #order then orderPos = 1 end
    end

    local published = publishGrid()
    printStatus(published)
end

return {
    engineHandlers = {
        onInit = onInit,
        onFrame = onFrame,
    },
}
EOF_LUA

grep -Fq 'camera.setInteriorVisibilityGrid' \
    "$PKG/mod/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua"
echo "PASS: Lua VISGRID sensor generated."

echo
echo "===== 8/11 PACKAGE BINARY + SOURCE ====="
docker cp "$C:$OPENMW_BIN" "$PKG/openmw-0.51"
docker cp "$C:$CMAKE" "$PKG/patched-source/apps/openmw/CMakeLists.txt"
docker cp "$C:$ANIM" "$PKG/patched-source/apps/openmw/mwrender/animation.cpp"
docker cp "$C:$CAMERA_BIND" "$PKG/patched-source/apps/openmw/mwlua/camerabindings.cpp"
docker cp "$C:$RENDERING" "$PKG/patched-source/apps/openmw/mwrender/renderingmanager.cpp"
docker cp "$C:$VIS_HPP" "$PKG/patched-source/apps/openmw/mwrender/interiorvisibility.hpp"
docker cp "$C:$VIS_CPP" "$PKG/patched-source/apps/openmw/mwrender/interiorvisibility.cpp"
if [ -n "${SOURCE_BACKUP:-}" ] && docker exec "$C" test -d "$SOURCE_BACKUP"; then
    docker cp "$C:$SOURCE_BACKUP/." "$PKG/source-backup/"
    printf '%s\n' "$SOURCE_BACKUP" > "$PKG/SOURCE_BACKUP_PATH.txt"
fi
chmod 755 "$PKG/openmw-0.51"
(
 cd "$PKG"
 sha256sum openmw-0.51 \
  mod/TSPInteriorVisGrid/TSPInteriorVisGrid.omwscripts \
  mod/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua > SHA256SUMS.txt
)
echo
echo "===== 9/11 CONNECT + BACK UP DEVICE ====="
ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEV" 'echo "SSH PASS"; hostname; date'
if ssh "$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
    echo "ERROR: OpenMW is running."
    echo "Exit it normally and rerun this SAME V1 script."
    echo "V1 source/build/package work is preserved at: $PKG"
    exit 20
fi

DEV_SHA="$(ssh "$DEV" "sha256sum '$REMOTE_BIN' | awk '{print \$1}'")"
echo "Current device OpenMW: $DEV_SHA"

ssh "$DEV" "
set -e
mkdir -p '$REMOTE_BACKUP/config-0.51'
cp -p '$REMOTE_BIN' '$REMOTE_BACKUP/openmw-0.51'

if [ -f '$REMOTE_CONFIG/openmw.cfg' ]; then
    cp -p '$REMOTE_CONFIG/openmw.cfg' '$REMOTE_BACKUP/config-0.51/openmw.cfg'
fi
if [ -f '$REMOTE_CONFIG/openmw/openmw.cfg' ]; then
    mkdir -p '$REMOTE_BACKUP/config-0.51/openmw'
    cp -p '$REMOTE_CONFIG/openmw/openmw.cfg' '$REMOTE_BACKUP/config-0.51/openmw/openmw.cfg'
fi

if [ -d '$REMOTE_MOD' ]; then
    cp -a '$REMOTE_MOD' '$REMOTE_BACKUP/TSPInteriorVisGrid.previous'
else
    touch '$REMOTE_BACKUP/.visgrid-mod-was-absent'
fi

sha256sum '$REMOTE_BACKUP/openmw-0.51' > '$REMOTE_BACKUP/SHA256SUMS.txt'
sync
"
scp -q "$DEV:$REMOTE_BIN" "$PKG/device-backup/openmw-0.51"
sha256sum "$PKG/device-backup/openmw-0.51" > "$PKG/device-backup/SHA256SUMS.txt"
echo "PASS: device backup: $REMOTE_BACKUP"

echo
echo "===== 10/11 INSTALL V1 BINARY + SENSOR MOD ====="
scp -q "$PKG/openmw-0.51" "$DEV:/tmp/openmw-0.51-visgrid-v1"
scp -qr "$PKG/mod/TSPInteriorVisGrid" "$DEV:/tmp/TSPInteriorVisGrid-v1"

ssh "$DEV" "
set -e
test -s /tmp/openmw-0.51-visgrid-v1
test -f /tmp/TSPInteriorVisGrid-v1/TSPInteriorVisGrid.omwscripts
test -f /tmp/TSPInteriorVisGrid-v1/scripts/TSPInteriorVisGrid/visgrid.lua

cp /tmp/openmw-0.51-visgrid-v1 '$REMOTE_BIN.new'
chmod 755 '$REMOTE_BIN.new'
mv -f '$REMOTE_BIN.new' '$REMOTE_BIN'

rm -rf '$REMOTE_MOD.new'
mv /tmp/TSPInteriorVisGrid-v1 '$REMOTE_MOD.new'
rm -rf '$REMOTE_MOD'
mv '$REMOTE_MOD.new' '$REMOTE_MOD'

for cfg in '$REMOTE_CONFIG/openmw.cfg' '$REMOTE_CONFIG/openmw/openmw.cfg'; do
    mkdir -p \"\$(dirname \"\$cfg\")\"
    touch \"\$cfg\"
    tmp=\"\$cfg.visgrid-v1.tmp\"
    awk -v d='data=$REMOTE_MOD' -v c='content=TSPInteriorVisGrid.omwscripts' \
        '\$0 != d && \$0 != c { print }' \"\$cfg\" > \"\$tmp\"
    mv \"\$tmp\" \"\$cfg\"
    # Keep the new content at the end, after the existing TSPPerformance script.
    printf '%s\n' 'data=$REMOTE_MOD' >> \"\$cfg\"
    printf '%s\n' 'content=TSPInteriorVisGrid.omwscripts' >> \"\$cfg\"
done

rm -f /tmp/openmw-0.51-visgrid-v1
sync
"

echo
echo "===== 11/11 VERIFY INSTALL + CREATE TRACE/ROLLBACK HELPERS ====="
LOCAL_SHA="$(sha256sum "$PKG/openmw-0.51" | awk '{print $1}')"
REMOTE_SHA="$(ssh "$DEV" "sha256sum '$REMOTE_BIN' | awk '{print \$1}'")"
echo "OpenMW package: $LOCAL_SHA"
echo "OpenMW device : $REMOTE_SHA"
[ "$LOCAL_SHA" = "$REMOTE_SHA" ] || { echo "ERROR: device SHA mismatch."; exit 1; }

ssh "$DEV" "
set -e
grep -a -q 'TSP_INTERIOR_VISGRID_051_V1' '$REMOTE_BIN'
grep -Fq 'PLAYER: scripts/TSPInteriorVisGrid/visgrid.lua' '$REMOTE_MOD/TSPInteriorVisGrid.omwscripts'
grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V1' '$REMOTE_MOD/scripts/TSPInteriorVisGrid/visgrid.lua'
for cfg in '$REMOTE_CONFIG/openmw.cfg' '$REMOTE_CONFIG/openmw/openmw.cfg'; do
    grep -Fqx 'data=$REMOTE_MOD' \"\$cfg\"
    grep -Fqx 'content=TSPInteriorVisGrid.omwscripts' \"\$cfg\"
done
echo 'PASS: V1 engine + Lua sensor + cfg load lines installed.'
"

cat > "$PKG/collect-visgrid-v1-trace.sh" <<'EOF_TRACE'
#!/usr/bin/env bash
set -Eeuo pipefail
DEV="${TSP_DEV:-root@192.168.1.25}"
OUT="${1:-$HOME/Downloads/openmw51-visgrid-v1-trace-$(date +%Y%m%d-%H%M%S).txt}"
{
 echo "=================================================================="
 echo "OPENMW INTERIOR VISGRID V1 TRACE"
 echo "=================================================================="
 ssh "$DEV" 'hostname; date'
 echo
 echo "===== VISGRID EVENTS + CULL STATS ====="
 ssh "$DEV" '
  grep -hE "TSP_VISGRID_V1|TSP_INTERIOR_VISGRID_051_V1|TSP_INTOCC|TSP_DEPTH_PROJECTION" \
    /mnt/SDCARD/data/ports/openmw51/config-0.51/openmw.log \
    /mnt/SDCARD/tsp_prog.txt 2>/dev/null | tail -1500 || true
 '
 echo
 echo "===== PERFORMANCE TELEMETRY ====="
 ssh "$DEV" '
  for f in \
    /mnt/SDCARD/data/ports/openmw51/openmw51_perf_latest.txt \
    /mnt/SDCARD/tsp_ring.txt \
    /mnt/SDCARD/tsp_diag.txt \
    /mnt/SDCARD/tsp_state.txt
  do
   if [ -f "$f" ]; then
    echo "--- $f ---"
    tail -350 "$f"
   fi
  done
 '
 echo
 echo "===== INSTALLED HASH + CONFIG ====="
 ssh "$DEV" '
  sha256sum /mnt/SDCARD/data/ports/openmw51/bin/openmw-0.51 \
    /mnt/SDCARD/data/ports/openmw51/mods/TSPInteriorVisGrid/TSPInteriorVisGrid.omwscripts \
    /mnt/SDCARD/data/ports/openmw51/mods/TSPInteriorVisGrid/scripts/TSPInteriorVisGrid/visgrid.lua \
    2>/dev/null || true
  grep -nF "TSPInteriorVisGrid" \
    /mnt/SDCARD/data/ports/openmw51/config-0.51/openmw.cfg \
    /mnt/SDCARD/data/ports/openmw51/config-0.51/openmw/openmw.cfg \
    2>/dev/null || true
 '
} 2>&1 | tee "$OUT"
echo
echo "Trace saved:"
echo "  $OUT"
EOF_TRACE
chmod +x "$PKG/collect-visgrid-v1-trace.sh"

cat > "$PKG/rollback-visgrid-v1.sh" <<EOF_ROLL
#!/usr/bin/env bash
set -Eeuo pipefail
DEV="\${TSP_DEV:-root@192.168.1.25}"
if ssh "\$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
 echo "ERROR: exit OpenMW before rollback."
 exit 1
fi
ssh "\$DEV" '
set -e
BACKUP="$REMOTE_BACKUP"
ROOT="$REMOTE_ROOT"
CONFIG="$REMOTE_CONFIG"
MOD="$REMOTE_MOD"
test -s "\$BACKUP/openmw-0.51"
cp -p "\$BACKUP/openmw-0.51" "\$ROOT/bin/openmw-0.51"
if [ -f "\$BACKUP/config-0.51/openmw.cfg" ]; then
 cp -p "\$BACKUP/config-0.51/openmw.cfg" "\$CONFIG/openmw.cfg"
fi
if [ -f "\$BACKUP/config-0.51/openmw/openmw.cfg" ]; then
 mkdir -p "\$CONFIG/openmw"
 cp -p "\$BACKUP/config-0.51/openmw/openmw.cfg" "\$CONFIG/openmw/openmw.cfg"
fi
rm -rf "\$MOD"
if [ -d "\$BACKUP/TSPInteriorVisGrid.previous" ]; then
 cp -a "\$BACKUP/TSPInteriorVisGrid.previous" "\$MOD"
fi
sync
'
echo "Rollback complete from:"
echo "  $REMOTE_BACKUP"
EOF_ROLL
chmod +x "$PKG/rollback-visgrid-v1.sh"

cat > "$PKG/INSTALL_REPORT.txt" <<EOF_REPORT
OpenMW 0.51 TSP Interior VISGRID V1
Created: $(date)
Source state: $SOURCE_STATE
Source backup: ${SOURCE_BACKUP:-not recorded on resume}
Device backup: $REMOTE_BACKUP
Previous device OpenMW: $DEV_SHA
Installed OpenMW: $REMOTE_SHA
Grid: 8x5
Sensor: World + Door physics rays
Rays/frame: 5
Maximum depth: 5500
C++ safety padding: 350
Actors culled: no (V1)
EOF_REPORT

echo
echo "=================================================================="
echo "VISGRID V1 SUCCESSFULLY INSTALLED"
echo "=================================================================="
echo "Package:"
echo "  $PKG"
echo
echo "TEST:"
echo "  1. Go to the same known bad Caldera interior view."
echo "  2. Stand still for about ONE SECOND so the 40 tiles get confirmed."
echo "  3. Note FPS."
echo "  4. Check for missing wall/floor/ceiling/door pieces."
echo "  5. Then test a doorway, stair opening, look up/down, and a slow turn."
echo
echo "WHILE OPENMW IS STILL RUNNING after the test, collect:"
echo "  $PKG/collect-visgrid-v1-trace.sh"
echo
echo "Rollback if needed (OpenMW closed):"
echo "  $PKG/rollback-visgrid-v1.sh"
echo "=================================================================="
