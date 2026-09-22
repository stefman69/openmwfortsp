#include "scene.hpp"

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <limits>

#include <BulletCollision/CollisionDispatch/btCollisionObject.h>

#include <components/debug/debuglog.hpp>
#include <components/detournavigator/agentbounds.hpp>
#include <components/detournavigator/debug.hpp>
#include <components/detournavigator/heightfieldshape.hpp>
#include <components/detournavigator/navigator.hpp>
#include <components/detournavigator/updateguard.hpp>
#include <components/esm/esmterrain.hpp>
#include <components/esm/records.hpp>
#include <components/esm3/loadcell.hpp>
#include <components/loadinglistener/loadinglistener.hpp>
#include <components/misc/convert.hpp>
#include <components/misc/resourcehelpers.hpp>
#include <components/resource/resourcesystem.hpp>
#include <components/resource/scenemanager.hpp>
#include <components/sceneutil/positionattitudetransform.hpp>
#include <components/settings/values.hpp>
#include <components/terrain/terraingrid.hpp>
#include <components/vfs/pathutil.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/luamanager.hpp"
#include "../mwbase/mechanicsmanager.hpp"
#include "../mwbase/soundmanager.hpp"
#include "../mwbase/windowmanager.hpp"
#include "../mwbase/world.hpp"

#include "../mwmechanics/creaturestats.hpp"

#include "../mwrender/landmanager.hpp"
#include "../mwrender/postprocessor.hpp"
#include "../mwrender/renderingmanager.hpp"
#include "../mwrender/interiorvisibility.hpp"

#include "../mwphysics/actor.hpp"
#include "../mwphysics/heightfield.hpp"
#include "../mwphysics/object.hpp"
#include "../mwphysics/physicssystem.hpp"

#include "../mwworld/actionteleport.hpp"

#include "cellpreloader.hpp"
#include "cellstore.hpp"
#include "cellvisitors.hpp"
#include "class.hpp"
#include "esmstore.hpp"
#include "localscripts.hpp"
#include "player.hpp"
#include "worldimp.hpp"

namespace
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

    osg::Quat makeActorOsgQuat(const ESM::Position& position)
    {
        return osg::Quat(position.rot[2], osg::Vec3(0, 0, -1));
    }

    osg::Quat makeInversedOrderObjectOsgQuat(const ESM::Position& position)
    {
        const float xr = position.rot[0];
        const float yr = position.rot[1];
        const float zr = position.rot[2];

        return osg::Quat(xr, osg::Vec3(-1, 0, 0)) * osg::Quat(yr, osg::Vec3(0, -1, 0))
            * osg::Quat(zr, osg::Vec3(0, 0, -1));
    }

    osg::Quat makeInverseNodeRotation(const MWWorld::Ptr& ptr)
    {
        const auto& pos = ptr.getRefData().getPosition();
        return ptr.getClass().isActor() ? makeActorOsgQuat(pos) : makeInversedOrderObjectOsgQuat(pos);
    }

    osg::Quat makeDirectNodeRotation(const MWWorld::Ptr& ptr)
    {
        const auto& pos = ptr.getRefData().getPosition();
        return ptr.getClass().isActor() ? makeActorOsgQuat(pos) : Misc::Convert::makeOsgQuat(pos);
    }

    osg::Quat makeNodeRotation(const MWWorld::Ptr& ptr, RotationOrder order)
    {
        if (order == RotationOrder::inverse)
            return makeInverseNodeRotation(ptr);
        return makeDirectNodeRotation(ptr);
    }

    void setNodeRotation(const MWWorld::Ptr& ptr, MWRender::RenderingManager& rendering, const osg::Quat& rotation)
    {
        if (ptr.getRefData().getBaseNode())
            rendering.rotateObject(ptr, rotation);
    }

    VFS::Path::Normalized getModel(const MWWorld::Ptr& ptr)
    {
        if (Misc::ResourceHelpers::isHiddenMarker(ptr.getCellRef().getRefId()))
            return {};
        return ptr.getClass().getCorrectedModel(ptr);
    }

    // Null node meant to distinguish objects that aren't in the scene from paged objects
    // TODO: find a more clever way to make paging exclusion more reliable?
    static osg::ref_ptr<SceneUtil::PositionAttitudeTransform> pagedNode = new SceneUtil::PositionAttitudeTransform;

    void addObject(const MWWorld::Ptr& ptr, const MWWorld::World& world, const std::vector<ESM::RefNum>& pagedRefs,
        MWPhysics::PhysicsSystem& physics, MWRender::RenderingManager& rendering)
    {
        if (ptr.getRefData().getBaseNode() || physics.getActor(ptr))
        {
            Log(Debug::Warning) << "Warning: Tried to add " << ptr.getCellRef().getRefId() << " to the scene twice";
            return;
        }

        const VFS::Path::Normalized model = getModel(ptr);
        const auto rotation = makeDirectNodeRotation(ptr);

        ESM::RefNum refnum = ptr.getCellRef().getRefNum();
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
        setNodeRotation(ptr, rendering, rotation);

        if (ptr.getClass().useAnim())
            MWBase::Environment::get().getMechanicsManager()->add(ptr);

        if (ptr.getClass().isActor())
            rendering.addWaterRippleEmitter(ptr);

        // Restore effect particles
        world.applyLoopingParticles(ptr);

        if (!model.empty())
            ptr.getClass().insertObject(ptr, model, rotation, physics);

        MWBase::Environment::get().getLuaManager()->objectAddedToScene(ptr);
    }

    void addObject(const MWWorld::Ptr& ptr, const MWWorld::World& world, const MWPhysics::PhysicsSystem& physics,
        float& lowestPoint, bool isInterior, DetourNavigator::Navigator& navigator,
        const DetourNavigator::UpdateGuard* navigatorUpdateGuard = nullptr)
    {
        if (const auto object = physics.getObject(ptr))
        {
            // Find the lowest point of this collision object in world space from its AABB if interior
            // this point is used to determine the infinite fall cutoff from lowest point in the cell
            if (isInterior)
            {
                btVector3 aabbMin;
                btVector3 aabbMax;
                const auto transform = object->getTransform();
                object->getShapeInstance()->mCollisionShape->getAabb(transform, aabbMin, aabbMax);
                lowestPoint = std::min(lowestPoint, static_cast<float>(aabbMin.z()));
            }

            const DetourNavigator::ObjectTransform objectTransform{ ptr.getRefData().getPosition(),
                ptr.getCellRef().getScale() };

            if (ptr.getClass().isDoor() && !ptr.getCellRef().getTeleport())
            {
                btVector3 aabbMin;
                btVector3 aabbMax;
                object->getShapeInstance()->mCollisionShape->getAabb(btTransform::getIdentity(), aabbMin, aabbMax);

                const auto center = (aabbMax + aabbMin) * 0.5f;

                const auto distanceFromDoor = world.getMaxActivationDistance() * 0.5f;
                const auto toPoint = aabbMax.x() - aabbMin.x() < aabbMax.y() - aabbMin.y()
                    ? btVector3(distanceFromDoor, 0, 0)
                    : btVector3(0, distanceFromDoor, 0);

                const auto transform = object->getTransform();
                const btTransform closedDoorTransform(
                    Misc::Convert::makeBulletQuaternion(ptr.getCellRef().getPosition()), transform.getOrigin());

                const auto start = Misc::Convert::makeOsgVec3f(closedDoorTransform(center + toPoint));
                const auto startPoint = physics.castRay(start, start - osg::Vec3f(0, 0, 1000), { ptr }, {},
                    MWPhysics::CollisionType_World | MWPhysics::CollisionType_HeightMap
                        | MWPhysics::CollisionType_Water);
                const auto connectionStart = startPoint.mHit ? startPoint.mHitPos : start;

                const auto end = Misc::Convert::makeOsgVec3f(closedDoorTransform(center - toPoint));
                const auto endPoint = physics.castRay(end, end - osg::Vec3f(0, 0, 1000), { ptr }, {},
                    MWPhysics::CollisionType_World | MWPhysics::CollisionType_HeightMap
                        | MWPhysics::CollisionType_Water);
                const auto connectionEnd = endPoint.mHit ? endPoint.mHitPos : end;

                navigator.addObject(DetourNavigator::ObjectId(object),
                    DetourNavigator::DoorShapes(
                        object->getShapeInstance(), objectTransform, connectionStart, connectionEnd),
                    transform, navigatorUpdateGuard);
            }
            else if (object->getShapeInstance()->mVisualCollisionType == Resource::VisualCollisionType::None)
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
        {
            const DetourNavigator::AgentBounds agentBounds = world.getPathfindingAgentBounds(ptr);
            if (!navigator.addAgent(agentBounds))
                Log(Debug::Warning) << "Agent bounds are not supported by navigator for " << ptr.toString() << ": "
                                    << agentBounds;
        }
    }

    struct InsertVisitor
    {
        MWWorld::CellStore& mCell;
        Loading::Listener* mLoadingListener;

        std::vector<MWWorld::Ptr> mToInsert;

        InsertVisitor(MWWorld::CellStore& cell, Loading::Listener* loadingListener);

        bool operator()(const MWWorld::Ptr& ptr);

        template <class AddObject>
        void insert(AddObject&& addObject);
    };

    InsertVisitor::InsertVisitor(MWWorld::CellStore& cell, Loading::Listener* loadingListener)
        : mCell(cell)
        , mLoadingListener(loadingListener)
    {
    }

    bool InsertVisitor::operator()(const MWWorld::Ptr& ptr)
    {
        // do not insert directly as we can't modify the cell from within the visitation
        // CreatureLevList::insertObjectRendering may spawn a new creature
        mToInsert.push_back(ptr);
        return true;
    }

    template <class AddObject>
    void InsertVisitor::insert(AddObject&& addObject)
    {
        for (MWWorld::Ptr& ptr : mToInsert)
        {
            if (!ptr.mRef->isDeleted() && ptr.getRefData().isEnabled())
            {
                try
                {
                    addObject(ptr);
                }
                catch (const std::exception& e)
                {
                    Log(Debug::Error) << "failed to render '" << ptr.getCellRef().getRefId() << "': " << e.what();
                }
            }

            if (mLoadingListener != nullptr)
                mLoadingListener->increaseProgress(1);
        }
    }

    int getCellPositionDistanceToOrigin(const std::pair<int, int>& cellPosition)
    {
        return std::abs(cellPosition.first) + std::abs(cellPosition.second);
    }

    bool isCellInCollection(ESM::ExteriorCellLocation cellIndex, MWWorld::Scene::CellStoreCollection& collection)
    {
        for (auto* cell : collection)
        {
            assert(cell->getCell()->isExterior());
            if (cellIndex == cell->getCell()->getExteriorCellLocation())
                return true;
        }
        return false;
    }

    bool removeFromSorted(ESM::RefNum refNum, std::vector<ESM::RefNum>& pagedRefs)
    {
        const auto it = std::lower_bound(pagedRefs.begin(), pagedRefs.end(), refNum);
        if (it == pagedRefs.end() || *it != refNum)
            return false;
        pagedRefs.erase(it);
        return true;
    }

    template <class Function>
    void iterateOverCellsAround(int cellX, int cellY, int range, Function&& f)
    {
        for (int x = cellX - range, lastX = cellX + range; x <= lastX; ++x)
            for (int y = cellY - range, lastY = cellY + range; y <= lastY; ++y)
                f(x, y);
    }

    void sortCellsToLoad(int centerX, int centerY, std::vector<std::pair<int, int>>& cells)
    {
        const auto getDistanceToPlayerCell = [&](const std::pair<int, int>& cellPosition) {
            return std::abs(cellPosition.first - centerX) + std::abs(cellPosition.second - centerY);
        };

        const auto getCellPositionPriority = [&](const std::pair<int, int>& cellPosition) {
            return std::make_pair(getDistanceToPlayerCell(cellPosition), getCellPositionDistanceToOrigin(cellPosition));
        };

        std::sort(cells.begin(), cells.end(), [&](const std::pair<int, int>& lhs, const std::pair<int, int>& rhs) {
            return getCellPositionPriority(lhs) < getCellPositionPriority(rhs);
        });
    }

}

