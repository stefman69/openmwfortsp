#!/usr/bin/env bash
# TSP_ZRAM_V1 - take the storage device out of the swap path, and measure Steve's
# small-transfer hypothesis properly while we are at it.
#
#   bash ~/Downloads/tsp_zram.sh check    # READ ONLY, instant. Do this first.
#   bash ~/Downloads/tsp_zram.sh on       # add zram swap at high priority, then play
#   bash ~/Downloads/tsp_zram.sh pull     # after you quit
#   bash ~/Downloads/tsp_zram.sh off      # swapoff zram, back to eMMC only
#
# ============================================================================
# STEVE'S HYPOTHESIS, AND WHERE IT LANDS
# ============================================================================
# "the same reason moving 40,000 1kb files takes way more time than moving one
#  40,000kb file... it's the inflow and outflow of these much smaller files in
#  memory, not a pressure from memory being lowered"
#
# Half right, and the half that is right matters more than the half that is not.
#
# NOT filesystem overhead: the swapfile's blocks are mapped once at swapon, and
# swap I/O goes to the block layer by sector, bypassing the inode/dentry path.
# There is no per-FILE cost in swap - no directory lookups, no metadata.
#
# But per-OPERATION cost is real and it is the dominant term: every swap-in is a
# block request with submission, completion, an interrupt, and on eMMC a command
# setup. That scales with the NUMBER of operations, which is the actual content of
# the 40,000-files intuition.
#
# ⚠ Taken seriously it argues AGAINST the vm.page-cluster=0 in tsp_swaptune:
#     page-cluster 0 -> 1 page  per fault: MORE ops, each tiny
#     page-cluster 3 -> 8 pages per fault: FEWER ops, each bigger   (current)
# "fewer, bigger" is the 40,000-files lesson, so it points to RAISING page-cluster.
# The existing data cannot settle it: swap pages/major-fault came out 2.10 and 1.86
# across two sessions while page-cluster=3 requests 8, but pgmajfault counts
# file-backed faults too, so that ratio is diluted by an unknown amount. Guessing
# the direction from it would be exactly the mistake that has cost us all week.
#
# So this captures the number that DOES settle it: /proc/diskstats field 4 is
# rd_ios, the OPERATION COUNT. With sectors and ops together,
#     avg bytes per op = (rd_sectors delta * 512) / (rd_ios delta)
# is the measured answer to the 40,000-files question on the swap device. My
# sampler has only ever recorded sectors, never ops.
#
# ============================================================================
# BUT THE BETTER MOVE IS TO DELETE THE QUESTION
# ============================================================================
# If the cost is the OFFLOAD rather than the memory pressure - which is what Steve
# is arguing and what the flat-RSS/rising-VmSwap data supports - then do not tune
# the transfer. Remove the storage device from the path.
#
#   eMMC 4 KB random read   ~300-1000 us   block layer + command + interrupt
#   zram 4 KB decompress      ~10-50 us    memcpy + lz4, no device involved
#
# ~20x cheaper per page, and the per-operation overhead disappears entirely because
# there is no operation - no queue, no command, no erase block. It is also exactly
# the trade Steve asked for: the CPU cost of compress/decompress is the "1-2 fps
# slower", paid smoothly every frame; the "massive dips" are eMMC stalls and they
# have nothing left to stall on.
#
# Memory arithmetic, corrected: zram disksize is the UNCOMPRESSED capacity it
# advertises. disksize=320M accepts 320 MB of pages and holds them in ~107 MB of
# real RAM at 3:1, or ~128 MB at 2.5:1. Against 320 MB of uncompressed anon pages
# that is a net gain of ~200 MB, not a cost.
#
# SAFETY: this never touches the existing swapfile. zram is added at priority 100
# against the file's -2, so swap-out prefers zram and spills to eMMC only when zram
# is full. There is no moment with no swap available, and `off` is one swapoff.
#
# Rule Zero: file, not paste; r() uses -n, rin() takes the heredoc (NEVER -n).
# No grep -r. No $(grep -c x f || echo 0). No apostrophe inside any awk program.
# Single-value /proc and /sys reads use cat, never `read -r x < file`: sysctl-style
# files hand back the whole value on one read() then EOF, and busybox AND dash both
# return only the FIRST CHARACTER ("6" for "60"). That bug was caught in test.

