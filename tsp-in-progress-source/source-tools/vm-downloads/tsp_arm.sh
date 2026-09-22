#!/usr/bin/env bash
# TSP_ARM_V1 - arm everything needed for one measured play session, per working
# agreement 27. Run from the VM:   bash ~/Downloads/tsp_arm.sh
#
# WHY THIS IS A FILE AND NOT A PASTE
# ----------------------------------
# Pasted as `bash <<'EOF' ... EOF`, the script itself arrives on stdin. Any ssh
# invoked without -n reads stdin, and it swallows the remainder of the script -
# silently, with no error and no output. That killed two deliveries. In a file the
# script is not on stdin, and every ssh below that does not take a heredoc also
# passes -n, so the failure cannot recur either way.

set -u

TSP="${TSP:-root@192.168.1.12}"
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6"
DL="${DL:-$HOME/Downloads}"
W="$DL/tsp-fpsavg-v2"
LUA=/mnt/SDCARD/data/ports/openmw/mods/TSPPerformance/scripts/TSPPerformance/dynamic_view.lua
STAMP="$(date +%Y%m%d-%H%M%S)"
EXP1=66a62043c74efebd83b3e496507ded72
EXP2=885f9c68d749282179e63223089fbf43
SRC_MD5=c45bb6c10e08caec16c7714132ebd021

mkdir -p "$W"

# -n: no stdin. Use for every command-string ssh.
r()  { ssh -n $SSH_OPTS "$TSP" "$@"; }
# no -n: stdin is the caller's heredoc.
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }

die() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

r 'echo ok' >/dev/null 2>&1 || die "cannot reach the TSP at $TSP"

echo "########## 1. WHY THE RING NEVER DUMPS ##########"
rin 'sh -s' <<'REMOTE'
G=/mnt/SDCARD/data/ports/openmw
LAUNCHER=/mnt/SDCARD/Roms/PORTS/Morrowind_51.sh
echo "-- launcher ring block: are these EXPORTED or plain assignments? --"
if [ -f "$LAUNCHER" ]; then
    grep -n -B2 -A6 'OPENMW_TSP_RING' "$LAUNCHER" | head -40
else
    echo "launcher not at $LAUNCHER; searching"
    grep -rln 'OPENMW_TSP_RING' /mnt/SDCARD/Roms/PORTS/ 2>/dev/null | head -5
fi
echo
echo "-- does the game process actually see them? --"
echo "(if the game is not running this prints nothing, which is expected)"
for p in /proc/[0-9]*; do
    if [ -r "$p/cmdline" ] && tr '\0' ' ' < "$p/cmdline" 2>/dev/null | grep -q 'openmw-0.51'; then
        echo "pid ${p#/proc/}:"
        tr '\0' '\n' < "$p/environ" 2>/dev/null | grep '^OPENMW_TSP_RING' || echo "  NO OPENMW_TSP_RING* IN ENVIRONMENT"
    fi
done
echo
echo "-- the profiler's own markers in the last log --"
printf 'TSP_RING_ARM lines:  %s\n' "$(grep -ac 'TSP_RING_ARM'  "$G/openmw_log.txt" 2>/dev/null; true)"
printf 'TSP_RING_DUMP lines: %s\n' "$(grep -ac 'TSP_RING_DUMP' "$G/openmw_log.txt" 2>/dev/null; true)"
grep -a 'TSP_RING' "$G/openmw_log.txt" 2>/dev/null | head -6
echo
echo "-- is the profiler in the binary at all --"
printf 'marker strings: %s\n' "$(strings "$G/bin/openmw-0.51" 2>/dev/null | grep -c 'TSP_RING_DUMP\|TSP_PROF_RUSAGE_V4'; true)"
printf 'binary: %s bytes\n' "$(wc -c < "$G/bin/openmw-0.51" 2>/dev/null; true)"
REMOTE

echo
echo "########## 2. PATCH THE LUA ##########"
if r "grep -q TSP_FPSAVG_V2 '$LUA'"; then
    echo "already patched on device"
