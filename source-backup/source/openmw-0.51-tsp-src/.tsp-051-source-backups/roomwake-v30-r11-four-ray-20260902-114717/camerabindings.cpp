#include "camerabindings.hpp"
#include <components/debug/debuglog.hpp>
#include <cstdlib>
#include <cmath>

#include <components/lua/luastate.hpp>
#include <components/lua/utilpackage.hpp>
#include <components/misc/finitevalues.hpp>
#include <components/settings/values.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/world.hpp"
#include "../mwrender/camera.hpp"
#include "../mwrender/renderingmanager.hpp"
#include "../mwrender/interiorvisibility.hpp" // TSP_INTERIOR_VISGRID_051_V1

#include <vector>
#include <stdexcept>

// TSP_LUAJIT_HEADER_051_V1 - LuaJIT headers are plain C with no
// extern "C" guards. Must be included last and wrapped, or every
// lua_* symbol in this file gets C++ linkage and the link fails.
extern "C" {
#include <luajit.h>
}

namespace MWLua
{
    using CameraMode = MWRender::Camera::Mode;

    sol::table initCameraPackage(sol::state_view lua)
    {
        using Misc::FiniteFloat;

        MWRender::Camera* camera = MWBase::Environment::get().getWorld()->getCamera();
        MWRender::RenderingManager* renderingManager = MWBase::Environment::get().getWorld()->getRenderingManager();

        sol::table api(lua, sol::create);
        api["MODE"] = LuaUtil::makeStrictReadOnly(
            lua.create_table_with("Static", CameraMode::Static, "FirstPerson", CameraMode::FirstPerson, "ThirdPerson",
                CameraMode::ThirdPerson, "Vanity", CameraMode::Vanity, "Preview", CameraMode::Preview));

        api["getMode"] = [camera]() -> int { return static_cast<int>(camera->getMode()); };
        api["getQueuedMode"] = [camera]() -> sol::optional<int> {
            std::optional<CameraMode> mode = camera->getQueuedMode();
            if (mode)
                return static_cast<int>(*mode);
            else
                return sol::nullopt;
        };
        api["setMode"] = [camera](int mode, sol::optional<bool> force) {
            camera->setMode(static_cast<CameraMode>(mode), force ? *force : false);
        };

        api["allowCharacterDeferredRotation"] = [camera](bool v) { camera->allowCharacterDeferredRotation(v); };
        api["showCrosshair"] = [camera](bool v) { camera->showCrosshair(v); };

        api["getTrackedPosition"] = [camera]() -> osg::Vec3f { return camera->getTrackedPosition(); };
        api["getPosition"] = [camera]() -> osg::Vec3f { return camera->getPosition(); };

        // All angles are negated in order to make camera rotation consistent with objects rotation.
        // TODO: Fix the inconsistency of rotation direction in camera.cpp.
        api["getPitch"] = [camera]() { return -camera->getPitch(); };
        api["getYaw"] = [camera]() { return -camera->getYaw(); };
        api["getRoll"] = [camera]() { return -camera->getRoll(); };

        api["setStaticPosition"] = [camera](const osg::Vec3f& pos) { camera->setStaticPosition(pos); };
        api["setPitch"] = [camera](const FiniteFloat v) {
            camera->setPitch(-v, true);
            if (camera->getMode() == CameraMode::ThirdPerson)
                camera->calculateDeferredRotation();
        };
        api["setYaw"] = [camera](const FiniteFloat v) {
            camera->setYaw(-v, true);
            if (camera->getMode() == CameraMode::ThirdPerson)
                camera->calculateDeferredRotation();
        };
        api["setRoll"] = [camera](const FiniteFloat v) { camera->setRoll(-v); };
        api["setExtraPitch"] = [camera](const FiniteFloat v) { camera->setExtraPitch(-v); };
        api["setExtraYaw"] = [camera](const FiniteFloat v) { camera->setExtraYaw(-v); };
        api["setExtraRoll"] = [camera](const FiniteFloat v) { camera->setExtraRoll(-v); };
        api["setProjectionOffset"]
            = [renderingManager](const osg::Vec2f& v) { renderingManager->setProjectionOffset(v); };
        api["getExtraPitch"] = [camera]() { return -camera->getExtraPitch(); };
        api["getExtraYaw"] = [camera]() { return -camera->getExtraYaw(); };
        api["getExtraRoll"] = [camera]() { return -camera->getExtraRoll(); };
        api["getProjectionOffset"] = [renderingManager]() { return renderingManager->getProjectionOffset(); };

        api["getThirdPersonDistance"] = [camera]() { return camera->getCameraDistance(); };
        api["setPreferredThirdPersonDistance"]
            = [camera](const FiniteFloat v) { camera->setPreferredCameraDistance(v); };

        api["getFirstPersonOffset"] = [camera]() { return camera->getFirstPersonOffset(); };
        api["setFirstPersonOffset"] = [camera](const osg::Vec3f& v) { camera->setFirstPersonOffset(v); };

        api["getFocalPreferredOffset"] = [camera]() -> osg::Vec2f { return camera->getFocalPointTargetOffset(); };
        api["setFocalPreferredOffset"] = [camera](const osg::Vec2f& v) { camera->setFocalPointTargetOffset(v); };
        api["getFocalTransitionSpeed"] = [camera]() { return camera->getFocalPointTransitionSpeed(); };
        api["setFocalTransitionSpeed"] = [camera](const FiniteFloat v) { camera->setFocalPointTransitionSpeed(v); };
        api["instantTransition"] = [camera]() { camera->instantTransition(); };

        api["getCollisionType"] = [camera]() { return camera->getCollisionType(); };
        api["setCollisionType"] = [camera](int collisionType) { camera->setCollisionType(collisionType); };

        api["getBaseFieldOfView"] = [] { return osg::DegreesToRadians(Settings::camera().mFieldOfView); };
        api["getFieldOfView"]
            = [renderingManager]() { return osg::DegreesToRadians(renderingManager->getFieldOfView()); };
        api["setFieldOfView"]
            = [renderingManager](const FiniteFloat v) { renderingManager->setFieldOfView(osg::RadiansToDegrees(v)); };

        api["getBaseViewDistance"] = [] { return Settings::camera().mViewingDistance.get(); };
        api["getViewDistance"] = [renderingManager]() { return renderingManager->getViewDistance(); };
        api["setViewDistance"]
            = [renderingManager](const FiniteFloat d) { renderingManager->setViewDistance(d, true); };

        // TSP_INTERIOR_VISGRID_051_V1
        // Generic Lua -> renderer bridge. Lua owns the room sensor; this API
        // only transports a conservative camera-space depth field.
        api["setInteriorVisibilityGrid"]
            = [](int cols, int rows, const sol::table& values, const FiniteFloat padding) {
                  // TSP_INTERIOR_VISGRID_051_V4_NOTHROW
                  // Never throw across the Lua boundary. LuaJIT on aarch64 does
                  // not support unwinding a C++ exception through its VM frames,
                  // and every element is now type-checked instead of read raw.
                  // Bad input degrades to "render everything", never to a
                  // damaged VM.

                  // TSP_LUAJIT_SAFE_051_V1
                  // Every VISGRID crash (9 of 9) faults at ONE instruction
                  // inside libluajit with a tagged-TValue pattern in the fault
                  // address, on the device's bundled beta-era LuaJIT, under
                  // the sensor's allocation load. The trace compiler and its
                  // GC interactions are the classic home of that bug family
                  // on aarch64, so the VM is switched to pure interpreter
                  // mode the moment VISGRID first publishes (same mechanism
                  // as Lua's own jit.off()). Interpreter Lua costs a few ms
                  // at our call rates; a corrupted VM costs the session.
                  //   TSP_LUAJIT_JIT=1   keeps the JIT enabled (A/B switch)
                  static bool tspJitConfigured = false;
                  if (!tspJitConfigured)
                  {
                      tspJitConfigured = true;
                      const char* tspKeepJit = std::getenv("TSP_LUAJIT_JIT");
                      if (tspKeepJit != nullptr && tspKeepJit[0] == '1')
                          Log(Debug::Warning)
                              << "TSP_LUAJIT_SAFE_051_V1 JIT kept ON (TSP_LUAJIT_JIT=1)";
                      else if (luaJIT_setmode(values.lua_state(), 0,
                                   LUAJIT_MODE_ENGINE | LUAJIT_MODE_OFF)
                          == 1)
                      {
                          // MODE_OFF stops NEW traces being recorded. Traces
                          // compiled before VISGRID armed stay resident and
                          // keep executing, so without a flush a survival
                          // would not prove the JIT was out of the picture.
                          const int tspFlushed = luaJIT_setmode(values.lua_state(), 0,
                              LUAJIT_MODE_ENGINE | LUAJIT_MODE_FLUSH);
                          Log(Debug::Warning)
                              << "TSP_LUAJIT_SAFE_051_V1 interpreter mode ON flush="
                              << tspFlushed
                              << " (set TSP_LUAJIT_JIT=1 to re-enable the JIT)";
                      }
                      else
                          Log(Debug::Warning)
                              << "TSP_LUAJIT_SAFE_051_V1 luaJIT_setmode FAILED - JIT left as-is";
                  }

                  const int count = cols * rows;
                  if (cols <= 0 || rows <= 0 || count <= 0
                      || count > MWRender::sInteriorVisibilityMaxTiles)
                  {
                      MWRender::clearInteriorVisibilityGrid();
                      return;
                  }

                  std::vector<float> depths;
                  depths.reserve(static_cast<std::size_t>(count));
                  for (int i = 1; i <= count; ++i)
                  {
                      const sol::optional<float> tspV = values.get<sol::optional<float>>(i);
                      if (!tspV || !std::isfinite(*tspV) || *tspV <= 0.f)
                      {
                          MWRender::clearInteriorVisibilityGrid();
                          return;
                      }
                      depths.push_back(*tspV);
                  }

                  MWRender::setInteriorVisibilityGrid(
                      cols, rows, std::span<const float>(depths.data(), depths.size()), padding);
              };

        // TSP_INTERIOR_VISGRID_051_V5_TOPO_PVS
        // Infrequent topology update bridge. Lua supplies all sector AABBs
        // plus the conservative 1-based active sector ids.
        api["setInteriorTopologyPvs"]
            = [](const sol::table& boxes, const sol::table& activeIds,
                  const FiniteFloat xyPadding, const FiniteFloat zPadding) {
                  const std::size_t boxValueCount = boxes.size();
                  if (boxValueCount == 0 || boxValueCount % 6 != 0
                      || boxValueCount / 6 > 64)
                  {
                      MWRender::clearInteriorTopologyPvs();
                      return;
                  }

                  std::vector<float> boxValues;
                  boxValues.reserve(boxValueCount);
                  for (std::size_t i = 1; i <= boxValueCount; ++i)
                  {
                      const sol::optional<float> v = boxes.get<sol::optional<float>>(i);
                      if (!v || !std::isfinite(*v))
                      {
                          MWRender::clearInteriorTopologyPvs();
                          return;
                      }
                      boxValues.push_back(*v);
                  }

                  std::vector<int> ids;
                  ids.reserve(activeIds.size());
                  for (std::size_t i = 1; i <= activeIds.size(); ++i)
                  {
                      const sol::optional<int> id = activeIds.get<sol::optional<int>>(i);
                      if (!id || *id <= 0 || *id > 64)
                      {
                          MWRender::clearInteriorTopologyPvs();
                          return;
                      }
                      ids.push_back(*id);
                  }

                  MWRender::setInteriorTopologyPvs(
                      std::span<const float>(boxValues.data(), boxValues.size()),
                      std::span<const int>(ids.data(), ids.size()), xyPadding, zPadding);
              };

        // TSP_ROOM_ADAPTIVE_RANGE_051_V30_R10 LUA_CPP_BRIDGE
        api["setInteriorAdaptiveRangeMode"] = [](int mode) {
            MWRender::setInteriorAdaptiveRangeMode(mode);
        };
        api["getInteriorAdaptiveRangeMode"] = []() {
            return MWRender::getInteriorAdaptiveRangeMode();
        };
        api["clearInteriorTopologyPvs"] = [] { MWRender::clearInteriorTopologyPvs(); };

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
            out["pvsEnabled"] = stats.mPvsEnabled;
            out["pvsSectorCount"] = stats.mPvsSectorCount;
            out["pvsActiveCount"] = stats.mPvsActiveCount;
            out["pvsTested"] = static_cast<double>(stats.mPvsTested);
            out["pvsCulled"] = static_cast<double>(stats.mPvsCulled);
            return out;
        };

