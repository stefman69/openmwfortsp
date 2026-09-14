#!/bin/sh
# tsp_drawthread_v1.sh - TSP_DRAWTHREAD_V1: OSG draw traversal on its own thread, on its own fast core.
# Launcher-only (Roms/PORTS/Morrowind.sh), no rebuild. POSIX sh on the host VM (bob-simpson). Modes:
#   sh ~/Downloads/tsp_drawthread_v1.sh            apply on every card         (the one command)
#   sh ~/Downloads/tsp_drawthread_v1.sh check      after a play session: armed/core/pin/sample proof lines per card
#                                                  (openmw_log.txt + tsp_prog.txt), plus a live per-thread table if the game is up
#   sh ~/Downloads/tsp_drawthread_v1.sh single     A/B: next launch on each card = SingleThreaded (model=single in the policy file)
#   sh ~/Downloads/tsp_drawthread_v1.sh draw       A/B: next launch on each card = DrawThreadPerContext
#   sh ~/Downloads/tsp_drawthread_v1.sh revert     put back the launcher each card had before V1
# Cards come from ~/.tsp_hosts (name<TAB>host); TSP=<host> in the environment limits it to one card.
#
# What it changes in Morrowind.sh (four anchored inserts, marker TSP_DRAWTHREAD_V1):
#  MODEL  replaces  export OSG_THREADING=SingleThreaded  (update+cull+draw serialised on ONE core) with
#         DrawThreadPerContext, the upstream desktop default OpenMW is built for: draw of frame N runs on a
#         second core while the main thread does update+cull of frame N+1.
#  CORE   the draw thread is as hot as the main thread, so it needs a fast core of its own. On the S CrossMix
#         leaves cpu5-7 offline (only cpu4 of the 2.16 GHz tier is up): bring the next core of the tier online
#         for the run, BEFORE TSP_CPU_OPTIMIZE_V2 enumerates so its masks include it. Put back on exit.
#  KEEPER after launch: main thread stays on the core TSP_CPU_OPTIMIZE_V2 gives it; the hottest non-main
#         thread (= the OSG draw thread once the world is up) is pinned to the draw core and every other thread
#         kept off it, re-checked every 5s (tsp_cpu_apply_split scatters them at 8/25/60s, and OSG re-creates
#         the thread with an all-CPU mask on settings changes). Sample line every 60s.
#  CLOCK  TSP_CPUCLOCK_V1, after the governor boost: lift scaling_max_freq to cpuinfo_max_freq on every online
#         core (the probe read the A133 at a flat 1.2 GHz of a 2.0 GHz ceiling with governor=performance), enable
#         the cpufreq boost knob if present, log the cooling-device state. Saved and restored on exit.
#  CLEAN  cleanup_children also puts the onlined core back and restores the clock cap (signal path).
# Policy file $GAMEDIR/tsp_drawthread_policy.txt (no file = defaults): model=single | core=off | pin=off | idle=main | clock=off
#   idle=main parks SCHED_IDLE threads (OpenMW's navmesh updater) on the main thread's core so they only ever get its
#   leftover cycles instead of a whole core. Off by default: a starved navmesh updater is the hitching you just fixed.
# Sample line fields: khz=main:/draw: core clocks, temp=hottest zone, /IDLE marks SCHED_IDLE threads, wait main=/draw=
#   R,S,D counts out of 20 samples plus the two commonest kernel wait channels (futex = waiting on the other thread,
#   a pvr/mali/fence/poll symbol = waiting on the GPU, nanosleep/hrtimer = a limiter).

MODE="${1:-all}"
STAMP=$(date +%Y%m%d-%H%M%S)
DL="$HOME/Downloads"
BK="$DL/tsp_drawthread_backups"
MARK=TSP_DRAWTHREAD_V1
SSH="${TSP_SSH:-ssh -o ConnectTimeout=10}"
mkdir -p "$DL" "$BK"

say() { printf '%s\n' "$*"; }
hdr() { say ""; say "########## $* ##########"; }
die() { say "  !! $*"; exit 1; }

# ---------------------------------------------------------------- card list
hosts() {
    if [ -n "$TSP" ]; then
        printf '%s\t%s\n' "${TSP_NAME:-tsp?}" "$TSP"; return
    fi
    if [ -f "$HOME/.tsp_hosts" ]; then
        grep -v '^[[:space:]]*#' "$HOME/.tsp_hosts" | awk 'NF>=2 {print $1 "\t" $2}'
        return
    fi
    say "  !! ~/.tsp_hosts not found - falling back to the two known cards" >&2
    printf 'tsps\t192.168.1.12\ntsp\t192.168.1.21\n'
}
sshhost() { case "$1" in *@*) printf '%s' "$1";; *) printf 'root@%s' "$1";; esac; }

# ---------------------------------------------------------------- remote: locate launcher + game dir (sourced by every mode)
REMOTE_COMMON='
L=""
for c in /mnt/sdcard/mmcblk1p1/Roms/PORTS/Morrowind.sh /mnt/SDCARD/Roms/PORTS/Morrowind.sh; do
    [ -f "$c" ] && { L="$c"; break; }
