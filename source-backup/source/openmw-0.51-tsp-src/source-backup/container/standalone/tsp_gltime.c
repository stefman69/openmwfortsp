/* tsp_gltime.c - per-frame GL cost breakdown by function
 *
 * tspprof v6 narrowed the hitch to the OSG DRAW traversal: frame 4844 was
 * total 833.8 ms, cpu 742.2, render 804.0, draw 783.0 - with compos 0.0 and
 * cmaps 0, so composite maps are not it. Cull is ~5 ms and never spikes. The
 * residual is flat at 13-20 ms and is the swap wait. Everything left is OSG
 * applying state and submitting primitives through gl4es, which from inside
 * OpenMW is one opaque number.
 *
 *   gcc-13 -shared -fPIC -O2 -o libtsp_gltime.so tsp_gltime.c -ldl
 *
 *   TSP_GLT_OUT    output path (default /mnt/SDCARD/tsp_gltime.txt)
 *   TSP_GLT_MS     report frames this slow or slower, ms (default 120)
 *   TSP_GLT_EVERY  rolling summary every N frames (default 600)
 *
 * Two clock_gettime calls per wrapped GL call, ~50 ns. At 12k draw calls that
 * is ~0.6 ms of a 40 ms frame; the report prints its own overhead so it can
 * be subtracted.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stddef.h>

typedef unsigned int GLenum;
typedef unsigned int GLuint;
typedef unsigned int GLbitfield;
typedef int GLint;
typedef int GLsizei;
typedef float GLfloat;
typedef unsigned char GLboolean;
typedef ptrdiff_t GLintptr;
typedef ptrdiff_t GLsizeiptr;

enum {
    S_DRAWELEM = 0, S_DRAWARR, S_DRAWRANGE,
    S_TEXIMG, S_TEXSUB, S_TEXCOMP, S_TEXPARM, S_BINDTEX, S_GENTEX, S_DELTEX,
    S_COMPILE, S_LINK, S_USEPROG, S_SHSRC, S_UNIFORM,
    S_BUFDATA, S_BUFSUB, S_BINDBUF,
    S_BINDFBO, S_FBOTEX, S_FBOCHECK, S_RBSTORE,
    S_CLEAR, S_FLUSH, S_FINISH, S_READPIX, S_GETERR, S_VIEWPORT,
    S_SWAP,
    S_COUNT
};

static const char* g_name[S_COUNT] = {
    "glDrawElements", "glDrawArrays", "glDrawRangeElements",
    "glTexImage2D", "glTexSubImage2D", "glCompressedTexImage2D", "glTexParameteri",
    "glBindTexture", "glGenTextures", "glDeleteTextures",
    "glCompileShader", "glLinkProgram", "glUseProgram", "glShaderSource", "glUniform*",
    "glBufferData", "glBufferSubData", "glBindBuffer",
    "glBindFramebuffer", "glFramebufferTexture2D", "glCheckFramebufferStatus", "glRenderbufferStorage",
    "glClear", "glFlush", "glFinish", "glReadPixels", "glGetError", "glViewport",
    "SDL_GL_SwapWindow"
};

static double g_ms[S_COUNT];
static long g_n[S_COUNT];
static double g_tot_ms[S_COUNT];
static long g_tot_n[S_COUNT];

static double g_t0 = -1.0;
static long g_frame = 0;
static long g_reported = 0;
static double g_thresh = 120.0;
static long g_every = 600;
static double g_overhead = 0.0;
static FILE* g_out = NULL;

static double nowms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

static void tsp_open(void)
{
    if (g_out) return;
    const char* p = getenv("TSP_GLT_OUT");
    if (!p || !p[0]) p = "/mnt/SDCARD/tsp_gltime.txt";
    g_out = fopen(p, "a");
    if (!g_out) g_out = stderr;
    const char* t = getenv("TSP_GLT_MS");
    if (t && t[0]) g_thresh = atof(t);
    const char* e = getenv("TSP_GLT_EVERY");
    if (e && e[0]) g_every = atol(e);
    fprintf(g_out, "\nTSP_GLT start thresh_ms=%.0f every=%ld\n", g_thresh, g_every);
    fflush(g_out);
}

/* If gl4es does not export something this shim wraps, the symbol now resolves
   HERE and does nothing - which would silently drop geometry. Say so loudly
   rather than letting it look like a rendering bug. */
