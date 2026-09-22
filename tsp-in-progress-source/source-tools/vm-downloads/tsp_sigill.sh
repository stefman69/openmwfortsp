#!/usr/bin/env bash
# tsp_sigill.sh - find out what executed an illegal instruction on the fresh card.
#
#   bash tsp_sigill.sh 1          crash log + binary identity on the card under test
#   bash tsp_sigill.sh 2          same, plus a file-by-file compare against the good card
#   bash tsp_sigill.sh 3          list the launcher's own env switches (for the A/B)
#
# Cards are addressed by name, never by hardcoded IP:
#   NEW=  the card that crashed          (default: $TSP_NEW, then root@192.168.1.21)
#   GOOD= the card that works            (default: $TSP_GOOD, then root@192.168.1.12)
#
# Small output in the terminal; the full dumps go to ~/Downloads.
set -u -o pipefail

printf 'tool: %s  md5 %s\n' "$(basename "$0")" \
    "$(md5sum "$0" 2>/dev/null | cut -d' ' -f1)"

MODE="${1:-1}"
NEW="${NEW:-${TSP_NEW:-root@192.168.1.21}}"
GOOD="${GOOD:-${TSP_GOOD:-root@192.168.1.12}}"
ROOT="${OPENMW_GAMEDIR:-/mnt/SDCARD/data/ports/openmw}"
OUT="${OPENMW_DOWNLOADS_DIR:-$HOME/Downloads}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DUMP="$OUT/tsp-sigill-$STAMP.txt"
SSHOPTS="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

[ -d "$OUT" ] || { echo "ERROR: output directory missing: $OUT" >&2; exit 9; }
: > "$DUMP"

say()  { echo "$*"; }
both() { echo "$*" >> "$DUMP"; }

