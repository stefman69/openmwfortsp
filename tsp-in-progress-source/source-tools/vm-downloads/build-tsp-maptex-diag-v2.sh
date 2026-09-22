#!/usr/bin/env bash

# IMPORTANT:
# This script runs as a child process. Its "set -e" cannot kill the
# interactive terminal that launched it.

set -Eeuo pipefail

D=/home/bob-simpson/Downloads
LOG="$D/tsp-maptex-build-v2.log"
GL_OUT="$D/libGL.so.1-tsp-texlife-v2"
OMW_OUT="$D/openmw-tsp-maplife-v2"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$D/tsp-maptex-live-pre-v2-$STAMP.tar.gz"

: > "$LOG"

on_error()
{
    rc=$?
    trap - ERR

    echo
    echo "============================================================"
    echo "FAILED (exit $rc)"
    echo
    echo "The terminal itself is fine; this child script stopped."
    echo
    echo "Full log:"
    echo "  $LOG"
    echo
    echo "Last 50 log lines:"
    echo "============================================================"
    tail -n 50 "$LOG" 2>/dev/null || true
    echo "============================================================"
    exit "$rc"
}

trap on_error ERR

echo "[1/7] Checking builder..."

docker inspect openmw_builder >/dev/null 2>&1

echo "[2/7] Backing up the exact live sources..."

docker exec openmw_builder bash -lc "
    set -e
    cd /root
    tar -czf /tmp/tsp-maptex-live-pre-v2-$STAMP.tar.gz \
        gl4es-tsps/src/gl/texture.h \
        gl4es-tsps/src/gl/texture_params.c \
        gl4es-tsps/src/gl/texture.c \
        gl4es-tsps/src/gl/framebuffers.c \
        openmw-0.51-tsp-src/apps/openmw/mwrender/localmap.cpp
" >>"$LOG" 2>&1

docker cp \
    "openmw_builder:/tmp/tsp-maptex-live-pre-v2-$STAMP.tar.gz" \
    "$BACKUP" >>"$LOG" 2>&1

echo "      Backup: $BACKUP"

echo "[3/7] Applying anchor-checked diagnostic instrumentation..."

docker exec -i openmw_builder python3 - >>"$LOG" 2>&1 <<'PY'
from pathlib import Path
import sys

GL = Path("/root/gl4es-tsps")
OMW = Path("/root/openmw-0.51-tsp-src")

files = {
    "texture_h": GL / "src/gl/texture.h",
    "texture_params": GL / "src/gl/texture_params.c",
    "texture_c": GL / "src/gl/texture.c",
    "framebuffers": GL / "src/gl/framebuffers.c",
    "localmap": OMW / "apps/openmw/mwrender/localmap.cpp",
}

for name, path in files.items():
    if not path.is_file():
        raise RuntimeError(f"missing required source: {path}")


def load(path):
    return path.read_text()


def save(path, text):
    path.write_text(text)


def replace_once(text, old, new, label):
    n = text.count(old)
    if n != 1:
        raise RuntimeError(
            f"{label}: expected exactly 1 anchor, found {n}"
        )
    return text.replace(old, new, 1)


def region(text, start_marker, end_marker, label):
    a = text.find(start_marker)
    if a < 0:
        raise RuntimeError(f"{label}: start marker not found")
    b = text.find(end_marker, a + len(start_marker))
    if b < 0:
        raise RuntimeError(f"{label}: end marker not found")
    return a, b


def replace_region(text, start_marker, end_marker, old, new, label):
    a, b = region(text, start_marker, end_marker, label)
    part = text[a:b]
    n = part.count(old)
    if n != 1:
        raise RuntimeError(
            f"{label}: expected exactly 1 in-function anchor, found {n}"
        )
    part = part.replace(old, new, 1)
    return text[:a] + part + text[b:]


def insert_before_function_end(text, start_marker, end_marker, insert, label):
    a, b = region(text, start_marker, end_marker, label)
    part = text[a:b]

    # Function should finish with a standalone brace before next function.
    p = part.rfind("\n}")
    if p < 0:
        raise RuntimeError(f"{label}: closing brace not found")

    part = part[:p] + "\n" + insert.rstrip() + "\n" + part[p:]
    return text[:a] + part + text[b:]


