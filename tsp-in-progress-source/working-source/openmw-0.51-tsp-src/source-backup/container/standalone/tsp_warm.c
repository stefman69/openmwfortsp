/*
 * tsp_warm.c  -  GL interventions for the OpenMW TrimUI port
 *
 * ===========================================================================
 * THIS LIBRARY CHANGES BEHAVIOUR. IT IS NOT A DIAGNOSTIC.
 * ===========================================================================
 *
 * Everything here injects calls, replaces calls, or draws geometry the engine
 * never asked for. It logs only enough to say whether its own intervention
 * did anything. If you are trying to find out what is wrong, this is the
 * wrong library - use libtsp_diag.so, which now touches nothing.
 *
 * All of this used to live inside libtsp_diag.so, which meant you could not
 * take a measurement without also running four fixes. That is what this split
 * exists to end.
 *
 * MODE NUMBERS ARE UNCHANGED from the pre-split library, so existing notes
 * still read correctly. Only the variable moved: LIBGL_TSP_DIAG -> LIBGL_TSP_WARM.
 *
 * ===========================================================================
 * WHAT EACH MODE DOES
 * ===========================================================================
 *
 *  512  PREWARM     Walks the fixed-function state space once at startup so
 *                   gl4es generates its shaders during the loading screen
 *                   rather than on the first swing at a creature. Covers the
 *                   cost; does not remove it.
 *
 * 1024  SCACHE      Persists each linked program binary to disk, keyed by an
 *                   FNV-1a hash of the concatenated shader source. A hit
 *                   skips the Mali compiler entirely. Includes SCWARM2, which
 *                   forces the driver's deferred per-program work at a frame
 *                   boundary instead of inside the first real draw.
 *
 * 2048  SCPRELOAD   Loads every cached binary into a throwaway program at the
 *                   loading screen and warms it. This is an EXPERIMENT, not a
 *                   fix: it tests whether Mali keys compiled state to the
 *                   binary content or to the program object. If by content,
 *                   OpenMW's later restore of the same bytes is cheap and the
 *                   stall is gone. If by object, the stalls remain and the
 *                   wrapper approach is exhausted. Either answer is worth
 *                   having; only one of them helps.
 *
 * Plus one knob that is not a mode:
 *
 *  LIBGL_TSP_ORPHAN=1   Before a glBufferSubData at offset 0, call
 *                       glBufferData(NULL) so the driver hands back fresh
 *                       storage instead of stalling until the GPU finishes
 *                       reading the old contents. OSG particle systems
 *                       rewrite their whole vertex buffer every frame, which
 *                       is the case this targets. This lived in
 *                       libtsp_diag.so's glBufferSubData, which is exactly
 *                       the sort of thing a measuring tool should never do.
 *
 * ===========================================================================
 * THE MEASUREMENT ALL OF THIS RESTS ON
 * ===========================================================================
 *
 *   LINK prog=7   137349us
 *   f=755 ... worst_us=236497 worst_cpu_us=236615 worst_prog=7
 *   LINK prog=51  140536us
 *   f=987 ... worst_us=238829 worst_cpu_us=238823 worst_prog=51
 *
 * worst_cpu_us == worst_us, so the thread is burning CPU, not blocked on the
 * GPU or a fence. Mali charges ~137ms inside glLinkProgram and defers a
 * further ~236ms into the first draw using the program: ~375ms per new
 * program, once. That is the whole stall - first swing at a creature type,
 * first application of a status effect, Free Action stalling exactly once.
 *
 * ===========================================================================
 * STATUS - READ BEFORE TRUSTING ANY OF IT
 * ===========================================================================
 *
 * PREWARM is PARTIALLY CONFIRMED. The first pass proved the mechanism: 64
 * combinations, 16 compiled something, 12-25ms each. But 25ms is an order of
 * magnitude short of 235ms, so the variants the game actually hits were not
 * covered. That pass bound one texture unit and enabled GL_LIGHTING without
 * configuring any lights. This version drives up to 4 units and 4 configured
 * lights, which is closer to what real Morrowind draws look like. Whether it
 * closes a 10x gap is unknown - the PREWARM lines are the test.
 *
 * Also dropped from the walk, because the first pass proved they generate no
 * new programs: blend state (a ROP operation) and primitive mode (QUADS ->
 * triangles is index generation). That budget went to units and lights.
 *
 * SCACHE previously failed silently with got=0. Cause, and the reason the
 * plain-RTLD_NEXT version of this file could not have worked: gl4es keeps its
 * own program ids and translates to the underlying GLES id inside its
 * wrappers (program.c:699 passes glprogram->id). dlsym(RTLD_NEXT) resolves
 * past gl4es straight to the Mali symbol, which then receives a gl4es id it
 * has never seen. The size query still answered, because gl4es handles that
 * one itself - which is what made it look like it was working. sc_bind_gl4es()
 * binds those three symbols explicitly out of libGL.so.1 so the id
 * translation happens.
 *
 * SCPRELOAD is an open experiment and is off in the launcher via
 * LIBGL_TSP_NOPRELOAD=1.
 *
 * RISK: SCWARM2 issues a draw with only generic attribute 0 bound. The
 * program's other attributes and uniforms are unset, so a GL error is
 * expected and is swallowed so the engine never sees it. An earlier attempt
 * used the fixed-function client-state path and broke rendering; this one
 * saves and restores every piece of state it touches. If rendering goes wrong
 * after enabling 1024, set LIBGL_TSP_NOWARM=1 - no rebuild - before assuming
 * the cache itself is at fault.
 *
 * ===========================================================================
 * ENVIRONMENT
 * ===========================================================================
 *
 *   LIBGL_TSP_WARM=1024          modes, comma separated (512,1024,2048)
 *   LIBGL_TSP_WARM_OUT=path      log, default /mnt/SDCARD/tsp_warm.txt
 *   LIBGL_TSP_SHADERCACHE=dir    cache dir, default
 *                                /mnt/SDCARD/data/ports/openmw51/shadercache
 *   LIBGL_TSP_NOWARM=1           disable SCWARM2 only
 *   LIBGL_TSP_NOPRELOAD=1        disable SCPRELOAD only
 *   LIBGL_TSP_ORPHAN=1           buffer orphaning (independent of modes)
 *   LIBGL_TSP_PREWARM_MAXTEX=N   default 4
 *   LIBGL_TSP_PREWARM_MAXLIGHT=N default 4
 *
 * Unset LIBGL_TSP_WARM and LIBGL_TSP_ORPHAN and this library does nothing at
 * all: no file is opened, no symbol beyond the forwarding target is resolved,
 * and every hook is a straight pass-through.
 *
 * Delete the cache directory after changing shaders or updating gl4es.
 * Binaries are driver- and source-specific; a stale one is rejected by the
 * driver rather than silently mis-rendered, but clearing is cleaner.
 *
 * ===========================================================================
 * BUILD / DEPLOY
 * ===========================================================================
 *
 *   gcc -shared -fPIC -O2 -o libtsp_warm.so tsp_warm.c -ldl
 *
 *   LD_PRELOAD="$GAMEDIR/lib/libtsp_diag.so:$GAMEDIR/lib/libtsp_warm.so:\
 *               $GAMEDIR/lib/libtsp_fullscreen_scaler.so:$TSP_GL4ES_LIBRARY"
 *
 * AFTER libtsp_diag.so on purpose: diag then still logs a LINK line for every
 * program, and its number includes whatever this library did. If warm came
 * first, a cache hit would return early and diag would never see the link.
 *
 * OSG_THREADING=SingleThreaded, so GL is single-threaded and none of this
 * state needs locking. If that ever changes, it does.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <dirent.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef unsigned int   GLenum;
typedef unsigned int   GLuint;
typedef int            GLint;
typedef int            GLsizei;
typedef unsigned char  GLboolean;
typedef float          GLfloat;
typedef void           GLvoid;

#define W_PREWARM    512
#define W_SCACHE    1024
#define W_SCPRELOAD 2048

#define GL_TEXTURE_2D          0x0DE1
#define GL_BLEND               0x0BE2
#define GL_ALPHA_TEST          0x0BC0
#define GL_LIGHTING            0x0B50
#define GL_FOG                 0x0B60
#define GL_SCISSOR_TEST        0x0C11
#define GL_VERTEX_ARRAY        0x8074
#define GL_COLOR_ARRAY         0x8076
#define GL_TEXTURE_COORD_ARRAY 0x8078
#define GL_TRIANGLE_FAN        0x0006
#define GL_FLOAT               0x1406
#define GL_UNSIGNED_BYTE       0x1401
#define GL_RGBA                0x1908
#define GL_TEXTURE0            0x84C0
#define GL_LIGHT0              0x4000
#define GL_POSITION            0x1203
#define GL_DIFFUSE             0x1201
#define GL_AMBIENT             0x1200
#define GL_GREATER             0x0204
#define GL_LINK_STATUS             0x8B82
#define GL_PROGRAM_BINARY_LENGTH   0x8741

#define SCW_ARRAY_BUFFER            0x8892
#define SCW_STATIC_DRAW             0x88E4
#define SCW_STREAM_DRAW             0x88E0
#define SCW_ARRAY_BUFFER_BINDING    0x8894
#define SCW_CURRENT_PROGRAM         0x8B8D
#define SCW_VAA_ENABLED             0x8622
#define SCW_VAA_SIZE                0x8623
#define SCW_VAA_STRIDE              0x8624
#define SCW_VAA_TYPE                0x8625
#define SCW_VAA_NORMALIZED          0x886A
#define SCW_VAA_BUFFER_BINDING      0x889F
#define SCW_VAA_POINTER             0x8645
#define SCW_SCISSOR_BOX             0x0C10
#define SCW_DEPTH_WRITEMASK         0x0B72
#define SCW_COLOR_WRITEMASK         0x0C23
#define SCW_CULL_FACE               0x0B44
#define SCW_TRIANGLES               0x0004

#define REAL(name, rettype, params)                                      \
    static rettype (*real_##name) params = NULL;                         \
    static void resolve_##name(void) {                                   \
        if (!real_##name)                                                \
            real_##name = (rettype (*) params) dlsym(RTLD_NEXT, #name);  \
    }

REAL(glEnable,                  void, (GLenum))
REAL(glDisable,                 void, (GLenum))
REAL(glIsEnabled,               GLboolean, (GLenum))
REAL(glEnableClientState,       void, (GLenum))
REAL(glDisableClientState,      void, (GLenum))
REAL(glVertexPointer,           void, (GLint,GLenum,GLsizei,const void*))
REAL(glColorPointer,            void, (GLint,GLenum,GLsizei,const void*))
REAL(glTexCoordPointer,         void, (GLint,GLenum,GLsizei,const void*))
REAL(glScissor,                 void, (GLint,GLint,GLsizei,GLsizei))
REAL(glAlphaFunc,               void, (GLenum,float))
REAL(glGenTextures,             void, (GLsizei,GLuint*))
REAL(glDeleteTextures,          void, (GLsizei,const GLuint*))
REAL(glBindTexture,             void, (GLenum,GLuint))
REAL(glTexImage2D,              void, (GLenum,GLint,GLint,GLsizei,GLsizei,GLint,GLenum,GLenum,const void*))
REAL(glDrawArrays,              void, (GLenum,GLint,GLsizei))
REAL(glActiveTexture,           void, (GLenum))
REAL(glClientActiveTexture,     void, (GLenum))
REAL(glLightfv,                 void, (GLenum,GLenum,const float*))
REAL(glLinkProgram,             void, (GLuint))
REAL(glShaderSource,            void, (GLuint,GLsizei,const char* const*,const GLint*))
REAL(glAttachShader,            void, (GLuint,GLuint))
REAL(glCreateProgram,           GLuint, (void))
REAL(glUseProgram,              void, (GLuint))
REAL(glGetProgramiv,            void, (GLuint,GLenum,GLint*))
REAL(glProgramBinary,           void, (GLuint,GLenum,const void*,GLsizei))
REAL(glGetProgramBinary,        void, (GLuint,GLsizei,GLsizei*,GLenum*,void*))
REAL(glGetIntegerv,             void, (GLenum,GLint*))
REAL(glGetBooleanv,             void, (GLenum,GLboolean*))
REAL(glBindBuffer,              void, (GLenum,GLuint))
REAL(glGenBuffers,              void, (GLsizei,GLuint*))
REAL(glBufferData,              void, (GLenum,long,const void*,GLenum))
REAL(glBufferSubData,           void, (GLenum,long,long,const void*))
REAL(glVertexAttribPointer,     void, (GLuint,GLint,GLenum,GLboolean,GLsizei,const void*))
REAL(glEnableVertexAttribArray, void, (GLuint))
REAL(glDisableVertexAttribArray,void, (GLuint))
REAL(glGetVertexAttribiv,       void, (GLuint,GLenum,GLint*))
REAL(glGetVertexAttribPointerv, void, (GLuint,GLenum,void**))
REAL(glDepthMask,               void, (GLboolean))
REAL(glColorMask,               void, (GLboolean,GLboolean,GLboolean,GLboolean))
REAL(glGetError,                GLenum, (void))
REAL(SDL_GL_SwapWindow,         void, (void*))

/* ------------------------------------------------------------------ */
/* config                                                              */
/* ------------------------------------------------------------------ */
static int   w_init;
static int   w_modes;
static int   w_orphan;
static FILE* w_out;
static char  w_cachedir[512];
static int   w_maxtex = 4, w_maxlight = 4;

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

