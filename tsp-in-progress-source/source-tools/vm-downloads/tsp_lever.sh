#!/bin/sh
# tsp_lever.sh - TSP_LEVER_V1: the last shared lever, as one tool.
#
#   build                    ONCE (host+container): patch gl4es with TSP_VBO_ORPHAN_V4, rebuild
#                            (full build output), export the lib to ~/Downloads/libGL.so.1.orphan
#   apply                    PER CARD: deploy that lib (backup kept) + patch the launcher with
#                            TSP_LEVER_V1 = TSP_HYGIENE_V1 + TSP_GPUCLOCK_V1 + LIBGL_TSP_ORPHAN=1
#   check                    PER CARD: proof lines + fps / view / draw numbers from the last session,
#                            appended to ~/Downloads/tsp-lever-ab-<name>.txt so A/B rows pile up
#   off [orphan] [gpuclock] [hygiene]
#                            PER CARD: switch levers off via $GAMEDIR/tsp_lever_policy.txt (no rebuild,
#                            no redeploy - the launcher reads it every launch). Bare "off" = all three.
#   on                       PER CARD: remove the policy file (all three on)
#   revert                   PER CARD: put back the launcher and libGL.so.1 that apply backed up
#
# Run:  bash ~/Downloads/tsp_lever.sh build && sh ~/Downloads/tsp_net.sh each tsp_lever.sh apply
#       ...play a session on each card...
#       sh ~/Downloads/tsp_net.sh each tsp_lever.sh check
# Per card by hand:  TSP=root@192.168.1.12 TSP_NAME=tsps sh ~/Downloads/tsp_lever.sh apply
#
if [ "$(head -c 400 "$0" | tr -d -c '\r' | wc -c | tr -d ' ')" != 0 ]; then T=/tmp/tsp_lever.$$; tr -d '\r' < "$0" > "$T"; exec sh "$T" "$@"; fi # absorbs a trailing CR
set -u
MODE="${1:-}"; [ $# -gt 0 ] && shift
case "$MODE" in build|apply|check|off|on|revert) ;; *) sed -n 2,19p "$0"; exit 2 ;; esac

TSP="${TSP:-${TSP_DEV:-}}"
if [ -z "${TSP}" ] && [ -r "$HOME/.tsp_dev" ]; then TSP="$(cat "$HOME/.tsp_dev")"; fi
[ -n "${TSP}" ] || TSP="root@192.168.1.12"
[ -n "${TSP_NAME:-}" ] || TSP_NAME="$(awk -F'\t' -v h="$TSP" '$2==h {print $1}' "$HOME/.tsp_hosts" 2>/dev/null | head -1)"
NAME="${TSP_NAME:-unnamed}"
STAMP="$(date +%Y%m%d-%H%M%S)"
SSHO="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o LogLevel=ERROR"
CONT="openmw_builder"
G="/mnt/SDCARD/data/ports/openmw"
L="/mnt/SDCARD/Roms/PORTS/Morrowind.sh"
LIB="$HOME/Downloads/libGL.so.1.orphan"
MARK="TSP_VBO_ORPHAN_V4"
say() { printf '%s\n' "$*"; }
hr()  { printf '\n########## %s ##########\n' "$*"; }
die() { say "  !! $*"; exit 1; }
# remote runner: body on stdin -> base64 -> file on the card -> sh, stdin closed (busybox-safe)
rin() {
  _b64="$(base64 | tr -d '\n')"
  ssh -n $SSHO "$TSP" "T=/tmp/tsp_lv.\$\$
printf '%s' '$_b64' | base64 -d > \"\$T\" 2>/dev/null || { echo '  (no base64 on this device)'; exit 1; }
sh \"\$T\" </dev/null
_r=\$?
rm -f \"\$T\"
exit \$_r" 2>&1
}

# =============================================================================== build
if [ "$MODE" = build ]; then
  hr "BUILD 1/4  patch gl4es in $CONT  ($STAMP)"
  command -v docker >/dev/null 2>&1 || die "docker not on PATH"
  docker ps --format '{{.Names}}' | grep -q "^${CONT}$" || die "container $CONT is not running (docker start $CONT)"
  docker exec -i "$CONT" python3 - <<'PY'
import re, sys, subprocess, time, shutil
R = '/root/gl4es-tsps/'
S = R + 'src/gl/'
def rd(f): return open(S + f).read()
def one(s, pat, rep, f, n=1):
    out, c = re.subn(pat, rep, s, flags=re.M)
    if c != n: sys.exit('PATCH ABORT %s: anchor matched %dx, expected %d: %r' % (f, c, n, pat[:80]))
    return out

# 1. Restore the three files to pristine HEAD, undoing any V1/V2/V3 (including their fpe.c hook).
#    The recon git status showed buffers.c / buffers.h / fpe.c carried NO TSP change before the
#    orphan work, so HEAD is genuinely pristine for them.
RESTORE = ('buffers.c', 'buffers.h', 'fpe.c', 'listdraw.c')
r = subprocess.run(['git', '-C', R, 'checkout', '--'] + ['src/gl/' + f for f in RESTORE],
                   capture_output=True, text=True)
