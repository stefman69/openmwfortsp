/*
 * tsp_frameprof.c  -  per-frame submission profiler for OpenMW on TrimUI
 *
 * ===========================================================================
 * WHY THIS EXISTS
 * ===========================================================================
 *
 * Framerate collapses while a spell or status effect is active. Ruled out by
 * measurement so far:
 *
 *   GPU clock      150 MHz -> 888 MHz          no change
 *   memory clock   already pinned at 1200 MHz  not clamped
 *   CPU cores      3 online -> 8 online        no change
 *   CPU clock      unclamped, big cluster      helped baseline, not the dip
 *   OSG threading  Single / DrawThread / Cull  no change
 *   soft particles disabled                    no change
 *   per-thread CPU during the dip              under one core total
 *
 * The process is NOT compute saturated during the dip, so it is stalling
 * rather than working. This measures what OpenMW actually submits per frame,
 * which separates the remaining possibilities:
 *
 *   draws jump, frame time jumps   -> submission volume; the effect adds
 *                                     hundreds of batches (per-particle
 *                                     draws). Fix is batching or particle
 *                                     count.
 *
 *   draws flat, frame time jumps   -> per-fragment or per-pass cost; the
 *                                     same geometry is simply more expensive
 *                                     to rasterise (blending, overdraw).
 *
 *   draws flat, frame time flat,
 *   but fps still drops            -> the stall is outside submission
 *                                     entirely: swap/vsync or driver sync.
 *
 * ===========================================================================
 * WHAT IT LOGS
 * ===========================================================================
 *
 * One line per frame:
 *
 *   f=1234 ms=48.２ fps=20.7 draws=312 verts=45102 tris=15034 binds=88 progs=12
 *
 *   ms      wall time for that frame, measured at SwapWindow
 *   draws   glDrawArrays + glDrawElements calls
 *   verts   total vertices submitted
 *   tris    triangles, where the primitive mode makes that meaningful
 *   binds   glBindTexture calls (state change pressure)
 *   progs   glUseProgram calls (shader switches, expensive on tilers)
 *
 * Compare a run of normal frames against frames during the effect. The column
 * that inflates names the cause.
 *
 * ===========================================================================
 * USAGE
 * ===========================================================================
 *
 *   build:  gcc -shared -fPIC -O2 -o libtsp_frameprof.so tsp_frameprof.c -ldl
 *   place FIRST in LD_PRELOAD, ahead of the scaler and libGL
 *
 *   export LIBGL_TSP_FRAMEPROF=/mnt/SDCARD/tsp_frames.txt
 *   export LIBGL_TSP_FRAMEPROF_MAX=4000     (optional, default 4000)
 *
 * Unset the path and it logs nothing and opens no file - one branch per call.
 *
 * Safe by construction: every hook forwards to the real function and returns
 * its value unchanged. No engine state is touched or dereferenced.
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
typedef void           GLvoid;

#define TSP_GL_TRIANGLES        0x0004
#define TSP_GL_TRIANGLE_STRIP   0x0005
#define TSP_GL_TRIANGLE_FAN     0x0006

/* ------------------------------------------------------------------ */
/* state                                                               */
/* ------------------------------------------------------------------ */

static FILE*         g_log   = NULL;
static int           g_check = 0;
static unsigned long g_max   = 4000;
static unsigned long g_frame = 0;

static unsigned long f_draws = 0;
static unsigned long f_verts = 0;
static unsigned long f_tris  = 0;
static unsigned long f_binds = 0;
static unsigned long f_progs = 0;
/* stall-related counters: these are the operations that force the CPU to
   wait for the GPU, or that touch a resource the GPU may still be using */
