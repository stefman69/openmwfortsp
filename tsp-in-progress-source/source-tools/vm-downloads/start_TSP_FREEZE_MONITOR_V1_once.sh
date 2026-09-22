#!/usr/bin/env bash
set -euo pipefail

HOST="${TSP_HOST:-root@192.168.1.21}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/tsp_freeze_monitor_v1_device.sh"
SOCK="${TMPDIR:-/tmp}/tsp-freeze-monitor-$$.sock"

[ -f "$SRC" ] || { echo "ERROR: missing $SRC"; exit 1; }

cleanup() {
    ssh -S "$SOCK" -O exit "$HOST" >/dev/null 2>&1 || true
    rm -f "$SOCK" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "===== 1/4 AUTHENTICATE ONCE ====="
echo "One password prompt only. Upload/start/verify reuse this connection."
ssh -M -S "$SOCK" -o ControlPersist=10m "$HOST" true

echo
echo "===== 2/4 VERIFY KNOWN-GOOD LAUNCHER + RUNNING GAME ====="
ssh -S "$SOCK" "$HOST" 'sh -s' <<'REMOTE'
set -eu
EXPECTED="8b6a3129bf37e5c39b0bee8572214ec72f32b8f750f7dd5b3910acd266ef1d38"

PLAY=""
for p in \
    /roms/ports/Morrowind.sh \
    /mnt/mmc/ROMS/Ports/Morrowind.sh \
    /mnt/mmc/Roms/PORTS/Morrowind.sh \
    /mnt/SDCARD/Roms/PORTS/Morrowind.sh \
    /userdata/roms/ports/Morrowind.sh \
    /storage/roms/ports/Morrowind.sh
do
    [ -f "$p" ] && { PLAY="$p"; break; }
done
[ -n "$PLAY" ] || { echo "ERROR: active Morrowind.sh not found"; exit 19; }

SHA="$(sha256sum "$PLAY" | awk '{print $1}')"
[ "$SHA" = "$EXPECTED" ] || {
    echo "ERROR: launcher is not the known-good baseline. Refusing to start diagnostics."
    echo "launcher=$PLAY"
    echo "expected=$EXPECTED"
    echo "actual=$SHA"
    exit 20
}
echo "Known-good launcher verified: $SHA"

PID=""
for d in /proc/[0-9]*; do
    [ -r "$d/comm" ] || continue
    IFS= read -r c < "$d/comm" || continue
    case "$c" in openmw-0.51|openmw) PID="${d##*/}"; break ;; esac
done
[ -n "$PID" ] || {
    echo "ERROR: OpenMW is not running."
    echo "Load your save fully into gameplay first, then rerun this starter."
    exit 21
}
echo "OpenMW pid=$PID"
REMOTE

echo
echo "===== 3/4 UPLOAD + START EXTERNAL MONITOR ====="
scp -o ControlPath="$SOCK" "$SRC" "$HOST:/tmp/tsp_freeze_monitor_v1_device.sh"

ssh -S "$SOCK" "$HOST" 'sh -s' <<'REMOTE'
set -eu

ROOT=""
for r in \
    /mnt/SDCARD/data/ports/openmw \
    /mnt/sdcard/mmcblk1p1/data/ports/openmw \
    /userdata/roms/ports/openmw \
    /mnt/mmc/ports/openmw \
    /mnt/sdcard/ports/openmw \
    /roms/ports/openmw \
    /storage/roms/ports/openmw
do
    [ -x "$r/bin/openmw-0.51" ] && { ROOT="$r"; break; }
done
[ -n "$ROOT" ] || { echo "ERROR: OpenMW root not found"; exit 21; }

mkdir -p "$ROOT/tsp_freeze_monitor"
cp -f /tmp/tsp_freeze_monitor_v1_device.sh "$ROOT/tsp_freeze_monitor/monitor-v1.sh"
chmod +x "$ROOT/tsp_freeze_monitor/monitor-v1.sh"
rm -f /tmp/tsp_freeze_monitor_v1_device.sh

# Stop only a stale copy of this external monitor, never OpenMW or the launcher.
if [ -f "$ROOT/tsp_freeze_monitor/active.pid" ]; then
    read -r OLD < "$ROOT/tsp_freeze_monitor/active.pid" 2>/dev/null || OLD=""
    case "$OLD" in
        ''|*[!0-9]*) ;;
        *) kill "$OLD" 2>/dev/null || true ;;
    esac
fi

nohup sh "$ROOT/tsp_freeze_monitor/monitor-v1.sh" \
    > "$ROOT/tsp_freeze_monitor/monitor-v1.stdout" 2>&1 </dev/null &
MPID=$!
echo "$MPID" > "$ROOT/tsp_freeze_monitor/active.pid"
sleep 2

kill -0 "$MPID" 2>/dev/null || {
    echo "ERROR: monitor exited during startup"
    cat "$ROOT/tsp_freeze_monitor/monitor-v1.stdout" 2>/dev/null || true
    exit 22
}

echo "ROOT=$ROOT"
echo "MONITOR_PID=$MPID"
REMOTE

echo
echo "===== 4/4 VERIFY LAUNCHER WAS NOT MODIFIED ====="
ssh -S "$SOCK" "$HOST" 'sh -s' <<'REMOTE'
set -eu
PLAY=""
for p in \
    /roms/ports/Morrowind.sh \
    /mnt/mmc/ROMS/Ports/Morrowind.sh \
    /mnt/mmc/Roms/PORTS/Morrowind.sh \
    /mnt/SDCARD/Roms/PORTS/Morrowind.sh \
    /userdata/roms/ports/Morrowind.sh \
    /storage/roms/ports/Morrowind.sh
do
    [ -f "$p" ] && { PLAY="$p"; break; }
done
[ -n "$PLAY" ] || { echo "ERROR: active launcher not found"; exit 23; }
SHA="$(sha256sum "$PLAY" | awk '{print $1}')"
echo "launcher=$PLAY"
echo "launcher_sha256=$SHA"
echo "PASS: external monitor started; Morrowind.sh was not edited by this operation"
REMOTE

echo
echo "DONE."
echo "Keep playing normally until the console freezes."
echo "After reboot, use collect_TSP_FREEZE_MONITOR_V1_once.sh."
