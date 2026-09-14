#!/usr/bin/env python3
"""
tsp_terrain_lead_v1.py - revert the async fallback, fix the aim instead

WHAT CHANGED MY MIND
====================

I claimed preloading was disabled and that was why the blocking fallback in
changeCellGrid fired. Reading Scene::preloadCells shows that is wrong - look
at where the braces are:

    if (mCurrentCell->isExterior())
        exteriorPositions.push_back(PositionCellGrid{
            predictedPos, gridCenterToBounds(getNewGridCenter(predictedPos, ...)) });
    mLastPlayerPos = playerPos;
    if (mPreloadEnabled)
    {
        if (mPreloadDoors)        preloadTeleportDoorDestinations(...);
        if (mPreloadExteriorGrid) preloadExteriorGrid(...);
        if (mPreloadFastTravel)   preloadFastTravelDestinations(...);
    }
    mPreloader->setTerrainPreloadPositions(exteriorPositions);   // OUTSIDE the gate

Terrain streaming runs unconditionally. mPreloadEnabled only gates doors, the
exterior CELL grid (which pulls object instances - the expensive, RAM-hungry
part), and fast travel.

So the fallback does not fire because preloading is off. It fires because of
AIM. The preloader is pointed at

    predictedPos = playerPos + moved / dt * mPredictionTime

which is one prediction-time of travel ahead, while changeCellGrid asks
isTerrainLoaded() about the grid the player has ACTUALLY entered. From
getNewGridCenter, the grid recenters once the player is
cellSize/2 + mCellLoadingThreshold from the old center - about 1000 units
INTO the new cell. One prediction-time of lead is not enough to have pulled a
grid of terrain off this SD card, so the check fails and the main thread
blocks in syncTerrainLoad.

WHAT THIS DOES
==============

1. REVERTS tsp_terrain_async_v1. preloadTerrain goes back to sync = true.

   The async change made the fallback cheap. This one stops the fallback from
   being reached, which is better: the terrain is actually present instead of
   arriving late. Keeping sync = true also means that if this fix ever fails,
   it fails loudly as a hitch rather than quietly as missing terrain - and the
   profiler will show it in the `world` slot exactly as before.

2. Aims a SECOND terrain preload position further along the movement vector,
   so the grid the player is about to enter is already warm.

       lead = moved / dt * (mPredictionTime * TSP_LEAD_FACTOR)
       clamped to at most one cell
       only pushed when it lands in a DIFFERENT grid than the near position

   The guard matters: standing still or moving slowly adds nothing, because
   the far center equals the near center and no second position is pushed.
   Cost only appears when actually travelling toward a boundary.

   This is terrain chunks only. It does NOT enable preloadExteriorGrid,
   preloadTeleportDoorDestinations or preloadFastTravelDestinations - those
   are the ones that pull object instances and cost RAM plus contention on
   the resource-cache mutex, and are the likely reason turning `preload
   enabled` on made framerate worse.

TUNING
======

TSP_LEAD_FACTOR is a named constant right at the change. If framerate drops,
halve it. If the `world` slot still spikes at cell boundaries, raise it. It
multiplies mPredictionTime, so 6.0 means roughly six prediction-times of lead,
capped at one cell of distance.

APPLY
=====

    sudo docker cp ~/Downloads/tsp_terrain_lead_v1.py openmw_builder:/root/
    sudo docker exec -i openmw_builder python3 /root/tsp_terrain_lead_v1.py

Handles both starting points: an async-patched tree (reverts it first) and a
clean one. Backs up. Idempotent. Writes nothing if any anchor misses.

REVERT
======

    sudo docker exec -i openmw_builder sh -c \\
      'cd /root/openmw-0.51-tsp-src/apps/openmw/mwworld && \\
       ls -t scene.cpp.tsplead1-* | head -1 | xargs -I{} cp {} scene.cpp'
"""

import os
import re
import sys
import time

SRC = "/root/openmw-0.51-tsp-src/apps/openmw/mwworld/scene.cpp"
STAMP = time.strftime("%Y%m%d-%H%M%S")
ASYNC_MARKER = "TSP_TERRAIN_ASYNC_GRID_V1"
LEAD_MARKER = "TSP_TERRAIN_LEAD_V1"

