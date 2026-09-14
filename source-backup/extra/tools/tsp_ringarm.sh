#!/usr/bin/env bash
# TSP_RINGARM_V2 - put the ring profiler back into the launcher, safely, and arm a
# clean capture. Run this, confirm READY, play, then run tsp_pull2.sh.
#
#   bash ~/Downloads/tsp_ringarm.sh
#
# The launcher currently has the three original `unset OPENMW_TSP_RING*` lines at
# ~994-996: TSP_RINGARM_V1 is gone, so the profiler has been receiving nothing and
# falling back to compiled defaults - which is how it ended up at trigger_ms=0.0,
# meaning "arm on every frame". V2 makes that impossible from the launcher side:
#   - tsp_ring_off still works as the off switch (it takes the unset path)
#   - the trigger is validated to be a number >= 20 before export, so an empty or
#     junk value can never reach the profiler
#   - all three are EXPORTED, which V1 was not
#
# Rule Zero: file, not paste; r() uses -n, rin() takes the heredoc.

set -u

TSP="${TSP:-root@192.168.1.12}"
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6"
DL="${DL:-$HOME/Downloads}"
STAMP="$(date +%Y%m%d-%H%M%S)"
W="$DL/tsp-ringarm"; mkdir -p "$W"

EXP1=66a62043c74efebd83b3e496507ded72   # tsp_hitch.sh
EXP2=885f9c68d749282179e63223089fbf43   # tsp_hitch2.sh
EXPV=53f69f48273d488ad953037e1e73d58a   # tsp_vsync.sh

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }
die() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

r 'echo ok' >/dev/null 2>&1 || die "cannot reach the TSP at $TSP"

echo "########## 1. READERS ##########"
for pair in "tsp_hitch.sh $EXP1" "tsp_hitch2.sh $EXP2" "tsp_vsync.sh $EXPV"; do
    set -- $pair
    g="$(md5sum "$DL/$1" 2>/dev/null | cut -d' ' -f1)"
    [ "${g:-x}" = "$2" ] || die "$DL/$1 md5 ${g:-missing} != $2 - save the newest to $DL"
done
scp -q $SSH_OPTS "$DL/tsp_hitch.sh" "$DL/tsp_hitch2.sh" "$DL/tsp_vsync.sh" "$TSP:/mnt/SDCARD/" </dev/null \
    || die "reader scp failed"
for pair in "tsp_hitch.sh $EXP1" "tsp_hitch2.sh $EXP2" "tsp_vsync.sh $EXPV"; do
    set -- $pair
    d="$(r "md5sum /mnt/SDCARD/$1" | cut -d' ' -f1)"
    [ "$d" = "$2" ] || die "$1 landed as $d"
done
r 'chmod +x /mnt/SDCARD/tsp_hitch.sh /mnt/SDCARD/tsp_hitch2.sh /mnt/SDCARD/tsp_vsync.sh'
echo "VERIFIED: all three readers on device at the expected md5"

