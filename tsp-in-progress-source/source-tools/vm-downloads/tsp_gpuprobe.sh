#!/bin/sh
# tsp_gpuprobe.sh - READ-ONLY. Is the base TSP (.21, PowerVR) held back by the GPU, by one CPU
# thread, by a thread handoff, or by throttling? It reads /proc + PowerVR debugfs while the game
# runs and prints a verdict. Touches nothing: no rebuild, no launcher edit, no change to the card.
#
# It runs the sampler ON THE HANDHELD (writing to /mnt/SDCARD/tsp_gpuprobe.txt) and fetches the
# result afterward, so a dropped wifi/ssh connection can no longer kill the run.
#
# HOW TO RUN:
#   1. On the TSP: launch Morrowind, load your save, walk to the WORST spot (e.g. Ald-ruhn exterior).
#   2. Stand still, camera on the heavy view. Do not move.
#   3. On the PC:   sh ~/Downloads/tsp_gpuprobe.sh
#      Keep holding that view until it prints the verdict (~25 s).
#   If the fetch ever fails, just run:   sh ~/Downloads/tsp_gpuprobe.sh pull
#   to grab the result the handheld already finished writing.
#
# Tune:  SECS=30 HZ=4 sh ~/Downloads/tsp_gpuprobe.sh    (default SECS=20 HZ=4)
# Force a card:  TSP=root@192.168.1.21 TSP_NAME=tsp sh ~/Downloads/tsp_gpuprobe.sh
#
if [ "$(head -c 400 "$0" | tr -d -c '\r' | wc -c | tr -d ' ')" != 0 ]; then T=/tmp/tsp_gpuprobe.$$; tr -d '\r' < "$0" > "$T"; exec sh "$T" "$@"; fi # absorbs a trailing CR
set -u
MODE="${1:-run}"
TSP="${TSP:-${TSP_DEV:-}}"
if [ -z "${TSP}" ] && [ -r "$HOME/.tsp_dev" ]; then TSP="$(cat "$HOME/.tsp_dev")"; fi
[ -n "${TSP}" ] || TSP="root@192.168.1.21"
[ -n "${TSP_NAME:-}" ] || TSP_NAME="$(awk -F'\t' -v h="$TSP" '$2==h {print $1}' "$HOME/.tsp_hosts" 2>/dev/null | head -1)"
NAME="${TSP_NAME:-tsp}"
SECS="${SECS:-20}"; HZ="${HZ:-4}"
SSHO="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o LogLevel=ERROR"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/tsp-gpuprobe-$NAME-$STAMP.txt"
DEVOUT=/mnt/SDCARD/tsp_gpuprobe.txt

fetch() {   # pull the device file to the PC and show it
  _o="$1"
  ssh -n $SSHO "$TSP" "cat $DEVOUT 2>/dev/null" > "$_o" 2>/dev/null
  if [ -s "$_o" ]; then
    cat "$_o"
    grep -q '==== DONE' "$_o" || echo "  (note: no DONE marker - the probe may still be running; wait and re-run: sh ~/Downloads/tsp_gpuprobe.sh pull)"
    echo; echo "  saved: $_o"
  else
    echo "  !! nothing to fetch yet at $DEVOUT - is the game running, and did you give the probe time to write? Re-run: sh ~/Downloads/tsp_gpuprobe.sh pull"
  fi
}

if [ "$MODE" = pull ]; then
  echo "Fetching the last probe result from $NAME ($TSP)..."
  fetch "$OUT"; exit 0
fi

# ---- launch the sampler detached on the handheld, then wait locally, then fetch ----
echo "tsp_gpuprobe on $NAME ($TSP)  ${SECS}s @ ${HZ}Hz  read-only"
echo "Starting the probe on the handheld. KEEP HOLDING the heavy view..."

SAMPLER="$(cat <<SAMP
SECS=$SECS; HZ=$HZ
N=\$(( SECS * HZ )); [ "\$N" -ge 1 ] || N=80
SLEEP=\$(awk -v h="\$HZ" 'BEGIN{printf "%.3f",(h>0)?1.0/h:0.25}')
PID=\$(pidof openmw-0.51 2>/dev/null | tr ' ' '\n' | head -1)
echo "tsp_gpuprobe \$(date +%H:%M:%S)  ${SECS}s @ ${HZ}Hz"
if [ -z "\$PID" ]; then echo "  !! openmw-0.51 is not running. Launch the game, stand in the worst spot, then run this."; echo "==== DONE (no game) ===="; exit 0; fi
MAIN=\$PID
echo "  game pid=\$PID  sampling \$N times"
PVR=/sys/kernel/debug/pvr
echo "  ---- PowerVR debugfs (before) ----"
if [ -d "\$PVR" ]; then
  echo "  nodes: \$(ls "\$PVR" 2>/dev/null | tr '\n' ' ')"
  for f in status gpu00/status gpu00/utilisation gpu00/gpu_utilisation gpu00/power; do
    [ -r "\$PVR/\$f" ] && { echo "  [\$f]:"; head -10 "\$PVR/\$f" 2>/dev/null | sed 's/^/    /'; }
  done
  grep -ri -m6 'util\|load\|busy\|active\|idle\|clock\|freq' "\$PVR/status" "\$PVR/driver_stats" 2>/dev/null | sed 's/^/    stat: /' | head -10
