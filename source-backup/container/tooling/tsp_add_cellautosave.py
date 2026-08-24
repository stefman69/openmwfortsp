#!/usr/bin/env python3
"""
tsp_add_cellautosave.py

Quicksave whenever the player crosses a cell boundary, so the ~40-minute
memory crash costs seconds of progress instead of a session.

===========================================================================
WHY
===========================================================================

Measured on device: 986MB total RAM, ZERO swap. With no swap the kernel has
no graceful degradation - once the system runs out, the process is OOM
killed outright.

Sampling RSS every 30s over ~16 minutes of play showed:

  - OpenMW's own RSS does NOT leak: it holds 600-660MB and drops to
    310-390MB on every load screen, so cache expiry works
  - but MemAvailable falls 706MB -> 41MB across the session and does NOT
    recover in proportion when RSS drops
  - below ~45MB available the game hits 1fps and then dies
  - moving to an interior cell did not postpone it

So something outside the process's resident set is accumulating. That is
still under investigation and this patch does not attempt to fix it.

This patch is the seatbelt, not the repair. It is worth having regardless of
what the leak turns out to be, and it is independent of every other TSP
change in the tree.

===========================================================================
WHAT IT DOES
===========================================================================

World::changeToInteriorCell and World::changeToExteriorCell
(apps/openmw/mwworld/worldimp.cpp) are the two funnels every cell transition
passes through. After the transition completes, request a quicksave via
MWState::StateManager::quickSave (statemanagerimp.cpp:697), which writes to
the rotating quicksave slots rather than overwriting a manual save.

Guards, because a save on every transition would be worse than the crash:

  - a minimum interval between autosaves (default 120s) so that running in
    and out of a doorway does not thrash the SD card
  - skipped entirely while a load is in progress, so it cannot fire
    re-entrantly during the transition it is reacting to
  - TSP_NO_CELL_AUTOSAVE=1 disables it at runtime
  - TSP_CELL_AUTOSAVE_SECS overrides the interval

===========================================================================
VERIFY
===========================================================================

  grep TSP_CELL_AUTOSAVE openmw.log

Expect a line per transition, either "saved" or "skipped (interval)".
Then check the quicksave slots are rotating in the save menu.

Note this writes to SD card on a timer-gated basis; if transitions feel like
they hitch afterwards, raise TSP_CELL_AUTOSAVE_SECS.

===========================================================================
USAGE
===========================================================================

  python3 tsp_add_cellautosave.py           apply
  python3 tsp_add_cellautosave.py --revert  restore newest backup
"""

import glob
import os
import shutil
import sys
import time

SRC = "/root/openmw-0.51-tsp-src/apps/openmw/mwworld/worldimp.cpp"
TAG = "TSP_CELL_AUTOSAVE"

HELPER = '''
namespace
{
    /* ''' + TAG + ''': the device has 986MB and no swap, and MemAvailable
       trickles to ~41MB over roughly 40 minutes of play before the process is
       OOM killed. Until that is fixed, save on cell transitions so a crash
       costs seconds rather than a session. Interval-gated so doorway
       round-trips do not hammer the SD card. */
    void tspCellAutosave(const char* where)
    {
        if (std::getenv("TSP_NO_CELL_AUTOSAVE"))
            return;

        double intervalSecs = 120.0;
        if (const char* e = std::getenv("TSP_CELL_AUTOSAVE_SECS"))
        {
            const double v = atof(e);
            if (v > 0.0)
                intervalSecs = v;
        }

        MWBase::StateManager* stateManager = MWBase::Environment::get().getStateManager();
        if (!stateManager || stateManager->getState() != MWBase::StateManager::State_Running)
            return;

        using TspClock = std::chrono::steady_clock;
        static TspClock::time_point sLast;
        static bool sHave = false;
        const TspClock::time_point now = TspClock::now();

        if (sHave)
        {
            const double since
                = std::chrono::duration_cast<std::chrono::duration<double>>(now - sLast).count();
            if (since < intervalSecs)
            {
                Log(Debug::Info) << "TSP_CELL_AUTOSAVE skipped (interval) at " << where
                                 << " since=" << since << "s";
                return;
            }
        }

        sLast = now;
        sHave = true;
        Log(Debug::Info) << "TSP_CELL_AUTOSAVE saving at " << where;
        stateManager->quickSave("Autosave");
    }
}
'''


def revert():
    b = sorted(glob.glob(SRC + ".before-cellautosave-*"))
    if not b:
        print("no backup found")
        return 1
    shutil.copy(b[-1], SRC)
    print("restored", os.path.basename(b[-1]))
    return 0


def main():
    if "--revert" in sys.argv:
        return revert()

    if not os.path.exists(SRC):
        print("ERROR: missing", SRC)
        return 1

    s = open(SRC).read()
    if TAG in s:
        print("already patched")
        return 0

    for inc in ("<chrono>", "<cstdlib>", "<components/debug/debuglog.hpp>",
                "<apps/openmw/mwbase/statemanager.hpp>"):
        if "#include %s" % inc not in s:
            i = s.find("#include")
            j = s.find("\n", i) + 1
            s = s[:j] + "#include %s\n" % inc + s[j:]

    # helper goes at namespace scope, before the World methods
    anchor = "    void World::changeToInteriorCell("
    if anchor not in s:
        print("ERROR: changeToInteriorCell anchor missing. Candidates:")
        for i, l in enumerate(s.split("\n"), 1):
            if "changeToInteriorCell" in l or "changeToExteriorCell" in l:
                print("  %d: %s" % (i, l.rstrip()[:100]))
        return 1
    s = s.replace(anchor, HELPER + "\n" + anchor, 1)

    # hook the two mWorldScene calls that perform the actual transition
    hooks = [
        ("        mWorldScene->changeToInteriorCell(cellName, position, adjustPlayerPos, changeEvent);",
         'tspCellAutosave("interior");'),
    ]
    count = 0
    for target, call in hooks:
        if target in s:
            s = s.replace(target, target + "\n        " + call, 1)
            count += 1
        else:
            print("WARNING: hook target not found:\n  " + target[:90])

    # exterior transitions - hook every mWorldScene->changeToExteriorCell call
    lines = s.split("\n")
    out = []
    for line in lines:
        out.append(line)
        if ("mWorldScene->changeToExteriorCell(" in line
                and "tspCellAutosave" not in line
                and line.rstrip().endswith(";")):
            indent = line[:len(line) - len(line.lstrip())]
            out.append(indent + 'tspCellAutosave("exterior");')
            count += 1
    s = "\n".join(out)

    if count == 0:
        print("ERROR: no transition call sites hooked")
        return 1

    shutil.copy(SRC, SRC + ".before-cellautosave-" + time.strftime("%Y%m%d-%H%M%S"))
    open(SRC, "w").write(s)
    print("patched %d transition site(s)" % count)
    print("\nbuild with:")
    print("  cd /root/openmw-0.51-tsp-build && cmake --build . --target openmw --parallel 4")
    return 0


sys.exit(main())