else
    r "cp -p '$LUA' '$LUA.before-fpsavgv2-$STAMP'" || die "device backup failed"
    echo "backed up to $LUA.before-fpsavgv2-$STAMP"
    scp -q $SSH_OPTS "$TSP:$LUA" "$W/dynamic_view.lua" </dev/null || die "scp down failed"

    SRC_MD5="$SRC_MD5" python3 - "$W/dynamic_view.lua" <<'PYEOF' || die "patch refused; device untouched"
import hashlib, os, sys
p = sys.argv[1]
src = open(p, encoding='utf-8').read()
h = hashlib.md5(src.encode()).hexdigest()
want = os.environ['SRC_MD5']
if h != want:
    print('source md5 %s does not match the analysed file %s' % (h, want)); sys.exit(1)

ANCHOR = ("    if weightSum <= 0.0 then\n"
          "        smoothFps = rawFps\n"
          "    else\n"
          "        smoothFps = sum / weightSum\n"
          "    end\n\n"
          "    return smoothFps\n")
INSERT = ("    if weightSum <= 0.0 then\n"
          "        smoothFps = rawFps\n"
          "    else\n"
          "        smoothFps = sum / weightSum\n"
          "    end\n\n"
          "    -- TSP_FPSAVG_V2 - a confirmed drop must not be averaged away. The trimmed mean\n"
          "    -- above deliberately ignores a single bad second, which is what stopped the\n"
          "    -- flicker; but it also ignored two bad seconds for several more, holding the\n"
          "    -- far plane long through real load. The better of the last two samples is a\n"
          "    -- ceiling: one bad second still moves nothing, two move immediately.\n"
          "    if count >= 2 then\n"
          "        local confirmed = fpsWindow[1]\n"
          "        if fpsWindow[2] > confirmed then confirmed = fpsWindow[2] end\n"
          "        if confirmed < smoothFps then smoothFps = confirmed end\n"
          "    end\n\n"
          "    return smoothFps\n")

n = src.count(ANCHOR)
print('anchor matches: %d (must be 1)' % n)
if n != 1:
    sys.exit(1)
out = src.replace(ANCHOR, INSERT, 1)

checks = [
    ('283 -> 294 lines',        len(src.splitlines()) == 283 and len(out.splitlines()) == 294),
    ('marker present once',     out.count('TSP_FPSAVG_V2') == 1),
    ('ceiling is the BETTER of the last two',
                                out.count('if fpsWindow[2] > confirmed then') == 1),
    ('trim loop untouched',     out.count('for i = 1, count do') == src.count('for i = 1, count do')),
    ('constants unchanged',     all(s in out for s in ('WINDOW_SAMPLES = 5', 'WEIGHT_DECAY = 0.80',
                                                       'TRIM_WORST = 1', 'LOW_FPS = 17.0',
                                                       'HIGH_FPS = 40.0'))),
    ('TSP_DIAG_FPS still true', out.count('TSP_DIAG_FPS = true') == 1),
    ('log tag unchanged',       out.count('TSP_DYNVIEW_V37MAP') == src.count('TSP_DYNVIEW_V37MAP')),
]
bad = False
for label, ok in checks:
    print('      %-4s %s' % ('OK' if ok else 'FAIL', label))
    bad = bad or not ok
if bad:
    sys.exit(1)
open(p, 'w', encoding='utf-8').write(out)
print('patched locally, md5 %s' % hashlib.md5(out.encode()).hexdigest())
PYEOF

    scp -q $SSH_OPTS "$W/dynamic_view.lua" "$TSP:$LUA" </dev/null || die "scp up failed"
fi
r "grep -q TSP_FPSAVG_V2 '$LUA'" || die "marker absent after deploy - do NOT play"
echo "VERIFIED: TSP_FPSAVG_V2 is live on the device"

