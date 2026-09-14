#!/bin/sh
# tsp_hitch.sh v2 - what stalls the frame, measured honestly.
#
#   dump             static state, read-only, to a txt in ~/Downloads
#   watch [seconds]  sample the MAIN THREAD while the game sits at the hitchy spot
#   vmtest [seconds] A/B the two kernel memory settings the evidence points at,
#                    with the fault counter as the scoreboard, then put them back
#
# WHAT WAS WRONG IN v1, and it was wrong in a way that produced a confident
# answer out of nothing:
#
#  1. It read /proc/<pid>/stat for "main thread cpu". That file is the whole
#     PROCESS - all 19 threads summed. Against a 43 s window it reported 57.8 s
#     of cpu, 133%. off-cpu was computed as wall minus that, went negative, got
#     clamped to 0, and the cascade then had no choice but to print "ON CPU the
#     whole window". The main thread is /proc/<pid>/task/<pid>/stat. Fixed.
#
#  2. /proc/<pid>/schedstat does not exist on this kernel (no CONFIG_SCHEDSTATS).
#     runq_ns=0 meant NOT MEASURED, and v1 printed it as "0 ms preempted". The
#     2>/dev/null was also after the input redirect instead of before it, which
#     is why there were a thousand error lines. Both fixed: the probe runs once,
#     up front, and anything unavailable prints as "not measured" and is excluded
#     from the attribution entirely.
#
#  3. PSI is absent on this kernel too - the dump says so in plain text - so the
#     io, memory and cpu stall lines were structurally zero. Same fix.
#
#  4. Conceptually: direct reclaim runs IN the allocating thread and burns ITS
#     cpu. So "on cpu" and "memory bound" are not alternatives, and v1's cascade
#     treated them as if they were. allocstall and pgscan_direct are now read as
#     on-cpu memory work, not as a stall.
#
# What v1 collected and never used: the per-tick major-fault delta. That is the
# one number that can actually show a 33 ms hitch, because a burst of faults
# inside one frame is what a hitch looks like from the kernel's side. It is the
# centrepiece now.

set -u

DEV="root@192.168.1.12"
GAMEDIR="/mnt/SDCARD/data/ports/openmw"
LAUNCHER="/mnt/SDCARD/Roms/PORTS/Morrowind.sh"
CONT="openmw_builder"
SRC="/root/openmw-0.51-tsp-src"
SSHO="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/tsp_hitch_dump_$STAMP.txt"
SECS="${2:-40}"
MODE="${1:-dump}"

r() { ssh $SSHO -n "$DEV" "$1" 2>&1; }
rin() { ssh $SSHO "$DEV" "sh -s" 2>&1; }
d() { docker exec "$CONT" sh -c "$1" 2>&1; }
din() { docker exec -i "$CONT" sh -c "$1" 2>&1; }
sec() {
    printf '\n\n===============================================================\n== %s\n===============================================================\n' "$1" >>"$OUT"
    printf '  .. %s\n' "$1"
}
both() { printf '  %s\n' "$*"; printf '%s\n' "$*" >>"$OUT"; }
say() { printf '  %s\n' "$*"; }
hr() { printf '\n########## %s ##########\n' "$1"; }

case "$MODE" in
dump | watch | vmtest | noswap | firstload) ;;
*)
    printf 'usage: %s dump | watch [s] | noswap [s] | vmtest [s]\n       %s firstload base|swappy|noswap|compare [s]\n' "$0" "$0"
    exit 2
    ;;
esac

if ! r "echo ok" | grep -q ok; then
    say "cannot reach $DEV - is the handheld awake and on wifi?"
    exit 1
fi

