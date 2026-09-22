#include "occlusionculling.hpp"

#include "objects.hpp"

#include <algorithm>
#include <cmath>
#include <chrono>
#include <cstdlib>
#include <map>
#include <vector>
#include <osg/ComputeBoundsVisitor>
#include <osg/NodeVisitor>
#include <osg/TriangleIndexFunctor>

#include <osg/BoundingBox>
#include <osg/BoundingSphere>
#include <osg/Camera>
#include <osg/Group>
#include <osg/Geometry>
#include <osg/Geode>
#include <osgUtil/CullVisitor>

#include <components/debug/debuglog.hpp>
#include <components/misc/constants.hpp>
#include <components/occlusionculling/occludermesh.hpp>
#include <components/sceneutil/occlusionculling.hpp>
#include <components/terrain/terrainoccluder.hpp>
#include "../mwworld/class.hpp"

namespace MWRender
{
    namespace
    {
        // TSP_INTOCC_V5 - proper interior occlusion culling.
        //
        // What V1-V4 measured, so this is not guesswork:
        //   params  minRadius=400 maxRadius=5000 shrink=1 meshRes=7 maxMeshRes=24
        //           insideThresh=1 maxDist=6144 maxTriangles=30000 (4679 in use)
        //   V4 mode2 p1 tot=29 tst=29 cul=0 | p2 tot=218 tst=212 cul=26 of 1046 drawables
        // Occluders are NOT shrunk and the eye-inside guard costs 1-2 objects a frame, so
        // neither of those is the problem. What is: the 27 occluders are 173-triangle
        // simplified PROXIES of rooms built at meshRes 7-24. A proxy that coarse does not
        // cover a Morrowind wall, so the depth buffer has holes everywhere and nothing
        // behind a wall is ever fully covered. TestRect only rejects a FULLY covered rect.
        //
        // TSP_INTOCC_FULLOCC=1 replaces the proxy with the object's REAL triangles, taken
        // straight out of its drawables in world space and cached per node. Correct by
        // construction: the depth buffer then matches what is actually drawn, so it can
        // never over-cull, only cost CPU - and the cost is measured and printed as rast_us
        // with a hard per-frame triangle budget, nearest occluders first.
        //
        // It also makes the eye-inside guard unnecessary. That guard exists because a solid
        // box proxy around the room you stand in would occlude the whole screen. Real
        // geometry does not: the near walls clip away behind the camera and the FAR wall of
        // your own room - the single most valuable occluder in an interior - goes into the
        // buffer where it belongs. So EYEIN defaults ON whenever FULLOCC is on.
        //
        // Env, all read once, no rebuild needed to sweep any of them:
        //   TSP_INTOCC        0 upstream | 1 Pass 2 tests the real world AABB | 2 also test
        //                     Pass 1 large objects against the complete buffer
        //   TSP_INTOCC_FULLOCC=1   real-geometry occluders, nearest first (the fix)
        //   TSP_INTOCC_RASTBUDGET  triangles rasterised per frame (default 12000)
        //   TSP_INTOCC_NODETRI     triangle cap for any single occluder (default 4000)
        //   TSP_INTOCC_TRIBUILD    nodes whose triangle soup is extracted per frame (6)
        //   TSP_INTOCC_EYEIN       -1 auto (=FULLOCC) | 0 keep upstream guard | 1 ignore it
        //   TSP_INTOCC_MESHRES / _MAXMESHRES / _MAXTRIANGLES / _SHRINK / _INSIDE / _MINR
        //                     override the corresponding occlusion setting at cell load
        //   TSP_INTOCC_BOXBUDGET   ComputeBoundsVisitor builds per frame (64)
        //   TSP_INTOCC_REPORT      report every N gameplay frames, NOT the first N (120)
        struct TspIntOccCfg
        {
            int mMode;
            int mFullOcc;
            int mEyeIn;
            int mMaxOcc;
            int mMaxTri;
            int mBudget;
            int mRastBudget;
            int mNodeTri;
            int mTriBuild;
            int mReportEvery;
            int mBoxBudget;
            int mMeshRes;
            int mMaxMeshRes;
            int mMaxTriangles;
            float mShrink;
            float mInside;
            float mMinR;
        };
        int tspEnvInt(const char* name, int def)
        {
            const char* e = std::getenv(name);
            if (e == nullptr || e[0] == 0)
                return def;
            return std::atoi(e);
        }
        float tspEnvFloat(const char* name, float def)
        {
            const char* e = std::getenv(name);
            if (e == nullptr || e[0] == 0)
                return def;
            return static_cast<float>(std::atof(e));
        }
        const TspIntOccCfg& tspIntOccCfg()
        {
            static TspIntOccCfg sCfg;
            static bool sInit = false;
            if (!sInit)
            {
                sInit = true;
                sCfg.mMode = tspEnvInt("TSP_INTOCC", 0);
                if (sCfg.mMode < 0)
                    sCfg.mMode = 0;
                sCfg.mFullOcc = tspEnvInt("TSP_INTOCC_FULLOCC", 0);
                sCfg.mEyeIn = tspEnvInt("TSP_INTOCC_EYEIN", -1);
                if (sCfg.mEyeIn < 0)
                    sCfg.mEyeIn = sCfg.mFullOcc ? 1 : 0;
                sCfg.mMaxOcc = tspEnvInt("TSP_INTOCC_MAXOCC", 12);
                sCfg.mMaxTri = tspEnvInt("TSP_INTOCC_MAXTRI", 512);
                sCfg.mBudget = tspEnvInt("TSP_INTOCC_BUDGET", 8000);
                sCfg.mRastBudget = tspEnvInt("TSP_INTOCC_RASTBUDGET", 12000);
                sCfg.mNodeTri = tspEnvInt("TSP_INTOCC_NODETRI", 4000);
                sCfg.mTriBuild = tspEnvInt("TSP_INTOCC_TRIBUILD", 6);
                sCfg.mReportEvery = tspEnvInt("TSP_INTOCC_REPORT", 120);
                sCfg.mBoxBudget = tspEnvInt("TSP_INTOCC_BOXBUDGET", 64);
                sCfg.mMeshRes = tspEnvInt("TSP_INTOCC_MESHRES", -1);
                sCfg.mMaxMeshRes = tspEnvInt("TSP_INTOCC_MAXMESHRES", -1);
                sCfg.mMaxTriangles = tspEnvInt("TSP_INTOCC_MAXTRIANGLES", -1);
                sCfg.mShrink = tspEnvFloat("TSP_INTOCC_SHRINK", -1.0f);
                sCfg.mInside = tspEnvFloat("TSP_INTOCC_INSIDE", -1.0f);
                sCfg.mMinR = tspEnvFloat("TSP_INTOCC_MINR", -1.0f);
                Log(Debug::Warning) << "TSP_INTOCC_V5 cfg mode=" << sCfg.mMode
                                    << " fullocc=" << sCfg.mFullOcc << " eyein=" << sCfg.mEyeIn
                                    << " rastbudget=" << sCfg.mRastBudget << " nodetri=" << sCfg.mNodeTri
                                    << " tribuild=" << sCfg.mTriBuild << " boxbudget=" << sCfg.mBoxBudget
                                    << " report=" << sCfg.mReportEvery
                                    << " ovr meshres=" << sCfg.mMeshRes << " maxmeshres=" << sCfg.mMaxMeshRes
                                    << " maxtriangles=" << sCfg.mMaxTriangles << " shrink=" << sCfg.mShrink
                                    << " inside=" << sCfg.mInside << " minr=" << sCfg.mMinR;
            }
            return sCfg;
        }
        double tspNowUs()
        {
            const std::chrono::steady_clock::time_point t = std::chrono::steady_clock::now();
            return static_cast<double>(
                       std::chrono::duration_cast<std::chrono::nanoseconds>(t.time_since_epoch()).count())
                / 1000.0;
        }
        unsigned int sTspFrame = 0xffffffffu;
        long sTspFrames = 0;
        long sTspBoxBuilt = 0;
        long sTspBoxDyn = 0;
        long sTriBuilt = 0;
        long sTriTris = 0;
        int sBoxThisFrame = 0;
        int sBoxDeferred = 0;
        int sTriThisFrame = 0;
        int sTriDeferred = 0;
        int sRastOcc = 0;
        int sRastTris = 0;
        double sRastUs = 0.0;
        int sP1Total = 0;
        int sP1Tested = 0;
        int sP1Culled = 0;
        int sP1TotDw = 0;
        int sP1CulDw = 0;
        int sP2Total = 0;
        int sP2Tested = 0;
        int sP2Culled = 0;
        int sP2Skip = 0;
        int sP2TotDw = 0;
        int sP2CulDw = 0;
        int sEyeSeen = 0;
        int sEyeRast = 0;
        int sEyeTris = 0;
        struct TspBoxEntry
        {
            osg::BoundingSphere::vec_type mCentre;
            osg::BoundingSphere::value_type mRadius = 0;
            osg::BoundingBox mBox;
            int mDrawables = 1;
            bool mDynamic = false;
        };
        struct TspCountVisitor : public osg::NodeVisitor
        {
            TspCountVisitor()
                : osg::NodeVisitor(osg::NodeVisitor::TRAVERSE_ALL_CHILDREN)
            {
            }
            void apply(osg::Drawable& drawable) override
            {
                (void)drawable;
                ++mCount;
            }
            int mCount = 0;
        };
        // World-space box plus subtree drawable count, cached and validated against the
        // node's bounding sphere. Any node whose sphere ever changes is marked dynamic and
        // permanently falls back to the cheap sphere box, so actors never pay for a
        // per-frame subtree traversal.
        const TspBoxEntry& tspEntry(osg::Node* child, const osg::BoundingSphere& bs)
        {
            static std::map<osg::Node*, TspBoxEntry> sCache;
            static TspBoxEntry sFallback;
            if (sCache.size() > 32768)
                sCache.clear();
            std::map<osg::Node*, TspBoxEntry>::iterator it = sCache.find(child);
            if (it != sCache.end())
            {
                if (!it->second.mDynamic && it->second.mRadius == bs.radius()
                    && it->second.mCentre == bs.center())
                    return it->second;
                if (!it->second.mDynamic)
                {
                    it->second.mDynamic = true;
                    ++sTspBoxDyn;
                }
                sFallback = it->second;
                sFallback.mBox = osg::BoundingBox();
                sFallback.mBox.expandBy(bs);
                return sFallback;
            }
            const TspIntOccCfg& c = tspIntOccCfg();
            if (c.mBoxBudget > 0 && sBoxThisFrame >= c.mBoxBudget)
            {
                ++sBoxDeferred;
                sFallback = TspBoxEntry();
                sFallback.mDynamic = true;
                sFallback.mBox.expandBy(bs);
                return sFallback;
            }
            ++sBoxThisFrame;
            osg::ComputeBoundsVisitor cbv;
            child->accept(cbv);
            TspCountVisitor cnt;
            child->accept(cnt);
            TspBoxEntry e;
            e.mCentre = bs.center();
            e.mRadius = bs.radius();
            e.mBox = cbv.getBoundingBox();
            e.mDrawables = cnt.mCount > 0 ? cnt.mCount : 1;
            e.mDynamic = false;
            if (!e.mBox.valid())
                e.mBox.expandBy(bs);
            ++sTspBoxBuilt;
            sCache[child] = e;
            return sCache[child];
        }
        struct TspTriCollector
        {
            std::vector<unsigned int>* mIdx = nullptr;
            unsigned int mBase = 0;
            unsigned int mLimit = 0;
            void operator()(unsigned int a, unsigned int b, unsigned int c)
            {
                if (mIdx == nullptr || a == b || b == c || a == c)
                    return;
                if (mLimit > 0 && mIdx->size() >= static_cast<std::size_t>(mLimit) * 3)
                    return;
                mIdx->push_back(mBase + a);
                mIdx->push_back(mBase + b);
                mIdx->push_back(mBase + c);
            }
        };
        // Pulls an object's real triangles into world space. Alpha-blended and explicitly
        // transparent geometry is skipped - a curtain or a window pane must not occlude.
        struct TspTriVisitor : public osg::NodeVisitor
        {
            TspTriVisitor()
                : osg::NodeVisitor(osg::NodeVisitor::TRAVERSE_ALL_CHILDREN)
            {
            }
            void apply(osg::Transform& transform) override
            {
                osg::Matrix m;
                if (!mStack.empty())
                    m = mStack.back();
                transform.computeLocalToWorldMatrix(m, this);
                mStack.push_back(m);
                traverse(transform);
                mStack.pop_back();
            }
            void apply(osg::Geometry& geom) override
            {
                if (mMesh == nullptr)
                    return;
                const osg::StateSet* ss = geom.getStateSet();
                if (ss != nullptr)
                {
                    if (ss->getRenderingHint() == osg::StateSet::TRANSPARENT_BIN)
                        return;
                    if ((ss->getMode(GL_BLEND) & osg::StateAttribute::ON) != 0)
                        return;
                }
                const osg::Vec3Array* va = dynamic_cast<const osg::Vec3Array*>(geom.getVertexArray());
                if (va == nullptr || va->empty())
                    return;
                osg::Matrixf mf;
                if (!mStack.empty())
                    mf = osg::Matrixf(mStack.back());
                const unsigned int base = static_cast<unsigned int>(mMesh->vertices.size());
                const std::size_t idxBefore = mMesh->indices.size();
                mMesh->vertices.reserve(mMesh->vertices.size() + va->size());
                for (unsigned int i = 0; i < va->size(); ++i)
                    mMesh->vertices.push_back((*va)[i] * mf);
                osg::TriangleIndexFunctor<TspTriCollector> tif;
                tif.mIdx = &mMesh->indices;
                tif.mBase = base;
                tif.mLimit = mLimit;
                geom.accept(tif);
                if (mMesh->indices.size() == idxBefore)
                    mMesh->vertices.resize(base);
            }
            std::vector<osg::Matrix> mStack;
            OccluderMesh* mMesh = nullptr;
            unsigned int mLimit = 4000;
        };
        struct TspRealEntry
        {
            OccluderMesh mMesh;
            osg::BoundingSphere::vec_type mCentre;
            osg::BoundingSphere::value_type mRadius = 0;
            bool mDynamic = false;
        };
        const OccluderMesh& tspRealMesh(osg::Node* child, const osg::BoundingSphere& bs)
        {
            static std::map<osg::Node*, TspRealEntry> sCache;
            static OccluderMesh sEmpty;
            std::map<osg::Node*, TspRealEntry>::iterator it = sCache.find(child);
            if (it != sCache.end())
            {
                if (it->second.mDynamic)
                    return sEmpty;
                if (it->second.mRadius == bs.radius() && it->second.mCentre == bs.center())
                    return it->second.mMesh;
                it->second.mDynamic = true;
                it->second.mMesh = OccluderMesh();
                return sEmpty;
            }
            const TspIntOccCfg& c = tspIntOccCfg();
            if (c.mTriBuild > 0 && sTriThisFrame >= c.mTriBuild)
            {
                ++sTriDeferred;
                return sEmpty;
            }
            if (sCache.size() > 512)
                sCache.clear();
            ++sTriThisFrame;
            TspRealEntry e;
            e.mCentre = bs.center();
            e.mRadius = bs.radius();
            TspTriVisitor v;
            v.mMesh = &e.mMesh;
            v.mLimit = static_cast<unsigned int>(c.mNodeTri > 0 ? c.mNodeTri : 4000);
            child->accept(v);
            for (std::size_t i = 0; i < e.mMesh.vertices.size(); ++i)
                e.mMesh.aabb.expandBy(e.mMesh.vertices[i]);
            ++sTriBuilt;
            sTriTris += static_cast<long>(e.mMesh.indices.size() / 3);
            sCache[child] = e;
            return sCache[child].mMesh;
        }
        struct TspCand
        {
            osg::Node* mNode = nullptr;
            float mDistSq = 0.0f;
        };
        bool tspCandLess(const TspCand& a, const TspCand& b)
        {
            return a.mDistSq < b.mDistSq;
        }
        void tspIntOccBeginFrame(unsigned int frame)
        {
            if (frame == sTspFrame)
                return;
            const TspIntOccCfg& c = tspIntOccCfg();
            if (sTspFrame != 0xffffffffu && (c.mMode >= 1 || c.mFullOcc))
            {
                ++sTspFrames;
                if (c.mReportEvery > 0 && (sTspFrames % c.mReportEvery) == 0)
                    Log(Debug::Warning) << "TSP_INTOCC_V5 f=" << sTspFrame
                                        << " p1 tot=" << sP1Total << " tst=" << sP1Tested
                                        << " cul=" << sP1Culled
                                        << " | p2 tot=" << sP2Total << " tst=" << sP2Tested
                                        << " cul=" << sP2Culled << " skip=" << sP2Skip
                                        << " | DRAWABLES p1 tot=" << sP1TotDw << " cul=" << sP1CulDw
                                        << " p2 tot=" << sP2TotDw << " cul=" << sP2CulDw
                                        << " submitted=" << (sP1TotDw + sP2TotDw - sP1CulDw - sP2CulDw)
                                        << " | RAST occ=" << sRastOcc << " tris=" << sRastTris
                                        << " us=" << static_cast<long>(sRastUs)
                                        << " | eyein seen=" << sEyeSeen << " rast=" << sEyeRast
                                        << " | box built=" << sTspBoxBuilt << " dyn=" << sTspBoxDyn
                                        << " def=" << sBoxDeferred
                                        << " | tri built=" << sTriBuilt
                                        << " tris=" << sTriTris << " def=" << sTriDeferred;
            }
            sTspFrame = frame;
            sBoxThisFrame = 0;
            sBoxDeferred = 0;
            sTriThisFrame = 0;
            sTriDeferred = 0;
            sRastOcc = 0;
            sRastTris = 0;
            sRastUs = 0.0;
            sP1Total = 0;
            sP1Tested = 0;
            sP1Culled = 0;
            sP1TotDw = 0;
            sP1CulDw = 0;
            sP2Total = 0;
            sP2Tested = 0;
            sP2Culled = 0;
            sP2Skip = 0;
            sP2TotDw = 0;
            sP2CulDw = 0;
            sEyeSeen = 0;
            sEyeRast = 0;
            sEyeTris = 0;
        }
        bool tspIntOccAllowInside(int tris)
        {
            const TspIntOccCfg& c = tspIntOccCfg();
            ++sEyeSeen;
            if (c.mEyeIn == 0)
                return false;
            if (c.mMaxTri > 0 && tris > c.mMaxTri)
                return false;
            if (c.mMaxOcc > 0 && sEyeRast >= c.mMaxOcc)
                return false;
            if (c.mBudget > 0 && sEyeTris + tris > c.mBudget)
                return false;
            ++sEyeRast;
            sEyeTris += tris;
            return true;
        }
        std::string_view getModelPathForNode(osg::Node* node)
        {
            if (!node)
                return {};

            if (auto* udc = node->getUserDataContainer())
            {
                for (unsigned int i = 0; i < udc->getNumUserObjects(); ++i)
                {
                    if (auto* holder = dynamic_cast<PtrHolder*>(udc->getUserObject(i)))
                        return holder->mPtr.getClass().getCorrectedModel(holder->mPtr);
                }
            }
            return {};
        }

