#include "interiorvisibility.hpp"
#include <cstdlib>

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
        // TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG
        std::atomic<float> sFogGuide{ 0.f };
        // TSP_INTERIOR_VISGRID_051_V4_CULLFOG
        std::atomic<float> sCullNear{ 0.f };
        std::array<std::atomic<float>, sInteriorVisibilityMaxTiles> sDepths{};
        std::atomic<std::uint64_t> sTested{ 0 };
        std::atomic<std::uint64_t> sCulled{ 0 };

        // TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS
        constexpr int sPvsMaxSectors = 64;
        constexpr int sPvsBoxStride = 6;
        std::atomic<bool> sPvsEnabled{ false };
        std::atomic<int> sPvsSectorCount{ 0 };
        std::atomic<int> sPvsActiveCount{ 0 };
        std::atomic<std::uint64_t> sPvsVisibleMask{ 0 };
        std::atomic<float> sPvsXyPadding{ 0.f };
        std::atomic<float> sPvsZPadding{ 0.f };
        std::array<std::atomic<float>, sPvsMaxSectors * sPvsBoxStride> sPvsBoxes{};
        std::atomic<std::uint64_t> sPvsTested{ 0 };
        std::atomic<std::uint64_t> sPvsCulled{ 0 };

        // TSP_OBJECT_DIAG_051_V1
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

        // TSP_VISGRID_ROOM_RESIDENCY_051_V24
        bool pvsOriginOverlapsSector(const osg::Vec3f& origin, float radius, int sector, bool structural)
        {
            const int base = sector * sPvsBoxStride;
            const float minX = sPvsBoxes[static_cast<std::size_t>(base + 0)].load(std::memory_order_relaxed);
            const float minY = sPvsBoxes[static_cast<std::size_t>(base + 1)].load(std::memory_order_relaxed);
            const float minZ = sPvsBoxes[static_cast<std::size_t>(base + 2)].load(std::memory_order_relaxed);
            const float maxX = sPvsBoxes[static_cast<std::size_t>(base + 3)].load(std::memory_order_relaxed);
            const float maxY = sPvsBoxes[static_cast<std::size_t>(base + 4)].load(std::memory_order_relaxed);
            const float maxZ = sPvsBoxes[static_cast<std::size_t>(base + 5)].load(std::memory_order_relaxed);

            if (!std::isfinite(minX) || !std::isfinite(minY) || !std::isfinite(minZ)
                || !std::isfinite(maxX) || !std::isfinite(maxY) || !std::isfinite(maxZ))
                return false;

            const float configuredXy = sPvsXyPadding.load(std::memory_order_relaxed);
            const float configuredZ = sPvsZPadding.load(std::memory_order_relaxed);
            const float pvsXy = structural ? configuredXy : std::min(configuredXy, 96.f);
            const float pvsZ = structural ? configuredZ : std::min(configuredZ, 64.f);
            const float xy = std::max(0.f, radius) + std::max(0.f, pvsXy);
            const float z = std::max(0.f, radius) + std::max(0.f, pvsZ);

            return origin.x() + xy >= minX && origin.x() - xy <= maxX
                && origin.y() + xy >= minY && origin.y() - xy <= maxY
                && origin.z() + z >= minZ && origin.z() - z <= maxZ;
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
        // TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG
        // Fog follows the SHALLOW MAJORITY of the curtain, not its deepest
        // doorway tile. Projection correctness still uses farFloor.
        std::array<float, sInteriorVisibilityMaxTiles> tspFogDepths{};
        for (int i = 0; i < count; ++i)
        {
            float d = depths[static_cast<std::size_t>(i)];
            if (!finitePositive(d))
                d = std::numeric_limits<float>::max() / 1024.f;
            sDepths[static_cast<std::size_t>(i)].store(d, std::memory_order_relaxed);
            tspFogDepths[static_cast<std::size_t>(i)] = d;
            farFloor = std::max(farFloor, d);
        }

        std::sort(tspFogDepths.begin(), tspFogDepths.begin() + count);
        // 75th percentile: up to one quarter of the screen may be a genuinely
        // deep doorway/corridor without pushing the fog wall to that depth.
        const int tspFogIndex = std::clamp(
            static_cast<int>(std::ceil(static_cast<float>(count) * 0.75f)) - 1,
            0, count - 1);
        const float tspFogGuide = tspFogDepths[static_cast<std::size_t>(tspFogIndex)];

        sCols.store(cols, std::memory_order_relaxed);
        sRows.store(rows, std::memory_order_relaxed);
        sPadding.store(std::max(0.f, padding), std::memory_order_relaxed);
        sFarFloor.store(farFloor, std::memory_order_relaxed);
        sFogGuide.store(tspFogGuide, std::memory_order_relaxed);
        sEnabled.store(true, std::memory_order_release);

        if (!wasEnabled)
            Log(Debug::Info) << "TSP_INTERIOR_VISGRID_051_V1 active cols=" << cols
                             << " rows=" << rows << " far_floor=" << farFloor
                             << " padding=" << std::max(0.f, padding);
    }

    void setInteriorTopologyPvs(std::span<const float> boxes,
        std::span<const int> activeSectorIds, float xyPadding, float zPadding)
    {
        if (boxes.empty() || boxes.size() % sPvsBoxStride != 0)
        {
            clearInteriorTopologyPvs();
            return;
        }

        const int sectorCount = static_cast<int>(boxes.size() / sPvsBoxStride);
        if (sectorCount <= 0 || sectorCount > sPvsMaxSectors)
        {
            clearInteriorTopologyPvs();
            return;
        }

        std::uint64_t visibleMask = 0;
        int activeCount = 0;
        for (int id : activeSectorIds)
        {
            if (id <= 0 || id > sectorCount)
            {
                clearInteriorTopologyPvs();
                return;
            }
            const std::uint64_t bit = std::uint64_t{ 1 } << (id - 1);
            if ((visibleMask & bit) == 0)
            {
                visibleMask |= bit;
                ++activeCount;
            }
        }
        if (visibleMask == 0)
        {
            clearInteriorTopologyPvs();
            return;
        }

        for (float value : boxes)
        {
            if (!std::isfinite(value))
            {
                clearInteriorTopologyPvs();
                return;
            }
        }

        const bool wasEnabled = sPvsEnabled.exchange(false, std::memory_order_acq_rel);
        for (std::size_t i = 0; i < boxes.size(); ++i)
            sPvsBoxes[i].store(boxes[i], std::memory_order_relaxed);

        sPvsSectorCount.store(sectorCount, std::memory_order_relaxed);
        sPvsActiveCount.store(activeCount, std::memory_order_relaxed);
        sPvsVisibleMask.store(visibleMask, std::memory_order_relaxed);
        sPvsXyPadding.store(std::max(0.f, xyPadding), std::memory_order_relaxed);
        sPvsZPadding.store(std::max(0.f, zPadding), std::memory_order_relaxed);
        sPvsEnabled.store(true, std::memory_order_release);

        if (!wasEnabled)
            Log(Debug::Info) << "TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS active sectors="
                             << sectorCount << " visible=" << activeCount
                             << " xy_pad=" << std::max(0.f, xyPadding)
                             << " z_pad=" << std::max(0.f, zPadding);
    }

    void clearInteriorTopologyPvs()
    {
        const bool wasEnabled = sPvsEnabled.exchange(false, std::memory_order_acq_rel);
        sPvsSectorCount.store(0, std::memory_order_relaxed);
        sPvsActiveCount.store(0, std::memory_order_relaxed);
        sPvsVisibleMask.store(0, std::memory_order_relaxed);
        if (wasEnabled)
            Log(Debug::Info) << "TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS inactive";
    }


    // TSP_ROOM_OBJECT_LIFECYCLE_051_V25
    bool isInteriorTopologyPvsEnabled()
    {
        return sPvsEnabled.load(std::memory_order_acquire);
    }

    bool isInteriorTopologyObjectResident(
        const osg::Vec3f& origin, float radius, bool structural)
    {
        if (!sPvsEnabled.load(std::memory_order_acquire))
            return true;

        const int sectorCount = sPvsSectorCount.load(std::memory_order_relaxed);
        const std::uint64_t visibleMask = sPvsVisibleMask.load(std::memory_order_relaxed);
        if (sectorCount <= 0 || sectorCount > sPvsMaxSectors || visibleMask == 0)
            return true;

        bool touchedMappedSector = false;
        int nearestSector = -1;
        float nearestD2 = std::numeric_limits<float>::infinity();

        for (int sector = 0; sector < sectorCount; ++sector)
        {
            bool overlaps = false;
            if (structural)
            {
                overlaps = pvsOriginOverlapsSector(origin, radius, sector, true);
            }
            else
            {
                // TSP_ROOM_OBJECT_ADAPTIVE_051_V27
                // Direct clutter ownership has ZERO XY bleed. Z slack only associates
                // shelf/tabletop clutter with the walkable room underneath it.
                const int base = sector * 6;
                const float minX = sPvsBoxes[static_cast<std::size_t>(base + 0)].load(std::memory_order_relaxed);
                const float minY = sPvsBoxes[static_cast<std::size_t>(base + 1)].load(std::memory_order_relaxed);
                const float minZ = sPvsBoxes[static_cast<std::size_t>(base + 2)].load(std::memory_order_relaxed);
                const float maxX = sPvsBoxes[static_cast<std::size_t>(base + 3)].load(std::memory_order_relaxed);
                const float maxY = sPvsBoxes[static_cast<std::size_t>(base + 4)].load(std::memory_order_relaxed);
                const float maxZ = sPvsBoxes[static_cast<std::size_t>(base + 5)].load(std::memory_order_relaxed);
                if (!std::isfinite(minX) || !std::isfinite(minY) || !std::isfinite(minZ)
                    || !std::isfinite(maxX) || !std::isfinite(maxY) || !std::isfinite(maxZ))
                    continue;

                // TSP_ROOM_LIGHT_KEEPALIVE_051_V30_R5
                // radius=0 preserves exact V27/V30 clutter ownership. Positive radius
                // is used only by ESM Light refs and expands XY around active sectors.
                // Z remains tight to avoid waking lights on another floor.
                const float xyPad = radius > 0.f ? radius : 0.f;
                const float zSlack = radius > 0.f ? 100.f : 110.f;
                overlaps = origin.x() >= minX - xyPad && origin.x() <= maxX + xyPad
                    && origin.y() >= minY - xyPad && origin.y() <= maxY + xyPad
                    && origin.z() >= minZ - zSlack && origin.z() <= maxZ + zSlack;

                // Distance to the AABB, not its center. This is only an OWNERSHIP
                // fallback; it is not a near-player render radius and cannot make an
                // object resident by itself.
                const float dx = origin.x() < minX ? minX - origin.x()
                    : (origin.x() > maxX ? origin.x() - maxX : 0.f);
                const float dy = origin.y() < minY ? minY - origin.y()
                    : (origin.y() > maxY ? origin.y() - maxY : 0.f);
                const float loZ = minZ - zSlack;
                const float hiZ = maxZ + zSlack;
                const float dz = origin.z() < loZ ? loZ - origin.z()
                    : (origin.z() > hiZ ? origin.z() - hiZ : 0.f);
                const float d2 = dx * dx + dy * dy + dz * dz;
                if (d2 < nearestD2)
                {
                    nearestD2 = d2;
                    nearestSector = sector;
                }
            }

            if (!overlaps)
                continue;
            touchedMappedSector = true;
            if ((visibleMask & (std::uint64_t{ 1 } << sector)) != 0)
                return true;
        }

        if (touchedMappedSector)
            return false;

        // TSP_ROOM_OBJECT_FLOOR_AUTHORITY_051_V30
        // If this interior has valid topology boxes, every eligible clutter object
        // belongs to its nearest room/connector sector even when its origin is high
        // above the thin navmesh AABB. This removes V27's >260-unit permanent-resident
        // escape hatch while avoiding V26's blanket fail-closed behavior in Balmora.
        if (!structural && nearestSector >= 0)
            return (visibleMask & (std::uint64_t{ 1 } << nearestSector)) != 0;

        // No usable topology sector at all: fail open for safety.
        return true;
    }

    void clearInteriorVisibilityGrid()
    {
        const bool wasEnabled = sEnabled.exchange(false, std::memory_order_acq_rel);
        sCols.store(0, std::memory_order_relaxed);
        sRows.store(0, std::memory_order_relaxed);
        sFarFloor.store(0.f, std::memory_order_relaxed);
        sFogGuide.store(0.f, std::memory_order_relaxed);
        sCullNear.store(0.f, std::memory_order_relaxed);
        // Never allow a structural PVS to survive a load/exterior transition.
        clearInteriorTopologyPvs();
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

    // TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG
    float getInteriorVisibilityFogGuide()
    {
        return sFogGuide.load(std::memory_order_relaxed);
    }

    // TSP_INTERIOR_VISGRID_051_V4_CULLFOG
    float takeInteriorVisibilityCullNear()
    {
        return sCullNear.exchange(0.f, std::memory_order_relaxed);
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
        out.mPvsEnabled = sPvsEnabled.load(std::memory_order_acquire);
        out.mPvsSectorCount = sPvsSectorCount.load(std::memory_order_relaxed);
        out.mPvsActiveCount = sPvsActiveCount.load(std::memory_order_relaxed);
        out.mPvsTested = sPvsTested.load(std::memory_order_relaxed);
        out.mPvsCulled = sPvsCulled.load(std::memory_order_relaxed);
        return out;
    }

    void resetInteriorVisibilityStats()
    {
        sTested.store(0, std::memory_order_relaxed);
        sCulled.store(0, std::memory_order_relaxed);
        sPvsTested.store(0, std::memory_order_relaxed);
        sPvsCulled.store(0, std::memory_order_relaxed);
    }

    void InteriorVisibilityCullCallback::operator()(osg::Node* node, osgUtil::CullVisitor* cv)
    {
        const bool gridEnabled = sEnabled.load(std::memory_order_acquire);
        const bool pvsEnabled = sPvsEnabled.load(std::memory_order_acquire);
        if ((!gridEnabled && !pvsEnabled) || node == nullptr || cv == nullptr)
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

        // TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS
        // Room residency applies to safe non-actor/non-door roots; structural roots keep wider padding.
        // Reject only if the padded placement sphere overlaps mapped sectors
        // and every overlapped sector is outside the active PVS.
        if (pvsEnabled && mPvsEligible && std::isfinite(mPvsRadius) && mPvsRadius > 0.f)
        {
            const int sectorCount = sPvsSectorCount.load(std::memory_order_relaxed);
            const std::uint64_t visibleMask = sPvsVisibleMask.load(std::memory_order_relaxed);
            if (sectorCount > 0 && sectorCount <= sPvsMaxSectors && visibleMask != 0)
            {
                bool touchedMappedSector = false;
                bool touchedVisibleSector = false;
                for (int sector = 0; sector < sectorCount; ++sector)
                {
                    if (!pvsOriginOverlapsSector(
                            mWorldOrigin, mPvsRadius, sector, mPvsStructural))
                        continue;
                    touchedMappedSector = true;
                    if ((visibleMask & (std::uint64_t{ 1 } << sector)) != 0)
                    {
                        touchedVisibleSector = true;
                        break;
                    }
                }

                if (touchedMappedSector)
                {
                    sPvsTested.fetch_add(1, std::memory_order_relaxed);
                    if (!touchedVisibleSector)
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
                }
            }
        }

        if (!gridEnabled)
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
            // TSP_INTERIOR_VISGRID_051_V4B_BORDERFOG
            // Fog exists to hide POP-RISK holes. A rejection far behind the
            // curtain (deep behind a drawn wall) can never appear on screen,
            // so it must not pull the fog wall in - V12 fed EVERY rejection
            // into the fog distance, which parked dense fog just past the
            // nearest wall whenever the curtain was working well. Only a
            // rejection within BORDER units of its own curtain edge - the
            // band where a stale bin could genuinely reveal a hole - feeds
            // the fog distance now.
            //   TSP_VISGRID_FOG_BORDER=<units>  default 700
            //   (huge value = V12 behaviour, 0 = exact-edge rejections only)
            {
                static bool tspBorderRead = false;
                static double tspBorder = 700.0;
                if (!tspBorderRead)
                {
                    tspBorderRead = true;
                    const char* tspEnvB = std::getenv("TSP_VISGRID_FOG_BORDER");
                    if (tspEnvB != nullptr)
                    {
                        const double tspB = std::strtod(tspEnvB, nullptr);
                        if (tspB >= 0.0)
                            tspBorder = tspB;
                    }
                    // Logged once per process. This also puts the marker in
                    // .rodata so the installer's binary check has something
                    // real to find - a // comment never reaches the binary.
                    Log(Debug::Info)
                        << "TSP_INTERIOR_VISGRID_051_V4B_BORDERFOG border=" << tspBorder;
                }
                if (nearestSurface < static_cast<double>(allowedDepth) + safety + tspBorder)
                {
                    const float tspNear = static_cast<float>(nearestSurface);
                    float tspPrev = sCullNear.load(std::memory_order_relaxed);
                    while ((tspPrev <= 0.f || tspNear < tspPrev)
                        && !sCullNear.compare_exchange_weak(
                            tspPrev, tspNear, std::memory_order_relaxed))
                    {
                    }
                }
            }
            return;
        }

        traverse(node, cv);
    }
}
