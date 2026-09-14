#!/usr/bin/env python3
"""
tsp_add_cellhooks.py

Two cell-transition hooks in one patch:
  1. autosave  - quicksave on transition, so an OOM crash costs seconds
  2. glrelease - releaseGLObjects on transition, testing the driver-memory theory

===========================================================================
WHY THIS REPLACES THE TWO EARLIER SCRIPTS
===========================================================================

The first attempt inserted statements immediately after each
mWorldScene->changeTo*Cell() call. That broke in two ways:

  - some call sites (startNewGame, line ~340) appear BEFORE the helper
    definition, so the name was not in scope
  - some call sites sit in unbraced if/else bodies:
        if (exteriorCell)
            mWorldScene->changeToExteriorCell(...);
        else
            mWorldScene->changeToInteriorCell(...);
    appending a statement there detaches the else

This version avoids both: the helper goes at file scope right after the
includes, and each World::changeTo*Cell method gets ONE scope-guard object
declared as the first statement of its body. The guard's destructor runs on
function exit, so the hook fires after the transition completes, and nothing
is inserted into a conditional.

===========================================================================
THE MEMORY EVIDENCE (context for the glrelease half)
===========================================================================

Device: 986MB RAM, ZERO swap - no graceful degradation, straight to OOM kill.

Sampled every 30s over ~16 minutes:
  - OpenMW RSS does NOT leak: 600-660MB steady, drops to 310-390MB on every
    load screen, so its cache expiry demonstrably works
  - MemAvailable falls 706MB -> 41MB and does NOT recover in proportion
  - below ~45MB available: 1fps, then death
  - retreating to an interior cell did not postpone it

Memory consumed but absent from VmRSS is the signature of kernel-side driver
allocations. On Mali, textures/VBOs/programs live there. OpenMW returns them
via releaseGLObjects, which in this tree runs on clearCache but NOT on
ordinary cache expiry.

THIS IS STILL AN UNCONFIRMED THEORY. It was written on the best-case
assumption to save a test cycle. The log lines below are the experiment: each
glrelease prints MemAvailable before and after. If reclaimed_kb is
consistently large and positive, the theory holds. If it is ~0, driver memory
is NOT the culprit and the remaining candidate is fragmentation.

RISK: releaseGLObjects(nullptr) drops GL objects with no State to unbind
from. OpenMW does this itself in clearCache so it is an existing engine path,
but combined with gl4es it is the most likely thing here to misbehave. If the
first transition crashes or textures go black, set TSP_NO_CELL_GLRELEASE=1
(no rebuild needed) rather than tuning.

===========================================================================
RUNTIME CONTROLS (all without rebuilding)
===========================================================================

  TSP_NO_CELL_AUTOSAVE=1      disable autosave
  TSP_CELL_AUTOSAVE_SECS=N    autosave interval, default 120
  TSP_NO_CELL_GLRELEASE=1     disable GL release
  TSP_CELL_GLRELEASE_SECS=N   GL release interval, default 90

===========================================================================
VERIFY
===========================================================================

  grep TSP_CELL_ openmw.log

Expect autosave lines and glrelease lines with reclaimed_kb. Re-run the RSS
sampler and compare against the 706->41MB baseline already captured.

  python3 tsp_add_cellhooks.py           apply
  python3 tsp_add_cellhooks.py --revert  restore newest backup
"""

import glob
import os
import re
import shutil
import sys
import time

SRC = "/root/openmw-0.51-tsp-src/apps/openmw/mwworld/worldimp.cpp"
TAG = "TSP_CELL_HOOKS"

HELPER = '''
/* ''' + TAG + ''': cell-transition hooks. Defined at file scope so every
   World::changeTo*Cell method can see it regardless of definition order -
   an earlier version placed this mid-file and calls in startNewGame failed
   to compile. Fired from a scope guard rather than appended after the
   transition call, because several of those calls sit in unbraced if/else
   bodies where an extra statement detaches the else. */
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

    /* Quicksave on transition. The device dies to OOM roughly every 40
       minutes and that is not yet fixed, so this is the seatbelt: rotating
       quicksave slots, never overwriting a manual save. Interval-gated so
       running in and out of a doorway does not thrash the SD card. */
    void tspCellAutosave(const char* where)
    {
        if (std::getenv("TSP_NO_CELL_AUTOSAVE"))
            return;

        MWBase::StateManager* stateManager = MWBase::Environment::get().getStateManager();
        if (!stateManager || stateManager->getState() != MWBase::StateManager::State_Running)
            return;

        const double intervalSecs = tspIntervalFromEnv("TSP_CELL_AUTOSAVE_SECS", 120.0);

        using TspClock = std::chrono::steady_clock;
        static TspClock::time_point sLast;
        static bool sHave = false;
        const TspClock::time_point now = TspClock::now();

        if (sHave)
        {
            const double since
                = std::chrono::duration_cast<std::chrono::duration<double>>(now - sLast).count();
            if (since < intervalSecs)
                return;
        }
        sLast = now;
        sHave = true;

        Log(Debug::Info) << "TSP_CELL_AUTOSAVE saving at " << where;
        stateManager->quickSave("Autosave");
    }

    /* Return driver-side GL memory. See the script header - this is an
       unconfirmed theory and the before/after numbers are the experiment. */
    void tspCellGlRelease(Resource::ResourceSystem* resourceSystem, const char* where)
    {
        if (!resourceSystem || std::getenv("TSP_NO_CELL_GLRELEASE"))
            return;

        const double intervalSecs = tspIntervalFromEnv("TSP_CELL_GLRELEASE_SECS", 90.0);

        using TspClock = std::chrono::steady_clock;
        static TspClock::time_point sLast;
        static bool sHave = false;
        const TspClock::time_point now = TspClock::now();

        if (sHave)
        {
            const double since
                = std::chrono::duration_cast<std::chrono::duration<double>>(now - sLast).count();
            if (since < intervalSecs)
                return;
        }
        sLast = now;
        sHave = true;

        const long long before = tspReadMemAvailableKb();
        resourceSystem->releaseGLObjects(nullptr);
        const long long after = tspReadMemAvailableKb();

        Log(Debug::Info) << "TSP_CELL_GLRELEASE at " << where
                         << " avail_before_kb=" << before
                         << " avail_after_kb=" << after
                         << " reclaimed_kb=" << (after - before);
    }
}
'''


