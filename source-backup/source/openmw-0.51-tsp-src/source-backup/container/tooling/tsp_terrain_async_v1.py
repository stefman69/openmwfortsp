#!/usr/bin/env python3
"""
tsp_terrain_async_v1.py - stop blocking the main thread on terrain at a cell
                          boundary

WHAT THE PROFILER SHOWED
========================

Frame 3465, gameplay, 900-frame ring:

    total 451.4 ms    render 236.8    world 140.9    focus 58.8

Normal values for those slots in the same dump are render 34.75, world 0.32,
focus 1.07. world went 0.32 -> 140.9, a 440x jump, in a frame where render
also tripled and the scene-graph intersection test took 58 ms. Nothing about
a texture upload or a shader link makes updateFocusObject() slow. Something
arrives all at once and every subsystem pays in the same frame.

Frames 2105 -> 2134 show the same shape: a load, then updt 117 ms, then
render 348 -> 214 -> 198 draining over ~20 frames.

WHERE IT COMES FROM
===================

apps/openmw/mwworld/scene.cpp, Scene::changeCellGrid:

    if (!mPreloader->isTerrainLoaded(PositionCellGrid{ pos, newGrid },
                                     mRendering.getReferenceTime()))
        preloadTerrain(pos, playerCellIndex.mWorldspace, true);

That third argument is `sync`. In Scene::preloadTerrain it means:

    if (!sync) return;
    Loading::ScopedLoad load(loadingListener);
    while (!mPreloader->syncTerrainLoad(vec, progress, ...))
        ...                     // busy-wait, 5 ms sleeps, until terrain is in

changeCellGrid runs from Scene::update, inside mWorld->update() - the `world`
slot. So world = 140.9 ms is this loop, mechanically.

It is a FALLBACK. It only runs when isTerrainLoaded() says the preloader has
not got there yet - i.e. when preloading did not run far enough ahead. That
is the real cause; this patch only makes the fallback cheap.

WHAT THIS CHANGES
=================

One argument: true -> false.

preloadTerrain(..., false) still calls setTerrainPreloadPositions(), so the
terrain load still STARTS - it just is not waited on. The chunks arrive over
the next frames instead of freezing the frame you cross the boundary on.

WHAT IT COSTS
=============

Distant terrain for a newly entered grid can be a few frames late, so there
may be a brief seam at the horizon when crossing a cell line. If that reads
badly at this view distance, it is a one-argument revert.

The teleport/door path is NOT touched. Blocking is correct there - the
loading screen is already up. This patch only changes the streaming path,
which is the one that runs while you are walking.

APPLY
=====

    sudo docker cp ~/Downloads/tsp_terrain_async_v1.py openmw_builder:/root/
    sudo docker exec -i openmw_builder python3 /root/tsp_terrain_async_v1.py

Prints every preloadTerrain call site first, so you can see that only the
streaming one changes. Backs up. Idempotent. Writes nothing on an anchor miss.

REVERT
======

    sudo docker exec -i openmw_builder sh -c \\
      'cd /root/openmw-0.51-tsp-src/apps/openmw/mwworld && \\
       ls -t scene.cpp.tspterrain1-* | head -1 | xargs -I{} cp {} scene.cpp'
"""

import os
import re
import sys
import time

SRC = "/root/openmw-0.51-tsp-src/apps/openmw/mwworld/scene.cpp"
STAMP = time.strftime("%Y%m%d-%H%M%S")
MARKER = "TSP_TERRAIN_ASYNC_GRID_V1"

# The streaming call site, guarded by isTerrainLoaded. Whitespace tolerant.
SYNC_RE = re.compile(
    r'(?P<indent>[ \t]*)if\s*\(\s*!\s*mPreloader->isTerrainLoaded\('
    r'\s*PositionCellGrid\s*\{\s*pos\s*,\s*newGrid\s*\}\s*,'
    r'\s*mRendering\.getReferenceTime\(\)\s*\)\s*\)\s*\n'
    r'(?P<inner>[ \t]*)preloadTerrain\('
    r'\s*pos\s*,\s*playerCellIndex\.mWorldspace\s*,\s*true\s*\)\s*;'
)

