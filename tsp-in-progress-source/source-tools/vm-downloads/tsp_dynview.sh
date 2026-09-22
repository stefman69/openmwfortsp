#!/bin/sh
# tsp_dynview.sh - make the far plane breathe instead of jump. Lua only.
#
#   plan   find every copy of dynamic_view.lua, dump it, show every edit. No writes.
#   go     apply the glide, with a backup and a syntax check per copy
#   tune   settle the plane: sample 2 s, deadband 250        (needs go)
#   tune2  slower breath, 2/3 the calls: 240/160, db 350, ms 16  (needs tune)
#   undo   restore every copy from its ORIGINAL backup - undoes all of the above
#
# Everything it prints is also saved to a txt file in ~/Downloads, so the run can
# be uploaded instead of pasted.
#
# THIS REPLACES THE EARLIER CONSTANTS-ONLY VERSION OF THIS SCRIPT, WHICH WAS
# WRONG. Same name and same three modes on purpose - the bad one should not be
# sitting in ~/Downloads next to this.
#
# Why it was wrong: DEADBAND does two jobs in the real file. It is the retarget
# threshold in onFrame, and it is ALSO the minimum applied movement inside
# setView (line 177: if math.abs(v - currentView) < DEADBAND then return false).
# Setting MAX_DROP/MAX_RAISE to 250 while raising DEADBAND to 256 meant every
# rate-limited step was smaller than the floor that lets a move through, so
# setView refused all of them. Run against the real file under lua5.3 it parked
# at 3000 after the load and never moved again for the whole run - zero
# setViewDistance calls in 25 seconds. My fixture had no second deadband check
# in setView, which is exactly why the bug did not show up there.
#
# WHAT THIS ONE DOES
#
# The controller decides once a second and then moves the plane in one lump.
# Driven on the framerate measured in tsp_cull.sh dump, the real file does this:
#
#     3000 (load snap) -> 2500 within one second -> pinned at the floor for four
#     seconds -> +308 +471 +490 +404 +208 +147 back up to 4529
#
# Seven pops, and four seconds at minimum draw distance on every load. So:
#
#   1. targetView becomes a held value. The once-a-second block sets it and
#      stops moving the camera itself.
#   2. A glide runs every frame, moving toward the target by at most rate * dt.
#      400 units/s in, 250 units/s out - about the same travel rate as before,
#      spread across the second instead of dumped in one frame.
#   3. setView takes a minStep argument. The glide passes GLIDE_MIN_STEP (12);
#      every existing caller omits it and keeps DEADBAND exactly as before.
#      That split is the change constants alone could not make.
#   4. FPS_SMOOTHING = 'none' sends the raw one-second average straight to the
#      target. The rate limit IS the smoothing now - one bad second can only
#      move the plane 400 units - so the recency window, the trim and the
#      FPSAVG_V2 ceiling are redundant. Nothing is deleted: set it to 'window'
#      and the original estimator is back, one word, no re-patch.
#
# Measured, same 25-second sequence, same load:
#
#                        as shipped     glide
#     largest step           500          24      units, after the load snap
#     setViewDistance          9         159      calls
#     total travel          5029        5479      units
#     settles at            4529        4471
#
# Same distance travelled, same place reached, in steps twenty times smaller.
#
# THE ONE THING TO WATCH: 159 calls instead of 9. A small view-distance change
# should be nearly free inside the engine - the terrain quadtree and object
# paging only do real work when the required set actually changes, so many tiny
# moves ought to cost less in spikes than one big one, which is the whole point.
# But if fps drops while the plane is moving, GLIDE_MIN_STEP is the dial: raise
# it to 24 or 48 for a third or a sixth of the calls in slightly larger steps.
# The glide banks sub-threshold movement in an accumulator rather than dropping
# it, so no value of GLIDE_MIN_STEP can freeze it the way the last patch froze.
#
# IT PATCHES EVERY COPY IT FINDS. The launcher force-installs VisGrid from
# v30_profiles/ at lines 794-817, so a mod file can have a shadow source copy
# that a later apply restores over the top. Patching only the live copy would
# work until the next mods-apply and then silently revert - which is exactly how
# tsp_iotune.conf came to be inert. The last plan found only one copy; this
# still checks.

