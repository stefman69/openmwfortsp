#!/usr/bin/env python3
"""
TSP_MANAGER_V31_FULL - brings a V2.9+v30 controller straight to the final state.

Collapses what were four separate patches (v30b status/version, v30c selftest rename,
v30d layout, v31 two size bands) into one pass that writes the intended end state
rather than replaying intermediate steps. Run it on the .before-v30b backup, which is
V2.9 plus the v30 texconv patch.

Result: the controller matches the device, so a future `install` carries everything
instead of reverting the small-texture band.

  python3 tsp_mgr_v31_full.py <controller.sh>
"""

import os
import shutil
import sys
import time

STAMP = time.strftime("%Y%m%d-%H%M%S")

# ------------------------------------------------------------- the new backend

TIERS_VAR = ('TEXCONV_MARK="$TEXCONV_DATA/tsp_texconv.done"',
             'TEXCONV_MARK="$TEXCONV_DATA/tsp_texconv.done"\nTEXCONV_TIERS="8x8+6x6"')

CONVERT_OLD_START = '''convert_textures() {
    local done_file rc snapshot pct phase detail pct2 phase2 detail2
    local before after fp args_ok=0'''

CONVERT_OLD_END = '''    progress "TEXTURE CONVERSION STOPPED" 100 "$after files done"
    say "ERROR texture conversion stopped early (exit $rc) after $after of the textures; run it again to carry on from there"
    return "$rc"
}'''

