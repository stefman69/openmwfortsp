#!/usr/bin/env python3
"""
tsp_purge_gradual_v22.py - make the memory purge measured, then make it stop
                           doing the two things that are now pure cost

WHAT THE AUDIT FOUND
====================

Three purge sites, all synchronous, all on the main thread, none of them timed:

  1. apps/openmw/engine.cpp:379
         rs->releaseGLObjects(nullptr);
     Unconditional on cell change. This is not a small call. It takes every
     resource manager's cache mutex in turn and walks EVERY cached object's
     entire subgraph - every StateSet, Drawable and Texture - discarding their
     GPU state. Two separate costs follow:
       - the traversal itself: main thread, no time budget, and the cache
         mutex is held throughout, so the preloader threads stall behind it;
       - the re-upload storm: releaseGLObjects does NOT remove anything from
         the cache. Everything still cached and still about to be drawn has to
         re-upload its textures and rebuild its buffers on next use.

  2. components/resource/resourcesystem.cpp, in updateCache:
         ::malloc_trim(0);            // TSP_MEMORY_TRIM_UPDATE_051_V7
     Throttled to once every five seconds. malloc_trim walks every arena's
     free lists and madvise(MADV_DONTNEED)s each releasable page - on a
     ~600 MB heap that is a long synchronous operation, and every page it
     drops costs a minor fault plus a zero-fill the next time the allocator
     hands that address out again. It buys a hitch now AND a fault storm
     afterwards.

     It was added when there was no swap and giving pages back to the kernel
     was the only relief available. There is swap now, at swappiness 150, and
     major faults went 997 -> 2 per 10s. The kernel is already doing this job,
     better, off the main thread.

  3. ObjectCache::update erase_if's the whole map under its mutex and destroys
     everything it collected in one batch. Timed here at the ResourceSystem
     level (per manager), because instrumenting objectcache.hpp would rebuild
     the world for a number we can get without touching it.

WHAT THIS CHANGES
=================

  MEASURE everything. Every purge site logs its own wall-clock milliseconds:

      TSP_PURGE updateCache ms=... worst_mgr=N worst_ms=...
      TSP_PURGE malloc_trim ms=... released=N every_s=...
      TSP_PURGE clearCache ms=... managers=N
      TSP_PURGE releaseGLObjects ms=... managers=N state=0|1
      TSP_CELL_GLRELEASE action=released ms=... avail_before_kb=...
      TSP_CELL_GLRELEASE action=skipped  avail_kb=... floor_kb=...

  updateCache only logs when it exceeds a threshold (default 4 ms), because it
  runs constantly. Everything else logs every time - those are rare events.

  CHANGE the two that are now pure cost:

    malloc_trim   default OFF   (was: every 5 s)
    cell release  now fires only when MemAvailable is actually low
                  (default floor 192 MB; healthy with swap measures ~375 MB,
                  and the old crash regime was 165-186 MB, so this arms just
                  above the danger zone and stays quiet above it)

DEFAULTS ARE THE FIX
====================

No environment variable is required for the new behaviour. The variables below
exist only to put the OLD behaviour back for an A/B, and each one logs the
value it resolved to on first use. Silence means the fix is active - the
opposite of v27/v28, which were gated ON and went quiet.

    OPENMW_TSP_MALLOC_TRIM_SECS     unset -> 0 (off).  5 = old behaviour.
    OPENMW_TSP_GLRELEASE_FLOOR_KB   unset -> 196608 (192 MB).
                                    0  = always release (old behaviour)
                                    -1 = never release
    OPENMW_TSP_PURGE_LOG_MS         unset -> 4.0. Threshold for updateCache.

WHAT THIS DOES NOT DO
=====================

It does not touch the save-load full reload, and it does not add preloading.
Those come after this measures, not before.

APPLY
=====

    sudo docker cp ~/Downloads/tsp_purge_gradual_v22.py openmw_builder:/root/
    sudo docker exec -i openmw_builder python3 /root/tsp_purge_gradual_v22.py

Backs up every file it touches, idempotent, and writes NOTHING if any anchor
misses - it prints the text it could not match so the miss is fixable in one
round trip.

REVERT
======

    sudo docker exec -i openmw_builder sh -c \\
      'cd /root/openmw-0.51-tsp-src && \\
       for f in apps/openmw/engine.cpp components/resource/resourcesystem.cpp; do \\
         ls -t "$f".tsppurge22-* 2>/dev/null | head -1 | xargs -I{} cp {} "$f"; \\
       done'
"""

