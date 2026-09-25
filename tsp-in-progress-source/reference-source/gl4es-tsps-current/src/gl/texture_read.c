#include "texture.h"

#include "../glx/hardext.h"
#include "../glx/streaming.h"
#include "array.h"
#include "blit.h"
#include "decompress.h"
#include "debug.h"
#include "enum_info.h"
#include "fpe.h"
#include "framebuffers.h"
#include "gles.h"
#include "init.h"
#include "loader.h"
#include "matrix.h"
#include "pixel.h"
#include "raster.h"

/* TSP_CT2_20260816 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static void tsp_ct2(const char* fmt, ...) {
    static int chk=0; static FILE* f=NULL; static unsigned long n=0;
    va_list ap;
    if(!chk){ const char* q=getenv("LIBGL_TSP_CT2"); chk=1; if(q&&q[0]) f=fopen(q,"w"); }
    if(!f) return;
    if(n>30000) return;
    fprintf(f,"%lu ",n++);
    va_start(ap,fmt); vfprintf(f,fmt,ap); va_end(ap);
    fprintf(f,"\n");
    if((n & 0x7f)==0) fflush(f);
}



/* TSP_LOCALMAP_BROAD_V6
 *
 * Force OpenMW local-map framebuffer copies through:
 *
 * framebuffer
 *      -> glReadPixels
 *      -> CPU RGBA8 buffer
 *      -> glTexSubImage2D
 *      -> original destination texture
 *
 * This deliberately bypasses the PowerVR/GLES
 * glCopyTexSubImage2D path for the local map only.
 *
 * Default: enabled.
 * Disable with:
 *   LIBGL_TSP_LOCALMAP_CPUCOPY=0
 */
static int tsp_localmap_cpucopy_enabled(void)
{
    static int checked = 0;
    static int enabled = 1;

    if (!checked)
    {
        const char* value =
            getenv("LIBGL_TSP_LOCALMAP_CPUCOPY");

        checked = 1;

        if (value
            && value[0] == '0'
            && value[1] == '\0')
        {
            enabled = 0;
        }
    }

    return enabled;
}

static int tsp_localmap_cpucopy_size(void)
{
    static int checked = 0;
    static int size = 256;

    if (!checked)
    {
        const char* value =
            getenv("LIBGL_TSP_LOCALMAP_CPUCOPY_SIZE");

        checked = 1;

        if (value && value[0])
        {
            int parsed = atoi(value);

            if (parsed >= 16 && parsed <= 4096)
                size = parsed;
        }
    }

    return size;
}

static unsigned long tsp_localmap_cpucopy_matches = 0;
static unsigned long tsp_localmap_cpucopy_observed = 0;


/* TSP_LOCALMAP_BROAD_V6 -------------------------------------------------
 *
 * Keep a CPU-side best image for active local-map textures.
 *
 * A new non-black pixel may replace an old pixel.
 * A new black pixel may NOT erase a previously non-black pixel.
 *
 * This directly handles map renders that fluctuate between complete
 * and partially-black on the TSP.
 */
#define TSP_LOCALMAP_BROAD_CACHE_SLOTS 64

typedef struct
{
    int used;

    GLuint logical_name;
    GLuint gl_name;

    unsigned char* pixels;
    size_t bytes;

    unsigned long samples;
    unsigned long long last_use;

    size_t black_pixels;
} tsp_localmap_broad_cache_t;

static tsp_localmap_broad_cache_t
    tsp_localmap_broad_cache[TSP_LOCALMAP_BROAD_CACHE_SLOTS];

static unsigned long long
    tsp_localmap_broad_cache_clock = 0;

static int tsp_localmap_broad_pixel_black(
    const unsigned char* p)
{
    return
        p[0] <= 5
        && p[1] <= 5
        && p[2] <= 5;
}

static tsp_localmap_broad_cache_t*
tsp_localmap_broad_get_cache(
    gltexture_t* bound,
    size_t bytes,
    int reset)
{
    tsp_localmap_broad_cache_t* slot = NULL;

    ++tsp_localmap_broad_cache_clock;

    for (int i = 0;
         i < TSP_LOCALMAP_BROAD_CACHE_SLOTS;
         ++i)
    {
        tsp_localmap_broad_cache_t* c =
            &tsp_localmap_broad_cache[i];

        if (c->used
            && c->logical_name == bound->texture
            && c->gl_name == bound->glname)
        {
            slot = c;
            break;
        }
    }

    if (!slot)
    {
        for (int i = 0;
             i < TSP_LOCALMAP_BROAD_CACHE_SLOTS;
             ++i)
        {
            if (!tsp_localmap_broad_cache[i].used)
            {
                slot = &tsp_localmap_broad_cache[i];
                break;
            }
        }
    }

    if (!slot)
    {
        slot = &tsp_localmap_broad_cache[0];

        for (int i = 1;
             i < TSP_LOCALMAP_BROAD_CACHE_SLOTS;
             ++i)
        {
            if (tsp_localmap_broad_cache[i].last_use
                < slot->last_use)
            {
                slot =
                    &tsp_localmap_broad_cache[i];
            }
        }

        reset = 1;
    }

    if (!slot->pixels
        || slot->bytes != bytes)
    {
        unsigned char* replacement =
            (unsigned char*)realloc(
                slot->pixels,
                bytes);

        if (!replacement)
            return NULL;

        slot->pixels = replacement;
        slot->bytes = bytes;
        reset = 1;
    }

    if (!slot->used
        || slot->logical_name != bound->texture
        || slot->gl_name != bound->glname)
    {
        reset = 1;
    }

    slot->used = 1;
    slot->logical_name = bound->texture;
    slot->gl_name = bound->glname;
    slot->last_use =
        tsp_localmap_broad_cache_clock;

    if (reset)
    {
        slot->samples = 0;
        slot->black_pixels = 0;
    }

    return slot;
}

