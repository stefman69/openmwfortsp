#!/usr/bin/env python3
"""
tsp_add_scwarm2.py

Safe deferred shader warm-up for the tsp_diag.c program binary cache.

===========================================================================
WHAT THIS IS FOR
===========================================================================

The shader binary cache removed the ~137ms glLinkProgram cost, but Mali
still defers ~236ms of per-program work to the first draw that uses the
program. Measured: a restore at one line, the 236ms stall in the very next
frame.

A throwaway draw at restore time does pull that work forward - the first
attempt proved it, with a restore jumping to 247242us and the stall count
dropping from 3 to 1. But that attempt broke rendering: plants and
creatures invisible, interiors flat blue.

===========================================================================
WHY THE FIRST ATTEMPT BROKE RENDERING
===========================================================================

Two mistakes, both mine:

1. It used glVertexPointer + glEnableClientState. That is the FIXED
   FUNCTION path. OpenMW's shaders use generic vertex attributes, so those
   calls dragged gl4es's fixed-pipeline emulation state into it and left
   it inconsistent. This version uses glVertexAttribPointer on attribute 0
   and never touches client state.

2. It restored almost nothing. The array pointer, buffer binding, scissor
   box, and write masks were all left however the warm-up set them, so
   every subsequent draw read the wrong vertex data - which is exactly
   "invisible but still interactable" geometry.

===========================================================================
HOW THIS VERSION WORKS
===========================================================================

Deferred: restores during a frame are queued, not drawn. The queue drains
immediately AFTER the buffer swap, when the frame is complete and OpenMW
is between frames. Smaller blast radius, and the cost lands at a frame
boundary rather than inside a draw batch.

Scratch VBO: a single tiny buffer created once. No client-side pointer is
ever handed to GL, so nothing OpenMW set can be clobbered by ours.

Full save/restore around each warm-up:
    current program, array buffer binding,
    attribute 0: enabled / size / type / normalized / stride / binding / pointer,
    scissor enable + box, depth write mask, colour write mask, cull face

Invisible by construction: scissored to 1x1 with colour and depth writes
masked off, so even if the draw lands on the default framebuffer it cannot
change a pixel.

Errors from the warm-up draw are expected - the program's other attributes
and uniforms are not bound. They are swallowed with glGetError so OpenMW
never sees them. The draw still forces the driver to finalise the program,
which is the entire point.

===========================================================================
USAGE
===========================================================================

  python3 tsp_add_scwarm2.py           apply
  python3 tsp_add_scwarm2.py --revert  restore newest backup

Rebuild and deploy libtsp_diag.so, then run twice (cache is already
populated, so run one should be all hits).

Reading the result:

  SCWARM prog=N %.0fus     - one line per warm-up, after the swap
  SCACHE hit ... %.0fus    - stays small; the cost is now in SCWARM

Success is SCWARM lines in the 200000us range AND no five-digit worst_us
stalls during play. If rendering breaks again, revert immediately - the
cache alone is still a large win and is known good.

Set LIBGL_TSP_NOWARM=1 to disable the warm-up at runtime without
rebuilding, keeping the cache active.
"""

import glob
import os
import re
import shutil
import sys
import time

PATH = "/root/tsp_diag.c"

WARM_BLOCK = r'''
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
'''

EXTRA_REALS = [
    ("glGetBooleanv",              "void,   (GLenum,GLboolean*)"),
    ("glBindBuffer",               "void,   (GLenum,GLuint)"),
    ("glBufferData",               "void,   (GLenum,long,const void*,GLenum)"),
    ("glGenBuffers",               "void,   (GLsizei,GLuint*)"),
    ("glVertexAttribPointer",      "void,   (GLuint,GLint,GLenum,GLboolean,GLsizei,const void*)"),
    ("glEnableVertexAttribArray",  "void,   (GLuint)"),
    ("glDisableVertexAttribArray", "void,   (GLuint)"),
    ("glGetVertexAttribiv",        "void,   (GLuint,GLenum,GLint*)"),
    ("glGetVertexAttribPointerv",  "void,   (GLuint,GLenum,void**)"),
    ("glIsEnabled",                "GLboolean, (GLenum)"),
    ("glDepthMask",                "void,   (GLboolean)"),
    ("glColorMask",                "void,   (GLboolean,GLboolean,GLboolean,GLboolean)"),
    ("glGetError",                 "GLenum, (void)"),
    ("glGetIntegerv",              "void,   (GLenum,GLint*)"),
    ("glUseProgram",               "void,   (GLuint)"),
    ("glScissor",                  "void,   (GLint,GLint,GLsizei,GLsizei)"),
    ("glEnable",                   "void,   (GLenum)"),
    ("glDisable",                  "void,   (GLenum)"),
    ("glDrawArrays",               "void,   (GLenum,GLint,GLsizei)"),
]


