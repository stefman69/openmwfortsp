#!/usr/bin/env bash
# pull-visgrid-perf.sh
#
# The V11 sensor prints a full status line once per second while it is armed.
# This pulls those lines, plus everything needed to interpret them, and then
# SUMMARISES them per interior episode so you can see at a glance whether the
# curtain is actually rejecting anything.
#
# Read-only. Changes nothing on the device.
set -Eeuo pipefail

if [ -f "$HOME/Downloads/visgrid-tools/device.env" ]; then
    # shellcheck disable=SC1091
    . "$HOME/Downloads/visgrid-tools/device.env" || true
fi
if [ -n "${TSP_IP:-}" ]; then DEV="root@$TSP_IP"; else DEV="${TSP_DEV:-root@192.168.1.25}"; fi

R="/mnt/SDCARD/data/ports/openmw51"
MOD="$R/mods/TSPInteriorVisGrid"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Downloads/visgrid-perf-$STAMP.txt"
RAW="$HOME/Downloads/visgrid-perf-$STAMP.status.txt"

{
echo "########## VISGRID PERF PULL - $(date) ##########"
ssh "$DEV" 'hostname; date' || true

echo
echo "########## SECTION 1: WHAT IS INSTALLED ##########"
ssh "$DEV" "
echo -n 'active sensor      : '
if grep -Fq 'TSP_VISGRID_V11_LOADSAFE_12S' '$MOD/scripts/TSPInteriorVisGrid/visgrid.lua'; then
    echo 'V11a (load-safe hold present)'
elif grep -Fq 'TSP_INTERIOR_VISGRID_LUA_V11' '$MOD/scripts/TSPInteriorVisGrid/visgrid.lua'; then
    echo 'V11 stock (NO hold)'
else
    echo 'other - see marker below'
    grep -o 'TSP_INTERIOR_VISGRID_LUA_V[0-9A-Za-z]*' '$MOD/scripts/TSPInteriorVisGrid/visgrid.lua' | head -1
fi
echo -n 'interiormap.lua    : '
if [ -s '$MOD/scripts/TSPInteriorVisGrid/interiormap.lua' ]; then
    echo \"present (\$(grep -c 'cap' '$MOD/scripts/TSPInteriorVisGrid/interiormap.lua') cap entries)\"
else
    echo 'MISSING'
fi
echo -n 'scan summary       : '
tail -1 '$R/tsp_interior_scan.txt' 2>/dev/null || echo 'no scan file'
echo
echo 'engine markers in binary:'
for m in TSP_INTERIOR_VISGRID_051_V1 TSP_INTERIOR_VISGRID_051_V3_PERCENTILE_FOG TSP_INTERIOR_SCAN_051_V1; do
    if grep -a -q \"\$m\" '$R/bin/openmw-0.51'; then echo \"  YES \$m\"; else echo \"  no  \$m\"; fi
done
echo
sha256sum '$R/bin/openmw-0.51' '$MOD/scripts/TSPInteriorVisGrid/visgrid.lua' 2>/dev/null || true
" || true

echo
echo "########## SECTION 2: WHICH CELLS THE MAP ACTUALLY COVERS ##########"
ssh "$DEV" "
if [ -s '$MOD/scripts/TSPInteriorVisGrid/interiormap.lua' ]; then
    grep -oE \"\\['[^']+'\\]\" '$MOD/scripts/TSPInteriorVisGrid/interiormap.lua' | tr -d \"[]'\" | head -40
    echo '  ... (first 40 shown)'
else
    echo '  no interiormap.lua on the card'
fi
" || true

echo
echo "########## SECTION 3: SESSION TIMELINE ##########"
ssh "$DEV" "grep -aE 'onLoad ->|onInit ->|load-safe hold|interior map loaded|no interior map|enter interior|exit interior|\\] map:|reset reason|disarm|sensor DISABLED|onFrame ERROR|TSP_LOAD_FREEZE|TSP_WARMDRAW_GATE|TSP_INTERIOR_VISGRID_051_V1 active|PERCENTILE_FOG active|exited with code' '$R/openmw_051_log.txt' 2>/dev/null | tail -120" || true

echo
echo "########## SECTION 4: RAW STATUS LINES (last 200) ##########"
ssh "$DEV" "grep -a 'TSP_VISGRID_V11\\] min=' '$R/openmw_051_log.txt' 2>/dev/null | tail -200" || true

echo
echo "########## SECTION 5: PERF FILE ##########"
ssh "$DEV" "[ -f '$R/openmw51_perf_latest.txt' ] && tail -60 '$R/openmw51_perf_latest.txt' || echo '  (no perf file)'" || true

echo
echo "########## SECTION 6: CRASH TAIL ##########"
ssh "$DEV" "[ -f /mnt/SDCARD/tsp_crash.txt ] && tail -60 /mnt/SDCARD/tsp_crash.txt || echo '  (no crash file)'" || true

echo "########## SECTIONS EMITTED: 6 ##########"
} 2>&1 | tee "$OUT"

