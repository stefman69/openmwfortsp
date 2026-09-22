#!/bin/sh
# tsp_spike.sh - identify the 441 MB transient allocation burst, two ways, no guessing.
#
#   src     ONE BIG READ-ONLY DUMP, no game run needed. Every plausible source of
#           a ~3.81 MB repeated allocation - global map, local map, terrain
#           composite maps, chunk manager, sky, water, shadow maps - with line
#           numbers, plus the settings that size each one, plus the arithmetic:
#           for every resolution found in the config it computes R*R*4 and flags
#           anything within 15% of the measured 3.81 MB per mapping.
#
#   catch   arm a device-side watcher before a cold load. It polls VmRSS at 2 Hz
#           and, the moment RSS crosses the threshold, snapshots the FULL
#           /proc/<pid>/smaps three times a second apart. That captures the
#           mapping SIZES during the burst.
#
#   pull    fetch those snapshots and group the mappings by size. 116 anonymous
#           mappings of the same size is a fingerprint - the size names the
#           allocation, and then no source guessing is needed at all.
#
#   off     disarm the watcher.
#
# WHY BOTH IN ONE FILE: `src` answers "which code could do this" from the source
# tree right now, and `catch`+`pull` answers "which allocation actually did it"
# from the kernel on the next cold load. Together they close it in one round
# trip instead of a dozen. Run `src` now; run `catch` before the next launch.

set -u
DEV="root@192.168.1.12"
G="/mnt/SDCARD/data/ports/openmw"
CONT="openmw_builder"
SRC="/root/openmw-0.51-tsp-src"
SSHO="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/tsp_spike_src_$STAMP.txt"
WATCH="/tmp/tsp_spike_watch.sh"
SNAPDIR="/tmp/tsp_spike"
OFFFLAG="/mnt/SDCARD/tsp_spike_off"
THRESH="${2:-560000}"

MODE="${1:-src}"
r() { ssh $SSHO -n "$DEV" "$1" 2>&1; }
rin() { ssh $SSHO "$DEV" "sh -s" 2>&1; }
d() { docker exec "$CONT" sh -c "$1" 2>&1; }
say() { printf '  %s\n' "$*"; }
hr() { printf '\n########## %s ##########\n' "$1"; }
sec() {
    printf '\n\n==============================================================\n== %s\n==============================================================\n' "$1" >>"$OUT"
    printf '  .. %s\n' "$1"
}

case "$MODE" in
src | catch | pull | report | off) ;;
*) printf 'usage: %s src | catch [rss_kb] | pull | report [dir] | off\n' "$0"; exit 2 ;;
esac

# =============================================================== src =========
if [ "$MODE" = "src" ]; then
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONT" || {
        say "container $CONT is not running - start it and re-run"; exit 1; }
    mkdir -p "$HOME/Downloads"
    printf 'TSP spike source dump %s\n' "$STAMP" >"$OUT"
    printf '\n########## COLLECTING (read-only) ##########\n'

    sec "THE MEASUREMENT WE ARE EXPLAINING"
    cat >>"$OUT" <<'MEOF'
From tsp_iowatch_20260911-205858.log, smaps rows, Rss in MB:

   +s   nmap   rss_tot     heap     anon  swap_tot
   32   1208      496M     318M     149M        0M
   45   1324      895M     306M     560M       60M   <-- the burst
   56   1339      474M     312M     137M       76M

  anon 149 -> 560 -> 137 MB. Total 895 MB on a 963 MB device.
  mappings in that interval: 1208 -> 1324 = +116
  441 MB / 116 = 3.81 MB per mapping
  ktx / bsa / file / gpu regions were 0 kB throughout, so this is NOT
  mmapped asset data - it is anonymous, i.e. malloc or an OSG image buffer.

Sizes that would produce 3.81 MB:
   1024 x 1024 x 4 = 4.00 MB     <- closest common render-target size
    954 x  864 x 4 = 3.14 MB     <- the global map overlay
   1000 x 1000 x 4 = 3.81 MB     <- exact
    512 x  512 x 4 = 1.00 MB
   2048 x 2048 x 4 = 16.0 MB
MEOF

    sec "SETTINGS THAT SIZE ANY OF THESE, AS THE DEVICE HAS THEM"
    rin >>"$OUT" <<SEOF