# ----------------------------------------------------------------------
# Refuse a mixed previous attempt, but allow a completed V2 rerun.
# ----------------------------------------------------------------------

states = {
    name: "TSP_TEXLIFE_V2" in load(path) or "TSP_MAPLIFE_V2" in load(path)
    for name, path in files.items()
}

if all(states.values()):
    print("TSP MAP/TEXTURE V2 instrumentation already present; no edit needed.")
    sys.exit(0)

if any(states.values()):
    raise RuntimeError(
        "partial V2 instrumentation detected; refusing to stack another patch"
    )


# ======================================================================
# 1. texture.h
# ======================================================================

p = files["texture_h"]
s = load(p)

anchor = "KHASH_MAP_DECLARE_INT(tex, gltexture_t *);"

insert = r'''
/* TSP_TEXLIFE_V2
 * Diagnostic-only texture lifetime / upload / FBO correlation.
 * Dormant unless LIBGL_TSP_TEXLIFE or LIBGL_TSP_FBOPATH is set.
 */
void tsp_texlife_created(gltexture_t* tex);
void tsp_texlife_deleted(gltexture_t* tex);

void tsp_texlife_image(
    const char* op,
    gltexture_t* tex,
    GLint level,
    GLsizei width,
    GLsizei height,
    GLenum format,
    GLenum type,
    const GLvoid* data,
    glbuffer_t* unpack);

void tsp_texlife_attach(
    const char* op,
    gltexture_t* tex,
    GLuint fbo,
    GLenum attachment);

'''

s = replace_once(
    s,
    anchor,
    insert + anchor,
    "texture.h prototypes"
)

save(p, s)


# ======================================================================
# 2. texture_params.c
# ======================================================================

p = files["texture_params"]
s = load(p)

anchor = "KHASH_MAP_IMPL_INT(tex, gltexture_t *);"