        OccluderMesh transformLocalMesh(const OccluderMesh& localMesh, const osg::Matrixf& matrix)
        {
            OccluderMesh worldMesh;
            worldMesh.indices = localMesh.indices;
            worldMesh.vertices.reserve(localMesh.vertices.size());
            for (const auto& v : localMesh.vertices)
            {
                const osg::Vec3f transformed = v * matrix;
                worldMesh.vertices.push_back(transformed);
                worldMesh.aabb.expandBy(transformed);
            }

            if (localMesh.vertices.empty() && localMesh.aabb.valid())
            {
                for (unsigned int i = 0; i < 8; ++i)
                    worldMesh.aabb.expandBy(localMesh.aabb.corner(i) * matrix);
            }
            return worldMesh;
        }
    }

    SceneOcclusionCallback::SceneOcclusionCallback(SceneUtil::OcclusionCuller* culler,
        Terrain::TerrainOccluder* occluder, int radiusCells, bool enableTerrainOccluder, bool enableDebugOverlay,
        bool enableDebugMessages, bool enableInteriors, OcclusionStorage* storage)
        : mCuller(culler)
        , mTerrainOccluder(occluder)
        , mRadiusCells(radiusCells)
        , mEnableTerrainOccluder(enableTerrainOccluder)
        , mEnableDebugOverlay(enableDebugOverlay)
        , mEnableDebugMessages(enableDebugMessages)
        , mEnableInteriors(enableInteriors)
        , mStorage(storage)
    {
    }

