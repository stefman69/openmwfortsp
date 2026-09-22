#!/bin/sh
# tsp_ktxab.sh - TSP_KTXAB_V4. One-variable A/B on the ASTC texture conversion,
# measured rather than felt.
#
#   0         arm the DDS arm  - engine ignores .ktx, reads DDS from the BSAs
#   1         arm the ASTC arm - engine prefers .ktx
#   verify    read TSP_KTX out of the RUNNING game. Do this in EVERY arm.
#   pull      fetch the sampler result and save it labelled with its arm
#   compare   the two newest arms, side by side, on the numbers that matter
#
# ---------------------------------------------------------------------------
# V1 WAS MEASURING NOTHING. THIS IS THE REPAIR.
#
# V1 wrote TSP_KTX into /mnt/SDCARD/tsp_iotune.conf. NOTHING SOURCES THAT FILE.
# The launcher says so in its own comment at lines 10-14, and /proc/<pid>/environ
# of a live game showed the variable absent. So both arms set nothing, the engine
# used the same compiled default in both, and the A/B could only ever come back
# "no difference" whatever the truth was.
#
# That matters beyond this tool: any earlier no-difference result on TSP_KTX
# taken through V1 is VOID, and the two results on record disagree with each
# other - 09-10 measured +87 MB MemAvailable, 09-11 measured "identical within
# noise" on steady frame time. At least one of those flipped nothing.
#
# V2 writes /mnt/SDCARD/tsp_intocc.env, which Morrowind.sh sources at line 5
# inside its own -f guard. That path is PROVEN: writing TSP_HEAPFIX_V1=1 there
# made it appear in /proc/<pid>/environ.
#
# AND V2 MAKES YOU PROVE THE ARM. `verify` reads the variable out of the running
# process. An A/B whose variable is not in the process environment is not an
# A/B, and that is exactly how V1 wasted its own existence.
#
# WHAT V1 ALSO DID THAT IT SHOULD NOT
#
# It re-enabled the ring profiler and wrote TSP_RING_TRIG=60.
# INCIDENT-profiler-trigger-zero-halved-the-framerate is on record, and the
# 09-11 notes say a trivial 60 ms startup spike at frame 7 burned the first dump
# at exactly that trigger. V2 does not touch the profiler at all. The sampler is
# tsp_verdict.sh, which is 1 Hz and was built for this.
#
# WHY IT DROPS THE PAGE CACHE - kept from V1, it was the good part
#
# Every comparison so far has been confounded by cache state: loads have ranged
# 3.3 s to 25.8 s and Cached has ranged 26 MB to 200 MB across runs, which moved
# the post-load fault rate far more than anything being tested. Both arms start
# cold or neither is comparable.
#
# AND WHY EYEBALLING IT IS NOT ENOUGH
#
# Two runs on identical config have already differed by more than any effect
# measured in this whole investigation. 1-2 fps by feel is inside that. The four
# numbers `compare` prints are the ones that survive it.
# ---------------------------------------------------------------------------

set -u
MODE="${1:-}"
case "$MODE" in
    0|1|verify|pull|compare) ;;
    *) echo "usage: sh $0 0|1|verify|pull|compare"
       echo "   0        DDS arm  - ignore .ktx, read DDS from the BSAs"
       echo "   1        ASTC arm - prefer .ktx"
       echo "   verify   prove the arm from the RUNNING game environ"
       echo "   pull     save the sampler result, labelled with its arm"
       echo "   compare  the two newest arms, side by side"
       exit 2 ;;
esac

# Device address, in order: an explicit DEV= in the environment, then $TSP_DEV
# as `tsp_net.sh each` sets it, then ~/.tsp_dev as `tsp_net.sh use` writes it,
# then the old hardcoded default. Every line returns 0 so a missing ~/.tsp_dev
# cannot trip set -e.
DEV="${DEV:-${TSP_DEV:-}}"
if [ -z "${DEV}" ] && [ -r "$HOME/.tsp_dev" ]; then DEV="$(cat "$HOME/.tsp_dev")"; fi
[ -n "${DEV}" ] || DEV="root@192.168.1.12"