def revert():
    n = 0
    for pat in (".before-cellhooks-*", ".before-cellautosave-*", ".before-glrelease-*"):
        b = sorted(glob.glob(SRC + pat))
        if b:
            shutil.copy(b[0], SRC)   # oldest = closest to pristine
            print("restored from", os.path.basename(b[0]))
            n += 1
            break
    return 0 if n else 1


def main():
    if "--revert" in sys.argv:
        return revert()

    if not os.path.exists(SRC):
        print("ERROR: missing", SRC)
        return 1

    s = open(SRC).read()

    # undo any earlier broken attempt before applying
    if "tspCellAutosave" in s or "tspCellGlRelease" in s:
        older = sorted(glob.glob(SRC + ".before-cellautosave-*")) \
            + sorted(glob.glob(SRC + ".before-glrelease-*"))
        if not older:
            print("ERROR: file already has hooks but no backup to restore from")
            return 1
        shutil.copy(older[0], SRC)
        print("reverted earlier attempt from", os.path.basename(older[0]))
        s = open(SRC).read()

    if TAG in s:
        print("already patched")
        return 0

    for inc in ("<chrono>", "<cstdlib>", "<fstream>", "<sstream>",
                "<components/debug/debuglog.hpp>",
                "<components/resource/resourcesystem.hpp>",
                '"../mwbase/statemanager.hpp"'):
        token = "#include %s" % inc
        if token not in s:
            i = s.rfind("\n#include")
            j = s.find("\n", i + 1) + 1
            s = s[:j] + token + "\n" + s[j:]

    # helper at file scope, after the include block, before any function
    i = s.rfind("\n#include")
    j = s.find("\n", i + 1) + 1
    s = s[:j] + HELPER + s[j:]

    # find how World reaches the ResourceSystem
    member = None
    for cand in ("mResourceSystem", "mRendering->getResourceSystem()"):
        if cand in s:
            member = cand
            break
    if member is None:
        print("ERROR: no ResourceSystem handle found in worldimp.cpp. Candidates:")
        for i, l in enumerate(s.split("\n"), 1):
            if "ResourceSystem" in l:
                print("  %d: %s" % (i, l.strip()[:100]))
        return 1
    print("ResourceSystem handle:", member)

    # insert a scope guard as the first statement of each transition method
    targets = [
        ("void World::changeToInteriorCell(", "interior"),
        ("void World::changeToExteriorCell(", "exterior"),
        ("void World::changeToCell(", "cell"),
    ]
    count = 0
    for sig, where in targets:
        pos = s.find(sig)
        if pos < 0:
            print("  (no %s in this tree, skipping)" % sig.strip())
            continue
        brace = s.find("\n    {\n", pos)
        if brace < 0 or brace - pos > 800:
            print("  WARNING: could not find body brace for %s, skipping" % sig.strip())
            continue
        ins = brace + len("\n    {\n")
        guard = (
            "        /* " + TAG + ": fires on function exit, after the transition. */\n"
            "        struct TspCellGuard\n"
            "        {\n"
            "            Resource::ResourceSystem* rs;\n"
            "            ~TspCellGuard()\n"
            "            {\n"
            '                tspCellAutosave("' + where + '");\n'
            '                tspCellGlRelease(rs, "' + where + '");\n'
            "            }\n"
            "        } tspCellGuard{ " + member + " };\n"
        )
        s = s[:ins] + guard + s[ins:]
        count += 1
        print("  hooked %s" % sig.strip())

    if count == 0:
        print("ERROR: no transition methods hooked")
        return 1

    shutil.copy(SRC, SRC + ".before-cellhooks-" + time.strftime("%Y%m%d-%H%M%S"))
    open(SRC, "w").write(s)
    print("patched %d method(s)" % count)
    return 0


sys.exit(main())
