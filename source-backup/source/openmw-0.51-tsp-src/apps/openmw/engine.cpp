#include "engine.hpp"
#include "mwworld/cell.hpp"
#include "mwworld/cellstore.hpp"
#include <cstdio>
#include <components/shader/shadermanager.hpp>
#include <osg/Group>

#include <cstdlib>
#include <cstring>

#include <cerrno>
#include <chrono>
#include <future>
#include <system_error>

#include <osgDB/ReaderWriter>
#include <osgDB/Registry>
#include <osgViewer/ViewerEventHandlers>

#include <SDL.h>

#include <components/debug/debuglog.hpp>
#include <components/debug/gldebug.hpp>

#include <components/misc/rng.hpp>
#include <components/misc/strings/format.hpp>

#include <components/vfs/manager.hpp>
#include <components/vfs/registerarchives.hpp>

#include <components/sdlutil/imagetosurface.hpp>
#include <components/sdlutil/sdlgraphicswindow.hpp>

#include <components/resource/resourcesystem.hpp>
#include <components/resource/scenemanager.hpp>
#include <components/resource/stats.hpp>

#include <components/compiler/extensions0.hpp>

#include <components/stereo/stereomanager.hpp>

#include <components/sceneutil/glextensions.hpp>
#include <components/sceneutil/workqueue.hpp>

#include <components/files/configurationmanager.hpp>

#include <components/version/version.hpp>

#include <components/l10n/manager.hpp>

#include <components/loadinglistener/asynclistener.hpp>
#include <components/loadinglistener/loadinglistener.hpp>

#include <components/misc/frameratelimiter.hpp>

#include <components/sceneutil/color.hpp>
#include <components/sceneutil/depth.hpp>
#include <components/sceneutil/screencapture.hpp>
#include <components/sceneutil/unrefqueue.hpp>
#include <components/sceneutil/util.hpp>

#include <components/settings/shadermanager.hpp>
#include <components/settings/values.hpp>

#include "mwinput/inputmanagerimp.hpp"

#include "mwgui/windowmanagerimp.hpp"

#include "mwlua/luamanagerimp.hpp"
#include "mwlua/worker.hpp"

#include "mwscript/interpretercontext.hpp"
#include "mwscript/scriptmanagerimp.hpp"

#include "mwsound/constants.hpp"
#include "mwsound/soundmanagerimp.hpp"

#include "mwworld/class.hpp"
#include "mwworld/datetimemanager.hpp"
#include "mwworld/worldimp.hpp"

#include "mwrender/vismask.hpp"

#include "mwclass/classes.hpp"

#include "mwdialogue/dialoguemanagerimp.hpp"
#include "mwdialogue/journalimp.hpp"
#include "mwdialogue/scripttest.hpp"

#include "mwmechanics/mechanicsmanagerimp.hpp"

#include "mwstate/statemanagerimp.hpp"

#include "profile.hpp"
#include <osgGA/GUIEventAdapter>
#include "tspprof.h"
#include <fstream>
#include <sstream>
#include "mwbase/statemanager.hpp"
#include "mwbase/windowmanager.hpp"
#include "mwbase/world.hpp"
#include "mwworld/globals.hpp"

namespace
{

    // TSP_OPTIONAL_FPS_OVERLAY_051_V20
    bool tspV20ShowFpsEnabled()
    {
        static const bool enabled = [] {
            const char* value = std::getenv("OPENMW_TSP_SHOW_FPS");

            if (value == nullptr || *value == '\0')
                return false;

            return !(std::strcmp(value, "0") == 0
                || std::strcmp(value, "false") == 0
                || std::strcmp(value, "off") == 0
                || std::strcmp(value, "no") == 0);
        }();

        return enabled;
    }

    void checkSDLError(int ret)
    {
        if (ret != 0)
            Log(Debug::Error) << "SDL error: " << SDL_GetError();
    }

    void initStatsHandler(Resource::Profiler& profiler)
    {
        const osg::Vec4f textColor(1.f, 1.f, 1.f, 1.f);
        const osg::Vec4f barColor(1.f, 1.f, 1.f, 1.f);
        const float multiplier = 1000;
        const bool average = true;
        const bool averageInInverseSpace = false;
        const float maxValue = 10000;

        OMW::forEachUserStatsValue([&](const OMW::UserStats& v) {
            profiler.addUserStatsLine(v.mLabel, textColor, barColor, v.mTaken, multiplier, average,
                averageInInverseSpace, v.mBegin, v.mEnd, maxValue);
        });
        // the forEachUserStatsValue loop is "run" at compile time, hence the settings manager is not available.
        // Unconditionnally add the async physics stats, and then remove it at runtime if necessary
        if (Settings::physics().mAsyncNumThreads == 0)
            profiler.removeUserStatsLine(" -Async");
    }

    struct ScreenCaptureMessageBox
    {
        void operator()(std::string filePath) const
        {
            if (filePath.empty())
            {
                MWBase::Environment::get().getWindowManager()->scheduleMessageBox(
                    "#{OMWEngine:ScreenshotFailed}", MWGui::ShowInDialogueMode_Never);

                return;
            }

            auto l10n = MWBase::Environment::get().getL10nManager()->getContext("OMWEngine");
            std::string message = l10n->formatMessage("ScreenshotMade", { "file" }, { L10n::toUnicode(filePath) });

            MWBase::Environment::get().getWindowManager()->scheduleMessageBox(
                std::move(message), MWGui::ShowInDialogueMode_Never);
        }
    };

    struct IgnoreString
    {
        void operator()(std::string) const {}
    };

    // TSP_DEPTH_DIAG_051_V13
    // Prefer a 32-bit default depth buffer on the TSP. SDL/GL4ES may
    // return 24 or 16; createWindow() retries progressively when needed.
    int tspRequestedDepthBits()
    {
        constexpr int defaultDepth = 32;
        const char* value = std::getenv("OPENMW_TSP_DEPTH_BITS");
        if (value == nullptr || *value == '\0')
            return defaultDepth;
        char* end = nullptr;
        const long parsed = std::strtol(value, &end, 10);
        if (end != value && *end == '\0' && (parsed == 16 || parsed == 24 || parsed == 32))
            return static_cast<int>(parsed);
        Log(Debug::Warning) << "TSP DEPTH invalid OPENMW_TSP_DEPTH_BITS='" << value
                            << "'; using " << defaultDepth;
        return defaultDepth;
    }
    class IdentifyOpenGLOperation : public osg::GraphicsOperation
    {
    public:
        IdentifyOpenGLOperation()
            : GraphicsOperation("IdentifyOpenGLOperation", false)
        {
        }

        void operator()(osg::GraphicsContext* graphicsContext) override
        {
            Log(Debug::Info) << "OpenGL Vendor: " << glGetString(GL_VENDOR);
            Log(Debug::Info) << "OpenGL Renderer: " << glGetString(GL_RENDERER);
            Log(Debug::Info) << "OpenGL Version: " << glGetString(GL_VERSION);
            GLint tspGlDepthBits = -1;
            GLint tspGlStencilBits = -1;
            GLint tspDepthFunc = -1;
            GLfloat tspDepthRange[2] = { -1.f, -1.f };
            glGetIntegerv(GL_DEPTH_BITS, &tspGlDepthBits);
            glGetIntegerv(GL_STENCIL_BITS, &tspGlStencilBits);
            glGetIntegerv(GL_DEPTH_FUNC, &tspDepthFunc);
            glGetFloatv(GL_DEPTH_RANGE, tspDepthRange);
            int tspSdlDepthBits = -1;
            int tspSdlStencilBits = -1;
            SDL_GL_GetAttribute(SDL_GL_DEPTH_SIZE, &tspSdlDepthBits);
            SDL_GL_GetAttribute(SDL_GL_STENCIL_SIZE, &tspSdlStencilBits);
            const char* tspExtensions = reinterpret_cast<const char*>(glGetString(GL_EXTENSIONS));
            const bool tspOesDepth24 = tspExtensions && std::strstr(tspExtensions, "GL_OES_depth24");
            const bool tspPackedDepthStencil
                = tspExtensions && (std::strstr(tspExtensions, "GL_OES_packed_depth_stencil")
                    || std::strstr(tspExtensions, "GL_EXT_packed_depth_stencil"));
            const bool tspFragDepth = tspExtensions && std::strstr(tspExtensions, "GL_EXT_frag_depth");
            Log(Debug::Info) << "TSP_DEPTH_DIAG_051_V13"
                             << " gl_depth_bits=" << tspGlDepthBits
                             << " gl_stencil_bits=" << tspGlStencilBits
                             << " sdl_depth_bits=" << tspSdlDepthBits
                             << " sdl_stencil_bits=" << tspSdlStencilBits
                             << " depth_func=" << tspDepthFunc
                             << " depth_range=" << tspDepthRange[0] << "," << tspDepthRange[1]
                             << " oes_depth24=" << (tspOesDepth24 ? 1 : 0)
                             << " packed_depth_stencil=" << (tspPackedDepthStencil ? 1 : 0)
                             << " ext_frag_depth=" << (tspFragDepth ? 1 : 0);
            glGetIntegerv(GL_MAX_TEXTURE_IMAGE_UNITS, &mMaxTextureImageUnits);
            if (mMaxTextureImageUnits <= 0)
            {
                Log(Debug::Warning) << "GL_MAX_TEXTURE_IMAGE_UNITS returned " << mMaxTextureImageUnits
                                    << "; using GLES2 minimum fallback of 8";
                mMaxTextureImageUnits = 8;
            }
        }