    void SceneOcclusionCallback::setCellType(bool isInterior, bool isQuasiExterior)
    {
        mIsInterior = isInterior;
        mIsQuasiExterior = isQuasiExterior;
    }

    void SceneOcclusionCallback::setupDebugOverlay()
    {
        unsigned int w, h;
        mCuller->getResolution(w, h);
        if (w == 0 || h == 0)
            return;

        mDepthPixels.resize(w * h);

        // Create image to hold depth data (luminance float -> converted to RGBA)
        mDebugImage = new osg::Image;
        mDebugImage->allocateImage(w, h, 1, GL_LUMINANCE, GL_FLOAT);

        // Create texture from image
        mDebugTexture = new osg::Texture2D(mDebugImage);
        mDebugTexture->setFilter(osg::Texture::MIN_FILTER, osg::Texture::NEAREST);
        mDebugTexture->setFilter(osg::Texture::MAG_FILTER, osg::Texture::NEAREST);
        mDebugTexture->setWrap(osg::Texture::WRAP_S, osg::Texture::CLAMP_TO_EDGE);
        mDebugTexture->setWrap(osg::Texture::WRAP_T, osg::Texture::CLAMP_TO_EDGE);
        mDebugTexture->setResizeNonPowerOfTwoHint(false);

        // Create POST_RENDER camera in corner of screen
        mDebugCamera = new osg::Camera;
        mDebugCamera->setName("OcclusionDebugCamera");
        mDebugCamera->setReferenceFrame(osg::Transform::ABSOLUTE_RF);
        mDebugCamera->setRenderOrder(osg::Camera::POST_RENDER, 100);
        mDebugCamera->setAllowEventFocus(false);
        mDebugCamera->setClearMask(0);
        mDebugCamera->setProjectionMatrix(osg::Matrix::ortho2D(0, 1, 0, 1));
        mDebugCamera->setViewMatrix(osg::Matrix::identity());
        mDebugCamera->getOrCreateStateSet()->setMode(GL_DEPTH_TEST, osg::StateAttribute::OFF);
        mDebugCamera->getOrCreateStateSet()->setMode(GL_LIGHTING, osg::StateAttribute::OFF);
        mDebugCamera->setCullingActive(false);

        // Scale viewport to show in bottom-left corner (400px wide, aspect-correct height)
        float displayWidth = 400.0f;
        float displayHeight = displayWidth * static_cast<float>(h) / static_cast<float>(w);
        mDebugCamera->setViewport(0, 0, static_cast<int>(displayWidth), static_cast<int>(displayHeight));

        // Create textured quad
        osg::ref_ptr<osg::Geometry> quad
            = osg::createTexturedQuadGeometry(osg::Vec3(0, 0, 0), osg::Vec3(1, 0, 0), osg::Vec3(0, 1, 0));
        quad->setCullingActive(false);

        osg::StateSet* ss = quad->getOrCreateStateSet();
        ss->setTextureAttributeAndModes(0, mDebugTexture, osg::StateAttribute::ON);

        osg::ref_ptr<osg::Geode> geode = new osg::Geode;
        geode->addDrawable(quad);
        mDebugCamera->addChild(geode);
    }

