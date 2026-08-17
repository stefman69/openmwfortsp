#ifndef OPENMW_COMPONENTS_RESOURCE_MANAGER_H
#define OPENMW_COMPONENTS_RESOURCE_MANAGER_H

#include <cstddef>

#include <osg/ref_ptr>

#include <components/vfs/pathutil.hpp>

#include "objectcache.hpp"

namespace VFS
{
    class Manager;
}

namespace osg
{
    class Stats;
    class State;
}

namespace Resource
{

    class BaseResourceManager
    {
    public:
        virtual ~BaseResourceManager() = default;
        virtual void updateCache(double referenceTime) = 0;
        virtual void clearCache() = 0;
        virtual void setExpiryDelay(double expiryDelay) = 0;
        virtual void reportStats(unsigned int frameNumber, osg::Stats* stats) const = 0;
        virtual void releaseGLObjects(osg::State* state) = 0;
        virtual CacheStats getTspMemoryCacheStats() const { return {}; }
    };

    /// @brief Base class for managers that require a virtual file system and object cache.
    /// @par This base class implements clearing of the cache, but populating it and what it's used for is up to the
    /// individual sub classes.
    template <class KeyType>
    class GenericResourceManager : public BaseResourceManager
    {
    public:
        typedef GenericObjectCache<KeyType> CacheType;

        explicit GenericResourceManager(const VFS::Manager* vfs, double expiryDelay)
            : mVFS(vfs)
            , mCache(new CacheType)
            , mExpiryDelay(expiryDelay)
        {
        }

        virtual ~GenericResourceManager() = default;

        /// Clear cache entries that have not been referenced for longer than expiryDelay.
        void updateCache(double referenceTime) override { mCache->update(referenceTime, mExpiryDelay); }

        /// Clear all cache entries.
        void clearCache() override { mCache->clear(); }

        /// How long to keep objects in cache after no longer being referenced.
        void setExpiryDelay(double expiryDelay) final { mExpiryDelay = expiryDelay; }
        double getExpiryDelay() const { return mExpiryDelay; }

        const VFS::Manager* getVFS() const { return mVFS; }

        // TSP_MEMORY_CACHE_STATS_ACCESSOR_051_V10
        CacheStats getTspMemoryCacheStats() const override { return mCache->getStats(); }
        void reportStats(unsigned int frameNumber, osg::Stats* stats) const override {}

        void releaseGLObjects(osg::State* state) override { mCache->releaseGLObjects(state); }

    protected:
        const VFS::Manager* mVFS;
        osg::ref_ptr<CacheType> mCache;
        double mExpiryDelay;
    };

    class ResourceManager : public GenericResourceManager<std::string>
    {
    public:
        explicit ResourceManager(const VFS::Manager* vfs, double expiryDelay)
            : GenericResourceManager(vfs, expiryDelay)
        {
        }
    };

}

#endif
