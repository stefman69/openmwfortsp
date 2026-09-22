#include "resourcesystem.hpp"

#include <algorithm>

#include "animblendrulesmanager.hpp"
#include "bgsmfilemanager.hpp"
#include "imagemanager.hpp"
#include "keyframemanager.hpp"
#include "niffilemanager.hpp"
#include "scenemanager.hpp"
#include <atomic>
#include <chrono>
#include <cstdint>
#if defined(__linux__) && defined(__GLIBC__)
#include <malloc.h>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <components/debug/debuglog.hpp>
#include <cstdlib>
#include <cstring>
#endif

namespace Resource
{

    namespace
    {
        // TSP_PERF_QUIET_HELPER_051_V20
        bool tspV20DeepDebugEnabled()
        {
            static const bool enabled = [] {
                const char* value = std::getenv("OPENMW_TSP_DEEP_DEBUG");

                if (value == nullptr || *value == '\0')
                    return false;

                return !(std::strcmp(value, "0") == 0
                    || std::strcmp(value, "false") == 0
                    || std::strcmp(value, "off") == 0
                    || std::strcmp(value, "no") == 0);
            }();

            return enabled;
        }
    }



    ResourceSystem::ResourceSystem(
        const VFS::Manager* vfs, double expiryDelay, const ToUTF8::StatelessUtf8Encoder* encoder)
        : mVFS(vfs)
    {
        mNifFileManager = std::make_unique<NifFileManager>(vfs, encoder);
        mBgsmFileManager = std::make_unique<BgsmFileManager>(vfs, expiryDelay);
        mImageManager = std::make_unique<ImageManager>(vfs, expiryDelay);
        mSceneManager = std::make_unique<SceneManager>(
            vfs, mImageManager.get(), mNifFileManager.get(), mBgsmFileManager.get(), expiryDelay);
        mKeyframeManager = std::make_unique<KeyframeManager>(vfs, mSceneManager.get(), expiryDelay, encoder);
        mAnimBlendRulesManager = std::make_unique<AnimBlendRulesManager>(vfs, expiryDelay);

        addResourceManager(mNifFileManager.get());
        addResourceManager(mBgsmFileManager.get());
        addResourceManager(mKeyframeManager.get());
        // note, scene references images so add images afterwards for correct implementation of updateCache()
        addResourceManager(mSceneManager.get());
        addResourceManager(mImageManager.get());
        addResourceManager(mAnimBlendRulesManager.get());
    }

    ResourceSystem::~ResourceSystem()
    {
        // this has to be defined in the .cpp file as we can't delete incomplete types

        mResourceManagers.clear();
    }

    SceneManager* ResourceSystem::getSceneManager()
    {
        return mSceneManager.get();
    }

    ImageManager* ResourceSystem::getImageManager()
    {
        return mImageManager.get();
    }

    BgsmFileManager* ResourceSystem::getBgsmFileManager()
    {
        return mBgsmFileManager.get();
    }

    NifFileManager* ResourceSystem::getNifFileManager()
    {
        return mNifFileManager.get();
    }

    KeyframeManager* ResourceSystem::getKeyframeManager()
    {
        return mKeyframeManager.get();
    }

    AnimBlendRulesManager* ResourceSystem::getAnimBlendRulesManager()
    {
        return mAnimBlendRulesManager.get();
    }

    void ResourceSystem::setExpiryDelay(double expiryDelay)
    {
        for (std::vector<BaseResourceManager*>::iterator it = mResourceManagers.begin(); it != mResourceManagers.end();
             ++it)
            (*it)->setExpiryDelay(expiryDelay);

        // NIF files aren't needed any more once the converted objects are cached in SceneManager / BulletShapeManager,
        // so no point in using an expiry delay
        mNifFileManager->setExpiryDelay(0.0);
    }

