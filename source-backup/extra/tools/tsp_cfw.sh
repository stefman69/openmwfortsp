#!/bin/sh
# tsp_cfw.sh - make the port work on BOTH cards, and show the scope of both.
#
#   scope   read-only inventory of whichever card is booted. Run on each, upload both.
#   plan    show the launcher fix and prove it parses. No writes.
#   go      apply it, gated on the DEVICE own /bin/sh -n
#   undo    restore the launcher from its backup
#   mark <label>  snapshot the comparable performance state under a label
#   compare       put every saved mark side by side
#
# Everything it prints is also saved to a txt in ~/Downloads.
#
# WHY
#
# The stock-OS card never started the game. Its openmw_log.txt says:
#
#     Bash version: unknown
#     ...Morrowind.sh: line 422: syntax error: unexpected "("
#
# "Bash version: unknown" means $BASH_VERSION was empty, so the launcher - whose
# shebang is #!/bin/bash - is being run by a shell that is NOT bash. Line 422 is
#
#     required_paths=(
#
# a bash array. busybox ash has no arrays, so "(" after "=" is a syntax error
# and the launcher dies there, before the game is ever invoked.
#
# busybox ash -n reproduces the device message VERBATIM - same line, same
# wording - so it is a faithful stand-in and the fix was iterated locally
# against it rather than on the device.
#
# A census of the whole 2157-line launcher found only TWO bash-only constructs,
# both halves of that one array (three further regex hits were false positives:
# the $' in grep -c '^content=builtin\.omwscripts$'). So the launcher is
# otherwise POSIX already, and two lines make one launcher serve both CFWs -
# which is the same "one thing for both consoles" constraint as the binary.
#
# THE SAME LAUNCHER IS ON BOTH CARDS. Every line number the working card
# reported - 631, 1064, 2013, 2032, 2087, 2092 - matches the uploaded file
# exactly. So this is not two divergent launchers; it is one launcher and two
# shells.
#
# THE FIX, at 422:
#
#   - the array becomes a heredoc-fed `while IFS= read -r` loop
#   - fed by a HEREDOC, not a pipe: a pipe puts the loop in a subshell and the
#     `exit 1` for a missing runtime file would be swallowed, leaving the
#     launcher running with a missing library
#   - `IFS= read -r` keeps paths containing spaces intact
#
# Verified under dash, busybox ash and bash: all three parse clean, and the
# loop behaves identically in all three - including a path with a space, and
# including the exit 1 actually stopping the script rather than a subshell.

set -u
# Device address, in order: an explicit DEV= in the environment, then $TSP_DEV
# as `tsp_net.sh each` sets it, then ~/.tsp_dev as `tsp_net.sh use` writes it,
# then the old hardcoded default. Two cards do not share an address, and a tool
# pointed at the wrong one reports that card state as if it were this one.
# Every line here returns 0, so a missing ~/.tsp_dev cannot trip set -e.
DEV="${DEV:-${TSP_DEV:-}}"
if [ -z "${DEV}" ] && [ -r "$HOME/.tsp_dev" ]; then DEV="$(cat "$HOME/.tsp_dev")"; fi
[ -n "${DEV}" ] || DEV="root@192.168.1.12"
CARD="/mnt/SDCARD"
G="$CARD/data/ports/openmw"
LAUNCHER="$CARD/Roms/PORTS/Morrowind.sh"
SSHO="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes -o LogLevel=ERROR"
STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="/tmp/tsp_cfw_$STAMP"
MARK="TSP_POSIX_V1"
IN_MD5="506d1893fafa8a23d19c904b509934d5"
OUT_MD5="6cded8f8ea8211ad604102c87d5040f4"

MODE="${1:-scope}"
case "$MODE" in scope | plan | go | undo | mark | compare) ;;
*) printf 'usage: %s scope | plan | go | undo | mark <label> | compare\n' "$0"; exit 2 ;; esac
LABEL="${2:-}"
MARKDIR="$HOME/Downloads/tsp-marks"

# $TSP_NAME is set by `tsp_net.sh each`. It goes in the filename because
# $STAMP has one-second resolution: two cards finishing inside the same second
# wrote the same file and the second overwrote the first.
DEVTAG=""
[ -n "${TSP_NAME:-}" ] && DEVTAG="-$(printf '%s' "$TSP_NAME" | tr -c 'A-Za-z0-9._-' '_')"
LOG="$HOME/Downloads/tsp-cfw-${MODE}${DEVTAG}-$STAMP.txt"
if [ "${TSP_CFW_TEE:-0}" != "1" ]; then
    TSP_CFW_TEE=1; export TSP_CFW_TEE
    # "$@", not "$MODE" - the re-exec dropped every argument after the first,
    # so `mark <label>` arrived with no label and aborted on its own usage text.
    sh "$0" "$@" 2>&1 | tee "$LOG"
    printf '\n  Saved to: %s\n  Upload that file rather than pasting it.\n\n' "$LOG"
    exit 0
fi

