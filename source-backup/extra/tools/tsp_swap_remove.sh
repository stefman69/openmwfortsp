#!/usr/bin/env python3
"""Install the persistent swapfile setup into Morrowind_51.sh. Idempotent."""
import shutil, sys, time

P = "/mnt/SDCARD/Roms/PORTS/Morrowind_51.sh"
s = open(P).read()

if "tsp_setup_swap" in s:
    print("VERIFIED: already applied")
    sys.exit(0)

MARK = "# <<< TSP_V36_PERF_TELEMETRY END"
if s.count(MARK) != 1:
    print("ANCHOR MISS marker count=%d - NOTHING WRITTEN" % s.count(MARK)); sys.exit(1)

ANCHORS = [
    "    tsp_cpu_optimize\n",
    '    LD_PRELOAD="$TSP_LD_PRELOAD" $TSP_TASKSET "$OPENMW_BIN" \\',
    '    LD_PRELOAD="$TSP_LD_PRELOAD" "$OPENMW_BIN" \\',
    '    "$OPENMW_BIN" \\',
]
anchor = None
for a in ANCHORS:
    if s.count(a) == 1:
        anchor = a
        break
if anchor is None:
    print("ANCHOR MISS launch site - NOTHING WRITTEN")
    for a in ANCHORS:
        print("   %r -> %d" % (a, s.count(a)))
    sys.exit(1)

