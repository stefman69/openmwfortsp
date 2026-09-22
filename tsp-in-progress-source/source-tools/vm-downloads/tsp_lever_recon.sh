#!/bin/bash
# tsp_lever_recon.sh  -  READ-ONLY recon for TSP_VBO_ORPHAN_V1 (gl4es) and TSP_HYGIENE_V1 (launcher).
# Writes nothing on the device, the container, or the source tree. Run once per card:
#     bash ~/Downloads/tsp_net.sh each tsp_lever_recon.sh
# or, per card by hand:
#     TSP=root@192.168.1.12 TSP_NAME=tsps bash ~/Downloads/tsp_lever_recon.sh
#     TSP=root@192.168.1.21 TSP_NAME=tsp  bash ~/Downloads/tsp_lever_recon.sh
# Output: ~/Downloads/tsp-lever-recon-<name>-<stamp>.txt   (upload every one produced)
#
# CRLF self-heal: if the download added \r, re-exec a stripped copy.
if [ "$(head -c 400 "$0" | tr -d -c '\r' | wc -c | tr -d ' ')" != 0 ]; then T=/tmp/tsp_lever_recon.$$; tr -d '\r' < "$0" > "$T"; exec sh "$T" "$@"; fi # keep this comment: it absorbs a trailing CR
set -u

TSP="${TSP:-${TSP_DEV:-}}"
if [ -z "${TSP}" ] && [ -r "$HOME/.tsp_dev" ]; then TSP="$(cat "$HOME/.tsp_dev")"; fi
[ -n "${TSP}" ] || TSP="root@192.168.1.12"
[ -n "${TSP_NAME:-}" ] || TSP_NAME="$(awk -F'\t' -v h="$TSP" '$2==h {print $1}' "$HOME/.tsp_hosts" 2>/dev/null | head -1)"
DEVTAG=""; [ -n "${TSP_NAME:-}" ] && DEVTAG="-$(printf '%s' "$TSP_NAME" | tr -c 'A-Za-z0-9._-' '_')"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/tsp-lever-recon${DEVTAG}-$STAMP.txt"
SSHO="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o LogLevel=ERROR"
CONT="openmw_builder"
GAME="/mnt/SDCARD/data/ports/openmw"
NSEC=0
hr() { NSEC=$((NSEC+1)); printf '\n########## %s ##########\n' "$1"; }

# remote runner: body on stdin -> base64 -> file on device -> busybox sh, stdin closed.
# (.21's /bin/bash is busybox and eats a script fed on stdin; this is the pattern tsp_cfw.sh uses.)
rin() {
  _b64="$(base64 | tr -d '\n')"
  ssh -n $SSHO "$TSP" "T=/tmp/tsp_lr.\$\$
printf '%s' '$_b64' | base64 -d > \"\$T\" 2>/dev/null || { echo '  (no base64 on this device)'; exit 1; }
sh \"\$T\" </dev/null
_r=\$?
rm -f \"\$T\"
exit \$_r" 2>&1
}