set -u
MODE="${1:-check}"
case "$MODE" in
    check|on|off|pull) : ;;
    *) echo "usage: bash $0 check|on|pull|off"; exit 2 ;;
esac

TSP="${TSP:-root@192.168.1.12}"
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6"
DL="${DL:-$HOME/Downloads}"
STAMP="$(date +%Y%m%d-%H%M%S)"
ZSIZE="${ZSIZE:-320M}"
ZPRIO="${ZPRIO:-100}"
REP="$DL/tsp-zram-$MODE-$STAMP.txt"

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }
die() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

r 'echo ok' >/dev/null 2>&1 || die "cannot reach the TSP at $TSP"

# ----------------------------------------------------------------------------
if [ "$MODE" = "check" ]; then
rin 'sh -s' <<'REMOTE' 2>&1 | tee "$REP"
# ---- TSP_ZRAM_CHECK_BEGIN ----
echo "########## 1. IS ZRAM AVAILABLE ##########"
FOUND=0
if [ -e /sys/class/zram-control ]; then
    echo "  OK   /sys/class/zram-control exists - zram is built in or already loaded"
    FOUND=1
else
    echo "  /sys/class/zram-control absent - trying modprobe"
    if modprobe zram 2>/dev/null; then
        sleep 1
        if [ -e /sys/class/zram-control ]; then
            echo "  OK   modprobe zram worked"
            FOUND=1
        else
            echo "  modprobe returned 0 but no zram-control appeared"
        fi
    else
        echo "  modprobe zram failed"
    fi
fi
if [ -e /dev/zram0 ]; then echo "  /dev/zram0 present"; else echo "  /dev/zram0 not present (hot_add can create it)"; fi
echo "  -- is zram in the kernel config --"
if [ -r /proc/config.gz ] && command -v zcat >/dev/null 2>&1; then
    zcat /proc/config.gz 2>/dev/null | grep -E 'CONFIG_ZRAM|CONFIG_ZSMALLOC|CONFIG_CRYPTO_LZ4|CONFIG_CRYPTO_LZO' | sed 's/^/    /'
else
    echo "    (no readable /proc/config.gz)"
fi
echo "  -- loadable modules matching zram --"
find /lib/modules -maxdepth 4 -name 'zram*' 2>/dev/null | head -5 | sed 's/^/    /'
find /lib/modules -maxdepth 4 -name 'zsmalloc*' 2>/dev/null | head -5 | sed 's/^/    /'
echo "  -- is zram already loaded --"
grep -E '^(zram|zsmalloc)' /proc/modules 2>/dev/null | sed 's/^/    /' || echo "    (not in /proc/modules - may be built in)"
echo

echo "########## 2. IS zram0 ALREADY IN USE BY THE STOCK OS ##########"
if [ -d /sys/block/zram0 ]; then
    printf '  disksize:  %s\n' "$(cat /sys/block/zram0/disksize 2>/dev/null)"
    printf '  algorithm: %s\n' "$(cat /sys/block/zram0/comp_algorithm 2>/dev/null)"
    if [ "$(cat /sys/block/zram0/disksize 2>/dev/null)" = "0" ]; then
        echo "  disksize 0 = unconfigured and free to use"
    else
        echo "  ** disksize is NON-ZERO - something already configured zram0."
        echo "     on will REFUSE rather than clobber it."
    fi
else
    echo "  /sys/block/zram0 absent"
fi
echo "  -- current swap layout --"
sed 's/^/    /' /proc/swaps 2>/dev/null
echo

echo "########## 3. THE 40,000-FILES QUESTION, MEASURED RIGHT NOW ##########"
echo "  /proc/diskstats: field 3 name, 4 rd_ios, 6 rd_sectors, 8 wr_ios, 10 wr_sectors"
echo "  These are cumulative since boot, so this is a whole-uptime average - the"
echo "  play-session figure comes from on/pull. Still worth seeing the shape."
echo
awk '
$3 == "mmcblk0" || $3 == "mmcblk1" || $3 ~ /^zram/ {
    rio = $4 + 0; rsec = $6 + 0; wio = $8 + 0; wsec = $10 + 0
    printf "  %-9s read %10d ops %12d sectors", $3, rio, rsec
    if (rio > 0) printf "  avg %7.1f KB/op", rsec * 512.0 / rio / 1024.0
    else printf "  avg       -    "
    printf "\n"
    printf "  %-9s writ %10d ops %12d sectors", "", wio, wsec
    if (wio > 0) printf "  avg %7.1f KB/op", wsec * 512.0 / wio / 1024.0
    else printf "  avg       -    "
    printf "\n"
}' /proc/diskstats
echo
echo "  How to read it: mmcblk0 is eMMC and carries the swapfile (/mnt/UDISK)."
echo "  If its read avg is ~4-8 KB/op, the transfers really are small and many,"
echo "  which is Steve's hypothesis confirmed, and page-cluster should go UP."
echo "  If it is ~32 KB/op, clustering is already happening and the question is"
echo "  instead how much of each 32 KB is wasted."
echo

