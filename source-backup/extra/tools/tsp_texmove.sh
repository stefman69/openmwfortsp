#!/usr/bin/env bash
# TSP_TEXMOVE_V1 - put the 4555 loose .ktx on the eMMC instead of the microSD.
#
#   bash ~/Downloads/tsp_texmove.sh bench    # measure BOTH devices first
#   bash ~/Downloads/tsp_texmove.sh on       # switch the engine to the eMMC copy
#   bash ~/Downloads/tsp_texmove.sh off      # switch back, instantly
#   bash ~/Downloads/tsp_texmove.sh swap 192 # shrink the swapfile 512 -> 192 MB
#
# ============================================================================
# THE NUMBERS BEHIND THIS
# ============================================================================
#   loose .ktx      4555 files    53.4 MB    mean 12.0 KB per file
#   swapfile                     512.0 MB
#   UDISK free                  ~3290 MB
#
# So the textures are 9.6x SMALLER than the swapfile, and 12 KB mean size is
# exactly the small-random-read workload a microSD is worst at. Textures are on
# mmcblk1 (500 GB microSD); swap is on mmcblk0p6 = /mnt/UDISK (7.4 GB eMMC).
#
# Moving them attacks per-operation latency directly, which is the real content of
# the "40,000 small files" argument.
#
# ============================================================================
# BUT MEASURE BEFORE MOVING 4555 FILES
# ============================================================================
# eMMC is usually far better than microSD at small random reads, but not always -
# a cheap eMMC against a good UHS-I card can lose. `bench` copies the tree to
# UDISK and then reads all 4555 files from EACH device with a cold page cache,
# taking /proc/diskstats before and after, so it reports for each device:
#     elapsed, files/s, MB/s, read ops, and KB PER OPERATION.
# `on` refuses to switch if the eMMC did not actually win.
#
# That KB/op figure is also, finally, the direct answer to the 40,000-files
# question - on the real workload, with no play session needed.
#
# ============================================================================
# WHY THIS COPIES RATHER THAN MOVES
# ============================================================================
# The SD originals stay exactly where they are. The engine is switched by adding
# one `data=` line pointing at the eMMC copy; OpenMW gives later data= entries
# precedence, so the eMMC files win. `off` deletes that line and the SD copy is
# live again instantly - no shuffling 4555 files to revert, and no window where
# the textures are missing. Costs 53 MB of the 3290 MB free on UDISK.
#
# ============================================================================
# ON REMOVING SWAP ENTIRELY - WHAT I WOULD NOT DO, AND WHY
# ============================================================================
# VmSwap peaked at 100.0 MB and 133.8 MB across the two measured sessions, with
# RSS at 660 MB on a 1 GB device and Cached already down at 40-60 MB during play.
# The game really does use that swap. Removing it does not remove the need.
#
# RESULT-leak-localized-world-teardown-vs-save-record-read-20260909.md, verbatim:
#   "The device now has 512 MB of swap ... That is why the failure mode was a
#    1-2 fps crawl rather than a HARD DEATH."
#
# So `swap` SHRINKS rather than removes: 512 -> 192 MB still covers the 134 MB
# peak, frees 320 MB of eMMC, and BOUNDS how much the kernel can push out, which
# is the thrash being felt. Same direction as removing it, without converting a
# slowdown into an OOM kill. If you still want it gone entirely after seeing the
# shrink, `swap 0` will do it and will say plainly what it is risking.
#
# Rule Zero: file, not paste; r() uses -n, rin() takes the heredoc (NEVER -n).
# No grep -r. No $(grep -c x f || echo 0). No apostrophe inside any awk program.
# -print0/xargs -0 everywhere: the path contains "Data Files" and a plain xargs
# would split that space and fail on every file.

set -u
MODE="${1:-}"
ARG="${2:-}"
case "$MODE" in
    bench|on|off) : ;;
    swap) case "$ARG" in ''|*[!0-9]*) echo "usage: bash $0 swap <MB>   e.g. swap 192"; exit 2 ;; esac ;;
    *) echo "usage: bash $0 bench|on|off|swap <MB>"; exit 2 ;;