if r.returncode != 0: sys.exit('PATCH ABORT: git checkout failed: ' + r.stderr.strip())
for f in RESTORE:
    if 'TSP_VBO_ORPHAN' in rd(f): sys.exit('PATCH ABORT: %s still carries an orphan marker after restore' % f)
print('  restored %s to pristine HEAD (removed any V1/V2/V3)' % ', '.join(RESTORE))

c = rd('buffers.c')
if 'TSP_VBO_ORPHAN_V4' in c:
    print('  buffers.c already carries TSP_VBO_ORPHAN_V4 - not patching again'); sys.exit(0)

helpers = r"""
/* TSP_VBO_ORPHAN_V4 - immediate, whole-buffer orphaning of dynamic vertex VBOs.
 * When LIBGL_TSP_ORPHAN=1, every glBufferSubData into a real ARRAY_BUFFER is turned
 * into a full glBufferData(size, shadow, usage): the driver hands back FRESH backing
 * storage (an "orphan"), so the CPU never has to wait for the GPU to finish reading
 * the bytes being overwritten. On a tiler (Mali / PowerVR) in single-threaded mode
 * that wait is what serialises the frame.
 *   gl4es already keeps a complete CPU shadow of every buffer (buff->data), updated
 * by the memcpy at the end of glBufferSubData, so re-specifying from it preserves
 * every byte OSG has ever written - including sub-arrays it did NOT touch this frame
 * (static texcoords next to animated positions). That completeness is why V4 renders
 * correctly. V1/V2/V3 deferred the upload to draw time, which raced the batch path
 * and any draw that skipped the flush, so the GPU read half-updated buffers - the
 * smooth NPCs, single-colour flags, black-until-distant walls and dead water.
 * Element buffers are never touched. Off unless the env var is exactly "1". */
static int tsp_orphan_on(void) {
    static int v = -1;
    if (v < 0) { const char* e = getenv("LIBGL_TSP_ORPHAN"); v = (e && e[0] == '1') ? 1 : 0; }
    return v;
}
static void tsp_orphan_report(long sz) {
    static unsigned long n = 0, kb = 0;
    kb += (unsigned long)(sz >> 10);
    if ((++n & 0xffff) == 1) {   /* first respec, then every 65536 */
        printf("TSP_VBO_ORPHAN_V4 on=1 (immediate whole-buffer orphan; supersedes V1/V2/V3) respec=%lu kb=%lu\n", n, kb);
        fflush(stdout);
    }
}

"""
c = one(c, r'^//#define DEBUG\n#ifdef DEBUG\n', lambda m: helpers.lstrip('\n') + m.group(0), 'buffers.c')

# glBufferSubData: ARRAY_BUFFER writes become a full orphaning glBufferData from the shadow.
c = one(c,
    r'''^([ \t]*)if\(\(target==GL_ARRAY_BUFFER \|\| target==GL_ELEMENT_ARRAY_BUFFER\) && buff->real_buffer\) \{
[ \t]*LOAD_GLES\(glBufferSubData\);
[ \t]*LOAD_GLES\(glBindBuffer\);
[ \t]*bindBuffer\(target, buff->real_buffer\);
[ \t]*gles_glBufferSubData\(target, offset, size, data\);
[ \t]*\}
''',
    r'''\1if((target==GL_ARRAY_BUFFER || target==GL_ELEMENT_ARRAY_BUFFER) && buff->real_buffer) {
\1    if(target==GL_ARRAY_BUFFER && tsp_orphan_on()) {   /* TSP_VBO_ORPHAN_V4 */
\1        LOAD_GLES(glBufferData);
\1        LOAD_GLES(glBindBuffer);
\1        memcpy((char*)buff->data + offset, data, size);   /* bring the shadow current first */
\1        bindBuffer(target, buff->real_buffer);
\1        gles_glBufferData(target, buff->size, buff->data, buff->usage);
\1        tsp_orphan_report(size);
\1        noerrorShim();
\1        return;
\1    }
\1    LOAD_GLES(glBufferSubData);
\1    LOAD_GLES(glBindBuffer);
\1    bindBuffer(target, buff->real_buffer);
\1    gles_glBufferSubData(target, offset, size, data);
\1}
''', 'buffers.c')