echo
echo "########## 2. LAUNCHER ARM BLOCK ##########"
LAUNCHER="$(r "for f in /mnt/SDCARD/Roms/PORTS/*.sh; do [ -f \"\$f\" ] && grep -q OPENMW_TSP_RING \"\$f\" && echo \"\$f\" && break; done")"
[ -n "$LAUNCHER" ] || die "no launcher under /mnt/SDCARD/Roms/PORTS mentions OPENMW_TSP_RING"
echo "launcher: $LAUNCHER"

if r "grep -q TSP_RINGARM_V2 '$LAUNCHER'"; then
    echo "TSP_RINGARM_V2 already present - not patching again"
else
    r "cp -p '$LAUNCHER' '$LAUNCHER.bak-ringarmv2-$STAMP'" || die "device backup failed"
    echo "backed up to $(basename "$LAUNCHER").bak-ringarmv2-$STAMP"
    scp -q $SSH_OPTS "$TSP:$LAUNCHER" "$W/launcher.sh" </dev/null || die "scp down failed"

    python3 - "$W/launcher.sh" <<'PYEOF' || die "patch refused; device untouched"
import hashlib, sys
p = sys.argv[1]
src = open(p, encoding='utf-8', errors='surrogateescape').read()

ANCHOR = ("unset OPENMW_TSP_RING\n"
          "unset OPENMW_TSP_RING_TRIGGER_MS\n"
          "unset OPENMW_TSP_RING_MAX_DUMPS\n")

BLOCK = """# TSP_RINGARM_V2 - restored 2026-09-11. V1 was lost and the launcher had reverted to
# the three unset lines, so the profiler ran on compiled defaults: trigger 0, meaning
# it armed a capture on EVERY frame. Everything below refuses to export a junk value.
if [ -f /mnt/SDCARD/tsp_ring_off ]; then
    unset OPENMW_TSP_RING
    unset OPENMW_TSP_RING_TRIGGER_MS
    unset OPENMW_TSP_RING_MAX_DUMPS
    echo "TSP_RINGARM_V2 disabled by /mnt/SDCARD/tsp_ring_off" >> /mnt/SDCARD/tsp_prog.txt
else
    if [ -f /mnt/SDCARD/tsp_ring.conf ]; then . /mnt/SDCARD/tsp_ring.conf; fi
    case "${TSP_RING_TRIG:-}" in ''|*[!0-9]*) TSP_RING_TRIG=60 ;; esac
    case "${TSP_RING_MAX:-}"  in ''|*[!0-9]*) TSP_RING_MAX=12 ;; esac
    if [ "$TSP_RING_TRIG" -lt 20 ] 2>/dev/null; then TSP_RING_TRIG=60; fi
    if [ "$TSP_RING_MAX" -lt 1 ] 2>/dev/null;  then TSP_RING_MAX=12; fi
    export OPENMW_TSP_RING=/mnt/SDCARD/tsp_ring
    export OPENMW_TSP_RING_TRIGGER_MS="$TSP_RING_TRIG"
    export OPENMW_TSP_RING_MAX_DUMPS="$TSP_RING_MAX"
    echo "TSP_RINGARM_V2 armed trigger=$TSP_RING_TRIG max=$TSP_RING_MAX out=/mnt/SDCARD/tsp_ring" >> /mnt/SDCARD/tsp_prog.txt
fi
"""

n = src.count(ANCHOR)
print('anchor (the three unset lines) matched: %d (must be 1)' % n)
if n != 1:
    for i, line in enumerate(src.splitlines(), 1):
        if 'OPENMW_TSP_RING' in line:
            print('  %5d: %s' % (i, line))
    sys.exit(1)

out = src.replace(ANCHOR, BLOCK, 1)
before, after = len(src.splitlines()), len(out.splitlines())
checks = [
    ('marker present once',       out.count('TSP_RINGARM_V2 armed') == 1),
    ('off switch preserved',      out.count('/mnt/SDCARD/tsp_ring_off') == 2),
    ('all three exported',        out.count('export OPENMW_TSP_RING') == 3),
    ('trigger validated',         "case \"${TSP_RING_TRIG:-}\"" in out),
    ('unset path kept',           out.count('unset OPENMW_TSP_RING\n') == 1),
    ('line delta matches the block',
                                  after - before == len(BLOCK.splitlines()) - len(ANCHOR.splitlines())),
    ('nothing else moved',        src.replace(ANCHOR, '', 1) == out.replace(BLOCK, '', 1)),
]
bad = False
for label, ok in checks:
    print('      %-4s %s' % ('OK' if ok else 'FAIL', label))
    bad = bad or not ok
if bad:
    print('INVARIANT FAILED - untouched'); sys.exit(1)
open(p, 'w', encoding='utf-8', errors='surrogateescape').write(out)
print('patched locally, md5 %s, %d -> %d lines' % (hashlib.md5(out.encode('utf-8','surrogateescape')).hexdigest(), before, after))
PYEOF

    bash -n "$W/launcher.sh" || die "patched launcher fails bash -n; device untouched"
    echo "bash -n: patched launcher is valid"
    scp -q $SSH_OPTS "$W/launcher.sh" "$TSP:$LAUNCHER" </dev/null || die "scp up failed"
    r "chmod +x '$LAUNCHER'"
fi
r "grep -q 'TSP_RINGARM_V2 armed' '$LAUNCHER'" || die "marker absent after deploy - do NOT play"
echo "VERIFIED: TSP_RINGARM_V2 is in the launcher"

echo
echo "########## 3. CLEAN CAPTURE STATE ##########"
rin "STAMP=$STAMP sh -s" <<'REMOTE'
S=/mnt/SDCARD
G=$S/data/ports/openmw

A="$S/tsp_hitch_archive_$STAMP"; n=0
for d in "$S"/tsp_ring.[0-9]*; do
    [ -f "$d" ] || continue
    mkdir -p "$A"; cp -p "$d" "$A/" && rm -f "$d" && n=$((n + 1))
done
echo "dumps archived: $n"

if [ -f "$S/tsp_ring_off" ]; then
    mv "$S/tsp_ring_off" "$S/tsp_ring_off.parked-$STAMP"
    echo "off switch parked (profiler now enabled)"
fi
printf 'TSP_RING_TRIG=60\nTSP_RING_MAX=12\n' > "$S/tsp_ring.conf"

if [ -s "$G/openmw_log.txt" ]; then
    mv "$G/openmw_log.txt" "$G/openmw_log.txt.pre-$STAMP"
    echo "log rotated"
fi
sync

echo
echo "########## READY CHECK ##########"
F=0
L="$S/Roms/PORTS/Morrowind.sh"
if grep -q 'TSP_RINGARM_V2 armed' "$L" 2>/dev/null; then echo "  OK   arm block in launcher"; else echo "  FAIL arm block missing"; F=1; fi
if [ -f "$S/tsp_ring_off" ]; then echo "  FAIL tsp_ring_off present - profiler off"; F=1; else echo "  OK   profiler enabled"; fi
if ls "$S"/tsp_ring.[0-9]* >/dev/null 2>&1; then echo "  FAIL dumps present"; F=1; else echo "  OK   all dump slots free"; fi
if [ -s "$G/openmw_log.txt" ]; then echo "  FAIL log not empty"; F=1; else echo "  OK   log clean"; fi
echo "  OK   conf: $(tr '\n' ' ' < "$S/tsp_ring.conf")"
for f in tsp_hitch.sh tsp_hitch2.sh tsp_vsync.sh; do
    echo "  OK   $f $(md5sum "$S/$f" | cut -d' ' -f1)"
done
echo
if [ "$F" -eq 0 ]; then echo "READY"; else echo "NOT READY - do not spend a play session"; fi
REMOTE

echo
echo "=================================================================="
echo "1. Launch 'Morrowind' from your menu."
echo "2. Play 15-20 min in the exteriors where it hitches. Cross cells,"
echo "   turn around, get in a fight."
echo "3. Quit THROUGH THE MENU so the logs flush."
echo "4. bash ~/Downloads/tsp_pull2.sh"
echo "=================================================================="
echo
echo "If the framerate is bad again, quit immediately and run:"
echo "   ssh -n root@192.168.1.12 'touch /mnt/SDCARD/tsp_ring_off'"
echo "That one command disables the profiler with no other change."