done
[ -n "$L" ] || { echo "  !! no Morrowind.sh in /mnt/sdcard/mmcblk1p1/Roms/PORTS - nothing done"; exit 1; }
GAMEDIR=$(sed -n "s/^GAMEDIR=\"\(.*\)\"[[:space:]]*$/\1/p" "$L" | head -1)
[ -n "$GAMEDIR" ] || GAMEDIR=/mnt/SDCARD/data/ports/openmw
PROG=/mnt/SDCARD/tsp_prog.txt
POL="$GAMEDIR/tsp_drawthread_policy.txt"
NCPU=$(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | wc -l)
find_pid() {
    for p in /proc/[0-9]*; do
        case "$(readlink "$p/exe" 2>/dev/null)" in *openmw-0.51*) echo "${p##*/}"; return 0;; esac
    done
    return 1
}
# per-thread CPU over a 10s window: "tid pct lastcpu allowed"
thread_sample() {
    P=$1; S0=/tmp/tsp_dt0.$$; S1=/tmp/tsp_dt1.$$
    snap() { for t in /proc/$P/task/[0-9]*; do s=$(cat "$t/stat" 2>/dev/null) || continue; r="${s##*) }"; set -- $r; echo "${t##*/} $(( ${12} + ${13} )) ${37} $(grep Cpus_allowed_list "$t/status" 2>/dev/null | cut -f2)"; done; }
    snap > $S0; sleep 10; snap > $S1
    awk -v main="$P" '"'"'NR==FNR { t0[$1]=$2; next } ($1 in t0) { d=($2-t0[$1])/10.0; printf "%6s %6.1f%%  cpu=%-2s allowed=%-5s %s\n", $1, d, $3, $4, ($1==main ? "<- main" : "") }'"'"' $S0 $S1 | sort -k2 -rn | head -8
    awk '"'"'NR==FNR { t0[$1]=$2; next } ($1 in t0) { d=($2-t0[$1])/10.0; if (d>=20) n++; tot+=d } END { printf "  hot(>=20%%)=%d total=%.0f%%\n", n, tot }'"'"' $S0 $S1
    rm -f $S0 $S1
}
'

