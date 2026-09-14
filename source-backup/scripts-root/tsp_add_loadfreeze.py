#!/usr/bin/env python3
"""
tsp_add_loadfreeze.py

Hold the player still for a few seconds after a save loads, while the scene
renders, so Mali's per-program shader work lands there instead of as stutter
during play.

===========================================================================
WHY THIS SHAPE
===========================================================================

Measured on Mali-G57 / gl4es: ~137ms in glLinkProgram plus ~236ms deferred
into the first draw using each program. TSP_SHADER_WARMDRAW already forces
that draw early with a throwaway 3-vertex triangle (proved by stall lines
reading worst_n=3 worst_tex=0), but those draws still land after the loading
screen closes, so the player gets 5-8fps for several seconds while free to
walk around and be attacked.

Two earlier attempts failed and are worth not repeating:

  - Spreading the warm draws across frames (kCooldownFrames). Each warm draw
    is one atomic ~240ms glDrawArrays; Mali will not yield partway through
    it, so spreading only scatters the hitches, never shrinks them.

  - Draining them from LoadingScreen::loadingOff. loadingOn() explicitly
    node-masks the whole scene off ("We are already using node masks to
    avoid the scene from being updated/rendered"), so the warm-up group
    hangs under a subtree that is not traversed there. The loop spun to its
    240-iteration guard four times, adding ~7s of dead loading and draining
    nothing.

The scene IS rendering once loading ends. So: let rendering proceed normally
and freeze only simulation and input for a short window afterwards.

===========================================================================
WHAT IT DOES
===========================================================================

In Engine::frame:
  - while the freeze counter is above zero, pass 0.f to mInputManager->update
    so the player cannot move, swing, or cast
  - force the existing `paused` flag true, which the file already threads into
    mechanics (354), physics (371) and world update (381), so nothing in the
    world acts on the player either
  - decrement each frame; rendering is untouched throughout

The counter is armed when a game finishes loading and cleared early once the
warm-up group is empty, so it never holds longer than the work actually takes.

TSP_NO_LOAD_FREEZE=1 disables it at runtime for a clean A/B.
TSP_LOAD_FREEZE_FRAMES overrides the frame budget (default 300).

===========================================================================
EXPECTED RESULT
===========================================================================

Character stands at the load point, world visible and rendering, for a few
seconds. Then normal play with the ~240ms hitches already spent.

  grep TSP_LOAD_FREEZE openmw.log        -> armed / released, and frame count
  grep -cE "worst_us=[0-9]{6,}" diag.txt -> stalls that still land in play

Programs created after the freeze window ends (new creature types, new
effects) will still warm mid-game; this cannot catch those.

===========================================================================
USAGE
===========================================================================

  python3 tsp_add_loadfreeze.py           apply
  python3 tsp_add_loadfreeze.py --revert  restore newest backups
"""

import glob
import os
import shutil
import sys
import time

SRC = "/root/openmw-0.51-tsp-src/apps/openmw"
ENGINE = SRC + "/engine.cpp"
STATE = SRC + "/mwstate/statemanagerimp.cpp"
TAG = "TSP_LOAD_FREEZE"

HELPER = '''
/* ''' + TAG + ''': frames still to hold after a save load. Armed by
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
'''

FRAME_GATE = '''    /* ''' + TAG + ''': hold simulation and input while the shader warm draws
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
        frametime = 0.f;
    }
'''


def backup(p):
    shutil.copy(p, p + ".before-loadfreeze-" + time.strftime("%Y%m%d-%H%M%S"))


def revert():
    n = 0
    for p in (ENGINE, STATE):
        b = sorted(glob.glob(p + ".before-loadfreeze-*"))
        if b:
            shutil.copy(b[-1], p)
            print("restored", os.path.basename(p))
            n += 1
    return 0 if n else 1


def main():
    if "--revert" in sys.argv:
        return revert()

    for p in (ENGINE, STATE):
        if not os.path.exists(p):
            print("ERROR: missing", p)
            return 1

    report = []

    # ---------------- engine.cpp ----------------
    e = open(ENGINE).read()
    if TAG in e:
        print("engine.cpp already patched")
    else:
        for inc in ("<cstdlib>", "<osg/Group>",
                    "<components/resource/scenemanager.hpp>",
                    "<components/shader/shadermanager.hpp>",
                    "<components/debug/debuglog.hpp>"):
            if "#include %s" % inc not in e:
                i = e.find("#include")
                j = e.find("\n", i) + 1
                e = e[:j] + "#include %s\n" % inc + e[j:]

        anchor = "bool OMW::Engine::frame(unsigned frameNumber, float frametime)"
        if anchor not in e:
            print("ERROR: Engine::frame anchor missing")
            return 1
        e = e.replace(anchor, HELPER + "\n" + anchor, 1)

        # insert the gate at the very top of frame(), before setFrameDuration
        marker = "    mEnvironment.setFrameDuration(frametime);"
        if marker not in e:
            print("ERROR: setFrameDuration anchor missing. Candidates:")
            for i, l in enumerate(e.split("\n"), 1):
                if "setFrameDuration" in l:
                    print("  %d: %s" % (i, l.strip()[:90]))
            return 1
        e = e.replace(marker, FRAME_GATE + marker, 1)

        # force the existing paused flag true during the freeze
        pmark = "        bool paused = mWorld->getTimeManager()->isPaused();"
        if pmark not in e:
            print("ERROR: paused anchor missing. Candidates:")
            for i, l in enumerate(e.split("\n"), 1):
                if "bool paused" in l:
                    print("  %d: %s" % (i, l.strip()[:90]))
            return 1
        e = e.replace(pmark,
                      pmark + "\n        if (tspFrozen)\n            paused = true;", 1)

        backup(ENGINE)
        open(ENGINE, "w").write(e)
        report.append("engine.cpp: freeze gate in frame()")

    # ---------------- statemanagerimp.cpp ----------------
    st = open(STATE).read()
    if TAG in st:
        print("statemanagerimp.cpp already patched")
    else:
        # arm at the same point already logged as phase=complete
        cand = [l for l in st.split("\n") if "phase=complete" in l]
        if not cand:
            print("ERROR: no phase=complete line in statemanagerimp.cpp")
            for i, l in enumerate(st.split("\n"), 1):
                if "TSP_LOAD_TRACE" in l:
                    print("  %d: %s" % (i, l.strip()[:100]))
            return 1
        line = cand[0]
        indent = line[:len(line) - len(line.lstrip())]
        st = st.replace(line,
                        line + "\n" + indent
                        + "extern void tspArmLoadFreeze();  /* " + TAG + " */\n"
                        + indent + "tspArmLoadFreeze();", 1)
        backup(STATE)
        open(STATE, "w").write(st)
        report.append("statemanagerimp.cpp: arm freeze at load completion")

    print("\n".join("  " + r for r in report) if report else "  nothing to do")
    print("\nbuild with:")
    print("  cd /root/openmw-0.51-tsp-build && cmake --build . --target openmw --parallel 4")
    return 0


sys.exit(main())
