#!/bin/sh
# tsp_ship.sh - ship-readiness for the OpenMW port on every card. POSIX sh on the host VM (bob-simpson). Modes:
#   sh ~/Downloads/tsp_ship.sh            compare: fetch each card's Roms/PORTS/Morrowind.sh + md5s of the port's own
#                                         files (bin, lib, libs, lib.sdl2, resources/version, defaults.bin, settings.cfg,
#                                         openmw.cfg, policy/flag files, mods list) and diff every card against the first
#   sh ~/Downloads/tsp_ship.sh quiet      TSP_QUIET_V1 on each card: every proof line the launcher scattered over the SD
#                                         card (tsp_prog.txt) goes into the one game log instead, the perf sampler
#                                         (openmw_perf_latest.txt) and the ring dumps (tsp_ring/) stay off. Backup kept.
#                                         quiet=off in $GAMEDIR/tsp_drawthread_policy.txt or /mnt/SDCARD/tsp_quiet_off
#                                         brings the side files back for a diagnostic session without editing anything.
#   sh ~/Downloads/tsp_ship.sh unquiet    put back the launcher each card had before quiet
#   sh ~/Downloads/tsp_ship.sh clean      remove the leftover diagnostic side files on each card (never backups/policies)
#   sh ~/Downloads/tsp_ship.sh sync NAME  copy card NAME's launcher onto every other card (backup kept) - run compare first
# Cards come from ~/.tsp_hosts (name<TAB>host); TSP=<host> in the environment limits it to one card.
# Order with the other tools: tsp_drawthread_v1.sh apply FIRST, then quiet (drawthread revert restores a pre-quiet launcher).

MODE="${1:-compare}"
ARG="${2:-}"
STAMP=$(date +%Y%m%d-%H%M%S)
DL="$HOME/Downloads"
SHIP="$DL/tsp_ship"
SSH="${TSP_SSH:-ssh -o ConnectTimeout=10}"
MARK=TSP_QUIET_V1
mkdir -p "$DL" "$SHIP"

say() { printf '%s\n' "$*"; }
hdr() { say ""; say "########## $* ##########"; }
die() { say "  !! $*"; exit 1; }

hosts() {
    if [ -n "$TSP" ]; then
        printf '%s\t%s\n' "${TSP_NAME:-tsp?}" "$TSP"; return
    fi
    if [ -f "$HOME/.tsp_hosts" ]; then
        grep -v '^[[:space:]]*#' "$HOME/.tsp_hosts" | awk 'NF>=2 {print $1 "\t" $2}'
        return
    fi
    say "  !! ~/.tsp_hosts not found - falling back to the two known cards" >&2
    printf 'tsps\t192.168.1.12\ntsp\t192.168.1.21\n'
}
sshhost() { case "$1" in *@*) printf '%s' "$1";; *) printf 'root@%s' "$1";; esac; }

REMOTE_COMMON='
L=""
for c in /mnt/sdcard/mmcblk1p1/Roms/PORTS/Morrowind.sh /mnt/SDCARD/Roms/PORTS/Morrowind.sh; do
    [ -f "$c" ] && { L="$c"; break; }
done
[ -n "$L" ] || { echo "  !! no Morrowind.sh in Roms/PORTS - nothing done"; exit 1; }
GAMEDIR=$(sed -n "s/^GAMEDIR=\"\(.*\)\"[[:space:]]*$/\1/p" "$L" | head -1)
[ -n "$GAMEDIR" ] || GAMEDIR=/mnt/SDCARD/data/ports/openmw
'