# glNamedBufferSubData: same, keyed on buff->type.
c = one(c,
    r'''^([ \t]*)if\(\(buff->type==GL_ARRAY_BUFFER \|\| buff->type==GL_ELEMENT_ARRAY_BUFFER\) && buff->real_buffer\) \{
[ \t]*LOAD_GLES\(glBufferSubData\);
[ \t]*LOAD_GLES\(glBindBuffer\);
[ \t]*bindBuffer\(buff->type, buff->real_buffer\);
[ \t]*gles_glBufferSubData\(buff->type, offset, size, data\);
[ \t]*\}
''',
    r'''\1if((buff->type==GL_ARRAY_BUFFER || buff->type==GL_ELEMENT_ARRAY_BUFFER) && buff->real_buffer) {
\1    if(buff->type==GL_ARRAY_BUFFER && tsp_orphan_on()) {   /* TSP_VBO_ORPHAN_V4 (named twin) */
\1        LOAD_GLES(glBufferData);
\1        LOAD_GLES(glBindBuffer);
\1        memcpy((char*)buff->data + offset, data, size);
\1        bindBuffer(buff->type, buff->real_buffer);
\1        gles_glBufferData(buff->type, buff->size, buff->data, buff->usage);
\1        tsp_orphan_report(size);
\1        noerrorShim();
\1        return;
\1    }
\1    LOAD_GLES(glBufferSubData);
\1    LOAD_GLES(glBindBuffer);
\1    bindBuffer(buff->type, buff->real_buffer);
\1    gles_glBufferSubData(buff->type, offset, size, data);
\1}
''', 'buffers.c')

shutil.copy2(S + 'buffers.c', S + 'buffers.c.before-orphan4-' + time.strftime('%Y%m%d-%H%M%S'))
open(S + 'buffers.c', 'w').write(c)
print('  patched buffers.c with TSP_VBO_ORPHAN_V4 (buffers.h and fpe.c left pristine)')
PY
  [ $? -eq 0 ] || die "gl4es patch aborted - nothing was written, read the ABORT line above"
  docker exec "$CONT" bash -c 'cd /root/gl4es-tsps && echo "  -- diffstat --" && git diff --stat -- src/gl/buffers.c && echo "  -- marker lines --" && grep -n TSP_VBO_ORPHAN_V4 src/gl/buffers.c | sed "s/^/  /"'

  hr "BUILD 2/4  rebuild gl4es (full output; also saved to ~/Downloads/tsp-lever-build-$STAMP.txt)"
  OLDMD5="$(docker exec "$CONT" md5sum /root/gl4es-tsps/lib/libGL.so.1 2>/dev/null | cut -c1-32)"
  say "  lib before: md5=$OLDMD5"
  docker exec "$CONT" bash -c 'export MAKEFLAGS=-j4; bash /root/rebuild_gl4es_tsps_o3.sh' 2>&1 | tee "$HOME/Downloads/tsp-lever-build-$STAMP.txt"

  hr "BUILD 3/4  gate: which built libGL.so.1 carries $MARK"
  PICK=""
  for f in /root/gl4es-tsps/lib/libGL.so.1 /root/gl4es-tsps-export-o3/libGL.so.1; do
    n="$(docker exec "$CONT" sh -c "grep -a -c $MARK $f 2>/dev/null"; true)"
    m="$(docker exec "$CONT" sh -c "md5sum $f 2>/dev/null | cut -c1-32"; true)"
    say "  $f  marker=$n md5=$m  $(docker exec "$CONT" sh -c "ls -la $f 2>/dev/null | awk '{print \$5, \$6, \$7, \$8}'")"
    [ -z "$PICK" ] && [ "${n:-0}" -ge 1 ] 2>/dev/null && [ "$m" != "$OLDMD5" ] && PICK="$f"
  done
  [ -n "$PICK" ] || die "no freshly built libGL.so.1 carries $MARK - the build did not produce a new library. Read the build output above."
  docker cp -L "$CONT:$PICK" "$LIB" || die "docker cp failed"
  [ "$(grep -a -c "$MARK" "$LIB"; true)" -ge 1 ] 2>/dev/null || die "exported $LIB does not carry $MARK (symlink copied instead of the file?)"
  cp -f "$LIB" "$LIB-$STAMP"

  hr "BUILD 4/4  exported"
  say "  $LIB  md5=$(md5sum "$LIB" | cut -c1-32)  size=$(wc -c < "$LIB")  marker=$(grep -a -c "$MARK" "$LIB"; true)"
  say "  (copy kept as $LIB-$STAMP)"
  say "  next: sh ~/Downloads/tsp_net.sh each tsp_lever.sh apply"
  exit 0
fi

# ============================================================================ per-card
hr "$MODE on $NAME ($TSP)  $STAMP"
ssh -n $SSHO "$TSP" 'echo "  device ok: $(hostname) $(uname -r)"' 2>&1 || die "card not reachable"

if [ "$MODE" = apply ]; then
  # ---- 1. the library
  hr "APPLY 1/3  deploy libGL.so.1 to $NAME"
  [ -s "$LIB" ] || die "$LIB missing - run: bash ~/Downloads/tsp_lever.sh build"
  [ "$(grep -a -c "$MARK" "$LIB"; true)" -ge 1 ] 2>/dev/null || die "$LIB does not carry $MARK"
  LOCALMD5="$(md5sum "$LIB" | cut -c1-32)"
  ssh $SSHO "$TSP" "cat > $G/lib/libGL.so.1.new" < "$LIB" || die "upload failed"
  rin <<REM
