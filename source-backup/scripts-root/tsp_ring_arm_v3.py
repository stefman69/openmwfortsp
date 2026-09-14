#!/usr/bin/env python3
"""
tsp_ring_arm_v3.py - measure the rest of the frame

WHAT V2 MISSED, AND HOW WE KNOW
===============================

V2 recorded frames for the first time. Two of the biggest events it caught
had almost nothing in any scope:

    frame 5742   329.0 ms total, 35.9 accounted   -> 293 ms unowned
    frame 8862   330.1 ms total, ~33 accounted    -> 297 ms unowned

Steve identified both: an autosave, and a manual save just before exit.
Reading Engine::frame (engine.cpp 402-616) shows why nothing owned them -
most of the frame was never measured:

    443  mInputManager->update       <- MyGUI dispatch, i.e. the save dialog
    476  mStateManager->update       <- AUTOSAVE lives here
    493  executeLocalScripts         <- MWScript. NOT the same as the lua slot
    496  getGlobalScripts().run      <- MWScript
    536  mWorld->updatePhysics       <- TSP_SLOT_PHYS existed, never wired
    566  mUnrefQueue->flush
    592  mWorld->updateFocusObject
    613  mLuaWorker->finishUpdate    <- and V2 put the frame boundary ABOVE
                                        this, so the wait for the Lua worker
                                        thread fell outside the frame and
                                        rolled into the next one

WHAT THIS DOES
==============

  apps/openmw/tspprof.h    replaced with V3 (18 slots, names written into the
                           dump header so the analyzer reads them from the
                           file instead of hardcoding them)

  apps/openmw/engine.cpp   a TSP_SCOPE on every call above, and the frame
                           boundary MOVED from above finishUpdate to below it

  apps/openmw/mwmechanics/actors.cpp
                           Actors::update moves from TSP_SLOT_MECH to
                           TSP_SLOT_ACTORS, ending the double count

THE MECH DOUBLE COUNT IS FIXED, SO OLD NUMBERS DO NOT COMPARE
=============================================================

V1 and V2 scoped both engine.cpp's MechanicsManager::update and actors.cpp's
Actors::update into TSP_SLOT_MECH, and the second nests inside the first, so
that slot read roughly double. V3 splits them. mech numbers from earlier runs
are not comparable with V3.

THE ACCOUNTING MODEL
====================

  top level (siblings, should sum to ~the frame total):
      input sound lua state script mech phys world gui unref event updt
      focus render luawait

  nested (inside a top-level slot, never added to that sum):
      actors  inside mech
      char    inside actors
      spell   inside actors

APPLY
=====

    sudo docker cp ~/Downloads/tspprof_v3.h        openmw_builder:/root/
    sudo docker cp ~/Downloads/tsp_ring_arm_v3.py  openmw_builder:/root/
    sudo docker exec -i openmw_builder python3 /root/tsp_ring_arm_v3.py

Reports state before and after. Backs up every file. Idempotent. Every anchor
must match EXACTLY ONCE or nothing is written at all - and it prints which
anchor failed and how many times it matched.

REVERT
======

    sudo docker exec -i openmw_builder sh -c \\
      'cd /root/openmw-0.51-tsp-src && \\
       for f in apps/openmw/tspprof.h apps/openmw/engine.cpp \\
                apps/openmw/mwmechanics/actors.cpp; do \\
         ls -t "$f".tspring3-* 2>/dev/null | head -1 | xargs -I{} cp {} "$f"; \\
       done'
"""

import os
import re
import sys
import time

SRCROOT = "/root/openmw-0.51-tsp-src"
HEADER = os.path.join(SRCROOT, "apps/openmw/tspprof.h")
ENGINE = os.path.join(SRCROOT, "apps/openmw/engine.cpp")
ACTORS = os.path.join(SRCROOT, "apps/openmw/mwmechanics/actors.cpp")
NEWHEADER = "/root/tspprof_v3.h"

STAMP = time.strftime("%Y%m%d-%H%M%S")
MARKER = "TSP_PROF_RING_V3"
BOUNDARY_MARKER = "TSP_PROF_FRAME_BOUNDARY_V3"

