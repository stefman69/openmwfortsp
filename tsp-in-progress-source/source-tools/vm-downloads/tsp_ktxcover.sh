#!/bin/sh
# tsp_ktxcover.sh - do the .ktx textures ACTUALLY get used, and how many.
#
#   probe    read-only, no game run: can this card answer the question at all
#   mark     stamp a reference time, immediately before you launch
#   count    after the session: how many .ktx were actually read, and where
#
# ---------------------------------------------------------------------------
# WHY THE OBVIOUS METHOD DOES NOT WORK
#
# You cannot count loads from the log. components/resource/imagemanager.cpp:214
#
#     static int tspKtxLogged = 0;
#     if (tspKtxLogged < 8)
#
# caps the TSP_KTX_V1 lines at eight BY DESIGN. "8 lines" has now twice been
# mistaken for "8 textures loaded" - once on 09-12, once by me on 09-13 - and a
# whole false conclusion was built on it the second time. Eight is a limiter.
#
# Replacing that cap with a real counter is bucket-list item 05 and needs a
# rebuild. This tool answers the same question WITHOUT one, by asking the
# filesystem which files were read.
#
# HOW: ACCESS TIME
#
# If /mnt/SDCARD records access times, then reading a .ktx bumps its atime.
# Stamp a reference file before launching, play, and afterwards every .ktx with
# an atime newer than the stamp was opened by the engine. That is a per-file
# census of real use across all 4555 of them, not a sample.
#
# The catch is that SD cards are very often mounted noatime to save writes, and
# then this cannot work at all. So `probe` does not assume: it reads
# /proc/mounts AND then proves it empirically by reading one file and checking
# whether its atime actually moved. If it did not, `probe` says so plainly and
# names the alternatives rather than producing a confident zero.
#
# BUSYBOX. The first version of this used `find -anewer STAMP`, which is GNU
# only - busybox find does not have it, so on the stock card every root would
# have reported 0 hits and looked like a devastating result. Verified against
# busybox 1.36.1, the same build the card runs, the only primitives available
# are -atime / -amin / -newer(mtime) and `touch -a -t`. So instead of comparing
# against a stamp file, `mark` BACKDATES the atime of every .ktx to 2001, and
# `count` asks which ones are no longer 2001. That is exact rather than
# minute-granular, and it uses nothing GNU.
#
# WHAT "USED" MEANS HERE
#
# An atime hit means the engine OPENED that .ktx. That is exactly the question:
# tspPreferKtx() swaps a resolved .dds for a sibling .ktx only when the VFS has
# one, so a .ktx that is never opened is a .ktx the engine decided not to use.
# It does not tell you the texture reached the GPU uncompressed or not - the
# TSP_KTX_V1 lines already prove the format arrives intact (fmt 37815 =
# GL_COMPRESSED_RGBA_ASTC_8x8_KHR with a full mip chain).
#
# KNOWN GAPS, so a shortfall is not misread as a bug. From
# RESULT-astc-ktx-textures-are-the-memory-fix-20260910:
#     4555 unique textures eligible after archive precedence
#     3663 converted        892 SKIPPED as smaller than 128px
#     excluded by name: menu 192, magicitem 32, _n. 24, cursor 4, icon 4
# So the ceiling is 3663, not 4555, and UI/menu art and normal maps are
# deliberately absent. A count well under 3663 is still meaningful: most of a
# texture set is not on screen in any one area.
# ---------------------------------------------------------------------------

set -u
# Device address, in order: an explicit DEV= in the environment, then $TSP_DEV
# as `tsp_net.sh each` sets it, then ~/.tsp_dev as `tsp_net.sh use` writes it,
# then the old hardcoded default. Every line returns 0 so a missing ~/.tsp_dev
# cannot trip set -e.
DEV="${DEV:-${TSP_DEV:-}}"
if [ -z "${DEV}" ] && [ -r "$HOME/.tsp_dev" ]; then DEV="$(cat "$HOME/.tsp_dev")"; fi
[ -n "${DEV}" ] || DEV="root@192.168.1.12"

# WHICH CONSOLE THIS IS. Two consoles are in play and unlabelled output is not
# a result.
[ -n "${TSP_NAME:-}" ] || TSP_NAME="$(awk -F'\t' -v h="$DEV" '$2==h {print $1}' "$HOME/.tsp_hosts" 2>/dev/null | head -1)"
printf '\n  ==================  DEVICE: %s  (%s)  ==================\n' "${TSP_NAME:-UNNAMED}" "$DEV"

