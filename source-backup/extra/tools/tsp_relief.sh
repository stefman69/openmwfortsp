#!/usr/bin/env bash
# TSP_RELIEF_V1 - two patches. Both config, both one line, both reversible.
#
#   bash ~/Downloads/tsp_relief.sh on     # apply, then just PLAY normally
#   bash ~/Downloads/tsp_relief.sh pull   # after you quit, the numbers
#   bash ~/Downloads/tsp_relief.sh off    # put everything back
#
# ============================================================================
# PATCH 1 - vm.swappiness 150 -> 10.  Aimed at the HITCHING.
# ============================================================================
# claude/RESULT-hitches-are-sd-major-faults-readahead-fix-20260907.md raised
# swappiness to 150 on this reasoning, quoted verbatim:
#
#   "high swappiness protects file cache, which is what we want, and swap lives
#    on eMMC while the assets live on the slower SD card"
#
# That was reasoned from believing the hitches were SD asset reads. Tonight
# disproved that. What swappiness=150 actually tells the kernel is: aggressively
# evict ANONYMOUS pages to preserve FILE cache.
#
#   anonymous pages = the game heap, ~450 MB, touched every frame
#   file cache      = assets, read once, re-readable at 512 KB readahead
#
# We told the kernel to throw out the hot working set to protect the cold one.
# The 09-10 capture shows exactly that: RSS FLAT at ~615 MB while VmSwap climbs
# 57 -> 134 MB over the session. The game is not growing; the kernel is steadily
# pushing its live pages to eMMC and the game keeps touching them back in. Every
# one of those is a major fault, and faulting frames measured 2.11x slower.
#
# Lowering swappiness keeps the game resident and lets the file cache take the
# hit instead. It does NOT require reducing the 196 MB by one byte.
#
# ============================================================================
# PATCH 2 - TSP_NO_SHADER_WARMDRAW=1.  Aimed at the LOADING BAR.
# ============================================================================
# The newest log shows FOUR gate runs in one launch, 15.3 s total:
#
#   23:53:08.602  TSP_WARMDRAW_GATE drained in 240 frames remaining=1  ms=3799.9
#   23:53:25.571  TSP_VARIANT_PRECOMPILE_V1 requested=6 built=6 failed=0
#   23:53:29.463  TSP_WARMDRAW_GATE drained in 240 frames remaining=14 ms=3891.76
#   23:53:36.358  TSP_WARMDRAW_GATE drained in 240 frames remaining=14 ms=3809.39
#   23:53:40.235  TSP_WARMDRAW_GATE drained in 240 frames remaining=14 ms=3803.14
#   23:53:44.745  TSP_WARMDRAIN_V5 backlog cleared
#
# It drains to 1, then precompile runs and the backlog is back to the full 14
# (highest queued n=14), then three consecutive 3.8 s runs fail to move it at all.
# shader-variant-precompile-and-warmdrain-20260908.md defines success as
# remaining=0 ms=2000-5000. This is failing that on three of four runs.
#
# Risk, stated plainly: the warm-draw exists to stop shader compile stalls during
# gameplay, and this turns it off. But TSP_PRGCACHE_V1 measured link at 50 ms ->
# 1.1 ms with hit=32 miss=0 reject=0, so the warm-draw is plausibly solving a
# problem the program binary cache already solved. If stalls come back, run off.
#
# The two patches have DIFFERENT observable effects - hitching vs load-bar length
# - so applying both at once is not a confound.
#
# ============================================================================
# WHAT IS NOT BEING ATTEMPTED, AND WHY
# ============================================================================
# The 196 MB allocated in the load gap is INVARIANT: 194132-197823 kB across 11
# loads and every config tried tonight (ktx on/off, 892 files parked, recordmem
# on/off), always 9 cells. It is deterministic and structural. Attributing it
# further needs trace points inside changeCellGrid, which means a rebuild. That
# is a separate job and it is not needed for either patch here.
#
# Rule Zero: file, not paste; r() uses -n, rin() takes the heredoc (NEVER -n).
# No grep -r. No $(grep -c x f || echo 0). No apostrophe inside any awk program.

set -u
MODE="${1:-}"
case "$MODE" in
    on|off|pull) : ;;
    *) echo "usage: bash $0 on|pull|off"; exit 2 ;;
esac