# WHICH CONSOLE THIS IS. Two consoles are in play and unlabelled output is not
# a result. The arm files are named with it too, so arms from different cards
# can never be compared by accident.
[ -n "${TSP_NAME:-}" ] || TSP_NAME="$(awk -F'\t' -v h="$DEV" '$2==h {print $1}' "$HOME/.tsp_hosts" 2>/dev/null | head -1)"
CARD="${TSP_NAME:-UNNAMED}"
printf '\n  ==================  DEVICE: %s  (%s)  ==================\n' "$CARD" "$DEV"

G="/mnt/SDCARD/data/ports/openmw"
ENVF="/mnt/SDCARD/tsp_intocc.env"
ARMF="$HOME/.tsp_ktxab_arm"
VERF="$HOME/.tsp_ktxab_verify"   # TSP_KTXAB_V3: what verify read,
                                 # so pull can fold it into the arm file
VERDICT="$HOME/Downloads/tsp_verdict.sh"
SSHO="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes -o LogLevel=ERROR"
STAMP="$(date +%Y%m%d-%H%M%S)"

say() { printf '  %s\n' "$*"; }
hr()  { printf '\n########## %s ##########\n' "$1"; }
die() { printf '\n  STOPPING: %s\n  Nothing was changed.\n\n' "$*"; exit 1; }

# base64 into the ssh COMMAND, decoded to a file on the device, run with
# </dev/null. On stdin, anything the payload invokes that reads stdin eats the
# rest of it - which is how the scope probe got truncated on the stock card.
rin() {
    _b64="$(base64 | tr -d '\n')"
    ssh -n $SSHO "$DEV" "T=/tmp/tsp_ktxab.\$\$
printf '%s' '$_b64' | base64 -d > \"\$T\" 2>/dev/null || { echo '  (no base64 on this device)'; exit 1; }
sh \"\$T\" </dev/null
_r=\$?
rm -f \"\$T\"
exit \$_r" 2>&1
}

_pf="$(ssh $SSHO -n "$DEV" "echo ok" 2>&1)"
case "$_pf" in
    *ok*) ;;
    *"Permission denied"*|*"publickey"*|*"Too many authentication"*)
        die "ssh AUTH failed for $DEV. Every tool here uses BatchMode and refuses
  passwords on purpose. Install the key once:
      sh ~/Downloads/tsp_net.sh key $DEV" ;;
    *)  die "cannot reach $DEV. ssh said: $_pf" ;;
esac

# =================================================================== verify ===
if [ "$MODE" = "verify" ]; then
    hr "WHAT THE RUNNING GAME ACTUALLY HAS"
    : > "$VERF"
    rin <<'VEOF' | tee -a "$VERF"
P="$(pidof openmw-0.51 2>/dev/null | awk '{print $1}')"
[ -n "$P" ] || P="$(ps -e 2>/dev/null | grep '[o]penmw-0.51' | awk '{print $1}' | head -1)"
[ -n "$P" ] || P="$(ps 2>/dev/null | grep '[o]penmw-0.51' | awk '{print $1}' | head -1)"
if [ -z "$P" ]; then
    echo "  the game is NOT running - launch it first, then verify"
    exit 1
fi
printf '  pid %s\n' "$P"
tr '\0' '\n' < "/proc/$P/environ" 2>/dev/null > /tmp/ab_environ.$$
for k in TSP_KTX TSP_ICO_MAXOBJ TSP_RESTORE_V1; do
    v="$(grep "^$k=" /tmp/ab_environ.$$ 2>/dev/null | head -1)"
    if [ -n "$v" ]; then printf '  PRESENT  %s\n' "$v"
    else                 printf '  ABSENT   %s   <- this arm is NOT what you think\n' "$k"; fi
done
rm -f /tmp/ab_environ.$$
echo "  --- the env file it should have come from ---"
grep -E 'TSP_KTX|TSP_ICO_MAXOBJ' /mnt/SDCARD/tsp_intocc.env 2>/dev/null | sed 's/^/    /'
echo "  --- the log line, which is CAPPED at 8 and is not a load count ---"
grep -c 'TSP_KTX_V1 loaded' /mnt/SDCARD/data/ports/openmw/openmw_log.txt 2>/dev/null \
  | sed 's/^/    capped log lines: /'
