/* tsp_swapbench.c - TSP_SWAPBENCH_V2
 *
 * Measures the swap / display floor with OpenMW completely out of the picture.
 *
 *   tsp_swapbench <mode 0-3> [frames=300] [quads=4]
 *
 *     mode 0  glClear + SDL_GL_SwapWindow, interval 0   the raw flip floor
 *     mode 1  N blended full-screen textured quads + swap    GPU fill + flip
 *     mode 2  the same fill + glFinish, NO swap             GPU fill alone
 *     mode 3  as mode 0 but interval 1                      what vsync looks like
 *
 * THE ANSWER THIS EXISTS FOR is the first line it prints. If it says
 * "interval req=0 got=1", SDL could not turn vsync off on this KMSDRM, every
 * swap waits for a vblank, and frame times are quantised to multiples of
 * 16.7 ms. That single line decides the whole B2 line of investigation.
 *
 * WHY V2 DOES NOT #include <SDL.h>
 * --------------------------------
 * V1 needed SDL2 headers and libSDL2 at link time. On the real build container
 * there are no SDL2 headers anywhere the search looked, and bench aborted
 * before it could measure anything. Hunting for the headers would have fixed
 * that one run; this removes the dependency for good.
 *
 * Instead it dlopen()s the SDL2 and libGL the GAME ITSELF loads, and declares
 * the fourteen SDL entry points and seventeen GL entry points it uses with its
 * own prototypes. Nothing is guessed: every prototype and every constant below
 * is part of the SDL2 / OpenGL ABI, which is frozen for the life of SDL2, and
 * each constant carries the header it comes from.
 *
 * That makes this strictly BETTER than V1, not just easier to build:
 *   - it compiles with `gcc -O2 tsp_swapbench.c -ldl -lm` and nothing else, so
 *     no header or library search can fail;
 *   - it measures the exact libSDL2 the game runs against, not whatever
 *     version's headers happened to be in the container;
 *   - a missing or unexpected symbol is reported by name instead of failing at
 *     link time in the container, where the error would be less legible.
 *
 * Build (no include path, no -lSDL2, no -lGL):
 *   gcc-13 -O2 -Wall -Wextra -o tsp_swapbench tsp_swapbench.c -ldl -lm
 * Gate: the binary must contain the string TSP_SWAPBENCH.
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

/* ------------------------------------------------------------------ ABI ---
 * SDL2, from SDL.h / SDL_video.h. These values are ABI - SDL2 cannot change
 * them without breaking every compiled binary on earth.
 */
#define SDL_INIT_VIDEO            0x00000020u  /* SDL.h */
#define SDL_WINDOW_FULLSCREEN     0x00000001u  /* SDL_video.h SDL_WindowFlags */
#define SDL_WINDOW_OPENGL         0x00000002u
#define SDL_WINDOW_SHOWN          0x00000004u
#define SDL_GL_DOUBLEBUFFER       5            /* SDL_video.h SDL_GLattr */
#define SDL_GL_DEPTH_SIZE         6

/* OpenGL 1.x / GLES enums, from GL/gl.h. Also frozen ABI. */
#define GL_DEPTH_BUFFER_BIT       0x00000100u
#define GL_COLOR_BUFFER_BIT       0x00004000u
#define GL_QUADS                  0x0007
#define GL_SRC_ALPHA              0x0302
#define GL_ONE_MINUS_SRC_ALPHA    0x0303
#define GL_BLEND                  0x0BE2
#define GL_TEXTURE_2D             0x0DE1
#define GL_UNSIGNED_BYTE          0x1401
#define GL_MODELVIEW              0x1700
#define GL_PROJECTION             0x1701
#define GL_VENDOR                 0x1F00
#define GL_RENDERER               0x1F01
#define GL_VERSION                0x1F02
#define GL_LINEAR                 0x2601
#define GL_TEXTURE_MAG_FILTER     0x2800
#define GL_TEXTURE_MIN_FILTER     0x2801
#define GL_RGBA                   0x1908