CONVERT_NEW = r'''# One pass of the converter over a size band. The tool skips any .ktx that already
# exists, so a pass is resumable and a second run over a done band costs seconds.
#
# Each pass writes its own log and only that log is parsed for progress. Sharing one
# log would leave the previous band's "done" line inside the parser's tail window,
# which pins the bar at 100% for most of the next band. The pass log is folded into
# the main log when the pass ends, so completion accounting still sees both bands.
texconv_run_pass() {
    local label="$1" tmin="$2" tmax="$3" block="$4"
    local done_file passlog rc snapshot pct phase detail pct2 phase2 detail2 f
    done_file="$PROGRESS_FILE.tex.$$"
    passlog="$TEXCONV_LOG.pass"
    rm -f "$done_file"
    : > "$passlog" 2>/dev/null || true
    progress "$label" 0 "reading the game archives"
    (
        trap - ERR
        set +e
        # Build the archive arguments by appending to the positional parameters. The
        # paths contain a space ("Data Files"), so they must never go through word
        # splitting; an earlier version packed them into one string and split on "|",
        # which produced a leading-space " --bsa" and made the tool exit 2 on every
        # run before converting anything.
        set --
        for f in Morrowind.bsa Tribunal.bsa Bloodmoon.bsa; do
            [ -f "$TEXCONV_DATA/$f" ] && set -- "$@" --bsa "$TEXCONV_DATA/$f"
        done
        rc=0
        "$TEXCONV_TOOL" "$@" --out "$TEXCONV_DATA" --threads 4 --report-every 25 \
            --min-size "$tmin" --max-size "$tmax" --block "$block" >> "$passlog" 2>&1 || rc=$?
        printf '%s\n' "$rc" > "$done_file"
    ) &
    while [ ! -s "$done_file" ]; do
        snapshot="$(texconv_progress_snapshot "$passlog")"
        IFS='|' read -r pct phase detail pct2 phase2 detail2 <<TEXCONV_EOF
$snapshot
TEXCONV_EOF
        case "$pct" in ''|*[!0-9-]*) pct=-1 ;; esac
        progress "${label}" "$pct" "$detail" "" -1 ""
        sleep "$SLEEP_TICK"
    done
    read -r rc < "$done_file"
    rm -f "$done_file"
    wait 2>/dev/null || true
    cat "$passlog" >> "$TEXCONV_LOG" 2>/dev/null || true
    rm -f "$passlog"
    case "$rc" in ''|*[!0-9]*) rc=1 ;; esac
    return "$rc"
}

convert_textures() {
    local rc1 rc2 before after fp failed reason
    [ -f "$TEXCONV_TOOL" ] || { say "ERROR the texture converter is missing: $TEXCONV_TOOL"; return 80; }
    [ -d "$TEXCONV_DATA" ] || { say "ERROR the game data folder was not found: $TEXCONV_DATA"; return 81; }

    fp="$(texconv_fingerprint)"
    [ -n "$fp" ] || { say "ERROR no game archives found in $TEXCONV_DATA"; return 82; }
    before="$(texconv_count)"

    # Both bands done for this game data: nothing to do. A marker without the tiers
    # line was written before the small-texture band existed, so it does not count.
    if [ -f "$TEXCONV_MARK" ] \
       && grep -Fqx "fingerprint=$fp" "$TEXCONV_MARK" 2>/dev/null \
       && grep -Fqx "tiers=$TEXCONV_TIERS" "$TEXCONV_MARK" 2>/dev/null; then
        progress "TEXTURES ALREADY CONVERTED" 100 "$before files"
        say "Textures are already converted for this game data ($before files); nothing to do"
        return 0
    fi

    say "Converting textures to ASTC. Two size bands, resumable, about an hour from scratch."
    : > "$TEXCONV_LOG" 2>/dev/null || true

    # Band 1: 128 px and larger at 8x8 (2 bpp). This is where the memory is.
    STEPS=2
    STEP=1
    texconv_run_pass "CONVERTING LARGE TEXTURES" 128 0 8x8
    rc1=$?

    # Band 2: everything smaller at 6x6 (~3.6-4.8 bpp), which is about what their DXT1
    # source already costs, so no meaningful quality change and no CPU decompress.
    STEP=2
    texconv_run_pass "CONVERTING SMALL TEXTURES" 0 127 6x6
    rc2=$?

    STEP=0
    STEPS=0
    after="$(texconv_count)"

    # Completed work: the tool returns 1 when individual textures failed but the run
    # finished. Only a band with no completion line is genuinely incomplete, and
    # re-running resumes because existing .ktx files are skipped.
    if [ "$(grep -c '^TSP_TEXCONV_V1 done' "$TEXCONV_LOG" 2>/dev/null || printf '0')" -ge 2 ]; then
        failed="$(sed -n 's/^TSP_TEXCONV_V1 done .*fail=\([0-9]*\).*/\1/p' "$TEXCONV_LOG" \
            | awk '{t+=$1} END {print t+0}')"
        case "$failed" in ''|*[!0-9]*) failed=0 ;; esac
        # The converter rewrites this marker per pass, so its own converted= counts only
        # the last band, and counts nothing at all on a resumed pass that skipped
        # everything. The home page reads converted=, so state the real number of .ktx
        # files on disk instead.
        grep -v -e '^tiers=' -e '^converted=' -e '^fingerprint=' "$TEXCONV_MARK" \
            2>/dev/null > "$TEXCONV_MARK.tmp" || true
        printf 'converted=%s\nfingerprint=%s\ntiers=%s\n' \
            "$after" "$fp" "$TEXCONV_TIERS" >> "$TEXCONV_MARK.tmp"
        mv -f "$TEXCONV_MARK.tmp" "$TEXCONV_MARK" 2>/dev/null || true
        progress "TEXTURE CONVERSION COMPLETE" 100 "$after files"
        if [ "$failed" -gt 0 ]; then
            say "Texture conversion finished: $after textures converted, $failed could not be read and were left as they were"
        else
            say "Texture conversion finished: $after textures converted"
        fi
        return 0
    fi

    # Surface the converter's own reason. Exit 2 is always an argument or archive
    # problem and it says which on its first line, so quote it rather than making
    # the next person pull the log.
    reason="$(grep -m1 '^TSP_TEXCONV_V1 fatal' "$TEXCONV_LOG" 2>/dev/null \
        | sed 's/^TSP_TEXCONV_V1 fatal //')"
    progress "TEXTURE CONVERSION STOPPED" 100 "$after files done"
    if [ -n "$reason" ]; then
        say "ERROR texture conversion stopped early (large band $rc1, small band $rc2) after $after textures: $reason"
    else
        say "ERROR texture conversion stopped early (large band $rc1, small band $rc2) after $after textures; run it again to carry on from there"
    fi
    return 1
}'''

# --------------------------------------------------- mandatory anchored edits

