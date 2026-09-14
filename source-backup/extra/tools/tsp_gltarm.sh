#!/bin/sh
# tsp_gltarm.sh - arm the GL timing shim so the next run you were going to do
# anyway also says what the draw block is made of.
#
#   plan    read-only: show the anchor and the exact block to be inserted
#   go      insert it, backed up and syntax-checked, and arm the flag
#   on/off  flip the flag only - no launcher change, no backup churn
#   pull    fetch tsp_gltime.txt and rank the per-call totals
#   undo    remove the block and restore the launcher from its backup
#
# ---------------------------------------------------------------------------
# WHY, AND WHY IT COSTS NO EXTRA PLAY SESSION
#
# On .21 (the base TSP) draw is 54.1 ms of an 80.3 ms render - 67% of the frame -
# while resid is only 10.2 against 19.6 on .12. Nothing yet says what those
# 54 ms consist of, and every other lever on that card is exhausted: no GPU
# devfreq at all, cpufreq already at performance/2.0 GHz on all four cores,
# walk-phase major faults a median of 0.
#
# libtsp_gltime.so answers it and is already on the card (32,144 bytes) - but it
# is NOT in the preload chain. Morrowind.sh line ~1071 builds TSP_LD_PRELOAD as
# warm : fullscreen_scaler : gl4es, a plain assignment, so exporting
# TSP_LD_PRELOAD from tsp_intocc.env cannot get in: line 1071 overwrites it.
# Hence a launcher block, gated on a flag file exactly like tsp_noscaler.
#
# Once armed it rides along with any launch. Arm it before the navmesh /
# first-load work and that run produces the draw attribution for free.
#
# WHERE IT GOES IN THE CHAIN, AND WHY FIRST
#
# The shim forwards each call to the next library below it, and it says so in
# its own output:
#     TSP_GLT *** MISSING SYMBOL %s - not in the chain below us, calls are
#     being DROPPED
# So it has to sit AHEAD of gl4es. Putting it ahead of the scaler too means
# SwapWindow is measured with the scaler's cost inside it, which is how the
# 9.91 ms/frame figure on .12 was obtained.
#
# THE ANCHOR
#
# Inserted immediately before the exec line
#     LD_PRELOAD="$TSP_LD_PRELOAD" "$OPENMW_BIN" \
# which is unique in the file and must exist for the game to start at all.
# NOT anchored on the TSP_AB_SWITCH_V1 end marker: that block is only present
# on a card where tsp_ab.sh install has been run, and the two cards carry
# different launchers (.12 md5 506d1893 POSIXFIX=0, .21 md5 6cded8f8
# POSIXFIX=1). The block itself is POSIX so it parses under .21 busybox ash.
#
# THE KNOBS, read off the shim with strings rather than guessed:
#     TSP_GLT_MS      slow-frame threshold in ms   (default here 45)
#     TSP_GLT_EVERY   emit a MEAN line every N frames (default here 600)
#     TSP_GLT_OUT     output path  (the shim own default is
#                     /mnt/SDCARD/tsp_gltime.txt)
#
# READING THE OUTPUT: gl= is a SUM of per-call times and can exceed total=.
# Never subtract it from total=; an earlier pass printed "-19.1 ms not in GL"
# doing exactly that.
# ---------------------------------------------------------------------------

set -u
# Device address, in order: an explicit DEV= in the environment, then $TSP_DEV
# as `tsp_net.sh each` sets it, then ~/.tsp_dev as `tsp_net.sh use` writes it,
# then the old hardcoded default. Every line returns 0 so a missing ~/.tsp_dev
# cannot trip set -e.
DEV="${DEV:-${TSP_DEV:-}}"
if [ -z "${DEV}" ] && [ -r "$HOME/.tsp_dev" ]; then DEV="$(cat "$HOME/.tsp_dev")"; fi
[ -n "${DEV}" ] || DEV="root@192.168.1.12"

# WHICH CONSOLE THIS IS. Printed on every run, and into the saved log.
[ -n "${TSP_NAME:-}" ] || TSP_NAME="$(awk -F'\t' -v h="$DEV" '$2==h {print $1}' "$HOME/.tsp_hosts" 2>/dev/null | head -1)"
printf '\n  ==================  DEVICE: %s  (%s)  ==================\n' "${TSP_NAME:-UNNAMED}" "$DEV"