    void SceneOcclusionCallback::updateDebugOverlay(osgUtil::CullVisitor* cv)
    {
        if (!mDebugCamera)
            return;

        unsigned int w, h;
        mCuller->getResolution(w, h);

        // Read depth buffer from MOC
        mCuller->computePixelDepthBuffer(mDepthPixels.data());

        // Copy to image (normalize: MOC stores 1/w, so closer = larger values)
        float* imageData = reinterpret_cast<float*>(mDebugImage->data());
        for (unsigned int i = 0; i < w * h; ++i)
        {
            float d = mDepthPixels[i];
            // MOC depth is 1/w (reciprocal clip-space w). 0 = far/empty, larger = closer.
            // Clamp and invert for visualization: dark = far, bright = near
            imageData[i] = std::min(d * 50.0f, 1.0f);
        }
        mDebugImage->dirty();

        // Inject debug camera into the cull visitor so it gets rendered
        unsigned int traversalMask = cv->getTraversalMask();
        cv->setTraversalMask(0xffffffff);
        mDebugCamera->accept(*cv);
        cv->setTraversalMask(traversalMask);
    }

    void SceneOcclusionCallback::operator()(osg::Node* node, osgUtil::CullVisitor* cv)
    {
        // Only run occlusion for the main scene camera.
        // Skip shadow cameras, water reflection, and any other cameras.
        osg::Camera* cam = cv->getCurrentCamera();
        if (cam->getName() != Constants::SceneCamera)
        {
            traverse(node, cv);
            return;
        }

        // The scene is traversed multiple times per frame: once for the main cull pass,
        // and again by MWShadowTechnique::cullShadowReceivingScene (same camera name).
        // Only set up MOC on the first traversal; subsequent passes just traverse normally.
        unsigned int frameNumber = cv->getFrameStamp()->getFrameNumber();
        if (frameNumber == mLastFrameNumber)
        {
            traverse(node, cv);
            return;
        }
        mLastFrameNumber = frameNumber;

        // Skip MSOC entirely in interiors (unless enabled via setting)
        if (mIsInterior && !mEnableInteriors)
        {
            traverse(node, cv);
            return;
        }

        // Begin occlusion frame with camera matrices
        mCuller->beginFrame(cam->getViewMatrix(), cam->getProjectionMatrix());

        // Build and rasterize terrain occluder mesh (skip for quasi-exteriors and interiors — no real terrain)
        if (mEnableTerrainOccluder && !mIsQuasiExterior && !mIsInterior && mTerrainOccluder->hasTerrainData())
        {
            mPositions.clear();
            mIndices.clear();
            mTerrainOccluder->build(cv->getEyePoint(), mRadiusCells, mPositions, mIndices);

            if (!mPositions.empty())
                mCuller->rasterizeTerrainOccluder(mPositions, mIndices);
        }

        // Continue normal cull traversal — CellOcclusionCallbacks will test against the buffer
        traverse(node, cv);

        // End the occlusion frame so sub-camera traversals (water reflection/refraction,
        // shadow cameras) that share this scene graph don't incorrectly cull against
        // the main camera's occlusion buffer.
        mCuller->endFrame();

        // Update debug overlay AFTER traversal (terrain + building occluders now in buffer)
        if (mEnableDebugOverlay)
        {
            if (!mDebugCamera)
                setupDebugOverlay();
            updateDebugOverlay(cv);
        }

        if (mEnableDebugMessages)
        {
            static int frameCount = 0;
            if (++frameCount % 300 == 0)
            {
                const auto terrainTris = mIndices.size() / 3;
                const auto bldgTris = mCuller->getNumBuildingTris();
                const auto terrainVerts = mPositions.size();
                const auto bldgVerts = mCuller->getNumBuildingVerts();
                Log(Debug::Info) << "OcclusionCull: terrain tris=" << terrainTris << " terrain verts=" << terrainVerts
                                 << " bldg occluders=" << mCuller->getNumBuildingOccluders()
                                 << " bldg tris=" << bldgTris << " bldg verts=" << bldgVerts
                                 << " total tris=" << (terrainTris + bldgTris)
                                 << " total verts=" << (terrainVerts + bldgVerts)
                                 << " tested=" << mCuller->getNumTested()
                                 << " occluded=" << mCuller->getNumOccluded();
                if (mStorage)
                {
                    const auto s = mStorage->getAndResetStats();
                    Log(Debug::Info) << "OcclusionCache: mem_hits=" << s.memHits
                                     << " db_hits=" << s.dbHits
                                     << " misses(built)=" << s.misses
                                     << " writes=" << s.writes;
                }
            }
        }
    }

