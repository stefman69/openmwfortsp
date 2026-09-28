// Resource ObjectCache for OpenMW, forked from osgDB ObjectCache by Robert Osfield, see copyright notice below.
// Changes:
// - removeExpiredObjectsInCache no longer keeps a lock while the unref happens.
// - template allows customized KeyType.
// - objects with uninitialized time stamp are not removed.

/* -*-c++-*- OpenSceneGraph - Copyright (C) 1998-2006 Robert Osfield
 *
 * This library is open source and may be redistributed and/or modified under
 * the terms of the OpenSceneGraph Public License (OSGPL) version 0.0 or
 * (at your option) any later version.  The full license is in LICENSE file
 * included with this distribution, and on the openscenegraph.org website.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * OpenSceneGraph Public License for more details.
 */

#ifndef OPENMW_COMPONENTS_RESOURCE_OBJECTCACHE
#define OPENMW_COMPONENTS_RESOURCE_OBJECTCACHE

#include "cachestats.hpp"

#include <osg/Node>
#include <osg/Referenced>
#include <osg/ref_ptr>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdlib>
#include <deque>
#include <map>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#if defined(__linux__)
#include <unistd.h>
#endif

#include <components/debug/debuglog.hpp>

namespace osg
{
    class Object;
    class State;
    class NodeVisitor;
    class Stats;
}

namespace Resource
{
    struct GenericObjectCacheItem
    {
        osg::ref_ptr<osg::Object> mValue;
        double mLastUsage;
    };

    // TSP_ASYNC_RECLAIM_V1
    //
    // GenericObjectCache already knows whether a resource is truly unused:
    // its cache reference is the only reference and mLastUsage is older than
    // the configured expiry delay.
    //
    // The previous TSP expiry-budget patch removed those entries from the
    // cache but retained their ref_ptrs in mTspPending. That traded a frame
    // hitch for retained RAM.
    //
    // This reclaimer preserves the existing expiry semantics and preloader.
    // Truly expired objects are removed immediately from the cache, then their
    // final ref is released on a low-priority background thread one object at
    // a time. Nothing that is active or held by the preloader can enter here.

    class TspAsyncObjectReclaimer
    {
    public:
        TspAsyncObjectReclaimer()
            : mThread([this] { run(); })
        {
        }

        ~TspAsyncObjectReclaimer()
        {
            {
                std::lock_guard<std::mutex> lock(mMutex);
                mStop = true;
            }

            mCondition.notify_all();

            if (mThread.joinable())
                mThread.join();
        }

        TspAsyncObjectReclaimer(const TspAsyncObjectReclaimer&) = delete;
        TspAsyncObjectReclaimer& operator=(
            const TspAsyncObjectReclaimer&) = delete;

        void enqueue(std::vector<osg::ref_ptr<osg::Object>>&& objects)
        {
            if (objects.empty())
                return;

            const std::size_t count = objects.size();

            {
                std::lock_guard<std::mutex> lock(mMutex);

                for (auto& object : objects)
                {
                    if (object)
                        mQueue.push_back(std::move(object));
                }
            }

            mQueued.fetch_add(count, std::memory_order_relaxed);
            mCondition.notify_one();
        }

    private:
        static bool diagnosticsEnabled()
        {
            static const bool enabled = [] {
                const char* value = std::getenv("TSP_RECLAIM_DIAG");
                return value != nullptr && value[0] == '1';
            }();

            return enabled;
        }