# ---------------------------------------------------------------- revert
# the block tsp_terrain_async_v1 wrote
ASYNC_RE = re.compile(
    r'[ \t]*// TSP_TERRAIN_ASYNC_GRID_V1\n'
    r'(?:[ \t]*//[^\n]*\n)*'
    r'(?P<i>[ \t]*)if \(!mPreloader->isTerrainLoaded\(PositionCellGrid\{ pos, newGrid \}, '
    r'mRendering\.getReferenceTime\(\)\)\)\n'
    r'(?P<n>[ \t]*)preloadTerrain\(pos, playerCellIndex\.mWorldspace, false\);'
)

ASYNC_REVERT = ('{i}if (!mPreloader->isTerrainLoaded(PositionCellGrid{{ pos, newGrid }}, '
                'mRendering.getReferenceTime()))\n'
                '{n}preloadTerrain(pos, playerCellIndex.mWorldspace, true);')

# ---------------------------------------------------------------- the fix
PRELOAD_RE = re.compile(
    r'(?P<i>[ \t]*)if\s*\(\s*mCurrentCell->isExterior\(\)\s*\)\s*\n'
    r'[ \t]*exteriorPositions\.push_back\(\s*PositionCellGrid\s*\{\s*\n'
    r'[ \t]*predictedPos\s*,\s*gridCenterToBounds\(\s*getNewGridCenter\('
    r'\s*predictedPos\s*,\s*&mCurrentGridCenter\s*\)\s*\)\s*\}\s*\)\s*;'
)

NEW_PRELOAD = '''{i}if (mCurrentCell->isExterior())
{i}{{
{i}    const osg::Vec2i tspNearCenter = getNewGridCenter(predictedPos, &mCurrentGridCenter);
{i}    exteriorPositions.push_back(PositionCellGrid{{ predictedPos, gridCenterToBounds(tspNearCenter) }});

{i}    // TSP_TERRAIN_LEAD_V1
{i}    // Aim a second terrain preload further along the movement vector, so the
{i}    // grid we are ABOUT to enter is warm before changeCellGrid asks for it.
{i}    //
{i}    // Without this, the only preload target is predictedPos - one
{i}    // mPredictionTime of travel ahead. getNewGridCenter does not recenter
{i}    // until the player is cellSize/2 + mCellLoadingThreshold from the old
{i}    // centre, i.e. ~1000 units INTO the new cell, so by the time
{i}    // changeCellGrid calls isTerrainLoaded() for the new grid, that grid has
{i}    // had roughly one prediction-time of warning. That is not enough to pull
{i}    // it off this SD card, the check fails, and preloadTerrain(..., true)
{i}    // busy-waits in syncTerrainLoad on the main thread. Measured: the `world`
{i}    // slot at 140.9 ms on frame 3465 against a normal value of 0.32 ms.
{i}    //
{i}    // Terrain chunks only. This deliberately does NOT enable
{i}    // preloadExteriorGrid / doors / fast travel - those pull object
{i}    // instances, cost real RAM, and put the preloader threads in contention
{i}    // with the main thread over the resource-cache mutex.
{i}    //
{i}    // The tspFarCenter != tspNearCenter guard means standing still or moving
{i}    // slowly costs nothing: no second position is pushed unless the
{i}    // projection actually lands in a different grid.
{i}    //
{i}    // TUNING: halve TSP_LEAD_FACTOR if framerate drops, raise it if `world`
{i}    // still spikes when crossing a cell line.
{i}    const float TSP_LEAD_FACTOR = 6.0f;
{i}    osg::Vec3f tspLead = moved / dt * (mPredictionTime * TSP_LEAD_FACTOR);
{i}    const float tspLeadLen = tspLead.length();
{i}    if (tspLeadLen > 1.0f)
{i}    {{
{i}        const float tspMaxLead
{i}            = static_cast<float>(ESM::getCellSize(mWorld.getCurrentWorldspace()));
{i}        if (tspLeadLen > tspMaxLead)
{i}            tspLead *= tspMaxLead / tspLeadLen;
{i}        const osg::Vec3f tspFarPos = playerPos + tspLead;
{i}        const osg::Vec2i tspFarCenter = getNewGridCenter(tspFarPos, &mCurrentGridCenter);
{i}        if (tspFarCenter != tspNearCenter)
{i}            exteriorPositions.push_back(
{i}                PositionCellGrid{{ tspFarPos, gridCenterToBounds(tspFarCenter) }});
{i}    }}
{i}}}'''