namespace MWWorld
{
    // TSP_SCENE_V2 build tag - volatile so it reaches the binary and "grep -a"
    // can prove which scene.cpp the running openmw was built from.
    const char* volatile tspSceneBuildTagV2 = "TSP_SCENE_V2_TERRAIN_LEAD_ASYNC";

    void Scene::removeFromPagedRefs(const Ptr& ptr)
    {
        ESM::RefNum refnum = ptr.getCellRef().getRefNum();
        if (refnum.hasContentFile() && removeFromSorted(refnum, mPagedRefs))
        {
            // TSP_ROOM_OBJECT_LIFECYCLE_051_V25
            mTspRoomSuppressedRefs.erase(refnum);
            if (!ptr.getRefData().getBaseNode())
                return;
            ptr.getClass().insertObjectRendering(ptr, getModel(ptr), mRendering);
            setNodeRotation(ptr, mRendering, makeNodeRotation(ptr, RotationOrder::direct));
            reloadTerrain();
        }
    }

    bool Scene::isPagedRef(const Ptr& ptr) const
    {
        return ptr.getRefData().getBaseNode() == pagedNode.get();
    }

    void Scene::updateObjectRotation(const Ptr& ptr, RotationOrder order)
    {
        const auto rot = makeNodeRotation(ptr, order);
        setNodeRotation(ptr, mRendering, rot);
        mPhysics->updateRotation(ptr, rot);
    }

    void Scene::updateObjectScale(const Ptr& ptr)
    {
        float scale = ptr.getCellRef().getScale();
        osg::Vec3f scaleVec(scale, scale, scale);
        ptr.getClass().adjustScale(ptr, scaleVec, true);
        mRendering.scaleObject(ptr, scaleVec);
        mPhysics->updateScale(ptr);
    }

    // TSP_ROOM_OBJECT_LIFECYCLE_051_V25
    bool Scene::tspRoomObjectEligible(const Ptr& ptr) const
    {
        if (mCurrentCell == nullptr || mCurrentCell->isExterior())
            return false;
        if (ptr.getCell() != mCurrentCell)
            return false;
        if (ptr.mRef->isDeleted() || !ptr.getRefData().isEnabled()
            || ptr.mRef->mRef.getCount() <= 0)
            return false;
        if (ptr.getClass().isActor() || ptr.getClass().isDoor())
            return false;

        const int type = ptr.getType();
        // TSP_ROOM_OBJECT_ADAPTIVE_051_V27
        // Static architecture and Activators are the lenient structural tier.
        // The hard lifecycle is reserved for clutter/gameplay objects whose room
        // residency produced the V26 performance win.
        if (type == ESM::REC_STAT || type == ESM::REC_STAT4
            || type == ESM::REC_ACTI || type == ESM::REC_ACTI4)
            return false;

        const ESM::RefNum refnum = ptr.getCellRef().getRefNum();
        if (!refnum.hasContentFile())
            return false;

        return !getModel(ptr).empty();
    }

    void Scene::tspRoomSuppressObject(const Ptr& ptr)
    {
        const ESM::RefNum refnum = ptr.getCellRef().getRefNum();
        if (!refnum.hasContentFile()
            || mTspRoomSuppressedRefs.find(refnum) != mTspRoomSuppressedRefs.end())
            return;

        // Remove scene-side machinery only. The CellStore/live ref and persistent
        // enabled/deleted/count/inventory/script state remain authoritative.
        MWBase::Environment::get().getMechanicsManager()->remove(ptr, true);

        if (const auto object = mPhysics->getObject(ptr))
        {
            if (object->getShapeInstance()->mVisualCollisionType
                == Resource::VisualCollisionType::None)
                mNavigator.removeObject(DetourNavigator::ObjectId(object), nullptr);
        }

        mPhysics->remove(ptr);
        mRendering.removeObject(ptr);
        ptr.getRefData().setBaseNode(pagedNode);

        const auto pos = std::lower_bound(mPagedRefs.begin(), mPagedRefs.end(), refnum);
        if (pos == mPagedRefs.end() || *pos != refnum)
            mPagedRefs.insert(pos, refnum);

        mTspRoomSuppressedRefs.insert(refnum);
        ++mTspRoomSuppressTotal;
    }

    void Scene::tspRoomWakeObject(const Ptr& ptr)
    {
        const ESM::RefNum refnum = ptr.getCellRef().getRefNum();
        const auto suppressed = mTspRoomSuppressedRefs.find(refnum);
        if (suppressed == mTspRoomSuppressedRefs.end())
            return;

        removeFromSorted(refnum, mPagedRefs);
        mTspRoomSuppressedRefs.erase(suppressed);

        if (ptr.mRef->isDeleted() || !ptr.getRefData().isEnabled()
            || ptr.mRef->mRef.getCount() <= 0)
        {
            ptr.getRefData().setBaseNode(nullptr);
            return;
        }

        if (ptr.getRefData().getBaseNode() == pagedNode.get())
            ptr.getRefData().setBaseNode(nullptr);

        const VFS::Path::Normalized model = getModel(ptr);
        if (model.empty())
            return;

        const auto rotation = makeDirectNodeRotation(ptr);
        ptr.getClass().insertObjectRendering(ptr, model, mRendering);
        setNodeRotation(ptr, mRendering, rotation);

        if (ptr.getClass().useAnim())
            MWBase::Environment::get().getMechanicsManager()->add(ptr);

        mWorld.applyLoopingParticles(ptr);
        ptr.getClass().insertObject(ptr, model, rotation, *mPhysics);
        addObject(ptr, mWorld, *mPhysics, mLowestPoint, true, mNavigator);
        ++mTspRoomWakeTotal;
    }