        int getMaxTextureImageUnits() const
        {
            if (mMaxTextureImageUnits == 0)
                throw std::logic_error("mMaxTextureImageUnits is not initialized");
            return mMaxTextureImageUnits;
        }

    private:
        int mMaxTextureImageUnits = 0;
    };

    void reportStats(unsigned frameNumber, osgViewer::Viewer& viewer, std::ostream& stream)
    {
        viewer.getViewerStats()->report(stream, frameNumber);
        osgViewer::Viewer::Cameras cameras;
        viewer.getCameras(cameras);
        for (osg::Camera* camera : cameras)
            camera->getStats()->report(stream, frameNumber);
    }
}

void OMW::Engine::executeLocalScripts()
{
    MWWorld::LocalScripts& localScripts = mWorld->getLocalScripts();

    localScripts.startIteration();
    std::pair<ESM::RefId, MWWorld::Ptr> script;
    while (localScripts.getNext(script))
    {
        MWScript::InterpreterContext interpreterContext(&script.second.getRefData().getLocals(), script.second);
        mScriptManager->run(script.first, interpreterContext);
    }
}


/* TSP_LOAD_FREEZE: frames still to hold after a save load. Armed by
   StateManager when loading completes, decremented in Engine::frame, and
   cleared early once the shader warm-up group has drained. File-static so no
   header change is needed. */
namespace
{
    int tspLoadFreezeFrames = 0;
}
void tspArmLoadFreeze()
{
    if (std::getenv("TSP_NO_LOAD_FREEZE"))
        return;
    int frames = 300;
    if (const char* e = std::getenv("TSP_LOAD_FREEZE_FRAMES"))
    {
        int v = atoi(e);
        if (v > 0)
            frames = v;
    }
    tspLoadFreezeFrames = frames;
    Log(Debug::Info) << "TSP_LOAD_FREEZE armed for " << frames << " frames";
}


/* TSP_CELL_HOOKS2: fired from Engine::frame where the engine already
   acknowledges a completed cell change (markCellAsUnchanged), NOT from
   World::changeTo*Cell - those are the load path and firing there produced
   "you cannot save your game right now" on every startup. */
namespace
{
    long long tspReadMemAvailableKb()
    {
        std::ifstream stream("/proc/meminfo");
        std::string line;
        while (std::getline(stream, line))
        {
            if (line.rfind("MemAvailable:", 0) == 0)
            {
                std::istringstream valueStream(line.substr(13));
                long long kb = -1;
                valueStream >> kb;
                return kb;
            }
        }
        return -1;
    }

    double tspIntervalFromEnv(const char* name, double fallback)
    {
        if (const char* e = std::getenv(name))
        {
            const double v = atof(e);
            if (v > 0.0)
                return v;
        }
        return fallback;
    }

    bool tspIntervalElapsed(std::chrono::steady_clock::time_point& last, bool& have, double secs)
    {
        const auto now = std::chrono::steady_clock::now();
        if (have)
        {
            const double since
                = std::chrono::duration_cast<std::chrono::duration<double>>(now - last).count();
            if (since < secs)
                return false;
        }
        last = now;
        have = true;
        return true;
    }

    // TSP_AUTOSAVE_ON_DOOR_V1
    // Rotating autosave slots. The index lives in a small file so rotation
    // survives a relaunch - an in-memory counter would overwrite slot 1 every
    // session and the other four would never be reached. Both the path and the
    // slot count are env-overridable so tuning is a one-token change.
    const char* tspAutoslotPath()
    {
        if (const char* e = std::getenv("TSP_AUTOSLOT_FILE"))
            if (e[0] != '\0')
                return e;
        return "/mnt/SDCARD/data/ports/openmw51/config-0.51/tsp_autoslot.txt";
    }

    int tspAutosaveSlots()
    {
        int n = 5;
        if (const char* e = std::getenv("TSP_AUTOSAVE_SLOTS"))
        {
            const int v = atoi(e);
            if (v > 0 && v <= 20)
                n = v;
        }
        return n;
    }

    int tspNextAutosaveSlot()
    {
        const int slots = tspAutosaveSlots();
        static int sSlot = -1;
        static bool sComplained = false;
        if (sSlot < 0)
        {
            sSlot = 0;
            if (FILE* f = std::fopen(tspAutoslotPath(), "r"))
            {
                int v = 0;
                if (std::fscanf(f, "%d", &v) == 1 && v >= 0)
                    sSlot = v;
                std::fclose(f);
            }
            else if (!sComplained)
            {
                sComplained = true;
                Log(Debug::Info) << "TSP_AUTOSAVE slot file not readable, starting at 0: "
                                 << tspAutoslotPath();
            }
        }
        const int use = sSlot % slots;
        sSlot = (use + 1) % slots;
        if (FILE* f = std::fopen(tspAutoslotPath(), "w"))
        {
            std::fprintf(f, "%d\n", sSlot);
            std::fclose(f);
        }
        else if (!sComplained)
        {
            sComplained = true;
            Log(Debug::Info) << "TSP_AUTOSAVE slot file not writable, rotation will not survive "
                             << "a relaunch: " << tspAutoslotPath();
        }
        return use;
    }