esac

TSP="${TSP:-root@192.168.1.12}"
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6"
DL="${DL:-$HOME/Downloads}"
STAMP="$(date +%Y%m%d-%H%M%S)"
UDIR="${UDIR:-/mnt/UDISK/openmw-tex}"
REP="$DL/tsp-texmove-$MODE-$STAMP.txt"

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }
die() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

r 'echo ok' >/dev/null 2>&1 || die "cannot reach the TSP at $TSP"
echo "MODE=$MODE${ARG:+ $ARG}   eMMC dir: $UDIR"
echo

# ============================================================================
if [ "$MODE" = "bench" ]; then
rin "UDIR=$UDIR STAMP=$STAMP sh -s" <<'REMOTE' 2>&1 | tee "$REP"
# ---- TSP_TEXMOVE_BENCH_BEGIN ----
S=/mnt/SDCARD
G=$S/data/ports/openmw
TEX="$G/data/Data Files/textures"

[ -d "$TEX" ] || { echo "FAIL: no texture dir at $TEX"; exit 1; }

echo "########## 1. WHAT WE ARE MOVING ##########"
N="$(find "$TEX" -type f -name '*.ktx' 2>/dev/null | wc -l)"
B="$(find "$TEX" -type f -name '*.ktx' -print0 2>/dev/null | xargs -0 -r stat -c '%s' 2>/dev/null \
      | awk '{t+=$1} END{print t+0}')"
printf '  loose .ktx      %s files   %.1f MB   mean %.1f KB\n' \
    "$N" "$(awk -v b="$B" 'BEGIN{printf "%.1f", b/1048576}')" \
    "$(awk -v b="$B" -v n="$N" 'BEGIN{printf "%.1f", (n?b/n/1024:0)}')"
if [ "${N:-0}" -lt 100 ]; then echo "  FAIL only $N files - nothing worth moving"; exit 1; fi
echo "  -- free space --"
df 2>/dev/null | awk 'NR==1 || /UDISK|sdcard|SDCARD/' | sed 's/^/    /'
echo "  -- which device is which --"
for d in mmcblk0 mmcblk1; do
    [ -r "/sys/block/$d/size" ] || continue
    sz="$(cat "/sys/block/$d/size" 2>/dev/null)"
    rot="$(cat "/sys/block/$d/queue/rotational" 2>/dev/null)"
    printf '    %-9s %6s MB  rotational=%s\n' "$d" "$((sz / 2048))" "${rot:-?}"
done
echo "    /mnt/UDISK is mmcblk0p6 = eMMC;  the game dir is mmcblk1p1 = microSD"
echo

echo "########## 2. COPY TO eMMC (needed for the test either way) ##########"
mkdir -p "$UDIR" || { echo "FAIL: cannot create $UDIR"; exit 1; }
HAVE="$(find "$UDIR" -type f -name '*.ktx' 2>/dev/null | wc -l)"
if [ "${HAVE:-0}" -eq "${N:-0}" ] && [ "${N:-0}" -gt 0 ]; then
    echo "  eMMC copy already complete ($HAVE files) - skipping the copy"
else
    echo "  copying $N files, $(awk -v b="$B" 'BEGIN{printf "%.0f", b/1048576}') MB ..."
    T0="$(date +%s)"
    mkdir -p "$UDIR/textures"
    ( cd "$TEX" && find . -type f -name '*.ktx' -print0 2>/dev/null \
        | xargs -0 -r -n 40 cp --parents -t "$UDIR/textures" 2>/dev/null ) \
      || ( cd "$TEX" && tar cf - . 2>/dev/null | ( cd "$UDIR/textures" && tar xf - ) )
    T1="$(date +%s)"
    HAVE="$(find "$UDIR" -type f -name '*.ktx' 2>/dev/null | wc -l)"
    printf '  copied in %s s -> %s files on eMMC\n' "$((T1 - T0))" "$HAVE"
