#!/usr/bin/env python3
"""
tsp_add_prewarm.py

Adds mode 9 = PREWARM to tsp_diag.c.

===========================================================================
WHAT THIS IS FOR
===========================================================================

Measured behaviour: a draw costs a fixed ~235ms, twice per frame, on the
first swing at a creature type and on the first application of a status
effect. Subsequent swings at the same creature are free. Free Action
stalled once and never again.

The stalling draw has worst_tex=0 (no texture bound) and worst_mode=0x7
(GL_QUADS), on a program id that appears nowhere else in the log. The cost
is identical - 235964us and 236037us on two draws with 17616 and 4 vertices
respectively - so it does not scale with geometry. Work that is constant
regardless of input is not rendering; it is one-time setup.

gl4es has no GL_QUADS primitive to hand to GLES2 and no fixed-function
pipeline, so it generates and compiles a shader for each distinct
fixed-function state combination it encounters, then caches it by state
key. That matches every observation: constant cost, GPU idle while the CPU
compiles, once per distinct case, free afterwards. It also explains why
SHADER mode logged nothing - those compiles happen inside gl4es, below the
LD_PRELOAD wrapper, so the wrapper never sees glCompileShader.

This mode walks the common state space once, at startup, forcing those
compiles to happen during the loading screen instead of mid-combat.

===========================================================================
THIS IS A TEST AS WELL AS A FIX
===========================================================================

If the hypothesis is right, the prewarm draws will each take roughly 235ms
- visible in the log it writes - and combat will then be clean. Startup
gets several seconds longer, during a loading screen where it does not
matter.

If the prewarm draws are all fast and combat still stalls, the hypothesis
is wrong, nothing has been broken, and one build cycle was spent ruling it
out. Either result is worth having.

===========================================================================
USAGE
===========================================================================

  python3 tsp_add_prewarm.py           apply
  python3 tsp_add_prewarm.py --revert  restore the newest backup

Then rebuild and deploy libtsp_diag.so, and enable with mode 9 alongside
the usual frame timing:

  export LIBGL_TSP_DIAG=1,2,9

Output goes to the existing LIBGL_TSP_DIAG_OUT file. Lines are tagged
PREWARM and carry the per-combination cost in microseconds.
"""

import glob
import os
import re
import shutil
import sys
import time

PATH = "/root/tsp_diag.c"