G=$G; S=$STAMP; MARK=$MARK
cd \$G || { echo "  !! no \$G"; exit 1; }
[ "\$(md5sum lib/libGL.so.1.new | cut -c1-32)" = "$LOCALMD5" ] || { echo "  !! upload md5 mismatch"; rm -f lib/libGL.so.1.new; exit 1; }
mkdir -p backups
if [ "\$(grep -a -c TSP_VBO_ORPHAN lib/libGL.so.1 2>/dev/null)" = "0" ]; then cp -p lib/libGL.so.1 "backups/libGL.so.1.before-orphan-\$S"; echo "  backup: backups/libGL.so.1.before-orphan-\$S (pristine)"; else echo "  live lib is an orphan build (\$(grep -a -o 'TSP_VBO_ORPHAN_V[0-9]' lib/libGL.so.1 | sort -u | tr '\\n' ' ')) - the pristine backup is the older one, kept"; fi
mv -f lib/libGL.so.1.new lib/libGL.so.1 && chmod +x lib/libGL.so.1
echo "  deployed: \$(ls -la lib/libGL.so.1 | awk '{print \$5, \$6, \$7, \$8}')  md5=\$(md5sum lib/libGL.so.1 | cut -c1-32)  marker=\$(grep -a -c \$MARK lib/libGL.so.1)  env_string=\$(grep -a -c LIBGL_TSP_ORPHAN lib/libGL.so.1)"
ls backups/libGL.so.1.before-orphan-* 2>/dev/null | tail -2 | sed 's/^/  kept: /'
REM
  [ $? -eq 0 ] || die "library deploy failed on $NAME"

  # ---- 2. the launcher (edited on this machine, syntax-checked here and on the card, then swapped in)
  hr "APPLY 2/3  patch the launcher on $NAME with TSP_LEVER_V1"
  W="$HOME/Downloads/.tsp_lever_work"; mkdir -p "$W"
  ssh -n $SSHO "$TSP" "cat $L" > "$W/launcher.$NAME.orig" || die "could not read $L"
  say "  pulled $L: $(wc -l < "$W/launcher.$NAME.orig") lines md5=$(md5sum "$W/launcher.$NAME.orig" | cut -c1-32)"
  python3 - "$W/launcher.$NAME.orig" "$W/launcher.$NAME.new" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
if 'TSP_LEVER_V1' in s:
    print('  launcher already carries TSP_LEVER_V1 - not patching again'); open(dst, 'w').write(s); sys.exit(0)
def one(s, old, new, n=1):
    c = s.count(old)
    if c != n: sys.exit('LAUNCHER PATCH ABORT: anchor found %dx, expected %d: %r' % (c, n, old.strip()[:60]))
    return s.replace(old, new)

