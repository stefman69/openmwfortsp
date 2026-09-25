#define _GNU_SOURCE

#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include <GLES2/gl2.h>

typedef void (*copy_fn)(
    GLenum, GLint, GLint, GLint,
    GLint, GLint, GLsizei, GLsizei);

typedef void (*read_fn)(
    GLint, GLint, GLsizei, GLsizei,
    GLenum, GLenum, void *);

typedef void (*texsub_fn)(
    GLenum, GLint, GLint, GLint,
    GLsizei, GLsizei,
    GLenum, GLenum, const void *);

typedef GLenum (*geterror_fn)(void);
typedef void (*getint_fn)(GLenum, GLint *);
typedef void (*pixelstore_fn)(GLenum, GLint);

static copy_fn real_copy = NULL;
static read_fn real_read = NULL;
static texsub_fn real_texsub = NULL;
static geterror_fn real_geterror = NULL;
static getint_fn real_getint = NULL;
static pixelstore_fn real_pixelstore = NULL;

static pthread_once_t resolve_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t map_lock = PTHREAD_MUTEX_INITIALIZER;

static unsigned char *cpu_buffer = NULL;
static size_t cpu_capacity = 0;

static unsigned long copy_calls = 0;
static unsigned long map_calls = 0;

static int enabled = 0;
static int map_size = 256;

static const char *gl_error_name(GLenum error)
{
    switch (error)
    {
        case GL_NO_ERROR:
            return "GL_NO_ERROR";

        case GL_INVALID_ENUM:
            return "GL_INVALID_ENUM";

        case GL_INVALID_VALUE:
            return "GL_INVALID_VALUE";

        case GL_INVALID_OPERATION:
            return "GL_INVALID_OPERATION";

        case GL_OUT_OF_MEMORY:
            return "GL_OUT_OF_MEMORY";

#ifdef GL_INVALID_FRAMEBUFFER_OPERATION
        case GL_INVALID_FRAMEBUFFER_OPERATION:
            return "GL_INVALID_FRAMEBUFFER_OPERATION";
#endif

        default:
            return "UNKNOWN_GL_ERROR";
    }
}

static void resolve_gl(void)
{
    real_copy =
        (copy_fn)dlsym(
            RTLD_NEXT,
            "glCopyTexSubImage2D");

    real_read =
        (read_fn)dlsym(
            RTLD_NEXT,
            "glReadPixels");

    real_texsub =
        (texsub_fn)dlsym(
            RTLD_NEXT,
            "glTexSubImage2D");

    real_geterror =
        (geterror_fn)dlsym(
            RTLD_NEXT,
            "glGetError");

    real_getint =
        (getint_fn)dlsym(
            RTLD_NEXT,
            "glGetIntegerv");

    real_pixelstore =
        (pixelstore_fn)dlsym(
            RTLD_NEXT,
            "glPixelStorei");

    fprintf(
        stderr,
        "TSP_MAP_COPY_CPU_V1 RESOLVE "
        "copy=%p read=%p upload=%p "
        "geterror=%p getint=%p pixelstore=%p\n",
        (void *)real_copy,
        (void *)real_read,
        (void *)real_texsub,
        (void *)real_geterror,
        (void *)real_getint,
        (void *)real_pixelstore);

    fflush(stderr);
}

__attribute__((constructor))
static void tsp_map_copy_cpu_init(void)
{
    const char *value =
        getenv("TSP_MAP_COPY_CPU");

    enabled =
        value != NULL &&
        value[0] == '1' &&
        value[1] == '\0';

    const char *size_value =
        getenv("TSP_MAP_COPY_CPU_SIZE");

    if (size_value != NULL &&
        size_value[0] != '\0')
    {
        int parsed = atoi(size_value);

        if (parsed >= 16 &&
            parsed <= 4096)
        {
            map_size = parsed;
        }
    }

    fprintf(
        stderr,
        "TSP_MAP_COPY_CPU_V1 LOADED "
        "enabled=%d "
        "size=%d "
        "path=framebuffer-to-CPU-to-texture\n",
        enabled,
        map_size);

    fflush(stderr);
}

__attribute__((destructor))
static void tsp_map_copy_cpu_fini(void)
{
    free(cpu_buffer);
    cpu_buffer = NULL;
    cpu_capacity = 0;
}

