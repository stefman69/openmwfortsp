#!/bin/sh
# tsp_icoktx.sh - turn two CONFIRMED fixes back on. They are off right now.
#
#   plan      show every change, write nothing
#   go        apply, verify by reading back      <-- THE ONE TO RUN
#   undo      back out everything this wrote
#
# ---------------------------------------------------------------------------
# WHAT IS ACTUALLY WRONG, AND IT IS NOT A NEW BUG
#
# /proc/<pid>/environ of the running game says:
#
#     absent   TSP_ICO_MAXOBJ
#     absent   TSP_KTX
#     absent   TSP_CRASH_OUT
#     absent   LIBGL_NOBANNER
#
# Those four exist ONLY as exports in /mnt/SDCARD/tsp_iotune.conf, and nothing
# sources that file. The launcher says so itself at lines 10-14. Two of them are
# fixes that were measured and confirmed and are simply not running:
#
# 1. TSP_ICO_MAXOBJ=4 - "RESULT-ico-maxobj-was-the-hitch-20260908": the
#    IncrementalCompileOperation was compiling ONE GL object per frame during
#    gameplay, so every texture and geometry a cell streamed in trickled out one
#    per frame and left a long tail of frames each carrying compile work.
#    Setting it to 4 gave "next to no frame hitching" in three of the worst
#    known spots, confirmed in game. THE FRAME-HITCH FIX. Currently unset.
#
# 2. TSP_KTX=1 - "RESULT-astc-ktx-textures-are-the-memory-fix-20260910":
#    one-variable A/B on the same route, same build, same session:
#        TSP_KTX=1 (ASTC): avail floor 192 MB, cached peak 302 MB, rss peak 584
#        TSP_KTX=0 (DDS) : avail floor 105 MB, cached peak 245 MB, rss peak 646
#    +87 MB available, +57 MB page cache, -62 MB RSS. Currently unset, and the
#    4481 converted .ktx on the card are being ignored while the DDS in the
#    BSAs are read instead.
#
# The last run measured Cached at 78 MB and MemAvailable at 154 MB - much closer
# to the DDS arm than the ASTC arm. Consistent with the fix being off.
#
# WHY IT WENT OFF. SHIP-STATE-20260909 recorded the launcher sourcing that conf
# at six places. A grep on 09-11 found ZERO references in either launcher. The
# mod manager regenerates Morrowind.sh, and this launcher has documented form
# for losing TSP blocks - TSP_RINGARM_V2's own comment says V1 was lost and the
# launcher reverted to unset lines, leaving the profiler on compiled defaults.
# Same failure, different block. Days were then spent hunting sound, swap and
# the heap while the actual confirmed fix sat switched off.
#
# THE THIRD CHANGE, and it is why maxobj may not have bitten hard even when set
#
# [Cells] target framerate = 120. That number is not a frame cap - OSG computes
# the ICO's TIME budget from it:
#     targetFrameTime = 1 / target framerate            120 -> 8.3 ms
#     availableTime   = max((targetFrameTime - elapsedThisFrame) * 0.5, 1 ms)
#     compileTime     = availableTime * 0.5
# The ICO runs inside the draw traversal, ~15 ms into a 37 ms frame. With
# target 120 that is max((8.3 - 15) * 0.5, 1) = the 1 ms FLOOR, so 0.5 ms of
# compile per frame and maxobj=4 only bites if four objects fit in 0.5 ms. At
# target 30: (33.3 - 15) * 0.5 = 9.2 ms -> 4.6 ms of compile per frame, and the
# post-transition backlog drains in a handful of frames instead of a long tail.
# The device runs at 26-27 fps; 120 was never a reachable target.
#
# NOT DONE HERE, deliberately:
#  - OPENMW_DEBUG_LEVEL is left exactly as it is. The diagnostics stay on.
#  - LIBGL_TSP_LOG, TSP_SNDWARM_LOG, TSP_RECORDMEM stay off - debug only.
#  - TSP_FPS_OVERLAY is left alone; the conf wants 0 and that is a preference.
#  - The heapfix env vars and preload settings are backed out, since the trim
#    proved the heap is live and neither ever got a number.
# ---------------------------------------------------------------------------

