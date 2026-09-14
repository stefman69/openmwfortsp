#!/usr/bin/env python3
"""
tsp_add_shader_precompile.py

Make OpenMW compile each shader program when it is CREATED (during the
loading screen) instead of leaving OSG to link it lazily on first draw
(mid-combat).

===========================================================================
WHY
===========================================================================

Measured across this session:

  - Mali charges ~137ms in glLinkProgram plus ~236ms deferred into the
    first draw that uses the program. worst_cpu_us == worst_us, so it is
    real CPU work, not a GPU stall.
  - The gl4es program-binary cache (TSP_PRGBIN_DETECT + the wrapper cache)
    removed the 137ms link permanently.
  - The remaining ~236ms cannot be moved from the wrapper. A warm-up draw
    only relocates it by one frame; preloading binaries into our own
    program objects at startup was nearly free (37ms for 13) and changed
    nothing in game, because the cost attaches to OpenMW's fully
    configured program objects.

The instrumented run then showed the opening:

  TSP_PROG t=6893.132 new program n=1  ... compatibility/gui.vert
  ...
  TSP_PROG t=6904.104 new program n=10 ... compatibility/objects.vert

All ten programs are created in an eleven second window at load. Nothing
is created later. But the stalls land at f=227 and f=255, well into play.

So creation and cost are separated: ShaderManager::getProgram builds the
osg::Program and inserts it into mPrograms without compiling, and OSG links
it lazily on the first apply() during draw. That first draw is mid-combat.

===========================================================================
WHAT THIS CHANGES
===========================================================================

ShaderManager gains an optional IncrementalCompileOperation. When
getProgram creates a new program, it queues that program for compilation
via CompileProgramOp - the same machinery OpenMW already uses for textures
and geometry, which is pumped during loading screens.

Three edits:

  components/shader/shadermanager.hpp  - ICO member + setter
  components/shader/shadermanager.cpp  - queue new programs on creation
  components/resource/scenemanager.cpp - forward the ICO to ShaderManager

It also reverts the TSP_PROGLOG diagnostic, which was only ever meant to
answer the creation-timing question and is a likely cause of the signal 11
seen in the last run (it dereferences a shader name that can be null).

===========================================================================
EXPECTED RESULT AND HOW TO READ IT
===========================================================================

Loading screens get longer by roughly the number of new programs times
236ms - with ten programs, about two and a half seconds, once per session,
where the player is already waiting.

In game: no five-digit worst_us stalls on first swing at a new creature or
first application of a status effect.

  grep -cE "worst_us=[0-9]{5,}" diag.txt

Zero is the goal. If stalls persist unchanged, the ICO is not compiling
programs on this OSG build and the next thing to try is calling
compileGLObjects directly from a graphics operation.

Set TSP_NO_SHADER_PRECOMPILE=1 to disable at runtime without rebuilding,
for a clean A/B.

===========================================================================
USAGE
===========================================================================

  python3 tsp_add_shader_precompile.py           apply
  python3 tsp_add_shader_precompile.py --revert  restore newest backups

Then rebuild openmw and deploy binary + defaults.bin + resources/version
together, as always.
"""

import glob
import os
import re
import shutil
import sys
import time

SRC = "/root/openmw-0.51-tsp-src"
HPP = SRC + "/components/shader/shadermanager.hpp"
CPP = SRC + "/components/shader/shadermanager.cpp"
SCN = SRC + "/components/resource/scenemanager.cpp"

TAG = "TSP_SHADER_PRECOMPILE"


def backup(path):
    shutil.copy(path, path + ".before-precompile-" + time.strftime("%Y%m%d-%H%M%S"))


def revert():
    n = 0
    for path in (HPP, CPP, SCN):
        b = sorted(glob.glob(path + ".before-precompile-*"))
        if b:
            shutil.copy(b[-1], path)
            print("restored", os.path.basename(path), "from", os.path.basename(b[-1]))
            n += 1
    if not n:
        print("no precompile backups found")
        return 1
    return 0


def drop_proglog(src):
    """Remove the TSP_PROGLOG diagnostic if present."""
    if "TSP_PROGLOG" not in src:
        return src, False
    m = re.search(
        r'\n[ \t]*/\* TSP_PROGLOG:.*?\*/\s*\n[ \t]*\{.*?\n[ \t]*\}',
        src, re.S)
    if m:
        return src[:m.start()] + src[m.end():], True
    return src, False