    void tspOnCellChanged(Resource::ResourceSystem* resourceSystem)
    {
        /* Mirror quickSave's own preconditions exactly (statemanagerimp.cpp).
           isSavingAllowed() is false during a load, so this cannot trip the
           SaveGameDenied message box the way the previous version did. */
        MWBase::StateManager* stateManager = MWBase::Environment::get().getStateManager();
        MWBase::World* world = MWBase::Environment::get().getWorld();
        MWBase::WindowManager* windowManager = MWBase::Environment::get().getWindowManager();
        if (!stateManager || !world || !windowManager)
            return;

        const bool saveOk = stateManager->getState() == MWBase::StateManager::State_Running
            && world->getGlobalInt(MWWorld::Globals::sCharGenState) == -1
            && windowManager->isSavingAllowed();

        if (!saveOk)
        {
            /* TSP_AUTOSAVE_LOG_GATE_V1: this fires once per frame during exterior
   movement and each line is an SD-card write. TSP_CELL_AUTOSAVE_LOG=1 restores it. */
            if (std::getenv("TSP_CELL_AUTOSAVE_LOG") != nullptr)
                Log(Debug::Info) << "TSP_CELL_AUTOSAVE skipped: saving not allowed yet";
            return;
        }

        if (!std::getenv("TSP_NO_CELL_GLRELEASE"))
        {
            static std::chrono::steady_clock::time_point sLastRel;
            static bool sHaveRel = false;
            if (tspIntervalElapsed(sLastRel, sHaveRel,
                    tspIntervalFromEnv("TSP_CELL_GLRELEASE_SECS", 90.0)))
            {
                Resource::ResourceSystem* rs = resourceSystem;
                if (rs)
                {
                    const long long before = tspReadMemAvailableKb();
                    rs->releaseGLObjects(nullptr);
                    const long long after = tspReadMemAvailableKb();
                    Log(Debug::Info) << "TSP_CELL_GLRELEASE avail_before_kb=" << before
                                     << " avail_after_kb=" << after
                                     << " reclaimed_kb=" << (after - before);
                }
            }
        }

        if (!std::getenv("TSP_NO_CELL_AUTOSAVE"))
        {
            // TSP_AUTOSAVE_ON_DOOR_V1
            // This function runs on EVERY cell change, and in an exterior that
            // includes sliding across an invisible cell line while walking. The
            // old 120 s timer therefore did not choose WHEN to save, only which
            // boundary crossing got picked - so it fired in the middle of
            // nowhere, and cost ~310 ms each time (measured: frames 6929, 10321
            // and 13712, total 310.4/310.4/316.2 ms, exactly 3391 frames apart).
            //
            // MWWorld::Cell::getWorldSpace() is `mIsExterior ? mParent : mId`.
            // Every exterior cell in a worldspace shares one value, and every
            // interior has its own. So a change of worldspace is precisely a
            // door or teleport transition and never a walk. Saving there hides
            // the cost behind the loading screen that is already happening.
            //
            // There is deliberately NO periodic backstop. Doors only.
            static ESM::RefId sLastWorldspace;
            static bool sHaveLastWorldspace = false;

            ESM::RefId worldspace;
            bool haveWorldspace = false;
            MWWorld::Ptr player = world->getPlayerPtr();
            if (!player.isEmpty())
            {
                if (MWWorld::CellStore* store = player.getCell())
                {
                    if (const MWWorld::Cell* cell = store->getCell())
                    {
                        worldspace = cell->getWorldSpace();
                        haveWorldspace = true;
                    }
                }
            }

            if (!haveWorldspace)
            {
                /* TSP_AUTOSAVE_LOG_GATE_V1: this fires once per frame during exterior
   movement and each line is an SD-card write. TSP_CELL_AUTOSAVE_LOG=1 restores it. */
            if (std::getenv("TSP_CELL_AUTOSAVE_LOG") != nullptr)
                Log(Debug::Info) << "TSP_CELL_AUTOSAVE skipped: no player cell";
            }
            else if (!sHaveLastWorldspace)
            {
                sLastWorldspace = worldspace;
                sHaveLastWorldspace = true;
                Log(Debug::Info) << "TSP_CELL_AUTOSAVE armed on first worldspace";
            }
            else if (worldspace == sLastWorldspace)
            {
                /* TSP_AUTOSAVE_LOG_GATE_V1: this fires once per frame during exterior
   movement and each line is an SD-card write. TSP_CELL_AUTOSAVE_LOG=1 restores it. */
            if (std::getenv("TSP_CELL_AUTOSAVE_LOG") != nullptr)
                Log(Debug::Info) << "TSP_CELL_AUTOSAVE skipped: same worldspace, exterior grid move";
            }
            else
            {
                sLastWorldspace = worldspace;
                static std::chrono::steady_clock::time_point sLastSave;
                static bool sHaveSave = false;
                if (!tspIntervalElapsed(sLastSave, sHaveSave,
                        tspIntervalFromEnv("TSP_CELL_AUTOSAVE_MIN_SECS", 15.0)))
                {
                    Log(Debug::Info) << "TSP_CELL_AUTOSAVE skipped: door cooldown";
                }
                else
                {
                    const std::string name = "Autosave " + std::to_string(tspNextAutosaveSlot() + 1);
                    Log(Debug::Info) << "TSP_CELL_AUTOSAVE saving on door transition, slot " << name;
                    stateManager->quickSave(name);
                }
            }
        }
    }
}