# ---------------------------------------------------------------- probe ----
# Deliberately busybox-only on the device: no python3, no bash-isms, and no
# recursive walk outside the port tree.
probe() {
    ssh $SSHOPTS "$1" 'sh -s' -- "$ROOT" <<'REMOTE_PROBE' 2>&1
set -u
R="$1"

echo "### identity"
uname -a
[ -r /etc/os-release ] && . /etc/os-release 2>/dev/null && echo "os=${PRETTY_NAME:-unknown}"
grep -m1 '^model name\|^Hardware\|^CPU part' /proc/cpuinfo 2>/dev/null || true
echo "cores=$(grep -c ^processor /proc/cpuinfo 2>/dev/null)"
for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
    [ -r "$c" ] || continue
    printf '%s=%s\n' "$(echo "$c" | sed 's|.*/cpu\([0-9]*\)/.*|cpu\1|')" "$(cat "$c")"
done

echo
echo "### crash log"
if [ -s /tmp/openmw-crash.log ]; then
    echo "present, $(wc -c < /tmp/openmw-crash.log) bytes"
    echo "--- 8< ---"
    cat /tmp/openmw-crash.log
    echo "--- >8 ---"
else
    echo "ABSENT (/tmp is tmpfs - gone after a reboot; re-run the game to regenerate)"
fi
if [ -s /mnt/SDCARD/tsp_crash.txt ]; then
    echo "tsp_crash.txt: $(wc -l < /mnt/SDCARD/tsp_crash.txt) lines, last record:"
    tail -n 40 /mnt/SDCARD/tsp_crash.txt
else
    echo "tsp_crash.txt: absent (libtsp_crash.so is not in the preload chain)"
fi

echo
echo "### binary and libraries"
[ -f "$R/bin/openmw-0.51" ] && sha256sum "$R/bin/openmw-0.51"
[ -f "$R/bin/openmw-0.51" ] && ls -l "$R/bin/openmw-0.51"
for f in "$R"/lib/*.so "$R"/lib/*.so.* ; do
    [ -f "$f" ] || continue
    sha256sum "$f"
done
echo "resources-version:"
for v in "$R/resources/version" "$R/resources/version.txt"; do
    [ -f "$v" ] && { echo "  $v"; sed -n '1,5p' "$v"; }
done

echo
echo "### markers compiled into the binary"
if [ -f "$R/bin/openmw-0.51" ]; then
    strings "$R/bin/openmw-0.51" 2>/dev/null | grep -c 'TSP_' | sed 's/^/  TSP_ marker count: /'
    for m in TSP_LUAJIT_SAFE TSP_MAXCOLORATTACH TSP_RESOLUTION_SPLIT TSP_DEPTH_TRAITS TSP_WARM_ASYNC_GUARD; do
        if strings "$R/bin/openmw-0.51" 2>/dev/null | grep -q "$m"; then
            echo "  PRESENT $m"
        else
            echo "  ABSENT  $m"
        fi
    done
fi

echo
echo "### what the game actually loaded last run"
[ -f "$R/openmw_log.txt" ] && grep -n 'Fatal Error\|Illegal opcode\|signal\|Address:\|exited with code' "$R/openmw_log.txt" | tail -n 12

echo
echo "### mods and content"
[ -f "$R/config/openmw.cfg" ] && grep -c '^content=' "$R/config/openmw.cfg" | sed 's/^/  content lines: /'
[ -f "$R/config/openmw.cfg" ] && grep '^content=' "$R/config/openmw.cfg" | sed 's/^/  /'

echo
echo "### storage"
[ -f /mnt/UDISK/openmw-nav/navmesh.db ] && ls -l /mnt/UDISK/openmw-nav/navmesh.db
[ -f /mnt/UDISK/openmw-swapfile ] && ls -l /mnt/UDISK/openmw-swapfile
grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo
cat /proc/sys/vm/swappiness | sed 's/^/  swappiness=/'
REMOTE_PROBE
}

case "$MODE" in
1|2)
    say "===== card under test: $NEW ====="
    probe "$NEW" > "$DUMP.new" 2>&1 || true
    cat "$DUMP.new" >> "$DUMP"

    say
    say "--- crash log ---"
    if grep -q '^present,' "$DUMP.new"; then
        sed -n '/^--- 8< ---/,/^--- >8 ---/p' "$DUMP.new" \
            | grep -vE '^(warning:|$)' | sed -n '1,40p'
    else
        sed -n '/^### crash log/,/^$/p' "$DUMP.new" | sed -n '2,4p'
    fi

    say
    say "--- binary ---"
    grep -E 'openmw-0\.51$' "$DUMP.new" | head -2
    sed -n '/^### markers/,/^$/p' "$DUMP.new" | sed -n '2,10p'

    say
    say "--- cpu / memory ---"
    grep -E '^cores=|^cpu[0-9]+=|^MemTotal|^MemAvailable|^SwapTotal|  swappiness=' "$DUMP.new" | head -12

    if [ "$MODE" = 2 ]; then
        say
        say "===== known-good card: $GOOD ====="
        probe "$GOOD" > "$DUMP.good" 2>&1 || true
        cat "$DUMP.good" >> "$DUMP"

        say
        say "--- binary and library differences (sha256) ---"
        grep -E '^[0-9a-f]{64}  ' "$DUMP.new"  | awk '{n=$2; sub(/.*\//,"",n); print n, $1}' | sort > "$DUMP.a"
        grep -E '^[0-9a-f]{64}  ' "$DUMP.good" | awk '{n=$2; sub(/.*\//,"",n); print n, $1}' | sort > "$DUMP.b"
        same=0; diff=0; onlynew=0; onlygood=0
        while read -r name sha; do
            other="$(awk -v n="$name" '$1==n {print $2}' "$DUMP.b")"
            if [ -z "$other" ]; then
                onlynew=$((onlynew+1)); echo "  ONLY-ON-NEW   $name"
            elif [ "$other" = "$sha" ]; then
                same=$((same+1))
            else
                diff=$((diff+1)); echo "  DIFFERS       $name"
            fi
        done < "$DUMP.a"
        while read -r name sha; do
            awk -v n="$name" '$1==n {f=1} END {exit !f}' "$DUMP.a" || {
                onlygood=$((onlygood+1)); echo "  MISSING-ON-NEW $name"
            }
        done < "$DUMP.b"
        say "  identical=$same differs=$diff only-on-new=$onlynew missing-on-new=$onlygood"
    fi

    say
    say "full dump: $DUMP"
    ;;
3)
    say "===== how the launcher builds the preload chain, on $NEW ====="
    ssh $SSHOPTS "$NEW" 'sh -s' <<'REMOTE_SWITCHES' 2>&1 | tee -a "$DUMP" | head -70
set -u
P=""
for c in /mnt/SDCARD/Roms/PORTS /mnt/sdcard/mmcblk1p1/Roms/PORTS; do [ -d "$c" ] && P="$c" && break; done
[ -n "$P" ] || { echo "ERROR no PORTS dir"; exit 1; }
L="$P/Morrowind.sh"
[ -f "$L" ] || { echo "ERROR no $L"; exit 1; }
echo "launcher: $L  $(wc -c < "$L") bytes"
sha256sum "$L"
echo
echo "--- every line that mentions the crash tool, the preload chain or quiet mode ---"
grep -n 'libtsp_crash\|LD_PRELOAD\|TSP_QUIET\|PRELOAD_CHAIN\|TSP_AB_SWITCH' "$L" | sed 's/^/  /'
echo
echo "--- is tsp_iotune.conf sourced, and where from ---"
grep -n 'iotune' "$L" | sed 's/^/  /'
[ -f /mnt/SDCARD/tsp_iotune.conf ] && { echo "  tsp_iotune.conf present:"; sed -n '1,40p' /mnt/SDCARD/tsp_iotune.conf | sed 's/^/    /'; } \
                                   || echo "  tsp_iotune.conf ABSENT on this card"
echo
echo "--- environment switches the launcher reads ---"
grep -oE '\$\{(TSP|LIBGL|OPENMW|NAVMESH)_[A-Z0-9_]+:-[^}]*\}' "$L" | sort -u | sed 's/^/  /'
echo
echo "--- flag files at the top of the card (not recursive) ---"
ls -l /mnt/SDCARD/tsp_* 2>/dev/null | sed 's/^/  /' || echo "  none"
REMOTE_SWITCHES
    say
    say "pulling the launcher itself so it can be read here..."
    scp $SSHOPTS "$NEW:/mnt/SDCARD/Roms/PORTS/Morrowind.sh" "$OUT/Morrowind-$STAMP.sh" >/dev/null 2>&1 \
        && say "  saved: $OUT/Morrowind-$STAMP.sh  ($(wc -c < "$OUT/Morrowind-$STAMP.sh") bytes)" \
        || say "  WARNING could not copy the launcher"
    say
    say "full dump: $DUMP"
    ;;
4)
    # NOT a tree walk. The port tree came from one source and is identical -
    # that is settled. What is NOT in the port tree is the interesting part:
    # the knob files at the top of the card, the launcher, the config dir and
    # the kernel vm settings. Seconds, not minutes.
    say "===== what lives OUTSIDE bin/ and lib/, $NEW vs $GOOD ====="
    for side in new good; do
        [ "$side" = new ] && host="$NEW" || host="$GOOD"
        ssh $SSHOPTS "$host" 'sh -s' -- "$ROOT" <<'REMOTE_TREE' > "$DUMP.$side" 2>&1
set -u
R="$1"

# knob and flag files at the top of the card - never recursive
for f in /mnt/SDCARD/tsp_*; do
    [ -f "$f" ] || continue
    printf 'CARD:%s %s\n' "${f##*/}" "$(sha256sum "$f" 2>/dev/null | cut -c1-64)"