    void ResourceSystem::updateCache(double referenceTime)
    {
        for (std::vector<BaseResourceManager*>::iterator it = mResourceManagers.begin(); it != mResourceManagers.end();
             ++it)
            (*it)->updateCache(referenceTime);
    
#if defined(__linux__) && defined(__GLIBC__)
        // TSP_MEMORY_TRIM_UPDATE_051_V7
        // OpenMW's managers have already expired unreferenced resources.
        // glibc may retain those free heap pages inside the process, so ask it
        // to return releasable pages to Linux at most once every five seconds.
        using TspTrimClock = std::chrono::steady_clock;
        static std::atomic<std::int64_t> sTspLastTrimNs{ 0 };

        const std::int64_t tspNowNs
            = std::chrono::duration_cast<std::chrono::nanoseconds>(
                  TspTrimClock::now().time_since_epoch())
                  .count();

        std::int64_t tspLastNs
            = sTspLastTrimNs.load(std::memory_order_relaxed);

        // TSP_MALLOC_TRIM_DEFAULT_OFF_V46
        // Default changed to OFF. malloc_trim(0) walks every arena's free lists
        // and madvise(MADV_DONTNEED)s each releasable page, so every page it drops
        // costs a minor fault plus a zero-fill the next time the allocator hands
        // that address back out - a hitch now AND a fault storm afterwards. It was
        // added when this device had no swap and returning pages to the kernel was
        // the only relief available. There is swap now (512 MB on /mnt/UDISK,
        // swappiness 150), and major faults measured 997 -> 2 per 10 s with it.
        // The kernel does this job better, and off the main thread.
        // See claude/memory-purge-audit.md.
        //
        // TSP_MALLOC_TRIM_SECS=<seconds> re-enables it without a rebuild, so this
        // is A/B-able in place. Unset, 0 or negative leaves it off.
        static const std::int64_t sTspTrimIntervalNs = []() -> std::int64_t {
            const char* tspEnv = std::getenv("TSP_MALLOC_TRIM_SECS");
            const double tspSecs = (tspEnv != nullptr) ? std::atof(tspEnv) : 0.0;
            return tspSecs > 0.0 ? static_cast<std::int64_t>(tspSecs * 1000000000.0) : 0;
        }();

        if (sTspTrimIntervalNs > 0
            && tspNowNs - tspLastNs >= sTspTrimIntervalNs
            && sTspLastTrimNs.compare_exchange_strong(
                tspLastNs, tspNowNs, std::memory_order_relaxed))
        {
            ::malloc_trim(0);
        }
#endif

        // TSP_PERF_QUIET_MEMORY_GATE_051_V20
        if (tspV20DeepDebugEnabled())
        {
        // TSP_MEMORY_PROCESS_TRACE_051_V10
        // Two-second diagnostic sampler. It runs after OpenMW's normal cache
        // expiry and the existing TSP malloc_trim pass, so persistent growth
        // seen here is what remains resident after cleanup had a chance to run.
        using TspMemClock = std::chrono::steady_clock;
        static std::atomic<std::int64_t> sTspLastMemTraceNs{ 0 };
        const std::int64_t tspMemNowNs
            = std::chrono::duration_cast<std::chrono::nanoseconds>(
                  TspMemClock::now().time_since_epoch())
                  .count();
        std::int64_t tspMemLastNs = sTspLastMemTraceNs.load(std::memory_order_relaxed);
        constexpr std::int64_t TspMemTraceIntervalNs = 10000000000LL;

        if (tspMemNowNs - tspMemLastNs >= TspMemTraceIntervalNs
            && sTspLastMemTraceNs.compare_exchange_strong(
                tspMemLastNs, tspMemNowNs, std::memory_order_relaxed))
        {
            auto parseKb = [](const std::string& line, const char* key, long long& target) {
                const std::string prefix(key);
                if (line.rfind(prefix, 0) != 0)
                    return;
                std::istringstream valueStream(line.substr(prefix.size()));
                valueStream >> target;
            };

            long long vmRss = -1;
            long long rssAnon = -1;
            long long rssFile = -1;
            long long rssShmem = -1;
            long long vmData = -1;
            long long vmSize = -1;
            long long vmSwap = -1;
            {
                std::ifstream stream("/proc/self/status");
                std::string line;
                while (std::getline(stream, line))
                {
                    parseKb(line, "VmRSS:", vmRss);
                    parseKb(line, "RssAnon:", rssAnon);
                    parseKb(line, "RssFile:", rssFile);
                    parseKb(line, "RssShmem:", rssShmem);
                    parseKb(line, "VmData:", vmData);
                    parseKb(line, "VmSize:", vmSize);
                    parseKb(line, "VmSwap:", vmSwap);
                }
            }

            long long pss = -1;
            long long privateClean = -1;
            long long privateDirty = -1;
            long long sharedClean = -1;
            long long sharedDirty = -1;
            long long anonymousKb = -1;
            {
                std::ifstream stream("/proc/self/smaps_rollup");
                std::string line;
                while (std::getline(stream, line))
                {
                    parseKb(line, "Pss:", pss);
                    parseKb(line, "Private_Clean:", privateClean);
                    parseKb(line, "Private_Dirty:", privateDirty);
                    parseKb(line, "Shared_Clean:", sharedClean);
                    parseKb(line, "Shared_Dirty:", sharedDirty);
                    parseKb(line, "Anonymous:", anonymousKb);
                }
            }

            long long memAvailable = -1;
            long long memFree = -1;
            long long cached = -1;
            long long slab = -1;
            long long sUnreclaim = -1;
            long long cmaFree = -1;
            {
                std::ifstream stream("/proc/meminfo");
                std::string line;
                while (std::getline(stream, line))
                {
                    parseKb(line, "MemAvailable:", memAvailable);
                    parseKb(line, "MemFree:", memFree);
                    parseKb(line, "Cached:", cached);
                    parseKb(line, "Slab:", slab);
                    parseKb(line, "SUnreclaim:", sUnreclaim);
                    parseKb(line, "CmaFree:", cmaFree);
                }
            }

            static long long sPrevVmRss = -1;
            static long long sPrevRssAnon = -1;
            static long long sPrevRssFile = -1;
            static long long sPrevVmData = -1;
            static long long sPrevCmaFree = -1;

            const auto delta = [](long long now, long long before) -> long long {
                return now >= 0 && before >= 0 ? now - before : 0;
            };

            long long mallocArena = -1;
            long long mallocInUse = -1;
            long long mallocFree = -1;
            long long mallocMmap = -1;
#if defined(__linux__) && defined(__GLIBC__)
            const struct mallinfo tspMall = ::mallinfo();
            mallocArena = tspMall.arena;
            mallocInUse = tspMall.uordblks;
            mallocFree = tspMall.fordblks;
            mallocMmap = tspMall.hblkhd;
#endif

            Log(Debug::Info)
                << "TSP MEMPROC"
                << " rss_kb=" << vmRss
                << " rss_d=" << delta(vmRss, sPrevVmRss)
                << " anon_kb=" << rssAnon
                << " anon_d=" << delta(rssAnon, sPrevRssAnon)
                << " file_kb=" << rssFile
                << " file_d=" << delta(rssFile, sPrevRssFile)
                << " shmem_kb=" << rssShmem
                << " vmdata_kb=" << vmData
                << " vmdata_d=" << delta(vmData, sPrevVmData)
                << " vmsize_kb=" << vmSize
                << " swap_kb=" << vmSwap
                << " pss_kb=" << pss
                << " priv_clean_kb=" << privateClean
                << " priv_dirty_kb=" << privateDirty
                << " shared_clean_kb=" << sharedClean
                << " shared_dirty_kb=" << sharedDirty
                << " smaps_anon_kb=" << anonymousKb
                << " malloc_arena_b=" << mallocArena
                << " malloc_inuse_b=" << mallocInUse
                << " malloc_free_b=" << mallocFree
                << " malloc_mmap_b=" << mallocMmap
                << " memavail_kb=" << memAvailable
                << " memfree_kb=" << memFree
                << " cached_kb=" << cached
                << " slab_kb=" << slab
                << " sunreclaim_kb=" << sUnreclaim
                << " cmafree_kb=" << cmaFree
                << " cmafree_d=" << delta(cmaFree, sPrevCmaFree);

            sPrevVmRss = vmRss;
            sPrevRssAnon = rssAnon;
            sPrevRssFile = rssFile;
            sPrevVmData = vmData;
            sPrevCmaFree = cmaFree;

            static std::vector<std::size_t> sPrevCacheSizes;
            if (sPrevCacheSizes.size() < mResourceManagers.size())
                sPrevCacheSizes.resize(mResourceManagers.size(), 0);

            for (std::size_t i = 0; i < mResourceManagers.size(); ++i)
            {
                BaseResourceManager* manager = mResourceManagers[i];
                const CacheStats stats = manager->getTspMemoryCacheStats();
                const long long sizeDelta = static_cast<long long>(stats.mSize)
                    - static_cast<long long>(sPrevCacheSizes[i]);

                const char* label = "Extra";
                if (manager == mNifFileManager.get())
                    label = "NIF";
                else if (manager == mBgsmFileManager.get())
                    label = "BGSM";
                else if (manager == mKeyframeManager.get())
                    label = "Keyframe";
                else if (manager == mSceneManager.get())
                    label = "SceneNode";
                else if (manager == mImageManager.get())
                    label = "Image";
                else if (manager == mAnimBlendRulesManager.get())
                    label = "AnimBlend";

                Log(Debug::Info)
                    << "TSP MEMCACHE"
                    << " index=" << i
                    << " name=" << label
                    << " size=" << stats.mSize
                    << " size_d=" << sizeDelta
                    << " gets=" << stats.mGet
                    << " hits=" << stats.mHit
                    << " expired=" << stats.mExpired;

                sPrevCacheSizes[i] = stats.mSize;
            }
        }
        }
}