import os
import re
import sys
import time

SRCROOT = "/root/openmw-0.51-tsp-src"
ENGINE = os.path.join(SRCROOT, "apps/openmw/engine.cpp")
RESSYS = os.path.join(SRCROOT, "components/resource/resourcesystem.cpp")

STAMP = time.strftime("%Y%m%d-%H%M%S")
MARKER = "TSP_PURGE_V22"


# ===========================================================================
# helpers
# ===========================================================================

def ensure_include(s, header):
    """Add #include <header> if absent, anchored on the first angle include."""
    if re.search(r'^\s*#include\s+<%s>' % re.escape(header), s, re.M):
        return s, "already present  #include <%s>" % header

    m = re.search(r'^\s*#include\s+<[^>]+>\s*$', s, re.M)
    if not m:
        return None, "ANCHOR MISS      no #include <...> line for <%s>" % header

    return (s[:m.start()] + "#include <%s>\n" % header + s[m.start():],
            "applied          #include <%s>" % header)


def find_pp_region(s, needle):
    """
    Locate the #if...#endif region that contains `needle`, honouring nesting.
    Returns (start_index_of_hash_if, end_index_after_endif_line) or None.
    """
    at = s.find(needle)
    if at < 0:
        return None

    # walk backwards over lines to the nearest unmatched #if/#ifdef/#ifndef
    lines = s[:at].split("\n")
    depth = 0
    start_line = None
    for i in range(len(lines) - 1, -1, -1):
        t = lines[i].lstrip()
        if t.startswith("#endif"):
            depth += 1
        elif t.startswith("#if"):
            if depth == 0:
                start_line = i
                break
            depth -= 1
    if start_line is None:
        return None

    start = len("\n".join(lines[:start_line]))
    if start_line > 0:
        start += 1  # step over the newline that joins into the previous line

    # walk forward from there to the matching #endif
    depth = 0
    i = start
    n = len(s)
    while i < n:
        eol = s.find("\n", i)
        if eol < 0:
            eol = n
        t = s[i:eol].lstrip()
        if t.startswith("#if"):
            depth += 1
        elif t.startswith("#endif"):
            depth -= 1
            if depth == 0:
                return (start, eol + 1 if eol < n else n)
        i = eol + 1

    return None


# ===========================================================================
# engine.cpp - the cell-change GL release
# ===========================================================================

CELL_RE = re.compile(
    r'(?P<indent>[ \t]*)\{[ \t]*\n'
    r'[ \t]*const long long before = tspReadMemAvailableKb\(\);[ \t]*\n'
    r'[ \t]*rs->releaseGLObjects\(nullptr\);[ \t]*\n'
    r'[ \t]*const long long after = tspReadMemAvailableKb\(\);[ \t]*\n'
    r'[ \t]*Log\(Debug::Info\) << "TSP_CELL_GLRELEASE avail_before_kb=" << before[ \t]*\n'
    r'[ \t]*<< " avail_after_kb=" << after[ \t]*\n'
    r'[ \t]*<< " reclaimed_kb=" << \(after - before\);[ \t]*\n'
    r'[ \t]*\}'
)

