#include "cellpreloader.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <limits>
#include <span>

#if defined(__linux__) && defined(__GLIBC__)
#include <malloc.h>
#endif

#include <osg/Stats>

#include <components/debug/debuglog.hpp>
#include <components/esm3/loadcell.hpp>
#include <components/loadinglistener/reporter.hpp>
#include <components/misc/constants.hpp>
#include <components/misc/pathhelpers.hpp>
#include <components/misc/resourcehelpers.hpp>
#include <components/misc/strings/algorithm.hpp>
#include <components/misc/strings/lower.hpp>
#include <components/resource/bulletshapemanager.hpp>
#include <components/resource/keyframemanager.hpp>
#include <components/resource/resourcesystem.hpp>
#include <components/resource/scenemanager.hpp>
#include <components/terrain/view.hpp>
#include <components/terrain/world.hpp>
#include <components/vfs/manager.hpp>

#include "../mwrender/landmanager.hpp"

#include "cellstore.hpp"
#include "class.hpp"

namespace MWWorld
{
    namespace
    {
        bool contains(std::span<const PositionCellGrid> positions, const PositionCellGrid& contained, float tolerance)
        {
            const float squaredTolerance = tolerance * tolerance;
            const auto predicate = [&](const PositionCellGrid& v) {
                return (contained.mPosition - v.mPosition).length2() < squaredTolerance
                    && contained.mCellBounds == v.mCellBounds;
            };
            return std::ranges::any_of(positions, predicate);
        }

        bool contains(
            std::span<const PositionCellGrid> container, std::span<const PositionCellGrid> contained, float tolerance)
        {
            const auto predicate = [&](const PositionCellGrid& v) { return contains(container, v, tolerance); };
            return std::ranges::all_of(contained, predicate);
        }

        // TSP_BGALLOC_V1
        bool tspBgAllocEnabled()
        {
            static const bool enabled = [] {
                const char* value = std::getenv("TSP_BGALLOC");
                return value != nullptr && value[0] == '1';
            }();

            return enabled;
        }

        std::int64_t tspBgAllocInUse()
        {
#if defined(__linux__) && defined(__GLIBC__)
            const struct mallinfo info = ::mallinfo();
            return static_cast<std::int64_t>(info.uordblks);
#else
            return -1;
#endif
        }

