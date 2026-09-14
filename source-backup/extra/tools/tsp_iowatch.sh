#!/bin/sh
# tsp_iowatch.sh - the READER for TSP_IOWATCH_SAMPLER_V2.
#
# The sampler survived in /tmp and is now in Backups/rescued-*. It was written
# for this job and is better than anything built since: 1 Hz rows with zero forks
# except sleep+date, an smaps row every 10 s bucketed by region, per-DEVICE disk
# sectors, and -1 for "could not read" so a failed read is never a real zero.
# This is only the host side that arms it and reads it back.
#
#   arm      start the sampler on the device (survives the ssh session)
#   pull     stop it, fetch the log, and report
#   off      stop it without fetching
#   wire     add /mnt/UDISK/openmw-tex as a data= root - the eMMC copy of the
#            4481 .ktx that was staged but never put in the config
#   unwire   take that line back out
#
# Why wire and pull belong in one tool: the sampler records mmcblk0 and mmcblk1
# read sectors separately, so it can SHOW whether the textures are being read off
# the eMMC or the SD card. That is the only honest way to check the wiring.

set -u
DEV="root@192.168.1.12"
G="/mnt/SDCARD/data/ports/openmw"
CFG="$G/openmw.cfg"
TEXROOT="/mnt/UDISK/openmw-tex"
SAMPLER="/tmp/tsp_iowatch_sampler.sh"
RESCUED="/mnt/SDCARD/data/ports/Backups"
LOG="/tmp/tsp_iowatch.log"
OFFFLAG="/mnt/SDCARD/tsp_iowatch_off"
SSHO="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes"
STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-pull}"
TICKS="${2:-2400}"

r() { ssh $SSHO -n "$DEV" "$1" 2>&1; }
rin() { ssh $SSHO "$DEV" "sh -s" 2>&1; }
say() { printf '  %s\n' "$*"; }
hr() { printf '\n########## %s ##########\n' "$1"; }

case "$MODE" in
arm | pull | off | wire | unwire) ;;
*) printf 'usage: %s arm [ticks] | pull | off | wire | unwire\n' "$0"; exit 2 ;;
esac

r "echo ok" | grep -q ok || { say "cannot reach $DEV"; exit 1; }

# ------------------------------------------------------------------- wire ----
if [ "$MODE" = "wire" ]; then
    hr "WIRING THE eMMC TEXTURE COPY INTO THE CONFIG"
    rin <<WEOF
set -e
CFG='$CFG'
T='$TEXROOT'

if [ ! -d "\$T" ]; then echo "  \$T does not exist - nothing to wire"; exit 1; fi
N="\$(find "\$T" -maxdepth 2 -iname '*.ktx' 2>/dev/null | wc -l)"
echo "  \$T holds \$N .ktx"
echo "  layout check - OpenMW wants subdirs like textures/ under a data root:"
ls -1 "\$T" | head -8 | sed 's/^/      /'
[ "\$N" -gt 0 ] || { echo "  no .ktx under it at depth 2 - refusing"; exit 1; }

if grep -q "^data=\"\?\$T" "\$CFG"; then
    echo "  ALREADY WIRED - the line is present. Nothing changed, unwire still works."
    grep -n '^data=' "\$CFG" | sed 's/^/      /'
    exit 0
fi

cp -p "\$CFG" "\$CFG.bak-texwire-$STAMP"
echo "  backed up to openmw.cfg.bak-texwire-$STAMP"

# In OpenMW the LAST data= root wins for a given filename, so this is appended
# after the existing roots rather than prepended. The ordering is then verified
# empirically from the per-device read split in 'pull', not taken on faith.
LAST="\$(grep -n '^data=' "\$CFG" | tail -1 | cut -d: -f1)"
[ -n "\$LAST" ] || { echo "  no data= lines found - refusing to guess"; exit 1; }
awk -v ln="\$LAST" -v add="data=\$T" \\
    'NR==ln { print; print add; next } { print }' "\$CFG" > /tmp/tsp_cfg.new
