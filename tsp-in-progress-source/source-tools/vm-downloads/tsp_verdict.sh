#!/bin/sh
# tsp_verdict.sh - stop guessing whether a change helped. Measure it.
#
#   revert  back out changes A and B of tsp_heapfix (the env file and the two
#           settings). Both were speculative and neither ever got a number.
#           The malloc_trim in the binary is LEFT IN - it costs nothing
#           measurable and its log line is a free per-run RSS reading.
#
#   arm     install a 1 Hz device-side sampler that waits for openmw to appear
#           and then records, every second: VmRSS, VmSwap, major faults,
#           system-wide pgmajfault, MemAvailable, Cached, SwapFree, and CPU
#           time. Arm it BEFORE the cold launch (working agreement 27).
#
#   pull    fetch the samples and MERGE THEM WITH THE GAME LOG by wall clock,
#           so every second has fps next to its fault count. Prints the whole
#           second-by-second table, the worst seconds ranked, and one summary
#           line per run that can be compared against another run.
#
#   off     remove the sampler.
#
# WHY THIS EXISTS
#
# Three runs of the heap fix produced returned_kb of -284, +572 and -216. The
# heap is LIVE, not fragmented waste, so that hypothesis is dead. But the runs
# also cannot be ranked against each other: run 2 was reported "wayyyyyy worse"
# than run 1 on IDENTICAL config, and run 3 was the worst ever seen on the same
# config as runs 1 and 2. Run-to-run variance is larger than the effect being
# chased, which makes every subjective A/B worthless and has cost days.
#
# The one metric that has ever discriminated cleanly here is major faults per
# second: 25.1/s at swappiness 150 versus 91.9/s at swappiness 1, with 24 versus
# 153 samples above 30 faults. That is what this measures, with fps beside it so
# a fault storm can be tied to a visible drop.
#
# The sampler reads five small /proc files a second and nothing else. It does
# NOT read smaps or smaps_rollup at 1 Hz - both make the kernel walk every VMA,
# and this process has hundreds. INCIDENT-profiler-trigger-zero halved the
# framerate by instrumenting too hard; VmRSS and VmSwap come from
# /proc/<pid>/status, which is a cheap read, and the full heap line is taken
# only once every 10 s.

set -u
# Device address, in order: an explicit DEV= in the environment, then $TSP_DEV
# as `tsp_net.sh each` sets it, then ~/.tsp_dev as `tsp_net.sh use` writes it,
# then the old hardcoded default. Two cards do not share an address, and a tool
# pointed at the wrong one reports that card state as if it were this one.
# Every line here returns 0, so a missing ~/.tsp_dev cannot trip set -e.
DEV="${DEV:-${TSP_DEV:-}}"
if [ -z "${DEV}" ] && [ -r "$HOME/.tsp_dev" ]; then DEV="$(cat "$HOME/.tsp_dev")"; fi
[ -n "${DEV}" ] || DEV="root@192.168.1.12"
# WHICH CONSOLE THIS IS. Printed on EVERY run, and it goes into the saved log
# too. With two consoles in play, output that does not name the device it
# touched is not a result - `tsp_verdict.sh arm` printed an arm confirmation
# with no device on it, which is worse than useless because it looks complete.
[ -n "${TSP_NAME:-}" ] || TSP_NAME="$(awk -F'\t' -v h="$DEV" '$2==h {print $1}' "$HOME/.tsp_hosts" 2>/dev/null | head -1)"
printf '\n  ==================  DEVICE: %s  (%s)  ==================\n' "${TSP_NAME:-UNNAMED}" "$DEV"
G="/mnt/SDCARD/data/ports/openmw"
CFG="$G/config/settings.cfg"
ENVF="/mnt/SDCARD/tsp_intocc.env"
LOG="$G/openmw_log.txt"
SAMPLER="/tmp/tsp_verdict_sampler.sh"
OUTDIR="/tmp/tsp_verdict"
SSHO="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes -o LogLevel=ERROR"
STAMP="$(date +%Y%m%d-%H%M%S)"
SECS="${2:-240}"

MODE="${1:-pull}"
case "$MODE" in revert | arm | pull | off) ;;
*) printf 'usage: %s revert | arm [seconds] | pull | off\n' "$0"; exit 2 ;; esac

say() { printf '  %s\n' "$*"; }
hr()  { printf '\n########## %s ##########\n' "$1"; }
r()   { ssh $SSHO -n "$DEV" "$1" 2>&1; }
rin() { ssh $SSHO "$DEV" "sh -s" 2>&1; }
abort() { printf '\n  STOPPING: %s\n\n' "$*"; exit 1; }