static unsigned char*
tsp_localmap_broad_fuse(
    gltexture_t* bound,
    unsigned char* current,
    size_t pixel_count,
    int reset,
    unsigned long match_number)
{
    const size_t bytes =
        pixel_count * 4;

    size_t capture_black = 0;

    /*
     * The local-map base tile is opaque.
     *
     * Default-framebuffer alpha is not reliable on this device and
     * is a good candidate for the puzzle-piece/seam artefacts seen
     * in V3/V5.
     */
    for (size_t i = 0;
         i < pixel_count;
         ++i)
    {
        unsigned char* p =
            current + i * 4;

        if (tsp_localmap_broad_pixel_black(p))
            ++capture_black;

        p[3] = 255;
    }

    tsp_localmap_broad_cache_t* cache =
        tsp_localmap_broad_get_cache(
            bound,
            bytes,
            reset);

    if (!cache)
    {
        fprintf(
            stderr,
            "TSP_LOCALMAP_BROAD_V6 FUSION_FAIL "
            "match=%lu reason=cache-allocation "
            "action=use-current-capture\n",
            match_number);

        fflush(stderr);
        return current;
    }

    if (cache->samples == 0)
    {
        memcpy(
            cache->pixels,
            current,
            bytes);
    }
    else
    {
        /*
         * Latest non-black pixel wins.
         * Latest black pixel cannot destroy previously-good RGB.
         */
        for (size_t i = 0;
             i < pixel_count;
             ++i)
        {
            unsigned char* dst =
                cache->pixels + i * 4;

            const unsigned char* src =
                current + i * 4;

            if (!tsp_localmap_broad_pixel_black(src))
            {
                dst[0] = src[0];
                dst[1] = src[1];
                dst[2] = src[2];
            }

            dst[3] = 255;
        }
    }

    ++cache->samples;

    size_t fused_black = 0;

    for (size_t i = 0;
         i < pixel_count;
         ++i)
    {
        if (tsp_localmap_broad_pixel_black(
                cache->pixels + i * 4))
        {
            ++fused_black;
        }
    }

    cache->black_pixels =
        fused_black;

    const size_t recovered =
        capture_black > fused_black
            ? capture_black - fused_black
            : 0;

    fprintf(
        stderr,
        "TSP_LOCALMAP_BROAD_V6 FUSION "
        "match=%lu "
        "tex=%u "
        "glname=%u "
        "sample=%lu "
        "capture_black=%zu/%zu "
        "fused_black=%zu/%zu "
        "recovered=%zu "
        "alpha=255\n",
        match_number,
        bound->texture,
        bound->glname,
        cache->samples,
        capture_black,
        pixel_count,
        fused_black,
        pixel_count,
        recovered);

    if (capture_black * 4 > pixel_count)
    {
        fprintf(
            stderr,
            "TSP_LOCALMAP_BROAD_V6 SOURCE_SUSPECT "
            "match=%lu "
            "black_pct_x100=%zu "
            "action=merge-not-trust\n",
            match_number,
            (capture_black * 10000)
                / pixel_count);
    }

    fflush(stderr);

    return cache->pixels;
}


static void tsp_localmap_cpucopy_observe(
    GLenum target,
    GLint level,
    GLint xoffset,
    GLint yoffset,
    GLint x,
    GLint y,
    GLsizei width,
    GLsizei height,
    gltexture_t* bound,
    GLuint framebuffer)
{
    static int armed_logged = 0;

    if (!tsp_localmap_cpucopy_enabled())
        return;

    if (!armed_logged)
    {
        armed_logged = 1;

        fprintf(
            stderr,
            "TSP_LOCALMAP_BROAD_V6 ARMED "
            "size=%d "
            "mode=GL4ES-internal "
            "path=glReadPixels->CPU->glTexSubImage2D\n",
            tsp_localmap_cpucopy_size());

        fflush(stderr);
    }

    /*
     * If the exact 256x256 assumption turns out to be wrong,
     * still show us every large full-texture copy so the log
     * tells us the real dimensions on the very next run.
     */
    if (level == 0
        && xoffset == 0
        && yoffset == 0
        && width >= 128
        && height >= 128
        && tsp_localmap_cpucopy_observed < 64)
    {
        ++tsp_localmap_cpucopy_observed;

        fprintf(
            stderr,
            "TSP_LOCALMAP_BROAD_V6 OBSERVE "
            "n=%lu "
            "target=0x%x "
            "level=%d "
            "src=%d,%d "
            "dst=%d,%d "
            "copy=%dx%d "
            "tex=%u "
            "texsize=%dx%d "
            "format=0x%x "
            "type=0x%x "
            "fb=%u\n",
            tsp_localmap_cpucopy_observed,
            target,
            level,
            x,
            y,
            xoffset,
            yoffset,
            (int)width,
            (int)height,
            bound ? bound->texture : 0,
            bound ? bound->width : -1,
            bound ? bound->height : -1,
            bound ? bound->format : 0,
            bound ? bound->type : 0,
            framebuffer);

        fflush(stderr);
    }
}

