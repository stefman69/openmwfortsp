#!/usr/bin/env python3
"""
tsp_ringprof.py

Adds a ring-buffer frame profiler to OpenMW's main loop and mechanics pass.

===========================================================================
WHY THIS DESIGN
===========================================================================

Every previous attempt in this investigation used a threshold and wrote to
disk when a call exceeded it. That failed repeatedly for the same reason:

  - a threshold guessed too high logged nothing
  - a threshold guessed too low logged constantly and the fwrite/fflush cost
    changed the thing being measured
  - the event had to happen during the capture window, and forced animation
    rebuilds fire roughly 4 times in 2800 frames, so most runs caught nothing

This records EVERY frame into a fixed in-memory array - no branches on a
threshold, no file I/O during play - and writes the last 600 frames out when
the process exits. Whatever happened is in there, including the frames either
side of a stall, so the shape of the spike is visible rather than a single
number torn out of context.

Cost per frame is a handful of clock_gettime calls and some array stores.

===========================================================================
WHAT IT RECORDS
===========================================================================

Per frame:

  frame     sequence number
  total_ms  wall time of the whole frame
  mech_ms   Actors::update - the mechanics pass over every actor
  spell_ms  ActiveSpells::update accumulated across all actors this frame
  char_ms   CharacterController::update accumulated across all actors
  anim_ms   refreshCurrentAnims accumulated across all actors
  nactors   how many actors the mechanics pass iterated
  nforced   how many forced animation rebuilds happened this frame

Confirmed so far: ActiveSpells::update costs 21ms once at application, a
forced refreshCurrentAnims costs 10.77ms, and Actors::update ran 12-26ms for
about 4.4 seconds during a paralysis. Those add to roughly 32ms of one-time
cost, which does not explain a sustained stall. The per-frame series will
show whether the sustained portion is real and which counter tracks it.

===========================================================================
USAGE
===========================================================================

  python3 tsp_ringprof.py            apply
  python3 tsp_ringprof.py --revert   restore from the newest backup

Then set in the launcher:

  export OPENMW_TSP_RING=/mnt/SDCARD/tsp_ring.txt

The file is written when the game exits normally. Quit through the menu
rather than killing the process, or the dump will not run.
"""

import glob
import os
import re
import shutil
import sys
import time

SRC = "/root/openmw-0.51-tsp-src/apps/openmw"

RING_HEADER = r'''
/* TSP_RINGPROF: fixed-size per-frame sample buffer.

   Records every frame with no threshold and no file I/O during play, then
   dumps the last TSP_RING_N frames at exit. This replaces the
   threshold-and-fflush approach that repeatedly either logged nothing or
   perturbed the measurement. */
#include <cstdio>
#include <cstdlib>
#include <ctime>

namespace TspRing
{
    static const int TSP_RING_N = 600;

    struct Sample
    {
        double total_ms;
        double mech_ms;
        double spell_ms;
        double char_ms;
        double anim_ms;
        int nactors;
        int nforced;
    };

    inline Sample* buffer()
    {
        static Sample buf[TSP_RING_N];
        return buf;
    }

    inline unsigned long& counter()
    {
        static unsigned long n = 0;
        return n;
    }

    /* accumulators for the frame currently being built */
    inline double& mechAcc()  { static double v = 0; return v; }
    inline double& spellAcc() { static double v = 0; return v; }
    inline double& charAcc()  { static double v = 0; return v; }
    inline double& animAcc()  { static double v = 0; return v; }
    inline int&    actorAcc() { static int v = 0; return v; }
    inline int&    forceAcc() { static int v = 0; return v; }

    inline double nowMs()
    {
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
    }

    inline void endFrame(double totalMs)
    {
        unsigned long n = counter()++;
        Sample& s = buffer()[n % TSP_RING_N];
        s.total_ms = totalMs;
        s.mech_ms  = mechAcc();
        s.spell_ms = spellAcc();
        s.char_ms  = charAcc();
        s.anim_ms  = animAcc();
        s.nactors  = actorAcc();
        s.nforced  = forceAcc();
        mechAcc() = spellAcc() = charAcc() = animAcc() = 0.0;
        actorAcc() = forceAcc() = 0;
    }

    inline void dump()
    {
        const char* p = getenv("OPENMW_TSP_RING");
        if (!p || !p[0])
            return;
        FILE* f = fopen(p, "w");
        if (!f)
            return;
        unsigned long n = counter();
        unsigned long start = (n > (unsigned long)TSP_RING_N) ? n - TSP_RING_N : 0;
        fprintf(f, "# last %lu frames of %lu\n",
                n - start, n);
        fprintf(f, "# frame total_ms mech_ms spell_ms char_ms anim_ms nactors nforced\n");
        for (unsigned long i = start; i < n; i++)
        {
            const Sample& s = buffer()[i % TSP_RING_N];
            fprintf(f, "%lu %.2f %.2f %.2f %.2f %.2f %d %d\n",
                    i, s.total_ms, s.mech_ms, s.spell_ms,
                    s.char_ms, s.anim_ms, s.nactors, s.nforced);
        }
        fclose(f);
    }

    /* RAII accumulator - adds its lifetime to the given accumulator */
    struct Acc
    {
        double* target;
        double t0;
        explicit Acc(double* t) : target(t), t0(nowMs()) {}
        ~Acc() { *target += nowMs() - t0; }
    };
}
'''