say() { printf '  %s\n' "$*"; }
hr()  { printf '\n########## %s ##########\n' "$1"; }
r()   { ssh $SSHO -n "$DEV" "$1" 2>&1; }
rq()  { ssh $SSHO -n "$DEV" "$1" 2>/dev/null; }
# The probe no longer travels on the remote stdin. It goes as base64 inside the
# ssh command (alphabet A-Za-z0-9+/=, so no quote or metacharacter survives to
# be interpreted), is decoded to a file on the device, and runs with
# </dev/null. Nothing it invokes can reach back into the script, so -n is
# correct again. See the comment above SSHO for what this cost us.
rin() {
    _b64="$(base64 | tr -d '\n')"
    ssh -n $SSHO "$DEV" "T=/tmp/tsp_rin.\$\$
printf '%s' '$_b64' | base64 -d > \"\$T\" 2>/dev/null || { echo '  (no base64 on this device - cannot run this probe)'; exit 1; }
sh \"\$T\" </dev/null
_r=\$?
rm -f \"\$T\"
exit \$_r" 2>&1
}
abort() { printf '\n  STOPPING: %s\n  Nothing was changed.\n\n' "$*"; exit 1; }

_pf="$(ssh $SSHO -n "$DEV" "echo ok" 2>&1)"
case "$_pf" in
    *ok*) ;;
    *"Permission denied"*|*"publickey"*|*"Too many authentication"*)
        abort "ssh AUTH failed for $DEV.
  Every tool here uses BatchMode, which refuses passwords on purpose - so a
  card you only ever typed a password into looks dead from in here. Install
  the key once:
      sh ~/Downloads/tsp_net.sh key $DEV" ;;
    *)  abort "cannot reach $DEV - is the handheld awake, on wifi, and booted
  from the card you want to inspect? ssh said: $_pf" ;;
esac

# ================================================================ mark ======
# ONE statistic, the same on both cards: the SDL_GL_SwapWindow mean from the
# TSP_GLT MEAN lines. It is per-frame and in milliseconds, so it compares across
# different silicon and different CFWs without normalising anything - unlike
# fps, which depends on where you stood.
#
# Everything else here exists to make a mark interpretable later: which card it
# came from, whether the GPU clock actually held during the run, and how hot it
# got. trans_stat and the fault counters are CUMULATIVE SINCE BOOT, so a mark
# stores them raw and `compare` differences consecutive marks from the same
# boot. Comparing two cumulative totals as if they were rates is the error that
# produced a bogus number earlier in this project.
if [ "$MODE" = "mark" ]; then
    [ -n "$LABEL" ] || abort "give the mark a label, e.g.:
      bash ~/Downloads/tsp_cfw.sh mark crossmix-baseline
      bash ~/Downloads/tsp_cfw.sh mark crossmix-clockpinned
      bash ~/Downloads/tsp_cfw.sh mark stock-baseline
      bash ~/Downloads/tsp_cfw.sh mark stock-clockpinned"
    case "$LABEL" in *[!A-Za-z0-9._-]*) abort "label: letters, digits, dot, dash, underscore only" ;; esac
    mkdir -p "$MARKDIR"
    OUT="$MARKDIR/$LABEL.txt"
    hr "MARK: $LABEL"
    say "Take this AFTER a play session, not before - it reads what the run left"
    say "behind. Nothing is written on the card."
    {
        printf 'LABEL\t%s\n' "$LABEL"
        printf 'TAKEN\t%s\n' "$STAMP"
        rin "sh -s" <<'REMOTE'
D=/mnt/SDCARD/Apps/PortMaster/PortMaster/device_info.txt
printf 'CFW\t%s\n' "$( [ -f "$D" ] && sed -n 's/^CFW_NAME=//p' "$D" | head -1 || echo unknown)"
printf 'CFWVER\t%s\n' "$( [ -f "$D" ] && sed -n 's/^CFW_VERSION=//p' "$D" | head -1 || echo unknown)"
printf 'KERNEL\t%s\n' "$(uname -r)"
printf 'SH\t%s\n' "$(readlink /bin/sh 2>/dev/null || echo '?')"
L=/mnt/SDCARD/Roms/PORTS/Morrowind.sh
[ -f "$L" ] && printf 'LAUNCHER\t%s\nPOSIXFIX\t%s\n' \
    "$(md5sum "$L" | cut -c1-8)" "$(grep -c TSP_POSIX_V1 "$L" 2>/dev/null)"
printf 'UPTIMES\t%s\n' "$(cut -d. -f1 /proc/uptime)"

# the GPU, found by identity - never by whichever node is fastest
M=""
for p in /sys/class/misc/mali0/device /sys/devices/platform/*gpu*; do
    [ -e "$p/power_policy" ] && { M="$p"; break; }
done
GN=""
if [ -n "$M" ] && [ -d "$M/devfreq" ]; then
    for d in "$M"/devfreq/*; do [ -e "$d/max_freq" ] && { GN="$d"; break; }; done
fi
if [ -z "$GN" ] && [ -n "$M" ]; then
    MR=$(cd "$M" 2>/dev/null && pwd -P)
    for d in /sys/class/devfreq/*; do
        DR=$(cd "$d/device" 2>/dev/null && pwd -P)
        [ -n "$DR" ] && [ "$DR" = "$MR" ] && { GN="$d"; break; }
    done
fi
if [ -z "$GN" ]; then
    for d in /sys/class/devfreq/*; do
        case "${d##*/}" in *dmc*|*ddr*|*mbus*|*cpu*) continue;; *gpu*|*mali*) GN="$d"; break;; esac
    done
