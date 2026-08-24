#!/usr/bin/env python3
"""
tsp_prof_fix_v4.py - fix the include that escapes the source tree, and remove
                     the endFrame() call I should never have added

TWO BUGS, BOTH FOUND BY THE SAME COMMAND
========================================

1. THE FRAME BOUNDARY ALREADY EXISTED

       engine.cpp:407
           struct TspFrameGuard { ~TspFrameGuard() { TspProf::endFrame(); } }
               tspFrameGuard;

   An RAII guard at the top of Engine::frame() that calls endFrame() on
   return. Present since at least 2026-08-18 (it is in
   engine.cpp.before-phases-20260818-092221).

   I claimed endFrame() was never called, on the strength of a grep for
   "TSP_SCOPE|TSP_RING|tspprof". That line contains TspProf with a capital P
   and none of the other three patterns, so the search could not have found
   it. The V2 patch then added a second call, and the ring recorded exactly
   one phantom per real frame: two endFrame() calls microseconds apart, the
   second with nothing accumulated. Measured on device:

       4767  0.00   every slot 0.00   every call 0
       4768 40.21   render 33.74      calls 1 0 0 0 0 0 1 1 1 1 1 1 1
       4769  0.00   every slot 0.00   every call 0

   The guard is also better placed than my call: it destructs at function
   return, AFTER mLuaWorker->finishUpdate(), so it closes the whole frame.
   Mine goes. The guard stays. dumpAtExit() stays too - the guard does not
   do that.

2. THE mwmechanics INCLUDES ESCAPE THE SOURCE TREE

       apps/openmw/mwmechanics/{actors,character,activespells}.cpp
           #include "../../tspprof.h"

   From apps/openmw/mwmechanics/ that is apps/tspprof.h, which DOES NOT
   EXIST. GCC then falls through to -I/root/openmw-0.51-tsp-src/. and
   resolves . + ../../tspprof.h to /root/tspprof.h - a stale copy beside the
   source tree, not in it.

   So three of the four instrumented files have been compiling against a
   header outside the repository. It only surfaced when V3 added
   TSP_SLOT_ACTORS to the real header and actors.cpp could not see it.

   Worse than a build error: two definitions of namespace TspProf, both full
   of inline functions holding function-local statics, is an ODR violation.
   The linker picks one arbitrarily. If the copies ever disagreed about
   TSP_SLOT_COUNT, sizeof(Frame) would differ between translation units and
   slot writes would run off the end of the array. The build error is the
   lucky outcome.

   Fixed by spelling the include "../tspprof.h", which resolves inside the
   tree to apps/openmw/tspprof.h. The stray /root/tspprof.h is renamed so it
   can never be picked up again.

APPLY
=====

    sudo docker cp ~/Downloads/tsp_prof_fix_v4.py openmw_builder:/root/
    sudo docker exec -i openmw_builder python3 /root/tsp_prof_fix_v4.py

Reports every candidate resolution for every include before it changes
anything. Backs up every file. Idempotent. Writes nothing on an anchor miss.
"""

import os
import re
import sys
import time

SRCROOT = "/root/openmw-0.51-tsp-src"
CANON = os.path.join(SRCROOT, "apps/openmw/tspprof.h")
ENGINE = os.path.join(SRCROOT, "apps/openmw/engine.cpp")
STAMP = time.strftime("%Y%m%d-%H%M%S")

# -I dirs from the real compile line, in order, for the quoted-include fallback
IDIRS = [os.path.join(SRCROOT, ".")]

INC_RE = re.compile(r'^([ \t]*#[ \t]*include[ \t]+")([^"]*tspprof\.h)(")', re.M)

# my redundant call, with the V3 comment block above it
ENDFRAME_RE = re.compile(
    r'\n([ \t]*)// TSP_PROF_FRAME_BOUNDARY_V3\n'
    r'(?:[ \t]*//[^\n]*\n)*'
    r'[ \t]*TspProf::endFrame\(\);\n'
    r'([ \t]*)TspProf::dumpAtExit\(\);'
)

REPLACEMENT = '''
{i}// TSP_PROF_FRAME_BOUNDARY_V4
{i}// endFrame() is NOT called here. It is already called by the RAII guard at
{i}// the top of this function:
{i}//
{i}//     struct TspFrameGuard  ->  its destructor calls endFrame()
{i}//     declared at the top of this function as tspFrameGuard
{i}//
{i}// which fires on return - after mLuaWorker->finishUpdate() - and so closes
{i}// the whole frame. V2 added a second call right here, and the ring then
{i}// recorded one phantom per real frame: two endFrame() calls microseconds
{i}// apart, the second with zero elapsed and zero calls in every slot.
{i}//
{i}// dumpAtExit() still belongs here. The guard does not do it, and a
{i}// function-local static costs one guard load per frame and cannot be
{i}// missed by a code path that happens not to run.
{i}TspProf::dumpAtExit();'''


def resolve_candidates(including_file, spelling):
    """Every path GCC would try for a quoted include, in order."""
    out = [os.path.normpath(os.path.join(os.path.dirname(including_file), spelling))]
    for d in IDIRS:
        out.append(os.path.normpath(os.path.join(d, spelling)))
    return out


