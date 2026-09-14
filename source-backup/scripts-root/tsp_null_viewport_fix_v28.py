#!/usr/bin/env python3
"""
tsp_null_viewport_fix_v28.py - fixes MY bug in v27, which silently did nothing

WHY V27 DID NOTHING
===================

v27 was compiled in, deployed, and armed. Measured on device:

    grep -a -c TSP_CAM_FIX <deployed binary>   -> 1     (patch is in there)
    OPENMW_TSP_FIX_NULL_VIEWPORT=1 at line 946 (env is set)
    12 x TSP_CAM_AUDIT in the log              (visitor runs)
    TSP_CAM_AUDIT ... viewport=-1x-1 ...       (the null camera IS seen)
    0  x TSP_CAM_FIX                           (and nothing was repaired)

The visitor reaches the camera, the guard passes, and then this line returns
null:

    osg::View* tspView = cam.getView();

osg::Camera::_view is only set by osg::View::setCamera() and addSlave(). A
camera that is simply a node in the scene graph - which is what this
PRE_RENDER camera is - has no View, so the master viewport was unreachable
and the repair skipped itself without a word. That silence cost a whole run.

WHAT V28 CHANGES
================

1. The visitor now remembers the first real viewport it sees and uses that as
   the source for repairs. Traversal order in your log is consistent:

       TSP_CAM_AUDIT first name="SceneCam"  viewport=1280x720
       TSP_CAM_AUDIT first name=""          viewport=1280x720
       TSP_CAM_AUDIT first name=""          viewport=-1x-1     <- the target

   so a good viewport is always in hand before the null one is reached.
   getView() is still tried first, since it is the more correct source when
   it exists.

2. It is no longer allowed to be silent. Every camera that matches the repair
   condition logs either TSP_CAM_FIX applied or TSP_CAM_FIX skip with the
   reason. A no-op now says so.

APPLY
=====

    sudo docker cp ~/Downloads/tsp_null_viewport_fix_v28.py openmw_builder:/root/
    sudo docker exec -i openmw_builder python3 /root/tsp_null_viewport_fix_v28.py

Handles both starting points: a tree with v27 already in it (replaced) and a
pristine tree (inserted). Backs up first, idempotent, writes nothing if the
anchor misses. Same env variable as before.

REVERT
======

    sudo docker exec -i openmw_builder sh -c \
      'cd /root/openmw-0.51-tsp-src/apps/openmw/mwrender && \
       ls -t renderingmanager.cpp.tspvpfix-* | head -1 | \
       xargs -I{} cp {} renderingmanager.cpp'
"""

import os
import sys
import time

SRC = "/root/openmw-0.51-tsp-src/apps/openmw/mwrender/renderingmanager.cpp"

V28_BLOCK = r'''
            // TSP_NULL_VIEWPORT_FIX_051_V28
            // v27 routed through cam.getView(), which is null for a camera
            // that is only a scene-graph node - i.e. exactly the camera this
            // targets - so it skipped in silence. v28 falls back to the first
            // real viewport the visitor has already seen this traversal, and
            // logs every decision including the ones that do nothing.
            //     OPENMW_TSP_FIX_NULL_VIEWPORT=1
            {
                static const bool tspFixNullViewport
                    = (std::getenv("OPENMW_TSP_FIX_NULL_VIEWPORT") != nullptr);

                // Remember a known-good viewport for later cameras.
                if (vp != nullptr && !isDefault && mFallbackViewport == nullptr)
                    mFallbackViewport = cam.getViewport();

                if (tspFixNullViewport && (vp == nullptr || isDefault))
                {
                    osg::View* tspView = cam.getView();
                    osg::Camera* tspMaster = tspView ? tspView->getCamera() : nullptr;
                    osg::Viewport* tspSource
                        = tspMaster ? tspMaster->getViewport() : nullptr;
                    const char* tspVia = "view-master";

                    if (tspSource == nullptr)
                    {
                        tspSource = mFallbackViewport;
                        tspVia = "first-seen";
                    }

                    if (tspSource == nullptr)
                    {
                        Log(Debug::Info)
                            << "TSP_CAM_FIX skip " << mTag
                            << " name=\"" << cam.getName() << "\""
                            << " reason=no-source-viewport"
                            << " had_view=" << (tspView ? 1 : 0);
                    }
                    else if (tspMaster == &cam)
                    {
                        Log(Debug::Info)
                            << "TSP_CAM_FIX skip " << mTag
                            << " name=\"" << cam.getName() << "\""
                            << " reason=is-master";
                    }
                    else
                    {
                        cam.setViewport(tspSource);

                        Log(Debug::Info)
                            << "TSP_CAM_FIX applied " << mTag
                            << " name=\"" << cam.getName() << "\""
                            << " was=" << w << "x" << h
                            << " now=" << static_cast<int>(tspSource->width())
                            << "x" << static_cast<int>(tspSource->height())
                            << " via=" << tspVia
                            << " render_order=" << static_cast<int>(cam.getRenderOrder());
                    }
                }
            }

            traverse(cam);'''

