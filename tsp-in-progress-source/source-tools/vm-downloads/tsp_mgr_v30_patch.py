#!/usr/bin/env python3
# TSP_MANAGER_V30_TEXCONV patcher.
#
# Adds "CONVERT TEXTURES FOR LOW MEMORY" to the SETUP STORAGE page and a
# convert-textures action that runs tools/tsp_texconv as a child of the live UI,
# publishing progress through the existing V2.4 contract.
#
# Idempotent, transactional, prints every anchor as tried. Writes nothing unless
# every anchor matched exactly once.
import os
import shutil
import sys
import time

SRC = os.environ.get("TSP_MGR_SRC", ".")
# Controller mode: the manager's sources live as heredocs inside the apply_* controller,
# so patching the controller inherits its ARM64 build, device staging, SHA re-verification,
# selftest, collect and rollback instead of reimplementing any of them.
CONTROLLER = os.environ.get("TSP_MGR_CONTROLLER", "")
STAMP = time.strftime("%Y%m%d-%H%M%S")

CPP = "openmw_launcher_manager.cpp"
ACT = "openmw_manager_action.sh"

# --------------------------------------------------------------- action backend

ACT_VARS = r'''TEXCONV_LOG="$ROOT/tsp-texconv.log"
TEXCONV_DATA="$ROOT/data/Data Files"
TEXCONV_TOOL="$ROOT/tools/tsp_texconv"
TEXCONV_MARK="$TEXCONV_DATA/tsp_texconv.done"
'''

