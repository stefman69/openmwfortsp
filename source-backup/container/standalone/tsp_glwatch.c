/*
 * tsp_glwatch.c  -  GL watchdog + render-target format fix
 *                   OpenMW / gl4es on TrimUI Smart Pro (Mali-G57, GLES2)
 *
 * ===========================================================================
 * THE BUG
 * ===========================================================================
 *
 * Distant terrain rendered black with rainbow speckle. Watchdog capture showed
 * 2300+ of 2400 framebuffer completeness checks returning 0x8CD7
 * (GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT).
 *
 * The cause is in how the composite-map render targets are allocated:
 *
 *     TEXIMAGE target=GL_TEXTURE_2D level=0 ifmt=0x1907 w=256 h=256
 *              fmt=0x1907 type=0x1401 hasdata=0
 *     ATTACHTEX att=GL_COLOR_ATTACHMENT0 tex=49
 *     FBSTATUS  ret=0x8CD7        <- incomplete
 *
 * 0x1907 is GL_RGB. In OpenGL ES 2.0, unsized GL_RGB is NOT a colour-renderable
 * format. The renderable set is GL_RGBA4, GL_RGB5_A1, GL_RGB565, plus GL_RGB8
 * and GL_RGBA8 when OES_rgb8_rgba8 is present. Desktop GL happily renders to
 * GL_RGB, so OpenMW requests it; gl4es forwards it unchanged; the Mali driver
 * refuses it as an attachment and the FBO is permanently incomplete.
 *
 * An incomplete FBO renders nothing, so every terrain composite map stays
 * empty - black, with whatever uninitialised memory shows through as speckle.
 *
 * 85 of 131 texture allocations in the capture were exactly this pattern:
 * 256x256, ifmt=GL_RGB, hasdata=0 (allocated empty, i.e. a render target).
 *
 * ===========================================================================
 * THE FIX
 * ===========================================================================
 *
 * Promote GL_RGB -> GL_RGBA for texture allocations with NULL data. Empty
 * allocation is the render-target signature; textures carrying pixel data are
 * left completely alone, so ordinary game textures are unaffected.
 *
 * GL_RGBA/GL_UNSIGNED_BYTE is colour-renderable on every GLES2 implementation,
 * so the attachment becomes valid and the FBO completes.
 *
 * Set LIBGL_TSP_RGB8=1 to use sized GL_RGB8 instead (valid here because the
 * Mali-G57 advertises GL_OES_rgb8_rgba8) - saves the alpha channel's memory
 * bandwidth if GL_RGBA proves costly.
 *
 * ===========================================================================
 * WHY A SEPARATE LIBRARY
 * ===========================================================================
 *
 * This sits in LD_PRELOAD ahead of libGL.so.1, intercepts calls, and forwards
 * to real gl4es via dlsym(RTLD_NEXT, ...). gl4es source is never touched and
 * libGL.so.1 is never rebuilt. If anything misbehaves, drop it from LD_PRELOAD
 * and the game is back to normal immediately.
 *
 * ===========================================================================
 * ENV VARS
 * ===========================================================================
 *
 *   LIBGL_TSP_NORGBFIX=1         disable the GL_RGB -> GL_RGBA promotion
 *   LIBGL_TSP_RGB8=1             promote to sized GL_RGB8 instead of GL_RGBA
 *   LIBGL_TSP_FBFIX=1            also collapse GL_DRAW/READ_FRAMEBUFFER onto
 *                                GL_FRAMEBUFFER (tested: did NOT fix the bug,
 *                                off by default, kept for experimentation)
 *
 *   LIBGL_TSP_WATCH=<path>       enable logging; unset = no logging, no file
 *   LIBGL_TSP_WATCH_MAX=<n>      line cap, default 40000
 *   LIBGL_TSP_WATCH_FBONLY=1     only log while a non-default FBO is bound
 *
 * For normal play: leave the library in LD_PRELOAD, leave LIBGL_TSP_WATCH
 * unset. The fix applies, nothing is logged, no file is opened.
 *
 * ===========================================================================
 * BUILD (inside the aarch64 container)
 * ===========================================================================
 *
 *   gcc -shared -fPIC -O2 -o libtsp_glwatch.so tsp_glwatch.c -ldl
 *
 * DEPLOY: copy next to libGL.so.1 and place FIRST in LD_PRELOAD:
 *   LD_PRELOAD="$GAMEDIR/lib/libtsp_glwatch.so:$GAMEDIR/lib/libtsp_fullscreen_scaler.so:$TSP_GL4ES_LIBRARY"
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

typedef unsigned int   GLenum;
typedef unsigned int   GLuint;
typedef int            GLint;
typedef int            GLsizei;
typedef unsigned int   GLbitfield;
typedef float          GLfloat;
typedef void           GLvoid;

#define TSP_GL_FRAMEBUFFER        0x8D40
#define TSP_GL_READ_FRAMEBUFFER   0x8CA8
#define TSP_GL_DRAW_FRAMEBUFFER   0x8CA9
#define TSP_GL_FB_COMPLETE        0x8CD5

#define TSP_GL_RGB                0x1907
#define TSP_GL_RGBA               0x1908
#define TSP_GL_RGB8               0x8051
#define TSP_GL_UNSIGNED_BYTE      0x1401
#define TSP_GL_TEXTURE_2D         0x0DE1

/* ------------------------------------------------------------------ */
/* logging                                                             */
/* ------------------------------------------------------------------ */