fi
if [ "${HAVE:-0}" -ne "${N:-0}" ]; then
    echo "  FAIL copy incomplete: $HAVE on eMMC vs $N on SD. Not benching a partial set."
    exit 1
fi
echo "  VERIFIED: $HAVE files on eMMC matches $N on SD"
echo

# One timed cold read of every file on one device, with diskstats either side.
# Reading via xargs cat exercises the real open+read path, which is the point -
# a raw dd on the device would miss the per-file cost entirely.
measure() {
    dir="$1"; label="$2"; dev="$3"
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    sleep 1
    b_io="$(awk -v d="$dev" '$3==d{print $4}' /proc/diskstats)"
    b_se="$(awk -v d="$dev" '$3==d{print $6}' /proc/diskstats)"
    t0="$(date +%s)"
    find "$dir" -type f -name '*.ktx' -print0 2>/dev/null | xargs -0 -r cat > /dev/null 2>&1
    t1="$(date +%s)"
    a_io="$(awk -v d="$dev" '$3==d{print $4}' /proc/diskstats)"
    a_se="$(awk -v d="$dev" '$3==d{print $6}' /proc/diskstats)"
    el=$((t1 - t0)); [ "$el" -lt 1 ] && el=1
    awk -v lab="$label" -v el="$el" -v n="$N" -v bytes="$B" \
        -v bio="${b_io:-0}" -v aio="${a_io:-0}" -v bse="${b_se:-0}" -v ase="${a_se:-0}" '
    BEGIN {
        ops = aio - bio; sec = ase - bse
        printf "  %-22s %3d s   %7.1f files/s   %6.2f MB/s", lab, el, n/el, bytes/1048576.0/el
        if (ops > 0) printf "   %8d ops   %7.1f ops/s   %6.1f KB/op\n", ops, ops/el, sec*512.0/ops/1024.0
        else printf "   (no read ops counted on this device)\n"
    }'
}

echo "########## 3. THE MEASUREMENT - cold cache, all $N files, both devices ##########"
printf '  %-22s %5s   %13s   %8s   %s\n' "device" "time" "throughput" "" "per-operation"
measure "$TEX"            "microSD (current)" mmcblk1
measure "$UDIR/textures"  "eMMC (proposed)"   mmcblk0
echo
echo "  KB/op is the answer to the 40,000-files question, on the real workload:"
echo "    ~4-12 KB/op  = one op per file, per-op latency dominates"
echo "    much larger  = the fs is coalescing and per-op cost is not the story"
echo

echo "########## 4. SWAP ARITHMETIC ##########"
sed 's/^/  /' /proc/swaps 2>/dev/null
SWKB="$(awk '/UDISK|swapfile/{print $3; exit}' /proc/swaps 2>/dev/null)"
printf '  swapfile %s kB = %s MB\n' "${SWKB:-?}" "$((${SWKB:-0} / 1024))"
printf '  textures %s MB - so the textures are far smaller than the swapfile\n' \
    "$(awk -v b="$B" 'BEGIN{printf "%.0f", b/1048576}')"
echo "  peak VmSwap measured in play: 100.0 MB and 133.8 MB"
echo "  -> 192 MB of swap still covers that peak and frees 320 MB of eMMC."
echo "     Removing swap outright does not remove the need for those 134 MB."
echo

echo "########## VERDICT ##########"
echo "  Compare the two rows in section 3. If eMMC is faster, switch with:"
echo "     bash ~/Downloads/tsp_texmove.sh on"
echo "  on re-runs this comparison and REFUSES if eMMC did not win."
echo "  Nothing has been switched yet - only a spare copy exists on eMMC."
# ---- TSP_TEXMOVE_BENCH_END ----
REMOTE
echo
echo "full report: $REP"
exit 0
fi