bool OMW::Engine::frame(unsigned frameNumber, float frametime)
{
    /* TSP: ring-buffer frame boundary. endFrame runs on scope exit whichever
       path returns, so every frame is recorded including early returns. */
    TspProf::dumpAtExit();
    struct TspFrameGuard { ~TspFrameGuard() { TspProf::endFrame(); } } tspFrameGuard;
    const osg::Timer_t frameStart = mViewer->getStartTick();
    const osg::Timer* const timer = osg::Timer::instance();
    osg::Stats* const stats = mViewer->getViewerStats();

    /* TSP_LOAD_FREEZE: hold simulation and input while the shader warm draws
       burn off. Rendering continues, so the warm-up triangles are drawn and
       Mali does its ~236ms per program here rather than during play. */
    const bool tspFrozen = (tspLoadFreezeFrames > 0);
    if (tspFrozen)
    {
        --tspLoadFreezeFrames;
        if (mResourceSystem)
        {
            osg::Group* warm
                = mResourceSystem->getSceneManager()->getShaderManager().getWarmupGroup();
            if (warm && warm->getNumChildren() == 0)
            {
                Log(Debug::Info) << "TSP_LOAD_FREEZE released early, "
                                 << tspLoadFreezeFrames << " frames unused";
                tspLoadFreezeFrames = 0;
            }
        }
        if (tspLoadFreezeFrames == 0)
            Log(Debug::Info) << "TSP_LOAD_FREEZE done";
    }
    mEnvironment.setFrameDuration(frametime);

    try
    {
        // update input
        {
            ScopedProfile<UserStatsType::Input> profile(frameStart, frameNumber, *timer, *stats);
            /* TSP_LOAD_FREEZE: disableControls is the engine's own
               mechanism for this - the player cannot move, swing or cast
               while it is set, and sound/GUI keep updating normally. */
            { TSP_SCOPE(TspProf::TSP_SLOT_INPUT); mInputManager->update(frametime, tspFrozen); }
        }

        // When the window is minimized, pause the game. Currently this *has* to be here to work around a MyGUI bug.
        // If we are not currently rendering, then RenderItems will not be reused resulting in a memory leak upon
        // changing widget textures (fixed in MyGUI 3.3.2), and destroyed widgets will not be deleted (not fixed yet,
        // https://github.com/MyGUI/mygui/issues/21)
        {
            ScopedProfile<UserStatsType::Sound> profile(frameStart, frameNumber, *timer, *stats);

            if (!mWindowManager->isWindowVisible())
            {
                mSoundManager->pausePlayback();
                return false;
            }
            else
                mSoundManager->resumePlayback();

            // sound
            if (mUseSound)
                /* TSP_SOUNDSLOW_V1: the sound slot averages 0.07-0.19 ms and
                   spikes to a very repeatable ~33 ms in 6 of 13 ring captures,
                   producing the worst frame in each. Verdict is burned real CPU,
                   not blocked, so it is decoding on the main thread. Find out
                   whether it correlates with music. */
                {
                    const osg::Timer_t tspSndT0 = osg::Timer::instance()->tick();
                    { TSP_SCOPE(TspProf::TSP_SLOT_SOUND); mSoundManager->update(frametime); }
                    const double tspSndMs
                        = osg::Timer::instance()->delta_m(tspSndT0, osg::Timer::instance()->tick());
                    static int tspSndLines = 0;
                    if (tspSndMs >= 15.0 && tspSndLines < 200)
                    {
                        ++tspSndLines;
                        Log(Debug::Info) << "TSP_SOUNDSLOW_V1 ms=" << tspSndMs
                                         << " music=" << (mSoundManager->isMusicPlaying() ? 1 : 0);
                    }
                }
        }

        {
            ScopedProfile<UserStatsType::LuaSyncUpdate> profile(frameStart, frameNumber, *timer, *stats);
            // Should be called after input manager update and before any change to the game world.
            // It applies to the game world queued changes from the previous frame.
            { TSP_SCOPE(TspProf::TSP_SLOT_LUA); mLuaManager->synchronizedUpdate(); }
        }

        // update game state
        {
            ScopedProfile<UserStatsType::State> profile(frameStart, frameNumber, *timer, *stats);
            { TSP_SCOPE(TspProf::TSP_SLOT_STATE); mStateManager->update(frametime); }
        }

        bool paused = mWorld->getTimeManager()->isPaused();
        if (tspFrozen)
            paused = true;

        {
            ScopedProfile<UserStatsType::Script> profile(frameStart, frameNumber, *timer, *stats);

            if (mStateManager->getState() != MWBase::StateManager::State_NoGame)
            {
                if (!mWindowManager->containsMode(MWGui::GM_MainMenu) || !paused)
                {
                    if (mWorld->getScriptsEnabled())
                    {
                        // local scripts
                        { TSP_SCOPE(TspProf::TSP_SLOT_SCRIPT); executeLocalScripts(); }

                        // global scripts
                        { TSP_SCOPE(TspProf::TSP_SLOT_SCRIPT); mScriptManager->getGlobalScripts().run(); }
                    }

                    /* TSP_CELL_HOOKS2: the engine acknowledges the completed cell change here. */
                    tspOnCellChanged(mResourceSystem.get());
                    mWorld->getWorldScene().markCellAsUnchanged();
                }

                if (!paused)
                {
                    double hours = (frametime * mWorld->getTimeManager()->getGameTimeScale()) / 3600.0;
                    mWorld->advanceTime(hours, true);
                    mWorld->rechargeItems(frametime, true);
                }
            }
        }

        // update mechanics
        {
            ScopedProfile<UserStatsType::Mechanics> profile(frameStart, frameNumber, *timer, *stats);

            if (mStateManager->getState() != MWBase::StateManager::State_NoGame)
            {
                { TSP_SCOPE(TspProf::TSP_SLOT_MECH); mMechanicsManager->update(frametime, paused); }
            }

            if (mStateManager->getState() == MWBase::StateManager::State_Running)
            {
                MWWorld::Ptr player = mWorld->getPlayerPtr();
                if (!paused && player.getClass().getCreatureStats(player).isDead())
                    mStateManager->endGame();
            }
        }

        // update physics
        {
            ScopedProfile<UserStatsType::Physics> profile(frameStart, frameNumber, *timer, *stats);

            if (mStateManager->getState() != MWBase::StateManager::State_NoGame)
            {
                { TSP_SCOPE(TspProf::TSP_SLOT_PHYS); mWorld->updatePhysics(frametime, paused, frameStart, frameNumber, *stats); }
            }
        }

        // update world
        {
            ScopedProfile<UserStatsType::World> profile(frameStart, frameNumber, *timer, *stats);

            if (mStateManager->getState() != MWBase::StateManager::State_NoGame)
            {
                { TSP_SCOPE(TspProf::TSP_SLOT_WORLD); mWorld->update(frametime, paused); }
            }
        }

        // update GUI
        {
            ScopedProfile<UserStatsType::Gui> profile(frameStart, frameNumber, *timer, *stats);
            { TSP_SCOPE(TspProf::TSP_SLOT_GUI); mWindowManager->update(frametime); }
        }
    }
    catch (const std::exception& e)
    {
        Log(Debug::Error) << "Error in frame: " << e.what();
    }

    const bool reportResource = stats->collectStats("resource");

    if (reportResource)
        stats->setAttribute(frameNumber, "UnrefQueue", static_cast<double>(mUnrefQueue->getSize()));

    { TSP_SCOPE(TspProf::TSP_SLOT_UNREF); mUnrefQueue->flush(*mWorkQueue); }

    if (reportResource)
    {
        stats->setAttribute(frameNumber, "FrameNumber", frameNumber);

        mResourceSystem->reportStats(frameNumber, stats);

        stats->setAttribute(frameNumber, "WorkQueue", static_cast<double>(mWorkQueue->getNumItems()));
        stats->setAttribute(frameNumber, "WorkThread", static_cast<double>(mWorkQueue->getNumActiveThreads()));

        mMechanicsManager->reportStats(frameNumber, *stats);
        mWorld->reportStats(frameNumber, *stats);
        mLuaManager->reportStats(frameNumber, *stats);

        stats->setAttribute(frameNumber, "StringRefId Count", static_cast<double>(ESM::StringRefId::totalCount()));
    }

    mStereoManager->updateSettings(Settings::camera().mNearClip, Settings::camera().mViewingDistance);

    { TSP_SCOPE(TspProf::TSP_SLOT_EVENT); mViewer->eventTraversal(); }
    { TSP_SCOPE(TspProf::TSP_SLOT_UPDATET); mViewer->updateTraversal(); }

    // update focus object for GUI
    {
        ScopedProfile<UserStatsType::Focus> profile(frameStart, frameNumber, *timer, *stats);
        { TSP_SCOPE(TspProf::TSP_SLOT_FOCUS); mWorld->updateFocusObject(); }
    }

    // if there is a separate Lua thread, it starts the update now
    mLuaWorker->allowUpdate(frameStart, frameNumber, *stats);

    /* TSP_CULLDRAW_V6: the render slot is 45-50 ms in busy frames while total GL
       is ~5 ms excluding swap, so the cost is OSG's own traversal. Split it into
       cull vs draw from OSG's own stats - two completely different fixes. The
       TSP_CULLDRAW_V5 block that did this was lost in the August tree loss and
       currently emits nothing. Capped so it cannot flood the SD card. */
    {
        static bool tspStatsArmed = false;
        if (!tspStatsArmed)
        {
            tspStatsArmed = true;
            if (osg::Camera* tspCam = mViewer->getCamera())
            {
                if (!tspCam->getStats())
                    tspCam->setStats(new osg::Stats("Camera"));
                tspCam->getStats()->collectStats("rendering", true);
            }
            if (mViewer->getViewerStats())
                mViewer->getViewerStats()->collectStats("rendering", true);
        }
        const osg::Timer_t tspT0 = osg::Timer::instance()->tick();
        { TSP_SCOPE(TspProf::TSP_SLOT_RENDER); mViewer->renderingTraversals(); }
        const double tspRenderMs = osg::Timer::instance()->delta_m(tspT0, osg::Timer::instance()->tick());
        static int tspLines = 0;
        if (tspRenderMs >= 35.0 && tspLines < 300)
        {
            ++tspLines;
            double tspCull = -1.0, tspDraw = -1.0;
            const unsigned int tspFn = mViewer->getFrameStamp()->getFrameNumber();
            osg::Camera* tspCam = mViewer->getCamera();
            osg::Stats* tspSt = tspCam ? tspCam->getStats() : nullptr;
            if (tspSt)
            {
                if (!tspSt->getAttribute(tspFn, "Cull traversal time taken", tspCull))
                    tspSt->getAttribute(tspFn - 1, "Cull traversal time taken", tspCull);
                if (!tspSt->getAttribute(tspFn, "Draw traversal time taken", tspDraw))
                    tspSt->getAttribute(tspFn - 1, "Draw traversal time taken", tspDraw);
            }
            const double tspCullMs = (tspCull > 0.0) ? tspCull * 1000.0 : 0.0;
            const double tspDrawMs = (tspDraw > 0.0) ? tspDraw * 1000.0 : 0.0;
            Log(Debug::Info) << "TSP_CULLDRAW_V6 render=" << tspRenderMs
                             << " cull=" << tspCullMs << " draw=" << tspDrawMs
                             << " resid=" << (tspRenderMs - tspCullMs - tspDrawMs);
        }
    }

    { TSP_SCOPE(TspProf::TSP_SLOT_LUAWAIT); mLuaWorker->finishUpdate(frameStart, frameNumber, *stats); }
    // TSP_PROF_FRAME_BOUNDARY_V3
    // The true end of the frame body. V2 placed this ABOVE
    // mLuaWorker->finishUpdate(), so the wait for the Lua worker thread fell
    // outside the frame and rolled into the next one's total.
    //
    // dumpAtExit() is called every frame rather than once at some shutdown
    // site: a function-local static costs one guard load and cannot be missed
    // by a code path that happens not to run. The exit dump is only a fallback
    // anyway - the trigger in tspprof.h is what catches a dip, since a crash
    // or a kill never runs a static destructor.
    TspProf::endFrame();
    TspProf::dumpAtExit();
    // TSP_PROF_FRAME_BOUNDARY_V4
    // endFrame() is NOT called here. It is already called by the RAII guard at
    // the top of this function:
    //
    //     struct TspFrameGuard  ->  its destructor calls endFrame()
    //     declared at the top of this function as tspFrameGuard
    //
    // which fires on return - after mLuaWorker->finishUpdate() - and so closes
    // the whole frame. V2 added a second call right here, and the ring then
    // recorded one phantom per real frame: two endFrame() calls microseconds
    // apart, the second with zero elapsed and zero calls in every slot.
    //
    // dumpAtExit() still belongs here. The guard does not do it, and a
    // function-local static costs one guard load per frame and cannot be
    // missed by a code path that happens not to run.
    TspProf::dumpAtExit();

    return true;
}

OMW::Engine::Engine(Files::ConfigurationManager& configurationManager)
    : mWindow(nullptr)
    , mEncoding(ToUTF8::WINDOWS_1252)
    , mScreenCaptureOperation(nullptr)
    , mSelectDepthFormatOperation(new SceneUtil::SelectDepthFormatOperation())
    , mSelectColorFormatOperation(new SceneUtil::Color::SelectColorFormatOperation())
    , mStereoManager(nullptr)
    , mSkipMenu(false)
    , mUseSound(true)
    , mCompileAll(false)
    , mCompileAllDialogue(false)
    , mWarningsMode(1)
    , mScriptConsoleMode(false)
    , mActivationDistanceOverride(-1)
    , mGrab(true)
    , mExportFonts(false)
    , mRandomSeed(0)
    , mNewGame(false)
    , mCfgMgr(configurationManager)
    , mGlMaxTextureImageUnits(0)
{
#if SDL_VERSION_ATLEAST(2, 24, 0)
    SDL_SetHint(SDL_HINT_MAC_OPENGL_ASYNC_DISPATCH, "1");
#endif
    SDL_SetHint(SDL_HINT_ACCELEROMETER_AS_JOYSTICK, "0"); // We use only gamepads

    Uint32 flags
        = SDL_INIT_VIDEO | SDL_INIT_NOPARACHUTE | SDL_INIT_GAMECONTROLLER | SDL_INIT_JOYSTICK | SDL_INIT_SENSOR;
    if (SDL_WasInit(flags) == 0)
    {
        SDL_SetMainReady();
        if (SDL_Init(flags) != 0)
        {
            throw std::runtime_error("Could not initialize SDL! " + std::string(SDL_GetError()));
        }
    }
}

