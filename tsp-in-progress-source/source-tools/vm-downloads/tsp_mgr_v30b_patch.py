#!/usr/bin/env python3
# TSP_MANAGER_V30B_STATUS - applies ON TOP of the v30 texconv patch.
#
# Three things v30 left out:
#   1. the header still said INTEGRATED V2.8, so an install was invisible;
#   2. the home page said nothing about whether textures had been converted;
#   3. the progress detail carried no rate or ETA, so an hour-long job looked
#      identical whether it was moving or wedged.
#
# The textures row is fed from the converter's own marker file, folded into the
# status map inside refresh(). No new Python status key, so the Python backend is
# not touched at all.
import os
import shutil
import sys
import time

CONTROLLER = os.environ.get("TSP_MGR_CONTROLLER", "")
SRC = os.environ.get("TSP_MGR_SRC", ".")
STAMP = time.strftime("%Y%m%d-%H%M%S")

CPP = "openmw_launcher_manager.cpp"
ACT = "openmw_manager_action.sh"

EDITS = [
    # ---------------------------------------------------------------- 1. version
    (
        "header-version",
        CPP,
        'label(f,"INTEGRATED V2.8",1010,25,2,DIM);',
        'label(f,"INTEGRATED V3.0",1010,25,2,DIM);',
    ),
    # -------------------------------------------- 2. marker folded into refresh()
    (
        "refresh-marker",
        CPP,
        "static void refresh(App&a){a.status=readKv(a.statusFile);",
        "static void refresh(App&a){a.status=readKv(a.statusFile);\n"
        "    // TSP_MANAGER_V30_TEXCONV: read the converter's own marker and expose it as status\n"
        "    // keys, so the home page needs nothing new from the Python backend.\n"
        "    {auto tk=readKv(a.root/\"data\"/\"Data Files\"/\"tsp_texconv.done\");\n"
        "     if(tk.empty())a.status[\"textures_state\"]=\"NOT CONVERTED\";\n"
        "     else{a.status[\"textures_state\"]=tk.count(\"fingerprint\")?\"CONVERTED\":\"PARTIAL\";\n"
        "          if(tk.count(\"converted\"))a.status[\"textures_count\"]=tk[\"converted\"];}}\n"
        "    ",
    ),
    # ------------------------------------------------- 3. taller status panel
    (
        "home-panel",
        CPP,
        'nav(f,a);title(f,"PORT STATUS","REAL INSTALL, MOD ORDER, NAVMESH AND SWAP CONTROL");f.rect(350,180,902,298,P1);',
        'nav(f,a);title(f,"PORT STATUS","REAL INSTALL, MOD ORDER, NAVMESH AND SWAP CONTROL");f.rect(350,180,902,338,P1);',
    ),
    # ------------------------------------------------------- 4. the textures row
    (
        "home-row",
        CPP,
        '        std::string content=val(a,"content_status","NOT SCANNED");\n'
        '        row(f,380,445,"CONFIG CONTENT",content,content=="VALID"?GOOD:(content=="NOT SCANNED"?DIM:BAD));\n'
        "    }",
        '        std::string content=val(a,"content_status","NOT SCANNED");\n'
        '        row(f,380,445,"CONFIG CONTENT",content,content=="VALID"?GOOD:(content=="NOT SCANNED"?DIM:BAD));\n'
        "    }\n"
        "    {\n"
        "        // TSP_MANAGER_V30_TEXCONV\n"
        '        std::string ts=val(a,"textures_state","NOT CONVERTED"),tc=val(a,"textures_count","");\n'
        '        row(f,380,485,"ASTC TEXTURES",ts=="CONVERTED"&&!tc.empty()?ts+" ("+tc+")":ts,\n'
        '            ts=="CONVERTED"?GOOD:(ts=="PARTIAL"?WARN:DIM));\n'
        "    }",
    ),
    # ------------------------------- 5. LAST ACTION moves down under the new row
    (
        "home-lastaction",
        CPP,
        'f.rect(350,490,902,98,P1);label(f,"LAST ACTION",380,508,2,ACC);label(f,fit(a.lastResult.empty()?"READY":a.lastResult,104),380,542,1,FG);label(f,"PLAY CHECKS THE CONTENT LIST AND THE NAVMESH PROFILE FIRST.",380,566,1,DIM);',
        'f.rect(350,530,902,98,P1);label(f,"LAST ACTION",380,548,2,ACC);label(f,fit(a.lastResult.empty()?"READY":a.lastResult,104),380,582,1,FG);label(f,"PLAY CHECKS THE CONTENT LIST AND THE NAVMESH PROFILE FIRST.",380,606,1,DIM);',
    ),
    # ------------------------------------- 6. rate and ETA in the progress detail
    (
        "awk-capture",
        ACT,
        "                if ($i ~ /^pct=/)   pct   = substr($i, 5)\n"
        "            }\n"
        "        }",
        "                if ($i ~ /^pct=/)   pct   = substr($i, 5)\n"
        "                if ($i ~ /^rate=/)  rate  = substr($i, 6)\n"
        "                if ($i ~ /^eta=/)   eta   = substr($i, 5)\n"
        "            }\n"
        "        }",
    ),
    (
        "awk-detail",
        ACT,
        '            if (done != "" && total != "") detail = done " / " total " textures"\n'
        '            if (ok != "") {\n'
        '                detail = detail "   converted " ok\n'
        '                if (fail != "" && fail + 0 > 0) detail = detail "  failed " fail\n'
        "            }",
        '            if (done != "" && total != "") detail = done " / " total\n'
        '            if (ok != "") detail = detail "  OK " ok\n'
        '            if (fail != "" && fail + 0 > 0) detail = detail "  FAIL " fail\n'
        '            if (rate != "") detail = detail "  " rate "/S"\n'
        '            if (eta != "" && eta + 0 > 0) detail = detail "  ETA " int((eta + 59) / 60) " MIN"',
    ),
    # ------------------------- 7. the selftest expectations move with the format
    (
        "selftest-progress",
        ACT,
        "    printf '%s\\n' 'TSP_TEXCONV_V1 progress done=1200 total=4555 ok=1000 small=200 fail=0 pct=26' >> \"$texlog\"\n"
        '    tsnap="$(texconv_progress_snapshot "$texlog")"\n'
        '    [ "$tsnap" = "26|CONVERTING TEXTURES|1200 / 4555 textures   converted 1000|-1||" ] \\\n'
        '        || { echo "FAIL texconv progress: $tsnap"; return 98; }',
        "    printf '%s\\n' 'TSP_TEXCONV_V1 progress done=1200 total=4555 ok=1000 small=200 fail=0 pct=26 rate=1.80 eta=1863' >> \"$texlog\"\n"
        '    tsnap="$(texconv_progress_snapshot "$texlog")"\n'
        '    [ "$tsnap" = "26|CONVERTING TEXTURES|1200 / 4555  OK 1000  1.80/S  ETA 32 MIN|-1||" ] \\\n'
        '        || { echo "FAIL texconv progress: $tsnap"; return 98; }',
    ),
    (
        "selftest-failcount",
        ACT,
        "    printf '%s\\n' 'TSP_TEXCONV_V1 progress done=2400 total=4555 ok=2000 small=397 fail=3 pct=52' >> \"$texlog\"\n"
        '    tsnap="$(texconv_progress_snapshot "$texlog")"\n'
        '    [ "$tsnap" = "52|CONVERTING TEXTURES|2400 / 4555 textures   converted 2000  failed 3|-1||" ] \\\n'
        '        || { echo "FAIL texconv failure count: $tsnap"; return 98; }',
        "    printf '%s\\n' 'TSP_TEXCONV_V1 progress done=2400 total=4555 ok=2000 small=397 fail=3 pct=52 rate=2.00 eta=1077' >> \"$texlog\"\n"
        '    tsnap="$(texconv_progress_snapshot "$texlog")"\n'
        '    [ "$tsnap" = "52|CONVERTING TEXTURES|2400 / 4555  OK 2000  FAIL 3  2.00/S  ETA 18 MIN|-1||" ] \\\n'
        '        || { echo "FAIL texconv failure count: $tsnap"; return 98; }',
    ),
]

