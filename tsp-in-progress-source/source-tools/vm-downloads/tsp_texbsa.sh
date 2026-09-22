#!/bin/sh
# tsp_texbsa.sh - convert the textures that are INSIDE the BSAs to ASTC.
#
#   plan      read-only: can this run, where should it write, is there room
#   go        start it in the background, resumable, with a progress log
#   status    how far it has got
#   stop      kill it (a later go resumes where it stopped)
#
# ---------------------------------------------------------------------------
# WHY. TSP_KTX=1 is on and doing essentially nothing.
#
# tsp_ktxwhy on the base TSP:
#
#     4481 ktx in Data Files/textures      4481 ktx in /mnt/UDISK/openmw-tex
#     total TSP_KTX_V1 lines: 8
#
#     a texture Balmora certainly needs:
#       tx_wood_rough      Data Files:0  openmw-tex:0
#       tx_stucco_brown    Data Files:0  openmw-tex:0
#       tx_rock_brown      Data Files:1  openmw-tex:1
#       tx_ashl_wall       Data Files:0  openmw-tex:0
#
# Three of the four textures Balmora draws have NO .ktx at all. The 4481 that
# exist are the LOOSE files that were already on the card, converted host-side
# and deployed as a tarball. The textures the game actually draws live inside
# Morrowind.bsa / Tribunal.bsa / Bloodmoon.bsa and have never been converted.
# The eight that do load are sky and star textures, which happen to be loose.
#
# The loader is not the problem. tspPreferKtx() in resourcehelpers.cpp does
# exactly what it says: resolve to .dds, then swap to a sibling .ktx if the VFS
# has one. There is no sibling for almost anything.
#
# WHY IT NEVER HAPPENED. openmw_manager_action.sh texconv_run_pass still builds
# the archive arguments the broken way - CRITICAL-texconv-bsa-argv-splitting-bug
# documented the fix but this controller still has `tex_args` with `IFS='|'`,
# which joins on a space and splits only on '|', so tsp_texconv received
# argv[1]=" --bsa" and exited 2 before opening a single archive. So the BSA
# conversion has never run. This tool calls the converter directly with POSIX
# positional accumulation, which is quote-safe with the space in "Data Files".
#
# AND WHY IT IS THE AGNOSTIC FIX. The base TSP has no GPU clock control, its
# CPU is already at performance/2.0 GHz on all four cores, and its walk-phase
# major faults are a median of 0 - so memory and clocks are both exhausted as
# levers there. What is left is draw: mean render 80.3 ms = cull 16.1 + draw
# 54.1 + resid 10.2, and a hitch over a good frame costs draw +18.7 ms against
# cull +2.6. Every texture it draws is currently DDS out of a BSA. ASTC 8x8 is
# 2 bpp against DXT1 4 / DXT5 8, and gl4es hands ASTC straight to GLES with no
# CPU decompress, no pixel_convert and no halfscale chain. That cuts bytes per
# frame and upload cost on both consoles, whoever made the GPU.
#
# WHERE IT WRITES, AND WHY THAT MATTERS. Data Files/textures holds 4481 .ktx
# reported as 571.6M, while the SAME 4481 files on /mnt/UDISK are 62.4M. That
# is a ~9x allocation penalty: the card is formatted with large clusters, so a
# 14 KB ASTC file occupies a whole 128 KB cluster. Converting tens of thousands
# more onto the card would cost gigabytes of slack for a few hundred MB of
# data. /mnt/UDISK/openmw-tex is already the LAST data= root, so the VFS
# prefers it, and it does not have that penalty. plan measures both and says
# which one this card should use rather than assuming.
# ---------------------------------------------------------------------------

set -u
# Device address, in order: an explicit DEV= in the environment, then $TSP_DEV
# as `tsp_net.sh each` sets it, then ~/.tsp_dev as `tsp_net.sh use` writes it,
# then the old hardcoded default. Two cards do not share an address, and a tool
# pointed at the wrong one reports that card state as if it were this one.
# Every line here returns 0, so a missing ~/.tsp_dev cannot trip set -e.
DEV="${DEV:-${TSP_DEV:-}}"
if [ -z "${DEV}" ] && [ -r "$HOME/.tsp_dev" ]; then DEV="$(cat "$HOME/.tsp_dev")"; fi
[ -n "${DEV}" ] || DEV="root@192.168.1.12"