s = s.replace(MARK, '# TSP_SWAP_V1\n# The 0-1 fps stalls on this port are page-cache thrash, confirmed by\n# measurement: 997 major faults in a 10-second window during a stall versus 0\n# while healthy, with CPU utilisation going DOWN because the process was\n# blocked in the fault path rather than computing.\n#\n# Cause: ~684 MB RSS plus a ~230 MB Mali pool on a 986 MB device with NO SWAP.\n# With no swap the kernel\'s only reclaimable memory is file-backed pages, so\n# it evicts the game\'s own executable and libraries and faults them straight\n# back off the SD card - which is a fuseblk (exFAT) mount, so every fault is a\n# round trip through a userspace filesystem daemon.\n#\n# Adding 512 MB of swap on the internal ext4 partition took the fault count\n# from 997 to 166 per 10 s and the same fast-travel spot from 0 fps to ~5.\n# swappiness is raised so the kernel prefers evicting anonymous pages (which\n# now have somewhere to go) over file pages (which are the expensive ones).\n#\n# THIS CREATES A PERSISTENT FILE ON THE USER\'S INTERNAL STORAGE.\n# Default 512 MB at /mnt/UDISK/openmw51-swapfile. Remove it with\n# tsp_swap_remove.sh. Size is overridable in $GAMEDIR/tsp_swap_mb.txt;\n# "0" or "off" disables the whole feature and the game runs exactly as before.\ntsp_setup_swap() {\n    TSP_SWAP_MB=512\n    TSP_SWAPPINESS=150\n    TSP_VFS_PRESSURE=50\n    TSP_SWAP_DIR=/mnt/UDISK\n    TSP_SWAP_FILE="$TSP_SWAP_DIR/openmw51-swapfile"\n\n    if [ -r "$GAMEDIR/tsp_swap_mb.txt" ]; then\n        read -r TSP_SWAP_CFG < "$GAMEDIR/tsp_swap_mb.txt" 2>/dev/null\n        case "$TSP_SWAP_CFG" in\n            off|OFF|0) echo "Swap:         disabled by tsp_swap_mb.txt"; return 0 ;;\n            \'\'|*[!0-9]*) ;;\n            *) TSP_SWAP_MB=$TSP_SWAP_CFG ;;\n        esac\n    fi\n\n    [ -e /proc/swaps ] || { echo "Swap:         kernel has no swap support - skipping"; return 0; }\n\n    if grep -q "^$TSP_SWAP_FILE " /proc/swaps 2>/dev/null; then\n        echo "Swap:         already active ($TSP_SWAP_FILE)"\n        tsp_swap_tune\n        return 0\n    fi\n\n    command -v mkswap >/dev/null 2>&1 || { echo "Swap:         mkswap unavailable - skipping"; return 0; }\n    command -v swapon >/dev/null 2>&1 || { echo "Swap:         swapon unavailable - skipping"; return 0; }\n    [ -d "$TSP_SWAP_DIR" ] || { echo "Swap:         $TSP_SWAP_DIR not present - skipping"; return 0; }\n\n    # Refuse anything that cannot back a swapfile. FUSE and FAT cannot.\n    TSP_SWAP_FSTYPE=""\n    while read -r _dev _mp _fs _rest; do\n        [ "$_mp" = "$TSP_SWAP_DIR" ] && TSP_SWAP_FSTYPE=$_fs\n    done < /proc/mounts\n    case "$TSP_SWAP_FSTYPE" in\n        ext2|ext3|ext4|f2fs|btrfs|xfs) ;;\n        *) echo "Swap:         $TSP_SWAP_DIR is \'$TSP_SWAP_FSTYPE\', cannot host a swapfile - skipping"; return 0 ;;\n    esac\n\n    if [ ! -f "$TSP_SWAP_FILE" ]; then\n        # Never fill the partition: require 2x the swap size free.\n        TSP_SWAP_FREE_KB=$(df -k "$TSP_SWAP_DIR" 2>/dev/null | tail -1 | tr -s \' \' | cut -d\' \' -f4)\n        case "$TSP_SWAP_FREE_KB" in \'\'|*[!0-9]*) TSP_SWAP_FREE_KB=0 ;; esac\n        TSP_SWAP_NEED_KB=$(( TSP_SWAP_MB * 1024 * 2 ))\n        if [ "$TSP_SWAP_FREE_KB" -lt "$TSP_SWAP_NEED_KB" ]; then\n            echo "Swap:         only ${TSP_SWAP_FREE_KB} kB free on $TSP_SWAP_DIR, need ${TSP_SWAP_NEED_KB} kB - skipping"\n            return 0\n        fi\n\n        echo "Swap:         creating ${TSP_SWAP_MB} MB at $TSP_SWAP_FILE (one time, ~15s)"\n        if ! dd if=/dev/zero of="$TSP_SWAP_FILE" bs=1M count="$TSP_SWAP_MB" 2>/dev/null; then\n            echo "Swap:         could not write swapfile - skipping"\n            rm -f "$TSP_SWAP_FILE"\n            return 0\n        fi\n        chmod 600 "$TSP_SWAP_FILE" 2>/dev/null\n        if ! mkswap "$TSP_SWAP_FILE" >/dev/null 2>&1; then\n            echo "Swap:         mkswap failed - removing and skipping"\n            rm -f "$TSP_SWAP_FILE"\n            return 0\n        fi\n    fi\n\n    chmod 600 "$TSP_SWAP_FILE" 2>/dev/null\n    if swapon "$TSP_SWAP_FILE" 2>/dev/null; then\n        echo "Swap:         active, ${TSP_SWAP_MB} MB at $TSP_SWAP_FILE"\n        tsp_swap_tune\n    else\n        echo "Swap:         swapon failed - continuing without swap"\n    fi\n}\n\ntsp_swap_tune() {\n    [ -w /proc/sys/vm/swappiness ] && echo "$TSP_SWAPPINESS" > /proc/sys/vm/swappiness 2>/dev/null\n    [ -w /proc/sys/vm/vfs_cache_pressure ] && echo "$TSP_VFS_PRESSURE" > /proc/sys/vm/vfs_cache_pressure 2>/dev/null\n    echo "  swappiness : $(cat /proc/sys/vm/swappiness 2>/dev/null) (prefer swapping heap over evicting code)"\n    echo "  vfs_cache  : $(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null)"\n}' + "\n\n" + MARK, 1)
s = s.replace(anchor, "    tsp_setup_swap\n" + anchor, 1)

shutil.copy(P, P + ".bak-" + time.strftime("%Y%m%d-%H%M%S"))
open(P, "w").write(s)
print("VERIFIED: patched")
print("  call inserted before: %r" % anchor.strip())