set -u
# Device address, in order: an explicit DEV= in the environment, then $TSP_DEV
# as `tsp_net.sh each` sets it, then ~/.tsp_dev as `tsp_net.sh use` writes it,
# then the old hardcoded default. Two cards do not share an address, and a tool
# pointed at the wrong one reports that card state as if it were this one.
# Every line here returns 0, so a missing ~/.tsp_dev cannot trip set -e.
DEV="${DEV:-${TSP_DEV:-}}"
if [ -z "${DEV}" ] && [ -r "$HOME/.tsp_dev" ]; then DEV="$(cat "$HOME/.tsp_dev")"; fi
[ -n "${DEV}" ] || DEV="root@192.168.1.12"
G="/mnt/SDCARD/data/ports/openmw"
CFG="$G/config/settings.cfg"
ENVF="/mnt/SDCARD/tsp_intocc.env"
LOG="$G/openmw_log.txt"
SSHO="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes"
STAMP="$(date +%Y%m%d-%H%M%S)"

MODE="${1:-plan}"
case "$MODE" in plan | go | undo) ;;
*) printf 'usage: %s plan | go | undo\n' "$0"; exit 2 ;; esac

say() { printf '  %s\n' "$*"; }
hr()  { printf '\n########## %s ##########\n' "$1"; }
r()   { ssh $SSHO -n "$DEV" "$1" 2>&1; }
rq()  { ssh $SSHO -n "$DEV" "$1" 2>/dev/null; }
rin() { ssh $SSHO "$DEV" "sh -s" 2>&1; }
abort() { printf '\n  STOPPING: %s\n  Nothing further was changed.\n\n' "$*"; exit 1; }

_pf="$(ssh $SSHO -n "$DEV" "echo ok" 2>&1)"
case "$_pf" in
    *ok*) ;;
    *"Permission denied"*|*"publickey"*|*"Too many authentication"*)
        abort "ssh AUTH failed for $DEV. Every tool here uses BatchMode and
  refuses passwords on purpose, so a card you only typed a password into looks
  dead from in here. Install the key once:
      sh ~/Downloads/tsp_net.sh key $DEV" ;;
    *)  abort "cannot reach $DEV - is the handheld awake and on wifi?
  ssh said: $_pf" ;;
esac

# ======================================================================= undo =
if [ "$MODE" = "undo" ]; then
    hr "BACKING OUT EVERYTHING tsp_restore WROTE"
    rin <<UEOF
E='$ENVF'
B=""
for c in \$(ls -1tr "\$E".before-restore-* 2>/dev/null); do
    grep -q 'TSP_RESTORE_V1' "\$c" 2>/dev/null || { B="\$c"; break; }
done
if [ -n "\$B" ]; then cp -p "\$B" "\$E" && printf '    env restored from %s\n' "\$B"
elif [ -f "\$E" ]; then rm -f "\$E" && echo "    env file removed"
else echo "    no env file"; fi

C='$CFG'
B2="\$(ls -1tr "\$C".before-restore-* 2>/dev/null | head -1)"
if [ -n "\$B2" ]; then cp -p "\$B2" "\$C" && printf '    settings restored from %s\n' "\$B2"
else echo "    no settings backup from tsp_restore"; fi
grep -n -e 'target framerate' -e 'preload cell cache max' -e 'preload cell expiry delay' "\$C" | sed 's/^/      /'
UEOF
    printf '\n'; exit 0
fi

# ================================================================ plan and go =
hr "1. WHAT THE GAME CURRENTLY HAS - and what it is missing"
rin <<'PEOF'
P="$(pidof openmw-0.51 2>/dev/null | awk '{print $1}')"
[ -n "$P" ] || P="$(ps -e 2>/dev/null | grep '[o]penmw-0.51' | awk '{print $1}' | head -1)"
[ -n "$P" ] || P="$(ps 2>/dev/null | grep '[o]penmw-0.51' | awk '{print $1}' | head -1)"
if [ -n "$P" ]; then
    tr '\0' '\n' < "/proc/$P/environ" 2>/dev/null > /tmp/tspe.$$
    for k in TSP_ICO_MAXOBJ TSP_KTX TSP_CRASH_OUT LIBGL_NOBANNER TSP_RESTORE_V1; do
        v="$(grep "^$k=" /tmp/tspe.$$ 2>/dev/null | head -1)"
        if [ -n "$v" ]; then printf '    PRESENT  %s\n' "$v"
        else                 printf '    ABSENT   %s\n' "$k"; fi
    done
    rm -f /tmp/tspe.$$
else
    echo "    game not running - launch it and re-run plan to see the environ,"
    echo "    or just run go; the fix does not depend on reading it first."
fi
echo "--- what tsp_iotune.conf thinks it is setting (it is sourced by nothing)"
grep -n -e 'TSP_ICO_MAXOBJ' -e 'TSP_KTX' -e 'TSP_CRASH_OUT' -e 'LIBGL_NOBANNER' \
     /mnt/SDCARD/tsp_iotune.conf 2>/dev/null | sed 's/^/    /'
