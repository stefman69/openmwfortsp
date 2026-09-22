#!/bin/sh
# tsp_ab.sh - two A/B switches in the launcher, flipped by flag files.
#
#   plan            fetch the launcher, show exactly what would be inserted,
#                   write nothing
#   install         insert the switch block (once), with a device backup and a
#                   syntax check that restores the backup if anything is wrong
#   scaler on|off   flip the swap-scaler arm
#   tex udisk|sd    flip the texture-root arm
#   status          which arms are armed, and what the last run actually did
#   uninstall       restore the launcher from its backup
#
# WHY THESE TWO
#
# 1. THE SCALER. The launcher logs
#      TSP_SWAPSCALER_051_V35 scale=0 source=1280x720 requested_output=1280x720
#    - a full-screen pass whose output is identical to its input, because the
#    resolution feature is idle at scale=0. On 09-08 tsp_gltime measured
#      total=46.5  gl=17.3  SwapWindow=11.5
#    with vsync confirmed off: 11.5 ms per frame inside SwapWindow, which is
#    31% of the frame and lands squarely in the 19.6 ms residual that
#    render = cull + draw + resid has never accounted for.
#    The resolution-lowering patch is NOT removed - it is bypassed while idle.
#
# 2. THE TEXTURE ROOT. /mnt/UDISK/openmw-tex is the last data= root so it wins
#    the VFS, which means every world texture is read from the eMMC. That same
#    eMMC already carries the 891 MB navmesh database and the 512 MB swapfile,
#    and it benched 2787 KB/s against the SD card's 5213 KB/s. Three consumers
#    on the slower device.
#    The flip moves /mnt/UDISK/openmw-tex/textures aside, so the data= root
#    still EXISTS (no missing-directory warning) but holds nothing, and every
#    texture falls through to the SD copy. No config is touched, so the mod
#    manager never sees an out-of-sync openmw.cfg and no mods-apply can strip it.
#
# BOTH ARMS LOG, EITHER WAY, so a run can never be misattributed. The flags live
# on the SD card so they can be deleted over ssh even if the screen is blank.
#
# WARNING that applies to the launcher edit: the mod manager regenerates
# Morrowind.sh and has demonstrably stripped TSP blocks before - TSP_RINGARM_V2's
# own comment records V1 being lost that way. `status` greps for the marker, so
# check it after any manager run.

set -u
DEV="root@192.168.1.12"
LAUNCH="/mnt/SDCARD/Roms/PORTS/Morrowind.sh"
G="/mnt/SDCARD/data/ports/openmw"
SSHO="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes"
STAMP="$(date +%Y%m%d-%H%M%S)"
PATCHER="$HOME/Downloads/tsp_abpatch.py"
WORK="/tmp/tsp_ab_$STAMP"
MARK="TSP_AB_SWITCH_V1"

MODE="${1:-status}"
ARG="${2:-}"
case "$MODE" in dump | plan | install | scaler | tex | status | uninstall) ;;
*) printf 'usage: %s dump | plan | install | scaler on|off | tex udisk|sd | status | uninstall\n' "$0"; exit 2 ;; esac

say() { printf '  %s\n' "$*"; }
hr()  { printf '\n########## %s ##########\n' "$1"; }
r()   { ssh $SSHO -n "$DEV" "$1" 2>&1; }
rq()  { ssh $SSHO -n "$DEV" "$1" 2>/dev/null; }
rin() { ssh $SSHO "$DEV" "sh -s" 2>&1; }
abort() { printf '\n  STOPPING: %s\n  Nothing further was changed.\n\n' "$*"; exit 1; }

ssh $SSHO -n "$DEV" "echo ok" 2>&1 | grep -q ok \
    || abort "cannot reach $DEV - is the handheld awake and on wifi?"