static int tsp_localmap_cpucopy_match(
    GLenum target,
    GLint level,
    GLint xoffset,
    GLint yoffset,
    GLsizei width,
    GLsizei height,
    gltexture_t* bound)
{
    const int size =
        tsp_localmap_cpucopy_size();

    if (!tsp_localmap_cpucopy_enabled())
        return 0;

    if (!bound)
        return 0;

    /*
     * Local-map render texture:
     *
     *   GL_TEXTURE_2D
     *   mip level 0
     *   full texture update
     *   256x256 by default
     *
     * GL4ES reports bound->width/height as 0x0 for these
     * OSG FRAME_BUFFER copy targets on the TSP, so those fields
     * cannot be used for identification.
     *
     * Match the observed full 256x256 RGBA8 copy instead.
     */
    return
        target == GL_TEXTURE_2D
        && level == 0
        && xoffset == 0
        && yoffset == 0
        && width == size
        && height == size
        && bound->format == GL_RGBA
        && bound->type == GL_UNSIGNED_BYTE;
}

static void tsp_localmap_cpucopy_analyze(
    const unsigned char* pixels,
    size_t pixel_count,
    unsigned long match_number)
{
    unsigned int min_rgb = 255;
    unsigned int max_rgb = 0;

    size_t white = 0;
    size_t black = 0;
    size_t colored = 0;

    unsigned long long hash =
        1469598103934665603ULL;

    for (size_t i = 0;
         i < pixel_count;
         ++i)
    {
        const unsigned char* p =
            pixels + i * 4;

        const unsigned int r = p[0];
        const unsigned int g = p[1];
        const unsigned int b = p[2];

        if (r < min_rgb) min_rgb = r;
        if (g < min_rgb) min_rgb = g;
        if (b < min_rgb) min_rgb = b;

        if (r > max_rgb) max_rgb = r;
        if (g > max_rgb) max_rgb = g;
        if (b > max_rgb) max_rgb = b;

        if (r >= 250
            && g >= 250
            && b >= 250)
        {
            ++white;
        }

        if (r <= 5
            && g <= 5
            && b <= 5)
        {
            ++black;
        }

        if (!(r == g && g == b))
            ++colored;

        hash ^= r;
        hash *= 1099511628211ULL;

        hash ^= g;
        hash *= 1099511628211ULL;

        hash ^= b;
        hash *= 1099511628211ULL;
    }

    fprintf(
        stderr,
        "TSP_LOCALMAP_BROAD_V6 READ_PASS "
        "match=%lu "
        "pixels=%zu "
        "rgb=%u..%u "
        "white=%zu/%zu "
        "black=%zu/%zu "
        "colored=%zu/%zu "
        "hash=%llu\n",
        match_number,
        pixel_count,
        min_rgb,
        max_rgb,
        white,
        pixel_count,
        black,
        pixel_count,
        colored,
        pixel_count,
        hash);

    if (white == pixel_count)
    {
        fprintf(
            stderr,
            "TSP_LOCALMAP_BROAD_V6 SOURCE_BAD "
            "match=%lu "
            "reason=framebuffer-all-white\n",
            match_number);
    }
    else if (black == pixel_count)
    {
        fprintf(
            stderr,
            "TSP_LOCALMAP_BROAD_V6 SOURCE_BAD "
            "match=%lu "
            "reason=framebuffer-all-black\n",
            match_number);
    }
    else
    {
        fprintf(
            stderr,
            "TSP_LOCALMAP_BROAD_V6 SOURCE_GOOD "
            "match=%lu "
            "reason=framebuffer-contains-varied-map-pixels\n",
            match_number);
    }

    fflush(stderr);
}

//#define DEBUG
#ifdef DEBUG
#define DBG(a) a
#else
#define DBG(a)
#endif

static int inline nlevel(int size, int level) {
    if(size) {
        size>>=level;
        if(!size) size=1;
    }
    return size;
}

void APIENTRY_GL4ES gl4es_glCopyTexImage2D(GLenum target,  GLint level,  GLenum internalformat,  GLint x,  GLint y,  
                                GLsizei width,  GLsizei height,  GLint border) {
    tsp_ct2("COPYIMG lvl=%d ifmt=0x%x x=%d y=%d w=%d h=%d", level, internalformat, x, y, width, height);
    DBG(printf("glCopyTexImage2D(%s, %i, %s, %i, %i, %i, %i, %i), glstate->fbo.current_fb=%p\n", PrintEnum(target), level, PrintEnum(internalformat), x, y, width, height, border, glstate->fbo.current_fb);)
     //PUSH_IF_COMPILING(glCopyTexImage2D);
    FLUSH_BEGINEND;
    const GLuint itarget = what_target(target);

    // actually bound if targeting shared TEX2D
    realize_bound(glstate->texture.active, target);

    if (globals4es.skiptexcopies) {
        DBG(printf("glCopyTexImage2D skipped.\n"));
        tsp_ct2("COPYIMG_SKIPPED");
        return;
    }

    errorGL();

    // "Unmap" if buffer mapped...
    glbuffer_t *pack = glstate->vao->pack;
    glbuffer_t *unpack = glstate->vao->unpack;
    glstate->vao->pack = NULL;
    glstate->vao->unpack = NULL;
    
    readfboBegin(); // multiple readfboBegin() can be chained...
    gltexture_t* bound = glstate->texture.bound[glstate->texture.active][itarget];

    if(glstate->fbo.current_fb->read_type==0) {
        LOAD_GLES(glGetIntegerv);
        gles_glGetIntegerv(GL_IMPLEMENTATION_COLOR_READ_FORMAT_OES, (GLint *) &glstate->fbo.current_fb->read_format);
        gles_glGetIntegerv(GL_IMPLEMENTATION_COLOR_READ_TYPE_OES, (GLint *) &glstate->fbo.current_fb->read_type);
    }
    int copytex = ((bound->format==GL_RGBA && bound->type==GL_UNSIGNED_BYTE) 
        || (bound->format==glstate->fbo.current_fb->read_format && bound->type==glstate->fbo.current_fb->read_type));

    if (copytex) {
        GLenum fmt;
        switch(internalformat) {
            case GL_ALPHA:
            case GL_ALPHA8:
                fmt = GL_ALPHA; break;
            case GL_LUMINANCE:
            case GL_LUMINANCE8:
                fmt = GL_LUMINANCE; break;
            case GL_LUMINANCE_ALPHA:
            case GL_LUMINANCE8_ALPHA8:
                fmt = GL_LUMINANCE_ALPHA; break;
            case GL_RGB:
            case 3:
                fmt = GL_RGB; break;
            default:
                fmt = GL_RGBA;
        }
        LOAD_GLES(glCopyTexImage2D);
        gles_glCopyTexImage2D(target, level, fmt, x, y, width, height, border);
    } else {
        void* tmp = malloc(width*height*4);
        gl4es_glReadPixels(x, y, width, height, GL_RGBA, GL_UNSIGNED_BYTE, tmp);
        gl4es_glTexImage2D(target, level, internalformat, width, height, border, GL_RGBA, GL_UNSIGNED_BYTE, tmp);
        free(tmp);
    }
    
    readfboEnd();
    // "Remap" if buffer mapped...
    glstate->vao->pack = pack;
    glstate->vao->unpack = unpack;
}

