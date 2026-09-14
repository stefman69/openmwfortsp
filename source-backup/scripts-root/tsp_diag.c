/*
 * tsp_diag.c  -  GL diagnostic wrapper for the OpenMW TrimUI port
 *
 * ===========================================================================
 * THIS LIBRARY MEASURES. IT DOES NOT FIX.
 * ===========================================================================
 *
 * Every hook counts or times, then forwards to the real function and returns
 * its value unchanged. No GL state is altered, no call is suppressed, no call
 * is injected. If a number in here is wrong, the bug is in the counting.
 *
 * That was not true before the split. This library used to carry:
 *
 *   LIBGL_TSP_ORPHAN     injected glBufferData(NULL) before glBufferSubData
 *   mode 512  PREWARM    drew ~100 invisible quads at startup
 *   mode 1024 SCACHE     replaced glLinkProgram with a disk cache
 *   mode 2048 SCPRELOAD  created programs from cached binaries
 *   SCWARM2              issued a draw per restored program after swap
 *
 * All five changed behaviour. All five are now in libtsp_warm.so. Nothing in
 * this file does anything to the frame you are measuring.
 *
 * Two consequences worth knowing:
 *
 *   - swap_us is now honest. scp_preload() and scw_drain() used to run
 *     between the real SwapWindow and the d_swap_us timestamp, so shader
 *     warm-up time was being reported as swap time.
 *   - MODE 512 HAS CHANGED MEANING. It was PREWARM. It is now MEMTRACE. If
 *     you set 512 and get PREWARM lines, you are running a pre-split
 *     library.
 *
 * One deliberate exception: mode 128 FINISH inserts a glFinish() before the
 * swap. That perturbs the thing it measures and is a probe, not a fix - it
 * exists to split a swap wait into "GPU still rendering" versus "GPU done,
 * blocked in present". It is off unless asked for, and it is the only hook
 * here that touches the pipeline.
 *
 * ===========================================================================
 * MODE TABLE
 * ===========================================================================
 *
 *  N  NAME        WHAT IT LOGS                        USE IT WHEN
 * --  ----------  ----------------------------------  --------------------------
 *  1  FRAME       one line per frame: frame time,     you want to know if a
 *                 draws, verts, tris, texture binds,  problem is submission
 *                 shader switches, buffer uploads     volume or something else
 *
 *  2  TIMING      adds the decisive split to mode 1:  a frame is slow and you
 *                 microseconds inside draw calls vs   need to know whether the
 *                 inside SwapWindow, plus the single  CPU is working or waiting
 *                 slowest draw with its vert count,   on the GPU
 *                 texture, program, and CPU time
 *
 *  4  DRAWSTATE   for frames over the ms threshold,   two frames submit the
 *                 every draw's full GL state: blend   same geometry but one is
 *                 on/off, blend func, depth test,     slow, and you need to see
 *                 depth mask, cull, texture id,       which state differs
 *                 program id, primitive mode, count.
 *                 Identical draws collapse to xN
 *
 *  8  FBO         framebuffer lifecycle: binds,       render-to-texture is
 *                 attachments, completeness status    black, missing, or
 *                                                     reports incomplete
 *
 * 16  SYNC        the operations that stall the       frame time is high but
 *                 pipeline: glFinish, glFlush,        neither draws nor swap
 *                 glReadPixels, glCopyTexSubImage,    explain it
 *                 texture uploads and their volume
 *
 * 32  SHADER      shader pipeline activity: source,   you suspect gl4es is
 *                 compile, link, program creation     generating and compiling
 *                                                     shaders mid-frame
 *
 * 64  EXT         one-shot at first frame: GL vendor, you need to know what the
 *                 renderer, full extension string     driver actually supports
 *
 * 128 FINISH      glFinish() before swap, timed       swap_us is large and you
 *                 separately. finish large + swap     need to know whether the
 *                 small = GPU genuinely rendering.    GPU is busy or the block
 *                 finish small + swap large = GPU     is in present/vsync
 *                 done, blocked in present or vsync.
 *                 COSTS A PIPELINE FLUSH PER FRAME
 *
 * 256 TEXMAP      texture id -> dimensions and        a draw-state dump names
 *                 format at creation                  textures only as numeric
 *                                                     ids and you need to know
 *                                                     which assets they are
 *
 * 512 MEMTRACE    GL memory accounting against        memory is disappearing
 *                 /proc/meminfo. WAS PREWARM before   and you need to know
 *                 the split - see below               whether the engine or
 *                                                     the driver is holding it
 *
 * ===========================================================================
 * MODE 512 MEMTRACE - WHAT IT ANSWERS
 * ===========================================================================
 *
 * Device: 986MB, ZERO swap, so no graceful degradation - straight to the OOM
 * killer. Established by measurement:
 *
 *   - OpenMW's RSS does NOT leak. 600-660MB steady, dropping to 310-390MB on
 *     every load screen, so its own cache expiry demonstrably works.
 *   - MemAvailable still falls 706MB -> 41MB over ~16 minutes and does NOT
 *     recover in proportion when RSS drops.
 *   - releaseGLObjects on cell transitions reclaimed 0kb, 272kb, 0kb across
 *     three fires. Asking the driver to drop its GL objects released nothing.
 *
 * A /proc/meminfo sampler proves the system lost memory. It cannot say who
 * took it. This can, because it sits at the boundary where OpenMW hands bytes
 * to the driver and counts both directions.
 *
 * Read the MEMTRACE line as what the engine thinks is live against what the
 * kernel thinks is gone:
 *
 *   tex_live + buf_live RISE with the fall in memavail
 *       -> OpenMW uploading and not deleting. An engine-side leak, which
 *          would contradict the flat RSS, so check up_mb against del_mb.
 *
 *   tex_live + buf_live FLAT while memavail falls
 *       -> the driver is losing memory on upload/delete churn. A high
 *          up_mb/del_mb ratio with flat live bytes means gl4es or Mali is
 *          failing to reuse freed pages.
 *
 *   tex_live + buf_live FALL and memavail does NOT recover by a similar
 *   amount
 *       -> the driver took the delete and kept the pages. This is what every
 *          piece of evidence so far points at, and this line confirms it.
 *          del_mb rising with no matching rise in memavail is the signature.
 *
 * unacct_kb is:
 *   MemTotal - MemFree - Buffers - Cached - Slab - KernelStack - PageTables
 *            - VmallocUsed - AnonPages
 * Memory the kernel handed out and reports in no category. On Mali that is
 * the GPU's own page pool. unacct_kb climbing while tex_live is flat means
 * the answer is the driver and the fix is not in OpenMW.
 *
 * CAVEAT ON THE NUMBERS: tex_live/buf_live are what OpenMW ASKED FOR, from
 * the dimensions and format passed in. They are not what the driver
 * allocated - gl4es may convert format, generate mipmaps (LIBGL_MIPMAP=5)
 * or shrink (LIBGL_SHRINK). Expect the absolute value to be wrong and the
 * TREND to be right. A leak is a derivative, not a level. Compressed uploads
 * carry their true byte size and are exact.
 *
 * ===========================================================================
 * ENVIRONMENT
 * ===========================================================================
 *
 *   LIBGL_TSP_DIAG=1,2        modes to enable (comma separated, or "all")
 *   LIBGL_TSP_DIAG_OUT=path   output file, default /mnt/SDCARD/tsp_diag.txt
 *   LIBGL_TSP_DIAG_MS=45      mode 4 threshold in ms, default 45
 *   LIBGL_TSP_DIAG_MAX=4000   max frames to log, default 4000
 *   LIBGL_TSP_DIAG_FRAMES=40  mode 4 max frames to dump, default 40
 *   LIBGL_TSP_DIAG_MEMSECS=5  mode 512 seconds between lines, default 5
 *   LIBGL_TSP_DIAG_MEMEVENT_KB=1024
 *                             mode 512: minimum delete batch to log as a
 *                             discrete MTFREE event. A bulk delete is a
 *                             releaseGLObjects or a cache purge, and having
 *                             it as a point on the timeline rather than a
 *                             step in a curve is what lets you line it up
 *                             against MemAvailable. 0 logs every batch.
 *
 * Unset LIBGL_TSP_DIAG and nothing is logged and no file is opened - the cost
 * is one predictable branch per intercepted call.
 *
 * ===========================================================================
 * BUILD / DEPLOY
 * ===========================================================================
 *
 *   gcc -shared -fPIC -O2 -o libtsp_diag.so tsp_diag.c -ldl
 *
 *   LD_PRELOAD="$GAMEDIR/lib/libtsp_diag.so:$GAMEDIR/lib/libtsp_warm.so:\
 *               $GAMEDIR/lib/libtsp_fullscreen_scaler.so:$TSP_GL4ES_LIBRARY"
 *
 * diag BEFORE warm, so a shader-cache hit still produces a LINK line here.
 * If warm came first it would return early on a hit and diag would never see
 * the link at all.
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
typedef unsigned int   GLbitfield;
typedef unsigned char  GLboolean;
typedef float          GLfloat;
typedef void           GLvoid;

#define M_FRAME      1
#define M_TIMING     2
#define M_DRAWSTATE  4
#define M_FBO        8
#define M_SYNC      16
#define M_SHADER    32
#define M_EXT       64
#define M_FINISH   128
#define M_TEXMAP   256
#define M_MEMTRACE 512     /* was PREWARM before the split - see header */
#define M_PREWARM  (1u<<8)   /* mode 9 */
#define M_SCACHE   (1u<<10)  /* pass 1024 */
#define M_SCPRELOAD (1u<<11)  /* pass 2048 */