static void tsp_missing(const char* fn)
{
    static const char* seen[S_COUNT];
    static int nseen = 0;
    int i;
    for (i = 0; i < nseen; i++)
        if (seen[i] == fn) return;
    if (nseen < S_COUNT) seen[nseen++] = fn;
    tsp_open();
    fprintf(g_out, "TSP_GLT *** MISSING SYMBOL %s - not in the chain below us, calls are being DROPPED\n", fn);
    fflush(g_out);
}

static void acc(int s, double ms)
{
    g_ms[s] += ms;
    g_n[s] += 1;
    g_overhead += 0.00005;
}

static void report(const char* why, double total)
{
    int order[S_COUNT], i, j, k;
    for (i = 0; i < S_COUNT; i++) order[i] = i;
    for (i = 0; i < S_COUNT; i++)
        for (j = i + 1; j < S_COUNT; j++)
            if (g_ms[order[j]] > g_ms[order[i]]) { k = order[i]; order[i] = order[j]; order[j] = k; }
    double acc_ms = 0.0;
    for (i = 0; i < S_COUNT; i++) acc_ms += g_ms[i];
    fprintf(g_out, "TSP_GLT %s frame=%ld total=%.1f gl=%.1f shim=%.1f |",
        why, g_frame, total, acc_ms, g_overhead);
    for (i = 0; i < S_COUNT; i++)
    {
        int s = order[i];
        if (g_ms[s] < 0.5 && i > 5) break;
        fprintf(g_out, " %s=%.1f/%ld", g_name[s], g_ms[s], g_n[s]);
    }
    fputc('\n', g_out);
    fflush(g_out);
    ++g_reported;
}

static void endframe(void)
{
    double now = nowms();
    if (g_t0 < 0.0) { g_t0 = now; return; }
    double total = now - g_t0;
    g_t0 = now;
    ++g_frame;

    int i;
    for (i = 0; i < S_COUNT; i++) { g_tot_ms[i] += g_ms[i]; g_tot_n[i] += g_n[i]; }

    if (total >= g_thresh && g_reported < 400)
        report("SLOW", total);

    if (g_every > 0 && (g_frame % g_every) == 0)
    {
        int order[S_COUNT], a, b, t;
        for (a = 0; a < S_COUNT; a++) order[a] = a;
        for (a = 0; a < S_COUNT; a++)
            for (b = a + 1; b < S_COUNT; b++)
                if (g_tot_ms[order[b]] > g_tot_ms[order[a]]) { t = order[a]; order[a] = order[b]; order[b] = t; }
        fprintf(g_out, "TSP_GLT MEAN over %ld frames |", g_frame);
        for (a = 0; a < 8; a++)
        {
            int s = order[a];
            fprintf(g_out, " %s=%.2fms/%.0f", g_name[s],
                g_tot_ms[s] / (double)g_frame, (double)g_tot_n[s] / (double)g_frame);
        }
        fputc('\n', g_out);
        fflush(g_out);
    }

    for (i = 0; i < S_COUNT; i++) { g_ms[i] = 0.0; g_n[i] = 0; }
    g_overhead = 0.0;
}

