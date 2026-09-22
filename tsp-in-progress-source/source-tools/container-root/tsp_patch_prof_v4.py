import sys, re
P = sys.argv[1] if len(sys.argv) > 1 else "tspprof.h"
src = open(P).read()
if "TSP_PROF_RUSAGE_V4" in src:
    print("ALREADY PATCHED - nothing to do")
    sys.exit(3)
E = []
def sub(old, new, tag):
    global src
    n = src.count(old)
    if n != 1:
        E.append("anchor %s matched %d times, need exactly 1" % (tag, n))
        return
    src = src.replace(old, new, 1)

# 1. header include
sub("#include <ctime>\n",
    "#include <ctime>\n#include <sys/resource.h>\n", "include")

# 2. Frame struct gains the rusage fields
sub("""    struct Frame
    {
        double total;
        double slot[TSP_SLOT_COUNT];
        int calls[TSP_SLOT_COUNT];
    };
""",
    """    struct Frame
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
""", "frame_struct")

# 3. clock helpers, inserted after nowMs()
sub("""    inline Frame* ring()
""",
    """    /* TSP_PROF_RUSAGE_V4.  clock_gettime is used rather than getrusage for
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
""", "helpers")

# 4. per-frame previous-value accessors, after lastFrameStart()
sub("""    inline void add(int slot, double ms)
""",
    """    inline double& lastThreadCpu()
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
""", "accessors")

# 5. dump header says v4 and names the extra columns
sub("""        fprintf(f, "# tspprof v3 - last %lu of %lu frames   reason=%s\\n",
            n - first, n, why ? why : "?");
        fprintf(f, "# nested: %s\\n", nestedNames());
        fprintf(f, "# frame total %s\\n", slotNames());
""",
    """        fprintf(f, "# tspprof v4 - last %lu of %lu frames   reason=%s\\n",
            n - first, n, why ? why : "?");
        fprintf(f, "# nested: %s\\n", nestedNames());
        fprintf(f, "# frame total %s\\n", slotNames());
        fprintf(f, "# extra: cpu pcpu minflt majflt tod_ms\\n");
        fprintf(f, "# row: frame total <slots> | <calls> | <extra>\\n");
""", "dump_header")

# 6. the row gains a second bar and the extras, AFTER the calls array
sub("""            for (int k = 0; k < TSP_SLOT_COUNT; k++)
                fprintf(f, " %d", s.calls[k]);
            fputc('\\n', f);
""",
    """            for (int k = 0; k < TSP_SLOT_COUNT; k++)
                fprintf(f, " %d", s.calls[k]);
            fprintf(f, " | %.2f %.2f %ld %ld %.1f",
                s.cpuMs, s.pcpuMs, s.minflt, s.majflt, s.tod);
            fputc('\\n', f);
""", "dump_row")

# 7. banner says v4 and carries a greppable binary marker
sub('''                "TSP_RING_CONFIG v3 path=%s trigger_ms=%.1f ring_frames=%d max_dumps=%d slots=%d\\n",''',
    '''                "TSP_RING_CONFIG v4 TSP_PROF_RUSAGE_V4 path=%s trigger_ms=%.1f ring_frames=%d max_dumps=%d slots=%d\\n",''',
    "banner")

# 8. endFrame samples the clocks and faults, and zeroes the new fields
sub("""        double now = nowMs();
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
""",
    """        double now = nowMs();
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
""", "endframe")

if E:
    print("PATCH REFUSED, nothing written:")
    for e in E:
        print("  " + e)
    sys.exit(1)
if src.count("{") != src.count("}"):
    print("PATCH REFUSED: brace imbalance %d vs %d" % (src.count("{"), src.count("}")))
    sys.exit(1)
open(P, "w").write(src)
print("PATCHED OK  lines=%d  marker=%d" % (src.count("\n"), src.count("TSP_PROF_RUSAGE_V4")))
