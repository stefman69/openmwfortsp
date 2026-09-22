#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef void SDL_Window;

typedef unsigned int GLenum;
typedef unsigned int GLuint;
typedef unsigned int GLbitfield;
typedef unsigned char GLboolean;
typedef int GLint;
typedef int GLsizei;
typedef float GLfloat;
typedef char GLchar;
typedef intptr_t GLsizeiptr;

typedef void* EGLDisplay;
typedef void* EGLSurface;
typedef unsigned int EGLBoolean;

#define GL_FALSE 0
#define GL_TRUE 1

#define GL_TEXTURE_2D 0x0DE1
#define GL_TEXTURE7 0x84C7
#define GL_ACTIVE_TEXTURE 0x84E0
#define GL_TEXTURE_BINDING_2D 0x8069

#define GL_ARRAY_BUFFER 0x8892
#define GL_ARRAY_BUFFER_BINDING 0x8894
#define GL_STATIC_DRAW 0x88E4

#define GL_FRAMEBUFFER 0x8D40
#define GL_FRAMEBUFFER_BINDING 0x8CA6

#define GL_VIEWPORT 0x0BA2
#define GL_SCISSOR_BOX 0x0C10
#define GL_CURRENT_PROGRAM 0x8B8D
#define GL_COLOR_WRITEMASK 0x0C23
#define GL_COLOR_CLEAR_VALUE 0x0C22
#define GL_COLOR_BUFFER_BIT 0x00004000

#define GL_BLEND 0x0BE2
#define GL_DEPTH_TEST 0x0B71
#define GL_STENCIL_TEST 0x0B90
#define GL_CULL_FACE 0x0B44
#define GL_SCISSOR_TEST 0x0C11

#define GL_VERTEX_SHADER 0x8B31
#define GL_FRAGMENT_SHADER 0x8B30
#define GL_COMPILE_STATUS 0x8B81
#define GL_LINK_STATUS 0x8B82

#define GL_RGBA 0x1908
#define GL_UNSIGNED_BYTE 0x1401
#define GL_FLOAT 0x1406

#define GL_TEXTURE_MIN_FILTER 0x2801
#define GL_TEXTURE_MAG_FILTER 0x2800
#define GL_TEXTURE_WRAP_S 0x2802
#define GL_TEXTURE_WRAP_T 0x2803
#define GL_LINEAR 0x2601
#define GL_NEAREST 0x2600
#define GL_CLAMP_TO_EDGE 0x812F

#define GL_TRIANGLE_STRIP 0x0005

#define GL_VERTEX_ATTRIB_ARRAY_ENABLED 0x8622
#define GL_VERTEX_ATTRIB_ARRAY_SIZE 0x8623
#define GL_VERTEX_ATTRIB_ARRAY_STRIDE 0x8624
#define GL_VERTEX_ATTRIB_ARRAY_TYPE 0x8625
#define GL_VERTEX_ATTRIB_ARRAY_NORMALIZED 0x886A
#define GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING 0x889F
#define GL_VERTEX_ATTRIB_ARRAY_POINTER 0x8645

#define ATTR_POS 6
#define ATTR_UV 7

typedef void (*PFN_SDL_GL_SWAPWINDOW)(SDL_Window*);
typedef void (*PFN_SDL_GL_GETDRAWABLESIZE)(SDL_Window*, int*, int*);
typedef EGLBoolean (*PFN_EGLSWAPBUFFERS)(EGLDisplay, EGLSurface);

typedef void (*PFN_glGetIntegerv)(GLenum, GLint*);
typedef void (*PFN_glGetBooleanv)(GLenum, GLboolean*);
typedef void (*PFN_glGetFloatv)(GLenum, GLfloat*);
typedef GLboolean (*PFN_glIsEnabled)(GLenum);
typedef void (*PFN_glEnable)(GLenum);
typedef void (*PFN_glDisable)(GLenum);
typedef void (*PFN_glViewport)(GLint, GLint, GLsizei, GLsizei);
typedef void (*PFN_glScissor)(GLint, GLint, GLsizei, GLsizei);
typedef void (*PFN_glColorMask)(GLboolean, GLboolean, GLboolean, GLboolean);
typedef void (*PFN_glClearColor)(GLfloat, GLfloat, GLfloat, GLfloat);
typedef void (*PFN_glClear)(GLbitfield);