void glCopyTexSubImage2D(
    GLenum target,
    GLint level,
    GLint xoffset,
    GLint yoffset,
    GLint x,
    GLint y,
    GLsizei width,
    GLsizei height)
{
    pthread_once(
        &resolve_once,
        resolve_gl);

    ++copy_calls;

    const int local_map_candidate =
        enabled &&
        target == GL_TEXTURE_2D &&
        level == 0 &&
        xoffset == 0 &&
        yoffset == 0 &&
        x == 0 &&
        y == 0 &&
        width == map_size &&
        height == map_size;

    if (!local_map_candidate)
    {
        if (real_copy != NULL)
        {
            real_copy(
                target,
                level,
                xoffset,
                yoffset,
                x,
                y,
                width,
                height);
        }
        else
        {
            fprintf(
                stderr,
                "TSP_MAP_COPY_CPU_V1 FATAL "
                "reason=real-copy-unresolved "
                "call=%lu\n",
                copy_calls);

            fflush(stderr);
        }

        return;
    }

    pthread_mutex_lock(
        &map_lock);

    ++map_calls;

    fprintf(
        stderr,
        "TSP_MAP_COPY_CPU_V1 INTERCEPT_BEGIN "
        "map_call=%lu "
        "copy_call=%lu "
        "size=%dx%d\n",
        map_calls,
        copy_calls,
        (int)width,
        (int)height);

    fflush(stderr);

    if (real_copy == NULL ||
        real_read == NULL ||
        real_texsub == NULL ||
        real_geterror == NULL ||
        real_getint == NULL ||
        real_pixelstore == NULL)
    {
        fprintf(
            stderr,
            "TSP_MAP_COPY_CPU_V1 INTERCEPT_FAIL "
            "map_call=%lu "
            "stage=resolve "
            "reason=required-GL-symbol-missing "
            "action=fallback-original-copy\n",
            map_calls);

        fflush(stderr);

        if (real_copy != NULL)
        {
            real_copy(
                target,
                level,
                xoffset,
                yoffset,
                x,
                y,
                width,
                height);
        }

        pthread_mutex_unlock(
            &map_lock);

        return;
    }

    const size_t pixel_count =
        (size_t)width *
        (size_t)height;

    const size_t byte_count =
        pixel_count * 4;

    if (cpu_capacity < byte_count)
    {
        unsigned char *new_buffer =
            realloc(
                cpu_buffer,
                byte_count);

        if (new_buffer == NULL)
        {
            fprintf(
                stderr,
                "TSP_MAP_COPY_CPU_V1 INTERCEPT_FAIL "
                "map_call=%lu "
                "stage=allocate "
                "reason=out-of-memory "
                "bytes=%zu "
                "action=fallback-original-copy\n",
                map_calls,
                byte_count);

            fflush(stderr);

            real_copy(
                target,
                level,
                xoffset,
                yoffset,
                x,
                y,
                width,
                height);

            pthread_mutex_unlock(
                &map_lock);

            return;
        }

        cpu_buffer = new_buffer;
        cpu_capacity = byte_count;

        fprintf(
            stderr,
            "TSP_MAP_COPY_CPU_V1 BUFFER_READY "
            "bytes=%zu\n",
            cpu_capacity);

        fflush(stderr);
    }

    /*
     * Drain errors that existed before this wrapper call.
     */
    for (int i = 0;
         i < 16;
         ++i)
    {
        GLenum error =
            real_geterror();

        if (error == GL_NO_ERROR)
            break;

        fprintf(
            stderr,
            "TSP_MAP_COPY_CPU_V1 PREEXISTING_GL_ERROR "
            "map_call=%lu "
            "error=0x%x "
            "name=%s\n",
            map_calls,
            error,
            gl_error_name(error));
    }

    GLint old_pack = 4;
    GLint old_unpack = 4;

    real_getint(
        GL_PACK_ALIGNMENT,
        &old_pack);

    real_getint(
        GL_UNPACK_ALIGNMENT,
        &old_unpack);

    real_pixelstore(
        GL_PACK_ALIGNMENT,
        1);

    real_pixelstore(
        GL_UNPACK_ALIGNMENT,
        1);

    fprintf(
        stderr,
        "TSP_MAP_COPY_CPU_V1 READ_BEGIN "
        "map_call=%lu "
        "source=framebuffer "
        "size=%dx%d "
        "format=RGBA8\n",
        map_calls,
        (int)width,
        (int)height);

    fflush(stderr);

    real_read(
        x,
        y,
        width,
        height,
        GL_RGBA,
        GL_UNSIGNED_BYTE,
        cpu_buffer);

    GLenum read_error =
        real_geterror();

    if (read_error != GL_NO_ERROR)
    {
        real_pixelstore(
            GL_PACK_ALIGNMENT,
            old_pack);

        real_pixelstore(
            GL_UNPACK_ALIGNMENT,
            old_unpack);

        fprintf(
            stderr,
            "TSP_MAP_COPY_CPU_V1 READ_FAIL "
            "map_call=%lu "
            "error=0x%x "
            "name=%s "
            "action=fallback-original-copy\n",
            map_calls,
            read_error,
            gl_error_name(read_error));

        fflush(stderr);

        real_copy(
            target,
            level,
            xoffset,
            yoffset,
            x,
            y,
            width,
            height);

        pthread_mutex_unlock(
            &map_lock);

        return;
    }

    unsigned int min_rgb = 255;
    unsigned int max_rgb = 0;

    size_t white_pixels = 0;
    size_t black_pixels = 0;
    size_t colored_pixels = 0;

    uint64_t hash =
        UINT64_C(1469598103934665603);

    for (size_t offset = 0;
         offset < byte_count;
         offset += 4)
    {
        unsigned int r =
            cpu_buffer[offset + 0];

        unsigned int g =
            cpu_buffer[offset + 1];

        unsigned int b =
            cpu_buffer[offset + 2];

        if (r < min_rgb)
            min_rgb = r;

        if (g < min_rgb)
            min_rgb = g;

        if (b < min_rgb)
            min_rgb = b;

        if (r > max_rgb)
            max_rgb = r;

        if (g > max_rgb)
            max_rgb = g;

        if (b > max_rgb)
            max_rgb = b;

        if (r >= 250 &&
            g >= 250 &&
            b >= 250)
        {
            ++white_pixels;
        }

        if (r <= 5 &&
            g <= 5 &&
            b <= 5)
        {
            ++black_pixels;
        }

        if (!(r == g &&
              g == b))
        {
            ++colored_pixels;
        }

        hash ^= r;
        hash *= UINT64_C(1099511628211);

        hash ^= g;
        hash *= UINT64_C(1099511628211);

        hash ^= b;
        hash *= UINT64_C(1099511628211);
    }

    fprintf(
        stderr,
        "TSP_MAP_COPY_CPU_V1 READ_PASS "
        "map_call=%lu "
        "bytes=%zu "
        "rgb=%u..%u "
        "white=%zu/%zu "
        "black=%zu/%zu "
        "colored=%zu/%zu "
        "hash=%llu\n",
        map_calls,
        byte_count,
        min_rgb,
        max_rgb,
        white_pixels,
        pixel_count,
        black_pixels,
        pixel_count,
        colored_pixels,
        pixel_count,
        (unsigned long long)hash);

    if (white_pixels == pixel_count)
    {
        fprintf(
            stderr,
            "TSP_MAP_COPY_CPU_V1 SOURCE_BAD "
            "map_call=%lu "
            "reason=framebuffer-all-white\n",
            map_calls);
    }

    if (black_pixels == pixel_count)
    {
        fprintf(
            stderr,
            "TSP_MAP_COPY_CPU_V1 SOURCE_BAD "
            "map_call=%lu "
            "reason=framebuffer-all-black\n",
            map_calls);
    }

    fprintf(
        stderr,
        "TSP_MAP_COPY_CPU_V1 UPLOAD_BEGIN "
        "map_call=%lu "
        "destination=current-bound-map-texture "
        "method=glTexSubImage2D\n",
        map_calls);

    fflush(stderr);

    /*
     * Replace framebuffer->texture copy with:
     *
     * framebuffer -> client CPU RGBA -> bound texture
     */
    real_texsub(
        target,
        level,
        xoffset,
        yoffset,
        width,
        height,
        GL_RGBA,
        GL_UNSIGNED_BYTE,
        cpu_buffer);

    GLenum upload_error =
        real_geterror();

    real_pixelstore(
        GL_PACK_ALIGNMENT,
        old_pack);

    real_pixelstore(
        GL_UNPACK_ALIGNMENT,
        old_unpack);

    if (upload_error != GL_NO_ERROR)
    {
        fprintf(
            stderr,
            "TSP_MAP_COPY_CPU_V1 UPLOAD_FAIL "
            "map_call=%lu "
            "error=0x%x "
            "name=%s "
            "action=fallback-original-copy\n",
            map_calls,
            upload_error,
            gl_error_name(upload_error));

        fflush(stderr);

        real_copy(
            target,
            level,
            xoffset,
            yoffset,
            x,
            y,
            width,
            height);

        pthread_mutex_unlock(
            &map_lock);

        return;
    }

    fprintf(
        stderr,
        "TSP_MAP_COPY_CPU_V1 INTERCEPT_PASS "
        "map_call=%lu "
        "path=framebuffer->CPU->map-texture\n",
        map_calls);

    fflush(stderr);

    pthread_mutex_unlock(
        &map_lock);
}