OMW::Engine::~Engine()
{
    if (mScreenCaptureOperation != nullptr)
    {
        mScreenCaptureOperation->stop();
        mScreenCaptureOperation = nullptr;
    }
    mScreenCaptureHandler = nullptr;

    mMechanicsManager = nullptr;
    mDialogueManager = nullptr;
    mJournal = nullptr;
    mWindowManager = nullptr;
    mScriptManager = nullptr;
    mWorld = nullptr;
    mStereoManager = nullptr;
    mSoundManager = nullptr;
    mInputManager = nullptr;
    mStateManager = nullptr;
    mLuaWorker = nullptr;
    mLuaManager = nullptr;
    mL10nManager = nullptr;

    mScriptContext = nullptr;

    mUnrefQueue = nullptr;
    mWorkQueue = nullptr;

    mViewer = nullptr;

    mResourceSystem.reset();

    mEncoder = nullptr;

    if (mWindow)
    {
        SDL_DestroyWindow(mWindow);
        mWindow = nullptr;
    }

    SDL_Quit();

    Log(Debug::Info) << "Quitting peacefully.";
}

// Set data dir

void OMW::Engine::setDataDirs(const Files::PathContainer& dataDirs)
{
    mDataDirs = dataDirs;
    mDataDirs.insert(mDataDirs.begin(), mResDir / "vfs");
    mFileCollections = Files::Collections(mDataDirs);
}

// Add BSA archive
void OMW::Engine::addArchive(const std::string& archive)
{
    mArchives.push_back(archive);
}

// Set resource dir
void OMW::Engine::setResourceDir(const std::filesystem::path& parResDir)
{
    mResDir = parResDir;
    if (!Version::checkResourcesVersion(mResDir))
        Log(Debug::Error) << "Resources dir " << mResDir
                          << " doesn't match OpenMW binary, the game may work incorrectly.";
}

// Set start cell name
void OMW::Engine::setCell(const std::string& cellName)
{
    mCellName = cellName;
}

void OMW::Engine::addContentFile(const std::string& file)
{
    mContentFiles.push_back(file);
}

void OMW::Engine::addGroundcoverFile(const std::string& file)
{
    mGroundcoverFiles.emplace_back(file);
}

void OMW::Engine::setSkipMenu(bool skipMenu, bool newGame)
{
    mSkipMenu = skipMenu;
    mNewGame = newGame;
}