    PagedOccluderCallback::PagedOccluderCallback(
        SceneUtil::OcclusionCuller* culler, float maxDistance, unsigned int maxTriangles)
        : mCuller(culler)
        , mMaxDistanceSq(maxDistance * maxDistance)
        , mMaxTriangles(maxTriangles)
    {
    }

    void PagedOccluderCallback::operator()(osg::Node* node, osgUtil::CullVisitor* cv)
    {
        if (!mCuller->isFrameActive())
        {
            traverse(node, cv);
            return;
        }

        // Transform chunk bounding sphere from local to world space.
        // The chunk sits under a PAT, so node->getBound() is in chunk-local space.
        const osg::BoundingSphere& bs = node->getBound();
        if (bs.valid())
        {
            osg::Matrixd viewInverse;
            viewInverse.invert(cv->getCurrentCamera()->getViewMatrix());
            const osg::Matrixd modelToWorld = *cv->getModelViewMatrix() * viewInverse;
            const osg::Vec3f worldCenter = bs.center() * modelToWorld;
            const float r = bs.radius();

            osg::BoundingBox worldBB(worldCenter.x() - r, worldCenter.y() - r, worldCenter.z() - r, worldCenter.x() + r,
                worldCenter.y() + r, worldCenter.z() + r);

            // If entire chunk is occluded, skip rasterization AND traversal
            if (!mCuller->testVisibleAABB(worldBB))
                return;

            // Rasterize nearby building occluder meshes for visible chunks
            const osg::Vec3f eyeWorld(viewInverse(3, 0), viewInverse(3, 1), viewInverse(3, 2));

            if (auto* udc = node->getUserDataContainer())
            {
                for (unsigned int i = 0; i < udc->getNumUserObjects(); ++i)
                {
                    if (auto* pod = dynamic_cast<PagedOccluderData*>(udc->getUserObject(i)))
                    {
                        for (const auto& occMesh : pod->mOccluderMeshes)
                        {
                            if (occMesh.indices.empty())
                                continue;

                            const osg::Vec3f center = occMesh.aabb.center();
                            if ((center - eyeWorld).length2() > mMaxDistanceSq)
                                continue;

                            unsigned int newTris = static_cast<unsigned int>(occMesh.indices.size() / 3);
                            if (mMaxTriangles > 0 && mCuller->getNumBuildingTris() + newTris > mMaxTriangles)
                                continue;

                            mCuller->rasterizeOccluder(occMesh.vertices, occMesh.indices);
                            mCuller->incrementBuildingOccluders(newTris,
                                static_cast<unsigned int>(occMesh.vertices.size()));
                        }
                        break;
                    }
                }
            }
        }

        traverse(node, cv);
    }