ACT_FUNCS = r'''# ---------------------------------------------------------------------------
# TSP_MANAGER_V30_TEXCONV
# One-time conversion of the game's DDS textures to ASTC .ktx, which gl4es
# uploads without a CPU decompress. Measured +87 MB MemAvailable and -62 MB RSS.
# The tool writes new filenames beside the originals, so no config is touched
# and the whole thing is undone by deleting the .ktx files.
# ---------------------------------------------------------------------------

# The archives the conversion was made from. A changed game install must read as
# stale rather than silently keeping textures that no longer match it.
texconv_fingerprint() {
    local f out=""
    for f in Morrowind.bsa Tribunal.bsa Bloodmoon.bsa; do
        if [ -f "$TEXCONV_DATA/$f" ]; then
            out="$out$f:$(stat -c %s "$TEXCONV_DATA/$f" 2>/dev/null || printf '0') "
        fi
    done
    printf '%s' "$out"
}

texconv_count() {
    find "$TEXCONV_DATA/textures" -name '*.ktx' 2>/dev/null | wc -l | tr -d ' '
}

# Turn the tail of the converter log into one "pct|phase|detail|pct2|phase2|detail2"
# line, the same shape build_navmesh uses. Only the tail is read.
texconv_progress_snapshot() {
    tail -n 40 "${1:-/dev/null}" 2>/dev/null | awk '
        /^TSP_TEXCONV_V1 start/ {
            for (i = 1; i <= NF; i++) if ($i ~ /^total=/) total = substr($i, 7)
        }
        /^TSP_TEXCONV_V1 progress/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^done=/)  done  = substr($i, 6)
                if ($i ~ /^total=/) total = substr($i, 7)
                if ($i ~ /^ok=/)    ok    = substr($i, 4)
                if ($i ~ /^fail=/)  fail  = substr($i, 6)
                if ($i ~ /^pct=/)   pct   = substr($i, 5)
            }
        }
        /^TSP_TEXCONV_V1 done/ { finished = 1 }
        END {
            p = -1; phase = "CONVERTING TEXTURES"; detail = ""
            if (pct != "") p = pct + 0
            if (done != "" && total != "") detail = done " / " total " textures"
            if (ok != "") {
                detail = detail "   converted " ok
                if (fail != "" && fail + 0 > 0) detail = detail "  failed " fail
            }
            if (finished) { p = 100; phase = "TEXTURE CONVERSION COMPLETE" }
            printf "%d|%s|%s|-1||\n", p, phase, detail
        }'
}

convert_textures() {
    local done_file rc snapshot pct phase detail pct2 phase2 detail2
    local before after fp args_ok=0
    [ -f "$TEXCONV_TOOL" ] || { say "ERROR the texture converter is missing: $TEXCONV_TOOL"; return 80; }
    [ -d "$TEXCONV_DATA" ] || { say "ERROR the game data folder was not found: $TEXCONV_DATA"; return 81; }

    fp="$(texconv_fingerprint)"
    [ -n "$fp" ] || { say "ERROR no game archives found in $TEXCONV_DATA"; return 82; }
    before="$(texconv_count)"

    # A card converted before this manager version has the textures but no marker.
    # Adopt them instead of spending an hour redoing work that is already done.
    if [ ! -f "$TEXCONV_MARK" ] && [ "${before:-0}" -gt 100 ]; then
        progress "TEXTURES ALREADY CONVERTED" 100 "$before files found"
        printf 'version=TSP_TEXCONV_V1\nadopted=1\nconverted=%s\nfingerprint=%s\n' \
            "$before" "$fp" > "$TEXCONV_MARK" 2>/dev/null || true
        say "Found $before converted textures already in place; recorded them and changed nothing"
        return 0
    fi
    if [ -f "$TEXCONV_MARK" ] && grep -Fqx "fingerprint=$fp" "$TEXCONV_MARK" 2>/dev/null; then
        progress "TEXTURES ALREADY CONVERTED" 100 "$before files"
        say "Textures are already converted for this game data ($before files); nothing to do"
        return 0
    fi

    say "Converting textures to ASTC. This runs once, takes about an hour, and can be resumed."
    progress "STARTING TEXTURE CONVERSION" 0 "reading the game archives"
    : > "$TEXCONV_LOG" 2>/dev/null || true

    done_file="$PROGRESS_FILE.tex.$$"
    rm -f "$done_file"
    # trap - ERR inside the subshell: a non-zero tool status is data here, not a
    # reason to abort, and set -E would otherwise push the parent trap in.
    (
        trap - ERR
        set +e
        tex_args=""
        for f in Morrowind.bsa Tribunal.bsa Bloodmoon.bsa; do
            [ -f "$TEXCONV_DATA/$f" ] && tex_args="$tex_args --bsa|$TEXCONV_DATA/$f"
        done
        old_ifs="$IFS"; IFS='|'
        # shellcheck disable=SC2086
        set -- $tex_args
        IFS="$old_ifs"
        rc=0
        "$TEXCONV_TOOL" "$@" --out "$TEXCONV_DATA" --threads 4 --report-every 25 \
            >> "$TEXCONV_LOG" 2>&1 || rc=$?
        printf '%s\n' "$rc" > "$done_file"
    ) &

    while [ ! -s "$done_file" ]; do
        snapshot="$(texconv_progress_snapshot "$TEXCONV_LOG")"
        IFS='|' read -r pct phase detail pct2 phase2 detail2 <<TEXCONV_EOF
$snapshot
TEXCONV_EOF
        case "$pct" in ''|*[!0-9-]*) pct=-1 ;; esac
        progress "${phase:-CONVERTING TEXTURES}" "$pct" "$detail" "" -1 ""
        sleep "$SLEEP_TICK"
    done

    read -r rc < "$done_file"
    rm -f "$done_file"
    wait 2>/dev/null || true
    case "$rc" in ''|*[!0-9]*) rc=1 ;; esac
    after="$(texconv_count)"

    # Completed work: the tool returns 1 when individual textures failed but the
    # run finished. Only a run with no completion line is genuinely incomplete,
    # and re-running resumes it because existing .ktx files are skipped.
    if grep -q '^TSP_TEXCONV_V1 done' "$TEXCONV_LOG" 2>/dev/null; then
        local failed
        failed="$(sed -n 's/^TSP_TEXCONV_V1 done .*fail=\([0-9]*\).*/\1/p' "$TEXCONV_LOG" | tail -n 1)"
        case "$failed" in ''|*[!0-9]*) failed=0 ;; esac
        printf 'fingerprint=%s\n' "$fp" >> "$TEXCONV_MARK" 2>/dev/null || true
        progress "TEXTURE CONVERSION COMPLETE" 100 "$after files"
        if [ "$failed" -gt 0 ]; then
            say "Texture conversion finished: $after textures converted, $failed could not be read and were left as they were"
        else
            say "Texture conversion finished: $after textures converted"
        fi
        return 0
    fi

    progress "TEXTURE CONVERSION STOPPED" 100 "$after files done"
    say "ERROR texture conversion stopped early (exit $rc) after $after of the textures; run it again to carry on from there"
    return "$rc"
}

'''

ACT_DISPATCH = '    convert-textures) convert_textures ;;\n'

