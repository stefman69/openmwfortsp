#!/bin/sh
# tsp_decomp.sh - TSP_DECOMP_V1. Put OPENMW_DECOMPRESS_TEXTURES behind a flag
# file so it can be A/B'd without editing the launcher again.
#
#   patch     replace the hardcoded export with a guarded block (idempotent)
#   off       create the flag: the next launch runs with decompression OFF
#   on        remove the flag: back to the shipped default, ON
#   state     what the launcher and the flag say right now
#
# ---------------------------------------------------------------------------
# WHY
#
# The launcher carries one hardcoded line:
#
#     export OPENMW_DECOMPRESS_TEXTURES=1
#
# That variable exists upstream so drivers with no S3TC/DXT support can still
# show Morrowind's DDS textures: OpenMW expands them to plain RGBA on the CPU
# before upload. gl4es on GLES2 is exactly that situation, so the line was
# almost certainly added for the DDS path, long before the ASTC work existed.
#
# If it also expands the ASTC .ktx, the whole conversion is cancelled out at
# load time. That would explain the 09-14 A/B exactly: 3663 files went 138.3 MB
# DDS to 51.3 MB KTX and the process footprint did not move a megabyte -
# peak VmRSS 383 vs 383, consumed 379 vs 384. ASTC 8x8 is 2 bits/pixel against
# DXT1 4 and DXT5 8, so a real 2-4x texture-memory cut cannot be invisible.
#
# WHAT TO EXPECT WHEN IT IS OFF
#
# Two useful outcomes, and both are informative:
#
#   textures still look right  -> gl4es is passing compressed data through, and
#                                 the CONSUMED number in the next capture pair
#                                 is finally a real test of ASTC.
#   DDS textures break, ASTC   -> that IS the proof ASTC reaches the GPU
#   ones look fine                compressed. The .ktx path is working and the
#                                 flag was masking it.
#   everything breaks          -> gl4es has no compressed-texture support at all
#                                 on this driver, the conversion can never pay,
#                                 and the 45-60 minute install step should go.
#
# Nothing here is destructive. The launcher is backed up with a timestamp, the
# block defaults to the shipped behaviour, and `on` puts it back.
#
# Every remote block is a QUOTED heredoc with literal card paths. An unquoted
# one expands in the LOCAL shell first, where $L and $ARM are not set, and
# under set -u that kills the tool before it sends anything.
# ---------------------------------------------------------------------------

set -u
MODE="${1:-}"
case "$MODE" in
    patch|off|on|state) ;;
    *) echo "usage: sh $0 patch|off|on|state"
       echo "   patch   put the export behind a flag file (do this once)"
       echo "   off     next launch runs with decompression OFF"
       echo "   on      next launch runs with the shipped default, ON"
       echo "   state   what the launcher and the flag say right now"
       exit 2 ;;
esac

# Device address, in order: an explicit TSP=/DEV= in the environment, then $TSP_DEV
# as `tsp_net.sh each` sets it, then ~/.tsp_dev as `tsp_net.sh use` writes it,
# then the old hardcoded default. Every line here returns 0, so a missing
# ~/.tsp_dev cannot trip set -e.
DEV="${DEV:-${TSP_DEV:-}}"
if [ -z "${DEV}" ] && [ -r "$HOME/.tsp_dev" ]; then DEV="$(cat "$HOME/.tsp_dev")"; fi
[ -n "${DEV}" ] || DEV="root@192.168.1.12"

# WHICH CONSOLE THIS IS. Printed on EVERY run.
[ -n "${TSP_NAME:-}" ] || TSP_NAME="$(awk -F'\t' -v h="$DEV" '$2==h {print $1}' "$HOME/.tsp_hosts" 2>/dev/null | head -1)"
printf '\n  ==================  DEVICE: %s  (%s)  ==================\n' "${TSP_NAME:-UNNAMED}" "$DEV"

SSHO="-o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

say() { printf '  %s\n' "$*"; }
hr()  { printf '\n########## %s ##########\n' "$1"; }
die() { printf '\n  STOPPING: %s\n\n' "$*"; exit 1; }