    void Scene::tspUpdateRoomObjectLifecycle(float duration)
    {
        if (mCurrentCell != mTspRoomLifecycleCell)
        {
            mTspRoomLifecycleCell = mCurrentCell;
            mTspRoomSuppressedRefs.clear();
            mTspRoomLifecycleAccumulator = 0.f;
            mTspRoomLogAccumulator = 0.f;
        }

        if (mCurrentCell == nullptr || mCurrentCell->isExterior())
            return;

        mTspRoomLifecycleAccumulator += std::max(0.f, duration);
        mTspRoomLogAccumulator += std::max(0.f, duration);
        if (mTspRoomLifecycleAccumulator < 0.05f)
            return;
        mTspRoomLifecycleAccumulator = 0.f;

        const bool pvsEnabled = MWRender::isInteriorTopologyPvsEnabled();
        std::vector<Ptr> toWake;
        std::vector<Ptr> toSuppress;
        int eligible = 0;
        int resident = 0;
        int inactive = 0;

        mCurrentCell->forEach([&](const Ptr& ptr) {
            if (!tspRoomObjectEligible(ptr))
                return true;

            ++eligible;
            const ESM::RefNum refnum = ptr.getCellRef().getRefNum();
            const osg::Vec3f origin = ptr.getRefData().getPosition().asVec3();
            // TSP_ROOM_OBJECT_ADAPTIVE_051_V27
            // Adaptive ROOM residency, still with ZERO object-radius keepalive.
            // Nearby rooms are selected in Lua; an object's own radius never punches
            // through a wall and forces it resident.
            // TSP_ROOM_LIGHT_KEEPALIVE_051_V30_R5
            // Lights get 3x R4 minimum inter-room distance; other objects remain radius 0.
            const bool tspRoomExtendedLight = ptr.getType() == ESM::REC_LIGH;
            const float tspRoomObjectRadius = tspRoomExtendedLight ? 1560.f : 0.f;
            const bool shouldLive = MWRender::isInteriorTopologyObjectResident(
                origin, tspRoomObjectRadius, false);

            if (shouldLive)
            {
                ++resident;
                if (mTspRoomSuppressedRefs.find(refnum) != mTspRoomSuppressedRefs.end())
                    toWake.push_back(ptr);
            }
            else
            {
                ++inactive;
                if (mTspRoomSuppressedRefs.find(refnum) == mTspRoomSuppressedRefs.end())
                    toSuppress.push_back(ptr);
            }
            return true;
        });

        // V26 CURRENT-SECTOR-ONLY: there is deliberately no prewarm queue.
        // Complete each room-state transition in one lifecycle pass so a 10-second
        // stationary test cannot hide behind an amortization budget.
        constexpr std::size_t wakeBudget = 4096;
        constexpr std::size_t suppressBudget = 4096;
        for (std::size_t i = 0; i < toWake.size() && i < wakeBudget; ++i)
            tspRoomWakeObject(toWake[i]);
        for (std::size_t i = 0; i < toSuppress.size() && i < suppressBudget; ++i)
            tspRoomSuppressObject(toSuppress[i]);

        if (mTspRoomLogAccumulator >= 1.f)
        {
            mTspRoomLogAccumulator = 0.f;
            Log(Debug::Info)
                << "[TSP_ROOMOBJ_V30] lightKeepXY=1560 pvs=" << (pvsEnabled ? 1 : 0)
                << " eligible=" << eligible
                << " resident=" << resident
                << " inactive=" << inactive
                << " parked=" << mTspRoomSuppressedRefs.size()
                << " wakeQ=" << toWake.size()
                << " suppressQ=" << toSuppress.size()
                << " suppressTotal=" << mTspRoomSuppressTotal
                << " wakeTotal=" << mTspRoomWakeTotal;
        }
    }

    // TSP_ROOM_ACTOR_HIBERNATE_051_V30
    void Scene::tspWakeSleepingRoomActors(CellStore* cell, const char* reason)
    {
        if (cell == nullptr || mTspRoomSleepingActors.empty())
            return;

        MWBase::MechanicsManager* const mechanics = MWBase::Environment::get().getMechanicsManager();
        const std::size_t requested = mTspRoomSleepingActors.size();
        std::size_t woke = 0;

        cell->forEach([&](const Ptr& ptr) {
            if (!ptr.getClass().isActor())
                return true;

            const ESM::RefNum refnum = ptr.getCellRef().getRefNum();
            const auto sleeping = mTspRoomSleepingActors.find(refnum);
            if (sleeping == mTspRoomSleepingActors.end())
                return true;

            mTspRoomSleepingActors.erase(sleeping);
            if (!ptr.mRef->isDeleted() && ptr.getRefData().isEnabled()
                && ptr.mRef->mRef.getCount() > 0 && ptr.getRefData().getBaseNode())
            {
                mechanics->add(ptr);
                ++mTspRoomActorWakeTotal;
                ++woke;
            }
            return true;
        });

        const std::size_t missing = mTspRoomSleepingActors.size();
        mTspRoomSleepingActors.clear();
        Log(Debug::Info)
            << "[TSP_ACTOR_V30] wake-all reason=" << reason
            << " requested=" << requested
            << " woke=" << woke
            << " missing=" << missing;
    }

    void Scene::tspUpdateRoomActorLifecycle(float duration)
    {
        if (mCurrentCell != mTspRoomActorCell)
        {
            if (mTspRoomActorCell != nullptr && !mTspRoomSleepingActors.empty())
                tspWakeSleepingRoomActors(mTspRoomActorCell, "cell-change");

            mTspRoomActorCell = mCurrentCell;
            mTspRoomSleepingActors.clear();
            mTspRoomActorAccumulator = 0.f;
            mTspRoomActorSenseAccumulator = 0.25f; // first pass evaluates awareness immediately
            mTspRoomActorLogAccumulator = 0.f;
        }

        if (mCurrentCell == nullptr || mCurrentCell->isExterior())
            return;

        mTspRoomActorAccumulator += std::max(0.f, duration);
        mTspRoomActorSenseAccumulator += std::max(0.f, duration);
        mTspRoomActorLogAccumulator += std::max(0.f, duration);
        if (mTspRoomActorAccumulator < 0.05f)
            return;
        mTspRoomActorAccumulator = 0.f;

        const bool pvsEnabled = MWRender::isInteriorTopologyPvsEnabled();
        if (!pvsEnabled)
        {
            if (!mTspRoomSleepingActors.empty())
                tspWakeSleepingRoomActors(mCurrentCell, "authority-off");
            return;
        }

        const bool senseDue = mTspRoomActorSenseAccumulator >= 0.25f;
        if (senseDue)
            mTspRoomActorSenseAccumulator = 0.f;

        MWBase::World* const world = MWBase::Environment::get().getWorld();
        MWBase::MechanicsManager* const mechanics = MWBase::Environment::get().getMechanicsManager();
        const Ptr player = world->getPlayerPtr();
        const osg::Vec3f playerPos = player.getRefData().getPosition().asVec3();

        std::vector<Ptr> toWake;
        std::vector<Ptr> toSleep;
        int eligible = 0;
        int roomAwake = 0;
        int offRoom = 0;
        int protectedCombat = 0;
        int protectedSense = 0;
        int senseHold = 0;
        int sleepingNow = 0;

        mCurrentCell->forEach([&](const Ptr& ptr) {
            if (!ptr.getClass().isActor() || ptr == player)
                return true;
            if (ptr.mRef->isDeleted() || !ptr.getRefData().isEnabled()
                || ptr.mRef->mRef.getCount() <= 0 || !ptr.getRefData().getBaseNode())
                return true;

            const ESM::RefNum refnum = ptr.getCellRef().getRefNum();
            if (!refnum.hasContentFile())
                return true; // dynamically-created actors fail open for safety

            MWMechanics::CreatureStats& stats = ptr.getClass().getCreatureStats(ptr);
            if (stats.isDead())
                return true; // never disturb corpse/death animation state in this first actor pass

            ++eligible;
            const bool isSleeping = mTspRoomSleepingActors.find(refnum) != mTspRoomSleepingActors.end();
            const osg::Vec3f origin = ptr.getRefData().getPosition().asVec3();
            const bool roomResident = MWRender::isInteriorTopologyObjectResident(origin, 0.f, false);

            if (roomResident)
            {
                ++roomAwake;
                if (isSleeping)
                    toWake.push_back(ptr);
                return true;
            }

            ++offRoom;
            const auto& ai = stats.getAiSequence();
            if (ai.isInCombat() || ai.isInPursuit())
            {
                ++protectedCombat;
                if (isSleeping)
                    toWake.push_back(ptr);
                return true;
            }

            if (senseDue)
            {
                // Only actors close enough to plausibly matter pay the LOS+awareness cost.
                // Physics remains present while sleeping, so this test still has real walls.
                constexpr float senseMax = 1800.f;
                const float dist2 = (playerPos - origin).length2();
                const bool sensesPlayer = dist2 <= senseMax * senseMax
                    && world->getLOS(ptr, player)
                    && mechanics->awarenessCheck(player, ptr, false);
                if (sensesPlayer)
                {
                    ++protectedSense;
                    if (isSleeping)
                        toWake.push_back(ptr);
                    return true;
                }
            }
            else if (!isSleeping)
            {
                // Do not put an awake actor to sleep between awareness samples.
                ++senseHold;
                return true;
            }

            if (isSleeping)
                ++sleepingNow;
            else
                toSleep.push_back(ptr);
            return true;
        });

        // Room/combat/awareness wakes are always processed before new sleeps.
        constexpr std::size_t wakeBudget = 128;
        constexpr std::size_t sleepBudget = 128;
        for (std::size_t i = 0; i < toWake.size() && i < wakeBudget; ++i)
        {
            const Ptr& ptr = toWake[i];
            const ESM::RefNum refnum = ptr.getCellRef().getRefNum();
            const auto sleeping = mTspRoomSleepingActors.find(refnum);
            if (sleeping == mTspRoomSleepingActors.end())
                continue;
            mTspRoomSleepingActors.erase(sleeping);
            mechanics->add(ptr);
            ++mTspRoomActorWakeTotal;
        }

        for (std::size_t i = 0; i < toSleep.size() && i < sleepBudget; ++i)
        {
            const Ptr& ptr = toSleep[i];
            const ESM::RefNum refnum = ptr.getCellRef().getRefNum();
            if (mTspRoomSleepingActors.find(refnum) != mTspRoomSleepingActors.end())
                continue;

            mechanics->remove(ptr, true);
            if (osg::Node* const node = ptr.getRefData().getBaseNode())
                node->setNodeMask(0u);
            mTspRoomSleepingActors.insert(refnum);
            ++mTspRoomActorSleepTotal;
        }

        if (mTspRoomActorLogAccumulator >= 1.f)
        {
            mTspRoomActorLogAccumulator = 0.f;
            Log(Debug::Info)
                << "[TSP_ACTOR_V30] authority=1"
                << " eligible=" << eligible
                << " roomAwake=" << roomAwake
                << " offRoom=" << offRoom
                << " sleeping=" << mTspRoomSleepingActors.size()
                << " sleepQ=" << toSleep.size()
                << " wakeQ=" << toWake.size()
                << " combat=" << protectedCombat
                << " sense=" << protectedSense
                << " senseHold=" << senseHold
                << " sleepTotal=" << mTspRoomActorSleepTotal
                << " wakeTotal=" << mTspRoomActorWakeTotal;
        }
    }

