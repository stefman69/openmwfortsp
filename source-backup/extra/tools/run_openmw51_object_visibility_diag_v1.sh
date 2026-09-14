#!/usr/bin/env bash
set -Eeuo pipefail

# OpenMW 0.51 / TSP
# OBJECT VISIBILITY + PAGING + ACTIVATION DIAGNOSTIC BUILD
#
# Default action: install
# Other actions:
#   rollback   restore pre-diagnostic source + device binary + launcher
#   collect    pull only this diagnostic session's logs
#
# This patches the EXACT current Docker source captured by the
# 2026-08-30 object-visibility recon. If those source hashes changed,
# it aborts before editing anything.

ACTION="${1:-install}"
CTR="${TSP_BUILDER:-openmw_builder}"
DEV="${TSP_DEV:-root@192.168.1.25}"

SRC="/root/openmw-0.51-tsp-src"
BUILD="/root/openmw-0.51-tsp-build"
BUILT_BIN="$BUILD/openmw"

ROOT="/mnt/SDCARD/data/ports/openmw51"
DEV_BIN="$ROOT/bin/openmw-0.51"
DEV_LOG="$ROOT/openmw_051_log.txt"
DEV_CONFIG_LOG="$ROOT/config-0.51/openmw.log"
DEV_BACK_POINTER="$ROOT/backups/object-diag-v1.latest"
DEV_LOG_START="$ROOT/object-diag-v1-log-start.txt"

EXPECTED_DEVICE_BIN="5ba39a9869c592f1e21349521ad19fce0a04c6d03bb378c22170929c9792c555"

STAMP="$(date +%Y%m%d-%H%M%S)"
PKG="$HOME/Downloads/openmw51-object-diag-v1-$STAMP"
BUILD_LOG="$PKG/build.log"
PATCH_LOG="$PKG/patch.log"
OUT_BIN="$PKG/openmw-0.51-object-diag-v1"
SOURCE_BACKUP="$SRC/.tsp-051-source-backups/object-diag-v1-$STAMP"
SOURCE_POINTER="/root/openmw51-object-diag-v1-source.latest"

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8)
SCP=(scp -q -o BatchMode=yes -o ConnectTimeout=8)

TARGETS=(
  "apps/openmw/mwrender/animation.cpp"
  "apps/openmw/mwrender/interiorvisibility.hpp"
  "apps/openmw/mwrender/interiorvisibility.cpp"
  "apps/openmw/mwworld/scene.cpp"
  "apps/openmw/mwrender/objectpaging.cpp"
  "apps/openmw/mwrender/renderingmanager.cpp"
  "apps/openmw/mwworld/worldimp.cpp"
)

EXPECTED_HASHES=(
  "29b95729a9d5c9040d5e3d49674ce8f5c45ac23d8feb436618d91d317fc7c3b1"
  "bb6962f5fe257b858ef756da61c045b902e0f0f76eb1969040e4d01ad769d3e1"
  "07ac8972cf9228cf0be80f7c17cf2ee71c21160b9d95ac4f0e2395986c17e505"
  "e0b5a39b603112f07bc05a08376ba2ff9606357f80db02d84a509cbd02130049"
  "ddb16fd4b493e20cd2e5fd4a1fe4dd45900f57e12a7433acbdf14578af48e807"
  "1695e3b8da27340cc70598de066bf95a6d0963912ed270179f9ada4d77dfd85d"
  "07db64a6af6e775bd56b43a801b5174be536542886c4bede57f15abe40009aed"
)

resolve_launcher() {
  "${SSH[@]}" "$DEV" '
    for p in \
      /mnt/sdcard/mmcblk1p1/Roms/PORTS/Morrowind_51.sh \
      /mnt/SDCARD/Roms/PORTS/Morrowind_51.sh \
      /mnt/SDCARD/Emus/PORTS/../../Roms/PORTS/Morrowind_51.sh
    do
      if [ -f "$p" ]; then
        readlink -f "$p" 2>/dev/null || printf "%s\n" "$p"
        exit 0
      fi
    done
    exit 1
  '
}

ensure_closed() {
  if "${SSH[@]}" "$DEV" 'pidof openmw-0.51 >/dev/null 2>&1 || pidof openmw >/dev/null 2>&1'; then
    echo "ERROR: OpenMW is running. Exit it normally first."
    exit 20
  fi
}

start_container() {
  if ! docker inspect "$CTR" >/dev/null 2>&1; then
    echo "ERROR: Docker container '$CTR' does not exist."
    exit 21
  fi
  if [ "$(docker inspect -f '{{.State.Running}}' "$CTR")" != "true" ]; then
    docker start "$CTR" >/dev/null
  fi
  docker exec "$CTR" test -d "$SRC"
}

