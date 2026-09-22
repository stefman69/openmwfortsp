#ifndef TSP_PROF_H
#define TSP_PROF_H
/*
 * tspprof.h - self-contained frame profiler for the TrimUI OpenMW port
 *
 * TSP_PROF_RING_V3
 *
 * ===========================================================================
 * WHY V3
 * ===========================================================================
 *
 * V2 recorded frames for the first time and immediately showed that the
 * biggest single events were not in any instrumented scope. Reading the main
 * loop (engine.cpp Engine::frame, 402-616) explained why - most of the frame
 * was never measured:
 *
 *   443  mInputManager->update            unmeasured  <- MyGUI dispatch,
 *                                                        i.e. the save dialog
 *   476  mStateManager->update            unmeasured  <- AUTOSAVE lives here
 *   493  executeLocalScripts              unmeasured  <- MWScript, not Lua
 *   496  getGlobalScripts().run           unmeasured  <- MWScript, not Lua
 *   536  mWorld->updatePhysics            unmeasured  <- TSP_SLOT_PHYS existed
 *                                                        and was never wired
 *   566  mUnrefQueue->flush               unmeasured
 *   592  mWorld->updateFocusObject        unmeasured
 *   613  mLuaWorker->finishUpdate         unmeasured, and V2 put the frame
 *                                         boundary ABOVE it, so the wait for
 *                                         the Lua worker thread rolled into
 *                                         the following frame
 *
 * Two ~330 ms frames with ~295 ms unowned were confirmed by Steve as an
 * autosave and a manual save. Both land in 443 or 476.
 *
 * V3 wires every one of those, and moves the frame boundary below
 * finishUpdate so a frame is a whole frame.
 *
 * ===========================================================================
 * THE MECH DOUBLE COUNT IS FIXED
 * ===========================================================================
 *
 * V1 and V2 scoped BOTH engine.cpp's MechanicsManager::update AND
 * actors.cpp's Actors::update into TSP_SLOT_MECH, and the second nests inside
 * the first, so the slot read roughly double and calls[mech] read 2.
 *
 * V3 splits them: MECH is the top-level MechanicsManager::update, ACTORS is
 * the nested Actors::update. Numbers from V1/V2 runs are NOT comparable with
 * V3 for that slot.
 *
 * ===========================================================================
 * THE ACCOUNTING MODEL
 * ===========================================================================
 *
 * TOP-LEVEL slots are siblings in Engine::frame. They should sum to very
 * nearly the frame total:
 *
 *   input sound lua state script mech phys world gui unref event updt focus
 *   render luawait
 *
 * NESTED slots are inside a top-level one and must NOT be added to that sum:
 *
 *   actors  inside mech
 *   char    inside actors
 *   spell   inside actors
 *
 * Remaining unaccounted time is real and lives between these calls - the
 * frame-rate limiter at engine.cpp:1380, mViewer->advance at 1349, or the
 * loop condition itself.
 *
 * ===========================================================================
 * CONFIG
 * ===========================================================================
 *
 *   OPENMW_TSP_RING             base path. UNSET = profiler writes nothing.
 *   OPENMW_TSP_RING_TRIGGER_MS  frame time that arms a dump. default 100.0
 *                               when OPENMW_TSP_RING is set. 0 = exit only.
 *   OPENMW_TSP_RING_MAX_DUMPS   default 8.
 *
 * TSP_RING_CONFIG is printed to stderr on the first frame, unconditionally.
 * The launcher appends stderr to tsp_prog.txt. That line is the liveness
 * proof; silence there means the profiler is not running.
 *
 * The dump's own header line names the slots in order, so the analyzer reads
 * the column names from the file rather than hardcoding them. Adding a slot
 * here does not require touching the analyzer.
 */
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <sys/resource.h>
namespace TspProf
{
    /* Order here defines the column order in the dump. Keep SLOT_NAMES below
       in exactly this order - the dump header is written from it. */
    enum Slot
    {
        TSP_SLOT_INPUT = 0, // mInputManager->update          engine.cpp:443
        TSP_SLOT_SOUND,     // mSoundManager->update          engine.cpp:463
        TSP_SLOT_LUA,       // mLuaManager->synchronizedUpdate engine.cpp:470
        TSP_SLOT_STATE,     // mStateManager->update          engine.cpp:476
        TSP_SLOT_SCRIPT,    // MWScript local + global        engine.cpp:493,496
        TSP_SLOT_MECH,      // mMechanicsManager->update      engine.cpp:519
        TSP_SLOT_PHYS,      // mWorld->updatePhysics          engine.cpp:536
        TSP_SLOT_WORLD,     // mWorld->update                 engine.cpp:546
        TSP_SLOT_GUI,       // mWindowManager->update         engine.cpp:553
        TSP_SLOT_UNREF,     // mUnrefQueue->flush             engine.cpp:566
        TSP_SLOT_EVENT,     // mViewer->eventTraversal        engine.cpp:586
        TSP_SLOT_UPDATET,   // mViewer->updateTraversal       engine.cpp:587
        TSP_SLOT_FOCUS,     // mWorld->updateFocusObject      engine.cpp:592
        TSP_SLOT_RENDER,    // mViewer->renderingTraversals   engine.cpp:598
        TSP_SLOT_LUAWAIT,   // mLuaWorker->finishUpdate       engine.cpp:613
        /* nested - inside a top-level slot above, never added to the sum */
        TSP_SLOT_ACTORS,    // Actors::update                 actors.cpp
        TSP_SLOT_CHAR,      // CharacterController::update    character.cpp
        TSP_SLOT_SPELL,     // ActiveSpells::update           activespells.cpp
        TSP_SLOT_COUNT
    };