TSP="${TSP:-root@192.168.1.12}"
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6"
DL="${DL:-$HOME/Downloads}"
STAMP="$(date +%Y%m%d-%H%M%S)"
SWAP_ON=10
SWAP_OFF=150
REP="$DL/tsp-relief-$MODE-$STAMP.txt"

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }
die() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

r 'echo ok' >/dev/null 2>&1 || die "cannot reach the TSP at $TSP"

if [ "$MODE" = "pull" ]; then
    rin 'sh -s' <<'REMOTE' 2>&1 | tee "$REP"
S=/mnt/SDCARD
G=$S/data/ports/openmw
LG=$G/openmw_log.txt

echo "########## 1. DID THE PATCHES ACTUALLY TAKE ##########"
printf '  vm.swappiness now:        %s   (patched value is 10, old was 150)\n' "$(cat /proc/sys/vm/swappiness 2>/dev/null)"
printf '  TSP_SWAPPINESS in conf:   %s\n' \
    "$(sed -n 's/^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}TSP_SWAPPINESS=\(.*\)$/\2/p' "$S/tsp_iotune.conf" 2>/dev/null | tail -1)"
printf '  TSP_NO_SHADER_WARMDRAW:   %s\n' \
    "$(sed -n 's/^[[:space:]]*export[[:space:]][[:space:]]*TSP_NO_SHADER_WARMDRAW=\(.*\)$/\1/p' "$S/tsp_iotune.conf" 2>/dev/null | tail -1)"
echo

echo "########## 2. THE WARM GATE - DID IT GO AWAY ##########"
echo "  BEFORE, from openmw_log.txt.memsplit-off-20260910-235359:"
echo "    4 gate runs, 15304 ms total, remaining=14 on three of them"
echo "  NOW:"
GN="$(grep -ac 'TSP_WARMDRAW_GATE' "$LG" 2>/dev/null; true)"
printf '    TSP_WARMDRAW_GATE lines: %s\n' "${GN:-0}"
if [ "${GN:-0}" -gt 0 ]; then
    grep -a 'TSP_WARMDRAW_GATE' "$LG" | sed 's/^/      /'
    grep -a 'TSP_WARMDRAW_GATE' "$LG" | awk '
    { for (i=1;i<=NF;i++){k=index($i,"="); if(k && substr($i,1,k-1)=="ms") t+=substr($i,k+1)+0} n++ }
    END { printf "      total %d runs, %.0f ms = %.1f s\n", n, t, t/1000.0 }'
else
    echo "      ZERO. The gate did not run. That is ~15.3 s off the load."
fi
grep -a 'TSP_WARMDRAIN' "$LG" 2>/dev/null | sed 's/^/      /'
echo

echo "########## 3. LOAD LADDER THIS RUN ##########"
awk '
function tosec(s){ if(s=="") return -1; split(s,a,":"); return a[1]*3600+a[2]*60+a[3] }
/TSP_LOAD_TRACE/ {
    ts=""
    if (match($0,/[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9]+/)) ts=substr($0,RSTART,RLENGTH)
    ph=""; kb=""
    for(i=1;i<=NF;i++){k=index($i,"="); if(!k) continue
        key=substr($i,1,k-1); val=substr($i,k+1)
        if(key=="phase") ph=val
        if(key=="inuse_kb") kb=val+0 }
    if(ph=="" || kb=="") next
    n++; P[n]=ph; K[n]=kb; T[n]=ts
}
END {
    if(n<2){ print "  (no ladder - is OPENMW_DEBUG_LEVEL still INFO?)"; exit }
    printf "  %-32s %10s %11s %8s\n","phase","inuse_kb","delta_kb","gap_s"
    for(i=1;i<=n;i++){
        d=""; g=""
        if(i>1){ d=sprintf("%+d",K[i]-K[i-1])
            s1=tosec(T[i-1]); s2=tosec(T[i]); if(s1>=0&&s2>=0) g=sprintf("%.3f",s2-s1)
            if(K[i]-K[i-1]>big){big=K[i]-K[i-1]; bi=i} }
        printf "  %-32s %10d %11s %8s%s\n",P[i],K[i],d,g,(i>1 && K[i]-K[i-1]>50000 ? "  <<<<" : "")
    }
    if(bi) printf "\n  biggest step: %s -> %s  %+d kB = %+.1f MB\n",P[bi-1],P[bi],big,big/1024.0
    print  "  reference across 11 earlier loads: 194132-197823 kB, always 9 cells"
}' "$LG"
echo