set -u
# Device address: $TSP_DEV wins, then ~/.tsp_dev as written by tsp_net.sh, then
# the old hardcoded default. Two cards do not share an address, and a tool
# pointed at the wrong one reports that card state as if it were this one.
DEV="${TSP_DEV:-}"
[ -n "$DEV" ] || { [ -r "$HOME/.tsp_dev" ] && DEV="$(cat "$HOME/.tsp_dev")"; }
[ -n "$DEV" ] || DEV="root@192.168.1.12"
G="/mnt/SDCARD/data/ports/openmw"
SSHO="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes"
STAMP="$(date +%Y%m%d-%H%M%S)"
PATCHER="$HOME/Downloads/tsp_glidepatch.py"
WORK="/tmp/tsp_dv_$STAMP"

MODE="${1:-plan}"
case "$MODE" in plan | go | tune | tuneplan | tune2 | tune2plan | undo) ;;
*) printf 'usage: %s plan | go | tune | tune2 | undo\n' "$0"; exit 2 ;; esac

# What each mode asks the patcher for, what marker proves it landed, and what
# its backup is called. undo always restores the OLDEST clean backup, so it
# rewinds past a tune to the pristine file whichever order they were run in.
case "$MODE" in
    tune2|tune2plan) PMODE="$MODE"; MARKW="TSP_DYNVIEW_TUNE_V2"; BAK="before-tune2"
                   VERB="on tune 2"; PREREQ="TSP_DYNVIEW_TUNE_V1" ;;
    tune|tuneplan) PMODE="$MODE"; MARKW="TSP_DYNVIEW_TUNE_V1"; BAK="before-tune"
                   VERB="tuned"; PREREQ="TSP_DYNVIEW_GLIDE_V1" ;;
    *)             PMODE="$MODE"; MARKW="TSP_DYNVIEW_GLIDE_V1"; BAK="before-glide"
                   VERB="glided"; PREREQ="" ;;
esac

# ------------------------------------------------------ save the whole run ---
# Re-exec once through tee so the transcript lands in a file. The guard variable
# is what stops it recursing.
MARK="$MARKW"
LOG="$HOME/Downloads/tsp_dynview_${MODE}_$STAMP.txt"
if [ "${TSP_DV_TEE:-0}" != "1" ]; then
    TSP_DV_TEE=1; export TSP_DV_TEE
    sh "$0" "$MODE" 2>&1 | tee "$LOG"
    printf '\n  Saved to: %s\n  Upload that file rather than pasting it.\n\n' "$LOG"
    exit 0
fi

say() { printf '  %s\n' "$*"; }
hr()  { printf '\n########## %s ##########\n' "$1"; }
r()   { ssh $SSHO -n "$DEV" "$1" 2>&1; }
rq()  { ssh $SSHO -n "$DEV" "$1" 2>/dev/null; }
rin() { ssh $SSHO "$DEV" "sh -s" 2>&1; }
abort() { printf '\n  STOPPING: %s\n  Nothing further was changed.\n\n' "$*"; exit 1; }

ssh $SSHO -n "$DEV" "echo ok" 2>&1 | grep -q ok \
    || abort "cannot reach $DEV - is the handheld awake and on wifi?"