static void warm_init(void)
{
    const char *m, *e;
    if (w_init) return;
    w_init = 1;

    e = getenv("LIBGL_TSP_ORPHAN");
    w_orphan = (e && e[0] && e[0] != '0');

    m = getenv("LIBGL_TSP_WARM");
    if (m && m[0]) {
        const char* s = m;
        while (*s) {
            int n = atoi(s);
            if (n > 0) w_modes |= n;
            while (*s && *s != ',') s++;
            if (*s == ',') s++;
        }
    }
    if (!w_modes && !w_orphan) return;

    e = getenv("LIBGL_TSP_WARM_OUT");
    w_out = fopen(e && e[0] ? e : "/mnt/SDCARD/tsp_warm.txt", "w");

    e = getenv("LIBGL_TSP_SHADERCACHE");
    if (!e || !e[0]) e = "/mnt/SDCARD/data/ports/openmw51/shadercache";
    snprintf(w_cachedir, sizeof(w_cachedir), "%s", e);

    e = getenv("LIBGL_TSP_PREWARM_MAXTEX");
    if (e && e[0]) { w_maxtex = atoi(e); if (w_maxtex < 0) w_maxtex = 0; if (w_maxtex > 8) w_maxtex = 8; }
    e = getenv("LIBGL_TSP_PREWARM_MAXLIGHT");
    if (e && e[0]) { w_maxlight = atoi(e); if (w_maxlight < 0) w_maxlight = 0; if (w_maxlight > 8) w_maxlight = 8; }

    if (w_out) {
        fprintf(w_out, "# libtsp_warm modes=%d%s%s%s orphan=%d\n", w_modes,
                (w_modes&W_PREWARM)?" PREWARM":"", (w_modes&W_SCACHE)?" SCACHE":"",
                (w_modes&W_SCPRELOAD)?" SCPRELOAD":"", w_orphan);
        fprintf(w_out, "# THIS LIBRARY CHANGES BEHAVIOUR. Measurements come from libtsp_diag.so.\n");
        if (w_modes & W_SCACHE) fprintf(w_out, "# cachedir=%s\n", w_cachedir);
        fflush(w_out);
    }
}
#define WON(bit) (w_modes & (bit))