echo "--- and the launcher still does not reference it"
grep -c 'tsp_iotune' /mnt/SDCARD/Roms/PORTS/Morrowind.sh 2>/dev/null | sed 's/^/    references in Morrowind.sh: /'
PEOF

hr "2. THE ICO BUDGET - has the game ever logged what it picked up"
r "grep -h 'TSP_ICO_BUDGET_V1' '$LOG' 2>/dev/null | tail -6 | sed 's/^/    /' || true"
r "grep -qh 'TSP_ICO_BUDGET_V1' '$LOG' 2>/dev/null || echo '    no TSP_ICO_BUDGET_V1 line in the log at all'"

hr "3. THE SETTING THAT PINS THE ICO AT ITS 1 ms FLOOR"
r "awk '/^\[Cells\]/{f=1} f&&/^\[/&&!/^\[Cells\]/{exit} f&&/target framerate/{printf \"    line %d: %s\n\", NR, \$0}' '$CFG'"
say "will become:  target framerate = 30   (inside [Cells] only)"
say ""
say "Every 'target framerate' line anywhere in the file, so nothing else moves:"
r "grep -n 'target framerate' '$CFG' | sed 's/^/    /'"

hr "4. THE ENV FILE THIS WILL WRITE"
cat <<'EEOF'
    export TSP_ICO_MAXOBJ=4
    export TSP_KTX=1        <- only on a card that HAS the .ktx; go counts them
    export TSP_CRASH_OUT=/mnt/SDCARD/data/ports/openmw/openmw_crash.txt
    export LIBGL_NOBANNER=1
    export TSP_RESTORE_V1=1
    (the heapfix MALLOC_* lines are NOT carried over - the trim proved the
     heap is live, so pinning the mmap threshold has no upside and costs a
     fresh zero-filled mmap for every mid-size allocation)
EEOF
say "It goes in $ENVF, which Morrowind.sh line 5 sources. That path is PROVEN:"
say "TSP_HEAPFIX_V1=1 was written there and showed up in /proc/<pid>/environ."

hr "5. AND THE TWO SPECULATIVE heapfix SETTINGS GO BACK"
r "grep -n -e 'preload cell cache max' -e 'preload cell expiry delay' '$CFG' | sed 's/^/    /'"
say "back to:  cache max = 24   expiry delay = 20"

if [ "$MODE" = "plan" ]; then
    printf '\n'
    say "PLAN ONLY. Nothing written."
    printf '\n      bash ~/Downloads/tsp_icoktx.sh go\n\n'
    exit 0
fi

# ---------------------------------------------------------------------- go ---
# -maxdepth, on one named directory. A recursive scan of the card once
# saturated the SD and gave a five-minute 0-1 fps load.
hr "DOES THIS CARD HAVE THE ASTC TEXTURES"
KTXN="$(rq "find '$G/data/Data Files/textures' -maxdepth 2 -iname '*.ktx' 2>/dev/null | wc -l" | tr -dc '0-9')"
[ -n "$KTXN" ] || KTXN=0
if [ "$KTXN" -gt 100 ]; then
    KTXVAL=1
    say "$KTXN .ktx present -> TSP_KTX=1, the memory fix is live on this card"
else
    KTXVAL=0
    say "only $KTXN .ktx present -> TSP_KTX=0 on this card."
    say "Pointing the loader at a texture set that is not here would be a"
    say "regression, not a fix. The ICO and framerate fixes below need no"
    say "converted assets and still apply. Run the ASTC conversion on this"
    say "card to get the memory fix too."
fi
printf '\n'

hr "WRITING THE ENV FILE"
rin <<EEOF2
E='$ENVF'
if [ -f "\$E" ]; then
    if ls "\$E".before-restore-* >/dev/null 2>&1; then
        printf '    original already preserved at %s - not re-backing up\n' \\
          "\$(ls -1tr "\$E".before-restore-* | head -1)"
    else
        cp -p "\$E" "\$E.before-restore-$STAMP" \\
          && printf '    backed up to %s.before-restore-%s\n' "\$E" "$STAMP"
    fi
fi
cat > "\$E" <<'INNER'
# tsp_intocc.env - sourced by Morrowind.sh line 5, inside its own -f guard.
# THIS IS THE DELIVERY PATH THAT WORKS. /mnt/SDCARD/tsp_iotune.conf is sourced
# by nothing (the launcher says so at its own lines 10-14), so every export in
# that file has been inert - including the two confirmed fixes below.

# --- THE FRAME-HITCH FIX. RESULT-ico-maxobj-was-the-hitch-20260908: the
# --- IncrementalCompileOperation was compiling ONE GL object per frame during
# --- gameplay, so a cell transition left a long tail of frames each doing
# --- compile work. 4 gave "next to no frame hitching" in three of the worst
# --- spots. Read by TSP_ICO_BUDGET_V1 in renderingmanager.cpp (~line 415).
# --- 8 is the next step up if a heavy load still feels rough; 1 is the old
# --- broken behaviour.
export TSP_ICO_MAXOBJ=4