helper = r'''
/* TSP_TEXLIFE_V2 ---------------------------------------------------------
 * Full texture lifetime/resource accounting for the TSP map investigation.
 *
 * Output:
 *   explicit LIBGL_TSP_TEXLIFE=/path
 * or, in the existing FBO diagnostic modes:
 *   ${LIBGL_TSP_FBOPATH}.texlife
 *
 * This intentionally streams to disk and keeps no unbounded diagnostic
 * allocation in memory.
 */
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>

static FILE* tsp_texlife_file(void)
{
    static int checked = 0;
    static FILE* file = NULL;
    static char derived[1024];

    if (!checked)
    {
        checked = 1;

        const char* path = getenv("LIBGL_TSP_TEXLIFE");

        if (!path || !path[0])
        {
            const char* fbo = getenv("LIBGL_TSP_FBOPATH");

            if (fbo && fbo[0])
            {
                snprintf(
                    derived,
                    sizeof(derived),
                    "%s.texlife",
                    fbo);

                path = derived;
            }
        }

        if (path && path[0])
        {
            file = fopen(path, "w");

            if (file)
            {
                setvbuf(file, NULL, _IOLBF, 0);

                fprintf(
                    file,
                    "# TSP_TEXLIFE_V2 epoch_ms seq event fields\n");
            }
        }
    }

    return file;
}


static volatile unsigned long tsp_texlife_seq = 0;
static volatile unsigned long tsp_texlife_live = 0;
static volatile unsigned long tsp_texlife_created_n = 0;
static volatile unsigned long tsp_texlife_deleted_n = 0;


static unsigned long long tsp_texlife_ms(void)
{
    struct timeval tv;

    gettimeofday(&tv, NULL);

    return
        (unsigned long long)tv.tv_sec * 1000ULL
        + (unsigned long long)(tv.tv_usec / 1000);
}


static int tsp_texlife_interesting_size(int w, int h)
{
    if (w == 256 && h == 256)
        return 1;

    if ((w == 512 && h == 1024)
        || (w == 1024 && h == 512))
        return 1;

    /* Current world-map target is around 954x864, but retain tolerance. */
    if (w >= 850 && h >= 750)
        return 1;

    return 0;
}


static unsigned long tsp_texlife_pbo_hash(
    glbuffer_t* unpack,
    const GLvoid* data)
{
    if (!unpack || !unpack->data || unpack->size <= 0)
        return 0;

    uintptr_t off = (uintptr_t)data;

    if (off >= (uintptr_t)unpack->size)
        return 0;

    size_t bytes = (size_t)unpack->size - (size_t)off;

    /* Sample enough to distinguish changing fog payloads without hashing
     * enormous buffers on every upload. */
    if (bytes > 16384)
        bytes = 16384;

    const unsigned char* p
        = (const unsigned char*)unpack->data + off;

    unsigned long h = 2166136261u;

    for (size_t i = 0; i < bytes; ++i)
        h = (h ^ p[i]) * 16777619u;

    return h;
}


static void tsp_texlife_log(const char* fmt, ...)
{
    FILE* file = tsp_texlife_file();

    if (!file)
        return;

    unsigned long seq
        = __sync_add_and_fetch(&tsp_texlife_seq, 1);

    fprintf(
        file,
        "%llu seq=%lu ",
        tsp_texlife_ms(),
        seq);

    va_list ap;

    va_start(ap, fmt);
    vfprintf(file, fmt, ap);
    va_end(ap);

    fputc('\n', file);
}


void tsp_texlife_created(gltexture_t* tex)
{
    if (!tex || !tsp_texlife_file())
        return;

    unsigned long live
        = __sync_add_and_fetch(&tsp_texlife_live, 1);

    unsigned long created
        = __sync_add_and_fetch(&tsp_texlife_created_n, 1);

    unsigned long deleted = tsp_texlife_deleted_n;

    /* Periodic total accounting plus a few startup objects. */
    if (created <= 32 || (created & 0xffUL) == 0)
    {
        tsp_texlife_log(
            "SUMMARY cause=create live=%lu created=%lu deleted=%lu "
            "id=%u gl=%u target=0x%x",
            live,
            created,
            deleted,
            tex->texture,
            tex->glname,
            tex->target);
    }
}


void tsp_texlife_deleted(gltexture_t* tex)
{
    if (!tex || !tsp_texlife_file())
        return;

    unsigned long before = tsp_texlife_live;

    if (tsp_texlife_interesting_size(tex->width, tex->height)
        || tex->binded_fbo)
    {
        tsp_texlife_log(
            "DELETE live_before=%lu id=%u gl=%u "
            "size=%dx%d native=%dx%d "
            "fmt=0x%x type=0x%x "
            "fbo=%d att=0x%x",
            before,
            tex->texture,
            tex->glname,
            tex->width,
            tex->height,
            tex->nwidth,
            tex->nheight,
            tex->format,
            tex->type,
            tex->binded_fbo,
            tex->binded_attachment);
    }

    unsigned long live = before;

    if (before)
        live = __sync_sub_and_fetch(&tsp_texlife_live, 1);

    unsigned long deleted
        = __sync_add_and_fetch(&tsp_texlife_deleted_n, 1);

    unsigned long created = tsp_texlife_created_n;

    if (tsp_texlife_interesting_size(tex->width, tex->height)
        || tex->binded_fbo
        || (deleted & 0xffUL) == 0)
    {
        tsp_texlife_log(
            "SUMMARY cause=delete live=%lu created=%lu deleted=%lu",
            live,
            created,
            deleted);
    }
}


void tsp_texlife_image(
    const char* op,
    gltexture_t* tex,
    GLint level,
    GLsizei width,
    GLsizei height,
    GLenum format,
    GLenum type,
    const GLvoid* data,
    glbuffer_t* unpack)
{
    if (!tex || !tsp_texlife_file())
        return;

    if (!unpack
        && !tex->binded_fbo
        && !tsp_texlife_interesting_size(width, height)
        && !tsp_texlife_interesting_size(tex->width, tex->height))
    {
        return;
    }

    tsp_texlife_log(
        "%s "
        "id=%u gl=%u level=%d "
        "in=%dx%d tex=%dx%d native=%dx%d "
        "fmt=0x%x type=0x%x src=%p "
        "pbo=%u pbo_real=%u pbo_size=%ld pbo_off=%lu pbo_hash=%lu "
        "fbo=%d att=0x%x "
        "live=%lu created=%lu deleted=%lu",
        op,
        tex->texture,
        tex->glname,
        level,
        width,
        height,
        tex->width,
        tex->height,
        tex->nwidth,
        tex->nheight,
        format,
        type,
        data,
        unpack ? unpack->buffer : 0,
        unpack ? unpack->real_buffer : 0,
        unpack ? (long)unpack->size : 0L,
        unpack ? (unsigned long)(uintptr_t)data : 0UL,
        tsp_texlife_pbo_hash(unpack, data),
        tex->binded_fbo,
        tex->binded_attachment,
        tsp_texlife_live,
        tsp_texlife_created_n,
        tsp_texlife_deleted_n);
}


void tsp_texlife_attach(
    const char* op,
    gltexture_t* tex,
    GLuint fbo,
    GLenum attachment)
{
    if (!tex || !tsp_texlife_file())
        return;

    tsp_texlife_log(
        "%s "
        "id=%u gl=%u fbo=%u att=0x%x "
        "size=%dx%d native=%dx%d "
        "fmt=0x%x type=0x%x "
        "live=%lu created=%lu deleted=%lu",
        op,
        tex->texture,
        tex->glname,
        fbo,
        attachment,
        tex->width,
        tex->height,
        tex->nwidth,
        tex->nheight,
        tex->format,
        tex->type,
        tsp_texlife_live,
        tsp_texlife_created_n,
        tsp_texlife_deleted_n);
}

/* ---------------------------------------------------------------------- */

'''