echo "########## 4. SWAP DEVICE QUEUE SETTINGS ##########"
for d in mmcblk0 mmcblk1; do
    [ -d "/sys/block/$d/queue" ] || continue
    echo "  -- $d --"
    for f in scheduler nr_requests read_ahead_kb rotational logical_block_size max_sectors_kb nomerges; do
        [ -r "/sys/block/$d/queue/$f" ] && printf '    %-20s %s\n' "$f" "$(cat "/sys/block/$d/queue/$f" 2>/dev/null)"
    done
done
echo

echo "########## 5. VM KNOBS ##########"
for k in swappiness page-cluster watermark_scale_factor vfs_cache_pressure min_free_kbytes; do
    [ -r "/proc/sys/vm/$k" ] && printf '  vm.%-24s %s\n' "$k" "$(cat "/proc/sys/vm/$k" 2>/dev/null)"
done
echo "  defaults: swappiness 60, page-cluster 3, watermark_scale_factor 10"
echo

echo "########## VERDICT ##########"
if [ "$FOUND" -eq 1 ]; then
    DS="$(cat /sys/block/zram0/disksize 2>/dev/null)"
    if [ -d /sys/block/zram0 ] && [ "${DS:-0}" != "0" ]; then
        echo "  zram is available BUT zram0 is already configured (disksize $DS)."
        echo "  Tell me and I will add a second device with hot_add instead."
    else
        echo "  ZRAM IS AVAILABLE. Next:"
        echo "     bash ~/Downloads/tsp_zram.sh on"
        echo "  then launch and play the spots that micro-stutter."
    fi
else
    echo "  ZRAM IS NOT AVAILABLE on this kernel. Fall back to tuning the eMMC"
    echo "  path instead, and the direction is decided by section 3 above."
fi
# ---- TSP_ZRAM_CHECK_END ----
REMOTE
echo
echo "full report: $REP"
exit 0
fi

# ----------------------------------------------------------------------------
if [ "$MODE" = "off" ]; then
rin 'sh -s' <<'REMOTE' 2>&1 | tee "$REP"
S=/mnt/SDCARD
touch "$S/tsp_zram_off"
for p in $(ps 2>/dev/null | awk '/[t]sp_zram_sampler/{print $1}'); do kill "$p" 2>/dev/null; done
echo "swap before:"; sed 's/^/  /' /proc/swaps
if grep -q '^/dev/zram0' /proc/swaps 2>/dev/null; then
    echo "swapoff /dev/zram0 - this moves any pages held there back into RAM,"
    echo "so it can take a few seconds and needs the RAM to be free."
    if swapoff /dev/zram0 2>/dev/null; then
        echo "  OK swapoff succeeded"
        echo 1 > /sys/block/zram0/reset 2>/dev/null && echo "  OK zram0 reset"
    else
        echo "  FAILED - not enough free RAM to absorb the pages right now."
        echo "  Reboot the device; zram is not persistent and will be gone."
    fi
else
    echo "zram0 is not in /proc/swaps - nothing to remove"
fi
echo "swap after:"; sed 's/^/  /' /proc/swaps
REMOTE
exit 0
fi

# ----------------------------------------------------------------------------
if [ "$MODE" = "pull" ]; then
rin 'sh -s' <<'REMOTE' 2>&1 | tee "$REP"
S=/mnt/SDCARD
G=$S/data/ports/openmw