typedef void (*PFN_glActiveTexture)(GLenum);
typedef void (*PFN_glGenTextures)(GLsizei, GLuint*);
typedef void (*PFN_glBindTexture)(GLenum, GLuint);
typedef void (*PFN_glTexParameteri)(GLenum, GLenum, GLint);
typedef void (*PFN_glTexImage2D)(
    GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void*);
typedef void (*PFN_glCopyTexSubImage2D)(
    GLenum, GLint, GLint, GLint, GLint, GLint, GLsizei, GLsizei);

typedef GLuint (*PFN_glCreateShader)(GLenum);
typedef void (*PFN_glShaderSource)(GLuint, GLsizei, const GLchar* const*, const GLint*);
typedef void (*PFN_glCompileShader)(GLuint);
typedef void (*PFN_glGetShaderiv)(GLuint, GLenum, GLint*);
typedef void (*PFN_glGetShaderInfoLog)(GLuint, GLsizei, GLsizei*, GLchar*);
typedef void (*PFN_glDeleteShader)(GLuint);

typedef GLuint (*PFN_glCreateProgram)(void);
typedef void (*PFN_glAttachShader)(GLuint, GLuint);
typedef void (*PFN_glBindAttribLocation)(GLuint, GLuint, const GLchar*);
typedef void (*PFN_glLinkProgram)(GLuint);
typedef void (*PFN_glGetProgramiv)(GLuint, GLenum, GLint*);
typedef void (*PFN_glGetProgramInfoLog)(GLuint, GLsizei, GLsizei*, GLchar*);
typedef void (*PFN_glUseProgram)(GLuint);
typedef GLint (*PFN_glGetUniformLocation)(GLuint, const GLchar*);
typedef void (*PFN_glUniform1i)(GLint, GLint);

typedef void (*PFN_glGenBuffers)(GLsizei, GLuint*);
typedef void (*PFN_glBindBuffer)(GLenum, GLuint);
typedef void (*PFN_glBufferData)(GLenum, GLsizeiptr, const void*, GLenum);

typedef void (*PFN_glVertexAttribPointer)(
    GLuint, GLint, GLenum, GLboolean, GLsizei, const void*);
typedef void (*PFN_glEnableVertexAttribArray)(GLuint);
typedef void (*PFN_glDisableVertexAttribArray)(GLuint);
typedef void (*PFN_glGetVertexAttribiv)(GLuint, GLenum, GLint*);
typedef void (*PFN_glGetVertexAttribPointerv)(GLuint, GLenum, void**);
typedef void (*PFN_glDrawArrays)(GLenum, GLint, GLsizei);

typedef void (*PFN_glBindFramebuffer)(GLenum, GLuint);

static PFN_SDL_GL_SWAPWINDOW real_SDL_GL_SwapWindow = NULL;
static PFN_SDL_GL_GETDRAWABLESIZE real_SDL_GL_GetDrawableSize = NULL;
static PFN_EGLSWAPBUFFERS real_eglSwapBuffers = NULL;

static void* g_gles = NULL;
static int g_gles_ready = 0;
static int g_disabled = 0;
static int g_scale_enabled = 0;
static int g_fps_enabled = 0;
static int g_first_frame_logged = 0;
static int g_last_loading_bypass = -1;

static int g_source_w = 0;
static int g_source_h = 0;
static int g_output_w = 1280;
static int g_output_h = 720;
static int g_linear = 1;

static GLuint g_program = 0;
static GLuint g_texture = 0;
static GLuint g_vbo = 0;
static GLint g_sampler = -1;
static int g_texture_w = 0;
static int g_texture_h = 0;

static double g_display_fps = 0.0;
static unsigned long g_fps_frames = 0;
static struct timespec g_fps_last = {0, 0};

static __thread int g_inside_sdl_swap = 0;

static PFN_glGetIntegerv p_glGetIntegerv;
static PFN_glGetBooleanv p_glGetBooleanv;
static PFN_glGetFloatv p_glGetFloatv;
static PFN_glIsEnabled p_glIsEnabled;
static PFN_glEnable p_glEnable;
static PFN_glDisable p_glDisable;
static PFN_glViewport p_glViewport;
static PFN_glScissor p_glScissor;
static PFN_glColorMask p_glColorMask;
static PFN_glClearColor p_glClearColor;
static PFN_glClear p_glClear;

static PFN_glActiveTexture p_glActiveTexture;
static PFN_glGenTextures p_glGenTextures;
static PFN_glBindTexture p_glBindTexture;
static PFN_glTexParameteri p_glTexParameteri;
static PFN_glTexImage2D p_glTexImage2D;
static PFN_glCopyTexSubImage2D p_glCopyTexSubImage2D;