# --- THE MEMORY FIX. RESULT-astc-ktx-textures-are-the-memory-fix-20260910,
# --- one-variable A/B on the same route: avail floor 192 vs 105 MB, cached
# --- peak 302 vs 245 MB, rss peak 584 vs 646 MB. Without this the 4481
# --- converted .ktx on the card are ignored and DDS is read from the BSAs.
# --- Written as what THIS card can honour: 1 only where the .ktx are present.
export TSP_KTX=$KTXVAL

# --- crash log next to openmw_log.txt, handled by libtsp_crash.so
export TSP_CRASH_OUT=/mnt/SDCARD/data/ports/openmw/openmw_crash.txt

# --- silences the gl4es banner. Not a fix, just noise off the SD card.
export LIBGL_NOBANNER=1

# --- marker, so /proc/<pid>/environ can prove this file reached the game
export TSP_RESTORE_V1=1
INNER
printf '    wrote %s bytes. Reading it back off the device:\n' "\$(wc -c < "\$E")"
sed 's/^/      /' "\$E"
EEOF2

hr "SETTINGS"
rin <<SEOF2
C='$CFG'
[ -f "\$C" ] || { echo "    $CFG missing"; exit 1; }
if ls "\$C".before-restore-* >/dev/null 2>&1; then
    printf '    original already preserved at %s - not re-backing up\n' \\
      "\$(ls -1tr "\$C".before-restore-* | head -1)"
else
    cp -p "\$C" "\$C.before-restore-$STAMP" \\
      && printf '    backed up to %s.before-restore-%s\n' "\$C" "$STAMP"
fi

# target framerate ONLY inside [Cells]. awk rewrites the file so no other
# section can be touched by a loose sed.
awk '
/^\[/ { sec = \$0 }
{
    if (sec == "[Cells]" && \$0 ~ /^[[:space:]]*target framerate[[:space:]]*=/)
        print "target framerate = 30"
    else if (\$0 ~ /^[[:space:]]*preload cell cache max[[:space:]]*=/)
        print "preload cell cache max = 24"
    else if (\$0 ~ /^[[:space:]]*preload cell expiry delay[[:space:]]*=/)
        print "preload cell expiry delay = 20"
    else
        print
}' "\$C" > "\$C.tsp_new" && mv "\$C.tsp_new" "\$C"

echo "    the whole [Cells] section now:"
awk '/^\[Cells\]/{f=1} f&&/^\[/&&!/^\[Cells\]/{exit} f{printf "      %4d | %s\n", NR, \$0}' "\$C"
echo "    every target framerate line in the file:"
grep -n 'target framerate' "\$C" | sed 's/^/      /'
A="\$(awk '/^\[Cells\]/{f=1} f&&/^\[/&&!/^\[Cells\]/{exit} f&&/^target framerate = 30\$/{n++} END{print n+0}' "\$C")"
B="\$(grep -c '^preload cell cache max = 24\$' "\$C")"
D="\$(grep -c '^preload cell expiry delay = 20\$' "\$C")"
if [ "\$A" = "1" ] && [ "\$B" = "1" ] && [ "\$D" = "1" ]; then
    echo "    VERIFIED: all three lines took, exactly once each"
else
    echo "    WARNING: expected 1 of each, got framerate=\$A cachemax=\$B expiry=\$D"
fi
SEOF2

hr "DONE - NOTHING WAS REBUILT, THE BINARY IS UNTOUCHED"
cat <<'FEOF'
    TSP_ICO_MAXOBJ=4     the 09-08 frame-hitch fix, back on
    TSP_KTX=1            the 09-10 memory fix, back on (+87 MB avail, +57 cached)
    target framerate 30  so the ICO gets a real per-frame compile budget
    cache max 24, expiry 20   the speculative heapfix settings reverted

  Arm the sampler BEFORE launching, so this run produces a number and not an
  impression - two runs on identical config have already differed by more than
  any effect measured so far:

      bash ~/Downloads/tsp_verdict.sh arm

  Then launch, load the Balmora save, walk the route past Caius, quit, and:

      bash ~/Downloads/tsp_verdict.sh pull

  The pull will show whether TSP_ICO_BUDGET_V1 and the ktx loads actually
  happened, so if either is still not picked up you will see it immediately.

  Back out with:  bash ~/Downloads/tsp_icoktx.sh undo
FEOF
printf '\n      bash ~/Downloads/tsp_verdict.sh arm\n\n'
