/* tsp_state.c v2 - TSP_STATECOST: where an interior frame's CPU actually goes.
 *
 * v1 result: bind+prog+unif carried 4% of the delta, not the >70% predicted.
 * gl4es binds textures at 2.5 us and programs at 1.2 us - normal. 84% sat in
 * "other". But the counts showed attr = 2 calls per FRAME against 124 draws,
 * and only 25 of 124 draws binding a GLSL program, so most drawing goes
 * through the fixed-function path - and v1 intercepted none of it. Every FFP
 * call was being counted as "other". v2 covers it.
 *
 *   frame_us = draw+bind+prog+unif+attr+en+buf+mtx+lite+arr+fix+err+clr+swap+other
 *
 * mtx  = matrix stack        lite = light / material
 * arr  = client vertex arrays  fix = texenv and per-draw modes
 * err  = glGetError (a per-draw error check is a classic hidden cost)
 * clr  = glClear
 *
 * "other" now genuinely means CPU reaching no GL call at all: OSG cull, OSG
 * state application, engine update.
 *
 * MEASUREMENT ONLY. Every wrapper forwards unconditionally.
 *
 * ENVIRONMENT
 *   TSP_STATE=1            enable. Unset/0 = fully passive, one stderr line.
 *   TSP_STATE_OUT=path     default /mnt/SDCARD/tsp_state.txt   (append)
 *   TSP_STATE_MAX=2000000  max frame lines
 *
 * BUILD (no line continuations anywhere - safe to paste as a heredoc)
 *   gcc-13 -shared -fPIC -O2 -Wall -Wextra -o libtsp_state.so tsp_state.c -ldl
 *
 * LD_PRELOAD: FIRST, ahead of libtsp_diag.so.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef unsigned int  GLenum;
typedef unsigned int  GLuint;
typedef int           GLint;
typedef int           GLsizei;
typedef unsigned char GLboolean;
typedef float         GLfloat;
typedef void          GLvoid;
typedef unsigned int  GLbitfield;

static FILE*         g_out   = NULL;
static int           g_init  = 0;
static int           g_on    = 0;
static unsigned long g_max   = 2000000UL;
static unsigned long g_frame = 0;
static double        g_last  = 0.0;

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}
static double now_cpu_ms(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) != 0) return 0.0;
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

/* every branch speaks - silence must be impossible to reach */
static void st_init(void)
{
    const char* v;
    if (g_init) return;
    g_init = 1;
    v = getenv("TSP_STATE");
    if (!v || !v[0] || v[0] == '0') {
        fprintf(stderr, "TSP_STATECOST disabled (TSP_STATE=%s)\n", v ? v : "(unset)");
        return;
    }
    v = getenv("TSP_STATE_OUT");
    g_out = fopen(v && v[0] ? v : "/mnt/SDCARD/tsp_state.txt", "a");
    if (!g_out) {
        fprintf(stderr, "TSP_STATECOST enabled but fopen failed - staying passive\n");
        return;
    }
    v = getenv("TSP_STATE_MAX");
    if (v && v[0]) { long n = atol(v); if (n > 0) g_max = (unsigned long)n; }
    g_on = 1;
    fprintf(stderr, "TSP_STATECOST v2 active out=%s max=%lu\n",
            getenv("TSP_STATE_OUT") ? getenv("TSP_STATE_OUT") : "/mnt/SDCARD/tsp_state.txt", g_max);
    fprintf(g_out, "# tsp_state v2  frame_us = draw+bind+prog+unif+attr+en+buf+mtx+lite+arr+fix+err+clr+swap+other\n");
    fprintf(g_out, "# other = CPU reaching no intercepted GL call: OSG cull, OSG state apply, engine update\n");
    fflush(g_out);
    g_last = now_ms();
}

static double a_draw, a_bind, a_prog, a_unif, a_attr, a_en, a_buf, a_swap;
static double a_bind_cpu, a_prog_cpu;
static unsigned long n_draw, n_bind, n_prog, n_unif, n_attr, n_en, n_buf;
static double a_mtx, a_lite, a_arr, a_fix, a_err, a_clr;
static unsigned long n_mtx, n_lite, n_arr, n_fix, n_err, n_clr;