echo "########## 1. DID ZRAM ACTUALLY GET USED ##########"
sed 's/^/  /' /proc/swaps 2>/dev/null
echo
if [ -r /sys/block/zram0/mm_stat ]; then
    echo "  -- zram0 mm_stat: orig compr mem_used same_pages huge_pages --"
    cat /sys/block/zram0/mm_stat | sed 's/^/    /'
    awk '{
        orig=$1+0; compr=$2+0; used=$3+0
        printf "    stored        %8.1f MB of pages\n", orig/1048576.0
        printf "    compressed to %8.1f MB\n", compr/1048576.0
        printf "    real RAM used %8.1f MB (incl. allocator overhead)\n", used/1048576.0
        if (compr > 0) printf "    ratio         %8.2f : 1\n", orig/compr
        if (orig == 0) print "    NOTHING WAS STORED - nothing swapped to zram this session."
    }' /sys/block/zram0/mm_stat
else
    echo "  (no /sys/block/zram0/mm_stat - zram not set up)"
fi
echo

echo "########## 2. THE 40,000-FILES QUESTION, FOR THIS SESSION ##########"
if [ -f /tmp/tsp_zram.log ]; then
    awk '
    /^t=/ {
        delete f
        for(i=1;i<=NF;i++){k=index($i,"="); if(k) f[substr($i,1,k-1)]=substr($i,k+1)+0}
        n++
        t[n]=f["t"]; ok[n]=f["ok"]; rss[n]=f["rss"]; vsw[n]=f["vswap"]
        pg[n]=f["pgmaj"]; si[n]=f["pswpin"]; so[n]=f["pswpout"]
        r0i[n]=f["m0rio"]; r0s[n]=f["m0rsec"]; r1i[n]=f["m1rio"]; r1s[n]=f["m1rsec"]
    }
    END {
        if(n<2){ print "  (too few rows)"; exit }
        for(i=2;i<=n;i++){
            dt=t[i]-t[i-1]; if(dt<=0) continue
            if(ok[i]!=1||ok[i-1]!=1) continue
            w++
            gm=(pg[i]-pg[i-1])/dt; if(gm<0) gm=0
            s=(si[i]-si[i-1])/dt;  if(s<0) s=0
            o=(so[i]-so[i-1])/dt;  if(o<0) o=0
            di0=r0i[i]-r0i[i-1]; ds0=r0s[i]-r0s[i-1]
            di1=r1i[i]-r1i[i-1]; ds1=r1s[i]-r1s[i-1]
            if(di0>0){ ops0+=di0; sec0+=ds0 }
            if(di1>0){ ops1+=di1; sec1+=ds1 }
            sg+=gm; ss+=s; sos+=o
            if(gm>pk) pk=gm
            if(vsw[i]>mx) mx=vsw[i]
            if(rss[i]>mr) mr=rss[i]
            if(gm>=200) big++; else if(gm>=50) mid++; else small++
        }
        if(!w){ print "  (game pid never seen)"; exit }
        printf "  game-live %d s   peak RSS %.1f MB   peak VmSwap %.1f MB\n", w, mr/1024.0, mx/1024.0
        print  ""
        print  "  THE ANSWER TO THE HYPOTHESIS - average operation size, per device:"
        if(ops0>0) printf "    eMMC  mmcblk0  %8.1f ops/s   %8.1f KB/op   (swapfile lives here)\n", ops0/w, sec0*512.0/ops0/1024.0
        else       printf "    eMMC  mmcblk0        no read ops this session\n"
        if(ops1>0) printf "    SD    mmcblk1  %8.1f ops/s   %8.1f KB/op   (assets)\n", ops1/w, sec1*512.0/ops1/1024.0
        else       printf "    SD    mmcblk1        no read ops this session\n"
        print  ""
        print  "    4-8 KB/op on eMMC  = small and many, Steve is right, raise page-cluster"
        print  "    ~32 KB/op on eMMC  = already clustered, the waste question instead"
        print  ""
        printf "  major faults  mean %8.1f /s   peak %8.1f /s\n", sg/w, pk
        printf "  swap reads    mean %8.1f KB/s\n", ss*4.0/w
        printf "  swap writes   mean %8.1f KB/s\n", sos*4.0/w
        print  ""
        print  "  SPIKINESS - the number that matters for micro-stutter:"
        printf "    seconds majflt >= 200 /s : %4d  (%.0f%%)\n", big+0, 100.0*(big+0)/w
        printf "    seconds       50-199 /s : %4d  (%.0f%%)\n", mid+0, 100.0*(mid+0)/w
        printf "    seconds        < 50  /s : %4d  (%.0f%%)\n", small+0, 100.0*(small+0)/w
        print  ""
        print  "  BASELINE, eMMC swap only, two sessions:"
        print  "    majflt mean  51.8/s peak 2363   swap 434 KB/s   peak VmSwap 133.8 MB"
        print  "    majflt mean 124.2/s peak 3205   swap 923 KB/s   peak VmSwap 100.0 MB"
    }' /tmp/tsp_zram.log
