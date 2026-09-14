#!/usr/bin/env python3
"""
tsp_add_shaderdump.py

Reveal what gl4es actually hands the Mali driver.

===========================================================================
WHY
===========================================================================

Measured: ~137ms in glLinkProgram plus ~236ms deferred into the first draw,
per program, on a Mali-G57. OpenMW's compatibility/objects.frag is 317 lines.
Hardware of this class compiles shaders of that size in single-digit
milliseconds. We are 20-50x off, which is not "shaders are complex" - it is
a sign something pathological is being submitted.

Cutting the point-light loop from 8 to 3 unrolled iterations changed the
numbers by nothing, which rules out raw instruction count as the driver.

OpenMW writes desktop GL 2.1 GLSL. gl4es rewrites it into GLES2 GLSL in
ConvertShader (src/gl/shaderconv.c:458), then this port layers
tsp_highp_varyings and tsp_invariant_pos on top (src/gl/shader.c:270,327).
The result, glshader->converted, is the only text Mali ever sees. Nobody has
looked at it.

This patch makes gl4es report, per shader:
  - source length in bytes and lines
  - converted length in bytes and lines
  - the expansion ratio

and, with LIBGL_TSP_SHADERDUMP set, writes the full converted text to disk.

===========================================================================
WHAT TO LOOK FOR
===========================================================================

If converted is ~= source: conversion is innocent, the cost is inside Mali's
compiler for this shader shape, and the next probe is which construct
(likely the gl_LightSource array access or a texture-matrix path).

If converted is many times source: gl4es is expanding something - most
plausibly every gl_LightSource[i] / gl_TextureMatrix[i] reference being
emitted inline per index - and THAT is the real bug. It lives in gl4es
source we have already patched successfully twice (TSP_EXTFLAGS,
TSP_PRGBIN_DETECT), and fixing it cuts both the 137ms link and the 236ms
compile, rather than redistributing them.

===========================================================================
USAGE
===========================================================================

  python3 tsp_add_shaderdump.py           apply
  python3 tsp_add_shaderdump.py --revert  restore newest backup

Then rebuild libGL and deploy. Run with:
  export LIBGL_TSP_SHADERDUMP=/mnt/SDCARD/shaderdump
to also get the full text of every converted shader on disk.
"""

import glob
import os
import shutil
import sys
import time

SRC = "/root/gl4es-tsps/src/gl/shader.c"
TAG = "TSP_SHADERDUMP"

HELPER = '''
/* ''' + TAG + ''': report what actually reaches the driver.
   gl4es rewrites OpenMW's desktop GLSL before Mali sees it; glshader->converted
   is the real compile input. A 317-line shader costing 137ms to link on a
   Mali-G57 is 20-50x slower than this hardware should be, and reducing the
   light-loop unroll changed nothing - so the submitted text is the thing to
   inspect before touching any more shader source. */
static void tsp_shader_report(const char* stage, GLuint shader, int isVertex,
                              const char* src, const char* conv)
{
    size_t slen = src ? strlen(src) : 0;
    size_t clen = conv ? strlen(conv) : 0;
    size_t slines = 0, clines = 0;
    if (src)  for (const char* p = src;  *p; ++p) if (*p == '\\n') ++slines;
    if (conv) for (const char* p = conv; *p; ++p) if (*p == '\\n') ++clines;

    fprintf(stderr,
        "TSP_SHADERDUMP %s shader=%u type=%s src_bytes=%zu src_lines=%zu "
        "conv_bytes=%zu conv_lines=%zu ratio=%.2f\\n",
        stage, shader, isVertex ? "VERT" : "FRAG",
        slen, slines, clen, clines,
        slen ? (double)clen / (double)slen : 0.0);
    fflush(stderr);

    const char* dir = getenv("LIBGL_TSP_SHADERDUMP");
    if (dir && *dir && conv) {
        char path[512];
        snprintf(path, sizeof(path), "%s/shader_%u_%s.glsl",
                 dir, shader, isVertex ? "vert" : "frag");
        FILE* f = fopen(path, "w");
        if (f) {
            fputs("/* ==== ORIGINAL (from OpenMW) ==== */\\n", f);
            if (src) fputs(src, f);
            fputs("\\n/* ==== CONVERTED (what Mali compiles) ==== */\\n", f);
            fputs(conv, f);
            fclose(f);
        }
    }
}
'''


def revert():
    b = sorted(glob.glob(SRC + ".before-shaderdump-*"))
    if not b:
        print("no backup found")
        return 1
    shutil.copy(b[-1], SRC)
    print("restored from", os.path.basename(b[-1]))
    return 0


def main():
    if "--revert" in sys.argv:
        return revert()

    if not os.path.exists(SRC):
        print("ERROR: missing", SRC)
        return 1

    s = open(SRC).read()
    if TAG in s:
        print("already patched")
        return 0

    for inc in ("<stdio.h>", "<stdlib.h>", "<string.h>"):
        if "#include %s" % inc not in s:
            i = s.find("#include")
            j = s.find("\n", i) + 1
            s = s[:j] + "#include %s\n" % inc + s[j:]

    # place helper before the first function that uses it
    anchor = "void APIENTRY_GL4ES gl4es_glShaderSource("
    if anchor not in s:
        print("ERROR: gl4es_glShaderSource anchor not found. Candidates:")
        for i, l in enumerate(s.split("\n"), 1):
            if "glShaderSource" in l:
                print("  %d: %s" % (i, l.strip()[:90]))
        return 1
    s = s.replace(anchor, HELPER + "\n" + anchor, 1)

    # both conversion sites assign glshader->converted = tsp_invariant_pos(...)
    count = 0
    out = []
    for line in s.split("\n"):
        out.append(line)
        if "glshader->converted = tsp_invariant_pos(" in line:
            indent = line[:len(line) - len(line.lstrip())]
            out.append(indent + 'tsp_shader_report("convert", shader, '
                                'glshader->type==GL_VERTEX_SHADER, '
                                'glshader->source, glshader->converted);')
            count += 1
    if count == 0:
        print("ERROR: no 'glshader->converted = tsp_invariant_pos(' sites found")
        return 1
    s = "\n".join(out)

    shutil.copy(SRC, SRC + ".before-shaderdump-" + time.strftime("%Y%m%d-%H%M%S"))
    open(SRC, "w").write(s)
    print("patched %d conversion site(s)" % count)
    print("\nbuild with:")
    print("  cd /root/gl4es-tsps/build && make -j4")
    return 0


sys.exit(main())