void APIENTRY_GL4ES gl4es_glCopyTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset,
                                GLint x, GLint y, GLsizei width, GLsizei height) {
    tsp_ct2("COPYSUB lvl=%d xo=%d yo=%d x=%d y=%d w=%d h=%d", level, xoffset, yoffset, x, y, width, height);
    const GLuint itarget = what_target(target);
    // WARNING: It seems glColorMask has an impact on what channel are actually copied by this. The crude glReadPixel / glTexSubImage cannot emulate that, and proper emulation will take need 2 read pixels.
    //  And using the real glCopyTexSubImage2D needs that the FrameBuffer were data are read is compatible with the Texture it's copied to...
    DBG(printf("glCopyTexSubImage2D(%s, %i, %i, %i, %i, %i, %i, %i), bounded texture=%u format/type=%s, %s\n", PrintEnum(target), level, xoffset, yoffset, x, y, width, height, (glstate->texture.bound[glstate->texture.active][itarget])?glstate->texture.bound[glstate->texture.active][itarget]->texture:0, PrintEnum((glstate->texture.bound[glstate->texture.active][itarget])?glstate->texture.bound[glstate->texture.active][itarget]->format:0), PrintEnum((glstate->texture.bound[glstate->texture.active][itarget])?glstate->texture.bound[glstate->texture.active][itarget]->type:0));)
    // PUSH_IF_COMPILING(glCopyTexSubImage2D);
    FLUSH_BEGINEND;

    if (globals4es.skiptexcopies) {
        DBG(printf("glCopyTexSubImage2D skipped.\n"));
        return;
    }
 
    LOAD_GLES(glCopyTexSubImage2D);
    LOAD_GLES(glFinish);
    LOAD_GLES(glBindTexture);
    LOAD_GLES(glTexSubImage2D);
    LOAD_GLES(glTexImage2D);
    errorGL();
    realize_bound(glstate->texture.active, target);
    
    // "Unmap" if buffer mapped...
    glbuffer_t *pack = glstate->vao->pack;
    glbuffer_t *unpack = glstate->vao->unpack;
    glstate->vao->pack = NULL;
    glstate->vao->unpack = NULL;

    readfboBegin(); // multiple readfboBegin() can be chained...

    gltexture_t* bound = glstate->texture.bound[glstate->texture.active][itarget];

    const GLuint tsp_current_fb =
        glstate->fbo.current_fb
            ? glstate->fbo.current_fb->id
            : 0;

    tsp_localmap_cpucopy_observe(
        target,
        level,
        xoffset,
        yoffset,
        x,
        y,
        width,
        height,
        bound,
        tsp_current_fb);

    const int tsp_force_cpu =
        tsp_localmap_cpucopy_match(
            target,
            level,
            xoffset,
            yoffset,
            width,
            height,
            bound);

    if (tsp_force_cpu)
    {
        ++tsp_localmap_cpucopy_matches;

        fprintf(
            stderr,
            "TSP_LOCALMAP_BROAD_V6 MATCH "
            "n=%lu "
            "src=%d,%d "
            "size=%dx%d "
            "tex=%u "
            "fb=%u "
            "action=FORCE_CPU_PATH\n",
            tsp_localmap_cpucopy_matches,
            x,
            y,
            (int)width,
            (int)height,
            bound ? bound->texture : 0,
            tsp_current_fb);

        fflush(stderr);
    }

#ifdef TEXSTREAM
    if (bound->streamed && !tsp_force_cpu) {
        void* buff = GetStreamingBuffer(bound->streamingID);
        if ((bound->width == width) && (bound->height == height) && (xoffset == yoffset == 0)) {
            gl4es_glReadPixels(x, y, width, height, GL_RGB, GL_UNSIGNED_SHORT_5_6_5, buff);
        } else {
            void* tmp = malloc(width*height*2);
            gl4es_glReadPixels(x, y, width, height, GL_RGB, GL_UNSIGNED_SHORT_5_6_5, tmp);
            for (int y=0; y<height; y++) {
                memcpy(buff+((yoffset+y)*bound->width+xoffset)*2, tmp+y*width*2, width*2);
            }
            free(tmp);
        }
    } else 
#endif
    {
        int copytex = 0;
        if(glstate->fbo.current_fb->read_type==0) {
            LOAD_GLES(glGetIntegerv);
            gles_glGetIntegerv(GL_IMPLEMENTATION_COLOR_READ_FORMAT_OES, (GLint *) &glstate->fbo.current_fb->read_format);
            gles_glGetIntegerv(GL_IMPLEMENTATION_COLOR_READ_TYPE_OES, (GLint *) &glstate->fbo.current_fb->read_type);
        }
        copytex = ((bound->format==GL_RGBA && bound->type==GL_UNSIGNED_BYTE) 
            || (bound->format==glstate->fbo.current_fb->read_format && bound->type==glstate->fbo.current_fb->read_type));
        if (!tsp_force_cpu && (copytex || !glstate->colormask[0] || !glstate->colormask[1] || !glstate->colormask[2] || !glstate->colormask[3])) {
            gles_glCopyTexSubImage2D(target, level, xoffset, yoffset, x, y, width, height);
            if(((((bound->max_level == level) && (level || bound->mipmap_need)) && (globals4es.automipmap!=3) && (bound->mipmap_need!=0))) && !(bound->max_level==bound->base_level && bound->base_level==0)) {
                LOAD_GLES2_OR_OES(glGenerateMipmap);
                if(gles_glGenerateMipmap)
                    gles_glGenerateMipmap(to_target(itarget));
            }
        } else {
            if (tsp_force_cpu)
            {
                ++tsp_localmap_cpucopy_matches;

                const unsigned long tsp_match =
                    tsp_localmap_cpucopy_matches;

                fprintf(
                    stderr,
                    "TSP_LOCALMAP_BROAD_V6 MATCH "
                    "n=%lu "
                    "src=%d,%d "
                    "size=%dx%d "
                    "tex=%u "
                    "glname=%u "
                    "fb=%u "
                    "action=CPU_FUSION_NATIVE_UPLOAD\n",
                    tsp_match,
                    x,
                    y,
                    (int)width,
                    (int)height,
                    bound ? bound->texture : 0,
                    bound ? bound->glname : 0,
                    tsp_current_fb);

                fflush(stderr);

                const size_t tsp_pixel_count =
                    (size_t)width * (size_t)height;

                const size_t tsp_byte_count =
                    tsp_pixel_count * 4;

                unsigned char* tmp =
                    (unsigned char*)malloc(
                        tsp_byte_count);

                if (!tmp)
                {
                    fprintf(
                        stderr,
                        "TSP_LOCALMAP_BROAD_V6 FAIL_PRESERVE "
                        "match=%lu "
                        "stage=malloc "
                        "bytes=%zu "
                        "driver-copy=FORBIDDEN\n",
                        tsp_match,
                        tsp_byte_count);

                    fflush(stderr);
                }
                else
                {
                    LOAD_GLES(glGetError);
                    LOAD_GLES(glFinish);
                    LOAD_GLES(glBindTexture);
                    LOAD_GLES(glTexImage2D);
                    LOAD_GLES(glTexSubImage2D);

                    /*
                     * Drain unrelated errors before this transaction.
                     */
                    if (gles_glGetError)
                    {
                        for (int tsp_i = 0;
                             tsp_i < 16;
                             ++tsp_i)
                        {
                            GLenum e =
                                gles_glGetError();

                            if (e == GL_NO_ERROR)
                                break;

                            fprintf(
                                stderr,
                                "TSP_LOCALMAP_BROAD_V6 "
                                "PREEXISTING_GL_ERROR "
                                "match=%lu error=0x%x\n",
                                tsp_match,
                                e);
                        }
                    }

                    /*
                     * Make the completion point explicit for this
                     * one-shot map camera before pulling its pixels.
                     */
                    if (gles_glFinish)
                        gles_glFinish();

                    fprintf(
                        stderr,
                        "TSP_LOCALMAP_BROAD_V6 READ_BEGIN "
                        "match=%lu size=%dx%d\n",
                        tsp_match,
                        (int)width,
                        (int)height);

                    fflush(stderr);

                    gl4es_glReadPixels(
                        x,
                        y,
                        width,
                        height,
                        GL_RGBA,
                        GL_UNSIGNED_BYTE,
                        tmp);

                    GLenum tsp_read_error =
                        gles_glGetError
                            ? gles_glGetError()
                            : GL_NO_ERROR;

                    if (tsp_read_error
                        != GL_NO_ERROR)
                    {
                        fprintf(
                            stderr,
                            "TSP_LOCALMAP_BROAD_V6 FAIL_PRESERVE "
                            "match=%lu "
                            "stage=glReadPixels "
                            "error=0x%x "
                            "driver-copy=FORBIDDEN\n",
                            tsp_match,
                            tsp_read_error);

                        fflush(stderr);
                    }
                    else
                    {
                        const int tsp_need_allocate =
                            !bound
                            || !bound->valid
                            || bound->width != width
                            || bound->height != height
                            || bound->nwidth != width
                            || bound->nheight != height;

                        unsigned char* tsp_upload_pixels =
                            tsp_localmap_broad_fuse(
                                bound,
                                tmp,
                                tsp_pixel_count,
                                tsp_need_allocate,
                                tsp_match);

                        tsp_localmap_cpucopy_analyze(
                            tsp_upload_pixels,
                            tsp_pixel_count,
                            tsp_match);

                        /*
                         * readfboBegin/readPixels may disturb the REAL
                         * GLES binding while GL4ES's cached binding still
                         * claims that the map texture is active.
                         *
                         * Do not trust the cache here. Bind the actual
                         * GLES texture by glname every time.
                         */
                        realize_active();

                        gles_glBindTexture(
                            GL_TEXTURE_2D,
                            bound->glname);

                        glstate->actual_tex2d[
                            glstate->texture.active]
                                = bound->glname;

                        GLenum tsp_bind_error =
                            gles_glGetError
                                ? gles_glGetError()
                                : GL_NO_ERROR;

                        fprintf(
                            stderr,
                            "TSP_LOCALMAP_BROAD_V6 NATIVE_BIND "
                            "match=%lu "
                            "logical=%u "
                            "glname=%u "
                            "active=%d "
                            "error=0x%x\n",
                            tsp_match,
                            bound->texture,
                            bound->glname,
                            glstate->texture.active,
                            tsp_bind_error);

                        fflush(stderr);

                        /*
                         * Drain the bind result so the next error
                         * belongs only to the upload.
                         */
                        if (gles_glGetError)
                        {
                            while (gles_glGetError()
                                   != GL_NO_ERROR)
                            {
                            }
                        }

                        GLenum tsp_upload_error =
                            GL_NO_ERROR;

                        if (tsp_need_allocate)
                        {
                            fprintf(
                                stderr,
                                "TSP_LOCALMAP_BROAD_V6 "
                                "ALLOCATE_BEGIN "
                                "match=%lu tex=%u glname=%u "
                                "old=%dx%d valid=%d new=%dx%d\n",
                                tsp_match,
                                bound->texture,
                                bound->glname,
                                bound->width,
                                bound->height,
                                bound->valid,
                                (int)width,
                                (int)height);

                            fflush(stderr);

                            /*
                             * Allocate exactly once for this texture.
                             */
                            gles_glTexImage2D(
                                GL_TEXTURE_2D,
                                level,
                                GL_RGBA,
                                width,
                                height,
                                0,
                                GL_RGBA,
                                GL_UNSIGNED_BYTE,
                                tsp_upload_pixels);

                            tsp_upload_error =
                                gles_glGetError
                                    ? gles_glGetError()
                                    : GL_NO_ERROR;

                            if (tsp_upload_error
                                == GL_NO_ERROR)
                            {
                                bound->width = width;
                                bound->height = height;
                                bound->nwidth = width;
                                bound->nheight = height;

                                bound->format = GL_RGBA;
                                bound->type = GL_UNSIGNED_BYTE;

                                bound->wanted_internal = GL_RGBA;
                                bound->orig_internal = GL_RGBA;
                                bound->internalformat = GL_RGBA;

                                bound->alpha = 1;
                                bound->compressed = 0;
                                bound->npot = 0;
                                bound->shrink = 0;
                                bound->useratio = 0;

                                bound->ratiox = 1.0f;
                                bound->ratioy = 1.0f;

                                bound->adjust = 0;
                                bound->adjustxy[0] = 1.0f;
                                bound->adjustxy[1] = 1.0f;

                                bound->valid = 1;

                                fprintf(
                                    stderr,
                                    "TSP_LOCALMAP_BROAD_V6 "
                                    "ALLOCATE_PASS "
                                    "match=%lu "
                                    "tex=%u glname=%u "
                                    "storage=%dx%d valid=1\n",
                                    tsp_match,
                                    bound->texture,
                                    bound->glname,
                                    bound->width,
                                    bound->height);

                                fflush(stderr);
                            }
                        }
                        else
                        {
                            fprintf(
                                stderr,
                                "TSP_LOCALMAP_BROAD_V6 "
                                "UPDATE_BEGIN "
                                "match=%lu tex=%u glname=%u "
                                "storage=%dx%d\n",
                                tsp_match,
                                bound->texture,
                                bound->glname,
                                bound->width,
                                bound->height);

                            fflush(stderr);

                            gles_glTexSubImage2D(
                                GL_TEXTURE_2D,
                                level,
                                xoffset,
                                yoffset,
                                width,
                                height,
                                GL_RGBA,
                                GL_UNSIGNED_BYTE,
                                tsp_upload_pixels);

                            tsp_upload_error =
                                gles_glGetError
                                    ? gles_glGetError()
                                    : GL_NO_ERROR;

                            /*
                             * One explicit native rebind + retry.
                             *
                             * V5 proved updates could become invalid
                             * even while GL4ES metadata remained
                             * 256x256/valid.
                             */
                            if (tsp_upload_error
                                != GL_NO_ERROR)
                            {
                                fprintf(
                                    stderr,
                                    "TSP_LOCALMAP_BROAD_V6 "
                                    "UPDATE_RETRY "
                                    "match=%lu first_error=0x%x\n",
                                    tsp_match,
                                    tsp_upload_error);

                                fflush(stderr);

                                realize_active();

                                gles_glBindTexture(
                                    GL_TEXTURE_2D,
                                    bound->glname);

                                glstate->actual_tex2d[
                                    glstate->texture.active]
                                        = bound->glname;

                                if (gles_glGetError)
                                {
                                    while (gles_glGetError()
                                           != GL_NO_ERROR)
                                    {
                                    }
                                }

                                gles_glTexSubImage2D(
                                    GL_TEXTURE_2D,
                                    level,
                                    xoffset,
                                    yoffset,
                                    width,
                                    height,
                                    GL_RGBA,
                                    GL_UNSIGNED_BYTE,
                                    tsp_upload_pixels);

                                tsp_upload_error =
                                    gles_glGetError
                                        ? gles_glGetError()
                                        : GL_NO_ERROR;

                                if (tsp_upload_error
                                    == GL_NO_ERROR)
                                {
                                    fprintf(
                                        stderr,
                                        "TSP_LOCALMAP_BROAD_V6 "
                                        "UPDATE_RETRY_PASS "
                                        "match=%lu\n",
                                        tsp_match);

                                    fflush(stderr);
                                }
                            }

                            if (tsp_upload_error
                                == GL_NO_ERROR)
                            {
                                fprintf(
                                    stderr,
                                    "TSP_LOCALMAP_BROAD_V6 "
                                    "UPDATE_PASS "
                                    "match=%lu "
                                    "storage-preserved=1\n",
                                    tsp_match);

                                fflush(stderr);
                            }
                        }

                        if (tsp_upload_error
                            != GL_NO_ERROR)
                        {
                            /*
                             * CRITICAL:
                             *
                             * Never go back to the old PowerVR copy
                             * for a matched local-map tile.
                             *
                             * Preserve whatever valid fused texture
                             * we already have instead of replacing it
                             * with black/rainbow corruption.
                             */
                            fprintf(
                                stderr,
                                "TSP_LOCALMAP_BROAD_V6 "
                                "FAIL_PRESERVE "
                                "match=%lu "
                                "stage=native-upload "
                                "error=0x%x "
                                "driver-copy=FORBIDDEN "
                                "old-texture=PRESERVED\n",
                                tsp_match,
                                tsp_upload_error);

                            fflush(stderr);
                        }
                        else
                        {
                            fprintf(
                                stderr,
                                "TSP_LOCALMAP_BROAD_V6 "
                                "UPLOAD_PASS "
                                "match=%lu "
                                "driver-copy=BYPASSED "
                                "alpha=OPAQUE "
                                "fusion=ACTIVE\n",
                                tsp_match);

                            fflush(stderr);
                        }
                    }

                    free(tmp);
                }
            }
            else
            {
                /*
                 * Original GL4ES CPU fallback.
                 * Unchanged for every non-map copy.
                 */
                void* tmp =
                    malloc(width*height*4);

                GLenum format =
                    bound->format;

                GLenum type =
                    bound->type;

                gl4es_glReadPixels(
                    x,
                    y,
                    width,
                    height,
                    format,
                    type,
                    tmp);

                // mipmap will be calculated by
                // gl4es_glTexSubImage2D
                gl4es_glTexSubImage2D(
                    target,
                    level,
                    xoffset,
                    yoffset,
                    width,
                    height,
                    format,
                    type,
                    tmp);

                free(tmp);
            }
        }
    }
    readfboEnd();
    // "Remap" if buffer mapped...
    glstate->vao->pack = pack;
    glstate->vao->unpack = unpack;
}