def backup(path):
    shutil.copy(path, path + ".before-ringprof-" + time.strftime("%Y%m%d-%H%M%S"))


def revert():
    n = 0
    for f in glob.glob(SRC + "/**/*.before-ringprof-*", recursive=True):
        orig = f.split(".before-ringprof-")[0]
        shutil.copy(f, orig)
        print("  restored", os.path.basename(orig))
        n += 1
    print("reverted %d file(s)" % n)
    return 0


def patch_engine():
    """Hook frame start/end and the exit dump in engine.cpp."""
    p = SRC + "/engine.cpp"
    src = open(p).read()
    if "TSP_RINGPROF" in src:
        print("engine.cpp already patched")
        return True

    m = re.search(r'\n(#include [^\n]+\n)(?![\s\S]*?\n#include )', src)
    if not m:
        print("engine.cpp: could not find include block")
        return False
    src = src[:m.end()] + RING_HEADER + src[m.end():]

    # frame boundary: OMW::Engine::frame
    m2 = re.search(r'(void OMW::Engine::frame\([^)]*\)\s*\{)', src)
    if not m2:
        print("engine.cpp: could not find Engine::frame")
        return False
    src = src[:m2.end()] + '''
    double tspFrameT0 = TspRing::nowMs();
    struct TspFrameEnd {
        double t0;
        explicit TspFrameEnd(double t) : t0(t) {}
        ~TspFrameEnd() { TspRing::endFrame(TspRing::nowMs() - t0); }
    } tspFrameEnd(tspFrameT0);
''' + src[m2.end():]

    # dump at the end of go()
    m3 = re.search(r'(void OMW::Engine::go\(\)\s*\{)', src)
    if m3:
        # find the closing of the main loop function by inserting a guard object
        src = src[:m3.end()] + '''
    struct TspDumpAtExit { ~TspDumpAtExit() { TspRing::dump(); } } tspDumpAtExit;
''' + src[m3.end():]
    else:
        print("engine.cpp: WARNING - could not find Engine::go, dump may not run")

    backup(p)
    open(p, "w").write(src)
    print("engine.cpp patched")
    return True


def patch_simple(relpath, sig_regex, accessor, label, extra=None):
    """Insert an Acc at the top of a function body."""
    p = SRC + "/" + relpath
    src = open(p).read()
    if "TspRing::Acc" in src and label in src:
        print("%s already patched" % relpath)
        return True

    if "TspRing" not in src:
        m = re.search(r'\n(#include [^\n]+\n)(?![\s\S]*?\n#include )', src)
        if not m:
            print("%s: no include block" % relpath)
            return False
        src = src[:m.end()] + '\n#include "../engine.hpp"\n' + src[m.end():]

    m2 = re.search(sig_regex, src)
    if not m2:
        print("%s: signature not found (%s)" % (relpath, label))
        return False
    ins = '\n        TspRing::Acc tspAcc%s(&TspRing::%s());' % (label, accessor)
    if extra:
        ins += "\n        " + extra
    src = src[:m2.end()] + ins + src[m2.end():]

    backup(p)
    open(p, "w").write(src)
    print("%s patched (%s)" % (relpath, label))
    return True


def main():
    if "--revert" in sys.argv:
        return revert()

    ok = True
    ok &= patch_engine()
    print()
    print("NOTE: the accumulators live in engine.cpp. If the mechanics files")
    print("cannot see them, only total_ms will be populated - that alone still")
    print("shows the per-frame spike shape, which is the main thing needed.")
    return 0 if ok else 1


sys.exit(main())
