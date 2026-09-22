#!/usr/bin/env python3
"""
tsp_add_warmdraw.py

Force a real DRAW with every new shader program, during the loading screen,
inside OpenMW - where the program carries its true vertex attributes and
uniforms.

===========================================================================
WHY A DRAW, NOT A COMPILE
===========================================================================

Measured across this session on Mali-G57 / gl4es:

  - ~137ms inside glLinkProgram, plus ~236ms deferred into the FIRST DRAW
    that uses the program. worst_cpu_us == worst_us, so both are CPU work.
  - The ICO precompile can only ever remove the first number.
    osgUtil::IncrementalCompileOperation links the program; it never draws
    with it. Best case that leaves 236ms of the 375ms still landing
    mid-combat.
  - A throwaway draw DOES pull the 236ms forward - the LD_PRELOAD wrapper
    proved that (SCWARM prog=17 235900us). But from the wrapper the only
    available moment was one frame later, which just relocated the stall.
  - Preloading the cached binary into our own bare program object was
    nearly free (37ms for 13 programs) and changed nothing in game, so the
    cost is bound to OpenMW's fully-configured program object, not to the
    binary or to the GL program name.

Conclusion: the draw has to happen with OpenMW's own program, at a moment
OpenMW controls. That is what this does.

===========================================================================
WHAT IT DOES
===========================================================================

ShaderManager gains a warm-up group. Whenever getProgram creates a new
program, it builds a tiny Geode carrying that program and adds it to the
group. RenderingManager attaches the group to the scene root, so the node
is drawn on the next frame - which, per the instrumented run, is during the
loading screen, since every program is created there.

The node writes nothing:
  - colour mask off on all four channels
  - depth writes off, depth test off
  - a degenerate (zero-area) triangle
so it cannot change a pixel even though the draw is really submitted, which
is what forces Mali to finish the program.

Each warm node removes itself after being traversed twice, so the per-frame
draw-call cost does not persist.

===========================================================================
EXPECTED RESULT
===========================================================================

Loading gets longer by roughly (number of new programs) x 236ms - about
2-4s for a typical cell load, once, where the player is already waiting.

In game: no five-digit worst_us stalls on first swing at a new creature or
first application of a status effect.

  grep -cE "worst_us=[0-9]{5,}" diag.txt

Zero is the goal. The log line

  TSP_WARMDRAW queued program n=N

confirms the branch actually ran - silence means it did not, and the
"skipped" lines say why.

If the stalls persist with WARMDRAW lines present, then the draw is
happening but Mali is keying its work to something else in the draw state
(blend mode, framebuffer format), and the next step is matching that state
rather than any further precompiling.

===========================================================================
USAGE
===========================================================================

  python3 tsp_add_warmdraw.py           apply
  python3 tsp_add_warmdraw.py --revert  restore newest backups

Rebuild openmw, deploy binary + defaults.bin + resources/version together.
TSP_NO_SHADER_WARMDRAW=1 disables it at runtime for a clean A/B.
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
RM = SRC + "/apps/openmw/mwrender/renderingmanager.cpp"

TAG = "TSP_SHADER_WARMDRAW"


def backup(path):
    shutil.copy(path, path + ".before-warmdraw-" + time.strftime("%Y%m%d-%H%M%S"))


def revert():
    n = 0
    for path in (HPP, CPP, RM):
        b = sorted(glob.glob(path + ".before-warmdraw-*"))
        if b:
            shutil.copy(b[-1], path)
            print("restored", os.path.basename(path), "from", os.path.basename(b[-1]))
            n += 1
    return 0 if n else 1


HPP_ADD = """
        /* """ + TAG + """: OSG links a program lazily and OSG's incremental
           compile only ever links it - Mali defers ~236ms more until the first
           real draw. This group holds a tiny throwaway drawable per new program
           so that draw happens during the loading screen instead of mid-combat.
           RenderingManager attaches it to the scene root. */
        osg::Group* getWarmupGroup() { return mWarmupGroup.get(); }"""

CPP_WARM = '''
namespace
{
    /* ''' + TAG + ''': removes the warm-up drawable once it has been traversed,
       so the extra draw call does not persist for the whole session. */
    class TspWarmupPrune : public osg::NodeCallback
    {
    public:
        void operator()(osg::Node* node, osg::NodeVisitor* nv) override
        {
            if (++mSeen >= 2)
            {
                for (unsigned int i = 0; i < node->getNumParents(); ++i)
                    node->getParent(i)->removeChild(node);
                return;
            }
            traverse(node, nv);
        }
    private:
        int mSeen = 0;
    };
}
'''

CPP_QUEUE = '''            /* ''' + TAG + ''': submit a real draw with this program now, during
               the loading screen. Colour and depth writes are masked off and the
               triangle is degenerate, so nothing can appear on screen - but the
               draw is genuinely submitted, which is what makes Mali finish its
               ~236ms of per-program work here instead of on the first swing. */
            if (!mWarmupGroup)
                Log(Debug::Info) << "TSP_WARMDRAW skipped: no warmup group";
            else if (std::getenv("TSP_NO_SHADER_WARMDRAW"))
                Log(Debug::Info) << "TSP_WARMDRAW skipped: disabled by env";
            else
            {
                osg::ref_ptr<osg::Vec3Array> verts = new osg::Vec3Array(3);
                (*verts)[0] = osg::Vec3(0.f, 0.f, 0.f);
                (*verts)[1] = osg::Vec3(0.f, 0.f, 0.f);
                (*verts)[2] = osg::Vec3(0.f, 0.f, 0.f);
                osg::ref_ptr<osg::Geometry> geom = new osg::Geometry;
                geom->setUseDisplayList(false);
                geom->setUseVertexBufferObjects(true);
                geom->setVertexArray(verts);
                geom->addPrimitiveSet(new osg::DrawArrays(osg::PrimitiveSet::TRIANGLES, 0, 3));
                geom->setCullingActive(false);
                osg::StateSet* ss = geom->getOrCreateStateSet();
                ss->setAttributeAndModes(program, osg::StateAttribute::ON);
                ss->setAttributeAndModes(
                    new osg::ColorMask(false, false, false, false), osg::StateAttribute::ON);
                ss->setAttributeAndModes(
                    new osg::Depth(osg::Depth::ALWAYS, 0.0, 1.0, false), osg::StateAttribute::ON);
                ss->setMode(GL_DEPTH_TEST, osg::StateAttribute::OFF);
                osg::ref_ptr<osg::Geode> geode = new osg::Geode;
                geode->addDrawable(geom);
                geode->setCullingActive(false);
                geode->addUpdateCallback(new TspWarmupPrune);
                mWarmupGroup->addChild(geode);
                Log(Debug::Info) << "TSP_WARMDRAW queued program n=" << mPrograms.size();
            }
'''


def main():
    if "--revert" in sys.argv:
        return revert()

    for p in (HPP, CPP, RM):
        if not os.path.exists(p):
            print("ERROR: missing", p)
            return 1

    report = []

    # ---------- header ----------
    hpp = open(HPP).read()
    if TAG in hpp:
        print("header already patched")
    else:
        if "#include <osg/Group>" not in hpp:
            m = re.search(r'^#include <osg/[^\n]*\n', hpp, re.M)
            if not m:
                print("ERROR: no osg include in header")
                return 1
            hpp = hpp[:m.end()] + "#include <osg/Group>\n" + hpp[m.end():]
        anchor = "const osg::Program* getProgramTemplate() const { return mProgramTemplate; }"
        if anchor not in hpp:
            print("ERROR: getProgramTemplate anchor missing. Lines with ProgramTemplate:")
            for i, l in enumerate(hpp.split("\n"), 1):
                if "ProgramTemplate" in l:
                    print("  %d: %s" % (i, l.strip()[:90]))
            return 1
        hpp = hpp.replace(anchor, anchor + HPP_ADD, 1)
        anchor2 = "ProgramMap mPrograms;"
        if anchor2 not in hpp:
            print("ERROR: mPrograms anchor missing in header")
            return 1
        hpp = hpp.replace(anchor2,
            anchor2 + "\n        osg::ref_ptr<osg::Group> mWarmupGroup = new osg::Group;", 1)
        backup(HPP)
        open(HPP, "w").write(hpp)
        report.append("hpp: warm-up group + accessor")

    # ---------- shadermanager.cpp ----------
    cpp = open(CPP).read()
    if TAG in cpp:
        print("shadermanager.cpp already patched")
    else:
        for inc in ("<osg/Geode>", "<osg/Geometry>", "<osg/ColorMask>", "<osg/Depth>",
                    "<osg/Array>", "<osg/PrimitiveSet>", "<osg/NodeCallback>", "<cstdlib>"):
            if "#include %s" % inc not in cpp:
                i = cpp.find("#include")
                j = cpp.find("\n", i) + 1
                cpp = cpp[:j] + "#include %s\n" % inc + cpp[j:]
        if "#include <components/debug/debuglog.hpp>" not in cpp:
            i = cpp.find("#include")
            j = cpp.find("\n", i) + 1
            cpp = cpp[:j] + "#include <components/debug/debuglog.hpp>\n" + cpp[j:]

        m = re.search(r'^namespace Shader\s*$', cpp, re.M)
        if not m:
            print("ERROR: 'namespace Shader' not found")
            return 1
        cpp = cpp[:m.start()] + CPP_WARM + "\n" + cpp[m.start():]

        anchor = "found = mPrograms.insert(std::make_pair(std::make_pair(vertexShader, fragmentShader), program)).first;"
        if anchor not in cpp:
            print("ERROR: mPrograms.insert anchor missing")
            return 1
        cpp = cpp.replace(anchor, anchor + "\n" + CPP_QUEUE, 1)
        backup(CPP)
        open(CPP, "w").write(cpp)
        report.append("cpp: queue a real warm-up draw per new program")

    # ---------- renderingmanager.cpp ----------
    rm = open(RM).read()
    if TAG in rm:
        print("renderingmanager.cpp already patched")
    else:
        anchor = "sceneRoot->addChild(mDebugDraw);"
        if anchor not in rm:
            print("ERROR: sceneRoot->addChild(mDebugDraw) anchor missing. Candidates:")
            for i, l in enumerate(rm.split("\n"), 1):
                if "sceneRoot->addChild" in l:
                    print("  %d: %s" % (i, l.strip()[:90]))
            return 1
        rm = rm.replace(anchor, anchor + """
        /* """ + TAG + """: attach the shader warm-up group so the throwaway
           drawables it collects are actually rendered, forcing Mali to finish
           each new program during the loading screen. */
        if (osg::Group* warmup
            = mResourceSystem->getSceneManager()->getShaderManager().getWarmupGroup())
            sceneRoot->addChild(warmup);""", 1)
        backup(RM)
        open(RM, "w").write(rm)
        report.append("renderingmanager.cpp: attach warm-up group to scene root")

    print("\n".join("  " + r for r in report) if report else "  nothing to do")
    print("\nbuild with:")
    print("  cd /root/openmw-0.51-tsp-build && cmake --build . --target openmw --parallel 4")
    return 0


sys.exit(main())
