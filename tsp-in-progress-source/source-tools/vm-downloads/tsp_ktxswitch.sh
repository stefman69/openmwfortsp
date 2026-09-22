#!/bin/sh
# tsp_ktxswitch.sh - TSP_KTXSWITCH_V2. Two PORTS-menu entries, each launching
# Morrowind in one of the two SHIPPABLE texture configurations, with a 120 s
# capture per launch that separates gameplay from teardown.
#
#   install   put both PORTS entries + the capture script on the card
#   pull      fetch the newest 4 captures and print them side by side
#   state     what the card is set to right now
#   remove    take the PORTS entries off again
#
# ---------------------------------------------------------------------------
# WHAT V1 ESTABLISHED, AND WHY THE ARMS CHANGED
#
# V1 flipped TSP_KTX only. With OPENMW_DECOMPRESS_TEXTURES off (TSP_DECOMP_V1),
# .12 gave the first replicated ASTC result on record - four runs, gameplay
# phase only:
#
#                    DDS #1   ASTC #1   DDS #2   ASTC #2
#     play secs         108        80       85        78
#     peak RSS MB       660       618      671       646
#     consumed MB       621       563      651       600
#     floor Cached MB    28        90       31        77
#     faults / sec     32.5      28.3     34.2      25.2
#
# Every metric moves the same way both times, and the Cached floor - the
# documented fault mechanism on this card - nearly trebles. So ASTC does work;
# the decompress flag was cancelling it, which is why the 09-14 .21 pair
# measured nothing at all.
#
# That leaves exactly TWO shippable configurations, because the other two are
# already dead:
#
#     ASTC + decompress ON    pointless - the engine expands the .ktx anyway
#     DDS  + decompress OFF   the worst measured config, by every number above
#
# So V2 stops flipping one variable and flips between the two survivors:
#
#     arm A   TSP_KTX=0, decompress ON    no conversion needed at all
#     arm B   TSP_KTX=1, decompress OFF   the 45-60 minute conversion
#
# Two variables at once is normally indefensible. Here it is the whole point:
# the question is not which variable matters, it is which of the two viable
# builds to ship, so there is nothing for the confound to mislead.
#
# ALSO FIXED IN V2: THE TEARDOWN WAS EATING THE FAULT COUNT
#
# V1 reported one major-faults total for the whole capture. In the four runs
# above, 13,424 of arm0 #1s 16,333 faults landed in the final 7 seconds while
# the process was exiting - threads dropping 20 -> 16 -> 13 -> 11 -> 1. That is
# teardown, not a hitch, exactly as the phase-split rule already says. Reading
# it as gameplay overstated the ASTC win as 2-3x when it is 17-26%.
#
# V2 post-processes each capture with ONE awk pass at the end, finds the last
# sample still at full thread count, and reports PLAY and QUIT separately. It
# also ignores 0 readings: /proc can be read mid-update and return 0 for rss,
# vsz or threads, and a 0 taken as a floor would make CONSUMED the whole start
# value.
#
# NOTHING HERE EDITS THE LAUNCHER OR ANY CONFIG.
# TSP_KTX goes into /mnt/SDCARD/tsp_intocc.env, which the launcher sources at
# the top of every run; the decompress arm is the /mnt/SDCARD/tsp_decomp_off
# flag that TSP_DECOMP_V1 reads. Both are on the SD card, so both can be undone
# over ssh if the screen comes up black, and neither needs bash.
#
# install REFUSES unless the launcher sources the env file AND carries
# TSP_DECOMP_V1 - without the second, arm A and arm B would both run with
# decompression on and the pair would be a fake.
#
# Every remote block is a QUOTED heredoc with literal card paths. An unquoted
# one expands in the LOCAL shell first, where $E and $ARM are not set, and
# under set -u that kills the tool before it sends anything.
# ---------------------------------------------------------------------------

set -u
MODE="${1:-}"
PAIR="$(printf '%s' "${2:-cd}" | tr 'A-Z' 'a-z')"
case "$MODE" in
    install)
        case "$PAIR" in
            ab|cd) ;;
            *) echo "usage: sh $0 install ab|cd"
               echo "   ab   arm A = DDS  + decompress ON   (no conversion needed)"
               echo "        arm B = ASTC + decompress OFF  (the hour-long conversion)"
               echo "   cd   arm C = ASTC + decompress ON   <- ASTC fixed, flag varied"
               echo "        arm D = ASTC + decompress OFF"
               exit 2 ;;
        esac ;;
    pull|state|remove|check) ;;
    *) echo "usage: sh $0 install ab|cd | pull | state | check | remove"
       echo "   install   write one PAIR of PORTS entries + the capture script"
       echo "   pull      fetch the newest 4 captures and compare them"
       echo "   state     which arm and which flag the card is on"
       echo "   check     confirm every ktx setting on the card is still right"
       echo "   remove    take the PORTS entries off again"
       exit 2 ;;
esac

# Device address, in order: an explicit TSP=/DEV= in the environment, then $TSP_DEV
# as `tsp_net.sh each` sets it, then ~/.tsp_dev as `tsp_net.sh use` writes it,
# then the old hardcoded default. Every line here returns 0, so a missing
# ~/.tsp_dev cannot trip set -e.
DEV="${DEV:-${TSP_DEV:-}}"
if [ -z "${DEV}" ] && [ -r "$HOME/.tsp_dev" ]; then DEV="$(cat "$HOME/.tsp_dev")"; fi
[ -n "${DEV}" ] || DEV="root@192.168.1.12"