static FILE*         g_log     = NULL;
static int           g_checked = 0;
static unsigned long g_lines   = 0;
static unsigned long g_max     = 40000;
static int           g_fbonly  = 0;
static GLuint        g_cur_fb  = 0;   /* our own tracked framebuffer binding */

static void tsp_open(void)
{
    const char* path;
    const char* mx;

    if (g_checked) return;
    g_checked = 1;

    path = getenv("LIBGL_TSP_WATCH");
    if (!path || !path[0]) return;

    mx = getenv("LIBGL_TSP_WATCH_MAX");
    if (mx && mx[0]) {
        long v = atol(mx);
        if (v > 0) g_max = (unsigned long)v;
    }

    if (getenv("LIBGL_TSP_WATCH_FBONLY")) g_fbonly = 1;

    g_log = fopen(path, "w");
    if (g_log) {
        fprintf(g_log,
                "# tsp_glwatch BUILD=v7-fallback  max=%lu fbonly=%d rgbfix=%s rgb8=%s fbfix=%s\n",
                g_max, g_fbonly,
                getenv("LIBGL_TSP_NORGBFIX") ? "OFF" : "ON",
                getenv("LIBGL_TSP_RGB8")     ? "ON"  : "OFF",
                getenv("LIBGL_TSP_NOFBFIX")  ? "OFF" : "ON");
        fflush(g_log);
    }
}

static void tsp_log(const char* fmt, ...)
{
    va_list ap;

    tsp_open();
    if (!g_log) return;
    if (g_lines >= g_max) return;
    if (g_fbonly && g_cur_fb == 0) return;

    fprintf(g_log, "%lu fb=%u ", g_lines++, g_cur_fb);
    va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    va_end(ap);
    fputc('\n', g_log);

    if ((g_lines & 0x3f) == 0) fflush(g_log);
}

/* ------------------------------------------------------------------ */
/* THE FIX - GL_RGB is not colour-renderable on GLES2                  */
/* ------------------------------------------------------------------ */

static int tsp_rgbfix_on(void)
{
    static int chk = 0, on = 1;
    if (!chk) { chk = 1; if (getenv("LIBGL_TSP_NORGBFIX")) on = 0; }
    return on;
}

static int tsp_use_rgb8(void)
{
    static int chk = 0, on = 0;
    if (!chk) { chk = 1; if (getenv("LIBGL_TSP_RGB8")) on = 1; }
    return on;
}

/* Optional, off by default: collapse read/draw framebuffer targets.
   Tested against this bug and did NOT fix it; retained for experiments. */
static int tsp_fbfix_on(void)
{
    static int chk = 0, on = 1;
    if (!chk) { chk = 1; if (getenv("LIBGL_TSP_NOFBFIX")) on = 0; }
    return on;
}

static GLenum tsp_fbtarget(GLenum t)
{
    if (tsp_fbfix_on() &&
        (t == TSP_GL_DRAW_FRAMEBUFFER || t == TSP_GL_READ_FRAMEBUFFER))
        return TSP_GL_FRAMEBUFFER;
    return t;
}