# ---------------------------------------------------------------- the launcher patcher (awk, runs on the card)
write_patcher() {
cat > "$1" <<'EOF_AWK'
# TSP_DRAWTHREAD_V1 launcher patcher. Input: the current Roms/PORTS/Morrowind.sh (must not carry the marker yet).
BEGIN { model = 0; core = 0; pid = 0; clean = 0; clock = 0 }
/TSP_DRAWTHREAD_V1/ { print "TSP_DRAWTHREAD_V1 PATCH REFUSED: launcher already carries the marker" > "/dev/stderr"; exit 4 }
{ line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line) }
line == "export OSG_THREADING=SingleThreaded" && model == 0 {
    model = 1
    print "# >>> TSP_DRAWTHREAD_V1 MODEL BEGIN (was: export OSG_THREADING=SingleThreaded)"
    print "# OSG draw traversal on its own thread - upstream OpenMW desktop default; SingleThreaded serialised"
    print "# update+cull+draw on one core. Policy $GAMEDIR/tsp_drawthread_policy.txt: model=single = old model,"
    print "# core=off = do not bring a second fast core online, pin=off = leave thread placement alone,"
    print "# idle=main = park SCHED_IDLE threads (navmesh updater) on the main core so they only get its leftover cycles."
    print "if grep -qs '^model=single' \"$GAMEDIR/tsp_drawthread_policy.txt\"; then"
    print "    export OSG_THREADING=SingleThreaded"
    print "else"
    print "    export OSG_THREADING=DrawThreadPerContext"
    print "fi"
    print "echo \"TSP_DRAWTHREAD_V1 model=$OSG_THREADING policy=[$(cat \"$GAMEDIR/tsp_drawthread_policy.txt\" 2>/dev/null | tr '\\n' ' ')]\""
    print "# <<< TSP_DRAWTHREAD_V1 MODEL END"
    next
}
line == "tsp_cpu_governor_restore 2>/dev/null || true" && clean == 0 {
    clean = 1
    print
    print "    [ -n \"${TSP_DRAW_ONLINED:-}\" ] && { echo 0 > \"$TSP_SYS_CPU/cpu$TSP_DRAW_ONLINED/online\" 2>/dev/null; echo \"TSP_DRAWTHREAD_V1 cpu$TSP_DRAW_ONLINED back offline (signal path)\"; }   # TSP_DRAWTHREAD_V1 CLEAN"
    print "    tsp_cpuclock_restore 2>/dev/null || true   # TSP_CPUCLOCK_V1 CLEAN"
    next
}
line == "tsp_cpu_governor_boost" && clock == 0 {
    clock = 1
    print
    print "# >>> TSP_CPUCLOCK_V1 BEGIN"
    print "# tsp_gpuprobe read every A133 core at 1,200,000 kHz for a whole run with the governor already on"
    print "# performance; the silicon ceiling (cpuinfo_max_freq) is 2,000,000. Lift scaling_max_freq to the ceiling on"
    print "# every online core (saved, put back on exit), enable the cpufreq boost knob where the driver has one, and log"
    print "# the cooling-device state so a thermally throttled run is recognisable from the log alone."
    print "# clock=off in $GAMEDIR/tsp_drawthread_policy.txt skips it. Cores already at their ceiling are left alone."
    print "TSP_CLOCK_SAVE=/tmp/tsp-maxfreq.saved"
    print "tsp_cpuclock_restore() {"
    print "    [ -r \"$TSP_CLOCK_SAVE\" ] || return 0"
    print "    while read -r _n _v; do"
    print "        [ -n \"$_n\" ] || continue"
    print "        if [ \"$_n\" = boost ]; then echo \"$_v\" > \"$TSP_SYS_CPU/cpufreq/boost\" 2>/dev/null; else echo \"$_v\" > \"$TSP_SYS_CPU/cpu$_n/cpufreq/scaling_max_freq\" 2>/dev/null; fi"
    print "    done < \"$TSP_CLOCK_SAVE\""
    print "    rm -f \"$TSP_CLOCK_SAVE\"; echo \"TSP_CPUCLOCK_V1 restored\""
    print "}"
    print "if grep -qs '^clock=off' \"$GAMEDIR/tsp_drawthread_policy.txt\"; then"
    print "    echo \"TSP_CPUCLOCK_V1 off (policy)\" | tee -a /mnt/SDCARD/tsp_prog.txt"
    print "else"
    print "    : > \"$TSP_CLOCK_SAVE\"; _cl=\"\""
    print "    for _d in \"$TSP_SYS_CPU\"/cpu[0-9]*; do"
    print "        _n=${_d##*/cpu}; case \"$_n\" in ''|*[!0-9]*) continue ;; esac"
    print "        [ -r \"$_d/cpufreq/scaling_max_freq\" ] || continue"
    print "        _on=1; [ -r \"$_d/online\" ] && read -r _on < \"$_d/online\"; [ \"$_on\" = 1 ] || continue"
    print "        read -r _smax < \"$_d/cpufreq/scaling_max_freq\"; _hmax=0; [ -r \"$_d/cpufreq/cpuinfo_max_freq\" ] && read -r _hmax < \"$_d/cpufreq/cpuinfo_max_freq\""
    print "        if [ \"$_smax\" -lt \"$_hmax\" ] 2>/dev/null; then"
    print "            echo \"$_n $_smax\" >> \"$TSP_CLOCK_SAVE\""
    print "            if echo \"$_hmax\" > \"$_d/cpufreq/scaling_max_freq\" 2>/dev/null; then _cl=\"$_cl cpu$_n:$_smax->$(cat \"$_d/cpufreq/scaling_max_freq\" 2>/dev/null)\"; else _cl=\"$_cl cpu$_n:$_smax->REFUSED\"; fi"
    print "        else"
    print "            _cl=\"$_cl cpu$_n:$_smax=ceiling\""
    print "        fi"
    print "    done"
    print "    if [ -w \"$TSP_SYS_CPU/cpufreq/boost\" ]; then _b0=$(cat \"$TSP_SYS_CPU/cpufreq/boost\" 2>/dev/null); [ \"$_b0\" = 1 ] || { echo \"boost $_b0\" >> \"$TSP_CLOCK_SAVE\"; echo 1 > \"$TSP_SYS_CPU/cpufreq/boost\" 2>/dev/null; }; _cl=\"$_cl boost:$_b0->$(cat \"$TSP_SYS_CPU/cpufreq/boost\" 2>/dev/null)\"; fi"
    print "    _cool=\"\"; for _c in /sys/class/thermal/cooling_device*; do [ -r \"$_c/type\" ] || continue; _ct=$(cat \"$_c/type\"); case \"$_ct\" in *cpu*|*cluster*) _cool=\"$_cool $_ct:$(cat \"$_c/cur_state\" 2>/dev/null)/$(cat \"$_c/max_state\" 2>/dev/null)\";; esac; done"
    print "    echo \"TSP_CPUCLOCK_V1 armed$_cl avail=[$(cat \"$TSP_SYS_CPU/cpu0/cpufreq/scaling_available_frequencies\" 2>/dev/null | tr -s ' ' ',')] cooling=[$_cool] temp=$(for _z in /sys/class/thermal/thermal_zone*/temp; do cat \"$_z\" 2>/dev/null; done | sort -n | tail -1)\" | tee -a /mnt/SDCARD/tsp_prog.txt"
    print "fi"
    print "# <<< TSP_CPUCLOCK_V1 END"
    next
}
line == "tsp_cpu_optimize" && core == 0 {
    core = 1
    print "# >>> TSP_DRAWTHREAD_V1 CORE BEGIN"
    print "# With DrawThreadPerContext the OSG draw thread is as hot as the main thread and needs a fast core of its"
    print "# own. On the S CrossMix leaves cpu5-7 offline, so only cpu4 of the 2.16 GHz tier exists to the scheduler:"
    print "# bring the next core of that tier online for the run (put back on exit) BEFORE TSP_CPU_OPTIMIZE_V2"
    print "# enumerates, so its masks include it. A 4-core card already has a second core in the tier."
    print "TSP_SYS_CPU=\"${TSP_SYS_CPU:-/sys/devices/system/cpu}\""
    print "TSP_DRAW_CPU=\"\"; TSP_DRAW_ONLINED=\"\"; TSP_MAIN_GUESS=\"\""
    print "if [ \"$OSG_THREADING\" = DrawThreadPerContext ] && ! grep -qs '^core=off' \"$GAMEDIR/tsp_drawthread_policy.txt\"; then"
    print "    _best=0; _tier=\"\""
    print "    for _d in \"$TSP_SYS_CPU\"/cpu[0-9]*; do"
    print "        _n=${_d##*/cpu}; case \"$_n\" in ''|*[!0-9]*) continue ;; esac"
    print "        _k=0; [ -r \"$_d/cpufreq/cpuinfo_max_freq\" ] && read -r _k < \"$_d/cpufreq/cpuinfo_max_freq\""
    print "        case \"$_k\" in ''|*[!0-9]*) _k=0 ;; esac"
    print "        if [ \"$_k\" -gt \"$_best\" ]; then _best=$_k; _tier=$_n"
    print "        elif [ \"$_k\" -eq \"$_best\" ]; then _tier=\"$_tier $_n\"; fi"
    print "    done"
    print "    # main = first ONLINE core of the tier (what TSP_CPU_OPTIMIZE_V2 picks); draw = the next one, online or brought online"
    print "    for _n in $_tier; do"
    print "        _on=1; [ -r \"$TSP_SYS_CPU/cpu$_n/online\" ] && read -r _on < \"$TSP_SYS_CPU/cpu$_n/online\""
    print "        if [ -z \"$TSP_MAIN_GUESS\" ]; then [ \"$_on\" = 1 ] && TSP_MAIN_GUESS=$_n; continue; fi"
    print "        if [ \"$_on\" = 1 ]; then TSP_DRAW_CPU=$_n; break; fi"
    print "        if [ -w \"$TSP_SYS_CPU/cpu$_n/online\" ] && echo 1 > \"$TSP_SYS_CPU/cpu$_n/online\" 2>/dev/null; then"
    print "            sleep 1; read -r _on < \"$TSP_SYS_CPU/cpu$_n/online\""
    print "            [ \"$_on\" = 1 ] && { TSP_DRAW_CPU=$_n; TSP_DRAW_ONLINED=$_n; break; }"
    print "        fi"
    print "    done"
    print "    # fallback: an offline sibling has no cpufreq node on some kernels - try main+1, keep it only if it is as fast"
    print "    if [ -z \"$TSP_DRAW_CPU\" ] && [ -n \"$TSP_MAIN_GUESS\" ]; then"
    print "        _n=$((TSP_MAIN_GUESS + 1)); _o=\"$TSP_SYS_CPU/cpu$_n/online\""
    print "        if [ -w \"$_o\" ] && [ \"$(cat \"$_o\" 2>/dev/null)\" = 0 ] && echo 1 > \"$_o\" 2>/dev/null; then"
    print "            sleep 1; _k=0; [ -r \"$TSP_SYS_CPU/cpu$_n/cpufreq/cpuinfo_max_freq\" ] && read -r _k < \"$TSP_SYS_CPU/cpu$_n/cpufreq/cpuinfo_max_freq\""
    print "            if [ \"${_k:-0}\" -ge \"$_best\" ] 2>/dev/null; then TSP_DRAW_CPU=$_n; TSP_DRAW_ONLINED=$_n; _tier=\"$_tier +$_n\"; else echo 0 > \"$_o\" 2>/dev/null; fi"
    print "        fi"
    print "    fi"
    print "    echo \"TSP_DRAWTHREAD_V1 core tier=[$_tier] @ ${_best} kHz main=cpu${TSP_MAIN_GUESS:-?} draw=cpu${TSP_DRAW_CPU:-none} onlined=${TSP_DRAW_ONLINED:-none} online_now=$(cat \"$TSP_SYS_CPU/online\" 2>/dev/null)\" | tee -a /mnt/SDCARD/tsp_prog.txt"
    print "fi"
    print "# <<< TSP_DRAWTHREAD_V1 CORE END"
    print
    next
}
{ print }
/OPENMW_PID=\$!/ && pid == 0 {
    pid = 1
    print "# >>> TSP_DRAWTHREAD_V1 KEEPER BEGIN"
    print "# Main thread stays where TSP_CPU_OPTIMIZE_V2 puts it. The hottest non-main thread (= the OSG draw thread once"
    print "# the world is up; 10% hysteresis so a loading worker does not steal the core) is pinned to cpu$TSP_DRAW_CPU and"
    print "# every other thread kept off it, re-checked every 5s: tsp_cpu_apply_split scatters them at 8/25/60s and OSG"
    print "# re-creates the draw thread with an all-CPU mask on settings changes. Every 60s a sample line (per-thread CPU"
    print "# over 10s) goes to this log and tsp_prog.txt. pin=off in the policy file = samples only. Onlined core goes back."
    print "TSP_DRAW_MASK=\"\"; TSP_REST_MASK=\"\"; TSP_IDLE_PARK=0"
    print "grep -qs '^idle=main' \"$GAMEDIR/tsp_drawthread_policy.txt\" && [ -n \"${TSP_CPU_MAIN_MASK:-}\" ] && TSP_IDLE_PARK=1"
    print "if [ -n \"$TSP_DRAW_CPU\" ] && [ -n \"${TSP_CPU_BG_MASK:-}\" ] && ! grep -qs '^pin=off' \"$GAMEDIR/tsp_drawthread_policy.txt\"; then"
    print "    TSP_DRAW_MASK=$(printf '%x' $(( 1 << TSP_DRAW_CPU )))"
    print "    TSP_REST_MASK=$(printf '%x' $(( 0x$TSP_CPU_BG_MASK & ~(1 << TSP_DRAW_CPU) )))"
    print "    [ \"$TSP_REST_MASK\" = 0 ] && TSP_REST_MASK=$TSP_CPU_BG_MASK"
    print "fi"
    print "echo \"TSP_DRAWTHREAD_V1 armed model=$OSG_THREADING main=cpu${TSP_CPU_MAIN:-?}/${TSP_CPU_MAIN_MASK:-none} draw=cpu${TSP_DRAW_CPU:-none}/${TSP_DRAW_MASK:-none} rest=${TSP_REST_MASK:-${TSP_CPU_BG_MASK:-none}} idle_park=$TSP_IDLE_PARK pid=$OPENMW_PID $(date '+%F %T')\" | tee -a /mnt/SDCARD/tsp_prog.txt"
    print "tsp_dt_snap() {   # one line per thread: tid ticks lastcpu allowed policy(0=normal 5=SCHED_IDLE)"
    print "    for _t in /proc/\"$OPENMW_PID\"/task/[0-9]*; do"
    print "        _s=$(cat \"$_t/stat\" 2>/dev/null) || continue; _r=\"${_s##*) }\"; set -- $_r"
    print "        echo \"${_t##*/} $(( ${12} + ${13} )) ${37} $(grep Cpus_allowed_list \"$_t/status\" 2>/dev/null | cut -f2) ${39}\""
    print "    done"
    print "}"
    print "tsp_dt_mask() { taskset -p \"$1\" 2>/dev/null | sed 's/.*: *//'; }   # current hex mask of a tid"
    print "tsp_dt_wait() {   # 20 samples over ~2s of one tid: R/S/D counts + the two commonest kernel wait channels"
    print "    _wt=$1; _wf=/tmp/tsp_dt_w.$OPENMW_PID; : > \"$_wf\"; _wn=0"
    print "    while [ $_wn -lt 20 ]; do"
    print "        _ws=$(cat /proc/$OPENMW_PID/task/$_wt/stat 2>/dev/null) || break; _wr=\"${_ws##*) }\"; set -- $_wr"
    print "        echo \"$1 $(cat /proc/$OPENMW_PID/task/$_wt/wchan 2>/dev/null)\" >> \"$_wf\"; _wn=$((_wn+1)); sleep 0.1 2>/dev/null || sleep 1"
    print "    done"
    print "    echo \"$(cut -c1 \"$_wf\" | sort | uniq -c | sort -rn | awk '{printf \"%s%s,\", $2, $1}')$(awk '$1!=\"R\" && NF>1 && $2!=\"0\" {print $2}' \"$_wf\" | sort | uniq -c | sort -rn | head -2 | awk '{printf \" %s(%s)\", $2, $1}')\""
    print "    rm -f \"$_wf\""
    print "}"
    print "tsp_dt_env() {   # freq of the main and draw cores + hottest thermal zone"
    print "    _e=\"khz=main:$(cat \"$TSP_SYS_CPU/cpu${TSP_CPU_MAIN:-0}/cpufreq/scaling_cur_freq\" 2>/dev/null)\""
    print "    [ -n \"$TSP_DRAW_CPU\" ] && _e=\"$_e/draw:$(cat \"$TSP_SYS_CPU/cpu$TSP_DRAW_CPU/cpufreq/scaling_cur_freq\" 2>/dev/null)\""
    print "    _tmax=0; for _z in /sys/class/thermal/thermal_zone*/temp; do _tv=$(cat \"$_z\" 2>/dev/null); case \"$_tv\" in ''|*[!0-9]*) continue;; esac; [ \"$_tv\" -gt \"$_tmax\" ] && _tmax=$_tv; done"
    print "    [ \"$_tmax\" -gt 1000 ] && _tmax=$((_tmax / 1000))"
    print "    echo \"$_e temp=$_tmax\""
    print "}"
    print "("
    print "    _i=0; _draw=\"\"; _A=/tmp/tsp_dt_a.$OPENMW_PID; _P=/tmp/tsp_dt_p.$OPENMW_PID; _S1=/tmp/tsp_dt_s1.$OPENMW_PID; _S2=/tmp/tsp_dt_s2.$OPENMW_PID"
    print "    tsp_dt_snap > \"$_P\""
    print "    while kill -0 \"$OPENMW_PID\" 2>/dev/null; do"
    print "        _i=$((_i+1))"
    print "        if [ -n \"$TSP_DRAW_MASK\" ] && [ $((_i % 5)) = 0 ]; then"
    print "            tsp_dt_snap > \"$_A\""
    print "            set -- $(awk -v main=\"$OPENMW_PID\" -v cur=\"$_draw\" 'NR==FNR { t0[$1]=$2; next } ($1 in t0 && $1!=main && $5!=5) { d=$2-t0[$1]; if ($1==cur) cd=d; if (d>best) { best=d; tid=$1 } } END { if (best>=75) printf \"%s %d %d\\n\", tid, best/5, cd/5 }' \"$_P\" \"$_A\")"
    print "            cp \"$_A\" \"$_P\""
    print "            if [ -n \"${1:-}\" ] && [ \"$1\" != \"$_draw\" ] && { [ -z \"$_draw\" ] || [ \"$2\" -ge $(( ${3:-0} + 10 )) ]; }; then"
    print "                [ -n \"$_draw\" ] && taskset -p \"$TSP_REST_MASK\" \"$_draw\" >/dev/null 2>&1"
    print "                taskset -p \"$TSP_DRAW_MASK\" \"$1\" >/dev/null 2>&1 && echo \"TSP_DRAWTHREAD_V1 pin draw tid=$1 (${2}%, was tid=${_draw:-none} ${3:-0}%) -> cpu$TSP_DRAW_CPU at +${_i}s\""
    print "                _draw=$1"
    print "            fi"
    print "            if [ -n \"$_draw\" ]; then"
    print "                for _t in /proc/\"$OPENMW_PID\"/task/[0-9]*; do"
    print "                    _tid=${_t##*/}; _m=$(tsp_dt_mask \"$_tid\"); [ -n \"$_m\" ] || continue"
    print "                    if [ \"$TSP_IDLE_PARK\" = 1 ] && [ \"$(awk -v t=\"$_tid\" '$1==t {print $5}' \"$_A\")\" = 5 ]; then"
    print "                        [ $(( 0x$_m )) = $(( 0x$TSP_CPU_MAIN_MASK )) ] || { taskset -p \"$TSP_CPU_MAIN_MASK\" \"$_tid\" >/dev/null 2>&1 && echo \"TSP_DRAWTHREAD_V1 park SCHED_IDLE tid=$_tid was $_m -> cpu$TSP_CPU_MAIN (idle=main) at +${_i}s\"; }"
    print "                    elif [ \"$_tid\" = \"$_draw\" ]; then"
    print "                        [ $(( 0x$_m )) = $(( 0x$TSP_DRAW_MASK )) ] || { taskset -p \"$TSP_DRAW_MASK\" \"$_tid\" >/dev/null 2>&1 && echo \"TSP_DRAWTHREAD_V1 re-pin draw tid=$_tid was $_m -> cpu$TSP_DRAW_CPU at +${_i}s\"; }"
    print "                    elif [ \"$_tid\" = \"$OPENMW_PID\" ]; then"
    print "                        [ $(( 0x$_m )) = $(( 0x$TSP_CPU_MAIN_MASK )) ] || taskset -p \"$TSP_CPU_MAIN_MASK\" \"$_tid\" >/dev/null 2>&1"
    print "                    elif [ $(( 0x$_m & (1 << TSP_DRAW_CPU) )) != 0 ]; then"
    print "                        taskset -p \"$TSP_REST_MASK\" \"$_tid\" >/dev/null 2>&1"
    print "                    fi"
    print "                done"
    print "            fi"
    print "        fi"
    print "        case $((_i % 60)) in"
    print "            20) tsp_dt_snap > \"$_S1\" ;;"
    print "            30) tsp_dt_snap > \"$_S2\""
    print "                _wm=$(tsp_dt_wait \"$OPENMW_PID\"); _wd=\"\"; [ -n \"$_draw\" ] && _wd=$(tsp_dt_wait \"$_draw\")"
    print "                awk -v main=\"$OPENMW_PID\" -v at=\"$_i\" -v model=\"$OSG_THREADING\" -v env=\"$(tsp_dt_env)\" -v wm=\"$_wm\" -v wd=\"$_wd\" -v draw=\"$_draw\" 'NR==FNR { t0[$1]=$2; next } ($1 in t0) { d=($2-t0[$1])/10.0; if (d>=20) hot++; tot+=d; if (d>=5) top=top \" \" $1 ($1==main ? \"(main)\" : ($1==draw ? \"(draw)\" : \"\")) \"=\" int(d+0.5) \"%@cpu\" $3 \"/\" $4 ($5==5 ? \"/IDLE\" : \"\") } END { printf \"TSP_DRAWTHREAD_V1 sample +%ss model=%s hot(>=20%%)=%d total=%.0f%% %s threads:%s | wait main=%s draw=%s\\n\", at, model, hot, tot, env, top, wm, wd }' \"$_S1\" \"$_S2\" | tee -a /mnt/SDCARD/tsp_prog.txt ;;"
    print "        esac"
    print "        sleep 1"
    print "    done"
    print "    rm -f \"$_A\" \"$_P\" \"$_S1\" \"$_S2\""
    print "    [ -n \"$TSP_DRAW_ONLINED\" ] && { echo 0 > \"$TSP_SYS_CPU/cpu$TSP_DRAW_ONLINED/online\" 2>/dev/null; echo \"TSP_DRAWTHREAD_V1 cpu$TSP_DRAW_ONLINED back offline: online_now=$(cat \"$TSP_SYS_CPU/online\" 2>/dev/null)\"; }"
    print "    tsp_cpuclock_restore 2>/dev/null || true"
    print ") &"
    print "TSP_DRAWTHREAD_KEEPER_PID=$!"
    print "# <<< TSP_DRAWTHREAD_V1 KEEPER END"
}
END { if (model != 1 || core != 1 || pid != 1 || clean != 1 || clock != 1) { print "TSP_DRAWTHREAD_V1 PATCH FAILED model=" model " core=" core " pid=" pid " clean=" clean " clock=" clock > "/dev/stderr"; exit 3 } }
EOF_AWK
}