CELL_NEW = r'''{
    // TSP_PURGE_V22  TSP_CELL_GLRELEASE_PRESSURE_GATE
    //
    // rs->releaseGLObjects(nullptr) walks every cached object's whole
    // subgraph in every resource manager, holding each cache mutex the
    // entire time, and throws away GPU state for models that are still
    // cached and about to be drawn again. The traversal is the hitch;
    // the re-upload afterwards is the second one.
    //
    // It was unconditional because there was no swap and no other relief.
    // There is swap now. Fire it when memory is actually tight, and say
    // how long it took either way.
    //
    //   OPENMW_TSP_GLRELEASE_FLOOR_KB
    //     unset -> 196608 (192 MB): release only at or below that
    //     0     -> always release   (old behaviour)
    //     -1    -> never release
    static const long long tspGlReleaseFloorKb = []() -> long long {
        const char* tspEnv = std::getenv("OPENMW_TSP_GLRELEASE_FLOOR_KB");
        long long tspKb = 196608;
        const char* tspSrc = "default";
        if (tspEnv != nullptr && tspEnv[0] != '\0')
        {
            tspKb = std::strtoll(tspEnv, nullptr, 10);
            tspSrc = "env";
        }
        Log(Debug::Warning) << "TSP_CELL_GLRELEASE_CONFIG floor_kb=" << tspKb
                            << " source=" << tspSrc;
        return tspKb;
    }();

    const long long before = tspReadMemAvailableKb();

    if (tspGlReleaseFloorKb < 0
        || (tspGlReleaseFloorKb > 0 && before > tspGlReleaseFloorKb))
    {
        Log(Debug::Info) << "TSP_CELL_GLRELEASE action=skipped"
                         << " avail_kb=" << before
                         << " floor_kb=" << tspGlReleaseFloorKb;
    }
    else
    {
        const std::chrono::steady_clock::time_point tspT0
            = std::chrono::steady_clock::now();
        rs->releaseGLObjects(nullptr);
        const double tspMs = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - tspT0)
                                 .count();
        const long long after = tspReadMemAvailableKb();
        Log(Debug::Info) << "TSP_CELL_GLRELEASE action=released"
                         << " ms=" << tspMs
                         << " avail_before_kb=" << before
                         << " avail_after_kb=" << after
                         << " reclaimed_kb=" << (after - before)
                         << " floor_kb=" << tspGlReleaseFloorKb;
    }
}'''


def reindent(block, indent):
    out = []
    for line in block.split("\n"):
        out.append((indent + line) if line.strip() else line)
    return "\n".join(out)


def patch_engine():
    log = []

    if not os.path.isfile(ENGINE):
        return None, ["ERROR: %s not found" % ENGINE]

    s = open(ENGINE, encoding="utf-8").read()
    original = s

    if MARKER in s:
        log.append("  already applied  engine.cpp cell GL release gate")
    else:
        m = CELL_RE.search(s)
        if not m:
            log.append("  ANCHOR MISS      engine.cpp cell GL release block")
            log.append("")
            log.append("  Looking for this, at any indentation:")
            log.append("      {")
            log.append("          const long long before = tspReadMemAvailableKb();")
            log.append("          rs->releaseGLObjects(nullptr);")
            log.append("          ...")
            log.append("      }")
            log.append("")
            log.append("  Current text around releaseGLObjects in engine.cpp:")
            at = s.find("rs->releaseGLObjects")
            if at < 0:
                log.append("      <rs->releaseGLObjects not present at all>")
            else:
                lo = s.rfind("\n", 0, max(0, at - 900)) + 1
                hi = s.find("\n", at + 900)
                log.append("")
                for ln in s[lo:hi if hi > 0 else len(s)].split("\n"):
                    log.append("      | " + ln)
            return None, log

        s = s[:m.start()] + reindent(CELL_NEW, m.group("indent")) + s[m.end():]
        log.append("  applied          engine.cpp cell GL release gate")

    for header in ("chrono", "cstdlib"):
        s2, msg = ensure_include(s, header)
        log.append("  " + msg)
        if s2 is None:
            return None, log
        s = s2

    if s == original:
        return ("nochange", ENGINE, None), log
    return ("write", ENGINE, (original, s)), log


