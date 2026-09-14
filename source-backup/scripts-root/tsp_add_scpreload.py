#!/usr/bin/env python3
"""
tsp_add_scpreload.py

Preload every cached shader binary at startup (mode 2048), during the
loading screen, and warm each one.

===========================================================================
THE QUESTION THIS ANSWERS
===========================================================================

Established so far, all measured:

  - Mali charges ~137ms in glLinkProgram plus ~236ms deferred to the first
    draw using the program. worst_cpu_us == worst_us, so it is CPU work.
  - The binary cache removed the 137ms link permanently.
  - The deferred ~236ms is irreducible. The warm-up proved it only moves:
    SCWARM prog=4 237289us, prog=9 238892us, prog=12 237446us, landing as
    f=88 ms=854.4 swap_us=758398. Same cost, one frame later.
  - There is no free window at restore time, because OpenMW links a program
    in the same frame it first draws with it.

So the only remaining question is whether that 236ms can be paid somewhere
harmless - specifically the loading screen, before the player has control.

That depends on something we do not know yet:

  Does Mali key its compiled program state to the BINARY CONTENT, or to the
  PROGRAM OBJECT?

  If BINARY: preloading each cached binary into our own throwaway program
  object and warming it populates a driver-side cache. OpenMW's later
  glProgramBinary of the same bytes is then cheap, and the stall is gone.

  If OBJECT: our warmed program objects are unrelated to OpenMW's, the work
  is redundant, and OpenMW still pays 236ms per program during play. That
  closes the wrapper avenue entirely and the fix has to move into OpenMW's
  shader manager.

Either result is worth having. A negative here is not a wasted step - it is
what tells us to stop working in the wrapper.

===========================================================================
WHAT IT DOES
===========================================================================

On the first buffer swap (loading screen, before player control):

  1. Enumerate *.bin in the shader cache directory
  2. For each: glCreateProgram, glProgramBinary, then the same warm-up draw
     already proven to force finalisation
  3. Keep the program objects alive for the session, so nothing the driver
     associated with them is torn down
  4. Log each one

Expect roughly 240ms per cached program - with ~12 cached that is about
three seconds added to load. Acceptable if it removes mid-combat stalls,
pointless if it does not, which is exactly what the test determines.

===========================================================================
READING THE RESULT
===========================================================================

  SCPRE file=<key> prog=N load=%.0fus warm=%.0fus

Then play and check the stalls:

  SUCCESS - SCPRE lines show ~240000us warm each at startup, and during
  play SCACHE hit stays small AND no five-digit worst_us stalls appear.
  Mali caches by binary; the cost now lives in the loading screen.

  FAILURE - SCPRE lines show ~240000us at startup AND the same ~236ms
  stalls still appear during play. Mali caches per program object; the
  startup work was redundant. Move to OpenMW.

===========================================================================
USAGE
===========================================================================

  python3 tsp_add_scpreload.py           apply
  python3 tsp_add_scpreload.py --revert  restore newest backup

Enable with mode 2048 alongside the rest:

  export LIBGL_TSP_DIAG=1,2,1024,2048

LIBGL_TSP_NOPRELOAD=1 disables it at runtime without rebuilding.
"""

import glob
import os
import re
import shutil
import sys
import time

PATH = "/root/tsp_diag.c"