# WHICH CONSOLE THIS IS. Printed on EVERY run, and it goes into the saved log
# too. With two consoles in play, output that does not name the device it
# touched is not a result.
[ -n "${TSP_NAME:-}" ] || TSP_NAME="$(awk -F'\t' -v h="$DEV" '$2==h {print $1}' "$HOME/.tsp_hosts" 2>/dev/null | head -1)"
printf '\n  ==================  DEVICE: %s  (%s)  ==================\n' "${TSP_NAME:-UNNAMED}" "$DEV"

G="/mnt/SDCARD/data/ports/openmw"
DATA="$G/data/Data Files"
TOOL="$G/tools/tsp_texconv"
UDISK="/mnt/UDISK/openmw-tex"
RLOG="/mnt/SDCARD/tsp_texbsa.log"
RPID="/mnt/SDCARD/tsp_texbsa.pid"
SSHO="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes -o LogLevel=ERROR"

MODE="${1:-plan}"
case "$MODE" in plan | go | status | stop) ;;
*) printf 'usage: %s plan | go | status | stop\n' "$0"; exit 2 ;; esac

say() { printf '  %s\n' "$*"; }
hr()  { printf '\n########## %s ##########\n' "$1"; }
die() { printf '\n  STOPPING: %s\n\n' "$*"; exit 1; }

# The probe travels as base64 inside the ssh COMMAND and is decoded to a file
# on the device, then run with </dev/null. Delivered on stdin instead, anything
# it invokes that reads stdin eats the rest of the script - which is exactly
# how the scope probe got truncated on the stock card.
rin() {
    _b64="$(base64 | tr -d '\n')"
    ssh -n $SSHO "$DEV" "T=/tmp/tsp_texbsa.\$\$
printf '%s' '$_b64' | base64 -d > \"\$T\" 2>/dev/null || { echo '  (no base64 on this device)'; exit 1; }
sh \"\$T\" </dev/null
_r=\$?
rm -f \"\$T\"
exit \$_r" 2>&1
}
r() { ssh -n $SSHO "$DEV" "$1" 2>&1; }

_pf="$(ssh $SSHO -n "$DEV" "echo ok" 2>&1)"
case "$_pf" in
    *ok*) ;;
    *"Permission denied"*|*"publickey"*|*"Too many authentication"*)
        die "ssh AUTH failed for $DEV. Install the key once:
      sh ~/Downloads/tsp_net.sh key $DEV" ;;
    *)  die "cannot reach $DEV. ssh said: $_pf" ;;
esac

# ==================================================================== stop ===
if [ "$MODE" = "stop" ]; then
    hr "STOPPING THE CONVERSION"
    rin <<STOPEOF
P="\$(cat '$RPID' 2>/dev/null)"
if [ -n "\$P" ] && kill -0 "\$P" 2>/dev/null; then
    kill "\$P" 2>/dev/null
    sleep 1
    kill -9 "\$P" 2>/dev/null
    echo "  killed pid \$P"
else
    echo "  nothing running (no live pid in $RPID)"
fi
rm -f '$RPID'
echo "  the converter skips any .ktx that already exists, so 'go' resumes"
echo "  from here rather than starting over."
STOPEOF
    printf '\n'; exit 0
fi

# ================================================================== status ===
if [ "$MODE" = "status" ]; then
    hr "HOW FAR IT HAS GOT"
    rin <<STATEOF
P="\$(cat '$RPID' 2>/dev/null)"
if [ -n "\$P" ] && kill -0 "\$P" 2>/dev/null; then
    echo "  RUNNING, pid \$P"
else
    echo "  not running"
fi
if [ -f '$RLOG' ]; then
    echo "  --- the last 12 lines of the converter own log ---"
    tail -12 '$RLOG' | sed 's/^/    /'
    echo "  --- counted from the log ---"
    printf '    fatal lines:     %s\n' "\$(grep -c 'TSP_TEXCONV_V1 fatal' '$RLOG' 2>/dev/null)"
    printf '    done lines:      %s\n' "\$(grep -c 'TSP_TEXCONV_V1 done' '$RLOG' 2>/dev/null)"