collect_logs() {
  local OUT="$HOME/Downloads/openmw51-object-diag-$(date +%Y%m%d-%H%M%S).txt"

  {
    echo "=================================================================="
    echo "OPENMW 0.51 OBJECT DIAGNOSTIC TRACE"
    echo "=================================================================="
    echo "Collected: $(date)"
    echo "Device: $DEV"
    echo

    "${SSH[@]}" "$DEV" "
      set +e
      START=1
      if [ -s '$DEV_LOG_START' ]; then
        START=\$(cat '$DEV_LOG_START')
      fi
      case \"\$START\" in
        ''|*[!0-9]*) START=1 ;;
      esac
      START=\$((START + 1))

      echo '===== SESSION LOG MARKERS ====='
      if [ -s '$DEV_LOG' ]; then
        tail -n +\"\$START\" '$DEV_LOG' |
          grep -E \
            'TSP_OBJECT_DIAG_051_V1|\[TSP_OBJROOT\]|\[TSP_VISOBJ_ATTACH\]|\[TSP_VISOBJ_CULL\]|\[TSP_OBJINSERT\]|\[TSP_NAVOBJ\]|\[TSP_OBJPAGE_CONT\]|\[TSP_PICK_RAW\]|\[TSP_PICK_FOCUS\]|TSP_VISGRID_V23PERF|TSP_VISGRID_V23MACRO|TSP_VISGRID_V23\]' \
          || true
      fi

      echo
      echo '===== CONFIG LOG OBJECT MARKERS ====='
      grep -E \
        'TSP_OBJECT_DIAG_051_V1|\[TSP_OBJROOT\]|\[TSP_VISOBJ_ATTACH\]|\[TSP_VISOBJ_CULL\]|\[TSP_OBJINSERT\]|\[TSP_NAVOBJ\]|\[TSP_OBJPAGE_CONT\]|\[TSP_PICK_RAW\]|\[TSP_PICK_FOCUS\]' \
        '$DEV_CONFIG_LOG' 2>/dev/null | tail -12000 || true

      echo
      echo '===== CURRENT HASH / MARKER ====='
      sha256sum '$DEV_BIN' 2>/dev/null || true
      grep -aE \
        'TSP_OBJECT_DIAG_051_V1|TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS' \
        '$DEV_BIN' 2>/dev/null | head -20 || true

      echo
      echo '===== PERF TAIL ====='
      tail -500 '$ROOT/openmw51_perf_latest.txt' 2>/dev/null || true
    "
  } 2>&1 | tee "$OUT"

  echo
  echo "Saved:"
  echo "  $OUT"
}

rollback_all() {
  ensure_closed
  start_container

  local DBACK
  DBACK="$("${SSH[@]}" "$DEV" "test -s '$DEV_BACK_POINTER' && cat '$DEV_BACK_POINTER'")" || {
    echo "ERROR: no device object-diag rollback pointer."
    exit 40
  }

  local SBACK
  SBACK="$(docker exec "$CTR" bash -lc "test -s '$SOURCE_POINTER' && cat '$SOURCE_POINTER'")" || {
    echo "ERROR: no Docker source rollback pointer."
    exit 41
  }

  echo "Device backup: $DBACK"
  echo "Source backup: $SBACK"

  "${SSH[@]}" "$DEV" "
    set -e
    test -s '$DBACK/openmw-0.51.before-object-diag'
    test -s '$DBACK/Morrowind_51.sh.before-object-diag'
    test -s '$DBACK/launcher.path'

    LAUNCHER=\$(cat '$DBACK/launcher.path')

    cp -p '$DBACK/openmw-0.51.before-object-diag' '$DEV_BIN.restore'
    chmod 755 '$DEV_BIN.restore'
    mv -f '$DEV_BIN.restore' '$DEV_BIN'

    cp -p '$DBACK/Morrowind_51.sh.before-object-diag' \"\$LAUNCHER.restore\"
    chmod +x \"\$LAUNCHER.restore\"
    mv -f \"\$LAUNCHER.restore\" \"\$LAUNCHER\"

    rm -f '$DEV_LOG_START'
    sync

    echo '===== DEVICE RESTORED ====='
    sha256sum '$DEV_BIN' \"\$LAUNCHER\"
  "

  docker exec "$CTR" bash -lc "
    set -e
    for rel in \
      apps/openmw/mwrender/animation.cpp \
      apps/openmw/mwrender/interiorvisibility.hpp \
      apps/openmw/mwrender/interiorvisibility.cpp \
      apps/openmw/mwworld/scene.cpp \
      apps/openmw/mwrender/objectpaging.cpp \
      apps/openmw/mwrender/renderingmanager.cpp \
      apps/openmw/mwworld/worldimp.cpp
    do
      test -s '$SBACK/'\"\$rel\"
      cp -p '$SBACK/'\"\$rel\" '$SRC/'\"\$rel\"
    done
    rm -f '$BUILT_BIN'
    echo 'PASS: exact pre-diagnostic Docker source restored.'
  "

  echo
  echo "PASS: diagnostic binary, launcher switch, and Docker source rolled back."
}

if [ "$ACTION" = "collect" ]; then
  collect_logs
  exit 0
fi

if [ "$ACTION" = "rollback" ]; then
  rollback_all
  exit 0
fi

if [ "$ACTION" != "install" ]; then
  echo "Usage: $0 {install|collect|rollback}"
  exit 2
fi

mkdir -p "$PKG"