# ------------------------------------------------- find every copy, bounded --
# maxdepth on named directories only. A recursive find over the card once
# saturated the SD and caused a five-minute 0-1 fps load.
hr "EVERY COPY OF dynamic_view.lua"
FILES="$(rq "for R in '$G/data' '$G/mods' '$G/v30_profiles' '$G/resources' '$G'; do
    [ -d \"\$R\" ] && find \"\$R\" -maxdepth 6 -name 'dynamic_view.lua' 2>/dev/null
done | sort -u")"
[ -n "$FILES" ] || abort "no dynamic_view.lua found under $G - send me the output of: ssh $DEV 'ls $G'"
printf '%s\n' "$FILES" | while read -r f; do
    [ -n "$f" ] || continue
    printf '    %-74s %6s bytes  marker x%s\n' "$f" \
      "$(rq "wc -c < '$f' 2>/dev/null")" \
      "$(rq "grep -c '$MARK' '$f' 2>/dev/null")"
done
N="$(printf '%s\n' "$FILES" | grep -c 'dynamic_view.lua')"
say "$N copy/copies"
[ "$N" -le 4 ] 2>/dev/null || abort "$N copies is more than expected - send me the list above"

# ======================================================================= undo =
if [ "$MODE" = "undo" ]; then
    hr "RESTORING EVERY COPY"
    printf '%s\n' "$FILES" | while read -r f; do
        [ -n "$f" ] || continue
        rin <<UEOF
F='$f'
B=""
# Oldest clean backup wins. Running a patch twice used to back up its own
# output, so undo restored the edit - three times in this project. Any backup
# that already carries a marker is skipped.
for c in \$(ls -1tr "\$F".before-glide-* "\$F".before-tune-* "\$F".before-tune2-* \\
              "\$F".before-damp-* 2>/dev/null); do
    grep -q 'TSP_DYNVIEW_GLIDE_V1' "\$c" 2>/dev/null && continue
    grep -q 'TSP_DYNVIEW_TUNE_V1'  "\$c" 2>/dev/null && continue
    grep -q 'TSP_DYNVIEW_TUNE_V2'  "\$c" 2>/dev/null && continue
    grep -q 'TSP_DYNVIEW_DAMP_V1'  "\$c" 2>/dev/null && continue
    B="\$c"; break
done
if [ -n "\$B" ]; then
    cp -p "\$B" "\$F" && printf '    %s <- %s\n' "\$F" "\$B"
else
    printf '    %s : no clean backup, left alone\n' "\$F"
fi
printf '        glide marker now: %s   tune marker now: %s\n' \\
  "\$(grep -c 'TSP_DYNVIEW_GLIDE_V1' "\$F" 2>/dev/null)" \\
  "\$(grep -c 'TSP_DYNVIEW_TUNE_V1' "\$F" 2>/dev/null)"
printf '        bytes now: %s\n' "\$(wc -c < "\$F")"
UEOF
    done
    printf '\n  Restart the game for Lua changes to take effect.\n\n'
    exit 0
fi

# ===================================================== plan / go / tune ======
if [ -n "$PREREQ" ]; then
    HAVE=0
    printf '%s\n' "$FILES" | while read -r f; do
        [ -n "$f" ] || continue
        rq "grep -q '$PREREQ' '$f' && echo yes" >> "/tmp/tsp_dv_prereq.$STAMP"
    done
    HAVE="$(grep -c yes "/tmp/tsp_dv_prereq.$STAMP" 2>/dev/null)"
    rm -f "/tmp/tsp_dv_prereq.$STAMP"
    case "$HAVE" in ''|*[!0-9]*) HAVE=0 ;; esac
    if [ "$HAVE" -le 0 ]; then
        case "$PREREQ" in
            *TUNE_V1) abort "$PREREQ is not on the device, so tune 2 has nothing to
  adjust. Run this first:
      bash ~/Downloads/tsp_dynview.sh tune" ;;
            *) abort "the glide patch is not on the device ($PREREQ absent). Run first:
      bash ~/Downloads/tsp_dynview.sh go" ;;
        esac
    fi
    say "$PREREQ present on $HAVE copy/copies - prerequisite met"
fi