#define WRAPV(SLOT, NAME, PARAMS, ARGS)                                        \
    void NAME PARAMS                                                           \
    {                                                                          \
        static void (*real) PARAMS = NULL;                                     \
        if (!real) { tsp_open(); real = dlsym(RTLD_NEXT, #NAME); }             \
        if (!real) { tsp_missing(#NAME); return; }                             \
        double t0 = nowms();                                                   \
        real ARGS;                                                             \
        acc(SLOT, nowms() - t0);                                               \
    }

#define WRAPR(SLOT, RET, NAME, PARAMS, ARGS, DEF)                              \
    RET NAME PARAMS                                                            \
    {                                                                          \
        static RET (*real) PARAMS = NULL;                                      \
        if (!real) { tsp_open(); real = dlsym(RTLD_NEXT, #NAME); }             \
        if (!real) { tsp_missing(#NAME); return DEF; }                         \
        double t0 = nowms();                                                   \
        RET r = real ARGS;                                                     \
        acc(SLOT, nowms() - t0);                                               \
        return r;                                                              \
    }

WRAPV(S_DRAWELEM, glDrawElements, (GLenum a, GLsizei b, GLenum c, const void* d), (a, b, c, d))
WRAPV(S_DRAWARR, glDrawArrays, (GLenum a, GLint b, GLsizei c), (a, b, c))
WRAPV(S_DRAWRANGE, glDrawRangeElements, (GLenum a, GLuint b, GLuint c, GLsizei d, GLenum e, const void* f), (a, b, c, d, e, f))
WRAPV(S_TEXIMG, glTexImage2D, (GLenum a, GLint b, GLint c, GLsizei d, GLsizei e, GLint f, GLenum g, GLenum h, const void* i), (a, b, c, d, e, f, g, h, i))
WRAPV(S_TEXSUB, glTexSubImage2D, (GLenum a, GLint b, GLint c, GLint d, GLsizei e, GLsizei f, GLenum g, GLenum h, const void* i), (a, b, c, d, e, f, g, h, i))
WRAPV(S_TEXCOMP, glCompressedTexImage2D, (GLenum a, GLint b, GLenum c, GLsizei d, GLsizei e, GLint f, GLsizei g, const void* h), (a, b, c, d, e, f, g, h))
WRAPV(S_TEXPARM, glTexParameteri, (GLenum a, GLenum b, GLint c), (a, b, c))
WRAPV(S_BINDTEX, glBindTexture, (GLenum a, GLuint b), (a, b))
WRAPV(S_GENTEX, glGenTextures, (GLsizei a, GLuint* b), (a, b))
WRAPV(S_DELTEX, glDeleteTextures, (GLsizei a, const GLuint* b), (a, b))
WRAPV(S_COMPILE, glCompileShader, (GLuint a), (a))
WRAPV(S_LINK, glLinkProgram, (GLuint a), (a))
WRAPV(S_USEPROG, glUseProgram, (GLuint a), (a))
WRAPV(S_SHSRC, glShaderSource, (GLuint a, GLsizei b, const char* const* c, const GLint* d), (a, b, c, d))
WRAPV(S_UNIFORM, glUniformMatrix4fv, (GLint a, GLsizei b, GLboolean c, const GLfloat* d), (a, b, c, d))
WRAPV(S_BUFDATA, glBufferData, (GLenum a, GLsizeiptr b, const void* c, GLenum d), (a, b, c, d))
WRAPV(S_BUFSUB, glBufferSubData, (GLenum a, GLintptr b, GLsizeiptr c, const void* d), (a, b, c, d))
WRAPV(S_BINDBUF, glBindBuffer, (GLenum a, GLuint b), (a, b))
WRAPV(S_BINDFBO, glBindFramebuffer, (GLenum a, GLuint b), (a, b))
WRAPV(S_FBOTEX, glFramebufferTexture2D, (GLenum a, GLenum b, GLenum c, GLuint d, GLint e), (a, b, c, d, e))
WRAPR(S_FBOCHECK, GLenum, glCheckFramebufferStatus, (GLenum a), (a), 0)
WRAPV(S_RBSTORE, glRenderbufferStorage, (GLenum a, GLenum b, GLsizei c, GLsizei d), (a, b, c, d))
WRAPV(S_CLEAR, glClear, (GLbitfield a), (a))
WRAPV(S_FLUSH, glFlush, (void), ())
WRAPV(S_FINISH, glFinish, (void), ())
WRAPV(S_READPIX, glReadPixels, (GLint a, GLint b, GLsizei c, GLsizei d, GLenum e, GLenum f, void* g), (a, b, c, d, e, f, g))
WRAPR(S_GETERR, GLenum, glGetError, (void), (), 0)
WRAPV(S_VIEWPORT, glViewport, (GLint a, GLint b, GLsizei c, GLsizei d), (a, b, c, d))

void SDL_GL_SwapWindow(void* w)
{
    static void (*real)(void*) = NULL;
    if (!real) { tsp_open(); real = dlsym(RTLD_NEXT, "SDL_GL_SwapWindow"); }
    if (!real) { tsp_missing("SDL_GL_SwapWindow"); return; }
    double t0 = nowms();
    real(w);
    acc(S_SWAP, nowms() - t0);
    endframe();
}