static PFN_glCreateShader p_glCreateShader;
static PFN_glShaderSource p_glShaderSource;
static PFN_glCompileShader p_glCompileShader;
static PFN_glGetShaderiv p_glGetShaderiv;
static PFN_glGetShaderInfoLog p_glGetShaderInfoLog;
static PFN_glDeleteShader p_glDeleteShader;

static PFN_glCreateProgram p_glCreateProgram;
static PFN_glAttachShader p_glAttachShader;
static PFN_glBindAttribLocation p_glBindAttribLocation;
static PFN_glLinkProgram p_glLinkProgram;
static PFN_glGetProgramiv p_glGetProgramiv;
static PFN_glGetProgramInfoLog p_glGetProgramInfoLog;
static PFN_glUseProgram p_glUseProgram;
static PFN_glGetUniformLocation p_glGetUniformLocation;
static PFN_glUniform1i p_glUniform1i;

static PFN_glGenBuffers p_glGenBuffers;
static PFN_glBindBuffer p_glBindBuffer;
static PFN_glBufferData p_glBufferData;

static PFN_glVertexAttribPointer p_glVertexAttribPointer;
static PFN_glEnableVertexAttribArray p_glEnableVertexAttribArray;
static PFN_glDisableVertexAttribArray p_glDisableVertexAttribArray;
static PFN_glGetVertexAttribiv p_glGetVertexAttribiv;
static PFN_glGetVertexAttribPointerv p_glGetVertexAttribPointerv;
static PFN_glDrawArrays p_glDrawArrays;

static PFN_glBindFramebuffer p_glBindFramebuffer;

static void parse_size(const char* value, int* w, int* h)
{
    if (!value || !w || !h)
        return;

    int tw = 0;
    int th = 0;

    if (sscanf(value, "%dx%d", &tw, &th) == 2 && tw > 0 && th > 0)
    {
        *w = tw;
        *h = th;
    }
}

static int env_is_one(const char* name)
{
    const char* value = getenv(name);
    return value && strcmp(value, "1") == 0;
}

static void load_config(void)
{
    g_scale_enabled = env_is_one("TSP_FULLSCREEN_SCALE");
    g_fps_enabled = env_is_one("TSP_FPS_OVERLAY");

    parse_size(getenv("TSP_SCALE_SOURCE"), &g_source_w, &g_source_h);
    parse_size(getenv("TSP_SCALE_OUTPUT"), &g_output_w, &g_output_h);

    const char* filter = getenv("TSP_SCALE_FILTER");
    g_linear = !(filter && strcmp(filter, "nearest") == 0);

    if (g_scale_enabled && (g_source_w <= 0 || g_source_h <= 0))
    {
        fprintf(
            stderr,
            "TSP_SWAPSCALER_051_V35 scale-disabled reason=invalid-source source=%s\n",
            getenv("TSP_SCALE_SOURCE") ? getenv("TSP_SCALE_SOURCE") : "<unset>");
        fflush(stderr);
        g_scale_enabled = 0;
    }

    if (!g_scale_enabled && !g_fps_enabled)
        g_disabled = 1;
}

__attribute__((constructor))
static void tsp_scaler_ctor(void)
{
    load_config();

    if (!g_disabled)
    {
        fprintf(
            stderr,
            "TSP_SWAPSCALER_051_V35 loaded "
            "scale=%d source=%dx%d requested_output=%dx%d "
            "filter=%s fps_overlay=%d\n",
            g_scale_enabled,
            g_source_w,
            g_source_h,
            g_output_w,
            g_output_h,
            g_linear ? "linear" : "nearest",
            g_fps_enabled);
        fflush(stderr);
    }
}

static void* try_dlopen_gles(void)
{
    static const char* candidates[] = {
        "libGLESv2.so",
        "libGLESv2.so.2",
        "/usr/lib64/libGLESv2.so",
        "/usr/lib/libGLESv2.so",
        "/mnt/SDCARD/System/lib/libGLESv2.so",
        NULL
    };

    for (int i = 0; candidates[i]; ++i)
    {
        void* h = dlopen(candidates[i], RTLD_NOW | RTLD_LOCAL);

        if (h)
            return h;
    }

    return NULL;
}

