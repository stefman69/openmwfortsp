#include <cstdio>
#include <malloc.h>
#include <fstream>
#include <string>
#include <cstdlib>
#include <components/resource/resourcesystem.hpp>
#include "statemanagerimp.hpp"
#include <array>
#include <cctype>
#include <chrono>
#include <cstdint>
#include <map>
#include <utility>

#include <filesystem>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

#if defined(__linux__)
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#if defined(__GLIBC__)
#include <malloc.h>
#endif
#endif

#include <SDL_clipboard.h>

#include <components/debug/debuglog.hpp>

#include <components/esm3/actoridconverter.hpp>
#include <components/esm3/esmreader.hpp>
#include <components/esm3/esmwriter.hpp>
#include <components/esm3/loadcell.hpp>
#include <components/esm3/loadclas.hpp>

#include <components/l10n/manager.hpp>

#include <components/loadinglistener/loadinglistener.hpp>

#include <components/files/conversion.hpp>
#include <components/misc/algorithm.hpp>
#include <components/settings/values.hpp>

#include <osg/Image>

#include <osgDB/Registry>

#include "../mwbase/dialoguemanager.hpp"
#include "../mwbase/environment.hpp"
#include "../mwbase/inputmanager.hpp"
#include "../mwbase/journal.hpp"
#include "../mwbase/luamanager.hpp"
#include "../mwbase/mechanicsmanager.hpp"
#include "../mwbase/scriptmanager.hpp"
#include "../mwbase/soundmanager.hpp"
#include "../mwbase/windowmanager.hpp"
#include "../mwbase/world.hpp"

#include "../mwworld/cellstore.hpp"
#include "../mwworld/class.hpp"
#include "../mwworld/datetimemanager.hpp"
#include "../mwworld/esmstore.hpp"
#include "../mwworld/globals.hpp"
#include "../mwworld/scene.hpp"
#include "../mwworld/worldmodel.hpp"

#include "../mwmechanics/actorutil.hpp"
#include "../mwmechanics/npcstats.hpp"

#include "../mwscript/globalscripts.hpp"

#include "quicksavemanager.hpp"

/* TSP_LOAD_FREEZE: defined at global scope in engine.cpp */
void tspArmLoadFreeze();

// TSP_FRESH_PROCESS_LOAD_051_V12
// On this low-memory GL4ES handheld, loading a new save into an already-live
// OpenMW process has repeatedly produced low-address SIGSEGVs. For an in-game
// load, quickload, or death reload, replace the process image before reading
// the next save. The startup load sees State_NoGame and proceeds normally.
namespace
{
    bool tspFreshProcessLoadsEnabled()
    {
        const char* value = std::getenv("OPENMW_TSP_FRESH_LOADS");
        return value == nullptr || std::strcmp(value, "0") != 0;
    }




#if defined(__linux__)
    void tspMarkNonStdioDescriptorsCloseOnExec()
    {
        DIR* directory = ::opendir("/proc/self/fd");
        if (directory == nullptr)
            return;

        const int directoryFd = ::dirfd(directory);
        while (dirent* entry = ::readdir(directory))
        {
            char* end = nullptr;
            errno = 0;
            const long parsed = std::strtol(entry->d_name, &end, 10);
            if (errno != 0 || end == entry->d_name || *end != '\0')
                continue;
            if (parsed < 3 || parsed == directoryFd)
                continue;

            const int fd = static_cast<int>(parsed);
            const int flags = ::fcntl(fd, F_GETFD);
            if (flags >= 0)
                ::fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
        }

        ::closedir(directory);
    }

    void tspRestartForSaveLoad(const std::filesystem::path& filepath)
    {
        std::ifstream commandLine("/proc/self/cmdline", std::ios::binary);
        if (!commandLine)
            throw std::runtime_error("TSP FRESHLOAD: unable to read /proc/self/cmdline");

        std::vector<std::string> oldArgs;
        std::string arg;
        while (std::getline(commandLine, arg, '\0'))
        {
            if (!arg.empty())
                oldArgs.push_back(arg);
        }

        if (oldArgs.empty())
            throw std::runtime_error("TSP FRESHLOAD: current command line is empty");

        std::vector<std::string> newArgs;
        newArgs.reserve(oldArgs.size() + 2);
        newArgs.push_back(oldArgs.front());

        for (std::size_t i = 1; i < oldArgs.size(); ++i)
        {
            const std::string& current = oldArgs[i];

            if (current == "--load-savegame")
            {
                if (i + 1 < oldArgs.size())
                    ++i;
                continue;
            }
            if (current.rfind("--load-savegame=", 0) == 0)
                continue;

            if (current == "--skip-menu")
            {
                if (i + 1 < oldArgs.size()
                    && (oldArgs[i + 1] == "0" || oldArgs[i + 1] == "1"
                        || oldArgs[i + 1] == "true" || oldArgs[i + 1] == "false"))
                    ++i;
                continue;
            }
            if (current.rfind("--skip-menu=", 0) == 0)
                continue;

            // A stale startup-new-game flag must not survive into a save load.
            if (current == "--new-game")
            {
                if (i + 1 < oldArgs.size()
                    && (oldArgs[i + 1] == "0" || oldArgs[i + 1] == "1"
                        || oldArgs[i + 1] == "true" || oldArgs[i + 1] == "false"))
                    ++i;
                continue;
            }
            if (current.rfind("--new-game=", 0) == 0)
                continue;

            newArgs.push_back(current);
        }

        const std::filesystem::path absoluteSave
            = std::filesystem::absolute(filepath).lexically_normal();
        newArgs.emplace_back("--load-savegame=" + absoluteSave.string());
        newArgs.emplace_back("--skip-menu=1");

        Log(Debug::Info)
            << "TSP_FRESH_PROCESS_LOAD_051_V12 "
            << "TSP FRESHLOAD restarting process for save: "
            << absoluteSave;

        // Keep the launcher's stdout/stderr log, but prevent old EGL, DRM,
        // ALSA/OpenAL and other library descriptors from crossing exec().
        tspMarkNonStdioDescriptorsCloseOnExec();

        std::cout.flush();
        std::cerr.flush();

        std::vector<char*> argv;
        argv.reserve(newArgs.size() + 1);
        for (std::string& value : newArgs)
            argv.push_back(value.data());
        argv.push_back(nullptr);

        ::execv("/proc/self/exe", argv.data());

        const int error = errno;
        throw std::runtime_error(
            "TSP FRESHLOAD: execv(/proc/self/exe) failed: "
            + std::string(std::strerror(error)));
    }
#endif
}