void APIENTRY_GL4ES gl4es_glReadPixels(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, GLvoid * data) {
    DBG(printf("glReadPixels(%i, %i, %i, %i, %s, %s, 0x%p)\n", x, y, width, height, PrintEnum(format), PrintEnum(type), data);)
    FLUSH_BEGINEND;
    if (glstate->list.compiling && glstate->list.active) {
        errorShim(GL_INVALID_OPERATION);
        return;	// never in list
    }
    LOAD_GLES(glReadPixels);
    errorGL();
    GLvoid* dst = data;
    if (glstate->vao->pack)
        dst = (char*)dst + (uintptr_t)glstate->vao->pack->data;
        
    readfboBegin();
    if ((format == GL_RGBA && type == GL_UNSIGNED_BYTE)     // should not use default GL_RGBA on Pandora as it's very slow...
       || (format == glstate->readf && type == glstate->readt)    // use the IMPLEMENTATION_READ too...
       || (format == GL_DEPTH_COMPONENT && (type == GL_FLOAT || type==GL_HALF_FLOAT)))   // this one will probably fail, as DEPTH is not readable on most GLES hardware 
    {
        // easy passthru
        gles_glReadPixels(x, y, width, height, format, type, dst);
        readfboEnd();
        return;
    }
    // grab data in GL_RGBA format
    int use_bgra = 0;
    if(glstate->readf==GL_BGRA && glstate->readt==GL_UNSIGNED_BYTE)
        use_bgra = 1;   // if IMPLEMENTATION_READ is BGRA, then use it as it's probably faster then RGBA.
    GLvoid *pixels = malloc(width*height*4);
    gles_glReadPixels(x, y, width, height, use_bgra?GL_BGRA:GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    if (! pixel_convert(pixels, &dst, width, height,
                        use_bgra?GL_BGRA:GL_RGBA, GL_UNSIGNED_BYTE, format, type, 0,glstate->texture.pack_align)) {
        LOGE("ReadPixels error: (%s, UNSIGNED_BYTE -> %s, %s )\n",
            PrintEnum(use_bgra?GL_BGRA:GL_RGBA), PrintEnum(format), PrintEnum(type));
    }
    free(pixels);
    readfboEnd();
    return;
}


void APIENTRY_GL4ES gl4es_glGetTexImage(GLenum target, GLint level, GLenum format, GLenum type, GLvoid * img) {
    DBG(printf("glGetTexImage(%s, %i, %s, %s, %p)\n", PrintEnum(target), level, PrintEnum(format), PrintEnum(type), img);)
    FLUSH_BEGINEND;
    const GLuint itarget = what_target(target);    

    realize_bound(glstate->texture.active, target);
       
    gltexture_t* bound = glstate->texture.bound[glstate->texture.active][itarget];
    int width = bound->width;
    int height = bound->height;
    int nwidth = bound->nwidth;
    int nheight = bound->nheight;
    int shrink = bound->shrink;
    if (level != 0) {
        //printf("STUBBED glGetTexImage with level=%i\n", level);
        void* tmp = malloc(width*height*pixel_sizeof(format, type)); // tmp space...
        void* tmp2;
        gl4es_glGetTexImage(map_tex_target(target), 0, format, type, tmp);
        for (int i=0; i<level; i++) {
            pixel_halfscale(tmp, &tmp2, width, height, format, type);
            free(tmp);
            tmp = tmp2;
            width = nlevel(width, 1);
            height = nlevel(height, 1);
        }
        memcpy(img, tmp, width*height*pixel_sizeof(format, type));
        free(tmp);
        return;
    }
    
    if (target!=GL_TEXTURE_2D) {
        return;
    }

    DBG(printf("glGetTexImage(%s, %i, %s, %s, 0x%p), texture=0x%x, size=%i,%i\n", PrintEnum(target), level, PrintEnum(format), PrintEnum(type), img, bound->glname, width, height);)
    
    GLvoid *dst = img;
    if (glstate->vao->pack)
        dst = (char*)dst + (uintptr_t)glstate->vao->pack->data;
#ifdef TEXSTREAM
    if (globals4es.texstream && bound->streamed) {
        noerrorShim();
        pixel_convert(GetStreamingBuffer(bound->streamingID), &dst, width, height, GL_RGB, GL_UNSIGNED_SHORT_5_6_5, format, type, 0, glstate->texture.unpack_align);
        readfboEnd();
        return;
    }
#endif
    if (globals4es.texcopydata && bound->data) {
        //printf("texcopydata* glGetTexImage(0x%04X, %d, 0x%04x, 0x%04X, %p)\n", target, level, format, type, img);
        noerrorShim();
        if (!pixel_convert(bound->data, &dst, width, height, GL_RGBA, GL_UNSIGNED_BYTE, format, type, 0, glstate->texture.pack_align))
            printf("LIBGL: Error on pixel_convert while glGetTexImage\n");
    } else {
        // Setup an FBO the same size of the texture
        GLuint oldBind = bound->glname;
        GLuint old_fbo = glstate->fbo.current_fb->id;
        GLuint fbo;
    
        // if the texture is not RGBA or RGB or ALPHA, the "just attach texture to the fbo" trick will not work, and a full Blit has to be done
        if((bound->format==GL_RGBA || bound->format==GL_RGB || (bound->format==GL_BGRA && hardext.bgra8888) || bound->format==GL_ALPHA) && (shrink==0)) {
            gl4es_glGenFramebuffers(1, &fbo);
            gl4es_glBindFramebuffer(GL_FRAMEBUFFER_OES, fbo);
            gl4es_glFramebufferTexture2D(GL_FRAMEBUFFER_OES, GL_COLOR_ATTACHMENT0_OES, GL_TEXTURE_2D, oldBind, 0);
            // Read the pixels!
            gl4es_glReadPixels(0, nheight-height, width, height, format, type, img);	// using "full" version with conversion of format/type
            gl4es_glBindFramebuffer(GL_FRAMEBUFFER_OES, old_fbo);
            gl4es_glDeleteFramebuffers(1, &fbo);
            noerrorShim();
        } else {
            gl4es_glGenFramebuffers(1, &fbo);
            gl4es_glBindFramebuffer(GL_FRAMEBUFFER_OES, fbo);
            GLuint temptex;
            gl4es_glGenTextures(1, &temptex);
            gl4es_glBindTexture(GL_TEXTURE_2D, temptex);
            gl4es_glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, nwidth<<shrink, nheight<<shrink, 0, GL_RGBA, GL_UNSIGNED_BYTE, 0);
            gl4es_glFramebufferTexture2D(GL_FRAMEBUFFER_OES, GL_COLOR_ATTACHMENT0_OES, GL_TEXTURE_2D, temptex, 0);
            gl4es_glBindTexture(GL_TEXTURE_2D, oldBind);
            // blit the texture
            gl4es_glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
            gl4es_glClear(GL_COLOR_BUFFER_BIT);
            gl4es_blitTexture(oldBind, 0.f, 0.f, width, height, nwidth, nheight, 1.0f, 1.0f, nwidth<<shrink, nheight<<shrink, 0, 0, BLIT_OPAQUE);
            // Read the pixels!
            gl4es_glReadPixels(0, (nheight-height)<<shrink, width<<shrink, height<<shrink, format, type, img);	// using "full" version with conversion of format/type
            gl4es_glBindFramebuffer(GL_FRAMEBUFFER_OES, old_fbo);
            gl4es_glDeleteFramebuffers(1, &fbo);
            gl4es_glDeleteTextures(1, &temptex);
            noerrorShim();
        }
    }
}