/* ------------------------------------------------------------------ */
/* SCACHE - persistent program binary cache                            */
/* ------------------------------------------------------------------ */
#define SC_MAXID   8192
#define SC_MAXSRC  262144

static char  *sc_src[SC_MAXID];               /* shader id  -> source text  */
static unsigned long long sc_prog[SC_MAXID];  /* program id -> running hash */
static int    sc_ready;

static unsigned long long sc_hash(unsigned long long h, const char *s)
{
    if (!s) return h;
    while (*s) { h ^= (unsigned char)(*s++); h *= 1099511628211ULL; }
    return h;
}

/* gl4es keeps its own program ids and translates to the underlying GLES id
   inside its wrappers (program.c:699 passes glprogram->id). dlsym(RTLD_NEXT)
   resolves past gl4es straight to the Mali symbol, which then receives a
   gl4es id it does not know - the size query still worked because gl4es
   answers that one itself, but the binary fetch wrote nothing (got=0,
   fmt=0). Bind explicitly to libGL so the id translation happens. */
static void *sc_gl4es;
static void sc_bind_gl4es(void)
{
    if (sc_gl4es) return;
    sc_gl4es = dlopen("libGL.so.1", RTLD_NOW | RTLD_NOLOAD);
    if (!sc_gl4es) sc_gl4es = dlopen("libGL.so.1", RTLD_NOW);
    if (sc_gl4es) {
        void *a = dlsym(sc_gl4es, "glGetProgramBinary");
        void *b = dlsym(sc_gl4es, "glProgramBinary");
        void *c = dlsym(sc_gl4es, "glGetProgramiv");
        if (a) real_glGetProgramBinary = (void(*)(GLuint,GLsizei,GLsizei*,GLenum*,void*))a;
        if (b) real_glProgramBinary    = (void(*)(GLuint,GLenum,const void*,GLsizei))b;
        if (c) real_glGetProgramiv     = (void(*)(GLuint,GLenum,GLint*))c;
        if (w_out) fprintf(w_out, "SCACHE bind gl4es getbin=%p progbin=%p getiv=%p\n", a, b, c);
    } else if (w_out) {
        fprintf(w_out, "SCACHE bind failed: %s\n", dlerror());
    }

    /* Fall back to RTLD_NEXT only for whatever the explicit bind did not
       supply. This is the path that produced got=0, so it is not a fix - it
       is here so a dlopen failure degrades to a DETECTABLE wrong answer
       ("SCACHE why=got0") instead of a silent no-op, and the bind line above
       records which path was taken. If you see got0 with a failed bind, the
       cause is the id translation, not the cache logic. */
    if (!real_glGetProgramBinary) resolve_glGetProgramBinary();
    if (!real_glProgramBinary)    resolve_glProgramBinary();
    if (!real_glGetProgramiv)     resolve_glGetProgramiv();
    if (w_out && !sc_gl4es)
        fprintf(w_out, "SCACHE WARNING: using RTLD_NEXT fallback, expect got0\n");
}