ssh $SSHO -n "$DEV" "echo ok" 2>&1 | grep -q ok \
    || abort "cannot reach $DEV - is the handheld awake and on wifi?"

# ===================================================================== revert =
if [ "$MODE" = "revert" ]; then
    hr "BACKING OUT A AND B"
    say "A - the allocator env file. Pinning MALLOC_MMAP_THRESHOLD_ low has no"
    say "    upside now that the trim has shown the heap is live, and it costs"
    say "    a fresh mmap plus zero-fill for every mid-size allocation instead"
    say "    of reusing a free-list chunk."
    rin <<UEOF
E='$ENVF'
B=""
for c in \$(ls -1tr "\$E".before-* 2>/dev/null); do
    grep -q 'TSP_HEAPFIX_V1' "\$c" 2>/dev/null || { B="\$c"; break; }
done
if [ -n "\$B" ]; then cp -p "\$B" "\$E" && printf '    restored from %s\n' "\$B"
elif [ -f "\$E" ]; then rm -f "\$E" && echo "    removed (there was no prior version)"
else echo "    already gone"; fi
[ -f "\$E" ] && { echo "    now contains:"; sed 's/^/      /' "\$E"; } || echo "    now: absent"
UEOF
    say ""
    say "B - the two preload settings. A SMALLER cache means more cells get"
    say "    thrown out and re-instantiated while walking, which is the exact"
    say "    moment the hitches happen. Back to 24 and 20."
    rin <<SEOF
C='$CFG'
B="\$(ls -1tr "\$C".before-heapfix-* 2>/dev/null | head -1)"
if [ -n "\$B" ] && grep -q '^preload cell cache max = 16' "\$B" 2>/dev/null; then
    echo "    REFUSING: oldest backup \$B already has the edit - not restoring"
elif [ -n "\$B" ]; then
    cp -p "\$B" "\$C" && printf '    restored from %s\n' "\$B"
else
    sed -i -e 's/^[[:space:]]*preload cell cache max[[:space:]]*=.*/preload cell cache max = 24/' \\
           -e 's/^[[:space:]]*preload cell expiry delay[[:space:]]*=.*/preload cell expiry delay = 20/' "\$C"
    echo "    no backup found - set the two lines back by hand"
fi
grep -n -e 'preload cell cache max' -e 'preload cell expiry delay' -e 'preload instances' "\$C" | sed 's/^/      /'
SEOF
    say ""
    say "C - malloc_trim stays in the binary. rc=1 with ~0 returned is itself a"
    say "    finding, and the log line gives a free RSS reading every run."
    printf '\n  Now arm the sampler BEFORE the next launch:\n'
    printf '\n      bash ~/Downloads/tsp_verdict.sh arm\n\n'
    exit 0
fi

# ======================================================================== off =
if [ "$MODE" = "off" ]; then
    hr "REMOVING THE SAMPLER"
    r "touch /mnt/SDCARD/tsp_verdict_off; sleep 2; ps 2>/dev/null | grep -c '[t]sp_verdict_sampler' | sed 's/^/    still running: /'"
    exit 0
fi

# ======================================================================== arm =
if [ "$MODE" = "arm" ]; then
    hr "ARMING THE 1 Hz SAMPLER FOR THE NEXT COLD LAUNCH"
    case "$SECS" in ''|*[!0-9]*) abort "seconds must be a number, got '$SECS'" ;; esac
    ARMOUT="$(rin <<AEOF
set -u
rm -f /mnt/SDCARD/tsp_verdict_off
rm -rf '$OUTDIR'; mkdir -p '$OUTDIR'
cat > '$SAMPLER' <<'SEOF'
#!/bin/sh
# TSP_VERDICT_SAMPLER_V1. Five cheap /proc reads a second. No smaps at 1 Hz -
# that makes the kernel walk every VMA and this process has hundreds of them.
set -u
O="\$1"; LIMIT="\$2"
# Prove this process actually started, independently of how ps behaves here.
# An arm check that greps ps is at the mercy of procps-vs-busybox differences;
# this file is direct evidence and cannot be wrong.
mkdir -p "\$O"
printf 'started_at=%s pid=%s\n' "\$(date +%s)" "\$\$" > "\$O/started"
# wait for the game, up to 5 minutes
W=0
while [ \$W -lt 300 ]; do
    [ -f /mnt/SDCARD/tsp_verdict_off ] && exit 0
    P="\$(pidof openmw-0.51 2>/dev/null | awk '{print \$1}')"
    [ -n "\$P" ] || P="\$(ps -e 2>/dev/null | grep '[o]penmw-0.51' | awk '{print \$1}' | head -1)"
    [ -n "\$P" ] || P="\$(ps 2>/dev/null | grep '[o]penmw-0.51' | awk '{print \$1}' | head -1)"
    [ -n "\$P" ] && break
    W=\$((W+1)); sleep 1
