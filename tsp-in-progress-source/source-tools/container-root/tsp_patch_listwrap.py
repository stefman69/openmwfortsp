import sys
P = "/root/tsp_state.c"
if len(sys.argv) > 1:
    P = sys.argv[1]
MARK = "TSP_LISTWRAP_V1"
src = open(P, encoding="utf-8", errors="replace").read()
if MARK in src:
    print("ALREADY APPLIED: " + MARK + " present. Nothing written.")
    sys.exit(0)
lines = src.split("\n")
iw = [i for i, l in enumerate(lines) if l.startswith("#define WRAPC(")]
io = [i for i, l in enumerate(lines) if l.strip() == "other = frame_us - sum;"]
fail = []
if len(iw) != 1:
    fail.append("anchor '#define WRAPC(' matched " + str(len(iw)) + " lines, want 1")
if len(io) != 1:
    fail.append("anchor 'other = frame_us - sum;' matched " + str(len(io)) + " lines, want 1")
for need in ("static void st_init", "now_ms", "g_on", "g_out", "g_frame", "g_max", "#define REAL("):
    if need not in src:
        fail.append("required symbol/text missing: " + repr(need))
if fail:
    print("ANCHOR FAILURE - NOTHING WRITTEN")
    for f in fail:
        print("  " + f)
    print("--- survey ---")
    for i, l in enumerate(lines, 1):
        if ("#define" in l) or ("frame_us" in l) or ("other" in l and "=" in l) or ("g_max" in l) or ("st_init" in l):
            print("  %4d| %s" % (i, l[:150]))
    sys.exit(1)
BLOCK = []
BLOCK.append("/* TSP_LISTWRAP_V1 - OSG display lists.")
BLOCK.append("   The shim counted 178 glDrawElements per frame while OSG reported ~656 visible")
BLOCK.append("   drawables. The gap is display lists: nifloader.cpp never calls")
BLOCK.append("   setUseDisplayList(false), so every NIF static is submitted through glCallList,")
BLOCK.append("   which nothing here intercepted - so its cost has been sitting inside other_us,")
BLOCK.append("   the 61 ms of an 83 ms frame that has never been attributed.")
BLOCK.append("   glNewList/glEndList are counted separately: if lists are being RECOMPILED every")
BLOCK.append("   frame rather than replayed, news will be non-zero and that is the whole story. */")
BLOCK.append("REAL(glCallList, void, (unsigned int))")
BLOCK.append("REAL(glCallLists, void, (int, unsigned int, const void *))")
BLOCK.append("REAL(glNewList, void, (unsigned int, unsigned int))")
BLOCK.append("REAL(glEndList, void, (void))")
BLOCK.append("static double us_list = 0.0;")
BLOCK.append("static double us_newl = 0.0;")
BLOCK.append("static unsigned long n_list = 0;")
BLOCK.append("static unsigned long n_newl = 0;")
BLOCK.append("void glCallList(unsigned int list)")
BLOCK.append("{")
BLOCK.append("    double t0 = 0;")
BLOCK.append("    st_init();")
BLOCK.append("    resolve_glCallList();")
BLOCK.append("    if (g_on) { n_list++; t0 = now_ms(); }")
BLOCK.append("    if (real_glCallList) real_glCallList(list);")
BLOCK.append("    if (g_on) us_list += (now_ms() - t0) * 1000.0;")
BLOCK.append("}")
BLOCK.append("void glCallLists(int n, unsigned int type, const void *lists)")
BLOCK.append("{")
BLOCK.append("    double t0 = 0;")
BLOCK.append("    st_init();")
BLOCK.append("    resolve_glCallLists();")
BLOCK.append("    if (g_on) { n_list++; t0 = now_ms(); }")
BLOCK.append("    if (real_glCallLists) real_glCallLists(n, type, lists);")
BLOCK.append("    if (g_on) us_list += (now_ms() - t0) * 1000.0;")
BLOCK.append("}")
BLOCK.append("void glNewList(unsigned int list, unsigned int mode)")
BLOCK.append("{")
BLOCK.append("    double t0 = 0;")
BLOCK.append("    st_init();")
BLOCK.append("    resolve_glNewList();")
BLOCK.append("    if (g_on) { n_newl++; t0 = now_ms(); }")
BLOCK.append("    if (real_glNewList) real_glNewList(list, mode);")
BLOCK.append("    if (g_on) us_newl += (now_ms() - t0) * 1000.0;")
BLOCK.append("}")
BLOCK.append("void glEndList(void)")
BLOCK.append("{")
BLOCK.append("    double t0 = 0;")
BLOCK.append("    st_init();")
BLOCK.append("    resolve_glEndList();")
BLOCK.append("    if (g_on) { t0 = now_ms(); }")
BLOCK.append("    if (real_glEndList) real_glEndList();")
BLOCK.append("    if (g_on) us_newl += (now_ms() - t0) * 1000.0;")
BLOCK.append("}")
REPORT = []
REPORT.append("    /* TSP_LISTWRAP_V1 - take list time out of other_us and emit it on its own line.")
REPORT.append("       The L line deliberately does NOT carry ms=, so the existing S-line readers")
REPORT.append("       skip it instead of mistaking it for a frame. */")
REPORT.append("    sum += us_list + us_newl;")
REPORT.append("    other = frame_us - sum;")
REPORT.append("    if (g_out && g_frame < g_max)")
REPORT.append("        fprintf(g_out, \"L f=%lu lms=%.2f list_us=%.0f lists=%lu new_us=%.0f news=%lu oth_us=%.0f\\n\",")
REPORT.append("                g_frame, frame_us / 1000.0, us_list, n_list, us_newl, n_newl, other);")
REPORT.append("    us_list = 0.0;")
REPORT.append("    us_newl = 0.0;")
REPORT.append("    n_list = 0;")
REPORT.append("    n_newl = 0;")
out = list(lines)
out[io[0]] = "\n".join(REPORT)
out.insert(iw[0] + 1, "\n".join(BLOCK))
res = "\n".join(out)
if res.count("{") != res.count("}"):
    print("BRACE IMBALANCE - NOTHING WRITTEN: " + str(res.count("{")) + " vs " + str(res.count("}")))
    sys.exit(1)
for frag in ("void glCallList(unsigned int list)", "sum += us_list + us_newl;", "other = frame_us - sum;", "list_us=%.0f"):
    if frag not in res:
        print("REQUIRED FRAGMENT MISSING (" + frag + ") - NOTHING WRITTEN")
        sys.exit(1)
if res.count("other = frame_us - sum;") != 1:
    print("REPORT SITE DUPLICATED - NOTHING WRITTEN")
    sys.exit(1)
open(P, "w", encoding="utf-8").write(res)
print("PATCH APPLIED: " + MARK)
print("  file    : " + P)
print("  lines   : " + str(len(lines)) + " -> " + str(len(res.split("\n"))))
print("  inserted after line " + str(iw[0] + 1) + " (#define WRAPC)")
print("  report site was line " + str(io[0] + 1))