{
printf '\n  ==================  DEVICE: %s  (%s)  ==================\n' "${TSP_NAME:-UNNAMED}" "$TSP"
printf '  tsp_lever_recon.sh  %s  read-only\n' "$STAMP"

hr "0. REACHABILITY"
if ssh -n $SSHO "$TSP" 'echo "  device ok: $(hostname) $(uname -r) MemTotal=$(awk "/MemTotal/{print \$2}" /proc/meminfo)"' 2>&1; then :; else
  echo "  !! DEVICE UNREACHABLE: $TSP - device sections below will be empty. Is it awake and on wifi?"
fi
if docker exec "$CONT" true 2>/dev/null; then echo "  container ok: $CONT"; else echo "  !! CONTAINER $CONT NOT RUNNING - gl4es sections will be empty"; fi

# ---------------------------------------------------------------- container: gl4es
hr "1. CONTAINER: which gl4es tree builds the deployed libGL.so.1"
docker exec -i "$CONT" bash -s <<'DOCK' 2>&1
cd /root/gl4es-tsps 2>/dev/null || { echo "  !! /root/gl4es-tsps missing"; ls -d /root/gl4es* 2>/dev/null; exit 0; }
echo "  -- git --"; git log --oneline -6 2>/dev/null; echo "  status:"; git status --short 2>/dev/null | head -15
echo "  -- version.h --"; grep -n 'MAJOR\|MINOR\|REVISION' include/version.h version.h 2>/dev/null | head -6
echo "  -- trees present --"; ls -d /root/gl4es* 2>/dev/null
echo "  -- rebuild script (first 120 lines) --"
for s in /root/rebuild_gl4es_tsps_o3.sh /root/rebuild_gl4es*.sh; do [ -f "$s" ] && { echo "  == $s =="; sed -n 1,120p "$s"; }; done 2>/dev/null
echo "  -- built libGL.so.1 candidates (path, size, mtime, md5) --"
find /root -maxdepth 4 -name 'libGL.so.1' -type f 2>/dev/null | while read -r f; do printf '  %s  %s\n' "$(md5sum "$f" | cut -c1-32)" "$(ls -la "$f")"; done
DOCK

hr "2. CONTAINER: src/gl/buffers.h FULL (glbuffer_t is here)"
docker exec -i "$CONT" bash -c 'cd /root/gl4es-tsps && wc -l src/gl/buffers.h src/gl/buffers.c src/gl/fpe.c src/gl/init.c src/gl/init.h src/gl/program.c src/gl/vao.h 2>&1; echo; cat -n src/gl/buffers.h' 2>&1

hr "3. CONTAINER: src/gl/buffers.c FULL (anchor file for TSP_VBO_ORPHAN_V1)"
docker exec -i "$CONT" bash -c 'cd /root/gl4es-tsps && cat -n src/gl/buffers.c' 2>&1

hr "4. CONTAINER: the draw-time real-VBO bind site in src/gl/fpe.c (deferred-upload hook goes here)"
docker exec -i "$CONT" bash -s <<'DOCK' 2>&1
cd /root/gl4es-tsps || exit 0
echo "  -- every real_buffer / bindBuffer( line in fpe.c and drawing.c --"
grep -n 'real_buffer\|bindBuffer(' src/gl/fpe.c src/gl/drawing.c 2>/dev/null
echo "  -- window around bindBuffer(GL_ARRAY_BUFFER, v->real_buffer) in fpe.c --"
L=$(grep -n 'bindBuffer(GL_ARRAY_BUFFER, *v->real_buffer)' src/gl/fpe.c | head -1 | cut -d: -f1)
if [ -n "$L" ]; then A=$((L-60)); [ $A -lt 1 ] && A=1; sed -n "${A},$((L+25))p" src/gl/fpe.c | awk -v s="$A" '{printf "  %5d: %s\n", s+NR-1, $0}' ; else echo "  (pattern not found - see grep above for the real site)"; fi
echo "  -- vao attrib struct (field names: buffer / real_buffer / real_pointer) --"
grep -n -B3 -A22 'typedef struct.*vertexattrib_s\|} vertexattrib_t' src/gl/vao.h 2>/dev/null | head -60
echo "  -- glstate->bind_buffer and VaoSharedClear --"
grep -n 'bind_buffer\.array\|VaoSharedClear' src/gl/*.h src/gl/*.c 2>/dev/null | head -12
DOCK

hr "5. CONTAINER: TSP conventions already in the fork (env gate + quiet log), and usevbo"
docker exec -i "$CONT" bash -s <<'DOCK' 2>&1
cd /root/gl4es-tsps || exit 0
echo "  -- TSP_ markers per file --"; grep -c 'TSP_' src/gl/*.c src/glx/*.c 2>/dev/null | grep -v ':0$'
echo "  -- env-gate / log helpers --"; grep -n 'tsp_prgcache_on\|tsp_shcache_on\|tsp_log_on\|TSP_QUIETLOG\|LIBGL_TSP_LOG\|getenv("LIBGL_TSP\|getenv("TSP_' src/gl/*.c src/glx/*.c 2>/dev/null | head -30
echo "  -- definition of the gate helper(s) in program.c --"
for fn in tsp_prgcache_on tsp_log_on tsp_shcache_on; do L=$(grep -n "^[a-z ]*int *$fn *(" src/gl/program.c src/gl/shader.c 2>/dev/null | head -1); [ -n "$L" ] && { f=${L%%:*}; n=$(echo "$L" | cut -d: -f2); echo "  == $f:$n =="; sed -n "${n},$((n+18))p" "$f"; }; done
echo "  -- usevbo registration --"; grep -n 'usevbo\|USEVBO' src/gl/init.c src/gl/init.h 2>/dev/null | head -10
echo "  -- how glBufferData decides go_real (usage list) --"; grep -n -A3 'go_real = 0' src/gl/buffers.c | head -12
DOCK

# ---------------------------------------------------------------- device
hr "6. DEVICE: identity, cores, cpufreq, cpusets"
rin <<'REM'
echo "  host=$(hostname) kernel=$(uname -r)"
echo "  compatible: $(tr '\0' ' ' < /proc/device-tree/compatible 2>/dev/null)"
echo "  online: $(cat /sys/devices/system/cpu/online 2>/dev/null)  present: $(cat /sys/devices/system/cpu/present 2>/dev/null)"
for c in /sys/devices/system/cpu/cpu[0-9]*; do n=${c##*/cpu}; o=1; [ -f "$c/online" ] && o=$(cat "$c/online")
  if [ -d "$c/cpufreq" ]; then printf '  cpu%-2s online=%s gov=%-14s cur=%-8s min=%-8s max=%-8s hw_max=%-8s related=%s\n' "$n" "$o" "$(cat $c/cpufreq/scaling_governor 2>/dev/null)" "$(cat $c/cpufreq/scaling_cur_freq 2>/dev/null)" "$(cat $c/cpufreq/scaling_min_freq 2>/dev/null)" "$(cat $c/cpufreq/scaling_max_freq 2>/dev/null)" "$(cat $c/cpufreq/cpuinfo_max_freq 2>/dev/null)" "$(cat $c/cpufreq/related_cpus 2>/dev/null)"
  else printf '  cpu%-2s online=%s (no cpufreq node)\n' "$n" "$o"; fi; done