fi
if [ -n "$GN" ]; then
    printf 'GPUNODE\t%s\n' "${GN##*/}"
    printf 'GPUGOV\t%s\n'  "$(cat "$GN/governor" 2>/dev/null)"
    printf 'GPUCUR\t%s\n'  "$(cat "$GN/cur_freq" 2>/dev/null)"
    printf 'GPUMIN\t%s\n'  "$(cat "$GN/min_freq" 2>/dev/null)"
    printf 'GPUMAX\t%s\n'  "$(cat "$GN/max_freq" 2>/dev/null)"
    printf 'GPUOPPS\t%s\n' "$(cat "$GN/available_frequencies" 2>/dev/null)"
    # cumulative ms at the top OPP and at the bottom one
    # "* 150000000:" has a SPACE after the star and a colon on the number.
    # The old pattern required a digit immediately after the star, so it skipped
    # the starred row - which on this hardware is the 150 MHz row, i.e. the
    # whole point of reading trans_stat at all.
    printf 'GPUTIS\t%s\n' "$(awk '
        /^[ \t]*\*?[ \t]*[0-9]+:/ {
            f=$1; if (f=="*") f=$2
            sub(/:$/,"",f); gsub(/\*/,"",f)
            print f "=" $NF
        }' "$GN/trans_stat" 2>/dev/null | tr '\n' ' ')"
else
    printf 'GPUNODE\tNOT-IDENTIFIED\n'
fi
[ -n "$M" ] && printf 'MALI\t%s\nPOLICY\t%s\n' \
    "$(cat "$M/gpuinfo" 2>/dev/null)" "$(cat "$M/power_policy" 2>/dev/null)"

for t in /sys/class/thermal/thermal_zone*; do
    [ -r "$t/temp" ] || continue
    printf 'TEMP\t%s=%s\n' "$(cat "$t/type" 2>/dev/null)" "$(cat "$t/temp" 2>/dev/null)"
done

# the statistic. Real field is SDL_GL_SwapWindow=9.91ms/1 - prefix, ms suffix,
# /count tail. A pattern anchored on "SwapWindow=" matches none of it.
F=/mnt/SDCARD/tsp_gltime.txt
if [ -s "$F" ]; then
    awk '
      function val(t) { sub(/^[A-Za-z_0-9]*=/,"",t); p=index(t,"/")
                        if (p>0) t=substr(t,1,p-1); sub(/ms$/,"",t); return t+0 }
      /TSP_GLT MEAN/ { for (i=1;i<=NF;i++) {
                         if ($i=="over") fr=$(i+1)+0
                         if ($i ~ /SwapWindow=/) { n++; v=val($i); s+=v
                           if (n==1) { f=v; ff=fr }
                           l=v; lf=fr; if (v>mx) mx=v; if (mn==0||v<mn) mn=v } }
                       next }
      /TSP_GLT SLOW/ { slow++
                       for (i=1;i<=NF;i++) { if ($i ~ /^total=/) { t=val($i); ts+=t; if (t>tm) tm=t } }
                       next }
      END { printf "SWAPN\t%d\n", n
            if (n>0) { printf "SWAPFIRST\t%.2f\nSWAPLAST\t%.2f\nSWAPMEAN\t%.2f\n", f, l, s/n
                       printf "SWAPMIN\t%.2f\nSWAPMAX\t%.2f\n", mn, mx
                       printf "FRAMES\t%d..%d\n", ff, lf }
            printf "SLOWN\t%d\n", slow
            if (slow>0) printf "SLOWMEAN\t%.1f\nSLOWMAX\t%.1f\n", ts/slow, tm }
    ' "$F"
    printf 'GLTBYTES\t%s\n' "$(wc -c < "$F")"
else
    printf 'SWAPN\t0\nNOTE\tno tsp_gltime.txt - the gl timing shim was not in the preload chain\n'
fi
REMOTE
    } > "$OUT" 2>&1
    sed 's/^/    /' "$OUT"
    printf '\n'
    say "saved to $OUT"
    say "Take the matching mark on the other card, then run: compare"
    printf '\n      bash ~/Downloads/tsp_cfw.sh compare\n\n'
    exit 0
fi