grep -q "^data=\$T" /tmp/tsp_cfg.new || { echo "  the edit did not take - refusing"; exit 1; }
cp -f /tmp/tsp_cfg.new "\$CFG"
echo "  data= roots now, in order:"
grep -n '^data=' "\$CFG" | sed 's/^/      /'
WEOF
    printf '\n'
    say "CAVEAT worth knowing before you rely on this: per the 09-05 manager"
    say "notes, a hand-added data= line makes the mod manager report OUT OF SYNC"
    say "and the next mods-apply strips it. Treat this as a test, not a ship."
    printf '\n'
    say "Now arm the sampler, cold-launch, walk the route, then pull:"
    printf '\n      bash ~/Downloads/tsp_iowatch.sh arm\n\n'
    exit 0
fi

if [ "$MODE" = "unwire" ]; then
    hr "REMOVING THE eMMC TEXTURE ROOT"
    LAST="$(r "for b in \$(ls -1t '$CFG.bak-texwire-'* 2>/dev/null); do \
                 grep -q '^data=$TEXROOT' \"\$b\" || { echo \"\$b\"; break; }; done")"
    if [ -n "$LAST" ]; then
        r "cp -f '$LAST' '$CFG' && echo '    restored from $(basename "$LAST")'"
    else
        say "no clean backup - removing the line directly instead"
        r "grep -v '^data=$TEXROOT' '$CFG' > /tmp/tsp_cfg.new && cp -f /tmp/tsp_cfg.new '$CFG' && echo '    line removed'"
    fi
    r "grep -n '^data=' '$CFG' | sed 's/^/      /'"
    exit 0
fi

# -------------------------------------------------------------------- arm ----
if [ "$MODE" = "arm" ]; then
    hr "ARMING TSP_IOWATCH_SAMPLER_V2 ($TICKS ticks = ${TICKS}s max)"
    # Restore the sampler from the rescued copy if /tmp was cleared.
    rin <<AEOF
S='$SAMPLER'
if [ ! -f "\$S" ]; then
    C="\$(ls -1t $RESCUED/rescued-*/tsp_iowatch_sampler.sh 2>/dev/null | head -1)"
    if [ -n "\$C" ]; then cp -p "\$C" "\$S"; echo "  restored sampler from \$C";
    else echo "  SAMPLER MISSING and no rescued copy - cannot arm"; exit 1; fi
fi
chmod 755 "\$S"
rm -f '$OFFFLAG' '$LOG'
echo "  sampler \$(md5sum "\$S" | cut -c1-12), off-flag cleared, old log removed"
AEOF
    r "test -f $SAMPLER" || { say "sampler not present - stopping"; exit 1; }

    # Background it in its own session, in a SEPARATE bounded call. Doing this
    # inside a heredoc once hung the ssh channel forever waiting on the child.
    r "cd /tmp && TICKS=$TICKS OUT=$LOG OFF=$OFFFLAG PIDNAME=openmw-0.51 \
       setsid nohup sh $SAMPLER >/dev/null 2>&1 < /dev/null & echo started"
    sleep 3
    hr "IS IT ACTUALLY RUNNING"
    r "ps | grep -c '[t]sp_iowatch_sampler' | sed 's/^/    matching processes: /'; \
       wc -l < $LOG 2>/dev/null | sed 's/^/    log lines so far: /'; \
       tail -1 $LOG 2>/dev/null | cut -c1-140 | sed 's/^/    /'"
    printf '\n'
    say "Cold-launch the game, load the save, WALK the route through the hitchy"
    say "spots. The sampler stops itself after $TICKS s, or on 'off'. Then:"
    printf '\n      bash ~/Downloads/tsp_iowatch.sh pull\n\n'
    exit 0
fi