ACT_SELFTEST = r'''    # --- texture converter log -> progress parser ---------------------------
    local texlog="$work/tex.log" tsnap
    printf '%s\n' 'TSP_TEXCONV_V1 archive Morrowind.bsa entries=11090 eligible=3694' > "$texlog"
    tsnap="$(texconv_progress_snapshot "$texlog")"
    [ "$tsnap" = "-1|CONVERTING TEXTURES||-1||" ] || { echo "FAIL texconv idle: $tsnap"; return 98; }

    printf '%s\n' 'TSP_TEXCONV_V1 start total=4555 unique=4555 threads=4 block=8x8 quality=medium out=/x' >> "$texlog"
    printf '%s\n' 'TSP_TEXCONV_V1 progress done=1200 total=4555 ok=1000 small=200 fail=0 pct=26' >> "$texlog"
    tsnap="$(texconv_progress_snapshot "$texlog")"
    [ "$tsnap" = "26|CONVERTING TEXTURES|1200 / 4555 textures   converted 1000|-1||" ] \
        || { echo "FAIL texconv progress: $tsnap"; return 98; }

    printf '%s\n' 'TSP_TEXCONV_V1 progress done=2400 total=4555 ok=2000 small=397 fail=3 pct=52' >> "$texlog"
    tsnap="$(texconv_progress_snapshot "$texlog")"
    [ "$tsnap" = "52|CONVERTING TEXTURES|2400 / 4555 textures   converted 2000  failed 3|-1||" ] \
        || { echo "FAIL texconv failure count: $tsnap"; return 98; }

    printf '%s\n' 'TSP_TEXCONV_V1 done ok=3663 small=892 fail=0 in=145 out=53 secs=2240.0' >> "$texlog"
    tsnap="$(texconv_progress_snapshot "$texlog")"
    case "$tsnap" in
        "100|TEXTURE CONVERSION COMPLETE|"*) : ;;
        *) echo "FAIL texconv completion: $tsnap"; return 98 ;;
    esac

    tsnap="$(texconv_progress_snapshot "$work/no-such-texlog")"
    [ "$tsnap" = "-1|CONVERTING TEXTURES||-1||" ] || { echo "FAIL texconv empty log: $tsnap"; return 98; }

    # The parser output must survive the same field split the run loop uses.
    IFS='|' read -r pct phase detail pct2 phase2 detail2 <<TEXPARSE_EOF
26|CONVERTING TEXTURES|1200 / 4555 textures   converted 1000|-1||
TEXPARSE_EOF
    [ "$pct" = "26" ] && [ "$phase" = "CONVERTING TEXTURES" ] && [ "$pct2" = "-1" ] \
        || { echo "FAIL texconv field split"; return 98; }

    # A missing tool must fail cleanly, not run anything.
    TEXCONV_TOOL="$work/absent-tool" TEXCONV_DATA="$work" convert_textures >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 80 ] || { echo "FAIL missing converter not reported: $rc"; return 98; }

'''

# ------------------------------------------------------------------------ C++