BLOCK = r'''
# =================== TSP_LEVER_V1 ===========================================
# Three levers that share one off-switch file, $GAMEDIR/tsp_lever_policy.txt:
#   orphan=off    do not export LIBGL_TSP_ORPHAN=1 (gl4es TSP_VBO_ORPHAN_V1 stays dormant)
#   gpuclock=off  leave the GPU clock / power policy alone
#   hygiene=off   leave the TrimUI daemons alone
# No file = all three on. Everything applied here is saved and put back on exit.
# Proof lines: TSP_VBO_ORPHAN_V1 / TSP_GPUCLOCK_V1 / TSP_HYGIENE_V1 in the log,
# one TSP_LEVER_V1 line per launch in /mnt/SDCARD/tsp_prog.txt.
TSP_HYG_SAVE="/tmp/tsp-hygiene.saved"
TSP_GPU_SAVE="/tmp/tsp-gpuclock.saved"
tsp_lever_policy() {
    if [ -r "$GAMEDIR/tsp_lever_policy.txt" ] && grep -q "^$1=off" "$GAMEDIR/tsp_lever_policy.txt" 2>/dev/null; then echo off; else echo on; fi
}
tsp_proc_nice() {
    _pp=$1; _s=$(cat /proc/$_pp/stat 2>/dev/null) || return 1
    _r=${_s##*) }; set -- $_r; echo "${17}"
}
tsp_proc_cpus() { grep Cpus_allowed_list /proc/$1/status 2>/dev/null | cut -f2; }

# TSP_HYGIENE_V1: the launcher UI and its daemons (trimui_osdd alone had 6151 CPU-s of
# uptime on the S) run at nice 0 on every core, including the one the game's main
# thread is pinned to. Pin them to the background mask, drop their priority, keep
# input responsive (trimui_inputd: pinned, not reniced) and give the FUSE exfat
# daemon that serves every asset read a small edge (-5) off the main core.
tsp_hygiene_apply() {
    if [ "$(tsp_lever_policy hygiene)" = off ]; then echo "TSP_HYGIENE_V1 off (policy)"; return 0; fi
    if [ -z "${TSP_CPU_BG_MASK:-}" ]; then echo "TSP_HYGIENE_V1 skipped (no background mask - CPU policy off or taskset rejected)"; return 0; fi
    command -v renice >/dev/null 2>&1 || { echo "TSP_HYGIENE_V1 skipped (no renice)"; return 0; }
    : > "$TSP_HYG_SAVE"
    _n=0
    for _spec in MainUI:10 keymon:10 trimui_scened:10 trimui_osdd:10 musicserver:10 hardwareservice:10 ledc:10 trimui_inputd:0 mount.exfat:-5; do
        _name=${_spec%%:*}; _adj=${_spec##*:}
        for _p in $(pidof "$_name" 2>/dev/null); do
            _on=$(tsp_proc_nice "$_p") || continue
            _om=$(taskset -p "$_p" 2>/dev/null | sed 's/.*: *//')
            [ -n "$_om" ] || continue
            printf '%s\t%s\t%s\t%s\n' "$_p" "$_name" "$_on" "$_om" >> "$TSP_HYG_SAVE"
            taskset -ap "$TSP_CPU_BG_MASK" "$_p" >/dev/null 2>&1 || true
            [ "$_adj" != 0 ] && { renice "$_adj" -p "$_p" >/dev/null 2>&1 || true; }
            _n=$((_n+1))
        done
    done
    echo "TSP_HYGIENE_V1 on bg_mask=$TSP_CPU_BG_MASK main_mask=${TSP_CPU_MAIN_MASK:-?} touched=$_n"
    while IFS="$(printf '\t')" read -r _p _name _on _om; do
        [ -n "$_p" ] || continue
        echo "  $_name pid=$_p nice=$(tsp_proc_nice "$_p") cpus=$(tsp_proc_cpus "$_p")  (was nice=$_on mask=$_om)"
    done < "$TSP_HYG_SAVE"
}
tsp_hygiene_restore() {
    [ -r "$TSP_HYG_SAVE" ] || return 0
    _n=0
    while IFS="$(printf '\t')" read -r _p _name _on _om; do
        [ -n "$_p" ] || continue
        [ "$(cat /proc/$_p/comm 2>/dev/null)" = "$_name" ] || continue
        taskset -ap "$_om" "$_p" >/dev/null 2>&1 || true
        renice "$_on" -p "$_p" >/dev/null 2>&1 || true
        _n=$((_n+1))
    done < "$TSP_HYG_SAVE"
    rm -f "$TSP_HYG_SAVE"
    echo "TSP_HYGIENE_V1 restored $_n daemon(s)"
}

# TSP_GPUCLOCK_V1: the S's Mali sits at 150 MHz of an 888 MHz range under
# simple_ondemand for its whole uptime; hold it at the top while the game runs
# (min_freq=max_freq, performance governor when offered, kbase power_policy
# always_on). The base TSP has no devfreq for the PowerVR; Allwinner's scenectrl
# node is the only runtime knob there and is tried if present. Saved + restored.
tsp_gpuclock_apply() {
    if [ "$(tsp_lever_policy gpuclock)" = off ]; then echo "TSP_GPUCLOCK_V1 off (policy)"; return 0; fi
    rm -f "$TSP_GPU_SAVE"
    _d=""; for _c in /sys/class/devfreq/*gpu*; do [ -e "$_c/cur_freq" ] && { _d=$_c; break; }; done
    if [ -n "$_d" ]; then
        _gov=$(cat $_d/governor 2>/dev/null); _min=$(cat $_d/min_freq 2>/dev/null); _max=$(cat $_d/max_freq 2>/dev/null)
        printf 'devfreq\t%s\t%s\t%s\n' "$_d" "$_gov" "$_min" >> "$TSP_GPU_SAVE"
        grep -qw performance $_d/available_governors 2>/dev/null && { echo performance > $_d/governor 2>/dev/null || true; }
        echo "$_max" > $_d/min_freq 2>/dev/null || true
        _pp=/sys/class/misc/mali0/device/power_policy
        if [ -w "$_pp" ]; then
            _old=$(sed 's/.*\[\(.*\)\].*/\1/' $_pp 2>/dev/null)
            printf 'mali_pp\t%s\t%s\n' "$_pp" "$_old" >> "$TSP_GPU_SAVE"
            echo always_on > $_pp 2>/dev/null || true
        fi
        sleep 1
        echo "TSP_GPUCLOCK_V1 on node=$_d gov=$(cat $_d/governor 2>/dev/null) min=$(cat $_d/min_freq 2>/dev/null) cur=$(cat $_d/cur_freq 2>/dev/null) max=$_max power_policy=$(cat $_pp 2>/dev/null | tr -d '\n')  (was gov=$_gov min=$_min)"
    elif [ -e /sys/devices/platform/gpu/scenectrl/command ]; then
        _sc=/sys/devices/platform/gpu/scenectrl
        _old=$(cat $_sc/command 2>/dev/null)
        printf 'scenectrl\t%s\t%s\n' "$_sc/command" "$_old" >> "$TSP_GPU_SAVE"
        echo 1 > $_sc/command 2>/dev/null || true
        echo "TSP_GPUCLOCK_V1 on scenectrl command=$(cat $_sc/command 2>/dev/null) status=$(cat $_sc/status 2>/dev/null)  (was $_old) nodes=[$(ls $_sc 2>/dev/null | tr '\n' ' ')]"
    else
        echo "TSP_GPUCLOCK_V1 skipped (no devfreq gpu node and no scenectrl on this card)"
    fi
}
tsp_gpuclock_restore() {
    [ -r "$TSP_GPU_SAVE" ] || return 0
    while IFS="$(printf '\t')" read -r _k _a _b _c; do
        case "$_k" in
            devfreq) [ -n "$_c" ] && { echo "$_c" > $_a/min_freq 2>/dev/null || true; }; [ -n "$_b" ] && { echo "$_b" > $_a/governor 2>/dev/null || true; } ;;
            mali_pp|scenectrl) [ -n "$_b" ] && { echo "$_b" > "$_a" 2>/dev/null || true; } ;;
        esac
    done < "$TSP_GPU_SAVE"
    rm -f "$TSP_GPU_SAVE"
    echo "TSP_GPUCLOCK_V1 restored"
}
tsp_lever_prelaunch() {
    echo "# TSP_LEVER_V1 ----------------------------------------------------"
    if [ "$(tsp_lever_policy orphan)" = off ]; then
        unset LIBGL_TSP_ORPHAN; echo "TSP_VBO_ORPHAN_V1 env off (policy)"
    else
        export LIBGL_TSP_ORPHAN=1
        echo "TSP_VBO_ORPHAN_V1 env on LIBGL_TSP_ORPHAN=1 lib_marker=$(grep -a -c TSP_VBO_ORPHAN_V1 "$GAMEDIR/lib/libGL.so.1" 2>/dev/null)"
    fi
    tsp_gpuclock_apply
    tsp_hygiene_apply
    echo "TSP_LEVER_V1 armed $(date '+%Y-%m-%d %H:%M:%S') orphan=$(tsp_lever_policy orphan) gpuclock=$(tsp_lever_policy gpuclock) hygiene=$(tsp_lever_policy hygiene) bg_mask=${TSP_CPU_BG_MASK:-none}" >> /mnt/SDCARD/tsp_prog.txt
}
tsp_lever_restore() { tsp_hygiene_restore; tsp_gpuclock_restore; }
# =================== end TSP_LEVER_V1 =======================================

'''
s = one(s, '\ntsp_cpu_apply_split() {\n', BLOCK + 'tsp_cpu_apply_split() {\n')
s = one(s, '\n    tsp_cpu_governor_boost\n', '\n    tsp_cpu_governor_boost\n    tsp_lever_prelaunch\n')
s = one(s, '\n    tsp_cpu_governor_restore 2>/dev/null || true\n', '\n    tsp_cpu_governor_restore 2>/dev/null || true\n    tsp_lever_restore 2>/dev/null || true\n')
s = one(s, '\n    OPENMW_EXIT_CODE=$?\n', '\n    OPENMW_EXIT_CODE=$?\n    tsp_lever_restore 2>/dev/null || true\n')
open(dst, 'w').write(s)
print('  patched: +%d lines, 4 anchors hit' % (s.count('\n') - open(src).read().count('\n')))
PY
  [ $? -eq 0 ] || die "launcher patch aborted on $NAME - nothing was pushed"
  bash -n "$W/launcher.$NAME.new" || die "patched launcher fails bash -n on this machine - not pushing"
  say "  bash -n ok here; anchors: $(grep -c 'tsp_lever_prelaunch\|tsp_lever_restore' "$W/launcher.$NAME.new") call sites"
  ssh $SSHO "$TSP" "cat > $L.new" < "$W/launcher.$NAME.new" || die "upload failed"
  NEWMD5="$(md5sum "$W/launcher.$NAME.new" | cut -c1-32)"
  rin <<REM