# WHICH CONSOLE THIS IS. Printed on EVERY run.
[ -n "${TSP_NAME:-}" ] || TSP_NAME="$(awk -F'\t' -v h="$DEV" '$2==h {print $1}' "$HOME/.tsp_hosts" 2>/dev/null | head -1)"
printf '\n  ==================  DEVICE: %s  (%s)  ==================\n' "${TSP_NAME:-UNNAMED}" "$DEV"

SSHO="-o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
CAPDIR="/mnt/SDCARD/tsp_ktxcap"
STAMP="$(date +%Y%m%d-%H%M%S)"

say() { printf '  %s\n' "$*"; }
hr()  { printf '\n########## %s ##########\n' "$1"; }
die() { printf '\n  STOPPING: %s\n\n' "$*"; exit 1; }

rin() {
    _b64="$(base64 | tr -d '\n')"
    ssh -n $SSHO "$DEV" "T=/tmp/tsp_sw.\$\$
printf '%s' '$_b64' | base64 -d > \"\$T\" 2>/dev/null || { echo '  (no base64 on this device)'; exit 1; }
sh \"\$T\" </dev/null
_r=\$?
rm -f \"\$T\"
exit \$_r" 2>&1
}

hr "REACHABILITY"
_pf="$(ssh -n $SSHO "$DEV" 'echo TSPSW ok' 2>&1)"
case "$_pf" in
    *"TSPSW ok"*) say "ssh ok" ;;
    *"Permission denied"*|*publickey*|*"Too many authentication"*)
        die "ssh AUTH failed for $DEV. Install the key once:
      sh ~/Downloads/tsp_net.sh key $DEV" ;;
    *)  die "cannot reach $DEV. ssh said: $_pf" ;;
esac

# ===================================================================== state ==
if [ "$MODE" = "state" ]; then
    hr "WHAT THIS CARD IS SET TO"
    rin <<'SEOF'
echo "--- TSP_KTX in the env file"
grep -nE '^[[:space:]]*(export[[:space:]]+)?TSP_KTX=' /mnt/SDCARD/tsp_intocc.env 2>/dev/null \
  | sed 's/^/    /' || echo "    no TSP_KTX line - compiled default"
echo "--- the decompress flag"
if [ -f /mnt/SDCARD/tsp_decomp_off ]; then
    echo "    tsp_decomp_off PRESENT -> decompression OFF"
else
    echo "    tsp_decomp_off absent  -> decompression ON (shipped default)"
fi
echo "--- which arm ran last"
ls -1 /mnt/SDCARD/ARM-IS-* 2>/dev/null | sed 's/^/    /' || echo "    no arm marker yet"
echo "--- the PORTS entries"
ls -1 /mnt/SDCARD/Roms/PORTS 2>/dev/null | sed 's/^/    /' | head -30
echo "--- captures on the card, newest first"
ls -1t /mnt/SDCARD/tsp_ktxcap 2>/dev/null | head -10 | sed 's/^/    /' || echo "    none yet"
echo "--- last few launches, from the prog log"
grep 'TSP_KTXSWITCH_V2\|TSP_DECOMP_V1' /mnt/SDCARD/tsp_prog.txt 2>/dev/null | tail -6 | sed 's/^/    /'
echo "--- is the game running"
if pidof openmw-0.51 >/dev/null 2>&1; then echo "    yes"; else echo "    no"; fi
SEOF
    printf '\n'
    exit 0
fi

# ===================================================================== check ==
if [ "$MODE" = "check" ]; then
    hr "IS EVERY KTX SETTING ON THIS CARD STILL RIGHT"
    rin <<'KEOF'
G=/mnt/SDCARD/data/ports/openmw
E=/mnt/SDCARD/tsp_intocc.env
P=/mnt/SDCARD/Roms/PORTS
ok()  { printf '  OK    %s\n' "$*"; }
bad() { printf '  WRONG %s\n' "$*"; }
note(){ printf '        %s\n' "$*"; }

echo "--- 1. the launcher the menu actually runs"
L=""
if [ -f "$P/Morrowind.sh" ] && ! grep -q 'TSP_KTXSWITCH_V' "$P/Morrowind.sh" 2>/dev/null; then
    L="$P/Morrowind.sh"
else
    for f in "$P"/*.sh; do
        grep -q 'TSP_KTXSWITCH_V' "$f" 2>/dev/null && continue
        grep -q '/mnt/SDCARD/data/ports/openmw' "$f" 2>/dev/null && { L="$f"; break; }
    done
fi
if [ -n "$L" ]; then ok "launcher: $L ($(wc -c < "$L") bytes)"
else bad "no launcher found in $P"; exit 1; fi
if grep -q 'tsp_intocc.env' "$L" 2>/dev/null; then ok "it sources tsp_intocc.env - TSP_KTX can reach the game"
else bad "it does NOT source tsp_intocc.env - TSP_KTX can never reach the game"; fi
if grep -q 'TSP_POSIX_V1' "$L" 2>/dev/null; then ok "TSP_POSIX_V1 present - runs on the stock card too"
else note "TSP_POSIX_V1 absent - this is an older launcher lineage"; fi

echo "--- 2. TSP_KTX itself"
K="$(sed -n 's/^[[:space:]]*\(export[[:space:]]*\)\?TSP_KTX=\([01]\).*/\2/p' "$E" 2>/dev/null | tail -1)"
case "$K" in
    1) ok "TSP_KTX=1 in the env file - the engine prefers the .ktx" ;;
    0) bad "TSP_KTX=0 - the engine is IGNORING every .ktx on this card" ;;
    *) bad "no TSP_KTX line in $E - the engine is on its compiled default"
       note "set it with: printf 'export TSP_KTX=1\\n' >> $E" ;;
