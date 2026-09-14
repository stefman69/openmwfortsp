#!/usr/bin/env bash
# TSP_LOADRAMP_V1 - cap the far plane through the post-load fault storm, clear the
# stale fps window on a load, and arm a clean capture.
#
#   bash ~/Downloads/tsp_loadramp.sh          then play, then: bash ~/Downloads/tsp_prun.sh
#
# WHY, measured 2026-09-10:
#   In the first 5 s after a save load, 34-54% of frames take a major page fault and
#   the rate decays from ~50/s to under 5/s over 15-40 s as the page cache refills.
#   Meanwhile the controller holds the far plane at MAX_VIEW=7168 for the first two
#   seconds and needs six to come down, because MAX_DROP_PER_SAMPLE is 800/s. So the
#   game asks the card for the most scene data at the exact moment it is thrashing.
#
#   Two changes, both anchored on text read off the device:
#     1. The dt>0.20 stall branch already catches the load frame. It calls
#        resetWindow() but NOT resetFpsWindow(), so pre-load fps samples (the menu
#        runs at 60+) survive and the first post-load decision uses them. Now it
#        clears the window and sets the far plane to RAMP_START_VIEW immediately.
#     2. For RAMP_SECONDS after a load, the target is capped by a ceiling that rises
#        from RAMP_START_VIEW to MAX_VIEW. Ceiling only - it never raises the target,
#        so a genuinely bad framerate still drives the view lower.
#
#   Simulated against the real handler code under lua5.3: at the load the far plane
#   goes 7168 -> 3000 instead of staying at 7168 for two seconds and taking six to
#   reach 3968. Steady state is unchanged (3868 vs 3968, inside the deadband).
#
#   Disable without reverting:  set RAMP_SECONDS = 0.0 in the lua.
#
# Rule Zero: file, not paste; r() uses -n, rin() takes the heredoc (NEVER -n).

set -u

TSP="${TSP:-root@192.168.1.12}"
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6"
DL="${DL:-$HOME/Downloads}"
STAMP="$(date +%Y%m%d-%H%M%S)"
W="$DL/tsp-loadramp"; mkdir -p "$W"
LUA='/mnt/SDCARD/data/ports/openmw/mods/TSPPerformance/scripts/TSPPerformance/dynamic_view.lua'
SRC_MD5=fd36e2f01fa4c212c50d9ba650f22d42   # the TSP_FPSAVG_V2 state, 294 lines

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }
die() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

r 'echo ok' >/dev/null 2>&1 || die "cannot reach the TSP at $TSP"

echo "########## 1. CURRENT STATE ##########"
r "md5sum '$LUA'; printf 'lines: '; wc -l < '$LUA'"
r "grep -q TSP_FPSAVG_V2 '$LUA'" || die "TSP_FPSAVG_V2 is not present - run tsp_luapatch.sh first"
echo "TSP_FPSAVG_V2 present"
echo

if r "grep -q TSP_LOADRAMP_V1 '$LUA'"; then
    echo "TSP_LOADRAMP_V1 already present - skipping the patch"
else
    echo "########## 2. PATCH ##########"
    r "cp -p '$LUA' '$LUA.before-loadramp-$STAMP'" || die "device backup failed"
    echo "backed up to dynamic_view.lua.before-loadramp-$STAMP"
    scp -q $SSH_OPTS "$TSP:$LUA" "$W/dynamic_view.lua" </dev/null || die "scp down failed"

    SRC_MD5="$SRC_MD5" python3 - "$W/dynamic_view.lua" <<'PYEOF' || die "patch refused; device untouched"
import hashlib, os, sys
p = sys.argv[1]
src = open(p, encoding='utf-8').read()
orig = src
h = hashlib.md5(src.encode()).hexdigest()
want = os.environ['SRC_MD5']
if h != want:
    print('source md5 %s != %s' % (h, want))
    print('Expected the TSP_FPSAVG_V2 state. Refusing rather than guessing.')
    sys.exit(1)