# ---------------------------------------------------------------- compare
do_compare() {
    FIRST=""
    hosts | while IFS="$(printf '\t')" read -r NAME HOST; do
        H=$(sshhost "$HOST")
        D="$SHIP/$NAME"; mkdir -p "$D"
        hdr "INVENTORY $NAME ($H)"
        $SSH "$H" sh -s <<EOF_REMOTE > "$D/inventory.txt"
$REMOTE_COMMON
echo "launcher=\$L"
echo "gamedir=\$GAMEDIR"
echo "host=\$(hostname 2>/dev/null) cpus=\$(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | wc -l) sh=\$(readlink -f /bin/sh 2>/dev/null) bash=\$(readlink -f /bin/bash 2>/dev/null)"
echo "== md5 launcher"; md5sum "\$L" | sed "s#  .*#  Morrowind.sh#"
echo "== md5 port files (paths relative to gamedir)"
cd "\$GAMEDIR" 2>/dev/null || exit 1
for f in bin/* lib/* libs/* lib.sdl2/* resources/version resources/defaults.bin config*/openmw/settings.cfg config*/openmw/openmw.cfg *.txt *.cfg *.conf *.env; do
    case "\$f" in *log*.txt|*perf*|tsp_gltime*|*.tmp*|*before-*|*backup*) continue ;; esac
    [ -f "\$f" ] && md5sum "\$f"