        void run()
        {
#if defined(__linux__)
            // The device normally pins OpenMW heavily. Make cleanup yield CPU
            // to the main/render path instead of producing periodic hitches.
            ::nice(10);
#endif

            auto lastDiagnostic
                = std::chrono::steady_clock::now();

            for (;;)
            {
                osg::ref_ptr<osg::Object> object;
                std::size_t pendingAfter = 0;

                {
                    std::unique_lock<std::mutex> lock(mMutex);

                    mCondition.wait(lock, [this] {
                        return mStop || !mQueue.empty();
                    });

                    if (mStop)
                        return;

                    object = std::move(mQueue.front());
                    mQueue.pop_front();
                    pendingAfter = mQueue.size();
                }

                // The destructor runs HERE, outside the cache mutex and
                // outside OpenMW's normal resource-cache update worker.
                object = nullptr;

                const std::size_t reclaimed
                    = mReclaimed.fetch_add(
                          1, std::memory_order_relaxed)
                    + 1;

                // Never monopolize the single gameplay CPU. One millisecond
                // between objects still clears hundreds of dead objects in
                // seconds instead of retaining them for minutes.
                std::this_thread::sleep_for(
                    std::chrono::milliseconds(1));

                if (diagnosticsEnabled())
                {
                    const auto now
                        = std::chrono::steady_clock::now();

                    if (now - lastDiagnostic
                        >= std::chrono::seconds(5))
                    {
                        lastDiagnostic = now;

                        Log(Debug::Info)
                            << "[TSP_RECLAIM_V1]"
                            << " queued_total="
                            << mQueued.load(
                                   std::memory_order_relaxed)
                            << " reclaimed_total="
                            << reclaimed
                            << " pending="
                            << pendingAfter;
                    }
                }
            }
        }

        std::mutex mMutex;
        std::condition_variable mCondition;
        std::deque<osg::ref_ptr<osg::Object>> mQueue;
        bool mStop = false;

        std::atomic<std::size_t> mQueued{ 0 };
        std::atomic<std::size_t> mReclaimed{ 0 };

        std::thread mThread;
    };

    inline TspAsyncObjectReclaimer& tspAsyncObjectReclaimer()
    {
        static TspAsyncObjectReclaimer reclaimer;
        return reclaimer;
    }

    template <typename KeyType>
    class GenericObjectCache : public osg::Referenced
    {
    public:
        /*
         * @brief Updates usage timestamps and removes expired items
         *
         * Updates the lastUsage timestamp of cached non-nullptr items that have external references.
         * Initializes lastUsage timestamp for new items.
         * Removes items that haven't been referenced for longer than expiryDelay.
         *
         * \note
         * Last usage might be updated from other places so nullptr items
         * that are not referenced elsewhere are not always removed.
         *
         * @param referenceTime the timestamp indicating when the item was most recently used
         * @param expiryDelay the delay after which the cache entry for an item expires
         */
        void update(double referenceTime, double expiryDelay)
        {
            std::vector<osg::ref_ptr<osg::Object>> objectsToRemove;
            {
                const double expiryTime = referenceTime - expiryDelay;
                std::lock_guard<std::mutex> lock(mMutex);

                std::erase_if(mItems, [&](auto& v) {
                    Item& item = v.second;

                    // update last usage timestamp if item is being referenced externally
                    // or initialize if not set
                    if ((item.mValue != nullptr && item.mValue->referenceCount() > 1) || item.mLastUsage == 0)
                        item.mLastUsage = referenceTime;

                    // skip items that have been accessed since expiryTime
                    if (item.mLastUsage > expiryTime)
                        return false;

                    ++mExpired;

                    // just mark for removal here so objects can be removed in bulk outside the lock
                    if (item.mValue != nullptr)
                        objectsToRemove.push_back(std::move(item.mValue));

                    return true;
                });
            }
            // TSP_ASYNC_RECLAIM_V1
            //
            // These objects have already exceeded the normal cache expiry
            // delay and no external owner is using them. Transfer their final
            // cache refs to the asynchronous reclaimer instead of retaining a
            // large pending backlog or destroying them in this cache-update
            // call.
            tspAsyncObjectReclaimer().enqueue(
                std::move(objectsToRemove));
        }

        /** Remove all objects in the cache regardless of having external references or expiry times.*/
        void clear()
        {
            std::vector<osg::ref_ptr<osg::Object>> objectsToRemove;

            {
                std::lock_guard<std::mutex> lock(mMutex);

                objectsToRemove.reserve(mItems.size());

                for (auto& [key, item] : mItems)
                {
                    if (item.mValue)
                        objectsToRemove.push_back(
                            std::move(item.mValue));
                }

                mItems.clear();
            }

            // TSP_ASYNC_RECLAIM_V1
            tspAsyncObjectReclaimer().enqueue(
                std::move(objectsToRemove));
        }