# ============================================================== compare =====
if [ "$MODE" = "compare" ]; then
    hr "EVERY MARK SIDE BY SIDE"
    [ -d "$MARKDIR" ] || abort "no marks yet. Take one after a play session:
      bash ~/Downloads/tsp_cfw.sh mark <label>"
    set -- "$MARKDIR"/*.txt
    [ -e "$1" ] || abort "no marks in $MARKDIR"
    awk -F'\t' '
      FNR==1 { n++; file[n]=FILENAME }
      { k=$1; v=$2; if (k=="TEMP") { t[n]=t[n] v " "; next } d[n,k]=v
        if (!(k in seen) && k!="TEMP") { seen[k]=1; order[++ko]=k } }
      END {
        printf "  %-14s", "field"
        for (i=1;i<=n;i++) printf " %-18s", d[i,"LABEL"]
        printf "\n  %-14s", "--------------"
        for (i=1;i<=n;i++) printf " %-18s", "------------------"
        printf "\n"
        split("CFW CFWVER SH POSIXFIX LAUNCHER GPUNODE GPUGOV GPUCUR GPUMAX POLICY SWAPN SWAPFIRST SWAPLAST SWAPMEAN SWAPMIN SWAPMAX FRAMES SLOWN SLOWMEAN SLOWMAX", want, " ")
        for (w=1; w<=20; w++) {
          k=want[w]; any=0
          for (i=1;i<=n;i++) if ((i,k) in d) any=1
          if (!any) continue
          printf "  %-14s", k
          for (i=1;i<=n;i++) printf " %-18s", ((i,k) in d ? substr(d[i,k],1,18) : "-")
          printf "\n"
        }
        printf "\n  THE COMPARABLE NUMBER IS SWAPMEAN - ms of swap per frame.\n"
        printf "  It is per-frame and in ms, so it holds across different silicon.\n"
        printf "  SWAPFIRST vs SWAPLAST shows drift within a single run.\n"
        printf "\n  GPU time-in-state, raw and cumulative since boot:\n"
        for (i=1;i<=n;i++) if ((i,"GPUTIS") in d)
          printf "    %-18s %s\n", d[i,"LABEL"], d[i,"GPUTIS"]
        printf "  Those are totals, not rates. Only differences between two marks\n"
        printf "  from the SAME boot mean anything.\n"
        printf "\n  temperatures at mark time:\n"
        for (i=1;i<=n;i++) printf "    %-18s %s\n", d[i,"LABEL"], t[i]
      }' "$@"
    printf '\n'
    exit 0
fi

# ======================================================================= scope
if [ "$MODE" = "scope" ]; then
    hr "0. WHICH CARD IS THIS"
    say "Run this once per card, booted from that card, and upload both files."
    say "Everything below is read-only."
    rin "sh -s" <<'REMOTE'
echo "  -- CFW identity --"
for f in /etc/os-release /usr/trimui/version /mnt/SDCARD/System/version.txt \
         /mnt/SDCARD/.tmp_update/version /etc/crossmix-version; do
    [ -f "$f" ] && { echo "    $f:"; head -6 "$f" | sed 's/^/      /'; }
done
for m in /mnt/SDCARD/System/usr/trimui /mnt/SDCARD/trimui /mnt/SDCARD/.tmp_update \
         /mnt/SDCARD/Apps/PortMaster /mnt/SDCARD/Emus/PORTS /mnt/SDCARD/Roms/PORTS; do
    [ -e "$m" ] && echo "    present: $m" || echo "    ABSENT : $m"
done
# device_info.txt is a SCRIPT that GENERATES a values file. Reading the script
# reports the defaults written inside it, which is how both cards came back as
# CFW_NAME="Unknown". Read the generated file instead, and never run the script
# - it writes into $HOME.
echo "  -- PortMaster device info (the generated values, not the script) --"
FOUND=0
SEEN=""
for g in "$HOME"/device_info_*.txt /root/device_info_*.txt; do
    [ -f "$g" ] || continue
    # HOME is /root on these cards, so both globs hit the same file and it
    # printed twice. Dedup on the resolved path.
    r="$(readlink -f "$g" 2>/dev/null)"; [ -n "$r" ] || r="$g"
    case " $SEEN " in *" $r "*) continue ;; esac
    SEEN="$SEEN $r"
    FOUND=1
    echo "    from $g"
    grep -E "^ *(CFW_|DEVICE_|PM_VERSION|DISPLAY_)" "$g" 2>/dev/null | sed 's/^ */      /'
done
if [ "$FOUND" = "0" ]; then
    echo "    not generated yet on this card (PortMaster writes it on first run)"
    echo "    falling back to what the OS itself says:"
    for f in /etc/version /usr/trimui/version /etc/crossmix-version; do
        [ -f "$f" ] && echo "      $f: $(head -1 "$f")"
    done
    [ -d /mnt/SDCARD/System/usr/trimui ] && echo "      stock TrimUI layout present"
fi
REMOTE

    hr "1. THE SHELL - THIS IS WHAT BROKE THE STOCK CARD"
    rin "sh -s" <<'REMOTE'
echo "  /bin/sh is:      $(ls -l /bin/sh 2>/dev/null)"
echo "  sh identifies as: $(sh -c 'echo ${BASH_VERSION:-not-bash}' 2>/dev/null)"
for b in /bin/bash /usr/bin/bash /mnt/SDCARD/System/bin/bash \
         /mnt/SDCARD/Apps/PortMaster/PortMaster/bash; do
    if [ ! -x "$b" ]; then echo "  bash absent:     $b"; continue; fi
    tgt="$(readlink -f "$b" 2>/dev/null)"; [ -n "$tgt" ] || tgt="$b"
    # </dev/null is not optional here: a binary that does not understand
    # --version falls back to reading commands from stdin.
    ver="$("$b" --version </dev/null 2>/dev/null | head -1)"
    case "$tgt" in
        *busybox*) echo "  bash at $b: NOT BASH - resolves to busybox ($tgt)" ;;
        *)         echo "  bash at $b: $tgt  $(wc -c < "$b" 2>/dev/null) bytes" ;;
    esac
    if [ -n "$ver" ]; then echo "      --version: $ver"
    else echo "      --version: NO ANSWER - this is not GNU bash, whatever the name says"; fi