s = replace_once(
    s,
    anchor,
    helper + anchor,
    "texture_params helper block"
)


# gl4es_getTexture(): count wrapper/native texture creation.
s = replace_region(
    s,
    "gltexture_t* gl4es_getTexture(GLenum target, GLuint texture)",
    "void APIENTRY_GL4ES gl4es_glBindTexture",
    """        tex->inter_format = GL_RGBA;
        tex->inter_type = GL_UNSIGNED_BYTE;
""",
    """        tex->inter_format = GL_RGBA;
        tex->inter_type = GL_UNSIGNED_BYTE;
        tsp_texlife_created(tex);
""",
    "getTexture creation"
)


# glDeleteTextures(): log before native GLES deletion / wrapper free.
s = replace_region(
    s,
    "void APIENTRY_GL4ES gl4es_glDeleteTextures",
    "void APIENTRY_GL4ES gl4es_glGenTextures",
    """                gles_glDeleteTextures(1, &tex->glname);
""",
    """                tsp_texlife_deleted(tex);
                gles_glDeleteTextures(1, &tex->glname);
""",
    "texture deletion"
)


# glGenTextures(): these wrapper records are created directly too.
s = replace_region(
    s,
    "void APIENTRY_GL4ES gl4es_glGenTextures",
    "GLboolean APIENTRY_GL4ES gl4es_glAreTexturesResident",
    """            tex->inter_format = GL_RGBA;
            tex->inter_type = GL_UNSIGNED_BYTE;
""",
    """            tex->inter_format = GL_RGBA;
            tex->inter_type = GL_UNSIGNED_BYTE;
            tsp_texlife_created(tex);
""",
    "glGenTextures creation"
)

save(p, s)


# ======================================================================
# 3. texture.c -- uncompressed TexImage/TexSubImage including PBO uploads
# ======================================================================

p = files["texture_c"]
s = load(p)

IMG_START = "void APIENTRY_GL4ES gl4es_glTexImage2D("
SUB_START = "void APIENTRY_GL4ES gl4es_glTexSubImage2D("


# Capture original API arguments before gl4es transforms dimensions/format.
s = replace_region(
    s,
    IMG_START,
    SUB_START,
    """                  GLenum format, GLenum type, const GLvoid *data) {
    DBG(""",
    """                  GLenum format, GLenum type, const GLvoid *data) {
    /* TSP_TEXLIFE_V2 */
    const GLsizei tsp_in_width = width;
    const GLsizei tsp_in_height = height;
    const GLenum tsp_in_format = format;
    const GLenum tsp_in_type = type;
    const GLvoid* tsp_in_data = data;
    glbuffer_t* tsp_in_unpack = glstate->vao->unpack;

    DBG(""",
    "TexImage argument capture"
)