# ===================================================================== status =
show_status() {
    hr "WHICH ARMS ARE ARMED"
    rin <<'SEOF'
L="/mnt/SDCARD/Roms/PORTS/Morrowind.sh"
n="$(grep -c 'TSP_AB_SWITCH_V1' "$L" 2>/dev/null)"
[ -n "$n" ] || n=0
if [ "$n" -ge 1 ] 2>/dev/null; then
    printf '    launcher: PATCHED (%s marker lines)\n' "$n"
else
    printf '    launcher: NOT PATCHED - run install\n'
fi
[ -f /mnt/SDCARD/tsp_noscaler ] && printf '    scaler : OFF  (flag present)\n' \
                                || printf '    scaler : ON   (flag absent)\n'
[ -f /mnt/SDCARD/tsp_texsd ]    && printf '    texroot: SD    (flag present)\n' \
                                || printf '    texroot: UDISK (flag absent)\n'
echo "--- the eMMC texture root right now"
for d in /mnt/UDISK/openmw-tex/textures /mnt/UDISK/openmw-tex/textures.off; do
    if [ -d "$d" ]; then
        printf '    %-44s %6s files, %s\n' "$d" \
          "$(find "$d/" -maxdepth 1 -type f 2>/dev/null | wc -l)" \
          "$(du -sh "$d" 2>/dev/null | cut -f1)"
    else
        printf '    %-44s absent\n' "$d"
    fi
done
echo "--- what the last runs actually did"
grep -h 'TSP_AB_SWITCH_V1' /mnt/SDCARD/tsp_prog.txt 2>/dev/null | tail -8 | sed 's/^/    /'
grep -qh 'TSP_AB_SWITCH_V1' /mnt/SDCARD/tsp_prog.txt 2>/dev/null \
  || echo "    (no run has gone through the block yet)"
echo "--- and what the scaler itself said"
grep -h 'TSP_SWAPSCALER' /mnt/SDCARD/data/ports/openmw/openmw_log.txt 2>/dev/null | tail -3 | sed 's/^/    /'
echo "--- launcher backups"
ls -1t /mnt/SDCARD/Roms/PORTS/Morrowind.sh.before-ab-* 2>/dev/null | head -3 | sed 's/^/    /'
SEOF
}

if [ "$MODE" = "status" ]; then
    show_status
    printf '\n'
    exit 0
fi

# ====================================================== scaler / tex toggles =
if [ "$MODE" = "scaler" ]; then
    case "$ARG" in
    off) r "touch /mnt/SDCARD/tsp_noscaler && echo '    scaler arm: OFF (bypassed)'" ;;
    on)  r "rm -f /mnt/SDCARD/tsp_noscaler && echo '    scaler arm: ON (preloaded)'" ;;
    *)   abort "usage: $0 scaler on|off" ;;
    esac
    show_status
    printf '\n  Arm the sampler BEFORE launching, then walk the Caius route:\n'
    printf '\n      bash ~/Downloads/tsp_verdict.sh arm\n\n'
    exit 0
fi

if [ "$MODE" = "tex" ]; then
    case "$ARG" in
    sd)    r "touch /mnt/SDCARD/tsp_texsd && echo '    texroot arm: SD (eMMC copy moved aside at launch)'" ;;
    udisk) r "rm -f /mnt/SDCARD/tsp_texsd && echo '    texroot arm: UDISK (eMMC copy restored at launch)'" ;;
    *)     abort "usage: $0 tex udisk|sd" ;;
    esac
    show_status
    printf '\n  The move happens at launch, not now - the dir state above will\n'
    printf '  still show the old arm until the game next starts.\n'
    printf '\n      bash ~/Downloads/tsp_verdict.sh arm\n\n'
    exit 0
fi

# ================================================================= uninstall =
if [ "$MODE" = "uninstall" ]; then
    hr "RESTORING THE LAUNCHER"
    rin <<'UEOF'
L="/mnt/SDCARD/Roms/PORTS/Morrowind.sh"
B=""
for c in $(ls -1tr "$L".before-ab-* 2>/dev/null); do
    grep -q 'TSP_AB_SWITCH_V1' "$c" 2>/dev/null || { B="$c"; break; }