def main():
    print()
    print("  tsp_terrain_lead_v1")
    print("  ===================")
    print()

    if not os.path.isfile(SRC):
        print("  ERROR: %s not found - NOTHING WRITTEN." % SRC)
        return 1

    s = open(SRC, encoding="utf-8").read()
    original = s

    print("  BEFORE")
    print("    %-34s x%d" % ("TSP_TERRAIN_ASYNC_GRID_V1", s.count(ASYNC_MARKER)))
    print("    %-34s x%d" % ("TSP_TERRAIN_LEAD_V1", s.count(LEAD_MARKER)))
    for i, line in enumerate(s.split("\n"), 1):
        if "preloadTerrain(" in line and not line.lstrip().startswith("//"):
            kind = "  <- BLOCKING" if re.search(r',\s*true\s*\)', line) else (
                   "  <- async" if re.search(r',\s*false\s*\)', line) else "")
            print("    %5d  %s%s" % (i, line.strip(), kind))
    print()

    # ---- step 1: revert the async change -------------------------------
    if ASYNC_MARKER in s:
        m = ASYNC_RE.search(s)
        if not m:
            print("  ANCHOR MISS      %s present but its block did not match" % ASYNC_MARKER)
            print("  Restore from the async backup first:")
            print("    ls -t %s.tspterrain1-* | head -1 | xargs -I{} cp {} %s"
                  % (SRC, SRC))
            print("\n  NOTHING WRITTEN.")
            return 1
        s = (s[:m.start()]
             + ASYNC_REVERT.format(i=m.group("i"), n=m.group("n"))
             + s[m.end():])
        if ASYNC_MARKER in s:
            print("  ERROR: async marker survived the revert - NOTHING WRITTEN.")
            return 1
        print("  reverted         async fallback -> preloadTerrain(..., true)")
    else:
        print("  nothing to revert  async patch is not present")

    # ---- step 2: the lead-time fix -------------------------------------
    if LEAD_MARKER in s:
        print("  already applied  terrain lead-time preload")
    else:
        hits = PRELOAD_RE.findall(s)
        if len(hits) != 1:
            print("  ANCHOR MISS      preloadCells exterior push_back: found %d, need 1"
                  % len(hits))
            print("  Looking for:")
            print("      if (mCurrentCell->isExterior())")
            print("          exteriorPositions.push_back(PositionCellGrid{")
            print("              predictedPos, gridCenterToBounds(getNewGridCenter("
                  "predictedPos, &mCurrentGridCenter)) });")
            at = s.find("exteriorPositions.push_back")
            if at >= 0:
                lo = s.rfind("\n", 0, max(0, at - 300)) + 1
                hi = s.find("\n", at + 300)
                print("\n  Current text there:")
                for ln in s[lo:hi if hi > 0 else len(s)].split("\n"):
                    print("      | " + ln)
            print("\n  NOTHING WRITTEN.")
            return 1
        m = PRELOAD_RE.search(s)
        s = s[:m.start()] + NEW_PRELOAD.format(i=m.group("i")) + s[m.end():]
        print("  applied          terrain lead-time preload in Scene::preloadCells")

    if s == original:
        print()
        print("  VERIFIED: no changes needed")
        return 0

    # ---- sanity ---------------------------------------------------------
    code = [ln for ln in s.split("\n") if not ln.lstrip().startswith("//")]
    n_block = sum(1 for ln in code if re.search(r'preloadTerrain\([^;]*,\s*true\s*\)', ln))
    n_async = sum(1 for ln in code if re.search(r'preloadTerrain\([^;]*,\s*false\s*\)', ln))
    depth = 0
    for ch in s:
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
    print()
    print("  CHECKS")
    print("    blocking preloadTerrain call sites   %d   (2 expected: teleport + fallback)"
          % n_block)
    print("    async preloadTerrain call sites      %d" % n_async)
    print("    brace balance over the whole file    %d   (must be 0)" % depth)
    if depth != 0:
        print("\n  BRACES DO NOT BALANCE - NOTHING WRITTEN.")
        return 1

    backup = SRC + ".tsplead1-" + STAMP
    open(backup, "w", encoding="utf-8").write(original)
    open(SRC, "w", encoding="utf-8").write(s)
    print()
    print("  backup   %s" % backup)
    print("  written  %s" % SRC)
    print()
    print("  VERIFIED: async reverted, terrain preload now aims ahead of the player")
    return 0


if __name__ == "__main__":
    sys.exit(main())