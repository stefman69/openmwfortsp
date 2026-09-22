#ifndef TSP_PROF_H
#define TSP_PROF_H
/*
 * tspprof.h - self-contained frame profiler for the TrimUI OpenMW port
 *
 * TSP_PROF_RING_V2
 *
 * ===========================================================================
 * WHY V2
 * ===========================================================================
 *
 * V1 was compiled into every build and never recorded a single frame:
 *
 *   - TspProf::endFrame() was never called from anywhere, so frameNo() stayed
 *     at 0, every frame accumulated into the same current() struct forever,
 *     and ring()[0] was the only slot ever written;
 *   - TspProf::dumpAtExit() was never called either, so the DumpAtExit static
 *     was never constructed and no destructor ever ran;
 *   - OPENMW_TSP_RING was not exported by the launcher, so dump() would have
 *     returned immediately even if it had been reached.
 *
 * Three independent reasons for silence, each sufficient on its own. V2 fixes
 * all three and adds the thing that makes the ring usable at all on a
 * handheld: a dump you do not have to quit the game to get.
 *
 * ===========================================================================
 * THE DUMP-AT-EXIT PROBLEM
 * ===========================================================================
 *
 * 900 frames at ~25 fps is 36 seconds. Dumping only at exit means the ring
 * has to still contain the event when you quit - so you would have to notice
 * a dip and quit within 36 seconds of it, every time, and a crash gives you
 * nothing at all.
 *
 * V2 keeps the ring and adds a TRIGGER. When a frame exceeds the threshold,
 * a countdown is armed for a quarter of the ring. When it expires the ring is
 * written to a numbered file - so the dump contains the spike, ~675 frames
 * leading up to it, and ~225 frames after it. No I/O happens during the spike
 * itself; it happens ~9 seconds later, once the interesting frames are safely
 * captured.
 *
 * A cooldown of one full ring prevents back-to-back dumps, and a hard cap on
 * dump count means this cannot fill the card.
 *
 * ===========================================================================
 * CONFIG
 * ===========================================================================
 *
 *   OPENMW_TSP_RING             base path. UNSET = profiler writes nothing.
 *                               e.g. /mnt/SDCARD/tsp_ring.txt
 *   OPENMW_TSP_RING_TRIGGER_MS  frame time that arms a dump.
 *                               default 100.0 when OPENMW_TSP_RING is set.
 *                               0 disables triggering (exit dump only).
 *   OPENMW_TSP_RING_MAX_DUMPS   default 8.
 *
 * On the first frame the resolved configuration is printed to stderr:
 *
 *   TSP_RING_CONFIG path=... trigger_ms=... ring_frames=... max_dumps=...
 *
 * The launcher appends stderr to /mnt/SDCARD/tsp_prog.txt, so that line is
 * the liveness proof. If it is not there, the profiler is not running, and
 * you know that without waiting for a dump that was never going to come.
 *
 * ===========================================================================
 * READING THE OUTPUT - TWO TRAPS
 * ===========================================================================
 *
 * 1. TSP_SLOT_MECH IS DOUBLE COUNTED. engine.cpp scopes
 *    MechanicsManager::update into MECH, and actors.cpp scopes
 *    Actors::update into MECH as well - and the second nests inside the
 *    first. So slot[MECH] is roughly twice the real cost and calls[MECH]
 *    reads 2. Left as-is deliberately: changing it now would invalidate
 *    comparison against anything measured earlier. The analyzer flags it.
 *
 * 2. PHYS, AI and ANIM have no TSP_SCOPE anywhere. They will always read
 *    0.00. That is not "physics is free", it is "physics is not measured".
 *    Physics time lands inside WORLD.
 *
 * ===========================================================================
 * USAGE
 * ===========================================================================
 *
 *   TSP_SCOPE(TspProf::TSP_SLOT_MECH);   // times the enclosing scope
 *   TspProf::endFrame();                 // once per frame, end of frame
 *   TspProf::dumpAtExit();               // once, anywhere that runs
 *
 * Cost per measurement point is two clock_gettime calls and a float add.
 */