def scan():
    rows = []
    for root, dirs, files in os.walk(SRCROOT):
        dirs[:] = [d for d in dirs if d not in (".git", "build")]
        for fn in files:
            if not fn.endswith((".cpp", ".hpp", ".h", ".cc")):
                continue
            p = os.path.join(root, fn)
            if os.path.basename(p) == "tspprof.h":
                continue
            # skip our own timestamped backups
            if re.search(r'\.(tspring\d|tsppurge\d+|before-|tspdedupe)', p):
                continue
            try:
                s = open(p, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            for m in INC_RE.finditer(s):
                rows.append((p, m.group(2)))
    return rows


def main():
    print()
    print("  tsp_prof_fix_v4")
    print("  ===============")
    print()

    rows = scan()
    print("  EVERY tspprof.h INCLUDE AND EVERY PATH GCC WOULD TRY")
    strays = set()
    needs_fix = []
    for path, spelling in rows:
        rel = os.path.relpath(path, SRCROOT)
        print("    %s" % rel)
        print('        spelled  "%s"' % spelling)
        hit = None
        for cand in resolve_candidates(path, spelling):
            exists = os.path.isfile(cand)
            inside = os.path.abspath(cand).startswith(os.path.abspath(SRCROOT) + os.sep)
            mark = ""
            if exists and hit is None:
                hit = cand
                mark = "   <== THIS ONE WINS"
                if not inside:
                    mark += "   *** OUTSIDE THE SOURCE TREE ***"
                    strays.add(cand)
            print("        %-58s %s%s"
                  % (cand, "exists" if exists else "missing", mark))
        if hit is None:
            print("        NOTHING RESOLVES - this file could not be compiling")
        elif os.path.abspath(hit) != os.path.abspath(CANON):
            needs_fix.append((path, spelling))
        print()

    if not os.path.isfile(CANON):
        print("  ERROR: canonical header %s missing - NOTHING WRITTEN." % CANON)
        return 1

    plans = []

    # ---- include spellings -------------------------------------------------
    for path, spelling in needs_fix:
        want = os.path.relpath(CANON, os.path.dirname(path)).replace(os.sep, "/")
        target = os.path.normpath(os.path.join(os.path.dirname(path), want))
        if os.path.abspath(target) != os.path.abspath(CANON):
            print("  ERROR: computed %s for %s but it resolves to %s - NOTHING WRITTEN."
                  % (want, os.path.relpath(path, SRCROOT), target))
            return 1
        s = open(path, encoding="utf-8").read()
        new = INC_RE.sub(lambda m: m.group(1) + want + m.group(3), s)
        if new == s:
            print("  ANCHOR MISS      could not rewrite the include in %s"
                  % os.path.relpath(path, SRCROOT))
            return 1
        plans.append((path, s, new,
                      'include "%s" -> "%s"' % (spelling, want)))

    if not needs_fix:
        print("  no change needed  every include already reaches the canonical header")

    # ---- the redundant endFrame -------------------------------------------
    es = open(ENGINE, encoding="utf-8").read()
    if "TSP_PROF_FRAME_BOUNDARY_V4" in es:
        print("  no change needed  engine.cpp already at V4 (guard only)")
    else:
        m = ENDFRAME_RE.search(es)
        if not m:
            print("  ANCHOR MISS      V3 boundary block not found in engine.cpp")
            at = es.find("TspProf::endFrame")
            if at >= 0:
                lo = es.rfind("\n", 0, max(0, at - 600)) + 1
                hi = es.find("\n", at + 400)
                print("  current text around endFrame:")
                for ln in es[lo:hi if hi > 0 else len(es)].split("\n"):
                    print("      | " + ln)
            print("\n  NOTHING WRITTEN.")
            return 1
        new = es[:m.start()] + REPLACEMENT.format(i=m.group(1)) + es[m.end():]
        n_after = sum(1 for ln in new.split("\n")
                      if "TspProf::endFrame" in ln and not ln.lstrip().startswith("//"))
        if n_after != 1:
            print("  ERROR: expected exactly 1 real endFrame call left (the guard),"
                  " found %d" % n_after)
            return 1
        plans.append((ENGINE, es, new, "remove the redundant endFrame(); keep the guard"))
        print("  applied          engine.cpp: drop my endFrame, keep the RAII guard")

    if not plans and not strays:
        print()
        print("  VERIFIED: nothing to do.")
        return 0

    print()
    for path, old, new, what in plans:
        backup = path + ".tspfix4-" + STAMP
        open(backup, "w", encoding="utf-8").write(old)
        open(path, "w", encoding="utf-8").write(new)
        print("  written  %s" % os.path.relpath(path, SRCROOT))
        print("    %s" % what)
        print("    backup %s" % os.path.basename(backup))

    # ---- neutralise strays -------------------------------------------------
    for stray in sorted(strays):
        dest = stray + ".NOT-THE-REAL-HEADER-" + STAMP
        try:
            os.rename(stray, dest)
            print("  RENAMED  %s" % stray)
            print("    -> %s" % dest)
            print("    It was outside the source tree and was being picked up by the")
            print("    -I fallback. Nothing references it now.")
        except OSError as e:
            print("  could not rename %s: %s" % (stray, e))

    print()
    print("  AFTER")
    for path, spelling in scan():
        rel = os.path.relpath(path, SRCROOT)
        hit = None
        for cand in resolve_candidates(path, spelling):
            if os.path.isfile(cand):
                hit = cand
                break
        ok = hit and os.path.abspath(hit) == os.path.abspath(CANON)
        print("    %-46s \"%s\"  ->  %s"
              % (rel, spelling,
                 "canonical header" if ok else ("%s  <== WRONG" % hit)))
    print("    engine.cpp real endFrame call sites: %d  (must be 1 - the guard)"
          % sum(1 for ln in open(ENGINE, encoding="utf-8").read().split("\n")
                if "TspProf::endFrame" in ln and not ln.lstrip().startswith("//")))
    print()
    print("  VERIFIED: %d file(s) written, %d stray header(s) renamed"
          % (len(plans), len(strays)))
    return 0


if __name__ == "__main__":
    sys.exit(main())