# Optional: the diagnostics grep looks for the literal 'INTEGRATED V2'. Widen it so it
# still matches after the bump. Applied only if present; it is a `|| true` grep.
OPTIONAL = [
    ("diag-grep", None, "grep -F 'INTEGRATED V2'", "grep -F 'INTEGRATED V'"),
]

INVARIANTS = [
    ("header says V3.0", lambda t: t.count('"INTEGRATED V3.0"') == 1),
    ("no V2.8 label left", lambda t: '"INTEGRATED V2.8"' not in t),
    ("textures row present", lambda t: t.count('"ASTC TEXTURES"') == 1),
    ("marker read in refresh", lambda t: t.count("tsp_texconv.done") >= 1),
    ("status panel is taller", lambda t: t.count("f.rect(350,180,902,338,P1)") == 1),
    ("last action moved", lambda t: t.count("f.rect(350,530,902,98,P1)") == 1),
    ("no stale last-action rect", lambda t: "f.rect(350,490,902,98,P1)" not in t),
    ("awk captures rate", lambda t: t.count("if ($i ~ /^rate=/)") == 1),
    ("awk captures eta", lambda t: t.count("if ($i ~ /^eta=/)") == 1),
    ("detail carries ETA", lambda t: t.count('" MIN"') == 1),
    ("progress-backend marker kept", lambda t: "TSP_MANAGER_V24_PROGRESS_BACKEND" in t),
]