#define LOAD_GLES(name)                                                        \
    do {                                                                       \
        *(void**)(&p_##name) = dlsym(g_gles, #name);                           \
        if (!p_##name) {                                                       \
            fprintf(stderr, "TSP_SWAPSCALER_051_V35 missing-symbol=%s\n", #name); \
            fflush(stderr);                                                    \
            g_disabled = 1;                                                    \
            return 0;                                                          \
        }                                                                      \
    } while (0)

static int load_gles(void)
{
    if (g_gles_ready)
        return 1;

    if (g_disabled)
        return 0;

    g_gles = try_dlopen_gles();

    if (!g_gles)
    {
        const char* err = dlerror();
        fprintf(
            stderr,
            "TSP_SWAPSCALER_051_V35 disabled reason=libGLESv2-dlopen-failed error=%s\n",
            err ? err : "<unknown>");
        fflush(stderr);
        g_disabled = 1;
        return 0;
    }

    LOAD_GLES(glGetIntegerv);
    LOAD_GLES(glGetBooleanv);
    LOAD_GLES(glGetFloatv);
    LOAD_GLES(glIsEnabled);
    LOAD_GLES(glEnable);
    LOAD_GLES(glDisable);
    LOAD_GLES(glViewport);
    LOAD_GLES(glScissor);
    LOAD_GLES(glColorMask);
    LOAD_GLES(glClearColor);
    LOAD_GLES(glClear);

    LOAD_GLES(glActiveTexture);
    LOAD_GLES(glGenTextures);
    LOAD_GLES(glBindTexture);
    LOAD_GLES(glTexParameteri);
    LOAD_GLES(glTexImage2D);
    LOAD_GLES(glCopyTexSubImage2D);

    LOAD_GLES(glCreateShader);
    LOAD_GLES(glShaderSource);
    LOAD_GLES(glCompileShader);
    LOAD_GLES(glGetShaderiv);
    LOAD_GLES(glGetShaderInfoLog);
    LOAD_GLES(glDeleteShader);

    LOAD_GLES(glCreateProgram);
    LOAD_GLES(glAttachShader);
    LOAD_GLES(glBindAttribLocation);
    LOAD_GLES(glLinkProgram);
    LOAD_GLES(glGetProgramiv);
    LOAD_GLES(glGetProgramInfoLog);
    LOAD_GLES(glUseProgram);
    LOAD_GLES(glGetUniformLocation);
    LOAD_GLES(glUniform1i);

    LOAD_GLES(glGenBuffers);
    LOAD_GLES(glBindBuffer);
    LOAD_GLES(glBufferData);

    LOAD_GLES(glVertexAttribPointer);
    LOAD_GLES(glEnableVertexAttribArray);
    LOAD_GLES(glDisableVertexAttribArray);
    LOAD_GLES(glGetVertexAttribiv);
    LOAD_GLES(glGetVertexAttribPointerv);
    LOAD_GLES(glDrawArrays);

    LOAD_GLES(glBindFramebuffer);

    g_gles_ready = 1;
    return 1;
}

static GLuint compile_shader(GLenum type, const char* source)
{
    GLuint shader = p_glCreateShader(type);

    if (!shader)
        return 0;

    p_glShaderSource(shader, 1, (const GLchar* const*)&source, NULL);
    p_glCompileShader(shader);

    GLint ok = 0;
    p_glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);

    if (!ok)
    {
        GLchar log[1024];
        GLsizei len = 0;
        memset(log, 0, sizeof(log));
        p_glGetShaderInfoLog(shader, (GLsizei)sizeof(log) - 1, &len, log);

        fprintf(
            stderr,
            "TSP_SWAPSCALER_051_V35 shader-compile-failed type=0x%x log=%s\n",
            type,
            log);
        fflush(stderr);

        p_glDeleteShader(shader);
        return 0;
    }

    return shader;
}

static int ensure_resources(void)
{
    if (!g_scale_enabled)
        return 1;

    if (g_program && g_texture && g_vbo
        && g_texture_w == g_source_w
        && g_texture_h == g_source_h)
    {
        return 1;
    }

    if (!g_program)
    {
        static const char* vs_source =
            "attribute vec2 aPos;\n"
            "attribute vec2 aUV;\n"
            "varying vec2 vUV;\n"
            "void main() {\n"
            "    gl_Position = vec4(aPos, 0.0, 1.0);\n"
            "    vUV = aUV;\n"
            "}\n";

        static const char* fs_source =
            "precision highp float;\n"
            "uniform sampler2D uTex;\n"
            "varying vec2 vUV;\n"
            "void main() {\n"
            "    gl_FragColor = texture2D(uTex, vUV);\n"
            "}\n";

        GLuint vs = compile_shader(GL_VERTEX_SHADER, vs_source);
        GLuint fs = compile_shader(GL_FRAGMENT_SHADER, fs_source);

        if (!vs || !fs)
            return 0;

        g_program = p_glCreateProgram();

        if (!g_program)
            return 0;

        p_glAttachShader(g_program, vs);
        p_glAttachShader(g_program, fs);
        p_glBindAttribLocation(g_program, ATTR_POS, "aPos");
        p_glBindAttribLocation(g_program, ATTR_UV, "aUV");
        p_glLinkProgram(g_program);

        GLint linked = 0;
        p_glGetProgramiv(g_program, GL_LINK_STATUS, &linked);

        if (!linked)
        {
            GLchar log[1024];
            GLsizei len = 0;
            memset(log, 0, sizeof(log));
            p_glGetProgramInfoLog(
                g_program,
                (GLsizei)sizeof(log) - 1,
                &len,
                log);

            fprintf(
                stderr,
                "TSP_SWAPSCALER_051_V35 program-link-failed log=%s\n",
                log);
            fflush(stderr);
            return 0;
        }

        g_sampler = p_glGetUniformLocation(g_program, "uTex");

        static const GLfloat vertices[] = {
            -1.0f, -1.0f, 0.0f, 0.0f,
             1.0f, -1.0f, 1.0f, 0.0f,
            -1.0f,  1.0f, 0.0f, 1.0f,
             1.0f,  1.0f, 1.0f, 1.0f
        };

        p_glGenBuffers(1, &g_vbo);
        p_glBindBuffer(GL_ARRAY_BUFFER, g_vbo);
        p_glBufferData(
            GL_ARRAY_BUFFER,
            (GLsizeiptr)sizeof(vertices),
            vertices,
            GL_STATIC_DRAW);

        p_glDeleteShader(vs);
        p_glDeleteShader(fs);
    }

    if (!g_texture)
        p_glGenTextures(1, &g_texture);

    p_glActiveTexture(GL_TEXTURE7);
    p_glBindTexture(GL_TEXTURE_2D, g_texture);

    p_glTexParameteri(
        GL_TEXTURE_2D,
        GL_TEXTURE_MIN_FILTER,
        g_linear ? GL_LINEAR : GL_NEAREST);

    p_glTexParameteri(
        GL_TEXTURE_2D,
        GL_TEXTURE_MAG_FILTER,
        g_linear ? GL_LINEAR : GL_NEAREST);

    p_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    p_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    if (g_texture_w != g_source_w || g_texture_h != g_source_h)
    {
        p_glTexImage2D(
            GL_TEXTURE_2D,
            0,
            GL_RGBA,
            g_source_w,
            g_source_h,
            0,
            GL_RGBA,
            GL_UNSIGNED_BYTE,
            NULL);

        g_texture_w = g_source_w;
        g_texture_h = g_source_h;
    }

    return 1;
}

typedef struct AttribState
{
    GLint enabled;
    GLint size;
    GLint stride;
    GLint type;
    GLint normalized;
    GLint buffer;
    void* pointer;
} AttribState;

static void save_attrib(GLuint index, AttribState* state)
{
    memset(state, 0, sizeof(*state));

    p_glGetVertexAttribiv(
        index,
        GL_VERTEX_ATTRIB_ARRAY_ENABLED,
        &state->enabled);

    p_glGetVertexAttribiv(
        index,
        GL_VERTEX_ATTRIB_ARRAY_SIZE,
        &state->size);

    p_glGetVertexAttribiv(
        index,
        GL_VERTEX_ATTRIB_ARRAY_STRIDE,
        &state->stride);

    p_glGetVertexAttribiv(
        index,
        GL_VERTEX_ATTRIB_ARRAY_TYPE,
        &state->type);

    p_glGetVertexAttribiv(
        index,
        GL_VERTEX_ATTRIB_ARRAY_NORMALIZED,
        &state->normalized);

    p_glGetVertexAttribiv(
        index,
        GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING,
        &state->buffer);

    p_glGetVertexAttribPointerv(
        index,
        GL_VERTEX_ATTRIB_ARRAY_POINTER,
        &state->pointer);
}

static void restore_attrib(GLuint index, const AttribState* state)
{
    p_glBindBuffer(GL_ARRAY_BUFFER, (GLuint)state->buffer);

    p_glVertexAttribPointer(
        index,
        state->size,
        (GLenum)state->type,
        (GLboolean)state->normalized,
        state->stride,
        state->pointer);

    if (state->enabled)
        p_glEnableVertexAttribArray(index);
    else
        p_glDisableVertexAttribArray(index);
}

static void restore_cap(GLenum cap, GLboolean enabled)
{
    if (enabled)
        p_glEnable(cap);
    else
        p_glDisable(cap);
}

static double timespec_seconds(const struct timespec* t)
{
    return (double)t->tv_sec + ((double)t->tv_nsec / 1000000000.0);
}

static void update_fps_counter(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);

    if (g_fps_last.tv_sec == 0 && g_fps_last.tv_nsec == 0)
    {
        g_fps_last = now;
        g_fps_frames = 0;
        return;
    }

    ++g_fps_frames;

    const double elapsed =
        timespec_seconds(&now) - timespec_seconds(&g_fps_last);

    if (elapsed >= 0.50)
    {
        g_display_fps = (double)g_fps_frames / elapsed;
        g_fps_frames = 0;
        g_fps_last = now;
    }
}