esac
N="$(grep -cE '^[[:space:]]*(export[[:space:]]+)?TSP_KTX=' "$E" 2>/dev/null)"
[ -n "$N" ] || N=0
if [ "$N" -le 1 ]; then ok "exactly $N TSP_KTX line - no contradictory duplicate"
else bad "$N TSP_KTX lines in the env file - the LAST one wins, the rest are noise"; fi

echo "--- 3. the decompress flag, which cancels ASTC when it is on"
if grep -q 'TSP_DECOMP_V1' "$L" 2>/dev/null; then ok "launcher is TSP_DECOMP_V1 patched - the flag works"
else bad "launcher NOT patched - the export is hardcoded and ASTC stays cancelled"
     note "fix: sh ~/Downloads/tsp_decomp.sh patch"; fi
if [ -f /mnt/SDCARD/tsp_decomp_off ]; then ok "tsp_decomp_off PRESENT - decompression OFF, ASTC can pay"
else bad "tsp_decomp_off absent - decompression ON, which expands the .ktx"; fi

echo "--- 4. are the .ktx actually installed, per data root"
T=0
{ sed -n 's/^data=//p' "$G/bin/openmw.cfg" 2>/dev/null
  sed -n 's/^data=//p' "$G/config/openmw.cfg" 2>/dev/null; } \
  | tr -d '"' | awk '!seen[$0]++' > /tmp/ktxroots.$$
while IFS= read -r d; do
    [ -d "$d/textures" ] || continue
    c="$(find "$d/textures" -maxdepth 2 -iname '*.ktx' 2>/dev/null | wc -l)"
    [ "$c" -gt 0 ] || continue
    printf '        %6s  %s\n' "$c" "$d/textures"
    T=$((T+c))
done < /tmp/ktxroots.$$
rm -f /tmp/ktxroots.$$
if [ "$T" -gt 4000 ]; then ok "$T .ktx across the data roots - the conversion is installed"
elif [ "$T" -gt 0 ]; then bad "only $T .ktx - the conversion is PARTIAL on this card"
else bad "NO .ktx found - nothing to prefer, TSP_KTX=1 does nothing here"; fi

echo "--- 5. a .dds with a .ktx sibling, to prove the pairing"
S="$(find "$G/data/Data Files/textures" -maxdepth 1 -iname '*.ktx' 2>/dev/null | head -1)"
if [ -n "$S" ]; then
    B="${S%.ktx}"
    printf '        %s  %s bytes\n' "$(basename "$S")" "$(wc -c < "$S")"
    if [ -f "$B.dds" ]; then printf '        %s  %s bytes  <- the pair the engine chooses between\n' "$(basename "$B.dds")" "$(wc -c < "$B.dds")"
    else note "$(basename "$B").dds not loose here - it lives in a BSA, which is normal"; fi
else note "no loose .ktx in data/Data Files/textures to sample"; fi

echo "--- 6. the two things that must stay OFF"
if [ -f /mnt/SDCARD/tsp_ktxwarm_off ]; then ok "tsp_ktxwarm_off present - the prefetch is disabled"
else bad "tsp_ktxwarm_off MISSING - TSP_KTXWARM tars the whole texture tree at launch"
     note "it tripled the post-load fault rate 51.9 -> 145.3/s, and it contaminates"
     note "any atime-based coverage census. Fix: touch /mnt/SDCARD/tsp_ktxwarm_off"; fi
if [ -f /mnt/SDCARD/tsp_ring_off ]; then ok "tsp_ring_off present - the ring profiler is disabled"
else bad "tsp_ring_off MISSING - the profiler halved the framerate once already"
     note "fix: touch /mnt/SDCARD/tsp_ring_off"; fi

echo "--- 7. what the last run actually had (the only real proof)"
LOG="$G/openmw_log.txt"
if [ -f "$LOG" ]; then
    grep -m1 'TSP_ICO_BUDGET_V1' "$LOG" 2>/dev/null | sed 's/^/        /'
    printf '        TSP_KTX_V1 loaded lines: %s  (the log CAPS this at 8 - it is not a load count)\n' \
        "$(grep -c 'TSP_KTX_V1 loaded' "$LOG" 2>/dev/null)"
    grep -m1 'TSP_KTX_V1 loaded' "$LOG" 2>/dev/null | sed 's/^/        /'
else note "no openmw_log.txt yet"; fi
grep 'TSP_DECOMP_V1' /mnt/SDCARD/tsp_prog.txt 2>/dev/null | tail -2 | sed 's/^/        /'
KEOF
    printf '\n'
    exit 0
fi

# ==================================================================== remove ==
if [ "$MODE" = "remove" ]; then
    hr "REMOVING THE PORTS ENTRIES"
    rin <<'REOF'
