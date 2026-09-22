#!/usr/bin/env python3
"""
tsp_viewport_audit.py - patch renderingmanager.cpp to name the camera that
                        owns the default 800x600 osg::Viewport

WHAT THIS IS FOR
================

TSP_ACTUAL_RENDER_RES_051_V25 reports:

    camera_viewport=1280x720   gl_viewport=800x600   gl_scissor=1280x720

800x600 is not arbitrary and it is not OpenMW's. Verified against OSG source,
osg::Viewport's default constructor is:

    Viewport::Viewport() { _x = 0; _y = 0; _width = 800; _height = 600; }

So a camera somewhere holds a default-constructed viewport. OSG applies it to
GL during that camera's draw, and because osg::State CACHES applied attributes,
whichever camera runs next may find its own viewport already "current" and skip
re-issuing glViewport. The stale 800x600 then survives into the swap.

The existing probe cannot say which camera, because it is a post-draw callback
on the master and only reports the state it inherits.

WHAT THIS PATCH ADDS
====================

1. TSP_CAM_AUDIT - a NodeVisitor that walks the whole scene graph with the node
   mask overridden (OpenMW masks heavily; without the override most cameras are
   invisible to a visitor) and prints every osg::Camera's name, its own
   viewport, render order and RTT mode. Any camera whose viewport is exactly
   800x600 is flagged. This finds the owner directly rather than inferring it
   from draw order.

2. The probe now runs as BOTH a pre-draw and a post-draw callback, tagged, and
   fires for the first 10 frames instead of once. That distinguishes:

     pre already 800x600   -> the master's viewport never reached GL at all
     pre 1280x720, post 800x600 -> a nested/RTT camera drew and left it behind

3. The probe log line gains camera_name and render_order.

APPLY
=====

    sudo docker cp ~/Downloads/tsp_viewport_audit.py openmw_builder:/root/
    sudo docker exec openmw_builder python3 /root/tsp_viewport_audit.py

It backs up the file first and is idempotent - re-running is harmless. Every
hunk reports applied / already-present / ANCHOR MISS separately, so a partial
match tells you exactly which one drifted.

REVERT
======

    sudo docker exec openmw_builder sh -c \
      'cd /root/openmw-0.51-tsp-src/apps/openmw/mwrender && \
       ls -t renderingmanager.cpp.tspaudit-* | head -1 | \
       xargs -I{} cp {} renderingmanager.cpp'
"""

import os
import sys
import time

SRC = "/root/openmw-0.51-tsp-src/apps/openmw/mwrender/renderingmanager.cpp"

AUDIT_CLASS = r'''
    // TSP_CAMERA_VIEWPORT_AUDIT_051_V26
    // Walks every osg::Camera and prints its viewport. osg::Viewport's default
    // constructor is (0,0,800,600), so any camera reporting exactly that never
    // had a real viewport assigned - which is the whole question.
    class TspCameraViewportAudit final : public osg::NodeVisitor
    {
    public:
        explicit TspCameraViewportAudit(const char* tag)
            : osg::NodeVisitor(osg::NodeVisitor::TRAVERSE_ALL_CHILDREN)
            , mTag(tag)
        {
            // OpenMW hides most of the graph behind node masks. Without this
            // the visitor sees almost nothing.
            setNodeMaskOverride(~0u);
        }

        void apply(osg::Camera& cam) override
        {
            const osg::Viewport* vp = cam.getViewport();
            const int w = vp ? static_cast<int>(vp->width()) : -1;
            const int h = vp ? static_cast<int>(vp->height()) : -1;
            const bool isDefault = (w == 800 && h == 600);

            Log(Debug::Info)
                << "TSP_CAM_AUDIT " << mTag
                << " name=\"" << cam.getName() << "\""
                << " viewport=" << w << "x" << h
                << " xy=" << (vp ? static_cast<int>(vp->x()) : -1)
                << "," << (vp ? static_cast<int>(vp->y()) : -1)
                << " render_order=" << static_cast<int>(cam.getRenderOrder())
                << " rtt=" << static_cast<int>(cam.getRenderTargetImplementation())
                << " mask=" << static_cast<unsigned long>(cam.getNodeMask())
                << (isDefault ? "   <<<< DEFAULT osg::Viewport(0,0,800,600)" : "");

            traverse(cam);
        }

    private:
        const char* mTag;
    };
'''

HUNKS = []


def hunk(name, old, new, note=""):
    HUNKS.append((name, old, new, note))