    inline const char* slotNames()
    {
        return "input sound lua state script mech phys world gui unref"
               " event updt focus render luawait actors char spell";
    }

    /* Which of the above are nested. The analyzer reads this line from the
       dump so it never has to be told twice. */
    inline const char* nestedNames()
    {
        return "actors char spell";
    }

    static const int TSP_RING_FRAMES = 900;
    struct Frame
    {
        double total;
        double slot[TSP_SLOT_COUNT];
        int calls[TSP_SLOT_COUNT];
        /* TSP_PROF_RUSAGE_V4 - written at the END of the row so that adding
           them cannot shift the slot or calls columns. The v4 that was lost
           in the 2026-08-22 tree loss put them BEFORE the calls array, which
           silently broke every field position in the analyzer. */
        double cpuMs;
        double pcpuMs;
        double tod;
        long minflt;
        long majflt;
    };
    inline double nowMs()
    {
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
    }
    /* TSP_PROF_RUSAGE_V4.  clock_gettime is used rather than getrusage for
       the CPU figures: getrusage reports in clock ticks (10 ms here), which
       cannot resolve a 40-80 ms hitch at all.  These two clocks are ns. */
    inline double cpuClockMs(clockid_t which)
    {
        struct timespec ts;
        if (clock_gettime(which, &ts) != 0)
            return 0.0;
        return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
    }
    inline double todMs()
    {
        struct timespec ts;
        if (clock_gettime(CLOCK_REALTIME, &ts) != 0)
            return 0.0;
        return (double)(ts.tv_sec % 86400) * 1000.0 + (double)ts.tv_nsec / 1000000.0;
    }
    inline void readFaults(long* mn, long* mj)
    {
        struct rusage ru;
        if (getrusage(RUSAGE_SELF, &ru) == 0)
        {
            *mn = (long)ru.ru_minflt;
            *mj = (long)ru.ru_majflt;
        }
        else
        {
            *mn = 0;
            *mj = 0;
        }
    }
    inline Frame* ring()
    {
        static Frame buf[TSP_RING_FRAMES];
        return buf;
    }
    inline Frame& current()
    {
        static Frame cur;
        return cur;
    }
    inline unsigned long& frameNo()
    {
        static unsigned long n = 0;
        return n;
    }
    inline double& lastFrameStart()
    {
        static double t = nowMs();
        return t;
    }
    inline double& lastThreadCpu()
    {
        static double t = cpuClockMs(CLOCK_THREAD_CPUTIME_ID);
        return t;
    }
    inline double& lastProcCpu()
    {
        static double t = cpuClockMs(CLOCK_PROCESS_CPUTIME_ID);
        return t;
    }
    inline long& lastMinflt()
    {
        static long v = 0;
        return v;
    }
    inline long& lastMajflt()
    {
        static long v = 0;
        return v;
    }
    inline void add(int slot, double ms)
    {
        if (slot < 0 || slot >= TSP_SLOT_COUNT)
            return;
        current().slot[slot] += ms;
        current().calls[slot] += 1;
    }