echo "########## 4. SWAP AND FAULTS DURING PLAY ##########"
printf '  swap in use now:  %s kB of %s kB\n' \
    "$(awk '/^SwapTotal:/{t=$2}/^SwapFree:/{f=$2}END{print t-f}' /proc/meminfo)" \
    "$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)"
printf '  Cached:           %s kB\n' "$(awk '/^Cached:/{print $2}' /proc/meminfo)"
echo "  BEFORE this patch, VmSwap climbed 57 -> 134 MB over one session while"
echo "  RSS stayed flat. If swap in use is much lower now, patch 1 is working."
echo
if [ -f /tmp/tsp_iowatch.log ]; then
    echo "  -- per-second sampler, the swap and fault columns --"
    awk '
    /^t=/ {
        delete f
        for(i=1;i<=NF;i++){k=index($i,"="); if(k) f[substr($i,1,k-1)]=substr($i,k+1)+0}
        n++; t[n]=f["t"]; ok[n]=f["ok"]; rss[n]=f["rss"]; vsw[n]=f["vswap"]
        pg[n]=f["pgmaj"]; si[n]=f["pswpin"]
    }
    END {
        if(n<2){ print "     (too few sampler rows)"; exit }
        for(i=2;i<=n;i++){
            dt=t[i]-t[i-1]; if(dt<=0) continue
            if(ok[i]!=1||ok[i-1]!=1) continue
            gm=(pg[i]-pg[i-1])/dt; if(gm<0) gm=0
            s=(si[i]-si[i-1])/dt;  if(s<0) s=0
            w++; sg+=gm; ss+=s
            if(gm>pk) pk=gm
            if(vsw[i]>mx) mx=vsw[i]
            if(rss[i]>mr) mr=rss[i]
        }
        if(!w){ print "     (game pid never seen)"; exit }
        printf "     game-live %d s   peak RSS %.1f MB   peak VmSwap %.1f MB\n", w, mr/1024.0, mx/1024.0
        printf "     major faults mean %.1f /s  peak %.1f /s\n", sg/w, pk
        printf "     swap reads   mean %.1f KB/s\n", ss*4.0/w
        print  "     BEFORE: majflt mean 51.8/s peak 2363/s, peak VmSwap 133.8 MB"
    }' /tmp/tsp_iowatch.log
else
    echo "  (no sampler log - relief on starts it; if you rebooted, it is gone)"
fi
echo

echo "########## 5. HITCHES, FROM THE RING ##########"
if ls "$S"/tsp_ring.[0-9]* >/dev/null 2>&1; then
    sh "$S/tsp_post.sh" "$S"/tsp_ring.[0-9]* 2>&1 | grep -vE '^  frame '
else
    echo "  (no ring dumps - nothing crossed the 1000 ms trigger, which is good)"
fi
REMOTE
    echo
    echo "=================================================================="
    echo "  If the hitching is better: patch 1 (swappiness) is the win."
    echo "  If the loading bar is shorter: patch 2 (warm-draw) is the win."
    echo "  If shader stalls came back during play, that is patch 2 - run:"
    echo "     bash ~/Downloads/tsp_relief.sh off"
    echo "  and tell me, and I will re-enable warm-draw while keeping patch 1."
    echo "=================================================================="
    exit 0
fi

if [ "$MODE" = "on" ]; then WSWAP=$SWAP_ON;  WWARM=1; LABEL="ON  swappiness=10, warm-draw OFF"
else                        WSWAP=$SWAP_OFF; WWARM=0; LABEL="OFF swappiness=150, warm-draw ON (as shipped)"; fi
echo "MODE=$LABEL"
echo

# The sampler, so pull has play-time numbers. Same code as TSP_IOWATCH_SAMPLER_V2,
# which was validated live against real /proc.
cat > "$DL/.tsp_relief_sampler.sh" <<'SAMP'
#!/bin/sh
OUT=${OUT:-/tmp/tsp_iowatch.log}
OFF=${OFF:-/mnt/SDCARD/tsp_iowatch_off}
TICKS=${TICKS:-2400}
PIDNAME=${PIDNAME:-openmw}
printf '# TSP_RELIEF_SAMPLER_V1 start=%s pidname=%s\n' "$(date +%s)" "$PIDNAME" > "$OUT"
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
    cached=0; memfree=0; swapfree=0
    while read -r k v _u; do
        case "$k" in Cached:) cached=$v ;; MemFree:) memfree=$v ;; SwapFree:) swapfree=$v ;; esac
    done < /proc/meminfo
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
    printf 't=%s pid=%s ok=%s rss=%s vswap=%s majf=%s pgmaj=%s pswpin=%s pswpout=%s cached=%s memfree=%s swapfree=%s\n' \
        "$(date +%s)" "${pid:-0}" "$ok" "$rss" "$vswap" "$majf" "$pgmaj" "$pswpin" \
        "$pswpout" "$cached" "$memfree" "$swapfree" >> "$OUT"
    sleep 1; i=$((i + 1))
