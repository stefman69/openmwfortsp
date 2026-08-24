/*
 * tsp_files.c  -  file access tracer for OpenMW on the TrimUI
 *
 * ===========================================================================
 * WHY
 * ===========================================================================
 *
 * We have staged assets in tmpfs several times and had no way to confirm the
 * game actually used them. OpenMW does not log asset loads even at debug
 * level in a release build, and the GL wrapper only sees numeric texture IDs,
 * never filenames. Every "cache it in RAM" test so far has been unverifiable.
 *
 * This hooks the file syscalls directly, so it reports exactly which paths the
 * process opens and where its reads land. That answers two questions we have
 * not been able to answer:
 *
 *   1. Is the tmpfs staging actually being used, or is the game still reading
 *      the BSA?  -> look for /tmp/... paths in the OPEN lines
 *
 *   2. What is being read at the moment of a stall?  -> the READ lines carry
 *      timestamps and byte offsets
 *
 * BSA reads show as offsets into Morrowind.bsa. Those can be mapped back to
 * asset names with `bsatool list` if needed, but for the immediate question -
 * "is it hitting RAM or the card" - the path alone is enough.
 *
 * ===========================================================================
 * OUTPUT
 * ===========================================================================
 *
 *   OPEN  fd=12 /tmp/tspvfx/textures/vfx_alt_glow.dds
 *   OPEN  fd=13 /mnt/SDCARD/.../Morrowind.bsa
 *   READ  t=48213 fd=13 off=104857600 len=8419        <- BSA seek+read
 *   SLOW  t=48261 gap=142ms since previous read       <- stall marker
 *
 * A "SLOW" line is emitted whenever more than LIBGL_TSP_FILES_GAP ms passes
 * between file operations, so a stall is easy to locate in the log and you can
 * see what was being read immediately before and after it.
 *
 * ===========================================================================
 * USAGE
 * ===========================================================================
 *
 *   gcc -shared -fPIC -O2 -o libtsp_files.so tsp_files.c -ldl
 *
 *   export LIBGL_TSP_FILES=/mnt/SDCARD/tsp_files.txt
 *   export LIBGL_TSP_FILES_GAP=50     optional, default 50 ms
 *   export LIBGL_TSP_FILES_MAX=20000  optional line cap
 *
 * Place FIRST in LD_PRELOAD. Unset LIBGL_TSP_FILES and it does nothing.
 *
 * Only paths under the game directory and /tmp are logged, so system and
 * library opens do not drown the output.
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/types.h>

#define MAXFD 4096

static FILE*        g_log = NULL;
static int          g_chk = 0;
static long         g_max = 20000;
static long         g_n = 0;
static double       g_gap = 50.0;
static double       g_last_op = 0.0;
static char*        g_fdname[MAXFD];

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

static void tsp_init(void)
{
    const char* p; const char* v;
    if (g_chk) return;
    g_chk = 1;
    p = getenv("LIBGL_TSP_FILES");
    if (!p || !p[0]) return;
    v = getenv("LIBGL_TSP_FILES_GAP"); if (v && v[0]) g_gap = atof(v);
    v = getenv("LIBGL_TSP_FILES_MAX"); if (v && v[0]) g_max = atol(v);
    g_log = fopen(p, "w");
    if (g_log) {
        fprintf(g_log, "# file access trace. OPEN = path opened, READ = offset/len,\n");
        fprintf(g_log, "# SLOW = gap over %.0fms between file operations\n", g_gap);
        fflush(g_log);
    }
    g_last_op = now_ms();
}

/* only trace paths we care about */
static int interesting(const char* p)
{
    if (!p) return 0;
    if (strstr(p, "/tmp/")) return 1;
    if (strstr(p, "openmw51")) return 1;
    if (strstr(p, "SDCARD")) return 1;
    return 0;
}

static void note_gap(void)
{
    double n = now_ms();
    double d = n - g_last_op;
    if (g_log && d > g_gap && g_n < g_max) {
        fprintf(g_log, "SLOW  t=%.0f gap=%.0fms\n", n, d);
        g_n++;
    }
    g_last_op = n;
}

#define REAL(name, rettype, params)                                      \
    static rettype (*real_##name) params = NULL;                         \
    static void resolve_##name(void) {                                   \
        if (!real_##name)                                                \
            real_##name = (rettype (*) params) dlsym(RTLD_NEXT, #name);  \
    }

REAL(open,    int,     (const char*, int, ...))
REAL(open64,  int,     (const char*, int, ...))
REAL(openat,  int,     (int, const char*, int, ...))
REAL(pread64, ssize_t, (int, void*, size_t, off64_t))
REAL(read,    ssize_t, (int, void*, size_t))
REAL(lseek64, off64_t, (int, off64_t, int))

static void record_open(int fd, const char* path)
{
    tsp_init();
    if (fd >= 0 && fd < MAXFD) {
        free(g_fdname[fd]);
        g_fdname[fd] = path ? strdup(path) : NULL;
    }
    if (g_log && interesting(path) && g_n < g_max) {
        note_gap();
        fprintf(g_log, "OPEN  fd=%-4d %s\n", fd, path);
        g_n++;
        if ((g_n & 0x3f) == 0) fflush(g_log);
    }
}

int open(const char* path, int flags, ...)
{
    int fd; mode_t m = 0;
    va_list ap; va_start(ap, flags); m = va_arg(ap, int); va_end(ap);
    resolve_open();
    fd = real_open ? real_open(path, flags, m) : -1;
    record_open(fd, path);
    return fd;
}

int open64(const char* path, int flags, ...)
{
    int fd; mode_t m = 0;
    va_list ap; va_start(ap, flags); m = va_arg(ap, int); va_end(ap);
    resolve_open64();
    fd = real_open64 ? real_open64(path, flags, m) : -1;
    record_open(fd, path);
    return fd;
}

int openat(int dirfd, const char* path, int flags, ...)
{
    int fd; mode_t m = 0;
    va_list ap; va_start(ap, flags); m = va_arg(ap, int); va_end(ap);
    resolve_openat();
    fd = real_openat ? real_openat(dirfd, path, flags, m) : -1;
    record_open(fd, path);
    return fd;
}

ssize_t pread64(int fd, void* buf, size_t n, off64_t off)
{
    ssize_t r;
    resolve_pread64();
    r = real_pread64 ? real_pread64(fd, buf, n, off) : -1;
    if (g_log && fd >= 0 && fd < MAXFD && interesting(g_fdname[fd]) && g_n < g_max) {
        note_gap();
        fprintf(g_log, "READ  t=%.0f fd=%-4d off=%lld len=%zu %s\n",
                now_ms(), fd, (long long)off, n,
                g_fdname[fd] ? g_fdname[fd] : "?");
        g_n++;
    }
    return r;
}

off64_t lseek64(int fd, off64_t off, int whence)
{
    off64_t r;
    resolve_lseek64();
    r = real_lseek64 ? real_lseek64(fd, off, whence) : -1;
    if (g_log && fd >= 0 && fd < MAXFD && g_fdname[fd]
        && strstr(g_fdname[fd], ".bsa") && g_n < g_max) {
        note_gap();
        fprintf(g_log, "SEEK  t=%.0f fd=%-4d off=%lld %s\n",
                now_ms(), fd, (long long)r, g_fdname[fd]);
        g_n++;
    }
    return r;
}