L=$L; S=$STAMP
[ "\$(md5sum \$L.new | cut -c1-32)" = "$NEWMD5" ] || { echo "  !! upload md5 mismatch"; rm -f \$L.new; exit 1; }
if /bin/bash -n \$L.new 2>/tmp/tsp_lv_syn.txt; then echo "  /bin/bash -n on the card: ok"; else echo "  !! /bin/bash -n on the card FAILED:"; sed 's/^/     /' /tmp/tsp_lv_syn.txt; rm -f \$L.new; exit 1; fi
if grep -q TSP_LEVER_V1 \$L; then echo "  live launcher already had TSP_LEVER_V1 - keeping its older backup"; else cp -p \$L \$L.before-lever-\$S; echo "  backup: \$L.before-lever-\$S"; fi
mv -f \$L.new \$L && chmod +x \$L
echo "  launcher now: \$(wc -l < \$L) lines md5=\$(md5sum \$L | cut -c1-32)  TSP_LEVER_V1=\$(grep -c TSP_LEVER_V1 \$L) prelaunch_call=\$(grep -c '^    tsp_lever_prelaunch\$' \$L) restore_calls=\$(grep -c 'tsp_lever_restore 2>/dev/null' \$L)"
ls \$L.before-lever-* 2>/dev/null | tail -2 | sed 's/^/  kept: /'
[ -f $G/tsp_lever_policy.txt ] && { echo "  policy file present:"; sed 's/^/     /' $G/tsp_lever_policy.txt; } || echo "  no policy file: orphan/gpuclock/hygiene all ON next launch"
REM
  [ $? -eq 0 ] || die "launcher swap failed on $NAME"

  hr "APPLY 3/3  $NAME ready"
  say "  Launch Morrowind on $NAME from the menu, play ~5-10 min in the usual exterior test spot, quit."
  say "  Then: sh ~/Downloads/tsp_net.sh each tsp_lever.sh check"
  exit 0