#define GL_BLEND          0x0BE2
#define GL_DEPTH_TEST     0x0B71
#define GL_CULL_FACE      0x0B44
#define GL_TEXTURE_2D     0x0DE1
#define GL_EXTENSIONS     0x1F03
#define GL_VENDOR         0x1F00
#define GL_RENDERER       0x1F01
#define GL_FB_COMPLETE    0x8CD5
#define GL_TRIANGLES      0x0004
#define GL_TRIANGLE_STRIP 0x0005
#define GL_TRIANGLE_FAN   0x0006
#define GL_TEXTURE0       0x84C0
#define GL_ARRAY_BUFFER         0x8892
#define GL_ELEMENT_ARRAY_BUFFER 0x8893

/* ------------------------------------------------------------------ */
/* config                                                              */
/* ------------------------------------------------------------------ */
static FILE*  g_out = NULL;
static int    g_init = 0;
static int    g_modes = 0;
static double g_thresh = 45.0;
static long   g_max = 4000;
static long   g_dsmax = 40;
static long   g_dsdone = 0;
static unsigned long g_frame = 0;
static double g_last = 0.0;

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

/* mode 512 tuning, read in diag_init */
static double mt_interval_ms = 5000.0;
static unsigned long long mt_event_bytes = 1048576ULL;

static void diag_init(void)
{
    const char* m; const char* p; const char* v;
    if (g_init) return;
    g_init = 1;
    m = getenv("LIBGL_TSP_DIAG");
    if (!m || !m[0]) return;
    if (strstr(m, "all")) {
        g_modes = M_FRAME|M_TIMING|M_DRAWSTATE|M_FBO|M_SYNC|M_SHADER|M_EXT
                 |M_TEXMAP|M_MEMTRACE;
        /* M_FINISH deliberately excluded from "all": it flushes the pipeline
           every frame, so including it would silently change what "all" costs
           and make the timings it sits next to unrepresentative. */
    } else {
        const char* s = m;
        while (*s) {
            int n = atoi(s);
            if (n > 0) g_modes |= n;
            while (*s && *s != ',') s++;
            if (*s == ',') s++;
        }
    }
    if (!g_modes) return;
    p = getenv("LIBGL_TSP_DIAG_OUT");
    g_out = fopen(p && p[0] ? p : "/mnt/SDCARD/tsp_diag.txt", "a");
    if (!g_out) { g_modes = 0; return; }
    v = getenv("LIBGL_TSP_DIAG_MS");     if (v && v[0]) g_thresh = atof(v);
    v = getenv("LIBGL_TSP_DIAG_MAX");    if (v && v[0]) g_max   = atol(v);
    v = getenv("LIBGL_TSP_DIAG_FRAMES"); if (v && v[0]) g_dsmax = atol(v);
    v = getenv("LIBGL_TSP_DIAG_MEMSECS");
    if (v && v[0]) { double d = atof(v); if (d > 0.0) mt_interval_ms = d * 1000.0; }
    v = getenv("LIBGL_TSP_DIAG_MEMEVENT_KB");
    if (v && v[0]) { double d = atof(v); if (d >= 0.0) mt_event_bytes = (unsigned long long)(d * 1024.0); }

    fprintf(g_out, "# tsp_diag modes=%d%s%s%s%s%s%s%s%s%s%s\n", g_modes,
            (g_modes&M_FRAME)?" FRAME":"", (g_modes&M_TIMING)?" TIMING":"",
            (g_modes&M_DRAWSTATE)?" DRAWSTATE":"", (g_modes&M_FBO)?" FBO":"",
            (g_modes&M_SYNC)?" SYNC":"", (g_modes&M_SHADER)?" SHADER":"",
            (g_modes&M_EXT)?" EXT":"", (g_modes&M_FINISH)?" FINISH":"",
            (g_modes&M_TEXMAP)?" TEXMAP":"", (g_modes&M_MEMTRACE)?" MEMTRACE":"");
    fprintf(g_out, "# measurement only - interventions live in libtsp_warm.so\n");
    if (g_modes & M_TEXMAP) fprintf(g_out, "# TEXMAP active: texture id -> size/format at creation\n");
    if (g_modes & M_FINISH) fprintf(g_out, "# FINISH mode active (adds a flush per frame)\n");
    if (g_modes & M_MEMTRACE)
        fprintf(g_out, "# MEMTRACE active: every %.0fs. NOTE 512 was PREWARM before the split.\n"
                       "# tex_live/buf_live are bytes OpenMW asked for, not bytes the driver\n"
                       "# allocated. Watch the trend, not the level.\n",
                mt_interval_ms / 1000.0);
    fflush(g_out);
    g_last = now_ms();
}
#define ON(bit) (g_out && (g_modes & (bit)))

/* ------------------------------------------------------------------ */
/* counters                                                            */
/* ------------------------------------------------------------------ */
static unsigned long c_draws, c_verts, c_tris, c_binds, c_progs, c_bufup;
static unsigned long c_texup, c_texkb, c_copytex, c_readpix, c_finish, c_flush, c_fbo;
static unsigned long c_compile, c_link, c_shsrc, c_newprog;
static double d_draw_us, d_swap_us, d_worst_us, d_finish_us;
static unsigned long d_worst_n; static unsigned d_worst_mode;

/* TSP_WORSTTEX: which texture/program was bound during the frame's
   slowest draw. A 4-vertex GL_QUADS draw hit 237ms twice and left swap
   blocking at 55-66ms for ~24 frames after - that can only be a sync,
   and the texture identity is the missing piece. */
static unsigned d_worst_tex, d_worst_prog;

/* TSP_CPUTIME: wall time alone cannot tell a 235ms computation from a 235ms
   block. CLOCK_THREAD_CPUTIME_ID only advances while this thread is on-CPU,
   so worst_cpu_us ~= worst_us means the thread is burning CPU (something in
   gl4es or the driver is computing), while worst_cpu_us ~= 0 means it is
   asleep waiting on a fence, the GPU, or a kernel allocation. Those need
   completely different fixes. */
static double d_worst_cpu_us;
static double now_cpu_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) != 0) return 0.0;
    return ts.tv_sec*1000.0 + ts.tv_nsec/1000000.0;
}

/* tracked GL state for DRAWSTATE */
static int    s_blend, s_depth, s_cull, s_dmask = 1;
static GLenum s_src = 1, s_dst = 0;
static GLuint s_tex, s_prog;

#define MAXREC 256
struct rec {
    int blend, depth, cull, dmask;
    GLenum src, dst, mode;
    GLuint tex, prog;
    long n; unsigned long count;
};
static struct rec g_rec[MAXREC];
static int g_nrec = 0;

static void rec_draw(GLenum mode, GLsizei count)
{
    int i;
    if (!ON(M_DRAWSTATE) || g_dsdone >= g_dsmax) return;
    for (i = 0; i < g_nrec; i++) {
        struct rec* r = &g_rec[i];
        if (r->blend==s_blend && r->depth==s_depth && r->cull==s_cull
            && r->dmask==s_dmask && r->src==s_src && r->dst==s_dst
            && r->tex==s_tex && r->prog==s_prog
            && r->mode==mode && r->n==(long)count) { r->count++; return; }
    }
    if (g_nrec >= MAXREC) return;
    g_rec[g_nrec].blend=s_blend; g_rec[g_nrec].depth=s_depth;
    g_rec[g_nrec].cull=s_cull;   g_rec[g_nrec].dmask=s_dmask;
    g_rec[g_nrec].src=s_src;     g_rec[g_nrec].dst=s_dst;
    g_rec[g_nrec].tex=s_tex;     g_rec[g_nrec].prog=s_prog;
    g_rec[g_nrec].mode=mode;     g_rec[g_nrec].n=(long)count;
    g_rec[g_nrec].count=1; g_nrec++;
}

