#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void SDL_Window;

typedef unsigned int GLenum;
typedef unsigned int GLuint;
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
typedef GLboolean (*PFN_glIsEnabled)(GLenum);
typedef void (*PFN_glEnable)(GLenum);
typedef void (*PFN_glDisable)(GLenum);
typedef void (*PFN_glViewport)(GLint, GLint, GLsizei, GLsizei);
typedef void (*PFN_glScissor)(GLint, GLint, GLsizei, GLsizei);
typedef void (*PFN_glColorMask)(GLboolean, GLboolean, GLboolean, GLboolean);

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
static int g_first_frame_logged = 0;

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

static __thread int g_inside_sdl_swap = 0;

static PFN_glGetIntegerv p_glGetIntegerv;
static PFN_glGetBooleanv p_glGetBooleanv;
static PFN_glIsEnabled p_glIsEnabled;
static PFN_glEnable p_glEnable;
static PFN_glDisable p_glDisable;
static PFN_glViewport p_glViewport;
static PFN_glScissor p_glScissor;
static PFN_glColorMask p_glColorMask;

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

static void load_config(void)
{
    const char* enabled = getenv("TSP_FULLSCREEN_SCALE");

    if (!enabled || strcmp(enabled, "1") != 0)
    {
        g_disabled = 1;
        return;
    }

    parse_size(getenv("TSP_SCALE_SOURCE"), &g_source_w, &g_source_h);
    parse_size(getenv("TSP_SCALE_OUTPUT"), &g_output_w, &g_output_h);

    const char* filter = getenv("TSP_SCALE_FILTER");
    g_linear = !(filter && strcmp(filter, "nearest") == 0);

    if (g_source_w <= 0 || g_source_h <= 0)
    {
        fprintf(
            stderr,
            "TSP_SWAPSCALER_051_V32 disabled reason=invalid-source source=%s\n",
            getenv("TSP_SCALE_SOURCE") ? getenv("TSP_SCALE_SOURCE") : "<unset>");
        fflush(stderr);
        g_disabled = 1;
    }
}

__attribute__((constructor))
static void tsp_scaler_ctor(void)
{
    load_config();

    if (!g_disabled)
    {
        fprintf(
            stderr,
            "TSP_SWAPSCALER_051_V32 loaded source=%dx%d requested_output=%dx%d filter=%s\n",
            g_source_w,
            g_source_h,
            g_output_w,
            g_output_h,
            g_linear ? "linear" : "nearest");
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
            fprintf(stderr, "TSP_SWAPSCALER_051_V32 missing-symbol=%s\n", #name); \
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
            "TSP_SWAPSCALER_051_V32 disabled reason=libGLESv2-dlopen-failed error=%s\n",
            err ? err : "<unknown>");
        fflush(stderr);
        g_disabled = 1;
        return 0;
    }

    LOAD_GLES(glGetIntegerv);
    LOAD_GLES(glGetBooleanv);
    LOAD_GLES(glIsEnabled);
    LOAD_GLES(glEnable);
    LOAD_GLES(glDisable);
    LOAD_GLES(glViewport);
    LOAD_GLES(glScissor);
    LOAD_GLES(glColorMask);

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
            "TSP_SWAPSCALER_051_V32 shader-compile-failed type=0x%x log=%s\n",
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
                "TSP_SWAPSCALER_051_V32 program-link-failed log=%s\n",
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
        GL_TRUE,
        GL_TRUE,
        GL_TRUE,
        GL_TRUE
    };

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

    save_attrib(ATTR_POS, &attr_pos);
    save_attrib(ATTR_UV, &attr_uv);

    p_glActiveTexture(GL_TEXTURE7);
    p_glGetIntegerv(GL_TEXTURE_BINDING_2D, &saved_texture7);

    if (!ensure_resources())
        goto restore;

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
        {
            real_SDL_GL_GetDrawableSize(
                window,
                &drawable_w,
                &drawable_h);
        }
    }

    /*
     * GPU-side copy from the framebuffer OpenMW/GL4ES left current.
     */
    p_glBindFramebuffer(
        GL_FRAMEBUFFER,
        (GLuint)saved_framebuffer);

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

    /*
     * Draw the copied low-res image across the full physical framebuffer.
     */
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

    if (!g_first_frame_logged)
    {
        fprintf(
            stderr,
            "TSP_SWAPSCALER_051_V32 frame=1 "
            "hook=%s "
            "source=%dx%d "
            "source_fbo=%d "
            "pre_viewport=%d,%d,%d,%d "
            "drawable=%dx%d "
            "output=%dx%d "
            "filter=%s\n",
            hook_name,
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