else
    echo "  (no sampler log)"
fi
echo

echo "########## 3. HITCHES FROM THE RING ##########"
if ls "$S"/tsp_ring.[0-9]* >/dev/null 2>&1; then
    sh "$S/tsp_post.sh" "$S"/tsp_ring.[0-9]* 2>&1 | grep -vE '^  frame '
    echo "  BASELINE after-spike: 29.5% then 58.9% of frames faulting"
else
    echo "  (no ring dumps - nothing crossed 1000 ms, which is a good sign)"
fi
REMOTE
echo
echo "=================================================================="
echo "  Two things to read: the KB/op line settles your hypothesis, and"
echo "  SPIKINESS says whether the stutter actually smoothed out."
echo "  Revert:  bash ~/Downloads/tsp_zram.sh off"
echo "=================================================================="
exit 0
fi

# ----------------------------------------------------------------------------
# on
# ----------------------------------------------------------------------------
cat > "$DL/.tsp_zram_sampler.sh" <<'SAMP'
#!/bin/sh
# Adds rd_ios alongside rd_sectors so average operation size is computable.
OUT=${OUT:-/tmp/tsp_zram.log}
OFF=${OFF:-/mnt/SDCARD/tsp_zram_off}
TICKS=${TICKS:-2400}
PIDNAME=${PIDNAME:-openmw}
printf '# TSP_ZRAM_SAMPLER_V1 start=%s pidname=%s\n' "$(date +%s)" "$PIDNAME" > "$OUT"
pid=""; i=0; recheck=0
while [ "$i" -lt "$TICKS" ]; do
    [ -f "$OFF" ] && break
    if [ -z "$pid" ] || [ ! -r "/proc/$pid/stat" ]; then
        if [ "$recheck" -le 0 ]; then
            pid="$(pidof "$PIDNAME" 2>/dev/null | cut -d' ' -f1)"; recheck=3
        else recheck=$((recheck - 1)); fi
    fi
    pgmaj=0; pswpin=0; pswpout=0
    while read -r k v _r; do
        case "$k" in pgmajfault) pgmaj=$v ;; pswpin) pswpin=$v ;; pswpout) pswpout=$v ;; esac
    done < /proc/vmstat
    cached=0; swapfree=0
    while read -r k v _u; do
        case "$k" in Cached:) cached=$v ;; SwapFree:) swapfree=$v ;; esac
    done < /proc/meminfo
    m0rio=0; m0rsec=0; m1rio=0; m1rsec=0; zrio=0; zrsec=0
    while read -r _a _b name rio _rm rsec _t1 _t2 _t3 _t4 _rest; do
        case "$name" in
            mmcblk0) m0rio=$rio; m0rsec=$rsec ;;
            mmcblk1) m1rio=$rio; m1rsec=$rsec ;;
            zram0)   zrio=$rio;  zrsec=$rsec ;;
        esac
    done < /proc/diskstats
    rss=-1; vswap=-1; majf=-1; ok=0
    if [ -n "$pid" ] && [ -r "/proc/$pid/stat" ]; then
        if read -r st < "/proc/$pid/stat" 2>/dev/null; then
            tf="${st##*") "}"
            # shellcheck disable=SC2086
            set -- $tf
            if [ $# -ge 10 ]; then majf=${10}; ok=1; fi
        fi
        if [ "$ok" -eq 1 ] && [ -r "/proc/$pid/status" ]; then
            rss=0; vswap=0
            while read -r k v _u; do
                case "$k" in VmRSS:) rss=$v ;; VmSwap:) vswap=$v ;; esac
            done < "/proc/$pid/status"
        fi
    fi
    printf 't=%s pid=%s ok=%s rss=%s vswap=%s majf=%s pgmaj=%s pswpin=%s pswpout=%s cached=%s swapfree=%s m0rio=%s m0rsec=%s m1rio=%s m1rsec=%s zrio=%s zrsec=%s\n' \
        "$(date +%s)" "${pid:-0}" "$ok" "$rss" "$vswap" "$majf" "$pgmaj" "$pswpin" \
        "$pswpout" "$cached" "$swapfree" "$m0rio" "$m0rsec" "$m1rio" "$m1rsec" \
        "$zrio" "$zrsec" >> "$OUT"
    sleep 1; i=$((i + 1))