VEOF
    printf '\n'
    say "If TSP_KTX is ABSENT, stop: the env file is not reaching the process and"
    say "nothing measured in this run is a test of it."
    printf '\n'
    exit 0
fi

# ===================================================================== pull ===
if [ "$MODE" = "pull" ]; then
    [ -r "$ARMF" ] || die "no arm on record. Run 0 or 1 first - otherwise the
  saved result has no arm attached to it and cannot be compared."
    ARM="$(awk 'NR==1{print $1}' "$ARMF")"
    ACARD="$(awk 'NR==1{print $2}' "$ARMF")"
    [ -x "$VERDICT" ] || [ -r "$VERDICT" ] || die "no $VERDICT to pull with"
    OUT="$HOME/Downloads/tsp_ktxab_${ACARD}_arm${ARM}_$STAMP.txt"
    hr "PULLING THE SAMPLER FOR ARM $ARM ON $ACARD"
    say "saving to $OUT"
    printf '\n'
    # Streamed, not captured and echoed later: a silent command that takes a
    # while reads as a hung one.
    # TSP_KTXAB_V3: the verify proof goes in FIRST, so the saved arm file
    # carries its own evidence and compare can find it later.
    if [ -s "$VERF" ]; then
        {   echo "########## VERIFY - READ OUT OF THE RUNNING GAME, ARM $ARM ##########"
            cat "$VERF"
            echo ""
        } > "$OUT"
        say "folded in the verify proof from $VERF"
        # and the proof has to AGREE with the arm on record, or the file is a lie
        _vk="$(grep -m1 -o 'TSP_KTX=[01]' "$VERF" 2>/dev/null | cut -d= -f2)"
        if [ -n "$_vk" ] && [ "$_vk" != "$ARM" ]; then
            printf '\n'
            say "*** MISMATCH: the arm on record is $ARM but the running game had"
            say "    TSP_KTX=$_vk. This run is NOT arm $ARM. Discard it, re-arm,"
            say "    relaunch, verify, and pull again."
            printf '\n'
        fi
    else
        {   echo "########## NO VERIFY WAS RUN FOR THIS ARM ##########"
            echo "  TSP_KTXAB_V4 stamp: verify was not run before this pull."
            echo ""
        } > "$OUT"
        say "NO verify on record for this arm. Run 'verify' while the game is"
        say "up next time - without it nothing proves which arm this run was."
    fi
    TSP_DEV="$DEV" sh "$VERDICT" pull 2>&1 | tee -a "$OUT"
    printf '\n'
    if grep -q 'no samples' "$OUT" 2>/dev/null; then
        say "NO SAMPLES - arm was not run before the launch, or openmw never"
        say "appeared inside the sampler window. This arm is void; redo it."
    else
        say "saved. Now do the other arm, then: sh $0 compare"
    fi
    printf '\n'
    exit 0
fi

