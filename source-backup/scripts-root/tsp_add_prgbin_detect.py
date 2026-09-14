#!/usr/bin/env python3
"""
tsp_add_prgbin_detect.py

Adds program-binary capability detection to tsp_late_hardext() in
gl4es src/glx/hardext.c.

===========================================================================
WHY
===========================================================================

The combat/effect stall is Mali compiling GLSL programs on demand during
play: ~137ms inside glLinkProgram plus ~236ms deferred into the first draw
that uses the program. Measured, not inferred - worst_cpu_us == worst_us,
so it is CPU burn, not a GPU stall.

The fix is a persistent program binary cache, and the driver supports it:
/usr/lib/libmali.so.0.32.0 advertises GL_OES_get_program_binary and
GL_ARM_mali_program_binary and exports all four entry points.

But every attempt to save a binary returned got=0 fmt=0, because gl4es
bails first:

    int gl4es_getProgramBinary(...) {
        if(hardext.prgbin_n==0)
            return 0;

hardext.prgbin_n is set in GetHardwareExtensions() at hardext.c:388-394 -
inside the probe body that LIBGL_NOTEST=1 skips on this device, since
probing at init blue-screens it. tsp_late_hardext() was written to set
flags from the extension string instead, but it only covers depth24,
depthstencil, derivatives, depthtex, npot and highp. prgbinary and
prgbin_n were never added, so they stay 0 forever.

This is the same failure mode as the texture wobble: a real hardware
capability reported as absent because detection never ran.

===========================================================================
WHAT THIS ADDS
===========================================================================

Two lines of capability, in the existing style:

  - set hardext.prgbinary from GL_OES_get_program_binary (falling back to
    the older GL_OES_get_program spelling, as upstream does)
  - when set, query GL_NUM_PROGRAM_BINARY_FORMATS_OES into prgbin_n

The query is glGetIntegerv - a plain state read, not a probe draw - so it
carries none of the risk that made init-time probing unsafe here. It still
runs inside tsp_late_hardext (deferred to first shader compile) rather
than being moved earlier, deliberately.

===========================================================================
USAGE
===========================================================================

  python3 tsp_add_prgbin_detect.py           apply
  python3 tsp_add_prgbin_detect.py --revert  restore newest backup

Then rebuild gl4es and deploy libGL.so.1.

Expected in the launcher output on next run:

  LIBGL: TSP_LATE ... prgbinary=1 prgbin_n=1

prgbin_n greater than zero means gl4es will now honour glGetProgramBinary
and glProgramBinary, and the shader cache in libtsp_diag.so should start
producing "SCACHE miss ... bytes=N" instead of "SCACHE fail".

If prgbin_n comes back 0 while prgbinary is 1, the driver advertises the
extension but exposes no binary formats, and caching is not possible on
this device - that would be a real answer too, and worth knowing before
any more work goes into the cache.
"""

import glob
import os
import shutil
import sys
import time

PATH = "/root/gl4es-tsps/src/glx/hardext.c"

ANCHOR = '            hardext.highp = 1;'

ADDITION = '''            hardext.highp = 1;
            /* TSP_PRGBIN_DETECT: upstream sets these in GetHardwareExtensions(),
               which LIBGL_NOTEST=1 skips on this device. Without them
               hardext.prgbin_n stays 0 and gl4es_getProgramBinary /
               gl4es_glProgramBinary early-return, which is why every attempt
               to save a compiled shader came back got=0 fmt=0. The Mali blob
               does support this (GL_OES_get_program_binary +
               GL_ARM_mali_program_binary), so detect it here rather than
               losing a 375ms-per-shader compile to a capability flag. */
            if(tsp_has(e,"GL_OES_get_program_binary"))    hardext.prgbinary = 1;
            if(!hardext.prgbinary && tsp_has(e,"GL_OES_get_program"))
                                                          hardext.prgbinary = 1;
            if(hardext.prgbinary) {
                LOAD_GLES2(glGetIntegerv);
                if(gles_glGetIntegerv)
                    gles_glGetIntegerv(GL_NUM_PROGRAM_BINARY_FORMATS_OES,
                                       &hardext.prgbin_n);
            }'''

LOGLINE_OLD = '''    printf("LIBGL: TSP_LATE depth24=%d depthstencil=%d derivatives=%d npot=%d vendor=0x%x highp=%d\\n",
           hardext.depth24, hardext.depthstencil, hardext.derivatives,
           hardext.npot, hardext.vendor, hardext.highp);'''

LOGLINE_NEW = '''    printf("LIBGL: TSP_LATE depth24=%d depthstencil=%d derivatives=%d npot=%d vendor=0x%x highp=%d prgbinary=%d prgbin_n=%d\\n",
           hardext.depth24, hardext.depthstencil, hardext.derivatives,
           hardext.npot, hardext.vendor, hardext.highp,
           hardext.prgbinary, hardext.prgbin_n);'''


def revert():
    b = sorted(glob.glob(PATH + ".before-prgbin-*"))
    if not b:
        print("no prgbin backup found")
        return 1
    shutil.copy(b[-1], PATH)
    print("restored from", os.path.basename(b[-1]))
    return 0


def main():
    if "--revert" in sys.argv:
        return revert()

    src = open(PATH).read()
    if "TSP_PRGBIN_DETECT" in src:
        print("already patched")
        return 0

    if ANCHOR not in src:
        print("ERROR: anchor not found. hardext.highp lines in file:")
        for i, l in enumerate(src.split("\n"), 1):
            if "highp" in l:
                print("  %d: %s" % (i, l.rstrip()))
        return 1
    if src.count(ANCHOR) != 1:
        print("ERROR: anchor appears %d times, expected 1" % src.count(ANCHOR))
        return 1

    src = src.replace(ANCHOR, ADDITION, 1)
    print("added prgbinary / prgbin_n detection")

    if LOGLINE_OLD in src:
        src = src.replace(LOGLINE_OLD, LOGLINE_NEW, 1)
        print("extended the TSP_LATE log line")
    else:
        print("NOTE: log line not matched - detection still applied, but the")
        print("      TSP_LATE output will not show prgbinary/prgbin_n.")

    shutil.copy(PATH, PATH + ".before-prgbin-" + time.strftime("%Y%m%d-%H%M%S"))
    open(PATH, "w").write(src)
    print("\nwritten. rebuild gl4es next.")
    return 0


sys.exit(main())