    CellOcclusionCallback::CellOcclusionCallback(SceneUtil::OcclusionCuller* culler, float occluderMinRadius,
        float occluderMaxRadius, float occluderShrinkFactor, int occluderMeshResolution, int occluderMaxMeshResolution,
        float occluderInsideThreshold, float occluderMaxDistance, bool enableStaticOccluders,
        unsigned int maxTriangles, OcclusionStorage* storage)
        : mCuller(culler)
        , mOccluderMinRadius(occluderMinRadius)
        , mOccluderMaxRadius(occluderMaxRadius)
        , mOccluderShrinkFactor(occluderShrinkFactor)
        , mOccluderMeshResolution(occluderMeshResolution)
        , mOccluderMaxMeshResolution(occluderMaxMeshResolution)
        , mOccluderInsideThreshold(occluderInsideThreshold)
        , mOccluderMaxDistanceSq(occluderMaxDistance * occluderMaxDistance)
        , mEnableStaticOccluders(enableStaticOccluders)
        , mMaxTriangles(maxTriangles)
        , mStorage(storage)
    {
        const TspIntOccCfg& tspCfg = tspIntOccCfg();
        if (tspCfg.mShrink >= 0.0f)
            mOccluderShrinkFactor = tspCfg.mShrink;
        if (tspCfg.mInside >= 0.0f)
            mOccluderInsideThreshold = tspCfg.mInside;
        if (tspCfg.mMinR >= 0.0f)
            mOccluderMinRadius = tspCfg.mMinR;
        if (tspCfg.mMeshRes > 0)
            mOccluderMeshResolution = tspCfg.mMeshRes;
        if (tspCfg.mMaxMeshRes > 0)
            mOccluderMaxMeshResolution = tspCfg.mMaxMeshRes;
        if (tspCfg.mMaxTriangles >= 0)
            mMaxTriangles = static_cast<unsigned int>(tspCfg.mMaxTriangles);
        static bool sTspParamsLogged = false;
        if (!sTspParamsLogged)
        {
            sTspParamsLogged = true;
            unsigned int tspBW = 0;
            unsigned int tspBH = 0;
            if (mCuller)
                mCuller->getResolution(tspBW, tspBH);
            Log(Debug::Warning) << "TSP_INTOCC_V5 params minRadius=" << mOccluderMinRadius
                                << " maxRadius=" << mOccluderMaxRadius
                                << " shrink=" << mOccluderShrinkFactor
                                << " meshRes=" << mOccluderMeshResolution
                                << " maxMeshRes=" << mOccluderMaxMeshResolution
                                << " insideThresh=" << mOccluderInsideThreshold
                                << " maxDist=" << std::sqrt(mOccluderMaxDistanceSq)
                                << " staticOcc=" << (mEnableStaticOccluders ? 1 : 0)
                                << " maxTriangles=" << mMaxTriangles
                                << " mocBuffer=" << tspBW << "x" << tspBH;
        }
    }

