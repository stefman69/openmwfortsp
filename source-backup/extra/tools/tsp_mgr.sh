#!/bin/sh
# ===========================================================================
# tsp_mgr.sh  -  TSP_MGR_V1
#
# Read-only audit of the OpenMW manager on ONE card. Answers, from the card
# itself rather than from inference:
#
#   * is there a real bash on this card, and what does /bin/bash actually do
#   * is there a python3 for the manager backend
#   * does this card's own /bin/sh parse each manager script
#   * what the manager log says it did last time
#   * what is and is not set up for first load: navmesh, swap, content=, ASTC
#
# It also PULLS the card's real manager files back to ~/Downloads so a patch
# can be built against what is actually installed rather than a stale copy.
#
# MODES
#   scope          full audit + pull   (default)
#   pull           pull the manager files only
#   help
#
# POINTING IT AT A CARD  -  resolution order, first match wins:
#   TSP=root@192.168.1.21 sh tsp_mgr.sh scope     explicit, wins over everything
#   $TSP_DEV                                      set per-run by tsp_net.sh each
#   ~/.tsp_dev                                    written by tsp_net.sh use
#   root@192.168.1.12                             the old default, last
# ===========================================================================

MODE="${1:-scope}"

# --- integrity gate, FIRST thing --------------------------------------------
# A download or copy that ends inside the embedded probe's heredoc would make
# the shell swallow the rest of the file and exit 0 after step 2, which looks
# like success. This runs before the heredoc, so it catches that.
if ! grep -q '^# TSP_MGR_V1 END OF FILE$' "$0" 2>/dev/null; then
    echo "tsp_mgr: this copy of the script is truncated - download it again" >&2
    exit 1
fi

# --- device resolution (CONSTRAINT-two-cards-are-addressed-by-name) --------
# Every line here returns 0 so a missing ~/.tsp_dev cannot trip set -e.
DEVICE=""
[ -n "${TSP:-}" ] && DEVICE="$TSP"
[ -z "$DEVICE" ] && [ -n "${DEV:-}" ] && DEVICE="$DEV"
[ -z "$DEVICE" ] && [ -n "${TSP_DEV:-}" ] && DEVICE="$TSP_DEV"
[ -z "$DEVICE" ] && [ -f "$HOME/.tsp_dev" ] && DEVICE="$(cat "$HOME/.tsp_dev" 2>/dev/null)"
[ -z "$DEVICE" ] && DEVICE="root@192.168.1.12"
true

# --- a friendly label for this card, from the registry if it is there ------
HOSTPART="${DEVICE#*@}"
LABEL=""
if [ -f "$HOME/.tsp_hosts" ]; then
    LABEL="$(awk -v d="$DEVICE" '$2 == d { print $1; exit }' "$HOME/.tsp_hosts" 2>/dev/null)"
fi
[ -n "$LABEL" ] || LABEL="$(echo "$HOSTPART" | tr '.' '-')"

DL="$HOME/Downloads"
[ -d "$DL" ] || DL="$HOME"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DL/tsp-mgr-scope-$LABEL-$TS.txt"
PULLDIR="$DL/tsp-mgr-pull-$LABEL-$TS"

SSHOPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
REMOTE_PROBE="/tmp/tsp_mgr_probe.sh"
ROOT_DEFAULT="/mnt/SDCARD/data/ports/openmw"

step() { echo "[$1] $2"; }
die()  { echo "tsp_mgr: $*" >&2; exit 1; }

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

[ "$MODE" = "help" ] && usage
[ "$MODE" = "-h" ] && usage
[ "$MODE" = "--help" ] && usage

echo "tsp_mgr V1  -  device: $DEVICE   label: $LABEL"
echo

# ---------------------------------------------------------------------------
# 1. reachability - and say WHY if it fails, never silently drop a host
# ---------------------------------------------------------------------------
step 1/6 "checking $DEVICE is reachable"
probe_out="$(ssh -n $SSHOPTS "$DEVICE" 'echo TSP_MGR_SSH_OK; uname -n' 2>&1)"
probe_rc=$?
case "$probe_out" in
    *TSP_MGR_SSH_OK*) : ;;
    *)
        echo "      UNREACHABLE rc=$probe_rc"
        echo "      $probe_out" | head -5
        echo
        echo "      If this is the stock card and the key is not installed yet:"
        echo "         sh ~/Downloads/tsp_net.sh key root@192.168.1.21"
        echo "         sh ~/Downloads/tsp_net.sh add tsp root@192.168.1.21"
        die "cannot reach $DEVICE"
        ;;
