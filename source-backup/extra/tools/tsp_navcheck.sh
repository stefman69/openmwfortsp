#!/usr/bin/env bash
# TSP_NAVCHECK_V1 - is the game generating navmesh at runtime after every load?
# READ ONLY. No play session, nothing changed.
#
#   bash ~/Downloads/tsp_navcheck.sh
#
# base-navmesh.db is 934 MB and the project notes flag navmesh_profile=STALE with
# mod_navmesh=MODDED as unresolved. A stale or unwritable navmesh DB means the engine
# builds navmesh on the fly after a load, which would show up as exactly what we
# measure: mech elevated on post-load frames, heavy I/O, decaying as nearby cells
# finish. This looks, and changes nothing.
#
# Rule Zero: file, not paste; r() uses -n, rin() takes the heredoc (NEVER -n).

set -u
TSP="${TSP:-root@192.168.1.12}"
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6"
DL="${DL:-$HOME/Downloads}"
REP="$DL/tsp-navcheck-$(date +%Y%m%d-%H%M%S).txt"

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }

r 'echo ok' >/dev/null 2>&1 || { echo "FAIL: cannot reach the TSP at $TSP" >&2; exit 1; }

rin 'sh -s' <<'REMOTE' 2>&1 | tee "$REP"
S=/mnt/SDCARD
G=$S/data/ports/openmw

echo "########## 1. THE DATABASES ##########"
for d in "$G/defaults/base-navmesh.db" /mnt/UDISK/openmw-nav/navmesh.db \
         "$G/config/navmesh.db" "$G/navmesh.db"; do
    [ -e "$d" ] && ls -l "$d"
done
echo "-- anything else called navmesh* --"
for base in "$G" /mnt/UDISK "$G/config"; do
    [ -d "$base" ] || continue
    find "$base" -maxdepth 3 -name 'navmesh*' 2>/dev/null | sed 's/^/  /'
done
echo "-- free space where the live db lives --"
df -h /mnt/UDISK /mnt/SDCARD 2>/dev/null
echo "SECTION 1 DONE"
echo

echo "########## 2. THE SETTINGS THAT DECIDE RUNTIME GENERATION ##########"
for c in "$G/config/settings.cfg" "$G/config-0.51/settings.cfg"; do
    [ -f "$c" ] || continue
    echo "-- $c --"
    grep -n -i 'navmesh\|\[Navigator\]\|async num threads\|max db file size\|write to navmeshdb\|enable nav mesh render' "$c"
done
echo "-- the generator awk, which rewrites settings.cfg each launch --"
for a in "$S"/tsp_*.awk; do
    [ -f "$a" ] || continue
    if grep -qi 'navmesh\|navigator' "$a" 2>/dev/null; then
        echo "-- $a --"; grep -n -i 'navmesh\|navigator' "$a"
    fi
done
echo "SECTION 2 DONE"
echo

echo "########## 3. WHAT THE ENGINE SAID LAST SESSION ##########"
L="$G/openmw_log.txt"
if [ -s "$L" ]; then
    printf 'log: %s bytes\n' "$(wc -c < "$L")"
else
    L="$(ls -t "$G"/openmw_log.txt.* 2>/dev/null | head -1)"
    printf 'live log empty; using %s\n' "$L"
fi
if [ -n "$L" ] && [ -s "$L" ]; then
    for k in navmesh Navigator 'nav mesh' navmeshdb RecastMesh 'db file size' 'Failed to' 'stale'; do
        printf -- '-- %s: %s hits --\n' "$k" "$(grep -aic "$k" "$L" 2>/dev/null; true)"
        grep -ai "$k" "$L" 2>/dev/null | head -4 | sed 's/^/    /'
    done
else
    echo "no log available"
fi
echo "SECTION 3 DONE"
echo

echo "########## 4. THE MANAGER'S VIEW OF THE NAVMESH ##########"
for f in "$G/launcher/status.kv" "$G/launcher/last-result.txt" \
         "$G/launcher/default-navmesh-candidates.txt" "$G/launcher/navmesh-profile.txt"; do
    [ -f "$f" ] && { echo "-- $f --"; head -25 "$f" | sed 's/^/    /'; }
done
echo "-- any key mentioning navmesh in the launcher dir --"
for f in "$G"/launcher/*.kv "$G"/launcher/*.txt "$G"/launcher/*.tsv; do
    [ -f "$f" ] || continue
    if grep -qi navmesh "$f" 2>/dev/null; then
        printf '  %s:\n' "$f"; grep -i navmesh "$f" | head -6 | sed 's/^/      /'
    fi
done
echo "SECTION 4 DONE"
echo

echo "########## 5. IS THE LIVE DB BEING WRITTEN ##########"
D=/mnt/UDISK/openmw-nav/navmesh.db
if [ -f "$D" ]; then
    ls -l "$D"
    echo "mtime vs now:"
    date
    echo "(if mtime is recent, the engine is writing navmesh during play)"
    for j in "$D-journal" "$D-wal" "$D-shm"; do [ -e "$j" ] && ls -l "$j"; done
else
    echo "$D not present - the engine has nowhere to cache generated navmesh"
fi
echo "SECTION 5 DONE"
REMOTE

echo
echo "full report: $REP"