# ================================================================== compare ===
if [ "$MODE" = "compare" ]; then
    hr "THE TWO NEWEST ARMS, SIDE BY SIDE"
    A0="$(ls -1t "$HOME/Downloads"/tsp_ktxab_*_arm0_*.txt 2>/dev/null | head -1)"
    A1="$(ls -1t "$HOME/Downloads"/tsp_ktxab_*_arm1_*.txt 2>/dev/null | head -1)"
    [ -n "$A0" ] || die "no arm0 file in ~/Downloads - run: sh $0 0"
    [ -n "$A1" ] || die "no arm1 file in ~/Downloads - run: sh $0 1"
    say "arm 0 (DDS) : $A0"
    say "arm 1 (ASTC): $A1"
    # filenames are tsp_ktxab_<card>_arm<N>_<stamp>.txt, so field 3 is the card
    C0="$(basename "$A0" | cut -d_ -f3)"
    C1="$(basename "$A1" | cut -d_ -f3)"
    if [ "$C0" != "$C1" ]; then
        printf '\n'
        say "REFUSING to compare: arm0 is from card [$C0] and arm1 from [$C1]."
        say "Two different consoles are not two arms of one A/B."
        printf '\n'; exit 1
    fi
    printf '\n'
    # One extractor, run over both files, so the two columns can never be
    # pulled by different rules.
    ext() {  # ext <file> <sed program>
        printf '%s' "$(sed -n "$2" "$1" 2>/dev/null | head -1)"
    }
    printf '  %-26s %18s %18s\n' "" "arm 0 (DDS)" "arm 1 (ASTC)"
    printf '  %-26s %18s %18s\n' "--------------------------" "------------------" "------------------"
    for spec in \
      "major faults/s mean|s/.*major faults per sec *mean *\([0-9.]*\).*/\1/p" \
      "seconds over 30|s/.*seconds over 30 \/ 100 *\([0-9]*\).*/\1/p" \
      "floor Cached MB|s/.*floor Cached *\([0-9]*\).*/\1/p" \
      "floor MemAvailable MB|s/.*floor MemAvailable *\([0-9]*\).*/\1/p" \
      "peak VmRSS MB|s/.*peak VmRSS *\([0-9]*\).*/\1/p" \
      "median fps|s/.*median *\([0-9.]*\) fps.*/\1/p" \
      "WALK phase secs|s/^ *WALK  *[0-9:]* - [0-9:]* *\([0-9]*\) .*/\1/p" \
      "steady frames (render<40)|s/^ *GOOD  (render < 40ms) *\([0-9]*\) .*/\1/p" \
      "steady render ms|s/^ *GOOD  (render < 40ms) *[0-9]*  *\([0-9.]*\) .*/\1/p" \
      "steady cull ms|s/^ *GOOD  (render < 40ms) *[0-9]*  *[0-9.]*  *\([0-9.]*\) .*/\1/p" \
      "steady draw ms|s/^ *GOOD  (render < 40ms) *[0-9]*  *[0-9.]*  *[0-9.]*  *\([0-9.]*\) .*/\1/p" \
      ; do
        LBL="${spec%%|*}"; PRG="${spec#*|}"
        printf '  %-26s %18s %18s\n' "$LBL" "$(ext "$A0" "$PRG")" "$(ext "$A1" "$PRG")"
    done
    # TSP_KTXAB_V3. The floor on its own is a TRAP. On the 09-14 pair arm 1
    # had a floor 24 MB higher and it read as a win - but arm 1 STARTED 29 MB
    # freer, and actually consumed 5 MB MORE. start - floor is the only
    # memory number that survives a different starting state.
    _s0="$(grep -o 'avail *[0-9]*' "$A0" 2>/dev/null | head -1 | awk '{print $2}')"
    _s1="$(grep -o 'avail *[0-9]*' "$A1" 2>/dev/null | head -1 | awk '{print $2}')"
    _f0="$(ext "$A0" 's/.*floor MemAvailable *\([0-9]*\).*/\1/p')"
    _f1="$(ext "$A1" 's/.*floor MemAvailable *\([0-9]*\).*/\1/p')"
    printf '  %-26s %18s %18s\n' "start MemAvailable MB" "${_s0:--}" "${_s1:--}"
    if [ -n "$_s0" ] && [ -n "$_f0" ] && [ -n "$_s1" ] && [ -n "$_f1" ]; then
        printf '  %-26s %18s %18s    <- THE memory number\n' \
            "MB CONSUMED start-floor" "$(( _s0 - _f0 ))" "$(( _s1 - _f1 ))"
    fi
    printf '\n'
    say "steady render ms is the GOOD bucket - render under 40 ms - NOT the"
    say "MEAN OVER line. That mean mixes in 700-1300 ms load frames, and on"
    say "those the log draw= exceeds its own render=, because draw is timed"
    say "on the draw thread and outlasts the frame it is filed under. Inside"
    say "the GOOD bucket, cull + draw + resid does reconcile with render."
    printf '\n'
    say "Compare these and nothing else. A change that lowers faults/s and"
    say "raises the Cached floor is working, whatever the run felt like."
    printf '\n'
    say "WHICH ARM EACH FILE ACTUALLY WAS"
    for f in "$A0" "$A1"; do
        if [ "$f" = "$A0" ]; then _want=0; else _want=1; fi
        printf '    %s\n' "$(basename "$f")"
        # (1) strongest: the variable read out of the live process. Anchored on
        #     PRESENT/ABSENT on purpose - tsp_verdict.sh prints the prose line
        #     "...is the only proof TSP_KTX=1 is doing" into EVERY arm file,
        #     arm 0 included, so a bare grep reports arm 0 as TSP_KTX=1.
        _p="$(grep -m1 -o 'PRESENT  TSP_KTX=[01]' "$f" 2>/dev/null | grep -o 'TSP_KTX=[01]')"
        _a="$(grep -c 'ABSENT   TSP_KTX' "$f" 2>/dev/null)"; [ -n "$_a" ] || _a=0
        # (2) works on EVERY file, pre-V3 ones included, and proves the engine
        #     ACTED rather than that the variable was merely set.
        _n="$(grep -c 'TSP_KTX_V1 loaded' "$f" 2>/dev/null)"; [ -n "$_n" ] || _n=0
        if [ -n "$_p" ]; then
            printf '      environ: %s   (read out of the running game)\n' "$_p"
        elif [ "$_a" -gt 0 ]; then
            printf '      environ: ABSENT - the env file did NOT reach the process.\n'
            printf '               This run tests nothing. Discard it.\n'
        elif grep -q 'NO VERIFY WAS RUN FOR THIS ARM' "$f" 2>/dev/null; then
            printf '      environ: not captured - verify was not run before this pull.\n'
        else
            printf '      environ: not in this file, and it CANNOT be - this arm was\n'
            printf '               pulled before the fix that saves the verify output.\n'
            printf '               That is the tool discarding it, not a missed step.\n'
        fi
        if [ "$_n" -gt 0 ]; then
            printf '      engine:  %s ASTC loads in the log - TSP_KTX WAS live. CONCLUSIVE.\n' "$_n"
            _got=1
        else
            printf '      engine:  0 ASTC loads - consistent with TSP_KTX=0.\n'
            # only worth the caveat when nothing above has already settled it
            if [ -z "$_p" ]; then
                printf '               NOT conclusive on its own: TSP_KTX=1 with nothing\n'
                printf '               eligible loaded would look exactly the same.\n'
            fi
            _got=0
        fi
        if [ "$_got" != "$_want" ] && [ "$_got" = 1 ]; then
            printf '      *** THIS IS NOT ARM %s - it has ASTC loads. Discard the pair.\n' "$_want"
        fi
    done
    printf '\n'
    exit 0