else
    echo "  no log at $RLOG yet"
fi
for d in '$DATA/textures' '$UDISK/textures'; do
    [ -d "\$d" ] || continue
    printf '  %s\n    %s ktx now\n' "\$d" \\
      "\$(find "\$d" -maxdepth 2 -iname '*.ktx' 2>/dev/null | wc -l)"
done
df -h /mnt/UDISK /mnt/SDCARD 2>/dev/null | sed 's/^/    /'
STATEOF
    printf '\n'
    say "Watch it with this same command. Stop it with: stop"
    printf '\n'
    exit 0
fi

# ==================================================== plan (and go preflight) =
hr "1. IS THE CONVERTER EVEN ON THIS CARD"
rin <<PRE1EOF
if [ -x '$TOOL' ]; then
    printf '  tool:  %s  %s bytes\n' '$TOOL' "\$(wc -c < '$TOOL')"
else
    echo "  TOOL MISSING or not executable: $TOOL"
    echo "  Nothing can be converted on this card until it is there."
fi
echo "  --- the archives it would read ---"
N=0
for f in Morrowind.bsa Tribunal.bsa Bloodmoon.bsa; do
    if [ -f '$DATA'/"\$f" ]; then
        printf '    %-16s %s bytes\n' "\$f" "\$(wc -c < '$DATA'/"\$f")"
        N=\$((N + 1))
    else
        printf '    %-16s ABSENT\n' "\$f"
    fi
done
printf '  %s archive(s) present\n' "\$N"
PRE1EOF

hr "2. WHERE IT SHOULD WRITE"
say "Both roots hold the same 4481 files. The size difference is filesystem"
say "slack, not content - and it decides where tens of thousands more can go."
rin <<PRE2EOF
for d in '$DATA/textures' '$UDISK/textures'; do
    if [ -d "\$d" ]; then
        printf '  %s\n' "\$d"
        printf '    %s ktx    apparent %s\n' \\
          "\$(find "\$d" -maxdepth 2 -iname '*.ktx' 2>/dev/null | wc -l)" \\
          "\$(du -sh "\$d" 2>/dev/null | awk '{print \$1}')"
    else
        printf '  %s   ABSENT\n' "\$d"
    fi
done
echo "  --- free space ---"
df -h /mnt/UDISK /mnt/SDCARD 2>/dev/null | sed 's/^/    /'
echo "  --- and is /mnt/UDISK/openmw-tex actually a data= root ---"
grep -n '^data=' '$G/config/openmw.cfg' 2>/dev/null | sed 's/^/    /'
PRE2EOF

hr "3. THE EXACT ARGV IT WILL USE"
say "Positional accumulation, not a delimiter-joined string. The manager still"
say "builds this with tex_args and IFS='|', which joins on a space and splits"
say "only on '|', so the tool got argv[1]=\" --bsa\" and exited 2 before opening"
say "an archive. That is why the BSA conversion has never run."
printf '\n'
say "    set --"
say "    for f in Morrowind.bsa Tribunal.bsa Bloodmoon.bsa; do"
say "        [ -f \"\$DATA/\$f\" ] && set -- \"\$@\" --bsa \"\$DATA/\$f\""
say "    done"
say "    \"\$TOOL\" \"\$@\" --out <outdir> --threads 4 --report-every 25 \\\\"
say "        --min-size <min> --max-size <max> --block <block>"
printf '\n'
say "Two bands, the same split the manager uses:"
say "    band 1   min-size 128  max-size 0    block 8x8   (large)"
say "    band 2   min-size 0    max-size 127  block 6x6   (small)"

if [ "$MODE" = "plan" ]; then
    printf '\n'
    hr "PLAN ONLY - NOTHING WAS WRITTEN"
    say "This is hours of work on the handheld, so go runs it detached and"
    say "resumable; the converter skips any .ktx that already exists."
    printf '\n      TSP_TEXOUT=<dir> sh %s go\n' "$0"
    printf '\n'
    say "Pick the output dir from section 2 - normally /mnt/UDISK/openmw-tex,"
    say "because the card wastes a 128 KB cluster on every 14 KB texture."
    printf '\n'
    exit 0
