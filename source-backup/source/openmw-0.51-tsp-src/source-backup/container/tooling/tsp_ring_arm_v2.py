#!/usr/bin/env python3
"""
tsp_ring_arm_v2.py - turn the frame profiler on, because it has never run

WHAT IS WRONG RIGHT NOW
=======================

tspprof.h is compiled into every build you have made and has never recorded a
single frame. Three independent reasons, each sufficient on its own:

  1. TspProf::endFrame() is not called from anywhere. Nothing advances
     frameNo(), so it stays 0, ring()[0] is the only element ever written, and
     current() accumulates every frame since launch into one struct.

  2. TspProf::dumpAtExit() is not called either, so the static DumpAtExit is
     never constructed and its destructor never runs.

  3. OPENMW_TSP_RING is not exported by the launcher, so dump() returns at its
     first line regardless.

The grep that produced this conclusion matched TSP_SCOPE, TSP_RING and
tspprof, and found all 13 scope sites and nothing else. endFrame and
dumpAtExit appear in the header and nowhere in the tree.

WHAT THIS DOES
==============

  apps/openmw/tspprof.h   replaced wholesale with V2:

      - dumpTo(path, why) split out of dump(), so the ring can be written
        somewhere other than at exit
      - a TRIGGER: a frame over the threshold arms a countdown of a quarter
        ring; when it expires the ring is written to <base>.<n>. The dump
        therefore holds the spike, ~675 frames before it and ~225 after, and
        the I/O happens ~9 s later rather than during the spike
      - a cooldown of one full ring, and a hard cap on dump count
      - TSP_RING_CONFIG printed to stderr on the first frame, unconditionally.
        The launcher appends stderr to tsp_prog.txt, so that line is the
        liveness proof. Silence there means it is not running.
      - TSP_SCOPE macro fixed. V1 was
            TspProf::Scope tspScope##__LINE__(slot)
        and a##b suppresses expansion of b, so every scope variable is
        literally named tspScope__LINE__. Harmless until two scopes share a
        block, then it will not compile.

  apps/openmw/engine.cpp  gains the frame boundary, immediately after
                          renderingTraversals(), which is the last thing in
                          an OpenMW frame:

      TspProf::endFrame();
      TspProf::dumpAtExit();

TWO TRAPS WHEN READING THE OUTPUT
=================================

  TSP_SLOT_MECH IS DOUBLE COUNTED. engine.cpp:519 scopes
  MechanicsManager::update into MECH and actors.cpp:1499 scopes
  Actors::update into MECH, and the second nests inside the first. slot[mech]
  is roughly twice the real cost; calls[mech] reads 2. Left alone on purpose
  so numbers stay comparable with anything measured before; the analyzer
  flags it.

  PHYS, AI and ANIM have no TSP_SCOPE anywhere and will always read 0.00.
  That is "not measured", not "free". Physics time lands inside WORLD.

APPLY
=====

    sudo docker cp ~/Downloads/tspprof_new.h        openmw_builder:/root/
    sudo docker cp ~/Downloads/tsp_ring_arm_v2.py   openmw_builder:/root/
    sudo docker exec -i openmw_builder python3 /root/tsp_ring_arm_v2.py

Reports the current state of everything before it writes. Backs up both
files. Idempotent. Writes NOTHING if the engine.cpp anchor misses, and prints
the surrounding text so it can be re-anchored in one round trip.

REVERT
======

    sudo docker exec -i openmw_builder sh -c \\
      'cd /root/openmw-0.51-tsp-src/apps/openmw && \\
       for f in tspprof.h engine.cpp; do \\
         ls -t "$f".tspring2-* 2>/dev/null | head -1 | xargs -I{} cp {} "$f"; \\
       done'
"""

import os
import re
import sys
import time

SRCROOT = "/root/openmw-0.51-tsp-src"
HEADER = os.path.join(SRCROOT, "apps/openmw/tspprof.h")
ENGINE = os.path.join(SRCROOT, "apps/openmw/engine.cpp")
NEWHEADER = "/root/tspprof_new.h"

STAMP = time.strftime("%Y%m%d-%H%M%S")
MARKER = "TSP_PROF_RING_V2"
BOUNDARY_MARKER = "TSP_PROF_FRAME_BOUNDARY_V2"

RENDER_RE = re.compile(
    r'(?P<indent>[ \t]*)\{[ \t]*TSP_SCOPE\(TspProf::TSP_SLOT_RENDER\);[ \t]*'
    r'mViewer->renderingTraversals\(\);[ \t]*\}'
)

