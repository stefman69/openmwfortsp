#!/bin/sh
# tsp_net.sh - a registry of BOTH handhelds, and a way to run anything against
# either or both of them.
#
#   find                 sweep the LAN; report every candidate AND why any was rejected
#   key <name|host>      install your ssh key there - one password prompt, then never again
#   add <name> <host>    record a device by name, e.g. add tsp root@192.168.1.21
#   list                 every recorded device, probed
#   use <name>           point the other tools at that one
#   each <cmd> [args...] run a tsp_*.sh command against EVERY recorded device
#   show                 what the tools are pointed at right now
#
# THE REGISTRY
#
# ~/.tsp_hosts holds "name<TAB>user@host", one per line. ~/.tsp_dev holds the
# one currently selected, which is what every other tool reads. `use` switches
# it; `each` switches it per-run via TSP_DEV without touching the file.
#
# So two devices are supported without editing any other tool:
#
#     sh tsp_net.sh each tsp_cfw.sh scope
#     sh tsp_net.sh each tsp_cfw.sh mark {}-baseline
#
# {} in the arguments is replaced by the device name, so the second line takes
# marks labelled tsps-baseline and tsp-baseline. Without that, both devices
# would write the same label and the second would overwrite the first.
#
# WHY find CHANGED
#
# The first version used BatchMode=yes for the fingerprint, which disables
# password authentication outright. 192.168.1.21 had ssh open and was dropped
# from the results with no explanation - it never appeared in the "which of
# them is the handheld" section at all. A probe that rejects a host silently is
# worse than one that fails, because it looks like an answer. Every candidate
# now reports a reason, and auth failures are named as such so it is obvious
# that a key needs installing rather than that the device is wrong.

set -u
STORE="$HOME/.tsp_dev"
HOSTS="$HOME/.tsp_hosts"
# Every ssh that carries a COMMAND takes -n, or it consumes this script own
# stdin and blocks forever. fingerprint() feeds a heredoc and must NOT use -n.
SSHBASE="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
USER_AT="${TSP_USER:-root}"
STAMP="$(date +%Y%m%d-%H%M%S)"

MODE="${1:-list}"
case "$MODE" in find | key | add | list | use | each | show) ;;
*) printf 'usage: %s find | key <host> | add <name> <host> | list | use <name> | each <cmd...> | show\n' "$0"; exit 2 ;; esac

say() { printf '  %s\n' "$*"; }
hr()  { printf '\n########## %s ##########\n' "$1"; }

REASON=""
FP=""
FPOUT="/tmp/tsp_net_fp.$$"
trap 'rm -f "$FPOUT" "/tmp/tsp_net_err.$$" "/tmp/tsp_net_cand.$STAMP" \
           "/tmp/tsp_net_order.$STAMP" "/tmp/tsp_net_hits.$STAMP"' EXIT HUP INT TERM