for c in '$G/config-0.51/settings.cfg' '$G/config/settings.cfg' '$G/settings.cfg'; do
    [ -f "\$c" ] && { echo "=== \$c"; cat "\$c"; }
done
echo "--- where settings.cfg actually is (bounded)"
find '$G' -maxdepth 3 -name 'settings.cfg' 2>/dev/null
SEOF

    sec "DEFAULTS THE ENGINE WOULD USE FOR ANY SETTING NOT IN THE FILE"
    d "cd '$SRC' && sed -n '/^\\[Terrain\\]/,/^\\[/p;/^\\[Map\\]/,/^\\[/p;/^\\[Camera\\]/,/^\\[/p;/^\\[Cells\\]/,/^\\[/p' files/settings-default.cfg 2>/dev/null | head -80" >>"$OUT"

    sec "EVERY PLACE THE ENGINE ALLOCATES AN IMAGE OR RENDER TARGET"
    d "cd '$SRC' && grep -rn --include='*.cpp' --include='*.hpp' \
        -e 'allocateImage' -e 'new osg::Image' -e 'setTextureSize' \
        -e 'new osg::Texture2D' -e 'GL_RGBA' \
        apps/openmw/mwrender components/terrain components/sceneutil components/resource \
        2>/dev/null | head -70" >>"$OUT"

    sec "GLOBAL MAP - globalmap.cpp, the 954x864 overlay and the camera queue"
    d "cd '$SRC' && f=apps/openmw/mwrender/globalmap.cpp; wc -l \$f; \
       grep -n -e 'allocateImage' -e 'mWidth' -e 'mHeight' -e 'exploreCell' \
               -e 'cleanupCameras' -e 'mPendingImageDest' -e 'void GlobalMap::' \
               -e 'TSP_' \$f" >>"$OUT"
    d "cd '$SRC' && f=apps/openmw/mwrender/globalmap.cpp; n=\$(grep -n 'void GlobalMap::exploreCell' \$f | head -1 | cut -d: -f1); [ -n \"\$n\" ] && sed -n \"\$n,\$((n+70))p\" \$f | cat -n" >>"$OUT"
    d "cd '$SRC' && f=apps/openmw/mwrender/globalmap.cpp; n=\$(grep -n 'GlobalMap::cleanupCameras' \$f | head -1 | cut -d: -f1); [ -n \"\$n\" ] && sed -n \"\$n,\$((n+40))p\" \$f | cat -n" >>"$OUT"

    sec "LOCAL MAP - localmap.cpp, per-cell render targets"
    d "cd '$SRC' && f=apps/openmw/mwrender/localmap.cpp; wc -l \$f; \
       grep -n -e 'allocateImage' -e 'mMapResolution' -e 'setTextureSize' \
               -e 'void LocalMap::' -e 'mSegments' -e 'requestMap' -e 'TSP_' \$f" >>"$OUT"

    sec "TERRAIN COMPOSITE MAPS - the best fit for a 1024x1024x4 = 4 MB burst"
    d "cd '$SRC' && for f in components/terrain/compositemaprenderer.cpp components/terrain/chunkmanager.cpp components/terrain/quadtreeworld.cpp components/terrain/terraingrid.cpp; do \
         [ -f \$f ] || continue; echo \"=== \$f (\$(wc -l < \$f) lines)\"; \
         grep -n -e 'allocateImage' -e 'setTextureSize' -e 'CompositeMap' \
                 -e 'mCompositeMapResolution' -e 'mCompositeMapLevel' -e 'new osg::Texture2D' \
                 -e 'compile' -e 'TSP_' \$f | head -30; done" >>"$OUT"
    d "cd '$SRC' && grep -rn -e 'composite map resolution' -e 'composite map level' \
        -e 'local map resolution' -e 'global map cell size' -e 'distant terrain' \
        components apps files 2>/dev/null | head -25" >>"$OUT"

    sec "WATER, SKY, SHADOWS - the other render-target families"
    d "cd '$SRC' && grep -rn --include='*.cpp' -e 'setTextureSize' -e 'allocateImage' \
        apps/openmw/mwrender/water.cpp apps/openmw/mwrender/sky.cpp \
        components/sceneutil/mwshadowtechnique.cpp 2>/dev/null | head -25" >>"$OUT"

    sec "WHAT IS ALREADY INSTRUMENTED IN THOSE FILES"
    d "cd '$SRC' && grep -rno 'TSP_[A-Z0-9_]*' apps/openmw/mwrender components/terrain 2>/dev/null | sort -u -t: -k3 | head -40" >>"$OUT"

    sec "THE FRAME LOOP, SO A PER-FRAME BUDGET HAS SOMEWHERE TO LIVE"
    d "cd '$SRC' && f=apps/openmw/engine.cpp; n=\$(grep -n 'void OMW::Engine::frame' \$f | head -1 | cut -d: -f1); [ -n \"\$n\" ] && sed -n \"\$n,\$((n+90))p\" \$f | cat -n" >>"$OUT"

    sec "GIT STATE, so the patch anchors against the right tree"
    d "cd '$SRC' && git log -3 --format='%h %ad %s' --date=short; echo '--- uncommitted:'; git status --porcelain | grep -v '\\.before-' | head -20" >>"$OUT"

    printf '\n########## SUMMARY ##########\n'
    say "full dump: $OUT  ($(wc -l <"$OUT") lines)"
    printf '\n'
    say "The arithmetic that matters, from your own settings:"
    awk '
    /composite map resolution|local map resolution|global map cell size|composite map level/ {
        for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) v = $i
        if (v > 0) {
            mb = v * v * 4 / 1048576
            printf "    %-42s %5d  -> %5d x %5d x 4 = %6.2f MB%s\n", $1" "$2" "$3, v, v, v, mb, \
                   (mb > 3.24 && mb < 4.38 ? "   <<< MATCHES 3.81 MB" : "")
        }
        v = 0
    }' "$OUT" | sort -u
    printf '\n'
    say "Then, BEFORE your next cold launch, arm the catcher:"
    printf '\n      bash ~/Downloads/tsp_spike.sh catch\n\n'
    exit 0