s = replace_region(
    s,
    IMG_START,
    SUB_START,
    """    const GLuint itarget = what_target(target);
    const GLuint rtarget = map_tex_target(target);
""",
    """    const GLuint itarget = what_target(target);
    const GLuint rtarget = map_tex_target(target);

    gltexture_t* tsp_bound
        = glstate->texture.bound[glstate->texture.active][itarget];

    tsp_texlife_image(
        "IMG_BEGIN",
        tsp_bound,
        level,
        tsp_in_width,
        tsp_in_height,
        tsp_in_format,
        tsp_in_type,
        tsp_in_data,
        tsp_in_unpack);
""",
    "TexImage begin trace"
)


s = insert_before_function_end(
    s,
    IMG_START,
    SUB_START,
    r'''
    tsp_texlife_image(
        "IMG_END",
        tsp_bound,
        level,
        tsp_in_width,
        tsp_in_height,
        tsp_in_format,
        tsp_in_type,
        tsp_in_data,
        tsp_in_unpack);
''',
    "TexImage end trace"
)


# TexSubImage argument capture.
SUB_END = "// 1d stubs"

s = replace_region(
    s,
    SUB_START,
    SUB_END,
    """                     const GLvoid *data) {

    if (glstate->list.pending) {
""",
    """                     const GLvoid *data) {
    /* TSP_TEXLIFE_V2 */
    const GLsizei tsp_in_width = width;
    const GLsizei tsp_in_height = height;
    const GLenum tsp_in_format = format;
    const GLenum tsp_in_type = type;
    const GLvoid* tsp_in_data = data;
    glbuffer_t* tsp_in_unpack = glstate->vao->unpack;

    if (glstate->list.pending) {
""",
    "TexSubImage argument capture"
)


s = replace_region(
    s,
    SUB_START,
    SUB_END,
    """    gltexture_t *bound = glstate->texture.bound[glstate->texture.active][itarget];
""",
    """    gltexture_t *bound = glstate->texture.bound[glstate->texture.active][itarget];

    tsp_texlife_image(
        "SUB_BEGIN",
        bound,
        level,
        tsp_in_width,
        tsp_in_height,
        tsp_in_format,
        tsp_in_type,
        tsp_in_data,
        tsp_in_unpack);
""",
    "TexSubImage begin trace"
)


s = insert_before_function_end(
    s,
    SUB_START,
    SUB_END,
    r'''
    tsp_texlife_image(
        "SUB_END",
        bound,
        level,
        tsp_in_width,
        tsp_in_height,
        tsp_in_format,
        tsp_in_type,
        tsp_in_data,
        tsp_in_unpack);
''',
    "TexSubImage end trace"
)

save(p, s)


# ======================================================================
# 4. framebuffers.c -- correlate native texture IDs with FBO lifetime
# ======================================================================

p = files["framebuffers"]
s = load(p)

s = replace_once(
    s,
    """            DBG(printf("Detach Texture %d from FBO %d as Attachement %s\\n", old->glname, old->binded_fbo, PrintEnum(old->binded_attachment));)
            old->binded_fbo = 0;
            old->binded_attachment = 0;
""",
    """            DBG(printf("Detach Texture %d from FBO %d as Attachement %s\\n", old->glname, old->binded_fbo, PrintEnum(old->binded_attachment));)
            /* TSP_TEXLIFE_V2 */
            tsp_texlife_attach(
                "DETACH",
                old,
                old->binded_fbo,
                old->binded_attachment);
            old->binded_fbo = 0;
            old->binded_attachment = 0;
""",
    "FBO detach trace"
)


s = replace_once(
    s,
    """        tex->binded_fbo = fb->id;
        tex->binded_attachment = attachment;
""",
    """        tex->binded_fbo = fb->id;
        tex->binded_attachment = attachment;
        /* TSP_TEXLIFE_V2 */
        tsp_texlife_attach("ATTACH", tex, fb->id, attachment);
""",
    "FBO attach trace"
)