static void fill_rect(
    int x,
    int y,
    int w,
    int h,
    GLfloat r,
    GLfloat g,
    GLfloat b,
    GLfloat a)
{
    if (w <= 0 || h <= 0)
        return;

    p_glEnable(GL_SCISSOR_TEST);
    p_glScissor(x, y, w, h);
    p_glClearColor(r, g, b, a);
    p_glClear(GL_COLOR_BUFFER_BIT);
}

/* Standard seven-segment map: A B C D E F G */
static const unsigned char digit_segments[10] = {
    0x3F, 0x06, 0x5B, 0x4F, 0x66,
    0x6D, 0x7D, 0x07, 0x7F, 0x6F
};

static void draw_digit(int digit, int x, int y, int s)
{
    if (digit < 0 || digit > 9)
        return;

    const unsigned char seg = digit_segments[digit];
    const int t = 2 * s;
    const int w = 10 * s;
    const int h = 18 * s;
    const int half = h / 2;

    const GLfloat r = 1.0f;
    const GLfloat g = 1.0f;
    const GLfloat b = 1.0f;
    const GLfloat a = 1.0f;

    if (seg & 0x01) fill_rect(x + t, y + h - t, w - 2*t, t, r,g,b,a);
    if (seg & 0x02) fill_rect(x + w - t, y + half, t, half - t, r,g,b,a);
    if (seg & 0x04) fill_rect(x + w - t, y + t, t, half - t, r,g,b,a);
    if (seg & 0x08) fill_rect(x + t, y, w - 2*t, t, r,g,b,a);
    if (seg & 0x10) fill_rect(x, y + t, t, half - t, r,g,b,a);
    if (seg & 0x20) fill_rect(x, y + half, t, half - t, r,g,b,a);
    if (seg & 0x40) fill_rect(x + t, y + half - (t/2), w - 2*t, t, r,g,b,a);
}

