#!/usr/bin/env python3
"""
tsp_prof_header_dedupe.py - one tspprof.h, reachable from every include path

THE BUILD ERROR
===============

    actors.cpp:1499: error: 'TSP_SLOT_ACTORS' is not a member of 'TspProf';
                            did you mean 'TSP_SLOT_CHAR'?

TSP_SLOT_ACTORS is in the V3 header. actors.cpp does not see it because it
does not include that header:

    apps/openmw/engine.cpp                  #include "tspprof.h"
        -> apps/openmw/tspprof.h            <- the one every patch has hit

    apps/openmw/mwmechanics/actors.cpp      #include "../../tspprof.h"
    apps/openmw/mwmechanics/character.cpp   #include "../../tspprof.h"
    apps/openmw/mwmechanics/activespells.cpp
        -> apps/tspprof.h                   <- a SECOND, separate copy

apps/openmw/mwmechanics/ + ../.. = apps/, not apps/openmw/. So three of the
four instrumented files have been compiling against a different header the
whole time.

WHY THIS IS WORSE THAN A BUILD ERROR
====================================

Both copies declare namespace TspProf with inline functions holding
function-local statics - ring(), current(), frameNo(), lastFrameStart(). Two
non-identical definitions of the same inline function is an ODR violation.
The linker is free to pick either, silently, and it only has to pick one. If
the two copies ever disagree about TSP_SLOT_COUNT, sizeof(Frame) differs
between translation units and every slot index past the shorter one writes
out of bounds.

Nothing has crashed yet because the copies happened to agree. The build error
is the first time they diverged - which is lucky, because the alternative was
a heisenbug.

WHAT THIS DOES
==============

Finds every tspprof.h in the tree. Keeps apps/openmw/tspprof.h as the single
real header, and replaces every other copy with a one-line forwarder that
includes it by a correctly-computed relative path. Both include spellings then
reach the same file, and no future patch can update one and miss the other.

It also prints, for the record:
  - each copy's version markers before the change
  - every #include of a tspprof.h and what it resolves to
  - every TspProf::endFrame() call site, because the ring is recording exactly
    one phantom record per real frame and a second call site would explain it

APPLY
=====

    sudo docker cp ~/Downloads/tsp_prof_header_dedupe.py openmw_builder:/root/
    sudo docker exec -i openmw_builder python3 /root/tsp_prof_header_dedupe.py

Backs up every file it rewrites. Idempotent. Refuses to touch anything if the
canonical header is not at V3.
"""

import os
import re
import sys
import time

SRCROOT = "/root/openmw-0.51-tsp-src"
CANON = os.path.join(SRCROOT, "apps/openmw/tspprof.h")
STAMP = time.strftime("%Y%m%d-%H%M%S")
FORWARD_MARKER = "TSP_PROF_FORWARDER_V3"

FORWARDER = """// %s
//
// NOT the real header. The real one is apps/openmw/tspprof.h.
//
// This path exists because the mwmechanics sources include
// "../../tspprof.h", which resolves to apps/tspprof.h, while
// apps/openmw/engine.cpp includes "tspprof.h", which resolves to
// apps/openmw/tspprof.h.
//
// Two copies of namespace TspProf, both full of inline functions holding
// function-local statics, is an ODR violation: the linker picks one
// arbitrarily, and if the copies ever disagree about TSP_SLOT_COUNT then
// sizeof(Frame) differs between translation units and slot writes run off
// the end of the array. They diverged once already - TSP_SLOT_ACTORS was
// added to one copy and not this one, which is what turned it into a build
// error instead of a heisenbug.
//
// One real header now, reached from both spellings.
#include "%s"
"""

VERSION_MARKERS = ["TSP_PROF_RING_V3", "TSP_PROF_RING_V2",
                   "TSP_SLOT_ACTORS", "TSP_SLOT_LUAWAIT", FORWARD_MARKER]


def find_headers():
    out = []
    for root, dirs, files in os.walk(SRCROOT):
        dirs[:] = [d for d in dirs if d not in (".git", "build")]
        if "tspprof.h" in files:
            out.append(os.path.join(root, "tspprof.h"))
    return sorted(out)


def describe(path):
    try:
        s = open(path, encoding="utf-8", errors="replace").read()
    except OSError as e:
        return "unreadable: %s" % e, ""
    bits = []
    for m in VERSION_MARKERS:
        if m in s:
            bits.append(m)
    return (", ".join(bits) if bits else "no known markers"), s