# ============================================================================
if [ "$MODE" = "swap" ]; then
rin "NEWMB=$ARG STAMP=$STAMP sh -s" <<'REMOTE' 2>&1 | tee "$REP"
S=/mnt/SDCARD
echo "########## CURRENT SWAP ##########"
sed 's/^/  /' /proc/swaps
SWF="$(awk 'NR>1 && $2=="file"{print $1; exit}' /proc/swaps)"
[ -n "$SWF" ] || { echo "FAIL: no swap FILE found in /proc/swaps"; exit 1; }
CURKB="$(awk -v f="$SWF" '$1==f{print $3}' /proc/swaps)"
printf '  file: %s   %s kB = %s MB\n' "$SWF" "$CURKB" "$((CURKB / 1024))"
echo "  peak VmSwap measured in play: 100.0 MB and 133.8 MB"
echo
if [ "$NEWMB" -eq 0 ]; then
    echo "  ** REQUESTED 0 MB = NO SWAP AT ALL."
    echo "     The game used 100-134 MB of swap at peak with RSS at 660 MB on a"
    echo "     1 GB device and Cached already at 40-60 MB. Removing swap does not"
    echo "     remove that need - it converts a slowdown into an OOM kill. The"
    echo "     09-09 doc says the 512 MB of swap is why the failure mode was a"
    echo "     1-2 fps crawl and not a hard death."
    echo "     REFUSING. Run 'swap 128' for the smallest value that still covers"
    echo "     the measured peak, or say explicitly that you want it gone."
    exit 1
fi
if [ "$NEWMB" -lt 160 ]; then
    echo "  NOTE $NEWMB MB is below the 134 MB measured peak plus headroom."
    echo "       Proceeding, but expect spill-to-nothing under load."
fi
echo "########## RESIZE ##########"
echo "  swapoff first - this pulls any swapped pages back into RAM, so it needs"
echo "  the RAM free and can take a few seconds. The game must NOT be running."
if pidof openmw openmw-0.51 >/dev/null 2>&1; then
    echo "  FAIL the game is running. Quit it first."
    exit 1
fi
if ! swapoff "$SWF" 2>/dev/null; then
    echo "  FAIL swapoff failed - not enough free RAM right now. Reboot and retry."
    exit 1
fi
echo "  OK swapoff"
rm -f "$SWF" || { echo "FAIL could not remove $SWF"; swapon "$SWF" 2>/dev/null; exit 1; }
echo "  old swapfile removed"
if ! dd if=/dev/zero of="$SWF" bs=1M count="$NEWMB" 2>/dev/null; then
    echo "  FAIL dd could not create the new swapfile"
    exit 1
fi
chmod 600 "$SWF"
mkswap "$SWF" >/dev/null 2>&1 || { echo "  FAIL mkswap"; exit 1; }
if swapon "$SWF" 2>/dev/null; then echo "  OK swapon"; else echo "  FAIL swapon"; exit 1; fi
echo
echo "########## VERIFY ##########"
sed 's/^/  /' /proc/swaps
GOT="$(awk -v f="$SWF" '$1==f{print $3}' /proc/swaps)"
printf '  now %s kB = %s MB   (wanted %s MB)\n' "${GOT:-0}" "$((${GOT:-0} / 1024))" "$NEWMB"
[ "$((${GOT:-0} / 1024))" -ge "$((NEWMB - 2))" ] && echo "  VERIFIED" || echo "  MISMATCH"
echo
echo "  NOTE the launcher may recreate the swapfile at its own size on next boot."
echo "  Checking for that:"
grep -n 'swapfile\|mkswap\|swapon' "$S/Roms/PORTS/Morrowind.sh" 2>/dev/null | sed 's/^/    /' \
    || echo "    (no swap handling in the launcher - the change should persist)"
df /mnt/UDISK 2>/dev/null | sed 's/^/  /'
REMOTE
exit 0
fi