P=/mnt/SDCARD/Roms/PORTS
for f in "$P"/*.sh; do
    grep -q 'TSP_KTXSWITCH_V' "$f" 2>/dev/null && { rm -f "$f"; echo "  removed $(basename "$f")"; }
done
rm -f /mnt/SDCARD/tsp_ktxcap.sh
echo "  captures LEFT ALONE - files kept: $(ls -1 /mnt/SDCARD/tsp_ktxcap 2>/dev/null | wc -l)"
echo "  the plain Morrowind entry is untouched. It will use whatever the last"
echo "  arm left behind:"
grep -nE '^[[:space:]]*(export[[:space:]]+)?TSP_KTX=' /mnt/SDCARD/tsp_intocc.env 2>/dev/null | sed 's/^/    /'
[ -f /mnt/SDCARD/tsp_decomp_off ] && echo "    decompress OFF" || echo "    decompress ON"
echo "  PORTS now:"
ls -1 "$P" 2>/dev/null | sed 's/^/    /'
REOF
    printf '\n'
    exit 0
fi

# ====================================================================== pull ==
if [ "$MODE" = "pull" ]; then
    hr "NEWEST 4 CAPTURES"
    LIST="$(ssh -n $SSHO "$DEV" "ls -1t $CAPDIR/*.txt 2>/dev/null | head -4" 2>/dev/null)"
    [ -n "$LIST" ] || die "no captures in $CAPDIR on this card.
  Launch the game at least once from one of the two PORTS entries first.
  Each launch writes its own file, so they accumulate."
    D="$HOME/Downloads/tsp_ktxcap_${TSP_NAME:-card}_$STAMP"
    mkdir -p "$D"
    for f in $LIST; do
        [ -n "$f" ] || continue
        b="$(basename "$f")"
        if scp $SSHO "$DEV:$f" "$D/$b" </dev/null >/dev/null 2>&1; then
            printf '  fetched %s\n' "$b"
        else
            printf '  FAILED  %s\n' "$b"
        fi
    done
    say "into $D"
    printf '\n'

    hr "THE RUNS SIDE BY SIDE - GAMEPLAY PHASE ONLY"
    ex() { sed -n "$2" "$1" 2>/dev/null | head -1; }
    FILES="$(ls -1 "$D"/*.txt 2>/dev/null)"
    [ -n "$FILES" ] || die "nothing landed in $D - every scp failed."
    printf '  %-26s' "run"
    for f in $FILES; do printf ' %14s' "$(basename "$f" .txt | cut -c10-)"; done
    printf '\n  %-26s' "--------------------------"
    for f in $FILES; do printf ' %14s' "--------------"; done
    printf '\n'
    # A capture whose summary never ran prints blanks in every cell, which reads
    # as zero. Say VOID instead: on 09-14 run 4 came back empty and looked like
    # a result rather than a dead file.
    printf '  %-26s' "status"
    for f in $FILES; do
        if [ -n "$(ex "$f" 's/^  PLAY secs  *\([0-9]*\).*/\1/p')" ]; then printf ' %14s' "ok"
        else printf ' %14s' "*** VOID ***"; fi
    done
    printf '\n'
    for spec in \
      "CONFIG (from the process)|s/^  CONFIG  \(.*\)$/\1/p" \
      "ktx load lines (cap 8)|s/^  ktx load lines[^:]*: *\([0-9]*\).*/\1/p" \
      "PLAY secs|s/^  PLAY secs  *\([0-9]*\).*/\1/p" \
      "PLAY peak VmRSS MB|s/^  PLAY peak VmRSS MB  *\([0-9]*\).*/\1/p" \
      "PLAY CONSUMED MB|s/^  PLAY CONSUMED MB  *\(-*[0-9]*\).*/\1/p" \
      "PLAY floor Cached MB|s/^  PLAY floor Cached MB  *\([0-9]*\).*/\1/p" \
      "PLAY faults per sec|s/^  PLAY faults per sec  *\([0-9.]*\).*/\1/p" \
      "PLAY major faults|s/^  PLAY major faults  *\([0-9]*\).*/\1/p" \
      "QUIT faults (ignore)|s/^  QUIT major faults  *\([0-9]*\).*/\1/p" \
      ; do
        L="${spec%%|*}"; PRG="${spec#*|}"
        printf '  %-26s' "$L"
        for f in $FILES; do printf ' %14s' "$(ex "$f" "$PRG")"; done
        printf '\n'
    done
    printf '\n'
    say "Read these four and nothing else:"
    say "  PLAY floor Cached MB   how hard the page cache got evicted. This is"
    say "                         the fault mechanism on this card, and it is"
    say "                         where ASTC showed its clearest win (28/31 MB"
    say "                         on DDS against 90/77 on ASTC)."
    say "  PLAY CONSUMED MB       start minus floor MemAvailable. A floor alone"
    say "                         is not a memory number."
    say "  PLAY faults per sec    normalised, because the walks are never the"
    say "                         same length."
    say "  PLAY peak VmRSS MB     whether the change shrank anything at all."
    printf '\n'
    say "QUIT faults is printed only so it can be IGNORED. In the 09-14 four,"
    say "13424 of arm0 number 1s 16333 faults were the process exiting. A total"
    say "that includes teardown overstated the ASTC win as 2-3x when it is"
    say "17-26 percent."
    printf '\n'
    say "PLAY secs differing by more than about 25 percent between two runs"
    say "makes their CONSUMED and peak RSS hard to compare - RSS keeps climbing."
    say "Walk the same route for the same time if you can."
    printf '\n'
    exit 0