echo
echo "########## 3. READERS, HARD md5 GATE ##########"
G1="$(md5sum "$DL/tsp_hitch.sh"  2>/dev/null | cut -d' ' -f1)"
G2="$(md5sum "$DL/tsp_hitch2.sh" 2>/dev/null | cut -d' ' -f1)"
[ "${G1:-none}" = "$EXP1" ] || die "tsp_hitch.sh md5 ${G1:-missing} != $EXP1 - save the newest to $DL"
[ "${G2:-none}" = "$EXP2" ] || die "tsp_hitch2.sh md5 ${G2:-missing} != $EXP2 - save the newest to $DL"
echo "VERIFIED: local reader md5s match"
scp -q $SSH_OPTS "$DL/tsp_hitch.sh" "$DL/tsp_hitch2.sh" "$TSP:/mnt/SDCARD/" </dev/null || die "reader scp failed"
D1="$(r 'md5sum /mnt/SDCARD/tsp_hitch.sh'  | cut -d' ' -f1)"
D2="$(r 'md5sum /mnt/SDCARD/tsp_hitch2.sh' | cut -d' ' -f1)"
[ "$D1" = "$EXP1" ] || die "tsp_hitch.sh landed as $D1"
[ "$D2" = "$EXP2" ] || die "tsp_hitch2.sh landed as $D2"
echo "VERIFIED: readers landed intact on the device"

echo
echo "########## 4. EMPTY THE INSTRUMENT, ROTATE THE LOG ##########"
rin "STAMP=$STAMP sh -s" <<'REMOTE'
G=/mnt/SDCARD/data/ports/openmw
S=/mnt/SDCARD
chmod +x "$S/tsp_hitch.sh" "$S/tsp_hitch2.sh"

A="$S/tsp_hitch_archive_$STAMP"
n=0
for d in "$S"/tsp_ring.[0-9]*; do
    [ -f "$d" ] || continue
    mkdir -p "$A"
    cp -p "$d" "$A/" && rm -f "$d" && n=$((n + 1))
done
echo "dumps archived: $n"

if [ -s "$G/openmw_log.txt" ]; then
    mv "$G/openmw_log.txt" "$G/openmw_log.txt.pre-$STAMP"
    echo "log rotated to openmw_log.txt.pre-$STAMP"
else
    echo "log already empty"
fi

printf 'TSP_RING_TRIG=60\nTSP_RING_MAX=12\n' > "$S/tsp_ring.conf"
if [ -f "$S/tsp_ring_off" ]; then
    mv "$S/tsp_ring_off" "$S/tsp_ring_off.was-set-$STAMP"
    echo "profiler re-enabled"
fi
sync

echo
echo "########## READY CHECK ##########"
FAILED=0
L="$G/mods/TSPPerformance/scripts/TSPPerformance/dynamic_view.lua"
if grep -q TSP_FPSAVG_V2 "$L"; then
    echo "  OK   fix live ($(wc -l < "$L") lines)"
else
    echo "  FAIL fix NOT live"; FAILED=1
fi
if ls "$S"/tsp_ring.[0-9]* >/dev/null 2>&1; then
    echo "  FAIL dumps still present - ring will fill early"; FAILED=1
else
    echo "  OK   all 12 dump slots free"
fi
if [ -s "$G/openmw_log.txt" ]; then
    echo "  FAIL log not empty - analysis would mix old samples"; FAILED=1
else
    echo "  OK   log clean"
fi
if [ -f "$S/tsp_ring_off" ]; then
    echo "  FAIL tsp_ring_off present - profiler disabled"; FAILED=1
else
    echo "  OK   profiler enabled"
fi
echo "  OK   armed: $(tr '\n' ' ' < "$S/tsp_ring.conf")"
echo "  OK   readers: $(md5sum "$S/tsp_hitch.sh" | cut -d' ' -f1)"
echo
if [ "$FAILED" -eq 0 ]; then
    echo "READY"
else
    echo "NOT READY - do not spend a play session"
fi
REMOTE

echo
echo "Send section 1 back before playing. If the launcher assigns OPENMW_TSP_RING"
echo "without export, no play session can produce a dump and that is a one-line fix"
echo "to make first."