EDITS = [
    # --- C++: the version leaves the header entirely (v30b bump + v30d removal, merged)
    ("cpp-header",
     'label(f,"TRIMUI SMART PRO MANAGER",270,25,2,FG);label(f,"INTEGRATED V2.8",1010,25,2,DIM);',
     'label(f,"TRIMUI SMART PRO MANAGER",270,25,2,FG);'),
    # --- C++: and reappears on the diagnostics page, in a rendered expression so -O2
    #         cannot discard the literal the installer's own test greps for
    ("cpp-diag-version",
     'title(f,"DIAGNOSTICS","EXACT PATHS AND READINESS");',
     'title(f,"DIAGNOSTICS","EXACT PATHS AND READINESS   INTEGRATED V3.0");'),
    # --- C++: five setup items must fit where four did; the status rows start at y=405
    ("cpp-setup-spacing",
     'for(int i=0;i<5;++i){int y=198+i*50;if(a.opt==i)f.rect(370,y-13,840,42,P2);label(f,a.opt==i?">":" ",386,y,2,a.opt==i?ACC:DIM);label(f,n[i],414,y,2,a.opt==i?FG:DIM);}',
     'for(int i=0;i<5;++i){int y=198+i*38;if(a.opt==i)f.rect(370,y-11,840,36,P2);label(f,a.opt==i?">":" ",386,y,2,a.opt==i?ACC:DIM);label(f,n[i],414,y,2,a.opt==i?FG:DIM);}'),
    # --- C++: the converter's own marker becomes status keys, so the home page needs
    #         nothing new from the Python backend
    ("cpp-refresh-marker",
     "static void refresh(App&a){a.status=readKv(a.statusFile);",
     "static void refresh(App&a){a.status=readKv(a.statusFile);\n"
     "    // TSP_MANAGER_V30_TEXCONV: read the converter's own marker and expose it as status\n"
     "    // keys, so the home page needs nothing new from the Python backend.\n"
     "    {auto tk=readKv(a.root/\"data\"/\"Data Files\"/\"tsp_texconv.done\");\n"
     "     if(tk.empty())a.status[\"textures_state\"]=\"NOT CONVERTED\";\n"
     "     else{a.status[\"textures_state\"]=tk.count(\"fingerprint\")?\"CONVERTED\":\"PARTIAL\";\n"
     "          if(tk.count(\"converted\"))a.status[\"textures_count\"]=tk[\"converted\"];}}\n"
     "    "),
    # --- C++: taller status panel, the new row, and LAST ACTION moved down under it
    ("cpp-home-panel",
     'nav(f,a);title(f,"PORT STATUS","REAL INSTALL, MOD ORDER, NAVMESH AND SWAP CONTROL");f.rect(350,180,902,298,P1);',
     'nav(f,a);title(f,"PORT STATUS","REAL INSTALL, MOD ORDER, NAVMESH AND SWAP CONTROL");f.rect(350,180,902,338,P1);'),
    ("cpp-home-row",
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
     "    }"),
    ("cpp-home-lastaction",
     'f.rect(350,490,902,98,P1);label(f,"LAST ACTION",380,508,2,ACC);label(f,fit(a.lastResult.empty()?"READY":a.lastResult,104),380,542,1,FG);label(f,"PLAY CHECKS THE CONTENT LIST AND THE NAVMESH PROFILE FIRST.",380,566,1,DIM);',
     'f.rect(350,530,902,98,P1);label(f,"LAST ACTION",380,548,2,ACC);label(f,fit(a.lastResult.empty()?"READY":a.lastResult,104),380,582,1,FG);label(f,"PLAY CHECKS THE CONTENT LIST AND THE NAVMESH PROFILE FIRST.",380,606,1,DIM);'),
    # --- backend: rate and ETA through the progress detail
    ("act-awk-capture",
     "                if ($i ~ /^pct=/)   pct   = substr($i, 5)\n"
     "            }\n"
     "        }",
     "                if ($i ~ /^pct=/)   pct   = substr($i, 5)\n"
     "                if ($i ~ /^rate=/)  rate  = substr($i, 6)\n"
     "                if ($i ~ /^eta=/)   eta   = substr($i, 5)\n"
     "            }\n"
     "        }"),
    ("act-awk-detail",
     '            if (done != "" && total != "") detail = done " / " total " textures"\n'
     '            if (ok != "") {\n'
     '                detail = detail "   converted " ok\n'
     '                if (fail != "" && fail + 0 > 0) detail = detail "  failed " fail\n'
     "            }",
     '            if (done != "" && total != "") detail = done " / " total\n'
     '            if (ok != "") detail = detail "  OK " ok\n'
     '            if (fail != "" && fail + 0 > 0) detail = detail "  FAIL " fail\n'
     '            if (rate != "") detail = detail "  " rate "/S"\n'
     '            if (eta != "" && eta + 0 > 0) detail = detail "  ETA " int((eta + 59) / 60) " MIN"'),
    # --- backend: the selftest expectations move with the detail format
    ("act-selftest-progress",
     "    printf '%s\\n' 'TSP_TEXCONV_V1 progress done=1200 total=4555 ok=1000 small=200 fail=0 pct=26' >> \"$texlog\"\n"
     '    tsnap="$(texconv_progress_snapshot "$texlog")"\n'
     '    [ "$tsnap" = "26|CONVERTING TEXTURES|1200 / 4555 textures   converted 1000|-1||" ] \\\n'
     '        || { echo "FAIL texconv progress: $tsnap"; return 98; }',
     "    printf '%s\\n' 'TSP_TEXCONV_V1 progress done=1200 total=4555 ok=1000 small=200 fail=0 pct=26 rate=1.80 eta=1863' >> \"$texlog\"\n"
     '    tsnap="$(texconv_progress_snapshot "$texlog")"\n'
     '    [ "$tsnap" = "26|CONVERTING TEXTURES|1200 / 4555  OK 1000  1.80/S  ETA 32 MIN|-1||" ] \\\n'
     '        || { echo "FAIL texconv progress: $tsnap"; return 98; }'),
    ("act-selftest-failcount",
     "    printf '%s\\n' 'TSP_TEXCONV_V1 progress done=2400 total=4555 ok=2000 small=397 fail=3 pct=52' >> \"$texlog\"\n"
     '    tsnap="$(texconv_progress_snapshot "$texlog")"\n'
     '    [ "$tsnap" = "52|CONVERTING TEXTURES|2400 / 4555 textures   converted 2000  failed 3|-1||" ] \\\n'
     '        || { echo "FAIL texconv failure count: $tsnap"; return 98; }',
     "    printf '%s\\n' 'TSP_TEXCONV_V1 progress done=2400 total=4555 ok=2000 small=397 fail=3 pct=52 rate=2.00 eta=1077' >> \"$texlog\"\n"
     '    tsnap="$(texconv_progress_snapshot "$texlog")"\n'
     '    [ "$tsnap" = "52|CONVERTING TEXTURES|2400 / 4555  OK 2000  FAIL 3  2.00/S  ETA 18 MIN|-1||" ] \\\n'
     '        || { echo "FAIL texconv failure count: $tsnap"; return 98; }'),
]