// TSP_SAFE_RELOAD_CONFIG_051_V13
// Normal/default behaviour: keep the process and already-parsed ESM/ESP content
// alive and perform an in-process load. If [TSP] safe reload = 1 is present in
// settings.cfg, use the proven V12 exec-based load as an opt-in fallback.
namespace
{
    struct TspSafeReloadSetting
    {
        // TSP_FRESH_DEFAULT_051_V15
        // TSP_FRESH_DEFAULT_OFF_V16
        // Default flipped to false. When true, every save load takes the V12
        // exec-based "fresh" path, which re-execs the process and re-parses all
        // ESM/OMW content - the multi-second reload on every load. The in-process
        // warm load is now the default; "[TSP] safe reload = 1" in settings.cfg
        // still opts back into the exec path explicitly.
        bool enabled = false;
        bool found = false;
        std::filesystem::path path;
        std::string source = "default";
    };

    std::string tspTrim(std::string value)
    {
        auto isSpace = [](unsigned char c) { return std::isspace(c) != 0; };
        while (!value.empty() && isSpace(static_cast<unsigned char>(value.front())))
            value.erase(value.begin());
        while (!value.empty() && isSpace(static_cast<unsigned char>(value.back())))
            value.pop_back();
        return value;
    }

    std::string tspLower(std::string value)
    {
        for (char& c : value)
            c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        return value;
    }

    bool tspBoolValue(std::string value)
    {
        value = tspLower(tspTrim(std::move(value)));
        return value == "1" || value == "true" || value == "yes" || value == "on";
    }

    TspSafeReloadSetting tspReadSafeReloadSetting()
    {
        TspSafeReloadSetting result;

        // Optional emergency override, mainly useful over SSH. settings.cfg is
        // the normal control requested for this port.
        if (const char* overrideValue = std::getenv("OPENMW_TSP_SAFE_RELOAD"))
        {
            result.enabled = tspBoolValue(overrideValue);
            result.found = true;
            result.source = "environment";
            return result;
        }

        if (const char* explicitPath = std::getenv("OPENMW_TSP_SETTINGS_FILE"))
            result.path = explicitPath;
        else if (const char* xdg = std::getenv("XDG_CONFIG_HOME"))
            result.path = std::filesystem::path(xdg) / "settings.cfg";
        else
            result.path = "settings.cfg";

        std::ifstream input(result.path);
        if (!input)
            return result;

        bool inTspSection = false;
        std::string line;
        while (std::getline(input, line))
        {
            if (!line.empty() && line.back() == '\r')
                line.pop_back();

            const std::size_t comment = line.find_first_of("#;");
            if (comment != std::string::npos)
                line.erase(comment);
            line = tspTrim(std::move(line));
            if (line.empty())
                continue;

            if (line.front() == '[' && line.back() == ']')
            {
                inTspSection = tspLower(tspTrim(line.substr(1, line.size() - 2))) == "tsp";
                continue;
            }
            if (!inTspSection)
                continue;

            const std::size_t eq = line.find('=');
            if (eq == std::string::npos)
                continue;
            const std::string key = tspLower(tspTrim(line.substr(0, eq)));
            if (key != "safe reload")
                continue;

            result.enabled = tspBoolValue(line.substr(eq + 1));
            result.found = true;
            result.source = "settings.cfg";
            return result;
        }
        return result;
    }

    std::uint64_t gTspLoadGeneration = 0;
    bool gTspLoadTraceActive = false;
    bool gTspLoadWatchActive = false;
    std::chrono::steady_clock::time_point gTspLoadWatchStart;
    std::size_t gTspLoadWatchIndex = 0;
    constexpr std::array<long long, 8> gTspLoadWatchMs{ 250, 500, 1000, 2000, 3000, 5000, 10000, 20000 };

    /* TSP_PHASEMEM_V1: deliberately a duplicate of tspMallocInuseKb rather than
       a forward declaration - that one is a file-scope static defined further
       down, and declaring it inside this anonymous namespace would name a
       different function and fail to link. Twelve duplicated lines of diagnostic
       code is the cheaper mistake. */
    long long tspPhaseInuseKb()
    {
#if defined(__GLIBC__)
#if defined(__GLIBC_PREREQ)
#if __GLIBC_PREREQ(2, 33)
        struct mallinfo2 tspMi = mallinfo2();
        return static_cast<long long>(tspMi.uordblks / 1024);
#else
        struct mallinfo tspMi = mallinfo();
        return static_cast<long long>(tspMi.uordblks) / 1024;
#endif
#else
        struct mallinfo tspMi = mallinfo();
        return static_cast<long long>(tspMi.uordblks) / 1024;
#endif
#else
        return -1;
#endif
    }

    void tspLoadPhase(const char* phase)
    {
        if (!gTspLoadTraceActive)
            return;
        Log(Debug::Info) << "TSP_LOAD_TRACE_051_V13 generation=" << gTspLoadGeneration
                         << " phase=" << phase
                         << " inuse_kb=" << tspPhaseInuseKb();
    }

    void tspBeginLoadTrace(const std::filesystem::path& filepath, bool activeReload, bool safeReload)
    {
        ++gTspLoadGeneration;
        gTspLoadTraceActive = true;
        gTspLoadWatchActive = false;
        gTspLoadWatchIndex = 0;
        Log(Debug::Info) << "TSP_LOAD_TRACE_051_V13 generation=" << gTspLoadGeneration
                         << " phase=begin active_reload=" << (activeReload ? 1 : 0)
                         << " safe_reload=" << (safeReload ? 1 : 0)
                         << " save=" << filepath.filename();
    }

    void tspFinishLoadTrace()
    {
        tspLoadPhase("complete");
        /* TSP_LOAD_FREEZE: arm the post-load simulation freeze so the shader
           warm draws burn off while the player stands still. */
        tspArmLoadFreeze();
        gTspLoadTraceActive = false;
        gTspLoadWatchStart = std::chrono::steady_clock::now();
        gTspLoadWatchIndex = 0;
        gTspLoadWatchActive = true;
    }

    void tspUpdateLoadWatch()
    {
        if (!gTspLoadWatchActive || gTspLoadWatchIndex >= gTspLoadWatchMs.size())
            return;
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - gTspLoadWatchStart).count();
        while (gTspLoadWatchIndex < gTspLoadWatchMs.size()
            && elapsed >= gTspLoadWatchMs[gTspLoadWatchIndex])
        {
            Log(Debug::Info) << "TSP_LOAD_WATCH_051_V13 generation=" << gTspLoadGeneration
                             << " survived_ms=" << gTspLoadWatchMs[gTspLoadWatchIndex];
            ++gTspLoadWatchIndex;
        }
        if (gTspLoadWatchIndex >= gTspLoadWatchMs.size())
            gTspLoadWatchActive = false;
    }
}