esac
echo "      reachable: $(echo "$probe_out" | tail -1)"

# ---------------------------------------------------------------------------
# 2. write the probe locally, then copy it over
# ---------------------------------------------------------------------------
step 2/6 "staging the probe"
LOCAL_PROBE="${TMPDIR:-/tmp}/tsp_mgr_probe.$$.sh"
cat > "$LOCAL_PROBE" <<'TSP_MGR_PROBE_EOF'
#!/bin/sh
# ---------------------------------------------------------------------------
# tsp_mgr device probe  -  TSP_MGR_PROBE_V1
# Runs ON THE CARD, under the card's own /bin/sh. Read-only: it creates nothing
# outside /tmp and modifies nothing in the game build.
#
# Written in strict POSIX sh because the stock TrimUI card's /bin/sh is busybox
# ash and its /bin/bash is a busybox symlink that answers "applet not found".
# ---------------------------------------------------------------------------

ROOT="${OPENMW_GAMEDIR:-/mnt/SDCARD/data/ports/openmw}"
NAVDIR="${OPENMW_NAVMESH_DIR:-/mnt/UDISK/openmw-nav}"
SWAP=/mnt/UDISK/openmw-swapfile
TMP=/tmp/tsp-mgr-probe.$$
mkdir -p "$TMP" 2>/dev/null

say()  { echo "$@"; }
hdr()  { echo; echo "===== $* ====="; }
kv()   { printf '%-34s %s\n' "$1" "$2"; }

# A file's md5 prefix, or a reason.
md5of() {
    [ -f "$1" ] || { echo "ABSENT"; return; }
    if command -v md5sum >/dev/null 2>&1; then
        md5sum "$1" 2>/dev/null | cut -c1-8
    else
        echo "NO-MD5SUM"
    fi
}

lines_of() { [ -f "$1" ] && wc -l < "$1" 2>/dev/null | tr -d ' ' || echo "-"; }
size_of()  { [ -e "$1" ] && wc -c < "$1" 2>/dev/null | tr -d ' ' || echo "-"; }

say "TSP_MGR_PROBE_V1"
say "probe run at: $(date 2>/dev/null)"
say "ROOT=$ROOT"

# ---------------------------------------------------------------------------
hdr "1. CARD IDENTITY"
# ---------------------------------------------------------------------------
kv "hostname" "$(cat /proc/sys/kernel/hostname 2>/dev/null)"
kv "/etc/version" "$(cat /etc/version 2>/dev/null | head -1)"
kv "/etc/os-release PRETTY" "$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | head -1)"
kv "kernel" "$(uname -r 2>/dev/null)"
kv "dt model" "$(cat /proc/device-tree/model 2>/dev/null | tr -d '\000')"

IPADDR=""
if command -v ip >/dev/null 2>&1; then
    IPADDR=$(ip -4 addr show 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | grep -v '^127\.' | head -1)