[ -f "$PATCHER" ] || abort "$PATCHER is missing - it ships with this script, put it in ~/Downloads"
command -v python3 >/dev/null 2>&1 || abort "python3 is not on this machine - the patcher needs it"
mkdir -p "$WORK"
I=0
printf '%s\n' "$FILES" | while read -r f; do
    [ -n "$f" ] || continue
    I=$((I + 1))
    L="$WORK/copy$I.lua"
    hr "COPY $I: $f"
    scp $SSHO "$DEV:$f" "$L" >/dev/null 2>&1 || { say "could not fetch it - skipping"; continue; }
    say "fetched $(wc -c < "$L") bytes, md5 $(md5sum "$L" | cut -c1-12)"

    case "$MODE" in
        plan)     printf '\n  --- THE PATCH\n';  python3 "$PATCHER" plan "$L";     continue ;;
        tuneplan)  printf '\n  --- TUNE 1\n'; python3 "$PATCHER" tuneplan "$L";  continue ;;
        tune2plan) printf '\n  --- TUNE 2\n'; python3 "$PATCHER" tune2plan "$L"; continue ;;
    esac

    python3 "$PATCHER" "$PMODE" "$L" "$L.new"
    PRC=$?
    if [ $PRC -eq 4 ]; then say "already $VERB - skipping"; continue; fi
    [ $PRC -eq 0 ] || { say "the patcher refused (rc=$PRC) - this copy is untouched"; continue; }
    [ -s "$L.new" ] || { say "patched file is empty - not uploading"; continue; }

    rin <<BEOF
F='$f'
if ls "\$F".$BAK-* >/dev/null 2>&1; then
    printf '    already preserved at %s\n' "\$(ls -1tr "\$F".$BAK-* | head -1)"
else
    cp -p "\$F" "\$F.$BAK-$STAMP" \\
      && printf '    backed up to %s.%s-%s\n' "\$F" "$BAK" "$STAMP"
fi
BEOF
    scp $SSHO "$L.new" "$DEV:$f.dv-new" >/dev/null 2>&1 \
        || { say "scp failed - this copy is untouched"; continue; }
    rin <<IEOF
F='$f'
[ -s "\$F.dv-new" ] || { echo "    uploaded file is empty - NOT installing"; exit 1; }
# Check on the device too if a Lua compiler happens to be there. The host
# already compared the patch against the original's own parse result.
for LC in luac luac5.4 luac5.3 luac5.1; do
    if command -v \$LC >/dev/null 2>&1; then
        if \$LC -p "\$F.dv-new" 2>&1; then echo "    \$LC -p OK on the device"
        else echo "    \$LC -p FAILED on the device - NOT installing"; rm -f "\$F.dv-new"; exit 1; fi
        break
    fi
done
cp -p "\$F" "\$F.dv-prev"
mv "\$F.dv-new" "\$F"
if grep -q '$MARK' "\$F"; then
    echo "    INSTALLED: marker present"
    rm -f "\$F.dv-prev"
else
    echo "    VERIFY FAILED - rolling back"
    cp -p "\$F.dv-prev" "\$F"; rm -f "\$F.dv-prev"
    exit 1
fi
IEOF
done

case "$MODE" in
    plan)     printf '\n'; say "PLAN ONLY. Nothing written, nothing uploaded."
              printf '\n      bash ~/Downloads/tsp_dynview.sh go\n\n'; exit 0 ;;
    tuneplan)  printf '\n'; say "PLAN ONLY. Nothing written, nothing uploaded."
               printf '\n      bash ~/Downloads/tsp_dynview.sh tune\n\n'; exit 0 ;;
    tune2plan) printf '\n'; say "PLAN ONLY. Nothing written, nothing uploaded."
               printf '\n      bash ~/Downloads/tsp_dynview.sh tune2\n\n'; exit 0 ;;
esac

# ------------------------------------------------ re-read the device state ---
# The loop above runs in a subshell, so it cannot report back. Ask the device
# what actually landed instead of trusting the loop's own output.
hr "WHAT IS ON THE DEVICE NOW"
: > "$WORK/hits"
printf '%s\n' "$FILES" | while read -r f; do
    [ -n "$f" ] || continue
    printf '    %s\n' "$f"
    rq "grep -n -e 'VIEW_DROP_PER_SECOND *=' -e 'VIEW_RAISE_PER_SECOND *=' \
             -e 'GLIDE_MIN_STEP *=' -e 'FPS_SMOOTHING *=' \
             -e '^local SAMPLE_SECONDS *=' -e '^local DEADBAND *=' \
             -e 'tspGlide(dt)' -e 'minStep or DEADBAND' '$f'" | sed 's/^/        /'
    printf '        %s x%s\n' "$MARK" "$(rq "grep -c '$MARK' '$f' 2>/dev/null")"
    rq "grep -q '$MARK' '$f' && echo hit" >> "$WORK/hits"