/* gl4es reports MISSING_ATTACHMENT for FBOs whose attachment we can see
   being made against a valid texture. If its completeness tracking is stale,
   OpenMW skips the render entirely -> black terrain. This lets the render
   proceed. LIBGL_TSP_FORCECOMPLETE=1 enables. */
static int tsp_forcecomplete_on(void)
{
    static int chk = 0, on = 0;
    if (!chk) { chk = 1; if (getenv("LIBGL_TSP_FORCECOMPLETE")) on = 1; }
    return on;
}

/* ------------------------------------------------------------------ */
/* real function resolution                                            */
/* ------------------------------------------------------------------ */

#define REAL(name, rettype, params)                                        \
    static rettype (*real_##name) params = NULL;                           \
    static void resolve_##name(void) {                                     \
        if (!real_##name)                                                  \
            real_##name = (rettype (*) params) dlsym(RTLD_NEXT, #name);    \
    }

REAL(glBindFramebuffer,          void,   (GLenum, GLuint))
REAL(glCheckFramebufferStatus,   GLenum, (GLenum))
REAL(glFramebufferTexture2D,     void,   (GLenum, GLenum, GLenum, GLuint, GLint))
REAL(glFramebufferRenderbuffer,  void,   (GLenum, GLenum, GLenum, GLuint))
REAL(glViewport,                 void,   (GLint, GLint, GLsizei, GLsizei))
REAL(glScissor,                  void,   (GLint, GLint, GLsizei, GLsizei))
REAL(glClear,                    void,   (GLbitfield))
REAL(glClearColor,               void,   (GLfloat, GLfloat, GLfloat, GLfloat))
REAL(glDrawArrays,               void,   (GLenum, GLint, GLsizei))
REAL(glDrawElements,             void,   (GLenum, GLsizei, GLenum, const GLvoid*))
REAL(glTexImage2D,               void,   (GLenum, GLint, GLint, GLsizei, GLsizei,
                                          GLint, GLenum, GLenum, const GLvoid*))
REAL(glGetError,                 GLenum, (void))
REAL(glBindTexture,              void,   (GLenum, GLuint))
REAL(glGenRenderbuffers,         void,   (GLsizei, GLuint*))
REAL(glBindRenderbuffer,         void,   (GLenum, GLuint))
REAL(glRenderbufferStorage,      void,   (GLenum, GLenum, GLsizei, GLsizei))
REAL(glDepthMask,                void,   (unsigned char))
REAL(glDisable,                  void,   (GLenum))
REAL(glEnable,                   void,   (GLenum))
REAL(glGenerateMipmap,           void,   (GLenum))
REAL(glTexParameteri,            void,   (GLenum, GLenum, GLint))
REAL(glReadPixels,               void,   (GLint, GLint, GLsizei, GLsizei,
                                          GLenum, GLenum, GLvoid*))
REAL(glGetIntegerv,              void,   (GLenum, GLint*))
REAL(glFinish,                   void,   (void))
REAL(glFlush,                    void,   (void))
REAL(glCopyTexSubImage2D,        void,   (GLenum, GLint, GLint, GLint,
                                          GLint, GLint, GLsizei, GLsizei))
REAL(glTexSubImage2D,            void,   (GLenum, GLint, GLint, GLint,
                                          GLsizei, GLsizei, GLenum, GLenum,
                                          const GLvoid*))

/* ------------------------------------------------------------------ */
/* colour-only FBOs are incomplete on this driver - supply depth       */
/* ------------------------------------------------------------------ */

#define TSP_GL_RENDERBUFFER       0x8D41
#define TSP_GL_DEPTH_ATTACHMENT   0x8D00
#define TSP_GL_COLOR_ATTACHMENT0  0x8CE0
#define TSP_GL_DEPTH_COMPONENT16  0x81A5

#define TSP_MAXTEX 4096
static GLsizei g_texw[TSP_MAXTEX];
static GLsizei g_texh[TSP_MAXTEX];
static GLuint  g_bound_tex = 0;
static GLuint  g_fb_color_tex = 0;   /* colour texture of the bound FBO */
static int     g_fb_draws     = 0;   /* draws issued since this attach */
static int     g_fb_ok        = 0;   /* framebuffer reported complete */
static unsigned char* g_good  = NULL;/* last known-good composite content */
static GLsizei g_good_w = 0, g_good_h = 0;

/* one depth renderbuffer per (fb,size) - small cache */
#define TSP_MAXDEPTH 64
static struct { GLuint fb; GLsizei w, h, rb; } g_depth[TSP_MAXDEPTH];
static int g_ndepth = 0;

static int tsp_depthfix_on(void)
{
    static int chk = 0, on = 1;
    if (!chk) { chk = 1; if (getenv("LIBGL_TSP_NODEPTHFIX")) on = 0; }
    return on;
}

static GLuint tsp_get_depth_rb(GLuint fb, GLsizei w, GLsizei h)
{
    int i;
    GLuint rb = 0;
    for (i = 0; i < g_ndepth; i++)
        if (g_depth[i].fb == fb && g_depth[i].w == w && g_depth[i].h == h)
            return g_depth[i].rb;
    if (g_ndepth >= TSP_MAXDEPTH) return 0;

    resolve_glGenRenderbuffers();
    resolve_glBindRenderbuffer();
    resolve_glRenderbufferStorage();
    if (!real_glGenRenderbuffers || !real_glBindRenderbuffer
        || !real_glRenderbufferStorage) return 0;

    real_glGenRenderbuffers(1, &rb);
    if (!rb) return 0;
    real_glBindRenderbuffer(TSP_GL_RENDERBUFFER, rb);
    real_glRenderbufferStorage(TSP_GL_RENDERBUFFER, TSP_GL_DEPTH_COMPONENT16, w, h);
    real_glBindRenderbuffer(TSP_GL_RENDERBUFFER, 0);

    g_depth[g_ndepth].fb = fb;
    g_depth[g_ndepth].w  = w;
    g_depth[g_ndepth].h  = h;
    g_depth[g_ndepth].rb = rb;
    g_ndepth++;
    tsp_log("DEPTHFIX created rb=%u for fb=%u %dx%d", rb, fb, w, h);
    return rb;
}

/* Did we add a depth renderbuffer to this framebuffer? */
static int tsp_fb_has_our_depth(GLuint fb)
{
    int i;
    for (i = 0; i < g_ndepth; i++)
        if (g_depth[i].fb == fb) return 1;
    return 0;
}

void glBindTexture(GLenum target, GLuint tex)
{
    resolve_glBindTexture();
    if (target == TSP_GL_TEXTURE_2D) g_bound_tex = tex;
    if (real_glBindTexture) real_glBindTexture(target, tex);
}

/* ------------------------------------------------------------------ */
/* the hook that matters                                               */
/* ------------------------------------------------------------------ */

void glTexImage2D(GLenum target, GLint level, GLint ifmt,
                  GLsizei w, GLsizei h, GLint border,
                  GLenum fmt, GLenum type, const GLvoid* data)
{
    GLint  new_ifmt = ifmt;
    GLenum new_fmt  = fmt;
    int    promoted = 0;

    resolve_glTexImage2D();

    /* Empty allocation (data == NULL) with GL_RGB is a render target that
       GLES2 cannot render to. Promote it to something renderable.
       Textures carrying pixel data are left untouched. */
    if (tsp_rgbfix_on()
        && data == NULL
        && target == TSP_GL_TEXTURE_2D
        && level == 0
        && ifmt == (GLint)TSP_GL_RGB
        && type == TSP_GL_UNSIGNED_BYTE) {

        if (tsp_use_rgb8()) {
            new_ifmt = TSP_GL_RGB8;     /* sized, needs OES_rgb8_rgba8 */
            new_fmt  = TSP_GL_RGB;      /* format stays unsized for sized ifmt */
        } else {
            new_ifmt = TSP_GL_RGBA;
            new_fmt  = TSP_GL_RGBA;
        }
        promoted = 1;
    }

    tsp_log("TEXIMAGE target=0x%x level=%d ifmt=0x%x%s w=%d h=%d fmt=0x%x type=0x%x hasdata=%d",
            target, level, ifmt,
            promoted ? (tsp_use_rgb8() ? "->RGB8" : "->RGBA") : "",
            w, h, fmt, type, data ? 1 : 0);

    if (target == TSP_GL_TEXTURE_2D && level == 0
        && g_bound_tex < TSP_MAXTEX) {
        g_texw[g_bound_tex] = w;
        g_texh[g_bound_tex] = h;
    }

    if (real_glTexImage2D)
        real_glTexImage2D(target, level, new_ifmt, w, h, border,
                          new_fmt, type, data);
}

/* ------------------------------------------------------------------ */
/* framebuffer hooks                                                   */
/* ------------------------------------------------------------------ */

void glBindFramebuffer(GLenum target, GLuint fb)
{
    GLenum t;
    resolve_glBindFramebuffer();

    /* Leaving a render-to-texture FBO: the texture has only level 0. If its
       min filter expects mipmaps it is an INCOMPLETE texture and samples as
       black. Force a linear min filter and generate mips so it is valid
       either way. LIBGL_TSP_NOMIPFIX=1 disables. */
    /* DEFINITIVE CHECK: read pixels straight out of the composite target
       while it is still bound. If these come back black the render produced
       nothing; if they carry terrain colour the render worked and the fault
       is in how the texture is later sampled. Capped so it costs nothing
       after the first few. Enable with LIBGL_TSP_READBACK=1. */
    /* FALLBACK SUBSTITUTION.
       Some composite maps render correctly and some come out empty. Rather
       than leaving the failures black, capture the content of a composite
       that worked and copy it into ones that did not. Distant terrain is
       low-detail and fogged, so approximate-but-present beats black.
       LIBGL_TSP_NOFALLBACK=1 disables. */
    if (g_cur_fb != 0 && fb != g_cur_fb && g_fb_color_tex != 0
        && !getenv("LIBGL_TSP_NOFALLBACK")
        && g_fb_color_tex < TSP_MAXTEX) {
        GLsizei w = g_texw[g_fb_color_tex];
        GLsizei h = g_texh[g_fb_color_tex];
        int good = (g_fb_ok && g_fb_draws > 0);

        resolve_glReadPixels();
        resolve_glBindTexture();
        resolve_glTexSubImage2D();

        if (good && w > 0 && h > 0 && real_glReadPixels) {
            /* remember this one as the reference */
            size_t need = (size_t)w * (size_t)h * 4;
            if (!g_good || g_good_w != w || g_good_h != h) {
                free(g_good);
                g_good = (unsigned char*)malloc(need);
                g_good_w = w; g_good_h = h;
            }
            if (g_good) {
                real_glReadPixels(0, 0, w, h, TSP_GL_RGBA,
                                  TSP_GL_UNSIGNED_BYTE, g_good);
                tsp_log("FALLBACK captured reference from tex=%u %dx%d",
                        g_fb_color_tex, w, h);
            }
        } else if (!good && g_good && w == g_good_w && h == g_good_h
                   && real_glBindTexture && real_glTexSubImage2D) {
            GLuint prev = g_bound_tex;
            real_glBindTexture(TSP_GL_TEXTURE_2D, g_fb_color_tex);
            real_glTexSubImage2D(TSP_GL_TEXTURE_2D, 0, 0, 0, w, h,
                                 TSP_GL_RGBA, TSP_GL_UNSIGNED_BYTE, g_good);
            real_glBindTexture(TSP_GL_TEXTURE_2D, prev);
            tsp_log("FALLBACK substituted into tex=%u (draws=%d ok=%d)",
                    g_fb_color_tex, g_fb_draws, g_fb_ok);
        }
    }

    /* TILE-BUFFER RESOLVE.
       The Mali-G57 is a tile-based deferred renderer: drawing into an FBO
       accumulates in tile memory and is only resolved to the texture when the
       render pass ends. Normally the driver tracks "rendered to X, now
       sampling X" automatically - but gl4es rebinds framebuffers behind the
       driver's back via its read/draw emulation, which loses that dependency.
       The texture is then sampled before the resolve and reads empty: black
       terrain. The glReadPixels INVALID_OPERATION is the same cause.
       Force the resolve when leaving a render-to-texture FBO.
         LIBGL_TSP_FBFLUSH=finish  (default) glFinish - strongest
         LIBGL_TSP_FBFLUSH=flush             glFlush  - cheaper
         LIBGL_TSP_FBFLUSH=off               disable */
    if (g_cur_fb != 0 && fb != g_cur_fb && g_fb_color_tex != 0) {
        static int chk = 0, mode = 2;   /* 0 off, 1 flush, 2 finish */
        if (!chk) {
            const char* e = getenv("LIBGL_TSP_FBFLUSH");
            chk = 1;
            if (e && e[0]) {
                if (e[0] == 'o') mode = 0;
                else if (e[0] == 'f' && e[1] == 'l') mode = 1;
                else mode = 2;
            }
        }
        if (mode == 2) { resolve_glFinish(); if (real_glFinish) real_glFinish(); }
        else if (mode == 1) { resolve_glFlush(); if (real_glFlush) real_glFlush(); }
    }

    /* DEFINITIVE CHECK, done correctly this time.
       GLES2 only guarantees glReadPixels for GL_RGBA/GL_UNSIGNED_BYTE on the
       *default* framebuffer. For an FBO you must query
       GL_IMPLEMENTATION_COLOR_READ_FORMAT / _TYPE and use those. The previous
       attempt assumed RGBA and the buffer came back untouched, which said
       nothing about the framebuffer contents.
       Errors are drained before and checked after, so "read failed" and
       "genuinely black" are distinguishable. LIBGL_TSP_READBACK=1 enables. */
    if (g_cur_fb != 0 && fb != g_cur_fb && g_fb_color_tex != 0
        && getenv("LIBGL_TSP_READBACK")) {
        static int rb_count = 0;
        if (rb_count < 40) {
            unsigned char px[32];
            int i;
            GLint rfmt = 0, rtype = 0;
            GLenum e0, e1;
            GLsizei w = (g_fb_color_tex < TSP_MAXTEX) ? g_texw[g_fb_color_tex] : 0;
            GLsizei h = (g_fb_color_tex < TSP_MAXTEX) ? g_texh[g_fb_color_tex] : 0;

            resolve_glReadPixels();
            resolve_glGetIntegerv();
            resolve_glGetError();

            if (real_glReadPixels && real_glGetIntegerv && w > 4 && h > 4) {
                /* drain any pending error so ours is attributable */
                if (real_glGetError) { int g; for (g = 0; g < 8; g++) if (!real_glGetError()) break; }

                real_glGetIntegerv(0x8B9B, &rfmt);   /* IMPLEMENTATION_COLOR_READ_FORMAT */
                real_glGetIntegerv(0x8B9A, &rtype);  /* IMPLEMENTATION_COLOR_READ_TYPE   */
                e0 = real_glGetError ? real_glGetError() : 0;

                for (i = 0; i < 32; i++) px[i] = 0xAB;   /* poison */

                if (rfmt == 0 || rtype == 0) { rfmt = TSP_GL_RGBA; rtype = TSP_GL_UNSIGNED_BYTE; }
                real_glReadPixels(w/2, h/2, 2, 2, (GLenum)rfmt, (GLenum)rtype, px);
                e1 = real_glGetError ? real_glGetError() : 0;

                tsp_log("READBACK2 tex=%u %dx%d rfmt=0x%x rtype=0x%x errq=0x%x errread=0x%x px= %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x",
                        g_fb_color_tex, w, h, (unsigned)rfmt, (unsigned)rtype,
                        (unsigned)e0, (unsigned)e1,
                        px[0],px[1],px[2],px[3],
                        px[4],px[5],px[6],px[7],
                        px[8],px[9],px[10],px[11]);
                rb_count++;
            } else {
                tsp_log("READBACK2 unavailable (readpixels=%d getint=%d w=%d h=%d)",
                        real_glReadPixels ? 1 : 0, real_glGetIntegerv ? 1 : 0, w, h);
                rb_count++;
            }
        }
    }

    if (g_cur_fb != 0 && fb != g_cur_fb && g_fb_color_tex != 0
        && !getenv("LIBGL_TSP_NOMIPFIX")) {
        GLuint prev = g_bound_tex;
        resolve_glBindTexture();
        resolve_glTexParameteri();
        resolve_glGenerateMipmap();
        if (real_glBindTexture && real_glTexParameteri) {
            real_glBindTexture(TSP_GL_TEXTURE_2D, g_fb_color_tex);
            real_glTexParameteri(TSP_GL_TEXTURE_2D, 0x2801, 0x2601); /* MIN_FILTER=LINEAR */
            real_glTexParameteri(TSP_GL_TEXTURE_2D, 0x2800, 0x2601); /* MAG_FILTER=LINEAR */
            if (real_glGenerateMipmap) real_glGenerateMipmap(TSP_GL_TEXTURE_2D);
            tsp_log("MIPFIX tex=%u made sampleable", g_fb_color_tex);
            real_glBindTexture(TSP_GL_TEXTURE_2D, prev);
        }
        g_fb_color_tex = 0;
    }

    g_cur_fb = fb;
    t = tsp_fbtarget(target);
    tsp_log("BINDFB target=0x%x%s fb=%u",
            target, (t != target) ? "->0x8D40" : "", fb);
    if (real_glBindFramebuffer) real_glBindFramebuffer(t, fb);
}

GLenum glCheckFramebufferStatus(GLenum target)
{
    GLenum rv = TSP_GL_FB_COMPLETE;
    GLenum t;
    resolve_glCheckFramebufferStatus();
    t = tsp_fbtarget(target);
    if (real_glCheckFramebufferStatus) rv = real_glCheckFramebufferStatus(t);

    g_fb_ok = (rv == TSP_GL_FB_COMPLETE);

    if (rv != TSP_GL_FB_COMPLETE && g_cur_fb != 0 && tsp_forcecomplete_on()) {
        tsp_log("FBSTATUS target=0x%x%s ret=0x%x FORCED->0x8CD5",
                target, (t != target) ? "->0x8D40" : "", rv);
        return TSP_GL_FB_COMPLETE;
    }

    tsp_log("FBSTATUS target=0x%x%s ret=0x%x%s",
            target, (t != target) ? "->0x8D40" : "", rv,
            (rv == TSP_GL_FB_COMPLETE) ? "" : "   <<<< NOT COMPLETE");
    return rv;
}

void glFramebufferTexture2D(GLenum target, GLenum att, GLenum textarget,
                            GLuint tex, GLint level)
{
    GLenum t;
    resolve_glFramebufferTexture2D();
    t = tsp_fbtarget(target);
    tsp_log("ATTACHTEX target=0x%x%s att=0x%x tex=%u level=%d",
            target, (t != target) ? "->0x8D40" : "", att, tex, level);
    if (real_glFramebufferTexture2D)
        real_glFramebufferTexture2D(t, att, textarget, tex, level);

    /* Colour-only framebuffers report MISSING_ATTACHMENT on this driver.
       Every FBO that works in the trace has depth attached; every failing
       one is colour-only. Supply a matching depth renderbuffer. */
    if (tsp_depthfix_on()
        && att == TSP_GL_COLOR_ATTACHMENT0
        && g_cur_fb != 0
        && tex != 0
        && tex < TSP_MAXTEX
        && g_texw[tex] > 0) {
        g_fb_color_tex = tex;
        g_fb_draws = 0;
        g_fb_ok = 0;
        GLuint rb = tsp_get_depth_rb(g_cur_fb, g_texw[tex], g_texh[tex]);
        if (rb) {
            resolve_glFramebufferRenderbuffer();
            if (real_glFramebufferRenderbuffer)
                real_glFramebufferRenderbuffer(TSP_GL_FRAMEBUFFER,
                                               TSP_GL_DEPTH_ATTACHMENT,
                                               TSP_GL_RENDERBUFFER, rb);

            /* OpenMW never calls glClear on the composite-map FBO - it
               renders opaque terrain that covers the whole target, so on
               desktop GL there is nothing to clear. Our injected depth
               buffer therefore holds garbage and the depth test discards
               every fragment. Clear it here, at attach time.
               Scissor is disabled and the depth mask forced on so the
               clear cannot be suppressed by inherited state. */
            resolve_glClear();
            resolve_glDepthMask();
            resolve_glDisable();
            resolve_glEnable();
            if (real_glClear) {
                /* The colour target is never cleared either - OpenMW assumes
                   the base terrain layer covers it, but a freshly allocated
                   texture has undefined contents (and undefined alpha, now
                   that we promote to RGBA). Clear colour to opaque black as
                   well so uncovered texels are defined rather than garbage.
                   LIBGL_TSP_NOCOLORCLEAR=1 disables just the colour part. */
                GLbitfield bits = 0x00000100;                   /* DEPTH */
                if (!getenv("LIBGL_TSP_NOCOLORCLEAR")) {
                    resolve_glClearColor();
                    if (real_glClearColor) real_glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
                    bits |= 0x00004000;                         /* COLOR */
                }
                if (real_glDisable)   real_glDisable(0x0C11);   /* SCISSOR_TEST */
                if (real_glDepthMask) real_glDepthMask(1);
                real_glClear(bits);
                if (real_glEnable)    real_glEnable(0x0C11);
                tsp_log("DEPTHFIX cleared bits=0x%x for fb=%u", bits, g_cur_fb);
            }
        }
    }
}

void glFramebufferRenderbuffer(GLenum target, GLenum att,
                               GLenum rbtarget, GLuint rb)
{
    GLenum t;
    resolve_glFramebufferRenderbuffer();
    t = tsp_fbtarget(target);
    tsp_log("ATTACHRB target=0x%x%s att=0x%x rb=%u",
            target, (t != target) ? "->0x8D40" : "", att, rb);
    if (real_glFramebufferRenderbuffer)
        real_glFramebufferRenderbuffer(t, att, rbtarget, rb);
}

/* ------------------------------------------------------------------ */
/* observation only                                                    */
/* ------------------------------------------------------------------ */

void glViewport(GLint x, GLint y, GLsizei w, GLsizei h)
{
    resolve_glViewport();
    tsp_log("VIEWPORT x=%d y=%d w=%d h=%d", x, y, w, h);
    if (real_glViewport) real_glViewport(x, y, w, h);
}

void glScissor(GLint x, GLint y, GLsizei w, GLsizei h)
{
    resolve_glScissor();
    tsp_log("SCISSOR x=%d y=%d w=%d h=%d", x, y, w, h);
    if (real_glScissor) real_glScissor(x, y, w, h);
}

void glClear(GLbitfield mask)
{
    GLbitfield m = mask;
    resolve_glClear();

    /* We attached a depth renderbuffer that OpenMW does not know about, so
       its clear only covers colour. An uncleared depth buffer contains
       garbage and the depth test then rejects almost every fragment - the
       terrain draws and is immediately discarded. Clear depth too. */
    if (tsp_depthfix_on() && g_cur_fb != 0
        && !(mask & 0x00000100) && tsp_fb_has_our_depth(g_cur_fb)) {
        m |= 0x00000100;   /* GL_DEPTH_BUFFER_BIT */
        tsp_log("CLEAR mask=0x%x +DEPTH", mask);
    } else {
        tsp_log("CLEAR mask=0x%x", mask);
    }

    if (real_glClear) real_glClear(m);
}

void glClearColor(GLfloat r, GLfloat g, GLfloat b, GLfloat a)
{
    resolve_glClearColor();
    tsp_log("CLEARCOL %.3f %.3f %.3f %.3f", r, g, b, a);
    if (real_glClearColor) real_glClearColor(r, g, b, a);
}

void glDrawArrays(GLenum mode, GLint first, GLsizei count)
{
    resolve_glDrawArrays();
    tsp_log("DRAWARR mode=0x%x first=%d count=%d", mode, first, count);
    if (real_glDrawArrays) real_glDrawArrays(mode, first, count);
}

void glDrawElements(GLenum mode, GLsizei count, GLenum type, const GLvoid* idx)
{
    resolve_glDrawElements();
    tsp_log("DRAWELE mode=0x%x count=%d type=0x%x", mode, count, type);
    if (real_glDrawElements) real_glDrawElements(mode, count, type, idx);
}

GLenum glGetError(void)
{
    GLenum rv = 0;
    resolve_glGetError();
    if (real_glGetError) rv = real_glGetError();
    if (rv != 0) tsp_log("ERR ret=0x%x   <<<< GL ERROR", rv);
    return rv;
}