        api["getViewTransform"] = [camera]() { return LuaUtil::TransformM{ camera->getViewMatrix() }; };

        api["viewportToWorldVector"] = [camera, renderingManager](osg::Vec2f pos) -> osg::Vec3f {
            const double width = Settings::video().mResolutionX;
            const double height = Settings::video().mResolutionY;
            double aspect = (height == 0.0) ? 1.0 : width / height;
            double fovTan = std::tan(osg::DegreesToRadians(renderingManager->getFieldOfView()) / 2);
            osg::Matrixf invertedViewMatrix;
            invertedViewMatrix.invert(camera->getViewMatrix());
            float x = static_cast<float>((pos.x() * 2 - 1) * aspect * fovTan);
            float y = static_cast<float>((1 - pos.y() * 2) * fovTan);
            return invertedViewMatrix.preMult(osg::Vec3f(x, y, -1)) - camera->getPosition();
        };

        api["worldToViewportVector"] = [camera](osg::Vec3f pos) {
            const int width = Settings::video().mResolutionX;
            const int height = Settings::video().mResolutionY;

            osg::Matrix windowMatrix
                = osg::Matrix::translate(1.0, 1.0, 1.0) * osg::Matrix::scale(0.5 * width, 0.5 * height, 0.5);
            osg::Vec3f vpCoords = pos * (camera->getViewMatrix() * camera->getProjectionMatrix() * windowMatrix);

            // Move 0,0 to top left to match viewportToWorldVector
            vpCoords.y() = height - vpCoords.y();

            // Set the z component to be distance from camera, in world space units
            vpCoords.z() = (pos - camera->getPosition()).length();

            return vpCoords;
        };

        return LuaUtil::makeReadOnly(api);
    }

}
