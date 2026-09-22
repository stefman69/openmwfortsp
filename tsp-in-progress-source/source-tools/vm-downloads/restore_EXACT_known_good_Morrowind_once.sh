#!/usr/bin/env bash
set -euo pipefail

HOST="${TSP_HOST:-root@192.168.1.21}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/Morrowind-MUOS-AUDIO-WATCHDOG-CLEAN(1).sh"
EXPECTED="8b6a3129bf37e5c39b0bee8572214ec72f32b8f750f7dd5b3910acd266ef1d38"
SOCK="${TMPDIR:-/tmp}/tsp-restore-known-good-$$.sock"

[ -f "$SRC" ] || {
    echo "ERROR: missing exact known-good launcher:"
    echo "  $SRC"
    exit 1
}

LOCAL_SHA="$(sha256sum "$SRC" | awk '{print $1}')"
[ "$LOCAL_SHA" = "$EXPECTED" ] || {
    echo "ERROR: local launcher is not the exact known-good file."
    echo "expected=$EXPECTED"
    echo "actual=$LOCAL_SHA"
    exit 2
}

cleanup() {
    ssh -S "$SOCK" -O exit "$HOST" >/dev/null 2>&1 || true
    rm -f "$SOCK" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "===== 1/4 AUTHENTICATE ONCE ====="
echo "One password prompt only. Backup, upload, restore, and verification reuse it."
ssh -M -S "$SOCK" -o ControlPersist=10m "$HOST" true

echo
echo "===== 2/4 BACK UP CURRENT DEVICE LAUNCHER ====="
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
[ -n "$PLAY" ] || { echo "ERROR: active Morrowind.sh not found"; exit 20; }

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

mkdir -p "$ROOT/launcher-backups"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$ROOT/launcher-backups/Morrowind.sh.before-known-good-restore-$STAMP"
cp -p "$PLAY" "$BACKUP"

echo "PLAY=$PLAY"
echo "ROOT=$ROOT"
echo "BACKUP=$BACKUP"
echo "CURRENT_SHA=$(sha256sum "$PLAY" | awk '{print $1}')"
REMOTE

echo
echo "===== 3/4 UPLOAD + RESTORE EXACT KNOWN-GOOD LAUNCHER ====="
scp -o ControlPath="$SOCK" "$SRC" "$HOST:/tmp/Morrowind.KNOWN-GOOD.sh"

ssh -S "$SOCK" "$HOST" sh -s -- "$EXPECTED" <<'REMOTE'
set -eu
EXPECTED="$1"

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
[ -n "$PLAY" ] || { echo "ERROR: active Morrowind.sh not found"; exit 30; }

UP_SHA="$(sha256sum /tmp/Morrowind.KNOWN-GOOD.sh | awk '{print $1}')"
[ "$UP_SHA" = "$EXPECTED" ] || {
    echo "ERROR: uploaded file hash mismatch"
    echo "expected=$EXPECTED"
    echo "actual=$UP_SHA"
    exit 31
}

cat /tmp/Morrowind.KNOWN-GOOD.sh > "$PLAY"
chmod +x "$PLAY"
rm -f /tmp/Morrowind.KNOWN-GOOD.sh

FINAL_SHA="$(sha256sum "$PLAY" | awk '{print $1}')"
[ "$FINAL_SHA" = "$EXPECTED" ] || {
    echo "ERROR: installed launcher hash mismatch"
    exit 32
}

echo "RESTORED=$PLAY"
REMOTE

echo
echo "===== 4/4 VERIFY BYTE-FOR-BYTE ====="
ssh -S "$SOCK" "$HOST" sh -s -- "$EXPECTED" <<'REMOTE'
set -eu
EXPECTED="$1"
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
[ -n "$PLAY" ]
SHA="$(sha256sum "$PLAY" | awk '{print $1}')"
[ "$SHA" = "$EXPECTED" ]
echo "PASS: exact known-good launcher restored"
echo "sha256=$SHA"
echo "No diagnostic changes are active in Morrowind.sh."
REMOTE