done
[ -n "\${P:-}" ] || { echo "never-appeared" > "\$O/status"; exit 1; }
echo "\$P" > "\$O/pid"
printf 'armed_at=%s pid=%s limit=%s\n' "\$(date +%s)" "\$P" "\$LIMIT" > "\$O/status"

pmaj=""; pmin=""; psys=""; put=""; pst=""
N=0
while [ \$N -lt "\$LIMIT" ]; do
    [ -f /mnt/SDCARD/tsp_verdict_off ] && break
    [ -d "/proc/\$P" ] || { echo "gone_at=\$(date +%s) sample=\$N" >> "\$O/status"; break; }

    st="\$(cat "/proc/\$P/stat" 2>/dev/null)"
    [ -n "\$st" ] || { N=\$((N+1)); sleep 1; continue; }
    # Strip through the comm field. It can contain spaces AND parentheses, so
    # this must be the LONGEST match (##) - a shortest match (#) cuts inside a
    # comm like "(we ird) name)" and shifts every field afterwards.
    # rest field N is stat field N+2, so:
    #   minflt (stat 10) -> \$8    majflt (stat 12) -> \$10
    #   utime  (stat 14) -> \$12   stime  (stat 15) -> \$13
    # Verified against a live /proc/<pid>/stat, not counted off a man page:
    # an earlier version used \$7/\$9/\$11/\$12 and reported MINOR faults in the
    # major-fault column.
    rest="\${st##*) }"
    set -- \$rest
    min="\${8:--1}"; maj="\${10:--1}"; ut="\${12:--1}"; stime="\${13:--1}"

    rss="\$(awk '/^VmRSS:/{print \$2}' "/proc/\$P/status" 2>/dev/null)"
    swp="\$(awk '/^VmSwap:/{print \$2}' "/proc/\$P/status" 2>/dev/null)"
    sys="\$(awk '/^pgmajfault /{print \$2}' /proc/vmstat 2>/dev/null)"
    eval "\$(awk '/^MemAvailable:/{printf "av=%s ", \$2}
                  /^Cached:/{printf "ca=%s ", \$2}
                  /^SwapFree:/{printf "sf=%s ", \$2}' /proc/meminfo 2>/dev/null)"

    dmaj=-1; dmin=-1; dsys=-1; dut=-1; dst=-1
    [ -n "\$pmaj" ] && dmaj=\$((maj-pmaj))
    [ -n "\$pmin" ] && dmin=\$((min-pmin))
    [ -n "\$psys" ] && dsys=\$((sys-psys))
    [ -n "\$put" ]  && dut=\$((ut-put))
    [ -n "\$pst" ]  && dst=\$((stime-pst))
    pmaj="\$maj"; pmin="\$min"; psys="\$sys"; put="\$ut"; pst="\$stime"

    printf 't=%s e=%s rss=%s swp=%s maj=%s min=%s sysmaj=%s av=%s ca=%s sf=%s ut=%s st=%s\n' \
        "\$(date +%H:%M:%S)" "\$(date +%s)" "\${rss:--1}" "\${swp:--1}" \
        "\$dmaj" "\$dmin" "\$dsys" "\${av:--1}" "\${ca:--1}" "\${sf:--1}" "\$dut" "\$dst" \
        >> "\$O/samples"

    # the heap line is expensive, so once every 10 s only
    if [ \$((N % 10)) -eq 0 ]; then
        awk '/\[heap\]\$/{h=1;next} h&&/^Size:/{s=\$2} h&&/^Rss:/{r=\$2} h&&/^Swap:/{w=\$2;
             printf "t=%s sz=%s rss=%s swp=%s\n", "'"\$(date +%H:%M:%S)"'", s, r, w; h=0}' \
            "/proc/\$P/smaps" 2>/dev/null >> "\$O/heap"
    fi
    N=\$((N+1))
    sleep 1
done
printf 'finished_at=%s samples=%s\n' "\$(date +%s)" "\$N" >> "\$O/status"
SEOF
chmod 755 '$SAMPLER'
if ! sh -n '$SAMPLER' 2>&1; then
    echo "    SAMPLER IS NOT VALID SHELL - not starting it"
    exit 9
fi
nohup '$SAMPLER' '$OUTDIR' '$SECS' >/dev/null 2>&1 &
sleep 1
RUN="\$(ps 2>/dev/null | grep -c '[t]sp_verdict_sampler')"
printf '    sampler lines: %s   md5 %s   ps count: %s\n' \
    "\$(wc -l < '$SAMPLER')" "\$(md5sum '$SAMPLER' | cut -c1-12)" "\$RUN"