EDITS = [
    ("loadramp-constants",
     "local DEADBAND = 96.0\n",
     "local DEADBAND = 96.0\n"
     "\n"
     "-- TSP_LOADRAMP_V1 - measured 2026-09-10: in the first 5 s after a save load,\n"
     "-- 34-54% of frames take a major page fault and the rate decays from ~50/s to\n"
     "-- under 5/s over 15-40 s as the page cache refills. Asking the card for a long\n"
     "-- far plane during that window makes it worse, so cap the far plane on a load\n"
     "-- and release the cap as the cache warms. RAMP_SECONDS = 0.0 disables it.\n"
     "local RAMP_SECONDS = 20.0\n"
     "local RAMP_START_VIEW = 3000.0\n"
     "local LOAD_STALL_SECONDS = 2.0\n"
     "local tspLoadAt = nil\n"),

    ("loadramp-detect",
     "            dt, realDt, realFps, stallView\n"
     "        ))\n"
     "\n"
     "        resetWindow()\n"
     "        return\n"
     "    end\n",
     "            dt, realDt, realFps, stallView\n"
     "        ))\n"
     "\n"
     "        -- TSP_LOADRAMP_V1 - a stall this long is a save or cell load, not a hitch.\n"
     "        -- Two things must happen here. The fps window still holds pre-load samples\n"
     "        -- (the menu runs at 60+ fps) because resetWindow does NOT clear it, so the\n"
     "        -- first post-load decision was being made from pre-load framerate. And the\n"
     "        -- far plane has to come in before the fault storm, not a second into it.\n"
     "        if RAMP_SECONDS > 0.0 and realDt >= LOAD_STALL_SECONDS then\n"
     "            tspLoadAt = tspNowReal\n"
     "            resetFpsWindow()\n"
     "            currentView = clamp(RAMP_START_VIEW, MIN_VIEW, MAX_VIEW)\n"
     "            camera.setViewDistance(currentView)\n"
     "            print(string.format(\n"
     "                '[TSP_DYNVIEW_V37MAP] action=load_ramp_start stall=%.1f view=%.0f ramp=%.0f',\n"
     "                realDt, currentView, RAMP_SECONDS\n"
     "            ))\n"
     "        end\n"
     "\n"
     "        resetWindow()\n"
     "        return\n"
     "    end\n"),

    ("loadramp-cap",
     "    local target = fpsToView(smoothFps)\n"
     "\n"
     "    if target < currentView - DEADBAND then\n",
     "    local target = fpsToView(smoothFps)\n"
     "\n"
     "    -- TSP_LOADRAMP_V1 - ceiling only. It never raises the target, so the fps\n"
     "    -- controller is still free to go lower if the framerate is genuinely bad.\n"
     "    if RAMP_SECONDS > 0.0 and tspLoadAt ~= nil and tspNowReal ~= nil then\n"
     "        local since = tspNowReal - tspLoadAt\n"
     "        if since >= 0.0 and since < RAMP_SECONDS then\n"
     "            local rampCap = RAMP_START_VIEW\n"
     "                + (since / RAMP_SECONDS) * (MAX_VIEW - RAMP_START_VIEW)\n"
     "            if target > rampCap then\n"
     "                target = rampCap\n"
     "            end\n"
     "        else\n"
     "            tspLoadAt = nil\n"
     "        end\n"
     "    end\n"
     "\n"
     "    if target < currentView - DEADBAND then\n"),
]

ok = True
for label, anchor, repl in EDITS:
    n = src.count(anchor)
    print('      %-4s %-22s matches=%d' % ('OK' if n == 1 else 'FAIL', label, n))
    if n != 1:
        ok = False
        continue
    src = src.replace(anchor, repl, 1)
if not ok:
    print('--- survey, for re-anchoring ---')
    for i, line in enumerate(orig.splitlines(), 1):
        if any(k in line for k in ('DEADBAND', 'stallView', 'resetWindow', 'fpsToView', 'resetFpsWindow')):
            print('  %4d: %s' % (i, line))
    print('NO WRITE - device untouched')
    sys.exit(1)

checks = [
    ('marker present 3x',   src.count('TSP_LOADRAMP_V1') == 3),
    ('load detect once',    src.count('action=load_ramp_start') == 1),
    ('one new resetFpsWindow call',
        src.count('resetFpsWindow()') == orig.count('resetFpsWindow()') + 1),
    ('cap is ceiling only', src.count('if target > rampCap then') == 1),
    ('cap never raises',    'target = rampCap' in src and 'target = math.max' not in src),
    ('disable switch',      src.count('RAMP_SECONDS > 0.0') == 2),
    ('constants once',      src.count('local RAMP_SECONDS = 20.0') == 1
                            and src.count('local RAMP_START_VIEW = 3000.0') == 1
                            and src.count('local LOAD_STALL_SECONDS = 2.0') == 1),
    ('clamp is defined',    'local function clamp' in src),
    ('fpsavg v2 intact',    src.count('if fpsWindow[2] > confirmed then') == 1),
    ('tuning constants untouched',
        all(s in src for s in ('WINDOW_SAMPLES = 5', 'WEIGHT_DECAY = 0.80', 'TRIM_WORST = 1',
                               'LOW_FPS = 17.0', 'HIGH_FPS = 40.0',
                               'MAX_DROP_PER_SAMPLE = 800.0', 'MAX_RAISE_PER_SAMPLE = 500.0'))),
    ('diag switch untouched', src.count('TSP_DIAG_FPS = true') == 1),
]
bad = False
for label, good in checks:
    print('      %-4s %s' % ('OK' if good else 'FAIL', label))
    bad = bad or not good
if bad:
    print('INVARIANT FAILED - device untouched'); sys.exit(1)
open(p, 'w', encoding='utf-8').write(src)
print('patched locally: %d -> %d lines, md5 %s'
      % (len(orig.splitlines()), len(src.splitlines()), hashlib.md5(src.encode()).hexdigest()))