static unsigned long f_texup = 0;   /* glTexImage2D + glTexSubImage2D   */
static unsigned long f_texbytes=0;  /* approximate upload volume        */
static unsigned long f_copytex= 0;  /* glCopyTexSubImage2D              */
static unsigned long f_readpix= 0;  /* glReadPixels - hard sync         */
static unsigned long f_finish = 0;  /* glFinish - hard sync             */
static unsigned long f_flush  = 0;  /* glFlush                          */
static unsigned long f_fbo    = 0;  /* framebuffer switches             */
static unsigned long f_bufup  = 0;  /* glBufferData/SubData             */
/* shader pipeline: compiles and links mid-frame are hard stalls and are the
   prime suspect - gl4es generates shader permutations from fixed-function
   state, so an effect that changes texenv/texgen state can force new
   compiles every frame */
static unsigned long f_compile = 0;
static unsigned long f_link    = 0;
static unsigned long f_shsrc   = 0;
static unsigned long f_newprog = 0;
/* THE decisive split: microseconds spent inside draw calls (CPU-side driver
   work) versus inside SwapWindow (waiting for the GPU to catch up).
   draw_us explodes  -> CPU-side per-draw cost in gl4es or the driver
   swap_us explodes  -> genuinely GPU bound, the CPU is just waiting
   neither explodes  -> the time is elsewhere in the frame entirely */
static double f_draw_us = 0.0;
static double f_swap_us = 0.0;
static double f_worst_us = 0.0;
static unsigned long f_worst_count = 0;
static unsigned f_worst_mode = 0;

static double g_last_ms = 0.0;

static double tsp_now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

static void tsp_open(void)
{
    const char* p;
    const char* m;

    if (g_check) return;
    g_check = 1;

    p = getenv("LIBGL_TSP_FRAMEPROF");
    if (!p || !p[0]) return;

    m = getenv("LIBGL_TSP_FRAMEPROF_MAX");
    if (m && m[0]) {
        long v = atol(m);
        if (v > 0) g_max = (unsigned long)v;
    }

    g_log = fopen(p, "w");
    if (g_log) {
        fprintf(g_log, "# tsp_frameprof  max=%lu frames\n", g_max);
        fprintf(g_log, "# f=frame ms=frametime draws/verts/tris=submission "
                       "binds=texture_binds progs=shader_switches\n");
        fflush(g_log);
    }
    g_last_ms = tsp_now_ms();
}

/* ------------------------------------------------------------------ */
/* real function resolution                                            */
/* ------------------------------------------------------------------ */