def find_function(src, sig):
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
    b = sorted(glob.glob(PATH + ".before-scwarm2-*"))
    if not b:
        print("no scwarm2 backup found")
        return 1
    shutil.copy(b[-1], PATH)
    print("restored from", os.path.basename(b[-1]))
    return 0


def main():
    if "--revert" in sys.argv:
        return revert()

    src = open(PATH).read()
    if "TSP_SCWARM2" in src:
        print("already patched")
        return 0
    if "sc_try_load" not in src:
        print("ERROR: shader cache not present - apply tsp_add_shadercache.py first")
        return 1

    report = []

    # every REAL() the warm-up needs, hoisted above the first existing one
    # so the declarations precede all use
    existing = set(re.findall(r'REAL\(\s*(\w+)\s*,', src))
    add, relocated = [], []
    for name, sig in EXTRA_REALS:
        if name in existing:
            m = re.search(r'^REAL\(\s*%s\s*,[^\n]*\n' % re.escape(name), src, re.M)
            if m:
                relocated.append(m.group(0).rstrip("\n"))
                src = src[:m.start()] + src[m.end():]
        else:
            add.append("REAL(%s,%s)" % (name, sig))
    first = re.search(r'^REAL\([^\n]*\n', src, re.M)
    if not first:
        print("ERROR: no REAL() block found")
        return 1
    block = relocated + add
    src = src[:first.start()] + "\n".join(block) + "\n" + src[first.start():]
    report.append("hoisted %d existing, added %d new entry point(s)"
                  % (len(relocated), len(add)))

    # warm-up implementation, placed just before sc_try_load
    idx = src.find("static int sc_try_load(")
    if idx < 0:
        print("ERROR: sc_try_load not found")
        return 1
    src = src[:idx] + WARM_BLOCK + "\n" + src[idx:]
    report.append("installed warm-up implementation")

    # queue instead of drawing inline
    span = find_function(src, "static int sc_try_load(")
    if not span:
        print("ERROR: could not bound sc_try_load")
        return 1
    a, b = span
    body = src[a:b]
    if "scw_enqueue" not in body:
        old = "    *us = (now_ms() - t0) * 1000.0;\n    free(buf);\n    return ok ? 1 : 0;"
        new = ("    *us = (now_ms() - t0) * 1000.0;\n    free(buf);\n"
               "    if (ok) scw_enqueue(prog);   /* TSP_SCWARM2: drained after swap */\n"
               "    return ok ? 1 : 0;")
        if old in body:
            body = body.replace(old, new, 1)
            report.append("queue restored programs for warm-up")
        else:
            print("WARNING: could not add scw_enqueue automatically.")
            print("         Add 'if (ok) scw_enqueue(prog);' before sc_try_load returns.")
        src = src[:a] + body + src[b:]

    # drain right after the real swap
    swap = None
    for name in ("eglSwapBuffers", "SDL_GL_SwapWindow", "glXSwapBuffers"):
        m = re.search(r'\n[A-Za-z_][\w \*]*\b%s\s*\([^)]*\)\s*\n?\{' % name, src)
        if m:
            swap = (name, m)
            break
    if not swap:
        print("WARNING: no swap hook found. Warm-ups will queue but never drain.")
        print("         Swap-like lines in the file:")
        for i, l in enumerate(src.split("\n"), 1):
            if "Swap" in l:
                print("           %d: %s" % (i, l.strip()[:90]))
    else:
        name, m = swap
        span = find_function(src, src[m.start():m.end()].strip().rstrip("{").strip())
        call = re.search(r'(\n[^\n]*real_%s\s*\([^;]*;)' % re.escape(name), src)
        if call:
            src = src[:call.end()] + "\n    scw_drain();   /* TSP_SCWARM2 */" + src[call.end():]
            report.append("drain inserted after real_%s" % name)
        else:
            print("WARNING: found %s but not its real_ call; add scw_drain() by hand" % name)

    shutil.copy(PATH, PATH + ".before-scwarm2-" + time.strftime("%Y%m%d-%H%M%S"))
    open(PATH, "w").write(src)
    print("\n".join("  " + r for r in report))
    print("\nbuild with:")
    print("  cd /root && gcc -shared -fPIC -O2 -o libtsp_diag.so tsp_diag.c -ldl")
    return 0


sys.exit(main())