        std::int64_t tspBgAllocElapsedMs(
            const std::chrono::steady_clock::time_point& start)
        {
            return std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - start).count();
        }
    }

    struct ListModelsVisitor
    {
        bool operator()(const MWWorld::ConstPtr& ptr)
        {
            ptr.getClass().getModelsToPreload(ptr, mOut);

            return true;
        }

        std::vector<std::string_view>& mOut;
    };

    /// Worker thread item: preload models in a cell.
    class PreloadItem : public SceneUtil::WorkItem
    {
    public:
        /// Constructor to be called from the main thread.
        explicit PreloadItem(MWWorld::CellStore* cell, Resource::SceneManager* sceneManager,
            Resource::BulletShapeManager* bulletShapeManager, Resource::KeyframeManager* keyframeManager,
            Terrain::World* terrain, MWRender::LandManager* landManager, bool preloadInstances)
            : mIsExterior(cell->getCell()->isExterior())
            , mCellLocation(cell->getCell()->getExteriorCellLocation())
            , mCellId(cell->getCell()->getId())
            , mSceneManager(sceneManager)
            , mBulletShapeManager(bulletShapeManager)
            , mKeyframeManager(keyframeManager)
            , mTerrain(terrain)
            , mLandManager(landManager)
            , mPreloadInstances(preloadInstances)
            , mAbort(false)
        {
            mTerrainView = mTerrain->createView();

            ListModelsVisitor visitor{ mMeshes };
            cell->forEachConst(visitor);
        }

        void abort() override { mAbort = true; }

        /// Preload work to be called from the worker thread.
        void doWork() override
        {
            const bool tspDiag = tspBgAllocEnabled();
            const auto tspStart = std::chrono::steady_clock::now();
            const std::int64_t tspBefore
                = tspDiag ? tspBgAllocInUse() : -1;

            if (mIsExterior)
            {
                try
                {
                    mTerrain->cacheCell(mTerrainView.get(), mCellLocation.mX, mCellLocation.mY);
                    mPreloadedObjects.insert(mLandManager->getLand(mCellLocation));
                }
                catch (const std::exception& e)
                {
                    Log(Debug::Warning) << "Failed to cache terrain for exterior cell " << mCellLocation << ": "
                                        << e.what();
                }
            }

            VFS::Path::Normalized mesh;
            VFS::Path::Normalized kfname;
            for (std::string_view path : mMeshes)
            {
                if (mAbort)
                    break;

                try
                {
                    const VFS::Manager& vfs = *mSceneManager->getVFS();
                    mesh = Misc::ResourceHelpers::correctMeshPath(VFS::Path::Normalized(path));
                    mesh = Misc::ResourceHelpers::correctActorModelPath(mesh, &vfs);

                    if (!vfs.exists(mesh))
                        continue;

                    constexpr VFS::Path::ExtensionView nif("nif");
                    if (Misc::getFileName(mesh).starts_with('x') && mesh.extension() == nif)
                    {
                        kfname = mesh;
                        constexpr VFS::Path::ExtensionView kf("kf");
                        kfname.changeExtension(kf);
                        if (vfs.exists(kfname))
                            mPreloadedObjects.insert(mKeyframeManager->get(kfname));
                    }

                    mPreloadedObjects.insert(mSceneManager->getTemplate(mesh));
                    if (mPreloadInstances)
                        mPreloadedObjects.insert(mBulletShapeManager->cacheInstance(mesh));
                    else
                        mPreloadedObjects.insert(mBulletShapeManager->getShape(mesh));
                }
                catch (const std::exception& e)
                {
                    Log(Debug::Warning) << "Failed to preload mesh \"" << path << "\" from cell " << mCellId << ": "
                                        << e.what();
                }
            }

            if (tspDiag)
            {
                const std::int64_t tspAfter = tspBgAllocInUse();

                Log(Debug::Info)
                    << "[TSP_BGALLOC_V1]"
                    << " kind=cell_preload"
                    << " cell=" << mCellId
                    << " meshes=" << mMeshes.size()
                    << " held_objects=" << mPreloadedObjects.size()
                    << " elapsed_ms=" << tspBgAllocElapsedMs(tspStart)
                    << " inuse_before=" << tspBefore
                    << " inuse_after=" << tspAfter
                    << " delta=" << (tspAfter - tspBefore);
            }
        }

    private:
        bool mIsExterior;
        ESM::ExteriorCellLocation mCellLocation;
        ESM::RefId mCellId;
        std::vector<std::string_view> mMeshes;
        Resource::SceneManager* mSceneManager;
        Resource::BulletShapeManager* mBulletShapeManager;
        Resource::KeyframeManager* mKeyframeManager;
        Terrain::World* mTerrain;
        MWRender::LandManager* mLandManager;
        bool mPreloadInstances;

        std::atomic<bool> mAbort;

        osg::ref_ptr<Terrain::View> mTerrainView;

        // keep a ref to the loaded objects to make sure it stays loaded as long as this cell is in the preloaded state
        std::set<osg::ref_ptr<const osg::Object>> mPreloadedObjects;
    };

    class TerrainPreloadItem : public SceneUtil::WorkItem
    {
    public:
        explicit TerrainPreloadItem(const std::vector<osg::ref_ptr<Terrain::View>>& views, Terrain::World* world,
            std::span<const PositionCellGrid> preloadPositions)
            : mAbort(false)
            , mTerrainViews(views)
            , mWorld(world)
            , mPreloadPositions(preloadPositions.begin(), preloadPositions.end())
        {
        }

        void doWork() override
        {
            const bool tspDiag = tspBgAllocEnabled();
            const auto tspStart = std::chrono::steady_clock::now();
            const std::int64_t tspBefore
                = tspDiag ? tspBgAllocInUse() : -1;

            for (unsigned int i = 0; i < mTerrainViews.size() && i < mPreloadPositions.size() && !mAbort; ++i)
            {
                mTerrainViews[i]->reset();
                mWorld->preload(mTerrainViews[i], mPreloadPositions[i].mPosition, mPreloadPositions[i].mCellBounds,
                    mAbort, mLoadingReporter);
            }

            mLoadingReporter.complete();

            if (tspDiag)
            {
                const std::int64_t tspAfter = tspBgAllocInUse();

                Log(Debug::Info)
                    << "[TSP_BGALLOC_V1]"
                    << " kind=terrain_preload"
                    << " positions=" << mPreloadPositions.size()
                    << " elapsed_ms=" << tspBgAllocElapsedMs(tspStart)
                    << " inuse_before=" << tspBefore
                    << " inuse_after=" << tspAfter
                    << " delta=" << (tspAfter - tspBefore);
            }
        }

        void abort() override { mAbort = true; }

        // TSP_TERRAIN_VIEW_RELEASE_V1
        // Once the preload has completed, the generated terrain/object chunks
        // remain owned by their normal ResourceSystem caches. The temporary
        // preload ViewData scene graphs no longer need to remain resident.
        std::vector<osg::ref_ptr<Terrain::View>> takeViews()
        {
            return std::move(mTerrainViews);
        }

        void wait(Loading::Listener& listener) const { mLoadingReporter.wait(listener); }

    private:
        std::atomic<bool> mAbort;
        std::vector<osg::ref_ptr<Terrain::View>> mTerrainViews;
        Terrain::World* mWorld;
        std::vector<PositionCellGrid> mPreloadPositions;
        Loading::Reporter mLoadingReporter;
    };

    // TSP_TERRAIN_VIEW_RELEASE_V1
    // Release completed terrain preload view graphs on a worker thread.
    // Their underlying terrain/object chunks remain in their normal caches.
    class ReleaseTerrainViewsItem : public SceneUtil::WorkItem
    {
    public:
        explicit ReleaseTerrainViewsItem(
            std::vector<osg::ref_ptr<Terrain::View>> views)
            : mViews(std::move(views))
        {
        }

        void doWork() override
        {
            mViews.clear();
        }

    private:
        std::vector<osg::ref_ptr<Terrain::View>> mViews;
    };

    /// Worker thread item: update the resource system's cache, effectively deleting unused entries.
    class UpdateCacheItem : public SceneUtil::WorkItem
    {
    public:
        UpdateCacheItem(Resource::ResourceSystem* resourceSystem, double referenceTime)
            : mReferenceTime(referenceTime)
            , mResourceSystem(resourceSystem)
        {
        }

        void doWork() override
        {
            const bool tspDiag = tspBgAllocEnabled();
            const auto tspStart = std::chrono::steady_clock::now();
            const std::int64_t tspBefore
                = tspDiag ? tspBgAllocInUse() : -1;

            mResourceSystem->updateCache(mReferenceTime);

            if (tspDiag)
            {
                const std::int64_t tspAfter = tspBgAllocInUse();
                const std::int64_t tspDelta = tspAfter - tspBefore;
                const std::int64_t tspMs = tspBgAllocElapsedMs(tspStart);

                if (tspDelta >= 65536 || tspDelta <= -65536 || tspMs >= 20)
                {
                    Log(Debug::Info)
                        << "[TSP_BGALLOC_V1]"
                        << " kind=resource_update"
                        << " elapsed_ms=" << tspMs
                        << " inuse_before=" << tspBefore
                        << " inuse_after=" << tspAfter
                        << " delta=" << tspDelta;
                }
            }
        }

    private:
        double mReferenceTime;
        Resource::ResourceSystem* mResourceSystem;
    };

    CellPreloader::CellPreloader(Resource::ResourceSystem* resourceSystem,
        Resource::BulletShapeManager* bulletShapeManager, Terrain::World* terrain, MWRender::LandManager* landManager)
        : mResourceSystem(resourceSystem)
        , mBulletShapeManager(bulletShapeManager)
        , mTerrain(terrain)
        , mLandManager(landManager)
        , mExpiryDelay(0.0)
        , mPreloadInstances(true)
        , mLastResourceCacheUpdate(0.0)
        , mLoadedTerrainTimestamp(0.0)
    {
    }

    CellPreloader::~CellPreloader()
    {
        clearAllTasks();
    }

    void CellPreloader::preload(CellStore& cell, double timestamp)
    {
        if (!mWorkQueue)
        {
            Log(Debug::Error) << "Error: can't preload, no work queue set";
            return;
        }
        if (cell.getState() == CellStore::State_Unloaded)
        {
            Log(Debug::Error) << "Error: can't preload objects for unloaded cell";
            return;
        }

        PreloadMap::iterator found = mPreloadCells.find(&cell);
        if (found != mPreloadCells.end())
        {
            // already preloaded, nothing to do other than updating the timestamp
            found->second.mTimeStamp = timestamp;
            return;
        }

        while (mPreloadCells.size() >= mMaxCacheSize)
        {
            // throw out oldest cell to make room
            PreloadMap::iterator oldestCell = mPreloadCells.begin();
            double oldestTimestamp = std::numeric_limits<double>::max();
            double threshold = 1.0; // seconds
            for (PreloadMap::iterator it = mPreloadCells.begin(); it != mPreloadCells.end(); ++it)
            {
                if (it->second.mTimeStamp < oldestTimestamp)
                {
                    oldestTimestamp = it->second.mTimeStamp;
                    oldestCell = it;
                }
            }

            if (oldestTimestamp + threshold < timestamp)
            {
                oldestCell->second.mWorkItem->abort();
                mPreloadCells.erase(oldestCell);
                ++mEvicted;
            }
            else
                return;
        }

        osg::ref_ptr<PreloadItem> item(new PreloadItem(&cell, mResourceSystem->getSceneManager(), mBulletShapeManager,
            mResourceSystem->getKeyframeManager(), mTerrain, mLandManager, mPreloadInstances));
        mWorkQueue->addWorkItem(item);

        mPreloadCells.emplace(&cell, PreloadEntry(timestamp, item));
        ++mAdded;
    }

    void CellPreloader::notifyLoaded(CellStore* cell)
    {
        PreloadMap::iterator found = mPreloadCells.find(cell);
        if (found != mPreloadCells.end())
        {
            if (found->second.mWorkItem)
            {
                found->second.mWorkItem->abort();
                found->second.mWorkItem = nullptr;
            }

            mPreloadCells.erase(found);
            ++mLoaded;
        }
    }

    void CellPreloader::clear()
    {
        for (PreloadMap::iterator it = mPreloadCells.begin(); it != mPreloadCells.end();)
        {
            if (it->second.mWorkItem)
            {
                it->second.mWorkItem->abort();
                it->second.mWorkItem = nullptr;
            }

            mPreloadCells.erase(it++);
        }
    }

    void CellPreloader::updateCache(double timestamp)
    {
        for (PreloadMap::iterator it = mPreloadCells.begin(); it != mPreloadCells.end();)
        {
            if (mPreloadCells.size() >= mMinCacheSize && it->second.mTimeStamp < timestamp - mExpiryDelay)
            {
                if (it->second.mWorkItem)
                {
                    it->second.mWorkItem->abort();
                    it->second.mWorkItem = nullptr;
                }
                mPreloadCells.erase(it++);
                ++mExpired;
            }
            else
                ++it;
        }

        if (timestamp - mLastResourceCacheUpdate > 1.0 && (!mUpdateCacheItem || mUpdateCacheItem->isDone()))
        {
            // the resource cache is cleared from the worker thread so that we're not holding up the main thread with
            // delete operations
            mUpdateCacheItem = new UpdateCacheItem(mResourceSystem, timestamp);
            mWorkQueue->addWorkItem(mUpdateCacheItem, true);
            mLastResourceCacheUpdate = timestamp;
        }

        if (mTerrainPreloadItem && mTerrainPreloadItem->isDone())
        {
            mLoadedTerrainPositions = mTerrainPreloadPositions;
            mLoadedTerrainTimestamp = timestamp;

            // TSP_TERRAIN_VIEW_RELEASE_V1
            //
            // The expensive chunk nodes created by preload() are already in
            // ChunkManager/ObjectPaging/Groundcover caches. Keeping the
            // independent preload ViewData graphs as well only adds another
            // strong-reference tree.
            //
            // Move the final view refs to a worker so releasing a large view
            // cannot create a destructor hitch on the gameplay thread.
            auto tspFinishedViews = mTerrainPreloadItem->takeViews();

            // TSP_TERRAIN_VIEW_KEEPDONE_V2
            //
            // Keep the completed WorkItem object alive. The original
            // CellPreloader logic intentionally leaves a completed item here,
            // which refreshes mLoadedTerrainTimestamp on later updateCache()
            // calls until a genuinely different terrain target replaces it.
            //
            // Its heavy ViewData refs have already been moved out by
            // takeViews(), so retaining this tiny completed WorkItem does NOT
            // retain the preload scene graphs.
            mTerrainViews.clear();

            if (!tspFinishedViews.empty())
            {
                osg::ref_ptr<ReleaseTerrainViewsItem> tspRelease
                    = new ReleaseTerrainViewsItem(std::move(tspFinishedViews));

                mWorkQueue->addWorkItem(tspRelease, true);
            }
        }
    }

    void CellPreloader::setExpiryDelay(double expiryDelay)
    {
        mExpiryDelay = expiryDelay;
    }

    void CellPreloader::setPreloadInstances(bool preload)
    {
        mPreloadInstances = preload;
    }

    void CellPreloader::setWorkQueue(osg::ref_ptr<SceneUtil::WorkQueue> workQueue)
    {
        mWorkQueue = workQueue;
    }

    void CellPreloader::syncTerrainLoad(Loading::Listener& listener)
    {
        if (mTerrainPreloadItem != nullptr && !mTerrainPreloadItem->isDone())
            mTerrainPreloadItem->wait(listener);
    }

    void CellPreloader::abortTerrainPreloadExcept(const PositionCellGrid* exceptPos)
    {
        if (exceptPos != nullptr && contains(mTerrainPreloadPositions, *exceptPos, Constants::CellSizeInUnits))
            return;
        if (mTerrainPreloadItem && !mTerrainPreloadItem->isDone())
        {
            mTerrainPreloadItem->abort();
            mTerrainPreloadItem->waitTillDone();
        }
        setTerrainPreloadPositions({});
    }

    void CellPreloader::setTerrainPreloadPositions(std::span<const PositionCellGrid> positions)
    {
        if (positions.empty())
        {
            mTerrainPreloadPositions.clear();
            mLoadedTerrainPositions.clear();
        }
        else if (contains(mTerrainPreloadPositions, positions, 128.f))
            return;
        if (mTerrainPreloadItem && !mTerrainPreloadItem->isDone())
            return;
        else
        {
            if (mTerrainViews.size() > positions.size())
                mTerrainViews.resize(positions.size());
            else if (mTerrainViews.size() < positions.size())
            {
                for (size_t i = mTerrainViews.size(); i < positions.size(); ++i)
                    mTerrainViews.emplace_back(mTerrain->createView());
            }

            mTerrainPreloadPositions.assign(positions.begin(), positions.end());
            if (!positions.empty())
            {
                mTerrainPreloadItem = new TerrainPreloadItem(mTerrainViews, mTerrain, positions);
                mWorkQueue->addWorkItem(mTerrainPreloadItem);
            }
        }
    }

    bool CellPreloader::isTerrainLoaded(const PositionCellGrid& position, double referenceTime) const
    {
        return mLoadedTerrainTimestamp + mResourceSystem->getSceneManager()->getExpiryDelay() > referenceTime
            && contains(mLoadedTerrainPositions, position, Constants::CellSizeInUnits);
    }

    void CellPreloader::setTerrain(Terrain::World* terrain)
    {
        if (terrain != mTerrain)
        {
            clearAllTasks();
            mTerrain = terrain;
        }
    }

    void CellPreloader::clearAllTasks()
    {
        if (mTerrainPreloadItem)
        {
            mTerrainPreloadItem->abort();
            mTerrainPreloadItem->waitTillDone();
            mTerrainPreloadItem = nullptr;
        }

        if (mUpdateCacheItem)
        {
            mUpdateCacheItem->waitTillDone();
            mUpdateCacheItem = nullptr;
        }

        for (PreloadMap::iterator it = mPreloadCells.begin(); it != mPreloadCells.end(); ++it)
            it->second.mWorkItem->abort();

        for (PreloadMap::iterator it = mPreloadCells.begin(); it != mPreloadCells.end(); ++it)
            it->second.mWorkItem->waitTillDone();

        mPreloadCells.clear();
    }

    void CellPreloader::reportStats(unsigned int frameNumber, osg::Stats& stats) const
    {
        stats.setAttribute(frameNumber, "CellPreloader Count", static_cast<double>(mPreloadCells.size()));
        stats.setAttribute(frameNumber, "CellPreloader Added", static_cast<double>(mAdded));
        stats.setAttribute(frameNumber, "CellPreloader Evicted", static_cast<double>(mEvicted));
        stats.setAttribute(frameNumber, "CellPreloader Loaded", static_cast<double>(mLoaded));
        stats.setAttribute(frameNumber, "CellPreloader Expired", static_cast<double>(mExpired));
    }
}