done
SAMP
scp -q $SSH_OPTS "$DL/.tsp_relief_sampler.sh" "$TSP:/tmp/tsp_relief_sampler.sh" </dev/null \
    || die "sampler scp failed"

rin "MODE=$MODE WSWAP=$WSWAP WWARM=$WWARM STAMP=$STAMP sh -s" <<'REMOTE' 2>&1 | tee "$REP"
# ---- TSP_RELIEF_ARM_BEGIN ----
S=/mnt/SDCARD
G=$S/data/ports/openmw
CONF=$S/tsp_iotune.conf

[ -f "$CONF" ] || { echo "FAIL: $CONF missing"; exit 1; }
cp -p "$CONF" "$CONF.bak-relief-$STAMP" || { echo "FAIL: backup"; exit 1; }
echo "########## 1. THE TWO LINES ##########"
echo "backed up $(basename "$CONF").bak-relief-$STAMP"
echo "  vm.swappiness right now (from the last launch): $(cat /proc/sys/vm/swappiness 2>/dev/null)"

# TSP_SWAPPINESS may be written with or without export; match either, keep the form.
if grep -q '^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}TSP_SWAPPINESS=' "$CONF"; then
    sed "s/^\([[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}TSP_SWAPPINESS=\).*/\1$WSWAP/" "$CONF" > "$CONF.n1" \
        && mv "$CONF.n1" "$CONF"
else
    printf 'export TSP_SWAPPINESS=%s\n' "$WSWAP" >> "$CONF"
fi

if [ "$WWARM" = "1" ]; then
    if grep -q '^[[:space:]]*export[[:space:]][[:space:]]*TSP_NO_SHADER_WARMDRAW=' "$CONF"; then
        sed 's/^\([[:space:]]*export[[:space:]][[:space:]]*TSP_NO_SHADER_WARMDRAW=\).*/\11/' "$CONF" > "$CONF.n2" \
            && mv "$CONF.n2" "$CONF"
    else
        printf 'export TSP_NO_SHADER_WARMDRAW=1\n' >> "$CONF"
    fi
else
    grep -v '^[[:space:]]*export[[:space:]][[:space:]]*TSP_NO_SHADER_WARMDRAW=' "$CONF" > "$CONF.n2" \
        && mv "$CONF.n2" "$CONF"
fi

GOTS="$(sed -n 's/^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}TSP_SWAPPINESS=\(.*\)$/\2/p' "$CONF" | tail -1)"
GOTW="$(sed -n 's/^[[:space:]]*export[[:space:]][[:space:]]*TSP_NO_SHADER_WARMDRAW=\(.*\)$/\1/p' "$CONF" | tail -1)"
echo "  TSP_SWAPPINESS=[${GOTS:-unset}]           want [$WSWAP]"
echo "  TSP_NO_SHADER_WARMDRAW=[${GOTW:-unset}]   want [$([ "$WWARM" = 1 ] && echo 1 || echo unset)]"

F=0
[ "$GOTS" = "$WSWAP" ] || { echo "  FAIL swappiness line wrong"; F=1; }
if [ "$WWARM" = "1" ]; then
    [ "$GOTW" = "1" ] || { echo "  FAIL warmdraw not set"; F=1; }
else
    [ -z "$GOTW" ] || { echo "  FAIL warmdraw still present as [$GOTW]"; F=1; }
fi
# do not let this run if the off switch would skip the whole tuning block
[ -f "$S/tsp_iotune_off" ] && { echo "  FAIL /mnt/SDCARD/tsp_iotune_off exists - the conf is not applied at all"; F=1; }
if [ "$F" -ne 0 ]; then
    echo "  restoring the backup and stopping - nothing changed"
    cp -p "$CONF.bak-relief-$STAMP" "$CONF"
    exit 1
fi
echo "  VERIFIED"
grep -n 'TSP_SWAPPINESS\|TSP_NO_SHADER_WARMDRAW\|OPENMW_DEBUG_LEVEL\|TSP_KTX\|TSP_NO_LOADPURGE' "$CONF" | sed 's/^/    /'
echo