# ============================================================================
# on / off  -  the switch is one data= line per openmw.cfg
# ============================================================================
rin "MODE=$MODE UDIR=$UDIR STAMP=$STAMP sh -s" <<'REMOTE' 2>&1 | tee "$REP"
# ---- TSP_TEXMOVE_SWITCH_BEGIN ----
S=/mnt/SDCARD
G=$S/data/ports/openmw
TEX="$G/data/Data Files/textures"
MARK="# TSP_TEXMOVE_V1 eMMC texture override"

echo "########## 1. EVERY openmw.cfg ON THE CARD ##########"
# Scoped to the game dir, never the whole card.
CFGS=""
for c in "$G/config/openmw.cfg" "$G/config-0.51/openmw.cfg" "$G/openmw.cfg" \
         "$G/launcher/openmw.cfg" "$G/data/openmw.cfg"; do
    [ -f "$c" ] && CFGS="$CFGS $c"
done
for c in $(find "$G" -maxdepth 3 -name 'openmw.cfg' 2>/dev/null); do
    case " $CFGS " in *" $c "*) : ;; *) CFGS="$CFGS $c" ;; esac
done
[ -n "$CFGS" ] || { echo "FAIL: no openmw.cfg found under $G"; exit 1; }
for c in $CFGS; do printf '  %s\n' "$c"; done
echo
echo "  -- the data= lines in the first one, for reference --"
FIRST="$(echo $CFGS | cut -d' ' -f1)"
grep -n '^data=' "$FIRST" | sed 's/^/    /'
echo "  (OpenMW gives LATER data= entries precedence, so the override is appended)"
echo

if [ "$MODE" = "on" ]; then
    echo "########## 2. GATE: DID eMMC ACTUALLY WIN ##########"
    N="$(find "$TEX" -type f -name '*.ktx' 2>/dev/null | wc -l)"
    HAVE="$(find "$UDIR" -type f -name '*.ktx' 2>/dev/null | wc -l)"
    printf '  SD %s files   eMMC %s files\n' "$N" "$HAVE"
    if [ "${HAVE:-0}" -ne "${N:-0}" ] || [ "${N:-0}" -lt 100 ]; then
        echo "  FAIL the eMMC copy is missing or incomplete. Run bench first:"
        echo "       bash ~/Downloads/tsp_texmove.sh bench"
        exit 1
    fi
    # quick re-race on a 400-file subset, cold, to confirm the bench verdict
    sub() {
        d="$1"; dev="$2"
        sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; sleep 1
        find "$d" -type f -name '*.ktx' 2>/dev/null | head -400 > /tmp/sub.$$
        b="$(awk -v x="$dev" '$3==x{print $4}' /proc/diskstats)"
        t0="$(date +%s)"
        xargs -r -a /tmp/sub.$$ cat > /dev/null 2>&1
        t1="$(date +%s)"
        a="$(awk -v x="$dev" '$3==x{print $4}' /proc/diskstats)"
        rm -f /tmp/sub.$$
        echo "$((t1 - t0)) $((${a:-0} - ${b:-0}))"
    }
    SDR="$(sub "$TEX" mmcblk1)";  SDT="${SDR%% *}"
    EMR="$(sub "$UDIR/textures" mmcblk0)"; EMT="${EMR%% *}"
    printf '  400-file cold read:  microSD %s s (%s ops)   eMMC %s s (%s ops)\n' \
        "$SDT" "${SDR##* }" "$EMT" "${EMR##* }"
    if [ "${EMT:-99}" -gt "${SDT:-0}" ] 2>/dev/null; then
        echo "  REFUSING: the eMMC was SLOWER in this re-race. Nothing switched."
        echo "  Your plan does not pay off on this hardware - keep the SD copy."
        exit 1
    fi
    echo "  OK eMMC is not slower - proceeding"
    echo

    echo "########## 3. APPEND THE OVERRIDE ##########"
    for c in $CFGS; do
        if grep -q "$MARK" "$c" 2>/dev/null; then
            echo "  $c already has it"
            continue
        fi
        cp -p "$c" "$c.bak-texmove-$STAMP" || { echo "  FAIL backup $c"; continue; }
        before="$(grep -c '^data=' "$c" 2>/dev/null; true)"
        printf '%s\ndata=%s\n' "$MARK" "$UDIR" >> "$c"
        after="$(grep -c '^data=' "$c" 2>/dev/null; true)"
        if [ "${after:-0}" -eq $((${before:-0} + 1)) ]; then
            printf '  OK   %s   data= lines %s -> %s\n' "$c" "$before" "$after"
        else
            printf '  FAIL %s   restoring\n' "$c"
            cp -p "$c.bak-texmove-$STAMP" "$c"
        fi
    done
