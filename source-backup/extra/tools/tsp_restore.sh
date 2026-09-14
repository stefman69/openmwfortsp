#!/usr/bin/env bash
# TSP_RESTORE_V1 - undo every performance-relevant device change made on 2026-09-10/11
# and put the ring profiler fully back off, so the game is playable again.
#
#   bash ~/Downloads/tsp_restore.sh
#
# Reverses, in this order:
#   1. tsp_ring_off            - restored from .was-set-*, or created. This is the
#                                documented off switch; with it present the launcher
#                                unsets the ring vars and the profiler does nothing.
#   2. the launcher            - restored from the newest .bak-ringexport-* (the export
#                                change), md5-compared against the backup.
#   3. /mnt/SDCARD/tsp_ring.conf - moved aside; restored from a backup if one exists.
#
# Nothing here touches the game data, the binary, the mods or the saves.
# Rule Zero: file, not paste; r() uses -n, rin() takes the heredoc.

set -u

TSP="${TSP:-root@192.168.1.12}"
SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=6"

r()   { ssh -n $SSH_OPTS "$TSP" "$@"; }
rin() { ssh    $SSH_OPTS "$TSP" "$@"; }

r 'echo ok' >/dev/null 2>&1 || { echo "FAIL: cannot reach the TSP at $TSP" >&2; exit 1; }

rin 'sh -s' <<'REMOTE'
# ---- TSP_RESTORE_REMOTE_BEGIN ----
S="${S:-/mnt/SDCARD}"
G="${G:-$S/data/ports/openmw}"
STAMP="$(date +%Y%m%d-%H%M%S)"

echo "########## 1. PROFILER OFF ##########"
if [ -f "$S/tsp_ring_off" ]; then
    echo "  tsp_ring_off already present - profiler already off"
else
    WAS="$(ls -t "$S"/tsp_ring_off.was-set-* 2>/dev/null | head -1)"
    if [ -n "$WAS" ]; then
        mv "$WAS" "$S/tsp_ring_off"
        echo "  RESTORED tsp_ring_off from $(basename "$WAS")"
        echo "  -> it WAS set before tonight. Enabling the profiler is what slowed the game."
    else
        : > "$S/tsp_ring_off"
        echo "  CREATED tsp_ring_off (no .was-set backup existed)"
        echo "  -> profiler now off regardless of how it was before."
    fi
fi

