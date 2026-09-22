#!/usr/bin/env bash
# TSP_LUAFIND_V2 - find every copy of dynamic_view.lua and whatever replaces it at
# launch. READ ONLY. No play session, nothing changed.
#
#   bash ~/Downloads/tsp_luafind.sh
#
# V1 hung for minutes: it ran `ls` and `awk` once per file over the whole mods tree
# (measured at ~3 s per 1000 files on hardware faster than the TSP), and it buffered
# all output into a file so the hang looked like a dead terminal. V2 has no per-file
# forks, scopes every find to a mod directory instead of walking the 4555-file texture
# tree, and streams every section as it completes.
#
# Rule Zero: file, not paste; r() uses -n, rin() takes the heredoc (NEVER -n).

set -u

TSP="${TSP:-root@192.168.1.12}"
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6"
DL="${DL:-$HOME/Downloads}"
REP="$DL/tsp-luafind-$(date +%Y%m%d-%H%M%S).txt"

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }

r 'echo ok' >/dev/null 2>&1 || { echo "FAIL: cannot reach the TSP at $TSP" >&2; exit 1; }

# tee, not redirect: every section appears as it finishes, so a slow step is visible.
rin 'sh -s' <<'REMOTE' 2>&1 | tee "$REP"
# ---- TSP_LUAFIND_REMOTE_BEGIN ----
S="${S:-/mnt/SDCARD}"
G="${G:-$S/data/ports/openmw}"

# One line per file. Only ever called on the handful of dynamic_view.lua matches, so
# the forks here are bounded; never call it inside a whole-tree loop.
show() {
    [ -f "$1" ] || return 0
    printf '  %s\n      %s lines  md5 %s  %s\n' \
        "$1" "$(wc -l < "$1")" "$(md5sum "$1" | cut -d' ' -f1)" \
        "$(grep -q TSP_FPSAVG_V2 "$1" 2>/dev/null && echo '*** HAS_V2 ***' || echo 'no marker')"
}

echo "########## 1. EVERY dynamic_view.lua ##########"
# Scoped to mod directories. Never $G itself: that walks data/Data Files/textures.
for base in "$G/mods" "$G/defaults" "$G/v30_profiles" "$G/launcher" "$G/profiles" "$S/mods"; do
    [ -d "$base" ] || continue
    find "$base" -maxdepth 6 -name 'dynamic_view.lua*' 2>/dev/null | while IFS= read -r c; do
        show "$c"
    done
done
echo "-- explicit candidates, in case the scoped search missed one --"
for c in \
    "$G/mods/TSPPerformance/scripts/TSPPerformance/dynamic_view.lua" \
    "$G/data/mods/TSPPerformance/scripts/TSPPerformance/dynamic_view.lua" \
    "$G/defaults/TSPPerformance/scripts/TSPPerformance/dynamic_view.lua" \
    "$G/defaults/mods/TSPPerformance/scripts/TSPPerformance/dynamic_view.lua" \
    "$G/v30_profiles/TSPPerformance/scripts/TSPPerformance/dynamic_view.lua" ; do
    show "$c"
done
echo "-- directories named TSPPerformance --"
for base in "$G/mods" "$G/defaults" "$G/v30_profiles" "$S/mods"; do
    [ -d "$base" ] || continue
    find "$base" -maxdepth 4 -type d -name 'TSPPerformance' 2>/dev/null | sed 's/^/  /'
done
echo "-- top level of the game dir, for orientation --"
ls -d "$G"/*/ 2>/dev/null | sed 's/^/  /'
echo "SECTION 1 DONE"
echo

echo "########## 2. WHAT THE LAUNCHER DOES WITH MODS ##########"
L=""
for f in "$S"/Roms/PORTS/*.sh; do
    [ -f "$f" ] || continue
    if grep -q 'openmw' "$f" 2>/dev/null; then L="$f"; break; fi
done
if [ -z "$L" ]; then
    echo "no launcher found under $S/Roms/PORTS"
else
    echo "launcher: $L  ($(wc -l < "$L") lines)"
    echo "-- lines mentioning TSPPerformance --"
    grep -n 'TSPPerformance' "$L" || echo "  (none)"
    echo "-- lines that copy a mod tree --"
    grep -n -E 'cp +-[a-zA-Z]*r|cp +-f|rsync|install_mod|force_install' "$L" | head -30
    echo "-- the VisGrid force-install block, as the known example of the pattern --"
    grep -n -B3 -A8 'v30_profiles' "$L" | head -30
fi
echo "SECTION 2 DONE"
echo

echo "########## 3. WHAT THE CONFIG SAYS ##########"
for c in "$G/config/openmw.cfg" "$G/config-0.51/openmw.cfg"; do
    [ -f "$c" ] || continue
    echo "-- $c --"
    grep -n -E '^data=|^content=|TSPPerformance|omwscripts' "$c"
done
echo "-- omwscripts files (mod dirs only) --"
for base in "$G/mods" "$G/defaults"; do
    [ -d "$base" ] || continue
    find "$base" -maxdepth 4 -name '*.omwscripts' 2>/dev/null | while IFS= read -r c; do
        printf '  %s\n' "$c"
        sed 's/^/      /' "$c"
    done
done
echo "SECTION 3 DONE"
echo

echo "########## 4. THE MANAGER'S MOD MACHINERY ##########"
for c in "$G/launcher/modplan.tsv" "$G/modplan.tsv"; do
    [ -f "$c" ] && { echo "-- $c --"; head -30 "$c" | sed 's/^/      /'; }
done
for p in "$G/launcher/openmw-launcher-backend-v2.py" "$G/launcher/openmw-launcher-backend.py"; do
    [ -f "$p" ] || continue
    echo "-- $p --"
    grep -n -E 'copytree|shutil\.copy|rmtree|TSPPerformance' "$p" | head -25
done
echo "SECTION 4 DONE"
echo

echo "########## 5. TIMESTAMPS ##########"
# ls -lt on directories only. No per-file forks: that is what made V1 hang.
for d in "$G/mods" "$G/defaults" "$G/v30_profiles"; do
    [ -d "$d" ] || continue
    echo "-- $d --"
    ls -lt "$d" 2>/dev/null | head -12 | sed 's/^/  /'
done
for c in \
    "$G/mods/TSPPerformance/scripts/TSPPerformance/dynamic_view.lua" \
    "$G/defaults/TSPPerformance/scripts/TSPPerformance/dynamic_view.lua" \
    "$G/config/openmw.cfg" ; do
    [ -e "$c" ] && ls -l "$c" | sed 's/^/  /'
done
echo "SECTION 5 DONE"
# ---- TSP_LUAFIND_REMOTE_END ----
REMOTE

echo
echo "full report: $REP"