# ------------------------------------------------------------ the sampler -----
# Written once, used by both watch and vmtest. Everything is in 10 ms units:
# /proc/uptime centiseconds and jiffies are both 1/100 s, so no floating point.
upload_sampler() {
    rin <<'SAMPEOF'
cat > /tmp/tsp_sample.sh <<'INNER'
#!/bin/sh
P="$1"; SECS="$2"
T="/proc/$P/task/$P"      # the MAIN THREAD, not the whole process

# ---- capability probe, once, so nothing unmeasured is reported as a zero ----
HAVE_SCHED=0; [ -r "$T/schedstat" ] && HAVE_SCHED=1
HAVE_PSI=0;   [ -r /proc/pressure/memory ] && HAVE_PSI=1
echo "@@CAPS"
echo "schedstat=$HAVE_SCHED"
echo "psi=$HAVE_PSI"

up() {
  _u=""
  if [ -r /proc/uptime ]; then read -r _u _ < /proc/uptime; fi
  case "$_u" in
    *.*) _i=${_u%.*}; _f=${_u#*.}; UP=$(( _i * 100 + ${_f#0} + 0 ));;
    *) BADUP=$((BADUP + 1));;
  esac
}
# main thread: minflt=8 majflt=10 utime=12 stime=13 of the post-") " fields
tstat() {
  read -r _l < "$T/stat" || return 1
  _l="${_l#*) }"; set -- $_l
  MINF=$8; MAJF=${10}; UT=${12}; ST=${13}
}
# whole process, reported separately and labelled as such
pstat() {
  read -r _l < "/proc/$P/stat" || return 1
  _l="${_l#*) }"; set -- $_l
  PMAJ=${10}; PUT=${12}; PST=${13}; NTH=${18}
}
sstat() { RUNQ=0; [ "$HAVE_SCHED" = 1 ] && { read -r _l < "$T/schedstat"; set -- $_l; RUNQ=$2; }; }
psi() {
  PMEM=0; PIO=0
  [ "$HAVE_PSI" = 1 ] || return 0
  while read -r kind rest; do
    [ "$kind" = "full" ] && for w in $rest; do case $w in total=*) PMEM=${w#total=};; esac; done
  done < /proc/pressure/memory
  while read -r kind rest; do
    [ "$kind" = "full" ] && for w in $rest; do case $w in total=*) PIO=${w#total=};; esac; done
  done < /proc/pressure/io
}
rss() { RSS=0; while read -r k v _; do [ "$k" = "VmRSS:" ] && RSS=$v; done < /proc/$P/status; }
mem() {
  MAVAIL=0; MFREE=0
  while read -r k v _; do
    case $k in MemAvailable:) MAVAIL=$v;; MemFree:) MFREE=$v;; esac
  done < /proc/meminfo
}
swapu() {
  SWU=0; SWT=0
  while read -r f t sz used pri; do
    case "$f" in /*) SWT=$((SWT + sz)); SWU=$((SWU + used));; esac
  done < /proc/swaps
}
oomk() { OOM=0; while read -r k v; do [ "$k" = "oom_kill" ] && OOM=$v; done < /proc/vmstat; }
vm() {
  SWPIN=0; SWPOUT=0; ASTALL=0; PGSD=0; SYSMAJ=0
  while read -r k v; do
    case $k in
      pswpin) SWPIN=$v;; pswpout) SWPOUT=$v;;
      pgmajfault) SYSMAJ=$v;; pgscan_direct) PGSD=$v;;
      allocstall_normal|allocstall_dma|allocstall_dma32|allocstall_movable) ASTALL=$((ASTALL + v));;
    esac
  done < /proc/vmstat
}
threads() {
  for t in /proc/$P/task/*; do
    read -r _l < "$t/stat" 2>/dev/null || continue
    _c="${_l#*(}"; _c="${_c%%)*}"
    _r="${_l#*) }"; set -- $_r
    printf '%s %s\n' "$_c" "$(( ${12} + ${13} ))"
  done
}

BADUP=0; SKIPPED=0
tstat || { echo "PROCESS GONE"; exit 1; }
pstat; sstat; psi; rss; vm; up; mem; swapu; oomk
MAVLOW=$MAVAIL; SWU0=$SWU; OOM0=$OOM; MAV0=$MAVAIL
U0=$UP; UT0=$UT; ST0=$ST; MAJ0=$MAJF; MIN0=$MINF; RQ0=$RUNQ
PUT0=$PUT; PST0=$PST; PMAJ0=$PMAJ
RSS0=$RSS; MEM0=$PMEM; IO0=$PIO
SW0=$SWPIN; SWO0=$SWPOUT; AS0=$ASTALL; PGSD0=$PGSD; SYSMAJ0=$SYSMAJ
threads > /tmp/tsp_thr_before.txt
SWPY0=$(cat /proc/sys/vm/swappiness)
SWON0=$(grep -c '^/' /proc/swaps)

if sleep 0.1 2>/dev/null; then HZS=10; SLP=0.1; else HZS=1; SLP=1; echo "    (no fractional sleep - 1 Hz)"; fi
TICKS=$((SECS * HZS))
WORSTOFF=0; WORSTF=0; F0=0; F10=0; F30=0; TOPF=""
PREV=$UP; PU=$UT; PS=$ST; PM=$MAJF
i=0
while [ $i -lt $TICKS ]; do
  sleep $SLP
  tstat || { echo "PROCESS GONE at tick $i"; break; }
  up
  dw=$((UP - PREV)); dc=$((UT - PU + ST - PS)); df=$((MAJF - PM))
  off=$((dw - dc)); [ $off -lt 0 ] && off=0
  if [ $dw -gt 100 ] || [ $dw -le 0 ]; then
    SKIPPED=$((SKIPPED + 1))
  else
    [ $off -gt $WORSTOFF ] && WORSTOFF=$off
    if [ $df -gt $WORSTF ]; then WORSTF=$df; fi
    # fault-burst histogram: how many sample windows carried a burst
    if [ $df -ge 30 ]; then F30=$((F30 + 1))
    elif [ $df -ge 10 ]; then F10=$((F10 + 1))
    elif [ $df -gt 0 ]; then F0=$((F0 + 1)); fi
    # keep the worst few ticks with their off-cpu, to see if they coincide
    if [ $df -ge 10 ]; then TOPF="$TOPF $df:$((off * 10)):$((i / HZS))"; fi
  fi
  PREV=$UP; PU=$UT; PS=$ST; PM=$MAJF
  i=$((i + 1))
  if [ $((i % HZS)) -eq 0 ]; then
    mem
    case "$MAVAIL" in ''|*[!0-9]*) : ;; *) [ "$MAVAIL" -lt "$MAVLOW" ] && MAVLOW=$MAVAIL;; esac
  fi
  if [ $((i % HZS)) -eq 0 ]; then
    printf '    %3ds/%ss  worst frame-gap %dms  worst fault burst %d\n' \
           $((i / HZS)) "$SECS" $((WORSTOFF * 10)) "$WORSTF"
  fi
done

tstat; pstat; sstat; psi; rss; vm; up
threads > /tmp/tsp_thr_after.txt
echo "@@RESULT"
echo "wall_cs=$((UP - U0))"
echo "main_cpu_cs=$((UT - UT0 + ST - ST0))"
echo "main_ut_cs=$((UT - UT0))"
echo "main_st_cs=$((ST - ST0))"
echo "proc_cpu_cs=$((PUT - PUT0 + PST - PST0))"
echo "main_majflt=$((MAJF - MAJ0))"
echo "proc_majflt=$((PMAJ - PMAJ0))"
echo "main_minflt=$((MINF - MIN0))"
echo "runq_ns=$((RUNQ - RQ0))"
echo "sys_majflt=$((SYSMAJ - SYSMAJ0))"
echo "swapin=$((SWPIN - SW0))"
echo "swapout=$((SWPOUT - SWO0))"
echo "allocstall=$((ASTALL - AS0))"
echo "pgscan_direct=$((PGSD - PGSD0))"
echo "psi_mem_us=$((PMEM - MEM0))"
echo "psi_io_us=$((PIO - IO0))"
echo "worst_off_ms=$((WORSTOFF * 10))"
echo "worst_burst=$WORSTF"
echo "burst_small=$F0"
echo "burst_10=$F10"
echo "burst_30=$F30"
echo "skipped=$SKIPPED"
echo "badup=$BADUP"
echo "ticks=$i"
echo "hz=$HZS"
echo "threads=$NTH"
echo "rss0_kb=$RSS0"
echo "rss1_kb=$RSS"
echo "cores=$(grep -c ^processor /proc/cpuinfo)"
mem; swapu; oomk
echo "memavail0_kb=$MAV0"
echo "memavail_low_kb=$MAVLOW"
echo "memavail1_kb=$MAVAIL"
echo "swap_used0_kb=$SWU0"
echo "swap_used1_kb=$SWU"
echo "swap_total_kb=$SWT"
echo "oom_kills=$((OOM - OOM0))"
echo "swappiness=$(cat /proc/sys/vm/swappiness)"
echo "swappiness0=$SWPY0"
echo "swapon0=$SWON0"
echo "min_free_kbytes=$(cat /proc/sys/vm/min_free_kbytes)"
echo "@@TOPF$TOPF"
echo "@@THREADS"
awk 'NR==FNR{a[$1]+=$2;next}{b[$1]+=$2}END{for(k in b){d=b[k]-a[k]; if(d>0) printf "%s %d\n", k, d}}' \
  /tmp/tsp_thr_before.txt /tmp/tsp_thr_after.txt | sort -k2 -nr | head -10
INNER
chmod 755 /tmp/tsp_sample.sh
echo "    sampler written"
SAMPEOF
}

# ------------------------------------------------------------- the report -----
report() {
    awk '
    /^@@CAPS/   { c = 1; next }
    /^@@RESULT/ { c = 0; v_ = 1; next }
    /^@@TOPF/   { v_ = 0; sub(/^@@TOPF/, ""); topf = $0; next }
    /^@@THREADS/{ v_ = 0; th = 1; next }
    c    && /=/     { split($0, k, "="); cap[k[1]] = k[2]; next }
    v_   && /=/     { split($0, k, "="); v[k[1]] = k[2]; next }
    th   && NF == 2 { tn++; tname[tn] = $1; tms[tn] = $2 * 10; next }
    END {
        wall = nz(v["wall_cs"]) * 10
        if (wall <= 0) { print "  window measured 0 ms - unusable sample, re-run."; exit }
        hz = nz(v["hz"]); if (hz < 1) hz = 1
        mcpu = nz(v["main_cpu_cs"]) * 10
        pcpu = nz(v["proc_cpu_cs"]) * 10
        off = wall - mcpu; if (off < 0) off = 0
        secs = wall / 1000.0

        printf "  window                       %7d ms   (%d samples at %d Hz)\n", wall, nz(v["ticks"]), hz
        printf "  MAIN THREAD on cpu           %7d ms  %3d%%   (user %d, sys %d)\n", \
               mcpu, 100 * mcpu / wall, nz(v["main_ut_cs"]) * 10, nz(v["main_st_cs"]) * 10
        printf "  MAIN THREAD off cpu          %7d ms  %3d%%\n", off, 100 * off / wall
        printf "  whole process on cpu         %7d ms  %3d%% of one core, %d threads, %s cores\n", \
               pcpu, 100 * pcpu / wall, nz(v["threads"]), v["cores"]
        printf "  worst single frame-gap       %7d ms off cpu\n", nz(v["worst_off_ms"])

        printf "\n  MAJOR FAULTS - a burst inside one frame IS a hitch\n"
        printf "    main thread            %6d   %5.1f/s\n", nz(v["main_majflt"]), nz(v["main_majflt"])/secs
        printf "    whole process          %6d   %5.1f/s\n", nz(v["proc_majflt"]), nz(v["proc_majflt"])/secs
        printf "    whole system           %6d   %5.1f/s\n", nz(v["sys_majflt"]), nz(v["sys_majflt"])/secs
        printf "    swap-ins               %6d   %5.1f/s  <- faults served from the swapfile\n", \
               nz(v["swapin"]), nz(v["swapin"])/secs
        printf "    swap-outs              %6d   %5.1f/s  = %.1f MB/s written to the card\n", \
               nz(v["swapout"]), nz(v["swapout"])/secs, nz(v["swapout"]) * 4.0 / 1024 / secs
        sm = nz(v["sys_majflt"]); si = nz(v["swapin"])
        if (sm > 0)
            printf "    swap-ins are %d%% of system major faults\n", (si > sm ? 100 : 100 * si / sm)
        printf "    worst burst in one %dms sample   %d faults\n", 1000/hz, nz(v["worst_burst"])
        printf "    samples with 1-9 / 10-29 / 30+ faults   %d / %d / %d\n", \
               nz(v["burst_small"]), nz(v["burst_10"]), nz(v["burst_30"])
        if (topf != "") {
            printf "    bursts of 10+ and the off-cpu ms in the same sample:\n     "
            n = split(topf, b, " ")
            shown = 0
            for (i = 1; i <= n && shown < 14; i++)
                if (b[i] != "") { split(b[i], q, ":"); printf " t%ss:%sf/%sms", q[3], q[1], q[2]; shown++ }
            printf "\n    (t = seconds into the window, so you can tell load from walk)\n"
        }

        printf "\n  MEMORY - direct reclaim is ON-CPU work in whichever thread allocates\n"
        printf "    direct reclaim stalls  %6d   pages scanned in-thread %d\n", \
               nz(v["allocstall"]), nz(v["pgscan_direct"])
        printf "    main thread minor faults %5d\n", nz(v["main_minflt"])
        if (nz(v["rss1_kb"]) == 0 && nz(v["rss0_kb"]) > 0)
            printf "    RSS %s kB at the start; the process was GONE by the final read,\n" \
                   "    so ignore the end-of-window numbers and re-run without quitting.\n", v["rss0_kb"]
        else
            printf "    RSS %s -> %s kB   (%+d MB over the window)\n", \
                   v["rss0_kb"], v["rss1_kb"], (nz(v["rss1_kb"]) - nz(v["rss0_kb"])) / 1024
        printf "    swappiness %s -> %s   min_free_kbytes %s   swap mounted at start: %s\n", \
               v["swappiness0"], v["swappiness"], v["min_free_kbytes"], \
               (nz(v["swapon0"]) > 0 ? "yes" : "no")
        if (v["swappiness0"] != v["swappiness"])
            printf "    *** swappiness CHANGED mid-window (%s -> %s) - something rewrote it,\n" \
                   "        most likely the launcher. This arm is NOT valid. ***\n", \
                   v["swappiness0"], v["swappiness"]
        printf "    MemAvailable %d -> low water %d -> %d MB\n", \
               nz(v["memavail0_kb"])/1024, nz(v["memavail_low_kb"])/1024, nz(v["memavail1_kb"])/1024
        printf "    swap used %d -> %d MB of %d MB\n", \
               nz(v["swap_used0_kb"])/1024, nz(v["swap_used1_kb"])/1024, nz(v["swap_total_kb"])/1024
        if (nz(v["oom_kills"]) > 0)
            printf "    *** %d OOM KILL(S) during this window ***\n", nz(v["oom_kills"])
        if (nz(v["proc_cpu_cs"]) == 0 || nz(v["rss1_kb"]) == 0)
            print "    *** the process was GONE before the window ended. If you did not\n" \
                  "        quit it yourself, it was killed - and note oom_kill is not in\n" \
                  "        every kernel vmstat, so a 0 there may mean not-measured. ***"
        if (nz(v["skipped"]) > 0)
            printf "    (%d sample(s) discarded - the sampler lost the cpu there)\n", nz(v["skipped"])

        printf "\n  WHAT WAS MEASURABLE ON THIS KERNEL\n"
        printf "    cpu time (main thread + process)  yes\n"
        printf "    major faults, swap, reclaim       yes\n"
        printf "    run-queue wait (preemption)       %s\n", \
               (cap["schedstat"] == "1" ? "yes" : "NO - no CONFIG_SCHEDSTATS, excluded")
        printf "    PSI io/memory stall               %s\n", \
               (cap["psi"] == "1" ? "yes" : "NO - kernel built without PSI, excluded")

        printf "\n  VERDICT\n"
        unexp = off
        if (cap["schedstat"] == "1") unexp -= int(nz(v["runq_ns"]) / 1000000)
        if (unexp < 0) unexp = 0
        if (nz(v["burst_30"]) > 0 || nz(v["worst_burst"]) >= 20)
            printf "  FAULT BURSTS. At least one %dms sample took %d major faults. On eMMC\n" \
                   "  at 1-3 ms per fault that alone is %d-%d ms inside a single sample,\n" \
                   "  which is the size of the hitch. And %d%% of system major faults were\n" \
                   "  swap-ins, so these are pages the game itself owns coming back off the card -\n" \
                   "  not texture files, not sound.\n", \
                   1000/hz, nz(v["worst_burst"]), nz(v["worst_burst"]), nz(v["worst_burst"]) * 3, \
                   (sm > 0 ? (si > sm ? 100 : 100 * si / sm) : 0)
        else if (off > wall * 0.25)
            printf "  OFF CPU %d%% of the window with no fault bursts. On this kernel neither\n" \
                   "  run-queue wait nor PSI is readable, so I cannot split preemption from a\n" \
                   "  blocking call - that split needs a kernel with CONFIG_SCHEDSTATS.\n", \
                   100 * off / wall
        else if (nz(v["allocstall"]) > 20)
            printf "  ON CPU, but doing memory work: %d direct-reclaim stalls and %d pages\n" \
                   "  scanned in-thread. That time is real cpu AND it is memory pressure.\n", \
                   nz(v["allocstall"]), nz(v["pgscan_direct"])
        else
            print "  ON CPU with no fault bursts and little reclaim - this window looks\n" \
                  "  clean. If it did not hitch, that is consistent; try again when it does."

        printf "\n  CPU BY THREAD (10ms resolution)\n"
        for (i = 1; i <= tn; i++) printf "      %-18s %6d ms\n", tname[i], tms[i]
    }
    function nz(x) { return (x == "" || x + 0 < 0) ? 0 : x + 0 }
    ' "$1"
}

# =========================================================== watch ============
if [ "$MODE" = "watch" ]; then
    hr "SAMPLING THE MAIN THREAD FOR ${SECS}s"
    PID="$(r "pidof openmw-0.51 2>/dev/null | tr ' ' '\n' | head -1" | tr -dc '0-9')"
    [ -n "$PID" ] || {
        say "openmw-0.51 is not running. Start it, get to the spot, re-run."
        exit 1
    }
    say "pid $PID.  WALK THE ROUTE - go through the spots that hitch, turn round,"
    say "walk back through them, and keep doing that for the whole window. Standing"
    say "still measures the wrong thing: nothing streams in, nothing gets allocated,"
    say "and the bursts never happen."
    printf '\n'
    upload_sampler
    RES="${TMPDIR:-/tmp}/tsp_watch.$$"
    r "sh /tmp/tsp_sample.sh $PID $SECS" | tee "$RES" | grep -v '^@@\|^[a-z][a-z0-9_]*=\|^[a-zA-Z][a-zA-Z0-9_.-]* [0-9]*$'
    hr "RESULT"
    report "$RES"
    rm -f "$RES"
    printf '\n'
    say "If the fault bursts are there, the next command tests the two kernel"
    say "settings that cause them, and puts them back afterwards:"
    printf '\n      bash ~/Downloads/tsp_hitch.sh vmtest 30\n\n'
    exit 0
fi

# =========================================================== vmtest ===========
if [ "$MODE" = "vmtest" ]; then
    hr "A/B: KERNEL MEMORY SETTINGS, ${SECS}s EACH"
    PID="$(r "pidof openmw-0.51 2>/dev/null | tr ' ' '\n' | head -1" | tr -dc '0-9')"
    [ -n "$PID" ] || {
        say "openmw-0.51 is not running. Start it, get to the spot, re-run."
        exit 1
    }
    OLDSW="$(r "cat /proc/sys/vm/swappiness" | tr -dc '0-9')"
    OLDMF="$(r "cat /proc/sys/vm/min_free_kbytes" | tr -dc '0-9')"
    if [ -z "$OLDSW" ] || [ -z "$OLDMF" ]; then
        say "could not read swappiness / min_free_kbytes - refusing to change them"
        exit 1
    fi
    # If this is interrupted mid-run, the settings must still go back.
    vm_restore() {
        r "echo $OLDSW > /proc/sys/vm/swappiness; echo $OLDMF > /proc/sys/vm/min_free_kbytes" >/dev/null 2>&1
    }
    trap 'printf "\n  interrupted - restoring swappiness=%s min_free_kbytes=%s\n" "$OLDSW" "$OLDMF"; vm_restore; exit 130' INT TERM HUP
    say "pid $PID.  now: swappiness=$OLDSW min_free_kbytes=$OLDMF"
    say "These are per-boot kernel settings. The launcher rewrites them every"
    say "launch, so nothing here is permanent even if this script dies."
    printf '\n'
    upload_sampler

    A="${TMPDIR:-/tmp}/tsp_vm_a.$$"
    B="${TMPDIR:-/tmp}/tsp_vm_b.$$"

    say "--- A: baseline, settings untouched. Walk the route through the spots."
    r "sh /tmp/tsp_sample.sh $PID $SECS" >"$A" 2>&1

    say "--- applying: swappiness=60 min_free_kbytes=32768"
    say "    (60 stops the kernel preferring pages the game owns over file"
    say "     cache; 32768 gives kswapd room to reclaim in the background"
    say "     instead of the frame doing it synchronously)"
    r "echo 60 > /proc/sys/vm/swappiness; echo 32768 > /proc/sys/vm/min_free_kbytes; \
       echo \"    now swappiness=\$(cat /proc/sys/vm/swappiness) min_free_kbytes=\$(cat /proc/sys/vm/min_free_kbytes)\""

    say "--- B: walk the SAME route, same length, same pace."
    r "sh /tmp/tsp_sample.sh $PID $SECS" >"$B" 2>&1

    trap - INT TERM HUP
    say "--- restoring swappiness=$OLDSW min_free_kbytes=$OLDMF"
    r "echo $OLDSW > /proc/sys/vm/swappiness; echo $OLDMF > /proc/sys/vm/min_free_kbytes; \
       echo \"    back to swappiness=\$(cat /proc/sys/vm/swappiness) min_free_kbytes=\$(cat /proc/sys/vm/min_free_kbytes)\""

    hr "A - BASELINE (swappiness=$OLDSW min_free=$OLDMF)"
    report "$A"
    hr "B - CHANGED (swappiness=60 min_free=32768)"
    report "$B"

    hr "SIDE BY SIDE"
    awk -v fa="$A" -v fb="$B" '
    function load(f, o) { while ((getline l < f) > 0) { if (l ~ /^[a-z][a-z0-9_]*=/) { split(l, kv, "="); o[kv[1]] = kv[2] } } close(f) }
    BEGIN {
        load(fa, a); load(fb, b)
        printf "  %-26s %12s %12s %10s\n", "", "A baseline", "B changed", "change"
        n = split("worst_burst burst_30 burst_10 sys_majflt swapin swapout allocstall worst_off_ms main_majflt", ks, " ")
        for (i = 1; i <= n; i++) {
            key = ks[i]; x = a[key] + 0; y = b[key] + 0
            d = (x == 0 ? (y == 0 ? 0 : 100) : 100 * (y - x) / x)
            printf "  %-26s %12d %12d %9.0f%%\n", key, x, y, d
        }
        printf "\n"
        wb = a["worst_burst"] + 0; wb2 = b["worst_burst"] + 0
        s1 = a["swapin"] + 0; s2 = b["swapin"] + 0
        if (wb2 < wb * 0.6 && s2 < s1 * 0.6)
            print "  B is clearly better: both the worst burst and the swap-in rate fell.\n" \
                  "  These two settings are the fix, and they belong in the launcher."
        else if (wb2 > wb * 1.4 || s2 > s1 * 1.4)
            print "  B is worse. Leave the settings alone; the faults are not coming from\n" \
                  "  the reclaim policy, and the next lever is RSS itself."
        else
            print "  No clear difference. Either the window did not contain the hitch, or\n" \
                  "  reclaim policy is not the lever - in which case the RSS itself is, and\n" \
                  "  that means TSP_NO_LOADPURGE and the texture memory settings."
    }'
    rm -f "$A" "$B"
    printf '\n'
    say "Settings are back to what they were either way - re-read above to confirm."
    exit 0
fi

# ========================================================= firstload =========
# The hitches happen on the FIRST load and the FIRST walk through a spot. Once
# the pages are resident they stop, which is why an in-game A/B was measuring
# nothing: by the time arm B started, arm A had already warmed everything.
#
# So: one arm per GAME LAUNCH, same save, same route, every time.
#
#   firstload base     baseline, nothing touched
#   firstload swappy   swappiness=1, swap still mounted as an OOM backstop
#   firstload noswap   swap off entirely
#   firstload compare  read the three saved runs back and put them side by side
#
# Each arm refuses to run if the game is ALREADY up, clears the swapfile
# backlog while nothing is loaded (which is the only time that is free), applies
# its setting, then waits for you to launch. The instant openmw appears it
# RE-APPLIES the setting - because the launcher writes TSP_SWAPPINESS itself at
# startup and would otherwise stamp on the arm - and starts sampling straight
# away, so the load screen and the first walk are both inside the window.
if [ "$MODE" = "firstload" ]; then
    ARM="${2:-base}"
    FSECS="${3:-150}"
    RESDIR="$HOME/Downloads/tsp_firstload"
    mkdir -p "$RESDIR"

    # ---- compare: no device work at all, just read the saved arms back -------
    if [ "$ARM" = "compare" ]; then
        hr "FIRST-LOAD ARMS, SIDE BY SIDE"
        for a in base swappy noswap; do
            [ -s "$RESDIR/$a.txt" ] && printf '  %-8s recorded %s\n' "$a" \
                "$(date -r "$RESDIR/$a.txt" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')" ||
                printf '  %-8s NOT RECORDED YET\n' "$a"
        done
        printf '\n'
        awk -v dir="$RESDIR" '
        function load(f, o) { while ((getline l < f) > 0) if (l ~ /^[a-z][a-z0-9_]*=/) { split(l, kv, "="); o[kv[1]] = kv[2] } close(f) }
        function has(o) { return ("wall_cs" in o) }
        BEGIN {
            load(dir "/base.txt", A); load(dir "/swappy.txt", B); load(dir "/noswap.txt", C)
            printf "  %-22s %11s %11s %11s\n", "", "base", "swappy=1", "no swap"
            n = split("worst_burst burst_30 burst_10 main_majflt sys_majflt swapin swapout allocstall worst_off_ms oom_kills ticks", ks, " ")
            for (i = 1; i <= n; i++) {
                key = ks[i]
                printf "  %-22s %11s %11s %11s\n", key, \
                    (has(A) ? sprintf("%d", A[key]+0) : "-"), \
                    (has(B) ? sprintf("%d", B[key]+0) : "-"), \
                    (has(C) ? sprintf("%d", C[key]+0) : "-")
            }
            printf "  %-22s %11s %11s %11s\n", "memavail_low_MB", \
                (has(A) ? sprintf("%d", (A["memavail_low_kb"]+0)/1024) : "-"), \
                (has(B) ? sprintf("%d", (B["memavail_low_kb"]+0)/1024) : "-"), \
                (has(C) ? sprintf("%d", (C["memavail_low_kb"]+0)/1024) : "-")
            printf "  %-22s %11s %11s %11s\n", "swappiness_held", \
                (has(A) ? (A["swappiness0"] == A["swappiness"] ? "yes" : "NO") : "-"), \
                (has(B) ? (B["swappiness0"] == B["swappiness"] ? "yes" : "NO") : "-"), \
                (has(C) ? (C["swappiness0"] == C["swappiness"] ? "yes" : "NO") : "-")
            printf "\n"
            if (!has(A)) { print "  No baseline yet - run: firstload base"; exit }
            bad = 0
            if (has(B) && B["swappiness0"] != B["swappiness"]) { print "  arm swappy was clobbered mid-window - re-run it."; bad = 1 }
            if (has(C) && C["oom_kills"]+0 > 0) { print "  arm noswap OOM-killed something: the port still needs swap mounted."; bad = 1 }
            if (bad) exit
            wa = A["worst_burst"]+0; sa = A["swapin"]+0
            wb = (has(B) ? B["worst_burst"]+0 : -1); wc = (has(C) ? C["worst_burst"]+0 : -1)
            if (wc >= 0 && wc < wa * 0.5 && (C["memavail_low_kb"]+0) > 81920)
                print "  NO SWAP WINS on first load, and low water stayed above 80 MB.\n" \
                      "  The texture work and the reload fix bought back enough. That is a\n" \
                      "  swapoff in the launcher."
            else if (wb >= 0 && wb < wa * 0.5)
                print "  swappiness=1 gets most of it and keeps swap as an OOM backstop.\n" \
                      "  That is the safer change and it belongs in the launcher."
            else if (wb >= wa * 0.8 && (wc < 0 || wc >= wa * 0.8))
                print "  Swap is NOT the lever - the first-load bursts survived every arm.\n" \
                      "  Then they are file-backed, not anonymous, and the suspects are\n" \
                      "  TSP_NO_LOADPURGE and the 4481 loose KTX files on the card."
            else
                print "  No clear winner. Check the ticks row - if the windows were very\n" \
                      "  different lengths, or one missed the walk, re-run that arm."
        }'
        printf '\n'
        say "Results live in $RESDIR - delete a file to re-record that arm."
        exit 0
    fi

    case "$ARM" in
    base | swappy | noswap) ;;
    *)
        printf '  arm must be base, swappy, noswap or compare\n'
        exit 2
        ;;
    esac

    hr "FIRST-LOAD ARM: $ARM  (${FSECS}s from the moment the game appears)"

    # ---- must NOT already be running -----------------------------------------
    if r "pidof openmw-0.51 >/dev/null 2>&1 && echo up" | grep -q up; then
        say "openmw-0.51 is ALREADY RUNNING. This arm has to start from a cold"
        say "launch or it measures a warm cache and tells us nothing."
        say "Quit the game fully, then run this again."
        exit 1
    fi
    say "game is not running - good, this will be a genuine first load"

    SWLINE="$(r "grep '^/' /proc/swaps | head -1")"
    SWFILE="$(printf '%s' "$SWLINE" | awk '{print $1}')"
    SWPRI="$(printf '%s' "$SWLINE" | awk '{print $NF}')"
    OLDSW="$(r "cat /proc/sys/vm/swappiness" | tr -dc '0-9')"
    if [ -z "$OLDSW" ]; then
        say "could not read swappiness - refusing to touch anything"
        exit 1
    fi
    [ -n "$SWFILE" ] || say "note: no swapfile is mounted right now"
    say "swapfile ${SWFILE:-none}  priority ${SWPRI:-n/a}  swappiness $OLDSW"

    restore_all() {
        r "echo $OLDSW > /proc/sys/vm/swappiness" >/dev/null 2>&1
        if [ -n "$SWFILE" ] && ! r "grep -q '^/' /proc/swaps && echo on" | grep -q on; then
            r "swapon -p $SWPRI '$SWFILE' 2>/dev/null || swapon '$SWFILE'" >/dev/null 2>&1
        fi
    }
    trap 'printf "\n  interrupted - restoring swap and swappiness\n"; restore_all; exit 130' INT TERM HUP

    # ---- identical starting point: clear the backlog while nothing is loaded --
    if [ -n "$SWFILE" ]; then
        hr "CLEARING THE SWAP BACKLOG (free to do with the game closed)"
        r "timeout 180 swapoff -a && (swapon -p $SWPRI '$SWFILE' 2>/dev/null || swapon '$SWFILE'); \
           echo \"    swap used now \$(awk '/^\//{print \$4}' /proc/swaps) kB\""
    fi

    # ---- apply the arm --------------------------------------------------------
    hr "APPLYING ARM: $ARM"
    case "$ARM" in
    base)
        WANTSW="$OLDSW"
        say "nothing changed - swappiness stays $OLDSW, swap stays mounted"
        ;;
    swappy)
        WANTSW=1
        r "echo 1 > /proc/sys/vm/swappiness; echo \"    swappiness now \$(cat /proc/sys/vm/swappiness)\""
        ;;
    noswap)
        WANTSW="$OLDSW"
        MAVAIL="$(r "awk '/^MemAvailable:/{print \$2}' /proc/meminfo" | tr -dc '0-9')"
        say "MemAvailable with the game closed: $(( ${MAVAIL:-0} / 1024 )) MB"
        r "timeout 180 swapoff -a; grep '^/' /proc/swaps || echo '    swap is OFF'"
        if r "grep -q '^/' /proc/swaps && echo still" | grep -q still; then
            say "swapoff did not take - cannot run this arm. Nothing else changed."
            restore_all
            exit 1
        fi
        ;;
    esac

    upload_sampler

    # ---- wait for the launch, then re-apply and sample ------------------------
    hr "LAUNCH THE GAME NOW"
    say "Start Morrowind, load THE SAME save you always use, and walk THE SAME"
    say "route through the spots that hitch. Do not stand still."
    say "I am watching for the process and will start recording the instant it"
    say "appears, so the load screen is inside the window too."
    printf '\n'
    PID=""
    W=0
    while [ $W -lt 300 ]; do
        PID="$(r "pidof openmw-0.51 2>/dev/null | tr ' ' '\n' | head -1" | tr -dc '0-9')"
        [ -n "$PID" ] && break
        W=$((W + 5))
        [ $((W % 20)) -eq 0 ] && printf '    still waiting for the launch (%ss)\n' "$W"
        sleep 5
    done
    if [ -z "$PID" ]; then
        say "no launch within 5 minutes - giving up and restoring."
        restore_all
        exit 1
    fi
    say "openmw-0.51 is pid $PID - recording now"

    # The launcher rewrites swappiness during startup, so stamp the arm back on
    # immediately and let the sampler prove whether it held.
    if [ "$ARM" = "swappy" ]; then
        r "echo 1 > /proc/sys/vm/swappiness; echo \"    re-applied swappiness=\$(cat /proc/sys/vm/swappiness) after launch\""
    elif [ "$ARM" = "noswap" ]; then
        r "swapoff -a 2>/dev/null; grep '^/' /proc/swaps && echo '    WARNING: launcher re-enabled swap' || echo '    swap still off after launch'"
    fi

    RES="$RESDIR/$ARM.txt"
    r "sh /tmp/tsp_sample.sh $PID $FSECS" | tee "$RES" | grep -v '^@@\|^[a-z][a-z0-9_]*=\|^[a-zA-Z][a-zA-Z0-9_.-]* [0-9]*$'

    hr "RESTORING"
    trap - INT TERM HUP
    restore_all
    r "echo '    swappiness now' \$(cat /proc/sys/vm/swappiness); grep '^/' /proc/swaps || echo '    WARNING: swap is still OFF'"

    hr "ARM $ARM"
    report "$RES"
    printf '\n'
    say "saved to $RES"
    printf '\n'
    case "$ARM" in
    base) say "Next, quit the game fully, then:"; printf '\n      bash ~/Downloads/tsp_hitch.sh firstload swappy %s\n\n' "$FSECS";;
    swappy) say "Next, quit the game fully, then:"; printf '\n      bash ~/Downloads/tsp_hitch.sh firstload noswap %s\n\n' "$FSECS";;
    noswap) say "All three recorded. Now:"; printf '\n      bash ~/Downloads/tsp_hitch.sh firstload compare\n\n';;
    esac
    exit 0
fi

# =========================================================== noswap ==========
# Steve idea, tested directly: does the port still need swap at all now that the
# texture work and the reload fix changed the memory picture?
#
# Three arms, same spot, same length, in one run:
#   A  baseline, nothing touched
#   B  swappiness=1 - swap stays mounted as an OOM backstop but the kernel stops
#      reaching for it. This is "no swap" without the cliff, so it is the safe
#      version of the same hypothesis and worth having beside C.
#   C  swapoff entirely - only attempted if the headroom check says it can be
#      done without an OOM kill, because swapoff has to read every swapped page
#      back into RAM before it returns.
# Everything is put back afterwards, including on Ctrl-C.
if [ "$MODE" = "noswap" ]; then
    hr "DOES THE PORT STILL NEED SWAP - 3 ARMS OF ${SECS}s"
    PID="$(r "pidof openmw-0.51 2>/dev/null | tr ' ' '\n' | head -1" | tr -dc '0-9')"
    [ -n "$PID" ] || {
        say "openmw-0.51 is not running. Start it, get to the spot, re-run."
        exit 1
    }

    # ---- record exactly what we are going to have to restore ----------------
    SWLINE="$(r "grep '^/' /proc/swaps | head -1")"
    SWFILE="$(printf '%s' "$SWLINE" | awk '{print $1}')"
    SWPRI="$(printf '%s' "$SWLINE" | awk '{print $NF}')"
    OLDSW="$(r "cat /proc/sys/vm/swappiness" | tr -dc '0-9')"
    if [ -z "$SWFILE" ] || [ -z "$OLDSW" ]; then
        say "could not read /proc/swaps or swappiness - refusing to touch either."
        say "what /proc/swaps gave back: ${SWLINE:-<empty>}"
        exit 1
    fi
    say "swapfile  $SWFILE  priority $SWPRI  swappiness $OLDSW"
    printf '\n'
    say "NO RESTART IS NEEDED - all three arms take effect on the running game."
    say "swappiness is consulted on every reclaim decision, and swapoff forces"
    say "every swapped page back into RAM the moment it runs."
    say ""
    say "BUT DO NOT RELAUNCH THE GAME DURING THIS RUN. The launcher writes"
    say "TSP_SWAPPINESS=$OLDSW at every launch, so a relaunch would silently put"
    say "arm B or C back to baseline and the comparison would be junk."

    restore_all() {
        r "echo $OLDSW > /proc/sys/vm/swappiness" >/dev/null 2>&1
        if ! r "grep -q '^/' /proc/swaps && echo on" | grep -q on; then
            r "swapon -p $SWPRI '$SWFILE' 2>/dev/null || swapon '$SWFILE'" >/dev/null 2>&1
        fi
    }
    trap 'printf "\n  interrupted - putting swap and swappiness back\n"; restore_all; r "grep \"^/\" /proc/swaps; cat /proc/sys/vm/swappiness"; exit 130' INT TERM HUP

    # ---- headroom check: is arm C even survivable ---------------------------
    hr "HEADROOM - can swapoff be done without an OOM kill"
    HR="$(r "awk '/^MemAvailable:/{a=\$2} /^MemFree:/{f=\$2} END{print a\" \"f}' /proc/meminfo;             awk '/^\//{print \$4}' /proc/swaps")"
    MAVAIL="$(printf '%s' "$HR" | sed -n 1p | awk '{print $1}')"
    SWUSED="$(printf '%s' "$HR" | sed -n 2p | tr -dc '0-9')"
    MAVAIL="$(printf '%s' "$MAVAIL" | tr -dc '0-9')"
    [ -n "$MAVAIL" ] || MAVAIL=0
    [ -n "$SWUSED" ] || SWUSED=0
    say "MemAvailable now $((MAVAIL / 1024)) MB, swap in use $((SWUSED / 1024)) MB"
    SAFEC=1
    if [ "$SWUSED" -eq 0 ]; then
        say "nothing is swapped out right now, so swapoff is free - arm C will run"
    elif [ $((MAVAIL - SWUSED)) -lt 81920 ]; then
        SAFEC=0
        say "swapoff would need to pull $((SWUSED / 1024)) MB back into RAM and would"
        say "leave under 80 MB spare. That is an OOM kill, not an experiment."
        say "Arm C is SKIPPED. Arm B (swappiness=1) tests the same idea safely."
    else
        say "swapoff leaves $(((MAVAIL - SWUSED) / 1024)) MB spare - arm C will run"
    fi

    # ---- your option A, checked properly --------------------------------------
    # Swap cannot hold game FILES. It only ever holds anonymous memory - heap,
    # allocations, the scene graph. File data lives in the page cache and is
    # dropped straight back to its source file, never written to swap. So a
    # bigger swapfile does not reserve room for assets; it gives the kernel MORE
    # room to push the game out, which is the opposite of what you want.
    #
    # What DOES do what you meant - keep the pages the game needs resident and
    # let everything else be reclaimed - is a cgroup memory floor. Probe for it
    # here so we know whether that option is even open before spending a session
    # on it.
    hr "OPTION A - is a memory floor for the game available on this kernel"
    rin <<'CGEOF'
if [ -d /sys/fs/cgroup ]; then
    if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
        echo "  cgroup v2 mounted. controllers: $(cat /sys/fs/cgroup/cgroup.controllers)"
        case "$(cat /sys/fs/cgroup/cgroup.controllers)" in
            *memory*) echo "  MEMORY CONTROLLER: yes -> memory.min is available."
                      echo "  That means we can give the game a hard floor the kernel may not"
                      echo "  reclaim below, e.g. 600M, and let it evict everything else first."
                      echo "  This is the real version of your keep-what-it-needs-resident idea.";;
            *) echo "  MEMORY CONTROLLER: NO - v2 is mounted but memory is not enabled,";
               echo "  so memory.min cannot be set. Arms B and C below are the only levers.";;
        esac
    elif [ -d /sys/fs/cgroup/memory ]; then
        echo "  cgroup v1 with a memory controller."
        echo "  v1 has soft_limit_in_bytes but no hard floor, and no memory.min."
        echo "  It can cap the game but it cannot protect it. Arms B and C are the levers."
    else
        echo "  /sys/fs/cgroup exists but neither v2 controllers nor v1 memory found."
    fi
else
    echo "  no /sys/fs/cgroup at all - no memory floor is possible on this kernel."
    echo "  Arms B and C below are the only two levers we have."
fi
echo "  --- and the reason a bigger swapfile is not one of the options:"
grep -e ^SwapTotal: -e ^SwapFree: -e ^AnonPages: -e ^Mapped: -e ^Cached: -e ^Shmem: /proc/meminfo
echo "    AnonPages is what swap can hold. Cached/Mapped is file data, which swap"
echo "    never touches - it goes back to the .bsa and .ktx files on the card."
CGEOF

    upload_sampler
    A="${TMPDIR:-/tmp}/tsp_ns_a.$$"
    B="${TMPDIR:-/tmp}/tsp_ns_b.$$"
    C="${TMPDIR:-/tmp}/tsp_ns_c.$$"
    : >"$C"

    hr "ARM A - baseline. WALK the route through the hitchy spots, back and forth"
    r "sh /tmp/tsp_sample.sh $PID $SECS" >"$A" 2>&1
    grep -c . "$A" >/dev/null && say "arm A done"

    hr "ARM B - swappiness=1, swap still mounted"
    r "echo 1 > /proc/sys/vm/swappiness; echo \"    swappiness now \$(cat /proc/sys/vm/swappiness)\""
    # Fairness: arm A leaves pages sitting on the card, and walking in arm B
    # would fault those back in and be charged for them - while arm C gets a
    # clean slate for free, because swapoff has to pull everything back anyway.
    # So give B the same clean slate: cycle the swapfile off and on once.
    if [ "$SAFEC" = 1 ]; then
        say "clearing the swap backlog first so B and C start from the same place"
        r "timeout 180 swapoff -a && (swapon -p $SWPRI '$SWFILE' 2>/dev/null || swapon '$SWFILE') && \
           echo \"    backlog cleared, swap back on, used now \$(awk '/^\//{print \$4}' /proc/swaps) kB\"" ||
            say "    backlog clear failed - B carries A leftovers, see swap_used_start below"
    else
        say "skipping the backlog clear - not enough headroom to cycle the swapfile."
        say "    B therefore inherits what A left swapped out and is biased WORSE."
    fi
    r "sh /tmp/tsp_sample.sh $PID $SECS" >"$B" 2>&1
    say "arm B done"

    if [ "$SAFEC" = 1 ]; then
        hr "ARM C - swap off completely"
        say "swapoff has to read $((SWUSED / 1024)) MB back off the card first; this"
        say "can take a while and the game may stutter hard during it. Waiting..."
        r "timeout 180 swapoff -a; echo \"    /proc/swaps now:\"; grep '^/' /proc/swaps || echo '      (empty - swap is OFF)'"
        if r "grep -q '^/' /proc/swaps && echo still" | grep -q still; then
            say "swapoff did not complete - swap is still on. Arm C is not valid."
            : >"$C"
        else
            r "sh /tmp/tsp_sample.sh $PID $SECS" >"$C" 2>&1
            say "arm C done"
        fi
    fi

    hr "RESTORING"
    trap - INT TERM HUP
    restore_all
    r "echo '    swappiness now' \$(cat /proc/sys/vm/swappiness); grep '^/' /proc/swaps || echo '    WARNING: swap is still OFF'"

    hr "A - BASELINE"
    report "$A"
    hr "B - SWAPPINESS 1"
    report "$B"
    if [ -s "$C" ]; then
        hr "C - NO SWAP AT ALL"
        report "$C"
    fi

    hr "SIDE BY SIDE"
    awk -v fa="$A" -v fb="$B" -v fc="$C" '
    function load(f, o) { while ((getline l < f) > 0) if (l ~ /^[a-z][a-z0-9_]*=/) { split(l, kv, "="); o[kv[1]] = kv[2] } close(f) }
    BEGIN {
        load(fa, a); load(fb, b); hasc = (fc != ""); if (hasc) load(fc, c)
        if (!(("wall_cs" in c))) hasc = 0
        printf "  %-22s %11s %11s %11s\n", "", "A baseline", "B swappy=1", (hasc ? "C no swap" : "C skipped")
        n = split("worst_burst burst_30 burst_10 main_majflt sys_majflt swapin swapout allocstall worst_off_ms oom_kills", ks, " ")
        for (i = 1; i <= n; i++) {
            key = ks[i]
            printf "  %-22s %11d %11d %11s\n", key, a[key] + 0, b[key] + 0, (hasc ? sprintf("%d", c[key] + 0) : "-")
        }
        printf "  %-22s %11d %11d %11s\n", "memavail_low_MB", (a["memavail_low_kb"]+0)/1024, \
               (b["memavail_low_kb"]+0)/1024, (hasc ? sprintf("%d", (c["memavail_low_kb"]+0)/1024) : "-")
        printf "  %-22s %11d %11d %11s\n", "swap_used_start_MB", (a["swap_used0_kb"]+0)/1024, \
               (b["swap_used0_kb"]+0)/1024, (hasc ? sprintf("%d", (c["swap_used0_kb"]+0)/1024) : "-")
        printf "  %-22s %11d %11d %11s\n", "swap_used_end_MB", (a["swap_used1_kb"]+0)/1024, \
               (b["swap_used1_kb"]+0)/1024, (hasc ? sprintf("%d", (c["swap_used1_kb"]+0)/1024) : "-")
        if ((a["swap_used0_kb"]+0) > 0 && (b["swap_used0_kb"]+0) > (a["swap_used0_kb"]+0) / 2)
            print "\n  NOTE: arm B started with pages already on the card, so some of its\n" \
                  "  faults are arm A leftovers being read back. Read B as a floor on how\n" \
                  "  good swappiness=1 is, not a ceiling."
        printf "\n"
        wa = a["worst_burst"] + 0; wb = b["worst_burst"] + 0
        sa = a["swapin"] + 0; sb = b["swapin"] + 0
        adead = ((a["proc_cpu_cs"] + 0) == 0 || (a["rss1_kb"] + 0) == 0)
        bdead = ((b["proc_cpu_cs"] + 0) == 0 || (b["rss1_kb"] + 0) == 0)
        cdead = (hasc && ((c["proc_cpu_cs"] + 0) == 0 || (c["rss1_kb"] + 0) == 0))
        if (adead || bdead || cdead) {
            printf "\n  ARM(S) INVALID - the game was gone by the end of:%s%s%s\n", \
                   (adead ? " A" : ""), (bdead ? " B" : ""), (cdead ? " C" : "")
            print "  A window the process did not survive is not a data point: its fault"
            print "  counters stop where the process died and its swap numbers include the"
            print "  teardown. No verdict from this run - see the note below."
            exit
        }
        if (hasc && (c["oom_kills"] + 0) > 0)
            print "  Arm C OOM-killed something. The port does still need swap as a\n" \
                  "  backstop - but arm B is the usable half of your idea: keep it\n" \
                  "  mounted, stop the kernel using it."
        else if (hasc && (c["worst_burst"] + 0) < wa * 0.5 && (c["memavail_low_kb"] + 0) > 81920)
            print "  NO SWAP WINS and it never got close to running out - low water was\n" \
                  "  still over 80 MB. The texture work and the reload fix did buy back\n" \
                  "  enough. swapoff belongs in the launcher."
        else if (wb < wa * 0.5 && sb < sa * 0.5)
            print "  swappiness=1 gets most of it without the OOM risk. That is the\n" \
                  "  change worth making permanent."
        else if (wb >= wa * 0.8 && (!hasc || (c["worst_burst"] + 0) >= wa * 0.8))
            print "  Swap is NOT the lever - the bursts survived both arms. Then the\n" \
                  "  faults are file-backed, not anonymous, and the next suspects are\n" \
                  "  TSP_NO_LOADPURGE and the 4481 loose KTX files."
        else
            print "  Mixed. Re-run at the same spot before deciding - one window per arm\n" \
                  "  is thin, and the spot has to actually hitch during all three."
    }'
    rm -f "$A" "$B" "$C"
    printf '\n'
    say "TO MAKE A WINNER STICK you do need a relaunch, because the launcher"
    say "rewrites both at every launch - that is a one-line launcher edit, and it"
    say "is the only part of this that needs the game restarted."
    printf '\n'
    say "Swap and swappiness are back as they were - the RESTORING block above"
    say "prints what the device actually has now. The launcher rewrites both at"
    say "every launch anyway, so nothing here survives a restart."
    exit 0
fi

# ============================================================ dump ============
mkdir -p "$HOME/Downloads"
: >"$OUT"
printf 'TSP hitch dump  %s\ndevice %s\n' "$STAMP" "$DEV" >"$OUT"
printf '\n########## COLLECTING (read-only) ##########\n'

sec "PROCESS / CORES / KERNEL CAPABILITIES"
rin >>"$OUT" <<'CEOF'
pidof openmw-0.51 >/dev/null 2>&1 && echo "game IS running" || echo "game is not running"
echo "--- cores: present vs online (v1 reported nproc=3 with 8 cpufreq nodes)"
for f in present online offline possible; do
    [ -r /sys/devices/system/cpu/$f ] && echo "  $f = $(cat /sys/devices/system/cpu/$f)"
done
echo "  /proc/cpuinfo processors = $(grep -c ^processor /proc/cpuinfo)"
echo "--- what the kernel will let us measure"
P="$(pidof openmw-0.51 2>/dev/null | tr ' ' '\n' | head -1)"
if [ -n "$P" ]; then
    [ -r "/proc/$P/task/$P/schedstat" ] && echo "  schedstat: yes" || echo "  schedstat: NO (no CONFIG_SCHEDSTATS)"
else
    echo "  schedstat: cannot tell, game not running"
fi
[ -r /proc/pressure/memory ] && echo "  PSI: yes" || echo "  PSI: NO"
[ -r /proc/vmstat ] && echo "  vmstat: yes" || echo "  vmstat: NO"
CEOF

sec "settings.cfg - found by search, not by a guessed path"
rin >>"$OUT" <<SEOF
for c in '$GAMEDIR/config-0.51/settings.cfg' '$GAMEDIR/config/settings.cfg' \
         '$GAMEDIR/settings.cfg' /root/.config/openmw/settings.cfg; do
    [ -f "\$c" ] && { echo "=== \$c"; cat "\$c"; }
done
echo "--- any other settings.cfg under the gamedir (bounded depth, never the whole card)"
find '$GAMEDIR' -maxdepth 3 -name 'settings.cfg' 2>/dev/null
SEOF

sec "LAUNCHER: the memory and texture settings that decide RSS"
r "grep -n -e 'TSP_NO_LOADPURGE' -e 'TSP_RELOAD_MEM_FLOOR_KB' -e 'TSP_SWAPPINESS' \
      -e 'LIBGL_SHRINK' -e 'LIBGL_AVOID16BITS' -e 'LIBGL_MIPMAP' -e 'TSP_TEXTURE_SHRINK' \
      -e 'min_free_kbytes' -e 'swapfile' '$LAUNCHER' | head -60" >>"$OUT"

sec "KERNEL: io, memory, cpu"
rin >>"$OUT" <<'KEOF'
for q in /sys/block/mmcblk0/queue /sys/block/mmcblk1/queue; do
    [ -d "$q" ] && echo "$q read_ahead_kb=$(cat $q/read_ahead_kb) nr_requests=$(cat $q/nr_requests)"
done
cat /proc/swaps
echo "swappiness=$(cat /proc/sys/vm/swappiness)  vfs_cache_pressure=$(cat /proc/sys/vm/vfs_cache_pressure)  min_free_kbytes=$(cat /proc/sys/vm/min_free_kbytes)"
echo "watermark_scale_factor=$(cat /proc/sys/vm/watermark_scale_factor 2>/dev/null)"
echo "loadavg=$(cat /proc/loadavg)"
grep -e ^MemTotal -e ^MemFree -e ^MemAvailable -e ^Cached -e ^SwapCached -e ^SwapFree -e ^AnonPages -e ^Shmem /proc/meminfo
grep -e ^pswpin -e ^pswpout -e ^pgmajfault -e ^allocstall -e ^pgscan_direct -e ^pgsteal_direct -e ^compact_stall /proc/vmstat
for g in /sys/class/devfreq/*/; do
    [ -d "$g" ] && echo "$g cur=$(cat $g/cur_freq 2>/dev/null) gov=$(cat $g/governor 2>/dev/null) max=$(cat $g/max_freq 2>/dev/null)"
done
KEOF

sec "LOG: the worst frames, with what else was in them"
rin >>"$OUT" <<LEOF
L='$GAMEDIR/openmw_log.txt'
[ -f "\$L" ] || { echo "no log"; exit 0; }
echo "log lines: \$(wc -l < "\$L")"
for m in TSP_SOUNDPHASE_V1 TSP_SOUNDSLOW_V1 TSP_MEMGATE_V1 TSP_LOAD_TRACE TSP_WARMDRAW \
         TSP_DYNVIEW TSP_VISGRID OcclusionCull 'stall_seen' 'Loading content file'; do
    printf '  %-24s %s\n' "\$m" "\$(grep -c "\$m" "\$L")"
done
echo "--- every dynamic-view stall the lua side saw"
grep -n 'stall_seen' "\$L" | tail -25
echo "--- fps reports"
grep -o 'raw_fps=[0-9.]* smooth_fps=[0-9.]*' "\$L" | tail -20
LEOF

sec "SOURCE: the purge that TSP_NO_LOADPURGE disables"
d "cd '$SRC' && grep -n -B4 -A8 'TSP_NO_LOADPURGE' apps/openmw/mwworld/scene.cpp | head -50" >>"$OUT"

printf '\n########## SUMMARY ##########\n'
both "full dump: $OUT  ($(wc -l <"$OUT") lines)"
printf '\n'
both "cores present vs online:"
grep -n -e ' present = ' -e ' online = ' -e 'processors = ' "$OUT" | sed 's/^/    /'
printf '\n'
both "the RSS levers, as the launcher actually sets them:"
grep -n -e 'TSP_NO_LOADPURGE=' -e 'RELOAD_MEM_FLOOR_KB=' -e 'LIBGL_SHRINK=' \
        -e 'LIBGL_AVOID16BITS=' -e 'TSP_TEXTURE_SHRINK=' "$OUT" | head -12 | sed 's/^/    /'
printf '\n'
say "Then, at the hitchy spot with the game running:"
printf '\n      bash ~/Downloads/tsp_hitch.sh watch 40\n\n'