# ---------------------------------------------------------------- apply
do_apply() {
    PATCHER="$DL/tsp_drawthread_v1_patch.awk"
    write_patcher "$PATCHER"
    hosts | while IFS="$(printf '\t')" read -r NAME HOST; do
        H=$(sshhost "$HOST")
        hdr "APPLY on $NAME ($H)  $STAMP"
        if ! $SSH "$H" "cat > /tmp/tsp_drawthread_v1_patch.awk" < "$PATCHER"; then say "  !! upload of the patcher failed on $NAME - skipping"; continue; fi
        $SSH "$H" sh -s "$NAME" "$STAMP" <<EOF_REMOTE
$REMOTE_COMMON
NAME=\$1; STAMP=\$2
echo "  launcher: \$L  (\$(wc -l < "\$L") lines)  gamedir=\$GAMEDIR  ncpu=\$NCPU online=\$(cat /sys/devices/system/cpu/online 2>/dev/null)"
if grep -q $MARK "\$L"; then
    echo "  already patched ($MARK present) - launcher untouched"
    grep -n '>>> TSP_DRAWTHREAD_V1' "\$L" | sed 's/^/    /'
    echo "  policy: [\$(cat "\$POL" 2>/dev/null | tr '\\n' ' ')]  (empty = draw model, core+pin on)"
    exit 0
fi
n_model=\$(grep -c '^[[:space:]]*export OSG_THREADING=SingleThreaded[[:space:]]*\$' "\$L")
n_core=\$(grep -c '^[[:space:]]*tsp_cpu_optimize[[:space:]]*\$' "\$L")
n_pid=\$(grep -c 'OPENMW_PID=\\\$!' "\$L")
n_clean=\$(grep -c '^[[:space:]]*tsp_cpu_governor_restore 2>/dev/null || true[[:space:]]*\$' "\$L")
n_boost=\$(grep -c '^[[:space:]]*tsp_cpu_governor_boost[[:space:]]*\$' "\$L")
echo "  anchors: OSG_THREADING=SingleThreaded x\$n_model, tsp_cpu_optimize call x\$n_core, governor_boost call x\$n_boost, OPENMW_PID=\\\$! x\$n_pid, governor_restore in cleanup x\$n_clean (all need 1)"
if [ "\$n_model" != 1 ] || [ "\$n_core" != 1 ] || [ "\$n_pid" != 1 ] || [ "\$n_clean" != 1 ] || [ "\$n_boost" != 1 ]; then
    echo "  !! anchors not unique on \$NAME - launcher untouched. The lines in question:"
    grep -n 'OSG_THREADING=\|^[[:space:]]*tsp_cpu_optimize\|^[[:space:]]*tsp_cpu_governor_boost\|OPENMW_PID=\\\$!\|tsp_cpu_governor_restore 2>' "\$L" | sed 's/^/    /'
    exit 1
fi
mkdir -p "\$GAMEDIR/backups"
cp "\$L" "\$GAMEDIR/backups/Morrowind.sh.before-drawthread-\$STAMP" || { echo "  !! backup copy failed - launcher untouched"; exit 1; }
if ! awk -f /tmp/tsp_drawthread_v1_patch.awk "\$L" > "\$L.tmp.\$\$"; then rm -f "\$L.tmp.\$\$"; echo "  !! patcher failed - launcher untouched"; exit 1; fi
if ! bash -n "\$L.tmp.\$\$"; then rm -f "\$L.tmp.\$\$"; echo "  !! patched launcher fails bash -n - launcher untouched"; exit 1; fi
chmod 755 "\$L.tmp.\$\$" && mv "\$L.tmp.\$\$" "\$L"
sed -i '/^model=single/d' "\$POL" 2>/dev/null
echo "  patched \$L with $MARK  (\$(wc -l < "\$L") lines)  backup: \$GAMEDIR/backups/Morrowind.sh.before-drawthread-\$STAMP"
echo "  -- marker lines --"
grep -n '>>> TSP_DRAWTHREAD_V1\|>>> TSP_CPUCLOCK_V1\|TSP_DRAWTHREAD_V1 CLEAN\|TSP_CPUCLOCK_V1 CLEAN\|export OSG_THREADING=' "\$L" | sed 's/^/    /'
echo "  policy: [\$(cat "\$POL" 2>/dev/null | tr '\\n' ' ')]  (empty = draw model, core+pin on)"
EOF_REMOTE
        rc=$?
        if [ "$rc" = 0 ]; then :; else say "  (rc=$rc on $NAME)"; fi
    done
}
# apply, then keep before/after copies on the VM and show what changed
do_apply_with_diff() {
    do_apply
    hdr "DIFF  what changed, per card (full copies in $BK)"
    hosts | while IFS="$(printf '\t')" read -r NAME HOST; do
        H=$(sshhost "$HOST")
        NEW="$BK/Morrowind.sh.$NAME.$STAMP.patched"
        OLD="$BK/Morrowind.sh.$NAME.$STAMP.before"
        $SSH "$H" 'L=/mnt/sdcard/mmcblk1p1/Roms/PORTS/Morrowind.sh; [ -f "$L" ] || L=/mnt/SDCARD/Roms/PORTS/Morrowind.sh; cat "$L"' > "$NEW" 2>/dev/null
        $SSH "$H" 'B=$(ls -t /mnt/SDCARD/data/ports/openmw/backups/Morrowind.sh.before-drawthread-* 2>/dev/null | head -1); [ -n "$B" ] && cat "$B"' > "$OLD" 2>/dev/null
        if [ -s "$NEW" ] && [ -s "$OLD" ]; then
            say "  $NAME: +$(diff "$OLD" "$NEW" | grep -c '^>') lines / -$(diff "$OLD" "$NEW" | grep -c '^<') lines   (diff -u \"$OLD\" \"$NEW\")"
        else
            say "  $NAME: could not fetch launcher/backup for the diff"
        fi
    done
    say ""
    say "  next: launch Morrowind on each card, play 3+ minutes in a heavy spot (Balmora Mages Guild chest area /"
    say "        Caldera castle stairs), quit, then:   sh ~/Downloads/tsp_drawthread_v1.sh check"
    say "        (check also gives a live per-thread CPU table if you run it while the game is up)"
}