#define REAL(name, rettype, params)                                      \
    static rettype (*real_##name) params = NULL;                         \
    static void resolve_##name(void) {                                   \
        if (!real_##name)                                                \
            real_##name = (rettype (*) params) dlsym(RTLD_NEXT, #name);  \
    }

REAL(glDrawArrays,       void, (GLenum, GLint, GLsizei))
REAL(glDrawElements,     void, (GLenum, GLsizei, GLenum, const GLvoid*))
REAL(glBindTexture,      void, (GLenum, GLuint))
REAL(glUseProgram,       void, (GLuint))
REAL(SDL_GL_SwapWindow,  void, (void*))
REAL(glTexImage2D,       void, (GLenum,GLint,GLint,GLsizei,GLsizei,GLint,GLenum,GLenum,const GLvoid*))
REAL(glTexSubImage2D,    void, (GLenum,GLint,GLint,GLint,GLsizei,GLsizei,GLenum,GLenum,const GLvoid*))
REAL(glCopyTexSubImage2D,void, (GLenum,GLint,GLint,GLint,GLint,GLint,GLsizei,GLsizei))
REAL(glReadPixels,       void, (GLint,GLint,GLsizei,GLsizei,GLenum,GLenum,GLvoid*))
REAL(glFinish,           void, (void))
REAL(glFlush,            void, (void))
REAL(glBindFramebuffer,  void, (GLenum,GLuint))
REAL(glBufferData,       void, (GLenum,long,const GLvoid*,GLenum))
REAL(glBufferSubData,    void, (GLenum,long,long,const GLvoid*))
REAL(glCompileShader,    void, (GLuint))
REAL(glLinkProgram,      void, (GLuint))
REAL(glShaderSource,     void, (GLuint,GLsizei,const char* const*,const GLint*))
REAL(glCreateProgram,    GLuint, (void))

/* ------------------------------------------------------------------ */
/* counting hooks                                                      */
/* ------------------------------------------------------------------ */

static void count_prim(GLenum mode, GLsizei count)
{
    f_draws++;
    f_verts += (unsigned long)(count > 0 ? count : 0);
    if (count >= 3) {
        if (mode == TSP_GL_TRIANGLES)
            f_tris += (unsigned long)(count / 3);
        else if (mode == TSP_GL_TRIANGLE_STRIP || mode == TSP_GL_TRIANGLE_FAN)
            f_tris += (unsigned long)(count - 2);
    }
}

void glDrawArrays(GLenum mode, GLint first, GLsizei count)
{
    double t0, dt;
    resolve_glDrawArrays();
    count_prim(mode, count);
    t0 = tsp_now_ms();
    if (real_glDrawArrays) real_glDrawArrays(mode, first, count);
    dt = (tsp_now_ms() - t0) * 1000.0;
    f_draw_us += dt;
    if (dt > f_worst_us) { f_worst_us = dt; f_worst_count = (unsigned long)count; f_worst_mode = mode; }
}

void glDrawElements(GLenum mode, GLsizei count, GLenum type, const GLvoid* idx)
{
    double t0, dt;
    resolve_glDrawElements();
    count_prim(mode, count);
    t0 = tsp_now_ms();
    if (real_glDrawElements) real_glDrawElements(mode, count, type, idx);
    dt = (tsp_now_ms() - t0) * 1000.0;
    f_draw_us += dt;
    if (dt > f_worst_us) { f_worst_us = dt; f_worst_count = (unsigned long)count; f_worst_mode = mode; }
}

void glBindTexture(GLenum target, GLuint tex)
{
    resolve_glBindTexture();
    f_binds++;
    if (real_glBindTexture) real_glBindTexture(target, tex);
}

void glUseProgram(GLuint prog)
{
    resolve_glUseProgram();
    f_progs++;
    if (real_glUseProgram) real_glUseProgram(prog);
}

/* ------------------------------------------------------------------ */
/* frame boundary                                                      */
/* ------------------------------------------------------------------ */

void SDL_GL_SwapWindow(void* window)
{
    double now, dt;

    resolve_SDL_GL_SwapWindow();
    tsp_open();

    if (g_log && g_frame < g_max) {
        now = tsp_now_ms();
        dt  = now - g_last_ms;
        g_last_ms = now;

        fprintf(g_log,
                "f=%lu ms=%.1f fps=%.1f draws=%lu verts=%lu tris=%lu binds=%lu progs=%lu "
                "texup=%lu texkb=%lu copytex=%lu readpix=%lu finish=%lu flush=%lu fbo=%lu bufup=%lu "
                "compile=%lu link=%lu shsrc=%lu newprog=%lu "
                "draw_us=%.0f swap_us=%.0f worst_us=%.0f worst_n=%lu worst_mode=0x%x\n",
                g_frame, dt, (dt > 0.0 ? 1000.0 / dt : 0.0),
                f_draws, f_verts, f_tris, f_binds, f_progs,
                f_texup, f_texbytes/1024, f_copytex, f_readpix,
                f_finish, f_flush, f_fbo, f_bufup,
                f_compile, f_link, f_shsrc, f_newprog,
                f_draw_us, f_swap_us, f_worst_us, f_worst_count, f_worst_mode);

        if ((g_frame & 0x3f) == 0) fflush(g_log);
        g_frame++;
    }

    f_draws = 0;
    f_verts = 0;
    f_tris  = 0;
    f_binds = 0;
    f_progs = 0;
    f_texup = 0; f_texbytes = 0; f_copytex = 0; f_readpix = 0;
    f_finish = 0; f_flush = 0; f_fbo = 0; f_bufup = 0;
    f_compile = 0; f_link = 0; f_shsrc = 0; f_newprog = 0;
    f_draw_us = 0.0; f_worst_us = 0.0; f_worst_count = 0; f_worst_mode = 0;

    {
        double s0 = tsp_now_ms();
        if (real_SDL_GL_SwapWindow) real_SDL_GL_SwapWindow(window);
        f_swap_us = (tsp_now_ms() - s0) * 1000.0;
    }
}

/* ------------------------------------------------------------------ */
/* stall-related hooks                                                 */
/* ------------------------------------------------------------------ */

void glTexImage2D(GLenum t, GLint l, GLint ifmt, GLsizei w, GLsizei h,
                  GLint b, GLenum f, GLenum ty, const GLvoid* d)
{
    resolve_glTexImage2D();
    f_texup++;
    if (d) f_texbytes += (unsigned long)w * (unsigned long)h * 4;
    if (real_glTexImage2D) real_glTexImage2D(t,l,ifmt,w,h,b,f,ty,d);
}

void glTexSubImage2D(GLenum t, GLint l, GLint xo, GLint yo,
                     GLsizei w, GLsizei h, GLenum f, GLenum ty, const GLvoid* d)
{
    resolve_glTexSubImage2D();
    f_texup++;
    if (d) f_texbytes += (unsigned long)w * (unsigned long)h * 4;
    if (real_glTexSubImage2D) real_glTexSubImage2D(t,l,xo,yo,w,h,f,ty,d);
}

void glCopyTexSubImage2D(GLenum t, GLint l, GLint xo, GLint yo,
                         GLint x, GLint y, GLsizei w, GLsizei h)
{
    resolve_glCopyTexSubImage2D();
    f_copytex++;
    if (real_glCopyTexSubImage2D) real_glCopyTexSubImage2D(t,l,xo,yo,x,y,w,h);
}

void glReadPixels(GLint x, GLint y, GLsizei w, GLsizei h,
                  GLenum f, GLenum t, GLvoid* d)
{
    resolve_glReadPixels();
    f_readpix++;
    if (real_glReadPixels) real_glReadPixels(x,y,w,h,f,t,d);
}

void glFinish(void)
{
    resolve_glFinish();
    f_finish++;
    if (real_glFinish) real_glFinish();
}

void glFlush(void)
{
    resolve_glFlush();
    f_flush++;
    if (real_glFlush) real_glFlush();
}

void glBindFramebuffer(GLenum target, GLuint fb)
{
    resolve_glBindFramebuffer();
    f_fbo++;
    if (real_glBindFramebuffer) real_glBindFramebuffer(target, fb);
}

void glBufferData(GLenum t, long size, const GLvoid* d, GLenum usage)
{
    resolve_glBufferData();
    f_bufup++;
    if (real_glBufferData) real_glBufferData(t,size,d,usage);
}

void glBufferSubData(GLenum t, long off, long size, const GLvoid* d)
{
    resolve_glBufferSubData();
    f_bufup++;
    if (real_glBufferSubData) real_glBufferSubData(t,off,size,d);
}

void glCompileShader(GLuint sh)
{
    resolve_glCompileShader();
    f_compile++;
    if (real_glCompileShader) real_glCompileShader(sh);
}

void glLinkProgram(GLuint pr)
{
    resolve_glLinkProgram();
    f_link++;
    if (real_glLinkProgram) real_glLinkProgram(pr);
}

void glShaderSource(GLuint sh, GLsizei n, const char* const* str, const GLint* len)
{
    resolve_glShaderSource();
    f_shsrc++;
    if (real_glShaderSource) real_glShaderSource(sh, n, str, len);
}

GLuint glCreateProgram(void)
{
    resolve_glCreateProgram();
    f_newprog++;
    return real_glCreateProgram ? real_glCreateProgram() : 0;
}