LAUNCH="/mnt/SDCARD/Roms/PORTS/Morrowind.sh"
FLAG="/mnt/SDCARD/tsp_gltime_on"
OUT="/mnt/SDCARD/tsp_gltime.txt"
MARK="TSP_GLTARM_V1"
SSHO="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes -o LogLevel=ERROR"
STAMP="$(date +%Y%m%d-%H%M%S)"

MODE="${1:-plan}"
case "$MODE" in plan | go | on | off | pull | undo) ;;
*) printf 'usage: %s plan | go | on | off | pull | undo\n' "$0"; exit 2 ;; esac

say() { printf '  %s\n' "$*"; }
hr()  { printf '\n########## %s ##########\n' "$1"; }
die() { printf '\n  STOPPING: %s\n  Nothing was changed.\n\n' "$*"; exit 1; }

# The probe goes as base64 inside the ssh COMMAND and is decoded to a file on
# the device, then run with </dev/null. Delivered on stdin, anything it invokes
# that reads stdin eats the rest of the script - which is how the scope probe
# got truncated on .21, where /bin/bash is busybox and does not know --version.
rin() {
    _b64="$(base64 | tr -d '\n')"
    ssh -n $SSHO "$DEV" "T=/tmp/tsp_gltarm.\$\$
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
  passwords on purpose, so a card you only typed a password into looks dead from
  in here. Install the key once:
      sh ~/Downloads/tsp_net.sh key $DEV" ;;
    *)  die "cannot reach $DEV. ssh said: $_pf" ;;
esac

# The block, written once here and reused by plan and go so the two can never
# drift apart. ${GAMEDIR} stays literal - it is the launcher own variable.
BLOCK='# =================== '"$MARK"' =====================================
# Prepend the GL timing shim when the flag file exists. FIRST in the chain: the
# shim forwards each call to the next library below it and prints
#   TSP_GLT *** MISSING SYMBOL ... calls are being DROPPED
# for anything it wraps that is not reachable underneath. Ahead of the scaler
# as well, so SwapWindow is measured with the scaler cost inside it.
if [ -f /mnt/SDCARD/tsp_gltime_on ]; then
  tsp_glt_lib="$GAMEDIR/lib/libtsp_gltime.so"
  if [ -f "$tsp_glt_lib" ]; then
    TSP_LD_PRELOAD="$tsp_glt_lib:$TSP_LD_PRELOAD"
    export TSP_LD_PRELOAD
    TSP_GLT_MS="${TSP_GLT_MS:-45}";    export TSP_GLT_MS
    TSP_GLT_EVERY="${TSP_GLT_EVERY:-600}"; export TSP_GLT_EVERY
    TSP_GLT_OUT="${TSP_GLT_OUT:-/mnt/SDCARD/tsp_gltime.txt}"; export TSP_GLT_OUT
    echo "'"$MARK"' armed ms=$TSP_GLT_MS every=$TSP_GLT_EVERY out=$TSP_GLT_OUT"
    echo "'"$MARK"' preload=[$TSP_LD_PRELOAD]"
  else
    echo "'"$MARK"' flag present but $tsp_glt_lib is missing - NOT armed"
  fi
fi
# =================== end '"$MARK"' ================================='

# ===================================================================== undo ===
if [ "$MODE" = "undo" ]; then
    hr "REMOVING THE BLOCK AND DISARMING"
    rin <<UEOF
L='$LAUNCH'
B="\$(ls -1tr "\$L".before-gltarm-* 2>/dev/null | head -1)"
if [ -n "\$B" ]; then
    cp -p "\$B" "\$L" && printf '    launcher restored from %s\n' "\$B"
else
    printf '    no backup found - leaving %s alone\n' "\$L"
fi
rm -f '$FLAG' && echo "    flag removed"
printf '    %s markers now in the launcher: %s\n' '$MARK' "\$(grep -c '$MARK' "\$L" 2>/dev/null)"
UEOF
    printf '\n'; exit 0
fi

# ================================================================= on / off ===
if [ "$MODE" = "on" ] || [ "$MODE" = "off" ]; then
    hr "FLAG ONLY - THE LAUNCHER IS NOT TOUCHED"
    if [ "$MODE" = "on" ]; then
        rin <<AEOF
