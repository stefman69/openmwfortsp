#!/bin/sh
# tsp_rescue.sh - two jobs, both small.
#
# 1. RESCUE /tmp/tsp_iowatch_sampler.sh before the next reboot takes it. /tmp is
#    tmpfs. That file is the device-side half of TSP_IOWATCH_V2 - the smaps-by-
#    region sampler - and it is the only surviving copy. It gets copied into
#    data/ports/Backups and printed here so the host-side reader can be rebuilt
#    around it instead of from scratch. Same for the other live samplers.
#
# 2. SETTLE THE TEXTURE QUESTION with device and inode numbers rather than an
#    argument. Are the 4481 .ktx on the eMMC, the SD card, or both? Does
#    "Data Files/textures" resolve to /mnt/UDISK/openmw-tex? Is the game reading
#    the eMMC copy or the SD copy? Only the kernel can answer that.

set -u
DEV="root@192.168.1.12"
G="/mnt/SDCARD/data/ports/openmw"
B="/mnt/SDCARD/data/ports/Backups/rescued-$(date +%Y%m%d-%H%M%S)"
SSHO="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes"
OUT="$HOME/Downloads/tsp_rescue_$(date +%Y%m%d-%H%M%S).txt"

rin() { ssh $SSHO "$DEV" "sh -s" 2>&1; }
ssh $SSHO -n "$DEV" "echo ok" 2>&1 | grep -q ok || {
    printf '  cannot reach %s\n' "$DEV"; exit 1; }
mkdir -p "$HOME/Downloads"

printf '\n########## 1. RESCUING THE SAMPLERS OUT OF tmpfs ##########\n'
rin <<REOF | tee "$OUT"
B='$B'
mkdir -p "\$B"
for f in /tmp/tsp_iowatch_sampler.sh /tmp/tsp_relief_sampler.sh /tmp/tsp_sample.sh \\
         /mnt/SDCARD/tsp_memreport.sh /mnt/SDCARD/tsp_memwatch.sh \\
         /mnt/SDCARD/tsp_memwatch_ktx.sh /mnt/SDCARD/tsp_hitch.sh \\
         /mnt/SDCARD/tsp_hitch2.sh /mnt/SDCARD/tsp_post.sh; do
    [ -f "\$f" ] || continue
    cp -p "\$f" "\$B/" 2>/dev/null && \\
      printf '  rescued %-40s %s  %s\\n' "\$(basename "\$f")" \\
        "\$(md5sum "\$f" | cut -c1-12)" "\$(du -k "\$f" | cut -f1)kB"
done
printf '  -> all copies now in %s\\n' "\$B"
REOF

printf '\n########## 2. THE IOWATCH SAMPLER, VERBATIM ##########\n'
printf '  (this is the piece worth keeping - the region bucketing)\n\n'
ssh $SSHO -n "$DEV" "cat /tmp/tsp_iowatch_sampler.sh 2>/dev/null || echo '  GONE - /tmp was cleared'" | tee -a "$OUT"

printf '\n########## 3. WHERE ARE THE TEXTURES, BY DEVICE AND INODE ##########\n'
rin <<TEOF | tee -a "$OUT"
G='$G'
SD="\$G/data/Data Files/textures"
EM="/mnt/UDISK/openmw-tex"

echo "--- what kind of thing is each path"
for p in "\$SD" "\$EM"; do
    if [ -L "\$p" ]; then
        printf '  %-52s SYMLINK -> %s\n' "\$p" "\$(readlink "\$p")"
    elif [ -d "\$p" ]; then
        printf '  %-52s real directory\n' "\$p"
    else
        printf '  %-52s DOES NOT EXIST\n' "\$p"
    fi
done

echo "--- which block device each path actually lives on"
for p in "\$SD" "\$EM"; do
    [ -e "\$p" ] || continue
    printf '  %-52s %s\n' "\$p" "\$(df "\$p" 2>/dev/null | tail -1 | awk '{print \$1"  "\$6}')"
done

echo "--- ktx counts (depth 1, each path)"
for p in "\$SD" "\$EM"; do
    [ -e "\$p" ] || continue
    printf '  %-52s %s files, %s\n' "\$p" \\
      "\$(find "\$p/" -maxdepth 1 -iname '*.ktx' 2>/dev/null | wc -l)" \\
      "\$(du -sh "\$p/" 2>/dev/null | cut -f1)"
done

echo "--- THE DECIDER: same file or two copies?"
S1="\$(find "\$SD/" -maxdepth 1 -iname '*.ktx' 2>/dev/null | head -1)"
if [ -n "\$S1" ]; then
    N="\$(basename "\$S1")"
    printf '  sample file: %s\n' "\$N"
    for p in "\$SD/\$N" "\$EM/\$N"; do
        [ -e "\$p" ] || { printf '    %-56s ABSENT\n' "\$p"; continue; }
        printf '    %-56s dev+inode %s  size %s\n' "\$p" \\
          "\$(stat -c '%d:%i' "\$p" 2>/dev/null || echo '?')" \\
          "\$(stat -c '%s' "\$p" 2>/dev/null || echo '?')"
    done
    echo "  same dev+inode  = one file, reached two ways (the move IS wired up)"
    echo "  different       = two copies, and the game is reading whichever the"
    echo "                    data= line points at, i.e. the SD one"
else
    echo "  no .ktx directly under the SD textures path"
fi

echo "--- is anything bind-mounted into the game dir"
mount | grep -e openmw -e UDISK | sed 's/^/  /'

echo "--- and what the config actually says, with line numbers"
grep -n -e '^data=' -e '^fallback-archive=' "\$G/openmw.cfg" | sed 's/^/  /'
TEOF

printf '\n########## SUMMARY ##########\n'
printf '  saved to %s\n\n' "$OUT"
printf '  Section 3 answers it: same dev+inode means the textures really are\n'
printf '  being read off the eMMC and my "they are on the SD card" was simply\n'
printf '  wrong. Different inodes means there are two copies and the game is\n'
printf '  still reading the SD one, which is a one-line config fix.\n\n'