    /* ------------------------------------------------------------------ */
    /* dumping                                                             */
    /* ------------------------------------------------------------------ */

    inline void dumpTo(const char* path, const char* why)
    {
        if (!path || !path[0])
            return;
        FILE* f = fopen(path, "w");
        if (!f)
            return;
        unsigned long n = frameNo();
        unsigned long first = (n > (unsigned long)TSP_RING_FRAMES)
            ? n - TSP_RING_FRAMES : 0;
        fprintf(f, "# tspprof v4 - last %lu of %lu frames   reason=%s\n",
            n - first, n, why ? why : "?");
        fprintf(f, "# nested: %s\n", nestedNames());
        fprintf(f, "# frame total %s\n", slotNames());
        fprintf(f, "# extra: cpu pcpu minflt majflt tod_ms\n");
        fprintf(f, "# row: frame total <slots> | <calls> | <extra>\n");
        for (unsigned long i = first; i < n; i++)
        {
            const Frame& s = ring()[i % TSP_RING_FRAMES];
            fprintf(f, "%lu %.2f", i, s.total);
            for (int k = 0; k < TSP_SLOT_COUNT; k++)
                fprintf(f, " %.2f", s.slot[k]);
            fprintf(f, " |");
            for (int k = 0; k < TSP_SLOT_COUNT; k++)
                fprintf(f, " %d", s.calls[k]);
            fprintf(f, " | %.2f %.2f %ld %ld %.1f",
                s.cpuMs, s.pcpuMs, s.minflt, s.majflt, s.tod);
            fputc('\n', f);
        }
        fclose(f);
    }

    inline void dump()
    {
        dumpTo(getenv("OPENMW_TSP_RING"), "exit");
    }

    /* ------------------------------------------------------------------ */
    /* trigger                                                             */
    /* ------------------------------------------------------------------ */

    struct TriggerCfg
    {
        const char* base;
        double ms;
        int maxDumps;
        int resolved;
    };

    inline TriggerCfg& trigger()
    {
        static TriggerCfg cfg = { 0, 0.0, 8, 0 };
        if (!cfg.resolved)
        {
            cfg.resolved = 1;
            cfg.base = getenv("OPENMW_TSP_RING");

            const char* t = getenv("OPENMW_TSP_RING_TRIGGER_MS");
            if (cfg.base && cfg.base[0])
                cfg.ms = (t && t[0]) ? atof(t) : 100.0;
            else
                cfg.ms = 0.0;

            const char* m = getenv("OPENMW_TSP_RING_MAX_DUMPS");
            if (m && m[0])
                cfg.maxDumps = atoi(m);

            fprintf(stderr,
                "TSP_RING_CONFIG v4 TSP_PROF_RUSAGE_V4 path=%s trigger_ms=%.1f ring_frames=%d max_dumps=%d slots=%d\n",
                (cfg.base && cfg.base[0]) ? cfg.base : "(OPENMW_TSP_RING unset - no output)",
                cfg.ms, TSP_RING_FRAMES, cfg.maxDumps, (int)TSP_SLOT_COUNT);
            fflush(stderr);
        }
        return cfg;
    }