fi
if [ -z "$IPADDR" ] && command -v ifconfig >/dev/null 2>&1; then
    IPADDR=$(ifconfig 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p' | grep -v '^127\.' | head -1)
    [ -n "$IPADDR" ] || IPADDR=$(ifconfig 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | grep -v '^127\.' | head -1)
fi
kv "THIS CARD'S IP" "${IPADDR:-unknown}"
kv "MAC (wlan0)" "$(cat /sys/class/net/wlan0/address 2>/dev/null)"

# ---------------------------------------------------------------------------
hdr "2. THE SHELL  -  is there a real bash on this card?"
# ---------------------------------------------------------------------------
kv "/bin/sh ->" "$(readlink -f /bin/sh 2>/dev/null)"
kv "\$BASH_VERSION in this shell" "${BASH_VERSION:-(empty - not bash)}"
kv "busybox version" "$(busybox 2>&1 | head -1)"

# A trivial probe script. If a candidate can run this, it is a usable shell.
printf '#!/bin/sh\necho PROBE_SHELL_RAN\n' > "$TMP/probe.sh" 2>/dev/null
chmod 755 "$TMP/probe.sh" 2>/dev/null

# A probe that only a REAL bash can run (array + BASH_VERSION).
printf 'a=(1 2 3); echo BASH_REAL ${#a[@]} $BASH_VERSION\n' > "$TMP/bashonly.sh" 2>/dev/null

say ""
say "candidate bash paths - what each one ACTUALLY does:"
for cand in /bin/bash /usr/bin/bash /usr/local/bin/bash \
            /mnt/SDCARD/System/bin/bash \
            /mnt/SDCARD/App/PortMaster/bash \
            /mnt/SDCARD/Tools/PortMaster/bash \
            /mnt/SDCARD/Emus/PORTS/bash
do
    if [ ! -e "$cand" ]; then
        printf '  %-42s ABSENT\n' "$cand"
        continue
    fi
    link=$(readlink -f "$cand" 2>/dev/null)
    out=$("$cand" "$TMP/bashonly.sh" 2>&1)
    rc=$?
    case "$out" in
        BASH_REAL*) verdict="REAL BASH   [$out]" ;;
        *)          verdict="NOT BASH    rc=$rc out=[$out]" ;;
    esac
    printf '  %-42s %s\n' "$cand" "$verdict"
    printf '  %-42s   -> resolves to %s (%s bytes)\n' "" "$link" "$(size_of "$cand")"
done

say ""
kv "command -v bash" "$(command -v bash 2>/dev/null || echo '(none)')"
say ""
say "what a '#!/bin/bash' script does when exec'd by the kernel:"
printf '#!/bin/bash\necho SHEBANG_BASH_RAN\n' > "$TMP/sb.sh" 2>/dev/null
chmod 755 "$TMP/sb.sh" 2>/dev/null
sbout=$("$TMP/sb.sh" 2>&1); sbrc=$?
kv "  ./script rc" "$sbrc"
kv "  ./script output" "$sbout"
say ""
say "what 'env -i /bin/bash -c' does (the manager uses this twice):"
eout=$(env -i /bin/bash -c 'echo ENVI_BASH_RAN' 2>&1); erc=$?
kv "  rc" "$erc"
kv "  output" "$eout"

# ---------------------------------------------------------------------------
hdr "3. PYTHON  -  the manager's backend is a python3 script"
# ---------------------------------------------------------------------------
for cand in python3 python; do
    p=$(command -v "$cand" 2>/dev/null)
    if [ -n "$p" ]; then
        printf '  %-42s %s  [%s]\n' "command -v $cand" "$p" "$("$p" -V 2>&1 | head -1)"
    else
        printf '  %-42s (none on PATH)\n' "command -v $cand"
    fi
done
for cand in /usr/bin/python3 /usr/bin/python \
            /mnt/SDCARD/System/bin/python3 \
            /mnt/SDCARD/App/PortMaster/python3 \
            /mnt/SDCARD/Tools/PortMaster/python3
do
    if [ -x "$cand" ]; then
        printf '  %-42s PRESENT  [%s]\n' "$cand" "$("$cand" -V 2>&1 | head -1)"
    else
        printf '  %-42s absent\n' "$cand"
    fi
done
say ""
say "what the backend's own shebang does:"
PY="$ROOT/launcher/openmw-launcher-backend-v2.py"
if [ -f "$PY" ]; then
    kv "  shebang" "$(head -1 "$PY")"
    if [ -x "$PY" ]; then
        # Capture the rc of $PY itself. Piping into head first would make $?
        # the rc of head, which is always 0 and hides every failure.
        pyraw=$("$PY" status 2>&1); pyrc=$?
        pyout=$(echo "$pyraw" | head -3)
        kv "  '\$PY status' rc" "$pyrc"
        say "  '\$PY status' first lines:"
        echo "$pyout" | sed 's/^/    /'
    else
        kv "  executable" "NO - not +x"
    fi
else
    kv "  backend" "ABSENT at $PY"
fi