static void sc_init(void)
{
    if (sc_ready) return;
    sc_ready = 1;
    mkdir(w_cachedir, 0777);
    sc_bind_gl4es();
    if (w_out) { fprintf(w_out, "SCACHE dir=%s\n", w_cachedir); fflush(w_out); }
}

static void sc_path(char *out, size_t n, unsigned long long key)
{
    snprintf(out, n, "%s/%016llx.bin", w_cachedir, key);
}

/* ------------------------------------------------------------------ */
/* SCWARM2 - deferred, state-preserving shader warm-up                 */
/*                                                                     */
/* Restoring a cached binary skips the link but Mali still defers its  */
/* final per-program work to the first draw. This forces that work at  */
/* a frame boundary instead, using a scratch VBO and generic vertex    */
/* attribute 0 - never the fixed-function client-state path, which is  */
/* what broke rendering on the first attempt.                          */
/* ------------------------------------------------------------------ */
#define SCW_QMAX 64
static GLuint scw_queue[SCW_QMAX];
static int    scw_qn;
static GLuint scw_vbo;
static int    scw_off;
static int    scw_checked;

static void scw_enqueue(GLuint prog)
{
    int i;
    if (!scw_checked) {
        const char *e = getenv("LIBGL_TSP_NOWARM");
        scw_off = (e && e[0] && e[0] != '0');
        scw_checked = 1;
    }
    if (scw_off) return;
    for (i = 0; i < scw_qn; i++) if (scw_queue[i] == prog) return;
    if (scw_qn < SCW_QMAX) scw_queue[scw_qn++] = prog;
}

/* Force the driver to finalise one program. Everything touched is saved
   first and put back afterwards. */