fi

# =================================================================== install ==
hr "1. CAN BOTH ARMS ACTUALLY REACH THE GAME"
PRE="/tmp/tsp_sw_pre.$$"
rin 2>&1 <<'PEOF' | tee "$PRE"
P=/mnt/SDCARD/Roms/PORTS
E=/mnt/SDCARD/tsp_intocc.env
echo "--- the PORTS folder"
if [ ! -d "$P" ]; then echo "  MISSING: $P"; echo "  TSPSW_FATAL no_ports_dir"; exit 1; fi
ls -1 "$P" 2>/dev/null | sed 's/^/    /' | head -30

# Find the real launcher. Skip our own wrappers by MARKER, not by name: arm A
# is called "DDS" and would not be caught by a name filter, and arm B would
# then hand off to it instead of to the game.
L=""
if [ -f "$P/Morrowind.sh" ] && ! grep -q 'TSP_KTXSWITCH_V' "$P/Morrowind.sh" 2>/dev/null; then
    L="$P/Morrowind.sh"
else
    for f in "$P"/*.sh; do
        grep -q 'TSP_KTXSWITCH_V' "$f" 2>/dev/null && continue
        grep -q '/mnt/SDCARD/data/ports/openmw' "$f" 2>/dev/null && { L="$f"; break; }
    done
fi
if [ -z "$L" ]; then echo "  no Morrowind launcher found in $P"; echo "  TSPSW_FATAL no_launcher"; exit 1; fi
echo "--- the launcher both arms will run"
echo "    $L   ($(wc -c < "$L") bytes)"

# Arm A needs TSP_KTX delivered. Without this the env file is inert.
if grep -q 'tsp_intocc.env' "$L" 2>/dev/null; then
    echo "    sources tsp_intocc.env: YES"
else
    echo "    sources tsp_intocc.env: NO"
    echo "  TSPSW_FATAL launcher_does_not_source_env"
fi

# Arm B needs the decompress flag honoured. Without TSP_DECOMP_V1 the export is
# still hardcoded, both arms run with decompression ON, and the pair is a fake.
if grep -q 'TSP_DECOMP_V1' "$L" 2>/dev/null; then
    echo "    carries TSP_DECOMP_V1:  YES"
    grep -n 'tsp_decomp_off' "$L" | head -2 | sed 's/^/      /'
else
    echo "    carries TSP_DECOMP_V1:  NO"
    echo "  TSPSW_FATAL launcher_not_decomp_patched"
fi

echo "--- state going in"
grep -nE '^[[:space:]]*(export[[:space:]]+)?TSP_KTX=' "$E" 2>/dev/null | sed 's/^/    /' \
  || echo "    no TSP_KTX line in the env file yet"
[ -f /mnt/SDCARD/tsp_decomp_off ] && echo "    tsp_decomp_off PRESENT" || echo "    tsp_decomp_off absent"
PEOF

if grep -q 'TSPSW_FATAL' "$PRE" 2>/dev/null; then
    WHY="$(sed -n 's/.*TSPSW_FATAL \(.*\)/\1/p' "$PRE" | head -1)"
    rm -f "$PRE"
    case "$WHY" in
      launcher_does_not_source_env)
        die "the live launcher does NOT source /mnt/SDCARD/tsp_intocc.env, so
  TSP_KTX could never reach the game. NOTHING WAS INSTALLED. That is the old
  bundled launcher; put the current one on this card first." ;;
      launcher_not_decomp_patched)
        die "the live launcher does not carry TSP_DECOMP_V1, so the decompress
  flag does nothing and BOTH arms would run with decompression on - the pair
  would be a fake. NOTHING WAS INSTALLED. Patch it first:

      TSP_DEV=$DEV sh ~/Downloads/tsp_decomp.sh patch" ;;
      no_ports_dir) die "/mnt/SDCARD/Roms/PORTS does not exist. Nothing was installed." ;;
      *) die "pre-flight failed: $WHY. Nothing was installed." ;;
    esac
fi
rm -f "$PRE"

hr "2. WRITING THE CAPTURE SCRIPT AND THE $PAIR PAIR"
# PAIR is prepended as a real assignment rather than interpolated, because the
# heredoc below is QUOTED on purpose: an unquoted one expands in the LOCAL
# shell first, where $E and $ARM are not set, and set -u kills the tool.
{ printf 'PAIR=%s\n' "$PAIR"
  cat <<'IEOF'
E=/mnt/SDCARD/tsp_intocc.env
P=/mnt/SDCARD/Roms/PORTS
C=/mnt/SDCARD/tsp_ktxcap.sh
mkdir -p /mnt/SDCARD/tsp_ktxcap 2>/dev/null

# Clear out EVERY previous arm, whatever version or pair. Only two switch
# entries exist at a time: leaving stale ones means picking the wrong arm in a
# menu of five Morrowinds, and their names promise configurations that are no
# longer what the tool is testing.
for f in "$P"/*.sh; do
    grep -q 'TSP_KTXSWITCH_V' "$f" 2>/dev/null && { rm -f "$f"; echo "  retired $(basename "$f")"; }
done

# ---------------------------------------------------------------- capture ----
cat > "$C" <<'CAPEOF'
#!/bin/sh
# TSP_KTXCAP_V2 - one 120 s capture per launch. $1 = the arm label.
ARM="${1:-?}"
OUT=/mnt/SDCARD/tsp_ktxcap
LOG=/mnt/SDCARD/data/ports/openmw/openmw_log.txt
mkdir -p "$OUT" 2>/dev/null
F="$OUT/$(date '+%Y%m%d-%H%M%S')_arm${ARM}.txt"

PID=""; W=0
while [ "$W" -lt 180 ]; do
    PID="$(pidof openmw-0.51 2>/dev/null)"
    PID="${PID%% *}"
    [ -n "$PID" ] && break
    W=$((W+1)); sleep 1
done

{
  printf '# TSP_KTXCAP_V2  arm=%s\n' "$ARM"
  printf '# when %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf '# card %s\n' "$(cat /etc/hostname 2>/dev/null)"
  printf '# waited %ss for the game\n' "$W"
  printf '# pid %s\n' "${PID:-NONE}"
} > "$F"

if [ -z "$PID" ]; then
    printf '# THE GAME NEVER APPEARED. This capture is void.\n' >> "$F"
    exit 1
fi

# Both knobs, read out of the RUNNING process and saved INTO this file. A proof
# printed somewhere else does not exist.
printf '\n# BOTH KNOBS, AS THE RUNNING PROCESS HAS THEM\n' >> "$F"
if [ -r "/proc/$PID/environ" ]; then
    tr '\0' '\n' < "/proc/$PID/environ" > /tmp/ktxcap_env.$$ 2>/dev/null
    for k in TSP_KTX OPENMW_DECOMPRESS_TEXTURES TSP_ICO_MAXOBJ LIBGL_SHRINK \
             LIBGL_MIPMAP LIBGL_AVOID16BITS LIBGL_RECOMPTEX LIBGL_NOMIPMAPS \
             OSG_THREADING TSP_RESTORE_V1; do
        v="$(grep "^$k=" /tmp/ktxcap_env.$$ 2>/dev/null | head -1)"
        if [ -n "$v" ]; then printf '  PRESENT  %s\n' "$v" >> "$F"
        else                  printf '  ABSENT   %s\n' "$k" >> "$F"; fi
    done
    rm -f /tmp/ktxcap_env.$$
else
    printf '  could not read /proc/%s/environ\n' "$PID" >> "$F"
fi
printf '  ktx load lines (the log caps this at 8): %s\n' \
    "$(grep -c 'TSP_KTX_V1 loaded' "$LOG" 2>/dev/null)" >> "$F"
grep -m1 'TSP_DECOMP_V1' /mnt/SDCARD/tsp_prog.txt 2>/dev/null | sed 's/^/  /' >> "$F"

# One canonical config line, derived from the environ reads above rather than
# from what the wrapper THOUGHT it set. Both knobs in one field so a single
# extractor can put the real configuration at the top of every column - the
# arm letter in the filename is a label, this is the evidence.
CDC=off
grep -q '^  PRESENT  OPENMW_DECOMPRESS_TEXTURES=' "$F" 2>/dev/null && CDC=on
CKX="$(sed -n 's/^  PRESENT  TSP_KTX=\([01]\).*/\1/p' "$F" 2>/dev/null | head -1)"
printf '  CONFIG  ktx=%s dec=%s\n' "${CKX:-?}" "$CDC" >> "$F"

