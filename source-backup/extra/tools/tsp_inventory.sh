#!/bin/sh
# tsp_inventory.sh - LOOK BEFORE BUILDING ANYTHING ELSE.
#
# Read-only. Finds what already exists on the device instead of trusting a
# compacted conversation: every tsp_*.sh tool, the backup folder and what is in
# it, what is actually on /mnt/UDISK, and every data= line the game is using.
#
# Bounded on purpose. maxdepth on named directories only, never a recursive
# find or grep over /mnt/SDCARD or /mnt/SDCARD/App - a recursive grep over the
# card once saturated the SD and caused a five-minute 0-1 fps load.

set -u
DEV="root@192.168.1.12"
G="/mnt/SDCARD/data/ports/openmw"
SSHO="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes"
OUT="$HOME/Downloads/tsp_inventory_$(date +%Y%m%d-%H%M%S).txt"

rin() { ssh $SSHO "$DEV" "sh -s" 2>&1; }
if ! ssh $SSHO -n "$DEV" "echo ok" 2>&1 | grep -q ok; then
    printf '  cannot reach %s - is the handheld awake and on wifi?\n' "$DEV"
    exit 1
fi

mkdir -p "$HOME/Downloads"
printf '\n########## INVENTORY (read-only, bounded) ##########\n'

rin <<'IEOF' | tee "$OUT"
G="/mnt/SDCARD/data/ports/openmw"

