/*
 * tsp_drawstate.c  -  per-draw GL state capture for the OpenMW TrimUI port
 *
 * ===========================================================================
 * WHY
 * ===========================================================================
 *
 * Measured with tsp_frameprof: while a spell/status effect is active the frame
 * goes from 26 ms to 68 ms, and the entire increase is in SwapWindow:
 *
 *              frame     draw_us    swap_us    other
 *   before     26.7      1.65        9.63      15.42
 *   effect     68.3      2.02       47.38      18.94
 *   after      25.8      1.77        9.79      14.26
 *
 * CPU submission is unchanged. The CPU finishes the frame in ~2 ms and then
 * blocks ~47 ms at swap waiting for the GPU. So the GPU is doing 5x the work
 * for near-identical geometry (136 vs 129 draws, 33k vs 32k verts).
 *
 * Ruled out by measurement: GPU clock (helps only 25%, so not ALU bound),
 * memory clock (already at max), resolution (no effect, so not simple fill
 * rate), CPU cores and clock, OSG threading, shader compilation, soft
 * particles, draw call count, vertex count.
 *
 * What is left is a STATE difference: the effect's draws enable something
 * that is cheap on desktop GL and expensive on a tile-based Mali - the usual
 * culprits being alpha test emulated as discard (kills early-Z), blending
 * combinations that force tile read-back, depth writes with blending, or
 * per-draw program switches that flush the tile pipeline.
 *
 * This records the exact state of every draw and dumps it for slow frames, so
 * the expensive state can be identified rather than guessed at.
 *
 * ===========================================================================
 * OUTPUT
 * ===========================================================================
 *
 * For each frame slower than LIBGL_TSP_DS_MS (default 45 ms), one block:
 *
 *   FRAME f=612 ms=81.8 draws=142
 *     x18  blend=1 src=0x302 dst=0x303 depth=1 dmask=0 cull=0 tex=41 prog=7 mode=0x4 n=6
 *     x92  blend=0 src=0x1   dst=0x0   depth=1 dmask=1 cull=1 tex=17 prog=3 mode=0x4 n=384
 *     ...
 *
 * Identical draws are collapsed with a count, so the block stays readable.
 * Diff a slow frame against a fast one and the extra state stands out.
 *
 * ===========================================================================
 * BUILD / USE
 * ===========================================================================
 *
 *   gcc -shared -fPIC -O2 -o libtsp_drawstate.so tsp_drawstate.c -ldl
 *
 *   export LIBGL_TSP_DRAWSTATE=/mnt/SDCARD/tsp_drawstate.txt
 *   export LIBGL_TSP_DS_MS=45        threshold in ms, optional
 *   export LIBGL_TSP_DS_FRAMES=40    max frames to dump, optional
 *
 * Place FIRST in LD_PRELOAD. Unset the path and it does nothing.
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef unsigned int   GLenum;
typedef unsigned int   GLuint;
typedef int            GLint;
typedef int            GLsizei;
typedef unsigned char  GLboolean;
typedef void           GLvoid;

#define GL_BLEND        0x0BE2
#define GL_DEPTH_TEST   0x0B71
#define GL_CULL_FACE    0x0B44
#define GL_TEXTURE_2D   0x0DE1
#define GL_SCISSOR_TEST 0x0C11

/* ------------------------------------------------------------------ */
/* tracked state                                                       */
/* ------------------------------------------------------------------ */

static int    s_blend = 0, s_depth = 0, s_cull = 0, s_scissor = 0;
static GLenum s_src = 1, s_dst = 0;
static int    s_dmask = 1;
static GLuint s_tex = 0, s_prog = 0;

/* per-draw records, collapsed by identical signature */
#define MAXREC 256
struct rec {
    int blend, depth, cull, dmask;
    GLenum src, dst, mode;
    GLuint tex, prog;
    long n;
    unsigned long count;
};
static struct rec g_rec[MAXREC];
static int g_nrec = 0;

static FILE*  g_log = NULL;
static int    g_check = 0;
static double g_thresh_ms = 45.0;
static long   g_max_frames = 40;
static long   g_dumped = 0;
static unsigned long g_frame = 0;
static double g_last = 0.0;
static unsigned long g_draws = 0;

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

static void tsp_open(void)
{
    const char* p; const char* v;
    if (g_check) return;
    g_check = 1;
    p = getenv("LIBGL_TSP_DRAWSTATE");
    if (!p || !p[0]) return;
    v = getenv("LIBGL_TSP_DS_MS");     if (v && v[0]) g_thresh_ms  = atof(v);
    v = getenv("LIBGL_TSP_DS_FRAMES"); if (v && v[0]) g_max_frames = atol(v);
    g_log = fopen(p, "w");
    if (g_log) {
        fprintf(g_log, "# per-draw state for frames slower than %.0f ms\n", g_thresh_ms);
        fprintf(g_log, "# xN = that many identical draws in the frame\n");
        fflush(g_log);
    }
    g_last = now_ms();
}

/* experiment: skip the effect's GL_QUADS draws to confirm they are the cost.
   LIBGL_TSP_SKIPQUADS=1 drops blended GL_QUADS draws entirely. */
static int tsp_skip(GLenum mode)
{
    static int chk=0,on=0;
    return on && mode==0x7 && s_blend;
}