#define REAL(name, ret, params) static ret (*real_##name) params = NULL; static void resolve_##name(void) { if (!real_##name) real_##name = (ret (*) params) dlsym(RTLD_NEXT, #name); }

REAL(glDrawArrays,               void, (GLenum,GLint,GLsizei))
REAL(glDrawElements,             void, (GLenum,GLsizei,GLenum,const GLvoid*))
REAL(glBindTexture,              void, (GLenum,GLuint))
REAL(glActiveTexture,            void, (GLenum))
REAL(glUseProgram,               void, (GLuint))
REAL(glEnable,                   void, (GLenum))
REAL(glDisable,                  void, (GLenum))
REAL(glBufferData,               void, (GLenum,long,const GLvoid*,GLenum))
REAL(glBufferSubData,            void, (GLenum,long,long,const GLvoid*))
REAL(glVertexAttribPointer,      void, (GLuint,GLint,GLenum,GLboolean,GLsizei,const void*))
REAL(glEnableVertexAttribArray,  void, (GLuint))
REAL(glDisableVertexAttribArray, void, (GLuint))
REAL(glUniform1i,                void, (GLint,GLint))
REAL(glUniform1f,                void, (GLint,GLfloat))
REAL(glUniform2f,                void, (GLint,GLfloat,GLfloat))
REAL(glUniform3f,                void, (GLint,GLfloat,GLfloat,GLfloat))
REAL(glUniform4f,                void, (GLint,GLfloat,GLfloat,GLfloat,GLfloat))
REAL(glUniform1iv,               void, (GLint,GLsizei,const GLint*))
REAL(glUniform1fv,               void, (GLint,GLsizei,const GLfloat*))
REAL(glUniform2fv,               void, (GLint,GLsizei,const GLfloat*))
REAL(glUniform3fv,               void, (GLint,GLsizei,const GLfloat*))
REAL(glUniform4fv,               void, (GLint,GLsizei,const GLfloat*))
REAL(glUniformMatrix3fv,         void, (GLint,GLsizei,GLboolean,const GLfloat*))
REAL(glUniformMatrix4fv,         void, (GLint,GLsizei,GLboolean,const GLfloat*))
REAL(glMatrixMode,               void, (GLenum))
REAL(glLoadMatrixf,              void, (const GLfloat*))
REAL(glMultMatrixf,              void, (const GLfloat*))
REAL(glPushMatrix,               void, (void))
REAL(glPopMatrix,                void, (void))
REAL(glLoadIdentity,             void, (void))
REAL(glLightfv,                  void, (GLenum,GLenum,const GLfloat*))
REAL(glLightf,                   void, (GLenum,GLenum,GLfloat))
REAL(glLightModelfv,             void, (GLenum,const GLfloat*))
REAL(glLightModeli,              void, (GLenum,GLint))
REAL(glMaterialfv,               void, (GLenum,GLenum,const GLfloat*))
REAL(glMaterialf,                void, (GLenum,GLenum,GLfloat))
REAL(glColorMaterial,            void, (GLenum,GLenum))
REAL(glVertexPointer,            void, (GLint,GLenum,GLsizei,const void*))
REAL(glNormalPointer,            void, (GLenum,GLsizei,const void*))
REAL(glColorPointer,             void, (GLint,GLenum,GLsizei,const void*))
REAL(glTexCoordPointer,          void, (GLint,GLenum,GLsizei,const void*))
REAL(glEnableClientState,        void, (GLenum))
REAL(glDisableClientState,       void, (GLenum))
REAL(glClientActiveTexture,      void, (GLenum))
REAL(glTexEnvf,                  void, (GLenum,GLenum,GLfloat))
REAL(glTexEnvi,                  void, (GLenum,GLenum,GLint))
REAL(glTexEnvfv,                 void, (GLenum,GLenum,const GLfloat*))
REAL(glTexParameteri,            void, (GLenum,GLenum,GLint))
REAL(glTexParameterf,            void, (GLenum,GLenum,GLfloat))
REAL(glAlphaFunc,                void, (GLenum,GLfloat))
REAL(glShadeModel,               void, (GLenum))
REAL(glFogf,                     void, (GLenum,GLfloat))
REAL(glFogfv,                    void, (GLenum,const GLfloat*))
REAL(glFogi,                     void, (GLenum,GLint))
REAL(glColor4f,                  void, (GLfloat,GLfloat,GLfloat,GLfloat))
REAL(glDepthFunc,                void, (GLenum))
REAL(glCullFace,                 void, (GLenum))
REAL(glFrontFace,                void, (GLenum))
REAL(glBlendFunc,                void, (GLenum,GLenum))
REAL(glDepthMask,                void, (GLboolean))
REAL(glColorMask,                void, (GLboolean,GLboolean,GLboolean,GLboolean))
REAL(glScissor,                  void, (GLint,GLint,GLsizei,GLsizei))
REAL(glViewport,                 void, (GLint,GLint,GLsizei,GLsizei))
REAL(glPolygonOffset,            void, (GLfloat,GLfloat))
REAL(glClear,                    void, (GLbitfield))
REAL(glGetError,                 GLenum, (void))
REAL(SDL_GL_SwapWindow,          void, (void*))