else echo "  (no /sys/kernel/debug/pvr on this card)"; fi
W=/tmp/tsp_gp_w.\$\$; mkdir -p "\$W"; : > "\$W/first"; : > "\$W/khz"; : > "\$W/temp"
i=0
while [ "\$i" -lt "\$N" ]; do
  for t in /proc/\$PID/task/[0-9]*; do
    tid=\${t##*/}
    read -r st < "\$t/stat" 2>/dev/null || continue
    rest=\${st##*) }
    set -- \$rest
    state=\$1; ut=\${12}; stt=\${13}; pol=\${39}
    wc=running
    if [ "\$state" != "R" ]; then wc=\$(cat "\$t/wchan" 2>/dev/null); [ -n "\$wc" ] || wc=unknown; fi
    case "\$wc" in
      running) cls=RUN_cpu ;;
      *pvr*|*rgx*|*rogue*|*fence*|*sync*|*dma*|*gpu*|*gem*|*MISR*|*kbase*|*mali*) cls=WAIT_gpu ;;
      *poll*|*egl*|*Swap*|*kms*|*drm*|*vblank*|*flip*) cls=WAIT_display ;;
      *futex*) cls=WAIT_thread ;;
      *hrtimer*|*nanosleep*|*schedule_timeout*|*schedule_hrtimeout*) cls=WAIT_sleep ;;
      *) cls=WAIT_other ;;
    esac
    echo "\$cls" >> "\$W/\$tid.cls"
    [ "\$wc" = running ] || echo "\$wc" >> "\$W/\$tid.wc"
    [ -f "\$W/\$tid.seen" ] || { echo "\$tid \$((ut+stt)) \$pol" >> "\$W/first"; : > "\$W/\$tid.seen"; }
    echo "\$tid \$((ut+stt)) \$pol" > "\$W/\$tid.last"
  done
  for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do [ -r "\$c" ] && { read -r v < "\$c" && printf '%s,' "\$v"; }; done >> "\$W/khz"; echo >> "\$W/khz"
  hot=0; for z in /sys/class/thermal/thermal_zone*/temp; do [ -r "\$z" ] || continue; read -r v < "\$z"; [ "\${v:-0}" -gt "\$hot" ] 2>/dev/null && hot=\$v; done; echo "\$hot" >> "\$W/temp"
  i=\$((i+1)); sleep "\$SLEEP"