static void scw_warm_one(GLuint prog)
{
    GLint  prevProg = 0, prevBuf = 0;
    GLint  aEnabled = 0, aSize = 4, aType = GL_FLOAT, aNorm = 0, aStride = 0, aBuf = 0;
    void  *aPtr = NULL;
    GLint  box[4] = {0,0,1,1};
    GLboolean scEn = 0, cullEn = 0, dMask = 1;
    GLboolean cMask[4] = {1,1,1,1};
    double t0 = now_ms();

    resolve_glGetIntegerv();   resolve_glGetBooleanv();
    resolve_glUseProgram();    resolve_glBindBuffer();
    resolve_glBufferData();    resolve_glGenBuffers();
    resolve_glVertexAttribPointer(); resolve_glEnableVertexAttribArray();
    resolve_glDisableVertexAttribArray();
    resolve_glGetVertexAttribiv(); resolve_glGetVertexAttribPointerv();
    resolve_glScissor();       resolve_glEnable();
    resolve_glDisable();       resolve_glIsEnabled();
    resolve_glDepthMask();     resolve_glColorMask();
    resolve_glDrawArrays();    resolve_glGetError();

    if (!real_glGetIntegerv || !real_glUseProgram || !real_glDrawArrays ||
        !real_glVertexAttribPointer || !real_glBindBuffer) return;

    /* ---- save ---- */
    real_glGetIntegerv(SCW_CURRENT_PROGRAM, &prevProg);
    real_glGetIntegerv(SCW_ARRAY_BUFFER_BINDING, &prevBuf);
    if (real_glGetVertexAttribiv) {
        real_glGetVertexAttribiv(0, SCW_VAA_ENABLED,        &aEnabled);
        real_glGetVertexAttribiv(0, SCW_VAA_SIZE,           &aSize);
        real_glGetVertexAttribiv(0, SCW_VAA_TYPE,           &aType);
        real_glGetVertexAttribiv(0, SCW_VAA_NORMALIZED,     &aNorm);
        real_glGetVertexAttribiv(0, SCW_VAA_STRIDE,         &aStride);
        real_glGetVertexAttribiv(0, SCW_VAA_BUFFER_BINDING, &aBuf);
    }
    if (real_glGetVertexAttribPointerv)
        real_glGetVertexAttribPointerv(0, SCW_VAA_POINTER, &aPtr);
    if (real_glIsEnabled) {
        scEn   = real_glIsEnabled(GL_SCISSOR_TEST);
        cullEn = real_glIsEnabled(SCW_CULL_FACE);
    }
    real_glGetIntegerv(SCW_SCISSOR_BOX, box);
    if (real_glGetBooleanv) {
        real_glGetBooleanv(SCW_DEPTH_WRITEMASK, &dMask);
        real_glGetBooleanv(SCW_COLOR_WRITEMASK, cMask);
    }

    /* ---- scratch geometry, created once ---- */
    if (!scw_vbo && real_glGenBuffers && real_glBufferData) {
        static const float tri[6] = { 0.f,0.f, 1.f,0.f, 0.f,1.f };
        real_glGenBuffers(1, &scw_vbo);
        if (scw_vbo) {
            real_glBindBuffer(SCW_ARRAY_BUFFER, scw_vbo);
            real_glBufferData(SCW_ARRAY_BUFFER, sizeof(tri), tri, SCW_STATIC_DRAW);
        }
    }
    if (!scw_vbo) return;

    /* ---- make the draw harmless, then force compilation ---- */
    if (real_glScissor) { real_glScissor(0, 0, 1, 1); real_glEnable(GL_SCISSOR_TEST); }
    if (real_glDepthMask) real_glDepthMask(0);
    if (real_glColorMask) real_glColorMask(0, 0, 0, 0);
    if (real_glDisable)   real_glDisable(SCW_CULL_FACE);

    real_glUseProgram(prog);
    real_glBindBuffer(SCW_ARRAY_BUFFER, scw_vbo);
    if (real_glEnableVertexAttribArray) real_glEnableVertexAttribArray(0);
    real_glVertexAttribPointer(0, 2, GL_FLOAT, 0, 0, (const void*)0);
    real_glDrawArrays(SCW_TRIANGLES, 0, 3);

    /* the program's other attributes and uniforms are not bound, so an
       error here is expected and meaningless - swallow it so the engine
       never sees it */
    if (real_glGetError) while (real_glGetError() != 0) { }

    /* ---- restore, in reverse ---- */
    if (aEnabled) {
        if (real_glEnableVertexAttribArray) real_glEnableVertexAttribArray(0);
    } else {
        if (real_glDisableVertexAttribArray) real_glDisableVertexAttribArray(0);
    }
    real_glBindBuffer(SCW_ARRAY_BUFFER, (GLuint)aBuf);
    if (aEnabled)
        real_glVertexAttribPointer(0, aSize, (GLenum)aType,
                                   (GLboolean)aNorm, aStride, aPtr);
    real_glBindBuffer(SCW_ARRAY_BUFFER, (GLuint)prevBuf);
    real_glUseProgram((GLuint)prevProg);
    if (real_glColorMask) real_glColorMask(cMask[0], cMask[1], cMask[2], cMask[3]);
    if (real_glDepthMask) real_glDepthMask(dMask);
    if (real_glScissor)   real_glScissor(box[0], box[1], box[2], box[3]);
    if (!scEn && real_glDisable)  real_glDisable(GL_SCISSOR_TEST);
    if (scEn  && real_glEnable)   real_glEnable(GL_SCISSOR_TEST);
    if (cullEn && real_glEnable)  real_glEnable(SCW_CULL_FACE);
    if (real_glGetError) while (real_glGetError() != 0) { }

    if (w_out) {
        fprintf(w_out, "SCWARM prog=%u %.0fus\n", prog, (now_ms()-t0)*1000.0);
        fflush(w_out);
    }
}

/* Drained after the swap, when the frame is done and state is quiescent. */
static void scw_drain(void)
{
    int i, n = scw_qn;
    if (!n) return;
    scw_qn = 0;
    for (i = 0; i < n; i++) scw_warm_one(scw_queue[i]);
}

/* Restore a previously compiled binary. Returns 1 on success. */
static int sc_try_load(GLuint prog, unsigned long long key, double *us)
{
    char path[600];
    FILE *f;
    long len;
    void *buf;
    GLenum fmt = 0;
    GLint ok = 0;
    double t0;

    sc_path(path, sizeof(path), key);
    f = fopen(path, "rb");
    if (!f) return 0;
    if (fread(&fmt, sizeof(fmt), 1, f) != 1) { fclose(f); return 0; }
    fseek(f, 0, SEEK_END);
    len = ftell(f) - (long)sizeof(fmt);
    fseek(f, (long)sizeof(fmt), SEEK_SET);
    if (len <= 0) { fclose(f); return 0; }
    buf = malloc((size_t)len);
    if (!buf) { fclose(f); return 0; }
    if (fread(buf, 1, (size_t)len, f) != (size_t)len) { free(buf); fclose(f); return 0; }
    fclose(f);

    if (!real_glProgramBinary || !real_glGetProgramiv) { free(buf); return 0; }

    t0 = now_ms();
    real_glProgramBinary(prog, fmt, buf, (GLsizei)len);
    real_glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    *us = (now_ms() - t0) * 1000.0;
    free(buf);
    if (ok) scw_enqueue(prog);   /* SCWARM2: drained after swap */
    return ok ? 1 : 0;
}