def main():
    if "--revert" in sys.argv:
        return revert()

    for p in (HPP, CPP, SCN):
        if not os.path.exists(p):
            print("ERROR: missing", p)
            return 1

    report = []

    # ---------------- header ----------------
    hpp = open(HPP).read()
    if TAG in hpp:
        print("header already patched")
    else:
        if "#include <osgUtil/IncrementalCompileOperation>" not in hpp:
            m = re.search(r'^#include <osg/[^\n]*\n', hpp, re.M)
            if not m:
                print("ERROR: no osg include in header to anchor to")
                return 1
            hpp = hpp[:m.end()] + "#include <osgUtil/IncrementalCompileOperation>\n" + hpp[m.end():]
            report.append("hpp: added IncrementalCompileOperation include")

        anchor = "const osg::Program* getProgramTemplate() const { return mProgramTemplate; }"
        if anchor not in hpp:
            print("ERROR: getProgramTemplate anchor not found. Nearby lines:")
            for i, l in enumerate(hpp.split("\n"), 1):
                if "ProgramTemplate" in l:
                    print("  %d: %s" % (i, l.strip()[:90]))
            return 1
        hpp = hpp.replace(anchor, anchor + """

        /* """ + TAG + """: OSG links an osg::Program lazily on first apply()
           during draw. On Mali that first draw costs ~236ms of CPU, and the
           instrumented run showed every program is created during the loading
           screen while the stall lands mid-combat. Handing the ICO each new
           program moves that compile into the load, using the same machinery
           OpenMW already pumps for textures and geometry. */
        void setIncrementalCompileOperation(osgUtil::IncrementalCompileOperation* ico)
        {
            mIncrementalCompileOperation = ico;
        }""", 1)

        anchor2 = "ProgramMap mPrograms;"
        if anchor2 not in hpp:
            print("ERROR: mPrograms anchor not found in header")
            return 1
        hpp = hpp.replace(anchor2,
            anchor2 + "\n        osg::ref_ptr<osgUtil::IncrementalCompileOperation> mIncrementalCompileOperation;", 1)
        report.append("hpp: added ICO member and setter")
        backup(HPP)
        open(HPP, "w").write(hpp)

    # ---------------- shadermanager.cpp ----------------
    cpp = open(CPP).read()
    cpp, dropped = drop_proglog(cpp)
    if dropped:
        report.append("cpp: removed TSP_PROGLOG diagnostic")

    if TAG in cpp:
        print("shadermanager.cpp already patched")
    else:
        anchor = "found = mPrograms.insert(std::make_pair(std::make_pair(vertexShader, fragmentShader), program)).first;"
        if anchor not in cpp:
            print("ERROR: mPrograms.insert anchor not found")
            return 1
        cpp = cpp.replace(anchor, anchor + """
            /* """ + TAG + """: compile now, during the loading screen, rather
               than letting OSG link on first draw in the middle of combat. */
            if (mIncrementalCompileOperation && !std::getenv("TSP_NO_SHADER_PRECOMPILE"))
            {
                osg::ref_ptr<osgUtil::IncrementalCompileOperation::CompileSet> compileSet
                    = new osgUtil::IncrementalCompileOperation::CompileSet;
                compileSet->add(program.get());
                mIncrementalCompileOperation->add(compileSet, false);
            }""", 1)
        if "#include <cstdlib>" not in cpp:
            m = re.search(r'^#include [^\n]*\n', cpp, re.M)
            cpp = cpp[:m.end()] + "#include <cstdlib>\n" + cpp[m.end():]
        report.append("cpp: queue new programs for compilation")

    backup(CPP)
    open(CPP, "w").write(cpp)

    # ---------------- scenemanager.cpp ----------------
    scn = open(SCN).read()
    if TAG in scn:
        print("scenemanager.cpp already patched")
    else:
        anchor = "mIncrementalCompileOperation = ico;"
        if anchor not in scn:
            print("ERROR: setIncrementalCompileOperation body not found")
            return 1
        scn = scn.replace(anchor, anchor + """
        /* """ + TAG + """: give the ShaderManager the same ICO so newly
           created programs are compiled at load instead of on first draw. */
        if (mShaderManager)
            mShaderManager->setIncrementalCompileOperation(ico);""", 1)
        report.append("scenemanager.cpp: forward ICO to ShaderManager")
        backup(SCN)
        open(SCN, "w").write(scn)

    print("\n".join("  " + r for r in report) if report else "  nothing to do")
    print("\nbuild with:")
    print("  cd /root/openmw-0.51-tsp-build && cmake --build . --target openmw --parallel 4")
    return 0


sys.exit(main())