fi

# ============================================================= catch =========
if [ "$MODE" = "catch" ]; then
    hr "ARMING THE SPIKE CATCHER (threshold ${THRESH} kB RSS)"
    if r "pidof openmw-0.51 >/dev/null 2>&1 && echo up" | grep -q up; then
        say "the game is already running - this has to be armed before a COLD load,"
        say "because the burst happens at +45s of the first load. Quit and re-run."
        exit 1
    fi
    rin <<CEOF
cat > '$WATCH' <<'INNER'
#!/bin/sh
# Waits for openmw, then polls VmRSS at 2 Hz. On crossing THRESH it snapshots the
# FULL smaps three times, a second apart, to catch the peak rather than the edge.
# A full smaps read is ~1.5 ms at 45 mappings, so even at 2 Hz this is free.
TH=\${TH:-640000}
DIR=\${DIR:-/tmp/tsp_spike}
OFF=\${OFF:-/mnt/SDCARD/tsp_spike_off}
rm -rf "\$DIR"; mkdir -p "\$DIR"
P=""
i=0
HI=0
QUIET=0
while [ \$i -lt 1200 ]; do
    [ -f "\$OFF" ] && { echo "off flag" >> "\$DIR/log"; exit 0; }
    if [ -z "\$P" ] || [ ! -r "/proc/\$P/status" ]; then
        P="\$(pidof openmw-0.51 2>/dev/null | cut -d' ' -f1)"
        [ -n "\$P" ] && {
            cp "/proc/\$P/smaps" "\$DIR/baseline.smaps" 2>/dev/null
            echo "pid=\$P baseline taken \$(date +%s)" >> "\$DIR/log"
        }
    fi
    if [ -n "\$P" ] && [ -r "/proc/\$P/status" ]; then
        RSS=0
        while read -r k v _u; do [ "\$k" = "VmRSS:" ] && RSS=\$v; done < "/proc/\$P/status"
        echo "\$(date +%s) \$RSS" >> "\$DIR/rss"
        # CHASE THE HIGH-WATER MARK. The previous version snapped three times on
        # first crossing and exited - it fired at 645 MB on the way up and quit
        # seven seconds before the real peak. Now every new high overwrites
        # peak.smaps, so what survives is the actual maximum.
        if [ "\$RSS" -gt "\$TH" ]; then
            if [ "\$RSS" -gt "\$HI" ]; then
                HI=\$RSS
                cp "/proc/\$P/smaps" "\$DIR/peak1.smaps" 2>/dev/null
                cp "/proc/\$P/status" "\$DIR/peak1.status" 2>/dev/null
                [ -r "/proc/\$P/smaps_rollup" ] && cp "/proc/\$P/smaps_rollup" "\$DIR/peak1.rollup" 2>/dev/null
                QUIET=0
                echo "NEW HIGH \$(date +%s) rss=\$HI - snapshot replaced" >> "\$DIR/log"
            else
                QUIET=\$((QUIET + 1))
                # 40 half-second ticks = 20 s with no new high: the burst is over.
                if [ "\$QUIET" -gt 40 ]; then
                    cp "/proc/\$P/smaps" "\$DIR/after.smaps" 2>/dev/null
                    cp "/proc/\$P/status" "\$DIR/after.status" 2>/dev/null
                    echo "SETTLED at \$(date +%s) rss=\$RSS high was \$HI" >> "\$DIR/log"
                    echo "done" >> "\$DIR/log"
                    exit 0
                fi
            fi
        fi
    fi
    sleep 0.5
    i=\$((i + 1))