/* Persist a freshly linked program. */
static long sc_save(GLuint prog, unsigned long long key, double *us)
{
    char path[600], tmp[620];
    FILE *f;
    GLint len = 0;
    GLsizei got = 0;
    GLenum fmt = 0;
    void *buf;
    double t0;

    if (!real_glGetProgramiv || !real_glGetProgramBinary) {
        if (w_out) fprintf(w_out, "SCACHE why=nosym getiv=%p getbin=%p\n",
                           (void*)real_glGetProgramiv, (void*)real_glGetProgramBinary);
        return -1;
    }
    real_glGetProgramiv(prog, GL_PROGRAM_BINARY_LENGTH, &len);
    if (len <= 0) { if (w_out) fprintf(w_out, "SCACHE why=len0 prog=%u\n", prog); return -1; }
    buf = malloc((size_t)len);
    if (!buf) return -1;

    t0 = now_ms();
    real_glGetProgramBinary(prog, len, &got, &fmt, buf);
    *us = (now_ms() - t0) * 1000.0;
    if (got <= 0) {
        if (w_out) fprintf(w_out, "SCACHE why=got0 prog=%u len=%d fmt=0x%x\n",
                           prog, (int)len, (unsigned)fmt);
        free(buf); return -1;
    }

    /* write to a temp name then rename, so a crash mid-write cannot leave a
       truncated binary that the driver would reject next run */
    sc_path(path, sizeof(path), key);
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    f = fopen(tmp, "wb");
    if (!f) { free(buf); return -1; }
    fwrite(&fmt, sizeof(fmt), 1, f);
    fwrite(buf, 1, (size_t)got, f);
    fclose(f);
    rename(tmp, path);
    free(buf);
    return (long)got;
}

/* ------------------------------------------------------------------ */
/* SCPRELOAD (mode 2048)                                               */
/*                                                                     */
/* Tests whether Mali keys compiled program state to the binary content */
/* or to the program object. Loads every cached binary into its own     */
/* throwaway program at the loading screen and warms it. If the driver  */
/* caches by binary, OpenMW's later restore of the same bytes is cheap  */
/* and the mid-combat stall disappears. If it caches per object, the    */
/* stalls remain and the wrapper approach is exhausted.                 */
/* ------------------------------------------------------------------ */
#define SCP_MAX 128
static GLuint scp_progs[SCP_MAX];
static int    scp_n;
static int    scp_done;

static void scp_preload(void)
{
    DIR *d;
    struct dirent *e;
    const char *env;
    double t_all;

    if (scp_done) return;
    scp_done = 1;
    if (!WON(W_SCPRELOAD)) return;
    env = getenv("LIBGL_TSP_NOPRELOAD");
    if (env && env[0] && env[0] != '0') return;

    sc_init();
    resolve_glCreateProgram();
    if (!real_glCreateProgram || !real_glProgramBinary) {
        if (w_out) { fprintf(w_out, "SCPRE unavailable\n"); fflush(w_out); }
        return;
    }
    d = opendir(w_cachedir);
    if (!d) {
        if (w_out) { fprintf(w_out, "SCPRE no dir %s\n", w_cachedir); fflush(w_out); }
        return;
    }
    t_all = now_ms();
    while ((e = readdir(d)) != NULL && scp_n < SCP_MAX) {
        char path[700];
        FILE *f;
        long len;
        void *buf;
        GLenum fmt;
        GLint ok = 0;
        GLuint prog;
        double t0, tload, twarm;
        size_t nl = strlen(e->d_name);
        if (nl < 5 || strcmp(e->d_name + nl - 4, ".bin") != 0) continue;
        snprintf(path, sizeof(path), "%s/%s", w_cachedir, e->d_name);
        f = fopen(path, "rb");
        if (!f) continue;
        if (fread(&fmt, sizeof(fmt), 1, f) != 1) { fclose(f); continue; }
        fseek(f, 0, SEEK_END);
        len = ftell(f) - (long)sizeof(fmt);
        fseek(f, (long)sizeof(fmt), SEEK_SET);
        if (len <= 0) { fclose(f); continue; }
        buf = malloc((size_t)len);
        if (!buf) { fclose(f); continue; }
        if (fread(buf, 1, (size_t)len, f) != (size_t)len) { free(buf); fclose(f); continue; }
        fclose(f);

        t0 = now_ms();
        prog = real_glCreateProgram();
        if (!prog) { free(buf); continue; }
        real_glProgramBinary(prog, fmt, buf, (GLsizei)len);
        if (real_glGetProgramiv) real_glGetProgramiv(prog, GL_LINK_STATUS, &ok);
        tload = (now_ms() - t0) * 1000.0;
        free(buf);
        if (!ok) {
            if (w_out) fprintf(w_out, "SCPRE file=%s REJECTED\n", e->d_name);
            continue;
        }
        t0 = now_ms();
        scw_warm_one(prog);
        twarm = (now_ms() - t0) * 1000.0;
        /* keep it alive - deleting might discard whatever the driver built */
        scp_progs[scp_n++] = prog;
        if (w_out) {
            fprintf(w_out, "SCPRE file=%s prog=%u load=%.0fus warm=%.0fus\n",
                    e->d_name, prog, tload, twarm);
            fflush(w_out);
        }
    }
    closedir(d);
    if (w_out) {
        fprintf(w_out, "SCPRE done n=%d total=%.0fms\n", scp_n, now_ms() - t_all);
        fflush(w_out);
    }
}

/* ------------------------------------------------------------------ */
/* shader hooks                                                        */
/* ------------------------------------------------------------------ */
void glShaderSource(GLuint sh, GLsizei count, const char* const* str, const GLint* len)
{
    warm_init();
    resolve_glShaderSource();
    if (WON(W_SCACHE) && sh < SC_MAXID && str) {
        size_t total = 0; GLsizei i; char *acc;
        for (i = 0; i < count; i++) if (str[i]) total += strlen(str[i]);
        if (total > 0 && total < SC_MAXSRC) {
            acc = (char*)malloc(total + 1);
            if (acc) {
                acc[0] = 0;
                for (i = 0; i < count; i++) if (str[i]) strcat(acc, str[i]);
                if (sc_src[sh]) free(sc_src[sh]);
                sc_src[sh] = acc;
            }
        }
    }
    if (real_glShaderSource) real_glShaderSource(sh, count, str, len);
}