void OMW::Engine::createWindow()
{
    const int screen = Settings::video().mScreen;
    const int tspInternalWidth = Settings::video().mResolutionX;
    const int tspInternalHeight = Settings::video().mResolutionY;
    // TSP_RESOLUTION_SPLIT_051_V21
    // The fixed TSP LCD/EGL drawable is always native 1280x720.
    // Video resolution settings are repurposed as GL4ES internal render size.
    const int width = 1280;
    const int height = 720;
    Log(Debug::Info)
        << "TSP_RESOLUTION_SPLIT_051_V21"
        << " physical=" << width << "x" << height
        << " internal=" << tspInternalWidth << "x" << tspInternalHeight;

    const Settings::WindowMode windowMode = Settings::video().mWindowMode;
    const bool windowBorder = Settings::video().mWindowBorder;
    const SDLUtil::VSyncMode vsync = Settings::video().mVsyncMode;
    unsigned antialiasing = static_cast<unsigned>(Settings::video().mAntialiasing);

    int posX = SDL_WINDOWPOS_CENTERED_DISPLAY(screen);
    int posY = SDL_WINDOWPOS_CENTERED_DISPLAY(screen);

    if (windowMode == Settings::WindowMode::Fullscreen || windowMode == Settings::WindowMode::WindowedFullscreen)
    {
        posX = SDL_WINDOWPOS_UNDEFINED_DISPLAY(screen);
        posY = SDL_WINDOWPOS_UNDEFINED_DISPLAY(screen);
    }

    Uint32 flags = SDL_WINDOW_OPENGL | SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI;
    if (windowMode == Settings::WindowMode::Fullscreen)
        flags |= SDL_WINDOW_FULLSCREEN;
    else if (windowMode == Settings::WindowMode::WindowedFullscreen)
        flags |= SDL_WINDOW_FULLSCREEN_DESKTOP;

    // Allows for Windows snapping features to properly work in borderless window
    SDL_SetHint("SDL_BORDERLESS_WINDOWED_STYLE", "1");
    SDL_SetHint("SDL_BORDERLESS_RESIZABLE_STYLE", "1");

    if (!windowBorder)
        flags |= SDL_WINDOW_BORDERLESS;

    SDL_SetHint(SDL_HINT_VIDEO_MINIMIZE_ON_FOCUS_LOSS, Settings::video().mMinimizeOnFocusLoss ? "1" : "0");

    checkSDLError(SDL_GL_SetAttribute(SDL_GL_RED_SIZE, 8));
    checkSDLError(SDL_GL_SetAttribute(SDL_GL_GREEN_SIZE, 8));
    checkSDLError(SDL_GL_SetAttribute(SDL_GL_BLUE_SIZE, 8));
    checkSDLError(SDL_GL_SetAttribute(SDL_GL_ALPHA_SIZE, 0));
    int tspDepthBits = tspRequestedDepthBits();
    const int tspInitialDepthBits = tspDepthBits;
    int tspStencilBits = 8;
    Log(Debug::Info) << "TSP_DEPTH_REQUEST_051_V13 requested_depth=" << tspDepthBits
                     << " requested_stencil=" << tspStencilBits;
    SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, tspDepthBits);
    SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, tspStencilBits);
    if (Debug::shouldDebugOpenGL())
        checkSDLError(SDL_GL_SetAttribute(SDL_GL_CONTEXT_FLAGS, SDL_GL_CONTEXT_DEBUG_FLAG));

    if (antialiasing > 0)
    {
        checkSDLError(SDL_GL_SetAttribute(SDL_GL_MULTISAMPLEBUFFERS, 1));
        checkSDLError(SDL_GL_SetAttribute(SDL_GL_MULTISAMPLESAMPLES, antialiasing));
    }

    osg::ref_ptr<SDLUtil::GraphicsWindowSDL2> graphicsWindow;
    while (!graphicsWindow || !graphicsWindow->valid())
    {
        while (!mWindow)
        {
            mWindow = SDL_CreateWindow("OpenMW", posX, posY, width, height, flags);
            if (!mWindow)
            {
                // Try with a lower AA
                if (antialiasing > 0)
                {
                    Log(Debug::Warning) << "Warning: " << antialiasing << "x antialiasing not supported, trying "
                                        << antialiasing / 2;
                    antialiasing /= 2;
                    Settings::video().mAntialiasing.set(antialiasing);
                    checkSDLError(SDL_GL_SetAttribute(SDL_GL_MULTISAMPLESAMPLES, antialiasing));
                    continue;
                }
                else
                {
                    if (tspDepthBits > 24)
                    {
                        Log(Debug::Warning) << "TSP DEPTH: SDL window creation failed at depth="
                                            << tspDepthBits << "; retrying depth=24";
                        tspDepthBits = 24;
                        SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, tspDepthBits);
                        continue;
                    }
                    if (tspDepthBits > 16)
                    {
                        Log(Debug::Warning) << "TSP DEPTH: SDL window creation failed at depth=24; retrying depth=16";
                        tspDepthBits = 16;
                        SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, tspDepthBits);
                        continue;
                    }
                    if (tspStencilBits > 0)
                    {
                        Log(Debug::Warning) << "TSP DEPTH: SDL window creation still failed; retrying stencil=0";
                        tspStencilBits = 0;
                        SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, tspStencilBits);
                        continue;
                    }
                    std::stringstream error;
                    error << "Failed to create SDL window: " << SDL_GetError();
                    throw std::runtime_error(error.str());
                }
            }
        }

        // Since we use physical resolution internally, we have to create the window with scaled resolution,
        // but we can't get the scale before the window exists, so instead we have to resize aftewards.
        int w, h;
        SDL_GetWindowSize(mWindow, &w, &h);
        int dw, dh;
        SDL_GL_GetDrawableSize(mWindow, &dw, &dh);
        if (dw != w || dh != h)
        {
            SDL_SetWindowSize(mWindow, width / (dw / w), height / (dh / h));
        }

        setWindowIcon();

        osg::ref_ptr<osg::GraphicsContext::Traits> traits = new osg::GraphicsContext::Traits;
        SDL_GetWindowPosition(mWindow, &traits->x, &traits->y);
        SDL_GL_GetDrawableSize(mWindow, &traits->width, &traits->height);
        traits->windowName = SDL_GetWindowTitle(mWindow);
        traits->windowDecoration = !(SDL_GetWindowFlags(mWindow) & SDL_WINDOW_BORDERLESS);
        traits->screenNum = SDL_GetWindowDisplayIndex(mWindow);
        traits->vsync = 0;
        traits->inheritedWindowData = new SDLUtil::GraphicsWindowSDL2::WindowData(mWindow);

        graphicsWindow = new SDLUtil::GraphicsWindowSDL2(traits, vsync);
        if (!graphicsWindow->valid())
            throw std::runtime_error("Failed to create GraphicsContext");

        if (traits->samples < antialiasing)
        {
            Log(Debug::Warning) << "Warning: Framebuffer MSAA level is only " << traits->samples << "x instead of "
                                << antialiasing << "x. Trying " << antialiasing / 2 << "x instead.";
            graphicsWindow->closeImplementation();
            SDL_DestroyWindow(mWindow);
            mWindow = nullptr;
            antialiasing /= 2;
            Settings::video().mAntialiasing.set(antialiasing);
            checkSDLError(SDL_GL_SetAttribute(SDL_GL_MULTISAMPLESAMPLES, antialiasing));
            continue;
        }

        if (traits->red < 8)
            Log(Debug::Warning) << "Warning: Framebuffer only has a " << traits->red << " bit red channel.";
        if (traits->green < 8)
            Log(Debug::Warning) << "Warning: Framebuffer only has a " << traits->green << " bit green channel.";
        if (traits->blue < 8)
            Log(Debug::Warning) << "Warning: Framebuffer only has a " << traits->blue << " bit blue channel.";
        Log(Debug::Info) << "TSP_DEPTH_TRAITS_051_V13 initial_request=" << tspInitialDepthBits
                         << " active_request=" << tspDepthBits
                         << " active_stencil_request=" << tspStencilBits
                         << " osg_depth=" << traits->depth
                         << " osg_stencil=" << traits->stencil;
        if (traits->depth < 24)
            Log(Debug::Warning) << "Warning: Framebuffer only has " << traits->depth << " bits of depth precision.";

        traits->alpha = 0; // set to 0 to stop ScreenCaptureHandler reading the alpha channel
    }

    osg::ref_ptr<osg::Camera> camera = mViewer->getCamera();
    camera->setGraphicsContext(graphicsWindow);
    camera->setViewport(0, 0, graphicsWindow->getTraits()->width, graphicsWindow->getTraits()->height);

    osg::ref_ptr<SceneUtil::OperationSequence> realizeOperations = new SceneUtil::OperationSequence(false);
    mViewer->setRealizeOperation(realizeOperations);
    osg::ref_ptr<IdentifyOpenGLOperation> identifyOp = new IdentifyOpenGLOperation();
    realizeOperations->add(identifyOp);
    realizeOperations->add(new SceneUtil::GetGLExtensionsOperation());

    if (Debug::shouldDebugOpenGL())
        realizeOperations->add(new Debug::EnableGLDebugOperation());

    realizeOperations->add(mSelectDepthFormatOperation);
    realizeOperations->add(mSelectColorFormatOperation);

    if (Stereo::getStereo())
    {
        Stereo::Settings settings;

        settings.mMultiview = Settings::stereo().mMultiview;
        settings.mAllowDisplayListsForMultiview = Settings::stereo().mAllowDisplayListsForMultiview;
        settings.mSharedShadowMaps = Settings::stereo().mSharedShadowMaps;

        if (Settings::stereo().mUseCustomView)
        {
            const osg::Vec3 leftEyeOffset(Settings::stereoView().mLeftEyeOffsetX,
                Settings::stereoView().mLeftEyeOffsetY, Settings::stereoView().mLeftEyeOffsetZ);

            const osg::Quat leftEyeOrientation(Settings::stereoView().mLeftEyeOrientationX,
                Settings::stereoView().mLeftEyeOrientationY, Settings::stereoView().mLeftEyeOrientationZ,
                Settings::stereoView().mLeftEyeOrientationW);

            const osg::Vec3 rightEyeOffset(Settings::stereoView().mRightEyeOffsetX,
                Settings::stereoView().mRightEyeOffsetY, Settings::stereoView().mRightEyeOffsetZ);

            const osg::Quat rightEyeOrientation(Settings::stereoView().mRightEyeOrientationX,
                Settings::stereoView().mRightEyeOrientationY, Settings::stereoView().mRightEyeOrientationZ,
                Settings::stereoView().mRightEyeOrientationW);

            settings.mCustomView = Stereo::CustomView{
                .mLeft = Stereo::View{
                    .pose = Stereo::Pose{
                        .position = leftEyeOffset,
                        .orientation = leftEyeOrientation,
                    },
                    .fov = Stereo::FieldOfView{
                        .angleLeft = Settings::stereoView().mLeftEyeFovLeft,
                        .angleRight = Settings::stereoView().mLeftEyeFovRight,
                        .angleUp = Settings::stereoView().mLeftEyeFovUp,
                        .angleDown = Settings::stereoView().mLeftEyeFovDown,
                    },
                },
                .mRight = Stereo::View{
                    .pose = Stereo::Pose{
                        .position = rightEyeOffset,
                        .orientation = rightEyeOrientation,
                    },
                    .fov = Stereo::FieldOfView{
                        .angleLeft = Settings::stereoView().mRightEyeFovLeft,
                        .angleRight = Settings::stereoView().mRightEyeFovRight,
                        .angleUp = Settings::stereoView().mRightEyeFovUp,
                        .angleDown = Settings::stereoView().mRightEyeFovDown,
                    },
                },
            };
        }

        if (Settings::stereo().mUseCustomEyeResolution)
            settings.mEyeResolution
                = osg::Vec2i(Settings::stereoView().mEyeResolutionX, Settings::stereoView().mEyeResolutionY);

        realizeOperations->add(new Stereo::InitializeStereoOperation(settings));
    }

    mViewer->realize();
    mGlMaxTextureImageUnits = identifyOp->getMaxTextureImageUnits();

    mViewer->getEventQueue()->getCurrentEventState()->setWindowRectangle(
        0, 0, graphicsWindow->getTraits()->width, graphicsWindow->getTraits()->height);
}

void OMW::Engine::setWindowIcon()
{
    std::ifstream windowIconStream;
    const auto windowIcon = mResDir / "openmw.png";
    windowIconStream.open(windowIcon, std::ios_base::in | std::ios_base::binary);
    if (windowIconStream.fail())
        Log(Debug::Error) << "Error: Failed to open " << windowIcon;
    osgDB::ReaderWriter* reader = osgDB::Registry::instance()->getReaderWriterForExtension("png");
    if (!reader)
    {
        Log(Debug::Error) << "Error: Failed to read window icon, no png readerwriter found";
        return;
    }
    osgDB::ReaderWriter::ReadResult result = reader->readImage(windowIconStream);
    if (!result.success())
        Log(Debug::Error) << "Error: Failed to read " << windowIcon << ": " << result.message() << " code "
                          << result.status();
    else
    {
        osg::ref_ptr<osg::Image> image = result.getImage();
        auto surface = SDLUtil::imageToSurface(image, true);
        SDL_SetWindowIcon(mWindow, surface.get());
    }
}

