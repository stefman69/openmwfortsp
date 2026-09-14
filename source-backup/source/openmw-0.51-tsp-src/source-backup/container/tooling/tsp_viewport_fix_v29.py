#!/usr/bin/env python3
"""
tsp_viewport_fix_v29.py - no env gate, no silence, whole-method replacement

WHY V27 AND V28 BOTH FAILED
===========================

Both were gated on std::getenv("OPENMW_TSP_FIX_NULL_VIEWPORT"). Measured on
device, that gate never opened, and neither version could say so:

    grep -a -c "TSP_CAM_FIX skip" <deployed binary>   -> 1     (code IS there)
    line 134 of renderingmanager.cpp                  -> V28   (placed right)
    export OPENMW_TSP_FIX_NULL_VIEWPORT=1             -> present, same block
                                                          as the LD_PRELOAD
                                                          line that works
    TSP_CAM_AUDIT lines in log                        -> 12    (visitor runs)
    TSP_CAM_AUDIT ... viewport=-1x-1                  -> null viewport seen
    TSP_CAM_FIX lines in log                          -> 0

Code present, correctly placed, condition unambiguously true, variable
exported, and nothing logged. The gate is the only thing left, so the gate is
gone. A diagnostic whose failure mode is silence is a bad diagnostic, and this
one cost three runs.

WHAT V29 DOES
=============

  - No environment variable anywhere. The repair always runs. To turn it off,
    revert the patch - that is the off switch.

  - Every camera the visitor reaches logs exactly ONE TSP_CAM_FIX line:

        action=repaired   had no viewport (or the default 800x600), and was
                          given the first real viewport seen this traversal
        action=kept       already had a sane viewport, left alone
        action=no-source  needed repair but no viewport had been seen yet

    Silence is now impossible. If the next run logs nothing at all, the
    visitor is not reaching apply() and that is a different bug entirely.

  - osg::View / getView() is gone. v28 routed through cam.getView(), which is
    null for a camera that is only a scene-graph node - which is exactly what
    the target camera is. The fallback viewport is the only source now.

HOW IT APPLIES
==============

Not by matching a fragment. It finds the unique marker

    // TSP_CAMERA_VIEWPORT_AUDIT_051_V26

then locates `void apply(osg::Camera& cam) override` below it, brace-matches
the whole method (skipping string literals and comments), and replaces it
wholesale. So it converges to byte-identical output from a clean tree, a v27
tree, or a v28 tree, and no amount of drift inside that method can misplace
it. It prints what it found before writing anything.

APPLY
=====

    sudo docker cp ~/Downloads/tsp_viewport_fix_v29.py openmw_builder:/root/
    sudo docker exec -i openmw_builder python3 /root/tsp_viewport_fix_v29.py

REVERT
======

    sudo docker exec -i openmw_builder sh -c \
      'cd /root/openmw-0.51-tsp-src/apps/openmw/mwrender && \
       ls -t renderingmanager.cpp.tspvp29-* | head -1 | \
       xargs -I{} cp {} renderingmanager.cpp'
"""

import os
import sys
import time

SRC = "/root/openmw-0.51-tsp-src/apps/openmw/mwrender/renderingmanager.cpp"

CLASS_MARKER = "// TSP_CAMERA_VIEWPORT_AUDIT_051_V26"
METHOD_SIG = "void apply(osg::Camera& cam) override"

NEW_METHOD = '''void apply(osg::Camera& cam) override
        {
            const osg::Viewport* vp = cam.getViewport();
            const int w = vp ? static_cast<int>(vp->width()) : -1;
            const int h = vp ? static_cast<int>(vp->height()) : -1;
            const bool isDefault = (w == 800 && h == 600);

            Log(Debug::Info)
                << "TSP_CAM_AUDIT " << mTag
                << " name=\\"" << cam.getName() << "\\""
                << " viewport=" << w << "x" << h
                << " xy=" << (vp ? static_cast<int>(vp->x()) : -1)
                << "," << (vp ? static_cast<int>(vp->y()) : -1)
                << " render_order=" << static_cast<int>(cam.getRenderOrder())
                << " rtt=" << static_cast<int>(cam.getRenderTargetImplementation())
                << " mask=" << static_cast<unsigned long>(cam.getNodeMask())
                << (isDefault ? "   <<<< DEFAULT osg::Viewport(0,0,800,600)" : "");

            // TSP_NULL_VIEWPORT_FIX_051_V29
            // No environment gate. v27 and v28 were gated and both went silent
            // on device with no way to see why. Every path below logs exactly
            // one TSP_CAM_FIX line, so this can never be quiet again. The off
            // switch is reverting the patch.
            //
            // osg::Viewport's default constructor is (0,0,800,600), so a
            // camera holding no viewport - or exactly that one - is the only
            // thing in this graph that can put those numbers into GL. Hand it
            // the first real viewport this traversal has seen. Traversal order
            // on device is consistently SceneCam (1280x720) first, so one is
            // always in hand by the time the null camera is reached.
            if (vp != nullptr && !isDefault && mFallbackViewport == nullptr)
                mFallbackViewport = cam.getViewport();

            if (vp == nullptr || isDefault)
            {
                if (mFallbackViewport == nullptr)
                {
                    Log(Debug::Info)
                        << "TSP_CAM_FIX " << mTag
                        << " name=\\"" << cam.getName() << "\\""
                        << " action=no-source"
                        << " was=" << w << "x" << h
                        << " render_order=" << static_cast<int>(cam.getRenderOrder());
                }
                else
                {
                    cam.setViewport(mFallbackViewport);

                    Log(Debug::Info)
                        << "TSP_CAM_FIX " << mTag
                        << " name=\\"" << cam.getName() << "\\""
                        << " action=repaired"
                        << " was=" << w << "x" << h
                        << " now=" << static_cast<int>(mFallbackViewport->width())
                        << "x" << static_cast<int>(mFallbackViewport->height())
                        << " render_order=" << static_cast<int>(cam.getRenderOrder())
                        << " rtt=" << static_cast<int>(cam.getRenderTargetImplementation())
                        << " mask=" << static_cast<unsigned long>(cam.getNodeMask());
                }
            }
            else
            {
                Log(Debug::Info)
                    << "TSP_CAM_FIX " << mTag
                    << " name=\\"" << cam.getName() << "\\""
                    << " action=kept"
                    << " viewport=" << w << "x" << h;
            }

            traverse(cam);
        }'''