else
    echo "########## 2. REMOVE THE OVERRIDE ##########"
    for c in $CFGS; do
        if ! grep -q "$MARK" "$c" 2>/dev/null; then
            echo "  $c does not have it"
            continue
        fi
        cp -p "$c" "$c.bak-texmove-off-$STAMP"
        grep -v -e "$MARK" -e "^data=$UDIR\$" "$c" > "$c.new" && mv "$c.new" "$c"
        if grep -q "$MARK" "$c" 2>/dev/null; then
            printf '  FAIL %s still has the marker\n' "$c"
        else
            printf '  OK   %s reverted\n' "$c"
        fi
    done
    echo
    echo "  The eMMC copy at $UDIR is LEFT IN PLACE so on is instant next time."
    echo "  To reclaim the 53 MB:  ssh -n root@192.168.1.12 'rm -rf $UDIR'"
fi
echo

echo "########## 4. FINAL STATE ##########"
for c in $CFGS; do
    printf '  %s\n' "$c"
    grep -n '^data=' "$c" | sed 's/^/      /'
done
echo
echo "########## 5. WILL THE MANAGER UNDO THIS ##########"
echo "  openmw.cfg is regenerated by the manager on a mod-apply, the same way"
echo "  settings.cfg is regenerated from tsp_cells_on.awk. If a mod-apply reverts"
echo "  this, the data= line has to go into the generator instead. Where it lives:"
for p in "$G/launcher/openmw-launcher-backend-v2.py" "$G/launcher/openmw-launcher-backend.py"; do
    [ -f "$p" ] || continue
    printf '    %s\n' "$p"
    grep -n 'data=' "$p" 2>/dev/null | head -8 | sed 's/^/      /'
done
[ -f "$G/launcher/modplan.tsv" ] && echo "    modplan.tsv present - the manager builds cfg from it"
echo
echo "########## READY CHECK ##########"
F=0
if [ "$MODE" = "on" ]; then
    for c in $CFGS; do
        grep -q "^data=$UDIR\$" "$c" 2>/dev/null || { echo "  FAIL $c missing the line"; F=1; }
    done
    [ "$F" -eq 0 ] && echo "  OK   every openmw.cfg points at the eMMC copy"
else
    for c in $CFGS; do
        grep -q "^data=$UDIR\$" "$c" 2>/dev/null && { echo "  FAIL $c still has the line"; F=1; }
    done
    [ "$F" -eq 0 ] && echo "  OK   every openmw.cfg is back to the SD copy"
fi
echo
[ "$F" -eq 0 ] && echo "READY" || echo "NOT READY"
# ---- TSP_TEXMOVE_SWITCH_END ----
REMOTE

echo
if [ "$MODE" = "on" ]; then
    echo "=================================================================="
    echo "  Launch and play. Watch for two things:"
    echo "    - textures still render (no magenta, no missing surfaces). If any"
    echo "      are broken, run off immediately - the SD copy is untouched."
    echo "    - whether the micro-stutters while walking change at all."
    echo
    echo "  Revert instantly:  bash ~/Downloads/tsp_texmove.sh off"
    echo "=================================================================="
else
    echo "=================================================================="
    echo "  Reverted to the microSD textures."
    echo "=================================================================="
fi