    void Scene::update(float duration)
    {
        if (mChangeCellGridRequest.has_value())
        {
            changeCellGrid(mChangeCellGridRequest->mPosition, mChangeCellGridRequest->mCellIndex,
                mChangeCellGridRequest->mChangeEvent);
            mChangeCellGridRequest.reset();
        }

        mPreloader->updateCache(mRendering.getReferenceTime());
        preloadCells(duration);

        // TSP_ROOM_OBJECT_LIFECYCLE_051_V25
        tspUpdateRoomObjectLifecycle(duration);

        // TSP_ROOM_ACTOR_HIBERNATE_051_V30
        tspUpdateRoomActorLifecycle(duration);
    }

    void Scene::unloadCell(CellStore* cell, const DetourNavigator::UpdateGuard* navigatorUpdateGuard)
    {
        if (mActiveCells.find(cell) == mActiveCells.end())
            return;

        // TSP_ROOM_ACTOR_HIBERNATE_051_V30
        // Re-register sleeping actors before normal cell teardown so MechanicsManager::drop
        // remains the sole owner of unload-time temporary-effect cleanup.
        if (cell == mTspRoomActorCell && !mTspRoomSleepingActors.empty())
        {
            tspWakeSleepingRoomActors(cell, "unload");
            mTspRoomActorCell = nullptr;
            mTspRoomActorAccumulator = 0.f;
            mTspRoomActorSenseAccumulator = 0.25f;
            mTspRoomActorLogAccumulator = 0.f;
        }

        // TSP_ROOM_OBJECT_ADAPTIVE_051_V27
        // Parked V25/V26 refs borrowed mPagedRefs only as a scene-side sentinel.
        // Purge those temporary entries BEFORE normal cell teardown so shutdown or
        // load-door transitions never carry stale parked bookkeeping forward.
        if (cell == mTspRoomLifecycleCell && !mTspRoomSuppressedRefs.empty())
        {
            const std::size_t tspParked = mTspRoomSuppressedRefs.size();
            for (const ESM::RefNum& refnum : mTspRoomSuppressedRefs)
                removeFromSorted(refnum, mPagedRefs);
            mTspRoomSuppressedRefs.clear();
            mTspRoomLifecycleCell = nullptr;
            mTspRoomLifecycleAccumulator = 0.f;
            mTspRoomLogAccumulator = 0.f;
            Log(Debug::Info) << "[TSP_ROOMOBJ_V30] unload-purge parked=" << tspParked;
        }

        Log(Debug::Info) << "Unloading cell " << cell->getCell()->getDescription();

        ListAndResetObjectsVisitor visitor;

        cell->forEach(visitor, true); // Include objects being teleported by Lua
        for (const auto& ptr : visitor.mObjects)
        {
            if (const auto object = mPhysics->getObject(ptr))
            {
                if (object->getShapeInstance()->mVisualCollisionType == Resource::VisualCollisionType::None)
                    mNavigator.removeObject(DetourNavigator::ObjectId(object), navigatorUpdateGuard);
                mPhysics->remove(ptr);
            }
            else if (mPhysics->getActor(ptr))
            {
                mNavigator.removeAgent(mWorld.getPathfindingAgentBounds(ptr));
                mRendering.removeActorPath(ptr);
                mPhysics->remove(ptr);
            }
            else
                ptr.mRef->mData.mPhysicsPostponed = false;
            MWBase::Environment::get().getLuaManager()->objectRemovedFromScene(ptr);
        }

        const auto cellX = cell->getCell()->getGridX();
        const auto cellY = cell->getCell()->getGridY();

        if (cell->getCell()->isExterior())
        {
            mNavigator.removeHeightfield(osg::Vec2i(cellX, cellY), navigatorUpdateGuard);
            mPhysics->removeHeightField(cellX, cellY);
        }

        if (cell->getCell()->hasWater())
            mNavigator.removeWater(osg::Vec2i(cellX, cellY), navigatorUpdateGuard);

        ESM::visit(ESM::VisitOverload{
                       [&](const ESM::Cell& c) {
                           if (const auto pathgrid = mWorld.getStore().get<ESM::Pathgrid>().search(c))
                               mNavigator.removePathgrid(*pathgrid);
                       },
                       [&](const ESM4::Cell& /*c*/) {},
                   },
            *cell->getCell());

        MWBase::Environment::get().getMechanicsManager()->drop(cell);

        mRendering.removeCell(cell);
        MWBase::Environment::get().getWindowManager()->removeCell(cell);

        mWorld.getLocalScripts().clearCell(cell);

        MWBase::Environment::get().getSoundManager()->stopSound(cell);
        mActiveCells.erase(cell);
        // Clean up any effects that may have been spawned while unloading all cells
        if (mActiveCells.empty())
            mRendering.notifyWorldSpaceChanged();
    }

    void Scene::loadCell(CellStore& cell, Loading::Listener* loadingListener, bool respawn, const osg::Vec3f& position,
        const DetourNavigator::UpdateGuard* navigatorUpdateGuard)
    {
        using DetourNavigator::HeightfieldShape;

        assert(mActiveCells.find(&cell) == mActiveCells.end());
        mActiveCells.insert(&cell);

        Log(Debug::Info) << "Loading cell " << cell.getCell()->getDescription();

        const int cellX = cell.getCell()->getGridX();
        const int cellY = cell.getCell()->getGridY();
        const MWWorld::Cell& cellVariant = *cell.getCell();
        ESM::RefId worldspace = cellVariant.getWorldSpace();
        ESM::ExteriorCellLocation cellIndex(cellX, cellY, worldspace);

        if (cellVariant.isExterior())
        {
            osg::ref_ptr<const ESMTerrain::LandObject> land = mRendering.getLandManager()->getLand(cellIndex);
            const ESM::LandData* data = land ? land->getData(ESM::Land::DATA_VHGT) : nullptr;
            const int verts = ESM::getLandSize(worldspace);
            const int worldsize = ESM::getCellSize(worldspace);

            if (data)
            {
                mPhysics->addHeightField(data->getHeights().data(), cellX, cellY, worldsize, verts,
                    data->getMinHeight(), data->getMaxHeight(), land.get());
            }
            else if (!ESM::isEsm4Ext(worldspace))
            {
                static const std::vector<float> defaultHeight(verts * verts, ESM::Land::DEFAULT_HEIGHT);
                mPhysics->addHeightField(defaultHeight.data(), cellX, cellY, worldsize, verts,
                    ESM::Land::DEFAULT_HEIGHT, ESM::Land::DEFAULT_HEIGHT, land.get());
            }
            if (mPhysics->getHeightField(cellX, cellY))
            {
                const osg::Vec2i cellPosition(cellX, cellY);
                const HeightfieldShape shape = [&]() -> HeightfieldShape {
                    if (data == nullptr)
                    {
                        return DetourNavigator::HeightfieldPlane{ static_cast<float>(ESM::Land::DEFAULT_HEIGHT) };
                    }
                    else
                    {
                        DetourNavigator::HeightfieldSurface heights;
                        heights.mHeights = data->getHeights().data();
                        heights.mSize = static_cast<std::size_t>(data->getLandSize());
                        heights.mMinHeight = data->getMinHeight();
                        heights.mMaxHeight = data->getMaxHeight();
                        return heights;
                    }
                }();
                mNavigator.addHeightfield(cellPosition, worldsize, shape, navigatorUpdateGuard);
            }
        }

        ESM::visit(ESM::VisitOverload{
                       [&](const ESM::Cell& c) {
                           if (const auto pathgrid = mWorld.getStore().get<ESM::Pathgrid>().search(c))
                               mNavigator.addPathgrid(c, *pathgrid);
                       },
                       [&](const ESM4::Cell& /*c*/) {},
                   },
            *cell.getCell());

        // register local scripts
        // do this before insertCell, to make sure we don't add scripts from levelled creature spawning twice
        mWorld.getLocalScripts().addCell(&cell);

        if (respawn)
            cell.respawn();

        insertCell(cell, loadingListener, navigatorUpdateGuard);

        mRendering.addCell(&cell);

        MWBase::Environment::get().getWindowManager()->addCell(&cell);
        bool waterEnabled = cellVariant.hasWater() || cell.isExterior();
        float waterLevel = cell.getWaterLevel();
        mRendering.setWaterEnabled(waterEnabled);
        if (waterEnabled)
        {
            mPhysics->enableWater(waterLevel);
            mRendering.setWaterHeight(waterLevel);

            if (cellVariant.isExterior())
            {
                if (mPhysics->getHeightField(cellX, cellY))
                    mNavigator.addWater(
                        osg::Vec2i(cellX, cellY), ESM::Land::REAL_SIZE, waterLevel, navigatorUpdateGuard);
            }
            else
            {
                mNavigator.addWater(
                    osg::Vec2i(cellX, cellY), std::numeric_limits<int>::max(), waterLevel, navigatorUpdateGuard);
            }
        }
        else
            mPhysics->disableWater();

        if (!cell.isExterior() && !cellVariant.isQuasiExterior())
            mRendering.configureAmbient(cellVariant);

        mPreloader->notifyLoaded(&cell);
    }

    void Scene::clear()
    {
        auto navigatorUpdateGuard = mNavigator.makeUpdateGuard();
        for (auto iter = mActiveCells.begin(); iter != mActiveCells.end();)
        {
            auto* cell = *iter++;
            unloadCell(cell, navigatorUpdateGuard.get());
        }
        navigatorUpdateGuard.reset();
        assert(mActiveCells.empty());
        mCurrentCell = nullptr;
        mLowestPoint = std::numeric_limits<float>::max();

        mPreloader->clear();
    }