done
echo "timed out without crossing \$TH" >> "\$DIR/log"
INNER
chmod 755 '$WATCH'
rm -f '$OFFFLAG'
echo "  watcher written, off-flag cleared"
CEOF
    r "test -f $WATCH" || { say "failed to write the watcher"; exit 1; }
    r "cd /tmp && TH=$THRESH DIR=$SNAPDIR OFF=$OFFFLAG setsid nohup sh $WATCH >/dev/null 2>&1 </dev/null & echo started"
    sleep 2
    r "ps | grep -c '[t]sp_spike_watch' | sed 's/^/    watcher processes: /'"
    printf '\n'
    say "NOW: cold-launch Morrowind from the 'Morrowind' entry, load the save, and"
    say "walk the route. The burst hits about 45 s after the process appears, so"
    say "the watcher will fire during the load or the first few steps."
    printf '\n'
    say "Then, without needing to quit the game:"
    printf '\n      bash ~/Downloads/tsp_spike.sh pull\n\n'
    exit 0
fi

if [ "$MODE" = "off" ]; then
    hr "DISARMING"
    r "touch '$OFFFLAG'; sleep 1; ps | grep -c '[t]sp_spike_watch' | sed 's/^/    still running: /'"
    exit 0
fi

# ============================================================ report =========
# LOCAL ONLY. Re-analyses snapshots already in ~/Downloads - no device, no game.
#
# Why this exists: `pull` grouped mappings by RESERVED SIZE and filtered to
# >256 kB. Both were wrong. The filter dropped every small mapping, which in
# aggregate is where most of the resident memory lives, and grouping by size put
# 383 MB of near-empty glibc arenas at the top of the table while the rss column
# read 0.0 across the board against a 702 MB process. This groups by Rss, filters
# nothing, and reads smaps_rollup - the kernel's own authoritative total, which
# `pull` fetched and then ignored.
if [ "$MODE" = "report" ]; then
    DIR="${2:-}"
    if [ -z "$DIR" ]; then
        DIR="$(ls -1dt "$HOME"/Downloads/tsp_spike_2* 2>/dev/null | head -1)"
    fi
    [ -n "$DIR" ] && [ -d "$DIR" ] || {
        say "no snapshot directory found. Pass one:"
        say "  bash ~/Downloads/tsp_spike.sh report ~/Downloads/tsp_spike_20260911-213824"
        exit 1; }

    # ONE classifier, shared by every table below. The previous version had
    # three separate copies and they disagreed - and the "bin" rule matched any
    # path containing openmw, which is EVERY game file, so hundreds of resource
    # mappings were reported as the executable. Basename now decides.
    KINDFN='
    function base(n,   a, k) { k = split(n, a, "/"); return a[k] }
    function kind(n,   b) {
        if (n == "" || n == "[anon]")  return "anon"
        if (n == "[heap]")             return "heap"
        if (n ~ /^\[stack/)            return "stack"
        if (n ~ /^\[/)                 return "kernel"
        if (n ~ /^\/dev\/(mali|dri|ion|kgsl|nvmap|disp|ump|galcore)/) return "gpu"
        if (n ~ /^\/dev\//)            return "dev"
        b = base(n)
        if (b ~ /\.so($|\.)/)          return "so"
        if (b ~ /\.[Bb][Ss][Aa]$/)     return "bsa"
        if (b ~ /\.[Kk][Tt][Xx]2?$/)   return "ktx"
        if (b ~ /^openmw/)             return "bin"
        if (n ~ /^\//)                 return "file"
        return "other"
    }'

    hr "READING $DIR"
    ls -1 "$DIR" | sed 's/^/    /'

    if [ -s "$DIR/peak1.rollup" ]; then
        hr "smaps_rollup AT PEAK - the kernel adding it up itself"
        sed 's/^/    /' "$DIR/peak1.rollup"
        say ""
        say "Every table below must add up to the Rss line above. If one does"
        say "not, believe this one and distrust the table."
    else
        say "(no peak1.rollup in this snapshot set)"
    fi

    for f in baseline peak1 after; do
        [ -s "$DIR/$f.smaps" ] || continue
        hr "$f - TOP 20 MAPPINGS BY Rss (nothing filtered, nothing dropped)"
        awk "$KINDFN"'
        /^[0-9a-fA-F]+-[0-9a-fA-F]+ / {
            if (have) printf "%d\t%d\t%d\t%s\t%s\n", rss, sz, swp, kind(nm), (nm == "" ? "[anon]" : nm)
            nm = ""
            if (NF >= 6) { for (i = 6; i <= NF; i++) nm = nm (i > 6 ? " " : "") $i }
            sz = 0; rss = 0; swp = 0; have = 1; next
        }
        /^Size:/ { sz  = $2; next }
        /^Rss:/  { rss = $2; next }
        /^Swap:/ { swp = $2; next }
        END { if (have) printf "%d\t%d\t%d\t%s\t%s\n", rss, sz, swp, kind(nm), (nm == "" ? "[anon]" : nm) }
        ' "$DIR/$f.smaps" | sort -rn | head -20 | awk -F'\t' '
        BEGIN { printf "    %9s %9s %9s  %-7s %s\n", "Rss MB", "Size MB", "Swap MB", "kind", "mapping" }
        { printf "    %9.1f %9.1f %9.1f  %-7s %s\n", $1/1024, $2/1024, $3/1024, $4, $5 }'

        printf "\n    --- %s, every mapping totalled by KIND, by Rss\n" "$f"
        awk "$KINDFN"'
        /^[0-9a-fA-F]+-[0-9a-fA-F]+ / {
            if (have) { k = kind(nm); r[k] += rss; w[k] += swp; v[k] += sz; c[k]++ }
            nm = ""
            if (NF >= 6) { for (i = 6; i <= NF; i++) nm = nm (i > 6 ? " " : "") $i }
            sz = 0; rss = 0; swp = 0; have = 1; next
        }
        /^Size:/ { sz  = $2; next }
        /^Rss:/  { rss = $2; next }
        /^Swap:/ { swp = $2; next }
        END {
            if (have) { k = kind(nm); r[k] += rss; w[k] += swp; v[k] += sz; c[k]++ }
            printf "    %-8s %8s %12s %12s %14s\n", "kind", "count", "Rss MB", "Swap MB", "reserved MB"
            tot = 0; totw = 0; totc = 0
            n = split("heap anon stack so bin file bsa ktx gpu dev kernel other", K, " ")
            for (i = 1; i <= n; i++) { k = K[i]
                if (c[k] > 0) {
                    printf "    %-8s %8d %12.1f %12.1f %14.1f\n", k, c[k], r[k]/1024, w[k]/1024, v[k]/1024
                    tot += r[k]; totw += w[k]; totc += c[k] } }
            printf "    %-8s %8d %12.1f %12.1f\n", "TOTAL", totc, tot/1024, totw/1024
        }' "$DIR/$f.smaps"
    done

    hr "THE [heap] BRK REGION ACROSS ALL THREE SNAPSHOTS"
    printf '    %-10s %12s %12s %12s\n' "snapshot" "reserved MB" "Rss MB" "Swap MB"
    for f in baseline peak1 after; do
        [ -s "$DIR/$f.smaps" ] || continue
        awk -v tag="$f" '
        /^[0-9a-fA-F]+-[0-9a-fA-F]+ / { h = ($0 ~ /\[heap\]$/); next }
        h && /^Size:/ { sz += $2; next }
        h && /^Rss:/  { rs += $2; next }
        h && /^Swap:/ { sw += $2; next }
        END { printf "    %-10s %12.1f %12.1f %12.1f\n", tag, sz/1024, rs/1024, sw/1024 }
        ' "$DIR/$f.smaps"
    done
    cat <<'HEOF'

    Read those three rows like this:
      Rss high at peak AND still high at after  -> the memory was allocated and
        never returned to the kernel. glibc only trims the TOP of brk, so one
        long-lived allocation above a freed burst pins the whole region. That is
        a malloc_trim / arena story and the fix is in how the load allocates.
      Rss high at peak, much lower at after     -> genuinely transient. The burst
        is real work that finishes; the fix is to make the burst smaller
        (fewer cells preloaded at once), not to change the allocator.
      reserved grows but Rss does not           -> address space only, not RAM,
        and not the thing causing the faults.
HEOF

    hr "WHAT GREW, BY Rss, BASELINE -> PEAK"
    if [ -s "$DIR/baseline.smaps" ] && [ -s "$DIR/peak1.smaps" ]; then
        awk "$KINDFN"'
        function flush(   k) {
            if (!have) return
            k = kind(nm)
            if (file == 1) { b[k] += rss; bc[k]++ } else { p[k] += rss; pc[k]++ }
            have = 0
        }
        FNR == 1 { flush(); file++ }
        /^[0-9a-fA-F]+-[0-9a-fA-F]+ / {
            flush()
            nm = ""
            if (NF >= 6) { for (i = 6; i <= NF; i++) nm = nm (i > 6 ? " " : "") $i }
            rss = 0; have = 1; next
        }
        /^Rss:/ { rss = $2; next }
        END {
            flush()
            printf "    %-8s %10s %10s %12s %10s %10s\n", "kind", "base MB", "peak MB", "growth MB", "base n", "peak n"
            big = ""; bigv = 0; tot = 0
            n = split("heap anon stack so bin file bsa ktx gpu dev kernel other", K, " ")
            for (i = 1; i <= n; i++) { k = K[i]
                if (b[k] == 0 && p[k] == 0 && bc[k] == 0 && pc[k] == 0) continue
                d = p[k] - b[k]; tot += d
                printf "    %-8s %10.1f %10.1f %+12.1f %10d %10d\n", k, b[k]/1024, p[k]/1024, d/1024, bc[k], pc[k]
                if (d > bigv) { bigv = d; big = k } }
            printf "    %-8s %10s %10s %+12.1f\n", "TOTAL", "", "", tot/1024
            printf "\n    LARGEST GROWER BY Rss: %s, +%.1f MB of the +%.1f MB total\n", big, bigv/1024, tot/1024
            if (big == "heap")
                print "    -> the glibc brk heap. Not an OSG texture, not a mapped asset,\n" \
                      "       not the BSA, not the ktx files. Whatever allocates this uses\n" \
                      "       plain new/malloc in chunks small enough to stay under\n" \
                      "       M_MMAP_THRESHOLD, so smaps can never name it. The next\n" \
                      "       instrument has to be malloc-level, inside the process."
            else if (big == "anon")
                print "    -> anonymous mmap - single allocations over M_MMAP_THRESHOLD.\n" \
                      "       These DO have individual sizes: read them off the top-20\n" \
                      "       table above and the size names the allocation."
            else
                printf "    -> %s. The top-20 table above names the individual mappings.\n", big
        }' "$DIR/baseline.smaps" "$DIR/peak1.smaps"
    fi
    printf '\n'
    say "No device was touched and no game was run - this re-read the snapshots"
    say "already sitting in that folder."
    printf '\n'
    exit 0
fi

# ============================================================== pull =========
hr "FETCHING THE SNAPSHOTS"
r "cat $SNAPDIR/log 2>/dev/null || echo '    no log - was catch armed?'"
r "ls -l $SNAPDIR/ 2>/dev/null | sed 's/^/    /'"
W="$HOME/Downloads/tsp_spike_$STAMP"
mkdir -p "$W"
for f in baseline.smaps peak1.smaps after.smaps peak1.status after.status peak1.rollup rss log; do
    scp $SSHO "$DEV:$SNAPDIR/$f" "$W/$f" >/dev/null 2>&1
done
say "saved into $W"
[ -s "$W/peak1.smaps" ] || {
    say "no peak snapshot - the threshold was never crossed."
    say "Lower it and try again on the next cold load:"
    printf '\n      bash ~/Downloads/tsp_spike.sh catch 560000\n\n'
    exit 1
}

hr "RSS CURVE AS THE WATCHER SAW IT"
[ -s "$W/rss" ] && awk 'NR==1{t0=$1} {printf "    +%3ds  %6.0f MB\n", $1-t0, $2/1024}' "$W/rss" | awk 'NR%4==1'

hr "WHAT THE 21:22 RUN ALREADY SETTLED - do not re-derive this"
cat <<'KEOF'
    There is NO row of ~116 identical 3.9 MB mappings. That inference was wrong:
    it came from dividing 441 MB by a mapping-count delta, which silently assumed
    the new mappings were uniform. The raw smaps says they are not.

    What the anon mappings actually are:
      4 x 65404 kB + 65536 + 65316 + 65312 + 62292 + 47940  = 555 MB RESERVED
        glibc per-thread arenas (HEAP_MAX_SIZE). Rss 0.0-0.1 MB - address
        space, not RAM. 19 threads in the process.
      12 x 8192 kB = 96 MB reserved - default pthread stacks, also ~0 Rss.

    The one big RESIDENT object:
      1 x 325896 kB = 318 MB, named [heap] - the glibc brk heap.
      iowatch's r_heap peak was 325384 kB. Same object.

    And a correction to my own doc: the 895 MB figure came from a single smaps
    read at +45s. VmRSS at +42s and +48s was 643 and 671 MB and never
    corroborated it. Treat 895 MB as unconfirmed until this run reproduces it.

KEOF

hr "MAPPINGS GROUPED BY SIZE"
for f in baseline peak1 after; do
    [ -s "$W/$f.smaps" ] || continue
    printf '\n  === %s\n' "$f"
    awk '
    /^[0-9a-f]+-[0-9a-f]+ / {
        nm = ""
        if (NF >= 6) { for (i = 6; i <= NF; i++) nm = nm (i > 6 ? " " : "") $i }
        cur = (nm == "" ? "anon" : (nm ~ /^\[/ ? "kernel" : "file"))
        next
    }
    /^Size:/ { sz = $2; next }
    /^Rss:/  { if (sz > 256) { key = cur "|" sz; cnt[key]++; rss[key] += $2 } next }
    END {
        for (k in cnt) printf "%d %s %d\n", cnt[k], k, rss[k]
    }' "$W/$f.smaps" | sort -rn | head -12 | awk -F'[ |]' '
    BEGIN { printf "    %6s  %-7s %10s %12s %12s\n", "count", "kind", "size kB", "total MB", "rss MB" }
    { printf "    %6d  %-7s %10d %12.1f %12.1f\n", $1, $2, $3, $1 * $3 / 1024, $4 / 1024 }'
done

hr "WHAT APPEARED BETWEEN BASELINE AND PEAK"
[ -s "$W/baseline.smaps" ] && awk '
function key(f) { return f }
FNR == 1 { file++ }
/^[0-9a-f]+-[0-9a-f]+ / {
    nm = ""
    if (NF >= 6) { for (i = 6; i <= NF; i++) nm = nm (i > 6 ? " " : "") $i }
    cur = (nm == "" ? "anon" : (nm ~ /^\[/ ? "kernel" : "file"))
    next
}
/^Size:/ { sz = $2; next }
/^Rss:/ {
    if (sz > 256) { if (file == 1) b[cur "|" sz]++; else p[cur "|" sz]++ }
    next
}
END {
    printf "    %6s  %-7s %10s %12s\n", "+count", "kind", "size kB", "new MB"
    tot = 0
    for (k in p) {
        d = p[k] - (k in b ? b[k] : 0)
        if (d > 0) { split(k, a, "|"); printf "    %6d  %-7s %10d %12.1f\n", d, a[1], a[2], d * a[2] / 1024; tot += d * a[2] / 1024 }
    }
    printf "\n    total new: %.1f MB\n", tot
    print "\n    Read it by RSS, not by reserved size. Sort the rows above by the"
    print "    rss column: whichever mapping actually holds hundreds of MB resident"
    print "    at the peak is the allocation. If it is [heap] again, the burst is"
    print "    inside glibc and the next instrument is malloc-level, not smaps."
}' "$W/baseline.smaps" "$W/peak1.smaps"

printf '\n'
say "Send me this whole output and the src dump; the next message is the patch."
printf '\n'