done 2>/dev/null | sort -k2
echo "== policy / flag files"
ls -la tsp_*.txt 2>/dev/null | awk '{print \$5, \$NF}'
ls -d /mnt/SDCARD/tsp_* 2>/dev/null
echo "== mods (name size)"
for m in mods/*; do [ -d "\$m" ] && echo "\$(du -sk "\$m" 2>/dev/null | cut -f1) \${m#mods/}"; done 2>/dev/null | sort -k2
echo "== resources/shaders md5 (summary)"; find resources/shaders -type f 2>/dev/null | sort | xargs md5sum 2>/dev/null | md5sum | cut -c1-32
echo "== backup clutter in the port dir (not compared; delete before imaging)"
for f in bin/*before-* bin/*.cfg.before-* lib/*before-* backups/*; do [ -f "\$f" ] && echo "\$(du -k "\$f" | cut -f1) \$f"; done 2>/dev/null | sort -rn | head -12
EOF_REMOTE
        $SSH "$H" 'L=/mnt/sdcard/mmcblk1p1/Roms/PORTS/Morrowind.sh; [ -f "$L" ] || L=/mnt/SDCARD/Roms/PORTS/Morrowind.sh; cat "$L"' < /dev/null > "$D/Morrowind.sh" 2>/dev/null
        say "  $(sed -n 3p "$D/inventory.txt")"
        say "  launcher: $(grep -A1 '== md5 launcher' "$D/inventory.txt" | tail -1)  ($(wc -l < "$D/Morrowind.sh") lines, TSP_DRAWTHREAD_V1=$(grep -c 'TSP_DRAWTHREAD_V1' "$D/Morrowind.sh") TSP_QUIET_V1=$(grep -c 'TSP_QUIET_V1' "$D/Morrowind.sh") bashisms=$(grep -c '^[[:space:]]*[A-Za-z_][A-Za-z_0-9]*=(\|^[[:space:]]*\[\[\|^[[:space:]]*function \|declare \|\${[A-Za-z_]*\[' "$D/Morrowind.sh"))"
        say "  port files hashed: $(sed -n '/== md5 port files/,/== policy/p' "$D/inventory.txt" | grep -c '^[0-9a-f]\{32\}')   mods: $(sed -n '/== mods/,/== resources/p' "$D/inventory.txt" | grep -c '^[0-9]')   backup clutter: $(awk '/^== backup clutter/{f=1; next} /^== /{f=0} f {n++; k+=$1} END {printf "%d files %d MB", n, k/1024}' "$D/inventory.txt")"
        say "  saved: $D/inventory.txt  $D/Morrowind.sh"
    done
    hdr "COMPARE  every card against the first listed"
    set -- $(hosts | cut -f1)
    FIRST=$1; shift
    [ -n "${1:-}" ] || { say "  only one card listed - nothing to compare against"; return 0; }
    for NAME in "$@"; do
        A="$SHIP/$FIRST"; B="$SHIP/$NAME"
        say ""
        say "  -- $FIRST vs $NAME --"
        if cmp -s "$A/Morrowind.sh" "$B/Morrowind.sh"; then say "  launcher: IDENTICAL"; else
            say "  launcher: DIFFERENT  (+$(diff "$A/Morrowind.sh" "$B/Morrowind.sh" | grep -c '^>') / -$(diff "$A/Morrowind.sh" "$B/Morrowind.sh" | grep -c '^<') lines; full: diff -u $A/Morrowind.sh $B/Morrowind.sh)"
            diff "$A/Morrowind.sh" "$B/Morrowind.sh" | grep '^[<>]' | head -12 | sed 's/^/      /'
        fi
        sed -n '/== md5 port files/,/== policy/p' "$A/inventory.txt" | grep '^[0-9a-f]\{32\}' | awk '{print $2, $1}' | sort > "$SHIP/.a.$$"
        sed -n '/== md5 port files/,/== policy/p' "$B/inventory.txt" | grep '^[0-9a-f]\{32\}' | awk '{print $2, $1}' | sort > "$SHIP/.b.$$"
        if cmp -s "$SHIP/.a.$$" "$SHIP/.b.$$"; then say "  port files (bin/lib/libs/resources/config): IDENTICAL ($(wc -l < "$SHIP/.a.$$") files)"; else
            say "  port files: DIFFERENT"
            join -j1 -a1 -a2 -e MISSING -o 0,1.2,2.2 "$SHIP/.a.$$" "$SHIP/.b.$$" | awk -v a="$FIRST" -v b="$NAME" '$2!=$3 {printf "      %-45s %s=%s %s=%s\n", $1, a, substr($2,1,8), b, substr($3,1,8)}' | head -30
        fi
        for sec in "== policy / flag files" "== mods (name size)" "== resources/shaders md5 (summary)"; do
            awk -v s="$sec" 'index($0,s)==1 {f=1; next} /^== / {f=0} f' "$A/inventory.txt" > "$SHIP/.a.$$"; awk -v s="$sec" 'index($0,s)==1 {f=1; next} /^== / {f=0} f' "$B/inventory.txt" > "$SHIP/.b.$$"
            if cmp -s "$SHIP/.a.$$" "$SHIP/.b.$$"; then say "  ${sec#== }: IDENTICAL"; else say "  ${sec#== }: DIFFERENT"; diff "$SHIP/.a.$$" "$SHIP/.b.$$" | grep '^[<>]' | head -10 | sed "s/^</      $FIRST:/; s/^>/      $NAME:/"; fi
        done
        rm -f "$SHIP/.a.$$" "$SHIP/.b.$$"
    done
    say ""
    say "  the launcher that must win is the one that parses under busybox ash (the stock TSP has no bash):"
    say "  sh ~/Downloads/tsp_ship.sh sync <name>   copies <name>'s launcher onto the others, backup kept"
}

# ---------------------------------------------------------------- quiet
write_quiet_awk() {
cat > "$1" <<'EOF_AWK'
# TSP_QUIET_V1 patcher. Input: the current Roms/PORTS/Morrowind.sh. GAMEDIR passed with -v gamedir=...
BEGIN { top = 0; opened = 0; perf = 0; ring = 0 }
/TSP_QUIET_V1/ { print "TSP_QUIET_V1 PATCH REFUSED: launcher already carries the marker" > "/dev/stderr"; exit 4 }
NR == 1 {
    print
    print "# >>> TSP_QUIET_V1 BEGIN"
    print "# Shipping: every proof line the launcher used to scatter over the SD card (tsp_prog.txt) goes into the one"
    print "# game log, the perf sampler (openmw_perf_latest.txt) and the stall ring dumps (tsp_ring/) stay off."
    print "# quiet=off in $GAMEDIR/tsp_drawthread_policy.txt, or touch /mnt/SDCARD/tsp_quiet_off, brings them back."
    print "TSP_QUIET=1"
    print "if grep -qs '^quiet=off' \"" gamedir "/tsp_drawthread_policy.txt\" || [ -f /mnt/SDCARD/tsp_quiet_off ]; then TSP_QUIET=0; fi"
    print "if [ \"$TSP_QUIET\" = 1 ]; then TSP_PROG=/tmp/tsp_prog_early.$$; TSP_PROG_TEE=/dev/null; else TSP_PROG=/mnt/SDCARD/tsp_prog.txt; TSP_PROG_TEE=/mnt/SDCARD/tsp_prog.txt; fi"
    print "# <<< TSP_QUIET_V1 END"
    top = 1
    next
}
{ line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line) }
line == "exec >> \"$LOG_FILE\" 2>&1" && opened == 0 {
    opened = 1
    print
    print "if [ \"$TSP_QUIET\" = 1 ]; then [ -f \"$TSP_PROG\" ] && { cat \"$TSP_PROG\"; rm -f \"$TSP_PROG\"; }; TSP_PROG=\"$LOG_FILE\"; echo \"TSP_QUIET_V1 on: proof lines in this log only, perf sampler off, ring dumps off\"; else echo \"TSP_QUIET_V1 off (policy): side files as before\"; fi   # TSP_QUIET_V1 OPEN"
    next
}
line == "tsp_perf_sampler \"$OPENMW_PID\" &" && perf == 0 {
    perf = 1
    print "if [ \"$TSP_QUIET\" = 1 ]; then TSP_PERF_MONITOR_PID=\"\"; else   # TSP_QUIET_V1 PERF"
    print "tsp_perf_sampler \"$OPENMW_PID\" &"
    print "TSP_PERF_MONITOR_PID=$!"
    print "fi"
    getline nxt
    n2 = nxt; sub(/^[ \t]+/, "", n2); sub(/[ \t]+$/, "", n2)
    if (n2 != "TSP_PERF_MONITOR_PID=$!") { print "TSP_QUIET_V1 PATCH FAILED: line after the sampler start is not TSP_PERF_MONITOR_PID=$!" > "/dev/stderr"; exit 3 }
    next
}
line == "if [ -f /mnt/SDCARD/tsp_ring_off ]; then" && ring == 0 {
    ring = 1
    print "if [ -f /mnt/SDCARD/tsp_ring_off ] || [ \"$TSP_QUIET\" = 1 ]; then   # TSP_QUIET_V1 RING"
    next
}
{
    gsub(/>> \/mnt\/SDCARD\/tsp_prog\.txt/, ">> \"$TSP_PROG\"")
    gsub(/tee -a \/mnt\/SDCARD\/tsp_prog\.txt/, "tee -a \"$TSP_PROG_TEE\"")
    print
}
END { if (top != 1 || opened != 1 || perf != 1 || ring != 1) { print "TSP_QUIET_V1 PATCH FAILED top=" top " opened=" opened " perf=" perf " ring=" ring > "/dev/stderr"; exit 3 } }
EOF_AWK
}
do_quiet() {
    AWK="$DL/tsp_quiet_v1_patch.awk"; write_quiet_awk "$AWK"
    hosts | while IFS="$(printf '\t')" read -r NAME HOST; do
        H=$(sshhost "$HOST")
        hdr "QUIET on $NAME ($H)  $STAMP"
        if ! $SSH "$H" "cat > /tmp/tsp_quiet_v1_patch.awk" < "$AWK"; then say "  !! upload of the patcher failed on $NAME - skipping"; continue; fi
        $SSH "$H" sh -s "$STAMP" <<EOF_REMOTE
$REMOTE_COMMON
STAMP=\$1
echo "  launcher: \$L (\$(wc -l < "\$L") lines) gamedir=\$GAMEDIR"
if grep -q $MARK "\$L"; then echo "  already quiet ($MARK present) - launcher untouched"; grep -n 'TSP_QUIET_V1 \(OPEN\|PERF\|RING\)' "\$L" | cut -c1-90 | sed 's/^/    /'; exit 0; fi
n_prog=\$(grep -c '/mnt/SDCARD/tsp_prog.txt' "\$L"); n_tee=\$(grep -c 'tee -a /mnt/SDCARD/tsp_prog.txt' "\$L")
echo "  before: \$n_prog lines name tsp_prog.txt (\$n_tee of them tee), perf sampler start x\$(grep -c '^[[:space:]]*tsp_perf_sampler "\\\$OPENMW_PID" &' "\$L"), ring gate x\$(grep -c '^[[:space:]]*if \[ -f /mnt/SDCARD/tsp_ring_off \]; then' "\$L"), log open x\$(grep -c '^[[:space:]]*exec >> "\\\$LOG_FILE" 2>&1' "\$L")"
mkdir -p "\$GAMEDIR/backups"; cp "\$L" "\$GAMEDIR/backups/Morrowind.sh.before-quiet-\$STAMP" || { echo "  !! backup failed - untouched"; exit 1; }
if ! awk -v gamedir="\$GAMEDIR" -f /tmp/tsp_quiet_v1_patch.awk "\$L" > "\$L.tmp.\$\$"; then rm -f "\$L.tmp.\$\$"; echo "  !! patcher failed - launcher untouched"; exit 1; fi
if ! bash -n "\$L.tmp.\$\$"; then rm -f "\$L.tmp.\$\$"; echo "  !! patched launcher fails bash -n (busybox ash on the stock TSP) - launcher untouched"; exit 1; fi
chmod 755 "\$L.tmp.\$\$" && mv "\$L.tmp.\$\$" "\$L"
echo "  patched (\$(wc -l < "\$L") lines)  backup: \$GAMEDIR/backups/Morrowind.sh.before-quiet-\$STAMP"
echo "  after: literal tsp_prog.txt targets left: \$(grep -c '>> /mnt/SDCARD/tsp_prog.txt\|tee -a /mnt/SDCARD/tsp_prog.txt' "\$L") (want 0), routed: \$(grep -c '"\\\$TSP_PROG"\|"\\\$TSP_PROG_TEE"' "\$L")"
grep -n 'TSP_QUIET_V1 \(OPEN\|PERF\|RING\)' "\$L" | cut -c1-100 | sed 's/^/    /'
EOF_REMOTE
    done
    say ""
    say "  next: launch once on each card, quit, then  sh ~/Downloads/tsp_ship.sh clean  to remove the old side files,"
    say "        and  sh ~/Downloads/tsp_drawthread_v1.sh check  (v4 reads the proof lines from the game log too)"
}
do_unquiet() {
    hosts | while IFS="$(printf '\t')" read -r NAME HOST; do
        H=$(sshhost "$HOST")
        hdr "UNQUIET on $NAME ($H)"
        $SSH "$H" sh -s "$STAMP" <<EOF_REMOTE
$REMOTE_COMMON
B=\$(ls -t "\$GAMEDIR/backups/Morrowind.sh.before-quiet-"* 2>/dev/null | head -1)
[ -n "\$B" ] || { echo "  no before-quiet backup here - nothing to do"; exit 0; }
cp "\$L" "\$GAMEDIR/backups/Morrowind.sh.quiet-removed-\$1" && cp "\$B" "\$L" && chmod 755 "\$L"
echo "  restored \$B -> \$L  marker now: \$(grep -c $MARK "\$L")"
EOF_REMOTE
    done
}

# ---------------------------------------------------------------- clean
do_clean() {
    hosts | while IFS="$(printf '\t')" read -r NAME HOST; do
        H=$(sshhost "$HOST")
        hdr "CLEAN on $NAME ($H)"
        $SSH "$H" sh -s <<EOF_REMOTE
$REMOTE_COMMON
for f in /mnt/SDCARD/tsp_prog.txt /mnt/SDCARD/tsp_gpuprobe.txt /mnt/SDCARD/tsp_watch.txt /mnt/SDCARD/tsp_dt.txt /mnt/SDCARD/tsp_gltime.txt \\
         "\$GAMEDIR/openmw_perf_latest.txt" "\$GAMEDIR/tsp_gltime.txt" /tmp/tsp_osgstats.txt /tmp/tsp_prog_early.*; do
    [ -e "\$f" ] && { echo "  rm \$f (\$(du -k "\$f" 2>/dev/null | cut -f1) kB)"; rm -f "\$f"; }
done
[ -d /mnt/SDCARD/tsp_ring ] && { echo "  rm -r /mnt/SDCARD/tsp_ring (\$(du -sk /mnt/SDCARD/tsp_ring | cut -f1) kB, \$(ls /mnt/SDCARD/tsp_ring | wc -l) dumps)"; rm -rf /mnt/SDCARD/tsp_ring; }
echo "  kept: \$GAMEDIR/backups (\$(ls "\$GAMEDIR/backups" 2>/dev/null | wc -l) files), policy files: \$(ls "\$GAMEDIR"/tsp_*policy*.txt 2>/dev/null | tr '\\n' ' ')"
echo "  flag files still on the SD card (each one changes behaviour - remove what you do not ship): \$(ls -d /mnt/SDCARD/tsp_* 2>/dev/null | tr '\\n' ' ')"
EOF_REMOTE
    done
}

# ---------------------------------------------------------------- sync
do_sync() {
    [ -n "$ARG" ] || die "usage: sh ~/Downloads/tsp_ship.sh sync <card-name>   (run compare first)"
    SRC="$SHIP/$ARG/Morrowind.sh"
    [ -s "$SRC" ] || die "$SRC missing - run: sh ~/Downloads/tsp_ship.sh compare"
    SRC_MD5=$(md5sum "$SRC" | cut -c1-32)
    say "  source: $ARG  md5=$SRC_MD5  ($(wc -l < "$SRC") lines)"
    hosts | while IFS="$(printf '\t')" read -r NAME HOST; do
        [ "$NAME" = "$ARG" ] && continue
        H=$(sshhost "$HOST")
        hdr "SYNC launcher -> $NAME ($H)  $STAMP"
        if ! $SSH "$H" "cat > /tmp/Morrowind.sh.sync" < "$SRC"; then say "  !! upload failed on $NAME"; continue; fi
        $SSH "$H" sh -s "$STAMP" "$SRC_MD5" <<EOF_REMOTE
$REMOTE_COMMON
[ "\$(md5sum /tmp/Morrowind.sh.sync | cut -c1-32)" = "\$2" ] || { echo "  !! upload md5 mismatch - untouched"; exit 1; }
bash -n /tmp/Morrowind.sh.sync || { echo "  !! source launcher does not parse on this card (bash -n) - untouched"; exit 1; }
mkdir -p "\$GAMEDIR/backups"; cp "\$L" "\$GAMEDIR/backups/Morrowind.sh.before-sync-\$1"
chmod 755 /tmp/Morrowind.sh.sync && mv /tmp/Morrowind.sh.sync "\$L"
echo "  \$L now md5=\$(md5sum "\$L" | cut -c1-32)  backup: \$GAMEDIR/backups/Morrowind.sh.before-sync-\$1"
EOF_REMOTE
    done
}

case "$MODE" in
    compare) do_compare ;;
    quiet)   do_quiet ;;
    unquiet) do_unquiet ;;
    clean)   do_clean ;;
    sync)    do_sync ;;
    *) die "unknown mode '$MODE' (compare|quiet|unquiet|clean|sync <name>)" ;;
esac