void glAttachShader(GLuint prog, GLuint sh)
{
    warm_init();
    resolve_glAttachShader();
    if (WON(W_SCACHE) && prog < SC_MAXID && sh < SC_MAXID) {
        if (!sc_prog[prog]) sc_prog[prog] = 14695981039346656037ULL;
        sc_prog[prog] = sc_hash(sc_prog[prog], sc_src[sh]);
    }
    if (real_glAttachShader) real_glAttachShader(prog, sh);
}

void glLinkProgram(GLuint p)
{
    double t0, dt, sus = 0;
    unsigned long long key;
    warm_init();
    resolve_glLinkProgram();

    if (WON(W_SCACHE) && p < SC_MAXID && sc_prog[p]) {
        sc_init();
        key = sc_prog[p];
        if (sc_try_load(p, key, &sus)) {
            if (w_out) { fprintf(w_out, "SCACHE hit  prog=%u key=%016llx %.0fus\n",
                                 p, key, sus); fflush(w_out); }
            return;
        }
        t0 = now_ms();
        if (real_glLinkProgram) real_glLinkProgram(p);
        dt = (now_ms() - t0) * 1000.0;
        {
            long n = sc_save(p, key, &sus);
            if (w_out) {
                if (n > 0)
                    fprintf(w_out, "SCACHE miss prog=%u key=%016llx link=%.0fus save=%.0fus bytes=%ld\n",
                            p, key, dt, sus, n);
                else
                    fprintf(w_out, "SCACHE fail prog=%u key=%016llx link=%.0fus\n", p, key, dt);
                fflush(w_out);
            }
        }
        return;
    }

    if (real_glLinkProgram) real_glLinkProgram(p);
}

/* ------------------------------------------------------------------ */
/* ORPHAN                                                              */
/*                                                                     */
/* OSG particle systems rewrite their whole vertex buffer every frame. */
/* On Mali, writing a buffer the GPU may still be reading stalls until  */
/* it finishes. Orphaning - glBufferData(NULL) first - makes the driver */
/* hand back fresh storage instead of waiting.                          */
/* ------------------------------------------------------------------ */
void glBufferSubData(GLenum t, long o, long sz, const void* d)
{
    warm_init();
    resolve_glBufferSubData();
    if (w_orphan && o == 0) {
        resolve_glBufferData();
        if (real_glBufferData) real_glBufferData(t, sz, (const void*)0, SCW_STREAM_DRAW);
    }
    if (real_glBufferSubData) real_glBufferSubData(t,o,sz,d);
}

/* ------------------------------------------------------------------ */
/* PREWARM (mode 512)                                                  */
/* ------------------------------------------------------------------ */
static int w_prewarm_done;