done
echo "  command -v bash: $(command -v bash 2>/dev/null || echo '<none on PATH>')"
echo "  busybox:         $(busybox 2>&1 | head -1)"
echo
echo "  -- does the launcher PARSE under this card own /bin/sh --"
L=/mnt/SDCARD/Roms/PORTS/Morrowind.sh
if [ -f "$L" ]; then
    echo "    md5:   $(md5sum "$L" | cut -d' ' -f1)"
    echo "    lines: $(wc -l < "$L")"
    echo "    revision: $(grep -m1 'Launcher revision' "$L" | sed 's/.*revision: //; s/"$//')"
    if sh -n "$L" 2>/tmp/tsp_shn.txt; then
        echo "    sh -n: PARSES CLEAN - this card can run it"
    else
        echo "    sh -n: FAILS ->"; sed 's/^/      /' /tmp/tsp_shn.txt
        echo "    That is the whole reason the game does not start here."
    fi
    rm -f /tmp/tsp_shn.txt
    echo "    TSP_POSIX_V1 marker: $(grep -c TSP_POSIX_V1 "$L" 2>/dev/null)"
else
    echo "    NO LAUNCHER at $L"
fi
REMOTE

    hr "2. GPU AND CLOCKS"
    rin "sh -s" <<'REMOTE'
echo "  -- GPU driver family (this is the thing that decides what tuning even applies) --"
GPUFAM="unknown"
for k in /sys/class/misc/mali0 /sys/module/mali_kbase /sys/module/mali; do
    [ -e "$k" ] && { echo "    Mali kbase: $k present"; GPUFAM="mali"; }
done
for k in /sys/module/pvrsrvkm /sys/kernel/debug/pvr /dev/pvr_sync /proc/pvr; do
    [ -e "$k" ] && { echo "    PowerVR:    $k present"; GPUFAM="powervr"; }
done
for u in /sys/class/drm/card0/device/uevent /sys/class/drm/card1/device/uevent; do
    [ -f "$u" ] && grep -h DRIVER "$u" 2>/dev/null | sed "s#^#    drm $u: #"
done
echo "    -> GPU family: $GPUFAM"
NDF=0
for d in /sys/class/devfreq/*; do
    [ -e "$d/max_freq" ] || continue
    NDF=$((NDF + 1))
done
if [ "$NDF" = "0" ]; then
    echo "  -- NO devfreq nodes on this card at all --"
    echo "     Nothing to pin. Any devfreq/governor tuning is a no-op here,"
    echo "     which is a result, not a missing section."
fi
for d in /sys/class/devfreq/*; do
    [ -e "$d/max_freq" ] || continue
    case "${d##*/}" in *dmc*|*ddr*|*mbus*) tag="(memory, not the GPU)";; *) tag="";; esac
    echo "  ${d##*/} $tag"
    echo "    gov=$(cat $d/governor 2>/dev/null) cur=$(cat $d/cur_freq 2>/dev/null) max=$(cat $d/max_freq 2>/dev/null)"
    echo "    opps=$(cat $d/available_frequencies 2>/dev/null)"
done
for p in /sys/class/misc/mali0/device /sys/devices/platform/*gpu*; do
    [ -e "$p/gpuinfo" ] || continue
    echo "  mali: $(cat $p/gpuinfo 2>/dev/null)"
    echo "    power_policy: $(cat $p/power_policy 2>/dev/null)"
    echo "    core_mask:    $(cat $p/core_mask 2>/dev/null | head -1)"
done
echo "  kernel: $(uname -r)  $(uname -m)"
echo "  -- what the SILICON says. PortMaster DEVICE_CPU is hardcoded from the"
echo "     CFW name, so it is a label, not a measurement. These are measured. --"
for f in /proc/device-tree/model /sys/firmware/devicetree/base/model; do
    [ -r "$f" ] && { echo "    dt model:      $(tr -d '\000' < "$f")"; break; }
done
for f in /proc/device-tree/compatible /sys/firmware/devicetree/base/compatible; do
    [ -r "$f" ] && { echo "    dt compatible: $(tr '\000' ' ' < "$f")"; break; }
done
[ -r /sys/devices/soc0/machine ] && echo "    soc0 machine:  $(cat /sys/devices/soc0/machine)"
[ -r /sys/devices/soc0/soc_id ]  && echo "    soc0 soc_id:   $(cat /sys/devices/soc0/soc_id)"
[ -r /sys/devices/soc0/family ]  && echo "    soc0 family:   $(cat /sys/devices/soc0/family)"
# CPU part is the decisive one: 0xd03 is Cortex-A53, 0xd05 is A55. Two cards
# with different part numbers are not the same chip, whatever the label says.
echo "    cpu part/impl: $(grep -m1 -i 'CPU part' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | tr -d ' ')/$(grep -m1 -i 'CPU implementer' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | tr -d ' ')"
echo "    cpuinfo model: $(grep -m1 -i -e 'model name' -e '^Hardware' /proc/cpuinfo 2>/dev/null | cut -d: -f2-)"
echo "  cores:  $(grep -c ^processor /proc/cpuinfo) online, present=$(cat /sys/devices/system/cpu/present 2>/dev/null) online=$(cat /sys/devices/system/cpu/online 2>/dev/null)"
# cpuinfo_max_freq is the SILICON ceiling. scaling_max_freq is what the
# governor is actually allowed to use, and it is the one that decides whether a
# card is clock-limited right now. Printing only the first was a hole: the
# A523 card showed 1416000 and there was no way to tell whether that was the
# chip or a cap someone set.
C=/sys/devices/system/cpu/cpu0/cpufreq
echo "    cpu0 hw max:   $(cat $C/cpuinfo_max_freq 2>/dev/null) kHz   hw min: $(cat $C/cpuinfo_min_freq 2>/dev/null) kHz"
echo "    cpu0 allowed:  $(cat $C/scaling_max_freq 2>/dev/null) kHz   cur: $(cat $C/scaling_cur_freq 2>/dev/null) kHz  gov=$(cat $C/scaling_governor 2>/dev/null)"
echo "    cpu0 govs:     $(cat $C/scaling_available_governors 2>/dev/null)"
echo "    cpu0 opps:     $(cat $C/scaling_available_frequencies 2>/dev/null)"
echo "    thermal:       $(for t in /sys/class/thermal/thermal_zone*; do [ -r "$t/temp" ] && printf '%s=%s ' "${t##*/}" "$(cat "$t/temp" 2>/dev/null)"; done)"
NOFF=0
for c in /sys/devices/system/cpu/cpu[0-9]*; do
    [ -f "$c/online" ] || continue
    [ "$(cat "$c/online" 2>/dev/null)" = "0" ] || continue
    NOFF=$((NOFF + 1))
    # Not [ -w ]: we run as root, and for root that is true whatever the mode
    # says, so it would report every core as writable. The mode bits are the
    # honest signal - a core the kernel will not hotplug exposes 0444, or no
    # online file at all.
    echo "    ${c##*/}: OFFLINE, online mode $(ls -l "$c/online" 2>/dev/null | cut -c1-10)"
