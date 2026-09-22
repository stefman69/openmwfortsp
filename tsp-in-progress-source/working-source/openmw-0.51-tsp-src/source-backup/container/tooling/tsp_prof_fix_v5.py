#!/usr/bin/env python3
"""
tsp_prof_fix_v5.py - rewrite the tspprof.h includes unconditionally

WHY v4 DID NOTHING
==================

v4 tried to predict which file GCC would open for each #include, and only
rewrote the ones it predicted were wrong. Two failures:

  1. The path arithmetic was wrong. -I/root/openmw-0.51-tsp-src/. plus
     "../../tspprof.h" is /tspprof.h, not /root/tspprof.h - two levels up
     from /root/openmw-0.51-tsp-src is /. And the compile line has a dozen
     more -I and -isystem dirs that v4 never modelled at all, one of which
     (-isystem /root/sdl2-2.30.12-install/include) DOES land on
     /root/tspprof.h.

  2. When no candidate resolved, v4 printed "NOTHING RESOLVES" and then
     skipped the fix:

         if hit is None:      print(...)          # and did nothing
         elif hit != CANON:   needs_fix.append(...)

     Exactly backwards. An include that cannot be resolved is the clearest
     case for rewriting there is.

v5 STOPS PREDICTING
===================

The correct spelling of that include is the relative path from the including
file to apps/openmw/tspprof.h, whatever GCC would otherwise have found. So
v5 computes that and writes it, unconditionally, for every #include of a
tspprof.h in the tree. No search-path model, nothing to get wrong.

    apps/openmw/engine.cpp                    "tspprof.h"       (already right)
    apps/openmw/mwmechanics/actors.cpp        "../tspprof.h"
    apps/openmw/mwmechanics/character.cpp     "../tspprof.h"
    apps/openmw/mwmechanics/activespells.cpp  "../tspprof.h"

Then it finds every tspprof.h on the whole filesystem - not by arithmetic,
by walking it - and renames any that is outside the source tree, so no -I or
-isystem fallback can ever shadow the real one again.

Each rewrite is verified by joining the including file's directory with the
new spelling and checking it lands on the canonical header. If it does not,
nothing is written.

WHY IT MATTERS BEYOND THE BUILD ERROR
=====================================

Two definitions of namespace TspProf, both full of inline functions holding
function-local statics, is an ODR violation. The linker picks one silently.
If the copies ever disagreed about TSP_SLOT_COUNT, sizeof(Frame) would differ
between translation units and slot writes would run off the end of the array.
The build error is the lucky outcome - the alternative was a heisenbug.

APPLY
=====

    sudo docker cp ~/Downloads/tsp_prof_fix_v5.py openmw_builder:/root/
    sudo docker exec -i openmw_builder python3 /root/tsp_prof_fix_v5.py

Backs up every file. Idempotent. Verifies every rewrite before writing.

REVERT
======

    sudo docker exec -i openmw_builder sh -c \\
      'cd /root/openmw-0.51-tsp-src/apps/openmw/mwmechanics && \\
       for f in actors.cpp character.cpp activespells.cpp; do \\
         ls -t "$f".tspfix5-* 2>/dev/null | head -1 | xargs -I{} cp {} "$f"; \\
       done'
"""

import os
import re
import sys
import time

SRCROOT = "/root/openmw-0.51-tsp-src"
CANON = os.path.join(SRCROOT, "apps/openmw/tspprof.h")
ENGINE = os.path.join(SRCROOT, "apps/openmw/engine.cpp")
STAMP = time.strftime("%Y%m%d-%H%M%S")

SKIP_DIRS = {"/proc", "/sys", "/dev", "/run", "/tmp"}

INC_RE = re.compile(r'^([ \t]*#[ \t]*include[ \t]+")([^"]*tspprof\.h)(")', re.M)
BACKUP_RE = re.compile(r'\.(tspring\d|tsppurge\d+|tspfix\d|tspdedupe|before-|tspvp|tsphandler)')

ENDFRAME_RE = re.compile(
    r'\n([ \t]*)// TSP_PROF_FRAME_BOUNDARY_V3\n'
    r'(?:[ \t]*//[^\n]*\n)*'
    r'[ \t]*TspProf::endFrame\(\);\n'
    r'([ \t]*)TspProf::dumpAtExit\(\);'
)

REPLACEMENT = '''
{i}// TSP_PROF_FRAME_BOUNDARY_V4
{i}// endFrame() is NOT called here. The RAII guard declared at the top of this
{i}// function as tspFrameGuard already calls it from its destructor, which
{i}// fires on return - after mLuaWorker->finishUpdate() - and so closes the
{i}// whole frame.
{i}//
{i}// V2 added a second call right here, and the ring then recorded one phantom
{i}// per real frame: two calls microseconds apart, the second with zero elapsed
{i}// and zero calls in every slot.
{i}//
{i}// dumpAtExit() still belongs here. The guard does not do it, and a
{i}// function-local static costs one guard load per frame and cannot be missed
{i}// by a code path that happens not to run.
{i}TspProf::dumpAtExit();'''


def find_all_headers():
    """Every tspprof.h on the filesystem. Walked, not predicted."""
    out = []
    for root, dirs, files in os.walk("/", topdown=True):
        dirs[:] = [d for d in dirs
                   if os.path.join(root, d) not in SKIP_DIRS
                   and not os.path.islink(os.path.join(root, d))]
        if "tspprof.h" in files:
            out.append(os.path.join(root, "tspprof.h"))
    return sorted(out)