def scan_includes():
    """Every #include of a tspprof.h, and what it actually resolves to."""
    rows = []
    inc = re.compile(r'^\s*#\s*include\s+"([^"]*tspprof\.h)"', re.M)
    for root, dirs, files in os.walk(SRCROOT):
        dirs[:] = [d for d in dirs if d not in (".git", "build")]
        for fn in files:
            if not fn.endswith((".cpp", ".hpp", ".h", ".cc")):
                continue
            p = os.path.join(root, fn)
            if os.path.basename(p) == "tspprof.h":
                continue
            try:
                s = open(p, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            for m in inc.finditer(s):
                spelling = m.group(1)
                resolved = os.path.normpath(os.path.join(root, spelling))
                rows.append((os.path.relpath(p, SRCROOT), spelling,
                             os.path.relpath(resolved, SRCROOT),
                             os.path.isfile(resolved)))
    return rows


def scan_endframe():
    rows = []
    for root, dirs, files in os.walk(SRCROOT):
        dirs[:] = [d for d in dirs if d not in (".git", "build")]
        for fn in files:
            if not fn.endswith((".cpp", ".hpp", ".h", ".cc")):
                continue
            p = os.path.join(root, fn)
            if os.path.basename(p) == "tspprof.h":
                continue
            try:
                s = open(p, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            for i, line in enumerate(s.split("\n"), 1):
                if "TspProf::endFrame" in line:
                    rows.append((os.path.relpath(p, SRCROOT), i, line.strip()))
    return rows


def main():
    print()
    print("  tsp_prof_header_dedupe")
    print("  ======================")
    print()

    headers = find_headers()
    print("  EVERY tspprof.h IN THE TREE")
    for h in headers:
        desc, _ = describe(h)
        print("    %-52s %7d bytes" % (os.path.relpath(h, SRCROOT),
                                       os.path.getsize(h)))
        print("        %s" % desc)
    print()

    print("  EVERY #include OF ONE, AND WHERE IT ACTUALLY GOES")
    for src, spelling, resolved, exists in scan_includes():
        print("    %-46s %-22s -> %s%s"
              % (src, '"%s"' % spelling, resolved, "" if exists else "   MISSING"))
    print()

    ef = scan_endframe()
    print("  EVERY TspProf::endFrame() CALL SITE   (expect exactly 1)")
    if not ef:
        print("    none - the ring cannot advance")
    for src, ln, txt in ef:
        print("    %s:%d   %s" % (src, ln, txt))
    if len(ef) > 1:
        print("    >>> MORE THAN ONE. That is the phantom-record source: the ring")
        print("        gets a second endFrame() with nothing accumulated.")
    print()

    if not os.path.isfile(CANON):
        print("  ERROR: canonical header %s not found - NOTHING WRITTEN." % CANON)
        return 1

    canon_desc, canon_src = describe(CANON)
    if "TSP_PROF_RING_V3" not in canon_src:
        print("  ERROR: %s is not at V3 (%s)." % (CANON, canon_desc))
        print("  Run tsp_ring_arm_v3.py first - NOTHING WRITTEN.")
        return 1

    wrote = 0
    for h in headers:
        if os.path.samefile(h, CANON):
            print("  canonical        %s" % os.path.relpath(h, SRCROOT))
            continue

        cur = open(h, encoding="utf-8", errors="replace").read()
        rel = os.path.relpath(CANON, os.path.dirname(h)).replace(os.sep, "/")
        new = FORWARDER % (FORWARD_MARKER, rel)

        if cur == new:
            print("  already forwards %s -> %s" % (os.path.relpath(h, SRCROOT), rel))
            continue

        backup = h + ".tspdedupe-" + STAMP
        open(backup, "w", encoding="utf-8").write(cur)
        open(h, "w", encoding="utf-8").write(new)
        print("  REWROTE          %s" % os.path.relpath(h, SRCROOT))
        print("    now forwards to %s" % rel)
        print("    backup          %s" % os.path.relpath(backup, SRCROOT))
        wrote += 1

    print()
    print("  AFTER")
    for h in find_headers():
        desc, _ = describe(h)
        print("    %-52s %s" % (os.path.relpath(h, SRCROOT), desc))

    print()
    if wrote == 0:
        print("  VERIFIED: nothing to change, all include paths already reach one header")
    else:
        print("  VERIFIED: %d duplicate header(s) replaced with forwarders" % wrote)
    return 0


if __name__ == "__main__":
    sys.exit(main())