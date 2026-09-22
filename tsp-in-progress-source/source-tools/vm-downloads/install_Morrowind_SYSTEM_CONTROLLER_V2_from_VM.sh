#!/usr/bin/env bash
set -u -o pipefail

DEV="root@192.168.1.21"
LOCAL="${HOME}/Downloads/Morrowind-SYSTEM-CONTROLLER-V2.sh"
REMOTE="/mnt/mmc/ROMS/Ports/Morrowind.sh"
BACKUP_DIR="/mnt/mmc/ports/openmw/launcher-backups"
EXPECTED_SHA="47823d373dee975cdd6a8ec1fadf45f83e00e0139f28021af5652cfba1799bae"

fail() { echo "ERROR: $*" >&2; exit 1; }
[ -f "$LOCAL" ] || fail "missing $LOCAL"
command -v ssh >/dev/null 2>&1 || fail "ssh is not installed"
LOCAL_SHA="$(sha256sum "$LOCAL" | awk '{print $1}')"
[ "$LOCAL_SHA" = "$EXPECTED_SHA" ] || fail "local launcher checksum mismatch: $LOCAL_SHA"

MUX_DIR="$(mktemp -d /tmp/tsp-morrowind-ssh.XXXXXX)" || fail "cannot create SSH control directory"
SOCK="$MUX_DIR/master"
cleanup() {
    ssh -S "$SOCK" -O exit "$DEV" >/dev/null 2>&1 || true
    rm -rf "$MUX_DIR" 2>/dev/null || true
}
trap cleanup EXIT

BASE=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=12)

printf '\n===== 1/4 AUTHENTICATE ONCE =====\n'
echo "One password prompt only. Every remaining SSH operation reuses this connection."
ssh "${BASE[@]}" -o ControlMaster=yes -o ControlPersist=900 -o "ControlPath=$SOCK" "$DEV" true \
    || fail "could not authenticate to $DEV"

rssh() {
    ssh "${BASE[@]}" -o BatchMode=yes -o "ControlPath=$SOCK" "$DEV" "$@"
}

printf '\n===== 2/4 BACK UP CURRENT MORROWIND LAUNCHER =====\n'
STAMP="$(date +%Y%m%d-%H%M%S)"
rssh "mkdir -p '$BACKUP_DIR' && test -f '$REMOTE' && cp -p '$REMOTE' '$BACKUP_DIR/Morrowind.sh.before-system-controller-$STAMP'" \
    || fail "could not back up $REMOTE"
echo "Backup: $BACKUP_DIR/Morrowind.sh.before-system-controller-$STAMP"

printf '\n===== 3/4 INSTALL CONTROLLER-NEUTRAL LAUNCHER =====\n'
# Stream over the already-authenticated SSH master; no scp and no second password prompt.
ssh "${BASE[@]}" -o BatchMode=yes -o "ControlPath=$SOCK" "$DEV" \
    "cat > '$REMOTE.incoming' && chmod 755 '$REMOTE.incoming' && mv -f '$REMOTE.incoming' '$REMOTE'" < "$LOCAL" \
    || fail "launcher upload/install failed"

printf '\n===== 4/4 VERIFY ON DEVICE =====\n'
rssh "set -u; \
    got=\$(sha256sum '$REMOTE' | awk '{print \$1}'); \
    [ \"\$got\" = '$EXPECTED_SHA' ] || { echo \"bad sha: \$got\"; exit 21; }; \
    grep -Fq 'TSP_SYSTEM_CONTROLLER_V2' '$REMOTE' || exit 22; \
    ! grep -Eq 'tsp_muos_uart_(start|stop|restore_stock)|tsp_muos_uart_input_v1\\.py|TSP_MUOS_UART_(DRIVER|PID|ACTIVE)|TSP_MUOS_STICK_CALIBRATION|pkill -9 -x trimui_inputd_smart_pro' '$REMOTE' || exit 23; \
    echo 'PASS launcher uses the system controller only'; \
    echo \"sha256=\$got\"; \
    echo 'controller_handler=/usr/bin/trimui_inputd_smart_pro'; \
    echo 'old_game_local_uart_route=absent'" \
    || fail "device verification failed"

echo
echo "DONE: Morrowind now leaves controller ownership to the system patch."
echo "No reboot is required for the launcher file itself; the next game launch uses it."