done
if [ -z "$B" ]; then
    echo "    no clean backup found - leaving the launcher alone"
    exit 1
fi
cp -p "$B" "$L" && printf '    restored from %s\n' "$B"
TSP_SH="bash"; command -v bash >/dev/null 2>&1 || TSP_SH="sh"
if "$TSP_SH" -n "$L" 2>&1; then echo "    restored launcher parses OK under $TSP_SH"
else echo "    WARNING: restored launcher does NOT parse under $TSP_SH"; fi
printf '    marker lines now: %s\n' "$(grep -c 'TSP_AB_SWITCH_V1' "$L" 2>/dev/null)"
rm -f /mnt/SDCARD/tsp_noscaler /mnt/SDCARD/tsp_texsd
echo "    both flags removed"
[ -d /mnt/UDISK/openmw-tex/textures.off ] \
  && mv /mnt/UDISK/openmw-tex/textures.off /mnt/UDISK/openmw-tex/textures \
  && echo "    eMMC textures restored"
UEOF
    printf '\n'; exit 0
fi

# ============================================================ plan / install =
[ -f "$PATCHER" ] || abort "$PATCHER is missing - it ships with this script, put it in ~/Downloads"
mkdir -p "$WORK"
hr "FETCHING THE LAUNCHER"
scp $SSHO "$DEV:$LAUNCH" "$WORK/Morrowind.sh" >/dev/null 2>&1 \
    || abort "could not fetch $LAUNCH"
say "$WORK/Morrowind.sh  ($(wc -l < "$WORK/Morrowind.sh") lines, $(wc -c < "$WORK/Morrowind.sh") bytes)"
say "md5 $(md5sum "$WORK/Morrowind.sh" | cut -c1-12)"

if [ "$MODE" = "dump" ]; then
    OUTF="$HOME/Downloads/tsp_ab_launcher_$STAMP.txt"
    python3 "$PATCHER" dump "$WORK/Morrowind.sh" > "$OUTF" 2>&1
    hr "LAUNCHER DUMP"
    say "wrote $OUTF  ($(wc -l < "$OUTF") lines)"
    say ""
    say "It has the shebang, BOTH parse results with the offending region printed,"
    say "every LD_PRELOAD line in context, the exec invocation including its line"
    say "continuations, the whole scaler block, what the launcher sources, and"
    say "every TSP marker already in it. Nothing was written to the device."
    printf '\n'
    exit 0
fi

hr "WHAT WOULD BE INSERTED"
if [ "$MODE" = "plan" ]; then
    python3 "$PATCHER" plan "$WORK/Morrowind.sh"
    RC=$?
    printf '\n'
    case $RC in
    0) say "PLAN ONLY. Nothing written, nothing uploaded."
       printf '\n      bash ~/Downloads/tsp_ab.sh install\n\n' ;;
    4) say "Already installed. Flip arms with the flag files." ;;
    *) say "The patcher refused. Send me the output above." ;;
    esac
    exit 0
fi

python3 "$PATCHER" go "$WORK/Morrowind.sh" "$WORK/Morrowind.sh.new"
RC=$?
if [ $RC -eq 4 ]; then
    say "already installed - skipping the launcher edit"
    show_status
    printf '\n'
    exit 0
fi
[ $RC -eq 0 ] || abort "the patcher refused (rc=$RC). The launcher on the device is untouched."
[ -s "$WORK/Morrowind.sh.new" ] || abort "the patched launcher is empty - not uploading"

hr "CHECKING THE PATCHED FILE BEFORE IT GOES ANYWHERE"
# The launcher is #!/bin/bash and its own line ~422 does not parse under dash,
# so requiring `sh -n` here rejected a correct patch over a pre-existing
# property. Check the interpreter the shebang names, and require sh only to be
# NO WORSE than the original.
bash -n "$WORK/Morrowind.sh.new" || abort "patched launcher fails bash -n"
say "parses under bash (the launcher's own interpreter)"
if sh -n "$WORK/Morrowind.sh" 2>/dev/null; then
    sh -n "$WORK/Morrowind.sh.new" || abort "the original parsed under sh and the patched file does not"
    say "parses under sh too, as the original did"