    void ResourceSystem::clearCache()
    {
        // TSP_MEMORY_CLEAR_TRACE_051_V10
        std::size_t tspClearBefore = 0;
        for (BaseResourceManager* manager : mResourceManagers)
            tspClearBefore += manager->getTspMemoryCacheStats().mSize;

        for (std::vector<BaseResourceManager*>::iterator it = mResourceManagers.begin(); it != mResourceManagers.end();
             ++it)
            (*it)->clearCache();
    
#if defined(__linux__) && defined(__GLIBC__)
        // TSP_MEMORY_TRIM_CLEAR_051_V7
        ::malloc_trim(0);
#endif

        std::size_t tspClearAfter = 0;
        for (BaseResourceManager* manager : mResourceManagers)
            tspClearAfter += manager->getTspMemoryCacheStats().mSize;
        Log(Debug::Info)
            << "TSP MEMCLEAR cache_entries_before=" << tspClearBefore
            << " cache_entries_after=" << tspClearAfter
            << " removed=" << (tspClearBefore - tspClearAfter);
}


    void ResourceSystem::addResourceManager(BaseResourceManager* resourceMgr)
    {
        mResourceManagers.push_back(resourceMgr);
    }

    void ResourceSystem::removeResourceManager(BaseResourceManager* resourceMgr)
    {
        std::vector<BaseResourceManager*>::iterator found
            = std::find(mResourceManagers.begin(), mResourceManagers.end(), resourceMgr);
        if (found != mResourceManagers.end())
            mResourceManagers.erase(found);
    }

    const VFS::Manager* ResourceSystem::getVFS() const
    {
        return mVFS;
    }

    void ResourceSystem::reportStats(unsigned int frameNumber, osg::Stats* stats) const
    {
        for (std::vector<BaseResourceManager*>::const_iterator it = mResourceManagers.begin();
             it != mResourceManagers.end(); ++it)
            (*it)->reportStats(frameNumber, stats);
    }

    void ResourceSystem::releaseGLObjects(osg::State* state)
    {
        for (std::vector<BaseResourceManager*>::const_iterator it = mResourceManagers.begin();
             it != mResourceManagers.end(); ++it)
            (*it)->releaseGLObjects(state);
    }

}