# Sets REASON and FP in the CURRENT shell, and returns 0/1. It must NOT be
# called as F="$(fingerprint ...)": inside command substitution every variable
# it sets belongs to the subshell, so REASON came back empty and every failure
# printed "UNREACHABLE:" with no reason at all. Callers use $FP after calling.
#
# BatchMode is OFF so a password-auth device can still be reached; set
# TSP_BATCH=1 to force it back on for unattended use.
fingerprint() {
    REASON=""; FP=""
    _e="/tmp/tsp_net_err.$$"
    ssh $SSHBASE ${TSP_BATCH:+-o BatchMode=yes} "$1" 'sh -s' >"$FPOUT" 2>"$_e" <<'F'
[ -d /mnt/SDCARD ] || { echo "TSP_NO_CARD"; exit 0; }
printf 'CARD=yes'
[ -d /mnt/SDCARD/data/ports/openmw ] && printf ' OPENMW=yes' || printf ' OPENMW=no'
printf ' HOST=%s' "$(cat /proc/sys/kernel/hostname 2>/dev/null)"
# The device states its OWN address. The stock-OS card does not show it in
# the device-info panel, which is the whole reason this address hunt started.
GOTIP=0
for n in wlan0 eth0 usb0; do
    [ -d "/sys/class/net/$n" ] || continue
    a="$(ip -o -4 addr show "$n" 2>/dev/null | awk '{print $4}' | head -1)"
    [ -n "$a" ] || a="$(ifconfig "$n" 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p' | head -1)"
    [ -n "$a" ] || a="$(ifconfig "$n" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)"
    if [ -n "$a" ]; then printf ' %sIP=%s' "$n" "${a%%/*}"; GOTIP=1; fi
    [ -r "/sys/class/net/$n/address" ] && printf ' %sMAC=%s' "$n" "$(cat "/sys/class/net/$n/address")"
done
# Last resort with neither ip nor ifconfig present: the kernel own table.
if [ "$GOTIP" = "0" ] && [ -r /proc/net/fib_trie ]; then
    a="$(awk '/32 host/ {print p} {p=$2}' /proc/net/fib_trie 2>/dev/null | grep -v '^127\.' | sort -u | head -1)"
    [ -n "$a" ] && printf ' IP=%s' "$a"
fi
printf ' SH=%s' "$(readlink /bin/sh 2>/dev/null || echo '?')"
printf ' BASH=%s' "$(command -v bash >/dev/null 2>&1 && echo yes || echo no)"
# NOT device_info.txt - that is a SCRIPT, and grepping it returns the default
# written inside it, which is how every card reported CFW=Unknown. The values
# live in the file the script generates.
for g in "${HOME:-/root}"/device_info_*.txt /root/device_info_*.txt; do
    [ -f "$g" ] || continue
    printf ' CFW=%s-%s' \
        "$(sed -n 's/^ *CFW_NAME=//p' "$g" | head -1 | tr -d '"')" \
        "$(sed -n 's/^ *CFW_VERSION=//p' "$g" | head -1 | tr -d '"')"
    break
done
L=/mnt/SDCARD/Roms/PORTS/Morrowind.sh
if [ -f "$L" ]; then
    printf ' LAUNCHER=%s' "$(md5sum "$L" | cut -c1-8)"
    printf ' POSIXFIX=%s' "$(grep -c TSP_POSIX_V1 "$L" 2>/dev/null)"
fi
printf '\n'
F
    _r=$?
    _o="$(cat "$FPOUT" 2>/dev/null)"
    _err="$(tr '\n' ' ' < "$_e" 2>/dev/null)"
    rm -f "$_e"
    case "$_o" in *TSP_NO_CARD*) REASON="reachable, but no /mnt/SDCARD - not a handheld"; return 1 ;; esac
    if [ -n "$_o" ]; then FP="$_o"; return 0; fi
    case "$_err" in
        *"Permission denied"*|*"Too many authentication"*|*"publickey"*)
            REASON="ssh AUTH failed - no key installed for $USER_AT here. Fix: sh $0 key $1" ;;
        *"Connection refused"*)     REASON="ssh refused the connection" ;;
        *"Connection timed out"*|*"Operation timed out"*) REASON="timed out" ;;
        *"No route to host"*)       REASON="no route" ;;
        *"Host key verification"*)  REASON="host key rejected (should not happen - checking is off)" ;;
        "")                         REASON="no output and no error (rc=$_r)" ;;
        *)                          REASON="ssh said: $_err" ;;
    esac
    return 1
}

reg_get() {   # reg_get <name> -> host
    [ -r "$HOSTS" ] || return 1
    awk -F'\t' -v n="$1" '$1==n {print $2; found=1} END {exit !found}' "$HOSTS"
}
reg_put() {   # reg_put <name> <host>
    # Drops any existing row with this NAME *or* this HOST. Dropping only the
    # name let `find` auto-name .12 "withbash" and a later `add tsps <.12>`
    # add a second row for the same card - so `each` ran every tool on it
    # twice and `list` put a * on two lines. One card, one row.
    touch "$HOSTS"
    awk -F'\t' -v n="$1" -v h="$2" '$1!=n && $2!=h' "$HOSTS" > "$HOSTS.tmp" 2>/dev/null
    printf '%s\t%s\n' "$1" "$2" >> "$HOSTS.tmp"
    sort -o "$HOSTS" "$HOSTS.tmp"; rm -f "$HOSTS.tmp"
}