# ---------------------------------------------------------------------------
hdr "4. MANAGER ARTIFACTS PRESENT"
# ---------------------------------------------------------------------------
for f in "$ROOT/bin/openmw-manager-v2" \
         "$ROOT/launcher/openmw-manager-action-v2.sh" \
         "$ROOT/launcher/openmw-launcher-backend-v2.py" \
         "$ROOT/tools/OpenMW_Generate_Full_Navmesh_3Worker.sh" \
         "$ROOT/tools/tsp_texconv" \
         "$ROOT/lib/libtsp_sdl_sensor_shim.so"
do
    if [ -e "$f" ]; then
        perms=$(ls -l "$f" 2>/dev/null | cut -c1-10)
        printf '  %-58s md5=%s  %sB  %sL  %s\n' "${f#$ROOT/}" "$(md5of "$f")" "$(size_of "$f")" "$(lines_of "$f")" "$perms"
    else
        printf '  %-58s ABSENT\n' "${f#$ROOT/}"
    fi
done
say ""
say "Ports entries:"
for d in /mnt/SDCARD/Roms/PORTS /mnt/sdcard/mmcblk1p1/Roms/PORTS /mnt/SDCARD/Emus/PORTS; do
    [ -d "$d" ] || continue
    ls -l "$d" 2>/dev/null | grep -i -e 'openmw' -e 'morrowind' | sed 's/^/  /'
done
say ""
say "manager binary version markers:"
MB="$ROOT/bin/openmw-manager-v2"
if [ -f "$MB" ]; then
    # busybox may have no `strings`; grep -a on the binary is the fallback.
    bintok() {
        if command -v strings >/dev/null 2>&1; then
            strings "$MB" 2>/dev/null | grep -F -e "$1" 2>/dev/null | wc -l | tr -d ' '
        else
            grep -a -o -F -e "$1" "$MB" 2>/dev/null | wc -l | tr -d ' '
        fi
    }
    for tok in 'INTEGRATED V3.0' 'INTEGRATED V2.9' 'INTEGRATED V2.8' \
               'CONVERT TEXTURES FOR LOW MEMORY' 'ASTC TEXTURES' '/bin/bash'
    do
        n=$(bintok "$tok")
        [ -n "$n" ] || n=0
        printf '  %-42s %s\n' "$tok" "$n"
    done
    say ""
    say "  ldd (missing libraries show as 'not found'):"
    ldd "$MB" 2>&1 | sed 's/^/    /' | head -30
fi

# ---------------------------------------------------------------------------
hdr "5. DOES THIS CARD'S SHELL PARSE THE MANAGER SCRIPTS?"
# ---------------------------------------------------------------------------
say "(this is the single line that says whether a script can run at all here)"
say ""
for f in "$ROOT/launcher/openmw-manager-action-v2.sh" \
         "$ROOT/tools/OpenMW_Generate_Full_Navmesh_3Worker.sh" \
         /mnt/SDCARD/Roms/PORTS/OpenMW_Manager.sh \
         /mnt/sdcard/mmcblk1p1/Roms/PORTS/OpenMW_Manager.sh \
         /mnt/SDCARD/Roms/PORTS/Morrowind.sh
do
    [ -f "$f" ] || continue
    out=$(/bin/sh -n "$f" 2>&1); rc=$?
    if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
        printf '  %-56s sh -n OK\n' "$(basename "$f")"
    else
        printf '  %-56s sh -n FAIL rc=%s\n' "$(basename "$f")" "$rc"
        echo "$out" | sed 's/^/      /'
    fi
    printf '  %-56s shebang: %s\n' "" "$(head -1 "$f")"
done

# ---------------------------------------------------------------------------
hdr "6. MANAGER LOGS  -  what it actually did last time"
# ---------------------------------------------------------------------------
for f in "$ROOT/launcher/manager-v2.log" \
         "$ROOT/launcher/last-result.txt" \
         "$ROOT/launcher/pending-report" \
         "$ROOT/launcher/request"
do
    say ""
    say "--- ${f#$ROOT/} ($(size_of "$f") bytes) ---"
    if [ -f "$f" ]; then
        tail -n 60 "$f" 2>/dev/null | sed 's/^/  /'
    else
        say "  ABSENT"
    fi
done