MEMBER_OLD = """    private:
        const char* mTag;
    };"""

MEMBER_NEW = """    private:
        const char* mTag;
        osg::Viewport* mFallbackViewport = nullptr;
    };"""


def find_method_end(s, open_brace_idx):
    """Brace-match from an opening brace, skipping strings, chars and comments."""
    i = open_brace_idx
    depth = 0
    n = len(s)

    while i < n:
        c = s[i]

        if c == '/' and i + 1 < n and s[i + 1] == '/':
            j = s.find('\n', i)
            i = n if j < 0 else j + 1
            continue

        if c == '/' and i + 1 < n and s[i + 1] == '*':
            j = s.find('*/', i + 2)
            i = n if j < 0 else j + 2
            continue

        if c in ('"', "'"):
            quote = c
            i += 1
            while i < n:
                if s[i] == '\\':
                    i += 2
                    continue
                if s[i] == quote:
                    i += 1
                    break
                i += 1
            continue

        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return i + 1

        i += 1

    return -1


def main():
    if not os.path.isfile(SRC):
        print("  ERROR: %s not found" % SRC)
        return 1

    s = open(SRC, encoding="utf-8").read()
    original = s

    # ---- diagnose what is currently in there -----------------------------
    print("  found in file:")
    for marker in ("TSP_CAMERA_VIEWPORT_AUDIT_051_V26",
                   "TSP_NULL_VIEWPORT_FIX_051_V27",
                   "TSP_NULL_VIEWPORT_FIX_051_V28",
                   "TSP_NULL_VIEWPORT_FIX_051_V29",
                   "mFallbackViewport",
                   "#include <osg/View>"):
        print("    %-40s x%d" % (marker, s.count(marker)))
    print()

    # ---- locate the class -------------------------------------------------
    if s.count(CLASS_MARKER) != 1:
        print("  ERROR: expected exactly 1 %s, found %d - NOTHING WRITTEN."
              % (CLASS_MARKER, s.count(CLASS_MARKER)))
        return 1
    cls_at = s.index(CLASS_MARKER)

    # ---- locate the method below it --------------------------------------
    sig_at = s.find(METHOD_SIG, cls_at)
    if sig_at < 0:
        print("  ERROR: '%s' not found after the class marker - NOTHING WRITTEN."
              % METHOD_SIG)
        return 1

    brace_at = s.find('{', sig_at + len(METHOD_SIG))
    if brace_at < 0:
        print("  ERROR: no opening brace after the method signature - NOTHING WRITTEN.")
        return 1

    end_at = find_method_end(s, brace_at)
    if end_at < 0:
        print("  ERROR: braces did not balance - NOTHING WRITTEN.")
        return 1

    old_method = s[sig_at:end_at]
    print("  method spans %d chars (%d lines)"
          % (len(old_method), old_method.count('\n') + 1))

    if old_method == NEW_METHOD:
        print("\n  VERIFIED: apply() already at v29")
    else:
        s = s[:sig_at] + NEW_METHOD + s[end_at:]
        print("  replaced         apply() -> v29")

    # ---- the fallback member ---------------------------------------------
    if "mFallbackViewport* " in s or "osg::Viewport* mFallbackViewport" in s:
        print("  already present  mFallbackViewport member")
    elif MEMBER_OLD in s:
        s = s.replace(MEMBER_OLD, MEMBER_NEW, 1)
        print("  applied          mFallbackViewport member")
    else:
        print("  ERROR: could not find the private member block - NOTHING WRITTEN.")
        return 1

    if s == original:
        print("\n  VERIFIED: no changes needed")
        return 0

    backup = SRC + ".tspvp29-" + time.strftime("%Y%m%d-%H%M%S")
    open(backup, "w", encoding="utf-8").write(original)
    open(SRC, "w", encoding="utf-8").write(s)
    print("\n  backup:  %s" % backup)
    print("  VERIFIED: written %s" % SRC)
    return 0


if __name__ == "__main__":
    sys.exit(main())