def sources_with_include():
    rows = []
    for root, dirs, files in os.walk(SRCROOT):
        dirs[:] = [d for d in dirs if d not in (".git", "build")]
        for fn in files:
            if not fn.endswith((".cpp", ".hpp", ".h", ".cc")):
                continue
            p = os.path.join(root, fn)
            if os.path.basename(p) == "tspprof.h" or BACKUP_RE.search(p):
                continue
            try:
                s = open(p, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            m = INC_RE.search(s)
            if m:
                rows.append((p, m.group(2), s))
    return sorted(rows)


def main():
    print()
    print("  tsp_prof_fix_v5")
    print("  ===============")
    print()

    if not os.path.isfile(CANON):
        print("  ERROR: canonical header %s missing - NOTHING WRITTEN." % CANON)
        return 1

    print("  EVERY tspprof.h ON THE FILESYSTEM   (walked, not computed)")
    headers = find_all_headers()
    strays = []
    for h in headers:
        inside = os.path.abspath(h).startswith(os.path.abspath(SRCROOT) + os.sep)
        canon = os.path.abspath(h) == os.path.abspath(CANON)
        tag = "CANONICAL" if canon else ("in tree" if inside else "STRAY - can shadow")
        print("    %-56s %8d bytes   %s" % (h, os.path.getsize(h), tag))
        if not canon:
            strays.append(h)
    if len(headers) == 1:
        print("    (only one - good)")
    print()

    rows = sources_with_include()
    print("  REWRITING EVERY INCLUDE TO THE CANONICAL HEADER")
    plans = []
    for path, spelling, s in rows:
        want = os.path.relpath(CANON, os.path.dirname(path)).replace(os.sep, "/")
        check = os.path.normpath(os.path.join(os.path.dirname(path), want))
        if os.path.abspath(check) != os.path.abspath(CANON):
            print("  ERROR: for %s computed \"%s\" which lands on %s - NOTHING WRITTEN."
                  % (os.path.relpath(path, SRCROOT), want, check))
            return 1

        if spelling == want:
            print("    %-46s \"%s\"   already correct"
                  % (os.path.relpath(path, SRCROOT), spelling))
            continue

        new = INC_RE.sub(lambda m: m.group(1) + want + m.group(3), s)
        if new == s:
            print("  ANCHOR MISS      could not rewrite %s - NOTHING WRITTEN."
                  % os.path.relpath(path, SRCROOT))
            return 1
        print("    %-46s \"%s\"  ->  \"%s\""
              % (os.path.relpath(path, SRCROOT), spelling, want))
        plans.append((path, s, new, "include -> \"%s\"" % want))
    print()

    # ---- the redundant endFrame -------------------------------------------
    es = open(ENGINE, encoding="utf-8").read()
    if "TSP_PROF_FRAME_BOUNDARY_V4" in es:
        print("  no change needed  engine.cpp already at V4 (guard only)")
    else:
        m = ENDFRAME_RE.search(es)
        if not m:
            print("  ANCHOR MISS      V3 boundary block not found in engine.cpp")
            return 1
        new = es[:m.start()] + REPLACEMENT.format(i=m.group(1)) + es[m.end():]
        real = [ln for ln in new.split("\n")
                if "TspProf::endFrame" in ln and not ln.lstrip().startswith("//")]
        if len(real) != 1:
            print("  ERROR: expected 1 real endFrame call (the guard), found %d"
                  % len(real))
            return 1
        plans.append((ENGINE, es, new, "drop the redundant endFrame; keep the guard"))
        print("  applied          engine.cpp: drop my endFrame, keep the RAII guard")

    print()
    for path, old, new, what in plans:
        backup = path + ".tspfix5-" + STAMP
        open(backup, "w", encoding="utf-8").write(old)
        open(path, "w", encoding="utf-8").write(new)
        print("  written  %-52s %s" % (os.path.relpath(path, SRCROOT), what))
        print("    backup %s" % os.path.basename(backup))

    for stray in strays:
        dest = stray + ".NOT-THE-REAL-HEADER-" + STAMP
        try:
            os.rename(stray, dest)
            print("  RENAMED  %s" % stray)
            print("    -> %s" % os.path.basename(dest))
            print("    Nothing references it now; it could only ever shadow.")
        except OSError as e:
            print("  could not rename %s: %s" % (stray, e))

    print()
    print("  AFTER   (each include joined with its own directory)")
    ok = True
    for path, spelling, _ in sources_with_include():
        landed = os.path.normpath(os.path.join(os.path.dirname(path), spelling))
        good = os.path.abspath(landed) == os.path.abspath(CANON)
        ok = ok and good
        print("    %-46s \"%s\"  ->  %s"
              % (os.path.relpath(path, SRCROOT), spelling,
                 "canonical header" if good else "%s   <== WRONG" % landed))
    real = [ln for ln in open(ENGINE, encoding="utf-8").read().split("\n")
            if "TspProf::endFrame" in ln and not ln.lstrip().startswith("//")]
    print("    engine.cpp real endFrame call sites: %d   (must be 1 - the guard)"
          % len(real))
    left = [h for h in find_all_headers()
            if os.path.abspath(h) != os.path.abspath(CANON)]
    print("    other tspprof.h left on the filesystem: %d   (must be 0)" % len(left))
    for h in left:
        print("      %s" % h)

    print()
    if not ok or len(real) != 1 or left:
        print("  NOT CLEAN - see the WRONG lines above.")
        return 1
    print("  VERIFIED: %d file(s) written, %d stray header(s) renamed"
          % (len(plans), len(strays)))
    return 0


if __name__ == "__main__":
    sys.exit(main())