void MWState::StateManager::cleanup(bool force)
{
    if (mState != State_NoGame || force)
    {
        tspLoadPhase("cleanup-sound");
            MWBase::Environment::get().getSoundManager()->clear();
        tspLoadPhase("cleanup-dialogue");
            MWBase::Environment::get().getDialogueManager()->clear();
        tspLoadPhase("cleanup-journal");
            MWBase::Environment::get().getJournal()->clear();
        tspLoadPhase("cleanup-scripts");
            MWBase::Environment::get().getScriptManager()->clear();
        tspLoadPhase("cleanup-window");
            MWBase::Environment::get().getWindowManager()->clear();
        tspLoadPhase("cleanup-world");
            MWBase::Environment::get().getWorld()->clear();
        tspLoadPhase("cleanup-input");
            MWBase::Environment::get().getInputManager()->clear();
        tspLoadPhase("cleanup-mechanics");
            MWBase::Environment::get().getMechanicsManager()->clear();

        /* TSP_LOADPURGE_V1: everything above unreferences the old world, but the
           resource caches are never told to drop what it held. Measured over ~30
           quickloads of one save in one cell: Image +332, SceneNode +320,
           malloc_inuse 278 -> 531 MB, swap 0 -> 429 MB, and the game ends up at
           1-2 fps thrashing. The exec-based "safe reload" path (TSP_FRESH_*)
           solved this by replacing the process, at the cost of re-parsing every
           ESM/ESP on every load. This reclaims the same memory while keeping the
           parsed content and the fast in-process load. Called here, after the
           world clear, so the entries are genuinely unreferenced and the free
           actually happens. ResourceSystem::clearCache() logs its own
           TSP_MEMORY_CLEAR_TRACE_051_V10 sizes. TSP_NO_LOADPURGE=1 disables. */
        if (std::getenv("TSP_NO_LOADPURGE") == nullptr)
        {
            tspLoadPhase("cleanup-resourcecache");
            /* TSP_LOADPURGE_V2: clearCache alone provably does not return memory.
               Measured with V1 firing on all 14 loads: the caches DO collapse
               (SceneNode 412->127, Image 481->181) yet at that same moment
               malloc_inuse was 461 MB, up 181 MB from session start. Cache entry
               count is not where the memory lives.

               clearCache drops the cache's reference to an osg::Texture; it never
               releases the GL object, so gl4es's CPU-side texture copies - and the
               launcher exports OPENMW_DECOMPRESS_TEXTURES=1, so they are the large
               uncompressed kind - are never freed. releaseGLObjects(nullptr) queues
               the deletes onto OSG's orphan lists, which drain in Renderer::draw.
               Deferred, which is exactly why the old TSP_CELL_GLRELEASE
               avail_before/avail_after numbers looked like nothing: an
               instantaneous delta cannot see a deferred free. */
            /* TSP_MEMGATE_V1: order was wrong in V2. releaseGLObjects fans out to
               mCache->releaseGLObjects() per manager - it iterates the very maps
               clearCache() had just emptied, so it walked nothing. Release first,
               then clear. */
            MWBase::Environment::get().getResourceSystem()->releaseGLObjects(nullptr);
            MWBase::Environment::get().getResourceSystem()->clearCache();
            Log(Debug::Info) << "TSP_LOADPURGE_V2 caches cleared + GL objects released";
        }

        mCharacterManager.setCurrentCharacter(nullptr);
        mTimePlayed = 0;
        mLastSavegame.clear();

        mState = State_NoGame;
        MWBase::Environment::get().getLuaManager()->noGame();
    }
    else
    {
        // TODO: do we need this cleanup?
        MWBase::Environment::get().getLuaManager()->clear();
    }
}

std::map<int, int> MWState::StateManager::buildContentFileIndexMap(const ESM::ESMReader& reader) const
{
    const std::vector<std::string>& current = MWBase::Environment::get().getWorld()->getContentFiles();

    const std::vector<ESM::Header::MasterData>& prev = reader.getGameFiles();

    std::map<int, int> map;

    for (int iPrev = 0; iPrev < static_cast<int>(prev.size()); ++iPrev)
    {
        for (int iCurrent = 0; iCurrent < static_cast<int>(current.size()); ++iCurrent)
            if (Misc::StringUtils::ciEqual(prev[iPrev].name, current[iCurrent]))
            {
                map.insert(std::make_pair(iPrev, iCurrent));
                break;
            }
    }

    return map;
}

MWState::StateManager::StateManager(const std::filesystem::path& saves, const std::vector<std::string>& contentFiles)
    : mQuitRequest(false)
    , mAskLoadRecent(false)
    , mState(State_NoGame)
    , mCharacterManager(saves, contentFiles)
    , mTimePlayed(0)
{
}

void MWState::StateManager::requestQuit()
{
    mQuitRequest = true;
}

bool MWState::StateManager::hasQuitRequest() const
{
    return mQuitRequest;
}

void MWState::StateManager::askLoadRecent()
{
    if (MWBase::Environment::get().getWindowManager()->getMode() == MWGui::GM_MainMenu)
        return;

    if (!mAskLoadRecent)
    {
        if (mLastSavegame.empty()) // no saves
        {
            MWBase::Environment::get().getWindowManager()->pushGuiMode(MWGui::GM_MainMenu);
        }
        else
        {
            std::string saveName = Files::pathToUnicodeString(mLastSavegame.filename());
            // Assume the last saved game belongs to the current character's slot list.
            const Character* character = getCurrentCharacter();
            if (character)
            {
                for (const auto& slot : *character)
                {
                    if (slot.mPath == mLastSavegame)
                    {
                        saveName = slot.mProfile.mDescription;
                        break;
                    }
                }
            }

            std::vector<std::string> buttons;
            buttons.emplace_back("#{Interface:Yes}");
            buttons.emplace_back("#{Interface:No}");
            auto l10n = MWBase::Environment::get().getL10nManager()->getContext("OMWEngine");
            std::string message = l10n->formatMessage("AskLoadLastSave", { "save" }, { L10n::toUnicode(saveName) });
            MWBase::Environment::get().getWindowManager()->interactiveMessageBox(message, buttons);
            mAskLoadRecent = true;
        }
    }
}

MWState::StateManager::State MWState::StateManager::getState() const
{
    return mState;
}

void MWState::StateManager::newGame(bool bypass)
{
    cleanup();

    if (!bypass)
        MWBase::Environment::get().getWindowManager()->setNewGame(true);

    try
    {
        Log(Debug::Info) << "Starting a new game";
        MWBase::Environment::get().getScriptManager()->getGlobalScripts().addStartup();
        MWBase::Environment::get().getWorld()->startNewGame(bypass);

        mState = State_Running;
        MWBase::Environment::get().getLuaManager()->gameLoaded();

        MWBase::Environment::get().getWindowManager()->fadeScreenOut(0);
        MWBase::Environment::get().getWindowManager()->fadeScreenIn(1);
    }
    catch (std::exception& e)
    {
        std::stringstream error;
        error << "Failed to start new game: " << e.what();

        Log(Debug::Error) << error.str();
        cleanup(true);

        MWBase::Environment::get().getWindowManager()->pushGuiMode(MWGui::GM_MainMenu);

        std::vector<std::string> buttons;
        buttons.emplace_back("#{Interface:OK}");
        MWBase::Environment::get().getWindowManager()->interactiveMessageBox(error.str(), buttons);
    }
}