fi

if [ "$MODE" = off ]; then
  KEYS="$*"; [ -n "$KEYS" ] || KEYS="orphan gpuclock hygiene"
  rin <<REM
G=$G; touch \$G/tsp_lever_policy.txt
for k in $KEYS; do grep -q "^\$k=off" \$G/tsp_lever_policy.txt || echo "\$k=off" >> \$G/tsp_lever_policy.txt; done
echo "  policy now:"; sed 's/^/     /' \$G/tsp_lever_policy.txt
echo "  takes effect on the next launch (the launcher reads it each time)"
REM
  exit $?
fi

if [ "$MODE" = on ]; then
  rin <<REM
rm -f $G/tsp_lever_policy.txt && echo "  policy file removed: orphan/gpuclock/hygiene all ON next launch"
REM
  exit $?
fi

if [ "$MODE" = revert ]; then
  rin <<REM
G=$G; L=$L
b=\$(ls -t \$L.before-lever-* 2>/dev/null | head -1)
if [ -n "\$b" ]; then cp -p \$b \$L && chmod +x \$L && echo "  launcher restored from \$b (TSP_LEVER_V1=\$(grep -c TSP_LEVER_V1 \$L))"; else echo "  no launcher backup found"; fi
l=""; for f in \$(ls -t \$G/backups/libGL.so.1.before-orphan-* 2>/dev/null); do [ "\$(grep -a -c TSP_VBO_ORPHAN \$f)" = "0" ] && { l=\$f; break; }; done
if [ -n "\$l" ]; then cp -p \$l \$G/lib/libGL.so.1 && chmod +x \$G/lib/libGL.so.1 && echo "  libGL.so.1 restored from \$l (marker=\$(grep -a -c $MARK \$G/lib/libGL.so.1) md5=\$(md5sum \$G/lib/libGL.so.1 | cut -c1-32))"; else echo "  no libGL backup found"; fi
rm -f /tmp/tsp-hygiene.saved /tmp/tsp-gpuclock.saved
REM
  exit $?
fi

# ================================================================================ check
AB="$HOME/Downloads/tsp-lever-ab-$NAME.txt"
rin <<REM
G=$G; LOG=\$G/openmw_log.txt
echo "  -- what is deployed --"
ob=none; for _v in V1 V2 V3 V4; do [ "\$(grep -a -c TSP_VBO_ORPHAN_\$_v \$G/lib/libGL.so.1 2>/dev/null)" != 0 ] && ob=\$_v; done
echo "  libGL.so.1 orphan_build=\$ob md5=\$(md5sum \$G/lib/libGL.so.1 2>/dev/null | cut -c1-32)   launcher TSP_LEVER_V1=\$(grep -c TSP_LEVER_V1 $L 2>/dev/null)"
[ -f \$G/tsp_lever_policy.txt ] && { echo "  policy file:"; sed 's/^/     /' \$G/tsp_lever_policy.txt; } || echo "  policy: none (all on)"
echo "  -- last launch (tsp_prog.txt) --"; grep -a TSP_LEVER_V1 /mnt/SDCARD/tsp_prog.txt 2>/dev/null | tail -2 | sed 's/^/  /'
echo "  -- proof lines from the current openmw_log.txt (\$(ls -la \$LOG 2>/dev/null | awk '{print \$5, \$6, \$7, \$8}')) --"
grep -a -n 'TSP_VBO_ORPHAN_V\|TSP_GPUCLOCK_V1\|TSP_HYGIENE_V1\|TSP_LEVER_V1' \$LOG 2>/dev/null | head -24 | cut -c1-220 | sed 's/^/  /'
echo "  ... orphan counters at the end of the session:"; grep -a 'TSP_VBO_ORPHAN_V. on=1' \$LOG 2>/dev/null | tail -1 | sed 's/^/  /'
echo "  -- the numbers (this session, as the game logged them) --"
awk '
/raw_fps=/ { if (match(\$0,/raw_fps=[0-9.]+/)) { f=substr(\$0,RSTART+8,RLENGTH-8); nf++; sf+=f; if (f<15) lo++ }
             if (match(\$0,/ view=[0-9]+/))   { v=substr(\$0,RSTART+6,RLENGTH-6); nv++; sv+=v } }