if [ -s '$OUTDIR/started' ]; then
    printf '    it ran: %s\n' "\$(cat '$OUTDIR/started')"
    echo "    ARMED_OK"
else
    echo "    SAMPLER NEVER STARTED - no \$O/started marker was written"
    exit 9
fi
AEOF
)"
printf '%s\n' "$ARMOUT"
    printf '%s\n' "$ARMOUT" | grep -q 'ARMED_OK' || {
        printf '\n'
        say "THE SAMPLER DID NOT ARM. The output above says why. Not telling you"
        say "to launch, because this run would measure nothing."
        printf '\n'
        exit 1; }

    cat <<FEOF

  It is now waiting for openmw to appear, for up to 5 minutes, then samples for
  $SECS seconds.

  1. Launch the game from the menu.
  2. Load the Balmora save and walk the same route past Caius Cosades.
  3. Quit the game (or just leave it - the sampler stops on its own).
  4. Run the pull.

FEOF
    printf '      bash ~/Downloads/tsp_verdict.sh pull\n\n'
    exit 0
fi

# ======================================================================= pull =
hr "FETCHING"
W="$HOME/Downloads/tsp_verdict_$STAMP"
mkdir -p "$W"
r "cat $OUTDIR/status 2>/dev/null | sed 's/^/    /' || echo '    no status - was arm run?'"
for f in samples heap status pid; do
    scp $SSHO "$DEV:$OUTDIR/$f" "$W/$f" >/dev/null 2>&1
done
# the fps and frame-cost lines the game already logs, with their wall clocks
r "grep -h -e 'raw_fps=' -e 'TSP_CULLDRAW' -e 'TSP_ICO_BUDGET' '$LOG' 2>/dev/null | tail -600" > "$W/loglines" 2>/dev/null
say "saved into $W"

[ -s "$W/samples" ] || {
    say "no samples. Either arm was not run before the launch, or openmw never"
    say "appeared within 5 minutes. Arm it, THEN launch:"
    printf '\n      bash ~/Downloads/tsp_verdict.sh arm\n\n'
    exit 1; }
say "$(wc -l < "$W/samples") samples, $(wc -l < "$W/loglines" 2>/dev/null || echo 0) log lines with fps or frame cost"