void MWState::StateManager::endGame()
{
    mState = State_Ended;
    MWBase::Environment::get().getLuaManager()->gameEnded();
}

void MWState::StateManager::resumeGame()
{
    mState = State_Running;
    MWBase::Environment::get().getLuaManager()->gameLoaded();
}

void MWState::StateManager::saveGame(std::string_view description, const Slot* slot)
{
    MWBase::Environment::get().getLuaManager()->applyDelayedActions();

    MWState::Character* character = getCurrentCharacter();

    try
    {
        const auto start = std::chrono::steady_clock::now();

        MWBase::Environment::get().getWindowManager()->asyncPrepareSaveMap();

        if (!character)
        {
            MWWorld::ConstPtr player = MWMechanics::getPlayer();
            const std::string& name = player.get<ESM::NPC>()->mBase->mName;

            character = mCharacterManager.createCharacter(name);
            mCharacterManager.setCurrentCharacter(character);
        }

        ESM::SavedGame profile;

        MWBase::World& world = *MWBase::Environment::get().getWorld();

        MWWorld::Ptr player = world.getPlayerPtr();

        profile.mContentFiles = world.getContentFiles();

        profile.mPlayerName = player.get<ESM::NPC>()->mBase->mName;
        profile.mPlayerLevel = player.getClass().getNpcStats(player).getLevel();

        const ESM::RefId& classId = player.get<ESM::NPC>()->mBase->mClass;
        if (world.getStore().get<ESM::Class>().isDynamic(classId))
            profile.mPlayerClassName = world.getStore().get<ESM::Class>().find(classId)->mName;
        else
            profile.mPlayerClassId = classId;

        const MWMechanics::CreatureStats& stats = player.getClass().getCreatureStats(player);

        profile.mPlayerCellName = world.getCellName();
        profile.mInGameTime = world.getTimeManager()->getEpochTimeStamp();
        profile.mTimePlayed = mTimePlayed;
        profile.mDescription = description;
        profile.mCurrentDay = world.getTimeManager()->getTimeStamp().getDay();
        profile.mCurrentHealth = stats.getHealth().getCurrent();
        profile.mMaximumHealth = stats.getHealth().getModified();

        Log(Debug::Info) << "Making a screenshot for saved game '" << description << "'";
        writeScreenshot(profile.mScreenshot);

        if (!slot)
            slot = character->createSlot(profile);
        else
            slot = character->updateSlot(slot, profile);

        // Make sure the animation state held by references is up to date before saving the game.
        MWBase::Environment::get().getMechanicsManager()->persistAnimationStates();

        Log(Debug::Info) << "Writing saved game '" << description << "' for character '" << profile.mPlayerName << "'";

        // Write to a memory stream first. If there is an exception during the save process, we don't want to trash the
        // existing save file we are overwriting.
        std::stringstream stream;

        ESM::ESMWriter writer;

        for (const std::string& contentFile : MWBase::Environment::get().getWorld()->getContentFiles())
            writer.addMaster(contentFile, 0); // not using the size information anyway -> use value of 0

        writer.setFormatVersion(ESM::CurrentSaveGameFormatVersion);

        // all unused
        writer.setVersion(0);
        writer.setType(0);
        writer.setAuthor("");
        writer.setDescription("");

        size_t recordCount = 1 // saved game header
            + MWBase::Environment::get().getJournal()->countSavedGameRecords()
            + MWBase::Environment::get().getLuaManager()->countSavedGameRecords()
            + MWBase::Environment::get().getWorld()->countSavedGameRecords()
            + MWBase::Environment::get().getScriptManager()->getGlobalScripts().countSavedGameRecords()
            + MWBase::Environment::get().getDialogueManager()->countSavedGameRecords()
            + MWBase::Environment::get().getMechanicsManager()->countSavedGameRecords()
            + MWBase::Environment::get().getInputManager()->countSavedGameRecords()
            + MWBase::Environment::get().getWindowManager()->countSavedGameRecords();
        writer.setRecordCount(static_cast<int>(recordCount));

        writer.save(stream);

        Loading::Listener& listener = *MWBase::Environment::get().getWindowManager()->getLoadingScreen();
        // Using only Cells for progress information, since they typically have the largest records by far
        listener.setProgressRange(MWBase::Environment::get().getWorld()->countSavedGameCells());
        listener.setLabel("#{OMWEngine:SavingInProgress}", true);

        Loading::ScopedLoad load(&listener);

        writer.startRecord(ESM::REC_SAVE);
        slot->mProfile.save(writer);
        writer.endRecord(ESM::REC_SAVE);

        MWBase::Environment::get().getJournal()->write(writer, listener);
        MWBase::Environment::get().getDialogueManager()->write(writer, listener);
        // LuaManager::write should be called before World::write because world also saves
        // local scripts that depend on LuaManager.
        MWBase::Environment::get().getLuaManager()->write(writer, listener);
        MWBase::Environment::get().getWorld()->write(writer, listener);
        MWBase::Environment::get().getScriptManager()->getGlobalScripts().write(writer, listener);
        MWBase::Environment::get().getMechanicsManager()->write(writer, listener);
        MWBase::Environment::get().getInputManager()->write(writer, listener);
        MWBase::Environment::get().getWindowManager()->write(writer, listener);

        // Ensure we have written the number of records that was estimated
        if (static_cast<size_t>(writer.getRecordCount()) != recordCount + 1) // 1 extra for TES3 record
            Log(Debug::Warning) << "Warning: number of written savegame records does not match. Estimated: "
                                << recordCount + 1 << ", written: " << writer.getRecordCount();

        writer.close();

        if (stream.fail())
            throw std::runtime_error(
                "Write operation failed (memory stream): " + std::generic_category().message(errno));

        // All good, write to file
        std::ofstream filestream(slot->mPath, std::ios::binary);
        filestream << stream.rdbuf();

        if (filestream.fail())
            throw std::runtime_error("Write operation failed (file stream): " + std::generic_category().message(errno));

        Settings::saves().mCharacter.set(Files::pathToUnicodeString(slot->mPath.parent_path().filename()));
        mLastSavegame = slot->mPath;

        const auto finish = std::chrono::steady_clock::now();

        Log(Debug::Info) << '\'' << description << "' is saved in "
                         << std::chrono::duration_cast<std::chrono::duration<float, std::milli>>(finish - start).count()
                         << "ms";
    }
    catch (const std::exception& e)
    {
        std::stringstream error;
        error << "Failed to save game: " << e.what();

        Log(Debug::Error) << error.str();

        std::vector<std::string> buttons;
        buttons.emplace_back("#{Interface:OK}");
        MWBase::Environment::get().getWindowManager()->interactiveMessageBox(error.str(), buttons);

        // If no file was written, clean up the slot
        if (character && slot && !std::filesystem::exists(slot->mPath))
        {
            character->deleteSlot(slot);
            character->cleanup();
        }
    }
}