done
# grep -c prints 0 and exits 1; the substitution keeps the 0 and the case guard
# handles an empty read. No "|| echo 0" - that is what produced "0\n0" and a
# gate that could not fail.
OK="$(grep -c hit "$WORK/hits" 2>/dev/null)"
case "$OK" in ''|*[!0-9]*) OK=0 ;; esac
printf '\n'
if [ "$OK" -eq 0 ]; then
    abort "the marker is on NO copy - nothing was installed. The per-copy output above says why."
fi
say "$OK of $N copies $VERB"
if [ "$OK" -lt "$N" ]; then
    printf '\n  WARNING: %s copy/copies did NOT take the patch.\n' "$((N - OK))"
    printf '  A shadow copy that still has the old code can be restored over the\n'
    printf '  live one by a mods-apply, which is exactly how tsp_iotune.conf went\n'
    printf '  inert. Send me the section above for the copy that refused.\n'
fi

hr "DONE - LUA ONLY, NOTHING WAS REBUILT"
if [ "$MODE" = "tune2" ]; then
cat <<'T2EOF'
    VIEW_DROP_PER_SECOND   400 -> 240    pulling in 40% slower
    VIEW_RAISE_PER_SECOND  250 -> 160    pushing out slower still
    DEADBAND               250 -> 350    1.72 fps of hysteresis, was 1.23
    GLIDE_MIN_STEP          12 ->  16    banks two frames instead of one

  YOUR POINT ABOUT TEXTURES WAS THE USEFUL ONE

  Textures flickering on and off at the far plane is objects crossing the
  boundary, and the crossing rate tracks the plane's SPEED - not the size of
  each step. Tune 1 never touched the speed, which is why it settled the plane
  but the breathing still felt quick. That is the rate pair above.

  But the rate alone does not cut the call count: a slower plane just travels
  for longer and makes about the same number of calls. 12 seeds x 120 s:

      drop/raise   calls/s   speed   time moving
        400/250      5.07     206       42%     <- tune 1
        300/200      5.23     175       48%
        220/150      4.71     141       53%

  So the deadband does the cutting - by reducing how far the plane travels at
  all, not by slowing it - and GLIDE_MIN_STEP comes up for a reason only the
  long case shows:

                             ordinary walking      one 27 -> 17.5 -> 27 walk-in
      400/250 db250 ms12       5.55 calls/s            4.6 calls/s   <- tune 1
      240/160 db350 ms12       4.20   (76%)            6.5   (141%)
      240/160 db350 ms16       3.65   (66%)            4.8   (104%)  <- shipped

  ms12 is the 75% you asked for on ordinary walking, and then costs 41% MORE
  during a long transition - exactly when the plane is working hardest, which
  defeats the reason you wanted the cut. So this is 66% instead of 75%, and
  never worse than tune 1 in any case I could construct.

      against tune 1        before    after
        calls/second          5.55     3.65
        speed while moving     194      150    units/s - the flicker rate
        total travel         11110     7798    units - the flicker total
        largest step          22.1     21.7    unchanged, as you wanted

  A genuine fps drop still reaches ~2575 by 25 seconds, same as before.

  WHAT TO LOOK FOR

      ssh root@192.168.1.12 "grep -h 'status glide' \
        /mnt/SDCARD/data/ports/openmw/openmw_log.txt | tail -20"

    moves should be roughly two thirds of what it was, max_step still ~21, and
    goal should repeat across more windows than before. If it is STILL too quick
    a breath, the rate pair is the dial and it costs nothing but responsiveness -
    tell me and I will take 240/160 down again rather than guess.

  Back out with:  bash ~/Downloads/tsp_dynview.sh undo   (undoes everything)
