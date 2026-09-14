#!/usr/bin/env bash
# TSP_GAPDUMP_V1 - read what the engine already said during the 13.3 s gap.
#
#   bash ~/Downloads/tsp_gapdump.sh
#
# READ ONLY. No new run, no play session, nothing on the card is changed.
#
# ============================================================================
# WHY THIS COSTS NOTHING
# ============================================================================
# Both memsplit logs are still on the device, rotated, and OPENMW_DEBUG_LEVEL=INFO
# was on for both. So the engine logged whatever it did during the 13.3 s window,
# and nobody has looked at it. This slices the log between the two phase markers
# and reports what is in there.
#
# ============================================================================
# WHERE THE INVESTIGATION STANDS
# ============================================================================
# The ladder from two independent loads, agreeing to under 2%:
#
#   records-parsed                 +70,394 kB   68.7 MB   1.45 s    25.9%
#   mechanics-playerLoaded ->
#     projectile-casters-updated  +196,425 kB  191.8 MB  13.32 s    72.2%
#   everything else                 +5,189 kB    5.1 MB
#
# ELIMINATED:
#   textures        TSP_KTX 1 vs 0 -> 452480 vs 448633 kB. 3.8 MB. Not it.
#   save records    records-parsed is its OWN earlier phase at 68.7 MB, which
#                   matches the 09-09 reference of ~60 MB. Accounted for.
#   leak on foot    RSS flat for two minutes of walking (09-10 iowatch capture).
#   global-map cams pending_removal_cams never logged; globalmap_read_kb=4 vs
#                   3223 before the 09-09 fix. That fix works.
#   GPU driver      no /dev/mali mapping exists in the process at all.
#
# ALSO ESTABLISHED, and it is a correction to the project docs: TSP_RECORDMEM is
# listed in SHIP-STATE-switches-and-config-20260909.md but emits ZERO lines in the
# current binary. It is not compiled in any more. (The "1 line" the pull reported
# was my own bug - I grepped the whole raw file, which contains the conf section,
# so it matched my own "export TSP_RECORDMEM=1".)
#
# So the 191.8 MB is in a 13.3 s window with NO instrumentation inside it. What
# happens there is cell loading and scene construction. Rather than guess which
# knob, read what the engine logged.
#
# Rule Zero: file, not paste; r() uses -n, rin() takes the heredoc (NEVER -n).
# No grep -r. No $(grep -c x f || echo 0). No apostrophe inside any awk program.
# Output is hard-bounded: this log can be tens of thousands of lines.

set -u

TSP="${TSP:-root@192.168.1.12}"
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6"
DL="${DL:-$HOME/Downloads}"
STAMP="$(date +%Y%m%d-%H%M%S)"
REP="$DL/tsp-gapdump-$STAMP.txt"

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }
die() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

r 'echo ok' >/dev/null 2>&1 || die "cannot reach the TSP at $TSP"

rin 'sh -s' <<'REMOTE' 2>&1 | tee "$REP"
# ---- TSP_GAPDUMP_REMOTE_BEGIN ----
S=/mnt/SDCARD
G=$S/data/ports/openmw
OPEN=$G/openmw_log.txt
A=start
B=end

echo "########## 1. WHICH LOGS HAVE BOTH MARKERS ##########"
# Scoped to the game dir, maxdepth 1. Never the whole card.
CANDS=""
for f in "$OPEN" "$G"/openmw_log.txt.*; do
    [ -f "$f" ] || continue
    n1="$(grep -ac 'phase=mechanics-playerLoaded' "$f" 2>/dev/null; true)"
    n2="$(grep -ac 'phase=projectile-casters-updated' "$f" 2>/dev/null; true)"
    sz="$(stat -c '%s' "$f" 2>/dev/null)"
    if [ "${n1:-0}" -ge 1 ] && [ "${n2:-0}" -ge 1 ]; then
        printf '  USABLE  %-58s %9s bytes\n' "$(basename "$f")" "$sz"
        CANDS="$CANDS $f"
    else
        printf '  skip    %-58s %9s bytes  (markers %s/%s)\n' "$(basename "$f")" "$sz" "${n1:-0}" "${n2:-0}"
    fi
done
if [ -z "$CANDS" ]; then
    echo
    echo "NO LOG HAS BOTH MARKERS."
    echo "The memsplit runs rotated their logs; if they have since been deleted,"
    echo "re-run one load with: bash ~/Downloads/tsp_memsplit.sh a"
    exit 1
fi
echo

# Take the two most recent usable logs.
SET="$(for f in $CANDS; do echo "$f"; done | tail -2)"

for LG in $SET; do
echo "=================================================================="
echo " $(basename "$LG")"
echo "=================================================================="

awk '
/phase=mechanics-playerLoaded/     { if (!s) s = NR }
/phase=projectile-casters-updated/ { if (s && !e) e = NR }
END {
    if (!s || !e) { print "  markers not both found"; exit }
    printf "  gap is lines %d..%d  -> %d log lines inside the 13.3 s window\n", s, e, e - s - 1
}' "$LG"

# Slice once into a temp file in tmpfs, then read it several ways. One pass over
# the big log, not five.
awk '
/phase=mechanics-playerLoaded/     { if (!s) { s = 1; next } }
/phase=projectile-casters-updated/ { if (s) exit }
s { print }' "$LG" > /tmp/gap.$$
GN="$(wc -l < /tmp/gap.$$)"
echo "  sliced $GN lines"
if [ "${GN:-0}" -eq 0 ]; then
    echo "  NOTHING IS LOGGED IN THE GAP. 13.3 s and 191.8 MB with the engine"
    echo "  silent at INFO. That itself is the finding: the window needs new"
    echo "  trace points, which means a rebuild."
    rm -f /tmp/gap.$$
    echo
    continue