PREWARM_CODE = r'''
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
REAL(glScissor,       void, (GLint,GLint,GLsizei,GLsizei))
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

static void tsp_prewarm(void)
{
    static const float verts[]  = { 0,0, 1,0, 1,1, 0,1 };
    static const float cols[]   = { 1,1,1,1, 1,1,1,1, 1,1,1,1, 1,1,1,1 };
    static const float texco[]  = { 0,0, 1,0, 1,1, 0,1 };
    static const unsigned char px[4] = { 255, 255, 255, 255 };

    GLuint tex = 0;
    int useTex, useBlend, useAlpha, useLight, useFog, quad;
    int combos = 0;
    double t_all0, t0, dt, worst = 0.0;
    char worstdesc[128];

    resolve_glEnable(); resolve_glDisable();
    resolve_glEnableClientState(); resolve_glDisableClientState();
    resolve_glVertexPointer(); resolve_glColorPointer();
    resolve_glTexCoordPointer(); resolve_glScissor();
    resolve_glAlphaFunc(); resolve_glGenTextures();
    resolve_glTexImage2D(); resolve_glDeleteTextures();
    resolve_glDrawArrays(); resolve_glBindTexture();
    resolve_glBlendFunc();

    if (!real_glEnable || !real_glDrawArrays || !real_glVertexPointer)
    {
        if (g_out) { fprintf(g_out, "PREWARM: required entry points missing, skipped\n"); fflush(g_out); }
        return;
    }

    worstdesc[0] = 0;
    t_all0 = now_ms();

    /* keep it invisible */
    if (real_glScissor) { real_glScissor(0, 0, 1, 1); real_glEnable(GL_SCISSOR_TEST); }

    /* a 1x1 white texture so the textured variants have something bound */
    if (real_glGenTextures && real_glTexImage2D)
    {
        real_glGenTextures(1, &tex);
        if (tex && real_glBindTexture)
        {
            real_glBindTexture(GL_TEXTURE_2D, tex);
            real_glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, px);
        }
    }

    real_glEnableClientState(GL_VERTEX_ARRAY);
    real_glVertexPointer(2, GL_FLOAT, 0, verts);
    real_glEnableClientState(GL_COLOR_ARRAY);
    real_glColorPointer(4, GL_FLOAT, 0, cols);

    for (quad = 0; quad < 2; quad++)
    for (useTex = 0; useTex < 2; useTex++)
    for (useBlend = 0; useBlend < 2; useBlend++)
    for (useAlpha = 0; useAlpha < 2; useAlpha++)
    for (useLight = 0; useLight < 2; useLight++)
    for (useFog = 0; useFog < 2; useFog++)
    {
        GLenum mode = quad ? GL_QUADS : GL_TRIANGLE_FAN;

        if (useTex)
        {
            real_glEnable(GL_TEXTURE_2D);
            real_glEnableClientState(GL_TEXTURE_COORD_ARRAY);
            real_glTexCoordPointer(2, GL_FLOAT, 0, texco);
            if (tex && real_glBindTexture) real_glBindTexture(GL_TEXTURE_2D, tex);
        }
        else
        {
            real_glDisable(GL_TEXTURE_2D);
            real_glDisableClientState(GL_TEXTURE_COORD_ARRAY);
            if (real_glBindTexture) real_glBindTexture(GL_TEXTURE_2D, 0);
        }

        if (useBlend) { real_glEnable(GL_BLEND); if (real_glBlendFunc) real_glBlendFunc(0x0302, 0x0303); }
        else            real_glDisable(GL_BLEND);

        if (useAlpha) { real_glEnable(GL_ALPHA_TEST); if (real_glAlphaFunc) real_glAlphaFunc(0x0204, 0.5f); }
        else            real_glDisable(GL_ALPHA_TEST);

        if (useLight) real_glEnable(GL_LIGHTING); else real_glDisable(GL_LIGHTING);
        if (useFog)   real_glEnable(GL_FOG);      else real_glDisable(GL_FOG);

        t0 = now_ms();
        real_glDrawArrays(mode, 0, 4);
        dt = (now_ms() - t0) * 1000.0;   /* us */
        combos++;

        if (dt > worst)
        {
            worst = dt;
            snprintf(worstdesc, sizeof(worstdesc),
                     "mode=%s tex=%d blend=%d alpha=%d light=%d fog=%d",
                     quad ? "QUADS" : "TRIFAN", useTex, useBlend, useAlpha, useLight, useFog);
        }

        if (g_out && dt > 1000.0)
            fprintf(g_out, "PREWARM %8.0fus  mode=%s tex=%d blend=%d alpha=%d light=%d fog=%d\n",
                    dt, quad ? "QUADS" : "TRIFAN", useTex, useBlend, useAlpha, useLight, useFog);
    }

    /* leave state as we found it */
    real_glDisable(GL_TEXTURE_2D);
    real_glDisable(GL_BLEND);
    real_glDisable(GL_ALPHA_TEST);
    real_glDisable(GL_LIGHTING);
    real_glDisable(GL_FOG);
    real_glDisableClientState(GL_TEXTURE_COORD_ARRAY);
    real_glDisableClientState(GL_COLOR_ARRAY);
    real_glDisableClientState(GL_VERTEX_ARRAY);
    if (real_glScissor) real_glDisable(GL_SCISSOR_TEST);
    if (tex && real_glDeleteTextures) real_glDeleteTextures(1, &tex);
    if (real_glBindTexture) real_glBindTexture(GL_TEXTURE_2D, 0);

    if (g_out)
    {
        fprintf(g_out, "PREWARM done: %d combinations in %.0fms, worst %.0fus (%s)\n",
                combos, now_ms() - t_all0, worst, worstdesc[0] ? worstdesc : "none");
        fflush(g_out);
    }
}
'''