echo "=============================================================="
echo "== 1. IS ANYTHING ALREADY ON /mnt/UDISK"
echo "=============================================================="
df -h /mnt/UDISK | tail -1
echo "--- top two levels of /mnt/UDISK"
find /mnt/UDISK -maxdepth 2 -mindepth 1 2>/dev/null | head -60
echo "--- sizes of each top-level entry"
for d in /mnt/UDISK/*; do
    [ -e "$d" ] || continue
    printf '  %-42s %s\n' "$(basename "$d")" "$(du -sh "$d" 2>/dev/null | cut -f1)"
done
echo "--- any .ktx anywhere under /mnt/UDISK (depth 3)"
printf '  ktx count: %s\n' "$(find /mnt/UDISK -maxdepth 3 -iname '*.ktx' 2>/dev/null | wc -l)"
printf '  wav/mp3 count: %s\n' "$(find /mnt/UDISK -maxdepth 4 \( -iname '*.wav' -o -iname '*.mp3' \) 2>/dev/null | wc -l)"

echo ""
echo "=============================================================="
echo "== 2. WHAT THE GAME IS ACTUALLY POINTED AT"
echo "=============================================================="
for c in "$G/openmw.cfg" "$G/bin/openmw.cfg"; do
    [ -f "$c" ] || continue
    echo "--- $c"
    grep -n -e '^data=' -e '^fallback-archive=' -e '^content=' "$c" | head -30
done
echo "--- openmw.cfg backups present (names say what changed them)"
ls -1t "$G"/openmw.cfg.bak-* "$G"/openmw.cfg.before-* 2>/dev/null | head -20

echo ""
echo "=============================================================="
echo "== 3. THE BACKUP FOLDER - /mnt/SDCARD/data/ports/Backups"
echo "=============================================================="
# Steve gave the path: data/ports/Backups. Resolve the real casing rather than
# assuming, then list the whole thing - this is where tools that left the game
# root ended up, and the reason several of them got rebuilt from scratch.
B=""
for c in /mnt/SDCARD/data/ports/Backups /mnt/SDCARD/data/ports/backups \
         /mnt/SDCARD/Data/ports/Backups /mnt/SDCARD/data/Ports/Backups; do
    [ -d "$c" ] && { B="$c"; break; }
done
if [ -z "$B" ]; then
    B="$(find /mnt/SDCARD/data -maxdepth 2 -type d -iname 'backups' 2>/dev/null | head -1)"
fi
if [ -z "$B" ]; then
    echo "  NOT FOUND at data/ports/Backups or any case variant."
    echo "  What is actually in /mnt/SDCARD/data/ports:"
    ls -1 /mnt/SDCARD/data/ports 2>/dev/null | head -30
else
    echo "  found: $B"
    printf '  total size: %s\n' "$(du -sh "$B" 2>/dev/null | cut -f1)"
    echo "--- everything in it, 4 levels, newest first"
    find "$B" -maxdepth 4 -type f 2>/dev/null | head -120 | while read -r f; do
        printf '  %-64s %7s  %s  %s\n' \
          "$(echo "$f" | sed "s|^$B/||")" \
          "$(du -k "$f" 2>/dev/null | cut -f1)kB" \
          "$(md5sum "$f" 2>/dev/null | cut -c1-12)" \
          "$(date -r "$f" '+%m-%d %H:%M' 2>/dev/null)"
    done
    echo "--- subdirectories"
    find "$B" -maxdepth 3 -type d 2>/dev/null | sed "s|^$B|  .|" | head -30
    echo "--- and the header + modes of every script in there"
    find "$B" -maxdepth 4 \( -name '*.sh' -o -name '*.py' \) 2>/dev/null | head -25 | while read -r f; do
        echo "  === $(echo "$f" | sed "s|^$B/||")"
        head -12 "$f" | grep -e '^#' | sed 's/^#\{1,2\} \{0,1\}/        /' | head -8
    done
fi
echo "--- top level of /mnt/SDCARD, for orientation"
ls -1 /mnt/SDCARD 2>/dev/null | head -30

echo ""
echo "=============================================================="
echo "== 4. EVERY tsp_*.sh AND .py TOOL ON THE DEVICE (bounded roots)"
echo "=============================================================="
for root in /mnt/SDCARD /mnt/SDCARD/data/ports /mnt/SDCARD/data/ports/Backups \
            /mnt/SDCARD/Roms/PORTS /mnt/UDISK /root /tmp "$G"; do
    [ -d "$root" ] || continue
    find "$root" -maxdepth 4 \( -name 'tsp_*.sh' -o -name 'tsp_*.py' -o -name 'tsp_*.conf' -o -name 'tsp_*.env' \) 2>/dev/null
done | sort -u | while read -r f; do
    printf '  %-58s %7s  %s  %s\n' "$f" "$(du -k "$f" 2>/dev/null | cut -f1)kB" \
           "$(md5sum "$f" 2>/dev/null | cut -c1-12)" \
           "$(date -r "$f" '+%m-%d %H:%M' 2>/dev/null)"
done

echo ""
echo "=============================================================="
echo "== 5. WHAT MODES EACH TOOL OFFERS (so nothing gets rebuilt)"
echo "=============================================================="
for root in /mnt/SDCARD /mnt/SDCARD/data/ports /mnt/UDISK /root "$G"; do
    [ -d "$root" ] || continue
    find "$root" -maxdepth 3 -name 'tsp_*.sh' 2>/dev/null
done | sort -u | while read -r f; do
    echo "--- $(basename "$f")"
    head -14 "$f" | grep -e '^#' | sed 's/^#\{1,2\} \{0,1\}/    /' | head -10
    grep -o -e '^[a-z]* | [a-z |]*) ;;' -e 'MODE" = "[a-z]*"' "$f" 2>/dev/null | head -6 | sed 's/^/      /'
done

echo ""
echo "=============================================================="
echo "== 6. STATE FLAGS AND MARKERS LYING AROUND"
echo "=============================================================="
ls -1 /mnt/SDCARD/tsp_* 2>/dev/null | head -30
echo "--- markers inside the game dir"
ls -1 "$G"/tsp_* "$G/data/Data Files"/tsp_* 2>/dev/null | head -20
echo "--- device binaries and their dates"
ls -lt "$G/bin/" 2>/dev/null | head -12
IEOF

printf '\n########## SUMMARY ##########\n'
printf '  saved to %s\n\n' "$OUT"
printf '  The three questions this answers, in order:\n'
printf '    1. is anything already staged on /mnt/UDISK  (section 1)\n'
printf '    2. does the game point at it                 (section 2)\n'
printf '    3. what is in data/ports/Backups              (section 3)\n'
printf '    4. every tool that already exists            (sections 4-5)\n\n'
printf '  Send me sections 1, 2 and 4 and I will stop guessing.\n\n'
