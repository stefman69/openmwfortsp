#!/usr/bin/env python3
"""
tsp_add_shadercache.py

Adds a persistent shader program binary cache to tsp_diag.c (mode 1024).

===========================================================================
THE PROBLEM THIS FIXES
===========================================================================

Measured, not guessed:

  LINK prog=7   137349us    <- glLinkProgram itself
  f=755 ... worst_us=236497 worst_cpu_us=236615 worst_prog=7
  LINK prog=51  140536us
  f=987 ... worst_us=238829 worst_cpu_us=238823 worst_prog=51

worst_cpu_us == worst_us, so the thread is burning CPU, not blocked on the
GPU or a fence. The LINK line lands immediately before the stall frame, so
OpenMW is creating and linking a GLSL program mid-combat and Mali charges
~137ms in the link plus ~236ms deferred into the first draw that uses the
program - about 375ms per new program, in one frame, once per program.

That is the whole stall: first swing at a creature type, first application
of a status effect, Free Action stalling exactly once. Every one of those
is "a shader variant this session has not built yet".

===========================================================================
THE FIX
===========================================================================

The device supports it - checked, not assumed:

  /usr/lib/libmali.so.0.32.0 exports glGetProgramBinary / glProgramBinary
  and advertises GL_OES_get_program_binary + GL_ARM_mali_program_binary.
  gl4es already wraps both (program.c: gl4es_getProgramBinary /
  gl4es_useProgramBinary).

So: hash the shader sources at link time. On a cache hit, restore the
compiled binary with glProgramBinary and skip compilation entirely. On a
miss, link normally, then save the binary out.

First playthrough still pays the full cost as it does today. Every session
after that reads from disk instead of invoking the Mali compiler.

===========================================================================
WHAT THIS DOES NOT DO
===========================================================================

It does not make the very first encounter with a new shader free. Nothing
short of shipping a pre-populated cache with the port does that - which
becomes possible later, once one playthrough has filled the cache.

It is also not yet known whether a restored binary skips the deferred
~236ms as well as the ~137ms link. The log tells us: if stalls drop to
roughly 236ms, only the link was saved and a warm-up draw per cached
program is the follow-up. If they drop to single digits, both halves were
cached and it is done.

===========================================================================
USAGE
===========================================================================

  python3 tsp_add_shadercache.py           apply
  python3 tsp_add_shadercache.py --revert  restore newest backup

Rebuild, deploy, then enable alongside frame timing:

  export LIBGL_TSP_DIAG=1,2,1024
  export LIBGL_TSP_SHADERCACHE=/mnt/SDCARD/data/ports/openmw51/shadercache

The cache directory is created if missing. Delete it to force a rebuild
after changing shaders or updating gl4es - binaries are driver- and
source-specific and a stale one is rejected by the driver, not silently
mis-rendered, but clearing is cleaner.

Log lines:
  SCACHE hit  prog=N key=... %.0fus
  SCACHE miss prog=N key=... link=%.0fus save=%.0fus bytes=N
  SCACHE fail prog=N key=... (binary rejected, fell back to normal link)
"""

import glob
import os
import shutil
import sys
import time

PATH = "/root/tsp_diag.c"

BLOCK = r'''
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
'''

SHADERSOURCE_HOOK = r'''
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
'''

NEW_LINK = r'''void glLinkProgram(GLuint p)
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
}'''

EXTRA_REALS = [
    ("glProgramBinary",    "void,   (GLuint,GLenum,const void*,GLsizei)"),
    ("glGetProgramBinary", "void,   (GLuint,GLsizei,GLsizei*,GLenum*,void*)"),
    ("glGetProgramiv",     "void,   (GLuint,GLenum,GLint*)"),
    ("glShaderSource",     "void,   (GLuint,GLsizei,const GLchar* const*,const GLint*)"),
    ("glAttachShader",     "void,   (GLuint,GLuint)"),
]


def find_function(src, sig):
    """Locate a function by signature, return (start, end) via brace matching."""
    start = src.find(sig)
    if start < 0:
        return None
    brace = src.find("{", start)
    if brace < 0:
        return None
    depth, i = 0, brace
    while i < len(src):
        c = src[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return (start, i + 1)
        elif c == '"':
            i += 1
            while i < len(src) and src[i] != '"':
                if src[i] == "\\":
                    i += 1
                i += 1
        elif src.startswith("/*", i):
            j = src.find("*/", i)
            i = j + 1 if j > 0 else len(src)
        i += 1
    return None


def revert():
    b = sorted(glob.glob(PATH + ".before-scache-*"))
    if not b:
        print("no scache backup found")
        return 1
    shutil.copy(b[-1], PATH)
    print("restored from", os.path.basename(b[-1]))
    return 0


def main():
    if "--revert" in sys.argv:
        return revert()

    src = open(PATH).read()
    if "TSP_SHADERCACHE" in src:
        print("already patched")
        return 0

    report = []

    # headers the cache needs
    for inc in ("<string.h>", "<stdlib.h>", "<sys/stat.h>"):
        if "#include %s" % inc not in src:
            src = src.replace("#include <stdio.h>", "#include <stdio.h>\n#include %s" % inc, 1)
            report.append("added include %s" % inc)

    # mode bit - next free above PREWARM (1u<<9)
    if "M_SCACHE" not in src:
        anchor = None
        for line in src.split("\n"):
            if line.startswith("#define M_") and "(1u<<" in line:
                anchor = line
        if not anchor:
            print("ERROR: no M_* mode defines found")
            return 1
        src = src.replace(anchor, anchor + "\n#define M_SCACHE   (1u<<10)  /* pass 1024 */", 1)
        report.append("added M_SCACHE as 1024")

    # entry points, skipping any already declared
    needed = []
    for name, sig in EXTRA_REALS:
        if ("REAL(%s," % name) in src:
            report.append("already declared: %s" % name)
        else:
            needed.append("REAL(%s,%s)" % (name, sig))
    if needed:
        m = None
        for line in src.split("\n"):
            if line.startswith("REAL("):
                m = line
        if not m:
            print("ERROR: no REAL() lines found")
            return 1
        src = src.replace(m, m + "\n" + "\n".join(needed), 1)
        report.append("added %d entry point(s)" % len(needed))

    # remove any pre-existing glShaderSource / glAttachShader hooks we replace
    for fn in ("void glShaderSource(", "void glAttachShader("):
        span = find_function(src, fn)
        if span:
            a, b = span
            src = src[:a] + src[b:]
            report.append("replaced existing hook: %s" % fn.split()[1].split("(")[0])

    # the cache implementation, placed before the link hook
    span = find_function(src, "void glLinkProgram(")
    if not span:
        print("ERROR: could not find glLinkProgram hook. Candidates:")
        for i, l in enumerate(src.split("\n"), 1):
            if "glLinkProgram" in l:
                print("  %d: %s" % (i, l.strip()[:90]))
        return 1
    a, b = span
    src = src[:a] + BLOCK + SHADERSOURCE_HOOK + "\n" + NEW_LINK + src[b:]
    report.append("installed cache and rewrote glLinkProgram")

    shutil.copy(PATH, PATH + ".before-scache-" + time.strftime("%Y%m%d-%H%M%S"))
    open(PATH, "w").write(src)

    print("\n".join("  " + r for r in report))
    print("\nbuild with:")
    print("  cd /root && gcc -shared -fPIC -O2 -o libtsp_diag.so tsp_diag.c -ldl")
    return 0


sys.exit(main())