void OMW::Engine::prepareEngine()
{
    mStateManager = std::make_unique<MWState::StateManager>(mCfgMgr.getUserDataPath() / "saves", mContentFiles);
    mEnvironment.setStateManager(*mStateManager);

    const bool stereoEnabled = Settings::stereo().mStereoEnabled || osg::DisplaySettings::instance().get()->getStereo();
    mStereoManager = std::make_unique<Stereo::Manager>(
        mViewer, stereoEnabled, Settings::camera().mNearClip, Settings::camera().mViewingDistance);

    osg::ref_ptr<osg::Group> rootNode(new osg::Group);
    mViewer->setSceneData(rootNode);

    createWindow();

    mVFS = std::make_unique<VFS::Manager>();

    VFS::registerArchives(mVFS.get(), mFileCollections, mArchives, true, &mEncoder.get()->getStatelessEncoder());

    mResourceSystem = std::make_unique<Resource::ResourceSystem>(
        mVFS.get(), Settings::cells().mCacheExpiryDelay, &mEncoder.get()->getStatelessEncoder());
    mResourceSystem->getSceneManager()->getShaderManager().setMaxTextureUnits(mGlMaxTextureImageUnits);
    mResourceSystem->getSceneManager()->setUnRefImageDataAfterApply(
        false); // keep to Off for now to allow better state sharing
    mResourceSystem->getSceneManager()->setFilterSettings(Settings::general().mTextureMagFilter,
        Settings::general().mTextureMinFilter, Settings::general().mTextureMipmap,
        static_cast<float>(Settings::general().mAnisotropy));
    mEnvironment.setResourceSystem(*mResourceSystem);

    mWorkQueue = new SceneUtil::WorkQueue(Settings::cells().mPreloadNumThreads);
    mUnrefQueue = std::make_unique<SceneUtil::UnrefQueue>();

    mScreenCaptureOperation = new SceneUtil::AsyncScreenCaptureOperation(mWorkQueue,
        new SceneUtil::WriteScreenshotToFileOperation(mCfgMgr.getScreenshotPath(),
            Settings::general().mScreenshotFormat,
            Settings::general().mNotifyOnSavedScreenshot ? std::function<void(std::string)>(ScreenCaptureMessageBox{})
                                                         : std::function<void(std::string)>(IgnoreString{})));

    mScreenCaptureHandler = new osgViewer::ScreenCaptureHandler(mScreenCaptureOperation);

    mViewer->addEventHandler(mScreenCaptureHandler);

    mL10nManager = std::make_unique<L10n::Manager>(mVFS.get());
    mL10nManager->setPreferredLocales(Settings::general().mPreferredLocales, Settings::general().mGmstOverridesL10n);
    mEnvironment.setL10nManager(*mL10nManager);

    mLuaManager = std::make_unique<MWLua::LuaManager>(mVFS.get(), mResDir / "lua_libs");
    mEnvironment.setLuaManager(*mLuaManager);

    // Create input and UI first to set up a bootstrapping environment for
    // showing a loading screen and keeping the window responsive while doing so

    const auto keybinderUser = mCfgMgr.getUserConfigPath() / "input_v3.xml";
    bool keybinderUserExists = std::filesystem::exists(keybinderUser);
    if (!keybinderUserExists)
    {
        const auto input2 = (mCfgMgr.getUserConfigPath() / "input_v2.xml");
        if (std::filesystem::exists(input2))
        {
            keybinderUserExists = std::filesystem::copy_file(input2, keybinderUser);
            Log(Debug::Info) << "Loading keybindings file: " << keybinderUser;
        }
    }
    else
        Log(Debug::Info) << "Loading keybindings file: " << keybinderUser;

    const auto userdefault = mCfgMgr.getUserConfigPath() / "gamecontrollerdb.txt";
    const auto localdefault = mCfgMgr.getLocalPath() / "gamecontrollerdb.txt";

    std::filesystem::path userGameControllerdb;
    if (std::filesystem::exists(userdefault))
        userGameControllerdb = userdefault;

    std::filesystem::path gameControllerdb;
    if (std::filesystem::exists(localdefault))
        gameControllerdb = localdefault;
    else if (!mCfgMgr.getGlobalPath().empty())
    {
        const auto globaldefault = mCfgMgr.getGlobalPath() / "gamecontrollerdb.txt";
        if (std::filesystem::exists(globaldefault))
            gameControllerdb = globaldefault;
    }
    // else if it doesn't exist, pass in an empty path

    // gui needs our shaders path before everything else
    mResourceSystem->getSceneManager()->setShaderPath(mResDir / "shaders");

    osg::GLExtensions& exts = SceneUtil::getGLExtensions();

#if OSG_VERSION_LESS_THAN(3, 6, 6)
    // hack fix for https://github.com/openscenegraph/OpenSceneGraph/issues/1028
    if (!osg::isGLExtensionSupported(exts.contextID, "NV_framebuffer_multisample_coverage"))
        exts.glRenderbufferStorageMultisampleCoverageNV = nullptr;
#endif

    osg::ref_ptr<osg::Group> guiRoot = new osg::Group;
    guiRoot->setName("GUI Root");
    guiRoot->setNodeMask(MWRender::Mask_GUI);
    mStereoManager->disableStereoForNode(guiRoot);
    rootNode->addChild(guiRoot);

    mWindowManager = std::make_unique<MWGui::WindowManager>(mWindow, mViewer, guiRoot, mResourceSystem.get(),
        mWorkQueue.get(), mCfgMgr.getLogPath(), mScriptConsoleMode, mTranslationDataStorage, mEncoding, mExportFonts,
        Version::getOpenmwVersionDescription(), mCfgMgr);
    mEnvironment.setWindowManager(*mWindowManager);

    mInputManager = std::make_unique<MWInput::InputManager>(mWindow, mViewer, mScreenCaptureHandler, keybinderUser,
        keybinderUserExists, userGameControllerdb, gameControllerdb, mGrab);
    mEnvironment.setInputManager(*mInputManager);

    // Create sound system
    mSoundManager = std::make_unique<MWSound::SoundManager>(mVFS.get(), mUseSound);
    mEnvironment.setSoundManager(*mSoundManager);

    // Create the world
    mWorld = std::make_unique<MWWorld::World>(
        mResourceSystem.get(), mActivationDistanceOverride, mCellName, mCfgMgr.getUserDataPath());
    mEnvironment.setWorld(*mWorld);
    mEnvironment.setWorldModel(mWorld->getWorldModel());
    mEnvironment.setESMStore(mWorld->getStore());

    const MWWorld::Store<ESM::GameSetting>* gmst = &mWorld->getStore().get<ESM::GameSetting>();
    mL10nManager->setGmstLoader([gmst, misses = std::set<std::string, Misc::StringUtils::CiComp>()](
                                    std::string_view gmstName) mutable -> const std::string* {
        const ESM::GameSetting* res = gmst->search(gmstName);
        if (res && res->mValue.getType() == ESM::VT_String)
            return &res->mValue.getString();
        if (misses.emplace(gmstName).second)
            Log(Debug::Error) << "GMST " << gmstName << " not found";
        return nullptr;
    });

    mWindowManager->setStore(mWorld->getStore());

    // Load translation data
    mTranslationDataStorage.setEncoder(mEncoder.get());
    for (auto& mContentFile : mContentFiles)
        mTranslationDataStorage.loadTranslationData(mFileCollections, mContentFile);

    Compiler::registerExtensions(mExtensions);

    // Create script system
    mScriptContext = std::make_unique<MWScript::CompilerContext>(MWScript::CompilerContext::Type_Full);
    mScriptContext->setExtensions(&mExtensions);

    mScriptManager = std::make_unique<MWScript::ScriptManager>(mWorld->getStore(), *mScriptContext, mWarningsMode);
    mEnvironment.setScriptManager(*mScriptManager);

    // Create game mechanics system
    mMechanicsManager = std::make_unique<MWMechanics::MechanicsManager>();
    mEnvironment.setMechanicsManager(*mMechanicsManager);

    // Create dialog system
    mJournal = std::make_unique<MWDialogue::Journal>();
    mEnvironment.setJournal(*mJournal);

    mDialogueManager = std::make_unique<MWDialogue::DialogueManager>(mExtensions, mTranslationDataStorage);
    mEnvironment.setDialogueManager(*mDialogueManager);

    mLuaManager->loadPermanentStorage(mCfgMgr.getUserConfigPath());
    mLuaManager->initPreLoad();

    Loading::Listener* listener = MWBase::Environment::get().getWindowManager()->getLoadingScreen();
    Loading::AsyncListener asyncListener(*listener);
    auto dataLoading = std::async(std::launch::async,
        [&] { mWorld->loadData(mFileCollections, mContentFiles, mGroundcoverFiles, mEncoder.get(), &asyncListener); });

    if (!mSkipMenu)
    {
        std::string_view logo = Fallback::Map::getString("Movies_Company_Logo");
        if (!logo.empty())
            mWindowManager->playVideo(logo, true);
    }

    listener->loadingOn();
    {
        using namespace std::chrono_literals;
        while (dataLoading.wait_for(50ms) != std::future_status::ready)
            asyncListener.update();
        dataLoading.get();
    }
    listener->loadingOff();

    mWorld->init(mMaxRecastLogLevel, mViewer, std::move(rootNode), mWorkQueue.get(), *mUnrefQueue);
    mEnvironment.setWorldScene(mWorld->getWorldScene());
    mWorld->setupPlayer();
    mWorld->setRandomSeed(mRandomSeed);
    mWindowManager->initUI();
    mLuaManager->initPostLoad();

    // scripts
    if (mCompileAll)
    {
        std::pair<int, int> result = mScriptManager->compileAll();
        if (result.first)
            Log(Debug::Info) << "compiled " << result.second << " of " << result.first << " scripts ("
                             << 100 * static_cast<double>(result.second) / result.first << "%)";
    }
    if (mCompileAllDialogue)
    {
        std::pair<int, int> result = MWDialogue::ScriptTest::compileAll(&mExtensions, mWarningsMode);
        if (result.first)
            Log(Debug::Info) << "compiled " << result.second << " of " << result.first << " dialogue scripts ("
                             << 100 * static_cast<double>(result.second) / result.first << "%)";
    }

    // starts a separate lua thread if "lua num threads" > 0
    mLuaWorker = std::make_unique<MWLua::Worker>(*mLuaManager);
}