fi
echo

echo "  -- what is in there, ranked by line count --"
# Key on the message text after the [ts LEVEL] prefix, first three words, so
# free-text engine messages bucket together instead of one bucket per cell name.
awk '
{
    line = $0
    p = index(line, "] ")
    if (p) line = substr(line, p + 2)
    n = split(line, w, " ")
    k = w[1]
    if (n >= 2) k = k " " w[2]
    if (n >= 3) k = k " " w[3]
    gsub(/[0-9]+/, "N", k)
    c[k]++
}
END { for (k in c) printf "     %7d  %s\n", c[k], k }' /tmp/gap.$$ | sort -rn | head -25
echo

echo "  -- per-second histogram: where the 13.3 s actually goes --"
awk '
{
    if (match($0, /[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) {
        t = substr($0, RSTART, RLENGTH)
        c[t]++
        if (!(t in seen)) { seen[t] = 1; n++; ord[n] = t }
    }
}
END {
    if (!n) { print "     (no timestamps in the gap)"; exit }
    for (i = 1; i <= n; i++) {
        bar = ""
        b = int(c[ord[i]] / 20)
        if (b > 60) b = 60
        for (j = 0; j < b; j++) bar = bar "#"
        printf "     %s  %6d  %s\n", ord[i], c[ord[i]], bar
    }
}' /tmp/gap.$$
echo

echo "  -- the specific suspects, by count --"
for pat in "Loading cell" "cell " "Terrain" "terrain" "ObjectPaging" "object paging" \
           "chunk" "NIF" "nif" "mesh" "Shader" "shader" "texture" "Sound" "sound" \
           "navmesh" "Navigator" "TSP_"; do
    c="$(grep -ac -- "$pat" /tmp/gap.$$ 2>/dev/null; true)"
    [ "${c:-0}" -gt 0 ] && printf '     %7d  %s\n' "$c" "$pat"
done
echo

echo "  -- every TSP_ line in the gap (our own instrumentation), capped 30 --"
grep -a 'TSP_' /tmp/gap.$$ 2>/dev/null | head -30 | sed 's/^/     /' || echo "     (none)"
echo

echo "  -- distinct cell names mentioned, capped 40 --"
grep -ao 'cell [A-Za-z0-9_'"'"' ,()-]*' /tmp/gap.$$ 2>/dev/null | sort -u | head -40 | sed 's/^/     /'
echo

echo "  -- first 20 lines of the gap --"
head -20 /tmp/gap.$$ | sed 's/^/     /'
echo "  -- last 20 lines of the gap --"
tail -20 /tmp/gap.$$ | sed 's/^/     /'
rm -f /tmp/gap.$$
echo
done

echo "=================================================================="
echo " 2. THE KNOBS THAT ACT IN THAT WINDOW - current values, read only"
echo "=================================================================="
CFG=$G/config/settings.cfg
if [ -f "$CFG" ]; then
    echo "  -- view distance and terrain, from settings.cfg --"
    grep -n -E '^\[|viewing distance|object paging|distant terrain|merge factor|min size|small feature culling|max texture size' "$CFG" \
        | grep -v '^\s*$' | sed 's/^/    /' | head -40
    echo
    echo "  -- cell preloading --"
    sed -n '/^\[Cells\]/,/^\[/p' "$CFG" | sed 's/^/    /'
else
    echo "  settings.cfg not found at $CFG"
fi
echo
echo "  -- the adaptive draw distance mod, which now owns view distance --"
LUA=$G/mods/TSPPerformance/scripts/TSPPerformance/dynamic_view.lua
if [ -f "$LUA" ]; then
    grep -n -E '^(MIN_VIEW|DEFAULT_VIEW|MAX_VIEW|RAMP_START_VIEW|RAMP_SECONDS) ' "$LUA" | sed 's/^/    /'
    printf '    markers: '
    for m in TSP_FPSAVG_V2 TSP_LOADRAMP_V1 TSP_LOADRAMP_V2; do
        grep -q "$m" "$LUA" 2>/dev/null && printf '%s ' "$m"
    done
    printf '\n'
    echo "    NOTE the Lua PLAYER script does not start until the world is up, so"
    echo "    whatever the FIRST changeToCell uses is settings.cfg / the mod default,"
    echo "    not the load ramp."
else
    echo "    dynamic_view.lua not found"
fi
echo
echo "  -- resource cache policy --"
for kv in TSP_NO_LOADPURGE TSP_ICO_MAXOBJ OPENMW_TSP_MALLOC_TRIM_SECS OPENMW_TSP_GLRELEASE_FLOOR_KB; do
    v="$(sed -n "s/^[[:space:]]*export[[:space:]][[:space:]]*$kv=\(.*\)\$/\1/p" "$S/tsp_iotune.conf" 2>/dev/null | tail -1)"
    printf '    %-32s %s\n' "$kv" "${v:-(unset)}"
done
echo "    TSP_NO_LOADPURGE=1 means the resource cache is NEVER purged on load, so"
echo "    everything instantiated during scene construction is held for the session."
# ---- TSP_GAPDUMP_REMOTE_END ----
REMOTE

echo
echo "full report: $REP"
