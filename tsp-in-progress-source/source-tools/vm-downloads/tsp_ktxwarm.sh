#!/usr/bin/env bash
# TSP_KTXWARM_V1 - pull the converted textures into the page cache before play, then
# arm a clean capture so the result is directly comparable to the 2026-09-10 19:00 run.
#
#   bash ~/Downloads/tsp_ktxwarm.sh
#
# WHY
#   The ASTC conversion replaced 3 sequential .bsa reads with 4555 loose .ktx files
#   averaging ~12 KB. Measured on 2026-09-10: the first 5 s after a save load ran at
#   51.9 major faults/sec with 34.2% of frames faulting and a 189 ms worst frame,
#   against 3.6% late in the same session. read_ahead_kb=512 does nothing useful for a
#   12 KB read - it fetches half a megabyte and discards most of it, 4555 times.
#   The whole tree is 56 MB against ~540 MB MemAvailable, so read it up front.
#
# The read runs in the BACKGROUND at launcher time, so it overlaps the main menu while
# you pick a save. Off switch, matching the tsp_ring_off convention:
#     touch /mnt/SDCARD/tsp_ktxwarm_off
#
# Rule Zero: file, not paste; r() uses -n, rin() takes the heredoc.

set -u

TSP="${TSP:-root@192.168.1.12}"
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6"
DL="${DL:-$HOME/Downloads}"
STAMP="$(date +%Y%m%d-%H%M%S)"
W="$DL/tsp-ktxwarm"; mkdir -p "$W"
EXPP=a6e3ba90fbd63851985c79db7bcbda00   # tsp_post.sh

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }
die() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

r 'echo ok' >/dev/null 2>&1 || die "cannot reach the TSP at $TSP"

echo "########## 1. READER ##########"
LP="$(md5sum "$DL/tsp_post.sh" 2>/dev/null | cut -d' ' -f1)"
[ "${LP:-x}" = "$EXPP" ] || die "$DL/tsp_post.sh md5 ${LP:-missing} != $EXPP - save the newest"
scp -q $SSH_OPTS "$DL/tsp_post.sh" "$TSP:/mnt/SDCARD/" </dev/null || die "scp failed"
[ "$(r 'md5sum /mnt/SDCARD/tsp_post.sh' | cut -d' ' -f1)" = "$EXPP" ] || die "reader landed wrong"
r 'chmod +x /mnt/SDCARD/tsp_post.sh'
echo "VERIFIED: tsp_post.sh at $EXPP"

