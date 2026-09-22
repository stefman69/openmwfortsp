/*
 * tsp_mpwatch.c - does LuaJIT's flip to executable memory ever fail?
 *
 * ===========================================================================
 * THE HYPOTHESIS THIS TESTS
 * ===========================================================================
 *
 * Crash pid=10060, t=34.5s, measured on device:
 *
 *   fault addr 0x7fa906dc40
 *   pc         0x7fa906dc40        <- pc == fault addr: EXECUTE fault
 *   MAP pc     7fa9053000-7fa9073000 rw-p 00000000 00:00 0
 *   lr         0x3a  <near-NULL>
 *   VmRSS 581876 kB   MemAvailable 186828 kB
 *
 *   stack scan:  lua_pcall, luaL_ref, lua_pcall, lua_pushcclosure
 *                (libluajit-5.1.so.2)
 *
 * The pc is inside a 128 KB ANONYMOUS read-write mapping - no file behind it.
 * dladdr blamed libtsp_warm.so; the maps line proves that was the nearest
 * preceding object and nothing more.
 *
 * LuaJIT assembles a trace into an mcode area mapped PROT_READ|PROT_WRITE,
 * then mprotect()s it to PROT_READ|PROT_EXEC before running it, and back to
 * RW before assembling the next one. If the flip to RX does not take, the
 * trace is executed from a page that is still writable and not executable ->
 * SEGV_ACCERR with pc == fault addr, in an anonymous rw-p mapping. That is
 * this crash exactly.
 *
 * mprotect can fail with ENOMEM under memory pressure - it may need to split
 * a VMA, and splitting allocates. Every one of these crashes happened at
 * VmRSS ~580 MB with MemAvailable ~165-186 MB. That is the pressure regime.
 *
 * If that is what is happening, this shim prints it in one line. If mprotect
 * never fails, the hypothesis is dead and we look at trace flushing or a
 * genuine stomp instead. Either answer is worth having.
 *
 * ===========================================================================
 * WHY ONLY mprotect
 * ===========================================================================
 *
 * mmap is deliberately NOT hooked. It is called by the dynamic loader before
 * any LD_PRELOAD constructor runs, and resolving it can re-enter the
 * allocator. mprotect is where the hypothesis lives, so that is all we touch.
 *
 * The loader calls mprotect too (RELRO), before our constructor. Those calls
 * pass straight through unlogged, and the real function is reached through
 * the raw syscall if dlsym is not usable yet.
 *
 * ===========================================================================
 * ENV
 * ===========================================================================
 *
 *   TSP_MPW_OUT    output path       (default /mnt/SDCARD/tsp_mpwatch.txt)
 *   TSP_MPW_ALL    1 = log every call, not just new regions and failures
 *   TSP_MPW_SECS   table dump interval in seconds (default 30, 0 = off)
 *   TSP_MPW_ADDR   an address (e.g. 0x7fa906dc40) to flag - any region
 *                  containing it is marked <<<< CONTAINS TSP_MPW_ADDR.
 *                  Use the pc from a crash dump to cross-reference directly.
 *
 * Steady-state cost is a mutex, a small linear scan, and no I/O.
 *
 * BUILD
 *   gcc -shared -fPIC -O2 -o libtsp_mpwatch.so tsp_mpwatch.c -ldl -lpthread
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <time.h>
#include <pthread.h>
#include <execinfo.h>
#include <sys/mman.h>
#include <sys/syscall.h>

typedef int (*mprotect_fn)(void*, size_t, int);

static mprotect_fn real_mprotect = NULL;

static FILE* g_out = NULL;
static int g_ready = 0;     /* constructor has run - safe to log */
static int g_all = 0;
static double g_dump_secs = 30.0;
static unsigned long g_flag_addr = 0;

static unsigned long long g_calls = 0;
static unsigned long long g_fails = 0;
static unsigned long long g_exec_calls = 0;

static double g_t0 = 0.0;
static double g_last_dump = 0.0;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

#define REG_MAX 256

struct region
{
    unsigned long lo;
    unsigned long hi;
    unsigned long n_gen;  /* flips to writable   */
    unsigned long n_run;  /* flips to executable */
    unsigned long n_other;
    unsigned long n_fail;
    int last_errno;
};

static struct region g_reg[REG_MAX];
static int g_reg_n = 0;

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void prot_str(int prot, char out[4])
{
    out[0] = (prot & PROT_READ) ? 'R' : '-';
    out[1] = (prot & PROT_WRITE) ? 'W' : '-';
    out[2] = (prot & PROT_EXEC) ? 'X' : '-';
    out[3] = 0;
}

/* Reach the real mprotect even before dlsym is usable. The loader calls
   mprotect during startup relocation; falling back to the raw syscall means
   we can never deadlock or crash on that path. */
static int call_real(void* addr, size_t len, int prot)
{
    if (!real_mprotect)
    {
        void* p = dlsym(RTLD_NEXT, "mprotect");
        if (p)
            *(void**)(&real_mprotect) = p;
    }

    if (real_mprotect)
        return real_mprotect(addr, len, prot);

    return (int)syscall(SYS_mprotect, addr, len, prot);
}

static struct region* reg_find(unsigned long lo, unsigned long hi, int* is_new)
{
    int i;

    *is_new = 0;

    for (i = 0; i < g_reg_n; i++)
        if (g_reg[i].lo == lo && g_reg[i].hi == hi)
            return &g_reg[i];

    if (g_reg_n >= REG_MAX)
        return NULL;

    memset(&g_reg[g_reg_n], 0, sizeof(g_reg[0]));
    g_reg[g_reg_n].lo = lo;
    g_reg[g_reg_n].hi = hi;
    *is_new = 1;
    return &g_reg[g_reg_n++];
}