    osg::Vec4i Scene::gridCenterToBounds(const osg::Vec2i& centerCell) const
    {
        return osg::Vec4i(centerCell.x() - mHalfGridSize, centerCell.y() - mHalfGridSize,
            centerCell.x() + mHalfGridSize + 1, centerCell.y() + mHalfGridSize + 1);
    }

    osg::Vec2i Scene::getNewGridCenter(const osg::Vec3f& pos, const osg::Vec2i* currentGridCenter) const
    {
        ESM::RefId worldspace
            = mCurrentCell ? mCurrentCell->getCell()->getWorldSpace() : ESM::Cell::sDefaultWorldspaceId;
        if (currentGridCenter)
        {
            const osg::Vec2f center = ESM::indexToPosition(
                ESM::ExteriorCellLocation(currentGridCenter->x(), currentGridCenter->y(), worldspace), true);
            float distance = std::max(std::abs(center.x() - pos.x()), std::abs(center.y() - pos.y()));
            int cellSize = ESM::getCellSize(worldspace);
            const float maxDistance = cellSize / 2 + mCellLoadingThreshold; // 1/2 cell size + threshold
            if (distance <= maxDistance)
                return *currentGridCenter;
        }
        ESM::ExteriorCellLocation cellPos = ESM::positionToExteriorCellLocation(pos.x(), pos.y(), worldspace);
        return { cellPos.mX, cellPos.mY };
    }

    void Scene::playerMoved(const osg::Vec3f& pos)
    {
        if (!mCurrentCell)
            return;

        // The player is reset when z is 90 units below the lowest reference bound z.
        constexpr float lowestPointAdjustment = -90.0f;
        if (mCurrentCell->isExterior())
        {
            osg::Vec2i newCell = getNewGridCenter(pos, &mCurrentGridCenter);
            if (newCell != mCurrentGridCenter)
                requestChangeCellGrid(pos, newCell);
        }
        else if (pos.z() < mLowestPoint + lowestPointAdjustment)
        {
            // Player has fallen into the void, reset to interior marker/coc (#1415)
            const std::string_view cellNameId = mCurrentCell->getCell()->getNameId();
            MWBase::World* world = MWBase::Environment::get().getWorld();
            MWWorld::Ptr playerPtr = world->getPlayerPtr();

            // Check that collision is enabled, which is opposite to Vanilla
            // this change was decided in MR #4100 as the behaviour is preferable
            if (world->isActorCollisionEnabled(playerPtr))
            {
                ESM::Position newPos;
                const ESM::RefId refId = world->findInteriorPosition(cellNameId, newPos);

                // Only teleport if that teleport point is > the lowest point, rare edge case
                if (!refId.empty() && newPos.pos[2] >= mLowestPoint - lowestPointAdjustment)
                {
                    MWWorld::ActionTeleport(refId, newPos, false).execute(playerPtr);
                    Log(Debug::Warning) << "Player position has been reset due to falling into the void";
                }
            }
        }
    }

    void Scene::requestChangeCellGrid(const osg::Vec3f& position, const osg::Vec2i& cell, bool changeEvent)
    {
        mChangeCellGridRequest = ChangeCellGridRequest{ position,
            ESM::ExteriorCellLocation(cell.x(), cell.y(), mCurrentCell->getCell()->getWorldSpace()), changeEvent };
    }

    void Scene::changeCellGrid(const osg::Vec3f& pos, ESM::ExteriorCellLocation playerCellIndex, bool changeEvent)
    {
        const int halfGridSize
            = isEsm4Ext(playerCellIndex.mWorldspace) ? Constants::ESM4CellGridRadius : Constants::CellGridRadius;
        auto navigatorUpdateGuard = mNavigator.makeUpdateGuard();
        const int playerCellX = playerCellIndex.mX;
        const int playerCellY = playerCellIndex.mY;

        for (auto iter = mActiveCells.begin(); iter != mActiveCells.end();)
        {
            auto* cell = *iter++;
            if (cell->getCell()->isExterior() && cell->getCell()->getWorldSpace() == playerCellIndex.mWorldspace)
            {
                const auto dx = std::abs(playerCellX - cell->getCell()->getGridX());
                const auto dy = std::abs(playerCellY - cell->getCell()->getGridY());
                if (dx > halfGridSize || dy > halfGridSize)
                    unloadCell(cell, navigatorUpdateGuard.get());
            }
            else
                unloadCell(cell, navigatorUpdateGuard.get());
        }

        const DetourNavigator::CellGridBounds cellGridBounds{
            .mCenter = osg::Vec2i(playerCellX, playerCellY),
            .mHalfSize = halfGridSize,
        };

        mNavigator.updateBounds(playerCellIndex.mWorldspace, cellGridBounds, pos, navigatorUpdateGuard.get());

        mHalfGridSize = halfGridSize;
        // TSP_TERRAIN_STREAM_V2 - captured before mCurrentGridCenter is overwritten below
        const osg::Vec2i tspPrevGridCenter = mCurrentGridCenter;
        mCurrentGridCenter = osg::Vec2i(playerCellX, playerCellY);
        osg::Vec4i newGrid = gridCenterToBounds(mCurrentGridCenter);

        // NOTE: setActiveGrid must be after enableTerrain, otherwise we set the grid in the old exterior worldspace
        mRendering.enableTerrain(true, playerCellIndex.mWorldspace);
        mRendering.setActiveGrid(newGrid);

        mPreloader->setTerrain(mRendering.getTerrain());
        if (mRendering.pagingUnlockCache())
            mPreloader->abortTerrainPreloadExcept(nullptr);
        // TSP_TERRAIN_STREAM_V2
        // preloadTerrain(..., true) ends in CellPreloader::syncTerrainLoad, which
        // blocks the main thread on mTerrainPreloadItem->wait(). changeCellGrid runs
        // from Scene::update inside mWorld->update(), so that block lands in the
        // profiler's world slot: frame 43443 measured world 396.2 ms with only ~76 ms
        // of executed CPU - 320 ms of the main thread doing nothing at all.
        //
        // And it waits on the wrong item. preloadTerrain first calls
        // abortTerrainPreloadExcept(&position), which returns early whenever the
        // in-flight set already covers this position, then
        // setTerrainPreloadPositions(span(&position,1)) - which opens with
        //     if (mTerrainPreloadItem && !mTerrainPreloadItem->isDone()) return;
        // and silently discards the position it was handed. So the wait that follows
        // is for a preload aimed somewhere else, and the grid actually needed is still
        // not resident when the wait returns.
        //
        // Blocking is right on the teleport/load path - the loading screen is already
        // up there. It is never right while walking. tspStreaming separates the two:
        // same worldspace, a grid already loaded, centre moving at most one cell. On
        // that path terrain is left to preloadCells above, which reissues both
        // positions every frame and finishes on a worker thread.
        const bool tspStreaming = !mActiveCells.empty() && mCurrentCell != nullptr
            && mCurrentCell->isExterior()
            && mCurrentCell->getCell()->getWorldSpace() == playerCellIndex.mWorldspace
            && std::abs(playerCellX - tspPrevGridCenter.x()) <= 1
            && std::abs(playerCellY - tspPrevGridCenter.y()) <= 1;
        if (!tspStreaming
            && !mPreloader->isTerrainLoaded(PositionCellGrid{ pos, newGrid }, mRendering.getReferenceTime()))
            preloadTerrain(pos, playerCellIndex.mWorldspace, true);
        mPagedRefs.clear();
        mRendering.getPagedRefnums(newGrid, mPagedRefs);

        addPostponedPhysicsObjects();

        std::size_t refsToLoad = 0;
        std::vector<std::pair<int, int>> cellsPositionsToLoad;
        iterateOverCellsAround(playerCellX, playerCellY, mHalfGridSize, [&](int x, int y) {
            const ESM::ExteriorCellLocation location(x, y, playerCellIndex.mWorldspace);
            if (isCellInCollection(location, mActiveCells))
                return;
            refsToLoad += mWorld.getWorldModel().getExterior(location).count();
            cellsPositionsToLoad.emplace_back(x, y);
        });

        Loading::Listener* loadingListener = MWBase::Environment::get().getWindowManager()->getLoadingScreen();
        Loading::ScopedLoad load(loadingListener);
        loadingListener->setLabel("#{OMWEngine:LoadingExterior}");
        loadingListener->setProgressRange(refsToLoad);

        sortCellsToLoad(playerCellX, playerCellY, cellsPositionsToLoad);

        for (const auto& [x, y] : cellsPositionsToLoad)
        {
            ESM::ExteriorCellLocation indexToLoad = { x, y, playerCellIndex.mWorldspace };
            if (!isCellInCollection(indexToLoad, mActiveCells))
            {
                CellStore& cell = mWorld.getWorldModel().getExterior(indexToLoad);
                loadCell(cell, loadingListener, changeEvent, pos, navigatorUpdateGuard.get());
            }
        }

        mNavigator.update(pos, navigatorUpdateGuard.get());

        navigatorUpdateGuard.reset();

        CellStore& current = mWorld.getWorldModel().getExterior(playerCellIndex);
        MWBase::Environment::get().getWindowManager()->changeCell(&current);

        if (changeEvent)
            mCellChanged = true;

        mCellLoaded = true;
    }

