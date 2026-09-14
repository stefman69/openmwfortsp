import glob
import sys
import time
P = "/root/tsp_state.c"
if len(sys.argv) > 1:
    P = sys.argv[1]
MARK = "TSP_LISTWRAP_V2"
STAMP = time.strftime("%Y%m%d-%H%M%S")
def rd(p):
    return open(p, encoding="utf-8", errors="replace").read()
cur = rd(P)
baks = sorted(glob.glob(P + ".before-listwrap*"))
src = None
note = ""
if baks:
    for b in baks:
        t = rd(b)
        if "TSP_LISTWRAP" not in t:
            src = t
            note = "pristine text restored from " + b
            break
    if src is None:
        print("GATE FAIL: " + str(len(baks)) + " listwrap backup(s) exist but every one contains TSP_LISTWRAP - no pristine copy found. NOTHING WRITTEN.")
        for b in baks:
            print("  " + b)
        sys.exit(1)
else:
    if "TSP_LISTWRAP" in cur:
        print("GATE FAIL: " + P + " carries TSP_LISTWRAP but no .before-listwrap* backup exists - unknown state. NOTHING WRITTEN.")
        sys.exit(1)
    src = cur
    note = "fresh apply, no prior listwrap backups"
lines = src.split("\n")
iw = [i for i, l in enumerate(lines) if l.startswith("#define WRAPC(")]
io = [i for i, l in enumerate(lines) if l.strip() == "other = frame_us - sum;"]
fail = []
if len(iw) != 1:
    fail.append("anchor '#define WRAPC(' matched " + str(len(iw)) + " lines, want 1")
if len(io) != 1:
    fail.append("anchor 'other = frame_us - sum;' matched " + str(len(io)) + " lines, want 1")
for need in ("static void st_init", "now_ms", "g_on", "g_out", "g_frame", "g_max", "#define REAL(", "n_draw"):
    if need not in src:
        fail.append("required symbol/text missing: " + repr(need))
if "glCallList" in src:
    fail.append("pristine text already mentions glCallList - refusing to double-wrap")
if fail:
    print("ANCHOR FAILURE - NOTHING WRITTEN (full pre-run file is saved on the VM as ~/tsp_state_prepatch.c)")
    for f in fail:
        print("  " + f)
    print("--- survey (lines matching the anchor patterns) ---")
    shown = 0
    for i, l in enumerate(lines, 1):
        if ("#define" in l) or ("frame_us" in l) or ("st_init" in l) or ("g_max" in l) or ("n_draw" in l and "," not in l):
            print("  %4d| %s" % (i, l[:140]))
            shown += 1
            if shown >= 50:
                print("  ... survey capped at 50 lines")
                break
    sys.exit(1)