printf '\n# t rss_kb vsz_kb threads memavail_kb memfree_kb cached_kb majflt utime stime\n' >> "$F"

T=0
while [ "$T" -lt 120 ]; do
    kill -0 "$PID" 2>/dev/null || break
    RSS=0; VSZ=0; THR=0
    while read -r k v _; do
        case "$k" in VmRSS:) RSS=$v ;; VmSize:) VSZ=$v ;; Threads:) THR=$v ;; esac
    done < "/proc/$PID/status"
    MA=0; MF=0; CA=0
    while read -r k v _; do
        case "$k" in MemAvailable:) MA=$v ;; MemFree:) MF=$v ;; Cached:) CA=$v ;; esac
    done < /proc/meminfo
    # comm is parenthesised and may contain spaces, so cut at the LAST ") ".
    # After that majflt is field 10, utime 12, stime 13.
    read -r STATLINE < "/proc/$PID/stat"
    set -- ${STATLINE##*) }
    MJ="${10}"; UT="${12}"; ST="${13}"
    case "$MJ" in ''|*[!0-9]*) MJ=0 ;; esac
    printf '%s %s %s %s %s %s %s %s %s %s\n' \
        "$T" "$RSS" "$VSZ" "$THR" "$MA" "$MF" "$CA" "$MJ" "$UT" "$ST" >> "$F"
    T=$((T+1)); sleep 1
done

# ONE awk pass at the end - not per sample. Splits PLAY from QUIT at the last
# sample still holding full thread count, and ignores 0 readings: /proc can be
# read mid-update and answer 0, and a 0 taken as a floor makes CONSUMED the
# entire start value.
awk '
/^#/ || NF < 10 { next }
{ i++; t[i]=$1; rss[i]=$2+0; th[i]=$4+0; ma[i]=$5+0; ca[i]=$7+0; mj[i]=$8+0
  if (th[i] > mx) mx = th[i] }