# ===================================================================== key ===
# One password prompt, then never again. This exists because BatchMode-only
# tooling cannot reach a password-auth device at all, and because `each` would
# otherwise prompt once per device per tool run.
#
# The keys travel as base64 in the ssh COMMAND, not in the heredoc body. That
# way the remote script stays inside a quoted heredoc (nothing expands locally)
# and the payload alphabet is A-Za-z0-9+/= - no quote or metacharacter can
# survive to be interpreted. The heredoc is this ssh stdin, so NO -n here.
if [ "$MODE" = "key" ]; then
    T="${2:-}"
    [ -n "$T" ] || { say "usage: sh $0 key root@192.168.1.21"; say "   or: sh $0 key <a name from: list>"; exit 2; }
    case "$T" in
        *@*) H="$T" ;;
        *.*) H="$USER_AT@$T" ;;
        *)   H="$(reg_get "$T")" || { say "no device named '$T'. Run: sh $0 list"; exit 1; } ;;
    esac

    mkdir -p "$HOME/.ssh" 2>/dev/null
    chmod 700 "$HOME/.ssh" 2>/dev/null
    PUBS=""
    for k in "$HOME/.ssh"/*.pub; do
        [ -r "$k" ] || continue
        PUBS="$PUBS$(cat "$k")
"
    done
    if [ -z "$PUBS" ]; then
        hr "NO KEY YET - MAKING ONE"
        say "RSA rather than ed25519: the stock TrimUI OS may be running dropbear,"
        say "and older dropbear builds do not accept ed25519 keys at all."
        printf '\n'
        command -v ssh-keygen >/dev/null 2>&1 || {
            say "ssh-keygen is not on this machine, so I cannot make a key here."
            say "Make one wherever you normally ssh from, then re-run this."
            exit 1; }
        ssh-keygen -t rsa -b 3072 -N "" -f "$HOME/.ssh/id_rsa" || { say "ssh-keygen failed"; exit 1; }
        PUBS="$(cat "$HOME/.ssh/id_rsa.pub")
"
    fi
    NKEY="$(printf '%s' "$PUBS" | grep -c .)"

    hr "INSTALLING $NKEY KEY(S) ON $H"
    say "ssh is about to ask for the DEVICE password. Type it once."
    say "After this, every tsp_*.sh tool reaches this card without a prompt."
    printf '\n'
    B64="$(printf '%s' "$PUBS" | base64 | tr -d '\n')"
    ssh $SSHBASE "$H" "sh -s '$B64'" <<'F'
K="${1:-}"
TMP="/tmp/tsp_newkeys.$$"
printf '%s' "$K" | base64 -d > "$TMP" 2>/dev/null
[ -s "$TMP" ] || { rm -f "$TMP"; echo "TSP_KEY_FAIL base64 -d produced nothing"; exit 1; }

echo "  ssh daemon here: $(ps 2>/dev/null | grep -e dropbear -e sshd | grep -v grep | head -2 | tr -s ' ' | cut -c1-70 | tr '\n' '|')"

install_to() {   # install_to <authorized_keys path>
    _a="$1"
    _d="${_a%/*}"
    mkdir -p "$_d" 2>/dev/null || { echo "  SKIP $_a (cannot create $_d)"; return 1; }
    chmod 700 "$_d" 2>/dev/null
    touch "$_a" 2>/dev/null || { echo "  SKIP $_a (cannot write)"; return 1; }
    chmod 600 "$_a" 2>/dev/null
    _n=0
    while IFS= read -r line; do
        case "$line" in "") continue ;; esac
        grep -qxF "$line" "$_a" 2>/dev/null && continue
        printf '%s\n' "$line" >> "$_a"
        _n=$((_n + 1))
    done < "$TMP"
    echo "  TSP_KEY_OK added=$_n now_holds=$(grep -c . "$_a") file=$_a"
    return 0
}

OK=0
install_to "${HOME:-/root}/.ssh/authorized_keys" && OK=1
# dropbear builds are sometimes pointed here instead of the home directory; a
# key written only to $HOME then silently does nothing.
[ -d /etc/dropbear ] && { install_to /etc/dropbear/authorized_keys && OK=1; }
rm -f "$TMP"
[ "$OK" = "1" ] || { echo "TSP_KEY_FAIL nowhere writable"; exit 1; }
F
    printf '\n'
    printf '\n'
    hr "PROVING IT WORKED (key only, password refused)"
    if TSP_BATCH=1 fingerprint "$H"; then
        say "$FP"
        printf '\n'
        say "That fingerprint came back with passwords disabled, so the key is in."
        say "Now record it:   sh $0 add <name> $H"
    else
        say "STILL FAILING: $REASON"
        printf '\n'
        say "If the line above says TSP_KEY_OK, the key is installed but the"
        say "daemon is not using it. On dropbear that is usually the permissions:"
        say "    ssh $H 'chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys'"
        exit 1
    fi
    printf '\n'
    exit 0
fi

# ===================================================================== add ===
if [ "$MODE" = "add" ]; then
    NAME="${2:-}"; H="${3:-}"
    [ -n "$NAME" ] && [ -n "$H" ] || { say "usage: sh $0 add <name> <user@host>"; say "e.g.  sh $0 add tsp root@192.168.1.21"; exit 2; }
    case "$NAME" in *[!A-Za-z0-9._-]*) say "name: letters, digits, dot, dash, underscore only"; exit 2 ;; esac
    case "$H" in *@*) ;; *) H="$USER_AT@$H" ;; esac
    hr "CHECKING $NAME = $H"
    if fingerprint "$H"; then
        say "$FP"
        reg_put "$NAME" "$H"
        say "recorded in $HOSTS as '$NAME'"
        [ -r "$STORE" ] || { printf '%s\n' "$H" > "$STORE"; say "and selected it, since nothing was selected yet"; }
    else
        say "NOT recorded: $REASON"
        printf '\n'
        say "Recording an unverified address would point the tools at the wrong"
        say "machine, so I have not."
        case "$REASON" in
            *AUTH*) say "Install a key, then re-run this exact command:"
                    say "    sh $0 key $H"
                    say "If ssh there wants another user: sh $0 add $NAME <user>@${H#*@}" ;;
            *"not a handheld"*) say "That address answered, but it is not the handheld. Check the"
                    say "address in the device's own settings and try that one." ;;
            *)      say "Check the address, then re-run this exact command." ;;
        esac
        exit 1
    fi
    printf '\n'
    exit 0
fi

# ==================================================================== list ===
if [ "$MODE" = "list" ]; then
    hr "RECORDED DEVICES"
    if [ ! -s "$HOSTS" ]; then
        say "none yet. Either sweep:      sh ~/Downloads/tsp_net.sh find"
        say "or add them by hand:         sh ~/Downloads/tsp_net.sh add tsps root@192.168.1.12"
        say "                             sh ~/Downloads/tsp_net.sh add tsp  root@192.168.1.21"
        printf '\n'; exit 0
    fi
    SEL=""; [ -r "$STORE" ] && SEL="$(cat "$STORE")"
    while IFS="$(printf '\t')" read -r n h <&3; do
        [ -n "$n" ] || continue
        M=" "; [ "$h" = "$SEL" ] && M="*"
        printf '  %s %-8s %-22s ' "$M" "$n" "$h"
        if fingerprint "$h"; then printf '%s\n' "$FP"
        else printf 'UNREACHABLE: %s\n' "$REASON"; fi
    done 3< "$HOSTS"
    printf '\n'
    say "* = the one the other tools are pointed at. Switch with: use <name>"
    printf '\n'
    exit 0
fi

# ===================================================================== use ===
if [ "$MODE" = "use" ]; then
    NAME="${2:-}"
    [ -n "$NAME" ] || { say "usage: sh $0 use <name>   (see: list)"; exit 2; }
    H="$(reg_get "$NAME")" || { say "no device named '$NAME'. Run: sh $0 list"; exit 1; }
    printf '%s\n' "$H" > "$STORE"
    hr "SELECTED $NAME = $H"
    say "every tsp_*.sh tool now talks to this one"
    printf '\n'
    exit 0
fi

# ==================================================================== show ===
if [ "$MODE" = "show" ]; then
    hr "WHAT THE TOOLS ARE POINTED AT"
    if [ -r "$STORE" ]; then
        D="$(cat "$STORE")"
        N="$(awk -F'\t' -v h="$D" '$2==h {print $1}' "$HOSTS" 2>/dev/null)"
        say "$STORE -> $D${N:+  (name: $N)}"
        if fingerprint "$D"; then say "  $FP"; else say "  UNREACHABLE: $REASON"; fi
    else
        say "nothing selected. Run: sh ~/Downloads/tsp_net.sh list"
    fi
    printf '\n'
    exit 0
fi

# ==================================================================== each ===
# Runs a tsp_*.sh command against every recorded device by exporting TSP_DEV,
# which every tool already honours, plus TSP_NAME so a tool can tag its own
# output file per card. {} in any argument becomes the device name, so
# per-device labels do not collide either.
if [ "$MODE" = "each" ]; then
    shift
    [ $# -gt 0 ] || { say "usage: sh $0 each tsp_cfw.sh scope"; say "   or: sh $0 each tsp_cfw.sh mark {}-baseline"; exit 2; }
    [ -s "$HOSTS" ] || { say "no devices recorded. Run: sh ~/Downloads/tsp_net.sh list"; exit 1; }
    CMD="$1"; shift
    case "$CMD" in
        */*) SCRIPT="$CMD" ;;
        *)   SCRIPT="$HOME/Downloads/$CMD" ;;
    esac
    [ -f "$SCRIPT" ] || { say "no such script: $SCRIPT"; exit 1; }
    RC=0
    RAN=0
    while IFS="$(printf '\t')" read -r n h <&3; do
        [ -n "$n" ] || continue
        hr "$n  ($h)"
        # substitute {} -> device name in every argument
        ARGS=""
        for a in "$@"; do
            b="$(printf '%s' "$a" | sed "s/{}/$n/g")"
            ARGS="$ARGS '$b'"
        done
        say "running: $CMD$ARGS"
        printf '\n'
        RAN=$((RAN + 1))
        # </dev/null matters: the tool being run calls ssh itself, and an ssh
        # without -n eats the stdin it is given. That stdin used to be this
        # loop's registry, so device 1 ran and device 2 vanished without a
        # word. fd 3 keeps the registry out of the child's reach either way.
        # shellcheck disable=SC2086
        eval "TSP_DEV='$h' TSP_NAME='$n' sh '$SCRIPT'$ARGS" </dev/null \
            || { RC=1; say "(that device returned non-zero)"; }
    done 3< "$HOSTS"
    printf '\n'
    say "ran on $RAN device(s)"
    [ "$RC" -eq 0 ] && say "all devices completed" || say "at least one device returned non-zero - see above"
    printf '\n'
    exit "$RC"