G="/mnt/SDCARD/data/ports/openmw"
CFG="$G/config/openmw.cfg"
CFGBIN="$G/bin/openmw.cfg"
STAMPF="/mnt/SDCARD/tsp_ktxcover.stamp"
SSHO="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes -o LogLevel=ERROR"

MODE="${1:-probe}"
case "$MODE" in probe | mark | count) ;;
*) printf 'usage: %s probe | mark | count\n' "$0"; exit 2 ;; esac

say() { printf '  %s\n' "$*"; }
hr()  { printf '\n########## %s ##########\n' "$1"; }
die() { printf '\n  STOPPING: %s\n\n' "$*"; exit 1; }

# The probe goes as base64 inside the ssh COMMAND and is decoded to a file on
# the device, then run with </dev/null. Delivered on the remote shell stdin,
# anything it invokes that reads stdin eats the rest of the script - which is
# how the scope probe got truncated on .21, where /bin/bash is busybox and does
# not understand --version.
rin() {
    _b64="$(base64 | tr -d '\n')"
    ssh -n $SSHO "$DEV" "T=/tmp/tsp_ktxcover.\$\$
printf '%s' '$_b64' | base64 -d > \"\$T\" 2>/dev/null || { echo '  (no base64 on this device)'; exit 1; }
sh \"\$T\" </dev/null
_r=\$?
rm -f \"\$T\"
exit \$_r" 2>&1
}

_pf="$(ssh $SSHO -n "$DEV" "echo ok" 2>&1)"
case "$_pf" in
    *ok*) ;;
    *"Permission denied"*|*"publickey"*|*"Too many authentication"*)
        die "ssh AUTH failed for $DEV. Every tool here uses BatchMode and refuses
  passwords on purpose. Install the key once:
      sh ~/Downloads/tsp_net.sh key $DEV" ;;
    *)  die "cannot reach $DEV. ssh said: $_pf" ;;
esac

# ==================================================================== probe ===
if [ "$MODE" = "probe" ]; then
    hr "1. CAN THIS CARD ANSWER THE QUESTION"
    rin <<'P1EOF'
echo "  --- how /mnt/SDCARD is mounted ---"
awk '$2 == "/mnt/SDCARD" || $2 == "/mnt/UDISK" {printf "    %s on %s  type %s\n      %s\n", $1, $2, $3, $4}' /proc/mounts
echo "  --- does atime ACTUALLY move? proving it rather than trusting the flag ---"
T=/mnt/SDCARD/tsp_ktxcover.atimetest
printf 'x' > "$T" 2>/dev/null || { echo "    cannot write to /mnt/SDCARD - card read-only?"; exit 1; }
# Backdate to 2001, read it, then ask find whether the atime is recent. No
# --time-style and no -anewer: both are GNU and this card is busybox.
touch -a -t 200101010000 "$T" 2>/dev/null
echo "    after touch -a -t 2001, listed as:"
ls -lu "$T" 2>/dev/null | sed 's/^/      /'
# ASSERT THE BACKDATE TOOK. Without this the next check is circular: a
# filesystem that ignores atime writes leaves the atime current, the
# read-recently test then passes, and the tool reports ATIME WORKS while the
# whole method is inert. That is exactly what happened on .12.
OLD="$(find "$T" -atime +30 2>/dev/null | wc -l)"
if [ "$OLD" != "1" ]; then
    echo "    BACKDATE DID NOT TAKE - this filesystem ignores atime writes."
    echo "    mark/count CANNOT work here. Not a zero result, no result."
    echo "    Alternatives:"
    echo "      - run the census on the other card, if its driver honours it"
    echo "      - libtsp_files.so is a file-access tracer already on the card"
    echo "        (LIBGL_TSP_FILES, and it prints: OPEN fd=%-4d <path>)"
    echo "      - bucket-list item 05: replace the < 8 log cap, one rebuild"
    rm -f "$T"
    exit 1
fi
echo "    backdate took (reads as over 30 days old)"
cat "$T" > /dev/null 2>&1
sync
MOVED="$(find "$T" -amin -3 2>/dev/null | wc -l)"
echo "    after one read, listed as:"
ls -lu "$T" 2>/dev/null | sed 's/^/      /'
if [ "$MOVED" = "1" ]; then
    echo "    ATIME WORKS on this card - the census in mark/count is valid"
else
    echo "    ATIME DOES NOT MOVE. This card cannot be censused this way."
    echo "    Alternatives, in order of cost:"
    echo "      - bucket-list item 05: replace the < 8 log cap with a real"
    echo "        counter. One rebuild, and it makes this provable forever."
    echo "      - bucket-list item 04: the magenta test. Unset"
    echo "        OPENMW_DECOMPRESS_TEXTURES and walk - anything still arriving"
    echo "        as S3TC DDS renders magenta, giving a visual coverage map."