    void Scene::addPostponedPhysicsObjects()
    {
        for (const auto& cell : mActiveCells)
        {
            cell->forEach([&](const MWWorld::Ptr& ptr) {
                if (ptr.mRef->mData.mPhysicsPostponed)
                {
                    ptr.mRef->mData.mPhysicsPostponed = false;
                    if (ptr.mRef->mData.isEnabled() && ptr.mRef->mRef.getCount() > 0)
                    {
                        const VFS::Path::Normalized model = getModel(ptr);
                        if (!model.empty())
                        {
                            const auto rotation = makeNodeRotation(ptr, RotationOrder::direct);
                            ptr.getClass().insertObjectPhysics(ptr, model, rotation, *mPhysics);
                        }
                    }
                }
                return true;
            });
        }
    }

    void Scene::testExteriorCells()
    {
        // Note: temporary disable ICO to decrease memory usage
        mRendering.getResourceSystem()->getSceneManager()->setIncrementalCompileOperation(nullptr);

        mRendering.getResourceSystem()->setExpiryDelay(1.f);

        const MWWorld::Store<ESM::Cell>& cells = mWorld.getStore().get<ESM::Cell>();

        Loading::Listener* loadingListener = MWBase::Environment::get().getWindowManager()->getLoadingScreen();
        Loading::ScopedLoad load(loadingListener);
        loadingListener->setProgressRange(cells.getExtSize());

        MWWorld::Store<ESM::Cell>::iterator it = cells.extBegin();
        int i = 1;
        auto navigatorUpdateGuard = mNavigator.makeUpdateGuard();
        for (; it != cells.extEnd(); ++it)
        {
            loadingListener->setLabel("#{OMWEngine:TestingExteriorCells} (" + std::to_string(i) + "/"
                + std::to_string(cells.getExtSize()) + ")...");

            CellStore& cell = mWorld.getWorldModel().getExterior(
                ESM::ExteriorCellLocation(it->mData.mX, it->mData.mY, ESM::Cell::sDefaultWorldspaceId));
            const osg::Vec3f position
                = osg::Vec3f(it->mData.mX + 0.5f, it->mData.mY + 0.5f, 0) * Constants::CellSizeInUnits;
            const osg::Vec2i cellPosition(it->mData.mX, it->mData.mY);

            const DetourNavigator::CellGridBounds cellGridBounds{
                .mCenter = osg::Vec2i(it->mData.mX, it->mData.mY),
                .mHalfSize = Constants::CellGridRadius,
            };

            mNavigator.updateBounds(
                ESM::Cell::sDefaultWorldspaceId, cellGridBounds, position, navigatorUpdateGuard.get());

            loadCell(cell, nullptr, false, position, navigatorUpdateGuard.get());

            mNavigator.update(position, navigatorUpdateGuard.get());
            navigatorUpdateGuard.reset();
            mNavigator.wait(DetourNavigator::WaitConditionType::requiredTilesPresent, nullptr);
            navigatorUpdateGuard = mNavigator.makeUpdateGuard();

            auto iter = mActiveCells.begin();
            while (iter != mActiveCells.end())
            {
                if (it->isExterior() && it->mData.mX == (*iter)->getCell()->getGridX()
                    && it->mData.mY == (*iter)->getCell()->getGridY())
                {
                    unloadCell(*iter, navigatorUpdateGuard.get());
                    break;
                }

                ++iter;
            }

            mRendering.getResourceSystem()->updateCache(mRendering.getReferenceTime());

            loadingListener->increaseProgress(1);
            i++;
        }

        mRendering.getResourceSystem()->getSceneManager()->setIncrementalCompileOperation(
            mRendering.getIncrementalCompileOperation());
        mRendering.getResourceSystem()->setExpiryDelay(Settings::cells().mCacheExpiryDelay);
    }

    void Scene::testInteriorCells()
    {
        // Note: temporary disable ICO to decrease memory usage
        mRendering.getResourceSystem()->getSceneManager()->setIncrementalCompileOperation(nullptr);

        mRendering.getResourceSystem()->setExpiryDelay(1.f);

        const MWWorld::Store<ESM::Cell>& cells = mWorld.getStore().get<ESM::Cell>();

        Loading::Listener* loadingListener = MWBase::Environment::get().getWindowManager()->getLoadingScreen();
        Loading::ScopedLoad load(loadingListener);
        loadingListener->setProgressRange(cells.getIntSize());

        int i = 1;
        MWWorld::Store<ESM::Cell>::iterator it = cells.intBegin();
        auto navigatorUpdateGuard = mNavigator.makeUpdateGuard();
        for (; it != cells.intEnd(); ++it)
        {
            loadingListener->setLabel("#{OMWEngine:TestingInteriorCells} (" + std::to_string(i) + "/"
                + std::to_string(cells.getIntSize()) + ")...");

            CellStore& cell = mWorld.getWorldModel().getInterior(it->mName);
            ESM::Position position;
            mWorld.findInteriorPosition(it->mName, position);
            mNavigator.updateBounds(
                cell.getCell()->getWorldSpace(), std::nullopt, position.asVec3(), navigatorUpdateGuard.get());
            loadCell(cell, nullptr, false, position.asVec3(), navigatorUpdateGuard.get());

            mNavigator.update(position.asVec3(), navigatorUpdateGuard.get());
            navigatorUpdateGuard.reset();
            mNavigator.wait(DetourNavigator::WaitConditionType::requiredTilesPresent, nullptr);
            navigatorUpdateGuard = mNavigator.makeUpdateGuard();

            auto iter = mActiveCells.begin();
            while (iter != mActiveCells.end())
            {
                assert(!(*iter)->getCell()->isExterior());

                if (it->mName == (*iter)->getCell()->getNameId())
                {
                    unloadCell(*iter, navigatorUpdateGuard.get());
                    break;
                }

                ++iter;
            }

            mRendering.getResourceSystem()->updateCache(mRendering.getReferenceTime());

            loadingListener->increaseProgress(1);
            i++;
        }

        mRendering.getResourceSystem()->getSceneManager()->setIncrementalCompileOperation(
            mRendering.getIncrementalCompileOperation());
        mRendering.getResourceSystem()->setExpiryDelay(Settings::cells().mCacheExpiryDelay);
    }

    void Scene::changePlayerCell(CellStore& cell, const ESM::Position& pos, bool adjustPlayerPos)
    {
        mHalfGridSize = cell.getCell()->isEsm4() ? Constants::ESM4CellGridRadius : Constants::CellGridRadius;
        mCurrentCell = &cell;

        mRendering.enableTerrain(cell.isExterior(), cell.getCell()->getWorldSpace());

        MWWorld::Ptr old = mWorld.getPlayerPtr();
        mWorld.getPlayer().setCell(&cell);

        MWWorld::Ptr player = mWorld.getPlayerPtr();
        mRendering.updatePlayerPtr(player);

        // The player is loaded before the scene and by default it is grounded, with the scene fully loaded,
        // we validate and correct this. Only run once, during initial cell load.
        if (old.mCell == &cell)
            mPhysics->traceDown(player, player.getRefData().getPosition().asVec3(), 10.f);

        if (adjustPlayerPos)
        {
            mWorld.moveObject(player, pos.asVec3());
            mWorld.rotateObject(player, pos.asRotationVec3());

            player.getClass().adjustPosition(player, true);
        }

        MWBase::Environment::get().getMechanicsManager()->updateCell(old, player);
        MWBase::Environment::get().getWindowManager()->watchActor(player);

        mPhysics->updatePtr(old, player);

        mWorld.adjustSky();

        mLastPlayerPos = player.getRefData().getPosition().asVec3();
    }

    Scene::Scene(MWWorld::World& world, MWRender::RenderingManager& rendering, MWPhysics::PhysicsSystem* physics,
        DetourNavigator::Navigator& navigator)
        : mCurrentCell(nullptr)
        , mCellChanged(false)
        , mWorld(world)
        , mPhysics(physics)
        , mRendering(rendering)
        , mNavigator(navigator)
        , mCellLoadingThreshold(1024.f)
        , mPreloadDistance(Settings::cells().mPreloadDistance)
        , mPreloadEnabled(Settings::cells().mPreloadEnabled)
        , mPreloadExteriorGrid(Settings::cells().mPreloadExteriorGrid)
        , mPreloadDoors(Settings::cells().mPreloadDoors)
        , mPreloadFastTravel(Settings::cells().mPreloadFastTravel)
        , mPredictionTime(Settings::cells().mPredictionTime)
        , mLowestPoint(std::numeric_limits<float>::max())
    {
        mPreloader = std::make_unique<CellPreloader>(rendering.getResourceSystem(), physics->getShapeManager(),
            rendering.getTerrain(), rendering.getLandManager());
        mPreloader->setWorkQueue(mRendering.getWorkQueue());
        mPreloader->setExpiryDelay(Settings::cells().mPreloadCellExpiryDelay);
        mPreloader->setMinCacheSize(Settings::cells().mPreloadCellCacheMin);
        mPreloader->setMaxCacheSize(Settings::cells().mPreloadCellCacheMax);
        mPreloader->setPreloadInstances(Settings::cells().mPreloadInstances);
    }

    Scene::~Scene()
    {
        for (const osg::ref_ptr<SceneUtil::WorkItem>& v : mWorkItems)
            v->abort();

        for (const osg::ref_ptr<SceneUtil::WorkItem>& v : mWorkItems)
            v->waitTillDone();
    }

    bool Scene::hasCellChanged() const
    {
        return mCellChanged;
    }

    const Scene::CellStoreCollection& Scene::getActiveCells() const
    {
        return mActiveCells;
    }