/* Single-line defines on purpose: no backslash continuations means the file
   survives any paste channel. */
#define WRAP(fn, proto, args, acc, cnt) void fn proto { double t0 = 0; st_init(); resolve_##fn(); if (g_on) { cnt++; t0 = now_ms(); } if (real_##fn) real_##fn args; if (g_on) acc += (now_ms() - t0) * 1000.0; }
#define WRAPC(fn, proto, args, acc, ccc, cnt) void fn proto { double t0 = 0, c0 = 0; st_init(); resolve_##fn(); if (g_on) { cnt++; t0 = now_ms(); c0 = now_cpu_ms(); } if (real_##fn) real_##fn args; if (g_on) { acc += (now_ms() - t0) * 1000.0; ccc += (now_cpu_ms() - c0) * 1000.0; } }

WRAP (glDrawArrays,   (GLenum m, GLint f, GLsizei c), (m,f,c), a_draw, n_draw)
WRAP (glDrawElements, (GLenum m, GLsizei c, GLenum t, const GLvoid* i), (m,c,t,i), a_draw, n_draw)
WRAPC(glBindTexture,  (GLenum t, GLuint x), (t,x), a_bind, a_bind_cpu, n_bind)
WRAP (glActiveTexture,(GLenum u), (u), a_bind, n_bind)
WRAPC(glUseProgram,   (GLuint p), (p), a_prog, a_prog_cpu, n_prog)
WRAP (glEnable,       (GLenum c), (c), a_en, n_en)
WRAP (glDisable,      (GLenum c), (c), a_en, n_en)
WRAP (glBufferData,   (GLenum t, long s, const GLvoid* d, GLenum u), (t,s,d,u), a_buf, n_buf)
WRAP (glBufferSubData,(GLenum t, long o, long s, const GLvoid* d), (t,o,s,d), a_buf, n_buf)
WRAP (glVertexAttribPointer, (GLuint i, GLint s, GLenum t, GLboolean n, GLsizei st, const void* p), (i,s,t,n,st,p), a_attr, n_attr)
WRAP (glEnableVertexAttribArray,  (GLuint i), (i), a_attr, n_attr)
WRAP (glDisableVertexAttribArray, (GLuint i), (i), a_attr, n_attr)
WRAP (glUniform1i,  (GLint l, GLint a), (l,a), a_unif, n_unif)
WRAP (glUniform1f,  (GLint l, GLfloat a), (l,a), a_unif, n_unif)
WRAP (glUniform2f,  (GLint l, GLfloat a, GLfloat b), (l,a,b), a_unif, n_unif)
WRAP (glUniform3f,  (GLint l, GLfloat a, GLfloat b, GLfloat c), (l,a,b,c), a_unif, n_unif)
WRAP (glUniform4f,  (GLint l, GLfloat a, GLfloat b, GLfloat c, GLfloat d), (l,a,b,c,d), a_unif, n_unif)
WRAP (glUniform1iv, (GLint l, GLsizei n, const GLint* v), (l,n,v), a_unif, n_unif)
WRAP (glUniform1fv, (GLint l, GLsizei n, const GLfloat* v), (l,n,v), a_unif, n_unif)
WRAP (glUniform2fv, (GLint l, GLsizei n, const GLfloat* v), (l,n,v), a_unif, n_unif)
WRAP (glUniform3fv, (GLint l, GLsizei n, const GLfloat* v), (l,n,v), a_unif, n_unif)
WRAP (glUniform4fv, (GLint l, GLsizei n, const GLfloat* v), (l,n,v), a_unif, n_unif)
WRAP (glUniformMatrix3fv, (GLint l, GLsizei n, GLboolean tr, const GLfloat* v), (l,n,tr,v), a_unif, n_unif)
WRAP (glUniformMatrix4fv, (GLint l, GLsizei n, GLboolean tr, const GLfloat* v), (l,n,tr,v), a_unif, n_unif)