static void dump_backtrace(const char* why)
{
    void* frames[32];
    int n;
    int i;

    n = backtrace(frames, 32);

    fprintf(g_out, "  backtrace (%s):\n", why);

    for (i = 0; i < n; i++)
    {
        Dl_info info;
        unsigned long a = (unsigned long)frames[i];

        memset(&info, 0, sizeof(info));

        if (dladdr(frames[i], &info) && info.dli_fname)
        {
            unsigned long base = (unsigned long)info.dli_fbase;
            fprintf(g_out, "    #%-2d 0x%012lx  %s+0x%lx",
                i, a, info.dli_fname, a > base ? a - base : 0UL);
            if (info.dli_sname)
                fprintf(g_out, "  (%s)", info.dli_sname);
            fputc('\n', g_out);
        }
        else
        {
            fprintf(g_out, "    #%-2d 0x%012lx  <no dladdr>\n", i, a);
        }
    }
}

static void dump_table(const char* tag)
{
    int i;

    if (!g_out)
        return;

    fprintf(g_out,
        "\nMPW TABLE %s t=%.0f calls=%llu exec_calls=%llu fails=%llu regions=%d\n",
        tag, now_s() - g_t0, g_calls, g_exec_calls, g_fails, g_reg_n);

    for (i = 0; i < g_reg_n; i++)
    {
        const struct region* r = &g_reg[i];
        const int contains = g_flag_addr && g_flag_addr >= r->lo && g_flag_addr < r->hi;

        fprintf(g_out,
            "  0x%012lx-0x%012lx  len=%-9lu gen=%-6lu run=%-6lu other=%-5lu fail=%lu%s%s%s\n",
            r->lo, r->hi, (unsigned long)(r->hi - r->lo),
            r->n_gen, r->n_run, r->n_other, r->n_fail,
            r->n_fail ? "  <<<< HAD FAILURES" : "",
            contains ? "  <<<< CONTAINS TSP_MPW_ADDR" : "",
            (r->n_run && r->n_fail) ? "  <<<< EXEC REGION THAT FAILED" : "");
    }

    fflush(g_out);
}

static void mpw_exit(void)
{
    if (g_out)
    {
        dump_table("atexit");
        fprintf(g_out, "MPW end pid=%d\n", (int)getpid());
        fflush(g_out);
    }
}

__attribute__((constructor))
static void mpw_ctor(void)
{
    const char* p;

    p = getenv("TSP_MPW_OUT");
    g_out = fopen(p && p[0] ? p : "/mnt/SDCARD/tsp_mpwatch.txt", "a");

    if (!g_out)
        g_out = stderr;

    p = getenv("TSP_MPW_ALL");
    g_all = (p && p[0] == '1');

    p = getenv("TSP_MPW_SECS");
    if (p && p[0])
        g_dump_secs = atof(p);

    p = getenv("TSP_MPW_ADDR");
    if (p && p[0])
        g_flag_addr = strtoul(p, NULL, 0);

    g_t0 = now_s();
    g_last_dump = g_t0;

    fprintf(g_out, "\n===============================================================\n");
    fprintf(g_out, "MPW start pid=%d all=%d dump_secs=%.0f flag_addr=0x%lx\n",
        (int)getpid(), g_all, g_dump_secs, g_flag_addr);
    fflush(g_out);

    atexit(mpw_exit);

    g_ready = 1;
}

int mprotect(void* addr, size_t len, int prot)
{
    int ret;
    int saved_errno;
    unsigned long lo, hi;
    struct region* r;
    int is_new = 0;
    char ps[4];

    ret = call_real(addr, len, prot);
    saved_errno = errno;

    /* Loader-time calls land here before the constructor. Pass them through
       silently rather than touching a FILE* that does not exist yet. */
    if (!g_ready || !g_out)
    {
        errno = saved_errno;
        return ret;
    }

    lo = (unsigned long)addr;
    hi = lo + (unsigned long)len;

    prot_str(prot, ps);

    pthread_mutex_lock(&g_lock);

    g_calls++;
    if (prot & PROT_EXEC)
        g_exec_calls++;

    r = reg_find(lo, hi, &is_new);

    if (r)
    {
        if (prot & PROT_EXEC)
            r->n_run++;
        else if (prot & PROT_WRITE)
            r->n_gen++;
        else
            r->n_other++;

        if (ret != 0)
        {
            r->n_fail++;
            r->last_errno = saved_errno;
        }
    }

    if (ret != 0)
    {
        g_fails++;
        fprintf(g_out,
            "\nMPW FAIL  0x%012lx-0x%012lx len=%lu prot=%s errno=%d (%s)  t=%.1f\n",
            lo, hi, (unsigned long)len, ps, saved_errno, strerror(saved_errno),
            now_s() - g_t0);
        dump_backtrace("who asked for this protection change");
        fflush(g_out);
    }
    else if (g_all)
    {
        fprintf(g_out, "mp 0x%012lx-0x%012lx %s\n", lo, hi, ps);
        fflush(g_out);
    }
    else if (is_new)
    {
        fprintf(g_out, "MPW new   0x%012lx-0x%012lx len=%-9lu first_prot=%s t=%.1f%s\n",
            lo, hi, (unsigned long)len, ps, now_s() - g_t0,
            (g_flag_addr && g_flag_addr >= lo && g_flag_addr < hi)
                ? "  <<<< CONTAINS TSP_MPW_ADDR" : "");
        fflush(g_out);
    }

    if (g_dump_secs > 0.0 && (now_s() - g_last_dump) >= g_dump_secs)
    {
        g_last_dump = now_s();
        dump_table("periodic");
    }

    pthread_mutex_unlock(&g_lock);

    errno = saved_errno;
    return ret;
}