# ---- local summary of the status lines --------------------------------------
grep -a 'TSP_VISGRID_V11\] min=' "$OUT" > "$RAW" || true

echo
echo "=================================================================="
echo "SUMMARY OF THE STATUS LINES"
echo "=================================================================="
python3 - "$RAW" <<'PYSUM'
import sys, re, statistics

path = sys.argv[1]
rows = []
for line in open(path, encoding='utf-8', errors='replace'):
    kv = dict(re.findall(r'([A-Za-z_]+)=([0-9.]+)', line))
    if 'min' in kv and 'reject' in kv:
        rows.append(kv)

if not rows:
    print("No status lines found.")
    print()
    print("That means the sensor never printed while armed. Either it never")
    print("armed (still inside the 12s load-safe hold, or you were never in an")
    print("interior), or the log was rotated. PRINT_PERIOD is 1.0s, so an armed")
    print("sensor produces one line per second.")
    raise SystemExit(0)

def col(name, cast=float):
    return [cast(r[name]) for r in rows if name in r]

def stat(name, unit=''):
    v = col(name)
    if not v:
        print("  %-14s (absent)" % name); return
    print("  %-14s min=%-9.1f mean=%-9.1f max=%-9.1f%s"
          % (name, min(v), statistics.fmean(v), max(v), unit))

print("status lines: %d  (~%d seconds of armed time)" % (len(rows), len(rows)))
print()
print("THE NUMBER THAT MATTERS - how much the curtain is rejecting:")
stat('reject', ' %')
rej = col('reject')
buckets = [(0,1),(1,10),(10,25),(25,50),(50,75),(75,101)]
print("  distribution:")
for lo, hi in buckets:
    n = sum(1 for x in rej if lo <= x < hi)
    if n:
        print("    %3d-%3d%% : %-4d %s" % (lo, hi, n, '#' * min(50, n)))
print()
print("PUBLISHED DEPTHS (what the engine is allowed to draw per tile):")
for k in ('min', 'mean', 'max', 'cap', 'fogq'):
    stat(k)
print()
print("SENSOR HEALTH (all of these must be non-zero and cast_fail must be 0):")
for k in ('cast_attempts', 'cast_ok', 'hits', 'cast_fail', 'dir_fail', 'len_fail',
          'known', 'planes', 'budget'):
    stat(k)
print()
mapv = col('map')
if mapv:
    on = sum(1 for x in mapv if x >= 1)
    print("interior map in use on %d/%d lines (map=1 means this cell had a map entry)"
          % (on, len(mapv)))
print()
print("HOW TO READ THIS")
print("  reject near 0%       -> the curtain is publishing OPEN depths and culling")
print("                        nothing; any slowdown is not VISGRID's to fix yet.")
print("  reject 60-90%        -> the curtain is working as it did in the V1 proof.")
print("  cap == 6200         -> no map entry for this cell (unknown = wide open).")
print("  fogq far below max  -> dense fog close in; that is the visual change,")
print("                        and it costs fill rate whether or not culling helps.")
PYSUM

echo
echo "Full pull : $OUT"
echo "Status raw: $RAW"