fi
rm -f "$T"
P1EOF

    hr "2. WHAT IS ON THE CARD, ACROSS EVERY data= ROOT"
    say "Not two roots. The last census only looked at two of them and missed"
    say "the loose conversions written beside their sources inside the mods."
    rin <<P2EOF
C='$CFG'
CB='$CFGBIN'
[ -f "\$C" ] || { echo "  no openmw.cfg at \$C"; exit 1; }
TOT=0
# The VFS applies data= in order and the LAST one wins, so print them in order.
# BOTH configs, deduped. bin/openmw.cfg carries the base Data Files root and
# mods/openmw-tex; config/openmw.cfg carries the mods. Reading one gets a
# fraction of the texture set.
{ sed -n 's/^data=//p' "\$CB" 2>/dev/null; sed -n 's/^data=//p' "\$C" 2>/dev/null; } \
  | tr -d '"' | awk '!seen[\$0]++' | while IFS= read -r d; do
    [ -d "\$d" ] || { printf '    MISSING ROOT  %s\n' "\$d"; continue; }
    # -maxdepth on ONE named directory. A recursive scan of the whole card once
    # saturated the SD and produced a five-minute 0-1 fps load.
    K=0
    [ -d "\$d/textures" ] && K="\$(find "\$d/textures" -maxdepth 2 -iname '*.ktx' 2>/dev/null | wc -l)"
    D=0
    [ -d "\$d/textures" ] && D="\$(find "\$d/textures" -maxdepth 2 -iname '*.dds' 2>/dev/null | wc -l)"
    printf '    %5s ktx  %5s dds   %s\n' "\$K" "\$D" "\$d"
done
echo "  --- the converter own marker, which says what it did ---"
M='$G/data/Data Files/tsp_texconv.done'
[ -f "\$M" ] && sed 's/^/    /' "\$M" || echo "    no marker at \$M"
P2EOF

    hr "3. IS THERE A FILE TRACER ALREADY ON THE CARD"
    say "libtsp_files.so is in the port lib dir. If it traces opens it answers"
    say "this directly, so read its knobs rather than assuming what it does."
    rin <<P3EOF
L='$G/lib/libtsp_files.so'
if [ -f "\$L" ]; then
    printf '    %s  %s bytes\n' "\$L" "\$(wc -c < "\$L")"
    echo "    env knobs it reads:"
    strings -a "\$L" 2>/dev/null | grep -E '^TSP_[A-Z0-9_]+\$' | sort -u | sed 's/^/      /'
    echo "    strings that look like an output path or a log tag:"
    strings -a "\$L" 2>/dev/null | grep -iE 'tsp_files|open|fopen|/mnt/' | sort -u | head -8 | sed 's/^/      /'
else
    echo "    not present"
fi
P3EOF

    printf '\n'
    hr "WHAT TO DO NEXT"
    say "If section 1 said ATIME WORKS:"
    printf '\n      sh %s mark      <- immediately before launching\n' "$0"
    printf '      sh %s count     <- after quitting\n\n' "$0"
    say "If it said atime does not move, stop here and tell me - the answer is"
    say "a rebuild with a real counter, not another run."
    printf '\n'
    exit 0
fi

# ===================================================================== mark ===
if [ "$MODE" = "mark" ]; then
    hr "BACKDATING EVERY .ktx SO A READ STANDS OUT"
    say "This touches metadata only - no file contents are written - and it is"
    say "the step that makes the count exact. It prints each root as it goes so"
    say "it is never silently working."
    printf '\n'
    rin <<MEOF
S='$STAMPF'
C='$CFG'
CB='$CFGBIN'
[ -f "\$C" ] || { echo "  no openmw.cfg at \$C"; exit 1; }
N=0
# BOTH configs, deduped. bin/openmw.cfg carries the base Data Files root and
# mods/openmw-tex; config/openmw.cfg carries the mods. Reading one gets a
# fraction of the texture set.
{ sed -n 's/^data=//p' "\$CB" 2>/dev/null; sed -n 's/^data=//p' "\$C" 2>/dev/null; } \
  | tr -d '"' | awk '!seen[\$0]++' | while IFS= read -r d; do
    [ -d "\$d/textures" ] || continue
    K="\$(find "\$d/textures" -maxdepth 2 -iname '*.ktx' 2>/dev/null | wc -l)"
    [ "\$K" -gt 0 ] || continue
    printf '    backdating %5s ktx in %s ... ' "\$K" "\$d"
    find "\$d/textures" -maxdepth 2 -iname '*.ktx' -exec touch -a -t 200101010000 {} + 2>/dev/null
    LEFT="\$(find "\$d/textures" -maxdepth 2 -iname '*.ktx' -atime -30 2>/dev/null | wc -l)"
    if [ "\$LEFT" = "0" ]; then echo "done"; else echo "\$LEFT did not take"; fi