    const OccluderMesh& CellOcclusionCallback::getOccluderMesh(osg::Node* node)
    {
        auto it = mMeshCache.find(node);
        if (it != mMeshCache.end())
            return it->second;

        int meshRes = mOccluderMeshResolution;
        float radius = node->getBound().radius();
        if (radius > mOccluderMinRadius && mOccluderMinRadius > 0)
        {
            float scale = radius / mOccluderMinRadius;
            meshRes = std::clamp(
                static_cast<int>(mOccluderMeshResolution * scale), mOccluderMeshResolution, mOccluderMaxMeshResolution);
        }

        OccluderMesh mesh;
        const std::string_view modelPath = getModelPathForNode(node);
        if (mStorage && mStorage->isOpen() && !modelPath.empty())
        {
            OccluderMesh localMesh;
            if (mStorage->get(modelPath, meshRes, OcclusionStorage::makeShrinkKey(mOccluderShrinkFactor), localMesh))
            {
                const auto nodePaths = node->getParentalNodePaths();
                osg::Matrixf localToWorld;
                if (!nodePaths.empty())
                    localToWorld = osg::computeLocalToWorld(nodePaths.front());
                mesh = transformLocalMesh(localMesh, localToWorld);
            }
        }

        if (!mesh.aabb.valid() && mesh.vertices.empty() && mesh.indices.empty())
        {
            if (mStorage)
                mStorage->recordMiss();
            mesh = OcclusionCulling::buildSimplifiedMesh(node, meshRes, mOccluderShrinkFactor);
            // Persist to SQLite so future sessions skip buildSimplifiedMesh entirely.
            if (mStorage && mStorage->isOpen() && !modelPath.empty())
                mStorage->put(modelPath, meshRes, OcclusionStorage::makeShrinkKey(mOccluderShrinkFactor), mesh);
        }

        return mMeshCache.emplace(node, std::move(mesh)).first->second;
    }