# statement -> slot. Each must appear exactly once, at any indentation.
SCOPES = [
    ("TSP_SLOT_INPUT",   r'mInputManager->update\(frametime, tspFrozen\);'),
    ("TSP_SLOT_STATE",   r'mStateManager->update\(frametime\);'),
    ("TSP_SLOT_SCRIPT",  r'executeLocalScripts\(\);'),
    ("TSP_SLOT_SCRIPT",  r'mScriptManager->getGlobalScripts\(\)\.run\(\);'),
    ("TSP_SLOT_PHYS",    r'mWorld->updatePhysics\(frametime, paused, frameStart, frameNumber, \*stats\);'),
    ("TSP_SLOT_UNREF",   r'mUnrefQueue->flush\(\*mWorkQueue\);'),
    ("TSP_SLOT_FOCUS",   r'mWorld->updateFocusObject\(\);'),
    ("TSP_SLOT_LUAWAIT", r'mLuaWorker->finishUpdate\(frameStart, frameNumber, \*stats\);'),
]

# the V2 boundary block, to be removed before the V3 one is placed
V2_BOUNDARY_RE = re.compile(
    r'\n[ \t]*// TSP_PROF_FRAME_BOUNDARY_V2\n'
    r'(?:[ \t]*//[^\n]*\n)*'
    r'[ \t]*TspProf::endFrame\(\);\n'
    r'[ \t]*TspProf::dumpAtExit\(\);'
)

LUAWAIT_SCOPED_RE = re.compile(
    r'(?P<indent>[ \t]*)\{[ \t]*TSP_SCOPE\(TspProf::TSP_SLOT_LUAWAIT\);[ \t]*'
    r'mLuaWorker->finishUpdate\(frameStart, frameNumber, \*stats\);[ \t]*\}'
)

BOUNDARY = '''
{i}// TSP_PROF_FRAME_BOUNDARY_V3
{i}// The true end of the frame body. V2 placed this ABOVE
{i}// mLuaWorker->finishUpdate(), so the wait for the Lua worker thread fell
{i}// outside the frame and rolled into the next one's total.
{i}//
{i}// dumpAtExit() is called every frame rather than once at some shutdown
{i}// site: a function-local static costs one guard load and cannot be missed
{i}// by a code path that happens not to run. The exit dump is only a fallback
{i}// anyway - the trigger in tspprof.h is what catches a dip, since a crash
{i}// or a kill never runs a static destructor.
{i}TspProf::endFrame();
{i}TspProf::dumpAtExit();'''

ACTORS_OLD = "TSP_SCOPE(TspProf::TSP_SLOT_MECH); // Actors::update"
ACTORS_NEW = "TSP_SCOPE(TspProf::TSP_SLOT_ACTORS); // Actors::update"


def report(path, checks):
    print("  --- %s" % path)
    if not os.path.isfile(path):
        print("      MISSING")
        return None
    s = open(path, encoding="utf-8").read()
    for label, needle in checks:
        print("      %-38s x%d" % (label, s.count(needle)))
    return s


