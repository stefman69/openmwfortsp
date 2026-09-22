#!/usr/bin/env bash
# TSP_LOADRAMP_V2 - make the ramp visible, and show the diag dispatcher.
#
#   bash ~/Downloads/tsp_rampvis.sh
#
# The ramp's own log line said "action=..." which routes to TSP_DIAG_DYNVIEW (false),
# so it left no trace. The pre-existing TSP_DYNVIEW_STALL_V3 line routes to
# TSP_DIAG_STALL (also false), so a 23 s load frame logged nothing at all and there is
# no way to tell whether the ramp fired or whether the stall branch was even reached
# (a load while self.cell is nil, or into an interior, returns earlier).
#
# Two edits: route the ramp line through the "status" gate that IS enabled, and log
# every stall the same way so a non-firing branch is distinguishable from a silent one.
#
# Rule Zero: file, not paste; r() uses -n, rin() takes the heredoc (NEVER -n).

set -u
TSP="${TSP:-root@192.168.1.12}"
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6"
DL="${DL:-$HOME/Downloads}"
STAMP="$(date +%Y%m%d-%H%M%S)"
W="$DL/tsp-rampvis"; mkdir -p "$W"
LUA='/mnt/SDCARD/data/ports/openmw/mods/TSPPerformance/scripts/TSPPerformance/dynamic_view.lua'
SRC_MD5=00a2fbff945e5a9e08dce936b16cd5fd

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }
die() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

r 'echo ok' >/dev/null 2>&1 || die "cannot reach the TSP at $TSP"

echo "########## THE DIAG DISPATCHER, WHICH SWALLOWED BOTH LINES ##########"
rin "sh -s" <<REMOTE
awk 'NR <= 32 { printf "%3d  %s\n", NR, \$0 }' '$LUA'
REMOTE
echo

if r "grep -q 'status load_ramp_start' '$LUA'"; then
    echo "already visible - skipping the patch"
else
    r "cp -p '$LUA' '$LUA.before-rampvis-$STAMP'" || die "backup failed"
    echo "backed up to dynamic_view.lua.before-rampvis-$STAMP"
    scp -q $SSH_OPTS "$TSP:$LUA" "$W/dynamic_view.lua" </dev/null || die "scp down failed"

    SRC_MD5="$SRC_MD5" python3 - "$W/dynamic_view.lua" <<'PYEOF' || die "patch refused; device untouched"
import hashlib, os, sys
p = sys.argv[1]
src = open(p, encoding='utf-8').read(); orig = src
h = hashlib.md5(src.encode()).hexdigest()
if h != os.environ['SRC_MD5']:
    print('source md5 %s != %s' % (h, os.environ['SRC_MD5'])); sys.exit(1)

EDITS = [
    ("route-through-enabled-gate",
     "'[TSP_DYNVIEW_V37MAP] action=load_ramp_start stall=%.1f view=%.0f ramp=%.0f',",
     "'[TSP_DYNVIEW_V37MAP] status load_ramp_start stall=%.1f view=%.0f ramp=%.0f',"),
    ("log-every-stall",
     "        if RAMP_SECONDS > 0.0 and realDt >= LOAD_STALL_SECONDS then\n",
     "        -- TSP_LOADRAMP_V2 - the STALL_V3 line above goes through TSP_DIAG_STALL,\n"
     "        -- which is false, so a 23 s load frame left no trace and there was no way\n"
     "        -- to tell a ramp that did not fire from a branch never reached. This one\n"
     "        -- carries \"status\", the only gate that is enabled.\n"
     "        print(string.format(\n"
     "            '[TSP_DYNVIEW_V37MAP] status stall_seen sim_dt=%.3f wall_dt=%.3f view=%.0f',\n"
     "            dt, realDt, stallView\n"
     "        ))\n"
     "\n"
     "        if RAMP_SECONDS > 0.0 and realDt >= LOAD_STALL_SECONDS then\n"),
]
ok = True
for label, a, rp in EDITS:
    n = src.count(a)
    print('      %-4s %-26s matches=%d' % ('OK' if n == 1 else 'FAIL', label, n))
    if n != 1:
        ok = False; continue
    src = src.replace(a, rp, 1)
if not ok:
    print('--- survey ---')
    for i, l in enumerate(orig.splitlines(), 1):
        if 'load_ramp_start' in l or 'LOAD_STALL_SECONDS' in l or 'stallView' in l:
            print('  %4d: %s' % (i, l))
    print('NO WRITE'); sys.exit(1)