# ===========================================================================
# resourcesystem.cpp
# ===========================================================================

HELPERS = r'''    // TSP_PURGE_V22 helpers
    // Both knobs resolve once and log what they resolved to, so a run can
    // never leave you guessing which behaviour was actually in effect.
    namespace
    {
        double tspPurgeLogMs()
        {
            static const double sMs = []() -> double {
                const char* tspEnv = std::getenv("OPENMW_TSP_PURGE_LOG_MS");
                const double tspMs
                    = (tspEnv != nullptr && tspEnv[0] != '\0') ? std::atof(tspEnv) : 4.0;
                Log(Debug::Warning) << "TSP_PURGE_CONFIG log_threshold_ms=" << tspMs
                                    << " source=" << ((tspEnv && tspEnv[0]) ? "env" : "default");
                return tspMs;
            }();
            return sMs;
        }

        double tspMallocTrimSecs()
        {
            static const double sSecs = []() -> double {
                const char* tspEnv = std::getenv("OPENMW_TSP_MALLOC_TRIM_SECS");
                const double tspSecs
                    = (tspEnv != nullptr && tspEnv[0] != '\0') ? std::atof(tspEnv) : 0.0;
                Log(Debug::Warning) << "TSP_PURGE_CONFIG malloc_trim_every_s=" << tspSecs
                                    << " source=" << ((tspEnv && tspEnv[0]) ? "env" : "default")
                                    << (tspSecs > 0.0 ? "" : "   (malloc_trim disabled)");
                return tspSecs;
            }();
            return sSecs;
        }
    }

'''

UPDATE_SIG = "    void ResourceSystem::updateCache(double referenceTime)"

UPDATE_LOOP_RE = re.compile(
    r'[ \t]*for \(std::vector<BaseResourceManager\*>::iterator it = mResourceManagers\.begin\(\);'
    r' it != mResourceManagers\.end\(\);[ \t]*\n'
    r'[ \t]*\+\+it\)[ \t]*\n'
    r'[ \t]*\(\*it\)->updateCache\(referenceTime\);'
)

UPDATE_LOOP_NEW = r'''        // TSP_PURGE_V22
        // updateCache is where expiry actually happens: ObjectCache::update
        // erase_if's the whole map under its mutex and then destroys
        // everything it collected in one batch. If the frame hitch is the
        // purge, it is either here or in the malloc_trim below - this says
        // which, and which manager. Quiet unless it goes slow.
        {
            const std::chrono::steady_clock::time_point tspAllT0
                = std::chrono::steady_clock::now();
            double tspWorstMs = 0.0;
            std::size_t tspWorstIdx = 0;

            for (std::size_t tspI = 0; tspI < mResourceManagers.size(); ++tspI)
            {
                const std::chrono::steady_clock::time_point tspT0
                    = std::chrono::steady_clock::now();
                mResourceManagers[tspI]->updateCache(referenceTime);
                const double tspMs = std::chrono::duration<double, std::milli>(
                    std::chrono::steady_clock::now() - tspT0)
                                         .count();
                if (tspMs > tspWorstMs)
                {
                    tspWorstMs = tspMs;
                    tspWorstIdx = tspI;
                }
            }

            const double tspAllMs = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - tspAllT0)
                                        .count();

            if (tspAllMs >= tspPurgeLogMs())
                Log(Debug::Info) << "TSP_PURGE updateCache ms=" << tspAllMs
                                 << " worst_mgr=" << tspWorstIdx
                                 << " worst_ms=" << tspWorstMs
                                 << " managers=" << mResourceManagers.size();
        }'''

CLEAR_LOOP_RE = re.compile(
    r'[ \t]*for \(std::vector<BaseResourceManager\*>::iterator it = mResourceManagers\.begin\(\);'
    r' it != mResourceManagers\.end\(\);[ \t]*\n'
    r'[ \t]*\+\+it\)[ \t]*\n'
    r'[ \t]*\(\*it\)->clearCache\(\);'
)