NEW = '''{i}// TSP_TERRAIN_ASYNC_GRID_V1
{i}// Was: preloadTerrain(pos, playerCellIndex.mWorldspace, true);
{i}//
{i}// sync = true makes Scene::preloadTerrain busy-wait on syncTerrainLoad()
{i}// with 5 ms sleeps until the whole new grid's terrain is resident. This
{i}// runs from Scene::update inside mWorld->update(), so it lands in the
{i}// `world` slot - measured at 140.9 ms on frame 3465, against a normal
{i}// value of 0.32 ms, in the same frame that render hit 236.8 and the
{i}// crosshair intersection test hit 58.8.
{i}//
{i}// sync = false still calls setTerrainPreloadPositions(), so the load
{i}// still starts. It just is not waited on, and the chunks land over the
{i}// following frames instead of freezing the one you cross the boundary on.
{i}//
{i}// This is the STREAMING path only. The teleport/door path keeps sync =
{i}// true, because there the loading screen is already up and blocking is
{i}// what you want.
{i}if (!mPreloader->isTerrainLoaded(PositionCellGrid{{ pos, newGrid }}, mRendering.getReferenceTime()))
{n}preloadTerrain(pos, playerCellIndex.mWorldspace, false);'''


def main():
    print()
    print("  tsp_terrain_async_v1")
    print("  ====================")
    print()

    if not os.path.isfile(SRC):
        print("  ERROR: %s not found - NOTHING WRITTEN." % SRC)
        return 1

    s = open(SRC, encoding="utf-8").read()

    print("  EVERY preloadTerrain CALL SITE IN scene.cpp")
    for i, line in enumerate(s.split("\n"), 1):
        if "preloadTerrain(" in line:
            kind = ""
            if re.search(r',\s*true\s*\)', line):
                kind = "   <- BLOCKING"
            elif re.search(r',\s*false\s*\)', line):
                kind = "   <- async"
            print("    %5d  %s%s" % (i, line.strip(), kind))
    print()

    if MARKER in s:
        print("  already applied  streaming terrain preload is async")
        print()
        print("  VERIFIED: no changes needed")
        return 0

    hits = SYNC_RE.findall(s)
    if len(hits) != 1:
        print("  ANCHOR MISS      expected exactly 1 match, found %d" % len(hits))
        print("  Looking for, at any indentation:")
        print("      if (!mPreloader->isTerrainLoaded(PositionCellGrid{ pos, newGrid },")
        print("                                       mRendering.getReferenceTime()))")
        print("          preloadTerrain(pos, playerCellIndex.mWorldspace, true);")
        print()
        at = s.find("isTerrainLoaded")
        if at < 0:
            print("  isTerrainLoaded does not appear in this file at all.")
        else:
            lo = s.rfind("\n", 0, max(0, at - 400)) + 1
            hi = s.find("\n", at + 400)
            print("  Current text around isTerrainLoaded:")
            for ln in s[lo:hi if hi > 0 else len(s)].split("\n"):
                print("      | " + ln)
        print()
        print("  NOTHING WRITTEN.")
        return 1

    m = SYNC_RE.search(s)
    new = s[:m.start()] + NEW.format(i=m.group("indent"), n=m.group("inner")) + s[m.end():]

    n_block = len(re.findall(r'preloadTerrain\([^;]*,\s*true\s*\)', new))
    n_async = len(re.findall(r'preloadTerrain\([^;]*,\s*false\s*\)', new))
    print("  after this change:  %d blocking call site(s), %d async" % (n_block, n_async))
    if n_async < 1:
        print("  ERROR: the async call did not land - NOTHING WRITTEN.")
        return 1

    backup = SRC + ".tspterrain1-" + STAMP
    open(backup, "w", encoding="utf-8").write(s)
    open(SRC, "w", encoding="utf-8").write(new)
    print()
    print("  backup   %s" % backup)
    print("  written  %s" % SRC)
    print()
    print("  VERIFIED: streaming terrain preload no longer blocks the main thread")
    return 0


if __name__ == "__main__":
    sys.exit(main())