BLOCK = r'''
/* ------------------------------------------------------------------ */
/* TSP_SCPRELOAD (mode 2048)                                           */
/*                                                                     */
/* Tests whether Mali keys compiled program state to the binary content */
/* or to the program object. Loads every cached binary into its own     */
/* throwaway program at the loading screen and warms it. If the driver  */
/* caches by binary, OpenMW's later restore of the same bytes is cheap  */
/* and the mid-combat stall disappears. If it caches per object, the    */
/* stalls remain and the wrapper approach is exhausted.                 */
/* ------------------------------------------------------------------ */

#define SCP_MAX 128
static GLuint scp_progs[SCP_MAX];
static int    scp_n;
static int    scp_done;

static void scp_preload(void)
{
    DIR *d;
    struct dirent *e;
    const char *env;
    double t_all;

    if (scp_done) return;
    scp_done = 1;
    if (!ON(M_SCPRELOAD)) return;
    env = getenv("LIBGL_TSP_NOPRELOAD");
    if (env && env[0] && env[0] != '0') return;

    sc_init();
    resolve_glCreateProgram();
    resolve_glProgramBinary();
    resolve_glGetProgramiv();
    if (!real_glCreateProgram || !real_glProgramBinary) {
        if (g_out) { fprintf(g_out, "SCPRE unavailable\n"); fflush(g_out); }
        return;
    }

    d = opendir(sc_dir);
    if (!d) {
        if (g_out) { fprintf(g_out, "SCPRE no dir %s\n", sc_dir); fflush(g_out); }
        return;
    }

    t_all = now_ms();
    while ((e = readdir(d)) != NULL && scp_n < SCP_MAX) {
        char path[700];
        FILE *f;
        long len;
        void *buf;
        GLenum fmt;
        GLint ok = 0;
        GLuint prog;
        double t0, tload, twarm;
        size_t nl = strlen(e->d_name);

        if (nl < 5 || strcmp(e->d_name + nl - 4, ".bin") != 0) continue;
        snprintf(path, sizeof(path), "%s/%s", sc_dir, e->d_name);
        f = fopen(path, "rb");
        if (!f) continue;
        if (fread(&fmt, sizeof(fmt), 1, f) != 1) { fclose(f); continue; }
        fseek(f, 0, SEEK_END);
        len = ftell(f) - (long)sizeof(fmt);
        fseek(f, sizeof(fmt), SEEK_SET);
        if (len <= 0) { fclose(f); continue; }
        buf = malloc((size_t)len);
        if (!buf) { fclose(f); continue; }
        if (fread(buf, 1, (size_t)len, f) != (size_t)len) { free(buf); fclose(f); continue; }
        fclose(f);

        t0 = now_ms();
        prog = real_glCreateProgram();
        if (!prog) { free(buf); continue; }
        real_glProgramBinary(prog, fmt, buf, (GLsizei)len);
        if (real_glGetProgramiv) real_glGetProgramiv(prog, GL_LINK_STATUS, &ok);
        tload = (now_ms() - t0) * 1000.0;
        free(buf);

        if (!ok) {
            if (g_out) fprintf(g_out, "SCPRE file=%s REJECTED\n", e->d_name);
            continue;
        }

        t0 = now_ms();
        scw_warm_one(prog);
        twarm = (now_ms() - t0) * 1000.0;

        /* keep it alive - deleting might discard whatever the driver built */
        scp_progs[scp_n++] = prog;

        if (g_out) {
            fprintf(g_out, "SCPRE file=%s prog=%u load=%.0fus warm=%.0fus\n",
                    e->d_name, prog, tload, twarm);
            fflush(g_out);
        }
    }
    closedir(d);

    if (g_out) {
        fprintf(g_out, "SCPRE done n=%d total=%.0fms\n",
                scp_n, now_ms() - t_all);
        fflush(g_out);
    }
}
'''


def revert():
    b = sorted(glob.glob(PATH + ".before-scpreload-*"))
    if not b:
        print("no scpreload backup found")
        return 1
    shutil.copy(b[-1], PATH)
    print("restored from", os.path.basename(b[-1]))
    return 0


def main():
    if "--revert" in sys.argv:
        return revert()

    src = open(PATH).read()
    if "TSP_SCPRELOAD" in src:
        print("already patched")
        return 0
    for need in ("scw_warm_one", "sc_init", "scw_drain"):
        if need not in src:
            print("ERROR: %s missing - apply the cache and warm-up patches first" % need)
            return 1

    report = []

    if "#include <dirent.h>" not in src:
        src = src.replace("#include <stdio.h>", "#include <stdio.h>\n#include <dirent.h>", 1)
        report.append("added dirent.h")

    if "M_SCPRELOAD" not in src:
        anchor = None
        for line in src.split("\n"):
            if line.startswith("#define M_") and "(1u<<" in line:
                anchor = line
        if not anchor:
            print("ERROR: no M_* defines")
            return 1
        src = src.replace(anchor, anchor + "\n#define M_SCPRELOAD (1u<<11)  /* pass 2048 */", 1)
        report.append("added M_SCPRELOAD as 2048")

    if "REAL(glCreateProgram," not in src:
        first = re.search(r'^REAL\([^\n]*\n', src, re.M)
        src = src[:first.start()] + "REAL(glCreateProgram,GLuint, (void))\n" + src[first.start():]
        report.append("added glCreateProgram entry point")

    # place after scw_drain so scw_warm_one is already declared
    m = re.search(r'static void scw_drain\(void\)\s*\{[^}]*\}', src, re.S)
    if not m:
        print("ERROR: could not locate scw_drain to insert after")
        return 1
    src = src[:m.end()] + "\n" + BLOCK + src[m.end():]
    report.append("installed preload")

    # fire on the first swap, before the drain
    pat = "    scw_drain();   /* TSP_SCWARM2 */"
    n = src.count(pat)
    if n == 0:
        print("ERROR: no scw_drain() call sites found")
        return 1
    src = src.replace(pat, "    scp_preload();  /* TSP_SCPRELOAD */\n" + pat)
    report.append("preload call added at %d swap site(s)" % n)

    shutil.copy(PATH, PATH + ".before-scpreload-" + time.strftime("%Y%m%d-%H%M%S"))
    open(PATH, "w").write(src)
    print("\n".join("  " + r for r in report))
    print("\nbuild with:")
    print("  cd /root && gcc -shared -fPIC -O2 -o libtsp_diag.so tsp_diag.c -ldl")
    return 0


sys.exit(main())