echo "  -- cpusets (what a launched port is allowed) --"
echo "  /proc/1/cpuset=$(cat /proc/1/cpuset 2>/dev/null)  /proc/self/cpuset=$(cat /proc/self/cpuset 2>/dev/null)"
echo "  /proc/self/status Cpus_allowed_list=$(grep Cpus_allowed_list /proc/self/status | cut -f2)"
find /sys/fs/cgroup -maxdepth 3 -name 'cpuset.cpus' 2>/dev/null | while read -r f; do echo "  $f = $(cat "$f")"; done
echo "  -- busybox applets we would use --"
busybox --list 2>/dev/null | grep -E '^(renice|taskset|chrt|nice|ionice|pgrep|pidof|pkill|base64|awk|stat|nproc)$' | tr '\n' ' '; echo
for t in taskset renice chrt; do printf '  %s -> %s\n' "$t" "$(command -v $t 2>/dev/null || echo MISSING)"; done
echo "  taskset probe (hex mask, pid 1 read-only): $(taskset -p 1 2>&1 | head -1)"
REM

hr "7. DEVICE: the OS daemons that share the cores with the game (nice, affinity, CPU time)"
rin <<'REM'
CLK=$(getconf CLK_TCK 2>/dev/null); [ -n "$CLK" ] || CLK=100
show() { # pid
  p=$1; [ -r /proc/$p/stat ] || return 0
  st=$(cat /proc/$p/stat 2>/dev/null); rest=${st##*) }
  set -- $rest   # $1=state $12=utime $13=stime $17=nice
  ut=${12}; stt=${13}; ni=${17}
  cpus=$(grep Cpus_allowed_list /proc/$p/status 2>/dev/null | cut -f2)
  cg=$(head -1 /proc/$p/cgroup 2>/dev/null)
  printf '  pid %-6s nice=%-3s cpus=%-8s cpu_s=%-7s %-16s %s\n' "$p" "$ni" "$cpus" "$(( (ut+stt)/CLK ))" "$(cat /proc/$p/comm 2>/dev/null)" "$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-70)"
}
echo "  -- named daemons --"
for n in MainUI keymon trimui_scened trimui_inputd trimui_osdd runtrimui.sh mount.exfat trimui_scened ledc; do
  for p in $(pidof "$n" 2>/dev/null); do show $p; done
done
for p in /proc/[0-9]*; do c=$(cat $p/comm 2>/dev/null); case "$c" in mount.exfat*|*trimui*|MainUI*|keymon*|ksoftirqd*|kswapd*|mmcqd*|jbd2*) show ${p##*/};; esac; done | sort -u
echo "  -- top 15 processes by accumulated CPU seconds (whole uptime) --"
for p in /proc/[0-9]*; do [ -r $p/stat ] || continue; st=$(cat $p/stat 2>/dev/null); rest=${st##*) }; set -- $rest; echo "$(( (${12}+${13})/CLK )) ${p##*/} ${17} $(cat $p/comm 2>/dev/null)"; done 2>/dev/null | sort -rn | head -15 | awk '{printf "  cpu_s=%-7s pid=%-6s nice=%-3s %s\n",$1,$2,$3,$4}'
echo "  -- the game, if it is running right now (threads: comm, cpus, nice, cpu_s) --"
gp=$(pidof openmw-0.51 2>/dev/null | head -1)
if [ -n "$gp" ]; then for t in /proc/$gp/task/[0-9]*; do st=$(cat $t/stat 2>/dev/null); rest=${st##*) }; set -- $rest; printf '  tid %-6s cpus=%-8s nice=%-3s cpu_s=%-6s %s\n' "${t##*/}" "$(grep Cpus_allowed_list $t/status | cut -f2)" "${17}" "$(( (${12}+${13})/CLK ))" "$(cat $t/comm)"; done | sort -t= -k4 -rn | head -14
else echo "  (openmw-0.51 not running - thread layout will come from TSP_CPU_OPTIMIZE_V2 in the launcher instead)"; fi
REM

hr "8. DEVICE: storage path of the game (FUSE?), readahead, thermal"
rin <<'REM'
grep -E 'SDCARD|UDISK|fuse|exfat|mmcblk' /proc/mounts | sed 's/^/  /'
for b in /sys/class/bdi/*; do [ -r "$b/read_ahead_kb" ] && echo "  $b read_ahead_kb=$(cat $b/read_ahead_kb)"; done | head -8
ls /sys/fs/fuse/connections/ 2>/dev/null | head -3 | while read -r c; do echo "  fuse conn $c: max_background=$(cat /sys/fs/fuse/connections/$c/max_background 2>/dev/null) congestion=$(cat /sys/fs/fuse/connections/$c/congestion_threshold 2>/dev/null)"; done
for t in /sys/class/thermal/thermal_zone*; do echo "  $(cat $t/type 2>/dev/null)=$(cat $t/temp 2>/dev/null)"; done | tr '\n' ' '; echo
REM

hr "9. DEVICE: the deployed libGL.so.1 (must match the container build) and its TSP markers"
rin <<'REM'
G=/mnt/SDCARD/data/ports/openmw; [ -f $G/lib/libGL.so.1 ] || G=/mnt/SDCARD/data/ports/openmw51
echo "  GAMEDIR used: $G   (other candidate: $(ls -d /mnt/SDCARD/data/ports/openmw* 2>/dev/null | tr '\n' ' '))"
ls -la $G/lib/libGL.so.1* 2>/dev/null | sed 's/^/  /'
echo "  md5: $(md5sum $G/lib/libGL.so.1 2>/dev/null | cut -c1-32)"
for m in TSP_PRGCACHE TSP_SHCACHE TSP_LATE TSP_QUIETLOG LIBGL_TSP_LOG LIBGL_USEVBO LIBGL_TSP_ORPHAN; do printf '  %-18s %s\n' "$m" "$(grep -a -c "$m" $G/lib/libGL.so.1 2>/dev/null)"; done
REM

hr "10. DEVICE: the launcher - md5, and every anchor TSP_HYGIENE_V1 needs, counted"
rin <<'REM'
L=/mnt/SDCARD/Roms/PORTS/Morrowind.sh
[ -f "$L" ] || L=$(ls /mnt/SDCARD/Roms/PORTS/*orrowind*.sh 2>/dev/null | head -1)
echo "  launcher: $L  lines=$(wc -l < "$L" 2>/dev/null)  md5=$(md5sum "$L" 2>/dev/null | cut -c1-32)"
echo "  shebang: $(head -1 "$L")"
for a in 'tsp_cpu_apply_split "$OPENMW_PID" &' 'tsp_cpu_governor_restore 2>/dev/null || true' 'cleanup_children() {' 'TSP_CPU_OPTIMIZE_V2' 'tsp_cpu_policy.txt' 'OPENMW_PID=$!' 'TSP_GOV_SAVE=' 'TSP_HYGIENE' 'tsp_cpu_apply_split() {' 'trap handle_launcher_signal'; do
  printf '  %-48s count=%s line=%s\n' "$a" "$(grep -F -c -- "$a" "$L")" "$(grep -F -n -- "$a" "$L" | head -1 | cut -d: -f1)"; done
echo "  -- cleanup_children() body --"
awk '/^cleanup_children\(\) \{/{p=1} p{print "  " NR ": " $0} p&&/^\}/{exit}' "$L"
echo "  -- tsp_cpu_apply_split() body --"
awk '/^tsp_cpu_apply_split\(\) \{/{p=1} p{print "  " NR ": " $0} p&&/^\}/{exit}' "$L"
G=$(grep -m1 '^GAMEDIR=' "$L" | cut -d= -f2- | tr -d '"'); echo "  GAMEDIR per launcher: $G"
echo "  -- CPU policy file --"; cat "$G/tsp_cpu_policy.txt" 2>/dev/null || echo "  (absent -> auto)"
echo "  -- last CPU policy lines from the launcher log(s) --"; grep -a -h 'CPU policy\|main thread:\|background :\|governor   :' "$G"/openmw*log*.txt /mnt/SDCARD/tsp_prog.txt 2>/dev/null | tail -8
echo "  -- log files present --"; ls -la "$G"/openmw*log*.txt "$G"/config-0.51/openmw.log /mnt/SDCARD/tsp_prog.txt 2>/dev/null | sed 's/^/  /'
REM

hr "11. DEVICE: gltime state on this card (BUCKET item 02 - has the MEAN line ever been produced here?)"
rin <<'REM'
ls -la /mnt/SDCARD/tsp_gltime.txt 2>/dev/null || echo "  no /mnt/SDCARD/tsp_gltime.txt on this card"
grep -a 'TSP_GLT MEAN' /mnt/SDCARD/tsp_gltime.txt 2>/dev/null | tail -2 | cut -c1-600
echo "  SLOW lines: $(grep -a -c 'TSP_GLT SLOW' /mnt/SDCARD/tsp_gltime.txt 2>/dev/null)"
echo "  gltime in preload chain now: $(grep -a -c 'libtsp_gltime' /mnt/SDCARD/Roms/PORTS/Morrowind.sh 2>/dev/null) mention(s) in launcher; tsp_intocc.env:"; grep -i 'gltime\|GLT' /mnt/SDCARD/tsp_intocc.env 2>/dev/null | sed 's/^/    /'
REM

hr "12. DEVICE: GPU clock control - Mali devfreq (S) or PowerVR DVFS (base TSP)"
rin <<'REM'
echo "  drm driver: $(cat /sys/class/drm/card0/device/uevent 2>/dev/null | grep DRIVER)"
echo "  -- devfreq --"; for d in /sys/class/devfreq/*; do [ -e "$d/cur_freq" ] && echo "  $d gov=$(cat $d/governor) cur=$(cat $d/cur_freq) min=$(cat $d/min_freq) max=$(cat $d/max_freq)"; done
echo "  -- platform gpu/pvr/mali nodes --"
for d in /sys/devices/platform/*gpu* /sys/devices/platform/*pvr* /sys/devices/platform/*mali* /sys/devices/platform/soc/*gpu* /sys/class/misc/mali0/device; do [ -d "$d" ] || continue; echo "  $d:"; ls "$d" 2>/dev/null | tr '\n' ' ' | cut -c1-400; echo; for f in power_policy dvfs_enable dvfs gpufreq scene_ctrl core_mask gpuinfo; do [ -e "$d/$f" ] && echo "    $f = $(cat $d/$f 2>/dev/null | head -1)"; done; done
echo "  -- any dvfs/gpufreq nodes anywhere under platform (depth 4) --"
find /sys/devices/platform -maxdepth 4 \( -iname '*dvfs*' -o -iname '*gpufreq*' -o -iname 'pvr*' \) 2>/dev/null | head -20 | sed 's/^/  /'
echo "  -- pvrsrvkm module params --"; ls /sys/module/pvrsrvkm/parameters/ 2>/dev/null | while read -r p; do echo "    $p=$(cat /sys/module/pvrsrvkm/parameters/$p 2>/dev/null | head -1)"; done
echo "  -- debugfs pvr (only if debugfs is already mounted; not mounting anything) --"; grep -q debugfs /proc/mounts && ls /sys/kernel/debug/pvr 2>/dev/null | head | sed 's/^/    /' || echo "    debugfs not mounted"
echo "  -- device tree gpu node(s) --"; ls /proc/device-tree 2>/dev/null | grep -i -E 'gpu|pvr|mali' | while read -r n; do echo "    $n: $(ls /proc/device-tree/$n 2>/dev/null | tr '\n' ' ' | cut -c1-300)"; for f in clock-frequency assigned-clock-rates operating-points; do [ -e "/proc/device-tree/$n/$f" ] && echo "      $f: $(hexdump -C /proc/device-tree/$n/$f 2>/dev/null | head -3 | tr -s ' ' | cut -c1-70)"; done; done
echo "  -- dmesg gpu lines --"; dmesg 2>/dev/null | grep -i -E 'pvr|rogue|mali|kbase|gpu' | head -20 | sed 's/^/    /'
REM

hr "13. SELF-CHECK"
echo "  SECTIONS EMITTED: $NSEC/14  (0..13)"
echo "  saved to: $OUT"
} 2>&1 | tee "$OUT"

# loud failure summary, after the tee so it is in the file too
if ! grep -q 'device ok:' "$OUT"; then echo "  !! DEVICE SECTIONS ARE EMPTY - the card was not reachable. Re-run when it is awake." | tee -a "$OUT"; fi
if ! grep -q 'container ok:' "$OUT"; then echo "  !! CONTAINER SECTIONS ARE EMPTY - start openmw_builder and re-run." | tee -a "$OUT"; fi
echo "  upload: $OUT"
