#!/usr/bin/env python3
"""
tsp_add_cellhooks2.py

Cell-transition autosave + GL release, hooked where the engine itself
acknowledges a completed cell change.

===========================================================================
WHY THIS IS THE THIRD VERSION
===========================================================================

Attempt 1 appended calls after each mWorldScene->changeTo*Cell(). It did not
compile: some call sites precede the helper definition, and others sit in
unbraced if/else bodies where an extra statement detaches the else.

Attempt 2 used scope guards inside World::changeToInteriorCell /
changeToExteriorCell / changeToCell. It compiled and ran, but behaved wrong:

  - it fired during loading, because those methods ARE the load path
    (worldimp.cpp:419-445 call them from startNewGame), and quickSave refuses
    with "you cannot save your game right now"
  - the 120s interval gate was then spent on those false fires, so real door
    transitions were suppressed

Root cause of both: World::changeTo*Cell is the low-level scene swap, not the
"player finished changing cell" event.

This version hooks the real event. Scene::mCellChanged is set at
scene.cpp:698 and 986, read via hasCellChanged(), and cleared by
markCellAsUnchanged() which Engine::frame calls at engine.cpp:388. That call
site is in the frame loop, after the transition, outside the load path.

It also mirrors quickSave's OWN preconditions (statemanagerimp.cpp) rather
than the weaker State_Running check used before:

    mState == State_Running
    && getGlobalInt(MWWorld::Globals::sCharGenState) == -1
    && getWindowManager()->isSavingAllowed()

Because isSavingAllowed() is false during a load, this cannot produce the
denial message by construction.

===========================================================================
THE GL RELEASE HALF - STILL AN UNCONFIRMED THEORY
===========================================================================

Device: 986MB RAM, ZERO swap - no graceful degradation, straight to OOM kill.

Sampled every 30s over ~16 minutes of play:
  - OpenMW RSS does NOT leak: 600-660MB steady, dropping to 310-390MB on
    every load screen, so its own cache expiry demonstrably works
  - MemAvailable falls 706MB -> 41MB and does NOT recover proportionally
  - below ~45MB available: 1fps, then death
  - retreating to an interior cell did not postpone it

Memory consumed but absent from VmRSS suggests kernel-side driver
allocations. On Mali, textures/VBOs/programs live there. OpenMW returns them
via releaseGLObjects, which in this tree runs on clearCache but NOT on
ordinary expiry.

Each release logs MemAvailable before and after. THAT PAIR IS THE EXPERIMENT.
Large positive reclaimed_kb means the theory holds; ~0 means driver memory is
not the culprit and fragmentation is the remaining candidate.

RISK: releaseGLObjects(nullptr) drops GL objects with no State to unbind
from. OpenMW does this itself in clearCache, so it is an existing engine
path, but with gl4es it is the likeliest thing here to misbehave. If a
transition crashes or textures go black, set TSP_NO_CELL_GLRELEASE=1 - no
rebuild needed.

===========================================================================
RUNTIME CONTROLS (no rebuild)
===========================================================================

  TSP_NO_CELL_AUTOSAVE=1      disable autosave
  TSP_CELL_AUTOSAVE_SECS=N    autosave interval, default 120
  TSP_NO_CELL_GLRELEASE=1     disable GL release
  TSP_CELL_GLRELEASE_SECS=N   GL release interval, default 90

===========================================================================
VERIFY
===========================================================================

  grep TSP_CELL_ openmw.log

Expect NO autosave lines during the initial load, then one per door
transition (interval permitting), and glrelease lines carrying reclaimed_kb.

  python3 tsp_add_cellhooks2.py           apply
  python3 tsp_add_cellhooks2.py --revert  restore pristine worldimp/engine
"""

import glob
import os
import shutil
import sys
import time

BASE = "/root/openmw-0.51-tsp-src/apps/openmw"
WORLD = BASE + "/mwworld/worldimp.cpp"
ENGINE = BASE + "/engine.cpp"
TAG = "TSP_CELL_HOOKS2"

HELPER = '''
/* ''' + TAG + ''': fired from Engine::frame where the engine already
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

    void tspOnCellChanged()
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
                Resource::ResourceSystem* rs = world->getResourceSystem();
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
            static std::chrono::steady_clock::time_point sLastSave;
            static bool sHaveSave = false;
            if (tspIntervalElapsed(sLastSave, sHaveSave,
                    tspIntervalFromEnv("TSP_CELL_AUTOSAVE_SECS", 120.0)))
            {
                Log(Debug::Info) << "TSP_CELL_AUTOSAVE saving on cell change";
                stateManager->quickSave("Autosave");
            }
        }
    }
}
'''


def restore(path, pats):
    for pat in pats:
        b = sorted(glob.glob(path + pat))
        if b:
            shutil.copy(b[0], path)
            print("restored", os.path.basename(path), "from", os.path.basename(b[0]))
            return True
    return False


def revert():
    ok = False
    ok |= restore(WORLD, [".before-cellhooks-*", ".before-cellautosave-*", ".before-glrelease-*"])
    ok |= restore(ENGINE, [".before-cellhooks2-*"])
    return 0 if ok else 1


def main():
    if "--revert" in sys.argv:
        return revert()

    for p in (WORLD, ENGINE):
        if not os.path.exists(p):
            print("ERROR: missing", p)
            return 1

    # 1. strip the previous attempts out of worldimp.cpp
    w = open(WORLD).read()
    if "tspCellAutosave" in w or "tspCellGlRelease" in w or "TSP_CELL_HOOKS" in w:
        if not restore(WORLD, [".before-cellhooks-*", ".before-cellautosave-*",
                               ".before-glrelease-*"]):
            print("ERROR: worldimp.cpp has old hooks but no backup to restore")
            return 1
    else:
        print("worldimp.cpp already clean")

    # 2. patch engine.cpp
    e = open(ENGINE).read()
    if TAG in e:
        print("engine.cpp already patched")
        return 0

    for inc in ("<chrono>", "<cstdlib>", "<fstream>", "<sstream>",
                "<components/debug/debuglog.hpp>",
                "<components/resource/resourcesystem.hpp>",
                '"mwbase/statemanager.hpp"', '"mwbase/windowmanager.hpp"',
                '"mwbase/world.hpp"', '"mwworld/globals.hpp"'):
        token = "#include %s" % inc
        if token not in e:
            i = e.rfind("\n#include")
            j = e.find("\n", i + 1) + 1
            e = e[:j] + token + "\n" + e[j:]

    anchor = "bool OMW::Engine::frame(unsigned frameNumber, float frametime)"
    if anchor not in e:
        print("ERROR: Engine::frame anchor missing")
        return 1
    e = e.replace(anchor, HELPER + "\n" + anchor, 1)

    mark = "mWorld->getWorldScene().markCellAsUnchanged();"
    if mark not in e:
        print("ERROR: markCellAsUnchanged anchor missing. Candidates:")
        for i, l in enumerate(e.split("\n"), 1):
            if "markCellAsUnchanged" in l or "hasCellChanged" in l:
                print("  %d: %s" % (i, l.strip()[:100]))
        return 1
    e = e.replace(mark,
                  "/* " + TAG + ": the engine acknowledges the completed cell change here. */\n"
                  "                    tspOnCellChanged();\n"
                  "                    " + mark, 1)

    shutil.copy(ENGINE, ENGINE + ".before-cellhooks2-" + time.strftime("%Y%m%d-%H%M%S"))
    open(ENGINE, "w").write(e)
    print("patched engine.cpp at markCellAsUnchanged")
    return 0


sys.exit(main())
