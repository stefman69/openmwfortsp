#ifndef OPENMW_MWRENDER_INTERIORVISIBILITY_H
#define OPENMW_MWRENDER_INTERIORVISIBILITY_H

// TSP_INTERIOR_VISGRID_051_V1

#include <components/sceneutil/nodecallback.hpp>

#include <osg/Vec3f>

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

        // TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS
        bool mPvsEnabled = false;
        int mPvsSectorCount = 0;
        int mPvsActiveCount = 0;
        std::uint64_t mPvsTested = 0;
        std::uint64_t mPvsCulled = 0;
    };

    void setInteriorVisibilityGrid(int cols, int rows, std::span<const float> depths, float padding);

    // TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS
    // Flat sector boxes are [minX,minY,minZ,maxX,maxY,maxZ] in sector-id
    // order. activeSectorIds are 1-based topology sector ids.
    void setInteriorTopologyPvs(std::span<const float> boxes,
        std::span<const int> activeSectorIds, float xyPadding, float zPadding);
    void clearInteriorTopologyPvs();
    void clearInteriorVisibilityGrid();
    bool isInteriorVisibilityGridEnabled();
    float getInteriorVisibilityFarFloor();
    // TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG
    float getInteriorVisibilityFogGuide();
    // TSP_INTERIOR_VISGRID_051_V4_CULLFOG
    // Nearest surface among objects the curtain actually rejected since
    // the last call; reads and resets. 0 means nothing was rejected.
    float takeInteriorVisibilityCullNear();
    InteriorVisibilityStats getInteriorVisibilityStats();
    void resetInteriorVisibilityStats();

    class InteriorVisibilityCullCallback
        : public SceneUtil::NodeCallback<InteriorVisibilityCullCallback, osg::Node*, osgUtil::CullVisitor*>
    {
    public:
        InteriorVisibilityCullCallback() = default;
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

        META_Object(MWRender, InteriorVisibilityCullCallback)

        void operator()(osg::Node* node, osgUtil::CullVisitor* cv);

    private:
        osg::Vec3f mWorldOrigin{ 0.f, 0.f, 0.f };
        float mPvsRadius = 0.f;
        bool mPvsEligible = false;
    };
}

#endif