# ---------------------------------------------------------------------------
hdr "7. FIRST-LOAD STATE  -  what is and is not set up on this card"
# ---------------------------------------------------------------------------
say "navmesh:"
kv "  $NAVDIR/navmesh.db" "$(size_of "$NAVDIR/navmesh.db") bytes"
if [ -f "$NAVDIR/navmesh.db" ]; then
    kv "  mtime" "$(ls -l "$NAVDIR/navmesh.db" 2>/dev/null | awk '{print $6, $7, $8}')"
fi
for f in "$ROOT/data/navmesh.db" "$ROOT/defaults/navmesh.db"; do
    [ -e "$f" ] && kv "  shipped copy $f" "$(size_of "$f") bytes"
done
say ""
say "  navmesh profile markers in the build:"
# Capture first: `ls ... | sed ... || say` would test sed's status, not ls's.
marker_ls=$(ls -l "$ROOT/launcher"/*navmesh* "$ROOT/launcher"/*default* 2>/dev/null)
if [ -n "$marker_ls" ]; then echo "$marker_ls" | sed 's/^/    /'; else say "    (none)"; fi
for m in "$ROOT/launcher/navmesh-profile" "$ROOT/launcher/default-profile"; do
    [ -f "$m" ] && { say "    --- $m ---"; sed 's/^/      /' "$m" 2>/dev/null | head -20; }
done

say ""
say "swap:"
kv "  $SWAP" "$(size_of "$SWAP") bytes"
say "  /proc/swaps:"
cat /proc/swaps 2>/dev/null | sed 's/^/    /'
kv "  swappiness" "$(cat /proc/sys/vm/swappiness 2>/dev/null)"
kv "  MemTotal" "$(sed -n 's/^MemTotal: *//p' /proc/meminfo 2>/dev/null)"

say ""
say "textures / ASTC:"
kv "  tsp_texconv.done" "$( [ -f "$ROOT/data/Data Files/tsp_texconv.done" ] && cat "$ROOT/data/Data Files/tsp_texconv.done" 2>/dev/null | tr '\n' ' ' || echo ABSENT)"
kv "  .ktx count in textures" "$(ls -1 "$ROOT/data/Data Files/textures"/*.ktx 2>/dev/null | wc -l | tr -d ' ')"

say ""
say "config chain:"
for c in "$ROOT/config/openmw.cfg" "$ROOT/openmw.cfg"; do
    [ -f "$c" ] || continue
    say "  --- $c ($(lines_of "$c") lines) ---"
    kv "    data= lines" "$(grep -c '^data=' "$c" 2>/dev/null | head -1)"
    kv "    content= lines" "$(grep -c '^content=' "$c" 2>/dev/null | head -1)"
    say "    content list:"
    grep '^content=' "$c" 2>/dev/null | sed 's/^/      /'
done
say ""
say "  settings.cfg:"
kv "    $ROOT/config/settings.cfg" "$(size_of "$ROOT/config/settings.cfg") bytes"

say ""
say "game log tail:"
for L in "$ROOT/openmw_log.txt" /mnt/SDCARD/Roms/PORTS/openmw_log.txt; do
    [ -f "$L" ] || continue
    say "  --- $L ---"
    tail -n 25 "$L" 2>/dev/null | sed 's/^/    /'
    break
done

# ---------------------------------------------------------------------------
hdr "8. VERDICT"
# ---------------------------------------------------------------------------
BASHREAL=0
for cand in /bin/bash /usr/bin/bash /mnt/SDCARD/System/bin/bash /mnt/SDCARD/App/PortMaster/bash; do
    [ -e "$cand" ] || continue
    case "$("$cand" "$TMP/bashonly.sh" 2>&1)" in BASH_REAL*) BASHREAL=1; BASHPATH="$cand"; break ;; esac
done
PY3=0
command -v python3 >/dev/null 2>&1 && PY3=1
kv "REAL_BASH" "$BASHREAL ${BASHPATH:-}"
kv "PYTHON3" "$PY3 $(command -v python3 2>/dev/null)"
kv "MANAGER_BIN" "$( [ -x "$ROOT/bin/openmw-manager-v2" ] && echo present || echo MISSING )"
kv "CARD_IP" "${IPADDR:-unknown}"

rm -rf "$TMP" 2>/dev/null
say ""
say "TSP_MGR_PROBE_V1 END"
TSP_MGR_PROBE_EOF