    inline void checkTrigger(double totalMs)
    {
        TriggerCfg& cfg = trigger();
        if (cfg.ms <= 0.0)
            return;

        static int armed = 0;
        static int cooldown = 0;
        static int dumps = 0;
        static double armedBy = 0.0;
        static unsigned long armedAt = 0;

        if (armed > 0)
        {
            if (--armed == 0)
            {
                if (dumps < cfg.maxDumps)
                {
                    char path[512];
                    ++dumps;
                    snprintf(path, sizeof(path), "%s.%d", cfg.base, dumps);
                    dumpTo(path, "slow-frame");
                    fprintf(stderr,
                        "TSP_RING_DUMP file=%s n=%d spike_frame=%lu spike_ms=%.1f\n",
                        path, dumps, armedAt, armedBy);
                }
                else
                {
                    fprintf(stderr, "TSP_RING_DUMP skipped=max_dumps_reached n=%d\n", dumps);
                }
                fflush(stderr);
                cooldown = TSP_RING_FRAMES;
            }
            return;
        }

        if (cooldown > 0)
        {
            --cooldown;
            return;
        }

        if (totalMs >= cfg.ms)
        {
            armed = TSP_RING_FRAMES / 4;
            armedBy = totalMs;
            armedAt = frameNo();
            fprintf(stderr, "TSP_RING_ARM frame=%lu total_ms=%.1f capture_after=%d\n",
                armedAt, totalMs, armed);
            fflush(stderr);
        }
    }

    /* Call once per frame, at the TRUE end of the frame body. In V2 this sat
       above mLuaWorker->finishUpdate(), so the wait for the Lua worker thread
       fell outside the frame and rolled into the next one. */
    inline void endFrame()
    {
        double now = nowMs();
        /* TSP_PROF_RUSAGE_V4 */
        double tcpu = cpuClockMs(CLOCK_THREAD_CPUTIME_ID);
        double pcpu = cpuClockMs(CLOCK_PROCESS_CPUTIME_ID);
        long mn = 0;
        long mj = 0;
        readFaults(&mn, &mj);
        const bool firstFrame = (frameNo() == 0);
        Frame& c = current();
        c.total = now - lastFrameStart();
        c.cpuMs = tcpu - lastThreadCpu();
        c.pcpuMs = pcpu - lastProcCpu();
        c.minflt = mn - lastMinflt();
        c.majflt = mj - lastMajflt();
        c.tod = todMs();
        /* frame 0 has no predecessor - the lazy statics initialise inside this
           very call, so every delta would be noise. Report it as empty. */
        if (firstFrame)
        {
            c.total = 0.0;
            c.cpuMs = 0.0;
            c.pcpuMs = 0.0;
            c.minflt = 0;
            c.majflt = 0;
        }
        lastFrameStart() = now;
        lastThreadCpu() = tcpu;
        lastProcCpu() = pcpu;
        lastMinflt() = mn;
        lastMajflt() = mj;
        const double total = c.total;
        unsigned long n = frameNo()++;
        ring()[n % TSP_RING_FRAMES] = c;
        c.total = 0.0;
        c.cpuMs = 0.0;
        c.pcpuMs = 0.0;
        c.tod = 0.0;
        c.minflt = 0;
        c.majflt = 0;
        for (int i = 0; i < TSP_SLOT_COUNT; i++)
        {
            c.slot[i] = 0.0;
            c.calls[i] = 0;
        }
        checkTrigger(total);
    }

    struct DumpAtExit
    {
        ~DumpAtExit() { dump(); }
    };
    inline void dumpAtExit()
    {
        static DumpAtExit d;
        (void)d;
    }
    struct Scope
    {
        int slot;
        double t0;
        explicit Scope(int s) : slot(s), t0(nowMs()) {}
        ~Scope() { add(slot, nowMs() - t0); }
    };
}
/* Two levels of indirection, because a##b suppresses expansion of b. V1 had
   TspProf::Scope tspScope##__LINE__(slot), which names the variable literally
   tspScope__LINE__ on every line - fine until two scopes share a block, then
   it is a redefinition error. */
#define TSP_CONCAT_(a, b) a##b
#define TSP_CONCAT(a, b) TSP_CONCAT_(a, b)
#define TSP_SCOPE(slot) TspProf::Scope TSP_CONCAT(tspScope, __LINE__)(slot)
#endif