save(p, s)


# ======================================================================
# 5. OpenMW LocalMap ownership / RTT / fog lifetime
# ======================================================================

p = files["localmap"]
s = load(p)


# Helper placed in the existing implementation namespace.
anchor = "    std::pair<int, int> divideIntoSegments"

helper = r'''    // TSP_MAPLIFE_V2
    static unsigned long tspMapLifeGeneration = 0;

    static bool tspMapLifeEnabled()
    {
        return std::getenv("TSP_MAPLIFE") != nullptr
            || std::getenv("TSP_GMAP_DUMP") != nullptr;
    }

'''

s = replace_once(
    s,
    anchor,
    helper + anchor,
    "LocalMap helper"
)


s = replace_once(
    s,
    """    LocalMap::~LocalMap()
    {
        for (auto& rtt : mLocalMapRTTs)
            mRoot->removeChild(rtt);
    }
""",
    """    LocalMap::~LocalMap()
    {
        if (tspMapLifeEnabled())
        {
            Log(Debug::Warning)
                << "TSP_MAPLIFE_V2 phase=destruct"
                << " gen=" << tspMapLifeGeneration
                << " ext=" << mExteriorSegments.size()
                << " interior=" << mInteriorSegments.size()
                << " rtt=" << mLocalMapRTTs.size();
        }

        for (auto& rtt : mLocalMapRTTs)
            mRoot->removeChild(rtt);
    }
""",
    "LocalMap destructor"
)


s = replace_once(
    s,
    """    void LocalMap::clear()
    {
        mExteriorSegments.clear();
        mInteriorSegments.clear();
    }
""",
    """    void LocalMap::clear()
    {
        ++tspMapLifeGeneration;

        if (tspMapLifeEnabled())
        {
            Log(Debug::Warning)
                << "TSP_MAPLIFE_V2 phase=clear_begin"
                << " gen=" << tspMapLifeGeneration
                << " ext=" << mExteriorSegments.size()
                << " interior=" << mInteriorSegments.size()
                << " rtt=" << mLocalMapRTTs.size();
        }

        mExteriorSegments.clear();
        mInteriorSegments.clear();

        if (tspMapLifeEnabled())
        {
            Log(Debug::Warning)
                << "TSP_MAPLIFE_V2 phase=clear_end"
                << " gen=" << tspMapLifeGeneration
                << " ext=" << mExteriorSegments.size()
                << " interior=" << mInteriorSegments.size()
                << " rtt=" << mLocalMapRTTs.size();
        }
    }
""",
    "LocalMap clear"
)


s = replace_once(
    s,
    """        segment.mMapTexture = static_cast<osg::Texture2D*>(mLocalMapRTTs.back()->getColorTexture(nullptr));
""",
    """        segment.mMapTexture = static_cast<osg::Texture2D*>(mLocalMapRTTs.back()->getColorTexture(nullptr));

        if (tspMapLifeEnabled())
        {
            Log(Debug::Warning)
                << "TSP_MAPLIFE_V2 phase=rtt_create"
                << " gen=" << tspMapLifeGeneration
                << " cell=" << segmentX << "," << segmentY
                << " interior=" << (mInterior ? 1 : 0)
                << " resolution=" << mMapResolution
                << " texture="
                << static_cast<const void*>(segment.mMapTexture.get())
                << " rtt_count=" << mLocalMapRTTs.size();
        }
""",
    "LocalMap RTT create"
)


s = replace_once(
    s,
    """    void LocalMap::removeExteriorCell(int x, int y)
    {
        mExteriorSegments.erase({ x, y });
    }
""",
    """    void LocalMap::removeExteriorCell(int x, int y)
    {
        const auto it = mExteriorSegments.find({ x, y });

        if (tspMapLifeEnabled())
        {
            Log(Debug::Warning)
                << "TSP_MAPLIFE_V2 phase=remove_ext"
                << " gen=" << tspMapLifeGeneration
                << " cell=" << x << "," << y
                << " found=" << (it != mExteriorSegments.end() ? 1 : 0)
                << " maptex="
                << (it != mExteriorSegments.end()
                        && it->second.mMapTexture
                    ? 1 : 0)
                << " fogtex="
                << (it != mExteriorSegments.end()
                        && it->second.mFogOfWarTexture
                    ? 1 : 0)
                << " ext_before=" << mExteriorSegments.size();
        }

        mExteriorSegments.erase({ x, y });
    }
""",
    "LocalMap exterior removal"
)