    void Scene::changeToInteriorCell(
        std::string_view cellName, const ESM::Position& position, bool adjustPlayerPos, bool changeEvent)
    {
        CellStore& cell = mWorld.getWorldModel().getInterior(cellName);
        bool useFading = (mCurrentCell != nullptr);
        if (useFading)
            MWBase::Environment::get().getWindowManager()->fadeScreenOut(0.5);

        Loading::Listener* loadingListener = MWBase::Environment::get().getWindowManager()->getLoadingScreen();
        loadingListener->setLabel("#{OMWEngine:LoadingInterior}");
        Loading::ScopedLoad load(loadingListener);

        if (mCurrentCell == &cell)
        {
            mWorld.moveObject(mWorld.getPlayerPtr(), position.asVec3());
            mWorld.rotateObject(mWorld.getPlayerPtr(), position.asRotationVec3());

            if (adjustPlayerPos)
                mWorld.getPlayerPtr().getClass().adjustPosition(mWorld.getPlayerPtr(), true);
            MWBase::Environment::get().getWindowManager()->fadeScreenIn(0.5);
            return;
        }

        Log(Debug::Info) << "Changing to interior";

        auto navigatorUpdateGuard = mNavigator.makeUpdateGuard();

        // unload
        for (auto iter = mActiveCells.begin(); iter != mActiveCells.end();)
        {
            auto* cellToUnload = *iter++;
            unloadCell(cellToUnload, navigatorUpdateGuard.get());
        }
        assert(mActiveCells.empty());

        loadingListener->setProgressRange(cell.count());

        mNavigator.updateBounds(
            cell.getCell()->getWorldSpace(), std::nullopt, position.asVec3(), navigatorUpdateGuard.get());

        // Load cell.
        mPagedRefs.clear();
        loadCell(cell, loadingListener, changeEvent, position.asVec3(), navigatorUpdateGuard.get());

        navigatorUpdateGuard.reset();

        changePlayerCell(cell, position, adjustPlayerPos);

        // adjust fog
        mRendering.configureFog(*mCurrentCell->getCell());

        // Sky system
        mWorld.adjustSky();

        if (changeEvent)
            mCellChanged = true;

        mCellLoaded = true;

        if (useFading)
            MWBase::Environment::get().getWindowManager()->fadeScreenIn(0.5);

        MWBase::Environment::get().getWindowManager()->changeCell(mCurrentCell);

        MWBase::Environment::get().getWorld()->getPostProcessor()->setExteriorFlag(cell.getCell()->isQuasiExterior());
    }

    void Scene::changeToExteriorCell(
        const ESM::RefId& extCellId, const ESM::Position& position, bool adjustPlayerPos, bool changeEvent)
    {

        if (changeEvent)
            MWBase::Environment::get().getWindowManager()->fadeScreenOut(0.5);
        CellStore& current = mWorld.getWorldModel().getCell(extCellId);

        const osg::Vec2i cellIndex(current.getCell()->getGridX(), current.getCell()->getGridY());

        changeCellGrid(position.asVec3(),
            ESM::ExteriorCellLocation(cellIndex.x(), cellIndex.y(), current.getCell()->getWorldSpace()), changeEvent);

        changePlayerCell(current, position, adjustPlayerPos);

        if (changeEvent)
            MWBase::Environment::get().getWindowManager()->fadeScreenIn(0.5);

        MWBase::Environment::get().getWorld()->getPostProcessor()->setExteriorFlag(true);
    }

    CellStore* Scene::getCurrentCell()
    {
        return mCurrentCell;
    }

    void Scene::markCellAsUnchanged()
    {
        mCellChanged = false;
    }

    void Scene::insertCell(
        CellStore& cell, Loading::Listener* loadingListener, const DetourNavigator::UpdateGuard* navigatorUpdateGuard)
    {
        const bool isInterior = !cell.isExterior();
        InsertVisitor insertVisitor(cell, loadingListener);
        cell.forEach(insertVisitor);
        insertVisitor.insert(
            [&](const MWWorld::Ptr& ptr) { addObject(ptr, mWorld, mPagedRefs, *mPhysics, mRendering); });
        insertVisitor.insert([&](const MWWorld::Ptr& ptr) {
            addObject(ptr, mWorld, *mPhysics, mLowestPoint, isInterior, mNavigator, navigatorUpdateGuard);
        });
    }

    void Scene::addObjectToScene(const Ptr& ptr)
    {
        const bool isInterior = mCurrentCell && !mCurrentCell->isExterior();
        try
        {
            addObject(ptr, mWorld, mPagedRefs, *mPhysics, mRendering);
            addObject(ptr, mWorld, *mPhysics, mLowestPoint, isInterior, mNavigator);
            mWorld.scaleObject(ptr, ptr.getCellRef().getScale());
        }
        catch (std::exception& e)
        {
            Log(Debug::Error) << "failed to render '" << ptr.getCellRef().getRefId() << "': " << e.what();
        }
    }

    void Scene::removeObjectFromScene(const Ptr& ptr, bool keepActive)
    {
        MWBase::Environment::get().getMechanicsManager()->remove(ptr, keepActive);
        // You'd expect the sounds attached to the object to be stopped here
        // because the object is nowhere to be heard, but in Morrowind, they're not.
        // They're still stopped when the cell is unloaded
        // or if the player moves away far from the object's position.
        // Todd Howard, Who art in Bethesda, hallowed be Thy name.
        MWBase::Environment::get().getLuaManager()->objectRemovedFromScene(ptr);
        if (const auto object = mPhysics->getObject(ptr))
        {
            if (object->getShapeInstance()->mVisualCollisionType == Resource::VisualCollisionType::None)
                mNavigator.removeObject(DetourNavigator::ObjectId(object), nullptr);
        }
        else if (mPhysics->getActor(ptr))
        {
            mNavigator.removeAgent(mWorld.getPathfindingAgentBounds(ptr));
        }
        mPhysics->remove(ptr);
        mRendering.removeObject(ptr);
        if (ptr.getClass().isActor())
            mRendering.removeWaterRippleEmitter(ptr);
        ptr.getRefData().setBaseNode(nullptr);
    }

    bool Scene::isCellActive(const CellStore& cell)
    {
        return mActiveCells.contains(&cell);
    }

    class PreloadMeshItem : public SceneUtil::WorkItem
    {
    public:
        explicit PreloadMeshItem(VFS::Path::NormalizedView mesh, Resource::SceneManager* sceneManager)
            : mMesh(mesh)
            , mSceneManager(sceneManager)
        {
        }

        void doWork() override
        {
            if (mAborted)
                return;

            try
            {
                mSceneManager->getTemplate(mMesh);
            }
            catch (const std::exception& e)
            {
                Log(Debug::Warning) << "Failed to get mesh template \"" << mMesh << "\" to preload: " << e.what();
            }
        }

        void abort() override { mAborted = true; }

    private:
        VFS::Path::Normalized mMesh;
        Resource::SceneManager* mSceneManager;
        std::atomic_bool mAborted{ false };
    };

    void Scene::preload(const std::string& mesh, bool useAnim)
    {
        const VFS::Path::Normalized meshPath = useAnim
            ? Misc::ResourceHelpers::correctActorModelPath(
                VFS::Path::toNormalized(mesh), mRendering.getResourceSystem()->getVFS())
            : VFS::Path::toNormalized(mesh);

        if (mRendering.getResourceSystem()->getSceneManager()->checkLoaded(meshPath, mRendering.getReferenceTime()))
            return;

        osg::ref_ptr<PreloadMeshItem> item(
            new PreloadMeshItem(meshPath, mRendering.getResourceSystem()->getSceneManager()));
        mRendering.getWorkQueue()->addWorkItem(item);
        const auto isDone = [](const osg::ref_ptr<SceneUtil::WorkItem>& v) { return v->isDone(); };
        mWorkItems.erase(std::remove_if(mWorkItems.begin(), mWorkItems.end(), isDone), mWorkItems.end());
        mWorkItems.emplace_back(std::move(item));
    }

    void Scene::preloadCells(float dt)
    {

        if (dt <= 1e-06)
            return;
        std::vector<PositionCellGrid> exteriorPositions;

        const MWWorld::ConstPtr player = mWorld.getPlayerPtr();
        osg::Vec3f playerPos = player.getRefData().getPosition().asVec3();
        osg::Vec3f moved = playerPos - mLastPlayerPos;
        osg::Vec3f predictedPos = playerPos + moved / dt * mPredictionTime;

        if (mCurrentCell->isExterior())
        {
            // TSP_TERRAIN_LEAD_V2
            // Entry 0 is upstream's: predictedPos with the hysteresis grid centre.
            // getNewGridCenter holds mCurrentGridCenter until the position is
            // mCellLoadingThreshold PAST the cell edge, and Scene::playerMoved fires
            // changeCellGrid on that same test applied to the real position - so the
            // only warning upstream gets is the prediction lead itself, about 3 s. A
            // terrain preload on this device does not finish in 3 s, which is why
            // changeCellGrid kept falling through to the blocking preloadTerrain.
            //
            // V1's far entry could not help. Its lead was clamped to exactly
            // CellSizeInUnits while isTerrainLoaded tests length2 < CellSizeInUnits^2
            // with a STRICT <, so a clamped far position never counted as loaded; a
            // full cell of lead can land two cells ahead, giving bounds changeCellGrid
            // never asks about; and it still passed &mCurrentGridCenter, so the far
            // centre could not differ from the near one until the near one had already
            // moved. All it did was double the work of every TerrainPreloadItem -
            // including the one syncTerrainLoad blocks on. Hence 6 -> 12 doing nothing.
            //
            // V2 asks which cell we are about to walk into. nullptr drops the
            // hysteresis, so the centre is simply the cell tspFarPos sits in, and
            // clamping the lead under one cell size keeps it at most one cell ahead -
            // the cell changeCellGrid will ask about - and well inside the tolerance.
            const osg::Vec2i tspNearCenter = getNewGridCenter(predictedPos, &mCurrentGridCenter);
            exteriorPositions.push_back(PositionCellGrid{ predictedPos, gridCenterToBounds(tspNearCenter) });

            const float tspCellSize = static_cast<float>(ESM::getCellSize(mWorld.getCurrentWorldspace()));
            const float tspMaxLead = tspCellSize * 0.95f;
            osg::Vec3f tspLead = moved / dt * (mPredictionTime * 4.0f);
            tspLead.z() = 0.f;
            const float tspLeadLen = tspLead.length();
            if (tspLeadLen > 1.0f)
            {
                if (tspLeadLen > tspMaxLead)
                    tspLead *= tspMaxLead / tspLeadLen;
                const osg::Vec3f tspFarPos = playerPos + tspLead;
                const osg::Vec2i tspFarCenter = getNewGridCenter(tspFarPos, nullptr);
                if (tspFarCenter != tspNearCenter)
                    exteriorPositions.push_back(PositionCellGrid{ tspFarPos, gridCenterToBounds(tspFarCenter) });
            }
        }

        mLastPlayerPos = playerPos;

        if (mPreloadEnabled)
        {
            if (mPreloadDoors)
                preloadTeleportDoorDestinations(playerPos, predictedPos);
            if (mPreloadExteriorGrid)
                preloadExteriorGrid(playerPos, predictedPos);
            if (mPreloadFastTravel)
                preloadFastTravelDestinations(playerPos, exteriorPositions);
        }

        mPreloader->setTerrainPreloadPositions(exteriorPositions);
    }