# ---------------------------------------------------------------- check (after a play session, or live)
do_check() {
    hosts | while IFS="$(printf '\t')" read -r NAME HOST; do
        H=$(sshhost "$HOST")
        hdr "CHECK on $NAME ($H)  $(date +%Y%m%d-%H%M%S)"
        $SSH "$H" sh -s "$NAME" <<EOF_REMOTE
$REMOTE_COMMON
NAME=\$1
echo "  launcher: \$L  marker=\$(grep -c $MARK "\$L")  ncpu=\$NCPU online=\$(cat /sys/devices/system/cpu/online 2>/dev/null)  policy=[\$(cat "\$POL" 2>/dev/null | tr '\\n' ' ')]"
for c in 0 4 5; do f=/sys/devices/system/cpu/cpu\$c/cpufreq; [ -d \$f ] && echo "  cpu\$c online=\$(cat /sys/devices/system/cpu/cpu\$c/online 2>/dev/null || echo 1) cur_khz=\$(cat \$f/scaling_cur_freq 2>/dev/null) gov=\$(cat \$f/scaling_governor 2>/dev/null)"; done
LOG="\$GAMEDIR/openmw_log.txt"
echo "  -- proof lines (\$PROG + openmw_log.txt; quiet mode writes them to the log only): last TSP_CPUCLOCK_V1, last 6 TSP_DRAWTHREAD_V1 core/armed/sample --"
grep -h TSP_CPUCLOCK_V1 "\$PROG" "\$LOG" 2>/dev/null | tail -1 | sed 's/^/    /'
grep -h 'TSP_DRAWTHREAD_V1 \(core\|armed\|sample\)' "\$PROG" "\$LOG" 2>/dev/null | tail -6 | sed 's/^/    /'
[ "\$(grep -h -c TSP_DRAWTHREAD_V1 "\$PROG" "\$LOG" 2>/dev/null | awk '{s+=\$1} END {print s+0}')" = 0 ] && echo "    (none: no launch since the patch, or the launcher never reached the launch line)"
if [ ! -f "\$LOG" ]; then echo "  !! \$LOG not found"; else
    echo "  -- \$LOG (\$(ls -l "\$LOG" | awk '{print \$5, \$6, \$7, \$8}')) --"
    echo "  model line:"; grep 'TSP_DRAWTHREAD_V1 model=' "\$LOG" | tail -1 | sed 's/^/    /'
    echo "  pin lines (first 3 + last 1; expect the draw tid to settle on one tid):"
    grep 'TSP_DRAWTHREAD_V1 \(pin\|re-pin\)' "\$LOG" | head -3 | sed 's/^/    /'; echo "    ..."; grep 'TSP_DRAWTHREAD_V1 \(pin\|re-pin\)' "\$LOG" | tail -1 | sed 's/^/    /'
    echo "  re-pins total: \$(grep -c 'TSP_DRAWTHREAD_V1 re-pin' "\$LOG")  parked: \$(grep -c 'TSP_DRAWTHREAD_V1 park' "\$LOG")   PROOF in a sample line = hot(>=20%)=2, main on its core, draw tid on cpu<draw>"
echo "  wait fields: main/draw mostly R = CPU-bound there; draw sleeping in a pvr/mali/fence/poll symbol = GPU-bound; futex = waiting on the other thread; a /IDLE thread at 100% = navmesh generating"
    echo "  GL errors logged by openmw: \$(grep -c -i "GL error\|glGetError\|invalid operation" "\$LOG")   crashes: \$(grep -c -i "signal 11\|segfault\|Segmentation" "\$LOG")"
fi
echo "  cpufreq now: cpu0 cur=\$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null) max=\$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null) ceiling=\$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null) gov=\$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)  (idle reading; khz= in a sample line is the in-game one)"
echo "  display path: dri=[\$(ls /dev/dri 2>/dev/null | tr '\\n' ' ')] fb=[\$(ls /dev/fb* 2>/dev/null | tr '\\n' ' ')]"
[ -r /sys/kernel/debug/dri/0/clients ] && { echo "  drm clients:"; head -8 /sys/kernel/debug/dri/0/clients | sed 's/^/    /'; }
P=\$(find_pid) || { echo "  game not running now - no live table (the sample lines above are the proof)"; exit 0; }
echo "  game fds on the display: \$(ls -l /proc/\$P/fd 2>/dev/null | grep -o '/dev/dri/[a-z0-9]*\|/dev/fb[0-9]*' | sort | uniq -c | tr '\\n' ' ')"
echo "  -- LIVE: game running (pid \$P, OSG_THREADING in its env: \$(tr '\\000' '\\n' < /proc/\$P/environ 2>/dev/null | awk -F= '/^OSG_THREADING=/ {print \$2}')) - sampling 10s, keep moving --"
thread_sample "\$P" | sed 's/^/    /'
EOF_REMOTE
    done
}