CPP_EDITS = [
    (
        "cpp-setup-labels",
        '    std::array<std::string,4> n={"SETUP GAME FOR FIRST LAUNCH","INSTALL / REPAIR DEFAULT NAVMESH","INSTALL / ACTIVATE DEFAULT SWAP","REFRESH DEVICE STATUS"};',
        '    std::array<std::string,5> n={"SETUP GAME FOR FIRST LAUNCH","INSTALL / REPAIR DEFAULT NAVMESH","INSTALL / ACTIVATE DEFAULT SWAP","CONVERT TEXTURES FOR LOW MEMORY","REFRESH DEVICE STATUS"};',
    ),
    (
        "cpp-setup-loop",
        '    for(int i=0;i<4;++i){int y=198+i*50;if(a.opt==i)f.rect(370,y-13,840,42,P2);label(f,a.opt==i?">":" ",386,y,2,a.opt==i?ACC:DIM);label(f,n[i],414,y,2,a.opt==i?FG:DIM);}',
        '    for(int i=0;i<5;++i){int y=198+i*50;if(a.opt==i)f.rect(370,y-13,840,42,P2);label(f,a.opt==i?">":" ",386,y,2,a.opt==i?ACC:DIM);label(f,n[i],414,y,2,a.opt==i?FG:DIM);}',
    ),
    (
        "cpp-setup-input",
        '    if(a.page==Page::Setup){if(q==Action::Up)a.opt=(a.opt+3)%4;else if(q==Action::Down)a.opt=(a.opt+1)%4;else if(q==Action::Refresh)dispatch(a,"status");else if(q==Action::Select){if(a.opt==0)confirm(a,Page::Setup,"INSTALL THE VERIFIED BASE NAVMESH AND THE UDISK SWAP FILE NOW?","setup-first-launch");else if(a.opt==1)confirm(a,Page::Setup,"REPLACE THE CANONICAL DB WITH THE VERIFIED DEFAULT NAVMESH?","install-navmesh");else if(a.opt==2)confirm(a,Page::Setup,"INSTALL OR ACTIVATE THE CANONICAL UDISK SWAPFILE?","install-swap");else dispatch(a,"status");}}',
        '    if(a.page==Page::Setup){if(q==Action::Up)a.opt=(a.opt+4)%5;else if(q==Action::Down)a.opt=(a.opt+1)%5;else if(q==Action::Refresh)dispatch(a,"status");else if(q==Action::Select){if(a.opt==0)confirm(a,Page::Setup,"INSTALL THE VERIFIED BASE NAVMESH AND THE UDISK SWAP FILE NOW?","setup-first-launch");else if(a.opt==1)confirm(a,Page::Setup,"REPLACE THE CANONICAL DB WITH THE VERIFIED DEFAULT NAVMESH?","install-navmesh");else if(a.opt==2)confirm(a,Page::Setup,"INSTALL OR ACTIVATE THE CANONICAL UDISK SWAPFILE?","install-swap");else if(a.opt==3)confirm(a,Page::Setup,"CONVERT GAME TEXTURES TO ASTC? RUNS ONCE, TAKES ABOUT AN HOUR, CAN BE RESUMED.","convert-textures");else dispatch(a,"status");}}',
    ),
    (
        "cpp-command",
        '    else if(cmd=="setup-first-launch") simple("setup-first-launch","FIRST LAUNCH SETUP: NAVMESH AND SWAP",true);',
        '    else if(cmd=="setup-first-launch") simple("setup-first-launch","FIRST LAUNCH SETUP: NAVMESH AND SWAP",true);\n'
        '    else if(cmd=="convert-textures") simple("convert-textures","CONVERTING TEXTURES FOR LOW MEMORY",true);',
    ),
]

ACT_EDITS = [
    (
        "act-vars",
        'GENLOG="$ROOT/navmesh-generation-full-3worker.log"',
        'GENLOG="$ROOT/navmesh-generation-full-3worker.log"\n' + ACT_VARS.rstrip("\n"),
    ),
    ("act-funcs", "run_selftest() {", ACT_FUNCS + "run_selftest() {"),
    (
        "act-dispatch",
        "    setup-first-launch) setup_first_launch ;;",
        "    setup-first-launch) setup_first_launch ;;\n" + ACT_DISPATCH.rstrip("\n"),
    ),
    (
        "act-selftest",
        '    printf \'%s\\n\' "OPENMW_MANAGER_V24_ACTION_SELFTEST_PASS"',
        ACT_SELFTEST + '    printf \'%s\\n\' "OPENMW_MANAGER_V24_ACTION_SELFTEST_PASS"',
    ),
]