s = replace_once(
    s,
    """    void LocalMap::cleanupCameras()
    {
        auto it = mLocalMapRTTs.begin();
        while (it != mLocalMapRTTs.end())
        {
            if (!(*it)->mActive)
            {
                mRoot->removeChild(*it);
                it = mLocalMapRTTs.erase(it);
            }
            else
                it++;
        }
    }
""",
    """    void LocalMap::cleanupCameras()
    {
        const std::size_t before = mLocalMapRTTs.size();
        std::size_t removed = 0;

        auto it = mLocalMapRTTs.begin();

        while (it != mLocalMapRTTs.end())
        {
            if (!(*it)->mActive)
            {
                mRoot->removeChild(*it);
                it = mLocalMapRTTs.erase(it);
                ++removed;
            }
            else
                it++;
        }

        if (tspMapLifeEnabled() && removed)
        {
            Log(Debug::Warning)
                << "TSP_MAPLIFE_V2 phase=rtt_cleanup"
                << " gen=" << tspMapLifeGeneration
                << " before=" << before
                << " removed=" << removed
                << " after=" << mLocalMapRTTs.size()
                << " ext=" << mExteriorSegments.size()
                << " interior=" << mInteriorSegments.size();
        }
    }
""",
    "LocalMap RTT cleanup"
)


s = replace_once(
    s,
    """        mFogOfWarTexture->setUnRefImageDataAfterApply(false);
        mFogOfWarTexture->setImage(mFogOfWarImage);
""",
    """        mFogOfWarTexture->setUnRefImageDataAfterApply(false);
        mFogOfWarTexture->setImage(mFogOfWarImage);

        if (tspMapLifeEnabled())
        {
            Log(Debug::Warning)
                << "TSP_MAPLIFE_V2 phase=fog_texture"
                << " gen=" << tspMapLifeGeneration
                << " texture="
                << static_cast<const void*>(mFogOfWarTexture.get())
                << " image="
                << static_cast<const void*>(mFogOfWarImage.get())
                << " size="
                << (mFogOfWarImage ? mFogOfWarImage->s() : 0)
                << "x"
                << (mFogOfWarImage ? mFogOfWarImage->t() : 0);
        }
""",
    "fog texture creation"
)


s = replace_once(
    s,
    """        mFogOfWarImage->setPixelBufferObject(new osg::PixelBufferObject);
        mFogOfWarImage->allocateImage(sFogOfWarResolution, sFogOfWarResolution, 1, GL_RGBA, GL_UNSIGNED_BYTE);
""",
    """        mFogOfWarImage->setPixelBufferObject(new osg::PixelBufferObject);
        mFogOfWarImage->allocateImage(sFogOfWarResolution, sFogOfWarResolution, 1, GL_RGBA, GL_UNSIGNED_BYTE);

        if (tspMapLifeEnabled())
        {
            Log(Debug::Warning)
                << "TSP_MAPLIFE_V2 phase=fog_image"
                << " gen=" << tspMapLifeGeneration
                << " image="
                << static_cast<const void*>(mFogOfWarImage.get())
                << " size=" << sFogOfWarResolution
                << "x" << sFogOfWarResolution
                << " pbo=1";
        }
""",
    "fog PBO image creation"
)

save(p, s)


# ======================================================================
# Post-edit validation
# ======================================================================

checks = {
    files["texture_h"]: [
        "TSP_TEXLIFE_V2",
        "tsp_texlife_image",
        "tsp_texlife_attach",
    ],
    files["texture_params"]: [
        "TSP_TEXLIFE_V2",
        "tsp_texlife_created",
        "tsp_texlife_deleted",
        "pbo_hash",
    ],
    files["texture_c"]: [
        "TSP_TEXLIFE_V2",
        '"IMG_BEGIN"',
        '"IMG_END"',
        '"SUB_BEGIN"',
        '"SUB_END"',
    ],
    files["framebuffers"]: [
        "TSP_TEXLIFE_V2",
        '"ATTACH"',
        '"DETACH"',
    ],
    files["localmap"]: [
        "TSP_MAPLIFE_V2",
        "phase=clear_begin",
        "phase=rtt_create",
        "phase=rtt_cleanup",
        "phase=fog_image",
        "phase=fog_texture",
    ],
}