if [ "$MODE" = "off" ]; then
    hr "STOPPING THE SAMPLER"
    r "touch '$OFFFLAG'; sleep 2; ps | grep -c '[t]sp_iowatch_sampler' | sed 's/^/    still running: /'"
    exit 0
fi

# ------------------------------------------------------------------- pull ----
hr "STOPPING AND FETCHING"
r "touch '$OFFFLAG'; sleep 2; wc -l < $LOG 2>/dev/null | sed 's/^/    log lines: /'"
L="$HOME/Downloads/tsp_iowatch_$STAMP.log"
mkdir -p "$HOME/Downloads"
scp $SSHO "$DEV:$LOG" "$L" >/dev/null 2>&1 || { say "could not fetch $LOG"; exit 1; }
say "saved $L ($(wc -l <"$L") lines)"

hr "REPORT"
awk '
function nz(x) { return (x == "" || x + 0 < 0) ? 0 : x + 0 }
/^t=/ {
    delete f
    for (i = 1; i <= NF; i++) { split($i, kv, "="); f[kv[1]] = kv[2] }
    if (f["ok"] != 1) { badrows++; next }
    n++
    tt = f["t"] + 0
    if (n == 1) {
        t0 = tt; rss0 = f["rss"]; sw0 = f["vswap"]
        maj0 = f["majf"]; smaj0 = f["pgmaj"]; in0 = f["pswpin"]; out0 = f["pswpout"]
        m0r0 = f["m0r"]; m1r0 = f["m1r"]; m0w0 = f["m0w"]; m1w0 = f["m1w"]
        mav0 = f["memavail"]; ca0 = f["cached"]
    }
    t1 = tt; rss1 = f["rss"]; sw1 = f["vswap"]
    maj1 = f["majf"]; smaj1 = f["pgmaj"]; in1 = f["pswpin"]; out1 = f["pswpout"]
    m0r1 = f["m0r"]; m1r1 = f["m1r"]; m0w1 = f["m0w"]; m1w1 = f["m1w"]
    mav1 = f["memavail"]; ca1 = f["cached"]
    if (f["rss"] + 0 > rssPk) { rssPk = f["rss"] + 0; rssPkT = tt }
    if (f["vswap"] + 0 > swPk) { swPk = f["vswap"] + 0 }
    if (mavLo == 0 || f["memavail"] + 0 < mavLo) mavLo = f["memavail"] + 0
    next
}
/^s=/ {
    delete g
    for (i = 1; i <= NF; i++) { split($i, kv, "="); g[kv[1]] = kv[2] }
    sn++
    nk = split("heap anon gpu so bin bsa ktx dev file stack other", K, " ")
    for (i = 1; i <= nk; i++) {
        k = K[i]; v = nz(g["r_" k])
        if (sn == 1) first[k] = v
        last[k] = v
        if (v > peak[k]) peak[k] = v
        sw = nz(g["w_" k]); if (sw > swpeak[k]) swpeak[k] = sw
    }
    if (sn == 1) nmap0 = g["nmap"]
    nmap1 = g["nmap"]
    next
}
END {
    if (n < 2) { print "  fewer than two usable rows - was the game running?"; exit }
    el = t1 - t0; if (el <= 0) el = 1
    printf "  window %d s, %d usable 1 Hz rows (%d unusable), %d smaps rows\n", el, n, badrows + 0, sn + 0
    printf "\n  FOOTPRINT\n"
    printf "    RSS      %6d -> peak %6d (at +%ds) -> %6d MB\n", \
           rss0/1024, rssPk/1024, rssPkT - t0, rss1/1024
    printf "    VmSwap   %6d -> peak %6d -> %6d MB\n", sw0/1024, swPk/1024, sw1/1024
    printf "    MemAvail %6d -> low  %6d -> %6d MB   Cached %d -> %d MB\n", \
           mav0/1024, mavLo/1024, mav1/1024, ca0/1024, ca1/1024

    printf "\n  WHICH DEVICE THE READS CAME FROM  (sectors x 512 B)\n"
    e_r = (m0r1 - m0r0) * 512 / 1024; s_r = (m1r1 - m1r0) * 512 / 1024
    e_w = (m0w1 - m0w0) * 512 / 1024; s_w = (m1w1 - m1w0) * 512 / 1024
    printf "    mmcblk0 eMMC   read %8.0f KB (%6.0f KB/s)   write %8.0f KB\n", e_r, e_r/el, e_w
    printf "    mmcblk1 SD     read %8.0f KB (%6.0f KB/s)   write %8.0f KB\n", s_r, s_r/el, s_w
    tot = e_r + s_r; if (tot <= 0) tot = 1
    printf "    -> %.0f%% of read traffic came off the eMMC, %.0f%% off the SD card\n", \
           100 * e_r / tot, 100 * s_r / tot
    printf "    (the eMMC carries the swapfile AND the staged textures AND the\n"
    printf "     891 MB navmesh, so a high eMMC share is not by itself the textures)\n"

    printf "\n  FAULTS AND SWAP  (same unit on each line, never a pages-vs-events ratio)\n"
    printf "    process major faults   %8d   %6.1f/s\n", maj1 - maj0, (maj1 - maj0) / el
    printf "    system  major faults   %8d   %6.1f/s\n", smaj1 - smaj0, (smaj1 - smaj0) / el
    printf "    swap read              %8.0f KB  %6.0f KB/s\n", (in1 - in0) * 4, (in1 - in0) * 4 / el
    printf "    swap write             %8.0f KB  %6.0f KB/s\n", (out1 - out0) * 4, (out1 - out0) * 4 / el

    if (sn < 1) { print "\n  no smaps rows - SMAPS_EVERY never elapsed"; exit }
    printf "\n  WHERE THE MEMORY IS, BY REGION  (Rss kB; this is the 516 MB question)\n"
    printf "    %-8s %10s %10s %10s %10s %8s\n", "region", "first", "peak", "last", "growth", "share"
    nk = split("heap anon gpu so bin bsa ktx dev file stack other", K, " ")
    tgrow = 0
    for (i = 1; i <= nk; i++) { d = last[K[i]] - first[K[i]]; if (d > 0) tgrow += d }
    if (tgrow <= 0) tgrow = 1
    bigk = ""; bigv = 0
    for (i = 1; i <= nk; i++) {
        k = K[i]; d = last[k] - first[k]
        printf "    %-8s %10d %10d %10d %+10d %7.0f%%\n", \
               k, first[k], peak[k], last[k], d, (d > 0 ? 100 * d / tgrow : 0)
        if (d > bigv) { bigv = d; bigk = k }
    }
    printf "    mappings %d -> %d\n", nmap0 + 0, nmap1 + 0
    printf "\n  LARGEST GROWER: %s, +%d kB = %.0f MB, %.0f%% of all growth\n", \
           bigk, bigv, bigv / 1024, 100 * bigv / tgrow
    if (bigk == "heap" || bigk == "anon")
        print "  -> glibc/anonymous. That is the global-map overlay hypothesis:\n" \
              "     954x864x4 = 3.14 MB each, so divide the growth by 3.14 MB for a\n" \
              "     count, and grep the log for pending_removal_cams= to confirm."
    else if (bigk == "gpu")
        print "  -> driver mappings. Invisible to mallinfo, which is exactly why the\n" \
              "     09-09 doc read a plateau at 292 MB while RSS was 691 MB."
    else if (bigk == "ktx" || bigk == "bsa" || bigk == "file")
        print "  -> mmapped ASSETS never unmapped. Then the resource cache is the\n" \
              "     lever, i.e. TSP_NO_LOADPURGE, not the swap settings."
    else
        print "  -> see the table; no single region dominates."
}
' "$L"

printf '\n'
say "The eMMC-vs-SD read split above is the real test of the texture wiring:"
say "run pull once wired and once unwired and the share should move."
printf '\n'