void APIENTRY_GL4ES gl4es_glCopyTexImage1D(GLenum target, GLint level, GLenum internalformat, GLint x, GLint y,
            GLsizei width, GLint border) {
    gl4es_glCopyTexImage2D(GL_TEXTURE_1D, level, internalformat, x, y, width, 1, border);
            
}

void APIENTRY_GL4ES gl4es_glCopyTexSubImage1D(GLenum target, GLint level, GLint xoffset, GLint x, GLint y,
                                GLsizei width) {
    gl4es_glCopyTexSubImage2D(GL_TEXTURE_1D, level, xoffset, 0, x, y, width, 1);
}
                                
//Direct wrapper
AliasExport(void,glGetTexImage,,(GLenum target, GLint level, GLenum format, GLenum type, GLvoid * img));
AliasExport(void,glReadPixels,,(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, GLvoid * data));
AliasExport(void,glCopyTexImage1D,,(GLenum target,  GLint level,  GLenum internalformat,  GLint x,  GLint y, GLsizei width,  GLint border));
AliasExport(void,glCopyTexImage2D,,(GLenum target,  GLint level,  GLenum internalformat,  GLint x,  GLint y, GLsizei width,  GLsizei height,  GLint border));
AliasExport(void,glCopyTexSubImage2D,,(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLint x, GLint y, GLsizei width, GLsizei height));
AliasExport(void,glCopyTexSubImage1D,,(GLenum target, GLint level, GLint xoffset, GLint x, GLint y, GLsizei width));