for path, needles in checks.items():
    text = load(path)

    for needle in needles:
        if needle not in text:
            raise RuntimeError(
                f"post-patch validation missing {needle!r} in {path}"
            )

print("TSP MAP/TEXTURE V2 source instrumentation applied successfully.")
PY

echo "      Source edits completed."

echo "[4/7] Running source validation..."

docker exec openmw_builder bash -lc '
    set -e

    cd /root/gl4es-tsps

    git diff --check -- \
        src/gl/texture.h \
        src/gl/texture_params.c \
        src/gl/texture.c \
        src/gl/framebuffers.c

    grep -q "TSP_TEXLIFE_V2" src/gl/texture_params.c
    grep -q "\"IMG_BEGIN\"" src/gl/texture.c
    grep -q "\"SUB_BEGIN\"" src/gl/texture.c
    grep -q "\"ATTACH\"" src/gl/framebuffers.c

    cd /root/openmw-0.51-tsp-src

    git diff --check -- \
        apps/openmw/mwrender/localmap.cpp

    grep -q "TSP_MAPLIFE_V2" \
        apps/openmw/mwrender/localmap.cpp
' >>"$LOG" 2>&1

echo "      Source validation passed."

echo "[5/7] Building gl4es..."

docker exec openmw_builder bash -lc '
    set -e
    /root/rebuild_gl4es_tsps_o3.sh
' >>"$LOG" 2>&1

echo "      gl4es completed."

echo "[6/7] Building OpenMW..."

docker exec openmw_builder bash -lc '
    set -e
    cmake --build /root/openmw-0.51-tsp-build \
        --target openmw \
        -j2
' >>"$LOG" 2>&1

echo "      OpenMW completed."

echo "[7/7] Exporting and validating binaries..."

rm -f "$GL_OUT" "$OMW_OUT"

docker cp \
    openmw_builder:/root/gl4es-tsps/lib/libGL.so.1 \
    "$GL_OUT" >>"$LOG" 2>&1

OPENMW_BIN="$(
    docker exec openmw_builder bash -lc '
        find /root/openmw-0.51-tsp-build \
            -type f \
            -name openmw \
            -perm -111 \
            -print \
        | head -n 1
    ' 2>>"$LOG" | tr -d '\r'
)"

if [ -z "$OPENMW_BIN" ]; then
    echo "ERROR: could not locate built OpenMW binary" >>"$LOG"
    false
fi

docker cp \
    "openmw_builder:$OPENMW_BIN" \
    "$OMW_OUT" >>"$LOG" 2>&1

chmod +x "$OMW_OUT"

strings "$GL_OUT" |
    grep -q "TSP_TEXLIFE_V2"

strings "$OMW_OUT" |
    grep -q "TSP_MAPLIFE_V2"

{
    echo
    echo "===== FINAL ARTIFACTS ====="
    ls -lh "$GL_OUT" "$OMW_OUT"
    echo
    sha256sum "$GL_OUT" "$OMW_OUT"
    echo
    echo "===== MARKERS ====="
    strings "$GL_OUT" |
        grep -E "TSP_TEXLIFE_V2" |
        sort -u

    strings "$OMW_OUT" |
        grep -E "TSP_MAPLIFE_V2" |
        sort -u
} >>"$LOG" 2>&1

echo
echo "============================================================"
echo "SUCCESS"
echo
echo "Built libGL:"
echo "  $GL_OUT"
echo
echo "Built OpenMW:"
echo "  $OMW_OUT"
echo
echo "Pre-build source backup:"
echo "  $BACKUP"
echo
echo "Full log:"
echo "  $LOG"
echo
echo "SHA256:"
sha256sum "$GL_OUT" "$OMW_OUT"
echo "============================================================"