done
echo "  ---- PowerVR debugfs (after) ----"
if [ -d "\$PVR" ]; then for f in status gpu00/status gpu00/utilisation gpu00/gpu_utilisation; do [ -r "\$PVR/\$f" ] && { echo "  [\$f]:"; head -8 "\$PVR/\$f" 2>/dev/null | sed 's/^/    /'; }; done; fi
CLK=\$(getconf CLK_TCK 2>/dev/null); [ -n "\$CLK" ] || CLK=100
echo; echo "  ========  PER-THREAD over \$N samples  ========"
echo "  tid      role          cpu%   share of samples"
for f in "\$W"/*.cls; do
  tid=\$(basename "\$f" .cls); tot=\$(wc -l < "\$f"); [ "\$tot" -ge 1 ] || continue
  first=\$(awk -v t="\$tid" '\$1==t{print \$2; exit}' "\$W/first")
  read -r lt lj lpol < "\$W/\$tid.last"
  dj=\$(( lj - first )); [ "\$dj" -ge 0 ] || dj=0
  cpu=\$(awk -v dj="\$dj" -v n="\$N" -v hz="\$HZ" -v clk="\$CLK" 'BEGIN{s=n/hz; printf "%.0f",(s>0)?100.0*(dj/clk)/s:0}')
  role=worker; [ "\$tid" = "\$MAIN" ] && role=MAIN; [ "\$lpol" = "5" ] && role="navmesh/IDLE"
  top=\$(sort "\$f" | uniq -c | sort -rn | awk -v tot="\$tot" '{printf "%s %d%%  ",\$2,int(100*\$1/tot)}' | sed 's/  *\$//')
  printf "  %-8s %-12s %5s%%  %s\n" "\$tid" "\$role" "\$cpu" "\$top"
  [ -r "\$W/\$tid.wc" ] && printf "  %-8s %-12s         top sleep: %s\n" "" "" "\$(sort "\$W/\$tid.wc" | uniq -c | sort -rn | head -1 | awk '{\$1="";sub(/^ /,"");print}')"
done
echo; echo "  ========  ENVIRONMENT  ========"
echo "  cpu kHz per-core  first: \$(head -1 "\$W/khz")   last: \$(tail -1 "\$W/khz")"
mint=\$(sort -n "\$W/temp" | head -1); maxt=\$(sort -n "\$W/temp" | tail -1)
echo "  hottest thermal zone: \$((mint/1000))C -> \$((maxt/1000))C"
echo; echo "  ========  VERDICT  ========"
draw=\$(for f in "\$W"/*.cls; do tid=\$(basename "\$f" .cls); [ "\$tid" = "\$MAIN" ] && continue; read -r a b lpol < "\$W/\$tid.last"; [ "\$lpol" = "5" ] && continue; first=\$(awk -v t="\$tid" '\$1==t{print \$2}' "\$W/first"); echo "\$(( b - first )) \$tid"; done | sort -rn | head -1 | awk '{print \$2}')
mainrun=\$(grep -c RUN_cpu "\$W/\$MAIN.cls" 2>/dev/null); maintot=\$(wc -l < "\$W/\$MAIN.cls" 2>/dev/null)
pct(){ [ "\${2:-0}" -gt 0 ] && echo \$(( 100*\$1/\$2 )) || echo 0; }
echo "  main thread (\$MAIN): running \$(pct \${mainrun:-0} \${maintot:-1})% of samples"
if [ -n "\$draw" ]; then
  dg=\$(grep -c 'WAIT_gpu\|WAIT_display' "\$W/\$draw.cls"); dr=\$(grep -c RUN_cpu "\$W/\$draw.cls"); dt=\$(grep -c WAIT_thread "\$W/\$draw.cls"); ds=\$(grep -c WAIT_sleep "\$W/\$draw.cls"); dto=\$(wc -l < "\$W/\$draw.cls")
  hex=no; [ -r "\$W/\$draw.wc" ] && grep -qE '^(0x)?[0-9a-f]{6,}\$|^0\$|^unknown\$' "\$W/\$draw.wc" && hex=yes
  gp=\$(pct \${dg:-0} \${dto:-1}); rn=\$(pct \${dr:-0} \${dto:-1}); th=\$(pct \${dt:-0} \${dto:-1}); sl=\$(pct \${ds:-0} \${dto:-1}); mr=\$(pct \${mainrun:-0} \${maintot:-1})
  echo "  draw/GL thread (\$draw): running \${rn}%, GPU/display wait \${gp}%, waiting-on-other-thread \${th}%, timer/limiter \${sl}%"
  if [ "\$hex" = yes ] && [ "\$gp" -lt 50 ] && [ "\$rn" -lt 50 ] && [ "\$th" -lt 30 ] && [ "\$sl" -lt 30 ]; then
    echo "  (kernel hides wchan names; inferring the sleep from thread state)"; gp=\$(( 100 - rn - th - sl ))
  fi
  if [ "\$gp" -ge 50 ]; then
    echo "  => GPU-BOUND. The draw thread spends most of the frame asleep waiting on the PowerVR;"
    echo "     the ~54 ms draw block is real GPU work. Levers = draw FEWER/cheaper things (view"
    echo "     distance, draw-call count, lights, shader cost). No GPU-clock knob exists on this card."
  elif [ "\$rn" -ge 50 ]; then
    echo "  => DRIVER/CPU-BOUND on the draw thread: burning CPU inside gl4es/PowerVR submission."
    echo "     Levers = fewer draw calls and state changes per frame (gl4es re-send cost)."
  elif [ "\$mr" -ge 85 ]; then
    echo "  => MAIN-THREAD-BOUND: cull/update is the ceiling (like the S was)."
  else
    echo "  => not saturated and not clearly GPU-waiting; a WAIT_thread majority = thread handoff,"
    echo "     a WAIT_sleep majority = a frame limiter. Read the per-thread lines above."
  fi
else echo "  (no distinct draw thread - OSG_THREADING SingleThreaded here?)"; fi
rm -rf "\$W"
echo "==== DONE ===="
SAMP
)"

# ship the sampler and run it detached on the device
_b64="$(printf '%s' "$SAMPLER" | base64 | tr -d '\n')"
ssh -n $SSHO "$TSP" "F=/tmp/tsp_gpsamp.sh
printf '%s' '$_b64' | base64 -d > \"\$F\" 2>/dev/null || { echo 'no base64 on device'; exit 1; }
rm -f $DEVOUT
setsid sh \"\$F\" </dev/null >$DEVOUT 2>&1 &
echo \"  probe started on the handheld (pid \$!), writing $DEVOUT\"" 2>&1 || {
  echo "  !! could not reach $TSP to start the probe. Is the handheld awake, on wifi, and running the game?"; exit 1; }

# wait out the sampling window, then POLL the device for the DONE marker so we never fetch early
echo "  sampling for ~${SECS}s (keep holding the view)..."
k=0; while [ "$k" -lt "$SECS" ]; do sleep 2; k=$((k+2)); printf '.'; done; echo
echo "  waiting for the probe to finish writing..."
tries=0
while [ "$tries" -lt 25 ]; do
  ssh -n $SSHO "$TSP" "grep -q '==== DONE' $DEVOUT 2>/dev/null" && break
  sleep 3; tries=$((tries+1)); printf '.'
done; echo
echo "  fetching the result..."
fetch "$OUT"