done
date '+%Y-%m-%d %H:%M:%S' > "\$S" 2>/dev/null
sync
printf '    marker: %s\n' "\$(cat "\$S" 2>/dev/null)"
echo "    every .ktx now reads as 2001. Anything the engine opens moves."
MEOF
    printf '\n'
    printf '      sh %s count     <- after you quit\n\n' "$0"
    exit 0
fi

# ==================================================================== count ===
hr "HOW MANY .ktx WERE ACTUALLY READ"
rin <<CEOF
S='$STAMPF'
C='$CFG'
CB='$CFGBIN'
[ -f "\$S" ] || { echo "  no stamp at \$S - run mark before the session"; exit 1; }
[ -f "\$C" ] || { echo "  no openmw.cfg"; exit 1; }
printf '  marked at: %s\n' "\$(cat "\$S" 2>/dev/null)"
# A zero is meaningless if the game never launched. That ambiguity cost a
# whole cycle: mark and count were run back to back with no session between.
L='$G/openmw_log.txt'
if [ -f "\$L" ]; then
    if [ "\$L" -nt "\$S" ]; then
        echo "  the game HAS run since the mark (log is newer than the stamp)"
    else
        echo "  *** THE GAME HAS NOT RUN SINCE THE MARK ***"
        echo "  The log is older than the stamp, so a zero below means no"
        echo "  session happened - it is not a result. Launch, play, re-run."
    fi
else
    echo "  no openmw log at all - has the game ever run on this card?"
fi
echo

LIST=/tmp/ktxhits.\$\$
: > "\$LIST"
# -atime -30 means "accessed within the last 30 days". mark set every .ktx to
# 2001, so anything inside 30 days was opened since. NOT -anewer: that is GNU
# and busybox find does not have it - it would have reported 0 everywhere.
# BOTH configs, deduped. bin/openmw.cfg carries the base Data Files root and
# mods/openmw-tex; config/openmw.cfg carries the mods. Reading one gets a
# fraction of the texture set.
{ sed -n 's/^data=//p' "\$CB" 2>/dev/null; sed -n 's/^data=//p' "\$C" 2>/dev/null; } \
  | tr -d '"' | awk '!seen[\$0]++' | while IFS= read -r d; do
    [ -d "\$d/textures" ] || continue
    T="\$(find "\$d/textures" -maxdepth 2 -iname '*.ktx' 2>/dev/null | wc -l)"
    [ "\$T" -gt 0 ] || continue
    find "\$d/textures" -maxdepth 2 -iname '*.ktx' -atime -30 2>/dev/null >> "\$LIST"
    H="\$(find "\$d/textures" -maxdepth 2 -iname '*.ktx' -atime -30 2>/dev/null | wc -l)"
    printf '    read %5s of %5s   %s\n' "\$H" "\$T" "\$d"
done

echo
TOT="\$(wc -l < "\$LIST")"
printf '  TOTAL .ktx opened since the stamp: %s\n' "\$TOT"
echo "  ceiling is 3663 - the 892 under 128px were never converted, and"
echo "  menu/magicitem/normal-map/cursor/icon art was excluded by name."
echo
echo "  --- the first 15, so you can see they are real world textures ---"
sort "\$LIST" | head -15 | sed 's#.*/textures/#      textures/#'
echo "  --- and how they split by subdirectory ---"
sed 's#/[^/]*\$##' "\$LIST" | sort | uniq -c | sort -rn | head -8 | sed 's/^/      /'
rm -f "\$LIST"

echo
echo "  --- cross-check against the log, which is CAPPED at 8 and is not a count ---"
grep -c 'TSP_KTX_V1 loaded' '$G/openmw_log.txt' 2>/dev/null | sed 's/^/      log lines: /'
grep -m1 'TSP_KTX' /mnt/SDCARD/tsp_intocc.env 2>/dev/null | sed 's/^/      env says: /'
CEOF
printf '\n'
say "A number well under 3663 is normal - one route does not touch a whole"
say "texture set. A number near ZERO with TSP_KTX=1 means the engine is not"
say "choosing them, and that is the real bug you suspected."
printf '\n'