rin() {
    _b64="$(base64 | tr -d '\n')"
    ssh -n $SSHO "$DEV" "T=/tmp/tsp_dc.\$\$
printf '%s' '$_b64' | base64 -d > \"\$T\" 2>/dev/null || { echo '  (no base64 on this device)'; exit 1; }
sh \"\$T\" </dev/null
_r=\$?
rm -f \"\$T\"
exit \$_r" 2>&1
}

hr "REACHABILITY"
_pf="$(ssh -n $SSHO "$DEV" 'echo TSPDC ok' 2>&1)"
case "$_pf" in
    *"TSPDC ok"*) say "ssh ok" ;;
    *"Permission denied"*|*publickey*|*"Too many authentication"*)
        die "ssh AUTH failed for $DEV. Install the key once:
      sh ~/Downloads/tsp_net.sh key $DEV" ;;
    *)  die "cannot reach $DEV. ssh said: $_pf" ;;
esac

# ===================================================================== state ==
if [ "$MODE" = "state" ]; then
    hr "THE LAUNCHER AND THE FLAG"
    rin <<'SEOF'
P=/mnt/SDCARD/Roms/PORTS
L=""
if [ -f "$P/Morrowind.sh" ]; then L="$P/Morrowind.sh"; else
    for f in "$P"/*.sh; do
        case "$f" in *ASTC*) continue ;; esac
        grep -q '/mnt/SDCARD/data/ports/openmw' "$f" 2>/dev/null && { L="$f"; break; }
    done
fi
[ -n "$L" ] || { echo "  no launcher found in $P"; exit 1; }
echo "--- launcher"
echo "    $L   ($(wc -c < "$L") bytes)"
echo "--- every mention of the variable, with line numbers"
grep -n 'OPENMW_DECOMPRESS_TEXTURES' "$L" | sed 's/^/    /'
echo "--- is it behind the flag yet"
if grep -q 'TSP_DECOMP_V1' "$L" 2>/dev/null; then echo "    YES - patched"; else echo "    NO - still a hardcoded export"; fi
echo "--- the flag file"
if [ -f /mnt/SDCARD/tsp_decomp_off ]; then
    echo "    /mnt/SDCARD/tsp_decomp_off PRESENT  -> decompression OFF next launch"
else
    echo "    /mnt/SDCARD/tsp_decomp_off absent   -> decompression ON (shipped default)"
fi
echo "--- what the last launches recorded"
grep 'TSP_DECOMP_V1' /mnt/SDCARD/tsp_prog.txt 2>/dev/null | tail -5 | sed 's/^/    /' \
  || echo "    nothing yet - the patched launcher has not run"
echo "--- and in the live process, if the game is up"
PID="$(pidof openmw-0.51 2>/dev/null)"; PID="${PID%% *}"
if [ -n "$PID" ] && [ -r "/proc/$PID/environ" ]; then
    if tr '\0' '\n' < "/proc/$PID/environ" | grep '^OPENMW_DECOMPRESS_TEXTURES=' ; then :
    else echo "    ABSENT from the running process - decompression is OFF right now"; fi
else
    echo "    game not running"
fi
SEOF
    printf '\n'
    exit 0
fi

# ================================================================== off / on ==
if [ "$MODE" = "off" ] || [ "$MODE" = "on" ]; then
    hr "FLIPPING THE FLAG"
    if [ "$MODE" = "off" ]; then
        rin <<'FEOF'
P=/mnt/SDCARD/Roms/PORTS
L=""
if [ -f "$P/Morrowind.sh" ]; then L="$P/Morrowind.sh"; else
    for f in "$P"/*.sh; do
        case "$f" in *ASTC*) continue ;; esac
        grep -q '/mnt/SDCARD/data/ports/openmw' "$f" 2>/dev/null && { L="$f"; break; }
    done
fi
if [ -n "$L" ] && ! grep -q 'TSP_DECOMP_V1' "$L" 2>/dev/null; then
    echo "  REFUSING: the launcher is NOT patched yet, so this flag does nothing."
    echo "  The export is still hardcoded. Run:  sh \$0 patch"
    exit 1
fi
: > /mnt/SDCARD/tsp_decomp_off
echo "  created /mnt/SDCARD/tsp_decomp_off"
echo "  the NEXT launch runs with OPENMW_DECOMPRESS_TEXTURES unset."
FEOF
    else
        rin <<'FEOF'
rm -f /mnt/SDCARD/tsp_decomp_off
echo "  removed /mnt/SDCARD/tsp_decomp_off"
echo "  the NEXT launch runs with the shipped default, decompression ON."
FEOF
    fi
    printf '\n'
    exit 0
fi

# ===================================================================== patch ==
hr "PATCHING THE LAUNCHER"
rin 2>&1 <<'PEOF'
P=/mnt/SDCARD/Roms/PORTS
L=""
if [ -f "$P/Morrowind.sh" ]; then L="$P/Morrowind.sh"; else
    for f in "$P"/*.sh; do
        case "$f" in *ASTC*) continue ;; esac
        grep -q '/mnt/SDCARD/data/ports/openmw' "$f" 2>/dev/null && { L="$f"; break; }
    done
fi
if [ -z "$L" ]; then echo "  no Morrowind launcher found in $P"; echo "  TSPDC_FATAL no_launcher"; exit 1; fi
echo "--- launcher"
echo "    $L   ($(wc -c < "$L") bytes)"

if grep -q 'TSP_DECOMP_V1' "$L" 2>/dev/null; then
    echo "--- already patched, nothing to do"
    grep -n 'TSP_DECOMP_V1\|OPENMW_DECOMPRESS_TEXTURES' "$L" | sed 's/^/    /'
    exit 0
fi

echo "--- the line to replace, as it is now"
N="$(grep -cE '^[[:space:]]*export OPENMW_DECOMPRESS_TEXTURES=1[[:space:]]*$' "$L")"
grep -nE '^[[:space:]]*export OPENMW_DECOMPRESS_TEXTURES=1[[:space:]]*$' "$L" | sed 's/^/    /'
echo "    matches: $N"
if [ "$N" != 1 ]; then
    echo "  REFUSING: expected exactly one hardcoded export, found $N."
    echo "  Every other mention in this launcher is a read, not a set:"
    grep -n 'OPENMW_DECOMPRESS_TEXTURES' "$L" | sed 's/^/      /'
    echo "  TSPDC_FATAL wrong_match_count"
    exit 1
fi

B="$L.before-decomp-$(date '+%Y%m%d-%H%M%S')"
cp -f "$L" "$B" || { echo "  TSPDC_FATAL backup_failed"; exit 1; }
echo "--- backup"
echo "    $B   ($(wc -c < "$B") bytes)"

# Replace the single hardcoded export with the guarded block. awk, not sed:
# a multi-line replacement through sed on busybox is where quoting goes wrong.
# No apostrophes anywhere in the program text - one inside a single-quoted awk
# program terminates it.
awk '
/^[[:space:]]*export OPENMW_DECOMPRESS_TEXTURES=1[[:space:]]*$/ && !seen {
    print "# TSP_DECOMP_V1 - OPENMW_DECOMPRESS_TEXTURES makes OpenMW expand compressed"
    print "# textures to plain RGBA on the CPU before upload. It is here for the DDS"
    print "# path, because gl4es on GLES2 has no S3TC - but it also expands the ASTC"
    print "# .ktx, which would cancel the whole texture conversion at load time and"
    print "# is the only mechanism that explains the 09-14 A/B measuring nothing:"
    print "# 138.3 MB DDS -> 51.3 MB KTX on disk, and peak VmRSS 383 vs 383 MB."
    print "# Default is the shipped behaviour. Off: touch /mnt/SDCARD/tsp_decomp_off"
    print "if [ -f /mnt/SDCARD/tsp_decomp_off ]; then"
    print "    unset OPENMW_DECOMPRESS_TEXTURES"
    print "    echo \"TSP_DECOMP_V1 decompress OFF (tsp_decomp_off present)\" >> /mnt/SDCARD/tsp_prog.txt"
    print "else"
    print "    export OPENMW_DECOMPRESS_TEXTURES=1"
    print "    echo \"TSP_DECOMP_V1 decompress ON (shipped default)\" >> /mnt/SDCARD/tsp_prog.txt"
    print "fi"
    seen = 1
    next
}
{ print }
' "$L" > "$L.new" || { echo "  TSPDC_FATAL awk_failed"; rm -f "$L.new"; exit 1; }

# Three assertions before anything is moved into place. The gltarm lesson: a
# patcher that reports success on an unchanged file costs a whole session.
echo "--- assertions before the file is moved into place"
M="$(grep -c 'TSP_DECOMP_V1' "$L.new")"
U="$(grep -cE '^[[:space:]]*export OPENMW_DECOMPRESS_TEXTURES=1[[:space:]]*$' "$L.new")"
printf '    TSP_DECOMP_V1 lines in the new file: %s  (want 3)\n' "$M"
printf '    exports now inside the guard:        %s  (want 1, indented)\n' "$U"
if [ "$M" -lt 3 ]; then echo "  TSPDC_FATAL block_not_inserted"; rm -f "$L.new"; exit 1; fi
if sh -n "$L.new" 2>/dev/null; then
    echo "    sh -n on the new file:               PARSES"
else
    echo "    sh -n on the new file:               SYNTAX ERROR"
    sh -n "$L.new" 2>&1 | sed 's/^/      /'
    echo "  TSPDC_FATAL new_file_does_not_parse"
    rm -f "$L.new"
    exit 1
fi
OLDB="$(wc -c < "$L")"; NEWB="$(wc -c < "$L.new")"
printf '    bytes: %s -> %s\n' "$OLDB" "$NEWB"
if [ "$NEWB" -le "$OLDB" ]; then echo "  TSPDC_FATAL new_file_not_larger"; rm -f "$L.new"; exit 1; fi

# Preserve the mode bits, then swap.
chmod --reference="$L" "$L.new" 2>/dev/null || chmod 755 "$L.new" 2>/dev/null
mv -f "$L.new" "$L" || { echo "  TSPDC_FATAL move_failed"; exit 1; }
sync

echo "--- the launcher now, around the change"
grep -n -A1 -B1 'TSP_DECOMP_V1\|OPENMW_DECOMPRESS_TEXTURES' "$L" | sed 's/^/    /'
echo "--- and it still parses in place"
if sh -n "$L" 2>/dev/null; then echo "    PARSES"; else echo "    SYNTAX ERROR - restore the backup above"; fi
echo "--- executable"
[ -x "$L" ] && echo "    yes" || echo "    NO - the menu may refuse it, chmod +x it"
PEOF

printf '\n'
hr "WHAT TO DO NOW"
say "The launcher is patched and still on its shipped default (ON), so nothing"
say "has changed about how the game runs yet. To take decompression off for the"
say "next launch:"
printf '\n'
printf '      TSP_DEV=%s sh ~/Downloads/tsp_decomp.sh off\n' "$DEV"
printf '\n'
say "Then launch from Morrowind ASTC ON in the Ports menu and look at the"
say "textures. Three outcomes, all of them worth having:"
printf '\n'
say "  everything looks right   gl4es passes compressed data through, and the"
say "                           next capture pair is a real ASTC test at last."
say "  DDS broken, ASTC fine    that IS proof the .ktx reach the GPU compressed"
say "                           and this flag was cancelling the conversion."
say "  everything broken        gl4es cannot do compressed textures on this"
say "                           driver, ASTC can never pay, drop the install step."
printf '\n'
say "Put it back either way with:"
printf '\n'
printf '      TSP_DEV=%s sh ~/Downloads/tsp_decomp.sh on\n' "$DEV"
printf '\n'
say "The flag lives on the SD card, so it can be removed over ssh even if the"
say "screen comes up black. And the capture from tsp_ktxswitch.sh already reads"
say "OPENMW_DECOMPRESS_TEXTURES out of the live process, so every run records"
say "which way it was set - no bookkeeping needed."
printf '\n'
exit 0