void MWState::StateManager::quickSave(std::string name)
{
    if (!(mState == State_Running
            && MWBase::Environment::get().getWorld()->getGlobalInt(MWWorld::Globals::sCharGenState) == -1 // char gen
            && MWBase::Environment::get().getWindowManager()->isSavingAllowed()))
    {
        // You can not save your game right now
        MWBase::Environment::get().getWindowManager()->messageBox("#{OMWEngine:SaveGameDenied}");
        return;
    }

    Character* currentCharacter = getCurrentCharacter(); // Get current character
    QuickSaveManager saveFinder(name, Settings::saves().mMaxQuicksaves);

    if (currentCharacter)
    {
        for (auto& save : *currentCharacter)
        {
            // Visiting slots allows the quicksave finder to find the oldest quicksave
            saveFinder.visitSave(&save);
        }
    }

    // Once all the saves have been visited, the save finder can tell us which
    // one to replace (or create)
    saveGame(name, saveFinder.getNextQuickSaveSlot());
}

void MWState::StateManager::loadGame(const std::filesystem::path& filepath)
{
    for (const auto& character : mCharacterManager)
    {
        for (const auto& slot : character)
        {
            if (std::filesystem::equivalent(slot.mPath, filepath))
            {
                loadGame(&character, slot.mPath);
                return;
            }
        }
    }

    MWState::Character* character = getCurrentCharacter();
    loadGame(character, filepath);
}

struct SaveFormatVersionError : public std::exception
{
    using std::exception::exception;

    SaveFormatVersionError(ESM::FormatVersion savegameFormat, const std::string& message)
        : mSavegameFormat(savegameFormat)
        , mErrorMessage(message)
    {
    }

    const char* what() const noexcept override { return mErrorMessage.c_str(); }
    ESM::FormatVersion getFormatVersion() const { return mSavegameFormat; }

protected:
    ESM::FormatVersion mSavegameFormat = ESM::DefaultFormatVersion;
    std::string mErrorMessage;
};

struct SaveVersionTooOldError : SaveFormatVersionError
{
    SaveVersionTooOldError(ESM::FormatVersion savegameFormat)
        : SaveFormatVersionError(savegameFormat, "format version " + std::to_string(savegameFormat) + " is too old")
    {
    }
};

struct SaveVersionTooNewError : SaveFormatVersionError
{
    SaveVersionTooNewError(ESM::FormatVersion savegameFormat)
        : SaveFormatVersionError(savegameFormat, "format version " + std::to_string(savegameFormat) + " is too new")
    {
    }
};

/* TSP_MEMGATE_V1: 37 purges with the caches pinned at their floor still ended at
   malloc_inuse 574 MB and 392 MB of swap, so the growth is not in the resource
   caches and may not be findable quickly. tspRestartForSaveLoad DOES reset it
   completely - it re-execs - but paying a full ESM re-parse on every load is the
   cost that got it switched off. So take it only when memory is actually low:
   fast warm loads normally, one slow clean restart when approaching the wall. */
static long long tspMemAvailableKb()
{
    std::ifstream tspMeminfo("/proc/meminfo");
    std::string tspKey;
    long long tspValue = 0;
    std::string tspUnit;
    while (tspMeminfo >> tspKey >> tspValue >> tspUnit)
    {
        if (tspKey == "MemAvailable:")
            return tspValue;
    }
    return -1;
}

static bool tspReloadMemLow(long long& outAvail, long long& outFloor)
{
    const char* tspEnv = std::getenv("TSP_RELOAD_MEM_FLOOR_KB");
    long long tspFloor = 204800;
    if (tspEnv != nullptr && tspEnv[0] != '\0')
    {
        const long long tspParsed = std::atoll(tspEnv);
        if (tspParsed > 0)
            tspFloor = tspParsed;
    }
    outFloor = tspFloor;
    outAvail = tspMemAvailableKb();
    return (outAvail > 0 && outAvail < tspFloor);
}

/* TSP_LOADMEM_V1: door transitions plateau (inuse flat, free rising to 95 MB)
   while quickloads climb 265->460 MB monotonically, so the leak lives in the
   save-load path. These two points bracket the teardown: growth ACROSS cleanup
   means teardown is incomplete; growth BETWEEN one load's after-cleanup and the
   next load's before-cleanup is what loadGame itself retains. */
static long long tspMallocInuseKb()
{
#if defined(__GLIBC__)
#if defined(__GLIBC_PREREQ)
#if __GLIBC_PREREQ(2, 33)
    struct mallinfo2 tspMi = mallinfo2();
    return static_cast<long long>(tspMi.uordblks / 1024);
#else
    struct mallinfo tspMi = mallinfo();
    return static_cast<long long>(tspMi.uordblks) / 1024;
#endif
#else
    struct mallinfo tspMi = mallinfo();
    return static_cast<long long>(tspMi.uordblks) / 1024;
#endif
#else
    return -1;
#endif
}


/* TSP_HEAPTRIM_V1: resident-set reader that needs no allocator helper, so this
   block does not depend on anything else in this file staying where it is. */
namespace
{
    long tspHeapTrimRssKb()
    {
        long rssPages = 0;
        FILE* f = std::fopen("/proc/self/statm", "r");
        if (f == nullptr)
            return -1;
        long totalPages = 0;
        const int got = std::fscanf(f, "%ld %ld", &totalPages, &rssPages);
        std::fclose(f);
        if (got != 2)
            return -1;
        return rssPages * (static_cast<long>(::sysconf(_SC_PAGESIZE)) / 1024);
    }
}