done
SAMP
scp -q $SSH_OPTS "$DL/.tsp_zram_sampler.sh" "$TSP:/tmp/tsp_zram_sampler.sh" </dev/null \
    || die "sampler scp failed"

echo "MODE=on   zram disksize=$ZSIZE priority=$ZPRIO"
echo

rin "STAMP=$STAMP ZSIZE=$ZSIZE ZPRIO=$ZPRIO sh -s" <<'REMOTE' 2>&1 | tee "$REP"
# ---- TSP_ZRAM_ON_BEGIN ----
S=/mnt/SDCARD
G=$S/data/ports/openmw
L=$S/Roms/PORTS/Morrowind.sh

echo "########## 1. GATES BEFORE TOUCHING ANYTHING ##########"
F=0
[ -e /sys/class/zram-control ] || modprobe zram 2>/dev/null
if [ ! -e /sys/class/zram-control ] && [ ! -d /sys/block/zram0 ]; then
    echo "  FAIL zram is not available - run check first"
    exit 1
fi
if grep -q '^/dev/zram0' /proc/swaps 2>/dev/null; then
    echo "  zram0 is ALREADY swap - reusing it, not reconfiguring"
    ALREADY=1
else
    ALREADY=0
    DS="$(cat /sys/block/zram0/disksize 2>/dev/null)"
    if [ -n "$DS" ] && [ "$DS" != "0" ]; then
        echo "  FAIL zram0 already has disksize $DS and is not swap - something else"
        echo "       owns it. REFUSING to clobber. Tell Claude and it will hot_add a"
        echo "       second device instead."
        exit 1
    fi
fi
# a swapfile must still exist as the fallback tier
grep -q 'openmw-swapfile\|/mnt/UDISK' /proc/swaps 2>/dev/null \
    && echo "  OK   the eMMC swapfile is still present as the spill tier" \
    || echo "  NOTE no eMMC swapfile in /proc/swaps - zram will be the only swap"
free 2>/dev/null | sed 's/^/  /'
echo

if [ "$ALREADY" -eq 0 ]; then
echo "########## 2. CONFIGURE zram0 ##########"
AVAIL="$(cat /sys/block/zram0/comp_algorithm 2>/dev/null)"
echo "  algorithms available: ${AVAIL:-unknown}"
for a in lz4 lzo-rle lzo zstd; do
    case " $AVAIL " in
        *" $a "*|*"[$a]"*)
            echo "$a" > /sys/block/zram0/comp_algorithm 2>/dev/null \
                && { echo "  selected: $a"; break; } ;;
    esac
done
echo "  algorithm now: $(cat /sys/block/zram0/comp_algorithm 2>/dev/null)"
echo "$ZSIZE" > /sys/block/zram0/disksize 2>/dev/null
GOT="$(cat /sys/block/zram0/disksize 2>/dev/null)"
echo "  disksize requested $ZSIZE, got $GOT bytes"
if [ "${GOT:-0}" = "0" ]; then
    echo "  FAIL disksize did not take - aborting, nothing else changed"
    exit 1
fi
if mkswap /dev/zram0 >/dev/null 2>&1; then echo "  OK   mkswap"; else echo "  FAIL mkswap"; F=1; fi
if [ "$F" -eq 0 ]; then
    if swapon -p "$ZPRIO" /dev/zram0 2>/dev/null; then
        echo "  OK   swapon -p $ZPRIO /dev/zram0"
    else
        echo "  swapon with -p failed, retrying without priority"
        swapon /dev/zram0 2>/dev/null && echo "  OK   swapon (default priority)" \
            || { echo "  FAIL swapon"; F=1; }
    fi
fi
if [ "$F" -ne 0 ]; then
    echo "  rolling back"
    swapoff /dev/zram0 2>/dev/null
    echo 1 > /sys/block/zram0/reset 2>/dev/null
    exit 1
fi
echo
fi

echo "########## 3. SWAP LAYOUT NOW ##########"
sed 's/^/  /' /proc/swaps
echo
echo "  zram must show a HIGHER priority number than the eMMC file, or swap-out"
echo "  will still prefer eMMC and this test proves nothing."
ZP="$(awk '/^\/dev\/zram0/{print $5}' /proc/swaps)"
FP="$(awk '/UDISK|swapfile/{print $5}' /proc/swaps | head -1)"
printf '  zram priority [%s]   file priority [%s]\n' "${ZP:-none}" "${FP:-none}"
if [ -n "$ZP" ] && [ -n "$FP" ] && [ "$ZP" -gt "$FP" ] 2>/dev/null; then
    echo "  OK   zram is preferred"