T2EOF
elif [ "$MODE" = "tune" ]; then
cat <<'TEOF'    SAMPLE_SECONDS   1.0 -> 2.0     decide every two seconds, on a two-second
                                    average - half the samples, half the
                                    decisions, and a quieter average behind them
    DEADBAND        96.0 -> 250.0   1.23 fps of hysteresis instead of 0.47

  GLIDE_MIN_STEP stays at 12 on purpose. Your max_step was 20-27 and you said
  you liked how that looks, so the steps stay that size - what changes is how
  often the plane is moving at all.

  WHAT YOUR LOG ACTUALLY SAID

    moves 37-101 per 5 s = 7-20 setViewDistance calls a second
    max_step 20-27       = the glide working, no pops
    goal 3736..4808      = 1072 units of wander, mean 416 units from view

  The plane never arrived. The band is 2500..7168 across 17..40 fps, so 203 view
  units per fps, which makes DEADBAND 96 worth 0.47 fps - half an fps of
  ordinary wobble was re-aiming it, all day. Reproduced at 26.7 fps +/- 3 for
  120 s: 12.8 calls/s, worst 5 s window 97, moving 92% of the wall clock. That
  matches your log, so the model is right.

                      before      after
    calls/second       12.8         5.1
    worst 5 s window     97          80
    largest step         23          21
    time in motion      92%         41%

  Response to a real drop is unchanged - on a sustained 27 -> 17.5 fps walk-in it
  reaches ~2600 by 25 s either way. The difference is it then HOLDS at 2599
  instead of jittering 2658 / 2564 / 2555.

  WHAT TO LOOK FOR

    Same line as before:

      ssh root@192.168.1.12 "grep -h 'status glide' \
        /mnt/SDCARD/data/ports/openmw/openmw_log.txt | tail -20"

    moves should roughly halve, max_step should stay about 21, and goal should
    sit much closer to view and repeat the same number across several windows -
    that repetition is the plane holding still, which is the thing you asked for.

    If it is still busier than you want, DEADBAND is the dial that costs nothing
    visually: 250 -> 400 takes time in motion from 41% to 20%. Tell me the moves
    numbers and I will set it rather than guess.

  Back out with:  bash ~/Downloads/tsp_dynview.sh undo   (undoes the glide too)
TEOF
else
cat <<'FEOF'
    VIEW_DROP_PER_SECOND   400    pulling in, units per second, applied per frame
    VIEW_RAISE_PER_SECOND  250    pushing out, slower on purpose
    GLIDE_MIN_STEP          12    smallest move worth a setViewDistance call
    FPS_SMOOTHING       'none'    raw 1 s average; 'window' restores the old one

  MAX_DROP_PER_SAMPLE, MAX_RAISE_PER_SAMPLE and DEADBAND are all still there at
  800 / 500 / 96. The first two no longer move the camera; DEADBAND still does
  its hysteresis job, and still floors every non-glide setView call.

  Lua loads at game start, so this needs a full restart, not a save reload.

  WHAT TO LOOK FOR

    Load a save, stand still fifteen seconds, walk a bit, then:

      ssh root@192.168.1.12 "grep -h 'status glide' \
        /mnt/SDCARD/data/ports/openmw/openmw_log.txt | tail -20"

    max_step is the number that matters: it should be 12-24, never 150-500.
    moves is how many setViewDistance calls those five seconds cost.

  IF FPS GOT WORSE

    Then the per-call cost is real and the dial is GLIDE_MIN_STEP. Raise it to
    24, then 48 - each doubling roughly halves the calls and doubles the step.

  Back out with:  bash ~/Downloads/tsp_dynview.sh undo
FEOF
fi
printf '\n  Lua loads at game start, so this needs a FULL RESTART, not a save reload.\n'
printf '\n      bash ~/Downloads/tsp_verdict.sh arm\n\n'