/* ------------------------------------------------------------------ */
#define REAL(name, rettype, params)                                      \
    static rettype (*real_##name) params = NULL;                         \
    static void resolve_##name(void) {                                   \
        if (!real_##name)                                                \
            real_##name = (rettype (*) params) dlsym(RTLD_NEXT, #name);  \
    }

REAL(glBindBuffer,             void,   (GLenum,GLuint))
REAL(glBufferData,             void,   (GLenum,long,const GLvoid*,GLenum))
REAL(glGenBuffers,             void,   (GLsizei,GLuint*))
REAL(glDepthMask,              void,   (GLboolean))
REAL(glUseProgram,             void,   (GLuint))
REAL(glScissor,       void, (GLint,GLint,GLsizei,GLsizei))
REAL(glEnable,                 void,   (GLenum))
REAL(glDisable,                void,   (GLenum))
REAL(glDrawArrays,             void,   (GLenum,GLint,GLsizei))
REAL(glGetBooleanv,void,   (GLenum,GLboolean*))
REAL(glVertexAttribPointer,void,   (GLuint,GLint,GLenum,GLboolean,GLsizei,const void*))
REAL(glEnableVertexAttribArray,void,   (GLuint))
REAL(glDisableVertexAttribArray,void,   (GLuint))
REAL(glGetVertexAttribiv,void,   (GLuint,GLenum,GLint*))
REAL(glGetVertexAttribPointerv,void,   (GLuint,GLenum,void**))
REAL(glIsEnabled,GLboolean, (GLenum))
REAL(glColorMask,void,   (GLboolean,GLboolean,GLboolean,GLboolean))
REAL(glGetError,GLenum, (void))
REAL(glGetIntegerv,void,   (GLenum,GLint*))
REAL(glDeleteBuffers,          void,   (GLsizei,const GLuint*))
REAL(glDrawElements,           void,   (GLenum,GLsizei,GLenum,const GLvoid*))
REAL(glBindTexture,            void,   (GLenum,GLuint))
REAL(glActiveTexture,          void,   (GLenum))
REAL(glGenTextures,            void,   (GLsizei,GLuint*))
REAL(glDeleteTextures,         void,   (GLsizei,const GLuint*))
REAL(glBlendFunc,              void,   (GLenum,GLenum))
REAL(glBufferSubData,          void,   (GLenum,long,long,const GLvoid*))
REAL(glTexImage2D,             void,   (GLenum,GLint,GLint,GLsizei,GLsizei,GLint,GLenum,GLenum,const GLvoid*))
REAL(glCompressedTexImage2D,   void,   (GLenum,GLint,GLenum,GLsizei,GLsizei,GLint,GLsizei,const GLvoid*))
REAL(glTexSubImage2D,          void,   (GLenum,GLint,GLint,GLint,GLsizei,GLsizei,GLenum,GLenum,const GLvoid*))
REAL(glCopyTexSubImage2D,      void,   (GLenum,GLint,GLint,GLint,GLint,GLint,GLsizei,GLsizei))
REAL(glReadPixels,             void,   (GLint,GLint,GLsizei,GLsizei,GLenum,GLenum,GLvoid*))
REAL(glFinish,                 void,   (void))
REAL(glFlush,                  void,   (void))
REAL(glBindFramebuffer,        void,   (GLenum,GLuint))
REAL(glFramebufferTexture2D,   void,   (GLenum,GLenum,GLenum,GLuint,GLint))
REAL(glCheckFramebufferStatus, GLenum, (GLenum))
REAL(glCompileShader,          void,   (GLuint))
REAL(glLinkProgram,            void,   (GLuint))
REAL(glShaderSource,           void,   (GLuint,GLsizei,const char* const*,const GLint*))
REAL(glCreateProgram,          GLuint, (void))
REAL(glDeleteProgram,          void,   (GLuint))
REAL(glGetString,              const unsigned char*, (GLenum))
REAL(SDL_GL_SwapWindow,        void,   (void*))

/* ------------------------------------------------------------------ */
/* MEMTRACE (mode 512) accounting                                      */
/*                                                                     */
/* Separate binding state from s_tex on purpose. s_tex is "last texture */
/* bound to GL_TEXTURE_2D on any unit" and DRAWSTATE/TEXMAP/worst_tex   */
/* have always meant that - changing it would change output you have    */
/* already reasoned from. mt_bound_tex[] is per-unit, which is what     */
/* correct upload accounting needs.                                     */
/* ------------------------------------------------------------------ */
#define MT_MAXID 16384
#define MT_UNITS 8

static unsigned int mt_tex_total[MT_MAXID];   /* all levels             */
static unsigned int mt_buf[MT_MAXID];
static unsigned long long mt_tex_live, mt_buf_live;
static unsigned long long mt_up_bytes, mt_del_bytes;
static long mt_tex_n, mt_buf_n, mt_prog_n;
static long mt_tex_created, mt_tex_deleted;
static GLuint mt_unit;
static GLuint mt_bound_tex[MT_UNITS];
static GLuint mt_bound_arr, mt_bound_elem;
static double mt_t0, mt_lastemit;
static int    mt_first = 1;

/* Approximate by design - gl4es may convert the format underneath us, so
   this tracks what the engine submitted, not what the driver stored. */
static unsigned mt_texel_bytes(GLenum format, GLenum type)
{
    unsigned comp;
    switch (format) {
        case 0x1906: comp = 1; break;   /* GL_ALPHA           */
        case 0x1907: comp = 3; break;   /* GL_RGB             */
        case 0x1908: comp = 4; break;   /* GL_RGBA            */
        case 0x1909: comp = 1; break;   /* GL_LUMINANCE       */
        case 0x190A: comp = 2; break;   /* GL_LUMINANCE_ALPHA */
        case 0x80E0: comp = 3; break;   /* GL_BGR             */
        case 0x80E1: comp = 4; break;   /* GL_BGRA            */
        case 0x1902: comp = 1; break;   /* GL_DEPTH_COMPONENT */
        default:     comp = 4; break;
    }
    switch (type) {
        case 0x1400: case 0x1401: return comp;      /* BYTE / UNSIGNED_BYTE  */
        case 0x8363: case 0x8033: case 0x8034: return 2; /* packed shorts    */
        case 0x1402: case 0x1403: return comp * 2;  /* SHORT / USHORT        */
        case 0x1404: case 0x1405: return comp * 4;  /* INT / UINT            */
        case 0x1406: return comp * 4;               /* FLOAT                 */
        default:     return comp;
    }
}

/* Level 0 respecifies the texture, so replace. Higher levels are mips, so
   accumulate. Keeps tex_live honest when OpenMW re-uploads a texture. */
static void mt_tex_account(GLint level, unsigned long long bytes)
{
    GLuint id;
    if (mt_unit >= MT_UNITS) return;
    id = mt_bound_tex[mt_unit];
    if (!id || id >= MT_MAXID) return;
    mt_up_bytes += bytes;
    if (level == 0) {
        unsigned int old = mt_tex_total[id];
        if (mt_tex_live >= old) mt_tex_live -= old; else mt_tex_live = 0;
        mt_tex_total[id] = (unsigned int)bytes;
        mt_tex_live += bytes;
    } else {
        mt_tex_total[id] += (unsigned int)bytes;
        mt_tex_live      += bytes;
    }
}

static long long mt_field(const char* buf, const char* key)
{
    const char* p = strstr(buf, key);
    if (!p) return -1;
    p += strlen(key);
    while (*p == ' ' || *p == '\t') p++;
    return atoll(p);
}

static void mt_emit(void)
{
    char buf[4096];
    FILE* f;
    size_t n = 0;
    long long total=-1, mfree=-1, mavail=-1, bufs=-1, cached=-1, shmem=-1;
    long long slab=-1, sunrecl=-1, kstack=-1, ptab=-1, vmal=-1, anon=-1;
    long long unacct=-1, rss=-1;

    f = fopen("/proc/meminfo", "r");
    if (f) { n = fread(buf, 1, sizeof(buf)-1, f); fclose(f); }
    buf[n] = 0;
    if (n) {
        total   = mt_field(buf, "MemTotal:");
        mfree   = mt_field(buf, "MemFree:");
        mavail  = mt_field(buf, "MemAvailable:");
        bufs    = mt_field(buf, "Buffers:");
        cached  = mt_field(buf, "\nCached:");     /* not SwapCached */
        shmem   = mt_field(buf, "Shmem:");
        slab    = mt_field(buf, "\nSlab:");
        sunrecl = mt_field(buf, "SUnreclaim:");
        kstack  = mt_field(buf, "KernelStack:");
        ptab    = mt_field(buf, "PageTables:");
        vmal    = mt_field(buf, "VmallocUsed:");
        anon    = mt_field(buf, "AnonPages:");
        if (total>=0 && mfree>=0 && bufs>=0 && cached>=0 && slab>=0
            && kstack>=0 && ptab>=0 && vmal>=0 && anon>=0)
            unacct = total - mfree - bufs - cached - slab - kstack - ptab - vmal - anon;
    }
    f = fopen("/proc/self/status", "r");
    if (f) {
        char line[256];
        while (fgets(line, sizeof(line), f))
            if (strncmp(line, "VmRSS:", 6) == 0) { rss = atoll(line+6); break; }
        fclose(f);
    }

    fprintf(g_out,
        "MEMTRACE t=%.0f f=%lu tex_live_kb=%llu buf_live_kb=%llu tex_n=%ld buf_n=%ld "
        "prog_n=%ld up_mb=%llu del_mb=%llu texcre=%ld texdel=%ld rss_kb=%lld "
        "memavail_kb=%lld memfree_kb=%lld cached_kb=%lld shmem_kb=%lld "
        "sunrecl_kb=%lld unacct_kb=%lld\n",
        (now_ms() - mt_t0) / 1000.0, g_frame,
        mt_tex_live/1024ULL, mt_buf_live/1024ULL,
        mt_tex_n, mt_buf_n, mt_prog_n,
        mt_up_bytes/1048576ULL, mt_del_bytes/1048576ULL,
        mt_tex_created, mt_tex_deleted,
        rss, mavail, mfree, cached, shmem, sunrecl, unacct);
    fflush(g_out);
}

/* ------------------------------------------------------------------ */
/* draws                                                               */
/* ------------------------------------------------------------------ */
static void count_prim(GLenum mode, GLsizei count)
{
    c_draws++;
    c_verts += (unsigned long)(count > 0 ? count : 0);
    if (count >= 3) {
        if (mode == GL_TRIANGLES) c_tris += (unsigned long)(count/3);
        else if (mode == GL_TRIANGLE_STRIP || mode == GL_TRIANGLE_FAN)
            c_tris += (unsigned long)(count-2);
    }
}

void glDrawArrays(GLenum mode, GLint first, GLsizei count)
{
    double t0 = 0, dt, c0 = 0, cdt;
    diag_init();
    resolve_glDrawArrays();
    count_prim(mode, count);
    rec_draw(mode, count);
    if (ON(M_TIMING)) { t0 = now_ms(); c0 = now_cpu_ms(); }
    if (real_glDrawArrays) real_glDrawArrays(mode, first, count);
    if (ON(M_TIMING)) {
        dt = (now_ms()-t0)*1000.0; cdt = (now_cpu_ms()-c0)*1000.0; d_draw_us += dt;
        if (dt > d_worst_us) { d_worst_us=dt; d_worst_n=(unsigned long)count; d_worst_mode=mode;
                               d_worst_tex=s_tex; d_worst_prog=s_prog; d_worst_cpu_us=cdt; }
    }
}

void glDrawElements(GLenum mode, GLsizei count, GLenum type, const GLvoid* idx)
{
    double t0 = 0, dt, c0 = 0, cdt;
    diag_init();
    resolve_glDrawElements();
    count_prim(mode, count);
    rec_draw(mode, count);
    if (ON(M_TIMING)) { t0 = now_ms(); c0 = now_cpu_ms(); }
    if (real_glDrawElements) real_glDrawElements(mode, count, type, idx);
    if (ON(M_TIMING)) {
        dt = (now_ms()-t0)*1000.0; cdt = (now_cpu_ms()-c0)*1000.0; d_draw_us += dt;
        if (dt > d_worst_us) { d_worst_us=dt; d_worst_n=(unsigned long)count; d_worst_mode=mode;
                               d_worst_tex=s_tex; d_worst_prog=s_prog; d_worst_cpu_us=cdt; }
    }
}

/* ------------------------------------------------------------------ */
/* state tracking                                                      */
/* ------------------------------------------------------------------ */
void glBindTexture(GLenum t, GLuint tex)
{
    diag_init();
    resolve_glBindTexture();
    c_binds++;
    if (t == GL_TEXTURE_2D) {
        s_tex = tex;                                  /* unchanged meaning */
        if (mt_unit < MT_UNITS) mt_bound_tex[mt_unit] = tex;
    }
    if (real_glBindTexture) real_glBindTexture(t, tex);
}

void glActiveTexture(GLenum unit)
{
    diag_init();
    resolve_glActiveTexture();
    { GLuint u = (GLuint)(unit - GL_TEXTURE0); mt_unit = (u < MT_UNITS) ? u : 0; }
    if (real_glActiveTexture) real_glActiveTexture(unit);
}

void glUseProgram(GLuint p)
{
    diag_init();
    resolve_glUseProgram();
    c_progs++; s_prog = p;
    if (real_glUseProgram) real_glUseProgram(p);
}

void glEnable(GLenum c)
{
    diag_init();
    resolve_glEnable();
    if (c==GL_BLEND) s_blend=1; else if (c==GL_DEPTH_TEST) s_depth=1;
    else if (c==GL_CULL_FACE) s_cull=1;
    if (real_glEnable) real_glEnable(c);
}

void glDisable(GLenum c)
{
    diag_init();
    resolve_glDisable();
    if (c==GL_BLEND) s_blend=0; else if (c==GL_DEPTH_TEST) s_depth=0;
    else if (c==GL_CULL_FACE) s_cull=0;
    if (real_glDisable) real_glDisable(c);
}

void glBlendFunc(GLenum s, GLenum d)
{
    diag_init();
    resolve_glBlendFunc();
    s_src=s; s_dst=d;
    if (real_glBlendFunc) real_glBlendFunc(s,d);
}

void glDepthMask(GLboolean f)
{
    diag_init();
    resolve_glDepthMask();
    s_dmask = f ? 1 : 0;
    if (real_glDepthMask) real_glDepthMask(f);
}

/* ------------------------------------------------------------------ */
/* buffers - counted, and sized for MEMTRACE                           */
/*                                                                     */
/* LIBGL_TSP_ORPHAN used to live in glBufferSubData below, injecting a  */
/* glBufferData(NULL) orphan call. That is an intervention and it now   */
/* lives in libtsp_warm.so. This file only counts.                      */
/* ------------------------------------------------------------------ */
void glGenBuffers(GLsizei n, GLuint* ids)
{
    diag_init();
    resolve_glGenBuffers();
    if (real_glGenBuffers) real_glGenBuffers(n, ids);
    if (ids) { GLsizei i; for (i=0;i<n;i++) { mt_buf_n++;
        if (ids[i] < MT_MAXID) mt_buf[ids[i]] = 0; } }
}

void glDeleteBuffers(GLsizei n, const GLuint* ids)
{
    diag_init();
    resolve_glDeleteBuffers();
    if (ids) {
        unsigned long long freed = 0; GLsizei i;
        for (i=0;i<n;i++) {
            GLuint id = ids[i];
            mt_buf_n--;
            if (id < MT_MAXID && mt_buf[id]) {
                freed += mt_buf[id];
                if (mt_buf_live >= mt_buf[id]) mt_buf_live -= mt_buf[id]; else mt_buf_live = 0;
                mt_buf[id] = 0;
            }
        }
        mt_del_bytes += freed;
        if (ON(M_MEMTRACE) && freed >= mt_event_bytes)
            fprintf(g_out, "MTFREE buf f=%lu n=%d freed_kb=%llu buf_live_kb=%llu\n",
                    g_frame, (int)n, freed/1024ULL, mt_buf_live/1024ULL);
    }
    if (real_glDeleteBuffers) real_glDeleteBuffers(n, ids);
}

void glBindBuffer(GLenum target, GLuint id)
{
    diag_init();
    resolve_glBindBuffer();
    if (target == GL_ARRAY_BUFFER)              mt_bound_arr  = id;
    else if (target == GL_ELEMENT_ARRAY_BUFFER) mt_bound_elem = id;
    if (real_glBindBuffer) real_glBindBuffer(target, id);
}

void glBufferData(GLenum t, long sz, const GLvoid* d, GLenum u)
{
    diag_init();
    resolve_glBufferData(); c_bufup++;
    if (sz > 0) {
        GLuint id = (t == GL_ELEMENT_ARRAY_BUFFER) ? mt_bound_elem : mt_bound_arr;
        if (id && id < MT_MAXID) {
            unsigned int old = mt_buf[id];
            if (mt_buf_live >= old) mt_buf_live -= old; else mt_buf_live = 0;
            mt_buf[id]   = (unsigned int)sz;
            mt_buf_live += (unsigned long long)sz;
            mt_up_bytes += (unsigned long long)sz;
        }
    }
    if (real_glBufferData) real_glBufferData(t,sz,d,u);
}

void glBufferSubData(GLenum t, long o, long sz, const GLvoid* d)
{
    diag_init();
    resolve_glBufferSubData(); c_bufup++;
    if (real_glBufferSubData) real_glBufferSubData(t,o,sz,d);
}

/* ------------------------------------------------------------------ */
/* textures - counted, mapped, and sized for MEMTRACE                  */
/* ------------------------------------------------------------------ */
void glGenTextures(GLsizei n, GLuint* ids)
{
    diag_init();
    resolve_glGenTextures();
    if (real_glGenTextures) real_glGenTextures(n, ids);
    if (ids) { GLsizei i; for (i=0;i<n;i++) { mt_tex_n++; mt_tex_created++;
        if (ids[i] < MT_MAXID) mt_tex_total[ids[i]] = 0; } }
}

void glDeleteTextures(GLsizei n, const GLuint* ids)
{
    diag_init();
    resolve_glDeleteTextures();
    if (ids) {
        unsigned long long freed = 0; GLsizei i;
        for (i=0;i<n;i++) {
            GLuint id = ids[i];
            mt_tex_n--; mt_tex_deleted++;
            if (id < MT_MAXID && mt_tex_total[id]) {
                freed += mt_tex_total[id];
                if (mt_tex_live >= mt_tex_total[id]) mt_tex_live -= mt_tex_total[id];
                else mt_tex_live = 0;
                mt_tex_total[id] = 0;
            }
        }
        mt_del_bytes += freed;
        /* A large batch is a releaseGLObjects or a cache purge. Logged as a
           discrete event so it is a point on the timeline you can line up
           against MemAvailable, not an invisible step in a curve. */
        if (ON(M_MEMTRACE) && freed >= mt_event_bytes)
            fprintf(g_out, "MTFREE tex f=%lu n=%d freed_kb=%llu tex_live_kb=%llu\n",
                    g_frame, (int)n, freed/1024ULL, mt_tex_live/1024ULL);
    }
    if (real_glDeleteTextures) real_glDeleteTextures(n, ids);
}

void glTexImage2D(GLenum t, GLint l, GLint ifmt, GLsizei w, GLsizei h,
                  GLint b, GLenum f, GLenum ty, const GLvoid* d)
{
    diag_init();
    resolve_glTexImage2D();
    c_texup++; if (d) c_texkb += (unsigned long)w*(unsigned long)h*4/1024;
    if (ON(M_TEXMAP) && l == 0)
        fprintf(g_out, "TEXMAP id=%u %dx%d ifmt=0x%x fmt=0x%x type=0x%x frame=%lu\n",
                s_tex, w, h, (unsigned)ifmt, f, ty, g_frame);
    if (t == GL_TEXTURE_2D && w > 0 && h > 0)
        mt_tex_account(l, (unsigned long long)w * (unsigned long long)h
                          * mt_texel_bytes(f, ty));
    if (real_glTexImage2D) real_glTexImage2D(t,l,ifmt,w,h,b,f,ty,d);
}

void glCompressedTexImage2D(GLenum t, GLint l, GLenum ifmt, GLsizei w, GLsizei h,
                            GLint b, GLsizei imageSize, const GLvoid* d)
{
    diag_init();
    resolve_glCompressedTexImage2D();
    c_texup++; if (imageSize > 0) c_texkb += (unsigned long)imageSize/1024;
    /* imageSize is exact - no format guessing needed */
    if (t == GL_TEXTURE_2D && imageSize > 0)
        mt_tex_account(l, (unsigned long long)imageSize);
    if (real_glCompressedTexImage2D)
        real_glCompressedTexImage2D(t,l,ifmt,w,h,b,imageSize,d);
}

void glTexSubImage2D(GLenum t, GLint l, GLint xo, GLint yo, GLsizei w,
                     GLsizei h, GLenum f, GLenum ty, const GLvoid* d)
{
    diag_init();
    resolve_glTexSubImage2D();
    c_texup++; if (d) c_texkb += (unsigned long)w*(unsigned long)h*4/1024;
    /* deliberately not counted in tex_live: a sub-image rewrites pixels
       inside an existing allocation, it does not allocate */
    if (real_glTexSubImage2D) real_glTexSubImage2D(t,l,xo,yo,w,h,f,ty,d);
}

void glCopyTexSubImage2D(GLenum t, GLint l, GLint xo, GLint yo,
                         GLint x, GLint y, GLsizei w, GLsizei h)
{
    diag_init();
    resolve_glCopyTexSubImage2D(); c_copytex++;
    if (real_glCopyTexSubImage2D) real_glCopyTexSubImage2D(t,l,xo,yo,x,y,w,h);
}

void glReadPixels(GLint x, GLint y, GLsizei w, GLsizei h,
                  GLenum f, GLenum t, GLvoid* d)
{
    diag_init();
    resolve_glReadPixels(); c_readpix++;
    if (real_glReadPixels) real_glReadPixels(x,y,w,h,f,t,d);
}

void glFinish(void) { diag_init(); resolve_glFinish(); c_finish++; if (real_glFinish) real_glFinish(); }
void glFlush(void)  { diag_init(); resolve_glFlush();  c_flush++;  if (real_glFlush)  real_glFlush();  }

/* ------------------------------------------------------------------ */
/* framebuffers                                                        */
/* ------------------------------------------------------------------ */
void glBindFramebuffer(GLenum target, GLuint fb)
{
    diag_init();
    resolve_glBindFramebuffer(); c_fbo++;
    if (ON(M_FBO)) fprintf(g_out, "FBO bind target=0x%x fb=%u\n", target, fb);
    if (real_glBindFramebuffer) real_glBindFramebuffer(target, fb);
}

void glFramebufferTexture2D(GLenum tg, GLenum att, GLenum tt, GLuint tex, GLint lv)
{
    diag_init();
    resolve_glFramebufferTexture2D();
    if (ON(M_FBO)) fprintf(g_out, "FBO attach target=0x%x att=0x%x tex=%u level=%d\n",
                           tg, att, tex, lv);
    if (real_glFramebufferTexture2D) real_glFramebufferTexture2D(tg,att,tt,tex,lv);
}

GLenum glCheckFramebufferStatus(GLenum target)
{
    GLenum rv = GL_FB_COMPLETE;
    diag_init();
    resolve_glCheckFramebufferStatus();
    if (real_glCheckFramebufferStatus) rv = real_glCheckFramebufferStatus(target);
    if (ON(M_FBO)) fprintf(g_out, "FBO status target=0x%x ret=0x%x%s\n", target, rv,
                           rv==GL_FB_COMPLETE ? "" : "   <<<< NOT COMPLETE");
    return rv;
}

/* ------------------------------------------------------------------ */
/* shaders                                                             */
/*                                                                     */
/* The SCACHE branch that used to live in glLinkProgram is gone - it    */
/* replaced the link with a disk read, which is a fix, not a            */
/* measurement. libtsp_warm.so owns it. What stays is the LINK timing,  */
/* which is what proved the ~137ms link plus ~236ms deferred compile in */
/* the first place.                                                     */
/* ------------------------------------------------------------------ */
void glCompileShader(GLuint s)
{
    diag_init();
    resolve_glCompileShader(); c_compile++;
    if (real_glCompileShader) real_glCompileShader(s);
}



/* TSP_LINKTIME: gl4es links eagerly (program.c:789) yet the ~240ms lands later
   inside the first draw using the program - Mali defers the backend compile to
   first use. Small link_us here plus a 240ms first draw confirms that. */

/* ------------------------------------------------------------------ */
/* TSP_SHADERCACHE (mode 1024)                                         */
/*                                                                     */
/* Mali compiles GLSL lazily and expensively: ~137ms inside            */
/* glLinkProgram plus ~236ms deferred into the first draw using the    */
/* program. Measured with CPU-time instrumentation (worst_cpu_us ==    */
/* worst_us), so it is real computation, not a stall on the GPU.       */
/*                                                                     */
/* OpenMW builds these programs on demand during play, which is why    */
/* the first swing at a creature type or the first status effect       */
/* costs a third of a second and every one after is free.              */
/*                                                                     */
/* This caches the linked binary to disk keyed by shader source hash,  */
/* so the compiler only ever runs once per program per install.        */
/* ------------------------------------------------------------------ */

#ifndef GL_PROGRAM_BINARY_LENGTH
#define GL_PROGRAM_BINARY_LENGTH 0x8741
#endif
#ifndef GL_LINK_STATUS
#define GL_LINK_STATUS 0x8B82
#endif
#ifndef GL_NUM_PROGRAM_BINARY_FORMATS
#define GL_NUM_PROGRAM_BINARY_FORMATS 0x87FE
#endif

#define SC_MAXID   8192
#define SC_MAXSRC  262144

static char  *sc_src[SC_MAXID];        /* shader id -> source text      */
static unsigned long long sc_prog[SC_MAXID]; /* program id -> running hash */
static int    sc_ready;
static char   sc_dir[512];

/* FNV-1a 64. Cheap, no dependencies, ample for keying a few hundred
   shader sources. */
static unsigned long long sc_hash(unsigned long long h, const char *s)
{
    if (!s) return h;
    while (*s) { h ^= (unsigned char)(*s++); h *= 1099511628211ULL; }
    return h;
}

static void sc_init(void)
{
    const char *e;
    if (sc_ready) return;
    sc_ready = 1;
    e = getenv("LIBGL_TSP_SHADERCACHE");
    if (!e || !e[0]) e = "/mnt/SDCARD/data/ports/openmw51/shadercache";
    snprintf(sc_dir, sizeof(sc_dir), "%s", e);
    mkdir(sc_dir, 0777);
    if (g_out) { fprintf(g_out, "SCACHE dir=%s\n", sc_dir); fflush(g_out); }
}

static void sc_path(char *out, size_t n, unsigned long long key)
{
    snprintf(out, n, "%s/%016llx.bin", sc_dir, key);
}

/* Try to restore a previously compiled binary. Returns 1 on success. */

/* ------------------------------------------------------------------ */
/* TSP_SCWARM2: deferred, state-preserving shader warm-up              */
/*                                                                     */
/* Restoring a cached binary skips the link but Mali still defers its  */
/* final per-program work to the first draw. This forces that work at  */
/* a frame boundary instead, using a scratch VBO and generic vertex    */
/* attribute 0 - never the fixed-function client-state path, which is  */
/* what broke rendering on the first attempt.                          */
/* ------------------------------------------------------------------ */

#define SCW_ARRAY_BUFFER            0x8892
#define SCW_STATIC_DRAW             0x88E4
#define SCW_ARRAY_BUFFER_BINDING    0x8894
#define SCW_CURRENT_PROGRAM         0x8B8D
#define SCW_VAA_ENABLED             0x8622
#define SCW_VAA_SIZE                0x8623
#define SCW_VAA_STRIDE              0x8624
#define SCW_VAA_TYPE                0x8625
#define SCW_VAA_NORMALIZED          0x886A
#define SCW_VAA_BUFFER_BINDING      0x889F
#define SCW_SCISSOR_TEST            0x0C11
#define SCW_SCISSOR_BOX             0x0C10
#define SCW_DEPTH_WRITEMASK         0x0B72
#define SCW_COLOR_WRITEMASK         0x0C23
#define SCW_CULL_FACE               0x0B44
#define SCW_FLOAT                   0x1406
#define SCW_TRIANGLES               0x0004

#define SCW_QMAX 64
static GLuint scw_queue[SCW_QMAX];
static int    scw_qn;
static GLuint scw_vbo;
static int    scw_off;      /* LIBGL_TSP_NOWARM */
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
    GLint  aEnabled = 0, aSize = 4, aType = SCW_FLOAT, aNorm = 0, aStride = 0, aBuf = 0;
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
        real_glGetVertexAttribPointerv(0, 0x8645 /* POINTER */, &aPtr);
    if (real_glIsEnabled) {
        scEn   = real_glIsEnabled(SCW_SCISSOR_TEST);
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
    if (real_glScissor) { real_glScissor(0, 0, 1, 1); real_glEnable(SCW_SCISSOR_TEST); }
    if (real_glDepthMask) real_glDepthMask(0);
    if (real_glColorMask) real_glColorMask(0, 0, 0, 0);
    if (real_glDisable)   real_glDisable(SCW_CULL_FACE);

    real_glUseProgram(prog);
    real_glBindBuffer(SCW_ARRAY_BUFFER, scw_vbo);
    if (real_glEnableVertexAttribArray) real_glEnableVertexAttribArray(0);
    real_glVertexAttribPointer(0, 2, SCW_FLOAT, 0, 0, (const void*)0);
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
    if (!scEn && real_glDisable)  real_glDisable(SCW_SCISSOR_TEST);
    if (scEn  && real_glEnable)   real_glEnable(SCW_SCISSOR_TEST);
    if (cullEn && real_glEnable)  real_glEnable(SCW_CULL_FACE);
    if (real_glGetError) while (real_glGetError() != 0) { }

    if (g_out) {
        fprintf(g_out, "SCWARM prog=%u %.0fus\n", prog, (now_ms()-t0)*1000.0);
        fflush(g_out);
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

/* ------------------------------------------------------------------ */
/* TSP_SCPRELOAD (mode 2048)                                           */
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
    if (!ON(M_SCPRELOAD)) return;
    env = getenv("LIBGL_TSP_NOPRELOAD");
    if (env && env[0] && env[0] != '0') return;

    sc_init();
    resolve_glCreateProgram();
    resolve_glProgramBinary();
    resolve_glGetProgramiv();
    if (!real_glCreateProgram || !real_glProgramBinary) {
        if (g_out) { fprintf(g_out, "SCPRE unavailable\n"); fflush(g_out); }
        return;
    }

    d = opendir(sc_dir);
    if (!d) {
        if (g_out) { fprintf(g_out, "SCPRE no dir %s\n", sc_dir); fflush(g_out); }
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
        snprintf(path, sizeof(path), "%s/%s", sc_dir, e->d_name);
        f = fopen(path, "rb");
        if (!f) continue;
        if (fread(&fmt, sizeof(fmt), 1, f) != 1) { fclose(f); continue; }
        fseek(f, 0, SEEK_END);
        len = ftell(f) - (long)sizeof(fmt);
        fseek(f, sizeof(fmt), SEEK_SET);
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
            if (g_out) fprintf(g_out, "SCPRE file=%s REJECTED\n", e->d_name);
            continue;
        }

        t0 = now_ms();
        scw_warm_one(prog);
        twarm = (now_ms() - t0) * 1000.0;

        /* keep it alive - deleting might discard whatever the driver built */
        scp_progs[scp_n++] = prog;

        if (g_out) {
            fprintf(g_out, "SCPRE file=%s prog=%u load=%.0fus warm=%.0fus\n",
                    e->d_name, prog, tload, twarm);
            fflush(g_out);
        }
    }
    closedir(d);

    if (g_out) {
        fprintf(g_out, "SCPRE done n=%d total=%.0fms\n",
                scp_n, now_ms() - t_all);
        fflush(g_out);
    }
}


static int sc_try_load(GLuint prog, unsigned long long key, double *us)
{
    char path[600];
    FILE *f;
    long len;
    void *buf;
    GLenum fmt;
    GLint ok = 0;
    double t0;

    sc_path(path, sizeof(path), key);
    f = fopen(path, "rb");
    if (!f) return 0;
    if (fread(&fmt, sizeof(fmt), 1, f) != 1) { fclose(f); return 0; }
    fseek(f, 0, SEEK_END);
    len = ftell(f) - (long)sizeof(fmt);
    fseek(f, sizeof(fmt), SEEK_SET);
    if (len <= 0) { fclose(f); return 0; }
    buf = malloc((size_t)len);
    if (!buf) { fclose(f); return 0; }
    if (fread(buf, 1, (size_t)len, f) != (size_t)len) { free(buf); fclose(f); return 0; }
    fclose(f);

    resolve_glProgramBinary();
    resolve_glGetProgramiv();
    if (!real_glProgramBinary || !real_glGetProgramiv) { free(buf); return 0; }

    t0 = now_ms();
    real_glProgramBinary(prog, fmt, buf, (GLsizei)len);
    real_glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    *us = (now_ms() - t0) * 1000.0;
    free(buf);
    if (ok) scw_enqueue(prog);   /* TSP_SCWARM2: drained after swap */
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

    resolve_glGetProgramiv();
    resolve_glGetProgramBinary();
    if (!real_glGetProgramiv || !real_glGetProgramBinary) return -1;

    real_glGetProgramiv(prog, GL_PROGRAM_BINARY_LENGTH, &len);
    if (len <= 0) return -1;
    buf = malloc((size_t)len);
    if (!buf) return -1;

    t0 = now_ms();
    real_glGetProgramBinary(prog, len, &got, &fmt, buf);
    *us = (now_ms() - t0) * 1000.0;
    if (got <= 0) { free(buf); return -1; }

    /* write to a temp name then rename, so a crash mid-write cannot
       leave a truncated binary that the driver would reject next run */
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

/* TSP_SHADERCACHE: keep each shader's source so the program can be keyed
   by what it was actually built from. */
void glShaderSource(GLuint sh, GLsizei count, const GLchar* const* str, const GLint* len)
{
    diag_init();
    resolve_glShaderSource();
    if (ON(M_SCACHE) && sh < SC_MAXID && str) {
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

/* TSP_SHADERCACHE: fold each attached shader's source into the program key. */
void glAttachShader(GLuint prog, GLuint sh)
{
    diag_init();
    resolve_glAttachShader();
    if (ON(M_SCACHE) && prog < SC_MAXID && sh < SC_MAXID) {
        if (!sc_prog[prog]) sc_prog[prog] = 14695981039346656037ULL;
        sc_prog[prog] = sc_hash(sc_prog[prog], sc_src[sh]);
    }
    if (real_glAttachShader) real_glAttachShader(prog, sh);
}

void glLinkProgram(GLuint p)
{
    double t0, dt, sus = 0;
    unsigned long long key;
    diag_init();
    resolve_glLinkProgram();
    c_link++;

    /* TSP_SHADERCACHE: a hit here skips the Mali compiler entirely. */
    if (ON(M_SCACHE) && p < SC_MAXID && sc_prog[p]) {
        sc_init();
        key = sc_prog[p];
        if (sc_try_load(p, key, &sus)) {
            if (g_out) { fprintf(g_out, "SCACHE hit  prog=%u key=%016llx %.0fus\n",
                                 p, key, sus); fflush(g_out); }
            return;
        }
        t0 = now_ms();
        if (real_glLinkProgram) real_glLinkProgram(p);
        dt = (now_ms() - t0) * 1000.0;
        {
            long n = sc_save(p, key, &sus);
            if (g_out) {
                if (n > 0)
                    fprintf(g_out, "SCACHE miss prog=%u key=%016llx link=%.0fus save=%.0fus bytes=%ld\n",
                            p, key, dt, sus, n);
                else
                    fprintf(g_out, "SCACHE fail prog=%u key=%016llx link=%.0fus\n", p, key, dt);
                fflush(g_out);
            }
        }
        return;
    }

    t0 = now_ms();
    if (real_glLinkProgram) real_glLinkProgram(p);
    if (g_out) { fprintf(g_out, "LINK prog=%u %.0fus\n", p, (now_ms()-t0)*1000.0); fflush(g_out); }
}

GLuint glCreateProgram(void)
{
    diag_init();
    resolve_glCreateProgram(); c_newprog++; mt_prog_n++;
    return real_glCreateProgram ? real_glCreateProgram() : 0;
}

void glDeleteProgram(GLuint p)
{
    diag_init();
    resolve_glDeleteProgram(); mt_prog_n--;
    if (real_glDeleteProgram) real_glDeleteProgram(p);
}

/* ------------------------------------------------------------------ */
/* frame boundary                                                      */
/* ------------------------------------------------------------------ */

/* ------------------------------------------------------------------ */
/* TSP_PREWARM (mode 9)                                                */
/*                                                                     */
/* Walks the fixed-function state combinations gl4es has to generate a */
/* shader for, so the compiles land at startup rather than on the      */
/* first swing at a creature or the first status effect.               */
/*                                                                     */
/* Each combination is drawn into a 1x1 scissor rect so nothing is     */
/* visible. Cost per combination is logged - a combination that costs  */
/* ~235ms here is one that would otherwise have cost that mid-combat.  */
/* ------------------------------------------------------------------ */

REAL(glEnable,        void, (GLenum))
REAL(glDisable,       void, (GLenum))
REAL(glEnableClientState,  void, (GLenum))
REAL(glDisableClientState, void, (GLenum))
REAL(glVertexPointer,   void, (GLint,GLenum,GLsizei,const void*))
REAL(glColorPointer,    void, (GLint,GLenum,GLsizei,const void*))
REAL(glTexCoordPointer, void, (GLint,GLenum,GLsizei,const void*))
REAL(glAlphaFunc,     void, (GLenum,GLclampf))
REAL(glGenTextures,   void, (GLsizei,GLuint*))
REAL(glTexImage2D,    void, (GLenum,GLint,GLint,GLsizei,GLsizei,GLint,GLenum,GLenum,const void*))
REAL(glDeleteTextures,void, (GLsizei,const GLuint*))

#ifndef GL_QUADS
#define GL_QUADS 0x0007
#endif
#ifndef GL_ALPHA_TEST
#define GL_ALPHA_TEST 0x0BC0
#endif
#ifndef GL_LIGHTING
#define GL_LIGHTING 0x0B50
#endif
#ifndef GL_FOG
#define GL_FOG 0x0B60
#endif
#ifndef GL_VERTEX_ARRAY
#define GL_VERTEX_ARRAY 0x8074
#endif
#ifndef GL_COLOR_ARRAY
#define GL_COLOR_ARRAY 0x8076
#endif
#ifndef GL_TEXTURE_COORD_ARRAY
#define GL_TEXTURE_COORD_ARRAY 0x8078
#endif
#ifndef GL_SCISSOR_TEST
#define GL_SCISSOR_TEST 0x0C11
#endif

static int g_prewarm_done = 0;

#ifndef GL_TEXTURE0
#define GL_TEXTURE0 0x84C0
#endif
#ifndef GL_LIGHT0
#define GL_LIGHT0 0x4000
#endif
#ifndef GL_POSITION
#define GL_POSITION 0x1203
#endif
#ifndef GL_DIFFUSE
#define GL_DIFFUSE 0x1201
#endif
#ifndef GL_AMBIENT
#define GL_AMBIENT 0x1200
#endif
#ifndef GL_TRIANGLE_FAN
#define GL_TRIANGLE_FAN 0x0006
#endif
REAL(glClientActiveTexture, void, (GLenum))
REAL(glLightfv,             void, (GLenum,GLenum,const float*))
REAL(glProgramBinary,void,   (GLuint,GLenum,const void*,GLsizei))
REAL(glGetProgramBinary,void,   (GLuint,GLsizei,GLsizei*,GLenum*,void*))
REAL(glGetProgramiv,void,   (GLuint,GLenum,GLint*))
REAL(glAttachShader,void,   (GLuint,GLuint))
static void tsp_prewarm(void)
{
    /* Geometry is irrelevant to shader generation - one quad is enough. */
    static const float verts[]  = { 0,0, 1,0, 1,1, 0,1 };
    static const float cols[]   = { 1,1,1,1, 1,1,1,1, 1,1,1,1, 1,1,1,1 };
    static const float texco[]  = { 0,0, 1,0, 1,1, 0,1 };
    static const unsigned char px[4] = { 255, 255, 255, 255 };
    static const float lpos[4]  = { 1.0f, 1.0f, 1.0f, 0.0f };
    static const float ldif[4]  = { 0.8f, 0.8f, 0.8f, 1.0f };
    static const float lamb[4]  = { 0.2f, 0.2f, 0.2f, 1.0f };

    GLuint tex[8];
    int maxTex = 4, maxLight = 4;
    int ntex, nlight, useAlpha, useFog, i;
    int combos = 0, compiled = 0;
    double t_all0, t0, dt, worst = 0.0;
    char worstdesc[160];
    const char *e;

    resolve_glEnable(); resolve_glDisable();
    resolve_glEnableClientState(); resolve_glDisableClientState();
    resolve_glVertexPointer(); resolve_glColorPointer();
    resolve_glTexCoordPointer(); resolve_glScissor();
    resolve_glAlphaFunc(); resolve_glGenTextures();
    resolve_glTexImage2D(); resolve_glDeleteTextures();
    resolve_glDrawArrays(); resolve_glBindTexture();
    resolve_glActiveTexture(); resolve_glClientActiveTexture();
    resolve_glLightfv();

    if (!real_glEnable || !real_glDrawArrays || !real_glVertexPointer)
    {
        if (g_out) { fprintf(g_out, "PREWARM: required entry points missing, skipped\n"); fflush(g_out); }
        return;
    }
    if (!real_glActiveTexture || !real_glClientActiveTexture)
        maxTex = 1;   /* cannot drive multiple units without these */

    e = getenv("LIBGL_TSP_PREWARM_MAXTEX");
    if (e && e[0]) { maxTex = atoi(e); if (maxTex < 0) maxTex = 0; if (maxTex > 8) maxTex = 8; }
    e = getenv("LIBGL_TSP_PREWARM_MAXLIGHT");
    if (e && e[0]) { maxLight = atoi(e); if (maxLight < 0) maxLight = 0; if (maxLight > 8) maxLight = 8; }

    worstdesc[0] = 0;
    t_all0 = now_ms();

    if (g_out)
    {
        fprintf(g_out, "PREWARM start: texunits 0..%d, lights 0..%d, alpha x fog\n",
                maxTex, maxLight);
        fflush(g_out);
    }

    /* 1x1 scissor keeps all of this off screen */
    if (real_glScissor) { real_glScissor(0, 0, 1, 1); real_glEnable(GL_SCISSOR_TEST); }

    /* one white 1x1 texture per unit */
    for (i = 0; i < 8; i++) tex[i] = 0;
    if (real_glGenTextures && real_glTexImage2D && real_glBindTexture)
    {
        real_glGenTextures(maxTex > 0 ? maxTex : 1, tex);
        for (i = 0; i < maxTex; i++)
        {
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
        /* texture units */
        for (i = 0; i < (maxTex > 0 ? maxTex : 1); i++)
        {
            if (real_glActiveTexture) real_glActiveTexture(GL_TEXTURE0 + i);
            if (real_glClientActiveTexture) real_glClientActiveTexture(GL_TEXTURE0 + i);
            if (i < ntex)
            {
                real_glEnable(GL_TEXTURE_2D);
                if (tex[i] && real_glBindTexture) real_glBindTexture(GL_TEXTURE_2D, tex[i]);
                real_glEnableClientState(GL_TEXTURE_COORD_ARRAY);
                real_glTexCoordPointer(2, GL_FLOAT, 0, texco);
            }
            else
            {
                real_glDisable(GL_TEXTURE_2D);
                real_glDisableClientState(GL_TEXTURE_COORD_ARRAY);
            }
        }
        if (real_glActiveTexture) real_glActiveTexture(GL_TEXTURE0);
        if (real_glClientActiveTexture) real_glClientActiveTexture(GL_TEXTURE0);

        /* lights - configured, not just enabled, so they cannot be folded away */
        if (nlight > 0) real_glEnable(GL_LIGHTING); else real_glDisable(GL_LIGHTING);
        for (i = 0; i < 8; i++)
        {
            if (i < nlight)
            {
                if (real_glLightfv)
                {
                    real_glLightfv(GL_LIGHT0 + i, GL_POSITION, lpos);
                    real_glLightfv(GL_LIGHT0 + i, GL_DIFFUSE,  ldif);
                    real_glLightfv(GL_LIGHT0 + i, GL_AMBIENT,  lamb);
                }
                real_glEnable(GL_LIGHT0 + i);
            }
            else
                real_glDisable(GL_LIGHT0 + i);
        }

        if (useAlpha) { real_glEnable(GL_ALPHA_TEST); if (real_glAlphaFunc) real_glAlphaFunc(0x0204, 0.5f); }
        else            real_glDisable(GL_ALPHA_TEST);

        if (useFog) real_glEnable(GL_FOG); else real_glDisable(GL_FOG);

        t0 = now_ms();
        real_glDrawArrays(GL_TRIANGLE_FAN, 0, 4);
        dt = (now_ms() - t0) * 1000.0;   /* us */
        combos++;

        if (dt > 1000.0)
        {
            compiled++;
            if (g_out)
                fprintf(g_out, "PREWARM %9.0fus  ntex=%d nlight=%d alpha=%d fog=%d\n",
                        dt, ntex, nlight, useAlpha, useFog);
        }
        if (dt > worst)
        {
            worst = dt;
            snprintf(worstdesc, sizeof(worstdesc),
                     "ntex=%d nlight=%d alpha=%d fog=%d", ntex, nlight, useAlpha, useFog);
        }
    }

    /* restore */
    for (i = 0; i < (maxTex > 0 ? maxTex : 1); i++)
    {
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

    if (g_out)
    {
        fprintf(g_out, "PREWARM done: %d combinations, %d compiled, %.0fms total, worst %.0fus (%s)\n",
                combos, compiled, now_ms() - t_all0, worst,
                worstdesc[0] ? worstdesc : "none");
        fflush(g_out);
    }
}

void SDL_GL_SwapWindow(void* w)
{
    /* TSP_PREWARM: run once, on the first swap after a context exists. */
    if (!g_prewarm_done && ON(M_PREWARM))
    {
        g_prewarm_done = 1;
        tsp_prewarm();
    }

    double n, dt, s0;
    int i;
    diag_init();
    resolve_SDL_GL_SwapWindow();
    if (!g_out) { if (real_SDL_GL_SwapWindow) real_SDL_GL_SwapWindow(w);
    scp_preload();  /* TSP_SCPRELOAD */
    scw_drain();   /* TSP_SCWARM2 */ return; }

    n = now_ms(); dt = n - g_last; g_last = n;

    if ((g_modes & M_EXT) && g_frame == 1) {
        const unsigned char* e;
        resolve_glGetString();
        if (real_glGetString) {
            e = real_glGetString(GL_VENDOR);   fprintf(g_out, "EXT vendor=%s\n", e?(const char*)e:"?");
            e = real_glGetString(GL_RENDERER); fprintf(g_out, "EXT renderer=%s\n", e?(const char*)e:"?");
            e = real_glGetString(GL_EXTENSIONS);
            fprintf(g_out, "EXT extensions=%s\n", e?(const char*)e:"?");
        }
    }

    if ((g_modes & M_FRAME) && g_frame < (unsigned long)g_max) {
        fprintf(g_out, "f=%lu ms=%.1f fps=%.1f draws=%lu verts=%lu tris=%lu binds=%lu progs=%lu bufup=%lu",
                g_frame, dt, dt>0?1000.0/dt:0.0,
                c_draws, c_verts, c_tris, c_binds, c_progs, c_bufup);
        if (g_modes & M_SYNC)
            fprintf(g_out, " texup=%lu texkb=%lu copytex=%lu readpix=%lu finish=%lu flush=%lu fbo=%lu",
                    c_texup, c_texkb, c_copytex, c_readpix, c_finish, c_flush, c_fbo);
        if (g_modes & M_SHADER)
            fprintf(g_out, " compile=%lu link=%lu shsrc=%lu newprog=%lu",
                    c_compile, c_link, c_shsrc, c_newprog);
        if (g_modes & M_TIMING)
            fprintf(g_out, " draw_us=%.0f swap_us=%.0f worst_us=%.0f worst_n=%lu worst_mode=0x%x worst_tex=%u worst_prog=%u worst_cpu_us=%.0f",
                    d_draw_us, d_swap_us, d_worst_us, d_worst_n, d_worst_mode, d_worst_tex, d_worst_prog, d_worst_cpu_us);
        if (g_modes & M_FINISH)
            fprintf(g_out, " finish_us=%.0f", d_finish_us);
        fputc('\n', g_out);
        if ((g_frame & 0x3f) == 0) fflush(g_out);
    }

    if ((g_modes & M_DRAWSTATE) && dt > g_thresh
        && g_dsdone < g_dsmax && g_frame > 30) {
        fprintf(g_out, "\nDRAWSTATE f=%lu ms=%.1f draws=%lu distinct=%d\n",
                g_frame, dt, c_draws, g_nrec);
        for (i = 0; i < g_nrec; i++) {
            struct rec* r = &g_rec[i];
            fprintf(g_out,
                "  x%-4lu blend=%d src=0x%-4x dst=0x%-4x depth=%d dmask=%d cull=%d tex=%-4u prog=%-3u mode=0x%x n=%ld\n",
                r->count, r->blend, r->src, r->dst, r->depth, r->dmask,
                r->cull, r->tex, r->prog, r->mode, r->n);
        }
        fflush(g_out);
        g_dsdone++;
    }

    if (g_modes & M_MEMTRACE) {
        double t;
        if (mt_first) { mt_t0 = n; }
        t = n - mt_t0;
        /* always emit on the first swap - without a baseline every later
           value is a level with nothing to be a delta from */
        if (mt_first || t - mt_lastemit >= mt_interval_ms) {
            mt_first = 0; mt_lastemit = t; mt_emit();
        }
    }

    g_frame++;
    c_draws=c_verts=c_tris=c_binds=c_progs=c_bufup=0;
    c_texup=c_texkb=c_copytex=c_readpix=c_finish=c_flush=c_fbo=0;
    c_compile=c_link=c_shsrc=c_newprog=0;
    d_draw_us=0; d_worst_us=0; d_worst_n=0; d_worst_mode=0; d_worst_tex=0; d_worst_prog=0; d_worst_cpu_us=0;
    g_nrec=0;

    if (g_modes & M_FINISH) {
        double f0 = now_ms();
        resolve_glFinish();
        if (real_glFinish) real_glFinish();
        d_finish_us = (now_ms()-f0)*1000.0;
    }

    /* Nothing may run between the swap and the timestamp. scp_preload() and
       scw_drain() used to sit here and their cost was being reported as
       swap_us. */
    s0 = now_ms();
    if (real_SDL_GL_SwapWindow) real_SDL_GL_SwapWindow(w);
    d_swap_us = (now_ms()-s0)*1000.0;
}