done

# the Ports scripts
for c in /mnt/SDCARD/Roms/PORTS /mnt/sdcard/mmcblk1p1/Roms/PORTS; do
    [ -d "$c" ] || continue
    for f in "$c"/*.sh; do
        [ -f "$f" ] || continue
        printf 'PORTS:%s %s\n' "${f##*/}" "$(sha256sum "$f" 2>/dev/null | cut -c1-64)"
    done
    break
done

# the config dir, one level
for f in "$R"/config/*; do
    [ -f "$f" ] || continue
    printf 'CFG:%s %s\n' "${f##*/}" "$(sha256sum "$f" 2>/dev/null | cut -c1-64)"
done

# only the script and plugin files under mods - not the textures
find "$R/mods" -maxdepth 3 \( -name '*.lua' -o -name '*.omwscripts' -o -name '*.esp' \
     -o -name '*.esm' -o -name '*.json' \) -type f 2>/dev/null | while read -r f; do
    printf 'MOD:%s %s\n' "${f#$R/mods/}" "$(sha256sum "$f" 2>/dev/null | cut -c1-64)"
done

printf 'VM:swappiness %s\n' "$(cat /proc/sys/vm/swappiness 2>/dev/null)"
printf 'VM:vfs_cache_pressure %s\n' "$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null)"
printf 'KERNEL:release %s\n' "$(uname -r)"
REMOTE_TREE
        say "  $side: $(wc -l < "$DUMP.$side") entries"
    done
    sort "$DUMP.new" > "$DUMP.a"; sort "$DUMP.good" > "$DUMP.b"
    say
    say "--- files that differ, are missing, or are extra ---"
    awk 'NR==FNR {g[$1]=$2; next}
         { if (!($1 in g)) print "  ONLY-ON-NEW    " $1;
           else if (g[$1] != $2) print "  DIFFERS        " $1;
           delete g[$1] }
         END { for (k in g) print "  MISSING-ON-NEW " k }' "$DUMP.b" "$DUMP.a" \
        | sort | tee -a "$DUMP" | head -40
    n="$(awk 'NR==FNR {g[$1]=$2; next} { if (!($1 in g) || g[$1] != $2) c++; delete g[$1] } END {for (k in g) c++; print c+0}' "$DUMP.b" "$DUMP.a")"
    say "  total differences: $n"
    say
    say "full dump: $DUMP"
    ;;
*)
    echo "usage: $0 [1|2|3|4]" >&2; exit 2;;
esac