CLEAR_LOOP_NEW = r'''        // TSP_PURGE_V22
        {
            const std::chrono::steady_clock::time_point tspClearT0
                = std::chrono::steady_clock::now();

            for (std::vector<BaseResourceManager*>::iterator it = mResourceManagers.begin();
                 it != mResourceManagers.end(); ++it)
                (*it)->clearCache();

            Log(Debug::Info) << "TSP_PURGE clearCache ms="
                             << std::chrono::duration<double, std::milli>(
                                    std::chrono::steady_clock::now() - tspClearT0)
                                    .count()
                             << " managers=" << mResourceManagers.size();
        }'''

GLREL_LOOP_RE = re.compile(
    r'[ \t]*for \(std::vector<BaseResourceManager\*>::const_iterator it = mResourceManagers\.begin\(\);[ \t]*\n'
    r'[ \t]*it != mResourceManagers\.end\(\); \+\+it\)[ \t]*\n'
    r'[ \t]*\(\*it\)->releaseGLObjects\(state\);'
)

GLREL_LOOP_NEW = r'''        // TSP_PURGE_V22
        {
            const std::chrono::steady_clock::time_point tspGlT0
                = std::chrono::steady_clock::now();

            for (std::vector<BaseResourceManager*>::const_iterator it = mResourceManagers.begin();
                 it != mResourceManagers.end(); ++it)
                (*it)->releaseGLObjects(state);

            Log(Debug::Info) << "TSP_PURGE releaseGLObjects ms="
                             << std::chrono::duration<double, std::milli>(
                                    std::chrono::steady_clock::now() - tspGlT0)
                                    .count()
                             << " managers=" << mResourceManagers.size()
                             << " state=" << (state != nullptr ? 1 : 0);
        }'''

TRIM_NEW = r'''#if defined(__linux__) && defined(__GLIBC__)
        // TSP_PURGE_V22   (replaces TSP_MEMORY_TRIM_UPDATE_051_V7)
        //
        // V7 called malloc_trim(0) every five seconds because there was no
        // swap and handing pages back to the kernel was the only relief
        // available. There is swap now, at swappiness 150, and major faults
        // went 997 -> 2 per 10s. malloc_trim is no longer free:
        //
        //   - it walks every arena's free lists and madvise(MADV_DONTNEED)s
        //     each releasable page, synchronously, on the main thread, on a
        //     ~600 MB heap;
        //   - every page it drops costs a minor fault plus a zero-fill the
        //     next time the allocator hands that address back out.
        //
        // So it buys a hitch now and a fault storm afterwards, to do a job
        // the kernel already does on its own, off this thread. Default OFF.
        //
        //   OPENMW_TSP_MALLOC_TRIM_SECS   unset -> 0 (off); 5 = V7 behaviour
        {
            const double tspTrimSecs = tspMallocTrimSecs();

            if (tspTrimSecs > 0.0)
            {
                using TspTrimClock = std::chrono::steady_clock;
                static std::atomic<std::int64_t> sTspLastTrimNs{ 0 };

                const std::int64_t tspNowNs
                    = std::chrono::duration_cast<std::chrono::nanoseconds>(
                        TspTrimClock::now().time_since_epoch())
                          .count();
                const std::int64_t tspLastNs
                    = sTspLastTrimNs.load(std::memory_order_relaxed);
                const std::int64_t tspIntervalNs
                    = static_cast<std::int64_t>(tspTrimSecs * 1e9);

                if (tspLastNs == 0 || (tspNowNs - tspLastNs) >= tspIntervalNs)
                {
                    sTspLastTrimNs.store(tspNowNs, std::memory_order_relaxed);

                    const TspTrimClock::time_point tspT0 = TspTrimClock::now();
                    const int tspTrimmed = ::malloc_trim(0);
                    const double tspMs = std::chrono::duration<double, std::milli>(
                        TspTrimClock::now() - tspT0)
                                             .count();

                    Log(Debug::Info) << "TSP_PURGE malloc_trim ms=" << tspMs
                                     << " released=" << tspTrimmed
                                     << " every_s=" << tspTrimSecs;
                }
            }
        }
#endif
'''