echo
echo "########## 2. LAUNCHER ##########"
LAUNCHER=""
for f in "$S"/Roms/PORTS/*.sh; do
    [ -f "$f" ] || continue
    if grep -q 'OPENMW_TSP_RING' "$f" 2>/dev/null; then LAUNCHER="$f"; break; fi
done
if [ -z "$LAUNCHER" ]; then
    for f in "$S"/Roms/PORTS/*.sh; do
        [ -f "$f" ] || continue
        if ls "$f".bak-ringexport-* >/dev/null 2>&1; then LAUNCHER="$f"; break; fi
    done
fi

if [ -z "$LAUNCHER" ]; then
    echo "  no launcher found that mentions OPENMW_TSP_RING or has an export backup"
    echo "  launchers present:"
    ls "$S"/Roms/PORTS/*.sh 2>/dev/null | sed 's/^/    /'
else
    echo "  launcher: $LAUNCHER"
    BAK="$(ls -t "$LAUNCHER".bak-ringexport-* 2>/dev/null | head -1)"
    if [ -z "$BAK" ]; then
        echo "  no .bak-ringexport-* backup - the export change was never applied here."
        echo "  leaving the launcher alone. Current ring lines:"
        grep -n 'OPENMW_TSP_RING' "$LAUNCHER" 2>/dev/null | sed 's/^/    /'
    else
        NOW_MD5="$(md5sum "$LAUNCHER" | cut -d' ' -f1)"
        BAK_MD5="$(md5sum "$BAK" | cut -d' ' -f1)"
        echo "  backup:   $(basename "$BAK")"
        if [ "$NOW_MD5" = "$BAK_MD5" ]; then
            echo "  already identical to the backup - nothing to restore"
        else
            cp -p "$LAUNCHER" "$LAUNCHER.before-restore-$STAMP"
            cp -p "$BAK" "$LAUNCHER" && chmod +x "$LAUNCHER"
            RES_MD5="$(md5sum "$LAUNCHER" | cut -d' ' -f1)"
            if [ "$RES_MD5" = "$BAK_MD5" ]; then
                echo "  RESTORED - md5 now matches the backup ($RES_MD5)"
            else
                echo "  FAIL - restore did not match the backup"
            fi
        fi
        echo "  ring lines as they now read:"
        grep -n 'OPENMW_TSP_RING' "$LAUNCHER" 2>/dev/null | sed 's/^/    /'
    fi
fi

echo
echo "########## 3. tsp_ring.conf ##########"
if [ -f "$S/tsp_ring.conf" ]; then
    echo "  current contents: $(tr '\n' ' ' < "$S/tsp_ring.conf")"
    mv "$S/tsp_ring.conf" "$S/tsp_ring.conf.claude-wrote-$STAMP"
    echo "  moved aside to tsp_ring.conf.claude-wrote-$STAMP"
else
    echo "  not present"
fi
CBAK="$(ls -t "$S"/tsp_ring.conf.bak-* "$S"/tsp_ring.conf.before-* 2>/dev/null | head -1)"
if [ -n "$CBAK" ]; then
    cp -p "$CBAK" "$S/tsp_ring.conf"
    echo "  RESTORED from $(basename "$CBAK"): $(tr '\n' ' ' < "$S/tsp_ring.conf")"
else
    echo "  no pre-existing backup found; left absent so the launcher uses its own defaults"
fi

sync

echo
echo "########## RESULT ##########"
if [ -f "$S/tsp_ring_off" ]; then
    echo "  OK   profiler OFF (tsp_ring_off present)"
else
    echo "  FAIL profiler still enabled"
fi
if [ -f "$S/tsp_ring.conf" ]; then
    echo "  note tsp_ring.conf present: $(tr '\n' ' ' < "$S/tsp_ring.conf")"
else
    echo "  OK   tsp_ring.conf absent (launcher defaults apply)"
fi
echo "  note ring dumps on card: $(ls "$S"/tsp_ring.[0-9]* 2>/dev/null | wc -l)"
echo
echo "########## WHAT THE MOD FILE LOOKS LIKE NOW ##########"
L="$G/mods/TSPPerformance/scripts/TSPPerformance/dynamic_view.lua"
if [ -f "$L" ]; then
    printf '  dynamic_view.lua  %s lines  md5 %s\n' "$(wc -l < "$L")" "$(md5sum "$L" | cut -d' ' -f1)"
    if grep -q TSP_FPSAVG_V2 "$L"; then
        echo "  TSP_FPSAVG_V2 present"
    else
        echo "  TSP_FPSAVG_V2 GONE - it was verified present before the session, so"
        echo "  something replaces this file at launch. Other copies on the card:"
        for c in "$S"/data/ports/openmw/defaults/TSPPerformance/scripts/TSPPerformance/dynamic_view.lua \
                 "$S"/data/ports/openmw/v30_profiles/TSPPerformance/scripts/TSPPerformance/dynamic_view.lua; do
            [ -f "$c" ] && printf '    %s  md5 %s\n' "$c" "$(md5sum "$c" | cut -d' ' -f1)"
        done
    fi
    echo "  backups of it:"
    ls -t "$L".before-* 2>/dev/null | head -3 | sed 's/^/    /'
else
    echo "  dynamic_view.lua not found at $L"
fi
# ---- TSP_RESTORE_REMOTE_END ----
REMOTE

echo
echo "Profiler is off. Launch 'Morrowind' from your menu and the framerate should be"
echo "back where it was. Nothing else about the game was changed by this script."