static void tsp_prewarm(void)
{
    /* geometry is irrelevant to shader generation - one quad is enough */
    static const float verts[]  = { 0,0, 1,0, 1,1, 0,1 };
    static const float cols[]   = { 1,1,1,1, 1,1,1,1, 1,1,1,1, 1,1,1,1 };
    static const float texco[]  = { 0,0, 1,0, 1,1, 0,1 };
    static const unsigned char px[4] = { 255, 255, 255, 255 };
    static const float lpos[4]  = { 1.0f, 1.0f, 1.0f, 0.0f };
    static const float ldif[4]  = { 0.8f, 0.8f, 0.8f, 1.0f };
    static const float lamb[4]  = { 0.2f, 0.2f, 0.2f, 1.0f };

    GLuint tex[8];
    int maxTex = w_maxtex, maxLight = w_maxlight;
    int ntex, nlight, useAlpha, useFog, i;
    int combos = 0, compiled = 0;
    double t_all0, t0, dt, worst = 0.0;
    char worstdesc[160];

    resolve_glEnable(); resolve_glDisable();
    resolve_glEnableClientState(); resolve_glDisableClientState();
    resolve_glVertexPointer(); resolve_glColorPointer();
    resolve_glTexCoordPointer(); resolve_glScissor();
    resolve_glAlphaFunc(); resolve_glGenTextures();
    resolve_glTexImage2D(); resolve_glDeleteTextures();
    resolve_glDrawArrays(); resolve_glBindTexture();
    resolve_glActiveTexture(); resolve_glClientActiveTexture();
    resolve_glLightfv();

    if (!real_glEnable || !real_glDrawArrays || !real_glVertexPointer
        || !real_glEnableClientState || !real_glDisableClientState
        || !real_glDisable || !real_glColorPointer)
    {
        if (w_out) { fprintf(w_out, "PREWARM: required entry points missing, skipped\n"); fflush(w_out); }
        return;
    }
    if (!real_glActiveTexture || !real_glClientActiveTexture)
        maxTex = 1;   /* cannot drive multiple units without these */

    worstdesc[0] = 0;
    t_all0 = now_ms();
    if (w_out) {
        fprintf(w_out, "PREWARM start: texunits 0..%d, lights 0..%d, alpha x fog\n",
                maxTex, maxLight);
        fflush(w_out);
    }

    if (real_glScissor) { real_glScissor(0, 0, 1, 1); real_glEnable(GL_SCISSOR_TEST); }

    for (i = 0; i < 8; i++) tex[i] = 0;
    if (real_glGenTextures && real_glTexImage2D && real_glBindTexture) {
        real_glGenTextures(maxTex > 0 ? maxTex : 1, tex);
        for (i = 0; i < maxTex; i++) {
            if (!tex[i]) continue;
            real_glBindTexture(GL_TEXTURE_2D, tex[i]);
            real_glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, px);
        }
    }

    real_glEnableClientState(GL_VERTEX_ARRAY);
    real_glVertexPointer(2, GL_FLOAT, 0, verts);
    real_glEnableClientState(GL_COLOR_ARRAY);
    real_glColorPointer(4, GL_FLOAT, 0, cols);

    for (ntex = 0; ntex <= maxTex; ntex++)
    for (nlight = 0; nlight <= maxLight; nlight++)
    for (useAlpha = 0; useAlpha < 2; useAlpha++)
    for (useFog = 0; useFog < 2; useFog++)
    {
        for (i = 0; i < (maxTex > 0 ? maxTex : 1); i++) {
            if (real_glActiveTexture) real_glActiveTexture(GL_TEXTURE0 + i);
            if (real_glClientActiveTexture) real_glClientActiveTexture(GL_TEXTURE0 + i);
            if (i < ntex) {
                real_glEnable(GL_TEXTURE_2D);
                if (tex[i] && real_glBindTexture) real_glBindTexture(GL_TEXTURE_2D, tex[i]);
                real_glEnableClientState(GL_TEXTURE_COORD_ARRAY);
                if (real_glTexCoordPointer) real_glTexCoordPointer(2, GL_FLOAT, 0, texco);
            } else {
                real_glDisable(GL_TEXTURE_2D);
                real_glDisableClientState(GL_TEXTURE_COORD_ARRAY);
            }
        }
        if (real_glActiveTexture) real_glActiveTexture(GL_TEXTURE0);
        if (real_glClientActiveTexture) real_glClientActiveTexture(GL_TEXTURE0);

        /* lights - configured, not just enabled, so they cannot be folded away */
        if (nlight > 0) real_glEnable(GL_LIGHTING); else real_glDisable(GL_LIGHTING);
        for (i = 0; i < 8; i++) {
            if (i < nlight) {
                if (real_glLightfv) {
                    real_glLightfv(GL_LIGHT0 + i, GL_POSITION, lpos);
                    real_glLightfv(GL_LIGHT0 + i, GL_DIFFUSE,  ldif);
                    real_glLightfv(GL_LIGHT0 + i, GL_AMBIENT,  lamb);
                }
                real_glEnable(GL_LIGHT0 + i);
            } else
                real_glDisable(GL_LIGHT0 + i);
        }

        if (useAlpha) { real_glEnable(GL_ALPHA_TEST); if (real_glAlphaFunc) real_glAlphaFunc(GL_GREATER, 0.5f); }
        else            real_glDisable(GL_ALPHA_TEST);
        if (useFog) real_glEnable(GL_FOG); else real_glDisable(GL_FOG);

        t0 = now_ms();
        real_glDrawArrays(GL_TRIANGLE_FAN, 0, 4);
        dt = (now_ms() - t0) * 1000.0;   /* us */
        combos++;

        if (dt > 1000.0) {
            compiled++;
            if (w_out)
                fprintf(w_out, "PREWARM %9.0fus  ntex=%d nlight=%d alpha=%d fog=%d\n",
                        dt, ntex, nlight, useAlpha, useFog);
        }
        if (dt > worst) {
            worst = dt;
            snprintf(worstdesc, sizeof(worstdesc),
                     "ntex=%d nlight=%d alpha=%d fog=%d", ntex, nlight, useAlpha, useFog);
        }
    }

    /* restore */
    for (i = 0; i < (maxTex > 0 ? maxTex : 1); i++) {
        if (real_glActiveTexture) real_glActiveTexture(GL_TEXTURE0 + i);
        if (real_glClientActiveTexture) real_glClientActiveTexture(GL_TEXTURE0 + i);
        real_glDisable(GL_TEXTURE_2D);
        real_glDisableClientState(GL_TEXTURE_COORD_ARRAY);
        if (real_glBindTexture) real_glBindTexture(GL_TEXTURE_2D, 0);
    }
    if (real_glActiveTexture) real_glActiveTexture(GL_TEXTURE0);
    if (real_glClientActiveTexture) real_glClientActiveTexture(GL_TEXTURE0);
    for (i = 0; i < 8; i++) real_glDisable(GL_LIGHT0 + i);
    real_glDisable(GL_LIGHTING);
    real_glDisable(GL_ALPHA_TEST);
    real_glDisable(GL_FOG);
    real_glDisable(GL_BLEND);
    real_glDisableClientState(GL_COLOR_ARRAY);
    real_glDisableClientState(GL_VERTEX_ARRAY);
    if (real_glScissor) real_glDisable(GL_SCISSOR_TEST);
    for (i = 0; i < maxTex; i++)
        if (tex[i] && real_glDeleteTextures) real_glDeleteTextures(1, &tex[i]);

    if (w_out) {
        fprintf(w_out, "PREWARM done: %d combinations, %d compiled, %.0fms total, worst %.0fus (%s)\n",
                combos, compiled, now_ms() - t_all0, worst,
                worstdesc[0] ? worstdesc : "none");
        fflush(w_out);
    }
}

/* ------------------------------------------------------------------ */
/* frame boundary                                                      */
/* ------------------------------------------------------------------ */
void SDL_GL_SwapWindow(void* w)
{
    warm_init();
    resolve_SDL_GL_SwapWindow();

    /* Before the swap: prewarm once, on the first frame with a live context.
       warm_init() has already run, unlike the pre-split version where this
       block sat above diag_init() and could not see its own mode bits. */
    if (!w_prewarm_done && WON(W_PREWARM)) {
        w_prewarm_done = 1;      /* set first: a crash inside must not loop */
        tsp_prewarm();
    }

    if (real_SDL_GL_SwapWindow) real_SDL_GL_SwapWindow(w);

    /* After the swap, when the frame is done and GL state is quiescent. */
    scp_preload();
    scw_drain();
}
