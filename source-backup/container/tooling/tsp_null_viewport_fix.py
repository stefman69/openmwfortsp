#!/usr/bin/env python3
"""
tsp_null_viewport_fix.py - candidate fix for the stale 800x600 GL viewport

WHAT THIS IS
============

The audit run settled what the 800x600 is NOT:

    tag=pre   fire=N  camera_viewport=1280x720  gl_viewport=1280x720
    tag=post  fire=N  camera_viewport=1280x720  gl_viewport=800x600

Same camera (SceneCam, the master) on both callbacks, so the 800x600 is
applied DURING its draw and never undone. And no camera in the graph holds
an 800x600 viewport:

    SceneCam   viewport=1280x720  render_order=2(POST_RENDER)  rtt=3(FRAME_BUFFER)
    ""         viewport=1280x720  render_order=2(POST_RENDER)  rtt=3(FRAME_BUFFER)
    ""         viewport=-1x-1     render_order=0(PRE_RENDER)   rtt=3(FRAME_BUFFER)  mask=0x40000

That third camera has NO viewport at all, renders PRE_RENDER into the default
framebuffer, and is therefore drawn inside the master's draw - exactly between
the two callbacks. osg::Viewport's default constructor is (0,0,800,600), so a
camera with no viewport is the one thing here that can put those numbers into
GL.

WHAT IT CHANGES
===============

One block inside TspCameraViewportAudit::apply. Any camera the visitor reaches
that has no viewport, or still holds exactly 800x600, is given the master
camera's viewport. Semantically that is what it would have inherited at cull
time anyway, so this cannot change what any camera renders - it only removes
the chance of a default-constructed Viewport reaching glViewport.

Gated on an environment variable, so one build gives you both sides of the
test:

    unset                             -> audit only, current behaviour
    OPENMW_TSP_FIX_NULL_VIEWPORT=1    -> audit plus the fix

This is a CANDIDATE, not a confirmed fix. The A/B is decisive either way: if
post-draw gl_viewport reads 1280x720 with the variable set, that camera was
the source. If it still reads 800x600, it is not, and the line is harmless.

Every camera that gets repaired logs a TSP_CAM_FIX line naming itself.

WHY NO CALL-SITE EDIT
=====================

The visitor is constructed differently in your tree than in the copy I have,
so this touches only the class body, which is identical. The master viewport
is reached through osg::Camera::getView() -> osg::View::getCamera(), both
verified present in your OSG headers (osg/Camera:63, osg/View:81).

APPLY
=====

    sudo docker cp ~/Downloads/tsp_null_viewport_fix.py openmw_builder:/root/
    sudo docker exec -i openmw_builder python3 /root/tsp_null_viewport_fix.py

Backs up first, idempotent, and writes nothing at all if any hunk misses.

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

HUNKS = []


def hunk(name, old, new, note=""):
    HUNKS.append((name, old, new, note))


# ---------------------------------------------------------------- hunk 1
# osg::View must be a complete type to call getCamera() on it. It already
# arrives via osgViewer/Viewer, but naming it directly makes that explicit
# and costs nothing - the header is guarded.
hunk(
    "include osg/View",
    "#include <osg/UserDataContainer>\n",
    "#include <osg/UserDataContainer>\n#include <osg/View>\n",
    "",
)

# ---------------------------------------------------------------- hunk 2
# The repair itself, inside the audit visitor, immediately before traverse().
hunk(
    "null-viewport repair",
    """                << (isDefault ? "   <<<< DEFAULT osg::Viewport(0,0,800,600)" : "");

            traverse(cam);""",
    """                << (isDefault ? "   <<<< DEFAULT osg::Viewport(0,0,800,600)" : "");

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
                            << " name=\\"" << cam.getName() << "\\""
                            << " was=" << w << "x" << h
                            << " now=" << static_cast<int>(tspMasterViewport->width())
                            << "x" << static_cast<int>(tspMasterViewport->height())
                            << " render_order=" << static_cast<int>(cam.getRenderOrder());
                    }
                }
            }

            traverse(cam);""",
    "adds TSP_CAM_FIX",
)


def main():
    if not os.path.isfile(SRC):
        print("  ERROR: %s not found" % SRC)
        return 1

    s = open(SRC, encoding="utf-8").read()
    original = s
    results = []
    missed = 0

    for name, old, new, note in HUNKS:
        if new.strip() in s:
            results.append("  already applied  %s" % name)
            continue

        if old not in s:
            results.append("  ANCHOR MISS      %s" % name)
            missed += 1
            continue

        s = s.replace(old, new, 1)
        results.append("  applied          %s%s" % (name, ("  (" + note + ")") if note else ""))

    print("\n".join(results))

    if missed:
        print("\n  %d hunk(s) missed - NOTHING WRITTEN." % missed)
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