    void CellOcclusionCallback::operator()(osg::Group* node, osgUtil::CullVisitor* cv)
    {
        // If occlusion is not active this frame (interior, shadow camera, etc.), traverse normally
        if (!mCuller->isFrameActive())
        {
            traverse(node, cv);
            return;
        }

        // Test cell bounding box against terrain-only depth — if fully hidden by terrain,
        // skip entire cell. Use terrain-only so buildings in adjacent cells don't
        // false-cull entire cells that are clearly in view.
        const osg::BoundingSphere& cellBS = node->getBound();
        if (cellBS.valid())
        {
            osg::BoundingBox cellBB;
            cellBB.expandBy(cellBS);

            if (!mCuller->testVisibleAABBTerrainOnly(cellBB))
                return; // Entire cell hidden by terrain — no children traversed
        }

        tspIntOccBeginFrame(cv->getTraversalNumber());
        std::vector<TspCand> tspP1;
        const unsigned int numChildren = node->getNumChildren();

        // Pass 1: Large objects — test against terrain depth, optionally rasterize as occluders
        for (unsigned int i = 0; i < numChildren; ++i)
        {
            osg::Node* child = node->getChild(i);
            const osg::BoundingSphere& bs = child->getBound();

            if (!bs.valid() || bs.radius() < mOccluderMinRadius)
                continue;

            // Paged chunks and other oversized objects — test visibility, rasterize stored occluders
            if (bs.radius() > mOccluderMaxRadius)
            {
                // Rasterize sub-object occluder meshes stored at chunk creation time
                if (mEnableStaticOccluders)
                {
                    if (auto* udc = child->getUserDataContainer())
                    {
                        for (unsigned int j = 0; j < udc->getNumUserObjects(); ++j)
                        {
                            if (auto* pod = dynamic_cast<PagedOccluderData*>(udc->getUserObject(j)))
                            {
                                for (const auto& occMesh : pod->mOccluderMeshes)
                                {
                                    if (occMesh.indices.empty())
                                        continue;

                                    unsigned int newTris = static_cast<unsigned int>(occMesh.indices.size() / 3);
                                    if (mMaxTriangles > 0
                                        && mCuller->getNumBuildingTris() + newTris > mMaxTriangles)
                                        continue;

                                    mCuller->rasterizeOccluder(occMesh.vertices, occMesh.indices);
                                    mCuller->incrementBuildingOccluders(
                                        newTris, static_cast<unsigned int>(occMesh.vertices.size()));
                                }
                                break; // Only one PagedOccluderData per chunk
                            }
                        }
                    }
                }

                // Test chunk visibility against terrain-only depth — paged chunks are large
                // geometry that should only be culled by terrain, not adjacent buildings.
                osg::BoundingBox pageBB;
                pageBB.expandBy(bs);
                if (mCuller->testVisibleAABBTerrainOnly(pageBB))
                    child->accept(*cv);
                continue;
            }

            // Get cached occluder mesh (with AABB for visibility test)
            ++sP1Total;
            if (tspIntOccCfg().mMode >= 1 || tspIntOccCfg().mFullOcc)
                sP1TotDw += tspEntry(child, bs).mDrawables;
            if (tspIntOccCfg().mFullOcc)
            {
                TspCand tspCnd;
                tspCnd.mNode = child;
                tspCnd.mDistSq = static_cast<float>((bs.center() - cv->getEyePoint()).length2());
                tspP1.push_back(tspCnd);
                continue;
            }
            const OccluderMesh& mesh = getOccluderMesh(child);

            // Rasterize as occluder if in range and camera is not inside the building.
            // Test against terrain-only buffer so other buildings don't prevent rasterization
            // of adjacent buildings (which would reduce culling coverage for Pass 2).
            if (mesh.aabb.valid() && mEnableStaticOccluders && !mesh.indices.empty()
                && mCuller->testVisibleAABBTerrainOnly(mesh.aabb))
            {
                float distSq = (bs.center() - cv->getEyePoint()).length2();
                if (distSq < mOccluderMaxDistanceSq)
                {
                    osg::Vec3f center = mesh.aabb.center();
                    osg::Vec3f halfExtent
                        = (osg::Vec3f(mesh.aabb.xMax(), mesh.aabb.yMax(), mesh.aabb.zMax()) - center)
                        * mOccluderInsideThreshold;
                    osg::BoundingBox scaledBB;
                    scaledBB.expandBy(center - halfExtent);
                    scaledBB.expandBy(center + halfExtent);
                    const bool tspEyeInside = scaledBB.contains(cv->getEyePoint());
                    if (!tspEyeInside
                        || tspIntOccAllowInside(static_cast<int>(mesh.indices.size() / 3)))
                    {
                        unsigned int newTris = static_cast<unsigned int>(mesh.indices.size() / 3);
                        if (mMaxTriangles == 0
                            || mCuller->getNumBuildingTris() + newTris <= mMaxTriangles)
                        {
                            mCuller->rasterizeOccluder(mesh.vertices, mesh.indices);
                            mCuller->incrementBuildingOccluders(
                                newTris, static_cast<unsigned int>(mesh.vertices.size()));
                        }
                    }
                }
            }

            // Always traverse large buildings. Do NOT gate traversal on testVisibleAABB —
            // buildings testing against a buffer that includes previously rasterized
            // buildings causes false culling (flickering) when child ordering happens to
            // place one building in front of another in the depth buffer. Large buildings
            // are correctly culled by PVS and the cell-level AABB test above; MSOC
            // is reserved for culling small objects in Pass 2.
            // TSP_INTOCC_V5: in mode 2 the traversal is deferred until every occluder in
            // this cell has been rasterised, so child order cannot decide what occludes what.
            if (tspIntOccCfg().mMode >= 2)
            {
                TspCand tspCnd2;
                tspCnd2.mNode = child;
                tspCnd2.mDistSq = static_cast<float>((bs.center() - cv->getEyePoint()).length2());
                tspP1.push_back(tspCnd2);
                continue;
            }
            child->accept(*cv);
        }

        // TSP_INTOCC_V5: rasterise real-geometry occluders nearest-first inside a hard
        // triangle budget, then test every large object against the COMPLETE buffer.
        if (tspIntOccCfg().mFullOcc && !tspP1.empty())
        {
            std::sort(tspP1.begin(), tspP1.end(), tspCandLess);
            const TspIntOccCfg& tspC = tspIntOccCfg();
            for (std::size_t tspI = 0; tspI < tspP1.size(); ++tspI)
            {
                if (!mEnableStaticOccluders)
                    break;
                if (tspP1[tspI].mDistSq >= mOccluderMaxDistanceSq)
                    continue;
                osg::Node* tspN = tspP1[tspI].mNode;
                const OccluderMesh& tspM = tspRealMesh(tspN, tspN->getBound());
                if (tspM.indices.empty() || !tspM.aabb.valid())
                    continue;
                const int tspTris = static_cast<int>(tspM.indices.size() / 3);
                if (tspC.mRastBudget > 0 && sRastTris + tspTris > tspC.mRastBudget)
                    continue;
                if (mMaxTriangles > 0
                    && mCuller->getNumBuildingTris() + static_cast<unsigned int>(tspTris) > mMaxTriangles)
                    continue;
                if (tspC.mEyeIn == 0)
                {
                    const osg::Vec3f tspCentre = tspM.aabb.center();
                    const osg::Vec3f tspHalf
                        = (osg::Vec3f(tspM.aabb.xMax(), tspM.aabb.yMax(), tspM.aabb.zMax()) - tspCentre)
                        * mOccluderInsideThreshold;
                    osg::BoundingBox tspSB;
                    tspSB.expandBy(tspCentre - tspHalf);
                    tspSB.expandBy(tspCentre + tspHalf);
                    if (tspSB.contains(cv->getEyePoint()))
                    {
                        ++sEyeSeen;
                        continue;
                    }
                }
                const double tspT0 = tspNowUs();
                mCuller->rasterizeOccluder(tspM.vertices, tspM.indices);
                sRastUs += tspNowUs() - tspT0;
                mCuller->incrementBuildingOccluders(
                    static_cast<unsigned int>(tspTris), static_cast<unsigned int>(tspM.vertices.size()));
                sRastTris += tspTris;
                ++sRastOcc;
            }
        }
        for (std::size_t tspJ = 0; tspJ < tspP1.size(); ++tspJ)
        {
            osg::Node* tspChild = tspP1[tspJ].mNode;
            const osg::BoundingSphere& tspBS = tspChild->getBound();
            if (tspIntOccCfg().mMode >= 2)
            {
                const TspBoxEntry& tspE = tspEntry(tspChild, tspBS);
                ++sP1Tested;
                if (!mCuller->testVisibleAABB(tspE.mBox))
                {
                    ++sP1Culled;
                    sP1CulDw += tspE.mDrawables;
                    continue;
                }
            }
            tspChild->accept(*cv);
        }
        // Pass 2: Small objects — test against enriched depth buffer (terrain + buildings)
        for (unsigned int i = 0; i < numChildren; ++i)
        {
            osg::Node* child = node->getChild(i);
            const osg::BoundingSphere& bs = child->getBound();

            if (!bs.valid())
            {
                child->accept(*cv);
                continue;
            }

            if (bs.radius() >= mOccluderMinRadius)
                continue; // Already handled in pass 1

            // Never occlude doors — they sit flush against building surfaces
            // and are easily falsely hidden by the parent building's AABB occluder
            bool skipOcclusion = false;
            child->getUserValue("skipOcclusion", skipOcclusion);

            osg::BoundingBox childBB;
            childBB.expandBy(bs);

            ++sP2Total;
            bool tspVisible = true;
            if (skipOcclusion)
                ++sP2Skip;
            else
            {
                ++sP2Tested;
                int tspDw = 1;
                if (tspIntOccCfg().mMode >= 1 || tspIntOccCfg().mFullOcc)
                {
                    const TspBoxEntry& tspE2 = tspEntry(child, bs);
                    if (tspIntOccCfg().mMode >= 1)
                        childBB = tspE2.mBox;
                    tspDw = tspE2.mDrawables;
                }
                sP2TotDw += tspDw;
                tspVisible = mCuller->testVisibleAABB(childBB);
                if (!tspVisible)
                {
                    ++sP2Culled;
                    sP2CulDw += tspDw;
                }
            }
            if (tspVisible)
                child->accept(*cv);
            // else: occluded — skip
        }
    }
}