# ---- pull fps out of the log, keyed by HH:MM:SS -----------------------------
awk '
match($0, /\[[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) {
    ts = substr($0, RSTART + 1, 8)
    if (match($0, /raw_fps=[0-9.]+/))
        printf "fps %s %s\n", ts, substr($0, RSTART + 8, RLENGTH - 8)
    if (match($0, /resid=[0-9.]+/))
        printf "resid %s %s\n", ts, substr($0, RSTART + 6, RLENGTH - 6)
    if (match($0, /render=[0-9.]+/))
        printf "render %s %s\n", ts, substr($0, RSTART + 7, RLENGTH - 7)
}' "$W/loglines" > "$W/fps" 2>/dev/null

hr "WHICH A/B ARM DID THIS RUN USE"
r "grep -h 'TSP_AB_SWITCH_V1' /mnt/SDCARD/tsp_prog.txt 2>/dev/null | tail -4 | sed 's/^/    /'"
r "grep -qh 'TSP_AB_SWITCH_V1' /mnt/SDCARD/tsp_prog.txt 2>/dev/null || echo '    (launcher switches not installed - both arms are at their defaults)'"
r "ls /mnt/SDCARD/tsp_noscaler >/dev/null 2>&1 && echo '    flag now: scaler=OFF' || echo '    flag now: scaler=ON'"
r "ls /mnt/SDCARD/tsp_texsd  >/dev/null 2>&1 && echo '    flag now: texroot=SD' || echo '    flag now: texroot=UDISK'"
say "(the flag lines are NOW; the TSP_AB_SWITCH lines are what the run actually did)"

hr "DID THE TWO RESTORED FIXES ACTUALLY GET PICKED UP"
r "grep -h 'TSP_ICO_BUDGET_V1' '$LOG' 2>/dev/null | tail -4 | sed 's/^/    /'"
r "grep -qh 'TSP_ICO_BUDGET_V1' '$LOG' 2>/dev/null || echo '    NO TSP_ICO_BUDGET_V1 LINE - the ICO cap is NOT being applied'"
r "grep -h -i -e 'ktx load' -e 'ktx: ' '$LOG' 2>/dev/null | tail -4 | sed 's/^/    /'"
r "grep -c -i 'ktx' '$LOG' 2>/dev/null | sed 's/^/    lines mentioning ktx in the log: /'"
say "(TSP_ICO_MAXOBJ and TSP_KTX are both read at startup - if the ICO line is"
say " missing or the ktx count is 0, the env file is not reaching the game and"
say " nothing below is a valid test of them.)"

hr "TEXTURES - is ASTC actually being used, and off which device"
rin <<'TEOF'
G="/mnt/SDCARD/data/ports/openmw"
L="$G/openmw_log.txt"
echo "--- every ktx / ASTC mention in this log, verbatim"
grep -h -i -e 'ktx' -e 'astc' "$L" 2>/dev/null | tail -14 | sed 's/^/    /'
N="$(grep -c -i -e 'ktx' -e 'astc' "$L" 2>/dev/null)"
printf '    total: %s lines
' "${N:-0}"
echo "--- THE DECIDER: which copy does data= point at, and are they the same file"
SD="$G/data/Data Files/textures"
EM="/mnt/UDISK/openmw-tex/textures"
S1="$(find "$SD/" -maxdepth 1 -iname '*.ktx' 2>/dev/null | head -1)"
if [ -n "$S1" ]; then
    NM="$(basename "$S1")"
    printf '    sample file: %s
' "$NM"
    for p in "$SD/$NM" "$EM/$NM"; do
        if [ -e "$p" ]; then
            printf '      %-56s dev+inode %s  %s bytes
' "$p"                 "$(stat -c '%d:%i' "$p" 2>/dev/null || echo '?')"                 "$(stat -c '%s' "$p" 2>/dev/null || echo '?')"
        else
            printf '      %-56s ABSENT
' "$p"
        fi
    done
    echo "      same dev+inode = one file reached two ways (the move IS wired)"
    echo "      different      = two copies, and data= decides which is read"
else
    echo "    no .ktx directly under the SD textures path"
fi
echo "--- the data= roots the game is using, in order"
grep -n '^data=' "$G/openmw.cfg" 2>/dev/null | sed 's/^/    /'
echo "--- and where each of those roots actually lives"
grep '^data=' "$G/openmw.cfg" 2>/dev/null | sed 's/^data=//; s/^"//; s/"$//' | while read -r d; do
    [ -d "$d" ] || continue
    printf '    %-58s %s
' "$d" "$(df "$d" 2>/dev/null | tail -1 | awk '{print $1"  "$6}')"
done
TEOF
say ""
say "A 'ktx loads: N' line with N > 0 is the only proof TSP_KTX=1 is doing"
say "anything. If there is no such line, ASTC may not be in use at all and the"
say "memory half of the restore is unverified."

hr "SECOND BY SECOND - faults, memory, and fps where the log has it"
awk '
FILENAME ~ /fps$/ { if ($1 == "fps") fps[$2] = $3; if ($1 == "render") rnd[$2] = $3; next }
{
    delete F
    for (i = 1; i <= NF; i++) { split($i, kv, "="); F[kv[1]] = kv[2] }
    t = F["t"]; if (t == "") next
    n++
    maj = F["maj"] + 0; sys = F["sysmaj"] + 0
    if (F["maj"] == "-1") maj = -1
    printf "    %s  maj/s %6s  sysmaj/s %7s  rss %6.0f  swap %6.0f  avail %6.0f  cached %6.0f  cpu %3d%%  %s%s\n",
        t,
        (maj < 0 ? "-" : maj),
        (F["sysmaj"] == "-1" ? "-" : sys),
        F["rss"] / 1024, F["swp"] / 1024, F["av"] / 1024, F["ca"] / 1024,
        (F["ut"] < 0 ? 0 : (F["ut"] + F["st"])),
        (t in fps ? sprintf("fps %5.1f", fps[t]) : ""),
        (t in rnd ? sprintf("  render %sms", rnd[t]) : "")
}
END { if (!n) print "    (no parseable samples)" }
' "$W/fps" "$W/samples" | awk '
# Never drop a second that had a fault or a fps reading - an every-other-row
# filter hid half the samples from the last two analyses. Quiet stretches are
# thinned instead, and the count of what was thinned is printed.
/maj\/s +[1-9]/ || /fps/ { print; next }
{ q++; if (q % 5 == 1) print; else hid++ }
END { if (hid) printf "    (%d further consecutive zero-fault seconds not listed)\n", hid }'

hr "THE WORST 12 SECONDS, RANKED BY MAJOR FAULTS"
awk '
FILENAME ~ /fps$/ { if ($1 == "fps") fps[$2] = $3; next }
{
    delete F
    for (i = 1; i <= NF; i++) { split($i, kv, "="); F[kv[1]] = kv[2] }
    if (F["t"] == "" || F["maj"] == "-1") next
    printf "%d\t%s\t%s\t%.0f\t%.0f\t%.0f\t%s\n", F["maj"], F["t"], F["sysmaj"],
        F["rss"]/1024, F["av"]/1024, F["ca"]/1024, (F["t"] in fps ? fps[F["t"]] : "-")
}' "$W/fps" "$W/samples" | sort -rn | head -12 | awk -F'\t' '
BEGIN { printf "    %8s  %10s  %10s  %8s  %8s  %8s  %6s\n",
        "maj/s", "at", "sysmaj/s", "rss MB", "avail MB", "cached MB", "fps" }
{ printf "    %8s  %10s  %10s  %8s  %8s  %8s  %6s\n", $1, $2, $3, $4, $5, $6, $7 }'

hr "FRAME COST OVER TIME - render = cull + draw + resid"
awk '
match($0, /\[[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) {
    ts = substr($0, RSTART + 1, 8)
    if (!match($0, /TSP_CULLDRAW/)) next
    r = c = d = x = ""
    if (match($0, /render=[0-9.]+/)) r = substr($0, RSTART + 7, RLENGTH - 7)
    if (match($0, /cull=[0-9.]+/))   c = substr($0, RSTART + 5, RLENGTH - 5)
    if (match($0, /draw=[0-9.]+/))   d = substr($0, RSTART + 5, RLENGTH - 5)
    if (match($0, /resid=[0-9.]+/))  x = substr($0, RSTART + 6, RLENGTH - 6)
    if (r == "") next
    # Force numeric NOW. substr() returns a STRING, so "r < 40" is a string
    # comparison and "1143.9" < "40" is TRUE because "1" < "4" - which put a
    # 1143 ms load frame in the GOOD bucket and every real hitch in LOAD.
    r = r + 0; c = c + 0; d = d + 0; x = x + 0
    n++
    printf "    %s  render %7.1f  cull %6.1f  draw %6.1f  resid %6.1f  (%.0f%% of the frame)\n",
        ts, r, c, d, x, (r > 0 ? x / r * 100 : 0)
    tr += r; tc += c; td += d; tx += x
    if (r < 40)        { gn++; gr += r; gc += c; gd += d; gx += x }
    else if (r <= 200) { bn++; br += r; bc += c; bd += d; bx += x }
    else               { ln++; lr += r; lc += c; ld += d; lx += x }
}
END {
    if (!n) { print "    (no TSP_CULLDRAW lines in the log tail)"; exit }
    printf "\n    MEAN OVER %d SAMPLES: render %.1f = cull %.1f + draw %.1f + resid %.1f\n",
        n, tr/n, tc/n, td/n, tx/n
    # A couple of 700-1100 ms load frames destroy that mean, so split the
    # steady state (render under 40 ms) from the spikes and compare the two.
    printf "\n    %-22s %7s %7s %7s %7s %7s\n", "", "count", "render", "cull", "draw", "resid"
    if (gn) printf "    %-22s %7d %7.1f %7.1f %7.1f %7.1f\n", "GOOD  (render < 40ms)", gn, gr/gn, gc/gn, gd/gn, gx/gn
    if (bn) printf "    %-22s %7d %7.1f %7.1f %7.1f %7.1f\n", "HITCH (render 40-200)", bn, br/bn, bc/bn, bd/bn, bx/bn
    if (ln) printf "    %-22s %7d %7.1f %7.1f %7.1f %7.1f\n", "LOAD  (render > 200)", ln, lr/ln, lc/ln, ld/ln, lx/ln
    if (gn && bn) {
        printf "\n    WHAT A HITCH COSTS, over a good frame:  cull %+.1f   draw %+.1f   resid %+.1f ms\n",
            bc/bn - gc/gn, bd/bn - gd/gn, bx/bn - gx/gn
        print  "    The biggest of those three is where the hitch lives. draw = the GL"
        print  "    traversal, which is where the IncrementalCompileOperation runs."
    }
}' "$W/loglines"

hr "FRAME TIME AS FPS - what the on-screen counter used to tell you, finer"
awk '
match($0, /\[[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) {
    if (!match($0, /TSP_CULLDRAW/)) {
        if (match($0, /raw_fps=[0-9.]+/)) { lf += substr($0, RSTART + 8, RLENGTH - 8) + 0; ln++ }
        next
    }
    if (!match($0, /render=[0-9.]+/)) next
    ms = substr($0, RSTART + 7, RLENGTH - 7) + 0
    if (ms <= 0 || ms > 200) next          # load frames are not gameplay
    n++; f = 1000 / ms; v[n] = f; sum += f
    if (f >= 28)      b1++
    else if (f >= 24) b2++
    else if (f >= 20) b3++
    else if (f >= 15) b4++
    else if (f >= 10) b5++
    else              b6++
}
END {
    if (!n) { print "    (no usable frame-cost lines)"; exit }
    for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (v[j] < v[i]) { t=v[i]; v[i]=v[j]; v[j]=t }
    printf "    %d gameplay frames sampled\n\n", n
    printf "    %-14s %6s  %s\n", "band", "frames", "share"
    split("28+ fps|24-28|20-24|15-20|10-15|under 10", NM, "|")
    c[1]=b1; c[2]=b2; c[3]=b3; c[4]=b4; c[5]=b5; c[6]=b6
    for (i = 1; i <= 6; i++) {
        k = c[i] + 0
        bar = ""
        w = int(k * 40 / n + 0.5)
        for (q = 0; q < w; q++) bar = bar "#"
        printf "    %-14s %6d  %-40s %4.1f%%\n", NM[i], k, bar, k * 100 / n
    }
    # Precompute the indices. A ">" inside a printf ARGUMENT is parsed by awk as
    # output redirection, so "v[int(n*0.05) > 0 ? a : b]" is a syntax error
    # there even though the identical expression is fine in an assignment.
    i5 = int(n * 0.05); if (i5 < 1) i5 = 1
    i50 = int(n * 0.50); if (i50 < 1) i50 = 1
    printf "\n    worst frame   %6.1f fps  (%.1f ms)\n", v[1], 1000 / v[1]
    printf "    5th pct       %6.1f fps\n", v[i5]
    printf "    median        %6.1f fps\n", v[i50]
    printf "    best frame    %6.1f fps  (%.1f ms)\n", v[n], 1000 / v[n]
    if (ln) printf "\n    cross-check: the game logged raw_fps averaging %.1f; frame time says %.1f\n",
        lf / ln, sum / n
    print  "\n    The bottom three bands are what a hitch feels like. This is per-frame,"
    print  "    so it catches a single 70 ms frame that a once-a-second counter misses."
}' "$W/loglines"

hr "PHASE SPLIT - load, walk, and quit are three different things"
say "Averaging them together is what made the last summary unreadable. The walk"
say "is the only phase the hitching question is about."
awk '
{
    delete F
    for (i = 1; i <= NF; i++) { split($i, kv, "="); F[kv[1]] = kv[2] }
    if (F["t"] == "" || F["maj"] == "-1") next
    k++; rss[k] = F["rss"] + 0; maj[k] = F["maj"] + 0
    ca[k] = F["ca"] + 0; av[k] = F["av"] + 0; tt[k] = F["t"]
    if (rss[k] > peak) peak = rss[k]
}
END {
    if (!k) { print "    no samples"; exit }
    # LOAD: from the start until RSS first reaches 90% of its peak.
    # QUIT: the tail after RSS starts falling away from the peak for good.
    # WALK: what is left in the middle - the only phase that answers the
    #       question, and the only one worth comparing between runs.
    for (i = 1; i <= k; i++) if (rss[i] >= 0.90 * peak) { loadend = i; break }
    # Teardown is unambiguous: hundreds to thousands of faults per second while
    # CPU collapses, as the kernel reaps the address space. An RSS-based boundary
    # put a 2375-fault teardown second inside WALK and tripled its mean.
    quitstart = k + 1
    for (i = k; i > loadend; i--) {
        if (maj[i] > 500) quitstart = i
        else if (quitstart <= k && i < quitstart - 3) break
    }
    if (quitstart > k) for (i = k; i > loadend; i--) { if (rss[i] >= 0.95 * peak) { quitstart = i + 1; break } }
    split("LOAD WALK QUIT", NAME, " ")
    lo[1] = 1;           hi[1] = loadend
    lo[2] = loadend + 1; hi[2] = quitstart - 1
    lo[3] = quitstart;   hi[3] = k
    printf "    %-6s %-19s %5s %9s %9s %7s %7s %8s %10s %10s\n",
        "phase", "window", "secs", "maj TOTAL", "mean/s", "median", "p95", "worst", "cached MB", "avail MB"
    for (p = 1; p <= 3; p++) {
        if (hi[p] < lo[p]) { printf "    %-6s (empty)\n", NAME[p]; continue }
        t = 0; w = 0; mc = 0; mnca = 0; mnav = 0; big = 0
        delete v
        for (i = lo[p]; i <= hi[p]; i++) {
            t += maj[i]; mc++; v[mc] = maj[i]
            if (maj[i] > w) w = maj[i]
            if (maj[i] > 500) big++
            if (mnca == 0 || ca[i] < mnca) mnca = ca[i]
            if (mnav == 0 || av[i] < mnav) mnav = av[i]
        }
        for (a = 1; a <= mc; a++) for (b = a + 1; b <= mc; b++) if (v[b] < v[a]) { z=v[a]; v[a]=v[b]; v[b]=z }
        md = v[int(mc * 0.50) > 0 ? int(mc * 0.50) : 1]
        p9 = v[int(mc * 0.95) > 0 ? int(mc * 0.95) : mc]
        printf "    %-6s %-19s %5d %9d %9.1f %7d %7d %8d %10.0f %10.0f\n",
            NAME[p], tt[lo[p]] " - " tt[hi[p]], mc, t, t / mc, md, p9, w, mnca / 1024, mnav / 1024
        if (p == 2 && big > 0)
            printf "           ^ WARNING: %d second(s) above 500 faults are inside WALK -\n           the phase boundary is probably still swallowing teardown.\n", big
    }
    print  ""
    print  "    WALK is the number to compare between runs. LOAD is a cold page cache"
    print  "    and will always storm. QUIT is teardown and is not a hitch at all."
}' "$W/samples"

hr "ONE SUMMARY LINE - WHOLE RUN, ALL PHASES MIXED"
awk '
{
    delete F
    for (i = 1; i <= NF; i++) { split($i, kv, "="); F[kv[1]] = kv[2] }
    if (F["t"] == "") next
    if (F["maj"] != "-1") {
        m = F["maj"] + 0; tot += m; n++
        if (m > mx) { mx = m; mxt = F["t"] }
        if (m >= 30) b30++
        if (m >= 100) b100++
        a[n] = m
    }
    rss = F["rss"] + 0; if (rss > mxrss) mxrss = rss
    av = F["av"] + 0;   if (mnav == 0 || av < mnav) mnav = av
    ca = F["ca"] + 0;   if (mnca == 0 || ca < mnca) mnca = ca
    sf = F["sf"] + 0;   if (mnsf == 0 || sf < mnsf) mnsf = sf
    sw = F["swp"] + 0;  if (sw > mxswp) mxswp = sw
}
END {
    if (!n) { print "    no fault samples"; exit }
    for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (a[j] < a[i]) { x=a[i]; a[i]=a[j]; a[j]=x }
    p50 = a[int(n * 0.50) + 0 ? int(n * 0.50) : 1]
    p95 = a[int(n * 0.95) + 0 ? int(n * 0.95) : n]
    printf "    seconds sampled        %d\n", n
    printf "    major faults TOTAL     %d\n", tot
    printf "    major faults per sec   mean %.1f   median %d   p95 %d   peak %d at %s\n", tot / n, p50, p95, mx, mxt
    printf "    seconds over 30 / 100  %d / %d\n", b30 + 0, b100 + 0
    printf "    peak VmRSS             %.0f MB\n", mxrss / 1024
    printf "    floor MemAvailable     %.0f MB\n", mnav / 1024
    printf "    floor Cached           %.0f MB   <- page cache eviction is the mechanism\n", mnca / 1024
    printf "    floor SwapFree         %.0f MB   (system-wide)\n", mnsf / 1024
    printf "    peak PROCESS swap      %.0f MB   <- 0 means nothing went to the swapfile\n", mxswp / 1024
}' "$W/samples"

hr "THE HEAP, EVERY 10 s"
[ -s "$W/heap" ] && awk '{
    delete F; for (i = 1; i <= NF; i++) { split($i, kv, "="); F[kv[1]] = kv[2] }
    printf "    %s  reserved %6.1f MB  Rss %6.1f MB  Swap %6.1f MB  committed %6.1f MB\n",
        F["t"], F["sz"]/1024, F["rss"]/1024, F["swp"]/1024, (F["rss"]+F["swp"])/1024
}' "$W/heap" || say "(no heap samples)"

cat <<'REOF'

  HOW TO USE THIS

  The summary block is the whole point. Run it once now to get a BASELINE with
  A and B reverted, then once per change. Compare these four numbers and nothing
  else:

      major faults per sec mean      the headline
      seconds over 30                how much of the walk was a fault storm
      floor Cached                   how hard the page cache got evicted
      peak VmRSS                     whether the change actually shrank anything

  A change that lowers faults/s and raises the Cached floor is working, whatever
  it felt like. A change that does not move them did nothing, however good that
  particular run felt - two runs on identical config have already differed by
  more than any effect measured so far.

REOF
printf '\n'