static void record(GLenum mode, GLsizei count)
{
    int i;
    g_draws++;
    if (!g_log || g_dumped >= g_max_frames) return;
    for (i = 0; i < g_nrec; i++) {
        struct rec* r = &g_rec[i];
        if (r->blend == s_blend && r->depth == s_depth && r->cull == s_cull
            && r->dmask == s_dmask && r->src == s_src && r->dst == s_dst
            && r->tex == s_tex && r->prog == s_prog
            && r->mode == mode && r->n == (long)count) {
            r->count++;
            return;
        }
    }
    if (g_nrec >= MAXREC) return;
    g_rec[g_nrec].blend = s_blend; g_rec[g_nrec].depth = s_depth;
    g_rec[g_nrec].cull  = s_cull;  g_rec[g_nrec].dmask = s_dmask;
    g_rec[g_nrec].src   = s_src;   g_rec[g_nrec].dst   = s_dst;
    g_rec[g_nrec].tex   = s_tex;   g_rec[g_nrec].prog  = s_prog;
    g_rec[g_nrec].mode  = mode;    g_rec[g_nrec].n     = (long)count;
    g_rec[g_nrec].count = 1;
    g_nrec++;
}

/* ------------------------------------------------------------------ */

#define REAL(name, rettype, params)                                      \
    static rettype (*real_##name) params = NULL;                         \
    static void resolve_##name(void) {                                   \
        if (!real_##name)                                                \
            real_##name = (rettype (*) params) dlsym(RTLD_NEXT, #name);  \
    }

REAL(glEnable,          void, (GLenum))
REAL(glDisable,         void, (GLenum))
REAL(glBlendFunc,       void, (GLenum, GLenum))
REAL(glDepthMask,       void, (GLboolean))
REAL(glBindTexture,     void, (GLenum, GLuint))
REAL(glUseProgram,      void, (GLuint))
REAL(glDrawArrays,      void, (GLenum, GLint, GLsizei))
REAL(glDrawElements,    void, (GLenum, GLsizei, GLenum, const GLvoid*))
REAL(SDL_GL_SwapWindow, void, (void*))

void glEnable(GLenum c)
{
    resolve_glEnable();
    if (c == GL_BLEND) s_blend = 1;
    else if (c == GL_DEPTH_TEST) s_depth = 1;
    else if (c == GL_CULL_FACE) s_cull = 1;
    else if (c == GL_SCISSOR_TEST) s_scissor = 1;
    if (real_glEnable) real_glEnable(c);
}

void glDisable(GLenum c)
{
    resolve_glDisable();
    if (c == GL_BLEND) s_blend = 0;
    else if (c == GL_DEPTH_TEST) s_depth = 0;
    else if (c == GL_CULL_FACE) s_cull = 0;
    else if (c == GL_SCISSOR_TEST) s_scissor = 0;
    if (real_glDisable) real_glDisable(c);
}

void glBlendFunc(GLenum s, GLenum d)
{
    resolve_glBlendFunc();
    s_src = s; s_dst = d;
    if (real_glBlendFunc) real_glBlendFunc(s, d);
}

void glDepthMask(GLboolean f)
{
    resolve_glDepthMask();
    s_dmask = f ? 1 : 0;
    if (real_glDepthMask) real_glDepthMask(f);
}

void glBindTexture(GLenum t, GLuint tex)
{
    resolve_glBindTexture();
    if (t == GL_TEXTURE_2D) s_tex = tex;
    if (real_glBindTexture) real_glBindTexture(t, tex);
}

void glUseProgram(GLuint p)
{
    resolve_glUseProgram();
    s_prog = p;
    if (real_glUseProgram) real_glUseProgram(p);
}

void glDrawArrays(GLenum mode, GLint first, GLsizei count)
{
    resolve_glDrawArrays();
    record(mode, count);
    if (tsp_skip(mode)) return;
    if (real_glDrawArrays) real_glDrawArrays(mode, first, count);
}

void glDrawElements(GLenum mode, GLsizei count, GLenum type, const GLvoid* i)
{
    resolve_glDrawElements();
    record(mode, count);
    if (tsp_skip(mode)) return;
    if (real_glDrawElements) real_glDrawElements(mode, count, type, i);
}

void SDL_GL_SwapWindow(void* w)
{
    double n, dt;
    int i;

    resolve_SDL_GL_SwapWindow();
    tsp_open();

    n = now_ms();
    dt = n - g_last;
    g_last = n;

    if (g_log && dt > g_thresh_ms && g_dumped < g_max_frames && g_frame > 30) {
        fprintf(g_log, "\nFRAME f=%lu ms=%.1f draws=%lu distinct=%d\n",
                g_frame, dt, g_draws, g_nrec);
        for (i = 0; i < g_nrec; i++) {
            struct rec* r = &g_rec[i];
            fprintf(g_log,
                "  x%-4lu blend=%d src=0x%-4x dst=0x%-4x depth=%d dmask=%d cull=%d tex=%-4u prog=%-3u mode=0x%x n=%ld\n",
                r->count, r->blend, r->src, r->dst, r->depth, r->dmask,
                r->cull, r->tex, r->prog, r->mode, r->n);
        }
        fflush(g_log);
        g_dumped++;
    }

    g_frame++;
    g_nrec = 0;
    g_draws = 0;
    if (real_SDL_GL_SwapWindow) real_SDL_GL_SwapWindow(w);
}