echo
echo "########## 2. LAUNCHER PREFETCH BLOCK ##########"
LAUNCHER="$(r "for f in /mnt/SDCARD/Roms/PORTS/*.sh; do [ -f \"\$f\" ] && grep -q 'TSP_RINGARM_V2 armed' \"\$f\" && echo \"\$f\" && break; done")"
[ -n "$LAUNCHER" ] || die "no launcher contains the TSP_RINGARM_V2 block - run tsp_ringarm.sh first"
echo "launcher: $LAUNCHER"

if r "grep -q TSP_KTXWARM_V1 '$LAUNCHER'"; then
    echo "TSP_KTXWARM_V1 already present - not patching again"
else
    r "cp -p '$LAUNCHER' '$LAUNCHER.bak-ktxwarm-$STAMP'" || die "device backup failed"
    echo "backed up to $(basename "$LAUNCHER").bak-ktxwarm-$STAMP"
    scp -q $SSH_OPTS "$TSP:$LAUNCHER" "$W/launcher.sh" </dev/null || die "scp down failed"

    python3 - "$W/launcher.sh" <<'PYEOF' || die "patch refused; device untouched"
import hashlib, sys
p = sys.argv[1]
src = open(p, encoding='utf-8', errors='surrogateescape').read()

ANCHOR = ('    echo "TSP_RINGARM_V2 armed trigger=$TSP_RING_TRIG max=$TSP_RING_MAX '
          'out=/mnt/SDCARD/tsp_ring" >> /mnt/SDCARD/tsp_prog.txt\nfi\n')

BLOCK = ANCHOR + """
# TSP_KTXWARM_V1 - the ASTC conversion turned 3 sequential .bsa reads into 4555 loose
# ~12 KB .ktx files. Measured 2026-09-10: the first 5 s after a save load ran 51.9
# major faults/sec with 34.2% of frames faulting, against 3.6% later in the session.
# 56 MB of textures against ~540 MB MemAvailable, so read the tree into the page cache
# in the background while the menu is up. Off: touch /mnt/SDCARD/tsp_ktxwarm_off
TSP_KTXDIR="/mnt/SDCARD/data/ports/openmw/data/Data Files/textures"
if [ ! -f /mnt/SDCARD/tsp_ktxwarm_off ] && [ -d "$TSP_KTXDIR" ]; then
    (
        TSP_KTXT0=$(date +%s)
        TSP_KTXHOW=tar
        if ! tar -cf /dev/null -C "$TSP_KTXDIR" . >/dev/null 2>&1; then
            TSP_KTXHOW=cat
            find "$TSP_KTXDIR" -name '*.ktx' 2>/dev/null | while IFS= read -r tsp_t; do
                cat "$tsp_t"
            done >/dev/null 2>&1
        fi
        echo "TSP_KTXWARM_V1 done via=$TSP_KTXHOW secs=$(( $(date +%s) - TSP_KTXT0 )) cached_kb=$(awk '/^Cached:/{print $2}' /proc/meminfo)" >> /mnt/SDCARD/tsp_prog.txt
    ) &
    echo "TSP_KTXWARM_V1 started dir=$TSP_KTXDIR cached_kb=$(awk '/^Cached:/{print $2}' /proc/meminfo)" >> /mnt/SDCARD/tsp_prog.txt
else
    echo "TSP_KTXWARM_V1 skipped (off switch present or dir missing)" >> /mnt/SDCARD/tsp_prog.txt
fi
"""

n = src.count(ANCHOR)
print('anchor (end of the RINGARM_V2 block) matched: %d (must be 1)' % n)
if n != 1:
    sys.exit(1)

out = src.replace(ANCHOR, BLOCK, 1)
before, after = len(src.splitlines()), len(out.splitlines())
checks = [
    ('marker once',            out.count('TSP_KTXWARM_V1 started') == 1),
    ('off switch honoured',    'if [ ! -f /mnt/SDCARD/tsp_ktxwarm_off ]' in out),
    ('runs in background',     out.count('    ) &') >= 1),
    ('tar with cat fallback',  'tar -cf /dev/null' in out and 'TSP_KTXHOW=cat' in out),
    ('ringarm block intact',   out.count('TSP_RINGARM_V2 armed') == 1),
    ('line delta matches',     after - before == len(BLOCK.splitlines()) - len(ANCHOR.splitlines())),
    ('nothing else moved',     src.replace(ANCHOR, '', 1) == out.replace(BLOCK, '', 1)),
]
bad = False
for label, ok in checks:
    print('      %-4s %s' % ('OK' if ok else 'FAIL', label))
    bad = bad or not ok
if bad:
    print('INVARIANT FAILED - untouched'); sys.exit(1)
open(p, 'w', encoding='utf-8', errors='surrogateescape').write(out)
print('patched locally, %d -> %d lines, md5 %s'
      % (before, after, hashlib.md5(out.encode('utf-8', 'surrogateescape')).hexdigest()))
PYEOF

    bash -n "$W/launcher.sh" || die "patched launcher fails bash -n; device untouched"
    echo "bash -n: patched launcher is valid"
    scp -q $SSH_OPTS "$W/launcher.sh" "$TSP:$LAUNCHER" </dev/null || die "scp up failed"
    r "chmod +x '$LAUNCHER'"
fi
r "grep -q 'TSP_KTXWARM_V1 started' '$LAUNCHER'" || die "marker absent after deploy"
echo "VERIFIED: TSP_KTXWARM_V1 is in the launcher"

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
echo "dumps archived: $n  (the 19:00 baseline is preserved there)"
if [ -f "$S/tsp_ring_off" ]; then mv "$S/tsp_ring_off" "$S/tsp_ring_off.parked-$STAMP"; fi
rm -f "$S/tsp_ktxwarm_off"
printf 'TSP_RING_TRIG=60\nTSP_RING_MAX=12\n' > "$S/tsp_ring.conf"
if [ -s "$G/openmw_log.txt" ]; then mv "$G/openmw_log.txt" "$G/openmw_log.txt.pre-$STAMP"; fi
: > "$S/tsp_prog.txt" 2>/dev/null || true
sync

echo
echo "########## READY CHECK ##########"
F=0
L="$(for f in "$S"/Roms/PORTS/*.sh; do [ -f "$f" ] && grep -q 'TSP_KTXWARM_V1 started' "$f" && echo "$f" && break; done)"
if [ -n "$L" ]; then echo "  OK   prefetch block in $(basename "$L")"; else echo "  FAIL prefetch block missing"; F=1; fi
if grep -q 'TSP_RINGARM_V2 armed' "$L" 2>/dev/null; then echo "  OK   ring arm block still present"; else echo "  FAIL ring arm block gone"; F=1; fi
if [ -f "$S/tsp_ktxwarm_off" ]; then echo "  FAIL prefetch disabled by off switch"; F=1; else echo "  OK   prefetch enabled"; fi
if [ -f "$S/tsp_ring_off" ]; then echo "  FAIL profiler off"; F=1; else echo "  OK   profiler enabled"; fi
if ls "$S"/tsp_ring.[0-9]* >/dev/null 2>&1; then echo "  FAIL dumps present"; F=1; else echo "  OK   dump slots free"; fi
if [ -s "$G/openmw_log.txt" ]; then echo "  FAIL log not empty"; F=1; else echo "  OK   log clean"; fi
printf '  OK   textures: %s files, %s bytes\n' \
    "$(find "$G/data/Data Files/textures" -name '*.ktx' 2>/dev/null | wc -l)" \
    "$(find "$G/data/Data Files/textures" -name '*.ktx' -exec wc -c {} + 2>/dev/null | tail -1 | awk '{print $1}')"
echo "  OK   Cached now: $(awk '/^Cached:/{print $2}' /proc/meminfo) kB"
echo
if [ "$F" -eq 0 ]; then echo "READY"; else echo "NOT READY"; fi
REMOTE

echo
echo "=================================================================="
echo "PROTOCOL - this must match the 19:00 run to be a valid comparison"
echo "  1. Launch 'Morrowind' from your menu."
echo "  2. Wait on the main menu about 10 seconds. That is the prefetch"
echo "     reading 56 MB into the page cache; it logs when it finishes."
echo "  3. Load THE SAME save you loaded at 19:00."
echo "  4. Play 60-90 seconds in the same area. Then quit through the menu."
echo "  5. bash ~/Downloads/tsp_prun.sh"
echo "=================================================================="
echo
echo "The number to compare is the 0-5 s bucket after the load:"
echo "    19:00 baseline    51.9 majflt/s   34.2% faulting   worst 189 ms"
echo "If the prefetch works that should fall a lot. If it does not move, the"
echo "faults are not the loose texture files and I will have been wrong."
echo
echo "Off switches, either one alone, no other change:"
echo "    ssh -n $TSP 'touch /mnt/SDCARD/tsp_ktxwarm_off'   # prefetch off"
echo "    ssh -n $TSP 'touch /mnt/SDCARD/tsp_ring_off'      # profiler off"