        /** Add a key,object,timestamp triple to the Registry::ObjectCache.*/
        template <class K>
        void addEntryToObjectCache(K&& key, osg::Object* object, double timestamp = 0.0)
        {
            std::lock_guard<std::mutex> lock(mMutex);
            const auto it = mItems.find(key);
            if (it == mItems.end())
                mItems.emplace_hint(it, std::forward<K>(key), Item{ object, timestamp });
            else
                it->second = Item{ object, timestamp };
        }

        /** Remove Object from cache.*/
        void removeFromObjectCache(const auto& key)
        {
            std::lock_guard<std::mutex> lock(mMutex);
            const auto itr = mItems.find(key);
            if (itr != mItems.end())
                mItems.erase(itr);
        }

        /** Get an ref_ptr<Object> from the object cache*/
        osg::ref_ptr<osg::Object> getRefFromObjectCache(const auto& key)
        {
            std::lock_guard<std::mutex> lock(mMutex);
            if (Item* const item = find(key))
                return item->mValue;
            return nullptr;
        }

        std::optional<osg::ref_ptr<osg::Object>> getRefFromObjectCacheOrNone(const auto& key)
        {
            const std::lock_guard<std::mutex> lock(mMutex);
            if (Item* const item = find(key))
                return item->mValue;
            return std::nullopt;
        }

        /** Check if an object is in the cache, and if it is, update its usage time stamp. */
        bool checkInObjectCache(const auto& key, double timeStamp)
        {
            std::lock_guard<std::mutex> lock(mMutex);
            if (Item* const item = find(key))
            {
                item->mLastUsage = timeStamp;
                return true;
            }
            return false;
        }

        /** call releaseGLObjects on all objects attached to the object cache.*/
        void releaseGLObjects(osg::State* state)
        {
            std::lock_guard<std::mutex> lock(mMutex);
            for (const auto& [k, v] : mItems)
                v.mValue->releaseGLObjects(state);
        }

        /** call node->accept(nv); for all nodes in the objectCache. */
        void accept(osg::NodeVisitor& nv)
        {
            std::lock_guard<std::mutex> lock(mMutex);
            for (const auto& [k, v] : mItems)
                if (osg::Object* const object = v.mValue.get())
                    if (osg::Node* const node = dynamic_cast<osg::Node*>(object))
                        node->accept(nv);
        }

        /** call operator()(KeyType, osg::Object*) for each object in the cache. */
        template <class Functor>
        void call(Functor&& f)
        {
            std::lock_guard<std::mutex> lock(mMutex);
            for (const auto& [k, v] : mItems)
                f(k, v.mValue.get());
        }

        template <class K>
        std::optional<std::pair<KeyType, osg::ref_ptr<osg::Object>>> lowerBound(K&& key)
        {
            const std::lock_guard<std::mutex> lock(mMutex);
            const auto it = mItems.lower_bound(std::forward<K>(key));
            if (it == mItems.end())
                return std::nullopt;
            return std::pair(it->first, it->second.mValue);
        }

        CacheStats getStats() const
        {
            const std::lock_guard<std::mutex> lock(mMutex);
            return CacheStats{
                .mSize = mItems.size(),
                .mGet = mGet,
                .mHit = mHit,
                .mExpired = mExpired,
            };
        }

    protected:
        using Item = GenericObjectCacheItem;

        std::map<KeyType, Item, std::less<>> mItems;
        mutable std::mutex mMutex;
        std::size_t mGet = 0;
        std::size_t mHit = 0;
        std::size_t mExpired = 0;

        Item* find(const auto& key)
        {
            ++mGet;
            const auto it = mItems.find(key);
            if (it == mItems.end())
                return nullptr;
            ++mHit;
            return &it->second;
        }
    };
}

#endif