done
[ "$NOFF" = "0" ] && echo "    every present core is online"
echo "  MemTotal: $(awk '/MemTotal/ {print $2" kB"}' /proc/meminfo)"
echo "  drm:    $(cat /sys/class/drm/card0/device/uevent 2>/dev/null | grep DRIVER)"
REMOTE

    hr "3. THE GRAPHICS STACK THE PORT DEPENDS ON"
    rin "sh -s" <<'REMOTE'
echo "  -- system EGL/GLES/mali --"
ls -la /usr/lib/libEGL.so* /usr/lib/libGLESv2.so* /usr/lib/libmali.so* 2>/dev/null | sed 's/^/    /'
echo "  -- the SDL2 that actually gets loaded --"
for s in /mnt/SDCARD/data/ports/openmw/lib/libSDL2-2.0.so.0 \
         /usr/trimui/lib/libSDL2-2.0.so.0 /mnt/SDCARD/System/lib/libSDL2-2.0.so.0 \
         /usr/lib/libSDL2-2.0.so.0; do
    if [ -f "$s" ]; then
        echo "    $s  $(wc -c < "$s") bytes"
        # sensor support is the stock-vs-CrossMix difference the launcher already
        # works around with libtsp_sdl_sensor_shim.so
        if grep -a -q SDL_SensorUpdate "$s" 2>/dev/null; then
            echo "      sensor API: present"
        else
            echo "      sensor API: MISSING (the shim covers this)"
        fi
    fi
done
echo "  -- the port own libs --"
ls -la /mnt/SDCARD/data/ports/openmw/lib 2>/dev/null \
  | grep -i -e libgl -e libegl -e sdl -e libtsp -e mygui | sed 's/^/    /'
echo "  -- glibc --"
(ldd --version 2>/dev/null || /lib/ld-linux-aarch64.so.1 --version 2>/dev/null) | head -2 | sed 's/^/    /'
REMOTE

    hr "4. IS THE GAME ITSELF THERE"
    rin "sh -s" <<'REMOTE'
G=/mnt/SDCARD/data/ports/openmw
for f in "$G/bin/openmw-0.51" "$G/data/Data Files/Morrowind.esm" \
         "$G/data/Data Files/Morrowind.bsa" "$G/openmw_log.txt" \
         "$G/mods/TSPPerformance/scripts/TSPPerformance/dynamic_view.lua"; do
    if [ -e "$f" ]; then echo "    ok      $f  ($(wc -c < "$f" 2>/dev/null) bytes)"
    else echo "    MISSING $f"; fi
done
echo "    dynview markers: glide=$(grep -c TSP_DYNVIEW_GLIDE_V1 "$G/mods/TSPPerformance/scripts/TSPPerformance/dynamic_view.lua" 2>/dev/null) tune1=$(grep -c TSP_DYNVIEW_TUNE_V1 "$G/mods/TSPPerformance/scripts/TSPPerformance/dynamic_view.lua" 2>/dev/null) tune2=$(grep -c TSP_DYNVIEW_TUNE_V2 "$G/mods/TSPPerformance/scripts/TSPPerformance/dynamic_view.lua" 2>/dev/null)"
echo "    last 3 launcher log lines:"
tail -3 "$G/openmw_log.txt" 2>/dev/null | sed 's/^/      /'
REMOTE

    hr "5. WHAT TO DO WITH THIS"
    cat <<'NOTE'
  Run scope on the OTHER card too and upload both files. With the pair I can
  say exactly what differs and what the port has to tolerate.

  If section 1 says sh -n FAILS on this card, the launcher fix is:

      bash ~/Downloads/tsp_cfw.sh plan
NOTE
    exit 0
fi

# ============================================================ plan / go / undo
hr "THE LAUNCHER ON THIS CARD"
r "test -f '$LAUNCHER'" || abort "no launcher at $LAUNCHER"
CUR_MD5="$(rq "md5sum '$LAUNCHER' | cut -d' ' -f1")"
say "md5:   $CUR_MD5"
say "lines: $(rq "wc -l < '$LAUNCHER'")"
HAVE="$(rq "grep -c '$MARK' '$LAUNCHER' 2>/dev/null")"
case "$HAVE" in ''|*[!0-9]*) HAVE=0 ;; esac
say "$MARK present: $HAVE"