# Refuse rather than ship a truncated probe.
if ! grep -q 'TSP_MGR_PROBE_V1 END' "$LOCAL_PROBE"; then
    rm -f "$LOCAL_PROBE"
    die "the embedded probe is truncated - this copy of tsp_mgr.sh is damaged"
fi
echo "      $(wc -l < "$LOCAL_PROBE" | tr -d ' ') lines"

if [ "$MODE" = "scope" ]; then
    step 3/6 "copying the probe to the card"
    scp $SSHOPTS "$LOCAL_PROBE" "$DEVICE:$REMOTE_PROBE" >/dev/null 2>&1 \
        || die "scp of the probe failed"

    # ---------------------------------------------------------------------
    # 4. run it - in the background, with live progress, never silent
    # ---------------------------------------------------------------------
    step 4/6 "running the audit on the card (output -> $OUT)"
    : > "$OUT"
    ssh -n $SSHOPTS "$DEVICE" "sh $REMOTE_PROBE" >> "$OUT" 2>&1 &
    SSHPID=$!
    waited=0
    while kill -0 "$SSHPID" 2>/dev/null; do
        sleep 2
        waited=$((waited + 2))
        printf '      %3ds  %s lines captured\n' "$waited" "$(wc -l < "$OUT" 2>/dev/null | tr -d ' ')"
        [ "$waited" -ge 240 ] && { echo "      giving up after 240s"; kill "$SSHPID" 2>/dev/null; break; }
    done
    wait "$SSHPID" 2>/dev/null
    ssh -n $SSHOPTS "$DEVICE" "rm -f $REMOTE_PROBE" >/dev/null 2>&1
    echo "      done: $(wc -l < "$OUT" 2>/dev/null | tr -d ' ') lines"
else
    step 3/6 "skipped (pull mode)"
    step 4/6 "skipped (pull mode)"
fi
rm -f "$LOCAL_PROBE"

# ---------------------------------------------------------------------------
# 5. pull the real files so a patch is built against what is installed
# ---------------------------------------------------------------------------
step 5/6 "pulling the card's manager files -> $PULLDIR"
mkdir -p "$PULLDIR" 2>/dev/null
GAMEROOT="$ROOT_DEFAULT"
for f in \
    "$GAMEROOT/launcher/openmw-manager-action-v2.sh" \
    "$GAMEROOT/launcher/openmw-launcher-backend-v2.py" \
    "$GAMEROOT/tools/OpenMW_Generate_Full_Navmesh_3Worker.sh" \
    "$GAMEROOT/launcher/manager-v2.log" \
    "$GAMEROOT/config/openmw.cfg" \
    /mnt/SDCARD/Roms/PORTS/OpenMW_Manager.sh
do
    base="$(basename "$f")"
    if scp $SSHOPTS "$DEVICE:$f" "$PULLDIR/$base" >/dev/null 2>&1; then
        printf '      got  %-44s %s bytes\n' "$base" "$(wc -c < "$PULLDIR/$base" 2>/dev/null | tr -d ' ')"
    else
        printf '      --   %-44s not present on this card\n' "$base"
    fi
done

# ---------------------------------------------------------------------------
# 6. the short answer, on screen
# ---------------------------------------------------------------------------
step 6/6 "summary"
echo
if [ -s "$OUT" ]; then
    echo "--------------------------------------------------------------"
    sed -n '/^===== 8. VERDICT/,$p' "$OUT"
    echo "--------------------------------------------------------------"
    echo "candidate bash paths:"
    sed -n '/candidate bash paths/,/^$/p' "$OUT" | sed '1d'
    echo "--------------------------------------------------------------"
    echo "script parse under this card's own /bin/sh:"
    sed -n '/^===== 5\./,/^===== 6\./p' "$OUT" | sed '1,2d;$d'
    echo "--------------------------------------------------------------"
fi
echo
if [ -s "$OUT" ]; then
    echo "FULL AUDIT  : $OUT"
    echo "PULLED FILES: $PULLDIR"
    echo
    echo "Upload the audit file above (and the pulled folder if you can) and I"
    echo "will build the fix against the files that are actually on that card."
else
    echo "PULLED FILES: $PULLDIR"
    echo
    echo "No audit was run (pull mode). For the full audit: sh $0 scope"
fi

# TSP_MGR_V1 END OF FILE