def main():
    if CONTROLLER:
        return patch_controller(CONTROLLER)
    files = {CPP: CPP_EDITS, ACT: ACT_EDITS}
    original = {}
    for name in files:
        path = os.path.join(SRC, name)
        if not os.path.isfile(path):
            print("FAIL  missing source: " + path)
            return 1
        with open(path, "r", encoding="utf-8") as fh:
            original[name] = fh.read()

    already = [n for n in files if "TSP_MANAGER_V30_TEXCONV" in original[n] or "convert-textures" in original[n]]
    if already:
        print("ALREADY PATCHED - nothing done:")
        for n in already:
            print("      " + n)
        return 2

    print("=== backups ===")
    for name in files:
        path = os.path.join(SRC, name)
        bak = path + ".before-v30-" + STAMP
        shutil.copy2(path, bak)
        print("      %s  %d bytes" % (bak, os.path.getsize(bak)))

    print("=== anchors ===")
    patched = dict(original)
    ok = True
    for name, edits in files.items():
        for label, anchor, replacement in edits:
            n = patched[name].count(anchor)
            print("      %-4s %-22s %-30s matches=%d" % ("OK" if n == 1 else "FAIL", label, name, n))
            if n != 1:
                ok = False
                needle = anchor.strip().split("\n")[0][:48]
                for i, line in enumerate(patched[name].split("\n"), 1):
                    if needle[:24] in line:
                        print("        %d: %s" % (i, line[:150]))
                continue
            patched[name] = patched[name].replace(anchor, replacement, 1)

    if not ok:
        print("=== NO FILE WRITTEN - an anchor did not match exactly once ===")
        return 1

    cpp, act = patched[CPP], patched[ACT]
    checks = [
        ("cpp: 5-item setup array", cpp.count("std::array<std::string,5> n=") == 1),
        ("cpp: no %4 left on the setup page", "(a.opt+3)%4" not in cpp),
        # the confirm() call plus both halves of parseCommand
        ("cpp: convert-textures wired 3x", cpp.count('"convert-textures"') == 3),
        ("cpp: label present", cpp.count("CONVERT TEXTURES FOR LOW MEMORY") == 1),
        ("act: marker preserved", "TSP_MANAGER_V24_PROGRESS_BACKEND" in act),
        ("act: convert_textures defined", act.count("convert_textures() {") == 1),
        ("act: dispatch case", act.count("convert-textures) convert_textures ;;") == 1),
        ("act: parser defined", act.count("texconv_progress_snapshot() {") == 1),
        ("act: selftest extended", act.count("FAIL texconv progress") == 1),
    ]
    print("=== invariants ===")
    for label, good in checks:
        print("      %-4s %s" % ("OK" if good else "FAIL", label))
    if not all(g for _l, g in checks):
        print("=== INVARIANT FAILED - nothing written, sources are byte-identical ===")
        return 1

    # Only now, with every anchor matched and every invariant satisfied, write.
    print("=== write ===")
    for name in files:
        with open(os.path.join(SRC, name), "w", encoding="utf-8") as fh:
            fh.write(patched[name])
        print("      %-30s +%d lines" % (
            name,
            len(patched[name].split("\n")) - len(original[name].split("\n"))))
    print("=== PATCH OK ===")
    return 0


def patch_controller(path):
    """Apply the same eight edits to the single controller file."""
    if not os.path.isfile(path):
        print("FAIL  controller not found: " + path)
        return 1
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    if "TSP_MANAGER_V30_TEXCONV" in text or "convert-textures" in text:
        print("ALREADY PATCHED - nothing done: " + path)
        return 2

    bak = path + ".before-v30-" + STAMP
    shutil.copy2(path, bak)
    with open(bak, "rb") as a, open(path, "rb") as b:
        if a.read() != b.read():
            print("FAIL  backup does not match the original")
            return 1
    print("=== verified backup ===")
    print("      %s  %d bytes" % (bak, os.path.getsize(bak)))

    print("=== anchors (inside the controller heredocs) ===")
    ok = True
    for label, anchor, replacement in CPP_EDITS + ACT_EDITS:
        n = text.count(anchor)
        print("      %-4s %-22s matches=%d" % ("OK" if n == 1 else "FAIL", label, n))
        if n != 1:
            ok = False
            continue
        text = text.replace(anchor, replacement, 1)
    if not ok:
        print("=== NO WRITE - an anchor did not match exactly once; controller untouched ===")
        return 1

    checks = [
        ("5-item setup array", text.count("std::array<std::string,5> n=") == 1),
        ("no %4 left on the setup page", "(a.opt+3)%4" not in text),
        ("convert-textures wired 3x", text.count('"convert-textures"') == 3),
        ("label present", text.count("CONVERT TEXTURES FOR LOW MEMORY") == 1),
        ("progress-backend marker kept", "TSP_MANAGER_V24_PROGRESS_BACKEND" in text),
        ("convert_textures defined", text.count("convert_textures() {") == 1),
        ("dispatch case", text.count("convert-textures) convert_textures ;;") == 1),
        ("parser defined", text.count("texconv_progress_snapshot() {") == 1),
        ("selftest extended", text.count("FAIL texconv progress") == 1),
    ]
    print("=== invariants ===")
    for label, good in checks:
        print("      %-4s %s" % ("OK" if good else "FAIL", label))
    if not all(g for _l, g in checks):
        print("=== INVARIANT FAILED - controller untouched ===")
        return 1

    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    print("=== PATCH OK === controller patched; run its selftest next")
    return 0


if __name__ == "__main__":
    sys.exit(main())
