#!/usr/bin/env python3
"""
tsp_apply_prof.py

Installs tspprof.h and inserts one hook line per measurement point.

Every edit is a single-line insertion immediately after a function's opening
brace. No block is removed, no brace is rewritten, nothing is moved. That is
the difference from the earlier attempts, which cut and reinserted regions and
corrupted character.cpp.

  python3 tsp_apply_prof.py            apply
  python3 tsp_apply_prof.py --revert   restore every touched file
  python3 tsp_apply_prof.py --check    report what is currently patched
"""

import glob
import os
import re
import shutil
import sys
import time

ROOT = "/root/openmw-0.51-tsp-src"
APPS = ROOT + "/apps/openmw"
HDR_SRC = "/root/tspprof.h"
HDR_DST = APPS + "/tspprof.h"

# (file, regex matching the function signature + opening brace, slot, label)
TARGETS = [
    (APPS + "/mwmechanics/actors.cpp",
     r'void Actors::update\(float duration, bool paused\)\s*\{',
     "TSP_SLOT_MECH", "Actors::update"),

    (APPS + "/mwmechanics/character.cpp",
     r'void CharacterController::update\(float duration\)\s*\{',
     "TSP_SLOT_CHAR", "CharacterController::update"),

    (APPS + "/mwmechanics/character.cpp",
     r'void CharacterController::refreshCurrentAnims\(\s*\n?[^)]*\)\s*\{',
     "TSP_SLOT_ANIM", "refreshCurrentAnims"),

    (APPS + "/mwmechanics/activespells.cpp",
     r'void ActiveSpells::update\(const MWWorld::Ptr& ptr, float duration\)\s*\{',
     "TSP_SLOT_SPELL", "ActiveSpells::update"),
]

# frame boundary and exit dump
FRAME_FILE = APPS + "/engine.cpp"
FRAME_SIG = r'void OMW::Engine::frame\([^)]*\)\s*\{'


def rel(p):
    return p.replace(ROOT + "/", "")


def backup(path):
    shutil.copy(path, path + ".before-tspprof-" + time.strftime("%Y%m%d-%H%M%S"))


def check():
    for f in sorted(set([t[0] for t in TARGETS] + [FRAME_FILE])):
        if not os.path.exists(f):
            print("  MISSING  %s" % rel(f))
            continue
        src = open(f).read()
        n = src.count("TSP_SCOPE") + src.count("TspProf::")
        print("  %-55s %d hook(s)" % (rel(f), n))
    print("  header installed: %s" % os.path.exists(HDR_DST))
    return 0


def revert():
    n = 0
    for f in glob.glob(ROOT + "/**/*.before-tspprof-*", recursive=True):
        orig = f.split(".before-tspprof-")[0]
        shutil.copy(f, orig)
        print("  restored", rel(orig))
        n += 1
    if os.path.exists(HDR_DST):
        os.remove(HDR_DST)
        print("  removed", rel(HDR_DST))
    print("reverted %d file(s)" % n)
    return 0


def ensure_include(src, depth):
    """Add the header include after the last existing include."""
    inc = '#include "%stspprof.h"' % ("../" * depth)
    if inc in src:
        return src, False
    m = None
    for m in re.finditer(r'#include [<"][^>"]+[>"]\n', src):
        pass
    if not m:
        return src, False
    return src[:m.end()] + inc + "\n" + src[m.end():], True


def main():
    if "--revert" in sys.argv:
        return revert()
    if "--check" in sys.argv:
        return check()

    if not os.path.exists(HDR_SRC):
        print("ERROR: %s not found - copy tspprof.h into the container first" % HDR_SRC)
        return 1
    shutil.copy(HDR_SRC, HDR_DST)
    print("installed", rel(HDR_DST))

    edits = {}

    for path, sig, slot, label in TARGETS:
        if not os.path.exists(path):
            print("  SKIP  %s (missing)" % rel(path))
            continue
        src = edits.get(path, open(path).read())

        if label in src and "TSP_SCOPE" in src:
            print("  SKIP  %s already hooked" % label)
            edits[path] = src
            continue

        m = re.search(sig, src)
        if not m:
            print("  FAIL  could not match %s in %s" % (label, rel(path)))
            continue

        depth = rel(path).count("/") - 1
        src, _ = ensure_include(src, depth)
        m = re.search(sig, src)  # offsets moved after the include

        line = "\n        TSP_SCOPE(TspProf::%s); // %s" % (slot, label)
        src = src[:m.end()] + line + src[m.end():]
        edits[path] = src
        print("  hooked %-28s -> %s" % (label, slot))

    # frame boundary + exit dump
    if os.path.exists(FRAME_FILE):
        src = edits.get(FRAME_FILE, open(FRAME_FILE).read())
        if "TspProf::endFrame" not in src:
            m = re.search(FRAME_SIG, src)
            if m:
                src, _ = ensure_include(src, rel(FRAME_FILE).count("/") - 1)
                m = re.search(FRAME_SIG, src)
                src = src[:m.end()] + '''
    TspProf::dumpAtExit();
    struct TspFrameGuard { ~TspFrameGuard() { TspProf::endFrame(); } } tspFrameGuard;''' + src[m.end():]
                edits[FRAME_FILE] = src
                print("  hooked frame boundary + exit dump")
            else:
                print("  FAIL  could not match Engine::frame")

    if not edits:
        print("nothing patched")
        return 1

    for path, src in edits.items():
        backup(path)
        open(path, "w").write(src)

    print()
    print("patched %d file(s). now build:" % len(edits))
    print("  cd /root/openmw-0.51-tsp-build && cmake --build . --target openmw --parallel 4")
    return 0


sys.exit(main())