echo "########## 2. CLEAN CAPTURE ##########"
[ -s "$G/openmw_log.txt" ] && mv "$G/openmw_log.txt" "$G/openmw_log.txt.relief-$MODE-$STAMP" \
    && echo "  log rotated"
A="$S/tsp_hitch_archive_$STAMP"; k=0
for d in "$S"/tsp_ring.[0-9]*; do
    [ -f "$d" ] || continue
    mkdir -p "$A"; cp -p "$d" "$A/" && rm -f "$d" && k=$((k + 1))
done
echo "  ring dumps archived: $k"
printf 'TSP_RING_TRIG=1000\nTSP_RING_MAX=12\n' > "$S/tsp_ring.conf"
[ -f "$S/tsp_ring_off" ] && mv "$S/tsp_ring_off" "$S/tsp_ring_off.parked-$STAMP"
rm -f "$S/tsp_iowatch_off"
sync
echo

echo "########## 3. SAMPLER ##########"
for p in $(ps 2>/dev/null | awk '/[t]sp_relief_sampler|[t]sp_iowatch_sampler/{print $1}'); do
    kill "$p" 2>/dev/null
done
BINNAME=openmw
L="$S/Roms/PORTS/Morrowind.sh"
if [ -f "$L" ]; then
    CAND="$(sed -n 's/^[[:space:]]*OPENMW_BIN=["'"'"']*\([^"'"'"']*\).*/\1/p' "$L" | tail -1)"
    [ -n "$CAND" ] && BINNAME="${CAND##*/}"
fi
echo "  pidof name: $BINNAME"
chmod +x /tmp/tsp_relief_sampler.sh
rm -f /tmp/tsp_iowatch.log
if command -v setsid >/dev/null 2>&1; then
    OUT=/tmp/tsp_iowatch.log PIDNAME="$BINNAME" setsid /tmp/tsp_relief_sampler.sh >/dev/null 2>&1 &
else
    OUT=/tmp/tsp_iowatch.log PIDNAME="$BINNAME" nohup /tmp/tsp_relief_sampler.sh >/dev/null 2>&1 &
fi
sleep 3
RUN="$(ps 2>/dev/null | awk '/[t]sp_relief_sampler/{n++} END{print n+0}')"
ROWS="$(grep -c '^t=' /tmp/tsp_iowatch.log 2>/dev/null; true)"
echo "  sampler processes $RUN, rows after 3 s: $ROWS"
echo

echo "########## READY CHECK ##########"
E=0
[ "$GOTS" = "$WSWAP" ] && echo "  OK   TSP_SWAPPINESS=$GOTS" || { echo "  FAIL"; E=1; }
if [ "$WWARM" = "1" ]; then
    [ "$GOTW" = "1" ] && echo "  OK   TSP_NO_SHADER_WARMDRAW=1" || { echo "  FAIL"; E=1; }
else
    [ -z "$GOTW" ] && echo "  OK   TSP_NO_SHADER_WARMDRAW unset" || { echo "  FAIL"; E=1; }
fi
[ "${RUN:-0}" -ge 1 ] && echo "  OK   sampler running" || { echo "  FAIL sampler"; E=1; }
[ -s "$G/openmw_log.txt" ] && { echo "  FAIL log not empty"; E=1; } || echo "  OK   log clean"
echo
[ "$E" -eq 0 ] && echo "READY" || echo "NOT READY"
# ---- TSP_RELIEF_ARM_END ----
REMOTE

echo
if [ "$MODE" = "off" ]; then
    echo "=================================================================="
    echo "  Reverted. swappiness back to 150, warm-draw back on."
    echo "=================================================================="
    exit 0
fi
echo "=================================================================="
echo "  Launch Morrowind and just PLAY. No route, no protocol."
echo
echo "  Two things to feel for, and they are independent:"
echo "    - the LOADING BAR should be roughly 15 s shorter"
echo "    - the HITCHING should be reduced or gone"
echo
echo "  If shaders stall visibly during play (a freeze the first time you"
echo "  see a new effect), that is patch 2 and it is the one to revert."
echo
echo "  When you are done, quit through the menu and run:"
echo "     bash ~/Downloads/tsp_relief.sh pull"
echo "  Revert everything:"
echo "     bash ~/Downloads/tsp_relief.sh off"
echo "=================================================================="
