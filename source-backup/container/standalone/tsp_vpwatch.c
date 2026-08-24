/*
 * tsp_vpwatch.c - name the exact call site that sets glViewport(0,0,800,600)
 *
 * ===========================================================================
 * WHY
 * ===========================================================================
 *
 * The camera audit settled the question of WHERE the 800x600 does NOT come
 * from. Measured on device:
 *
 *   tag=pre  fire=N  camera_viewport=1280x720  gl_viewport=1280x720
 *   tag=post fire=N  camera_viewport=1280x720  gl_viewport=800x600
 *
 * and the audit found no camera holding an 800x600 viewport:
 *
 *   SceneCam   viewport=1280x720  render_order=2(POST_RENDER)  rtt=3(FRAME_BUFFER)
 *   ""         viewport=1280x720  render_order=2(POST_RENDER)  rtt=3(FRAME_BUFFER)
 *   ""         viewport=-1x-1     render_order=0(PRE_RENDER)   rtt=3(FRAME_BUFFER)  mask=0x40000
 *
 * So the 800x600 is not a camera attribute that OSG is faithfully applying.
 * It is a raw glViewport call issued during SceneCam's draw, between the
 * pre-draw and post-draw callbacks. 800x600 is exactly osg::Viewport's
 * default-constructed value, so somebody is applying a default-constructed
 * Viewport - most likely on behalf of that third camera, which has no
 * viewport of its own.
 *
 * Guessing which OSG internal does that from headers alone is how the last
 * two patches got written wrong. This does not guess. It interposes
 * glViewport, and the first time the arguments are exactly the bad geometry
 * it writes a backtrace. The call site is then a fact, not a theory.
 *
 * ===========================================================================
 * WHY THIS DOES NOT COLLIDE WITH THE SCALER
 * ===========================================================================
 *
 * libtsp_fullscreen_scaler.so resolves its GL entry points with
 * dlopen("libGLESv2.so*", RTLD_NOW|RTLD_LOCAL) + dlsym on that handle. Its
 * p_glViewport therefore bypasses the PLT entirely and never reaches this
 * wrapper. Everything logged here is OSG's own traffic.
 *
 * ===========================================================================
 * ENV
 * ===========================================================================
 *
 *   TSP_VPWATCH_OUT    output path      (default /mnt/SDCARD/tsp_vpwatch.txt)
 *   TSP_VPWATCH_BAD    geometry to trap (default "800x600"; "off" disables)
 *   TSP_VPWATCH_MAX    max backtraces   (default 6)
 *   TSP_VPWATCH_ALL    1 = backtrace the first TSP_VPWATCH_MAX *distinct*
 *                      viewport values, not just the bad one
 *   TSP_VPWATCH_SCISSOR 1 = also wrap glScissor
 *
 * Every distinct viewport value is logged as a one-line transition regardless,
 * so the file stays small at 60fps.
 *
 * BUILD
 *   gcc-13 -shared -fPIC -O2 -o libtsp_vpwatch.so tsp_vpwatch.c -ldl -rdynamic
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <execinfo.h>
#include <pthread.h>
#include <sys/syscall.h>

/* glibc grew gettid() in 2.30. The device is on 2.33 but the build container
   is not necessarily, and a missing declaration here would silently become an
   implicit int-returning call. Use the syscall directly and skip the question. */
static long vpw_tid(void)
{
    return syscall(SYS_gettid);
}

typedef int GLint;
typedef int GLsizei;

typedef void (*vp_fn)(GLint, GLint, GLsizei, GLsizei);

static vp_fn real_glViewport = NULL;
static vp_fn real_glScissor = NULL;

static FILE* g_out = NULL;
static int g_ready = 0;
static int g_inside = 0; /* re-entrancy guard for the backtrace path */

static int g_bad_w = 800;
static int g_bad_h = 600;
static int g_bad_on = 1;

static int g_max = 6;
static int g_dumped = 0;
static int g_all = 0;
static int g_scissor = 0;

static GLint g_last[4] = { -1, -1, -1, -1 };
static GLint g_last_sc[4] = { -1, -1, -1, -1 };
static unsigned long g_calls = 0;

/* The bad viewport is set every frame, so without this the log would be six
   copies of one stack. Key on the return address of our caller and dump only
   the first time each distinct call site appears. */
#define RA_MAX 32
static void* g_ra[RA_MAX];
static int g_ra_n = 0;

static int ra_seen(void* ra)
{
    int i;
    for (i = 0; i < g_ra_n; i++)
        if (g_ra[i] == ra)
            return 1;
    if (g_ra_n < RA_MAX)
        g_ra[g_ra_n++] = ra;
    return 0;
}

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

/* remember which distinct geometries we already backtraced, for _ALL mode */
#define SEEN_MAX 32
static GLint g_seen[SEEN_MAX][4];
static int g_seen_n = 0;

static int seen_before(GLint x, GLint y, GLint w, GLint h)
{
    int i;
    for (i = 0; i < g_seen_n; i++)
    {
        if (g_seen[i][0] == x && g_seen[i][1] == y && g_seen[i][2] == w && g_seen[i][3] == h)
            return 1;
    }
    if (g_seen_n < SEEN_MAX)
    {
        g_seen[g_seen_n][0] = x;
        g_seen[g_seen_n][1] = y;
        g_seen[g_seen_n][2] = w;
        g_seen[g_seen_n][3] = h;
        g_seen_n++;
    }
    return 0;
}

/* Print the /proc/self/maps line that contains addr. dladdr alone has been
   misleading on this device - it happily attributes an address to the nearest
   preceding shared object even when the address is far past that object's
   image. The maps line is authoritative. */