fi

# ================================================================ 0 / 1 arm ===
rm -f "$VERF"   # TSP_KTXAB_V3: a new arm invalidates the old proof
hr "1. THE ENV FILE AS IT IS NOW"
rin <<E1EOF
E='$ENVF'
if [ -f "\$E" ]; then
    grep -nE 'TSP_KTX|TSP_ICO_MAXOBJ|TSP_RESTORE_V1' "\$E" | sed 's/^/    /'
else
    echo "    $ENVF DOES NOT EXIST"
    echo "    That file is the only delivery path that reaches the process."
    echo "    Recreate it with:  sh ~/Downloads/tsp_icoktx.sh go"
fi
E1EOF

hr "2. SETTING TSP_KTX=$MODE IN THE PATH THAT WORKS"
# The remote block refuses when there is no env file to edit. V2.0 threw that
# refusal away and carried on to drop the cache, arm the sampler and print
# "ARM 0 IS SET" - so a run with the variable never set looked like an arm.
# The pull then showed TSP_ICO_BUDGET_V1 maxobj=20, the compiled fallback,
# which is what a missing env file looks like. Abort instead.
AB2="/tmp/tsp_ktxab_set.$$"
rin 2>&1 <<E2EOF | tee "$AB2"
E='$ENVF'
[ -f "\$E" ] || { echo "    no env file - refusing to invent one"; exit 1; }
BEFORE="\$(grep -c 'TSP_KTX' "\$E")"
if [ "\$BEFORE" -lt 1 ]; then
    echo "    no TSP_KTX line to change; refusing to invent one."
    echo "    Run: sh ~/Downloads/tsp_icoktx.sh go"
    exit 1
fi
cp -p "\$E" "\$E.before-ktxab-$STAMP" || { echo "    backup failed"; exit 1; }
printf '    backed up to %s.before-ktxab-%s\n' "\$E" '$STAMP'