restore_source_on_error=0
restore_source() {
  local rc=$?
  if [ "$restore_source_on_error" = "1" ]; then
    echo
    echo "ERROR: diagnostic patch/build failed; restoring Docker source..." | tee -a "$PATCH_LOG"
    docker exec "$CTR" bash -lc "
      set +e
      for rel in \
        apps/openmw/mwrender/animation.cpp \
        apps/openmw/mwrender/interiorvisibility.hpp \
        apps/openmw/mwrender/interiorvisibility.cpp \
        apps/openmw/mwworld/scene.cpp \
        apps/openmw/mwrender/objectpaging.cpp \
        apps/openmw/mwrender/renderingmanager.cpp \
        apps/openmw/mwworld/worldimp.cpp
      do
        [ -s '$SOURCE_BACKUP/'\"\$rel\" ] && cp -p '$SOURCE_BACKUP/'\"\$rel\" '$SRC/'\"\$rel\"
      done
    "
  fi
  echo "Logs preserved in: $PKG"
  exit "$rc"
}
trap restore_source ERR

echo "=================================================================="
echo "OPENMW 0.51 OBJECT VISIBILITY / PAGING / PICK DIAGNOSTIC BUILD"
echo "=================================================================="
echo "Package: $PKG"
echo

echo "===== 1/10 PREFLIGHT ====="
start_container
ensure_closed

LAUNCHER="$(resolve_launcher)" || {
  echo "ERROR: Morrowind_51.sh not found."
  exit 22
}
echo "Launcher: $LAUNCHER"

DEV_SHA="$("${SSH[@]}" "$DEV" "sha256sum '$DEV_BIN'" | awk '{print $1}')"
echo "Device binary: $DEV_SHA"
if [ "$DEV_SHA" != "$EXPECTED_DEVICE_BIN" ]; then
  echo "ERROR: device binary changed since the recon."
  echo "Expected: $EXPECTED_DEVICE_BIN"
  echo "Got:      $DEV_SHA"
  echo "Nothing changed."
  exit 23
fi

echo
echo "===== 2/10 VERIFY EXACT CURRENT SOURCE ====="
ALREADY=1
for rel in "${TARGETS[@]}"; do
  if ! docker exec "$CTR" grep -Fq 'TSP_OBJECT_DIAG_051_V1' "$SRC/$rel"; then
    ALREADY=0
    break
  fi
done

if [ "$ALREADY" = "0" ]; then
  for i in "${!TARGETS[@]}"; do
    rel="${TARGETS[$i]}"
    expected="${EXPECTED_HASHES[$i]}"
    got="$(docker exec "$CTR" sha256sum "$SRC/$rel" | awk '{print $1}')"
    printf '%s  %s\n' "$got" "$rel"
    if [ "$got" != "$expected" ]; then
      echo
      echo "ERROR: source drift in $rel"
      echo "Expected: $expected"
      echo "Got:      $got"
      echo "Nothing changed."
      exit 24
    fi
  done
  echo "PASS: all seven source files match the uploaded recon exactly."
else
  echo "INFO: complete TSP_OBJECT_DIAG_051_V1 source already present; resuming."
fi

echo
echo "===== 3/10 BACK UP SOURCE ====="
if [ "$ALREADY" = "0" ]; then
  docker exec "$CTR" mkdir -p "$SOURCE_BACKUP"
  for rel in "${TARGETS[@]}"; do
    docker exec "$CTR" mkdir -p "$SOURCE_BACKUP/$(dirname "$rel")"
    docker exec "$CTR" cp -p "$SRC/$rel" "$SOURCE_BACKUP/$rel"
    a="$(docker exec "$CTR" sha256sum "$SRC/$rel" | awk '{print $1}')"
    b="$(docker exec "$CTR" sha256sum "$SOURCE_BACKUP/$rel" | awk '{print $1}')"
    [ "$a" = "$b" ]
  done
  docker exec "$CTR" bash -lc "printf '%s\n' '$SOURCE_BACKUP' > '$SOURCE_POINTER'"
  restore_source_on_error=1
  echo "Backup: $SOURCE_BACKUP"
else
  EXISTING="$(docker exec "$CTR" bash -lc "cat '$SOURCE_POINTER' 2>/dev/null || true")"
  echo "Existing source backup: ${EXISTING:-unknown}"
fi

echo
echo "===== 4/10 APPLY EXACT DIAGNOSTIC PATCH ====="
if [ "$ALREADY" = "0" ]; then
docker exec -i "$CTR" python3 - "$SRC" <<'PY_PATCH' | tee "$PATCH_LOG"
from pathlib import Path
import sys

root = Path(sys.argv[1])

def one(rel, old, new, label):
    p = root / rel
    s = p.read_text()
    n = s.count(old)
    if n != 1:
        raise SystemExit("ERROR: %s anchor count=%d" % (label, n))
    with p.open("w", newline="\n") as f:
        f.write(s.replace(old, new, 1))
    print("PATCH PASS:", label)

one("apps/openmw/mwrender/animation.cpp",
'''#include <algorithm>
#include <iomanip>
#include <limits>
''',
'''#include <algorithm>
#include <cstdlib>
#include <iomanip>
#include <limits>
''', "animation cstdlib")

one("apps/openmw/mwrender/animation.cpp",
'''        // TSP_INTERIOR_VISGRID_051_V1
        // The VISGRID callback is deliberately installed first, outside the
        // normal LightList callback. A rejected object therefore avoids the
        // ordinary per-object light/state traversal. Actors remain untouched.
        if (!mPtr.getClass().isActor() && !mPtr.getClass().isDoor())
        {
            // TSP_INTERIOR_VISGRID_051_V6_DOOR_BYPASS
            // Real ESM doors never enter the VISGRID screen-depth callback.
            // This is intentionally independent of topology: teleport/load
            // doors must remain drawable even when no navmesh portal exists.
            // Structural PVS already only applies to ESM::Static objects.
            // TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS
            // First prototype intentionally limits structural PVS to immutable
            // ESM3 Static refs. Dynamic objects, doors and actors keep normal
            // behavior. Very large roots bypass the PVS as well.
            const bool tspIsStatic = mPtr.get<ESM::Static>() != nullptr;
            const osg::Vec3f tspPvsOrigin = mPtr.getRefData().getPosition().asVec3();
            float tspPvsRadius = 0.f;
            if (tspIsStatic)
            {
                const osg::BoundingSphere tspBound = mObjectRoot->getBound();
                if (tspBound.valid() && std::isfinite(tspBound.radius()) && tspBound.radius() > 0.f)
                {
                    const float tspScale = std::max(0.01f, std::abs(mPtr.getCellRef().getScale()));
                    tspPvsRadius = (tspBound.center().length() + tspBound.radius()) * tspScale;
                }
            }
            const bool tspPvsEligible = tspIsStatic && std::isfinite(tspPvsRadius)
                && tspPvsRadius > 0.f && tspPvsRadius <= 900.f;
            mObjectRoot->addCullCallback(
                new InteriorVisibilityCullCallback(tspPvsOrigin, tspPvsRadius, tspPvsEligible));
        }
''',
'''        // TSP_INTERIOR_VISGRID_051_V1
        // TSP_OBJECT_DIAG_051_V1
        const char* tspObjectDiagEnv = std::getenv("TSP_OBJECT_DIAG");
        const bool tspObjectDiag = tspObjectDiagEnv != nullptr && tspObjectDiagEnv[0] == '1';
        const ESM::RefId& tspDiagRefId = mPtr.getCellRef().getRefId();
        const bool tspDiagActor = mPtr.getClass().isActor();
        const bool tspDiagDoor = mPtr.getClass().isDoor();
        const bool tspIsStatic
            = !tspDiagActor && !tspDiagDoor && mPtr.get<ESM::Static>() != nullptr;
        int tspDiagType = -1;
        std::string tspDiagId;
        if (tspObjectDiag)
        {
            static bool tspDiagBanner = false;
            if (!tspDiagBanner)
            {
                tspDiagBanner = true;
                Log(Debug::Info) << "TSP_OBJECT_DIAG_051_V1 enabled";
            }
            tspDiagId = tspDiagRefId.toDebugString();
            tspDiagType = MWBase::Environment::get().getESMStore()->findStatic(tspDiagRefId);
            Log(Debug::Info) << "[TSP_OBJROOT] id=" << tspDiagId
                             << " type=" << tspDiagType
                             << " actor=" << (tspDiagActor ? 1 : 0)
                             << " door=" << (tspDiagDoor ? 1 : 0)
                             << " static=" << (tspIsStatic ? 1 : 0)
                             << " callback=" << ((!tspDiagActor && !tspDiagDoor) ? 1 : 0)
                             << " scale=" << mPtr.getCellRef().getScale();
        }

        // The VISGRID callback is deliberately installed first, outside the
        // normal LightList callback. A rejected object therefore avoids the
        // ordinary per-object light/state traversal.
        if (!tspDiagActor && !tspDiagDoor)
        {
            // TSP_INTERIOR_VISGRID_051_V6_DOOR_BYPASS
            // TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS
            const osg::Vec3f tspPvsOrigin = mPtr.getRefData().getPosition().asVec3();
            float tspPvsRadius = 0.f;
            if (tspIsStatic)
            {
                const osg::BoundingSphere tspBound = mObjectRoot->getBound();
                if (tspBound.valid() && std::isfinite(tspBound.radius()) && tspBound.radius() > 0.f)
                {
                    const float tspScale = std::max(0.01f, std::abs(mPtr.getCellRef().getScale()));
                    tspPvsRadius = (tspBound.center().length() + tspBound.radius()) * tspScale;
                }
            }
            const bool tspPvsEligible = tspIsStatic && std::isfinite(tspPvsRadius)
                && tspPvsRadius > 0.f && tspPvsRadius <= 900.f;
            if (tspObjectDiag)
            {
                Log(Debug::Info) << "[TSP_VISOBJ_ATTACH] id=" << tspDiagId
                                 << " type=" << tspDiagType
                                 << " static=" << (tspIsStatic ? 1 : 0)
                                 << " pvsEligible=" << (tspPvsEligible ? 1 : 0)
                                 << " pvsRadius=" << tspPvsRadius
                                 << " x=" << tspPvsOrigin.x()
                                 << " y=" << tspPvsOrigin.y()
                                 << " z=" << tspPvsOrigin.z();
            }
            mObjectRoot->addCullCallback(new InteriorVisibilityCullCallback(
                tspPvsOrigin, tspPvsRadius, tspPvsEligible, std::move(tspDiagId), tspDiagType, tspIsStatic));
        }
''', "animation object diagnostics")

one("apps/openmw/mwrender/interiorvisibility.hpp",
'''#include <cstdint>
#include <span>
''',
'''#include <cstdint>
#include <span>
#include <string>
#include <utility>
''', "interiorvisibility.hpp includes")

one("apps/openmw/mwrender/interiorvisibility.hpp",
'''        InteriorVisibilityCullCallback() = default;
        InteriorVisibilityCullCallback(const osg::Vec3f& worldOrigin, float pvsRadius, bool pvsEligible)
            : mWorldOrigin(worldOrigin)
            , mPvsRadius(pvsRadius)
            , mPvsEligible(pvsEligible)
        {
        }
        InteriorVisibilityCullCallback(const InteriorVisibilityCullCallback& copy, const osg::CopyOp& copyop)
            : osg::Object(copy, copyop)
            , SceneUtil::NodeCallback<InteriorVisibilityCullCallback, osg::Node*, osgUtil::CullVisitor*>(copy, copyop)
            , mWorldOrigin(copy.mWorldOrigin)
            , mPvsRadius(copy.mPvsRadius)
            , mPvsEligible(copy.mPvsEligible)
        {
        }
''',
'''        InteriorVisibilityCullCallback() = default;
        InteriorVisibilityCullCallback(const osg::Vec3f& worldOrigin, float pvsRadius, bool pvsEligible,
            std::string diagId = {}, int diagType = -1, bool diagStatic = false)
            : mWorldOrigin(worldOrigin)
            , mPvsRadius(pvsRadius)
            , mPvsEligible(pvsEligible)
            , mDiagId(std::move(diagId))
            , mDiagType(diagType)
            , mDiagStatic(diagStatic)
        {
        }
        InteriorVisibilityCullCallback(const InteriorVisibilityCullCallback& copy, const osg::CopyOp& copyop)
            : osg::Object(copy, copyop)
            , SceneUtil::NodeCallback<InteriorVisibilityCullCallback, osg::Node*, osgUtil::CullVisitor*>(copy, copyop)
            , mWorldOrigin(copy.mWorldOrigin)
            , mPvsRadius(copy.mPvsRadius)
            , mPvsEligible(copy.mPvsEligible)
            , mDiagId(copy.mDiagId)
            , mDiagType(copy.mDiagType)
            , mDiagStatic(copy.mDiagStatic)
            , mDiagLogged(copy.mDiagLogged)
        {
        }
''', "interiorvisibility.hpp ctor")

one("apps/openmw/mwrender/interiorvisibility.hpp",
'''        osg::Vec3f mWorldOrigin{ 0.f, 0.f, 0.f };
        float mPvsRadius = 0.f;
        bool mPvsEligible = false;
''',
'''        osg::Vec3f mWorldOrigin{ 0.f, 0.f, 0.f };
        float mPvsRadius = 0.f;
        bool mPvsEligible = false;

        // TSP_OBJECT_DIAG_051_V1
        std::string mDiagId;
        int mDiagType = -1;
        bool mDiagStatic = false;
        unsigned char mDiagLogged = 0;
''', "interiorvisibility.hpp fields")

one("apps/openmw/mwrender/interiorvisibility.cpp",
'''        bool finitePositive(float value)
        {
            return std::isfinite(value) && value > 0.f;
        }
''',
'''        // TSP_OBJECT_DIAG_051_V1
        bool objectDiagEnabled()
        {
            static const bool enabled = [] {
                const char* e = std::getenv("TSP_OBJECT_DIAG");
                return e != nullptr && e[0] == '1';
            }();
            return enabled;
        }

        bool finitePositive(float value)
        {
            return std::isfinite(value) && value > 0.f;
        }
''', "interiorvisibility diag helper")

one("apps/openmw/mwrender/interiorvisibility.cpp",
'''                    if (!touchedVisibleSector)
                    {
                        sPvsCulled.fetch_add(1, std::memory_order_relaxed);
                        return;
                    }
''',
'''                    if (!touchedVisibleSector)
                    {
                        sPvsCulled.fetch_add(1, std::memory_order_relaxed);
                        if (objectDiagEnabled() && (mDiagLogged & 0x1u) == 0)
                        {
                            mDiagLogged |= 0x1u;
                            Log(Debug::Info) << "[TSP_VISOBJ_CULL] reason=PVS id=" << mDiagId
                                             << " type=" << mDiagType
                                             << " static=" << (mDiagStatic ? 1 : 0)
                                             << " pvsRadius=" << mPvsRadius
                                             << " x=" << mWorldOrigin.x()
                                             << " y=" << mWorldOrigin.y()
                                             << " z=" << mWorldOrigin.z();
                        }
                        return;
                    }
''', "PVS cull logging")

one("apps/openmw/mwrender/interiorvisibility.cpp",
'''        if (nearestSurface > static_cast<double>(allowedDepth)+safety)
        {
            sCulled.fetch_add(1,std::memory_order_relaxed);
''',
'''        if (nearestSurface > static_cast<double>(allowedDepth)+safety)
        {
            sCulled.fetch_add(1,std::memory_order_relaxed);
            if (objectDiagEnabled() && (mDiagLogged & 0x2u) == 0)
            {
                mDiagLogged |= 0x2u;
                Log(Debug::Info) << "[TSP_VISOBJ_CULL] reason=GRID id=" << mDiagId
                                 << " type=" << mDiagType
                                 << " static=" << (mDiagStatic ? 1 : 0)
                                 << " nearest=" << nearestSurface
                                 << " allowed=" << allowedDepth
                                 << " pad=" << safety
                                 << " radius=" << radius
                                 << " centerZ=" << center.z();
            }
''', "grid cull logging")

one("apps/openmw/mwworld/scene.cpp",
'''#include <atomic>
#include <chrono>
#include <limits>
''',
'''#include <atomic>
#include <chrono>
#include <cstdlib>
#include <limits>
''', "scene cstdlib")

one("apps/openmw/mwworld/scene.cpp",
'''namespace
{
    using MWWorld::RotationOrder;
''',
'''namespace
{
    using MWWorld::RotationOrder;

    // TSP_OBJECT_DIAG_051_V1
    bool tspObjectDiagEnabled()
    {
        static const bool enabled = [] {
            const char* e = std::getenv("TSP_OBJECT_DIAG");
            return e != nullptr && e[0] == '1';
        }();
        return enabled;
    }
''', "scene diag helper")

one("apps/openmw/mwworld/scene.cpp",
'''        ESM::RefNum refnum = ptr.getCellRef().getRefNum();
        if (!refnum.hasContentFile() || !std::binary_search(pagedRefs.begin(), pagedRefs.end(), refnum))
            ptr.getClass().insertObjectRendering(ptr, model, rendering);
        else
            ptr.getRefData().setBaseNode(pagedNode);
''',
'''        ESM::RefNum refnum = ptr.getCellRef().getRefNum();
        const bool tspPaged
            = refnum.hasContentFile() && std::binary_search(pagedRefs.begin(), pagedRefs.end(), refnum);

        if (tspObjectDiagEnabled())
        {
            const ESM::RefId& tspId = ptr.getCellRef().getRefId();
            const int tspType = world.getStore().findStatic(tspId);
            Log(Debug::Info) << "[TSP_OBJINSERT] id=" << tspId
                             << " type=" << tspType
                             << " exterior=" << ((ptr.getCell() && ptr.getCell()->isExterior()) ? 1 : 0)
                             << " paged=" << (tspPaged ? 1 : 0)
                             << " hasContentRef=" << (refnum.hasContentFile() ? 1 : 0)
                             << " model=" << model.value();
        }

        if (!tspPaged)
            ptr.getClass().insertObjectRendering(ptr, model, rendering);
        else
            ptr.getRefData().setBaseNode(pagedNode);
''', "scene render/paging insert")

one("apps/openmw/mwworld/scene.cpp",
'''            else if (object->getShapeInstance()->mVisualCollisionType == Resource::VisualCollisionType::None)
            {
                navigator.addObject(DetourNavigator::ObjectId(object),
                    DetourNavigator::ObjectShapes(object->getShapeInstance(), objectTransform), object->getTransform(),
                    navigatorUpdateGuard);
            }
        }
        else if (physics.getActor(ptr))
''',
'''            else if (object->getShapeInstance()->mVisualCollisionType == Resource::VisualCollisionType::None)
            {
                navigator.addObject(DetourNavigator::ObjectId(object),
                    DetourNavigator::ObjectShapes(object->getShapeInstance(), objectTransform), object->getTransform(),
                    navigatorUpdateGuard);
            }

            if (tspObjectDiagEnabled())
            {
                const ESM::RefId& tspId = ptr.getCellRef().getRefId();
                const int tspType = world.getStore().findStatic(tspId);
                const bool tspDoorNav = ptr.getClass().isDoor() && !ptr.getCellRef().getTeleport();
                const bool tspObjectNav
                    = !tspDoorNav
                    && object->getShapeInstance()->mVisualCollisionType == Resource::VisualCollisionType::None;
                Log(Debug::Info) << "[TSP_NAVOBJ] id=" << tspId
                                 << " type=" << tspType
                                 << " interior=" << (isInterior ? 1 : 0)
                                 << " physics=1"
                                 << " navMode=" << (tspDoorNav ? "door" : (tspObjectNav ? "object" : "none"));
            }
        }
        else if (physics.getActor(ptr))
''', "navigator object logging")

one("apps/openmw/mwrender/objectpaging.cpp",
'''#include <unordered_map>
#include <vector>
''',
'''#include <cstdlib>
#include <unordered_map>
#include <vector>

#include <components/debug/debuglog.hpp>
''', "objectpaging diagnostics includes")

one("apps/openmw/mwrender/objectpaging.cpp",
'''    namespace
    {
        bool typeFilter(int type, bool far)
''',
'''    namespace
    {
        // TSP_OBJECT_DIAG_051_V1
        bool tspObjectDiagEnabled()
        {
            static const bool enabled = [] {
                const char* e = std::getenv("TSP_OBJECT_DIAG");
                return e != nullptr && e[0] == '1';
            }();
            return enabled;
        }

        bool typeFilter(int type, bool far)
''', "objectpaging diag helper")

one("apps/openmw/mwrender/objectpaging.cpp",
'''            const int type = store.findStatic(ref.mRefId);
            VFS::Path::Normalized model(getModel(type, ref.mRefId, store));
            if (model.empty())
                continue;
''',
'''            const int type = store.findStatic(ref.mRefId);
            VFS::Path::Normalized model(getModel(type, ref.mRefId, store));
            if (model.empty())
                continue;

            if (activeGrid && type == ESM::REC_CONT && tspObjectDiagEnabled())
                Log(Debug::Info) << "[TSP_OBJPAGE_CONT] phase=candidate id=" << ref.mRefId
                                 << " model=" << model.value()
                                 << " x=" << ref.mPosition.x()
                                 << " y=" << ref.mPosition.y()
                                 << " z=" << ref.mPosition.z();
''', "objectpaging container candidate")

one("apps/openmw/mwrender/objectpaging.cpp",
'''                else
                    refnumSet->mRefnums.push_back(refNum);
            }
''',
'''                else
                {
                    refnumSet->mRefnums.push_back(refNum);
                    if (type == ESM::REC_CONT && tspObjectDiagEnabled())
                        Log(Debug::Info) << "[TSP_OBJPAGE_CONT] phase=accepted id=" << ref.mRefId
                                         << " updateTraversal=0";
                }
            }
''', "objectpaging container accepted")

one("apps/openmw/mwrender/objectpaging.cpp",
'''                if (activeGrid)
                {
                    if (merge)
                    {
                        AddRefnumMarkerVisitor visitor(ref.mRefNum);
                        trans->accept(visitor);
                    }
                    else
                    {
                        osg::ref_ptr<RefnumMarker> marker = new RefnumMarker;
                        marker->mRefnum = ref.mRefNum;
                        trans->getOrCreateUserDataContainer()->addUserObject(marker);
                    }
                }
''',
'''                if (activeGrid)
                {
                    if (merge)
                    {
                        AddRefnumMarkerVisitor visitor(ref.mRefNum);
                        trans->accept(visitor);
                    }
                    else
                    {
                        osg::ref_ptr<RefnumMarker> marker = new RefnumMarker;
                        marker->mRefnum = ref.mRefNum;
                        trans->getOrCreateUserDataContainer()->addUserObject(marker);
                    }

                    if (tspObjectDiagEnabled() && store.findStatic(ref.mRefId) == ESM::REC_CONT)
                        Log(Debug::Info) << "[TSP_OBJPAGE_CONT] phase=marker id=" << ref.mRefId
                                         << " merge=" << (merge ? 1 : 0);
                }
''', "objectpaging container marker")

one("apps/openmw/mwrender/renderingmanager.cpp",
'''#include <cmath>
#include <algorithm>
''',
'''#include <cmath>
#include <algorithm>
#include <cstdint>
''', "renderingmanager cstdint")

one("apps/openmw/mwrender/renderingmanager.cpp",
'''namespace
{
    // TSP_ACTUAL_RENDER_RES_PROBE_051_V25
''',
'''namespace
{
    // TSP_OBJECT_DIAG_051_V1
    bool tspObjectDiagEnabled()
    {
        static const bool enabled = [] {
            const char* e = std::getenv("TSP_OBJECT_DIAG");
            return e != nullptr && e[0] == '1';
        }();
        return enabled;
    }

    // TSP_ACTUAL_RENDER_RES_PROBE_051_V25
''', "renderingmanager diag helper")

one("apps/openmw/mwrender/renderingmanager.cpp",
'''        mViewer->getCamera()->accept(*getIntersectionVisitor(intersector, ignorePlayer, ignoreActors));

        return getIntersectionResult(intersector, mIntersectionVisitor);
''',
'''        mViewer->getCamera()->accept(*getIntersectionVisitor(intersector, ignorePlayer, ignoreActors));

        RayResult tspResult = getIntersectionResult(intersector, mIntersectionVisitor);
        if (tspObjectDiagEnabled())
        {
            static std::uint64_t tspPickSample = 0;
            ++tspPickSample;
            if ((tspPickSample % 15u) == 0u || tspResult.mHitRefnum.isSet())
                Log(Debug::Info) << "[TSP_PICK_RAW] rawIntersections="
                                 << (intersector->containsIntersections() ? 1 : 0)
                                 << " hit=" << (tspResult.mHit ? 1 : 0)
                                 << " ptr=" << (!tspResult.mHitObject.isEmpty() ? 1 : 0)
                                 << " refnum=" << (tspResult.mHitRefnum.isSet() ? 1 : 0)
                                 << " ratio=" << tspResult.mRatio
                                 << " maxDistance=" << maxDistance;
        }
        return tspResult;
''', "activation raw pick logging")

one("apps/openmw/mwworld/worldimp.cpp",
'''#include <cstdlib>

#include <charconv>
''',
'''#include <cstdlib>
#include <cstdint>

#include <charconv>
''', "worldimp cstdint")

one("apps/openmw/mwworld/worldimp.cpp",
'''        focusObject = rayToObject.mHitObject;
        if (focusObject.isEmpty() && rayToObject.mHitRefnum.isSet())
            focusObject = MWBase::Environment::get().getWorldModel()->getPtr(rayToObject.mHitRefnum);
        if (rayToObject.mHit)
            mDistanceToFocusObject = (rayToObject.mRatio * maxDistance) - camDist;
        else
            mDistanceToFocusObject = -1;
        return focusObject;
''',
'''        focusObject = rayToObject.mHitObject;
        const bool tspFocusFromPtr = !focusObject.isEmpty();
        const bool tspFocusFromRefnum = focusObject.isEmpty() && rayToObject.mHitRefnum.isSet();
        if (tspFocusFromRefnum)
            focusObject = MWBase::Environment::get().getWorldModel()->getPtr(rayToObject.mHitRefnum);
        if (rayToObject.mHit)
            mDistanceToFocusObject = (rayToObject.mRatio * maxDistance) - camDist;
        else
            mDistanceToFocusObject = -1;

        // TSP_OBJECT_DIAG_051_V1
        const char* tspObjectDiagEnv = std::getenv("TSP_OBJECT_DIAG");
        if (tspObjectDiagEnv != nullptr && tspObjectDiagEnv[0] == '1')
        {
            static std::uint64_t tspFocusSample = 0;
            ++tspFocusSample;
            if ((tspFocusSample % 15u) == 0u || tspFocusFromRefnum)
            {
                Log(Debug::Info) << "[TSP_PICK_FOCUS] rawHit=" << (rayToObject.mHit ? 1 : 0)
                                 << " source="
                                 << (tspFocusFromPtr ? "ptr" : (tspFocusFromRefnum ? "refnum" : "none"))
                                 << " final=" << (!focusObject.isEmpty() ? 1 : 0)
                                 << " id="
                                 << (!focusObject.isEmpty()
                                         ? focusObject.getCellRef().getRefId().toDebugString()
                                         : std::string("<none>"))
                                 << " dist=" << mDistanceToFocusObject;
            }
        }
        return focusObject;
''', "resolved focus logging")

for rel in (
    "apps/openmw/mwrender/animation.cpp",
    "apps/openmw/mwrender/interiorvisibility.hpp",
    "apps/openmw/mwrender/interiorvisibility.cpp",
    "apps/openmw/mwworld/scene.cpp",
    "apps/openmw/mwrender/objectpaging.cpp",
    "apps/openmw/mwrender/renderingmanager.cpp",
    "apps/openmw/mwworld/worldimp.cpp",
):
    text = (root / rel).read_text()
    if "TSP_OBJECT_DIAG_051_V1" not in text:
        raise SystemExit("ERROR: diagnostic marker missing after patch: " + rel)
    if text.count("{") != text.count("}"):
        raise SystemExit("ERROR: brace count changed/imbalanced: " + rel)

print("PASS: all diagnostic source candidates written.")
PY_PATCH

restore_source_on_error=1
else
  echo "Source already patched."
fi

echo
echo "===== 5/10 INCREMENTAL BUILD ====="
PRE_SHA=""
if docker exec "$CTR" test -s "$BUILT_BIN"; then
  PRE_SHA="$(docker exec "$CTR" sha256sum "$BUILT_BIN" | awk '{print $1}')"
fi
echo "Pre-build SHA: ${PRE_SHA:-none}"

set +e
docker exec "$CTR" bash -lc "cmake --build '$BUILD' --target openmw -j2" \
  > >(tee "$BUILD_LOG") 2>&1
BUILD_RC=$?
set -e
if [ "$BUILD_RC" -ne 0 ]; then
  echo "ERROR: build failed with code $BUILD_RC"
  false
fi

docker exec "$CTR" test -s "$BUILT_BIN"
NEW_SHA="$(docker exec "$CTR" sha256sum "$BUILT_BIN" | awk '{print $1}')"
echo "Post-build SHA: $NEW_SHA"

docker exec "$CTR" bash -lc "
  set -e
  file '$BUILT_BIN'
  file '$BUILT_BIN' | grep -Eqi 'aarch64'
  grep -a -q 'TSP_OBJECT_DIAG_051_V1 enabled' '$BUILT_BIN'
  grep -a -q '\\[TSP_VISOBJ_CULL\\]' '$BUILT_BIN'
  grep -a -q '\\[TSP_OBJPAGE_CONT\\]' '$BUILT_BIN'
  grep -a -q '\\[TSP_PICK_FOCUS\\]' '$BUILT_BIN'
  grep -a -q 'TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS' '$BUILT_BIN'
"
echo "PASS: AArch64 diagnostic binary + required markers verified."

echo
echo "===== 6/10 COPY BINARY DOCKER -> UBUNTU ====="
docker cp "$CTR:$BUILT_BIN" "$OUT_BIN"
chmod +x "$OUT_BIN"
test "$(sha256sum "$OUT_BIN" | awk '{print $1}')" = "$NEW_SHA"
echo "PASS: $OUT_BIN"

echo
echo "===== 7/10 BACK UP DEVICE ====="
DEVICE_BACK="$ROOT/backups/object-diag-v1-$STAMP"

"${SSH[@]}" "$DEV" "
  set -e
  mkdir -p '$DEVICE_BACK'
  cp -p '$DEV_BIN' '$DEVICE_BACK/openmw-0.51.before-object-diag'
  cp -p '$LAUNCHER' '$DEVICE_BACK/Morrowind_51.sh.before-object-diag'
  printf '%s\n' '$LAUNCHER' > '$DEVICE_BACK/launcher.path'
  sha256sum '$DEV_BIN' '$LAUNCHER' > '$DEVICE_BACK/SHA256SUMS.before.txt'
  wc -l < '$DEV_LOG' > '$DEV_LOG_START' 2>/dev/null || echo 0 > '$DEV_LOG_START'
  printf '%s\n' '$DEVICE_BACK' > '$DEV_BACK_POINTER'
  sync
"
echo "Backup: $DEVICE_BACK"

echo
echo "===== 8/10 INSTALL BINARY + ENABLE ONLY OBJECT DIAGNOSTICS ====="
"${SCP[@]}" "$OUT_BIN" "$DEV:/tmp/openmw-0.51-object-diag-v1"
"${SCP[@]}" "$DEV:$LAUNCHER" "$PKG/Morrowind_51.before-object-diag.sh"

python3 - "$PKG/Morrowind_51.before-object-diag.sh" "$PKG/Morrowind_51.object-diag.sh" <<'PY_LAUNCHER'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text(encoding="utf-8", errors="surrogateescape")

if "export TSP_OBJECT_DIAG=1" in src:
    out = src
else:
    anchor = "export TSP_TEXTURE_DEBUG=0\n"
    if src.count(anchor) != 1:
        raise SystemExit("ERROR: quiet-diagnostics launcher anchor count=%d" % src.count(anchor))
    out = src.replace(
        anchor,
        anchor
        + "export TSP_OBJECT_DIAG=1  # TSP_OBJECT_DIAG_051_V1 temporary object/render/pick trace\n",
        1,
    )

with open(
    sys.argv[2], "w", encoding="utf-8", errors="surrogateescape", newline="\n"
) as f:
    f.write(out)
PY_LAUNCHER

bash -n "$PKG/Morrowind_51.object-diag.sh"
"${SCP[@]}" "$PKG/Morrowind_51.object-diag.sh" "$DEV:/tmp/Morrowind_51.object-diag.sh"

"${SSH[@]}" "$DEV" "
  set -e

  test \"\$(sha256sum /tmp/openmw-0.51-object-diag-v1 | awk '{print \$1}')\" = '$NEW_SHA'
  grep -a -q 'TSP_OBJECT_DIAG_051_V1 enabled' /tmp/openmw-0.51-object-diag-v1
  grep -Fq 'export TSP_OBJECT_DIAG=1' /tmp/Morrowind_51.object-diag.sh

  cp -f /tmp/openmw-0.51-object-diag-v1 '$DEV_BIN.new'
  chmod 755 '$DEV_BIN.new'
  mv -f '$DEV_BIN.new' '$DEV_BIN'

  cp -f /tmp/Morrowind_51.object-diag.sh '$LAUNCHER.new'
  chmod +x '$LAUNCHER.new'
  mv -f '$LAUNCHER.new' '$LAUNCHER'

  rm -f /tmp/openmw-0.51-object-diag-v1 /tmp/Morrowind_51.object-diag.sh
  sync

  test \"\$(sha256sum '$DEV_BIN' | awk '{print \$1}')\" = '$NEW_SHA'
  grep -Fq 'export TSP_OBJECT_DIAG=1' '$LAUNCHER'
"
echo "PASS: diagnostic binary installed and TSP_OBJECT_DIAG=1 enabled."

echo
echo "===== 9/10 WRITE COLLECTOR + ROLLBACK HELPERS ====="
cat > "$HOME/Downloads/pull_openmw51_object_diag.sh" <<EOF_PULL
#!/usr/bin/env bash
set -Eeuo pipefail
exec "$HOME/Downloads/$(basename "$0")" collect
EOF_PULL
chmod +x "$HOME/Downloads/pull_openmw51_object_diag.sh"

cat > "$HOME/Downloads/rollback_openmw51_object_diag.sh" <<EOF_ROLL
#!/usr/bin/env bash
set -Eeuo pipefail
exec "$HOME/Downloads/$(basename "$0")" rollback
EOF_ROLL
chmod +x "$HOME/Downloads/rollback_openmw51_object_diag.sh"

restore_source_on_error=0

echo
echo "===== 10/10 FINAL VERIFY ====="
"${SSH[@]}" "$DEV" "
  sha256sum '$DEV_BIN' '$LAUNCHER'
  echo
  grep -aE \
    'TSP_OBJECT_DIAG_051_V1 enabled|\\[TSP_VISOBJ_CULL\\]|\\[TSP_OBJPAGE_CONT\\]|\\[TSP_PICK_FOCUS\\]' \
    '$DEV_BIN' 2>/dev/null | head -20
  echo
  grep -n 'TSP_OBJECT_DIAG' '$LAUNCHER'
"

echo
echo "=================================================================="
echo "OBJECT DIAGNOSTIC BUILD INSTALLED"
echo "=================================================================="
echo
echo "Short test only; logging is intentionally heavy."
echo
echo "Recommended route:"
echo "  1. Load an interior where books/containers/clutter are missing."
echo "  2. Slowly look across the missing-object areas for ~15 seconds."
echo "  3. Go outside to one visible-but-unusable container."
echo "  4. Aim directly at it for ~10 seconds and try Activate several times."
echo "  5. Exit OpenMW normally."
echo
echo "Then collect:"
echo "  cd ~/Downloads"
echo "  ./pull_openmw51_object_diag.sh"
echo
echo "Rollback afterward:"
echo "  cd ~/Downloads"
echo "  ./rollback_openmw51_object_diag.sh"
echo
echo "Build/install package:"
echo "  $PKG"
echo "=================================================================="