END {
  if (!i) { print ""; print "# NO SAMPLES - this capture is void."; exit }
  e = i
  for (j = i; j >= 1; j--) if (th[j] >= mx - 1) { e = j; break }
  pk = 0; sa = 0; fa = 0; fc = 0
  for (j = 1; j <= e; j++) {
    if (rss[j] > pk) pk = rss[j]
    if (ma[j] > 0) { if (!sa) sa = ma[j]; if (!fa || ma[j] < fa) fa = ma[j] }
    if (ca[j] > 0 && (!fc || ca[j] < fc)) fc = ca[j]
  }
  ps = t[e] - t[1]; pf = mj[e] - mj[1]
  qs = t[i] - t[e]; qf = mj[i] - mj[e]
  print ""
  print "# SUMMARY - PLAY PHASE, teardown excluded. These are the numbers."
  printf "  PLAY secs  %d\n", ps
  printf "  PLAY peak VmRSS MB  %d\n", pk / 1024
  printf "  PLAY start MemAvail MB  %d\n", sa / 1024
  printf "  PLAY floor MemAvail MB  %d\n", fa / 1024
  printf "  PLAY CONSUMED MB  %d\n", (sa - fa) / 1024
  printf "  PLAY floor Cached MB  %d\n", fc / 1024
  printf "  PLAY major faults  %d\n", pf
  printf "  PLAY faults per sec  %.1f\n", (ps > 0 ? pf / ps : 0)
  print ""
  print "# SUMMARY - QUIT PHASE. Teardown. NOT gameplay - printed to be ignored."
  printf "  QUIT secs  %d\n", qs
  printf "  QUIT major faults  %d\n", qf
  printf "  (peak threads %d, play ended at sample %d of %d)\n", mx, e, i
  print ""
  print "# CONSUMED is start minus floor MemAvailable. A floor alone is not a"
  print "# memory number: two runs that began from different free memory are"
  print "# not comparable by their floors."
}
' "$F" >> "$F"
CAPEOF
chmod +x "$C" 2>/dev/null

# ------------------------------------------------------------------- arms -----
# One template. __KTX__ is the TSP_KTX value, __DECOMP__ is on or off, __ARM__
# is the label that ends up in the capture filename.
cat > /tmp/tsp_sw_tpl <<'WEOF'
#!/bin/sh
# TSP_KTXSWITCH_V2 - arm __ARM__ : TSP_KTX=__KTX__, decompression __DECOMP__
# The two shippable configurations. The other two are already dead: ASTC with
# decompression on is pointless (the engine expands the .ktx anyway), and DDS
# with decompression off is the worst measured config.
ARM=__ARM__
KTX=__KTX__
DECOMP=__DECOMP__

# TSP_KTX rides in the env file the launcher sources at the top of every run.
E=/mnt/SDCARD/tsp_intocc.env
[ -f "$E" ] || : > "$E"
cp -f "$E" "$E.bak" 2>/dev/null
grep -vE '^[[:space:]]*(export[[:space:]]+)?TSP_KTX=' "$E" > "$E.new" 2>/dev/null
printf 'export TSP_KTX=%s\n' "$KTX" >> "$E.new"
mv -f "$E.new" "$E"

# The decompress arm is the flag file TSP_DECOMP_V1 reads in the launcher.
if [ "$DECOMP" = off ]; then : > /mnt/SDCARD/tsp_decomp_off
else                          rm -f /mnt/SDCARD/tsp_decomp_off; fi

rm -f /mnt/SDCARD/ARM-IS-A /mnt/SDCARD/ARM-IS-B
: > "/mnt/SDCARD/ARM-IS-$ARM"
printf 'TSP_KTXSWITCH_V2 arm=%s TSP_KTX=%s decompress=%s at %s\n' \
    "$ARM" "$KTX" "$DECOMP" "$(date '+%F %T')" >> /mnt/SDCARD/tsp_prog.txt

# Arm the capture. It waits for the game itself, so it is started BEFORE the
# handoff and keeps running across it.
if [ -x /mnt/SDCARD/tsp_ktxcap.sh ]; then
    /mnt/SDCARD/tsp_ktxcap.sh "$ARM" >/dev/null 2>&1 &
fi

# Hand off to the real launcher. Located at runtime, and our own wrappers are
# skipped by MARKER not by name - arm A is called DDS and a name filter would
# miss it, so arm B would hand off to arm A instead of to the game.
D="$(dirname "$0")"
[ -d "$D" ] || D=/mnt/SDCARD/Roms/PORTS
L=""
if [ -f "$D/Morrowind.sh" ] && ! grep -q 'TSP_KTXSWITCH_V' "$D/Morrowind.sh" 2>/dev/null; then
    L="$D/Morrowind.sh"