WRAP (glMatrixMode,   (GLenum m), (m), a_mtx, n_mtx)
WRAP (glLoadMatrixf,  (const GLfloat* v), (v), a_mtx, n_mtx)
WRAP (glMultMatrixf,  (const GLfloat* v), (v), a_mtx, n_mtx)
WRAP (glPushMatrix,   (void), (), a_mtx, n_mtx)
WRAP (glPopMatrix,    (void), (), a_mtx, n_mtx)
WRAP (glLoadIdentity, (void), (), a_mtx, n_mtx)
WRAP (glLightfv,      (GLenum l, GLenum p, const GLfloat* v), (l,p,v), a_lite, n_lite)
WRAP (glLightf,       (GLenum l, GLenum p, GLfloat v), (l,p,v), a_lite, n_lite)
WRAP (glLightModelfv, (GLenum p, const GLfloat* v), (p,v), a_lite, n_lite)
WRAP (glLightModeli,  (GLenum p, GLint v), (p,v), a_lite, n_lite)
WRAP (glMaterialfv,   (GLenum f, GLenum p, const GLfloat* v), (f,p,v), a_lite, n_lite)
WRAP (glMaterialf,    (GLenum f, GLenum p, GLfloat v), (f,p,v), a_lite, n_lite)
WRAP (glColorMaterial,(GLenum f, GLenum m), (f,m), a_lite, n_lite)
WRAP (glVertexPointer,   (GLint s, GLenum t, GLsizei st, const void* p), (s,t,st,p), a_arr, n_arr)
WRAP (glNormalPointer,   (GLenum t, GLsizei st, const void* p), (t,st,p), a_arr, n_arr)
WRAP (glColorPointer,    (GLint s, GLenum t, GLsizei st, const void* p), (s,t,st,p), a_arr, n_arr)
WRAP (glTexCoordPointer, (GLint s, GLenum t, GLsizei st, const void* p), (s,t,st,p), a_arr, n_arr)
WRAP (glEnableClientState,  (GLenum c), (c), a_arr, n_arr)
WRAP (glDisableClientState, (GLenum c), (c), a_arr, n_arr)
WRAP (glClientActiveTexture,(GLenum u), (u), a_arr, n_arr)
WRAP (glTexEnvf,      (GLenum t, GLenum p, GLfloat v), (t,p,v), a_fix, n_fix)
WRAP (glTexEnvi,      (GLenum t, GLenum p, GLint v), (t,p,v), a_fix, n_fix)
WRAP (glTexEnvfv,     (GLenum t, GLenum p, const GLfloat* v), (t,p,v), a_fix, n_fix)
WRAP (glTexParameteri,(GLenum t, GLenum p, GLint v), (t,p,v), a_fix, n_fix)
WRAP (glTexParameterf,(GLenum t, GLenum p, GLfloat v), (t,p,v), a_fix, n_fix)
WRAP (glAlphaFunc,    (GLenum f, GLfloat r), (f,r), a_fix, n_fix)
WRAP (glShadeModel,   (GLenum m), (m), a_fix, n_fix)
WRAP (glFogf,         (GLenum p, GLfloat v), (p,v), a_fix, n_fix)
WRAP (glFogfv,        (GLenum p, const GLfloat* v), (p,v), a_fix, n_fix)
WRAP (glFogi,         (GLenum p, GLint v), (p,v), a_fix, n_fix)
WRAP (glColor4f,      (GLfloat r, GLfloat g, GLfloat b, GLfloat a), (r,g,b,a), a_fix, n_fix)
WRAP (glDepthFunc,    (GLenum f), (f), a_fix, n_fix)
WRAP (glCullFace,     (GLenum m), (m), a_fix, n_fix)
WRAP (glFrontFace,    (GLenum m), (m), a_fix, n_fix)
WRAP (glBlendFunc,    (GLenum s, GLenum d), (s,d), a_fix, n_fix)
WRAP (glDepthMask,    (GLboolean f), (f), a_fix, n_fix)
WRAP (glColorMask,    (GLboolean r, GLboolean g, GLboolean b, GLboolean a), (r,g,b,a), a_fix, n_fix)
WRAP (glScissor,      (GLint x, GLint y, GLsizei w, GLsizei h), (x,y,w,h), a_fix, n_fix)
WRAP (glViewport,     (GLint x, GLint y, GLsizei w, GLsizei h), (x,y,w,h), a_fix, n_fix)
WRAP (glPolygonOffset,(GLfloat f, GLfloat u), (f,u), a_fix, n_fix)
WRAP (glClear,        (GLbitfield m), (m), a_clr, n_clr)