void MWState::StateManager::loadGame(const Character* character, const std::filesystem::path& filepath)
{
    try
    {
        const bool tspActiveReload = (mState != State_NoGame);
        TspSafeReloadSetting tspSafeReload;
#if defined(__linux__)
        if (tspActiveReload)
        {
            tspSafeReload = tspReadSafeReloadSetting();
            Log(Debug::Info) << "TSP_SAFE_RELOAD_CONFIG_051_V13"
                             << " enabled=" << (tspSafeReload.enabled ? 1 : 0)
                             << " found=" << (tspSafeReload.found ? 1 : 0)
                             << " source=" << tspSafeReload.source
                             << " path=" << tspSafeReload.path;
            Log(Debug::Info) << "TSP_FRESH_DEFAULT_051_V15"
                             << " effective_fresh=" << (tspSafeReload.enabled ? 1 : 0)
                             << " explicit=" << (tspSafeReload.found ? 1 : 0)
                             << " source=" << tspSafeReload.source;
            long long tspAvailKb = 0;
            long long tspFloorKb = 0;
            const bool tspMemLow = tspReloadMemLow(tspAvailKb, tspFloorKb);
            Log(Debug::Info) << "TSP_MEMGATE_V1 memavail_kb=" << tspAvailKb
                             << " floor_kb=" << tspFloorKb
                             << " action=" << ((tspSafeReload.enabled || tspMemLow) ? "fresh" : "warm");
            if (tspSafeReload.enabled || tspMemLow)
            {
                Log(Debug::Info) << "TSP_SAFE_RELOAD_051_V13 action=fresh save=" << filepath.filename();
                tspRestartForSaveLoad(filepath);
            }
            Log(Debug::Info) << "TSP_SAFE_RELOAD_051_V13 action=warm save=" << filepath.filename();
        }
#endif
        tspBeginLoadTrace(filepath, tspActiveReload, tspSafeReload.enabled);
        tspLoadPhase("cleanup-begin");
        const long long tspInuseBefore = tspMallocInuseKb();
        cleanup();
        const long long tspInuseAfter = tspMallocInuseKb();
        Log(Debug::Info) << "TSP_LOADMEM_V1 before_kb=" << tspInuseBefore
                         << " after_kb=" << tspInuseAfter
                         << " freed_kb=" << (tspInuseBefore - tspInuseAfter);
        tspLoadPhase("cleanup-done");

        Log(Debug::Info) << "Reading save file " << filepath.filename();

        ESM::ESMReader reader;
        reader.open(filepath);
        tspLoadPhase("reader-open");
        {
            std::size_t tspIndex = 0;
            for (const std::string& tspContent : MWBase::Environment::get().getWorld()->getContentFiles())
                Log(Debug::Info) << "TSP_LOAD_CONTENT_051_V13 source=current index=" << tspIndex++
                                 << " name=" << tspContent;
            tspIndex = 0;
            for (const auto& tspMaster : reader.getGameFiles())
                Log(Debug::Info) << "TSP_LOAD_CONTENT_051_V13 source=save-master index=" << tspIndex++
                                 << " name=" << tspMaster.name;
        }

        ESM::FormatVersion version = reader.getFormatVersion();
        if (version > ESM::CurrentSaveGameFormatVersion)
            throw SaveVersionTooNewError(version);
        else if (version < ESM::MinSupportedSaveGameFormatVersion)
            throw SaveVersionTooOldError(version);

        std::map<int, int> contentFileMap = buildContentFileIndexMap(reader);
        for (const auto& tspMapping : contentFileMap)
            Log(Debug::Info) << "TSP_LOAD_CONTENT_051_V13 source=content-map save_index=" << tspMapping.first
                             << " current_index=" << tspMapping.second;
        tspLoadPhase("content-map-ready");
        reader.setContentFileMapping(&contentFileMap);
        MWBase::Environment::get().getLuaManager()->setContentFileMapping(contentFileMap);

        ESM::ActorIdConverter actorIdConverter;
        if (version <= ESM::MaxActorIdSaveGameFormatVersion)
            reader.mActorIdConverter = &actorIdConverter;

        Loading::Listener& listener = *MWBase::Environment::get().getWindowManager()->getLoadingScreen();

        listener.setProgressRange(100);
        listener.setLabel("#{OMWEngine:LoadingInProgress}");

        Loading::ScopedLoad load(&listener);

        bool firstPersonCam = false;

        size_t total = reader.getFileSize();
        int currentPercent = 0;
        std::map<std::string, std::size_t> tspRecordCounts;
        std::map<std::string, long long> tspRecordKb;
        const bool tspRecordMemOn = (std::getenv("TSP_RECORDMEM") != nullptr);
        std::size_t tspRecordTotal = 0;
        while (reader.hasMoreRecs())
        {
            ESM::NAME n = reader.getRecName();
            ++tspRecordTotal;
            ++tspRecordCounts[std::string(n.toStringView())];
            const std::string tspRecName(n.toStringView());
            const long long tspRecKb0 = tspRecordMemOn ? tspPhaseInuseKb() : 0;
            if ((tspRecordTotal % 128) == 0)
                Log(Debug::Info) << "TSP_LOAD_RECORD_PROGRESS_051_V13 generation=" << gTspLoadGeneration
                                 << " records=" << tspRecordTotal
                                 << " offset=" << reader.getFileOffset()
                                 << " total=" << total;
            reader.getRecHeader();

            switch (n.toInt())
            {
                case ESM::REC_SAVE:
                {
                    ESM::SavedGame profile;
                    profile.load(reader);
                    const auto& selectedContentFiles = MWBase::Environment::get().getWorld()->getContentFiles();
                    auto missingFiles = profile.getMissingContentFiles(selectedContentFiles);
                    if (!missingFiles.empty() && !confirmLoading(missingFiles))
                    {
                        cleanup(true);
                        MWBase::Environment::get().getWindowManager()->pushGuiMode(MWGui::GM_MainMenu);
                        return;
                    }
                    mTimePlayed = profile.mTimePlayed;
                    Log(Debug::Info) << "Loading saved game '" << profile.mDescription << "' for character '"
                                     << profile.mPlayerName << "'";
                }
                break;

                case ESM::REC_JOUR:
                case ESM::REC_QUES:

                    MWBase::Environment::get().getJournal()->readRecord(reader, n.toInt());
                    break;

                case ESM::REC_DIAS:

                    MWBase::Environment::get().getDialogueManager()->readRecord(reader, n.toInt());
                    break;

                case ESM::REC_ALCH:
                case ESM::REC_MISC:
                case ESM::REC_ACTI:
                case ESM::REC_ARMO:
                case ESM::REC_BOOK:
                case ESM::REC_CLAS:
                case ESM::REC_CLOT:
                case ESM::REC_ENCH:
                case ESM::REC_NPC_:
                case ESM::REC_SPEL:
                case ESM::REC_WEAP:
                case ESM::REC_GLOB:
                case ESM::REC_PLAY:
                case ESM::REC_CSTA:
                case ESM::REC_WTHR:
                case ESM::REC_DYNA:
                case ESM::REC_ACTC:
                case ESM::REC_PROJ:
                case ESM::REC_MPRJ:
                case ESM::REC_ENAB:
                case ESM::REC_LEVC:
                case ESM::REC_LEVI:
                case ESM::REC_LIGH:
                case ESM::REC_CREA:
                case ESM::REC_CONT:
                case ESM::REC_RAND:
                case ESM::REC_STAT:
                case ESM::REC_DOOR:
                case ESM::REC_PROB:
                    MWBase::Environment::get().getWorld()->readRecord(reader, n.toInt());
                    break;

                case ESM::REC_CAM_:
                    reader.getHNT(firstPersonCam, "FIRS");
                    break;

                case ESM::REC_GSCR:

                    MWBase::Environment::get().getScriptManager()->getGlobalScripts().readRecord(reader, n.toInt());
                    break;

                case ESM::REC_GMAP:
                case ESM::REC_KEYS:
                case ESM::REC_ASPL:
                case ESM::REC_MARK:

                    MWBase::Environment::get().getWindowManager()->readRecord(reader, n.toInt());
                    break;

                case ESM::REC_DCOU:
                case ESM::REC_STLN:

                    MWBase::Environment::get().getMechanicsManager()->readRecord(reader, n.toInt());
                    break;

                case ESM::REC_INPU:
                    MWBase::Environment::get().getInputManager()->readRecord(reader, n.toInt());
                    break;

                case ESM::REC_LUAM:
                    MWBase::Environment::get().getLuaManager()->readRecord(reader, n.toInt());
                    break;

                default:

                    // ignore invalid records
                    Log(Debug::Warning) << "Warning: Ignoring unknown record: " << n.toStringView();
                    reader.skipRecord();
            }
            if (tspRecordMemOn) tspRecordKb[tspRecName] += tspPhaseInuseKb() - tspRecKb0;
            int progressPercent = static_cast<int>(float(reader.getFileOffset()) / total * 100);
            if (progressPercent > currentPercent)
            {
                listener.increaseProgress(progressPercent - currentPercent);
                currentPercent = progressPercent;
            }
        }
        for (const auto& tspCount : tspRecordCounts)
            Log(Debug::Info) << "TSP_LOAD_RECORDS_051_V13 type=" << tspCount.first
                             << " count=" << tspCount.second;
        Log(Debug::Info) << "TSP_LOAD_RECORDS_051_V13 total=" << tspRecordTotal;
        for (const auto& tspKb : tspRecordKb)
            Log(Debug::Info) << "TSP_RECORDMEM_V1 type=" << tspKb.first << " kb=" << tspKb.second;
        tspLoadPhase("records-parsed");
        mCharacterManager.setCurrentCharacter(character);

        mState = State_Running;

        if (character)
            Settings::saves().mCharacter.set(Files::pathToUnicodeString(character->getPath().filename()));
        mLastSavegame = filepath;

        MWBase::Environment::get().getWindowManager()->setNewGame(false);
        MWBase::Environment::get().getWorld()->saveLoaded(reader);
        tspLoadPhase("world-saveLoaded");
        actorIdConverter.apply();
        tspLoadPhase("actor-id-map-applied");
        MWBase::Environment::get().getWorld()->setupPlayer();
        tspLoadPhase("player-setup");
        MWBase::Environment::get().getWorld()->renderPlayer();
        tspLoadPhase("player-rendered");
        MWBase::Environment::get().getWindowManager()->updatePlayer();
        tspLoadPhase("window-player-updated");
        MWBase::Environment::get().getMechanicsManager()->playerLoaded();
        tspLoadPhase("mechanics-playerLoaded");
        MWBase::Environment::get().getWorld()->toggleVanityMode(false);

        if (firstPersonCam != MWBase::Environment::get().getWorld()->isFirstPerson())
            MWBase::Environment::get().getWorld()->togglePOV();

        MWWorld::ConstPtr ptr = MWMechanics::getPlayer();

        if (ptr.isInCell())
        {
            const ESM::RefId cellId = ptr.getCell()->getCell()->getId();

            // Use detectWorldSpaceChange=false, otherwise some of the data we just loaded would be cleared again
            MWBase::Environment::get().getWorld()->changeToCell(cellId, ptr.getRefData().getPosition(), false, false);
        }
        else
        {
            // Cell no longer exists (i.e. changed game files), choose a default cell
            Log(Debug::Warning) << "Player character's cell no longer exists, changing to the default cell";
            ESM::ExteriorCellLocation cellIndex(0, 0, ESM::Cell::sDefaultWorldspaceId);
            MWWorld::CellStore& cell = MWBase::Environment::get().getWorldModel()->getExterior(cellIndex);
            const osg::Vec2f posFromIndex = ESM::indexToPosition(cellIndex, false);
            ESM::Position pos;
            pos.pos[0] = posFromIndex.x();
            pos.pos[1] = posFromIndex.y();
            pos.pos[2] = 0; // should be adjusted automatically (adjustPlayerPos=true)
            pos.rot[0] = 0;
            pos.rot[1] = 0;
            pos.rot[2] = 0;
            MWBase::Environment::get().getWorld()->changeToCell(cell.getCell()->getId(), pos, true, false);
        }

        MWBase::Environment::get().getWorld()->updateProjectilesCasters();
        tspLoadPhase("projectile-casters-updated");

        // Vanilla MW will restart startup scripts when a save game is loaded. This is unintuitive,
        // but some mods may be using it as a reload detector.
        MWBase::Environment::get().getScriptManager()->getGlobalScripts().addStartup();
        tspLoadPhase("startup-scripts-added");

        // Since we passed "changeEvent=false" to changeCell, we shouldn't have triggered the cell change flag.
        // But make sure the flag is cleared anyway in case it was set from an earlier game.
        MWBase::Environment::get().getWorldScene()->markCellAsUnchanged();

        MWBase::Environment::get().getLuaManager()->gameLoaded();
        tspLoadPhase("lua-gameLoaded");
        for (int actorId : actorIdConverter.mGraveyard)
        {
            auto mapped = actorIdConverter.mMappings.find(actorId);
            if (mapped != actorIdConverter.mMappings.end())
                MWBase::Environment::get().getMechanicsManager()->cleanupSummonedCreature(mapped->second);
        }
        tspFinishLoadTrace();
    }
    catch (const SaveVersionTooNewError& e)
    {
        std::string error = "#{OMWEngine:LoadingRequiresNewVersionError}";
        printSavegameFormatError(e.what(), error);
    }
    catch (const SaveVersionTooOldError& e)
    {
        const char* release;
        // Report the last version still capable of reading this save
        if (e.getFormatVersion() < ESM::OpenMW0_49MinSaveGameFormatVersion)
            release = "OpenMW 0.48.0";
        else
        {
            // Insert additional else if statements above to cover future releases
            static_assert(ESM::MinSupportedSaveGameFormatVersion <= ESM::OpenMW0_49MinSaveGameFormatVersion);
            release = "OpenMW 0.51.0";
        }
        auto l10n = MWBase::Environment::get().getL10nManager()->getContext("OMWEngine");
        std::string error = l10n->formatMessage("LoadingRequiresOldVersionError", { "version" }, { release });
        printSavegameFormatError(e.what(), error);
    }
    catch (const std::exception& e)
    {
        std::string error = "#{OMWEngine:LoadingFailed}: " + std::string(e.what());
        printSavegameFormatError(e.what(), error);
    }

    /* TSP_HEAPTRIM_V1: see tsp_heappatch.py. The load burst is freed but not
       returned - glibc trims only the top of brk. This hands the interior free
       pages back. Runs under the loading screen, so the cost is not a hitch.
       TSP_NO_HEAPTRIM=1 disables it. */
#if defined(__GLIBC__)
    if (std::getenv("TSP_NO_HEAPTRIM") == nullptr)
    {
        const long tspTrimRssBefore = tspHeapTrimRssKb();
        const int tspTrimRc = malloc_trim(0);
        const long tspTrimRssAfter = tspHeapTrimRssKb();
        Log(Debug::Warning) << "TSP_HEAPTRIM_V1 rc=" << tspTrimRc
                            << " rss_before_kb=" << tspTrimRssBefore
                            << " rss_after_kb=" << tspTrimRssAfter
                            << " returned_kb=" << (tspTrimRssBefore - tspTrimRssAfter);
    }
#endif
}