BOUNDARY = '''
{i}// TSP_PROF_FRAME_BOUNDARY_V2
{i}// renderingTraversals() is the last thing in an OpenMW frame, so this is
{i}// the frame boundary. Without it the ring never advances - frameNo() stays
{i}// 0 and every frame accumulates into one struct, which is what V1 did for
{i}// its entire life.
{i}//
{i}// dumpAtExit() is called here, every frame, rather than once at some
{i}// shutdown site. A function-local static costs one guard load per frame and
{i}// cannot be missed by a code path that happens not to run. The exit dump is
{i}// a fallback anyway - the trigger in tspprof.h is what actually catches a
{i}// dip, since a crash or a kill never runs a static destructor.
{i}TspProf::endFrame();
{i}TspProf::dumpAtExit();'''


def report(path, checks):
    print("  --- %s" % path)
    if not os.path.isfile(path):
        print("      MISSING")
        return None
    s = open(path, encoding="utf-8").read()
    for label, needle in checks:
        print("      %-34s x%d" % (label, s.count(needle)))
    return s


def main():
    print()
    print("  tsp_ring_arm_v2")
    print("  ===============")
    print()
    print("  BEFORE:")

    hs = report(HEADER, [
        ("TSP_PROF_RING_V2", "TSP_PROF_RING_V2"),
        ("dumpTo(", "dumpTo("),
        ("checkTrigger", "checkTrigger"),
        ("broken TSP_SCOPE define", "#define TSP_SCOPE(slot) TspProf::Scope tspScope##__LINE__"),
    ])
    es = report(ENGINE, [
        ("TspProf::endFrame()", "TspProf::endFrame()"),
        ("TspProf::dumpAtExit()", "TspProf::dumpAtExit()"),
        ("TSP_SLOT_RENDER scope", "TSP_SCOPE(TspProf::TSP_SLOT_RENDER)"),
        ("#include \"tspprof.h\"", '#include "tspprof.h"'),
    ])
    print()

    if hs is None or es is None:
        print("  ERROR: a target file is missing - NOTHING WRITTEN.")
        return 1

    if not os.path.isfile(NEWHEADER):
        print("  ERROR: %s not found." % NEWHEADER)
        print("  Copy it in first:")
        print("      sudo docker cp ~/Downloads/tspprof_new.h openmw_builder:/root/")
        return 1

    new_header = open(NEWHEADER, encoding="utf-8").read()
    if MARKER not in new_header:
        print("  ERROR: %s does not contain %s - wrong file?" % (NEWHEADER, MARKER))
        return 1

    plans = []

    # ---- header ----------------------------------------------------------
    if hs == new_header:
        print("  no change needed  tspprof.h already at V2")
    else:
        plans.append((HEADER, hs, new_header,
                      "tspprof.h -> V2" if MARKER not in hs else "tspprof.h -> V2 (refresh)"))

    # ---- engine.cpp ------------------------------------------------------
    if BOUNDARY_MARKER in es:
        print("  no change needed  engine.cpp frame boundary already present")
    else:
        m = RENDER_RE.search(es)
        if not m:
            print()
            print("  ANCHOR MISS      engine.cpp renderingTraversals scope")
            print("  Looking for, at any indentation:")
            print("      { TSP_SCOPE(TspProf::TSP_SLOT_RENDER); mViewer->renderingTraversals(); }")
            print()
            at = es.find("renderingTraversals")
            if at < 0:
                print("      renderingTraversals does not appear in engine.cpp at all.")
            else:
                lo = es.rfind("\n", 0, max(0, at - 500)) + 1
                hi = es.find("\n", at + 500)
                print("  Current text around it:")
                for ln in es[lo:hi if hi > 0 else len(es)].split("\n"):
                    print("      | " + ln)
            print()
            print("  NOTHING WRITTEN.")
            return 1

        indent = m.group("indent")
        insert = BOUNDARY.format(i=indent)
        es_new = es[:m.end()] + insert + es[m.end():]
        plans.append((ENGINE, es, es_new, "engine.cpp frame boundary"))

    if not plans:
        print()
        print("  VERIFIED: nothing to do, already armed.")
        return 0

    print()
    for path, old, new, what in plans:
        backup = path + ".tspring2-" + STAMP
        open(backup, "w", encoding="utf-8").write(old)
        open(path, "w", encoding="utf-8").write(new)
        print("  applied  %s" % what)
        print("    backup   %s" % backup)
        print("    written  %s" % path)

    print()
    print("  AFTER:")
    report(HEADER, [
        ("TSP_PROF_RING_V2", "TSP_PROF_RING_V2"),
        ("checkTrigger", "checkTrigger"),
        ("broken TSP_SCOPE define", "#define TSP_SCOPE(slot) TspProf::Scope tspScope##__LINE__"),
    ])
    report(ENGINE, [
        ("TspProf::endFrame()", "TspProf::endFrame()"),
        ("TspProf::dumpAtExit()", "TspProf::dumpAtExit()"),
    ])
    print()
    print("  VERIFIED: %d file(s) written" % len(plans))
    return 0


if __name__ == "__main__":
    sys.exit(main())