B = []
B.append("/* TSP_LISTWRAP_V2 - time OSG display-list submission separately.")
B.append("   The shim counts ~178 glDrawElements/frame while OSG reports ~656 visible")
B.append("   drawables. nifloader.cpp never calls setUseDisplayList(false), so NIF statics")
B.append("   keep OSG's default display-list path and are submitted via glCallList, which")
B.append("   this shim never wrapped - that cost has been hiding inside other_us (61 ms of")
B.append("   an 83 ms slow frame, unattributed). glNewList/glEndList are timed separately:")
B.append("   if news is non-zero, lists are being RECOMPILED during gameplay, which would")
B.append("   be a finding on its own.")
B.append("   V2 over V1: the L line carries d= (this frame's draw count) so the reader can")
B.append("   drop menu/loading frames exactly like the S readers do (agreement 25). */")
B.append("REAL(glCallList, void, (unsigned int))")
B.append("REAL(glCallLists, void, (int, unsigned int, const void *))")
B.append("REAL(glNewList, void, (unsigned int, unsigned int))")
B.append("REAL(glEndList, void, (void))")
B.append("static double us_list = 0.0;")
B.append("static double us_newl = 0.0;")
B.append("static unsigned long n_list = 0;")
B.append("static unsigned long n_newl = 0;")
B.append("void glCallList(unsigned int list)")
B.append("{")
B.append("    double t0 = 0;")
B.append("    st_init();")
B.append("    resolve_glCallList();")
B.append("    if (g_on) { n_list++; t0 = now_ms(); }")
B.append("    if (real_glCallList) real_glCallList(list);")
B.append("    if (g_on) us_list += (now_ms() - t0) * 1000.0;")
B.append("}")
B.append("void glCallLists(int n, unsigned int type, const void *lists)")
B.append("{")
B.append("    double t0 = 0;")
B.append("    st_init();")
B.append("    resolve_glCallLists();")
B.append("    if (g_on) { if (n > 0) n_list += (unsigned long)n; t0 = now_ms(); }")
B.append("    if (real_glCallLists) real_glCallLists(n, type, lists);")
B.append("    if (g_on) us_list += (now_ms() - t0) * 1000.0;")
B.append("}")
B.append("void glNewList(unsigned int list, unsigned int mode)")
B.append("{")
B.append("    double t0 = 0;")
B.append("    st_init();")
B.append("    resolve_glNewList();")
B.append("    if (g_on) { n_newl++; t0 = now_ms(); }")
B.append("    if (real_glNewList) real_glNewList(list, mode);")
B.append("    if (g_on) us_newl += (now_ms() - t0) * 1000.0;")
B.append("}")
B.append("void glEndList(void)")
B.append("{")
B.append("    double t0 = 0;")
B.append("    st_init();")
B.append("    resolve_glEndList();")
B.append("    if (g_on) { t0 = now_ms(); }")
B.append("    if (real_glEndList) real_glEndList();")
B.append("    if (g_on) us_newl += (now_ms() - t0) * 1000.0;")
B.append("}")
R = []
R.append("    /* TSP_LISTWRAP_V2 - move list time out of other_us and emit an L line.")
R.append("       No ms= key on the L line, so the existing S-line readers skip it. */")
R.append("    sum += us_list + us_newl;")
R.append("    other = frame_us - sum;")
R.append("    if (g_out && g_frame < g_max)")
R.append("        fprintf(g_out, \"L f=%lu d=%lu lms=%.2f list_us=%.0f lists=%lu new_us=%.0f news=%lu oth_us=%.0f\\n\",")
R.append("                g_frame, n_draw, frame_us / 1000.0, us_list, n_list, us_newl, n_newl, other);")
R.append("    us_list = 0.0;")
R.append("    us_newl = 0.0;")
R.append("    n_list = 0;")
R.append("    n_newl = 0;")
out = list(lines)
out[io[0]] = "\n".join(R)
out.insert(iw[0] + 1, "\n".join(B))
res = "\n".join(out)
if res.count("{") != res.count("}"):
    print("BRACE IMBALANCE - NOTHING WRITTEN: " + str(res.count("{")) + " vs " + str(res.count("}")))
    sys.exit(1)
for frag in ("void glCallList(unsigned int list)", "sum += us_list + us_newl;", "other = frame_us - sum;", "d=%lu lms=", MARK):
    if frag not in res:
        print("REQUIRED FRAGMENT MISSING (" + frag + ") - NOTHING WRITTEN")
        sys.exit(1)
if res.count("other = frame_us - sum;") != 1:
    print("REPORT SITE DUPLICATED - NOTHING WRITTEN")
    sys.exit(1)
if res.count("L f=%lu d=%lu") != 1:
    print("L LINE COUNT WRONG - NOTHING WRITTEN")
    sys.exit(1)
if cur == res:
    print("ALREADY CONVERGED: " + P + " is exactly the V2 result. Nothing written.")
    sys.exit(0)
if not baks:
    bp = P + ".before-listwrap2-" + STAMP
    open(bp, "w", encoding="utf-8").write(cur)
    if rd(bp) != cur:
        print("GATE FAIL: backup readback mismatch at " + bp + " - NOTHING WRITTEN to " + P)
        sys.exit(1)
    print("  backup  : " + bp)
elif cur != src:
    pw = P + ".prewrite-listwrap2-" + STAMP
    open(pw, "w", encoding="utf-8").write(cur)
    print("  note    : current file differed from pristine (old V1 patch?); saved aside as " + pw)
open(P, "w", encoding="utf-8").write(res)
print("PATCH APPLIED: " + MARK + " (" + note + ")")
print("  file    : " + P)
print("  lines   : " + str(len(lines)) + " -> " + str(len(res.split("\n"))))
print("  wrappers inserted after line " + str(iw[0] + 1) + " (the WRAPC define)")
print("  report site at former line " + str(io[0] + 1))