void MWState::StateManager::printSavegameFormatError(
    const std::string& exceptionText, const std::string& messageBoxText)
{
    Log(Debug::Error) << "Failed to load saved game: " << exceptionText;

    cleanup(true);

    MWBase::Environment::get().getWindowManager()->pushGuiMode(MWGui::GM_MainMenu);

    std::vector<std::string> buttons;
    buttons.emplace_back("#{Interface:OK}");

    MWBase::Environment::get().getWindowManager()->interactiveMessageBox(messageBoxText, buttons);
}

void MWState::StateManager::quickLoad()
{
    if (Character* currentCharacter = getCurrentCharacter())
    {
        if (currentCharacter->begin() == currentCharacter->end())
            return;
        // use requestLoad, otherwise we can crash by loading during the wrong part of the frame
        requestLoad(currentCharacter, currentCharacter->begin()->mPath);
    }
}

void MWState::StateManager::deleteGame(const MWState::Character* character, const MWState::Slot* slot)
{
    const std::filesystem::path savePath = slot->mPath;
    mCharacterManager.deleteSlot(slot, character);
    if (mLastSavegame == savePath)
    {
        if (character != nullptr)
            mLastSavegame = character->begin()->mPath;
        else
            mLastSavegame.clear();
    }
}

MWState::Character* MWState::StateManager::getCurrentCharacter()
{
    return mCharacterManager.getCurrentCharacter();
}