# ---------------------------------------------------------------- A/B policy + revert
do_flag() {
    hosts | while IFS="$(printf '\t')" read -r NAME HOST; do
        H=$(sshhost "$HOST")
        hdr "$1 on $NAME ($H)"
        $SSH "$H" sh -s "$1" <<EOF_REMOTE
$REMOTE_COMMON
if [ "\$1" = single ]; then grep -qs '^model=single' "\$POL" || echo "model=single" >> "\$POL"; echo "  next launch = SingleThreaded (restart the game)"; fi
if [ "\$1" = draw ]; then sed -i '/^model=single/d' "\$POL" 2>/dev/null; echo "  next launch = DrawThreadPerContext (restart the game)"; fi
echo "  policy: [\$(cat "\$POL" 2>/dev/null | tr '\\n' ' ')]"
grep -q $MARK "\$L" || echo "  !! launcher is not patched with $MARK - the policy does nothing until you run apply"
EOF_REMOTE
    done
}
do_revert() {
    hosts | while IFS="$(printf '\t')" read -r NAME HOST; do
        H=$(sshhost "$HOST")
        hdr "REVERT on $NAME ($H)"
        $SSH "$H" sh -s "$STAMP" <<EOF_REMOTE
$REMOTE_COMMON
B=\$(ls -t "\$GAMEDIR/backups/Morrowind.sh.before-drawthread-"* 2>/dev/null | head -1)
[ -n "\$B" ] || { echo "  no before-drawthread backup here - nothing to do"; exit 0; }
cp "\$L" "\$GAMEDIR/backups/Morrowind.sh.drawthread-removed-\$1" && cp "\$B" "\$L" && chmod 755 "\$L" && rm -f "\$POL"
echo "  restored \$B -> \$L  marker now: \$(grep -c $MARK "\$L")"
grep -n 'export OSG_THREADING=' "\$L" | sed 's/^/    /'
EOF_REMOTE
    done
}

case "$MODE" in
    all|apply)     do_apply_with_diff ;;
    check|verify)  do_check ;;
    single|draw)   do_flag "$MODE" ;;
    revert)        do_revert ;;
    *) die "unknown mode '$MODE' (all|apply|check|single|draw|revert)" ;;
esac