/* glGetError returns a value, so it cannot use the void WRAP macro. */
GLenum glGetError(void)
{
    double t0 = 0; GLenum r = 0;
    st_init();
    resolve_glGetError();
    if (g_on) { n_err++; t0 = now_ms(); }
    if (real_glGetError) r = real_glGetError();
    if (g_on) a_err += (now_ms() - t0) * 1000.0;
    return r;
}

void SDL_GL_SwapWindow(void* w)
{
    double n, frame_us, sum, other, s0;
    st_init();
    resolve_SDL_GL_SwapWindow();
    if (!g_on) { if (real_SDL_GL_SwapWindow) real_SDL_GL_SwapWindow(w); return; }

    n = now_ms();
    frame_us = (n - g_last) * 1000.0;
    g_last = n;

    sum   = a_draw + a_bind + a_prog + a_unif + a_attr + a_en + a_buf + a_swap
          + a_mtx + a_lite + a_arr + a_fix + a_err + a_clr;
    other = frame_us - sum;

    if (g_frame < g_max) {
        fprintf(g_out,
            "S f=%lu ms=%.2f draw_us=%.0f bind_us=%.0f prog_us=%.0f unif_us=%.0f "
            "attr_us=%.0f en_us=%.0f buf_us=%.0f swap_us=%.0f other_us=%.0f "
            "mtx_us=%.0f lite_us=%.0f arr_us=%.0f fix_us=%.0f err_us=%.0f clr_us=%.0f "
            "draws=%lu binds=%lu progs=%lu unif=%lu attr=%lu en=%lu buf=%lu "
            "mtx=%lu lite=%lu arr=%lu fix=%lu err=%lu clr=%lu "
            "bind_cpu_us=%.0f prog_cpu_us=%.0f\n",
            g_frame, frame_us / 1000.0,
            a_draw, a_bind, a_prog, a_unif, a_attr, a_en, a_buf, a_swap, other,
            a_mtx, a_lite, a_arr, a_fix, a_err, a_clr,
            n_draw, n_bind, n_prog, n_unif, n_attr, n_en, n_buf,
            n_mtx, n_lite, n_arr, n_fix, n_err, n_clr,
            a_bind_cpu, a_prog_cpu);
        if ((g_frame & 0x3f) == 0) fflush(g_out);
    }

    g_frame++;
    a_draw = a_bind = a_prog = a_unif = a_attr = a_en = a_buf = 0;
    a_bind_cpu = a_prog_cpu = 0;
    a_mtx = a_lite = a_arr = a_fix = a_err = a_clr = 0;
    n_draw = n_bind = n_prog = n_unif = n_attr = n_en = n_buf = 0;
    n_mtx = n_lite = n_arr = n_fix = n_err = n_clr = 0;

    s0 = now_ms();
    if (real_SDL_GL_SwapWindow) real_SDL_GL_SwapWindow(w);
    a_swap = (now_ms() - s0) * 1000.0;
}