grep -q '$MARK' '$LAUNCH' 2>/dev/null \\
  || { echo "    the launcher has no $MARK block - run go first"; exit 1; }
touch '$FLAG' && echo "    ARMED. The next launch will write $OUT"
AEOF
    else
        rin <<BEOF
rm -f '$FLAG' && echo "    DISARMED. The shim will not be preloaded."
BEOF
    fi
    printf '\n'; exit 0
fi

# ====================================================================== pull ===
if [ "$MODE" = "pull" ]; then
    hr "WHAT THE FRAME IS MADE OF"
    rin <<PEOF
F='$OUT'
[ -f "\$F" ] || { echo "    no \$F - was it armed before the launch?"; \\
                  echo "    arm:  sh ~/Downloads/tsp_gltarm.sh on"; exit 1; }
printf '    %s bytes, %s lines\n' "\$(wc -c < "\$F")" "\$(wc -l < "\$F")"
echo "  --- the start line (what it was configured with) ---"
grep -m1 'TSP_GLT start' "\$F" | sed 's/^/    /'
echo "  --- the LAST MEAN line: per-call totals, ranked as the shim printed them"
echo "      gl= is a SUM of per-call times and can exceed total=. Do not subtract."
grep 'MEAN' "\$F" | tail -1 | tr '|' '\n' | sed 's/^ */      /'
echo "  --- how many slow frames it caught ---"
printf '    SLOW lines: %s\n' "\$(grep -c 'SLOW' "\$F" 2>/dev/null)"
echo "  --- the three worst, by total ---"
grep 'SLOW' "\$F" | sort -t= -k3 -rn | head -3 | sed 's/^/      /'
echo "  --- any dropped-call warning, which would invalidate the numbers ---"
grep 'MISSING SYMBOL' "\$F" | sort -u | head -5 | sed 's/^/      /'
PEOF
    printf '\n'
    exit 0
fi

# ================================================================ plan / go ===
hr "1. THE ANCHOR, AS IT IS ON THIS CARD"
rin <<A1EOF
L='$LAUNCH'
[ -f "\$L" ] || { echo "    NO LAUNCHER AT \$L"; exit 1; }
printf '    md5 %s   %s lines\n' "\$(md5sum "\$L" | cut -c1-8)" "\$(wc -l < "\$L")"
N="\$(grep -c 'LD_PRELOAD="\$TSP_LD_PRELOAD" "\$OPENMW_BIN"' "\$L" 2>/dev/null)"
printf '    exec anchor found %s time(s) - it must be exactly 1\n' "\$N"
grep -n 'LD_PRELOAD="\$TSP_LD_PRELOAD" "\$OPENMW_BIN"' "\$L" | sed 's/^/      /'
printf '    %s already present: %s\n' '$MARK' "\$(grep -c '$MARK' "\$L" 2>/dev/null)"
echo "  --- the shim itself ---"
S=/mnt/SDCARD/data/ports/openmw/lib/libtsp_gltime.so
if [ -f "\$S" ]; then printf '    %s  %s bytes\n' "\$S" "\$(wc -c < "\$S")"
else echo "    SHIM MISSING: \$S - nothing to arm"; fi
echo "  --- the chain it will be prepended to ---"
grep -n 'TSP_LD_PRELOAD="\$GAMEDIR' "\$L" | sed 's/^/      /'
A1EOF

hr "2. THE BLOCK THAT WILL BE INSERTED, VERBATIM"
printf '%s\n' "$BLOCK" | sed 's/^/    /'

if [ "$MODE" = "plan" ]; then
    printf '\n'
    hr "PLAN ONLY - NOTHING WAS WRITTEN"
    say "go backs the launcher up, inserts this, checks it parses with THIS"
    say "card own /bin/sh, restores the backup if it does not, and arms the flag."
    printf '\n      sh %s go\n\n' "$0"
    exit 0
fi

# ======================================================================== go ===
hr "3. INSERTING"
printf '%s\n' "$BLOCK" > /tmp/tsp_gltarm_block.$$
B64="$(base64 < /tmp/tsp_gltarm_block.$$ | tr -d '\n')"
rm -f /tmp/tsp_gltarm_block.$$