def patch_ressys():
    log = []

    if not os.path.isfile(RESSYS):
        return None, ["ERROR: %s not found" % RESSYS]

    s = open(RESSYS, encoding="utf-8").read()
    original = s

    if MARKER in s:
        log.append("  already applied  resourcesystem.cpp (all four sites)")
    else:
        # --- helpers --------------------------------------------------------
        if UPDATE_SIG not in s:
            log.append("  ANCHOR MISS      ResourceSystem::updateCache signature")
            return None, log
        at = s.index(UPDATE_SIG)
        s = s[:at] + HELPERS + s[at:]
        log.append("  applied          purge knob helpers")

        # --- updateCache loop ----------------------------------------------
        m = UPDATE_LOOP_RE.search(s)
        if not m:
            log.append("  ANCHOR MISS      updateCache manager loop")
            return None, log
        s = s[:m.start()] + UPDATE_LOOP_NEW + s[m.end():]
        log.append("  applied          updateCache per-manager timing")

        # --- malloc_trim ----------------------------------------------------
        region = find_pp_region(s, "TSP_MEMORY_TRIM_UPDATE_051_V7")
        if region is None:
            log.append("  ANCHOR MISS      TSP_MEMORY_TRIM_UPDATE_051_V7 #if region")
            return None, log
        lo, hi = region
        log.append("  found            V7 trim region, %d lines"
                   % (s[lo:hi].count("\n")))
        s = s[:lo] + TRIM_NEW + s[hi:]
        log.append("  applied          malloc_trim now OFF by default + timed")

        # --- clearCache loop -------------------------------------------------
        m = CLEAR_LOOP_RE.search(s)
        if not m:
            log.append("  ANCHOR MISS      clearCache manager loop")
            return None, log
        s = s[:m.start()] + CLEAR_LOOP_NEW + s[m.end():]
        log.append("  applied          clearCache timing")

        # --- releaseGLObjects loop -------------------------------------------
        m = GLREL_LOOP_RE.search(s)
        if not m:
            log.append("  ANCHOR MISS      releaseGLObjects manager loop")
            return None, log
        s = s[:m.start()] + GLREL_LOOP_NEW + s[m.end():]
        log.append("  applied          releaseGLObjects timing")

    for header in ("chrono", "cstdlib", "cstdint", "atomic"):
        s2, msg = ensure_include(s, header)
        log.append("  " + msg)
        if s2 is None:
            return None, log
        s = s2

    if s == original:
        return ("nochange", RESSYS, None), log
    return ("write", RESSYS, (original, s)), log


# ===========================================================================

def main():
    print()
    print("  tsp_purge_gradual_v22")
    print("  =====================")
    print()

    plans = []
    ok = True

    for name, fn in (("engine.cpp", patch_engine),
                     ("resourcesystem.cpp", patch_ressys)):
        print("  --- %s" % name)
        plan, log = fn()
        for line in log:
            print(line)
        print()
        if plan is None:
            ok = False
        else:
            plans.append(plan)

    if not ok:
        print("  ONE OR MORE ANCHORS MISSED - NOTHING WRITTEN.")
        print("  Send me the printed context above and I will re-anchor it.")
        return 1

    wrote = 0
    for kind, path, payload in plans:
        if kind == "nochange":
            print("  no change needed  %s" % path)
            continue
        original, new = payload
        backup = path + ".tsppurge22-" + STAMP
        open(backup, "w", encoding="utf-8").write(original)
        open(path, "w", encoding="utf-8").write(new)
        print("  backup   %s" % backup)
        print("  written  %s" % path)
        wrote += 1

    print()
    print("  VERIFIED: %d file(s) written" % wrote)
    return 0


if __name__ == "__main__":
    sys.exit(main())