checks = [
    ('ramp line on the status gate', src.count("status load_ramp_start") == 1),
    ('no action= ramp line left',    "action=load_ramp_start" not in src),
    ('stall_seen added once',        src.count('status stall_seen') == 1),
    ('ramp condition still there',   src.count('RAMP_SECONDS > 0.0 and realDt >= LOAD_STALL_SECONDS') == 1),
    ('fpsavg v2 intact',             src.count('if fpsWindow[2] > confirmed then') == 1),
    ('loadramp intact',              src.count('TSP_LOADRAMP_V1') == 3),
    ('constants untouched',          all(s in src for s in ('RAMP_SECONDS = 20.0',
                                         'RAMP_START_VIEW = 3000.0', 'LOAD_STALL_SECONDS = 2.0'))),
]
bad = False
for label, good in checks:
    print('      %-4s %s' % ('OK' if good else 'FAIL', label)); bad = bad or not good
if bad:
    print('INVARIANT FAILED - device untouched'); sys.exit(1)
open(p, 'w', encoding='utf-8').write(src)
print('patched: %d -> %d lines, md5 %s'
      % (len(orig.splitlines()), len(src.splitlines()), hashlib.md5(src.encode()).hexdigest()))
PYEOF

    if command -v lua5.3 >/dev/null 2>&1; then
        lua5.3 -e 'local c,e=loadfile("'"$W"'/dynamic_view.lua") if not c then io.stderr:write(tostring(e).."\n") os.exit(1) end print("lua5.3: compiles OK")' || die "does not compile"
    else
        echo "(no lua on this VM; compiled under lua5.3 before delivery)"
    fi
    scp -q $SSH_OPTS "$W/dynamic_view.lua" "$TSP:$LUA" </dev/null || die "scp up failed"
fi

r "grep -q 'status load_ramp_start' '$LUA'" || die "marker absent after deploy"
r "grep -q 'status stall_seen' '$LUA'"      || die "stall_seen absent after deploy"
echo
echo "VERIFIED on device:"
r "md5sum '$LUA'; printf 'lines: '; wc -l < '$LUA'; grep -n 'status load_ramp_start\|status stall_seen' '$LUA'"

echo
echo "########## CLEAN CAPTURE ##########"
rin "STAMP=$STAMP sh -s" <<'REMOTE'
S=/mnt/SDCARD; G=$S/data/ports/openmw
A="$S/tsp_hitch_archive_$STAMP"; n=0
for d in "$S"/tsp_ring.[0-9]*; do
    [ -f "$d" ] || continue
    mkdir -p "$A"; cp -p "$d" "$A/" && rm -f "$d" && n=$((n+1))
done
echo "dumps archived: $n"
touch "$S/tsp_ktxwarm_off"
if [ -f "$S/tsp_ring_off" ]; then mv "$S/tsp_ring_off" "$S/tsp_ring_off.parked-$STAMP"; fi
if [ -s "$G/openmw_log.txt" ]; then mv "$G/openmw_log.txt" "$G/openmw_log.txt.pre-$STAMP"; fi
sync
F=0
L="$G/mods/TSPPerformance/scripts/TSPPerformance/dynamic_view.lua"
grep -q 'status load_ramp_start' "$L" && echo "  OK   ramp line visible" || { echo "  FAIL"; F=1; }
grep -q 'status stall_seen' "$L" && echo "  OK   stall logging visible" || { echo "  FAIL"; F=1; }
[ -f "$S/tsp_ring_off" ] && { echo "  FAIL profiler off"; F=1; } || echo "  OK   profiler enabled"
ls "$S"/tsp_ring.[0-9]* >/dev/null 2>&1 && { echo "  FAIL dumps present"; F=1; } || echo "  OK   dump slots free"
[ -s "$G/openmw_log.txt" ] && { echo "  FAIL log not empty"; F=1; } || echo "  OK   log clean"
[ "$F" -eq 0 ] && echo "READY" || echo "NOT READY"
REMOTE

echo
echo "Load a save into an exterior, play 60-90 s, quit, then BOTH of these:"
echo "  bash ~/Downloads/tsp_prun.sh"
echo "  ssh -n $TSP \"grep -a 'stall_seen\\|load_ramp_start' /mnt/SDCARD/data/ports/openmw/openmw_log.txt\""