fi

# ====================================================================== go ===
OUT="${TSP_TEXOUT:-}"
[ -n "$OUT" ] || die "set the output directory explicitly, from section 2 above:
      TSP_TEXOUT=$UDISK sh $0 go
  I will not guess this: the card and the eMMC differ by ~9x in slack and
  writing to the wrong one can fill it."

hr "STARTING - DETACHED, RESUMABLE"
rin <<GOEOF
if [ -f '$RPID' ]; then
    P="\$(cat '$RPID' 2>/dev/null)"
    if [ -n "\$P" ] && kill -0 "\$P" 2>/dev/null; then
        echo "  ALREADY RUNNING as pid \$P - not starting a second one."
        echo "  Watch it:  sh ~/Downloads/tsp_texbsa.sh status"
        exit 1
    fi
    rm -f '$RPID'
fi
[ -x '$TOOL' ] || { echo "  tool missing: $TOOL"; exit 1; }
mkdir -p '$OUT' || { echo "  cannot create $OUT"; exit 1; }

cat > /mnt/SDCARD/tsp_texbsa_run.sh <<'RUNNER'
#!/bin/sh
# Written by tsp_texbsa.sh. Runs both size bands with correct positional argv.
TOOL="__TOOL__"; DATA="__DATA__"; OUT="__OUT__"; LOG="__LOG__"
{
  echo "TSP_TEXBSA start \$(date) out=\$OUT"
  for band in "128 0 8x8" "0 127 6x6"; do
      set -- \$band
      tmin="\$1"; tmax="\$2"; blk="\$3"
      echo "TSP_TEXBSA band min=\$tmin max=\$tmax block=\$blk"
      set --
      for f in Morrowind.bsa Tribunal.bsa Bloodmoon.bsa; do
          [ -f "\$DATA/\$f" ] && set -- "\$@" --bsa "\$DATA/\$f"
      done
      [ \$# -gt 0 ] || { echo "TSP_TEXBSA no archives found - nothing to do"; break; }
      "\$TOOL" "\$@" --out "\$OUT" --threads 4 --report-every 25 \\
          --min-size "\$tmin" --max-size "\$tmax" --block "\$blk"
      echo "TSP_TEXBSA band rc=\$?"
  done
  echo "TSP_TEXBSA finished \$(date)"
} >> "\$LOG" 2>&1
RUNNER
sed -i -e 's#__TOOL__#$TOOL#' -e 's#__DATA__#$DATA#' -e 's#__OUT__#$OUT#' \\
       -e 's#__LOG__#$RLOG#' /mnt/SDCARD/tsp_texbsa_run.sh
chmod +x /mnt/SDCARD/tsp_texbsa_run.sh
echo "  runner written. The argv it will build:"
sed -n '/set --\$/,/done/p' /mnt/SDCARD/tsp_texbsa_run.sh | sed 's/^/    /'

: > '$RLOG'
setsid sh /mnt/SDCARD/tsp_texbsa_run.sh >/dev/null 2>&1 &
echo \$! > '$RPID'
sleep 3
P="\$(cat '$RPID')"
if kill -0 "\$P" 2>/dev/null; then
    echo "  RUNNING as pid \$P"
elif grep -q 'TSP_TEXBSA finished' '$RLOG' 2>/dev/null; then
    # A gone pid is not the same as a dead one - a fully resumed run finishes
    # in seconds because the converter skips every .ktx that already exists.
    echo "  ALREADY FINISHED - every texture in both bands was already done."
    sed 's/^/    /' '$RLOG'
else
    echo "  IT DIED WITHIN 3 SECONDS. The log says:"
    sed 's/^/    /' '$RLOG'
    exit 1
fi
echo "  --- the first lines of the log ---"
sed 's/^/    /' '$RLOG'
GOEOF

printf '\n'
say "It is detached, so closing this shell will not stop it. Check on it with"
say "this, as often as you like - it also prints the live .ktx count:"
printf '\n      sh %s status\n\n' "$0"
say "Stop it with:  sh $0 stop   (a later go resumes, nothing is redone)"
printf '\n'