if [ "$MODE" = "undo" ]; then
    hr "RESTORING THE LAUNCHER"
    rin <<UEOF
L='$LAUNCHER'
B=""
for c in \$(ls -1tr "\$L".before-posix-* 2>/dev/null); do
    grep -q '$MARK' "\$c" 2>/dev/null && continue
    B="\$c"; break
done
if [ -n "\$B" ]; then
    cp -p "\$B" "\$L" && chmod +x "\$L" && printf '    %s <- %s\n' "\$L" "\$B"
    printf '    md5 now: %s\n' "\$(md5sum "\$L" | cut -d" " -f1)"
else
    printf '    no clean backup found, left alone\n'
fi
UEOF
    printf '\n  Note: the original does NOT parse under busybox ash, so restoring it\n'
    printf '  puts the stock-OS card back to not starting the game.\n\n'
    exit 0
fi

if [ "$HAVE" -gt 0 ]; then
    say "already patched - nothing to do"
    exit 0
fi

hr "THE FIX"
cat <<'FIX'
  At line 422 a bash array becomes a heredoc-fed while loop. Two spots, one
  construct. Nothing else in the file changes.

  -required_paths=(
  -    "$OPENMW_BIN"
  -    ... nine entries ...
  -)
  -for required in "${required_paths[@]}"; do
  +while IFS= read -r required; do
  +    [ -n "$required" ] || continue
       if [ ! -e "$required" ]; then ... exit 1; fi
  -done
  +done <<TSP_REQEOF
  +$OPENMW_BIN
  +... the same nine entries, one per line ...
  +TSP_REQEOF

  A HEREDOC, not a pipe: a pipe would put the loop in a subshell and the exit 1
  for a missing runtime file would be swallowed, leaving the launcher running
  with a missing library. IFS= read -r keeps paths containing spaces intact.

  Verified under dash, busybox ash and bash - all three parse clean, and the
  loop behaves identically in all three, including a path with a space and
  including the exit 1 actually stopping the script.
FIX

if [ "$CUR_MD5" = "$IN_MD5" ]; then
    say "The launcher on this card is byte-identical to the one I patched and"
    say "tested ($IN_MD5), so the result will be $OUT_MD5."
else
    say "This card launcher md5 is $CUR_MD5, not the $IN_MD5 I patched."
    say "The edit is anchored on the exact text of the array, so it will either"
    say "match and apply or refuse - it cannot half-apply."
fi

if [ "$MODE" = "plan" ]; then
    printf '\n'
    say "PLAN ONLY. Nothing written."
    printf '\n      bash ~/Downloads/tsp_cfw.sh go\n\n'
    exit 0
fi

hr "APPLYING"
mkdir -p "$WORK"
scp $SSHO "$DEV:$LAUNCHER" "$WORK/mw.sh" >/dev/null 2>&1 || abort "could not fetch the launcher"
say "fetched $(wc -c < "$WORK/mw.sh") bytes"

python3 - "$WORK/mw.sh" "$WORK/mw.new" <<'PYEOF' || abort "the patcher refused - the launcher is untouched"
import sys, hashlib
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding='utf-8', errors='surrogateescape').read()
OLD = '''required_paths=(
    "$OPENMW_BIN"
    "$CONTROL_HELPER"
    "$OPENMW_RESOURCES"
    "$OPENMW_RESOURCES/defaults.bin"
    "$OPENMW_RESOURCES/vfs"
    "$OPENMW_RESOURCES/vfs-mw"
    "$OPENMW_LIB/libMyGUIEngine.so.3.4.3"
    "$OPENMW_LIB/libstdc++.so.6"
    "$OPENMW_LIB/libgcc_s.so.1"
)

for required in "${required_paths[@]}"; do'''
NEW = '''# TSP_POSIX_V1 - was a bash array, which busybox ash cannot parse: the stock-OS
# card runs this launcher under ash, not bash, and died here with
# "line 422: syntax error: unexpected \\"(\\"" before the game ever started.
#
# Fed by a heredoc, NOT a pipe. A pipe would put the loop in a subshell and the
# exit 1 below would leave the launcher running with a missing runtime file.
# The heredoc keeps the loop in the current shell, and read -r with IFS unset
# keeps paths containing spaces intact.
while IFS= read -r required; do
    [ -n "$required" ] || continue'''
TAIL_OLD = '''        exit 1
    fi
done

for required_lib in \\'''
TAIL_NEW = '''        exit 1
    fi
done <<TSP_REQEOF
$OPENMW_BIN
$CONTROL_HELPER
$OPENMW_RESOURCES
$OPENMW_RESOURCES/defaults.bin
$OPENMW_RESOURCES/vfs
$OPENMW_RESOURCES/vfs-mw
$OPENMW_LIB/libMyGUIEngine.so.3.4.3
$OPENMW_LIB/libstdc++.so.6
$OPENMW_LIB/libgcc_s.so.1
TSP_REQEOF

for required_lib in \\'''
for name, a in (("array head", OLD), ("loop tail", TAIL_OLD)):
    n = s.count(a)
    print("  anchor %-11s %d match%s %s" % (name, n, "" if n == 1 else "es",
                                            "OK" if n == 1 else "<-- PROBLEM"))
    if n != 1:
        print("  REFUSING: anchor did not match exactly once. Launcher untouched.")
        sys.exit(3)