MWState::StateManager::CharacterIterator MWState::StateManager::characterBegin()
{
    return mCharacterManager.begin();
}

MWState::StateManager::CharacterIterator MWState::StateManager::characterEnd()
{
    return mCharacterManager.end();
}

void MWState::StateManager::update(float duration)
{
        tspUpdateLoadWatch();
    mTimePlayed += duration;

    // Note: It would be nicer to trigger this from InputManager, i.e. the very beginning of the frame update.
    if (mAskLoadRecent)
    {
        int iButton = MWBase::Environment::get().getWindowManager()->readPressedButton();
        MWState::Character* curCharacter = getCurrentCharacter();
        if (iButton == 0 && curCharacter)
        {
            mAskLoadRecent = false;
            // Load last saved game for current character
            // loadGame resets the game state along with mLastSavegame so we want to preserve it
            const std::filesystem::path filePath = std::move(mLastSavegame);
            loadGame(curCharacter, filePath);
        }
        else if (iButton == 1)
        {
            mAskLoadRecent = false;
            MWBase::Environment::get().getWindowManager()->pushGuiMode(MWGui::GM_MainMenu);
        }
    }

    if (mNewGameRequest)
    {
        MWBase::Environment::get().getWindowManager()->removeGuiMode(MWGui::GM_MainMenu);
        newGame();
        mNewGameRequest = false;
    }

    if (mLoadRequest)
    {
        MWBase::Environment::get().getWindowManager()->removeGuiMode(MWGui::GM_MainMenu);
        const Character* character = mLoadRequest->first;
        // The character may have been deleted after the request was made
        const bool validCharacter = std::ranges::find_if(mCharacterManager, [=](const Character& c) {
            return &c == character;
        }) != mCharacterManager.end();
        if (!validCharacter)
            character = getCurrentCharacter();
        loadGame(character, mLoadRequest->second);
        mLoadRequest = std::nullopt;
    }
}

bool MWState::StateManager::confirmLoading(const std::vector<std::string_view>& missingFiles) const
{
    std::ostringstream stream;
    for (auto& contentFile : missingFiles)
    {
        Log(Debug::Warning) << "Warning: Saved game dependency " << contentFile << " is missing.";
        stream << contentFile << "\n";
    }

    auto fullList = stream.str();
    if (!fullList.empty())
        fullList.pop_back();

    constexpr size_t missingPluginsDisplayLimit = 12;

    std::vector<std::string> buttons;
    buttons.emplace_back("#{Interface:Yes}");
    buttons.emplace_back("#{Interface:Copy}");
    buttons.emplace_back("#{Interface:No}");
    std::string message = "#{OMWEngine:MissingContentFilesConfirmation}";

    auto l10n = MWBase::Environment::get().getL10nManager()->getContext("OMWEngine");
    message += l10n->formatMessage("MissingContentFilesList", { "files" }, { static_cast<int>(missingFiles.size()) });
    auto cappedSize = std::min(missingFiles.size(), missingPluginsDisplayLimit);
    if (cappedSize == missingFiles.size())
    {
        message += fullList;
    }
    else
    {
        for (size_t i = 0; i < cappedSize - 1; ++i)
        {
            message += missingFiles[i];
            message += "\n";
        }

        message += "...";
    }

    message
        += l10n->formatMessage("MissingContentFilesListCopy", { "files" }, { static_cast<int>(missingFiles.size()) });

    int selectedButton = -1;
    while (true)
    {
        auto windowManager = MWBase::Environment::get().getWindowManager();
        windowManager->interactiveMessageBox(message, buttons, true, selectedButton);
        selectedButton = windowManager->readPressedButton();
        if (selectedButton == 0)
            break;

        if (selectedButton == 1)
        {
            SDL_SetClipboardText(fullList.c_str());
            continue;
        }

        return false;
    }

    return true;
}

void MWState::StateManager::writeScreenshot(std::vector<char>& imageData) const
{
    int screenshotW = 259 * 2, screenshotH = 133 * 2; // *2 to get some nice antialiasing

    osg::ref_ptr<osg::Image> screenshot(new osg::Image);

    MWBase::Environment::get().getWorld()->screenshot(screenshot.get(), screenshotW, screenshotH);

    osgDB::ReaderWriter* readerwriter = osgDB::Registry::instance()->getReaderWriterForExtension("jpg");
    if (!readerwriter)
    {
        Log(Debug::Error) << "Error: Unable to write screenshot, can't find a jpg ReaderWriter";
        return;
    }

    std::ostringstream ostream;
    osgDB::ReaderWriter::WriteResult result = readerwriter->writeImage(*screenshot, ostream);
    if (!result.success())
    {
        Log(Debug::Error) << "Error: Unable to write screenshot: " << result.message() << " code " << result.status();
        return;
    }

    std::string data = ostream.str();
    imageData = std::vector<char>(data.begin(), data.end());
}