elif [ -n "$ZP" ] && [ -z "$FP" ]; then
    echo "  OK   zram is the only swap"
else
    echo "  WARNING zram is NOT preferred - results will be muddy"
fi
echo

echo "########## 4. SAMPLER ##########"
rm -f "$S/tsp_zram_off"
for p in $(ps 2>/dev/null | awk '/[t]sp_zram_sampler|[t]sp_swaptune_sampler|[t]sp_relief_sampler|[t]sp_iowatch_sampler|[t]sp_swaptune_applier/{print $1}'); do
    kill "$p" 2>/dev/null
done
BINNAME=openmw
if [ -f "$L" ]; then
    CAND="$(sed -n 's/^[[:space:]]*OPENMW_BIN=["'"'"']*\([^"'"'"']*\).*/\1/p' "$L" | tail -1)"
    [ -n "$CAND" ] && BINNAME="${CAND##*/}"
fi
echo "  pidof name: $BINNAME"
chmod +x /tmp/tsp_zram_sampler.sh
rm -f /tmp/tsp_zram.log
if command -v setsid >/dev/null 2>&1; then
    OUT=/tmp/tsp_zram.log PIDNAME="$BINNAME" setsid /tmp/tsp_zram_sampler.sh >/dev/null 2>&1 &
else
    OUT=/tmp/tsp_zram.log PIDNAME="$BINNAME" nohup /tmp/tsp_zram_sampler.sh >/dev/null 2>&1 &
fi
sleep 3
SP="$(ps 2>/dev/null | awk '/[t]sp_zram_sampler/{n++} END{print n+0}')"
ROWS="$(grep -c '^t=' /tmp/tsp_zram.log 2>/dev/null; true)"
echo "  sampler running $SP, rows $ROWS"
echo "  a sample row, so the reader is known to parse the real thing:"
grep -m1 '^t=' /tmp/tsp_zram.log | tr ' ' '\n' | sed 's/^/    /'
echo

echo "########## 5. CLEAN CAPTURE ##########"
[ -s "$G/openmw_log.txt" ] && mv "$G/openmw_log.txt" "$G/openmw_log.txt.zram-$STAMP" && echo "  log rotated"
A="$S/tsp_hitch_archive_$STAMP"; k=0
for d in "$S"/tsp_ring.[0-9]*; do
    [ -f "$d" ] || continue
    mkdir -p "$A"; cp -p "$d" "$A/" && rm -f "$d" && k=$((k + 1))
done
echo "  ring dumps archived: $k"
printf 'TSP_RING_TRIG=1000\nTSP_RING_MAX=12\n' > "$S/tsp_ring.conf"
[ -f "$S/tsp_ring_off" ] && mv "$S/tsp_ring_off" "$S/tsp_ring_off.parked-$STAMP"
sync
echo

echo "########## READY CHECK ##########"
E=0
grep -q '^/dev/zram0' /proc/swaps 2>/dev/null && echo "  OK   zram0 is active swap" || { echo "  FAIL zram0 not swap"; E=1; }
[ "${SP:-0}" -ge 1 ] && echo "  OK   sampler running" || { echo "  FAIL sampler"; E=1; }
[ "${ROWS:-0}" -ge 2 ] && echo "  OK   rows appearing" || { echo "  FAIL no rows"; E=1; }
[ -s "$G/openmw_log.txt" ] && { echo "  FAIL log not empty"; E=1; } || echo "  OK   log clean"
echo
[ "$E" -eq 0 ] && echo "READY" || echo "NOT READY"
# ---- TSP_ZRAM_ON_END ----
REMOTE

echo
echo "=================================================================="
echo "  Launch and play the spots that micro-stutter. Nothing is timed,"
echo "  the sampler runs for 40 minutes and stops on its own."
echo
echo "  What to feel for: the dips should flatten into a small constant"
echo "  cost, because swap-in is now a decompress instead of an eMMC read."
echo
echo "  When you quit:  bash ~/Downloads/tsp_zram.sh pull"
echo "  Revert:         bash ~/Downloads/tsp_zram.sh off"
echo "=================================================================="
