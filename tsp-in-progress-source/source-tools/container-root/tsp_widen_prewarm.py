#!/usr/bin/env python3
"""
tsp_widen_prewarm.py

Replaces tsp_prewarm() in tsp_diag.c with a version that covers multiple
texture units and multiple enabled lights.

===========================================================================
WHY
===========================================================================

The first prewarm run confirmed the mechanism and bounded it:

  64 combinations attempted, 16 actually compiled something, 12-25ms each,
  304ms total. The 16 were exactly the tex x alpha x light x fog set -
  blend state and primitive mode did NOT produce new shaders, which is
  correct: blending is a ROP operation and QUADS->triangles is index
  generation, so neither needs its own program.

So gl4es does compile fixed-function shaders lazily and it is expensive.
But 12-25ms is an order of magnitude short of the 235ms stall, so the
variants the game actually hits are not the trivial ones the first pass
covered. That pass bound a single texture unit and enabled GL_LIGHTING
without configuring any lights.

Real Morrowind draws use several texture units at once and several active
lights. Those generate substantially larger shaders. Whether that closes a
10x gap is genuinely unknown - this is the test.

===========================================================================
WHAT CHANGED
===========================================================================

  texture units   0..LIBGL_TSP_PREWARM_MAXTEX   (default 4)
  active lights   0..LIBGL_TSP_PREWARM_MAXLIGHT (default 4)
  alpha test      off, on
  fog             off, on

Lights are given real position/colour values, since a driver may fold
unconfigured lights away and never generate the code we are trying to
force.

Dropped from the loop: blend and primitive mode, proven not to matter.
That frees the budget for the dimensions that do.

Default is 5 x 5 x 2 x 2 = 100 combinations. If each costs 235ms that is
~23s of loading screen - long, but it happens once and it is the answer.
Dial the ranges down with the env vars if it is unbearable.

===========================================================================
USAGE
===========================================================================

  python3 tsp_widen_prewarm.py           apply
  python3 tsp_widen_prewarm.py --revert  restore newest backup

Rebuild, deploy, then enable everything for one combined run:

  export LIBGL_TSP_DIAG=1,2,8,256,512

  1   = FRAME    per-frame line
  2   = TIMING   draw_us / swap_us / worst draw
  8   = FBO      framebuffer bind/attach/status - the tex=256 failure
  256 = TEXMAP   texture id -> size/format, identifies tex 256
  512 = PREWARM  this

That single run covers both open threads.
"""

import glob
import os
import shutil
import sys
import time

PATH = "/root/tsp_diag.c"
FUNC = "static void tsp_prewarm(void)"

NEW_FUNC = r'''static void tsp_prewarm(void)
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
}'''

EXTRA_REALS = '''REAL(glActiveTexture,       void, (GLenum))
REAL(glClientActiveTexture, void, (GLenum))
REAL(glLightfv,             void, (GLenum,GLenum,const float*))
'''

EXTRA_DEFS = '''#ifndef GL_TEXTURE0
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
'''


def find_function(src, sig):
    """Locate a function by signature and return (start, end) by brace matching."""
    start = src.find(sig)
    if start < 0:
        return None
    brace = src.find("{", start)
    if brace < 0:
        return None
    depth = 0
    i = brace
    while i < len(src):
        c = src[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return (start, i + 1)
        elif c == '"':          # skip string literals
            i += 1
            while i < len(src) and src[i] != '"':
                if src[i] == "\\":
                    i += 1
                i += 1
        elif c == "'":          # skip char literals
            i += 1
            while i < len(src) and src[i] != "'":
                if src[i] == "\\":
                    i += 1
                i += 1
        elif src.startswith("/*", i):
            j = src.find("*/", i)
            i = j + 1 if j > 0 else len(src)
        elif src.startswith("//", i):
            j = src.find("\n", i)
            i = j if j > 0 else len(src)
        i += 1
    return None


def revert():
    backups = sorted(glob.glob(PATH + ".before-widen-*"))
    if not backups:
        print("no widen backup found")
        return 1
    shutil.copy(backups[-1], PATH)
    print("restored from", os.path.basename(backups[-1]))
    return 0


def main():
    if "--revert" in sys.argv:
        return revert()

    src = open(PATH).read()

    span = find_function(src, FUNC)
    if not span:
        print("ERROR: could not locate", FUNC)
        for i, l in enumerate(src.split("\n"), 1):
            if "tsp_prewarm" in l:
                print("  %d: %s" % (i, l.strip()[:90]))
        return 1
    a, b = span
    old_len = b - a
    print("found tsp_prewarm: %d bytes" % old_len)

    # declare the extra GL entry points, skipping any already present upstream
    head = src[:a]
    needed = []
    for line in EXTRA_REALS.strip().split("\n"):
        name = line.split("(")[1].split(",")[0].strip()
        if ("REAL(%s," % name) in head or ("REAL(%s " % name) in head:
            print("  already declared upstream:", name)
        else:
            needed.append(line)
    add = ""
    if needed:
        add += "\n".join(needed) + "\n"
        print("  adding %d entry point(s)" % len(needed))

    defs = [d for d in EXTRA_DEFS.strip().split("#ifndef ") if d]
    add_defs = ""
    for d in defs:
        name = d.split("\n")[0].strip()
        if ("#define %s" % name) not in src:
            add_defs += "#ifndef " + d if d.startswith(name) else ""
    if EXTRA_DEFS.strip() not in src:
        add_defs = EXTRA_DEFS
        print("  adding GL constant defines")

    src = src[:a] + add_defs + add + NEW_FUNC + src[b:]

    shutil.copy(PATH, PATH + ".before-widen-" + time.strftime("%Y%m%d-%H%M%S"))
    open(PATH, "w").write(src)
    print("replaced tsp_prewarm (%d -> %d bytes)" % (old_len, len(NEW_FUNC)))
    print()
    print("build with:")
    print("  cd /root && gcc -shared -fPIC -O2 -o libtsp_diag.so tsp_diag.c -ldl")
    return 0


sys.exit(main())