# The v27 block, verbatim, so it can be replaced rather than duplicated.
V27_BLOCK = r'''
            // TSP_NULL_VIEWPORT_FIX_051_V27
            // Opt-in candidate fix. A camera with no viewport of its own, or
            // one still holding osg::Viewport's default-constructed
            // (0,0,800,600), is the only thing in this graph that can put
            // 800x600 into GL. Give it the master's viewport explicitly.
            // That is what it would have inherited at cull time anyway, so
            // if this changes nothing the source is elsewhere.
            //     OPENMW_TSP_FIX_NULL_VIEWPORT=1
            {
                static const bool tspFixNullViewport
                    = (std::getenv("OPENMW_TSP_FIX_NULL_VIEWPORT") != nullptr);

                if (tspFixNullViewport && (vp == nullptr || isDefault))
                {
                    osg::View* tspView = cam.getView();
                    osg::Camera* tspMaster = tspView ? tspView->getCamera() : nullptr;
                    osg::Viewport* tspMasterViewport
                        = tspMaster ? tspMaster->getViewport() : nullptr;

                    if (tspMasterViewport != nullptr && tspMaster != &cam)
                    {
                        cam.setViewport(tspMasterViewport);

                        Log(Debug::Info)
                            << "TSP_CAM_FIX " << mTag
                            << " name=\"" << cam.getName() << "\""
                            << " was=" << w << "x" << h
                            << " now=" << static_cast<int>(tspMasterViewport->width())
                            << "x" << static_cast<int>(tspMasterViewport->height())
                            << " render_order=" << static_cast<int>(cam.getRenderOrder());
                    }
                }
            }

            traverse(cam);'''

PRISTINE_TAIL = r'''
            traverse(cam);'''

MEMBER_OLD = """    private:
        const char* mTag;
    };"""

MEMBER_NEW = """    private:
        const char* mTag;
        osg::Viewport* mFallbackViewport = nullptr;
    };"""


def main():
    if not os.path.isfile(SRC):
        print("  ERROR: %s not found" % SRC)
        return 1

    s = open(SRC, encoding="utf-8").read()
    original = s
    results = []
    failed = False

    # ---- include ---------------------------------------------------------
    if "#include <osg/View>" in s:
        results.append("  already applied  include osg/View")
    elif "#include <osg/UserDataContainer>\n" in s:
        s = s.replace("#include <osg/UserDataContainer>\n",
                      "#include <osg/UserDataContainer>\n#include <osg/View>\n", 1)
        results.append("  applied          include osg/View")
    else:
        results.append("  ANCHOR MISS      include osg/View")
        failed = True

    # ---- fallback member -------------------------------------------------
    if "mFallbackViewport" in s:
        results.append("  already applied  mFallbackViewport member")
    elif MEMBER_OLD in s:
        s = s.replace(MEMBER_OLD, MEMBER_NEW, 1)
        results.append("  applied          mFallbackViewport member")
    else:
        results.append("  ANCHOR MISS      mFallbackViewport member")
        failed = True

    # ---- the repair block ------------------------------------------------
    if "TSP_NULL_VIEWPORT_FIX_051_V28" in s:
        results.append("  already applied  v28 repair block")
    elif V27_BLOCK in s:
        s = s.replace(V27_BLOCK, V28_BLOCK, 1)
        results.append("  applied          v28 repair block  (replaced v27)")
    elif PRISTINE_TAIL in s:
        s = s.replace(PRISTINE_TAIL, V28_BLOCK, 1)
        results.append("  applied          v28 repair block  (fresh insert)")
    else:
        results.append("  ANCHOR MISS      v28 repair block")
        failed = True

    print("\n".join(results))

    if failed:
        print("\n  hunk(s) missed - NOTHING WRITTEN.")
        return 1

    if s == original:
        print("\n  VERIFIED: no changes needed (already applied)")
        return 0

    backup = SRC + ".tspvpfix-" + time.strftime("%Y%m%d-%H%M%S")
    open(backup, "w", encoding="utf-8").write(original)
    open(SRC, "w", encoding="utf-8").write(s)
    print("\n  backup:  %s" % backup)
    print("  VERIFIED: written %s" % SRC)
    return 0


if __name__ == "__main__":
    sys.exit(main())