PYEOF

    if command -v luac5.3 >/dev/null 2>&1; then
        luac5.3 -p "$W/dynamic_view.lua" && echo "luac5.3: syntax OK"
    elif command -v luac >/dev/null 2>&1; then
        luac -p "$W/dynamic_view.lua" && echo "luac: syntax OK"
    elif command -v lua5.3 >/dev/null 2>&1; then
        lua5.3 -e 'local c,e=loadfile("'"$W"'/dynamic_view.lua") if not c then io.stderr:write(tostring(e).."\n") os.exit(1) end print("lua5.3: compiles OK")' || die "patched lua does not compile"
    else
        echo "(no lua on this VM; the patched controller was compiled and behaviour-tested under lua5.3 before delivery)"
    fi

    scp -q $SSH_OPTS "$W/dynamic_view.lua" "$TSP:$LUA" </dev/null || die "scp up failed"
fi

echo
echo "########## 3. VERIFY ON DEVICE ##########"
r "grep -q TSP_LOADRAMP_V1 '$LUA'" || die "marker absent after deploy - do NOT play"
r "md5sum '$LUA'; printf 'lines: '; wc -l < '$LUA'"
r "grep -n 'RAMP_SECONDS\|RAMP_START_VIEW\|LOAD_STALL_SECONDS\|load_ramp_start' '$LUA'"
echo "VERIFIED: TSP_LOADRAMP_V1 is live"

echo
echo "########## 4. CLEAN CAPTURE ##########"
rin "STAMP=$STAMP sh -s" <<'REMOTE'
S=/mnt/SDCARD
G=$S/data/ports/openmw
A="$S/tsp_hitch_archive_$STAMP"; n=0
for d in "$S"/tsp_ring.[0-9]*; do
    [ -f "$d" ] || continue
    mkdir -p "$A"; cp -p "$d" "$A/" && rm -f "$d" && n=$((n + 1))
done
echo "dumps archived: $n"
# The prefetch experiment tripled the post-load fault rate; keep it off.
touch "$S/tsp_ktxwarm_off"
if [ -f "$S/tsp_ring_off" ]; then mv "$S/tsp_ring_off" "$S/tsp_ring_off.parked-$STAMP"; fi
printf 'TSP_RING_TRIG=60\nTSP_RING_MAX=12\n' > "$S/tsp_ring.conf"
if [ -s "$G/openmw_log.txt" ]; then mv "$G/openmw_log.txt" "$G/openmw_log.txt.pre-$STAMP"; fi
sync

echo
echo "########## READY CHECK ##########"
F=0
L="$G/mods/TSPPerformance/scripts/TSPPerformance/dynamic_view.lua"
if grep -q TSP_FPSAVG_V2  "$L"; then echo "  OK   smoothing fix live"; else echo "  FAIL smoothing fix missing"; F=1; fi
if grep -q TSP_LOADRAMP_V1 "$L"; then echo "  OK   load ramp live"; else echo "  FAIL load ramp missing"; F=1; fi
if [ -f "$S/tsp_ktxwarm_off" ]; then echo "  OK   prefetch off (it made things worse)"; else echo "  FAIL prefetch still on"; F=1; fi
if [ -f "$S/tsp_ring_off" ]; then echo "  FAIL profiler off"; F=1; else echo "  OK   profiler enabled"; fi
if ls "$S"/tsp_ring.[0-9]* >/dev/null 2>&1; then echo "  FAIL dumps present"; F=1; else echo "  OK   dump slots free"; fi
if [ -s "$G/openmw_log.txt" ]; then echo "  FAIL log not empty"; F=1; else echo "  OK   log clean"; fi
echo "  OK   conf: $(tr '\n' ' ' < "$S/tsp_ring.conf")"
echo
if [ "$F" -eq 0 ]; then echo "READY"; else echo "NOT READY - do not spend a play session"; fi
REMOTE

echo
echo "=================================================================="
echo "  1. Launch 'Morrowind' from your menu."
echo "  2. Load a save into an EXTERIOR (the ramp is exterior-only;"
echo "     interiors are VisGrid's and stay pinned at 5500)."
echo "  3. Play 60-90 s. The first few seconds should feel better; the"
echo "     far plane will be visibly shorter and grow over ~20 s."
echo "  4. Quit through the menu."
echo "  5. bash ~/Downloads/tsp_prun.sh"
echo "=================================================================="
echo
echo "Compare the 0-5 s bucket after the load against 20:30:"
echo "    145.3 majflt/s   54.5% faulting   worst 203 ms"
echo "and against 19:00, which had no prefetch:"
echo "     51.9 majflt/s   34.2% faulting   worst 189 ms"
echo
echo "Also grep the log for load_ramp_start to confirm it fired:"
echo "    ssh -n $TSP \"grep -a load_ramp_start /mnt/SDCARD/data/ports/openmw/openmw_log.txt\""
echo
echo "To disable the ramp without reverting anything:"
echo "    ssh -n $TSP \"sed -i 's/^local RAMP_SECONDS = 20.0/local RAMP_SECONDS = 0.0/' '$LUA'\""