fi

# ==================================================================== find ===
hr "1. WHERE TO LOOK"
NETS="$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}')"
# Git Bash and MSYS have no ip(8). Pair each IPv4 Address line from ipconfig
# with the Subnet Mask line that follows it, and emit CIDR for the sizes the
# sweep below understands. Without this, find exits at step 1 on Windows.
if [ -z "$NETS" ] && command -v ipconfig >/dev/null 2>&1; then
    NETS="$(ipconfig 2>/dev/null | tr -d '\r' | awk '
        /IPv4 Address/ { split($0, p, ":"); a = p[2]; gsub(/[^0-9.]/, "", a); next }
        /Subnet Mask/ && a != "" {
            split($0, q, ":"); m = q[2]; gsub(/[^0-9.]/, "", m)
            if (m == "255.255.255.0")      print a "/24"
            else if (m == "255.255.254.0") print a "/23"
            else if (m == "255.255.252.0") print a "/22"
            a = ""
        }')"
fi
[ -n "$NETS" ] || {
    say "could not read this machine IPv4 addresses - no ip(8) and no ipconfig."
    say "You already know both addresses, so skip the sweep entirely:"
    say "    sh $0 add tsps root@192.168.1.12"
    say "    sh $0 add tsp  root@192.168.1.21"
    exit 1; }
