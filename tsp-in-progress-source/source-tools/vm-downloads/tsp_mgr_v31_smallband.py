import shutil, sys, time
target = sys.argv[1] if len(sys.argv) > 1 else "openmw_manager_action.sh"
text = open(target, encoding="utf-8").read()

OLD_START = '''convert_textures() {
    local done_file rc snapshot pct phase detail pct2 phase2 detail2
    local before after fp args_ok=0'''
OLD_END = '''    progress "TEXTURE CONVERSION STOPPED" 100 "$after files done"
    say "ERROR texture conversion stopped early (exit $rc) after $after of the textures; run it again to carry on from there"
    return "$rc"
}'''

NEW = r'''# One pass of the converter over a size band. The tool skips any .ktx that already
# exists, so a pass is resumable and a second run over a done band costs seconds.
texconv_run_pass() {
    local label="$1" tmin="$2" tmax="$3" block="$4"
    local done_file rc snapshot pct phase detail pct2 phase2 detail2 f
    done_file="$PROGRESS_FILE.tex.$$"
    rm -f "$done_file"
    progress "$label" 0 "reading the game archives"
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
            --min-size "$tmin" --max-size "$tmax" --block "$block" >> "$TEXCONV_LOG" 2>&1 || rc=$?
        printf '%s\n' "$rc" > "$done_file"
    ) &
    while [ ! -s "$done_file" ]; do
        snapshot="$(texconv_progress_snapshot "$TEXCONV_LOG")"
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
    case "$rc" in ''|*[!0-9]*) rc=1 ;; esac
    return "$rc"
}

convert_textures() {
    local rc1 rc2 before after fp failed
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
        grep -v '^tiers=' "$TEXCONV_MARK" 2>/dev/null > "$TEXCONV_MARK.tmp" || true
        printf 'fingerprint=%s\ntiers=%s\n' "$fp" "$TEXCONV_TIERS" >> "$TEXCONV_MARK.tmp"
        mv -f "$TEXCONV_MARK.tmp" "$TEXCONV_MARK" 2>/dev/null || true
        progress "TEXTURE CONVERSION COMPLETE" 100 "$after files"
        if [ "$failed" -gt 0 ]; then
            say "Texture conversion finished: $after textures converted, $failed could not be read and were left as they were"
        else
            say "Texture conversion finished: $after textures converted"
        fi
        return 0
    fi

    progress "TEXTURE CONVERSION STOPPED" 100 "$after files done"
    say "ERROR texture conversion stopped early (large band $rc1, small band $rc2) after $after textures; run it again to carry on from there"
    return 1
}'''

start = text.find(OLD_START)
end = text.find(OLD_END)
if start < 0 or end < 0:
    print("FAIL could not locate the v30 convert_textures function")
    sys.exit(1)
if "TEXCONV_TIERS" in text:
    print("ALREADY PATCHED")
    sys.exit(2)

bak = target + ".before-v31-" + time.strftime("%Y%m%d-%H%M%S")
shutil.copy2(target, bak)
if open(bak,"rb").read() != open(target,"rb").read():
    print("FAIL backup mismatch"); sys.exit(1)
print("=== verified backup ===\n      " + bak)

text = text[:start] + NEW + text[end + len(OLD_END):]
text = text.replace('TEXCONV_MARK="$TEXCONV_DATA/tsp_texconv.done"',
                    'TEXCONV_MARK="$TEXCONV_DATA/tsp_texconv.done"\nTEXCONV_TIERS="8x8+6x6"', 1)

checks = [
    ("two-band runner defined", text.count("texconv_run_pass() {") == 1),
    ("large band wired", text.count('texconv_run_pass "CONVERTING LARGE TEXTURES" 128 0 8x8') == 1),
    ("small band wired", text.count('texconv_run_pass "CONVERTING SMALL TEXTURES" 0 127 6x6') == 1),
    ("tiers constant", text.count('TEXCONV_TIERS="8x8+6x6"') == 1),
    ("tiers gate on early return", text.count('grep -Fqx "tiers=$TEXCONV_TIERS"') == 1),
    ("STEPS=2 for the two bands", text.count("STEPS=2") == 1),
    ("missing tool still returns 80", text.count("return 80") == 1),
    ("old single-pass body gone", "args_ok=0" not in text),
    ("parser untouched", text.count("texconv_progress_snapshot() {") == 1),
    ("progress-backend marker kept", "TSP_MANAGER_V24_PROGRESS_BACKEND" in text),
]
print("=== invariants ===")
bad = False
for label, good in checks:
    print("      %-4s %s" % ("OK" if good else "FAIL", label))
    bad = bad or not good
if bad:
    print("=== INVARIANT FAILED - nothing written ==="); sys.exit(1)

open(target, "w", encoding="utf-8").write(text)
print("=== PATCH OK ===")