// Initialise and enter main loop.
void OMW::Engine::go()
{
    assert(!mContentFiles.empty());

    Log(Debug::Info) << "OSG version: " << osgGetVersion();
    SDL_version sdlVersion;
    SDL_GetVersion(&sdlVersion);
    Log(Debug::Info) << "SDL version: " << (int)sdlVersion.major << "." << (int)sdlVersion.minor << "."
                     << (int)sdlVersion.patch;

    Misc::Rng::init(mRandomSeed);

    Settings::ShaderManager::get().load(mCfgMgr.getUserConfigPath() / "shaders.yaml");

    MWClass::registerClasses();

    // Create encoder
    mEncoder = std::make_unique<ToUTF8::Utf8Encoder>(mEncoding);

    // Setup viewer
    mViewer = new osgViewer::Viewer;
    mViewer->setReleaseContextAtEndOfFrameHint(false);

    // Do not try to outsmart the OS thread scheduler (see bug #4785).
    mViewer->setUseConfigureAffinity(false);

    mEnvironment.setFrameRateLimit(Settings::video().mFramerateLimit);

    prepareEngine();

#ifdef _WIN32
    const auto* statsFile = _wgetenv(L"OPENMW_OSG_STATS_FILE");
#else
    const auto* statsFile = std::getenv("OPENMW_OSG_STATS_FILE");
#endif

    std::filesystem::path path;
    if (statsFile != nullptr)
        path = statsFile;

    std::ofstream stats;
    if (!path.empty())
    {
        stats.open(path, std::ios_base::out);
        if (stats.is_open())
            Log(Debug::Info) << "OSG stats will be written to: " << path;
        else
            Log(Debug::Warning) << "Failed to open file to write OSG stats \"" << path
                                << "\": " << std::generic_category().message(errno);
    }

    // Setup profiler
    osg::ref_ptr<Resource::Profiler> statsHandler = new Resource::Profiler(stats.is_open(), *mVFS);

    initStatsHandler(*statsHandler);

    mViewer->addEventHandler(statsHandler);

    if (tspV20ShowFpsEnabled())
    {
        mViewer->getEventQueue()->keyPress(
            osgGA::GUIEventAdapter::KEY_F3);
        mViewer->getEventQueue()->keyRelease(
            osgGA::GUIEventAdapter::KEY_F3);

        Log(Debug::Info)
            << "TSP_OPTIONAL_FPS_OVERLAY_051_V20 enabled=1";
    }


    osg::ref_ptr<Resource::StatsHandler> resourcesHandler = new Resource::StatsHandler(stats.is_open(), *mVFS);
    mViewer->addEventHandler(resourcesHandler);

    if (stats.is_open())
        Resource::collectStatistics(*mViewer);

    // Start the game
    if (!mSaveGameFile.empty())
    {
        mStateManager->loadGame(mSaveGameFile);
    }
    else if (!mSkipMenu)
    {
        // start in main menu
        mWindowManager->pushGuiMode(MWGui::GM_MainMenu);

        if (mVFS->exists(MWSound::titleMusic))
            mSoundManager->streamMusic(MWSound::titleMusic, MWSound::MusicType::Normal);
        else
            Log(Debug::Warning) << "Title music not found";

        std::string_view logo = Fallback::Map::getString("Movies_Morrowind_Logo");
        if (!logo.empty())
            mWindowManager->playVideo(logo, /*allowSkipping*/ true, /*overrideSounds*/ false);
    }
    else
    {
        mStateManager->newGame(!mNewGame);
    }

    if (!mStartupScript.empty() && mStateManager->getState() == MWState::StateManager::State_Running)
    {
        mWindowManager->executeInConsole(mStartupScript);
    }

    // Start the main rendering loop
    MWWorld::DateTimeManager& timeManager = *mWorld->getTimeManager();
    Misc::FrameRateLimiter frameRateLimiter = Misc::makeFrameRateLimiter(mEnvironment.getFrameRateLimit());
    const std::chrono::steady_clock::duration maxSimulationInterval(std::chrono::milliseconds(200));
    while (!mViewer->done() && !mStateManager->hasQuitRequest())
    {
        const double dt = std::chrono::duration_cast<std::chrono::duration<double>>(
                              std::min(frameRateLimiter.getLastFrameDuration(), maxSimulationInterval))
                              .count()
            * timeManager.getSimulationTimeScale();

        mViewer->advance(timeManager.getRenderingSimulationTime());

        const unsigned frameNumber = mViewer->getFrameStamp()->getFrameNumber();

        if (!frame(frameNumber, static_cast<float>(dt)))
        {
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
            continue;
        }
        timeManager.updateIsPaused();
        if (!timeManager.isPaused())
        {
            timeManager.setSimulationTime(timeManager.getSimulationTime() + dt);
            timeManager.setRenderingSimulationTime(timeManager.getRenderingSimulationTime() + dt);
        }

        if (stats)
        {
            // The delay is required because rendering happens in parallel to the main thread and stats from there is
            // available with delay.
            constexpr unsigned statsReportDelay = 3;
            if (frameNumber >= statsReportDelay)
            {
                // Viewer frame number can be different from frameNumber because of loading screens which render new
                // frames inside a simulation frame.
                const unsigned currentFrameNumber = mViewer->getFrameStamp()->getFrameNumber();
                for (unsigned i = frameNumber; i <= currentFrameNumber; ++i)
                    reportStats(i - statsReportDelay, *mViewer, stats);
            }
        }

        frameRateLimiter.limit();
    }

    mLuaWorker->join();

    // Save user settings
    Settings::Manager::saveUser(mCfgMgr.getUserConfigPath() / "settings.cfg");
    Settings::ShaderManager::get().save();
    mLuaManager->savePermanentStorage(mCfgMgr.getUserConfigPath());
}

void OMW::Engine::setCompileAll(bool all)
{
    mCompileAll = all;
}

void OMW::Engine::setCompileAllDialogue(bool all)
{
    mCompileAllDialogue = all;
}

void OMW::Engine::setSoundUsage(bool soundUsage)
{
    mUseSound = soundUsage;
}

void OMW::Engine::setEncoding(const ToUTF8::FromType& encoding)
{
    mEncoding = encoding;
}

void OMW::Engine::setScriptConsoleMode(bool enabled)
{
    mScriptConsoleMode = enabled;
}

void OMW::Engine::setStartupScript(const std::filesystem::path& path)
{
    mStartupScript = path;
}

void OMW::Engine::setActivationDistanceOverride(int distance)
{
    mActivationDistanceOverride = distance;
}

void OMW::Engine::setWarningsMode(int mode)
{
    mWarningsMode = mode;
}

void OMW::Engine::enableFontExport(bool exportFonts)
{
    mExportFonts = exportFonts;
}

void OMW::Engine::setSaveGameFile(const std::filesystem::path& savegame)
{
    mSaveGameFile = savegame;
}

void OMW::Engine::setRandomSeed(unsigned int seed)
{
    mRandomSeed = seed;
}