typedef void  SDL_Window;
typedef void* SDL_GLContext;

/* SDL_Event is a union whose size SDL2 pins at 56 bytes (SDL_events.h ends it
 * with `Uint8 padding[56]`). 256 is used here so no future member can overflow
 * the buffer SDL_PollEvent writes into - the contents are never read. */
typedef union { unsigned char raw[256]; uint32_t type; } TSP_Event;

/* ------------------------------------------------------- resolved symbols ---*/
static int          (*p_SDL_Init)(uint32_t);
static const char*  (*p_SDL_GetError)(void);
static int          (*p_SDL_GL_SetAttribute)(int, int);
static SDL_Window*  (*p_SDL_CreateWindow)(const char*, int, int, int, int, uint32_t);
static SDL_GLContext(*p_SDL_GL_CreateContext)(SDL_Window*);
static int          (*p_SDL_GL_SetSwapInterval)(int);
static int          (*p_SDL_GL_GetSwapInterval)(void);
static void         (*p_SDL_GL_SwapWindow)(SDL_Window*);
static const char*  (*p_SDL_GetCurrentVideoDriver)(void);
static int          (*p_SDL_PollEvent)(TSP_Event*);
static void         (*p_SDL_GL_DeleteContext)(SDL_GLContext);
static void         (*p_SDL_DestroyWindow)(SDL_Window*);
static void         (*p_SDL_Quit)(void);
static void*        (*p_SDL_GL_GetProcAddress)(const char*);

static void  (*p_glClear)(unsigned int);
static void  (*p_glClearColor)(float, float, float, float);
static const unsigned char* (*p_glGetString)(unsigned int);
static void  (*p_glViewport)(int, int, int, int);
static void  (*p_glFinish)(void);
static void  (*p_glEnable)(unsigned int);
static void  (*p_glBlendFunc)(unsigned int, unsigned int);
static void  (*p_glGenTextures)(int, unsigned int*);
static void  (*p_glBindTexture)(unsigned int, unsigned int);
static void  (*p_glTexParameteri)(unsigned int, unsigned int, int);
static void  (*p_glTexImage2D)(unsigned int, int, int, int, int, int, unsigned int, unsigned int, const void*);
static void  (*p_glDeleteTextures)(int, const unsigned int*);
static void  (*p_glMatrixMode)(unsigned int);
static void  (*p_glLoadIdentity)(void);
static void  (*p_glOrtho)(double, double, double, double, double, double);
static void  (*p_glBegin)(unsigned int);
static void  (*p_glEnd)(void);
static void  (*p_glColor4f)(float, float, float, float);
static void  (*p_glTexCoord2f)(float, float);
static void  (*p_glVertex2f)(float, float);

static int missing = 0;

static void* pick(void* h, const char* name, int required)
{
    void* s = dlsym(h, name);
    if (s == NULL && required)
    {
        printf("TSP_SWAPBENCH FAIL missing symbol %s\n", name);
        missing++;
    }
    return s;
}

/* The game's own SDL2 and libGL, by soname, found through LD_LIBRARY_PATH which
 * the Ports entry points at the game's lib directory. Each candidate is tried in
 * turn and the one that loads is reported, so the log says exactly which
 * libraries were measured. */
static void* load_any(const char* const* names, const char* what)
{
    for (int i = 0; names[i] != NULL; ++i)
    {
        void* h = dlopen(names[i], RTLD_NOW | RTLD_GLOBAL);
        if (h != NULL)
        {
            printf("TSP_SWAPBENCH lib %s = %s\n", what, names[i]);
            return h;
        }
    }
    printf("TSP_SWAPBENCH FAIL could not dlopen %s: %s\n", what, dlerror());
    return NULL;
}

static double now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec * 1e3 + (double)t.tv_nsec / 1e6;
}