say "this machine: $(printf '%s' "$NETS" | tr '\n' ' ')"

hr "2. NEIGHBOURS ALREADY KNOWN (free, no scan)"
NEIGH="$(ip -4 neigh show 2>/dev/null | awk '$1 ~ /^[0-9]+\./ {print $1}' | sort -u)"
[ -n "$NEIGH" ] || NEIGH="$(arp -a 2>/dev/null | tr -d '\r' \
    | grep -oE "([0-9]{1,3}[.]){3}[0-9]{1,3}" | sort -u)"
if [ -n "$NEIGH" ]; then printf '%s\n' "$NEIGH" | sed 's/^/    /'; else say "(arp cache empty)"; fi

hr "3. WHO HAS SSH OPEN"
say "254 addresses, 48 at a time, 2s each at worst - under a minute."
# One probe, ssh only. The previous version preferred bash /dev/tcp, which has
# no timeout of its own: on a LAN that DROPS rather than refuses, every silent
# address blocked for the OS SYN timeout and the sweep never finished. nc is
# absent from Git Bash. ssh is the one thing guaranteed present here, and
# ConnectTimeout is a real bound. An auth refusal still means sshd answered.
probe() {
    _p="$(ssh -n -o ConnectTimeout=2 -o BatchMode=yes -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
            "$USER_AT@$1" true 2>&1)"
    case "$_p" in
        *"Connection timed out"*|*"Operation timed out"*|*"No route to host"*\
        |*"Connection refused"*|*"Network is unreachable"*|*"Host is down"*\
        |*"Name or service not known"*|*"Connection closed"*) return 1 ;;
        *) return 0 ;;
    esac
}
CAND="/tmp/tsp_net_cand.$STAMP"; : > "$CAND"
ORD="/tmp/tsp_net_order.$STAMP"
for ip in $NEIGH; do printf '%s\n' "$ip"; done > "$ORD"
for n in $NETS; do
    case "$n" in
        */24|*/23|*/22)
            base="$(printf '%s' "${n%%/*}" | cut -d. -f1-3)"
            i=1; while [ "$i" -le 254 ]; do printf '%s.%s\n' "$base" "$i"; i=$((i + 1)); done ;;
        *) say "skipping $n - only /22../24 are swept; use 'add' for anything else" ;;
    esac
done >> "$ORD"
N=0
for ip in $(sort -u "$ORD"); do
    probe "$ip" && printf '%s\n' "$ip" >> "$CAND" &
    N=$((N + 1)); [ $((N % 48)) -eq 0 ] && wait
done
wait
rm -f "$ORD"
[ -s "$CAND" ] || { say "nothing on this LAN has port 22 open."; rm -f "$CAND"; exit 1; }
sort -u "$CAND" -o "$CAND"
say "$(wc -l < "$CAND") host(s) with ssh open:"
sed 's/^/    /' "$CAND"

hr "4. EVERY CANDIDATE, WITH A REASON EITHER WAY"
say "Nothing is dropped silently here. The previous version used BatchMode=yes,"
say "which disables password auth, so a device reachable only by password was"
say "discarded without a word - which is how .21 vanished from this section."
printf '\n'
HITS="/tmp/tsp_net_hits.$STAMP"; : > "$HITS"
while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    if fingerprint "$USER_AT@$ip"; then
        printf '  OK      %-22s %s\n' "$USER_AT@$ip" "$FP"
        printf '%s\t%s\n' "$USER_AT@$ip" "$FP" >> "$HITS"
    else
        printf '  no      %-22s %s\n' "$USER_AT@$ip" "$REASON"
    fi
done < "$CAND"
rm -f "$CAND"

hr "5. RECORD THEM"
if [ ! -s "$HITS" ]; then
    say "no handheld answered. If a reason above says AUTH, install a key:"
    say "    sh $0 key $USER_AT@<that address>"
    say "then re-run find. If ssh there uses another user:"
    say "    TSP_USER=<user> sh ~/Downloads/tsp_net.sh find"
    rm -f "$HITS"; exit 1
fi
say "Each handheld that answered, with the add line to paste for it. I do not"
say "name them for you - a name you did not choose is one you have to undo."
printf '\n'
while IFS="$(printf '\t')" read -r h f; do
    CFW="$(printf '%s' "$f" | sed -n 's/.*CFW=\([^ ]*\).*/\1/p' | tr -d '"')"
    BASH_="$(printf '%s' "$f" | sed -n 's/.*BASH=\([^ ]*\).*/\1/p')"
    printf '  %-22s CFW=%s bash=%s\n' "$h" "${CFW:-?}" "${BASH_:-?}"
    printf '      sh ~/Downloads/tsp_net.sh add <yourname> %s\n' "$h"
done < "$HITS"
rm -f "$HITS"
printf '\n'
say "e.g., for the two you already know:"
printf '      sh ~/Downloads/tsp_net.sh add tsps root@192.168.1.12\n'
printf '      sh ~/Downloads/tsp_net.sh add tsp  root@192.168.1.21\n'
printf '\n'
say "add records AND verifies. add with an existing name, or an address already"
say "recorded under another name, replaces that row rather than adding a second."
printf '\n'
