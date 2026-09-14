#!/usr/bin/env bash
# TSP_RINGFIX_V1 - find out why the ring profiler never dumps, and fix it if the cause
# is a missing `export`. Then re-verify the arm state.
#
#   bash ~/Downloads/tsp_ringfix.sh
#
# Rule Zero: file, not paste. Every ssh goes through r() (-n, command string) or
# rin() (heredoc, never -n). The remote body below is written so it can be executed
# standalone against a fake tree by overriding S=, which is how it was tested.

set -u

TSP="${TSP:-root@192.168.1.12}"
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6"

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }

r 'echo ok' >/dev/null 2>&1 || { echo "FAIL: cannot reach the TSP at $TSP" >&2; exit 1; }

rin 'sh -s' <<'REMOTE'
# ---- TSP_RINGFIX_REMOTE_BEGIN ----
S="${S:-/mnt/SDCARD}"
G="${G:-$S/data/ports/openmw}"
STAMP="$(date +%Y%m%d-%H%M%S)"

echo "########## 1. WHICH LAUNCHER, AND IS THE RING EXPORTED ##########"
echo "-- launchers present --"
ls -la "$S"/Roms/PORTS/*.sh 2>/dev/null || echo "(none found under $S/Roms/PORTS)"
echo

# Locate by content, with explicit paths. busybox grep -r silently matches nothing,
# so it is never used here.
LAUNCHER=""
for f in "$S"/Roms/PORTS/*.sh; do
    [ -f "$f" ] || continue
    if grep -q 'OPENMW_TSP_RING' "$f" 2>/dev/null; then
        LAUNCHER="$f"
        break
    fi
done

if [ -z "$LAUNCHER" ]; then
    echo "RESULT: no launcher under $S/Roms/PORTS mentions OPENMW_TSP_RING at all."
    echo "        TSP_RINGARM_V1 is not in any launcher, so the profiler can never arm."
    echo "        Files that DO mention TSP_RING (for reference):"
    for f in "$S"/Roms/PORTS/*.sh; do
        [ -f "$f" ] || continue
        if grep -q 'TSP_RING' "$f" 2>/dev/null; then echo "          $f"; fi
    done
    exit 0
fi

echo "-- ring block in $LAUNCHER --"
grep -n -B3 -A8 'OPENMW_TSP_RING' "$LAUNCHER"
echo

NEXP=$(grep -c '^[[:space:]]*export[[:space:]][[:space:]]*OPENMW_TSP_RING' "$LAUNCHER" ; true)
NPLAIN=$(grep -c '^[[:space:]]*OPENMW_TSP_RING[A-Z_]*=' "$LAUNCHER" ; true)
NUNSET=$(grep -c '^[[:space:]]*unset[[:space:]][[:space:]]*OPENMW_TSP_RING' "$LAUNCHER" ; true)
echo "exported assignments: $NEXP    plain (un-exported) assignments: $NPLAIN    unset lines: $NUNSET"
echo

if [ "$NUNSET" -gt 0 ]; then
    echo "WARNING: $NUNSET 'unset OPENMW_TSP_RING...' line(s) remain in the launcher."
    echo "         If any of them runs AFTER the arm block, it disarms the profiler."
    grep -n '^[[:space:]]*unset[[:space:]][[:space:]]*OPENMW_TSP_RING' "$LAUNCHER"
    echo
fi

if [ "$NPLAIN" -eq 0 ] && [ "$NEXP" -gt 0 ]; then
    echo "RESULT: already exported. A missing export is NOT the cause."
    echo "        Next suspects, in order:"
    echo "          1. an 'unset' after the arm block (see above)"
    echo "          2. the game runs via a wrapper that scrubs the environment"
    echo "          3. the profiler is compiled out of this binary"
elif [ "$NPLAIN" -gt 0 ]; then
    echo "RESULT: $NPLAIN OPENMW_TSP_RING assignment(s) are NOT exported."
    echo "        The launcher sets them in its own shell only, so the game process"
    echo "        never sees them and the profiler can never dump. Fixing now."
    echo

    cp -p "$LAUNCHER" "$LAUNCHER.bak-ringexport-$STAMP" || { echo "FAIL: backup failed"; exit 1; }
    echo "backed up to $LAUNCHER.bak-ringexport-$STAMP"

    BEFORE_LINES=$(wc -l < "$LAUNCHER")
    sed 's/^\([[:space:]]*\)\(OPENMW_TSP_RING[A-Z_]*=\)/\1export \2/' \
        "$LAUNCHER" > "$LAUNCHER.new" || { echo "FAIL: sed failed"; rm -f "$LAUNCHER.new"; exit 1; }

    AFTER_LINES=$(wc -l < "$LAUNCHER.new")
    AFTER_EXP=$(grep -c '^[[:space:]]*export[[:space:]][[:space:]]*OPENMW_TSP_RING' "$LAUNCHER.new" ; true)
    AFTER_PLAIN=$(grep -c '^[[:space:]]*OPENMW_TSP_RING[A-Z_]*=' "$LAUNCHER.new" ; true)

    echo "  lines $BEFORE_LINES -> $AFTER_LINES   (must be equal)"
    echo "  exported $NEXP -> $AFTER_EXP          (must have grown by $NPLAIN)"
    echo "  plain    $NPLAIN -> $AFTER_PLAIN      (must be 0)"

    OK=1
    [ "$BEFORE_LINES" = "$AFTER_LINES" ] || OK=0
    [ "$AFTER_PLAIN" -eq 0 ] || OK=0
    [ "$AFTER_EXP" -eq $((NEXP + NPLAIN)) ] || OK=0
    if ! sh -n "$LAUNCHER.new" 2>/dev/null; then
        if ! bash -n "$LAUNCHER.new" 2>/dev/null; then OK=0; echo "  FAIL: patched launcher fails a syntax check"; fi
    fi

    if [ "$OK" -eq 1 ]; then
        mv "$LAUNCHER.new" "$LAUNCHER" && chmod +x "$LAUNCHER"
        echo "  VERIFIED: export added to $NPLAIN assignment(s)"
        echo
        echo "-- the block as it now reads --"
        grep -n 'OPENMW_TSP_RING' "$LAUNCHER"
    else
        rm -f "$LAUNCHER.new"
        echo "  REFUSED: a check failed. Launcher untouched; backup left in place."
    fi
else
    echo "RESULT: the launcher mentions OPENMW_TSP_RING but assigns it in a shape this"
    echo "        script does not recognise. Nothing changed. The block is printed above."
fi

echo
echo "########## 2. IS THE PROFILER IN THE BINARY ##########"
B="$G/bin/openmw-0.51"
if [ -f "$B" ]; then
    printf 'binary %s bytes\n' "$(wc -c < "$B")"
    printf 'TSP_PROF_RUSAGE_V4 strings: %s\n' "$(strings "$B" 2>/dev/null | grep -c 'TSP_PROF_RUSAGE_V4' ; true)"
    printf 'TSP_RING_DUMP strings:      %s\n' "$(strings "$B" 2>/dev/null | grep -c 'TSP_RING_DUMP' ; true)"
    printf 'TSP_RING_ARM strings:       %s\n' "$(strings "$B" 2>/dev/null | grep -c 'TSP_RING_ARM' ; true)"
else
    echo "binary not found at $B"
fi

echo
echo "########## 3. ARM STATE ##########"
L="$G/mods/TSPPerformance/scripts/TSPPerformance/dynamic_view.lua"
FAILED=0
if grep -q TSP_FPSAVG_V2 "$L" 2>/dev/null; then
    echo "  OK   fps fix live ($(wc -l < "$L") lines)"
else
    echo "  FAIL fps fix NOT live"; FAILED=1
fi
if ls "$S"/tsp_ring.[0-9]* >/dev/null 2>&1; then
    echo "  FAIL $(ls "$S"/tsp_ring.[0-9]* | wc -l) dump(s) present - archive them first"; FAILED=1
else
    echo "  OK   all dump slots free"
fi
if [ -s "$G/openmw_log.txt" ]; then
    echo "  WARN log has $(wc -c < "$G/openmw_log.txt") bytes - it will mix with this session"
else
    echo "  OK   log clean"
fi
if [ -f "$S/tsp_ring_off" ]; then
    echo "  FAIL tsp_ring_off present - profiler disabled"; FAILED=1
else
    echo "  OK   profiler enabled"
fi
echo "  OK   conf: $(tr '\n' ' ' < "$S/tsp_ring.conf" 2>/dev/null)"
echo "  OK   reader: $(md5sum "$S/tsp_hitch.sh" 2>/dev/null | cut -d' ' -f1)"
echo
if [ "$FAILED" -eq 0 ]; then echo "READY"; else echo "NOT READY"; fi
# ---- TSP_RINGFIX_REMOTE_END ----
REMOTE

echo
echo "Launch the game from the entry named 'Morrowind' in your menu, play 15-20 min in"
echo "the exteriors where it hitches, quit through the menu, then:  bash ~/Downloads/tsp_pull.sh"