GO_OUT="/tmp/tsp_gltarm_go.$$"
rin 2>&1 <<GEOF | tee "$GO_OUT"
L='$LAUNCH'
[ -f "\$L" ] || { echo "    no launcher"; exit 1; }
if grep -q '$MARK' "\$L" 2>/dev/null; then
    echo "    $MARK is already in the launcher - not inserting a second copy."
    echo "    Arm it with:  sh ~/Downloads/tsp_gltarm.sh on"
    exit 0
fi
N="\$(grep -c 'LD_PRELOAD="\\\$TSP_LD_PRELOAD" "\\\$OPENMW_BIN"' "\$L" 2>/dev/null)"
if [ "\$N" != "1" ]; then
    echo "    REFUSING: the exec anchor appears \$N times, expected exactly 1."
    echo "    Nothing was changed."
    exit 1
fi
cp -p "\$L" "\$L.before-gltarm-$STAMP" \\
  && printf '    backed up to %s.before-gltarm-%s\n' "\$L" '$STAMP'

printf '%s' '$B64' | base64 -d > /tmp/gltblock.\$\$
# awk, not sed: the block is multi-line and carries slashes and quotes.
awk -v bf=/tmp/gltblock.\$\$ '
  /LD_PRELOAD/ && /OPENMW_BIN/ && !done {
      while ((getline l < bf) > 0) print l
      close(bf)
      done = 1
  }
  { print }
' "\$L" > "\$L.gltnew" || { echo "    awk failed"; rm -f "\$L.gltnew" /tmp/gltblock.\$\$; exit 1; }

# Verify the block is actually IN the candidate before anything is moved. The
# first version trusted awk, the pattern missed, and `sh -n` then passed on an
# unchanged file and printed "inserted" - a success message for a no-op.
MO="\$(grep -c '^# =================== $MARK ' "\$L.gltnew" 2>/dev/null)"
MC="\$(grep -c '^# =================== end $MARK' "\$L.gltnew" 2>/dev/null)"
if [ "\$MO" != "1" ] || [ "\$MC" != "1" ]; then
    echo "    REFUSING: the block is not in the candidate file"
    echo "    (open banner \$MO, close banner \$MC, both must be 1)."
    echo "    The launcher was NOT replaced."
    rm -f "\$L.gltnew"
    exit 1
fi
rm -f /tmp/gltblock.\$\$

# Parse with THIS card own /bin/sh. .21 is busybox ash and .12 is bash; a block
# that parses on one is not proof for the other.
if sh -n "\$L.gltnew" 2>/tmp/gltsyn.\$\$; then
    mv "\$L.gltnew" "\$L"
    chmod +x "\$L"
    echo "    inserted and it PARSES under this card /bin/sh"
else
    echo "    SYNTAX ERROR - the launcher was NOT replaced:"
    sed 's/^/      /' /tmp/gltsyn.\$\$
    rm -f "\$L.gltnew"
    rm -f /tmp/gltsyn.\$\$
    exit 1
fi
rm -f /tmp/gltsyn.\$\$

echo "  --- reading it back off the device ---"
grep -n -A3 '$MARK armed' "\$L" | sed 's/^/      /'
printf '    banners now: open %s, close %s (1 each)\n' \
  "\$(grep -c '^# =================== $MARK ' "\$L")" \
  "\$(grep -c '^# =================== end $MARK' "\$L")"
touch '$FLAG' && echo "    ARMED - the flag file is in place"
GEOF
if grep -qE "REFUSING|SYNTAX ERROR|no launcher|UNEXPECTED" "$GO_OUT"; then
    rm -f "$GO_OUT"
    printf '\n'
    die "the device refused the change - see the lines above. The launcher is
  untouched and the flag was not set, so nothing is armed."
fi
rm -f "$GO_OUT"

printf '\n'
say "It is armed now, so it rides along with whatever you launch next - the"
say "navmesh and first-load run will produce the draw attribution for free."
printf '\n'
say "After that run:"
printf '\n      sh %s pull\n\n' "$0"
say "Turn it off without touching the launcher:  sh $0 off"
say "Remove it entirely:                         sh $0 undo"
printf '\n'