CALL_SITE = r'''
    /* TSP_PREWARM: run once, on the first swap after a context exists. */
    if (!g_prewarm_done && ON(M_PREWARM))
    {
        g_prewarm_done = 1;
        tsp_prewarm();
    }
'''


def revert():
    n = 0
    for f in sorted(glob.glob(PATH + ".before-prewarm-*")):
        pass
    backups = sorted(glob.glob(PATH + ".before-prewarm-*"))
    if not backups:
        print("no prewarm backup found")
        return 1
    shutil.copy(backups[-1], PATH)
    print("restored from", os.path.basename(backups[-1]))
    return 0


def main():
    if "--revert" in sys.argv:
        return revert()

    src = open(PATH).read()
    if "TSP_PREWARM" in src:
        print("already patched")
        return 0

    report = []

    # 1. find the mode bit definitions so we can add M_PREWARM
    modes = re.findall(r'#define\s+(M_[A-Z]+)\s+(\S+)', src)
    if not modes:
        print("ERROR: could not find any M_* mode defines. Showing candidates:")
        for i, l in enumerate(src.split("\n"), 1):
            if "#define M_" in l or "M_TEXMAP" in l:
                print("  %d: %s" % (i, l.strip()))
        return 1
    report.append("found %d existing modes: %s" % (len(modes), ", ".join(m[0] for m in modes)))

    if "M_PREWARM" not in src:
        last_def = None
        for m in re.finditer(r'#define\s+M_[A-Z]+\s+\S+.*\n', src):
            last_def = m
        src = src[:last_def.end()] + "#define M_PREWARM  (1u<<8)   /* mode 9 */\n" + src[last_def.end():]
        report.append("added M_PREWARM as mode 9")

    # 2. register mode 9 in whatever parses the mode list
    mp = re.search(r'(if\s*\(\s*n\s*==\s*8\s*\)[^\n]*\n)', src)
    if mp:
        indent = re.match(r'\s*', mp.group(1)).group(0)
        src = src[:mp.end()] + indent + "if (n == 9) g_modes |= M_PREWARM;\n" + src[mp.end():]
        report.append("registered mode 9 in the mode parser")
    else:
        report.append("WARNING: could not find the mode parser - "
                      "look for where modes 1-8 are matched and add 9 by hand")

    # 3. insert the prewarm body before the swap hook
    swap = re.search(r'\n[A-Za-z_][A-Za-z0-9_ \*]*\b(eglSwapBuffers|SDL_GL_SwapWindow|glXSwapBuffers)\s*\(', src)
    if not swap:
        print("ERROR: could not find a swap function to hook. Candidates in file:")
        for i, l in enumerate(src.split("\n"), 1):
            if "Swap" in l:
                print("  %d: %s" % (i, l.strip()[:100]))
        return 1
    swapname = swap.group(1)
    report.append("swap hook is %s" % swapname)

    src = src[:swap.start()] + "\n" + PREWARM_CODE + src[swap.start():]

    # 4. call it at the top of the swap hook body
    swap2 = re.search(r'\n[A-Za-z_][A-Za-z0-9_ \*]*\b' + swapname + r'\s*\([^)]*\)\s*\n?\{', src)
    if not swap2:
        report.append("WARNING: found the swap declaration but not its body - "
                      "add the call to tsp_prewarm() by hand")
    else:
        src = src[:swap2.end()] + CALL_SITE + src[swap2.end():]
        report.append("prewarm call inserted at the top of %s" % swapname)

    shutil.copy(PATH, PATH + ".before-prewarm-" + time.strftime("%Y%m%d-%H%M%S"))
    open(PATH, "w").write(src)

    print("\n".join("  " + r for r in report))
    print("\npatched. now build:")
    print("  cd /root && gcc -shared -fPIC -O2 -o libtsp_diag.so tsp_diag.c -ldl")
    return 0


sys.exit(main())