else
    for f in "$D"/*.sh; do
        grep -q 'TSP_KTXSWITCH_V' "$f" 2>/dev/null && continue
        grep -q '/mnt/SDCARD/data/ports/openmw' "$f" 2>/dev/null && { L="$f"; break; }
    done
fi
if [ -z "$L" ]; then
    printf 'TSP_KTXSWITCH_V2 NO LAUNCHER FOUND in %s - nothing started\n' "$D" \
        >> /mnt/SDCARD/tsp_prog.txt
    exit 1
fi
printf 'TSP_KTXSWITCH_V2 handing off to %s\n' "$L" >> /mnt/SDCARD/tsp_prog.txt
if [ -x "$L" ]; then exec "$L" "$@"; else exec sh "$L" "$@"; fi
WEOF

# label | TSP_KTX | decompress | menu filename
case "$PAIR" in
  ab) S1="A|0|on|Morrowind A - DDS decompress ON.sh"
      S2="B|1|off|Morrowind B - ASTC decompress OFF.sh" ;;
  cd) S1="C|1|on|Morrowind C - ASTC decompress ON.sh"
      S2="D|1|off|Morrowind D - ASTC decompress OFF.sh" ;;
  *)  echo "  TSPSW_FATAL bad_pair"; exit 1 ;;
esac
W1=""; W2=""
for spec in "$S1" "$S2"; do
    lab="${spec%%|*}";  r="${spec#*|}"
    ktx="${r%%|*}";     r="${r#*|}"
    dcp="${r%%|*}";     fn="${r#*|}"
    sed -e "s/__ARM__/$lab/g" -e "s/__KTX__/$ktx/g" -e "s/__DECOMP__/$dcp/g" \
        /tmp/tsp_sw_tpl > "$P/$fn"
    chmod +x "$P/$fn" 2>/dev/null
    if [ -z "$W1" ]; then W1="$P/$fn"; else W2="$P/$fn"; fi
done
rm -f /tmp/tsp_sw_tpl

echo "--- written"
for f in "$C" "$W1" "$W2"; do
    if [ -s "$f" ]; then
        printf '    %-38s %6s bytes  %s\n' "$(basename "$f")" "$(wc -c < "$f")" \
            "$([ -x "$f" ] && echo executable || echo NOT-EXECUTABLE)"
    else
        printf '    %-38s MISSING\n' "$(basename "$f")"
    fi
done

echo "--- do they parse under THIS card's shell"
for f in "$C" "$W1" "$W2"; do
    if sh -n "$f" 2>/dev/null; then printf '    %-38s PARSES\n' "$(basename "$f")"
    else printf '    %-38s SYNTAX ERROR:\n' "$(basename "$f")"; sh -n "$f" 2>&1 | sed 's/^/      /'; fi
done

echo "--- what each arm says it sets"
for f in "$W1" "$W2"; do
    printf '    %-38s %s %s %s\n' "$(basename "$f")" \
        "$(grep -m1 '^ARM=' "$f")" "$(grep -m1 '^KTX=' "$f")" "$(grep -m1 '^DECOMP=' "$f")"
done

echo "--- each arm finds the real launcher, not the other arm"
for f in "$W1" "$W2"; do
    D="$P"; L=""
    if [ -f "$D/Morrowind.sh" ] && ! grep -q 'TSP_KTXSWITCH_V' "$D/Morrowind.sh" 2>/dev/null; then
        L="$D/Morrowind.sh"
    else
        for g in "$D"/*.sh; do
            grep -q 'TSP_KTXSWITCH_V' "$g" 2>/dev/null && continue
            grep -q '/mnt/SDCARD/data/ports/openmw' "$g" 2>/dev/null && { L="$g"; break; }
        done
    fi
    printf '    %-38s -> %s\n' "$(basename "$f")" "${L:-NOTHING FOUND}"
done

echo "--- the env file, unchanged by install"
sed 's/^/      /' "$E" 2>/dev/null
[ -f /mnt/SDCARD/tsp_decomp_off ] && echo "      tsp_decomp_off PRESENT" || echo "      tsp_decomp_off absent"
echo "    (install sets neither knob. The arms do, when you pick one.)"
IEOF
} | rin 2>&1

printf '\n'
hr "3. WHAT TO DO ON THE CARD"
if [ "$PAIR" = cd ]; then
    say "Two entries, ASTC ON in BOTH. Only the decompress flag differs:"
    printf '\n'
    say "    Morrowind C - ASTC decompress ON     ktx=1, engine expands them"
    say "    Morrowind D - ASTC decompress OFF    ktx=1, uploaded compressed"
    printf '\n'
    say "Single variable, so this one is clean. If C matches D, the flag does"
    say "not matter with ASTC installed and it can stay at its shipped default."
    say "If D wins, decompression has to stay off for the conversion to pay."
else
    say "Two entries, one variable each side of the ship decision:"
    printf '\n'
    say "    Morrowind A - DDS decompress ON      no conversion needed at all"
    say "    Morrowind B - ASTC decompress OFF    the 45-60 minute conversion"
fi
printf '\n'
say "Run them alternating - first, second, first, second - so a warm card or a"
say "bad walk cannot land entirely on one arm. Same route, and keep the runs"
say "the same LENGTH: peak RSS and CONSUMED both climb the whole time, so a"
say "36 s run against an 82 s one tells you nothing. Two minutes each is what"
say "the capture window is sized for."
printf '\n'
say "Then:"
printf '\n'
printf '      TSP_DEV=%s sh ~/Downloads/tsp_ktxswitch.sh pull\n' "$DEV"
printf '\n'
say "The plain Morrowind entry inherits whichever arm ran last, for both knobs."
printf '      TSP_DEV=%s sh ~/Downloads/tsp_ktxswitch.sh state\n' "$DEV"
say "says which, and"
printf '      TSP_DEV=%s sh ~/Downloads/tsp_ktxswitch.sh check\n' "$DEV"
say "confirms every ktx setting on the card in one pass."
printf '\n'
exit 0