    void Scene::preloadTeleportDoorDestinations(const osg::Vec3f& playerPos, const osg::Vec3f& predictedPos)
    {
        std::vector<MWWorld::ConstPtr> teleportDoors;
        for (const MWWorld::CellStore* cellStore : mActiveCells)
        {
            typedef MWWorld::CellRefList<ESM::Door>::List DoorList;
            const DoorList& doors = cellStore->getReadOnlyDoors().mList;
            for (auto& door : doors)
            {
                if (!door.mRef.getTeleport())
                {
                    continue;
                }
                teleportDoors.emplace_back(&door, cellStore);
            }
        }

        for (const MWWorld::ConstPtr& door : teleportDoors)
        {
            float sqrDistToPlayer = (playerPos - door.getRefData().getPosition().asVec3()).length2();
            sqrDistToPlayer
                = std::min(sqrDistToPlayer, (predictedPos - door.getRefData().getPosition().asVec3()).length2());

            if (sqrDistToPlayer < mPreloadDistance * mPreloadDistance)
            {
                try
                {
                    preloadCellWithSurroundings(mWorld.getWorldModel().getCell(door.getCellRef().getDestCell()));
                }
                catch (const std::exception& e)
                {
                    Log(Debug::Warning) << "Failed to schedule preload for door " << door.toString() << ": "
                                        << e.what();
                }
            }
        }
    }

    void Scene::preloadExteriorGrid(const osg::Vec3f& playerPos, const osg::Vec3f& predictedPos)
    {
        if (!mWorld.isCellExterior())
            return;

        int halfGridSizePlusOne = mHalfGridSize + 1;

        int cellX, cellY;
        cellX = mCurrentGridCenter.x();
        cellY = mCurrentGridCenter.y();
        ESM::RefId extWorldspace = mWorld.getCurrentWorldspace();

        int cellSize = ESM::getCellSize(extWorldspace);

        for (int dx = -halfGridSizePlusOne; dx <= halfGridSizePlusOne; ++dx)
        {
            for (int dy = -halfGridSizePlusOne; dy <= halfGridSizePlusOne; ++dy)
            {
                if (dy != halfGridSizePlusOne && dy != -halfGridSizePlusOne && dx != halfGridSizePlusOne
                    && dx != -halfGridSizePlusOne)
                    continue; // only care about the outer (not yet loaded) part of the grid
                ESM::ExteriorCellLocation cellIndex(cellX + dx, cellY + dy, extWorldspace);
                const osg::Vec2f thisCellCenter = ESM::indexToPosition(cellIndex, true);

                float dist = std::max(
                    std::abs(thisCellCenter.x() - playerPos.x()), std::abs(thisCellCenter.y() - playerPos.y()));
                dist = std::min(dist,
                    std::max(std::abs(thisCellCenter.x() - predictedPos.x()),
                        std::abs(thisCellCenter.y() - predictedPos.y())));
                float loadDist = cellSize / 2 + cellSize - mCellLoadingThreshold + mPreloadDistance;

                if (dist < loadDist)
                    preloadCell(mWorld.getWorldModel().getExterior(cellIndex));
            }
        }
    }

    void Scene::preloadCellWithSurroundings(CellStore& cell)
    {
        if (!cell.isExterior())
        {
            mPreloader->preload(cell, mRendering.getReferenceTime());
            return;
        }

        const int cellX = cell.getCell()->getGridX();
        const int cellY = cell.getCell()->getGridY();

        std::vector<std::pair<int, int>> cells;
        const std::size_t gridSize = static_cast<std::size_t>(2 * mHalfGridSize + 1);
        cells.reserve(gridSize * gridSize);

        iterateOverCellsAround(cellX, cellY, mHalfGridSize, [&](int x, int y) { cells.emplace_back(x, y); });

        sortCellsToLoad(cellX, cellY, cells);

        const std::size_t leftCapacity = mPreloader->getMaxCacheSize() - mPreloader->getCacheSize();
        if (cells.size() > leftCapacity)
        {
            [[maybe_unused]] static const bool logged = [&] {
                Log(Debug::Warning) << "Not enough cell preloader cache capacity to preload exterior cells, consider "
                                       "increasing \"preload cell cache max\" up to "
                                    << (mPreloader->getCacheSize() + cells.size());
                return true;
            }();
            cells.resize(leftCapacity);
        }

        const ESM::RefId worldspace = cell.getCell()->getWorldSpace();
        for (const auto& [x, y] : cells)
            mPreloader->preload(mWorld.getWorldModel().getExterior(ESM::ExteriorCellLocation(x, y, worldspace)),
                mRendering.getReferenceTime());
    }

    void Scene::preloadCell(CellStore& cell)
    {
        mPreloader->preload(cell, mRendering.getReferenceTime());
    }

    void Scene::preloadTerrain(const osg::Vec3f& pos, ESM::RefId worldspace, bool sync)
    {
        if (mRendering.getTerrain()->getWorldspace() != worldspace)
            throw std::runtime_error("preloadTerrain can only work with the current exterior worldspace");

        ESM::ExteriorCellLocation cellPos = ESM::positionToExteriorCellLocation(pos.x(), pos.y(), worldspace);
        const PositionCellGrid position{ pos, gridCenterToBounds({ cellPos.mX, cellPos.mY }) };
        mPreloader->abortTerrainPreloadExcept(&position);
        mPreloader->setTerrainPreloadPositions(std::span(&position, 1));
        if (!sync)
            return;

        Loading::Listener* loadingListener = MWBase::Environment::get().getWindowManager()->getLoadingScreen();
        Loading::ScopedLoad load(loadingListener);

        loadingListener->setLabel("#{OMWEngine:InitializingData}");

        mPreloader->syncTerrainLoad(*loadingListener);
    }

    void Scene::reloadTerrain()
    {
        mPreloader->setTerrainPreloadPositions({});
    }

    struct ListFastTravelDestinationsVisitor
    {
        ListFastTravelDestinationsVisitor(float preloadDist, const osg::Vec3f& playerPos)
            : mPreloadDist(preloadDist)
            , mPlayerPos(playerPos)
        {
        }

        bool operator()(const MWWorld::Ptr& ptr)
        {
            if ((ptr.getRefData().getPosition().asVec3() - mPlayerPos).length2() > mPreloadDist * mPreloadDist)
                return true;

            if (ptr.getClass().isNpc())
            {
                const std::vector<ESM::Transport::Dest>& transport = ptr.get<ESM::NPC>()->mBase->mTransport.mList;
                mList.insert(mList.begin(), transport.begin(), transport.end());
            }
            else
            {
                const std::vector<ESM::Transport::Dest>& transport = ptr.get<ESM::Creature>()->mBase->mTransport.mList;
                mList.insert(mList.begin(), transport.begin(), transport.end());
            }
            return true;
        }
        float mPreloadDist;
        osg::Vec3f mPlayerPos;
        std::vector<ESM::Transport::Dest> mList;
    };

    void Scene::preloadFastTravelDestinations(
        const osg::Vec3f& playerPos, std::vector<PositionCellGrid>& exteriorPositions)
    {
        ListFastTravelDestinationsVisitor listVisitor(mPreloadDistance, playerPos);
        ESM::RefId extWorldspace = mWorld.getCurrentWorldspace();
        for (MWWorld::CellStore* cellStore : mActiveCells)
        {
            cellStore->forEachType<ESM::NPC>(listVisitor);
            cellStore->forEachType<ESM::Creature>(listVisitor);
        }

        for (ESM::Transport::Dest& dest : listVisitor.mList)
        {
            if (!dest.mCellName.empty())
                preloadCell(mWorld.getWorldModel().getInterior(dest.mCellName));
            else
            {
                osg::Vec3f pos = dest.mPos.asVec3();
                const ESM::ExteriorCellLocation cellIndex
                    = ESM::positionToExteriorCellLocation(pos.x(), pos.y(), extWorldspace);
                preloadCellWithSurroundings(mWorld.getWorldModel().getExterior(cellIndex));
                exteriorPositions.push_back(PositionCellGrid{ pos, gridCenterToBounds(getNewGridCenter(pos)) });
            }
        }
    }

    void Scene::reportStats(unsigned int frameNumber, osg::Stats& stats) const
    {
        mPreloader->reportStats(frameNumber, stats);
    }
}