s = s.replace(OLD, NEW, 1).replace(TAIL_OLD, TAIL_NEW, 1)
checks = [
    ("marker present once", s.count("TSP_POSIX_V1") == 1),
    ("no bash array left", "required_paths=(" not in s and "${required_paths[@]}" not in s),
    ("heredoc opened and closed", s.count("<<TSP_REQEOF") == 1 and s.count("\nTSP_REQEOF\n") == 1),
    ("all nine paths still listed",
     all(p in s for p in ("$OPENMW_BIN", "$CONTROL_HELPER", "$OPENMW_RESOURCES/defaults.bin",
                          "$OPENMW_RESOURCES/vfs", "$OPENMW_RESOURCES/vfs-mw",
                          "$OPENMW_LIB/libMyGUIEngine.so.3.4.3", "$OPENMW_LIB/libstdc++.so.6",
                          "$OPENMW_LIB/libgcc_s.so.1"))),
    ("the exit 1 is still inside the loop", "        exit 1\n    fi\ndone <<TSP_REQEOF" in s),
]
bad = 0
for label, ok in checks:
    print("  %-36s %s" % (label, "PASS" if ok else "FAIL"))
    bad += 0 if ok else 1
if bad:
    print("  REFUSING: %d assertion(s) failed. Launcher untouched." % bad)
    sys.exit(3)
open(dst, 'w', encoding='utf-8', errors='surrogateescape').write(s)
print("  wrote %s  md5 %s" % (dst, hashlib.md5(
    open(dst, 'rb').read()).hexdigest()))
PYEOF

[ -s "$WORK/mw.new" ] || abort "the patched file is empty - nothing uploaded"

# Local parse gate. dash is the closest thing here to the card busybox ash, and
# on the original it reproduces the device error verbatim.
say ""
say "-- local parse gate --"
for s in dash sh bash; do
    command -v "$s" >/dev/null 2>&1 || continue
    if "$s" -n "$WORK/mw.new" 2>/dev/null; then say "  $s -n: clean"
    else say "  $s -n: FAILED"; abort "the patched launcher does not parse under $s locally"; fi
done

scp $SSHO "$WORK/mw.new" "$DEV:$LAUNCHER.posix-new" >/dev/null 2>&1 \
    || abort "scp failed - the launcher is untouched"

rin <<IEOF
L='$LAUNCHER'
N="\$L.posix-new"
[ -s "\$N" ] || { echo "    uploaded file is empty - NOT installing"; exit 1; }

# THE decisive gate, and the one place an absolute pass is right: the entire
# point of this patch is that the card own /bin/sh can parse the launcher.
if sh -n "\$N" 2>/tmp/tsp_shn.txt; then
    echo "    /bin/sh -n on the DEVICE: PARSES CLEAN"
else
    echo "    /bin/sh -n on the DEVICE: FAILED ->"
    sed 's/^/      /' /tmp/tsp_shn.txt
    rm -f "\$N" /tmp/tsp_shn.txt
    echo "    NOT installing."
    exit 1
fi
rm -f /tmp/tsp_shn.txt

if ls "\$L".before-posix-* >/dev/null 2>&1; then
    printf '    original already preserved at %s\n' "\$(ls -1tr "\$L".before-posix-* | head -1)"
else
    cp -p "\$L" "\$L.before-posix-$STAMP" \\
      && printf '    backed up to %s.before-posix-%s\n' "\$L" "$STAMP"
fi

cp -p "\$L" "\$L.posix-prev"
mv "\$N" "\$L"
chmod +x "\$L"
if grep -q '$MARK' "\$L" && sh -n "\$L" 2>/dev/null; then
    echo "    INSTALLED: marker present and it parses"
    printf '    md5 now: %s  lines: %s\n' "\$(md5sum "\$L" | cut -d' ' -f1)" "\$(wc -l < "\$L")"
    rm -f "\$L.posix-prev"
else
    echo "    VERIFY FAILED - rolling back"
    cp -p "\$L.posix-prev" "\$L"; chmod +x "\$L"; rm -f "\$L.posix-prev"
    exit 1
fi
IEOF

hr "DONE"
cat <<'FEOF'
  Launch Morrowind from the ports menu on this card. If it still stops early,
  the log will now say where - and it will be a different line, because 422 is
  the only bash-only construct in the file.

      ssh root@192.168.1.12 "tail -40 \
        /mnt/SDCARD/data/ports/openmw/openmw_log.txt"

  Two things to expect on the stock card even once it starts:

    - SDL2 there has no sensor API. The launcher already handles that with
      libtsp_sdl_sensor_shim.so and says so in the log. Not a fault.
    - It loads /usr/trimui/lib/libSDL2-2.0.so.0, which is a different SDL2 from
      the CrossMix card. If behaviour differs between the cards after this, that
      is the first thing to compare - scope section 3 prints both.

  Back out with:  bash ~/Downloads/tsp_cfw.sh undo
  (but the original cannot start the game on this card at all)
FEOF
printf '\n      bash ~/Downloads/tsp_cfw.sh scope\n'
printf '  ...on the OTHER card too, so I can see both.\n\n'