sed "s/^\\([[:space:]]*export[[:space:]][[:space:]]*TSP_KTX=\\).*/\\1$MODE/" "\$E" > "\$E.new" \\
    || { echo "    sed failed"; rm -f "\$E.new"; exit 1; }

BL="\$(wc -l < "\$E")"; AL="\$(wc -l < "\$E.new")"
GOT="\$(sed -n 's/^[[:space:]]*export[[:space:]][[:space:]]*TSP_KTX=\\(.*\\)\$/\\1/p' "\$E.new")"
printf '    lines %s -> %s     (must be equal)\n' "\$BL" "\$AL"
printf '    TSP_KTX now [%s]   (must be %s)\n' "\$GOT" '$MODE'
OK=1
[ "\$BL" = "\$AL" ] || OK=0
[ "\$GOT" = "$MODE" ] || OK=0
if [ "\$OK" -ne 1 ]; then
    rm -f "\$E.new"
    echo "    REFUSED - env file untouched"
    exit 1
fi
mv "\$E.new" "\$E"
echo "    VERIFIED on disk: export TSP_KTX=$MODE"
echo "    (on disk is NOT in the process - prove that with: verify)"
E2EOF
if grep -qE 'refusing|no env file|REFUSED|sed failed|backup failed' "$AB2"; then
    rm -f "$AB2"
    die "the arm was NOT set, so there is nothing to measure. Nothing was
  armed and the page cache was left alone.

  /mnt/SDCARD/tsp_intocc.env is the only path that reaches the process, and it
  is missing or has no TSP_KTX line. Recreate it, which also puts the ICO fix
  back, then re-run this arm:

      sh ~/Downloads/tsp_icoktx.sh go"
fi
rm -f "$AB2"

hr "3. A CLEAN, COLD START - THE CONTROL"
rin <<E3EOF
S=/mnt/SDCARD
G='$G'
if [ -s "\$G/openmw_log.txt" ]; then
    mv "\$G/openmw_log.txt" "\$G/openmw_log.txt.ktx$MODE-$STAMP" \\
      && echo "    log parked as openmw_log.txt.ktx$MODE-$STAMP"
fi
touch "\$S/tsp_ktxwarm_off"
echo "    prefetch left off (TSP_KTXWARM tripled the fault rate on this device)"
echo "    profiler NOT touched - tsp_verdict is the sampler"
sync
printf '    Cached before: %s kB\n' "\$(awk '/^Cached:/{print \$2}' /proc/meminfo)"
sync
if echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; then
    echo "    caches dropped"
else
    echo "    WARNING: could not drop caches - this arm is NOT comparable"
fi
printf '    Cached after:  %s kB\n' "\$(awk '/^Cached:/{print \$2}' /proc/meminfo)"
E3EOF

hr "4. ARMING THE 1 Hz SAMPLER"
if [ -r "$VERDICT" ]; then
    TSP_DEV="$DEV" sh "$VERDICT" arm 2>&1 | sed -n '/ARMING\|sampler lines\|ARMED_OK\|it ran\|waiting/p' | sed 's/^/    /'
else
    say "no $VERDICT - arm it yourself before launching, or this arm has no numbers"
fi

printf '%s %s %s\n' "$MODE" "$CARD" "$STAMP" > "$ARMF"
say "arm recorded in $ARMF as: arm $MODE on $CARD"

printf '\n'
printf '  ================================================================\n'
printf '   ARM %s IS SET ON %s   (%s)\n' "$MODE" "$CARD" \
  "$( [ "$MODE" = 1 ] && echo 'ASTC - prefer .ktx' || echo 'DDS - ignore .ktx' )"
printf '  ================================================================\n'
say "1. LAUNCH NOW, while the cache is still cold."
say "2. Once it is in game, from another shell:   sh $0 verify"
say "   If TSP_KTX is ABSENT there, abandon the run - it is not an arm."
say "3. Load the Balmora save, walk the same route past Caius, quit."
say "4. Then:                                     sh $0 pull"
printf '\n'
say "Do arm 0 and arm 1 the same way, then:       sh $0 compare"
printf '\n'