static int cmpd(const void* a, const void* b)
{
    double x = *(const double*)a, y = *(const double*)b;
    return (x > y) - (x < y);
}

static const char* gs(unsigned int e)
{
    if (p_glGetString == NULL) return "?";
    const unsigned char* v = p_glGetString(e);
    return (v != NULL) ? (const char*)v : "(null)";   /* never printf a NULL */
}

int main(int argc, char** argv)
{
    int mode   = (argc > 1) ? atoi(argv[1]) : 0;
    int frames = (argc > 2) ? atoi(argv[2]) : 300;
    int quads  = (argc > 3) ? atoi(argv[3]) : 4;
    if (mode < 0 || mode > 3) { printf("TSP_SWAPBENCH FAIL mode %d out of range 0-3\n", mode); return 2; }
    if (frames < 10) frames = 10;
    if (frames > 5000) frames = 5000;
    if (quads < 0) quads = 0;

    static const char* const sdl_names[] = {
        "libSDL2-2.0.so.0", "libSDL2-2.0.so", "libSDL2.so.0", "libSDL2.so", NULL };
    static const char* const gl_names[] = {
        "libGL.so.1", "libGL.so", "libGLESv2.so.2", "libGLESv2.so", NULL };

    void* hs = load_any(sdl_names, "SDL2");
    if (hs == NULL) return 1;

    p_SDL_Init                = (int (*)(uint32_t))               pick(hs, "SDL_Init", 1);
    p_SDL_GetError            = (const char* (*)(void))           pick(hs, "SDL_GetError", 1);
    p_SDL_GL_SetAttribute     = (int (*)(int, int))               pick(hs, "SDL_GL_SetAttribute", 1);
    p_SDL_CreateWindow        = (SDL_Window* (*)(const char*, int, int, int, int, uint32_t))
                                                                  pick(hs, "SDL_CreateWindow", 1);
    p_SDL_GL_CreateContext    = (SDL_GLContext (*)(SDL_Window*))  pick(hs, "SDL_GL_CreateContext", 1);
    p_SDL_GL_SetSwapInterval  = (int (*)(int))                    pick(hs, "SDL_GL_SetSwapInterval", 1);
    p_SDL_GL_GetSwapInterval  = (int (*)(void))                   pick(hs, "SDL_GL_GetSwapInterval", 1);
    p_SDL_GL_SwapWindow       = (void (*)(SDL_Window*))           pick(hs, "SDL_GL_SwapWindow", 1);
    p_SDL_GetCurrentVideoDriver = (const char* (*)(void))         pick(hs, "SDL_GetCurrentVideoDriver", 1);
    p_SDL_PollEvent           = (int (*)(TSP_Event*))             pick(hs, "SDL_PollEvent", 1);
    p_SDL_GL_DeleteContext    = (void (*)(SDL_GLContext))         pick(hs, "SDL_GL_DeleteContext", 1);
    p_SDL_DestroyWindow       = (void (*)(SDL_Window*))           pick(hs, "SDL_DestroyWindow", 1);
    p_SDL_Quit                = (void (*)(void))                  pick(hs, "SDL_Quit", 1);
    p_SDL_GL_GetProcAddress   = (void* (*)(const char*))          pick(hs, "SDL_GL_GetProcAddress", 1);
    if (missing) { printf("TSP_SWAPBENCH FAIL %d SDL symbol(s) missing\n", missing); return 1; }

    if (p_SDL_Init(SDL_INIT_VIDEO) != 0)
    {
        printf("TSP_SWAPBENCH FAIL SDL_Init: %s\n", p_SDL_GetError());
        return 1;
    }

    p_SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    p_SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);

    SDL_Window* w = p_SDL_CreateWindow("tsp_swapbench", 0, 0, 1280, 720,
                                       SDL_WINDOW_OPENGL | SDL_WINDOW_FULLSCREEN | SDL_WINDOW_SHOWN);
    if (w == NULL) { printf("TSP_SWAPBENCH FAIL SDL_CreateWindow: %s\n", p_SDL_GetError()); return 1; }

    SDL_GLContext ctx = p_SDL_GL_CreateContext(w);
    if (ctx == NULL) { printf("TSP_SWAPBENCH FAIL SDL_GL_CreateContext: %s\n", p_SDL_GetError()); return 1; }

    /* GL entry points come from SDL_GL_GetProcAddress first - that is the
     * context's own loader and is what the game itself resolves through - and
     * from a dlopen'd libGL only as a fallback. On gl4es both land on the same
     * library; asking the context first is what makes this correct if the game
     * is ever run on a different GL. */
    void* hg = NULL;
    #define GLSYM(v, n, t) do { \
        void* s = p_SDL_GL_GetProcAddress ? p_SDL_GL_GetProcAddress(n) : NULL; \
        if (s == NULL) { if (hg == NULL) hg = load_any(gl_names, "GL"); s = hg ? dlsym(hg, n) : NULL; } \
        if (s == NULL) { printf("TSP_SWAPBENCH FAIL missing GL symbol %s\n", n); missing++; } \
        v = (t)s; } while (0)

    GLSYM(p_glClear,        "glClear",        void (*)(unsigned int));
    GLSYM(p_glClearColor,   "glClearColor",   void (*)(float, float, float, float));
    GLSYM(p_glGetString,    "glGetString",    const unsigned char* (*)(unsigned int));
    GLSYM(p_glViewport,     "glViewport",     void (*)(int, int, int, int));
    GLSYM(p_glFinish,       "glFinish",       void (*)(void));
    if (missing) { printf("TSP_SWAPBENCH FAIL %d GL symbol(s) missing\n", missing); return 1; }

    int want = (mode == 3) ? 1 : 0;
    int setrc = p_SDL_GL_SetSwapInterval(want);
    int got   = p_SDL_GL_GetSwapInterval();

    printf("TSP_SWAPBENCH env driver=%s renderer=%s vendor=%s version=%s\n",
           p_SDL_GetCurrentVideoDriver() ? p_SDL_GetCurrentVideoDriver() : "(null)",
           gs(GL_RENDERER), gs(GL_VENDOR), gs(GL_VERSION));
    printf("TSP_SWAPBENCH interval req=%d got=%d setrc=%d%s\n", want, got, setrc,
           (want == 0 && got != 0)
             ? "   <-- interval 0 REFUSED: every swap waits for a vblank"
             : "");
    fflush(stdout);

    unsigned int tex = 0;
    if (mode == 1 || mode == 2)
    {
        GLSYM(p_glEnable,        "glEnable",        void (*)(unsigned int));
        GLSYM(p_glBlendFunc,     "glBlendFunc",     void (*)(unsigned int, unsigned int));
        GLSYM(p_glGenTextures,   "glGenTextures",   void (*)(int, unsigned int*));
        GLSYM(p_glBindTexture,   "glBindTexture",   void (*)(unsigned int, unsigned int));
        GLSYM(p_glTexParameteri, "glTexParameteri", void (*)(unsigned int, unsigned int, int));
        GLSYM(p_glTexImage2D,    "glTexImage2D",    void (*)(unsigned int, int, int, int, int, int, unsigned int, unsigned int, const void*));
        GLSYM(p_glDeleteTextures,"glDeleteTextures",void (*)(int, const unsigned int*));
        GLSYM(p_glMatrixMode,    "glMatrixMode",    void (*)(unsigned int));
        GLSYM(p_glLoadIdentity,  "glLoadIdentity",  void (*)(void));
        GLSYM(p_glOrtho,         "glOrtho",         void (*)(double, double, double, double, double, double));
        GLSYM(p_glBegin,         "glBegin",         void (*)(unsigned int));
        GLSYM(p_glEnd,           "glEnd",           void (*)(void));
        GLSYM(p_glColor4f,       "glColor4f",       void (*)(float, float, float, float));
        GLSYM(p_glTexCoord2f,    "glTexCoord2f",    void (*)(float, float));
        GLSYM(p_glVertex2f,      "glVertex2f",      void (*)(float, float));
        if (missing) { printf("TSP_SWAPBENCH FAIL %d GL symbol(s) missing for mode %d\n", missing, mode); return 1; }

        const int N = 1024;
        unsigned char* px = (unsigned char*)malloc((size_t)N * N * 4);
        if (px == NULL) { printf("TSP_SWAPBENCH FAIL out of memory for the test texture\n"); return 1; }
        for (size_t i = 0; i < (size_t)N * N * 4; ++i)
            px[i] = (unsigned char)((i * 2654435761u) >> 13);
        p_glGenTextures(1, &tex);
        p_glBindTexture(GL_TEXTURE_2D, tex);
        p_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        p_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        p_glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, N, N, 0, GL_RGBA, GL_UNSIGNED_BYTE, px);
        free(px);
        p_glEnable(GL_TEXTURE_2D);
        p_glEnable(GL_BLEND);
        p_glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);  /* blended, like the UI */
        p_glMatrixMode(GL_PROJECTION); p_glLoadIdentity();
        p_glOrtho(0, 1, 0, 1, -1, 1);
        p_glMatrixMode(GL_MODELVIEW);  p_glLoadIdentity();
    }
    p_glViewport(0, 0, 1280, 720);

    double* t = (double*)calloc((size_t)frames, sizeof(double));
    if (t == NULL) { printf("TSP_SWAPBENCH FAIL out of memory for %d timings\n", frames); return 1; }

    for (int f = 0; f < frames; ++f)
    {
        double t0 = now_ms();
        p_glClearColor(0.1f, 0.2f, 0.3f, 1.0f);
        p_glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        if (mode == 1 || mode == 2)
        {
            for (int q = 0; q < quads; ++q)
            {
                float o = 0.002f * (float)q;  /* offset so the driver cannot merge them */
                p_glColor4f(1.0f, 1.0f, 1.0f, 0.9f);
                p_glBegin(GL_QUADS);
                p_glTexCoord2f(0, 0); p_glVertex2f(0 + o, 0);
                p_glTexCoord2f(1, 0); p_glVertex2f(1, 0 + o);
                p_glTexCoord2f(1, 1); p_glVertex2f(1 - o, 1);
                p_glTexCoord2f(0, 1); p_glVertex2f(0, 1 - o);
                p_glEnd();
            }
        }
        if (mode == 2) p_glFinish(); else p_SDL_GL_SwapWindow(w);
        t[f] = now_ms() - t0;
        TSP_Event e;
        while (p_SDL_PollEvent(&e)) { }
    }

    /* Drop the first 30 frames: shader/pipeline warm-up and the first flip are
     * not the steady state being measured. */
    int skip = (frames > 60) ? 30 : 0;
    int n = frames - skip;
    double sum = 0.0;
    for (int i = skip; i < frames; ++i) sum += t[i];
    qsort(t + skip, (size_t)n, sizeof(double), cmpd);
    printf("TSP_SWAPBENCH mode=%d frames=%d quads=%d min=%.2f p50=%.2f p90=%.2f max=%.2f mean=%.2f ms\n",
           mode, n, quads, t[skip], t[skip + n / 2], t[skip + (n * 9) / 10],
           t[frames - 1], sum / (double)n);
    fflush(stdout);

    free(t);
    if (tex != 0 && p_glDeleteTextures != NULL) p_glDeleteTextures(1, &tex);
    p_SDL_GL_DeleteContext(ctx);
    p_SDL_DestroyWindow(w);
    p_SDL_Quit();
    return 0;
}