# Applied where present. The controller's own host test and diagnostics grep name the
# version marker; both must follow it to V3.0. A simulated controller has neither.
OPTIONAL = [
    ("ctl-selftest-marker", "INTEGRATED V2.8", "INTEGRATED V3.0"),
    ("ctl-selftest-message", "V2.8 UI marker", "V3.0 UI marker"),
    ("ctl-diag-grep", "grep -F 'INTEGRATED V2'", "grep -F 'INTEGRATED V'"),
]

INVARIANTS = [
    ("header carries no version", lambda t: 'label(f,"INTEGRATED V2.8",1010,25,2,DIM)' not in t
                                            and 'label(f,"INTEGRATED V3.0",1010,25,2,DIM)' not in t),
    ("version on diagnostics", lambda t: t.count("EXACT PATHS AND READINESS   INTEGRATED V3.0") == 1),
    ("marker literal survives", lambda t: t.count("INTEGRATED V3.0") >= 1),
    ("no V2.8 marker anywhere", lambda t: "INTEGRATED V2.8" not in t),
    ("setup menu is 38px", lambda t: t.count("int y=198+i*38") == 1 and "int y=198+i*50" not in t),
    ("textures row present", lambda t: t.count('"ASTC TEXTURES"') == 1),
    ("marker read in refresh", lambda t: t.count("tsp_texconv.done") >= 1),
    ("status panel taller", lambda t: t.count("f.rect(350,180,902,338,P1)") == 1),
    ("last action moved", lambda t: t.count("f.rect(350,530,902,98,P1)") == 1
                                    and "f.rect(350,490,902,98,P1)" not in t),
    ("awk captures rate and eta", lambda t: t.count("if ($i ~ /^rate=/)") == 1
                                            and t.count("if ($i ~ /^eta=/)") == 1),
    ("detail carries ETA", lambda t: t.count('" MIN"') == 1),
    ("two-band runner", lambda t: t.count("texconv_run_pass() {") == 1),
    ("large band wired", lambda t: t.count('texconv_run_pass "CONVERTING LARGE TEXTURES" 128 0 8x8') == 1),
    ("small band wired", lambda t: t.count('texconv_run_pass "CONVERTING SMALL TEXTURES" 0 127 6x6') == 1),
    ("tiers constant", lambda t: t.count('TEXCONV_TIERS="8x8+6x6"') == 1),
    ("tiers gates the early return", lambda t: t.count('grep -Fqx "tiers=$TEXCONV_TIERS"') == 1),
    ("old single-pass body gone", lambda t: "args_ok=0" not in t),
    ("each band logs separately", lambda t: t.count('passlog="$TEXCONV_LOG.pass"') == 1
                                            and t.count('texconv_progress_snapshot "$passlog"') == 1
                                            and t.count('cat "$passlog" >> "$TEXCONV_LOG"') == 1),
    ("count comes from disk", lambda t: t.count("printf 'converted=%s\\nfingerprint=%s\\ntiers=%s\\n'") == 1),
    ("failure names the reason", lambda t: t.count("grep -m1 '^TSP_TEXCONV_V1 fatal'") == 1),
    ("archive args are quoted", lambda t: t.count('set -- "$@" --bsa "$TEXCONV_DATA/$f"') == 1
                                          and 'tex_args' not in t),
    ("missing tool still returns 80", lambda t: t.count("return 80") == 1),
    ("texconv menu entry intact", lambda t: t.count("CONVERT TEXTURES FOR LOW MEMORY") == 1),
    ("dispatch case intact", lambda t: t.count("convert-textures) convert_textures ;;") == 1),
    ("progress-backend marker kept", lambda t: "TSP_MANAGER_V24_PROGRESS_BACKEND" in t),
]


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    if not os.path.isfile(path):
        print("FAIL not found: " + path)
        return 1
    text = open(path, encoding="utf-8").read()

    if "convert-textures) convert_textures" not in text:
        print("FAIL this controller does not have the v30 texconv patch; use the .before-v30b backup")
        return 1
    if "TEXCONV_TIERS" in text:
        print("ALREADY PATCHED - nothing done: " + path)
        return 2

    bak = path + ".before-v31full-" + STAMP
    shutil.copy2(path, bak)
    if open(bak, "rb").read() != open(path, "rb").read():
        print("FAIL backup does not match the original")
        return 1
    print("=== verified backup ===")
    print("      %s  %d bytes" % (bak, os.path.getsize(bak)))

    print("=== mandatory anchors ===")
    ok = True
    for label, anchor, replacement in EDITS:
        n = text.count(anchor)
        print("      %-4s %-24s matches=%d" % ("OK" if n == 1 else "FAIL", label, n))
        if n != 1:
            ok = False
            continue
        text = text.replace(anchor, replacement, 1)

    print("=== two size bands ===")
    n = text.count(TIERS_VAR[0])
    print("      %-4s %-24s matches=%d" % ("OK" if n == 1 else "FAIL", "act-tiers-var", n))
    if n != 1:
        ok = False
    else:
        text = text.replace(TIERS_VAR[0], TIERS_VAR[1], 1)

    start = text.find(CONVERT_OLD_START)
    end = text.find(CONVERT_OLD_END)
    good = start >= 0 and end > start
    print("      %-4s %-24s" % ("OK" if good else "FAIL", "act-convert-textures"))
    if not good:
        ok = False
    else:
        text = text[:start] + CONVERT_NEW + text[end + len(CONVERT_OLD_END):]

    print("=== optional (controller-only sites) ===")
    for label, anchor, replacement in OPTIONAL:
        n = text.count(anchor)
        if n:
            text = text.replace(anchor, replacement)
            print("      OK   %-24s rewritten %d" % (label, n))
        else:
            print("      SKIP %-24s not present" % label)

    if not ok:
        print("=== NO WRITE - an anchor did not match exactly once; file untouched ===")
        return 1

    print("=== invariants ===")
    bad = False
    for label, test in INVARIANTS:
        g = test(text)
        print("      %-4s %s" % ("OK" if g else "FAIL", label))
        bad = bad or not g
    if bad:
        print("=== INVARIANT FAILED - file untouched ===")
        return 1

    open(path, "w", encoding="utf-8").write(text)
    print("=== PATCH OK === run the controller's selftest, then install")
    return 0


if __name__ == "__main__":
    sys.exit(main())