static void draw_fps_overlay(void)
{
    if (!g_fps_enabled)
        return;

    update_fps_counter();

    int fps = (int)(g_display_fps + 0.5);
    if (fps < 0) fps = 0;
    if (fps > 999) fps = 999;

    const int s = 2;
    const int digit_w = 10 * s;
    const int digit_gap = 3 * s;
    const int digit_h = 18 * s;
    const int margin = 8;
    const int padding = 6;

    const int box_w = padding * 2 + digit_w * 3 + digit_gap * 2;
    const int box_h = padding * 2 + digit_h;
    const int box_x = margin;
    const int box_y = g_output_h - margin - box_h;

    fill_rect(box_x, box_y, box_w, box_h, 0.0f, 0.0f, 0.0f, 1.0f);

    const int hundreds = fps / 100;
    const int tens = (fps / 10) % 10;
    const int ones = fps % 10;

    int x = box_x + padding;
    const int y = box_y + padding;

    if (hundreds > 0)
        draw_digit(hundreds, x, y, s);

    x += digit_w + digit_gap;

    if (hundreds > 0 || tens > 0)
        draw_digit(tens, x, y, s);

    x += digit_w + digit_gap;
    draw_digit(ones, x, y, s);
}


static void present_scaled(SDL_Window* window, const char* hook_name)
{
    if (g_disabled || !load_gles())
        return;

    GLint saved_program = 0;
    GLint saved_active_texture = 0;
    GLint saved_texture7 = 0;
    GLint saved_array_buffer = 0;
    GLint saved_framebuffer = 0;

    GLint saved_viewport[4] = {0, 0, 0, 0};
    GLint saved_scissor[4] = {0, 0, 0, 0};

    GLboolean saved_color_mask[4] = {
        GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE
    };

    GLfloat saved_clear_color[4] = {0.f, 0.f, 0.f, 0.f};

    const GLboolean saved_blend = p_glIsEnabled(GL_BLEND);
    const GLboolean saved_depth = p_glIsEnabled(GL_DEPTH_TEST);
    const GLboolean saved_stencil = p_glIsEnabled(GL_STENCIL_TEST);
    const GLboolean saved_cull = p_glIsEnabled(GL_CULL_FACE);
    const GLboolean saved_scissor_enabled = p_glIsEnabled(GL_SCISSOR_TEST);

    AttribState attr_pos;
    AttribState attr_uv;

    p_glGetIntegerv(GL_CURRENT_PROGRAM, &saved_program);
    p_glGetIntegerv(GL_ACTIVE_TEXTURE, &saved_active_texture);
    p_glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &saved_array_buffer);
    p_glGetIntegerv(GL_FRAMEBUFFER_BINDING, &saved_framebuffer);
    p_glGetIntegerv(GL_VIEWPORT, saved_viewport);
    p_glGetIntegerv(GL_SCISSOR_BOX, saved_scissor);
    p_glGetBooleanv(GL_COLOR_WRITEMASK, saved_color_mask);
    p_glGetFloatv(GL_COLOR_CLEAR_VALUE, saved_clear_color);

    save_attrib(ATTR_POS, &attr_pos);
    save_attrib(ATTR_UV, &attr_uv);

    p_glActiveTexture(GL_TEXTURE7);
    p_glGetIntegerv(GL_TEXTURE_BINDING_2D, &saved_texture7);

    int drawable_w = 0;
    int drawable_h = 0;

    if (window)
    {
        if (!real_SDL_GL_GetDrawableSize)
        {
            *(void**)(&real_SDL_GL_GetDrawableSize) =
                dlsym(RTLD_NEXT, "SDL_GL_GetDrawableSize");
        }

        if (real_SDL_GL_GetDrawableSize)
            real_SDL_GL_GetDrawableSize(window, &drawable_w, &drawable_h);
    }

    /*
     * TSP V35 loading-screen bypass.
     * The marker exists only while OpenMW's LoadingScreen is active.
     */
    const int loading_bypass =
        g_scale_enabled
        && access("/tmp/openmw-tsp-loading-active", F_OK) == 0;

    if (loading_bypass != g_last_loading_bypass)
    {
        fprintf(
            stderr,
            "TSP_SWAPSCALER_051_V35 loading_bypass=%d "
            "source=%dx%d output=%dx%d\n",
            loading_bypass,
            g_source_w,
            g_source_h,
            g_output_w,
            g_output_h);
        fflush(stderr);
        g_last_loading_bypass = loading_bypass;
    }

    if (g_scale_enabled && !loading_bypass)
    {
        if (!ensure_resources())
            goto restore;

        p_glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)saved_framebuffer);

        p_glActiveTexture(GL_TEXTURE7);
        p_glBindTexture(GL_TEXTURE_2D, g_texture);

        p_glCopyTexSubImage2D(
            GL_TEXTURE_2D,
            0,
            0,
            0,
            0,
            0,
            g_source_w,
            g_source_h);

        p_glBindFramebuffer(GL_FRAMEBUFFER, 0);
        p_glViewport(0, 0, g_output_w, g_output_h);

        p_glDisable(GL_SCISSOR_TEST);
        p_glDisable(GL_BLEND);
        p_glDisable(GL_DEPTH_TEST);
        p_glDisable(GL_STENCIL_TEST);
        p_glDisable(GL_CULL_FACE);

        p_glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        p_glUseProgram(g_program);

        p_glActiveTexture(GL_TEXTURE7);
        p_glBindTexture(GL_TEXTURE_2D, g_texture);

        if (g_sampler >= 0)
            p_glUniform1i(g_sampler, 7);

        p_glBindBuffer(GL_ARRAY_BUFFER, g_vbo);

        p_glVertexAttribPointer(
            ATTR_POS,
            2,
            GL_FLOAT,
            GL_FALSE,
            4 * (GLsizei)sizeof(GLfloat),
            (const void*)(uintptr_t)0);

        p_glVertexAttribPointer(
            ATTR_UV,
            2,
            GL_FLOAT,
            GL_FALSE,
            4 * (GLsizei)sizeof(GLfloat),
            (const void*)(uintptr_t)(2 * sizeof(GLfloat)));

        p_glEnableVertexAttribArray(ATTR_POS);
        p_glEnableVertexAttribArray(ATTR_UV);
        p_glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }
    else
    {
        p_glBindFramebuffer(GL_FRAMEBUFFER, 0);
        p_glViewport(0, 0, g_output_w, g_output_h);
        p_glDisable(GL_DEPTH_TEST);
        p_glDisable(GL_STENCIL_TEST);
        p_glDisable(GL_CULL_FACE);
        p_glDisable(GL_BLEND);
        p_glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    }

    draw_fps_overlay();

    if (!g_first_frame_logged)
    {
        fprintf(
            stderr,
            "TSP_SWAPSCALER_051_V35 frame=1 "
            "hook=%s scale=%d loading_bypass=%d fps_overlay=%d "
            "source=%dx%d source_fbo=%d "
            "pre_viewport=%d,%d,%d,%d "
            "drawable=%dx%d output=%dx%d "
            "filter=%s\n",
            hook_name,
            g_scale_enabled,
            loading_bypass,
            g_fps_enabled,
            g_source_w,
            g_source_h,
            saved_framebuffer,
            saved_viewport[0],
            saved_viewport[1],
            saved_viewport[2],
            saved_viewport[3],
            drawable_w,
            drawable_h,
            g_output_w,
            g_output_h,
            g_linear ? "linear" : "nearest");

        fflush(stderr);
        g_first_frame_logged = 1;
    }