def apply_edits(text, label_filter=None):
    ok = True
    for label, _f, anchor, replacement in EDITS:
        if label_filter and not label_filter(label):
            continue
        n = text.count(anchor)
        print("      %-4s %-20s matches=%d" % ("OK" if n == 1 else "FAIL", label, n))
        if n != 1:
            ok = False
            continue
        text = text.replace(anchor, replacement, 1)
    for label, _f, anchor, replacement in OPTIONAL:
        n = text.count(anchor)
        if n:
            text = text.replace(anchor, replacement)
            print("      OK   %-20s rewritten %d time(s)" % (label, n))
        else:
            print("      SKIP %-20s not present (harmless)" % label)
    return text, ok


def main():
    if not CONTROLLER:
        # split-file mode, for testing against the emitted sources
        out = 0
        for name in (CPP, ACT):
            path = os.path.join(SRC, name)
            if not os.path.isfile(path):
                print("FAIL missing " + path)
                return 1
        text = {}
        for name in (CPP, ACT):
            with open(os.path.join(SRC, name), "r", encoding="utf-8") as fh:
                text[name] = fh.read()
        joined = text[CPP] + "\n@@SPLIT@@\n" + text[ACT]
        if "TSP_MANAGER_V30B" in joined or '"INTEGRATED V3.0"' in joined:
            print("ALREADY PATCHED - nothing done")
            return 2
        patched, ok = apply_edits(joined)
        if not ok:
            print("=== NO WRITE ===")
            return 1
        print("=== invariants ===")
        for label, test in INVARIANTS:
            good = test(patched)
            print("      %-4s %s" % ("OK" if good else "FAIL", label))
            if not good:
                out = 1
        if out:
            print("=== INVARIANT FAILED - nothing written ===")
            return 1
        cpp_text, act_text = patched.split("\n@@SPLIT@@\n", 1)
        for name, body in ((CPP, cpp_text), (ACT, act_text)):
            path = os.path.join(SRC, name)
            shutil.copy2(path, path + ".before-v30b-" + STAMP)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(body)
        print("=== PATCH OK ===")
        return 0

    path = CONTROLLER
    if not os.path.isfile(path):
        print("FAIL controller not found: " + path)
        return 1
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    if "convert-textures" not in text:
        print("FAIL this controller has not had the v30 texconv patch applied yet")
        return 1
    if '"INTEGRATED V3.0"' in text:
        print("ALREADY PATCHED - nothing done: " + path)
        return 2

    bak = path + ".before-v30b-" + STAMP
    shutil.copy2(path, bak)
    with open(bak, "rb") as a, open(path, "rb") as b:
        if a.read() != b.read():
            print("FAIL backup does not match the original")
            return 1
    print("=== verified backup ===")
    print("      %s  %d bytes" % (bak, os.path.getsize(bak)))

    print("=== anchors ===")
    patched, ok = apply_edits(text)
    if not ok:
        print("=== NO WRITE - an anchor did not match exactly once; controller untouched ===")
        return 1
    print("=== invariants ===")
    bad = False
    for label, test in INVARIANTS:
        good = test(patched)
        print("      %-4s %s" % ("OK" if good else "FAIL", label))
        if not good:
            bad = True
    if bad:
        print("=== INVARIANT FAILED - controller untouched ===")
        return 1
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(patched)
    print("=== PATCH OK === run the controller's selftest, then install")
    return 0


if __name__ == "__main__":
    sys.exit(main())