static void maps_lookup(FILE* f, unsigned long addr)
{
    FILE* m = fopen("/proc/self/maps", "r");
    char line[512];

    if (!m)
        return;

    while (fgets(line, sizeof(line), m))
    {
        unsigned long lo = 0, hi = 0;
        if (sscanf(line, "%lx-%lx", &lo, &hi) != 2)
            continue;
        if (addr >= lo && addr < hi)
        {
            size_t n = strlen(line);
            if (n && line[n - 1] == '\n')
                line[n - 1] = 0;
            fprintf(f, "        map  %s\n", line);
            break;
        }
    }

    fclose(m);
}

static void dump_backtrace(const char* why, GLint x, GLint y, GLint w, GLint h)
{
    void* frames[64];
    int n;
    int i;

    if (!g_out)
        return;

    n = backtrace(frames, 64);

    fprintf(g_out, "\n=== VPWATCH %s  glViewport(%d,%d,%d,%d)  call=%lu  pid=%d tid=%ld\n",
        why, x, y, w, h, g_calls, (int)getpid(), vpw_tid());

    for (i = 0; i < n; i++)
    {
        Dl_info info;
        unsigned long a = (unsigned long)frames[i];

        memset(&info, 0, sizeof(info));

        if (dladdr(frames[i], &info) && info.dli_fname)
        {
            unsigned long base = (unsigned long)info.dli_fbase;
            fprintf(g_out, "  #%-2d 0x%016lx  %s+0x%lx",
                i, a, info.dli_fname, a > base ? a - base : 0UL);

            if (info.dli_sname)
            {
                unsigned long sa = (unsigned long)info.dli_saddr;
                fprintf(g_out, "  (%s+0x%lx)", info.dli_sname, a > sa ? a - sa : 0UL);
            }
            fputc('\n', g_out);
        }
        else
        {
            fprintf(g_out, "  #%-2d 0x%016lx  <no dladdr>\n", i, a);
        }

        maps_lookup(g_out, a);
    }

    fprintf(g_out, "=== END VPWATCH %s\n\n", why);
    fflush(g_out);
}

static void vpw_init(void)
{
    const char* p;

    if (g_ready)
        return;
    g_ready = 1;

    p = getenv("TSP_VPWATCH_OUT");
    g_out = fopen(p && p[0] ? p : "/mnt/SDCARD/tsp_vpwatch.txt", "a");

    if (!g_out)
        g_out = stderr;

    p = getenv("TSP_VPWATCH_BAD");
    if (p && p[0])
    {
        if (!strcmp(p, "off") || !strcmp(p, "0"))
        {
            g_bad_on = 0;
        }
        else
        {
            int a = 0, b = 0;
            if (sscanf(p, "%dx%d", &a, &b) == 2 && a > 0 && b > 0)
            {
                g_bad_w = a;
                g_bad_h = b;
            }
        }
    }

    p = getenv("TSP_VPWATCH_MAX");
    if (p && p[0])
        g_max = atoi(p);

    p = getenv("TSP_VPWATCH_ALL");
    g_all = (p && p[0] == '1');

    p = getenv("TSP_VPWATCH_SCISSOR");
    g_scissor = (p && p[0] == '1');

    fprintf(g_out, "VPWATCH start pid=%d bad=%dx%d%s max=%d all=%d scissor=%d\n",
        (int)getpid(), g_bad_w, g_bad_h, g_bad_on ? "" : " (disabled)",
        g_max, g_all, g_scissor);
    fflush(g_out);
}

void glViewport(GLint x, GLint y, GLsizei width, GLsizei height)
{
    int do_dump = 0;
    const char* why = "";

    if (!real_glViewport)
        *(void**)(&real_glViewport) = dlsym(RTLD_NEXT, "glViewport");

    pthread_mutex_lock(&g_lock);

    vpw_init();
    g_calls++;

    if (x != g_last[0] || y != g_last[1] || width != g_last[2] || height != g_last[3])
    {
        fprintf(g_out, "vp %lu  %d,%d,%dx%d\n", g_calls, x, y, width, height);
        fflush(g_out);

        g_last[0] = x;
        g_last[1] = y;
        g_last[2] = width;
        g_last[3] = height;

        if (g_all && !seen_before(x, y, width, height) && g_dumped < g_max)
        {
            do_dump = 1;
            why = "DISTINCT";
        }
    }

    if (!do_dump && g_bad_on && width == g_bad_w && height == g_bad_h && g_dumped < g_max)
    {
        do_dump = 1;
        why = "BAD";
    }

    if (do_dump && !g_inside)
    {
        g_inside = 1;
        if (ra_seen(__builtin_return_address(0)))
            do_dump = 0; /* same call site as an earlier dump - not news */
        if (do_dump)
        {
            g_dumped++;
            dump_backtrace(why, x, y, width, height);
        }
        g_inside = 0;
    }

    pthread_mutex_unlock(&g_lock);

    if (real_glViewport)
        real_glViewport(x, y, width, height);
}

void glScissor(GLint x, GLint y, GLsizei width, GLsizei height)
{
    if (!real_glScissor)
        *(void**)(&real_glScissor) = dlsym(RTLD_NEXT, "glScissor");

    if (g_scissor)
    {
        pthread_mutex_lock(&g_lock);
        vpw_init();

        if (x != g_last_sc[0] || y != g_last_sc[1]
            || width != g_last_sc[2] || height != g_last_sc[3])
        {
            fprintf(g_out, "sc %lu  %d,%d,%dx%d\n", g_calls, x, y, width, height);
            fflush(g_out);

            g_last_sc[0] = x;
            g_last_sc[1] = y;
            g_last_sc[2] = width;
            g_last_sc[3] = height;
        }

        pthread_mutex_unlock(&g_lock);
    }

    if (real_glScissor)
        real_glScissor(x, y, width, height);
}