/TSP_CULLDRAW/ { if (match(\$0,/render=[0-9.]+/)) { r=substr(\$0,RSTART+7,RLENGTH-7); nr++; sr+=r; if (r>100) hit++ }
                 if (match(\$0,/cull=[0-9.]+/))   { sc+=substr(\$0,RSTART+5,RLENGTH-5) }
                 if (match(\$0,/draw=[0-9.]+/))   { sd+=substr(\$0,RSTART+5,RLENGTH-5) }
                 if (match(\$0,/resid=[0-9.]+/))  { ss+=substr(\$0,RSTART+6,RLENGTH-6) } }
END {
  if (nf) printf "  fps     : mean raw_fps=%.2f over %d status lines, %d of them under 15 fps\n", sf/nf, nf, lo; else print "  fps     : no raw_fps lines (no play session in this log?)";
  if (nv) printf "  view    : mean view=%.0f (adaptive draw distance - a higher view at the same fps is also a win)\n", sv/nv;
  if (nr) printf "  culldraw: %d lines  mean render=%.1f cull=%.1f draw=%.1f resid=%.1f ms   render>100ms: %d\n", nr, sr/nr, sc/nr, sd/nr, ss/nr, hit; else print "  culldraw: no TSP_CULLDRAW lines";
  printf "AB\tfps=%.2f\tview=%.0f\tdraw=%.1f\tresid=%.1f\tswap_or_render=%.1f\thitch=%d\tn=%d\n", (nf?sf/nf:0), (nv?sv/nv:0), (nr?sd/nr:0), (nr?ss/nr:0), (nr?sr/nr:0), hit, nf
}' \$LOG 2>/dev/null
echo "  -- live state right now (only meaningful while the game is running) --"
gp=\$(pidof openmw-0.51 2>/dev/null | head -1)
if [ -n "\$gp" ]; then
  echo "  game pid \$gp: main thread cpus=\$(grep Cpus_allowed_list /proc/\$gp/status | cut -f2)"
  for n in MainUI keymon trimui_osdd trimui_scened trimui_inputd mount.exfat musicserver; do for p in \$(pidof \$n 2>/dev/null); do st=\$(cat /proc/\$p/stat); r=\${st##*) }; set -- \$r; echo "  \$n pid=\$p nice=\${17} cpus=\$(grep Cpus_allowed_list /proc/\$p/status | cut -f2)"; done; done
  for d in /sys/class/devfreq/*gpu*; do [ -e \$d/cur_freq ] && echo "  gpu devfreq: gov=\$(cat \$d/governor) cur=\$(cat \$d/cur_freq) min=\$(cat \$d/min_freq)"; done
  [ -e /sys/devices/platform/gpu/scenectrl/command ] && echo "  scenectrl: command=\$(cat /sys/devices/platform/gpu/scenectrl/command) status=\$(cat /sys/devices/platform/gpu/scenectrl/status 2>/dev/null)"
  echo "  thermal: \$(for t in /sys/class/thermal/thermal_zone*; do printf '%s=%s ' "\$(cat \$t/type)" "\$(cat \$t/temp)"; done)"
else
  echo "  game not running; MainUI nice=\$(for p in \$(pidof MainUI); do st=\$(cat /proc/\$p/stat); r=\${st##*) }; set -- \$r; echo \${17}; done | head -1) (0 = hygiene restored correctly)"
  for d in /sys/class/devfreq/*gpu*; do [ -e \$d/cur_freq ] && echo "  gpu devfreq now: gov=\$(cat \$d/governor) min=\$(cat \$d/min_freq) (simple_ondemand/150000000 = restored)"; done
fi
REM
# keep an A/B row per check so before/after rows line up in one file
ROW="$(rin <<REM
awk '/raw_fps=/{if(match(\$0,/raw_fps=[0-9.]+/)){nf++;sf+=substr(\$0,RSTART+8,RLENGTH-8)} if(match(\$0,/ view=[0-9]+/)){nv++;sv+=substr(\$0,RSTART+6,RLENGTH-6)}} /TSP_CULLDRAW/{if(match(\$0,/draw=[0-9.]+/)){nd++;sd+=substr(\$0,RSTART+5,RLENGTH-5)} if(match(\$0,/resid=[0-9.]+/)){ss+=substr(\$0,RSTART+6,RLENGTH-6)} if(match(\$0,/render=[0-9.]+/)&&substr(\$0,RSTART+7,RLENGTH-7)>100)h++} END{printf "fps=%.2f view=%.0f draw=%.1f resid=%.1f hitch>100ms=%d n=%d", (nf?sf/nf:0),(nv?sv/nv:0),(nd?sd/nd:0),(nd?ss/nd:0),h,nf}' $G/openmw_log.txt 2>/dev/null
printf '  levers=%s' "\$(grep -a 'TSP_LEVER_V1 armed' /mnt/SDCARD/tsp_prog.txt 2>/dev/null | tail -1 | sed 's/.*orphan=/orphan=/')"
REM
)"
printf '%s  %s  %s\n' "$STAMP" "$NAME" "$ROW" >> "$AB"
hr "A/B rows so far for $NAME  ($AB)"
sed 's/^/  /' "$AB"