# ---------------------------------------------------------------- hunk 1
# Insert the audit visitor just before the probe class.
hunk(
    "audit visitor class",
    "    // TSP_ACTUAL_RENDER_RES_PROBE_051_V25\n",
    AUDIT_CLASS + "\n    // TSP_ACTUAL_RENDER_RES_PROBE_051_V25\n",
    "adds TspCameraViewportAudit",
)

# ---------------------------------------------------------------- hunk 2
# Tag the probe so pre-draw and post-draw are distinguishable.
hunk(
    "probe constructor takes a tag",
    """        TspActualRenderResolutionProbe(int requestedWidth, int requestedHeight)
            : mRequestedWidth(requestedWidth)
            , mRequestedHeight(requestedHeight)
        {
        }""",
    """        TspActualRenderResolutionProbe(int requestedWidth, int requestedHeight,
                                       const char* tag = "post")
            : mRequestedWidth(requestedWidth)
            , mRequestedHeight(requestedHeight)
            , mTag(tag)
        {
        }""",
    "adds mTag",
)

hunk(
    "probe tag member",
    """        int mRequestedWidth;
        int mRequestedHeight;
        mutable bool mLogged = false;""",
    """        int mRequestedWidth;
        int mRequestedHeight;
        const char* mTag = "post";
        mutable int mFires = 0;""",
    "one-shot bool -> fire counter",
)

# ---------------------------------------------------------------- hunk 3
# Fire for the first 10 frames instead of once.
hunk(
    "probe fires 10x not once",
    """            if (mLogged)
                return;""",
    """            // Ten frames, not one. The camera graph is built lazily as the
            // world loads, so a single sample at frame 1 can miss the camera
            // that actually owns the stale viewport.
            if (mFires >= 10)
                return;
            ++mFires;""",
    "",
)

hunk(
    "drop the old one-shot assignment",
    "            mLogged = true;\n",
    "",
    "",
)

# ---------------------------------------------------------------- hunk 4
# Add tag + camera name + render order to the log line, and run the audit.
hunk(
    "probe logs camera identity",
    """                << " LIBGL_TSP_OUTPUT=" << (libglOutput ? libglOutput : "<unset>");""",
    """                << " LIBGL_TSP_OUTPUT=" << (libglOutput ? libglOutput : "<unset>")
                << " tag=" << mTag
                << " fire=" << mFires
                << " camera_name=\\"" << (camera ? camera->getName() : std::string("<null>")) << "\\""
                << " render_order=" << (camera ? static_cast<int>(camera->getRenderOrder()) : -1);

            // On the first and last fire, walk the graph and name every camera.
            if (camera && (mFires == 1 || mFires == 10))
            {
                TspCameraViewportAudit audit(mFires == 1 ? "first" : "settled");
                if (camera->getView() && camera->getView()->getSceneData())
                    camera->getView()->getSceneData()->accept(audit);
            }""",
    "",
)

# ---------------------------------------------------------------- hunk 5
# Register the probe as a pre-draw callback as well as post-draw.
hunk(
    "register pre-draw probe",
    """        mViewer->getCamera()->setPostDrawCallback(
            new TspActualRenderResolutionProbe(
                tspInternalWidth,
                tspInternalHeight));""",
    """        mViewer->getCamera()->setPostDrawCallback(
            new TspActualRenderResolutionProbe(
                tspInternalWidth,
                tspInternalHeight,
                "post"));

        // Pre-draw as well. If pre already reads 800x600 the master viewport
        // never reached GL; if pre reads 1280x720 and post reads 800x600 then
        // something drew in between and left it behind.
        mViewer->getCamera()->setPreDrawCallback(
            new TspActualRenderResolutionProbe(
                tspInternalWidth,
                tspInternalHeight,
                "pre"));""",
    "",
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
        # A hunk whose replacement is empty is a DELETION. For those, "the old
        # text is gone" IS the applied state - checking for the new text would
        # always fail and report a false ANCHOR MISS on a second run.
        is_deletion = (new.strip() == "")

        if is_deletion:
            if old not in s:
                results.append("  already applied  %s" % name)
                continue
        elif new.strip() in s:
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
        print("  The file has drifted from what this patch expects.")
        return 1

    if s == original:
        print("\n  no changes needed")
        return 0

    backup = SRC + ".tspaudit-" + time.strftime("%Y%m%d-%H%M%S")
    open(backup, "w", encoding="utf-8").write(original)
    open(SRC, "w", encoding="utf-8").write(s)
    print("\n  backup: %s" % backup)
    print("  written: %s" % SRC)
    return 0


if __name__ == "__main__":
    sys.exit(main())