else
    say "the original does not parse under sh either - pre-existing, not caused here"
fi
say "marker lines: $(grep -c "$MARK" "$WORK/Morrowind.sh.new")"
say "line delta:   $(( $(wc -l < "$WORK/Morrowind.sh.new") - $(wc -l < "$WORK/Morrowind.sh") ))"

hr "UPLOADING, WITH A BACKUP AND A ROLLBACK"
rin <<BEOF
L='$LAUNCH'
if ls "\$L".before-ab-* >/dev/null 2>&1; then
    printf '    original already preserved at %s - not re-backing up\n' \\
      "\$(ls -1tr "\$L".before-ab-* | head -1)"
else
    cp -p "\$L" "\$L.before-ab-$STAMP" \\
      && printf '    backed up to %s.before-ab-%s\n' "\$L" "$STAMP"
fi
BEOF
scp $SSHO "$WORK/Morrowind.sh.new" "$DEV:$LAUNCH.ab-new" >/dev/null 2>&1 \
    || abort "scp failed - the launcher on the device is untouched"
rin <<IEOF
L='$LAUNCH'
[ -s "\$L.ab-new" ] || { echo "    uploaded file is empty - NOT installing"; exit 1; }
# Use the interpreter the shebang names. busybox sh would reject this launcher's
# own bash syntax and reject a perfectly good patch.
TSP_SH="bash"
command -v bash >/dev/null 2>&1 || TSP_SH="sh"
printf '    checking with %s on the device\n' "\$TSP_SH"
if ! "\$TSP_SH" -n "\$L.ab-new" 2>&1; then
    echo "    uploaded file does NOT parse on the device - NOT installing"
    rm -f "\$L.ab-new"
    exit 1
fi
cp -p "\$L" "\$L.ab-prev"
mv "\$L.ab-new" "\$L"
chmod 755 "\$L"
if grep -q 'TSP_AB_SWITCH_V1' "\$L" && "\$TSP_SH" -n "\$L" 2>/dev/null; then
    echo "    INSTALLED and verified: marker present, parses on the device"
    rm -f "\$L.ab-prev"
else
    echo "    VERIFY FAILED - rolling back to the previous launcher"
    cp -p "\$L.ab-prev" "\$L"
    rm -f "\$L.ab-prev"
    exit 1
fi
IEOF

show_status

cat <<'FEOF'

  HOW TO RUN THE A/B - one variable at a time, or neither result means anything

  Baseline is already on record: walk 6.9 faults/s, 35.2 ms good frame,
  cull 7.6 / draw 8.1 / resid 19.6.

  RUN 1 - the scaler, which is the bigger suspect
      bash ~/Downloads/tsp_ab.sh scaler off
      bash ~/Downloads/tsp_verdict.sh arm
      (launch, walk the Caius route 2-3 min, quit)
      bash ~/Downloads/tsp_verdict.sh pull

    Read the GOOD frame row of the frame-cost table. If resid drops from ~19.6
    toward ~8, the scaler was 11 ms of every frame and this is the single
    biggest win of the whole investigation. If resid does not move, the display
    path has a real floor and we stop looking there.

    If the screen is blank or wrong, put it back with:
      bash ~/Downloads/tsp_ab.sh scaler on

  RUN 2 - the texture root, with the scaler back where run 1 left it
      bash ~/Downloads/tsp_ab.sh tex sd
      bash ~/Downloads/tsp_verdict.sh arm
      (same route)
      bash ~/Downloads/tsp_verdict.sh pull

    Read WALK faults/s and the Cached floor. The eMMC is carrying the navmesh,
    the swapfile and the textures at 2787 KB/s while the SD card does 5213, so
    if contention on that device is the last of the hitching, this moves those
    two numbers and nothing else.

FEOF
printf '      bash ~/Downloads/tsp_ab.sh scaler off\n\n'