def main():
    print()
    print("  tsp_ring_arm_v3")
    print("  ===============")
    print()
    print("  BEFORE:")
    hs = report(HEADER, [("TSP_PROF_RING_V3", "TSP_PROF_RING_V3"),
                         ("TSP_PROF_RING_V2", "TSP_PROF_RING_V2"),
                         ("TSP_SLOT_LUAWAIT", "TSP_SLOT_LUAWAIT")])
    es = report(ENGINE, [("boundary V2", "TSP_PROF_FRAME_BOUNDARY_V2"),
                         ("boundary V3", "TSP_PROF_FRAME_BOUNDARY_V3"),
                         ("TSP_SCOPE total", "TSP_SCOPE(")])
    a_s = report(ACTORS, [("SLOT_MECH", "TSP_SLOT_MECH"),
                          ("SLOT_ACTORS", "TSP_SLOT_ACTORS")])
    print()

    if hs is None or es is None or a_s is None:
        print("  ERROR: a target file is missing - NOTHING WRITTEN.")
        return 1
    if not os.path.isfile(NEWHEADER):
        print("  ERROR: %s not found. Copy it in first:" % NEWHEADER)
        print("      sudo docker cp ~/Downloads/tspprof_v3.h openmw_builder:/root/")
        return 1

    new_header = open(NEWHEADER, encoding="utf-8").read()
    if MARKER not in new_header:
        print("  ERROR: %s does not contain %s - wrong file?" % (NEWHEADER, MARKER))
        return 1

    plans = []
    fail = False

    # ---------------- header ----------------
    if hs == new_header:
        print("  no change needed  tspprof.h already at V3")
    else:
        plans.append((HEADER, hs, new_header, "tspprof.h -> V3"))

    # ---------------- engine.cpp ----------------
    if BOUNDARY_MARKER in es:
        print("  no change needed  engine.cpp already at V3")
    else:
        work = es

        # remove the V2 boundary if present
        if "TSP_PROF_FRAME_BOUNDARY_V2" in work:
            work, n = V2_BOUNDARY_RE.subn("", work, count=1)
            if n != 1 or "TSP_PROF_FRAME_BOUNDARY_V2" in work:
                print("  ANCHOR MISS      could not cleanly remove the V2 boundary block")
                fail = True
            else:
                print("  removed          V2 frame boundary")

        # add the scopes
        for slot, pat in SCOPES:
            already = re.compile(
                r'\{[ \t]*TSP_SCOPE\(TspProf::%s\);[ \t]*%s' % (slot, pat))
            if already.search(work):
                print("  already present  %-16s %s" % (slot, pat[:44]))
                continue

            full = re.compile(r'(?P<indent>[ \t]*)(?P<stmt>%s)' % pat)
            hits = full.findall(work)
            if len(hits) != 1:
                print("  ANCHOR MISS      %-16s matched %d times, need exactly 1"
                      % (slot, len(hits)))
                print("                   pattern: %s" % pat)
                fail = True
                continue

            m = full.search(work)
            work = (work[:m.start()]
                    + "%s{ TSP_SCOPE(TspProf::%s); %s }" % (m.group("indent"), slot, m.group("stmt"))
                    + work[m.end():])
            print("  applied          %-16s %s" % (slot, pat[:44]))

        # place the V3 boundary after the luawait scope
        if not fail:
            m = LUAWAIT_SCOPED_RE.search(work)
            if not m:
                print("  ANCHOR MISS      luawait scope not found for the boundary")
                fail = True
            else:
                work = (work[:m.end()]
                        + BOUNDARY.format(i=m.group("indent"))
                        + work[m.end():])
                print("  applied          V3 frame boundary (below finishUpdate)")
                plans.append((ENGINE, es, work, "engine.cpp scopes + boundary"))

    # ---------------- actors.cpp ----------------
    if ACTORS_NEW in a_s:
        print("  no change needed  actors.cpp already on TSP_SLOT_ACTORS")
    elif a_s.count(ACTORS_OLD) == 1:
        plans.append((ACTORS, a_s, a_s.replace(ACTORS_OLD, ACTORS_NEW, 1),
                      "actors.cpp MECH -> ACTORS"))
        print("  applied          actors.cpp MECH -> ACTORS (ends double count)")
    else:
        print("  ANCHOR MISS      actors.cpp: found %d of\n                   %s"
              % (a_s.count(ACTORS_OLD), ACTORS_OLD))
        fail = True

    if fail:
        print()
        print("  ONE OR MORE ANCHORS MISSED - NOTHING WRITTEN.")
        return 1

    if not plans:
        print()
        print("  VERIFIED: nothing to do, already at V3.")
        return 0

    print()
    for path, old, new, what in plans:
        backup = path + ".tspring3-" + STAMP
        open(backup, "w", encoding="utf-8").write(old)
        open(path, "w", encoding="utf-8").write(new)
        print("  backup   %s" % backup)
        print("  written  %s   (%s)" % (path, what))

    print()
    print("  AFTER:")
    report(HEADER, [("TSP_PROF_RING_V3", "TSP_PROF_RING_V3")])
    report(ENGINE, [("boundary V2 (must be 0)", "TSP_PROF_FRAME_BOUNDARY_V2"),
                    ("boundary V3 (must be 1)", "TSP_PROF_FRAME_BOUNDARY_V3"),
                    ("TSP_SCOPE total (expect 16)", "TSP_SCOPE(")])
    report(ACTORS, [("SLOT_ACTORS (must be 1)", "TSP_SLOT_ACTORS")])
    print()
    print("  VERIFIED: %d file(s) written" % len(plans))
    return 0


if __name__ == "__main__":
    sys.exit(main())