restore:
    restore_attrib(ATTR_POS, &attr_pos);
    restore_attrib(ATTR_UV, &attr_uv);

    p_glBindBuffer(GL_ARRAY_BUFFER, (GLuint)saved_array_buffer);
    p_glUseProgram((GLuint)saved_program);

    p_glActiveTexture(GL_TEXTURE7);
    p_glBindTexture(GL_TEXTURE_2D, (GLuint)saved_texture7);
    p_glActiveTexture((GLenum)saved_active_texture);

    p_glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)saved_framebuffer);

    p_glViewport(
        saved_viewport[0],
        saved_viewport[1],
        saved_viewport[2],
        saved_viewport[3]);

    p_glScissor(
        saved_scissor[0],
        saved_scissor[1],
        saved_scissor[2],
        saved_scissor[3]);

    p_glColorMask(
        saved_color_mask[0],
        saved_color_mask[1],
        saved_color_mask[2],
        saved_color_mask[3]);

    p_glClearColor(
        saved_clear_color[0],
        saved_clear_color[1],
        saved_clear_color[2],
        saved_clear_color[3]);

    restore_cap(GL_BLEND, saved_blend);
    restore_cap(GL_DEPTH_TEST, saved_depth);
    restore_cap(GL_STENCIL_TEST, saved_stencil);
    restore_cap(GL_CULL_FACE, saved_cull);
    restore_cap(GL_SCISSOR_TEST, saved_scissor_enabled);
}

void SDL_GL_SwapWindow(SDL_Window* window)
{
    if (!real_SDL_GL_SwapWindow)
    {
        *(void**)(&real_SDL_GL_SwapWindow) =
            dlsym(RTLD_NEXT, "SDL_GL_SwapWindow");
    }

    if (!g_disabled)
        present_scaled(window, "SDL_GL_SwapWindow");

    if (real_SDL_GL_SwapWindow)
    {
        g_inside_sdl_swap = 1;
        real_SDL_GL_SwapWindow(window);
        g_inside_sdl_swap = 0;
    }
}

EGLBoolean eglSwapBuffers(EGLDisplay display, EGLSurface surface)
{
    if (!real_eglSwapBuffers)
    {
        *(void**)(&real_eglSwapBuffers) =
            dlsym(RTLD_NEXT, "eglSwapBuffers");
    }

    if (!g_disabled && !g_inside_sdl_swap)
        present_scaled(NULL, "eglSwapBuffers");

    if (real_eglSwapBuffers)
        return real_eglSwapBuffers(display, surface);

    return 0;
}