#include <cstdio>
#include <cstdlib>
#include <ctime>
namespace TspProf
{
    enum Slot
    {
        TSP_SLOT_MECH = 0, // Actors::update - the whole mechanics pass
        TSP_SLOT_CHAR,     // CharacterController::update
        TSP_SLOT_ANIM,     // refreshCurrentAnims          (NOT INSTRUMENTED)
        TSP_SLOT_SPELL,    // ActiveSpells::update
        TSP_SLOT_PHYS,     // physics simulation           (NOT INSTRUMENTED)
        TSP_SLOT_AI,       // AiSequence::execute          (NOT INSTRUMENTED)
        TSP_SLOT_LUA,      // LuaManager::synchronizedUpdate
        TSP_SLOT_WORLD,    // World::update
        TSP_SLOT_GUI,      // WindowManager::update
        TSP_SLOT_EVENT,    // Viewer::eventTraversal
        TSP_SLOT_UPDATET,  // Viewer::updateTraversal
        TSP_SLOT_RENDER,   // Viewer::renderingTraversals - cull + draw
        TSP_SLOT_SOUND,    // SoundManager::update
        TSP_SLOT_COUNT
    };
    static const int TSP_RING_FRAMES = 900;
    struct Frame
    {
        double total;
        double slot[TSP_SLOT_COUNT];
        int calls[TSP_SLOT_COUNT];
    };
    inline double nowMs()
    {
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
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
        fprintf(f, "# tspprof v2 - last %lu of %lu frames   reason=%s\n",
            n - first, n, why ? why : "?");
        fprintf(f, "# NOTE mech is double counted (engine.cpp + actors.cpp nest)\n");
        fprintf(f, "# NOTE anim, phys, ai are not instrumented and always read 0\n");
        fprintf(f, "# frame total mech char anim spell phys ai lua world gui event updt render sound\n");
        for (unsigned long i = first; i < n; i++)
        {
            const Frame& s = ring()[i % TSP_RING_FRAMES];
            fprintf(f, "%lu %.2f", i, s.total);
            for (int k = 0; k < TSP_SLOT_COUNT; k++)
                fprintf(f, " %.2f", s.slot[k]);
            fprintf(f, " |");
            for (int k = 0; k < TSP_SLOT_COUNT; k++)
                fprintf(f, " %d", s.calls[k]);
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

            /* Unconditional, on stderr, once. The launcher appends stderr to
               tsp_prog.txt. A profiler whose failure mode is silence is
               useless - this one always announces itself. */
            fprintf(stderr,
                "TSP_RING_CONFIG path=%s trigger_ms=%.1f ring_frames=%d max_dumps=%d\n",
                (cfg.base && cfg.base[0]) ? cfg.base : "(OPENMW_TSP_RING unset - no output)",
                cfg.ms, TSP_RING_FRAMES, cfg.maxDumps);
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

    /* call once per frame from the main loop */
    inline void endFrame()
    {
        double now = nowMs();
        Frame& c = current();
        c.total = now - lastFrameStart();
        lastFrameStart() = now;
        const double total = c.total;
        unsigned long n = frameNo()++;
        ring()[n % TSP_RING_FRAMES] = c;
        c.total = 0.0;
        for (int i = 0; i < TSP_SLOT_COUNT; i++)
        {
            c.slot[i] = 0.0;
            c.calls[i] = 0;
        }
        checkTrigger(total);
    }

    /* object whose destructor dumps - declare one at shutdown scope */
    struct DumpAtExit
    {
        ~DumpAtExit() { dump(); }
    };
    inline void dumpAtExit()
    {
        static DumpAtExit d;
        (void)d;
    }
    /* RAII scope timer */
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
   it is a redefinition error. This expands properly. */
#define TSP_CONCAT_(a, b) a##b
#define TSP_CONCAT(a, b) TSP_CONCAT_(a, b)
#define TSP_SCOPE(slot) TspProf::Scope TSP_CONCAT(tspScope, __LINE__)(slot)
#endif
